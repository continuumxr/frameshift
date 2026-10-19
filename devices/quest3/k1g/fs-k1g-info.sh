#!/bin/busybox sh
# FrameShift K1g — fs-k1g-info.sh <role>: the READ-ONLY fact helper of the K1g runner (k1g/fs-k1g.sh); an
# adapted copy of k1a/fs-k1a-info.sh (not edited) with one more role, blkguard.
# Installed as /lib/fs/fs-k1g-info.sh; run by fs-k1g under /bin/fs-supervise (empty environment, cwd /,
# its own session), one role per FSB1 step. It reads /proc, /sys, /config and /run only; it writes
# nothing (no file, no sysfs node, no tty) and opens no block or DRM device. stderr goes to stdout so the
# step's err stream stays empty in practice (the runner's MAXLINES still counts both streams at their caps).
#
# Roles (the FSB1 step ids, in record order):
#   kernel   uname -r, uname -v, /proc/version (our pinned build identity), /proc/cmdline
#   config   the running kernel's own config (/proc/config.gz, CONFIG_IKCONFIG_PROC=y): its size, SHA-256 of the
#            decompressed text (= the gated .config: kgate config-binding), and the K1a option lines
#   mem      MemTotal, MemFree, MemAvailable, CmaTotal (FS-A-013 §2.2: MemTotal recorded)
#   modules  count and taint, the loader's lines from /run/fs.log, /proc/modules (name, refcount, state)
#   kmsg     one read of the kernel log: lines of a symbol-version or vermagic refusal (expected: none), and every
#            kernel WARNING / BUG / oops-class line with counts (FS-R-012 §3: WARNINGs reported in every phase)
#   fs       /proc/filesystems (devtmpfs, tmpfs; btrfs/autofs are modules of OUR build and are NOT loaded:
#            K1a loads the stock vendor modules only) and /proc/mounts
#   usb      the gadget (ACM only, J-179): UDC and state, the linked functions, product and serial
#   log      /run/fs.log and /run/fs.stages
#   blkguard the result of PID 1's fs-blkguard proof (init.sh section 2b), from RAM: the RESULT line first (so a
#            cut-off report still carries it), fs-supervise's report, the probe's compact report and the byte count
#            of its stderr, then the first 8 lines of /proc/fs_blkguard (mode, seal, allowlist, module latch,
#            hazards, refusal counters) as read NOW, after the proof
PATH=/bin
export PATH
exec 2>&1
G=/config/usb_gadget/fs
UDC=a600000.dwc3
K1A_OPTS='DEVTMPFS|DEVTMPFS_MOUNT|FHANDLE|AUTOFS_FS|BTRFS_FS|BTRFS_FS_POSIX_ACL|TMPFS|TMPFS_XATTR|TMPFS_POSIX_ACL|BLK_DEV_RAM|BLK_DEV_RAM_COUNT|BLK_DEV_RAM_SIZE|SYSVIPC|POSIX_MQUEUE|USER_NS|PID_NS|MODVERSIONS|MODULE_SIG|LOCALVERSION_AUTO'

[ $# -eq 1 ] || { echo "== usage"; exit 2; }
case "$1" in
kernel)
    echo "== uname-r $(uname -r)"
    echo "== uname-v $(uname -v)"
    echo "== proc-version"
    cat /proc/version
    echo "== cmdline"
    cat /proc/cmdline
    ;;
config)
    if [ ! -r /proc/config.gz ]; then echo "== config absent"; exit 0; fi
    echo "== config_gz_bytes $(cat /proc/config.gz | wc -c)"
    echo "== config_sha256 $(zcat /proc/config.gz | sha256sum | cut -d' ' -f1)"
    echo "== k1a-options"
    zcat /proc/config.gz | grep -E "^(# )?CONFIG_($K1A_OPTS)( is not set|=)"
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
    ;;
kmsg)
    # ONE read of the kernel log (from boot to now, as far as the ring buffer holds it), three filters:
    # the module loader's symbol-version / vermagic refusals (expected: none; a FAIL), the taint notes ("taints
    # kernel": reported only, never a FAIL; review MAJOR-2), and every kernel WARNING / BUG / oops-class line
    # (FS-R-012 §3: the classifier reports kernel WARNINGs in every phase). Each section ends at the next "==" line.
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
    ;;
fs)
    echo "== filesystems"
    cat /proc/filesystems
    echo "== mounts"
    cat /proc/mounts
    ;;
usb)
    echo "== udc $(cat "$G/UDC" 2>/dev/null) state=$(cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
    echo "== config-functions $(ls "$G/configs/c.1" 2>/dev/null | grep -E '^[a-z0-9_]+[.][a-z0-9_]+$' | tr '\n' ' ')"
    echo "== product $(cat "$G/strings/0x409/product" 2>/dev/null) serial=$(cat "$G/strings/0x409/serialnumber" 2>/dev/null)"
    ;;
log)
    echo "== fs.log"
    cat /run/fs.log
    echo "== fs.stages"
    cat /run/fs.stages
    ;;
blkguard)
    echo "== result $(grep -m1 '^FSBG-PROBE RESULT:' /run/fsbg.out 2>/dev/null)"
    echo "== supervise"
    cat /run/fsbg.sup 2>/dev/null
    echo "== err-bytes $(cat /run/fsbg.err 2>/dev/null | wc -c)"
    echo "== probe"
    cat /run/fsbg.out 2>/dev/null
    echo "== guard"
    head -n 8 /proc/fs_blkguard 2>/dev/null
    ;;
*)
    echo "== unknown-role"
    exit 2
    ;;
esac
exit 0
