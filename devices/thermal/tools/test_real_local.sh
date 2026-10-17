#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# LOCAL-ONLY differential against Meta's real vendor images (design §4.5.7,
# §7.1): the C reader, the Python reference reader and debugfs must agree;
# the hashes and parse digests must equal tables/known-firmware.tsv; and the
# supervisor must accept each record (limits=meta-runtime). Rev 3 (PM
# 2026-10-15, METACFG-SPEC M-21a): an image whose build.prop enables Virtual
# A/B (the v2.7 rows) must instead be refused by both readers with the same
# record (status vab-policy) and run on the built-in table; its JSON (by
# debugfs) must still equal the table row's. The images are OTA vendor
# images wrapped in a synthetic super (wrap_super.py): no real super is
# exercised (the T0 lpdump probe settles the real layout). Reads the images
# read-only; writes only scratch files under $W (deleted at the end); prints
# hashes and status lines only, never file content. Skips a row whose image
# is absent. Nothing it produces is committed except its summary lines.
# usage: test_real_local.sh BUILD_DIR
set -uo pipefail
B=${1:?build dir}
T=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "$HOME/fsth-real.XXXXXX")
trap 'rm -rf "$W"' EXIT
FW="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"/firmware
pass=0; fail=0; skip=0
row() { # label device image [expected reader status, default ok]
    local label=$1 dev=$2 img=$3 r=$W/$1 want_st=${4:-ok}
    if [ ! -r "$img" ]; then echo "SKIP $label (image absent)"; skip=$((skip+1)); return; fi
    mkdir -p $r/root/sys/class/block/sda7 $r/root/dev $r/root/proc
    local size; size=$(python3 -I "$T/tools/fix/wrap_super.py" "$img" $r/super.img)
    printf 'DEVNAME=sda7\nPARTNAME=super\n' > $r/root/sys/class/block/sda7/uevent
    ln -s $r/super.img $r/root/dev/sda7
    printf 'androidboot.slot_suffix = "_a"\n' > $r/root/proc/bootconfig
    printf 'androidboot.slot_suffix=_a\n' > $r/root/proc/cmdline
    "$B/fs-metacfg-test" $dev 1 --root $r/root --super-size $size --allow-regular > $r/c.rec
    python3 -I "$T/tools/ref/metacfg_ref.py" --image $r/super.img --device $dev --slot-suffix _a \
        --super-size $size --out $r/py.rec > /dev/null
    local dj dv want
    dj=$(debugfs -R "cat /etc/thermal_info_config.json" "$img" 2>/dev/null | sha256sum | cut -c1-64)
    dv=$(debugfs -R "cat /etc/vr_runtime_power_mitigation.json" "$img" 2>/dev/null | sha256sum | cut -c1-64)
    want=$(awk -F'\t' -v L=$label '$1==L{print $5" "$6" "$7}' "$T/tables/known-firmware.tsv")
    local acc; acc=$("$B/fs-thermald" --device $dev --record $r/c.rec --accept-only 2>/dev/null)
    local cj cd
    cj=$(echo "$acc" | sed -n 's/.*json_sha256=\([0-9a-f]*\).*/\1/p')
    cd=$(echo "$acc" | sed -n 's/.*digest=\([0-9a-f]*\).*/\1/p')
    if [ "$want_st" != ok ]; then
        local st; st=$(python3 -I "$T/tools/mcrec.py" $r/c.rec | sed -n 's/^status=\([^ ]*\).*/\1/p')
        if cmp -s $r/c.rec $r/py.rec && [ "$st" = "$want_st" ] && [ "${want%% *}" = "$dj" ] && \
           echo "$acc" | grep -q "limits=builtin reason=reader:$want_st"; then
            echo "PASS $label: C record == Python record, status $st; json $dj == table row; built-in table"
            pass=$((pass+1))
        else
            echo "FAIL $label: cmp=$(cmp -s $r/c.rec $r/py.rec && echo same || echo differ) status=$st json=$dj accept=[$acc]"
            fail=$((fail+1))
        fi
        return
    fi
    if cmp -s $r/c.rec $r/py.rec && [ "$cj" = "$dj" ] && [ "$want" = "$cj $cd $dv" ] && \
       echo "$acc" | grep -q 'limits=meta-runtime reason=- .*vr_export=1'; then
        echo "PASS $label: C record == Python record; json $dj == debugfs; digest $cd == table; accepted"
        pass=$((pass+1))
    else
        echo "FAIL $label: cmp=$(cmp -s $r/c.rec $r/py.rec && echo same || echo differ) json=$cj debugfs=$dj accept=[$acc]"
        fail=$((fail+1))
    fi
}
row eureka-v27 eureka "$HOME/work/fs006-kernel/v27/vendor.img" vab-policy
row eureka-v66 eureka "$FW/quest3/v66_unit1_super/vendor_a.img"
row hollywood-v27 hollywood "$FW/quest2/v2.7-user_ota/vendor.img" vab-policy
echo "real images (local only): $pass pass, $fail fail, $skip skipped"
[ $fail -eq 0 ]
