# Sourced by scripts/test.sh after the shared smoke setup.

# Exercise the pure SemVer requirement module independently of the CLI. This
# keeps parser/range regressions visible without requiring a registry fixture.
SEMVER_PROBE="$TEST_TMP/semver-probe-$$.elisa"
SEMVER_BIN="$TEST_TMP/semver-probe-$$"
cat > "$SEMVER_PROBE" <<EOF
include "$ROOT/src/package/model.elisa"
include "$ROOT/src/resolution/semver.elisa"

def main() -> i64:
    caret: mutable darray[u8] = [94, 49, 46, 50, 46, 51]
    exact: mutable darray[u8] = [49, 46, 50, 46, 51]
    pair: mutable darray[u8] = [62, 61, 49, 46, 48, 46, 48, 32, 60, 50, 46, 48, 46, 48]
    bad: mutable darray[u8] = [49, 46, 48, 46, 48, 45, 48, 49]
    alpha: mutable darray[u8] = [49, 46, 48, 46, 48, 45, 97, 108, 112, 104, 97]
    beta: mutable darray[u8] = [49, 46, 48, 46, 48, 45, 98, 101, 116, 97]
    stable: mutable darray[u8] = [49, 46, 48, 46, 48]
    alpha_version: mutable Model::Version = Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}
    beta_version: mutable Model::Version = Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}
    stable_version: mutable Model::Version = Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}
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
    return 16 if not SemVer::parse(alpha, &alpha_version) or not SemVer::parse(beta, &beta_version) or not SemVer::parse(stable, &stable_version)
    # Model::Version intentionally discards prerelease identifiers. Do not
    # claim same-core prereleases are equal; use compare_text for their order.
    return 17 if SemVer::compare(alpha_version, beta_version) != SemVer::COMPARE_INCOMPARABLE
    return 18 if SemVer::compare(alpha_version, stable_version) != -1
    return 19 if SemVer::compare(stable_version, alpha_version) != 1
    empty_range: mutable darray[u8] = [62, 49, 46, 48, 46, 48, 46, 48, 32, 60, 61, 49, 46, 48, 46, 48]
    return 15 if SemVer::parse_requirement(empty_range, &blank)
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$SEMVER_BIN" "$SEMVER_PROBE"
"$SEMVER_BIN"

# The resolver primitive has no network/provider dependency. Verify highest
# satisfying selection, prerelease ordering, and fail-closed catalog parsing.
RESOLVE_PROBE="$TEST_TMP/resolve-probe-$$.elisa"
RESOLVE_BIN="$TEST_TMP/resolve-probe-$$"
cat > "$RESOLVE_PROBE" <<EOF
include "$ROOT/src/resolution/resolve.elisa"

def same(value: darray[u8]&, expected: cstr) -> bool:
    length: mutable usize = 0.usize()
    while expected[length].u8() != 0:
        length <- length + 1.usize()
    return false if value.count != length
    for index in 0..<length |value, expected|:
        return false if value[index] != expected[index].u8()
    return true

def push_decimal(out: mutable darray[u8]&, value: u64) -> void can[Memory.Allocate, Abort.Panic]:
    digits: mutable darray[u8] = []
    number: mutable u64 = value
    if number == 0:
        digits.push(48)
    while number > 0 |digits, number|:
        digit: u8 = (48.u64() + number % 10.u64()).u8()
        digits.push(digit)
        number <- number / 10.u64()
    cursor: mutable usize = digits.count
    while cursor > 0.usize() |out, digits, cursor|:
        cursor <- cursor - 1.usize()
        out.push(digits[cursor])

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
    # Exercise the full documented catalog limit so duplicate tracking remains
    # bounded at the largest metadata input, not only on short happy paths.
    large_catalog: mutable darray[u8] = []
    for minor in 0..<4096 |large_catalog|:
        large_catalog.push(48)
        large_catalog.push(46)
        push_decimal(&large_catalog, minor.u64())
        large_catalog.push(46)
        large_catalog.push(48)
        large_catalog.push(10)
    at_least_zero: mutable darray[u8] = [62, 61, 48, 46, 48, 46, 48]
    return 7 if not Resolve::select_highest_version(large_catalog, at_least_zero, &selected)
    return 8 if not same(selected, "0.4095.0")
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$RESOLVE_BIN" "$RESOLVE_PROBE"
"$RESOLVE_BIN"

