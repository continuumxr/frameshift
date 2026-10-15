#!/bin/busybox sh
# FrameShift stage 3d — fs-phase <ph> <chal> <prev>: the per-phase step runner of the
# interactive display run on v2.7 (stage3d/README.md; the stage-3c design
# devices/quest3/stage3c/DESIGN.md rev 3 §5 with the stage-3d deltas). Installed in the
# image as /bin/fs-phase (build-image.sh, hash in MANIFEST). Sent once per phase by the host
# (verb table: '^(p0|r1|r2|r3) [0-9a-f]{32} [0-9a-f]{16}\z', unchanged).
#
# Stage-3d changes from stage3c/fs-phase.sh (PM decisions; everything else is unchanged):
#   - r1 is the DISPLAY RESET: `fs-pattern reset <chal[0:8]>` (fs-pattern v0.7), three steps in one
#     process: (A) disable the handed-over CRTC (connector CRTC_ID 0, MODE_ID 0, ACTIVE 0, its planes
#     off), (B) a dark re-enable on an all-black buffer (the v0.5 modeset attempts; it ends the
#     continuous splash), (C) close at once (lastclose powers the panel fully off). No picture; only
#     black is ever scanned out. Same supervisor bounds, same probe (fs-probe.sh r1 unchanged), same
#     gates before it; no hold, no PM readings.
#   - r2 is gated on the RESET (gate_reset): run1-not-run, run1-supervisor, run1-not-reset (the
#     exit line is not code=0 reason=reset_done|already_inactive), run1-stream; then the pause
#     after r1 (unchanged) and r2's own inactive-CRTC precondition in fs-pattern (exit 31).
#   - r2 passes the picture options explicitly: show-off-quad <c2> 10 /dev/dri/card0 roll=$ROLL eyes=$EYES.
#   - the FSB1 record type is exp=s3d_<ph> (was s3c_<ph>): a stage-3c host tool cannot mistake
#     the reset record for a lit run 1.
#
#   <ph>   p0 | r1 | r2 | r3, in this order only (r3 only after r2; nothing after r3)
#   <chal> 32 lowercase hex, fresh per phase; its first 8 are that run's characters
#   <prev> the first 16 hex of rec_sha256 of the previous phase's record (p0: 16 zeros);
#          compared with the device's own copy taken from its own END line
#
# One FSB1 record per phase (FSB1 v1, fsb1-enc.sh rev 5, paced by fsb1-pace.sh at 20
# lines per 0.1 s), exp=s3d_<ph>, 2 steps, each under /bin/fs-supervise:
#   p0  1 hash      /bin/busybox sha256sum /bin/fs-pattern        -t 2 -g 1 -c 256   (concurrent)
#       2 probe0    /lib/fs/fs-probe.sh p0 /run/fsb3c/h           -t 8 -g 1 -c 16384 (THE write 127)
#   r1  1 probe1    /lib/fs/fs-probe.sh r1 /run/fsb3c/h           -t 24 -g 1 -c 16384
#       2 pattern1  /bin/fs-pattern reset <chal[0:8]>             -t 9 -g 3 -c 57344 (no picture)
#   r2  1 probe2    /lib/fs/fs-probe.sh r2 /run/fsb3c/h           -t 32 -g 1 -c 16384
#       2 pattern2  /bin/fs-pattern show-off-quad <chal[0:8]> 10 /dev/dri/card0 roll=21 eyes=swap
#                                                                 -t 16 -g 3 -c 57344
#   r3  1 probe3    /lib/fs/fs-probe.sh r3 /run/fsb3c/h           -t 26 -g 1 -c 16384
#       2 pattern3  /bin/fs-pattern show-off-solid <chal[0:8]> 5  -t 11 -g 3 -c 28672
# A run that does not happen is still a step: `/bin/busybox echo FSK1 run=<n> skipped
# reason=<why> END` under fs-supervise (-t 2 -g 1 -c 256).
#
# Device-side gates (registered skips; DESIGN §5.3):
#   r1  the p0 write evidence (/run/fsb3c/p0.bl = 127, p0.wrc = 0), else p0-write-missing;
#       probe1's pre FINISHED within TW, else probe-late; the read-back 127, else
#       brightness-not-verified.
#   r2  (stage 3d) the reset ran (else run1-not-run) with supervisor end=exited code=0 sig=0 ...
#       strays=0 pipes=eof why=none (run1-supervisor), exit rc=0 code=0 reason=reset_done or
#       reason=already_inactive with shown=0 (run1-not-reset), eos ... dropped=0 (run1-stream);
#       then the PAUSE: uptime >= run 1's end + 2.00 s, bounded (pause-fault); then probe-late /
#       brightness-not-verified; fs-pattern itself refuses an active CRTC (exit 31).
#   r3  the same on run 2, plus commit ... layout=quad_ (run2-not-quad); pause after run 2.
#   The pause computes rem = end + 2.00 s - uptime once; rem > 2.00 s or an unreadable
#   uptime -> pause-fault; else at most PAUSE_ITER x `read -t 0.1` on the private FIFO,
#   re-reading /proc/uptime each time; still short after the last one -> pause-fault.
#
# Refusals (DESIGN §5.2): exactly one line `FSXE1 p=<ph|-> ran=<0|1> error=<why> END`, then
# /run/fsb3c/closed exists and every later phase is refused (order). ran=0: nothing of the
# phase ran (usage, bad-nonce, order, already-run, chain, time, begin). ran=1: the steps ran
# (step<i>, end, emit-<rc>, record-too-large lines=N max=M); markers may precede it;
# record-too-large is decided BEFORE the rec marker; emit-<rc> follows the rec marker (a
# partial record is possible). No complete record exists after any refusal.
#
# Live markers (DESIGN §5.4), one printf builtin each, <= 64 bytes, never containing FSB1,
# all BEFORE the record's leading empty line, at most 4 per phase:
#   FSPM1 n=<nonce16> p=<ph> e=<begin|go|end|skip|rec> t=<uptime_ms> END
# begin: the refusal checks passed and the lock is taken; go: the pattern step was spawned;
# end: its supervisor returned; skip: the run is replaced by its skip step; rec: right before
# the paced emission. After the record nothing is written to the tty.
#
# Idle limit hand-shake (fs-idle.sh): /run/fsb3c/activity = uptime seconds at the start and
# at the end of every phase that took the lock; /run/fsb3c/running exists during it.
#
# Timing constants (read by tools/check-timing-3c.py; seconds unless noted):
# (build review: TQ 2 -> 3 s, NIT-3; PHASE_WORST re-derived with the encoder END pass and the cold
#  57344-byte repetition, MINOR-2: every PHASE_WORST >= W + 0.5 s; DESIGN 9.1, check-timing-3c.py)
TW=2
TQ=3
PAUSE_CS=200
PAUSE_ITER=20
HEADROOM=5
PHASE_WORST_p0=23
PHASE_WORST_r1=38
PHASE_WORST_r2=47
PHASE_WORST_r3=39
MAXLINES_p0=360
MAXLINES_r1=1545
MAXLINES_r2=1545
MAXLINES_r3=945
# stage 3d: the run-2 picture options (fs-pattern v0.7; [C]: J-125 report, screen_rotation 201)
ROLL=21
EYES=swap

