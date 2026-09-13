#!/usr/bin/env python3
"""Compile and exercise the safe aggregate-source include emitter."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILD_ROOT = ROOT / "build"


def byte_list(value: bytes) -> str:
    return ",".join(str(byte) for byte in value)


def probe_source() -> str:
    module_path = ROOT / "src" / "build.elisa"
    safe_path = b"/tmp/package root/src/main.elisa"
    expected = b"x\ninclude \"" + safe_path + b"\"\n"
    return f'''include "{module_path}"

def same_bytes(left: darray[u8]&, right: darray[u8]&) -> bool:
    return false if left.count != right.count
    for index in 0..<left.count |left, right|:
        return false if left[index] != right[index]
    return true

def rejected_without_change(path: darray[u8]&) -> bool can[Memory.Allocate, Abort.Panic]:
    output: mutable darray[u8] = [120, 10]
    accepted: bool = Build::append_include_path(path, &output)
    return not accepted and output.count == 2.usize() and output[0] == 120 and output[1] == 10

def main() -> i64 can[Memory.Allocate, Abort.Panic]:
    safe_path: mutable darray[u8] = [{byte_list(safe_path)}]
    output: mutable darray[u8] = [120, 10]
    expected: mutable darray[u8] = [{byte_list(expected)}]
    return 1 if not Build::append_include_path(safe_path, &output)
    return 2 if not same_bytes(output, expected)

    empty: mutable darray[u8] = []
    return 3 if not rejected_without_change(empty)
    relative: mutable darray[u8] = [114, 101, 108, 97, 116, 105, 118, 101, 47, 115, 111, 117, 114, 99, 101]
    return 4 if not rejected_without_change(relative)
    quoted: mutable darray[u8] = [47, 97, 34, 98]
    return 5 if not rejected_without_change(quoted)
    backslash: mutable darray[u8] = [47, 97, 92, 98]
    return 6 if not rejected_without_change(backslash)

    control: mutable usize = 0.usize()
    while control < 32.usize() |control|:
        invalid: mutable darray[u8] = [47, 120]
        invalid.push(control.u8())
        return 7 if not rejected_without_change(invalid)
        control <- control + 1.usize()
    delete: mutable darray[u8] = [47, 120, 127]
    return 8 if not rejected_without_change(delete)

    exact_limit: mutable darray[u8] = [47]
    while exact_limit.count < 4096.usize() |exact_limit|:
        exact_limit.push(97)
    boundary_output: mutable darray[u8] = []
    return 9 if not Build::append_include_path(exact_limit, &boundary_output)
    return 10 if boundary_output.count != 4107.usize()
    return 11 if boundary_output[0] != 105 or boundary_output[7] != 32 or boundary_output[8] != 34
    for index in 0..<4096.usize() |boundary_output, exact_limit|:
        return 12 if boundary_output[9.usize() + index] != exact_limit[index]
    return 13 if boundary_output[4105] != 34 or boundary_output[4106] != 10

    over_limit: mutable darray[u8] = [47]
    while over_limit.count < 4097.usize() |over_limit|:
        over_limit.push(97)
    return 14 if not rejected_without_change(over_limit)
    return 0
'''


def main() -> int:
    compiler_root_value = os.environ.get("ELISA_COMPILER_ROOT")
    if not compiler_root_value:
        raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
    compiler_root = Path(compiler_root_value).resolve()
    stage1 = Path(os.environ.get("ELISA_STAGE1_BIN", compiler_root / "bin/elisac-stage1")).resolve()
    wrapper = Path(os.environ.get("ELISA_COMPILER_WRAPPER", compiler_root / "scripts/elisac_stage1.sh")).resolve()
    runtime = Path(os.environ.get("ELISA_RUNTIME_OBJ", compiler_root / "build/runtime/elisacore_runtime.o")).resolve()

    for label, path in (
        ("stage1 compiler", stage1),
        ("compiler wrapper", wrapper),
        ("runtime object", runtime),
    ):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}")
    if not os.access(stage1, os.X_OK) or not os.access(wrapper, os.X_OK):
        raise SystemExit("error: Elisa compiler and wrapper must be executable")

    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    compiler_env = dict(os.environ)
    compiler_env["ELISA_STAGE1_BIN"] = str(stage1)
    compiler_env["ELISA_COMPILER_WRAPPER"] = str(wrapper)
    compiler_env["ELISA_RUNTIME_OBJ"] = str(runtime)
    compiler_env.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")

    with tempfile.TemporaryDirectory(prefix="elisapkg-build-include-", dir=BUILD_ROOT) as raw:
        work = Path(raw)
        source = work / "build_include_probe.elisa"
        binary = work / "build_include_probe"
        source.write_text(probe_source(), encoding="utf-8")
        compile_result = subprocess.run(
            [str(wrapper), "-emit", "exe", "-o", str(binary), str(source)],
            cwd=work,
            env=compiler_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
        if compile_result.returncode != 0:
            raise SystemExit(f"error: could not compile include-emission probe:\n{compile_result.stdout}")
        result = subprocess.run(
            [str(binary)],
            cwd=work,
            env=compiler_env,
            timeout=5,
            check=False,
        )
        if result.returncode != 0:
            raise SystemExit(f"error: include-emission probe returned status {result.returncode}")

    print("Elisa aggregate-source include regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
