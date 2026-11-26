#!/usr/bin/env python3
"""Check provenance pinning and deterministic release-candidate packaging."""

from __future__ import annotations

import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_provenance", ROOT / "scripts/build_provenance.py")
if SPEC is None or SPEC.loader is None:
    raise SystemExit("error: could not load build provenance implementation")
provenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provenance)


def run(args: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )
    return result.stdout.strip()


def initialize_repo(path: Path, name: str, files: dict[str, bytes]) -> str:
    path.mkdir(parents=True)
    run(["git", "init", "--quiet", str(path)])
    run(["git", "-C", str(path), "config", "user.name", "Provenance Test"])
    run(["git", "-C", str(path), "config", "user.email", "provenance@example.invalid"])
    run(["git", "-C", str(path), "branch", "-M", "main"])
    for relative, content in files.items():
        target = path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    run(["git", "-C", str(path), "add", "-A"])
    run(["git", "-C", str(path), "commit", "--quiet", "-m", name])
    return run(["git", "-C", str(path), "rev-parse", "HEAD"])


def write_executable(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    path.chmod(0o755)


def create_fixture(root: Path) -> tuple[dict[str, object], dict[str, str], Path]:
    project = root / "project"
    compiler = root / "Elisa-compiler"
    core = root / "Elisa-core"
    project_sha = initialize_repo(project, "project", {".gitignore": b"build/\n", "README.md": b"fixture\n"})
    compiler_sha = initialize_repo(
        compiler,
        "compiler",
        {".gitignore": b"bin/\nbuild/\nscripts/elisac_stage1.sh\n", "README.md": b"compiler fixture\n"},
    )
    core_sha = initialize_repo(
        core,
        "core",
        {".gitignore": b"compiler/bin/\n", "README.md": b"core fixture\n"},
    )

    binary = project / "build/elisapkg"
    write_executable(binary, b"\x7fELF\x00elisapkg test executable\n")
    write_executable(compiler / "scripts/elisac_stage1.sh", b"#!/bin/sh\nexit 0\n")
    write_executable(compiler / "bin/elisac-stage1", b"stage1 bytes\n")
    write_executable(core / "compiler/bin/elisac", b"stage0 bytes\n")
    (compiler / "build/runtime").mkdir(parents=True)
    (compiler / "build/runtime/elisacore_runtime.o").write_bytes(b"runtime object\n")

    tool_bin = root / "fake-bin"
    write_executable(tool_bin / "go", b"#!/bin/sh\nprintf '%s\\n' 'go version go1.25.0 darwin/arm64'\n")
    write_executable(tool_bin / "xcodebuild", b"#!/bin/sh\nprintf '%s\\n' 'Xcode 26.0' 'Build version 17A123'\n")
    write_executable(tool_bin / "sw_vers", b"#!/bin/sh\nprintf '%s\\n' '15.6'\n")
    llvm_config = root / "llvm-config"
    write_executable(llvm_config, b"#!/bin/sh\nprintf '%s\\n' '23.1.1'\n")
    clang = root / "clang"
    write_executable(clang, b"#!/bin/sh\nexit 0\n")

    env = dict(os.environ)
    env.update(
        {
            "PATH": str(tool_bin) + os.pathsep + os.environ.get("PATH", ""),
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": "example/elisapkg",
            "GITHUB_SHA": project_sha,
            "GITHUB_WORKFLOW_REF": "example/elisapkg/.github/workflows/macos-ci.yml@refs/heads/main",
            "GITHUB_RUN_ID": "1234",
            "GITHUB_RUN_ATTEMPT": "1",
            "GIT_DIR": "/definitely/not/the/checkout",
            "RUNNER_OS": "macOS",
            "RUNNER_ARCH": "ARM64",
            "ImageOS": "macos15",
            "ImageVersion": "2026.09.01.1",
            "ELISA_COMPILER_SHA": compiler_sha,
            "ELISA_CORE_SHA": core_sha,
            "ELISA_GO_VERSION": "1.25.0",
            "ELISA_LLVM_VERSION": "23.1.1",
        }
    )
    inputs: dict[str, object] = {
        "project_root": project,
        "binary_input": binary,
        "compiler_root_input": compiler,
        "core_root_input": core,
        "stage0_input": core / "compiler/bin/elisac",
        "stage1_input": compiler / "bin/elisac-stage1",
        "wrapper_input": compiler / "scripts/elisac_stage1.sh",
        "runtime_input": compiler / "build/runtime/elisacore_runtime.o",
        "clang_input": clang,
        "llvm_config_input": llvm_config,
        "output_dir_input": project / "build/release-candidate",
        "env": env,
        "host": {
            "system": "macOS",
            "architecture": "arm64",
            "version": "15.6",
            "runner_image": "macos15",
            "runner_image_version": "2026.09.01.1",
            "xcode": "Xcode 26.0\nBuild version 17A123",
        },
    }
    return inputs, env, binary


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="elisapkg-provenance-") as temporary:
        inputs, env, binary = create_fixture(Path(temporary))
        manifest_path, archive_path, checksum_path = provenance.generate_candidate(**inputs)
        manifest_bytes = manifest_path.read_bytes()
        archive_bytes = archive_path.read_bytes()
        manifest = json.loads(manifest_bytes)
        artifact_digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        if manifest["artifact"]["sha256"] != artifact_digest:
            raise SystemExit("error: provenance manifest does not bind the compiled artifact digest")
        if manifest["source"]["revision"] != env["GITHUB_SHA"]:
            raise SystemExit("error: provenance manifest does not bind the source commit")
        if manifest["toolchain"]["elisa_compiler"]["source_revision"] != env["ELISA_COMPILER_SHA"]:
            raise SystemExit("error: provenance manifest does not bind the pinned compiler commit")
        if manifest["toolchain"]["elisa_core"]["source_revision"] != env["ELISA_CORE_SHA"]:
            raise SystemExit("error: provenance manifest does not bind the pinned core commit")
        with tarfile.open(archive_path, "r:gz") as archive:
            members = archive.getmembers()
            if [member.name for member in members] != ["elisapkg", "elisapkg.provenance.json"]:
                raise SystemExit("error: release candidate archive contains an unexpected member set")
            if any(not member.isfile() or member.uid != 0 or member.gid != 0 or member.mtime != 0 for member in members):
                raise SystemExit("error: release candidate archive metadata is not normalized")
            if archive.extractfile(members[0]).read() != binary.read_bytes():
                raise SystemExit("error: release candidate archive changed the executable bytes")
            if archive.extractfile(members[1]).read() != manifest_bytes:
                raise SystemExit("error: release candidate archive changed its provenance manifest")
        with gzip.open(archive_path, "rb") as compressed:
            expanded_archive = compressed.read()
        expected_tar_size = (
            512
            + ((binary.stat().st_size + 511) // 512) * 512
            + 512
            + ((len(manifest_bytes) + 511) // 512) * 512
            + 1024
        )
        expected_tar_size = (
            (expected_tar_size + tarfile.RECORDSIZE - 1) // tarfile.RECORDSIZE
        ) * tarfile.RECORDSIZE
        if len(expanded_archive) != expected_tar_size:
            raise SystemExit("error: release candidate archive does not have the expected bounded tar size")
        expected_checksum = f"{hashlib.sha256(archive_bytes).hexdigest()}  {archive_path.name}\n"
        if checksum_path.read_text(encoding="ascii") != expected_checksum:
            raise SystemExit("error: release candidate checksum does not match the archive")

        invalid_archive = archive_path.parent / "invalid.tar.gz"
        for manifest_mode, extra_member in ((0o600, False), (0o644, True)):
            with tarfile.open(invalid_archive, "w:gz", format=tarfile.USTAR_FORMAT) as archive:
                provenance.add_tar_file(archive, binary, "elisapkg", 0o755)
                provenance.add_tar_file(archive, manifest_path, "elisapkg.provenance.json", manifest_mode)
                if extra_member:
                    provenance.add_tar_file(archive, manifest_path, "unexpected.json", 0o644)
            try:
                provenance.verify_archive(invalid_archive, artifact_digest, binary.stat().st_size, manifest_bytes)
            except provenance.ProvenanceError:
                pass
            else:
                raise SystemExit("error: release archive verifier accepted a noncanonical archive")
        invalid_archive.unlink()

        for invalid_bytes in (
            archive_bytes[:-4],
            archive_bytes + gzip.compress(b"extra"),
            gzip.compress(expanded_archive[:-1] + b"\x01"),
        ):
            invalid_archive.write_bytes(invalid_bytes)
            try:
                provenance.verify_archive(invalid_archive, artifact_digest, binary.stat().st_size, manifest_bytes)
            except provenance.ProvenanceError:
                pass
            else:
                raise SystemExit("error: release archive verifier accepted invalid gzip or tar padding")
        invalid_archive.unlink()

        provenance.generate_candidate(**inputs)
        if manifest_path.read_bytes() != manifest_bytes or archive_path.read_bytes() != archive_bytes:
            raise SystemExit("error: identical release candidate inputs produced different archive bytes")

        symlink = binary.parent / "elisapkg-alias"
        symlink.symlink_to(binary)
        symlink_inputs = dict(inputs)
        symlink_inputs["binary_input"] = symlink
        try:
            provenance.generate_candidate(**symlink_inputs)
        except provenance.ProvenanceError:
            pass
        else:
            raise SystemExit("error: release candidate accepted a symlinked executable input")
        finally:
            symlink.unlink()

        output_link = inputs["project_root"] / "build/release-candidate-alias"
        output_link.symlink_to(inputs["output_dir_input"], target_is_directory=True)
        symlink_output_inputs = dict(inputs)
        symlink_output_inputs["output_dir_input"] = output_link
        try:
            provenance.generate_candidate(**symlink_output_inputs)
        except provenance.ProvenanceError:
            pass
        else:
            raise SystemExit("error: release candidate followed a symlinked output directory")
        finally:
            output_link.unlink()

        wrong_pin_inputs = dict(inputs)
        wrong_pin_env = dict(env)
        wrong_pin_env["ELISA_COMPILER_SHA"] = "0" * 40
        wrong_pin_inputs["env"] = wrong_pin_env
        unverified_output = inputs["project_root"] / "build/unverified/candidate"
        wrong_pin_inputs["output_dir_input"] = unverified_output
        try:
            provenance.generate_candidate(**wrong_pin_inputs)
        except provenance.ProvenanceError:
            pass
        else:
            raise SystemExit("error: release candidate accepted a compiler checkout with a wrong pin")
        if unverified_output.parent.exists():
            raise SystemExit("error: rejected release candidate created an output directory")

        runtime = inputs["runtime_input"]
        original_runtime = runtime.read_bytes()
        runtime.write_bytes(b"")
        try:
            provenance.generate_candidate(**{**inputs, "output_dir_input": unverified_output})
        except provenance.ProvenanceError as error:
            if "nonempty regular file" not in str(error):
                raise
        else:
            raise SystemExit("error: release candidate accepted an empty runtime object")
        finally:
            runtime.write_bytes(original_runtime)
        if unverified_output.parent.exists():
            raise SystemExit("error: empty toolchain input created an output directory")

        project_root = inputs["project_root"]
        try:
            provenance.generate_candidate(**{**inputs, "output_dir_input": project_root})
        except provenance.ProvenanceError:
            pass
        else:
            raise SystemExit("error: release candidate accepted the project root as its output directory")

        tracked_file = project_root / "README.md"
        original = tracked_file.read_bytes()
        tracked_file.write_bytes(original + b"dirty\n")
        try:
            provenance.generate_candidate(**inputs)
        except provenance.ProvenanceError:
            pass
        else:
            raise SystemExit("error: release candidate accepted a modified source checkout")
        tracked_file.write_bytes(original)

    print("Elisa build provenance regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