D=/run/fsb3c
H=$D/h
PH=-
SUP=/bin/fs-supervise
LOCKED=0

refuse() {  # refuse RAN WHY...: the one FSXE1 line; the session is closed for every later phase
    # ($D is made before the first refusal check, so even a usage refusal of the first command leaves
    #  $D/closed behind: build review MINOR-1; a symlinked $D is never written and refuses every phase)
    [ -d "$D" ] && [ ! -L "$D" ] && : > "$D/closed"
    printf 'FSXE1 p=%s ran=%s error=%s END\n' "$PH" "$1" "$2"
    if [ "$LOCKED" = 1 ]; then activity; rm -f "$D/running"; fi
    exit 1
}
_num() {  # _num VALUE -> _d: canonical decimal (0 or [1-9][0-9]{0,8}) else empty (no arithmetic on it)
    case "$1" in
        0) _d=0 ;;
        ''|*[!0-9]*|0*) _d= ;;
        *) if [ ${#1} -le 9 ]; then _d=$1; else _d=; fi ;;
    esac
}
now_cs() {  # now_cs: _cs = /proc/uptime in centiseconds (builtins only); 1 if unreadable
    _u=""; read -r _u _r < /proc/uptime
    _num "${_u%%.*}"; _s=$_d
    _f=${_u#*.}
    case "$_f" in [0-9][0-9]) _f=${_f#0} ;; *) _cs=; return 1 ;; esac
    [ -n "$_s" ] || { _cs=; return 1; }
    _cs=$((_s * 100 + _f))
    return 0
}
mark() {  # mark EVENT: one live marker line, fork-free
    if now_cs; then _ms=$((_cs * 10)); else _ms=0; fi
    printf 'FSPM1 n=%s p=%s e=%s t=%s END\n' "$n" "$PH" "$1" "$_ms"
}
activity() {  # the idle-limit hand-shake: uptime seconds, fork-free
    _u=""; read -r _u _r < /proc/uptime
    printf '%s\n' "${_u%%.*}" > "$D/activity"
}
tick() { if [ -p "$TICK" ]; then read -r -t 0.1 _x <> "$TICK"; else sleep 0.1; fi; }
waitfor() {  # waitfor FILE TENTHS: fork-free; 0 if FILE exists in time
    _n=0
    while [ ! -e "$1" ] && [ "$_n" -lt "$2" ]; do tick; _n=$((_n + 1)); done
    [ -e "$1" ]
}
waitsup() {  # waitsup SUPFILE PID TENTHS: the step's report within TENTHS, else KILL its supervisor
    _n=0
    while [ ! -s "$1" ] && [ "$_n" -lt "$3" ]; do tick; _n=$((_n + 1)); done
    [ -s "$1" ] || kill -KILL "$2" 2>/dev/null
    wait "$2" 2>/dev/null
    return 0
}
skipstep() {  # skipstep I RUN WHY: the step that replaces a run that does not happen
    $SUP -t 2 -g 1 -c 256 -o "$S/$1.out" -r "$S/$1.err" -- /bin/busybox echo "FSK1 run=$2 skipped reason=$3 END" > "$S/$1.sup" 2>/dev/null
}
endmark() {  # endmark: run N's end time (centiseconds) for the next pause, then the end marker
    if now_cs; then printf '%s\n' "$_cs" > "$D/$PH.end_cs"; fi
    mark end
}
pause() {  # pause PREVPH: until uptime >= <prev>.end_cs + PAUSE_CS, bounded and fork-free; 1 = pause-fault
    _e=""; [ -f "$D/$1.end_cs" ] && read -r _e < "$D/$1.end_cs"
    _num "$_e"; _e=$_d
    [ -n "$_e" ] && now_cs || return 1
    _rem=$((_e + PAUSE_CS - _cs))
    [ "$_rem" -le "$PAUSE_CS" ] || return 1
    _i=0
    while [ "$_rem" -gt 0 ]; do
        [ "$_i" -lt "$PAUSE_ITER" ] || return 1
        tick
        _i=$((_i + 1))
        now_cs || return 1
        _rem=$((_e + PAUSE_CS - _cs))
    done
    return 0
}
gate_reset() {  # stage 3d: gate_reset -> why (empty = go): run 1 (the reset) finished cleanly
    _G=$D/r1
    why=
    if [ -e "$H/r1.skip" ] || [ ! -f "$_G/2.out" ]; then why=run1-not-run
    elif ! grep -Eq '^FSUP1 end=exited code=0 sig=0 .* strays=0 pipes=eof why=none END$' "$_G/2.sup"; then why=run1-supervisor
    elif ! grep -Eq ' step=exit rc=0 code=0 reason=(reset_done|already_inactive) shown=0 ' "$_G/2.out"; then why=run1-not-reset
    elif ! tail -n 1 "$_G/2.out" | grep -Eq '^FSP1 .* step=eos rc=0 .* dropped=0 '; then why=run1-stream
    fi
}
gate_prev() {  # gate_prev PREVPH RUNNO: the previous run's accepted commit and clean close -> why (empty = go)
    _G=$D/$1
    why=
    if [ -e "$H/$1.skip" ] || [ ! -f "$_G/2.out" ]; then why=run$2-not-run
    elif ! grep -Eq '^FSUP1 end=exited code=0 sig=0 .* strays=0 pipes=eof why=none END$' "$_G/2.sup"; then why=run$2-supervisor
    elif ! grep -q ' step=commit rc=0 ' "$_G/2.out"; then why=run$2-no-accepted-commit
    elif [ "$2" = 2 ] && ! grep -Eq ' step=commit rc=0 attempt=[0-9]+ modeset=1 layout=quad_(vig|dma) ' "$_G/2.out"; then why=run2-not-quad
    elif ! grep -Eq ' step=hold_end rc=0 reason=deadline .* close_rc=0 ' "$_G/2.out"; then why=run$2-close-not-clean
    elif ! grep -q ' step=exit rc=0 code=0 reason=held_to_deadline shown=1 ' "$_G/2.out"; then why=run$2-exit
    elif ! tail -n 1 "$_G/2.out" | grep -Eq '^FSP1 .* step=eos rc=0 .* dropped=0 '; then why=run$2-stream
    fi
}
lit_phase() {  # lit_phase RUNNO PROBE_T: probe, gates, the pattern step (synchronous) or its skip step
    $SUP -t "$2" -g 1 -c 16384 -o "$S/1.out" -r "$S/1.err" -- /bin/busybox sh /lib/fs/fs-probe.sh "$PH" "$H" > "$S/1.sup" 2>/dev/null &
    P_PR=$!
    waitfor "$H/$PH.pre.done" $((TW * 10))
    bl=""; [ -f "$H/$PH.bl" ] && IFS= read -r -n 16 bl < "$H/$PH.bl"
    if [ -z "$why" ]; then
        if [ ! -e "$H/$PH.pre.done" ]; then why=probe-late
        elif [ "$bl" != 127 ]; then why=brightness-not-verified
        fi
    fi
    if [ -z "$why" ]; then
        case "$PH" in
            r1) $SUP -t 9 -g 3 -c 57344 -o "$S/2.out" -r "$S/2.err" -- /bin/fs-pattern reset "$d8" > "$S/2.sup" 2>/dev/null & ;;
            r2) $SUP -t 16 -g 3 -c 57344 -o "$S/2.out" -r "$S/2.err" -- /bin/fs-pattern show-off-quad "$d8" 10 /dev/dri/card0 "roll=$ROLL" "eyes=$EYES" > "$S/2.sup" 2>/dev/null & ;;
            r3) $SUP -t 11 -g 3 -c 28672 -o "$S/2.out" -r "$S/2.err" -- /bin/fs-pattern show-off-solid "$d8" 5 > "$S/2.sup" 2>/dev/null & ;;
        esac
        P_RUN=$!
        : > "$H/$PH.go"
        mark go
        wait "$P_RUN"
        endmark
    else
        : > "$H/$PH.skip"; : > "$H/$PH.go"
        mark skip
        skipstep 2 "$1" "$why"
    fi
    : > "$H/$PH.end"
    waitsup "$S/1.sup" "$P_PR" $((TQ * 10))
}

