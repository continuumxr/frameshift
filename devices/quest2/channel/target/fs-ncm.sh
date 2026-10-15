#!/bin/busybox sh
# FrameShift Quest 2 — USB NCM gadget, IPv6 link-local address and the
# fixed-verb responder (busybox ash; SOURCED by the Quest 2 stage-1 PID 1,
# never run on its own). Design: devices/quest2/channel/README.md.
# Offline draft: never run on a device.
#
# Applets used (all in the reviewed busybox 1.37 applet table,
# build/stage1/20261008T024856Z-112740d1bd6a4ecf/applets.txt):
#   mkdir ln cat tr cut ls sleep ip mount grep (kill and echo are ash builtins)
#
# The caller provides, before sourcing:
#   NONCE               16 lowercase hex (baked by the builder)
#   log MSG             RAM-first logger (never the USB link)
#   fail STAGE DETAIL   records, waits out ERR_DELAY, reboots; never returns
# and may override:
#   FS_CONFIG=/config  FS_SYS=/sys  FS_PROC=/proc  FS_RUN=/run
#   FS_UDC_EXPECT=""   if set, the single UDC must have exactly this name
#                      (v59: a600000.dwc3; v2.7: [O] until Q2-P1)
#   FS_UDC_WAIT=10     seconds to wait for a UDC to appear
#   FS_ROLE_WAIT=5     seconds to wait for the UDC to leave "not attached"
#                      before the guarded mode=peripheral fallback
#   FS_SSUSB=$FS_SYS/devices/platform/soc/a600000.ssusb
#   FS_RPC_BIN=/bin/fs-rpcd  FS_RPC_PORT=47101
#   FS_RPC_RUNNER=""  FS_RPC_RUNNER_S=""   (stage 2a/3a only: fs-collect)
#   FS_RPC_WAIT=12      seconds for the responder's "FSRPC listening" line
#
# Sequence (stage-1 init, after modules would have been loaded — none on v2.7):
#   fs_ncm_ids        derive the MACs and the link-local address from NONCE
#   fs_ncm_udc        find the single UDC
#   fs_ncm_gadget     configfs gadget, serial FS-<nonce>, function ncm.fs, bind
#   fs_ncm_role       guarded peripheral fallback (only if still unattached)
#   fs_ncm_net        sysctls, link up, fe80::<nonce>/64, wait until not tentative
#   fs_rpc_start      the responder as a child; PID 1 continues to its own
#                     deadline loop (common/target/pid1-hold.sh fs_hold_loop)
#
# Rules:
#   - Every write goes through _fsn_wr (a failed write calls fail) and is read
#     back with an exact string comparison. No shell arithmetic on file
#     contents (an arithmetic error aborts ash, i.e. PID 1).
#   - Nothing here reads host-controlled bytes. The responder is the only code
#     that sees host bytes, and it never hands them to a shell.
#   - The address, the MACs and the USB serial are functions of NONCE only.

: "${FS_CONFIG:=/config}" "${FS_SYS:=/sys}" "${FS_PROC:=/proc}" "${FS_RUN:=/run}"
: "${FS_UDC_EXPECT:=}" "${FS_UDC_WAIT:=10}" "${FS_ROLE_WAIT:=5}"
: "${FS_SSUSB:=$FS_SYS/devices/platform/soc/a600000.ssusb}"
: "${FS_RPC_BIN:=/bin/fs-rpcd}" "${FS_RPC_PORT:=47101}"
: "${FS_RPC_RUNNER:=}" "${FS_RPC_RUNNER_S:=}" "${FS_RPC_WAIT:=12}"
FS_GADGET=$FS_CONFIG/usb_gadget/fs
FS_NCM_FN=ncm.fs

