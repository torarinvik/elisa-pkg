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
duplicate_root2 = root2.replace(b'"version":2', b'"version":2,"version":2', 1)
tampered_root2 = root2.replace(b'"consistent_snapshot":false', b'"consistent_snapshot":true', 1)
unsupported_root2 = root2.replace(b'"spec_version":"1.0.0"', b'"spec_version":"1.0.37"', 1)
if duplicate_root2 == root2 or tampered_root2 == root2 or unsupported_root2 == root2:
    raise SystemExit("generated root 2 no longer matches expected test transformations")

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
