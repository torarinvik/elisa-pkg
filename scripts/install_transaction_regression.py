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


def check_install_recovery_sync_order() -> None:
    source = (ROOT / "src/main.elisa").read_text(encoding="utf-8")
    retire_start = source.find("def retire_local_install_transaction(")
    retire_end = source.find("def remove_empty_directory(", retire_start)
    if retire_start < 0 or retire_end < 0:
        raise SystemExit("error: durable local install transaction retirement helper is missing")
    retire = source[retire_start:retire_end]
    unlink = retire.find("remove_known_file(&path_snapshot)")
    journal_parent_sync = retire.find("Platform::pkg_fsync_parent(path_name)")
    if unlink < 0 or journal_parent_sync <= unlink:
        raise SystemExit("error: transaction journal retirement must sync its parent after unlink")

    recovery_start = source.find("def recover_local_install_transaction(")
    recovery_end = source.find("def finish_local_install_error(", recovery_start)
    if recovery_start < 0 or recovery_end < 0:
        raise SystemExit("error: local install recovery implementation is missing")
    recovery = source[recovery_start:recovery_end]
    install_start = recovery.find('if bytes_equal_view(operation, "install"):')
    uninstall_start = recovery.find("# Removal intent is durable", install_start)
    copy_outputs_start = recovery.find("for index in 0..<operation.count", uninstall_start)
    if install_start < 0 or uninstall_start < 0 or copy_outputs_start < 0:
        raise SystemExit("error: local install recovery branches are missing")
    install_branch = recovery[install_start:uninstall_start]
    journal_retire = install_branch.rfind("retire_local_install_transaction(transaction_path)")
    install_sync = install_branch.rfind("sync_local_install_entry_parents(destination_name, receipt_name)")
    if install_sync < 0 or install_sync >= journal_retire:
        raise SystemExit("error: install recovery must sync both target directories before retiring its journal")

    uninstall_branch = recovery[uninstall_start:copy_outputs_start]
    retire_positions = []
    cursor = 0
    while True:
        position = uninstall_branch.find("retire_local_install_transaction(transaction_path)", cursor)
        if position < 0:
            break
        retire_positions.append(position)
        cursor = position + 1
    if len(retire_positions) != 2:
        raise SystemExit("error: uninstall recovery journal-retirement paths changed unexpectedly")
    previous_retire = -1
    for position in retire_positions:
        sync = uninstall_branch.rfind(
            "sync_local_install_entry_parents(destination_name, receipt_name)",
            previous_retire + 1,
            position,
        )
        if sync < 0:
            raise SystemExit("error: uninstall recovery must sync both target directories before retiring its journal")
        previous_retire = position

    publish_start = source.find("def publish_local_install_receipt(")
    publish_end = source.find("def recover_local_install_transaction(", publish_start)
    if publish_start < 0 or publish_end < 0:
        raise SystemExit("error: local receipt publication helper is missing")
    publish = source[publish_start:publish_end]
    matching_receipt = publish.find("return false if not bytes_equal(existing, receipt)")
    parent_sync = publish.find("Platform::pkg_fsync_parent(path_name)")
    if matching_receipt < 0 or parent_sync <= matching_receipt:
        raise SystemExit("error: receipt publication must sync its parent before success")

    for begin, end, label in (
        ("def run_install_local(", "def run_install(", "install"),
        ("def run_uninstall_local(", "def run_uninstall(", "uninstall"),
    ):
        start = source.find(begin)
        stop = source.find(end, start)
        if start < 0 or stop < 0:
            raise SystemExit(f"error: normal local {label} implementation is missing")
        operation = source[start:stop]
        retire = operation.rfind("retire_local_install_transaction(transaction_path)")
        sync = operation.rfind("sync_local_install_entry_parents(destination_name, receipt_sync_name)" if label == "install" else "sync_local_install_entry_parents(destination_name, receipt_name)")
        if sync < 0 or sync >= retire:
            raise SystemExit(f"error: normal local {label} must sync target directories before retiring its journal")


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
    check_install_recovery_sync_order()

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
