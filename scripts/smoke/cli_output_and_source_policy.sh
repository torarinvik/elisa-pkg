# Sourced by scripts/test.sh after the shared smoke setup.

# Global output modes are strict: quiet suppresses human success text without
# hiding JSON results, and color values are validated even though the current
# renderer intentionally emits no ANSI escapes.
QUIET_FIXTURE="$TEST_TMP/quiet-fixture-$$"
mkdir "$QUIET_FIXTURE"
"$BIN" init "$QUIET_FIXTURE" >/dev/null
INIT_MODE_FIXTURE="$TEST_TMP/init-output-modes-$$"
init_quiet_output="$("$BIN" init "$INIT_MODE_FIXTURE" --quiet 2>/dev/null)"
test -z "$init_quiet_output"
if "$BIN" init "$TEST_TMP/init-color-invalid-$$" --color invalid >/dev/null 2>&1; then
  echo 'init accepted an invalid color mode' >&2
  exit 1
else
  test "$?" -eq 2
fi
quiet_output="$(cd "$QUIET_FIXTURE" && "$BIN" check-manifest --quiet 2>/dev/null)"
test -z "$quiet_output"
(
  cd "$QUIET_FIXTURE"
  "$BIN" resolve >/dev/null
)
quiet_tree="$(cd "$QUIET_FIXTURE" && "$BIN" tree --quiet 2>/dev/null)"
test -z "$quiet_tree"
(
  cd "$QUIET_FIXTURE"
  "$BIN" check-manifest --color always >/dev/null
  "$BIN" check-manifest --color never >/dev/null
)
if (cd "$QUIET_FIXTURE" && "$BIN" check-manifest --color invalid >/dev/null 2>&1); then
  echo 'invalid color mode was accepted' >&2
  exit 1
fi
json_quiet="$(cd "$QUIET_FIXTURE" && "$BIN" check-manifest --json --quiet)"
test "$json_quiet" = '{"schema-version":1,"valid":true,"manifest":"elisapkg.json"}'

# Credential filtering is relative to the package root. A checkout nested under
# a credential-store directory must still fingerprint its own source files.
ANCESTOR_FIXTURE="$TEST_TMP/.config/gcloud/ordinary-package"
mkdir -p "$TEST_TMP/.config/gcloud"
"$BIN" init "$ANCESTOR_FIXTURE" >/dev/null
(
  cd "$ANCESTOR_FIXTURE"
  "$BIN" resolve >/dev/null
  cp src/main.elisa "$TEST_TMP/ancestor-project-main.good"
  printf '%s\n' '# source identity must include this package file' >> src/main.elisa
  if "$BIN" resolve --frozen >/dev/null 2>&1; then
    echo "source under a credential-named ancestor was omitted from the lock digest" >&2
    exit 1
  else
    test "$?" -eq 3
  fi
  cp "$TEST_TMP/ancestor-project-main.good" src/main.elisa
  "$BIN" resolve --frozen >/dev/null
)

# If the package root itself is a credential-store directory, its children
# have ordinary relative names. Resolution must reject that root explicitly.
for CREDENTIAL_ROOT in "$TEST_TMP/.docker" "$TEST_TMP/.config" "$TEST_TMP/.config/gh"; do
  "$BIN" init "$CREDENTIAL_ROOT" >/dev/null
  if (cd "$CREDENTIAL_ROOT" && "$BIN" resolve >/dev/null 2>&1); then
    echo "resolution accepted a package rooted in a credential store: $CREDENTIAL_ROOT" >&2
    exit 1
  fi
done
