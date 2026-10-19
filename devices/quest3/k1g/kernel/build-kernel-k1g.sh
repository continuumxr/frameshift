#!/bin/bash
# K1g kernel build (Quest 3): Meta v2.7 source dbc2bc83a2b6 PLUS the fs-blkguard patch (commit a9c63e24cb76, the
# patch file tools/blkguard/patches/0001-*.patch byte-identical to `git format-patch` of that commit), with the
# EXACT K1a config (stock v2.7 config plus the K1a request list quest3-k1a.txt; the patch adds no Kconfig symbol).
# Adapted copy of ../../k1a/kernel/build-kernel.sh (not edited); differences: source tree, patch check, build host
# k1g, object path ~/work/kgate27/out-k1g. Built with the pinned toolchain, make variables and build identity of the kernel gate
# (relays/FS-A-006-raw/kernel-gate/kgate27*.sh, tools/kgate/validation/repro_q3.sh), plus ASLR off
# (setarch -R), which repro_q3.sh showed is needed for a bit-identical vmlinux/Image (sample-PGO).
# Offline only: no device access, no downloads. Runs in WSL.
#
# Usage: build-kernel.sh <outdir> <log-dir>
#   <outdir>   object directory (fresh; deleted first). Bit-identical rebuilds must use the SAME absolute path:
#              build at ~/work/kgate27/out-k1g, move it aside, build again at the same path, compare
#              (compare-builds.sh; kernel/BUILD-RECORD.txt).
#   <log-dir>  where the build record, the olddefconfig/build logs and the manifest go.
# Env (optional): FS_STOCK_CONFIG (the firmware kernel.config, CRLF allowed), FS_REQ (request list), FS_JOBS (make -j;
#   default nproc; recorded; the job count does not change the output).
# Review M1/m5 (2026-10-15): pipefail; every pin file checked first: toolchain.sha256 (the clang/LLVM tools, AOSP make,
# pahole and its dwarves/dw/elf libraries, the PGO profile), toolchain-clanglib.sha256 (clang's resource directory),
# toolchain.links (each tool name resolves to the pinned file); written by make-toolchain-pins.sh. python3, perl, tar
# and xz are recorded, not pinned.
set -uo pipefail
O=${1:?outdir}; L=${2:?logdir}; mkdir -p "$L"
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
W=~/work/kgate27; SRC=${FS_K1G_SRC:-$HOME/work/k1g/src}   # a pristine checkout of the patched commit
CL=~/toolchains/clang-r450784e/bin; MK=~/toolchains/build-tools/bin/make
REQ=${FS_REQ:-$REPO/tools/kgate/validation/requests/quest3-k1a.txt}
CFG=${FS_STOCK_CONFIG:-<repo>/firmware/quest3/extracted/v2.7-user_ota/kernel.config}
SRC_COMMIT=a9c63e24cb76ef7f16781c0a86b9f9905bad9128     # fs-blkguard on dbc2bc83a2b6
BASE_COMMIT=dbc2bc83a2b673f5d1c24ee9dadb0cd708ffda3f
PATCH=$REPO/tools/blkguard/patches/0001-block-add-fs-blkguard-a-boot-chain-block-write-guard.patch
PIN=$REPO/devices/quest3/k1a/kernel   # the K1a toolchain pin files, reused unchanged
JOBS=${FS_JOBS:-$(nproc)}
case "$JOBS" in ''|*[!0-9]*|0) echo "FATAL: FS_JOBS '$JOBS' is not a positive number"; exit 2 ;; esac
export PATH=$CL:$PATH
umask 022
export LANG=C.UTF-8 TZ=UTC; unset LC_ALL
# Pinned build identity: uname -v shows "#1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026"; /proc/version
# shows (frameshift@k1g). This proves our build booted, not which attempt (the nonce does that).
export KBUILD_BUILD_TIMESTAMP="Wed Oct 14 00:00:00 UTC 2026" KBUILD_BUILD_USER=frameshift KBUILD_BUILD_HOST=k1g KBUILD_BUILD_VERSION=1
ENVV="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- REAL_CC=$CL/clang LLVM=1 LLVM_IAS=1 LD=$CL/ld.lld AR=$CL/llvm-ar NM=$CL/llvm-nm OBJCOPY=$CL/llvm-objcopy OBJDUMP=$CL/llvm-objdump READELF=$CL/llvm-readelf OBJSIZE=$CL/llvm-size STRIP=$CL/llvm-strip HOSTCC=$CL/clang HOSTAR=$CL/llvm-ar HOSTLD=$CL/ld.lld HOSTLDFLAGS=-fuse-ld=lld PYTHON=python3"
SA="setarch $(uname -m) -R"
REC=$L/build-record.txt
die() { echo "FATAL: $*" | tee -a "$REC"; exit 2; }

