#!/bin/bash
# FrameShift stage 3c — time the FSB1 encoder (common/target/fsb1-enc.sh rev 5, pinned, unchanged) at the
# MAXIMUM per-phase streams under qemu-aarch64 with the reviewed busybox (DESIGN.md §9.1 "Encode re-timed at
# the 56 KiB stream"): r2's maximum record (probe stdout 16384 B + pattern stdout 57344 B, the r1/r2 cap) and
# r3's (16384 B + 28672 B). Each fsb1_step and the fsb1_end are timed separately, 3 repetitions; the
# largest per-step time is the input of tools/check-timing-3c.py (max(1 s, measured x 1.5) per step).
# Run in WSL:  bash tools/encode-timing.sh > /tmp/enc.txt, then append the hand-recorded ENCODE_COLD lines of the
# current fixtures/encode-timing.txt (grep '^ENCODE_COLD\|^# recorded\|^# repetition' ...) and replace the fixture: the
# cold repetition seen in the integration pass is kept on record (build review MINOR-2; check-timing-3c.py reads it).
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"
BB=$ROOT/build/third_party/busybox/busybox
ENC=$ROOT/devices/quest3/common/target/fsb1-enc.sh
D=$(mktemp -d)
trap 'rm -rf "${D:?}"' EXIT
[ "$(sha256sum "$BB" | cut -c1-64)" = c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02 ] || { echo "busybox is not the reviewed binary"; exit 1; }
mkdir -p "$D/bin"
for a in sh cat printf base64 awk sha256sum cut wc sed grep tr date; do ln -s "$BB" "$D/bin/$a"; done
echo "# stage 3c encode timing  $(date -u +%Y-%m-%dT%H:%M:%SZ); fsb1-enc.sh $(sha256sum "$ENC" | cut -c1-16); busybox c2f279d1d5640a0f (reviewed); qemu: $(qemu-aarch64 --version | head -1)"
SUPLINE='FSUP1 end=exited code=0 sig=0 errno=0 ms=1234 term_ms=-1 kill_ms=-1 out_total=%d out_kept=%d err_total=0 err_kept=0 strays=0 pipes=eof why=none END'
max=0
for spec in "r2 16384 57344" "r3 16384 28672"; do
    set -- $spec
    ph=$1; c1=$2; c2=$3
    for rep in 1 2 3; do
        W=$D/$ph-$rep; mkdir -p "$W"
        head -c "$c1" /dev/urandom > "$W/1.out"; head -c "$c2" /dev/urandom > "$W/2.out"; : > "$W/1.err"; : > "$W/2.err"
        printf "$SUPLINE\n" "$c1" "$c1" > "$W/1.sup"; printf "$SUPLINE\n" "$c2" "$c2" > "$W/2.sup"
        cat > "$W/t.sh" <<EOF
. $ENC
ms() { read -r u _ < /proc/uptime; echo "\$u"; }
fsb1_begin $W/record s3c_$ph 0123456789abcdef 0123456789abcdef0123456789abcdef 2 || exit 11
t0=\$(ms); fsb1_step $W/record 1 probe $W/1.sup $W/1.out $W/1.err || exit 12
t1=\$(ms); fsb1_step $W/record 2 pattern $W/2.sup $W/2.out $W/2.err || exit 13
t2=\$(ms); fsb1_end $W/record 0123456789abcdef 0123456789abcdef0123456789abcdef || exit 14
t3=\$(ms); echo "\$t0 \$t1 \$t2 \$t3 \$(wc -l < $W/record)"
EOF
        out=$(PATH=$D/bin /usr/bin/qemu-aarch64 "$BB" sh "$W/t.sh")
        set -- $out
        s1=$(echo "$2 - $1" | bc); s2=$(echo "$3 - $2" | bc); se=$(echo "$4 - $3" | bc)
        echo "ENCODE $ph rep=$rep step1(probe ${c1} B) ${s1} s  step2(pattern ${c2} B) ${s2} s  end ${se} s  record_lines=$5"
        for v in $s1 $s2 $se; do if [ "$(echo "$v > $max" | bc)" = 1 ]; then max=$v; fi; done
    done
done
echo "ENCODE_MAX_STEP_S $max"
