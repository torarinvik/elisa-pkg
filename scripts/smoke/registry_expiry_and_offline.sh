# Sourced by scripts/test.sh after the shared smoke setup.

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
write_registry_index() {
  local expiry_kind="${4:-}"
  local identity_mode="${5:-}"
  local yanked_versions="${6:-}"
  python3 - "$REGISTRY_EXPIRY_ROOT" "$REGISTRY_EXPIRY_PRIVATE" "$OPENSSL_BIN" "$1" "$2" "$3" "$expiry_kind" "$identity_mode" "$yanked_versions" <<'PY'
from pathlib import Path
import subprocess, sys, time

root = Path(sys.argv[1])
private_key = sys.argv[2]
openssl = sys.argv[3]
package = sys.argv[4]
generation = int(sys.argv[5])
versions = sys.argv[6].split(",")
if versions == ["4097-versions"]:
    versions = [f"0.0.{number}" for number in range(1, 4098)]
expiry_kind = sys.argv[7]
identity_mode = sys.argv[8]
yanked_versions = sys.argv[9].split(",") if sys.argv[9] else []
expires = int(time.time()) + 86400
if expiry_kind == "expired":
    expires = 1
elif expiry_kind == "long":
    expires = int(time.time()) + 31 * 86400
elif expiry_kind:
    expires = int(expiry_kind)
registry_field = str(root) + ("-other" if identity_mode == "wrong-registry" else "")
package_field = package + ("-other" if identity_mode == "wrong-package" else "")
payload = (
    "elisapkg-index:1\n"
    f"registry:{registry_field}\n"
    f"package:{package_field}\n"
    f"generation:{generation}\n"
    f"expires:{expires}\n"
    "versions:\n"
    + "".join(f"{version}\n" for version in versions)
    + ("yanked:\n" + "".join(f"{version}\n" for version in yanked_versions) if yanked_versions else "")
).encode("ascii")
package_dir = root / package
package_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
index_path = package_dir / "index"
index_path.write_bytes(payload)
index_path.chmod(0o600)
subprocess.run([openssl, "pkeyutl", "-sign", "-rawin", "-inkey", private_key,
                "-in", str(index_path), "-out", str(package_dir / "index.sig")], check=True)
(package_dir / "index.sig").chmod(0o600)
PY
}
write_registry_release() {
  python3 - "$BIN" "$REGISTRY_EXPIRY_ROOT" "$REGISTRY_EXPIRY_SOURCE" "$REGISTRY_EXPIRY_PRIVATE" "$OPENSSL_BIN" "$@" <<'PYTHON'
from pathlib import Path
import hashlib, json, subprocess, sys, time

binary, root, sources, key, openssl, package, version, expiry = sys.argv[1:]
root = Path(root)
project = Path(sources) / package / version
project.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([binary, "init", str(project)], check=True, stdout=subprocess.DEVNULL)
manifest_path = project / "elisapkg.json"
manifest = json.loads(manifest_path.read_text())
manifest["package"].update(name=package, version=version)
manifest_path.write_text(json.dumps(manifest) + "\n")
for command in ("resolve", "package"):
    subprocess.run([binary, command], cwd=project, check=True, stdout=subprocess.DEVNULL)
archive = (project / ".elisapkg/package.tar").read_bytes()

release = root / package / version
release.mkdir(mode=0o700, parents=True)
(release / "archive.tar").write_bytes(archive)
metadata = {
    "schema-version": 1,
    "algorithm": "ed25519",
    "registry": str(root),
    "package": package,
    "version": version,
    "archive": "archive.tar",
    "archive-size": len(archive),
    "archive-digest": hashlib.sha256(archive).hexdigest(),
    "expires": int(time.time()) + 3600 if expiry == "current" else int(expiry),
}
metadata_path = release / "metadata.json"
metadata_path.write_text(json.dumps(metadata, separators=(",", ":")) + "\n")
subprocess.run([openssl, "pkeyutl", "-sign", "-rawin", "-inkey", key,
                "-in", str(metadata_path), "-out", str(release / "metadata.sig")],
               check=True)
PYTHON
}
write_registry_release foo 1.0.0 1
write_registry_release foo 1.1.0 current
write_registry_release unused 1.0.0 current
write_registry_index unused 1 1.0.0

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

resolve_registry_app() {
  (
    cd "$REGISTRY_EXPIRY_APP"
    ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
    ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
    ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_STATE" \
      "$BIN" resolve >/dev/null
  )
}

REGISTRY_EXPIRY_ONLY_APP="$REGISTRY_EXPIRY_CASE/app-expired-only"
write_registry_dependency "$REGISTRY_EXPIRY_ONLY_APP" "^1.0.0"
write_registry_index foo 1 1.0.0
if (
  cd "$REGISTRY_EXPIRY_ONLY_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_CASE/expired-only.state" \
    "$BIN" resolve > resolve.stdout 2> resolve.stderr
); then
  echo "resolution accepted a registry with only expired releases" >&2
  exit 1
else
  test "$?" -eq 3
