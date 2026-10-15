#!/bin/bash
# FrameShift stage 3d — build fs-pattern v0.7.1 (static aarch64). Run inside WSL:
#   wsl.exe -e bash <repo>/devices/quest3/stage3d/tools/build.sh
# Offline only: builds and inspects binaries; touches no device.
#   build/fs-pattern           the tool (the only binary meant for a device image)
#   build/fs-pattern-unittest  same source with -DFSP_UNIT_TEST (offline only, never in an image)
#   build/fs-pattern-unittest-maxmodes128  v0.7.1's unit-test build with v0.7's MAXMODES 128 (the negative control of the
#                              v2.7 mode-list scenarios, J-141; offline only, never in an image)
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest3/stage3d
CLANG=$HOME/toolchains/clang-r450784e/bin/clang
UAPI=$HOME/work/kgate27/src/include/uapi/drm       # v2.7 Meta source, kernel uapi
LIBC_A=/usr/aarch64-linux-gnu/lib/libc.a
OUT=$HERE/build
mkdir -p "$OUT"

die() { echo "BUILD FAILED: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -c1-64; }
[ -x "$CLANG" ] || die "clang missing"
[ -f "$UAPI/drm.h" ] && [ -f "$UAPI/drm_mode.h" ] || die "v2.7 uapi headers missing"
[ -f "$LIBC_A" ] || die "static libc missing"

# drm.h in the raw source tree still carries __user (stripped by headers_install).
CFLAGS="--target=aarch64-linux-gnu -static -O2 -std=c11 -D_GNU_SOURCE -D__user= \
 -Wall -Wextra -Werror -Wno-missing-field-initializers -fno-ident -I$UAPI"
LDFLAGS="-fuse-ld=lld -Wl,--build-id=none -s"

build() {  # build <output> [extra flags]
    local o=$1; shift
    # shellcheck disable=SC2086
    "$CLANG" $CFLAGS "$@" $LDFLAGS -o "$o" "$HERE/src/fs-pattern.c"
}
build "$OUT/fs-pattern"
build "$OUT/fs-pattern.rebuild"          # reproducibility check
build "$OUT/fs-pattern-unittest" -DFSP_UNIT_TEST -Wno-unused-function -Wno-unused-variable
# v0.7.1 negative control: v0.7's mode limit (128) with the v0.7.1 mock; the v2.7 scenarios must exit 30 too_many_modes
sed -e 's/^#define MAXMODES 512 .*/#define MAXMODES 128/' -e 's/^#if MAXMODES < 480$/#if 0/' "$HERE/src/fs-pattern.c" > "$OUT/fs-pattern-maxmodes128.c"
[ "$(grep -c '^#define MAXMODES 128$' "$OUT/fs-pattern-maxmodes128.c")" = 1 ] || die "control source not made"
# shellcheck disable=SC2086
"$CLANG" $CFLAGS -DFSP_UNIT_TEST -Wno-unused-function -Wno-unused-variable $LDFLAGS -o "$OUT/fs-pattern-unittest-maxmodes128" "$OUT/fs-pattern-maxmodes128.c"

# static ELF requirements (same as stage-1 build.sh section 2)
B=$OUT/fs-pattern
file -b "$B" | grep -q "ARM aarch64" || die "not aarch64"
readelf -h "$B" | grep -q "Type:.*EXEC" || die "not ET_EXEC"
if readelf -l "$B" | grep -q INTERP; then die "has a program interpreter"; fi
if readelf -d "$B" 2>/dev/null | grep -q NEEDED; then die "has dynamic dependencies"; fi
cmp -s "$B" "$OUT/fs-pattern.rebuild" || die "build is not reproducible"
rm -f "$OUT/fs-pattern.rebuild"

{
echo "fs-pattern build record"
echo "date_utc:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "compiler:   $("$CLANG" --version | head -1)"
echo "command:    $CLANG $CFLAGS $LDFLAGS -o build/fs-pattern src/fs-pattern.c" | tr -s ' '
echo "source:     src/fs-pattern.c sha256=$(sha "$HERE/src/fs-pattern.c")"
echo "uapi:       $UAPI/drm.h sha256=$(sha "$UAPI/drm.h")"
echo "uapi:       $UAPI/drm_mode.h sha256=$(sha "$UAPI/drm_mode.h")"
echo "libc:       $(dpkg-query -W -f='${Package} ${Version}' libc6-dev-arm64-cross 2>/dev/null || echo unknown) (static glibc)"
echo "libc.a:     $LIBC_A sha256=$(sha "$LIBC_A")"
echo "binary:     build/fs-pattern sha256=$(sha "$B") size=$(stat -c %s "$B")"
echo "elf:        $(file -b "$B")"
echo "checks:     aarch64, ET_EXEC, no INTERP, no NEEDED, bit-identical rebuild"
echo "unittest:   build/fs-pattern-unittest sha256=$(sha "$OUT/fs-pattern-unittest") (-DFSP_UNIT_TEST; offline only, never in an image)"
echo "control:    build/fs-pattern-unittest-maxmodes128 sha256=$(sha "$OUT/fs-pattern-unittest-maxmodes128") (-DFSP_UNIT_TEST, MAXMODES 128 = v0.7's limit; offline only)"
} | tee "$OUT/BUILD.txt"
