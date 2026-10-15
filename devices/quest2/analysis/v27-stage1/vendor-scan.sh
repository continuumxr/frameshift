#!/bin/bash
# FrameShift Quest 2 v2.7 — read-only scan of the OTA vendor image (offline).
# Usage (WSL; needs e2fsprogs debugfs): vendor-scan.sh <vendor.img> > vendor-scan.txt
# debugfs opens the image read-only by default; nothing is mounted or written
# except a temporary copy of the rc files under a mktemp directory.
set -eu
V=$1
O=$(mktemp -d)
trap 'rm -rf "$O"' EXIT
echo "# vendor-scan of $(basename "$V") sha256=$(sha256sum "$V" | cut -d' ' -f1)"
for d in /etc/init/hw /etc/init; do
  for f in $(debugfs -R "ls $d" "$V" 2>/dev/null | tr -s ' ' '\n' | grep 'rc$'); do
    debugfs -R "cat $d/$f" "$V" > "$O/$f" 2>/dev/null
  done
done
echo "== rc files"; ls "$O" | tr '\n' ' '; echo
echo "== build.prop (selected)"
debugfs -R "cat /build.prop" "$V" 2>/dev/null | grep -E '^(ro.vendor.build.version.incremental|ro.virtual_ab.enabled|ro.boot.dynamic_partitions|ro.board.platform|ro.board.first_api_level)='
echo "== fstab.hollywood: misc and partitions"
debugfs -R "cat /etc/fstab.hollywood" "$V" 2>/dev/null | grep -E '^(system|vendor|odm|product|system_ext|/dev/block)' | awk '{print $1, $2, $3}'
echo "== watchdog / softdog references in vendor rc (expect none)"
grep -n -i -E 'watchdog|softdog' "$O"/* || echo "(none)"
echo "== USB gadget (init.kona.usb.rc): UDC and NCM lines"
grep -n -E 'UDC|ncm|idVendor|idProduct' "$O/init.kona.usb.rc"
echo "== governor writes in vendor rc"
grep -n -i 'scaling_governor' "$O"/* || echo "(none)"
echo "== /lib/modules/modules.load"
debugfs -R "cat /lib/modules/modules.load" "$V" 2>/dev/null | tr '\n' ' '; echo
echo "== /lib/modules/*.ko"
debugfs -R "ls /lib/modules" "$V" 2>/dev/null | tr -s ' ' '\n' | grep -E 'ko$' | sort | tr '\n' ' '; echo
echo "== ueventd.rc: misc"
debugfs -R "cat /etc/ueventd.rc" "$V" 2>/dev/null | grep -n -i 'misc'
