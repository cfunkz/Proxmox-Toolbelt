#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals here are read by the sourced script
# Tests for scheduled snapshots and backups in proxmox-toolbelt.sh, with mocked Proxmox
# commands and fixture files (no Proxmox or systemd needed):
#   bash tests/test-schedule.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=../proxmox-toolbelt.sh
source ./proxmox-toolbelt.sh
set +eE; trap - EXIT ERR INT TERM
C_B="" C_D="" C_G="" C_Y="" C_R="" C_C="" C_0=""

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: got '$2' want '$3'"; fi; }
ok() { if "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail + 1)); echo "FAIL: $1"; else pass=$((pass + 1)); fi; }
has() { if grep -qF -- "$3" <<<"$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s: missing %q in:\n%s\n' "$1" "$3" "$2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then fail=$((fail + 1)); printf 'FAIL: %s: unexpected %q in:\n%s\n' "$1" "$3" "$2"; else pass=$((pass + 1)); fi; }

FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
PVE_DIR="$FX/pve" NODE=pve1
SCHED_DIR="$FX/etc/schedule" SCHED_STATE="$FX/state" SCHED_LOG="$FX/log" SCHED_LOCKS="$FX/lock" UNIT_DIR="$FX/units"
SCHED_RETRY_WAIT=0
CALLS="$FX/calls"; : >"$CALLS"
mkdir -p "$PVE_DIR/nodes/pve1/qemu-server" "$PVE_DIR/nodes/pve1/lxc" "$SCHED_LOCKS"

cat >"$PVE_DIR/storage.cfg" <<'EOF'
dir: local
	path /var/lib/vz
	content iso,vztmpl,backup,images

zfspool: local-zfs
	pool rpool/data
	content images,rootdir

lvmthin: local-lvm
	thinpool data
	vgname pve
	content rootdir,images

lvm: thick
	vgname vg1
	content images

pbs: pbs1
	server 10.0.0.5
	datastore main
EOF
vmconf() { printf '%s\n' "$@" >"$PVE_DIR/nodes/pve1/qemu-server/${1#id=}.conf"; }
cat >"$PVE_DIR/nodes/pve1/qemu-server/100.conf" <<'EOF'
name: web
scsi0: local-zfs:vm-100-disk-0,size=32G
ide2: local-lvm:vm-100-cloudinit,media=cdrom
efidisk0: local-zfs:vm-100-disk-1,size=1M
EOF
cat >"$PVE_DIR/nodes/pve1/qemu-server/101.conf" <<'EOF'
name: db
scsi0: thick:vm-101-disk-0,size=32G
EOF
cat >"$PVE_DIR/nodes/pve1/qemu-server/103.conf" <<'EOF'
name: rawfile
virtio0: local:103/vm-103-disk-0.raw,size=8G
EOF
cat >"$PVE_DIR/nodes/pve1/qemu-server/104.conf" <<'EOF'
name: qcow
scsi0: local:104/vm-104-disk-0.qcow2,size=8G
EOF
cat >"$PVE_DIR/nodes/pve1/qemu-server/9000.conf" <<'EOF'
name: tpl-debian
template: 1
scsi0: local-zfs:base-9000-disk-0,size=4G
EOF
cat >"$PVE_DIR/nodes/pve1/lxc/102.conf" <<'EOF'
hostname: dns
rootfs: local-lvm:vm-102-disk-0,size=8G
mp0: /mnt/data,mp=/data
EOF

# ---- mocks ---------------------------------------------------------------
declare -A FEATURE=([100]=1 [101]=0 [102]=1 [103]=0 [104]=1)
declare -A PVESM=([local]="dir active 1000 100 900" [local-zfs]="zfspool active 1000 500 500"
                  [local-lvm]="lvmthin active 1000 100 900" [thick]="lvm active 1000 100 900" [pbs1]="pbs active 1000 10 990")
THIN_META=5 QUORATE=1 VZDUMP_FAIL_FIRST="" SNAP_FAIL=""
pvesh() {
  if [[ "$2" =~ ^/nodes/pve1/(qemu|lxc)/([0-9]+)/feature$ ]]; then printf '{"hasFeature":%s,"nodes":["pve1"]}\n' "${FEATURE[${BASH_REMATCH[2]}]:-1}"; return 0; fi
  [[ "$2" == /cluster/status ]] && { printf '[{"type":"cluster","quorate":%s},{"type":"node","name":"pve1"}]\n' "$QUORATE"; return 0; }
  [[ "$2" == /pools/prod ]] && { echo '{"members":[{"vmid":104,"type":"qemu"},{"vmid":777,"type":"qemu"},{"id":"storage/pve1/local","type":"storage"}]}'; return 0; }
  return 1
}
pvesm() {
  local s
  if [[ "${2:-}" == --storage ]]; then
    [[ -n "${PVESM[$3]+x}" ]] || return 1
    echo "Name Type Status Total Used Available %"; read -r -a f <<<"${PVESM[$3]}"; echo "$3 ${f[*]} 10%"; return 0
  fi
  if [[ "${2:-}" == --content && "${3:-}" == backup ]]; then
    echo "Name Type Status Total Used Available %"
    for s in local pbs1; do echo "$s ${PVESM[$s]} 1%"; done
  fi
}
lvs() { echo "  $THIN_META.00"; }
snapctr=0
snap_name() { local n; n="$(cat "$FX/snapctr" 2>/dev/null || echo 0)"; n=$(( n + 1 )); echo "$n" >"$FX/snapctr"; printf 'ptb_%s_20261112_%06d\n' "${J[NAME]}" "$n"; }
guestcmd() { # TOOL ARGS...
  local tool="$1" sub="$2" id="$3" conf; shift 3
  echo "$tool $sub $id $*" >>"$CALLS"
  conf="$PVE_DIR/nodes/pve1/$([[ $tool == pct ]] && echo lxc || echo qemu-server)/$id.conf"
  case "$sub" in
    snapshot)
      [[ " $SNAP_FAIL " == *" $id "* ]] && { echo "snapshot failed: timeout"; return 1; }
      printf '\n[%s]\nsnaptime: %s\n' "$1" "$(cat "$FX/snapctr")" >>"$conf" ;;
    delsnapshot)
      awk -v n="[$1]" '$0==n{skip=1; next} /^\[/{skip=0} !skip' "$conf" >"$conf.t" && mv "$conf.t" "$conf" ;;
    unlock) sed -i '/^lock:/d' "$conf" ;;
    status) echo "status: stopped" ;;
  esac
}
qm()  { guestcmd qm "$@"; }
pct() { guestcmd pct "$@"; }
vzdump_calls=0
vzdump() {
  echo "vzdump $*" >>"$CALLS"
  local n; n="$(grep -c '^vzdump' "$CALLS")"
  if [[ -n "$VZDUMP_FAIL_FIRST" && "$n" == 1 ]]; then echo "INFO: Backup of VM 100 started"; echo "ERROR: Backup of VM $VZDUMP_FAIL_FIRST failed - lock"; return 1; fi
  echo "INFO: Backup job finished successfully"
}
systemctl() { echo "systemctl $*" >>"$CALLS"; [[ "$1" == is-enabled ]] && return 0; return 0; }
sendmail() { { echo "sendmail $*"; cat; } >>"$FX/mail"; }
pgrep() { return 1; }
sleep() { :; }
sched_require_prog() { :; }
is_cluster() { [[ "$QUORATE" != skip ]]; }
jx() { job_exec "$@" >/dev/null; set +e; }
snaps_of() { conf_snapshots "$PVE_DIR/nodes/pve1/qemu-server/$1.conf" | awk '{print $2}' | paste -sd' ' -; }