_fsn_wr() {      # _fsn_wr FILE VALUE: write, fail() on error
    echo "$2" > "$1" 2>/dev/null || fail ncm "write ${1#"$FS_CONFIG"}=$2"
}
_fsn_rd() { cat "$1" 2>/dev/null | tr 'A-F' 'a-f'; }
_fsn_expect() {  # _fsn_expect FILE VALUE: exact readback (lowercased) or fail()
    _fsn_got=$(_fsn_rd "$1")
    [ "$_fsn_got" = "$2" ] || fail ncm "readback ${1##*/}='$_fsn_got' expected '$2'"
}
_fsn_sysctl() {  # _fsn_sysctl FILE VALUE: write and read back (procfs)
    [ -f "$1" ] || fail net "missing ${1#"$FS_PROC"}"
    echo "$2" > "$1" 2>/dev/null || fail net "write ${1#"$FS_PROC"}=$2"
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] || fail net "readback ${1#"$FS_PROC"}"
}

fs_ncm_ids() {   # sets FS_DEV_MAC FS_HOST_MAC FS_LL FS_LL_RAW FS_SERIAL
    for _v in "$FS_UDC_WAIT" "$FS_ROLE_WAIT" "$FS_RPC_WAIT" "$FS_RPC_PORT"; do   # baked constants, still checked
        case "$_v" in ''|*[!0-9]*|0?*) fail ncm "bad numeric setting '$_v'" ;; esac
    done
    case "$NONCE" in *[!0-9a-f]*|'') fail ncm "bad nonce" ;; esac
    [ "${#NONCE}" -eq 16 ] || fail ncm "bad nonce length"
    _a=$(echo "$NONCE" | cut -c1-2);   _b=$(echo "$NONCE" | cut -c3-4)
    _c=$(echo "$NONCE" | cut -c5-6);   _d=$(echo "$NONCE" | cut -c7-8)
    _e=$(echo "$NONCE" | cut -c9-10)
    # locally administered unicast MACs (first octet 02 / 06), distinct by construction
    FS_DEV_MAC="02:$_a:$_b:$_c:$_d:$_e"
    FS_HOST_MAC="06:$_a:$_b:$_c:$_d:$_e"
    # the 64-bit nonce IS the interface identifier: fe80::<n0-3>:<n4-7>:<n8-11>:<n12-15>
    FS_LL="fe80::$(echo "$NONCE" | cut -c1-4):$(echo "$NONCE" | cut -c5-8):$(echo "$NONCE" | cut -c9-12):$(echo "$NONCE" | cut -c13-16)"
    FS_LL_RAW="fe80000000000000$NONCE"      # its /proc/net/if_inet6 spelling
    FS_SERIAL="FS-$NONCE"
}

fs_ncm_udc() {   # sets FS_UDC: exactly one UDC, a safe name, and FS_UDC_EXPECT if given
    _i=0
    while :; do
        _u=$(ls "$FS_SYS/class/udc" 2>/dev/null | tr '\n' ' ')
        [ -n "$_u" ] && break
        [ "$_i" -ge "$FS_UDC_WAIT" ] && fail udc "no UDC after ${FS_UDC_WAIT}s"
        sleep 1; _i=$((_i + 1))
    done
    set -- $_u
    [ $# -eq 1 ] || fail udc "expected one UDC, found: $_u"
    case "$1" in *[!A-Za-z0-9._-]*|'') fail udc "unsafe UDC name" ;; esac
    if [ -n "$FS_UDC_EXPECT" ] && [ "$1" != "$FS_UDC_EXPECT" ]; then fail udc "UDC '$1' is not '$FS_UDC_EXPECT'"; fi
    FS_UDC=$1
    log "UDC name=$FS_UDC state=$(cat "$FS_SYS/class/udc/$FS_UDC/state" 2>/dev/null)"
}

