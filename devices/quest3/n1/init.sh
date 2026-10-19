#!/bin/busybox sh
# FrameShift — Quest 3 N1 init (runs as PID 1): "an NCM USB network link next to the ACM console"
# (FS-R-013 §5 and §9: N1 is prepared before R-1's RAM-root transfer; its conditions: ACM continuity,
# bounded enumeration, no unintended listener). The boot image carries the UNCHANGED K1a kernel (Meta's
# v2.7 source dbc2bc83a2b6 plus the K1a request list; k1a/kernel/; NCM, ACM, configfs and IPv6 are built
# in: CONFIG_USB_CONFIGFS_NCM=y, CONFIG_USB_F_NCM=y, CONFIG_IPV6=y) and this ramdisk. vendor_boot (vendor
# ramdisk, DT, vendor command line) stays the unit's own stock v2.7 one. No Valve file. No panel write.
#
# = the K1a init (devices/quest3/k1a/init.sh; itself the stage-3d init without the display parts) with
#   these changes only:
#   - the gadget product string "FrameShift N1";
#   - 4b. NCM as the SECOND function of the same configuration, linked AFTER acm.gs0 (the ACM interfaces
#     stay 0-1: Windows' MI_00 COM port is unchanged; NCM is interfaces 2-3, MI_02). MACs from the nonce
#     (dev_addr 02:<nonce bytes 0-4>, host_addr 06:<nonce bytes 0-4>, locally administered, as
#     devices/quest2/channel/target/fs-ncm.sh), the IPv6 "default" sysctls set and read back BEFORE the
#     bind (no kernel-generated address, no DAD, no RA, no autoconf, no router solicitation). NCM is NEVER
#     fatal: every NCM step uses nw() (write + exact readback, no fail()); a failure before the bind removes
#     the function again and the gadget binds ACM-only (NCM_SKIPPED);
#   - the bind: if it fails while NCM is linked (f_ncm's bind, the UDC's endpoints), the NCM link is
#     removed and the bind is retried ACM-only ONCE (NCM_DROPPED); only a failure of that retry is the
#     K1a "bind failed" (fail udc). So a failure in the NCM bind leaves the ACM console working;
#   - 4c. after ttyGS0 appears: the NCM network, IPv6 link-local ONLY: the interface name from configfs
#     (a plain [a-z0-9] name that carries dev_addr), its sysctls set and read back, link up, ONE address
#     fe80::<nonce>/64 (the 64-bit nonce IS the interface identifier). No IPv4 address, no DHCP, no route,
#     no daemon. Nothing is waited for: with DAD off the address becomes permanent at the first DAD work run
#     (milliseconds), with or without carrier (5.10 addrconf_dad_begin completes before its IF_READY
#     check; fs-xfer retries its bind on EADDRNOTAVAIL for the gap); the link carries traffic once
#     the host's NCM driver activates the data interface. A failure is logged (NCM_NET_FAILED) and leaves
#     ACM alone. The state goes to /run/fs.ncm for the runner;
#   - 6b. the ACM-continuity guard (one child, one shot, never fatal): if NCM is bound, a host is attached
#     (UDC state default, powered or addressed) and it has neither configured the gadget nor sent fs-ack
#     within NCM_GUARD_S (30 s) of SHELL_READY (checked again right before acting), the guard unbinds,
#     removes NCM and binds ACM-only (NCM_FALLBACK; the bind retried once): a host that cannot enumerate the
#     composite should then get the console [C, untested on Windows]. A configured or acked gadget, or no
#     attached host, is never touched;
#   - NOTHING LISTENS: no daemon, no inetd, no busybox nc/httpd/telnetd. The only listener of the image is
#     /bin/fs-xfer (n1/src/fs-xfer.c), started ONCE by the runner's step 5 under fs-supervise: one session
#     on [fe80::<nonce>%<if>]:47201 (designed to end within 23 s; hard stops: its alarm at 25 s, fs-supervise
#     TERM at 26 s), the listening socket closed at the first good accept;
#   - one runner, /bin/fs-n1 <challenge> (n1/fs-n1.sh): ONE paced FSB1 record (exp=n1, 6 steps kernel,
#     mem, modules, net, xfer, log): the K1a facts, the NCM and socket state before and after, the transfer.
#   Kept unchanged from K1a: the deadline (DEADLINE 200 s, backstop 201 s, ACK_WINDOW 150 s, ERR_DELAY
#   60 s; common/target/pid1-hold.sh), the module index pins, OUR 95-module list with the same loader, the
#   USB role, the ACM function and identity, fs-verify/fs-ack/fs-status/fs-done, the console shell, the hold.
# Rules kept: PID 1 never exits; no block device is mounted or opened; records go to RAM (/run)
# first; nothing in logging or recovery writes the USB tty.
#
# The NONCE placeholder below is replaced by build-image.sh with a fresh per-attempt value.

