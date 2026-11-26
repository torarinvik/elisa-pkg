#!/usr/bin/env python3
"""Verify receipt-owned removal refuses an inode swapped after verification."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
COMPILER_ROOT = Path(os.environ.get("ELISA_COMPILER_ROOT", ""))


def probe_source(device: int, inode: int, target: Path, backup: Path) -> str:
    return f'''include "{ROOT / "src/platform.elisa"}"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    return 1 if Platform::pkg_unlink_file_identity("{target}", {device}.u64(), {inode}.u64()) == 0
    return 2 if Platform::pkg_package_file_size("{target}") != 11
    return 3 if Platform::pkg_unlink_file_identity("{backup}", {device}.u64(), {inode}.u64()) != 0
    return 4 if Platform::pkg_package_file_size("{backup}") != -2
    return 0
'''


def main() -> int:
    if not (COMPILER_ROOT / "scripts/elisac_stage1.sh").is_file():
        raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
    stage1 = COMPILER_ROOT / "scripts/elisac_stage1.sh"
    env = dict(os.environ)
    env["ELISA_STAGE1_BIN"] = env.get("ELISA_STAGE1_BIN", str(COMPILER_ROOT / "bin/elisac-stage1"))
    env["ELISA_RUNTIME_OBJ"] = env.get("ELISA_RUNTIME_OBJ", str(COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))
    env["ELISA_ALLOW_STALE_STAGE1"] = env.get("ELISA_ALLOW_STALE_STAGE1", "0")

    # The identity-safe unlink requires an euid-owned trusted parent chain.
    # Keep the probe out of potentially shared checkout mounts.
    with tempfile.TemporaryDirectory(prefix="elisapkg-install-identity-", dir=Path.home()) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        target = directory / "target"
        backup = directory / "backup"
        target.write_bytes(b"verified original inode\n")
        target.chmod(0o600)
        identity = os.lstat(target)
        device = identity.st_dev
        inode = identity.st_ino
        target.rename(backup)
        target.write_bytes(b"replacement")
        target.chmod(0o600)
        source = directory / "identity-probe.elisa"
        binary = directory / "identity-probe"
        source.write_text(probe_source(device, inode, target, backup), encoding="utf-8")

        compile_result = subprocess.run(
            [str(stage1), "-emit", "exe", "-o", str(binary), str(source)],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
        if compile_result.returncode != 0:
            raise SystemExit(f"error: could not compile identity probe:\n{compile_result.stdout}")

        result = subprocess.run([str(binary)], env=env, timeout=30, check=False)
        if result.returncode != 0:
            raise SystemExit(f"error: identity probe returned {result.returncode}")
        if target.read_bytes() != b"replacement" or backup.exists():
            raise SystemExit("error: identity removal changed the replacement or retained the verified original")

    print("Elisa install identity regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
