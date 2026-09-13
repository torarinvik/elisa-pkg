# Security release gates

Network source acquisition is disabled in the current binary. `elisapkg fetch`
verifies local path sources against the lockfile. When `ELISAPKG_REGISTRY_DIR`
is configured, `fetch PACKAGE REQUIREMENT` also verifies detached Ed25519
metadata, expiry, archive size, and archive digest for a local registry
artifact. Remote fetches, real `publish`, and remote `install NAME` fail with
security status 5 until the TUF verifier, provider, network transport, and
publisher authorization are implemented and reviewed.
`publish --dry-run` is a local validation-only preflight and does not cross that
trust boundary.
`install --local` is a separate, offline path
that only publishes the current package's verified build output under the
user-selected prefix. This is an intentional fail-closed boundary, not a
temporary insecure mode.

The file-backed registry's signed `index` is a local test fixture only. Its
byte-for-byte Ed25519 signature binds the configured registry, package,
positive generation, expiry, and complete declared version list. The list is
bounded, sorted, unique, and limited to stable SemVer without build metadata.
Each package generation and snapshot digest are persisted in the clock-bound
trust state; a lower generation or changed bytes at the same generation fail
closed. Index files, signatures, and trust roots use the same owner, mode, ACL,
and no-follow checks as other trusted inputs. This custom index is not TUF, is
not the production format, and must not be served over a network. Its signed
completeness claim and first-use replay limitation apply only to the fixture.

The local Ed25519 verifier uses fixed OpenSSL candidates only. It resolves each
candidate, opens its directory chain without following links, and checks the
opened executable's owner, mode, ACL, and execute permission before use. The
executable must be root-owned or owned by the effective user and must not be
group- or world-writable. Directory components must be root-owned or
effective-user-owned and protected from world writes. A non-root macOS process
may use an effective-user-owned group-writable provider directory only when
the owning group is the system `admin` group; that group is treated as
privileged. A process running as root never trusts an effective-user-owned
provider tree. If no candidate meets the policy or supports Ed25519, signature
verification fails closed. Package trust records also require the version to
appear in the currently authenticated index, and the exact generation and
snapshot digest are rechecked under the trust-state lock before package
history is written.
Individual signed release metadata must also expire within 30 days of
verification. Longer lifetimes fail as a distinct security error, bounding the
replay window even when a signing key creates an accidentally far-future
expiry.

Local installation checks the nearest existing prefix ancestor before creating
directories. Existing path components must be real directories owned by root or
the effective user and must have no group or other write bits. Installation
then rechecks the completed `bin` and receipt directory chains; uninstall checks
both existing chains before opening its transaction lock or reading files. This
reduces cross-user replacement risk. On macOS, every opened directory is also
checked for extended ACLs: deny-only entries are accepted, while allow entries
and unknown tags fail closed. Linux ACL grants are not inspected. Neither mode
nor ACL checks prevent pathname races by another process with the same user ID;
handle-relative identity-checked removal remains required before hostile shared
prefixes can be supported. A durable per-prefix transaction journal records
install or uninstall intent before the executable or receipt changes. The next
locked operation validates the journal and both artifacts, then finishes or
abandons only a state whose package identity, digest, and receipt match exactly;
malformed or mismatched state stops with its evidence intact. The regression
suite synthesizes reachable durable states and uses
`scripts/install_killpoint_regression.py` to kill an instrumented copy of the
Elisa binary after each install and uninstall transaction boundary. It then
checks recovery with the production binary. Test controls are inserted only in
a temporary source copy. These tests cover process death between transaction
operations, but not interruption inside an FFI filesystem helper or physical
power loss. Retirement removes the journal only after syncing the binary and
receipt directories, then syncs the prefix directory so the journal removal is
durable too.

Before enabling remote packages, the implementation must conform to the
selected TUF v1.0.36 profile in [`decisions.md`](decisions.md) and
[`tuf-profile.md`](tuf-profile.md), use an audited cryptographic provider,
bootstrap roots out of band, enforce role thresholds and package-scoped
delegation, bind exact target length and digest plus package identity, and
persist expiry/rollback state atomically. The local fixture requires
`ELISAPKG_REGISTRY_TRUST_ROOT` to point to an independently provisioned
32-byte key outside `ELISAPKG_REGISTRY_DIR`; registry contents cannot select
their own trust root. The configured registry path must canonicalize
successfully. The configured key path is checked against both the configured
registry path and their canonical identities; a key path that cannot be
resolved fails with `MissingTrustRoot`. The key and persisted trust files are
opened once through descriptor-relative, no-follow paths. Every directory in
those paths and each file must be owned by root or the effective user and must
not be group- or world-writable. Symlinks and shared writable directories such
as `/tmp` are rejected. On macOS, directory and regular-file checks also
reject extended ACL allow entries and unknown ACL tags; deny-only entries are
accepted. Linux ACL grants are not inspected.

