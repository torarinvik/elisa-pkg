#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"
BIN="$ROOT/build/elisapkg"
# Keep every fixture and probe under one private directory so interrupted or
# successful runs cannot leave stale test files in the shared build tree.
TEST_TMP="$(mktemp -d "$ROOT/build/test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT
# The Elisa binary uses this same wrapper through execvp. Keep the smoke test
# independent of whatever compiler happens to be first on the developer's PATH.
if [[ -n "${ELISA_COMPILER_ROOT:-}" ]]; then
  export ELISAPKG_COMPILER="${ELISAPKG_COMPILER:-$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh}"
  export ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}"
fi
export ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}"
"$BIN" --version | grep -F 'elisapkg 0.1.0' >/dev/null
"$BIN" doctor | grep -F 'local Ed25519 provider available' >/dev/null
python3 "$ROOT/scripts/ffi_boundary_test.py"
python3 "$ROOT/scripts/ffi_fifo_regression.py"
python3 "$ROOT/scripts/install_lock_regression.py"
python3 "$ROOT/scripts/transaction_guard_regression.py"
python3 "$ROOT/scripts/sandbox_policy_test.py"

# Global output modes are strict: quiet suppresses human success text without
# hiding JSON results, and color values are validated even though the current
# renderer intentionally emits no ANSI escapes.
QUIET_FIXTURE="$TEST_TMP/quiet-fixture-$$"
mkdir "$QUIET_FIXTURE"
"$BIN" init "$QUIET_FIXTURE" >/dev/null
INIT_MODE_FIXTURE="$TEST_TMP/init-output-modes-$$"
init_quiet_output="$("$BIN" init "$INIT_MODE_FIXTURE" --quiet 2>/dev/null)"
test -z "$init_quiet_output"
if "$BIN" init "$TEST_TMP/init-color-invalid-$$" --color invalid >/dev/null 2>&1; then
  echo 'init accepted an invalid color mode' >&2
  exit 1
else
  test "$?" -eq 2
fi
quiet_output="$(cd "$QUIET_FIXTURE" && "$BIN" check-manifest --quiet 2>/dev/null)"
test -z "$quiet_output"
(
  cd "$QUIET_FIXTURE"
  "$BIN" resolve >/dev/null
)
quiet_tree="$(cd "$QUIET_FIXTURE" && "$BIN" tree --quiet 2>/dev/null)"
test -z "$quiet_tree"
(
  cd "$QUIET_FIXTURE"
  "$BIN" check-manifest --color always >/dev/null
  "$BIN" check-manifest --color never >/dev/null
)
if (cd "$QUIET_FIXTURE" && "$BIN" check-manifest --color invalid >/dev/null 2>&1); then
  echo 'invalid color mode was accepted' >&2
  exit 1
fi
json_quiet="$(cd "$QUIET_FIXTURE" && "$BIN" check-manifest --json --quiet)"
test "$json_quiet" = '{"schema-version":1,"valid":true,"manifest":"elisapkg.json"}'

# Credential filtering is relative to the package root. A checkout nested under
# a credential-store directory must still fingerprint its own source files.
ANCESTOR_FIXTURE="$TEST_TMP/.config/gcloud/ordinary-package"
mkdir -p "$TEST_TMP/.config/gcloud"
"$BIN" init "$ANCESTOR_FIXTURE" >/dev/null
(
  cd "$ANCESTOR_FIXTURE"
  "$BIN" resolve >/dev/null
  cp src/main.elisa "$TEST_TMP/ancestor-project-main.good"
  printf '%s\n' '# source identity must include this package file' >> src/main.elisa
  if "$BIN" resolve --frozen >/dev/null 2>&1; then
    echo "source under a credential-named ancestor was omitted from the lock digest" >&2
    exit 1
  else
    test "$?" -eq 3
  fi
  cp "$TEST_TMP/ancestor-project-main.good" src/main.elisa
  "$BIN" resolve --frozen >/dev/null
)

# If the package root itself is a credential-store directory, its children
# have ordinary relative names. Resolution must reject that root explicitly.
for CREDENTIAL_ROOT in "$TEST_TMP/.docker" "$TEST_TMP/.config" "$TEST_TMP/.config/gh"; do
  "$BIN" init "$CREDENTIAL_ROOT" >/dev/null
  if (cd "$CREDENTIAL_ROOT" && "$BIN" resolve >/dev/null 2>&1); then
    echo "resolution accepted a package rooted in a credential store: $CREDENTIAL_ROOT" >&2
    exit 1
  fi
done

# Exercise the pure SemVer requirement module independently of the CLI. This
# keeps parser/range regressions visible without requiring a registry fixture.
SEMVER_PROBE="$TEST_TMP/semver-probe-$$.elisa"
SEMVER_BIN="$TEST_TMP/semver-probe-$$"
cat > "$SEMVER_PROBE" <<EOF
include "$ROOT/src/model.elisa"
include "$ROOT/src/semver.elisa"

def main() -> i64:
    caret: mutable darray[u8] = [94, 49, 46, 50, 46, 51]
    exact: mutable darray[u8] = [49, 46, 50, 46, 51]
    pair: mutable darray[u8] = [62, 61, 49, 46, 48, 46, 48, 32, 60, 50, 46, 48, 46, 48]
    bad: mutable darray[u8] = [49, 46, 48, 46, 48, 45, 48, 49]
    alpha: mutable darray[u8] = [49, 46, 48, 46, 48, 45, 97, 108, 112, 104, 97]
    beta: mutable darray[u8] = [49, 46, 48, 46, 48, 45, 98, 101, 116, 97]
    stable: mutable darray[u8] = [49, 46, 48, 46, 48]
    blank: mutable SemVer::Requirement = SemVer::Requirement{lower: Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}, upper: Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}, has_lower: false, has_upper: false, include_lower: false, include_upper: false}
    return 1 if not SemVer::parse_requirement(caret, &blank)
    return 2 if not SemVer::matches(blank, Model::Version{major: 1, minor: 9, patch: 0, prerelease: false})
    return 3 if SemVer::matches(blank, Model::Version{major: 2, minor: 0, patch: 0, prerelease: false})
    return 4 if not SemVer::parse_requirement(exact, &blank)
    return 5 if not SemVer::matches(blank, Model::Version{major: 1, minor: 2, patch: 3, prerelease: false})
    return 6 if SemVer::matches(blank, Model::Version{major: 1, minor: 2, patch: 4, prerelease: false})
    return 7 if not SemVer::parse_requirement(pair, &blank)
    return 8 if not SemVer::matches(blank, Model::Version{major: 1, minor: 7, patch: 0, prerelease: false})
    return 9 if SemVer::matches(blank, Model::Version{major: 2, minor: 0, patch: 0, prerelease: false})
    return 10 if SemVer::parse_requirement(bad, &blank)
    return 11 if SemVer::compare_text(alpha, beta) != -1
    return 12 if SemVer::compare_text(alpha, stable) != -1
    return 13 if SemVer::compare_text(beta, alpha) != 1
    return 14 if SemVer::compare_text(stable, alpha) != 1
    empty_range: mutable darray[u8] = [62, 49, 46, 48, 46, 48, 46, 48, 32, 60, 61, 49, 46, 48, 46, 48]
    return 15 if SemVer::parse_requirement(empty_range, &blank)
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$SEMVER_BIN" "$SEMVER_PROBE"
"$SEMVER_BIN"

# The resolver primitive has no network/provider dependency. Verify highest
# satisfying selection, prerelease ordering, and fail-closed catalog parsing.
RESOLVE_PROBE="$TEST_TMP/resolve-probe-$$.elisa"
RESOLVE_BIN="$TEST_TMP/resolve-probe-$$"
cat > "$RESOLVE_PROBE" <<EOF
include "$ROOT/src/resolve.elisa"

def same(value: darray[u8]&, expected: cstr) -> bool:
    length: mutable usize = 0.usize()
    while expected[length].u8() != 0:
        length <- length + 1.usize()
    return false if value.count != length
    for index in 0..<length |value, expected|:
        return false if value[index] != expected[index].u8()
    return true

def main() -> i64:
    catalog: mutable darray[u8] = [49, 46, 48, 46, 48, 10, 49, 46, 53, 46, 48, 10, 49, 46, 53, 46, 48, 45, 97, 108, 112, 104, 97, 10, 50, 46, 48, 46, 48, 10]
    caret: mutable darray[u8] = [94, 49, 46, 48, 46, 48]
    selected: mutable darray[u8] = []
    return 1 if not Resolve::select_highest_version(catalog, caret, &selected)
    return 2 if not same(selected, "1.5.0")
    pair: mutable darray[u8] = [62, 61, 49, 46, 53, 46, 48, 32, 60, 50, 46, 48, 46, 48]
    return 3 if not Resolve::select_highest_version(catalog, pair, &selected)
    return 4 if not same(selected, "1.5.0")
    duplicate: mutable darray[u8] = [49, 46, 48, 46, 48, 10, 49, 46, 48, 46, 48, 10]
    return 5 if Resolve::select_highest_version(duplicate, caret, &selected)
    invalid: mutable darray[u8] = [49, 46, 48, 10]
    return 6 if Resolve::select_highest_version(invalid, caret, &selected)
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$RESOLVE_BIN" "$RESOLVE_PROBE"
"$RESOLVE_BIN"

# Trust policy prechecks are distinct from cryptographic verification. Exercise
# their expiry, rollback, namespace, and algorithm failures while the production
# remote provider remains disabled.
TRUST_PROBE="$TEST_TMP/trust-probe-$$.elisa"
TRUST_BIN="$TEST_TMP/trust-probe-$$"
cat > "$TRUST_PROBE" <<EOF
include "$ROOT/src/trust.elisa"

def main() -> i64:
    package: mutable darray[u8] = [97, 99, 109, 101, 47, 97, 112, 112]
    namespace: mutable darray[u8] = [97, 99, 109, 101]
    other: mutable darray[u8] = [101, 118, 105, 108]
    return 1 if Trust::precheck_metadata(4, 3, 100, 200) != Trust::VerificationCode.RollbackDetected
    return 2 if Trust::precheck_metadata(4, 4, 200, 200) != Trust::VerificationCode.ExpiredMetadata
    return 3 if Trust::precheck_metadata(4, 5, 100, 200) != Trust::VerificationCode.Valid
    return 4 if Trust::precheck_algorithm("rsa") != Trust::VerificationCode.UnknownAlgorithm
    return 5 if Trust::precheck_algorithm("ed25519") != Trust::VerificationCode.Valid
    return 6 if Trust::precheck_namespace(package, namespace) != Trust::VerificationCode.Valid
    return 7 if Trust::precheck_namespace(package, other) != Trust::VerificationCode.UnauthorizedNamespace
    registry: mutable darray[u8] = [112, 114, 105, 109, 97, 114, 121]
    mirror: mutable darray[u8] = [109, 105, 114, 114, 111, 114]
    version: mutable darray[u8] = [49, 46, 48, 46, 48]
    digest: mutable darray[u8] = [100, 105, 103, 101, 115, 116]
    return 8 if Trust::precheck_binding(registry, registry, package, package, version, version, digest, digest, 3, 3) != Trust::VerificationCode.Valid
    return 9 if Trust::precheck_binding(mirror, registry, package, package, version, version, digest, digest, 3, 3) != Trust::VerificationCode.WrongRegistry
    return 10 if Trust::precheck_binding(registry, registry, package, package, version, version, digest, digest, 2, 3) != Trust::VerificationCode.ArchiveSizeMismatch
    return 11 if Trust::precheck_publisher_attestation(false) != Trust::VerificationCode.MissingPublisherAttestation
    return 12 if Trust::precheck_threshold(1, 2) != Trust::VerificationCode.ThresholdInsufficient
    return 13 if Trust::precheck_revocation(true) != Trust::VerificationCode.RevokedKey
    return 14 if Trust::precheck_clock(9, 8) != Trust::VerificationCode.ClockRollback
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_BIN" "$TRUST_PROBE"
"$TRUST_BIN"

# The provider path is exercised with a fixed Ed25519 vector. A valid detached
# signature must pass, while a one-byte mutation must fail closed.
CRYPTO_PROBE="$TEST_TMP/crypto-probe-$$.elisa"
CRYPTO_BIN="$TEST_TMP/crypto-probe-$$"
cat > "$CRYPTO_PROBE" <<EOF
include "$ROOT/src/trust.elisa"

def main() -> i64:
    public_key: mutable darray[u8] = [210,215,81,194,128,33,126,204,53,156,34,244,6,136,131,235,211,40,218,212,248,228,62,102,227,40,136,58,31,197,139,182]
    message: mutable darray[u8] = [115,105,103,110,101,100,32,109,101,115,115,97,103,101]
    signature: mutable darray[u8] = [56,127,124,128,177,193,186,187,254,246,65,194,183,136,113,123,176,137,87,75,172,103,193,38,147,182,192,39,141,37,36,99,91,152,227,12,212,208,239,177,87,48,112,226,96,86,5,98,91,112,95,218,34,97,244,169,23,44,233,89,231,84,107,14]
    return 1 if Trust::verify_detached("ed25519", public_key, message, signature) != Trust::VerificationCode.Valid
    signature[0] <- signature[0] + 1
    return 2 if Trust::verify_detached("ed25519", public_key, message, signature) == Trust::VerificationCode.Valid
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$CRYPTO_BIN" "$CRYPTO_PROBE"
"$CRYPTO_BIN"

# The registry adapter must fail closed when no explicit source root is
# configured. This also compiles the full provider graph as a standalone
# module, keeping its public/private boundary independent of the CLI.
REGISTRY_PROBE="$TEST_TMP/registry-probe-$$.elisa"
REGISTRY_BIN="$TEST_TMP/registry-probe-$$"
cat > "$REGISTRY_PROBE" <<EOF
include "$ROOT/src/registry.elisa"

