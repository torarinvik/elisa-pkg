#!/usr/bin/env python3
"""Exercise durable local install and uninstall recovery states."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "build/elisapkg"
ARTIFACT = b"#!/bin/sh\nprintf '%s\\n' transaction-fixture\n"
VERSION = b"1.2.3"
DIGEST = hashlib.sha256(ARTIFACT).hexdigest().encode("ascii")


def function_source(source: str, name: str) -> str:
    declaration = re.search(rf"(?m)^( +)def {re.escape(name)}\(", source)
    if declaration is None:
        raise SystemExit(f"error: could not locate {name}")
    indentation = declaration[1]
    remainder = source[declaration.end():]
    next_declaration = re.search(rf"(?m)^(?:{indentation}def | +(?:public|private):)", remainder)
    end = declaration.end() + next_declaration.start() if next_declaration else len(source)
    return source[declaration.start():end]


# Argument spellings change with refactors; these patterns match the call and
# its qualifier only, so each check asserts the ordering it protects.
UNLINK_CALL = re.compile(r"\bremove_known_file\(")
PARENT_SYNC_CALL = re.compile(r"\b(?:ProjectFiles::sync_parent_directory|Platform::synchronize_parent_directory)\(")
ENTRY_PARENTS_SYNC_CALL = re.compile(r"\bsync_local_install_entry_parents\(")
JOURNAL_RETIRE_CALL = re.compile(r"\bretire_local_install_transaction\(")
SYNC_AND_RETIRE_CALL = re.compile(r"\bsync_and_retire\(")
# The sync result must gate the retirement, not merely precede it.
GATED_SYNC_AND_RETIRE = re.compile(
    r"\bsync_local_install_entry_parents\([^\n]*\)\s+and\s+retire_local_install_transaction\("
)
SYNC_FAILURE_RETURNS = re.compile(
    r"if not (?:\w+::)?sync_local_install_entry_parents\([^\n]*\n\s+return "
)


def positions(pattern: re.Pattern[str], text: str) -> list[int]:
    return [match.start() for match in pattern.finditer(text)]


def check_journal_retirement(source: str) -> None:
    retire = function_source(source, "retire_local_install_transaction")
    unlinks = positions(UNLINK_CALL, retire)
    parent_syncs = positions(PARENT_SYNC_CALL, retire)
    if not unlinks or not parent_syncs or parent_syncs[-1] <= unlinks[0]:
        raise SystemExit("error: transaction journal retirement must sync its parent after unlink")


def check_entry_parent_sync(source: str) -> None:
    sync = function_source(source, "sync_local_install_entry_parents")
    if len(positions(PARENT_SYNC_CALL, sync)) != 2:
        raise SystemExit("error: local install entry sync must sync both the binary and receipt directories")


def check_recovery_dispatch(source: str) -> None:
    recovery = function_source(source, "recover_local_install_transaction")
    install_start = recovery.find('if ByteText::equal_text(operation, "install"):')
    install_call = recovery.find("recover_install(", install_start)
    uninstall_call = recovery.find("recover_uninstall(", install_call)
    if install_start < 0 or install_call < 0 or uninstall_call < 0:
        raise SystemExit("error: local install recovery branches are missing")
    if positions(JOURNAL_RETIRE_CALL, recovery) or positions(SYNC_AND_RETIRE_CALL, recovery):
        raise SystemExit("error: local install recovery must retire its journal only inside the per-operation branches")


def check_recovery_retirement(source: str) -> None:
    sync_and_retire = function_source(source, "sync_and_retire")
    if not GATED_SYNC_AND_RETIRE.search(sync_and_retire):
        raise SystemExit("error: recovery must sync both target directories before retiring its journal")

    install = function_source(source, "recover_install")
    # Only an intent with neither target published may retire without a
    # directory sync: there is no new name for the sync to make durable.
    for position in positions(JOURNAL_RETIRE_CALL, install):
        line_end = install.find("\n", position)
        line = install[install.rfind("\n", 0, position) + 1:line_end]
        if "destination_state == -2 and targets.receipt_state == -2" not in line:
            raise SystemExit("error: install recovery must sync both target directories before retiring its journal")
    install_retirements = positions(SYNC_AND_RETIRE_CALL, install)
    published = install.find("published <- true")
    if not install_retirements or published < 0 or install_retirements[-1] >= published:
        raise SystemExit("error: install recovery must sync both target directories before retiring its journal")

    uninstall = function_source(source, "recover_uninstall")
    if positions(JOURNAL_RETIRE_CALL, uninstall):
        raise SystemExit("error: uninstall recovery must sync both target directories before retiring its journal")
    if len(positions(SYNC_AND_RETIRE_CALL, uninstall)) != 2:
        raise SystemExit("error: uninstall recovery journal-retirement paths changed unexpectedly")


def check_receipt_publication(source: str) -> None:
    publish = function_source(source, "publish_local_install_receipt")
    matching_receipt = publish.find("ByteText::equal(existing, receipt)")
    parent_syncs = positions(PARENT_SYNC_CALL, publish)
    if matching_receipt < 0 or not parent_syncs or parent_syncs[-1] <= matching_receipt:
        raise SystemExit("error: receipt publication must sync its parent before success")


def check_normal_operations() -> None:
    command_source = (ROOT / "src/cli/local_install.elisa").read_text(encoding="utf-8")
    for function, label in (("publish_new", "install"), ("remove_installed", "uninstall")):
        operation = function_source(command_source, function)
        retirements = positions(JOURNAL_RETIRE_CALL, operation)
        syncs = positions(ENTRY_PARENTS_SYNC_CALL, operation)
        if len(retirements) != 1 or not syncs or syncs[-1] >= retirements[0] or not SYNC_FAILURE_RETURNS.search(operation):
            raise SystemExit(f"error: normal local {label} must sync target directories before retiring its journal")


def check_install_recovery_sync_order() -> None:
    source = (ROOT / "src/package/install_transaction.elisa").read_text(encoding="utf-8")
    check_journal_retirement(source)
    check_entry_parent_sync(source)
    check_recovery_dispatch(source)
    check_recovery_retirement(source)
    check_receipt_publication(source)
    check_normal_operations()


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

    # The install boundary verifies every parent directory's owner and write
    # bits. The checkout can sit on a shared mount, so run recovery fixtures
    # below the current user's private home directory.
    with tempfile.TemporaryDirectory(prefix="elisapkg-install-transaction-", dir=Path.home()) as temporary:
        prefix = Path(temporary) / "prefix"
        for directory in (
            prefix,
            prefix / "bin",
            prefix / "share",
            prefix / "share/elisapkg",
            prefix / "share/elisapkg/receipts",
        ):
            directory.mkdir(mode=0o755)
            directory.chmod(0o755)
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
