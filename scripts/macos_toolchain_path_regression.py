#!/usr/bin/env python3
"""Check the macOS SDK/developer path resolver through the public FFI facade."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    if sys.platform != "darwin":
        print("skip: macOS toolchain path probe requires Darwin")
        return 0

    compiler_root = Path(os.environ.get("ELISA_COMPILER_ROOT", ""))
    wrapper = Path(os.environ.get("ELISAPKG_COMPILER", compiler_root / "scripts/elisac_stage1.sh"))
    stage1 = Path(os.environ.get("ELISA_STAGE1_BIN", compiler_root / "bin/elisac-stage1"))
    runtime = Path(os.environ.get("ELISA_RUNTIME_OBJ", compiler_root / "build/runtime/elisacore_runtime.o"))
    for label, path in (("compiler wrapper", wrapper), ("stage1 compiler", stage1), ("runtime object", runtime)):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}; set ELISA_COMPILER_ROOT")
    if not os.access(wrapper, os.X_OK) or not os.access(stage1, os.X_OK):
        raise SystemExit("error: Elisa compiler and wrapper must be executable")

    candidates = (
        Path("/Library/Developer/CommandLineTools"),
        Path("/Applications/Xcode.app/Contents/Developer"),
    )
    developer = next(
        (
            candidate.resolve()
            for candidate in candidates
            if (candidate / "SDKs/MacOSX.sdk").is_dir()
            or (candidate / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk").is_dir()
        ),
        None,
    )
    if developer is None:
        raise SystemExit("error: no supported Command Line Tools or Xcode macOS SDK is installed")

    source_text = f'''include "{ROOT / "src/platform.elisa"}"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    sdk: mutable darray[u8] = []
    developer: mutable darray[u8] = []
    resolved: bool = Platform::pkg_macos_toolchain_paths(&sdk, &developer)
    if Platform::pkg_getenv("ELISAPKG_EXPECT_INVALID_TOOLCHAIN") is invalid_case:
        return 0 if not resolved
        return 2
    return 1 if not resolved or sdk.count == 0.usize() or developer.count == 0.usize()
    developer_name: cstr = (&developer[0]).cast[cstr] can Unsafe.PointerCast
    expected_developer: cstr = "{developer}"
    return 3 if not Platform::pkg_cstr_equal(developer_name, expected_developer)
    sdk_name: mutable darray[u8] = []
    for index in 0..<sdk.count |sdk_name, sdk|:
        sdk_name.push(sdk[index])
    sdk_name.push(0)
    return 4 if Platform::pkg_is_directory((&sdk_name[0]).cast[cstr] can Unsafe.PointerCast) != 1
    return 0
'''

    compiler_env = dict(os.environ)
    compiler_env.pop("ELISAPKG_EXPECT_INVALID_TOOLCHAIN", None)
    compiler_env["DEVELOPER_DIR"] = str(developer)
    compiler_env["ELISA_STAGE1_BIN"] = str(stage1)
    compiler_env["ELISA_RUNTIME_OBJ"] = str(runtime)
    compiler_env.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")

    build_root = ROOT / "build"
    build_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elisapkg-macos-toolchain-", dir=build_root) as raw:
        work = Path(raw)
        work.chmod(0o700)
        source = work / "toolchain_probe.elisa"
        binary = work / "toolchain_probe"
        source.write_text(source_text, encoding="utf-8")
        compiled = subprocess.run(
            [str(wrapper), "-emit", "exe", "-o", str(binary), str(source)],
            cwd=work,
            env=compiler_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
        if compiled.returncode != 0:
            raise SystemExit(f"error: could not compile macOS toolchain probe:\n{compiled.stdout}")

        valid = subprocess.run([str(binary)], cwd=work, env=compiler_env, timeout=20, check=False)
        invalid_env = dict(compiler_env)
        invalid_env["DEVELOPER_DIR"] = "/tmp"
        invalid_env["ELISAPKG_EXPECT_INVALID_TOOLCHAIN"] = "1"
        invalid = subprocess.run([str(binary)], cwd=work, env=invalid_env, timeout=20, check=False)
        if valid.returncode != 0 or invalid.returncode != 0:
            raise SystemExit(
                "error: toolchain path probe failed "
                f"(supported environment exit {valid.returncode}, unsupported environment exit {invalid.returncode})"
            )

    print("macOS toolchain path regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
