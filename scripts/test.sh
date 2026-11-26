#!/usr/bin/env bash
set -euo pipefail
# Fixtures that the application consumes must have a predictable, non-shared
# writable mode even on hosts whose default umask is group-friendly (for
# example 0002). The package path policy intentionally rejects group-writable
# source roots.
umask 022

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
  export ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}"
fi
export ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}"
"$BIN" --version | grep -F 'elisapkg 0.1.0' >/dev/null
"$BIN" doctor | grep -F 'fixed trusted local OpenSSL candidate' >/dev/null
python3 "$ROOT/scripts/ffi_boundary_test.py"
python3 "$ROOT/scripts/security/tuf_policy_regression.py"
python3 "$ROOT/scripts/security/linux_acl_regression.py"
python3 "$ROOT/scripts/macos_toolchain_path_regression.py"
python3 "$ROOT/scripts/security/collect_files_budget_regression.py"
python3 "$ROOT/scripts/build_include_regression.py"
python3 "$ROOT/scripts/build_provenance_regression.py"
python3 "$ROOT/scripts/local_dependency_build_regression.py"
python3 "$ROOT/scripts/security/package_path_policy_regression.py"
python3 "$ROOT/scripts/security/ffi_fifo_regression.py"
python3 "$ROOT/scripts/security/ffi_source_open_regression.py"
python3 "$ROOT/scripts/security/access_regression.py"
python3 "$ROOT/scripts/security/crypto_provider_trust_regression.py"
python3 "$ROOT/scripts/security/inherited_fd_regression.py"
python3 "$ROOT/scripts/security/process_group_regression.py"
python3 "$ROOT/scripts/security/install_lock_regression.py"
python3 "$ROOT/scripts/security/install_transaction_regression.py"
python3 "$ROOT/scripts/security/install_killpoint_regression.py"
python3 "$ROOT/scripts/security/install_identity_regression.py"
python3 "$ROOT/scripts/transaction_guard_regression.py"
python3 "$ROOT/scripts/sandbox_policy_test.py"
python3 "$ROOT/scripts/security/archive_extract_regression.py"
python3 "$ROOT/scripts/security/index_generation_race_regression.py"
python3 "$ROOT/scripts/security/trust_state_registry_isolation_regression.py"

source "$ROOT/scripts/smoke/cli_output_and_source_policy.sh"

source "$ROOT/scripts/smoke/resolution_and_signatures.sh"

source "$ROOT/scripts/smoke/registry_trust_roots.sh"

source "$ROOT/scripts/smoke/registry_expiry_and_offline.sh"
source "$ROOT/scripts/smoke/registry_selection_and_path_security.sh"
source "$ROOT/scripts/smoke/registry_trust_state.sh"
source "$ROOT/scripts/smoke/archive_integrity_and_graphs.sh"

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
        printf '%s\n' 'module LocalUtil:' '    public:' '        def answer() -> i64:' '            return 9' > "$mutation_target"
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
  printf '%s\n' 'module LocalUtil:' '    public:' '        def answer() -> i64:' '            return NestedUtil::answer()' > local-util/src/main.elisa
  printf '%s\n' 'module NestedUtil:' '    public:' '        def answer() -> i64:' '            return 42' > nested-util/src/main.elisa
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
  printf '%s\n' 'module LocalUtil:' '    public:' '        def answer() -> i64:' '            return 1' > local-util/src/main.elisa
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
  mkdir -p BUILD TARGET src/.GIT src/.Hg src/.SVN src/.BUILD src/docs/IMPLEMENTATION_PLAN.MD
  printf '%s\n' secret > BUILD/cached-output.elisa
  printf '%s\n' secret > TARGET/stale-output.elisa
  printf '%s\n' secret > src/.GIT/config
  printf '%s\n' secret > src/.Hg/hgrc
  printf '%s\n' secret > src/.SVN/wc.db
  printf '%s\n' 'ignored plan metadata' > src/implementation_plan.MD
  printf '%s\n' 'ignored plan directory child' > src/docs/IMPLEMENTATION_PLAN.MD/child.elisa
  printf '%s\n' 'nested build-named source remains a package input' > src/.BUILD/nested-source.elisa
  "$BIN" package --list > package-files-vcs.txt
  if grep -Ei '(^|/)(\.git|\.hg|\.svn)(/|$)|(^|/)implementation_plan\.md(/|$)|^(\.elisapkg|build|target)(/|$)' package-files-vcs.txt >/dev/null; then
    echo "package listing included VCS metadata, ignored plan data, or root package state" >&2
    exit 1
  fi
  if ! grep -F 'src/.BUILD/nested-source.elisa' package-files-vcs.txt >/dev/null; then
    echo "package listing omitted a nested source directory named like package state" >&2
    exit 1
  fi
  "$BIN" resolve >/dev/null
  "$BIN" package >/dev/null
  if tar -tf .elisapkg/package.tar | grep -Ei '(^|/)(\.git|\.hg|\.svn)(/|$)|(^|/)implementation_plan\.md(/|$)|^(\.elisapkg|build|target)(/|$)' >/dev/null; then
    echo "package archive included case-varied VCS metadata, plan data, or root state" >&2
    exit 1
  fi
  if ! tar -tf .elisapkg/package.tar | grep -F 'src/.BUILD/nested-source.elisa' >/dev/null; then
    echo "package archive omitted a nested source directory named like package state" >&2
    exit 1
  fi
  rm -rf BUILD TARGET src/.GIT src/.Hg src/.SVN src/.BUILD src/docs/IMPLEMENTATION_PLAN.MD
  rm -f .git .hg .svn src/implementation_plan.MD package-files-vcs.txt
  "$BIN" resolve >/dev/null
  "$BIN" package >/dev/null
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
  if "$BIN" resolve >/dev/null 2>&1; then
    echo "resolution accepted a source symlink that the compiler could follow" >&2
    exit 1
  fi
  if "$BIN" package --list >/dev/null 2>&1; then
    echo "package listing accepted a source tree containing a symlink" >&2
    exit 1
  fi
  rm src/linked-main
  "$BIN" resolve --frozen >/dev/null
  for SOURCE_STATE_DIR in src/.elisapkg src/build src/target; do
    mkdir -p "$SOURCE_STATE_DIR"
    SOURCE_STATE_FILE="$SOURCE_STATE_DIR/fingerprinted-input.elisa"
    printf '%s\n' 'nested package source must be fingerprinted' > "$SOURCE_STATE_FILE"
    "$BIN" resolve >/dev/null
    printf '%s\n' '# input mutation probe' >> "$SOURCE_STATE_FILE"
    if "$BIN" resolve --frozen >/dev/null 2>&1; then
      echo "frozen resolution omitted nested source input under $SOURCE_STATE_DIR" >&2
      exit 1
    else
      test "$?" -eq 3
    fi
    printf '%s\n' 'nested package source must be fingerprinted' > "$SOURCE_STATE_FILE"
    "$BIN" resolve --frozen >/dev/null
  done
  rm -rf src/.elisapkg src/build src/target
  "$BIN" resolve >/dev/null
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
  publish_json_output="$TEST_TMP/publish-json-$$.out"
  publish_json_reordered_output="$TEST_TMP/publish-json-reordered-$$.out"
  "$BIN" publish --json --dry-run >"$publish_json_output"
  "$BIN" publish --dry-run --json >"$publish_json_reordered_output"
  cmp "$publish_json_output" "$publish_json_reordered_output" >/dev/null
  python3 - "$publish_json_output" "$publish_json_reordered_output" <<'PY'
