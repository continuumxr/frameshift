#!/bin/bash
# FrameShift stage 3d — negative fixtures for build-image.sh (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/stage3d/test-builder.sh [CANDIDATE_DIR]
# Derived from stage3c/test-builder.sh (unchanged). Stage 3d adds the v2.7 provenance cases (v66 boot,
# vendor_boot or vbmeta given instead of the pinned v2.7 files) and the stage-3c fs-pattern binary (v0.6).
# Each case points ONE input elsewhere through the builder's FS_TEST_* variables
# and requires: a nonzero exit, the expected "BUILD REFUSED: ..." reason, and
# nothing published (the case's own FS_TEST_OUTBASE stays empty). Tampered
# copies live only in WSL scratch (~/work/fsbuild-neg).
# The positive build is build-image.sh itself (IMAGE.md records its MANIFEST).
# E1 (the AOSP checkout) has its own regression fixtures in
# devices/quest3/host/fixtures/gitcheck/ (the builder sources that helper).
# With CANDIDATE_DIR (a build/stage3d/<UTC>-<nonce>/ directory), the candidate is also rebuilt with its own
# nonce and stamp and must give a bit-identical image and cpio (fixtures/builder/candidate-rebuild.txt).
# Writes fixtures/builder/RESULTS.txt.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
HERE=$ROOT/devices/quest3/stage3d
B=$HERE/build-image.sh
FX=$HERE/fixtures/builder
S=$HOME/work/fsbuild-neg/stage3d
rm -rf "${S:?}" "${FX:?}"; mkdir -p "$S" "$FX"
R=$FX/RESULTS.txt
echo "# stage3d builder negatives  $(date -u +%Y-%m-%dT%H:%M:%SZ); build-image.sh sha256=$(sha256sum "$B" | cut -c1-64)" > "$R"

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

cp "$ROOT/devices/quest3/common/target/fsb1-pace.sh" "$S/fsb1-pace.sh"; echo "# x" >> "$S/fsb1-pace.sh"
case_ fsb1-pace-tampered 'common fsb1-pace.sh hash differs from the pin' FS_TEST_FSB1_PACE="$S/fsb1-pace.sh"

case_ stock-boot-wrong 'AVB check' FS_TEST_STOCK_BOOT="$ROOT/firmware/quest3/v66_unit1_slotA/vendor_boot.img"
# stage 3d: the v66 files of Unit 1 instead of Unit 2's v2.7 files
case_ stock-boot-v66 'AVB check' FS_TEST_STOCK_BOOT="$ROOT/firmware/quest3/v66_unit1_slotA/boot.img"
case_ stock-vboot-v66 'AVB check' FS_TEST_STOCK_VBOOT="$ROOT/firmware/quest3/v66_unit1_slotA/vendor_boot.img"
case_ vbmeta-v66 'vbmeta hash differs from the pin' FS_TEST_VBMETA="$ROOT/firmware/quest3/v66_unit1_slotA/vbmeta.img"
case_ fs-pattern-v06 'fs-pattern hash differs from the pin' FS_TEST_FS_PATTERN="$ROOT/devices/quest3/stage3c/build/fs-pattern"

# stage 3c (PM decision J-109 #2): a script with a debugfs mount is refused
cp "$HERE/fs-idle.sh" "$S/fs-idle.sh"; printf 'mount -t debugfs none /sys/kernel/debug
' >> "$S/fs-idle.sh"
case_ fs-idle-debugfs-mount 'debugfs in a non-comment line of' FS_TEST_IDLE="$S/fs-idle.sh"

