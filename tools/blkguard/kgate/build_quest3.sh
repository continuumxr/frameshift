#!/bin/bash
# fs-blkguard: build Meta's Quest 3 v2.7 kernel (group "a", the K1a option set already
# gated by kgate) with the fs-blkguard patch, for the kgate CRC-neutrality check.
# Same toolchain, make and environment as relays/FS-A-006-raw/kernel-gate/kgate27-step3.sh.
# Offline only; no device access.  Run in WSL:
#   bash tools/blkguard/kgate/build_quest3.sh [objs]
#     objs : compile only the touched translation units (quick syntax check)
#     (none): full Image + modules build into ~/work/blkguard/out-a
# Inputs : ~/work/blkguard/src (shared clone of ~/work/kgate27/src at dbc2bc83a, branch
#          fs-blkguard = the patch applied), ~/work/kgate27/out-a/.config (unpatched group-a build).
set -uo pipefail
PHASE=${1:-full}
W=~/work/blkguard; S=$W/src; O=$W/out-a; BASE=~/work/kgate27/out-a
CL=~/toolchains/clang-r450784e/bin; MK=~/toolchains/build-tools/bin/make
ENVV="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- REAL_CC=$CL/clang LLVM=1 LLVM_IAS=1 LD=$CL/ld.lld AR=$CL/llvm-ar NM=$CL/llvm-nm OBJCOPY=$CL/llvm-objcopy OBJDUMP=$CL/llvm-objdump READELF=$CL/llvm-readelf OBJSIZE=$CL/llvm-size STRIP=$CL/llvm-strip HOSTCC=$CL/clang HOSTAR=$CL/llvm-ar HOSTLD=$CL/ld.lld HOSTLDFLAGS=-fuse-ld=lld PYTHON=python3"
export PATH=$CL:$PATH
umask 022
echo "== source: $(git -C $S log -1 --format='%H %s')"
echo "== patch:  $(git -C $S diff --stat dbc2bc83a | tail -1)"
mkdir -p $O
if [ ! -f $O/.config ]; then
  cp $BASE/.config $O/.config
  $MK -C $S O=$O $ENVV olddefconfig > $O/olddefconfig.log 2>&1 || { echo "olddefconfig failed"; exit 1; }
fi
cmp -s $O/.config $BASE/.config && echo "== .config byte-identical to unpatched group-a build ($BASE/.config)" \
  || { echo "== .config DIFFERS from $BASE/.config"; diff $BASE/.config $O/.config | head; exit 1; }
if [ "$PHASE" = objs ]; then
  $MK -C $S O=$O $ENVV -j12 block/fs-blkguard.o block/blk-core.o block/ioctl.o block/scsi_ioctl.o \
     block/bsg.o drivers/scsi/sg.o fs/block_dev.o drivers/scsi/scsi_ioctl.o drivers/scsi/scsi_error.o 2>&1 | grep -E 'error|warning|fs-blkguard' ; echo "objs rc=${PIPESTATUS[0]}"
  exit 0
fi
T0=$(date +%s)
$MK -C $S O=$O $ENVV -j12 Image modules > $O/build.log 2>&1; rc=$?
echo "== build rc=$rc in $(( $(date +%s) - T0 ))s"
[ $rc -eq 0 ] || { grep -m20 -E 'error:|Error ' $O/build.log; exit 3; }
grep -E 'warning:.*fs-blkguard|fs-blkguard.*warning' $O/build.log || echo "== no compiler warnings from fs-blkguard"
grep -a -m1 -o 'Linux version 5[[:print:]]*' $O/vmlinux
cmp -s $O/Module.symvers $BASE/Module.symvers && echo "== Module.symvers byte-identical to the unpatched group-a build" \
  || { echo "== Module.symvers DIFFERS:"; diff $BASE/Module.symvers $O/Module.symvers | head -20; }
