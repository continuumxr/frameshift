#!/bin/busybox sh
# FrameShift — Quest 3 stage-3a init (runs as PID 1): the display test, one
# static fs-pattern image (stage3a/README.md, v0.4, 10 s hold cap) on the
# stock kernel. A separate image from stage 2a; no Valve file is in it.
#
# = the PROVEN stage-1 init (devices/quest3/stage1/init.sh, image efefe10d…)
#   for bring-up: minimal mounts and nodes, Meta's 97 recovery modules in
#   Android first-stage order, USB role writes, the CDC-ACM gadget with the
#   nonce as serial, fs-verify / fs-ack / fs-status, the shell on ttyGS0;
# + the common PID 1 deadline (devices/quest3/common/target/pid1-hold.sh,
#   DEADLINE.md): fixed at PID 1 start, NOT cancelled or extended by HOST_ACK
#   (only recorded), a backstop child, immediate reboot when the host runs
#   fs-done, PID 1's own reboots by exec of /bin/fs-reboot-final;
# + /dev/dri/card0 created after MODULES_READY if sysfs reports 226:0;
# + /bin/fs-display (fs-display.sh): hash of /bin/fs-pattern, then
#   fs-pattern show <chal[0:8]> 10 under /bin/fs-supervise (stdout to a RAM
#   file), one FSB1 record on the tty.
#
# Differences from stage 1 (each deliberate; IMAGE.md "Changes from stage 1"):
#   - stage-1 dead-man subshell + HOST_ACK kill + hold  -> fs_hold_init,
#     fs_start_backstop, fs_hold_loop (FS-R-006 §5 D);
#   - DEADLINE 170 s (backstop 171 s; stage 1: a 300 s dead-man): sized so the host's
#     worst-case budget fits (IMAGE.md "Timing", ../stage2a/tools/check-timing.py);
#     ACK_WINDOW 150 s and ERR_DELAY 60 s are stage 1's values (unchanged).
#     PANELS: fs-pattern holds its frame <= 10 s (<= 15 s if it stalls), then closes the
#     DRM fd. That the close turns the panels OFF is derived from the v2.7 driver source
#     [D]; for the v66 driver it is open [O]. Worst case: the panels stay powered (black,
#     backlight at the boot level) until the PID 1 reboot, at most T0+171 s. The PM
#     confirms they are dark before fs-done (the collector pauses 3 s for it);
#   - no-host-ack: magenta LED, as stage 1 (now in common pid1-hold.sh rev 5);
#   - fail(): logs, waits until T0 + ERR_DELAY, then exec fs-reboot-final
#     (stage 1 forked fs-reboot, which exits 1 as PID 1 = panic if the syscall fails);
#   - no `sync` before the reboot: nothing persistent is mounted (common/DEADLINE.md §2.3);
#   - the DRM node step after MODULES_READY;
#   - gadget product string "FrameShift stage3a".
# Rules kept: PID 1 never exits; no block device is mounted or opened; records
# go to RAM (/run) first; nothing in logging or recovery writes the USB tty.
#
# The NONCE placeholder below is replaced by build-image.sh with a fresh per-attempt value.

NONCE="@NONCE@"
DEADLINE=170
ACK_WINDOW=150
ERR_DELAY=60
UDC_NAME=a600000.dwc3
SSUSB=/sys/devices/platform/soc/a600000.ssusb
G=/config/usb_gadget/fs
BB=/bin/busybox

# ---------------------------------------------------------------------------
# 0. Minimal environment (stage 1 §0, unchanged). DEVTMPFS=n: populate /dev.
# ---------------------------------------------------------------------------
$BB mkdir -p /proc /sys /dev /run /tmp /config /bin /sbin
$BB mount -t proc  proc  /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t tmpfs -o mode=0755,size=4m tmpfs /dev
$BB mount -t tmpfs -o mode=0755,size=4m tmpfs /run
$BB mknod -m 600 /dev/console c 5 1
$BB mknod -m 666 /dev/null    c 1 3
$BB mknod -m 600 /dev/kmsg    c 1 11
exec 0</dev/null 1>/dev/null 2>/dev/null
$BB --install -s /bin
export PATH=/bin:/sbin
: > /run/fs.log
: > /run/fs.stages
echo "$NONCE" > /run/fs.nonce

