#!/usr/bin/env python3
"""Check that another CLI process never replays a journal under its owner guard."""

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

        # This is a separate CLI process observing the exact state left by a
        # live mutator. It must fail without restoring files or consuming its
        # journal while the mutator's guard remains present.
        run("check-manifest", cwd=project, expected=5)
        run("resolve", cwd=project, expected=5)
        if manifest.read_bytes() != new_manifest or lock.read_bytes() != new_lock:
            raise SystemExit("active-guard refusal changed the manifest or lockfile")
        if not (state / "transaction.state").is_file() or not guard.is_dir():
            raise SystemExit("active-guard refusal removed transaction recovery evidence")

        # Once the owner guard is absent, recovery claims it and restores the
        # original manifest/lock pair from the staged journal.
        guard.rmdir()
        run("check-manifest", cwd=project, expected=0)
        if manifest.read_bytes() != original_manifest or lock.read_bytes() != original_lock:
            raise SystemExit("recovery without an active guard did not restore the original pair")
        if (state / "transaction.state").exists() or guard.exists():
            raise SystemExit("successful transaction recovery retained its journal")

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

        # A guard with no state marker is also fail-closed instead of being
        # mistaken for an unused project directory.
        guard.mkdir(mode=0o700)
        run("check-manifest", cwd=project, expected=5)
        if not guard.is_dir():
            raise SystemExit("guard-only refusal removed the guard")
        guard.rmdir()

    print("transaction guard regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