# ---- intervals -------------------------------------------------------------
eq "10m" "$(parse_every 10m)" "10 0"
eq "10min" "$(parse_every 10min)" "10 0"
eq "10h" "$(parse_every 10h)" "600 0"
eq "24h" "$(parse_every 24h)" "1440 0"
eq "1d" "$(parse_every 1d)" "1440 0"
eq "2w" "$(parse_every 2w)" "20160 0"
eq "3mo" "$(parse_every 3mo)" "0 3"
eq "2months" "$(parse_every 2months)" "0 2"
eq "1h30m" "$(parse_every 1h30m)" "90 0"
eq "1d12h" "$(parse_every 1D12H)" "2160 0"
eq "daily" "$(parse_every daily)" "1440 0"
eq "spaces" "$(parse_every '1h 30m')" "90 0"
no "4m too short" parse_every 4m
no "unit missing" parse_every 10
no "bad unit" parse_every 10x
no "months mixed" parse_every 1mo2d
no "empty" parse_every ""
no "over a year" parse_every 400d

eq "text hours" "$(every_text 600 0)" "every 10 hours"
eq "text 90" "$(every_text 90 0)" "every 90 minutes"
eq "text day" "$(every_text 1440 0)" "every day"
eq "text weeks" "$(every_text 20160 0)" "every 2 weeks"
eq "text months" "$(every_text 0 3)" "every 3 months"

