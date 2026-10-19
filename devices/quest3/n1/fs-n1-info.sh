#!/bin/busybox sh
# FrameShift N1 — fs-n1-info.sh <role>: the READ-ONLY fact helper of the N1 runner (n1/fs-n1.sh). Derived from
# k1a/fs-k1a-info.sh (its kernel, config, mem, modules and kmsg sections unchanged; "fs" dropped; usb extended into
# "net"). Installed as /lib/fs/fs-n1-info.sh; run by fs-n1 under /bin/fs-supervise (empty environment, cwd /, its own
# session), one role per FSB1 step. It reads /proc, /sys, /config and /run only; it writes nothing (no file, no sysfs
# node, no tty), opens no block or DRM device, opens no socket. stderr goes to stdout so the step's err stream stays
# empty in practice (the runner's MAXLINES still counts both streams at their caps).
#
# Roles (the FSB1 step ids, in record order; step 5 "xfer" is /bin/fs-xfer, not this helper):
#   kernel   uname -r, uname -v, /proc/version, /proc/cmdline; the running config (/proc/config.gz): its size,
#            SHA-256 (= the gated k1a.config) and the K1a option lines plus the NCM/IPv6 ones
#   mem      MemTotal, MemFree, MemAvailable, CmaTotal (FS-R-013 s.2: MemTotal valid and positive is REQUIRED)
#   modules  count and taint, the loader's lines, /proc/modules; then ONE kernel-log read: symbol-version or
#            vermagic refusals (expected: none), taint notes, every WARNING / BUG / oops-class line with counts
#   net      the gadget (UDC and state, the linked functions, configuration, product, serial), the NCM function
#            (dev_addr, host_addr, ifname), /run/fs.ncm, the interfaces, the NCM interface (MAC, operstate, carrier,
#            mtu, flags, ifindex, its IPv6 sysctls), /proc/net/if_inet6, IPv4 (/proc/net/fib_trie: no local IPv4
#            address expected), the IPv6 routes, and EVERY socket table BEFORE the transfer (tcp, tcp6, udp, udp6,
#            udplite, udplite6, raw, raw6, packet): expected no TCP LISTEN row and no UDP, raw or packet socket
#   log      FIRST a second, bounded kernel-log read AFTER the transfer (FS-R-014 s.5; kmsg_post below), then
#            /run/fs.log and /run/fs.stages, EVERY socket table AFTER the transfer (expected: no listener left), the
#            interface's counters and /proc/net/if_inet6 again
PATH=/bin
export PATH
exec 2>&1
G=/config/usb_gadget/fs
UDC=a600000.dwc3
K1A_OPTS='DEVTMPFS|DEVTMPFS_MOUNT|FHANDLE|AUTOFS_FS|BTRFS_FS|BTRFS_FS_POSIX_ACL|TMPFS|TMPFS_XATTR|TMPFS_POSIX_ACL|BLK_DEV_RAM|BLK_DEV_RAM_COUNT|BLK_DEV_RAM_SIZE|SYSVIPC|POSIX_MQUEUE|USER_NS|PID_NS|MODVERSIONS|MODULE_SIG|LOCALVERSION_AUTO'
N1_OPTS='USB_CONFIGFS_NCM|USB_F_NCM|USB_CONFIGFS_ACM|USB_U_ETHER|IPV6|INET|PACKET'

# the NCM interface name from /run/fs.ncm (init.sh 4c), used only when it is a plain name
ncm_if() {
    nif=none
    if [ -f /run/fs.ncm ]; then
        while IFS='=' read -r k v; do [ "$k" = if ] && nif=$v; done < /run/fs.ncm
    fi
    case "$nif" in ''|*[!a-z0-9]*) nif=none ;; esac
}
# every IP and packet socket table, as the kernel lists it, in ONE read (grep -H prefixes each line with its file; the
# header lines included; a missing table shows as grep's error line). Few forks: under QEMU user mode every fork costs.
socks() {
    echo "== sockets $1"
    grep -H '' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 /proc/net/udplite /proc/net/udplite6 /proc/net/raw /proc/net/raw6 /proc/net/packet
}

