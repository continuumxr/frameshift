#!/bin/busybox sh
# FrameShift stage 3c — fs-probe.sh: the bounded, read-only probe helper of the
# per-phase display run, plus the ONE backlight write (DESIGN.md §7; derived from
# stage3b/fs-probe.sh, which is unchanged).
# Stage 3d (J-141), the ONE change vs stage3c/fs-probe.sh: in the dmesg section the v2.7
# mode-validation lines (dsi_conn_mode_valid "could not find mode <w>x<h>x<r>vid" and
# dsi_display_find_mode "failed to find mode for v_active ..."; 66 per connector probe on
# v2.7, informational) are not kept; one summary line gives their count per point, so the
# panel/DSI/backlight lines stay within the 80-line / 4096-byte budget. Installed in the image as
# /lib/fs/fs-probe.sh (build-image.sh, hash in MANIFEST). Run ONLY by /bin/fs-phase,
# each time as one FSB1 step under /bin/fs-supervise (empty environment, stdin
# /dev/null, stdout/stderr captured to RAM, -t/-c bounded):
#
#   fs-probe.sh p0 DIR    phase p0, step 2 `probe0`: irq0 (init's sample), mods (irq,
#                         nodes, cmdline, dmesg), THE backlight write + read-back.
#                         No go/end wait.
#   fs-probe.sh r1 DIR    phase r1, step 1 `probe1`: read-back (no write), pre, then
#   fs-probe.sh r2 DIR    the TE/BLU sample at go + 1.0 s, the mid pair (mid and
#   fs-probe.sh r3 DIR    mid + 0.5 s; mid at 1.5 / 5 / 2.5 s after go), the sample at
#                         end (immediately), post.
#
# DIR (/run/fsb3c/h, RAM) carries the hand-shake with fs-phase, all files in RAM:
#   written here:  p0.bl (the brightness read back after the write), p0.wrc (write rc),
#                  <ph>.bl (the read-back of phase ph), <ph>.pre.done (pre has FINISHED),
#                  dmesg.last (timestamp of the newest dmesg line already shown)
#   read here:     <ph>.go (the pattern step was started), <ph>.skip (it was not: no
#                  go+1/mid sample), <ph>.end (the pattern step has ended: the end
#                  sample now, then post)
#
# READ-ONLY, sysfs and /proc only. card0 (/dev/dri/*) is NEVER opened; debugfs is
# NEVER mounted, listed or read (PM decision J-109 #2). The node list (unchanged from
# stage 3b):
#   read:  /proc/uptime, /proc/interrupts (te-edge-isr, blu-pwm-isr lines),
#          /proc/cmdline (p0 mods only), the kernel log (busybox dmesg, never -c;
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
#   written (the ONLY write outside RAM, exactly once per boot, p0 only):
#          /sys/class/backlight/panel0-backlight/brightness = 127
# NEVER written or read: blu_default_duty, blu_max_overlap_us, fifo_trim,
# backlight_changes_blocked, debugfs, oculus,blu bootload/reset; no DCS.
#
# Bounds: every sysfs value is read with the `read` builtin, at most 120 bytes and
# one line (`read -n`); at most 4 interrupt lines of at most 200 bytes per sample;
# the cmdline at most 2048 bytes; the dmesg section (only at mods, mid and post;
# NEVER at pre, so nothing slow runs right before a commit) filtered
# (case-insensitive) dsi|sde|drm|blu|splash|panel|backlight|bl_|warn|smmu|fault|
# underrun|iommu|timeout|esd|dsc, only lines newer than the previous point, the
# last 80, each at most 200 bytes, at most 4096 bytes in all. fs-supervise's -c
# (16384) is the backstop: a longer output is cut there (out_kept < out_total),
# which is still a valid record; the backlight lines come early and survive any
# cut. stderr goes to /dev/null from the first command, so the step's stderr is
# empty (the record-size bound counts stdout only). Snapshots use builtins except
# dmesg|awk (2 processes) and the cmdline head (1).
exec 2>/dev/null
PATH=/bin
export PATH
MODE=$1
H=$2
case "$MODE" in p0|r1|r2|r3) ;; *) echo "FSPR1 error=usage END"; exit 2 ;; esac
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
irqpoint() {       # irqpoint NAME: one interrupt sample on its own (DESIGN §7: go+1, end), in the layout of snap
    echo "== point $1 run=$MODE up=$(up)"
    echo "-- irq"
    irq
    echo "== end $1 up=$(up)"
}
dmesg_new() {      # filtered kernel log: newer than the last shown line, the last 80, <= 200 B each, <= 4096 B
    _last=""
    [ -f "$H/dmesg.last" ] && IFS= read -r -n 32 _last < "$H/dmesg.last"
    case "$_last" in ''|*[!0-9.]*) _last=0 ;; esac
    dmesg 2>/dev/null | awk -v t="$_last" -v f="$H/dmesg.last.new" '
        { l = tolower($0) }
        l !~ /dsi|sde|drm|blu|splash|panel|backlight|bl_|warn|smmu|fault|underrun|iommu|timeout|esd|dsc/ { next }
        { ts = -1
          if (match($0, /^\[ *[0-9]+\.[0-9]+\]/)) { s = substr($0, 2, RLENGTH - 2); ts = s + 0; if (ts > m) m = ts }
          if (ts >= 0 && ts <= t) next
          if (l ~ /dsi_conn_mode_valid.*could not find mode / || l ~ /dsi_display_find_mode.*failed to find mode for v_active /) { mv++; next }
          r[n % 80] = substr($0, 1, 200); n++ }
        END { k = n < 80 ? n : 80; tot = 0; first = n - k
              for (i = n - 1; i >= n - k; i--) { tot += length(r[i % 80]) + 1; if (tot > 4096) { first = i + 1; break } }
              for (i = first; i < n; i++) print r[i % 80]
              printf "-- dmesg: %d new matching line(s), %d shown\n", n, n - first
              printf "-- dmesg: %d mode-validation line(s) not kept (dsi_conn_mode_valid / dsi_display_find_mode)\n", mv
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
        *) echo "-- dmesg (new matching lines, last 80, <= 200 bytes each, <= 4096 bytes)"; dmesg_new ;;
    esac
    echo "== end $1 up=$(up)"
}