`Trust::precheck_threshold`, `precheck_revocation`, and
`precheck_publisher_attestation` validate caller-supplied policy facts; they do
not count TUF role signatures, discover revoked keys, or verify build
provenance. Only `Trust::verify_detached` currently invokes the local exact-byte
Ed25519 provider, and that path is not a TUF implementation. Remote use must
reject unknown algorithms, missing thresholds, stale or mixed metadata,
invalid signatures, revoked keys, and unauthorized namespaces through the
complete selected TUF chain. Namespace authorization must cover the exact
deterministic archive target bytes.

The CI workflow now emits a GitHub provenance attestation for the tested
main-branch candidate executable, manifest, archive, and checksum. This is a
separate client-build identity record: the `Trust` module does not fetch or
verify it, it does not authorize an Elisa package namespace or publication,
and it does not replace the pending TUF and publisher-verification work.

The `Trust` module exposes metadata prechecks for expiry, rollback, namespace,
and algorithm policy plus an exact-byte detached Ed25519 verification gate.
Verified local-registry selections persist monotonic package/version/archive-
digest/metadata-digest records outside the project in a user-owned trust-state
file. Trust-state format v4 keys package history by registry-root hash and
package name, in addition to binding each version to its archive and signed
metadata digests. It also pins each registry path to the SHA-256 fingerprint
of its configured Ed25519 key in the same rollback-protected state file; key
changes fail closed instead of starting a fresh version-history namespace.
When older v2/v3 state is next updated after a signed index verifies, its
existing history is preserved and the currently configured key is recorded as
the pin. Because those legacy formats contain no signing-key fingerprint, this
first v4 enrollment is necessarily trust-on-first-use: it cannot detect that the
configured key changed before enrollment. Deployments that require continuity
across this migration must preserve and verify the expected key out of band.
An explicit override containing any unscoped v2
package rows fails closed because their registry provenance cannot be recovered.
Legacy v1 records without metadata identity fail closed rather than being
migrated. Updates hold a nonblocking
kernel `flock` on a persistent protected regular file at `<state>.lock`; the
inode stays in place and the kernel releases ownership after a process crash.
The complete state is published with a durable atomic rename. A pre-existing
legacy lock directory fails closed and is never removed automatically while an
older process might still be using it. Lower versions and same-version
archive- or metadata-digest changes fail closed; malformed or unavailable
state is a security error. The default path is
`$HOME/.local/share/elisapkg/trust/<sha256-of-registry-root>.state`, with
`ELISAPKG_TRUST_STATE` available for an explicit absolute path. Override paths
must use canonical non-empty components; `.` and `..` are rejected before any
state directory is opened. Network operations remain disabled until transport
and publisher delegation are reviewed. The sibling `.clock` file stores both
the greatest observed wall-clock timestamp and the SHA-256 of the exact state
bytes. Recording and successful verification compare that digest before using
history; successful verification advances the bound clock while holding the
same lock and rechecks evidence expiry against that clock observation. A missing
or restored state file with a retained newer clock fails closed. The sidecar is
written before changed state bytes; a crash between the
two atomic writes also fails closed. A legacy clock without a state digest is
malformed and is not migrated automatically. Restoring both user-owned files
together remains outside this local check's protection because they are not
anchored in hardware-backed monotonic storage.
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
are cached by metadata digest. Frozen or offline `fetch` re-hashes and
signature-verifies that snapshot, validates its dependency edges against the lock,
then validates the receipt, content-addressed archive, and existing user-owned
trust record without contacting a provider or mutating the lockfile. Registry
artifact verification and caching does not enable registry dependency builds:
`build`, `run`, and `test` reject a version 3 lock containing registry
dependencies before launching a compiler, whether or not its artifacts are
cached. Missing, malformed, mismatched, expired, or untrusted evidence is a
security failure; a cache pathname alone is never evidence.

Manifest bytes must be valid UTF-8 before field interpretation. The local
target validator rejects absolute, parent, dot-prefixed, and
backslash path forms, then canonicalizes both the package root and each target
entry with `realpath` and enforces a component boundary. This catches a
lexically safe path that escapes through a symlink. `Integrity::sha256` is
covered by FIPS known-answer tests and is used only as a content primitive;
`Trust` must still authenticate any digest before remote bytes are accepted.

