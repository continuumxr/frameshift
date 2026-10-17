#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# pid1-hold-ts.sh (revision 6, the TRIP branch) fixtures, in the manner of
# devices/quest3/common/tools/fixtures-deadline.sh: the hold logic runs in
# the REVIEWED stage-1 busybox (aarch64) under qemu-aarch64; only the
# syscalls are faked (fs-poweroff-final / fs-reboot-final / fs-reboot are
# scripts that record "<uptime> <reason> pid=<pid> via=<kind>" and then
# behave as the real helpers would: the final helpers never return).
# The guard is a native stand-in named fs-thermald (tools/testprogs/guardhb.c).
# Scaled times: deadline 16 s, guard READY limit 4 s. Offline; no device.
#   bash tools/stage/test_pid1_trip.sh BUILD_DIR   (BUILD_DIR holds guardhb)
set -uo pipefail
B=${1:?build dir}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
HOLD=$HERE/stage/pid1-hold-ts.sh
BB_SRC=${FS_BUSYBOX:-<repo>/build/third_party/busybox/busybox}
QEMU=$(command -v qemu-aarch64 || true)
[ -n "$QEMU" ] || { echo "SKIP: qemu-aarch64 missing"; exit 1; }
[ "$(sha256sum "$BB_SRC" | cut -c1-64)" = c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02 ] \
    || { echo "REFUSED: busybox is not the reviewed binary"; exit 1; }
W=$(mktemp -d /tmp/fsts.XXXXXX)
trap 'pkill -9 -f "$W/" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/g"
cp "$BB_SRC" "$W/bin/busybox"; chmod 0755 "$W/bin/busybox"
for a in sh cut cat echo sleep head rm mv printf mkfifo sync; do ln -s busybox "$W/bin/$a"; done
cp "$B/guardhb" "$W/g/fs-thermald"
DL=16; RDY=4
for k in final poweroff; do
cat > "$W/bin/fake-$k" <<EOF
#!$W/bin/sh
read -r u _ < /proc/uptime
echo "\${u%%.*} \${1:-none} pid=\$\$ via=$k" >> "\$FS_REC"
while :; do sleep 3600; done
EOF
chmod 0755 "$W/bin/fake-$k"
done
cat > "$W/bin/fake-reboot" <<EOF
#!$W/bin/sh
read -r u _ < /proc/uptime
echo "\${u%%.*} \${1:-none} pid=\$\$ via=fork" >> "\$FS_REC"
exit 1
EOF
chmod 0755 "$W/bin/fake-reboot"
ln -s "$W/bin/fake-poweroff" "$W/bin/poweroff-link"

cat > "$W/sim.sh" <<'EOF'
. "$HOLD"
log()   { echo "FS t=$(cut -d. -f1 /proc/uptime)s $*" >> "$FS_RUN/fs.log"; }
stage() { echo "$1" >> "$FS_RUN/fs.stages"; }
led()   { :; }
fs_hold_init "$DL" "$DL"
echo "$T0" > "$FS_REC.t0"; echo "$$" > "$FS_REC.pid"
fs_start_backstop
if [ -n "$GUARD_MODE" ]; then
    "$GUARD_BIN" "$FS_GUARD_HB" "$GUARD_MODE" "$GUARD_AFTER" &
    FS_GUARD_PID=$!
fi
if [ -n "$FORGE_PID" ]; then sleep 600 & FS_GUARD_PID=$!; fi
echo ab > "$FS_RUN/host_ack"
fs_hold_loop
EOF

SUM=$HERE/fixtures/stage/RESULTS.txt
mkdir -p "$(dirname "$SUM")"
: > "$SUM"
echo "pid1-hold-ts.sh sha256=$(sha256sum "$HOLD" | cut -c1-64)" | tee -a "$SUM"
echo "busybox         sha256=$(sha256sum "$W/bin/busybox" | cut -c1-64) (reviewed stage-1 binary, under qemu-aarch64)" | tee -a "$SUM"
up() { cut -d. -f1 /proc/uptime; }
npass=0; nall=0

