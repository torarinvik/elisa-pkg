# Elisa Packaging System

**elisapkg** manages Elisa projects. Use it to create a project, declare dependencies, record the exact inputs in a lockfile, and build or package the result. The package manager itself is written in Elisa.

**Project status:** Local projects and local path dependencies are supported. Building projects requires Apple Silicon macOS with a working Seatbelt sandbox. Linux x86-64 and arm64 can run supported commands that don't build projects. The registry implementation is a signed, file-backed fixture for development. Network downloads, remote installation, and publication are disabled.

## Quick start

### 1. Build elisapkg

Start in the root of this repository. You'll need Bash, Python 3, and a separate Elisa compiler checkout with an executable Stage1 compiler, its wrapper script, and a built runtime object. Set the first path below to your actual compiler checkout. See [compiler compatibility](docs/compatibility.md) for the supported toolchain layout.

```sh
export ELISA_COMPILER_ROOT="/absolute/path/to/elisa-compiler"
export ELISA_STAGE1_BIN="$ELISA_COMPILER_ROOT/bin/elisac-stage1"
export ELISA_RUNTIME_OBJ="$ELISA_COMPILER_ROOT/build/runtime/elisacore_runtime.o"

./scripts/build.sh
export ELISAPKG="$(pwd)/build/elisapkg"
"$ELISAPKG" --help
"$ELISAPKG" doctor
```

A successful build creates `build/elisapkg`. The example saves its absolute path so it still works after you change directories. If your checkout uses a different wrapper location, set `ELISA_COMPILER_WRAPPER` to that executable before running the script. The script uses your existing compiler checkout and does not download a toolchain.

### 2. Create and inspect a project

Pick an unused directory name. Run these commands from a directory where you want to create the project.

```sh
"$ELISAPKG" init hello-elisa
cd hello-elisa
"$ELISAPKG" check-manifest
"$ELISAPKG" resolve
"$ELISAPKG" resolve --frozen
"$ELISAPKG" tree
```

- `src/main.elisa` is the starter program. It exits successfully without printing anything.
- `elisapkg.json` is the **manifest**. It describes the package, targets, and dependencies you want.
- `elisapkg.lock` is the **lockfile**. It records the resolved inputs. Commit it alongside the manifest. After an intentional input change, run `resolve` and review the lockfile diff.
- `.elisapkg/` holds generated state and artifacts. Add it to your project's Git ignore rules.

The generated package and binary target are named `app`, even though the example directory is named `hello-elisa`. The manifest controls those names.

### 3. Build and run on Apple Silicon macOS

Use a trusted compiler and keep the toolchain settings from step 1 in the same shell. macOS also needs the Xcode Command Line Tools or a supported Xcode installation.

```sh
export ELISAPKG_COMPILER="${ELISA_COMPILER_WRAPPER:-$ELISA_COMPILER_ROOT/scripts/elisac_stage1.sh}"
"$ELISAPKG" build --bin app
"$ELISAPKG" run --bin app --
```

The default build produces `.elisapkg/build/app`. Put program arguments after `--`. On Linux, you can still validate, resolve, and package this project, but `build`, `run`, and `test` require the macOS build sandbox.

### 4. Preview and create a package archive

```sh
"$ELISAPKG" package --list
"$ELISAPKG" package
"$ELISAPKG" cache verify
```

The preview shows which source files will ship. Packaging writes `.elisapkg/package.tar` and a verification receipt. Creating the archive does not compile or upload it.

## Command reference

Run project commands from the project directory. Where supported, `--manifest-path PATH` selects a different project directory or its `elisapkg.json`. Use `elisapkg --help` for the full command list.

| I want to… | Command | What it does |
| --- | --- | --- |
| Add a sibling library | `add my-lib --path ../my-lib` | Adds a local dependency whose manifest name is `my-lib`. Local dependency builds require exactly one library target per dependency. |
| Review dependency selections | `tree` or `why my-lib` | Displays the locked graph or explains why a package is present. |
| Check a committed lockfile | `resolve --frozen` | Verifies the lockfile without rewriting it. |
| Inspect normalized metadata | `metadata --json` | Prints machine-readable package metadata. |
| Build a release binary | `build --bin app --profile release` | Places the binary under `.elisapkg/build/release/`. |
| Run a test target | `test --test app-tests` | Builds and runs a test target you have declared in the manifest. |
| Install a local binary | `install --local --bin app` | Installs under `$HOME/.local/bin` by default. The destination uses the package name. |
| Remove that installation | `uninstall --local app` | Removes the binary only if it matches its installation receipt. |
| Remove generated build outputs | `clean` | Removes known local build and package outputs. |
| Check release inputs | `publish --dry-run` | Validates release inputs and deterministic archive contents without uploading. |

## Troubleshooting

- **Missing compiler, wrapper, or runtime:** Check the three paths in step 1 against your Elisa compiler checkout. Bootstrap the compiler in that checkout first if its Stage1 or runtime artifacts are missing.
- **Cannot find the build compiler:** Set `ELISAPKG_COMPILER` to the absolute path of the trusted compiler wrapper, then run `doctor`.
- **Manifest or target not found:** Check your working directory and the target's `name` and `kind` in `elisapkg.json`. Use [the manifest reference](docs/manifest.md) when defining a new target.
- **Frozen lock is stale:** Review the source or dependency changes. If they're intentional, run `resolve` and review the updated `elisapkg.lock`.
- **Sandbox unavailable:** Project builds require macOS and successful Seatbelt profile application. An installed `sandbox-exec` alone does not prove a profile can run.
- **Local install refused:** Check for an existing destination and use a private, trusted prefix. You can choose another absolute directory with `ELISAPKG_INSTALL_PREFIX`. The installer will not replace an existing binary.

## How it works

Local resolution records dependencies in a deterministic lockfile with SHA-256 identities for manifests and source trees. Local library targets are compiled in dependency order. Builds compile verified source snapshots and require the Stage1 semantic gate. They reuse a previous artifact only when its receipt and verified inputs match, including the source, lockfile, and selected toolchain identities. Packaging writes a bounded, deterministic ustar archive with normalized metadata.

The build sandbox restricts compiler file access and denies network access. **`run` and `test` execute package code with your user account's permissions.** Only run code you trust. The [security model](docs/security.md) describes the sandbox's limits.

The local registry fixture verifies detached Ed25519 signatures, expiry, cached evidence, and persisted rollback state. It can resolve and cache fixture packages, but those dependencies cannot be built. The production TUF profile is documented separately and is not implemented. See [the registry guide](docs/registry.md), [threat model](docs/threat-model.md), and [security reporting policy](SECURITY.md).

## Documentation and development

| Reference | Covers |
| --- | --- |
| [Manifest](docs/manifest.md) and [lockfile](docs/lockfile.md) | JSON schemas, targets, dependencies, and lockfile formats |
| [Architecture](docs/architecture.md) and [decisions](docs/decisions.md) | Elisa modules, public interfaces, and the private POSIX FFI boundary |
| [Compiler compatibility](docs/compatibility.md) | Bootstrap paths, host support, and toolchain constraints |
| [CI and regression checks](docs/ci.md) | Development checks and host requirements |
| [TUF profile](docs/tuf-profile.md) | Requirements for future production registry support |

Source lives in `src/`, build and regression tooling in `scripts/`, and experimental work in `spikes/`. With the toolchain configured, `make build` builds the CLI and `make test` runs the smoke suite on a supported build host.

See [LICENSE](LICENSE) for license terms.
