#!/usr/bin/env python3
"""Exercise the generated macOS compiler profile against hostile Elisa probes."""

from __future__ import annotations

import os
import platform
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "fixtures"
CI_ENABLED = os.environ.get("CI", "").strip().lower() in {"1", "true", "yes"}
REQUIRE_SANDBOX = os.environ.get("ELISAPKG_REQUIRE_SANDBOX_TESTS") == "1" or CI_ENABLED


def unavailable(reason: str) -> int:
    label = "error" if REQUIRE_SANDBOX else "skip"
    print(f"{label}: sandbox policy probes: {reason}", file=sys.stderr if REQUIRE_SANDBOX else sys.stdout)
    return 1 if REQUIRE_SANDBOX else 0


def compile_probe(source: Path, output: Path, compiler_root: Path, env: dict[str, str]) -> None:
    stage1 = compiler_root / "scripts" / "elisac_stage1.sh"
    result = subprocess.run(
        [str(stage1), "-emit", "exe", "-o", str(output), str(source)],
        cwd=FIXTURES,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise RuntimeError(f"could not compile {source.name}:\n{result.stdout}")


def sandbox_apply_available() -> tuple[bool, str]:
    sandbox_exec = Path("/usr/bin/sandbox-exec")
    if not sandbox_exec.is_file() or not os.access(sandbox_exec, os.X_OK):
        return False, "/usr/bin/sandbox-exec is unavailable"
    result = subprocess.run(
        [str(sandbox_exec), "-p", "(version 1)\n(allow default)\n", "/usr/bin/true"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode == 0:
        return True, ""
    diagnostic = result.stderr.strip()
    if "sandbox_apply: Operation not permitted" in diagnostic:
        return False, "the host denies Seatbelt profile application"
    raise RuntimeError(f"permissive sandbox control profile failed ({result.returncode}): {diagnostic}")


def run_sandbox_probe(
    executable: Path,
    profile: Path,
    callback_path: Path,
    env: dict[str, str],
    args: tuple[str, ...] = (),
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [
            "/usr/bin/sandbox-exec",
            "-D",
            f"CALLBACK_PATH={callback_path}",
            "-p",
            str(profile),
            str(executable),
            *args,
        ],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=15,
    )


def start_loopback_listener() -> tuple[socket.socket, threading.Event, threading.Thread]:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(2)
    accepted = threading.Event()

    def accept_one() -> None:
        try:
            connection, _ = listener.accept()
        except (TimeoutError, socket.timeout):
            return
        accepted.set()
        connection.close()

    server_thread = threading.Thread(target=accept_one, daemon=True)
    server_thread.start()
    return listener, accepted, server_thread


def run() -> int:
    if platform.system() != "Darwin":
        return unavailable("these probes require macOS Seatbelt")

    compiler_value = os.environ.get("ELISA_COMPILER_ROOT")
    compiler_root = Path(compiler_value).resolve() if compiler_value else (ROOT.parent / "Elisa-compiler").resolve()
    if not (compiler_root / "scripts" / "elisac_stage1.sh").is_file():
        raise RuntimeError(f"Elisa compiler not found at {compiler_root}; set ELISA_COMPILER_ROOT")

    build_root = ROOT / "build"
    build_root.mkdir(exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix="sandbox-policy.", dir=build_root))
    callback_path: Optional[Path] = None
    callback_decoy_path: Optional[Path] = None
    generated_paths: list[Path] = []
    try:
        project_root = base / "project.with.dots"
        sandbox_build_root = project_root / ".elisapkg" / "build"
        sandbox_work_root = sandbox_build_root / "scratch"
        source_snapshot_root = sandbox_build_root / "source-snapshots"
        tools_root = base / "tools"
        sandbox_work_root.mkdir(parents=True)
        source_snapshot_root.mkdir()
        tools_root.mkdir()
        git_metadata_root = project_root / ".git"
        git_metadata_root.mkdir()
        git_config = git_metadata_root / "config"
        git_config.write_text("[http]\n\textraHeader = Authorization: Bearer test-secret\n")
        git_config_worktree = git_metadata_root / "config.worktree"
        git_config_worktree.write_text("[remote \"origin\"]\n\turl = https://user:test-secret@example.invalid/repo\n")
        source_file = project_root / "src" / "main.elisa"
        source_file.parent.mkdir()
        source_file.write_text("package source remains readable\n")
        snapshot_file = source_snapshot_root / "root" / "src" / "main.elisa"
        snapshot_file.parent.mkdir(parents=True)
        snapshot_file.write_text("verified source snapshot remains readable\n")
        snapshot_credential = source_snapshot_root / "root" / ".env"
        snapshot_credential.write_text("snapshot credential must remain denied\n")
        snapshot_git_state = source_snapshot_root / "root" / ".git" / "config"
        snapshot_git_state.parent.mkdir()
        snapshot_git_state.write_text("snapshot VCS state must remain denied\n")
        snapshot_reserved_state = source_snapshot_root / "build" / "stale-input.elisa"
        snapshot_reserved_state.parent.mkdir()
        snapshot_reserved_state.write_text("snapshot build state must remain denied\n")
        snapshot_nested_source = source_snapshot_root / "root" / "src" / ".build" / "nested-source.elisa"
        snapshot_nested_source.parent.mkdir()
        snapshot_nested_source.write_text("nested package source remains readable\n")
        hidden_state_files = (
            project_root / ".elisapkg" / "stale-input.elisa",
            project_root / "build" / "stale-input.elisa",
            project_root / "target" / "stale-input.elisa",
            project_root / "src" / ".hg",
            project_root / "src" / ".svn",
            project_root / "src" / "IMPLEMENTATION_PLAN.md",
        )
        for hidden_state_file in hidden_state_files:
            hidden_state_file.parent.mkdir(parents=True, exist_ok=True)
            hidden_state_file.write_text("must not become an untracked compiler input\n")
        scratch_source = sandbox_work_root / "aggregate.elisa"
        scratch_source.write_text("private generated build input remains readable\n")
        nested_source_files = (
            project_root / "src" / ".elisapkg" / "nested-source.elisa",
            project_root / "src" / "build" / "nested-source.elisa",
            project_root / "src" / "target" / "nested-source.elisa",
        )
        for nested_source_file in nested_source_files:
            nested_source_file.parent.mkdir(parents=True, exist_ok=True)
            nested_source_file.write_text("nested source state is fingerprinted\n")
        output_temp = sandbox_work_root / "output-probe"
        output_temp.write_bytes(b"parent-owned output placeholder\n")

        callback_probe = tools_root / "sandbox-callback-probe"
        profile_probe = tools_root / "sandbox-profile-probe"
        env = os.environ.copy()
        env.pop("BASH_ENV", None)
        env.pop("ENV", None)
        env["ELISA_STAGE1_BIN"] = env.get("ELISA_STAGE1_BIN", str(compiler_root / "bin" / "elisac-stage1"))
        env["ELISA_RUNTIME_OBJ"] = env.get("ELISA_RUNTIME_OBJ", str(compiler_root / "build" / "runtime" / "elisacore_runtime.o"))
        env["ELISA_ALLOW_STALE_STAGE1"] = env.get("ELISA_ALLOW_STALE_STAGE1", "0")

        compile_probe(FIXTURES / "sandbox_callback_probe.elisa", callback_probe, compiler_root, env)
        compile_probe(FIXTURES / "sandbox_profile_probe.elisa", profile_probe, compiler_root, env)

        callback_path = Path("/private/tmp") / f"elisapkg-policy-{os.getpid()}-{os.urandom(8).hex()}.c"
        callback_decoy_path = Path(f"{callback_path}.decoy")
        generated_paths = [
            callback_decoy_path,
            Path(f"{callback_path}.sibling"),
            Path(f"{callback_path}.link"),
            Path(f"{callback_path}.renamed"),
        ]
        callback_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(callback_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            os.write(fd, b"parent sentinel bytes\n")
        finally:
            os.close(fd)
        initial_stat = callback_path.lstat()
        decoy_contents = b"unrelated inode must stay unchanged\n"
        fd = os.open(callback_decoy_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            os.write(fd, decoy_contents)
        finally:
            os.close(fd)
        initial_decoy_stat = callback_decoy_path.lstat()

        env["ELISAPKG_TEST_PROJECT_ROOT"] = str(project_root.resolve())
        env["ELISAPKG_TEST_BUILD_ROOT"] = str(sandbox_work_root.resolve())
        env["ELISAPKG_TEST_SOURCE_SNAPSHOT"] = str(source_snapshot_root.resolve())
        env["ELISAPKG_TEST_OUTPUT"] = str(output_temp.resolve())
        env["ELISAPKG_TEST_EXECUTABLE_ONE"] = "/bin/bash"
        env["ELISAPKG_TEST_EXECUTABLE_TWO"] = str(callback_probe.resolve())
        env["ELISAPKG_TEST_CALLBACK_PATH"] = str(callback_path)
        env["ELISAPKG_TEST_DECOY_PATH"] = str(callback_decoy_path)
        env["ELISAPKG_TEST_GIT_CONFIG"] = str(git_config)
        env["ELISAPKG_TEST_GIT_CONFIG_WORKTREE"] = str(git_config_worktree)
        env["ELISAPKG_TEST_SOURCE_FILE"] = str(source_file)
        env["ELISAPKG_TEST_SNAPSHOT_FILE"] = str(snapshot_file.resolve())
        env["ELISAPKG_TEST_SNAPSHOT_CREDENTIAL"] = str(snapshot_credential.resolve())
        env["ELISAPKG_TEST_SNAPSHOT_GIT_STATE"] = str(snapshot_git_state.resolve())
        env["ELISAPKG_TEST_SNAPSHOT_RESERVED_STATE"] = str(snapshot_reserved_state.resolve())
        env["ELISAPKG_TEST_SNAPSHOT_NESTED_SOURCE"] = str(snapshot_nested_source.resolve())
        env["ELISAPKG_TEST_STALE_INPUTS"] = "\n".join(str(path) for path in hidden_state_files)
        env["ELISAPKG_TEST_NESTED_INPUTS"] = "\n".join(str(path) for path in nested_source_files)
        env["ELISAPKG_TEST_SCRATCH_SOURCE"] = str(scratch_source)

        profile_result = subprocess.run(
            [str(profile_probe)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )
        if profile_result.returncode != 0 or not profile_result.stdout.startswith(b"(version 1)"):
            diagnostic = (profile_result.stdout + profile_result.stderr).decode(errors="replace")
            raise RuntimeError(f"could not generate the production sandbox profile: {diagnostic}")
        if b"(deny network*)" not in profile_result.stdout:
            raise RuntimeError("generated compiler profile omitted the network denial")
        if b'(allow file-write-data (literal (param "CALLBACK_PATH")))' not in profile_result.stdout:
            raise RuntimeError("generated compiler profile omitted the exact callback data-write rule")
        for state_root in (
            project_root / ".elisapkg",
            project_root / "build",
            project_root / "target",
        ):
            expected_deny = f'(deny file-read* (subpath "{state_root.resolve()}"))'.encode()
            if expected_deny not in profile_result.stdout:
                raise RuntimeError(f"generated compiler profile omitted source-state denial for {state_root.name}")
        expected_scratch_allow = (
            f'(allow file-read* (subpath "{sandbox_work_root.resolve()}"))'.encode()
        )
        if expected_scratch_allow not in profile_result.stdout:
            raise RuntimeError("generated compiler profile omitted its exact private-scratch read rule")
        expected_snapshot_allow = (
            f'(allow file-read* (subpath "{source_snapshot_root.resolve()}"))'.encode()
        )
        expected_snapshot_deny_write = (
            f'(deny file-write* (subpath "{source_snapshot_root.resolve()}"))'.encode()
        )
        if expected_snapshot_allow not in profile_result.stdout:
            raise RuntimeError("generated compiler profile omitted its exact verified-source read rule")
        if expected_snapshot_deny_write not in profile_result.stdout:
            raise RuntimeError("generated compiler profile omitted the verified-source write denial")
        denial_patterns = [
            re.compile(pattern.decode("ascii"))
            for pattern in re.findall(rb'\(deny file-read\* \(regex #"([^\"]+)"\)\)', profile_result.stdout)
        ]
        if not denial_patterns:
            raise RuntimeError("generated compiler profile omitted credential-path read denials")
        credential_pattern = next(
            (pattern for pattern in denial_patterns if pattern.match("/Users/test/.AZURE/credentials.json")),
            None,
        )
        if credential_pattern is None:
            raise RuntimeError("generated compiler profile omitted its credential-path matcher")
        credential_paths = (
            "/Users/test/.AZURE/credentials.json",
            "/Users/test/.TERRAFORM.D/state",
            "/Users/test/.CONFIG/GH/hosts.yml",
            "/Users/test/.GIT-CREDENTIALS",
            "/Users/test/project/.git/config",
            "/Users/test/project/.git/config.worktree",
            "/Users/test/project/src/.hg",
            "/Users/test/project/src/.svn/wc.db",
            "/Users/test/project/src/IMPLEMENTATION_PLAN.md",
            "/Users/test/project/src/implementation_plan.md",
            "/Users/test/project/src/ImPlEmEnTaTiOn_PlAn.Md/child.elisa",
            "/Users/test/id_ECDSA",
            "/Users/test/credentials-backup/token.txt",
            "/Users/test/.env.production/token.txt",
            "/Users/test/config.ENV",
            "/Users/test/private.key.backup",
            "/Users/test/private.P12",
            "/Users/test/private.JKS",
        )
        for path in credential_paths:
            if credential_pattern.match(path) is None:
                raise RuntimeError(f"compiler profile credential rule missed {path}")
        ordinary_paths = (
            "/Users/test/project/src/main.elisa",
            "/Users/test/project/.github/workflows/ci.yml",
            "/Users/test/project/credentialed-notes.txt",
        )
        for path in ordinary_paths:
            if credential_pattern.match(path) is not None:
                raise RuntimeError(f"compiler profile credential rule unexpectedly denied {path}")
        root_state_sample = str(project_root.resolve() / ".ELISAPKG" / "unhashed-input.elisa")
        root_state_patterns = [
            pattern for pattern in denial_patterns if pattern.match(root_state_sample) is not None
        ]
        if not root_state_patterns:
            raise RuntimeError("compiler profile omitted case-insensitive root-state denials")
        for state_name in (".ELISAPKG", "BUILD", "TaRgEt"):
            path = str(project_root.resolve() / state_name / "unhashed-input.elisa")
            if not any(pattern.match(path) is not None for pattern in root_state_patterns):
                raise RuntimeError(f"compiler profile omitted case-insensitive state denial for {state_name}")
        nested_state_paths = (
            project_root / "src" / ".ELISAPKG" / "nested-source.elisa",
            project_root / "src" / ".BUILD" / "nested-source.elisa",
            project_root / "src" / ".TARGET" / "nested-source.elisa",
        )
        for path in nested_state_paths:
            if any(pattern.match(str(path)) is not None for pattern in root_state_patterns):
                raise RuntimeError(f"compiler profile unexpectedly denied nested source input {path}")
        sibling_root = project_root.parent / "projectXwithXdots"
        sibling_state_path = str(sibling_root / "BUILD" / "unhashed-input.elisa")
        if any(pattern.match(sibling_state_path) is not None for pattern in root_state_patterns):
            raise RuntimeError("compiler state denial regex treated project-root dots as wildcards")
        profile_path = base / "compiler.sb"
        profile_path.write_bytes(profile_result.stdout)

        available, reason = sandbox_apply_available()
        if not available:
            return unavailable(reason)

        metadata_positive_script = (
            'for path in "$ELISAPKG_TEST_SOURCE_FILE" "$ELISAPKG_TEST_GIT_CONFIG" "$ELISAPKG_TEST_GIT_CONFIG_WORKTREE" "$ELISAPKG_TEST_SNAPSHOT_FILE" "$ELISAPKG_TEST_SNAPSHOT_CREDENTIAL" "$ELISAPKG_TEST_SNAPSHOT_GIT_STATE" "$ELISAPKG_TEST_SNAPSHOT_RESERVED_STATE" "$ELISAPKG_TEST_SNAPSHOT_NESTED_SOURCE"; do\n'
            '  if ! IFS= read -r _ < "$path"; then\n'
            "    printf 'PROJECT_FILE_READ_FAILED\\n'\n"
            "    exit 86\n"
            "  fi\n"
            "done\n"
            'while IFS= read -r path; do\n'
            '  if ! IFS= read -r _ < "$path"; then\n'
            "    printf 'SOURCE_STATE_POSITIVE_CONTROL_FAILED\\n'\n"
            "    exit 87\n"
            "  fi\n"
            'done <<EOF\n$ELISAPKG_TEST_STALE_INPUTS\nEOF\n'
            'while IFS= read -r path; do\n'
            '  if ! IFS= read -r _ < "$path"; then\n'
            "    printf 'NESTED_SOURCE_POSITIVE_CONTROL_FAILED\\n'\n"
            "    exit 89\n"
            "  fi\n"
            'done <<EOF\n$ELISAPKG_TEST_NESTED_INPUTS\nEOF\n'
            'if ! IFS= read -r _ < "$ELISAPKG_TEST_SCRATCH_SOURCE"; then\n'
            "  printf 'SCRATCH_POSITIVE_CONTROL_FAILED\\n'\n"
            "  exit 88\n"
            "fi\n"
            "printf 'PROJECT_FILES_READABLE\\n'\n"
        )
        metadata_read_script = (
            'if IFS= read -r _ < "$ELISAPKG_TEST_SOURCE_FILE"; then\n'
            "  printf 'LIVE_SOURCE_READ_ALLOWED\\n'\n"
            "  exit 83\\n"
            "fi\n"
            "printf 'LIVE_SOURCE_READ_DENIED\\n'\n"
            'if ! IFS= read -r _ < "$ELISAPKG_TEST_SNAPSHOT_FILE"; then\n'
            "  printf 'SNAPSHOT_SOURCE_READ_DENIED\\n'\n"
            "  exit 91\\n"
            "fi\n"
            "printf 'SNAPSHOT_SOURCE_READ_ALLOWED\\n'\n"
            'if IFS= read -r _ < "$ELISAPKG_TEST_GIT_CONFIG"; then\n'
            "  printf 'GIT_CONFIG_READ_ALLOWED\\n'\n"
            "  exit 84\\n"
            "fi\n"
            "printf 'GIT_CONFIG_READ_DENIED\\n'\n"
            'if IFS= read -r _ < "$ELISAPKG_TEST_GIT_CONFIG_WORKTREE"; then\n'
            "  printf 'GIT_CONFIG_WORKTREE_READ_ALLOWED\\n'\n"
            "  exit 85\\n"
            "fi\n"
            "printf 'GIT_CONFIG_WORKTREE_READ_DENIED\\n'\n"
            'while IFS= read -r path; do\n'
            '  if IFS= read -r _ < "$path"; then\n'
            "    printf 'SOURCE_STATE_READ_ALLOWED\\n'\n"
            "    exit 86\\n"
            "  fi\n"
            'done <<EOF\n$ELISAPKG_TEST_STALE_INPUTS\nEOF\n'
            "printf 'SOURCE_STATE_READ_DENIED\\n'\n"
            'if IFS= read -r _ < "$ELISAPKG_TEST_SNAPSHOT_CREDENTIAL"; then\n'
            "  printf 'SNAPSHOT_CREDENTIAL_READ_ALLOWED\\n'\n"
            "  exit 92\\n"
            "fi\n"
            'if IFS= read -r _ < "$ELISAPKG_TEST_SNAPSHOT_GIT_STATE"; then\n'
            "  printf 'SNAPSHOT_GIT_STATE_READ_ALLOWED\\n'\n"
            "  exit 93\\n"
            "fi\n"
            'if IFS= read -r _ < "$ELISAPKG_TEST_SNAPSHOT_RESERVED_STATE"; then\n'
            "  printf 'SNAPSHOT_RESERVED_STATE_READ_ALLOWED\\n'\n"
            "  exit 94\\n"
            "fi\n"
            "printf 'SNAPSHOT_SECRET_AND_STATE_READ_DENIED\\n'\n"
            'if ! IFS= read -r _ < "$ELISAPKG_TEST_SNAPSHOT_NESTED_SOURCE"; then\n'
            "  printf 'SNAPSHOT_NESTED_SOURCE_READ_DENIED\\n'\n"
            "  exit 95\\n"
            "fi\n"
            "printf 'SNAPSHOT_NESTED_SOURCE_READABLE\\n'\n"
            'if printf \'changed\\n\' >> "$ELISAPKG_TEST_SNAPSHOT_FILE"; then\n'
            "  printf 'SNAPSHOT_WRITE_ALLOWED\\n'\n"
            "  exit 96\\n"
            "fi\n"
            "printf 'SNAPSHOT_WRITE_DENIED\\n'\n"
            'if printf \'new\\n\' > "$ELISAPKG_TEST_SNAPSHOT_FILE.new"; then\n'
            "  printf 'SNAPSHOT_CREATE_ALLOWED\\n'\n"
            "  exit 97\\n"
            "fi\n"
            "printf 'SNAPSHOT_CREATE_DENIED\\n'\n"
            'if IFS= read -r _ < "$ELISAPKG_TEST_SCRATCH_SOURCE"; then\n'
            "  printf 'SANDBOX_SCRATCH_READ_ALLOWED\\n'\n"
            "else\n"
            "  printf 'SANDBOX_SCRATCH_READ_DENIED\\n'\n"
            "  exit 87\\n"
            "fi\n"
        )
        unconfined_metadata_result = subprocess.run(
            ["/bin/bash", "-c", metadata_positive_script],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        if (
            unconfined_metadata_result.returncode != 0
            or b"PROJECT_FILES_READABLE\n" not in unconfined_metadata_result.stdout
        ):
            raise RuntimeError("unconfined project metadata positive control failed")

        network_script = (
            'if exec 3<>"/dev/tcp/127.0.0.1/$ELISAPKG_TEST_PORT"; then\n'
            "  printf 'SANDBOX_NETWORK_ALLOWED\\n'\n"
            "  exit 82\n"
            "fi\n"
            "printf 'SANDBOX_NETWORK_DENIED\\n'\n"
        )
        listener, accepted, server_thread = start_loopback_listener()
        env["ELISAPKG_TEST_PORT"] = str(listener.getsockname()[1])
        try:
            control_result = subprocess.run(
                ["/bin/bash", "-c", network_script],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
        finally:
            server_thread.join(timeout=2)
            listener.close()
        control_output = control_result.stdout + control_result.stderr
        if (
            control_result.returncode != 82
            or b"SANDBOX_NETWORK_ALLOWED\n" not in control_output
            or not accepted.is_set()
        ):
            raise RuntimeError(
                "unconfined loopback positive control failed: "
                f"exit={control_result.returncode}, output={control_output.decode(errors='replace')}"
            )

        listener, accepted, server_thread = start_loopback_listener()
        env["ELISAPKG_TEST_PORT"] = str(listener.getsockname()[1])
        try:
            network_result = run_sandbox_probe(
                Path("/bin/bash"), profile_path, callback_path, env, ("-c", network_script)
            )
        finally:
            server_thread.join(timeout=2)
            listener.close()
        network_output = network_result.stdout + network_result.stderr
        if network_result.returncode != 0 or b"SANDBOX_NETWORK_DENIED\n" not in network_output:
            raise RuntimeError(
                "network denial probe failed: "
                f"exit={network_result.returncode}, output={network_output.decode(errors='replace')}"
            )
        if accepted.is_set():
            raise RuntimeError("the sandboxed compiler probe connected to a loopback listener")

        metadata_result = run_sandbox_probe(
            Path("/bin/bash"), profile_path, callback_path, env, ("-c", metadata_read_script)
        )
        metadata_output = metadata_result.stdout + metadata_result.stderr
        if (
            metadata_result.returncode != 0
            or b"LIVE_SOURCE_READ_DENIED\n" not in metadata_output
            or b"SNAPSHOT_SOURCE_READ_ALLOWED\n" not in metadata_output
            or b"GIT_CONFIG_READ_DENIED\n" not in metadata_output
            or b"GIT_CONFIG_WORKTREE_READ_DENIED\n" not in metadata_output
            or b"SOURCE_STATE_READ_DENIED\n" not in metadata_output
            or b"SNAPSHOT_SECRET_AND_STATE_READ_DENIED\n" not in metadata_output
            or b"SNAPSHOT_NESTED_SOURCE_READABLE\n" not in metadata_output
            or b"SNAPSHOT_WRITE_DENIED\n" not in metadata_output
            or b"SNAPSHOT_CREATE_DENIED\n" not in metadata_output
            or b"SANDBOX_SCRATCH_READ_ALLOWED\n" not in metadata_output
            or b"LIVE_SOURCE_READ_ALLOWED\n" in metadata_output
            or b"GIT_CONFIG_READ_ALLOWED\n" in metadata_output
            or b"GIT_CONFIG_WORKTREE_READ_ALLOWED\n" in metadata_output
            or b"SOURCE_STATE_READ_ALLOWED\n" in metadata_output
            or b"SNAPSHOT_CREDENTIAL_READ_ALLOWED\n" in metadata_output
            or b"SNAPSHOT_GIT_STATE_READ_ALLOWED\n" in metadata_output
            or b"SNAPSHOT_RESERVED_STATE_READ_ALLOWED\n" in metadata_output
            or b"SNAPSHOT_WRITE_ALLOWED\n" in metadata_output
            or b"SNAPSHOT_CREATE_ALLOWED\n" in metadata_output
        ):
            raise RuntimeError(
                "Git metadata read denial probe failed: "
                f"exit={metadata_result.returncode}, output={metadata_output.decode(errors='replace')}"
            )
        snapshot_stat = snapshot_file.lstat()
        if snapshot_file.read_text() != "verified source snapshot remains readable\n":
            raise RuntimeError("the sandbox modified verified package source bytes")
        if (snapshot_stat.st_dev, snapshot_stat.st_ino) != (
            snapshot_file.stat().st_dev,
            snapshot_file.stat().st_ino,
        ):
            raise RuntimeError("the sandbox replaced the verified package source inode")
        if os.path.lexists(Path(f"{snapshot_file}.new")):
            raise RuntimeError("the sandbox created a file inside the read-only source snapshot")

        callback_script = (
            'if ! printf \'SAX\' >> "$ELISAPKG_TEST_CALLBACK_PATH"; then\n'
            "  printf 'CALLBACK_DATA_WRITE_DENIED\\n'\n"
            "  exit 81\n"
            "fi\n"
            'if printf \'BAD\' >> "$ELISAPKG_TEST_DECOY_PATH"; then\n'
            "  printf 'CALLBACK_DECOY_WRITE_ALLOWED\\n'\n"
            "  exit 88\n"
            "fi\n"
            "printf 'CALLBACK_DECOY_WRITE_DENIED\\n'\n"
            'exec "$ELISAPKG_TEST_EXECUTABLE_TWO"\n'
        )
        callback_result = run_sandbox_probe(
            Path("/bin/bash"), profile_path, callback_path, env, ("-c", callback_script)
        )
        callback_output = callback_result.stdout + callback_result.stderr
        if (
            callback_result.returncode != 0
            or b"CALLBACK_DECOY_WRITE_DENIED\n" not in callback_output
            or b"CALLBACK_POLICY_OK\n" not in callback_output
        ):
            raise RuntimeError(
                "callback inode policy probe failed: "
                f"exit={callback_result.returncode}, output={callback_output.decode(errors='replace')}"
            )
        final_stat = callback_path.lstat()
        if (final_stat.st_dev, final_stat.st_ino) != (initial_stat.st_dev, initial_stat.st_ino):
            raise RuntimeError("the sandbox callback inode identity changed")
        if stat.S_IMODE(final_stat.st_mode) != 0o600:
            raise RuntimeError("the sandbox callback inode mode changed")
        if not callback_path.read_bytes().endswith(b"SAX"):
            raise RuntimeError("the allowed callback data write did not reach the pre-created inode")
        final_decoy_stat = callback_decoy_path.lstat()
        if (final_decoy_stat.st_dev, final_decoy_stat.st_ino) != (
            initial_decoy_stat.st_dev,
            initial_decoy_stat.st_ino,
        ):
            raise RuntimeError("the sandbox modified the unrelated callback decoy inode identity")
        if stat.S_IMODE(final_decoy_stat.st_mode) != 0o600 or callback_decoy_path.read_bytes() != decoy_contents:
            raise RuntimeError("the sandbox callback exception allowed writing a different inode")
        if any(os.path.lexists(path) for path in generated_paths):
            raise RuntimeError("a sandbox callback namespace operation created an unexpected path")

        print("sandbox policy probes passed (loopback denied; callback data write confined to its pre-created inode)")
        return 0
    finally:
        for path in generated_paths:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        if callback_path is not None:
            try:
                callback_path.unlink()
            except FileNotFoundError:
                pass
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(run())
    except Exception as error:
        print(f"sandbox policy test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
