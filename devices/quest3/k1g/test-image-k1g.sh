#!/bin/bash
# FrameShift K1g — offline whole-image fixtures (the QEMU smoke test of the PID-1 logic; run inside WSL); adapted
# copy of k1a/test-image.sh (not edited):
#   wsl.exe -e bash <checkout>/devices/quest3/k1g/test-image-k1g.sh [IMAGE_DIR]
# Runs the /init of the BUILT image (default: the newest $FS_INPUT_ROOT/build/k1g/<UTC>-<nonce>/) as PID 1 of a bwrap
# sandbox under qemu-aarch64 (tools/image-harness-k1g.py says what is real and what is fake). The guard proof meets
# a kernel without fs-blkguard and must ABORT having created nothing (every scenario checks it). THE KERNEL IS NOT
# BOOTED: QEMU user mode runs our aarch64 userspace on the host kernel, and no QEMU machine models the Quest 3
# (anorak SoC, Meta's DT, the vendor_boot path); the kernel facts the runner reports are bind-mounted fakes.
# No device, no adb/fastboot, no COM port. Scenarios (in parallel, real timings):
#   c-full             verify, ack, status, fs-k1g, fs-done: FSB1 VALID (exp k1g, 9 steps), every step's content,
#                      the ACM-only gadget (J-179), reboot "collected" within 3 s of fs-done
#   c-bind-fail        the UDC bind fails: ERROR_udc, no shell, reboot error-udc at T0 + 60 s
#   c-kmsg-findings    canned 5.10 kernel-log lines: the helper's filters under the image's busybox count 4 refusals,
#                      1 taint note and 1 WARNING (3 lines). Every kernel fact (the log, /proc/modules, filesystems, mounts,
#                      the taint value) is a fake in every scenario: no host data in the fixtures (review M2)
#   c-repeat           fs-k1g twice: the second refused FSDE1 error=already-run
#   c-bad-challenge    fs-k1g nothex: FSDE1 error=bad-challenge, no record
#   c-time             a near /run/fs.deadline (30 s, written from outside): FSDE1 error=time (RUNNER_WORST 127 s)
#   c-no-ack           fs-verify only: reboot no-host-ack at SHELL_READY + 150 s
#   c-ack-no-done      ack, no runner, no fs-done: reboot "deadline" at T0 + 200 s
#   c-done-early       fs-done right after fs-verify: reboot "collected"
#   c-modules-real     the image's own 95-module list against the real v2.7 modules.dep/softdep (no .ko)
#   c-modules-refused  modules.dep one line off the pin: no module, no shell, reboot error-modules at T0 + 60 s
# Every scenario also checks: the deadline values, the backstop, PID 1's exec of fs-reboot-final, no access to a
# decoy backlight node or /sys/class/drm/card0 (inotify), and the tty accounting (no stray output).
# Output: build/k1g-harness/<scenario>/ (gitignored) and the tracked summary fixtures/image/.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${FS_INPUT_ROOT:-<repo>}
H=$HERE/tools/image-harness-k1g.py
IMG=${1:-$(ls -d "$ROOT"/build/k1g/2*-*/ 2>/dev/null | sort | tail -1)}
IMG=${IMG%/}
[ -f "$IMG/boot-k1g.img" ] && [ -f "$IMG/MANIFEST.txt" ] || { echo "no built image in '$IMG'"; exit 2; }
if [ -z "${FS_TEST_ALLOW_OVERRIDES:-}" ]; then
    grep -q '^TEST OVERRIDES' "$IMG/MANIFEST.txt" && { echo "refused: $IMG was built with test overrides"; exit 2; }
fi
for t in bwrap qemu-aarch64 python3 lz4 cpio; do command -v $t >/dev/null || { echo "missing $t"; exit 2; }; done
grep -q '^flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || { echo "binfmt qemu-aarch64 with flag F required"; exit 2; }
SCEN=${SCEN:-"c-ack-no-done c-no-ack c-full c-kmsg-findings c-bind-fail c-repeat c-bad-challenge c-time c-done-early c-modules-real c-modules-refused"}
OUT=$ROOT/build/k1g-harness
FX=$HERE/fixtures/image
rm -rf "$OUT" "$FX"; mkdir -p "$OUT" "$FX"
echo "image: $IMG  sha256=$(sha256sum "$IMG/boot-k1g.img" | cut -c1-64)"
printf '%s\n' $SCEN | xargs -P ${PAR:-5} -I{} sh -c 'python3 -I "$0" "$1" "$2" {} > "$2/{}.harness.txt" 2>&1; echo "{} rc=$?"' "$H" "$IMG" "$OUT"
{
echo "# k1g whole-image fixtures  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# image $(basename "$IMG")/boot-k1g.img sha256=$(sha256sum "$IMG/boot-k1g.img" | cut -c1-64)"
echo "# harness sha256=$(sha256sum "$H" | cut -c1-64)  test-image.sh sha256=$(sha256sum "$0" | cut -c1-64)"
echo "# host: $(uname -sr); qemu: $(qemu-aarch64 --version | head -1); bwrap $(bwrap --version | cut -d' ' -f2)"
echo "# NOT shown here: the K1g kernel booting (no QEMU model of the Quest 3) or the guard acting (no guard in the host kernel: the probe ABORTs); see tools/image-harness-k1g.py and tools/blkguard/vm/"
} > "$FX/RESULTS.txt"
fail=0
for s in $SCEN; do
    if [ -f "$OUT/$s/result.txt" ]; then
        mkdir -p "$FX/$s"
        for f in "$OUT/$s"/*; do
            case "${f##*/}" in result.txt|host.log|fs.log|fs.stages|fs.collected|fsb1.txt|meta.json|capture.raw|capture.raw.idx|runner-*.raw) cp "$f" "$FX/$s/" ;; esac
        done
        tail -1 "$OUT/$s/result.txt" >> "$FX/RESULTS.txt"
        grep -q "^SCENARIO $s PASS$" "$OUT/$s/result.txt" || fail=$((fail + 1))
    else
        echo "SCENARIO $s FAIL (harness error: $(tail -3 "$OUT/$s.harness.txt" | tr '\n' ' '))" >> "$FX/RESULTS.txt"; fail=$((fail + 1))
    fi
done
echo "TOTAL: $(echo $SCEN | wc -w) scenarios, $fail failed" >> "$FX/RESULTS.txt"
cat "$FX/RESULTS.txt"
[ $fail -eq 0 ]
