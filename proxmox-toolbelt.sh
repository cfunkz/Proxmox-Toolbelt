#!/usr/bin/env bash
# proxmox-toolbelt.sh: health checks, configuration changes, a cloud-init VM builder
# and an LXC container builder for Proxmox VE 8 and 9.
#
# Checks are read-only (2FA, SSH, certificate, firewall, repositories, updates,
# storage, disks, backups, notifications, system). Changes print a diff or the
# commands and require confirmation. --dry-run applies nothing.
#
# Usage: proxmox-toolbelt.sh [--dry-run]            menu
#        proxmox-toolbelt.sh check [--json] [--details]
#        proxmox-toolbelt.sh create-vm [--dry-run]  (create-vm.sh does the same)
#        proxmox-toolbelt.sh create-ct [--dry-run]  (create-ct.sh does the same)
set -Eeuo pipefail
umask 077

VERSION="0.0.3"

# ---------------------------------------------------------------------------
# Defaults (override in /etc/proxmox-toolbelt.conf, see proxmox-toolbelt.conf.example)
# ---------------------------------------------------------------------------
DEF_DISTRO="ubuntu-24.04"
DEF_STORAGE=""            # blank = local-lvm if present, else first image storage
DEF_BRIDGE=""             # blank = bridge holding the host's default route
DEF_DISK="32G"
DEF_MEM="2048"
DEF_CORES="2"
DEF_CPU="host"            # Rocky/Alma 10 need x86-64-v3 or host
DEF_BIOS="ovmf"
DEF_FW="1"                # Proxmox firewall flag on the NIC (no effect unless enabled in the datacenter)
DEF_SSHKEYS="/root/.ssh/authorized_keys"
DEF_DNS=""                # blank = gateway of the first static NIC
DEF_SEARCHDOMAIN=""       # blank = search domain from the host's resolv.conf
DEF_ONBOOT="1"
DEF_UPGRADE="1"           # upgrade packages on first boot
DEF_TEMPLATE_ID="9000"    # first VMID tried by the template builder
DEF_CT_TEMPLATE="debian-13-standard"   # container builder: template name without version
DEF_CT_STORAGE=""         # blank = DEF_STORAGE / local-lvm if present, else first rootdir storage
DEF_CT_DISK="8"           # GiB
DEF_CT_MEM="1024"
DEF_CT_SWAP="512"
DEF_CT_CORES="1"
SNIPPET_STORAGE=""        # blank = first storage with "snippets" content
IMG_DIR="/var/lib/vz/template/cloudimg"
KEEP_ON_FAIL="0"          # 1 = keep a half-built VM instead of destroying it
BACKUP_ROOT="/root/proxmox-toolbelt-backups"

# Paths, overridable for tests
SYS_NET="${SYS_NET:-/sys/class/net}"
PVE_DIR="${PVE_DIR:-/etc/pve}"
APT_DIR="${APT_DIR:-/etc/apt}"
SSHD_DIR="${SSHD_DIR:-/etc/ssh}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
ROOT_KEYS="${ROOT_KEYS:-/root/.ssh/authorized_keys}"
CPUINFO="${CPUINFO:-/proc/cpuinfo}"
NODE="${NODE:-$(uname -n)}"; NODE="${NODE%%.*}"

CONF_FILE="${TOOLBELT_CONF:-/etc/proxmox-toolbelt.conf}"
# older versions read /etc/create-vm.conf
[[ -z "${TOOLBELT_CONF:-}" && ! -e "$CONF_FILE" && -e /etc/create-vm.conf ]] && CONF_FILE=/etc/create-vm.conf
DRY_RUN=0
SSH_DROPIN="01-proxmox-toolbelt.conf"
PKG_RE='^(pve-|proxmox-|libpve|qemu-server|lxc-pve|libproxmox|ceph|spiceterm|vncterm|novnc-pve|pve$)'

# Distro catalog: key|label|default user|image URL|checksum URL
#   checksum URL "@file" = per-image checksum file (<image URL>.CHECKSUM, single entry)
#   image URL "fedora"   = resolved to the newest Fedora Cloud release at runtime
CATALOG=(
  "ubuntu-26.04|Ubuntu 26.04 LTS (Resolute)|ubuntu|https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img|https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS"
  "ubuntu-24.04|Ubuntu 24.04 LTS (Noble)|ubuntu|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
  "ubuntu-22.04|Ubuntu 22.04 LTS (Jammy)|ubuntu|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
  "debian-13|Debian 13 (Trixie)|debian|https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2|https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
  "debian-12|Debian 12 (Bookworm)|debian|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
  "rocky-10|Rocky Linux 10|rocky|https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2|@file"
  "rocky-9|Rocky Linux 9|rocky|https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2|@file"
  "alma-10|AlmaLinux 10|almalinux|https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2|https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/CHECKSUM"
  "alma-9|AlmaLinux 9|almalinux|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/CHECKSUM"
  "fedora|Fedora Cloud (latest release)|fedora|fedora|"
  "custom|Custom image URL|cloud|custom|"
)

# ---------------------------------------------------------------------------
# Output and prompts
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then C_B=$'\e[1m' C_D=$'\e[2m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_C=$'\e[36m' C_0=$'\e[0m'
else C_B="" C_D="" C_G="" C_Y="" C_R="" C_C="" C_0=""; fi

die()  { echo "${C_R}ERROR:${C_0} $*" >&2; exit 1; }
warn() { echo "${C_Y}WARN:${C_0} $*" >&2; }
log()  { echo "${C_G}[+]${C_0} $*"; }
hint() { echo "  ${C_D}$*${C_0}"; }
hdr()  { echo; echo "${C_B}=== $* ===${C_0}"; }

# ask VAR "Question" "default" [validator]: re-asks until the validator accepts
ask() {
  local __var="$1" q="$2" def="${3:-}" check="${4:-}" a
  while true; do
    if [[ -n "$def" ]]; then read -erp "$q [$def]: " a || exit 130
    else read -erp "$q: " a || exit 130; fi
    a="${a:-$def}"
    a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
    if [[ -n "$check" ]]; then "$check" "$a" || continue
    elif [[ -z "$a" ]]; then continue; fi
    printf -v "$__var" '%s' "$a"
    return 0
  done
}

# ask_yn "Question" y|n: returns 0 for yes
ask_yn() {
  local q="$1" def="${2:-n}" a
  while true; do
    read -erp "$q [$([[ $def == y ]] && echo Y/n || echo y/N)]: " a || exit 130
    a="${a:-$def}"
    case "${a,,}" in y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

# confirm "Question": yes/no for a change to the system. Default is No, so Enter never applies.
confirm() { ask_yn "$1" n; }

# ask_secret VAR "Question": hidden input, asked twice
ask_secret() {
  local __var="$1" q="$2" a b
  while true; do
    read -rsp "$q: " a || exit 130; echo
    [[ -n "$a" ]] || continue
    read -rsp "Repeat: " b || exit 130; echo
    [[ "$a" == "$b" ]] && { printf -v "$__var" '%s' "$a"; return 0; }
    echo "  They do not match" >&2
  done
}

# menu VAR "Question" default "value|description"...: numbered list, pick by number or value.
# Set MENU_FREE=<validator> right before the call to also accept other typed values.
menu() {
  local __var="$1" q="$2" def="$3" free="${MENU_FREE:-}" a e v d
  MENU_FREE=""
  shift 3
  local vals=() w=8
  for e in "$@"; do v="${e%%|*}"; (( ${#v} > w )) && w=${#v}; done
  for e in "$@"; do
    v="${e%%|*}"; d=""; [[ "$e" == *"|"* ]] && d="${e#*|}"
    vals+=("$v")
    printf '  %s%2d) %-*s  %s%s\n' "$([[ $v == "$def" ]] && echo "*" || echo " ")" "${#vals[@]}" "$w" "$v" "${C_D}" "$d${C_0}"
  done
  [[ -n "$free" ]] && hint "or enter another value"
  while true; do
    read -erp "$q [$def]: " a || exit 130
    a="${a:-$def}"
    if [[ "$a" =~ ^[0-9]+$ ]] && (( 10#$a >= 1 && 10#$a <= ${#vals[@]} )); then
      printf -v "$__var" '%s' "${vals[10#$a-1]}"; return 0
    fi
    for v in "${vals[@]}"; do
      [[ "$a" == "$v" ]] && { printf -v "$__var" '%s' "$a"; return 0; }
    done
    if [[ -n "$free" && -n "$a" ]] && "$free" "$a"; then printf -v "$__var" '%s' "$a"; return 0; fi
    [[ -n "$free" ]] || echo "  Pick 1-${#vals[@]}" >&2
  done
}

# run CMD...: runs (or prints in dry-run); secrets after --cipassword/--password/--token are masked
run() {
  if (( DRY_RUN )); then
    local a hide=0
    printf '%s+%s' "$C_D" "$C_0" >&2
    for a in "$@"; do
      if (( hide )); then a="********"
      elif [[ ! "$a" =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then a="'${a//\'/\'\\\'\'}'"; fi
      [[ "$a" =~ ^--(cipassword|password|token|secret)$ ]] && hide=1 || hide=0
      printf ' %s' "$a" >&2
    done
    echo >&2
  else "$@" || die "Command failed: $1 ${2:-} ${3:-}"; fi
}

# ---------------------------------------------------------------------------
# IPv4 math (pure bash)
# ---------------------------------------------------------------------------
is_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
int2ip() { local n="$1"; echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"; }
mask_int() { local p="$1"; (( p == 0 )) && echo 0 || echo $(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )); }
net_int()   { echo $(( $(ip2int "$1") & $(mask_int "$2") )); }
bcast_int() { echo $(( $(net_int "$1" "$2") | (~$(mask_int "$2") & 0xFFFFFFFF) )); }
first_host() { local p="$2"; (( p >= 31 )) && int2ip "$(net_int "$1" "$p")" || int2ip $(( $(net_int "$1" "$p") + 1 )); }
last_host()  { local p="$2"; (( p >= 31 )) && int2ip "$(bcast_int "$1" "$p")" || int2ip $(( $(bcast_int "$1" "$p") - 1 )); }
in_subnet() { [[ "$(net_int "$1" "$3")" == "$(net_int "$2" "$3")" ]]; }   # in_subnet IP NETIP PREFIX
is_prefix() { [[ "$1" =~ ^[0-9]{1,2}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 32 )); }

# Gateway guess for IP/PREFIX: first usable host, or the last one when the VM itself is the first
predict_gateway() {
  local ip="$1" p="$2" g
  (( p >= 31 )) && return 0
  g="$(first_host "$ip" "$p")"
  [[ "$g" == "$ip" ]] && g="$(last_host "$ip" "$p")"
  echo "$g"
}

# Address usable for a host? (not network/broadcast on /1-/30)
is_host_addr() {
  local ip="$1" p="$2" n
  (( p >= 31 )) && return 0
  n="$(ip2int "$ip")"
  (( n != $(net_int "$ip" "$p") && n != $(bcast_int "$ip" "$p") ))
}

# ---------------------------------------------------------------------------
# Host discovery
# ---------------------------------------------------------------------------
list_bridges() {
  local d b
  {
    for d in "$SYS_NET"/*/bridge; do
      [[ -d "$d" ]] || continue
      b="${d%/bridge}"; b="${b##*/}"
      [[ "$b" =~ ^(fwbr|fwpr|fwln|vmbr[0-9]+v[0-9]+$) ]] && continue
      echo "$b"
    done
    if command -v ovs-vsctl >/dev/null 2>&1; then ovs-vsctl list-br 2>/dev/null || true; fi
  } | sort -uV
}

iface_ipv4() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}'; }
default_route() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++){if($i=="via")g=$(i+1);if($i=="dev")d=$(i+1)}; print d"|"g; exit}'; }
vlan_aware() { [[ "$(cat "$SYS_NET/$1/bridge/vlan_filtering" 2>/dev/null)" == 1 ]]; }

# Comment Proxmox stores in /etc/network/interfaces for an interface (shown in the GUI)
iface_comment() {
  awk -v want="$1" '
    $1=="iface" { cur=$2; next }
    $1=="auto" || $1=="allow-hotplug" || NF==0 { cur="" ; next }
    cur==want && /^#/ { sub(/^#+[ ]*/,""); print; exit }
  ' /etc/network/interfaces 2>/dev/null || true
}

# Every guest NIC in the cluster: kind|id|bridge|tag|ip/prefix|gw (ip may be dhcp/empty)
guest_addresses() {
  local files=()
  shopt -s nullglob
  files=("$PVE_DIR"/nodes/*/qemu-server/*.conf "$PVE_DIR"/nodes/*/lxc/*.conf)
  shopt -u nullglob
  (( ${#files[@]} )) || return 0
  awk '
    FNR==1 { stop=0; f=FILENAME; id=f; sub(/.*\//,"",id); sub(/\.conf$/,"",id)
             kind[f]=(f ~ /\/lxc\//) ? "ct" : "vm"; ids[f]=id }
    /^\[/ { stop=1 }
    stop { next }
    /^(net|ipconfig)[0-9]+: / {
      key=$1; sub(/:$/,"",key); idx=key; sub(/^[a-z]+/,"",idx)
      val=substr($0, length($1)+2); m=split(val, kv, ",")
      for (i=1; i<=m; i++) {
        eq=index(kv[i],"="); if (!eq) continue
        k=substr(kv[i],1,eq-1); v=substr(kv[i],eq+1)
        if (k=="bridge") BR[f,idx]=v; else if (k=="tag") TG[f,idx]=v
        else if (k=="ip") IP[f,idx]=v; else if (k=="gw") GW[f,idx]=v
      }
      SEEN[f,idx]=1
    }
    END { for (k in SEEN) { split(k,a,SUBSEP)
            print kind[a[1]] "|" ids[a[1]] "|" BR[k] "|" TG[k] "|" IP[k] "|" GW[k] } }
  ' "${files[@]}" 2>/dev/null || true
}

host_cores()  { nproc 2>/dev/null || echo 1; }
host_mem_mb() { awk -v k="${1:-MemTotal}:" '$1==k{print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 0; }
host_has_flags() { local f fl; fl=" $(awk -F: '/^flags/{print $2; exit}' "$CPUINFO" 2>/dev/null) "; for f in "$@"; do [[ "$fl" == *" $f "* ]] || return 1; done; }
host_resolvers() { awk '$1=="nameserver"{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | sed 's/ $//' || true; }
human_gib() { awk -v k="$1" 'BEGIN{ g=k/1048576; if (g>=1024) printf "%.1fT", g/1024; else printf "%.0fG", g }'; }
human_bytes() { awk -v b="${1:-0}" 'BEGIN{ split("B K M G T P",u," "); i=1; while (b>=1024 && i<6) { b/=1024; i++ } printf (b<10 && i>1 ? "%.1f%s" : "%.0f%s"), b, u[i] }'; }
host_search_domain() { awk '$1=="search"||$1=="domain"{print $2; exit}' /etc/resolv.conf 2>/dev/null || true; }
os_codename() { awk -F= '$1=="VERSION_CODENAME"{gsub(/"/,"",$2); print $2; exit}' "$OS_RELEASE" 2>/dev/null || true; }
is_cluster() { [[ -f "$PVE_DIR/corosync.conf" ]]; }
days_since() { echo $(( ( $(date +%s) - $1 ) / 86400 )); }
guest_conf() { local f; for f in "$PVE_DIR"/nodes/*/qemu-server/"$1".conf "$PVE_DIR"/nodes/*/lxc/"$1".conf; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done; return 1; }

# ---------------------------------------------------------------------------
# Proxmox API access (JSON via pvesh, cached for one board refresh)
# ---------------------------------------------------------------------------
TK_CACHE=""
pj() {
  local key f
  if [[ -z "$TK_CACHE" ]]; then pvesh get "$@" --output-format json 2>/dev/null; return; fi
  key="$(printf '%s ' "$@" | md5sum | cut -c1-16)"; f="$TK_CACHE/$key"
  if [[ ! -s "$f" ]]; then
    local part="$f.$BASHPID"   # expanded here: redirections of external commands expand after the fork
    pvesh get "$@" --output-format json >"$part" 2>/dev/null || { rm -f "$part"; return 1; }
    mv -f "$part" "$f"
  fi
  cat "$f"
}

# jrows KEY...: JSON array (or object) on stdin -> one "|"-separated line per element
jrows() {
  perl -MJSON::PP -e '
    local $/; my $d = eval { JSON::PP->new->decode(scalar <STDIN>) }; exit 0 unless ref $d;
    $d = [$d] if ref $d eq "HASH";
    for my $r (@$d) {
      next unless ref $r eq "HASH";
      print join("|", map {
        my $v = $r->{$_};
        if (!defined $v) { "" }
        elsif (ref $v eq "ARRAY") { join(",", grep { !ref } @$v) }
        elsif (ref $v eq "HASH") { "" }
        elsif (ref $v) { $v ? 1 : 0 }
        else { (my $s = $v) =~ s/[|\r\n\t]+/ /g; $s }
      } @ARGV), "\n";
    }' "$@" 2>/dev/null || true
}

# Users with their 2FA: userid|enabled|types|locked|email|tokens(id:privsep:expire,...)
tfa_rows() {
  TK_U="$1" TK_T="$2" TK_D="$3" perl -MJSON::PP -e '
    my $j = JSON::PP->new;
    my ($u, $t, $d) = map { my $x = eval { $j->decode($ENV{$_} // "") }; ref $x eq "ARRAY" ? $x : [] } qw(TK_U TK_T TK_D);
    my %realm_tfa = map { (($_->{realm} // "") => ($_->{tfa} // "")) } grep { ref eq "HASH" } @$d;
    my (%kinds, %locked);
    for my $e (@$t) {
      my $id = $e->{userid} // next;
      for my $x (@{ $e->{entries} // [] }) {
        next if defined $x->{enable} && !$x->{enable};
        $kinds{$id}{ $x->{type} // "unknown" } = 1;
      }
      $locked{$id} = 1 if $e->{"totp-locked"} || ($e->{"tfa-locked-until"} // 0) > time;
    }
    for my $x (@$u) {
      my $id = $x->{userid} // next;
      my $en = (!defined $x->{enable} || $x->{enable}) ? 1 : 0;
      $en = 0 if ($x->{expire} // 0) && $x->{expire} < time;
      my ($realm) = $id =~ /\@([^@]+)$/;
      my %k = %{ $kinds{$id} // {} };
      if ($realm_tfa{$realm // ""} && ($x->{keys} // "") ne "") {
        my ($rt) = $realm_tfa{$realm} =~ /type=(\w+)/; $k{"realm-" . ($rt // "tfa")} = 1;
      }
      my @tok = map { ($_->{tokenid} // "?") . ":" . ((!defined $_->{privsep} || $_->{privsep}) ? 1 : 0) . ":" . ($_->{expire} // 0) } @{ $x->{tokens} // [] };
      (my $mail = $x->{email} // "") =~ s/[|\s]//g;
      print join("|", $id, $en, join(",", sort keys %k), $locked{$id} ? 1 : 0, $mail, join(",", @tok)), "\n";
    }' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# apt sources (one-line .list and deb822 .sources)
# ---------------------------------------------------------------------------
# apt_entries [DIR]: file|enabled|types|uri|suite|components for every entry
apt_entries() {
  local dir="${1:-$APT_DIR}" f
  for f in "$dir/sources.list" "$dir"/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    awk -v f="$f" '
      { line=$0; en=1
        if (line ~ /^[[:space:]]*#/) { en=0; sub(/^[[:space:]]*#+[[:space:]]*/, "", line) }
        n=split(line, a, /[[:space:]]+/); s=1; if (a[1]=="") s=2
        if (a[s]!="deb" && a[s]!="deb-src") next
        u=s+1; if (a[u] ~ /^\[/) { while (u<=n && a[u] !~ /\]$/) u++; u++ }
        comp=""; for (j=u+2; j<=n; j++) if (a[j]!="") comp=comp (comp=="" ? "" : " ") a[j]
        print f "|" en "|" a[s] "|" a[u] "|" a[u+1] "|" comp }' "$f"
  done
  for f in "$dir"/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    awk -v f="$f" '
      function flush(   nu, ns, a, b, U, S, en) {
        if (uris != "") {
          en = (tolower(enabled) ~ /^(no|false|0)$/) ? 0 : 1
          nu = split(uris, U, /[[:space:]]+/); ns = split(suites, S, /[[:space:]]+/)
          for (a = 1; a <= nu; a++) for (b = 1; b <= ns; b++) if (U[a] != "" && S[b] != "") print f "|" en "|" types "|" U[a] "|" S[b] "|" comps
        }
        uris = suites = comps = types = ""; enabled = "yes"
      }
      BEGIN { enabled = "yes" }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { flush(); next }
      /^[[:space:]]/ { next }
      { k = tolower($1); sub(/:$/, "", k); v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
        if (k == "uris") uris = v; else if (k == "suites") suites = v; else if (k == "components") comps = v
        else if (k == "types") types = v; else if (k == "enabled") enabled = v }
      END { flush() }' "$f"
  done
}

# repo_kind URI COMPONENTS: pve-ent pve-nosub pve-test ceph-ent ceph-nosub ceph-test debian other
repo_kind() {
  local u="$1" c=" $2 "
  case "$u" in
    *proxmox.com/debian/ceph-*)
      if [[ "$u" == *enterprise.proxmox.com* ]]; then echo ceph-ent
      elif [[ "$c" == *" no-subscription "* ]]; then echo ceph-nosub
      else echo ceph-test; fi ;;
    *enterprise.proxmox.com/debian/pve*) echo pve-ent ;;
    *proxmox.com/debian/pve*)
      if [[ "$c" == *" pve-no-subscription "* ]]; then echo pve-nosub
      elif [[ "$c" == *" pvetest "* || "$c" == *" pve-test "* ]]; then echo pve-test
      else echo other; fi ;;
    *debian.org/debian*|*security.debian.org*) echo debian ;;
    *) echo other ;;
  esac
}

ceph_release_of() { local u="$1"; u="${u##*/debian/ceph-}"; echo "${u%%/*}"; }
installed_ceph() { ceph --version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\(stable|^\(dev/) {print $(i-1); exit}}'; }

subscription_status() {
  local s; s="$(pvesubscription get 2>/dev/null | awk -F': *' '$1=="status"{print $2; exit}')"
  case "$s" in notfound) echo "none (no subscription key)" ;; "") echo unknown ;; *) echo "$s" ;; esac
}

# ---------------------------------------------------------------------------
# Checks. Each prints STATUS|LABEL|MESSAGE|FIX lines (STATUS: OK WARN FAIL INFO,
# or "-" for a detail line shown only in the full report).
# ---------------------------------------------------------------------------
res()    { local m="${3//|//}"; printf '%s|%s|%s|%s\n' "$1" "$2" "$m" "${4:-}"; }
detail() { local m="${2//|//}"; printf -- '-|%s|%s|\n' "$1" "$m"; }

