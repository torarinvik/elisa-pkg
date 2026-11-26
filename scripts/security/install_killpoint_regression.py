#!/usr/bin/env python3
"""Kill an instrumented Elisa binary at real install transaction boundaries."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
PRODUCTION_BIN = ROOT / "build" / "elisapkg"
BUILD_ROOT = ROOT / "build"
FAULT_MODULE = r'''module InstallFaults:
    private:
        def write_text(value: cstr) -> void can[Console.Write, Unsafe.PointerCast]:
            length: usize = Platform::c_string_length(value)
            offset: mutable usize = 0.usize()
            while offset < length |value, offset|:
                raw: void& = (&value[offset]).cast[void&] can Unsafe.PointerCast
                written: i64 = Platform::write_file_descriptor(1, raw, length - offset) can Console.Write
                return if written <= 0 or written > (length - offset).i64()
                offset <- offset + written.usize()

    public:
        def use_test_prebuilt_artifact() -> bool can[Memory.Allocate, Unsafe.PointerCast]:
            return true

        def transaction_boundary(name: cstr) -> void can[Console.Write, Memory.Allocate, Unsafe.PointerCast]:
            if Platform::environment_variable("ELISAPKG_TEST_CRASH_POINT") is raw_point:
                requested: cstr = raw_point.cast[cstr] can Unsafe.PointerCast
                return if not Platform::c_string_equal(requested, name)
                write_text("ELISAPKG_FAULT_POINT:")
                write_text(name)
                write_text("\n")
                wake: mutable u8 = 0
                while true:
                    read: i64 = Platform::read_file_descriptor(0, &wake, 1.usize()) can Unsafe.PointerCast
                    return if read <= 0
'''


def compile_fault_binary(work: Path) -> Path:
    compiler_root_value = os.environ.get("ELISA_COMPILER_ROOT")
    if not compiler_root_value:
        raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
    compiler_root = Path(compiler_root_value).resolve()
    stage1 = Path(os.environ.get("ELISA_STAGE1_BIN", compiler_root / "bin/elisac-stage1")).resolve()
    wrapper = Path(os.environ.get("ELISA_COMPILER_WRAPPER", compiler_root / "scripts/elisac_stage1.sh")).resolve()
    runtime = Path(os.environ.get("ELISA_RUNTIME_OBJ", compiler_root / "build/runtime/elisacore_runtime.o")).resolve()
    for label, path in (("stage1 compiler", stage1), ("compiler wrapper", wrapper), ("runtime object", runtime)):
        if not path.is_file():
            raise SystemExit(f"error: {label} is missing: {path}")

    copied_src = work / "src"
    shutil.copytree(ROOT / "src", copied_src)
    production_fault_module = copied_src / "install_faults.elisa"
    production_module_text = production_fault_module.read_text(encoding="utf-8")
    if "ELISAPKG_TEST_CRASH_POINT" in production_module_text or "ELISAPKG_TEST_PREBUILT_ARTIFACT" in production_module_text:
        raise SystemExit("error: test-only fault control leaked into the production module")
    production_fault_module.write_text(FAULT_MODULE, encoding="utf-8")

    binary = work / "elisapkg-fault-test"
    compiler_env = dict(os.environ)
    compiler_env["ELISA_STAGE1_BIN"] = str(stage1)
    compiler_env["ELISA_RUNTIME_OBJ"] = str(runtime)
    compiler_env.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
    result = subprocess.run(
        [str(wrapper), "-emit", "exe", "-o", str(binary), str(copied_src / "main.elisa")],
        cwd=work,
        env=compiler_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=180,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"error: could not compile the test-only fault binary:\n{result.stdout}")
    return binary


def write_install(prefix: Path) -> tuple[Path, Path, Path]:
    artifact = b"#!/bin/sh\nprintf '%s\\n' transaction-fixture\n"
    version = b"1.2.3"
    digest = hashlib.sha256(artifact).hexdigest().encode("ascii")
    binary = prefix / "bin" / "app"
    receipt = prefix / "share" / "elisapkg" / "receipts" / "app"
    journal = prefix / ".elisapkg-install-transaction"
    binary.write_bytes(artifact)
    binary.chmod(0o755)
    receipt.write_bytes(
        b"elisapkg-install-receipt:1\nname:app\nversion:"
        + version
        + b"\npath:"
        + str(binary).encode("utf-8")
        + b"\nartifact-digest:sha256:"
        + digest
        + b"\n"
    )
    receipt.chmod(0o600)
    return binary, receipt, journal


def kill_at_boundary(
    binary: Path,
    prefix: Path,
    point: str,
    *,
    args: tuple[str, ...] = ("uninstall", "--local", "app"),
    cwd: Path | None = None,
) -> None:
    environment = dict(os.environ)
    environment["ELISAPKG_INSTALL_PREFIX"] = str(prefix)
    environment["ELISAPKG_TEST_CRASH_POINT"] = point
    process = subprocess.Popen(
        [str(binary), *args],
        cwd=cwd,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    assert process.stdout is not None
    marker = f"ELISAPKG_FAULT_POINT:{point}\n".encode("ascii")
    captured = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + (180 if cwd is not None else 45)
    try:
        while time.monotonic() < deadline and marker not in captured:
            events = selector.select(max(0.0, deadline - time.monotonic()))
            if not events:
                break
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            captured.extend(chunk)
        if marker not in captured:
            if process.poll() is None:
                process.kill()
            stdout, stderr = process.communicate(timeout=10)
            raise SystemExit(
                f"error: test binary did not reach {point}; status={process.returncode}; "
                f"stdout={(bytes(captured) + stdout).decode(errors='replace')} "
                f"stderr={stderr.decode(errors='replace')}"
            )
        process.kill()
        process.wait(timeout=10)
        if process.returncode != -signal.SIGKILL:
            raise SystemExit(f"error: {point} stopped with {process.returncode}, expected SIGKILL")
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        if process.stdin is not None:
            process.stdin.close()
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()


def recover(prefix: Path, expected: int, label: str) -> None:
    environment = dict(os.environ)
    environment["ELISAPKG_INSTALL_PREFIX"] = str(prefix)
    environment.pop("ELISAPKG_TEST_CRASH_POINT", None)
    result = subprocess.run(
        [str(PRODUCTION_BIN), "uninstall", "--local", "app"],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    if result.returncode != expected:
        raise SystemExit(
            f"error: {label} returned {result.returncode}, expected {expected}: "
            f"{result.stdout.decode(errors='replace')}{result.stderr.decode(errors='replace')}"
        )


def retry_install(binary: Path, prefix: Path, cwd: Path, artifact: bytes, label: str) -> None:
    environment = dict(os.environ)
    environment["ELISAPKG_INSTALL_PREFIX"] = str(prefix)
    environment.pop("ELISAPKG_TEST_CRASH_POINT", None)
    result = subprocess.run(
        [str(binary), "install", "--local", "--quiet"],
        cwd=cwd,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"error: {label} returned {result.returncode}: "
            f"{result.stdout.decode(errors='replace')}{result.stderr.decode(errors='replace')}"
        )

    binary_path = prefix / "bin" / "app"
    receipt_path = prefix / "share" / "elisapkg" / "receipts" / "app"
    journal_path = prefix / ".elisapkg-install-transaction"
    digest = hashlib.sha256(artifact).hexdigest().encode("ascii")
    expected_receipt = (
        b"elisapkg-install-receipt:1\nname:app\nversion:1.2.3\npath:"
        + str(binary_path).encode("utf-8")
        + b"\nartifact-digest:sha256:"
        + digest
        + b"\n"
    )
    if (
        not binary_path.is_file()
        or binary_path.is_symlink()
        or binary_path.read_bytes() != artifact
        or binary_path.stat().st_mode & 0o777 != 0o755
        or not receipt_path.is_file()
        or receipt_path.is_symlink()
        or receipt_path.read_bytes() != expected_receipt
        or journal_path.exists()
    ):
        raise SystemExit(f"error: {label} did not leave the exact installed artifact, receipt, and retired journal")


def main() -> int:
    if not PRODUCTION_BIN.is_file():
        raise SystemExit(f"error: production binary is missing: {PRODUCTION_BIN}")
    compiler_root_value = os.environ.get("ELISA_COMPILER_ROOT")
    if not compiler_root_value:
        raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
    compiler_root = Path(compiler_root_value).resolve()
    os.environ.setdefault("ELISA_STAGE1_BIN", str(compiler_root / "bin/elisac-stage1"))
    os.environ.setdefault("ELISA_COMPILER_WRAPPER", str(compiler_root / "scripts/elisac_stage1.sh"))
    os.environ.setdefault("ELISA_RUNTIME_OBJ", str(compiler_root / "build/runtime/elisacore_runtime.o"))
    os.environ.setdefault("ELISAPKG_COMPILER", os.environ["ELISA_COMPILER_WRAPPER"])
    os.environ.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    install_points = (
        "install.journal.durable",
        "install.binary.durable",
        "install.binary.mode.durable",
        "install.receipt.durable",
        "install.targets.synced",
    )
    uninstall_points = (
        "uninstall.journal.durable",
        "uninstall.binary.removed",
        "uninstall.receipt.removed",
        "uninstall.targets.synced",
        "transaction.journal.unlinked",
    )
    # Install prefixes require every ancestor to be trusted and euid-owned.
    # The checkout may be on a shared mount, so keep both prefixes and their
    # package fixture under the current user's private home directory.
    with tempfile.TemporaryDirectory(prefix="elisapkg-install-killpoints-", dir=Path.home()) as raw:
        work = Path(raw)
        test_binary = compile_fault_binary(work)
        package = work / "package"
        package.mkdir(mode=0o700)
        (package / "src").mkdir(mode=0o700)
        (package / "src" / "main.elisa").write_text(
            "def main() -> i64:\n    return 0\n", encoding="utf-8"
        )
        (package / "elisapkg.json").write_text(
            '{"schema-version":1,"package":{"name":"app","version":"1.2.3"},'
            '"targets":[{"name":"app","kind":"bin","entry":"src/main.elisa"}],'
            '"dependencies":{}}\n',
            encoding="utf-8",
        )
        # A known fixture binary lets these tests exercise install publication
        # even on hosts where the external toolchain cannot link package code.
        prebuilt = package / ".elisapkg" / "build" / "app"
        (package / ".elisapkg").mkdir(mode=0o700)
        prebuilt.parent.mkdir(mode=0o700)
        prebuilt.write_bytes(b"#!/bin/sh\nexit 0\n")

        # The copied test module explicitly selects this prebuilt fixture;
        # production always builds from verified package source as usual.
        for point in install_points:
            prefix = work / point
            prefix.mkdir(mode=0o755)
            kill_at_boundary(
                test_binary,
                prefix,
                point,
                args=("install", "--local", "--quiet"),
                cwd=package,
            )
            retry_install(test_binary, prefix, package, prebuilt.read_bytes(), f"install retry after {point}")
            recover(prefix, 0, f"cleanup after retrying {point}")
            binary_path = prefix / "bin" / "app"
            receipt_path = prefix / "share" / "elisapkg" / "receipts" / "app"
            journal_path = prefix / ".elisapkg-install-transaction"
            if binary_path.exists() or receipt_path.exists() or journal_path.exists():
                raise SystemExit(f"error: recovery after {point} left package files or the transaction journal")

        for point in uninstall_points:
            prefix = work / point
            prefix.mkdir(mode=0o755)
            (prefix / "bin").mkdir(mode=0o755)
            (prefix / "share").mkdir(mode=0o755)
            (prefix / "share" / "elisapkg").mkdir(mode=0o755)
            (prefix / "share" / "elisapkg" / "receipts").mkdir(mode=0o755)
            binary_path, receipt_path, journal_path = write_install(prefix)
            kill_at_boundary(test_binary, prefix, point)

            if point == "transaction.journal.unlinked":
                expected_recovery = 7
            else:
                expected_recovery = 0
            recover(prefix, expected_recovery, f"recovery after {point}")
            if binary_path.exists() or receipt_path.exists() or journal_path.exists():
                raise SystemExit(f"error: recovery after {point} left package files or the transaction journal")

    print("Elisa install/uninstall process-kill regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
