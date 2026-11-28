#!/usr/bin/env python3
"""Exercise rebuild timeout and cancellation with harmless child processes."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


WRAPPER = Path(__file__).with_name("compiler_rebuild_timeout.py").resolve()
STAGE0_HOOK = Path(__file__).with_name("stage0_rebuild_hook.py").resolve()


def run_wrapper(*arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run([sys.executable, str(WRAPPER), *arguments], capture_output=True, timeout=5)


def check_options_and_resume(directory: Path) -> None:
    for bad in (["/bin/true"], ["--limit-seconds", "0", "--", "/bin/true"],
                ["--limit-seconds", "nan", "--", "/bin/true"], ["--unknown", "1", "--", "/bin/true"]):
        if run_wrapper(*bad).returncode != 2:
            raise AssertionError(f"usage error was not reported for {bad!r}")
    if run_wrapper("--limit-seconds", "0.2", "--", "/bin/sleep", "10").returncode != 124:
        raise AssertionError("--limit-seconds did not bound the rebuild")

    # The fixture exits 75 twice, saving progress, then succeeds. Resumes share
    # one deadline, and any other failure status passes through unchanged.
    counter = directory / "attempts"
    resumable = 'n=$(cat "$1" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$1"; [ "$n" -ge 3 ] || exit 75'
    resumed = run_wrapper("--resume-status", "75", "--", "/bin/sh", "-c", resumable, "fixture", str(counter))
    if resumed.returncode != 0 or counter.read_text().strip() != "3":
        raise AssertionError(f"checkpointed rebuild was not resumed: {resumed.stderr!r}")
    if run_wrapper("--", "/bin/sh", "-c", "exit 75").returncode != 75:
        raise AssertionError("status 75 was resumed without --resume-status")
    if run_wrapper("--resume-status", "75", "--", "/bin/sh", "-c", "exit 3").returncode != 3:
        raise AssertionError("a failing rebuild status was not passed through")
    endless = run_wrapper("--limit-seconds", "0.5", "--resume-status", "75", "--", "/bin/sh", "-c", "exit 75")
    if endless.returncode != 124:
        raise AssertionError("resumes extended the overall deadline")


def check_stage0_hook() -> None:
    hook_command = [sys.executable, str(STAGE0_HOOK), "5", "--grace-seconds", "0", "--", "/bin/sh", "-c", "exit 7"]
    unsupervised = subprocess.run(hook_command, capture_output=True, timeout=5,
                                  env={key: value for key, value in os.environ.items() if key != "ELISA_REBUILD_SUPERVISOR"})
    if unsupervised.returncode != 2:
        raise AssertionError("Stage0 hook ran a build without a rebuild supervisor")
    supervised = run_wrapper("--", *hook_command)
    if supervised.returncode != 7:
        raise AssertionError(f"Stage0 hook did not run its command: {supervised.stderr!r}")
    bounded = run_wrapper("--limit-seconds", "0.2", "--", sys.executable, str(STAGE0_HOOK), "5", "--", "/bin/sleep", "10")
    if bounded.returncode != 124:
        raise AssertionError("Stage0 hook escaped the supervisor's deadline")


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
        check_options_and_resume(Path(directory))
    check_stage0_hook()

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
