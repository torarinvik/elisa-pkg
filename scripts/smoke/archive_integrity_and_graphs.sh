# Sourced by scripts/test.sh after the shared smoke setup.

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
ARCHIVE_EXTRACT_PUBLIC_DIR="$TEST_TMP/archive-extract-public-$$"
ARCHIVE_TRAVERSAL_ESCAPE="$TEST_TMP/outside"
mkdir -m 700 "$ARCHIVE_EXTRACT_DIR"
mkdir -m 700 "$ARCHIVE_EXTRACT_DIR-partial"
mkdir -m 700 "$ARCHIVE_EXTRACT_DIR-end"
mkdir -m 700 "$ARCHIVE_EXTRACT_512_DIR"
mkdir -m 700 "$ARCHIVE_EXTRACT_LIMIT_DIR"
mkdir -m 700 "$ARCHIVE_EXTRACT_TRAVERSAL_DIR"
mkdir -m 700 "$ARCHIVE_EXTRACT_COLLISION_DIR"
mkdir -m 700 "$ARCHIVE_EXTRACT_PUBLIC_DIR"
chmod 777 "$ARCHIVE_EXTRACT_PUBLIC_DIR"
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
    public_destination: mutable darray[u8] = []
    append_text(&public_destination, "$ARCHIVE_EXTRACT_PUBLIC_DIR")
    return 16 if Archive::extract_ustar_archive(valid, public_destination)
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
test -z "$(find "$ARCHIVE_EXTRACT_PUBLIC_DIR" -mindepth 1 -print -quit)"
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

  # Authenticated or cached registry artifacts are fetchable, but the compiler
  # must never receive a v3 registry graph until dependency build integration
  # is implemented. Use a marker compiler to prove the CLI rejects it first.
  registry_compiler_marker="$TEST_TMP/registry-compiler-was-invoked-$$"
  registry_compiler="$TEST_TMP/registry-compiler-marker-$$.sh"
  registry_build_log="$TEST_TMP/registry-build-rejection-$$.log"
  cat > "$registry_compiler" <<EOF
#!/bin/sh
: > "$registry_compiler_marker"
exit 99
EOF
  chmod 700 "$registry_compiler"
  if env -u ELISAPKG_REGISTRY_DIR -u ELISAPKG_TRUST_STATE \
    ELISAPKG_COMPILER="$registry_compiler" "$BIN" build --frozen > "$registry_build_log" 2>&1; then
    echo "build unexpectedly accepted a registry dependency graph" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  if ! grep -F -e 'builds with registry dependencies are not supported' \
    -e 'compiler builds require the macOS Seatbelt sandbox' "$registry_build_log" >/dev/null; then
    echo "registry build did not fail for the dependency or sandbox policy reason" >&2
    exit 1
  fi
  if [[ -e "$registry_compiler_marker" ]]; then
    echo "compiler was invoked for a registry dependency graph" >&2
    exit 1
  fi
)
