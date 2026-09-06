# Local authenticated registry fixture

`elisapkg fetch PACKAGE REQUIREMENT` reads a deterministic file-backed registry
when `ELISAPKG_REGISTRY_DIR` is set. This provider is the transport-neutral
boundary for future network transports: all metadata is read with bounded Elisa
FFI file operations and verified before an archive path is returned.

The directory must be an absolute, symlink-free path. Its layout is:

```text
REGISTRY/
  root.ed25519
  PACKAGE/index
  PACKAGE/VERSION/metadata.json
  PACKAGE/VERSION/metadata.sig
  PACKAGE/VERSION/archive.tar
```

`root.ed25519` is exactly 32 raw Ed25519 public-key bytes. `index` is a
newline-separated list of unique, complete SemVer versions. The resolver picks
the highest version satisfying the requested exact, caret, tilde, or comparison
requirement.

`metadata.json` is signed byte-for-byte as stored, including its final newline
if present. It must be a unique-key JSON object containing:

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
digest are all compared with the selected path and bytes. Expiry is checked
against the host wall clock. A detached signature or trust root that is missing,
malformed, unavailable, or invalid fails closed. The Ed25519 provider is the
small FFI seam in `src/platform_native.elisa`; signature policy remains in
`src/trust.elisa` and `src/registry.elisa`.
