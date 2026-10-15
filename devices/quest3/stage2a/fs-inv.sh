#!/bin/busybox sh
# FrameShift stage 2a — fs-inv: the read-only inventory step (FS-A-006 §5.1;
# decision J-49; common/OUTCOMES.md §2 step 8). INFORMATIONAL ONLY: it can
# never change the outcome class. Installed as /bin/fs-inv; run by fs-valve as
#   fs-supervise -t 10 -- /bin/busybox sh /bin/fs-inv
# with an empty environment (no PATH: every program is called by its path).
#
# Reads only, with busybox `cat` and `ls`; writes nothing (stdout is the
# supervisor's pipe). A missing path prints "(absent)" and a missing
# directory "(none)"; neither is an error. The script always exits 0; a read
# error (e.g. EIO from a driver) appears on stderr and is recorded as is.
# Note: reading a power_supply uevent calls into the drivers (on Unit 1 the
# bq27 gauge over I2C, which logs errors in stock Android too, FS-R-006 §4);
# that is why this step runs last and has its own 10 s timeout.
BB=/bin/busybox

show() {   # show FILE: its contents, or (absent)
    echo "-- $1"
    if [ -f "$1" ]; then $BB cat "$1"; else echo "(absent)"; fi
}

echo "== /proc/modules"
if [ -f /proc/modules ]; then $BB cat /proc/modules; else echo "(absent)"; fi

echo "== /sys/class/remoteproc"
n=0
for d in /sys/class/remoteproc/*; do
    [ -e "$d" ] || continue
    n=$((n + 1))
    show "$d/name"
    show "$d/state"
done
[ "$n" -gt 0 ] || echo "(none)"

echo "== /sys/bus/platform/devices/3000000.remoteproc-adsp/driver"
p=/sys/bus/platform/devices/3000000.remoteproc-adsp/driver
if [ -e "$p" ] || [ -L "$p" ]; then $BB ls -l "$p"; else echo "(absent)"; fi

echo "== /sys/class/power_supply"
n=0
for d in /sys/class/power_supply/*; do
    [ -e "$d" ] || continue
    n=$((n + 1))
    show "$d/uevent"
done
[ "$n" -gt 0 ] || echo "(none)"
echo "== end"
exit 0