: > "$REC"
{
  echo "# K1g kernel build record"
  echo "start: $(date -u +%FT%TZ)"
  echo "outdir: $O"
  echo "host: $(uname -srm); nproc $(nproc); make -j$JOBS"
  echo "source: $(git -C $SRC log -1 --format=%H) (dirty files: $(git -C $SRC status --porcelain | wc -l))"
  echo "make: $($MK --version | head -1)"
  echo "clang: $($CL/clang --version | head -1)"
  echo "ld.lld: $($CL/ld.lld --version | head -1)"
  echo "pahole: $(pahole --version)"
  echo "recorded, not pinned: python3 $(python3 --version 2>&1 | cut -d' ' -f2); perl $(perl -e 'print $^V'); $(tar --version | head -1); $(xz --version | head -1); glibc $(ldd --version | head -1 | awk '{print $NF}')"
  echo "locale: LANG=$LANG TZ=$TZ umask $(umask); randomize_va_space $(cat /proc/sys/kernel/randomize_va_space); make prefix: $SA"
  env | grep '^KBUILD_' | sort
  echo "make vars: $ENVV"
  echo "request list: $REQ sha256 $(sha256sum < "$REQ" | cut -d' ' -f1)"
  echo "stock config: $CFG sha256 $(sha256sum < "$CFG" | cut -d' ' -f1) (CRLF-stripped $(tr -d '\r' < "$CFG" | sha256sum | cut -d' ' -f1))"
  echo "build-kernel-k1g.sh: $(sha256sum < "$0" | cut -d' ' -f1)"
  echo "patch: $PATCH sha256 $(sha256sum < "$PATCH" | cut -d' ' -f1)"
} | tee -a "$REC"

[ "$(git -C $SRC log -1 --format=%H)" = "$SRC_COMMIT" ] || die "source is not $SRC_COMMIT"
[ "$(git -C $SRC status --porcelain --ignored | wc -l)" = 0 ] || die "source tree is dirty (incl. ignored build files)"
[ "$(git -C $SRC rev-parse "$SRC_COMMIT^")" = "$BASE_COMMIT" ] || die "the patch commit's parent is not $BASE_COMMIT"
cmp -s <(git -C $SRC format-patch -1 --stdout "$SRC_COMMIT") "$PATCH" || die "the source commit differs from $PATCH"
echo "patch: the source commit's format-patch equals the committed patch file" | tee -a "$REC"
for pf in toolchain.sha256 toolchain-clanglib.sha256; do
  [ -f "$PIN/$pf" ] || die "no toolchain pin file $PIN/$pf (make-toolchain-pins.sh)"
  ( cd / && sha256sum -c --quiet "$PIN/$pf" ) >> "$REC" 2>&1 || die "toolchain differs from $PIN/$pf"
  echo "toolchain: matches $pf ($(grep -c . "$PIN/$pf") files; pin file sha256 $(sha256sum < "$PIN/$pf" | cut -d' ' -f1))" | tee -a "$REC"
done
[ -f "$PIN/toolchain.links" ] || die "no $PIN/toolchain.links"
while read -r name target; do
  [ "$(readlink -f "$CL/$name")" = "$target" ] || die "$CL/$name resolves to $(readlink -f "$CL/$name"), not the pinned $target"
done < "$PIN/toolchain.links"
echo "toolchain: every tool name resolves to its pinned file (toolchain.links, $(grep -c . "$PIN/toolchain.links") names)" | tee -a "$REC"
cmp -s <(tr -d '\r' < "$CFG") $W/stock.config || die "$W/stock.config differs from the CRLF-stripped firmware config"

# request tokens (comments stripped), as tools/kgate parse_requested reads them
mapfile -t TOK < <(grep -v '^[[:space:]]*#' "$REQ" | tr -s ' \t\r\n' '\n' | grep -v '^$')
echo "requests: ${TOK[*]}" | tee -a "$REC"

rm -rf "$O"; mkdir -p "$O"
cp $W/stock.config "$O/.config"
$SRC/scripts/config --file "$O/.config" "${TOK[@]}" || die "scripts/config failed"
$SA $MK -C $SRC O="$O" $ENVV olddefconfig > "$L/olddefconfig.log" 2>&1 || die "olddefconfig failed"
echo "== config delta vs stock (olddefconfig of stock.config = the step-2 build's .config):" | tee -a "$REC"
diff <(grep -E '^(CONFIG_|# CONFIG_)' $W/out/.config | sort) <(grep -E '^(CONFIG_|# CONFIG_)' "$O/.config" | sort) | grep '^[<>]' | tee -a "$REC"
T0=$(date +%s)
$SA $MK -C $SRC O="$O" $ENVV -j"$JOBS" Image modules > "$L/build.log" 2>&1; rc=$?
echo "build rc=$rc in $(( $(date +%s) - T0 ))s" | tee -a "$REC"
[ $rc -eq 0 ] || { tail -30 "$L/build.log" | tee -a "$REC"; exit 3; }
echo "banner: $(grep -a -m1 -o 'Linux version 5[[:print:]]*' "$O/vmlinux")" | tee -a "$REC"
echo "kernelrelease: $(cat "$O/include/config/kernel.release")" | tee -a "$REC"
( cd "$O" && sha256sum .config vmlinux arch/arm64/boot/Image Module.symvers System.map && find . -name '*.ko' -printf '%P\n' | LC_ALL=C sort | xargs sha256sum ) > "$L/manifest.txt" \
  || die "the manifest could not be written"
head -5 "$L/manifest.txt" | tee -a "$REC"
echo ".ko: $(grep -c '\.ko$' "$L/manifest.txt") (list sha256 $(grep '\.ko$' "$L/manifest.txt" | sha256sum | cut -d' ' -f1))" | tee -a "$REC"
echo "end: $(date -u +%FT%TZ)" | tee -a "$REC"
