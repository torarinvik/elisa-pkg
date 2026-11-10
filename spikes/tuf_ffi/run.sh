#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SPIKE="$ROOT/spikes/tuf_ffi"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-}"
if [[ -z "$COMPILER_ROOT" ]]; then
  echo "error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout" >&2
  exit 2
fi
COMPILER_ROOT="$(cd -- "$COMPILER_ROOT" && pwd)"
STAGE1="${ELISA_STAGE1_BIN:-$COMPILER_ROOT/bin/elisac-stage1}"
WRAPPER="${ELISA_COMPILER_WRAPPER:-$COMPILER_ROOT/scripts/elisac_stage1.sh}"
RUNTIME="${ELISA_RUNTIME_OBJ:-$COMPILER_ROOT/build/runtime/elisacore_runtime.o}"
CARGO_BIN="${CARGO:-cargo}"

for path in "$STAGE1" "$WRAPPER" "$RUNTIME"; do
  if [[ ! -e "$path" ]]; then
    echo "error: required toolchain input is missing: $path" >&2
    exit 2
  fi
done
if [[ ! -x "$STAGE1" || ! -x "$WRAPPER" ]]; then
  echo "error: Elisa compiler and wrapper must be executable" >&2
  exit 2
fi

mkdir -p "$ROOT/build"
export CARGO_TARGET_DIR="$ROOT/build/tuf-ffi-cargo"
mkdir -p "$CARGO_TARGET_DIR"
WORK="$(mktemp -d "$ROOT/build/tuf-ffi.XXXXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -m 700 "$WORK/package-root" "$WORK/package-root/src"
mkdir -m 700 "$WORK/fixtures"

"$CARGO_BIN" test --locked --manifest-path "$SPIKE/Cargo.toml"
"$CARGO_BIN" build --locked --release --manifest-path "$SPIKE/Cargo.toml"
"$CARGO_BIN" run --locked --release --manifest-path "$SPIKE/Cargo.toml" --bin root_chain_fixturegen -- "$WORK/fixtures"

python3 - "$SPIKE/abi_probe.elisa.in" "$WORK/fixtures/root3.json" "$SPIKE/testdata/github-root.json" "$WORK/fixtures" "$WORK/abi_probe.elisa" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

template_path, root_path, github_root_path, fixture_dir, output_path = map(Path, sys.argv[1:])
raw = root_path.read_bytes()
document = json.loads(raw)
signed = document["signed"]
github_root = github_root_path.read_bytes()
tampered = raw.replace(b'"consistent_snapshot":false', b'"consistent_snapshot":true', 1)
unsupported = raw.replace(b'"spec_version":"1.0.0"', b'"spec_version":"1.0.37"', 1)
if tampered == raw or unsupported == raw:
    raise SystemExit("generated Ed25519 root no longer matches expected test transformations")

rotation_roots = [fixture_dir / f"root{version}.json" for version in (1, 2, 3)]
rotation_documents = [json.loads(path.read_bytes()) for path in rotation_roots]
if [item["signed"]["version"] for item in rotation_documents] != [1, 2, 3]:
    raise SystemExit("generated root rotation fixtures are not sequential")
expired_root_path = fixture_dir / "root-expired.json"
expired_root_document = json.loads(expired_root_path.read_bytes())
boundary_root_path = fixture_dir / "root-expiry-boundary.json"
boundary_root_document = json.loads(boundary_root_path.read_bytes())
timestamp_path = fixture_dir / "timestamp.json"
timestamp_document = json.loads(timestamp_path.read_bytes())
expired_timestamp_path = fixture_dir / "timestamp-expired.json"
expired_timestamp_document = json.loads(expired_timestamp_path.read_bytes())
boundary_timestamp_path = fixture_dir / "timestamp-expiry-boundary.json"
boundary_timestamp_document = json.loads(boundary_timestamp_path.read_bytes())
if rotation_documents[1]["signed"]["expires"] >= "2023-11-14T22:13:20Z":
    raise SystemExit("root 2 must be expired at the fixed probe time")
if rotation_documents[2]["signed"]["expires"] <= "2023-11-14T22:13:20Z":
    raise SystemExit("root 3 must be unexpired at the fixed probe time")
if expired_root_document["signed"]["expires"] >= "2023-11-14T22:13:20Z":
    raise SystemExit("expired root fixture must be expired at the fixed probe time")
if boundary_root_document["signed"]["expires"] != "2023-11-14T22:13:20Z":
    raise SystemExit("boundary root fixture must expire exactly at the fixed probe time")
if timestamp_document["signed"]["_type"] != "timestamp":
    raise SystemExit("timestamp fixture has the wrong role type")
if expired_timestamp_document["signed"]["expires"] >= "2023-11-14T22:13:20Z":
    raise SystemExit("expired timestamp fixture must be expired at the fixed probe time")
