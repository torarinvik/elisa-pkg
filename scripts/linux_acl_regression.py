#!/usr/bin/env python3
"""Check Linux POSIX ACLs through the descriptor-based Elisa trust boundary."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COMPILER_ROOT = Path(os.environ.get("ELISA_COMPILER_ROOT", ""))
STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1"))
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh"))
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))
EXECUTOR = shlex.split(os.environ.get("ELISAPKG_TEST_EXECUTOR", ""))
ACL_VERSION = 2
ACL_USER_OBJ = 1
ACL_USER = 2
ACL_GROUP_OBJ = 4
ACL_GROUP = 8
ACL_MASK = 16
ACL_OTHER = 32
ACL_UNDEFINED_ID = 0xFFFFFFFF


def acl(entries: list[tuple[int, int, int]]) -> bytes:
    return struct.pack("<I", ACL_VERSION) + b"".join(struct.pack("<HHI", *entry) for entry in entries)


def main() -> int:
    if os.uname().sysname != "Linux":
        print("skip: Linux POSIX ACL probe requires Linux")
        return 0
    for label, path in (("stage1 compiler", STAGE1), ("compiler wrapper", WRAPPER), ("runtime object", RUNTIME)):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}; set ELISA_COMPILER_ROOT")
    if not os.access(STAGE1, os.X_OK) or not os.access(WRAPPER, os.X_OK):
        raise SystemExit("error: Elisa compiler and wrapper must be executable")

    with tempfile.TemporaryDirectory(prefix="elisapkg-linux-acl-", dir=ROOT) as raw:
        work = Path(raw)
        work.chmod(0o700)
        clean_directory = work / "clean-directory"
        clean_directory.mkdir(mode=0o700)
        named_directory = work / "named-acl-directory"
        named_directory.mkdir(mode=0o700)
        default_directory = work / "default-acl-directory"
        default_directory.mkdir(mode=0o700)
        clean_file = work / "clean-key"
        clean_file.write_bytes(bytes(range(32)))
        clean_file.chmod(0o600)
        named_file = work / "named-acl-key"
        named_file.write_bytes(bytes(range(32)))
        named_file.chmod(0o600)

        user_id = 65534
        os.setxattr(
            named_directory,
            "system.posix_acl_access",
            acl(
                [
                    (ACL_USER_OBJ, 7, ACL_UNDEFINED_ID),
                    (ACL_USER, 5, user_id),
                    (ACL_GROUP_OBJ, 0, ACL_UNDEFINED_ID),
                    (ACL_MASK, 5, ACL_UNDEFINED_ID),
                    (ACL_OTHER, 0, ACL_UNDEFINED_ID),
                ]
            ),
        )
        os.setxattr(
            named_file,
            "system.posix_acl_access",
            acl(
                [
                    (ACL_USER_OBJ, 6, ACL_UNDEFINED_ID),
                    (ACL_USER, 4, user_id),
                    (ACL_GROUP_OBJ, 0, ACL_UNDEFINED_ID),
                    (ACL_MASK, 4, ACL_UNDEFINED_ID),
                    (ACL_OTHER, 0, ACL_UNDEFINED_ID),
                ]
            ),
        )
        os.setxattr(
            default_directory,
            "system.posix_acl_default",
            acl(
                [
                    (ACL_USER_OBJ, 7, ACL_UNDEFINED_ID),
                    (ACL_USER, 6, user_id),
                    (ACL_GROUP_OBJ, 0, ACL_UNDEFINED_ID),
                    (ACL_MASK, 6, ACL_UNDEFINED_ID),
                    (ACL_OTHER, 0, ACL_UNDEFINED_ID),
                ]
            ),
        )

        # These are read-only ACL grants: the group-class mode bits remain
        # non-writable, so the trust probe must reject them by inspecting ACL
        # records on the opened descriptor rather than relying on chmod bits.
        if named_directory.stat().st_mode & 0o020 or named_file.stat().st_mode & 0o020:
            raise SystemExit("error: fixture ACL unexpectedly enabled group write")

        source = work / "linux_acl_probe.elisa"
        binary = work / "linux_acl_probe"
        paths = [clean_directory, named_directory, default_directory, clean_file, named_file]
        path_literals = [json.dumps(str(path)) for path in paths]
        source.write_text(
            f'''include "{ROOT / "src/platform.elisa"}"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    return 1 if Platform::pkg_is_trusted_directory({path_literals[0]}) != 1
    return 2 if Platform::pkg_is_trusted_directory({path_literals[1]}) != 0
    return 3 if Platform::pkg_is_trusted_directory({path_literals[2]}) != 0
    clean_key: mutable darray[u8] = []
    clean_key.resize(33)
    clean_raw: mutable u8& = (&clean_key[0]).cast[mutable u8&] can Unsafe.PointerCast
    return 4 if Platform::pkg_read_trusted_file({path_literals[3]}, clean_raw, clean_key.count) != 32
    return 5 if clean_key[0] != 0 or clean_key[31] != 31
    named_key: mutable darray[u8] = []
    named_key.resize(33)
    named_raw: mutable u8& = (&named_key[0]).cast[mutable u8&] can Unsafe.PointerCast
    return 6 if Platform::pkg_read_trusted_file({path_literals[4]}, named_raw, named_key.count) >= 0
    return 0
''',
            encoding="utf-8",
        )
        compiler_env = dict(os.environ)
        compiler_env["ELISA_STAGE1_BIN"] = str(STAGE1)
        compiler_env["ELISA_COMPILER_WRAPPER"] = str(WRAPPER)
        compiler_env["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
        compiler_env.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
        result = subprocess.run(
            [str(WRAPPER), "-emit", "exe", "-o", str(binary), str(source)],
            cwd=work,
            env=compiler_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
        if result.returncode != 0:
            raise SystemExit(f"error: could not compile Linux ACL probe:\n{result.stdout}")
        probe = subprocess.run([*EXECUTOR, str(binary)], cwd=work, env=compiler_env, timeout=10, check=False)
        if probe.returncode != 0:
            raise SystemExit(f"error: Linux ACL probe failed at case {probe.returncode}")

    print("Linux POSIX ACL trust-boundary regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
