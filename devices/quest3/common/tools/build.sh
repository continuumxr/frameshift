#!/bin/bash
# FrameShift common — build fs-supervise (static aarch64). Run inside WSL:
#   wsl.exe -e bash <repo>/devices/quest3/common/tools/build.sh
# Offline only: builds and inspects a binary; touches no device.
# Same compiler, flags and static checks as stage3a/tools/build.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest3/common
CLANG=$HOME/toolchains/clang-r450784e/bin/clang
OUT=$HERE/build
mkdir -p "$OUT"

die() { echo "BUILD FAILED: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -c1-64; }
[ -x "$CLANG" ] || die "clang missing"

CFLAGS="--target=aarch64-linux-gnu -static -O2 -std=c11 -D_GNU_SOURCE \
 -Wall -Wextra -Werror -fno-ident"

build() {  # build <output>
    # shellcheck disable=SC2086
    "$CLANG" $CFLAGS -fuse-ld=lld -Wl,--build-id=none -s -o "$1" "$HERE/src/fs-supervise.c"
}
build "$OUT/fs-supervise"
build "$OUT/fs-supervise.rebuild"          # reproducibility check

B=$OUT/fs-supervise
file -b "$B" | grep -q "ARM aarch64" || die "not aarch64"
readelf -h "$B" | grep -q "Type:.*EXEC" || die "not ET_EXEC"
if readelf -l "$B" | grep -q INTERP; then die "has a program interpreter"; fi
if readelf -d "$B" 2>/dev/null | grep -q NEEDED; then die "has dynamic dependencies"; fi
cmp -s "$B" "$OUT/fs-supervise.rebuild" || die "build is not reproducible"
rm -f "$OUT/fs-supervise.rebuild"
# the compiled-in limits must be the reviewed ones
for c in "MAX_TIMEOUT_S     60" "MAX_GRACE_S       10" "MAX_CAP          (1024 \* 1024)"; do
    grep -q "^#define $c" "$HERE/src/fs-supervise.c" || die "limit changed: $c"
done

# ---- fs-reboot-final: freestanding, never exits (PID 1 execs it) ----
FFLAGS="--target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector -fno-ident -Wall -Wextra -Werror"
# shellcheck disable=SC2086
"$CLANG" $FFLAGS -fuse-ld=lld -Wl,--build-id=none -s -o "$OUT/fs-reboot-final" "$HERE/src/fs-reboot-final.c"
# shellcheck disable=SC2086
"$CLANG" $FFLAGS -fuse-ld=lld -Wl,--build-id=none -s -o "$OUT/fs-reboot-final.rebuild" "$HERE/src/fs-reboot-final.c"
F=$OUT/fs-reboot-final
cmp -s "$F" "$OUT/fs-reboot-final.rebuild" || die "fs-reboot-final not reproducible"
rm -f "$OUT/fs-reboot-final.rebuild"
file -b "$F" | grep -q "ARM aarch64" || die "fs-reboot-final not aarch64"
if readelf -l "$F" | grep -q INTERP; then die "fs-reboot-final has an interpreter"; fi
grep -Eq 'SYS_exit|exit\(' "$HERE/src/fs-reboot-final.c" && die "fs-reboot-final source mentions exit"
# the only printable mode string is "bootloader"
for s in edl recovery fastboot rescue; do strings -a "$F" | grep -qx "$s" && die "unexpected mode string $s"; done
strings -a "$F" | grep -qx bootloader || die "bootloader string missing"
# no exit/exit_group syscall: no 'mov w8/x8, #93|#94' anywhere in the code
llvm_objdump=$(dirname "$CLANG")/llvm-objdump
if [ -x "$llvm_objdump" ]; then
    "$llvm_objdump" -d "$F" > "$OUT/fs-reboot-final.dis"
    grep -Eq 'mov[[:space:]]+[wx]8, #0x5[de]\b|mov[[:space:]]+[wx]8, #9[34]\b' "$OUT/fs-reboot-final.dis" && die "fs-reboot-final contains an exit syscall number"
    # exactly three syscalls, numbers 142 (reboot), 142 (reboot), 101 (nanosleep), in that order
    [ "$(grep -c 'svc' "$OUT/fs-reboot-final.dis")" = 3 ] || die "fs-reboot-final: not exactly 3 syscalls"
    [ "$(grep -Eo 'mov[[:space:]]+w8, #[0-9]+' "$OUT/fs-reboot-final.dis" | grep -Eo '[0-9]+$' | tr '
' ' ')" = "142 142 101 " ]         || die "fs-reboot-final: syscall sequence is not reboot, reboot, nanosleep"
    # full argument proof (magics, commands, the "bootloader\0" pointer, {3600,0}, closed loop)
    python3 -I "$HERE/tools/check_final.py" "$F" "$OUT/fs-reboot-final.dis" "$OUT/fs-reboot-final.layout" > "$OUT/fs-reboot-final.check" \
        || { cat "$OUT/fs-reboot-final.check"; die "fs-reboot-final: argument check failed"; }
else
    die "llvm-objdump missing: cannot verify fs-reboot-final"
fi

{
echo "fs-supervise build record"
echo "date_utc:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "compiler:   $("$CLANG" --version | head -1)"
echo "command:    $CLANG $CFLAGS -fuse-ld=lld -Wl,--build-id=none -s -o build/fs-supervise src/fs-supervise.c" | tr -s ' '
echo "source:     src/fs-supervise.c sha256=$(sha "$HERE/src/fs-supervise.c")"
echo "libc:       $(dpkg-query -W -f='${Package} ${Version}' libc6-dev-arm64-cross 2>/dev/null || echo unknown) (static glibc)"
echo "binary:     build/fs-supervise sha256=$(sha "$B") size=$(stat -c %s "$B")"
echo "elf:        $(file -b "$B")"
echo "limits:     timeout<=60s grace<=10s (default 2) cap<=1MiB (default 64KiB) reap-wait 3s backstop alarm 90s"
echo "checks:     aarch64, ET_EXEC, no INTERP, no NEEDED, bit-identical rebuild, limits unchanged"
echo "final:      src/fs-reboot-final.c sha256=$(sha "$HERE/src/fs-reboot-final.c")"
echo "final:      build/fs-reboot-final sha256=$(sha "$F") size=$(stat -c %s "$F") ($FFLAGS)"
echo "final chk:  aarch64, no INTERP, bit-identical rebuild, no exit in source or code, only mode string 'bootloader'; check_final.py: reboot(0xfee1dead,0x28121969,0xa1b2c3d4,&\"bootloader\0\"), reboot(...,0x01234567,0), nanosleep(&{3600,0}) in a closed loop, exactly 3 svc"
} | tee "$OUT/BUILD.txt"
