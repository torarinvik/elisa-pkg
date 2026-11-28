# Toolchains

A toolchain is the set of files a build runs: the Elisa compiler wrapper, its
Stage1 executable, and the runtime object. `elisapkg toolchain` records
toolchains per user, so builds no longer need compiler environment variables.

## Commands

| Command | Effect |
| --- | --- |
| `toolchain link NAME PATH` | Register the Elisa compiler checkout at `PATH` as `NAME`. The first toolchain becomes the default. |
| `toolchain list` | Show the registered toolchains and mark the default. |
| `toolchain default [NAME]` | Show the default toolchain, or make `NAME` the default. |
| `toolchain unlink NAME` | Remove a toolchain record. Unlinking the default leaves no default. |

A name has 1 to 64 lowercase ASCII letters, digits, `.`, `_`, or `-`, and
starts with a letter or digit. Linking requires an executable
`scripts/elisac_stage1.sh`, an executable `bin/elisac-stage1`, and
`build/runtime/elisacore_runtime.o` under the checkout, and records their
canonical paths. A linked checkout is used in place: rebuilding its Stage1
changes the compiler that builds use, and the build cache notices because it
fingerprints every toolchain file.

```sh
elisapkg toolchain link dev /absolute/path/to/Elisa-compiler
elisapkg toolchain list
elisapkg doctor
```

## How a build selects its compiler

1. If `ELISAPKG_COMPILER` is set, the environment selects the compiler, and
   `ELISA_STAGE1_BIN` and `ELISA_RUNTIME_OBJ` select its Stage1 and runtime, as
   before toolchains existed.
2. Otherwise the default toolchain supplies all three files. Setting
   `ELISA_STAGE1_BIN` or `ELISA_RUNTIME_OBJ` without `ELISAPKG_COMPILER` is an
   error, so a build never mixes files from two compilers.
3. With neither, the build looks for `elisac-stage1` on its isolated `PATH`.

`ELISA_ALLOW_STALE_STAGE1` and `ELISA_CLANG` apply in every case. `doctor`
reports which of these selects the compiler.

## Storage and trust

Records live in `$HOME/.local/share/elisapkg/toolchains`: one
`NAME.toolchain` file per toolchain and a `default` file naming the default.
elisapkg creates each directory from `$HOME/.local` down with mode `0700` and
refuses the store if any of them, or any parent directory, is a symlink or is
writable by another user. Records are written atomically with mode `0600` and
read through the same no-follow trusted walk as registry trust state. A
malformed record is never used; `toolchain list` shows it as unreadable and
`toolchain unlink` removes it. A symlink inside the store makes listing fail
closed.

## Planned

Linking local checkouts is the first phase. Later phases, recorded in
[decisions](decisions.md#d-015-toolchain-management), add:

- Installing prebuilt, signed toolchain archives for macOS arm64, Linux x64
  and arm64, and Windows x64 and arm64. Each archive carries the compiler
  together with the LLVM tools (from the official llvm-project release
  builds), z3, and the libraries they need, pinned as one tested set.
- `toolchain update`, which replaces a whole set at once.
- A per-project toolchain pin in `elisapkg.json`.