NONCE="@NONCE@"
DEADLINE=200
ACK_WINDOW=150
ERR_DELAY=60
NCM_PORT=47201
NCM_GUARD_S=30
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
# stage 3c (kept): the deadline file, read by /bin/fs-n1 for its `time` refusal (fork-free)
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
# 4. ACM gadget via configfs (stage 1 §4; product string changed only). ACM first: unchanged from K1a.
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
wr "$G/strings/0x409/product"                   "FrameShift N1"
wr "$G/configs/c.1/strings/0x409/configuration" "acm"
ln -s "$G/functions/acm.gs0" "$G/configs/c.1/" || fail acm "link acm"
expect "$G/idVendor"        0x1d6b
expect "$G/idProduct"       0x0104
expect "$G/bDeviceClass"    0xef
expect "$G/bDeviceSubClass" 0x02
expect "$G/bDeviceProtocol" 0x01
[ "$(cat "$G/strings/0x409/serialnumber" 2>/dev/null)" = "FS-$NONCE" ] || fail acm "readback serialnumber"
log "GADGET_IDENTITY vid=$(rd "$G/idVendor") pid=$(rd "$G/idProduct") class=$(rd "$G/bDeviceClass")/$(rd "$G/bDeviceSubClass")/$(rd "$G/bDeviceProtocol") serial=$(cat "$G/strings/0x409/serialnumber")"

# ---------------------------------------------------------------------------
# 4b. N1: NCM as the second function (after acm.gs0). NEVER fatal: no fail() below until the bind.
# ---------------------------------------------------------------------------
NCM=none
NCM_WHY=
NCM_FN=$G/functions/ncm.fs
nb() { echo "$NONCE" | cut -c"$1"; }
NCM_DEV="02:$(nb 1-2):$(nb 3-4):$(nb 5-6):$(nb 7-8):$(nb 9-10)"
NCM_HOST="06:${NCM_DEV#02:}"
NCM_LL="fe80::$(nb 1-4):$(nb 5-8):$(nb 9-12):$(nb 13-16)"
# nw FILE VALUE: write, then an exact (lowercased) readback; returns nonzero on any failure, never fail()s
nw() { echo "$2" > "$1" 2>/dev/null && [ "$(cat "$1" 2>/dev/null | tr 'A-F' 'a-f')" = "$2" ]; }
ncm_prep() {
    mkdir -p "$NCM_FN" 2>/dev/null || { NCM_WHY=mkdir; return 1; }
    nw "$NCM_FN/dev_addr" "$NCM_DEV" || { NCM_WHY=dev_addr; return 1; }
    nw "$NCM_FN/host_addr" "$NCM_HOST" || { NCM_WHY=host_addr; return 1; }
    # the kernel skips DAD only when both all/ and the interface's accept_dad are below 1
    [ "$(cat /proc/sys/net/ipv6/conf/all/accept_dad 2>/dev/null)" = 0 ] || nw /proc/sys/net/ipv6/conf/all/accept_dad 0 \
        || { NCM_WHY=all/accept_dad; return 1; }
    # a new interface inherits default/: no kernel-generated (EUI-64) address, no DAD, no RA, no autoconf, no RS
    for kv in addr_gen_mode:1 accept_dad:0 dad_transmits:0 accept_ra:0 autoconf:0 router_solicitations:0; do
        nw "/proc/sys/net/ipv6/conf/default/${kv%%:*}" "${kv#*:}" || { NCM_WHY="default/${kv%%:*}"; return 1; }
    done
    ln -s "$NCM_FN" "$G/configs/c.1/" 2>/dev/null || { NCM_WHY=link; return 1; }
    return 0
}
if ncm_prep; then
    NCM=linked
    echo "acm+ncm" > "$G/configs/c.1/strings/0x409/configuration" 2>/dev/null