# A cyclic highest-version branch must backtrack when a lower version yields
# an acyclic solution, rather than misclassifying the input as malformed.
SOLVER_PROBE="$TEST_TMP/solver-probe-$$.elisa"
SOLVER_BIN="$TEST_TMP/solver-probe-$$"
cat > "$SOLVER_PROBE" <<EOF
include "$ROOT/src/resolution/solver.elisa"

def main() -> i64 can[Memory.Allocate, Abort.Panic]:
    a: mutable darray[u8] = [97]
    b: mutable darray[u8] = [98]
    any_v1: mutable darray[u8] = [94,49,46,48,46,48]
    a_high_dependencies: mutable darray[Solver::Constraint] = []
    a_high_dependencies.push(Solver::Constraint{package: b, requirement: any_v1})
    b_dependencies: mutable darray[Solver::Constraint] = []
    b_dependencies.push(Solver::Constraint{package: a, requirement: any_v1})
    candidates: mutable darray[Solver::Candidate] = []
    candidates.push(Solver::Candidate{package: a, version: Model::Version{major: 1, minor: 1, patch: 0, prerelease: false}, dependencies: a_high_dependencies, yanked: false})
    candidates.push(Solver::Candidate{package: a, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: [], yanked: false})
    candidates.push(Solver::Candidate{package: b, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: b_dependencies, yanked: false})
    roots: mutable darray[Solver::Constraint] = []
    roots.push(Solver::Constraint{package: a, requirement: any_v1})
    selected: mutable darray[usize] = []
    result: Solver::SolveCode = Solver::solve(candidates, roots, &selected)
    return 1 if result != Solver::SolveCode.Solved
    return 2 if selected.count != 1
    return 3 if selected[0] != 1
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$SOLVER_BIN" "$SOLVER_PROBE"
"$SOLVER_BIN"

# Trust policy prechecks are distinct from cryptographic verification. Exercise
# their expiry, rollback, namespace, and algorithm failures while the production
# remote provider remains disabled.
TRUST_PROBE="$TEST_TMP/trust-probe-$$.elisa"
TRUST_BIN="$TEST_TMP/trust-probe-$$"
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

# The provider path is exercised with a fixed Ed25519 vector. A valid detached
# signature must pass, while a one-byte mutation must fail closed.
CRYPTO_PROBE="$TEST_TMP/crypto-probe-$$.elisa"
CRYPTO_BIN="$TEST_TMP/crypto-probe-$$"
cat > "$CRYPTO_PROBE" <<EOF
include "$ROOT/src/trust.elisa"

def main() -> i64:
    public_key: mutable darray[u8] = [210,215,81,194,128,33,126,204,53,156,34,244,6,136,131,235,211,40,218,212,248,228,62,102,227,40,136,58,31,197,139,182]
    message: mutable darray[u8] = [115,105,103,110,101,100,32,109,101,115,115,97,103,101]
    signature: mutable darray[u8] = [56,127,124,128,177,193,186,187,254,246,65,194,183,136,113,123,176,137,87,75,172,103,193,38,147,182,192,39,141,37,36,99,91,152,227,12,212,208,239,177,87,48,112,226,96,86,5,98,91,112,95,218,34,97,244,169,23,44,233,89,231,84,107,14]
    return 1 if Trust::verify_detached("ed25519", public_key, message, signature) != Trust::VerificationCode.Valid
    signature[0] <- signature[0] + 1
    return 2 if Trust::verify_detached("ed25519", public_key, message, signature) == Trust::VerificationCode.Valid
    return 0
EOF
ELISA_STAGE1_BIN="${ELISA_STAGE1_BIN:-$ELISA_COMPILER_ROOT/bin/elisac-stage1}" \
ELISA_ALLOW_STALE_STAGE1="${ELISA_ALLOW_STALE_STAGE1:-0}" \
ELISA_RUNTIME_OBJ="${ELISA_RUNTIME_OBJ:-$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o}" \
  "$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh" -emit exe -o "$CRYPTO_BIN" "$CRYPTO_PROBE"
"$CRYPTO_BIN"
