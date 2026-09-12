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

`scripts/build.sh` invokes the compiler wrapper with the selected Elisa runtime
object and `ELISA_STAGE1_SEMANTIC_GATE=1` supplied by the package manager's
child build environment. Filesystem traversal, archive extraction, and process
policy are compiled from Elisa; only direct libc/POSIX primitives cross the
private FFI boundary. The errno accessor is selected at compile time for the
target (`__error` on Apple/FreeBSD and `__errno_location` on Linux), so a
Linux build does not depend on the Darwin symbol. The wrapper and stage1
executable must be explicitly present and executable.

## Capability matrix

| Capability | Current implementation | Evidence | Limitation |
| --- | --- | --- | --- |
| argv, stdout, stderr | Elisa wrappers | `scripts/test.sh` | Output streaming is intentionally small |
| regular file read/write | Elisa plus direct libc FFI | Elisa probe and regression suite | Same-UID mutation can still race the final inode check before unlink |
| no-follow source read | `openat`/`O_NOFOLLOW` through the private Elisa platform module | Elisa platform probe | Explicit `..` path dependencies remain user-owned inputs |
| sorted regular-file walk | bounded `opendir`/`readdir` traversal through the private Elisa platform module | package reproducibility tests | Extraction accepts regular files and creates only parent directories |
| atomic file replacement | `mkstemp` + file fsync + rename + parent-directory fsync | lockfile fixtures | Filesystem durability guarantees still depend on the host filesystem |
| exclusive publication | hard-link from fsynced temp | install lock regression and install fixtures | macOS/Linux advisory `flock` on a persistent prefix inode; existing legacy directory lock paths fail closed |
| compiler build isolation | macOS Seatbelt deny-default profile with network denial, unique scratch subtree for all compiler outputs, pre-created callback inode with data-write only, captured stdio | `scripts/sandbox_policy_test.py` probes the generated profile, confirms loopback reachability outside the sandbox, then verifies network denial and callback inode confinement; CI environments require enforcement automatically, or set `ELISAPKG_REQUIRE_SANDBOX_TESTS=1` explicitly | Local runs skip when the host denies Seatbelt application; hostile descendants can escape process groups; project, local dependency, and selected toolchain trees remain readable |
| process execution | argv array through `env -i`, private process groups, monotonic deadlines, and resource profiles | compiler environment fixture and native timeout seam | `run` and `test` execute artifacts as the invoking user, outside the build sandbox |
| native target artifacts | `bin`/`test` targets use `-emit exe`; `lib` targets use `-emit obj` through the same structured adapter | library-target fixture in `scripts/test.sh` | Dependency compile/link planning remains future adapter work |
| semantic checking | mandatory stage1 gate | invalid-source fixture | Supported toolchain must still be pinned for release |
| SHA-256 | in-language implementation | FIPS known-answer fixture | Digest is not publisher authentication |
| JSON grammar | bounded iterative validator | manifest and regression fixtures | No decoded value tree or source locations |
| deterministic graph solver | bounded in-memory backtracking module | solver fixture in `scripts/regression_test.py` | CLI still resolves local paths through its existing graph walker |
| TLS, registry transport | disabled | fail-closed command tests | Requires reviewed transport adapter |
| signed metadata | file-backed `primary` fixture provider | Ed25519, expiry, identity, archive, transitive graph, and persistent trust-state fixtures | Requires publisher authorization and protocol review before network use |
| archive extraction | bounded staged primitive | descriptor-relative no-follow ustar extraction with exclusive regular-file creation and directory fsync | Callers must provide a private empty staging directory |
| local publish preflight | `publish --dry-run` validates and hashes deterministic archive bytes in memory | human/JSON output and repeated-archive regression fixtures | Authenticated upload and publisher signatures remain disabled |

Unsupported hosts and missing capabilities must produce an actionable error;
they must not silently fall back to an unreviewed shell or network path.

Build isolation currently requires macOS and a working `sandbox-exec`. Linux
builds return the build error status before invoking a compiler. Other package
operations use the documented native FFI target matrix above.

The private POSIX FFI currently has explicit layouts for macOS arm64, Linux
x86_64, and Linux arm64. Other host layouts remain unsupported and must be
added as reviewed target-specific Elisa branches before those hosts are used.
