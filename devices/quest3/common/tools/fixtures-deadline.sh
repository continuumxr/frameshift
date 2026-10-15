#!/bin/bash
# FrameShift common — PID 1 deadline fixtures (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/common/tools/fixtures-deadline.sh
#   HOLD=<file> OUT=<dir>   run against another pid1-hold.sh (before/after table)
# Runs target/pid1-hold.sh with the REVIEWED stage-1 busybox (aarch64) under
# qemu-aarch64. Only the reboot SYSCALL is faked: FS_REBOOT_BIN and
# FS_REBOOT_FALLBACK are scripts that append "<uptime> <reason>" to a record
# file OUTSIDE the simulated /run and then return (as a failed syscall
# would), so everything the real path does before and after the syscall
# runs for real. For the revision-1 interface (reboot_bootloader +
# FS_BACKSTOP_CMD) the sim provides a stage-1-shaped reboot_bootloader that
# logs to /run/fs.log first, exactly like stage-1 init.sh.
# Scaled times: deadline 8 s, ack window 4 s.
# Touches no device. Writes fixtures/deadline/*.txt and RESULTS.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"
HERE=$ROOT/devices/quest3/common
HOLD=${HOLD:-$HERE/target/pid1-hold.sh}
BB_SRC=$ROOT/build/third_party/busybox/busybox
FX=${OUT:-$HERE/fixtures/deadline}
# refuse BEFORE touching any committed result file when a gitignored build input is missing
for _in in "$BB_SRC"; do
    [ -f "$_in" ] || { echo "REFUSED: build input missing: $_in (gitignored; see README \"What is not in git\"); nothing was written"; exit 1; }
done
W=$(mktemp -d /tmp/fsdl.XXXXXX)
trap 'pkill -9 -f "$W/" 2>/dev/null; rm -rf "$W"' EXIT
rm -rf "$FX"; mkdir -p "$FX"
SUM=$FX/RESULTS.txt; : > "$SUM"
DL=8; AW=4

[ "$(sha256sum "$BB_SRC" | cut -c1-64)" = c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02 ] \
    || { echo "REFUSED: busybox is not the reviewed binary"; exit 1; }
mkdir -p "$W/bin"
cp "$BB_SRC" "$W/bin/busybox"; chmod 0755 "$W/bin/busybox"
for a in sh cut cat echo sleep head rm mv printf mkfifo sync; do ln -s busybox "$W/bin/$a"; done
BB=$W/bin/busybox
# the fake reboot helper: records, then returns like a failed syscall
cat > "$W/bin/fake-reboot" <<EOF
#!$W/bin/sh
read -r u _ < /proc/uptime
echo "\${u%%.*} \${1:-none} pid=\$\$ via=fork" >> "\$FS_REC"
exit 1
EOF
# fake fs-reboot-final: PID 1 execs it; records, then never exits (like the real one)
cat > "$W/bin/fake-final" <<EOF
#!$W/bin/sh
read -r u _ < /proc/uptime
echo "\${u%%.*} \${1:-none} pid=\$\$ via=final" >> "\$FS_REC"
while :; do sleep 3600; done
EOF
chmod 0755 "$W/bin/fake-final"
chmod 0755 "$W/bin/fake-reboot"
echo "pid1-hold.sh sha256=$(sha256sum "$HOLD" | cut -c1-64)" | tee -a "$SUM"
echo "busybox      sha256=$(sha256sum "$BB" | cut -c1-64) (runs the logic, under qemu-aarch64)" | tee -a "$SUM"

res() {  # parallel scenarios write their own file (no interleaving); collected in order after wait
    local l; if [ "$2" = 0 ]; then l="$1 PASS $3"; else l="$1 FAIL $3"; fi
    if [ -n "${RESOUT:-}" ]; then echo "$l" > "$RESOUT"; else echo "$l" | tee -a "$SUM"; fi
}
up() { cut -d. -f1 /proc/uptime; }

