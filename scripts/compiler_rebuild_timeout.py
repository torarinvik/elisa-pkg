#!/usr/bin/env python3
"""Run one Elisa compiler rebuild with a strict 30-second wall-clock limit."""

from __future__ import annotations

import os
import signal
import subprocess
import sys


TIMEOUT_SECONDS = 30


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] != "--":
        print(
            "usage: compiler_rebuild_timeout.py -- COMMAND [ARG ...]",
            file=sys.stderr,
        )
        return 2

    command = sys.argv[2:]
    try:
        process = subprocess.Popen(command, start_new_session=True)
    except OSError as error:
        print(f"error: unable to start compiler rebuild: {error}", file=sys.stderr)
        return 127

    try:
        return_code = process.wait(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            # The rebuild can spawn make, Go, or compiler children. Keep them
            # in one session and terminate the whole process group at the same
            # deadline so no background rebuild continues past the limit.
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
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
