# Elisa Packaging System decisions

This file records implementation decisions that are part of the supported
`elisapkg` contract. Each entry names the evidence and the fixture that keeps
the decision from drifting silently.

## D-001: package and lock filenames

`elisapkg.json` is the package manifest and `elisapkg.lock` is the generated
lockfile. An existing compiler `manifest.json` is treated as a separate
configuration file; a project containing both package manifests is rejected as
ambiguous. Fixture: the duplicate-manifest case in `scripts/test.sh`.

## D-002: local graph identity

Local packages are identified by their canonical manifest location, declared
package name, and declared version. A dependency alias must equal the package
name. Serialized paths remain relative to the declaring project where possible;
absolute paths are never emitted. Fixture: the transitive local graph in the
smoke suite and the external sibling dependency in
`scripts/regression_test.py`.

## D-003: one stable version per package identity

The initial resolver selects one stable version for each registry/name identity.
Prerelease requirements and candidates remain rejected until the requirement
model stores complete prerelease identity. Conflicts must be reported rather
than silently selecting multiple copies. The current in-memory selector is a
pure provider-free primitive; the backtracking provider contract is tracked in
`src/resolution/resolve.elisa` before registry support is enabled.

## D-004: canonical bytes

Manifest and lock fingerprints use exact validated UTF-8 bytes. Lock output uses
fixed member order, two-space indentation, LF endings, sorted package records,
and one terminal newline. Atomic writes use an exclusive temporary file,
`fsync`, and same-directory replacement. Fixture: repeated resolve and frozen
inode/mtime checks in `scripts/test.sh`.

## D-005: trust boundary

Remote operations remain fail-closed until the TUF profile in D-013,
trusted-root bootstrap, namespace-scoped publisher authorization,
expiry/rollback state, and audited cryptographic binding are implemented
together. The local fixture's signed version index is not part of the
production protocol. SHA-256 is an integrity primitive only. No URL, checksum,
or lockfile entry enables a remote source by itself.

## D-006: source and archive policy

Package archives contain bounded regular files with normalized metadata. Source
reads use descriptor-relative no-follow opens for every component. Archive
headers, checksums, padding, path collisions, and end markers are verified
again before publication. `package` revalidates the lock and captures the
complete sanitized source-tree digest before reading files, then compares a
second digest before publishing the archive. A mutation during that read window
fails packaging instead of producing a mixed source release. Directory entries
that cannot be opened as a directory or regular file fail collection; a type
change between those probes is never silently omitted from the digest. Fixture:
archive corruption and native symlink tests in `scripts/regression_test.py`.

## D-007: build reuse

Receipt version 9 fingerprints the complete sanitized source tree, selected
target source and kind, manifest bytes, resolved-lock bytes, compiler
configuration, content identities for the selected compiler/stage1/runtime
inputs, artifact name, and output artifact. The source-tree digest is rechecked
before publication so a concurrent source mutation cannot be paired with the
pre-build receipt. A matching receipt and verified artifact may be reused only
when all three toolchain identities were captured.
If an identity cannot be resolved or read, the build still proceeds but cache
reuse is disabled for that invocation. A failed child or invalid output never
replaces the last known-good artifact.
Fixture: compiler-failure and artifact-preservation cases in the regression
suite.

## D-008: trusted-source execution

Compiler children on macOS require the deny-by-default Seatbelt profile. It
denies network access, gives each build a private scratch directory, and
permits compiler writes only inside it plus data writes to one exclusively
pre-created stage1 callback inode. The compiler cannot create, chmod, or unlink
that host path. Compiler output and adjacent linker intermediates stay in
scratch. Compiler stdin is detached, and stdout/stderr are
captured privately until the compiler process group is stopped. Since a child
can create a new session, process-group cleanup is best effort; the compiler's
output is copied to a new parent-owned inode before publication so retained
descriptors cannot alter the cached artifact. Builds fail closed when the
profile is unavailable or rejected.
Project and local dependency trees plus selected toolchain directories remain
readable, and a name-based secret denylist is incomplete. Direct stage1
execution skips wrapper freshness/RSS polling; resource limits are best effort.
The policy does not cover run/test artifact execution; those commands execute
as the invoking user. Linux builds remain unavailable. This is an interim
platform adapter, not a claim that hostile build code is fully contained.

