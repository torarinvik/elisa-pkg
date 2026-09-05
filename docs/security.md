# Security release gates

Remote source acquisition is disabled in the current binary. `elisapkg fetch`, `publish`, and `install` fail with security status 5 until a trusted source provider is configured. This is an intentional fail-closed boundary, not a temporary insecure mode.

Before enabling remote packages, the implementation must use an established signed-metadata protocol and an audited cryptographic provider. The client must bootstrap a trusted root out of band, validate threshold-signed role metadata and namespace delegation, bind identity/version/registry/archive digest together, enforce expiry and monotonic rollback protection, and persist trusted metadata versions atomically. Publisher authorization must cover the exact deterministic archive bytes. Unknown algorithms, missing thresholds, stale or replayed metadata, invalid signatures, revoked keys, and unauthorized namespaces are hard failures.

Archive extraction is a separate boundary. The accepted subset is regular files and directories only, with bounded compressed and expanded sizes, no links/devices/special modes, no absolute or traversal paths, no duplicate or case-colliding names, private staging, and atomic publication into a verified content store. Cache pathnames and receipts are never treated as proof of verification.

The local target validator rejects absolute, parent, dot-prefixed, and
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
