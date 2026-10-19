#!/bin/bash
# fs-blkguard VM test (QEMU variant): boots the generic arm64 test kernel on QEMU "virt"
# with fsbg-probe as PID 1 (initramfs) and two host-file decoy disks carrying Quest GPT
# names and random content: virtio-blk (vda) and virtio-scsi scsi-hd (sda, with sg and bsg
# nodes).  Both images are hashed on the host before and after every run.
# NEEDS qemu-system-aarch64, which is not installed: installing it (apt install
# qemu-system-arm) is a download and needs the PM's approval first.  Offline otherwise.
#   bash tools/blkguard/vm/run_qemu.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
W=~/work/blkguard
R=$W/qemu-run
OUT=${OUT:-$REPO/tools/blkguard/vm/results}
command -v qemu-system-aarch64 > /dev/null || { echo "qemu-system-aarch64 not installed (needs PM approval to download)"; exit 2; }
mkdir -p "$OUT"; rm -rf "$R"; mkdir -p "$R/initramfs/proc" "$R/initramfs/sys" "$R/initramfs/dev" "$R/initramfs/run"
aarch64-linux-gnu-gcc -static -O2 -Wall -Wextra -Wno-unused-parameter -Wno-format-truncation \
    -o "$R/initramfs/init" "$REPO/tools/blkguard/probe/fsbg-probe.c" || exit 2
( cd "$R/initramfs" && find . | LC_ALL=C sort | cpio -o -H newc --quiet ) > "$R/initramfs.cpio"

mkdecoy() {   # mkdecoy <img>: 16 MiB, random fill, GPT with Quest names
  rm -f "$1"; head -c $((16 << 20)) /dev/urandom > "$1"; sgdisk -Z "$1" > /dev/null 2>&1
  sgdisk -o -n1:2048:+1M -c1:xbl_a -n2:0:+1M -c2:tz_a -n3:0:+1M -c3:persist \
         -n4:0:+1M -c4:${DECOY_P4:-recovery_a} -n5:0:+1M -c5:keymaster_a -n6:0:+1M -c6:modemst1 \
         -n7:0:+1M -c7:fsbg_decoy_ro -n8:0:+1M -c8:userdata "$1" > /dev/null || exit 2
}

SUMMARY=$OUT/qemu-summary.txt
[ -n "${RUNS:-}" ] || : > "$SUMMARY"
note() { echo "$*" | tee -a "$SUMMARY"; }
note "# fs-blkguard QEMU VM test $(date -u +%FT%TZ); $(qemu-system-aarch64 --version | head -1)"
note "# kernel: $(sha256sum < "$W/out-qemu/arch/arm64/boot/Image" | cut -c1-16) out-qemu Image"
note "# probe:  $(sha256sum < "$REPO/tools/blkguard/probe/fsbg-probe.c" | cut -c1-16) fsbg-probe.c (built here for the VM; the device binary is k1g/build-probe.sh's)"

