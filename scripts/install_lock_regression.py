#!/usr/bin/env python3
"""Exercise the local-install kernel lock through the Elisa platform facade."""

from pathlib import Path
import atexit
import os
import select
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
compiler_root_text = os.environ.get("ELISA_COMPILER_ROOT", "")
if not compiler_root_text:
    raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
COMPILER_ROOT = Path(compiler_root_text).resolve()
STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1")).resolve()
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh")).resolve()
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o")).resolve()
ACTIVE_PROCESSES: list[subprocess.Popen[bytes]] = []


def cleanup_processes() -> None:
    for process in ACTIVE_PROCESSES:
        if process.poll() is None:
            process.kill()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass


atexit.register(cleanup_processes)


PROBE = f'''include "{ROOT / "src/platform.elisa"}"

def main() -> i64 can[Console.Write, Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:
    prefix_value: u8&? = Platform::pkg_getenv("ELISAPKG_TEST_LOCK_PREFIX")
    if prefix_value is prefix:
        prefix_name: cstr = prefix.cast[cstr] can Unsafe.PointerCast
        lock_fd: i64 = Platform::pkg_acquire_install_lock(prefix_name)
        return 2 if lock_fd < 0
        ready: u8 = 82
        ready_ref: void& = (&ready).cast[void&] can Unsafe.PointerCast
        return 3 if Platform::pkg_write(1, ready_ref, 1.usize()) != 1
        input_byte: mutable u8 = 0
        read_result: i64 = Platform::pkg_read_fd(0, &input_byte, 1.usize())
        close_result: i64 = Platform::pkg_close(lock_fd)
        return 4 if close_result != 0
        return 0 if read_result == 0 or read_result == 1
        return 5
    return 10
'''