# build review (R-B helper, mutations 7a-7c): debugfs mounts hidden from the lexical word check are refused by the
# mount whitelist (quoted, through variables, through an octal escape); and a tty write in fs-idle.sh (mutation 6)
cp "$HERE/fs-idle.sh" "$S/fs-idle-q.sh"; printf '%s\n' "\$BB mount -t debug''fs none /sys/kernel/debu''g" >> "$S/fs-idle-q.sh"
case_ fs-idle-debugfs-quoted 'mount line not in the reviewed whitelist' FS_TEST_IDLE="$S/fs-idle-q.sh"
cp "$HERE/fs-idle.sh" "$S/fs-idle-v.sh"; printf '%s\n' 'K=/sys/kernel; F=fs; $BB mount -t debug$F none $K/debug' >> "$S/fs-idle-v.sh"
case_ fs-idle-debugfs-variables 'mount line not in the reviewed whitelist' FS_TEST_IDLE="$S/fs-idle-v.sh"
cp "$HERE/fs-idle.sh" "$S/fs-idle-o.sh"; printf '%s\n' '$BB mount -t "$(printf "\144ebugfs")" none /sys/./kernel/debug' >> "$S/fs-idle-o.sh"
case_ fs-idle-debugfs-octal 'mount line not in the reviewed whitelist' FS_TEST_IDLE="$S/fs-idle-o.sh"
cp "$HERE/fs-idle.sh" "$S/fs-idle-t.sh"; printf '%s\n' "printf 'FS-IDLE fired\\n' > /dev/ttyGS0" >> "$S/fs-idle-t.sh"
case_ fs-idle-tty-write 'fs-idle.sh names a tty or the console' FS_TEST_IDLE="$S/fs-idle-t.sh"

# N5 (fix round 6): an extra file injected into the staged ramdisk is refused by the exact-list check
printf 'injected\n' > "$S/inject.txt"
case_ inject-extra-file 'ramdisk contents differ from the expected list' FS_TEST_INJECT="$S/inject.txt:etc/ld.so.preload"

# stage 3d (PM decision J-129): the module list. A list with a v2.7-only module added is refused by the pin;
# a script that names backlight_changes_blocked is refused by the lint
cp "$HERE/modules.load.v66" "$S/modlist-plus-tsens"; echo qcom_tsens.ko >> "$S/modlist-plus-tsens"
case_ module-list-plus-tsens 'module list \(modules.load.v66\) hash differs from the pin' FS_TEST_MODLIST="$S/modlist-plus-tsens"
cp "$HERE/fs-idle.sh" "$S/fs-idle-blk.sh"; printf '%s\n' 'echo 0 > /sys/class/drm/card0-sde-crtc-0/backlight_changes_blocked' >> "$S/fs-idle-blk.sh"
case_ fs-idle-backlight-unblock 'backlight_changes_blocked in a non-comment line of' FS_TEST_IDLE="$S/fs-idle-blk.sh"
# image review B: init.sh's device-side pin of the vendor modules.dep must be the pinned vendor_boot's (one hex digit off)
sed 's/^MODDEP_SHA=ae5edf11/MODDEP_SHA=ae5edf12/' "$HERE/init.sh" > "$S/init-moddep.sh"
case_ init-moddep-pin-wrong 'init.sh MODDEP_SHA is not the pinned vendor_boot' FS_TEST_INIT="$S/init-moddep.sh"
# and the checker itself (tools/module-list-check.py) on the v2.7 vendor modules: it must refuse a list that is not
# closed (a v2.7-only remoteproc module whose dependencies are outside), one that misses a display root, and a
# list naming a file the ramdisk does not have; it must accept the pinned list
python3 -I -E -s -B "$ROOT/build/third_party/mkbootimg/unpack_bootimg.py" --boot_img "$ROOT/firmware/quest3/v2.7-user_ota/vendor_boot.img" --out "$S/vb27" > /dev/null
mkdir -p "$S/vx27" && ( cd "$S/vx27" && lz4 -dc "$S/vb27/vendor_ramdisk00" | cpio -id --quiet --no-absolute-filenames )
ROOTS=msm_drm,dwc3-msm,leds-qti-tri-led,tps65132-regulator,blu_fw_driver,mp3314,pwm-qti-lpg,msm_ext_display,panel_event_notifier,dispcc0-anorak,dispcc1-anorak,ucsi_glink,pwm-tach-fan
MC=$HERE/tools/module-list-check.py
mcase() {  # mcase NAME WANT_RC EXPECTED-FAIL-CHECK LISTFILE
    n=$((n + 1))
    python3 -I -B "$MC" "$4" "$S/vx27/lib/modules" "$ROOTS" > "$FX/$1.log" 2>&1; local rc=$?
    if [ "$rc" = "$2" ] && { [ -z "$3" ] || grep -q "^CHECK $3.* FAIL" "$FX/$1.log"; }; then
        echo "PASS  $1  rc=$rc ${3:+($3 FAIL)}" | tee -a "$R"
    else
        echo "FAIL  $1  rc=$rc (wanted $2 ${3:+with $3 FAIL})" | tee -a "$R"; fail=$((fail + 1))
    fi
}
mcase modcheck-pinned-list 0 "" "$HERE/modules.load.v66"
cp "$HERE/modules.load.v66" "$S/ml-pas"; echo qcom_q6v5_pas.ko >> "$S/ml-pas"
mcase modcheck-not-closed 1 list_closed_under_modules_dep_and_softdeps "$S/ml-pas"
grep -vx 'msm_drm.ko' "$HERE/modules.load.v66" > "$S/ml-nodrm"
mcase modcheck-missing-display-root 1 'roots_closure_inside_the_list' "$S/ml-nodrm"
cp "$HERE/modules.load.v66" "$S/ml-absent"; echo debug-regulator.ko >> "$S/ml-absent"
mcase modcheck-file-absent-in-v27 1 entries_present_as_files "$S/ml-absent"
# review C MINOR-1: adding a v2.7-only module that is closed on its own (no outside deps) must still fail (check 5)
for m in qcom_tsens.ko usbvdm.ko qcom_lpm.ko userspace-consumer.ko bcl_soc.ko; do
    cp "$HERE/modules.load.v66" "$S/ml-forb-$m"; echo "$m" >> "$S/ml-forb-$m"
    mcase "modcheck-forbidden-${m%.ko}" 1 no_forbidden_module "$S/ml-forb-$m"
