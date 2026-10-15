#!/bin/bash
# FrameShift stage 3a — offline whole-image fixtures (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/stage3a/test-image.sh [IMAGE_DIR]
# then, on Windows, the host side over the same captures (FSB1 decode, the stage-3a
# classifier, and fs-collect.ps1 -Stage 3a -Replay end to end):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\stage2a\test-host.ps1 -Dir build\stage3a-harness
#
# Runs the /init of the BUILT image (default: the newest build/stage3a/<UTC>-<nonce>/)
# as PID 1 of a bwrap sandbox under qemu-aarch64 (../stage2a/tools/image-harness.py:
# what is real and what is fake). There is NO DRM device (no /sys/class/drm, no
# /dev/dri): fs-pattern must report "no device" cleanly. No device, no adb/fastboot,
# no COM port. Scenarios (in parallel, real timings):
#   s3-nodrm            full exchange -> FSB1 VALID; step 2 exited 10; FSP1 stream COMPLETE inside the
#                       payload, every nonce = chal[0:8]; reboot "collected" by exec (pid 1)
#   s3-pattern-stopped  the GENUINE fs-pattern (hash intact) SIGSTOPped from outside as it starts -> step 2
#                       timer-kill: DISPLAY FAIL (OUTCOMES §8 rule 6) without an integrity trip
#   s3-hung-pattern     fs-pattern replaced by a TERM-ignoring endless script -> step 2 timer-kill sig=9
#                       after 16 + 3 s; the record completes and validates
#   s3-missing-pattern  /bin/fs-pattern removed (the builder refuses this: test-builder.sh) -> hash step
#                       "can't open", step 2 exec-failed; record VALID
#   s3-no-ack           fs-verify only -> reboot "no-host-ack" at SHELL_READY+120 s
#   s3-ack-no-done      full exchange, no fs-done -> reboot "deadline" at T0+170 s (HOST_ACK did not cancel it)
#   s3-done-early       fs-done right after fs-verify -> reboot "collected" within 3 s
#   s3-no-udc           /sys/class/udc absent: fail() before any shell -> reboot "error-udc" at T0+30 s (ERR_DELAY)
# Output: build/stage3a-harness/<scenario>/ (gitignored) and the tracked summary
# fixtures/image/.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
HERE=$ROOT/devices/quest3/stage3a
STAGE=stage3a
H=$ROOT/devices/quest3/stage2a/tools/image-harness.py
IMG=${1:-$(ls -d "$ROOT"/build/$STAGE/2*-*/ 2>/dev/null | sort | tail -1)}
IMG=${IMG%/}
[ -f "$IMG/boot-$STAGE.img" ] && [ -f "$IMG/MANIFEST.txt" ] || { echo "REFUSED: no built image in '$IMG' (expected boot-$STAGE.img and MANIFEST.txt under build/$STAGE/<UTC>-<nonce>/; build/ is gitignored). Build one with devices/quest3/$STAGE/build-image.sh, which needs the gitignored inputs listed in README \"What is not in git\", or pass IMAGE_DIR."; exit 2; }
grep -q '^TEST OVERRIDES' "$IMG/MANIFEST.txt" && { echo "refused: $IMG was built with test overrides"; exit 2; }
for t in bwrap qemu-aarch64 python3 lz4 cpio; do command -v $t >/dev/null || { echo "missing $t"; exit 2; }; done
grep -q '^flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || { echo "binfmt qemu-aarch64 with flag F required"; exit 2; }
SCEN="s3-ack-no-done s3-no-ack s3-no-udc s3-nodrm s3-pattern-stopped s3-hung-pattern s3-missing-pattern s3-done-early"
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
        for f in result.txt host.log fs.log fs.stages fsb1-python.txt fsp1-stream.txt; do [ -f "$OUT/$s/$f" ] && cp "$OUT/$s/$f" "$FX/$s/"; done
        tail -1 "$OUT/$s/result.txt" >> "$FX/RESULTS.txt"
        grep -q "^SCENARIO $s PASS$" "$OUT/$s/result.txt" || fail=$((fail + 1))
    else
        echo "SCENARIO $s FAIL (harness error: $(tail -3 "$OUT/$s.harness.txt" | tr '\n' ' '))" >> "$FX/RESULTS.txt"; fail=$((fail + 1))
    fi
done
echo "TOTAL: $(echo $SCEN | wc -w) scenarios, $fail failed" >> "$FX/RESULTS.txt"
cat "$FX/RESULTS.txt"
[ $fail -eq 0 ]
