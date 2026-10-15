#!/bin/busybox sh
# FrameShift common — PID 1 hold and deadline logic (busybox ash; sourced by
# the stage-2a/3a init, never run on its own). Design: DEADLINE.md.
# Revision 2: review fixes B1 (FIFO stops both timers), S5 (fork failure).
# Revision 3: PID 1 reboots by exec of fs-reboot-final (no fork).
# Revision 5: fix round 6 (N2): magenta LED before the no-host-ack reboot (stage 1 had it).
# Revision 4: second review S1 (the clock is a replaceable file; leading
#   zeros made ash arithmetic abort PID 1): strict number parsing, a second
#   file-independent clock (loop-iteration counter), `set +eu`.
#
# Rules this file enforces (FS-R-006 §5 D):
#   - The deadline is fixed once, from PID 1's own start (T0). Nothing here
#     can extend or cancel it: no `kill`; HOST_ACK is only recorded.
#     The uptime FILE can lie (e.g. a bind-mounted frozen /proc/uptime): then
#     the primary clock is wrong, but the loop-iteration counter (no file)
#     and the backstop's sleep (kernel timer, no file) still reboot. A forged
#     clock can make the counter EARLIER only (it starts from the clock's
#     elapsed time if that is sane, else from 0).
#   - Every number that reaches $(( )) or [ -lt ] has passed _fs_num: digits
#     only, no leading zero (ash reads 09 as bad octal -> "arithmetic syntax
#     error" -> the shell exits -> for PID 1 a kernel panic), at most 9
#     digits. Anything else takes the caller's fail-safe fallback.
#   - Host input can only SHORTEN the hold (fs.collected; no ack in time).
#   - REBOOT FIRST: nothing under /run or /dev is opened or written on the
#     way to the reboot syscall. PID 1 execs fs-reboot-final (never exits);
#     the backstop child fork-execs fs-reboot.
#   - Never block on a host-writable path: files are read only after `[ -f ]`
#     (host_ack, clock) or `[ -p ]` (tick, read with `read -t 1 <>`); appends
#     go only to regular or new files. Residual: a file swapped (FIFO,
#     device) between the type test and the open can still stall the loop;
#     the backstop (writes nothing, reads nothing) then still reboots.
#   - Fork-free loop: `read` builtin for the clock, `read -t 1` on a private
#     FIFO for the pause; `sleep` only if that FIFO is gone.
#   - `set +eu`: a nonzero `read -t` or an unset variable must never end PID 1.
#
# The caller provides: log MSG (used only before SHELL_READY), led R G B
# (fork-free, sysfs only), and the variables
#   FS_RUN=/run  FS_UPTIME=/proc/uptime
#   FS_REBOOT_FINAL=/bin/fs-reboot-final (PID 1 execs it: never exits; args ignored)
#   FS_REBOOT_BIN=/bin/fs-reboot        (backstop child; argument-free helper; extra args ignored)
#   FS_REBOOT_FALLBACK="reboot -f"

FS_DEADLINE_MAX=299          # backstop = deadline + 1 <= 300 s (FS-R-006 §5 D ceiling)

