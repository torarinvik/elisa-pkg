#!/usr/bin/env python3
"""Review regressions: independent fixtures, bounded subprocesses, real CLI."""
import ctypes
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'build/elisapkg'
COMPILER = Path(os.environ['ELISA_COMPILER_ROOT']) / 'scripts/elisac_stage1.sh'


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], timeout=120, check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='review-', dir=ROOT / 'build') as directory:
    work = Path(directory)
    lines = [f'include "{ROOT}/src/model.elisa"',
             f'include "{ROOT}/src/semver.elisa"',
             f'include "{ROOT}/src/json.elisa"',
             f'include "{ROOT}/src/archive.elisa"',
             f'include "{ROOT}/src/cache.elisa"',
             f'include "{ROOT}/src/resolve.elisa"',
             f'include "{ROOT}/src/trust.elisa"',
             f'include "{ROOT}/src/solver.elisa"', 'def main() -> i64:']
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
                  '{"a\\u0062":1}', ' [ -1.25e+2 ] ']:
        check(f'Json::valid_document({data(value)})')
    for value in ['{"a":1 "b":2}', '{"a":1,}', '[1,]', '[}', '{}{}', '{"a":01}',
                  '{"a":tru}', '{"a":1e}', '{"a":"\\q"}', '[' * 66 + '0' + ']' * 66]:
        check(f'not Json::valid_document({data(value)})')
    lines.append('    req: mutable SemVer::Requirement = SemVer::Requirement{lower: Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}, upper: Model::Version{major: 0, minor: 0, patch: 0, prerelease: false}, has_lower: false, has_upper: false, include_lower: false, include_upper: false}')
    for value in ['>=1.5.0 <2.0.0', '<2.0.0 >=1.5.0']:
        check(f'SemVer::parse_requirement({data(value)}, &req)')
        check('not SemVer::matches(req, Model::Version{major: 1, minor: 0, patch: 0, prerelease: false})')
        check('not SemVer::matches(req, Model::Version{major: 2, minor: 0, patch: 0, prerelease: false})')
        check('SemVer::matches(req, Model::Version{major: 1, minor: 7, patch: 0, prerelease: false})')
    for value in ['^18446744073709551615.0.0', '~1.18446744073709551615.0', '>=1.0.0 >=2.0.0', '1.0.0-alpha']:
        check(f'not SemVer::parse_requirement({data(value)}, &req)')
    left, right = data('1.0.0-alpha.1'), data('1.0.0-alpha.2')
    check(f'SemVer::compare_text({left}, {right}) == -1')
    lines.append('    selected: mutable darray[u8] = [120]')
    catalog, requirement = data('1.0.0\nbroken\n'), data('^1.0.0')
    check(f'not Resolve::select_highest_version({catalog}, {requirement}, &selected)')
    check('selected.count == 0.usize()')
    for value in ['../a', 'a/../b', 'a\x00b', 'a\nb', 'a/', 'C:/a', 'a:b']:
        check(f'not Archive::is_safe_entry({data(value)})')
    check(f'Archive::is_safe_entry({data("a..b")})')
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
    lines.append(f'    receipt: mutable darray[u8] = Archive::package_receipt_bytes({receipt_name}, {receipt_version}, {receipt_digest}, {receipt_digest}, {receipt_digest})')
    check('receipt.count > 0.usize()')
    bad_receipt_digest = data('bad')
    lines.append(f'    bad_receipt: mutable darray[u8] = Archive::package_receipt_bytes({receipt_name}, {receipt_version}, {bad_receipt_digest}, {receipt_digest}, {receipt_digest})')
    check('bad_receipt.count == 0.usize()')
    namespace, package = data('acme'), data('acme/../evil')
    check(f'Trust::precheck_namespace({package}, {namespace}) == Trust::VerificationCode.UnauthorizedNamespace')
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
    check(f'Trust::precheck_key_material("ed25519", {data("short")}, {trust_signature}) == Trust::VerificationCode.MalformedKey')
    check(f'Trust::precheck_key_material("ed25519", {trust_key}, {data("short")}) == Trust::VerificationCode.MalformedSignature')
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
    lines.append('    solver_candidates[1].yanked <- true')
    lines.append('    solver_result <- Solver::solve(solver_candidates, solver_roots, &solver_selected)')
    check('solver_result == Solver::SolveCode.Solved and solver_selected[0] == 0.usize()')
    lines.append('    solver_candidates[0].yanked <- true')
    lines.append('    solver_result <- Solver::solve(solver_candidates, solver_roots, &solver_selected)')
    check('solver_result == Solver::SolveCode.Unsatisfiable')
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
    lines.append('    return 0')
    source = work / 'probe.elisa'
    source.write_text('\n'.join(lines) + '\n')
    (ROOT / 'build/review-probe.elisa').write_text(source.read_text())
    run([COMPILER, '-emit', 'exe', '-o', work / 'probe', source])
    run([work / 'probe'])

    run([BIN, 'init', work / 'project'], stdout=subprocess.DEVNULL)
    project = work / 'project'
    conflict_init = subprocess.run([BIN, 'init', work / 'conflict', '--lib', '--bin'], capture_output=True, timeout=120)
    assert conflict_init.returncode == 2, conflict_init
    run([BIN, 'resolve'], cwd=project, stdout=subprocess.DEVNULL)
    for command in [['resolve', 'unexpected'], ['check-manifest', 'unexpected']]:
        result = subprocess.run([BIN, *command], cwd=project, capture_output=True, timeout=120)
        assert result.returncode == 2, (command, result)
    for command in [['resolve', '--list'], ['build', '--dry-run'], ['build', '--version']]:
        result = subprocess.run([BIN, *command], cwd=project, capture_output=True, timeout=120)
        assert result.returncode == 2, (command, result)
    duplicate_manifest_path = subprocess.run([BIN, 'check-manifest', '--manifest-path', project / 'elisapkg.json', '--manifest-path', project / 'elisapkg.json'], capture_output=True, timeout=120)
    assert duplicate_manifest_path.returncode == 2, duplicate_manifest_path
    result = subprocess.run([BIN, 'update', 'missing'], cwd=project, capture_output=True, timeout=120)
    assert result.returncode == 3, result
    result = subprocess.run([BIN, 'test'], cwd=project, capture_output=True, timeout=120)
    assert result.returncode == 2, result
    lock = project / 'elisapkg.lock'
    before = lock.stat()
    run([BIN, 'resolve', '--frozen'], cwd=project, stdout=subprocess.DEVNULL)
    after = lock.stat()
    assert (before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns)

    external = work / 'external'
    external.mkdir()
    (external / 'src').mkdir()
    (external / 'src/main.elisa').write_text('def main() -> i64:\n    return 0\n')
    (external / 'elisapkg.json').write_text(
        '{"schema-version":1,"package":{"name":"external","version":"0.1.0"},'
        '"targets":[{"name":"external","kind":"lib","entry":"src/main.elisa"}],'
        '"dependencies":{}}\n')
    parent = work / 'parent'
    run([BIN, 'init', parent], stdout=subprocess.DEVNULL)
    manifest = parent / 'elisapkg.json'
    manifest.write_text(
        '{"schema-version":1,"package":{"name":"parent","version":"0.1.0"},'
        '"targets":[{"name":"parent","kind":"bin","entry":"src/main.elisa"}],'
        '"dependencies":{"external":{"path":"../external"}}}\n')
    run([BIN, 'resolve'], cwd=parent, stdout=subprocess.DEVNULL)
    assert '"name":"external"' in (parent / 'elisapkg.lock').read_text()

    collision_root = work / 'collision-root'
    collision_dep = work / 'collision-dep'
    run([BIN, 'init', collision_root], stdout=subprocess.DEVNULL)
    run([BIN, 'init', collision_dep], stdout=subprocess.DEVNULL)
    collision_manifest = collision_root / 'elisapkg.json'
    collision_manifest.write_text(
        '{"schema-version":1,"package":{"name":"collision-root","version":"0.1.0"},'
        '"targets":[{"name":"collision-root","kind":"bin","entry":"src/main.elisa"}],'
        '"dependencies":{"collision":{"path":"../collision-dep"}}}\n')
    (collision_dep / 'elisapkg.json').write_text(
        '{"schema-version":1,"package":{"name":"collision-root","version":"0.2.0"},'
        '"targets":[{"name":"collision-root","kind":"lib","entry":"src/main.elisa"}],'
        '"dependencies":{}}\n')
    result = subprocess.run([BIN, 'resolve'], cwd=collision_root, capture_output=True, timeout=120)
    assert result.returncode == 3, result

    manifest = project / 'elisapkg.json'
    valid = manifest.read_text()
    unsupported_registry = valid.replace('"dependencies": {}', '"dependencies":{"remote":{"registry":"default","version":"^1.0.0"}}')
    misplaced_identity = valid.replace('"targets":', '"name":"shadow","targets":')
    misplaced_package_field = valid.replace('"version": "0.1.0"', '"version": "0.1.0", "entry":"src/main.elisa"', 1)
    misplaced_target_field = valid.replace('"kind": "bin"', '"kind": "bin", "license":"MIT"', 1)
    missing_target_entry = valid.replace(', "entry": "src/main.elisa"', '', 1)
    missing_target_kind = valid.replace(', "kind": "bin"', '', 1)
    for invalid in [valid.replace('"schema-version": 1,', '"schema-version": 1'), valid + '{}', unsupported_registry, misplaced_identity, misplaced_package_field, misplaced_target_field, missing_target_entry, missing_target_kind]:
        manifest.write_text(invalid)
        result = subprocess.run([BIN, 'check-manifest'], cwd=project, capture_output=True, timeout=120)
        assert result.returncode != 0
    manifest.write_text(valid)
    legacy_only = project / 'manifest.json'
    legacy_only.write_text(valid)
    manifest.unlink()
    result = subprocess.run([BIN, 'check-manifest'], cwd=project, capture_output=True, timeout=120)
    assert result.returncode == 2, result
    manifest.write_text(valid)
    legacy_only.unlink()
    artifact = project / '.elisapkg/build/app'
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_bytes(b'previous working output')
    artifact.chmod(0o755)
    compiler = work / 'empty-compiler'
    compiler.write_text('#!/bin/sh\nexit 0\n')
    compiler.chmod(0o755)
    environment = dict(os.environ, ELISAPKG_COMPILER=str(compiler))
    result = subprocess.run([BIN, 'build'], cwd=project, env=environment,
                            capture_output=True, timeout=120)
    assert result.returncode == 6, result
    assert artifact.read_bytes() == b'previous working output'

    guard = project / '.elisapkg/transaction.guard'
    guard.mkdir()
    result = subprocess.run([BIN, 'check-manifest'], cwd=project, capture_output=True, timeout=120)
    assert result.returncode == 5, result
    guard.rmdir()

    # Directly exercise the native seam with a regular file and link traversal.
    library = work / 'platform.dylib'
    run([os.environ.get('CC', 'cc'), '-shared', '-fPIC', ROOT / 'src/platform_files.c', '-o', library])
    native = ctypes.CDLL(str(library))
    read = native.elisapkg_read_package_file
    read.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
    read.restype = ctypes.c_longlong
    is_directory = native.elisapkg_is_directory
    is_directory.argtypes = [ctypes.c_char_p]
    is_directory.restype = ctypes.c_longlong
    mkdir_secure = native.elisapkg_mkdir
    mkdir_secure.argtypes = [ctypes.c_char_p, ctypes.c_ushort]
    mkdir_secure.restype = ctypes.c_longlong
    access_secure = native.elisapkg_access
    access_secure.argtypes = [ctypes.c_char_p, ctypes.c_int]
    access_secure.restype = ctypes.c_longlong
    mkstemp_secure = native.elisapkg_mkstemp
    mkstemp_secure.argtypes = [ctypes.c_char_p]
    mkstemp_secure.restype = ctypes.c_longlong
    rename_secure = native.elisapkg_rename
    rename_secure.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    rename_secure.restype = ctypes.c_longlong
    unlink_secure = native.elisapkg_unlink
    unlink_secure.argtypes = [ctypes.c_char_p]
    unlink_secure.restype = ctypes.c_longlong
    chdir_secure = native.elisapkg_chdir
    chdir_secure.argtypes = [ctypes.c_char_p]
    chdir_secure.restype = ctypes.c_longlong
    extract_ustar = native.elisapkg_extract_ustar
    extract_ustar.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p]
    extract_ustar.restype = ctypes.c_longlong
    wait_timeout = native.elisapkg_waitpid_timeout
    wait_timeout.argtypes = [ctypes.c_longlong, ctypes.POINTER(ctypes.c_longlong), ctypes.c_longlong]
    wait_timeout.restype = ctypes.c_longlong
    timeout_error = native.elisapkg_timeout_error
    timeout_error.argtypes = []
    timeout_error.restype = ctypes.c_longlong
    realpath_secure = native.elisapkg_realpath
    realpath_secure.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
    realpath_secure.restype = ctypes.c_char_p

    def ustar(name, content, mode=0o644):
        header = bytearray(512)
        encoded_name = name.encode()
        assert 0 < len(encoded_name) < 100
        header[:len(encoded_name)] = encoded_name
        header[100:108] = f'{mode:07o}'.encode() + b'\0'
        header[108:116] = b'0000000\0'
        header[116:124] = b'0000000\0'
        header[124:136] = f'{len(content):011o}'.encode() + b'\0'
        header[136:148] = b'00000000000\0'
        header[148:156] = b'        '
        header[156] = ord('0')
        header[257:263] = b'ustar\0'
        header[263:265] = b'00'
        header[148:156] = f'{sum(header):06o}'.encode() + b'\0 '
        padding = b'\0' * ((512 - len(content) % 512) % 512)
        return bytes(header) + content + padding + b'\0' * 1024

    buffer = ctypes.create_string_buffer(128)
    previous = Path.cwd()
    try:
        os.chdir(project)
        assert is_directory(b'') == 0
        assert is_directory(b'../') == 0
        assert is_directory(b'src') == 1
        assert read(b'src/main.elisa', buffer, 128) > 0
        assert read(b'../external/src/main.elisa', buffer, 128) > 0
        resolved = ctypes.create_string_buffer(4096)
        assert realpath_secure(b'src/main.elisa', resolved, len(resolved)) is not None
        tiny_resolved = ctypes.create_string_buffer(1)
        assert realpath_secure(b'src/main.elisa', tiny_resolved, len(tiny_resolved)) is None
        Path('alias').symlink_to('src', target_is_directory=True)
        assert is_directory(b'alias') == 0
        Path('nested').mkdir()
        Path('nested/alias').symlink_to('../src', target_is_directory=True)
        assert is_directory(b'nested/alias') == 0
        assert mkdir_secure(b'nested/created', 0o755) == 0
        assert is_directory(b'nested/created') == 1
        assert mkdir_secure(b'nested/alias/blocked', 0o755) < 0
        assert read(b'alias/main.elisa', buffer, 128) < 0
        assert access_secure(b'alias/main.elisa', 0) < 0
        assert chdir_secure(b'alias') < 0
        temp_template = ctypes.create_string_buffer(b'nested/temporary.XXXXXX')
        temp_fd = mkstemp_secure(temp_template)
        assert temp_fd >= 0
        os.close(temp_fd)
        temporary_name = Path(temp_template.value.decode())
        assert temporary_name.is_file()
        assert unlink_secure(str(temporary_name).encode()) == 0
        linked_parent_template = ctypes.create_string_buffer(b'nested/alias/temporary.XXXXXX')
        assert mkstemp_secure(linked_parent_template) < 0
        Path('rename-source').write_bytes(b'source')
        Path('rename-destination').symlink_to('src/main.elisa')
        assert rename_secure(b'rename-source', b'rename-destination') < 0
        Path('rename-destination').unlink()
        Path('rename-source').unlink()
        Path('linked').symlink_to('src/main.elisa')
        assert read(b'linked', buffer, 128) < 0
        assert read(str((project / 'src/main.elisa').resolve()).encode(), buffer, 128) > 0
        Path('absolute-linked').symlink_to((project / 'src/main.elisa').resolve())
        assert read(str(project / 'absolute-linked').encode(), buffer, 128) < 0
        extraction_root = work / 'extraction'
        extraction_root.mkdir()
        archive = ustar('src/main.elisa', b'def main() -> i64:\n    return 0\n')
        archive_buffer = ctypes.create_string_buffer(archive)
        assert extract_ustar(archive_buffer, len(archive), str(extraction_root).encode()) == 0
        assert (extraction_root / 'src/main.elisa').read_bytes().startswith(b'def main')
        traversal_root = work / 'traversal-extraction'
        traversal_root.mkdir()
        traversal = ustar('../escape', b'escape')
        traversal_buffer = ctypes.create_string_buffer(traversal)
        assert extract_ustar(traversal_buffer, len(traversal), str(traversal_root).encode()) < 0
        assert not (work / 'escape').exists()
        nonempty_root = work / 'nonempty-extraction'
        nonempty_root.mkdir()
        (nonempty_root / 'keep').write_text('keep')
        assert extract_ustar(archive_buffer, len(archive), str(nonempty_root).encode()) < 0
        assert (nonempty_root / 'keep').read_text() == 'keep'
    finally:
        os.chdir(previous)
    sleepy = os.fork()
    if sleepy == 0:
        os.execl('/bin/sleep', 'sleep', '5')
    child_status = ctypes.c_longlong()
    assert wait_timeout(sleepy, ctypes.byref(child_status), 50) == timeout_error()
    try:
        os.kill(sleepy, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError('timed-out child still exists')
print('review regressions passed')