Compiler children on macOS run under a deny-by-default Seatbelt profile. The profile denies network access and gives the child a unique private scratch directory for HOME/TMPDIR/cache data and every compiler output, including stage1's intermediate object. It does not grant write access to the build cache, artifact, or receipt. Before launch, elisapkg copies the selected package inputs into private source snapshots, verifies each copy against its locked source digest, and allows the child to read those snapshots while denying reads from the live project and dependency roots. Snapshot writes are denied. Stage1's legacy callback path is reserved by the trusted launcher with exclusive creation before sandbox entry; the child receives exact-path read access and data-write access to that existing inode, without create, mode, or unlink permission. The parent removes the callback path after the child exits. Compiler stdin is redirected to `/dev/null`; stdout and stderr are captured in exclusive files inside private scratch and forwarded by the parent after the compiler process group has stopped. After setting those standard streams, the launcher closes every inherited descriptor numbered 3 or higher before `exec`; failure to close them stops the child. The writable exceptions are private scratch, the pre-created callback inode, and `/dev/null`. Exact compiler and required system-helper paths receive execution and executable-mapping rights; selected toolchain and runtime-library directories are read-only. Tool-root expansion is limited to known compiler and LLVM layouts and never grants HOME or an ancestor as an inferred tool root. Unsupported platforms, profile construction failures, and sandbox launch failures stop the build; there is no unsandboxed build fallback.

The compiler reads the verified snapshots, configured compiler/toolchain roots, and narrow runtime-library directories required by selected Homebrew LLVM installations. The live package roots are denied after their broad read exceptions are established. A case-insensitive path rule blocks the shared credential policy’s common store directories, Git metadata (including `.git/config` and `.git/config.worktree`), credential filenames, and private-key formats from the snapshots; package roots that are themselves named credential stores are rejected. This name-based denylist is partial: arbitrary secrets stored in otherwise eligible source files or toolchain paths remain visible. The profile also allows process creation and the selected build tools, so this is a constrained compiler boundary, not a general hostile-code sandbox or a guarantee that a compromised compiler cannot attack the invoking account through an unmodeled OS interface. `scripts/sandbox_policy_test.py` first proves Bash can connect to a loopback listener outside the sandbox, then verifies the generated profile denies that same connection. It checks representative mixed-case and nested credential paths against the generated rule, verifies sandboxed builds can read ordinary snapshot source while live project source, `.git/config`, and `.git/config.worktree` remain denied, then checks snapshot writes and callback data writes cannot escape their exact inode and path boundaries. The probes run only when a permissive control profile can be applied; release CI must set `ELISAPKG_REQUIRE_SANDBOX_TESTS=1` so an unavailable Seatbelt host fails instead of skipping the policy checks. Linux build execution remains unavailable and fails closed. This profile is an interim macOS adapter, not a substitute for independent sandbox review, adversarial tests, and a maintained platform isolation API.

Build subprocesses receive a minimal environment through `/usr/bin/env -i`; registry credentials and unrelated variables are omitted. When the selected adapter and stage1 binary resolve to the expected sibling `scripts/elisac_stage1.sh` and `bin/elisac-stage1` layout, elisapkg invokes stage1 directly because macOS refuses the wrapper's setuid `ps` RSS poll under Seatbelt. This skips the wrapper's source-freshness check as well as RSS polling; the selected binary's digest is recorded in the receipt, but it is not verified against compiler source. The package parent applies CPU, file-size, and deadline limits, disables core dumps, and kills the compiler's process group before it validates output. Memory use is not capped: this host rejects the attempted low data-segment/address-space limits for ordinary compiler processes, while the resident-size limit is not reliable. This is a material limitation for hostile builds.

`run` and `test` launch the resulting artifact as the invoking user, outside the compiler sandbox. Users should treat these commands as executing the package's code with their account's permissions. Arbitrary build scripts, plugins, and automatic native dependency installation remain disabled.

Compiler children have a ten-minute monotonic deadline; `run` and `test`
children have a two-minute deadline. Each child enters a private process group,
and refuses to execute if that group cannot be established. Build execution
kills and checks the group after normal exit as well as after timeout or wait
failure, before reading the output artifact. `run` and `test` apply the same
cleanup after their direct child exits, times out, or cannot be reaped.
Process-group cleanup does not prove that every descendant has exited: a
process can create a new session, and Seatbelt permits this for compiler
children. The compiler-owned output is therefore
copied to a fresh parent-owned inode after hashing; the old exact output path
is unlinked before publication, preventing a retained output descriptor from
changing the cached artifact. Detached descendants remain a resource/cleanup
limitation and are a release gate for hostile remote builds.

