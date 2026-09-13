#!/usr/bin/env python3
"""Exercise trust-state kernel locking through the Elisa registry API."""

from pathlib import Path
import fcntl
import os
import select
import stat
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
if len(sys.argv) != 4:
    raise SystemExit("usage: trust_state_lock_regression.py PROBE REGISTRY STATE")
PROBE = Path(sys.argv[1]).resolve()
REGISTRY = Path(sys.argv[2]).resolve()
STATE = Path(sys.argv[3]).resolve()


def run_probe(state: Path, *, succeeds: bool, label: str) -> None:
    environment = dict(os.environ)
    environment["ELISAPKG_REGISTRY_DIR"] = str(REGISTRY)
    environment["ELISAPKG_TRUST_STATE"] = str(state)
    try:
        result = subprocess.run(
            [str(PROBE)],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise SystemExit(f"error: trust-state probe blocked for {label}") from error
    expected = 0 if succeeds else 1
    if result.returncode != expected:
        raise SystemExit(
            f"error: trust-state probe for {label} returned {result.returncode}, "
            f"expected {expected}: {result.stderr!r}"
        )


def start_lock_holder(path: Path) -> subprocess.Popen[bytes]:
    holder_code = (
        "import fcntl, os, sys\n"
        "fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)\n"
        "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
        "print('ready', flush=True)\n"
        "sys.stdin.buffer.read()\n"
    )
    process = subprocess.Popen(
        [sys.executable, "-c", holder_code, str(path)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    ready, _, _ = select.select([process.stdout], [], [], 3)
    if not ready or process.stdout.readline() != b"ready\n":
        process.kill()
        process.wait(timeout=3)
        stderr = process.stderr.read() if process.stderr is not None else b""
        raise SystemExit(f"error: Python did not acquire trust-state lock: {stderr!r}")
    return process


def check_contended_lock_recovery() -> None:
    # Let Elisa create the persistent lock inode, then simulate another
    # process dying while it owns that same inode.
    run_probe(STATE, succeeds=True, label="initial trust-state record")
    lock_path = Path(f"{STATE}.lock")
    initial = lock_path.lstat()
    if not stat.S_ISREG(initial.st_mode):
        raise SystemExit("error: trust-state lock is not a regular file")

    owner = start_lock_holder(lock_path)
    try:
        run_probe(STATE, succeeds=False, label="a contended trust-state lock")
    finally:
        owner.kill()
        owner.wait(timeout=3)

    run_probe(STATE, succeeds=True, label="trust-state lock after owner crash")
    recovered = lock_path.lstat()
    if not stat.S_ISREG(recovered.st_mode) or stat.S_IMODE(recovered.st_mode) & 0o022:
        raise SystemExit("error: recovered trust-state lock is not a protected regular file")
    if (recovered.st_dev, recovered.st_ino) != (initial.st_dev, initial.st_ino):
        raise SystemExit("error: trust-state lock inode changed during crash recovery")


def check_invalid_lock_objects(work: Path) -> None:
    untouched_target = work / "symlink-target"
    untouched_target.write_bytes(b"preserve this file\n")
    cases = (
        ("symlink", lambda path: path.symlink_to(untouched_target)),
        ("FIFO", lambda path: os.mkfifo(path, 0o600)),
        ("directory", lambda path: path.mkdir(mode=0o700)),
    )
    for label, create in cases:
        case_dir = work / f"invalid-{label}"
        case_dir.mkdir(mode=0o700)
        state = case_dir / "state"
        lock_path = Path(f"{state}.lock")
        create(lock_path)
        run_probe(state, succeeds=False, label=f"a {label} lock object")
        if label == "symlink" and (
            not lock_path.is_symlink() or untouched_target.read_bytes() != b"preserve this file\n"
        ):
            raise SystemExit("error: trust-state lock validation changed a symlink target")
        if state.exists():
            raise SystemExit(f"error: rejected {label} lock object still allowed trust-state creation")

    case_dir = work / "permissive-lock"
    case_dir.mkdir(mode=0o700)
    state = case_dir / "state"
    lock_path = Path(f"{state}.lock")
    lock_path.touch(mode=0o600)
    lock_path.chmod(0o666)
    run_probe(state, succeeds=False, label="a group/other-writable lock file")
    if stat.S_IMODE(lock_path.stat().st_mode) != 0o666 or state.exists():
        raise SystemExit("error: validation modified or accepted a permissive trust-state lock")


def main() -> int:
    if not PROBE.is_file() or not os.access(PROBE, os.X_OK):
        raise SystemExit(f"error: trust-state probe is not executable: {PROBE}")
    with tempfile.TemporaryDirectory(prefix="elisapkg-trust-lock-", dir=ROOT / "build") as directory:
        check_contended_lock_recovery()
        check_invalid_lock_objects(Path(directory))
    print("Elisa trust-state lock regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
