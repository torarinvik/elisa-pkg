# Compiler and platform compatibility

The package manager is bootstrapped by an explicitly selected Elisa compiler.
It never guesses a sibling checkout, downloads a compiler, or treats object
emission as semantic validation.

## Current seed contract

The documented local seed invocation is:

```sh
ELISA_COMPILER_ROOT=/path/to/Elisa-compiler \
ELISA_STAGE1_BIN=/path/to/elisac-stage1 \
ELISA_ALLOW_STALE_STAGE1=1 \
scripts/build.sh
```

`scripts/build.sh` compiles the reviewed C filesystem seam with C11 warnings
as errors, combines it with the selected runtime object, and invokes the
compiler wrapper with `ELISA_STAGE1_SEMANTIC_GATE=1` supplied by the package
manager's child build environment. The wrapper and stage1 executable must be
explicitly present and executable.

## Capability matrix

| Capability | Current implementation | Evidence | Limitation |
| --- | --- | --- | --- |
| argv, stdout, stderr | Elisa wrappers | `scripts/test.sh` | Output streaming is intentionally small |
| regular file read/write | Elisa plus reviewed C seam | C analyzer and regression suite | Shared hostile directories need handle-based mutation |
| no-follow source read | `openat`/`O_NOFOLLOW` C seam | native regression fixture | Explicit `..` path dependencies remain user-owned inputs |
| sorted regular-file walk | `nftw(FTW_PHYS)` seam | package reproducibility tests | No extraction support yet |
| atomic file replacement | `mkstemp` + `fsync` + rename | lockfile fixtures | Directory fsync is platform-dependent |
| exclusive publication | hard-link from fsynced temp | install fixtures | Prefix lock is a mkdir lock, not a kernel lease |
| process execution | argv array through `env -i` | compiler environment fixture | No OS sandbox or process-tree cancellation; signalled child processes return 130 |
| semantic checking | mandatory stage1 gate | invalid-source fixture | Supported toolchain must still be pinned for release |
| SHA-256 | in-language implementation | FIPS known-answer fixture | Digest is not publisher authentication |
| JSON grammar | bounded iterative validator | manifest and regression fixtures | No decoded value tree or source locations |
| deterministic graph solver | bounded in-memory backtracking module | solver fixture in `scripts/regression_test.py` | CLI still resolves local paths through its existing graph walker |
| TLS, registry transport | disabled | fail-closed command tests | Requires reviewed transport adapter |
| signed metadata | disabled | fail-closed trust policy | Requires protocol/provider review and trust-state persistence |
| archive extraction | disabled | deterministic writer/verifier and package receipts | Safe staging primitives are still a milestone |

Unsupported hosts and missing capabilities must produce an actionable error;
they must not silently fall back to an unreviewed shell or network path.
