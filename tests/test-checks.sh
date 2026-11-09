#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals here are read by the sourced script
# Tests for the status checks and repository planning in proxmox-toolbelt.sh, using
# mocked Proxmox commands and fixture files (no Proxmox needed):
#   bash tests/test-checks.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=../proxmox-toolbelt.sh
source ./proxmox-toolbelt.sh
set +eE; trap - EXIT ERR INT TERM
C_B="" C_D="" C_G="" C_Y="" C_R="" C_C="" C_0=""

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: got '$2' want '$3'"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s: missing %q in:\n%s\n' "$1" "$3" "$2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then fail=$((fail + 1)); printf 'FAIL: %s: unexpected %q in:\n%s\n' "$1" "$3" "$2"; else pass=$((pass + 1)); fi; }

FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
PVE_DIR="$FX/pve" APT_DIR="$FX/apt" OS_RELEASE="$FX/os-release" CPUINFO="$FX/cpuinfo" ROOT_KEYS="$FX/authorized_keys" NODE=pve1
mkdir -p "$PVE_DIR/nodes/pve1/qemu-server" "$PVE_DIR/nodes/pve1/lxc" "$PVE_DIR/firewall" "$PVE_DIR/local" "$APT_DIR/sources.list.d"
echo 'VERSION_CODENAME=trixie' >"$OS_RELEASE"

# ---- mocks ---------------------------------------------------------------
declare -A PVESH=()
pvesh() { local p="$2"; [[ -n "${PVESH[$p]+x}" ]] || return 1; printf '%s\n' "${PVESH[$p]}"; }
SSHD_T="" SUBSCRIPTION="notfound" KEYS_OUT="" PVESM_OUT="" SNIP_OUT="" PVENODE_OUT=""
sshd() { [[ "$1" == -T ]] && printf '%s\n' "$SSHD_T"; }
ssh-keygen() { [[ -s "${3:-}" ]] && printf '%s\n' "$KEYS_OUT"; }
pvesubscription() { echo "status: $SUBSCRIPTION"; }
pvenode() { printf '%s\n' "$PVENODE_OUT"; }
pvesm() { if [[ "${2:-}" == --content && "${3:-}" == snippets ]]; then printf '%s\n' "$SNIP_OUT"; else printf '%s\n' "$PVESM_OUT"; fi; }
systemctl() { return 1; }
ceph() { return 1; }
lvs() { :; }
zpool() { :; }
postconf() { :; }

# ---- jrows / apt parsing ---------------------------------------------------
eq "jrows basic" "$(jrows a b c <<<'[{"a":"x|y","b":true,"c":[1,2]},{"a":"z"}]')" $'x y|1|1,2\nz||'
eq "jrows object" "$(jrows a <<<'{"a":5}')" "5"
eq "jrows bad json" "$(jrows a <<<'not json')" ""

cat >"$APT_DIR/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
cat >"$APT_DIR/sources.list.d/pve-enterprise.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
cat >"$APT_DIR/sources.list.d/ceph.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
ents="$(apt_entries)"
eq "deb822 entries" "$(grep -c . <<<"$ents")" 5
has "deb822 two suites" "$ents" "debian.sources|1|deb|http://deb.debian.org/debian|trixie-updates|main contrib"
eq "kind ent" "$(repo_kind https://enterprise.proxmox.com/debian/pve pve-enterprise)" pve-ent
eq "kind nosub" "$(repo_kind http://download.proxmox.com/debian/pve pve-no-subscription)" pve-nosub
eq "kind ceph" "$(repo_kind https://enterprise.proxmox.com/debian/ceph-squid enterprise)" ceph-ent
eq "kind debian security" "$(repo_kind http://security.debian.org/debian-security main)" debian
eq "ceph release" "$(ceph_release_of https://enterprise.proxmox.com/debian/ceph-squid)" squid

