# Elisa module architecture

The executable entry point is intentionally tiny: the global `main` function delegates to the public `Cli::run` contract. Command behavior remains in the Elisa source; the module boundary prevents the operating-system seam and trust policy from becoming implicit CLI behavior.

The current source units are:

| Module | Public surface | Private state | Boundary rule |
| --- | --- | --- | --- |
| `Platform` | Namespaced wrappers for the small libc/process seam, including byte-wise C-string comparison | File modes and future platform policy | Only platform wrappers may refer to foreign declarations; reads, temporary files, directory creation, path mutations, and bounded process waits use no-follow or monotonic-deadline primitives. |
| `Model` | `Version` and `CommandOptions` value contracts | Schema-policy constants and future normalized records | No handles, credentials, or unverified source bytes cross the model API. |
| `Trust` | Verification result codes, policy contract, diagnostics, metadata prechecks, and exact-byte detached verification | Provider status mapping and private comparison helpers | Prechecks cover expiry, rollback, namespace, and algorithm policy; the provider is reached only after key/signature shape checks. |
| `Tuf` | Pinned TUF spec-version, metadata JSON, SHA-256 hash-map, signature-key-ID prechecks, authenticated checkpoint decisions, and canonical sorted checkpoint-batch validation | Integer-only metadata number checks, digest/role/version grammar, key-ID syntax, duplicate detection, checkpoint comparison, and flat-list comparison | Checkpoint decisions reject rollback and same-version digest equivocation after the verifier authenticates a role. The module does not parse TUF schemas, canonicalize signed bytes, or authenticate metadata. Remote operations remain disabled until the full TUF workflow passes conformance and review. |
| `Security` | Fail-closed statuses and user-facing denial messages | TUF profile state and provider status | The TUF v1.0.36 protocol is selected, but remote operations stay disabled until its verifier and provider pass review. |
| `Archive` | Bounded archive writing, verification, embedded entry reads, and staged extraction | selected-path serialization and read orchestration | Embedded bytes become available only after the full archive is validated. Native extraction uses the same format rules. |
| `UstarFields` | Normalized header encoding and validation, entry path checks, and payload boundaries | Octal parsing, checksum calculation, and zero-range checks | Writer and readers share the ustar format limits. |
| `Manifest` | Manifest schema and entry-path policy | Key and path rules | Filesystem validation stays with callers that know the project root. |
| `ManifestTargets` | Target selection and output names | Target field and suffix helpers | Cleanup plans output names before removing files and works after source files are removed. |
| `PackageSelection` | Include and exclude matching and archive path policy | Matcher and shared work budget accounting | Selection remains bounded across the full package walk. |
| `PackageReceipt`, `InstallRecords` | Local archive receipts and installation record codecs | Record format and field validation | An invalid install journal yields no parsed fields. |
| `InstallPrefix` | Installation prefix configuration and directory trust | Prefix validation and native path conversion | Missing directory components are created relative to trusted parent descriptors. |
| `Build`, `Toolchain` | Build output locations, include emission, and executable lookup | Include path validation and compiler path helpers | Compiler lookup and child environment share the same search path. |
| `UserData` | The per-user data directories under `$HOME/.local/share/elisapkg` | HOME validation and per-directory creation | Every directory from `$HOME/.local` down is created with mode `0700` and must pass the trusted-directory policy. Registry trust state and toolchain records share it. |
| `ToolchainStore` | Toolchain names, record encoding, and the default toolchain | Record field parsing and listing | Records are published exclusively or replaced atomically, and read only through trusted no-follow walks; a malformed record is never used. |
| `SourceFingerprint`, `BuildSnapshots` | Source tree identity and verified sandbox inputs | Byte budgets, staging names, and snapshot cleanup | Fingerprints bind logical paths to file digests. The build uses a copied tree only after its fingerprint matches and the selected entry resolves to a regular file. The caller cleans every registered staging directory on success or failure. |
| `Json` | Bounded JSON syntax validation, duplicate-key rejection, and direct field lookup | Lexical cursors and seen-key tables | It bounds document size, nesting, object-key count, and duplicate-key comparison work; callers still own schema and type validation. |
| `SemVer` | Version precedence and initial range matching | Requirement parser helpers and grammar constants | Resolver code receives parsed bounds instead of interpreting range text itself. |
| `Resolve` | Bounded in-memory candidate selection | Catalog cursors and duplicate tracking | Selection is pure and deterministic; providers must authenticate metadata before constructing a catalog. |
| `Registry` | Local fixture metadata and archive resolution, plus locked read and atomic persistence of TUF checkpoint batches | Fixture trust-root configuration, protected state paths, bounded JSON field extraction, and path assembly | The provider verifies only the local detached-Ed25519 fixture; its checkpoint store is a persistence primitive and does not implement TUF authentication or a remote adapter. |
| `CheckpointRecords` | On-disk scoped checkpoint record format and bounded merge | Row decoding, sorted role keys, and monotonic version and digest checks | The caller supplies authenticated checkpoints. The registry validates batch format and owns locking, clock checks, and persistence. |
| `Solver` | Bounded backtracking over authenticated candidates | Candidate ordering, trails, and decision limits | It accepts metadata records only; source acquisition, signature checks, and filesystem effects remain outside the solver. |
| `SolverBudget` | The deterministic work budget and charged byte comparisons shared by solver steps | Prefix comparison | Every solver comparison, constraint check, and parser call charges one budget, so a hostile graph cannot run unbounded. |
| `Integrity` | SHA-256 bytes and hexadecimal encoding | Compression/hash implementation details | Digests are content claims; `Trust` still decides whether authenticated metadata authorizes them. |
| `Cache` | Digest-addressed paths, verified byte reads, quarantine, and registry receipt codecs | Bounded file reads, path construction, and receipt fields | Blob reads return the bytes that passed SHA-256 verification. The CLI coordinates publication. |
| `Cli` | `run(argc, argv)` | None | The public command surface delegates to private command helpers. |

