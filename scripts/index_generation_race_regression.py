#!/usr/bin/env python3
"""Check signer authorization and stale selections against signed index updates."""

from __future__ import annotations

import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
COMPILER_ROOT = os.environ.get("ELISA_COMPILER_ROOT")
if not COMPILER_ROOT:
    raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
COMPILER_ROOT = Path(COMPILER_ROOT).resolve()
OPENSSL = os.environ.get("ELISAPKG_OPENSSL")
if not OPENSSL:
    OPENSSL = next((path for path in (
        "/opt/homebrew/opt/openssl@3/bin/openssl",
        "/opt/homebrew/opt/openssl/bin/openssl",
        "/usr/bin/openssl",
    ) if Path(path).is_file() and os.access(path, os.X_OK)), None)
if not OPENSSL:
    OPENSSL = shutil.which("openssl")
if not OPENSSL:
    raise SystemExit("error: openssl is required for signed index race fixtures")


PROBE_SOURCE = r'''include "{registry}"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [97,112,112]
    versions: mutable darray[u8] = []
    generation: mutable u64 = 0
    index_digest: mutable darray[u8] = []
    index_identity: mutable darray[u8] = []
    status: Registry::ResultCode = Registry::read_index(package, &versions, &generation, &index_digest, &index_identity)
    if Platform::pkg_cstr_equal("{mode}", "unauthorized"):
        read_rejected: bool = status == Registry::ResultCode.InvalidSignature
        selected: mutable darray[u8] = []
        archive: mutable darray[u8] = []
        digest: mutable darray[u8] = []
        metadata: mutable darray[u8] = []
        archive_size: mutable u64 = 0
        requirement: mutable darray[u8] = [49,46,48,46,48]
        previous: Model::Version = Model::Version{{major: 0, minor: 0, patch: 0, prerelease: false}}
        resolved: Registry::ResultCode = Registry::resolve_metadata(package, requirement, previous, &selected, &archive, &digest, &archive_size, &metadata)
        return 0 if read_rejected and resolved == Registry::ResultCode.InvalidSignature
        return 11
    return 10 if status != Registry::ResultCode.Ok

    return 0 if Platform::pkg_cstr_equal("{mode}", "advance")

    if Platform::pkg_cstr_equal("{mode}", "stale"):
        marker: mutable darray[u8] = [114,101,97,100,121,10]
        marker_raw: void& = (&marker[0]).cast[void&] can Unsafe.PointerCast
        return 13 if Platform::pkg_write(1, marker_raw, marker.count) != marker.count.i64()
        release_byte: mutable darray[u8] = [0]
        release_raw: mutable u8& = (&release_byte[0]).cast[mutable u8&] can Unsafe.PointerCast
        return 14 if Platform::pkg_read_fd(0, release_raw, 1.usize()) != 1

    version: mutable darray[u8] = [49,46,48,46,48]
    archive_digest: mutable darray[u8] = []
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |archive_digest, metadata_digest|:
        archive_digest.push(97)
        metadata_digest.push(98)
    expires: u64 = Platform::pkg_wall_clock_seconds().u64() + 3600
    record_status: Registry::ResultCode = Registry::record_trusted_at_index(package, version, archive_digest, metadata_digest, expires, generation, index_digest, index_identity)
    return 0 if Platform::pkg_cstr_equal("{mode}", "stale") and record_status == Registry::ResultCode.RollbackDetected
    return 1 if Platform::pkg_cstr_equal("{mode}", "commit") and record_status != Registry::ResultCode.Ok
    if Platform::pkg_cstr_equal("{mode}", "commit"):
        unlisted_version: mutable darray[u8] = [57,46,57,46,57]
        unlisted_status: Registry::ResultCode = Registry::record_trusted(package, unlisted_version, archive_digest, metadata_digest, expires)
        return 0 if unlisted_status == Registry::ResultCode.NoMatchingVersion
    return 1
'''


