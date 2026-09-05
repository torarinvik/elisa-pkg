# Security release gates

Remote source acquisition is disabled in the current binary. `elisapkg fetch`,
`publish`, and remote `install NAME` fail with security status 5 until a trusted
source provider is configured. `install --local` is a separate, offline path
that only publishes the current package's verified build output under the
user-selected prefix. This is an intentional fail-closed boundary, not a
temporary insecure mode.

Before enabling remote packages, the implementation must use an established signed-metadata protocol and an audited cryptographic provider. The client must bootstrap a trusted root out of band, validate threshold-signed role metadata and namespace delegation, bind identity/version/registry/archive digest together, enforce expiry and monotonic rollback protection, and persist trusted metadata versions atomically. Publisher authorization must cover the exact deterministic archive bytes. Unknown algorithms, missing thresholds, stale or replayed metadata, invalid signatures, revoked keys, and unauthorized namespaces are hard failures.

The `Trust` module now exposes metadata prechecks for expiry, rollback,
namespace, and algorithm policy. They are deliberately not signature
verification; the production policy still rejects every remote operation until
the reviewed provider and trust-state persistence are implemented.

Archive extraction is a separate boundary. The accepted subset is regular files and directories only, with bounded compressed and expanded sizes, no links/devices/special modes, no absolute or traversal paths, no duplicate or case-colliding names, private staging, and atomic publication into a verified content store. Cache pathnames and receipts are never treated as proof of verification.

Manifest bytes must be valid UTF-8 before field interpretation. The local
target validator rejects absolute, parent, dot-prefixed, and
backslash path forms, then canonicalizes both the package root and each target
entry with `realpath` and enforces a component boundary. This catches a
lexically safe path that escapes through a symlink. `Integrity::sha256` is
covered by FIPS known-answer tests and is used only as a content primitive;
`Trust` must still authenticate any digest before remote bytes are accepted.

Build subprocesses receive no credentials and no arbitrary dependency scripts. Compile-time execution is currently trusted-source execution; sandboxing is not claimed. A security review, fuzz corpus, interruption/concurrency tests, key rotation/revocation exercise, and compromise-recovery drill are release blockers for remote support.

The local executor starts compiler and application children through `/usr/bin/env -i` with a fixed PATH. It retains only the three compiler bootstrap variables needed by the self-hosting wrapper and never forwards the parent environment wholesale. This is credential minimization, not a sandbox: the selected compiler and trusted source still have the operating-system privileges of the invoking user.

Every package build additionally sets `ELISA_STAGE1_SEMANTIC_GATE=1` in the
controlled child environment. A semantic diagnostic therefore stops the build
before an artifact can be reported as successful.

Local installation uses a per-prefix mkdir lock and exclusive hard-link
publication for both the binary and its receipt. It refuses pre-existing
destinations, records the artifact SHA-256 digest, and only uninstalls when the
receipt, package name, path, and current bytes all match. A changed executable
or receipt is left in place for manual recovery.

The local package writer emits only regular files in sorted ustar order with
zero timestamps and normalized ownership. It rejects unsafe or overlong names,
state/VCS directories, and credential-like filenames before reading bytes;
PAX/GNU extensions and compression are not accepted. Before the archive is
written, a second parser verifies its magic, octal fields, checksum, regular
file mode, case-folded duplicate names, data padding, zeroed extension fields,
and exactly two zero end blocks. Remote publication still requires signed
metadata and publisher authorization.

`cache gc --dry-run` does not delete anything. Actual cache collection remains
disabled until it can mark live lock, lease, and installation references and
recheck them before unlinking immutable entries.

Review corrections: archive reads use descriptor-relative no-follow opens for
all components, detect I/O errors, and reject special files. Archive validation
also checks zero data padding and file/directory conflicts. Frozen resolution
performs no lockfile replacement. Build receipt v2 reuses only when the target,
manifest, compiler settings, and artifact digest all match; included sources
and complete toolchain contents remain outside the current key.

These changes do not supply the planned remote verifier or execution sandbox.
Project mutation and installation still assume a trusted, user-owned directory;
concurrent malicious changes to state or installation directories require further
handle-based filesystem work before hostile shared directories are supported.
