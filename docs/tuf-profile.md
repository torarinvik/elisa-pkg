# elisapkg TUF profile

This document is the selected production registry metadata profile referenced
by decision D-013. It is an implementation contract, not evidence that network
registry support is implemented or ready to enable.

## Specification and interoperability

- Implement
  [TUF Specification v1.0.36](https://theupdateframework.github.io/specification/v1.0.36/),
  including TAP 6, TAP 9, TAP 10, and TAP 11. TUF permits adopters to define
  how metadata `spec_version` matches the expected version ([specification
  rule](https://theupdateframework.github.io/specification/v1.0.36/#file-formats-root)).
  Elisapkg accepts only stable versions `1.0.P` where the numeric patch `P` is
  between 0 and 36 inclusive. Reject malformed versions, prerelease or build
  suffixes, any other major/minor version, and a patch above 36. A later patch
  or any other TUF specification requires an explicit compatibility review
  and a new decision before it is accepted.
- Use the TUF JSON metadata format and the canonical signed-byte rules defined
  by that specification. A conformant client may implement role, delegation,
  and state policy in Elisa; signature primitives must come from a reviewed
  cryptographic library through the narrow native FFI boundary. If a suitable
  maintained TUF client can be integrated safely on every supported platform,
  evaluate it before implementing the verifier. If the TUF client is written
  in Elisa, prove conformance with independently generated fixtures,
  differential vectors against a separate TUF implementation, fuzzing, and
  independent review. Never substitute the local detached-signature fixture.
- Reject duplicate JSON object keys, invalid UTF-8, floating-point values,
  noncanonical integer encodings, malformed timestamps, and metadata exceeding
  configured size, role-count, delegation-depth, or target-count bounds before
  it can affect trust state. Preserve and authenticate fields as required by
  TUF. In `custom.elisapkg`, accept only fields defined by its schema version;
  reject unknown fields that could alter package semantics. Require every role
  threshold to be a positive integer and reject thresholds larger than the
  number of distinct authorized key IDs.
- Initially accept only TUF `ed25519` signing keys and signatures. Verify each
  declared key ID in root and delegation key maps against the TUF SHA-256 key
  ID calculated from that key's canonical public fields. Each signature must
  encode exactly 64 bytes as hexadecimal. Accept SHA-256 target digests encoded
  as exactly 64 lowercase hexadecimal characters. Do not negotiate algorithms
  from server input. Supporting an additional
  signature or digest algorithm requires a reviewed profile change, a trusted
  metadata migration, and compatibility fixtures.

The initial resource limits are: 1 MiB per metadata file; 64 authorized keys
per role; 320 keys total in root metadata; 65,536 delegation keys total;
64 signatures per metadata file; 4,096 package-scoped delegated roles; one
delegation hop from top-level Targets to a package role; 4,096 targets in each
Targets role; 4,096-byte target paths; 64 MiB per target artifact; 1,024
sequential root updates per refresh; and 64 JSON container levels. The
duplicate-key validator additionally bounds each file to 65,536 total object
keys, 8,500,000 candidate comparisons, and 65,536 bytes of key-equality
comparisons; exceeding any of these limits rejects the metadata before trust
state is changed. These limits are part of the profile and require a reviewed
change if they prove too small for a real registry.

## Repository identity and root trust

- Each configured registry has a stable local registry identity and its own
  TUF repository root. Metadata from separate roots is never combined, and a
  package name in one registry cannot authorize a same-named package from a
  different registry.
- The distribution supplies the default root with the client. Additional
  roots require an explicit authenticated out-of-band enrollment operation.
  A repository, mirror, lockfile, package manifest, or environment variable
  provided by the repository cannot silently enroll or replace a root.
- Root updates are processed one version at a time and verified according to
  TUF's old-root and new-root threshold rules. Persist every validated
  intermediate root before continuing. An expired intermediate root does not
  stop a valid sequential rotation; after processing the chain, reject the
  update if the final trusted root is expired at the fixed update start time.
  Skipped, malformed, incorrectly signed, or unauthorized root transitions
  stop the update.
- The root role establishes the keys and thresholds for top-level Targets,
  Snapshot, and Timestamp. Top-level Targets delegates only package-scoped
  authority. Deployment records must identify distinct key holders, role
  thresholds, offline custody, recovery operators, rotation, and emergency
  revocation procedures before production use.
- Root metadata has exactly the four required TUF roles (`root`, `timestamp`,
  `snapshot`, and `targets`), with the optional `mirrors` role allowed. Reject
  unknown roles, more than 64 key IDs in any role, and more than 320 keys in
  the root key map.
- Require `consistent_snapshot: true` in every trusted root. Reject missing or
  false values so the client uses versioned metadata and hash-prefixed target
  names as required by this profile.

## Roles, package authority, and target identity

- Validate root, timestamp, snapshot, top-level targets, and each required
  delegated targets role using the ordered client workflow in TUF v1.0.36.
  Require signed expiry, monotonic metadata versions, snapshot references, and
  hashes/lengths so stale, mixed, or rollback metadata cannot be accepted.
- Package release authority is a delegated Targets role scoped to the
  normalized package namespace; its role name is `package-<name>` so valid
  package names cannot collide with TUF's top-level role names. Its path is
  exactly `packages/<name>/*/*.tar`. Top-level Targets metadata
  must not directly list targets under `packages/`; each package target must
  be reached through its package-scoped delegation. Each such delegation is
  terminating and uses exactly `packages/<name>/*/*.tar` in its `paths` field,
  with no `path_hash_prefixes`; package path scopes are disjoint, so a later
  role cannot provide a fallback target for the same namespace. Delegation
  depth is limited to one hop: a package-scoped role may list its release
  targets but may not delegate further. Only signatures from keys authorized
  for the active role count toward its threshold. Unknown or unauthorized
  signatures never count; insufficient valid signatures, unsupported trusted
  algorithms, revoked keys, or a namespace mismatch are hard failures.
- The logical target path is
  `packages/<normalized-name>/<exact-version>/<sha256>.tar`. The repository
  sets TUF consistent snapshots to true. A package role has at most one
  archive for each exact stable version. The target's TUF length and SHA-256
  digest describe the exact deterministic ustar archive bytes; the client
  rechecks both before parsing or extracting the archive.
- Each target has an authenticated `custom.elisapkg` object with an explicit
  schema version. It binds the configured registry identity, normalized
  package name, exact stable SemVer, dependency declarations (registry,
  package, and requirement), compiler requirements, archive format, and
  publication/revocation state to the target. The client checks the custom
  identity fields against the role scope and target path. It compares
  dependency declarations with the packaged manifest before accepting the
  package graph.
- Package metadata cannot supply arbitrary fetch URLs, executable hooks,
  compiler commands, alternate roots, or cryptographic policy. The client
  selects targets only through configured repository policy and TUF metadata.
  Mirrors are untrusted byte sources; all downloaded metadata and archive bytes
  must still match authenticated TUF references.
- HTTPS is required for configured remote origins. TLS protects credentials
  and availability but does not establish package authenticity. Credentials
  are bound to the configured origin and are never forwarded across redirects
  to another origin.

## Freshness, persistence, and offline behavior

- Each role's maximum expiry horizon and refresh schedule must be explicitly
  bounded in the deployment profile. At refresh start, capture one fixed
  update time and use it for every expiry decision in that metadata chain. The
  client rejects expired active role metadata, including the final trusted
  root, and detects wall-clock rollback against persisted trusted observations.
  During sequential root rotation, an expired intermediate root may be used
  only to verify and persist the next root; after the chain is processed, the
  final root must be unexpired at the fixed update start time.
- Persist accepted metadata versions and hashes atomically in protected
  per-user state outside the project. Cache receipts are not authority: offline
  use must revalidate the cached TUF chain, expiry policy, metadata identities,
  and target bytes under the stored trust state.
- A lockfile constrains package selections but cannot select a root, signer,
  target URL, role, or policy. Resolution, fetch, frozen/offline use, and
  installation all verify the same registry, namespace, package, version,
  dependency, and target-digest bindings.
- Offline operation cannot learn about a newly issued revocation. The default
  policy fails when required metadata is expired or unavailable; any archival
  exception must be a distinct, explicit policy with visible limitations and
  separate review.

## Publisher authorization and limits

The package-scoped Targets delegation authorizes which release keys may
publish exact package target metadata and archive digests. TUF does not prove
that the source is safe or that the archive was built from a claimed commit.
Build provenance, CI signer isolation, short-lived publication credentials,
and malicious-but-authorized package risks remain separate controls under
release gates in `docs/security.md`.

The local file-backed registry documented in `docs/registry.md` is a test
fixture only. Its custom `index`, JSON payload, and detached Ed25519 signatures
are not a TUF wire format, an alternative trust path, or a network-compatible
precursor. Its tests may be retained to cover Elisa policy and filesystem
boundaries, but production trust must come from the full TUF chain above.

## Required conformance and security evidence

Before network support is enabled, fixtures must cover:

- run the official TUF conformance suite against the exact client build and
  pinned specification version; require every applicable security test to pass,
  with skips or expected failures individually justified and reviewed;
- known-good metadata generated independently by a conformant TUF tool;
- `spec_version` values `1.0.0`, `1.0.31`, and `1.0.36` accepted, while `1.0.37`,
  `1.1.0`, `2.0.0`, malformed versions, prerelease versions, and build-metadata
  suffixes are rejected;
- root bootstrap, sequential root rotation, old/new threshold failures, and
  recovery from revoked or compromised role keys;
- valid signatures from unauthorized keys and valid delegated signatures
  outside the package namespace are rejected when the authorized role
  threshold is not met; an otherwise valid threshold is unaffected by an
  extra unknown signature, while duplicate key IDs in a metadata signature
  array are rejected as malformed;
- wrong repository, package, version, dependency, compiler, target path, size,
  and digest bindings;
- an expired intermediate root accepted only within a valid sequential
  rotation, and an expired final root, targets, snapshot, or timestamp rejected;
  rollback, freeze, fast-forward, equivocation, and mixed-metadata attempts;
- malformed JSON, duplicate keys, oversized metadata, delegation-depth and
  target-count limits, unsupported algorithms, and canonicalization edge cases;
- cache modification, concurrent trust-state updates, restored old state,
  clock rollback, offline/frozen use, and installation with stale or revoked
  trust evidence;
- parser fuzzing and an independent review of the trust adapter, cryptographic
  provider, key custody, network credential handling, and FFI boundary.

Remote `fetch`, `publish`, and `install NAME` remain disabled until all required
fixtures pass and the independent security review has no unresolved
release-blocking findings.
