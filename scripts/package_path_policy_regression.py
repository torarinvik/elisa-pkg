#!/usr/bin/env python3
"""Compile and exercise the shared case-insensitive reserved-path policy."""

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
    paths = (
        (b".ELISAPKG/cache/blob", True),
        (b"BUILD/stale-output.elisa", True),
        (b"TaRgEt/object.o", True),
        (b".GIT/config", True),
        (b"src/.Hg/hgrc", True),
        (b"src/.SvN/wc.db", True),
        (b"src/implementation_plan.MD", True),
        (b"src/IMPLEMENTATION_PLAN.md/child.elisa", True),
        (b"src/.ELISAPKG/nested-source.elisa", False),
        (b"src/.BUILD/nested-source.elisa", False),
        (b"src/.TARGET/nested-source.elisa", False),
        (b"src/main.elisa", False),
        (b"src/my.git/data.elisa", False),
    )
    checks = "\n".join(
        f"    path_{index}: mutable darray[u8] = [{byte_list(path)}]\n"
        f"    return {index + 1} if PackagePathPolicy::reserved_source_path_forbidden(path_{index}) != {str(expected).lower()}"
        for index, (path, expected) in enumerate(paths)
    )
    return f'''include "{ROOT / 'src' / 'package_path_policy.elisa'}"

def main() -> i64:
{checks}
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
    for label, path in (("stage1 compiler", stage1), ("compiler wrapper", wrapper), ("runtime object", runtime)):
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
    with tempfile.TemporaryDirectory(prefix="elisapkg-path-policy-", dir=BUILD_ROOT) as raw:
        work = Path(raw)
        source = work / "reserved_path_probe.elisa"
        binary = work / "reserved_path_probe"
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
            raise SystemExit(f"error: could not compile path-policy probe:\n{compile_result.stdout}")
        result = subprocess.run([str(binary)], cwd=work, env=compiler_env, timeout=5, check=False)
        if result.returncode != 0:
            raise SystemExit(f"error: reserved path probe failed at case {result.returncode}")
    print("Elisa reserved path policy regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
