# Test-only TUF FFI spike

This isolated spike checks whether the transport-free `sigstore-tuf` verifier
can sit behind a narrow versioned C ABI and be called from Elisa. The upstream
dependency is pinned to commit
[`79d8597006987309930ed3b286f58668adee43cd`](https://github.com/sigstore/sigstore-rust/tree/79d8597006987309930ed3b286f58668adee43cd).
The Rust crate builds a static library; it adds no C source files.

The ABI accepts at most 1 MiB of root metadata, catches Rust unwinding panics,
returns stable integer status codes, and writes a verified root summary only
after parsing and threshold verification succeed. Elisa's bounded TUF JSON
precheck runs before the foreign call, so duplicate JSON keys and noncanonical
numbers never reach the upstream parser. No Rust code owns persistent trust
state, performs I/O, handles network transport, or decides package policy.
The probe's signed GitHub root fixture is copied from the pinned upstream
`crates/sigstore-tuf/tests/../../sigstore-trust-root/repository/tuf_github_root.json`
path (SHA-256 `eb303461e0109458144b6ebcbfd62aaa6f6d7481e9ca77504b85f17761661462`);
the test alters signed fields to confirm signature failure and an out-of-profile
version to confirm fail-closed profile handling.

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
rejection, duplicate-key rejection in Elisa, and spec-version rejection.
Signature-threshold edge cases, root chaining, profile-specific hash rules, and
injected durable-write failures remain required before any integration is
considered.
