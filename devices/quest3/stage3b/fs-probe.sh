#!/bin/busybox sh
# FrameShift stage 3b — fs-probe.sh: the bounded, read-only probe helper of the
# display test, plus the ONE backlight write (FS-R-010 §4). Installed in the
# image as /lib/fs/fs-probe.sh (build-image.sh, hash in MANIFEST). Run ONLY by
# /bin/fs-display, each time as one FSB1 step under /bin/fs-supervise (empty
# environment, stdin /dev/null, stdout/stderr captured to RAM, -t/-c bounded):
#
#   fs-probe.sh run1 DIR     step 2 `probe1`: irq0 (init's sample), mods, the
#                            backlight write + read-back, pre1, mid1, post1
#   fs-probe.sh run2 DIR     step 4 `probe2`: read-back (no write), pre2, mid2, post2
#
# DIR (/run/fsb/h, RAM) carries the hand-shake with fs-display, all files in RAM:
#   written here:  pre1.bl / pre2.bl (the brightness read back), pre1.done / pre2.done,
#                  dmesg.last (timestamp of the newest dmesg line already shown)
#   read here:     go1 / go2 (the pattern step was started), skip1 / skip2 (it was
#                  not: no mid snapshot), end1 / end2 (the pattern step has ended:
#                  no mid snapshot any more, the post snapshot now)
#
# READ-ONLY, sysfs and /proc only. card0 (/dev/dri/*) is NEVER opened; debugfs is
# never mounted or read. The node list (README "Nodes"):
#   read:  /proc/uptime, /proc/interrupts (te-edge-isr, blu-pwm-isr lines),
#          /proc/cmdline (run1 mods only), the kernel log (busybox dmesg, never -c;
#            at mods, mid and post only),
#          /sys/class/drm/card0-*/{status,enabled,dpms} (at most 8 entries),
#          /sys/class/drm/card0-sde-crtc-0/{backlight_timing,backlight_event,
#            active_event,measured_fps,vsync_timing},
#          /sys/class/backlight/panel0-backlight/{brightness,actual_brightness,bl_power},
#          /sys/class/hwmon/hwmon*/name (at most 16), and for the one named
#            "pwmfan": rpm, pwm (the fan, read-only),
#          /sys/class/thermal/cooling_device*/type (at most 32), and for the one
#            of type "pwm-tach-fan0": cur_state (read-only),
#          /run/fs.irq0 (init's fork-free sample after MODULES_READY)
#   written (the ONLY write outside RAM, exactly once, run1 only, before run 1):
#          /sys/class/backlight/panel0-backlight/brightness = 127
# NEVER written or read: blu_default_duty, blu_max_overlap_us, fifo_trim,
# backlight_changes_blocked, debugfs, oculus,blu bootload/reset; no DCS.
#
# Bounds (README "Probe bounds"): every sysfs value is read with the `read`
# builtin, at most 120 bytes and one line (`read -n`); at most 4 interrupt lines
# of at most 200 bytes; the cmdline at most 2048 bytes; the dmesg section (only at
# mods, mid and post; NOT at pre1/pre2, so nothing slow runs right before a
# commit) at most 40 lines of at most 160 bytes and at most 1536 bytes in all.
# fs-supervise's -c (16384 / 12288) is the backstop: a longer output is cut there
# (out_kept < out_total), which is still a valid record; the backlight lines come
# early and survive any cut. stderr goes to /dev/null from the first command, so
# the step's stderr is empty (the record-size bound counts stdout only).
# Snapshots use builtins except dmesg|awk (2 processes) and the cmdline head (1).
exec 2>/dev/null
PATH=/bin
export PATH
MODE=$1
H=$2
case "$MODE" in run1|run2) ;; *) echo "FSPR1 error=usage END"; exit 2 ;; esac
[ -d "$H" ] && [ ! -L "$H" ] || { echo "FSPR1 error=no-dir END"; exit 2; }
BL=/sys/class/backlight/panel0-backlight
CR=/sys/class/drm/card0-sde-crtc-0
TICK=$H/.tick-$MODE
mkfifo -m 600 "$TICK" 2>/dev/null

