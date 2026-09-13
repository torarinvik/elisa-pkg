#!/usr/bin/env python3
"""Check effective execute access and no-follow behavior through the Elisa FFI."""

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


def source_for(check_group_only: bool, selected_llvm: Path | None) -> str:
    lines = [
        f'include "{ROOT / "src/platform.elisa"}"',
        "",
        "def main() -> i64:",
        '    return 1 if Platform::pkg_access("exec-target", 1) != 0',
        '    return 2 if Platform::pkg_access("exec-link", 1) == 0',
    ]
    if check_group_only:
        lines.append('    return 3 if Platform::pkg_access("group-only", 1) == 0')
    if selected_llvm is not None:
        lines.append(f'    return 4 if Platform::pkg_access("{selected_llvm}", 1) != 0')
    lines.append("    return 0")
    return "\n".join(lines) + "\n"


def main() -> int:
    for label, path in (
        ("compiler root", COMPILER_ROOT),
        ("stage1 compiler", STAGE1),
        ("compiler wrapper", WRAPPER),
        ("runtime object", RUNTIME),
    ):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}; set ELISA_COMPILER_ROOT")
    if not os.access(STAGE1, os.X_OK) or not os.access(WRAPPER, os.X_OK):
        raise SystemExit("error: Elisa compiler and wrapper must be executable")

    (ROOT / "build").mkdir(parents=True, exist_ok=True)
    check_group_only = os.geteuid() != 0
    selected_llvm = None
    for candidate in (Path("/opt/homebrew/opt/llvm/bin/clang"), Path("/usr/local/opt/llvm/bin/clang")):
        if candidate.exists():
            resolved = candidate.resolve(strict=True)
            if resolved.is_file() and os.access(resolved, os.X_OK):
                selected_llvm = resolved
                break
    with tempfile.TemporaryDirectory(prefix="elisapkg-access-", dir=ROOT / "build") as raw:
        work = Path(raw)
        executable = work / "exec-target"
        executable.write_bytes(b"executable permission probe\n")
        executable.chmod(0o700)
        (work / "exec-link").symlink_to(executable.name)

        if check_group_only:
            # The process owns this file, so POSIX's owner class applies and
            # its missing owner-execute bit must deny X_OK even though the
            # group-execute bit is set. A mode-bit-only probe falsely accepts it.
            group_only = work / "group-only"
            group_only.write_bytes(b"not executable by its owner\n")
            group_only.chmod(0o410)

        probe = work / "access_probe.elisa"
        binary = work / "access_probe"
        probe.write_text(source_for(check_group_only, selected_llvm), encoding="utf-8")
        environment = dict(os.environ)
        environment["ELISA_STAGE1_BIN"] = str(STAGE1)
        environment["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
        environment.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
        compile_result = subprocess.run(
            [str(WRAPPER), "-emit", "exe", "-o", str(binary), str(probe)],
            cwd=work,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
        if compile_result.returncode != 0:
            raise SystemExit(f"error: could not compile execute-access probe:\n{compile_result.stdout}")
        result = subprocess.run([str(binary)], cwd=work, env=environment, timeout=5, check=False)
        if result.returncode == 1:
            raise SystemExit("error: effective execute access rejected the owner-executable file")
        if result.returncode == 2:
            raise SystemExit("error: execute access followed a final-component symlink")
        if result.returncode == 3:
            raise SystemExit("error: execute access accepted a group-only mode bit for its owner")
        if result.returncode == 4:
            raise SystemExit("error: execute access rejected the selected Homebrew LLVM executable")
        if result.returncode != 0:
            raise SystemExit(f"error: execute-access probe returned unexpected status {result.returncode}")

    if check_group_only:
        print("Elisa effective execute-access regression passed")
    else:
        print("Elisa execute-access regression passed (group-only case skipped for root)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