def main() -> i64:
    package: mutable darray[u8] = [101, 120, 97, 109, 112, 108, 101]
    requirement: mutable darray[u8] = [49, 46, 48, 46, 48]
    selected: mutable darray[u8] = []
    archive: mutable darray[u8] = []
    digest: mutable darray[u8] = []
    metadata: mutable darray[u8] = []
    size: mutable u64 = 0
    previous: Model::Version = Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}
    status: Registry::ResultCode = Registry::resolve(package, requirement, previous, &selected, &archive, &digest, &size, &metadata)
    if Platform::pkg_getenv("ELISAPKG_REGISTRY_DIR") is configured:
        if Platform::pkg_getenv("ELISAPKG_EXPECT_MISSING_TRUST_ROOT") is expected_missing:
            return 0 if status == Registry::ResultCode.MissingTrustRoot
            return 1
        return 0 if status == Registry::ResultCode.InvalidConfiguration
        return 1
    return 0 if status == Registry::ResultCode.NotConfigured else 1
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$REGISTRY_BIN" "$REGISTRY_PROBE"
env -u ELISAPKG_REGISTRY_DIR -u ELISAPKG_REGISTRY_TRUST_ROOT "$REGISTRY_BIN"
if ! ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$ROOT/../escape.key" "$REGISTRY_BIN" >/dev/null 2>&1; then
  echo "trust-root traversal override was not rejected as invalid configuration" >&2
  exit 1
fi
TRUST_ROOT_FIXTURE_REGISTRY="$TEST_TMP/registry-with-trust-root"
TRUST_ROOT_FIXTURE_KEY="$TRUST_ROOT_FIXTURE_REGISTRY/trust/key"
mkdir -m 700 -p "$TRUST_ROOT_FIXTURE_REGISTRY/trust"
python3 - "$TRUST_ROOT_FIXTURE_KEY" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as stream:
    stream.write(bytes(range(32)))
os.chmod(sys.argv[1], 0o600)
PY
if ! ELISAPKG_REGISTRY_DIR="$TRUST_ROOT_FIXTURE_REGISTRY" ELISAPKG_REGISTRY_TRUST_ROOT="$TRUST_ROOT_FIXTURE_KEY" "$REGISTRY_BIN" >/dev/null 2>&1; then
  echo "trust root inside registry was not rejected as invalid configuration" >&2
  exit 1
fi
TRUST_ROOT_FIXTURE_ALIAS="$TEST_TMP/registry-with-trust-root-alias"
ln -s "$TRUST_ROOT_FIXTURE_REGISTRY" "$TRUST_ROOT_FIXTURE_ALIAS"
if ! ELISAPKG_REGISTRY_DIR="$TRUST_ROOT_FIXTURE_ALIAS" ELISAPKG_REGISTRY_TRUST_ROOT="$TRUST_ROOT_FIXTURE_KEY" "$REGISTRY_BIN" >/dev/null 2>&1; then
  echo "trust root inside canonical registry was not rejected through an alias" >&2
  exit 1
fi
TRUST_ROOT_MISSING="$TRUST_ROOT_FIXTURE_REGISTRY/trust/missing-key"
if ! ELISAPKG_REGISTRY_DIR="$TRUST_ROOT_FIXTURE_ALIAS" ELISAPKG_REGISTRY_TRUST_ROOT="$TRUST_ROOT_MISSING" ELISAPKG_EXPECT_MISSING_TRUST_ROOT=1 "$REGISTRY_BIN" >/dev/null 2>&1; then
  echo "unresolvable trust root did not fail as missing trust material" >&2
  exit 1
fi
TRUST_ROOT_EXTERNAL_DIR="$TEST_TMP/trust-root-external"
TRUST_ROOT_EXTERNAL_KEY="$TRUST_ROOT_EXTERNAL_DIR/key"
mkdir -m 700 "$TRUST_ROOT_EXTERNAL_DIR"
python3 - "$TRUST_ROOT_EXTERNAL_KEY" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as stream:
    stream.write(bytes(range(32)))
os.chmod(sys.argv[1], 0o600)
PY
if ! ELISAPKG_REGISTRY_DIR="$TEST_TMP/missing-registry-root" ELISAPKG_REGISTRY_TRUST_ROOT="$TRUST_ROOT_EXTERNAL_KEY" "$REGISTRY_BIN" >/dev/null 2>&1; then
  echo "unresolvable registry root was not rejected as invalid configuration" >&2
  exit 1
fi

# Registry graph resolution excludes signed, expired historical releases while
# retaining hard failures for malformed expiry data. Generate ephemeral keys
# with the same OpenSSL executable search order used by the native verifier.
REGISTRY_EXPIRY_CASE="$TEST_TMP/registry-expiry-regression"
REGISTRY_EXPIRY_ROOT="$REGISTRY_EXPIRY_CASE/registry"
REGISTRY_EXPIRY_KEY="$REGISTRY_EXPIRY_CASE/trust/key"
REGISTRY_EXPIRY_PRIVATE="$REGISTRY_EXPIRY_CASE/test-private.pem"
REGISTRY_EXPIRY_PUBLIC_DER="$REGISTRY_EXPIRY_CASE/test-public.der"
REGISTRY_EXPIRY_SOURCE="$REGISTRY_EXPIRY_CASE/archive-source"
REGISTRY_EXPIRY_APP="$REGISTRY_EXPIRY_CASE/app-broad"
REGISTRY_EXPIRY_EXACT_APP="$REGISTRY_EXPIRY_CASE/app-exact"
REGISTRY_EXPIRY_MALFORMED_APP="$REGISTRY_EXPIRY_CASE/app-malformed"
REGISTRY_EXPIRY_LONG_APP="$REGISTRY_EXPIRY_CASE/app-long-expiry"
REGISTRY_EXPIRY_SNAPSHOT_PROBE="$REGISTRY_EXPIRY_CASE/expiry-snapshot-probe.elisa"
REGISTRY_EXPIRY_SNAPSHOT_BIN="$REGISTRY_EXPIRY_CASE/expiry-snapshot-probe"
REGISTRY_EXPIRY_STATE="$REGISTRY_EXPIRY_CASE/trust.state"
REGISTRY_EXPIRY_MALFORMED_STATE="$REGISTRY_EXPIRY_CASE/trust-malformed.state"
OPENSSL_BIN=""
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/opt/openssl/bin/openssl /usr/bin/openssl; do
  if [[ -x "$candidate" ]]; then
    OPENSSL_BIN="$candidate"
    break
  fi
done
if [[ -z "$OPENSSL_BIN" ]]; then
  echo "no OpenSSL executable is available for signed registry regression fixtures" >&2
  exit 1
fi
mkdir -m 700 -p "$REGISTRY_EXPIRY_ROOT" "$REGISTRY_EXPIRY_CASE/trust"
"$OPENSSL_BIN" genpkey -algorithm ED25519 -out "$REGISTRY_EXPIRY_PRIVATE"
chmod 600 "$REGISTRY_EXPIRY_PRIVATE"
"$OPENSSL_BIN" pkey -in "$REGISTRY_EXPIRY_PRIVATE" -pubout -outform DER -out "$REGISTRY_EXPIRY_PUBLIC_DER"
python3 - "$REGISTRY_EXPIRY_PUBLIC_DER" "$REGISTRY_EXPIRY_KEY" <<'PY'
from pathlib import Path
import os, sys

der = Path(sys.argv[1]).read_bytes()
prefix = bytes.fromhex("302a300506032b6570032100")
if len(der) != len(prefix) + 32 or not der.startswith(prefix):
    raise SystemExit("OpenSSL emitted an unexpected Ed25519 public-key encoding")
Path(sys.argv[2]).write_bytes(der[-32:])
os.chmod(sys.argv[2], 0o600)
PY
"$BIN" init "$REGISTRY_EXPIRY_SOURCE" >/dev/null
(
  cd "$REGISTRY_EXPIRY_SOURCE"
  "$BIN" resolve >/dev/null
  "$BIN" package >/dev/null
)
python3 - "$REGISTRY_EXPIRY_ROOT" "$REGISTRY_EXPIRY_SOURCE/.elisapkg/package.tar" "$REGISTRY_EXPIRY_PRIVATE" "$OPENSSL_BIN" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys, time

root = Path(sys.argv[1])
archive = Path(sys.argv[2]).read_bytes()
private_key = sys.argv[3]
openssl = sys.argv[4]
digest = hashlib.sha256(archive).hexdigest()
root.mkdir(mode=0o700, parents=True, exist_ok=True)
for version, expires in (("1.0.0", 1), ("1.1.0", int(time.time()) + 3600)):
    version_dir = root / "foo" / version
    version_dir.mkdir(mode=0o700, parents=True)
    (version_dir / "archive.tar").write_bytes(archive)
    metadata = {
        "schema-version": 1,
        "algorithm": "ed25519",
        "registry": str(root),
        "package": "foo",
        "version": version,
        "archive": "archive.tar",
        "archive-size": len(archive),
        "archive-digest": digest,
        "expires": expires,
    }
    metadata_path = version_dir / "metadata.json"
    metadata_path.write_bytes((json.dumps(metadata, separators=(",", ":")) + "\n").encode())
    subprocess.run([openssl, "pkeyutl", "-sign", "-rawin", "-inkey", private_key,
                    "-in", str(metadata_path), "-out", str(version_dir / "metadata.sig")],
                   check=True)
(root / "foo" / "index").write_text("1.0.0\n1.1.0\n", encoding="ascii")
PY

