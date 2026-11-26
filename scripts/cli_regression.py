#!/usr/bin/env python3
"""Exercise package commands and their exit and output contracts."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'build/elisapkg'


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], timeout=120, check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='cli-review-', dir=ROOT / 'build') as directory:
    work = Path(directory)
    run([BIN, 'init', work / 'project'], stdout=subprocess.DEVNULL)
    project = work / 'project'
    conflict_init = subprocess.run([BIN, 'init', work / 'conflict', '--lib', '--bin'], capture_output=True, timeout=120, check=False)
    assert conflict_init.returncode == 2, conflict_init
    run([BIN, 'resolve'], cwd=project, stdout=subprocess.DEVNULL)
    check_manifest_json = subprocess.run([BIN, 'check-manifest', '--json'], cwd=project, capture_output=True, text=True, timeout=120, check=True)
    assert json.loads(check_manifest_json.stdout) == {'schema-version': 1, 'valid': True, 'manifest': 'elisapkg.json'}
    resolved_json = subprocess.run([BIN, 'resolve', '--json'], cwd=project, capture_output=True, text=True, timeout=120, check=True)
    assert json.loads(resolved_json.stdout) == {'schema-version': 1, 'resolved': True, 'package': {'name': 'app', 'version': '0.1.0'}}
    tree_json = subprocess.run([BIN, 'tree', '--json'], cwd=project, capture_output=True, text=True, timeout=120, check=True)
    assert json.loads(tree_json.stdout) == {'schema-version': 1, 'packages': [{'name': 'app', 'version': '0.1.0'}]}
    for command in [['resolve', 'unexpected'], ['check-manifest', 'unexpected']]:
        result = subprocess.run([BIN, *command], cwd=project, capture_output=True, timeout=120, check=False)
        assert result.returncode == 2, (command, result)
    result = subprocess.run([BIN, 'fetch', 'foo', '1.0.0-alpha'], cwd=project, capture_output=True, timeout=120, check=False)
    assert result.returncode == 2, result
    for command in [['resolve', '--list'], ['build', '--dry-run'], ['build', '--version']]:
        result = subprocess.run([BIN, *command], cwd=project, capture_output=True, timeout=120, check=False)
        assert result.returncode == 2, (command, result)
    blocked_project = work / 'blocked'
    run([BIN, 'init', blocked_project], stdout=subprocess.DEVNULL)
    state = blocked_project / '.elisapkg'
    state.mkdir(exist_ok=True)
    guard = state / 'transaction.guard'
    guard.write_bytes(b'not a transaction directory')
    result = subprocess.run([BIN, 'check-manifest', '--unexpected'], cwd=blocked_project,
                            capture_output=True, timeout=120, check=False)
    assert result.returncode == 2 and guard.read_bytes() == b'not a transaction directory', result
    for command in (
        ['add'],
        ['add', 'foo', '--path', '/absolute'],
        ['add', 'foo', '--version', 'not-a-version', '--registry', 'primary'],
        ['remove', 'INVALID'],
        ['update', 'foo', 'extra'],
    ):
        result = subprocess.run([BIN, *command], cwd=blocked_project,
                                capture_output=True, timeout=120, check=False)
        assert result.returncode == 2, (command, result)
        assert guard.read_bytes() == b'not a transaction directory'
    result = subprocess.run([BIN, 'check-manifest'], cwd=blocked_project,
                            capture_output=True, timeout=120, check=False)
    assert result.returncode == 5, result
    result = subprocess.run([BIN, 'doctor'], cwd=blocked_project,
                            capture_output=True, timeout=120, check=False)
    assert result.returncode == 0 and b'elisapkg doctor\n' in result.stdout, result
    assert guard.read_bytes() == b'not a transaction directory'
    duplicate_manifest_path = subprocess.run([BIN, 'check-manifest', '--manifest-path', project / 'elisapkg.json', '--manifest-path', project / 'elisapkg.json'], capture_output=True, timeout=120, check=False)
    assert duplicate_manifest_path.returncode == 2, duplicate_manifest_path
    run([BIN, 'init', work / '--quiet'], stdout=subprocess.DEVNULL)
    result = subprocess.run([BIN, 'check-manifest', '--manifest-path', '--quiet'], cwd=work,
                            capture_output=True, timeout=120, check=False)
    assert result.returncode == 2, result
    run([BIN, 'check-manifest', '--manifest-path', './--quiet'], cwd=work, stdout=subprocess.DEVNULL)
    result = subprocess.run([BIN, 'update', 'missing'], cwd=project, capture_output=True, timeout=120, check=False)
    assert result.returncode == 3, result
    result = subprocess.run([BIN, 'test'], cwd=project, capture_output=True, timeout=120, check=False)
    assert result.returncode == 2, result
    lock = project / 'elisapkg.lock'
    before = lock.stat()
    run([BIN, 'resolve', '--frozen'], cwd=project, stdout=subprocess.DEVNULL)
    after = lock.stat()
    assert (before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns)

    for cache_arguments in (['verify', '--quiet'], ['--quiet', 'verify']):
        quiet_cache_verify = subprocess.run(
            [BIN, 'cache', *cache_arguments], cwd=project,
            capture_output=True, text=True, timeout=120, check=False)
        assert quiet_cache_verify.returncode == 0, quiet_cache_verify
        assert quiet_cache_verify.stdout == ''
    quiet_cache_gc = subprocess.run(
        [BIN, 'cache', 'gc', '--dry-run', '--quiet'], cwd=project,
        capture_output=True, text=True, timeout=120, check=False)
    assert quiet_cache_gc.returncode == 0, quiet_cache_gc
    assert quiet_cache_gc.stdout == ''

    fetch_environment = dict(os.environ)
    fetch_environment.pop('ELISAPKG_REGISTRY_DIR', None)
    fetch_environment.pop('ELISAPKG_REGISTRY_TRUST_ROOT', None)
    colored_fetch = subprocess.run(
        [BIN, 'fetch', 'foo', '1.0.0', '--color', 'always'], cwd=project,
        env=fetch_environment, capture_output=True, text=True, timeout=120,
        check=False)
    assert colored_fetch.returncode == 3, colored_fetch
    assert 'registry is not configured' in colored_fetch.stderr

    library = work / 'library'
    run([BIN, 'init', library, '--lib'], stdout=subprocess.DEVNULL)
    install_environment = dict(
        os.environ, ELISAPKG_INSTALL_PREFIX=str(work / 'install-prefix'))
    quiet_library_install = subprocess.run(
        [BIN, 'install', '--local', '--quiet'], cwd=library,
        env=install_environment, capture_output=True, text=True, timeout=120,
        check=False)
    assert quiet_library_install.returncode == 7, quiet_library_install
    assert 'requires a binary target' in quiet_library_install.stderr

    external = work / 'external'
    external.mkdir()
    (external / 'src').mkdir()
    (external / 'src/main.elisa').write_text('def main() -> i64:\n    return 0\n')
    (external / 'elisapkg.json').write_text(
        '{"schema-version":1,"package":{"name":"external","version":"0.1.0"},'
        '"targets":[{"name":"external","kind":"lib","entry":"src/main.elisa"}],'
        '"dependencies":{"nested-util":{"path":"../nested-util"}}}\n')
    nested = work / 'nested-util'
    nested.mkdir()
    (nested / 'src').mkdir()
    (nested / 'src/main.elisa').write_text('def main() -> i64:\n    return 0\n')
    (nested / 'elisapkg.json').write_text(
        '{"schema-version":1,"package":{"name":"nested-util","version":"0.2.0"},'
        '"targets":[{"name":"nested-util","kind":"lib","entry":"src/main.elisa"}],'
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
    why_json = subprocess.run([BIN, 'why', 'external', '--json'], cwd=parent, capture_output=True, text=True, timeout=120, check=True)
    assert json.loads(why_json.stdout) == {'schema-version': 1, 'root': 'parent', 'package': 'external'}
    root_why = subprocess.run([BIN, 'why', 'parent'], cwd=parent, capture_output=True, timeout=120, check=False)
    assert root_why.returncode == 3, root_why
    transitive_why = subprocess.run([BIN, 'why', 'nested-util'], cwd=parent, capture_output=True, timeout=120, check=False)
    assert transitive_why.returncode == 3, transitive_why

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
    result = subprocess.run([BIN, 'resolve'], cwd=collision_root, capture_output=True, timeout=120, check=False)
    assert result.returncode == 3, result

    manifest = project / 'elisapkg.json'
    valid = manifest.read_text()
    unsupported_registry = valid.replace('"dependencies": {}', '"dependencies":{"remote":{"registry":"default","version":"^1.0.0"}}')
    unsupported_dev = valid.replace('"dev-dependencies": {}', '"dev-dependencies":{"tools":{"path":"../tools"}}')
    misplaced_identity = valid.replace('"targets":', '"name":"shadow","targets":')
    misplaced_package_field = valid.replace('"version": "0.1.0"', '"version": "0.1.0", "entry":"src/main.elisa"', 1)
    misplaced_target_field = valid.replace('"kind": "bin"', '"kind": "bin", "license":"MIT"', 1)
    missing_target_entry = valid.replace(', "entry": "src/main.elisa"', '', 1)
    missing_target_kind = valid.replace(', "kind": "bin"', '', 1)
    for invalid in [valid.replace('"schema-version": 1,', '"schema-version": 1'), valid + '{}', unsupported_registry, unsupported_dev, misplaced_identity, misplaced_package_field, misplaced_target_field, missing_target_entry, missing_target_kind]:
        manifest.write_text(invalid)
        result = subprocess.run([BIN, 'check-manifest'], cwd=project, capture_output=True, timeout=120, check=False)
        assert result.returncode != 0
    manifest.write_text(valid)
    legacy_only = project / 'manifest.json'
    legacy_only.write_text(valid)
    manifest.unlink()
    result = subprocess.run([BIN, 'check-manifest'], cwd=project, capture_output=True, timeout=120, check=False)
    assert result.returncode == 2, result
    manifest.write_text(valid)
    lockfile = project / 'elisapkg.lock'
    original_lock = lockfile.read_bytes()
    for command in (
        ['add', 'other', '--version', '1.0.0', '--registry', 'primary'],
        ['remove', 'other'],
        ['update'],
    ):
        result = subprocess.run([BIN, *command], cwd=project, capture_output=True,
                                timeout=120, check=False)
        assert result.returncode == 2, (command, result)
        assert manifest.read_text() == valid and legacy_only.read_text() == valid
        assert lockfile.read_bytes() == original_lock
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
                            capture_output=True, timeout=120, check=False)
    assert result.returncode == 6, result
    assert artifact.read_bytes() == b'previous working output'

print('CLI regressions passed')
