# Security release gates

Network source acquisition is disabled in the current binary. `elisapkg fetch`
verifies local path sources against the lockfile. When `ELISAPKG_REGISTRY_DIR`
is configured, `fetch PACKAGE REQUIREMENT` also verifies detached Ed25519
metadata, expiry, archive size, and archive digest for a local registry
artifact. Remote fetches, real `publish`, and remote `install NAME` fail with
security status 5 until transport and publisher authorization are configured.
`publish --dry-run` is a local validation-only preflight and does not cross that
trust boundary.
`install --local` is a separate, offline path
that only publishes the current package's verified build output under the
user-selected prefix. This is an intentional fail-closed boundary, not a
temporary insecure mode.

Local installation checks the nearest existing prefix ancestor before creating
directories. Existing path components must be real directories owned by root or
the effective user and must have no group or other write bits. Installation
then rechecks the completed `bin` and receipt directory chains; uninstall checks
both existing chains before opening its transaction lock or reading files. This
reduces cross-user replacement risk for ordinary mode-bit-controlled paths, but
the check does not inspect ACL grants or prevent pathname races by another
process with the same user ID. Handle-relative identity-checked removal remains
required before hostile shared prefixes can be supported.

Before enabling remote packages, the implementation must use an established signed-metadata protocol and an audited cryptographic provider. The client must bootstrap a trusted root out of band, validate threshold-signed role metadata and namespace delegation, bind identity/version/registry/archive digest and size together, enforce expiry and monotonic rollback protection, and persist trusted metadata versions atomically. The local fixture takes this first step by requiring `ELISAPKG_REGISTRY_TRUST_ROOT` to point to an independently provisioned 32-byte key outside `ELISAPKG_REGISTRY_DIR`; registry contents cannot select their own trust root. The key and persisted trust files are opened once through descriptor-relative, no-follow paths. Every directory in those paths and each file must be owned by root or the effective user and must not be group- or world-writable. Symlinks and shared writable directories such as `/tmp` are rejected. The Elisa `Trust` module already exposes fail-closed prechecks for those bindings, publisher attestation, thresholds, revocation, and clock rollback; these prechecks never substitute for cryptographic verification. Publisher authorization must cover the exact deterministic archive bytes. Unknown algorithms, missing thresholds, stale or replayed metadata, invalid signatures, revoked keys, and unauthorized namespaces are hard failures.

The `Trust` module exposes metadata prechecks for expiry, rollback, namespace,
and algorithm policy plus an exact-byte detached Ed25519 verification gate.
Verified local-registry selections persist monotonic package/version/digest
records outside the project in a user-owned trust-state file. Updates hold an
exclusive lock directory and publish the complete state with a durable atomic
rename. Lower versions and same-version digest changes fail closed; malformed
or unavailable state is a security error. The default path is
`$HOME/.local/share/elisapkg/trust/<sha256-of-registry-root>.state`, with
`ELISAPKG_TRUST_STATE` available for an explicit absolute path. Network
Override paths must use canonical non-empty components; `.` and `..` are
rejected before any state directory is opened.
operations still remain disabled until transport and publisher delegation are
reviewed. A sibling `.clock` file records the greatest observed wall-clock
timestamp through the same atomic publication path; malformed values and clock
rollback fail closed before expiry or trust-state updates. Removing the sidecar
after trust history exists is also an unavailable-state error, so deletion
cannot reset the rollback floor.
When the default location is used, `HOME` is treated as untrusted input: it
must be absolute, bounded, and free of control bytes and backslashes. Trailing
separators are collapsed (while preserving `/`), so equivalent spellings cannot
select different state paths. Invalid `HOME` values fail closed before any
trust-state directory is created.

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
metadata digest, and expiry. The exact signed metadata bytes and detached signature
are cached by metadata digest. Frozen or offline builds re-hash and signature-verify
that snapshot, validate its dependency edges against the lock, then validate the
receipt, content-addressed archive, and existing user-owned trust record without
contacting a provider or mutating the lockfile. Missing, malformed, mismatched,
expired, or untrusted evidence is a security failure; a cache pathname alone is never
evidence.

