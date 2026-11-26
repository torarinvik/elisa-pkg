#!/usr/bin/env bash
set -euo pipefail
umask 022

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-}"
if [[ -z "$COMPILER_ROOT" ]]; then
  echo "error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout" >&2
  exit 2
fi
COMPILER_ROOT="$(cd -- "$COMPILER_ROOT" && pwd)"
CROSS_CC="${ELISAPKG_AARCH64_CC:-aarch64-linux-gnu-gcc}"
QEMU="${ELISAPKG_QEMU_AARCH64:-qemu-aarch64}"
SYSROOT="${ELISAPKG_AARCH64_SYSROOT:-/usr/aarch64-linux-gnu}"
for tool in "$CROSS_CC" "$QEMU"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: missing cross-test tool: $tool" >&2
    echo "note: install an AArch64 Linux cross compiler, libc sysroot, and qemu-user" >&2
    exit 2
  fi
done
CROSS_CC="$(command -v "$CROSS_CC")"
QEMU="$(command -v "$QEMU")"
if [[ ! -d "$SYSROOT" ]]; then
  echo "error: AArch64 sysroot is missing: $SYSROOT" >&2
  exit 2
fi

export ELISA_STAGE1_TRIPLE="aarch64-unknown-linux-gnu"
export ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$COMPILER_ROOT/bin/elisac-stage1}"
export ELISA_COMPILER_WRAPPER="${ELISA_COMPILER_WRAPPER:-$COMPILER_ROOT/scripts/elisac_stage1.sh}"
export ELISA_RUNTIME_OBJ="$ROOT/build/elisacore_runtime.aarch64.o"
export ELISA_CLANG="$CROSS_CC"
export ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}"
# QEMU's -L also prefixes guest absolute paths, hiding the host /tmp and
# /dev fixtures these security regressions intentionally exercise. Static
# probes let user-mode QEMU run with the host filesystem namespace instead.
export ELISA_STAGE1_LINK="${ELISAPKG_STAGE1_LINK:--static}"
export ELISAPKG_TEST_EXECUTOR="${ELISAPKG_TEST_EXECUTOR:-$QEMU}"

"$COMPILER_ROOT/scripts/build_runtime_object.sh"
"$ROOT/scripts/build.sh"
"$QEMU" "$ROOT/build/elisapkg" --version | grep -F 'elisapkg 0.1.0' >/dev/null
"$QEMU" "$ROOT/build/elisapkg" doctor >/dev/null
python3 "$ROOT/scripts/ffi_boundary_test.py"
python3 "$ROOT/scripts/security/ffi_source_open_regression.py"
python3 "$ROOT/scripts/security/linux_acl_regression.py"