eq "tick 10m" "$(sched_tick 10 0)" "600|*-*-* *:00/10:00"
eq "tick 45m" "$(sched_tick 45 0)" "900|*-*-* *:00/15:00"
eq "tick 7m" "$(sched_tick 7 0)" "60|*-*-* *:00/1:00"
eq "tick 10h" "$(sched_tick 600 0)" "3600|*-*-* *:00:00"
eq "tick 36h" "$(sched_tick 2160 0)" "3600|*-*-* *:00:00"
eq "tick 1d" "$(sched_tick 1440 0 02:00)" "86400|*-*-* 02:00:00"
eq "tick 1mo" "$(sched_tick 0 1 03:30)" "86400|*-*-* 03:30:00"
if command -v systemd-analyze >/dev/null; then
  for m in 10 45 7 600 1440; do
    c="$(sched_tick "$m" 0 02:00)"; ok "systemd accepts ${c#*|}" systemd-analyze calendar "${c#*|}" >/dev/null
  done
fi

export TZ=UTC
t0="$(date -d '2026-11-12 13:37:20' +%s)"
eq "slot 10m" "$(fmt_ts "$(sched_slot "$t0" 600)")" "2026-11-12 13:30"
eq "slot 1h" "$(fmt_ts "$(sched_slot "$t0" 3600)")" "2026-11-12 13:00"
eq "slot day" "$(fmt_ts "$(sched_slot "$t0" 86400 02:00)")" "2026-11-12 02:00"
eq "slot day before at" "$(fmt_ts "$(sched_slot "$(date -d '2026-11-12 01:10' +%s)" 86400 02:00)")" "2026-11-11 02:00"
TZ=Asia/Kolkata eq "slot +0530" "$(TZ=Asia/Kolkata date -d "@$(TZ=Asia/Kolkata sched_slot "$t0" 3600)" +%M)" "00"