write_registry_dependency() {
  local app="$1"
  local requirement="$2"
  "$BIN" init "$app" >/dev/null
  python3 - "$app/elisapkg.json" "$requirement" <<'PY'
from pathlib import Path
import json, sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["dependencies"] = {"foo": {"version": sys.argv[2], "registry": "primary"}}
path.write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

write_registry_dependency "$REGISTRY_EXPIRY_APP" "^1.0.0"
(
  cd "$REGISTRY_EXPIRY_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_STATE" \
    "$BIN" resolve >/dev/null
)
python3 - "$REGISTRY_EXPIRY_APP/elisapkg.lock" <<'PY'
from pathlib import Path
import json, sys

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
versions = [record["version"] for record in lock["packages"] if record["name"] == "foo"]
if versions != ["1.1.0"]:
    raise SystemExit(f"expired historical release affected resolution: {versions!r}")
PY

# Populate the signed metadata cache through the normal provider path, then
# hide all package provider files during offline validation. The configured
# trust root remains available because snapshot verification checks its
# registry binding before using the cached metadata and signature.
(
  cd "$REGISTRY_EXPIRY_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_STATE" \
    "$BIN" fetch >/dev/null
)
mv "$REGISTRY_EXPIRY_ROOT/foo" "$REGISTRY_EXPIRY_CASE/foo.offline-hidden"
(
  cd "$REGISTRY_EXPIRY_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
    ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_STATE" \
    "$BIN" fetch --offline >/dev/null
)
mv "$REGISTRY_EXPIRY_CASE/foo.offline-hidden" "$REGISTRY_EXPIRY_ROOT/foo"

# The expired artifact itself must remain unavailable even when it is pinned.
write_registry_dependency "$REGISTRY_EXPIRY_EXACT_APP" "1.0.0"
if (
  cd "$REGISTRY_EXPIRY_EXACT_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_STATE" \
    "$BIN" resolve >/dev/null 2>&1
); then
  echo "resolution accepted a pinned expired registry version" >&2
  exit 1
else
  test "$?" -eq 3
fi
test ! -e "$REGISTRY_EXPIRY_EXACT_APP/elisapkg.lock"

# An absent expiry is malformed metadata, not a stale release to skip.
python3 - "$REGISTRY_EXPIRY_ROOT/foo/1.0.0/metadata.json" <<'PY'
from pathlib import Path
import json, sys

path = Path(sys.argv[1])
metadata = json.loads(path.read_text(encoding="utf-8"))
metadata.pop("expires")
path.write_text(json.dumps(metadata, separators=(",", ":")) + "\n", encoding="utf-8")
PY
"$OPENSSL_BIN" pkeyutl -sign -rawin -inkey "$REGISTRY_EXPIRY_PRIVATE" \
  -in "$REGISTRY_EXPIRY_ROOT/foo/1.0.0/metadata.json" \
  -out "$REGISTRY_EXPIRY_ROOT/foo/1.0.0/metadata.sig"
write_registry_dependency "$REGISTRY_EXPIRY_MALFORMED_APP" "^1.0.0"
if (
  cd "$REGISTRY_EXPIRY_MALFORMED_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_MALFORMED_STATE" \
    "$BIN" resolve >/dev/null 2>&1
); then
  echo "resolution skipped signed metadata with a malformed expiry" >&2
  exit 1
else
  test "$?" -eq 5
fi
test ! -e "$REGISTRY_EXPIRY_MALFORMED_APP/elisapkg.lock"

# A valid signature does not permit effectively permanent replay. The client
# caps each release metadata lifetime at 30 days and treats longer signed
# expiries as a security error instead of silently selecting another version.
python3 - "$REGISTRY_EXPIRY_ROOT" "$REGISTRY_EXPIRY_SOURCE/.elisapkg/package.tar" "$REGISTRY_EXPIRY_PRIVATE" "$OPENSSL_BIN" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys

root = Path(sys.argv[1])
archive = Path(sys.argv[2]).read_bytes()
private_key = sys.argv[3]
openssl = sys.argv[4]
digest = hashlib.sha256(archive).hexdigest()
version_dir = root / "foo" / "1.2.0"
version_dir.mkdir(mode=0o700, parents=True)
(version_dir / "archive.tar").write_bytes(archive)
metadata = {
    "schema-version": 1,
    "algorithm": "ed25519",
    "registry": str(root),
    "package": "foo",
    "version": "1.2.0",
    "archive": "archive.tar",
    "archive-size": len(archive),
    "archive-digest": digest,
    "expires": 18446744073709551615,
}
metadata_path = version_dir / "metadata.json"
metadata_path.write_bytes((json.dumps(metadata, separators=(",", ":")) + "\n").encode())
subprocess.run([openssl, "pkeyutl", "-sign", "-rawin", "-inkey", private_key,
                "-in", str(metadata_path), "-out", str(version_dir / "metadata.sig")],
               check=True)
(root / "foo" / "index").write_text("1.1.0\n1.2.0\n", encoding="ascii")
PY
cat > "$REGISTRY_EXPIRY_SNAPSHOT_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    metadata: mutable darray[u8] = []
    metadata.resize(1048576)
    metadata_raw: mutable u8& = (&metadata[0]).cast[mutable u8&] can Unsafe.PointerCast
    metadata_size: i64 = Platform::pkg_read_trusted_file("$REGISTRY_EXPIRY_ROOT/foo/1.2.0/metadata.json", metadata_raw, metadata.count)
    return 1 if metadata_size <= 0
    metadata.resize(metadata_size.usize())
    signature: mutable darray[u8] = []
    # The trusted-file API reserves an extra byte to detect exact-limit files.
    signature.resize(65)
    signature_raw: mutable u8& = (&signature[0]).cast[mutable u8&] can Unsafe.PointerCast
    return 2 if Platform::pkg_read_trusted_file("$REGISTRY_EXPIRY_ROOT/foo/1.2.0/metadata.sig", signature_raw, signature.count) != 64
    signature.resize(64)
    metadata_digest_bytes: mutable darray[u8] = []
    metadata_digest: mutable darray[u8] = []
    return 3 if Integrity::sha256(metadata, &metadata_digest_bytes) != Integrity::DigestCode.Ok or not Integrity::hex_digest(metadata_digest_bytes, &metadata_digest)
    package: mutable darray[u8] = [102,111,111]
    version: mutable darray[u8] = [49,46,50,46,48]
    archive: mutable darray[u8] = []
    digest: mutable darray[u8] = []
    archive_size: mutable u64 = 0
    expires: mutable u64 = 0
    dependencies: mutable darray[Solver::Constraint] = []
    status: Registry::ResultCode = Registry::verify_metadata_snapshot(package, version, metadata_digest, metadata, signature, &archive, &digest, &archive_size, &expires, &dependencies)
    return 0 if status == Registry::ResultCode.ExpiryHorizon else 4
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$REGISTRY_EXPIRY_SNAPSHOT_BIN" "$REGISTRY_EXPIRY_SNAPSHOT_PROBE"
ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  "$REGISTRY_EXPIRY_SNAPSHOT_BIN"
write_registry_dependency "$REGISTRY_EXPIRY_LONG_APP" "^1.0.0"
if (
  cd "$REGISTRY_EXPIRY_LONG_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_CASE/trust-long.state" \
    "$BIN" resolve >/dev/null 2>&1
); then
  echo "resolution accepted signed metadata beyond the expiry horizon" >&2
  exit 1
else
  test "$?" -eq 5
fi
test ! -e "$REGISTRY_EXPIRY_LONG_APP/elisapkg.lock"

# The index is unsigned local filesystem data. A writable package directory
# must be rejected as a security failure before it can omit or replace entries.
chmod 0770 "$REGISTRY_EXPIRY_ROOT/foo"
if (
  cd "$REGISTRY_EXPIRY_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_STATE" \
    "$BIN" resolve >/dev/null 2>"$TEST_TMP/untrusted-index-parent.err"
); then
  echo "resolution accepted an index beneath a group-writable parent" >&2
  exit 1
else
  test "$?" -eq 5
fi
grep -F "registry configuration is invalid" "$TEST_TMP/untrusted-index-parent.err" >/dev/null

# Trust anchors are opened and read through one descriptor. Secure roots work;
# writable parents, writable key files, and symlinked path components fail.
TRUST_READ_PROBE="$TEST_TMP/trusted-read-probe-$$.elisa"
TRUST_READ_BIN="$TEST_TMP/trusted-read-probe-$$"
TRUST_ROOT_DIR="$TEST_TMP/trusted-root"
TRUST_ROOT_DIR_LINK="$TEST_TMP/trusted-root-link"
TRUST_ROOT_FILE="$TRUST_ROOT_DIR/key"
TRUST_ROOT_INSECURE_DIR="$TEST_TMP/trusted-root-insecure"
TRUST_ROOT_INSECURE_FILE="$TRUST_ROOT_INSECURE_DIR/key"
TRUST_ROOT_SYMLINK_FILE="$TEST_TMP/trusted-root-symlink"
mkdir -m 700 "$TRUST_ROOT_DIR"
mkdir -m 777 "$TRUST_ROOT_INSECURE_DIR"
python3 - "$TRUST_ROOT_FILE" "$TRUST_ROOT_INSECURE_FILE" <<'PY'
from pathlib import Path
import sys

key = bytes(range(32))
for name in sys.argv[1:]:
    Path(name).write_bytes(key)
Path(sys.argv[1]).chmod(0o600)
Path(sys.argv[2]).chmod(0o600)
PY
chmod 666 "$TRUST_ROOT_INSECURE_FILE"
ln -s "$TRUST_ROOT_DIR" "$TRUST_ROOT_DIR_LINK"
ln -s "$TRUST_ROOT_FILE" "$TRUST_ROOT_SYMLINK_FILE"
cat > "$TRUST_READ_PROBE" <<EOF
include "$ROOT/src/platform.elisa"

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    key: mutable darray[u8] = []
    key.resize(33)
    key_raw: mutable u8& = (&key[0]).cast[mutable u8&] can Unsafe.PointerCast
    return 1 if Platform::pkg_read_trusted_file("$TRUST_ROOT_FILE", key_raw, key.count) != 32
    return 2 if key[0] != 0 or key[31] != 31
    return 3 if Platform::pkg_read_trusted_file("$TRUST_ROOT_INSECURE_FILE", key_raw, key.count) >= 0
    return 4 if Platform::pkg_read_trusted_file("$TRUST_ROOT_DIR_LINK/key", key_raw, key.count) >= 0
    return 5 if Platform::pkg_read_trusted_file("$TRUST_ROOT_SYMLINK_FILE", key_raw, key.count) >= 0
    return 6 if Platform::pkg_is_trusted_directory("$TRUST_ROOT_INSECURE_DIR") != 0
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_READ_BIN" "$TRUST_READ_PROBE"
"$TRUST_READ_BIN"

# Darwin's mode bits do not reflect extended ACL grants. Deny-only ACLs are
# common on HOME and remain acceptable; any extended allow ACE must invalidate
# a trusted directory even when chmod still reports mode 0700.
if [ "$(uname -s)" = "Darwin" ]; then
  ACL_NONE_DIR="$TEST_TMP/acl-none"
  ACL_DENY_DIR="$TEST_TMP/acl-deny"
  ACL_ALLOW_DIR="$TEST_TMP/acl-allow"
  ACL_DENY_FILE="$TEST_TMP/acl-deny-file"
  ACL_ALLOW_FILE="$TEST_TMP/acl-allow-file"
  mkdir -m 700 "$ACL_NONE_DIR" "$ACL_DENY_DIR" "$ACL_ALLOW_DIR"
  cp "$TRUST_ROOT_FILE" "$ACL_DENY_FILE"
  cp "$TRUST_ROOT_FILE" "$ACL_ALLOW_FILE"
  chmod 600 "$ACL_DENY_FILE" "$ACL_ALLOW_FILE"
  chmod +a "everyone deny delete" "$ACL_DENY_DIR"
  chmod +a "everyone allow add_file,delete_child" "$ACL_ALLOW_DIR"
  chmod +a "everyone deny write" "$ACL_DENY_FILE"
  chmod +a "everyone allow write" "$ACL_ALLOW_FILE"
  ACL_PROBE="$TEST_TMP/trusted-acl-probe-$$.elisa"
  ACL_BIN="$TEST_TMP/trusted-acl-probe-$$"
  cat > "$ACL_PROBE" <<EOF
include "$ROOT/src/platform.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    return 1 if Platform::pkg_is_trusted_directory("$ACL_NONE_DIR") != 1
    return 2 if Platform::pkg_is_trusted_directory("$ACL_DENY_DIR") != 1
    return 3 if Platform::pkg_is_trusted_directory("$ACL_ALLOW_DIR") != 0
    denied_key: mutable darray[u8] = []
    denied_key.resize(33)
    denied_raw: mutable u8& = (&denied_key[0]).cast[mutable u8&] can Unsafe.PointerCast
    return 4 if Platform::pkg_read_trusted_file("$ACL_DENY_FILE", denied_raw, denied_key.count) != 32
    return 5 if denied_key[0] != 0 or denied_key[31] != 31
    allowed_key: mutable darray[u8] = []
    allowed_key.resize(33)
    allowed_raw: mutable u8& = (&allowed_key[0]).cast[mutable u8&] can Unsafe.PointerCast
    return 6 if Platform::pkg_read_trusted_file("$ACL_ALLOW_FILE", allowed_raw, allowed_key.count) >= 0
    return 0
EOF
  ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
  ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
  ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
    "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$ACL_BIN" "$ACL_PROBE"
  "$ACL_BIN"
  test "$(stat -f '%Lp' "$ACL_ALLOW_DIR")" = "700"
  test "$(stat -f '%Lp' "$ACL_ALLOW_FILE")" = "600"
  chmod -a "everyone deny delete" "$ACL_DENY_DIR"
  chmod -a "everyone allow add_file,delete_child" "$ACL_ALLOW_DIR"
  chmod -a "everyone deny write" "$ACL_DENY_FILE"
  chmod -a "everyone allow write" "$ACL_ALLOW_FILE"
fi

# Persistent trust state is outside the project lockfile. Verify monotonic
# versions, same-version archive/metadata digest pinning, durable re-entry, and fail-closed
# malformed/duplicate history handling through the public Registry boundary.
TRUST_STATE_PROBE="$TEST_TMP/trust-state-probe-$$.elisa"
TRUST_STATE_BIN="$TEST_TMP/trust-state-probe-$$"
TRUST_STATE_FILE="$TEST_TMP/trust-state-$$.state"
TRUST_STATE_V1_PROBE="$TEST_TMP/trust-state-v1-probe-$$.elisa"
TRUST_STATE_V1_BIN="$TEST_TMP/trust-state-v1-probe-$$"
TRUST_STATE_V1_SNAPSHOT="$TEST_TMP/trust-state-v1-$$.snapshot"
TRUST_STATE_V2_SNAPSHOT="$TEST_TMP/trust-state-v2-$$.snapshot"
TRUST_STATE_REPEAT_PROBE="$TEST_TMP/trust-state-repeat-$$.elisa"
TRUST_STATE_REPEAT_BIN="$TEST_TMP/trust-state-repeat-$$"
TRUST_STATE_VERIFY_V1_PROBE="$TEST_TMP/trust-state-verify-v1-$$.elisa"
TRUST_STATE_VERIFY_V1_BIN="$TEST_TMP/trust-state-verify-v1-$$"
TRUST_STATE_VERIFY_FAIL_PROBE="$TEST_TMP/trust-state-verify-fail-$$.elisa"
TRUST_STATE_VERIFY_FAIL_BIN="$TEST_TMP/trust-state-verify-fail-$$"
TRUST_STATE_RECORD_EXPIRED_PROBE="$TEST_TMP/trust-state-record-expired-$$.elisa"
TRUST_STATE_RECORD_EXPIRED_BIN="$TEST_TMP/trust-state-record-expired-$$"
TRUST_STATE_LEGACY_PROBE="$TEST_TMP/trust-state-legacy-$$.elisa"
TRUST_STATE_LEGACY_BIN="$TEST_TMP/trust-state-legacy-$$"
TRUST_STATE_LEGACY_FILE="$TEST_TMP/trust-state-legacy-$$.state"
cat > "$TRUST_STATE_V1_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [97,112,112]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    for _index in 0..<64 |digest|:
        digest.push(97)
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |metadata_digest|:
        metadata_digest.push(99)
    return 0 if Registry::record_trusted(package, version, digest, metadata_digest, Platform::pkg_wall_clock_seconds().u64() + 3600) == Registry::ResultCode.Ok else 1
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_V1_BIN" "$TRUST_STATE_V1_PROBE"
cat > "$TRUST_STATE_VERIFY_V1_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [97,112,112]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    for _index in 0..<64 |digest|:
        digest.push(97)
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |metadata_digest|:
        metadata_digest.push(99)
    return 0 if Registry::verify_trusted(package, version, digest, metadata_digest, Platform::pkg_wall_clock_seconds().u64() + 3600) == Registry::ResultCode.Ok else 1
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
"$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_VERIFY_V1_BIN" "$TRUST_STATE_VERIFY_V1_PROBE"
cat > "$TRUST_STATE_LEGACY_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [97,112,112]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |digest, metadata_digest|:
        digest.push(97)
        metadata_digest.push(99)
    return 0 if Registry::verify_trusted(package, version, digest, metadata_digest, Platform::pkg_wall_clock_seconds().u64() + 3600) == Registry::ResultCode.TrustStateMalformed else 1
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_LEGACY_BIN" "$TRUST_STATE_LEGACY_PROBE"
printf 'elisapkg-trust-state:1\napp 1.0.0 %064d\n' 0 > "$TRUST_STATE_LEGACY_FILE"
python3 - "$TRUST_STATE_LEGACY_FILE" <<'PY'
from pathlib import Path
import os, sys

os.chmod(sys.argv[1], 0o600)
PY
ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_LEGACY_FILE" "$TRUST_STATE_LEGACY_BIN"
ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_V1_BIN"
cp "$TRUST_STATE_FILE" "$TRUST_STATE_V1_SNAPSHOT"
TRUST_STATE_CURRENT_HASH=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TRUST_STATE_FILE")
printf 'clock:0\nstate-sha256:%s\n' "$TRUST_STATE_CURRENT_HASH" > "$TRUST_STATE_FILE.clock"
ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_VERIFY_V1_BIN"
python3 - "$TRUST_STATE_FILE" "$TRUST_STATE_FILE.clock" "$TRUST_STATE_CURRENT_HASH" <<'PY'
from pathlib import Path
import hashlib, sys

state = Path(sys.argv[1]).read_bytes()
clock = Path(sys.argv[2]).read_text(encoding="ascii").splitlines()
if hashlib.sha256(state).hexdigest() != sys.argv[3]:
    raise SystemExit("successful trust verification rewrote trust-state bytes")
if len(clock) != 2 or not clock[0].startswith("clock:") or int(clock[0][6:]) <= 0:
    raise SystemExit("successful trust verification did not advance the bound clock")
if clock[1] != "state-sha256:" + sys.argv[3]:
    raise SystemExit("advanced trust clock is not bound to unchanged state bytes")
PY
cat > "$TRUST_STATE_VERIFY_FAIL_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [97,112,112]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |digest, metadata_digest|:
        digest.push(97)
        metadata_digest.push(100)
    return 1 if Registry::verify_trusted(package, version, digest, metadata_digest, Platform::pkg_wall_clock_seconds().u64() + 3600) != Registry::ResultCode.DigestMismatch
    metadata_digest.resize(0)
    for _index in 0..<64 |metadata_digest|:
        metadata_digest.push(99)
    return 0 if Registry::verify_trusted(package, version, digest, metadata_digest, 1) == Registry::ResultCode.ExpiredMetadata else 2
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_VERIFY_FAIL_BIN" "$TRUST_STATE_VERIFY_FAIL_PROBE"
printf 'clock:0\nstate-sha256:%s\n' "$TRUST_STATE_CURRENT_HASH" > "$TRUST_STATE_FILE.clock"
ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_VERIFY_FAIL_BIN"
grep -Fx "clock:0" "$TRUST_STATE_FILE.clock" >/dev/null
cat > "$TRUST_STATE_RECORD_EXPIRED_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [97,112,112]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |digest, metadata_digest|:
        digest.push(97)
        metadata_digest.push(99)
    return 1 if Registry::record_trusted(package, version, digest, metadata_digest, 1) != Registry::ResultCode.ExpiredMetadata
    beyond_horizon: u64 = Platform::pkg_wall_clock_seconds().u64() + 2592001
    return 2 if Registry::record_trusted(package, version, digest, metadata_digest, beyond_horizon) != Registry::ResultCode.ExpiryHorizon
    return 3 if Registry::verify_trusted(package, version, digest, metadata_digest, beyond_horizon) != Registry::ResultCode.ExpiryHorizon
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_RECORD_EXPIRED_BIN" "$TRUST_STATE_RECORD_EXPIRED_PROBE"
ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_RECORD_EXPIRED_BIN"
grep -Fx "clock:0" "$TRUST_STATE_FILE.clock" >/dev/null
cat > "$TRUST_STATE_PROBE" <<EOF
include "$ROOT/src/registry.elisa"

def filled(value: u8) -> darray[u8]:
    out: mutable darray[u8] = []
    for _index in 0..<64 |out|:
        out.push(value)
    return out

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [97,112,112]
    v1: mutable darray[u8] = [49,46,48,46,48]
    v0: mutable darray[u8] = [48,46,57,46,48]
    v2: mutable darray[u8] = [50,46,48,46,48]
    digest_a: mutable darray[u8] = filled(97)
    digest_b: mutable darray[u8] = filled(98)
    metadata_a: mutable darray[u8] = filled(99)
    metadata_b: mutable darray[u8] = filled(100)
    return 1 if Registry::record_trusted(package, v1, digest_a, metadata_a, Platform::pkg_wall_clock_seconds().u64() + 3600) != Registry::ResultCode.Ok
    return 2 if Registry::record_trusted(package, v0, digest_a, metadata_a, Platform::pkg_wall_clock_seconds().u64() + 3600) != Registry::ResultCode.RollbackDetected
    return 3 if Registry::record_trusted(package, v1, digest_b, metadata_a, Platform::pkg_wall_clock_seconds().u64() + 3600) != Registry::ResultCode.DigestMismatch
    return 4 if Registry::record_trusted(package, v1, digest_a, metadata_b, Platform::pkg_wall_clock_seconds().u64() + 3600) != Registry::ResultCode.DigestMismatch
    return 5 if Registry::record_trusted(package, v2, digest_b, metadata_b, Platform::pkg_wall_clock_seconds().u64() + 3600) != Registry::ResultCode.Ok
    return 6 if Registry::record_trusted(package, v2, digest_b, metadata_b, Platform::pkg_wall_clock_seconds().u64() + 3600) != Registry::ResultCode.Ok
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_BIN" "$TRUST_STATE_PROBE"
ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_BIN"
cat > "$TRUST_STATE_REPEAT_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [97,112,112]
    digest: mutable darray[u8] = []
    for _index in 0..<64 |digest|:
        digest.push(98)
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |metadata_digest|:
        metadata_digest.push(100)
    version: mutable darray[u8] = [50,46,48,46,48]
    return 0 if Registry::record_trusted(package, version, digest, metadata_digest, Platform::pkg_wall_clock_seconds().u64() + 3600) == Registry::ResultCode.Ok else 1
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_REPEAT_BIN" "$TRUST_STATE_REPEAT_PROBE"
ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN"
test -s "$TRUST_STATE_FILE"
test -s "$TRUST_STATE_FILE.clock"
cp "$TRUST_STATE_FILE" "$TRUST_STATE_V2_SNAPSHOT"
cp "$TRUST_STATE_V1_SNAPSHOT" "$TRUST_STATE_FILE"
chmod 600 "$TRUST_STATE_FILE"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_VERIFY_V1_BIN" >/dev/null 2>&1; then
  echo "restored old trust-state history was accepted by verification" >&2
  exit 1
fi
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "restored old trust-state history was accepted by recording" >&2
  exit 1
fi
rm "$TRUST_STATE_FILE"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "missing trust-state bytes with a retained clock were accepted" >&2
  exit 1
fi
cp "$TRUST_STATE_V2_SNAPSHOT" "$TRUST_STATE_FILE"
chmod 600 "$TRUST_STATE_FILE"
chmod 666 "$TRUST_STATE_FILE"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "writable trust-state file was accepted" >&2
  exit 1
fi
chmod 600 "$TRUST_STATE_FILE"
mkdir -m 777 "$TEST_TMP/trust-state-insecure"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TEST_TMP/trust-state-insecure/state" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "trust state in a shared writable directory was accepted" >&2
  exit 1
fi
test ! -e "$TEST_TMP/trust-state-insecure/state"
TRUST_STATE_CURRENT_HASH=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TRUST_STATE_FILE")
printf 'clock:18446744073709551615\nstate-sha256:%s\n' "$TRUST_STATE_CURRENT_HASH" > "$TRUST_STATE_FILE.clock"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "trust-state clock rollback was accepted" >&2
  exit 1
fi
rm -f "$TRUST_STATE_FILE.clock"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "missing trust-state clock was accepted" >&2
  exit 1
fi
printf 'clock:0\n' > "$TRUST_STATE_FILE.clock"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "legacy clock without state binding was accepted" >&2
  exit 1
fi
printf 'clock:0\nstate-sha256:%s\n' "$TRUST_STATE_CURRENT_HASH" > "$TRUST_STATE_FILE.clock"
mkdir "$TRUST_STATE_FILE.lock"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "trust-state lock was ignored" >&2
  exit 1
fi
rmdir "$TRUST_STATE_FILE.lock"
printf 'invalid trust state\n' > "$TRUST_STATE_FILE"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "malformed trust state was accepted" >&2
  exit 1
fi
printf 'elisapkg-trust-state:1\napp 1.0.0 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$TRUST_STATE_FILE"
TRUST_STATE_TRUNCATED_HASH=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TRUST_STATE_FILE")
printf 'clock:0\nstate-sha256:%s\n' "$TRUST_STATE_TRUNCATED_HASH" > "$TRUST_STATE_FILE.clock"
if ELISAPKG_REGISTRY_DIR="$ROOT" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "truncated trust state was accepted" >&2
  exit 1
fi

# The default HOME-derived trust path must reject control bytes and normalize a
# trailing separator. This exercises the same path helper used when no explicit
# ELISAPKG_TRUST_STATE override is configured.
DEFAULT_TRUST_HOME="$TEST_TMP/default-trust-home-$$"
mkdir -p "$DEFAULT_TRUST_HOME"
env -u ELISAPKG_TRUST_STATE HOME="$DEFAULT_TRUST_HOME/" ELISAPKG_REGISTRY_DIR="$ROOT" "$TRUST_STATE_BIN"
test -n "$(find "$DEFAULT_TRUST_HOME/.local/share/elisapkg/trust" -name '*.state' -type f -print -quit)"
BAD_TRUST_HOME="$TEST_TMP/bad-trust-home-$$"
BAD_TRUST_HOME="$BAD_TRUST_HOME"$'\n'x
if env -u ELISAPKG_TRUST_STATE HOME="$BAD_TRUST_HOME" ELISAPKG_REGISTRY_DIR="$ROOT" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "control-byte HOME was accepted for trust state" >&2
  exit 1
fi
BAD_TRUST_HOME_PARENT="$TEST_TMP/home-parent-$$/../escape"
if env -u ELISAPKG_TRUST_STATE HOME="$BAD_TRUST_HOME_PARENT" ELISAPKG_REGISTRY_DIR="$ROOT" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "parent traversal HOME was accepted for trust state" >&2
  exit 1
fi
if ELISAPKG_TRUST_STATE="$TEST_TMP/trust-state-parent-$$/../escape.state" ELISAPKG_REGISTRY_DIR="$ROOT" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "parent traversal trust-state override was accepted" >&2
  exit 1
fi
if ELISAPKG_TRUST_STATE="$TEST_TMP/trust-state-dot-$$/./escape.state" ELISAPKG_REGISTRY_DIR="$ROOT" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "non-canonical trust-state override was accepted" >&2
  exit 1
fi

# Verify the in-language SHA-256 implementation against the two canonical
# FIPS vectors used by the package-integrity path.
HASH_PROBE="$TEST_TMP/hash-probe-$$.elisa"
HASH_BIN="$TEST_TMP/hash-probe-$$"
cat > "$HASH_PROBE" <<EOF
include "$ROOT/src/integrity.elisa"

def equals_text(value: darray[u8]&, expected: cstr) -> bool:
    return false if value.count != 64.usize()
    for index in 0..<64 |value, expected|:
        return false if value[index] != expected[index].u8()
    return true

def check(value: darray[u8]&, expected: cstr) -> bool:
    digest: mutable darray[u8] = []
    text: mutable darray[u8] = []
    return false if Integrity::sha256(value, &digest) != Integrity::DigestCode.Ok
    return false if not Integrity::hex_digest(digest, &text)
    return equals_text(text, expected)

def main() -> i64:
    empty: mutable darray[u8] = []
    abc: mutable darray[u8] = [97, 98, 99]
    thousand: mutable darray[u8] = []
    for _index in 0..<1000 |thousand|:
        thousand.push(97)
    return 1 if not check(empty, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    return 2 if not check(abc, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    return 3 if not check(thousand, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$HASH_BIN" "$HASH_PROBE"
"$HASH_BIN"

# Exercise the archive verifier against a valid record and two malformed
# variants. The verifier is the gate used immediately before package output is
# published, so checksum and type-field regressions must fail closed.
ARCHIVE_PROBE="$TEST_TMP/archive-probe-$$.elisa"
ARCHIVE_BIN="$TEST_TMP/archive-probe-$$"
ARCHIVE_EXTRACT_DIR="$TEST_TMP/archive-extract-$$"
ARCHIVE_EXTRACT_512_DIR="$TEST_TMP/archive-extract-512-$$"
ARCHIVE_EXTRACT_LIMIT_DIR="$TEST_TMP/archive-extract-limit-$$"
ARCHIVE_EXTRACT_TRAVERSAL_DIR="$TEST_TMP/archive-extract-traversal-$$"
ARCHIVE_EXTRACT_COLLISION_DIR="$TEST_TMP/archive-extract-collision-$$"
ARCHIVE_TRAVERSAL_ESCAPE="$TEST_TMP/outside"
mkdir -p "$ARCHIVE_EXTRACT_DIR"
mkdir -p "$ARCHIVE_EXTRACT_DIR-partial"
mkdir -p "$ARCHIVE_EXTRACT_DIR-end"
mkdir -p "$ARCHIVE_EXTRACT_512_DIR"
mkdir -p "$ARCHIVE_EXTRACT_LIMIT_DIR"
mkdir -p "$ARCHIVE_EXTRACT_TRAVERSAL_DIR"
mkdir -p "$ARCHIVE_EXTRACT_COLLISION_DIR"
cat > "$ARCHIVE_PROBE" <<EOF
include "$ROOT/src/archive.elisa"

def append_bytes(out: mutable darray[u8]&, value: darray[u8]&) -> void:
    for index in 0..<value.count |out, value|:
        out.push(value[index])

def append_zeroes(out: mutable darray[u8]&, count: usize) -> void:
    for _index in 0..<count |out|:
        out.push(0)

def append_text(out: mutable darray[u8]&, value: cstr) -> void:
    index: mutable usize = 0
    while value[index].u8() != 0:
        out.push(value[index].u8())
        index <- index + 1

def append_indexed_zero_file(out: mutable darray[u8]&, index: usize) -> void can[Memory.Allocate, Abort.Panic]:
    name: mutable darray[u8] = []
    for _prefix in 0..<92 |name|:
        name.push(97)
    name.push(47)
    name.push(48 + (index / 100).u8())
    name.push(48 + ((index / 10) % 10).u8())
    name.push(48 + (index % 10).u8())
    header: darray[u8] = Archive::tar_file_header(name, 0)
    append_bytes(out, header)

def replace_header_name_and_checksum(header: mutable darray[u8]&, name: darray[u8]&) -> void can[Memory.Allocate, Abort.Panic]:
    for index in 0..<100 |header|:
        header[index] <- 0
    for index in 0..<name.count |header, name|:
        header[index] <- name[index]
    for index in 148..<156 |header|:
        header[index] <- 32
    checksum: mutable usize = 0
    for index in 0..<512 |header, checksum|:
        checksum <- checksum + header[index].usize()
    divisor: mutable usize = 1
    for _step in 0..<5 |divisor|:
        divisor <- divisor * 8
    for index in 0..<6 |header, checksum, divisor|:
        header[148 + index] <- 48 + ((checksum / divisor) % 8).u8()
        divisor <- divisor / 8
    header[154] <- 0
    header[155] <- 32

def main() -> i64:
    name: mutable darray[u8] = [115, 114, 99, 47, 109, 97, 105, 110, 46, 101, 108, 105, 115, 97]
    header: darray[u8] = Archive::tar_file_header(name, 3)
    return 1 if header.count != 512.usize()
    valid: mutable darray[u8] = []
    append_bytes(&valid, header)
    valid.push(97)
    valid.push(98)
    valid.push(99)
    append_zeroes(&valid, 509)
    append_zeroes(&valid, 1024)
    return 2 if not Archive::verify_ustar_archive(valid)
    destination: mutable darray[u8] = []
    append_text(&destination, "$ARCHIVE_EXTRACT_DIR")
    return 5 if not Archive::extract_ustar_archive(valid, destination)
    valid[156] <- 50
    return 3 if Archive::verify_ustar_archive(valid)
    upper_name: mutable darray[u8] = [83, 82, 67, 47, 77, 65, 73, 78, 46, 69, 76, 73, 83, 65]
    upper_header: darray[u8] = Archive::tar_file_header(upper_name, 3)
    duplicate: mutable darray[u8] = []
    append_bytes(&duplicate, header)
    duplicate.push(97)
    duplicate.push(98)
    duplicate.push(99)
    append_zeroes(&duplicate, 509)
    append_bytes(&duplicate, upper_header)
    duplicate.push(97)
    duplicate.push(98)
    duplicate.push(99)
    append_zeroes(&duplicate, 509)
    append_zeroes(&duplicate, 1024)
    return 4 if Archive::verify_ustar_archive(duplicate)
    duplicate_destination: mutable darray[u8] = []
    append_text(&duplicate_destination, "$ARCHIVE_EXTRACT_COLLISION_DIR")
    return 12 if Archive::extract_ustar_archive(duplicate, duplicate_destination)
    forged_header: mutable darray[u8] = Archive::tar_file_header(name, 0)
    safe_header_name: mutable darray[u8] = [115, 97, 102, 101, 45, 102, 105, 108, 101]
    replace_header_name_and_checksum(&forged_header, safe_header_name)
    safe_header_archive: mutable darray[u8] = []
    append_bytes(&safe_header_archive, forged_header)
    append_zeroes(&safe_header_archive, 1024)
    return 13 if not Archive::verify_ustar_archive(safe_header_archive)
    traversal_name: mutable darray[u8] = [46, 46, 47, 111, 117, 116, 115, 105, 100, 101]
    replace_header_name_and_checksum(&forged_header, traversal_name)
    traversal_archive: mutable darray[u8] = []
    append_bytes(&traversal_archive, forged_header)
    append_zeroes(&traversal_archive, 1024)
    return 14 if Archive::verify_ustar_archive(traversal_archive)
    traversal_destination: mutable darray[u8] = []
    append_text(&traversal_destination, "$ARCHIVE_EXTRACT_TRAVERSAL_DIR")
    return 15 if Archive::extract_ustar_archive(traversal_archive, traversal_destination)
    nested_name: mutable darray[u8] = [110, 101, 115, 116, 101, 100, 47, 102, 105, 108, 101]
    nested_header: darray[u8] = Archive::tar_file_header(nested_name, 3)
    partial: mutable darray[u8] = []
    append_bytes(&partial, nested_header)
    partial.push(97)
    partial.push(98)
    partial.push(99)
    append_zeroes(&partial, 509)
    partial.push(1)
    append_zeroes(&partial, 511)
    partial_destination: mutable darray[u8] = []
    append_text(&partial_destination, "$ARCHIVE_EXTRACT_DIR-partial")
    return 6 if Archive::extract_ustar_archive(partial, partial_destination)
    # A single zero end block used to bypass rollback after writing files.
    partial[1024] <- 0
    end_destination: mutable darray[u8] = []
    append_text(&end_destination, "$ARCHIVE_EXTRACT_DIR-end")
    return 7 if Archive::extract_ustar_archive(partial, end_destination)
    archive_512: mutable darray[u8] = []
    for index in 0..<512.usize() |archive_512|:
        append_indexed_zero_file(&archive_512, index)
    append_zeroes(&archive_512, 1024)
    return 8 if not Archive::verify_ustar_archive(archive_512)
    accepted_destination: mutable darray[u8] = []
    append_text(&accepted_destination, "$ARCHIVE_EXTRACT_512_DIR")
    return 11 if not Archive::extract_ustar_archive(archive_512, accepted_destination)
    archive_513: mutable darray[u8] = []
    for index in 0..<513.usize() |archive_513|:
        append_indexed_zero_file(&archive_513, index)
    append_zeroes(&archive_513, 1024)
    return 9 if Archive::verify_ustar_archive(archive_513)
    limit_destination: mutable darray[u8] = []
    append_text(&limit_destination, "$ARCHIVE_EXTRACT_LIMIT_DIR")
    return 10 if Archive::extract_ustar_archive(archive_513, limit_destination)
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$ARCHIVE_BIN" "$ARCHIVE_PROBE"
"$ARCHIVE_BIN"
test -f "$ARCHIVE_EXTRACT_DIR/src/main.elisa"
test "$(cat "$ARCHIVE_EXTRACT_DIR/src/main.elisa")" = abc
test -z "$(find "$ARCHIVE_EXTRACT_COLLISION_DIR" -mindepth 1 -print -quit)"
test -z "$(find "$ARCHIVE_EXTRACT_TRAVERSAL_DIR" -mindepth 1 -print -quit)"
test ! -e "$ARCHIVE_TRAVERSAL_ESCAPE"
test -z "$(find "$ARCHIVE_EXTRACT_DIR-partial" -mindepth 1 -print -quit)"
test -z "$(find "$ARCHIVE_EXTRACT_DIR-end" -mindepth 1 -print -quit)"
test "$(find "$ARCHIVE_EXTRACT_512_DIR" -type f | wc -l | tr -d ' ')" -eq 512
test -z "$(find "$ARCHIVE_EXTRACT_LIMIT_DIR" -mindepth 1 -print -quit)"

# Transitive local paths are normalized without duplicate separators. This
# nested/../ form used to retain the separator at the removed component and
# emit a lock path containing `//`, which later build validation rejected.
NORMALIZE_PATH_CASE="$TEST_TMP/normalize-dependency-path-$$"
mkdir -p "$NORMALIZE_PATH_CASE/src" "$NORMALIZE_PATH_CASE/group/local-util/src" "$NORMALIZE_PATH_CASE/group/local-util/nested" "$NORMALIZE_PATH_CASE/group/local-util/nested-util/src"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$NORMALIZE_PATH_CASE/src/main.elisa"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$NORMALIZE_PATH_CASE/group/local-util/src/main.elisa"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$NORMALIZE_PATH_CASE/group/local-util/nested-util/src/main.elisa"
printf '%s\n' '{"schema-version":1,"package":{"name":"normalize-root","version":"1.0.0"},"targets":[{"name":"normalize-root","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"local-util":{"path":"group/local-util"}}}' > "$NORMALIZE_PATH_CASE/elisapkg.json"
printf '%s\n' '{"schema-version":1,"package":{"name":"local-util","version":"1.0.0"},"targets":[{"name":"local-util","kind":"lib","entry":"src/main.elisa"}],"dependencies":{"nested-util":{"path":"nested/../nested-util"}}}' > "$NORMALIZE_PATH_CASE/group/local-util/elisapkg.json"
printf '%s\n' '{"schema-version":1,"package":{"name":"nested-util","version":"1.0.0"},"targets":[{"name":"nested-util","kind":"lib","entry":"src/main.elisa"}],"dependencies":{}}' > "$NORMALIZE_PATH_CASE/group/local-util/nested-util/elisapkg.json"
(
  cd "$NORMALIZE_PATH_CASE"
  "$BIN" resolve >/dev/null
  grep -F '"path":"group/local-util/nested-util"' elisapkg.lock >/dev/null
  "$BIN" resolve --frozen >/dev/null
)

# The source collector rejects packages beyond the archive's documented entry
# cap before the writer or duplicate scanner sees an oversized list.
PACKAGE_ENTRY_LIMIT_CASE="$TEST_TMP/package-entry-limit-$$"
mkdir -p "$PACKAGE_ENTRY_LIMIT_CASE/src" "$PACKAGE_ENTRY_LIMIT_CASE/extra"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$PACKAGE_ENTRY_LIMIT_CASE/src/main.elisa"
printf '%s\n' '{"schema-version":1,"package":{"name":"entry-limit","version":"1.0.0"},"targets":[{"name":"entry-limit","kind":"bin","entry":"src/main.elisa"}],"dependencies":{}}' > "$PACKAGE_ENTRY_LIMIT_CASE/elisapkg.json"
(
  cd "$PACKAGE_ENTRY_LIMIT_CASE"
  "$BIN" resolve >/dev/null
  for index in $(seq 1 509); do
    printf x > "extra/file-$index"
  done
  "$BIN" package --list >/dev/null
  printf x > extra/file-510
  if "$BIN" package --list >/dev/null 2>&1; then
    echo "package listing accepted more than 512 archive entries" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
)

# Read-only graph inspection must not refresh a registry or depend on its
# current availability. A structurally valid v3 lock with matching local root
# digests is enough for tree/why to operate while the provider is unset.
READONLY_REGISTRY_CASE="$TEST_TMP/readonly-registry-$$"
mkdir -p "$READONLY_REGISTRY_CASE/src"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$READONLY_REGISTRY_CASE/src/main.elisa"
printf '%s\n' '{"schema-version":1,"package":{"name":"readonly-app","version":"0.1.0"},"targets":[{"name":"app","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"dep":{"version":"1.0.0","registry":"primary"}}}' > "$READONLY_REGISTRY_CASE/elisapkg.json"
readonly_manifest_digest="$(shasum -a 256 "$READONLY_REGISTRY_CASE/elisapkg.json" | awk '{print $1}')"
# The registry lock binds the root's complete sanitized source tree. Manifest
# and lock bytes have dedicated fields, so the source fingerprint contains the
# logical source path and its raw SHA-256 content digest only.
readonly_source_digest="$(python3 - "$READONLY_REGISTRY_CASE/src/main.elisa" <<'PY'
import hashlib
import sys

source_path = sys.argv[1]
content_digest = hashlib.sha256(open(source_path, 'rb').read()).digest()
fingerprint = b'src/main.elisa\0' + content_digest + b'\0'
print(hashlib.sha256(fingerprint).hexdigest())
PY
)"
readonly_zero_digest="$(printf '%064d' 0)"
cat > "$READONLY_REGISTRY_CASE/elisapkg.lock" <<EOF
{
  "lock-version": 3,
  "resolver": "elisapkg-registry-v1",
  "package": {
    "name": "readonly-app",
    "version": "0.1.0",
    "manifest-digest": "sha256:$readonly_manifest_digest",
    "source-digest": "sha256:$readonly_source_digest"
  },
  "packages": [{"name":"dep","version":"1.0.0","source":{"type":"registry","registry":"primary","archive":"dep.tar"},"archive-size":1,"archive-digest":"sha256:$readonly_zero_digest","metadata-digest":"sha256:$readonly_zero_digest"}]
}
EOF
(
  cd "$READONLY_REGISTRY_CASE"
  env -u ELISAPKG_REGISTRY_DIR -u ELISAPKG_TRUST_STATE "$BIN" tree | grep -F 'dep 1.0.0' >/dev/null
  env -u ELISAPKG_REGISTRY_DIR -u ELISAPKG_TRUST_STATE "$BIN" why dep | grep -F 'readonly-app -> dep' >/dev/null
  env -u ELISAPKG_REGISTRY_DIR -u ELISAPKG_TRUST_STATE "$BIN" resolve --frozen >/dev/null
  ELISAPKG_REGISTRY_DIR="$READONLY_REGISTRY_CASE/provider-does-not-exist" env -u ELISAPKG_TRUST_STATE "$BIN" resolve --offline >/dev/null
  if ELISAPKG_REGISTRY_DIR="$READONLY_REGISTRY_CASE/provider-does-not-exist" env -u ELISAPKG_TRUST_STATE "$BIN" fetch --offline >/dev/null 2>&1; then
    echo "offline fetch accepted a lock without cached metadata and signature evidence" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  cp elisapkg.lock elisapkg.lock.valid
  python3 - "$READONLY_REGISTRY_CASE/elisapkg.lock" <<'PY'
from pathlib import Path
import sys

lock_path = Path(sys.argv[1])
text = lock_path.read_text()
marker = '"packages": [{"name":"dep"'
root_record = ('"packages": [{"name":"readonly-app","version":"0.1.0",'
               '"source":{"type":"registry","registry":"primary","archive":"dep.tar"},'
               '"archive-size":1,"archive-digest":"sha256:' + ('0' * 64) + '",'
               '"metadata-digest":"sha256:' + ('0' * 64) + '"}, {"name":"dep"')
if marker not in text:
    raise SystemExit('registry fixture marker missing')
lock_path.write_text(text.replace(marker, root_record, 1))
PY
  if env -u ELISAPKG_REGISTRY_DIR -u ELISAPKG_TRUST_STATE "$BIN" resolve --frozen >/dev/null 2>&1; then
    echo "frozen registry resolution accepted a root package record" >&2
    exit 1
  else
    test "$?" -eq 3
  fi
  mv elisapkg.lock.valid elisapkg.lock
  cp elisapkg.lock elisapkg.lock.valid
  python3 - "$READONLY_REGISTRY_CASE/elisapkg.lock" <<'PY'
from pathlib import Path
import sys

lock_path = Path(sys.argv[1])
text = lock_path.read_text()
marker = '"name":"dep","version":"1.0.0"'
if marker not in text:
    raise SystemExit('registry version fixture marker missing')
lock_path.write_text(text.replace(marker, '"name":"dep","version":"2.0.0"', 1))
PY
  if env -u ELISAPKG_REGISTRY_DIR -u ELISAPKG_TRUST_STATE "$BIN" resolve --frozen >/dev/null 2>&1; then
    echo "frozen registry resolution accepted an out-of-range dependency version" >&2
    exit 1
  else
    test "$?" -eq 3
  fi
  mv elisapkg.lock.valid elisapkg.lock
  if ELISAPKG_REGISTRY_DIR="$READONLY_REGISTRY_CASE/provider-does-not-exist" env -u ELISAPKG_TRUST_STATE "$BIN" fetch --offline dep 1.0.0 >/dev/null 2>&1; then
    echo "offline package-specific fetch unexpectedly reached a provider" >&2
    exit 1
  else
    test "$?" -eq 3
  fi
)

CASE="$TEST_TMP/test-package-$(date +%s%N)"
mkdir -p "$CASE"
(
  cd "$CASE"
  run_build_with_parent_mutation() {
    local wrapper="$1"
    local log_path="$2"
    local mutation_kind="$3"
    local mutation_target="$4"
    case "$mutation_kind" in
      manifest|dependency|toolchain) ;;
      *)
        echo "unknown parent mutation kind: $mutation_kind" >&2
        return 99
        ;;
    esac
    cat > "$wrapper" <<EOF
#!/bin/bash
: > "\$TMPDIR/elisapkg-test.ready"
release_deadline=\$((SECONDS + 10))
while [[ ! -p "\$TMPDIR/elisapkg-test.release" ]]; do
  (( SECONDS < release_deadline )) || exit 92
done
read -r -t 10 _ < "\$TMPDIR/elisapkg-test.release" || exit 91
exec '$ELISA_COMPILER_ROOT/bin/elisac-stage1' "\$@"
EOF
    chmod +x "$wrapper"
    ELISAPKG_COMPILER="$wrapper" "$BIN" build >"$log_path" 2>&1 &
    local build_pid=$!
    local scratch=""
    local attempt=0
    while (( attempt < 500 )); do
      for candidate in "$CASE"/.elisapkg/build/.sandbox-*; do
        if [[ -f "$candidate/elisapkg-test.ready" ]]; then
          scratch="$candidate"
          break 2
        fi
      done
      if ! kill -0 "$build_pid" 2>/dev/null; then
        break
      fi
      sleep 0.01
      attempt=$((attempt + 1))
    done
    if [[ -z "$scratch" ]]; then
      local early_status=0
      if wait "$build_pid"; then
        early_status=0
      else
        early_status=$?
      fi
      echo "compiler did not reach the coordinated mutation point (exit $early_status)" >&2
      return 99
    fi
    case "$mutation_kind" in
      manifest)
        printf '\n' >> "$mutation_target"
        ;;
      dependency)
        printf '%s\n' 'def main() -> i64:' '    return 9' > "$mutation_target"
        ;;
      toolchain)
        printf '%s\n' '# changed while the compiler was running' >> "$mutation_target"
        ;;
    esac
    mkfifo "$scratch/elisapkg-test.release"
    printf 'continue\n' > "$scratch/elisapkg-test.release"
    rm -f "$scratch/elisapkg-test.ready" "$scratch/elisapkg-test.release"
    local build_status=0
    if wait "$build_pid"; then
      build_status=0
    else
      build_status=$?
    fi
    return "$build_status"
  }
  "$BIN" init . >/dev/null
  "$BIN" check-manifest --manifest-path "$CASE/elisapkg.json" >/dev/null
  printf '%s\n' '{}' > settings.json
  if "$BIN" check-manifest --manifest-path "$CASE/settings.json" >/dev/null 2>&1; then
    echo "non-manifest file path was accepted" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  mkdir -p local-util/src nested-util/src
  printf '%s\n' 'def main() -> i64:' '    return 0' > local-util/src/main.elisa
  printf '%s\n' 'def main() -> i64:' '    return 0' > nested-util/src/main.elisa
  printf '%s\n' '{"schema-version":1,"package":{"name":"nested-util","version":"0.4.0"},"targets":[{"name":"nested-util","kind":"lib","entry":"src/main.elisa"}],"dependencies":{}}' > nested-util/elisapkg.json
  printf '%s\n' '{"schema-version":1,"package":{"name":"local-util","version":"1.2.3"},"targets":[{"name":"local-util","kind":"lib","entry":"src/main.elisa"}],"dependencies":{"nested-util":{"path":"../nested-util"}}}' > local-util/elisapkg.json
  if "$BIN" add local-util --path local-util --color invalid >/dev/null 2>&1; then
    echo 'dependency mutation accepted an invalid color mode' >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  add_quiet_output="$("$BIN" add local-util --path local-util --quiet 2>/dev/null)"
  test -z "$add_quiet_output"
  "$BIN" check-manifest >/dev/null
  "$BIN" resolve >/dev/null
  grep -F '"name":"nested-util"' elisapkg.lock >/dev/null
  update_quiet_output="$(cd "$ROOT" && "$BIN" update local-util --manifest-path "$CASE" --quiet 2>/dev/null)"
  test -z "$update_quiet_output"
  remove_quiet_output="$(cd "$ROOT" && "$BIN" remove local-util --manifest-path "$CASE" --quiet 2>/dev/null)"
  test -z "$remove_quiet_output"
  if grep -F '"local-util"' elisapkg.json >/dev/null; then
    echo "manifest-path remove left the dependency declared" >&2
    exit 1
  fi
  (cd "$ROOT" && "$BIN" add local-util --path local-util --manifest-path "$CASE" >/dev/null)
  grep -F '"local-util"' elisapkg.json >/dev/null
  "$BIN" resolve >/dev/null
  grep -F '"name":"nested-util"' elisapkg.lock >/dev/null
  "$BIN" cache verify | grep -F 'manifest digests verified' >/dev/null
  "$BIN" cache gc --dry-run | grep -F 'nothing would be collected' >/dev/null
  if "$BIN" cache gc >/dev/null 2>&1; then
    echo "disabled cache GC unexpectedly succeeded" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  "$BIN" resolve --frozen >/dev/null
  cp local-util/elisapkg.json local-util/elisapkg.json.good
  sed 's/1.2.3/1.2.4/' local-util/elisapkg.json.good > local-util/elisapkg.json
  if "$BIN" resolve --frozen >/dev/null 2>&1; then
    echo "frozen mode accepted a changed dependency manifest" >&2
    exit 1
  else
    test "$?" -eq 3
  fi
  mv local-util/elisapkg.json.good local-util/elisapkg.json
  cp elisapkg.lock elisapkg.lock.good
  printf '%s\n' '{}' > elisapkg.lock
  if "$BIN" resolve --frozen >/dev/null 2>&1; then
    echo "frozen mode accepted a tampered lockfile" >&2
    exit 1
  fi
  mv elisapkg.lock.good elisapkg.lock
  cp elisapkg.json elisapkg.root.good
  sed 's/An Elisa application/Changed description/' elisapkg.root.good > elisapkg.json
  if "$BIN" resolve --frozen >/dev/null 2>&1; then
    echo "frozen mode accepted a changed root manifest" >&2
    exit 1
  else
    test "$?" -eq 3
  fi
  mv elisapkg.root.good elisapkg.json
  "$BIN" build >/dev/null
  "$BIN" build --frozen >/dev/null
  normal_cached_build="$("$BIN" build)"
  case "$normal_cached_build" in
    *"(cached)"*) ;;
    *)
      echo "unchanged linker inputs were not reused" >&2
      exit 1
      ;;
  esac
  missing_clang_log="$CASE/missing-clang-build.log"
  if ELISA_CLANG="$CASE/not-installed-clang" "$BIN" build >"$missing_clang_log" 2>&1; then
    echo "build reused an artifact after selecting an unavailable linker" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  if grep -F '(cached)' "$missing_clang_log" >/dev/null; then
    echo "unavailable selected linker was accepted from the build cache" >&2
    exit 1
  fi
  alternate_clang_log="$CASE/alternate-clang-build.log"
  if ELISA_CLANG=/usr/bin/true "$BIN" build >"$alternate_clang_log" 2>&1; then
    echo "build unexpectedly accepted an unrelated executable as its linker" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  if grep -F '(cached)' "$alternate_clang_log" >/dev/null; then
    echo "build reused output after selecting a different executable linker" >&2
    exit 1
  fi
  normal_cached_build="$("$BIN" build)"
  case "$normal_cached_build" in
    *"(cached)"*) ;;
    *)
      echo "restoring the original linker inputs did not restore the cache hit" >&2
      exit 1
      ;;
  esac
  "$BIN" build --profile release >/dev/null
  test -s .elisapkg/build/release/app
  grep -F 'profile:release' .elisapkg/build/release/app.receipt >/dev/null
  if "$BIN" build --profile release --profile debug >/dev/null 2>&1; then
    echo "duplicate build profile was accepted" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  if "$BIN" update app >/dev/null 2>&1; then
    echo "targeted update accepted the root package" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  TOOLCHAIN_WRAPPER="$TEST_TMP/compiler-wrapper.sh"
  printf '%s\n' '#!/bin/sh' "exec '$ELISA_COMPILER_ROOT/bin/elisac-stage1' \"\$@\"" > "$TOOLCHAIN_WRAPPER"
  chmod +x "$TOOLCHAIN_WRAPPER"
  wrapper_build_output="$(ELISAPKG_COMPILER="$TOOLCHAIN_WRAPPER" "$BIN" build)"
  case "$wrapper_build_output" in
    *"(cached)"*)
      echo "changed compiler path was accepted from the cache" >&2
      exit 1
      ;;
  esac
  wrapper_cached_output="$(ELISAPKG_COMPILER="$TOOLCHAIN_WRAPPER" "$BIN" build)"
  case "$wrapper_cached_output" in
    *"(cached)"*) ;;
    *)
      echo "unchanged compiler wrapper was not reused" >&2
      exit 1
      ;;
  esac
  printf '%s\n' 'source tree mutation must invalidate the receipt' > src/helper.elisa
  source_tree_build_output="$("$BIN" build)"
  case "$source_tree_build_output" in
    *"(cached)"*)
      echo "new source file was accepted from the cache" >&2
      exit 1
      ;;
  esac
  source_tree_cached_output="$("$BIN" build)"
  case "$source_tree_cached_output" in
    *"(cached)"*) ;;
    *)
      echo "unchanged source tree was not reused" >&2
      exit 1
      ;;
  esac
  printf '%s\n' 'source tree mutation must invalidate the receipt again' >> src/helper.elisa
  source_tree_mutated_output="$("$BIN" build)"
  case "$source_tree_mutated_output" in
    *"(cached)"*)
      echo "changed non-target source was accepted from the cache" >&2
      exit 1
      ;;
  esac
  printf '%s\n' '# content mutation must invalidate the receipt' >> "$TOOLCHAIN_WRAPPER"
  wrapper_mutated_output="$(ELISAPKG_COMPILER="$TOOLCHAIN_WRAPPER" "$BIN" build)"
  case "$wrapper_mutated_output" in
    *"(cached)"*)
      echo "mutated compiler wrapper was accepted from the cache" >&2
      exit 1
      ;;
  esac
  TOOLCHAIN_MUTATING_WRAPPER="$TEST_TMP/toolchain-mutating-compiler.sh"
  if run_build_with_parent_mutation "$TOOLCHAIN_MUTATING_WRAPPER" "$CASE/toolchain-mutation-build.log" toolchain "$TOOLCHAIN_MUTATING_WRAPPER"; then
    echo "build published output after its compiler changed during compilation" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  grep -F 'compiler toolchain changed during the build' "$CASE/toolchain-mutation-build.log" >/dev/null
  if grep -F '(cached)' "$CASE/toolchain-mutation-build.log" >/dev/null; then
    echo "build reused output after its compiler changed during compilation" >&2
    exit 1
  fi
  cp local-util/src/main.elisa local-util/src/main.elisa.good
  printf '%s\n' 'def main() -> i64:' '    return 1' > local-util/src/main.elisa
  dependency_rebuild_output="$("$BIN" build)"
  case "$dependency_rebuild_output" in
    *"(cached)"*)
      echo "changed dependency source was accepted from the cache" >&2
      exit 1
      ;;
  esac
  mv local-util/src/main.elisa.good local-util/src/main.elisa
  printf '%s\n' 'non-target dependency mutation must invalidate the receipt' > local-util/src/helper.elisa
  dependency_helper_rebuild_output="$("$BIN" build)"
  case "$dependency_helper_rebuild_output" in
    *"(cached)"*)
      echo "changed non-target dependency source was accepted from the cache" >&2
      exit 1
      ;;
  esac
  dependency_helper_cached_output="$("$BIN" build)"
  case "$dependency_helper_cached_output" in
    *"(cached)"*) ;;
    *)
      echo "unchanged dependency source tree was not reused" >&2
      exit 1
      ;;
  esac
  cp elisapkg.json elisapkg.build-good
  INPUT_MUTATING_WRAPPER="$TEST_TMP/manifest-mutating-compiler.sh"
  if run_build_with_parent_mutation "$INPUT_MUTATING_WRAPPER" "$CASE/manifest-mutation-build.log" manifest "$CASE/elisapkg.json"; then
    echo "build published an artifact after its manifest changed during compilation" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  mv elisapkg.build-good elisapkg.json
  cp local-util/src/main.elisa local-util/src/main.build-good
  INPUT_MUTATING_WRAPPER="$TEST_TMP/dependency-mutating-compiler.sh"
  if run_build_with_parent_mutation "$INPUT_MUTATING_WRAPPER" "$CASE/dependency-mutation-build.log" dependency "$CASE/local-util/src/main.elisa"; then
    echo "build published an artifact after a locked local dependency changed during compilation" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  mv local-util/src/main.build-good local-util/src/main.elisa
  test -z "$(find .elisapkg/build -name 'app.tmp.*' -print -quit)"
  rm -f local-util/src/helper.elisa
  python3 - <<'PY'
