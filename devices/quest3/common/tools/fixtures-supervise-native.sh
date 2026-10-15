#!/bin/bash
# FrameShift common — fs-supervise fixtures on a NATIVE x86-64 build of the
# same source (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/common/tools/fixtures-supervise-native.sh
# Why native: qemu-user is too slow to show timing faults (review B2: fast
# writers starving the deadline). The aarch64 binary keeps its own qemu suite
# (fixtures-supervise.sh); this one is the same C file built with the host gcc.
#   SRC=<file> OUT=<dir>  test another source (used for the before/after table)
# Touches no device.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest3/common
SRC=${SRC:-$HERE/src/fs-supervise.c}
FX=${OUT:-$HERE/fixtures/supervise-native}
W=$(mktemp -d /tmp/fssupn.XXXXXX)
trap 'pkill -9 -f "$W/" 2>/dev/null; rm -rf "$W"' EXIT
rm -rf "$FX"; mkdir -p "$FX" "$W/cap"
SUM=$FX/RESULTS.txt; : > "$SUM"

gcc -O2 -Wall -Wextra -o "$W/fsup" "$SRC" 2> "$W/cc.txt" || { cat "$W/cc.txt"; exit 1; }
gcc -O2 -o "$W/hopper" "$HERE/tools/testprogs/hopper.c"
gcc -O2 -o "$W/esc" "$HERE/tools/testprogs/esc.c"
S=$W/fsup
echo "source sha256=$(sha256sum "$SRC" | cut -c1-64)" | tee -a "$SUM"
echo "native: $(gcc --version | head -1), binary sha256=$(sha256sum "$S" | cut -c1-64) (test build only)" | tee -a "$SUM"

