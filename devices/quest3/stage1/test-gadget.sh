#!/bin/bash
# Offline execution test of init.sh section 4 (ACM gadget via configfs).
#
# Runs the EXACT section-4 lines of init.sh (from the "# 4. ACM gadget" banner
# up to and including the UDC_BOUND stage) under a POSIX shell inside a bwrap
# sandbox with a fake configfs and a fake UDC, and stubs for fail/stage/log/
# led/mount. Added after the revision-3 re-review found a mangled line
# continuation that `sh -n` cannot detect (a syntax check is not execution).
#
# Cases: positive; uppercase readback (kernel formatting variant); failed open;
# failed write() (ENOSPC); wrong readback; missing UDC. Exit 0 only if every
# case behaves as expected.
# Usage: test-gadget.sh [shell]   (default: dash). The device's busybox is
# aarch64 and is not executed here: busybox-ash behaviour is [M-static].
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SH=${1:-dash}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# exact section 4: from its banner through the UDC_BOUND stage line
awk '/^# 4\. ACM gadget via configfs/{f=1} f{print} f&&/^stage UDC_BOUND/{exit}' "$HERE/init.sh" | tr -d '\r' > "$W/sec4.sh"
grep -q '^stage UDC_BOUND' "$W/sec4.sh" || { echo "could not extract section 4"; exit 2; }

run_case() {   # run_case <name> <expect: PASS|FAIL:<substring>> <setup snippet>
    name=$1; expect=$2; setup=$3
    cat > "$W/run.sh" <<EOF
NONCE=5c03f6f696db9ad0
UDC_NAME=a600000.dwc3
G=/config/usb_gadget/fs
mount() { :; }
stage() { echo "STAGE \$1 \$2" >> /tmp/out; }
log()   { echo "LOG \$*" >> /tmp/out; }
led()   { :; }
fail()  { echo "FAIL \$1 \$2" >> /tmp/out; exit 99; }
mkdir -p /config/usb_gadget /sys/class/udc/\$UDC_NAME
echo configured > /sys/class/udc/\$UDC_NAME/state
$setup
. /tmp/sec4.sh
echo "REACHED_END" >> /tmp/out
EOF
    : > "$W/out"
    # tmpfs root (so /config and /sys can be created), host /usr read-only;
    # a case that hangs (e.g. reading /dev/full) is killed and counts as failed
    timeout -k 5 30 bwrap --tmpfs / --ro-bind /usr /usr \
          --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
          --dir /config --dir /sys --bind "$W" /tmp \
          --dev /dev --proc /proc --unshare-all --die-with-parent \
          "$SH" ${SHFLAGS:-} /tmp/run.sh >/dev/null 2>&1
    rc=$?
    got=$(cat "$W/out")
    case "$expect" in
        # reaching UDC_BOUND implies the section's own "bind did not stick" check passed
        PASS)  if [ $rc -eq 0 ] && echo "$got" | grep -q REACHED_END && echo "$got" | grep -q "^STAGE UDC_BOUND"; then ok=1; else ok=0; fi ;;
        FAIL:*) want=${expect#FAIL:}
               if [ $rc -eq 99 ] && echo "$got" | grep -q "FAIL .*$want" && ! echo "$got" | grep -q REACHED_END; then ok=1; else ok=0; fi ;;
    esac
    if [ $ok -eq 1 ]; then echo "PASS  $name"; else echo "FAIL  $name (rc=$rc)"; echo "$got" | sed 's/^/        /'; FAILED=1; fi
    if [ "$expect" = PASS ]; then echo "$got" | grep -E "GADGET_IDENTITY|STAGE UDC_BOUND" | sed 's/^/        /'; fi
}

FAILED=0
echo "shell: $SH ${SHFLAGS:-} ($(command -v "$SH"))"
echo "section 4 sha256: $(sha256sum "$W/sec4.sh" | cut -c1-16)…  ($(wc -l < "$W/sec4.sh") lines from init.sh)"
run_case "G1 positive: identity written, read back, UDC bound" PASS ""
run_case "G2 kernel prints hex in uppercase: still accepted" PASS \
    'cat() { case "$1" in */idVendor) echo 0x1D6B ;; */bDeviceClass) echo 0xEF ;; *) command cat "$@" ;; esac; }'
run_case "G3 serialnumber cannot be opened: fail(acm write)" "FAIL:acm write serialnumber" \
    'mkdir -p "$G/strings/0x409/serialnumber"'
run_case "G4 idVendor reads back wrong: fail(acm readback)" "FAIL:acm readback idVendor" \
    'cat() { case "$1" in */idVendor) echo 0x18d1 ;; *) command cat "$@" ;; esac; }'
run_case "G5 subclass reads back wrong: fail(acm readback)" "FAIL:acm readback bDeviceSubClass" \
    'cat() { case "$1" in */bDeviceSubClass) echo 0x00 ;; *) command cat "$@" ;; esac; }'
run_case "G6 UDC absent: fail(udc)" "FAIL:udc UDC" \
    'rmdir /sys/class/udc/$UDC_NAME 2>/dev/null; rm -rf /sys/class/udc/$UDC_NAME'
run_case "G7 idProduct write() fails (ENOSPC): fail(acm write)" "FAIL:acm write idProduct" \
    'mkdir -p "$G" && ln -s /dev/full "$G/idProduct"'
echo
if [ $FAILED -eq 0 ]; then echo "TOTAL: all gadget cases behaved as expected"; exit 0; else echo "TOTAL: FAILURES"; exit 1; fi
