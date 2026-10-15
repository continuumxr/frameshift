#!/bin/bash
# Reproducibility check: rebuild the Quest 2 stock-config kernel in a FRESH object dir with the
# same source, toolchain, make and environment as kgateq2.sh, pinning the build identity strings
# to those recorded in the original banner; then compare hashes with ~/work/kgateq2/out.
# PUBLIC COPY: the banner time is converted to UTC and the recorded build user/host values are
# withheld (the original local-zone timestamp is not published either), so outside readers cannot
# reproduce the recorded hashes. FS_KBUILD_USER / FS_KBUILD_HOST default to builder /
# build-host; with them, run-to-run reproducibility can still be checked.
set -u
W=~/work/kgateq2; O=$W/out-repro
CL=~/toolchains/clang-r450784e/bin; MK=~/toolchains/build-tools/bin/make
export PATH=$CL:$PATH
export KBUILD_BUILD_TIMESTAMP="Thu Oct 8 21:13:58 UTC 2026" KBUILD_BUILD_USER="${FS_KBUILD_USER:-builder}" KBUILD_BUILD_HOST="${FS_KBUILD_HOST:-build-host}" KBUILD_BUILD_VERSION=1
ENVV="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- REAL_CC=$CL/clang LLVM=1 LLVM_IAS=1 LD=$CL/ld.lld AR=$CL/llvm-ar NM=$CL/llvm-nm OBJCOPY=$CL/llvm-objcopy OBJDUMP=$CL/llvm-objdump READELF=$CL/llvm-readelf OBJSIZE=$CL/llvm-size STRIP=$CL/llvm-strip HOSTCC=$CL/clang HOSTAR=$CL/llvm-ar HOSTLD=$CL/ld.lld HOSTLDFLAGS=-fuse-ld=lld PYTHON=python3"
echo "start $(date -u +%FT%TZ)"
rm -rf $O; mkdir -p $O/kernel/qcom; ln -sfn $W/src $O/kernel/qcom/kona
cp $W/stock.config $O/.config
$MK -C $W/src O=$O $ENVV olddefconfig > $O/olddefconfig.log 2>&1 || { echo "olddefconfig failed"; exit 1; }
T0=$(date +%s)
$MK -C $W/src O=$O $ENVV -j12 Image.gz modules > $O/build.log 2>&1; rc=$?
echo "build rc=$rc in $(( $(date +%s) - T0 ))s"
cmp -s $W/out/.config $O/.config && echo ".config identical" || echo ".config DIFFERS"
for f in vmlinux arch/arm64/boot/Image arch/arm64/boot/Image.gz Module.symvers; do
  a=$(sha256sum $W/out/$f | cut -c1-64); b=$(sha256sum $O/$f | cut -c1-64)
  [ "$a" = "$b" ] && echo "IDENTICAL $f $a" || echo "DIFFERS   $f orig=$a repro=$b"
done
echo "end $(date -u +%FT%TZ)"
