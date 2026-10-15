#!/bin/bash
# FrameShift stage 3d — offline whole-image fixtures (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/stage3d/test-image.sh [IMAGE_DIR]
# Derived from stage3c/test-image.sh (unchanged). Stage 3d: r1 is the display reset (fs-pattern reset), the
# records are exp s3d_<ph>, r2 is gated on the reset (run1-not-reset). Runs the /init of the BUILT image (default: the
# newest build/stage3d/<UTC>-<nonce>/) as PID 1 of a bwrap sandbox under qemu-aarch64
# (tools/image-harness-3d.py: what is real and what is fake). There is NO DRM device: the genuine
# fs-pattern reports "no device"; the sim-* scenarios replace it by a replay of framed v0.7 FSP1
# streams so the runner's gates, pause, probes, markers, idle limit and paced emission run for
# real. No device, no adb/fastboot, no COM port. Scenarios (DESIGN.md §12.3; in parallel, real timings):
#   c-nodrm            genuine fs-pattern: r1 exit 10; r2 skipped (run1-supervisor); p0's write (fake node)
#   c-sim-all          replayed FSP1 for r1 (reset)/r2/r3 (r2 quad_vig): every record VALID, the chain, the fs-pattern
#                      arguments (reset <c1>; show-off-quad <c2> 10 /dev/dri/card0 roll=21 eyes=swap), r3 runs
#   c-sim-r2-dma       r2: quad_vig rejected, quad_dma committed; r3 runs
#   c-sim-r2-reject    r2: both quads rejected, split probe accepted: exit 50, no commit; r3 sent anyway: skipped
#   c-sim-active       r2 finds the CRTC active: exit 31 (precondition unmet)
#   c-sim-reset-fail   r1 (the reset) exit 50 reset_on_rejected: r2 skipped (run1-supervisor: the exit code is checked first)
#   c-order            r2 before r1: FSXE1 ran=0 order
#   c-repeat           p0 twice: FSXE1 ran=0 already-run
#   c-chain-bad        r1 with a wrong <prev>: FSXE1 ran=0 chain
#   c-time             a near /run/fs.deadline (written from outside): FSXE1 ran=0 time
#   c-pause            r2 sent at once after r1: the device waits >= 2 s (markers, probe2 pre)
#   c-pause-fault      an implausible run-1 end time at the pause: r2 skipped pause-fault at once
#   c-idle             no command after r1: reboot "collected" (token idle) at last activity + 120 s
#   c-idle-stuck       "running" with an old activity: the stuck rule (180 s), not the 120 s rule
#   c-no-ack           fs-verify only: reboot no-host-ack at SHELL_READY + 150 s
#   c-ack-no-done      full exchange, no phase, no fs-done: reboot "deadline" at T0 + 200 s
#   c-done-early       fs-done right after fs-verify: reboot "collected"
#   c-markers          FSPM1 grammar, <= 64 B, no FSB1 text, none after rec, nonce, order
#   c-probe-hang       probes block on a sysfs read after p0: r1 skipped probe-late; probes nosup
#   c-no-backlight     no backlight node: p0 write nonode; r1 skipped p0-write-missing
#   c-record-too-large r1's record exceeds MAXLINES_r1: FSXE1 ran=1 record-too-large lines=N max=1545
#   c-step-fail        an encoder step failure after the lit step: FSXE1 ran=1 step1
#   c-sim-r3-hold      r3 replay: show-off-solid <c3[0:8]> 5, the 5 s hold, probe3 mid at 2.5 s
#   c-no-debugfs       inotify on the fake /sys/kernel/debug tree: no access in any phase (checked in every scenario)
#   c-usage-then-p0    a malformed first command (usage refusal before /run/fsb3c existed), then p0: FSXE1 ran=0 order (build review MINOR-1)
#   c-modules-real     (stage 3d) the image's own 95-module list against the real v2.7 modules.dep/softdep (text only, no
#                      .ko): MODULE_INDEX logged first, every entry tried once, nothing else, the vendor list never read
#   c-modules-refused  (stage 3d) modules.dep one line off the pin: MODULES_REFUSED + ERROR_modules, no module tried,
#                      no shell, reboot error-modules at T0 + 60 s. All other scenarios use the real index with a
#                      3-module subset of the list (harness fake, for time)
# Output: build/stage3d-harness/<scenario>/ (gitignored) and the tracked summary fixtures/image/.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
HERE=$ROOT/devices/quest3/stage3d
STAGE=stage3d
H=$HERE/tools/image-harness-3d.py
IMG=${1:-$(ls -d "$ROOT"/build/$STAGE/2*-*/ 2>/dev/null | sort | tail -1)}
IMG=${IMG%/}
[ -f "$IMG/boot-$STAGE.img" ] && [ -f "$IMG/MANIFEST.txt" ] || { echo "no built image in '$IMG'"; exit 2; }
if [ -z "${FS_TEST_ALLOW_OVERRIDES:-}" ]; then
    grep -q '^TEST OVERRIDES' "$IMG/MANIFEST.txt" && { echo "refused: $IMG was built with test overrides"; exit 2; }
fi
for t in bwrap qemu-aarch64 python3 lz4 cpio; do command -v $t >/dev/null || { echo "missing $t"; exit 2; }; done
grep -q '^flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || { echo "binfmt qemu-aarch64 with flag F required"; exit 2; }
SCEN=${SCEN:-"c-ack-no-done c-no-ack c-idle c-idle-stuck c-nodrm c-sim-all c-sim-r2-dma c-sim-r2-reject c-sim-active c-sim-reset-fail c-order c-repeat c-chain-bad c-time c-pause c-pause-fault c-done-early c-markers c-probe-hang c-no-backlight c-record-too-large c-step-fail c-sim-r3-hold c-no-debugfs c-usage-then-p0 c-modules-real c-modules-refused"}
OUT=$ROOT/build/$STAGE-harness
FX=$HERE/fixtures/image
rm -rf "$OUT" "$FX"; mkdir -p "$OUT" "$FX"
echo "image: $IMG  sha256=$(sha256sum "$IMG/boot-$STAGE.img" | cut -c1-64)"
printf '%s\n' $SCEN | xargs -P ${PAR:-6} -I{} sh -c 'python3 -I "$0" "$1" "$2" "$3" {} > "$3/{}.harness.txt" 2>&1; echo "{} rc=$?"' "$H" "$STAGE" "$IMG" "$OUT"
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
        for f in "$OUT/$s"/*; do
            case "${f##*/}" in result.txt|host.log|fs.log|fs.stages|fs.collected|fsb1-*.txt|fsp1-*.txt|probe-*.txt|meta.json|capture.raw|capture.raw.idx|phase-*.raw) cp "$f" "$FX/$s/" ;; esac
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
