#!/bin/busybox sh
# FrameShift N1 — fs-n1 <challenge>: the N1 step runner. Installed as /bin/fs-n1 (build-image.sh, hash in
# MANIFEST). Run ONCE per attempt by the host after fs-verify / fs-ack / fs-status, then fs-done. Derived from
# k1a/fs-k1a.sh (the same encoder, pacer, supervisor, refusals and time rule).
# Steps 1-4 and 6 are reads of /proc, /sys, /config or /run (/lib/fs/fs-n1-info.sh <role>, see there). Step 5 runs
# /bin/fs-xfer, the image's ONLY listener (n1/src/fs-xfer.c): one transfer session on the NCM link, designed to end
# within 23 s by its own compiled-in phase limits, under fs-supervise -t 26. The 23 s is a design budget, NOT a hard
# maximum (FS-R-014 s.5): fs-xfer tests a phase deadline only when it waits (poll after EAGAIN; the bind retry); while data keeps
# flowing, while it hashes or computes the stream, and while it writes its report lines, no deadline is tested. The
# hard bounds are its alarm (SIGALRM at 25 s) and fs-supervise (TERM at 26 s, KILL 1 s later); the step is budgeted
# below at t + g + 7.5 = 34.5 s like every step.
#
# FSB1 exp=n1, 6 steps, each under /bin/fs-supervise:
#   i id       -t -g  -c (bytes per stream)   what
#   1 kernel    8  1  6144    uname, /proc/version, /proc/cmdline, the running config's SHA-256 and option lines
#   2 mem       2  1  256     MemTotal, MemFree, MemAvailable, CmaTotal
#   3 modules   9  1  24576   the loaded modules and the loader's lines; the PRE-transfer kernel-log read (refusals,
#                             taint, WARNINGs; K1a's section, unchanged)
#   4 net       6  1  6144    the gadget, the NCM function and interface, IPv6/IPv4 state, every socket table BEFORE
#   5 xfer     26  1  2048    /bin/fs-xfer -n <nonce> -c <challenge> -a fe80::<nonce> -i <if> -p 47201 (or -i none)
#   6 log       6  1  24576   FIRST the post-transfer kernel-log check (FS-R-014 s.5), then /run/fs.log,
#                             /run/fs.stages, every socket table AFTER, the interface counters
# (The timeouts carry the K1a margins for the QEMU user-mode fixtures, where every exec costs ~0.3 s; on the unit each
# read step takes well under a second [C].)
# Steps run one after another (no overlap). A step whose supervisor reports nothing still yields its STEP line.
#
# Bounds (seconds unless noted; tools/check-bounds-n1.py re-derives them from this file and from fs-xfer.c):
#   per step at most t + g + 7.5 (fs-supervise: TERM at t, KILL g later, give-up 3 s after the KILL, its exec-report
#   wait 0.5 s, stray hunt 3 s and drain 1 s):  57 + 6 + 6 x 7.5 = 108
#   MAXLINES: BEGIN + 6 STEP + END + both streams of every step at its cap (48 bytes per DATA line):
#     8 + 2 x (128 + 6 + 512 + 128 + 43 + 512) = 8 + 2 x 1329 = 2666
#   emission: ceil(2666 / 20) = 134 pauses of 0.1 s = 13.4 s, plus the writes (allowed 2 s)
#   RUNNER_WORST = ceil(108 + 13.4 + 2) + 2 (margin) = 126: the runner refuses ("time") unless
#   now + RUNNER_WORST <= /run/fs.deadline (T0 + 200), i.e. it must start by T0 + 74. [C]: the encoder's own work
#   is assumed to fit in the 2 s margin (as K1a, review m4).
# Refusals print one "FSDE1 error=<why> END" line (no FSB1 text: the host classifies INCONCLUSIVE).
# Runs at most once per boot (mkdir /run/fsb).
MAXLINES=2666
RUNNER_WORST=126
XFER_PORT=47201
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
fsb1_begin "$REC" n1 "$n" "$c" 6 || { echo "FSDE1 error=begin END"; exit 1; }

# the xfer step's arguments: the address is a function of the nonce (as init.sh assigns it); the interface comes
# from /run/fs.ncm (init.sh 4c; the guard rewrites it on a fallback) and is used only as a plain name with state=up
ll="fe80::$(echo "$n" | cut -c1-4):$(echo "$n" | cut -c5-8):$(echo "$n" | cut -c9-12):$(echo "$n" | cut -c13-16)"
xs=; xi=
if [ -f /run/fs.ncm ]; then
    while IFS='=' read -r k v; do
        case "$k" in state) xs=$v ;; if) xi=$v ;; esac
    done < /run/fs.ncm
fi
case "$xi" in ''|*[!a-z0-9]*) xi=none ;; esac
[ "$xs" = up ] || xi=none

i=0
for spec in kernel:8:6144 mem:2:256 modules:9:24576 net:6:6144 xfer:26:2048 log:6:24576; do
    i=$((i + 1))
    id=${spec%%:*}; r=${spec#*:}; t=${r%%:*}; cap=${r#*:}
    [ -e "$D/$i.out" ] || [ -e "$D/$i.err" ] || [ -e "$D/$i.sup" ] && { echo "FSDE1 error=step$i END"; exit 1; }
    if [ "$id" = xfer ] && [ "$xi" = none ]; then
        $SUP -t "$t" -g 1 -c "$cap" -o "$D/$i.out" -r "$D/$i.err" -- /bin/fs-xfer -n "$n" -c "$c" -i none > "$D/$i.sup" 2>/dev/null
    elif [ "$id" = xfer ]; then
        $SUP -t "$t" -g 1 -c "$cap" -o "$D/$i.out" -r "$D/$i.err" -- /bin/fs-xfer -n "$n" -c "$c" -a "$ll" -i "$xi" -p "$XFER_PORT" > "$D/$i.sup" 2>/dev/null
    else
        $SUP -t "$t" -g 1 -c "$cap" -o "$D/$i.out" -r "$D/$i.err" -- /bin/busybox sh /lib/fs/fs-n1-info.sh "$id" > "$D/$i.sup" 2>/dev/null
    fi
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
