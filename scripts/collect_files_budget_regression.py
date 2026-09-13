#!/usr/bin/env python3
"""Exercise bounded, deterministic filesystem collection through Elisa FFI."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COMPILER_ROOT = Path(os.environ.get("ELISA_COMPILER_ROOT", ""))
STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1"))
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh"))
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))


def elisa_bytes(value: bytes) -> str:
    return ", ".join(str(byte) for byte in value)


def main() -> int:
    for label, path in (("stage1 compiler", STAGE1), ("compiler wrapper", WRAPPER), ("runtime object", RUNTIME)):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}; set ELISA_COMPILER_ROOT")
    if not os.access(STAGE1, os.X_OK) or not os.access(WRAPPER, os.X_OK):
        raise SystemExit("error: Elisa compiler and wrapper must be executable")

    build_root = ROOT / "build"
    build_root.mkdir(parents=True, exist_ok=True)
    compiler_env = dict(os.environ)
    compiler_env["ELISA_STAGE1_BIN"] = str(STAGE1)
    compiler_env["ELISA_COMPILER_WRAPPER"] = str(WRAPPER)
    compiler_env["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
    compiler_env.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")

    with tempfile.TemporaryDirectory(prefix="elisapkg-collect-files-", dir=build_root) as raw:
        work = Path(raw)
        work.chmod(0o700)
        ordered_root = work / "ordered"
        ordered_root.mkdir(mode=0o700)
        file_names = [f"source-{index:04d}.elisa" for index in range(256)]
        for name in reversed(file_names):
            (ordered_root / name).write_text("package input\n", encoding="ascii")
        (ordered_root / "empty-directory").mkdir()

        stress_root = work / "stress"
        stress_root.mkdir(mode=0o700)
        for index in range(8192):
            (stress_root / f"directory-{index:04d}").mkdir()
            (stress_root / f"credentials-{index:04d}").write_bytes(b"excluded by path policy")

        expected = b"".join(os.fsencode(ordered_root / name) + b"\0" for name in file_names)
        ordered_bytes = os.fsencode(ordered_root) + b"\0"
        stress_bytes = os.fsencode(stress_root) + b"\0"
        source = work / "collect_files_probe.elisa"
        binary = work / "collect_files_probe"
        source.write_text(
            f'''include "{ROOT / "src/platform.elisa"}"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    ordered_root: mutable darray[u8] = [{elisa_bytes(ordered_bytes)}]
    ordered_name: cstr = (&ordered_root[0]).cast[cstr] can Unsafe.PointerCast
    stress_root: mutable darray[u8] = [{elisa_bytes(stress_bytes)}]
    stress_name: cstr = (&stress_root[0]).cast[cstr] can Unsafe.PointerCast
    output: mutable darray[u8] = []
    output.resize({len(expected) + 1})
    output_raw: mutable u8& = (&output[0]).cast[mutable u8&] can Unsafe.PointerCast
    collected: i64 = Platform::pkg_collect_files(ordered_name, output_raw, output.count)
    return 10 if collected < 0
    return 11 if collected < {len(expected)}
    return 12 if collected > {len(expected)}
    expected: mutable darray[u8] = [{elisa_bytes(expected)}]
    for index in 0..<expected.count |output, expected|:
        return 2 if output[index] != expected[index]
    oversized: i64 = Platform::pkg_collect_files(stress_name, output_raw, output.count)
    return 3 if oversized != -75
    return 0
''',
            encoding="utf-8",
        )

        compile_result = subprocess.run(
            [str(WRAPPER), "-emit", "exe", "-o", str(binary), str(source)],
            cwd=work,
            env=compiler_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
        if compile_result.returncode != 0:
            raise SystemExit(f"error: could not compile collector probe:\n{compile_result.stdout}")
        result = subprocess.run([str(binary)], cwd=work, env=compiler_env, timeout=30, check=False)
        if result.returncode != 0:
            raise SystemExit(f"error: collector probe failed at case {result.returncode}")

    print("Elisa bounded file collector regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
