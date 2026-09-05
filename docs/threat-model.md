# `elisapkg` threat model

This is the tracked release-gate threat model for the implementation roadmap.
The package manager treats manifests, lockfiles, registry metadata, archives,
Git data, cache records, and compiler diagnostics as hostile input.

| Asset | Attacker capability | Required property | Current defense | Remaining gate |
| --- | --- | --- | --- | --- |
| package identity and version | registry/CDN replacement | authenticated name, registry, version binding | remote operations disabled | signed metadata and delegation |
| source archive bytes | mirror or cache poisoning | exact digest and safe extraction | deterministic writer/verifier plus no-follow staged extraction; no remote fetch | verified source store |
| trusted metadata state | replay/freeze/rollback | expiry and monotonic version checks | precheck contracts only | persistent signed trust state |
| project manifest/lock pair | crash or concurrent editor | recoverable consistent mutation | journaled local edits | bounded mutation lock and kill-point matrix |
| credentials | malicious package/compiler/log path | scoped storage and redaction | scrubbed compiler environment; remote disabled | credential-store adapter and redirect tests |
| build output | failed or malicious compiler child | failed builds preserve known-good output | exclusive temp, pre-rename validation | sandbox/resource policy |
| cache entries | writable pathname or stale receipt | immutable verified bytes | local digest-addressed hard-link, read-only receipt revalidation, and quarantine on republish; no shared remote cache | leases, GC, and concurrent-reader policy |
| installation prefix | unrelated executable or race | ownership and atomic replacement | receipt and hard-link publication | platform lock and upgrade fault tests |
| compiler/runtime | bootstrap compromise | pinned provenance and semantic gate | explicit seed/runtime inputs | signed release provenance |

Out of scope for signatures alone are a fully compromised operating system,
the invoking user's account, and a malicious package that is correctly
authorized by its publisher. Those cases require least privilege, review, and
eventual process isolation; they are never represented as “trusted code is
safe.”

The mandatory negative corpus includes unauthorized signatures, wrong
registry/name/version bindings, threshold failures, unknown algorithms,
expired/replayed metadata, restored old trust state, poisoned receipts,
credential-changing redirects, hostile archives, symlink races, and interrupted
publication. A remote release is blocked until those fixtures run through
resolution, fetch, frozen/offline use, and installation boundaries.
