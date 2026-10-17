#!/bin/busybox sh
# FrameShift TS — composition identity rows (README D-T0-2): read-only roles
# run by each TS image's FSB1 runner before fs-thermald starts, in the K1a
# fs-k1a-info.sh pattern (one role per supervised step; output to stdout;
# never a redirection into a file, never a writing command: checked by
# tools/test_ts_info.sh). They record, under OUR kernel and module
# composition, what T0 recorded under Android: the zone types, the PMIC IIO
# channels, the remoteproc names, the fan hwmon, the cpufreq policies,
# download_mode (the softdog precondition, EXEC-SPEC E-2), the LEDs, the
# loaded modules and MemTotal.
#   fs-ts-info.sh <role>     role: mem zones iio rproc fan cpufreq dload leds modules model
# FS_ROOT (tests only) prefixes every path.
R=${FS_ROOT:-}
case "$1" in
mem)
    while read -r k v u; do
        case "$k" in MemTotal:|MemAvailable:) echo "$k $v $u" ;; esac
    done < "$R/proc/meminfo"
    ;;
zones)
    for z in "$R"/sys/class/thermal/thermal_zone*; do
        [ -d "$z" ] || continue
        t=""; v=""
        read -r t 2>/dev/null < "$z/type"
        read -r v 2>/dev/null < "$z/temp"
        echo "Z ${z##*/} ${t:-?} ${v:-ERR}"
    done
    ;;
iio)
    for d in "$R"/sys/bus/iio/devices/iio:device*; do
        [ -d "$d" ] || continue
        n=""; read -r n 2>/dev/null < "$d/name"
        echo "I ${d##*/} ${n:-?}"
        for f in "$d"/in_temp_*_input; do
            [ -f "$f" ] || continue
            v=""; read -r v 2>/dev/null < "$f"
            echo "IT ${f##*/} ${v:-ERR}"
        done
    done
    ;;
rproc)
    for r in "$R"/sys/class/remoteproc/remoteproc*; do
        [ -d "$r" ] || continue
        n=""; s=""
        read -r n 2>/dev/null < "$r/name"
        read -r s 2>/dev/null < "$r/state"
        echo "R ${r##*/} ${n:-?} ${s:-?}"
    done
    ;;
fan)
    for h in "$R"/sys/class/hwmon/hwmon*; do
        [ -d "$h" ] || continue
        n=""; read -r n 2>/dev/null < "$h/name"
        echo "H ${h##*/} ${n:-?}"
        if [ "$n" = pwmfan ]; then
            for a in rpm pwm rpm_per_sec silent_rpm; do
                v=""; read -r v 2>/dev/null < "$h/$a"
                echo "HA $a ${v:-ERR}"
            done
        fi
    done
    ;;
cpufreq)
    for p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        for a in affected_cpus cpuinfo_min_freq cpuinfo_max_freq scaling_governor scaling_max_freq; do
            v=""; read -r v 2>/dev/null < "$p/$a"
            echo "F ${p##*/} $a ${v:-ERR}"
        done
    done
    ;;
dload)
    v=""; read -r v 2>/dev/null < "$R/sys/module/qcom_dload_mode/parameters/download_mode"
    echo "DL ${v:-ABSENT}"
    ;;
leds)
    for l in "$R"/sys/class/leds/*; do
        [ -d "$l" ] || continue
        m=""; read -r m 2>/dev/null < "$l/max_brightness"
        echo "L ${l##*/} ${m:-?}"
    done
    ;;
modules)
    n=0
    while read -r name size refs rest; do
        echo "MOD $name"
        n=$((n + 1))
    done < "$R/proc/modules"
    echo "MODCOUNT $n"
    ;;
model)
    m=""; read -r m 2>/dev/null < "$R/proc/device-tree/model"
    echo "M ${m:-?}"
    ;;
*)
    echo "FSTI1 error=role"
    exit 2
    ;;
esac
exit 0