# ---- refusal checks, in the order of DESIGN §5.2 (ran=0: nothing of the phase has run) ----
# $D first (build review MINOR-1): a refusal before $D existed used to leave no $D/closed, so a later
# p0 was accepted after a malformed first command. The -L check below still refuses a symlinked $D.
if [ ! -d "$D" ] && [ ! -L "$D" ]; then mkdir -m 0700 "$D" 2>/dev/null; fi
[ $# -eq 3 ] || refuse 0 usage
case "$1" in p0|r1|r2|r3) ;; *) refuse 0 usage ;; esac
PH=$1
c=$2
prev=$3
case "$c" in ''|*[!0-9a-f]*) refuse 0 usage ;; esac
[ "${#c}" -eq 32 ] || refuse 0 usage
case "$prev" in ''|*[!0-9a-f]*) refuse 0 usage ;; esac
[ "${#prev}" -eq 16 ] || refuse 0 usage
n=""
[ -f /run/fs.nonce ] && read -r n < /run/fs.nonce
case "$n" in ''|*[!0-9a-f]*) refuse 0 bad-nonce ;; esac
[ "${#n}" -eq 16 ] || refuse 0 bad-nonce
[ -d "$D" ] && [ ! -L "$D" ] || refuse 0 order
[ -e "$D/closed" ] && refuse 0 order
case "$PH" in p0) pp= ;; r1) pp=p0 ;; r2) pp=r1 ;; r3) pp=r2 ;; esac
[ -z "$pp" ] || [ -f "$D/$pp.sha16" ] || refuse 0 order
mkdir -m 0700 "$D/$PH" 2>/dev/null || refuse 0 already-run
S=$D/$PH
if [ -z "$pp" ]; then want=0000000000000000; else want=""; read -r want < "$D/$pp.sha16"; fi
[ "$prev" = "$want" ] || refuse 0 chain
case "$PH" in p0) PW=$PHASE_WORST_p0; ML=$MAXLINES_p0 ;; r1) PW=$PHASE_WORST_r1; ML=$MAXLINES_r1 ;;
              r2) PW=$PHASE_WORST_r2; ML=$MAXLINES_r2 ;; r3) PW=$PHASE_WORST_r3; ML=$MAXLINES_r3 ;; esac