echo "FSPR1 helper=$MODE start up=$(up)"
if [ "$MODE" = p0 ]; then
    echo "== irq0 (init, after MODULES_READY)"
    if [ -f /run/fs.irq0 ]; then head -c 1024 /run/fs.irq0; else echo "(absent)"; fi
    snap mods
    # THE backlight write (DESIGN §7, §10): exactly once per boot, the normal backlight node, value 127.
    # fs-phase runs p0 at most once per boot (mkdir /run/fsb3c/p0), so this line runs at most once.
    echo "== backlight-write node=$BL/brightness value=127 up=$(up)"
    if [ -f "$BL/brightness" ]; then
        if echo 127 > "$BL/brightness" 2>/dev/null; then wrc=0; else wrc=1; fi
    else
        wrc=nonode
    fi
    v=""; [ -f "$BL/brightness" ] && IFS= read -r -n 16 v < "$BL/brightness"
    echo "write_rc=$wrc readback=${v:-none}"
    echo "${v:-none}" > "$H/p0.bl"
    echo "$wrc" > "$H/p0.wrc"
    echo "FSPR1 helper=$MODE end up=$(up)"
    exit 0
fi
case "$MODE" in r1) MID=15 ;; r2) MID=50 ;; r3) MID=25 ;; esac
echo "== backlight-verify node=$BL/brightness (read only) up=$(up)"
v=""; [ -f "$BL/brightness" ] && IFS= read -r -n 16 v < "$BL/brightness"
echo "readback=${v:-none}"
echo "${v:-none}" > "$H/$MODE.bl"
snap pre
: > "$H/$MODE.pre.done"
# the pattern step: started (go) or skipped (skip); go+1 and mid only while it runs;
# bounded waits (fs-phase kills a helper that is late after the run has ended)
if await "$H/$MODE.go" 300; then
    if [ ! -e "$H/$MODE.skip" ]; then
        if pause_unless "$H/$MODE.end" 10; then
            irqpoint go+1
            if pause_unless "$H/$MODE.end" $((MID - 10)); then
                snap mid pair
            fi
        fi
    fi
else
    echo "== no go marker within 30 s"
fi
if await "$H/$MODE.end" 300; then
    [ -e "$H/$MODE.skip" ] || irqpoint end
    snap post
else
    echo "== no end marker within 30 s"
fi
echo "FSPR1 helper=$MODE end up=$(up)"
exit 0
