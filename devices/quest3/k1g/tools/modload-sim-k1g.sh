#!/bin/bash
# FrameShift K1g — the module-load simulation on the K1g build (adapted copy of k1a/tools/modload-sim.sh, not edited;
# it runs k1a/tools/modload-sim-k1a.py unchanged) and writes k1g/fixtures/modload/RESULTS.txt.
# Offline; run in WSL:  bash <checkout>/devices/quest3/k1g/tools/modload-sim-k1g.sh
# Cases:
#   k1g            the K1g build (Module.symvers + Image) with the image's 95-module list: must PASS, 95/95
#   stock-build    control: our stock-config build of the same source (~/work/kgate27/out-repro): must PASS, 95/95
#   k1g-perturbed  negative control: the K1g view with kmalloc_caches' CRC flipped: must FAIL (the importers refused)
#   k1g-list-plus  negative control: the list plus qcom_q6v5_pas.ko (not closed: its dependencies are outside the
#                  list, and the loader replay then pulls them in; must still PASS the loader checks, but the count
#                  differs from 95: expect-loaded fails) -- shows the count pin bites
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
K1G=$(cd "$HERE/.." && pwd)
ROOT=${FS_INPUT_ROOT:-<repo>}
AOSP=$ROOT/build/third_party/mkbootimg
VB=$ROOT/firmware/quest3/v2.7-user_ota/vendor_boot.img
EXPECT_VB=bc0dd14de41834a601513123b2225a677fa4212dfa4505bf964228cea40d2f5b
OUTK=${FS_K1G_OUT:-$HOME/work/kgate27/out-k1g}
OUTS=$HOME/work/kgate27/out-repro
LIST=$K1G/../stage3d/modules.load.v66
SIM=$K1G/../k1a/tools/modload-sim-k1a.py
FX=$K1G/fixtures/modload
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
rm -rf "$FX"; mkdir -p "$FX"
[ "$(sha256sum "$VB" | cut -c1-64)" = "$EXPECT_VB" ] || { echo "vendor_boot is not the pinned v2.7 one"; exit 2; }
python3 -I -E -s -B "$AOSP/unpack_bootimg.py" --boot_img "$VB" --out "$W/vb" > /dev/null
mkdir -p "$W/vx" && ( cd "$W/vx" && lz4 -dc "$W/vb/vendor_ramdisk00" | cpio -id --quiet --no-absolute-filenames )
R=$FX/RESULTS.txt
{
echo "# K1g module-load simulation  $(date -u +%FT%TZ)"
echo "# tool $(sha256sum "$SIM" | cut -c1-64); vendor_boot $EXPECT_VB; list $(sha256sum "$LIST" | cut -c1-64) (stage3d/modules.load.v66)"
echo "# K1g build: Module.symvers $(sha256sum "$OUTK/Module.symvers" | cut -c1-64), Image $(sha256sum "$OUTK/arch/arm64/boot/Image" | cut -c1-64)"
echo "# stock-config build: Module.symvers $(sha256sum "$OUTS/Module.symvers" | cut -c1-64)"
} > "$R"
fail=0
sim() {  # sim NAME WANT_RC ARGS...
    local name=$1 want=$2; shift 2
    python3 -I -B "$SIM" --vendor-ramdisk "$W/vx" --label "$name" "$@" > "$FX/$name.txt" 2>&1; local rc=$?
    local res; res=$(grep -m1 '^RESULT' "$FX/$name.txt")
    if [ "$rc" = "$want" ]; then echo "PASS  $name  rc=$rc  $res" | tee -a "$R"; else echo "FAIL  $name  rc=$rc (wanted $want)  $res" | tee -a "$R"; fail=$((fail + 1)); fi
}
sim k1g 0 --modlist "$LIST" --symvers "$OUTK/Module.symvers" --kernel "$OUTK/arch/arm64/boot/Image" --expect-loaded 95
sim stock-build 0 --modlist "$LIST" --symvers "$OUTS/Module.symvers" --kernel "$OUTS/arch/arm64/boot/Image" --expect-loaded 95
sim k1g-perturbed 1 --modlist "$LIST" --symvers "$OUTK/Module.symvers" --kernel "$OUTK/arch/arm64/boot/Image" --expect-loaded 95 --perturb kmalloc_caches
cp "$LIST" "$W/list-plus"; echo qcom_q6v5_pas.ko >> "$W/list-plus"
sim k1g-list-plus 1 --modlist "$W/list-plus" --symvers "$OUTK/Module.symvers" --kernel "$OUTK/arch/arm64/boot/Image" --expect-loaded 95
echo "TOTAL: 4 cases, $fail failed" | tee -a "$R"
[ $fail -eq 0 ]
