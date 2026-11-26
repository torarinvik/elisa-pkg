#!/usr/bin/env python3
"""Keep the native implementation in Elisa with one explicit FFI seam."""

import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FFI_DECLARATIONS = (ROOT / "src/platform/libc.elisa").resolve()
NATIVE_MODULE = (ROOT / "src/platform_native.elisa").resolve()
GENERATED_DIRECTORIES = {".git", ".elisapkg", ".ruff_cache", "build"}
FORBIDDEN_NATIVE_SUFFIXES = {".c", ".h", ".cc", ".cpp", ".cxx", ".hpp"}
FOREIGN_DECLARATION = re.compile(r"^\s*(?:@link_name\b|extern\b)")
NATIVE_SYMBOL = re.compile(r"\bnative_[A-Za-z0-9_]+\b")
C_INT_RETURN_SYMBOLS = {
    "native_open",
    "native_openat",
    "native_mkdirat",
    "native_unlinkat",
    "native_renameat",
    "native_linkat",
    "native_close",
    "native_getdtablesize",
    "native_dup",
    "native_dup2",
    "native_fcntl",
    "native_fsync",
    "native_flock",
    "native_fchmod",
    "native_fchdir",
    "native_fstat",
    "native_fstatat",
    "native_faccessat",
    "native_closedir",
    "native_fork",
    "native_execvp",
    "native_setpgid",
    "native_getpid",
    "native_waitpid",
    "native_kill",
    "native_clock_gettime",
    "native_nanosleep",
    "native_setrlimit",
}
C_SSIZE_T_RETURN_SYMBOLS = {"native_fgetxattr"}


def source_files():
    for directory, children, names in os.walk(ROOT, followlinks=False):
        if Path(directory) == ROOT:
            children[:] = sorted(set(children) - GENERATED_DIRECTORIES)
        else:
            children.sort()
        for name in sorted(names):
            path = Path(directory) / name
            if path.is_file():
                yield path


def main() -> int:
    native_source = FFI_DECLARATIONS.read_text(encoding="utf-8")
    extern_returns = dict(
        re.findall(
            r"(?m)^\s*extern\s+(native_[A-Za-z0-9_]+)\([^\n]*\)\s*->\s*([A-Za-z0-9_]+)",
            native_source,
        )
    )
    bad_c_int_returns = sorted(
        name for name in C_INT_RETURN_SYMBOLS if extern_returns.get(name) != "i32"
    )
    if bad_c_int_returns:
        print("error: POSIX C int returns must use i32 at the FFI boundary", flush=True)
        for name in bad_c_int_returns:
            print(f"  {name}: expected i32, got {extern_returns.get(name, 'missing')}", flush=True)
        return 1

    bad_ssize_t_returns = sorted(
        name for name in C_SSIZE_T_RETURN_SYMBOLS if extern_returns.get(name) != "i64"
    )
    if bad_ssize_t_returns:
        print("error: 64-bit POSIX ssize_t returns must use i64 at the FFI boundary", flush=True)
        for name in bad_ssize_t_returns:
            print(f"  {name}: expected i64, got {extern_returns.get(name, 'missing')}", flush=True)
        return 1

    sources = list(source_files())
    native_files = [
        path.relative_to(ROOT)
        for path in sources
        if path.suffix.lower() in FORBIDDEN_NATIVE_SUFFIXES
    ]
    if native_files:
        print("error: native C implementation files are forbidden; keep OS code in Elisa FFI", flush=True)
        for path in native_files:
            print(f"  {path}", flush=True)
        return 1

    violations = []
    for path in sources:
        if path.suffix != ".elisa":
            continue
        text = path.read_text(encoding="utf-8")
        resolved = path.resolve()
        for line_number, line in enumerate(text.splitlines(), 1):
            foreign_declaration = resolved != FFI_DECLARATIONS and FOREIGN_DECLARATION.search(line)
            foreign_call = resolved not in {FFI_DECLARATIONS, NATIVE_MODULE} and NATIVE_SYMBOL.search(line)
            if foreign_declaration or foreign_call:
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