done

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

# the candidate itself, rebuilt with its own nonce and stamp: the same image, the same cpio
CAND=${1:-}
if [ -n "$CAND" ]; then
    n=$((n + 1))
    CAND=${CAND%/}; cn=${CAND##*-}; cs=$(basename "$CAND" | cut -d- -f1)
    env FS_TEST_NONCE="$cn" FS_TEST_STAMP="$cs" FS_TEST_OUTBASE="$S/cand" bash "$B" > "$FX/candidate-rebuild.log" 2>&1
    hc=$(sha256sum "$CAND/boot-stage3d.img" | cut -c1-64); hr=$(sha256sum "$S"/cand/*/boot-stage3d.img 2>/dev/null | cut -c1-64)
    cc=$(grep -m1 '^ramdisk.cpio' "$CAND/MANIFEST.txt"); cr=$(grep -m1 '^ramdisk.cpio' "$S"/cand/*/MANIFEST.txt 2>/dev/null)
    { echo "candidate $CAND"; echo "nonce $cn stamp $cs"; echo "candidate image $hc"; echo "rebuilt   image $hr"; echo "candidate $cc"; echo "rebuilt   $cr"; } > "$FX/candidate-rebuild.txt"
    if [ -n "$hr" ] && [ "$hc" = "$hr" ] && [ "$cc" = "$cr" ]; then
        echo "PASS  candidate-rebuild  nonce $cn stamp $cs: image $hc again; identical cpio" | tee -a "$R"
    else
        echo "FAIL  candidate-rebuild  '$hc' vs '$hr'" | tee -a "$R"; fail=$((fail + 1))
    fi
fi

rm -rf "${S:?}"
echo "TOTAL: $n cases, $fail failed" | tee -a "$R"
[ $fail -eq 0 ]
