#!/bin/busybox sh
# FrameShift stage 3b — fs-display <challenge>: the trial (iii-b) step runner
# (FS-R-010 §4-§6). Installed in the image as /bin/fs-display (build-image.sh,
# hash in MANIFEST). Run ONCE per attempt by the host, with the PM looking
# through the lenses.
#
# FSB1 exp=stage3b, 5 steps (IMAGE.md "Expected FSB1 steps"), each under /bin/fs-supervise:
#   1 hash      /bin/busybox sha256sum /bin/fs-pattern         -t 2 -g 1 -c 256 (runs in the
#               background from the start: no run waits for it)
#   2 probe1    /lib/fs/fs-probe.sh run1 /run/fsb/h             -t 26 -g 1 -c 16384
#               (irq0, mods snapshot, THE backlight write 127 + read-back, pre1, mid1, post1)
#   3 pattern1  /bin/fs-pattern show <chal[0:8]> 3              -t 9 -g 3 -c 40960   (run 1)
#   4 probe2    /lib/fs/fs-probe.sh run2 /run/fsb/h             -t 32 -g 1 -c 12288
#               (read-back only, pre2, mid2, post2)
#   5 pattern2  /bin/fs-pattern show-off <chal[0:8]> 10         -t 16 -g 3 -c 28672  (run 2)
# A run that does not happen is still a step: `/bin/busybox echo FSK1 run=<n> skipped
# reason=<why> END` under fs-supervise (-t 2 -g 1 -c 256), so the step list never changes.
#
# Order and gates (FS-R-010 §4):
#   - probe1 reads (mods), writes brightness 127 ONCE, reads it back (pre1.bl), takes pre1.
#     fs-display waits at most TW1 for that; run 1 starts ONLY if pre1 has FINISHED
#     (pre1.done: no snapshot still running at the commit) and the read-back is 127.
#   - run 1 is SYNCHRONOUS: fs-display waits on its supervisor's PID. No other process
#     opens card0 (probes read sysfs and /proc only; the hash reads /bin/fs-pattern).
#   - after run 1: end1 marker; probe1 takes post1; fs-display waits at most TQ for probe1,
#     then kills its supervisor if it is still running (the step is then "nosup").
#   - the run-2 gate: run 1's supervisor reported end=exited code=0 sig=0 strays=0 pipes=eof,
#     and its FSP1 stream has commit rc=0 (the accepted commit), hold_end rc=0
#     reason=deadline close_rc=0 and exit code=0 reason=held_to_deadline shown=1 (the clean
#     close), ending in eos ... dropped=0. Otherwise run 2 is skipped (registered).
#   - a pause of PAUSE seconds (fork-free) after probe1 ends; then probe2 reads the
#     brightness back (pre2.bl) and takes pre2 (waited for at most TW2); run 2 starts only
#     if the gate holds AND the read-back is 127. Run 2 is `show-off`: it commits nothing
#     unless the CRTC is provably inactive (else exit 31: "precondition unmet: CRTC active").
#   - after run 2: end2; probe2 takes post2; at most TQ, then killed as above.
#   - the record is emitted PACED (common/target/fsb1-pace.sh, with FSB1_PACE_LINES=20 set here:
#     20 lines per 0.1 s, at most about 3 KB per write, far below the 12,289-byte first-read
#     boundary of trial (iii); the same
#     bytes as fsb1_emit), and only if it has at most MAXLINES lines (the maximum permitted
#     record; IMAGE.md §4 derives the emission bound from it). Otherwise FSDE1, no record.
#     MAXLINES is consistent with the caps (review M1): BEGIN + 5 STEP + END + every step's
#     stdout at its cap (48 bytes per DATA line) + the hash step's stderr at its cap =
#     7 + 6 + 6 + 342 + 854 + 256 + 598 = 2069 <= 2070, so no record within its caps can
#     exceed it (fs-pattern writes nothing to stderr; fs-probe.sh sends stderr to /dev/null;
#     the skip step's echo writes none). tools/check-timing-3b.py asserts this.
#
# Refusals print one "FSDE1 error=<why> END" line (no FSB1 text: INCONCLUSIVE).
# Runs at most once per boot (mkdir /run/fsb).
#
# Timing constants (read by tools/check-timing-3b.py; seconds unless noted):
TW1=3
TW2=2
TQ=2
PAUSE=2
MAXLINES=2070
. /lib/fs/fsb1-enc.sh || { echo "FSDE1 error=no-encoder END"; exit 1; }
# 20 lines per 0.1 s (the pinned pacer keeps a caller's value: ${FSB1_PACE_LINES:-10})
FSB1_PACE_LINES=20
. /lib/fs/fsb1-pace.sh || { echo "FSDE1 error=no-pacer END"; exit 1; }

