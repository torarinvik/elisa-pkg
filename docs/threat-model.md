# `elisapkg` threat model

This is the tracked release-gate threat model for the implementation roadmap.
The package manager treats manifests, lockfiles, registry metadata, archives,
Git data, cache records, and compiler diagnostics as hostile input.

| Asset | Attacker capability | Required property | Current defense | Remaining gate |
| --- | --- | --- | --- | --- |
| package identity and version | registry/CDN replacement | authenticated name, registry, version binding | remote operations disabled | signed metadata and delegation |
| registry version index | replay, omission, or replacement | authenticated completeness and freshness | unsigned local index is read through no-follow descriptors with owner/mode/ACL checks on every ancestor and the file | index is not fully rollback-safe; signed expiring snapshots and persisted monotonic generations are mandatory before remote or mirror transport |
| source archive bytes | mirror or cache poisoning | exact digest and safe extraction | deterministic writer/verifier plus no-follow staged extraction; no remote fetch | verified source store |
| trusted metadata state | replay/freeze/rollback | expiry and monotonic version checks | detached Ed25519 verification, v2 per-user history binds archive and metadata digests, successful locked verification advances the state-bound clock | restoring both user-owned files together is outside local storage protection; remote transport and publisher delegation remain disabled |
| project manifest/lock pair | crash or concurrent editor | recoverable consistent mutation | journaled edits and lock refreshes; exclusive guard ownership during recovery; staged lock replacement | bounded mutation lock and kill-point matrix |
| credentials | malicious package/compiler/log path | scoped storage and redaction | scrubbed compiler environment; shared credential-path denylist in source collection, package selection, and compiler profile | project and local dependency trees are readable; arbitrary secrets need a stronger input boundary |
| build output | failed or malicious compiler child | failed builds preserve known-good output | Seatbelt on macOS, configured network denial, private scratch for all compiler outputs, exact pre-created callback data-write, captured stdio, process-group cleanup, parent-owned artifact snapshot; generated-profile loopback and callback probes in `scripts/sandbox_policy_test.py` | Release CI must require those host-dependent probes; detached sessions can outlive the group; scratch quotas and a maintained isolation API remain required |
| cache entries | writable pathname or stale receipt | immutable verified bytes | local digest-addressed hard-link, read-only receipt revalidation, and quarantine on republish; no shared remote cache | leases, GC, and concurrent-reader policy |
| installation prefix | unrelated executable, crash, or race | ownership and recoverable publication | receipt and hard-link publication; a durable per-prefix journal is recovered under the persistent kernel `flock` and binds package, version, executable digest, and derived receipt path; every existing directory in the prefix chain must be root/euid-owned and not group/other-writable; macOS also rejects extended ACL allow entries and unknown tags | malformed or identity-mismatched journal state fails closed; a legacy mkdir lock path fails closed and needs manual review; Linux ACL grants and same-UID pathname races remain; regression fixtures model durable crash states but do not yet kill the process at every syscall boundary |
| compiler/runtime | bootstrap compromise | pinned provenance and semantic gate | explicit seed/runtime inputs | signed release provenance |

Out of scope for signatures alone are a fully compromised operating system,
the invoking user's account, and a malicious package that is correctly
authorized by its publisher. The current compiler boundary is macOS-only and
does not sandbox artifacts launched by run/test; stronger process isolation is
still required before hostile shared directories or remote packages are
supported.

The mandatory negative corpus includes unauthorized signatures, wrong
registry/name/version bindings, threshold failures, unknown algorithms,
expired/replayed metadata, restored old trust state, poisoned receipts,
credential-changing redirects, hostile archives, symlink races, and interrupted
publication. A remote release is blocked until those fixtures run through
resolution, fetch, frozen/offline use, and installation boundaries.