dl=""; [ -f /run/fs.deadline ] && read -r dl < /run/fs.deadline
_num "$dl"; dl=$_d
_u=""; read -r _u _r < /proc/uptime
_num "${_u%%.*}"; us=$_d
[ -n "$dl" ] && [ -n "$us" ] || refuse 0 time
[ $((dl - us)) -ge $((PW + HEADROOM)) ] || refuse 0 time
enc=0
if [ -f /lib/fs/fsb1-enc.sh ] && [ -f /lib/fs/fsb1-pace.sh ]; then
    . /lib/fs/fsb1-enc.sh
    # 20 lines per 0.1 s (the pinned pacer keeps a caller's value: ${FSB1_PACE_LINES:-10})
    FSB1_PACE_LINES=20
    . /lib/fs/fsb1-pace.sh
    enc=1
fi
REC=$S/record
[ "$enc" = 1 ] || refuse 0 begin
fsb1_begin "$REC" "s3d_$PH" "$n" "$c" 2 || refuse 0 begin

# ---- the phase: from here a refusal is ran=1 ----------------------------------------------------
LOCKED=1
activity
: > "$D/running"
mark begin
TICK=$S/.tick
mkfifo -m 600 "$TICK" 2>/dev/null
[ -d "$H" ] || mkdir -m 0700 "$H"
d8=${c:0:8}
why=
case "$PH" in
    p0)
        $SUP -t 2 -g 1 -c 256 -o "$S/1.out" -r "$S/1.err" -- /bin/busybox sha256sum /bin/fs-pattern > "$S/1.sup" 2>/dev/null &
        P_HASH=$!
        $SUP -t 8 -g 1 -c 16384 -o "$S/2.out" -r "$S/2.err" -- /bin/busybox sh /lib/fs/fs-probe.sh p0 "$H" > "$S/2.sup" 2>/dev/null &
        P_PR=$!
        wait "$P_HASH"
        wait "$P_PR"
        bl=""; [ -f "$H/p0.bl" ] && IFS= read -r -n 16 bl < "$H/p0.bl"
        wrc=""; [ -f "$H/p0.wrc" ] && IFS= read -r -n 16 wrc < "$H/p0.wrc"
        printf '%s\n' "${bl:-none}" > "$D/p0.bl"
        printf '%s\n' "${wrc:-none}" > "$D/p0.wrc"
        I1=hash; I2=probe0
        ;;
    r1)
        p0bl=""; [ -f "$D/p0.bl" ] && read -r p0bl < "$D/p0.bl"
        p0wrc=""; [ -f "$D/p0.wrc" ] && read -r p0wrc < "$D/p0.wrc"
        { [ "$p0bl" = 127 ] && [ "$p0wrc" = 0 ]; } || why=p0-write-missing
        lit_phase 1 24
        I1=probe1; I2=pattern1
        ;;
    r2)
        gate_reset
        if [ -z "$why" ]; then pause r1 || why=pause-fault; fi
        lit_phase 2 32
        I1=probe2; I2=pattern2
        ;;
    r3)
        gate_prev r2 2
        if [ -z "$why" ]; then pause r2 || why=pause-fault; fi
        lit_phase 3 26
        I1=probe3; I2=pattern3
        ;;
