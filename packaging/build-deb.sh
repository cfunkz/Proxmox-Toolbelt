#!/usr/bin/env bash
# Builds proxmox-toolbelt_<version>_all.deb with dpkg-deb (no debhelper needed).
#   packaging/build-deb.sh [VERSION] [OUTDIR]
# VERSION defaults to VERSION= in proxmox-toolbelt.sh and must match it.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

MAINTAINER="cfunkz <cfunkz@pm.me>"
HOMEPAGE="https://github.com/cfunkz/Proxmox-Toolbelt"
PKG=proxmox-toolbelt

script_ver="$(awk -F'"' '/^VERSION=/{print $2; exit}' proxmox-toolbelt.sh)"
ver="${1:-$script_ver}"; ver="${ver#v}"
out="${2:-dist}"
[[ "$ver" == "$script_ver" ]] || { echo "Version $ver does not match VERSION=\"$script_ver\" in proxmox-toolbelt.sh" >&2; exit 1; }
[[ "$ver" =~ ^[0-9][A-Za-z0-9.+~-]*$ ]] || { echo "Invalid Debian version: $ver" >&2; exit 1; }

root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT
doc="$root/usr/share/doc/$PKG"
install -d "$root/DEBIAN" "$root/usr/sbin" "$doc" "$root/usr/share/$PKG"
install -m 755 proxmox-toolbelt.sh "$root/usr/sbin/$PKG"
install -m 644 README.md "$doc/README.md"
install -m 644 proxmox-toolbelt.conf.example "$root/usr/share/$PKG/proxmox-toolbelt.conf.example"

cat >"$doc/copyright" <<C
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: $PKG
Source: $HOMEPAGE

Files: *
Copyright: $(date -u +%Y) $MAINTAINER
License: see $HOMEPAGE
C
printf '%s (%s) stable; urgency=medium\n\n  * Release %s. See %s/releases\n\n -- %s  %s\n' \
  "$PKG" "$ver" "$ver" "$HOMEPAGE" "$MAINTAINER" "$(date -uR)" | gzip -9n >"$doc/changelog.Debian.gz"

cat >"$root/DEBIAN/control" <<C
Package: $PKG
Version: $ver
Architecture: all
Maintainer: $MAINTAINER
Installed-Size: $(du -sk "$root/usr" | cut -f1)
Depends: bash (>= 5), perl, curl, iproute2, pve-manager (>= 8.0)
Recommends: tmux
Section: admin
Priority: optional
Homepage: $HOMEPAGE
Description: Interactive system checks and VM/CT launcher for Proxmox VE
 Status board with read-only checks for a Proxmox VE 8/9 node (2FA, SSH,
 certificate, firewall, repositories, updates, storage, disks, backups,
 notifications), guided fixes that show a diff before applying, and
 builders for cloud-init VMs, LXC containers and VM templates.
 .
 Run: proxmox-toolbelt
C

# Removes only the defaults file on purge; image cache and backups stay (proxmox-toolbelt uninstall).
cat >"$root/DEBIAN/postrm" <<'C'
#!/bin/sh
set -e
if [ "$1" = purge ]; then
  rm -f /etc/proxmox-toolbelt.conf
fi
exit 0
C
chmod 755 "$root/DEBIAN/postrm"

mkdir -p "$out"
deb="$out/${PKG}_${ver}_all.deb"
dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
echo "$deb"
