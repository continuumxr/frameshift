#!/bin/busybox sh
# FrameShift — Quest 3 stage-1 diagnostic init (runs as PID 1).
#
# Purpose: prove that a kernel + initramfs we control runs on the headset, and
# give the host a verifiable command channel over USB CDC-ACM.
#
# Design rules (FS-R-003 §5–6, FS-R-004 §2–4):
#   - PID 1 never exits; every path ends in a bounded wait or a deliberate
#     reboot into the bootloader through the reviewed /bin/fs-reboot helper.
#   - No deliberate persistent writes: only tmpfs/proc/sysfs/configfs are
#     mounted; no block device is opened for writing.
#   - Records go to RAM first (/run/fs.log). /dev/kmsg and /dev/pmsg0 are
#     written only if they are character devices. Nothing in the logging or
#     recovery paths writes to the USB tty, so a stuck transport cannot block
#     recovery.
#   - The host verifies the shell with a challenge: /bin/fs-verify prints one
#     complete record whose response, sha256("<nonce>:<challenge>"), is
#     computed here and never appears in the host's command.
#   - The dead-man timer touches only RAM and the helper.
#
# @NONCE@ is replaced by build.sh with a fresh per-attempt value.

NONCE="@NONCE@"
ERR_DELAY=60
ACK_WINDOW=150
DEADMAN=300
UDC_NAME=a600000.dwc3
SSUSB=/sys/devices/platform/soc/a600000.ssusb
G=/config/usb_gadget/fs
BB=/bin/busybox

# ---------------------------------------------------------------------------
# 0. Minimal environment. DEVTMPFS=n on this kernel: populate /dev ourselves.
# ---------------------------------------------------------------------------
$BB mkdir -p /proc /sys /dev /run /tmp /config /bin /sbin
$BB mount -t proc  proc  /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t tmpfs -o mode=0755,size=4m tmpfs /dev
$BB mount -t tmpfs -o mode=0755,size=4m tmpfs /run
$BB mknod -m 600 /dev/console c 5 1
$BB mknod -m 666 /dev/null    c 1 3
$BB mknod -m 600 /dev/kmsg    c 1 11
# console=none leaves fds 0-2 closed; give PID 1 defined stdio so no later
# open() can land on fd 0-2 by accident (adversarial review, finding 5).
exec 0</dev/null 1>/dev/null 2>/dev/null
$BB --install -s /bin
export PATH=/bin:/sbin
: > /run/fs.log
: > /run/fs.stages
echo "$NONCE" > /run/fs.nonce

up() { cut -d. -f1 /proc/uptime; }
T0=$(up)

log() {       # RAM first; kmsg/pmsg best-effort; never the USB tty
    msg="FS[$NONCE] t=$(up)s $*"
    echo "$msg" >> /run/fs.log
    [ -c /dev/kmsg ]  && echo "$msg" > /dev/kmsg
    [ -c /dev/pmsg0 ] && echo "$msg" > /dev/pmsg0
    return 0
}
stage() {     # stage NAME [detail]: a nonce-bearing stage record
    echo "$1" >> /run/fs.stages
    log "STAGE=$1 $2"
}

led() {       # led <red> <green> <blue> (0-255); no-op if absent
    for c in red green blue; do
        v=$1; shift
        [ -w /sys/class/leds/$c/brightness ] && echo "$v" > /sys/class/leds/$c/brightness
    done
    return 0
}

hold() { while :; do sleep 3600; done; }

reboot_bootloader() {
    echo "FS[$NONCE] t=$(up)s REBOOT_BOOTLOADER reason=$1" >> /run/fs.log
    sync
    /bin/fs-reboot                      # reviewed helper: bootloader only
    echo "FS[$NONCE] t=$(up)s FS_REBOOT_RETURNED fallback=reboot-f" >> /run/fs.log
    reboot -f
    hold
}

