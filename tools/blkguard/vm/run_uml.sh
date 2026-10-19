#!/bin/bash
# fs-blkguard VM test (UML variant): boots the UML test kernel with fsbg-probe as PID 1,
# once per configuration, with decoy disks only:
#   - a host-file decoy disk (16 MiB GPT with Quest names, random fill), attached in the VM
#     as /dev/loop5 over the hostfs file and hashed ON THE HOST before and after each run;
#   - scsi_debug (a RAM SCSI disk: sd, sg and bsg nodes), GPT written by the probe pre-arm;
#   - brd RAM disks, a loop decoy on tmpfs, dm and loop stacks (see fsbg-probe.c).
# Offline; no device access; nothing outside ~/work/blkguard/uml-run is written.
#   bash tools/blkguard/vm/run_uml.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
W=~/work/blkguard
R=$W/uml-run
OUT=${OUT:-$REPO/tools/blkguard/vm/results}
mkdir -p "$OUT"
rm -rf "$R"; mkdir -p "$R/root/proc" "$R/root/sys" "$R/root/dev" "$R/root/run"
gcc -static -O2 -Wall -Wextra -Wno-unused-parameter -Wno-format-truncation \
    -o "$R/root/init" "$REPO/tools/blkguard/probe/fsbg-probe.c" || exit 2

mkdecoy() {   # a fresh host decoy with Quest names and random content
  local img=$R/root/fsbg-hostdecoy.img
  rm -f "$img"
  head -c $((16 << 20)) /dev/urandom > "$img"
  sgdisk -Z "$img" > /dev/null 2>&1
  sgdisk -o -n1:2048:+1M -c1:xbl_a -n2:0:+1M -c2:tz_a -n3:0:+1M -c3:persist \
         -n4:0:+1M -c4:recovery_a -n5:0:+1M -c5:keymaster_a -n6:0:+1M -c6:modemst1 \
         -n7:0:+1M -c7:fsbg_decoy_ro -n8:0:+1M -c8:userdata "$img" > /dev/null || exit 2
}

SUMMARY=$OUT/uml-summary.txt
: > "$SUMMARY"
note() { echo "$*" | tee -a "$SUMMARY"; }
note "# fs-blkguard UML VM test $(date -u +%FT%TZ)"
note "# kernel: $(sha256sum "$W/out-um/linux" | cut -c1-16) out-um/linux; $(git -C $W/src-um log --oneline -2 | tr '\n' '|')"
note "# probe:  $(sha256sum "$REPO/tools/blkguard/probe/fsbg-probe.c" | cut -c1-16) fsbg-probe.c"

run() {   # run <name> <kernel> <extra cmdline...>
  local name=$1 kern=$2; shift 2
  local nonce; nonce=$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')
  mkdecoy
  local before after; before=$(sha256sum "$R/root/fsbg-hostdecoy.img" | cut -d' ' -f1)
  ( cd "$R" && TMPDIR=$R timeout 600 "$kern" mem=384M rootfstype=hostfs rootflags="$R/root" rw \
      init=/init con=null con0=fd:0,fd:1 scsi_debug.dev_size_mb=16 \
      fsbg.nonce="$nonce" "$@" < /dev/null > "$OUT/uml-$name.log" 2>&1 )
  local rc=$?
  after=$(sha256sum "$R/root/fsbg-hostdecoy.img" | cut -d' ' -f1)
  local res; res=$(tr -d '\r' < "$OUT/uml-$name.log" | grep -a "FSBG-PROBE RESULT" | tail -1)
  note "[$name] cmdline: $*"
  note "[$name] ${res:-no result line} (uml exit $rc)"
  grep -a "nonce=$nonce" "$OUT/uml-$name.log" > /dev/null && note "[$name] fresh nonce $nonce seen" \
    || note "[$name] nonce $nonce NOT seen"
  [ "$before" = "$after" ] && note "[$name] host decoy unchanged ($before)" \
    || note "[$name] HOST DECOY CHANGED: $before -> $after"
  tr -d '\r' < "$OUT/uml-$name.log" | grep -a -E "^(CASE|ALLOW).*FAIL|^STOP|^ABORT|HASH .*CHANGED" | sed "s/^/   [$name] /" | tee -a "$SUMMARY" > /dev/null
}

want() { [ -z "${RUNS:-}" ] || [[ " $RUNS " == *" $1 "* ]]; }   # RUNS="name ..." selects runs
want strict-bootprotect && run strict-bootprotect "$W/out-um/linux" fsbg.vm
want strict-bootoff     && run strict-bootoff     "$W/out-um/linux" fsbg.vm fs_blkguard=off
want protect            && run protect            "$W/out-um/linux" fsbg.vm fsbg.protect
want device-mode        && run device-mode        "$W/out-um/linux" fsbg.testkernel
want k1g-layout         && run k1g-layout         "$W/out-um/linux" fsbg.testkernel fsbg.tmpfsdev fsbg.child fsbg.compact
# K1g r3 (J-207): the same with scsi_debug on 4096-byte logical blocks (the Quest 3 UFS block size)
want strict-4k         && run strict-4k         "$W/out-um/linux" fsbg.vm scsi_debug.sector_size=4096
want k1g-layout-4k     && run k1g-layout-4k     "$W/out-um/linux" fsbg.testkernel fsbg.tmpfsdev fsbg.child fsbg.compact scsi_debug.sector_size=4096
if [ -x "$W/out-um-nog/linux" ] && want unpatched-kernel; then
  run unpatched-kernel "$W/out-um-nog/linux" fsbg.vm
fi
note "# end $(date -u +%FT%TZ)"
