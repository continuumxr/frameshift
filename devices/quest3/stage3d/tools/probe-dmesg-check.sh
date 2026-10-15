#!/bin/bash
# FrameShift stage 3d (J-141) — check fs-probe.sh's dmesg filter on a v2.7-like kernel log: the 66 mode-validation
# lines one connector probe writes on v2.7 (dsi_conn_mode_valid "could not find mode 4128x2208x<17..49>vid" and
# dsi_display_find_mode "failed to find mode for v_active ...", as in Unit 2's probe1 post dmesg) around five real
# display lines. The exact awk program of fs-probe.sh (extracted as tools/dmesg-timing.sh does) runs under busybox awk
# (qemu-aarch64). Offline. Run in WSL:
#   bash tools/probe-dmesg-check.sh BUSYBOX STAGE3D_FS_PROBE STAGE3C_FS_PROBE OUTDIR
# Prints CHECK lines; exit 1 on any FAIL. The stage-3c probe is the negative control: it keeps the noise, and with the
# 4096-byte budget the real lines before the noise are lost.
set -u
BB=$1; P3D=$2; P3C=$3; OUT=$4
D=$(mktemp -d)
trap 'rm -rf "${D:?}"' EXIT
fails=0
check() { if [ "${2:-}" = 1 ]; then echo "CHECK $1 PASS ${3:-}"; else echo "CHECK $1 FAIL ${3:-}"; fails=$((fails + 1)); fi; }
python3 -I -B - "$D/log" <<'PY'
import sys
out, t = [], 23.900000
def add(s):
    global t
    t += 0.000073
    out.append("[%12.6f] %s" % (t, s))
add("[drm:dsi_display_set_mode [msm_drm]] REAL-1 dsi display mode set 4128x2208x90vid")
add("[drm:sde_encoder_virt_enable [msm_drm]] REAL-2 sde encoder enable")
add("panel_event_notifier: REAL-3 panel power on")
for r in range(49, 16, -1):
    add("[drm:dsi_display_find_mode [msm_drm]] *ERROR* [msm-dsi-error]: [meta,eureka_panel_sharp] failed to find mode for v_active 2208 h_active 4128 fps %d pclk 0" % (r - 1 if r > 17 else 17))
    add("[drm:dsi_conn_mode_valid [msm_drm]] *ERROR* [msm-dsi-error]: could not find mode 4128x2208x%dvid" % r)
add("[drm:dsi_panel_set_backlight [msm_drm]] REAL-4 backlight level 127")
add("[drm:sde_kms_underrun [msm_drm]] *ERROR* REAL-5 underrun on intf 1")
add("usb 1-1: not a display line (filtered out by the probe's word filter)")
open(sys.argv[1], "w").write("\n".join(out) + "\n")
PY
prog() { sed -n "/dmesg 2>\/dev\/null | awk/,/^    \[ -f/p" "$1" | sed '1s/.*awk -v t="$_last" -v f="$H\/dmesg.last.new" '"'"'//' | sed '$d' | sed '$s/'"'"'$//' > "$2"; }
prog "$P3D" "$D/p3d.awk"; prog "$P3C" "$D/p3c.awk"
mkdir -p "$D/bin"; for a in sh awk cat; do ln -s "$BB" "$D/bin/$a"; done
run() { PATH=$D/bin /usr/bin/qemu-aarch64 "$BB" sh -c "cat $D/log | awk -v t=$2 -v f=$D/last.$3 -f $1" > "$OUT/probe-dmesg-$3.txt" 2>&1; }
run "$D/p3d.awk" 0 v27; run "$D/p3c.awk" 0 v66
run "$D/p3d.awk" "$(cat "$D/last.v27")" v27-again
O=$OUT/probe-dmesg-v27.txt; C=$OUT/probe-dmesg-v66.txt; A=$OUT/probe-dmesg-v27-again.txt
nl=$(grep -c 'could not find mode\|failed to find mode for v_active' "$O")
real=$(grep -c 'REAL-[1-5]' "$O")
check "stage3d probe: the 66 mode-validation lines are not kept" "$([ "$nl" = 0 ] && echo 1)" "kept=$nl"
check "stage3d probe: the 5 real display lines are kept, in order" "$([ "$real" = 5 ] && [ "$(grep -o 'REAL-[1-5]' "$O" | tr -d '\n')" = REAL-1REAL-2REAL-3REAL-4REAL-5 ] && echo 1)" "kept=$real"
check "stage3d probe: one summary line with the count (66)" "$(grep -qx -- '-- dmesg: 66 mode-validation line(s) not kept (dsi_conn_mode_valid / dsi_display_find_mode)' "$O" && echo 1)"
check "stage3d probe: the counts line (5 new matching, 5 shown) and the newest timestamp remembered" \
      "$(grep -qx -- '-- dmesg: 5 new matching line(s), 5 shown' "$O" && [ "$(cat "$D/last.v27")" = "$(tail -2 "$D/log" | head -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/')" ] && echo 1)" "last=$(cat "$D/last.v27")"
check "stage3d probe: a later point with no new line keeps nothing, counts 0" \
      "$(grep -qx -- '-- dmesg: 0 new matching line(s), 0 shown' "$A" && grep -qx -- '-- dmesg: 0 mode-validation line(s) not kept (dsi_conn_mode_valid / dsi_display_find_mode)' "$A" && echo 1)"
c_real=$(grep -c 'REAL-[1-3]' "$C"); c_nl=$(grep -c 'could not find mode\|failed to find mode for v_active' "$C")
check "negative control: the stage-3c probe keeps the noise and loses REAL-1..3 to the 4096-byte budget" \
      "$([ "$c_real" = 0 ] && [ "$c_nl" -gt 20 ] && echo 1)" "stage3c kept $c_nl noise lines, REAL-1..3: $c_real"
exit $fails