tick() { if [ -p "$TICK" ]; then read -r -t 0.1 _x <> "$TICK"; else sleep 0.1; fi; }
pause_unless() {   # pause_unless FILE TENTHS: wait TENTHS/10 s, but stop early if FILE appears; 0 = full pause
    _n=0
    while [ "$_n" -lt "$2" ]; do
        [ -e "$1" ] && return 1
        tick; _n=$((_n + 1))
    done
    [ ! -e "$1" ]
}
await() {          # await FILE TENTHS: until FILE exists or the time is up; 0 if it exists
    _n=0
    while [ ! -e "$1" ] && [ "$_n" -lt "$2" ]; do tick; _n=$((_n + 1)); done
    [ -e "$1" ]
}
up() { read -r _u _r < /proc/uptime; echo "$_u"; }
rd() {             # rd FILE MAXBYTES: one line, at most MAXBYTES bytes, read by the builtin
    if [ -e "$1" ]; then
        _v=""
        IFS= read -r -n "$2" _v < "$1" 2>/dev/null
        [ -n "$_v" ] && echo "$_v" || echo "(unreadable-or-empty)"
    else
        echo "(absent)"
    fi
}
irq() {            # the TE and BLU-PWM interrupt lines (at most 4, 200 bytes each), builtins only
    _k=0
    while IFS= read -r _l; do
        case "$_l" in *te-edge-isr*|*blu-pwm-isr*) _k=$((_k + 1)); [ "$_k" -le 4 ] && echo "${_l:0:200}" ;; esac
    done < /proc/interrupts
    [ "$_k" -gt 0 ] || echo "(no te-edge-isr / blu-pwm-isr line)"
    echo "-- at $(up)"
}
dmesg_new() {      # filtered kernel log: newer than the last shown line, the last 40, <= 160 B each, <= 1536 B
    _last=""
    [ -f "$H/dmesg.last" ] && IFS= read -r -n 32 _last < "$H/dmesg.last"
    case "$_last" in ''|*[!0-9.]*) _last=0 ;; esac
    dmesg 2>/dev/null | awk -v t="$_last" -v f="$H/dmesg.last.new" '
        { l = tolower($0) }
        l !~ /dsi|sde|drm|blu|splash|panel|backlight|bl_|warn/ { next }
        { ts = -1
          if (match($0, /^\[ *[0-9]+\.[0-9]+\]/)) { s = substr($0, 2, RLENGTH - 2); ts = s + 0; if (ts > m) m = ts }
          if (ts >= 0 && ts <= t) next
          r[n % 40] = substr($0, 1, 160); n++ }
        END { k = n < 40 ? n : 40; tot = 0; first = n - k
              for (i = n - 1; i >= n - k; i--) { tot += length(r[i % 40]) + 1; if (tot > 1536) { first = i + 1; break } }
              for (i = first; i < n; i++) print r[i % 40]
              printf "-- dmesg: %d new matching line(s), %d shown\n", n, n - first
              if (m > t) printf "%.6f\n", m > f; else printf "%s\n", t > f }'
    [ -f "$H/dmesg.last.new" ] && mv "$H/dmesg.last.new" "$H/dmesg.last"
}
snap() {           # snap POINT [pair]: one bounded snapshot
    echo "== point $1 run=$MODE up=$(up)"
    echo "-- irq"
    irq
    if [ "$2" = pair ]; then _n=0; while [ "$_n" -lt 5 ]; do tick; _n=$((_n + 1)); done; echo "-- irq (+0.5 s)"; irq; fi
    echo "-- drm connectors"
    _k=0
    for c in /sys/class/drm/card0-*; do
        [ -e "$c/status" ] || [ -e "$c/enabled" ] || [ -e "$c/dpms" ] || continue
        _k=$((_k + 1)); [ "$_k" -le 8 ] || break
        echo "${c##*/} status=$(rd "$c/status" 32) enabled=$(rd "$c/enabled" 32) dpms=$(rd "$c/dpms" 32)"
    done
    [ "$_k" -gt 0 ] || echo "(no card0-* connector nodes)"
    echo "-- crtc-0"
    for f in backlight_timing backlight_event active_event measured_fps vsync_timing; do
        echo "$f=$(rd "$CR/$f" 120)"
    done
    echo "-- backlight"
    echo "brightness=$(rd "$BL/brightness" 16) actual_brightness=$(rd "$BL/actual_brightness" 16) bl_power=$(rd "$BL/bl_power" 16)"
    echo "-- fan"
    _k=0; _f=0
    for h in /sys/class/hwmon/hwmon*; do
        _k=$((_k + 1)); [ "$_k" -le 16 ] || break
        [ -e "$h/name" ] || continue
        if [ "$(rd "$h/name" 32)" = pwmfan ]; then
            _f=1; echo "${h##*/} name=pwmfan rpm=$(rd "$h/rpm" 16) pwm=$(rd "$h/pwm" 16)"
        fi
    done
    [ "$_f" = 1 ] || echo "(no hwmon named pwmfan)"
    _k=0; _f=0
    for d in /sys/class/thermal/cooling_device*; do
        _k=$((_k + 1)); [ "$_k" -le 32 ] || break
        [ -e "$d/type" ] || continue
        if [ "$(rd "$d/type" 32)" = pwm-tach-fan0 ]; then
            _f=1; echo "${d##*/} type=pwm-tach-fan0 cur_state=$(rd "$d/cur_state" 16)"
        fi
    done
    [ "$_f" = 1 ] || echo "(no cooling device pwm-tach-fan0)"
    if [ "$1" = mods ]; then
        echo "-- cmdline (<= 2048 bytes)"
        head -c 2048 /proc/cmdline 2>/dev/null; echo
    fi
    case "$1" in
        pre*) echo "-- dmesg: not read at $1 (it is read at mods, mid and post)" ;;
        *) echo "-- dmesg (new matching lines, last 40, <= 160 bytes each, <= 1536 bytes)"; dmesg_new ;;
    esac
    echo "== end $1 up=$(up)"
}

