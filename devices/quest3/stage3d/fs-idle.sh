#!/bin/busybox sh
# FrameShift stage 3c — fs-idle.sh: the device-side idle limit (DESIGN.md §5.9).
# Installed in the image as /lib/fs/fs-idle.sh (build-image.sh, hash in MANIFEST).
# Started ONCE by init.sh (PID 1), before SHELL_READY, with stdin, stdout and
# stderr on /dev/null. It NEVER writes the tty and never touches DEADLINE.
#
# Rule: unarmed until /run/fsb3c/activity exists (fs-phase writes it at the start
# of p0). Then, once per second:
#   - no phase running (/run/fsb3c/running absent) and now - activity >= IDLE_S, or
#   - a phase "running" and now - activity >= STUCK_S (= IDLE_S + 60: a stuck runner)
#   -> write /run/fs.collected (token "idle") and exit. pid1-hold.sh (rev 5, pinned,
#      unchanged) reboots within about 1 s of seeing that file: the existing fs-done
#      path. It can only SHORTEN the hold.
# The loop forks NOTHING: `read -t 1` on a private FIFO (opened O_RDWR, so the open
# never blocks; nothing writes it, so the read times out) and builtin reads of
# /proc/uptime and of the activity file. Every number passes _num (digits only, no
# leading zero, at most 9 digits) before it reaches arithmetic: anything else is
# ignored for that second (the safe direction: DEADLINE and the backstop still cover).
# `sleep 1` (a fork) only if the FIFO could not be made.
exec 0</dev/null 1>/dev/null 2>/dev/null
set +eu
IDLE_S=120
STUCK_S=180
D=/run/fsb3c
OUT=/run/fs.collected
TICK=/run/.fs-idle-tick
mkfifo -m 600 "$TICK" 2>/dev/null

_num() {  # _num VALUE -> _d: canonical decimal (0 or [1-9][0-9]{0,8}) else empty
    case "$1" in
        0) _d=0 ;;
        ''|*[!0-9]*|0*) _d= ;;
        *) if [ ${#1} -le 9 ]; then _d=$1; else _d=; fi ;;
    esac
}

while :; do
    if [ -p "$TICK" ] && [ ! -L "$TICK" ]; then read -r -t 1 _x <> "$TICK"; else sleep 1; fi
    [ -f "$D/activity" ] && [ ! -L "$D/activity" ] || continue        # unarmed before p0
    _a=""; read -r -t 1 _a < "$D/activity"
    _num "$_a"; _act=$_d
    _u=""; read -r -t 1 _u _r < /proc/uptime
    _num "${_u%%.*}"; _now=$_d
    [ -n "$_act" ] && [ -n "$_now" ] || continue
    _lim=$IDLE_S
    [ -e "$D/running" ] && _lim=$STUCK_S
    if [ $((_now - _act)) -ge "$_lim" ]; then
        if [ ! -L "$OUT" ]; then printf 'idle\n' > "$OUT"; fi
        exit 0
    fi
done
