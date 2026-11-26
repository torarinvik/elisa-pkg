#!/usr/bin/env python3
"""Run one Elisa compiler rebuild with a strict 30-second wall-clock limit."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


TIMEOUT_SECONDS = 30


def process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


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
    cancellation_signal = 0

    def request_cancel(signum, _frame):
        # Record cancellation even if it arrives while Popen is starting the
        # session. Cleanup runs once the child's process group is known.
        nonlocal cancellation_signal
        cancellation_signal = signum

    signal.signal(signal.SIGINT, request_cancel)
    signal.signal(signal.SIGTERM, request_cancel)
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

    # Reap the leader and confirm the complete rebuild group has exited.
    # Polling also lets cancellation interrupt the wait without interrupting
    # Popen or leaving its newly detached child behind.
    while not cancellation_signal and time.monotonic() < deadline:
        return_code = process.poll()
        if return_code is not None and not process_group_exists(process.pid):
            completed_at = time.monotonic()
            if not cancellation_signal and completed_at < deadline:
                elapsed = completed_at - started
                print(
                    f"compiler rebuild completed in {elapsed:.3f}s "
                    f"(limit {TIMEOUT_SECONDS}s)",
                    file=sys.stderr,
                )
                return return_code if return_code >= 0 else 128 - return_code
            break
        time.sleep(max(0.0, min(0.01, deadline - time.monotonic())))

    terminate_process_group(process.pid)
    # An uninterruptible child must not extend the wall-clock limit.
    process.poll()
    if cancellation_signal:
        print("error: compiler rebuild cancelled; terminated its process group", file=sys.stderr)
        return 128 + cancellation_signal
    print(
        f"error: compiler rebuild exceeded its {TIMEOUT_SECONDS}-second "
        "wall-clock limit; sent SIGKILL to its process group",
        file=sys.stderr,
    )
    return 124


if __name__ == "__main__":
    raise SystemExit(main())
