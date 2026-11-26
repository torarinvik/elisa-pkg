#!/usr/bin/env python3
"""Review regressions: independent fixtures, bounded subprocesses, real CLI."""
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
compiler_root = os.environ.get('ELISA_COMPILER_ROOT')
if not compiler_root:
    raise SystemExit('error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout')
COMPILER = Path(compiler_root) / 'scripts/elisac_stage1.sh'
CI_ENABLED = os.environ.get('CI', '').strip().lower() in {'1', 'true', 'yes'}
REQUIRE_COMPILER_PROBE = os.environ.get('ELISAPKG_REQUIRE_SANDBOX_TESTS') == '1' or CI_ENABLED

FNV_PRIME = 16777619
FNV_MASK = 0xffffffff
FNV_PRIME_INVERSE = pow(FNV_PRIME, -1, 1 << 32)
FNV_SAFE_BYTES = tuple(byte for byte in range(33, 127) if byte not in (34, 92))


def fnv_step(state, byte):
    return ((state ^ byte) * FNV_PRIME) & FNV_MASK


def fnv_unstep(state, byte):
    return ((state * FNV_PRIME_INVERSE) & FNV_MASK) ^ byte


def fnv1a(value):
    state = 2166136261
    for byte in value:
        state = fnv_step(state, byte)
    return state