path = ".elisapkg/build/app"
with open(path, "r+b") as handle:
    value = handle.read(1)
    handle.seek(0)
    handle.write(bytes([value[0] ^ 1]))
PY
  rebuild_output="$("$BIN" build)"
  case "$rebuild_output" in
    *"(cached)"*)
      echo "tampered artifact was accepted from the cache" >&2
      exit 1
      ;;
  esac
  cp src/main.elisa src/main.size.good
  python3 - <<'PY'
with open("src/main.elisa", "wb") as handle:
    handle.write(b" " * 1048577)
PY
  if "$BIN" build >/dev/null 2>&1; then
    echo "oversized target source was accepted" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  mv src/main.size.good src/main.elisa
  printf '%s\n' 'def main() -> i64:' '    return 0' > src/alternate.elisa
  cp elisapkg.json elisapkg.target.good
  sed 's#src/main.elisa#src/alternate.elisa#' elisapkg.target.good > elisapkg.json
  "$BIN" build >/dev/null
  mv elisapkg.target.good elisapkg.json
  cp src/main.elisa src/main.elisa.good
  printf '%s\n' 'def main() -> i64:' '    return' > src/main.elisa
  if "$BIN" build >/dev/null 2>&1; then
    echo "semantic-invalid source was accepted" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  test -x .elisapkg/build/app
  mv src/main.elisa.good src/main.elisa
  "$BIN" run -- >/dev/null
  if command -v mkfifo >/dev/null 2>&1; then
    mkfifo src/package-pipe
    if "$BIN" package --list >/dev/null 2>&1; then
      echo "package listing accepted a non-regular file" >&2
      exit 1
    fi
    rm -f src/package-pipe
  fi
  mkdir -p src/nested
  printf '%s\n' root > src/deep.elisa
  printf '%s\n' nested > src/nested/deep.elisa
  cp elisapkg.json elisapkg.include.good
  sed 's#src/\*\*#src/*#' elisapkg.include.good > elisapkg.json
  "$BIN" package --list > package-files-glob.txt
  grep -F 'src/helper.elisa' package-files-glob.txt >/dev/null
  if grep -F 'src/nested/deep.elisa' package-files-glob.txt >/dev/null; then
    echo "single-star include crossed a path separator" >&2
    exit 1
  fi
  sed 's#src/\*\*#src/**/deep.elisa", "src/main.elisa#' elisapkg.include.good > elisapkg.json
  "$BIN" package --list > package-files-glob-double-star.txt
  grep -F 'src/deep.elisa' package-files-glob-double-star.txt >/dev/null
  grep -F 'src/nested/deep.elisa' package-files-glob-double-star.txt >/dev/null
  mv elisapkg.include.good elisapkg.json
  rm -rf src/deep.elisa src/nested package-files-glob.txt package-files-glob-double-star.txt
  "$BIN" package --list >/dev/null
  cp elisapkg.json elisapkg.exclude.good
  python3 - <<'PY'