run() {   # run <name> <Image> <extra cmdline...>
  local name=$1 kern=$2; shift 2
  local nonce; nonce=$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')
  mkdecoy "$R/blk.img"; mkdecoy "$R/scsi.img"
  local b1 b2 a1 a2
  b1=$(sha256sum "$R/blk.img" | cut -d' ' -f1); b2=$(sha256sum "$R/scsi.img" | cut -d' ' -f1)
  timeout ${QEMU_TIMEOUT:-500} qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 2 -m 512 -nographic -no-reboot \
    -kernel "$kern" -initrd "${INITRD:-$R/initramfs.cpio}" \
    -append "console=ttyAMA0 loglevel=3 rdinit=/init panic=-1 fsbg.nonce=$nonce $*" \
    -drive if=none,file="$R/blk.img",format=raw,id=d0 -device virtio-blk-device,drive=d0 \
    -device virtio-scsi-device,id=scsi0 \
    -drive if=none,file="$R/scsi.img",format=raw,id=d1 -device scsi-hd,drive=d1,bus=scsi0.0 \
    ${EXTRA_DRIVE:-} < /dev/null > "$OUT/qemu-$name.log" 2>&1
  local rc=$?
  a1=$(sha256sum "$R/blk.img" | cut -d' ' -f1); a2=$(sha256sum "$R/scsi.img" | cut -d' ' -f1)
  note "[$name] cmdline: $*"
  note "[$name] $(tr -d '\r' < "$OUT/qemu-$name.log" | grep -a 'FSBG-PROBE RESULT' | tail -1) (qemu exit $rc)"
  grep -a -q "nonce=$nonce" "$OUT/qemu-$name.log" && note "[$name] fresh nonce $nonce seen" || note "[$name] nonce NOT seen"
  [ "$b1" = "$a1" ] && note "[$name] virtio-blk decoy unchanged" || note "[$name] VIRTIO-BLK DECOY CHANGED"
  [ "$b2" = "$a2" ] && note "[$name] virtio-scsi decoy unchanged" || note "[$name] VIRTIO-SCSI DECOY CHANGED"
  tr -d '\r' < "$OUT/qemu-$name.log" | grep -a -E "^(CASE|ALLOW).*FAIL|^STOP|^ABORT|HASH .*CHANGED" | sed "s/^/   [$name] /" | tee -a "$SUMMARY" > /dev/null
}

K=$W/out-qemu/arch/arm64/boot/Image
want() { [ -z "${RUNS:-}" ] || [[ " $RUNS " == *" $1 "* ]]; }   # RUNS="name ..." selects runs
want strict-bootprotect && run strict-bootprotect "$K" fsbg.vm
want strict-bootoff     && run strict-bootoff     "$K" fsbg.vm fs_blkguard=off
want protect            && run protect            "$K" fsbg.vm fsbg.protect
want device-mode        && run device-mode        "$K" fsbg.testkernel
want k1g-layout         && run k1g-layout         "$K" fsbg.testkernel fsbg.tmpfsdev fsbg.child fsbg.compact
# negative (FS-A-014 review, MAJOR 1): a VM-only flag on a platform that identifies as a Quest is refused. The QEMU
# machine is given the Quest's stock DTB boot arguments (qcom_dload_mode, msm_drm.dsi_display0=meta): the probe must
# ABORT with "VM-only mode(s) testkernel refused" before anything else (see also probe/test/test-identity.c)
want quest-ident        && run quest-ident        "$K" fsbg.testkernel qcom_dload_mode.download_mode=1 msm_drm.dsi_display0=meta,eureka_panel_sharp:

# ufs-*: the same runs with a QEMU UFS host as well (ufshcd-pci with the test-only PCI id,
# qemu-test-only-ufs-pci-id.patch; its transport bsg /dev/bsg/ufs-bsg0 and well-known LUNs) and one 64 MiB LU
# (random fill, 4096-byte blocks), hashed on the host. Q10 (and C19 in vm mode) run on ufs-bsg0. Q12 cannot run here:
# UFS_IOCTL_QUERY is installed by Qualcomm's ufs-qcom vendor driver, which binds only to Qualcomm UFS hardware
# (QEMU's PCI UFS host has no driver ioctl); Q12 runs in UML (scsi_debug's host ioctl, the same scsi_ioctl path).
ufsrun() {   # ufsrun <name> <cmdline...>
  local name=$1 ub ua; shift
  rm -f "$R/ufs.img"; head -c $((64 << 20)) /dev/urandom > "$R/ufs.img"
  ub=$(sha256sum "$R/ufs.img" | cut -d' ' -f1)
  EXTRA_DRIVE="-device ufs,serial=fsbgufs,id=ufs0 -drive if=none,file=$R/ufs.img,format=raw,id=u0 -device ufs-lu,drive=u0,bus=ufs0" \
    run "$name" "$K" "$@"
  ua=$(sha256sum "$R/ufs.img" | cut -d' ' -f1)
  [ "$ub" = "$ua" ] && note "[$name] UFS LU unchanged" || note "[$name] UFS LU CHANGED"
  tr -d '\r' < "$OUT/qemu-$name.log" | grep -a -E "^(CASE|SKIP) +(Q10|Q12|C19) " | sed "s/^/   [$name] /" | tee -a "$SUMMARY" > /dev/null
}
want ufs-strict         && ufsrun ufs-strict fsbg.vm
want ufs-device         && ufsrun ufs-device fsbg.testkernel

