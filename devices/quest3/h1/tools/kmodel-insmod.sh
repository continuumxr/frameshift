#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# FrameShift H-1 test harness: a simulated kernel module loader standing in for `insmod` (host bash, offline).
#   kmodel-insmod.sh /path/name.ko [params...]
# It models the 5.10 facts the loader depends on (README §1, each [M-static] from the v2.7 source):
#   - the module appears in /sys/module/<name>/initstate as "coming" while its init runs and "live" as soon
#     as the init returned, BEFORE the async wait below (kernel/module.c:3784 vs :3799-3800); a failed init
#     removes it (kernel/module.c show_initstate, do_init_module);
#   - a dependency that is still "coming" is waited for (resolve_symbol_wait; scaled to KM_SYMWAIT s), a
#     dependency that is not loaded at all fails at once ("Unknown symbol");
#   - a driver that prefers asynchronous probing schedules its probe as async work; after a module's init
#     (with the module already live), a load WITHOUT the async_probe parameter waits for ALL pending async work
#     (async_synchronize_full, kernel/module.c:3799-3800); with async_probe it does not (:3979-3981);
#   - a synchronous probe runs inside the module's own init; a driver of the default probe type probes
#     asynchronously when its module was loaded with async_probe (drivers/base/dd.c:778-796); a probe may
#     bind, defer or fail;
#   - binding creates the driver's device link and the class nodes listed for the module; the driver link
#     appears under /sys/module/<name>/drivers/ (drivers/base/module.c module_add_driver).
# Scenario lines (KM_SCEN), one per module, unspecified modules are plain libraries (no driver):
#   <name> [init=<ms>|hang] [rc=<n>] [probe=none|sync|forcesync|async] [pms=<ms>|hang] [result=bind|defer|fail]
#          [devs=<n>] [needs=<a,b>] [nodes=<rel>=<val>;<rel>=<val>]   (rel under KM_SYS)
# Every call is logged to $KM_STATE/calls with the firmware-loader settings seen at that moment.
set -u
f=$1; shift
params="$*"
name=$(basename "$f" .ko); name=${name//-/_}
SYS=$KM_SYS; ST=$KM_STATE
mkdir -p "$ST/pending"
fw="$(cat "$KM_PROC/sys/kernel/firmware_config/force_sysfs_fallback" 2>/dev/null || echo -),$(cat "$KM_PROC/sys/kernel/firmware_config/ignore_sysfs_fallback" 2>/dev/null || echo -),$(cat "$SYS/class/firmware/timeout" 2>/dev/null || echo -)"
echo "$name params=[${params}] fw=$fw pid=$$ ppid=$PPID t=$(cut -d' ' -f1 /proc/uptime)" >> "$ST/calls"
echo $$ >> "$ST/pids"
[ -f "$f" ] || { echo "insmod: can't insert '$f': No such file or directory" >&2; exit 1; }
[ -e "$SYS/module/$name" ] && { echo "insmod: can't insert '$f': File exists" >&2; exit 1; }

init=0; rc=0; probe=none; pms=0; result=bind; devs=1; needs=""; nodes=""
line=$(grep -m1 "^$name\( \|$\)" "$KM_SCEN" 2>/dev/null || true)
for kv in ${line#"$name"}; do
    case $kv in
    init=*) init=${kv#init=} ;; rc=*) rc=${kv#rc=} ;; probe=*) probe=${kv#probe=} ;;
    pms=*) pms=${kv#pms=} ;; result=*) result=${kv#result=} ;; devs=*) devs=${kv#devs=} ;;
    needs=*) needs=${kv#needs=} ;; nodes=*) nodes=${kv#nodes=} ;;
    esac
done
msleep() { if [ "$1" = hang ]; then while :; do sleep 1; done; else sleep "$(awk "BEGIN{print $1/1000}")"; fi; }
async=0
for p in $params; do case $p in async_probe|async_probe=*) async=1 ;; esac; done

# symbol resolution
for d in ${needs//,/ }; do
    w=0
    while :; do
        s=$(cat "$SYS/module/$d/initstate" 2>/dev/null || echo absent)
        [ "$s" = live ] && break
        if [ "$s" = absent ] || [ "$w" -ge $((${KM_SYMWAIT:-3} * 20)) ]; then
            echo "insmod: can't insert '$f': unknown symbol in module, or unknown parameter" >&2; exit 1
        fi
        sleep 0.05; w=$((w + 1))
    done
done
mkdir -p "$SYS/module/$name"
echo coming > "$SYS/module/$name/initstate"

bind() {
    local i
    for i in $(seq 1 "$devs"); do
        mkdir -p "$SYS/devices/platform/$name.$i"
        ln -s "$SYS/devices/platform/$name.$i" "$SYS/bus/platform/drivers/$name/$name.$i"
    done
    local IFS=';'
    for n in $nodes; do
        mkdir -p "$(dirname "$SYS/${n%%=*}")"
        echo "${n#*=}" > "$SYS/${n%%=*}"
    done
}
doprobe() {   # runs the probe: bind, defer (stays unbound) or fail
    msleep "$pms"
    [ "$result" = bind ] && bind
    return 0
}

msleep "$init"
if [ "$rc" != 0 ]; then
    rm -rf "$SYS/module/$name"
    echo "insmod: can't insert '$f': Operation not permitted" >&2
    exit "$rc"
fi
# probe type (drivers/base/dd.c:778-796): PREFER_ASYNCHRONOUS -> async; FORCE_SYNCHRONOUS -> sync; the
# default type is async when the module was loaded with async_probe, else sync
[ "$probe" = sync ] && [ "$async" = 1 ] && probe=async
[ "$probe" = forcesync ] && probe=sync
if [ "$probe" != none ]; then
    mkdir -p "$SYS/bus/platform/drivers/$name" "$SYS/module/$name/drivers"
    ln -s "$SYS/module/$name" "$SYS/bus/platform/drivers/$name/module"
    ln -s "$SYS/bus/platform/drivers/$name" "$SYS/module/$name/drivers/platform:$name"
    if [ "$probe" = sync ]; then
        doprobe
    else
        tok="$ST/pending/$name.$$"; : > "$tok"
        ( doprobe; rm -f "$tok" ) &
        echo $! >> "$ST/pids"
    fi
fi
echo live > "$SYS/module/$name/initstate"   # MODULE_STATE_LIVE (kernel/module.c:3784)
if [ "$async" = 0 ]; then   # async_synchronize_full() (:3799-3800): every pending async probe, from any module
    while [ -n "$(ls -A "$ST/pending")" ]; do sleep 0.05; done
fi
exit 0
