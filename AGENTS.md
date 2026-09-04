# Project instructions

## Verification

- `make test` is the authoritative suite. It runs `tests/run` under zsh.
- Tests use a temporary directory plus fake Homebrew and `displayplacer` commands; they must not change real displays, user profiles, or the network.

## Invariants

- Keep the command compatible with macOS `/bin/zsh`.
- Saved profiles omit physical display IDs so they can be applied to equivalent monitors with different IDs.
- Reject unsafe profile names and monitor-count mismatches before invoking `displayplacer`.
- Respect `SCREENSTAMP_PROFILE_DIR`; otherwise use `${XDG_CONFIG_HOME:-$HOME/.config}/screenstamp/profiles`.
- Installation defaults to `${HOME}/.local/bin` and must remain overridable through `PREFIX`, `BINDIR`, and the installer environment variables.