# ---- repositories: fresh PVE 9 without subscription -------------------------
out="$(chk_repos)"
has "pve9 enterprise no sub" "$out" "FAIL|Repository|enterprise enabled, no subscription (apt update fails with 401)|3.1"
has "pve9 ceph enterprise" "$out" "FAIL|Ceph repository|ceph-squid enterprise enabled"
hasnt "pve9 suites ok" "$out" "Repo suites"

stage="$FX/stage"; apt_stage "$stage"; repo_plan nosub "$stage"
has "ent disabled" "$(cat "$stage/sources.list.d/pve-enterprise.sources")" "Enabled: false"
has "nosub file" "$(cat "$stage/sources.list.d/proxmox.sources")" "Components: pve-no-subscription"
has "ceph converted uri" "$(cat "$stage/sources.list.d/ceph.sources")" "URIs: http://download.proxmox.com/debian/ceph-squid"
has "ceph converted comp" "$(cat "$stage/sources.list.d/ceph.sources")" "Components: no-subscription"
eq "debian untouched" "$(cmp -s "$stage/sources.list.d/debian.sources" "$APT_DIR/sources.list.d/debian.sources" && echo same)" same
out="$(APT_DIR="$stage" chk_repos)"
has "after plan ok" "$out" "OK|Repository|no-subscription|"
hasnt "after plan no ceph fail" "$out" "FAIL|Ceph"
cp -r "$stage" "$FX/stage2"; repo_plan nosub "$FX/stage2"
eq "plan is idempotent" "$(diff -r "$stage" "$FX/stage2" && echo same)" same
repo_plan enterprise "$FX/stage2"
out="$(APT_DIR="$FX/stage2" SUBSCRIPTION=active chk_repos)"
has "back to enterprise" "$out" "OK|Repository|enterprise (subscription active)"
has "nosub disabled again" "$(cat "$FX/stage2/sources.list.d/proxmox.sources")" "Enabled: false"
hasnt "ent enabled again" "$(cat "$FX/stage2/sources.list.d/pve-enterprise.sources")" "Enabled:"
has "ceph back to enterprise" "$(cat "$FX/stage2/sources.list.d/ceph.sources")" "URIs: https://enterprise.proxmox.com/debian/ceph-squid"

nff_plan "$stage"
eq "non-free-firmware added twice" "$(grep -c 'Components: main contrib non-free-firmware' "$stage/sources.list.d/debian.sources")" 2
hasnt "nff not on proxmox" "$(cat "$stage/sources.list.d/proxmox.sources")" "non-free-firmware"

# ---- repositories: PVE 8 one-line format --------------------------------
A8="$FX/apt8"; mkdir -p "$A8/sources.list.d"
printf 'deb http://deb.debian.org/debian bookworm main contrib\n# deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription\n' >"$A8/sources.list"
echo 'deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise' >"$A8/sources.list.d/pve-enterprise.list"
echo 'deb [arch=amd64] https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise' >"$A8/sources.list.d/ceph.list"
echo 'VERSION_CODENAME=bookworm' >"$FX/os8"
ents="$(apt_entries "$A8")"
has "list commented entry" "$ents" "sources.list|0|deb|http://download.proxmox.com/debian/pve|bookworm|pve-no-subscription"
has "list options skipped" "$ents" "ceph.list|1|deb|https://enterprise.proxmox.com/debian/ceph-quincy|bookworm|enterprise"
s8="$FX/stage8"; APT_DIR="$A8" apt_stage "$s8"; OS_RELEASE="$FX/os8" repo_plan nosub "$s8"
eq "pve8 ent commented" "$(cat "$s8/sources.list.d/pve-enterprise.list")" "# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise"
has "pve8 nosub uncommented" "$(cat "$s8/sources.list")" $'\ndeb http://download.proxmox.com/debian/pve bookworm pve-no-subscription'
eq "pve8 no new file" "$(ls "$s8/sources.list.d" | paste -sd' ' -)" "ceph.list pve-enterprise.list"
eq "pve8 ceph" "$(cat "$s8/sources.list.d/ceph.list")" "deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription"
out="$(APT_DIR="$s8" OS_RELEASE="$FX/os8" chk_repos)"
has "pve8 after plan" "$out" "OK|Repository|no-subscription|"
rm "$s8/sources.list"; echo 'deb http://deb.debian.org/debian bookworm main' >"$s8/sources.list"
APT_DIR="$A8" OS_RELEASE="$FX/os8" repo_plan nosub "$s8"
eq "pve8 creates list file" "$(cat "$s8/sources.list.d/pve-no-subscription.list")" "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
echo 'deb http://download.proxmox.com/debian/pve bullseye pve-no-subscription' >"$s8/sources.list.d/old.list"
out="$(APT_DIR="$s8" OS_RELEASE="$FX/os8" chk_repos)"
has "suite mismatch" "$out" "FAIL|Repo suites|not matching Debian bookworm: old.list: bullseye"