chk_tfa() {
  local users tfa doms rows id en types locked mail toks total=0 without=() root_ok=1 locked_list=()
  users="$(pj /access/users --full 1)" || { res INFO "2FA" "pvesh get /access/users failed"; return; }
  tfa="$(pj /access/tfa)" || tfa="[]"
  doms="$(pj /access/domains)" || doms="[]"
  rows="$(tfa_rows "$users" "$tfa" "$doms")"
  local t tid priv exp full_tok=()
  while IFS='|' read -r id en types locked mail toks; do
    [[ -n "$id" ]] || continue
    for t in ${toks//,/ }; do
      IFS=: read -r tid priv exp <<<"$t"
      [[ "$priv" == 0 ]] && full_tok+=("$id!$tid")
      detail "API token" "$id!$tid privsep=$priv expire=$([[ $exp == 0 ]] && echo never || date -d "@$exp" +%F 2>/dev/null)"
    done
    (( en )) || { detail "2FA" "$id: disabled or expired user"; continue; }
    total=$(( total + 1 ))
    [[ "$locked" == 1 ]] && locked_list+=("$id")
    local real="${types//recovery/}"; real="${real//,/}"
    if [[ -z "$real" ]]; then
      without+=("$id"); [[ "$id" == root@pam ]] && root_ok=0
      detail "2FA" "$id: none${types:+ (recovery keys only)}"
    else
      detail "2FA" "$id: ${types//,/, }$([[ ",$types," == *,recovery,* ]] || echo "  (no recovery keys)")"
    fi
  done <<<"$rows"
  if (( total == 0 )); then res INFO "2FA" "no enabled users found"
  elif (( ! root_ok )); then res FAIL "2FA" "not set up for root@pam (${#without[@]} of $total users without 2FA)" 2.1
  elif (( ${#without[@]} )); then res WARN "2FA" "not set up for ${without[*]}" 2.1
  else res OK "2FA" "set up for all $total users"; fi
  (( ${#locked_list[@]} )) && res WARN "2FA lockout" "locked after failed attempts: ${locked_list[*]}" 2.1
  (( ${#full_tok[@]} )) && res WARN "API tokens" "full user rights (no privilege separation): ${full_tok[*]}" 2.1
  return 0
}

ssh_key_info() { # authorized_keys file -> "bits type" per valid key
  [[ -r "$1" ]] || return 0
  ssh-keygen -l -f "$1" 2>/dev/null | awk '{t=$NF; gsub(/[()]/,"",t); print $1, t}'
}

chk_ssh() {
  local conf; conf="$(sshd -T 2>/dev/null)" || { res WARN "SSH" "sshd -T failed"; return; }
  sv() { awk -v k="$1" '$1==k{print $2; exit}' <<<"$conf"; }
  local prl pa kbd pam pk port pw=0
  prl="$(sv permitrootlogin)" pa="$(sv passwordauthentication)" pk="$(sv pubkeyauthentication)" pam="$(sv usepam)" port="$(sv port)"
  kbd="$(sv kbdinteractiveauthentication)"; [[ -n "$kbd" ]] || kbd="$(sv challengeresponseauthentication)"
  [[ "$pa" == yes || ( "$kbd" == yes && "$pam" == yes ) ]] && pw=1
  detail "SSH" "port ${port:-22}, PermitRootLogin $prl, PasswordAuthentication $pa, KbdInteractive $kbd, Pubkey $pk"
  case "$prl" in
    no) if is_cluster; then res FAIL "SSH root login" "disabled, but cluster nodes need root SSH (use prohibit-password)" 2.2
        else res OK "SSH root login" "disabled"; fi ;;
    yes) if (( pw )); then res WARN "SSH root login" "password allowed (key-only recommended)" 2.2
         else res OK "SSH root login" "yes, password authentication disabled"; fi ;;
    prohibit-password|without-password) res OK "SSH root login" "keys only" ;;
    forced-commands-only) res OK "SSH root login" "forced commands only" ;;
    *) res INFO "SSH root login" "PermitRootLogin ${prl:-unknown}" ;;
  esac
  if (( pw )); then res WARN "SSH passwords" "enabled for all users" 2.2
  else res OK "SSH passwords" "disabled"; fi
  [[ "$pk" == no ]] && res FAIL "SSH pubkeys" "PubkeyAuthentication no" 2.2

  local keys n=0 weak=() bits type
  keys="$(ssh_key_info "$ROOT_KEYS")"
  while read -r bits type; do
    [[ -n "$bits" ]] || continue
    n=$(( n + 1 ))
    if [[ "$type" == DSA ]] || [[ "$type" == RSA && "$bits" -lt 2048 ]]; then weak+=("$type-$bits"); fi
  done <<<"$keys"
  if (( n == 0 )); then res WARN "SSH keys" "no valid key in $ROOT_KEYS" 2.3
  elif (( ${#weak[@]} )); then res WARN "SSH keys" "$n keys, weak: ${weak[*]}" 2.3
  else res OK "SSH keys" "$n valid key$( (( n > 1 )) && echo s) in root's authorized_keys"; fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then detail "SSH" "fail2ban is running"
  else detail "SSH" "fail2ban is not running (brute-force protection)"; fi
  return 0
}

chk_cert() {
  local f="$PVE_DIR/local/pveproxy-ssl.pem" kind="custom" end days issuer acme="" names
  [[ -s "$f" ]] || { f="$PVE_DIR/local/pve-ssl.pem"; kind="self-signed"; }
  [[ -s "$f" ]] || { res WARN "Certificate" "no certificate found in $PVE_DIR/local"; return; }
  end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)"
  [[ -n "$end" ]] || { res WARN "Certificate" "cannot read $f"; return; }
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  issuer="$(openssl x509 -in "$f" -noout -issuer -nameopt multiline 2>/dev/null | awk -F'= ' '/commonName|organizationName/{print $2; exit}')"
  names="$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g; s/IPAddress://g')"
  pvenode config get 2>/dev/null | grep -E '^acme(domain[0-9]+)?:' >/dev/null && acme=1
  if [[ "$kind" == custom ]]; then
    if [[ -n "$acme" ]]; then kind="ACME (${issuer:-unknown issuer})"; else kind="custom (${issuer:-unknown issuer})"; fi
  fi
  detail "Certificate" "$f, issuer ${issuer:-?}, names ${names:-?}, valid until $end"
  if (( days < 0 )); then res FAIL "Certificate" "$kind, expired $(( -days )) days ago" 2.4
  elif (( days < 14 )); then res FAIL "Certificate" "$kind, expires in $days days" 2.4
  elif (( days < 30 )); then res WARN "Certificate" "$kind, expires in $days days" 2.4
  elif [[ "$kind" == self-signed ]]; then res WARN "Certificate" "self-signed, expires in $days days, no ACME" 2.4
  else res OK "Certificate" "$kind, expires in $days days"; fi
  return 0
}

fw_enabled() { # FILE: prints 1/0/"" from [OPTIONS] enable
  awk 'BEGIN{IGNORECASE=1} /^\[/{opt=($0 ~ /^\[OPTIONS\]/)} opt && $1=="enable:"{print $2; exit}' "$1" 2>/dev/null || true
}

chk_firewall() {
  local dc node_fw f id off=() line
  dc="$(fw_enabled "$PVE_DIR/firewall/cluster.fw")"
  node_fw="$(fw_enabled "$PVE_DIR/nodes/$NODE/host.fw")"
  if [[ "$dc" != 1 ]]; then res WARN "Firewall" "datacenter firewall disabled" 2.5
  elif [[ "$node_fw" == 0 ]]; then res WARN "Firewall" "enabled for the datacenter, disabled on node $NODE" 2.5
  else
    local pol; pol="$(awk '/^\[OPTIONS\]/{o=1;next} /^\[/{o=0} o && $1=="policy_in:"{print $2}' "$PVE_DIR/firewall/cluster.fw" 2>/dev/null)"
    res OK "Firewall" "enabled, input policy ${pol:-DROP}"
  fi
  shopt -s nullglob
  for f in "$PVE_DIR"/nodes/*/qemu-server/*.conf "$PVE_DIR"/nodes/*/lxc/*.conf; do
    line="$(awk '/^\[/{exit} /^net[0-9]+:.*firewall=1/{print; exit}' "$f")"
    [[ -n "$line" ]] || continue
    id="${f##*/}"; id="${id%.conf}"
    [[ "$(fw_enabled "$PVE_DIR/firewall/$id.fw")" == 1 ]] || off+=("$id")
  done
  shopt -u nullglob
  if (( ${#off[@]} )); then
    [[ "$dc" == 1 ]] && res INFO "VM/CT firewall" "firewall=1 on a NIC, VM/CT firewall disabled: ${off[*]:0:8}" 2.5
    detail "Firewall" "guests with NIC firewall=1 but firewall option off: ${off[*]}"
  fi
  return 0
}

chk_repos() {
  local entries f en types uri suite comps kind code sub
  local pve_ent=0 pve_nosub=0 pve_test=0 ceph_ent=0 ceph_other=0 ceph_rel="" mism=() dups=()
  code="$(os_codename)"; sub="$(subscription_status)"
  entries="$(apt_entries)"
  local -A seen=()
  while IFS='|' read -r f en types uri suite comps; do
    [[ -n "$f" && "$en" == 1 && " $types " == *" deb "* ]] || continue
    kind="$(repo_kind "$uri" "$comps")"
    detail "Repository" "${f##*/}: $uri $suite $comps"
    case "$kind" in
      pve-ent) pve_ent=1 ;; pve-nosub) pve_nosub=1 ;; pve-test) pve_test=1 ;;
      ceph-ent) ceph_ent=1; ceph_rel="$(ceph_release_of "$uri")" ;;
      ceph-nosub|ceph-test) ceph_other=1; ceph_rel="$(ceph_release_of "$uri")" ;;
    esac
    if [[ "$kind" != other && -n "$code" ]]; then
      local base="${suite%%-*}"; base="${base%%/*}"
      [[ "$base" == "$code" ]] || mism+=("${f##*/}: $suite")
    fi
    local k="$uri $suite $comps"
    [[ -n "${seen[$k]:-}" ]] && dups+=("${f##*/} and ${seen[$k]##*/}")
    seen[$k]="$f"
  done <<<"$entries"

  if (( pve_ent )) && [[ "$sub" != active ]]; then
    res FAIL "Repository" "enterprise enabled, no subscription (apt update fails with 401)" 3.1
  elif (( ! pve_ent && ! pve_nosub && ! pve_test )); then
    res FAIL "Repository" "no Proxmox VE repository enabled" 3.1
  elif (( pve_test && ! pve_ent && ! pve_nosub )); then
    res WARN "Repository" "only pve-test enabled" 3.1
  elif (( pve_ent )); then res OK "Repository" "enterprise (subscription $sub)"
  else res OK "Repository" "no-subscription$( (( pve_test )) && echo " + pve-test")"; fi

  local inst; inst="$(installed_ceph)"
  if (( ceph_ent )) && [[ "$sub" != active ]]; then
    res FAIL "Ceph repository" "ceph-$ceph_rel enterprise enabled, no subscription (apt 401)" 3.1
  elif [[ -n "$inst" && -n "$ceph_rel" && "$inst" != "$ceph_rel" ]]; then
    res WARN "Ceph repository" "repo is ceph-$ceph_rel but Ceph $inst is installed"
  elif [[ -n "$inst" ]] && (( ! ceph_ent && ! ceph_other )); then
    res WARN "Ceph repository" "Ceph $inst installed, no Ceph repository enabled" 3.1
  elif (( ceph_ent || ceph_other )); then
    detail "Ceph repository" "ceph-$ceph_rel $( (( ceph_ent )) && echo enterprise || echo no-subscription)${inst:+, Ceph $inst installed}"
  fi
  (( ${#mism[@]} )) && res FAIL "Repo suites" "not matching Debian $code: ${mism[*]}"
  (( ${#dups[@]} )) && res WARN "Repo duplicates" "same entry twice: ${dups[0]}"
  detail "Subscription" "$sub"
  return 0
}

newest_kernel() {
  local k
  for k in /boot/vmlinuz-*; do [[ -e "$k" ]] && echo "${k#/boot/vmlinuz-}"; done | sort -V | tail -1
}

chk_updates() {
  local stamp=0 t f age list n pm
  for f in /var/cache/apt/pkgcache.bin /var/lib/apt/periodic/update-success-stamp /var/lib/apt/lists/*InRelease; do
    [[ -e "$f" ]] || continue
    t="$(stat -c %Y "$f" 2>/dev/null || echo 0)"; (( t > stamp )) && stamp=$t
  done
  age=$(( stamp ? $(days_since "$stamp") : 999 ))
  list="$(apt list --upgradable 2>/dev/null | grep '/' || true)"
  n="$(grep -c . <<<"$list" || true)"
  pm="$(cut -d/ -f1 <<<"$list" | grep -cE "$PKG_RE" || true)"
  local when="last apt update today"
  (( age == 1 )) && when="last apt update yesterday"
  (( age > 1 )) && when="last apt update $age days ago"
  (( age == 999 )) && when="package lists never refreshed"
  if (( n > 0 )); then res WARN "Packages" "$n pending ($pm Proxmox), $when" 3.2
  elif (( age > 7 )); then res WARN "Packages" "no pending updates, but $when" 3.2
  else res OK "Packages" "up to date, $when"; fi
  while IFS= read -r f; do [[ -n "$f" ]] && detail "Packages" "$f"; done <<<"$(head -40 <<<"$list")"

  [[ -n "$(dpkg --audit 2>/dev/null)" ]] && res FAIL "dpkg" "unfinished package configuration (dpkg --audit)" 3.2
  local running newest pinned
  running="$(uname -r)"; newest="$(newest_kernel)"
  pinned="$(proxmox-boot-tool kernel list 2>/dev/null | awk '/^Pinned kernel/{getline; print $1; exit}')"
  if [[ -n "$pinned" && "$pinned" == "$running" ]]; then res OK "Kernel" "running pinned kernel $running"
  elif [[ -n "$newest" && "$newest" != "$running" ]]; then res WARN "Reboot" "running $running, newest installed $newest"
  else res OK "Kernel" "running the newest installed kernel ($running)"; fi
  return 0
}

microcode_pkg() {
  case "$(awk -F': ' '/^vendor_id/{print $2; exit}' "$CPUINFO" 2>/dev/null)" in
    GenuineIntel) echo intel-microcode ;; AuthenticAMD) echo amd64-microcode ;;
  esac
}

chk_microcode() {
  local pkg ver
  if grep -qw hypervisor "$CPUINFO" 2>/dev/null; then res INFO "Microcode" "virtualized host, not required"; return; fi
  pkg="$(microcode_pkg)"; [[ -n "$pkg" ]] || return 0
  ver="$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "$pkg" 2>/dev/null || true)"
  if [[ "$ver" == ii* ]]; then res OK "Microcode" "$pkg ${ver#*|}"
  else res WARN "Microcode" "$pkg not installed" 3.3; fi
}

chk_system() {
  local ip
  ip="$(getent ahostsv4 "$NODE" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -z "$ip" ]]; then res FAIL "/etc/hosts" "$NODE does not resolve; add it to /etc/hosts"
  elif [[ "$ip" == 127.* ]]; then res FAIL "/etc/hosts" "$NODE resolves to $ip (loopback); must be the node address"
  elif ! ip -4 -o addr show 2>/dev/null | grep " ${ip}/" >/dev/null; then res FAIL "/etc/hosts" "$NODE resolves to $ip, not a local address"
  else res OK "/etc/hosts" "$NODE -> $ip"; fi

  local sync off
  sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  off="$(chronyc -n tracking 2>/dev/null | awk -F': ' '/^System time/{split($2,a," "); printf "%.1f ms", a[1]*1000}')"
  if [[ "$sync" == yes ]]; then res OK "Time sync" "synchronized${off:+, offset $off}"
  else res WARN "Time sync" "NTP not synchronized"; fi

  local pct size
  read -r size pct < <(df -P / 2>/dev/null | awk 'NR==2{print $2, $5+0}')
  if [[ -n "${pct:-}" ]]; then
    if (( pct >= 90 )); then res FAIL "Root disk" "$pct% used of $(human_gib "$size")"
    elif (( pct >= 80 )); then res WARN "Root disk" "$pct% used of $(human_gib "$size")"
    else res OK "Root disk" "$pct% used of $(human_gib "$size")"; fi
  fi
  local tot avail
  tot="$(host_mem_mb)" avail="$(host_mem_mb MemAvailable)"
  if (( tot > 0 )); then
    if (( avail * 100 / tot < 10 )); then res WARN "Memory" "only $avail MB of $tot MB available"
    else res OK "Memory" "$(( (tot - avail) * 100 / tot ))% used of $(( tot / 1024 )) GiB"; fi
  fi

  if is_cluster; then
    local st q nodes
    st="$(pvecm status 2>/dev/null || true)"
    q="$(awk -F': *' '/^Quorate/{print $2; exit}' <<<"$st")"
    nodes="$(awk -F': *' '/^Nodes/{print $2; exit}' <<<"$st")"
    if [[ "$q" == Yes ]]; then res OK "Cluster" "quorate, ${nodes:-?} nodes"
    else res FAIL "Cluster" "NOT quorate (${nodes:-?} nodes visible)"; fi
  fi
  return 0
}

chk_storage() {
  local name type st total used avail pct n=0
  while read -r name type st total used avail pct; do
    [[ -n "$name" ]] || continue
    n=$(( n + 1 ))
    case "$st" in
      disabled) detail "Storage" "$name ($type) disabled"; continue ;;
      active) ;;
      *) res FAIL "$name" "$type storage is $st"; continue ;;
    esac
    pct=0; (( total > 0 )) && pct=$(( used * 100 / total ))
    local msg; msg="$pct% used of $(human_gib "$total") ($type)"
    if (( pct >= 90 )); then res FAIL "$name" "$msg" 4.1
    elif (( pct >= 80 )); then res WARN "$name" "$msg" 4.1
    else res OK "$name" "$msg"; fi
  done < <(pvesm status 2>/dev/null | awk 'NR>1')
  (( n )) || res WARN "Storage" "pvesm status returned nothing"

  local vg lv seg dp mp
  while IFS='|' read -r vg lv seg dp mp; do
    [[ "$seg" == thin-pool ]] || continue
    dp="${dp%%.*}"; mp="${mp%%.*}"
    detail "Thin pool" "$vg/$lv data ${dp:-?}%, metadata ${mp:-?}%"
    if (( ${mp:-0} >= 90 )); then res FAIL "Thin metadata" "$vg/$lv metadata ${mp}% full" 4.1
    elif (( ${mp:-0} >= 80 )); then res WARN "Thin metadata" "$vg/$lv metadata ${mp}% full" 4.1; fi
  done < <(lvs --noheadings --separator '|' -o vg_name,lv_name,segtype,data_percent,metadata_percent 2>/dev/null | tr -d ' ')

  local pool health cap scrub sdate sdays
  while read -r pool health cap; do
    [[ -n "$pool" ]] || continue
    cap="${cap%\%}"
    scrub="$(zpool status "$pool" 2>/dev/null | awk '/scan:/{sub(/.*scan: */,""); print; exit}')"
    sdays=""
    if [[ "$scrub" == *" on "* ]]; then sdate="${scrub##* on }"; sdays="$(days_since "$(date -d "$sdate" +%s 2>/dev/null || echo 0)")"; fi
    if [[ "$health" != ONLINE ]]; then res FAIL "ZFS $pool" "$health"
    elif (( cap >= 80 )); then res WARN "ZFS $pool" "$cap% full" 4.1
    elif [[ -z "$sdays" ]]; then res WARN "ZFS $pool" "online, $cap% full, never scrubbed"
    elif (( sdays > 40 )); then res WARN "ZFS $pool" "online, $cap% full, last scrub $sdays days ago"
    else res OK "ZFS $pool" "online, $cap% full, scrubbed $sdays days ago"; fi
  done < <(zpool list -H -o name,health,capacity 2>/dev/null)

  local snips; snips="$(pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}' | paste -sd, -)"
  if [[ -n "$snips" ]]; then res OK "Snippets" "enabled on $snips"
  else res WARN "Snippets" "not enabled on any storage (required by the VM builder)" 4.2; fi
  return 0
}

chk_disks() {
  local json dev size used model health wear type n=0 unused=() bad=() worn=()
  json="$(pj "/nodes/$NODE/disks/list")" || { res INFO "Disks" "could not list disks"; return; }
  while IFS='|' read -r dev size used model health wear type; do
    [[ -n "$dev" ]] || continue
    n=$(( n + 1 ))
    local h; h="$(human_bytes "$size")"
    detail "Disks" "$dev $h ${type:-?} ${model:-?}: ${used:-unused}, SMART ${health:-?}$([[ $wear =~ ^[0-9]+$ ]] && echo ", wear $(( 100 - wear ))%")"
    [[ -z "$used" ]] && unused+=("$dev $h ${model:-}")
    [[ "${health^^}" == FAILED ]] && bad+=("$dev")
    if [[ "$wear" =~ ^[0-9]+$ ]] && (( wear <= 20 )); then worn+=("$dev $(( 100 - wear ))% worn"); fi
  done < <(jrows devpath size used model health wearout type <<<"$json")
  if (( ${#bad[@]} )); then res FAIL "Disks" "SMART failed: ${bad[*]}" 4.3
  elif (( ${#worn[@]} )); then res WARN "Disks" "SSD wear: ${worn[*]}" 4.3
  elif (( n )); then res OK "Disks" "$n disks, SMART ok"; fi
  (( ${#unused[@]} )) && res INFO "Unused disks" "${#unused[@]} unused: ${unused[0]}$( (( ${#unused[@]} > 1 )) && echo ", ...")" 4.3

  local f id det=()
  shopt -s nullglob
  for f in "$PVE_DIR"/nodes/*/qemu-server/*.conf "$PVE_DIR"/nodes/*/lxc/*.conf; do
    id="${f##*/}"; id="${id%.conf}"
    while read -r u; do det+=("$id:${u%:}"); done < <(awk '/^\[/{exit} /^unused[0-9]+:/{print $1}' "$f")
  done
  shopt -u nullglob
  (( ${#det[@]} )) && res INFO "Detached disks" "${#det[@]} unused disk entries in guest configs: ${det[*]:0:5}" 4.4
  return 0
}

chk_backups() {
  local jobs njobs=0 nen=0 id en sched store all vmid
  jobs="$(pj /cluster/backup)" || { res INFO "Backups" "could not read backup jobs"; return; }
  while IFS='|' read -r id en sched store all vmid; do
    [[ -n "$id" ]] || continue
    njobs=$(( njobs + 1 )); [[ "$en" == 0 ]] || nen=$(( nen + 1 ))
    detail "Backup job" "$id: ${sched:-?} to ${store:-?}$([[ $all == 1 ]] && echo ", all guests" || echo ", guests ${vmid:-pool}")$([[ $en == 0 ]] && echo ", DISABLED")"
  done < <(jrows id enabled schedule storage all vmid <<<"$jobs")

  local guests total missing=() g name
  guests="$(pj /cluster/resources --type vm)" || guests="[]"
  total="$(jrows vmid template <<<"$guests" | awk -F'|' '$1!="" && $2!=1' | grep -c . || true)"
  while IFS='|' read -r g name; do [[ -n "$g" ]] && missing+=("$g${name:+ ($name)}"); done \
    < <(pj /cluster/backup-info/not-backed-up | jrows vmid name)
  if (( nen == 0 && total > 0 )); then res FAIL "Backups" "no enabled backup job for $total VMs/CTs" 5.1
  elif (( ${#missing[@]} )); then res WARN "Backups" "${#missing[@]} of $total VMs/CTs in no backup job" 5.1
  elif (( total > 0 )); then res OK "Backups" "$nen job$( (( nen > 1 )) && echo "s cover" || echo " covers") all $total VMs/CTs"
  else res INFO "Backups" "no VMs or containers yet"; fi
  (( ${#missing[@]} )) && detail "Backups" "not covered: ${missing[*]}"

  local tasks upid start status
  tasks="$(pj "/nodes/$NODE/tasks" --typefilter vzdump --limit 10)" || return 0
  IFS='|' read -r upid start status < <(jrows upid starttime status <<<"$tasks" | awk 'NR==1') || true
  if [[ -n "${upid:-}" ]]; then
    local d; d="$(days_since "$start")"
    if [[ "$status" != OK && "$status" != WARNINGS* ]]; then res FAIL "Last backup" "$(date -d "@$start" +%F) failed: $status" 5.2
    elif (( d > 8 )); then res WARN "Last backup" "$d days ago on this node ($status)" 5.2
    else res OK "Last backup" "$(date -d "@$start" '+%F %H:%M'), $status"; fi
  fi
  return 0
}

chk_notify() {
  local targets matchers users email name type dis origin tgt nt=0 nm=0 has_mail=0 has_other=0
  targets="$(pj /cluster/notifications/targets)" || { res INFO "Notifications" "notification system needs Proxmox VE 8.1 or newer"; return; }
  matchers="$(pj /cluster/notifications/matchers)" || matchers="[]"
  users="$(pj /access/users)" || users="[]"
  email="$(jrows userid email <<<"$users" | awk -F'|' '$1=="root@pam"{print $2}')"
  while IFS='|' read -r name type dis origin; do
    [[ -n "$name" && "$dis" != 1 ]] || continue
    nt=$(( nt + 1 ))
    [[ "$type" == sendmail ]] && has_mail=1 || has_other=1
    detail "Target" "$name ($type, ${origin:-user-created})"
  done < <(jrows name type disable origin <<<"$targets")
  while IFS='|' read -r name dis tgt; do
    [[ -n "$name" && "$dis" != 1 && -n "$tgt" ]] || continue
    nm=$(( nm + 1 )); detail "Matcher" "$name -> $tgt"
  done < <(jrows name disable target <<<"$matchers")

  if (( nt == 0 )); then res FAIL "Notifications" "no notification target" 6.2
  elif (( nm == 0 )); then res FAIL "Notifications" "no active matcher" 6.5
  elif (( ! has_other )) && [[ -z "$email" ]]; then res WARN "Notifications" "root@pam has no e-mail address (used by mail-to-root)" 6.1
  elif (( ! has_other )); then
    local relay; relay="$(postconf -h relayhost 2>/dev/null || true)"
    if [[ -z "$relay" ]]; then res WARN "Notifications" "no relay host; mail to $email is delivered directly (often rejected)" 6.2
    else res OK "Notifications" "mail to $email via $relay"; fi
  else res OK "Notifications" "$nt targets, $nm matchers${email:+, root e-mail $email}"; fi
  if (( has_mail )) && ! systemctl is-active --quiet postfix 2>/dev/null; then res WARN "Mail server" "postfix not running; sendmail targets cannot deliver"; fi
  return 0
}

# section|function, in board order
CHECKS=(
  "SECURITY|chk_tfa" "SECURITY|chk_ssh" "SECURITY|chk_cert" "SECURITY|chk_firewall"
  "UPDATES|chk_repos" "UPDATES|chk_updates" "UPDATES|chk_microcode"
  "STORAGE|chk_storage" "STORAGE|chk_disks"
  "BACKUPS AND ALERTS|chk_backups" "BACKUPS AND ALERTS|chk_schedule" "BACKUPS AND ALERTS|chk_notify"
  "SYSTEM|chk_system"
)

# run_checks: fills RESULTS with SECTION|STATUS|LABEL|MESSAGE|FIX (checks run in parallel)
RESULTS=()
run_checks() {
  local dir i sec l
  dir="$(mktemp -d)"
  [[ -n "$TK_CACHE" ]] && rm -f "$TK_CACHE"/* 2>/dev/null
  for i in "${!CHECKS[@]}"; do
    ( set +eE; trap - ERR; "${CHECKS[i]#*|}" >"$dir/$i" 2>/dev/null ) &
  done
  wait
  RESULTS=()
  for i in "${!CHECKS[@]}"; do
    sec="${CHECKS[i]%%|*}"
    while IFS= read -r l; do [[ -n "$l" ]] && RESULTS+=("$sec|$l"); done <"$dir/$i"
  done
  rm -rf "$dir"
}

badge() {
  case "$1" in
    OK) echo "${C_G}[ OK ]${C_0}" ;; WARN) echo "${C_Y}[WARN]${C_0}" ;;
    FAIL) echo "${C_R}[FAIL]${C_0}" ;; *) echo "${C_C}[INFO]${C_0}" ;;
  esac
}

# print_results [1 = include detail lines]
print_results() {
  local full="${1:-0}" cur="" l sec st label msg fix
  for l in "${RESULTS[@]}"; do
    IFS='|' read -r sec st label msg fix <<<"$l"
    [[ "$st" == - ]] && (( ! full )) && continue
    [[ "$sec" != "$cur" ]] && { echo " ${C_B}${sec}${C_0}"; cur="$sec"; }
    if [[ "$st" == - ]]; then printf '         %s%-15s %s%s\n' "$C_D" "$label" "$msg" "$C_0"
    else printf '  %s %-15s %s%s\n' "$(badge "$st")" "$label" "$msg" "${fix:+  ${C_D}-> $fix${C_0}}"; fi
  done
}

json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
print_json() {
  local l sec st label msg fix first=1
  printf '{"node":%s,"version":%s,"results":[' "$(json_str "$NODE")" "$(json_str "$VERSION")"
  for l in "${RESULTS[@]}"; do
    IFS='|' read -r sec st label msg fix <<<"$l"
    [[ "$st" == - ]] && continue
    (( first )) || printf ','; first=0
    printf '{"section":%s,"status":%s,"check":%s,"message":%s,"fix":%s}' \
      "$(json_str "$sec")" "$(json_str "$st")" "$(json_str "$label")" "$(json_str "$msg")" "$(json_str "$fix")"
  done
  printf ']}\n'
}

# worst status -> exit code 0 ok, 1 warn, 2 fail
results_rc() {
  local l rc=0
  for l in "${RESULTS[@]}"; do
    case "$l" in *"|FAIL|"*) rc=2 ;; *"|WARN|"*) (( rc < 1 )) && rc=1 ;; esac
  done
  return "$rc"
}

header_line() {
  local v k dr dev gw addr ip dns
  v="$(pveversion 2>/dev/null | awk -F/ '{print $2}')"
  k="$(uname -r)"
  echo "${C_B}Proxmox toolbelt $VERSION${C_0}   node ${C_B}$NODE${C_0}   PVE ${v:-?}   kernel $k   $(is_cluster && echo cluster || echo "single node")$( (( DRY_RUN )) && echo "   ${C_Y}[dry-run]${C_0}")"
  dr="$(default_route)"; dev="${dr%%|*}" gw="${dr#*|}"
  addr="$(iface_ipv4 "$dev")"; ip="$(node_ip)"; dns="$(host_resolvers)"
  echo "${C_D}$(host_fqdn)   ${addr:-no address}${dev:+ on $dev}${gw:+ gw $gw}   DNS ${dns:-none}   GUI https://${ip:-?}:8006${C_0}"
}

host_fqdn() { hostname -f 2>/dev/null || hostname 2>/dev/null || echo "$NODE"; }

# node_ip: the address $NODE resolves to (what the GUI and cluster use), else the default route address
node_ip() {
  local ip dr
  ip="$(getent ahostsv4 "$NODE" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -n "$ip" && "$ip" != 127.* ]]; then echo "$ip"; return 0; fi
  dr="$(default_route)"; ip="$(iface_ipv4 "${dr%%|*}")"
  echo "${ip%/*}"
}

# ---------------------------------------------------------------------------
# File changes: diff, confirm, back up, write
# ---------------------------------------------------------------------------
BACKUP_DIR=""
backup_file() {
  local real; real="$(readlink -f "$1")"
  [[ -e "$real" ]] || return 0
  [[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$BACKUP_ROOT/$(date +%F-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  cp -a --parents "$real" "$BACKUP_DIR/"
  hint "backup: $BACKUP_DIR$real"
}

show_diff() { # REAL NEW
  diff -u --label "$1 (now)" --label "$1 (new)" "$([[ -e $1 ]] && echo "$1" || echo /dev/null)" "$2" \
    | sed -e "s/^+/${C_G}+/" -e "s/^-/${C_R}-/" -e "s/\$/${C_0}/" || true
}

# write_file PATH NEWFILE [MODE]: backs up and replaces content (keeps symlinks/permissions)
write_file() {
  local path="$1" new="$2" mode="${3:-644}"
  if (( DRY_RUN )); then hint "[dry-run] would write $path"; return 0; fi
  if [[ -e "$path" ]]; then backup_file "$path"; cat "$new" >"$path"
  else mkdir -p "$(dirname "$path")"; install -m "$mode" "$new" "$path"; fi
  log "Wrote $path"
}

pause() { echo; read -rsp "${C_D}Press Enter to continue${C_0}" _ || true; echo; }

# Ctrl+C during "read -e" leaves the terminal in raw mode without echo (readline does not
# get to restore it). The settings saved at start are put back after each action and on exit.
TTY_SAVE=""
save_tty()    { [[ -t 0 ]] && TTY_SAVE="$(stty -g 2>/dev/null)" || true; }
restore_tty() { [[ -n "$TTY_SAVE" && -t 0 ]] && stty "$TTY_SAVE" 2>/dev/null || true; }
need_root() { (( EUID == 0 )) || die "Run as root on a Proxmox VE node"; }

# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------
view_tfa() {
  hdr "Users and two-factor authentication"
  local users tfa doms id en types locked mail toks
  users="$(pj /access/users --full 1)" || die "Could not read users"
  tfa="$(pj /access/tfa)" || tfa="[]"; doms="$(pj /access/domains)" || doms="[]"
  printf '  %-28s %-8s %-30s %s\n' USER STATE 2FA E-MAIL
  while IFS='|' read -r id en types locked mail toks; do
    [[ -n "$id" ]] || continue
    local col="$C_G"; [[ -z "${types//recovery/}" || "${types//recovery/}" == , ]] && col="$C_R"
    (( en )) || col="$C_D"
    printf '  %-28s %-8s %s%-30s%s %s\n' "$id" "$( (( en )) && echo enabled || echo disabled)" "$col" "${types:-none}$([[ $locked == 1 ]] && echo " LOCKED")" "$C_0" "${mail:--}"
    [[ -n "$toks" ]] && printf '    %stokens: %s%s\n' "$C_D" "$toks" "$C_0"
  done < <(tfa_rows "$users" "$tfa" "$doms")
  echo
  hint "Add 2FA: Datacenter > Permissions > Two Factor > Add > TOTP. Add Recovery Keys as a fallback."
  hint "Token format: id:privsep:expire. privsep=0 grants the token all permissions of its user."
}

# pubkey_lines [FILE]: public keys from FILE (or stdin), one per line. Drops CR (files edited
# on Windows), control characters and authorized_keys options before the key type.
pubkey_lines() {
  tr -d '\r' <"${1:-/dev/stdin}" | tr -d '\000-\010\013-\037\177' | awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-)/) break
    if (i >= NF) next
    out = $i; for (j = i + 1; j <= NF; j++) out = out " " $j; print out }'
}

# pubkey_label FILE: "N key(s): comment1, comment2, ..." (at most 3 comments, 60 characters)
pubkey_label() {
  local n names
  n="$(pubkey_lines "$1" | grep -c . || true)"
  names="$(pubkey_lines "$1" | awk 'NR<=3{c=""; for (j = 3; j <= NF; j++) c = c (c == "" ? "" : " ") $j; print (c == "" ? $1 : c)}' | paste -sd, - | sed 's/,/, /g')"
  (( n > 3 )) && names+=", ..."
  (( ${#names} > 60 )) && names="${names:0:57}..."
  echo "$n key(s): $names"
}

ssh_valid_keys() { ssh_key_info "$ROOT_KEYS" | grep -c . || true; }

fix_ssh_addkey() {
  hdr "Add an SSH public key for root"
  hint "Enter a public key (ssh-ed25519 AAAA... comment) or the path to a .pub file"
  local in tmp; tmp="$(mktemp)"; TMP_FILES+=("$tmp")
  while true; do
    ask in "Key or file" "" v_any
    if [[ -f "$in" ]]; then pubkey_lines "$in" >"$tmp"
    else printf '%s\n' "$in" | pubkey_lines >"$tmp"; fi
    if [[ -s "$tmp" ]] && ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then break; fi
    echo "  Not a valid SSH public key" >&2
  done
  ssh-keygen -l -f "$tmp"
  local k added=0 new; new="$(mktemp)"; TMP_FILES+=("$new")
  [[ -f "$ROOT_KEYS" ]] && cat "$ROOT_KEYS" >"$new"
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    if [[ -f "$ROOT_KEYS" ]] && grep -qF "$(awk '{print $2}' <<<"$k")" "$ROOT_KEYS"; then hint "already present, skipped: ${k:0:40}..."; continue; fi
    printf '%s\n' "$k" >>"$new"; added=$(( added + 1 ))
  done <"$tmp"
  (( added )) || { log "No new keys"; return 0; }
  show_diff "$ROOT_KEYS" "$new"
  confirm "Add $added key(s) to $ROOT_KEYS?" || return 0
  if [[ ! -e "$ROOT_KEYS" ]] && (( ! DRY_RUN )); then mkdir -p "$(dirname "$ROOT_KEYS")"; chmod 700 "$(dirname "$ROOT_KEYS")"; fi
  write_file "$ROOT_KEYS" "$new" 600
}

fix_ssh() {
  hdr "Harden SSH: root by key only, no password logins"
  local conf; conf="$(sshd -T 2>/dev/null)" || die "sshd -T failed; is openssh-server installed?"
  hint "Current: $(awk '$1~/^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication)$/{printf "%s %s  ", $1, $2}' <<<"$conf")"
  local n; n="$(ssh_valid_keys)"
  if (( n == 0 )); then
    warn "No valid key in $ROOT_KEYS. Without one, root SSH login fails after this change."
    confirm "Add a key?" && fix_ssh_addkey
    n="$(ssh_valid_keys)"
    (( n > 0 || DRY_RUN )) || die "Aborted: root has no SSH key"
  else log "root has $n valid SSH key(s)"; fi

  local u others=()
  while IFS=: read -r u _ uid _ _ home shell; do
    (( uid >= 1000 && uid < 65534 )) || continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    [[ -s "$home/.ssh/authorized_keys" ]] || others+=("$u")
  done < <(getent passwd)
  (( ${#others[@]} )) && warn "Users without an SSH key (password login stops working): ${others[*]}"

  local dropin="$SSHD_DIR/sshd_config.d/$SSH_DROPIN" new; new="$(mktemp)"; TMP_FILES+=("$new")
  cat >"$new" <<EOF
# Managed by proxmox-toolbelt.sh. Remove this file and reload ssh to undo.
# prohibit-password (not "no"): cluster nodes connect to each other as root by key.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
  echo; show_diff "$dropin" "$new"; echo
  local earlier; earlier="$(find "$SSHD_DIR/sshd_config.d" -maxdepth 1 -name '*.conf' 2>/dev/null | sort | awk -v me="$dropin" '$0 < me' | paste -sd' ' -)"
  [[ -n "$earlier" ]] && warn "Read before this file and take precedence: $earlier"
  hint "The change is reverted automatically after ${SSH_REVERT_SECS}s unless you confirm that a new login works."
  confirm "Apply?" || return 0
  local had_prev=0; [[ -e "$dropin" ]] && had_prev=1
  (( DRY_RUN )) && { hint "[dry-run] would write $dropin, run sshd -t, schedule a revert in ${SSH_REVERT_SECS}s and reload ssh"; return 0; }
  write_file "$dropin" "$new" 644
  if ! sshd -t; then
    ssh_restore_dropin "$dropin" "$had_prev"
    die "sshd -t rejected the configuration; $dropin restored, nothing changed"
  fi

  # The revert runs outside this session (systemd timer), so it also happens if the connection drops.
  local revert unit="proxmox-toolbelt-ssh-revert-$$"
  revert="$(ssh_revert_cmd "$dropin" "$had_prev")"
  schedule_revert "$unit" "$SSH_REVERT_SECS" "$revert"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd || { cancel_revert "$unit"; sh -c "$revert"; die "Could not reload ssh; change reverted"; }
  conf="$(sshd -T 2>/dev/null)"
  local got; got="$(awk '$1=="passwordauthentication"{print $2}' <<<"$conf")"
  if [[ "$got" == no ]]; then log "Password authentication disabled"
  else warn "PasswordAuthentication is still '$got'; set earlier in another file"; fi

  echo
  echo "  ${C_Y}Open a NEW terminal now and log in: ssh root@$(node_ip)${C_0}"
  echo "  ${C_Y}This session stays open. Without confirmation the change is reverted in ${SSH_REVERT_SECS}s.${C_0}"
  local a=""
  read -t "$SSH_REVERT_SECS" -erp "Type 'keep' after the new login worked: " a || true
  cancel_revert "$unit"
  if [[ "$a" == keep ]]; then
    log "SSH change kept"
    echo "  Revert later: rm $dropin && systemctl reload ssh"
  else
    echo
    sh -c "$revert"
    warn "Not confirmed; SSH configuration reverted and ssh reloaded"
  fi
}

SSH_REVERT_SECS="${SSH_REVERT_SECS:-120}"
# ssh_revert_cmd DROPIN HAD_PREV: shell command that restores the previous drop-in and reloads ssh
ssh_revert_cmd() {
  local dropin="$1" restore
  if (( $2 )) && [[ -n "$BACKUP_DIR" ]]; then
    restore="cp -f $(printf '%q' "$BACKUP_DIR$(readlink -m "$dropin")") $(printf '%q' "$dropin")"
  else
    restore="rm -f $(printf '%q' "$dropin")"
  fi
  echo "$restore; systemctl reload ssh 2>/dev/null || systemctl reload sshd"
}
ssh_restore_dropin() {
  local dropin="$1"
  if (( $2 )) && [[ -n "$BACKUP_DIR" ]]; then cp -f "$BACKUP_DIR$(readlink -m "$dropin")" "$dropin"
  else rm -f "$dropin"; fi
}

# schedule_revert UNIT SECONDS CMD: runs CMD after SECONDS, detached from this session
REVERT_PID="" REVERT_FLAG=""
schedule_revert() {
  local unit="$1" secs="$2" cmd="$3"
  REVERT_PID=""
  if command -v systemd-run >/dev/null \
     && systemd-run --quiet --unit="$unit" --on-active="$secs" /bin/sh -c "$cmd" 2>/dev/null; then
    hint "Revert scheduled: systemd timer $unit.timer"
    return 0
  fi
  # Fallback without systemd-run: the command runs only while the flag file exists.
  # Not in TMP_FILES: the revert must still run if this session ends.
  REVERT_FLAG="$(mktemp /run/proxmox-toolbelt-revert.XXXXXX 2>/dev/null || mktemp)"
  setsid /bin/sh -c "sleep $secs; [ -e $(printf '%q' "$REVERT_FLAG") ] && { rm -f $(printf '%q' "$REVERT_FLAG"); $cmd; }" </dev/null >/dev/null 2>&1 &
  REVERT_PID=$!
  hint "Revert scheduled: background process $REVERT_PID"
}
cancel_revert() {
  if [[ -n "$REVERT_PID" ]]; then
    rm -f "$REVERT_FLAG"; kill "$REVERT_PID" 2>/dev/null || true; REVERT_PID="" REVERT_FLAG=""
  else systemctl stop "$1.timer" 2>/dev/null || true; fi
}

view_cert() {
  hdr "Web GUI certificate"
  local f
  for f in "$PVE_DIR/local/pveproxy-ssl.pem" "$PVE_DIR/local/pve-ssl.pem"; do
    [[ -s "$f" ]] || continue
    echo "${C_B}$f${C_0}"
    openssl x509 -in "$f" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/  /'
    [[ "$f" == *pveproxy-ssl.pem ]] && { hint "In use by pveproxy (overrides pve-ssl.pem)."; break; }
  done
  echo; echo "${C_B}ACME${C_0}"
  pvenode acme account list 2>/dev/null | sed 's/^/  /' || true
  pvenode config get 2>/dev/null | grep -E '^acme' | sed 's/^/  /' || hint "No ACME domain configured."
  echo
  hint "ACME setup: Datacenter > ACME > Add account; Node > System > Certificates > ACME > Add domain > Order Certificates Now."
  hint "Renewal is handled by pve-daily-update.timer."
}

view_firewall() {
  hdr "Firewall"
  pve-firewall status 2>/dev/null | sed 's/^/  /' || true
  local f
  for f in "$PVE_DIR/firewall/cluster.fw" "$PVE_DIR/nodes/$NODE/host.fw"; do
    echo; echo "${C_B}$f${C_0}"
    if [[ -s "$f" ]]; then sed 's/^/  /' "$f"; else hint "(not present, defaults apply)"; fi
  done
  echo
  hint "Default: datacenter firewall disabled. Add ACCEPT rules for tcp/8006 and tcp/22 from the management"
  hint "network before enabling it (Datacenter > Firewall > Options). Guest traffic is filtered only when the"
  hint "guest firewall is enabled (VM > Firewall > Options); firewall=1 on the NIC alone is not sufficient."
}

# ---------------------------------------------------------------------------
# Updates and repositories
# ---------------------------------------------------------------------------
# apt_stage DIR: copy every sources file into DIR (same layout) for planning
apt_stage() {
  local dir="$1" f
  mkdir -p "$dir/sources.list.d"
  [[ -f "$APT_DIR/sources.list" ]] && cp "$APT_DIR/sources.list" "$dir/"
  for f in "$APT_DIR"/sources.list.d/*.list "$APT_DIR"/sources.list.d/*.sources; do
    [[ -f "$f" ]] && cp "$f" "$dir/sources.list.d/"
  done
  return 0
}

# Transforms one sources file for TARGET (nosub|enterprise): toggles PVE repos, converts Ceph repos
repo_transform_sources() {
  awk -v T="$1" '
    function kind(u, c) {
      if (u ~ /proxmox\.com\/debian\/ceph-/) { if (u ~ /enterprise\.proxmox\.com/) return "ceph-ent"; if (c ~ /(^| )no-subscription( |$)/) return "ceph-nosub"; return "ceph-other" }
      if (u ~ /enterprise\.proxmox\.com\/debian\/pve/) return "pve-ent"
      if (u ~ /proxmox\.com\/debian\/pve/ && c ~ /pve-no-subscription/) return "pve-nosub"
      return "other"
    }
    function rel(u) { sub(/.*\/debian\/ceph-/, "", u); sub(/[\/ ].*/, "", u); return u }
    function flush(   i, k, want, key, line) {
      if (n == 0) return
      k = kind(uris, comps); want = ""
      if (k == "pve-ent") want = (T == "nosub") ? "off" : "on"
      if (k == "pve-nosub") want = (T == "nosub") ? "on" : "off"
      for (i = 1; i <= n; i++) {
        line = L[i]; key = tolower(line); sub(/:.*/, "", key)
        if (want != "" && key == "enabled") continue
        if (k == "ceph-ent" && T == "nosub") {
          if (key == "uris") line = "URIs: http://download.proxmox.com/debian/ceph-" rel(uris)
          if (key == "components") line = "Components: no-subscription"
        }
        if (k == "ceph-nosub" && T == "enterprise") {
          if (key == "uris") line = "URIs: https://enterprise.proxmox.com/debian/ceph-" rel(uris)
          if (key == "components") line = "Components: enterprise"
        }
        print line
      }
      if (want == "off") print "Enabled: false"
      n = 0; uris = comps = ""
    }
    /^[[:space:]]*$/ { flush(); print; next }
    { L[++n] = $0
      if ($0 !~ /^[[:space:]#]/) { key = tolower($0); sub(/:.*/, "", key); v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
        if (key == "uris") uris = v; if (key == "components") comps = v } }
    END { flush() }'
}

repo_transform_list() {
  awk -v T="$1" '
    function rel(u) { sub(/.*\/debian\/ceph-/, "", u); sub(/[\/ ].*/, "", u); return u }
    { body = $0; en = 1
      if (body ~ /^[[:space:]]*#[[:space:]]*deb(-src)?[[:space:]]/) { en = 0; sub(/^[[:space:]]*#[[:space:]]*/, "", body) }
      else if (body !~ /^[[:space:]]*deb(-src)?[[:space:]]/) { print; next }
      n = split(body, a, /[[:space:]]+/); s = (a[1] == "") ? 2 : 1
      u = s + 1; if (a[u] ~ /^\[/) { while (u <= n && a[u] !~ /\]$/) u++; u++ }
      uri = a[u]; comps = " "; for (j = u + 2; j <= n; j++) comps = comps a[j] " "
      if (uri ~ /enterprise\.proxmox\.com\/debian\/pve/) { print (T == "nosub" ? "# " body : body); next }
      if (uri ~ /proxmox\.com\/debian\/pve/ && comps ~ / pve-no-subscription /) { print (T == "nosub" ? body : "# " body); next }
      if (en && uri ~ /enterprise\.proxmox\.com\/debian\/ceph-/ && T == "nosub") { print a[s] " http://download.proxmox.com/debian/ceph-" rel(uri) " " a[u+1] " no-subscription"; next }
      if (en && uri ~ /download\.proxmox\.com\/debian\/ceph-/ && comps ~ / no-subscription / && T == "enterprise") { print a[s] " https://enterprise.proxmox.com/debian/ceph-" rel(uri) " " a[u+1] " enterprise"; next }
      print }'
}

# repo_plan TARGET STAGE: rewrites the staged copy so TARGET is the active PVE repository
repo_plan() {
  local target="$1" stage="$2" f code deb822=1
  code="$(os_codename)"; [[ -n "$code" ]] || die "Cannot tell the Debian release from $OS_RELEASE"
  [[ "$code" == bookworm || "$code" == bullseye ]] && deb822=0
  for f in "$stage"/sources.list "$stage"/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *.sources) repo_transform_sources "$target" <"$f" >"$f.new" ;;
      *) repo_transform_list "$target" <"$f" >"$f.new" ;;
    esac
    mv -f "$f.new" "$f"
  done
  local want; [[ "$target" == nosub ]] && want=pve-nosub || want=pve-ent
  local en ty uri co have=0
  while IFS='|' read -r _ en ty uri _ co; do
    [[ "$en" == 1 && "$(repo_kind "$uri" "$co")" == "$want" ]] && have=1
  done < <(apt_entries "$stage")
  (( have )) && return 0
  local url comp name
  if [[ "$target" == nosub ]]; then url="http://download.proxmox.com/debian/pve" comp="pve-no-subscription" name="pve-no-subscription"
  else url="https://enterprise.proxmox.com/debian/pve" comp="pve-enterprise" name="pve-enterprise"; fi
  if (( deb822 )); then
    [[ "$target" == nosub && ! -e "$stage/sources.list.d/proxmox.sources" ]] && name="proxmox"
    f="$stage/sources.list.d/$name.sources"
    [[ -s "$f" ]] && printf '\n' >>"$f"
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' "$url" "$code" "$comp" >>"$f"
  else
    printf 'deb %s %s %s\n' "$url" "$code" "$comp" >>"$stage/sources.list.d/$name.list"
  fi
}

# apt_apply STAGE: shows the diff of every changed sources file, confirms, writes
apt_apply() {
  local stage="$1" f rel real changed=()
  for f in "$stage"/sources.list "$stage"/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    rel="${f#"$stage"/}"; real="$APT_DIR/$rel"
    if [[ ! -e "$real" ]] || ! cmp -s "$f" "$real"; then changed+=("$rel"); show_diff "$real" "$f"; echo; fi
  done
  (( ${#changed[@]} )) || { log "No changes required"; return 1; }
  confirm "Write these ${#changed[@]} file(s)?" || return 1
  for rel in "${changed[@]}"; do write_file "$APT_DIR/$rel" "$stage/$rel" 644; done
  return 0
}

fix_repos() {
  hdr "Proxmox repositories"
  local sub; sub="$(subscription_status)"
  hint "Subscription: $sub. Debian release: $(os_codename)."
  local opts=("nosub|no-subscription: free, updates from download.proxmox.com (homelab)")
  opts+=("enterprise|enterprise: needs an active subscription, most tested updates")
  local def=nosub; [[ "$sub" == active ]] && def=enterprise
  local target; menu target "Use which repository" "$def" "${opts[@]}"
  [[ "$target" == enterprise && "$sub" != active ]] && { warn "No active subscription; apt update will return 401 for the enterprise repository."; ask_yn "Continue anyway?" n || return 0; }
  local stage; stage="$(mktemp -d)"; TMP_DIRS+=("$stage")
  apt_stage "$stage"
  repo_plan "$target" "$stage"
  echo
  apt_apply "$stage" || return 0
  (( DRY_RUN )) && return 0
  log "Running apt-get update"
  apt-get update || warn "apt-get update reported errors (see above)"
}

JOB_SESSION="proxmox-toolbelt"
# Own tmux server (socket "proxmox-toolbelt", no user config): independent of tmux sessions
# and ~/.tmux.conf of the admin. Re-attach: tmux -L proxmox-toolbelt attach
tmx() { tmux -L "$JOB_SESSION" -f /dev/null "$@"; }
JOB_ATTACH="tmux -L $JOB_SESSION attach"
JOB_RC_FILE="${JOB_RC_FILE:-/run/proxmox-toolbelt.rc}"

# job_guard: returns 1 (after offering to attach) when a proxmox-toolbelt tmux session still exists
job_guard() {
  command -v tmux >/dev/null && tmx has-session -t "$JOB_SESSION" 2>/dev/null || return 0
  warn "A package job from an earlier run is still open (tmux session '$JOB_SESSION')."
  hint "It may still be running. Starting another apt run now would fail on the dpkg lock."
  ask_yn "Attach to it?" y && tmx attach -t "$JOB_SESSION"
  return 1
}

# ensure_tmux: returns 0 when tmux is available (offers to install it)
ensure_tmux() {
  command -v tmux >/dev/null && return 0
  warn "tmux is not installed. Without it, a dropped SSH connection interrupts dpkg."
  if confirm "Install tmux now (apt-get install tmux)?"; then
    run apt-get install -y tmux
    (( DRY_RUN )) && return 0
    command -v tmux >/dev/null && return 0
  fi
  return 1
}

# in_multiplexer: the toolbelt itself already runs inside tmux or screen
in_multiplexer() { [[ -n "${TMUX:-}" || -n "${STY:-}" ]]; }

# run_job CMD...: runs CMD on a terminal, as typed in a shell.
# Outside tmux it starts a tmux session "proxmox-toolbelt" and attaches to it, so the command
# survives a dropped SSH connection (re-attach: tmux -L proxmox-toolbelt attach).
# Sets JOB_RC to the exit code, or "" when the session was detached and is still running.
run_job() {
  JOB_RC=""
  if (( DRY_RUN )); then run "$@"; JOB_RC=0; return 0; fi
  if in_multiplexer; then
    hint "Running inside tmux/screen; the command survives a dropped connection."
    set +e; "$@"; JOB_RC=$?; set -e
    return 0
  fi
  if ! ensure_tmux; then
    warn "Without tmux, a dropped SSH connection stops '$*' and can leave dpkg half-configured."
    confirm "Run it without tmux anyway?" || { JOB_RC=""; hint "Not started."; return 1; }
    set +e; "$@"; JOB_RC=$?; set -e
    return 0
  fi
  local inner start=(tmux -L "$JOB_SESSION" -f /dev/null)
  inner="$(printf '%q ' "$@"); rc=\$?; echo \$rc > $JOB_RC_FILE; echo; echo \"[proxmox-toolbelt] exit code \$rc. Press Enter to close this tmux session.\"; read -r _"
  rm -f "$JOB_RC_FILE"
  # A separate systemd scope keeps the tmux server alive when the SSH login session ends,
  # also with KillUserProcesses=yes in logind.conf.
  if command -v systemd-run >/dev/null && systemd-run --quiet --scope --collect --unit="$JOB_SESSION-job-$$" \
       "${start[@]}" new-session -d -s "$JOB_SESSION" "bash -c $(printf '%q' "$inner")" 2>/dev/null; then :
  else
    tmx new-session -d -s "$JOB_SESSION" "bash -c $(printf '%q' "$inner")" || die "Could not start tmux session"
  fi
  hint "tmux session '$JOB_SESSION'. Detach: Ctrl+B then D. Re-attach: $JOB_ATTACH"
  sleep 0.5
  tmx attach -t "$JOB_SESSION" || true
  if tmx has-session -t "$JOB_SESSION" 2>/dev/null; then
    hint "Detached. The command is still running in tmux session '$JOB_SESSION'."
    hint "Re-attach: $JOB_ATTACH"
    return 0
  fi
  JOB_RC="$(cat "$JOB_RC_FILE" 2>/dev/null || true)"
  rm -f "$JOB_RC_FILE"
  return 0
}

# Reports dpkg state, new default config files and pending reboot after a package job
after_packages() {
  local marker="$1" f
  if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
    warn "dpkg reports unfinished packages. Run menu 3.2 again, or: dpkg --configure -a"
  fi
  local dist=()
  while IFS= read -r f; do dist+=("$f"); done < <(find /etc -name '*.dpkg-dist' -newer "$marker" 2>/dev/null)
  if (( ${#dist[@]} )); then
    warn "Local config files were kept. New package defaults saved as:"
    for f in "${dist[@]}"; do echo "    $f"; done
    hint "Compare with: diff -u <file> <file>.dpkg-dist"
  fi
  local running newest; running="$(uname -r)"; newest="$(newest_kernel)"
  [[ -n "$newest" && "$newest" != "$running" ]] && warn "Reboot required: kernel $newest installed, $running running"
  return 0
}

fix_updates() {
  hdr "Install updates"
  hint "Proxmox VE requires dist-upgrade (full-upgrade). Plain 'apt upgrade' can leave the system inconsistent."
  job_guard || return 0
  if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
    warn "A previous package operation did not finish (dpkg --audit)."
    if confirm "Run dpkg --configure -a now?"; then
      local m0; m0="$(mktemp)"; TMP_FILES+=("$m0")
      run_job dpkg --configure -a || return 0
      (( DRY_RUN )) && return 0
      [[ -n "$JOB_RC" ]] || return 0
      after_packages "$m0"
      [[ "$JOB_RC" == 0 ]] || { warn "dpkg --configure -a exited with $JOB_RC; fix this before upgrading"; return 0; }
    fi
  fi
  run apt-get update
  (( DRY_RUN )) && { run apt-get dist-upgrade; return 0; }
  local sim rm_list
  sim="$(apt-get -s dist-upgrade 2>/dev/null)"
  rm_list="$(awk '/^Remv /{print $2}' <<<"$sim" | paste -sd' ' -)"
  grep -q '^Inst ' <<<"$sim" || [[ -n "$rm_list" ]] || { log "No updates available"; return 0; }
  if grep -qwE 'proxmox-ve|pve-manager|qemu-server' <<<"$rm_list"; then
    die "Aborted: the upgrade would remove $rm_list. Check the repositories (3.1)."
  fi
  if [[ -n "$rm_list" ]]; then
    warn "The upgrade removes these packages: $rm_list"
    confirm "Continue with package removals?" || return 0
  fi
  local marker; marker="$(mktemp)"; TMP_FILES+=("$marker")
  run_job apt-get dist-upgrade || return 0
  [[ -n "$JOB_RC" ]] || return 0
  after_packages "$marker"
  if [[ "$JOB_RC" == 0 ]]; then log "apt-get dist-upgrade finished"
  else warn "apt-get dist-upgrade exited with $JOB_RC"; fi
}

# Adds non-free-firmware to Debian entries of a staged sources tree
nff_plan() {
  local stage="$1" f
  for f in "$stage"/sources.list "$stage"/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *.sources) awk '
          function flush(   i) { for (i = 1; i <= n; i++) { if (deb && L[i] ~ /^[Cc]omponents:/ && L[i] !~ /non-free-firmware/) L[i] = L[i] " non-free-firmware"; print L[i] } n = 0; deb = 0 }
          /^[[:space:]]*$/ { flush(); print; next }
          { L[++n] = $0; if ($0 ~ /^[Uu][Rr][Ii][Ss]:.*debian\.org\/debian/) deb = 1 }
          END { flush() }' "$f" >"$f.new" ;;
      *) awk '/^[[:space:]]*deb(-src)?[[:space:]].*debian\.org\/debian/ && !/non-free-firmware/ { print $0 " non-free-firmware"; next } { print }' "$f" >"$f.new" ;;
    esac
    mv -f "$f.new" "$f"
  done
}

fix_microcode() {
  hdr "CPU microcode"
  job_guard || return 0
  local pkg; pkg="$(microcode_pkg)"
  [[ -n "$pkg" ]] || die "Unknown CPU vendor"
  if [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || true)" == ii* ]]; then log "$pkg is already installed"; return 0; fi
  local stage; stage="$(mktemp -d)"; TMP_DIRS+=("$stage")
  apt_stage "$stage"; nff_plan "$stage"
  if apt_apply "$stage"; then :; else hint "Sources unchanged"; fi
  run apt-get update
  local marker; marker="$(mktemp)"; TMP_FILES+=("$marker")
  run_job apt-get install "$pkg" || return 0
  (( DRY_RUN )) && return 0
  [[ -n "$JOB_RC" ]] || return 0
  after_packages "$marker"
  if [[ "$JOB_RC" == 0 ]]; then log "$pkg installed; active after reboot"
  else warn "apt-get install exited with $JOB_RC"; fi
}

view_versions() { hdr "Proxmox package versions"; pveversion -v 2>/dev/null | sed 's/^/  /' || die "pveversion not found"; }

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
view_storage() {
  hdr "Storage"
  printf '  %-18s %-10s %-9s %8s %8s %5s\n' NAME TYPE STATUS TOTAL FREE USED
  local name type st total used avail pct
  while read -r name type st total used avail pct; do
    pct=0; (( total > 0 )) && pct=$(( used * 100 / total ))
    printf '  %-18s %-10s %-9s %8s %8s %4s%%\n' "$name" "$type" "$st" "$(human_gib "$total")" "$(human_gib "$avail")" "$pct"
  done < <(pvesm status 2>/dev/null | awk 'NR>1')
  echo
  local cfg; cfg="$(pj /storage)" || cfg="[]"
  echo "${C_B}Content types${C_0}"
  jrows storage type content <<<"$cfg" | awk -F'|' '{printf "  %-18s %-10s %s\n", $1, $2, $3}'
  if command -v lvs >/dev/null; then echo; echo "${C_B}LVM thin pools${C_0}"; lvs -o vg_name,lv_name,lv_size,data_percent,metadata_percent -S 'segtype=thin-pool' 2>/dev/null | sed 's/^/  /' || true; fi
  if command -v zpool >/dev/null; then echo; echo "${C_B}ZFS${C_0}"; zpool list 2>/dev/null | sed 's/^/  /' || true; zpool status -x 2>/dev/null | sed 's/^/  /' || true; fi
}

fix_snippets() {
  hdr "Enable snippets"
  hint "Required by the VM builder for the cloud-init vendor snippet (qemu-guest-agent install)."
  local cfg opts=() name type content def=""
  cfg="$(pj /storage)" || die "Could not read the storage configuration"
  while IFS='|' read -r name type content; do
    [[ "$type" =~ ^(dir|nfs|cifs|cephfs|glusterfs|btrfs)$ ]] || continue
    opts+=("$name|$type: ${content:-none}"); [[ -z "$def" || "$name" == local ]] && def="$name"
  done < <(jrows storage type content <<<"$cfg")
  (( ${#opts[@]} )) || die "No file-based storage (dir, nfs, cifs, cephfs) to hold snippets"
  local st; menu st "Storage" "$def" "${opts[@]}"
  content="$(jrows storage content <<<"$cfg" | awk -F'|' -v s="$st" '$1==s{print $2}')"
  [[ ",$content," == *,snippets,* ]] && { log "$st already has snippets content"; return 0; }
  local new="${content:+$content,}snippets"
  log "$st content: ${content:-none} -> $new"
  confirm "Apply?" || return 0
  run pvesm set "$st" --content "$new"
}

view_disks() {
  hdr "Disks"
  local json; json="$(pj "/nodes/$NODE/disks/list")" || die "Could not list disks"
  printf '  %-14s %-7s %-5s %-26s %-16s %-7s %s\n' DEVICE SIZE TYPE MODEL USED-BY SMART WEAR
  local dev size used model health wear type
  while IFS='|' read -r dev size used model health wear type; do
    [[ -n "$dev" ]] || continue
    local w="-"; [[ "$wear" =~ ^[0-9]+$ ]] && w="$(( 100 - wear ))%"
    local col=""; [[ -z "$used" ]] && col="$C_C"; [[ "${health^^}" == FAILED ]] && col="$C_R"
    printf '  %s%-14s %-7s %-5s %-26.26s %-16.16s %-7s %s%s\n' "$col" "$dev" "$(human_bytes "$size")" "${type:-?}" "${model:--}" "${used:-UNUSED}" "${health:--}" "$w" "$C_0"
  done < <(jrows devpath size used model health wearout type <<<"$json")
  echo
  hint "Initialize unused disks: Node > Disks > LVM-Thin, ZFS or Directory > Create."
  hint "WEAR = percentage of rated SSD endurance used."
}

view_orphans() {
  hdr "Unused and orphaned disk images"
  local f id
  echo "${C_B}Detached disks still listed in guest configs${C_0} (Hardware tab shows them as 'Unused Disk')"
  local any=0
  shopt -s nullglob
  for f in "$PVE_DIR"/nodes/*/qemu-server/*.conf "$PVE_DIR"/nodes/*/lxc/*.conf; do
    id="${f##*/}"; id="${id%.conf}"
    while read -r line; do any=1; echo "  $id  $line"; done < <(awk '/^\[/{exit} /^unused[0-9]+:/{print}' "$f")
  done
  shopt -u nullglob
  (( any )) || hint "none"

  echo; echo "${C_B}Volumes on storage that no guest config mentions${C_0} (scanning, may take a moment)"
  local refs; refs="$(cat "$PVE_DIR"/nodes/*/qemu-server/*.conf "$PVE_DIR"/nodes/*/lxc/*.conf 2>/dev/null || true)"
  local name type stat volid size vmid found=0
  while read -r name type stat _; do
    [[ "$stat" == active ]] || continue
    while read -r volid _ _ size vmid; do
      [[ "$volid" == *:* && -n "${vmid:-}" ]] || continue
      grep -qF "${volid#*:}" <<<"$refs" && continue
      found=1
      printf '  %-45s %8s  %s\n' "$volid" "$(human_bytes "${size:-0}")" "$(guest_conf "$vmid" >/dev/null && echo "guest $vmid exists but does not use it" || echo "guest $vmid does not exist")"
    done < <(pvesm list "$name" --content images 2>/dev/null | awk 'NR>1'; pvesm list "$name" --content rootdir 2>/dev/null | awk 'NR>1')
  done < <(pvesm status 2>/dev/null | awk 'NR>1')
  (( found )) || hint "none"
  echo
  hint "Verify each volume before removal: pvesm free <volid>"
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
view_backups() {
  hdr "Backup jobs"
  local jobs; jobs="$(pj /cluster/backup)" || die "Could not read backup jobs"
  local id en sched store all vmid mode keep
  printf '  %-22s %-8s %-18s %-14s %-22s %s\n' JOB STATE SCHEDULE STORAGE GUESTS RETENTION
  while IFS='|' read -r id en sched store all vmid mode keep; do
    [[ -n "$id" ]] || continue
    printf '  %-22.22s %-8s %-18.18s %-14.14s %-22.22s %s\n' "$id" "$([[ $en == 0 ]] && echo off || echo on)" "${sched:-?}" "${store:-?}" "$([[ $all == 1 ]] && echo all || echo "${vmid:-pool}")" "${keep:--}"
  done < <(jrows id enabled schedule storage all vmid mode prune-backups <<<"$jobs")
  echo; echo "${C_B}VMs and containers in no backup job${C_0}"
  local g name type n=0
  while IFS='|' read -r g name type; do [[ -n "$g" ]] && { n=1; echo "  $g  ${name:-}  ($type)"; }; done < <(pj /cluster/backup-info/not-backed-up | jrows vmid name type)
  (( n )) || hint "none"
  echo
  hint "Add a job: Datacenter > Backup > Add."
}

view_backup_tasks() {
  hdr "Recent backup runs on $NODE"
  local upid start end status user
  while IFS='|' read -r upid start end status user; do
    [[ -n "$upid" ]] || continue
    local col="$C_G"; [[ "$status" == OK ]] || col="$C_Y"; [[ "$status" == OK || "$status" == WARNINGS* ]] || col="$C_R"
    printf '  %s  %4s min  %s%s%s\n' "$(date -d "@$start" '+%F %H:%M')" "$(( (${end:-$start} - start) / 60 ))" "$col" "${status:-running}" "$C_0"
  done < <(pj "/nodes/$NODE/tasks" --typefilter vzdump --limit 20 | jrows upid starttime endtime status user)
  hint "Logs: Node > Task History, or pvenode task log <UPID>"
}

# ---------------------------------------------------------------------------
# Scheduled snapshots and backups
# ---------------------------------------------------------------------------
# A job is $SCHED_DIR/NAME.conf: KEY=value lines, validated and never sourced.
# The timer proxmox-toolbelt-job@NAME.timer fires on a calendar grid (the "tick", for example
# hourly) with Persistent=true, so a tick missed while the node was off fires right after boot.
# Each tick runs "proxmox-toolbelt schedule tick NAME". It compares the tick with the last
# completed run in $SCHED_STATE/NAME.state and starts the job only when the interval has passed.
# That keeps intervals that no calendar expression covers (10h, 36h, 3 months) evenly spaced.
# A run cut short by a reboot or crash does not count as completed: it runs again after boot
# (proxmox-toolbelt-schedule-recover.service), after stale guest locks it left are cleared.
SCHED_DIR="${SCHED_DIR:-/etc/proxmox-toolbelt/schedule}"
SCHED_STATE="${SCHED_STATE:-/var/lib/proxmox-toolbelt/schedule}"
SCHED_LOG="${SCHED_LOG:-/var/log/proxmox-toolbelt}"
SCHED_LOCKS="${SCHED_LOCKS:-/run/lock}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
SCHED_ATTEMPTS="${SCHED_ATTEMPTS:-3}"        # tries per guest (snapshot) or per run (backup)
SCHED_RETRY_WAIT="${SCHED_RETRY_WAIT:-60}"   # seconds between tries
SCHED_LOG_LINES=5000                         # each job log is trimmed to this many lines
JOB_UNIT="proxmox-toolbelt-job"
RECOVER_UNIT="proxmox-toolbelt-schedule-recover.service"
SCHED_PROGS=(/usr/local/sbin/proxmox-toolbelt /usr/sbin/proxmox-toolbelt)   # systemd's search order
declare -A J=()

sched_now() { echo "${SCHED_NOW:-$(date +%s)}"; }
fmt_ts() { if [[ "${1:-}" =~ ^[0-9]+$ ]]; then date -d "@$1" '+%F %H:%M'; else echo "-"; fi; }
gcd() { local a="$1" b="$2" t; while (( b )); do t=$(( a % b )); a=$b; b=$t; done; echo "$a"; }

# parse_every SPEC: prints "MINUTES MONTHS" (one of them 0). Accepts 10m, 90min, 10h, 24h, 1d,
# 2w, 3mo, combinations such as 1h30m or 1d12h, and hourly, daily, weekly, monthly.
# "m" is minutes; months are "mo". From 5 minutes up to 1 year, or 1 to 120 months.
parse_every() {
  local s="${1,,}" min=0 mon=0 n u
  s="${s//[[:space:]]/}"
  case "$s" in hourly) s=1h ;; daily) s=1d ;; weekly) s=1w ;; monthly) s=1mo ;; esac
  [[ -n "$s" ]] || return 1
  local re='^([0-9]{1,6})(months?|mo|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w)(([0-9].*)?)$'
  while [[ -n "$s" ]]; do
    [[ "$s" =~ $re ]] || return 1
    n=$(( 10#${BASH_REMATCH[1]} )) u="${BASH_REMATCH[2]}" s="${BASH_REMATCH[3]}"
    case "$u" in
      mo|month*) mon=$(( mon + n )) ;;
      m|min*) min=$(( min + n )) ;;
      h*) min=$(( min + n * 60 )) ;;
      d*) min=$(( min + n * 1440 )) ;;
      w*) min=$(( min + n * 10080 )) ;;
    esac
  done
  if (( mon )); then (( min == 0 && mon <= 120 )) || return 1
  else (( min >= 5 && min <= 525600 )) || return 1; fi
  echo "$min $mon"
}

# every_text MINUTES MONTHS: "every 10 hours"
every_text() {
  local min="$1" mon="$2" u n c
  if (( mon )); then if (( mon == 1 )); then echo "every month"; else echo "every $mon months"; fi; return 0; fi
  for u in "10080 week" "1440 day" "60 hour" "1 minute"; do
    n="${u%% *}"
    (( min % n == 0 )) || continue
    c=$(( min / n ))
    if (( c == 1 )); then echo "every ${u#* }"; else echo "every $c ${u#* }s"; fi
    return 0
  done
}

# sched_tick MINUTES MONTHS AT: "SECONDS|OnCalendar" of the timer grid. Whole days, weeks and
# months tick daily at AT; other intervals tick every gcd(interval, 60) minutes (10m -> 10 min,
# 45m -> 15 min, 10h -> hourly), so every run lands on the grid.
sched_tick() {
  local min="$1" mon="$2" at="${3:-00:00}" t
  if (( mon || min % 1440 == 0 )); then echo "86400|*-*-* $at:00"; return 0; fi
  t="$(gcd "$min" 60)"
  if (( t == 60 )); then echo "3600|*-*-* *:00:00"; else echo "$(( t * 60 ))|*-*-* *:00/$t:00"; fi
}

# sched_slot NOW TICK AT: start of the grid period that contains NOW (local time)
sched_slot() {
  local now="$1" tick="$2" at="${3:-00:00}" s z off
  if (( tick == 86400 )); then
    s="$(date -d "$(date -d "@$now" +%F) $at" +%s 2>/dev/null)" || s=$(( now - now % 3600 ))
    if (( s > now )); then
      s="$(date -d "$(date -d "@$(( now - 86400 ))" +%F) $at" +%s 2>/dev/null)" || s=$(( now - now % 3600 ))
    fi
    echo "$s"; return 0
  fi
  z="$(date -d "@$now" +%z)"
  off=$(( 10#${z:1:2} * 3600 + 10#${z:3:2} * 60 )); [[ "${z:0:1}" == - ]] && off=$(( -off ))
  echo $(( now - (now + off) % tick ))
}

# sched_due SLOT LAST MINUTES MONTHS TICK: 0 when a run is due in SLOT. LAST is the slot of the
# last completed run. Day intervals allow half a tick of slack (DST); months count calendar
# months, so "1mo" runs on the 1st of each month (the first run happens at the next tick).
sched_due() {
  local slot="$1" last="$2" min="$3" mon="$4" tick="$5" y1 m1 y2 m2
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  (( slot > last )) || return 1
  if (( mon )); then
    read -r y1 m1 <<<"$(date -d "@$last" '+%Y %m')"
    read -r y2 m2 <<<"$(date -d "@$slot" '+%Y %m')"
    (( (10#$y2 * 12 + 10#$m2) - (10#$y1 * 12 + 10#$m1) >= mon ))
  else
    (( slot - last >= min * 60 - tick / 2 ))
  fi
}

# next_due_text NAME: when the next run is expected (J loaded)
next_due_text() {
  local name="$1" last min mon at="${J[AT]}" st
  if ! systemctl is-enabled --quiet "$JOB_UNIT@$name.timer" 2>/dev/null; then echo "paused"; return 0; fi
  if [[ -n "${J[CALENDAR]}" ]]; then
    local us; us="$(systemctl show -p NextElapseUSecRealtime --value "$JOB_UNIT@$name.timer" 2>/dev/null || true)"
    if [[ -n "$us" && "$us" != n/a ]]; then date -d "$us" '+%F %H:%M' 2>/dev/null || echo "$us"; else echo "?"; fi
    return 0
  fi
  st="$(state_get "$name" status)"
  last="$(state_get "$name" last_slot)"
  [[ "$st" == running ]] && { echo "running"; return 0; }
  if ! [[ "$last" =~ ^[0-9]+$ ]]; then
    local us; us="$(systemctl show -p NextElapseUSecRealtime --value "$JOB_UNIT@$name.timer" 2>/dev/null || true)"
    if [[ -n "$us" && "$us" != n/a ]]; then date -d "$us" '+%F %H:%M' 2>/dev/null || echo "next tick"; else echo "next tick"; fi
    return 0
  fi
  read -r min mon <<<"$(parse_every "${J[EVERY]}")"
  if (( mon )); then date -d "$(date -d "@$last" +%Y-%m-01) $at +$mon month" '+%F %H:%M' 2>/dev/null || echo "?"
  else fmt_ts $(( last + min * 60 )); fi
}

# ---- job files ---------------------------------------------------------------
JOB_KEYS=(TYPE EVERY AT CALENDAR GUESTS EXCLUDE KEEP RETENTION VMSTATE STORAGE MODE COMPRESS MAX_USED NOTIFY)
job_file()   { echo "$SCHED_DIR/$1.conf"; }
state_file() { echo "$SCHED_STATE/$1.state"; }
job_names()  { local f; for f in "$SCHED_DIR"/*.conf; do [[ -f "$f" ]] || continue; f="${f##*/}"; echo "${f%.conf}"; done; }

v_jobname() { [[ "$1" =~ ^[a-z][a-z0-9_]{0,19}$ ]] || { echo "  Lowercase letters, digits and _, up to 20 characters, starting with a letter" >&2; return 1; }; }
v_newjob()  { v_jobname "$1" || return 1; [[ ! -e "$(job_file "$1")" ]] || { echo "  Job $1 already exists" >&2; return 1; }; }
v_every() {
  if [[ "$1" == cal:* ]]; then v_calendar "${1#cal:}"; return; fi
  parse_every "$1" >/dev/null || { echo "  Use an interval such as 10m, 30m, 1h, 10h, 24h, 1d, 1w, 1mo or 1h30m (5 minutes or more), or cal:<calendar>" >&2; return 1; }
}
v_calendar() {
  local re='^[A-Za-z0-9 ,.:/*~+-]+$'
  [[ "$1" =~ $re ]] || { echo "  Calendar: letters, digits, spaces and , . : / * ~ + -" >&2; return 1; }
  if command -v systemd-analyze >/dev/null && ! systemd-analyze calendar "$1" >/dev/null 2>&1; then
    echo "  systemd does not accept '$1' (try: systemd-analyze calendar '$1')" >&2; return 1
  fi
}
v_at()      { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "  Time as HH:MM, e.g. 02:00" >&2; return 1; }; }
v_guests()  { [[ "$1" =~ ^(all|pool:[A-Za-z0-9_.-]+|[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*)$ ]] || { echo "  all, pool:NAME, or IDs such as 100,101,200-210" >&2; return 1; }; }
v_idlist()  { [[ -z "$1" || "$1" == none || "$1" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || { echo "  IDs such as 100,105-110, or blank" >&2; return 1; }; }
v_keep()    { [[ "$1" =~ ^[0-9]{1,4}$ ]] && (( 10#$1 >= 1 )) || { echo "  A number from 1" >&2; return 1; }; }
v_pct()     { [[ "$1" =~ ^[0-9]{2}$ ]] && (( 10#$1 >= 50 )) || { echo "  A percentage from 50 to 99" >&2; return 1; }; }
v_retention() {
  local k='keep-(last|hourly|daily|weekly|monthly|yearly)=[0-9]+'
  [[ -z "$1" || "$1" == none || "$1" =~ ^$k(,$k)*$ ]] || { echo "  e.g. keep-daily=7,keep-weekly=4,keep-monthly=6 (or blank)" >&2; return 1; }
}

# job_check KEY VALUE: validates one job setting
job_check() {
  local k="$1" v="$2"
  case "$k" in
    TYPE) [[ "$v" == snapshot || "$v" == backup ]] ;;
    EVERY) [[ -z "$v" ]] || parse_every "$v" >/dev/null ;;
    AT) v_at "$v" 2>/dev/null ;;
    CALENDAR) [[ -z "$v" ]] || v_calendar "$v" 2>/dev/null ;;
    GUESTS) v_guests "$v" 2>/dev/null ;;
    EXCLUDE) [[ "$v" != none ]] && v_idlist "$v" 2>/dev/null ;;
    KEEP) v_keep "$v" 2>/dev/null ;;
    RETENTION) [[ "$v" != none ]] && v_retention "$v" 2>/dev/null ;;
    VMSTATE) [[ "$v" == 0 || "$v" == 1 ]] ;;
    STORAGE) [[ -z "$v" || "$v" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]] ;;
    MODE) [[ "$v" =~ ^(snapshot|suspend|stop)$ ]] ;;
    COMPRESS) [[ "$v" =~ ^(zstd|lzo|gzip|0)$ ]] ;;
    MAX_USED) v_pct "$v" 2>/dev/null ;;
    NOTIFY) [[ "$v" =~ ^(failure|always|never)$ ]] ;;
    *) return 1 ;;
  esac
}

job_defaults() {
  J=([NAME]="${1:-}" [TYPE]="" [EVERY]="" [AT]="02:00" [CALENDAR]="" [GUESTS]="" [EXCLUDE]="" [KEEP]="7"
     [RETENTION]="" [VMSTATE]="0" [STORAGE]="" [MODE]="snapshot" [COMPRESS]="zstd" [MAX_USED]="90" [NOTIFY]="failure")
}

# job_check_all: settings that depend on each other (J filled)
job_check_all() {
  local k
  for k in "${JOB_KEYS[@]}"; do job_check "$k" "${J[$k]}" || { echo "invalid $k=${J[$k]}" >&2; return 1; }; done
  [[ -n "${J[TYPE]}" ]] || { echo "TYPE is missing" >&2; return 1; }
  [[ -n "${J[GUESTS]}" ]] || { echo "GUESTS is missing" >&2; return 1; }
  [[ -n "${J[EVERY]}" || -n "${J[CALENDAR]}" ]] || { echo "EVERY or CALENDAR is required" >&2; return 1; }
  [[ -z "${J[EVERY]}" || -z "${J[CALENDAR]}" ]] || { echo "set EVERY or CALENDAR, not both" >&2; return 1; }
  [[ "${J[TYPE]}" != backup || -n "${J[STORAGE]}" ]] || { echo "STORAGE is required for backup jobs" >&2; return 1; }
  return 0
}

# job_load NAME: reads the job into J
job_load() {
  local name="$1" f line k v n=0
  v_jobname "$name" 2>/dev/null || { echo "Invalid job name: $name" >&2; return 1; }
  f="$(job_file "$name")"
  [[ -f "$f" ]] || { echo "Job $name not found ($f)" >&2; return 1; }
  job_defaults "$name"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$(( n + 1 )); line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || { echo "$f:$n: not KEY=value" >&2; return 1; }
    k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
    [[ "$v" == \"*\" ]] && { v="${v#\"}"; v="${v%\"}"; }
    job_check "$k" "$v" || { echo "$f:$n: invalid $k=$v" >&2; return 1; }
    J[$k]="$v"
  done <"$f"
  job_check_all || { echo "in $f" >&2; return 1; }
}

job_render() {
  local k min=0 mon=0
  [[ -n "${J[EVERY]}" ]] && read -r min mon <<<"$(parse_every "${J[EVERY]}")"
  echo "# proxmox-toolbelt scheduled ${J[TYPE]} job. Read as KEY=value (not sourced)."
  echo "# Change it with: proxmox-toolbelt schedule remove ${J[NAME]}; proxmox-toolbelt schedule add ..."
  for k in "${JOB_KEYS[@]}"; do
    [[ "${J[TYPE]}" == snapshot && "$k" =~ ^(STORAGE|MODE|COMPRESS|RETENTION)$ ]] && continue
    [[ "${J[TYPE]}" == backup && "$k" == VMSTATE ]] && continue
    [[ -n "${J[CALENDAR]}" && "$k" =~ ^(EVERY|AT)$ ]] && continue
    [[ -z "${J[CALENDAR]}" && "$k" == CALENDAR ]] && continue
    [[ "$k" == AT ]] && (( mon == 0 && min % 1440 != 0 )) && continue
    echo "$k=${J[$k]}"
  done
}

# schedule_text: "every 10 hours", "every day at 02:00", "calendar Mon..Fri 22:00" (J loaded)
schedule_text() {
  local min mon
  if [[ -n "${J[CALENDAR]}" ]]; then echo "calendar ${J[CALENDAR]}"; return 0; fi
  read -r min mon <<<"$(parse_every "${J[EVERY]}")"
  if (( mon || min % 1440 == 0 )); then echo "$(every_text "$min" "$mon") at ${J[AT]}$( (( mon )) && echo ", on the 1st")"
  else every_text "$min" "$mon"; fi
}

# ---- state -------------------------------------------------------------------
state_get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$(state_file "$1")" 2>/dev/null || true; }
# state_set NAME KEY=VALUE...: replaces those keys; written to a temp file, synced, renamed
state_set() {
  local f tmp; f="$(state_file "$1")"; shift
  mkdir -p "$SCHED_STATE"
  tmp="$(mktemp "$f.XXXXXX")"
  { [[ -f "$f" ]] && cat "$f"; true; } | SET_KV="$(printf '%s\n' "$@" | tr -d '\r')" awk '
    BEGIN { n = split(ENVIRON["SET_KV"], a, "\n"); for (i = 1; i <= n; i++) { if (a[i] == "") continue; k = a[i]; sub(/=.*/, "", k); v[k] = a[i]; o[++m] = k } }
    { k = $0; sub(/=.*/, "", k); if (!(k in v)) print }
    END { for (i = 1; i <= m; i++) print v[o[i]] }' >"$tmp"
  sync "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
}

# ---- job log -------------------------------------------------------------------
JLOG=""
jlog() {
  local l; l="$(date '+%F %T') $*"
  echo "$l"
  if [[ -n "$JLOG" ]]; then echo "$l" >>"$JLOG" || true; fi
}
# jrun CMD...: runs CMD with its output in the job log; returns its exit code. JRUN_OUT gets a copy.
JRUN_OUT=""
jrun() {
  if (( DRY_RUN )); then jlog "[dry-run] $*"; return 0; fi
  jlog "\$ $*"
  local ps=() l out="${JRUN_OUT:-/dev/null}"
  "$@" 2>&1 </dev/null | tee "$out" | while IFS= read -r l; do jlog "  $l"; done && ps=("${PIPESTATUS[@]}") || ps=("${PIPESTATUS[@]}")
  return "${ps[0]}"
}
log_notes() { local l; while IFS= read -r l; do jlog "note: $l"; done <"$JOB_TMP/notes" 2>/dev/null || true; }
log_trim() {
  [[ -f "$1" ]] || return 0
  local n; n="$(wc -l <"$1")"
  (( n > SCHED_LOG_LINES )) || return 0
  local t; t="$(mktemp "$1.XXXXXX")"
  tail -n $(( SCHED_LOG_LINES * 4 / 5 )) "$1" >"$t" && mv -f "$t" "$1"
}

# ---- guests --------------------------------------------------------------------
# expand_ids "100,101,200-203": one VMID per line
expand_ids() {
  local part a b parts=()
  IFS=, read -ra parts <<<"${1:-}"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+(-[0-9]+)?$ ]] || continue
    if [[ "$part" == *-* ]]; then
      a=$(( 10#${part%-*} )) b=$(( 10#${part#*-} ))
      (( b - a <= 10000 )) || b=$(( a + 10000 ))
      for (( ; a <= b; a++ )); do echo "$a"; done
    else echo $(( 10#$part )); fi
  done
}

guest_conf_path() { echo "$PVE_DIR/nodes/$NODE/$([[ $2 == lxc ]] && echo lxc || echo qemu-server)/$1.conf"; }

# local_guests: "vmid|qemu or lxc|name|template" for each guest on this node
local_guests() {
  local f id t info
  for f in "$PVE_DIR/nodes/$NODE/qemu-server/"*.conf "$PVE_DIR/nodes/$NODE/lxc/"*.conf; do
    [[ -f "$f" ]] || continue
    id="${f##*/}"; id="${id%.conf}"; [[ "$id" =~ ^[0-9]+$ ]] || continue
    if [[ "$f" == */lxc/* ]]; then t=lxc; else t=qemu; fi
    info="$(awk '/^\[/{exit} $1=="name:"||$1=="hostname:"{n=$2} $1=="template:"{tp=$2} END{printf "%s|%d", n, tp}' "$f")"
    echo "$id|$t|$info"
  done | sort -t'|' -k1,1n
}

# pool_members POOL: VMIDs in a resource pool
pool_members() {
  local j
  j="$(pvesh get "/pools/$1" --output-format json 2>/dev/null)" \
    || j="$(pvesh get /pools --poolid "$1" --output-format json 2>/dev/null)" || return 1
  perl -MJSON::PP -e 'local $/; my $d = eval { JSON::PP->new->decode(scalar <STDIN>) } or exit 1;
    $d = $d->[0] if ref $d eq "ARRAY"; exit 1 unless ref $d eq "HASH";
    print "$_->{vmid}\n" for grep { ref eq "HASH" && defined $_->{vmid} } @{ $d->{members} // [] }' <<<"$j"
}

# resolve_guests SPEC EXCLUDE SKIP_TEMPLATES: "vmid|type|name" for the guests on this node.
# Notes about skipped guests go to stderr.
resolve_guests() {
  local spec="$1" excl skip_tpl="${3:-0}" all wanted=() id line t name tpl pm
  excl=" $(expand_ids "${2:-}" | paste -sd' ' -) "
  all="$(local_guests)"
  case "$spec" in
    all) mapfile -t wanted < <(cut -d'|' -f1 <<<"$all") ;;
    pool:*) pm="$(pool_members "${spec#pool:}")" || { echo "Pool ${spec#pool:} not found" >&2; return 1; }
            mapfile -t wanted <<<"$pm" ;;
    *) mapfile -t wanted < <(expand_ids "$spec") ;;
  esac
  for id in "${wanted[@]}"; do
    [[ -n "$id" ]] || continue
    [[ "$excl" == *" $id "* ]] && continue
    line="$(awk -F'|' -v i="$id" '$1==i{print; exit}' <<<"$all")"
    if [[ -z "$line" ]]; then
      [[ "$spec" == pool:* ]] || echo "guest $id is not on node $NODE, skipped" >&2
      continue
    fi
    IFS='|' read -r _ t name tpl <<<"$line"
    if (( skip_tpl )) && [[ "$tpl" == 1 ]]; then
      [[ "$spec" == all || "$spec" == pool:* ]] || echo "guest $id is a template (no snapshots), skipped" >&2
      continue
    fi
    echo "$id|$t|$name"
  done
}

# storage_type STORAGE: type from storage.cfg (dir, zfspool, lvmthin, lvm, pbs, ...)
storage_type() { awk -v s="$1" '/^[a-z]+: /{t=$1; sub(/:$/, "", t); if ($2 == s) {print t; exit}}' "$PVE_DIR/storage.cfg" 2>/dev/null || true; }
storage_cfg()  { awk -v s="$1" -v k="$2" '/^[a-z]+: /{cur=$2; next} cur==s && $1==k {print $2; exit}' "$PVE_DIR/storage.cfg" 2>/dev/null || true; }

# guest_volumes CONF: "storage:volume" of each disk in the current config (no CD-ROMs, bind mounts)
guest_volumes() {
  awk '/^\[/{exit}
       $1 ~ /^(ide|sata|scsi|virtio|efidisk|tpmstate|rootfs|mp)[0-9]*:$/ && $0 !~ /media=cdrom/ {
         v = $2; sub(/,.*/, "", v); if (v ~ /^[A-Za-z][A-Za-z0-9_.-]*:/) print v }' "$1" 2>/dev/null || true
}
guest_storages() { guest_volumes "$1" | cut -d: -f1 | sort -u; }

# snap_capable CONF: prints "yes", or "no: <volume> (<type>)" for the first disk that cannot be
# snapshotted. Offline guess from the storage types; the API check at run time decides.
snap_capable() {
  local vol st type
  while IFS= read -r vol; do
    st="${vol%%:*}"; type="$(storage_type "$st")"
    case "$type" in
      zfspool|lvmthin|rbd|btrfs|zfs) ;;
      dir|nfs|cifs|glusterfs|cephfs) [[ "$vol" == *.qcow2 ]] || { echo "no: $vol is not qcow2"; return 0; } ;;
      "") ;;
      *) echo "no: $vol is on $type storage"; return 0 ;;
    esac
  done < <(guest_volumes "$1")
  echo yes
}

# snap_supported VMID TYPE: Proxmox API check. 0 yes, 1 no, 2 unknown
snap_supported() {
  local j; j="$(pvesh get "/nodes/$NODE/$2/$1/feature" --feature snapshot --output-format json 2>/dev/null)" || return 2
  [[ "$(jrows hasFeature <<<"$j")" == 1 ]] || return 1
}

backup_storages() { pvesm status --content backup 2>/dev/null | awk 'NR>1{print $1}' || true; }
is_backup_storage() { [[ $'\n'"$(backup_storages)"$'\n' == *$'\n'"$1"$'\n'* ]]; }

# storage_room STORAGE MAXPCT: fails with the reason when the storage is inactive or too full
storage_room() {
  local st="$1" max="$2" line type status total used pct meta vg pool
  line="$(pvesm status --storage "$st" 2>/dev/null | awk 'NR==2')" || true
  [[ -n "$line" ]] || { echo "storage $st not found"; return 1; }
  read -r _ type status total used _ <<<"$line"
  [[ "$status" == active ]] || { echo "storage $st is $status"; return 1; }
  pct=0; [[ "$total" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]] && (( total > 0 )) && pct=$(( used * 100 / total ))
  (( pct < max )) || { echo "storage $st is $pct% full (limit $max%)"; return 1; }
  if [[ "$type" == lvmthin ]]; then
    vg="$(storage_cfg "$st" vgname)" pool="$(storage_cfg "$st" thinpool)"
    meta="$(lvs --noheadings -o metadata_percent "$vg/$pool" 2>/dev/null | awk '{print int($1)}')" || true
    (( ${meta:-0} < max )) || { echo "thin pool $vg/$pool metadata is $meta% full (limit $max%)"; return 1; }
  fi
  return 0
}

# conf_snapshots CONF: "snaptime name snapstate" per snapshot section, oldest first
conf_snapshots() {
  awk '/^\[/ { if (n != "") print t + 0, n, s; n = substr($0, 2, length($0) - 2); t = 0; s = ""; if (n ~ /^(PENDING|special:)/) n = ""; next }
       n != "" && $1 == "snaptime:" { t = $2 }
       n != "" && $1 == "snapstate:" { s = $2 }
       END { if (n != "") print t + 0, n, s }' "$1" 2>/dev/null | sort -n
}
job_snap_re() { echo "^ptb_${1}_[0-9]{8}_[0-9]{6}\$"; }
snap_name()   { echo "ptb_${J[NAME]}_$(date +%Y%m%d_%H%M%S)"; }

quorate() {
  is_cluster || return 0
  [[ "$(pvesh get /cluster/status --output-format json 2>/dev/null | jrows type quorate | awk -F'|' '$1=="cluster"{print $2}')" == 1 ]]
}

# ---- running a job ------------------------------------------------------------------
# job_cleanup: after an interrupted run, unlock guests it left locked and remove its
# half-made snapshots. Skipped for a guest while a backup or snapshot process still runs.
job_cleanup() {
  local id t name conf lock cmd snaps re sn state
  re="$(job_snap_re "${J[NAME]}")"
  while IFS='|' read -r id t name; do
    [[ -n "$id" ]] || continue
    conf="$(guest_conf_path "$id" "$t")"; [[ "$t" == lxc ]] && cmd=pct || cmd=qm
    lock="$(awk '/^\[/{exit} $1=="lock:"{print $2}' "$conf" 2>/dev/null || true)"
    case "$lock" in
      backup)
        if pgrep -f vzdump >/dev/null 2>&1; then jlog "  $id: locked (backup) and a vzdump is running; left alone"
        else jlog "  $id: removing stale backup lock"; jrun "$cmd" unlock "$id" || true; fi ;;
      snapshot|snapshot-delete)
        if pgrep -f "(snapshot|delsnapshot):$id:|(qm|pct) (snapshot|delsnapshot) $id( |\$)" >/dev/null 2>&1; then
          jlog "  $id: locked ($lock) by a running snapshot task; left alone"
        else jlog "  $id: removing stale $lock lock"; jrun "$cmd" unlock "$id" || true; fi ;;
    esac
    snaps="$(conf_snapshots "$conf")"
    while read -r _ sn state; do
      [[ -n "${sn:-}" && -n "${state:-}" && "$sn" =~ $re ]] || continue
      jlog "  $id: removing half-made snapshot $sn ($state)"
      jrun "$cmd" delsnapshot "$id" "$sn" --force 1 || true
    done <<<"$snaps"
    if [[ -n "$lock" && "$(awk '/^\[/{exit} $1=="onboot:"{print $2}' "$conf" 2>/dev/null)" == 1 ]] \
       && ! "$cmd" status "$id" 2>/dev/null | grep -q running; then
      jlog "  $id: has onboot=1 but is stopped (it was locked at boot). Start it: $cmd start $id"
    fi
  done < <(resolve_guests "${J[GUESTS]}" "${J[EXCLUDE]}" 0 2>/dev/null || true)
}

# snap_prune ID TYPE CONF: deletes this job's oldest snapshots beyond KEEP
snap_prune() {
  local id="$1" t="$2" conf="$3" keep="${J[KEEP]}" names=() sn state cmd re n i pfail=0
  [[ "$t" == lxc ]] && cmd=pct || cmd=qm
  re="$(job_snap_re "${J[NAME]}")"
  while read -r _ sn state; do
    [[ -n "${sn:-}" && "$sn" =~ $re ]] || continue
    if [[ -n "${state:-}" ]]; then jlog "  $id: snapshot $sn is in state '$state'; not counted, not deleted"; continue; fi
    names+=("$sn")
  done < <(conf_snapshots "$conf")
  (( DRY_RUN )) && keep=$(( keep - 1 ))   # the new snapshot does not exist in a dry run
  n=$(( ${#names[@]} - keep ))
  for (( i = 0; i < n; i++ )); do
    jrun "$cmd" delsnapshot "$id" "${names[i]}" || { jlog "  $id: could not delete ${names[i]}; kept"; pfail=1; }
  done
  return "$pfail"
}

# snap_guest ID TYPE NAME: 0 ok, 1 failed, 2 ok but pruning failed, 3 skipped (no snapshot
# support, guest picked by "all" or a pool; a guest listed by ID fails instead)
snap_guest() {
  local id="$1" t="$2" gname="$3" conf cmd st reason attempt snap sup=0 args why
  conf="$(guest_conf_path "$id" "$t")"; [[ "$t" == lxc ]] && cmd=pct || cmd=qm
  snap_supported "$id" "$t" || sup=$?
  if (( sup == 1 )); then
    why="$(snap_capable "$conf" | sed 's/^no: //; s/^yes$/its storage does not support snapshots/')"
    if [[ "${J[GUESTS]}" == all || "${J[GUESTS]}" == pool:* ]]; then
      jlog "SKIP $id ${gname:+($gname)}: $why - cannot be snapshotted; back it up with a backup job"
      return 3
    fi
    jlog "FAILED $id ${gname:+($gname)}: $why - this guest cannot be snapshotted; use a backup job for it"
    return 1
  fi
  for st in $(guest_storages "$conf"); do
    reason="$(storage_room "$st" "${J[MAX_USED]}")" || { jlog "FAILED $id ${gname:+($gname)}: $reason; no snapshot taken"; return 1; }
  done
  for (( attempt = 1; attempt <= SCHED_ATTEMPTS; attempt++ )); do
    snap="$(snap_name)"
    args=("$cmd" snapshot "$id" "$snap" --description "proxmox-toolbelt job ${J[NAME]}")
    [[ "$t" == qemu && "${J[VMSTATE]}" == 1 ]] && args+=(--vmstate 1)
    if jrun "${args[@]}"; then
      jlog "OK $id ${gname:+($gname)}: $snap"
      snap_prune "$id" "$t" "$conf" || return 2
      return 0
    fi
    if (( attempt < SCHED_ATTEMPTS )); then jlog "  $id: try $attempt failed; next try in ${SCHED_RETRY_WAIT}s"; sleep "$SCHED_RETRY_WAIT"; fi
  done
  jlog "FAILED $id ${gname:+($gname)}: snapshot failed $SCHED_ATTEMPTS times"
  return 1
}

# run_snapshots: snapshot each guest; prints the summary on fd 3. 0 ok, 1 failed, 2 warnings
run_snapshots() {
  local guests id t name ok=0 failed=() warned=() skipped=() rc
  guests="$(resolve_guests "${J[GUESTS]}" "${J[EXCLUDE]}" 1 2>"$JOB_TMP/notes")" || { log_notes; echo "guest list failed" >&3; return 1; }
  log_notes
  if [[ -z "$guests" ]]; then jlog "No guests on $NODE match '${J[GUESTS]}'"; echo "no guests" >&3; return 2; fi
  while IFS='|' read -r id t name; do
    rc=0; snap_guest "$id" "$t" "$name" || rc=$?
    case "$rc" in 0) ok=$(( ok + 1 )) ;; 2) ok=$(( ok + 1 )); warned+=("$id") ;; 3) skipped+=("$id") ;; *) failed+=("$id") ;; esac
  done <<<"$guests"
  echo "$ok snapshot(s)${failed[*]:+, failed: ${failed[*]}}${warned[*]:+, pruning failed: ${warned[*]}}${skipped[*]:+, skipped (no snapshot support): ${skipped[*]}}" >&3
  if (( ${#failed[@]} )); then return 1; elif (( ${#warned[@]} )); then return 2; fi
  return 0
}

# run_backup: one vzdump run; failed guests are tried again. 0 ok, 1 failed, 2 warnings
run_backup() {
  local st="${J[STORAGE]}" reason guests ids=() id attempt out failed=() type args
  reason="$(storage_room "$st" "${J[MAX_USED]}")" || { jlog "FAILED: $reason; no backup started"; echo "$reason" >&3; return 1; }
  if ! is_backup_storage "$st"; then
    jlog "FAILED: storage $st does not allow backups (content 'VZDump backup file')"; echo "storage $st has no backup content" >&3; return 1
  fi
  guests="$(resolve_guests "${J[GUESTS]}" "${J[EXCLUDE]}" 0 2>"$JOB_TMP/notes")" || { log_notes; echo "guest list failed" >&3; return 1; }
  log_notes
  mapfile -t ids < <(cut -d'|' -f1 <<<"$guests" | grep .)
  if (( ${#ids[@]} == 0 )); then jlog "No guests on $NODE match '${J[GUESTS]}'"; echo "no guests" >&3; return 2; fi
  type="$(storage_type "$st")"
  out="$JOB_TMP/vzdump.out"
  for (( attempt = 1; attempt <= SCHED_ATTEMPTS; attempt++ )); do
    args=(vzdump "${ids[@]}" --storage "$st" --mode "${J[MODE]}"
          --prune-backups "${J[RETENTION]:-keep-last=${J[KEEP]}}"
          --notes-template "{{guestname}} (proxmox-toolbelt job ${J[NAME]})")
    [[ "$type" == pbs ]] || args+=(--compress "${J[COMPRESS]}")
    if JRUN_OUT="$out" jrun "${args[@]}"; then
      echo "${#ids[@]} guest(s) backed up to $st$( (( attempt > 1 )) && echo " (after $attempt tries)")" >&3
      return 0
    fi
    mapfile -t failed < <(grep -oE 'Backup of VM [0-9]+ failed' "$out" 2>/dev/null | grep -oE '[0-9]+' | sort -un)
    (( ${#failed[@]} )) && ids=("${failed[@]}")
    if (( attempt < SCHED_ATTEMPTS )); then jlog "  try $attempt failed${failed[*]:+ for ${failed[*]}}; next try in ${SCHED_RETRY_WAIT}s"; sleep "$SCHED_RETRY_WAIT"; fi
  done
  echo "backup failed for ${ids[*]}" >&3
  return 1
}

job_notify() { # NAME STATUS SUMMARY
  local mode="${J[NOTIFY]}" sm
  [[ "$mode" == never ]] && return 0
  [[ "$mode" == always || "$2" != ok ]] || return 0
  if command -v sendmail >/dev/null; then sm=sendmail
  elif [[ -x /usr/sbin/sendmail ]]; then sm=/usr/sbin/sendmail
  else jlog "no sendmail; notification not sent"; return 0; fi
  {
    printf 'To: root\nSubject: [%s] %s job %s: %s\n\n' "$NODE" "${J[TYPE]}" "$1" "$2"
    printf '%s\n\nLog: %s\nLast lines:\n\n' "$3" "$JLOG"
    tail -n 60 "$JLOG" 2>/dev/null
  } | "$sm" -i root 2>/dev/null || jlog "could not send the notification mail"
}

job_locked() { ! flock -n "$1" true 2>/dev/null; }

# job_exec NAME SLOT MANUAL: one run under the job lock. Sets JOB_RESULT (ok, warning, failed,
# busy, dry-run). Called as a plain command: under "if" or "||" bash ignores set -e in the run.
JOB_RESULT="" JOB_TMP=""
job_exec() {
  local name="$1" slot="$2" manual="${3:-0}" lockf fd start end rc st summary sf
  JOB_RESULT=""
  job_load "$name" || exit 1
  JOB_TMP="$(mktemp -d)"; TMP_DIRS+=("$JOB_TMP")
  if (( DRY_RUN )); then
    JLOG=""
    jlog "[dry-run] ${J[TYPE]} job $name ($(schedule_text)), guests ${J[GUESTS]}${J[EXCLUDE]:+ except ${J[EXCLUDE]}}"
    sf="$JOB_TMP/summary"
    if [[ "${J[TYPE]}" == snapshot ]]; then run_snapshots 3>"$sf" || true; else run_backup 3>"$sf" || true; fi
    jlog "[dry-run] result: $(cat "$sf")"
    JOB_RESULT=dry-run
    return 0
  fi
  mkdir -p "$SCHED_LOG" "$SCHED_STATE" "$SCHED_LOCKS"
  JLOG="$SCHED_LOG/$name.log"
  lockf="$SCHED_LOCKS/$JOB_UNIT-$name.lock"
  exec {fd}>>"$lockf"
  if ! flock -n "$fd"; then
    jlog "Job $name is already running (lock $lockf); this start is skipped"
    exec {fd}>&-
    JOB_RESULT=busy
    return 0
  fi
  if [[ "$(state_get "$name" status)" == running ]]; then
    jlog "WARN: the run started $(fmt_ts "$(state_get "$name" last_start)") did not finish (reboot, crash or kill). Cleaning up, then running again."
    job_cleanup
  fi
  start="$(date +%s)"
  state_set "$name" status=running "last_start=$start"
  jlog "=== ${J[TYPE]} job $name started$( (( manual )) && echo " by hand"): $(schedule_text), guests ${J[GUESTS]}${J[EXCLUDE]:+ except ${J[EXCLUDE]}}, keep ${J[RETENTION]:-${J[KEEP]}}"
  sf="$JOB_TMP/summary"; : >"$sf"
  if ! quorate; then
    jlog "FAILED: the cluster is not quorate (/etc/pve is read-only)"; echo "cluster not quorate" >"$sf"; rc=1
  else
    set +e
    ( set -e; if [[ "${J[TYPE]}" == snapshot ]]; then run_snapshots; else run_backup; fi ) 3>"$sf"
    rc=$?
    set -e
  fi
  end="$(date +%s)"
  summary="$(tr '\n' ' ' <"$sf" | sed 's/ *$//')"
  case "$rc" in
    0) st=ok ;; 2) st=warning ;;
    *) st=failed; [[ -n "$summary" ]] || summary="stopped with exit code $rc" ;;
  esac
  local upd=(status="$st" "last_end=$end" "last_rc=$rc" "message=$summary" "duration=$(( end - start ))")
  (( manual )) || upd+=("last_slot=$slot")
  if [[ "$st" == failed ]]; then upd+=("fails=$(( $(state_get "$name" fails || echo 0) + 1 ))"); else upd+=("last_ok=$end" "fails=0"); fi
  state_set "$name" "${upd[@]}"
  jlog "=== job $name: $st in $(( end - start ))s: $summary"
  job_notify "$name" "$st" "$summary"
  log_trim "$JLOG"
  exec {fd}>&-
  JOB_RESULT="$st"
  return 0
}

# job_tick NAME: timer entry point; runs the job when it is due
job_tick() {
  local name="$1" min mon tick cal now slot last st
  JOB_RESULT=""
  job_load "$name" || exit 1
  if [[ -n "${J[CALENDAR]}" ]]; then job_exec "$name" "$(sched_now)" 0; return 0; fi
  read -r min mon <<<"$(parse_every "${J[EVERY]}")"
  IFS='|' read -r tick cal <<<"$(sched_tick "$min" "$mon" "${J[AT]}")"
  now="$(sched_now)"; slot="$(sched_slot "$now" "$tick" "${J[AT]}")"
  last="$(state_get "$name" last_slot)"; st="$(state_get "$name" status)"
  if [[ "$st" != running ]] && ! sched_due "$slot" "$last" "$min" "$mon" "$tick"; then JOB_RESULT=not-due; return 0; fi
  job_exec "$name" "$slot" 0
}

# sched_recover: at boot, starts every job whose last run was cut short
sched_recover() {
  local name
  while IFS= read -r name; do
    [[ "$(state_get "$name" status)" == running ]] || continue
    job_locked "$SCHED_LOCKS/$JOB_UNIT-$name.lock" && continue
    echo "Job $name was interrupted at $(fmt_ts "$(state_get "$name" last_start)"); starting it again"
    systemctl start --no-block "$JOB_UNIT@$name.service" || echo "Could not start $JOB_UNIT@$name.service" >&2
  done < <(job_names)
}

# ---- systemd units -------------------------------------------------------------------
unit_service() {
  cat <<EOF
# Written by proxmox-toolbelt. Runs one scheduled snapshot or backup job.
[Unit]
Description=proxmox-toolbelt scheduled job %i
Documentation=https://github.com/cfunkz/Proxmox-Toolbelt
After=pve-cluster.service pve-guests.service pvestatd.service network-online.target remote-fs.target
ConditionPathExists=$SCHED_DIR/%i.conf
ConditionPathExists=|${SCHED_PROGS[0]}
ConditionPathExists=|${SCHED_PROGS[1]}

[Service]
Type=oneshot
ExecStart=/usr/bin/env proxmox-toolbelt schedule tick %i
Nice=10
TimeoutStopSec=10min
EOF
}

unit_recover() {
  cat <<EOF
# Written by proxmox-toolbelt. Restarts scheduled jobs that a reboot or crash interrupted.
[Unit]
Description=proxmox-toolbelt: resume interrupted scheduled jobs
After=pve-cluster.service pve-guests.service pvestatd.service network-online.target remote-fs.target
ConditionDirectoryNotEmpty=$SCHED_DIR
ConditionPathExists=|${SCHED_PROGS[0]}
ConditionPathExists=|${SCHED_PROGS[1]}

[Service]
Type=oneshot
ExecStart=/usr/bin/env proxmox-toolbelt schedule recover

[Install]
WantedBy=multi-user.target
EOF
}

unit_timer() { # J loaded
  local cal min mon
  if [[ -n "${J[CALENDAR]}" ]]; then cal="${J[CALENDAR]}"
  else read -r min mon <<<"$(parse_every "${J[EVERY]}")"; cal="$(sched_tick "$min" "$mon" "${J[AT]}")"; cal="${cal#*|}"; fi
  cat <<EOF
# Written by proxmox-toolbelt. Job settings: $(job_file "${J[NAME]}")
# The timer ticks on this grid; each tick runs the job only when it is due ($(schedule_text)).
[Unit]
Description=proxmox-toolbelt ${J[TYPE]} job ${J[NAME]}: $(schedule_text)

[Timer]
OnCalendar=$cal
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

# sched_put PATH MODE < content: atomic write (dry run: shows the content)
sched_put() {
  local p="$1" m="$2" t
  if (( DRY_RUN )); then echo "${C_D}[dry-run] would write $p:${C_0}"; sed 's/^/    /'; return 0; fi
  mkdir -p "$(dirname "$p")"
  t="$(mktemp "$p.XXXXXX")"; cat >"$t"; chmod "$m" "$t"; mv -f "$t" "$p"
  log "Wrote $p"
}

# sched_prog: the installed proxmox-toolbelt that the timers run
sched_prog() { local p; for p in "${SCHED_PROGS[@]}"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; return 1; }
sched_require_prog() {
  local p
  if p="$(sched_prog)"; then
    grep -q 'schedule tick' "$p" 2>/dev/null && return 0
    warn "$p is an older proxmox-toolbelt without scheduled jobs; the timers would fail."
  else
    warn "The timers need proxmox-toolbelt installed as ${SCHED_PROGS[1]} (package) or ${SCHED_PROGS[0]}."
  fi
  if [[ -t 0 && -z "$(pkg_version)" ]]; then fix_install; sched_prog >/dev/null && grep -q 'schedule tick' "$(sched_prog)" && return 0; fi
  (( DRY_RUN )) && return 0
  die "Install or update proxmox-toolbelt first (menu 8.2 or the .deb package)"
}

# job_install: writes the job file and units, enables the timer (J filled and checked)
job_install() {
  local name="${J[NAME]}"
  job_render | sched_put "$(job_file "$name")" 644
  unit_service | sched_put "$UNIT_DIR/$JOB_UNIT@.service" 644
  unit_recover | sched_put "$UNIT_DIR/$RECOVER_UNIT" 644
  unit_timer | sched_put "$UNIT_DIR/$JOB_UNIT@$name.timer" 644
  run systemctl daemon-reload
  run systemctl enable --now "$JOB_UNIT@$name.timer"
  run systemctl enable "$RECOVER_UNIT"
}

# job_remove NAME: timer, job file and state; the log and the snapshots/backups stay
run_soft() { if (( DRY_RUN )); then run "$@"; else "$@" || warn "Command failed: $*"; fi; }
job_remove() {
  local name="$1"
  run_soft systemctl disable --now "$JOB_UNIT@$name.timer"
  run rm -f "$UNIT_DIR/$JOB_UNIT@$name.timer" "$(job_file "$name")" "$(state_file "$name")"
  if [[ -z "$(job_names | grep -vx "$name" || true)" ]]; then
    run_soft systemctl disable "$RECOVER_UNIT"
    run rm -f "$UNIT_DIR/$RECOVER_UNIT" "$UNIT_DIR/$JOB_UNIT@.service"
  fi
  run systemctl daemon-reload
}

# ---- views and wizards ------------------------------------------------------------------
view_schedules() {
  hdr "Scheduled snapshots and backups on $NODE"
  local names name st when
  names="$(job_names)"
  if [[ -z "$names" ]]; then
    hint "No jobs yet. Add one with 5.4 (snapshots) or 5.5 (backups)."
    return 0
  fi
  printf '  %-16s %-8s %-28s %-14s %-12s %-16s %-8s %s\n' JOB TYPE SCHEDULE GUESTS KEEP "LAST RUN" RESULT NEXT
  while IFS= read -r name; do
    if ! job_load "$name" 2>/dev/null; then printf '  %-16s %s\n' "$name" "${C_R}invalid job file $(job_file "$name")${C_0}"; continue; fi
    st="$(state_get "$name" status)"
    local col="$C_G"; case "$st" in failed) col="$C_R" ;; warning|running) col="$C_Y" ;; "") col="$C_D"; st=never ;; esac
    when="$(next_due_text "$name")"
    printf '  %-16s %-8s %-28.28s %-14.14s %-12.12s %-16s %s%-8s%s %s\n' "$name" "${J[TYPE]}" "$(schedule_text)" \
      "${J[GUESTS]}${J[EXCLUDE]:+ -${J[EXCLUDE]}}" "${J[RETENTION]:-${J[KEEP]}}" "$(fmt_ts "$(state_get "$name" last_start)")" \
      "$col" "$st" "$C_0" "$when"
    local msg; msg="$(state_get "$name" message)"
    [[ -n "$msg" ]] && printf '  %s%-16s %s%s\n' "$C_D" "" "$msg" "$C_0"
  done <<<"$names"
  echo
  hint "Timers: systemctl list-timers '$JOB_UNIT@*'   Logs: $SCHED_LOG/<job>.log"
  hint "Snapshots are named ptb_<job>_<date>_<time> and show in the guest's Snapshots tab."
}

job_status() {
  local name="$1"
  job_load "$name" || return 1
  hdr "Job $name"
  job_render | grep -v '^#' | sed 's/^/  /'
  echo
  local k
  for k in status last_start last_end duration message last_ok fails; do
    local v; v="$(state_get "$name" "$k")"
    [[ "$k" =~ ^last_(start|end|ok)$ ]] && v="$(fmt_ts "$v")"
    printf '  %-11s %s\n' "$k" "${v:--}"
  done
  printf '  %-11s %s\n' timer "$(systemctl is-enabled "$JOB_UNIT@$name.timer" 2>/dev/null || echo missing), $(systemctl is-active "$JOB_UNIT@$name.timer" 2>/dev/null || true)"
  printf '  %-11s %s\n' next "$(next_due_text "$name")"
  echo; echo "${C_B}Last log lines${C_0} ($SCHED_LOG/$name.log)"
  tail -n 15 "$SCHED_LOG/$name.log" 2>/dev/null | sed 's/^/  /' || hint "no runs yet"
}

add_snapshot_job() { sched_wizard snapshot; }
add_backup_job()   { sched_wizard backup; }

sched_wizard() {
  local type="$1" id t name tpl conf n=0 sup
  need_root
  sched_require_prog
  hdr "New scheduled $type job"
  if [[ "$type" == snapshot ]]; then
    hint "Proxmox snapshots: ZFS snapshots on ZFS, thin snapshots on LVM-thin, qcow2 snapshots on"
    hint "directory/NFS storage. Plain LVM and raw disk files cannot be snapshotted: use a backup job."
    hint "A snapshot lives on the same disks as the guest. It is not a backup."
  else
    hint "vzdump backups to a backup storage (directory, NFS, CIFS or Proxmox Backup Server)."
    hint "Works for guests on any storage, including ZFS and plain LVM."
  fi
  echo
  printf '  %-6s %-3s %-24s %s\n' ID T NAME "$([[ $type == snapshot ]] && echo SNAPSHOTS || echo DISKS)"
  while IFS='|' read -r id t name tpl; do
    [[ -n "$id" ]] || continue
    n=$(( n + 1 )); conf="$(guest_conf_path "$id" "$t")"
    if [[ "$type" == snapshot ]]; then
      if [[ "$tpl" == 1 ]]; then sup="${C_D}template, skipped${C_0}"
      else sup="$(snap_capable "$conf")"; [[ "$sup" == yes ]] && sup="${C_G}yes${C_0}" || sup="${C_Y}$sup${C_0}"; fi
    else sup="$(guest_storages "$conf" | paste -sd, -)"; fi
    printf '  %-6s %-3s %-24.24s %s\n' "$id" "$([[ $t == lxc ]] && echo CT || echo VM)" "${name:--}" "$sup"
  done < <(local_guests)
  (( n )) || die "No VMs or containers on $NODE"
  echo
  job_defaults ""
  J[TYPE]="$type"
  local g ex resolved
  while true; do
    ask g "Guests: all, pool:NAME, or IDs such as 100,101,200-210" all v_guests
    ex=""
    [[ "$g" == all || "$g" == pool:* ]] && ask ex "Leave out (IDs, blank for none)" none v_idlist
    [[ "$ex" == none ]] && ex=""
    resolved="$(resolve_guests "$g" "$ex" "$([[ $type == snapshot ]] && echo 1 || echo 0)")" || continue
    [[ -n "$resolved" ]] && break
    echo "  No guest on $NODE matches" >&2
  done
  J[GUESTS]="$g" J[EXCLUDE]="$ex"
  if [[ "$type" == snapshot ]]; then
    local nos=() c
    while IFS='|' read -r id t _; do
      c="$(snap_capable "$(guest_conf_path "$id" "$t")")"; [[ "$c" == yes ]] || nos+=("$id")
    done <<<"$resolved"
    if (( ${#nos[@]} )); then
      if [[ "$g" == all || "$g" == pool:* ]]; then warn "No snapshot support for ${nos[*]}: these are skipped (cover them with a backup job)."
      else warn "No snapshot support for ${nos[*]}: each run will report them as failed. Use a backup job for them."; fi
    fi
  fi
  log "Guests now: $(cut -d'|' -f1 <<<"$resolved" | paste -sd' ' -)$([[ $g == all || $g == pool:* ]] && echo " (guests added later are included)")"

  echo
  hint "Interval: 10m 30m 1h 6h 10h 24h 1d 1w 1mo, or combinations such as 1h30m (m = minutes, mo = months)."
  hint "Or a systemd calendar: cal:Mon..Fri 22:00, cal:*-*-01 03:00 (see: man systemd.time)."
  local every min mon
  ask every "Run every" "$([[ $type == snapshot ]] && echo 1h || echo 1d)" v_every
  if [[ "$every" == cal:* ]]; then
    J[CALENDAR]="${every#cal:}"
  else
    J[EVERY]="${every,,}"
    read -r min mon <<<"$(parse_every "$every")"
    if (( mon || min % 1440 == 0 )); then
      ask "J[AT]" "At (HH:MM)" "$([[ $type == snapshot ]] && echo 01:00 || echo 02:00)" v_at
      (( mon )) && hint "Month intervals run on the 1st of the month; the first run is at the next ${J[AT]}."
    fi
  fi

  echo
  local kdef=7
  if [[ "$type" == snapshot && -z "${J[CALENDAR]}" ]]; then
    if (( mon )); then kdef=3; elif (( min < 1440 )); then kdef=24; elif (( min % 10080 == 0 )); then kdef=4; fi
  fi
  ask "J[KEEP]" "Keep how many ${type}s per guest (oldest are deleted)" "$kdef" v_keep
  if [[ "$type" == backup ]]; then
    hint "Instead of keep-last, Proxmox retention rules can be used, e.g. keep-daily=7,keep-weekly=4,keep-monthly=6."
    hint "Retention counts every backup of a guest on that storage, also those made by other jobs or by hand."
    ask "J[RETENTION]" "Retention rules (blank = keep-last=${J[KEEP]})" none v_retention
    [[ "${J[RETENTION]}" == none ]] && J[RETENTION]=""

    local opts=() s ty stt tot used avail def=""
    while read -r s ty stt tot used avail _; do
      [[ -n "$s" ]] || continue
      opts+=("$s|$ty, $stt, $(human_gib "${avail:-0}") free"); [[ -z "$def" || "$ty" == pbs ]] && def="$s"
    done < <(pvesm status --content backup 2>/dev/null | awk 'NR>1')
    (( ${#opts[@]} )) || die "No storage allows backups. Add one: Datacenter > Storage > Add (Directory, NFS, PBS) with content 'VZDump backup file'."
    menu "J[STORAGE]" "Backup storage" "$def" "${opts[@]}"
    menu "J[MODE]" "Backup mode" snapshot "snapshot|no downtime (recommended)" "suspend|short pause of the guest" "stop|guest is shut down during the backup"
    [[ "$(storage_type "${J[STORAGE]}")" == pbs ]] || menu "J[COMPRESS]" "Compression" zstd "zstd|fast, good ratio" "gzip|" "lzo|" "0|none"
  else
    ask_yn "Include VM RAM in snapshots (vmstate: slower, uses as much space as the RAM)?" n && J[VMSTATE]=1
  fi
  ask "J[MAX_USED]" "Skip the run when the storage is at least this full (%)" 90 v_pct
  menu "J[NOTIFY]" "Mail root@pam when" failure "failure|the run fails or partly fails" "always|after every run" "never|no mail"

  local defname; defname="$([[ $type == snapshot ]] && echo snap || echo backup)_$(tr -c 'a-z0-9\n' '_' <<<"${J[EVERY]:-cal}" | tr -s _ | sed 's/_$//')"
  v_newjob "$defname" 2>/dev/null || defname="${defname}_2"
  ask "J[NAME]" "Job name" "$defname" v_newjob
  job_check_all || die "Invalid settings"

  hdr "Summary"
  job_render | grep -v '^#' | sed 's/^/  /'
  echo
  hint "Runs $(schedule_text); missed runs (node off) run right after boot; interrupted runs run again."
  [[ "$type" == snapshot ]] && hint "Snapshot names: ptb_${J[NAME]}_YYYYMMDD_HHMMSS. Only these are pruned; other snapshots are never touched."
  hint "Files: $(job_file "${J[NAME]}"), $UNIT_DIR/$JOB_UNIT@${J[NAME]}.timer"
  confirm "Create job ${J[NAME]}?" || return 0
  job_install
  (( DRY_RUN )) && return 0
  log "Job ${J[NAME]} created. Next: $(next_due_text "${J[NAME]}")"
  ask_yn "Run it once now to test it (the output is also logged)?" y || return 0
  job_exec "${J[NAME]}" "" 1
}

manage_jobs() {
  need_root
  local names opts=() name
  view_schedules
  names="$(job_names)"
  [[ -n "$names" ]] || return 0
  while IFS= read -r name; do opts+=("$name"); done <<<"$names"
  echo
  menu name "Job" "${opts[0]}" "${opts[@]}"
  local on=0 act; systemctl is-enabled --quiet "$JOB_UNIT@$name.timer" 2>/dev/null && on=1
  menu act "Action" status "status|settings, last run and log" "run|run it now" "test|dry run: show what it would do" \
    "$( (( on )) && echo "pause|stop the timer" || echo "resume|start the timer")" "remove|delete the job (snapshots and backups stay)"
  case "$act" in
    status) job_status "$name" ;;
    run) job_exec "$name" "" 1 ;;
    test) DRY_RUN=1 job_exec "$name" "" 1 ;;
    pause) run systemctl disable --now "$JOB_UNIT@$name.timer" ;;
    resume) run systemctl enable --now "$JOB_UNIT@$name.timer" ;;
    remove)
      job_load "$name" || true
      local snaps=() id t re sn state
      if [[ "${J[TYPE]:-}" == snapshot ]]; then
        re="$(job_snap_re "$name")"
        while IFS="|" read -r id t _; do
          while read -r _ sn state; do [[ -n "${sn:-}" && "$sn" =~ $re ]] && snaps+=("$id|$t|$sn"); done < <(conf_snapshots "$(guest_conf_path "$id" "$t")")
        done < <(resolve_guests all "" 0 2>/dev/null)
      fi
      confirm "Remove job $name?" || return 0
      job_remove "$name"
      if (( ${#snaps[@]} )) && confirm "Also delete the ${#snaps[@]} snapshot(s) this job made?"; then
        local s; for s in "${snaps[@]}"; do IFS='|' read -r id t sn <<<"$s"; run "$([[ $t == lxc ]] && echo pct || echo qm)" delsnapshot "$id" "$sn"; done
      fi
      log "Removed $name. Its log stays in $SCHED_LOG/$name.log" ;;
  esac
}

chk_schedule() {
  local names name st n=0 bad=() off=() late=() min mon last_end
  names="$(job_names 2>/dev/null)"
  [[ -n "$names" ]] || return 0
  while IFS= read -r name; do
    n=$(( n + 1 ))
    if ! job_load "$name" 2>/dev/null; then bad+=("$name (invalid file)"); continue; fi
    st="$(state_get "$name" status)"
    systemctl is-enabled --quiet "$JOB_UNIT@$name.timer" 2>/dev/null || off+=("$name")
    [[ "$st" == failed || "$st" == warning ]] && bad+=("$name ($st)")
    last_end="$(state_get "$name" last_end)"
    if [[ -n "${J[EVERY]}" && "$last_end" =~ ^[0-9]+$ ]]; then
      read -r min mon <<<"$(parse_every "${J[EVERY]}")"
      (( mon )) && min=$(( mon * 31 * 1440 ))
      (( $(sched_now) - last_end > min * 120 + 7200 )) && late+=("$name")
    fi
    detail "Scheduled" "$name: ${J[TYPE]} $(schedule_text), last $(fmt_ts "$(state_get "$name" last_start)") ${st:-never}"
  done <<<"$names"
  if (( ${#bad[@]} )); then res WARN "Scheduled jobs" "${#bad[@]} of $n need attention: ${bad[*]}" 5.3
  elif (( ${#late[@]} )); then res WARN "Scheduled jobs" "overdue: ${late[*]}" 5.3
  else res OK "Scheduled jobs" "$n job(s)$( (( ${#off[@]} )) && echo ", paused: ${off[*]}"), last runs OK"; fi
  return 0
}

# ---- command line ----------------------------------------------------------------------
sched_usage() {
  cat <<EOF
proxmox-toolbelt schedule - scheduled snapshots and backups (systemd timers, survive reboots)

  schedule list
  schedule add snapshot NAME --every 1h --guests all [--exclude 105] [--keep 24] [--vmstate]
  schedule add backup NAME --every 1d --at 02:00 --guests 100,101 --storage local [--keep 7]
           [--retention keep-daily=7,keep-weekly=4] [--mode snapshot|suspend|stop] [--compress zstd]
  schedule run NAME [--dry-run]     run now (ignores the interval), output on the terminal
  schedule status NAME              settings, last result, next run, log tail
  schedule log NAME [LINES]
  schedule pause NAME | resume NAME
  schedule remove NAME              the snapshots and backups it made are kept

  --every   10m 30m 1h 10h 24h 1d 2w 1mo 1h30m (m = minutes, mo = months; at least 5m)
  --calendar SPEC   systemd calendar instead of --every, e.g. 'Mon..Fri 22:00'
  --at HH:MM        time of day for intervals in whole days, weeks or months (default 02:00)
  --guests  all | pool:NAME | 100,101,200-210        --exclude IDs (with all or pool:)
  --max-used PCT    skip the run when the storage is PCT% full or more (default 90)
  --notify failure|always|never   mail to root (forwarded to root@pam's address)
  --dry-run         show what would be written or run
EOF
}

sched_cli() {
  local cmd="${1:-list}"; (( $# )) && shift
  local args=() a
  for a in "$@"; do case "$a" in --dry-run|-n) DRY_RUN=1 ;; *) args+=("$a") ;; esac; done
  set -- "${args[@]}"
  case "$cmd" in
    list|ls) view_schedules ;;
    tick) [[ -n "${1:-}" ]] || die "schedule tick NAME"
          job_tick "$1"; [[ "$JOB_RESULT" != failed ]] || exit 1 ;;
    run) [[ -n "${1:-}" ]] || die "schedule run NAME"
         job_exec "$1" "" 1
         case "$JOB_RESULT" in failed) exit 1 ;; busy) exit 75 ;; esac ;;
    status) [[ -n "${1:-}" ]] || die "schedule status NAME"; job_status "$1" ;;
    log) [[ -n "${1:-}" ]] || die "schedule log NAME [LINES]"; v_jobname "$1" || exit 1
         tail -n "${2:-100}" "$SCHED_LOG/$1.log" 2>/dev/null || die "No log for $1 yet" ;;
    pause|disable) job_load "${1:-}" || exit 1; run systemctl disable --now "$JOB_UNIT@$1.timer" ;;
    resume|enable) job_load "${1:-}" || exit 1; sched_require_prog; run systemctl enable --now "$JOB_UNIT@$1.timer" ;;
    remove|rm) job_load "${1:-}" || exit 1; job_remove "$1"; log "Removed job $1 (snapshots, backups and $SCHED_LOG/$1.log are kept)" ;;
    recover) sched_recover ;;
    add) sched_cli_add "$@" ;;
    help|--help|-h) sched_usage ;;
    *) sched_usage >&2; die "Unknown schedule command: $cmd" ;;
  esac
}

sched_cli_add() {
  local type="${1:-}" name="${2:-}"
  [[ "$type" == snapshot || "$type" == backup ]] || die "schedule add snapshot|backup NAME ..."
  v_newjob "$name" || exit 1
  shift 2
  job_defaults "$name"; J[TYPE]="$type"
  [[ "$type" == snapshot ]] && J[AT]="01:00"
  while (( $# )); do
    case "$1" in
      --every) J[EVERY]="${2:-}"; shift ;;
      --calendar) J[CALENDAR]="${2:-}"; shift ;;
      --at) J[AT]="${2:-}"; shift ;;
      --guests) J[GUESTS]="${2:-}"; shift ;;
      --exclude) J[EXCLUDE]="${2:-}"; shift ;;
      --keep) J[KEEP]="${2:-}"; shift ;;
      --retention) J[RETENTION]="${2:-}"; shift ;;
      --storage) J[STORAGE]="${2:-}"; shift ;;
      --mode) J[MODE]="${2:-}"; shift ;;
      --compress) J[COMPRESS]="${2:-}"; shift ;;
      --max-used) J[MAX_USED]="${2:-}"; shift ;;
      --notify) J[NOTIFY]="${2:-}"; shift ;;
      --vmstate) J[VMSTATE]=1 ;;
      *) die "Unknown option for schedule add: $1" ;;
    esac
    shift
  done
  [[ -z "${J[EVERY]}" ]] || parse_every "${J[EVERY]}" >/dev/null || { v_every "${J[EVERY]}"; exit 1; }
  J[EVERY]="${J[EVERY],,}"
  job_check_all || die "Invalid job settings (see: proxmox-toolbelt schedule help)"
  local resolved
  resolved="$(resolve_guests "${J[GUESTS]}" "${J[EXCLUDE]}" "$([[ $type == snapshot ]] && echo 1 || echo 0)")" || exit 1
  [[ -n "$resolved" ]] || warn "No guest on $NODE matches '${J[GUESTS]}' yet"
  if [[ "$type" == snapshot ]]; then
    local id t c
    while IFS='|' read -r id t _; do
      [[ -n "$id" ]] || continue
      c="$(snap_capable "$(guest_conf_path "$id" "$t")")"
      [[ "$c" == yes ]] || warn "Guest $id: $c - it cannot be snapshotted; use a backup job for it"
    done <<<"$resolved"
  else
    is_backup_storage "${J[STORAGE]}" || die "Storage ${J[STORAGE]} does not exist or does not allow backups (content 'VZDump backup file')"
  fi
  sched_require_prog
  job_install
  (( DRY_RUN )) || log "Job $name: ${J[TYPE]} $(schedule_text). Test it now: proxmox-toolbelt schedule run $name"
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
v_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "  Enter an e-mail address" >&2; return 1; }; }
v_tname() { [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]{1,31}$ ]] || { echo "  Letters, digits, - and _, starting with a letter" >&2; return 1; }; }
v_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) || { echo "  Port 1-65535" >&2; return 1; }; }

root_email() { pj /access/users | jrows userid email | awk -F'|' '$1=="root@pam"{print $2}'; }

fix_root_email() {
  hdr "E-mail address for root@pam"
  hint "Recipient of the built-in mail-to-root target."
  local cur; cur="$(root_email)"
  local e; ask e "E-mail" "$cur" v_email
  [[ "$e" == "$cur" ]] && { log "Unchanged"; return 0; }
  confirm "Set the root@pam e-mail to $e${cur:+ (replaces $cur)}?" || return 0
  run pveum user modify root@pam --email "$e"
  (( DRY_RUN )) || log "root@pam e-mail set to $e"
}

offer_test_and_matcher() {
  local name="$1"
  if ask_yn "Send a test notification through $name now?" y; then run pvesh create "/cluster/notifications/targets/$name/test"; (( DRY_RUN )) || log "Test notification sent"; fi
  ask_yn "Create an alert rule that sends warnings and errors to $name?" y && fix_matcher "$name"
  return 0
}

fix_smtp() {
  hdr "Add an SMTP (e-mail) target"
  local preset; menu preset "Mail provider" gmail \
    "gmail|smtp.gmail.com, needs a Google app password" "outlook|smtp-mail.outlook.com" "custom|any SMTP server"
  local server port mode
  case "$preset" in
    gmail) server=smtp.gmail.com port=587 mode=starttls ;;
    outlook) server=smtp-mail.outlook.com port=587 mode=starttls ;;
    custom) ask server "SMTP server" "" v_any; ask port "Port" 587 v_port
            menu mode "Encryption" starttls "starttls|STARTTLS (port 587)" "tls|TLS (port 465)" "insecure|none" ;;
  esac
  local name user pass from to
  ask name "Target name" "smtp-$preset" v_tname
  ask user "Username (full e-mail address)" "" v_any
  ask_secret pass "Password$([[ $preset == gmail ]] && echo " (app password from myaccount.google.com/apppasswords)")"
  ask from "From address" "$user" v_email
  local cur; cur="$(root_email)"
  ask to "Send to" "${cur:-$user}" v_email
  log "Creating SMTP target $name ($server:$port, $mode)"
  run pvesh create /cluster/notifications/endpoints/smtp --name "$name" --server "$server" --port "$port" \
    --mode "$mode" --username "$user" --password "$pass" --from-address "$from" --mailto "$to" \
    --comment "added by proxmox-toolbelt.sh"
  offer_test_and_matcher "$name"
}

