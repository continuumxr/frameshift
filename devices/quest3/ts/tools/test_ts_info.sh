#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# fs-ts-info.sh fixtures: every role under the reviewed stage-1 busybox (aarch64, qemu-user) on a
# fake sysfs tree (FS_ROOT), plus the lexical no-write guard of the K1a info-script pattern.
# Offline; no device.   bash tools/test_ts_info.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
S=$HERE/target/fs-ts-info.sh
BB_SRC=${FS_BUSYBOX:-<repo>/build/third_party/busybox/busybox}
QEMU=$(command -v qemu-aarch64 || true)
[ -n "$QEMU" ] || { echo "SKIP: qemu-aarch64 missing"; exit 1; }
[ "$(sha256sum "$BB_SRC" | cut -c1-64)" = c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02 ] \
    || { echo "REFUSED: busybox is not the reviewed binary"; exit 1; }
W=$(mktemp -d /tmp/fsti.XXXXXX); trap 'rm -rf "$W"' EXIT
n=0; bad=0
t() { n=$((n + 1)); if [ "$2" = 0 ]; then echo "PASS $1"; else bad=$((bad + 1)); echo "FAIL $1 ${3:-}"; fi; }
# lexical guard: the only redirections are input "<" and "2>/dev/null"; no writing command
body=$(grep -v '^[[:space:]]*#' "$S")
w=$(printf '%s\n' "$body" | sed 's#2>/dev/null##g' | grep -n '>' || true)
t 'no output redirection other than 2>/dev/null' "$([ -z "$w" ] && echo 0 || echo 1)" "$w"
c=$(printf '%s\n' "$body" | grep -nwE 'tee|dd|rm|mv|cp|mkdir|mknod|insmod|rmmod|modprobe|ln|touch|chmod|chown|mount|umount|reboot|poweroff|sysctl|kill|setprop|stop|start' || true)
t 'no writing command' "$([ -z "$c" ] && echo 0 || echo 1)" "$c"
# fake tree
F=$W/root
mk() { mkdir -p "$(dirname "$F/$1")"; printf '%s\n' "$2" > "$F/$1"; }
mk proc/meminfo 'MemTotal:        7798880 kB'
printf 'MemFree: 1 kB\nMemAvailable:    5000000 kB\n' >> "$F/proc/meminfo"
mk sys/class/thermal/thermal_zone0/type cpu-0-0-0; mk sys/class/thermal/thermal_zone0/temp 31000
mk sys/class/thermal/thermal_zone1/type soc-usr
mkdir -p "$F/sys/bus/iio/devices/iio:device2"; mk sys/bus/iio/devices/iio:device2/name vadc
mk sys/bus/iio/devices/iio:device2/in_temp_pmk8550_die_temp_input 35500
mk sys/class/remoteproc/remoteproc1/name 3000000.remoteproc-adsp; mk sys/class/remoteproc/remoteproc1/state offline
mk sys/class/hwmon/hwmon3/name pwmfan; mk sys/class/hwmon/hwmon3/rpm 0
mk sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq 307200
mk sys/module/qcom_dload_mode/parameters/download_mode 0
mk sys/class/leds/red/max_brightness 255
printf 'qcom_tsens 98304 0 - Live 0x0\nmsm_drm 1 0 - Live 0x0\n' > "$W/mods"; mkdir -p "$F/proc"; cp "$W/mods" "$F/proc/modules"
mk proc/device-tree/model 'Oculus Eureka (synthetic)'
run() { FS_ROOT=$F "$QEMU" "$BB_SRC" sh "$S" "$1" 2>&1; }
o=$(run mem); t 'mem: MemTotal and MemAvailable' "$([ "$o" = "$(printf 'MemTotal: 7798880 kB\nMemAvailable: 5000000 kB')" ] && echo 0 || echo 1)" "$o"
o=$(run zones); t 'zones: type and temp, ERR for an unreadable temp' "$(printf '%s' "$o" | grep -qx 'Z thermal_zone0 cpu-0-0-0 31000' && printf '%s' "$o" | grep -qx 'Z thermal_zone1 soc-usr ERR' && echo 0 || echo 1)" "$o"
o=$(run iio); t 'iio: device name and the PMIC channel' "$(printf '%s' "$o" | grep -qx 'IT in_temp_pmk8550_die_temp_input 35500' && echo 0 || echo 1)" "$o"
o=$(run rproc); t 'rproc: the v2.7 ADSP name and state' "$(printf '%s' "$o" | grep -qx 'R remoteproc1 3000000.remoteproc-adsp offline' && echo 0 || echo 1)" "$o"
o=$(run fan); t 'fan: pwmfan attributes, ERR when absent' "$(printf '%s' "$o" | grep -qx 'HA rpm 0' && printf '%s' "$o" | grep -qx 'HA silent_rpm ERR' && echo 0 || echo 1)" "$o"
o=$(run cpufreq); t 'cpufreq: per policy' "$(printf '%s' "$o" | grep -qx 'F policy0 cpuinfo_min_freq 307200' && echo 0 || echo 1)" "$o"
o=$(run dload); t 'dload: the raw text' "$([ "$o" = 'DL 0' ] && echo 0 || echo 1)" "$o"
rm "$F/sys/module/qcom_dload_mode/parameters/download_mode"
o=$(run dload); t 'dload: ABSENT when the module is not loaded' "$([ "$o" = 'DL ABSENT' ] && echo 0 || echo 1)" "$o"
o=$(run leds); t 'leds' "$([ "$o" = 'L red 255' ] && echo 0 || echo 1)" "$o"
o=$(run modules); t 'modules: names and count' "$(printf '%s' "$o" | grep -qx 'MODCOUNT 2' && printf '%s' "$o" | grep -qx 'MOD qcom_tsens' && echo 0 || echo 1)" "$o"
o=$(run model); t 'model' "$([ "$o" = 'M Oculus Eureka (synthetic)' ] && echo 0 || echo 1)" "$o"
o=$(run bogus); t 'unknown role refused' "$([ "$o" = 'FSTI1 error=role' ] && echo 0 || echo 1)" "$o"
before=$(cd "$F" && find . -type f -exec sha256sum {} + | sort | sha256sum)
for r in mem zones iio rproc fan cpufreq dload leds modules model; do run $r > /dev/null; done
after=$(cd "$F" && find . -type f -exec sha256sum {} + | sort | sha256sum)
t 'the tree is unchanged after every role' "$([ "$before" = "$after" ] && echo 0 || echo 1)"
echo "fs-ts-info: $((n - bad))/$n pass"
[ "$bad" = 0 ]
