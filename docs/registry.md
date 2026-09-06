# Local authenticated registry fixture

`elisapkg fetch PACKAGE VERSION` reads a deterministic file-backed registry
when `ELISAPKG_REGISTRY_DIR` is set. `elisapkg fetch` with no package arguments
walks every registry record in a validated lockfile v3 and verifies/caches the
exact locked bytes. This provider is the transport-neutral
boundary for future network transports: all metadata is read with bounded Elisa
FFI file operations and verified before archive bytes are returned. The exact
archive is then rechecked and published to the project content-addressed cache
at `.elisapkg/cache/sha256/<first-two-hex>/<digest>`. Existing entries are
rehash-verified; corrupt entries are quarantined before replacement. No cache
pathname is treated as proof of authenticity.

The directory must be an absolute, symlink-free path. Its layout is:

```text
REGISTRY/
  PACKAGE/index
  PACKAGE/VERSION/metadata.json
  PACKAGE/VERSION/metadata.sig
  PACKAGE/VERSION/archive.tar
```

Set `ELISAPKG_REGISTRY_TRUST_ROOT` to an independently provisioned absolute
file containing exactly 32 raw Ed25519 public-key bytes. The key must not be
stored under the mutable registry directory. `metadata.sig` is exactly 64 raw
Ed25519 signature bytes. `index` is a
newline-separated list of unique, complete SemVer versions. The resolver picks
the highest version satisfying the requested exact, caret, tilde, or comparison
requirement.

`metadata.json` is signed byte-for-byte as stored, including its final newline
if present. It must be a unique-key JSON object containing only the documented
root fields (plus the optional dependency map); unknown protocol fields are
rejected before signature use. Dependency objects likewise accept only
`registry` and `version`.

```json
{
  "schema-version": 1,
  "algorithm": "ed25519",
  "registry": "/absolute/registry/path",
  "package": "example",
  "version": "1.2.3",
  "archive": "archive.tar",
  "archive-size": 1024,
  "archive-digest": "64 lowercase hexadecimal characters",
  "expires": 4102444800
}
```

The registry identity, package, version, archive name, byte size, and SHA-256
digest are all compared with the selected path and bytes. Every registry file
must also resolve through `realpath` to the exact requested path; symlinked
metadata, trust roots, indexes, and archives are refused. Expiry is checked
against the host wall clock. A detached signature or trust root that is missing,
malformed, unavailable, or invalid fails closed. The Ed25519 provider is the
small FFI seam in `src/platform_native.elisa`; signature policy remains in
`src/trust.elisa` and `src/registry.elisa`.

The archive reader verifies the strict deterministic ustar subset again at the
cache boundary. `Archive::extract_ustar_archive` can extract only into a private,
empty staging directory; it rejects links, unsafe path components, duplicate
case-folded names, nonzero metadata fields, oversized files, and malformed
checksums, and uses descriptor-relative no-follow operations for every parent.
Network/TLS transport and publisher authorization are still disabled until
their independent security review gates are complete. Signed selections are
also recorded in a user-owned trust-state file after archive verification. By
default the file is
`$HOME/.local/share/elisapkg/trust/<sha256-of-registry-root>.state`; set
`ELISAPKG_TRUST_STATE` to an absolute path when an isolated state location is
needed. The file is written through an exclusive lock directory, a temporary
file, `fsync`, atomic rename, and parent-directory `fsync`. Each package's
history is monotonic: a lower version is rejected, and a same-version digest
change is rejected. History is independent of the project lockfile, so
restoring or deleting a project cannot reset rollback protection. A stale lock
directory is left for manual recovery and causes a fail-closed trust-state
error rather than being removed automatically. Beside the state file, elisapkg
durably records the greatest observed wall-clock value in `<state>.clock` using
the same exclusive temporary-file, `fsync`, atomic-rename, and parent-directory
`fsync` sequence. A malformed clock or a later observation below that value is
rejected before trust history can advance, protecting expiry checks from a
wall-clock rollback. Older installations without a clock sidecar start at
zero and create it on their next verified selection; once records exist, a
missing sidecar is treated as unavailable state rather than a reset.