fix_gotify() {
  hdr "Add a Gotify target"
  local name server token
  ask name "Target name" gotify v_tname
  ask server "Gotify server URL" "" v_url
  ask_secret token "Application token"
  run pvesh create /cluster/notifications/endpoints/gotify --name "$name" --server "$server" --token "$token" --comment "added by proxmox-toolbelt.sh"
  offer_test_and_matcher "$name"
}

fix_ntfy() {
  hdr "Add an ntfy target (webhook)"
  hint "Topics on ntfy.sh are public; use a random topic name or an access token."
  local name server topic token=""
  ask name "Target name" ntfy v_tname
  ask server "ntfy server" "https://ntfy.sh" v_url
  ask topic "Topic" "pve-$(openssl rand -hex 4)" v_tname
  ask_yn "Does the topic need an access token?" n && ask_secret token "Access token"
  b64() { printf '%s' "$1" | base64 -w0; }
  local args=(--name "$name" --url "${server%/}/$topic" --method post
              --body "$(b64 '{{ message }}')"
              --header "name=Title,value=$(b64 '{{ title }}')"
              --comment "added by proxmox-toolbelt.sh")
  if [[ -n "$token" ]]; then
    args+=(--secret "name=token,value=$(b64 "$token")" --header "name=Authorization,value=$(b64 'Bearer {{ secrets.token }}')")
  fi
  run pvesh create /cluster/notifications/endpoints/webhook "${args[@]}"
  hint "Subscribe to: ${server%/}/$topic"
  offer_test_and_matcher "$name"
}

