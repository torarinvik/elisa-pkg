# Continuous integration

`.github/workflows/macos-ci.yml` is the required supported-host CI workflow. Its
`test` job runs the complete `scripts/test.sh` suite on an Apple Silicon macOS
15 runner and sets `ELISAPKG_REQUIRE_SANDBOX_TESTS=1`, so unavailable Seatbelt
application or a failed network-denial/callback probe fails the job rather than
silently skipping those checks. The test job has read-only repository
permissions, checks out without persistent credentials, and has no package
publishing or signing credentials.

Repository rules must require the `Seeded toolchain and required sandbox
tests` check before merging to `main`, restrict who can update `main`, and
limit bypasses. The workflow cannot inspect or enforce those settings. Until
the rules are enabled in repository settings, this job reports failures but
does not prevent a merge. The attestation job runs after a successful test job
on a push to `refs/heads/main`; it does not run on pull requests.

For qualifying main-branch pushes, the test job creates a build candidate
manifest and normalized tar archive, then uploads those files and the tested
executable as a 90-day Actions artifact. A separate Ubuntu job downloads and
validates the candidate. It does not check out the repository or execute the
candidate binary. Only this job receives `id-token: write` and
`attestations: write`; pull-request code runs only in the read-only test job.
GitHub's `actions/attest` action creates a provenance attestation for the
executable, manifest, archive, and checksum file. The candidate is not a
published release asset.

The machine-readable manifest binds the source repository, commit, main-branch
workflow and run attempt, compiler and core commits, Go and LLVM versions,
toolchain executable digests, runner identity, and executable digest. The
attestation job checks those identities against the active workflow run and
validates the archive, including its full gzip checksum trailer, normalized
tar members, executable bytes, and sidecar checksum.

To verify a downloaded candidate online, use GitHub CLI with the repository
that created the attestation. Run this for each of the four subject files:

```sh
gh attestation verify elisapkg -R OWNER/REPOSITORY \
  --signer-workflow OWNER/REPOSITORY/.github/workflows/macos-ci.yml \
  --source-ref refs/heads/main
gh attestation verify elisapkg.provenance.json -R OWNER/REPOSITORY \
  --signer-workflow OWNER/REPOSITORY/.github/workflows/macos-ci.yml \
  --source-ref refs/heads/main
gh attestation verify elisapkg-macos-arm64.tar.gz -R OWNER/REPOSITORY \
  --signer-workflow OWNER/REPOSITORY/.github/workflows/macos-ci.yml \
  --source-ref refs/heads/main
gh attestation verify elisapkg-macos-arm64.tar.gz.sha256 -R OWNER/REPOSITORY \
  --signer-workflow OWNER/REPOSITORY/.github/workflows/macos-ci.yml \
  --source-ref refs/heads/main
```

The checksum file is itself attested; verify the archive's digest against it as
an additional check. GitHub CLI verification validates the GitHub attestation,
expected workflow identity, and main-branch source ref. It does not establish that the compiler is
trustworthy, make the build byte-reproducible, authorize an Elisa package
publisher, or provide a signature format that the current `elisapkg` client
understands. The client does not yet consume or verify these attestations.
Artifact Attestations are available for public repositories on current GitHub
plans; private or internal repositories require GitHub Enterprise Cloud. An
unsupported repository plan makes the attestation job fail closed.

The workflow builds its toolchain from exact source revisions instead of
using whatever compiler happens to be installed on the runner:

| Input | Pinned identity |
| --- | --- |
| Elisa compiler | `7b1b33e193e5092ffac12c77109ff33ee59c4df7` |
| Elisa core / stage0 | `e33dbd60f8c3fb0316114917265e4113d686495b` |
| Go | `1.25.0`, required by the pinned core `go.mod` |
| LLVM | `23.1.1`, checked after Homebrew installation |
| `actions/checkout` | `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` |
| `actions/setup-go` | `b7ad1dad31e06c5925ef5d2fc7ad053ef454303e0` |
| `actions/upload-artifact` | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` (v7.0.1) |
| `actions/download-artifact` | `634f93cb2916e3fdff6788551b99b062d0335ce0` (v5.0.0) |
| `actions/attest` | `1e69f48acb82d1966a394da916b4c1698aa569d6` (v4.2.2) |

To update a pin, review the upstream source and compatibility notes, update the
workflow and this table together, then run the clean seed/build/test sequence
on the supported host. An LLVM formula change intentionally fails the version
check until the new compiler/runtime combination has been validated. Go module
dependency changes are constrained by the pinned core `go.sum` and
`GOFLAGS=-mod=readonly`.

This is an initial attested CI candidate, not a production client release. A
release still needs consumer-side verification, a supported distribution and
recovery process, independent provenance review, publisher authorization, and
the signed TUF metadata chain. This workflow also cannot prove that repository
branch rules or organization-level Actions settings are correctly configured.

GitHub references: [artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations) and [the `actions/attest` action](https://github.com/actions/attest).