if boundary_timestamp_document["signed"]["expires"] != "2023-11-14T22:13:20Z":
    raise SystemExit("boundary timestamp fixture must expire exactly at the fixed probe time")
root2 = rotation_roots[1].read_bytes()
root2_document = json.loads(root2)
duplicate_root2 = root2.replace(b'"version":2', b'"version":2,"version":2', 1)
tampered_root2 = root2.replace(b'"consistent_snapshot":false', b'"consistent_snapshot":true', 1)
unsupported_root2 = root2.replace(b'"spec_version":"1.0.0"', b'"spec_version":"1.0.37"', 1)
duplicate_signature_root2 = json.dumps(
    {"signed": root2_document["signed"], "signatures": [root2_document["signatures"][0]] * 2},
    separators=(",", ":"),
).encode()
oversized_signatures_root2 = json.dumps(
    {"signed": root2_document["signed"], "signatures": [root2_document["signatures"][0]] * 65},
    separators=(",", ":"),
).encode()
oversized_role_root2_document = json.loads(root2)
root_key_id = oversized_role_root2_document["signed"]["roles"]["root"]["keyids"][0]
oversized_role_root2_document["signed"]["roles"]["root"]["keyids"] = [root_key_id] * 65
oversized_role_root2 = json.dumps(oversized_role_root2_document, separators=(",", ":")).encode()
oversized_root_keys_document = json.loads(root2)
root_key = next(iter(oversized_root_keys_document["signed"]["keys"].values()))
oversized_root_keys_document["signed"]["keys"] = {
    f"{key_index:064x}": root_key for key_index in range(321)
}
oversized_root_keys = json.dumps(oversized_root_keys_document, separators=(",", ":")).encode()
if duplicate_root2 == root2 or tampered_root2 == root2 or unsupported_root2 == root2:
    raise SystemExit("generated root 2 no longer matches expected test transformations")
timestamp_document_with_duplicate_signature = {
    "signed": timestamp_document["signed"],
    "signatures": [timestamp_document["signatures"][0]] * 2,
}
duplicate_signature_timestamp = json.dumps(
    timestamp_document_with_duplicate_signature, separators=(",", ":")
).encode()

published_delegated_path = fixture_dir / "published-package-demo.json"
published_delegated_bytes = published_delegated_path.read_bytes()
published_delegated_document = json.loads(published_delegated_bytes)
package_target_path = next(iter(published_delegated_document["signed"]["targets"]))
archive_record = published_delegated_document["signed"]["targets"][package_target_path]
if package_target_path.split("/")[:3] != ["packages", "demo", "1.2.3"]:
    raise SystemExit("generated package fixture has an unexpected target path")
if archive_record["length"] <= 0 or archive_record["hashes"].get("sha256") not in package_target_path:
    raise SystemExit("generated package fixture path does not bind its archive digest")
bad_target_path = package_target_path.replace("/1.2.3/", "/1.2.4/")
if bad_target_path == package_target_path:
    raise SystemExit("generated package fixture path could not be altered for the negative probe")

def fixture_bytes(prefix, suffix):
    return (fixture_dir / f"{prefix}-{suffix}.json").read_bytes()

