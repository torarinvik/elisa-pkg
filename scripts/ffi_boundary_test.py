#!/usr/bin/env python3
"""Keep the native implementation in Elisa with one explicit FFI seam."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NATIVE_MODULE = (ROOT / "src/platform_native.elisa").resolve()
SOURCE_SUFFIXES = {".elisa", ".py", ".sh", ".md", ".json", ".lock", ".mk"}
FORBIDDEN_NATIVE_SUFFIXES = {".c", ".h", ".cc", ".cpp", ".cxx", ".hpp"}
FOREIGN_DECLARATION = re.compile(r"^\s*(?:@link_name\b|extern\b)")
NATIVE_SYMBOL = re.compile(r"\bnative_[A-Za-z0-9_]+\b")


def source_files():
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if relative.parts[0] in {".git", "build"}:
            continue
        if path.name == "IMPLEMENTATION_PLAN.md":
            continue
        yield path


def main() -> int:
    native_files = [
        path.relative_to(ROOT)
        for path in source_files()
        if path.suffix.lower() in FORBIDDEN_NATIVE_SUFFIXES
    ]
    if native_files:
        print("error: native C implementation files are forbidden; keep OS code in Elisa FFI", flush=True)
        for path in native_files:
            print(f"  {path}", flush=True)
        return 1

    violations = []
    for path in source_files():
        if path.suffix != ".elisa":
            continue
        text = path.read_text(encoding="utf-8")
        if path.resolve() != NATIVE_MODULE:
            for line_number, line in enumerate(text.splitlines(), 1):
                if FOREIGN_DECLARATION.search(line) or NATIVE_SYMBOL.search(line):
                    violations.append((path.relative_to(ROOT), line_number, line.strip()))
    if violations:
        print("error: foreign declarations or native symbols escaped the private FFI module", flush=True)
        for path, line_number, line in violations:
            print(f"  {path}:{line_number}: {line}", flush=True)
        return 1

    print("Elisa FFI boundary passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