esac

# ---- the record: both steps, END, the sha16 from our own END line, then the paced emission ----
fsb1_step "$REC" 1 "$I1" "$S/1.sup" "$S/1.out" "$S/1.err" || refuse 1 step1
fsb1_step "$REC" 2 "$I2" "$S/2.sup" "$S/2.out" "$S/2.err" || refuse 1 step2
fsb1_end "$REC" "$n" "$c" || refuse 1 end
last=$(tail -n 1 "$REC")
h=${last##* rec_sha256=}
case "$h" in ''|*[!0-9a-f]*) refuse 1 end ;; esac
[ "${#h}" -eq 64 ] || refuse 1 end
lines=$(wc -l < "$REC" | tr -d ' ')
_num "$lines"
[ -n "$_d" ] || refuse 1 end
[ "$_d" -le "$ML" ] || refuse 1 "record-too-large lines=$_d max=$ML"
mark rec
fsb1_emit_paced "$REC" "$TICK" "$ML"
rc=$?
# every pacer failure after the rec marker is emit-<rc>, rc 3 included (build review NIT-1: the
# record-too-large check is the one BEFORE the marker, above; DESIGN §5.2)
case $rc in
    0) ;;
    *) refuse 1 "emit-$rc" ;;
esac
# after the record: files only, nothing on the tty
printf '%s\n' "${h:0:16}" > "$D/$PH.sha16"
activity
rm -f "$D/running"
exit 0