# ---- 2FA ------------------------------------------------------------------
PVESH[/access/users]='[{"userid":"root@pam","enable":1,"expire":0,"email":"","tokens":[{"tokenid":"ci","privsep":0,"expire":0}]},{"userid":"alice@pve","enable":1,"expire":0,"email":"a@x.io"},{"userid":"bob@pve","enable":0}]'
PVESH[/access/tfa]='[{"userid":"alice@pve","entries":[{"type":"totp","id":"t1","enable":true},{"type":"recovery","id":"recovery"}]}]'
PVESH[/access/domains]='[{"realm":"pam","type":"pam"},{"realm":"pve","type":"pve"}]'
out="$(chk_tfa)"
has "root no 2fa" "$out" "FAIL|2FA|not set up for root@pam (1 of 2 users without 2FA)|2.1"
has "token full rights" "$out" "WARN|API tokens|full user rights (no privilege separation): root@pam!ci|2.1"
has "alice detail" "$out" "-|2FA|alice@pve: recovery, totp|"
PVESH[/access/tfa]='[{"userid":"alice@pve","entries":[{"type":"totp"}]},{"userid":"root@pam","entries":[{"type":"webauthn"},{"type":"totp","enable":false}],"totp-locked":true}]'
PVESH[/access/users]='[{"userid":"root@pam","enable":1},{"userid":"alice@pve","enable":1},{"userid":"carol@pve","enable":1,"expire":1}]'
out="$(chk_tfa)"
has "all set" "$out" "OK|2FA|set up for all 2 users"
has "lockout" "$out" "WARN|2FA lockout|locked after failed attempts: root@pam"
has "no recovery hint" "$out" "alice@pve: totp  (no recovery keys)"
PVESH[/access/users]='[{"userid":"root@pam","enable":1},{"userid":"dave@pve","enable":1}]'
out="$(chk_tfa)"
has "other user missing" "$out" "WARN|2FA|not set up for dave@pve|2.1"

# ---- SSH ------------------------------------------------------------------
SSHD_T=$'port 22\npermitrootlogin yes\npasswordauthentication yes\nkbdinteractiveauthentication no\npubkeyauthentication yes\nusepam yes'
printf 'ssh-ed25519 AAAA test\n' >"$ROOT_KEYS"
KEYS_OUT='256 SHA256:abc root@x (ED25519)'
out="$(chk_ssh)"
has "root password" "$out" "WARN|SSH root login|password allowed (key-only recommended)|2.2"
has "passwords on" "$out" "WARN|SSH passwords|enabled for all users|2.2"
has "keys ok" "$out" "OK|SSH keys|1 valid key in root's authorized_keys|"
SSHD_T=$'permitrootlogin without-password\npasswordauthentication no\nkbdinteractiveauthentication yes\nusepam yes\npubkeyauthentication yes'
out="$(chk_ssh)"
has "kbd-interactive counts as password" "$out" "WARN|SSH passwords"
has "prohibit-password ok" "$out" "OK|SSH root login|keys only|"
SSHD_T=$'permitrootlogin no\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes'
touch "$PVE_DIR/corosync.conf"
KEYS_OUT=$'1024 SHA256:a x (RSA)\n256 SHA256:b y (ED25519)'
out="$(chk_ssh)"
has "cluster root no" "$out" "FAIL|SSH root login|disabled, but cluster nodes need root SSH (use prohibit-password)|2.2"
has "weak key" "$out" "WARN|SSH keys|2 keys, weak: RSA-1024|2.3"
rm "$PVE_DIR/corosync.conf"
out="$(chk_ssh)"
has "single node root no" "$out" "OK|SSH root login|disabled|"
rm "$ROOT_KEYS"; out="$(chk_ssh)"
has "no keys" "$out" "WARN|SSH keys|no valid key in"

