#!/usr/bin/env python3
"""Run one Elisa compiler rebuild with a strict 30-second wall-clock limit."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from typing import Optional


TIMEOUT_SECONDS = 30


def wait_for_process_group_exit(process_group: int, deadline: float) -> Optional[float]:
    """Wait until the rebuild leader and every same-group child have exited."""
    while True:
        if time.monotonic() >= deadline:
            return False
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            # Do not let scheduler delay turn a post-deadline observation into
            # a successful rebuild result.
            completed_at = time.monotonic()
            return completed_at if completed_at < deadline else None
        except PermissionError:
            # The group still exists, but the wrapper cannot signal it. Keep
            # enforcing the deadline and let the caller report the timeout.
            pass

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        time.sleep(min(0.01, remaining))


def terminate_process_group(process_group: int) -> None:
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass


def is_stage1_seed_command(command: list[str]) -> bool:
    for index in range(len(command) - 1):
        if (
            os.path.basename(command[index]) == "elisac_stage1.sh"
            and command[index + 1] == "--seed"
        ):
            return True
    return False


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] != "--":
        print(
            "usage: compiler_rebuild_timeout.py -- COMMAND [ARG ...]",
            file=sys.stderr,
        )
        return 2

    command = sys.argv[2:]
    started = time.monotonic()
    deadline = started + TIMEOUT_SECONDS
    environment = os.environ.copy()
    if is_stage1_seed_command(command):
        # The Stage1 wrapper normally starts its own timeout session. Here this
        # process owns the timeout and group, so keep the seed build inside it
        # for reliable cancellation at the same deadline.
        environment["ELISA_STAGE1_SEED_TIMEOUT_WRAPPED"] = "1"
    try:
        process = subprocess.Popen(
            command,
            env=environment,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as error:
        print(f"error: unable to start compiler rebuild: {error}", file=sys.stderr)
        return 127

    try:
        return_code = process.wait(timeout=max(0.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        # The rebuild can spawn make, Go, or compiler children. Keep them in
        # one session and signal the whole process group at the deadline.
        terminate_process_group(process.pid)
        # Reap the leader only if it has already exited. A blocking wait here
        # would let an uninterruptible child defeat the wall-clock deadline.
        process.poll()
        print(
            f"error: compiler rebuild exceeded its {TIMEOUT_SECONDS}-second "
            "wall-clock limit; sent SIGKILL to its process group",
            file=sys.stderr,
        )
        return 124

    # A wrapper can exit successfully while a background compiler child keeps
    # rebuilding. The wall-clock contract covers the whole process group, not
    # only the command whose PID Popen tracks.
    completed_at = wait_for_process_group_exit(process.pid, deadline)
    if completed_at is None:
        terminate_process_group(process.pid)
        process.poll()
        print(
            f"error: compiler rebuild exceeded its {TIMEOUT_SECONDS}-second "
            "wall-clock limit; sent SIGKILL to its process group",
            file=sys.stderr,
        )
        return 124

    elapsed = completed_at - started
    print(
        f"compiler rebuild completed in {elapsed:.3f}s "
        f"(limit {TIMEOUT_SECONDS}s)",
        file=sys.stderr,
    )
    return return_code if return_code >= 0 else 128 - return_code


if __name__ == "__main__":
    raise SystemExit(main())
