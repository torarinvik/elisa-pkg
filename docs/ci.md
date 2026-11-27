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
manifest and normalized tar archive. Bootstrap builds publish the executable
with mode `0755` regardless of the build umask. The job then uploads those files and the tested
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

## Verify a candidate

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

## Pinned toolchain

The workflow builds its toolchain from exact source revisions instead of
using whatever compiler happens to be installed on the runner:

| Input | Pinned identity |
| --- | --- |
| Elisa compiler | `a0fe756c11064d88d1f7f402ef9b1e38866d9f09` |
| Elisa core / stage0 | `ffb9ba3661e4aa734cd780089b8d5cc036379522` |
| Go | `1.25.0`, required by the pinned core `go.mod` |
| LLVM | `23.1.6`, checked after Homebrew installation |
| `actions/checkout` | `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` |
| `actions/setup-go` | `b7ad1dad31e06c5925ef5d2fc7ad053ef454303e` (v7.0.0) |
| `actions/upload-artifact` | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` (v7.0.1) |
| `actions/download-artifact` | `634f93cb2916e3fdff6788551b99b062d0335ce0` (v5.0.0) |
| `actions/attest` | `1e69f48acb82d1966a394da916b4c1698aa569d6` (v4.2.2) |

Each Stage0 and Stage1 rebuild runs through
`scripts/compiler_rebuild_timeout.py`, which terminates the rebuild process
group on cancellation and enforces a 30-second wall-clock
limit, kills the rebuild's entire process group at the deadline, and reports
elapsed wall time on success. The pinned core's `make build` clears its
environment and limits the Go build to five seconds, which a cold Go cache
cannot meet. The job therefore first compiles every Stage0 package without a
time limit, in the same cleared environment, so the timed Stage0 build measures
an incremental rebuild against the job's own Go cache rather than the cold
compile. Stage1 gets a new empty SMT proof cache, and the job disables the
retained analysis server so warm state cannot hide fresh-cache seed timing. A
timeout fails the workflow; profile and optimize the rebuild before retrying it
under the same limit.

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

## Strict Elisa lint

The macOS workflow checks the repository layout, FFI boundary, and rebuild
timeout supervisor before fetching or rebuilding the compiler. After seeding
Stage1 from the pinned sources, it runs `make lint`, so a strict never-leak
finding fails the workflow before the regression suite runs.

Run `make lint` to check the 600-line source limit and 20-file directory limit
before checking Elisa semantics. The layout check also runs independently with
`python3 scripts/check_source_layout.py`.

The semantic step, `scripts/build.sh --check`, needs a Stage1 toolchain that
supports `-Werror=never-leak=strict` and `-emit check`; the pinned compiler
does. It checks the full package-manager source graph without linking an
executable and treats every strict never-leak finding as an error. Use
`scripts/build.sh --strict` to produce `build/elisapkg-strict` with the same
diagnostics reported as warnings. The source tree checks clean under
`-Wnever-leak=strict`; keep new code warning-free.
