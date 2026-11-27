#!/usr/bin/env bash
set -euo pipefail

lint_flags=()
case "${1:-}" in
  "") ;;
  --strict|--check) lint_flags=(-Wnever-leak=strict) ;;
  *) echo "usage: scripts/build.sh [--strict|--check]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "usage: scripts/build.sh [--strict|--check]" >&2
  exit 2
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-}"
if [[ -z "$COMPILER_ROOT" ]]; then
  echo "error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout" >&2
  exit 2
fi
COMPILER_ROOT="$(cd -- "$COMPILER_ROOT" && pwd)"
STAGE1="${ELISA_STAGE1_BIN:-$COMPILER_ROOT/bin/elisac-stage1}"
WRAPPER="${ELISA_COMPILER_WRAPPER:-$COMPILER_ROOT/scripts/elisac_stage1.sh}"
RUNTIME="${ELISA_RUNTIME_OBJ:-$COMPILER_ROOT/build/runtime/elisacore_runtime.o}"
OUT="$ROOT/build/elisapkg"
if [[ ${1:-} == --strict ]]; then
  OUT="$ROOT/build/elisapkg-strict"
fi
if [[ ! -x "$WRAPPER" ]]; then
  echo "error: compiler wrapper is not executable: $WRAPPER" >&2
  exit 2
fi
if [[ ! -x "$STAGE1" ]]; then
  echo "error: stage1 compiler is not executable: $STAGE1" >&2
  echo "note: seed the compiler first or set ELISA_STAGE1_BIN" >&2
  exit 2
fi
# Lint the full include graph without invoking code generation or the linker.
# Strict never-leak findings are errors here, so any new finding fails the check.
if [[ ${1:-} == --check ]]; then
  ELISA_STAGE1_BIN="$STAGE1" \
  ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
  ELISA_STAGE1_SEMANTIC_GATE=1 \
    exec "$WRAPPER" -Werror=never-leak=strict -emit check "$ROOT/src/main.elisa"
fi
if [[ ! -f "$RUNTIME" ]]; then
  echo "error: Elisa runtime object is missing: $RUNTIME" >&2
  exit 2
fi

if ! command -v python3 >/dev/null; then
  echo "error: python3 is required to publish the build output" >&2
  exit 2
fi

mkdir -p "$ROOT/build"
staging_directory="$(mktemp -d "$ROOT/build/.elisapkg-build.XXXXXXXX")"
trap 'rm -rf -- "$staging_directory"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
staged_binary="$staging_directory/${OUT##*/}"

ELISA_STAGE1_BIN="$STAGE1" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_STAGE1_SEMANTIC_GATE=1 \
ELISA_RUNTIME_OBJ="$RUNTIME" \
  "$WRAPPER" ${lint_flags[@]+"${lint_flags[@]}"} -emit exe -o "$staged_binary" "$ROOT/src/main.elisa"

if [[ ! -f "$staged_binary" || -L "$staged_binary" || ! -s "$staged_binary" || ! -x "$staged_binary" ]]; then
  echo "error: compiler did not produce a nonempty executable file" >&2
  exit 1
fi

# Rename on the same filesystem. A directory at OUT is an error, rather
# than a destination into which the binary can be moved.
python3 - "$staged_binary" "$OUT" <<'PYTHON'
import os
import sys

try:
    os.chmod(sys.argv[1], 0o755)
    os.replace(sys.argv[1], sys.argv[2])
except OSError as error:
    raise SystemExit(f"error: unable to publish elisapkg: {error}") from error
PYTHON
echo "built $OUT"
