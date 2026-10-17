#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# fs-thermald / fs-metacfg (parts 1 and 2): offline builds. Run inside WSL:
#   bash devices/thermal/tools/build.sh OUT_DIR
# Native test builds (gcc) for the suites, and static aarch64 builds with the
# project's pinned clang r450784e (as devices/quest3/common/tools/build.sh),
# checked like the stage binaries (aarch64, ET_EXEC, no INTERP, no NEEDED,
# bit-identical rebuild). The aarch64 builds are artifacts for qemu-user
# tests only: part 1 builds no image and nothing here runs on a device.
set -euo pipefail
OUT=${1:?out dir}
HERE=$(cd "$(dirname "$0")/.." && pwd)
S=$HERE/src
mkdir -p "$OUT"
die() { echo "BUILD FAILED: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -c1-64; }

W="-O2 -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wno-format-truncation"
MC="$S/fs-metacfg.c $S/sha256.c"
TD="$S/fs-thermald.c $S/thermald_core.c $S/thermald_accept.c $S/thermald_tables.c $S/thermald_exec.c $S/fst_record.c $S/sha256.c"

# ---- native (x86_64) for the suites ----
gcc $W -DFS_TEST -o "$OUT/fs-metacfg-test" $MC
gcc $W -o "$OUT/fs-metacfg" $MC
gcc $W -DFS_TEST -o "$OUT/fs-thermald" $TD
gcc $W -DFS_TEST -DFS_LOGONLY -o "$OUT/fs-thermald-logonly-test" $TD
gcc -O2 -Wall -Wextra -Werror -o "$OUT/fakehelper" "$HERE/tools/testprogs/fakehelper.c"
gcc -O2 -Wall -Wextra -Werror -o "$OUT/fakepid1" "$HERE/tools/testprogs/fakepid1.c"
gcc -O2 -Wall -Wextra -Werror -o "$OUT/stepgroup" "$HERE/tools/testprogs/stepgroup.c"
gcc -O2 -Wall -Wextra -Werror -o "$OUT/guardhb" "$HERE/tools/testprogs/guardhb.c"
for c in fs-noticed fs-thermald-watch; do
    [ -f "$S/$c.c" ] && gcc $W -DFS_TEST -o "$OUT/$c-test" "$S/$c.c" $S/fst_record.c ${WS_EXTRA:-}
done

# ---- static aarch64, pinned clang ----
CLANG=$HOME/toolchains/clang-r450784e/bin/clang
[ -x "$CLANG" ] || die "clang r450784e missing"
CF="--target=aarch64-linux-gnu -static -fuse-ld=lld -Wl,--build-id=none -s -fno-ident -O2 -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror"
a64() { # name defines sources...
    local n=$1 d=$2; shift 2
    # shellcheck disable=SC2086
    "$CLANG" $CF $d -o "$OUT/$n.a64" "$@"
    # shellcheck disable=SC2086
    "$CLANG" $CF $d -o "$OUT/$n.a64.rebuild" "$@"
    cmp -s "$OUT/$n.a64" "$OUT/$n.a64.rebuild" || die "$n not reproducible"
    rm -f "$OUT/$n.a64.rebuild"
    file -b "$OUT/$n.a64" | grep -q "ARM aarch64" || die "$n not aarch64"
    readelf -h "$OUT/$n.a64" | grep -q "Type:.*EXEC" || die "$n not ET_EXEC"
    if readelf -l "$OUT/$n.a64" | grep -q INTERP; then die "$n has an interpreter"; fi
    if readelf -d "$OUT/$n.a64" 2>/dev/null | grep -q NEEDED; then die "$n has dynamic dependencies"; fi
}
a64 fs-metacfg "" $MC
a64 fs-metacfg-test -DFS_TEST $MC
a64 fs-thermald-sim -DFS_TEST $TD
# part 2 device builds (EXEC-SPEC §7): product, trial (adds the override flags), T1 log-only
a64 fs-thermald -DFS_DEVICE $TD
a64 fs-thermald-trial "-DFS_DEVICE -DFS_TRIAL" $TD
a64 fs-thermald-logonly "-DFS_DEVICE -DFS_LOGONLY" $TD
a64 fs-thermald-logonly-trial "-DFS_DEVICE -DFS_LOGONLY -DFS_TRIAL" $TD   # T1 (--stage --trial-override --batt-absent)
for c in fs-noticed fs-thermald-watch; do
    [ -f "$S/$c.c" ] && a64 "$c" -DFS_DEVICE "$S/$c.c" $S/fst_record.c
done
bash "$HERE/tools/build_warnscreen.sh" "$OUT" > "$OUT/warnscreen.txt"
# fs-poweroff-final: freestanding, never exits (PID 1 execs it on TRIP / a gate refusal)
FFLAGS="--target=aarch64-linux-gnu -Os -static -nostdlib -ffreestanding -fno-stack-protector -fno-ident -Wall -Wextra -Werror -fuse-ld=lld -Wl,--build-id=none -s"
# shellcheck disable=SC2086
"$CLANG" $FFLAGS -o "$OUT/fs-poweroff-final.a64" "$S/fs-poweroff-final.c"
# shellcheck disable=SC2086
"$CLANG" $FFLAGS -o "$OUT/fs-poweroff-final.rebuild" "$S/fs-poweroff-final.c"
cmp -s "$OUT/fs-poweroff-final.a64" "$OUT/fs-poweroff-final.rebuild" || die "fs-poweroff-final not reproducible"
rm -f "$OUT/fs-poweroff-final.rebuild"
grep -Eq 'SYS_exit|exit\(' "$S/fs-poweroff-final.c" "$S/poweroff_final.h" && die "fs-poweroff-final source mentions exit"
"$(dirname "$CLANG")/llvm-objdump" -d "$OUT/fs-poweroff-final.a64" > "$OUT/fs-poweroff-final.dis"
python3 -I "$HERE/tools/check_poweroff.py" "$OUT/fs-poweroff-final.a64" "$OUT/fs-poweroff-final.dis" || die "fs-poweroff-final check failed"
# no printable string beyond the linker comment and section names
if strings -a -n 4 "$OUT/fs-poweroff-final.a64" | grep -vxE 'Linker: LLD [0-9.]+|\.rodata|\.text|\.comment|\.shstrtab' | grep -q .; then
    die "fs-poweroff-final carries a string"
fi
strings -a "$OUT/fs-metacfg.a64" > "$OUT/strings.tmp"
for s in --root --allow-regular --seccomp-optional --uevent-sock --seccomp-selftest; do
    if grep -q -- "$s" "$OUT/strings.tmp"; then die "production fs-metacfg contains test option $s"; fi
done
strings -a "$OUT/fs-thermald-sim.a64" > "$OUT/strings.tmp"
grep -q "test build (simulation and exec-sim), no device mode" "$OUT/strings.tmp" || die "sim banner missing"
# EXEC-SPEC §7 build-time exclusions
strings -a "$OUT/fs-thermald.a64" > "$OUT/strings.tmp"
for s in --trial-override --batt-absent --sim --test-pid1 "--root " --test-row --fst-scan "!HANG" "!EIO"; do
    if grep -qF -- "$s" "$OUT/strings.tmp"; then die "product fs-thermald contains $s"; fi
done
grep -q "device build" "$OUT/strings.tmp" || die "device banner missing"
strings -a "$OUT/fs-thermald-trial.a64" > "$OUT/strings2.tmp"; grep -q -- --trial-override "$OUT/strings2.tmp" || die "trial build lacks --trial-override"; rm -f "$OUT/strings2.tmp"
strings -a "$OUT/fs-thermald-logonly.a64" > "$OUT/strings.tmp"
for s in /dev/watchdog /proc/sysrq-trigger /dev/pmsg0 --trial-override; do
    if grep -qF -- "$s" "$OUT/strings.tmp"; then die "log-only fs-thermald contains $s"; fi
done
grep -q "device log-only build" "$OUT/strings.tmp" || die "log-only banner missing"
rm -f "$OUT/strings.tmp"

{
echo "fs-thermald / fs-metacfg build record, parts 1 and 2 (no image is built here; nothing here runs on a device)"
echo "compiler: $("$CLANG" --version | head -1)"
echo "libc:     $(dpkg-query -W -f='${Package} ${Version}' libc6-dev-arm64-cross 2>/dev/null || echo unknown) (static glibc)"
for f in fs-metacfg.c fs-thermald.c thermald_core.c thermald_accept.c thermald_tables.c thermald_exec.c fst_record.c fs-poweroff-final.c sha256.c sha256.h thermald.h thermald_accept.h thermald_exec.h fst_record.h poweroff_final.h metacfg_record.h fs-noticed.c fs-warnscreen.c fs-thermald-watch.c; do
    [ -f "$S/$f" ] || continue
    echo "source:   src/$f sha256=$(sha "$S/$f")"
done
for b in fs-metacfg fs-metacfg-test fs-thermald-sim fs-thermald fs-thermald-trial fs-thermald-logonly fs-thermald-logonly-trial fs-poweroff-final fs-noticed fs-warnscreen fs-thermald-watch; do
    [ -f "$OUT/$b.a64" ] || continue
    echo "binary:   $b.a64 sha256=$(sha "$OUT/$b.a64") size=$(stat -c %s "$OUT/$b.a64")"
done
echo "checks:   aarch64, ET_EXEC, no INTERP, no NEEDED, bit-identical rebuild; production fs-metacfg has no test option string;"
echo "          product fs-thermald has no test/trial option; log-only has no softdog/sysrq/pmsg path; fs-poweroff-final: 3 syscalls checked"
} > "$OUT/BUILD.txt"
cat "$OUT/BUILD.txt"