# ---- certificate ------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FX/k.pem" -out "$PVE_DIR/local/pve-ssl.pem" -days 700 -subj "/CN=pve1" 2>/dev/null
out="$(chk_cert)"
has "self-signed" "$out" "WARN|Certificate|self-signed, expires in "
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FX/k.pem" -out "$PVE_DIR/local/pveproxy-ssl.pem" -days 10 -subj "/O=Let's Encrypt/CN=R11" 2>/dev/null
PVENODE_OUT='acmedomain0: domain=pve.example.com'
out="$(chk_cert)"
has "acme expiring" "$out" "FAIL|Certificate|ACME (Let's Encrypt), expires in"

# ---- firewall ---------------------------------------------------------------
out="$(chk_firewall)"
has "dc off" "$out" "WARN|Firewall|datacenter firewall disabled|2.5"
printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n' >"$PVE_DIR/firewall/cluster.fw"
printf 'name: web\nnet0: virtio=AA:BB,bridge=vmbr0,firewall=1\nipconfig0: ip=10.0.0.5/24,gw=10.0.0.1\n[snap1]\nnet0: virtio,bridge=vmbr0\n' >"$PVE_DIR/nodes/pve1/qemu-server/100.conf"
printf 'net0: virtio=AA:BC,bridge=vmbr0,firewall=1\n' >"$PVE_DIR/nodes/pve1/qemu-server/101.conf"
printf '[OPTIONS]\nenable: 1\n' >"$PVE_DIR/firewall/101.fw"
out="$(chk_firewall)"
has "dc on" "$out" "OK|Firewall|enabled, input policy DROP"
has "guest fw off" "$out" "INFO|VM/CT firewall|firewall=1 on a NIC, VM/CT firewall disabled: 100|2.5"

# ---- storage and disks ------------------------------------------------------
PVESM_OUT=$'Name Type Status Total Used Available %\nlocal dir active 100000 85000 15000 85.00%\nlocal-lvm lvmthin active 200000 20000 180000 10.00%\nnas nfs inactive 0 0 0 0.00%\nold dir disabled 0 0 0 N/A'
out="$(chk_storage)"
has "storage warn" "$out" "WARN|local|85% used of 0G (dir)|4.1"
has "storage ok" "$out" "OK|local-lvm|10% used"
has "storage inactive" "$out" "FAIL|nas|nfs storage is inactive|"
hasnt "disabled skipped" "$out" "|old|"
has "no snippets" "$out" "WARN|Snippets|not enabled on any storage (required by the VM builder)|4.2"
SNIP_OUT=$'Name Type Status\nlocal dir active'
has "snippets ok" "$(chk_storage)" "OK|Snippets|enabled on local|"

PVESH[/nodes/pve1/disks/list]='[{"devpath":"/dev/sda","size":512110190592,"used":"LVM","model":"Samsung SSD","health":"PASSED","wearout":15,"type":"ssd"},{"devpath":"/dev/sdb","size":2000398934016,"model":"WD Red","health":"PASSED","wearout":"N/A","type":"hdd"}]'
printf 'unused0: local-lvm:vm-101-disk-1\n' >>"$PVE_DIR/nodes/pve1/qemu-server/101.conf"
out="$(chk_disks)"
has "ssd wear" "$out" "WARN|Disks|SSD wear: /dev/sda 85% worn|4.3"
has "unused disk" "$out" "INFO|Unused disks|1 unused: /dev/sdb 1.8T WD Red|4.3"
has "detached" "$out" "INFO|Detached disks|1 unused disk entries in guest configs: 101:unused0|4.4"
PVESH[/nodes/pve1/disks/list]='[{"devpath":"/dev/sda","size":1,"used":"ZFS","health":"FAILED"}]'
has "smart failed" "$(chk_disks)" "FAIL|Disks|SMART failed: /dev/sda|4.3"