# The simulated PID 1. Supports both interfaces of pid1-hold.sh.
cat > "$W/sim.sh" <<'EOF'
read -r _h _ < /proc/uptime; echo "${_h%%.*}" > "$FS_REC.start"      # harness-only, real clock
. "$HOLD"
log()   { echo "FS t=$(cut -d. -f1 /proc/uptime)s $*" >> "$FS_RUN/fs.log"; }   # pre-shell logger (stage-1 shape)
stage() { echo "$1" >> "$FS_RUN/fs.stages"; log "STAGE=$1 $2"; }
led()   { :; }
reboot_bootloader() {        # revision-1 interface, stage-1 shape: log first, then the helper
    echo "FS REBOOT_BOOTLOADER reason=$1" >> "$FS_RUN/fs.log"
    sync
    "$FS_REBOOT_BIN" "$1"
    $FS_REBOOT_FALLBACK
    while :; do sleep 3600; done
}
if [ "${SETE:-0}" = 1 ]; then set -eu; fi      # harness-only: a future init running with set -eu
fs_hold_init "$DL" "$AW"
echo "$T0" > "$FS_REC.t0"; echo "$$" > "$FS_REC.pid"
fs_start_backstop
if [ "${STALL:-0}" = 1 ]; then while :; do sleep 1; done; fi   # harness-only: PID 1 stuck before its loop
echo ready > "$FS_RUN/READY"
fs_hold_loop
EOF
# stage-1 logic (init.sh §1, §7 in substance): HOST_ACK kills the dead-man
cat > "$W/sim-stage1.sh" <<'EOF'
up() { cut -d. -f1 /proc/uptime; }
echo "$(up)" > "$FS_REC.start"; echo "$(up)" > "$FS_REC.t0"
( sleep "$DL"; "$FS_REBOOT_BIN" deadman ) &
DEADMAN_PID=$!
echo ready > "$FS_RUN/READY"
S0=$(up)
while :; do
    if [ -f "$FS_RUN/host_ack" ]; then
        a=$(cat "$FS_RUN/host_ack")
        case "$a" in
            ''|*[!0-9a-f]*) rm -f "$FS_RUN/host_ack" ;;
            *) echo "$a" > "$FS_RUN/fs.acked"; kill "$DEADMAN_PID" 2>/dev/null
               while :; do sleep 3600; done ;;
        esac
    fi
    [ $(( $(up) - S0 )) -ge "$AW" ] && { "$FS_REBOOT_BIN" no-host-ack; exit 0; }
    sleep 1
done
EOF