_fs_num() {  # _fs_num VALUE FALLBACK -> _fs_d: canonical decimal (0 or [1-9][0-9]{0,8}) else FALLBACK
    case "$1" in
        0) _fs_d=0 ;;
        ''|*[!0-9]*|0*) _fs_d=$2 ;;
        *) if [ ${#1} -le 9 ]; then _fs_d=$1; else _fs_d=$2; fi ;;
    esac
}
_fs_digits_or() { _fs_num "$1" "$2"; }
_fs_now() {  # _fs_now FALLBACK: sets _fs_t to whole seconds of uptime. No fork.
    _fs_t=""
    if [ -f "$FS_UPTIME" ]; then read -r -t 1 _fs_t _fs_rest < "$FS_UPTIME" 2>/dev/null; fi
    _fs_num "${_fs_t%%.*}" "$1"; _fs_t=$_fs_d
}
_fs_put() {  # _fs_put FILE TEXT: append, only to a regular file or a new name; never a FIFO/device
    if [ -L "$1" ]; then return 0; fi
    if [ -f "$1" ] || [ ! -e "$1" ]; then printf '%s\n' "$2" >> "$1"; fi 2>/dev/null
    return 0
}
_fs_wait() {  # about one second, without forking
    if [ -p "$FS_TICK" ] && [ ! -L "$FS_TICK" ]; then
        read -r -t 1 _fs_x <> "$FS_TICK" 2>/dev/null
    else
        sleep 1 2>/dev/null
    fi
    return 0
}

fs_reboot() {  # fs_reboot REASON (backstop child): the reboot syscall comes before any file access
    "$FS_REBOOT_BIN" "$1"
    $FS_REBOOT_FALLBACK
    _fs_put "$FS_RUN/fs.log" "FS REBOOT_RETURNED reason=$1"      # only if both failed
    while :; do _fs_wait; done
}

fs_reboot_pid1() {  # fs_reboot_pid1 REASON (PID 1 itself): exec, no fork
    # fs-reboot-final never exits: RESTART2 "bootloader", then RESTART, then
    # sleeps for ever. A FAILED exec would end this shell (ash exits with 127),
    # i.e. kill PID 1, so exec only a regular executable file; otherwise fall
    # back to the forking path.
    if [ -f "$FS_REBOOT_FINAL" ] && [ -x "$FS_REBOOT_FINAL" ] && [ ! -L "$FS_REBOOT_FINAL" ]; then
        exec "$FS_REBOOT_FINAL" "$1"
    fi
    fs_reboot "$1"
}

fs_hold_init() {  # fs_hold_init DEADLINE_S ACK_WINDOW_S: first thing in PID 1, before any host shell
    set +eu
    _fs_num "$1" "$FS_DEADLINE_MAX"; FS_DEADLINE=$_fs_d
    [ "$FS_DEADLINE" -le "$FS_DEADLINE_MAX" ] || FS_DEADLINE=$FS_DEADLINE_MAX
    _fs_num "$2" 150; FS_ACK_WINDOW=$_fs_d
    [ "$FS_ACK_WINDOW" -le "$FS_DEADLINE" ] || FS_ACK_WINDOW=$FS_DEADLINE
    _fs_now 0; T0=$_fs_t
    FS_TICK=$FS_RUN/.fs-tick
    mkfifo -m 600 "$FS_TICK" 2>/dev/null
    log "DEADLINE armed t0=$T0 deadline=T0+$FS_DEADLINE ack_window=$FS_ACK_WINDOW backstop=T0+$((FS_DEADLINE + 1)) reboot-reasons-not-logged-at-reboot"
}

fs_start_backstop() {  # at INIT_STARTED; an independent second timer that writes nothing
    _fs_now 999999
    _left=$((T0 + FS_DEADLINE + 1 - _fs_t))
    [ "$_left" -ge 0 ] || _left=0
    ( sleep "$_left"; fs_reboot backstop ) &
    FS_BACKSTOP_PID=$!         # recorded for the log only; never signalled
    log "BACKSTOP armed pid=$FS_BACKSTOP_PID in=${_left}s"
}

fs_hold_loop() {  # after SHELL_READY; never returns
    set +eu
    _fs_now 0; _s0=$_fs_t
    # second clock: one count per iteration (each about 1 s, never less unless
    # the host writes into the tick FIFO, which only makes it EARLIER). It
    # starts from the elapsed time the clock reports now, if that is sane.
    _fs_n=$((_s0 - T0))
    [ "$_fs_n" -ge 0 ] || _fs_n=0
    _acked=""; _rej=""
    while :; do
        _fs_now 999999
        if [ $((_fs_t - T0)) -ge "$FS_DEADLINE" ]; then fs_reboot_pid1 deadline; fi
        if [ "$_fs_n" -ge "$FS_DEADLINE" ]; then fs_reboot_pid1 deadline-ticks; fi
        if [ -e "$FS_RUN/fs.collected" ] || [ -L "$FS_RUN/fs.collected" ]; then fs_reboot_pid1 collected; fi
        if [ -z "$_acked" ]; then
            _a=""
            if [ -f "$FS_RUN/host_ack" ] && [ ! -L "$FS_RUN/host_ack" ]; then
                read -r -t 1 _a <> "$FS_RUN/host_ack" 2>/dev/null
            fi
            case "$_a" in
                '') ;;
                *[!0-9a-f]*) if [ "$_a" != "$_rej" ]; then _rej=$_a; _fs_put "$FS_RUN/fs.log" "FS t=${_fs_t}s HOST_ACK_REJECTED malformed"; fi ;;
                *) if [ ${#_a} -le 64 ]; then
                       _acked=$_a
                       _fs_put "$FS_RUN/fs.acked" "$_a"
                       _fs_put "$FS_RUN/fs.stages" HOST_ACK
                       _fs_put "$FS_RUN/fs.log" "FS t=${_fs_t}s STAGE=HOST_ACK ack=$_a deadline-unchanged=T0+$FS_DEADLINE"
                       led 255 255 255
                   fi ;;
            esac
            # Revision 5 (fix round 6, N2): the stage-1 magenta LED for "no host ack" is restored.
            # `led` is the caller's fork-free sysfs writer; /sys/class/leds cannot hold a FIFO, so this
            # keeps "reboot first" for every path a host can tamper with (nothing under /run or /dev).
            if [ -z "$_acked" ] && [ $((_fs_t - _s0)) -ge "$FS_ACK_WINDOW" ]; then led 255 0 255; fs_reboot_pid1 no-host-ack; fi
        fi
        _fs_wait
        _fs_n=$((_fs_n + 1))
    done
}
