#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"
BIN="$ROOT/build/elisapkg"
# The Elisa binary uses this same wrapper through execvp. Keep the smoke test
# independent of whatever compiler happens to be first on the developer's PATH.
if [[ -n "${ELISA_COMPILER_ROOT:-}" ]]; then
  export ELISAPKG_COMPILER="${ELISAPKG_COMPILER:-$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh}"
  export ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}"
fi
export ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}"
"$BIN" --version | grep -F 'elisapkg 0.1.0' >/dev/null
"$BIN" doctor | grep -F 'remote metadata signatures: unavailable' >/dev/null

# Exercise the pure SemVer requirement module independently of the CLI. This
# keeps parser/range regressions visible without requiring a registry fixture.
SEMVER_PROBE="$ROOT/build/semver-probe-$$.elisa"
SEMVER_BIN="$ROOT/build/semver-probe-$$"
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
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$SEMVER_BIN" "$SEMVER_PROBE"
"$SEMVER_BIN"

# The resolver primitive has no network/provider dependency. Verify highest
# satisfying selection, prerelease ordering, and fail-closed catalog parsing.
RESOLVE_PROBE="$ROOT/build/resolve-probe-$$.elisa"
RESOLVE_BIN="$ROOT/build/resolve-probe-$$"
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
TRUST_PROBE="$ROOT/build/trust-probe-$$.elisa"
TRUST_BIN="$ROOT/build/trust-probe-$$"
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

# Verify the in-language SHA-256 implementation against the two canonical
# FIPS vectors used by the package-integrity path.
HASH_PROBE="$ROOT/build/hash-probe-$$.elisa"
HASH_BIN="$ROOT/build/hash-probe-$$"
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
ARCHIVE_PROBE="$ROOT/build/archive-probe-$$.elisa"
ARCHIVE_BIN="$ROOT/build/archive-probe-$$"
cat > "$ARCHIVE_PROBE" <<EOF
include "$ROOT/src/archive.elisa"

def append_bytes(out: mutable darray[u8]&, value: darray[u8]&) -> void:
    for index in 0..<value.count |out, value|:
        out.push(value[index])

def append_zeroes(out: mutable darray[u8]&, count: usize) -> void:
    for _index in 0..<count |out|:
        out.push(0)

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
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$ARCHIVE_BIN" "$ARCHIVE_PROBE"
"$ARCHIVE_BIN"

CASE="$ROOT/build/test-package-$(date +%s%N)"
mkdir -p "$CASE"
(
  cd "$CASE"
  "$BIN" init . >/dev/null
  "$BIN" check-manifest --manifest-path "$CASE/elisapkg.json" >/dev/null
  mkdir -p local-util/src nested-util/src
  printf '%s\n' 'def main() -> i64:' '    return 0' > local-util/src/main.elisa
  printf '%s\n' 'def main() -> i64:' '    return 0' > nested-util/src/main.elisa
  printf '%s\n' '{"schema-version":1,"package":{"name":"nested-util","version":"0.4.0"},"targets":[{"name":"nested-util","kind":"lib","entry":"src/main.elisa"}],"dependencies":{}}' > nested-util/elisapkg.json
  printf '%s\n' '{"schema-version":1,"package":{"name":"local-util","version":"1.2.3"},"targets":[{"name":"local-util","kind":"lib","entry":"src/main.elisa"}],"dependencies":{"nested-util":{"path":"../nested-util"}}}' > local-util/elisapkg.json
  "$BIN" add local-util --path local-util >/dev/null
  "$BIN" check-manifest >/dev/null
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
  TOOLCHAIN_WRAPPER="$CASE/compiler-wrapper.sh"
  printf '%s\n' '#!/bin/sh' "exec '$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh' \"\$@\"" > "$TOOLCHAIN_WRAPPER"
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
  printf '%s\n' '# content mutation must invalidate the receipt' >> "$TOOLCHAIN_WRAPPER"
  wrapper_mutated_output="$(ELISAPKG_COMPILER="$TOOLCHAIN_WRAPPER" "$BIN" build)"
  case "$wrapper_mutated_output" in
    *"(cached)"*)
      echo "mutated compiler wrapper was accepted from the cache" >&2
      exit 1
      ;;
  esac
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
  "$BIN" package --list >/dev/null
  "$BIN" package >/dev/null
  cp .elisapkg/package.tar package.tar.good
  cp .elisapkg/package.receipt package.receipt.good
  test -s .elisapkg/package.receipt
  "$BIN" cache verify | grep -F 'package archive and receipt verified' >/dev/null
  PACKAGE_BLOB="$(find .elisapkg/cache/sha256 -type f | head -n 1)"
  test -n "$PACKAGE_BLOB"
  printf '%s' junk >> "$PACKAGE_BLOB"
  if "$BIN" cache verify >/dev/null 2>&1; then
    echo "cache verification accepted a corrupted content-addressed blob" >&2
    exit 1
  fi
  "$BIN" package >/dev/null
  test -n "$(find .elisapkg/cache/quarantine -type f | head -n 1)"
  cmp package.tar.good .elisapkg/package.tar >/dev/null
  cmp package.receipt.good .elisapkg/package.receipt >/dev/null
  tar -tf .elisapkg/package.tar | grep -F 'elisapkg.json' >/dev/null
  if tar -tf .elisapkg/package.tar | grep -E 'IMPLEMENTATION_PLAN|\.elisapkg/|\.env|\.pem|\.key' >/dev/null; then
    echo "package archive included a forbidden path" >&2
    exit 1
  fi
  printf '%s' secret > src/.env
  printf '%s' secret > src/private.pem
  "$BIN" package >/dev/null
  if tar -tf .elisapkg/package.tar | grep -E 'src/\.env|src/private\.pem' >/dev/null; then
    echo "package archive included a credential-like file" >&2
    exit 1
  fi
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
for name in ("src/.env", "src/private.pem"):
    Path(name).unlink()
