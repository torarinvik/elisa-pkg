# `elisapkg.lock` schemas version 2 and 3

The lockfile records the exact resolution policy and selected package bytes. It is generated but intended to be committed. `--locked` and `--frozen` never edit it; a missing or byte-different lock is an error. Normal `resolve` writes the file only after validation succeeds. `fetch` validates the root manifest fingerprint first; for registry lock v3 it then checks every exact record against freshly authenticated metadata before caching the archive.

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
before emitting these records; the lockfile remains untrusted input and is
revalidated against the configured registry during `resolve --locked` or
`fetch`.

After a registry archive is fetched, the content-addressed cache stores an immutable
receipt beside the blob. The receipt repeats the exact package, version, archive,
sizes, archive and metadata digests, and expiry. `build --offline` and `build --frozen`
use only this receipt, the verified archive, and a pre-existing trust-state record; they
fail closed when any evidence is absent or changed and never rewrite the lockfile.

Lock replacement uses an exclusive `mkstemp` file in the project directory, writes all bytes with short-write handling, calls `fsync`, closes the descriptor, and atomically renames the temporary file into place. A failed write or durability step removes the temporary file and leaves the previous lock untouched. The temporary file is created with owner-only permissions while it is in flight.

Dependency edits also journal the original manifest and, when present, the
original lock under `.elisapkg/transaction.*`. A state marker is advanced only
after each replacement; startup recovery restores the original pair for an
unfinished transaction and removes the journal after a completed one.

Registry entries will add the registry identity, exact version, immutable source descriptor, archive size and SHA-256 digest, authenticated metadata version, signer/delegation identity, and normalized dependency edges. Absolute paths, credentials, host-specific temporary locations, and mutable branch names do not belong in a published lockfile.

Local path resolution walks reachable local dependencies transitively. Paths are normalized relative to the project root (`a/../b` is recorded as `b`), duplicate package names must resolve to the same path and version, and package records are sorted by canonical package name before serialization.
The active parent chain is tracked separately from the queue, so a cycle is a
resolution error while a shared diamond dependency remains valid.

The root package record and each local record carry `manifest-digest`, a SHA-256
digest of the exact validated manifest bytes, and `source-digest`, a SHA-256
digest of its first validated target entry. They detect root and dependency
manifest/source drift in frozen resolution; complete source-tree and archive
digests remain a separate release gate and are not implied by these fields.

Canonical bytes are UTF-8, two-space indentation, LF endings, deterministic member ordering, sorted package and edge arrays, and exactly one terminal newline. The resolver version is part of the format so changing candidate ordering or trust policy cannot silently reuse an old result.