fi
grep -F 'no registry version satisfies the requirement' "$REGISTRY_EXPIRY_ONLY_APP/resolve.stderr" >/dev/null
test ! -e "$REGISTRY_EXPIRY_ONLY_APP/elisapkg.lock"
write_registry_index foo 1 1.0.0,1.1.0

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

# Signed index payloads bind the whole version list to the registry, package,
# generation, and expiry. A byte edit without resigning and a validly signed
# generation replay must fail before either the lockfile or trust state moves.
write_registry_index foo 2 1.0.0,1.1.0
resolve_registry_app
cp "$REGISTRY_EXPIRY_APP/elisapkg.lock" "$REGISTRY_EXPIRY_CASE/lock-before-index-failures"
cp "$REGISTRY_EXPIRY_STATE" "$REGISTRY_EXPIRY_CASE/state-before-index-failures"
cp "$REGISTRY_EXPIRY_STATE.clock" "$REGISTRY_EXPIRY_CASE/clock-before-index-failures"
python3 - "$REGISTRY_EXPIRY_ROOT/foo/index" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
payload = path.read_bytes()
if b"1.1.0\n" not in payload:
    raise SystemExit("signed index fixture did not contain the expected latest version")
path.write_bytes(payload.replace(b"1.1.0\n", b"1.2.0\n", 1))
PY
if resolve_registry_app >/dev/null 2>&1; then
  echo "resolution accepted an index payload changed without a new signature" >&2
  exit 1
else
  test "$?" -eq 5
fi
cmp "$REGISTRY_EXPIRY_CASE/lock-before-index-failures" "$REGISTRY_EXPIRY_APP/elisapkg.lock" >/dev/null
cmp "$REGISTRY_EXPIRY_CASE/state-before-index-failures" "$REGISTRY_EXPIRY_STATE" >/dev/null
cmp "$REGISTRY_EXPIRY_CASE/clock-before-index-failures" "$REGISTRY_EXPIRY_STATE.clock" >/dev/null

# Even an authorized signature cannot roll the persisted generation backward.
# Equal-generation equivocation is rejected as well, because a generation
# identifies one immutable complete snapshot.
write_registry_index foo 2 1.0.0
if resolve_registry_app >/dev/null 2>&1; then
  echo "resolution accepted a different signed index at the same generation" >&2
  exit 1
else
  test "$?" -eq 5
fi
cmp "$REGISTRY_EXPIRY_CASE/lock-before-index-failures" "$REGISTRY_EXPIRY_APP/elisapkg.lock" >/dev/null
cmp "$REGISTRY_EXPIRY_CASE/state-before-index-failures" "$REGISTRY_EXPIRY_STATE" >/dev/null
cmp "$REGISTRY_EXPIRY_CASE/clock-before-index-failures" "$REGISTRY_EXPIRY_STATE.clock" >/dev/null
write_registry_index foo 1 1.0.0
if resolve_registry_app >/dev/null 2>&1; then
  echo "resolution accepted a validly signed older index generation" >&2
  exit 1
else
  test "$?" -eq 5
fi
cmp "$REGISTRY_EXPIRY_CASE/lock-before-index-failures" "$REGISTRY_EXPIRY_APP/elisapkg.lock" >/dev/null
cmp "$REGISTRY_EXPIRY_CASE/state-before-index-failures" "$REGISTRY_EXPIRY_STATE" >/dev/null
cmp "$REGISTRY_EXPIRY_CASE/clock-before-index-failures" "$REGISTRY_EXPIRY_STATE.clock" >/dev/null
write_registry_index foo 3 1.0.0,1.1.0
resolve_registry_app

cp "$REGISTRY_EXPIRY_APP/elisapkg.lock" "$REGISTRY_EXPIRY_CASE/lock-before-index-policy-failures"
cp "$REGISTRY_EXPIRY_STATE" "$REGISTRY_EXPIRY_CASE/state-before-index-policy-failures"
cp "$REGISTRY_EXPIRY_STATE.clock" "$REGISTRY_EXPIRY_CASE/clock-before-index-policy-failures"
for invalid_index_case in "wrong-registry" "wrong-package" "expired" "long" "unsorted" "duplicate" "prerelease" "yanked-unlisted" "yanked-unsorted" "yanked-duplicate" "overflow-generation" "too-many-versions" "missing-signature" "short-signature"; do
  case "$invalid_index_case" in
    wrong-registry) write_registry_index foo 4 1.0.0,1.1.0 "" wrong-registry ;;
    wrong-package) write_registry_index foo 4 1.0.0,1.1.0 "" wrong-package ;;
    expired) write_registry_index foo 4 1.0.0,1.1.0 expired ;;
    long) write_registry_index foo 4 1.0.0,1.1.0 long ;;
    unsorted) write_registry_index foo 4 1.1.0,1.0.0 ;;
    duplicate) write_registry_index foo 4 1.0.0,1.0.0 ;;
    prerelease) write_registry_index foo 4 1.0.0-alpha ;;
    yanked-unlisted) write_registry_index foo 4 1.0.0 "" "" 2.0.0 ;;
    yanked-unsorted) write_registry_index foo 4 1.0.0,1.1.0 "" "" 1.1.0,1.0.0 ;;
    yanked-duplicate) write_registry_index foo 4 1.0.0,1.1.0 "" "" 1.0.0,1.0.0 ;;
    overflow-generation) write_registry_index foo 18446744073709551616 1.0.0,1.1.0 ;;
    too-many-versions) write_registry_index foo 4 4097-versions ;;
    missing-signature) write_registry_index foo 4 1.0.0,1.1.0; rm "$REGISTRY_EXPIRY_ROOT/foo/index.sig" ;;
    short-signature) write_registry_index foo 4 1.0.0,1.1.0; python3 - "$REGISTRY_EXPIRY_ROOT/foo/index.sig" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_bytes(path.read_bytes()[:-1])
