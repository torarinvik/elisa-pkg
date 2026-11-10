# `elisapkg.lock` schemas version 2 and 3

The lockfile records the exact resolution policy and selected package bytes. It is generated but intended to be committed. `--locked` and `--frozen` never edit it; a missing or byte-different lock is an error. Normal `resolve` writes the file only after validation succeeds. `fetch` validates the root manifest fingerprint first; for registry lock v3 it then checks every exact record against freshly authenticated metadata before caching the archive.

Package version strings in both local and registry lock records use the same
128-byte SemVer limit as package manifests. Lock records are still untrusted
input and are rejected when their version text is malformed or exceeds that
bound.

The first local release emits:

```json
{
  "lock-version": 2,
  "resolver": "elisapkg-v2",
  "package": {"name": "elisapkg", "version": "0.1.0", "manifest-digest": "sha256:<hex>", "source-digest": "sha256:<hex>"},
  "packages": []
}
```

Registry-only graphs use lockfile version 3 and the resolver identifier
`elisapkg-registry-v1`. Each selected record includes the canonical registry
identity, exact package/version, archive filename, byte size, archive SHA-256,
and metadata SHA-256. The resolver verifies the signed metadata and archive
before emitting these records. The lockfile remains untrusted input. `resolve`
with `--locked` or `--frozen` validates its structure, root fingerprints, and
direct version constraints without contacting a registry. `fetch` revalidates
registry records against freshly authenticated metadata and can cache their
signed metadata and archives. Registry dependencies are not yet consumable by
`build`, `run`, or `test`: every v3 build is rejected before compiler launch,
even after `fetch` has verified and cached all artifacts. Offline and frozen
`fetch` operations can validate matching cached signature and archive evidence.

During a normal registry refresh, versions in the previous lock are soft
candidate-order preferences: a still-valid locked version is tried first, but
the preference never adds a package constraint. The new lock contains only
packages reachable from the current root requirements and the dependencies of
the selected versions. `fetch` applies the same preferences while
reconstructing the lock, then checks the exact authenticated records and graph.

Offline and frozen validation also checks every direct registry requirement
against its locked SemVer. A structurally valid record with an out-of-range
version is rejected before cached bytes are used.

After a registry archive is fetched, the content-addressed cache stores an immutable
receipt beside the blob, keyed by both archive and metadata digest. The exact signed metadata bytes are cached under their
metadata digest, with the detached signature stored beside that snapshot. The receipt
repeats the exact package, version, archive, sizes, archive and metadata digests, and
expiry. Offline or frozen `fetch` re-hashes the snapshot, verifies its signature
and dependency edges against the lock, then verifies the archive and the
pre-existing trust-state record. Missing, changed, expired, or untrusted evidence
fails closed and the lockfile is never rewritten. This authenticates and caches
package artifacts; it does not enable building a package graph that contains
registry dependencies.

Lock replacement uses an exclusive `mkstemp` file in the project directory, writes all bytes with short-write handling, calls `fsync`, closes the descriptor, and atomically renames the temporary file into place. A failed write or durability step leaves the previous lock untouched; the owner-only temporary evidence is retained for a later recovery or cleanup pass instead of unlinking a pathname that could have been replaced concurrently.

Dependency edits and normal lockfile refreshes journal the original manifest
and, when present, the original lock under `.elisapkg/transaction.*`. New lock
bytes are staged before the lockfile is atomically replaced. Startup recovery
claims the exclusive guard before replaying a stale journal and removes the
journal after a completed transaction. An existing guard blocks recovery, so a
second process cannot restore the old pair during a live edit. A leftover guard
after interruption remains fail-closed and requires explicit operator recovery.

Registry entries will add the registry identity, exact version, immutable source descriptor, archive size and SHA-256 digest, authenticated metadata version, signer/delegation identity, and normalized dependency edges. Absolute paths, credentials, host-specific temporary locations, and mutable branch names do not belong in a published lockfile.

Local path resolution walks reachable local dependencies transitively. Paths are normalized relative to the project root (`a/../b` is recorded as `b`), duplicate package names must resolve to the same path and version, and package records are sorted by canonical package name before serialization.
The active parent chain is tracked separately from the queue, so a cycle is a
resolution error while a shared diamond dependency remains valid.

The root package record and each local record carry `manifest-digest`, a SHA-256
digest of the exact validated manifest bytes, and `source-digest`, a SHA-256
digest of the complete sanitized source tree under that package root. The tree
fingerprint sorts logical relative paths and combines each path with its raw
SHA-256 content digest; manifest and lock bytes have dedicated fields and are
excluded from this fingerprint to avoid a self-reference. These fields detect
root and dependency source drift in frozen resolution.

Local graph fingerprinting is bounded to 256 MiB of source file bytes across
the root and all reachable path dependencies, with the existing 64 MiB per-file
limit. Larger graphs fail resolution before generating a lockfile; build
snapshots retain the same 256 MiB aggregate cap.

Canonical bytes are UTF-8, two-space indentation, LF endings, deterministic member ordering, sorted package and edge arrays, and exactly one terminal newline. The resolver version is part of the format so changing candidate ordering or trust policy cannot silently reuse an old result.
