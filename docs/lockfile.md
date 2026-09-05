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

Registry entries will add the registry identity, exact version, immutable source descriptor, archive size and SHA-256 digest, authenticated metadata version, signer/delegation identity, and normalized dependency edges. Absolute paths, credentials, host-specific temporary locations, and mutable branch names do not belong in a published lockfile.

Canonical bytes are UTF-8, two-space indentation, LF endings, deterministic member ordering, sorted package and edge arrays, and exactly one terminal newline. The resolver version is part of the format so changing candidate ordering or trust policy cannot silently reuse an old result.