Manifest bytes must be valid UTF-8 before field interpretation. The local
target validator rejects absolute, parent, dot-prefixed, and
backslash path forms, then canonicalizes both the package root and each target
entry with `realpath` and enforces a component boundary. This catches a
lexically safe path that escapes through a symlink. `Integrity::sha256` is
covered by FIPS known-answer tests and is used only as a content primitive;
`Trust` must still authenticate any digest before remote bytes are accepted.

Compiler children on macOS run under a deny-by-default Seatbelt profile. The profile denies network access and gives the child a unique private scratch directory for HOME/TMPDIR/cache data and every compiler output, including stage1's intermediate object. It does not grant write access to the build cache, artifact, or receipt. Stage1's legacy callback path is reserved by the trusted launcher with exclusive creation before sandbox entry; the child receives exact-path read access and data-write access to that existing inode, without create, mode, or unlink permission. The parent removes the callback path after the child exits. Compiler stdin is redirected to `/dev/null`; stdout and stderr are captured in exclusive files inside private scratch and forwarded by the parent after the compiler process group has stopped. The writable exceptions are private scratch, the pre-created callback inode, and `/dev/null`. Exact compiler and required system-helper paths receive execution and executable-mapping rights; selected toolchain and runtime-library directories are read-only. Tool-root expansion is limited to known compiler and LLVM layouts and never grants HOME or an ancestor as an inferred tool root. Unsupported platforms, profile construction failures, and sandbox launch failures stop the build; there is no unsandboxed build fallback.

The compiler must read the whole project and each locked local dependency tree, plus the configured compiler/toolchain roots and narrow runtime-library directories required by selected Homebrew LLVM installations. A case-insensitive path rule blocks the shared credential policy’s common store directories, credential filenames, and private-key formats before the compiler can read them; package roots that are themselves named credential stores are rejected. This name-based denylist is partial and does not protect arbitrary secrets stored under those readable roots. The profile also allows process creation and the selected build tools, so this is a constrained compiler boundary, not a general hostile-code sandbox or a guarantee that a compromised compiler cannot attack the invoking account through an unmodeled OS interface. `scripts/sandbox_policy_test.py` first proves Bash can connect to a loopback listener outside the sandbox, then verifies the generated profile denies that same connection. It checks representative mixed-case and nested credential paths against the generated rule, then checks that callback data writes preserve the pre-created inode, cannot write a separate pre-existing inode, and cannot create, chmod, link, rename, or unlink paths. The probes run only when a permissive control profile can be applied; release CI must set `ELISAPKG_REQUIRE_SANDBOX_TESTS=1` so an unavailable Seatbelt host fails instead of skipping the policy checks. Linux build execution remains unavailable and fails closed. This profile is an interim macOS adapter, not a substitute for independent sandbox review, adversarial tests, and a maintained platform isolation API.

Build subprocesses receive a minimal environment through `/usr/bin/env -i`; registry credentials and unrelated variables are omitted. When the selected adapter and stage1 binary resolve to the expected sibling `scripts/elisac_stage1.sh` and `bin/elisac-stage1` layout, elisapkg invokes stage1 directly because macOS refuses the wrapper's setuid `ps` RSS poll under Seatbelt. This skips the wrapper's source-freshness check as well as RSS polling; the selected binary's digest is recorded in the receipt, but it is not verified against compiler source. The package parent applies CPU, file-size, and deadline limits, disables core dumps, and kills the compiler's process group before it validates output. Memory use is not capped: this host rejects the attempted low data-segment/address-space limits for ordinary compiler processes, while the resident-size limit is not reliable. This is a material limitation for hostile builds.

