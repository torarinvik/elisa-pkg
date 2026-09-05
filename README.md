# elisapkg

`elisapkg` is the Elisa Packaging System, implemented in Elisa. The repository currently contains the first local vertical slice: strict manifest checks, deterministic lockfiles, frozen builds, local project scaffolding, toolchain invocation, and fail-closed remote-source policy.

The source uses explicit Elisa modules. `Cli::run` is the public command boundary; `Platform` wraps the minimal FFI seam; `Model` contains value contracts; `Integrity` computes SHA-256 digests; `Trust` defines signed-metadata verification results and the fail-closed production policy; and `Security` owns remote-operation decisions. See [`docs/architecture.md`](docs/architecture.md) for the visibility and namespace rules.

## Bootstrap

The package manager is compiled by the self-hosted Elisa compiler. Set `ELISA_COMPILER_ROOT` to an Elisa compiler checkout, then run:

```sh
scripts/build.sh
build/elisapkg --help
```

`ELISA_COMPILER_ROOT` is required; the script does not guess a sibling checkout or download a compiler. `ELISA_RUNTIME_OBJ` may point to the compiler's runtime object. `ELISAPKG_COMPILER` selects the compiler executable used by `elisapkg build`; it is passed as an argv element, never through a shell command string.

## Local workflow

```sh
build/elisapkg init path/to/app
(cd path/to/app && ../../build/elisapkg check-manifest)
(cd path/to/app && ../../build/elisapkg resolve)
(cd path/to/app && ../../build/elisapkg build)
(cd path/to/app && ../../build/elisapkg run --)
```

The manifest and lockfile are JSON schema-versioned. `resolve --frozen` verifies the existing lockfile byte-for-byte and refuses to edit it. Dependency edits journal the original manifest/lock pair and recover it after an interrupted process. `tree` and `why NAME` read the verified lock and show the selected local graph. `--offline`, `--locked`, and `--frozen` are accepted by the CLI; remote acquisition remains disabled until signed registry metadata and publisher authorization are configured.

Commands that inspect or build a project accept `--manifest-path PATH`; PATH may name the project directory or its `elisapkg.json`. Local path resolution walks the dependency graph transitively, sorts package records by canonical name, normalizes relative paths, records a SHA-256 manifest digest, and rejects conflicting duplicate package identities. Target paths are resolved with `realpath` and must remain below their package root, including when a symlink is present. `clean` removes only the known `.elisapkg/build/app` output and empty build directories. Registry dependency declarations are syntax-checked locally, including exact, caret, tilde, and comparison SemVer ranges, but resolution remains fail-closed until a verified registry provider exists.

## Security posture

Remote packages are not accepted unsigned. `fetch` currently exits with the security status and explains that no trusted source provider is configured. This is deliberate: checksums, TLS, and a registry URL alone do not authenticate a publisher. The implementation plan requires a reviewed signed-metadata protocol, trusted-root bootstrap, publisher delegation, expiry and rollback protection, safe archive extraction, credential redaction, key rotation/revocation, adversarial fixtures, and independent security review before remote support is enabled.

Builds execute trusted Elisa source under the selected compiler. Dependency build sandboxing, arbitrary build scripts, plugins, and native dependency installation are not enabled. `doctor` reports these limits instead of implying isolation.

Compiler and application subprocesses receive a minimal environment through an `env -i` argv invocation. Only the selected compiler bootstrap variables (`ELISA_STAGE1_BIN`, `ELISA_RUNTIME_OBJ`, and `ELISA_ALLOW_STALE_STAGE1`) are copied when present; registry credentials and unrelated variables are excluded.

## Development

Run the deterministic smoke suite with:

```sh
scripts/test.sh
```

The suite compiles the source, checks help/version/doctor, creates an isolated package, resolves and freezes its lockfile, builds and runs it, and verifies invalid-manifest and unsigned-fetch failures. Generated state is ignored by Git.