replacements = {
    "@@ROOT_BYTES@@": ", ".join(map(str, raw)),
    "@@ROOT_VERSION@@": str(signed["version"]),
    "@@ROOT_KEY_COUNT@@": str(len(signed["keys"])),
    "@@ROOT_THRESHOLD@@": str(signed["roles"]["root"]["threshold"]),
    "@@TAMPERED_ROOT_BYTES@@": ", ".join(map(str, tampered)),
    "@@UNSUPPORTED_SPEC_ROOT_BYTES@@": ", ".join(map(str, unsupported)),
    "@@UNSUPPORTED_KEY_ALGORITHM_BYTES@@": ", ".join(map(str, github_root)),
    "@@ROOT1_BYTES@@": ", ".join(map(str, rotation_roots[0].read_bytes())),
    "@@ROOT2_BYTES@@": ", ".join(map(str, root2)),
    "@@ROOT3_BYTES@@": ", ".join(map(str, rotation_roots[2].read_bytes())),
    "@@EXPIRED_ROOT_BYTES@@": ", ".join(map(str, expired_root_path.read_bytes())),
    "@@BOUNDARY_ROOT_BYTES@@": ", ".join(map(str, boundary_root_path.read_bytes())),
    "@@TIMESTAMP_BYTES@@": ", ".join(map(str, timestamp_path.read_bytes())),
    "@@EXPIRED_TIMESTAMP_BYTES@@": ", ".join(map(str, expired_timestamp_path.read_bytes())),
    "@@BOUNDARY_TIMESTAMP_BYTES@@": ", ".join(map(str, boundary_timestamp_path.read_bytes())),
    "@@DUPLICATE_ROOT2_BYTES@@": ", ".join(map(str, duplicate_root2)),
    "@@DUPLICATE_SIGNATURE_ROOT2_BYTES@@": ", ".join(map(str, duplicate_signature_root2)),
    "@@OVERSIZED_SIGNATURES_ROOT2_BYTES@@": ", ".join(map(str, oversized_signatures_root2)),
    "@@OVERSIZED_ROLE_ROOT2_BYTES@@": ", ".join(map(str, oversized_role_root2)),
    "@@OVERSIZED_ROOT_KEYS_BYTES@@": ", ".join(map(str, oversized_root_keys)),
    "@@DUPLICATE_SIGNATURE_TIMESTAMP_BYTES@@": ", ".join(map(str, duplicate_signature_timestamp)),
    "@@PUBLISHED_TIMESTAMP_BYTES@@": ", ".join(map(str, fixture_bytes("published", "timestamp"))),
    "@@PUBLISHED_SNAPSHOT_BYTES@@": ", ".join(map(str, fixture_bytes("published", "snapshot"))),
    "@@PUBLISHED_TARGETS_BYTES@@": ", ".join(map(str, fixture_bytes("published", "targets"))),
    "@@PUBLISHED_DELEGATED_TARGETS_BYTES@@": ", ".join(map(str, published_delegated_bytes)),
    "@@YANKED_TIMESTAMP_BYTES@@": ", ".join(map(str, fixture_bytes("yanked", "timestamp"))),
    "@@YANKED_SNAPSHOT_BYTES@@": ", ".join(map(str, fixture_bytes("yanked", "snapshot"))),
    "@@YANKED_DELEGATED_TARGETS_BYTES@@": ", ".join(map(str, fixture_bytes("yanked", "package-demo"))),
    "@@REVOKED_TIMESTAMP_BYTES@@": ", ".join(map(str, fixture_bytes("revoked", "timestamp"))),
    "@@REVOKED_SNAPSHOT_BYTES@@": ", ".join(map(str, fixture_bytes("revoked", "snapshot"))),
    "@@REVOKED_DELEGATED_TARGETS_BYTES@@": ", ".join(map(str, fixture_bytes("revoked", "package-demo"))),
    "@@BAD_SIGNATURE_TIMESTAMP_BYTES@@": ", ".join(map(str, fixture_bytes("bad-signature", "timestamp"))),
    "@@BAD_SIGNATURE_SNAPSHOT_BYTES@@": ", ".join(map(str, fixture_bytes("bad-signature", "snapshot"))),
    "@@BAD_SIGNATURE_DELEGATED_TARGETS_BYTES@@": ", ".join(map(str, fixture_bytes("bad-signature", "package-demo"))),
    "@@PACKAGE_TARGET_PATH_BYTES@@": ", ".join(map(str, package_target_path.encode())),
    "@@BAD_TARGET_PATH_BYTES@@": ", ".join(map(str, bad_target_path.encode())),
    "@@ARCHIVE_LENGTH@@": str(archive_record["length"]),
    "@@ARCHIVE_SHA256_BYTES@@": ", ".join(
        str(value) for value in bytes.fromhex(archive_record["hashes"]["sha256"])
    ),
    "@@DELEGATED_TARGETS_LENGTH@@": str(len(published_delegated_bytes)),
    "@@DELEGATED_TARGETS_SHA256_BYTES@@": ", ".join(
        str(value) for value in hashlib.sha256(published_delegated_bytes).digest()
    ),
    "@@TAMPERED_ROOT2_BYTES@@": ", ".join(map(str, tampered_root2)),
    "@@UNSUPPORTED_ROOT2_BYTES@@": ", ".join(map(str, unsupported_root2)),
}
source = template_path.read_text()
for marker, value in replacements.items():
    source = source.replace(marker, value)
if "@@" in source:
    raise SystemExit("unexpanded Elisa probe template marker")
output_path.write_text(source)
PY

STATIC_LIB="$CARGO_TARGET_DIR/release/libelisapkg_tuf_ffi_spike.a"
if [[ ! -f "$STATIC_LIB" ]]; then
  echo "error: Rust static library was not produced: $STATIC_LIB" >&2
  exit 2
fi

(cd "$WORK/package-root" && \
  ELISA_STAGE1_BIN="$STAGE1" \
  ELISA_RUNTIME_OBJ="$RUNTIME" \
    "$WRAPPER" -emit obj -o "$WORK/tuf-ffi-probe.o" "$WORK/abi_probe.elisa")

"${RUSTC:-rustc}" --edition=2021 "$SPIKE/ffi_runner.rs" \
  -L "native=$CARGO_TARGET_DIR/release" \
  -l static=elisapkg_tuf_ffi_spike \
  -C relocation-model=static \
  -C "link-arg=$WORK/tuf-ffi-probe.o" \
  -C "link-arg=$RUNTIME" \
  -o "$WORK/tuf-ffi-probe"

(cd "$WORK/package-root" && "$WORK/tuf-ffi-probe")
echo "TUF ABI v1 Rust/Elisa probe passed"