# scenario NAME SCRIPT ACTIONFN WANT LO HI [ENV=VAL...]
#   WANT: reason of the FIRST reboot record ("a|b" alternatives), or "none".
#   LO..HI: window for (record time - T0); T0 unreadable -> from sim start.
scenario() {
    local name=$1 script=$2 action=$3 want=$4 lo=$5 hi=$6; shift 6
    local R=$W/$name; mkdir -p "$R"
    local RESOUT=$W/$name.res
    local REC=$W/$name.rec
    ( cd /; exec setsid env -i PATH="$W/bin" HOLD="$HOLD" FS_RUN="$R" FS_REC="$REC" \
        FS_UPTIME="${FAKE_UPTIME:-/proc/uptime}" FS_REBOOT_BIN="$W/bin/fake-reboot" \
        FS_REBOOT_FINAL="$W/bin/fake-final" \
        FS_REBOOT_FALLBACK="$W/bin/fake-reboot fallback" \
        FS_BACKSTOP_CMD="$W/bin/fake-reboot backstop" DL=$DL AW=$AW "$@" \
        /usr/bin/qemu-aarch64 ${STRACE:+-strace} "$BB" sh "$W/$script" > "$R.stdout" 2>&1 ) &
    local sp=$!
    "$action" "$R" "$sp" &
    local ap=$!
    local stop=$(( $(up) + hi + 4 ))
    while [ ! -s "$REC" ] && [ "$(up)" -lt "$stop" ]; do sleep 0.2; done
    [ "$want" = none ] || sleep 0.5
    kill $ap 2>/dev/null
    local first t0 when why rel
    first=$(head -1 "$REC" 2>/dev/null)
    t0=$(cat "$REC.t0" 2>/dev/null || echo 0)
    when=$(echo "$first" | cut -d' ' -f1); why=$(echo "$first" | cut -d' ' -f2)
    local rpid via simpid; rpid=$(echo "$first" | sed -n 's/.* pid=\([0-9]*\).*/\1/p'); via=$(echo "$first" | sed -n 's/.* via=//p')
    simpid=$(cat "$REC.pid" 2>/dev/null)
    # PID 1's own reboots must be an exec of fs-reboot-final (same pid, no fork); the backstop forks
    local okvia=0
    case "$why" in
        deadline|deadline-ticks|collected|no-host-ack) { [ "$via" = final ] && [ -n "$simpid" ] && [ "$rpid" = "$simpid" ]; } || okvia=1 ;;
        backstop) { [ "$via" = fork ] && [ "$rpid" != "$simpid" ]; } || okvia=1 ;;
    esac
    {
        echo "# scenario $name ($script, action $action), deadline=$DL ack_window=$AW $*"
        echo "# T0=$t0 reboot records (fake syscall; first one counts):"; sed 's/^/#   /' "$REC" 2>/dev/null
        if [ -p "$R/fs.log" ]; then echo "# fs.log is a FIFO (attack in place)"; else echo "# PID 1 log:"; sed 's/^/#   /' "$R/fs.log" 2>/dev/null; fi
        [ -f "$R.note" ] && echo "# harness: $(tr '\n' ' ' < "$R.note")"
        echo "# sim stdout/stderr:"; sed 's/^/#   /' "$R.stdout"
    } > "$FX/$name.txt"
    kill -9 -- -$sp 2>/dev/null
    if [ "$want" = none ]; then
        [ -z "$first" ] && res "$name" 0 "no reboot within ${hi}s (as required for this control)" \
                        || res "$name" 1 "unexpected reboot: $first (T0=$t0)"
        return
    fi
    rel=$(( ${when:-0} - t0 ))
    # T0 unreadable or from a fake clock file: measure from the (real-clock) sim start
    if [ "$t0" = 0 ] || [ -n "${FAKE_UPTIME:-}" ]; then rel=$(( ${when:-0} - $(cat "$REC.start" 2>/dev/null || echo 0) )); fi
    local okwhy=1 alt x
    IFS='|' read -ra alt <<< "$want"; for x in "${alt[@]}"; do [ "$why" = "$x" ] && okwhy=0; done
    if [ -n "$first" ] && [ $okwhy = 0 ] && [ $okvia = 0 ] && [ "$rel" -ge "$lo" ] && [ "$rel" -le "$hi" ]; then
        res "$name" 0 "first reboot: '$why' via=$via at T0+${rel}s (window ${lo}..${hi})"
    else
        res "$name" 1 "first reboot: '${first:-none}' rel=${rel} want '$want' in ${lo}..${hi} (sim pid ${simpid:-?})"
    fi
}