else
    rm -f "$G/configs/c.1/ncm.fs" 2>/dev/null
    rmdir "$NCM_FN" 2>/dev/null
    log "NCM_SKIPPED step=$NCM_WHY (before the bind; the gadget binds ACM-only)"
fi
log "NCM function=$NCM dev_addr=$NCM_DEV host_addr=$NCM_HOST ll=$NCM_LL port=$NCM_PORT"

[ -d "/sys/class/udc/$UDC_NAME" ] || fail udc "UDC $UDC_NAME not present"
# N1: a bind that fails while NCM is linked drops NCM and is retried ACM-only ONCE; only that retry's
# failure is K1a's "bind failed" (the ACM console never depends on NCM)
if ! echo "$UDC_NAME" > "$G/UDC" 2>/dev/null; then
    if [ "$NCM" = linked ]; then
        rm -f "$G/configs/c.1/ncm.fs" 2>/dev/null
        echo "acm" > "$G/configs/c.1/strings/0x409/configuration" 2>/dev/null
        NCM=dropped
        log "NCM_DROPPED the bind failed with NCM linked; retrying the bind ACM-only (ncm link left: $([ -e "$G/configs/c.1/ncm.fs" ] && echo yes || echo no))"
        echo "$UDC_NAME" > "$G/UDC" || fail udc "bind failed (ACM-only retry)"
    else
        fail udc "bind failed"
    fi
fi
[ "$(cat $G/UDC)" = "$UDC_NAME" ] || fail udc "bind did not stick"
stage UDC_BOUND "state=$(cat /sys/class/udc/$UDC_NAME/state 2>/dev/null)"
led 0 0 255

i=0
while [ ! -c /dev/ttyGS0 ] && [ $i -lt 10 ]; do mdev -s; sleep 1; i=$((i + 1)); done
[ -c /dev/ttyGS0 ] || fail tty "ttyGS0 never appeared"