from pathlib import Path

path = Path('elisapkg.json')
text = path.read_text()
needle = '  "include": ["src/**", "elisapkg.json", "LICENSE", "README.md"]'
replacement = needle + ',\n  "exclude": ["src/helper.elisa"]'
if needle not in text:
    raise SystemExit('exclude fixture manifest shape missing')
path.write_text(text.replace(needle, replacement, 1))
PY
  "$BIN" package --list > package-files-exclude.txt
  if grep -F 'src/helper.elisa' package-files-exclude.txt >/dev/null; then
    echo "exclude pattern did not remove a selected source" >&2
    exit 1
  fi
  mv elisapkg.exclude.good elisapkg.json
  rm -f package-files-exclude.txt
  "$BIN" package >/dev/null
  cp .elisapkg/package.tar .elisapkg/package.tar.good
  cp .elisapkg/package.receipt .elisapkg/package.receipt.good
  test -s .elisapkg/package.receipt
  "$BIN" cache verify | grep -F 'package archive and receipt verified' >/dev/null
  mv .elisapkg/package.tar .elisapkg/package.tar.real
  mv .elisapkg/package.receipt .elisapkg/package.receipt.real
  ln -s package.tar.real .elisapkg/package.tar
  ln -s package.receipt.real .elisapkg/package.receipt
  if "$BIN" cache verify >/dev/null 2>&1; then
    echo "cache verification accepted symlinked package evidence" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  rm .elisapkg/package.tar .elisapkg/package.receipt
  mv .elisapkg/package.tar.real .elisapkg/package.tar
  mv .elisapkg/package.receipt.real .elisapkg/package.receipt
  PACKAGE_BLOB="$(find .elisapkg/cache/sha256 -type f | head -n 1)"
  test -n "$PACKAGE_BLOB"
  printf '%s' junk >> "$PACKAGE_BLOB"
  if "$BIN" cache verify >/dev/null 2>&1; then
    echo "cache verification accepted a corrupted content-addressed blob" >&2
    exit 1
  fi
  "$BIN" package >/dev/null
  test -n "$(find .elisapkg/cache/quarantine -type f | head -n 1)"
  QUARANTINE_BLOB="$(find .elisapkg/cache/quarantine -type f | head -n 1)"
  QUARANTINE_DIGEST="$(shasum -a 256 "$QUARANTINE_BLOB" | awk '{print $1}')"
  printf '%s' junk >> "$PACKAGE_BLOB"
  if "$BIN" package >/dev/null 2>&1; then
    echo "cache packaging overwrote an existing quarantine record" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  test "$QUARANTINE_DIGEST" = "$(shasum -a 256 "$QUARANTINE_BLOB" | awk '{print $1}')"
  cp .elisapkg/package.tar "$PACKAGE_BLOB"
  cmp .elisapkg/package.tar.good .elisapkg/package.tar >/dev/null
  cmp .elisapkg/package.receipt.good .elisapkg/package.receipt >/dev/null
  tar -tf .elisapkg/package.tar | grep -F 'elisapkg.json' >/dev/null
  if tar -tf .elisapkg/package.tar | grep -E 'IMPLEMENTATION_PLAN|\.elisapkg/|\.env|\.pem|\.key' >/dev/null; then
    echo "package archive included a forbidden path" >&2
    exit 1
  fi
  printf '%s' marker > .git
  printf '%s' marker > .hg
  printf '%s' marker > .svn
  "$BIN" package --list > package-files-vcs.txt
  if grep -E '(^|/)(\.git|\.hg|\.svn)$' package-files-vcs.txt >/dev/null; then
    echo "package listing included a VCS marker file" >&2
    exit 1
  fi
  rm -f .git .hg .svn package-files-vcs.txt
  printf '%s' secret > src/.env
  printf '%s' secret > src/config.env
  printf '%s' secret > src/private.pem
  cp elisapkg.json "$TEST_TMP/credentials-manifest.good"
  python3 - <<'PY'