def sign_index(root: Path, private_key: Path, generation: int, versions: str) -> None:
    package_dir = root / "app"
    package_dir.mkdir(mode=0o700, exist_ok=True)
    expires = int(time.time()) + 3600
    payload = (
        "elisapkg-index:1\n"
        f"registry:{root}\n"
        "package:app\n"
        f"generation:{generation}\n"
        f"expires:{expires}\n"
        "versions:\n"
        f"{versions}\n"
    ).encode()
    index_path = package_dir / "index"
    signature_path = package_dir / "index.sig"
    index_path.write_bytes(payload)
    index_path.chmod(0o600)
    subprocess.run(
        [OPENSSL, "pkeyutl", "-sign", "-rawin", "-inkey", str(private_key),
         "-in", str(index_path), "-out", str(signature_path)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    signature_path.chmod(0o600)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="elisapkg-index-race-", dir=ROOT / "build") as directory:
        work = Path(directory)
        registry = work / "registry"
        registry.mkdir(mode=0o700)
        trust_dir = work / "trust"
        trust_dir.mkdir(mode=0o700)
        private_key = trust_dir / "private.pem"
        unauthorized_private_key = trust_dir / "unauthorized-private.pem"
        public_der = trust_dir / "public.der"
        public_key = trust_dir / "public.raw"
        state = trust_dir / "state"
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "ED25519", "-out", str(private_key)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        private_key.chmod(0o600)
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "ED25519", "-out", str(unauthorized_private_key)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        unauthorized_private_key.chmod(0o600)
        subprocess.run([OPENSSL, "pkey", "-in", str(private_key), "-pubout", "-outform", "DER",
                        "-out", str(public_der)], check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE)
        der = public_der.read_bytes()
        prefix = bytes.fromhex("302a300506032b6570032100")
        if len(der) != len(prefix) + 32 or not der.startswith(prefix):
            raise SystemExit("error: OpenSSL emitted an unexpected Ed25519 public key")
        public_key.write_bytes(der[-32:])
        public_key.chmod(0o600)

        binaries: dict[str, Path] = {}
        compiler_env = dict(os.environ)
        compiler_env["ELISA_STAGE1_BIN"] = compiler_env.get(
            "ELISA_STAGE1_BIN", str(COMPILER_ROOT / "bin/elisac-stage1"))
        compiler_env["ELISA_ALLOW_STALE_STAGE1"] = compiler_env.get("ELISA_ALLOW_STALE_STAGE1", "0")
        compiler_env["ELISA_RUNTIME_OBJ"] = compiler_env.get(
            "ELISA_RUNTIME_OBJ", str(COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))
        for mode in ("unauthorized", "stale", "advance", "commit"):
            source = work / f"probe-{mode}.elisa"
            source.write_text(PROBE_SOURCE.format(
                registry=(ROOT / "src/registry.elisa").as_posix(), mode=mode))
            binary = work / f"probe-{mode}"
            subprocess.run([str(COMPILER_ROOT / "scripts/elisac_stage1.sh"), "-emit", "exe",
                            "-o", str(binary), str(source)], check=True, env=compiler_env)
            binaries[mode] = binary

        environment = dict(os.environ)
        environment.update({
            "ELISAPKG_REGISTRY_DIR": str(registry),
            "ELISAPKG_REGISTRY_TRUST_ROOT": str(public_key),
            "ELISAPKG_TRUST_STATE": str(state),
        })
        sign_index(registry, unauthorized_private_key, 1, "1.0.0")
        unauthorized = subprocess.run([str(binaries["unauthorized"])], env=environment,
                                       capture_output=True, timeout=10, check=False)
        if unauthorized.returncode != 0:
            raise SystemExit(
                "error: a valid signature from a key outside the configured trust root "
                f"was accepted at the index or resolution boundary: {unauthorized.returncode}; "
                f"{unauthorized.stderr!r}"
            )

        sign_index(registry, private_key, 1, "1.0.0")
        stale = subprocess.Popen([str(binaries["stale"])], env=environment, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert stale.stdout is not None and stale.stdin is not None
        ready_deadline = time.monotonic() + 10
        ready_line = b""
        while time.monotonic() < ready_deadline:
            ready, _, _ = select.select([stale.stdout], [], [], max(0, ready_deadline - time.monotonic()))
            if not ready:
                break
            ready_line = stale.stdout.readline()
            if ready_line == b"ready\n":
                break
            if not ready_line:
                break
        if ready_line != b"ready\n":
            output, error = stale.communicate(timeout=5)
            raise SystemExit(
                f"error: stale process did not reach commit barrier "
                f"(line={ready_line!r}; exit={stale.returncode}; stdout={output!r}; stderr={error!r})"
            )

        # Commit the same release once under the matching generation. This
        # proves a current selection succeeds, and makes an unguarded stale
        # retry idempotent so only the index high-water check can reject it.
        current = subprocess.run([str(binaries["commit"])], env=environment, capture_output=True,
                                 timeout=10, check=False)
        if current.returncode != 0:
            stale.kill()
            stale.wait(timeout=5)
            raise SystemExit(
                f"error: current signed index selection did not commit: "
                f"{current.returncode}; {current.stderr!r}"
            )

        # The newer signed snapshot omits the old release. Reading it persists
        # generation 2 before the paused generation-1 process can publish.
        sign_index(registry, private_key, 2, "2.0.0")
        advanced = subprocess.run([str(binaries["advance"])], env=environment, capture_output=True,
                                  timeout=10, check=False)
        if advanced.returncode != 0:
            stale.kill()
            stale.wait(timeout=5)
            raise SystemExit(
                f"error: newer index did not persist successfully: {advanced.returncode}; "
                f"{advanced.stderr!r}"
            )

        stale.stdin.write(b"x")
        stale.stdin.flush()
        _, error = stale.communicate(timeout=10)
        if stale.returncode != 0:
            raise SystemExit(
                "error: stale release committed after newer index state was persisted "
                f"(exit {stale.returncode}; stderr={error!r})"
            )

    print("signed index signer authorization and generation race regressions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