c=$1
n=$(cat /run/fs.nonce 2>/dev/null)
case "$c" in ''|*[!0-9a-f]*) echo "FSDE1 error=bad-challenge END"; exit 1 ;; esac
[ "${#c}" -eq 32 ] || { echo "FSDE1 error=bad-challenge END"; exit 1; }
case "$n" in ''|*[!0-9a-f]*) echo "FSDE1 error=bad-nonce END"; exit 1 ;; esac
[ "${#n}" -eq 16 ] || { echo "FSDE1 error=bad-nonce END"; exit 1; }
[ $# -eq 1 ] || { echo "FSDE1 error=usage END"; exit 1; }
d8=$(printf '%s' "$c" | cut -c1-8)
case "$d8" in ????????) ;; *) echo "FSDE1 error=nonce8 END"; exit 1 ;; esac

D=/run/fsb
mkdir -m 0700 "$D" 2>/dev/null || { echo "FSDE1 error=already-run END"; exit 1; }
H=$D/h
mkdir -m 0700 "$H" || { echo "FSDE1 error=mkdir END"; exit 1; }
REC=$D/record
TICK=$D/.tick
mkfifo -m 600 "$TICK" 2>/dev/null
SUP=/bin/fs-supervise

waitfor() {  # waitfor FILE TENTHS: fork-free (read -t on the private FIFO); 0 if FILE exists in time
    _n=0
    while [ ! -e "$1" ] && [ "$_n" -lt "$2" ]; do
        if [ -p "$TICK" ]; then read -r -t 0.1 _x <> "$TICK"; else sleep 0.1; fi
        _n=$((_n + 1))
    done
    [ -e "$1" ]
}
waitsup() {  # waitsup SUPFILE PID TENTHS: the step's report within TENTHS, else KILL its supervisor
    _n=0
    while [ ! -s "$1" ] && [ "$_n" -lt "$3" ]; do
        if [ -p "$TICK" ]; then read -r -t 0.1 _x <> "$TICK"; else sleep 0.1; fi
        _n=$((_n + 1))
    done
    [ -s "$1" ] || kill -KILL "$2" 2>/dev/null
    wait "$2" 2>/dev/null
    return 0
}
skipstep() {  # skipstep I RUN WHY: the step that replaces a run that does not happen
    $SUP -t 2 -g 1 -c 256 -o "$D/$1.out" -r "$D/$1.err" -- /bin/busybox echo "FSK1 run=$2 skipped reason=$3 END" > "$D/$1.sup" 2>/dev/null
}
for i in 1 2 3 4 5; do
    [ -e "$D/$i.out" ] || [ -e "$D/$i.err" ] || [ -e "$D/$i.sup" ] && { echo "FSDE1 error=step$i END"; exit 1; }
done
fsb1_begin "$REC" stage3b "$n" "$c" 5 || { echo "FSDE1 error=begin END"; exit 1; }

# step 1 (background): the integrity hash
$SUP -t 2 -g 1 -c 256 -o "$D/1.out" -r "$D/1.err" -- /bin/busybox sha256sum /bin/fs-pattern > "$D/1.sup" 2>/dev/null &
P_HASH=$!
# step 2 (background): probe1 (mods, the backlight write and read-back, pre1, then mid1/post1)
$SUP -t 26 -g 1 -c 16384 -o "$D/2.out" -r "$D/2.err" -- /bin/busybox sh /lib/fs/fs-probe.sh run1 "$H" > "$D/2.sup" 2>/dev/null &
P_PR1=$!
waitfor "$H/pre1.done" $((TW1 * 10))
bl1=$(head -c 16 "$H/pre1.bl" 2>/dev/null | tr -d ' \n')

# step 3: run 1 (synchronous)
run1=no
if [ -e "$H/pre1.done" ] && [ "$bl1" = 127 ]; then
    $SUP -t 9 -g 3 -c 40960 -o "$D/3.out" -r "$D/3.err" -- /bin/fs-pattern show "$d8" 3 > "$D/3.sup" 2>/dev/null &
    P_RUN1=$!
    : > "$H/go1"
    wait "$P_RUN1"
    run1=yes
