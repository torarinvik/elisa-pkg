#!/usr/bin/env python3
"""Ensure package history is isolated by registry root in a shared state file."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import time
from typing import Optional


ROOT = Path(__file__).resolve().parents[2]
COMPILER_ROOT = os.environ.get("ELISA_COMPILER_ROOT")
if not COMPILER_ROOT:
    raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
COMPILER_ROOT = Path(COMPILER_ROOT)
STAGE1 = COMPILER_ROOT / "scripts/elisac_stage1.sh"


def find_openssl() -> str:
    for candidate in (
        "/opt/homebrew/opt/openssl@3/bin/openssl",
        "/opt/homebrew/opt/openssl/bin/openssl",
        "/usr/bin/openssl",
    ):
        if os.access(candidate, os.X_OK):
            return candidate
    raise SystemExit("error: no supported OpenSSL executable for signed registry fixtures")


def compile_probe(work: Path, label: str, archive_byte: str, metadata_byte: str, version: str = "1.0.0") -> Path:
    source = work / f"record-{label}.elisa"
    binary = work / f"record-{label}"
    archive_digest = ",".join(str(ord(archive_byte)) for _ in range(64))
    metadata_digest = ",".join(str(ord(metadata_byte)) for _ in range(64))
    version_bytes = ",".join(str(ord(part)) for part in version)
    source.write_text(
        f'''include "{ROOT}/src/registry.elisa"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [102,111,111]
    version: mutable darray[u8] = [{version_bytes}]
    archive_digest: mutable darray[u8] = [{archive_digest}]
    metadata_digest: mutable darray[u8] = [{metadata_digest}]
    expires: u64 = Platform::pkg_wall_clock_seconds().u64() + 3600
    result: Registry::ResultCode = Registry::record_trusted(package, version, archive_digest, metadata_digest, expires)
    if result != Registry::ResultCode.Ok:
        message: cstr = Registry::result_message(result)
        message_ref: void& = message.cast[void&] can Unsafe.PointerCast
        Platform::pkg_write(2, message_ref, Platform::pkg_strlen(message)) can Console.Write
        return 1
    verified: Registry::ResultCode = Registry::verify_trusted(package, version, archive_digest, metadata_digest, expires)
    if verified != Registry::ResultCode.Ok:
        message: cstr = Registry::result_message(verified)
        message_ref: void& = message.cast[void&] can Unsafe.PointerCast
        Platform::pkg_write(2, message_ref, Platform::pkg_strlen(message)) can Console.Write
        return 2
    return 0
''',
        encoding="utf-8",
    )
    compiler_env = dict(os.environ)
    compiler_env.setdefault("ELISA_STAGE1_BIN", str(COMPILER_ROOT / "bin/elisac-stage1"))
    compiler_env.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
    compiler_env.setdefault("ELISA_RUNTIME_OBJ", str(COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))
    subprocess.run(
        [str(STAGE1), "-emit", "exe", "-o", str(binary), str(source)],
        cwd=ROOT,
        env=compiler_env,
        check=True,
        timeout=120,
    )
    return binary


def compile_verify_probe(work: Path, label: str, archive_byte: str, metadata_byte: str) -> Path:
    source = work / f"verify-{label}.elisa"
    binary = work / f"verify-{label}"
    archive_digest = ",".join(str(ord(archive_byte)) for _ in range(64))
    metadata_digest = ",".join(str(ord(metadata_byte)) for _ in range(64))
    source.write_text(
        f'''include "{ROOT}/src/registry.elisa"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [102,111,111]
    version: mutable darray[u8] = [49,46,48,46,48]
    archive_digest: mutable darray[u8] = [{archive_digest}]
    metadata_digest: mutable darray[u8] = [{metadata_digest}]
    expires: u64 = Platform::pkg_wall_clock_seconds().u64() + 3600
    result: Registry::ResultCode = Registry::verify_trusted(package, version, archive_digest, metadata_digest, expires)
    return 0 if result != Registry::ResultCode.Ok else 1
''',
        encoding="utf-8",
    )
    compiler_env = dict(os.environ)
    compiler_env.setdefault("ELISA_STAGE1_BIN", str(COMPILER_ROOT / "bin/elisac-stage1"))
    compiler_env.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
    compiler_env.setdefault("ELISA_RUNTIME_OBJ", str(COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))
    subprocess.run(
        [str(STAGE1), "-emit", "exe", "-o", str(binary), str(source)],
        cwd=ROOT,
        env=compiler_env,
        check=True,
        timeout=120,
    )
    return binary


def write_index(root: Path, private_key: Path, openssl: str, generation: int) -> None:
    package_dir = root / "foo"
    expires = int(time.time()) + 86400
    payload = (
        "elisapkg-index:1\n"
        f"registry:{root}\n"
        "package:foo\n"
        f"generation:{generation}\n"
        f"expires:{expires}\n"
        "versions:\n"
        "1.0.0\n"
        "2.0.0\n"
    ).encode("ascii")
    index = package_dir / "index"
    index.write_bytes(payload)
    index.chmod(0o600)
    signature = package_dir / "index.sig"
    subprocess.run(
        [openssl, "pkeyutl", "-sign", "-rawin", "-inkey", str(private_key), "-in", str(index), "-out", str(signature)],
        check=True,
        timeout=10,
    )
    signature.chmod(0o600)


def create_registry(root: Path, private_key: Path, openssl: str) -> None:
    package_dir = root / "foo"
    package_dir.mkdir(mode=0o700, parents=True)
    write_index(root, private_key, openssl, 1)


def main() -> None:
    openssl = find_openssl()
    with tempfile.TemporaryDirectory(prefix="elisapkg-trust-isolation-", dir=ROOT / "build") as temp:
        work = Path(temp)
        trust_dir = work / "trust"
        trust_dir.mkdir(mode=0o700)
        private_key = trust_dir / "private.pem"
        public_der = trust_dir / "public.der"
        public_key = trust_dir / "key"
        subprocess.run([openssl, "genpkey", "-algorithm", "ED25519", "-out", str(private_key)], check=True, timeout=10)
        private_key.chmod(0o600)
        subprocess.run([openssl, "pkey", "-in", str(private_key), "-pubout", "-outform", "DER", "-out", str(public_der)], check=True, timeout=10)
        public_bytes = public_der.read_bytes()
        der_prefix = bytes.fromhex("302a300506032b6570032100")
        if len(public_bytes) != len(der_prefix) + 32 or not public_bytes.startswith(der_prefix):
            raise SystemExit("error: OpenSSL emitted an unexpected Ed25519 public-key encoding")
        public_key.write_bytes(public_bytes[-32:])
        public_key.chmod(0o600)

        registry_a = work / "registry-a"
        registry_b = work / "registry-b"
        registry_a.mkdir(mode=0o700)
        registry_b.mkdir(mode=0o700)
        create_registry(registry_a, private_key, openssl)
        create_registry(registry_b, private_key, openssl)

        probe_a = compile_probe(work, "a", "a", "b")
        probe_b = compile_probe(work, "b", "c", "d")
        migration_probe = compile_probe(work, "migration", "e", "f", "2.0.0")
        verify_b = compile_verify_probe(work, "b", "c", "d")
        shared_state = work / "shared.state"

        def record(binary: Path, registry: Path, label: str) -> None:
            environment = dict(os.environ)
            environment["ELISAPKG_REGISTRY_DIR"] = str(registry)
            environment["ELISAPKG_REGISTRY_TRUST_ROOT"] = str(public_key)
            environment["ELISAPKG_TRUST_STATE"] = str(shared_state)
            result = subprocess.run(
                [str(binary)],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=10,
            )
            if result.returncode != 0:
                raise SystemExit(f"error: {label} could not record in shared trust state (exit {result.returncode}): {result.stderr!r}")

        record(probe_a, registry_a, "registry A")
        record(probe_b, registry_b, "registry B")
        record(probe_a, registry_a, "registry A re-entry")

        records = shared_state.read_text(encoding="ascii").splitlines()[1:]
        expected = {
            f"@package:{hashlib.sha256(os.fsencode(str(registry_a))).hexdigest()}:foo",
            f"@package:{hashlib.sha256(os.fsencode(str(registry_b))).hexdigest()}:foo",
        }
        recorded_identities = {record.split(" ", 1)[0] for record in records}
        if not shared_state.read_bytes().startswith(b"elisapkg-trust-state:4\n"):
            raise SystemExit("error: new trust state did not use schema version 4")
        if not expected.issubset(recorded_identities):
            raise SystemExit("error: shared trust state did not retain separate registry-scoped package histories")
        public_fingerprint = hashlib.sha256(public_key.read_bytes()).hexdigest().encode("ascii")
        for registry in (registry_a, registry_b):
            root_key_identity = f"@root-key:{hashlib.sha256(os.fsencode(str(registry))).hexdigest()}".encode("ascii")
            if root_key_identity + b" 0.0.0 " + public_fingerprint + b" " + public_fingerprint not in shared_state.read_bytes():
                raise SystemExit("error: trust state did not pin the configured signing key to its registry path")

        def probe_environment(registry: Path, home: Path, state: Optional[Path] = None) -> dict[str, str]:
            environment = dict(os.environ)
            environment["ELISAPKG_REGISTRY_DIR"] = str(registry)
            environment["ELISAPKG_REGISTRY_TRUST_ROOT"] = str(public_key)
            environment["HOME"] = str(home)
            if state is None:
                environment.pop("ELISAPKG_TRUST_STATE", None)
            else:
                environment["ELISAPKG_TRUST_STATE"] = str(state)
            return environment

        # Older v2 package rows are safe to migrate only in the default file,
        # whose pathname is already hashed from its sole registry root.
        migration_home = work / "migration-home"
        migration_home.mkdir(mode=0o700)
        migration_directories = (
            migration_home / ".local",
            migration_home / ".local/share",
            migration_home / ".local/share/elisapkg",
            migration_home / ".local/share/elisapkg/trust",
        )
        for directory in migration_directories:
            directory.mkdir(mode=0o700)
        migration_state = migration_directories[-1] / (hashlib.sha256(os.fsencode(str(registry_a))).hexdigest() + ".state")
        scoped_root_hash = hashlib.sha256(os.fsencode(str(registry_a))).hexdigest()
        index_digest = hashlib.sha256((registry_a / "foo" / "index").read_bytes()).hexdigest().encode("ascii")
        legacy_row = b"foo 1.0.0 " + b"a" * 64 + b" " + b"b" * 64 + b"\n"
        legacy_index_row = f"@index:{scoped_root_hash}:foo 0.0.1 ".encode("ascii") + index_digest + b" " + index_digest + b"\n"
        legacy_state = b"elisapkg-trust-state:2\n" + legacy_row + legacy_index_row
        migration_state.write_bytes(legacy_state)
        migration_state.chmod(0o600)
        migration_clock = Path(f"{migration_state}.clock")
        migration_clock.write_text(
            "clock:0\nstate-sha256:" + hashlib.sha256(legacy_state).hexdigest() + "\n",
            encoding="ascii",
        )
        migration_clock.chmod(0o600)
        migrated = subprocess.run(
            [str(migration_probe)], cwd=ROOT, env=probe_environment(registry_a, migration_home),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=10,
        )
        if migrated.returncode != 0:
            raise SystemExit(f"error: default v2 state could not migrate safely: {migrated.stderr!r}")
        migrated_bytes = migration_state.read_bytes()
        migrated_identity = f"@package:{hashlib.sha256(os.fsencode(str(registry_a))).hexdigest()}:foo".encode("ascii")
        if not migrated_bytes.startswith(b"elisapkg-trust-state:4\n") or migrated_identity + b" 1.0.0 " not in migrated_bytes or migrated_identity + b" 2.0.0 " not in migrated_bytes:
            raise SystemExit("error: higher-release update did not migrate and retain default v2 package history as scoped v4 records")
        if b"\nfoo 1.0.0 " in migrated_bytes:
            raise SystemExit("error: unscoped v2 package row survived default-state migration")
        migrated_root_key_identity = f"@root-key:{scoped_root_hash}".encode("ascii")
        if migrated_root_key_identity + b" 0.0.0 " + public_fingerprint + b" " + public_fingerprint not in migrated_bytes:
            raise SystemExit("error: v2 migration did not pin the key that verified its first signed v4 update")

        # A v2 override may have accumulated rows from multiple registries, so
        # it cannot safely lend an unscoped record to any current root.
        ambiguous_state = work / "legacy-shared.state"
        ambiguous_bytes = b"elisapkg-trust-state:2\nfoo 1.0.0 " + b"c" * 64 + b" " + b"d" * 64 + b"\n"
        ambiguous_state.write_bytes(ambiguous_bytes)
        ambiguous_state.chmod(0o600)
        ambiguous_clock = Path(f"{ambiguous_state}.clock")
        ambiguous_clock_bytes = (
            "clock:0\nstate-sha256:" + hashlib.sha256(ambiguous_bytes).hexdigest() + "\n"
        ).encode("ascii")
        ambiguous_clock.write_bytes(ambiguous_clock_bytes)
        ambiguous_clock.chmod(0o600)
        legacy_verify = subprocess.run(
            [str(verify_b)], cwd=ROOT,
            env=probe_environment(registry_b, work, ambiguous_state),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=10,
        )
        if legacy_verify.returncode != 0:
            raise SystemExit("error: ambiguous unscoped v2 override history was accepted for verification")
        legacy_record = subprocess.run(
            [str(probe_b)], cwd=ROOT,
            env=probe_environment(registry_b, work, ambiguous_state),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=10,
        )
        if (
            legacy_record.returncode == 0
            or ambiguous_state.read_bytes() != ambiguous_bytes
            or ambiguous_clock.read_bytes() != ambiguous_clock_bytes
        ):
            raise SystemExit("error: ambiguous unscoped v2 override history was recorded or rewritten")

        # Replacing the configured key for the same registry path must not
        # create a fresh rollback namespace. Even a higher signed generation
        # under the new key is rejected without changing either durable file.
        replacement_private = trust_dir / "replacement-private.pem"
        replacement_der = trust_dir / "replacement-public.der"
        replacement_public = trust_dir / "replacement-key"
        subprocess.run([openssl, "genpkey", "-algorithm", "ED25519", "-out", str(replacement_private)], check=True, timeout=10)
        replacement_private.chmod(0o600)
        subprocess.run([openssl, "pkey", "-in", str(replacement_private), "-pubout", "-outform", "DER", "-out", str(replacement_der)], check=True, timeout=10)
        replacement_bytes = replacement_der.read_bytes()
        if len(replacement_bytes) != len(der_prefix) + 32 or not replacement_bytes.startswith(der_prefix):
            raise SystemExit("error: OpenSSL emitted an unexpected replacement Ed25519 key encoding")
        replacement_public.write_bytes(replacement_bytes[-32:])
        replacement_public.chmod(0o600)
        write_index(registry_a, replacement_private, openssl, 2)
        prior_state = shared_state.read_bytes()
        shared_clock = Path(f"{shared_state}.clock")
        prior_clock = shared_clock.read_bytes()
        replacement_environment = dict(os.environ)
        replacement_environment["ELISAPKG_REGISTRY_DIR"] = str(registry_a)
        replacement_environment["ELISAPKG_REGISTRY_TRUST_ROOT"] = str(replacement_public)
        replacement_environment["ELISAPKG_TRUST_STATE"] = str(shared_state)
        rejected_key = subprocess.run(
            [str(probe_a)], cwd=ROOT, env=replacement_environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=10,
        )
        if rejected_key.returncode == 0 or b"without an authenticated rotation" not in rejected_key.stderr:
            raise SystemExit(f"error: replacement signing key was not rejected with a clear trust-root error: {rejected_key.stderr!r}")
        if shared_state.read_bytes() != prior_state or shared_clock.read_bytes() != prior_clock:
            raise SystemExit("error: rejecting a replacement signing key changed trust state or clock")

    print("Elisa shared trust-state registry isolation regression passed")


if __name__ == "__main__":
    main()