# devicesim: EVERY device code path (the 16-name storage check, R1-R6 against the expected v2.7 values, no Q11,
# Q12 only where the host has a driver ioctl, compact output, tmpfs /dev, 32 MiB /run, child of PID 1); only the
# build-hazard check is waived. Two more disks carry the Quest names; boot_a/vendor_boot_a/dtbo_a/vbmeta_a/
# vbmeta_system_a hold the local v2.7 OTA images (Meta data: in ~/work only, never committed), misc 1 MiB,
# devinfo 4 KiB. It is hashed on the host before and after.
# QUEST_LBS=4096 (K1g r3, J-207): the two Quest-named disks are virtio-blk disks with 4096-byte LOGICAL blocks, as the
# Quest 3's UFS LUNs, and their GPT is written in 4096-byte LBAs (tools/blkguard/vm/mkgpt.py; same names, sizes and
# content as the 512-byte layout, partitions back to back from 1 MiB). R3 dtbo_a (12,564 bytes), R4 vbmeta_a (5,632)
# and R5 vbmeta_system_a (3,136) are then read through O_DIRECT on 4096-byte blocks, as on the unit.
mkquest4k() {   # mkquest4k <imgA> <imgB>
  local f=${FS_INPUT_ROOT:-<repo>}/firmware/quest3/v2.7-user_ota M=1048576 K=4096
  local -A offA offB
  local n name o sz
  rm -f "$1" "$2"
  while read -r n name o sz; do offA[$n]=$o; done < <(python3 "$REPO/tools/blkguard/vm/mkgpt.py" "$1" 4096 $((80 * M)) \
    boot_a:$((64 * M)) vendor_boot_a:$((8 * M)) dtbo_a:$M vbmeta_a:$((64 * K)) vbmeta_system_a:$((64 * K)) misc:$M \
    devinfo:$K xbl_a:$M) || exit 2
  while read -r n name o sz; do offB[$n]=$o; done < <(python3 "$REPO/tools/blkguard/vm/mkgpt.py" "$2" 4096 $((16 * M)) \
    xbl_b:$M tz_a:$M tz_b:$M abl_a:$M persist:$M frp:$M modemst1:$M modemst2:$M fsg:$M cdt:$M ddr:$M) || exit 2
  [ "${#offA[@]}" = 8 ] && [ "${#offB[@]}" = 11 ] || exit 2
  put4k() { dd if="$3" of="$1" bs=1M seek="$2" count="$4" iflag=count_bytes oflag=seek_bytes conv=notrunc status=none; }
  put4k "$1" "${offA[1]}" "$f/boot.img" $((64 * M)); put4k "$1" "${offA[2]}" "$f/vendor_boot.img" $((8 * M))
  put4k "$1" "${offA[3]}" "$f/dtbo.img" $M; put4k "$1" "${offA[4]}" "$f/vbmeta.img" $((8 * K))
  put4k "$1" "${offA[5]}" "$f/vbmeta_system.img" $((4 * K))
  for n in 6 8; do put4k "$1" "${offA[$n]}" /dev/urandom $M; done
  put4k "$1" "${offA[7]}" /dev/urandom $K
  for n in 1 2 3 4 5 6 7 8 9 10 11; do put4k "$2" "${offB[$n]}" /dev/urandom $M; done
  # QUEST_CORRUPT=<n> (negative runs): one byte of questA partition n flipped, as in the 512-byte layout
  if [ -n "${QUEST_CORRUPT:-}" ]; then
    printf '\377' | dd of="$1" bs=1 seek=$((${offA[$QUEST_CORRUPT]} + 100)) conv=notrunc status=none
  fi
}
mkquest() {   # mkquest <imgA> <imgB>: virtio-blk has 16 minors (15 partitions), so the names go on two disks
  [ "${QUEST_LBS:-512}" = 4096 ] && { mkquest4k "$@"; return; }
  local f=${FS_INPUT_ROOT:-<repo>}/firmware/quest3/v2.7-user_ota
  put() { local off; off=$(sgdisk -i "$2" "$1" | awk '/^First sector/{print $3}'); dd if="$3" of="$1" bs=1M seek=$((off * 512)) count=$(($4 * 512)) iflag=count_bytes oflag=seek_bytes conv=notrunc status=none; }
  rm -f "$1" "$2"; truncate -s 80M "$1"; truncate -s 16M "$2"; sgdisk -Z "$1" > /dev/null 2>&1; sgdisk -Z "$2" > /dev/null 2>&1
  sgdisk -a 8 -o -n1:2048:+64M -c1:boot_a -n2:0:+8M -c2:vendor_boot_a -n3:0:+1M -c3:dtbo_a -n4:0:+64K -c4:vbmeta_a \
         -n5:0:+64K -c5:vbmeta_system_a -n6:0:+1M -c6:misc -n7:0:+4K -c7:devinfo -n8:0:+1M -c8:xbl_a "$1" > /dev/null || exit 2
  sgdisk -a 8 -o -n1:2048:+1M -c1:xbl_b -n2:0:+1M -c2:tz_a -n3:0:+1M -c3:tz_b -n4:0:+1M -c4:abl_a -n5:0:+1M -c5:persist \
         -n6:0:+1M -c6:frp -n7:0:+1M -c7:modemst1 -n8:0:+1M -c8:modemst2 -n9:0:+1M -c9:fsg -n10:0:+1M -c10:cdt -n11:0:+1M -c11:ddr \
         "$2" > /dev/null || exit 2
  put "$1" 1 "$f/boot.img" $((64 * 2048)); put "$1" 2 "$f/vendor_boot.img" $((8 * 2048)); put "$1" 3 "$f/dtbo.img" 2048
  put "$1" 4 "$f/vbmeta.img" 16; put "$1" 5 "$f/vbmeta_system.img" 8
  for i in 6 8; do put "$1" $i /dev/urandom 2048; done
  put "$1" 7 /dev/urandom 8
  # QUEST_CORRUPT=<n> (negative runs): one byte of questA partition n flipped (an expected-content mismatch)
  if [ -n "${QUEST_CORRUPT:-}" ]; then
    local off; off=$(sgdisk -i "$QUEST_CORRUPT" "$1" | awk '/^First sector/{print $3}')
    printf '\377' | dd of="$1" bs=1 seek=$((off * 512 + 100)) conv=notrunc status=none
  fi
  for i in 1 2 3 4 5 6 7 8 9 10 11; do put "$2" $i /dev/urandom 2048; done
}
devsim() {   # devsim <name>: one devicesim run with the Quest-named disks, hashed on the host before and after
  local lb=""
  [ "${QUEST_LBS:-512}" = 4096 ] && lb=",logical_block_size=4096,physical_block_size=4096"
  mkquest "$R/questA.img" "$R/questB.img"; qb=$(cat "$R/questA.img" "$R/questB.img" | sha256sum | cut -d' ' -f1)
  EXTRA_DRIVE="-drive if=none,file=$R/questA.img,format=raw,id=d2 -device virtio-blk-device,drive=d2$lb -drive if=none,file=$R/questB.img,format=raw,id=d3 -device virtio-blk-device,drive=d3$lb" \
    run "$1" "$K" fsbg.devicesim fsbg.tmpfsdev fsbg.child fsbg.compact ${EXTRA_CMDLINE:-}
  [ -z "$lb" ] || { tr -d '\r' < "$OUT/qemu-$1.log" | grep -a -E "\[vd[a-z]\] .*logical blocks|^ROW (H|R6) " | sed "s/^/   [$1] /" | tee -a "$SUMMARY" > /dev/null; }
  qa=$(cat "$R/questA.img" "$R/questB.img" | sha256sum | cut -d' ' -f1)
  [ "$qb" = "$qa" ] && note "[$1] Quest-named disks unchanged ($qb)" || note "[$1] QUEST-NAMED DISKS CHANGED: $qb -> $qa"
}
want devicesim && devsim devicesim
# negative: the decoy disks also carry a partition named boot_a, so the R1 name is ambiguous (3 nodes): the probe must
# ABORT before arming (exactly one node per readback name)
want devicesim-dupname && DECOY_P4=boot_a devsim devicesim-dupname
# negative: the before-hash pass budget set to 1 s (fsbg.prebudget, VM only): the probe must stop before arming with
# "ABORT: time:" (no armed guard test case attempted; the host classifies it INCONCLUSIVE)
want devicesim-timeout && EXTRA_CMDLINE=fsbg.prebudget=1 devsim devicesim-timeout
# negative (FS-R-014 s.3.2): vbmeta_a (R4) differs from the expected v2.7 value: the probe must read no further
# row (R5, R6, R7d, R8 "not read") and ABORT before arming
want devicesim-mismatch && QUEST_CORRUPT=4 devsim devicesim-mismatch
# K1g r3 (J-207): devicesim with the Quest-named disks on 4096-byte logical blocks (the unit's UFS block size): every
# row R1-R5, R6, R7d, R8 must pass with whole-4096-byte O_DIRECT reads
want devicesim-4k && EXTRA_CMDLINE=loglevel=6 QUEST_LBS=4096 devsim devicesim-4k
# and its negative on 4096-byte blocks: R4 vbmeta_a differs (as devicesim-mismatch): every later row "not read", ABORT
want devicesim-4k-mismatch && EXTRA_CMDLINE=loglevel=6 QUEST_LBS=4096 QUEST_CORRUPT=4 devsim devicesim-4k-mismatch
# the regression: the SAME 4K run with the r2 probe source (git show ${R2_REF:-a537251e}; 512-byte rounding) must ABORT
# before arming with R3 dtbo_a "Invalid argument" and every later row "not read", as on Unit 2
if want devicesim-4k-r2code; then
  mkdir -p "$R/initramfs-r2/proc" "$R/initramfs-r2/sys" "$R/initramfs-r2/dev" "$R/initramfs-r2/run"
  git -C "$REPO" show "${R2_REF:-a537251e}:tools/blkguard/probe/fsbg-probe.c" > "$R/fsbg-probe-r2.c" || exit 2
  aarch64-linux-gnu-gcc -static -O2 -Wall -Wextra -Wno-unused-parameter -Wno-format-truncation \
      -o "$R/initramfs-r2/init" "$R/fsbg-probe-r2.c" || exit 2
  ( cd "$R/initramfs-r2" && find . | LC_ALL=C sort | cpio -o -H newc --quiet ) > "$R/initramfs-r2.cpio"
  note "# devicesim-4k-r2code probe: $(sha256sum < "$R/fsbg-probe-r2.c" | cut -c1-16) fsbg-probe.c at ${R2_REF:-a537251e} (the r2 code)"
  EXTRA_CMDLINE=loglevel=6 INITRD=$R/initramfs-r2.cpio QUEST_LBS=4096 devsim devicesim-4k-r2code
fi
note "# end $(date -u +%FT%TZ)"
