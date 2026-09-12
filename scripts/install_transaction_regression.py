#!/usr/bin/env python3
"""Exercise durable local install and uninstall recovery states."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "build/elisapkg"
ARTIFACT = b"#!/bin/sh\nprintf '%s\\n' transaction-fixture\n"
VERSION = b"1.2.3"
DIGEST = hashlib.sha256(ARTIFACT).hexdigest().encode("ascii")


def run(args: list[str], prefix: Path, expected: int, label: str) -> subprocess.CompletedProcess[bytes]:
    environment = dict(os.environ)
    environment["ELISAPKG_INSTALL_PREFIX"] = str(prefix)
    result = subprocess.run(
        [str(BIN), *args],
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
    return result


def write_transaction(path: Path, operation: str) -> None:
    payload = (
        b"elisapkg-install-transaction:1\n"
        + f"operation:{operation}\nname:app\nversion:".encode("ascii")
        + VERSION
        + b"\nartifact-digest:sha256:"
        + DIGEST
        + b"\n"
    )
    path.write_bytes(payload)
    path.chmod(0o600)


def write_install(prefix: Path) -> tuple[Path, Path, Path, bytes]:
    binary = prefix / "bin/app"
    receipt = prefix / "share/elisapkg/receipts/app"
    journal = prefix / ".elisapkg-install-transaction"
    binary.write_bytes(ARTIFACT)
    binary.chmod(0o755)
    receipt_bytes = (
        b"elisapkg-install-receipt:1\nname:app\nversion:"
        + VERSION
        + b"\npath:"
        + str(binary).encode("utf-8")
        + b"\nartifact-digest:sha256:"
        + DIGEST
        + b"\n"
    )
    receipt.write_bytes(receipt_bytes)
    receipt.chmod(0o600)
    return binary, receipt, journal, receipt_bytes


def main() -> int:
    if not BIN.is_file():
        raise SystemExit(f"error: built elisapkg binary is missing: {BIN}")

    with tempfile.TemporaryDirectory(prefix="elisapkg-install-transaction-", dir=ROOT / "build") as temporary:
        prefix = Path(temporary) / "prefix"
        (prefix / "bin").mkdir(parents=True, mode=0o755)
        (prefix / "share/elisapkg/receipts").mkdir(parents=True, mode=0o755)
        binary = prefix / "bin/app"
        receipt = prefix / "share/elisapkg/receipts/app"
        journal = prefix / ".elisapkg-install-transaction"

        too_long_prefix = Path("/" + ("p" * 4006))
        run(["uninstall", "--local", "app"], too_long_prefix, 2, "overlong install prefix")

        # A crash after durable intent but before either target publication is
        # safe to abandon; the next locked operation clears it and continues.
        write_transaction(journal, "install")
        run(["uninstall", "--local", "other"], prefix, 7, "unpublished install intent")
        if journal.exists():
            raise SystemExit("error: recovery retained an install intent with no published files")

        # A malformed journal fails closed and remains available for inspection.
        write_install(prefix)
        journal.write_bytes(b"not a transaction\n")
        journal.chmod(0o600)
        run(["uninstall", "--local", "app"], prefix, 7, "malformed transaction")
        if not binary.is_file() or not receipt.is_file() or not journal.is_file():
            raise SystemExit("error: malformed journal recovery changed package files or discarded evidence")
        journal.unlink()

        # Model a process stopping after executable publication but before chmod
        # or receipt publication. Recovery verifies the digest, applies 0755,
        # publishes the exact receipt, and retires the journal.
        binary.chmod(0o600)
        receipt.unlink()
        write_transaction(journal, "install")
        run(["uninstall", "--local", "other"], prefix, 7, "install recovery after executable publication")
        expected_receipt = (
            b"elisapkg-install-receipt:1\nname:app\nversion:"
            + VERSION
            + b"\npath:"
            + str(binary).encode("utf-8")
            + b"\nartifact-digest:sha256:"
            + DIGEST
            + b"\n"
        )
        if journal.exists() or binary.read_bytes() != ARTIFACT or not os.access(binary, os.X_OK) or receipt.read_bytes() != expected_receipt:
            raise SystemExit("error: install recovery did not restore the expected executable and receipt")

        # If both install products are already durable, recovery only retires the
        # intent. A different requested package must leave the recovered app.
        write_transaction(journal, "install")
        run(["uninstall", "--local", "other"], prefix, 7, "recovery after complete install publication")
        if journal.exists() or binary.read_bytes() != ARTIFACT or receipt.read_bytes() != expected_receipt:
            raise SystemExit("error: completed install recovery changed the installed package")

        # A durable uninstall intent with both unchanged products still present
        # must be completed instead of asking the user to retry manually.
        write_transaction(journal, "uninstall")
        run(["uninstall", "--local", "app"], prefix, 0, "uninstall recovery before first unlink")
        if binary.exists() or receipt.exists() or journal.exists():
            raise SystemExit("error: recovery did not finish an untouched uninstall intent")
        write_install(prefix)

        # Invalid journal entries, including symlinks, are never followed or
        # silently replaced. The referenced outside file must remain untouched.
        journal.write_bytes(b"broken\n")
        journal.chmod(0o600)
        run(["uninstall", "--local", "app"], prefix, 7, "invalid uninstall journal")
        if not binary.is_file() or not receipt.is_file() or not journal.is_file():
            raise SystemExit("error: invalid journal did not preserve package evidence")
        journal.unlink()
        outside = Path(temporary) / "outside"
        outside.write_text("preserve\n", encoding="ascii")
        journal.symlink_to(outside)
        run(["uninstall", "--local", "app"], prefix, 7, "symlinked journal")
        if outside.read_text(encoding="ascii") != "preserve\n" or not journal.is_symlink():
            raise SystemExit("error: symlinked journal recovery followed or replaced its target")
        journal.unlink()

        # An uninstall intent cannot authorize deletion of a changed executable.
        # Once the expected bytes return, a crash after its unlink is completed by
        # removing only the exact receipt recorded in the journal.
        write_transaction(journal, "uninstall")
        with binary.open("ab") as stream:
            stream.write(b"changed")
        run(["uninstall", "--local", "app"], prefix, 7, "mismatched executable")
        if not binary.is_file() or not receipt.is_file() or not journal.is_file():
            raise SystemExit("error: mismatched executable recovery removed evidence")
        binary.write_bytes(ARTIFACT)
        binary.chmod(0o755)
        binary.unlink()
        run(["uninstall", "--local", "app"], prefix, 0, "recovery after executable removal")
        if binary.exists() or receipt.exists() or journal.exists():
            raise SystemExit("error: recovery did not finish after the executable unlink")

        # When the binary is gone but its receipt has changed, retain both the
        # receipt and journal. Restoring the exact receipt makes recovery safe.
        _, receipt, journal, receipt_bytes = write_install(prefix)
        write_transaction(journal, "uninstall")
        binary.unlink()
        with receipt.open("ab") as stream:
            stream.write(b"changed")
        run(["uninstall", "--local", "app"], prefix, 7, "mismatched receipt")
        if binary.exists() or not receipt.is_file() or not journal.is_file():
            raise SystemExit("error: mismatched receipt recovery changed package evidence")
        receipt.write_bytes(receipt_bytes)
        receipt.chmod(0o600)
        run(["uninstall", "--local", "app"], prefix, 0, "recovery after receipt restoration")
        if binary.exists() or receipt.exists() or journal.exists():
            raise SystemExit("error: uninstall recovery left files or its journal")

        # A normal uninstall writes its own intent and retires it after both
        # identity checks and durable removals. A stop after both unlinks then
        # needs only journal cleanup on retry.
        write_install(prefix)
        run(["uninstall", "--local", "app"], prefix, 0, "normal journaled uninstall")
        if binary.exists() or receipt.exists() or journal.exists():
            raise SystemExit("error: normal uninstall left package files or its journal")
        write_transaction(journal, "uninstall")
        run(["uninstall", "--local", "app"], prefix, 0, "recovery after complete uninstall")
        if journal.exists():
            raise SystemExit("error: completed uninstall journal was not retired")

    print("Elisa install transaction regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
