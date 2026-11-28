# The elisapkg home

Everything elisapkg keeps for a user lives in one directory, the elisapkg
home: `$ELISAPKG_HOME` when it is set, otherwise `$HOME/.elisapkg`.
`ELISAPKG_HOME` must be an absolute path without `.` or `..` components.
Project files stay in each project's own `.elisapkg/` directory and are not
part of the home.

| Path | Contents |
| --- | --- |
| `bin/` | Binaries installed by `install --local`. Add it to your `PATH` to run them by name. |
| `receipts/` | One installation receipt per binary in `bin/`, which `uninstall --local` checks before removing anything. |
| `lang/elisac/NAME/` | One registered Elisa toolchain. A linked checkout has a single `toolchain` record file. |
| `lang/settings.json` | Language settings. `default-toolchain` names the toolchain builds use. |
| `lang/packages/` | Reserved for Elisa libraries. |
| `agent/` | The Elisa agent's home, managed by its own `elisa-agent` command: `store/` holds shared content-addressed objects and `agents/NAME/` holds each agent's lock and its spawned instances. |
| `trust/` | Registry rollback state, one `<sha256-of-registry-root>.state` file per registry. |

```sh
export PATH="$HOME/.elisapkg/bin:$PATH"
```

## Trust

elisapkg creates the home and every directory below it that it needs with mode
`0700`. Before it reads or writes a file there, every directory from `/` down
must be owned by root or the current user and must not be writable by anyone
else, and no component may be a symlink. Otherwise the command fails closed
with a security error.

## Overrides

- `ELISAPKG_INSTALL_PREFIX` installs into another prefix. Binaries then go to
  `PREFIX/bin` and receipts to `PREFIX/share/elisapkg/receipts`, so a shared
  prefix such as `/usr/local` keeps elisapkg's own files below `share/`.
- `ELISAPKG_TRUST_STATE` names one trust-state file to use in place of `trust/`.
- `ELISAPKG_COMPILER` selects a compiler without using `lang/elisac`; see
  [toolchains](toolchains.md).

## Moving from older releases

Releases before the elisapkg home kept registry trust state in
`$HOME/.local/share/elisapkg/trust`. When `ELISAPKG_HOME` is unset and
`$HOME/.elisapkg/trust` does not exist yet, the first command that uses trust
state moves that directory into the home with a single rename, so its files
keep their modes and no partial copy is ever visible. If the old directory is
untrusted or cannot be moved, the command fails closed rather than starting
with empty rollback state. Once `$HOME/.elisapkg/trust` exists it is used and
the old directory is left alone.

Binaries installed into `$HOME/.local/bin` by older releases stay there. Remove
them with their original prefix:

```sh
ELISAPKG_INSTALL_PREFIX="$HOME/.local" elisapkg uninstall --local app
```
