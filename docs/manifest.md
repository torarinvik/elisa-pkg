# `elisapkg.json` schema version 1

The package manifest is a UTF-8 JSON object. Its schema version is the integer `1`; writers emit canonical two-space JSON with LF line endings. The package manager rejects NUL bytes, missing required members, invalid package names, invalid SemVer versions, duplicate required keys, unsupported build scripts/plugins, and entries larger than 1 MiB.

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

Package names are 1–64 bytes, start with a lowercase ASCII letter, and contain lowercase ASCII letters, digits, and single interior hyphens. Versions use `major.minor.patch` with an optional prerelease suffix. Build metadata is not currently accepted as an identity field. Targets require unique package-style names, their kinds are limited to `bin`, `lib`, or `test`, and their entries must remain inside the package root. Entries reject absolute, parent, dot-prefixed, and backslash path forms; target-specific compiler flags are not inherited from dependencies. If present, `include` is a JSON array containing unescaped strings; the current archive writer accepts bounded `*` patterns, forces the manifest and lockfile into the release, and excludes VCS/state directories and credential-like files.

Dependency objects select exactly one source. A local dependency uses `{"path":"../sibling"}` and is checked as a bounded relative path resolved from the declaring manifest. Reachable local packages are traversed transitively; lexical `.`/`..` segments are normalized for the lockfile, and the canonical real path is checked before a target is accepted. A registry declaration uses `{"version":"^1.2.0","registry":"primary"}`; the current `SemVer` module accepts exact, caret, tilde, and single-comparator ranges and rejects malformed, overflowed, or leading-zero numeric identifiers. Duplicate aliases, mixed local/registry source fields, non-string registry values, and unsupported Git fields are rejected before resolution. Remote registry access remains disabled until the signed-metadata trust chain is implemented.

The current Elisa decoder uses a bounded structural validator while the schema grows. It requires valid UTF-8, tokenizes quoted keys (so text inside descriptions cannot spoof fields), rejects duplicate keys in every JSON object, checks root/package object ownership, permits arbitrary names only as direct dependency keys, and rejects unknown execution fields. It is still not a complete JSON value grammar or diagnostic decoder; before registry support, it must be replaced or supplemented with the full parser and diagnostics specified in the implementation roadmap.