echo "FSPR1 helper=$MODE start up=$(up)"
if [ "$MODE" = run1 ]; then
    echo "== irq0 (init, after MODULES_READY)"
    if [ -f /run/fs.irq0 ]; then head -c 1024 /run/fs.irq0; else echo "(absent)"; fi
    snap mods
    # THE backlight write (FS-R-010 §4): exactly once, the normal backlight node, value 127
    echo "== backlight-write node=$BL/brightness value=127 up=$(up)"
    if [ -f "$BL/brightness" ]; then
        if echo 127 > "$BL/brightness" 2>/dev/null; then wrc=0; else wrc=1; fi
    else
        wrc=nonode
    fi
    v=""; [ -f "$BL/brightness" ] && IFS= read -r -n 16 v < "$BL/brightness"
    echo "write_rc=$wrc readback=${v:-none}"
    echo "${v:-none}" > "$H/pre1.bl"
    snap pre1
    : > "$H/pre1.done"
    N=1; MID=15
else
    echo "== backlight-verify node=$BL/brightness (read only) up=$(up)"
    v=""; [ -f "$BL/brightness" ] && IFS= read -r -n 16 v < "$BL/brightness"
    echo "readback=${v:-none}"
    echo "${v:-none}" > "$H/pre2.bl"
    snap pre2
    : > "$H/pre2.done"
    N=2; MID=50
fi
# the pattern step: started (go) or skipped (skip); the mid snapshot only while it runs;
# bounded waits (fs-display kills a helper that is late after the run has ended)
if await "$H/go$N" 300; then
    if [ ! -e "$H/skip$N" ] && pause_unless "$H/end$N" "$MID"; then
        snap "mid$N" pair
    fi
else
    echo "== no go$N marker within 30 s"
fi
if await "$H/end$N" 300; then snap "post$N"; else echo "== no end$N marker within 30 s"; fi
echo "FSPR1 helper=$MODE end up=$(up)"
exit 0
