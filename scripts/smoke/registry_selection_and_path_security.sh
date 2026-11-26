# Sourced by scripts/test.sh after the shared smoke setup.

# A previous lock choice must remain a soft preference. If an older candidate
# has a dependency that the newly selected candidate no longer has, resolution
# must not retain that old dependency as a disconnected package record.
REGISTRY_GRAPH_CASE="$TEST_TMP/registry-graph-preference-regression"
REGISTRY_GRAPH_ROOT="$REGISTRY_GRAPH_CASE/registry"
REGISTRY_GRAPH_KEY="$REGISTRY_GRAPH_CASE/trust/key"
REGISTRY_GRAPH_PRIVATE="$REGISTRY_GRAPH_CASE/test-private.pem"
REGISTRY_GRAPH_SOURCE="$REGISTRY_GRAPH_CASE/archive-source"
REGISTRY_GRAPH_APP="$REGISTRY_GRAPH_CASE/app"
REGISTRY_GRAPH_STATE="$REGISTRY_GRAPH_CASE/trust/state"
mkdir -m 700 -p "$REGISTRY_GRAPH_ROOT" "$REGISTRY_GRAPH_CASE/trust"
cp "$REGISTRY_EXPIRY_PRIVATE" "$REGISTRY_GRAPH_PRIVATE"
cp "$REGISTRY_EXPIRY_KEY" "$REGISTRY_GRAPH_KEY"
chmod 600 "$REGISTRY_GRAPH_PRIVATE" "$REGISTRY_GRAPH_KEY"
"$BIN" init "$REGISTRY_GRAPH_SOURCE" >/dev/null
(
  cd "$REGISTRY_GRAPH_SOURCE"
  "$BIN" resolve >/dev/null
  "$BIN" package >/dev/null
)
python3 - "$REGISTRY_GRAPH_ROOT" "$REGISTRY_GRAPH_SOURCE/.elisapkg/package.tar" "$REGISTRY_GRAPH_PRIVATE" "$OPENSSL_BIN" <<'PY'
from pathlib import Path
import hashlib, io, json, subprocess, sys, tarfile, time

root = Path(sys.argv[1])
archive_template = Path(sys.argv[2]).read_bytes()
private_key = sys.argv[3]
openssl = sys.argv[4]
expires = int(time.time()) + 3600

def release_archive(package, version, dependencies):
    output = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(archive_template)) as original:
        with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as updated:
            for entry in original:
                content = original.extractfile(entry).read()
                if entry.name == "elisapkg.json":
                    manifest = json.loads(content)
                    manifest["package"].update(name=package, version=version)
                    manifest["dependencies"] = dependencies
                    content = (json.dumps(manifest) + "\n").encode()
                    entry.size = len(content)
                updated.addfile(entry, io.BytesIO(content))
            end = updated.offset
    return output.getvalue()[:end + 1024]

