#!/bin/busybox sh
# FrameShift — Quest 3 K1a init (runs as PID 1): "our own kernel boots" (FS-A-013 §2.2 K1a;
# PROJECT_SETUP §3). The boot image carries the FrameShift-built K1a kernel (Meta's v2.7 source
# dbc2bc83a2b6 plus the K1a request list; k1a/kernel/) and this ramdisk. vendor_boot (vendor
# ramdisk, DT, vendor command line) stays the unit's own stock v2.7 one. No Valve file. No panel write.
#
# = the stage-3d init (devices/quest3/stage3d/init.sh; stage-3d PASS on both units, J-144/J-146)
#   with these changes only:
#   - the gadget product string "FrameShift K1a"; the gadget stays ACM ONLY, as in stage 3d (PM
#     decision J-179: no NCM in K1a);
#   - no idle limit (stage 3c's fs-idle.sh went with the display parts): the hold ends at fs-done,
#     at the ack window (150 s after SHELL_READY without fs-ack), or at the deadline T0 + 200 s;
#   - the display parts of stages 3c/3d are removed: no fs-phase, fs-pattern, fs-probe.sh,
#     fs-idle.sh, no /dev/dri node, no /proc/interrupts sample. Nothing here opens a DRM device or
#     writes a backlight or panel node (the status LEDs are written as in every stage);
#   - one runner, /bin/fs-k1a <challenge> (k1a/fs-k1a.sh): ONE paced FSB1 record (exp=k1a) of
#     read-only facts: /proc/version and uname -v (our pinned build identity), the SHA-256 of the
#     running kernel's own config (/proc/config.gz), MemTotal, the loaded modules and any
#     symbol-version refusal in the kernel log, /proc/filesystems, the USB functions, /run/fs.log.
#   Kept unchanged: the deadline (DEADLINE 200 s, backstop 201 s, ACK_WINDOW 150 s, ERR_DELAY
#   60 s; common/target/pid1-hold.sh), the module index pins (MODDEP_SHA, MODSOFTDEP_SHA: the
#   pinned v2.7 vendor_boot's), OUR 95-module list (stage3d/modules.load.v66, J-129) with the same
#   loader, the USB role, fs-verify/fs-ack/fs-status/fs-done, the console shell and the hold.
#   DEVTMPFS is now built in (K1a), but /dev stays the stage-1 tmpfs plus mdev (the mounts are
#   unchanged; the builder's mount whitelist): the runner only REPORTS devtmpfs in /proc/filesystems.
#   With the stock kernel the stage-1 comment below ("DEVTMPFS=n") was literal; with K1a it means
#   "devtmpfs is not used".
# Rules kept: PID 1 never exits; no block device is mounted or opened; records go to RAM (/run)
# first; nothing in logging or recovery writes the USB tty.
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
# stage 3c (kept): the deadline file, read by /bin/fs-k1a for its `time` refusal (fork-free)
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
# 3. USB role (stage 1 §3, unchanged).
# ---------------------------------------------------------------------------
[ -w "$SSUSB/mode" ] && echo peripheral > "$SSUSB/mode" 2>/dev/null
for r in /sys/class/usb_role/*/role; do
    [ -w "$r" ] && echo device > "$r" 2>/dev/null
done
log "ROLE mode=$(cat $SSUSB/mode 2>/dev/null) roles=$(cat /sys/class/usb_role/*/role 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 4. ACM gadget via configfs (stage 1 §4; product string changed only; ACM only, J-179).
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
wr "$G/strings/0x409/product"                   "FrameShift K1a"
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
# 5. Host protocol helpers (stage 1 §5, unchanged). fs-k1a and fs-done are
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
