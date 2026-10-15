#!/bin/bash
# FrameShift Quest 2 channel — WSL side of the host transport fixtures (offline).
# Started by host/test-transport-tcp.ps1 through wsl.exe; never touches a device.
#   host-fixture-wsl.sh sim  TAG PORT ADDR NONCE DL AW   simulated PID 1 + fs-rpcd (aarch64, qemu)
#   host-fixture-wsl.sh evil TAG BASEPORT NONCE [ADDR]    the scripted misbehaving device
#   host-fixture-wsl.sh stop TAG                          kill everything under /tmp/fsq2host-TAG
# State lives in /tmp/fsq2host-TAG (run/, rec, evil/). Every process has a hard lifetime.
set -u
export PYTHONDONTWRITEBYTECODE=1   # -I implies -E (variable ignored); every python call also passes -B
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"
HERE=$ROOT/devices/quest2/channel
Q3C=$ROOT/devices/quest3/common
cmd=$1; TAG=$2
case "$TAG" in *[!a-z0-9]*|'') echo "bad tag"; exit 2 ;; esac
W=/tmp/fsq2host-$TAG
case "$cmd" in
sim)
    PORT=$3 ADDR=$4 NONCE=$5 DL=$6 AW=$7
    rm -rf "$W"; mkdir -p "$W/bin" "$W/run"
    [ "$(sha256sum "$ROOT/build/third_party/busybox/busybox" | cut -c1-64)" = c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02 ] || { echo "busybox mismatch"; exit 1; }
    cp "$ROOT/build/third_party/busybox/busybox" "$W/bin/busybox"; chmod 0755 "$W/bin/busybox"
    for a in sh cut cat echo sleep head rm mv printf mkfifo sync; do ln -s busybox "$W/bin/$a"; done
    cp "$HERE/build/fs-rpcd" "$W/bin/fs-rpcd"; chmod 0755 "$W/bin/fs-rpcd"
    printf '#!%s/bin/sh\nread -r u _ < /proc/uptime\necho "${u%%%%.*} ${1:-none} pid=$$ via=fork" >> "$FS_REC"\nexit 1\n' "$W" > "$W/bin/fake-reboot"
    printf '#!%s/bin/sh\nread -r u _ < /proc/uptime\necho "${u%%%%.*} ${1:-none} pid=$$ via=final" >> "$FS_REC"\nwhile :; do sleep 3600; done\n' "$W" > "$W/bin/fake-final"
    chmod 0755 "$W/bin/fake-reboot" "$W/bin/fake-final"
    RUNNER=; RUNNER_S=
    if [ "${8:-}" = fsb1 ]; then
        # a real FSB1 record: common/target/fsb1-enc.sh (read only) + the reviewed fs-supervise
        cp "$Q3C/build/fs-supervise" "$W/bin/fs-supervise"; chmod 0755 "$W/bin/fs-supervise"
        mkdir -p "$W/bb"; for a in sh cat printf base64 awk sha256sum cut wc sed grep tr mkdir uname; do ln -s "$W/bin/busybox" "$W/bb/$a"; done
        cat > "$W/bin/runner" <<EOF
#!$W/bin/busybox sh
PATH=$W/bb
FSB1_SUP=$W/bin/fs-supervise
. $Q3C/target/fsb1-enc.sh
c=\$1
case "\$c" in *[!0-9a-f]*|'') exit 2 ;; esac
D=$W/rec.\$c; mkdir "\$D" || exit 3
fsb1_begin "\$D/rec" fixture $NONCE "\$c" 2 || exit 4
fsb1_run "\$D/rec" 1 uname "\$D" 5 -- $W/bin/busybox uname -s || exit 5
fsb1_run "\$D/rec" 2 echo "\$D" 5 -- $W/bin/busybox printf 'x\ny\n' || exit 6
fsb1_end "\$D/rec" $NONCE "\$c" || exit 7
fsb1_emit "\$D/rec"
EOF
        chmod 0755 "$W/bin/runner"; RUNNER=$W/bin/runner; RUNNER_S=20
    elif [ "${8:-}" = fail ]; then
        # a runner that starts a record and fails: fs-rpcd must send FSR1 runner-exit, never the partial bytes
        printf '#!%s/bin/busybox sh\nprintf "\\nFSB1 BEGIN v=1 partial\\n"\nexit 1\n' "$W" > "$W/bin/runner"
        chmod 0755 "$W/bin/runner"; RUNNER=$W/bin/runner; RUNNER_S=20
    fi
    cd /
    exec timeout 900 setsid env -i PATH="$W/bin" HOLD="$Q3C/target/pid1-hold.sh" FS_RUN="$W/run" FS_REC="$W/rec" \
        RUNNER="$RUNNER" RUNNER_S="$RUNNER_S" \
        FS_UPTIME=/proc/uptime FS_REBOOT_BIN="$W/bin/fake-reboot" FS_REBOOT_FINAL="$W/bin/fake-final" \
        FS_REBOOT_FALLBACK="$W/bin/fake-reboot fallback" DL="$DL" AW="$AW" RPCD="$W/bin/fs-rpcd" \
        ADDR="$ADDR" PORT="$PORT" NONCE="$NONCE" \
        /usr/bin/qemu-aarch64 "$W/bin/busybox" sh "$HERE/tools/sim-pid1.sh" > "$W/sim.stdout" 2>&1
    ;;
evil)
    BASE=$3 NONCE=$4 ADDR=${5:-127.0.0.1}
    rm -rf "$W"; mkdir -p "$W/evil"
    cd /
    exec timeout 900 python3 -I -B "$HERE/tools/evil_device.py" "$BASE" "$W/evil" "$NONCE" "$ADDR"
    ;;
stop)
    pkill -9 -f "$W/" 2>/dev/null
    pkill -9 -f "evil_device.py [0-9]* $W/evil" 2>/dev/null
    exit 0
    ;;
*) echo "usage"; exit 2 ;;
esac
