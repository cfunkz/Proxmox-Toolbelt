#!/usr/bin/env bash
# create-ct.sh: shortcut to the LXC container builder in proxmox-toolbelt.sh
#   ./create-ct.sh [--dry-run]   is the same as   ./proxmox-toolbelt.sh create-ct [--dry-run]
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
for t in "$here/proxmox-toolbelt.sh" "$(command -v proxmox-toolbelt 2>/dev/null)"; do
  [[ -n "$t" && -f "$t" ]] && exec bash "$t" create-ct "$@"
done
echo "create-ct.sh needs proxmox-toolbelt.sh next to it. Get it with:" >&2
echo "  wget -O proxmox-toolbelt.sh https://raw.githubusercontent.com/cfunkz/Proxmox-Toolbelt/main/proxmox-toolbelt.sh" >&2
exit 1
