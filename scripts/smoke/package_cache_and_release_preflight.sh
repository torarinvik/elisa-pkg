# Sourced by scripts/test.sh with its smoke fixtures in scope.

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