Immediately before `exec`, compiler, `run`, and `test` children close every
inherited descriptor numbered 3 or higher, preserving only standard input,
output, and error. A close failure stops execution. This prevents a caller's
open files, sockets, and credential-agent descriptors from becoming ambient
capabilities in package code. The compiler and shared `run`/`test` launch paths
are covered by `scripts/inherited_fd_regression.py`.

Build profiles deny reads from root-level `.elisapkg`, `build`, and `target`
directories inside the root package and every locked local dependency,
including ASCII case variants on case-insensitive filesystems. The
source walker excludes those directories only at the package root, so nested
source directories with the same names remain fingerprinted and readable from
the verified snapshots. Live project and dependency roots remain unreadable.
VCS metadata components (`.git`, `.hg`, `.svn`) and every file or directory
named `IMPLEMENTATION_PLAN.md` are excluded from the digest and denied to the
compiler at any depth, with ASCII case-insensitive matching. Only the unique
private scratch directory and its exact compiler output are reallowed. The
source walker also fails closed on symlinks instead of omitting them from the
digest while allowing the compiler's include reader to follow them. The
read-only snapshot root is also explicitly reallowed after its source-state
and credential denials; writable scratch remains a separate sibling tree.

Generic local package source reads currently open each path component with
descriptor-relative `openat`, `O_NOFOLLOW`, and `O_NONBLOCK`, then check that
the final descriptor is a regular file. This rejects symlinks and avoids
blocking on FIFOs, but the regular-file check happens after `openat`: an
existing character or block device can receive its device `open` operation
before the client rejects it. The generic source walk also does not require
each parent directory to be protected against mutation by another uid. Do not
treat this path as safe for adversarial trees containing device nodes or for
source paths inside hostile shared-writable directories. Before making local
source trees an adversarial input boundary, add a descriptor-pinned
pre-stat/open/post-identity check and a parent policy that preserves valid
private temporary directories and elevated reads from user-owned trees; test
sticky-directory behavior and races on both supported operating systems.

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

Local installation uses a persistent regular lock file and an exclusive
nonblocking kernel `flock` shared by install and uninstall. The lock inode is
never removed: unlinking it could let concurrent processes lock different
inodes for the same prefix. The descriptor is close-on-exec, and the kernel
releases its lock when the process exits, including after a crash. The lock file
is opened relative to a trusted prefix directory with no-follow and nonblocking
flags, then checked as a protected regular file with acceptable ownership and,
on macOS, ACL entries. Existing legacy directory lock paths and malformed lock
files fail closed; review and remove a legacy path manually only after ensuring
no old installer is still running. `scripts/install_lock_regression.py` checks
contending processes, crash release, persistent inode behavior, and rejection of
symlinks, FIFOs, and directories.

Install and uninstall write a durable per-prefix transaction journal before
changing a binary or receipt. The next operation recovers under the persistent
kernel lock only when the journal, package identity, digest, receipt, and
on-disk artifact agree; malformed or externally changed state fails closed
with its evidence preserved. `scripts/install_transaction_regression.py`
synthesizes recovery states; `scripts/install_killpoint_regression.py` adds
process kills after each transaction-level install/uninstall operation and
validates recovery with the production binary. Fault controls exist only in a
temporary copied source tree. The tests do not interrupt inside FFI filesystem
helpers or simulate power loss. Same-UID pathname races and Linux ACL grants
also remain outside the current protection.

The local package writer emits only regular files in sorted ustar order with
zero timestamps and normalized ownership, with a maximum of 512 selected files
per archive. A shared `PackagePathPolicy` rejects
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
state for the local registry fixture, but do not supply the selected TUF
verifier, remote transport, or production publisher/delegation operations. The
current Seatbelt profile applies only
to compiler children on macOS; output execution and project mutation are not
sandboxed. Project mutation assumes a trusted, user-owned directory. Local
installation enforces root/effective-user ownership and no-group/other-write
permissions on its directory chain. Uninstall reads each receipt-owned file
through one trusted descriptor and compares its device/inode through that same
parent directory immediately before `unlinkat`. macOS also rejects extended
ACL allow entries and unknown tags, while Linux ACLs and a same-UID race between
the final identity comparison and `unlinkat` remain. This narrows the pathname
window but does not make concurrent hostile same-UID mutation safe.
