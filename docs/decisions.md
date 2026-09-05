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

Receipt version 2 fingerprints the selected target source, manifest bytes,
compiler configuration, and output artifact. A matching receipt and verified
artifact may be reused; included non-target sources and complete compiler
contents remain outside the key and require a future expansion. A failed child
or invalid output never replaces the last known-good artifact. Fixture:
compiler-failure and artifact-preservation cases in the regression suite.

## D-008: trusted-source execution

The current supported build path executes selected compiler and Elisa source
with a scrubbed environment but does not claim an OS sandbox. Dependency build
scripts, plugins, post-install hooks, and automatic native dependency
installation are disabled. This remains a release limitation until an
enforceable process-isolation adapter is proven.
