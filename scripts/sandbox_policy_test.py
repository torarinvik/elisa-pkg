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
        project_root = base / "project"
        sandbox_build_root = project_root / ".elisapkg" / "build"
        tools_root = base / "tools"
        sandbox_build_root.mkdir(parents=True)
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
        output_temp = sandbox_build_root / "output-probe"
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
        env["ELISAPKG_TEST_BUILD_ROOT"] = str(sandbox_build_root.resolve())
        env["ELISAPKG_TEST_OUTPUT"] = str(output_temp.resolve())
        env["ELISAPKG_TEST_EXECUTABLE_ONE"] = "/bin/bash"
        env["ELISAPKG_TEST_EXECUTABLE_TWO"] = str(callback_probe.resolve())
        env["ELISAPKG_TEST_CALLBACK_PATH"] = str(callback_path)
        env["ELISAPKG_TEST_DECOY_PATH"] = str(callback_decoy_path)
        env["ELISAPKG_TEST_GIT_CONFIG"] = str(git_config)
        env["ELISAPKG_TEST_GIT_CONFIG_WORKTREE"] = str(git_config_worktree)
        env["ELISAPKG_TEST_SOURCE_FILE"] = str(source_file)

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
        credential_rule = re.search(rb'\(deny file-read\* \(regex #"([^\"]+)"\)\)', profile_result.stdout)
        if credential_rule is None:
            raise RuntimeError("generated compiler profile omitted credential-path read denials")
        credential_pattern = re.compile(credential_rule.group(1).decode("ascii"))
        credential_paths = (
            "/Users/test/.AZURE/credentials.json",
            "/Users/test/.TERRAFORM.D/state",
            "/Users/test/.CONFIG/GH/hosts.yml",
            "/Users/test/.GIT-CREDENTIALS",
            "/Users/test/project/.git/config",
            "/Users/test/project/.git/config.worktree",
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
        profile_path = base / "compiler.sb"
        profile_path.write_bytes(profile_result.stdout)

        available, reason = sandbox_apply_available()
        if not available:
            return unavailable(reason)

        metadata_positive_script = (
            'for path in "$ELISAPKG_TEST_SOURCE_FILE" "$ELISAPKG_TEST_GIT_CONFIG" "$ELISAPKG_TEST_GIT_CONFIG_WORKTREE"; do\n'
            '  if ! IFS= read -r _ < "$path"; then\n'
            "    printf 'PROJECT_FILE_READ_FAILED\\n'\n"
            "    exit 86\n"
            "  fi\n"
            "done\n"
            "printf 'PROJECT_FILES_READABLE\\n'\n"
        )
        metadata_read_script = (
            'if IFS= read -r _ < "$ELISAPKG_TEST_SOURCE_FILE"; then\n'
            "  printf 'SOURCE_READ_ALLOWED\\n'\n"
            "else\n"
            "  printf 'SOURCE_READ_DENIED\\n'\n"
            "  exit 83\n"
            "fi\n"
            'if IFS= read -r _ < "$ELISAPKG_TEST_GIT_CONFIG"; then\n'
            "  printf 'GIT_CONFIG_READ_ALLOWED\\n'\n"
            "  exit 84\n"
            "fi\n"
            "printf 'GIT_CONFIG_READ_DENIED\\n'\n"
            'if IFS= read -r _ < "$ELISAPKG_TEST_GIT_CONFIG_WORKTREE"; then\n'
            "  printf 'GIT_CONFIG_WORKTREE_READ_ALLOWED\\n'\n"
            "  exit 85\n"
            "fi\n"
            "printf 'GIT_CONFIG_WORKTREE_READ_DENIED\\n'\n"
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
            or b"SOURCE_READ_ALLOWED\n" not in metadata_output
            or b"GIT_CONFIG_READ_DENIED\n" not in metadata_output
            or b"GIT_CONFIG_WORKTREE_READ_DENIED\n" not in metadata_output
            or b"GIT_CONFIG_READ_ALLOWED\n" in metadata_output
            or b"GIT_CONFIG_WORKTREE_READ_ALLOWED\n" in metadata_output
        ):
            raise RuntimeError(
                "Git metadata read denial probe failed: "
                f"exit={metadata_result.returncode}, output={metadata_output.decode(errors='replace')}"
            )

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
