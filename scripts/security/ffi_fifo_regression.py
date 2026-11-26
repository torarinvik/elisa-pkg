#!/usr/bin/env python3
"""Ensure regular-file probes through the native FFI never block on a FIFO."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
compiler_root_text = os.environ.get("ELISA_COMPILER_ROOT", "")
if not compiler_root_text:
    raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
COMPILER_ROOT = Path(compiler_root_text)

STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1"))
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh"))
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))


def main() -> int:
    for label, path in (("stage1 compiler", STAGE1), ("compiler wrapper", WRAPPER), ("runtime object", RUNTIME)):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}")
    if not os.access(STAGE1, os.X_OK) or not os.access(WRAPPER, os.X_OK):
        raise SystemExit("error: Elisa compiler and wrapper must be executable")

    (ROOT / "build").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elisapkg-fifo-", dir=ROOT / "build") as directory:
        work = Path(directory)
        (work / "source").write_bytes(b"regular source\n")
        os.mkfifo(work / "destination", 0o600)
        shared = work / "shared"
        shared.mkdir(mode=0o700)
        (shared / "rename-source").write_bytes(b"rename source\n")
        (shared / "link-source").write_bytes(b"link source\n")
        os.chmod(shared, 0o777)
        probe = work / "fifo_probe.elisa"
        binary = work / "fifo_probe"
        probe.write_text(
            f'include "{ROOT / "src/platform.elisa"}"\n\n'
            'def main() -> i64:\n'
            '    result: i64 = Platform::rename_path("source", "destination")\n'
            '    return 1 if result != -21\n'
            '    rename_result: i64 = Platform::rename_path("shared/rename-source", "shared/rename-destination")\n'
            '    return 2 if rename_result != -13\n'
            '    link_result: i64 = Platform::create_hard_link("shared/link-source", "shared/link-destination")\n'
            '    return 3 if link_result != -13\n'
            '    return 0\n',
            encoding="utf-8",
        )
        environment = dict(os.environ)
        environment["ELISA_STAGE1_BIN"] = str(STAGE1)
        environment["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
        environment.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
        subprocess.run(
            [str(WRAPPER), "-emit", "exe", "-o", str(binary), str(probe)],
            cwd=work,
            env=environment,
            check=True,
            timeout=120,
        )
        try:
            result = subprocess.run([str(binary)], cwd=work, timeout=3, check=False)
        except subprocess.TimeoutExpired as error:
            raise SystemExit("error: rename_path blocked while probing a FIFO destination") from error
        if result.returncode != 0:
            raise SystemExit(f"error: rename_path returned {result.returncode}, expected rejection status 0")
        if not (work / "destination").is_fifo() or not (work / "source").is_file():
            raise SystemExit("error: FIFO probe unexpectedly changed either path")
        if (shared / "rename-source").read_bytes() != b"rename source\n" or (shared / "rename-destination").exists():
            raise SystemExit("error: rename_path modified a source inside an untrusted parent")
        if (shared / "link-source").read_bytes() != b"link source\n" or (shared / "link-destination").exists():
            raise SystemExit("error: create_hard_link modified a source inside an untrusted parent")
    print("Elisa FFI FIFO probe passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
