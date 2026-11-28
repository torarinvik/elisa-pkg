# Sourced by scripts/test.sh after the shared smoke setup.

# `toolchain` keeps per-user records under $HOME/.local/share/elisapkg. Each
# case runs in a subshell with a private HOME so the developer's own
# toolchains are never read or changed.
TOOLCHAIN_HOME="$TEST_TMP/toolchain-home"
mkdir -m 700 "$TOOLCHAIN_HOME"
TOOLCHAIN_STORE="$TOOLCHAIN_HOME/.local/share/elisapkg/toolchains"
FAKE_CHECKOUT="$TEST_TMP/fake-compiler-checkout"
mkdir -p "$FAKE_CHECKOUT/scripts" "$FAKE_CHECKOUT/bin" "$FAKE_CHECKOUT/build/runtime"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CHECKOUT/scripts/elisac_stage1.sh"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CHECKOUT/bin/elisac-stage1"
chmod 755 "$FAKE_CHECKOUT/scripts/elisac_stage1.sh" "$FAKE_CHECKOUT/bin/elisac-stage1"
: > "$FAKE_CHECKOUT/build/runtime/elisacore_runtime.o"

expect_toolchain_status() {
  local expected="$1"
  shift
  if HOME="$TOOLCHAIN_HOME" "$BIN" toolchain "$@" >"$TEST_TMP/toolchain.out" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "toolchain $* exited $actual, expected $expected:" >&2
    cat "$TEST_TMP/toolchain.out" >&2
    exit 1
  fi
}

(
  unset ELISAPKG_COMPILER
  expect_toolchain_status 0 list
  grep -F 'no toolchains' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 0 default
  grep -Fx 'no default toolchain' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 2
  expect_toolchain_status 2 link Upper "$FAKE_CHECKOUT"
  expect_toolchain_status 2 link -dash "$FAKE_CHECKOUT"
  expect_toolchain_status 2 link dev "$TEST_TMP/no-such-checkout"
  expect_toolchain_status 2 link dev "$TEST_TMP"

  # The first link becomes the default; the store is private to the user.
  expect_toolchain_status 0 link dev "$FAKE_CHECKOUT"
  grep -F '(default)' "$TEST_TMP/toolchain.out" >/dev/null
  test "$(stat -f '%Lp' "$TOOLCHAIN_STORE" 2>/dev/null || stat -c '%a' "$TOOLCHAIN_STORE")" = 700
  test "$(stat -f '%Lp' "$TOOLCHAIN_STORE/dev.toolchain" 2>/dev/null || stat -c '%a' "$TOOLCHAIN_STORE/dev.toolchain")" = 600
  grep -Fx "compiler=$(cd "$FAKE_CHECKOUT" && pwd -P)/scripts/elisac_stage1.sh" "$TOOLCHAIN_STORE/dev.toolchain" >/dev/null

  # A duplicate name is refused before anything is staged in the store.
  expect_toolchain_status 7 link dev "$FAKE_CHECKOUT"
  test -z "$(find "$TOOLCHAIN_STORE" -name '*.tmp.*' -print)"

  expect_toolchain_status 0 link second "$FAKE_CHECKOUT"
  if grep -F '(default)' "$TEST_TMP/toolchain.out" >/dev/null; then
    echo 'a second linked toolchain replaced the default' >&2
    exit 1
  fi
  expect_toolchain_status 0 list
  grep -F 'dev (default): linked' "$TEST_TMP/toolchain.out" >/dev/null
  grep -F 'second: linked' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 0 default second
  expect_toolchain_status 0 default
  grep -Fx 'second' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 7 default missing
  expect_toolchain_status 0 unlink second
  grep -F 'no default toolchain is set' "$TEST_TMP/toolchain.out" >/dev/null
  test ! -e "$TOOLCHAIN_STORE/default"
  expect_toolchain_status 7 unlink second
  expect_toolchain_status 0 default dev

  # doctor reports the compiler a build would use.
  HOME="$TOOLCHAIN_HOME" "$BIN" doctor | grep -F 'compiler: default toolchain dev' >/dev/null
  HOME="$TOOLCHAIN_HOME" ELISAPKG_COMPILER=/usr/bin/true "$BIN" doctor | grep -F 'ELISAPKG_COMPILER selects the compiler' >/dev/null

  # A malformed record is listed as unreadable and never used, but can be
  # unlinked. A symlink in the store makes listing fail closed and is never
  # followed as a record.
  printf 'elisapkg-toolchain=1\nkind=link\ncompiler=relative\n' > "$TOOLCHAIN_STORE/broken.toolchain"
  expect_toolchain_status 0 list
  grep -F 'broken: unreadable record' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 7 default broken
  expect_toolchain_status 0 unlink broken
  ln -s "$TOOLCHAIN_STORE/dev.toolchain" "$TOOLCHAIN_STORE/alias.toolchain"
  expect_toolchain_status 7 list
  expect_toolchain_status 7 default alias
  rm "$TOOLCHAIN_STORE/alias.toolchain"

  # Another user's write access makes the whole store untrusted.
  chmod 770 "$TOOLCHAIN_STORE"
  expect_toolchain_status 5 list
  expect_toolchain_status 5 link third "$FAKE_CHECKOUT"
  chmod 700 "$TOOLCHAIN_STORE"
  expect_toolchain_status 0 list
)

# With a real compiler, a build needs no compiler environment variables once
# a toolchain is the default.
if [[ -n "${ELISA_COMPILER_ROOT:-}" ]]; then
  TOOLCHAIN_BUILD_HOME="$TEST_TMP/toolchain-build-home"
  mkdir -m 700 "$TOOLCHAIN_BUILD_HOME"
  TOOLCHAIN_PROJECT="$TEST_TMP/toolchain-build-project"
  "$BIN" init "$TOOLCHAIN_PROJECT" >/dev/null
  (
    unset ELISAPKG_COMPILER ELISA_STAGE1_BIN ELISA_RUNTIME_OBJ
    export HOME="$TOOLCHAIN_BUILD_HOME"
    cd "$TOOLCHAIN_PROJECT"
    "$BIN" toolchain link real "$ELISA_COMPILER_ROOT" >/dev/null
    "$BIN" build >"$TEST_TMP/toolchain-build.log" 2>&1
    test -x .elisapkg/build/app
    if ELISA_STAGE1_BIN="$ELISA_COMPILER_ROOT/bin/elisac-stage1" "$BIN" build >"$TEST_TMP/toolchain-conflict.log" 2>&1; then
      echo 'a build mixed the default toolchain with ELISA_STAGE1_BIN' >&2
      exit 1
    else
      test "$?" -eq 6
    fi
    grep -F 'apply only with ELISAPKG_COMPILER' "$TEST_TMP/toolchain-conflict.log" >/dev/null
  )
fi
