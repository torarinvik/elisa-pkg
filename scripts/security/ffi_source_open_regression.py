#!/usr/bin/env python3
"""Exercise native source opens against ordinary and special filesystem nodes."""

from __future__ import annotations

import os
from pathlib import Path
import shlex
import socket
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
COMPILER_ROOT = Path(os.environ.get("ELISA_COMPILER_ROOT", ""))
STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1"))
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh"))
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))
EXECUTOR = shlex.split(os.environ.get("ELISAPKG_TEST_EXECUTOR", ""))


def elisa_string(value: str | Path) -> str:
    """Quote an absolute path as an Elisa string literal."""
    text = str(value)
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def source_for(sticky_file: Path, good_source: Path, good_destination: Path,
               special_source: Path, special_destination: Path) -> str:
    return "\n".join(
        [
            f"include {elisa_string(ROOT / 'src/platform.elisa')}",
            "",
            "def rejected_source(path: cstr, check_chmod: bool) -> bool can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:",
            "    return false if Platform::pkg_access(path, 1) == 0",
            "    return false if Platform::pkg_package_file_size(path) >= 0",
            "    buffer: mutable darray[u8] = []",
            "    buffer.resize(64)",
            "    raw: mutable u8& = (&buffer[0]).cast[mutable u8&] can Unsafe.PointerCast",
            "    return false if Platform::pkg_read_package_file(path, raw, buffer.count) >= 0",
            "    if check_chmod:",
            "        return false if Platform::pkg_chmod(path, 384.u16()) == 0",
            "    return true",
            "",
            "def accepted_source(path: cstr) -> bool can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:",
            "    return Platform::pkg_package_file_size(path) == 8 and Platform::pkg_access(path, 1) == 0",
            "",
            "def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:",
            '    return 1 if Platform::pkg_package_file_size("private/regular") != 8',
            "    buffer: mutable darray[u8] = []",
            "    buffer.resize(9)",
            "    raw: mutable u8& = (&buffer[0]).cast[mutable u8&] can Unsafe.PointerCast",
            '    return 4 if Platform::pkg_read_package_file("private/regular", raw, buffer.count) != 8',
            '    return 5 if Platform::pkg_access("private/regular", 1) != 0',
            '    return 20 if Platform::pkg_access("./private/../private/regular", 0) != 0',
            '    return 6 if Platform::pkg_chmod("private/regular", 448.u16()) != 0',
            '    return 10 if not rejected_source("private/link", true)',
            '    return 19 if not rejected_source("private/directory-link/payload", false)',
            '    return 11 if not rejected_source("private/fifo", true)',
            '    return 12 if not rejected_source("private/socket", true)',
            '    return 13 if not rejected_source("/dev/null", false)',
            '    return 14 if not rejected_source("group-writable/file", true)',
            '    return 15 if not rejected_source("world-writable/file", true)',
            f"    return 16 if not accepted_source({elisa_string(sticky_file)})",
            f"    good_snapshot: i64 = Platform::pkg_snapshot_package_tree({elisa_string(good_source)}, {elisa_string(good_destination)}, 67108864.usize())",
            "    return 17 if good_snapshot <= 0",
            f"    special_snapshot: i64 = Platform::pkg_snapshot_package_tree({elisa_string(special_source)}, {elisa_string(special_destination)}, 67108864.usize())",
            "    return 18 if special_snapshot >= 0",
            "    return 0",
            "",
        ]
    )


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

    sticky_root = Path("/tmp").resolve(strict=True)
    sticky_stat = sticky_root.stat()
    if not stat.S_ISDIR(sticky_stat.st_mode) or not sticky_stat.st_mode & stat.S_ISVTX:
        raise SystemExit(f"error: /tmp must resolve to a sticky directory on this platform: {sticky_root}")

    sticky_file: Path | None = None
    try:
        # Keep the Unix-domain socket fixture short enough for sun_path on
        # both supported OSes; the project checkout itself can have a long
        # path and should not determine the fixture length.
        with tempfile.TemporaryDirectory(prefix="elisapkg-source-open-", dir=sticky_root) as directory:
            work = Path(directory).resolve()
            private = work / "private"
            private.mkdir(mode=0o700)
            private.chmod(0o700)
            (private / "regular").write_bytes(b"regular\n")
            (private / "regular").chmod(0o700)
            (private / "link").symlink_to("regular")
            target_directory = private / "target-directory"
            target_directory.mkdir(mode=0o700)
            (target_directory / "payload").write_bytes(b"must stay beneath a real directory\n")
            (private / "directory-link").symlink_to("target-directory", target_is_directory=True)
            os.mkfifo(private / "fifo", 0o600)

            unix_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                unix_socket.bind(str(private / "socket"))
            finally:
                unix_socket.close()

            for name, mode in (("group-writable", 0o770), ("world-writable", 0o777)):
                writable = work / name
                writable.mkdir(mode=0o700)
                (writable / "file").write_bytes(b"must be rejected\n")
                (writable / "file").chmod(0o700)
                writable.chmod(mode)

            sticky_fd, sticky_name = tempfile.mkstemp(prefix="elisapkg-source-open-", dir=sticky_root)
            sticky_file = Path(sticky_name)
            with os.fdopen(sticky_fd, "wb") as stream:
                stream.write(b"sticky parent\n")
            sticky_file.chmod(0o700)

            good_source = work / "snapshot-good-source"
            good_destination = work / "snapshot-good-destination"
            special_source = work / "snapshot-special-source"
            special_destination = work / "snapshot-special-destination"
            for path in (good_source, good_destination, special_source, special_destination):
                path.mkdir(mode=0o700)
                path.chmod(0o700)
            (good_source / "payload").write_bytes(b"snapshot payload\n")
            (special_source / "payload").write_bytes(b"snapshot payload\n")
            os.mkfifo(special_source / "fifo", 0o600)

            probe = work / "source_open_probe.elisa"
            binary = work / "source_open_probe"
            probe.write_text(
                source_for(sticky_file, good_source, good_destination, special_source, special_destination),
                encoding="utf-8",
            )
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
                raise SystemExit(f"error: could not compile source-open probe:\n{compile_result.stdout}")

            try:
                result = subprocess.run([*EXECUTOR, str(binary)], cwd=work, env=environment, timeout=15, check=False)
            except subprocess.TimeoutExpired as error:
                raise SystemExit("error: source-open probe blocked while inspecting a special file") from error
            if result.returncode != 0:
                failures = {
                    1: "regular package file size was not reported",
                    4: "regular pkg_read_package_file failed",
                    5: "regular pkg_access rejected the executable file",
                    6: "pkg_chmod rejected a regular file",
                    10: "final-component symlink was accepted by a source API",
                    11: "FIFO was accepted by a source API",
                    12: "Unix-domain socket was accepted by a source API",
                    13: "/dev/null was accepted by a source API",
                    14: "group-writable parent was accepted by a source API",
                    15: "world-writable parent was accepted by a source API",
                    16: "regular file in sticky /tmp was rejected",
                    17: "regular package snapshot failed",
                    18: "snapshot accepted a source tree containing a FIFO",
                    19: "intermediate directory symlink was followed by a source API",
                    20: "local source traversal rejected a valid parent component",
                }
                failure = failures.get(result.returncode, "probe returned an unexpected status")
                raise SystemExit(f"error: {failure} (probe status {result.returncode})")

            copied_payload = good_destination / "payload"
            if not copied_payload.is_file() or copied_payload.is_symlink() or copied_payload.read_bytes() != b"snapshot payload\n":
                raise SystemExit("error: regular package snapshot did not preserve its payload")
            if any(special_destination.iterdir()):
                raise SystemExit("error: rejected special-file snapshot left staged entries behind")

    finally:
        if sticky_file is not None:
            try:
                sticky_file.unlink()
            except FileNotFoundError:
                pass

    print("Elisa native source-open regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
