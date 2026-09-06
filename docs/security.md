# Security release gates

Network source acquisition is disabled in the current binary. `elisapkg fetch`
verifies local path sources against the lockfile. When `ELISAPKG_REGISTRY_DIR`
is configured, `fetch PACKAGE REQUIREMENT` also verifies detached Ed25519
metadata, expiry, archive size, and archive digest for a local registry
artifact. Remote fetches, `publish`, and remote `install NAME` fail with
security status 5 until transport and publisher authorization are configured.
`install --local` is a separate, offline path
that only publishes the current package's verified build output under the
user-selected prefix. This is an intentional fail-closed boundary, not a
temporary insecure mode.

Before enabling remote packages, the implementation must use an established signed-metadata protocol and an audited cryptographic provider. The client must bootstrap a trusted root out of band, validate threshold-signed role metadata and namespace delegation, bind identity/version/registry/archive digest and size together, enforce expiry and monotonic rollback protection, and persist trusted metadata versions atomically. The local fixture takes this first step by requiring `ELISAPKG_REGISTRY_TRUST_ROOT` to point to an independently provisioned 32-byte key outside `ELISAPKG_REGISTRY_DIR`; registry contents cannot select their own trust root. The Elisa `Trust` module already exposes fail-closed prechecks for those bindings, publisher attestation, thresholds, revocation, and clock rollback; these prechecks never substitute for cryptographic verification. Publisher authorization must cover the exact deterministic archive bytes. Unknown algorithms, missing thresholds, stale or replayed metadata, invalid signatures, revoked keys, and unauthorized namespaces are hard failures.

The `Trust` module exposes metadata prechecks for expiry, rollback, namespace,
and algorithm policy plus an exact-byte detached Ed25519 verification gate.
Verified local-registry selections persist monotonic package/version/digest
records outside the project in a user-owned trust-state file. Updates hold an
exclusive lock directory and publish the complete state with a durable atomic
rename. Lower versions and same-version digest changes fail closed; malformed
or unavailable state is a security error. The default path is
`$HOME/.local/share/elisapkg/trust/<sha256-of-registry-root>.state`, with
`ELISAPKG_TRUST_STATE` available for an explicit absolute path. Network
operations still remain disabled until transport and publisher delegation are
reviewed. A sibling `.clock` file records the greatest observed wall-clock
timestamp through the same atomic publication path; malformed values and clock
rollback fail closed before expiry or trust-state updates. Removing the sidecar
after trust history exists is also an unavailable-state error, so deletion
cannot reset the rollback floor.

State-directory creation and atomic file publication use descriptor-anchored
`mkdirat`/`openat`/`renameat`/`linkat` traversal. Reads, temporary files,
access checks, cleanup, and directory changes reject symlinked `.elisapkg`,
build, install, and receipt paths, including intermediate parent links.
Controlled local dependency reads may use normalized `..` path segments so
sibling packages remain supported; target and state paths are validated before
they reach this seam.

Canonical target checks use a bounded platform `realpath` wrapper. It resolves
into caller-provided storage only after checking the input and output limits;
short buffers fail instead of receiving a truncated or overflowing path.

Archive extraction is a separate boundary. The accepted subset is regular files
with parent directories created by the extractor, bounded archive and file
sizes, no links/devices/special modes, no absolute or traversal paths, no
duplicate or case-colliding names, and a private empty staging directory. Cache
pathnames and receipts are never treated as proof of verification.

Registry cache entries carry a separate immutable verification receipt. Its fields bind
the exact lock selection to the archive name, size, archive digest, authenticated
metadata digest, and expiry. Frozen or offline builds validate that receipt, the
content-addressed archive, and the existing user-owned trust record without loading
registry metadata or mutating the lockfile. Missing, malformed, mismatched, expired, or
untrusted evidence is a security failure; a cache pathname alone is never evidence.

