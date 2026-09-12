# Elisa module architecture

The executable entry point is intentionally tiny: the global `main` function delegates to the public `Cli::run` contract. Command behavior remains in the Elisa source; the module boundary prevents the operating-system seam and trust policy from becoming implicit CLI behavior.

The current source units are:

| Module | Public surface | Private state | Boundary rule |
| --- | --- | --- | --- |
| `Platform` | Namespaced wrappers for the small libc/process seam, including byte-wise C-string comparison | File modes and future platform policy | Only platform wrappers may refer to foreign declarations; reads, temporary files, directory creation, path mutations, and bounded process waits use no-follow or monotonic-deadline primitives. |
| `Model` | `Version` and `CommandOptions` value contracts | Schema-policy constants and future normalized records | No handles, credentials, or unverified source bytes cross the model API. |
| `Trust` | Verification result codes, policy contract, diagnostics, metadata prechecks, and exact-byte detached verification | Provider status mapping and private comparison helpers | Prechecks cover expiry, rollback, namespace, and algorithm policy; the provider is reached only after key/signature shape checks. |
| `Security` | Fail-closed statuses and user-facing denial messages | Trust-protocol selection state | Remote operations cannot become enabled by a URL, flag, or lockfile alone. |
| `Archive` | Safe relative-entry policy, deterministic ustar headers, and staged extraction contract | Path-segment checks, fixed tar metadata, and no-follow file creation | Remote acquisition is still disabled; long-name extensions remain disabled. |
| `Manifest` | Manifest entry-path policy | Schema/path policy marker | Target paths are checked through `Archive`; parser state remains private to validation. |
| `Json` | Bounded duplicate-key rejection for JSON objects | Lexical cursors and seen-key tables | It rejects ambiguity at the byte boundary; callers still own schema and type validation. |
| `SemVer` | Version precedence and initial range matching | Requirement parser helpers and grammar constants | Resolver code receives parsed bounds instead of interpreting range text itself. |
| `Resolve` | Bounded in-memory candidate selection | Catalog cursors and duplicate tracking | Selection is pure and deterministic; providers must authenticate metadata before constructing a catalog. |
| `Registry` | File-backed signed metadata and archive resolution | Root configuration, bounded JSON field extraction, and path assembly | The provider verifies detached Ed25519 metadata, expiry, archive shape, size, and digest before exposing a candidate. Network transport is not part of this module. |
| `Solver` | Bounded backtracking over authenticated candidates | Candidate ordering, trails, and decision limits | It accepts metadata records only; source acquisition, signature checks, and filesystem effects remain outside the solver. |
| `Integrity` | SHA-256 bytes and hexadecimal encoding | Compression/hash implementation details | Digests are content claims; `Trust` still decides whether authenticated metadata authorizes them. |
| `Cache` | Digest-addressed blob paths and byte revalidation | Digest grammar and no-follow blob reads | A pathname is never accepted as proof; callers must publish and quarantine through the CLI transaction. |
| `Cli` | `run(argc, argv)` | None | The public command surface delegates to private command helpers. |

The current compiler backend requires foreign declarations at compilation-unit scope, so the private `PlatformNative` module keeps those declarations and the descriptor-relative policy helpers together. `Platform` exposes only the reviewed wrapper surface. Callers use qualified names such as `Platform::pkg_fopen`, `Model::Version`, and `Security::remote_fetch_status`; `using` imports are deliberately avoided.

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
- `Trust` owns signed-metadata verification and persisted rollback state; expose verification results, never keys or raw credential storage.
- `Registry` owns transport-neutral candidate loading; expose only authenticated metadata and content identities, never unsigned paths.
- `Archive` owns deterministic writing and bounded safe extraction; expose verified staging operations, never arbitrary destination paths.
- `Cache` owns content-addressed storage and locking; expose immutable verified handles, never “verified” booleans detached from bytes.
- `Build` owns target planning and subprocess execution; expose sanitized build results and keep environment construction private.
- `Integrity` owns digest calculation and known-answer vectors; expose bytes or encoded digests, never mutable hash state.

Each module must have one owner for its invariants, explicit public data contracts, and a `private:` section for parsing cursors, filesystem paths, mutable caches, and other implementation details. Cross-module calls should use qualified names so a future member cannot silently shadow a security-sensitive helper.
