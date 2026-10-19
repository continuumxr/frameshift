#!/bin/bash
# FrameShift N1 — offline whole-image fixtures (the QEMU smoke test of the PID-1 logic and the NCM link's userspace;
# run inside WSL):
#   wsl.exe -e bash <checkout>/devices/quest3/n1/test-image.sh [IMAGE_DIR]
# Derived from k1a/test-image.sh. Runs the /init of the BUILT image (default: the newest $FS_INPUT_ROOT/build/n1/<UTC>-<nonce>/)
# as PID 1 of a bwrap sandbox under qemu-aarch64, each scenario in its own `unshare -rnm` (user, network and mount
# namespaces): the NCM link is a veth pair between the sandbox's namespace and a "PC" namespace that runs the
# reference transfer client (tools/image-harness-n1.py says what is real and what is fake). THE KERNEL IS NOT BOOTED
# (no QEMU model of the Quest 3); /proc/net, the IPv6 address states, the socket tables and the counters are the WSL
# kernel's. No device, no adb/fastboot, no COM port, no host network. Scenarios (in parallel, real timings):
#   c-full             verify, ack, status, fs-n1, fs-done: FSB1 VALID (exp n1, 6 steps); NCM after ACM with the nonce
#                      MACs; fe80::<nonce> the only address, permanent even before the host link (DAD off); no listener
#                      before or after (socket tables; a refused connect before and after); the 8 MiB transfer each
#                      way with matching SHA-256 on both sides; reboot "collected" within 3 s of fs-done
#   c-ncm-bind-fail    the UDC bind fails while NCM is linked (ENODEV): NCM_DROPPED, ONE ACM-only retry, console up,
#                      record VALID, xfer result=no-ncm
#   c-bind-fail        both binds fail: ERROR_udc ("bind failed (ACM-only retry)"), no shell, reboot error-udc at T0 + 60 s
#   c-ncm-skip         the NCM function cannot be made: NCM_SKIPPED, ACM-only, record VALID, xfer no-ncm
#   c-ncm-ifname       NCM bound but no plain interface name: NCM_NET_FAILED, ACM unaffected, xfer no-ncm
#   c-ncm-no-host      the PC never brings the link up (no carrier): fs-xfer listens, nobody connects: accept-timeout
#   c-ncm-fallback     the host never configures the gadget and sends no ack for 30 s: the guard drops NCM and rebinds
#                      ACM-only (NCM_FALLBACK); the console then works; xfer no-ncm
#   c-ncm-unattached   no host attached for 30 s ("not attached"): the guard changes nothing, NCM stays bound
#   c-xfer-bad-header  the client sends another challenge: fs-xfer result=bad-header, nothing sent back
#   c-xfer-short       the client sends half the bytes and closes: fs-xfer result=rx-short
#   c-listener-decoy   an unintended UDP socket and TCP listener in the device namespace: the net step lists them (REVIEW)
#   c-no-memtotal      /proc/meminfo without MemTotal: the record shows it (the classifier must not PASS)
#   c-kmsg-post        (FS-R-014 s.5) a WARNING appears in the kernel log only once the transfer has begun (the
#                      device's port-47201 session ESTABLISHED): step 3's read has none, the log step's post-transfer
#                      read has it (the classifier must not PASS)
#   c-kmsg-post-unreadable  the post-transfer read is refused (EPERM): read=fail (REVIEW, never a silent PASS)
#   c-kmsg-post-wrapped     the post-transfer read misses the log's first lines (as if wrapped): coverage not proven
#   c-kmsg-findings, c-repeat, c-bad-challenge, c-time, c-no-ack, c-ack-no-done, c-done-early, c-modules-real,
#   c-modules-refused  as K1a (RUNNER_WORST 126 s in c-time)
# Every scenario also checks: the deadline values, the backstop, PID 1's exec of fs-reboot-final, no access to a
# decoy backlight node or /sys/class/drm/card0 (inotify), and the tty accounting (no stray output).
# Output: build/n1-harness/<scenario>/ (gitignored) and the tracked summary fixtures/image/.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${FS_INPUT_ROOT:-<repo>}
H=$HERE/tools/image-harness-n1.py
IMG=${1:-$(ls -d "$ROOT"/build/n1/2*-*/ 2>/dev/null | sort | tail -1)}
IMG=${IMG%/}
[ -f "$IMG/boot-n1.img" ] && [ -f "$IMG/MANIFEST.txt" ] || { echo "no built image in '$IMG'"; exit 2; }
if [ -z "${FS_TEST_ALLOW_OVERRIDES:-}" ]; then
    grep -q '^TEST OVERRIDES' "$IMG/MANIFEST.txt" && { echo "refused: $IMG was built with test overrides"; exit 2; }
fi
for t in bwrap qemu-aarch64 python3 lz4 cpio unshare nsenter ip; do command -v $t >/dev/null || { echo "missing $t"; exit 2; }; done
grep -q '^flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || { echo "binfmt qemu-aarch64 with flag F required"; exit 2; }
SCEN=${SCEN:-"c-ack-no-done c-no-ack c-full c-ncm-fallback c-ncm-unattached c-ncm-bind-fail c-bind-fail c-ncm-skip c-ncm-ifname c-ncm-no-host c-xfer-bad-header c-xfer-short c-listener-decoy c-no-memtotal c-kmsg-findings c-kmsg-post c-kmsg-post-unreadable c-kmsg-post-wrapped c-repeat c-bad-challenge c-time c-done-early c-modules-real c-modules-refused"}
OUT=$ROOT/build/n1-harness
FX=$HERE/fixtures/image
rm -rf "$OUT" "$FX"; mkdir -p "$OUT" "$FX"
echo "image: $IMG  sha256=$(sha256sum "$IMG/boot-n1.img" | cut -c1-64)"
printf '%s\n' $SCEN | xargs -P ${PAR:-5} -I{} sh -c 'unshare -rnm python3 -I "$0" "$1" "$2" {} > "$2/{}.harness.txt" 2>&1; echo "{} rc=$?"' "$H" "$IMG" "$OUT"
{
echo "# n1 whole-image fixtures  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# image $(basename "$IMG")/boot-n1.img sha256=$(sha256sum "$IMG/boot-n1.img" | cut -c1-64)"
echo "# harness sha256=$(sha256sum "$H" | cut -c1-64)  test-image.sh sha256=$(sha256sum "$0" | cut -c1-64)"
echo "# host: $(uname -sr); qemu: $(qemu-aarch64 --version | head -1); bwrap $(bwrap --version | cut -d' ' -f2)"
echo "# NOT shown here: the kernel booting (no QEMU model of the Quest 3), f_ncm, the UDC, USB enumeration and Windows; see tools/image-harness-n1.py"
} > "$FX/RESULTS.txt"
fail=0
for s in $SCEN; do
    if [ -f "$OUT/$s/result.txt" ]; then
        mkdir -p "$FX/$s"
        for f in "$OUT/$s"/*; do
            case "${f##*/}" in result.txt|host.log|fs.log|fs.stages|fs.collected|fs.ncm|fsb1.txt|meta.json|capture.raw|capture.raw.idx|runner-*.raw) cp "$f" "$FX/$s/" ;;
            host-xfer) mkdir -p "$FX/$s/host-xfer"; cp "$f"/xfer.json "$f"/client.out "$FX/$s/host-xfer/" 2>/dev/null ;; esac
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
