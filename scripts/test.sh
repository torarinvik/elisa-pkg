#!/usr/bin/env bash
set -euo pipefail
# Fixtures that the application consumes must have a predictable, non-shared
# writable mode even on hosts whose default umask is group-friendly (for
# example 0002). The package path policy intentionally rejects group-writable
# source roots.
umask 022

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/scripts/check_source_layout.py"
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
  source "$ROOT/scripts/smoke/binary_build_and_package_selection.sh"
  source "$ROOT/scripts/smoke/package_cache_and_release_preflight.sh"
)

source "$ROOT/scripts/smoke/targets_and_invalid_projects.sh"
source "$ROOT/scripts/smoke/toolchain_store.sh"
source "$ROOT/scripts/smoke/agent_runtime.sh"
python3 "$ROOT/scripts/regression_test.py"
python3 "$ROOT/scripts/cli_regression.py"
echo "elisapkg smoke tests passed"
