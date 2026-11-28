#!/usr/bin/env python3
"""Stand in for Elisa-core's Stage0 timeout script under a rebuild supervisor.

Elisa-core's `make build` runs `python3 $(ELISA_STAGE0_TIMEOUT_SCRIPT) 5
--grace-seconds 0 -- COMMAND ...`. CI passes this script as that hook so the
Stage0 build runs under `compiler_rebuild_timeout.py`'s limit instead of the
fixed five seconds. The command replaces this process, so it stays in the
supervisor's process group and is killed with it at the supervisor's deadline.
Outside that supervisor this script would run the build with no limit at all,
so it refuses to run unless ELISA_REBUILD_SUPERVISOR is set.
"""

from __future__ import annotations

import os
import sys


def main() -> int:
    arguments = sys.argv[1:]
    if os.environ.get("ELISA_REBUILD_SUPERVISOR") != "1":
        print("error: stage0_rebuild_hook.py only runs under compiler_rebuild_timeout.py", file=sys.stderr)
        return 2
    if "--" not in arguments or arguments.index("--") + 1 >= len(arguments):
        print("usage: stage0_rebuild_hook.py SECONDS [OPTION ...] -- COMMAND [ARG ...]", file=sys.stderr)
        return 2
    command = arguments[arguments.index("--") + 1:]
    try:
        os.execvp(command[0], command)
    except OSError as error:
        print(f"error: unable to start Stage0 build: {error}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    raise SystemExit(main())