# scenario NAME WANT_REASON WANT_VIA LO HI [ENV=VAL...]   (WANT none: no record, the sim must exit 1)
scenario() {
    local name=$1 want=$2 wvia=$3 lo=$4 hi=$5; shift 5
    local R=$W/$name REC=$W/$name.rec
    mkdir -p "$R"
    ( cd /; exec setsid env -i PATH="$W/bin" HOLD="$HOLD" FS_RUN="$R" FS_REC="$REC" FS_UPTIME=/proc/uptime \
        FS_REBOOT_BIN="$W/bin/fake-reboot" FS_REBOOT_FINAL="$W/bin/fake-final" \
        FS_REBOOT_FALLBACK="$W/bin/fake-reboot fallback" FS_POWEROFF_FINAL="$W/bin/fake-poweroff" \
        FS_GUARD_HB="$R/hb" GUARD_BIN="$W/g/fs-thermald" FS_GUARD_READY_S=$RDY DL=$DL \
        GUARD_MODE= GUARD_AFTER=3 FORGE_PID= "$@" \
        sh -c "\"$QEMU\" \"$W/bin/busybox\" sh \"$W/sim.sh\"; echo \$? > \"$REC.exit\"" > "$R.out" 2>&1 ) &
    disown $! 2>/dev/null
    local st=$(( $(up) + hi + 4 )) prep="" a
    for a in "$@"; do case "$a" in PREP=*) prep=${a#PREP=} ;; esac; done
    if [ -n "$prep" ]; then "$prep" "$R"; fi
    while [ ! -s "$REC" ] && [ ! -s "$REC.exit" ] && [ "$(up)" -lt "$st" ]; do sleep 0.2; done
    sleep 0.3
    local first t0 when why via rpid simpid rel ok=1 detail
    first=$(head -1 "$REC" 2>/dev/null)
    t0=$(cat "$REC.t0" 2>/dev/null || echo 0)
    when=$(echo "$first" | cut -d' ' -f1); why=$(echo "$first" | cut -d' ' -f2)
    via=$(echo "$first" | sed -n 's/.* via=//p'); rpid=$(echo "$first" | sed -n 's/.* pid=\([0-9]*\).*/\1/p')
    simpid=$(cat "$REC.pid" 2>/dev/null)
    if [ "$want" = none ]; then
        [ -z "$first" ] && [ "$(cat "$REC.exit" 2>/dev/null)" = 1 ] && ok=0
        detail="records='$first' exit=$(cat "$REC.exit" 2>/dev/null)"
    else
        rel=$(( ${when:-0} - t0 ))
        [ "$why" = "$want" ] && [ "$via" = "$wvia" ] && [ "$rel" -ge "$lo" ] && [ "$rel" -le "$hi" ] && ok=0
        # PID 1's own power-off / reboot is an exec (same pid), never a fork
        case "$wvia" in final|poweroff) [ "$rpid" = "$simpid" ] || ok=1 ;; esac
        detail="first='$first' t-T0=$rel (want $want via=$wvia in $lo..$hi)"
    fi
    nall=$((nall + 1))
    if [ $ok = 0 ]; then npass=$((npass + 1)); echo "PASS $name: $detail" | tee -a "$SUM"
    else echo "FAIL $name: $detail" | tee -a "$SUM"; sed 's/^/    log: /' "$R/fs.log" 2>/dev/null | tail -5; fi
    pkill -9 -f "$R" 2>/dev/null; pkill -9 -f "$W/g/fs-thermald $R" 2>/dev/null
}

forge_trip() { sleep 3; printf '9 1 TRIP\n' > "$1/hb"; }
forge_ready() { for _ in $(seq 1 20); do [ -d "$1" ] || break; printf '%s %s READY\n' "$RANDOM" "$(up)" > "$1/hb"; sleep 0.5; done & }
fifo_hb() { mkfifo "$1/hb"; }

scenario trip_basic             trip poweroff 3 6   GUARD_MODE=trip
scenario trip_missing_helper    none -        0 8   GUARD_MODE=trip FS_POWEROFF_FINAL=/nonexistent
scenario trip_symlink_helper    none -        0 8   GUARD_MODE=trip FS_POWEROFF_FINAL="$W/bin/poweroff-link"
scenario trip_forged_no_guard   trip poweroff 3 6   PREP=forge_trip
scenario no_guard_deadline      deadline final 16 18
scenario hb_fifo_ignored        deadline final 16 18 PREP=fifo_hb
scenario req_never_ready        guard-not-ready final 4 6  FS_GUARD_REQUIRED=1 GUARD_MODE=init
scenario req_ready_holds        deadline final 16 18       FS_GUARD_REQUIRED=1 GUARD_MODE=ready
scenario req_ready_then_trip    trip poweroff 3 6          FS_GUARD_REQUIRED=1 GUARD_MODE=trip
scenario req_stale_record       guard-stale final 8 11     FS_GUARD_REQUIRED=1 GUARD_MODE=stale
scenario req_seq_frozen         guard-stale-seq final 7 13 FS_GUARD_REQUIRED=1 GUARD_MODE=seqfreeze
scenario req_garbled_state       guard-stale-seq final 7 13 FS_GUARD_REQUIRED=1 GUARD_MODE=garble
scenario req_frozen_boottime    guard-stale final 8 11     FS_GUARD_REQUIRED=1 GUARD_MODE=frozen
scenario req_guard_dead         guard-dead final 3 6       FS_GUARD_REQUIRED=1 GUARD_MODE=dead
scenario req_forged_ready       guard-not-ready final 4 6  FS_GUARD_REQUIRED=1 FORGE_PID=1 PREP=forge_ready
echo "pid1-hold-ts TRIP branch: $npass/$nall pass" | tee -a "$SUM"
[ "$npass" = "$nall" ]