def write_signed(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(0o600)
    signature = path.with_name("metadata.sig" if path.name == "metadata.json" else "index.sig")
    subprocess.run([openssl, "pkeyutl", "-sign", "-rawin", "-inkey", private_key,
                    "-in", str(path), "-out", str(signature)], check=True)
    signature.chmod(0o600)

for package, version, dependencies in (
        ("foo", "1.0.0", {"bar": {"registry": "primary", "version": "^1.0.0"}}),
        ("foo", "2.0.0", {}),
        ("foo", "2.1.0", {}),
        ("bar", "1.0.0", {})):
    version_dir = root / package / version
    version_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    version_dir.chmod(0o700)
    archive = release_archive(package, version, dependencies)
    (version_dir / "archive.tar").write_bytes(archive)
    (version_dir / "archive.tar").chmod(0o600)
    metadata = {
        "schema-version": 1,
        "algorithm": "ed25519",
        "registry": str(root),
        "package": package,
        "version": version,
        "archive": "archive.tar",
        "archive-size": len(archive),
        "archive-digest": hashlib.sha256(archive).hexdigest(),
        "expires": expires,
    }
    if dependencies:
        metadata["dependencies"] = dependencies
    metadata_path = version_dir / "metadata.json"
    write_signed(metadata_path, (json.dumps(metadata, separators=(",", ":")) + "\n").encode())

for package, versions in (("foo", ("1.0.0", "2.0.0")), ("bar", ("1.0.0",))):
    index = (
        "elisapkg-index:1\n"
        f"registry:{root}\n"
        f"package:{package}\n"
        "generation:1\n"
        f"expires:{expires}\n"
        "versions:\n"
        + "".join(f"{version}\n" for version in versions)
    ).encode("ascii")
    write_signed(root / package / "index", index)
PY
"$BIN" init "$REGISTRY_GRAPH_APP" >/dev/null
python3 - "$REGISTRY_GRAPH_APP/elisapkg.json" <<'PY'
from pathlib import Path
import json, sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["dependencies"] = {"foo": {"version": "^1.0.0", "registry": "primary"}}
path.write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")
PY
(
  cd "$REGISTRY_GRAPH_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_GRAPH_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_GRAPH_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_GRAPH_STATE" \
    "$BIN" resolve >/dev/null
)
python3 - "$REGISTRY_GRAPH_APP/elisapkg.lock" <<'PY'
from pathlib import Path
import json, sys

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selected = {record["name"]: record["version"] for record in lock["packages"]}
if selected != {"bar": "1.0.0", "foo": "1.0.0"}:
    raise SystemExit(f"initial dependency graph was not locked: {selected!r}")
PY
(
  cd "$REGISTRY_GRAPH_APP"
  export ELISAPKG_REGISTRY_DIR="$REGISTRY_GRAPH_ROOT"
  export ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_GRAPH_KEY"
  export ELISAPKG_TRUST_STATE="$REGISTRY_GRAPH_STATE"
  "$BIN" fetch --locked >/dev/null
  # Retain the configured registry identity, but make its releases unavailable.
  mv "$REGISTRY_GRAPH_ROOT/foo" "$REGISTRY_GRAPH_CASE/unavailable-foo"
  mv "$REGISTRY_GRAPH_ROOT/bar" "$REGISTRY_GRAPH_CASE/unavailable-bar"
  "$BIN" fetch --offline > "$REGISTRY_GRAPH_CASE/offline.stdout"
  python3 - "$BIN" "$REGISTRY_GRAPH_STATE.clock" <<'PY'
from pathlib import Path
import json, subprocess, sys

lock = json.loads(Path("elisapkg.lock").read_text())
first = lock["packages"][0]
assert first["name"] == "bar"
digest = first["archive-digest"].removeprefix("sha256:")
blob = Path(".elisapkg/cache/sha256") / digest[:2] / digest
clock = Path(sys.argv[2])
clock_before = (clock.stat().st_ino, clock.read_bytes())
hidden = blob.with_suffix(".temporarily-unavailable")
blob.rename(hidden)
try:
    result = subprocess.run([sys.argv[1], "fetch", "--offline"], capture_output=True, timeout=30)
    assert result.returncode == 5, result
    assert b"could not verify cached archive for bar 1.0.0" in result.stderr, result
    assert (clock.stat().st_ino, clock.read_bytes()) == clock_before
finally:
    hidden.rename(blob)
PY
  mv "$REGISTRY_GRAPH_CASE/unavailable-foo" "$REGISTRY_GRAPH_ROOT/foo"
  mv "$REGISTRY_GRAPH_CASE/unavailable-bar" "$REGISTRY_GRAPH_ROOT/bar"
)
grep -F 'verified cached registry artifact bar 1.0.0' "$REGISTRY_GRAPH_CASE/offline.stdout" >/dev/null
grep -F 'verified cached registry artifact foo 1.0.0' "$REGISTRY_GRAPH_CASE/offline.stdout" >/dev/null
python3 - "$REGISTRY_GRAPH_APP/elisapkg.json" <<'PY'
from pathlib import Path
import json, sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["dependencies"]["foo"]["version"] = "^2.0.0"
path.write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")
PY
(
  cd "$REGISTRY_GRAPH_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_GRAPH_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_GRAPH_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_GRAPH_STATE" \
    "$BIN" resolve >/dev/null
  ELISAPKG_REGISTRY_DIR="$REGISTRY_GRAPH_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_GRAPH_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_GRAPH_STATE" \
    "$BIN" fetch >/dev/null
)
python3 - "$REGISTRY_GRAPH_APP/elisapkg.lock" <<'PY'
from pathlib import Path
import json, sys

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selected = {record["name"]: record["version"] for record in lock["packages"]}
if selected != {"foo": "2.0.0"}:
    raise SystemExit(f"stale lock preference added unreachable packages: {selected!r}")
PY
python3 - "$REGISTRY_GRAPH_ROOT" "$REGISTRY_GRAPH_PRIVATE" "$OPENSSL_BIN" <<'PY'
from pathlib import Path
import subprocess, sys, time

root = Path(sys.argv[1])
private_key = sys.argv[2]
openssl = sys.argv[3]
expires = int(time.time()) + 3600
payload = (
    "elisapkg-index:1\n"
    f"registry:{root}\n"
    "package:foo\n"
    "generation:2\n"
    f"expires:{expires}\n"
    "versions:\n"
    "1.0.0\n"
    "2.0.0\n"
    "2.1.0\n"
    "yanked:\n"
    "2.0.0\n"
).encode("ascii")
index = root / "foo" / "index"
index.write_bytes(payload)
index.chmod(0o600)
signature = index.with_name("index.sig")
subprocess.run([openssl, "pkeyutl", "-sign", "-rawin", "-inkey", private_key,
                "-in", str(index), "-out", str(signature)], check=True)
signature.chmod(0o600)
PY
(
  cd "$REGISTRY_GRAPH_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_GRAPH_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_GRAPH_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_GRAPH_STATE" \
    "$BIN" resolve >/dev/null 2>"$TEST_TMP/locked-yanked-warning.err"
)
grep -F "warning: retaining locked yanked release foo@2.0.0" "$TEST_TMP/locked-yanked-warning.err" >/dev/null
python3 - "$REGISTRY_GRAPH_APP/elisapkg.lock" <<'PY'
from pathlib import Path
import json, sys

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selected = {record["name"]: record["version"] for record in lock["packages"]}
if selected != {"foo": "2.0.0"}:
    raise SystemExit(f"normal resolution did not retain the exact locked yank: {selected!r}")
PY
(
  cd "$REGISTRY_GRAPH_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_GRAPH_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_GRAPH_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_GRAPH_STATE" \
    "$BIN" update foo >/dev/null
)
python3 - "$REGISTRY_GRAPH_APP/elisapkg.lock" <<'PY'
from pathlib import Path
import json, sys

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selected = {record["name"]: record["version"] for record in lock["packages"]}
if selected != {"foo": "2.1.0"}:
    raise SystemExit(f"explicit update did not move to an unyanked release: {selected!r}")
PY
REGISTRY_YANKED_APP="$REGISTRY_GRAPH_CASE/fresh-exact-yanked"
"$BIN" init "$REGISTRY_YANKED_APP" >/dev/null
python3 - "$REGISTRY_YANKED_APP/elisapkg.json" <<'PY'
from pathlib import Path
import json, sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["dependencies"] = {"foo": {"version": "2.0.0", "registry": "primary"}}
path.write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")
PY
if (
  cd "$REGISTRY_YANKED_APP"
  ELISAPKG_REGISTRY_DIR="$REGISTRY_GRAPH_ROOT" \
  ELISAPKG_REGISTRY_TRUST_ROOT="$REGISTRY_GRAPH_KEY" \
  ELISAPKG_TRUST_STATE="$REGISTRY_GRAPH_CASE/fresh-trust-state" \
    "$BIN" resolve >/dev/null 2>&1
); then
  echo "fresh resolution selected an exact yanked release" >&2
  exit 1
else
  # A soft yank removes the candidate from this graph; it is not a security
  # revocation, so the resolver reports an unsatisfiable dependency graph.
  test "$?" -eq 3
fi
test ! -e "$REGISTRY_YANKED_APP/elisapkg.lock"
echo "registry lock and signed yank regressions passed"

# A writable package directory must be rejected as a security failure before
# it can replace a signed snapshot or its detached signature.
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