waitready() { local n=0; while [ ! -f "$1/READY" ] && [ $n -lt 200 ]; do sleep 0.1; n=$((n + 1)); done; }
put() { printf '%s\n' "$2" > "$1/$3.tmp" && mv "$1/$3.tmp" "$1/$3"; }   # like fs-ack / fs-done
fifo() { rm -f "$1/$2"; mkfifo "$1/$2"; echo "fifo $2" >> "$1.note"; }
a_none()     { :; }
a_ack()      { waitready "$1"; sleep 1; put "$1" 0123abcd host_ack; }
a_ack_done() { a_ack "$1"; sleep 2; put "$1" done fs.collected; }
a_ack_late() { waitready "$1"; sleep 3.5; put "$1" 0123abcd host_ack; }
a_kill_backstop() { local bp; bp=$(sed -n 's/.*BACKSTOP.*pid=\([0-9]*\).*/\1/p' "$1/fs.log"); kill "$bp" 2>/dev/null && echo "killed backstop subshell $bp" >> "$1.note"; }
a_frozen()   { waitready "$1"; sleep 1; put "$1" 0123abcd host_ack; sleep 0.5; a_kill_backstop "$1"; }   # clock file frozen from the start
a_octal()    { waitready "$1"; sleep 1.5; printf '09.00 1\n' > "$W/octal.clock"; echo "clock -> 09.00" >> "$1.note"; }
a_huge()     { waitready "$1"; sleep 1.5; printf '99999999999999999999.0 1\n' > "$W/huge.clock"; echo "clock -> 20 digits" >> "$1.note"; }
a_cancel()   { # every "cancel" a confused host could try after acking (stage-1 style included)
    a_ack "$1"; sleep 1
    put "$1" 99999999 host_ack; rm -f "$1/fs.acked" "$1/fs.stages"
    for f in fs.deadline deadline DEADLINE fs.cancel cancel T0; do put "$1" 0 $f; done
    bp=$(sed -n 's/.*BACKSTOP.*pid=\([0-9]*\).*/\1/p' "$1/fs.log")
    kill "$bp" 2>/dev/null && echo "killed backstop subshell $bp" >> "$1.note"
}
a_malformed() { waitready "$1"; sleep 1; put "$1" 'XYZ!' host_ack; }
a_fifo_ack() { waitready "$1"; sleep 1; fifo "$1" host_ack; }
a_done_noack() { waitready "$1"; sleep 2; put "$1" done fs.collected; }
a_fifo_done() { waitready "$1"; sleep 2; fifo "$1" fs.collected; }
# B1: FIFOs on every file PID 1 writes, then the ack that makes it write
a_fifo_logs() { waitready "$1"; sleep 1; fifo "$1" fs.log; fifo "$1" fs.stages; fifo "$1" fs.acked; sleep 0.5; put "$1" 0123abcd host_ack; }
# B1, worst case: PID 1 stuck before its loop AND fs.log a FIFO: only the backstop is left
a_fifo_stalled() { sleep 2; fifo "$1" fs.log; }
# S5: count the distinct child processes of the simulated PID 1 while it is in its loop
a_forks() {
    waitready "$1"; put "$1" 0123abcd host_ack; sleep 0.5
    local seen=" " end=$(( $(date +%s%N) / 1000000 + 3000 )) c
    while [ $(( $(date +%s%N) / 1000000 )) -lt $end ]; do
        for c in $(cat /proc/[0-9]*/stat 2>/dev/null | awk -v pp="$2" '$4 == pp { print $1 }'); do
            case "$seen" in *" $c "*) ;; *) seen="$seen$c " ;; esac
        done
        sleep 0.05
    done
    echo "children seen in 3 s: $(echo $seen | wc -w) ($seen)" >> "$1.note"
}
a_kill_sleep() { # kill only the backstop's sleep: the backstop must then fire EARLY (fail-safe)
    waitready "$1"; put "$1" 0123abcd host_ack; sleep 2
    for p in $(ls -d /proc/[0-9]* 2>/dev/null); do
        { tr '\000' '\n' < "$p/environ"; } 2>/dev/null | grep -qx "FS_RUN=$1" || continue
        { tr '\000' ' ' < "$p/cmdline"; } 2>/dev/null | grep -Eq ' sleep [0-9]+ $' || continue
        { tr '\000' ' ' < "$p/cmdline"; } 2>/dev/null | grep -q ' sleep 1 $' && continue
        kill "${p#/proc/}" 2>/dev/null && echo "killed backstop sleep ${p#/proc/}" >> "$1.note"
    done
}

# ---- static properties of pid1-hold.sh --------------------------------------
code=$(sed 's/#.*//' "$HOLD")
echo "$code" | grep -Eqw 'kill|pkill|killall' && res static-no-kill 1 "pid1-hold.sh contains a kill" \
    || res static-no-kill 0 "no kill/pkill/killall in pid1-hold.sh (outside comments)"
n=$(echo "$code" | grep -Ec '(^|[^_A-Za-z])(FS_DEADLINE|T0)=')
inside=$(echo "$code" | sed -n '/^fs_hold_init()/,/^}/p' | grep -Ec '(^|[^_A-Za-z])(FS_DEADLINE|T0)=')
[ "$n" = "$inside" ] && [ "$n" -ge 2 ] && res static-assign-once 0 "FS_DEADLINE/T0 assigned only in fs_hold_init ($n assignments)" \
    || res static-assign-once 1 "assignments outside fs_hold_init: total $n inside $inside"
first=$(echo "$code" | sed -n '/^fs_reboot()/,/^}/p' | sed -n '2p' | tr -s ' ')
bs=$(echo "$code" | grep -c '( sleep "$_left"; fs_reboot backstop ) &')
[ "$first" = ' "$FS_REBOOT_BIN" "$1"' ] && [ "$bs" = 1 ] \
    && res static-reboot-first 0 "fs_reboot's first command is the reboot helper; the backstop is exactly 'sleep; fs_reboot' (no write before the syscall)" \
    || res static-reboot-first 1 "first='$first' backstop-lines=$bs"