## D-009: project transaction ownership

Manifest and lock edits hold a persistent `.elisapkg/transaction.flock`
advisory lock and acquire an exclusive `.elisapkg/transaction.guard` directory
before journaling state. Normal lockfile publication uses the same journal and
lock, and records the replacement bytes before publishing them. Recovery must
acquire the advisory lock before replaying a journal; the kernel releases it if
the process exits, allowing a later invocation to recover a stale guard. The
guard remains as a compatibility boundary for concurrent older invocations.
Guards from versions predating the advisory lock still require explicit
operator recovery because they cannot be distinguished safely from a live old
process.

## D-010: local archive cache identity

Every successfully packaged archive is hard-linked into the local
`.elisapkg/cache/sha256/<prefix>/<digest>` store after deterministic archive
verification, and the containing directory is flushed before the package
receipt is published. `cache verify` rehashes both the visible archive and its receipt
backing blob; a missing or corrupted blob is a security failure. A subsequent
package operation moves a corrupted active blob to the quarantine directory
before publishing a replacement. The move uses exclusive hard-link publication
and fails closed if the deterministic quarantine record already exists, preserving
the first failure for forensic review. Shared leases, destructive garbage collection,
and remote cache exchange remain disabled until their concurrency policy is
implemented. Fixture: package receipt and corrupted-blob cases in
`scripts/test.sh`.

## D-011: registry verification before use

The local-only registry test fixture uses a detached Ed25519 signature over
the exact metadata bytes. Its custom index and metadata wire formats are not
TUF, are not the production protocol, and must not be exposed through a network
transport. The trust root is an independently provisioned 32-byte file
selected through `ELISAPKG_REGISTRY_TRUST_ROOT`, outside the mutable registry
directory; metadata binds the
registry path, package, selected SemVer, archive relative path, byte size, and
SHA-256 digest. The resolver validates the archive as deterministic ustar and
recomputes its digest before returning success. Registry file reads reject
symlinked descendants by requiring `realpath` equality, and a no-argument
locked fetch reauthenticates every v3 record before caching it. Each verified
selection is persisted outside the project in a per-user monotonic trust-state
file protected by a persistent regular-file `flock` and durable atomic
replacement. The lock inode is never unlinked, and the kernel releases its
ownership after process exit; pre-existing legacy lock directories fail closed
for manual recovery. On macOS,
ACL allow entries and unknown ACL tags on both trust directories and regular
trust files are rejected; deny-only entries are accepted. A network transport
and the TUF verifier/delegation implementation remain release gates. The local
version index is an exact-byte Ed25519-signed snapshot binding the registry,
package, generation, expiry, and complete declared stable-version list. Its
generation and payload digest are persisted in the same checksum-bound trust
state as package history; lower generations and same-generation equivocation
fail closed. Owner, mode, no-follow, and supported ACL checks apply to the
snapshot, signature, and trust root. The authorized signer asserts that the
list is complete; a first-use client cannot know about a newer unseen signed
generation, so expiry bounds replay. Same-user deletion or corruption can
still deny service. Trust history format v4 keys package history by
registry-root hash and package name, and binds version, archive digest, and
metadata digest. It also pins each registry path to the SHA-256 fingerprint of
the configured Ed25519 key. Default per-registry paths migrate v2/v3 history on
the next state update; because these formats contain no key fingerprint, the
first v4 pin is trust-on-first-use. Deployments that require signer continuity
across this migration must preserve and verify the expected key out of band.
Ambiguous unscoped rows in an explicit override fail closed. Legacy v1 history
without metadata identity remains rejected.
Successful offline verification advances the state-bound clock only after
signed metadata and archive checks, and rechecks expiry using the time sampled
while holding the trust-state lock. This fixture tests local trust-boundary
behavior only; it does not implement TUF roles, threshold signatures, namespace
delegation, production key rotation, or publisher build provenance.

## D-012: local installation directory trust