import json
from pathlib import Path

path = Path('elisapkg.json')
manifest = json.loads(path.read_text())
manifest.pop('include', None)
manifest.pop('exclude', None)
path.write_text(json.dumps(manifest, indent=2) + '\n')
PY
  mkdir -p .docker .kube .ssh .gnupg .AWS .azure .terraform .terraform.d .config/gcloud .config/gh .config/rclone .env.production credentials-backup private.pem-store private.key-store
  printf '%s' secret > .docker/config.json
  printf '%s' secret > .kube/config
  printf '%s' secret > .ssh/id_ed25519
  printf '%s' secret > .AWS/credentials
  printf '%s' secret > .azure/credentials
  printf '%s' secret > .terraform/terraform.tfstate
  printf '%s' secret > .terraform.d/credentials
  printf '%s' secret > .config/gcloud/application_default_credentials.json
  printf '%s' secret > .config/gh/hosts.yml
  printf '%s' secret > .config/rclone/rclone.conf
  printf '%s' secret > .env.production/secret.txt
  printf '%s' secret > credentials-backup/token.txt
  printf '%s' secret > private.pem-store/secret.txt
  printf '%s' secret > private.key-store/secret.txt
  printf '%s' secret > signing.p12
  printf '%s' secret > signing.PFX
  printf '%s' secret > signing.p8
  printf '%s' secret > trust.jks
  printf '%s' secret > token.keystore
  printf '%s' secret > .NPMRC
  printf '%s' secret > .pypirc
  printf '%s' secret > .git-credentials
  "$BIN" resolve >/dev/null
  "$BIN" package --list > "$TEST_TMP/package-files-secret-check.txt"
  credential_path_pattern='\.docker/|\.kube/|\.ssh/|\.gnupg/|\.aws/|\.azure/|\.terraform(\.d)?/|\.config/(gcloud|gh|rclone)/|\.npmrc|\.pypirc|\.git-credentials|id_(rsa|ed25519|ecdsa|dsa)|credentials|\.env|\.pem|\.key|\.(p12|pfx|p8|jks|keystore)'
  if grep -Ei "$credential_path_pattern" "$TEST_TMP/package-files-secret-check.txt" >/dev/null; then
    echo "package listing included a credential-bearing path" >&2
    exit 1
  fi
  "$BIN" package >/dev/null
  if tar -tf .elisapkg/package.tar | grep -Ei "$credential_path_pattern" >/dev/null; then
    echo "package archive included a credential-bearing path" >&2
    exit 1
  fi
  mv "$TEST_TMP/credentials-manifest.good" elisapkg.json
  rm -rf .docker .kube .ssh .gnupg .AWS .azure .terraform .terraform.d .config .env.production credentials-backup private.pem-store private.key-store .NPMRC .pypirc .git-credentials signing.p12 signing.PFX signing.p8 trust.jks token.keystore src/.env src/config.env src/private.pem
  "$BIN" resolve >/dev/null
  "$BIN" package >/dev/null
  ln -s main.elisa src/linked-main
  "$BIN" resolve >/dev/null
  "$BIN" package --list > "$TEST_TMP/package-files-symlink-check.txt"
  if grep -F 'src/linked-main' "$TEST_TMP/package-files-symlink-check.txt" >/dev/null; then
    echo "package listing included a symlinked source path" >&2
    exit 1
  fi
  rm src/linked-main
  "$BIN" resolve --frozen >/dev/null
  printf '%s' junk >> .elisapkg/package.receipt
  if "$BIN" cache verify >/dev/null 2>&1; then
    echo "cache verification accepted a tampered package receipt" >&2
    exit 1
  fi
  "$BIN" package >/dev/null
  mv .elisapkg/package.receipt .elisapkg/package.receipt.saved
  if "$BIN" cache verify >/dev/null 2>&1; then
    echo "cache verification accepted a package without its receipt" >&2
    exit 1
  fi
  mv .elisapkg/package.receipt.saved .elisapkg/package.receipt
  python3 - <<'PY'