fs_ncm_gadget() {   # configfs NCM gadget; sets FS_IF (the network interface name)
    grep -q " $FS_CONFIG configfs " "$FS_PROC/mounts" 2>/dev/null || mount -t configfs none "$FS_CONFIG" 2>/dev/null
    [ -d "$FS_CONFIG/usb_gadget" ] || fail ncm "no configfs usb_gadget"
    [ -e "$FS_GADGET" ] && fail ncm "gadget already exists"
    mkdir "$FS_GADGET" || fail ncm "mkdir gadget"
    mkdir -p "$FS_GADGET/strings/0x409" "$FS_GADGET/configs/c.1/strings/0x409" "$FS_GADGET/functions/$FS_NCM_FN" \
        || fail ncm "mkdir gadget tree"
    _fsn_wr "$FS_GADGET/idVendor"        0x1d6b        # Linux Foundation
    _fsn_wr "$FS_GADGET/idProduct"       0x0104        # Multifunction Composite Gadget
    # Misc / Common / IAD: f_ncm carries its own IAD (f_ncm.c:148-155), so Windows
    # groups the two NCM interfaces and matches usbncm.inf USB\Class_02&SubClass_0d&Prot_00
    _fsn_wr "$FS_GADGET/bDeviceClass"    0xef
    _fsn_wr "$FS_GADGET/bDeviceSubClass" 0x02
    _fsn_wr "$FS_GADGET/bDeviceProtocol" 0x01
    _fsn_wr "$FS_GADGET/strings/0x409/serialnumber" "$FS_SERIAL"
    _fsn_wr "$FS_GADGET/strings/0x409/manufacturer" "FrameShift"
    _fsn_wr "$FS_GADGET/strings/0x409/product"      "FrameShift stage1 ncm"
    _fsn_wr "$FS_GADGET/configs/c.1/strings/0x409/configuration" "ncm"
    _fsn_wr "$FS_GADGET/functions/$FS_NCM_FN/dev_addr"  "$FS_DEV_MAC"
    _fsn_wr "$FS_GADGET/functions/$FS_NCM_FN/host_addr" "$FS_HOST_MAC"
    ln -s "$FS_GADGET/functions/$FS_NCM_FN" "$FS_GADGET/configs/c.1/" || fail ncm "link ncm"
    _fsn_expect "$FS_GADGET/idVendor"        0x1d6b
    _fsn_expect "$FS_GADGET/idProduct"       0x0104
    _fsn_expect "$FS_GADGET/bDeviceClass"    0xef
    _fsn_expect "$FS_GADGET/bDeviceSubClass" 0x02
    _fsn_expect "$FS_GADGET/bDeviceProtocol" 0x01
    _fsn_expect "$FS_GADGET/functions/$FS_NCM_FN/dev_addr"  "$FS_DEV_MAC"
    _fsn_expect "$FS_GADGET/functions/$FS_NCM_FN/host_addr" "$FS_HOST_MAC"
    [ "$(cat "$FS_GADGET/strings/0x409/serialnumber" 2>/dev/null)" = "$FS_SERIAL" ] || fail ncm "readback serialnumber"
    # revision 2 (review m11): the strings and the function link are read back too
    [ "$(cat "$FS_GADGET/strings/0x409/manufacturer" 2>/dev/null)" = "FrameShift" ] || fail ncm "readback manufacturer"
    [ "$(cat "$FS_GADGET/strings/0x409/product" 2>/dev/null)" = "FrameShift stage1 ncm" ] || fail ncm "readback product"
    [ "$(cat "$FS_GADGET/configs/c.1/strings/0x409/configuration" 2>/dev/null)" = "ncm" ] || fail ncm "readback configuration"
    [ -L "$FS_GADGET/configs/c.1/$FS_NCM_FN" ] && [ -d "$FS_GADGET/configs/c.1/$FS_NCM_FN" ] || fail ncm "readback link"
    # new interfaces inherit "default": no EUI-64 address, no DAD, no RA/autoconf on the NCM link
    _fsn_sysctl "$FS_PROC/sys/net/ipv6/conf/default/addr_gen_mode" 1
    _fsn_sysctl "$FS_PROC/sys/net/ipv6/conf/default/accept_dad" 0
    _fsn_sysctl "$FS_PROC/sys/net/ipv6/conf/default/accept_ra" 0
    _fsn_sysctl "$FS_PROC/sys/net/ipv6/conf/default/autoconf" 0
    echo "$FS_UDC" > "$FS_GADGET/UDC" 2>/dev/null || fail udc "bind failed"
    [ "$(cat "$FS_GADGET/UDC" 2>/dev/null)" = "$FS_UDC" ] || fail udc "bind did not stick"
    # the netdev registers at bind (f_ncm.c:1461-1463). Its name from configfs must be
    # the interface that carries our dev_addr.
    FS_IF=$(cat "$FS_GADGET/functions/$FS_NCM_FN/ifname" 2>/dev/null)
    case "$FS_IF" in *[!a-z0-9]*|'') fail net "bad ifname '$FS_IF'" ;; esac
    [ "$(_fsn_rd "$FS_SYS/class/net/$FS_IF/address")" = "$FS_DEV_MAC" ] || fail net "$FS_IF does not carry $FS_DEV_MAC"
    log "GADGET serial=$FS_SERIAL udc=$FS_UDC if=$FS_IF dev=$FS_DEV_MAC host=$FS_HOST_MAC"
}