Local install checks the nearest existing prefix ancestor before creating
directories and rechecks the final `bin` and receipt directory chains. Uninstall
requires both existing chains to pass the same check before it reads or removes
files. Every checked directory must be owned by root or the effective user and
must not have group or other write bits; symlinks are rejected by the
descriptor-relative walker. On macOS it rejects extended ACL allow entries and
unknown tags while accepting deny-only entries. Linux checks parse access ACLs
on opened descriptors, reject named user/group entries and malformed or
unreadable ACLs, and reject default ACLs on trusted directories. A durable
per-prefix journal records install or uninstall intent
before changing the executable or receipt, and the next operation validates
the journaled identity while holding the persistent prefix lock. Mismatched or
malformed states fail closed and preserve their evidence. Uninstall reads each
verified file through one trusted descriptor and removes it through the same
opened parent directory only when a final device/inode comparison still
matches. A same-UID process can still race between that comparison and
`unlinkat`, so hostile same-UID mutation remains a release limitation. Fixtures
cover swapped inodes, writable prefixes and ancestors, symlinked components,
writable binary or receipt directories, journal recovery states, and macOS ACL
cases in `scripts/test.sh`.

## D-013: production registry metadata protocol

Production registry metadata will use The Update Framework (TUF), pinned to
[Specification v1.0.36](https://theupdateframework.github.io/specification/v1.0.36/)
and its required TAP 6, TAP 9, TAP 10, and TAP 11 behavior. The elisapkg wire
and role profile is recorded in
[`tuf-profile.md`](tuf-profile.md). This decision selects a protocol and trust
model; it does not enable network access or approve a cryptographic provider.
The specification version is the normative baseline. Metadata `spec_version`
acceptance is limited to stable `1.0.P` values where `0 <= P <= 36`; role
thresholds must be positive integers, and impossible thresholds are rejected.

Every configured registry has a trusted root provisioned with the client or
through an authenticated out-of-band enrollment process. Root updates follow
TUF's sequential root-rotation procedure and its old-root/new-root signature
requirements. Persist each validated intermediate root; intermediate root
expiry alone does not stop the chain, but the final trusted root must be valid
at the fixed update start time. Registry and mirror responses cannot introduce
or replace a trust root. Each registry is an independent TUF repository; package metadata
from separate repositories is never merged into one authority.

Root, top-level Targets, package-scoped delegated Targets, Snapshot, and
Timestamp metadata form the trust chain. Top-level Targets cannot directly
list package targets. A terminating delegation for each disjoint package path
restricts release authority to the corresponding Targets role; a valid
signature from any other key does not authorize that package. TUF target length
and SHA-256 bind the exact deterministic archive bytes; SHA-256 values use
exactly 64 lowercase hexadecimal characters. An authenticated elisapkg custom target
object binds registry identity, normalized package name, exact version,
dependency declarations, compiler requirements, and archive format to that
target. Role thresholds, expiry bounds, key custody, recovery operators, and
publication identities must be explicitly configured and reviewed before
production deployment.

The production client must use a TUF-conformant implementation for metadata
parsing, canonical signed bytes, threshold counting, delegation traversal,
role updates, and target verification. No hand-rolled detached-signature or
index format may substitute for this chain. Algorithm policy is pinned by the
elisapkg profile and cannot be negotiated or downgraded using repository input.
Trusted metadata versions and hashes are persisted atomically outside project
state. Expired active metadata, rolled-back, mixed, malformed, under-threshold,
unsupported-algorithm, revoked, or unauthorized metadata fails closed, subject
to TUF's rule allowing an expired intermediate root during a valid sequential
rotation. Signatures by unknown or unauthorized keys never count toward a
role's threshold.

The initial engine review evaluated
[`sigstore-rust` commit `79d8597006987309930ed3b286f58668adee43cd`](https://github.com/sigstore/sigstore-rust/tree/79d8597006987309930ed3b286f58668adee43cd),
whose `sigstore-tuf` crate is version 0.14.0. On Rust 1.99, its library and
integration targets passed 34 tests with default features disabled. The
repository's release `conformance_client` also passed all 119 tests from the
official [`tuf-conformance` v2.5.0 harness](https://github.com/theupdateframework/tuf-conformance/tree/1bc18916ee35f753b6eb8ee19dabb98449ca7326)
on x86_64 Linux with Rust 1.99.0; the candidate's xfail list contained no
active entries. This exercises general TUF behavior, including expiry,
rollback, root rotation, threshold signatures, delegation, and target hash
verification. The unqualified no-default-features test command failed to
compile an example that imports the feature-gated `HttpRepository`. This
baseline is not a profile approval: the reviewed parser accepted duplicate
JSON members, accepted `spec_version` values outside this profile's stable
`1.0.P` range, and accepted SHA-512 target digests. The reviewed update paths
also log and swallow metadata-store write failures, while the default file
store does not fsync the metadata file and parent directory. Its Rust API has
no stable C ABI for the Elisa FFI boundary. The general conformance suite does not establish
that elisapkg's stricter profile rejects duplicate JSON members or unsupported
algorithms, that trusted-state writes are durable and failure-propagating, or
that the Elisa FFI boundary is safe. Each of these gaps must be resolved and
verified against the exact pinned build before this candidate can be approved;
remote registry operations remain disabled in the meantime.

The pinned [`Role::is_expired`](https://github.com/sigstore/sigstore-rust/blob/79d8597006987309930ed3b286f58668adee43cd/crates/sigstore-tuf/src/metadata/mod.rs)
helper compares `expires_at() < now`, while the [TUF workflow](https://theupdateframework.github.io/specification/v1.0.36/)
requires every active metadata expiry to be later than the fixed refresh start
time. Equality is therefore accepted by that helper even though the profile
must reject it. The root-expiry ABI applies its own `<=` comparison; future
timestamp, snapshot, and targets operations must enforce the same rule,
including subsecond timestamps.

The candidate review is version-specific. On 2026-11-10, the latest published
[`sigstore-tuf` release](https://github.com/sigstore/sigstore-rust/releases)
was 0.15.1 (signed release commit `fc308a2`); its release notes include API
stabilization work ahead of 1.0, crypto agility, and a switch to
`sigstore-crypto` for hashing. The reviewed crate archive
([`sigstore-tuf` 0.15.1](https://docs.rs/crate/sigstore-tuf/0.15.1)) had SHA-256
`fb4ea7f5d83c3d2d06397d153de059ff5b6f594fb04c3d8dc1912d127cf105db`. Reviewing
its source confirmed that several profile gaps remain: metadata parsing accepts any
`1.x` `spec_version`; integrity checking supports SHA-512 and skips unknown
algorithms when another supported hash exists; updater cache-store failures are
logged and ignored; and the filesystem store atomically renames a temporary
file without syncing the file and parent directory. Its JSON parser first
materializes a `serde_json::Value`, so duplicate-member rejection still needs
to happen before the foreign parser, as it does in Elisa. The 0.15.1 release
therefore is not approved for the package profile or durable trust-state
ownership. The official [TUF conformance dashboard](https://theupdateframework.github.io/tuf-conformance/)
was updated 2026-11-09 and
reports `sigstore-rust` at 119/119; that is general conformance evidence, not a
result for the previously pinned 0.14.0 build or the 0.15.1 source/profile/ABI
combination. Re-pin and rerun the exact release before reconsidering it.

An exploratory Rust FFI prototype linked an Elisa-emitted object on Linux
x86-64 and exercised bounded TUF root verification and rotation. The
prototype remains in Git history under `spikes/tuf_ffi`. That experiment
did not establish durable rollback protection, complete metadata refresh,
delegation, or compatibility across supported platforms. The package manager
does not use the prototype.

The fixture in D-011 remains a local implementation test only. Its custom
single-key index and signed metadata are not a compatible TUF implementation
or a network protocol. TUF authenticates release authorization and exact
target bytes; it does not prove that package code is safe or independently
attest how a build was produced. Build provenance, operational key custody,
provider approval, and all D-005/M0/M5 security gates remain separate release
requirements.

## D-014: local dependency compilation

The build adapter compiles only version 2 local-path graphs. It reconstructs
the canonical local roots from the lock, revalidates each package identity,
manifest digest, source-tree digest, and unique library target, then emits one
bounded aggregate Elisa source in private scratch. A deterministic
dependency-first walk uses reverse-edge counters, binary-searched package
identities, and package-name ordering. The graph is capped at 65,536 edges and
the aggregate at 32 MiB. An absent or ambiguous library target, missing edge,
cycle, registry record, or mixed source graph fails closed. The receipt binds
the ordered logical dependency target paths along with the lock and source
digests. The separately emitted aggregate of verified snapshot paths is
compared byte-for-byte after the compiler exits and before publication.
Registry build support remains disabled
until authenticated source acquisition, cache extraction, and graph-wide
compilation are integrated. Fixture: `scripts/local_dependency_build_regression.py`.