else
    why=brightness-not-verified
    [ -e "$H/pre1.done" ] || why=probe1-late
    : > "$H/skip1"; : > "$H/go1"
    skipstep 3 1 "$why"
fi
: > "$H/end1"
waitsup "$D/2.sup" "$P_PR1" $((TQ * 10))

# the run-2 gate: run 1's accepted commit and clean close
gate=go; why=
if [ "$run1" != yes ]; then gate=skip; why=run1-not-run
elif ! grep -Eq '^FSUP1 end=exited code=0 sig=0 .* strays=0 pipes=eof why=none END$' "$D/3.sup"; then gate=skip; why=run1-supervisor
elif ! grep -q ' step=commit rc=0 ' "$D/3.out"; then gate=skip; why=run1-no-accepted-commit
elif ! grep -Eq ' step=hold_end rc=0 reason=deadline .* close_rc=0 ' "$D/3.out"; then gate=skip; why=run1-close-not-clean
elif ! grep -q ' step=exit rc=0 code=0 reason=held_to_deadline shown=1 ' "$D/3.out"; then gate=skip; why=run1-exit
elif ! tail -n 1 "$D/3.out" | grep -Eq '^FSP1 .* step=eos rc=0 .* dropped=0 '; then gate=skip; why=run1-stream
fi

# the pause (fork-free), then step 4 (background): probe2 (read-back, pre2, mid2, post2)
_n=0
while [ "$_n" -lt "$PAUSE" ]; do
    if [ -p "$TICK" ]; then read -r -t 1 _x <> "$TICK"; else sleep 1; fi
    _n=$((_n + 1))
done
$SUP -t 32 -g 1 -c 12288 -o "$D/4.out" -r "$D/4.err" -- /bin/busybox sh /lib/fs/fs-probe.sh run2 "$H" > "$D/4.sup" 2>/dev/null &
P_PR2=$!
waitfor "$H/pre2.done" $((TW2 * 10))
bl2=$(head -c 16 "$H/pre2.bl" 2>/dev/null | tr -d ' \n')
if [ "$gate" = go ] && { [ ! -e "$H/pre2.done" ] || [ "$bl2" != 127 ]; }; then
    gate=skip; why=brightness-not-verified
    [ -e "$H/pre2.done" ] || why=probe2-late
fi

# step 5: run 2 (show-off: commits only from a provably inactive CRTC)
if [ "$gate" = go ]; then
    $SUP -t 16 -g 3 -c 28672 -o "$D/5.out" -r "$D/5.err" -- /bin/fs-pattern show-off "$d8" 10 > "$D/5.sup" 2>/dev/null &
    P_RUN2=$!
    : > "$H/go2"
    wait "$P_RUN2"
else
    : > "$H/skip2"; : > "$H/go2"
    skipstep 5 2 "$why"
fi
: > "$H/end2"
waitsup "$D/4.sup" "$P_PR2" $((TQ * 10))
wait "$P_HASH" 2>/dev/null

# the record: steps in order, then END, then the paced emission
fsb1_step "$REC" 1 hash     "$D/1.sup" "$D/1.out" "$D/1.err" || { echo "FSDE1 error=step1 END"; exit 1; }
fsb1_step "$REC" 2 probe1   "$D/2.sup" "$D/2.out" "$D/2.err" || { echo "FSDE1 error=step2 END"; exit 1; }
fsb1_step "$REC" 3 pattern1 "$D/3.sup" "$D/3.out" "$D/3.err" || { echo "FSDE1 error=step3 END"; exit 1; }
fsb1_step "$REC" 4 probe2   "$D/4.sup" "$D/4.out" "$D/4.err" || { echo "FSDE1 error=step4 END"; exit 1; }
fsb1_step "$REC" 5 pattern2 "$D/5.sup" "$D/5.out" "$D/5.err" || { echo "FSDE1 error=step5 END"; exit 1; }
fsb1_end "$REC" "$n" "$c" || { echo "FSDE1 error=end END"; exit 1; }
fsb1_emit_paced "$REC" "$TICK" "$MAXLINES"
rc=$?
case $rc in
    0) ;;
    3) echo "FSDE1 error=record-too-large lines=$(wc -l < "$REC" | tr -d ' ') max=$MAXLINES END"; exit 1 ;;
    *) echo "FSDE1 error=emit-$rc END"; exit 1 ;;
esac
