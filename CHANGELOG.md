# Changelog

## 0.0.2

- SSH keys: keys read from files with Windows line endings (CRLF) or with
  `authorized_keys` options are cleaned before use. The key menu showed a garbled
  line, and the keys passed to `qm set --sshkeys` / `pct create --ssh-public-keys`
  could contain carriage returns.
- Key menu lists up to three key comments, separated by commas.
- Dry-run output quotes arguments only where needed (`'Created by ...'` instead of `Created\ by\ ...`).
- "1 core" instead of "1 cores"; subscription status `notfound` is shown as "none".
- Release workflow publishes the release again when a tag is re-pushed.
- Package maintainer address changed to the GitHub noreply address.

## 0.0.1

- First release: status board, guided fixes, VM, container and template builders, Debian package.
