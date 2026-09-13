# Continuous integration

`.github/workflows/macos-ci.yml` is the required supported-host CI gate. It runs
the complete `scripts/test.sh` suite on an Apple Silicon macOS 15 runner. The
workflow sets `ELISAPKG_REQUIRE_SANDBOX_TESTS=1`, so unavailable Seatbelt
application or a failed network-denial/callback probe fails the job rather
than silently skipping those checks. The job has read-only repository
permissions and no package-publishing or signing credentials.

Repository rules must require the `Seeded toolchain and required sandbox tests`
check before merging to `main`; workflow files cannot configure branch
protection. Until that rule is enabled in repository settings, this job reports
failures but does not prevent a merge.

The workflow builds its toolchain from exact source revisions instead of using
whatever compiler happens to be installed on the runner:

| Input | Pinned identity |
| --- | --- |
| Elisa compiler | `7b1b33e193e5092ffac12c77109ff33ee59c4df7` |
| Elisa core / stage0 | `e33dbd60f8c3fb0316114917265e4113d686495b` |
| Go | `1.25.0`, required by the pinned core `go.mod` |
| LLVM | `23.1.1`, checked after Homebrew installation |
| `actions/checkout` | `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` |
| `actions/setup-go` | `b7ad1dad31e06c5925ef5d2fc7ad053ef454303e0` |

To update a pin, review the upstream source and compatibility notes, update the
workflow and this table together, then run the clean seed/build/test sequence
on the supported host. An LLVM formula change intentionally fails the version
check until the new compiler/runtime combination has been validated. Go module
dependency changes are constrained by the pinned core `go.sum` and
`GOFLAGS=-mod=readonly`.

This job verifies the current macOS ARM64 build and isolation contract. It does
not establish Linux build isolation, remote registry readiness, publisher
authorization, release signing/provenance, or independent security review.