up() { cut -d. -f1 /proc/uptime; }

log() {       # RAM first; kmsg/pmsg best-effort; never the USB tty (pre-shell only)
    msg="FS[$NONCE] t=$(up)s $*"
    echo "$msg" >> /run/fs.log
    [ -c /dev/kmsg ]  && echo "$msg" > /dev/kmsg
    [ -c /dev/pmsg0 ] && echo "$msg" > /dev/pmsg0
    return 0
}
stage() {     # stage NAME [detail]
    echo "$1" >> /run/fs.stages
    log "STAGE=$1 $2"
}
led() {       # led <red> <green> <blue>: sysfs writes with builtins only (fork-free)
    for c in red green blue; do
        v=$1; shift
        [ -w /sys/class/leds/$c/brightness ] && echo "$v" > /sys/class/leds/$c/brightness
    done
    return 0
}

# ---------------------------------------------------------------------------
# 1. The deadline: fixed now, before any module, gadget or host shell.
#    If the common file were missing, `.` would end this shell (PID 1): reboot
#    instead (the builder makes this unreachable).
# ---------------------------------------------------------------------------
if [ ! -f /lib/fs/pid1-hold.sh ]; then
    /bin/fs-reboot; reboot -f; while :; do sleep 3600; done
fi
. /lib/fs/pid1-hold.sh
FS_RUN=/run
FS_UPTIME=/proc/uptime
FS_REBOOT_FINAL=/bin/fs-reboot-final
FS_REBOOT_BIN=/bin/fs-reboot
FS_REBOOT_FALLBACK="reboot -f"
fs_hold_init "$DEADLINE" "$ACK_WINDOW"

fail() {      # fail <stage> <detail>: pre-shell only. Record, wait out ERR_DELAY from T0, reboot.
    log "ERROR stage=$1 $2"
    echo "ERROR_$1" >> /run/fs.stages
    led 255 0 0
    while [ $(( $(up) - T0 )) -lt "$ERR_DELAY" ]; do sleep 1; done
    log "REBOOT reason=error-$1"
    fs_reboot_pid1 "error-$1"
}

mdev -s
stage INIT_STARTED "pid=$$ kernel=$(uname -r) deadline=T0+$FS_DEADLINE"
fs_start_backstop

# ---------------------------------------------------------------------------
# 2. Modules (stage 1 §2, unchanged): Meta's recovery set, softdep pre:, the
#    modules.dep closure in reverse, the module, softdep post:, each once.
# ---------------------------------------------------------------------------
MD=/lib/modules
LOADED=" "
ok=0; bad=0

