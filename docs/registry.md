# Local authenticated registry fixture

`elisapkg fetch PACKAGE VERSION` reads a deterministic file-backed registry
when `ELISAPKG_REGISTRY_DIR` is set. `elisapkg fetch` with no package arguments
walks every registry record in a validated lockfile v3 and verifies/caches the
exact locked bytes. This provider is the transport-neutral
boundary for future network transports: all metadata is read with bounded Elisa
FFI file operations and verified before archive bytes are returned. The exact
archive is then rechecked and published to the project content-addressed cache
at `.elisapkg/cache/sha256/<first-two-hex>/<digest>`. Existing entries are
rehash-verified; corrupt entries are quarantined before replacement. Quarantine
uses an exclusive hard-link publication, so an existing evidence record causes a
fail-closed error rather than being replaced. No cache
pathname is treated as proof of authenticity.

`elisapkg publish --dry-run` is the local release preflight for packages that
will later be published through an authenticated registry. It validates the
frozen lockfile and source snapshot, generates and verifies the deterministic
archive twice in memory, and reports its size and digest; it never writes an
archive or contacts this provider.

Each verified registry archive also gets an immutable receipt in the archive digest
directory at `<archive-digest>.<metadata-digest>.receipt`. Including both digests
prevents two authenticated package/version records that share archive bytes from
colliding. The receipt binds the primary registry, package and exact version, archive
filename and size, archive digest, authenticated metadata digest, and metadata expiry.
It is created with exclusive publication and read back byte-for-byte. The
signed metadata bytes are cached at the metadata digest's content-addressed blob path,
and its raw detached signature is stored in a sibling `.sig` file with no-clobber
semantics. A warm `build --offline` or `build --frozen` accepts a registry artifact
only when the lockfile, receipt, metadata snapshot and signature, archive bytes,
expiry, dependency edges, and previously persisted trust-state record all agree; it
does not contact a provider or rewrite the lockfile.

The directory must be an absolute, symlink-free path. Its layout is:

```text
REGISTRY/
  PACKAGE/index          # signed snapshot payload
  PACKAGE/index.sig      # 64 raw Ed25519 signature bytes
  PACKAGE/VERSION/metadata.json
  PACKAGE/VERSION/metadata.sig
  PACKAGE/VERSION/archive.tar
```

Set `ELISAPKG_REGISTRY_TRUST_ROOT` to an independently provisioned absolute
file containing exactly 32 raw Ed25519 public-key bytes. The key must not be
stored under the mutable registry directory. The key and every directory above
it must be owned by root or the effective user and must not be group- or
world-writable; symlinks and shared writable directories are rejected. The
configured key path is compared with the registry path lexically and, when the
paths exist, by canonical identity as well. Reads use one no-follow descriptor,
so the bytes verified are the bytes from the checked file. Persisted trust-state
and clock files follow the same ownership, permission, and descriptor rules.
On macOS, trusted directory and regular-file descriptors also reject extended
ACL allow entries and unknown ACL tags while permitting deny-only entries;
Linux ACL grants are not inspected. Both `metadata.sig` and `index.sig` are
exactly 64 raw Ed25519 signature bytes. The `index` payload is signed
byte-for-byte and uses this bounded line format:

```text
elisapkg-index:1
registry:/absolute/registry/path
package:example
generation:7
expires:1780000000
versions:
1.0.0
1.2.0
```

The registry and package fields must match the configured registry and
requested package. Generation and expiry are canonical unsigned decimal
integers; generation must be positive. Versions must be unique, ascending,
stable SemVer values without build metadata, with at most 4096 entries. The
resolver picks the highest version satisfying the requested exact, caret,
tilde, or comparison
requirement. The snapshot expires within 30 days, and its generation is stored
in rollback-protected trust state under an identity bound to the registry and
package. A lower generation is rejected; reusing a generation with different
signed bytes is also rejected. The resolver carries the exact generation and
snapshot digest used for candidate enumeration through final version selection.
Before it records release trust, it checks that evidence against the persisted
index high-water mark under the same trust-state lock. If another process has
advanced the index, the stale selection fails closed.

