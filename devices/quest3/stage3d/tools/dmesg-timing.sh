#!/bin/bash
# FrameShift stage 3d (= stage 3c, probe unchanged) — time the probe's dmesg filter (the exact awk program of fs-probe.sh) on a
# synthetic ~1 MB kernel log under qemu-aarch64 (DESIGN.md §7: the new filter, last 80 lines, <= 200 B each, <= 4096 B; the TW/TQ margins). Run in WSL:
#   bash tools/dmesg-timing.sh > fixtures/dmesg-timing.txt
set -e
BB="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/build/third_party/busybox/busybox
P="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest3/stage3d/fs-probe.sh
D=$(mktemp -d)
trap 'rm -rf "${D:?}"' EXIT
python3 -I -B -c '
import random
r = random.Random(1)
words = ["msm_drm", "dsi_panel", "sde_kms", "cpufreq", "usb", "ext4", "binder", "regulator", "wlan", "ipa", "audio", "thermal"]
out = []
t = 0.0
n = 0
while sum(len(x) + 1 for x in out) < 1048576:
    t += r.random() * 0.01
    w = r.choice(words)
    out.append("[%12.6f] %s: %s" % (t, w, "x" * r.randint(30, 110)))
open("'$D'/log", "w").write("\n".join(out) + "\n")
print(len(out), "lines")
'
ls -l $D/log | awk '{print $5" bytes"}'
# extract the awk program from fs-probe.sh
sed -n "/dmesg 2>\/dev\/null | awk/,/^    \[ -f/p" $P | sed '1s/.*awk -v t="$_last" -v f="$H\/dmesg.last.new" '"'"'//' | sed '$d' | sed '$s/'"'"'$//' > $D/prog.awk
mkdir -p $D/bin; for a in sh awk cat; do ln -s $BB $D/bin/$a; done
cat > $D/t.sh <<EOF
cat $D/log | awk -v t=0 -v f=$D/last -f $D/prog.awk | tail -c 300
EOF
s=$(date +%s.%N); PATH=$D/bin /usr/bin/qemu-aarch64 $BB sh $D/t.sh > $D/out; e=$(date +%s.%N)
tail -2 $D/out; echo "qemu wall: $(echo "$e - $s" | bc) s (first pass over the whole 1 MB log)"
cat > $D/t2.sh <<EOF
cat $D/log | awk -v t=$(cat $D/last) -v f=$D/last2 -f $D/prog.awk | tail -c 200
EOF
s=$(date +%s.%N); PATH=$D/bin /usr/bin/qemu-aarch64 $BB sh $D/t2.sh > $D/out2; e=$(date +%s.%N)
tail -1 $D/out2; echo "qemu wall: $(echo "$e - $s" | bc) s (a later point: no new lines)"
