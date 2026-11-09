# Test-only TUF FFI spike

This isolated spike checks whether the transport-free `sigstore-tuf` verifier
can sit behind a narrow versioned C ABI and be called from Elisa. The upstream
dependency is pinned to commit
[`79d8597006987309930ed3b286f58668adee43cd`](https://github.com/sigstore/sigstore-rust/tree/79d8597006987309930ed3b286f58668adee43cd).
The Rust crate builds a static library; it adds no C source files.

The ABI accepts at most 1 MiB per metadata file, catches Rust unwinding panics,
and returns stable integer status codes. Root verification writes its summary
only after threshold verification succeeds. It rejects mismatched TUF root key
IDs, non-Ed25519 root keys, roots with more than 64 key IDs in any role, over
320 root keys, metadata with more than 64 signatures, duplicate signature key
IDs, and malformed Ed25519 signature encodings before the upstream verifier
processes them. The adapter also recomputes delegated-key IDs and applies the
same Ed25519 profile to delegation key maps. Timestamp verification checks the
timestamp role against a trusted root and returns the authenticated snapshot
version, length, and SHA-256 pin. Snapshot verification rechecks that chain,
validates each snapshot metadata entry's bounded length and SHA-256 pin,
verifies the snapshot threshold, and returns its version and entry count. A pin
lookup operation re-verifies the same chain and returns one authenticated
metadata version, length, and digest for a requested entry. The ABI also checks
one root-rotation link per call; Elisa must persist that candidate before
passing it as the trusted root for the next link. Root, timestamp, and
snapshot expiry checks use the caller's fixed refresh time at nanosecond
precision. Expired intermediate roots can pass only through sequential
rotation; final roots and active metadata must be current. The ABI still does
not own rollback floors or write trust state.

Elisa's bounded TUF JSON prechecks run before the foreign calls, so duplicate
JSON keys and noncanonical numbers never reach the upstream parser. The adapter
owns no persistent trust state, production filesystem I/O, network transport,
or package policy; the test-only fixture generator writes ephemeral signed
metadata under the probe's private build dir. Generated valid roots use
Ed25519 keys, and the probe rejects the pinned GitHub ECDSA root because it is
outside the selected package profile. The source root fixture is copied from
the pinned upstream `crates/sigstore-tuf/tests/../../sigstore-trust-root/repository/tuf_github_root.json`
path (SHA-256 `eb303461e0109458144b6ebcbfd62aaa6f6d7481e9ca77504b85f17761661462`).

The foreign declarations in `abi_probe.elisa.in` are at compilation-unit scope
because the current Elisa compiler requires that placement. All caller-facing
operations remain under the qualified `TufEngine` module with public and private
sections. The adapter is experimental and must not be linked into the production
binary: the pinned upstream crate still has profile and durable-cache gaps
recorded in `docs/decisions.md` (D-013).

On the Vast Linux x86_64 checkout used for this proof, the compiler's `-emit
exe` fallback could not link because it referenced a callback source file that
was absent at link time. The probe therefore emits an Elisa object and links it
through the small Rust process runner; it verifies the ABI call and object-level
linkage, but not the product's final executable-link pipeline.

Run the probe with the pinned Rust toolchain and an Elisa compiler checkout:

```sh
ELISA_COMPILER_ROOT=/path/to/Elisa-compiler spikes/tuf_ffi/run.sh
```

The script runs the spike crate's Rust tests, builds the release static library,
emits the Elisa probe object, links it with a tiny Rust process entry point and
the adapter, and runs it from a private package root. This keeps the spike free
of C sources. The probe exercises valid-root summary output, tampered signature
rejection, duplicate-key rejection in Elisa, and spec-version rejection. It
also generates three ephemeral roots, makes the intermediate root expired,
verifies two consecutive rotations through the Elisa ABI, and checks final-root
expiry separately, including equality and subsecond boundaries. It verifies a
timestamp signature and authenticated snapshot pin, rejects an expired or
exact-boundary timestamp, and rejects a skipped root version, invalid
signature, and expired final root. The Rust ABI now has snapshot-chain,
authenticated pin lookup, top-level Targets verification, and package-target
verification entry points; the probe does not yet exercise them. Top-level
Targets verification bounds target records, rejects direct package targets,
and checks package delegation names, paths, key IDs, and thresholds.
Package-target verification checks one caller-specified path under the
`package-<name>` delegated role against its snapshot pin and delegated
signature threshold, requires one archive per exact version, checks the
configured registry/package/version bindings and strict `custom.elisapkg`
schema, and returns the authenticated length, digest, and published/yanked
status. Revoked selections fail with a distinct status. Elisa still has to
parse and evaluate the dependency and compiler SemVer requirements, enumerate
all candidates through the authenticated role, and compare dependencies with
the packaged manifest. Signature-threshold edge cases, durable root
checkpointing, and injected write-failure tests also remain required before
any integration is considered.
