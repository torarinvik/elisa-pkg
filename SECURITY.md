# Security policy

`elisapkg` treats package metadata, source archives, manifests, lockfiles, and registry responses as hostile input. The current implementation has no enabled remote source provider. `fetch` fails closed with exit status 5, and `publish`/remote `install NAME` are not enabled. `install --local` remains an offline, receipt-backed deployment of the current build and does not consume registry data. Remote support stays disabled while the selected TUF verifier, provider, and key operations remain unimplemented and under review.

The selected production trust protocol is TUF Specification v1.0.33. Its
elisapkg profile and remaining implementation gates are documented in
[`docs/decisions.md`](docs/decisions.md) (D-013),
[`docs/tuf-profile.md`](docs/tuf-profile.md), and
[`docs/security.md`](docs/security.md). Protocol selection does not mean the
TUF verifier or production key operations are implemented: remote fetch,
publish, and install remain disabled until those gates pass. A checksum or TLS
connection by itself is not publisher authentication.

The client must never execute registry-provided shell commands, build scripts, plugins, or post-install hooks. Compiler builds receive no publication credentials. Archive extraction must reject path traversal, links, devices, duplicate/case-colliding paths, malformed metadata, and resource-limit violations before any final cache path is touched.

The Elisa implementation keeps these decisions behind `Trust` and `Security` modules. `Trust::VerificationCode` distinguishes missing, invalid, unauthorized, expired, rollback, and digest failures; the current production policy returns a hard failure for every remote operation because no reviewed verifier is enabled. A status code or lockfile entry never acts as proof of authenticity.

Report suspected vulnerabilities privately to the project maintainers. Include the affected version, command, platform, and a minimal reproduction without publishing credentials or malicious payloads. Do not claim that signatures make package code harmless: an authorized publisher can still publish malicious source, so source trust and execution isolation remain separate controls.
