#!/usr/bin/env python3
"""Exercise the native ustar extractor through the public Elisa platform API."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COMPILER_ROOT = Path(os.environ.get("ELISA_COMPILER_ROOT", ""))
STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1"))
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh"))
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))


def octal_field(value: int, width: int) -> bytes:
    encoded = f"{value:0{width - 1}o}".encode("ascii") + b"\0"
    if len(encoded) != width:
        raise ValueError("ustar numeric field overflow")
    return encoded


def make_header(
    name: bytes,
    content_size: int,
    *,
    typeflag: bytes = b"0",
    linkname: bytes = b"",
    corrupt_checksum: bool = False,
) -> bytes:
    if not name or len(name) >= 100 or len(typeflag) != 1 or len(linkname) >= 100:
        raise ValueError("invalid test header input")
    header = bytearray(512)
    header[: len(name)] = name
    header[100:108] = octal_field(0o644, 8)
    header[108:116] = octal_field(0, 8)
    header[116:124] = octal_field(0, 8)
    header[124:136] = octal_field(content_size, 12)
    header[136:148] = octal_field(0, 12)
    header[148:156] = b" " * 8
    header[156] = typeflag[0]
    header[157 : 157 + len(linkname)] = linkname
    header[257:263] = b"ustar\0"
    header[263:265] = b"00"
    checksum = sum(header)
    header[148:155] = octal_field(checksum, 7)
    header[155] = 32
    if corrupt_checksum:
        header[148] = ord("1") if header[148] != ord("1") else ord("2")
    return bytes(header)


def make_archive(entries: list[tuple[bytes, bytes, bytes, bytes, bool]]) -> bytes:
    """Build strict ustar records: (name, payload, typeflag, linkname, bad sum)."""
    archive = bytearray()
    for name, payload, typeflag, linkname, corrupt_checksum in entries:
        archive.extend(
            make_header(
                name,
                len(payload),
                typeflag=typeflag,
                linkname=linkname,
                corrupt_checksum=corrupt_checksum,
            )
        )
        archive.extend(payload)
        archive.extend(b"\0" * ((-len(payload)) % 512))
    archive.extend(b"\0" * 1024)
    return bytes(archive)


def regular(name: str, payload: bytes) -> tuple[bytes, bytes, bytes, bytes, bool]:
    return name.encode("ascii"), payload, b"0", b"", False


def special(
    name: str, typeflag: bytes, linkname: bytes = b""
) -> tuple[bytes, bytes, bytes, bytes, bool]:
    return name.encode("ascii"), b"", typeflag, linkname, False


def source_for(cases: list[tuple[str, Path, Path, bool, bytes]]) -> str:
    lines = [
        f'include "{ROOT / "src/platform.elisa"}"',
        "",
        "def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:",
    ]
    for index, (label, destination, archive_path, should_succeed, destination_bytes) in enumerate(cases, 1):
        archive_path_values = ", ".join(str(byte) for byte in os.fsencode(archive_path) + b"\0")
        destination_values = ", ".join(str(byte) for byte in destination_bytes)
        lines.extend(
            [
                f"    archive_path_{index}: mutable darray[u8] = [{archive_path_values}]",
                f"    archive_name_{index}: cstr = (&archive_path_{index}[0]).cast[cstr] can Unsafe.PointerCast",
                f"    archive_size_{index}: i64 = Platform::pkg_package_file_size(archive_name_{index})",
                f"    return {index} if archive_size_{index} < 0 or archive_size_{index} > 1048576",
                f"    archive_{index}: mutable darray[u8] = []",
                f"    archive_{index}.resize(archive_size_{index}.usize() + 1.usize())",
                f"    archive_raw_{index}: mutable u8& = (&archive_{index}[0]).cast[mutable u8&] can Unsafe.PointerCast",
                f"    archive_read_{index}: i64 = Platform::pkg_read_package_file(archive_name_{index}, archive_raw_{index}, archive_{index}.count)",
                f"    return {index} if archive_read_{index} != archive_size_{index}",
                f"    archive_{index}.resize(archive_read_{index}.usize())",
                f"    destination_{index}: mutable darray[u8] = [{destination_values}]",
                f"    result_{index}: i64 = Platform::pkg_extract_ustar(archive_{index}, destination_{index})",
            ]
        )
        if should_succeed:
            lines.append(f"    return {index} if result_{index} != 0")
        else:
            lines.append(f"    return {index} if result_{index} == 0")
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
    if not STAGE1.is_file() or not os.access(STAGE1, os.X_OK) or not os.access(WRAPPER, os.X_OK):
        raise SystemExit("error: Elisa stage1 compiler and wrapper must be executable")

    (ROOT / "build").mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment["ELISA_STAGE1_BIN"] = str(STAGE1)
    environment["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
    environment.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")

    valid_payloads = {
        "src/nested/main.elisa": b"def main() -> i64:\n    return 0\n",
        "share/deep/message.txt": b"nested package data\n",
    }
    # Every record adds 31 unique implicit directories and one regular file.
    # The stream stays small while its extracted filesystem tree exceeds the
    # native extractor's aggregate-node budget.
    node_budget_entries = [
        regular(
            f"node{index:03d}/" + "/".join(["x"] * 30) + "/file",
            b"x",
        )
        for index in range(129)
    ]

    with tempfile.TemporaryDirectory(prefix="elisapkg-archive-extract-", dir=ROOT / "build") as temporary:
        work = Path(temporary)
        work.chmod(0o700)

        case_specs: list[tuple[str, list[tuple[bytes, bytes, bytes, bytes, bool]], bool]] = [
            (
                "valid-nested",
                [regular(name, payload) for name, payload in valid_payloads.items()],
                True,
            ),
            (
                "traversal",
                [regular("safe.txt", b"cleanup me"), regular("../escape", b"outside")],
                False,
            ),
            (
                "symbolic-link",
                [regular("safe.txt", b"cleanup me"), special("link", b"2", b"../escape")],
                False,
            ),
            (
                "hard-link",
                [regular("safe.txt", b"cleanup me"), special("hardlink", b"1", b"safe.txt")],
                False,
            ),
            (
                "directory-type",
                [regular("safe.txt", b"cleanup me"), special("directory", b"5")],
                False,
            ),
            (
                "duplicate-name",
                [regular("duplicate.txt", b"first"), regular("duplicate.txt", b"second")],
                False,
            ),
            (
                "file-prefix-collision",
                [regular("node", b"file first"), regular("node/child", b"child")],
                False,
            ),
            (
                "directory-prefix-collision",
                [regular("node/child", b"child first"), regular("node", b"file")],
                False,
            ),
            (
                "bad-late-checksum",
                [regular("safe.txt", b"cleanup me"), (b"bad-checksum", b"x", b"0", b"", True)],
                False,
            ),
            (
                "embedded-nul-destination",
                [regular(name, payload) for name, payload in valid_payloads.items()],
                False,
            ),
            ("expanded-node-budget", node_budget_entries, False),
        ]

        fixtures = work / "fixtures"
        fixtures.mkdir(mode=0o700)
        cases: list[tuple[str, Path, Path, bool, bytes]] = []
        outside_sentinel = work / "traversal" / "escape"
        for label, entries, should_succeed in case_specs:
            case_root = work / label
            case_root.mkdir(mode=0o700)
            stage = case_root / "stage"
            stage.mkdir(mode=0o700)
            stage.chmod(0o700)
            if stat.S_IMODE(stage.stat().st_mode) != 0o700:
                raise SystemExit(f"error: test staging directory is not owner-only: {stage}")
            archive_path = fixtures / f"{label}.tar"
            archive_path.write_bytes(make_archive(entries))
            archive_path.chmod(0o600)
            destination_bytes = os.fsencode(stage)
            if label == "embedded-nul-destination":
                destination_bytes += b"\0/truncated-path-must-not-be-used"
            cases.append((label, stage, archive_path, should_succeed, destination_bytes))

        outside_sentinel.write_bytes(b"must remain outside extraction\n")
        source = work / "archive_extract_probe.elisa"
        binary = work / "archive_extract_probe"
        source.write_text(source_for(cases), encoding="utf-8")
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
            raise SystemExit(f"error: could not compile archive extractor probe:\n{compile_result.stdout}")

        run_result = subprocess.run([str(binary)], cwd=work, env=environment, timeout=60, check=False)
        if run_result.returncode != 0:
            raise SystemExit(f"error: archive extractor probe returned {run_result.returncode}")

        for label, stage, _, should_succeed, _ in cases:
            if should_succeed:
                for relative, expected in valid_payloads.items():
                    actual_path = stage / relative
                    if not actual_path.is_file() or actual_path.is_symlink() or actual_path.read_bytes() != expected:
                        raise SystemExit(f"error: valid extraction produced incorrect file: {actual_path}")
            elif any(stage.iterdir()):
                leftovers = ", ".join(sorted(str(path.relative_to(stage)) for path in stage.rglob("*")))
                raise SystemExit(f"error: rejected {label} archive left staging entries: {leftovers}")

        if outside_sentinel.read_bytes() != b"must remain outside extraction\n":
            raise SystemExit("error: traversal archive changed the file outside its staging root")
        if (work / "escape").exists():
            raise SystemExit("error: traversal archive created a file outside its staging root")

    print("Elisa native archive extraction regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
