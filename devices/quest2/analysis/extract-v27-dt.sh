#!/bin/bash
# FrameShift — Quest 2 offline analysis: split and decompile the v2.7 boot DTBs
# (boot header v2: DTB section) and the dtbo table. Offline only; reads the
# held v2.7 OTA extract, writes into devices/quest2/analysis/v27-dt/.
# Run inside WSL (needs python3, dtc). 2026-10-09.
#
# PROXY ONLY: the PM's unit runs v59 (4.19.157); these are v2.7 (4.19.325)
# artifacts. On the unit ABL chose dtb_idx=2 / dtbo_idx=1 from the v59 images
# (baseline getprop); the v2.7 index order differs (see v27-dt/INDEX.txt).
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
FW=$ROOT/firmware/quest2/v2.7-user_ota
OUT=$ROOT/devices/quest2/analysis/v27-dt
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$OUT"
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP
python3 -I -B "$ROOT/build/third_party/mkbootimg/unpack_bootimg.py" --boot_img "$FW/boot.img" --out "$W/boot" > "$OUT/boot-header.txt"
python3 -I - "$W/boot/dtb" "$FW/dtbo.img" "$W" <<'EOF'
import struct, sys
dtb, dtbo, w = sys.argv[1:4]
d = open(dtb, "rb").read(); i = n = 0
while True:
    j = d.find(b"\xd0\x0d\xfe\xed", i)
    if j < 0: break
    sz = struct.unpack(">I", d[j+4:j+8])[0]
    open("%s/v27-dtb%d.dtb" % (w, n), "wb").write(d[j:j+sz]); n += 1; i = j + sz
d = open(dtbo, "rb").read()
magic, total, hsz, esz, cnt, off, pg, ver = struct.unpack(">8I", d[:32])
assert magic == 0xd7b7ab1e, "not a dtbo table"
for k in range(cnt):
    sz, o = struct.unpack(">2I", d[off+k*esz:off+k*esz+8])
    open("%s/v27-dtbo%d.dtb" % (w, k), "wb").write(d[o:o+sz])
EOF
{
  echo "# v2.7 DT index (file: model | board-id | msm-id | sha256 of the binary blob)"
  for f in "$W"/v27-dtb*.dtb; do
    b=$(basename "$f" .dtb)
    dtc -q -I dtb -O dts -o "$W/$b.dts" "$f"
    echo "$b: $(grep -m1 'model =' "$W/$b.dts" | tr -d '\t') | $(grep -m1 'qcom,board-id' "$W/$b.dts" | tr -d '\t') | $(grep -m1 'qcom,msm-id' "$W/$b.dts" | tr -d '\t') | $(sha256sum "$f" | cut -c1-64)"
  done
} > "$OUT/INDEX.txt"
# Keep the two proxies closest to the unit: kona v2.1 base (hw-revision 20001 [C])
# and the Hollywood (DVT) overlay (unit model-revision "Hollywood (DVT)" [M]).
cp "$W/v27-dtb1.dts" "$W/v27-dtbo0.dts" "$OUT/"
( cd "$OUT" && sha256sum v27-dtb1.dts v27-dtbo0.dts boot-header.txt INDEX.txt > SHA256SUMS )
cat "$OUT/INDEX.txt"