from pathlib import Path
for name in ("src/.env", "src/config.env", "src/private.pem"):
    Path(name).unlink()
PY
  PREFIX="$CASE/local-prefix"
  if ELISAPKG_INSTALL_PREFIX="$CASE/local-prefix/../escape" "$BIN" install --local >/dev/null 2>&1; then
    echo "path traversal install prefix was accepted" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  if ELISAPKG_INSTALL_PREFIX="$CASE/local-prefix/./dot" "$BIN" install --local >/dev/null 2>&1; then
    echo "non-canonical install prefix was accepted" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  INSECURE_PREFIX="$CASE/insecure-prefix"
  mkdir -m 777 "$INSECURE_PREFIX"
  chmod 777 "$INSECURE_PREFIX"
  if ELISAPKG_INSTALL_PREFIX="$INSECURE_PREFIX" "$BIN" install --local >/dev/null 2>&1; then
    echo "local install accepted a group/other-writable prefix" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  test ! -e "$INSECURE_PREFIX/bin"
  INSECURE_PARENT="$CASE/insecure-parent"
  mkdir "$INSECURE_PARENT"
  chmod 777 "$INSECURE_PARENT"
  if ELISAPKG_INSTALL_PREFIX="$INSECURE_PARENT/nested-prefix" "$BIN" install --local >/dev/null 2>&1; then
    echo "local install accepted a writable existing prefix ancestor" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  test ! -e "$INSECURE_PARENT/nested-prefix"
  SYMLINK_TARGET="$CASE/symlink-target"
  SYMLINK_PREFIX="$CASE/symlink-prefix"
  mkdir "$SYMLINK_TARGET"
  ln -s "$SYMLINK_TARGET" "$SYMLINK_PREFIX"
  if ELISAPKG_INSTALL_PREFIX="$SYMLINK_PREFIX/nested-prefix" "$BIN" install --local >/dev/null 2>&1; then
    echo "local install accepted a symlinked prefix component" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  test ! -e "$SYMLINK_TARGET/nested-prefix"
  ELISAPKG_INSTALL_PREFIX="$PREFIX" "$BIN" install --local >/dev/null
  test -x "$PREFIX/bin/app"
  ELISAPKG_INSTALL_PREFIX="$PREFIX" "$PREFIX/bin/app"
  if ELISAPKG_INSTALL_PREFIX="$PREFIX" "$BIN" install --local >/dev/null 2>&1; then
    echo "local install overwrote an existing destination" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  cp "$PREFIX/bin/app" "$PREFIX/bin/app.good"
  printf '%s' x >> "$PREFIX/bin/app"
  if ELISAPKG_INSTALL_PREFIX="$PREFIX" "$BIN" uninstall --local app >/dev/null 2>&1; then
    echo "local uninstall removed a modified binary" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  cp "$PREFIX/bin/app.good" "$PREFIX/bin/app"
  rm "$PREFIX/bin/app.good"
  cp "$PREFIX/share/elisapkg/receipts/app" "$PREFIX/share/elisapkg/receipts/app.good"
  printf '%s' junk >> "$PREFIX/share/elisapkg/receipts/app"
  if ELISAPKG_INSTALL_PREFIX="$PREFIX" "$BIN" uninstall --local app >/dev/null 2>&1; then
    echo "local uninstall accepted a malformed receipt" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  mv "$PREFIX/share/elisapkg/receipts/app.good" "$PREFIX/share/elisapkg/receipts/app"
  chmod 777 "$PREFIX/bin"
  if ELISAPKG_INSTALL_PREFIX="$PREFIX" "$BIN" uninstall --local app >/dev/null 2>&1; then
    echo "local uninstall accepted a group/other-writable binary directory" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  test -x "$PREFIX/bin/app"
  test -f "$PREFIX/share/elisapkg/receipts/app"
  chmod 755 "$PREFIX/bin"
  chmod 777 "$PREFIX/share/elisapkg/receipts"
  if ELISAPKG_INSTALL_PREFIX="$PREFIX" "$BIN" uninstall --local app >/dev/null 2>&1; then
    echo "local uninstall accepted a group/other-writable receipt directory" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  test -x "$PREFIX/bin/app"
  test -f "$PREFIX/share/elisapkg/receipts/app"
  chmod 755 "$PREFIX/share/elisapkg/receipts"
  ELISAPKG_INSTALL_PREFIX="$PREFIX" "$BIN" uninstall --local app >/dev/null
  test ! -e "$PREFIX/bin/app"
  TRAILING_HOME="$CASE/trailing-home"
  mkdir -p "$TRAILING_HOME"
  env -u ELISAPKG_INSTALL_PREFIX HOME="$TRAILING_HOME/" "$BIN" install --local >/dev/null
  test -x "$TRAILING_HOME/.local/bin/app"
  env -u ELISAPKG_INSTALL_PREFIX HOME="$TRAILING_HOME/" "$BIN" uninstall --local app >/dev/null
  test ! -e "$TRAILING_HOME/.local/bin/app"
  PROBE="$CASE/compiler-env-probe.sh"
  PROBE_OUTPUT="$CASE/compiler-env.output"
  printf '%s\n' '#!/bin/sh' 'exec /usr/bin/env' > "$PROBE"
  chmod +x "$PROBE"
  if ELISAPKG_COMPILER="$PROBE" ELISAPKG_SECRET=should_not_cross "$BIN" build >"$PROBE_OUTPUT" 2>&1; then
    echo "compiler probe unexpectedly succeeded" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  grep -F 'ELISA_STAGE1_SEMANTIC_GATE=1' "$PROBE_OUTPUT" >/dev/null
  if grep -F 'ELISAPKG_SECRET=should_not_cross' "$PROBE_OUTPUT" >/dev/null 2>&1; then
    echo "compiler child inherited a parent secret" >&2
    exit 1
  fi
  WRITE_PROBE="$CASE/compiler-write-probe.sh"
  WRITE_MARKER="$CASE/src/compiler-write.marker"
  printf '%s\n' '#!/bin/sh' "printf blocked > '$WRITE_MARKER'" 'exec /usr/bin/env' > "$WRITE_PROBE"
  chmod +x "$WRITE_PROBE"
  if ELISAPKG_COMPILER="$WRITE_PROBE" "$BIN" build >/dev/null 2>&1; then
    echo "compiler probe unexpectedly succeeded after a project write" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  test ! -e "$WRITE_MARKER"
  if ELISAPKG_COMPILER='-invalid-compiler' "$BIN" build >/dev/null 2>&1; then
    echo "option-shaped compiler override unexpectedly succeeded" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  TOO_LONG_TOOLCHAIN_VALUE="$(python3 -c 'print("x" * 4097)')"
  if ELISA_STAGE1_BIN="$TOO_LONG_TOOLCHAIN_VALUE" "$BIN" build >/dev/null 2>&1; then
    echo "oversized compiler bootstrap override unexpectedly succeeded" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  printf '%s\n' 'def main() -> i64:' '    return 7' > src/main.elisa
  if "$BIN" run -- >/dev/null 2>&1; then
    echo "run discarded the child exit status" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  printf '%s\n' 'def main() -> i64:' '    return 0' > src/main.elisa
  "$BIN" resolve >/dev/null
  "$BIN" metadata --json | grep -F '"schema-version":1' >/dev/null
  "$BIN" tree | grep -F 'app 0.1.0' >/dev/null
  "$BIN" tree | grep -F 'local-util 1.2.3' >/dev/null
  "$BIN" why local-util | grep -F 'app -> local-util' >/dev/null
  "$BIN" package >/dev/null
  test -s .elisapkg/package.tar
  "$BIN" update local-util >/dev/null
  if "$BIN" add local-util --path local-util >/dev/null 2>&1; then
    echo "duplicate dependency was accepted" >&2
    exit 1
  else
    test "$?" -eq 3
  fi
  "$BIN" remove local-util >/dev/null
  "$BIN" check-manifest >/dev/null
  "$BIN" resolve --frozen >/dev/null
  "$BIN" fetch >/dev/null
  if "$BIN" fetch -- ignored >/dev/null 2>&1; then
    echo "fetch silently discarded arguments after --" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  if "$BIN" build -- ignored >/dev/null 2>&1; then
    echo "build silently accepted arguments after --" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  if "$BIN" cache verify --dry-run >/dev/null 2>&1; then
    echo "cache verify silently accepted --dry-run" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  if "$BIN" publish >/dev/null 2>&1; then
    echo "publish unexpectedly succeeded" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  "$BIN" publish --dry-run | grep -F 'publish dry-run: manifest, lockfile, source tree, and package file selection are valid' >/dev/null
  cp .elisapkg/package.tar .elisapkg/package.tar.before-publish-dry-run
  "$BIN" publish --json --dry-run | grep -E '^\{"schema-version":1,"command":"publish","dry-run":true,"valid":true,"source-tree-digest":"sha256:[0-9a-f]{64}","archive-size":[0-9]+,"archive-digest":"sha256:[0-9a-f]{64}"\}$' >/dev/null
  "$BIN" publish --dry-run --json | grep -E '^\{"schema-version":1,"command":"publish","dry-run":true,"valid":true,"source-tree-digest":"sha256:[0-9a-f]{64}","archive-size":[0-9]+,"archive-digest":"sha256:[0-9a-f]{64}"\}$' >/dev/null
  cmp .elisapkg/package.tar.before-publish-dry-run .elisapkg/package.tar >/dev/null
  if "$BIN" install app >/dev/null 2>&1; then
    echo "remote install unexpectedly succeeded" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  "$BIN" fetch --offline >/dev/null
  test -f .elisapkg/build/app
  "$BIN" clean >/dev/null
  test ! -e .elisapkg/build/app
  mkdir -p .elisapkg
  cp elisapkg.json .elisapkg/transaction.manifest
  cp elisapkg.lock .elisapkg/transaction.lock
  cp elisapkg.json recovered.manifest
  printf '%s\n' 'prepared-lock' > .elisapkg/transaction.state
  cp recovered.manifest elisapkg.json
  "$BIN" check-manifest >/dev/null
  cmp recovered.manifest elisapkg.json >/dev/null
  test ! -e .elisapkg/transaction.state
  cp recovered.manifest .elisapkg/transaction.manifest
  cp elisapkg.lock .elisapkg/transaction.lock
  printf '%s\n' '{}' > .elisapkg/transaction.new-manifest
  printf '%s\n' 'manifest-replaced' > .elisapkg/transaction.state
  cp .elisapkg/transaction.new-manifest elisapkg.json
  mkdir .elisapkg/transaction.guard
  if "$BIN" check-manifest >/dev/null 2>&1; then
    echo "transaction recovery modified a journal while its guard was held" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  cmp .elisapkg/transaction.new-manifest elisapkg.json >/dev/null
  cmp .elisapkg/transaction.lock elisapkg.lock >/dev/null
  test -f .elisapkg/transaction.state
  test -d .elisapkg/transaction.guard
  rmdir .elisapkg/transaction.guard
  "$BIN" check-manifest >/dev/null
  cmp recovered.manifest elisapkg.json >/dev/null
  test ! -e .elisapkg/transaction.state
  cp recovered.manifest .elisapkg/transaction.manifest
  cp elisapkg.lock .elisapkg/transaction.lock
  printf '%s\n' 'prepared-lock' > .elisapkg/transaction.state
  printf '%s\n' '{}' > elisapkg.json
  if "$BIN" check-manifest >/dev/null 2>&1; then
    echo "transaction recovery overwrote an external manifest edit" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  cp recovered.manifest elisapkg.json
  "$BIN" check-manifest >/dev/null
  test ! -e .elisapkg/transaction.state
  cp recovered.manifest .elisapkg/transaction.manifest
  cp elisapkg.lock .elisapkg/transaction.lock
  printf '%s\n' 'prepared-lock' > .elisapkg/transaction.state
  printf '%s\n' '{"external":"lock-edit"}' > elisapkg.lock
  if "$BIN" check-manifest >/dev/null 2>&1; then
    echo "transaction recovery overwrote an external lockfile edit" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  cp .elisapkg/transaction.lock elisapkg.lock
  "$BIN" check-manifest >/dev/null
  test ! -e .elisapkg/transaction.state
  printf '%s\n' 'unrecognized-state' > .elisapkg/transaction.state
  if "$BIN" check-manifest >/dev/null 2>&1; then
    echo "unrecognized transaction state was accepted" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  python3 -c 'import os; os.unlink(".elisapkg/transaction.state")'
)

