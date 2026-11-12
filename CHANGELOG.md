# Changelog

## 0.0.3

- Scheduled snapshots and backups (menu 5.3 to 5.6, `proxmox-toolbelt schedule`):
  - Snapshot jobs (`qm`/`pct snapshot`) for ZFS, LVM-thin, Ceph RBD and qcow2 disks, and backup
    jobs (`vzdump`) for guests on any storage, including plain LVM.
  - Intervals such as 10m, 10h, 24h, 1d, 2w, 1mo, 1h30m, or a systemd calendar expression.
  - systemd timers with `Persistent=true`: runs missed while the node was off are made up after
    boot; interrupted runs run again after their stale guest locks are removed.
  - Per-job lock, retries, retention (keep-last, or Proxmox `keep-*` rules for backups), storage
    fill check (also LVM-thin metadata), log file, e-mail to root on failure.
  - Status board line for failed or overdue jobs; `uninstall` and `apt purge` remove the jobs.

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
