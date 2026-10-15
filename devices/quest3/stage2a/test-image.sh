#!/bin/bash
# FrameShift stage 2a — offline whole-image fixtures (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/stage2a/test-image.sh [IMAGE_DIR]
# then, on Windows, the host side over the same captures:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\stage2a\test-host.ps1 -Dir build\stage2a-harness
#
# Runs the /init of the BUILT image (default: the newest build/stage2a/<UTC>-<nonce>/)
# as PID 1 of a bwrap sandbox under qemu-aarch64, with the harness as the USB
# host on a pty (tools/image-harness.py: what is real and what is fake). No
# device, no adb/fastboot, no COM port. Scenarios (in parallel, real timings):
#   s2-pass            full host exchange           -> FSB1 VALID (8 steps), PASS, reboot "collected" by exec (pid 1);
#                      step 8 inv read the fake remoteproc/driver/power_supply entries
#   s2-inv-absent      those sysfs entries removed  -> inv prints (none)/(absent), exits 0; still PASS
#   s2-tamper-forced   one bit of /valve/bin/b2sum flipped in the unpacked ramdisk (the builder refuses
#                      this input: test-builder.sh) -> record VALID, hash step measures it: INTEGRITY FAULT
#   s2-missing-forced  /valve/bin/uname removed     -> "can't open" on stderr: INTEGRITY FAULT
#   s2-preload-forced  /etc/ld.so.preload created   -> the absent step lists it: INTEGRITY FAULT
#   s2-hung-step       the loader replaced by a TERM-ignoring endless script -> steps 3-7 end
#                      timer-kill sig=9, the record still completes and validates (INTEGRITY FAULT first)
#   s2-no-ack          fs-verify only, HOST_ACK never sent -> reboot "no-host-ack" at SHELL_READY+120 s (ACK_WINDOW)
#   s2-ack-no-done     full exchange but no fs-done -> reboot "deadline" at T0+260 s: HOST_ACK did not cancel it
#   s2-done-early      fs-done right after fs-verify (no ack, no runner) -> reboot "collected" within 3 s
#   s2-no-udc          /sys/class/udc absent: init fail()s before any shell -> reboot "error-udc" by exec
#                      at T0+ERR_DELAY (60 s); nothing ever written to the tty
# Output: build/stage2a-harness/<scenario>/ (captures; gitignored) and the tracked
# summary fixtures/image/ (RESULTS.txt, per-scenario result/host/fs logs).
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
HERE=$ROOT/devices/quest3/stage2a
STAGE=stage2a
H=$HERE/tools/image-harness.py
IMG=${1:-$(ls -d "$ROOT"/build/$STAGE/2*-*/ 2>/dev/null | sort | tail -1)}
IMG=${IMG%/}
[ -f "$IMG/boot-$STAGE.img" ] && [ -f "$IMG/MANIFEST.txt" ] || { echo "REFUSED: no built image in '$IMG' (expected boot-$STAGE.img and MANIFEST.txt under build/$STAGE/<UTC>-<nonce>/; build/ is gitignored). Build one with devices/quest3/$STAGE/build-image.sh, which needs the gitignored inputs listed in README \"What is not in git\", or pass IMAGE_DIR."; exit 2; }
grep -q '^TEST OVERRIDES' "$IMG/MANIFEST.txt" && { echo "refused: $IMG was built with test overrides"; exit 2; }
for t in bwrap qemu-aarch64 python3 lz4 cpio; do command -v $t >/dev/null || { echo "missing $t"; exit 2; }; done
grep -q '^flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || { echo "binfmt qemu-aarch64 with flag F required"; exit 2; }
SCEN="s2-ack-no-done s2-no-ack s2-no-udc s2-pass s2-inv-absent s2-tamper-forced s2-missing-forced s2-preload-forced s2-hung-step s2-done-early"
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
