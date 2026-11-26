# Sourced by scripts/test.sh after the shared smoke setup.

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
    package: mutable darray[u8] = [116,114,117,115,116,115,116,97,116,101]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    for _index in 0..<64 |digest|:
        digest.push(97)
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |metadata_digest|:
        metadata_digest.push(99)
    return 0 if Registry::record_trusted(package, version, digest, metadata_digest, Platform::wall_clock_seconds().u64() + 3600) == Registry::ResultCode.Ok else 1
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_V1_BIN" "$TRUST_STATE_V1_PROBE"
cat > "$TRUST_STATE_VERIFY_V1_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [116,114,117,115,116,115,116,97,116,101]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    for _index in 0..<64 |digest|:
        digest.push(97)
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |metadata_digest|:
        metadata_digest.push(99)
    return 0 if Registry::verify_trusted(package, version, digest, metadata_digest, Platform::wall_clock_seconds().u64() + 3600) == Registry::ResultCode.Ok else 1
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
    return 0 if Registry::verify_trusted(package, version, digest, metadata_digest, Platform::wall_clock_seconds().u64() + 3600) == Registry::ResultCode.TrustStateMalformed else 1
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
ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_LEGACY_FILE" "$TRUST_STATE_LEGACY_BIN"
write_registry_index truststate 1 0.9.0,1.0.0,2.0.0
ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_V1_BIN"
cp "$TRUST_STATE_FILE" "$TRUST_STATE_V1_SNAPSHOT"
TRUST_STATE_CURRENT_HASH=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TRUST_STATE_FILE")
printf 'clock:0\nstate-sha256:%s\n' "$TRUST_STATE_CURRENT_HASH" > "$TRUST_STATE_FILE.clock"
ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_VERIFY_V1_BIN"
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
    package: mutable darray[u8] = [116,114,117,115,116,115,116,97,116,101]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |digest, metadata_digest|:
        digest.push(97)
        metadata_digest.push(100)
    return 1 if Registry::verify_trusted(package, version, digest, metadata_digest, Platform::wall_clock_seconds().u64() + 3600) != Registry::ResultCode.DigestMismatch
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
ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_VERIFY_FAIL_BIN"
grep -Fx "clock:0" "$TRUST_STATE_FILE.clock" >/dev/null
cat > "$TRUST_STATE_RECORD_EXPIRED_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [116,114,117,115,116,115,116,97,116,101]
    version: mutable darray[u8] = [49,46,48,46,48]
    digest: mutable darray[u8] = []
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |digest, metadata_digest|:
        digest.push(97)
        metadata_digest.push(99)
    return 1 if Registry::record_trusted(package, version, digest, metadata_digest, 1) != Registry::ResultCode.ExpiredMetadata
    beyond_horizon: u64 = Platform::wall_clock_seconds().u64() + 2592001
    return 2 if Registry::record_trusted(package, version, digest, metadata_digest, beyond_horizon) != Registry::ResultCode.ExpiryHorizon
    return 3 if Registry::verify_trusted(package, version, digest, metadata_digest, beyond_horizon) != Registry::ResultCode.ExpiryHorizon
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_RECORD_EXPIRED_BIN" "$TRUST_STATE_RECORD_EXPIRED_PROBE"
ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_RECORD_EXPIRED_BIN"
grep -Fx "clock:0" "$TRUST_STATE_FILE.clock" >/dev/null
cat > "$TRUST_STATE_PROBE" <<EOF
include "$ROOT/src/registry.elisa"

def filled(value: u8) -> darray[u8]:
    out: mutable darray[u8] = []
    for _index in 0..<64 |out|:
        out.push(value)
    return out

def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [116,114,117,115,116,115,116,97,116,101]
    v1: mutable darray[u8] = [49,46,48,46,48]
    v0: mutable darray[u8] = [48,46,57,46,48]
    v2: mutable darray[u8] = [50,46,48,46,48]
    digest_a: mutable darray[u8] = filled(97)
    digest_b: mutable darray[u8] = filled(98)
    metadata_a: mutable darray[u8] = filled(99)
    metadata_b: mutable darray[u8] = filled(100)
    return 1 if Registry::record_trusted(package, v1, digest_a, metadata_a, Platform::wall_clock_seconds().u64() + 3600) != Registry::ResultCode.Ok
    return 2 if Registry::record_trusted(package, v0, digest_a, metadata_a, Platform::wall_clock_seconds().u64() + 3600) != Registry::ResultCode.RollbackDetected
    return 3 if Registry::record_trusted(package, v1, digest_b, metadata_a, Platform::wall_clock_seconds().u64() + 3600) != Registry::ResultCode.DigestMismatch
    return 4 if Registry::record_trusted(package, v1, digest_a, metadata_b, Platform::wall_clock_seconds().u64() + 3600) != Registry::ResultCode.DigestMismatch
    return 5 if Registry::record_trusted(package, v2, digest_b, metadata_b, Platform::wall_clock_seconds().u64() + 3600) != Registry::ResultCode.Ok
    return 6 if Registry::record_trusted(package, v2, digest_b, metadata_b, Platform::wall_clock_seconds().u64() + 3600) != Registry::ResultCode.Ok
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_BIN" "$TRUST_STATE_PROBE"
ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_BIN"
cat > "$TRUST_STATE_REPEAT_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:
    package: mutable darray[u8] = [116,114,117,115,116,115,116,97,116,101]
    digest: mutable darray[u8] = []
    for _index in 0..<64 |digest|:
        digest.push(98)
    metadata_digest: mutable darray[u8] = []
    for _index in 0..<64 |metadata_digest|:
        metadata_digest.push(100)
    version: mutable darray[u8] = [50,46,48,46,48]
    return 0 if Registry::record_trusted(package, version, digest, metadata_digest, Platform::wall_clock_seconds().u64() + 3600) == Registry::ResultCode.Ok else 1
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$TRUST_STATE_REPEAT_BIN" "$TRUST_STATE_REPEAT_PROBE"
ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN"
test -s "$TRUST_STATE_FILE"
test -s "$TRUST_STATE_FILE.clock"
cp "$TRUST_STATE_FILE" "$TRUST_STATE_V2_SNAPSHOT"
cp "$TRUST_STATE_V1_SNAPSHOT" "$TRUST_STATE_FILE"
chmod 600 "$TRUST_STATE_FILE"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_VERIFY_V1_BIN" >/dev/null 2>&1; then
  echo "restored old trust-state history was accepted by verification" >&2
  exit 1
