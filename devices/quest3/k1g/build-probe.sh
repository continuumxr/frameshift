#!/bin/bash
# K1g: build the device probe (tools/blkguard/probe/fsbg-probe.c) as a static aarch64 executable, reproducibly
# (static glibc, fixed flags, no build id or timestamp in the binary), and check it against the pin the image
# builder uses (build-image-k1g.sh EXPECT_FSBG_PROBE). Offline; run in WSL.
# Usage: build-probe.sh [<out file>]   (default $FS_INPUT_ROOT/build/k1g/probe/fsbg-probe, gitignored)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
ROOT=${FS_INPUT_ROOT:-<repo>}
SRC=$REPO/tools/blkguard/probe/fsbg-probe.c
OUT=${1:-$ROOT/build/k1g/probe/fsbg-probe}
CC=aarch64-linux-gnu-gcc
mkdir -p "$(dirname "$OUT")"
echo "source:   $SRC sha256 $(sha256sum < "$SRC" | cut -c1-64)"
# pinned toolchain (review: recorded AND checked): the cross gcc and the static glibc it links
EXPECT_CC='aarch64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0'
EXPECT_GLIBC='2.43-2ubuntu2cross1'
got_cc=$($CC --version | head -1); got_glibc=$(dpkg-query -W -f='${Version}' libc6-dev-arm64-cross 2>/dev/null || echo unknown)
echo "compiler: $got_cc; glibc (aarch64 cross) $got_glibc"
[ "$got_cc" = "$EXPECT_CC" ] || { echo "REFUSED: compiler is not the pinned '$EXPECT_CC'"; exit 1; }
[ "$got_glibc" = "$EXPECT_GLIBC" ] || { echo "REFUSED: libc6-dev-arm64-cross is not the pinned $EXPECT_GLIBC"; exit 1; }
cd "$(dirname "$SRC")"
$CC -static -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-format-truncation \
    -ffile-prefix-map="$(pwd)"=. -Wl,--build-id=none -o "$OUT.tmp" fsbg-probe.c
mv "$OUT.tmp" "$OUT"
echo "binary:   $OUT sha256 $(sha256sum < "$OUT" | cut -c1-64) size $(stat -c %s "$OUT")"
pin=$(sed -n 's/^EXPECT_FSBG_PROBE=\([0-9a-f]\{64\}\).*$/\1/p' "$HERE/build-image-k1g.sh" 2>/dev/null || true)
if [ -n "$pin" ]; then
    [ "$(sha256sum < "$OUT" | cut -c1-64)" = "$pin" ] && echo "PIN OK (build-image-k1g.sh EXPECT_FSBG_PROBE)" || { echo "PIN DIFFERS from build-image-k1g.sh ($pin)"; exit 1; }
fi
