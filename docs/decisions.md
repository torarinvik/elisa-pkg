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
`src/resolve.elisa` before registry support is enabled.

## D-004: canonical bytes

Manifest and lock fingerprints use exact validated UTF-8 bytes. Lock output uses
fixed member order, two-space indentation, LF endings, sorted package records,
and one terminal newline. Atomic writes use an exclusive temporary file,
`fsync`, and same-directory replacement. Fixture: repeated resolve and frozen
inode/mtime checks in `scripts/test.sh`.

## D-005: trust boundary

Remote operations remain fail-closed until an established signed-metadata
protocol, trusted-root bootstrap, publisher authorization, expiry/rollback
state, signed expiring index snapshots with persisted monotonic generations,
and audited cryptographic binding are implemented together. SHA-256 is an
integrity primitive only. No URL, checksum, or lockfile entry enables a remote
source by itself.

## D-006: source and archive policy

Package archives contain bounded regular files with normalized metadata. Source
reads use descriptor-relative no-follow opens for every component. Archive
headers, checksums, padding, path collisions, and end markers are verified
again before publication. `package` revalidates the lock and captures the
complete sanitized source-tree digest before reading files, then compares a
second digest before publishing the archive. A mutation during that read window
fails packaging instead of producing a mixed source release. Fixture: archive
corruption and native symlink tests in `scripts/regression_test.py`.

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

Manifest and lock edits acquire an exclusive `.elisapkg/transaction.guard`
directory before journaling state. Normal lockfile publication uses the same
journal and guard, and records the replacement bytes before publishing them.
Recovery claims the guard before replaying a stale journal; an existing guard is
treated as an active or interrupted transaction and blocks further commands.
Successful commit, rollback, and recovery remove the guard. A guard left by an
interrupted process still requires explicit operator recovery.

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

The local registry fixture uses a detached Ed25519 signature over the exact
metadata bytes. The trust root is an independently provisioned 32-byte file
selected through `ELISAPKG_REGISTRY_TRUST_ROOT`, outside the mutable registry
directory; metadata binds the
registry path, package, selected SemVer, archive relative path, byte size, and
SHA-256 digest. The resolver validates the archive as deterministic ustar and
recomputes its digest before returning success. Registry file reads reject
symlinked descendants by requiring `realpath` equality, and a no-argument
locked fetch reauthenticates every v3 record before caching it. Each verified
selection is persisted outside the project in a per-user monotonic trust-state
file protected by an exclusive lock and durable atomic replacement. On macOS,
ACL allow entries and unknown ACL tags on both trust directories and regular
trust files are rejected; deny-only entries are accepted. A network
transport and publisher delegation remain separate release gates. The local
version index is unsigned filesystem-trusted data. Its no-follow descriptor
walk checks owner, mode, and supported ACL policy for each ancestor and the
file, but does not authenticate completeness or freshness: first-use omissions
and replay remain possible, and the same user can modify it. It is not fully
rollback-safe. Signed expiring index snapshots and a persisted monotonic index
generation are mandatory before remote or mirror transport. Trust history
format v2 binds package, version, archive digest, and metadata digest; legacy
history without metadata identity fails closed. Successful offline
verification advances the state-bound clock only after signed metadata and
archive checks, and rechecks expiry using the time sampled while holding the
trust-state lock.

## D-012: local installation directory trust

Local install checks the nearest existing prefix ancestor before creating
directories and rechecks the final `bin` and receipt directory chains. Uninstall
requires both existing chains to pass the same check before it reads or removes
files. Every checked directory must be owned by root or the effective user and
must not have group or other write bits; symlinks are rejected by the
descriptor-relative walker. On macOS it rejects extended ACL allow entries and
unknown tags while accepting deny-only entries; Linux ACL grants remain
unchecked. The check does not
prevent same-UID pathname races, so handle-relative identity-checked removal
remains a release gate for hostile shared directories. Fixtures cover writable
prefixes and ancestors, symlinked components, writable binary or receipt
directories, and macOS ACL cases in `scripts/test.sh`.