# The post-transfer kernel-log check (FS-R-014 s.5): ONE more read of the whole kernel log (busybox dmesg: the ring
# buffer as it stands after step 5 ended), summarised by ONE awk pass (few forks), printed FIRST in the log role so a
# cap on the later sections cannot cut it, and closed by an end marker (its absence = truncated or cut short). The
# step 3 read (modules role) is kept unchanged as the pre-transfer evidence; the host compares the two (first line,
# line count: an unchanged first line and no fewer lines = the post read covers everything the pre read saw plus all
# that came after; anything else = coverage not proven). Lines:
#   == kmsg-post read=ok|fail rc=<dmesg status> bytes=<length read>      (fail: nothing else but the end marker;
#                                     dmesg's stderr is captured with its output, so its error text never precedes
#                                     this line; on a failure bytes counts that text)
#   == kmsg-post-lines <n>
#   == kmsg-post-first <the first 16 bytes of the first line>            (as the modules role's first=)
#   == kmsg-post-last <the first 16 bytes of the last line>
#   == kmsg-post-modver <n>          the modules role's refusal filter, counted
#   == kmsg-post-taint <n>           lines with "taints kernel", counted
#   == kmsg-post-warnings <w> warning-lines, <b> bug-lines, <l> lines, <k> listed   (the modules role's filters)
#   | <the last k (at most 30) of those l lines, each cut at 200 bytes>
#   == kmsg-post-ncm <n> lines, <k> listed
#   | <the last k (at most 10) ncm/usb0/gadget/dwc3 lines, each cut at 160 bytes>
#   == kmsg-post-end
# Bounded: a 1 s pause (deferred teardown after fs-xfer's exit may still log), then ONE plain dmesg (no option: it
# never clears the log; it reads the kernel's whole buffer, 256 KiB on the unit: the stock vendor command line's
# log_buf_len=256K overrides CONFIG_LOG_BUF_SHIFT=17, seen in K1a record 0ac82c68's cmdline) and ONE awk; at most
# about 8.1 KB of output. The "same first line" rule relies on every line's [timestamp] prefix (CONFIG_PRINTK_TIME=y,
# no printk.time=0 on the command line). Coverage ends at this read (before fs-done): a line logged later is not seen.
kmsg_post() {
    sleep 1
    d=$(dmesg 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$d" ]; then
        echo "== kmsg-post read=fail rc=$rc bytes=${#d}"
        echo "== kmsg-post-end"
        return 0
    fi
    echo "== kmsg-post read=ok rc=0 bytes=${#d}"
    printf '%s\n' "$d" | awk -v W=30 -v U=10 '
        NR == 1 { f = substr($0, 1, 16) }
        { z = substr($0, 1, 16); y = tolower($0) }
        y ~ /disagrees about version|version magic|no symbol version|unknown symbol|module_layout|exec format error|module verification/ { m++ }
        y ~ /taints kernel/ { t++ }
        /WARNING:|BUG:|Oops|Call trace:|cut here|Unable to handle kernel|Internal error:|Kernel panic|INFO: task .* blocked/ {
            k++; if ($0 ~ /WARNING:/) w++
            if ($0 ~ /BUG:|Oops|Unable to handle kernel|Internal error:|Kernel panic/) b++
            q[k % W] = substr($0, 1, 200)
        }
        y ~ /ncm|usb0|gadget|dwc3/ { n++; u[n % U] = substr($0, 1, 160) }
        END {
            printf "== kmsg-post-lines %d\n== kmsg-post-first %s\n== kmsg-post-last %s\n", NR, f, z
            printf "== kmsg-post-modver %d\n== kmsg-post-taint %d\n", m, t
            s = 1; if (W < k) s = k - W + 1
            printf "== kmsg-post-warnings %d warning-lines, %d bug-lines, %d lines, %d listed\n", w, b, k, k - s + 1
            for (i = s; i <= k; i++) print "| " q[i % W]
            s = 1; if (U < n) s = n - U + 1
            printf "== kmsg-post-ncm %d lines, %d listed\n", n, n - s + 1
            for (i = s; i <= n; i++) print "| " u[i % U]
            print "== kmsg-post-end"
        }'
}

[ $# -eq 1 ] || { echo "== usage"; exit 2; }
case "$1" in
kernel)
    echo "== uname-r $(uname -r)"
    echo "== uname-v $(uname -v)"
    echo "== proc-version"
    cat /proc/version
    echo "== cmdline"
    cat /proc/cmdline
    if [ ! -r /proc/config.gz ]; then echo "== config absent"; exit 0; fi
    echo "== config_gz_bytes $(cat /proc/config.gz | wc -c)"
    echo "== config_sha256 $(zcat /proc/config.gz | sha256sum | cut -d' ' -f1)"
    echo "== k1a-options"
    zcat /proc/config.gz | grep -E "^(# )?CONFIG_($K1A_OPTS)( is not set|=)"
    echo "== n1-options"
    zcat /proc/config.gz | grep -E "^(# )?CONFIG_($N1_OPTS)( is not set|=)"
    ;;
mem)
    grep -E '^(MemTotal|MemFree|MemAvailable|CmaTotal):' /proc/meminfo
    ;;
