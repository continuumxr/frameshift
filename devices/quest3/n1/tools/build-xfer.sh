#!/bin/bash
# FrameShift N1 — build fs-xfer (static aarch64), the N1 transfer-test responder. Run inside WSL:
#   wsl.exe -e bash <checkout>/devices/quest3/n1/tools/build-xfer.sh
# Offline only: builds and inspects a binary; touches no device. Same compiler, flags and static checks as
# devices/quest3/common/tools/build.sh (fs-supervise): the AOSP clang r450784e, -static, glibc of
# libc6-dev-arm64-cross; plus a native build (gcc) of the same source for the fixtures that need the host kernel.
# Writes <n1>/build/fs-xfer (gitignored; pinned by sha256 in n1/build-image.sh) and n1/build-record/BUILD-xfer.txt.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CLANG=$HOME/toolchains/clang-r450784e/bin/clang
SRC=$HERE/src/fs-xfer.c
OUT=$HERE/build
REC=$HERE/build-record
mkdir -p "$OUT" "$REC"
die() { echo "BUILD FAILED: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -c1-64; }
[ -x "$CLANG" ] || die "clang missing ($CLANG)"
[ "$(tr -cd '\r' < "$SRC" | wc -c)" -eq 0 ] || die "CR characters in $SRC"

CFLAGS="--target=aarch64-linux-gnu -static -O2 -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -fno-ident"
build() {  # build <output>
    # shellcheck disable=SC2086
    "$CLANG" $CFLAGS -fuse-ld=lld -Wl,--build-id=none -s -o "$1" "$SRC"
}
build "$OUT/fs-xfer"
build "$OUT/fs-xfer.rebuild"
B=$OUT/fs-xfer
file -b "$B" | grep -q "ARM aarch64" || die "not aarch64"
readelf -h "$B" | grep -q "Type:.*EXEC" || die "not ET_EXEC"
if readelf -l "$B" | grep -q INTERP; then die "has a program interpreter"; fi
if readelf -d "$B" 2>/dev/null | grep -q NEEDED; then die "has dynamic dependencies"; fi
cmp -s "$B" "$OUT/fs-xfer.rebuild" || die "build is not reproducible"
rm -f "$OUT/fs-xfer.rebuild"
# the compiled-in limits must be the reviewed ones (tools/check-bounds-n1.py reads the same lines)
for c in "H2D_BYTES   8388608u" "D2H_BYTES   8388608u" "LISTEN_MS   10000" "SESSION_MS  12000" "HEADER_MS   2000" \
         "DRAIN_MS    1000" "DRAIN_MAX   65536" "MAX_REJECTS 4" "BACKSTOP_S  25"; do
    grep -q "^#define $c\b" "$SRC" || die "limit changed: $c"
done
# no exec, fork, file writes or shell from fs-xfer's own code (source scan; static glibc still links its own internals)
if grep -vE '^\s*(\*|/\*|//)' "$SRC" | grep -Eq '\b(execve|execv|execl|execvp|system|popen|posix_spawn|fork|vfork|clone|open|openat|fopen|creat|unlink|rename|mkdir)\s*\('; then
    die "fs-xfer source calls exec/fork/open/file-writing functions"
fi
# the native twin (host kernel fixtures only: veth link-local, loopback); never packaged
gcc -O2 -std=c11 -D_GNU_SOURCE -DFSX_FIXTURE -Wall -Wextra -Werror -o "$OUT/fs-xfer.native" "$SRC"
{
echo "fs-xfer build record"
echo "date_utc:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "compiler:   $("$CLANG" --version | head -1)"
echo "command:    $CLANG $CFLAGS -fuse-ld=lld -Wl,--build-id=none -s -o build/fs-xfer src/fs-xfer.c" | tr -s ' '
echo "source:     src/fs-xfer.c sha256=$(sha "$SRC")"
echo "libc:       $(dpkg-query -W -f='${Package} ${Version}' libc6-dev-arm64-cross 2>/dev/null || echo unknown) (static glibc)"
echo "binary:     build/fs-xfer sha256=$(sha "$B") size=$(stat -c %s "$B")"
echo "elf:        $(file -b "$B")"
echo "limits:     h2d=d2h=8388608 bytes; listen 10 s (bind retried on EADDRNOTAVAIL, then the accept), session 12 s, header 2 s, drain 1 s / 64 KiB, 4 rejects, backstop alarm 25 s"
echo "checks:     aarch64, ET_EXEC, no INTERP, no NEEDED, bit-identical rebuild, limits unchanged, no exec/fork/open in the source"
echo "native:     build/fs-xfer.native (gcc $(gcc -dumpfullversion), -DFSX_FIXTURE: the ::1 mode; fixtures only, never packaged) sha256=$(sha "$OUT/fs-xfer.native")"
} | tee "$REC/BUILD-xfer.txt"