def fnv_collision_prefixes(count, key_length):
    """Build distinct, equal-length printable keys with one FNV-1a hash."""
    first_prefix = b'k0000'
    filler_length = key_length - len(first_prefix) - 4
    first_filler = b'x' * filler_length
    first_suffix = b'aaaa'
    target = fnv1a(first_prefix + first_filler + first_suffix)
    prefixes_and_suffixes = [(first_prefix, first_suffix)]

    # Reverse the final two FNV steps once, then meet that table while trying
    # printable first-half suffixes for each distinct prefix.
    reverse_pairs = {}
    for third in FNV_SAFE_BYTES:
        for fourth in FNV_SAFE_BYTES:
            middle = fnv_unstep(fnv_unstep(target, fourth), third)
            reverse_pairs[middle] = (third, fourth)

    candidate = 1
    while len(prefixes_and_suffixes) < count:
        prefix = f'k{candidate:04x}'.encode('ascii')
        candidate += 1
        prefix_hash = fnv1a(prefix + b'x' * (key_length - len(prefix) - 4))
        found = None
        for first in FNV_SAFE_BYTES:
            first_hash = fnv_step(prefix_hash, first)
            for second in FNV_SAFE_BYTES:
                middle = fnv_step(first_hash, second)
                if middle in reverse_pairs:
                    found = bytes((first, second, *reverse_pairs[middle]))
                    break
            if found is not None:
                break
        if found is not None:
            prefixes_and_suffixes.append((prefix, found))

    keys = [prefix + b'x' * (key_length - len(prefix) - 4) + suffix
            for prefix, suffix in prefixes_and_suffixes]
    assert len(set(keys)) == count
    assert len({len(key) for key in keys}) == 1
    assert len({fnv1a(key) for key in keys}) == 1
    return prefixes_and_suffixes


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], timeout=120, check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='review-', dir=ROOT / 'build') as directory:
    work = Path(directory)
    lines = [f'include "{ROOT}/src/registry.elisa"',
             f'include "{ROOT}/src/package/manifest.elisa"',
             f'include "{ROOT}/src/package/receipt.elisa"',
             f'include "{ROOT}/src/cache.elisa"',
             'def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast, Console.Write]:']
    lines.extend([
        '    platform_buffer: mutable darray[u8] = []',
        '    platform_size: i64 = Platform::pkg_package_file_size("src/main.elisa")',
        '    return 803 if platform_size <= 0 or platform_size > 1048576',
        '    platform_buffer.resize(platform_size.usize() + 1.usize())',
        '    platform_raw: mutable u8& = (&platform_buffer[0]).cast[mutable u8&] can Unsafe.PointerCast',
        '    return 800 if Platform::pkg_is_directory(".") != 1',
        '    return 801 if Platform::pkg_is_directory("src") != 1',
        '    return 802 if Platform::pkg_is_directory("../") != 0',
        '    return 803 if Platform::pkg_read_package_file("src/main.elisa", platform_raw, platform_buffer.count) <= 0',
        '    return 804 if Platform::pkg_access("src/main.elisa", 0) != 0',
        '    return 805 if Platform::pkg_access(".", 0) == 0',
        '    return 806 if Platform::pkg_chmod(".", 493.u16()) == 0',
    ])
    number = 0

    def data(value):
        global number
        number += 1
        name = f'fixture{number}'
        lines.append(f'    {name}: mutable darray[u8] = {list(value.encode())}')
        return name

    def check(expression):
        lines.append(f'    return {len(lines)} if not ({expression})')

    for value in ['{}', '{"a":[1,true,false,null,{"b":"x\\u0041"}]}',
                  ' [ -1.25e+2 ] ']:
        check(f'Json::valid_document({data(value)})')
    for value in ['{"a":1 "b":2}', '{"a":1,}', '[1,]', '[}', '{}{}', '{"a":01}',
                  '{"a":tru}', '{"a":1e}', '{"a":"\\q"}', '{"a\\u0062":1}',
                  '{"a":1,"\\u0061":2}', '[' * 66 + '0' + ']' * 66]:
        check(f'not Json::valid_document({data(value)})')

    # Each key is distinct and valid JSON, but all keys collide in the
    # validator's 32-bit FNV-1a index. The comparison-work guard must reject
    # this input deterministically, without relying on a timing threshold.
    collision_keys = fnv_collision_prefixes(8, 4096)
    lines.append('    collision_document: mutable darray[u8] = [123]')
    for key_index, (prefix, suffix) in enumerate(collision_keys):
        if key_index > 0:
            lines.append('    collision_document.push(44)')
        lines.append('    collision_document.push(34)')
        lines.extend(f'    collision_document.push({byte})' for byte in prefix)
        lines.append(f'    for collision_fill_{key_index} in 0..<4087.usize() |collision_document|:')
        lines.append('        collision_document.push(120)')
        lines.extend(f'    collision_document.push({byte})' for byte in suffix)
        lines.extend(['    collision_document.push(34)',
                      '    collision_document.push(58)',
                      '    collision_document.push(48)'])
    lines.append('    collision_document.push(125)')
    check('Json::valid_document(collision_document)')
    check('not Json::unique_object_keys(collision_document)')

    lines.append('    req: mutable SemVer::Requirement = SemVer::Requirement{lower: Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}, upper: Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}, has_lower: false, has_upper: false, include_lower: false, include_upper: false}')
    for value in ['>=1.5.0 <2.0.0', '<2.0.0 >=1.5.0']:
        check(f'SemVer::parse_requirement({data(value)}, &req)')
        check('not SemVer::matches(req, Model::Version{major: 1, minor: 0, patch: 0, prerelease: false})')
        check('not SemVer::matches(req, Model::Version{major: 2, minor: 0, patch: 0, prerelease: false})')
        check('SemVer::matches(req, Model::Version{major: 1, minor: 7, patch: 0, prerelease: false})')
    for value in ['^18446744073709551615.0.0', '~1.18446744073709551615.0', '>=1.0.0 >=2.0.0', '1.0.0-alpha']:
        check(f'not SemVer::parse_requirement({data(value)}, &req)')
    for value in ['>1.0.0 <=1.0.0', '>=1.0.0 <1.0.0']:
        check(f'not SemVer::parse_requirement({data(value)}, &req)')
    left, right = data('1.0.0-alpha.1'), data('1.0.0-alpha.2')
    check(f'SemVer::compare_text({left}, {right}) == -1')
    hyphenated_prerelease = data('1.2.3-alpha-beta')
    parsed_hyphenated_prerelease = 'parsed_hyphenated_prerelease'
    lines.append(f'    {parsed_hyphenated_prerelease}: mutable Model::Version = Model::Version{{major: 0, minor: 0, patch: 0, prerelease: false}}')
    check(f'SemVer::parse({hyphenated_prerelease}, &{parsed_hyphenated_prerelease})')
    check(f'{parsed_hyphenated_prerelease}.major == 1 and {parsed_hyphenated_prerelease}.minor == 2 and {parsed_hyphenated_prerelease}.patch == 3 and {parsed_hyphenated_prerelease}.prerelease')
    lines.extend([
        '    exact_requirement: mutable darray[u8] = []',
        '    Registry::exact_requirement(Model::Version{major: 1, minor: 2, patch: 3, prerelease: false}, &exact_requirement)',
    ])
    check('exact_requirement.count == 5.usize() and exact_requirement[0] == 49 and exact_requirement[1] == 46 and exact_requirement[2] == 50 and exact_requirement[3] == 46 and exact_requirement[4] == 51')
    lines.append('    selected: mutable darray[u8] = [120]')
    catalog, requirement = data('1.0.0\nbroken\n'), data('^1.0.0')
    check(f'not Resolve::select_highest_version({catalog}, {requirement}, &selected)')
    check('selected.count == 0.usize()')
    for value in ['../a', 'a/../b', 'a\x00b', 'a\nb', 'a/', 'C:/a', 'a:b', 'a\x7fb', 'café']:
        check(f'not Archive::is_safe_entry({data(value)})')
    check(f'Archive::is_safe_entry({data("a..b")})')
    check(f'not Manifest::is_safe_relative_entry({data(".hidden/main.elisa")})')
    check(f'Manifest::is_safe_relative_entry({data("src/main.elisa")})')
    name = data('source.elisa')
    lines.extend([f'    header: darray[u8] = Archive::tar_file_header({name}, 1)',
                  '    archive: mutable darray[u8] = []', '    archive.resize(2048)',
                  '    for index in 0..<512 |archive, header|:',
                  '        archive[index] <- header[index]', '    archive[512] <- 65'])
    check('Archive::verify_ustar_archive(archive)')
    lines.append('    archive[513] <- 1')
    check('not Archive::verify_ustar_archive(archive)')
    receipt_name = data('acme')
    receipt_version = data('1.2.3')
    receipt_digest = data('a' * 64)
    lines.append(f'    receipt: mutable darray[u8] = PackageReceipt::encode({receipt_name}, {receipt_version}, {receipt_digest}, {receipt_digest}, {receipt_digest})')
    check('receipt.count > 0.usize()')
    injected_receipt_name = data('acme\ninjected:yes')
    lines.append(f'    injected_name_receipt: mutable darray[u8] = PackageReceipt::encode({injected_receipt_name}, {receipt_version}, {receipt_digest}, {receipt_digest}, {receipt_digest})')
    check('injected_name_receipt.count == 0.usize()')
    injected_receipt_version = data('1.2.3\ninjected:yes')
    lines.append(f'    injected_version_receipt: mutable darray[u8] = PackageReceipt::encode({receipt_name}, {injected_receipt_version}, {receipt_digest}, {receipt_digest}, {receipt_digest})')
    check('injected_version_receipt.count == 0.usize()')
    bad_receipt_digest = data('bad')
    lines.append(f'    bad_receipt: mutable darray[u8] = PackageReceipt::encode({receipt_name}, {receipt_version}, {bad_receipt_digest}, {receipt_digest}, {receipt_digest})')
    check('bad_receipt.count == 0.usize()')
    namespace, package = data('acme'), data('acme/../evil')
    check(f'Trust::precheck_namespace({package}, {namespace}) == Trust::VerificationCode.UnauthorizedNamespace')
    check(f'Trust::precheck_namespace({data("-bad")}, {namespace}) == Trust::VerificationCode.UnauthorizedNamespace')
    check(f'Trust::precheck_namespace({data("acme/-bad")}, {namespace}) == Trust::VerificationCode.UnauthorizedNamespace')
    check(f'Trust::precheck_namespace({data("acme/bad-")}, {namespace}) == Trust::VerificationCode.UnauthorizedNamespace')
    check(f'Trust::precheck_namespace({data("acme/bad--name")}, {namespace}) == Trust::VerificationCode.UnauthorizedNamespace')
    registry, expected_registry = data('primary'), data('primary')
    package_name, expected_package = data('acme/app'), data('acme/app')
    version, expected_version = data('1.2.3'), data('1.2.3')
    archive_digest, expected_digest = data('digest'), data('digest')
    check(f'Trust::precheck_binding({registry}, {expected_registry}, {package_name}, {expected_package}, {version}, {expected_version}, {archive_digest}, {expected_digest}, 42, 42) == Trust::VerificationCode.Valid')
    check(f'Trust::precheck_binding({data("mirror")}, {expected_registry}, {package_name}, {expected_package}, {version}, {expected_version}, {archive_digest}, {expected_digest}, 42, 42) == Trust::VerificationCode.WrongRegistry')
    check(f'Trust::precheck_binding({registry}, {expected_registry}, {package_name}, {expected_package}, {version}, {expected_version}, {archive_digest}, {expected_digest}, 41, 42) == Trust::VerificationCode.ArchiveSizeMismatch')
    check('Trust::precheck_publisher_attestation(false) == Trust::VerificationCode.MissingPublisherAttestation')
    check('Trust::precheck_threshold(1, 2) == Trust::VerificationCode.ThresholdInsufficient')
    check('Trust::precheck_revocation(true) == Trust::VerificationCode.RevokedKey')
    check('Trust::precheck_clock(9, 8) == Trust::VerificationCode.ClockRollback')
    trust_key = data('k' * 32)
    trust_signature = data('s' * 64)
    check(f'Trust::precheck_key_material("ed25519", {trust_key}, {trust_signature}) == Trust::VerificationCode.Valid')
    lines.extend([
        '    algorithm_storage: mutable darray[u8] = [101,100,50,53,53,49,57,0]',
        '    algorithm_name: cstr = (&algorithm_storage[0]).cast[cstr] can Unsafe.PointerCast',
    ])
    check('Trust::precheck_algorithm(algorithm_name) == Trust::VerificationCode.Valid')
    check(f'Trust::precheck_key_material("ed25519", {data("short")}, {trust_signature}) == Trust::VerificationCode.MalformedKey')
    check(f'Trust::precheck_key_material("ed25519", {trust_key}, {data("short")}) == Trust::VerificationCode.MalformedSignature')
    verify_package = data('acme')
    verify_version = data('1.0.0')
    verify_digest = data('a' * 64)
    verify_metadata_digest = data('b' * 64)
    lines.append(f'    trust_status: Registry::ResultCode = Registry::verify_trusted({verify_package}, {verify_version}, {verify_digest}, {verify_metadata_digest}, 4102444800)')
    check('trust_status == Registry::ResultCode.TrustStateUnavailable')
    check('Platform::pkg_strlen(Registry::result_message(Registry::ResultCode.Unsatisfiable)) > 0.usize()')
    cache_digest = data('a' * 64)
    cache_path: str = 'cache_path'
    lines.append(f'    {cache_path}: mutable darray[u8] = []')
    check(f'Cache::blob_path({cache_digest}, &{cache_path})')
    check(f'{cache_path}.count > 0.usize()')
    invalid_cache_digest = data('not-a-digest')
    lines.append('    invalid_cache_path: mutable darray[u8] = []')
    check(f'not Cache::blob_path({invalid_cache_digest}, &invalid_cache_path)')
    lines.extend([
        '    solver_name: mutable darray[u8] = [97]',
        '    solver_requirement: mutable darray[u8] = [94,49,46,48,46,48]',
        '    solver_roots: mutable darray[Solver::Constraint] = []',
        '    solver_roots.push(Solver::Constraint{package: solver_name, requirement: solver_requirement})',
        '    solver_dependencies: mutable darray[Solver::Constraint] = []',
        '    solver_candidates: mutable darray[Solver::Candidate] = []',
        '    solver_candidates.push(Solver::Candidate{package: solver_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    solver_candidates.push(Solver::Candidate{package: solver_name, version: Model::Version{major: 1, minor: 1, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    solver_selected: mutable darray[usize] = []',
        '    solver_result: mutable Solver::SolveCode = Solver::solve(solver_candidates, solver_roots, &solver_selected)',
    ])
    check('solver_result == Solver::SolveCode.Solved')
    check('solver_selected.count == 1.usize()')
    check('solver_selected[0] == 1.usize()')
    lines.extend([
        '    solver_preference: mutable darray[Solver::Preference] = []',
        '    solver_preference.push(Solver::Preference{package: solver_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}})',
        '    solver_preferred_selected: mutable darray[usize] = []',
        '    solver_preferred_result: Solver::SolveCode = Solver::solve_with_preferences(solver_candidates, solver_roots, solver_preference, &solver_preferred_selected)',
    ])
    check('solver_preferred_result == Solver::SolveCode.Solved and solver_preferred_selected.count == 1.usize() and solver_preferred_selected[0] == 0.usize()')
    lines.extend([
        '    solver_yanked_candidates: mutable darray[Solver::Candidate] = []',
        '    solver_yanked_candidates.push(Solver::Candidate{package: solver_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: true})',
        '    solver_yanked_candidates.push(Solver::Candidate{package: solver_name, version: Model::Version{major: 1, minor: 1, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    solver_yanked_preferred_selected: mutable darray[usize] = []',
        '    solver_yanked_preferred_result: Solver::SolveCode = Solver::solve_with_preferences(solver_yanked_candidates, solver_roots, solver_preference, &solver_yanked_preferred_selected)',
    ])
    check('solver_yanked_preferred_result == Solver::SolveCode.Solved and solver_yanked_preferred_selected.count == 1.usize() and solver_yanked_preferred_selected[0] == 0.usize()')
    lines.extend([
        '    solver_yanked_unpreferred_selected: mutable darray[usize] = []',
        '    solver_yanked_unpreferred_result: Solver::SolveCode = Solver::solve(solver_yanked_candidates, solver_roots, &solver_yanked_unpreferred_selected)',
    ])
    check('solver_yanked_unpreferred_result == Solver::SolveCode.Solved and solver_yanked_unpreferred_selected.count == 1.usize() and solver_yanked_unpreferred_selected[0] == 1.usize()')
    # These individually bounded inputs create millions of candidate/range
    # comparisons in the solver. The aggregate deterministic work cap must
    # stop the operation with ResourceLimit instead of spending unbounded CPU.
    lines.extend([
        '    solver_budget_candidates: mutable darray[Solver::Candidate] = []',
        '    solver_budget_roots: mutable darray[Solver::Constraint] = []',
        '    for solver_budget_index in 0..<2048 |solver_budget_candidates, solver_budget_roots|:',
        '        solver_budget_candidates.push(Solver::Candidate{package: solver_name, version: Model::Version{major: 1, minor: solver_budget_index.u64(), patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '        solver_budget_roots.push(Solver::Constraint{package: solver_name, requirement: solver_requirement})',
        '    solver_budget_selected: mutable darray[usize] = []',
        '    solver_budget_result: Solver::SolveCode = Solver::solve(solver_budget_candidates, solver_budget_roots, &solver_budget_selected)',
    ])
    check('solver_budget_result == Solver::SolveCode.ResourceLimit and solver_budget_selected.count == 0.usize()')
    lines.extend([
        '    solver_bad_requirement: mutable darray[u8] = [49,46,48]',
        '    solver_bad_roots: mutable darray[Solver::Constraint] = []',
        '    solver_bad_roots.push(Solver::Constraint{package: solver_name, requirement: solver_bad_requirement})',
        '    solver_bad_selected: mutable darray[usize] = []',
        '    solver_bad_result: Solver::SolveCode = Solver::solve(solver_candidates, solver_bad_roots, &solver_bad_selected)',
    ])
    check('solver_bad_result == Solver::SolveCode.Malformed and solver_bad_selected.count == 0.usize()')
    lines.extend([
        '    solver_pre_candidates: mutable darray[Solver::Candidate] = []',
        '    solver_pre_candidates.push(Solver::Candidate{package: solver_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: true}, dependencies: solver_dependencies, yanked: false})',
        '    solver_pre_selected: mutable darray[usize] = []',
        '    solver_pre_result: Solver::SolveCode = Solver::solve(solver_pre_candidates, solver_roots, &solver_pre_selected)',
    ])
    check('solver_pre_result == Solver::SolveCode.Malformed and solver_pre_selected.count == 0.usize()')
    lines.append('    solver_candidates[1].yanked <- true')
    lines.append('    solver_result <- Solver::solve(solver_candidates, solver_roots, &solver_selected)')
    check('solver_result == Solver::SolveCode.Solved and solver_selected[0] == 0.usize()')
    lines.append('    solver_candidates[0].yanked <- true')
    lines.append('    solver_result <- Solver::solve(solver_candidates, solver_roots, &solver_selected)')
    check('solver_result == Solver::SolveCode.Unsatisfiable')
    lines.extend([
        '    solver_conflict: mutable Solver::Conflict = Solver::Conflict{package: [], first_requirement: [], second_requirement: []}',
        '    solver_conflict_result: Solver::SolveCode = Solver::solve_with_conflict(solver_candidates, solver_roots, &solver_selected, &solver_conflict)',
    ])
    check('solver_conflict_result == Solver::SolveCode.Unsatisfiable and solver_conflict.package.count == 1.usize() and solver_conflict.first_requirement.count == solver_requirement.count and solver_conflict.second_requirement.count == solver_requirement.count')
    lines.extend([
        '    solver_extra_name: mutable darray[u8] = [98]',
        '    solver_extra_candidates: mutable darray[Solver::Candidate] = []',
        '    solver_extra_candidates.push(Solver::Candidate{package: solver_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    solver_extra_candidates.push(Solver::Candidate{package: solver_extra_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    solver_extra_selected: mutable darray[usize] = []',
        '    solver_extra_result: Solver::SolveCode = Solver::solve(solver_extra_candidates, solver_roots, &solver_extra_selected)',
    ])
    check('solver_extra_result == Solver::SolveCode.Solved and solver_extra_selected.count == 1.usize() and solver_extra_selected[0] == 0.usize()')
    lines.extend([
        '    solver_a_name: mutable darray[u8] = [97]',
        '    solver_b_name: mutable darray[u8] = [98]',
        '    solver_a_req_one: mutable darray[u8] = [94,49,46,48,46,48]',
        '    solver_a_req_two: mutable darray[u8] = [94,50,46,48,46,48]',
        '    solver_b_root_req: mutable darray[u8] = [62,61,49,46,48,46,48,32,60,51,46,48,46,48]',
        '    solver_roots_two: mutable darray[Solver::Constraint] = []',
        '    solver_roots_two.push(Solver::Constraint{package: solver_a_name, requirement: solver_a_req_one})',
        '    solver_roots_two.push(Solver::Constraint{package: solver_b_name, requirement: solver_b_root_req})',
        '    solver_b_deps_one: mutable darray[Solver::Constraint] = []',
        '    solver_b_deps_two: mutable darray[Solver::Constraint] = []',
        '    solver_b_deps_one.push(Solver::Constraint{package: solver_a_name, requirement: solver_a_req_one})',
        '    solver_b_deps_two.push(Solver::Constraint{package: solver_a_name, requirement: solver_a_req_two})',
        '    solver_candidates_two: mutable darray[Solver::Candidate] = []',
        '    solver_candidates_two.push(Solver::Candidate{package: solver_a_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    solver_candidates_two.push(Solver::Candidate{package: solver_a_name, version: Model::Version{major: 2, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    solver_candidates_two.push(Solver::Candidate{package: solver_b_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: solver_b_deps_one, yanked: false})',
        '    solver_candidates_two.push(Solver::Candidate{package: solver_b_name, version: Model::Version{major: 2, minor: 0, patch: 0, prerelease: false}, dependencies: solver_b_deps_two, yanked: false})',
        '    solver_selected_two: mutable darray[usize] = []',
        '    solver_result <- Solver::solve(solver_candidates_two, solver_roots_two, &solver_selected_two)',
    ])
    check('solver_result == Solver::SolveCode.Solved')
    check('solver_selected_two.count == 2.usize() and solver_selected_two[0] == 0.usize() and solver_selected_two[1] == 2.usize()')
    lines.extend([
        '    solver_candidates_two[2].yanked <- true',
        '    solver_result <- Solver::solve(solver_candidates_two, solver_roots_two, &solver_selected_two)',
    ])
    check('solver_result == Solver::SolveCode.Unsatisfiable')
    lines.extend([
        '    solver_conflict_two: mutable Solver::Conflict = Solver::Conflict{package: [], first_requirement: [], second_requirement: []}',
        '    solver_conflict_two_result: Solver::SolveCode = Solver::solve_with_conflict(solver_candidates_two, solver_roots_two, &solver_selected_two, &solver_conflict_two)',
    ])
    check('solver_conflict_two_result == Solver::SolveCode.Unsatisfiable and solver_conflict_two.package.count == solver_a_name.count and solver_conflict_two.first_requirement.count == solver_a_req_one.count and solver_conflict_two.second_requirement.count == solver_a_req_two.count')
    lines.extend([
        '    diagnostic_a_name: mutable darray[u8] = [97]',
        '    diagnostic_b_name: mutable darray[u8] = [98]',
        '    diagnostic_c_name: mutable darray[u8] = [99]',
        '    diagnostic_q_name: mutable darray[u8] = [113]',
        '    diagnostic_z_name: mutable darray[u8] = [122]',
        '    diagnostic_a_range: mutable darray[u8] = [62,61,49,46,48,46,48,32,60,51,46,48,46,48]',
        '    diagnostic_b_below: mutable darray[u8] = [60,50,46,48,46,48]',
        '    diagnostic_b_at_least: mutable darray[u8] = [62,61,50,46,48,46,48]',
        '    diagnostic_c_below: mutable darray[u8] = [60,50,46,48,46,48]',
        '    diagnostic_c_at_least: mutable darray[u8] = [62,61,50,46,48,46,48]',
        '    diagnostic_a_one_dependencies: mutable darray[Solver::Constraint] = []',
        '    diagnostic_a_two_dependencies: mutable darray[Solver::Constraint] = []',
        '    diagnostic_q_dependencies: mutable darray[Solver::Constraint] = []',
        '    diagnostic_z_dependencies: mutable darray[Solver::Constraint] = []',
        '    diagnostic_a_one_dependencies.push(Solver::Constraint{package: diagnostic_b_name, requirement: diagnostic_b_below})',
        '    diagnostic_a_two_dependencies.push(Solver::Constraint{package: diagnostic_b_name, requirement: diagnostic_b_at_least})',
        '    diagnostic_q_dependencies.push(Solver::Constraint{package: diagnostic_c_name, requirement: diagnostic_c_at_least})',
        '    diagnostic_z_dependencies.push(Solver::Constraint{package: diagnostic_c_name, requirement: diagnostic_c_below})',
        '    diagnostic_candidates: mutable darray[Solver::Candidate] = []',
        '    diagnostic_candidates.push(Solver::Candidate{package: diagnostic_a_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: diagnostic_a_one_dependencies, yanked: false})',
        '    diagnostic_candidates.push(Solver::Candidate{package: diagnostic_a_name, version: Model::Version{major: 2, minor: 0, patch: 0, prerelease: false}, dependencies: diagnostic_a_two_dependencies, yanked: false})',
        '    diagnostic_candidates.push(Solver::Candidate{package: diagnostic_b_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    diagnostic_candidates.push(Solver::Candidate{package: diagnostic_b_name, version: Model::Version{major: 2, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    diagnostic_candidates.push(Solver::Candidate{package: diagnostic_c_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    diagnostic_candidates.push(Solver::Candidate{package: diagnostic_c_name, version: Model::Version{major: 2, minor: 0, patch: 0, prerelease: false}, dependencies: solver_dependencies, yanked: false})',
        '    diagnostic_candidates.push(Solver::Candidate{package: diagnostic_q_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: diagnostic_q_dependencies, yanked: false})',
        '    diagnostic_candidates.push(Solver::Candidate{package: diagnostic_z_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: diagnostic_z_dependencies, yanked: false})',
        '    diagnostic_roots: mutable darray[Solver::Constraint] = []',
        '    diagnostic_roots.push(Solver::Constraint{package: diagnostic_a_name, requirement: diagnostic_a_range})',
        '    diagnostic_roots.push(Solver::Constraint{package: diagnostic_q_name, requirement: solver_requirement})',
        '    diagnostic_roots.push(Solver::Constraint{package: diagnostic_z_name, requirement: solver_requirement})',
        '    diagnostic_selected: mutable darray[usize] = []',
        '    diagnostic_conflict: mutable Solver::Conflict = Solver::Conflict{package: [], first_requirement: [], second_requirement: []}',
        '    diagnostic_result: Solver::SolveCode = Solver::solve_with_conflict(diagnostic_candidates, diagnostic_roots, &diagnostic_selected, &diagnostic_conflict)',
    ])
    check('diagnostic_result == Solver::SolveCode.Unsatisfiable and diagnostic_conflict.package.count == 1.usize() and diagnostic_conflict.package[0] == 99 and diagnostic_conflict.first_requirement.count > 0.usize() and diagnostic_conflict.second_requirement.count > 0.usize()')
    lines.extend([
        '    cycle_a_name: mutable darray[u8] = [99]',
        '    cycle_b_name: mutable darray[u8] = [100]',
        '    cycle_requirement: mutable darray[u8] = [94,49,46,48,46,48]',
        '    cycle_a_dependencies: mutable darray[Solver::Constraint] = []',
        '    cycle_b_dependencies: mutable darray[Solver::Constraint] = []',
        '    cycle_a_dependencies.push(Solver::Constraint{package: cycle_b_name, requirement: cycle_requirement})',
        '    cycle_b_dependencies.push(Solver::Constraint{package: cycle_a_name, requirement: cycle_requirement})',
        '    cycle_candidates: mutable darray[Solver::Candidate] = []',
        '    cycle_candidates.push(Solver::Candidate{package: cycle_a_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: cycle_a_dependencies, yanked: false})',
        '    cycle_candidates.push(Solver::Candidate{package: cycle_b_name, version: Model::Version{major: 1, minor: 0, patch: 0, prerelease: false}, dependencies: cycle_b_dependencies, yanked: false})',
        '    cycle_roots: mutable darray[Solver::Constraint] = []',
        '    cycle_roots.push(Solver::Constraint{package: cycle_a_name, requirement: cycle_requirement})',
        '    cycle_selected: mutable darray[usize] = []',
        '    cycle_result: Solver::SolveCode = Solver::solve(cycle_candidates, cycle_roots, &cycle_selected)',
    ])
    check('cycle_result == Solver::SolveCode.Unsatisfiable and cycle_selected.count == 0.usize()')
    lines.append('    return 0')
    source = work / 'probe.elisa'
    source.write_text('\n'.join(lines) + '\n')
    compiler_result = subprocess.run(
        [str(COMPILER), '-emit', 'exe', '-o', str(work / 'probe'), str(source)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        timeout=120, check=False,
    )
    probe_built = compiler_result.returncode == 0
    if not probe_built:
        license_unaccepted = 'You have not agreed to the Xcode license agreements' in compiler_result.stdout
        if license_unaccepted and not REQUIRE_COMPILER_PROBE:
            print('review compiler probe skipped: host Xcode license is not accepted')
        else:
            raise SystemExit(
                f'error: compiler review probe failed with exit {compiler_result.returncode}:\n'
                f'{compiler_result.stdout}'
            )
    empty_home = work / 'empty-home'
    empty_home.mkdir()
    trust_key = work / 'registry-trust-key'
    trust_key.write_bytes(bytes(range(32)))
    trust_key.chmod(0o600)
    probe_environment = dict(
        os.environ,
        ELISAPKG_REGISTRY_DIR=str(work / 'missing-registry'),
        ELISAPKG_REGISTRY_TRUST_ROOT=str(trust_key),
        HOME=str(empty_home),
    )
    if probe_built:
        # Exercise the package-file FFI inside a private source root. The
        # platform boundary intentionally rejects group-writable roots such
        # as some shared Vast checkouts.
        probe_root = work / 'probe-root'
        probe_root.mkdir(mode=0o700)
        probe_source = probe_root / 'src'
        probe_source.mkdir(mode=0o700)
        (probe_source / 'main.elisa').write_text('def main() -> i64:\n    return 0\n')
        run([work / 'probe'], cwd=probe_root, env=probe_environment)
        assert not (empty_home / '.local').exists(), 'read-only trust verification created user state directories'


print('Elisa module regressions passed')
