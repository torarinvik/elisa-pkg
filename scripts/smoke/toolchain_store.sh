# Sourced by scripts/test.sh after the shared smoke setup.

# `toolchain` keeps per-user records in lang/elisac of the elisapkg home,
# $HOME/.elisapkg by default. Each case runs in a subshell with a private
# HOME so the developer's own toolchains are never read or changed.
TOOLCHAIN_HOME="$TEST_TMP/toolchain-home"
mkdir -m 700 "$TOOLCHAIN_HOME"
TOOLCHAIN_STORE="$TOOLCHAIN_HOME/.elisapkg/lang/elisac"
TOOLCHAIN_SETTINGS="$TOOLCHAIN_HOME/.elisapkg/lang/settings.json"
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
  unset ELISAPKG_COMPILER ELISAPKG_HOME
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
  for directory in "$TOOLCHAIN_HOME/.elisapkg" "$TOOLCHAIN_HOME/.elisapkg/lang" "$TOOLCHAIN_STORE" "$TOOLCHAIN_STORE/dev"; do
    test "$(stat -f '%Lp' "$directory" 2>/dev/null || stat -c '%a' "$directory")" = 700
  done
  test "$(stat -f '%Lp' "$TOOLCHAIN_STORE/dev/toolchain" 2>/dev/null || stat -c '%a' "$TOOLCHAIN_STORE/dev/toolchain")" = 600
  grep -Fx "compiler=$(cd "$FAKE_CHECKOUT" && pwd -P)/scripts/elisac_stage1.sh" "$TOOLCHAIN_STORE/dev/toolchain" >/dev/null
  grep -F '"default-toolchain": "dev"' "$TOOLCHAIN_SETTINGS" >/dev/null

  # A duplicate name is refused before anything is staged in the store.
  expect_toolchain_status 7 link dev "$FAKE_CHECKOUT"
  test -z "$(find "$TOOLCHAIN_STORE" -name '*.tmp.*' -print)"

  # Names that package snapshots skip, such as build, are ordinary toolchains.
  expect_toolchain_status 0 link build "$FAKE_CHECKOUT"
  expect_toolchain_status 0 link second "$FAKE_CHECKOUT"
  if grep -F '(default)' "$TEST_TMP/toolchain.out" >/dev/null; then
    echo 'a second linked toolchain replaced the default' >&2
    exit 1
  fi
  expect_toolchain_status 0 list
  grep -F 'dev (default): linked' "$TEST_TMP/toolchain.out" >/dev/null
  grep -F 'build: linked' "$TEST_TMP/toolchain.out" >/dev/null
  grep -F 'second: linked' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 0 unlink build
  expect_toolchain_status 0 default second
  expect_toolchain_status 0 default
  grep -Fx 'second' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 7 default missing
  expect_toolchain_status 0 unlink second
  grep -F 'no default toolchain is set' "$TEST_TMP/toolchain.out" >/dev/null
  test ! -e "$TOOLCHAIN_SETTINGS"
  test ! -e "$TOOLCHAIN_STORE/second"
  expect_toolchain_status 7 unlink second
  expect_toolchain_status 0 default dev

  # doctor reports the compiler a build would use.
  HOME="$TOOLCHAIN_HOME" "$BIN" doctor | grep -F 'compiler: default toolchain dev' >/dev/null
  HOME="$TOOLCHAIN_HOME" ELISAPKG_COMPILER=/usr/bin/true "$BIN" doctor | grep -F 'ELISAPKG_COMPILER selects the compiler' >/dev/null

  # Malformed settings are an error, never an implicit "no default".
  cp "$TOOLCHAIN_SETTINGS" "$TEST_TMP/toolchain-settings.good"
  printf '{"default-toolchain": "dev", "default-toolchain": "second"}\n' > "$TOOLCHAIN_SETTINGS"
  expect_toolchain_status 7 default
  HOME="$TOOLCHAIN_HOME" "$BIN" doctor | grep -F 'settings.json in the elisapkg home is unreadable or malformed' >/dev/null
  cp "$TEST_TMP/toolchain-settings.good" "$TOOLCHAIN_SETTINGS"

  # A malformed record is listed as unreadable and never used, but can be
  # unlinked. A symlinked toolchain is never followed: it is unreadable, and
  # unlinking it removes only the link, never the record it points at.
  mkdir -m 700 "$TOOLCHAIN_STORE/broken"
  printf 'elisapkg-toolchain=1\nkind=link\ncompiler=relative\n' > "$TOOLCHAIN_STORE/broken/toolchain"
  expect_toolchain_status 0 list
  grep -F 'broken: unreadable record' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 7 default broken
  expect_toolchain_status 0 unlink broken
  test ! -e "$TOOLCHAIN_STORE/broken"
  ln -s "$TOOLCHAIN_STORE/dev" "$TOOLCHAIN_STORE/alias"
  expect_toolchain_status 0 list
  grep -F 'alias: unreadable record' "$TEST_TMP/toolchain.out" >/dev/null
  expect_toolchain_status 7 default alias
  expect_toolchain_status 0 unlink alias
  test ! -L "$TOOLCHAIN_STORE/alias"
  test -f "$TOOLCHAIN_STORE/dev/toolchain"

  # ELISAPKG_HOME moves the whole store; it must be absolute.
  ELISAPKG_HOME="$TOOLCHAIN_HOME/elsewhere" expect_toolchain_status 0 link moved "$FAKE_CHECKOUT"
  test -f "$TOOLCHAIN_HOME/elsewhere/lang/elisac/moved/toolchain"
  test ! -e "$TOOLCHAIN_STORE/moved"
  ELISAPKG_HOME=relative/home expect_toolchain_status 5 list

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