modfile() {
    n=${1##*/}; n=${n%.ko}
    for c in "$n" "$(echo "$n" | tr '_' '-')" "$(echo "$n" | tr '-' '_')"; do
        [ -f "$MD/$c.ko" ] && { echo "$MD/$c.ko"; return 0; }
    done
    return 1
}

softdeps() {
    name=$(basename "$2" .ko | tr '-' '_')
    line=$(grep "^softdep $name " "$MD/modules.softdep" 2>/dev/null)
    [ -n "$line" ] || return 0
    if [ "$1" = pre ]; then part=${line#*pre:}; part=${part%%post:*}
    else case "$line" in *post:*) part=${line#*post:} ;; *) part="" ;; esac
    fi
    for s in $part; do modfile "$s"; done
}

load_mod() {
    case "$LOADED" in *" $1 "*) return 0 ;; esac
    LOADED="$LOADED$1 "
    for d in $(softdeps pre "$1"); do load_mod "$d"; done
    for d in $(sed -n "s#^$1: ##p" "$MD/modules.dep" | tr ' ' '\n' | sed -n '1!G;h;$p'); do
        load_mod "$d"
    done
    if out=$(insmod "$1" 2>&1); then
        ok=$((ok + 1))
    else
        bad=$((bad + 1)); log "MODULE_FAIL ${1##*/}: $out"
    fi
    for d in $(softdeps post "$1"); do load_mod "$d"; done
}

[ -w /sys/class/firmware/timeout ] && echo 1 > /sys/class/firmware/timeout
log "FW_TIMEOUT=$(cat /sys/class/firmware/timeout 2>/dev/null)"

for m in $(cat "$MD/modules.load.recovery"); do
    load_mod "$MD/$m"
done
sleep 3
mdev -s
led 255 160 0
stage MODULES_READY "ok=$ok fail=$bad udc=$(ls /sys/class/udc 2>/dev/null | tr '\n' ' ') drm=$(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 2a. DRM node (stage3a/README.md integration step 1). DEVTMPFS=n; mdev may
#     already have made it. Only major:minor 226:0, as sysfs reports it.
#     fs-pattern itself opens only a character device with major 226.
# ---------------------------------------------------------------------------
dv=$(cat /sys/class/drm/card0/dev 2>/dev/null)
if [ ! -c /dev/dri/card0 ] && [ "$dv" = "226:0" ]; then
    mkdir -p /dev/dri && mknod -m 600 /dev/dri/card0 c 226 0
fi
log "DRM_NODE sysfs=${dv:-absent} node=$( [ -c /dev/dri/card0 ] && echo char || echo absent)"

# ---------------------------------------------------------------------------
# 3. USB role (stage 1 §3, unchanged).
# ---------------------------------------------------------------------------
[ -w "$SSUSB/mode" ] && echo peripheral > "$SSUSB/mode" 2>/dev/null
for r in /sys/class/usb_role/*/role; do
    [ -w "$r" ] && echo device > "$r" 2>/dev/null
done
log "ROLE mode=$(cat $SSUSB/mode 2>/dev/null) roles=$(cat /sys/class/usb_role/*/role 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 4. ACM gadget via configfs (stage 1 §4; product string changed only).
# ---------------------------------------------------------------------------
stage ACM_SETUP_ATTEMPTED
mount -t configfs none /config 2>/dev/null
[ -d /config/usb_gadget ] || fail acm "no configfs usb_gadget"
mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/acm.gs0" \
    || fail acm "mkdir gadget"
wr() { echo "$2" > "$1" 2>/dev/null || fail acm "write $(basename "$1")=$2"; }
rd() { cat "$1" 2>/dev/null | tr 'A-F' 'a-f'; }
expect() {
    got=$(rd "$1")
    [ "$got" = "$2" ] || fail acm "readback $(basename "$1")='$got' expected '$2'"
}
wr "$G/idVendor"        0x1d6b
wr "$G/idProduct"       0x0104
wr "$G/bDeviceClass"    0xef
wr "$G/bDeviceSubClass" 0x02
wr "$G/bDeviceProtocol" 0x01
wr "$G/strings/0x409/serialnumber"              "FS-$NONCE"
wr "$G/strings/0x409/manufacturer"              "FrameShift"
wr "$G/strings/0x409/product"                   "FrameShift stage3a"
wr "$G/configs/c.1/strings/0x409/configuration" "acm"
ln -s "$G/functions/acm.gs0" "$G/configs/c.1/" || fail acm "link acm"
expect "$G/idVendor"        0x1d6b
expect "$G/idProduct"       0x0104
expect "$G/bDeviceClass"    0xef
expect "$G/bDeviceSubClass" 0x02
expect "$G/bDeviceProtocol" 0x01
[ "$(cat "$G/strings/0x409/serialnumber" 2>/dev/null)" = "FS-$NONCE" ] || fail acm "readback serialnumber"
log "GADGET_IDENTITY vid=$(rd "$G/idVendor") pid=$(rd "$G/idProduct") class=$(rd "$G/bDeviceClass")/$(rd "$G/bDeviceSubClass")/$(rd "$G/bDeviceProtocol") serial=$(cat "$G/strings/0x409/serialnumber")"

[ -d "/sys/class/udc/$UDC_NAME" ] || fail udc "UDC $UDC_NAME not present"
echo "$UDC_NAME" > "$G/UDC" || fail udc "bind failed"
[ "$(cat $G/UDC)" = "$UDC_NAME" ] || fail udc "bind did not stick"
stage UDC_BOUND "state=$(cat /sys/class/udc/$UDC_NAME/state 2>/dev/null)"
led 0 0 255

i=0
while [ ! -c /dev/ttyGS0 ] && [ $i -lt 10 ]; do mdev -s; sleep 1; i=$((i + 1)); done
[ -c /dev/ttyGS0 ] || fail tty "ttyGS0 never appeared"

# ---------------------------------------------------------------------------
# 5. Host protocol helpers (stage 1 §5, unchanged). fs-display and fs-done are
#    files in the ramdisk (build-image.sh, hashes in MANIFEST).
# ---------------------------------------------------------------------------
cat > /bin/fs-verify <<'EOF'
#!/bin/busybox sh
# fs-verify <challenge>: prove command execution on the target.
n=$(cat /run/fs.nonce); c=$1
case "$c" in ''|*[!0-9a-f]*) echo "FSV1 nonce=$n error=bad-challenge END"; exit 1 ;; esac
r=$(printf '%s:%s' "$n" "$c" | sha256sum | cut -d' ' -f1)
p=$(tr '\0' ',' < /proc/1/cmdline | sed 's/,$//')
s=$(tr '\n' ',' < /run/fs.stages | sed 's/,$//')
echo "FSV1 nonce=$n resp=$r kernel=$(uname -r) pid1=$p stages=$s END"
EOF
cat > /bin/fs-ack <<'EOF'
#!/bin/busybox sh
# fs-ack <challenge2>: hand PID 1 an acknowledgement token (recorded only;
# it does not change the deadline).
case "$1" in ''|*[!0-9a-f]*) echo "FSA1 error=bad-token END"; exit 1 ;; esac
echo "$1" > /run/host_ack.tmp && mv /run/host_ack.tmp /run/host_ack
echo "FSA1 queued END"
EOF
cat > /bin/fs-status <<'EOF'
#!/bin/busybox sh
# fs-status: current stages and the acknowledgement PID 1 recorded, if any.
n=$(cat /run/fs.nonce)
s=$(tr '\n' ',' < /run/fs.stages | sed 's/,$//')
a=$(cat /run/fs.acked 2>/dev/null)
echo "FSS1 nonce=$n stages=$s acked=${a:-none} END"
EOF
chmod 0755 /bin/fs-verify /bin/fs-ack /bin/fs-status

# ---------------------------------------------------------------------------
# 6. Shell on ttyGS0 (stage 1 §6, unchanged). Respawns; PID 1 never waits on it.
# ---------------------------------------------------------------------------
(
    while :; do
        stty -F /dev/ttyGS0 raw -echo 2>/dev/null
        setsid sh -c 'exec 0</dev/ttyGS0 1>/dev/ttyGS0 2>&1; exec sh'
        sleep 1
    done
) &
stage SHELL_READY
led 0 255 0

# ---------------------------------------------------------------------------
# 7. Hold (replaces stage 1 §7): HOST_ACK recorded only; reboot at the
#    deadline, at the ack window without an ack, or ~1 s after fs-done.
#    Never returns.
# ---------------------------------------------------------------------------
fs_hold_loop
