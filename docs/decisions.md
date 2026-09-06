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
state, and audited cryptographic binding are implemented together. SHA-256 is
an integrity primitive only. No URL, checksum, or lockfile entry enables a
remote source by itself.

## D-006: source and archive policy

Package archives contain bounded regular files with normalized metadata. Source
reads use descriptor-relative no-follow opens for every component. Archive
headers, checksums, padding, path collisions, and end markers are verified
again before publication. Fixture: archive corruption and native symlink tests
in `scripts/regression_test.py`.

## D-007: build reuse

Receipt version 5 fingerprints the selected target source and kind, manifest
bytes, resolved-lock bytes, compiler configuration, content identities for the
selected compiler/stage1/runtime inputs, artifact name, and output artifact. A matching
receipt and verified artifact may be reused only when all three toolchain
identities were captured. If an identity cannot be resolved or read, the build
still proceeds but cache reuse is disabled for that invocation. Included
non-target sources remain outside the key and require a future expansion. A
failed child or invalid output never replaces the last known-good artifact.
Fixture: compiler-failure and artifact-preservation cases in the regression
suite.

## D-008: trusted-source execution

The current supported build path executes selected compiler and Elisa source
with a scrubbed environment but does not claim an OS sandbox. Dependency build
scripts, plugins, post-install hooks, and automatic native dependency
installation are disabled. This remains a release limitation until an
enforceable process-isolation adapter is proven.

## D-009: project transaction ownership

Manifest and lock edits acquire an exclusive `.elisapkg/transaction.guard`
directory before journaling state. A guard with no recoverable state is treated
as an active or interrupted transaction and blocks further commands; the client
does not guess whether it is safe to delete another process's lock. Successful
commit and rollback remove the guard, while stale guards require explicit
operator recovery.

## D-010: local archive cache identity

Every successfully packaged archive is hard-linked into the local
`.elisapkg/cache/sha256/<prefix>/<digest>` store after deterministic archive
verification. `cache verify` rehashes both the visible archive and its receipt
backing blob; a missing or corrupted blob is a security failure. A subsequent
package operation moves a corrupted active blob to the quarantine directory
before publishing a replacement. Shared leases, destructive garbage collection,
and remote cache exchange remain disabled until their concurrency policy is
implemented. Fixture: package receipt and corrupted-blob cases in
`scripts/test.sh`.

## D-011: registry verification before use

The local registry fixture uses a detached Ed25519 signature over the exact
metadata bytes. The trust root is a separate 32-byte file; metadata binds the
registry path, package, selected SemVer, archive relative path, byte size, and
SHA-256 digest. The resolver validates the archive as deterministic ustar and
recomputes its digest before returning success. Registry file reads reject
symlinked descendants by requiring `realpath` equality, and a no-argument
locked fetch reauthenticates every v3 record before caching it. A network
transport, publisher delegation, and persisted rollback state remain separate
release gates.
