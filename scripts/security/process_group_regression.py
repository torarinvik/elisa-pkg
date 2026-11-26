#!/usr/bin/env python3
"""Verify a normally exiting process cannot leave a same-group child behind."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
COMPILER_ROOT = Path(os.environ.get("ELISA_COMPILER_ROOT", ""))
STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1"))
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh"))
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))


def source_for() -> str:
    return f'''include "{ROOT / "src/platform.elisa"}"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    leader: i64 = Platform::fork_process()
    if leader == 0:
        if Platform::set_process_group() != 0:
            Platform::exit_process(20)
        if Platform::set_process_limits(2) != 0:
            Platform::exit_process(21)
        descendant: i64 = Platform::fork_process()
        if descendant < 0:
            Platform::exit_process(22)
        if descendant == 0:
            if Platform::create_exclusive_file("ready") != 0:
                Platform::exit_process(23)
            descendant_deadline: i64 = Platform::monotonic_milliseconds() + 8000
            descendant_now: mutable i64 = 0
            while Platform::access_path("release", 0) != 0 |descendant_deadline, descendant_now|:
                descendant_now <- Platform::monotonic_milliseconds()
                if descendant_now < 0 or descendant_now > descendant_deadline:
                    Platform::exit_process(24)
                if Platform::sleep_milliseconds(10) != 0:
                    Platform::exit_process(27)
            if Platform::create_exclusive_file("escaped") != 0:
                Platform::exit_process(25)
            Platform::exit_process(0)
        ready_deadline: i64 = Platform::monotonic_milliseconds() + 15000
        ready_now: mutable i64 = 0
        while Platform::access_path("ready", 0) != 0 |ready_deadline, ready_now|:
            ready_now <- Platform::monotonic_milliseconds()
            if ready_now < 0 or ready_now > ready_deadline:
                Platform::exit_process(26)
            if Platform::sleep_milliseconds(10) != 0:
                Platform::exit_process(28)
        Platform::exit_process(0)
    if leader < 0:
        return 1

    status: mutable i32 = 0
    waited: i64 = Platform::wait_for_process_group_with_timeout(leader, &status, 20000)
    return 2 if waited != 0
    return 7 if status != 0
    return 3 if Platform::access_path("ready", 0) != 0
    return 4 if Platform::create_exclusive_file("release") != 0
    observe_deadline: i64 = Platform::monotonic_milliseconds() + 2000
    observe_now: mutable i64 = 0
    while Platform::access_path("escaped", 0) != 0 |observe_deadline, observe_now|:
        observe_now <- Platform::monotonic_milliseconds()
        return 5 if observe_now < 0
        break if observe_now >= observe_deadline
        return 8 if Platform::sleep_milliseconds(10) != 0
    return 6 if Platform::access_path("escaped", 0) == 0
    return 0
'''


def main() -> int:
    for label, path in (
        ("compiler root", COMPILER_ROOT),
        ("stage1 compiler", STAGE1),
        ("compiler wrapper", WRAPPER),
        ("runtime object", RUNTIME),
    ):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}; set ELISA_COMPILER_ROOT")
    if not STAGE1.is_file() or not os.access(STAGE1, os.X_OK) or not os.access(WRAPPER, os.X_OK):
        raise SystemExit("error: Elisa stage1 compiler and wrapper must be executable")

    (ROOT / "build").mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment["ELISA_STAGE1_BIN"] = str(STAGE1)
    environment["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
    environment.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")

    with tempfile.TemporaryDirectory(prefix="elisapkg-process-group-", dir=ROOT / "build") as raw:
        work = Path(raw)
        source = work / "process_group_probe.elisa"
        binary = work / "process_group_probe"
        source.write_text(source_for(), encoding="utf-8")
        compile_result = subprocess.run(
            [str(WRAPPER), "-emit", "exe", "-o", str(binary), str(source)],
            cwd=work,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
        if compile_result.returncode != 0:
            raise SystemExit(f"error: could not compile process group probe:\n{compile_result.stdout}")

        run_result = subprocess.run([str(binary)], cwd=work, env=environment, timeout=30, check=False)
        if run_result.returncode != 0:
            detail = {
                2: "leader wait or process-group cleanup returned an error",
                7: "leader exited before the descendant became ready",
                8: "descendant check could not sleep",
            }.get(run_result.returncode, "a same-group descendant survived normal parent exit or cleanup failed")
            raise SystemExit(
                f"error: process group probe returned {run_result.returncode}: {detail}"
            )

    print("Elisa process group cleanup regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