PY
      ;;
  esac
  if resolve_registry_app >/dev/null 2>&1; then
    echo "resolution accepted signed index case: $invalid_index_case" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  cmp "$REGISTRY_EXPIRY_CASE/lock-before-index-policy-failures" "$REGISTRY_EXPIRY_APP/elisapkg.lock" >/dev/null
  cmp "$REGISTRY_EXPIRY_CASE/state-before-index-policy-failures" "$REGISTRY_EXPIRY_STATE" >/dev/null
  cmp "$REGISTRY_EXPIRY_CASE/clock-before-index-policy-failures" "$REGISTRY_EXPIRY_STATE.clock" >/dev/null
done
write_registry_index foo 4 1.0.0,1.1.0
resolve_registry_app

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

# A valid signed but disconnected package record must not be replayed offline.
# Populate its metadata and artifact cache through a temporary manifest using a
# separate trust state, then attach its record to the foo-only lock. Closure
# validation must reject the edit before the user's trust state advances.
cp "$REGISTRY_EXPIRY_APP/elisapkg.json" "$REGISTRY_EXPIRY_CASE/foo-only.manifest"
cp "$REGISTRY_EXPIRY_APP/elisapkg.lock" "$REGISTRY_EXPIRY_CASE/foo-only.lock"
python3 - "$REGISTRY_EXPIRY_APP/elisapkg.json" <<'PY'
from pathlib import Path
import json, sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["dependencies"]["unused"] = {"version": "1.0.0", "registry": "primary"}
path.write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")
PY
(
  cd "$REGISTRY_EXPIRY_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_CASE/trust/extra-state" \
    "$BIN" resolve >/dev/null
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_CASE/trust/extra-state" \
    "$BIN" fetch >/dev/null
)
cp "$REGISTRY_EXPIRY_CASE/foo-only.manifest" "$REGISTRY_EXPIRY_APP/elisapkg.json"
python3 - "$REGISTRY_EXPIRY_APP/elisapkg.lock" "$REGISTRY_EXPIRY_CASE/foo-only.lock" <<'PY'
from pathlib import Path
import json, sys

edited_path = Path(sys.argv[1])
original = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
with_extra = json.loads(edited_path.read_text(encoding="utf-8"))
extra = next(record for record in with_extra["packages"] if record["name"] == "unused")
original["packages"].append(extra)
original["packages"].sort(key=lambda record: record["name"])
edited_path.write_text(json.dumps(original, separators=(",", ":")) + "\n", encoding="utf-8")
PY
cp "$REGISTRY_EXPIRY_STATE" "$REGISTRY_EXPIRY_CASE/trust/state.before-disconnected"
if (
  cd "$REGISTRY_EXPIRY_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_EXPIRY_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_EXPIRY_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_EXPIRY_STATE" \
    "$BIN" fetch --offline >/dev/null 2>&1
); then
  echo "offline fetch accepted a signed package disconnected from the manifest" >&2
  exit 1
else
  test "$?" -eq 3
fi
cmp "$REGISTRY_EXPIRY_CASE/trust/state.before-disconnected" "$REGISTRY_EXPIRY_STATE" >/dev/null
cp "$REGISTRY_EXPIRY_CASE/foo-only.lock" "$REGISTRY_EXPIRY_APP/elisapkg.lock"

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
write_registry_release foo 1.2.0 18446744073709551615
write_registry_index foo 5 1.0.0,1.1.0,1.2.0
cat > "$REGISTRY_EXPIRY_SNAPSHOT_PROBE" <<EOF
include "$ROOT/src/registry.elisa"
def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    metadata: mutable darray[u8] = []
    metadata.resize(1048576)
    metadata_raw: mutable u8& = (&metadata[0]).cast[mutable u8&] can Unsafe.PointerCast
    metadata_size: i64 = Platform::read_trusted_file("$REGISTRY_EXPIRY_ROOT/foo/1.2.0/metadata.json", metadata_raw, metadata.count)
    return 1 if metadata_size <= 0
    metadata.resize(metadata_size.usize())
    signature: mutable darray[u8] = []
    # The trusted-file API reserves an extra byte to detect exact-limit files.
    signature.resize(65)
    signature_raw: mutable u8& = (&signature[0]).cast[mutable u8&] can Unsafe.PointerCast
    return 2 if Platform::read_trusted_file("$REGISTRY_EXPIRY_ROOT/foo/1.2.0/metadata.sig", signature_raw, signature.count) != 64
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