fs_ncm_role() {  # dr_mode=drd should follow VBUS; write peripheral only if still unattached
    _i=0
    while [ "$_i" -lt "$FS_ROLE_WAIT" ]; do
        [ "$(cat "$FS_SYS/class/udc/$FS_UDC/state" 2>/dev/null)" != "not attached" ] && break
        sleep 1; _i=$((_i + 1))
    done
    _s=$(cat "$FS_SYS/class/udc/$FS_UDC/state" 2>/dev/null)
    # Best effort, NOT enforced: the result is logged, a failed write does not fail().
    # Without device mode there is no link; the host then refuses or ends INCONCLUSIVE
    # and PID 1's own deadline recovers. (VBUS may still attach later.)
    if [ "$_s" = "not attached" ] && [ -w "$FS_SSUSB/mode" ]; then
        echo peripheral > "$FS_SSUSB/mode" 2>/dev/null
        log "ROLE fallback write-rc=$? mode=$(cat "$FS_SSUSB/mode" 2>/dev/null)"
    fi
    log "ROLE udc-state=$(cat "$FS_SYS/class/udc/$FS_UDC/state" 2>/dev/null)"
}

fs_ncm_net() {   # fe80::<nonce>/64 on FS_IF, permanent and not tentative
    _c=$FS_PROC/sys/net/ipv6/conf/$FS_IF
    _fsn_sysctl "$_c/disable_ipv6" 0
    _fsn_sysctl "$_c/addr_gen_mode" 1          # before link up: no kernel-generated address
    _fsn_sysctl "$_c/accept_dad" 0             # with all/accept_dad 0 (checked): DAD skipped (addrconf.c:3969)
    _fsn_sysctl "$_c/dad_transmits" 0
    _fsn_sysctl "$_c/accept_ra" 0
    _fsn_sysctl "$_c/autoconf" 0
    _fsn_sysctl "$_c/router_solicitations" 0
    [ "$(cat "$FS_PROC/sys/net/ipv6/conf/all/accept_dad" 2>/dev/null)" = 0 ] || _fsn_sysctl "$FS_PROC/sys/net/ipv6/conf/all/accept_dad" 0
    ip link set dev "$FS_IF" up 2>/dev/null || fail net "link up"
    ip -6 addr add "$FS_LL/64" dev "$FS_IF" 2>/dev/null || fail net "addr add"
    _i=0
    while :; do
        # exactly one address on FS_IF: ours, prefix 64 (40), scope link (20), flags permanent (80)
        _l=$(grep " $FS_IF\$" "$FS_PROC/net/if_inet6" 2>/dev/null)
        set -- $_l
        if [ $# -eq 6 ] && [ "$1" = "$FS_LL_RAW" ] && [ "$3" = 40 ] && [ "$4" = 20 ] && [ "$5" = 80 ]; then break; fi
        [ "$_i" -ge 10 ] && fail net "address state: $_l"
        sleep 1; _i=$((_i + 1))
    done
    log "NET if=$FS_IF addr=$FS_LL/64 flags=permanent"
}

_fsn_state() {   # _fsn_state PID: _fsn_st = its /proc state letter, '' if it is gone
    _fsn_st=""
    [ -f "$FS_PROC/$1/stat" ] || return 0
    _fsn_l=""
    read -r _fsn_l < "$FS_PROC/$1/stat" 2>/dev/null
    _fsn_l=${_fsn_l##*") "}            # after the last ") ": comm may contain spaces
    _fsn_st=${_fsn_l%% *}
    return 0
}
_fsn_alive() { _fsn_state "$1"; case "$_fsn_st" in ''|Z) return 1 ;; esac; return 0; }   # a zombie is not alive

# Revision 3 (re-review N1): every failure after the responder was started SIGKILLs it and
# reaps it BEFORE fail(), so it can never verify/ack/collect during fail()'s ERR_DELAY wait.
# Bounded: `wait` only once /proc shows it gone or a zombie (then wait returns at once); a
# child the kernel keeps (D state, SIGKILL pending) is logged and left - it runs no more
# userspace code.
_fsn_rpc_stop() {
    [ -n "${FS_RPC_PID:-}" ] || return 0
    kill -9 "$FS_RPC_PID" 2>/dev/null
    _j=0
    while [ "$_j" -lt 3 ]; do
        _fsn_state "$FS_RPC_PID"
        case "$_fsn_st" in
            ''|Z) wait "$FS_RPC_PID" 2>/dev/null; log "RPC stopped pid=$FS_RPC_PID"; return 0 ;;
        esac
        sleep 1; _j=$((_j + 1))
    done
    log "RPC stop: pid=$FS_RPC_PID not reaped (state $_fsn_st)"
    return 0
}
_fsn_rpc_fail() { _fsn_rpc_stop; fail rpc "$1"; }

