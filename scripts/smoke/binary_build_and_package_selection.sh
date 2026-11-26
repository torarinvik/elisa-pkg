# Sourced by scripts/test.sh with its smoke fixtures in scope.

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