`run` and `test` launch the resulting artifact as the invoking user, outside the compiler sandbox. Users should treat these commands as executing the package's code with their account's permissions. Arbitrary build scripts, plugins, and automatic native dependency installation remain disabled.

Compiler children have a ten-minute monotonic deadline; `run` and `test`
children have a two-minute deadline. Each child enters a private process group,
and refuses to execute if that group cannot be established. Build execution
kills and checks the group after normal exit as well as after timeout or wait
failure, before reading the output artifact. macOS Seatbelt still allows a
forked child to create a new session, so process-group cleanup does not prove
that every descendant has exited. The compiler-owned output is therefore
copied to a fresh parent-owned inode after hashing; the old exact output path
is unlinked before publication, preventing a retained output descriptor from
changing the cached artifact. Detached descendants remain a resource/cleanup
limitation and are a release gate for hostile remote builds.

Before `exec`, the child also applies a platform resource profile: compiler
children receive 600 seconds of CPU time and a 128 MiB per-file limit, while
run/test children receive 120 seconds of CPU time and a 64 MiB per-file limit;
core dumps are disabled. The attempted memory limits were removed because this
macOS host rejects the data-segment/address-space settings for ordinary
processes and resident-size limits are unreliable. Memory use is therefore not
capped. If the operating system refuses one of the remaining limits, the child
exits before running selected code. These controls do not provide
application-run filesystem or network isolation.

Every package build additionally sets `ELISA_STAGE1_SEMANTIC_GATE=1` in the
controlled child environment. A semantic diagnostic therefore stops the build
before an artifact can be reported as successful.

Local installation uses a per-prefix mkdir lock and exclusive hard-link
publication for both the binary and its receipt. It refuses pre-existing
destinations, records the artifact SHA-256 digest, and only uninstalls when the
receipt, package name, path, and current bytes all match. A changed executable
or receipt is left in place for manual recovery.

The local package writer emits only regular files in sorted ustar order with
zero timestamps and normalized ownership. A shared `PackagePathPolicy` rejects
unsafe or overlong names, state/VCS directories, credential-bearing directories
such as `.ssh`, `.aws`, `.kube`, and `.docker`, and credential files such as
`.npmrc`, `.pypirc`, `.env*`, and private-key formats before reading bytes;
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
paths anchored at `/`; atomic writes and failure cleanup detect I/O errors and
avoid deleting destination pathnames after a concurrent replacement, while
rejecting special files.
Archive validation
also checks zero data padding and file/directory conflicts. Frozen resolution
performs no lockfile replacement. Build receipt v10 reuses only when the
complete sanitized source tree, selected target, manifest, compiler settings,
compiler/stage1/runtime/linker resolved paths and content identities, and
artifact digest all match. An unavailable linker identity disables reuse.
Identifiable toolchain files are checked again after compilation so changes
during the build cannot be recorded as the original input identity. The
source-tree digest is also checked immediately before artifact publication so
source changes during compilation cannot be recorded as the old input identity.
Package publication applies the same boundary around archive creation: it
revalidates the lock and source digest after resolution, checks the digest again
after reading the selected files, and aborts if the tree changed during that
window. This catches mixed archives caused by ordinary concurrent edits; a
hostile shared directory still requires the handle-based filesystem work noted
below.
An
unavailable toolchain identity disables reuse rather than silently trusting a
stale artifact.

These changes supply detached Ed25519 verification and persistent rollback
state for the local registry fixture, but do not supply the planned remote
transport or publisher delegation. The current Seatbelt profile applies only
to compiler children on macOS; output execution and project mutation are not
sandboxed. Project mutation assumes a trusted, user-owned directory. Local
installation enforces the root/effective-user ownership and no-group/other-write
precondition on its directory chain, but it does not inspect ACLs or stop a
same-UID process from racing pathnames. Handle-relative identity-checked removal
remains required before hostile shared installation directories are supported.