# ---------------------------------------------------------------------------
# 4c. N1: the NCM network, IPv6 link-local only (NEVER fatal; nothing is waited for: DAD is off, so the
#     address is permanent at once; traffic flows once the host's driver brings the carrier up). /run/fs.ncm
#     tells the runner the state.
# ---------------------------------------------------------------------------
NCM_IF=none
ncm_net() {
    i=$(cat "$NCM_FN/ifname" 2>/dev/null)
    case "$i" in ''|*[!a-z0-9]*) NCM_WHY="ifname '$i' is not a plain name"; return 1 ;; esac
    [ ${#i} -le 15 ] || { NCM_WHY="ifname too long"; return 1; }
    [ "$(cat "/sys/class/net/$i/address" 2>/dev/null | tr 'A-F' 'a-f')" = "$NCM_DEV" ] || { NCM_WHY="$i does not carry $NCM_DEV"; return 1; }
    NCM_IF=$i
    for kv in disable_ipv6:0 addr_gen_mode:1 accept_dad:0 dad_transmits:0 accept_ra:0 autoconf:0 router_solicitations:0; do
        nw "/proc/sys/net/ipv6/conf/$i/${kv%%:*}" "${kv#*:}" || { NCM_WHY="$i/${kv%%:*}"; return 1; }
    done
    ip link set dev "$i" up 2>/dev/null || { NCM_WHY="link up"; return 1; }
    ip -6 addr add "$NCM_LL/64" dev "$i" 2>/dev/null || { NCM_WHY="addr add"; return 1; }
    return 0
}
if [ "$NCM" = linked ]; then
    if ncm_net; then
        NCM=up
        log "NCM_NET if=$NCM_IF addr=$NCM_LL/64 operstate=$(cat "/sys/class/net/$NCM_IF/operstate" 2>/dev/null) inet6=[$(grep " $NCM_IF\$" /proc/net/if_inet6 2>/dev/null | tr -s ' ' | tr '\n' ';')]"
    else
        NCM=net-failed
        log "NCM_NET_FAILED $NCM_WHY (the NCM function stays bound; the ACM console is unaffected)"
    fi
fi
# written to a temporary file and renamed (review m3: the runner never reads a half-written file)
printf 'state=%s\nif=%s\nll=%s\nport=%s\n' "$NCM" "$NCM_IF" "$NCM_LL" "$NCM_PORT" > /run/fs.ncm.tmp && mv /run/fs.ncm.tmp /run/fs.ncm

# ---------------------------------------------------------------------------
# 5. Host protocol helpers (stage 1 §5, unchanged). fs-n1 and fs-done are
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
# 6b. N1: the ACM-continuity guard (one child, one shot, bounded by NCM_GUARD_S; never fatal; PID 1 never waits
#     on it). Only while NCM is bound: if within NCM_GUARD_S of SHELL_READY the host has neither CONFIGURED the
#     gadget (UDC state) nor sent fs-ack, the composite apparently did not enumerate: unbind, remove NCM, bind
#     ACM-only (NCM_FALLBACK). A configured gadget is never touched.
# ---------------------------------------------------------------------------
if [ "$NCM" = up ] || [ "$NCM" = net-failed ]; then
    (
        # the window is measured on the uptime clock (read builtin; digits only before any arithmetic), so slow
        # iterations cannot stretch it; at most NCM_GUARD_S + 1 iterations of one second whatever the clock says
        g0=; read -r g0 _ < /proc/uptime; g0=${g0%%.*}
        case "$g0" in ''|0?*|*[!0-9]*) g0=0 ;; esac
        k=0; seen=0; el=0
        while [ $k -le $NCM_GUARD_S ] && [ $el -lt $NCM_GUARD_S ]; do
            st=; read -r st < "/sys/class/udc/$UDC_NAME/state" 2>/dev/null
            if [ "$st" = configured ]; then seen=1; break; fi
            if [ -e /run/host_ack ] || [ -e /run/fs.acked ]; then seen=2; break; fi
            sleep 1; k=$((k + 1))
            gn=; read -r gn _ < /proc/uptime; gn=${gn%%.*}
            case "$gn" in ''|0?*|*[!0-9]*) el=$k ;; *) [ "$g0" -gt 0 ] && el=$((gn - g0)) || el=$k ;; esac
        done
        # review M1: everything is read once more right before acting (a SET_CONFIGURATION or an ack during the last
        # sleep wins); review m1: the fallback only when a host is attached but never configured the gadget (default,
        # powered or addressed); "not attached" (no cable or PC yet) changes nothing
        st=; read -r st < "/sys/class/udc/$UDC_NAME/state" 2>/dev/null
        if [ $seen = 0 ] && { [ "$st" = configured ] || [ -e /run/host_ack ] || [ -e /run/fs.acked ]; }; then seen=3; fi
        case "$st" in default|powered|addressed) ;; *) [ $seen = 0 ] && seen=4 ;; esac
        if [ $seen = 0 ]; then
            log "NCM_FALLBACK no configured state and no fs-ack within ${NCM_GUARD_S}s of SHELL_READY (state=$st): unbind, remove NCM, bind ACM-only"
            echo "" > "$G/UDC" 2>/dev/null
            rm -f "$G/configs/c.1/ncm.fs" 2>/dev/null
            echo "acm" > "$G/configs/c.1/strings/0x409/configuration" 2>/dev/null
            echo "$UDC_NAME" > "$G/UDC" 2>/dev/null; rc=$?
            # review m2: one more try after 1 s if the ACM-only bind failed
            if [ $rc != 0 ]; then sleep 1; echo "$UDC_NAME" > "$G/UDC" 2>/dev/null; rc2=$?; else rc2=-; fi
            printf 'state=fallback\nif=none\nll=%s\nport=%s\n' "$NCM_LL" "$NCM_PORT" > /run/fs.ncm.tmp && mv /run/fs.ncm.tmp /run/fs.ncm
            log "NCM_FALLBACK rebind rc=$rc retry=$rc2 udc=$(cat "$G/UDC" 2>/dev/null) ncm-link=$([ -e "$G/configs/c.1/ncm.fs" ] && echo yes || echo no)"
        elif [ $seen = 4 ]; then
            log "NCM_GUARD done after ${el}s: no host attached (state=$st); nothing changed"
        else
            log "NCM_GUARD done after ${el}s: $([ $seen = 1 ] && echo 'the host configured the gadget' || { [ $seen = 2 ] && echo 'fs-ack received'; } || echo 'configured or acked at the last check'); nothing changed"
        fi
    ) &
fi

# ---------------------------------------------------------------------------
# 7. Hold (replaces stage 1 §7): HOST_ACK recorded only; reboot at the
#    deadline, at the ack window without an ack, or ~1 s after fs-done.
#    Never returns.
# ---------------------------------------------------------------------------
fs_hold_loop
