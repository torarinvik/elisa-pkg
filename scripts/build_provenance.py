#!/usr/bin/env python3
"""Create a pinned-toolchain provenance manifest and macOS release candidate."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
from typing import Mapping


GIT_SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
MAX_MANIFEST_BYTES = 1024 * 1024


class ProvenanceError(Exception):
    """An input does not describe the expected clean, pinned build."""


def command_output(argv: list[str], env: Mapping[str, str]) -> str:
    try:
        result = subprocess.run(
            argv,
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            env=dict(env),
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ProvenanceError(f"could not run {argv[0]}: {error}") from error
    output = result.stdout.strip()
    if not output or len(output) > 8192:
        raise ProvenanceError(f"{argv[0]} returned empty or oversized version output")
    return output


def required_env(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "")
    if not value or "\x00" in value:
        raise ProvenanceError(f"required build environment value is missing: {name}")
    return value


def resolved_file(
    path: str | Path,
    label: str,
    *,
    executable: bool = False,
    reject_symlink: bool = False,
) -> Path:
    try:
        candidate = Path(path)
        info = candidate.lstat()
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError(f"{label} is unavailable: {path}: {error}") from error
    if stat.S_ISLNK(info.st_mode):
        if reject_symlink:
            raise ProvenanceError(f"{label} must not be a symbolic link: {path}")
        try:
            info = resolved.stat()
        except OSError as error:
            raise ProvenanceError(f"{label} target is unavailable: {path}: {error}") from error
    if not stat.S_ISREG(info.st_mode):
        raise ProvenanceError(f"{label} must be a regular file: {path}")
    if executable and not os.access(resolved, os.X_OK):
        raise ProvenanceError(f"{label} is not executable: {path}")
    return resolved


def require_within(path: Path, root: Path, label: str) -> None:
    try:
        path.relative_to(root)
    except ValueError as error:
        raise ProvenanceError(f"{label} resolves outside its pinned source tree") from error


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise ProvenanceError(f"could not hash {path}: {error}") from error
    return digest.hexdigest()


def file_record(path: Path) -> dict[str, int | str]:
    info = path.stat()
    return {"sha256": sha256_file(path), "size_bytes": info.st_size}


def git_environment(env: Mapping[str, str]) -> dict[str, str]:
    # Git honors environment overrides that can redirect even an explicit -C
    # invocation to a different repository or index. The build does not need
    # any caller-provided GIT_* setting to inspect these pinned checkouts.
    clean = {key: value for key, value in env.items() if not key.startswith("GIT_")}
    clean["GIT_CONFIG_NOSYSTEM"] = "1"
    clean["GIT_CONFIG_GLOBAL"] = os.devnull
    clean["GIT_OPTIONAL_LOCKS"] = "0"
    return clean


def git_identity(root: Path, expected: str, label: str, env: Mapping[str, str]) -> str:
    if not GIT_SHA_RE.fullmatch(expected):
        raise ProvenanceError(f"{label} pin must be a full 40-character Git commit")
    clean_env = git_environment(env)
    top_level = command_output(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], clean_env
    )
    if Path(top_level).resolve() != root:
        raise ProvenanceError(f"{label} path must name the root of its Git checkout")
    revision = command_output(["git", "-C", str(root), "rev-parse", "HEAD"], clean_env)
    if revision != expected:
        raise ProvenanceError(f"{label} checkout does not match its configured pin")
    status = command_output_allow_empty(
        [
            "git",
            "-C",
            str(root),
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignore-submodules=none",
        ],
        clean_env,
    )
    if status:
        raise ProvenanceError(f"{label} checkout has tracked or untracked changes")
    return revision


def command_output_allow_empty(argv: list[str], env: Mapping[str, str]) -> str:
    try:
        result = subprocess.run(
            argv,
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            env=dict(env),
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ProvenanceError(f"could not run {argv[0]}: {error}") from error
    return result.stdout.strip()


def host_identity(env: Mapping[str, str]) -> dict[str, str | None]:
    runner_os = required_env(env, "RUNNER_OS")
    runner_arch = required_env(env, "RUNNER_ARCH")
    system = platform.system()
    machine = platform.machine().lower()
    if runner_os != "macOS" or system != "Darwin":
        raise ProvenanceError("release candidates must be built on the macOS runner")
    if runner_arch.upper() != "ARM64" or machine not in {"arm64", "aarch64"}:
        raise ProvenanceError("release candidates must target Apple Silicon")
    return {
        "system": "macOS",
        "architecture": "arm64",
        "version": command_output(["sw_vers", "-productVersion"], env),
        "runner_image": env.get("ImageOS"),
        "runner_image_version": env.get("ImageVersion"),
        "xcode": command_output(["xcodebuild", "-version"], env),
    }


def locate_executable(name: str, env: Mapping[str, str]) -> Path:
    found = shutil.which(name, path=env.get("PATH"))
    if not found:
        raise ProvenanceError(f"required build tool is unavailable: {name}")
    return resolved_file(found, name, executable=True)


def atomic_write(path: Path, content: bytes, mode: int = 0o644) -> None:
    temporary_name = ""
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
        temporary_name = ""
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as error:
        raise ProvenanceError(f"could not durably write {path}: {error}") from error
    finally:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def add_tar_file(archive: tarfile.TarFile, path: Path, name: str, mode: int) -> None:
    size = path.stat().st_size
    info = tarfile.TarInfo(name)
    info.size = size
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    info.type = tarfile.REGTYPE
    with path.open("rb") as stream:
        archive.addfile(info, stream)


def create_archive(binary: Path, manifest: Path, output: Path) -> None:
    temporary_name = ""
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
        with os.fdopen(descriptor, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    binary_mode = stat.S_IMODE(binary.stat().st_mode)
                    add_tar_file(archive, binary, "elisapkg", binary_mode)
                    add_tar_file(archive, manifest, "elisapkg.provenance.json", 0o644)
            raw.flush()
            os.fchmod(raw.fileno(), 0o644)
            os.fsync(raw.fileno())
        os.replace(temporary_name, output)
        temporary_name = ""
        directory_fd = os.open(output.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as error:
        raise ProvenanceError(f"could not create release candidate archive: {error}") from error
    finally:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def generate_candidate(
    *,
    project_root: Path,
    binary_input: Path,
    compiler_root_input: Path,
    core_root_input: Path,
    stage0_input: Path,
    stage1_input: Path,
    wrapper_input: Path,
    runtime_input: Path,
    clang_input: Path,
    llvm_config_input: Path,
    output_dir_input: Path,
    env: Mapping[str, str],
    host: dict[str, str | None] | None = None,
) -> tuple[Path, Path, Path]:
    try:
        project_root_argument = Path(project_root)
        project_root_lexical = Path(os.path.normpath(os.path.abspath(project_root_argument)))
        project_root = project_root_argument.resolve(strict=True)
        compiler_root = compiler_root_input.resolve(strict=True)
        core_root = core_root_input.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError(f"a source or output directory is unavailable: {error}") from error
    output_path_lexical = Path(os.path.normpath(os.path.abspath(output_dir_input)))
    try:
        output_relative = output_path_lexical.relative_to(project_root_lexical)
    except ValueError as error:
        raise ProvenanceError("candidate output directory must be below the project root") from error
    output_dir = project_root / output_relative
    require_within(output_dir, project_root, "candidate output directory")
    current = project_root
    try:
        for component in output_dir.relative_to(project_root).parts:
            current = current / component
            try:
                info = current.lstat()
            except FileNotFoundError:
                current.mkdir()
                info = current.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise ProvenanceError(
                    f"candidate output path contains a non-directory or symlink: {current}"
                )
        output_dir = output_dir.resolve(strict=True)
    except OSError as error:
        raise ProvenanceError(f"a source or output directory is unavailable: {error}") from error

    if required_env(env, "GITHUB_EVENT_NAME") != "push" or required_env(env, "GITHUB_REF") != "refs/heads/main":
        raise ProvenanceError("release candidate artifacts are limited to pushes on main")
    repository = required_env(env, "GITHUB_REPOSITORY")
    workflow_ref = required_env(env, "GITHUB_WORKFLOW_REF")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ProvenanceError("GITHUB_REPOSITORY is not a valid owner/repository identity")
    expected_workflow_ref = (
        f"{repository}/.github/workflows/macos-ci.yml@refs/heads/main"
    )
    if workflow_ref != expected_workflow_ref:
        raise ProvenanceError("release candidates must use the macOS CI workflow on main")

    source_revision = git_identity(
        project_root, required_env(env, "GITHUB_SHA"), "elisapkg", env
    )
    compiler_revision = git_identity(
        compiler_root, required_env(env, "ELISA_COMPILER_SHA"), "Elisa compiler", env
    )
    core_revision = git_identity(
        core_root, required_env(env, "ELISA_CORE_SHA"), "Elisa core", env
    )

    binary = resolved_file(
        binary_input, "elisapkg executable", executable=True, reject_symlink=True
    )
    require_within(binary, project_root, "elisapkg executable")
    if stat.S_IMODE(binary.stat().st_mode) != 0o755:
        raise ProvenanceError("elisapkg executable must have normalized mode 0755")
    compiler_wrapper = resolved_file(wrapper_input, "compiler wrapper", executable=True)
    stage1 = resolved_file(stage1_input, "stage1 compiler", executable=True)
    runtime = resolved_file(runtime_input, "Elisa runtime object")
    stage0 = resolved_file(stage0_input, "stage0 compiler", executable=True)
    require_within(compiler_wrapper, compiler_root, "compiler wrapper")
    require_within(stage1, compiler_root, "stage1 compiler")
    require_within(runtime, compiler_root, "Elisa runtime object")
    require_within(stage0, core_root, "stage0 compiler")

    clang = resolved_file(clang_input, "LLVM clang", executable=True)
    llvm_config = resolved_file(llvm_config_input, "LLVM config", executable=True)
    go = locate_executable("go", env)
    go_version = command_output([str(go), "version"], env)
    expected_go = required_env(env, "ELISA_GO_VERSION")
    if not re.search(rf"\bgo{re.escape(expected_go)}(?:\s|$)", go_version):
        raise ProvenanceError("active Go toolchain does not match the configured exact version")
    llvm_version = command_output([str(llvm_config), "--version"], env)
    expected_llvm = required_env(env, "ELISA_LLVM_VERSION")
    if llvm_version != expected_llvm:
        raise ProvenanceError("active LLVM toolchain does not match the configured exact version")
    host = host_identity(env) if host is None else host
    if host.get("system") != "macOS" or host.get("architecture") != "arm64":
        raise ProvenanceError("release candidate host identity must be macOS arm64")

    run_id = required_env(env, "GITHUB_RUN_ID")
    run_attempt = required_env(env, "GITHUB_RUN_ATTEMPT")
    manifest: dict[str, object] = {
        "schema_version": 1,
        "source": {
            "repository": repository,
            "revision": source_revision,
            "ref": env["GITHUB_REF"],
            "event": env["GITHUB_EVENT_NAME"],
        },
        "builder": {
            "provider": "GitHub Actions",
            "workflow": workflow_ref,
            "run_id": run_id,
            "run_attempt": run_attempt,
            "platform": host,
        },
        "toolchain": {
            "elisa_compiler": {
                "source_revision": compiler_revision,
                "wrapper": file_record(compiler_wrapper),
                "stage1": file_record(stage1),
            },
            "elisa_core": {
                "source_revision": core_revision,
                "stage0": file_record(stage0),
            },
            "runtime_object": file_record(runtime),
            "go": {"version": go_version, "executable": file_record(go)},
            "llvm": {
                "version": llvm_version,
                "clang": file_record(clang),
                "llvm_config": file_record(llvm_config),
            },
        },
        "artifact": {
            "name": "elisapkg",
            "file": "elisapkg",
            "sha256": sha256_file(binary),
            "size_bytes": binary.stat().st_size,
            "mode": f"{stat.S_IMODE(binary.stat().st_mode):04o}",
        },
    }
    manifest_bytes = (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if len(manifest_bytes) > MAX_MANIFEST_BYTES:
        raise ProvenanceError("generated provenance manifest exceeds its size limit")

    manifest_path = output_dir / "elisapkg.provenance.json"
    archive_path = output_dir / "elisapkg-macos-arm64.tar.gz"
    checksum_path = output_dir / "elisapkg-macos-arm64.tar.gz.sha256"
    atomic_write(manifest_path, manifest_bytes)
    create_archive(binary, manifest_path, archive_path)
    checksum = f"{sha256_file(archive_path)}  {archive_path.name}\n".encode("ascii")
    atomic_write(checksum_path, checksum)
    return manifest_path, archive_path, checksum_path


def argument_path(parser: argparse.ArgumentParser, name: str, env: Mapping[str, str]) -> Path:
    value = env.get(name)
    if not value:
        parser.error(f"required environment path is missing: {name}")
    return Path(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--binary", type=Path, default=Path("build/elisapkg"))
    parser.add_argument("--output-dir", type=Path, default=Path("build/release-candidate"))
    args = parser.parse_args()
    env = os.environ
    try:
        manifest, archive, checksum = generate_candidate(
            project_root=args.project_root,
            binary_input=args.project_root / args.binary,
            compiler_root_input=argument_path(parser, "ELISA_COMPILER_ROOT", env),
            core_root_input=argument_path(parser, "ELISA_CORE", env),
            stage0_input=argument_path(parser, "ELISACORE_BIN", env),
            stage1_input=argument_path(parser, "ELISA_STAGE1_BIN", env),
            wrapper_input=argument_path(parser, "ELISA_COMPILER_WRAPPER", env),
            runtime_input=argument_path(parser, "ELISA_RUNTIME_OBJ", env),
            clang_input=argument_path(parser, "ELISA_CLANG", env),
            llvm_config_input=argument_path(parser, "LLVM_CONFIG", env),
            output_dir_input=args.project_root / args.output_dir,
            env=env,
        )
    except ProvenanceError as error:
        parser.exit(1, f"error: {error}\n")
    print(f"wrote {manifest}")
    print(f"wrote {archive}")
    print(f"wrote {checksum}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