fs_rpc_start() { # the responder as a child; PID 1 never waits on it
    [ -f "$FS_RPC_BIN" ] && [ -x "$FS_RPC_BIN" ] || fail rpc "no responder"
    grep -q "^FSRPC listening" "$FS_RUN/fs.rpc.log" 2>/dev/null && fail rpc "stale fs.rpc.log"
    if [ -n "$FS_RPC_RUNNER" ]; then
        "$FS_RPC_BIN" -n "$NONCE" -a "$FS_LL" -p "$FS_RPC_PORT" -i "$FS_IF" -r "$FS_RUN" \
            -c "$FS_RPC_RUNNER" -T "$FS_RPC_RUNNER_S" </dev/null >/dev/null 2>&1 &
    else
        "$FS_RPC_BIN" -n "$NONCE" -a "$FS_LL" -p "$FS_RPC_PORT" -i "$FS_IF" -r "$FS_RUN" </dev/null >/dev/null 2>&1 &
    fi
    FS_RPC_PID=$!
    # revision 2 (review m7): RPC_READY only once the responder has logged that it listens
    # on our port (it binds after the address appears, <= 10 s) and is still alive.
    # revision 3: "alive" from /proc (kill -0 also succeeds on a zombie), and every failure
    # kills and reaps the responder first (N1).
    _i=0
    while ! grep -q "^FSRPC listening port=$FS_RPC_PORT " "$FS_RUN/fs.rpc.log" 2>/dev/null; do
        _fsn_alive "$FS_RPC_PID" || _fsn_rpc_fail "responder exited before listening"
        [ "$_i" -ge "$FS_RPC_WAIT" ] && _fsn_rpc_fail "responder not listening after ${FS_RPC_WAIT}s"
        sleep 1; _i=$((_i + 1))
    done
    _fsn_alive "$FS_RPC_PID" || _fsn_rpc_fail "responder exited after listening"
    log "RPC pid=$FS_RPC_PID addr=[$FS_LL%$FS_IF]:$FS_RPC_PORT runner=${FS_RPC_RUNNER:-none} listening"
}