ex=$(echo "$code" | sed -n '/^fs_reboot_pid1()/,/^}/p')
lp=$(echo "$code" | sed -n '/^fs_hold_loop()/,/^}/p')
{ echo "$ex" | grep -q 'exec "$FS_REBOOT_FINAL" "$1"' && echo "$ex" | grep -q '\[ -x "$FS_REBOOT_FINAL" \]' \
  && [ "$(echo "$lp" | grep -c 'fs_reboot_pid1 ')" = 4 ] && ! echo "$lp" | grep -Eq 'fs_reboot (deadline|collected|no-host-ack)'; } \
    && res static-pid1-exec 0 "all 4 PID 1 reboot sites (deadline, deadline-ticks, collected, no-host-ack) use fs_reboot_pid1, which execs fs-reboot-final only after an -f/-x check (a failed exec would end PID 1)" \
    || res static-pid1-exec 1 "fs_reboot_pid1/loop check failed"
clamp=$(env -i PATH="$W/bin" HOLD="$HOLD" FS_UPTIME=/proc/uptime FS_RUN="$W" /usr/bin/qemu-aarch64 "$BB" sh -c \
    '. "$HOLD"; log() { :; }; for a in "999 999" "abc 5" "60 999" "300 10" "299 150" "08 04" "1234567890 5" "010 009"; do fs_hold_init $a; printf "%s->%s/%s " "$a" "$FS_DEADLINE" "$FS_ACK_WINDOW"; done')
echo "# clamp: $clamp" > "$FX/static-clamp.txt"
[ "$clamp" = "999 999->299/299 abc 5->299/5 60 999->60/60 300 10->299/10 299 150->299/150 08 04->299/150 1234567890 5->299/5 010 009->299/150 " ] \
    && res static-clamp 0 "deadline clamped to <= 299 s, ack window <= deadline; garbage, leading zeros and > 9 digits -> fallback (no arithmetic error)" \
    || res static-clamp 1 "$clamp"

# ---- fs-done reports honestly -----------------------------------------------
DONE=$HERE/target/fs-done
mkdir -p "$W/donedir"
o1=$(env -i PATH="$W/bin" FS_RUN="$W/donedir" /usr/bin/qemu-aarch64 "$BB" sh "$DONE" abc); r1=$?
o2=$(env -i PATH="$W/bin" FS_RUN="$W/no-such-dir" /usr/bin/qemu-aarch64 "$BB" sh "$DONE" abc); r2=$?
echo "# fs-done into a writable dir: '$o1' rc=$r1 file=$(cat "$W/donedir/fs.collected" 2>/dev/null)"$'\n'"# fs-done into a missing dir: '$o2' rc=$r2" > "$FX/fs-done.txt"
[ "$o1" = "FSD1 queued END" ] && [ $r1 = 0 ] && [ -f "$W/donedir/fs.collected" ] && [ "$o2" = "FSD1 error=write END" ] && [ $r2 = 1 ] \
    && res fs-done-honest 0 "queued only when written (rc 0); a failed write says error=write (rc 1)" \
    || res fs-done-honest 1 "'$o1' rc=$r1 / '$o2' rc=$r2"