# ---- backups ----------------------------------------------------------------
PVESH[/cluster/backup]='[]'
PVESH[/cluster/resources]='[{"vmid":100,"template":0},{"vmid":101},{"vmid":9000,"template":1}]'
PVESH[/cluster/backup-info/not-backed-up]='[{"vmid":100,"name":"web"},{"vmid":101,"name":"db"}]'
has "no jobs" "$(chk_backups)" "FAIL|Backups|no enabled backup job for 2 VMs/CTs|5.1"
PVESH[/cluster/backup]='[{"id":"backup-1","enabled":1,"schedule":"21:00","storage":"pbs","vmid":"100"}]'
PVESH[/cluster/backup-info/not-backed-up]='[{"vmid":101,"name":"db"}]'
PVESH[/nodes/pve1/tasks]="[{\"upid\":\"UPID:x\",\"starttime\":$(( $(date +%s) - 3600 )),\"status\":\"job errors\"}]"
out="$(chk_backups)"
has "partial" "$out" "WARN|Backups|1 of 2 VMs/CTs in no backup job|5.1"
has "last failed" "$out" "FAIL|Last backup|"

# ---- notifications ----------------------------------------------------------
PVESH[/access/users]='[{"userid":"root@pam","enable":1,"email":""}]'
PVESH[/cluster/notifications/targets]='[{"name":"mail-to-root","type":"sendmail","origin":"builtin"}]'
PVESH[/cluster/notifications/matchers]='[{"name":"default-matcher","target":["mail-to-root"],"origin":"builtin"}]'
out="$(chk_notify)"
has "no root mail" "$out" "WARN|Notifications|root@pam has no e-mail address (used by mail-to-root)|6.1"
has "postfix down" "$out" "WARN|Mail server|postfix not running"
PVESH[/cluster/notifications/matchers]='[{"name":"default-matcher","target":["mail-to-root"],"disable":true}]'
has "no matcher" "$(chk_notify)" "FAIL|Notifications|no active matcher|6.5"
PVESH[/cluster/notifications/targets]='[{"name":"mail-to-root","type":"sendmail"},{"name":"ntfy","type":"webhook"}]'
PVESH[/cluster/notifications/matchers]='[{"name":"alerts","target":["ntfy"]}]'
has "other target ok" "$(chk_notify)" "OK|Notifications|2 targets, 1 matchers"
unset 'PVESH[/cluster/notifications/targets]'
has "old pve" "$(chk_notify)" "INFO|Notifications|notification system needs Proxmox VE 8.1 or newer"

# ---- microcode ----------------------------------------------------------------
printf 'vendor_id\t: GenuineIntel\nflags\t\t: fpu hypervisor sse\n' >"$CPUINFO"
has "vm microcode" "$(chk_microcode)" "INFO|Microcode|virtualized host, not required"
printf 'vendor_id\t: AuthenticAMD\nflags\t\t: fpu sse\n' >"$CPUINFO"
dpkg-query() { return 1; }
has "amd missing" "$(chk_microcode)" "WARN|Microcode|amd64-microcode not installed|3.3"

# ---- board, json and exit codes -------------------------------------------------
CHECKS=("SECURITY|chk_tfa" "SECURITY|chk_firewall" "STORAGE|chk_disks")
run_checks
board="$(print_results 0)"
has "board section" "$board" " SECURITY"
has "board line" "$board" "[FAIL] Disks           SMART failed: /dev/sda  -> 4.3"
hasnt "board hides details" "$board" "pve1/qemu"
eq "rc fail" "$(results_rc; echo $?)" 2
json="$(print_json)"
eq "json valid" "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["results"])>0 and d["node"])' <<<"$json")" pve1
RESULTS=("X|OK|a|b|" "X|WARN|a|b|")
eq "rc warn" "$(results_rc; echo $?)" 1