Manifest bytes must be valid UTF-8 before field interpretation. The local
target validator rejects absolute, parent, dot-prefixed, and
backslash path forms, then canonicalizes both the package root and each target
entry with `realpath` and enforces a component boundary. This catches a
lexically safe path that escapes through a symlink. `Integrity::sha256` is
covered by FIPS known-answer tests and is used only as a content primitive;
`Trust` must still authenticate any digest before remote bytes are accepted.

Build subprocesses receive no credentials and no arbitrary dependency scripts. Compile-time execution is currently trusted-source execution; sandboxing is not claimed. A security review, fuzz corpus, interruption/concurrency tests, key rotation/revocation exercise, and compromise-recovery drill are release blockers for remote support.

The local executor starts compiler and application children through `/usr/bin/env -i` with a fixed PATH. It retains only the three compiler bootstrap variables needed by the self-hosting wrapper and never forwards the parent environment wholesale. This is credential minimization, not a sandbox: the selected compiler and trusted source still have the operating-system privileges of the invoking user.

Compiler children have a ten-minute monotonic deadline; `run` and `test`
children have a two-minute deadline. Each child enters a private process group,
and refuses to execute if that group cannot be established. A timeout then kills
the group before the temporary artifact is removed. This
limits hangs and descendant-process leaks, but it does not replace a sandbox or
prevent a trusted child from consuming resources until the deadline.

Before `exec`, the child also applies a platform resource profile: compiler
children receive 600 seconds of CPU time and a 128 MiB file-size limit, while
run/test children receive 120 seconds of CPU time and a 64 MiB file-size limit;
core dumps are disabled. If the operating system refuses the profile, the child
exits before running user-selected code. These limits are host-specific
guardrails and do not provide filesystem or network isolation.

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
and exactly two zero end blocks. The `Archive` staged extractor repeats the
same restrictions in the private Elisa platform module, requires an empty
destination, creates parent directories with `openat`/`mkdirat` and
`O_NOFOLLOW` through FFI, and publishes each
regular file with `O_EXCL` plus `fsync`; it removes files it created if
extraction fails. Remote publication still requires signed metadata and
publisher authorization.

`cache verify` treats `.elisapkg/package.tar` and `.elisapkg/package.receipt` as
an all-or-nothing pair. The receipt records the package identity, manifest
digest, lock digest, and deterministic archive digest; verification re-reads the
archive through the no-follow platform seam and recomputes every digest. A
missing pair member, changed archive, changed lock, or changed manifest is a
security failure rather than a cache miss. The archive is also retained as a
local content-addressed hard-link under `.elisapkg/cache/sha256/<prefix>/`; the
same digest is recomputed from that blob, so a corrupted cache object cannot be
consumed as a normal miss. Package publication flushes the cache directory after
linking the verified blob and before publishing the receipt. When a package
operation quarantines a corrupt active blob, it publishes the evidence with an exclusive hard link and refuses to replace
an existing `<digest>.invalid` record.

`cache gc --dry-run` does not delete anything. Actual cache collection remains
disabled until it can mark live lock, lease, and installation references and
recheck them before unlinking immutable entries.

Review corrections: archive, manifest, lockfile, receipt, and artifact reads
use descriptor-relative no-follow opens for all components, including absolute
paths anchored at `/`; atomic writes and cleanup use the same parent-handle
boundary, detect I/O errors, and reject special files.
Archive validation
also checks zero data padding and file/directory conflicts. Frozen resolution
performs no lockfile replacement. Build receipt v6 reuses only when the
complete sanitized source tree, selected target, manifest, compiler settings,
compiler/stage1/runtime content identities, and artifact digest all match. An
unavailable toolchain identity disables reuse rather than silently trusting a
stale artifact.

These changes supply detached Ed25519 verification and persistent rollback
state for the local registry fixture, but do not supply the planned remote
transport, publisher delegation, or execution sandbox. Project mutation and
installation still assume a trusted, user-owned directory; concurrent
malicious changes to installation directories require further handle-based
filesystem work before hostile shared directories are supported.