h=3600
ok "never ran" sched_due "$t0" "" 600 0 $h
no "same slot" sched_due "$t0" "$t0" 600 0 $h
no "10h job after 9h" sched_due $(( t0 + 9 * h )) "$t0" 600 0 $h
ok "10h job after 10h" sched_due $(( t0 + 10 * h )) "$t0" 600 0 $h
ok "daily after 23h (DST)" sched_due $(( t0 + 23 * h )) "$t0" 1440 0 86400
no "daily after 11h" sched_due $(( t0 + 11 * h )) "$t0" 1440 0 86400
no "1w after 6d" sched_due $(( t0 + 6 * 24 * h )) "$t0" 10080 0 86400
ok "1w after 7d" sched_due $(( t0 + 7 * 24 * h )) "$t0" 10080 0 86400
nov12="$(date -d '2026-11-12 02:00' +%s)"
no "1mo same month" sched_due "$(date -d '2026-11-30 02:00' +%s)" "$nov12" 0 1 86400
ok "1mo on the 1st" sched_due "$(date -d '2026-12-01 02:00' +%s)" "$nov12" 0 1 86400
no "3mo after 2" sched_due "$(date -d '2027-01-01 02:00' +%s)" "$nov12" 0 3 86400
ok "3mo after 3" sched_due "$(date -d '2027-02-01 02:00' +%s)" "$nov12" 0 3 86400
no "clock went back" sched_due $(( t0 - h )) "$t0" 10 0 600

# ---- validation and job files -------------------------------------------------
eq "expand ids" "$(expand_ids 100,102-104 | paste -sd' ' -)" "100 102 103 104"
ok "guests all" v_guests all
ok "guests pool" v_guests pool:prod
ok "guests list" v_guests 100,101-105
no "guests injection" v_guests '100;reboot' 2>/dev/null
ok "retention" v_retention keep-daily=7,keep-weekly=4
no "retention bad" v_retention keep-all=1 2>/dev/null
ok "calendar" v_calendar 'Mon..Fri 22:00'
no "calendar subst" v_calendar '$(id)' 2>/dev/null
ok "job name" v_jobname nightly_zfs
no "job name dash" v_jobname nightly-zfs 2>/dev/null
no "job name long" v_jobname abcdefghijklmnopqrstu 2>/dev/null