def build_probe(work: Path) -> Path:
    for label, path in (("stage1 compiler", STAGE1), ("compiler wrapper", WRAPPER), ("runtime object", RUNTIME)):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}")
    if not os.access(STAGE1, os.X_OK) or not os.access(WRAPPER, os.X_OK):
        raise SystemExit("error: Elisa compiler and wrapper must be executable")

    source = work / "install_lock_probe.elisa"
    binary = work / "install_lock_probe"
    source.write_text(PROBE, encoding="utf-8")
    environment = dict(os.environ)
    environment["ELISA_STAGE1_BIN"] = str(STAGE1)
    environment["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
    environment.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
    subprocess.run(
        [str(WRAPPER), "-emit", "exe", "-o", str(binary), str(source)],
        cwd=work,
        env=environment,
        check=True,
        timeout=120,
    )
    return binary


def start_probe(binary: Path, prefix: Path) -> subprocess.Popen[bytes]:
    environment = dict(os.environ)
    environment["ELISAPKG_TEST_LOCK_PREFIX"] = str(prefix)
    process = subprocess.Popen(
        [str(binary)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    ACTIVE_PROCESSES.append(process)
    return process


def read_ready(process: subprocess.Popen[bytes], timeout: float = 3.0) -> bytes:
    assert process.stdout is not None
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        process.kill()
        process.wait(timeout=3)
        raise SystemExit("error: lock probe did not report whether it acquired the lock")
    return process.stdout.read(1)


def expect_rejected_without_blocking(binary: Path, prefix: Path, label: str) -> None:
    process = start_probe(binary, prefix)
    marker = read_ready(process)
    if marker:
        process.kill()
        process.wait(timeout=3)
        raise SystemExit(f"error: install lock accepted a {label}")
    try:
        _, stderr = process.communicate(timeout=3)
    except subprocess.TimeoutExpired as error:
        process.kill()
        process.wait(timeout=3)
        raise SystemExit(f"error: install lock probe blocked on a {label}") from error
    if process.returncode != 2:
        raise SystemExit(f"error: {label} rejection returned {process.returncode}: {stderr!r}")


def main() -> int:
    (ROOT / "build").mkdir(parents=True, exist_ok=True)
    # The platform lock accepts only a trusted, euid-owned path. The checkout
    # may live on a shared or otherwise untrusted mount, so keep the fixture in
    # the current user's private home directory instead of inheriting that path.
    with tempfile.TemporaryDirectory(prefix="elisapkg-install-lock-", dir=Path.home()) as directory:
        work = Path(directory)
        binary = build_probe(work)
        prefix = work / "prefix"
        prefix.mkdir(mode=0o700)

        owner = start_probe(binary, prefix)
        if read_ready(owner) != b"R":
            raise SystemExit("error: first installer did not acquire the empty-prefix lock")
        initial_lock_stat = (prefix / ".elisapkg-install.lock").lstat()

        contender = start_probe(binary, prefix)
        marker = read_ready(contender)
        if marker:
            contender.kill()
            contender.wait(timeout=3)
            owner.kill()
            owner.wait(timeout=3)
            raise SystemExit("error: two installer processes acquired the same prefix lock")
        try:
            _, stderr = contender.communicate(timeout=3)
        except subprocess.TimeoutExpired as error:
            contender.kill()
            contender.wait(timeout=3)
            owner.kill()
            owner.wait(timeout=3)
            raise SystemExit("error: competing install lock acquisition blocked instead of failing quickly") from error
        if contender.returncode != 2:
            owner.kill()
            owner.wait(timeout=3)
            raise SystemExit(f"error: contending installer returned {contender.returncode}: {stderr!r}")

        # Simulate a process crash while it owns the lock. flock must be released
        # by the kernel even though the persistent lock inode is left untouched.
        owner.kill()
        owner.wait(timeout=3)
        recovered = start_probe(binary, prefix)
        if read_ready(recovered) != b"R":
            raise SystemExit("error: crashed installer left the prefix lock permanently held")
        assert recovered.stdin is not None
        recovered.stdin.write(b"x")
        recovered.stdin.flush()
        try:
            _, stderr = recovered.communicate(timeout=3)
        except subprocess.TimeoutExpired as error:
            recovered.kill()
            recovered.wait(timeout=3)
            raise SystemExit("error: recovered installer did not exit after releasing the lock") from error
        if recovered.returncode != 0:
            raise SystemExit(f"error: recovered installer failed: {stderr!r}")

        lock_path = prefix / ".elisapkg-install.lock"
        lock_stat = lock_path.lstat()
        if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_mode & 0o022:
            raise SystemExit("error: persistent lock inode is not a protected regular file")
        if (lock_stat.st_dev, lock_stat.st_ino) != (initial_lock_stat.st_dev, initial_lock_stat.st_ino):
            raise SystemExit("error: install lock inode changed while a crashed owner was recovered")

        untouched_target = work / "untouched-target"
        untouched_target.write_bytes(b"leave this file alone\n")
        for label, create in (
            ("symlink", lambda path: path.symlink_to(untouched_target)),
            ("FIFO", lambda path: os.mkfifo(path, 0o600)),
            ("directory", lambda path: path.mkdir(mode=0o700)),
        ):
            invalid_prefix = work / f"invalid-{label}"
            invalid_prefix.mkdir(mode=0o700)
            invalid_path = invalid_prefix / ".elisapkg-install.lock"
            create(invalid_path)
            expect_rejected_without_blocking(binary, invalid_prefix, label)
            if label == "symlink" and (not invalid_path.is_symlink() or untouched_target.read_bytes() != b"leave this file alone\n"):
                raise SystemExit("error: lock acquisition changed the symlink or its target")

        permissive_prefix = work / "permissive-lock"
        permissive_prefix.mkdir(mode=0o700)
        permissive_lock = permissive_prefix / ".elisapkg-install.lock"
        permissive_lock.touch(mode=0o600)
        permissive_lock.chmod(0o666)
        expect_rejected_without_blocking(binary, permissive_prefix, "group/other-writable regular file")
        if stat.S_IMODE(permissive_lock.stat().st_mode) != 0o666:
            raise SystemExit("error: lock validation changed an untrusted lock file")

        print("Elisa install lock regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