# Library targets emit a regular object with the same atomic receipt/cache
# handling as binaries. They must never be accidentally executed or installed
# through the local binary path, and clean must remove the object output too.
LIB_CASE="$TEST_TMP/library-target-$$"
LIB_PREFIX="$LIB_CASE/prefix"
mkdir -p "$LIB_CASE"
"$BIN" init "$LIB_CASE" --lib >/dev/null
(
  cd "$LIB_CASE"
  "$BIN" build >/dev/null
  test -f .elisapkg/build/app.o
  test ! -e .elisapkg/build/app
  "$BIN" build | grep -F '(cached)' >/dev/null
  if "$BIN" run -- >/dev/null 2>&1; then
    echo "library target was executed as a binary" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  if ELISAPKG_INSTALL_PREFIX="$LIB_PREFIX" "$BIN" install --local >/dev/null 2>&1; then
    echo "library target was installed as a binary" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  if ELISAPKG_INSTALL_PREFIX="$LIB_PREFIX" "$BIN" install --local unexpected >/dev/null 2>&1; then
    echo "install accepted an unexpected positional argument" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  "$BIN" clean >/dev/null
  test ! -e .elisapkg/build/app.o
)

# Named targets must have independent artifact names and selectors. Building a
# binary, library, and test from one manifest exercises the same target graph
# without allowing one target's output or run path to shadow another's.
MULTI_CASE="$TEST_TMP/multi-target-$$"
mkdir -p "$MULTI_CASE"
"$BIN" init "$MULTI_CASE" >/dev/null
(
  cd "$MULTI_CASE"
  printf '%s\n' 'def main() -> i64:' '    return 0' > src/tool.elisa
  printf '%s\n' 'def main() -> i64:' '    return 0' > src/util.elisa
  printf '%s\n' 'def main() -> i64:' '    return 0' > src/checks.elisa
  cat > elisapkg.json <<'EOF'
{"schema-version":1,"package":{"name":"multi","version":"0.1.0"},"targets":[{"name":"app","kind":"bin","entry":"src/main.elisa"},{"name":"tool","kind":"bin","entry":"src/tool.elisa"},{"name":"util","kind":"lib","entry":"src/util.elisa"},{"name":"checks","kind":"test","entry":"src/checks.elisa"}],"dependencies":{}}
EOF
  "$BIN" check-manifest >/dev/null
  "$BIN" resolve >/dev/null
  "$BIN" build --bin tool >/dev/null
  test -x .elisapkg/build/tool
  test ! -e .elisapkg/build/app
  "$BIN" build --lib util >/dev/null
  test -f .elisapkg/build/util.o
  "$BIN" test --test checks >/dev/null
  test -x .elisapkg/build/checks
  "$BIN" run --bin tool -- >/dev/null
  if "$BIN" build --bin missing >/dev/null 2>&1; then
    echo "unknown named target was accepted" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
)

# Keep this hostile-path fixture isolated per invocation. A previous interrupted
# run may leave its symlink probes behind, and reusing the directory would make
# the next test fail before exercising the package manager.
BAD="$TEST_TMP/invalid-package-$$"
mkdir -p "$BAD/src"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$BAD/src/main.elisa"
printf '%s\n' '{"schema-version":1,"package":{"name":"Bad_Name","version":"1.0.0"},"targets":[],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "invalid manifest was accepted" >&2
  exit 1
fi

for invalid_version in 1.01.0 1.0.0-01 1.0; do
  printf '%s\n' "{\"schema-version\":1,\"package\":{\"name\":\"bad\",\"version\":\"$invalid_version\"},\"targets\":[{\"entry\":\"src/main.elisa\"}],\"dependencies\":{}}" > "$BAD/elisapkg.json"
  if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
    echo "invalid version was accepted: $invalid_version" >&2
    exit 1
  fi
done

# A target that exists only through a symlink escaping the package root must be
# rejected before any build or package operation can read it.
OUTSIDE="$TEST_TMP/invalid-target-outside-$$"
mkdir -p "$OUTSIDE"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$OUTSIDE/main.elisa"
ln -s "$OUTSIDE" "$BAD/escape"
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"escape/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "symlink target escaped the package root" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"src"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "directory target entry was accepted" >&2
  exit 1
fi
ln -sf src/main.elisa "$BAD/linked-main"
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"linked-main"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "symlink target entry was accepted" >&2
  exit 1
fi

printf '%s\n' '{"schema-version":1,"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"package":{"name":"good","version":"1.0.0"},"dependencies":{}}' > "$BAD/elisapkg.json"
(cd "$BAD" && "$BIN" check-manifest >/dev/null)
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"},{"name":"target","kind":"test","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "duplicate target name was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"plugin","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unsupported target kind was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"},1],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "scalar target array member was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":"primary"}}}' > "$BAD/elisapkg.json"
if ! (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "supported primary registry dependency was rejected" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"1.01.0","registry":"primary"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "invalid dependency requirement was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"path":"local","registry":"primary","version":"^1.0.0"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "dependency with contradictory sources was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":true}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "non-string registry was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"path":"local","extra":true}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unknown local dependency field was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":"primary","extra":true}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unknown registry dependency field was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"git":"https://example.invalid/foo","rev":"0123456789abcdef0123456789abcdef01234567"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unsupported Git dependency was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":"primary"},"foo":{"version":"^1.0.0","registry":"primary"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "duplicate dependency alias was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"../outside.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "traversal target entry was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"./src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "dot-prefixed target entry was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
cp "$BAD/elisapkg.json" "$BAD/manifest.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "ambiguous manifest pair was accepted" >&2
  exit 1
fi
mv "$BAD/manifest.json" "$BAD/manifest.json.checked"

printf '%s\n' '{"schema-version":1,"targets":[{"package":{"name":"nested","version":"1.0.0"},"entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "nested package object was accepted as the root package" >&2
  exit 1
fi

printf '%s\n' '{"schema-version":1,"package":{"name":"good","name":"evil","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "duplicate package key was accepted" >&2
  exit 1
fi

printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "duplicate target key was accepted" >&2
  exit 1
fi

printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0","unknown-policy-hook":true},"targets":[{"entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unknown manifest field was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0","description":true},"targets":[{"entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "non-string package metadata was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"src/main.elisa"}],"include":{},"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "non-array include field was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"src/main.elisa"}],"include":["src/**",],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "trailing include comma was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"src/main.elisa"}],"include":["src/../secret"],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unsafe include path was accepted" >&2
  exit 1
fi
python3 - "$BAD/elisapkg.json" <<'PY'
import sys
path = sys.argv[1]
data = b'{"schema-version":1,"package":{"name":"bad","version":"1.0.0","description":"ok\xc0"},"targets":[{"name":"bad","kind":"bin","entry":"src/main.elisa"}],"dependencies":{}}\n'
with open(path, "wb") as handle:
    handle.write(data)
PY
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "invalid UTF-8 manifest was accepted" >&2
  exit 1
fi

printf '%s' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
head -c 1049000 /dev/zero | tr '\0' ' ' >> "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "oversized manifest was accepted" >&2
  exit 1
fi

CYCLE="$TEST_TMP/cycle-package-$$"
mkdir -p "$CYCLE/a/src" "$CYCLE/b/src" "$CYCLE/src"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$CYCLE/src/main.elisa"
cp "$CYCLE/src/main.elisa" "$CYCLE/a/src/main.elisa"
cp "$CYCLE/src/main.elisa" "$CYCLE/b/src/main.elisa"
printf '%s\n' '{"schema-version":1,"package":{"name":"a","version":"1.0.0"},"targets":[{"name":"a","kind":"lib","entry":"src/main.elisa"}],"dependencies":{"b":{"path":"../b"}}}' > "$CYCLE/a/elisapkg.json"
printf '%s\n' '{"schema-version":1,"package":{"name":"b","version":"1.0.0"},"targets":[{"name":"b","kind":"lib","entry":"src/main.elisa"}],"dependencies":{"a":{"path":"../a"}}}' > "$CYCLE/b/elisapkg.json"
printf '%s\n' '{"schema-version":1,"package":{"name":"root","version":"1.0.0"},"targets":[{"name":"root","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"a":{"path":"a"}}}' > "$CYCLE/elisapkg.json"
if (cd "$CYCLE" && "$BIN" resolve >/dev/null 2>&1); then
  echo "dependency cycle was accepted" >&2
  exit 1
else
  test "$?" -eq 3
fi

python3 "$ROOT/scripts/regression_test.py"
echo "elisapkg smoke tests passed"