# ---- pipefail safety ------------------------------------------------------------
# With "set -o pipefail", "cmd | head" fails when cmd gets SIGPIPE on long output.
no_head="$(grep -nE '[|][[:space:]]*head([[:space:]]|$)' proxmox-toolbelt.sh || true)"
eq "no '| head' in proxmox-toolbelt.sh" "$no_head" ""
eq "old pattern fails under pipefail" "$(bash -c 'set -eo pipefail; seq 1 200000 | sed "s/^/  /" | head -60 >/dev/null; echo ok' 2>/dev/null)" ""
eq "new pattern ok under pipefail" "$(bash -c 'set -eo pipefail; seq 1 200000 | awk "/1/{print \"  \" \$0}" >/dev/null; echo ok')" ok

# ---- package jobs (tmux) ------------------------------------------------------------
TMUX_HAS=1
tmux() {
  [[ "$1" == -L ]] || { echo "tmux called without -L: $*"; return 9; }
  shift 4   # -L proxmox-toolbelt -f /dev/null
  case "$1" in has-session) return $(( 1 - TMUX_HAS )) ;; attach) echo attached ;; esac
}
guard="$(job_guard <<<"n" 2>&1; echo "rc=$?")"
has "guard sees session" "$guard" "A package job from an earlier run is still open (tmux session 'proxmox-toolbelt')."
has "guard blocks" "$guard" "rc=1"
TMUX_HAS=0
eq "guard passes" "$(job_guard; echo "rc=$?")" "rc=0"
unset -f tmux
# inside screen/tmux: runs directly and keeps the exit code
eq "in multiplexer" "$(STY=1 run_job bash -c 'exit 3' >/dev/null 2>&1; echo "rc=$? job=$JOB_RC")" "rc=0 job=3"
STY=1 run_job true >/dev/null 2>&1; eq "in multiplexer rc" "$JOB_RC" 0
# no tmux and the user declines: nothing runs
ensure_tmux() { return 1; }
out="$(TMUX="" STY="" run_job touch "$FX/ran" <<<"" 2>&1; echo "rc=$?")"
has "no tmux declined" "$out" "rc=1"
eq "no tmux nothing ran" "$( [[ -e $FX/ran ]] && echo ran)" ""
out="$(TMUX="" STY="" run_job touch "$FX/ran" <<<"y" 2>&1; echo "rc=$?")"
eq "no tmux confirmed ran" "$( [[ -e $FX/ran ]] && echo ran)" ran
unset -f ensure_tmux
DRY_RUN=1; eq "dry-run job" "$(run_job apt-get dist-upgrade 2>&1)" "+ apt-get dist-upgrade"; DRY_RUN=0

# ---- container builder ------------------------------------------------------------
pveam() {
  case "$1" in
    list) printf 'NAME  SIZE\nlocal:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst  120.32MB\nlocal:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst  130.10MB\n' ;;
    available) printf 'system  debian-12-standard_12.12-1_amd64.tar.zst\nsystem  debian-12-standard_12.7-1_amd64.tar.zst\nsystem  debian-13-standard_13.1-2_amd64.tar.zst\nsystem  alpine-3.22-default_20250617_amd64.tar.xz\n' ;;
  esac
}
ct_template_index local
eq "ct newest version" "${CT_AVAIL[debian-12-standard]}" "debian-12-standard_12.12-1_amd64.tar.zst"
eq "ct index keys" "$(printf '%s\n' "${!CT_AVAIL[@]}" | sort | paste -sd' ' -)" "alpine-3.22-default debian-12-standard debian-13-standard"
eq "ct downloaded" "${CT_HAVE[debian-13-standard_13.1-2_amd64.tar.zst]:-}" 1
eq "ct not downloaded" "${CT_HAVE[alpine-3.22-default_20250617_amd64.tar.xz]:-}" ""
eq "ct version" "$(ct_tpl_version debian-13-standard_13.1-2_amd64.tar.zst)" "13.1-2"
eq "ct template name ok" "$(v_ct_tpl alpine-3.22-default_20250617_amd64.tar.xz 2>/dev/null && echo ok)" ok
eq "ct template name bad" "$(v_ct_tpl '../x.tar.zst' 2>/dev/null && echo ok)" ""
unset -f pveam
NIC_NET=("virtio,bridge=vmbr0,firewall=1,tag=20" "virtio,bridge=vmbr1,firewall=0") NIC_IPCFG=("ip=10.5.0.20/24,gw=10.5.0.1" "ip=dhcp,ip6=auto")
eq "ct net static" "$(ct_net 0)" "name=eth0,bridge=vmbr0,firewall=1,tag=20,ip=10.5.0.20/24,gw=10.5.0.1"
eq "ct net dhcp" "$(ct_net 1)" "name=eth1,bridge=vmbr1,firewall=0,ip=dhcp,ip6=auto"
NIC_IPCFG[1]=""
eq "ct net no ip" "$(ct_net 1)" "name=eth1,bridge=vmbr1,firewall=0"

