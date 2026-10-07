#!/usr/bin/env python3
"""Check the bounded policy primitives for the pinned TUF profile."""

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


def elisa_bytes(value: bytes) -> str:
    return ", ".join(str(byte) for byte in value)


def main() -> int:
    for label, path in (("stage1 compiler", STAGE1), ("compiler wrapper", WRAPPER), ("runtime object", RUNTIME)):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}; set ELISA_COMPILER_ROOT")
    if not os.access(STAGE1, os.X_OK) or not os.access(WRAPPER, os.X_OK):
        raise SystemExit("error: Elisa compiler and wrapper must be executable")

    valid_early = elisa_bytes(b"1.0.0")
    valid_middle = elisa_bytes(b"1.0.31")
    valid_latest = elisa_bytes(b"1.0.36")
    invalid_versions = [b"1.0.37", b"1.1.0", b"2.0.0", b"1.0.00", b"1.0.1-alpha", b"1.0.1+build"]
    invalid_version_literals = [elisa_bytes(value) for value in invalid_versions]

    with tempfile.TemporaryDirectory(prefix="elisapkg-tuf-policy-", dir=ROOT) as raw:
        work = Path(raw)
        work.chmod(0o700)
        source = work / "tuf_policy_probe.elisa"
        binary = work / "tuf_policy_probe"
        invalid_version_checks = "\n".join(
            f"    invalid_version_{index}: mutable darray[u8] = [{literal}]\n"
            f"    return {10 + index} if Tuf::precheck_spec_version(invalid_version_{index}) != Tuf::ValidationCode.UnsupportedSpecVersion"
            for index, literal in enumerate(invalid_version_literals)
        )
        source.write_text(
            f'''include "{ROOT / "src/tuf.elisa"}"

def main() -> i64 can[Memory.Allocate, Abort.Panic]:
    early: mutable darray[u8] = [{valid_early}]
    middle: mutable darray[u8] = [{valid_middle}]
    latest: mutable darray[u8] = [{valid_latest}]
    return 1 if Tuf::precheck_spec_version(early) != Tuf::ValidationCode.WellFormed
    return 2 if Tuf::precheck_spec_version(middle) != Tuf::ValidationCode.WellFormed
    return 3 if Tuf::precheck_spec_version(latest) != Tuf::ValidationCode.WellFormed
{invalid_version_checks}
    authorized: mutable darray[u8] = []
    known_and_unknown: mutable darray[u8] = []
    unknown_only: mutable darray[u8] = []
    duplicate_authorized: mutable darray[u8] = []
    duplicate_supplied: mutable darray[u8] = []
    malformed: mutable darray[u8] = []
    for index in 0..<64 |authorized, known_and_unknown, unknown_only, duplicate_authorized, duplicate_supplied, malformed|:
        authorized.push(97)
        known_and_unknown.push(97)
        unknown_only.push(98)
        duplicate_authorized.push(97)
        duplicate_supplied.push(97)
        malformed.push(97)
    for index in 0..<64 |known_and_unknown|:
        known_and_unknown.push(98)
    return 20 if Tuf::precheck_signature_key_ids(authorized, known_and_unknown, 1) != Tuf::ValidationCode.WellFormed
    return 21 if Tuf::precheck_signature_key_ids(authorized, unknown_only, 1) != Tuf::ValidationCode.ThresholdInsufficient
    for index in 0..<64 |duplicate_authorized|:
        duplicate_authorized.push(97)
    return 22 if Tuf::precheck_signature_key_ids(duplicate_authorized, known_and_unknown, 1) != Tuf::ValidationCode.DuplicateKeyId
    for index in 0..<64 |duplicate_supplied|:
        duplicate_supplied.push(97)
    return 23 if Tuf::precheck_signature_key_ids(authorized, duplicate_supplied, 1) != Tuf::ValidationCode.DuplicateKeyId
    malformed[63] <- 103
    return 24 if Tuf::precheck_signature_key_ids(authorized, malformed, 1) != Tuf::ValidationCode.MalformedKeyId
    return 25 if Tuf::precheck_signature_key_ids(authorized, known_and_unknown, 0) != Tuf::ValidationCode.InvalidThreshold
    return 26 if Tuf::precheck_signature_key_ids(authorized, known_and_unknown, 2) != Tuf::ValidationCode.InvalidThreshold
    malformed_length: mutable darray[u8] = [97]
    return 27 if Tuf::precheck_signature_key_ids(authorized, malformed_length, 1) != Tuf::ValidationCode.MalformedKeyId
    too_many_keys: mutable darray[u8] = []
    too_many_signatures: mutable darray[u8] = []
    for key_index in 0..<65 |too_many_keys|:
        for byte_index in 0..<64 |too_many_keys|:
            too_many_keys.push(97)
    return 28 if Tuf::precheck_signature_key_ids(too_many_keys, unknown_only, 1) != Tuf::ValidationCode.ResourceLimit
    for signature_index in 0..<65 |too_many_signatures|:
        for byte_index in 0..<64 |too_many_signatures|:
            too_many_signatures.push(98)
    return 29 if Tuf::precheck_signature_key_ids(authorized, too_many_signatures, 1) != Tuf::ValidationCode.ResourceLimit
    return 30 if Tuf::max_metadata_file_bytes != 1048576.usize() or Tuf::max_authorized_keys_per_role != 64.usize()
    return 31 if Tuf::max_signatures_per_metadata != 64.usize() or Tuf::max_delegation_depth != 1.usize()
    return 32 if Tuf::max_delegated_roles != 4096.usize() or Tuf::max_targets_per_package_role != 4096.usize()
    return 33 if Tuf::max_root_updates_per_refresh != 1024.usize() or Tuf::max_json_container_depth != 64.usize()
    return 0
''',
            encoding="utf-8",
        )
        compiler_env = dict(os.environ)
        compiler_env["ELISA_STAGE1_BIN"] = str(STAGE1)
        compiler_env["ELISA_COMPILER_WRAPPER"] = str(WRAPPER)
        compiler_env["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
        compiler_env.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
        compiled = subprocess.run(
            [str(WRAPPER), "-emit", "exe", "-o", str(binary), str(source)],
            cwd=work,
            env=compiler_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
            check=False,
        )
        if compiled.returncode != 0:
            raise SystemExit(f"error: could not compile TUF policy probe:\n{compiled.stdout}")
        result = subprocess.run([str(binary)], cwd=work, env=compiler_env, timeout=10, check=False)
        if result.returncode != 0:
            raise SystemExit(f"error: TUF policy probe failed at case {result.returncode}")

    print("TUF profile policy regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