## Command modules

`Cli::run` dispatches to command modules in `src/cli/`. Each command keeps its
orchestration short and delegates each phase to a focused module:

| Module | Responsibility |
| --- | --- |
| `CliArguments`, `CliOutput`, `CliStatus`, `ProjectContext` | Argument grammar, output policy and help text, exit statuses, and project discovery |
| `BuildCommand` | Orders a build: read the project, prepare inputs, reuse a cached artifact, or compile |
| `BuildTarget` | Reads the manifest and selects the compiled target |
| `BuildInputs`, `BuildSources` | Fingerprints the inputs bound to a build receipt and prepares the private source tree |
| `BuildToolchainSetup` | Selects the compiler from `ELISAPKG_COMPILER` or the default toolchain, and fingerprints every component |
| `BuildWorkspace` | Owns the private scratch files of one build and removes them on every path |
| `BuildExecution`, `CompilerProcess` | Runs the sandboxed compiler and verifies and publishes its output |
| `FetchCommand`, `FetchRelease`, `FetchOffline` | Fetches registry releases online, or verifies a registry lock against the authenticated offline cache |
| `ResolutionCommand` | Resolves, edits, and presents dependency locks |
| `LocalInstallCommand` | Publishes and removes verified local installations under a per-prefix lock |
| `MaintenanceCommand`, `ProgramCommand` | Cleans outputs, verifies the package cache, and runs built programs |
| `InitCommand`, `PackageCommand`, `InstallCommand`, `ToolchainCommand` (`src/cli/commands/`) | Creates a package scaffold, lists or writes the package archive and validates a publish dry run, installs the built binary target locally, and links, lists, selects, and unlinks toolchains |

Command modules read the argument vector as an immutable `cstr&&`. Only the
child-process argument vectors handed to `execvp` are writable.

The current compiler backend requires foreign declarations at compilation-unit scope, so the declarations live in `src/platform/libc.elisa`. Target constants and directory entry layouts live in `src/platform/abi.elisa`. Only `PlatformNative` calls the foreign functions to implement descriptor-relative operating-system policy. `Platform` exposes only the reviewed wrapper surface. Callers use qualified names such as `Platform::read_package_file`, `Model::Version`, and `Security::remote_fetch_status`; `using` imports are deliberately avoided.

The current CLI also has a local deployment path. `install --local` stays in
the command layer, but delegates digesting and filesystem publication to the
same platform and integrity primitives used by builds. Its receipt is treated
as an ownership claim only after the executable bytes, package name, and exact
destination match; remote installation remains behind `Security` and `Trust`.
Before either file changes, the CLI writes a durable per-prefix transaction
journal. The next operation recovers under the same prefix lock by checking the
package name, version, executable digest, and exact derived receipt; unexpected
or malformed state remains untouched and blocks mutation.

The package writer asks `Platform` for a sorted, regular-file-only directory
walk, then applies manifest include patterns and the `Archive` path policy in
Elisa before reading bytes. `PlatformNative` applies conservative file
exclusions and descriptor-relative no-follow traversal but performs no archive
serialization, which keeps filesystem traversal separate from the public
archive format. `Archive::verify_ustar_archive` parses the resulting bytes
again, so the file is only exposed after bounds, checksum, duplicate-entry,
padding, and end-marker checks; the verified byte stream is suitable for later
signing.

Future implementation modules should follow the same pattern:

- `Manifest` owns parsing and validation; expose normalized package records and keep token scanners private.
- `Resolve` owns deterministic graph solving; expose a resolver interface that accepts a source provider, never an HTTP client.
- `Trust` owns signed-metadata verification; `Registry` owns protected source identity and persisted rollback state. Expose verification results, never keys or raw credential storage.
- `Registry` owns configured-source acquisition; remote candidates must pass the TUF profile before exposure, and the custom file-backed provider remains a test fixture only.
- `Archive` owns deterministic writing and bounded safe extraction; expose verified staging operations, never arbitrary destination paths.
- `Cache` owns content-addressed storage and locking; expose immutable verified handles, never “verified” booleans detached from bytes.
- `Build` owns target planning and subprocess execution; expose sanitized build results and keep environment construction private.
- `Integrity` owns digest calculation and known-answer vectors; expose bytes or encoded digests, never mutable hash state.

Each module must have one owner for its invariants, explicit public data contracts, and a `private:` section for parsing cursors, filesystem paths, mutable caches, and other implementation details. Cross-module calls should use qualified names so a future member cannot silently shadow a security-sensitive helper.

Package schema and identity modules live in `src/package/`. Version ranges
and dependency selection live in `src/resolution/`. These directories group
source by responsibility. The Elisa module names and public interfaces stay
independent of the directory layout.
