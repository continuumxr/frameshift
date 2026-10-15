#!/bin/busybox sh
# FrameShift — Quest 3 stage-3d init (runs as PID 1): the stage-3c interactive per-phase
# display run for Quest 3 Unit 2 on its own stock Horizon OS v2.7 kernel and vendor_boot
# (stage3d/README.md). A separate image from stages 2a-3c (all unchanged); no Valve file.
#
# = the stage-3c init (devices/quest3/stage3c/init.sh, image 9d3ad984...) with THREE changes:
#   - the gadget product string "FrameShift stage3d";
#   - before any module loads, the device's /lib/modules/modules.dep and modules.softdep must have the
#     pinned v2.7 SHA-256 (MODDEP_SHA, MODSOFTDEP_SHA); otherwise fail closed (no module, reboot
#     "error-modules" at T0 + 60 s; image review B);
#   - the module loop reads OUR list /lib/fs/modules.load (stage3d/modules.load.v66, pinned by
#     build-image.sh) instead of the vendor's lib/modules/modules.load.recovery (PM decision J-129):
#     the proven v66 set (stage 3c's 97 minus debug-regulator and qti-regmap-debugfs = 95),
#     resolved against the v2.7 module files in the vendor ramdisk; the builder checks that the
#     list is closed under modules.dep and modules.softdep, so none of the 36 v2.7-only modules
#     (ADSP remoteproc/audio, charger, tsens/ADC/bcl thermal, sensors, usbvdm, qcom_lpm,
#     userspace-consumer) is ever loaded. modules.dep / modules.softdep are still the vendor's.
#   Run 1 of stage 3d is a non-lit display reset (fs-phase.sh, fs-pattern v0.7 "reset"); nothing
#   here depends on it. Nothing here writes backlight_changes_blocked (left as the driver sets it).
#   The stage-3c notes below are kept as they were.
#
# = the stage-3b init (devices/quest3/stage3b/init.sh, image ea60d6cd..., itself the stage-3a
#   init: the PROVEN stage-1 init plus the common PID 1 deadline) with these changes only:
#   - right after fs_hold_init: /run/fs.deadline = T0 + DEADLINE (whole seconds of uptime,
#     builtins only), read by /bin/fs-phase for its `time` refusal (DESIGN §5.2; defence in
#     depth, the host guards are the real admission control).
#   - /lib/fs/fs-idle.sh (DESIGN §5.9), started ONCE before SHELL_READY (one fork) with stdin,
#     stdout and stderr on /dev/null: the 120 s device-side idle limit. It writes only
#     /run/fs.collected (token "idle") and can only SHORTEN the hold; it never writes the tty.
#   - /bin/fs-phase (stage3c/fs-phase.sh) replaces /bin/fs-display: one command per phase
#     (p0, r1, r2, r3), one paced FSB1 record each, live FSPM1 markers. /lib/fs/fs-probe.sh is
#     the stage-3c probe (roles p0/r1/r2/r3, wider dmesg filter, more TE/BLU points).
#   - gadget product string "FrameShift stage3c".
#   DEADLINE stays 200 s (backstop 201 s), ACK_WINDOW 150 s, ERR_DELAY 60 s. No debugfs is
#   mounted anywhere in this image (PM decision J-109 #2; build-image.sh checks it).
#   PANELS (stage3c/README.md, IMAGE.md): run 1 holds its frame for 3 s, run 2 for 10 s, run 3
#   (if requested) for 5 s; each run closes the DRM fd at its end. On v66 a close after our
#   commit performs a full panel off [D, near-match source; not optically confirmed]. If it
#   does not, the last frame may stay lit until fs-done, the idle limit or recovery; T0+200/201 s
#   are intended reboot times, not guaranteed panel-off times (FS-R-007 §4).
# Rules kept: PID 1 never exits; no block device is mounted or opened; records go to
# RAM (/run) first; nothing in logging or recovery writes the USB tty.
#
# The NONCE placeholder below is replaced by build-image.sh with a fresh per-attempt value.