# ---- behaviour (parallel; each scenario has its own run directory) -----------
scenario no-ack          sim.sh        a_none         no-host-ack 4 6 &
scenario ack-holds       sim.sh        a_ack          deadline    8 9 &
scenario ack-collected   sim.sh        a_ack_done     collected   3 6 &
scenario cancel-attempt  sim.sh        a_cancel       deadline    8 9 &
scenario ack-late        sim.sh        a_ack_late     deadline    8 9 &
scenario malformed-ack   sim.sh        a_malformed    no-host-ack 4 6 &
scenario fifo-ack        sim.sh        a_fifo_ack     no-host-ack 4 7 &
scenario done-no-ack     sim.sh        a_done_noack   collected   2 5 &
scenario fifo-collected  sim.sh        a_fifo_done    collected   2 5 &
scenario fifo-logs       sim.sh        a_fifo_logs    deadline    8 9 &
wait   # wave 1 done; wave 2 below (fewer concurrent qemu processes, steadier timing)
scenario fifo-stalled    sim.sh        a_fifo_stalled backstop    9 10 STALL=1 &
scenario stalled-pid1    sim.sh        a_ack          backstop    9 10 STALL=1 &
scenario backstop-sleep-killed sim.sh  a_kill_sleep   backstop    2 7 &
scenario fork-count      sim.sh        a_forks        deadline    8 9 &
printf '5.00 1\n' > "$W/frozen.clock"; FAKE_UPTIME=$W/frozen.clock scenario frozen-clock sim.sh a_frozen deadline-ticks 8 12 &
printf '5.00 1\n' > "$W/octal.clock";  FAKE_UPTIME=$W/octal.clock  scenario octal-clock  sim.sh a_octal  deadline 1 6 &
printf '5.00 1\n' > "$W/huge.clock";   FAKE_UPTIME=$W/huge.clock   scenario huge-clock   sim.sh a_huge   deadline 1 6 &
SETE=1 scenario set-eu          sim.sh        a_ack          deadline    8 9 &
STRACE=1 scenario strace-exec sim.sh   a_ack          deadline    8 9 &
FAKE_UPTIME=/nonexistent scenario clock-unreadable sim.sh a_none 'deadline|backstop' 0 2 &
scenario stage1-control  sim-stage1.sh a_ack          none        0 $((DL + 3)) &
wait
for n in no-ack ack-holds ack-collected cancel-attempt ack-late malformed-ack fifo-ack done-no-ack          fifo-collected fifo-logs fifo-stalled stalled-pid1 backstop-sleep-killed fork-count strace-exec frozen-clock octal-clock huge-clock set-eu clock-unreadable stage1-control; do
    if [ -f "$W/$n.res" ]; then tee -a "$SUM" < "$W/$n.res"; else echo "$n FAIL no result" | tee -a "$SUM"; fi
done

# S5: fork-free loop -> the only child seen is the backstop subshell (and its sleep)
note=$(cat "$W/fork-count.note" 2>/dev/null)
nch=$(echo "$note" | sed -n 's/^children seen in 3 s: \([0-9]*\).*/\1/p')
echo "# $note" >> "$FX/fork-count.txt"
[ -n "$nch" ] && [ "$nch" -le 2 ] && res fork-free-loop 0 "after the ack the loop forked nothing in 3 s; the only child is the backstop ($note)" \
    || res fork-free-loop 1 "$note"

# PID 1 path, qemu -strace of the simulated PID 1: after READY, no clone before the execve of fs-reboot-final
SP=$(cat "$W/strace-exec.rec.pid" 2>/dev/null)
LOG=$W/strace-exec.stdout
seg=$(grep "^$SP " "$LOG" | sed -n '/READY/,$p')
ncl=$(echo "$seg" | sed -n '1,/execve(".*fake-final"/p' | grep -c ' clone(')
nex=$(echo "$seg" | grep -c 'execve(".*fake-final"')
{ echo "# qemu -strace of the simulated PID 1 (pid $SP), from the READY write on (clone/execve/READY/host_ack lines):"
  echo "$seg" | grep -E 'READY|clone|execve|host_ack' | sed 's/^/#   /' | head -40; } > "$FX/strace-exec-syscalls.txt"
{ [ -n "$SP" ] && [ "$nex" = 1 ] && [ "$ncl" = 0 ]; } \
    && res pid1-exec-no-clone 0 "PID 1 (pid $SP): 0 clone calls between READY and execve(fs-reboot-final); the reboot is an exec" \
    || res pid1-exec-no-clone 1 "pid=$SP clones=$ncl execve-final=$nex"

# the REAL fs-reboot-final exec'd by the simulated PID 1 (reboot fails unprivileged: EPERM)
FINAL_BIN=$HERE/build/fs-reboot-final
R=$W/real-final; mkdir -p "$R"; REC=$W/real-final.rec
( cd /; exec setsid env -i PATH="$W/bin" HOLD="$HOLD" FS_RUN="$R" FS_REC="$REC" FS_UPTIME=/proc/uptime \
    FS_REBOOT_BIN="$W/bin/fake-reboot" FS_REBOOT_FALLBACK="$W/bin/fake-reboot fallback" FS_REBOOT_FINAL="$FINAL_BIN" \
    DL=$DL AW=$AW /usr/bin/qemu-aarch64 "$BB" sh "$W/sim.sh" > "$R.stdout" 2>&1 ) &
