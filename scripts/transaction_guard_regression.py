#!/usr/bin/env python3
"""Check that another CLI process never replays a journal under its owner guard."""

import fcntl
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "build" / "elisapkg"


def run(*args: str, cwd: Path, expected: int) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(BIN), *args], cwd=cwd, capture_output=True, text=True, timeout=30, check=False
    )
    if result.returncode != expected:
        raise SystemExit(
            f"{args!r} returned {result.returncode}, expected {expected}: "
            f"stdout={result.stdout!r} stderr={result.stderr!r}"
        )
    return result


def main() -> int:
    if not BIN.is_file():
        raise SystemExit(f"error: package manager binary is missing: {BIN}")
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elisapkg-transaction-", dir=build) as raw:
        project = Path(raw)
        run("init", str(project), cwd=ROOT, expected=0)
        run("resolve", cwd=project, expected=0)

        state = project / ".elisapkg"
        manifest = project / "elisapkg.json"
        lock = project / "elisapkg.lock"
        original_manifest = manifest.read_bytes()
        original_lock = lock.read_bytes()
        new_manifest = b"{}\n"
        new_lock = original_lock + b" "
        (state / "transaction.manifest").write_bytes(original_manifest)
        (state / "transaction.lock").write_bytes(original_lock)
        (state / "transaction.new-manifest").write_bytes(new_manifest)
        (state / "transaction.new-lock").write_bytes(new_lock)
        (state / "transaction.state").write_bytes(b"manifest-replaced\n")
        manifest.write_bytes(new_manifest)
        lock.write_bytes(new_lock)
        guard = state / "transaction.guard"
        guard.mkdir(mode=0o700)
        transaction_flock = state / "transaction.flock"

        # Hold the same kernel lock as an active mutator while invoking the CLI.
        transaction_flock.touch(mode=0o600, exist_ok=True)
        with transaction_flock.open("r+b") as descriptor:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run("check-manifest", cwd=project, expected=5)
            run("resolve", cwd=project, expected=5)
        if manifest.read_bytes() != new_manifest or lock.read_bytes() != new_lock:
            raise SystemExit("active-guard refusal changed the manifest or lockfile")
        if not (state / "transaction.state").is_file() or not guard.is_dir():
            raise SystemExit("active-guard refusal removed transaction recovery evidence")

        # Process exit releases the flock and leaves the directory behind.
        # Recovery must restore the original manifest and lock in that state.
        run("check-manifest", cwd=project, expected=0)
        if manifest.read_bytes() != original_manifest or lock.read_bytes() != original_lock:
            raise SystemExit("recovery after lock release did not restore the original pair")
        if (state / "transaction.state").exists() or guard.exists():
            raise SystemExit("successful transaction recovery retained its journal")

        # A writer acquires the flock before it creates its guard or journal.
        with transaction_flock.open("r+b") as descriptor:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run("check-manifest", cwd=project, expected=5)
        run("check-manifest", cwd=project, expected=0)

        # The manifest replacement intent is durable before publication. A
        # crash on either side of the manifest rename must safely roll back.
        (state / "transaction.manifest").write_bytes(original_manifest)
        (state / "transaction.lock").write_bytes(original_lock)
        (state / "transaction.new-manifest").write_bytes(new_manifest)
        (state / "transaction.state").write_bytes(b"manifest-pending\n")
        run("check-manifest", cwd=project, expected=0)
        if manifest.read_bytes() != original_manifest:
            raise SystemExit("pending recovery before publication changed the original manifest")
        if (state / "transaction.state").exists():
            raise SystemExit("pending recovery before publication retained its journal")

        (state / "transaction.manifest").write_bytes(original_manifest)
        (state / "transaction.lock").write_bytes(original_lock)
        (state / "transaction.new-manifest").write_bytes(new_manifest)
        (state / "transaction.state").write_bytes(b"manifest-pending\n")
        manifest.write_bytes(new_manifest)
        run("check-manifest", cwd=project, expected=0)
        if manifest.read_bytes() != original_manifest:
            raise SystemExit("pending recovery after publication did not restore the original manifest")
        if (state / "transaction.state").exists():
            raise SystemExit("pending recovery after publication retained its journal")

        # Recovery must reject an unrelated edit during a pending phase, while
        # retaining evidence so the user can restore the known original and
        # safely retry recovery.
        (state / "transaction.manifest").write_bytes(original_manifest)
        (state / "transaction.lock").write_bytes(original_lock)
        (state / "transaction.new-manifest").write_bytes(new_manifest)
        (state / "transaction.state").write_bytes(b"manifest-pending\n")
        external_manifest = b'{"external":"manifest-edit"}\n'
        manifest.write_bytes(external_manifest)
        run("check-manifest", cwd=project, expected=5)
        if manifest.read_bytes() != external_manifest or not (state / "transaction.state").is_file():
            raise SystemExit("pending recovery overwrote an external edit or discarded its journal")
        if not guard.is_dir():
            raise SystemExit("failed recovery discarded its transaction guard")
        manifest.write_bytes(original_manifest)
        run("check-manifest", cwd=project, expected=0)

        # Older releases could crash after restoration but before deleting the
        # journal. Replaying that recovery must remain idempotent.
        (state / "transaction.manifest").write_bytes(original_manifest)
        (state / "transaction.lock").write_bytes(original_lock)
        (state / "transaction.new-manifest").write_bytes(new_manifest)
        (state / "transaction.state").write_bytes(b"manifest-replaced\n")
        run("check-manifest", cwd=project, expected=0)
        if manifest.read_bytes() != original_manifest or (state / "transaction.state").exists():
            raise SystemExit("recovery after an already-restored manifest was not idempotent")

        # A resolver can be interrupted after staging replacement bytes but
        # before publishing a lock that did not exist when the transaction
        # began. Recovery must still recognize this as its own staged write.
        lock.unlink()
        (state / "transaction.manifest").write_bytes(original_manifest)
        (state / "transaction.new-lock").write_bytes(original_lock)
        (state / "transaction.state").write_bytes(b"prepared-no-lock\n")
        run("check-manifest", cwd=project, expected=0)
        if lock.exists() or manifest.read_bytes() != original_manifest:
            raise SystemExit("recovery did not preserve the original missing-lock state")
        if (state / "transaction.state").exists():
            raise SystemExit("missing-lock recovery retained its journal")

        # A prepared journal declaring an original lock cannot recover without
        # its backup, even when the staged operation removed the live lock.
        (state / "transaction.manifest").write_bytes(original_manifest)
        (state / "transaction.new-lock-missing").write_bytes(b"missing\n")
        journal = state / "transaction.state"
        journal.write_bytes(b"prepared-lock\n")
        run("check-manifest", cwd=project, expected=5)
        if lock.exists() or manifest.read_bytes() != original_manifest:
            raise SystemExit("recovery changed live files without the required lock backup")
        if journal.read_bytes() != b"prepared-lock\n":
            raise SystemExit("recovery discarded the journal while its backup was missing")
        (state / "transaction.lock").write_bytes(original_lock)
        run("check-manifest", cwd=project, expected=0)
        if lock.read_bytes() != original_lock:
            raise SystemExit("recovery did not restore the repaired lock backup")
        lock.unlink()

        # Final markers survive interrupted cleanup. Once present, recovery
        # must finish cleanup without replaying backups or requiring the guard.
        for terminal_state in (b"complete\n", b"restored\n"):
            journal.write_bytes(terminal_state)
            leftover = state / "transaction.new-manifest"
            leftover.write_bytes(new_manifest)
            run("check-manifest", cwd=project, expected=0)
            if manifest.read_bytes() != original_manifest or lock.exists():
                raise SystemExit(f"cleanup replayed an already finalized transaction: {terminal_state!r}")
            if journal.exists() or leftover.exists() or guard.exists():
                raise SystemExit(f"cleanup retained a finalized transaction: {terminal_state!r}")
            run("check-manifest", cwd=project, expected=0)

        # A modern guard can be recovered after a crash before journal publication.
        guard.mkdir(mode=0o700)
        (state / "transaction.manifest").write_bytes(original_manifest)
        unexpected = guard / "unexpected"
        unexpected.write_bytes(b"preserve this file")
        run("check-manifest", cwd=project, expected=5)
        if unexpected.read_bytes() != b"preserve this file":
            raise SystemExit("partial recovery modified unexpected guard contents")
        if manifest.read_bytes() != original_manifest or lock.exists():
            raise SystemExit("failed partial recovery touched the manifest or lockfile")
        unexpected.unlink()
        run("check-manifest", cwd=project, expected=0)
        if guard.exists() or (state / "transaction.manifest").exists():
            raise SystemExit("recovery retained files from a partially prepared journal")

        # A legacy guard has no flock file and requires operator recovery.
        transaction_flock.unlink()
        guard.mkdir(mode=0o700)
        run("check-manifest", cwd=project, expected=5)
        if not guard.is_dir():
            raise SystemExit("guard-only refusal removed the guard")
        guard.rmdir()

    print("transaction guard regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