NONCE="@NONCE@"
DEADLINE=200
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
# stage 3c: the deadline for fs-phase's `time` refusal (fork-free: builtin echo and arithmetic)
echo $((T0 + FS_DEADLINE)) > /run/fs.deadline

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

# stage 3d (image review B): the device's vendor module index must be the pinned v2.7 one BEFORE any module
# loads. modules.dep and modules.softdep come from the vendor_boot on the slot (our list /lib/fs/modules.load is
# in this ramdisk, pinned by the builder). Mismatch (e.g. a unit not on build 52433670036000520): fail closed:
# no module is loaded, stages MODULES_REFUSED + ERROR_modules, reboot "error-modules" at T0 + ERR_DELAY. With no
# module there is no USB gadget and no LED (both are modules): the host sees no FS-<nonce> gadget and the unit
# back in fastboot about 60 s after the boot. build-image.sh checks these two pins against the pinned vendor_boot.
MODDEP_SHA=ae5edf110424463af4ca2cb3b51992ff25cc031c5e74296eb01d8b9828e429e3
MODSOFTDEP_SHA=8e49f03a5cbcf0883d5107e176bfefcb16f99bdb965a6d65725725d8811bff62
dsha=$(sha256sum "$MD/modules.dep" 2>/dev/null | cut -d' ' -f1)
ssha=$(sha256sum "$MD/modules.softdep" 2>/dev/null | cut -d' ' -f1)
if [ "$dsha" != "$MODDEP_SHA" ] || [ "$ssha" != "$MODSOFTDEP_SHA" ]; then
    stage MODULES_REFUSED "reason=vendor-module-index-mismatch dep=${dsha:-none} softdep=${ssha:-none}"
    fail modules "vendor modules.dep/modules.softdep are not the pinned v2.7 ones; no module loaded"
fi
log "MODULE_INDEX dep=$dsha softdep=$ssha (= the pinned v2.7 index)"

[ -w /sys/class/firmware/timeout ] && echo 1 > /sys/class/firmware/timeout
log "FW_TIMEOUT=$(cat /sys/class/firmware/timeout 2>/dev/null)"

# stage 3d (J-129): our pinned v66 set, not the vendor's v2.7 modules.load.recovery
log "MODLIST /lib/fs/modules.load entries=$(wc -l < /lib/fs/modules.load 2>/dev/null)"
for m in $(cat /lib/fs/modules.load); do
    load_mod "$MD/$m"
done
sleep 3
mdev -s
led 255 160 0
stage MODULES_READY "ok=$ok fail=$bad udc=$(ls /sys/class/udc 2>/dev/null | tr '\n' ' ') drm=$(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 2.1 Stage 3b (kept): the handoff-time TE / BLU-PWM interrupt counters, read-only and
#     fork-free (builtins only; at most the two matching lines plus uptime).
# ---------------------------------------------------------------------------
: > /run/fs.irq0
if [ -f /proc/interrupts ]; then
    while IFS= read -r l; do
        case "$l" in *te-edge-isr*|*blu-pwm-isr*) echo "$l" >> /run/fs.irq0 ;; esac
    done < /proc/interrupts
fi
read -r u0 _ < /proc/uptime && echo "-- at $u0 (init, after MODULES_READY)" >> /run/fs.irq0

# ---------------------------------------------------------------------------
# 2a. DRM node (as stage 3a; stage3a/README.md integration step 1). DEVTMPFS=n; mdev may
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
wr "$G/strings/0x409/product"                   "FrameShift stage3d"
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
# 5. Host protocol helpers (stage 1 §5, unchanged). fs-phase and fs-done are
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
# 5a. Stage 3c: the device-side idle limit (DESIGN §5.9). One fork, before SHELL_READY,
#     stdio on /dev/null; unarmed until fs-phase p0 writes /run/fsb3c/activity.
# ---------------------------------------------------------------------------
/bin/busybox sh /lib/fs/fs-idle.sh </dev/null >/dev/null 2>&1 &
log "IDLE_LIMIT started pid=$! idle=120s stuck=180s (unarmed until p0)"

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