PY
  PREFIX="$CASE/local-prefix"
  if ELISAPKG_INSTALL_PREFIX="$CASE/local-prefix/../escape" "$BIN" install --local >/dev/null 2>&1; then
    echo "path traversal install prefix was accepted" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
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
  ELISAPKG_INSTALL_PREFIX="$PREFIX" "$BIN" uninstall --local app >/dev/null
  test ! -e "$PREFIX/bin/app"
  PROBE="$CASE/compiler-env-probe.sh"
  DUMP="$CASE/compiler-env.dump"
  printf '%s\n' '#!/bin/sh' "/usr/bin/env > '$DUMP'" 'exit 127' > "$PROBE"
  chmod +x "$PROBE"
  if ELISAPKG_COMPILER="$PROBE" ELISAPKG_SECRET=should_not_cross "$BIN" build >/dev/null 2>&1; then
    echo "compiler probe unexpectedly succeeded" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  if grep -F 'ELISAPKG_SECRET=should_not_cross' "$DUMP" >/dev/null 2>&1; then
    echo "compiler child inherited a parent secret" >&2
    exit 1
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
  "$BIN" publish >/dev/null 2>&1 && exit 1 || test "$?" -eq 5
  "$BIN" install app >/dev/null 2>&1 && exit 1 || test "$?" -eq 5
  "$BIN" fetch --offline >/dev/null
  test -f .elisapkg/build/app
  "$BIN" clean >/dev/null
  test ! -e .elisapkg/build/app
  mkdir -p .elisapkg
  cp elisapkg.json .elisapkg/transaction.manifest
  cp elisapkg.json recovered.manifest
  printf '%s\n' 'prepared-no-lock' > .elisapkg/transaction.state
  printf '%s\n' '{}' > elisapkg.json
  "$BIN" check-manifest >/dev/null
  cmp recovered.manifest elisapkg.json >/dev/null
  test ! -e .elisapkg/transaction.state
  cp recovered.manifest .elisapkg/transaction.manifest
  printf '%s\n' 'manifest-replaced' > .elisapkg/transaction.state
  printf '%s\n' '{}' > elisapkg.json
  "$BIN" check-manifest >/dev/null
  cmp recovered.manifest elisapkg.json >/dev/null
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

BAD="$ROOT/build/invalid-package"
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
OUTSIDE="$ROOT/build/invalid-target-outside-$$"
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
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":"primary"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unsupported registry dependency was accepted" >&2
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

CYCLE="$ROOT/build/cycle-package-$$"
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