ms() { echo $(( $(date +%s%N) / 1000000 )); }
f() { echo "$REP" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
res() { if [ "$2" = 0 ]; then echo "$1 PASS $3" | tee -a "$SUM"; else echo "$1 FAIL $3 | $REP rc=$RC wall=$WALL" | tee -a "$SUM"; fi; }
between() { [ -n "$1" ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
# run NAME [prefix-cmd...] -- fs-supervise-args...
run() {
    local name=$1; shift
    local pre=()
    while [ "$1" != "--" ]; do pre+=("$1"); shift; done; shift
    OUT=$W/cap/$name.o; ERR=$W/cap/$name.e
    local t0; t0=$(ms)
    timeout 60 "${pre[@]}" "$S" -o "$OUT" -r "$ERR" "$@" > "$W/cap/$name.rep" 2>/dev/null; RC=$?
    REP=$(grep '^FSUP1' "$W/cap/$name.rep")
    WALL=$(( $(ms) - t0 ))
    { echo "# report: $REP"; echo "# exit=$RC wall_ms=$WALL"
      [ -f "$OUT" ] && { echo "# stdout (first 300 B):"; head -c 300 "$OUT" | sed 's/^/#   /'; }
      [ -f "$ERR" ] && { echo "# stderr (first 300 B):"; head -c 300 "$ERR" | sed 's/^/#   /'; }; } > "$FX/$name.txt"
}

# ---- B2: fast writers vs the deadline ---------------------------------------------
run flood1 -- -t 1 -g 1 -c 0 -- /bin/sh -c 'exec cat /dev/zero'
res flood1 "$( between "$(f term_ms)" 1000 1100 && [ "$(f end)" = timer-term ] && [ "$(f ms)" -lt 1500 ]; echo $?)" "1 writer: timer-term, TERM at 1000..1100 ms, reaped < 1500 ms"
run flood4 -- -t 1 -g 1 -c 0 -- /bin/sh -c 'cat /dev/zero & cat /dev/zero & cat /dev/zero & exec cat /dev/zero'
res flood4 "$( between "$(f term_ms)" 1000 1100 && [ "$(f end)" = timer-term ] && [ "$(f kill_ms)" = -1 ] && [ "$(f ms)" -lt 1500 ] && [ "$(f why)" = none ]; echo $?)" "4 writers: timer-term, TERM at 1000..1100 ms, no KILL, reaped < 1500 ms"
run flood4ign -- -t 1 -g 1 -c 0 -- /bin/sh -c 'trap "" TERM; cat /dev/zero & cat /dev/zero & cat /dev/zero & exec cat /dev/zero'
gap=$(( $(f kill_ms) - $(f term_ms) ))
res flood4ign "$( [ "$(f end)" = timer-kill ] && between "$(f term_ms)" 1000 1100 && between $gap 1000 1100 && [ "$(f ms)" -lt 2600 ]; echo $?)" "4 TERM-ignoring writers: timer-kill, TERM ~1000 ms, KILL a full grace (1000..1100 ms) after the TERM (gap=$gap)"
run sleeper -- -t 1 -g 1 -- /bin/sleep 30
res sleeper "$( [ "$(f end)" = timer-term ] && between "$(f term_ms)" 1000 1030; echo $?)" "deadline precision: TERM at 1000..1030 ms"
run stopped -- -t 1 -g 1 -- /bin/sh -c 'kill -STOP $$'
res stopped "$( [ "$(f end)" = timer-kill ] && [ "$(f sig)" = 9 ]; echo $?)" "a stopped child: TERM stays pending, KILL ends it (timer-kill)"

# ---- S1: inherited descriptors -----------------------------------------------------
: > "$W/leak.txt"
exec 7>"$W/leak.txt"
run fdleak -- -t 5 -- /bin/sh -c 'ls /proc/$$/fd; echo LEAKED >&7'
exec 7>&-
res fdleak "$( [ ! -s "$W/leak.txt" ] && [ "$(tr '\n' ' ' < "$OUT")" = "0 1 2 " ]; echo $?)" "caller's fd 7 not inherited; child fds exactly 0 1 2"

# ---- S2: session and controlling tty ---------------------------------------------------
python3 -I -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], sys.argv[1:])
out = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
' "$S" -t 5 -o "$W/cap/sess.o" -r "$W/cap/sess.e" -- /bin/sh -c 'read -r a b c d e s t rest < /proc/$$/stat; echo "pid=$a pgrp=$e sid=$s tty=$t"' > "$W/sess.rep"
REP=$(grep -a '^FSUP1' "$W/sess.rep" | tr -d '\r'); RC=-; WALL=-
L=$(cat "$W/cap/sess.o")
{ echo "# run inside a pty (fs-supervise HAS a controlling tty)"; echo "# report: $REP"; echo "# child: $L"; } > "$FX/session.txt"
p=$(echo "$L" | sed -n 's/^pid=\([0-9]*\) .*/\1/p')
res session "$( [ -n "$p" ] && [ "$L" = "pid=$p pgrp=$p sid=$p tty=0" ]; echo $?)" "child is a session leader with no controlling tty ($L)"

# ---- S3: inherited SIG_IGN on the supervisor ---------------------------------------------
run sigchld python3 -I -c 'import os,signal,sys; signal.signal(signal.SIGCHLD, signal.SIG_IGN); os.execv(sys.argv[1], sys.argv[1:])' -- -t 3 -g 1 -- /bin/true
res sigchld-ignored "$( [ "$(f end)" = exited ] && [ "$(f code)" = 0 ] && [ "$WALL" -lt 1500 ]; echo $?)" "caller ignored SIGCHLD: /bin/true still end=exited code=0 at once"
run sigalrm python3 -I -c 'import os,signal,sys; signal.signal(signal.SIGALRM, signal.SIG_IGN); os.execv(sys.argv[1], sys.argv[1:])' -- -t 2 -- /bin/sh -c 'sed -n "s/^SigIgn:[[:space:]]*//p" /proc/$PPID/status'
m=$(cat "$OUT"); ign=$(( 0x$m & 0x2000 ))
res sigalrm-ignored "$( [ -n "$m" ] && [ $ign = 0 ]; echo $?)" "caller ignored SIGALRM: the supervisor's SigIgn ($m) has no SIGALRM bit, so its 90 s backstop is armed"

# ---- S4: descendants ------------------------------------------------------------------------
pkill -9 -x esc 2>/dev/null
run escape -- -t 5 -- "$W/esc"
sleep 0.3; left=$(pgrep -xc esc)
res escape "$( grep -q '^setsid=ok' "$OUT" && [ "$(f strays)" = 1 ] && [ "$(f why)" = none ] && [ "$left" = 0 ] && [ "$RC" = 0 ]; echo $?)" "setsid escapee (setsid=ok asserted) killed via /proc: strays=1 why=none, none left"
pkill -9 -x esc 2>/dev/null
rm -f "$W/marker"
run hopper -- -t 2 -g 1 -- "$W/hopper" "$W/marker"
sleep 1; left=$(pgrep -xc hopper)
res hopper "$( [ "$left" = 0 ] && [ "$(f why)" = none ]; echo $?)" "fork-hopper in its own session hunted down: none alive 1 s later, why=none (strays=$(f strays))"
sleep 6
res hopper-marker "$( [ ! -f "$W/marker" ]; echo $?)" "no hopper instance survived to 5 s (no marker)"
pkill -9 -x hopper 2>/dev/null
if unshare -rm true 2>/dev/null; then
    REP=$(unshare -rm sh -c "mount -t tmpfs none /proc && exec $S -t 2 -o $W/cap/noproc.o -r $W/cap/noproc.e -- $W/esc" 2>/dev/null); RC=$?; WALL=-
    sleep 0.3; left=$(pgrep -xc esc)
    { echo "# fs-supervise in a mount namespace with an empty tmpfs over /proc"; echo "# report: $REP"; echo "# exit=$RC escapees alive afterwards: $left"; } > "$FX/noproc.txt"
    res noproc "$( echo "$REP" | grep -q 'why=no-proc' && [ "$RC" = 7 ] && [ "$left" = 1 ]; echo $?)" "/proc hidden: the surviving escapee is REPORTED (why=no-proc, exit 7), not strays=0/why=none"
    pkill -9 -x esc 2>/dev/null
else
    echo "noproc SKIP unshare -rm not available" | tee -a "$SUM"
fi

# ---- nits ------------------------------------------------------------------------------------
for o in "-g 1 -g 2" "-c 10 -c 20" "-i /dev/null -i /dev/null"; do
    run "dup${o:1:1}" -- -t 5 $o -- /bin/true
    res "dup-option-${o:1:1}" "$( [ "$(f end)" = refused ] && [ "$(f why)" = usage ] && [ "$RC" = 64 ]; echo $?)" "'$o' refused"
done
for kv in SCUDO_OPTIONS=x LIBC_DEBUG_MALLOC_OPTIONS=x MUSL_LOCPATH=/x; do
    k=${kv%%=*}; run "env-$k" -- -t 5 -e "$kv" -- /usr/bin/env
    res "env-$k" "$( [ "$(f why)" = env-refused ]; echo $?)" "-e $k refused"
done

p=$(grep -c ' PASS ' "$SUM"); fl=$(grep -c ' FAIL ' "$SUM")
echo "TOTAL pass=$p fail=$fl" | tee -a "$SUM"
[ "$fl" = 0 ]
