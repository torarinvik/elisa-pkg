#!/usr/bin/env python3
"""Check native trust validation for crypto-provider executable paths."""

from pathlib import Path
import os
import grp
import pwd
import stat
import subprocess
import tempfile
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
COMPILER_ROOT = Path(os.environ.get("ELISA_COMPILER_ROOT", ""))
STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1"))
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh"))
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))


def elisa_bytes(value: Path) -> str:
    return ", ".join(str(byte) for byte in os.fsencode(value) + b"\0")


def available_candidate(path: str) -> Optional[Path]:
    try:
        resolved = Path(path).resolve(strict=True)
        metadata = resolved.stat()
    except OSError:
        return None
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o111 == 0:
        return None
    return resolved


def non_root_uid() -> int:
    for account in ("nobody", "_www"):
        try:
            uid = pwd.getpwnam(account).pw_uid
        except KeyError:
            continue
        if uid != 0:
            return uid
    return 65534


def main() -> int:
    for label, path in (
        ("compiler root", COMPILER_ROOT),
        ("stage1 compiler", STAGE1),
        ("compiler wrapper", WRAPPER),
        ("runtime object", RUNTIME),
    ):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}; set ELISA_COMPILER_ROOT")

    (ROOT / "build").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elisapkg-provider-trust-", dir=ROOT / "build") as directory:
        work = Path(directory)
        fake_prefix = work / "fake-prefix"
        fake_bin = fake_prefix / "bin"
        fake_bin.mkdir(parents=True, mode=0o755)
        fake_provider = fake_bin / "openssl"
        fake_provider.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
        fake_provider.chmod(0o755)

        # When the regression itself runs as root, make the complete fake
        # provider subtree belong to a different uid while keeping the test
        # parent root-owned. This deterministically models a user-owned
        # Homebrew installation presented to an elevated elisapkg process.
        if os.geteuid() == 0:
            uid = non_root_uid()
            os.chown(fake_prefix, uid, -1)
            os.chown(fake_bin, uid, -1)
            os.chown(fake_provider, uid, -1)

        # A writable directory owned by the expected user is still unsafe if
        # an ordinary group can replace the provider. macOS permits the
        # privileged `admin` group exception; the ordinary `staff` group must
        # remain rejected. Linux rejects all group-writable provider dirs.
        fake_group_prefix = work / "fake-group-prefix"
        fake_group_bin = fake_group_prefix / "bin"
        fake_group_bin.mkdir(parents=True, mode=0o755)
        fake_group_provider = fake_group_bin / "openssl"
        fake_group_provider.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
        fake_group_provider.chmod(0o755)
        expected_user_uid = os.geteuid() if os.geteuid() != 0 else non_root_uid()
        ordinary_gid = grp.getgrnam("staff").gr_gid if os.uname().sysname == "Darwin" else os.getgid()
        os.chown(fake_group_prefix, expected_user_uid, ordinary_gid)
        os.chown(fake_group_bin, expected_user_uid, ordinary_gid)
        os.chown(fake_group_provider, expected_user_uid, ordinary_gid)
        fake_group_prefix.chmod(0o775)

        trusted_provider = Path("/usr/bin/env").resolve(strict=True)
        candidates = [
            candidate
            for candidate in (
                available_candidate("/opt/homebrew/opt/openssl@3/bin/openssl"),
                available_candidate("/opt/homebrew/opt/openssl/bin/openssl"),
                available_candidate("/usr/bin/openssl"),
            )
            if candidate is not None
        ]
        homebrew_candidate = next(
            (
                candidate
                for candidate in (
                    available_candidate("/opt/homebrew/opt/openssl@3/bin/openssl"),
                    available_candidate("/opt/homebrew/opt/openssl/bin/openssl"),
                )
                if candidate is not None
            ),
            None,
        )

        probe = work / "provider_trust_probe.elisa"
        binary = work / "provider_trust_probe"
        lines = [
            f'include "{ROOT / "src/platform_native.elisa"}"',
            "",
            "def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:",
            f'    fake_path: mutable darray[u8] = [{elisa_bytes(fake_provider)}]',
            '    fake_name: cstr = (&fake_path[0]).cast[cstr] can Unsafe.PointerCast',
            '    return 1 if PlatformNative::is_trusted_crypto_executable(fake_name, 0.u64())',
            f'    fake_group_path: mutable darray[u8] = [{elisa_bytes(fake_group_provider)}]',
            '    fake_group_name: cstr = (&fake_group_path[0]).cast[cstr] can Unsafe.PointerCast',
            f'    return 6 if PlatformNative::is_trusted_crypto_executable(fake_group_name, {expected_user_uid}.u64())',
            f'    system_path: mutable darray[u8] = [{elisa_bytes(trusted_provider)}]',
            '    system_name: cstr = (&system_path[0]).cast[cstr] can Unsafe.PointerCast',
            '    return 2 if not PlatformNative::is_trusted_crypto_executable(system_name, 0.u64())',
            '    has_current_provider: mutable bool = false',
        ]
        for index, candidate in enumerate(candidates):
            lines.extend(
                [
                    f'    candidate_path_{index}: mutable darray[u8] = [{elisa_bytes(candidate)}]',
                    f'    candidate_name_{index}: cstr = (&candidate_path_{index}[0]).cast[cstr] can Unsafe.PointerCast',
                    f'    candidate_trusted_{index}: bool = PlatformNative::is_trusted_crypto_executable(candidate_name_{index}, {os.geteuid()}.u64())',
                    f'    has_current_provider <- true if candidate_trusted_{index}',
                ]
            )
        lines.append('    return 3 if not has_current_provider')
        if os.geteuid() != 0 and homebrew_candidate is not None:
            # In the affected configuration this actual Homebrew binary sits
            # under an euid-owned group-writable Cellar directory. The
            # production provider order selects it before /usr/bin/openssl.
            lines.extend(
                [
                    f'    homebrew_path: mutable darray[u8] = [{elisa_bytes(homebrew_candidate)}]',
                    '    homebrew_name: cstr = (&homebrew_path[0]).cast[cstr] can Unsafe.PointerCast',
                    f'    return 4 if not PlatformNative::is_trusted_crypto_executable(homebrew_name, {os.geteuid()}.u64())',
                ]
            )
        public_key = bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
        signature = bytes.fromhex(
            "92a009a9f0d4cab8720e820b5f642540"
            "a2b27b5416503f8fb3762223ebdb69da"
            "085ac1e43e15996e458f3613d0f11d8c"
            "387b2eaeb4302aeeb00d291612bb0c00"
        )
        lines.extend(
            [
                f'    public_key: mutable darray[u8] = [{", ".join(str(byte) for byte in public_key)}]',
                '    message: mutable darray[u8] = [114]',
                f'    signature: mutable darray[u8] = [{", ".join(str(byte) for byte in signature)}]',
                '    return 5 if PlatformNative::verify_ed25519(public_key, message, signature) != 0',
                '    return 0',
            ]
        )
        probe.write_text("\n".join(lines) + "\n", encoding="utf-8")
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
        result = subprocess.run([str(binary)], cwd=work, timeout=5, check=False)
        if result.returncode != 0:
            raise SystemExit(f"error: provider trust probe exited {result.returncode}")

    print("Elisa crypto-provider trust regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
