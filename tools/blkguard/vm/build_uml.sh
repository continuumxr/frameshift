#!/bin/bash
# fs-blkguard VM test kernel, UML variant (x86_64 User Mode Linux).
# Used because qemu-system-aarch64 is not installed and installing it is a download
# (needs PM approval; run_qemu.sh is ready for that case).  The UML kernel is built from
# the SAME Meta v2.7 tree with the SAME fs-blkguard commit, plus one test-only commit that
# guards a CONFIG_SMP-only call in Meta's scheduler (UML is !SMP); that commit is never
# part of a device kernel.  The block layer, SCSI midlayer, sd, sg, bsg, loop, brd and dm
# code under test is architecture-independent.  Offline; no device access.
#   bash tools/blkguard/vm/build_uml.sh [patched|unpatched]
#     patched   : ~/work/blkguard/src-um  (fs-blkguard + test-only build fix) -> out-um
#     unpatched : the same tree at the parent of the fs-blkguard commit (+ build fix) -> out-um-nog
set -euo pipefail
WHICH=${1:-patched}
W=~/work/blkguard
if [ "$WHICH" = patched ]; then
  S=$W/src-um; O=$W/out-um
else
  S=$W/src-um-nog; O=$W/out-um-nog
  if [ ! -d $S ]; then
    git clone -q --shared $W/src-um $S
    git -C $S checkout -q -b unpatched dbc2bc83a
    git -C $S -c user.name=fs-build -c user.email=fs-build@invalid cherry-pick "$(git -C $W/src-um log --format=%H -1 --grep='TEST ONLY (UML build)')"
  fi
fi
echo "== source: $(git -C $S log --oneline -3 | tr '\n' '|')"
mkdir -p $O
cp $S/arch/um/configs/x86_64_defconfig $O/.config
$S/scripts/config --file $O/.config -e BLK_DEV -e BLK_DEV_RAM --set-val BLK_DEV_RAM_COUNT 4 \
  --set-val BLK_DEV_RAM_SIZE 8192 -e BLK_DEV_LOOP -e PARTITION_ADVANCED -e EFI_PARTITION \
  -e MD -e BLK_DEV_DM -e SCSI -e BLK_DEV_SD -e CHR_DEV_SG -e BLK_DEV_BSG -e SCSI_LOWLEVEL \
  -e SCSI_DEBUG -e DEVTMPFS -e TMPFS -e HOSTFS -e AIO -e SWAP -d BLK_DEV_UBD -e MODULES \
  -d DEBUG_FS -e PROC_FS -e SYSFS -e RT_THROTTLING_SYSCTL -d WERROR -d RTIMD_I2C
MK="make -C $S ARCH=um O=$O CC=gcc HOSTCC=gcc KCFLAGS=-Wno-error=unknown-pragmas"
$MK olddefconfig > $O/olddefconfig.log 2>&1
grep -E '^CONFIG_(SCSI_DEBUG|BLK_DEV_DM|BLK_DEV_BSG|CHR_DEV_SG|HOSTFS|BLK_DEV_RAM_COUNT)=' $O/.config | tr '\n' ' '; echo
T0=$(date +%s)
rc=0; $MK -j6 linux > $O/build.log 2>&1 || rc=$?
echo "== UML build ($WHICH) rc=$rc in $(( $(date +%s) - T0 ))s"
[ $rc -eq 0 ] || { grep -m20 -E 'error:|Error ' $O/build.log; exit 3; }
ls -la $O/linux