import json
from pathlib import Path
import re
import sys

expected = re.compile(
    r'^\{"schema-version":1,"command":"publish","dry-run":true,"valid":true,'
    r'"source-tree-digest":"sha256:[0-9a-f]{64}","archive-size":[0-9]+,'
    r'"archive-digest":"sha256:[0-9a-f]{64}"\}$'
)
for filename in sys.argv[1:]:
    raw = Path(filename).read_bytes()
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise SystemExit("publish --json --dry-run emitted extra stdout lines")
    try:
        line = raw[:-1].decode("ascii")
        json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"publish --json --dry-run emitted invalid JSON: {error}")
    if expected.fullmatch(line) is None:
        raise SystemExit("publish --json --dry-run emitted an unexpected JSON result")
PY
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
  # A journaled manifest intent must recover both sides of the publication
  # rename: before publication the live file is original; afterward it is the
  # staged new content. Both cases roll back to the original manifest.
  cp recovered.manifest .elisapkg/transaction.manifest
  cp elisapkg.lock .elisapkg/transaction.lock
  printf '%s\n' '{}' > .elisapkg/transaction.new-manifest
  printf '%s\n' 'manifest-pending' > .elisapkg/transaction.state
  "$BIN" check-manifest >/dev/null
  cmp recovered.manifest elisapkg.json >/dev/null
  test ! -e .elisapkg/transaction.state
  cp recovered.manifest .elisapkg/transaction.manifest
  cp elisapkg.lock .elisapkg/transaction.lock
  printf '%s\n' '{}' > .elisapkg/transaction.new-manifest
  printf '%s\n' 'manifest-pending' > .elisapkg/transaction.state
  cp .elisapkg/transaction.new-manifest elisapkg.json
  "$BIN" check-manifest >/dev/null
  cmp recovered.manifest elisapkg.json >/dev/null
  test ! -e .elisapkg/transaction.state
  cp recovered.manifest .elisapkg/transaction.manifest
  cp elisapkg.lock .elisapkg/transaction.lock
  printf '%s\n' '{}' > .elisapkg/transaction.new-manifest
  printf '%s\n' 'manifest-pending' > .elisapkg/transaction.state
  printf '%s\n' '{"external":"manifest-edit"}' > elisapkg.json
  if "$BIN" check-manifest >/dev/null 2>&1; then
    echo "pending transaction recovery overwrote an external manifest edit" >&2
    exit 1
  else
    test "$?" -eq 5
  fi
  cp recovered.manifest elisapkg.json
  "$BIN" check-manifest >/dev/null
  test ! -e .elisapkg/transaction.state
  # Older journals may have already restored the original manifest but crash
  # before deleting their recovery files. Recovery must be safe to repeat.
  cp recovered.manifest .elisapkg/transaction.manifest
  cp elisapkg.lock .elisapkg/transaction.lock
  printf '%s\n' '{}' > .elisapkg/transaction.new-manifest
  printf '%s\n' 'manifest-replaced' > .elisapkg/transaction.state
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
python3 "$ROOT/scripts/cli_regression.py"
echo "elisapkg smoke tests passed"
