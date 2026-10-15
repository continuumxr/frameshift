#!/bin/bash
# Reproducibility check, Quest 3 v2.7 (5.10) tree: mirror of repro_q2.sh.
# Rebuild the STOCK Quest 3 config (CRLF stripped) twice in fresh object dirs at the SAME absolute
# path (~/work/kgate27/out-repro), with the same source, toolchain, make and environment as
# relays/FS-A-006-raw/kernel-gate/kgate27.sh, pinning the build identity strings to those of the
# original FS-A-006 build (~/work/kgate27/out, include/generated/compile.h). Compare .config,
# vmlinux, arch/arm64/boot/Image, Module.symvers and every built .ko by SHA-256, and check
# module_layout + the 2601 vendor-required (symbol, CRC) pairs. Offline only; no device access.
# Usage: repro_q3.sh [aslr]     runs 1-2 (as kgate27.sh, ASLR on): run 1, compare vs original out/,
#                               move aside to out-repro-1, run 2 at the same path, compare with run 1
#        repro_q3.sh noaslr     runs 3-4: same, but every make runs under `setarch -R` (personality
#                               ADDR_NO_RANDOMIZE, inherited by clang/ld.lld). Run 2 is moved to
#                               out-repro-2, run 3 built and compared with run 2, moved to out-repro-3,
#                               run 4 built at the same path and compared with run 3.
# Finding (see reproducibility-quest3.txt): with ASLR on, clang r450784e's sample-PGO annotation
# (-fprofile-sample-use=vmlinux.profdata, CONFIG_META_SAMPLE_PGO) is address-dependent, so the
# bitcode of some translation units varies from run to run.
set -u
PHASE=${1:-aslr}
W=~/work/kgate27; O=$W/out-repro; R=$W/repro; mkdir -p $R
CL=~/toolchains/clang-r450784e/bin; MK=~/toolchains/build-tools/bin/make
REF=~/work/fs006-kernel/v27req
CFG="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"/firmware/quest3/extracted/v2.7-user_ota/kernel.config
export PATH=$CL:$PATH
umask 022
# Pinned to the original banner time, converted to UTC for publication: "#2 SMP PREEMPT Thu Oct 8
# 18:17:14 UTC 2026", <build-user>@<build-host>. The recorded hashes used the original local-zone
# string, so this timestamp (like the withheld user/host) does not reproduce them.
# PUBLIC COPY: the recorded build user/host values are withheld, so outside readers cannot
# reproduce the recorded hashes. FS_KBUILD_USER / FS_KBUILD_HOST default to builder /
# build-host; with them, run-to-run reproducibility can still be checked.
export KBUILD_BUILD_TIMESTAMP="Thu Oct 8 18:17:14 UTC 2026" KBUILD_BUILD_USER="${FS_KBUILD_USER:-builder}" KBUILD_BUILD_HOST="${FS_KBUILD_HOST:-build-host}" KBUILD_BUILD_VERSION=2
ENVV="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- REAL_CC=$CL/clang LLVM=1 LLVM_IAS=1 LD=$CL/ld.lld AR=$CL/llvm-ar NM=$CL/llvm-nm OBJCOPY=$CL/llvm-objcopy OBJDUMP=$CL/llvm-objdump READELF=$CL/llvm-readelf OBJSIZE=$CL/llvm-size STRIP=$CL/llvm-strip HOSTCC=$CL/clang HOSTAR=$CL/llvm-ar HOSTLD=$CL/ld.lld HOSTLDFLAGS=-fuse-ld=lld PYTHON=python3"

envinfo() {
  echo "== environment"
  echo "host: $(uname -srm)"; echo "nproc: $(nproc)"
  git -C $W/src log -1 --format='source: %H'; echo "source tree dirty files: $(git -C $W/src status --porcelain | wc -l)"
  echo "make: $($MK --version | head -1)"; echo "clang: $(clang --version | head -1)"; echo "ld.lld: $(ld.lld --version | head -1)"
  echo "pahole: $(pahole --version)"; echo "tar: $(tar --version | head -1)"; echo "xz: $(xz --version | head -1)"
  echo "python3: $(python3 --version)"; echo "perl: $(perl -e 'print $^V')"; echo "date: $(date --version | head -1)"
  cmp -s <(tr -d '\r' < $CFG) $W/stock.config && echo "stock.config == CRLF-stripped $CFG" || echo "stock.config DIFFERS from firmware config"
  echo "locale: LANG=${LANG:-} LC_ALL=${LC_ALL:-} TZ=${TZ:-} (localtime $(date +%Z)) umask $(umask)"
  echo "kernel.randomize_va_space: $(cat /proc/sys/kernel/randomize_va_space)"
  env | grep "^KBUILD_" | sort
}

