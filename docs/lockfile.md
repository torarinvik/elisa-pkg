# `elisapkg.lock` schema version 2

The lockfile records the exact resolution policy and selected package bytes. It is generated but intended to be committed. `--locked` and `--frozen` never edit it; a missing or byte-different lock is an error. Normal `resolve` writes the file only after validation succeeds.

The first local release emits:

```json
{
  "lock-version": 2,
  "resolver": "elisapkg-v2",
  "package": {"name": "elisapkg", "version": "0.1.0"},
  "packages": []
}
```

Lock replacement uses an exclusive `mkstemp` file in the project directory, writes all bytes with short-write handling, calls `fsync`, closes the descriptor, and atomically renames the temporary file into place. A failed write or durability step removes the temporary file and leaves the previous lock untouched. The temporary file is created with owner-only permissions while it is in flight.

Dependency edits also journal the original manifest and, when present, the
original lock under `.elisapkg/transaction.*`. A state marker is advanced only
after each replacement; startup recovery restores the original pair for an
unfinished transaction and removes the journal after a completed one.

Registry entries will add the registry identity, exact version, immutable source descriptor, archive size and SHA-256 digest, authenticated metadata version, signer/delegation identity, and normalized dependency edges. Absolute paths, credentials, host-specific temporary locations, and mutable branch names do not belong in a published lockfile.

Local path resolution walks reachable local dependencies transitively. Paths are normalized relative to the project root (`a/../b` is recorded as `b`), duplicate package names must resolve to the same path and version, and package records are sorted by canonical package name before serialization.
The active parent chain is tracked separately from the queue, so a cycle is a
resolution error while a shared diamond dependency remains valid.

Each local record also carries `manifest-digest`, a SHA-256 digest of the exact
validated manifest bytes. It detects manifest drift in frozen resolution; source
file/archive digests remain a separate release gate and are not implied by this
field.

Canonical bytes are UTF-8, two-space indentation, LF endings, deterministic member ordering, sorted package and edge arrays, and exactly one terminal newline. The resolver version is part of the format so changing candidate ordering or trust policy cannot silently reuse an old result.
