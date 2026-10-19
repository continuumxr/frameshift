#!/bin/busybox sh
# FrameShift K1g — fs-k1g <challenge>: the K1g step runner (adapted copy of k1a/fs-k1a.sh, not edited).
# Installed as /bin/fs-k1g (build-image-k1g.sh, hash in MANIFEST). Run ONCE per attempt by the host after
# fs-verify / fs-ack / fs-status, then fs-done. It changes nothing on the unit: every step is a read of /proc,
# /sys, /config or /run (/lib/fs/fs-k1g-info.sh <role>, see there). The guard proof itself ran earlier, in PID 1
# (init.sh section 2b); step 9 (blkguard) only reports its result from RAM.
#
# FSB1 exp=k1g, 9 steps, each `/bin/busybox sh /lib/fs/fs-k1g-info.sh <id>` under /bin/fs-supervise:
#   i id       -t -g  -c (bytes per stream)
#   1 kernel    3  1  4096
#   2 config    8  1  2048
#   3 mem       2  1  256
#   4 modules   5  1  8192
#   5 kmsg      4  1  16384
#   6 fs        3  1  1024
#   7 usb       5  1  2048
#   8 log       2  1  16384
#   9 blkguard  2  1  8192
# (The timeouts carry a margin for the QEMU user-mode fixtures, where every exec costs ~0.3 s; on the unit each step
# takes well under a second [C].)
# Steps run one after another (no overlap). A step whose supervisor reports nothing still yields its STEP
# line (fsb1_step's fixed "nosup" field set), so the step list never changes.
#
# Bounds (seconds unless noted; k1g/tools/check-bounds-k1g.py re-derives them from this file):
#   per step at most t + g + 7.5 (fs-supervise: TERM at t, KILL g later, give-up 3 s after the KILL, plus its
#   exec-report wait 0.5 s, stray hunt 3 s and drain 1 s; review MINOR-5):
#     34 + 9 + 9 x 7.5 = 110.5
#   MAXLINES: BEGIN + 9 STEP + END + both streams of every step at its cap (48 bytes per DATA line):
#     11 + 2 x (86 + 43 + 6 + 171 + 342 + 22 + 43 + 342 + 171) = 11 + 2 x 1226 = 2463
#   emission: 2463 lines, 20 per 0.1 s tick = 124 pauses = 12.4 s (common/target/fsb1-pace.sh), plus the writes
#   themselves (at most ~150 KB on the ACM link; allowed 2 s) -> 14.4 s
#   RUNNER_WORST = ceil(110.5 + 14.4) + 2 (margin) = 127: the runner refuses ("time") unless
#   now + RUNNER_WORST <= /run/fs.deadline (T0 + 200, written by init.sh), i.e. it must start by T0 + 73, so a
#   started record ends before PID 1's deadline even in the worst case. [C]: the encoder's own work (fsb1_begin, the
#   STEP lines, base64 of at most ~110 KB, fsb1_end) is assumed to fit in the 2 s margin (review m4).
#
# Refusals print one "FSDE1 error=<why> END" line (no FSB1 text: the host classifies INCONCLUSIVE).
# Runs at most once per boot (mkdir /run/fsb).
MAXLINES=2463
RUNNER_WORST=127
. /lib/fs/fsb1-enc.sh || { echo "FSDE1 error=no-encoder END"; exit 1; }
# 20 lines per 0.1 s (the pinned pacer keeps a caller's value: ${FSB1_PACE_LINES:-10})
FSB1_PACE_LINES=20
. /lib/fs/fsb1-pace.sh || { echo "FSDE1 error=no-pacer END"; exit 1; }

c=$1
n=$(cat /run/fs.nonce 2>/dev/null)
[ $# -eq 1 ] || { echo "FSDE1 error=usage END"; exit 1; }
case "$c" in ''|*[!0-9a-f]*) echo "FSDE1 error=bad-challenge END"; exit 1 ;; esac
[ "${#c}" -eq 32 ] || { echo "FSDE1 error=bad-challenge END"; exit 1; }
case "$n" in ''|*[!0-9a-f]*) echo "FSDE1 error=bad-nonce END"; exit 1 ;; esac
[ "${#n}" -eq 16 ] || { echo "FSDE1 error=bad-nonce END"; exit 1; }

# the time refusal (stage 3c's rule): digits only, no leading zero, before any arithmetic
dl=$(cat /run/fs.deadline 2>/dev/null)
read -r now _ < /proc/uptime
now=${now%%.*}
case "$dl" in ''|0?*|*[!0-9]*) echo "FSDE1 error=time-unknown END"; exit 1 ;; esac
case "$now" in ''|0?*|*[!0-9]*) echo "FSDE1 error=time-unknown END"; exit 1 ;; esac
[ "${#dl}" -le 9 ] && [ "${#now}" -le 9 ] || { echo "FSDE1 error=time-unknown END"; exit 1; }
[ $((now + RUNNER_WORST)) -le "$dl" ] || { echo "FSDE1 error=time now=$now deadline=$dl worst=$RUNNER_WORST END"; exit 1; }

D=/run/fsb
mkdir -m 0700 "$D" 2>/dev/null || { echo "FSDE1 error=already-run END"; exit 1; }
REC=$D/record
TICK=$D/.tick
mkfifo -m 600 "$TICK" 2>/dev/null
SUP=/bin/fs-supervise
fsb1_begin "$REC" k1g "$n" "$c" 9 || { echo "FSDE1 error=begin END"; exit 1; }

i=0
for spec in kernel:3:4096 config:8:2048 mem:2:256 modules:5:8192 kmsg:4:16384 fs:3:1024 usb:5:2048 log:2:16384 blkguard:2:8192; do
    i=$((i + 1))
    id=${spec%%:*}; r=${spec#*:}; t=${r%%:*}; cap=${r#*:}
    [ -e "$D/$i.out" ] || [ -e "$D/$i.err" ] || [ -e "$D/$i.sup" ] && { echo "FSDE1 error=step$i END"; exit 1; }
    $SUP -t "$t" -g 1 -c "$cap" -o "$D/$i.out" -r "$D/$i.err" -- /bin/busybox sh /lib/fs/fs-k1g-info.sh "$id" > "$D/$i.sup" 2>/dev/null
    fsb1_step "$REC" "$i" "$id" "$D/$i.sup" "$D/$i.out" "$D/$i.err" || { echo "FSDE1 error=step$i END"; exit 1; }
done
fsb1_end "$REC" "$n" "$c" || { echo "FSDE1 error=end END"; exit 1; }
fsb1_emit_paced "$REC" "$TICK" "$MAXLINES"
rc=$?
case "$rc" in
    0) ;;
    3) echo "FSDE1 error=record-too-large lines=$(wc -l < "$REC") max=$MAXLINES END"; exit 1 ;;
    *) echo "FSDE1 error=emit rc=$rc END"; exit 1 ;;
esac
exit 0