mkdir -p "$SCHED_DIR"
printf 'TYPE=snapshot\r\nEVERY="10h"\r\nGUESTS=100\r\nKEEP=3\r\n# comment\r\n' >"$SCHED_DIR/crlf.conf"
ok "loads CRLF + quotes" job_load crlf
eq "loaded value" "${J[EVERY]}|${J[KEEP]}|${J[AT]}" "10h|3|02:00"
printf 'TYPE=snapshot\nEVERY=1h\nGUESTS=$(touch %s/pwned)\n' "$FX" >"$SCHED_DIR/evil.conf"
no "rejects command substitution" job_load evil 2>/dev/null
ok "never executed" test ! -e "$FX/pwned"
printf 'TYPE=snapshot\nEVERY=1h\nGUESTS=all\nFOO=1\n' >"$SCHED_DIR/unknown.conf"
no "rejects unknown key" job_load unknown 2>/dev/null
printf 'TYPE=backup\nEVERY=1d\nGUESTS=all\n' >"$SCHED_DIR/nostore.conf"
no "backup needs storage" job_load nostore 2>/dev/null
printf 'TYPE=snapshot\nEVERY=1d\nCALENDAR=daily\nGUESTS=all\n' >"$SCHED_DIR/both.conf"
no "every and calendar" job_load both 2>/dev/null
rm -f "$SCHED_DIR"/*.conf

job_defaults rt; J[TYPE]=backup J[EVERY]=1d J[GUESTS]=all J[EXCLUDE]=105 J[STORAGE]=local J[RETENTION]=keep-daily=7
job_render >"$SCHED_DIR/rt.conf"
before="$(declare -p J)"
ok "rendered job loads" job_load rt
eq "roundtrip" "$(declare -p J)" "$before"
hasnt "no vmstate in backup job" "$(cat "$SCHED_DIR/rt.conf")" "VMSTATE"
eq "schedule text" "$(schedule_text)" "every day at 02:00"
rm -f "$SCHED_DIR/rt.conf"

# ---- guests and storage ------------------------------------------------------------
eq "all, templates skipped" "$(resolve_guests all "" 1 2>/dev/null | cut -d'|' -f1 | paste -sd' ' -)" "100 101 102 103 104"
eq "all with template" "$(resolve_guests all "" 0 | cut -d'|' -f1 | paste -sd' ' -)" "100 101 102 103 104 9000"
eq "exclude" "$(resolve_guests all "101,103-104" 1 | cut -d'|' -f1 | paste -sd' ' -)" "100 102"
eq "lxc type and name" "$(resolve_guests 102 "" 1)" "102|lxc|dns"
eq "missing guest note" "$(resolve_guests 100,555 "" 1 2>&1 >/dev/null)" "guest 555 is not on node pve1, skipped"
eq "pool: local members only" "$(resolve_guests pool:prod "" 1 2>&1 | cut -d'|' -f1)" "104"
no "unknown pool" resolve_guests pool:nope "" 1 2>/dev/null

eq "volumes, no cdrom" "$(guest_volumes "$PVE_DIR/nodes/pve1/qemu-server/100.conf" | paste -sd' ' -)" "local-zfs:vm-100-disk-0 local-zfs:vm-100-disk-1"
eq "ct volumes, no bind mount" "$(guest_volumes "$PVE_DIR/nodes/pve1/lxc/102.conf")" "local-lvm:vm-102-disk-0"
eq "zfs snapshots" "$(snap_capable "$PVE_DIR/nodes/pve1/qemu-server/100.conf")" "yes"
eq "thick lvm" "$(snap_capable "$PVE_DIR/nodes/pve1/qemu-server/101.conf")" "no: thick:vm-101-disk-0 is on lvm storage"
eq "raw on dir" "$(snap_capable "$PVE_DIR/nodes/pve1/qemu-server/103.conf")" "no: local:103/vm-103-disk-0.raw is not qcow2"
eq "qcow2 on dir" "$(snap_capable "$PVE_DIR/nodes/pve1/qemu-server/104.conf")" "yes"
eq "lvm-thin ct" "$(snap_capable "$PVE_DIR/nodes/pve1/lxc/102.conf")" "yes"

ok "room ok" storage_room local-zfs 90
PVESM[local-zfs]="zfspool active 1000 950 50"
eq "room full" "$(storage_room local-zfs 90)" "storage local-zfs is 95% full (limit 90%)"
PVESM[local-zfs]="zfspool inactive 0 0 0"
no "room inactive" storage_room local-zfs 90 >/dev/null
PVESM[local-zfs]="zfspool active 1000 500 500"
THIN_META=93
eq "thin metadata" "$(storage_room local-lvm 90)" "thin pool pve/data metadata is 93% full (limit 90%)"
THIN_META=5
no "room unknown storage" storage_room nope 90 >/dev/null

# ---- snapshot job ----------------------------------------------------------------------
job_defaults zfs; J[TYPE]=snapshot J[EVERY]=1h J[GUESTS]=100,102 J[KEEP]=2
job_render >"$SCHED_DIR/zfs.conf"
for i in 1 2 3; do jx zfs "$(( t0 + i * 3600 ))" 0; done
eq "result ok" "$JOB_RESULT" ok
eq "pruned to keep=2" "$(snaps_of 100)" "ptb_zfs_20261112_000003 ptb_zfs_20261112_000005"
eq "ct snapshots" "$(conf_snapshots "$PVE_DIR/nodes/pve1/lxc/102.conf" | wc -l | tr -d ' ')" 2
eq "state ok" "$(state_get zfs status)" ok
eq "state slot" "$(state_get zfs last_slot)" "$(( t0 + 3 * 3600 ))"
has "state message" "$(state_get zfs message)" "2 snapshot(s)"
has "pct used for ct" "$(cat "$CALLS")" "pct snapshot 102 ptb_zfs_"
has "description" "$(cat "$CALLS")" "--description proxmox-toolbelt job zfs"
has "log file" "$(cat "$SCHED_LOG/zfs.log")" "=== job zfs: ok"
ok "no mail on success" test ! -e "$FX/mail"

# a manual (hand) run keeps the schedule slot
jx zfs "" 1
eq "manual run keeps slot" "$(state_get zfs last_slot)" "$(( t0 + 3 * 3600 ))"

# other snapshots are never pruned
printf '\n[before_upgrade]\nsnaptime: 1\n' >>"$PVE_DIR/nodes/pve1/qemu-server/100.conf"
jx zfs "" 1
has "foreign snapshot kept" "$(snaps_of 100)" "before_upgrade"

# a guest that cannot be snapshotted fails the run but not the others
job_defaults mixed; J[TYPE]=snapshot J[EVERY]=1h J[GUESTS]=100,101 J[KEEP]=5
job_render >"$SCHED_DIR/mixed.conf"
: >"$CALLS"
jx mixed "$t0" 0
eq "mixed result" "$JOB_RESULT" failed
has "mixed message" "$(state_get mixed message)" "1 snapshot(s), failed: 101"
hasnt "no snapshot attempt on thick lvm" "$(cat "$CALLS")" "qm snapshot 101"
has "failure mail" "$(cat "$FX/mail")" "Subject: [pve1] snapshot job mixed: failed"
has "mail says why" "$(cat "$FX/mail")" "thick:vm-101-disk-0 is on lvm storage"
eq "fail counter" "$(state_get mixed fails)" 1

# with "all", guests without snapshot support are skipped, not failed
job_defaults allsnap; J[TYPE]=snapshot J[EVERY]=1h J[GUESTS]=all J[EXCLUDE]=102,104 J[KEEP]=5
job_render >"$SCHED_DIR/allsnap.conf"
: >"$CALLS"
jx allsnap "$t0" 0
eq "all: skipped is ok" "$JOB_RESULT" ok
has "all: skip message" "$(state_get allsnap message)" "1 snapshot(s), skipped (no snapshot support): 101 103"
hasnt "all: no attempt on raw" "$(cat "$CALLS")" "qm snapshot 103"
job_remove allsnap >/dev/null

# retries, then gives up
SNAP_FAIL=100 SCHED_ATTEMPTS=3; : >"$CALLS"
jx mixed "$(( t0 + 3600 ))" 0
eq "three tries" "$(grep -c '^qm snapshot 100' "$CALLS")" 3
eq "fail counter 2" "$(state_get mixed fails)" 2
SNAP_FAIL=""

# full storage: no snapshot
PVESM[local-zfs]="zfspool active 1000 950 50"; : >"$CALLS"
jx zfs "" 1
eq "full pool result" "$JOB_RESULT" failed
hasnt "no snapshot on full pool" "$(cat "$CALLS")" "qm snapshot 100"
PVESM[local-zfs]="zfspool active 1000 500 500"

# not quorate: nothing runs
QUORATE=0; : >"$CALLS"
jx zfs "" 1
eq "no quorum" "$(state_get zfs message)" "cluster not quorate"
eq "no commands without quorum" "$(grep -c . "$CALLS")" 0
QUORATE=1

# ---- interrupted run, busy lock, ticks -------------------------------------------------
c100="$PVE_DIR/nodes/pve1/qemu-server/100.conf"
sed -i '1i lock: snapshot' "$c100"
printf '\n[ptb_zfs_20261112_999999]\nsnaptime: 5\nsnapstate: prepare\n' >>"$c100"
state_set zfs status=running
: >"$CALLS"
jx zfs "" 1
has "unlocks" "$(cat "$CALLS")" "qm unlock 100"
has "removes half snapshot" "$(cat "$CALLS")" "qm delsnapshot 100 ptb_zfs_20261112_999999 --force 1"
hasnt "lock gone" "$(cat "$c100")" "lock: snapshot"
eq "after recovery" "$JOB_RESULT" ok
has "logged" "$(cat "$SCHED_LOG/zfs.log")" "did not finish"

flock "$SCHED_LOCKS/$JOB_UNIT-zfs.lock" sleep 3 &
lockpid=$!
command sleep 0.3
jx zfs "" 1
eq "busy" "$JOB_RESULT" busy
kill "$lockpid" 2>/dev/null; wait "$lockpid" 2>/dev/null

job_defaults tenh; J[TYPE]=snapshot J[EVERY]=10h J[GUESTS]=100 J[KEEP]=3
job_render >"$SCHED_DIR/tenh.conf"
SCHED_NOW=$(( t0 )); job_tick tenh >/dev/null; set +e
eq "first tick runs" "$JOB_RESULT" ok
SCHED_NOW=$(( t0 + 60 )); job_tick tenh >/dev/null; set +e
eq "same hour: not due" "$JOB_RESULT" not-due
SCHED_NOW=$(( t0 + 9 * 3600 )); job_tick tenh >/dev/null; set +e
eq "9h: not due" "$JOB_RESULT" not-due
SCHED_NOW=$(( t0 + 10 * 3600 + 5 )); job_tick tenh >/dev/null; set +e
eq "10h: runs" "$JOB_RESULT" ok
state_set tenh status=running
SCHED_NOW=$(( t0 + 10 * 3600 + 900 )); job_tick tenh >/dev/null; set +e
eq "interrupted run repeats" "$JOB_RESULT" ok
unset SCHED_NOW

: >"$CALLS"
state_set tenh status=running
sched_recover >/dev/null
has "recover starts it" "$(cat "$CALLS")" "systemctl start --no-block proxmox-toolbelt-job@tenh.service"
state_set tenh status=ok

# ---- backup job --------------------------------------------------------------------------
job_defaults nightly; J[TYPE]=backup J[EVERY]=1d J[GUESTS]=all J[EXCLUDE]=103-104 J[STORAGE]=local
job_render >"$SCHED_DIR/nightly.conf"
: >"$CALLS"; VZDUMP_FAIL_FIRST=101
jx nightly "$t0" 0
eq "backup ok after retry" "$JOB_RESULT" ok
eq "two vzdump runs" "$(grep -c '^vzdump' "$CALLS")" 2
has "first run, all minus excluded" "$(sed -n 1p "$CALLS")" "vzdump 100 101 102 9000 --storage local --mode snapshot --prune-backups keep-last=7"
has "notes" "$(sed -n 1p "$CALLS")" "--notes-template {{guestname}} (proxmox-toolbelt job nightly)"
has "compress" "$(sed -n 1p "$CALLS")" "--compress zstd"
has "retry only the failed guest" "$(sed -n 2p "$CALLS")" "vzdump 101 --storage local"
has "summary" "$(state_get nightly message)" "after 2 tries"
VZDUMP_FAIL_FIRST=""

job_defaults pbsjob; J[TYPE]=backup J[EVERY]=1d J[GUESTS]=100 J[STORAGE]=pbs1 J[RETENTION]=keep-daily=7,keep-weekly=4
job_render >"$SCHED_DIR/pbsjob.conf"
: >"$CALLS"
jx pbsjob "$t0" 0
has "retention rules" "$(cat "$CALLS")" "--prune-backups keep-daily=7,keep-weekly=4"
hasnt "no compress on pbs" "$(cat "$CALLS")" "--compress"

PVESM[local]="dir inactive 0 0 0"; : >"$CALLS"
jx nightly "" 1
eq "inactive target fails" "$JOB_RESULT" failed
eq "no vzdump on inactive target" "$(grep -c '^vzdump' "$CALLS")" 0
PVESM[local]="dir active 1000 100 900"

job_defaults nobk; J[TYPE]=backup J[EVERY]=1d J[GUESTS]=100 J[STORAGE]=local-zfs
job_render >"$SCHED_DIR/nobk.conf"
jx nobk "" 1
has "storage without backup content" "$(state_get nobk message)" "no backup content"

# dry run changes nothing
: >"$CALLS"; before="$(cat "$SCHED_STATE/nightly.state")"
out="$(DRY_RUN=1 job_exec nightly "" 1)"; set +e
has "dry run prints vzdump" "$out" "[dry-run] vzdump 100 101 102 9000"
eq "dry run: no commands" "$(grep -c . "$CALLS")" 0
eq "dry run: state unchanged" "$(cat "$SCHED_STATE/nightly.state")" "$before"

# ---- install, status board, remove ----------------------------------------------------------
job_load zfs
: >"$CALLS"
job_install >/dev/null
timer="$UNIT_DIR/$JOB_UNIT@zfs.timer"
has "timer calendar" "$(cat "$timer")" "OnCalendar=*-*-* *:00:00"
has "timer persistent" "$(cat "$timer")" "Persistent=true"
has "service runs tick" "$(cat "$UNIT_DIR/$JOB_UNIT@.service")" "ExecStart=/usr/bin/env proxmox-toolbelt schedule tick %i"
has "service condition" "$(cat "$UNIT_DIR/$JOB_UNIT@.service")" "ConditionPathExists=$SCHED_DIR/%i.conf"
has "recover unit" "$(cat "$UNIT_DIR/$RECOVER_UNIT")" "WantedBy=multi-user.target"
has "enables timer" "$(cat "$CALLS")" "systemctl enable --now proxmox-toolbelt-job@zfs.timer"
has "enables recover" "$(cat "$CALLS")" "systemctl enable proxmox-toolbelt-schedule-recover.service"

job_defaults cal; J[TYPE]=backup J[CALENDAR]="Mon..Fri 22:00" J[GUESTS]=100 J[STORAGE]=local
has "calendar timer" "$(unit_timer)" "OnCalendar=Mon..Fri 22:00"
job_defaults mo; J[TYPE]=snapshot J[EVERY]=3mo J[AT]=03:00 J[GUESTS]=100
has "month timer ticks daily" "$(unit_timer)" "OnCalendar=*-*-* 03:00:00"
eq "month text" "$(schedule_text)" "every 3 months at 03:00, on the 1st"

board="$(chk_schedule)"
has "board warns" "$board" "WARN|Scheduled jobs|"
has "board names failed job" "$board" "mixed (failed)"
has "board detail" "$board" "-|Scheduled|zfs: snapshot every hour"

: >"$CALLS"
job_remove mixed >/dev/null
ok "job file removed" test ! -e "$SCHED_DIR/mixed.conf"
has "timer disabled" "$(cat "$CALLS")" "systemctl disable --now proxmox-toolbelt-job@mixed.timer"
ok "units kept while jobs remain" test -e "$UNIT_DIR/$JOB_UNIT@.service"
for j in $(job_names); do job_remove "$j" >/dev/null; done
ok "last job removes units" test ! -e "$UNIT_DIR/$JOB_UNIT@.service"

# ---- command line ---------------------------------------------------------------------------
: >"$CALLS"
out="$(sched_cli add snapshot hourly --every 1H --guests all --exclude 101 --keep 24 2>&1)"; set +e
ok "cli add" test -f "$SCHED_DIR/hourly.conf"
has "cli lowercases interval" "$(cat "$SCHED_DIR/hourly.conf")" "EVERY=1h"
has "cli warns about raw disk" "$out" "Guest 103: no:"
out="$( (sched_cli add snapshot bad --every 2m --guests all) 2>&1)"
has "cli rejects 2m" "$out" "5 minutes or more"
out="$( (sched_cli add backup bk --every 1d --guests all --storage local-zfs) 2>&1)"
has "cli checks backup storage" "$out" "does not allow backups"
out="$(sched_cli list)"
has "list" "$out" "hourly           snapshot every hour"

echo "$pass passed, $fail failed"
(( fail == 0 ))
