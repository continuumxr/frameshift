#!/bin/bash
# FrameShift stage 3a — negative fixtures for build-image.sh (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/stage3a/test-builder.sh
# Each case points ONE input elsewhere through the builder's FS_TEST_* variables
# and requires: a nonzero exit, the expected "BUILD REFUSED: ..." reason, and
# nothing published (the case's own FS_TEST_OUTBASE stays empty). Tampered
# copies live only in WSL scratch (~/work/fsbuild-neg).
# The positive build is build-image.sh itself (IMAGE.md records its MANIFEST).
# E1 (the AOSP checkout) has its own regression fixtures in
# devices/quest3/host/fixtures/gitcheck/ (the builder sources that helper).
# Writes fixtures/builder/RESULTS.txt.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
HERE=$ROOT/devices/quest3/stage3a
B=$HERE/build-image.sh
for _in in "$ROOT/build/third_party/busybox/busybox" "$ROOT/build/third_party/mkbootimg" "$ROOT/firmware/quest3"; do
    [ -e "$_in" ] || { echo "REFUSED: build input missing: $_in (gitignored; see README \"What is not in git\")" >&2; exit 2; }
done
FX=$HERE/fixtures/builder
S=$HOME/work/fsbuild-neg/stage3a
rm -rf "$S" "$FX"; mkdir -p "$S" "$FX"
R=$FX/RESULTS.txt
echo "# stage3a builder negatives  $(date -u +%Y-%m-%dT%H:%M:%SZ); build-image.sh sha256=$(sha256sum "$B" | cut -c1-64)" > "$R"

flip() { python3 -I -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[0x2000]^=1; open(p,"wb").write(b)' "$1"; }

fail=0; n=0
case_() {   # case_ NAME EXPECTED-REASON-REGEX VAR=VALUE...
    local name=$1 want=$2; shift 2
    local o=$S/out-$name; mkdir -p "$o"
    n=$((n + 1))
    env "$@" FS_TEST_OUTBASE="$o" bash "$B" > "$FX/$name.log" 2>&1; local rc=$?
    local why; why=$(grep -m1 '^BUILD REFUSED' "$FX/$name.log" || true)
    local left; left=$(find "$o" -mindepth 1 | wc -l)
    if [ $rc -ne 0 ] && printf '%s\n' "$why" | grep -Eq "$want" && [ "$left" -eq 0 ]; then
        echo "PASS  $name  rc=$rc  $why" | tee -a "$R"
    else
        echo "FAIL  $name  rc=$rc  published=$left  $why (wanted /$want/)" | tee -a "$R"; fail=$((fail + 1))
    fi
}

cp "$HERE/build/fs-pattern" "$S/fs-pattern"; flip "$S/fs-pattern"
case_ fs-pattern-tampered 'fs-pattern hash differs from the pin' FS_TEST_FS_PATTERN="$S/fs-pattern"

case_ fs-pattern-missing 'input missing or not a regular file: /nonexistent/fs-pattern' FS_TEST_FS_PATTERN=/nonexistent/fs-pattern

cp "$ROOT/build/third_party/busybox/busybox" "$S/busybox"; printf '\0' >> "$S/busybox"
case_ busybox-tampered 'busybox hash differs from the pin' FS_TEST_BUSYBOX="$S/busybox"

case_ fs-supervise-missing 'input missing or not a regular file: /nonexistent/fs-supervise' FS_TEST_FS_SUPERVISE=/nonexistent/fs-supervise

cp "$ROOT/devices/quest3/common/build/fs-reboot-final" "$S/fs-reboot-final"; flip "$S/fs-reboot-final" 2>/dev/null || printf 'x' >> "$S/fs-reboot-final"
case_ fs-reboot-final-tampered 'fs-reboot-final hash differs from the pin' FS_TEST_FS_REBOOT_FINAL="$S/fs-reboot-final"

cp "$ROOT/build/stage1-tools/fs-reboot" "$S/fs-reboot"; printf 'x' >> "$S/fs-reboot"
case_ fs-reboot-tampered 'fs-reboot hash differs from the pin' FS_TEST_FS_REBOOT="$S/fs-reboot"

case_ stock-boot-wrong 'stock boot hash differs from the pin' FS_TEST_STOCK_BOOT="$ROOT/firmware/quest3/v66_unit1_slotA/vendor_boot.img"

# N5 (fix round 6): an extra file injected into the staged ramdisk is refused by the exact-list check
printf 'injected\n' > "$S/inject.txt"
case_ inject-extra-file 'ramdisk contents differ from the expected list' FS_TEST_INJECT="$S/inject.txt:etc/ld.so.preload"

# N1 (fix round 6): reproducibility. Two builds with the same nonce and stamp must give a
# bit-identical image (cpio --reproducible, fixed mtimes, deterministic lz4/mkbootimg).
n=$((n + 1))
for k in 1 2; do
    env FS_TEST_NONCE=0123456789abcdef FS_TEST_STAMP=20260101T000000Z FS_TEST_OUTBASE="$S/repro$k" bash "$B" > "$FX/repro-$k.log" 2>&1
done
h1=$(sha256sum "$S"/repro1/*/boot-*.img 2>/dev/null | cut -c1-64); h2=$(sha256sum "$S"/repro2/*/boot-*.img 2>/dev/null | cut -c1-64)
c1=$(grep -m1 '^ramdisk.cpio' "$S"/repro1/*/MANIFEST.txt 2>/dev/null); c2=$(grep -m1 '^ramdisk.cpio' "$S"/repro2/*/MANIFEST.txt 2>/dev/null)
if [ -n "$h1" ] && [ "$h1" = "$h2" ] && [ -n "$c1" ] && [ "$c1" = "$c2" ]; then
    echo "PASS  repro-same-nonce  two builds, nonce 0123456789abcdef: image $h1 both times; $c1" | tee -a "$R"
else
    echo "FAIL  repro-same-nonce  image '$h1' vs '$h2'; cpio '$c1' vs '$c2'" | tee -a "$R"; fail=$((fail + 1))
fi

rm -rf "$S"
echo "TOTAL: $n cases, $fail failed" | tee -a "$R"
[ $fail -eq 0 ]