build() {  # build into $O (fresh)
  echo "== build start $(date -u +%FT%TZ)"
  rm -rf $O; mkdir -p $O
  cp $W/stock.config $O/.config
  $SA $MK -C $W/src O=$O $ENVV olddefconfig > $R/olddefconfig.$1.log 2>&1 || { echo "olddefconfig failed"; exit 1; }
  T0=$(date +%s)
  $SA $MK -C $W/src O=$O $ENVV -j12 Image modules > $R/build.$1.log 2>&1; rc=$?
  echo "build rc=$rc in $(( $(date +%s) - T0 ))s"; [ $rc -eq 0 ] || { tail -20 $R/build.$1.log; exit 3; }
  grep -a -m1 -o 'Linux version 5[[:print:]]*' $O/vmlinux
}

manifest() {  # $1 dir, $2 out file
  ( cd $1 && sha256sum .config vmlinux arch/arm64/boot/Image Module.symvers && find . -name '*.ko' -printf '%P\n' | sort | xargs sha256sum ) > $2
}

compare() {  # $1 manifest A (reference), $2 manifest B
  for f in .config vmlinux arch/arm64/boot/Image Module.symvers; do
    a=$(awk -v f=$f '$2==f{print $1}' $1); b=$(awk -v f=$f '$2==f{print $1}' $2)
    [ "$a" = "$b" ] && echo "IDENTICAL $f $a" || echo "DIFFERS   $f ref=$a new=$b"
  done
  join -1 2 -2 2 <(grep '\.ko$' $1 | sort -k2,2) <(grep '\.ko$' $2 | sort -k2,2) > $R/ko_join.tmp
  echo ".ko: ref=$(grep -c '\.ko$' $1) new=$(grep -c '\.ko$' $2) common=$(wc -l < $R/ko_join.tmp) identical=$(awk '$2==$3' $R/ko_join.tmp | wc -l) differ=$(awk '$2!=$3' $R/ko_join.tmp | wc -l)"
  awk '$2!=$3{print "  DIFFERS " $1}' $R/ko_join.tmp | head -400
  echo ".ko list sha256: ref=$(grep '\.ko$' $1 | sha256sum | cut -c1-16) new=$(grep '\.ko$' $2 | sha256sum | cut -c1-16)"
}

crc() {  # vendor-required CRC check (as kgate27.sh step 4) for $O
  awk '$3=="vmlinux"{print $2, $1}' $O/Module.symvers | sort -u > $R/crcs.$1.txt
  join <(sort -u $REF/core_syms_needed.txt) <(sort -k1,1 $REF/req_versions.txt) > $R/need.txt
  join -a1 -e MISSING -o 0,1.2,2.2 $R/need.txt <(sort -k1,1 $R/crcs.$1.txt) > $R/cmp.$1.txt
  echo "vendor-required: required=$(wc -l < $R/cmp.$1.txt) match=$(awk '$2==$3' $R/cmp.$1.txt | wc -l) mismatch=$(awk '$3!="MISSING" && $2!=$3' $R/cmp.$1.txt | wc -l) missing=$(awk '$3=="MISSING"' $R/cmp.$1.txt | wc -l)"
  grep -w module_layout $R/cmp.$1.txt
  cmp -s $R/crcs.$1.txt $W/built_vmlinux_crcs.txt && echo "all $(wc -l < $R/crcs.$1.txt) vmlinux (symbol,CRC) pairs identical to original FS-A-006 build" || echo "vmlinux CRC set DIFFERS from original FS-A-006 build"
}

envinfo
if [ "$PHASE" = aslr ]; then
  SA=""
  [ -f $R/manifest.orig.txt ] || manifest $W/out $R/manifest.orig.txt
  echo; echo "## Run 1: pinned build in $O vs original FS-A-006 build $W/out (unpinned, path out/)"
  build 1; manifest $O $R/manifest.run1.txt; compare $R/manifest.orig.txt $R/manifest.run1.txt; crc run1
  rm -rf $O-1; mv $O $O-1
  echo; echo "## Run 2: second pinned build at the SAME path ($O) vs run 1 (moved to $O-1)"
  build 2; manifest $O $R/manifest.run2.txt
  compare $R/manifest.run1.txt $R/manifest.run2.txt; crc run2
elif [ "$PHASE" = noaslr ]; then
  SA="setarch $(uname -m) -R"; echo "make prefix: $SA"
  [ -d $O ] && { rm -rf $O-2; mv $O $O-2; }
  echo; echo "## Run 3: pinned build, ASLR off, at $O vs run 2 (ASLR on, moved to $O-2)"
  build 3; manifest $O $R/manifest.run3.txt; compare $R/manifest.run2.txt $R/manifest.run3.txt; crc run3
  rm -rf $O-3; mv $O $O-3
  echo; echo "## Run 4: second pinned ASLR-off build at the SAME path ($O) vs run 3 (moved to $O-3)"
  build 4; manifest $O $R/manifest.run4.txt
  compare $R/manifest.run3.txt $R/manifest.run4.txt; crc run4
fi
echo "== end $(date -u +%FT%TZ)"