fail() {      # fail <stage> <detail>: record, wait out ERR_DELAY from start, reboot
    log "ERROR stage=$1 $2"
    echo "ERROR_$1" >> /run/fs.stages
    led 255 0 0
    while [ $(( $(up) - T0 )) -lt "$ERR_DELAY" ]; do sleep 1; done
    reboot_bootloader "error-$1"
}

# ---------------------------------------------------------------------------
# 1. INIT_STARTED, plus a dead-man timer that touches only RAM and the helper.
# ---------------------------------------------------------------------------
mdev -s
stage INIT_STARTED "pid=$$ kernel=$(uname -r)"
(
    sleep "$DEADMAN"
    echo "FS[$NONCE] DEADMAN_FIRED" >> /run/fs.log
    /bin/fs-reboot
    reboot -f
) &
DEADMAN_PID=$!

# ---------------------------------------------------------------------------
# 2. Modules: Meta's own recovery set (all 97), loaded the way Android's
#    first-stage init does (observed in the stock boot log): softdep "pre:",
#    then the modules.dep closure in reverse, then the module, then "post:";
#    each module exactly once. modules.dep uses absolute paths.
# ---------------------------------------------------------------------------
MD=/lib/modules
LOADED=" "
ok=0; bad=0

modfile() {   # module name or file -> /lib/modules/<file>.ko if present
    n=${1##*/}; n=${n%.ko}
    for c in "$n" "$(echo "$n" | tr '_' '-')" "$(echo "$n" | tr '-' '_')"; do
        [ -f "$MD/$c.ko" ] && { echo "$MD/$c.ko"; return 0; }
    done
    return 1
}

softdeps() {  # softdeps <pre|post> <file> -> files listed in modules.softdep
    name=$(basename "$2" .ko | tr '-' '_')
    line=$(grep "^softdep $name " "$MD/modules.softdep" 2>/dev/null)
    [ -n "$line" ] || return 0
    if [ "$1" = pre ]; then part=${line#*pre:}; part=${part%%post:*}
    else case "$line" in *post:*) part=${line#*post:} ;; *) part="" ;; esac
    fi
    for s in $part; do modfile "$s"; done
}

load_mod() {  # load_mod /lib/modules/x.ko : deps first, each module once
    case "$LOADED" in *" $1 "*) return 0 ;; esac
    LOADED="$LOADED$1 "                         # mark first: no loops
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

# CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y and nothing here answers firmware
# requests: without this, each missing firmware file stalls 60 s
# (adversarial review, finding 3).
[ -w /sys/class/firmware/timeout ] && echo 1 > /sys/class/firmware/timeout
log "FW_TIMEOUT=$(cat /sys/class/firmware/timeout 2>/dev/null)"

for m in $(cat "$MD/modules.load.recovery"); do
    load_mod "$MD/$m"
done
sleep 3                       # let deferred probes settle
mdev -s
led 255 160 0                 # amber: modules stage done
stage MODULES_READY "ok=$ok fail=$bad udc=$(ls /sys/class/udc 2>/dev/null | tr '\n' ' ') drm=$(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 3. USB role: without the ADSP's Type-C stack nothing requests device mode.
# ---------------------------------------------------------------------------
[ -w "$SSUSB/mode" ] && echo peripheral > "$SSUSB/mode" 2>/dev/null
for r in /sys/class/usb_role/*/role; do
    [ -w "$r" ] && echo device > "$r" 2>/dev/null
done
log "ROLE mode=$(cat $SSUSB/mode 2>/dev/null) roles=$(cat /sys/class/usb_role/*/role 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 4. ACM gadget via configfs. The nonce is the USB serial number.
# ---------------------------------------------------------------------------
stage ACM_SETUP_ATTEMPTED
mount -t configfs none /config 2>/dev/null
[ -d /config/usb_gadget ] || fail acm "no configfs usb_gadget"
mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/acm.gs0" \
    || fail acm "mkdir gadget"
# Every gadget write goes through wr(): a failed write calls fail().
wr() { echo "$2" > "$1" 2>/dev/null || fail acm "write $(basename "$1")=$2"; }
# Read back with exact string comparison. No shell arithmetic: an arithmetic
# error in a non-interactive ash aborts the shell, which here is PID 1.
# configfs prints u16 as 0x%04x and u8 as 0x%02x; tr lowercases defensively.
rd() { cat "$1" 2>/dev/null | tr 'A-F' 'a-f'; }
expect() {    # expect <file> <value>: fail() unless the readback equals value
    got=$(rd "$1")
    [ "$got" = "$2" ] || fail acm "readback $(basename "$1")='$got' expected '$2'"
}
wr "$G/idVendor"        0x1d6b            # Linux Foundation
wr "$G/idProduct"       0x0104            # Multifunction Composite Gadget
# Miscellaneous / Common Class / Interface Association: Windows then groups
# f_acm's two interfaces by their IAD, so usbser gets a complete CDC-ACM
# function (adversarial review, finding 1).
wr "$G/bDeviceClass"    0xef
wr "$G/bDeviceSubClass" 0x02
wr "$G/bDeviceProtocol" 0x01
wr "$G/strings/0x409/serialnumber"              "FS-$NONCE"
wr "$G/strings/0x409/manufacturer"              "FrameShift"
wr "$G/strings/0x409/product"                   "FrameShift stage1"
wr "$G/configs/c.1/strings/0x409/configuration" "acm"
ln -s "$G/functions/acm.gs0" "$G/configs/c.1/" || fail acm "link acm"
# Read the identity back: a gadget without the nonce serial would never be
# contacted by the host (adversarial review, finding 4).
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
led 0 0 255                   # blue: gadget bound

i=0                           # ttyGS0 exists only after the bind: rescan
while [ ! -c /dev/ttyGS0 ] && [ $i -lt 10 ]; do mdev -s; sleep 1; i=$((i + 1)); done
[ -c /dev/ttyGS0 ] || fail tty "ttyGS0 never appeared"

# ---------------------------------------------------------------------------
# 5. Host protocol helpers (written at boot; they read /run state).
#    Records are single lines: "<TAG> key=value ... END".
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
# fs-ack <challenge2>: hand PID 1 an acknowledgement token.
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
# 6. Shell on ttyGS0, tty set raw/-echo. NOTE: with a tty on stdin and stdout
#    busybox ash becomes INTERACTIVE (prompt, line editing, its own echo).
#    The host protocol tolerates this: records are parsed as complete lines.
#    Respawns if it exits; PID 1 never waits on it.
# ---------------------------------------------------------------------------
(
    while :; do
        stty -F /dev/ttyGS0 raw -echo 2>/dev/null
        setsid sh -c 'exec 0</dev/ttyGS0 1>/dev/ttyGS0 2>&1; exec sh'
        sleep 1
    done
) &
stage SHELL_READY
led 0 255 0                   # green: shell offered

# ---------------------------------------------------------------------------
# 7. Wait for a valid host acknowledgement. PID 1 itself validates and records
#    it (nonce-bearing HOST_ACK). No ack within ACK_WINDOW: reboot to the
#    bootloader.
# ---------------------------------------------------------------------------
S0=$(up)
while :; do
    if [ -f /run/host_ack ]; then
        a=$(cat /run/host_ack)
        case "$a" in
            ''|*[!0-9a-f]*) log "HOST_ACK_REJECTED malformed"; rm -f /run/host_ack ;;
            *) echo "$a" > /run/fs.acked
               kill "$DEADMAN_PID" 2>/dev/null
               stage HOST_ACK "ack=$a deadman-cancelled"
               led 255 255 255
               hold ;;
        esac
    fi
    [ $(( $(up) - S0 )) -ge "$ACK_WINDOW" ] && { led 255 0 255; reboot_bootloader no-host-ack; }
    sleep 1
done
