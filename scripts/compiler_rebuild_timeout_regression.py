#!/usr/bin/env python3
"""Exercise rebuild timeout and cancellation with harmless child processes."""

from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


WRAPPER = Path(__file__).with_name("compiler_rebuild_timeout.py").resolve()


def check_cancellation(signum: signal.Signals, marker: Path) -> None:
    # The child keeps stdout open. communicate() observes EOF only after the
    # wrapper and the background child have both stopped.
    command = 'sleep 10 & child=$!; printf "%s\n" "$child" > "$1"; wait "$child"'
    with subprocess.Popen(
        [sys.executable, str(WRAPPER), "--", "/bin/sh", "-c", command, "fixture", str(marker)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ) as wrapper:
        try:
            deadline = time.monotonic() + 3
            while not marker.exists() or not marker.read_text().strip():
                if time.monotonic() >= deadline:
                    raise AssertionError("cancellation fixture did not start")
                time.sleep(0.01)
            wrapper.send_signal(signum)
            _, stderr = wrapper.communicate(timeout=3)
            if wrapper.returncode != 128 + signum:
                raise AssertionError(f"unexpected cancellation status: {stderr!r}")
        finally:
            if wrapper.poll() is None:
                wrapper.terminate()


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        for signum in (signal.SIGINT, signal.SIGTERM):
            check_cancellation(signum, Path(directory) / signum.name)

    # Keep the regression fast without changing the production deadline.
    short_deadline = (
        "import runpy, sys; "
        "main = runpy.run_path(sys.argv.pop(1))['main']; "
        "main.__globals__['TIMEOUT_SECONDS'] = 0.1; "
        "raise SystemExit(main())"
    )
    result = subprocess.run(
        [sys.executable, "-c", short_deadline, str(WRAPPER), "--", "/bin/sleep", "10"],
        capture_output=True,
        timeout=3,
    )
    if result.returncode != 124:
        raise AssertionError(f"unexpected timeout status: {result.stderr!r}")
    print("Compiler rebuild timeout and cancellation checks passed")


if __name__ == "__main__":
    main()
