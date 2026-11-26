# Sourced by scripts/test.sh after the shared smoke setup.

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
