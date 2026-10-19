#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# FrameShift H-1/H-2 loader tests: target/fs-modload.sh under the reviewed stage-1 busybox (aarch64, qemu-user)
# on a simulated /sys and /proc, with tools/kmodel-insmod.sh standing in for the kernel's module loader.
# Offline; no device. Run in WSL:   bash devices/quest3/h1/tools/test-modload.sh [RESULTS_FILE]
# Optional (the real-list cases, local inputs only, never committed):
#   FS_H1_INDEX="<vendor_boot lib/modules dir> <vendor_dlkm lib/modules dir> <odm_dlkm lib/modules dir>"
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
H1=$(cd "$HERE/.." && pwd)
REPO=$(cd "$H1/../../.." && pwd)
LIB=$H1/target/fs-modload.sh
K1A_INIT=$REPO/devices/quest3/k1a/init.sh
BB_SRC=${FS_BUSYBOX:-<repo>/build/third_party/busybox/busybox}
BB_SHA=c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02
QEMU=$(command -v qemu-aarch64 || true)
OUT=${1:-}
[ -n "$QEMU" ] || { echo "SKIP: qemu-aarch64 missing"; exit 1; }
[ "$(sha256sum "$BB_SRC" | cut -c1-64)" = "$BB_SHA" ] || { echo "REFUSED: busybox is not the reviewed binary"; exit 1; }
W=$(mktemp -d /tmp/fsh1.XXXXXX)
cleanup() {
    for p in $(cat "$W"/*/state/pids 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    pkill -9 -f "$W/" 2>/dev/null
    [ -n "${FS_H1_KEEP:-}" ] && { echo "kept: $W"; return; }
    rm -rf "$W"
}
trap cleanup EXIT
mkdir -p "$W/bin"; cp "$BB_SRC" "$W/bin/busybox"; chmod +x "$W/bin/busybox"
cp "$HERE/kmodel-insmod.sh" "$W/bin/kmodel"; chmod +x "$W/bin/kmodel"
cp "$LIB" "$W/bin/fs-modload.sh"
n=0; bad=0; LOGT=""
t() {  # t NAME 0|1 [detail]
    n=$((n + 1))
    if [ "$2" = 0 ]; then LOGT+="PASS $1"$'\n'; echo "PASS $1"
    else bad=$((bad + 1)); LOGT+="FAIL $1 ${3:-}"$'\n'; echo "FAIL $1 ${3:-}"; fi
}
ok() { [ "$@" ] && echo 0 || echo 1; }

# --- case scaffolding ---------------------------------------------------------------------------------
new() {  # new CASE: a fresh simulated root with the kernel's default firmware settings (force=1: CONFIG_..._FALLBACK=y)
    C=$W/$1; mkdir -p "$C/root/sys/class/firmware" "$C/root/proc/sys/kernel/firmware_config" "$C/md" "$C/state" "$C/run"
    echo 1 > "$C/root/proc/sys/kernel/firmware_config/force_sysfs_fallback"
    echo 0 > "$C/root/proc/sys/kernel/firmware_config/ignore_sysfs_fallback"
    echo 60 > "$C/root/sys/class/firmware/timeout"
    echo 0 > "$C/root/proc/sys/kernel/modules_disabled"
    : > "$C/scen"; : > "$C/state/calls"; : > "$C/state/pids"; : > "$C/md/modules.softdep"; : > "$C/md/modules.dep"
}
mod() {  # mod NAME [DEP...]: a module file and its modules.dep line
    local m=$1; shift; : > "$C/md/$m.ko"
    local l="/lib/modules/$m.ko:"; for d in "$@"; do l+=" /lib/modules/$d.ko"; done
    echo "$l" >> "$C/md/modules.dep"
}
scen() { echo "$*" >> "$C/scen"; }
list() { printf '%s\n' "$@" > "$C/list"; }
pins() { echo "$C/md/modules.dep=$(sha256sum "$C/md/modules.dep" | cut -c1-64) $C/md/modules.softdep=$(sha256sum "$C/md/modules.softdep" | cut -c1-64)"; }
run() {  # run [VAR=VALUE...]: fsml_run in the reviewed busybox; sets RC, SECS; the record is $C/log
    local idx; idx=$(pins)
    {
        echo "export KM_SYS='$C/root/sys' KM_PROC='$C/root/proc' KM_STATE='$C/state' KM_SCEN='$C/scen' KM_SYMWAIT=2"
        echo "FSML_LIST='$C/list' FSML_MD='$C/md' FSML_LOG='$C/log' FSML_RUN='$C/run' FSML_ROOT='$C/root'"
        echo "FSML_INSMOD='$W/bin/kmodel' FSML_INDEX='${IDX_OVERRIDE:-$idx}' FSML_TEST=1"
        echo "FSML_LIST_SHA='${LSHA_OVERRIDE:-$(sha256sum "$C/list" | cut -c1-64)}'"
        echo "FSML_DL_S=2 FSML_DL_E=2 FSML_DL_F=2 FSML_READY_S=2 FSML_BUDGET_E=6 FSML_BUDGET_F=6 FSML_BUDGET_TOTAL=40"
        for a in "$@"; do echo "$a"; done
        echo ". '$W/bin/fs-modload.sh'"
        printf '%s\n' "${PRE:-}"
        echo 'r=0; fsml_run || r=$?'
        echo 'echo "RC=$r" > "'"$C"'/rc"; echo "OPTS=$-" >> "'"$C"'/rc"; echo "IFS=[$IFS]" >> "'"$C"'/rc"'
    } > "$C/driver.sh"
    local s e; s=$(date +%s%N)
    timeout 120 "$QEMU" "$W/bin/busybox" sh "$C/driver.sh" > "$C/out" 2>&1
    e=$(date +%s%N); SECS=$(( (e - s) / 1000000 ))   # milliseconds
    RC=$(sed -n 's/^RC=//p' "$C/rc" 2>/dev/null); RC=${RC:-none}
}
has() { grep -qE "$1" "$C/log"; }
called() { grep -q "^$1 " "$C/state/calls"; }
ncalls() { grep -c . "$C/state/calls"; }
alive() {  # the library's own insmod child for module $1 (child= in its record) is still running
    local p; p=$(grep -E "MODULE(_TIMEOUT)? $1 " "$C/log" | sed -n 's/.* child=\([0-9]*\).*/\1/p' | head -1)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
span() {  # span PHASE: seconds between "PHASE X start" and "PHASE X end"; "none" if either line is missing
    awk -v p="$1" '$3=="PHASE" && $4==p && $5=="start"{s=substr($2,3); a=1} $3=="PHASE" && $4==p && $5=="end"{e=substr($2,3); b=1}
        END{ if (a && b) print e - s; else print "none" }' "$C/log"
}
within() { [ "$1" != none ] && awk -v x="$1" -v m="$2" 'BEGIN{exit !(x <= m)}'; }
reap() { for p in $(cat "$C/state/pids" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; }

# --- 1. H-1: a hung asynchronous probe, then an S module -----------------------------------------------
new h1_hang_then_s
mod s_lib; mod fan_s s_lib; mod wifi_f
scen "fan_s probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
scen "wifi_f probe=async pms=hang"
list "S s_lib.ko live" "S fan_s.ko hwmon:pwmfan" "F wifi_f.ko auto"
run
t "hang-then-S: HANDOFF OK (rc 0)" "$(ok "$RC" = 0)" "rc=$RC"
t "hang-then-S: the S module is READY" "$(ok "$(has 'OUTCOME fan_s phase=S outcome=READY' && echo y)")"
t "hang-then-S: the hung F module is loaded with async_probe=1 and PENDING (insmod 0, device not ready)" \
  "$(ok "$(grep -q '^wifi_f params=\[async_probe=1\]' "$C/state/calls" && has 'MODULE wifi_f phase=F result=LOADED rc=0' && has 'OUTCOME wifi_f phase=F outcome=PENDING initstate=live' && echo y)")"
t "hang-then-S: S loaded before F, with no params" "$(ok "$(head -2 "$C/state/calls" | awk '{print $1, $2}' | tr '\n' ' ' | grep -q '^s_lib params=\[\] fan_s params=\[\]' && echo y)")"
t "hang-then-S: finished well inside the bound (< 15 s)" "$(ok "$SECS" -lt 15000)" "ms=$SECS"
t "hang-then-S: no insmod is left blocked (F used async_probe; S loaded before the hang)" "$(ok "$(has 'insmod_blocked=none' && echo y)")"
reap

# --- 2. negative control: K1a's loader (pinned init.sh, read-only) on the same modules -----------------
C=$W/h1_hang_then_s
mkdir -p "$C/k1a"; : > "$C/state/calls"; rm -rf "$C/root/sys/module" "$C/root/sys/bus" "$C/state/pending"; : > "$C/state/pids"
sed "s#/lib/modules/#$C/md/#g" "$C/md/modules.dep" > "$C/k1a/modules.dep"; cp "$C/md"/*.ko "$C/k1a/"; : > "$C/k1a/modules.softdep"
{
    echo "export KM_SYS='$C/root/sys' KM_PROC='$C/root/proc' KM_STATE='$C/state' KM_SCEN='$C/scen' KM_SYMWAIT=2"
    echo "insmod() { '$W/bin/kmodel' \"\$@\"; }"
    echo "log() { :; }"
    echo "MD='$C/k1a'; LOADED=' '; ok=0; bad=0"
    sed -n '/^modfile() {/,/^}/p; /^softdeps() {/,/^}/p; /^load_mod() {/,/^}/p' "$K1A_INIT"
    echo 'for m in wifi_f.ko s_lib.ko fan_s.ko; do load_mod "$MD/$m"; done; echo K1A-DONE'
} > "$C/k1a.sh"
k1a_sha=$(sha256sum "$K1A_INIT" | cut -c1-64)
timeout 8 "$QEMU" "$W/bin/busybox" sh "$C/k1a.sh" > "$C/k1a.out" 2>&1; krc=$?
t "negative control: K1a's loader (init.sh $k1a_sha; no per-insmod deadline, waits for each insmod's return) stalls on the plain insmod blocked behind the hung probe and never reaches the S module" \
  "$(ok "$krc" = 124 -a "$(grep -c K1A-DONE "$C/k1a.out")" = 0 -a "$(grep -c '^fan_s ' "$C/state/calls")" = 0)" "rc=$krc calls=$(cut -d' ' -f1 "$C/state/calls" | tr '\n' ,)"
reap

# --- 3. a hung asynchronous probe INSIDE phase S, then another S module (kernel order: LIVE, then the wait) --
new s_hang_then_s
mod arb_s; mod fan_s; mod usb_e; mod f1
scen "arb_s probe=async pms=hang"
scen "fan_s probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
scen "usb_e probe=sync nodes=class/udc/a600000.dwc3/state=x"
list "S arb_s.ko bound:1" "S fan_s.ko hwmon:pwmfan" "E usb_e.ko udc:a600000.dwc3" "F f1.ko auto"
run FSML_DL_S=2 FSML_READY_S=1
t "S hang: every S module is attempted (no deadline skips an S module)" "$(ok "$(called arb_s && called fan_s && echo y)")"
t "S hang: each plain insmod is recorded LIVE insmod=blocked (init done, stuck in the global async wait), not as done" \
  "$(ok "$(has 'MODULE arb_s phase=S result=LIVE insmod=blocked' && has 'MODULE fan_s phase=S result=LIVE insmod=blocked' && echo y)")"
t "S hang: the hung device is PENDING insmod=blocked; the next S device, bound in its own init, is READY-BLOCKED with a FINDING" \
  "$(ok "$(has 'OUTCOME arb_s phase=S outcome=PENDING initstate=live ready=bound:1 insmod=blocked' && has 'OUTCOME fan_s phase=S outcome=READY-BLOCKED initstate=live ready=hwmon:pwmfan insmod=blocked' && has 'FINDING ready-blocked module=fan_s phase=S ready=hwmon:pwmfan covered=own-check' && echo y)")"
t "S hang: HANDOFF REFUSED (rc 1) naming the S module and the F skip" "$(ok "$RC" = 1 -a "$(grep -c 'HANDOFF verdict=REFUSED not_ready=S:arb_s:PENDING,.*F:all:SKIPPED-s-not-ready f_skipped=s-not-ready' "$C/log")" = 1)" "rc=$RC $(grep HANDOFF "$C/log")"
t "S hang: phase F skipped (s-not-ready); E still attempted" "$(ok "$(has 'MODULE_SKIPPED f1 reason=s-not-ready' && called usb_e && ! called f1 && echo y)")"
t "S hang: the library's own blocked insmod children are not killed" "$(ok "$(alive arb_s && alive fan_s && echo y)")"
t "S hang: bounded (< 12 s)" "$(ok "$SECS" -lt 12000)" "ms=$SECS"
reap

# --- 3c. the S ceiling: reaching it is an S-readiness failure; nothing after it is loaded -----------------
new s_ceiling
mod h1_s; mod h2_s; mod h3_s; mod e1; mod f1
scen "h1_s init=hang"; scen "h2_s init=hang"; scen "h3_s init=hang"
list "S h1_s.ko live" "S h2_s.ko live" "S h3_s.ko live" "e e1.ko auto" "F f1.ko auto"
run FSML_DL_S=10 FSML_S_MAX=2
t "S ceiling: the in-flight S module TIMED-OUT at the ceiling (not cancelled), the rest NOT-ATTEMPTED, never loaded" \
  "$(ok "$(has 'MODULE_TIMEOUT h1_s phase=S waited_ms=2[0-9][0-9]0 initstate=coming child=[0-9]* cancel=none' && has 'MODULE_NOT_ATTEMPTED h2_s reason=s-ceiling' && has 'OUTCOME h3_s phase=S outcome=NOT-ATTEMPTED' && ! called h2_s && ! called h3_s && echo y)")" "$(grep -E 'h1_s|h2_s' "$C/log" | head -3)"
t "S ceiling: recorded as an S-readiness failure; E and F not loaded; HANDOFF REFUSED (rc 1) naming the ceiling" \
  "$(ok "$RC" = 1 -a "$(grep -c 'S_CEILING reached s_max_s=2: S-readiness failure' "$C/log")" = 1 -a "$(grep -c 'MODULE_SKIPPED e1 reason=s-ceiling' "$C/log")" = 1 -a "$(grep -c 'MODULE_SKIPPED f1 reason=s-ceiling' "$C/log")" = 1 -a "$(grep -c 'HANDOFF verdict=REFUSED .*S:ceiling:REACHED' "$C/log")" = 1 -a "$(ncalls)" = 1)" "rc=$RC"
t "S ceiling: bounded by the ceiling (< 6 s), the blocked child still running" "$(ok "$SECS" -lt 6000 -a "$(alive h1_s && echo 0 || echo 1)" = 0)" "ms=$SECS"
reap

# --- 3d. READY-BLOCKED: accepted when its own readiness check covers it, refused when it does not ----------
new ready_blocked_ok
mod s1; mod drm_e; mod usb_e; mod f1
scen "drm_e probe=async pms=hang"; scen "usb_e probe=sync nodes=class/udc/a600000.dwc3/state=x"
list "S s1.ko live" "e drm_e.ko auto" "E usb_e.ko udc:a600000.dwc3" "F f1.ko auto"
run
t "READY-BLOCKED covered: required E device ready while its insmod is blocked -> READY-BLOCKED, FINDING covered=own-check, HANDOFF OK listing it" \
  "$(ok "$RC" = 0 -a "$(grep -c 'OUTCOME usb_e phase=E outcome=READY-BLOCKED' "$C/log")" = 1 -a "$(grep -c 'FINDING ready-blocked module=usb_e phase=E ready=udc:a600000.dwc3 covered=own-check' "$C/log")" = 1 -a "$(grep -c 'HANDOFF verdict=OK ready_blocked=usb_e' "$C/log")" = 1)" "rc=$RC $(grep HANDOFF "$C/log")"
reap
new ready_blocked_uncovered
mod s1; mod drm_e; mod usb_e; mod f1
scen "drm_e probe=async pms=hang"
list "S s1.ko live" "e drm_e.ko auto" "E usb_e.ko auto" "F f1.ko auto"
run
t "READY-BLOCKED uncovered: an 'auto' check with no driver does not cover the function -> FINDING covered=no, HANDOFF REFUSED" \
  "$(ok "$RC" = 1 -a "$(grep -c 'FINDING ready-blocked module=usb_e phase=E ready=auto covered=no' "$C/log")" = 1 -a "$(grep -c 'not_ready=E:usb_e:READY-BLOCKED-uncovered' "$C/log")" = 1)" "rc=$RC $(grep HANDOFF "$C/log")"
reap

# --- 3e. H1-F6: the explicit ADSP start, a bounded wait for running; absence = S-readiness failure ---------
rpcase() {  # rpcase NAME RESPONSE(running|offline|none)
    new "$1"; mod adsp_s; mod f1
    scen "adsp_s probe=sync nodes=class/remoteproc/remoteproc0/name=adsp-x;class/remoteproc/remoteproc0/state=offline"
    list "S adsp_s.ko rproc:adsp-x" "F f1.ko auto"
    if [ "$2" != none ]; then
        ( sf=$C/root/sys/class/remoteproc/remoteproc0/state
          for _ in $(seq 1 400); do
              if [ -f "$sf" ] && grep -qx start "$sf"; then sleep 0.3; echo "$2" > "$sf"; break; fi
              sleep 0.05
          done ) &
        echo $! >> "$C/state/pids"
    fi
}
rpcase rproc_ok running; run FSML_RPROC_START=adsp-x FSML_RPROC_WAIT=3
t "ADSP start: written, reaches running inside its bounded wait, S ready, HANDOFF OK" \
  "$(ok "$RC" = 0 -a "$(grep -c 'RPROC_START adsp-x state=offline firmware_class.path=unset action=write-start' "$C/log")" = 1 -a "$(grep -c 'RPROC_START adsp-x result=running' "$C/log")" = 1 -a "$(grep -c 'OUTCOME f1 phase=F outcome=READY' "$C/log")" = 1)" "rc=$RC $(grep -E 'RPROC|HANDOFF' "$C/log")"
reap
rpcase rproc_fail offline; run FSML_RPROC_START=adsp-x FSML_RPROC_WAIT=2
t "ADSP start: no running within the wait -> S-readiness failure, F skipped, HANDOFF REFUSED naming the remoteproc" \
  "$(ok "$RC" = 1 -a "$(grep -c 'RPROC_START adsp-x result=FAILED state=offline' "$C/log")" = 1 -a "$(grep -c 'MODULE_SKIPPED f1 reason=s-not-ready' "$C/log")" = 1 -a "$(grep -c 'not_ready=.*S:rproc-adsp-x:offline' "$C/log")" = 1)" "rc=$RC $(grep -E 'RPROC|HANDOFF' "$C/log")"
reap
new rproc_absent; mod s1; list "S s1.ko live"; run FSML_RPROC_START=adsp-x FSML_RPROC_WAIT=1
t "ADSP start: remoteproc not registered -> FAILED not-registered, HANDOFF REFUSED" \
  "$(ok "$RC" = 1 -a "$(grep -c 'RPROC_START adsp-x result=FAILED reason=not-registered' "$C/log")" = 1)" "rc=$RC"

# --- 3b. an S init that never returns (uninterruptible-init model), then another S module ----------------
new s_init_hang
mod stuck_s; mod fan_s; mod f1
scen "stuck_s init=hang"; scen "fan_s probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
list "S stuck_s.ko live" "S fan_s.ko hwmon:pwmfan" "F f1.ko auto"
run FSML_DL_S=1 FSML_READY_S=1
t "S init hang: MODULE_TIMEOUT initstate=coming cancel=none; the next S module is still loaded and READY" \
  "$(ok "$(has 'MODULE_TIMEOUT stuck_s phase=S waited_ms=[0-9]* initstate=coming child=[0-9]* cancel=none' && has 'OUTCOME fan_s phase=S outcome=READY' && echo y)")"
t "S init hang: TIMED-OUT, HANDOFF REFUSED (rc 1), the child still running (not killed)" \
  "$(ok "$RC" = 1 -a "$(grep -c 'OUTCOME stuck_s phase=S outcome=TIMED-OUT initstate=coming ready=live insmod=blocked' "$C/log")" = 1 -a "$(alive stuck_s && echo 0 || echo 1)" = 0)" "rc=$RC"
reap

# --- 4. a missing S module -----------------------------------------------------------------------------
new missing_s
mod s_lib; mod fan_s s_lib; mod tsens_s; mod f1
rm "$C/md/tsens_s.ko"
scen "fan_s probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
list "S s_lib.ko live" "S tsens_s.ko bound:2" "S fan_s.ko hwmon:pwmfan" "F f1.ko auto"
run FSML_READY_S=6
t "missing S: recorded FAILED file-missing" "$(ok "$(has 'MODULE tsens_s phase=S result=FAILED reason=file-missing' && has 'OUTCOME tsens_s phase=S outcome=FAILED' && echo y)")"
t "missing S: the other S modules are still loaded and READY" "$(ok "$(has 'OUTCOME fan_s phase=S outcome=READY' && has 'OUTCOME s_lib phase=S outcome=READY' && echo y)")"
t "missing S: HANDOFF REFUSED (rc 1); F skipped and named in the refusal" "$(ok "$RC" = 1 -a "$(grep -c 'not_ready=S:tsens_s:FAILED,F:all:SKIPPED-s-not-ready f_skipped=s-not-ready' "$C/log")" = 1 -a "$(grep -c 'MODULE_SKIPPED f1 reason=s-not-ready' "$C/log")" = 1)" "rc=$RC"
t "missing S: the 6 s S readiness window is not waited (an S module is already dead)" "$(ok "$(within "$(span S)" 4 && echo y)")" "span=$(span S)"
reap

# --- 5. H-2: firmware settings written and read back before any module; refusal on a mismatch ----------
new fw_ok
mod s_lib; mod f1; list "S s_lib.ko live" "F f1.ko auto"
run
t "fw: settings applied and read back before the first insmod (the first call saw 0,1,1)" \
  "$(ok "$(has 'FWCFG ok force_sysfs_fallback=0 ignore_sysfs_fallback=1 timeout=1' && head -1 "$C/state/calls" | grep -q 'fw=0,1,1' && [ "$(grep -n FWCFG "$C/log" | cut -d: -f1)" -lt "$(grep -n 'MODULE s_lib' "$C/log" | cut -d: -f1)" ] && echo y)")"
fwcase() {  # fwcase NAME how
    new "$1"; mod s_lib; list "S s_lib.ko live"
    case $2 in
    ro-force)   chmod 444 "$C/root/proc/sys/kernel/firmware_config/force_sysfs_fallback" ;;
    no-ignore)  rm "$C/root/proc/sys/kernel/firmware_config/ignore_sysfs_fallback" ;;
    no-timeout) rm "$C/root/sys/class/firmware/timeout" ;;
    ro-timeout) chmod 444 "$C/root/sys/class/firmware/timeout" ;;
    esac
    run
    t "fw readback failure ($2): REFUSED before any module (rc 2, no insmod, no /sys/module)" \
      "$(ok "$RC" = 2 -a "$(ncalls)" = 0 -a ! -e "$C/root/sys/module" -a "$(grep -c 'FWCFG REFUSED' "$C/log")" = 1 -a "$(grep -c 'HANDOFF verdict=REFUSED reason=firmware-config' "$C/log")" = 1)" "rc=$RC calls=$(ncalls) $(grep FWCFG "$C/log")"
}
if [ "$(id -u)" != 0 ]; then fwcase fw_ro_force ro-force; fwcase fw_ro_timeout ro-timeout; else echo "NOTE: running as root: the read-only cases are skipped"; fi
fwcase fw_no_ignore no-ignore
fwcase fw_no_timeout no-timeout

# --- 6. budget exhaustion in phase F never touches S ---------------------------------------------------
new f_budget
mod s_lib; mod fan_s s_lib; for i in 1 2 3 4 5 6 7 8; do mod "f$i"; scen "f$i init=900"; done
scen "fan_s probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
list "S s_lib.ko live" "S fan_s.ko hwmon:pwmfan" "F f1.ko auto" "F f2.ko auto" "F f3.ko auto" "F f4.ko auto" "F f5.ko auto" "F f6.ko auto" "F f7.ko auto" "F f8.ko auto"
run FSML_BUDGET_F=3
sk=$(grep -c 'MODULE_SKIPPED f[0-9] reason=budget-f' "$C/log")
t "F budget: the rest of F is SKIPPED (budget-f), at least one F module loaded" "$(ok "$sk" -ge 4 -a "$(grep -c 'MODULE f[0-9] phase=F result=LOADED' "$C/log")" -ge 1)" "skipped=$sk"
t "F budget: S untouched (both READY) and HANDOFF OK (rc 0)" "$(ok "$RC" = 0 -a "$(grep -c 'OUTCOME .* phase=S outcome=READY' "$C/log")" = 2)" "rc=$RC"
t "F budget: phase F ended within its budget (+ one poll and record overhead, 0.5 s)" "$(ok "$(within "$(span F)" 3.5 && echo y)")" "span=$(span F)"
reap

# --- 7. total budget: E and F stop at it; S is exempt ---------------------------------------------------
new total_budget
mod slow_s; mod e1; mod f1
scen "slow_s init=1500"
list "S slow_s.ko live" "e e1.ko auto" "F f1.ko auto"
run FSML_BUDGET_TOTAL=1
t "total budget: S loaded in full past the total; E and F SKIPPED (budget-total); HANDOFF OK" \
  "$(ok "$RC" = 0 -a "$(grep -c 'OUTCOME slow_s phase=S outcome=READY' "$C/log")" = 1 -a "$(grep -c 'MODULE_SKIPPED e1 reason=budget-total' "$C/log")" = 1 -a "$(grep -c 'MODULE_SKIPPED f1 reason=budget-total' "$C/log")" = 1)" "rc=$RC"
reap

# --- 8. a deadline is not a cancel: an S init that outlives its deadline and finishes later ------------
new s_late
mod slow_s; scen "slow_s init=1800 probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
list "S slow_s.ko hwmon:pwmfan"
run FSML_DL_S=1 FSML_READY_S=3
t "late S: MODULE_TIMEOUT initstate=coming at the deadline, then READY late=1 late_rc=0; HANDOFF OK" \
  "$(ok "$RC" = 0 -a "$(grep -c 'MODULE_TIMEOUT slow_s phase=S .*initstate=coming' "$C/log")" = 1 -a "$(grep -c 'OUTCOME slow_s phase=S outcome=READY .*late=1 late_rc=0' "$C/log")" = 1)" "rc=$RC"
reap

# --- 9. insmod returning 0 is not readiness -------------------------------------------------------------
new rc0_not_ready
mod fan_s; scen "fan_s probe=async pms=100 result=defer"
list "S fan_s.ko hwmon:pwmfan"
run FSML_READY_S=1
t "rc 0 is not ready: S insmod rc=0, initstate live, no hwmon -> PENDING; HANDOFF REFUSED" \
  "$(ok "$RC" = 1 -a "$(grep -c 'MODULE fan_s phase=S result=LOADED rc=0' "$C/log")" = 1 -a "$(grep -c 'OUTCOME fan_s phase=S outcome=PENDING initstate=live' "$C/log")" = 1)" "rc=$RC"
reap

# --- 10. a required E module failing refuses the handoff; best-effort e does not ------------------------
new e_required
mod s1; mod usb_e; mod led_e; mod f1
scen "usb_e rc=1"; scen "led_e rc=1"
list "S s1.ko live" "E usb_e.ko udc:a600000.dwc3" "e led_e.ko led:red" "F f1.ko auto"
run
t "E required: FAILED -> HANDOFF REFUSED naming only the required one; F still loaded" \
  "$(ok "$RC" = 1 -a "$(grep -c 'not_ready=E:usb_e:FAILED$' "$C/log")" = 1 -a "$(grep -c 'OUTCOME f1 phase=F outcome=READY' "$C/log")" = 1)" "rc=$RC $(grep HANDOFF "$C/log")"
reap

# --- 11. a hung async probe and hung inits in phase E: the E budget ends E, F (async_probe) still loads ----
new e_hang
mod s1; mod drm_e; mod e2; mod e3; mod e4; mod f1; mod f2
scen "drm_e probe=async pms=hang"; scen "e2 init=hang"; scen "e3 init=hang"
scen "f1 probe=sync nodes=class/leds/red/brightness=0"
list "S s1.ko live" "e drm_e.ko auto" "e e2.ko auto" "e e3.ko auto" "e e4.ko auto" "F f1.ko led:red" "F f2.ko auto"
run FSML_BUDGET_E=2 FSML_DL_E=1
t "E hang: drm_e LIVE insmod=blocked and PENDING; e2 MODULE_TIMEOUT coming; the rest of E SKIPPED (budget-e) inside the budget" \
  "$(ok "$(has 'MODULE drm_e phase=E result=LIVE insmod=blocked' && has 'OUTCOME drm_e phase=e outcome=PENDING' && has 'MODULE_TIMEOUT e2 phase=E .*initstate=coming' && has 'MODULE_SKIPPED e4 reason=budget-e' && within "$(span E)" 2.5 && echo y)")" "span=$(span E)"
t "E hang: phase F (async_probe=1) is not blocked: F modules READY; HANDOFF OK (no required E)" \
  "$(ok "$RC" = 0 -a "$(grep -c 'OUTCOME f1 phase=F outcome=READY' "$C/log")" = 1 -a "$(grep -c 'OUTCOME f2 phase=F outcome=READY' "$C/log")" = 1)" "rc=$RC"
reap

# --- 12. list and index validation: refused before any module -------------------------------------------
lcase() {  # lcase NAME EXPECT_REASON LIST_LINES...
    local nm=$1 why=$2; shift 2
    new "$nm"; mod a; mod b a; mod c
    list "$@"; run
    t "list refused ($nm): rc 2, no insmod, reason $why" "$(ok "$RC" = 2 -a "$(ncalls)" = 0 -a "$(grep -c "LIST REFUSED.*$why" "$C/log")" = 1)" "rc=$RC $(grep 'LIST' "$C/log")"
}
lcase dep_later 'dep-later:b.ko->a.ko' "S b.ko live" "S a.ko live"
lcase dep_missing 'dep-not-listed:b.ko->a.ko' "S b.ko live"
lcase bad_pred 'reason=predicate' "S a.ko live" "F c.ko rm:-rf"
lcase bad_name 'reason=name' "S a.ko live" 'F $(reboot).ko auto'
lcase dot_name 'reason=name' "S a.ko live" 'F c.x.ko auto'
lcase phase_order 'reason=phase-order' "S a.ko live" "F c.ko auto" "S b.ko live"
lcase s_auto 'reason=s-needs-explicit-predicate' "S a.ko auto"
lcase dup 'reason=duplicate' "S a.ko live" "F a.ko auto"
lcase no_s 'reason=no-S-module' "F a.ko auto"
lcase not_indexed 'not-indexed:c2.ko' "S a.ko live" "F c2.ko auto"
lcase extra_field 'reason=fields' "S a.ko live x"
lcase s_auto_atom 'reason=s-needs-explicit-predicate' "S a.ko live,auto"
lcase empty_atom 'reason=predicate' "S a.ko live,"
new list_pin; mod a; list "S a.ko live"; LSHA_OVERRIDE=1111111111111111111111111111111111111111111111111111111111111111 run
t "list pin mismatch: rc 2, no insmod" "$(ok "$RC" = 2 -a "$(ncalls)" = 0 -a "$(grep -c 'LIST REFUSED .*reason=pin' "$C/log")" = 1)" "rc=$RC"
new no_newline; mod a; mod b; scen "b probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
printf 'S a.ko live\nS b.ko hwmon:pwmfan' > "$C/list"; run
t "a last list line without a newline is still loaded (S=2, b READY)" "$(ok "$RC" = 0 -a "$(grep -c 'LIST ok .* S=2 ' "$C/log")" = 1 -a "$(grep -c 'OUTCOME b phase=S outcome=READY' "$C/log")" = 1)" "rc=$RC $(grep LIST "$C/log")"
new soft_later; mod a; mod d; echo "softdep d pre: a" > "$C/md/modules.softdep"; list "S d.ko live" "F a.ko auto"; run
t "list refused (softdep pre: later): rc 2" "$(ok "$RC" = 2 -a "$(grep -c 'softdep-later:d.ko->a' "$C/log")" = 1)" "rc=$RC $(grep LIST "$C/log")"
new idx_bad; mod a; list "S a.ko live"; IDX_OVERRIDE="$C/md/modules.dep=0000000000000000000000000000000000000000000000000000000000000000" run
t "index pin mismatch: rc 2, no insmod" "$(ok "$RC" = 2 -a "$(ncalls)" = 0 -a "$(grep -c 'INDEX REFUSED' "$C/log")" = 1)" "rc=$RC"
new idx_none; mod a; list "S a.ko live"; IDX_OVERRIDE=" " run
t "no index pins: rc 2, no insmod" "$(ok "$RC" = 2 -a "$(ncalls)" = 0 -a "$(grep -c 'INDEX REFUSED reason=no-pins' "$C/log")" = 1)" "rc=$RC"
new bad_budget; mod a; list "S a.ko live"; run FSML_BUDGET_F=abc
t "a malformed budget is refused (rc 2, no insmod)" "$(ok "$RC" = 2 -a "$(ncalls)" = 0)" "rc=$RC"
new octal_budget; mod a; list "S a.ko live"; run FSML_BUDGET_E=08
t "a budget with a leading zero (octal in ash) is refused (rc 2, no insmod)" "$(ok "$RC" = 2 -a "$(ncalls)" = 0 -a "$(grep -c 'reason=bad-budget value=08' "$C/log")" = 1)" "rc=$RC"
new bad_poll; mod a; list "S a.ko live"; run FSML_POLL=0
t "a zero poll interval is refused (rc 2, no insmod)" "$(ok "$RC" = 2 -a "$(ncalls)" = 0 -a "$(grep -c 'reason=bad-poll' "$C/log")" = 1)" "rc=$RC"
new run_ro; mod a; list "S a.ko live"; mkdir -p "$C/ro"; chmod 555 "$C/ro"
if [ "$(id -u)" != 0 ]; then
    run "FSML_RUN='$C/ro/run'"
    t "an unwritable run directory is refused before any module (rc 2)" "$(ok "$RC" = 2 -a "$(ncalls)" = 0 -a "$(grep -c 'reason=run-dir-unwritable' "$C/log")" = 1)" "rc=$RC"
fi
chmod 755 "$C/ro"

# --- 13. the module latch (optional, after F) -----------------------------------------------------------
new latch; mod a; list "S a.ko live"; run FSML_LATCH=1
t "latch: modules_disabled=1 written after F and read back" "$(ok "$RC" = 0 -a "$(cat "$C/root/proc/sys/kernel/modules_disabled")" = 1 -a "$(grep -c '^FSML1 .* LATCH modules_disabled=1' "$C/log")" = 1)" "rc=$RC"

# --- 14. a dependency still "coming" when the next module loads (resolve_symbol_wait) -------------------
new dep_coming
mod base_s; mod user_s base_s
scen "base_s init=hang"; scen "user_s needs=base_s probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
list "S base_s.ko live" "S user_s.ko hwmon:pwmfan"
run FSML_DL_S=1 FSML_READY_S=4
t "dep coming: the dependent S module is still attempted; its late failure is FAILED late=1 late_rc=1; REFUSED" \
  "$(ok "$RC" = 1 -a "$(grep -c '^user_s ' "$C/state/calls")" = 1 -a "$(grep -c 'OUTCOME user_s phase=S outcome=FAILED initstate=absent ready=hwmon:pwmfan late=1 late_rc=1' "$C/log")" = 1)" "rc=$RC $(grep 'OUTCOME user_s' "$C/log")"
reap

# --- 14b. S late after its window but ready before F: re-checked, F loaded, OK ---------------------------
new s_recheck
mod slow_s; mod e1; mod f1
scen "slow_s init=2600 probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"; scen "e1 init=1800"
list "S slow_s.ko hwmon:pwmfan" "e e1.ko auto" "F f1.ko auto"
run FSML_DL_S=1 FSML_READY_S=1
t "S re-checked before F: window missed, ready by F -> F loaded, READY late=1, HANDOFF OK" \
  "$(ok "$RC" = 0 -a "$(grep -c 'S ready=yes (re-checked before F' "$C/log")" = 1 -a "$(grep -c 'OUTCOME f1 phase=F outcome=READY' "$C/log")" = 1 -a "$(grep -c 'OUTCOME slow_s phase=S outcome=READY .*late=1 late_rc=0' "$C/log")" = 1)" "rc=$RC $(grep -E 'HANDOFF|SKIPPED' "$C/log")"
reap

# --- 14c. a module already live (EEXIST) is judged by its readiness, not refused ---------------------------
new already_live
mod a; mod b; scen "b probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
mkdir -p "$C/root/sys/module/a"; echo live > "$C/root/sys/module/a/initstate"
list "S a.ko live" "S b.ko hwmon:pwmfan"; run
t "already live: rc=1 note=already-live, READY, HANDOFF OK" "$(ok "$RC" = 0 -a "$(grep -c 'MODULE a phase=S result=LOADED rc=1 note=already-live' "$C/log")" = 1 -a "$(grep -c 'OUTCOME a phase=S outcome=READY' "$C/log")" = 1)" "rc=$RC"

# --- 14d. the caller's set -e, set -u and IFS do not break the run and are restored ------------------------
new caller_opts
mod a; mod f1; scen "a probe=sync nodes=class/hwmon/hwmon0/name=pwmfan"
list "S a.ko hwmon:pwmfan" "F f1.ko auto"
PRE='set -eu; IFS=,' run
t "caller set -eu and IFS=, : HANDOFF OK, options and IFS restored afterwards" \
  "$(ok "$RC" = 0 -a "$(grep -c '^OPTS=.*e' "$C/rc")" = 1 -a "$(grep -c '^OPTS=.*u' "$C/rc")" = 1 -a "$(grep -c '^IFS=\[,\]' "$C/rc")" = 1)" "rc=$RC $(tr '\n' ' ' < "$C/rc")"

# --- 15. the real derived lists (local index only; the lists are committed, the index is not) ------------
if [ -n "${FS_H1_INDEX:-}" ]; then
    for prof in k1i ts-t1 ts-t2 ts-t3b; do
        new "real_$prof"
        L=$H1/lists/$prof.phases
        cp "$L" "$C/list"
        IDXS=""
        for d in $FS_H1_INDEX; do
            IDXS+="$d/modules.dep=$(sha256sum "$d/modules.dep" | cut -c1-64) $d/modules.softdep=$(sha256sum "$d/modules.softdep" | cut -c1-64) "
        done
        z=0
        awk '$1 !~ /^#/ && NF {print $2}' "$L" | while read -r m; do : > "$C/md/$m"; done
        awk '$1 !~ /^#/ && NF {print $2, $3}' "$L" | while read -r m p; do
            nm=${m%.ko}; nm=${nm//-/_}; nodes=""; devs=1; probe=none
            IFS=, read -ra atoms <<< "$p"
            for a in "${atoms[@]}"; do
                z=$((z + 1))
                case $a in
                hwmon:*) nodes+="class/hwmon/hwmon$z/name=${a#hwmon:};"; probe=sync ;;
                cpufreq:*) nodes+="devices/system/cpu/cpufreq/${a#cpufreq:}/scaling_max_freq=1;"; probe=sync ;;
                param:*) pp=${a#param:}; nodes+="module/${pp%%/*}/parameters/${pp#*/}=0;"; probe=sync ;;
                bound:*) devs=${a#bound:}; probe=sync ;;
                iiochan:*) nodes+="bus/iio/devices/iio:device$z/in_temp_${a#iiochan:}_input=30000;"; probe=sync ;;
                tz:*) nodes+="class/thermal/thermal_zone$z/type=${a#tz:};"; probe=sync ;;
                rproc:*) r=${a#rproc:}; nodes+="class/remoteproc/remoteproc$z/name=${r%%=*};class/remoteproc/remoteproc$z/state=${r#*=};"; probe=sync ;;
                psy:*) nodes+="class/power_supply/${a#psy:}/type=x;"; probe=sync ;;
                udc:*) nodes+="class/udc/${a#udc:}/state=x;"; probe=sync ;;
                led:*) nodes+="class/leds/${a#led:}/brightness=0;"; probe=sync ;;
                path:/sys/*) nodes+="${a#path:/sys/}=1;"; probe=sync ;;
                esac
            done
            echo "$nm probe=$probe devs=$devs nodes=$nodes" >> "$C/scen"
        done
        IDX_OVERRIDE="$IDXS" run FSML_DL_S=5 FSML_DL_E=5 FSML_DL_F=5 FSML_BUDGET_E=60 FSML_BUDGET_F=120 FSML_BUDGET_TOTAL=400
        want=$(awk '$1 !~ /^#/ && NF {m=$2; sub(/\.ko$/,"",m); gsub(/-/,"_",m); print m, ($1=="F" ? "[async_probe=1]" : "[]")}' "$L")
        got=$(sed 's/^\([^ ]*\) params=\(\[[^]]*\]\).*/\1 \2/' "$C/state/calls")
        nl=$(grep -c . <<< "$want")
        t "real list $prof ($nl modules, list $(sha256sum "$L" | cut -c1-12)): the runtime order/closure check passes against the pinned v2.7 index and HANDOFF OK" \
          "$(ok "$RC" = 0 -a "$(grep -c "OUTCOME .* outcome=READY" "$C/log")" = "$nl")" "rc=$RC $(grep -m3 'REFUSED\|outcome=[^R]' "$C/log")"
        t "real list $prof: insmod order = list order, async_probe=1 exactly on F" "$(ok "$want" = "$got")"
        reap
    done
else
    echo "NOTE: FS_H1_INDEX not set: the real-list cases (15) are not run"
fi

echo "fs-modload: $((n - bad))/$n pass"
if [ -n "$OUT" ]; then
    {
        echo "# FrameShift H-1 loader tests  $(date -u +%FT%TZ)"
        echo "# library $(sha256sum "$LIB" | cut -c1-64)  kmodel $(sha256sum "$HERE/kmodel-insmod.sh" | cut -c1-64)  harness $(sha256sum "$0" | cut -c1-64)"
        echo "# busybox $BB_SHA (reviewed stage-1, aarch64 under $(qemu-aarch64 --version | head -1))"
        echo "# k1a init.sh (negative control, read-only) $(sha256sum "$K1A_INIT" | cut -c1-64)"
        [ -n "${FS_H1_INDEX:-}" ] && for d in $FS_H1_INDEX; do echo "# index $(sha256sum "$d/modules.dep" | cut -c1-64) modules.dep, $(sha256sum "$d/modules.softdep" | cut -c1-64) modules.softdep"; done
        printf '%s' "$LOGT"
        echo "TOTAL: $n cases, $bad failed"
    } > "$OUT"
fi
[ "$bad" = 0 ]
