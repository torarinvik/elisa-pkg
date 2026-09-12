# elisapkg

`elisapkg` is the Elisa Packaging System, implemented in Elisa. The repository currently contains the first local vertical slice: strict manifest checks, deterministic lockfiles, frozen builds, local project scaffolding, toolchain invocation, and fail-closed remote-source policy.

The source uses explicit Elisa modules. `Cli::run` is the public command boundary; `Platform` wraps the minimal FFI seam and byte-wise C-string helpers; `Model` contains value contracts; `Json` rejects duplicate keys and invalid UTF-8 before schema lookup; `Integrity` computes SHA-256 digests; `Trust` defines signed-metadata verification results and the fail-closed production policy; and `Security` owns remote-operation decisions. See [`docs/architecture.md`](docs/architecture.md) for the visibility and namespace rules.

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
(cd path/to/app && ../../build/elisapkg build --bin app)
(cd path/to/app && ../../build/elisapkg run --bin app --)
(cd path/to/app && ../../build/elisapkg test --test app-tests)
(cd path/to/app && ELISAPKG_INSTALL_PREFIX="$HOME/.local" ../../build/elisapkg install --local)
```

The manifest and lockfile are JSON schema-versioned. `resolve --frozen` verifies the existing lockfile byte-for-byte and refuses to edit it. Dependency edits journal the original manifest/lock pair and recover it after an interrupted process. `tree` and `why NAME` read the verified lock and show the selected local graph. `--offline`, `--locked`, `--frozen`, and `--quiet` are accepted by the CLI; `--color auto|always|never` is validated for forward-compatible output policy (the current renderer emits no ANSI escapes). Quiet mode suppresses human success/progress text but never hides errors or explicitly requested JSON. `fetch` verifies local path sources against the committed lockfile without network access. With `ELISAPKG_REGISTRY_DIR`, `fetch PACKAGE REQUIREMENT` verifies one file-backed registry artifact with detached Ed25519 metadata, while no-argument `fetch` verifies and caches every exact registry record in lock v3; network acquisition remains disabled.

`cache verify` performs the same canonical-lock and local manifest-digest check
and, when a package archive exists, verifies its deterministic archive receipt.
The receipt binds the archive bytes to the exact manifest and lockfile digests,
and a partial archive/receipt pair is rejected. It then reports that no shared
remote cache is configured. Package archives also receive a local
content-addressed hard-link under `.elisapkg/cache/sha256/`; verification
rehashes that blob and rejects corruption. Successful builds
publish an exclusive compiler output by atomic rename and retain a receipt of
the target source, manifest, resolved-lock, and artifact digests plus selected
compiler inputs. A matching receipt and artifact are reused; changing the
root, dependency graph, or target source forces a fresh compiler invocation.
Compiler, stage1, and runtime content identities are included in the receipt;
if any identity cannot be captured, that build does not reuse an existing
artifact. The receipt also includes a deterministic digest of every sanitized
source-tree file, so additions, removals, renames, and changes to non-target
sources invalidate reuse.
`cache gc --dry-run` is likewise read-only and reports that there is no shared
cache to sweep; destructive garbage collection stays disabled until leases and
concurrent-reader rules are implemented for the local blob store. A new package
operation quarantines a corrupted active blob before republishing its verified
replacement. Quarantine publication is exclusive; if the deterministic evidence
name already exists, the operation fails closed instead of replacing prior evidence.

Project commands accept `--manifest-path PATH`; PATH may name the project directory or its `elisapkg.json`, including dependency mutations such as `add`, `remove`, and `update`. Local path resolution walks the dependency graph transitively, sorts package records by canonical name, normalizes relative paths, records SHA-256 manifest and complete sanitized source-tree digests, and rejects conflicting duplicate package identities. Target paths are resolved with `realpath` and must remain below their package root, including when a symlink is present. `build` selects the first target by default or a named target with `--bin NAME`, `--lib NAME`, or `--test NAME`; executable and test artifacts use the target name under `.elisapkg/build/`, while libraries use the same name with an `.o` suffix. Build receipts and cache validation bind the target kind and artifact name, while `run --bin NAME` and `install --local --bin NAME` reject library targets before attempting execution or publication. `test --test NAME` selects a named test target. `clean` removes known build artifacts plus `.elisapkg/package.tar`, `.elisapkg/package.receipt`, and empty build directories. Registry dependency declarations are syntax-checked locally, including exact, caret, tilde, and comparison SemVer ranges. Registry-only graphs use the signed local `primary` provider described in [`docs/registry.md`](docs/registry.md), produce lockfile version 3, and can be cached with `fetch PACKAGE VERSION`; mixed local/registry graphs and network transport remain fail-closed.

Fetched registry blobs have immutable receipts beside their content-addressed cache
objects. The exact signed metadata bytes and detached signature are cached by metadata
digest, while the receipt binds the lock selection to the archive and authenticated
metadata digests, size, and expiry. `build --offline` and `build --frozen` re-verify the
cached metadata and dependency edges, then validate the receipt, archive, and persisted
trust record without contacting a provider or changing the lockfile; missing or forged
evidence fails closed.

After archive verification, each signed registry selection is recorded in a
user-owned trust-state file outside the project. The default location is
`$HOME/.local/share/elisapkg/trust/<sha256-of-registry-root>.state`; set
`ELISAPKG_TRUST_STATE` to an absolute path for an isolated location. Updates
use an exclusive lock and durable atomic replacement. A lower version or a
same-version digest change is rejected even if the project lockfile is deleted
or restored. The adjacent `.clock` sidecar durably records the greatest wall
clock value observed for the registry; malformed values and clock rollback are
rejected before a signed selection can update trust state. Removing it after a
record exists fails closed rather than resetting that floor.
The derived `HOME` path is accepted only when it is absolute and contains no
control bytes or backslashes; trailing separators are normalized, and malformed
environment input fails closed before any trust-state directory is created.

`package --list` previews the validated file set. `package` writes a bounded,
deterministic ustar archive to `.elisapkg/package.tar`, with sorted regular
files, normalized metadata, and a fixed timestamp. Source reads refuse symlinks at every path component. PAX/GNU long-name
extensions and compression are intentionally deferred. The generated bytes are
verified again for headers, checksums, case-folded duplicate names, bounds, and
end blocks. Packaging revalidates the lock and compares complete source-tree
digests before and after reading the selected files, then re-reads the manifest
and lockfile, so an in-flight input mutation aborts instead of producing a mixed
archive. The archive digest is recorded in `.elisapkg/package.receipt` together
with the manifest and lock digests;
signing is still required before any remote publication.

`publish --dry-run` performs the release preflight without writing an archive
or contacting a registry: it requires a valid frozen lockfile, rechecks the
complete source-tree digest, and validates the selected package file set.
Successful preflight does not publish bytes or bypass signing and publisher
authorization requirements.

`install --local` is the deliberately narrow local deployment path. It resolves
the local graph, builds the current binary, and writes it to
`$ELISAPKG_INSTALL_PREFIX/bin/<package-name>` (or `$HOME/.local/bin` when the
override is absent). The destination and its receipt are created through an
exclusive hard-link publication, so an existing file cannot be replaced. A
receipt under `share/elisapkg/receipts` binds the package name, destination, and
SHA-256 artifact digest. `uninstall --local NAME` removes only a matching,
unchanged receipt-owned binary; modified files and malformed receipts are
refused. Remote `install NAME` remains trust-gated with the other network
operations.

## Security posture

Remote packages are not accepted unsigned. `fetch` and remote `install NAME`
currently exit with the security status and explain that no trusted source
provider is configured. This is deliberate: checksums, TLS, and a registry URL
alone do not authenticate a publisher. The implementation plan requires a
reviewed signed-metadata protocol, trusted-root bootstrap, publisher
delegation, expiry and rollback protection, safe archive extraction, credential
redaction, key rotation/revocation, adversarial fixtures, and independent
security review before remote support is enabled.

On macOS, compiler children run under a deny-by-default Seatbelt profile with network access denied and a per-build scratch directory. Compiler output, including stage1's intermediate object, stays in scratch; the child can write there, to `/dev/null`, and to the already-created callback C file through its existing inode. It cannot create, chmod, or unlink that callback path. The parent validates and copies the output to a new inode before publishing it. Compiler stdin is `/dev/null`; stdout and stderr go to private scratch files and are forwarded by the parent only after the compiler process group has stopped. Builds fail closed when Seatbelt is absent or rejects the profile. Project and locked local dependency trees plus selected compiler/toolchain directories remain readable to the compiler, so this is constrained build isolation rather than a complete credential boundary. `run` and `test` execute the resulting artifact as the invoking user. Arbitrary dependency build scripts, plugins, and automatic native dependency installation remain disabled. `doctor` reports whether `sandbox-exec` is present; an actual build validates profile application.

Build subprocesses receive a minimal environment through an `env -i` argv invocation, with only the selected compiler bootstrap values, selected Clang path, and isolated HOME/TMPDIR/cache paths. When `ELISAPKG_COMPILER` and `ELISA_STAGE1_BIN` resolve to the expected `scripts/elisac_stage1.sh` and sibling `bin/elisac-stage1` layout, elisapkg invokes stage1 directly because macOS blocks the wrapper's setuid `ps` memory poll in a sandbox. That path skips the wrapper's source-freshness and RSS-polling checks; the binary digest is recorded. Registry credentials and unrelated variables are excluded. Compiler and application children use private process groups, deadlines, CPU/file-size limits, and disabled core dumps. Memory use is not capped: macOS rejects the attempted data-segment/address-space limits for ordinary compiler processes, and its resident-size limit is not reliable. Before publication, compiler output bytes are copied to a fresh parent-owned file so a detached process holding the compiler's old output descriptor cannot modify the cached artifact. Seatbelt does not stop every possible detached descendant, so complete process cleanup remains an isolation requirement. Application processes launched by `run` and `test` do not use the build sandbox.

Builds also force `ELISA_STAGE1_SEMANTIC_GATE=1`; a semantic-check failure is a
build failure and cannot be replaced by successful object emission. Build
receipts include SHA-256 identities for the selected compiler, stage1 binary,
and runtime object. If any identity cannot be captured reliably, cache reuse is
disabled for that build.

## Development

Run the deterministic smoke suite with:

```sh
scripts/test.sh
```

The suite compiles the source, checks help/version/doctor, creates an isolated package, resolves and freezes its lockfile, builds and runs it, and verifies invalid-manifest, local-fetch, and unsigned-remote-operation failures. Generated state is ignored by Git.