modules)
    echo "== loaded $(wc -l < /proc/modules)"
    echo "== tainted $(cat /proc/sys/kernel/tainted)"
    echo "== loader"
    grep -E 'MODULE_INDEX|MODULE_FAIL|MODLIST|STAGE=MODULES_' /run/fs.log
    echo "== proc-modules"
    cut -d' ' -f1,3,5 /proc/modules
    # K1a's kmsg section, unchanged: ONE read of the kernel log, three filters
    d=$(dmesg)
    echo "== kmsg-lines $(printf '%s\n' "$d" | wc -l) first=$(printf '%s\n' "$d" | head -n 1 | cut -c1-16)"
    m=$(printf '%s\n' "$d" | grep -iE 'disagrees about version|version magic|no symbol version|unknown symbol|module_layout|exec format error|module verification')
    if [ -n "$m" ]; then
        echo "== modver-matches $(printf '%s\n' "$m" | wc -l)"
        printf '%s\n' "$m" | tail -n 20
    else
        echo "== modver-matches 0"
    fi
    t=$(printf '%s\n' "$d" | grep -i 'taints kernel')
    if [ -n "$t" ]; then
        echo "== taint-lines $(printf '%s\n' "$t" | wc -l)"
        printf '%s\n' "$t" | tail -n 5
    else
        echo "== taint-lines 0"
    fi
    w=$(printf '%s\n' "$d" | grep -E 'WARNING:|BUG:|Oops|Call trace:|cut here|Unable to handle kernel|Internal error:|Kernel panic|INFO: task .* blocked')
    if [ -n "$w" ]; then
        echo "== warnings $(printf '%s\n' "$w" | grep -c 'WARNING:') warning-lines, $(printf '%s\n' "$w" | grep -cE 'BUG:|Oops|Unable to handle kernel|Internal error:|Kernel panic') bug-lines, $(printf '%s\n' "$w" | wc -l) lines"
        printf '%s\n' "$w" | tail -n 60
    else
        echo "== warnings 0 warning-lines, 0 bug-lines, 0 lines"
    fi
    echo "== ncm-kmsg"
    printf '%s\n' "$d" | grep -iE 'ncm|usb0|gadget|dwc3' | tail -n 20
    ;;
net)
    # sysfs/configfs/procfs attributes are read with grep -H (one fork for many files; "path:value" lines)
    echo "== udc"
    grep -H '' "$G/UDC" "/sys/class/udc/$UDC/state"
    printf '== config-functions '
    for x in "$G"/configs/c.1/*.*; do [ -e "$x" ] && printf '%s ' "${x##*/}"; done
    echo
    echo "== gadget"
    grep -H '' "$G/strings/0x409/product" "$G/strings/0x409/serialnumber" "$G/configs/c.1/strings/0x409/configuration"
    F=$G/functions/ncm.fs
    if [ -d "$F" ]; then
        echo "== ncm-function"
        grep -H '' "$F/dev_addr" "$F/host_addr" "$F/ifname"
    else
        echo "== ncm-function none"
    fi
    echo "== fs.ncm"
    grep -H '' /run/fs.ncm
    printf '== ifaces '
    for x in /sys/class/net/*; do [ -e "$x" ] && printf '%s ' "${x##*/}"; done
    echo
    ncm_if
    if [ "$nif" != none ] && [ -d "/sys/class/net/$nif" ]; then
        S=/sys/class/net/$nif
        P=/proc/sys/net/ipv6/conf/$nif
        echo "== if $nif"
        grep -H '' $S/address $S/operstate $S/carrier $S/mtu $S/flags $S/ifindex
        echo "== ipv6conf $nif"
        grep -H '' $P/disable_ipv6 $P/addr_gen_mode $P/accept_dad $P/dad_transmits $P/accept_ra $P/autoconf $P/router_solicitations $P/forwarding
    else
        echo "== if none"
    fi
    echo "== ipv6conf all"
    grep -H '' /proc/sys/net/ipv6/conf/all/accept_dad /proc/sys/net/ipv6/conf/all/forwarding /proc/sys/net/ipv4/ip_forward
    echo "== if_inet6"
    cat /proc/net/if_inet6
    echo "== fib_trie"
    cat /proc/net/fib_trie
    echo "== ipv6_route"
    cat /proc/net/ipv6_route
    socks before
    ;;
log)
    kmsg_post
    echo "== fs.log"
    cat /run/fs.log
    echo "== fs.stages"
    cat /run/fs.stages
    echo "== fs.ncm"
    grep -H '' /run/fs.ncm
    socks after
    ncm_if
    if [ "$nif" != none ] && [ -d "/sys/class/net/$nif" ]; then
        S=/sys/class/net/$nif/statistics
        echo "== counters $nif"
        grep -H '' $S/rx_bytes $S/tx_bytes $S/rx_packets $S/tx_packets $S/rx_errors $S/tx_errors $S/rx_dropped $S/tx_dropped /sys/class/net/$nif/operstate
    else
        echo "== counters none"
    fi
    echo "== if_inet6-after"
    cat /proc/net/if_inet6
    ;;
*)
    echo "== unknown-role"
    exit 2
    ;;
esac
exit 0
