#!/usr/bin/env python3
"""Verify compiler-child descriptor cleanup survives dup2 and exec."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
compiler_root_text = os.environ.get("ELISA_COMPILER_ROOT", "")
if not compiler_root_text:
    raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")
COMPILER_ROOT = Path(compiler_root_text)
STAGE1 = Path(os.environ.get("ELISA_STAGE1_BIN", COMPILER_ROOT / "bin/elisac-stage1"))
WRAPPER = Path(os.environ.get("ELISA_COMPILER_WRAPPER", COMPILER_ROOT / "scripts/elisac_stage1.sh"))
RUNTIME = Path(os.environ.get("ELISA_RUNTIME_OBJ", COMPILER_ROOT / "build/runtime/elisacore_runtime.o"))


def main() -> int:
    for label, path in (("stage1 compiler", STAGE1), ("compiler wrapper", WRAPPER), ("runtime object", RUNTIME)):
        if not path.exists():
            raise SystemExit(f"error: {label} is missing: {path}")

    source = (ROOT / "src/main.elisa").read_text(encoding="utf-8")
    stdio_setup = source.find("if null_fd < 0 or Platform::pkg_dup2(null_fd, 0)")
    child_setup = source.find("if null_fd > 2:")
    descriptor_close = source.find("Platform::pkg_close_inherited_fds()", child_setup)
    compiler_exec = source.find('Platform::pkg_execvp("/usr/bin/sandbox-exec", child_argv)', child_setup)
    if stdio_setup < 0 or not stdio_setup < child_setup < descriptor_close < compiler_exec:
        raise SystemExit("error: compiler launch must close inherited descriptors after stdio setup and before exec")

    (ROOT / "build").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elisapkg-fd-cleanup-", dir=ROOT / "build") as directory:
        work = Path(directory)
        probe = work / "fd_probe.elisa"
        binary = work / "fd_probe"
        probe.write_text(
            f'include "{ROOT / "src/platform_native.elisa"}"\n\n'
            'def main() -> i64 can[Memory.Allocate, Abort.Panic, Unsafe.PointerCast]:\n'
            '    inherited_fd: i64 = PlatformNative::open_null()\n'
            '    return 1 if inherited_fd < 3\n'
            '    fd_path: mutable darray[u8] = [47, 100, 101, 118, 47, 102, 100, 47]\n'
            '    digits: mutable darray[u8] = []\n'
            '    number: mutable i64 = inherited_fd\n'
            '    while number > 0 |digits, number|:\n'
            '        digits.push(48 + (number % 10).u8())\n'
            '        number <- number / 10\n'
            '    cursor: mutable usize = digits.count\n'
            '    while cursor > 0.usize() |fd_path, digits, cursor|:\n'
            '        cursor <- cursor - 1.usize()\n'
            '        fd_path.push(digits[cursor])\n'
            '    fd_path.push(0)\n'
            '    fd_name: cstr = (&fd_path[0]).cast[cstr] can Unsafe.PointerCast\n'
            '    args: mutable darray[cstr] = []\n'
            '    args.push("/bin/sh")\n'
            '    args.push("-c")\n'
            '    args.push("test -e \\\"$1\\\" -a ! -e \\\"$2\\\"")\n'
            '    args.push("elisapkg-fd-probe")\n'
            '    args.push("/dev/fd/1")\n'
            '    args.push(fd_name)\n'
            '    args.push(null)\n'
            '    child_argv: mutable cstr&& = (&args[0]).cast[mutable cstr&&] can Unsafe.PointerCast\n'
            '    pid: i64 = PlatformNative::fork()\n'
            '    if pid == 0:\n'
            '        return 126 if PlatformNative::duplicate_fd(inherited_fd, 1) != 1\n'
            '        return 126 if PlatformNative::close_inherited_fds() != 0\n'
            '        _ = PlatformNative::execvp("/bin/sh", child_argv)\n'
            '        PlatformNative::process_exit(127)\n'
            '    return 2 if pid < 0\n'
            '    status: mutable i32 = 0\n'
            '    waited: i64 = PlatformNative::waitpid(pid, &status, 0)\n'
            '    _ = PlatformNative::close(inherited_fd)\n'
            '    return 3 if waited != pid\n'
            '    return 4 if status != 0\n'
            '    return 0\n',
            encoding="utf-8",
        )
        environment = dict(os.environ)
        environment["ELISA_STAGE1_BIN"] = str(STAGE1)
        environment["ELISA_RUNTIME_OBJ"] = str(RUNTIME)
        environment.setdefault("ELISA_ALLOW_STALE_STAGE1", "0")
        subprocess.run(
            [str(WRAPPER), "-emit", "exe", "-o", str(binary), str(probe)],
            cwd=work,
            env=environment,
            check=True,
            timeout=120,
        )
        try:
            result = subprocess.run([str(binary)], cwd=work, timeout=5, check=False)
        except subprocess.TimeoutExpired as error:
            raise SystemExit("error: inherited descriptor child failed to exit") from error
        if result.returncode != 0:
            raise SystemExit(f"error: inherited descriptor probe exited {result.returncode}")

    print("Elisa inherited descriptor regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