The detached signature authenticates the publisher's declared complete
version set and its freshness window. It cannot prove that a trusted publisher
did not omit a release. A first-use client also cannot distinguish an older
still-valid signed snapshot from the latest unseen generation; expiry bounds
that replay window. Once a generation has been persisted, an older signed
snapshot is rejected. A same-user writer can still delete or corrupt provider
files to cause denial of service, but cannot alter a snapshot without the
signing key. Restoring both user-owned trust state and its clock together
remains outside this local storage mechanism's protection.

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
  "expires": "<Unix timestamp generated at publish time + 1 day>"
}
```

The registry identity, package, version, archive name, byte size, and SHA-256
digest are all compared with the selected path and bytes. Every registry file
must also resolve through `realpath` to the exact requested path; symlinked
metadata, trust roots, indexes, and archives are refused. Expiry is checked
against the host wall clock, and metadata more than 30 days ahead is rejected
to prevent an accidentally or maliciously long replay window. The expiry shown
above is a placeholder: publishers must write a fresh integer Unix timestamp
within that 30-day horizon before signing. A detached signature or trust root that is missing,
malformed, unavailable, or invalid fails closed. The Ed25519 provider is the
small FFI seam in `src/platform_native.elisa`; signature policy remains in
`src/trust.elisa` and `src/registry.elisa`.

The archive reader verifies the strict deterministic ustar subset again at the
cache boundary. `Archive::extract_ustar_archive` can extract only into a private,
empty staging directory; it accepts at most 512 regular-file entries and
rejects links, unsafe path components, duplicate case-folded names, nonzero
metadata fields, oversized files, and malformed checksums, and uses
descriptor-relative no-follow operations for every parent. The entry limit
keeps the verifier's and extractor's flat duplicate-name scans bounded even
for long common prefixes.
Network/TLS transport and publisher authorization are still disabled until
their independent security review gates are complete. Signed selections are
also recorded in a user-owned trust-state file after archive verification. By
default the file is
`$HOME/.local/share/elisapkg/trust/<sha256-of-registry-root>.state`; set
`ELISAPKG_TRUST_STATE` to an absolute path when an isolated state location is
needed. Trust-state operations hold an exclusive, nonblocking kernel `flock`
on a persistent protected regular file at `<state>.lock`; the inode is never
removed, and the kernel releases the lock after process exit or a crash. A
pre-existing legacy lock directory fails closed and requires manual removal
after confirming no older elisapkg process is still using it. The state file
is published through a temporary file, `fsync`, atomic rename, and
parent-directory `fsync`. Each package's
history is monotonic: a lower version is rejected, and a same-version digest
change is rejected. Format v2 binds package, version, archive digest, and signed
metadata digest together; changing either digest for an existing version is
rejected. Legacy records without metadata identity fail closed and are not
migrated. History is independent of the project lockfile, so
restoring or deleting a project cannot reset rollback protection. A stale
directory from an older release is never removed automatically because an old
process may still be active. Beside the state file, elisapkg
durably records the greatest observed wall-clock value and the SHA-256 of the
exact state bytes in `<state>.clock`, using the same exclusive temporary-file,
`fsync`, atomic-rename, and parent-directory `fsync` sequence. Both recording
and successful verification compare the state digest before using its version
history. Verification also rechecks metadata expiry against the wall-clock
value read under the trust-state lock, then advances the bound clock on success;
expired or otherwise rejected evidence cannot advance it. A missing or restored
state file with the retained clock therefore
fails closed. A malformed clock or a later observation below its value is also
rejected before trust history can advance, protecting expiry checks from a
wall-clock rollback. A clock without a state digest is malformed and is not
migrated automatically. Restoring the state and clock together remains outside
this user-owned local storage check's protection.
