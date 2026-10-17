#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# fs-warnscreen = fs-pattern v0.7.1 (stage 3d, pinned by hash) + src/warnscreen/warn.patch
# (main -> fsp_main, the picture -> warn_frame.h, main = warn_main.h). Every DRM step is
# fs-pattern's own. Builds the native test binary (offline frame fixtures) and the static
# aarch64 binary. Offline only.   bash tools/build_warnscreen.sh OUT_DIR
set -euo pipefail
OUT=${1:?out dir}
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SRC=$REPO/devices/quest3/stage3d/src/fs-pattern.c
PIN_IN=99fc131b4c68fac12bedaa5585d7381e65ef4f6509b8462879decee8cd99e7c2
PIN_OUT=300b035d22f1ec2a9218da1a0cc903670c4d87c037096fba51aaff58b1db967e
UAPI=$HOME/work/kgate27/src/include/uapi/drm
CLANG=$HOME/toolchains/clang-r450784e/bin/clang
die() { echo "BUILD FAILED (warnscreen): $*" >&2; exit 1; }
[ "$(sha256sum "$SRC" | cut -c1-64)" = "$PIN_IN" ] || die "fs-pattern.c is not v0.7.1 ($PIN_IN)"
[ -f "$UAPI/drm.h" ] || die "v2.7 uapi headers missing"
W=$OUT/warnscreen-src
rm -rf "$W"; mkdir -p "$W"
cp "$SRC" "$W/fs-warnscreen.c"
patch -s --no-backup-if-mismatch -d "$W" fs-warnscreen.c < "$HERE/src/warnscreen/warn.patch" || die "patch does not apply"
[ "$(sha256sum "$W/fs-warnscreen.c" | cut -c1-64)" = "$PIN_OUT" ] || die "patched source differs from the reviewed result ($PIN_OUT)"
cp "$HERE/src/warnscreen/warn_frame.h" "$HERE/src/warnscreen/warn_main.h" "$W/"
mkdir -p "$W/../warnscreen-inc"
CF="-O2 -std=c11 -D_GNU_SOURCE -D__user= -DFSP_WARNSCREEN -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-unused-function -I$UAPI -I$W -I$HERE/src"
# shellcheck disable=SC2086
gcc $CF -Wno-format-truncation -o "$OUT/fs-warnscreen-test" "$W/fs-warnscreen.c" "$HERE/src/fst_record.c"
A="--target=aarch64-linux-gnu -static -fuse-ld=lld -Wl,--build-id=none -s -fno-ident"
# shellcheck disable=SC2086
"$CLANG" $A $CF -o "$OUT/fs-warnscreen.a64" "$W/fs-warnscreen.c" "$HERE/src/fst_record.c"
# shellcheck disable=SC2086
"$CLANG" $A $CF -o "$OUT/fs-warnscreen.a64.rebuild" "$W/fs-warnscreen.c" "$HERE/src/fst_record.c"
cmp -s "$OUT/fs-warnscreen.a64" "$OUT/fs-warnscreen.a64.rebuild" || die "not reproducible"
rm -f "$OUT/fs-warnscreen.a64.rebuild"
readelf -h "$OUT/fs-warnscreen.a64" | grep -q "Type:.*EXEC" || die "not ET_EXEC"
if readelf -l "$OUT/fs-warnscreen.a64" | grep -q INTERP; then die "has an interpreter"; fi
echo "fs-warnscreen: fs-pattern.c $PIN_IN + warn.patch -> $PIN_OUT; a64 sha256=$(sha256sum "$OUT/fs-warnscreen.a64" | cut -c1-64)"