fix_matcher() {
  hdr "Add an alert rule (matcher)"
  local targets names=() opts=() n t ty
  targets="$(pj /cluster/notifications/targets)" || die "Could not read notification targets"
  while IFS='|' read -r n ty; do [[ -n "$n" ]] && { names+=("$n"); opts+=("$n|$ty"); }; done < <(jrows name type <<<"$targets")
  (( ${#names[@]} )) || die "Add a target first"
  local pick="${1:-}"
  if [[ -z "$pick" ]]; then
    local i; for i in "${!opts[@]}"; do printf '  %2d) %s\n' $(( i + 1 )) "${opts[i]/|/  }"; done
    local sel; ask sel "Targets (numbers or names, comma separated)" "${names[-1]}" v_any
    for t in ${sel//,/ }; do
      [[ "$t" =~ ^[0-9]+$ ]] && (( t >= 1 && t <= ${#names[@]} )) && t="${names[t-1]}"
      pick+="${pick:+ }$t"
    done
  fi
  local sev; menu sev "Which events" "warning,error" \
    "warning,error|warnings and errors (failed backups, fencing, updates available is info)" \
    "info,notice,warning,error|everything, including successful backups and available updates" \
    "error|errors only"
  local name; ask name "Rule name" "alerts-${pick%% *}" v_tname
  local args=(--name "$name" --mode all --match-severity "$sev" --comment "added by proxmox-toolbelt.sh")
  for t in $pick; do args+=(--target "$t"); done
  run pvesh create /cluster/notifications/matchers "${args[@]}"
  (( DRY_RUN )) || log "Alert rule $name sends $sev to: $pick"
}

fix_test_notify() {
  hdr "Send a test notification"
  local opts=() n ty
  while IFS='|' read -r n ty; do [[ -n "$n" ]] && opts+=("$n|$ty"); done < <(pj /cluster/notifications/targets | jrows name type)
  (( ${#opts[@]} )) || die "No notification targets"
  local t; menu t "Target" "${opts[0]%%|*}" "${opts[@]}"
  run pvesh create "/cluster/notifications/targets/$t/test"
  (( DRY_RUN )) || log "Test sent through $t"
}

view_notify() {
  hdr "Notification targets and rules"
  echo "${C_B}Targets${C_0}"
  { pj /cluster/notifications/targets || true; } | jrows name type disable origin comment | awk -F'|' '{printf "  %-24s %-9s %-8s %-16s %s\n", $1, $2, ($3==1?"off":"on"), $4, $5}'
  echo; echo "${C_B}Matchers (rules)${C_0}"
  { pj /cluster/notifications/matchers || true; } | jrows name disable target match-severity mode | awk -F'|' '{printf "  %-24s %-4s -> %-30s severity %s\n", $1, ($2==1?"off":"on"), $3, ($4==""?"any":$4)}'
  echo; hint "root@pam e-mail: $(root_email || true)"
}

# ---------------------------------------------------------------------------
# Images and checksums (VM builder)
# ---------------------------------------------------------------------------
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 "$@"; }

# checksum_lookup FILE NAME [single]: prints "sha256|sha512 HASH" for NAME.
# Understands GNU ("hash  name") and BSD ("SHA256 (name) = hash") formats.
checksum_lookup() {
  local file="$1" name="$2" single="${3:-}" line h n count=0 only=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^SHA(256|512)\ \((.+)\)\ =\ ([0-9a-fA-F]+)$ ]]; then
      n="${BASH_REMATCH[2]}"; h="${BASH_REMATCH[3]}"
    elif [[ "$line" =~ ^([0-9a-fA-F]{64}|[0-9a-fA-F]{128})\ [\ *](.+)$ ]]; then
      h="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
    else continue; fi
    n="${n#./}"
    count=$(( count + 1 )); only="$h"
    if [[ "$n" == "$name" ]]; then echo "$(hash_algo "$h") ${h,,}"; return 0; fi
  done <"$file"
  if [[ -n "$single" ]] && (( count == 1 )); then echo "$(hash_algo "$only") ${only,,}"; return 0; fi
  return 1
}
hash_algo() { (( ${#1} == 128 )) && echo sha512 || echo sha256; }

file_hash() { "${1}sum" "$2" | awk '{print $1}'; }

resolve_fedora() {
  local base="https://download.fedoraproject.org/pub/fedora/linux/releases" v dir idx img sum
  for v in $(fetch "$base/" | grep -oE 'href="[0-9]+/"' | grep -oE '[0-9]+' | sort -rn | awk 'NR<=3'); do
    dir="$base/$v/Cloud/x86_64/images"
    idx="$(fetch "$dir/" 2>/dev/null)" || continue
    img="$(grep -oE 'Fedora-Cloud-Base-Generic-[0-9][A-Za-z0-9._-]*\.x86_64\.qcow2' <<<"$idx" | sort -uV | tail -1)"
    sum="$(grep -oE 'Fedora-Cloud-[0-9][A-Za-z0-9._-]*-x86_64-CHECKSUM' <<<"$idx" | sort -uV | tail -1)"
    if [[ -n "$img" && -n "$sum" ]]; then IMG_URL="$dir/$img"; SUM_URL="$dir/$sum"; return 0; fi
  done
  die "Could not find a Fedora Cloud image under $base"
}

# Download (or reuse) IMG_URL into IMG_PATH and verify it against EXPECT ("algo hash" or empty)
get_image() {
  local algo="" want=""
  [[ -n "$EXPECT" ]] && read -r algo want <<<"$EXPECT"
  verify() { [[ -z "$want" ]] || [[ "$(file_hash "$algo" "$IMG_PATH")" == "$want" ]]; }

  if (( DRY_RUN )); then log "[dry-run] would download/verify $IMG_URL -> $IMG_PATH"; return 0; fi
  mkdir -p "${IMG_PATH%/*}"
  exec 9>"${IMG_PATH}.lock"
  flock -w 600 9 || die "Another run is downloading $IMG_PATH"

  if [[ -s "$IMG_PATH" && -n "$want" ]] && verify; then
    log "Using cached image (${algo} OK)"
    return 0
  fi
  log "Downloading ${IMG_URL##*/}"
  TMP_FILES+=("${IMG_PATH}.part")
  curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "${IMG_PATH}.part" "$IMG_URL" || die "Download failed: $IMG_URL"
  mv -f "${IMG_PATH}.part" "$IMG_PATH"
  if ! verify; then rm -f "$IMG_PATH"; die "Checksum mismatch for ${IMG_URL##*/}, image deleted"; fi
  [[ -n "$want" ]] && log "Checksum verified (${algo})"
  return 0
}

# ---------------------------------------------------------------------------
# Validators (print why, return 1 to re-ask)
# ---------------------------------------------------------------------------
v_vmid() {
  [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] || { echo "  VMID must be a number from 100 to 999999999" >&2; return 1; }
  if [[ -e "$PVE_DIR/nodes" ]] && compgen -G "$PVE_DIR/nodes/*/*/$1.conf" >/dev/null; then
    echo "  VMID $1 is already in use" >&2; return 1; fi
  if qm status "$1" &>/dev/null; then echo "  VMID $1 is already in use" >&2; return 1; fi
}
v_name() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || { echo "  Use a DNS name: letters, digits, dashes, dots" >&2; return 1; }; }
v_disk() { [[ "$1" =~ ^[1-9][0-9]*[GT]?$ ]] || { echo "  Use a size like 32G or 1T" >&2; return 1; }; }
v_mem()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 512 )) || { echo "  Memory in MB, at least 512" >&2; return 1; }; }
v_cores() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 512 )) || { echo "  1 or more cores" >&2; return 1; }; }
v_01()   { [[ "$1" == 0 || "$1" == 1 ]] || { echo "  Enter 0 or 1" >&2; return 1; }; }
v_vlan() { [[ -z "$1" || "$1" == none ]] && return 0; [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 4094 )) || { echo "  VLAN tag 1-4094, or blank for none" >&2; return 1; }; }
v_cpu()  { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "  Invalid CPU type" >&2; return 1; }; }
v_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != root ]] || { echo "  Lowercase user name, not root" >&2; return 1; }; }
v_dns() {
  [[ "$1" == host ]] && return 0
  local s; for s in ${1//,/ }; do is_ipv4 "$s" || { echo "  '$s' is not an IPv4 address (or type 'host')" >&2; return 1; }; done
  [[ -n "${1//[ ,]/}" ]] || { echo "  Enter at least one DNS server, or 'host'" >&2; return 1; }
}
v_domain() { [[ -z "$1" || "$1" == none || "$1" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "  Invalid search domain" >&2; return 1; }; }
v_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]] || { echo "  Enter an http(s) URL" >&2; return 1; }; }
v_any() { return 0; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
VMID="" CREATED=0 TMP_FILES=() TMP_DIRS=() ERR_LEVEL=0
on_exit() {
  local rc=$?
  set +e
  restore_tty
  (( ${#TMP_FILES[@]} )) && rm -f "${TMP_FILES[@]}"
  (( ${#TMP_DIRS[@]} )) && rm -rf "${TMP_DIRS[@]}"
  if (( rc != 0 && CREATED == 1 )); then
    if (( KEEP_ON_FAIL )); then
      echo "Build failed; VM $VMID was kept. Remove it with: qm destroy $VMID --purge" >&2
    else
      echo "Build failed; removing half-built VM $VMID..." >&2
      qm stop "$VMID" --skiplock 1 &>/dev/null
      qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1 &>/dev/null \
        || echo "Could not remove VM $VMID, run: qm destroy $VMID --purge" >&2
    fi
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
trap '(( BASH_SUBSHELL > ERR_LEVEL )) || echo "${C_R}Failed at line $LINENO: $BASH_COMMAND${C_0}" >&2' ERR

# ---------------------------------------------------------------------------
# VM builder steps
# ---------------------------------------------------------------------------
load_config() {
  [[ -f "$CONF_FILE" ]] || return 0
  local owner perms
  owner="$(stat -c %u "$CONF_FILE")"; perms="$(stat -c %a "$CONF_FILE")"
  [[ "$owner" == 0 ]] || die "$CONF_FILE must be owned by root"
  (( (8#$perms & 8#022) == 0 )) || die "$CONF_FILE must not be group/world writable"
  # shellcheck source=/dev/null
  source "$CONF_FILE"
}

preflight() {
  local dep
  for dep in qm pvesm pvesh ip awk curl sha256sum sha512sum flock qemu-img openssl ssh-keygen; do
    command -v "$dep" >/dev/null || die "Missing dependency: $dep"
  done
}

# catalog_select KEY: sets DISTRO DISTRO_LABEL DISTRO_USER IMG_URL SUM_URL from the catalog
catalog_select() {
  local i key label user url sum
  for i in "${!CATALOG[@]}"; do
    IFS='|' read -r key label user url sum <<<"${CATALOG[i]}"
    [[ "$key" == "$1" ]] || continue
    DISTRO="$key" DISTRO_LABEL="$label" DISTRO_USER="$user" IMG_URL="$url" SUM_URL="$sum" SUM_SINGLE=""
    return 0
  done
  die "Unknown distro key: $1"
}

# resolve_image: turns SUM_URL into EXPECT and sets IMG_PATH (fetches checksum files)
resolve_image() {
  [[ "$IMG_URL" == fedora ]] && { log "Resolving latest Fedora Cloud release"; resolve_fedora; }
  [[ "$SUM_URL" == "@file" ]] && { SUM_URL="${IMG_URL}.CHECKSUM"; SUM_SINGLE=1; }
  EXPECT=""
  if [[ "$SUM_URL" =~ ^([0-9a-fA-F]{64}|[0-9a-fA-F]{128})$ ]]; then
    EXPECT="$(hash_algo "$SUM_URL") ${SUM_URL,,}"
  elif [[ -n "$SUM_URL" ]]; then
    local sums; sums="$(mktemp)"; TMP_FILES+=("$sums")
    log "Fetching checksums for $DISTRO"
    fetch -o "$sums" "$SUM_URL" || die "Could not download $SUM_URL"
    EXPECT="$(checksum_lookup "$sums" "${IMG_URL##*/}" "$SUM_SINGLE")" \
      || die "No checksum for ${IMG_URL##*/} in $SUM_URL"
  fi
  [[ "${IMG_URL##*/}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unexpected image file name: ${IMG_URL##*/}"
  IMG_PATH="${IMG_DIR}/${DISTRO}/${IMG_URL##*/}"
}

step_distro() {
  hdr "Image"
  local i key label user opts=()
  for i in "${!CATALOG[@]}"; do
    IFS='|' read -r key label user _ _ <<<"${CATALOG[i]}"
    opts+=("$key|$label (user $user)")
  done
  local pick; menu pick "Distro" "$DEF_DISTRO" "${opts[@]}"
  catalog_select "$pick"
  if [[ "$IMG_URL" == custom ]]; then
    ask IMG_URL "Image URL (qcow2/img/raw)" "" v_url
    [[ "$IMG_URL" == https://* ]] || ask_yn "Plain http download. Continue?" n || die "Aborted"
    ask SUM_URL "Checksum file URL, or the sha256/sha512 hash itself (blank = none)" "" v_any
    DISTRO_LABEL="Custom (${IMG_URL##*/})"
  fi
  if [[ -z "$SUM_URL" && "$IMG_URL" != fedora ]]; then
    warn "No checksum; the image will not be verified"
    ask_yn "Continue without verification?" n || die "Aborted"
  fi
  resolve_image
}

# pick_storage VAR [CONTENT] [PROMPT] [DEFAULT]: menu of active storages with that content type
pick_storage() {
  local __v="$1" content="${2:-images}" q="${3:-Storage for the disks}" want="${4:-${DEF_STORAGE:-local-lvm}}"
  local stores=() opts=() s def="" name type st total used avail
  while read -r name type st total used avail _; do
    [[ "$st" == active ]] || continue
    stores+=("$name")
    opts+=("$name|$type, $(human_gib "$avail") free of $(human_gib "$total")")
  done < <(pvesm status --content "$content" 2>/dev/null | awk 'NR>1')
  (( ${#stores[@]} )) || die "No active storage has content type '$content' (Datacenter > Storage > Edit > Content)"
  for s in "${stores[@]}"; do [[ "$s" == "$want" ]] && def="$s"; done
  if (( ${#stores[@]} == 1 )); then
    printf -v "$__v" '%s' "${stores[0]}"; echo "  $q: ${opts[0]%%|*} ${C_D}(${opts[0]#*|})${C_0}"; return 0
  fi
  menu "$__v" "$q" "${def:-${stores[0]}}" "${opts[@]}"
}

step_vm() {
  hdr "VM"
  local next; next="$(pvesh get /cluster/nextid 2>/dev/null || true)"; [[ "$next" =~ ^[0-9]+$ ]] || next=100
  ask VMID "VMID (next free: $next)" "$next" v_vmid
  ask VMNAME "Name" "${DISTRO%%-*}-${VMID}" v_name

  echo; echo "${C_B}CPU${C_0} ${C_D}(host: $(host_cores) threads, $(awk -F': ' '/^model name/{print $2; exit}' "$CPUINFO" 2>/dev/null))${C_0}"
  local opts=() c hc; hc="$(host_cores)"
  for c in 1 2 4 6 8 12 16 24 32; do (( c <= hc )) && opts+=("$c|"); done
  MENU_FREE=v_cores menu CORES "CPU cores" "$DEF_CORES" "${opts[@]}"
  (( CORES <= hc )) || warn "$CORES cores is more than the host's $hc threads"

  opts=("host|all host CPU features, fastest (no live migration to different CPUs)")
  opts+=("x86-64-v2-AES|portable, safe for mixed clusters (Proxmox default)")
  host_has_flags avx avx2 bmi1 bmi2 fma movbe && opts+=("x86-64-v3|portable + AVX2 (needed by Rocky/Alma 10 if not host)")
  host_has_flags avx512f avx512bw avx512cd avx512dq avx512vl && opts+=("x86-64-v4|portable + AVX-512")
  opts+=("kvm64|oldest baseline, maximum compatibility")
  local m
  while read -r m; do [[ -n "$m" ]] && opts+=("custom-$m|custom model from cpu-models.conf"); done \
    < <(awk '$1=="cpu-model:"{print $2}' "$PVE_DIR/virtual-guest/cpu-models.conf" 2>/dev/null)
  MENU_FREE=v_cpu menu CPU "CPU type" "$DEF_CPU" "${opts[@]}"
  if [[ "$DISTRO" =~ ^(rocky|alma)-10$ && "$CPU" =~ ^(x86-64-v2|x86-64-v2-AES|kvm64|qemu64)$ ]]; then
    warn "$DISTRO needs x86-64-v3 or newer and will not boot with $CPU"
    ask_yn "Keep $CPU anyway?" n || MENU_FREE=v_cpu menu CPU "CPU type" host "${opts[@]}"
  fi

  echo; echo "${C_B}Memory${C_0} ${C_D}(host: $(host_mem_mb) MB total, $(host_mem_mb MemAvailable) MB available)${C_0}"
  local hm; hm="$(host_mem_mb)"; opts=()
  for m in 1024 2048 4096 8192 16384 32768 65536; do (( hm == 0 || m <= hm )) && opts+=("$m|$(( m / 1024 )) GiB"); done
  MENU_FREE=v_mem menu MEM "Memory (MB)" "$DEF_MEM" "${opts[@]}"
  (( hm == 0 || MEM <= hm )) || warn "$MEM MB is more than the host has"

  echo; echo "${C_B}Firmware${C_0}"
  menu BIOS "Firmware" "$DEF_BIOS" "ovmf|UEFI (recommended for cloud images)" "seabios|legacy BIOS"

  echo; echo "${C_B}Storage${C_0}"
  pick_storage STORAGE

  opts=()
  local s; for s in 16G 32G 64G 128G 256G 512G; do opts+=("$s|"); done
  MENU_FREE=v_disk menu DISK_SIZE "Disk size" "$DEF_DISK" "${opts[@]}"
  [[ "$DISK_SIZE" =~ [GT]$ ]] || DISK_SIZE="${DISK_SIZE}G"
}

# Fills BRIDGES, GUESTS, DR_DEV, DR_GW, BRIDGE_OPTS
discover_network() {
  mapfile -t BRIDGES < <(list_bridges)
  (( ${#BRIDGES[@]} )) || die "No bridges found on this host"
  mapfile -t GUESTS < <(guest_addresses)
  local dr; dr="$(default_route)"; DR_DEV="${dr%%|*}" DR_GW="${dr#*|}"
  local b addr extra cm
  BRIDGE_OPTS=()
  for b in "${BRIDGES[@]}"; do
    addr="$(iface_ipv4 "$b")"; extra=""; cm="$(iface_comment "$b")"
    vlan_aware "$b" && extra+=", vlan-aware"
    [[ "$b" == "$DR_DEV" ]] && extra+=", default route"
    BRIDGE_OPTS+=("$b|${addr:-no host IP}${cm:+  \"$cm\"}$extra")
  done
}

# Network: fills NIC_NET[], NIC_IPCFG[], NIC_DESC[] and DNS settings
step_network() {
  hdr "Network"
  discover_network
  NIC_NET=() NIC_IPCFG=() NIC_DESC=() GW_SET="" FIRST_GW=""
  local n=0
  while true; do
    nic_prompt "$n"
    n=$(( n + 1 ))
    (( n < 8 )) && ask_yn "Add another network card?" n || break
  done

  echo
  echo "${C_B}DNS${C_0}"
  local opts=() hr; hr="$(host_resolvers)"
  [[ -n "$FIRST_GW" ]] && opts+=("$FIRST_GW|gateway of the first static NIC (usual for a router/firewall)")
  opts+=("host|copy the Proxmox host's resolvers (${hr:-none found})")
  opts+=("1.1.1.1 1.0.0.1|Cloudflare" "9.9.9.9 149.112.112.112|Quad9" "8.8.8.8 8.8.4.4|Google")
  MENU_FREE=v_dns menu DNS "DNS servers (space separated)" "${DEF_DNS:-${FIRST_GW:-host}}" "${opts[@]}"
  local -a dns_list; read -ra dns_list <<<"${DNS//,/ }"; DNS="${dns_list[*]}"
  local sd; sd="${DEF_SEARCHDOMAIN:-$(host_search_domain)}"
  ask SEARCHDOMAIN "Search domain (none = skip)" "${sd:-none}" v_domain
}

default_bridge() {
  local def_br="${DEF_BRIDGE:-${DR_DEV:-${BRIDGES[0]}}}" b
  for b in "${BRIDGES[@]}"; do [[ "$b" == "$def_br" ]] && { echo "$def_br"; return; }; done
  echo "${BRIDGES[0]}"
}

nic_prompt() {
  local n="$1" br tag fw mode v6 ipcfg="" desc
  echo; echo "${C_B}-- net${n} --${C_0}"
  menu br "Bridge" "$(default_bridge)" "${BRIDGE_OPTS[@]}"

  # VLAN tags other guests already use on this bridge
  local opts=("none|untagged") g kind id gbr gtag gip ggw t
  local -A seen=()
  for g in "${GUESTS[@]}"; do
    IFS='|' read -r kind id gbr gtag gip ggw <<<"$g"
    [[ "$gbr" == "$br" && -n "$gtag" ]] || continue
    seen[$gtag]+="$kind $id${gip:+ ($gip)}, "
  done
  for t in $(printf '%s\n' "${!seen[@]}" | sort -n); do
    opts+=("$t|used by ${seen[$t]%, }")
  done
  vlan_aware "$br" || (( ${#seen[@]} )) || hint "$br is not VLAN-aware; a tag creates a separate VLAN bridge"
  MENU_FREE=v_vlan menu tag "VLAN tag" none "${opts[@]}"
  [[ "$tag" == none ]] && tag=""

  menu fw "Proxmox firewall on this NIC" "$DEF_FW" "1|on (datacenter and VM/CT firewall rules apply)" "0|off (e.g. a router VM filters this net)"

  local net="virtio,bridge=${br},firewall=${fw}"
  [[ -n "$tag" ]] && net+=",tag=${tag}"
  desc="${br}${tag:+ vlan $tag} fw=$fw"

  menu mode "IPv4" "$( (( n == 0 )) && echo static || echo dhcp)" \
    "static|fixed address (subnet and gateway predicted)" "dhcp|address from a DHCP server" "none|no IPv4"
  case "$mode" in
    dhcp) ipcfg="ip=dhcp"; desc+=" dhcp" ;;
    static) nic_static "$n" "$br" "$tag"; ipcfg="$STATIC_CFG"; desc+=" $STATIC_DESC" ;;
    none) ;;
  esac

  menu v6 "IPv6" none "none|no IPv6" "auto|SLAAC (router advertisements)" "dhcp|DHCPv6"
  if [[ "$v6" != none ]]; then ipcfg="${ipcfg:+$ipcfg,}ip6=${v6}"; desc+=" ip6=$v6"; fi

  NIC_NET[n]="$net" NIC_IPCFG[n]="$ipcfg" NIC_DESC[n]="$desc"
}

# Predicts subnet/gateway/free IP for bridge+tag, asks, validates. Sets STATIC_CFG, STATIC_DESC.
nic_static() {
  local n="$1" br="$2" tag="$3"
  local k_ip="" k_p="" k_gw="" why="" g b kind id gbr gtag gip ggw used=()
  local hostif="$br" hostaddr

  # 1) other guests with a static address on the same bridge + VLAN
  for g in "${GUESTS[@]}"; do
    IFS='|' read -r kind id gbr gtag gip ggw <<<"$g"
    [[ "$gip" == */* ]] || continue
    used+=("${gip%/*}")
    if [[ -z "$k_ip" && "$gbr" == "$br" && "$gtag" == "$tag" ]]; then
      k_ip="${gip%/*}" k_p="${gip#*/}" k_gw="$ggw" why="from $kind $id on this bridge"
    fi
  done
  # 2) the host's own address on the bridge (or its VLAN sub-interface)
  [[ -n "$tag" ]] && { hostif=""; for b in "${br}.${tag}" "vlan${tag}"; do [[ -e "$SYS_NET/$b" ]] && hostif="$b"; done; }
  hostaddr="${hostif:+$(iface_ipv4 "$hostif")}"
  [[ -n "$hostaddr" ]] && used+=("${hostaddr%/*}")
  if [[ -z "$k_ip" && -n "$hostaddr" ]]; then
    k_ip="${hostaddr%/*}" k_p="${hostaddr#*/}" why="from host address $hostaddr on $hostif"
    if [[ "$DR_DEV" == "$hostif" && -n "$DR_GW" ]]; then k_gw="$DR_GW"; why+=", via the default route"
    else k_gw="$k_ip"; why+=", host routes this net"; fi
  fi
  [[ -n "$k_gw" ]] && used+=("$k_gw")

  local def_ip=""
  if [[ -n "$k_ip" ]]; then
    hint "Known subnet $(int2ip "$(net_int "$k_ip" "$k_p")")/$k_p, gateway ${k_gw:-?} ($why)"
    def_ip="$(suggest_free_ip "$k_ip" "$k_p" "${used[@]}")"
    [[ -n "$def_ip" ]] && def_ip+="/$k_p"
  else
    hint "No existing address on this network; enter IP/CIDR, e.g. 10.5.0.20/24"
  fi
  hint "Formats: 10.5.0.20/24, 10.5.0.20 (prefix ${k_p:-24}), or the host part when the subnet is known"

  local in ip p
  while true; do
    ask in "IP address/CIDR" "$def_ip" v_any
    if [[ "$in" =~ ^[0-9]+$ && -n "$k_ip" ]]; then
      ip="$(int2ip $(( $(net_int "$k_ip" "$k_p") + 10#$in )))"; p="$k_p"
      in_subnet "$ip" "$k_ip" "$k_p" || { echo "  Host number $in does not fit in /$k_p" >&2; continue; }
    elif [[ "$in" == */* ]]; then ip="${in%/*}" p="${in#*/}"
    else ip="$in" p="${k_p:-24}"; fi
    is_ipv4 "$ip" || { echo "  '$ip' is not an IPv4 address" >&2; continue; }
    is_prefix "$p" || { echo "  Prefix must be 1-32" >&2; continue; }
    p=$(( 10#$p ))
    is_host_addr "$ip" "$p" || { echo "  $ip is the network or broadcast address of /$p" >&2; continue; }
    if ip_in_use "$ip" "${used[@]}"; then
      warn "$ip is already configured on another guest or the host"
      ask_yn "Use it anyway?" n || continue
    fi
    if ping_responds "$ip" "$hostif"; then
      warn "$ip responds to ping"
      ask_yn "Use it anyway?" n || continue
    fi
    break
  done

  # Gateway candidates: learned one if it fits this subnet, first and last usable host
  local cidr; cidr="$(int2ip "$(net_int "$ip" "$p")")/$p"
  local opts=() gw_def="" c fh lh
  if [[ -n "$k_gw" ]] && is_ipv4 "$k_gw" && in_subnet "$k_gw" "$ip" "$p" && [[ "$k_gw" != "$ip" ]]; then
    opts+=("$k_gw|$why"); gw_def="$k_gw"
  fi
  if (( p < 31 )); then
    fh="$(first_host "$ip" "$p")" lh="$(last_host "$ip" "$p")"
    for c in "$fh" "$lh"; do
      [[ "$c" == "$ip" || "$c" == "$gw_def" ]] && continue
      opts+=("$c|$([[ $c == "$fh" ]] && echo first || echo last) usable host of $cidr")
    done
    [[ -n "$gw_def" ]] || gw_def="$(predict_gateway "$ip" "$p")"
  fi
  opts+=("none|no gateway on this NIC")
  if [[ -n "$GW_SET" ]]; then
    hint "Default gateway already set on net${GW_SET}; default here is none"
    gw_def="none"
  fi
  local gw
  while true; do
    MENU_FREE=v_any menu gw "Gateway" "${gw_def:-none}" "${opts[@]}"
    [[ "$gw" == none ]] && { gw=""; break; }
    is_ipv4 "$gw" || { echo "  Not an IPv4 address" >&2; continue; }
    [[ "$gw" != "$ip" ]] || { echo "  Gateway cannot be the same as the address" >&2; continue; }
    if ! in_subnet "$gw" "$ip" "$p"; then
      warn "$gw is outside $cidr"
      ask_yn "Use it anyway (on-link gateway)?" n || continue
    fi
    break
  done

  STATIC_CFG="ip=${ip}/${p}${gw:+,gw=$gw}"
  STATIC_DESC="${ip}/${p} gw ${gw:-none}"
  if [[ -n "$gw" && -z "$GW_SET" ]]; then GW_SET="$n"; FIRST_GW="$gw"; fi
}

# suggest_free_ip REF PREFIX USED...: first free address from .100 (or host 2) upward
suggest_free_ip() {
  local ref="$1" p="$2"; shift 2
  local net bc start i ip
  (( p >= 31 )) && return 0
  net="$(net_int "$ref" "$p")"; bc="$(bcast_int "$ref" "$p")"
  start=$(( net + 100 )); (( start < bc - 1 )) || start=$(( net + 2 ))
  for (( i = start; i < bc && i < start + 1024; i++ )); do
    ip="$(int2ip "$i")"
    ip_in_use "$ip" "$@" || { echo "$ip"; return 0; }
  done
}
ip_in_use() { local ip="$1" u; shift; for u in "$@"; do [[ "$u" == "$ip" ]] && return 0; done; return 1; }

# Only meaningful when the host itself sits on that segment
ping_responds() {
  local ip="$1" dev="$2"
  (( DRY_RUN )) && return 1
  [[ -n "$dev" && -n "$(iface_ipv4 "$dev")" ]] || return 1
  command -v ping >/dev/null || return 1
  ping -c 1 -W 1 -I "$dev" "$ip" &>/dev/null
}

# pick_sshkeys: sets SSHKEY_FILE (temp file with validated keys) or ""
pick_sshkeys() {
  SSHKEY_FILE=""
  echo; echo "${C_B}SSH keys${C_0}"
  local keys def_keys="none" opts=() f cnt home=""
  [[ -n "${SUDO_USER:-}" ]] && home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  for f in "$DEF_SSHKEYS" /root/.ssh/authorized_keys /root/.ssh/*.pub ${home:+"$home"/.ssh/*.pub}; do
    [[ -s "$f" ]] || continue
    ip_in_use "$f" "${opts[@]%%|*}" && continue
    cnt="$(pubkey_lines "$f" | grep -c . || true)"
    (( cnt )) || continue
    opts+=("$f|$(pubkey_label "$f")")
    [[ "$def_keys" == none ]] && def_keys="$f"
  done
  opts+=("none|no SSH key (password login only)")
  while true; do
    MENU_FREE=v_any menu keys "SSH key file, or paste a public key" "$def_keys" "${opts[@]}"
    [[ "$keys" == none ]] && break
    SSHKEY_FILE="$(mktemp)"; TMP_FILES+=("$SSHKEY_FILE")
    if [[ -f "$keys" ]]; then pubkey_lines "$keys" >"$SSHKEY_FILE"
    else printf '%s\n' "$keys" | pubkey_lines >"$SSHKEY_FILE"; fi
    if [[ -s "$SSHKEY_FILE" ]] && ssh-keygen -l -f "$SSHKEY_FILE" >/dev/null 2>&1; then
      log "$(wc -l <"$SSHKEY_FILE") SSH key(s) accepted"; break
    fi
    echo "  No valid SSH public key found there" >&2; SSHKEY_FILE=""
  done
}

# ask_vm_password: sets CIPASS and PASS_GENERATED
ask_vm_password() {
  CIPASS="" PASS_GENERATED=0
  hint "Password is for console login; blank = generate one, 'none' = SSH key only"
  local p1 p2
  while true; do
    read -rsp "Password: " p1 || exit 130; echo
    if [[ "$p1" == none ]]; then
      [[ -n "$SSHKEY_FILE" ]] && break
      echo "  Without an SSH key a password is required" >&2; continue
    fi
    if [[ -z "$p1" ]]; then CIPASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"; PASS_GENERATED=1; break; fi
    (( ${#p1} >= 8 )) || { echo "  At least 8 characters" >&2; continue; }
    read -rsp "Repeat:   " p2 || exit 130; echo
    [[ "$p1" == "$p2" ]] && { CIPASS="$p1"; break; }
    echo "  Passwords do not match" >&2
  done
}

step_user() {
  hdr "Login"
  ask CIUSER "Username" "$DISTRO_USER" v_user
  pick_sshkeys
  ask_vm_password
}

# pick_snippet_store: sets SNIP_STORE ("" when none)
pick_snippet_store() {
  SNIP_STORE="$SNIPPET_STORAGE"
  if [[ -z "$SNIP_STORE" ]]; then
    local snips=()
    mapfile -t snips < <(pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}')
    if (( ${#snips[@]} > 1 )); then
      menu SNIP_STORE "Storage for the cloud-init snippet" "${snips[0]}" "${snips[@]}"
    elif (( ${#snips[@]} )); then SNIP_STORE="${snips[0]}"; fi
  fi
  if [[ -z "$SNIP_STORE" ]]; then
    warn "No storage with snippets content; qemu-guest-agent will not be installed automatically."
    hint "Enable with menu 4.2, or: pvesm set local --content iso,vztmpl,backup,snippets"
    ask_yn "Continue without the vendor snippet?" y || die "Aborted"
  fi
}

step_options() {
  hdr "Options"
  UPGRADE=0; ask_yn "Upgrade packages on first boot?" "$([[ $DEF_UPGRADE == 1 ]] && echo y || echo n)" && UPGRADE=1
  ONBOOT=0; ask_yn "Start with the host (onboot)?" "$([[ $DEF_ONBOOT == 1 ]] && echo y || echo n)" && ONBOOT=1
  menu FINISH "When done" start "start|boot the VM now" "stopped|leave it powered off" "template|convert to a template for cloning"
  pick_snippet_store
}

summary() {
  hdr "Summary"
  echo "  Image   : $DISTRO_LABEL"
  echo "            ${IMG_URL}"
  echo "            checksum: $([[ -n $EXPECT ]] && echo "${EXPECT%% *} verified" || echo "NOT verified")"
  echo "  VM      : $VMID ($VMNAME) | $CORES core$( ((CORES == 1)) || echo s), ${MEM} MB, $DISK_SIZE on $STORAGE | cpu $CPU | $BIOS"
  local i
  for i in "${!NIC_DESC[@]}"; do echo "  net$i    : ${NIC_DESC[i]}"; done
  echo "  DNS     : $DNS | search ${SEARCHDOMAIN}"
  echo "  Login   : $CIUSER | ssh keys: $([[ -n $SSHKEY_FILE ]] && echo yes || echo no) | password: $([[ -n $CIPASS ]] && echo yes || echo no)"
  echo "  Options : upgrade=$UPGRADE onboot=$ONBOOT finish=$FINISH snippets=${SNIP_STORE:-none}"
  if [[ "$DEF_FW" == 1 && " ${NIC_NET[*]} " == *firewall=1* ]] && [[ "$(fw_enabled "$PVE_DIR/firewall/cluster.fw")" == 1 ]]; then
    hint "firewall=1 has no effect until the VM firewall is enabled; this is offered after creation."
  fi
  echo
  confirm "Create this VM?" || die "Aborted"
}

write_snippet() {
  [[ -n "$SNIP_STORE" ]] || return 0
  SNIP_NAME="create-vm-vendor.yaml"
  (( UPGRADE )) && SNIP_NAME="create-vm-vendor-upgrade.yaml"
  local path; path="$(pvesm path "${SNIP_STORE}:snippets/${SNIP_NAME}" 2>/dev/null)" || die "Cannot resolve snippet path on $SNIP_STORE"
  local body
  body="#cloud-config
# managed by create-vm.sh
package_update: true
package_upgrade: $( (( UPGRADE )) && echo true || echo false)
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]"
  if [[ ! -f "$path" ]] || [[ "$(cat "$path")" != "$body" ]]; then
    log "Writing cloud-init vendor snippet $SNIP_NAME"
    if (( DRY_RUN )); then hint "[dry-run] would write $path"
    else mkdir -p "${path%/*}"; printf '%s\n' "$body" >"$path"; chmod 644 "$path"; fi
  fi
}

build() {
  get_image
  write_snippet

  local args=(--name "$VMNAME" --ostype l26 --machine q35 --bios "$BIOS" --cpu "$CPU"
              --cores "$CORES" --memory "$MEM" --balloon 0 --scsihw virtio-scsi-single
              --agent enabled=1 --serial0 socket --vga std --tablet 0 --onboot "$ONBOOT"
              --tags "create-vm;${DISTRO//./-}")
  local i
  for i in "${!NIC_NET[@]}"; do args+=("--net$i" "${NIC_NET[i]}"); done

  log "Creating VM $VMID"
  run qm create "$VMID" "${args[@]}"
  CREATED=1

  [[ "$BIOS" == ovmf ]] && run qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0"

  log "Importing disk"
  run qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${IMG_PATH},discard=on,iothread=1,ssd=1"

  local cur want
  if (( ! DRY_RUN )); then
    cur="$(qemu-img info --output=json "$IMG_PATH" | awk -F'[:,]' '/"virtual-size"/{gsub(/ /,"",$2); print $2; exit}')"
    want=$(( ${DISK_SIZE%[GT]} * 1073741824 ))
    [[ "$DISK_SIZE" == *T ]] && want=$(( want * 1024 ))
    if (( want > cur )); then run qm resize "$VMID" scsi0 "$DISK_SIZE"
    else warn "Image size is already $(( cur / 1073741824 ))G; not resized"; fi
  else run qm resize "$VMID" scsi0 "$DISK_SIZE"; fi

  log "Configuring cloud-init"
  run qm set "$VMID" --ide2 "${STORAGE}:cloudinit" --boot order=scsi0
  local ci=(--ciuser "$CIUSER")
  [[ -n "$CIPASS" ]] && ci+=(--cipassword "$CIPASS")
  for i in "${!NIC_IPCFG[@]}"; do [[ -n "${NIC_IPCFG[i]}" ]] && ci+=("--ipconfig$i" "${NIC_IPCFG[i]}"); done
  [[ "$DNS" != host ]] && ci+=(--nameserver "$DNS")
  [[ "$SEARCHDOMAIN" != none && -n "$SEARCHDOMAIN" ]] && ci+=(--searchdomain "$SEARCHDOMAIN")
  [[ -n "$SNIP_STORE" ]] && ci+=(--cicustom "vendor=${SNIP_STORE}:snippets/${SNIP_NAME}")
  [[ -n "$SSHKEY_FILE" ]] && ci+=(--sshkeys "$SSHKEY_FILE")
  run qm set "$VMID" "${ci[@]}"
  run qm set "$VMID" --description "Created by proxmox-toolbelt.sh $VERSION on $(date -u +%F) from ${IMG_URL##*/}"

  case "$FINISH" in
    start)    log "Starting VM"; run qm start "$VMID" ;;
    template) log "Converting to template"; run qm template "$VMID" ;;
  esac
  CREATED=0
}

# offer_vm_firewall [qemu|lxc]: offers to switch on the VM/CT firewall when a NIC has
# firewall=1 and the datacenter firewall is on
offer_vm_firewall() {
  local type="${1:-qemu}" word=VM
  [[ "$type" == lxc ]] && word=container
  [[ " ${NIC_NET[*]} " == *firewall=1* ]] || return 0
  [[ "$(fw_enabled "$PVE_DIR/firewall/cluster.fw")" == 1 ]] || return 0
  echo
  hint "firewall=1 is set on a NIC; rules apply only with the $word firewall enabled."
  ask_yn "Enable the firewall for $word $VMID (default input policy applies)?" n || return 0
  run pvesh set "/nodes/$NODE/$type/$VMID/firewall/options" --enable 1
}

report() {
  hdr "Done"
  echo "  VM $VMID ($VMNAME) ${DISTRO_LABEL}: $FINISH"
  echo "  Hostname : $VMNAME"
  local i; for i in "${!NIC_DESC[@]}"; do echo "  net$i     : ${NIC_DESC[i]}"; done
  echo "  DNS      : $( [[ $DNS == host ]] && echo "host settings ($(host_resolvers))" || echo "$DNS")$( [[ -n $SEARCHDOMAIN && $SEARCHDOMAIN != none ]] && echo " | search $SEARCHDOMAIN")"
  echo "  User     : $CIUSER"
  (( PASS_GENERATED )) && echo "  Password : $CIPASS   ${C_Y}(generated, store it now; it is not shown again)${C_0}"
  echo "  Console  : qm terminal $VMID   (Ctrl+O to exit)"
  [[ -n "$SNIP_STORE" ]] && echo "  The guest agent installs on first boot; the IP shows in the GUI after ~2 minutes."
  return 0
}

create_vm() {
  preflight
  echo "${C_B}Proxmox cloud-init VM builder $VERSION${C_0}$( (( DRY_RUN )) && echo "  ${C_Y}[dry-run]${C_0}")"
  step_distro
  step_vm
  step_network
  step_user
  step_options
  summary
  build
  offer_vm_firewall
  report
}

# ---------------------------------------------------------------------------
# Container builder (LXC)
# ---------------------------------------------------------------------------
declare -A CT_AVAIL=() CT_HAVE=()
v_ct_mem()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 64 )) || { echo "  Memory in MB, at least 64" >&2; return 1; }; }
v_ct_swap() { [[ "$1" =~ ^[0-9]+$ ]] || { echo "  Swap in MB, 0 for none" >&2; return 1; }; }
v_ct_disk() { [[ "$1" =~ ^[1-9][0-9]*[Gg]?$ ]] || { echo "  Size in GiB, e.g. 8" >&2; return 1; }; }
v_ct_tpl()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.tar\.(gz|xz|zst)$ ]] || { echo "  Pick a number, or enter a template file name (*.tar.zst, *.tar.xz, *.tar.gz)" >&2; return 1; }; }

# ct_template_index STORE: fills CT_AVAIL (name -> newest file in the pveam index)
# and CT_HAVE (file -> 1 when already on STORE). The name is the file name up to the first "_".
ct_template_index() {
  local f
  CT_AVAIL=() CT_HAVE=()
  while read -r f; do [[ -n "$f" ]] && CT_HAVE[${f##*/}]=1; done \
    < <(pveam list "$1" 2>/dev/null | awk 'NR>1 && $1 ~ /:vztmpl\//{print $1}')
  while read -r f; do [[ -n "$f" ]] && CT_AVAIL[${f%%_*}]="$f"; done \
    < <(pveam available --section system 2>/dev/null | awk '{print $2}' | sort -V)
}

# ct_tpl_version FILE: debian-13-standard_13.1-2_amd64.tar.zst -> 13.1-2
ct_tpl_version() { local v="${1#*_}"; echo "${v%%_*}"; }

# step_ct_template: sets CT_TPL_STORE CT_TPL CT_TPL_VOLID CT_TPL_LOCAL CT_KEY
step_ct_template() {
  hdr "Template"
  pick_storage CT_TPL_STORE vztmpl "Storage for templates" local
  if (( ! DRY_RUN )); then
    log "Updating the template index (pveam update)"
    pveam update >/dev/null 2>&1 || warn "pveam update failed (no Internet access?); using the cached index"
  fi
  ct_template_index "$CT_TPL_STORE"

  local k f d opts=() def=""
  for k in $(printf '%s\n' "${!CT_AVAIL[@]}" | sort -V); do
    f="${CT_AVAIL[$k]}" d=""
    [[ -n "${CT_HAVE[$f]:-}" ]] && d=", downloaded"
    opts+=("$k|$(ct_tpl_version "$f")$d")
  done
  # downloaded files that are not the newest version in the index
  for f in $(printf '%s\n' "${!CT_HAVE[@]}" | sort -V); do
    [[ "${CT_AVAIL[${f%%_*}]:-}" == "$f" ]] || opts+=("$f|downloaded")
  done
  (( ${#opts[@]} )) || die "No container templates: the index is empty and $CT_TPL_STORE has none. Check Internet access and run: pveam update"
  for k in "$DEF_CT_TEMPLATE" debian-13-standard debian-12-standard; do
    [[ -n "${CT_AVAIL[$k]:-}" ]] && { def="$k"; break; }
  done
  hint "Templates from the Proxmox index (pveam available --section system)"
  local pick; MENU_FREE=v_ct_tpl menu pick "Template" "${def:-${opts[0]%%|*}}" "${opts[@]}"
  CT_TPL="${CT_AVAIL[$pick]:-$pick}"
  if [[ -z "${CT_HAVE[$CT_TPL]:-}" && " ${CT_AVAIL[*]} " != *" $CT_TPL "* ]]; then
    die "$CT_TPL is neither in the index nor on $CT_TPL_STORE"
  fi
  CT_KEY="${CT_TPL%%_*}"
  CT_TPL_VOLID="${CT_TPL_STORE}:vztmpl/${CT_TPL}"
  CT_TPL_LOCAL=0; [[ -n "${CT_HAVE[$CT_TPL]:-}" ]] && CT_TPL_LOCAL=1
  return 0
}

step_ct() {
  hdr "Container"
  local next; next="$(pvesh get /cluster/nextid 2>/dev/null || true)"; [[ "$next" =~ ^[0-9]+$ ]] || next=100
  ask VMID "CT ID (next free: $next)" "$next" v_vmid
  ask VMNAME "Hostname" "${CT_KEY%%-*}-${VMID}" v_name

  echo; echo "${C_B}CPU and memory${C_0} ${C_D}(host: $(host_cores) threads, $(host_mem_mb) MB total, $(host_mem_mb MemAvailable) MB available)${C_0}"
  local opts=() c hc hm m; hc="$(host_cores)" hm="$(host_mem_mb)"
  for c in 1 2 4 8 16; do (( c <= hc )) && opts+=("$c|"); done
  MENU_FREE=v_cores menu CORES "CPU cores" "$DEF_CT_CORES" "${opts[@]}"
  opts=()
  for m in 256 512 1024 2048 4096 8192; do (( hm == 0 || m <= hm )) && opts+=("$m|"); done
  MENU_FREE=v_ct_mem menu MEM "Memory (MB)" "$DEF_CT_MEM" "${opts[@]}"
  (( hm == 0 || MEM <= hm )) || warn "$MEM MB is more than the host has"
  MENU_FREE=v_ct_swap menu CT_SWAP "Swap (MB)" "$DEF_CT_SWAP" "0|no swap" "256|" "512|" "1024|"

  echo; echo "${C_B}Root disk${C_0}"
  pick_storage STORAGE rootdir "Storage for the root disk" "${DEF_CT_STORAGE:-${DEF_STORAGE:-local-lvm}}"
  MENU_FREE=v_ct_disk menu DISK_SIZE "Disk size (GiB)" "$DEF_CT_DISK" "4|" "8|" "16|" "32|" "64|"
  DISK_SIZE="${DISK_SIZE%[Gg]}"

  echo; echo "${C_B}Type${C_0}"
  local t
  menu t "Container type" unprivileged \
    "unprivileged|recommended; root in the container is mapped to an unprivileged host user" \
    "privileged|only if needed, e.g. NFS/CIFS mounts inside the container"
  CT_UNPRIV=0; [[ "$t" == unprivileged ]] && CT_UNPRIV=1
  CT_NEST=0
  ask_yn "Enable nesting (needed by systemd in current templates and by Docker)?" "$([[ $CT_UNPRIV == 1 ]] && echo y || echo n)" && CT_NEST=1
  return 0
}

step_ct_login() {
  hdr "Login"
  hint "The container is accessed as root. 'pct enter ID' on the host opens a root shell without a password."
  pick_sshkeys
  ask_vm_password
}

step_ct_options() {
  hdr "Options"
  ONBOOT=0; ask_yn "Start with the host (onboot)?" "$([[ $DEF_ONBOOT == 1 ]] && echo y || echo n)" && ONBOOT=1
  CT_START=0; ask_yn "Start the container after creation?" y && CT_START=1
  return 0
}

# ct_net I: the pct --netI value built from NIC_NET[I] and NIC_IPCFG[I]
ct_net() {
  local i="$1" net="${NIC_NET[$1]#virtio,}"
  echo "name=eth${i},${net}${NIC_IPCFG[i]:+,${NIC_IPCFG[i]}}"
}

summary_ct() {
  hdr "Summary"
  echo "  Template : $CT_TPL_VOLID $( (( CT_TPL_LOCAL )) && echo "(downloaded)" || echo "(will be downloaded)")"
  echo "  CT       : $VMID ($VMNAME) | $CORES core$( ((CORES == 1)) || echo s), $MEM MB, swap $CT_SWAP MB, ${DISK_SIZE}G on $STORAGE"
  echo "  Type     : $( (( CT_UNPRIV )) && echo unprivileged || echo privileged)$( (( CT_NEST )) && echo ", nesting")"
  local i
  for i in "${!NIC_NET[@]}"; do echo "  net$i     : $(ct_net "$i")"; done
  echo "  DNS      : $DNS | search ${SEARCHDOMAIN}"
  echo "  Login    : root | ssh keys: $([[ -n $SSHKEY_FILE ]] && echo yes || echo no) | password: $([[ -n $CIPASS ]] && echo yes || echo no)"
  echo "  Options  : onboot=$ONBOOT start=$CT_START"
  echo
  confirm "Create this container?" || die "Aborted"
}

build_ct() {
  if (( ! CT_TPL_LOCAL )); then
    log "Downloading $CT_TPL to $CT_TPL_STORE"
    run pveam download "$CT_TPL_STORE" "$CT_TPL"
  fi
  local args=(--hostname "$VMNAME" --cores "$CORES" --memory "$MEM" --swap "$CT_SWAP"
              --rootfs "${STORAGE}:${DISK_SIZE}" --unprivileged "$CT_UNPRIV" --onboot "$ONBOOT"
              --tags "create-ct;${CT_KEY//./-}"
              --description "Created by proxmox-toolbelt.sh $VERSION on $(date -u +%F) from $CT_TPL")
  (( CT_NEST )) && args+=(--features nesting=1)
  local i
  for i in "${!NIC_NET[@]}"; do args+=("--net$i" "$(ct_net "$i")"); done
  [[ "$DNS" != host ]] && args+=(--nameserver "$DNS")
  [[ "$SEARCHDOMAIN" != none && -n "$SEARCHDOMAIN" ]] && args+=(--searchdomain "$SEARCHDOMAIN")
  [[ -n "$SSHKEY_FILE" ]] && args+=(--ssh-public-keys "$SSHKEY_FILE")
  [[ -n "$CIPASS" ]] && args+=(--password "$CIPASS")

  # pct create removes the container and its volume itself if it fails
  log "Creating container $VMID"
  run pct create "$VMID" "$CT_TPL_VOLID" "${args[@]}"
}

start_ct() {
  CT_IPS=""
  (( CT_START )) || return 0
  log "Starting container $VMID"
  if (( DRY_RUN )); then run pct start "$VMID"; return 0; fi
  if ! pct start "$VMID"; then
    CT_START=0
    warn "Container $VMID was created but did not start. Details: pct start $VMID --debug"
    return 0
  fi
  local n
  for n in 1 2 3 4 5 6 7 8 9 10; do
    CT_IPS="$(lxc-info -n "$VMID" -iH 2>/dev/null | grep -v ':' | paste -sd' ' -)" || true
    [[ -n "$CT_IPS" ]] && break
    sleep 1
  done
  return 0
}

report_ct() {
  hdr "Done"
  echo "  CT $VMID ($VMNAME) $CT_KEY: $( (( CT_START )) && echo running || echo stopped)"
  echo "  Hostname : $VMNAME"
  local i; for i in "${!NIC_DESC[@]}"; do echo "  net$i     : ${NIC_DESC[i]}"; done
  echo "  DNS      : $( [[ $DNS == host ]] && echo "host settings ($(host_resolvers))" || echo "$DNS")$( [[ -n $SEARCHDOMAIN && $SEARCHDOMAIN != none ]] && echo " | search $SEARCHDOMAIN")"
  [[ -n "${CT_IPS:-}" ]] && echo "  IPv4     : $CT_IPS"
  echo "  User     : root"
  (( PASS_GENERATED )) && echo "  Password : $CIPASS   ${C_Y}(generated, store it now; it is not shown again)${C_0}"
  echo "  Shell    : pct enter $VMID"
  if [[ -z "$SSHKEY_FILE" && "$CT_KEY" =~ ^(debian|ubuntu) ]]; then
    hint "Debian and Ubuntu templates allow root SSH login by key only (PermitRootLogin prohibit-password)."
    hint "Use pct enter, or add a key to /root/.ssh/authorized_keys in the container."
  fi
  return 0
}

create_ct() {
  local dep
  for dep in pct pveam pvesm pvesh; do command -v "$dep" >/dev/null || die "Missing dependency: $dep"; done
  echo "${C_B}Proxmox container builder $VERSION${C_0}$( (( DRY_RUN )) && echo "  ${C_Y}[dry-run]${C_0}")"
  step_ct_template
  step_ct
  step_network
  step_ct_login
  step_ct_options
  summary_ct
  build_ct
  offer_vm_firewall lxc
  start_ct
  report_ct
}

# ---------------------------------------------------------------------------
# VMs and containers
# ---------------------------------------------------------------------------
agent_ips() { # VMID -> space separated IPv4s from the guest agent
  timeout 4 qm guest cmd "$1" network-get-interfaces 2>/dev/null | perl -MJSON::PP -e '
    local $/; my $d = eval { JSON::PP->new->decode(scalar <STDIN>) } or exit 0;
    my @ip; for my $i (@$d) { next if ($i->{name} // "") eq "lo";
      for my $a (@{ $i->{"ip-addresses"} // [] }) { push @ip, $a->{"ip-address"} if ($a->{"ip-address-type"} // "") eq "ipv4" && $a->{"ip-address"} !~ /^127\./ } }
    print join(" ", @ip);' 2>/dev/null || true
}

view_guests() {
  hdr "VMs and containers"
  local res nb
  res="$(pj /cluster/resources --type vm)" || die "Could not list guests"
  nb=" $(pj /cluster/backup-info/not-backed-up | jrows vmid | paste -sd' ' - || true) "
  printf '  %-6s %-3s %-22s %-8s %-8s %-24s %-20s %-6s %-6s %s\n' ID T NAME STATUS NODE NETWORK ADDRESS ONBOOT BACKUP SNAPS
  local vmid type name status node tpl conf net ips onboot snaps
  while IFS='|' read -r vmid type name status node tpl; do
    [[ -n "$vmid" ]] || continue
    conf="$PVE_DIR/nodes/$node/$([[ $type == lxc ]] && echo lxc || echo qemu-server)/$vmid.conf"
    net="$(awk '/^\[/{exit} /^net[0-9]+:/{b=""; t=""; n=split($2,kv,","); for(i=1;i<=n;i++){split(kv[i],p,"="); if(p[1]=="bridge")b=p[2]; if(p[1]=="tag")t=p[2]} printf "%s%s ", b, (t!=""?"."t:"")}' "$conf" 2>/dev/null || true)"
    onboot="$(awk -F': ' '/^\[/{exit} $1=="onboot"{print $2}' "$conf" 2>/dev/null || true)"
    snaps="$(awk '/^\[/ && !/^\[(PENDING|special:)/{n++} END{print n+0}' "$conf" 2>/dev/null || echo 0)"
    ips=""
    if [[ "$status" == running && "$node" == "$NODE" ]]; then
      if [[ "$type" == qemu ]] && grep -qE '^agent:.*(1|enabled=1)' "$conf" 2>/dev/null; then ips="$(agent_ips "$vmid")"; [[ -n "$ips" ]] || ips="(no agent reply)"
      elif [[ "$type" == lxc ]]; then ips="$(lxc-info -n "$vmid" -iH 2>/dev/null | grep -v ':' | paste -sd' ' - || true)"; fi
    fi
    [[ -n "$ips" ]] || ips="$(grep -oE '(^ipconfig[0-9]+:|^net[0-9]+:).*ip=[0-9.]+/[0-9]+' "$conf" 2>/dev/null | grep -oE 'ip=[0-9.]+' | cut -d= -f2 | paste -sd' ' - || true)"
    local st_col="$C_D"; [[ "$status" == running ]] && st_col="$C_G"
    [[ "$tpl" == 1 ]] && status="template"
    printf '  %-6s %-3s %-22.22s %s%-8s%s %-8.8s %-24.24s %-20.20s %-6s %-6s %s\n' "$vmid" "$([[ $type == lxc ]] && echo CT || echo VM)" "${name:-}" \
      "$st_col" "$status" "$C_0" "$node" "${net:--}" "${ips:--}" "$([[ $onboot == 1 ]] && echo yes || echo no)" \
      "$([[ "$tpl" == 1 ]] && echo - || { [[ "$nb" == *" $vmid "* ]] && echo "${C_Y}none${C_0}" || echo yes; })" "$snaps"
  done < <(jrows vmid type name status node template <<<"$res" | sort -t'|' -k1,1n)
}

next_free_id() {
  local id="$1"
  while compgen -G "$PVE_DIR/nodes/*/*/$id.conf" >/dev/null || qm status "$id" &>/dev/null; do id=$(( id + 1 )); done
  echo "$id"
}

build_templates() {
  preflight
  hdr "Build cloud-init templates"
  hint "Creates one template per selected distribution."
  local i key label user opts=() keys=()
  for i in "${!CATALOG[@]}"; do
    IFS='|' read -r key label user _ _ <<<"${CATALOG[i]}"
    [[ "$key" == custom ]] && continue
    keys+=("$key"); printf '  %2d) %-14s %s%s (user %s)%s\n' "${#keys[@]}" "$key" "$C_D" "$label" "$user" "$C_0"
  done
  local sel picked=() s
  while true; do
    ask sel "Distros (numbers or keys, comma separated, or 'all')" "1,2,4" v_any
    picked=()
    [[ "$sel" == all ]] && { picked=("${keys[@]}"); break; }
    for s in ${sel//,/ }; do
      if [[ "$s" =~ ^[0-9]+$ ]] && (( s >= 1 && s <= ${#keys[@]} )); then picked+=("${keys[s-1]}")
      elif ip_in_use "$s" "${keys[@]}"; then picked+=("$s")
      else echo "  Unknown: $s" >&2; picked=(); break; fi
    done
    (( ${#picked[@]} )) && break
  done

  echo; echo "${C_B}Storage${C_0}"; pick_storage STORAGE
  discover_network
  echo; echo "${C_B}Network${C_0} ${C_D}(templates use DHCP; set a static IP per clone in its Cloud-Init tab)${C_0}"
  local br; menu br "Bridge" "$(default_bridge)" "${BRIDGE_OPTS[@]}"
  local tag; MENU_FREE=v_vlan menu tag "VLAN tag" none "none|untagged"; [[ "$tag" == none ]] && tag=""
  local net="virtio,bridge=${br},firewall=${DEF_FW}${tag:+,tag=$tag}"

  local onename=""
  ask_yn "Use each distro's usual login name (ubuntu, debian, rocky...)?" y || ask onename "Login name for all templates" "admin" v_user
  pick_sshkeys
  ask_vm_password
  UPGRADE=0; ask_yn "Upgrade packages on first boot of each clone?" "$([[ $DEF_UPGRADE == 1 ]] && echo y || echo n)" && UPGRADE=1
  pick_snippet_store
  local start; start="$(next_free_id "$DEF_TEMPLATE_ID")"

  hdr "Summary"
  local id="$start" plan=()
  for key in "${picked[@]}"; do
    id="$(next_free_id "$id")"; plan+=("$key|$id")
    echo "  $id  tpl-${key//./-}"; id=$(( id + 1 ))
  done
  echo "  each: $DEF_CORES core$( ((DEF_CORES == 1)) || echo s), $DEF_MEM MB, $DEF_DISK on $STORAGE, cpu $DEF_CPU, $DEF_BIOS, $br${tag:+ vlan $tag} dhcp"
  echo
  confirm "Build ${#plan[@]} template(s)?" || return 0

  CORES="$DEF_CORES" MEM="$DEF_MEM" DISK_SIZE="$DEF_DISK" CPU="$DEF_CPU" BIOS="$DEF_BIOS"
  [[ "$DISK_SIZE" =~ [GT]$ ]] || DISK_SIZE="${DISK_SIZE}G"
  ONBOOT=0 FINISH=template DNS=host SEARCHDOMAIN=none
  NIC_NET=("$net") NIC_IPCFG=("ip=dhcp") NIC_DESC=("$br${tag:+ vlan $tag} dhcp")
  local p done_list=() cpu_keep="$CPU"
  for p in "${plan[@]}"; do
    catalog_select "${p%%|*}"; VMID="${p#*|}"
    hdr "$DISTRO_LABEL -> template $VMID"
    resolve_image
    CPU="$cpu_keep"
    [[ "$DISTRO" =~ ^(rocky|alma)-10$ && "$CPU" =~ ^(x86-64-v2|x86-64-v2-AES|kvm64|qemu64)$ ]] && { warn "$DISTRO needs x86-64-v3; using host"; CPU=host; }
    VMNAME="tpl-${DISTRO//./-}" CIUSER="${onename:-$DISTRO_USER}"
    build
    done_list+=("$VMID $VMNAME")
  done
  hdr "Done"
  for p in "${done_list[@]}"; do echo "  $p"; done
  (( PASS_GENERATED )) && echo "  Password : $CIPASS   ${C_Y}(generated, store it now; it is not shown again)${C_0}"
  echo "  Clone one: qm clone <template-id> <new-id> --name web-01 --full 1"
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# System information
# ---------------------------------------------------------------------------
view_sysinfo() {
  hdr "System information"
  local f="%-14s: %s\n" ip hosts dr dev gw
  ip="$(node_ip)"; dr="$(default_route)"; dev="${dr%%|*}" gw="${dr#*|}"
  hosts="$(getent ahostsv4 "$NODE" 2>/dev/null | awk 'NR==1{print $1}')"
  # shellcheck disable=SC2059
  {
  printf "  $f" "Hostname" "$(hostname 2>/dev/null || echo "$NODE")"
  printf "  $f" "FQDN" "$(host_fqdn)"
  printf "  $f" "Node resolves" "${hosts:-not resolvable}  (/etc/hosts)$([[ -z $hosts || $hosts == 127.* ]] && echo "  ${C_Y}must be the node address${C_0}")"
  printf "  $f" "Web GUI" "https://${ip:-?}:8006/"
  printf "  $f" "SSH" "ssh root@${ip:-?}"
  echo
  local n a d port cm
  while read -r _ n _ a _; do
    [[ -n "$n" ]] || continue
    port="$(ip -o link show master "$n" 2>/dev/null | awk -F': ' '{sub(/@.*/,"",$2); printf "%s ", $2}')"
    cm="$(iface_comment "$n")"
    d="$a${port:+  ports ${port% }}${cm:+  \"$cm\"}"
    [[ "$n" == "$dev" ]] && d+="  (default route)"
    printf "  $f" "$n" "$d"
  done < <(ip -4 -o addr show scope global 2>/dev/null)
  printf "  $f" "Gateway" "${gw:-none}${dev:+ via $dev}"
  printf "  $f" "DNS servers" "$(host_resolvers || true)"
  printf "  $f" "Search domain" "$(host_search_domain | grep . || echo none)"
  echo
  local os mem_t mem_a sw cpu sock cores thr up load
  os="$(awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2; exit}' "$OS_RELEASE" 2>/dev/null || true)"
  printf "  $f" "Proxmox VE" "$(pveversion 2>/dev/null || echo unknown)"
  printf "  $f" "OS" "${os:-unknown}, kernel $(uname -r)"
  cpu="$(awk -F': ' '/^model name/{print $2; exit}' "$CPUINFO" 2>/dev/null)"
  sock="$(awk -F': ' '/^physical id/{print $2}' "$CPUINFO" 2>/dev/null | sort -u | wc -l)"
  cores="$(awk -F': ' '/^core id/{print $2}' "$CPUINFO" 2>/dev/null | sort -u | wc -l)"
  thr="$(host_cores)"
  (( sock > 0 && cores > 0 )) && cores=$(( sock * cores )) || cores="?"
  printf "  $f" "CPU" "${cpu:-unknown}, ${sock:-?} socket(s), $cores cores, $thr threads"
  mem_t="$(host_mem_mb)" mem_a="$(host_mem_mb MemAvailable)" sw="$(host_mem_mb SwapTotal)"
  printf "  $f" "Memory" "$(( mem_t - mem_a )) MB used of $mem_t MB, swap $sw MB"
  read -r up load < <(awk '{printf "%d ", $1}' /proc/uptime 2>/dev/null; awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
  printf "  $f" "Uptime" "$(( ${up:-0} / 86400 ))d $(( ${up:-0} % 86400 / 3600 ))h, load $load"
  printf "  $f" "Boot" "$([[ -d /sys/firmware/efi ]] && echo UEFI || echo "legacy BIOS")"
  printf "  $f" "Time" "$(date '+%F %T %Z'), NTP $(timedatectl show -p NTPSynchronized --value 2>/dev/null | sed 's/yes/synchronized/;s/no/not synchronized/' || echo unknown)"
  printf "  $f" "Subscription" "$(subscription_status)"
  if is_cluster; then
    printf "  $f" "Cluster" "$(awk '$1=="cluster_name:"{print $2; exit}' "$PVE_DIR/corosync.conf" 2>/dev/null), nodes: $(awk '$1=="name:"{printf "%s ", $2}' "$PVE_DIR/corosync.conf" 2>/dev/null)"
  else
    printf "  $f" "Cluster" "single node"
  fi
  }
  return 0
}

# pkg_version: version of the installed proxmox-toolbelt Debian package, empty if not installed
pkg_version() { dpkg-query -W -f='${Status} ${Version}\n' proxmox-toolbelt 2>/dev/null | awk '$3=="installed"{print $4}' || true; }

fix_install() {
  hdr "Install proxmox-toolbelt"
  local pv; pv="$(pkg_version)"
  if [[ -n "$pv" ]]; then
    log "Installed as Debian package proxmox-toolbelt $pv (/usr/sbin/proxmox-toolbelt)"
    hint "Update by installing a newer .deb: apt install ./proxmox-toolbelt_<version>_all.deb"
    return 0
  fi
  local src dst="$INSTALL_PATH" old; src="$(readlink -f "${BASH_SOURCE[0]}")"
  if [[ -e "$dst" ]]; then
    old="$(awk -F'"' '/^VERSION=/{print $2; exit}' "$dst" 2>/dev/null)"
    cmp -s "$src" "$dst" && { log "$dst is already this version ($VERSION)"; return 0; }
    confirm "Replace $dst (version ${old:-unknown}) with version $VERSION?" || return 0
  else
    confirm "Install version $VERSION as $dst?" || return 0
  fi
  run install -m 755 "$src" "$dst"
  (( DRY_RUN )) || log "Installed as $dst. Remove with: proxmox-toolbelt uninstall"
}

INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/proxmox-toolbelt}"

# du_h PATH...: total size, e.g. 1.2G
du_h() { du -sch "$@" 2>/dev/null | awk 'END{print $1}'; }

# toolbelt_snippets: "store|volid|path|referenced-by" for the cloud-init vendor snippets the VM builder wrote
toolbelt_snippets() {
  local st name p refs
  while read -r st; do
    for name in create-vm-vendor.yaml create-vm-vendor-upgrade.yaml; do
      p="$(pvesm path "$st:snippets/$name" 2>/dev/null)" || continue
      [[ -f "$p" ]] || continue
      refs="$(grep -l "snippets/$name" "$PVE_DIR"/nodes/*/qemu-server/*.conf 2>/dev/null \
              | awk -F/ '{sub(/\.conf$/,"",$NF); printf "%s ", $NF}')" || true
      echo "$st|$st:snippets/$name|$p|${refs% }"
    done
  done < <(pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}')
}

fix_uninstall() {
  hdr "Uninstall proxmox-toolbelt"
  hint "Removes files that proxmox-toolbelt created on this node. Each group is confirmed separately."
  hint "Not touched: VMs, containers, templates, downloaded CT templates, notification targets, repository settings."
  echo

  if command -v tmux >/dev/null && tmx has-session -t "$JOB_SESSION" 2>/dev/null; then
    die "tmux session '$JOB_SESSION' still exists (package job). Finish it first: $JOB_ATTACH"
  fi
  local timers
  timers="$(systemctl list-units --all --plain --no-legend 'proxmox-toolbelt-ssh-revert-*' 2>/dev/null | awk '{printf "%s ", $1}')" || true
  [[ -z "$timers" ]] || die "SSH revert pending ($timers). Wait until it has run, then uninstall."

  local removed=0

  # 1) SSH drop-in (also the one from the earlier name pve-toolkit): removing it changes SSH settings
  local dropin
  for dropin in "$SSHD_DIR/sshd_config.d/$SSH_DROPIN" "$SSHD_DIR/sshd_config.d/01-pve-toolkit.conf"; do
  [[ -e "$dropin" ]] || continue
    echo "${C_B}SSH settings${C_0}  $dropin"
    hint "Removing it restores the SSH settings from sshd_config (root password login may be allowed again)."
    if confirm "Remove the SSH drop-in and reload ssh?"; then
      run rm -f "$dropin"
      if (( ! DRY_RUN )); then
        if sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd || warn "Reload ssh manually: systemctl reload ssh"
        else warn "sshd -t reports an error in the remaining configuration; ssh was not reloaded"; fi
      fi
      removed=$(( removed + 1 ))
    fi
    echo
  done

  # 2) cloud-init vendor snippets, only when no VM references them
  local st vol p refs free=()
  while IFS='|' read -r st vol p refs; do
    [[ -n "$vol" ]] || continue
    if [[ -n "$refs" ]]; then hint "Kept $vol: used by VM $refs (cicustom)"; else free+=("$p"); fi
  done < <(toolbelt_snippets)
  if (( ${#free[@]} )); then
    echo "${C_B}Cloud-init snippets${C_0}  ${free[*]}"
    confirm "Remove ${#free[@]} unused snippet file(s)?" && { run rm -f "${free[@]}"; removed=$(( removed + 1 )); }
    echo
  fi

  # 3) cloud image cache of the VM builder
  if [[ -d "$IMG_DIR" ]]; then
    echo "${C_B}Cloud image cache${C_0}  $IMG_DIR  ($(du_h "$IMG_DIR"))"
    if [[ "${IMG_DIR%/}" != */cloudimg ]]; then
      hint "Skipped: IMG_DIR does not end in /cloudimg; remove it manually if it holds only images."
    else
      hint "Templates and VMs do not use these files after creation."
      confirm "Delete the image cache?" && { run rm -rf -- "${IMG_DIR%/}"; removed=$(( removed + 1 )); }
    fi
    echo
  fi

  # 4) backups of files the fixes edited (also /root/pve-toolkit-backups from the earlier name)
  local bdir
  for bdir in "$BACKUP_ROOT" /root/pve-toolkit-backups; do
  [[ -d "$bdir" ]] || continue
  BACKUP_ROOT="$bdir"
  if [[ -d "$BACKUP_ROOT" ]]; then
    echo "${C_B}Backups of edited files${C_0}  $BACKUP_ROOT  ($(du_h "$BACKUP_ROOT"), $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 | wc -l) run(s))"
    if [[ "${BACKUP_ROOT%/}" != *proxmox-toolbelt-backups && "${BACKUP_ROOT%/}" != */pve-toolkit-backups ]]; then
      hint "Skipped: BACKUP_ROOT is not a proxmox-toolbelt-backups directory."
    else
      hint "These are the only copies of SSH and apt files as they were before a change."
      confirm "Delete the backups?" && { run rm -rf -- "${BACKUP_ROOT%/}"; removed=$(( removed + 1 )); }
    fi
    echo
  fi
  done

  # 5) scheduled snapshot/backup jobs: timers, job files, state, logs (snapshots and backups stay)
  local jobs j
  jobs="$(job_names | paste -sd' ' -)"
  if [[ -n "$jobs" || -e "$UNIT_DIR/$JOB_UNIT@.service" || -d "$SCHED_STATE" || -d "$SCHED_LOG" ]]; then
    echo "${C_B}Scheduled jobs${C_0}  ${jobs:-no jobs left} ($SCHED_DIR, timers in $UNIT_DIR, logs in $SCHED_LOG)"
    hint "Snapshots and backup files that the jobs made are kept."
    if confirm "Remove the scheduled jobs, their timers, state and logs?"; then
      for j in $jobs; do job_remove "$j"; done
      run rm -f "$UNIT_DIR/$JOB_UNIT@.service" "$UNIT_DIR/$RECOVER_UNIT"
      run rm -rf -- "$SCHED_STATE" "$SCHED_LOG"
      [[ -d "$SCHED_DIR" ]] && run rmdir --ignore-fail-on-non-empty "$SCHED_DIR" "$(dirname "$SCHED_DIR")"
      removed=$(( removed + 1 ))
    fi
    echo
  fi

  # 6) program and defaults file
  local pv; pv="$(pkg_version)"
  if [[ -n "$pv" ]]; then
    echo "${C_B}Debian package${C_0}  proxmox-toolbelt $pv"
    confirm "Remove the package (apt-get purge proxmox-toolbelt)?" && { run apt-get purge -y proxmox-toolbelt; removed=$(( removed + 1 )); }
    echo
  fi
  local prog=() f
  for f in "$INSTALL_PATH" /etc/proxmox-toolbelt.conf /etc/create-vm.conf "$JOB_RC_FILE" \
           /usr/local/sbin/pve-toolkit /run/pve-toolkit.rc; do
    [[ -e "$f" ]] && prog+=("$f")
  done
  if (( ${#prog[@]} )); then
    echo "${C_B}Program and defaults file${C_0}  ${prog[*]}"
    confirm "Remove these file(s)?" && { run rm -f -- "${prog[@]}"; removed=$(( removed + 1 )); }
    echo
  fi

  if (( removed == 0 )); then log "Nothing removed"
  else log "Done. This copy of the script ($(readlink -f "${BASH_SOURCE[0]}")) can be deleted by hand."; fi
}

view_settings() {
  hdr "Settings"
  echo "  Defaults file : $CONF_FILE $([[ -f $CONF_FILE ]] && echo "(loaded)" || echo "(not present)")"
  echo "  Image cache   : $IMG_DIR"
  echo "  File backups  : $BACKUP_ROOT"
  echo
  if [[ -f "$CONF_FILE" ]]; then sed 's/^/  /' "$CONF_FILE"
  else hint "To change builder defaults, copy proxmox-toolbelt.conf.example to $CONF_FILE (owner root, mode 600 or 644)."; fi
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
# Entries: "label|function|view or fix" (read through ${!arr} in submenu)
# shellcheck disable=SC2034
{
MENU_TITLES=([2]="Security" [3]="Updates and repositories" [4]="Storage and disks" [5]="Backups" [6]="Notifications" [7]="VMs and containers" [8]="System and settings")
MENU_2=("Users and two-factor status|view_tfa|view" "Harden SSH (root by key only, no passwords)|fix_ssh|fix"
        "Add an SSH public key for root|fix_ssh_addkey|fix" "Web GUI certificate and ACME|view_cert|view"
        "Firewall status|view_firewall|view")
MENU_3=("Switch repository (no-subscription / enterprise)|fix_repos|fix" "Install updates (apt full-upgrade)|fix_updates|fix"
        "Install CPU microcode|fix_microcode|fix" "Show Proxmox package versions|view_versions|view")
MENU_4=("Storage usage and content types|view_storage|view" "Enable snippets on a storage|fix_snippets|fix"
        "Disks: used, unused, SMART, wear|view_disks|view" "Unused and orphaned disk images|view_orphans|view")
MENU_5=("Backup jobs and guests not covered|view_backups|view" "Recent backup runs|view_backup_tasks|view"
        "Scheduled snapshots and backups: list and status|view_schedules|view"
        "Add a scheduled snapshot job (every 10m, 1h, 1d, ...)|add_snapshot_job|fix"
        "Add a scheduled backup job (vzdump, any storage)|add_backup_job|fix"
        "Run, test, pause, resume or remove a scheduled job|manage_jobs|fix")
MENU_6=("Set root@pam e-mail|fix_root_email|fix" "Add SMTP e-mail target (Gmail, Outlook, custom)|fix_smtp|fix"
        "Add Gotify target|fix_gotify|fix" "Add ntfy target|fix_ntfy|fix" "Add alert rule (matcher)|fix_matcher|fix"
        "Send a test notification|fix_test_notify|fix" "Show targets and rules|view_notify|view")
MENU_7=("List VMs and containers|view_guests|view" "Create a VM (cloud-init image)|create_vm|fix"
        "Create a container (LXC template)|create_ct|fix" "Build VM templates for several distros|build_templates|fix")
MENU_8=("System information (hostname, addresses, DNS, hardware)|view_sysinfo|view"
        "Install as /usr/local/sbin/proxmox-toolbelt|fix_install|fix" "Show settings and defaults file|view_settings|view"
        "Uninstall from this node|fix_uninstall|fix")
}

STALE=1
# do_action FUNCTION KIND: runs in a subshell so an error returns to the menu
do_action() {
  local fn="$1" kind="$2" rc
  trap ':' INT
  ERR_LEVEL=-1   # the ERR trap stays quiet in this shell; the subshell reports its own failures
  set +e
  # shellcheck disable=SC2034  # read by the ERR trap
  ( ERR_LEVEL=$BASH_SUBSHELL; set -e; trap on_exit EXIT; trap 'exit 130' INT TERM; BACKUP_DIR="" TMP_FILES=() TMP_DIRS=(); "$fn" )
  rc=$?
  set -e
  restore_tty
  # shellcheck disable=SC2034  # read by the ERR trap
  ERR_LEVEL=0
  trap 'exit 130' INT
  if (( rc == 130 )); then echo; echo "${C_D}(cancelled)${C_0}"; return 0; fi
  (( rc != 0 )) && echo "${C_D}(action aborted)${C_0}"
  [[ "$kind" == fix ]] && STALE=1
  pause
}

submenu() {
  local n="$1" pick="${2:-}" arr="MENU_$1[@]" items=() i e
  items=("${!arr}")
  while true; do
    if [[ -z "$pick" ]]; then
      hdr "${MENU_TITLES[n]}"
      for i in "${!items[@]}"; do e="${items[i]}"; printf '  %d.%d) %s%s\n' "$n" $(( i + 1 )) "${e%%|*}" "$([[ ${e##*|} == fix ]] && echo "  ${C_D}[change]${C_0}")"; done
      echo "    b) back"
      read -erp "Choice: " pick || exit 0
      pick="${pick#"$n".}"
    fi
    case "$pick" in
      b|B|"") return 0 ;;
      q|Q) exit 0 ;;
    esac
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#items[@]} )); then
      e="${items[pick-1]}"; local rest="${e#*|}"
      do_action "${rest%%|*}" "${rest#*|}"
      return 0
    fi
    echo "  Pick 1-${#items[@]} or b" >&2; pick=""
  done
}

main_menu() {
  local c
  while true; do
    if (( STALE )); then printf '%sChecking...%s' "$C_D" "$C_0"; run_checks; printf '\r\e[K'; STALE=0; fi
    echo; header_line; echo
    print_results 0
    echo
    echo "  1) Full report      2) Security    3) Updates     4) Storage   5) Backups"
    echo "  6) Notifications    7) VMs/CTs     8) System      r) Re-check  q) Quit"
    echo "  ${C_D}Enter a menu number or an entry such as 2.2 (7.2 create VM, 5.4 scheduled snapshots).${C_0}"
    read -erp "Choice: " c || { echo; exit 0; }
    case "$c" in
      q|Q) exit 0 ;;
      r|R) STALE=1 ;;
      1) hdr "Full report"; print_results 1; pause ;;
      [2-8]) submenu "$c" ;;
      [2-8].[0-9]*) [[ -n "${MENU_TITLES[${c%%.*}]:-}" ]] && submenu "${c%%.*}" "${c#*.}" || echo "  Unknown choice" >&2 ;;
      "") ;;
      *) echo "  Unknown choice" >&2 ;;
    esac
  done
}

usage() {
  cat <<EOF
proxmox-toolbelt.sh $VERSION - health checks, configuration changes, VM and container builders for Proxmox VE

  proxmox-toolbelt.sh [--dry-run]              status board and menu
  proxmox-toolbelt.sh check [--json] [--details]
                                             run checks once; exit 0 OK, 1 warnings, 2 failures
  proxmox-toolbelt.sh info                     system information (hostname, addresses, DNS, hardware)
  proxmox-toolbelt.sh uninstall                remove the installed script, defaults file, caches and backups
  proxmox-toolbelt.sh create-vm [--dry-run]    VM builder (same as create-vm.sh)
  proxmox-toolbelt.sh create-ct [--dry-run]    container builder (same as create-ct.sh)
  proxmox-toolbelt.sh templates [--dry-run]    VM template builder
  proxmox-toolbelt.sh schedule [list|add|run|status|log|pause|resume|remove|help]
                                             scheduled snapshots and backups (see: schedule help)

  --dry-run   print diffs and commands instead of applying them
  --help      show this help

Builder defaults: $CONF_FILE (see proxmox-toolbelt.conf.example).
EOF
}

main() {
  local mode=menu json=0 details=0 SCHED_ARGS=()
  case "${0##*/}" in create-vm*) mode=create-vm ;; create-ct*) mode=create-ct ;; esac
  while (( $# )); do
    case "$1" in
      check|info|uninstall|create-vm|create-ct|templates) mode="$1" ;;
      schedule) mode=schedule; shift; SCHED_ARGS=("$@"); break ;;
      --json) json=1 ;;
      --details|-v) details=1 ;;
      --dry-run|-n) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      --version) echo "$VERSION"; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
  if [[ "$mode" == schedule && "${SCHED_ARGS[0]:-}" =~ ^(help|--help|-h)$ ]]; then sched_usage; exit 0; fi
  save_tty
  load_config
  if [[ "$mode" == create-[vc][mt] ]] && (( DRY_RUN )); then :; else need_root; fi
  command -v pvesh >/dev/null || die "pvesh not found: run this on a Proxmox VE node"
  command -v perl >/dev/null || die "perl not found"
  TK_CACHE="$(mktemp -d)"; TMP_DIRS+=("$TK_CACHE")
  case "$mode" in
    check)
      run_checks
      if (( json )); then print_json; else header_line; print_results "$details"; fi
      local rc=0; results_rc || rc=$?
      exit "$rc" ;;
    info) view_sysinfo ;;
    schedule) sched_cli "${SCHED_ARGS[@]}" ;;
    uninstall)
      [[ -t 0 ]] || die "Run interactively (stdin must be a terminal)"
      fix_uninstall ;;
    create-vm|create-ct|templates)
      [[ -t 0 ]] || die "Run interactively (stdin must be a terminal)"
      case "$mode" in
        create-vm) create_vm ;;
        create-ct) create_ct ;;
        templates) build_templates ;;
      esac ;;
    menu)
      [[ -t 0 ]] || die "Run interactively (stdin must be a terminal), or use: $0 check"
      main_menu ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
