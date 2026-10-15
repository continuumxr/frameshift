#!/bin/bash
# FrameShift stage 3b — offline whole-image fixtures (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/stage3b/test-image.sh [IMAGE_DIR]
# then, on Windows, the host side over the same captures (FSB1 decode, the stage-3b
# classifier, and fs-collect.ps1 -Stage 3b -Replay end to end):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host3b.ps1
#
# Runs the /init of the BUILT image (default: the newest build/stage3b/<UTC>-<nonce>/)
# as PID 1 of a bwrap sandbox under qemu-aarch64 (tools/image-harness-3b.py: what is
# real and what is fake). There is NO DRM device: the genuine fs-pattern reports "no
# device"; the sim-* scenarios replace it by a replay of framed FSP1 streams so the
# runner's gate, pause, probes and paced emission run for real. No device, no
# adb/fastboot, no COM port. Scenarios (in parallel, real timings):
#   b-nodrm            genuine fs-pattern: run 1 exit 10; run 2 skipped (run1-supervisor);
#                      the backlight write (fake node) and read-back 127; FSB1 VALID
#   b-sim-go           both runs "commit" (replay); mid1/mid2 during the holds; pause >= 2 s
#   b-sim-active       run 2 finds the CRTC active: exit 31, no commit (precondition unmet)
#   b-sim-unclean      run 1's close_rc != 0: run 2 skipped (run1-close-not-clean)
#   b-no-backlight     no backlight node: neither run starts (brightness-not-verified)
#   b-probe-hang       every probe blocks on a sysfs read: no run; probes killed after TQ (nosup)
#   b-hung-pattern     fs-pattern ignores TERM: run 1 timer-kill; run 2 skipped
#   b-pattern-stopped  the genuine fs-pattern SIGSTOPped: run 1 timer-kill; run 2 skipped
#   b-no-ack           fs-verify only: reboot no-host-ack at SHELL_READY+150 s
#   b-ack-no-done      full exchange, no fs-done: reboot "deadline" at T0+200 s
#   b-done-early       fs-done right after fs-verify: reboot "collected"
#   b-no-udc           no UDC: fail() reboot at T0+60 s (ERR_DELAY)
# Output: build/stage3b-harness/<scenario>/ (gitignored) and the tracked summary fixtures/image/.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
HERE=$ROOT/devices/quest3/stage3b
STAGE=stage3b
H=$HERE/tools/image-harness-3b.py
IMG=${1:-$(ls -d "$ROOT"/build/$STAGE/2*-*/ 2>/dev/null | sort | tail -1)}
IMG=${IMG%/}
[ -f "$IMG/boot-$STAGE.img" ] && [ -f "$IMG/MANIFEST.txt" ] || { echo "REFUSED: no built image in '$IMG' (expected boot-$STAGE.img and MANIFEST.txt under build/$STAGE/<UTC>-<nonce>/; build/ is gitignored). Build one with devices/quest3/$STAGE/build-image.sh, which needs the gitignored inputs listed in README \"What is not in git\", or pass IMAGE_DIR."; exit 2; }
grep -q '^TEST OVERRIDES' "$IMG/MANIFEST.txt" && { echo "refused: $IMG was built with test overrides"; exit 2; }
for t in bwrap qemu-aarch64 python3 lz4 cpio; do command -v $t >/dev/null || { echo "missing $t"; exit 2; }; done
grep -q '^flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || { echo "binfmt qemu-aarch64 with flag F required"; exit 2; }
SCEN=${SCEN:-"b-ack-no-done b-no-ack b-no-udc b-nodrm b-sim-go b-sim-active b-sim-unclean b-no-backlight b-probe-hang b-hung-pattern b-pattern-stopped b-done-early"}
OUT=$ROOT/build/$STAGE-harness
FX=$HERE/fixtures/image
rm -rf "$OUT" "$FX"; mkdir -p "$OUT" "$FX"
echo "image: $IMG  sha256=$(sha256sum "$IMG/boot-$STAGE.img" | cut -c1-64)"
printf '%s\n' $SCEN | xargs -P 4 -I{} sh -c 'python3 -I "$0" "$1" "$2" "$3" {} > "$3/{}.harness.txt" 2>&1; echo "{} rc=$?"' "$H" "$STAGE" "$IMG" "$OUT"
{
echo "# $STAGE whole-image fixtures  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# image $IMG/boot-$STAGE.img sha256=$(sha256sum "$IMG/boot-$STAGE.img" | cut -c1-64)"
echo "# harness sha256=$(sha256sum "$H" | cut -c1-64)  test-image.sh sha256=$(sha256sum "$0" | cut -c1-64)"
echo "# host: $(uname -sr); qemu: $(qemu-aarch64 --version | head -1); bwrap $(bwrap --version | cut -d' ' -f2)"
} > "$FX/RESULTS.txt"
fail=0
for s in $SCEN; do
    if [ -f "$OUT/$s/result.txt" ]; then
        mkdir -p "$FX/$s"
        for f in result.txt host.log fs.log fs.stages fsb1-python.txt fsp1-run1.txt fsp1-run2.txt probe1.txt probe2.txt meta.json capture.raw capture.raw.idx; do [ -f "$OUT/$s/$f" ] && cp "$OUT/$s/$f" "$FX/$s/"; done
        tail -1 "$OUT/$s/result.txt" >> "$FX/RESULTS.txt"
        grep -q "^SCENARIO $s PASS$" "$OUT/$s/result.txt" || fail=$((fail + 1))
    else
        echo "SCENARIO $s FAIL (harness error: $(tail -3 "$OUT/$s.harness.txt" | tr '\n' ' '))" >> "$FX/RESULTS.txt"; fail=$((fail + 1))
    fi
done
echo "TOTAL: $(echo $SCEN | wc -w) scenarios, $fail failed" >> "$FX/RESULTS.txt"
cat "$FX/RESULTS.txt"
[ $fail -eq 0 ]
