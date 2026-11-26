#!/usr/bin/env python3
"""Check the bounded policy primitives for the pinned TUF profile."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
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
    json_cases = {
        "valid_metadata": b'{"signed":{"version":1,"text":"value 1.5 and -0"},"signatures":[]}',
        "duplicate_metadata": b'{"signed":{"version":1,"version":2},"signatures":[]}',
        "float_metadata": b'{"signed":{"version":1.0},"signatures":[]}',
        "exponent_metadata": b'{"signed":{"version":1e2},"signatures":[]}',
        "negative_zero_metadata": b'{"signed":{"version":-0},"signatures":[]}',
        "negative_integer_metadata": b'{"signed":{"version":-1},"signatures":[]}',
        "malformed_metadata": b'{"signed":, "signatures":[]}',
        "empty_metadata": b"",
        "sha256_hash_metadata": (
            b'{"signed":{"targets":{"pkg":{"hashes":{"sha256":"'
            + b"a" * 64
            + b'"}}}},"signatures":[]}'
        ),
        "sha512_hash_metadata": (
            b'{"signed":{"targets":{"pkg":{"hashes":{"sha512":"'
            + b"a" * 128
            + b'"}}}},"signatures":[]}'
        ),
        "malformed_hash_metadata": (
            b'{"signed":{"targets":{"pkg":{"hashes":{"sha256":"'
            + b"g" * 64
            + b'"}}}},"signatures":[]}'
        ),
        "uppercase_hash_metadata": (
            b'{"signed":{"targets":{"pkg":{"hashes":{"sha256":"'
            + b"A" * 64
            + b'"}}}},"signatures":[]}'
        ),
        "empty_hash_metadata": b'{"signed":{"targets":{"pkg":{"hashes":{}}}},"signatures":[]}',
        "hashes_text_metadata": b'{"signed":{"description":"literal \\"hashes\\":{\\"sha512\\":\\"x\\"}"},"signatures":[]}',
    }
    json_literals = {name: elisa_bytes(value) for name, value in json_cases.items()}

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

def append_ascii(out: mutable darray[u8]&, text: cstr) -> void can[Memory.Allocate, Abort.Panic]:
    cursor: mutable usize = 0.usize()
    while text[cursor].u8() != 0 |out, text, cursor|:
        out.push(text[cursor].u8())
        cursor <- cursor + 1.usize()

def append_decimal(out: mutable darray[u8]&, value: u64) -> void can[Memory.Allocate, Abort.Panic]:
    digits: mutable darray[u8] = []
    remaining: mutable u64 = value
    if remaining == 0.u64():
        digits.push(48)
    while remaining > 0.u64() |digits, remaining|:
        digits.push(48 + (remaining % 10.u64()).u8())
        remaining <- remaining / 10.u64()
    for digit_index in 0..<digits.count |out, digits|:
        out.push(digits[digits.count - 1.usize() - digit_index])

def main() -> i64 can[Memory.Allocate, Abort.Panic]:
    early: mutable darray[u8] = [{valid_early}]
    middle: mutable darray[u8] = [{valid_middle}]
    latest: mutable darray[u8] = [{valid_latest}]
    return 1 if Tuf::precheck_spec_version(early) != Tuf::ValidationCode.WellFormed
    return 2 if Tuf::precheck_spec_version(middle) != Tuf::ValidationCode.WellFormed
    return 3 if Tuf::precheck_spec_version(latest) != Tuf::ValidationCode.WellFormed
{invalid_version_checks}
    valid_metadata: mutable darray[u8] = [{json_literals['valid_metadata']}]
    duplicate_metadata: mutable darray[u8] = [{json_literals['duplicate_metadata']}]
    float_metadata: mutable darray[u8] = [{json_literals['float_metadata']}]
    exponent_metadata: mutable darray[u8] = [{json_literals['exponent_metadata']}]
    negative_zero_metadata: mutable darray[u8] = [{json_literals['negative_zero_metadata']}]
    negative_integer_metadata: mutable darray[u8] = [{json_literals['negative_integer_metadata']}]
    malformed_metadata: mutable darray[u8] = [{json_literals['malformed_metadata']}]
    empty_metadata: mutable darray[u8] = []
    sha256_hash_metadata: mutable darray[u8] = [{json_literals['sha256_hash_metadata']}]
    sha512_hash_metadata: mutable darray[u8] = [{json_literals['sha512_hash_metadata']}]
    malformed_hash_metadata: mutable darray[u8] = [{json_literals['malformed_hash_metadata']}]
    uppercase_hash_metadata: mutable darray[u8] = [{json_literals['uppercase_hash_metadata']}]
    empty_hash_metadata: mutable darray[u8] = [{json_literals['empty_hash_metadata']}]
    hashes_text_metadata: mutable darray[u8] = [{json_literals['hashes_text_metadata']}]
    return 34 if Tuf::precheck_metadata_json(valid_metadata) != Tuf::ValidationCode.WellFormed
    return 35 if Tuf::precheck_metadata_json(duplicate_metadata) != Tuf::ValidationCode.InvalidJsonKeys
    return 36 if Tuf::precheck_metadata_json(float_metadata) != Tuf::ValidationCode.NoncanonicalNumber
    return 37 if Tuf::precheck_metadata_json(exponent_metadata) != Tuf::ValidationCode.NoncanonicalNumber
    return 38 if Tuf::precheck_metadata_json(negative_zero_metadata) != Tuf::ValidationCode.NoncanonicalNumber
    return 39 if Tuf::precheck_metadata_json(negative_integer_metadata) != Tuf::ValidationCode.WellFormed
    return 40 if Tuf::precheck_metadata_json(malformed_metadata) != Tuf::ValidationCode.MalformedJson
    return 44 if Tuf::precheck_metadata_json(empty_metadata) != Tuf::ValidationCode.MalformedJson
    return 50 if Tuf::precheck_sha256_hashes(sha256_hash_metadata) != Tuf::ValidationCode.WellFormed
    return 51 if Tuf::precheck_sha256_hashes(sha512_hash_metadata) != Tuf::ValidationCode.UnsupportedHashAlgorithm
    return 52 if Tuf::precheck_sha256_hashes(malformed_hash_metadata) != Tuf::ValidationCode.MalformedHash
    return 53 if Tuf::precheck_sha256_hashes(empty_hash_metadata) != Tuf::ValidationCode.MalformedHash
    return 54 if Tuf::precheck_sha256_hashes(hashes_text_metadata) != Tuf::ValidationCode.WellFormed
    return 55 if Tuf::precheck_sha256_hashes(uppercase_hash_metadata) != Tuf::ValidationCode.MalformedHash
    small_metadata: mutable darray[u8] = []
    append_ascii(&small_metadata, "{{\\\"signed\\\":{{\\\"targets\\\":{{}}}},\\\"signatures\\\":[]}}")
    return 49 if Tuf::precheck_metadata_json(small_metadata) != Tuf::ValidationCode.WellFormed
    large_metadata: mutable darray[u8] = []
    append_ascii(&large_metadata, "{{\\\"signed\\\":{{\\\"targets\\\":{{")
    for target_index in 0..<4096 |large_metadata, target_index|:
        if target_index > 0:
            append_ascii(&large_metadata, ",")
        append_ascii(&large_metadata, "\\\"pkg/")
        append_decimal(&large_metadata, target_index.u64())
        append_ascii(&large_metadata, "\\\":{{\\\"length\\\":1,\\\"hashes\\\":{{\\\"sha256\\\":\\\"")
        for digest_byte in 0..<64 |large_metadata|:
            large_metadata.push(48)
        append_ascii(&large_metadata, "\\\"}},\\\"custom\\\":{{\\\"schema-version\\\":1}}}}")
    append_ascii(&large_metadata, "}}}},\\\"signatures\\\":[]}}")
    return 41 if large_metadata.count > Tuf::max_metadata_file_bytes
    large_status: Tuf::ValidationCode = Tuf::precheck_metadata_json(large_metadata)
    return 42 if large_status == Tuf::ValidationCode.MalformedJson
    return 45 if large_status == Tuf::ValidationCode.ResourceLimit
    return 46 if large_status == Tuf::ValidationCode.InvalidJsonKeys
    return 47 if large_status == Tuf::ValidationCode.NoncanonicalNumber
    return 48 if large_status != Tuf::ValidationCode.WellFormed
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
    return 43 if Tuf::max_json_object_keys != 65536.usize() or Tuf::max_duplicate_key_candidates != 8500000.usize() or Tuf::max_duplicate_key_comparison_bytes != 65536.usize()
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