# ---- SSH change auto-revert ------------------------------------------------------------
BACKUP_DIR=""
eq "revert new dropin" "$(ssh_revert_cmd /etc/ssh/sshd_config.d/01-proxmox-toolbelt.conf 0)" "rm -f /etc/ssh/sshd_config.d/01-proxmox-toolbelt.conf; systemctl reload ssh 2>/dev/null || systemctl reload sshd"
BACKUP_DIR="/root/bk"
eq "revert existing dropin" "$(ssh_revert_cmd /nonexistent/x.conf 1)" "cp -f /root/bk/nonexistent/x.conf /nonexistent/x.conf; systemctl reload ssh 2>/dev/null || systemctl reload sshd"
BACKUP_DIR=""
systemd-run() { printf '%s\n' "$@" >"$FX/sdrun"; }
systemctl() { echo "systemctl $*" >>"$FX/sdctl"; }
schedule_revert unit-a 120 "true" >/dev/null
has "systemd timer" "$(cat "$FX/sdrun")" "--on-active=120"
eq "no fallback pid" "$REVERT_PID" ""
cancel_revert unit-a
has "timer stopped" "$(cat "$FX/sdctl")" "systemctl stop unit-a.timer"
systemd-run() { return 1; }
schedule_revert unit-b 1 "touch $FX/reverted" >/dev/null
sleep 2
eq "fallback revert runs" "$( [[ -e $FX/reverted ]] && echo yes)" yes
rm -f "$FX/reverted"
schedule_revert unit-c 1 "touch $FX/reverted" >/dev/null
cancel_revert unit-c
sleep 2
eq "fallback revert cancelled" "$( [[ -e $FX/reverted ]] && echo yes)" ""
unset -f systemd-run systemctl
eq "confirm default no" "$(confirm 'x?' <<<'' 2>/dev/null; echo $?)" 1

# ---- uninstall ------------------------------------------------------------
mkdir -p "$FX/snip"; : >"$FX/snip/create-vm-vendor.yaml"; : >"$FX/snip/create-vm-vendor-upgrade.yaml"
mkdir -p "$PVE_DIR/nodes/pve1/qemu-server"
echo "cicustom: vendor=local:snippets/create-vm-vendor-upgrade.yaml" >"$PVE_DIR/nodes/pve1/qemu-server/777.conf"
pvesm() { if [[ "$1" == path ]]; then echo "$FX/snip/${2##*/}"; else printf 'Name Type Status\nlocal dir active\n'; fi; }
sn="$(toolbelt_snippets)"
has "snippet unused" "$sn" "local|local:snippets/create-vm-vendor.yaml|$FX/snip/create-vm-vendor.yaml|"
has "snippet referenced" "$sn" "local|local:snippets/create-vm-vendor-upgrade.yaml|$FX/snip/create-vm-vendor-upgrade.yaml|777"
rm -f "$PVE_DIR/nodes/pve1/qemu-server/777.conf"; unset -f pvesm

echo "$pass passed, $fail failed"
(( fail == 0 ))
