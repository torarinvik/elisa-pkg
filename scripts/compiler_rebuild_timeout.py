#!/usr/bin/env python3
"""Run one Elisa compiler rebuild with a strict 30-second wall-clock limit."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time


TIMEOUT_SECONDS = 30


def wait_for_process_group_exit(process_group: int, deadline: float) -> bool:
    """Wait until the rebuild leader and every same-group child have exited."""
    while True:
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            # The group still exists, but the wrapper cannot signal it. Keep
            # enforcing the deadline and let the caller report the timeout.
            pass

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.01, remaining))


def terminate_process_group(process_group: int) -> None:
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] != "--":
        print(
            "usage: compiler_rebuild_timeout.py -- COMMAND [ARG ...]",
            file=sys.stderr,
        )
        return 2

    command = sys.argv[2:]
    deadline = time.monotonic() + TIMEOUT_SECONDS
    try:
        process = subprocess.Popen(
            command,
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
        # one session and terminate the whole process group at the deadline.
        terminate_process_group(process.pid)
        process.wait()
        print(
            f"error: compiler rebuild exceeded its {TIMEOUT_SECONDS}-second "
            "wall-clock limit; terminated its process group",
            file=sys.stderr,
        )
        return 124

    # A wrapper can exit successfully while a background compiler child keeps
    # rebuilding. The wall-clock contract covers the whole process group, not
    # only the command whose PID Popen tracks.
    if not wait_for_process_group_exit(process.pid, deadline):
        terminate_process_group(process.pid)
        process.wait()
        print(
            f"error: compiler rebuild exceeded its {TIMEOUT_SECONDS}-second "
            "wall-clock limit; terminated its process group",
            file=sys.stderr,
        )
        return 124

    return return_code if return_code >= 0 else 128 - return_code


if __name__ == "__main__":
    raise SystemExit(main())
