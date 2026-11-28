#!/usr/bin/env python3
"""Run one Elisa compiler rebuild under a strict wall-clock limit.

The limit defaults to 30 seconds. `--limit-seconds N` changes it, and
`--resume-status S` reruns the command while it exits with status S (a build
that saved a checkpoint and asks to be rerun) until it finishes or the single
overall deadline passes.
"""

from __future__ import annotations

import math
import os
import signal
import subprocess
import sys
import time


TIMEOUT_SECONDS = 30
USAGE = "usage: compiler_rebuild_timeout.py [--limit-seconds N] [--resume-status S] -- COMMAND [ARG ...]"


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
    except PermissionError:
        # macOS reports EPERM when the group holds only an exited, unreaped
        # leader. Every live member is this process's own child, which it may
        # always signal, so nothing in the group is left running.
        pass


def is_stage1_seed_command(command: list[str]) -> bool:
    for index in range(len(command) - 1):
        if (
            os.path.basename(command[index]) == "elisac_stage1.sh"
            and command[index + 1] == "--seed"
        ):
            return True
    return False


def parse_arguments(arguments: list[str]) -> tuple[float, int | None, list[str]] | None:
    """Return (limit seconds, resume status, command), or None for bad usage."""
    limit_seconds: float = TIMEOUT_SECONDS
    resume_status: int | None = None
    index = 0
    while index < len(arguments) and arguments[index] != "--":
        if index + 1 >= len(arguments):
            return None
        option, value = arguments[index], arguments[index + 1]
        try:
            if option == "--limit-seconds":
                limit_seconds = float(value)
            elif option == "--resume-status":
                resume_status = int(value)
            else:
                return None
        except ValueError:
            return None
        index += 2
    command = arguments[index + 1:]
    if index >= len(arguments) or not command or not math.isfinite(limit_seconds) or limit_seconds <= 0:
        return None
    return limit_seconds, resume_status, command


def main() -> int:
    parsed = parse_arguments(sys.argv[1:])
    if parsed is None:
        print(USAGE, file=sys.stderr)
        return 2

    limit_seconds, resume_status, command = parsed
    started = time.monotonic()
    deadline = started + limit_seconds
    environment = os.environ.copy()
    # stage0_rebuild_hook.py checks this before it drops Elisa-core's own
    # Stage0 limit, because only this deadline then bounds the build.
    environment["ELISA_REBUILD_SUPERVISOR"] = "1"
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
    attempt = 1
    # The attempt whose process group may still be running, if any.
    process: subprocess.Popen | None = None
    while not cancellation_signal and time.monotonic() < deadline:
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
        return_code: int | None = None
        while not cancellation_signal and time.monotonic() < deadline:
            polled = process.poll()
            if polled is not None and not process_group_exists(process.pid):
                return_code = polled if time.monotonic() < deadline else None
                process = None
                break
            time.sleep(max(0.0, min(0.01, deadline - time.monotonic())))

        if return_code is None or cancellation_signal:
            break
        if resume_status is not None and return_code == resume_status:
            print(f"compiler rebuild attempt {attempt} saved a checkpoint; resuming", file=sys.stderr)
            attempt += 1
            continue
        elapsed = time.monotonic() - started
        print(
            f"compiler rebuild completed in {elapsed:.3f}s "
            f"after {attempt} attempt(s) (limit {limit_seconds:g}s)",
            file=sys.stderr,
        )
        return return_code if return_code >= 0 else 128 - return_code

    if process is not None:
        terminate_process_group(process.pid)
        # An uninterruptible child must not extend the wall-clock limit.
        process.poll()
    if cancellation_signal:
        print("error: compiler rebuild cancelled; terminated its process group", file=sys.stderr)
        return 128 + cancellation_signal
    print(
        f"error: compiler rebuild exceeded its {limit_seconds:g}-second "
        "wall-clock limit; sent SIGKILL to its process group",
        file=sys.stderr,
    )
    return 124


if __name__ == "__main__":
    raise SystemExit(main())
