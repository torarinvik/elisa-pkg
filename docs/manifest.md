# `elisapkg.json` schema version 1

The package manifest is a UTF-8 JSON object. Its schema version is the integer
`1`; writers emit canonical two-space JSON with LF line endings. The package
manager rejects NUL bytes, escaped object-key spellings, missing required
members, invalid package names, invalid SemVer versions, duplicate required
keys, unsupported build scripts/plugins, and entries larger than 1 MiB.
Version strings accept the numeric major/minor/patch form with an optional
prerelease suffix and are limited to 128 UTF-8 bytes. SemVer build metadata
(`+...`) is outside the v1 version grammar because lock identities retain
precedence fields only.
The optional `package.elisa` field must use the stable requirement grammar
described below. It is currently syntax-checked only; builds do not compare it
with the selected compiler's version or capabilities.

The minimum package is:

```json
{
  "schema-version": 1,
  "package": {
    "name": "hello-app",
    "version": "0.1.0",
    "description": "A small Elisa program",
    "license": "MIT",
    "elisa": ">=0.1.0 <1.0.0"
  },
  "targets": [
    {"name": "hello-app", "kind": "bin", "entry": "src/main.elisa"}
  ],
  "dependencies": {},
  "dev-dependencies": {},
  "include": ["src/**", "elisapkg.json", "elisapkg.lock", "README.md", "LICENSE"]
}
```

Package names are 1–64 bytes, start with a lowercase ASCII letter, and contain lowercase ASCII letters, digits, and single interior hyphens. Versions use `major.minor.patch` with an optional prerelease suffix and are limited to 128 bytes. Build metadata is not currently accepted as an identity field. Targets require unique package-style names, their kinds are limited to `bin`, `lib`, or `test`, and their entries must be existing regular files below the package root. Entries reject absolute, parent, dot-prefixed, backslash, and symlink path forms; target-specific compiler flags are not inherited from dependencies. `build` selects the first target by default, or a named target with `--bin NAME`, `--lib NAME`, or `--test NAME`. Executable and test targets are emitted as `.elisapkg/build/NAME`; library targets are emitted as `.elisapkg/build/NAME.o` regular object files. `run --bin NAME` and local installation require an executable target, and `test --test NAME` selects a test target. If present, `include` and `exclude` are JSON arrays containing unescaped strings; the current archive writer accepts bounded glob patterns where `*` matches within one path component and consecutive `**` matches across path separators. An excluded path is omitted even when it also matches `include`; the manifest and lockfile remain required release entries, and VCS/state directories plus common credential stores and files (including `.ssh`, `.aws`, `.kube`, `.docker`, `.config/gcloud`, `.config/gh`, `.npmrc`, `.pypirc`, `.env*`, and private-key formats) are always excluded. Credential rules apply to every path component, including directory names; a package root named as a credential store or credential file is rejected.

Include/exclude evaluation shares a fixed budget of 16,777,216 work units and
65,536 dynamic-programming rows across one package walk. Exceeding either bound
fails packaging with an explicit error instead of silently omitting files.

Dependency objects select exactly one source. A local dependency uses `{"path":"../sibling"}` and is checked as a bounded relative path resolved from the declaring manifest. Reachable local packages are traversed transitively; lexical `.`/`..` segments are normalized for the lockfile, and the canonical real path is checked before a target is accepted. The configured `primary` registry source uses `{"registry":"primary","version":"^1.2.0"}` and is accepted only when the signed local registry provider can authenticate the complete graph. Registry-only graphs produce lockfile version 3 records with exact archive identities; mixed local/registry graphs and Git sources remain rejected until their source identity rules are implemented. The `SemVer` module accepts stable exact, caret, tilde, single-comparator, and paired lower/upper ranges up to 128 bytes and rejects malformed, overflowed, or leading-zero numeric identifiers. Duplicate aliases, mixed local/remote source fields, non-string values, and unsupported Git fields are rejected before resolution. The `dev-dependencies` object is reserved for root test/example graph activation and must currently be empty; non-empty declarations are rejected instead of being silently ignored. Network transport remains disabled; configuring a URL never bypasses signature checks.

Builds currently compile only a fully validated version 2 local-path graph.
Every transitive dependency must declare exactly one `lib` target; that target
is included before its dependents in a deterministic dependency-first aggregate
source. The build receipt binds the ordered logical dependency target paths
along with the lock and source digests. The compiler receives a separate
aggregate of validated absolute includes into the verified snapshots, created
in private compiler scratch and checked unchanged before publication. Local dependency
manifests, target entries, and source-tree digests are revalidated from the
canonical lock identities. Registry-only builds fail closed until authenticated
package acquisition and dependency compilation are integrated; mixed graphs
remain unsupported. Fixture: `scripts/local_dependency_build_regression.py`.

The current Elisa decoder validates value grammar with a bounded iterative stack (64 containers), including separators, literals, number syntax, and every JSON string escape form. It requires valid UTF-8, tokenizes quoted keys (so text inside descriptions cannot spoof fields), rejects duplicate keys in every JSON object, checks root/package object ownership, permits arbitrary names only as direct dependency keys, and rejects unknown execution fields. Required manifest field lookup remains byte-exact, so those fields must use their documented spelling rather than escaped key equivalents. It does not yet provide a decoded value tree or location diagnostics; a future parser layer can add those usability features without weakening this bounded validation pass.

Prerelease package versions may use dotted identifiers. Dependency requirements containing prereleases are rejected until the requirement model preserves their complete identity; stable ranges exclude prerelease candidates.