rp=$!
a_ack "$R"
sleep $((DL + 4))
SP=$(cat "$REC.pid" 2>/dev/null)
alive=no; cmd=""
if [ -n "$SP" ] && kill -0 "$SP" 2>/dev/null; then alive=yes; cmd=$(tr '\000' ' ' < "/proc/$SP/cmdline"); fi
own=$(grep -c "pid=$SP " "$REC" 2>/dev/null)
{ echo "# simulated PID 1 with FS_REBOOT_FINAL = the real build/fs-reboot-final ($(sha256sum "$FINAL_BIN" | cut -c1-64))"
  echo "# deadline+4 s later: pid $SP alive=$alive cmdline: $cmd"
  echo "# fork-path records by PID 1 itself: $own"; echo "# all records (the backstop child's fork path may appear):"; sed 's/^/#   /' "$REC" 2>/dev/null; } > "$FX/real-final.txt"
kill -9 -- -$rp 2>/dev/null
{ [ "$alive" = yes ] && echo "$cmd" | grep -q 'fs-reboot-final' && [ "$own" = 0 ]; } \
    && res pid1-real-final 0 "PID 1 exec'd the real fs-reboot-final at the deadline; with reboot failing (EPERM) it is still alive at deadline+4 s (never exits) and never took the fork path" \
    || res pid1-real-final 1 "alive=$alive cmd='$cmd' own-fork-records=$own"

# fs-reboot-final on its own, unprivileged under qemu -strace: both reboot calls fail (EPERM),
# then it must sleep for ever and NEVER exit
qemu-aarch64 -strace "$FINAL_BIN" > "$W/final.strace" 2>&1 &
fp=$!
sleep 4
falive=no; kill -0 $fp 2>/dev/null && falive=yes
kill -9 $fp 2>/dev/null; wait $fp 2>/dev/null
nrb=$(grep -c 'reboot(' "$W/final.strace"); nep=$(grep -c 'reboot(.*= -1 errno=1' "$W/final.strace")
LAY=$(cat "$HERE/build/fs-reboot-final.layout"); SV=${LAY#str_vaddr=}; SV=${SV%% *}; TV=${LAY#*ts_vaddr=}
a1=$(grep -c "reboot(4276215469,672274793,2712847316,$SV," "$W/final.strace")    # 0xfee1dead, 0x28121969, 0xa1b2c3d4, &"bootloader"
a2=$(grep -c "reboot(4276215469,672274793,19088743,0," "$W/final.strace")         # ..., 0x01234567, 0
a3=$(grep -c "nanosleep($TV,0," "$W/final.strace")                                # &{3600,0} (proved by check_final.py), NULL
nns=$(grep -c 'nanosleep(' "$W/final.strace"); nexit=$(grep -Ec 'exit\(|exit_group\(' "$W/final.strace")
{ echo "# qemu-aarch64 -strace build/fs-reboot-final, unprivileged; killed by the harness after 4 s"
  echo "# alive after 4 s: $falive; reboot calls $nrb (EPERM $nep); nanosleep calls $nns; exit calls $nexit"
  sed 's/^/#   /' "$W/final.strace" | head -10; } > "$FX/fs-reboot-final.txt"
{ [ "$falive" = yes ] && [ "$nrb" = 2 ] && [ "$nep" = 2 ] && [ "$nns" -ge 1 ] && [ "$nexit" = 0 ] && [ "$a1" = 1 ] && [ "$a2" = 1 ] && [ "$a3" -ge 1 ]; } \
    && res fs-reboot-final-never-exits 0 "reboot(0xfee1dead,0x28121969,0xa1b2c3d4,&'bootloader' @$SV) then reboot(...,0x01234567,0), both EPERM; then nanosleep(&{3600,0} @$TV); alive after 4 s; no exit call" \
    || res fs-reboot-final-never-exits 1 "alive=$falive reboot=$nrb eperm=$nep nanosleep=$nns exit=$nexit args=$a1/$a2/$a3"

p=$(grep -c ' PASS ' "$SUM"); f=$(grep -c ' FAIL ' "$SUM")
echo "TOTAL pass=$p fail=$f" | tee -a "$SUM"
[ "$f" = 0 ]
