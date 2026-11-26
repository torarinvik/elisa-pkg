#!/usr/bin/env python3
"""Enforce the repository's source length and directory size limits."""

import collections
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
MAX_SOURCE_LINES = 600
MAX_DIRECTORY_FILES = 20
SOURCE_SUFFIXES = {".elisa", ".py", ".sh"}


def main() -> int:
    entries = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    )
    paths = sorted({Path(os.fsdecode(entry)) for entry in entries.split(b"\0") if entry})
    directories: collections.Counter[Path] = collections.Counter()
    failures: list[str] = []
    for relative_path in paths:
        path = ROOT / relative_path
        if not path.is_file():
            continue
        directories[relative_path.parent] += 1
        if relative_path.suffix not in SOURCE_SUFFIXES and relative_path.name != "Makefile":
            continue
        with path.open("rb") as stream:
            lines = sum(1 for _ in stream)
        if lines > MAX_SOURCE_LINES:
            failures.append(f"{relative_path}: {lines} lines (limit {MAX_SOURCE_LINES})")
    for directory, files in sorted(directories.items()):
        if files > MAX_DIRECTORY_FILES:
            failures.append(f"{directory}: {files} files (limit {MAX_DIRECTORY_FILES})")
    if failures:
        print("\n".join(failures))
        return 1
    print("Source layout checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