fi
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "restored old trust-state history was accepted by recording" >&2
  exit 1
fi
rm "$TRUST_STATE_FILE"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "missing trust-state bytes with a retained clock were accepted" >&2
  exit 1
fi
cp "$TRUST_STATE_V2_SNAPSHOT" "$TRUST_STATE_FILE"
chmod 600 "$TRUST_STATE_FILE"
chmod 666 "$TRUST_STATE_FILE"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "writable trust-state file was accepted" >&2
  exit 1
fi
chmod 600 "$TRUST_STATE_FILE"
mkdir -m 777 "$TEST_TMP/trust-state-insecure"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TEST_TMP/trust-state-insecure/state" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "trust state in a shared writable directory was accepted" >&2
  exit 1
fi
test ! -e "$TEST_TMP/trust-state-insecure/state"
TRUST_STATE_CURRENT_HASH=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TRUST_STATE_FILE")
printf 'clock:18446744073709551615\nstate-sha256:%s\n' "$TRUST_STATE_CURRENT_HASH" > "$TRUST_STATE_FILE.clock"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "trust-state clock rollback was accepted" >&2
  exit 1
fi
rm -f "$TRUST_STATE_FILE.clock"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "missing trust-state clock was accepted" >&2
  exit 1
fi
printf 'clock:0\n' > "$TRUST_STATE_FILE.clock"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "legacy clock without state binding was accepted" >&2
  exit 1
fi
printf 'clock:0\nstate-sha256:%s\n' "$TRUST_STATE_CURRENT_HASH" > "$TRUST_STATE_FILE.clock"
TRUST_STATE_LEGACY_LOCK_FILE="$TEST_TMP/trust-state-legacy-lock-$$.state"
mkdir "$TRUST_STATE_LEGACY_LOCK_FILE.lock"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_LEGACY_LOCK_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "legacy trust-state directory lock was accepted" >&2
  exit 1
fi
rmdir "$TRUST_STATE_LEGACY_LOCK_FILE.lock"
ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" python3 "$ROOT/scripts/security/trust_state_lock_regression.py" "$TRUST_STATE_REPEAT_BIN" "$REGISTRY_EXPIRY_ROOT" "$TRUST_STATE_FILE"
printf 'invalid trust state\n' > "$TRUST_STATE_FILE"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "malformed trust state was accepted" >&2
  exit 1
fi
printf 'elisapkg-trust-state:1\napp 1.0.0 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$TRUST_STATE_FILE"
TRUST_STATE_TRUNCATED_HASH=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TRUST_STATE_FILE")
printf 'clock:0\nstate-sha256:%s\n' "$TRUST_STATE_TRUNCATED_HASH" > "$TRUST_STATE_FILE.clock"
if ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" ELISAPKG_TRUST_STATE="$TRUST_STATE_FILE" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "truncated trust state was accepted" >&2
  exit 1
fi

# The default HOME-derived trust path must reject control bytes and normalize a
# trailing separator. This exercises the same path helper used when no explicit
# ELISAPKG_TRUST_STATE override is configured.
DEFAULT_TRUST_HOME="$TEST_TMP/default-trust-home-$$"
mkdir -p "$DEFAULT_TRUST_HOME"
env -u ELISAPKG_TRUST_STATE HOME="$DEFAULT_TRUST_HOME/" ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" "$TRUST_STATE_BIN"
test -n "$(find "$DEFAULT_TRUST_HOME/.local/share/elisapkg/trust" -name '*.state' -type f -print -quit)"
BAD_TRUST_HOME="$TEST_TMP/bad-trust-home-$$"
BAD_TRUST_HOME="$BAD_TRUST_HOME"$'\n'x
if env -u ELISAPKG_TRUST_STATE HOME="$BAD_TRUST_HOME" ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "control-byte HOME was accepted for trust state" >&2
  exit 1
fi
BAD_TRUST_HOME_PARENT="$TEST_TMP/home-parent-$$/../escape"
if env -u ELISAPKG_TRUST_STATE HOME="$BAD_TRUST_HOME_PARENT" ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "parent traversal HOME was accepted for trust state" >&2
  exit 1
fi
if ELISAPKG_TRUST_STATE="$TEST_TMP/trust-state-parent-$$/../escape.state" ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "parent traversal trust-state override was accepted" >&2
  exit 1
fi
if ELISAPKG_TRUST_STATE="$TEST_TMP/trust-state-dot-$$/./escape.state" ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" "$TRUST_STATE_REPEAT_BIN" >/dev/null 2>&1; then
  echo "non-canonical trust-state override was accepted" >&2
  exit 1
fi
