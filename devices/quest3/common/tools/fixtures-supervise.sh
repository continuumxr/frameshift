#!/bin/bash
# FrameShift common — offline fixtures for fs-supervise (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/common/tools/fixtures-supervise.sh
# Runs the exact aarch64 build/fs-supervise under qemu-aarch64 (user mode).
# Children are the REVIEWED stage-1 busybox (aarch64, sha256 c2f279d1…ec02),
# executed through binfmt_misc (qemu-aarch64), with PATH pointing at busybox
# applet links so every child-side tool is that busybox too.
# Touches no device. Writes fixtures/supervise/*.txt and RESULTS.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"
HERE=$ROOT/devices/quest3/common
BIN=$HERE/build/fs-supervise
BB_SRC=$ROOT/build/third_party/busybox/busybox
FX=${OUT:-$HERE/fixtures/supervise}   # OUT=<dir>: write results elsewhere (default: the tracked fixture dir)
# refuse BEFORE touching any committed result file when a gitignored build input is missing
for _in in "$BB_SRC" "$BIN"; do
    [ -f "$_in" ] || { echo "REFUSED: build input missing: $_in (gitignored; see README \"What is not in git\"); nothing was written"; exit 1; }
done
W=$(mktemp -d /tmp/fssup.XXXXXX)
trap 'rm -rf "$W"' EXIT
rm -rf "$FX"; mkdir -p "$FX"
SUM=$FX/RESULTS.txt
: > "$SUM"
fails=0; passes=0

[ "$(sha256sum "$BB_SRC" | cut -c1-64)" = c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02 ] \
    || { echo "REFUSED: busybox is not the reviewed binary"; exit 1; }
grep -q enabled /proc/sys/fs/binfmt_misc/qemu-aarch64 || { echo "REFUSED: no binfmt for aarch64"; exit 1; }
mkdir -p "$W/bin" "$W/cap"
cp "$BB_SRC" "$W/bin/busybox"; chmod 0755 "$W/bin/busybox"
for a in sh sleep echo cat env pwd yes head kill setsid printf trap wait true; do ln -s busybox "$W/bin/$a"; done
BB=$W/bin/busybox
P="-e PATH=$W/bin"

echo "fs-supervise sha256=$(sha256sum "$BIN" | cut -c1-64)" | tee -a "$SUM"
echo "busybox      sha256=$(sha256sum "$BB" | cut -c1-64) (children)" | tee -a "$SUM"
echo "qemu: $(qemu-aarch64 --version | head -1)" | tee -a "$SUM"

GRAMMAR='^FSUP1 end=(exited|signaled|timer-term|timer-kill|exec-failed|unreaped|refused|internal) code=-?[0-9]+ sig=[0-9]+ errno=[0-9]+ ms=-?[0-9]+ term_ms=-?[0-9]+ kill_ms=-?[0-9]+ out_total=[0-9]+ out_kept=[0-9]+ err_total=[0-9]+ err_kept=[0-9]+ strays=[0-9]+ pipes=(eof|open|none) why=[a-z-]+ END$'

ms() { echo $(( $(date +%s%N) / 1000000 )); }
f() { echo "$REP" | tr ' ' '\n' | sed -n "s/^$1=//p"; }        # field of the last report
res() {  # res <name> <ok 0/1> <detail>
    if [ "$2" = 0 ]; then echo "$1 PASS $3" | tee -a "$SUM"; passes=$((passes + 1))
    else echo "$1 FAIL $3" | tee -a "$SUM"; fails=$((fails + 1)); fi
}
# run <name> <supervise args...>: sets REP, RC, WALL, OUT, ERR; writes fixtures/supervise/<name>.txt
run() {
    local name=$1; shift
    OUT=$W/cap/$name.out; ERR=$W/cap/$name.err
    local t0; t0=$(ms)
    REP=$(qemu-aarch64 "$BIN" "$@" 2>"$W/cap/$name.selferr"); RC=$?
    WALL=$(( $(ms) - t0 ))
    {
        echo "# cmd: fs-supervise $*" | sed "s#$W#\$W#g"
        echo "# report: $REP"
        echo "# exit=$RC wall_ms=$WALL"
        [ -s "$W/cap/$name.selferr" ] && echo "# fs-supervise stderr: $(cat "$W/cap/$name.selferr")"
        if [ -f "$OUT" ]; then echo "# stdout capture: $(stat -c %s "$OUT") bytes, first 64 as hex:"; head -c 64 "$OUT" | od -An -c | sed 's/^/#   /'; else echo "# stdout capture: (no file)"; fi
        if [ -f "$ERR" ]; then echo "# stderr capture: $(stat -c %s "$ERR") bytes, first 64 as hex:"; head -c 64 "$ERR" | od -An -c | sed 's/^/#   /'; else echo "# stderr capture: (no file)"; fi
    } > "$FX/$name.txt"
    if echo "$REP" | grep -Eq "$GRAMMAR" && [ "$(echo "$REP" | wc -l)" = 1 ]; then :; else res "$name-grammar" 1 "bad report: $REP"; fi
}
# expect <name> <condition-description> <shell test...>
expect() { local name=$1 d=$2; shift 2; if "$@"; then res "$name" 0 "$d"; else res "$name" 1 "$d | $REP exit=$RC wall=$WALL"; fi; }
is() { [ "$1" = "$2" ]; }
between() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
o() { echo "-o $OUT -r $ERR"; }
pre() { OUT=$W/cap/$1.out; ERR=$W/cap/$1.err; }

# ---- background: backstop (fs-supervise itself stopped past its 90 s alarm) ----
pre backstop
( t0=$(ms)
  qemu-aarch64 "$BIN" -t 60 $P $(o) -- "$BB" sleep 3000 > "$W/cap/backstop.rep" 2>&1 & sp=$!
  sleep 2
  # the child sleep must die with fs-supervise (PR_SET_PDEATHSIG)
  kill -STOP $sp; sleep 92; kill -CONT $sp; wait $sp; rc=$?
  sleep 1
  left=$(ps -eo args | grep -c "[s]leep 3000")
  echo "rc=$rc wall_ms=$(( $(ms) - t0 )) children_left=$left report=$(cat "$W/cap/backstop.rep")" > "$W/cap/backstop.res" ) &
P_BACK=$!

# ---- 1. normal exit ----------------------------------------------------------------
pre normal; run normal -t 5 $P $(o) -- "$BB" sh -c 'echo hello; echo err >&2'
expect normal "end=exited code=0, exit 0, out 6 B, err 4 B, nothing sent" \
  eval 'is "$(f end)" exited && is "$(f code)" 0 && is $RC 0 && is "$(f out_total)" 6 && is "$(f out_kept)" 6 && is "$(f err_total)" 4 && is "$(f term_ms)" -1 && is "$(f kill_ms)" -1 && is "$(f strays)" 0 && is "$(f pipes)" eof && is "$(cat $OUT)" hello'

# ---- 2. nonzero exit --------------------------------------------------------------
pre nonzero; run nonzero -t 5 $P $(o) -- "$BB" sh -c 'exit 3'
expect nonzero "end=exited code=3, no timer" eval 'is "$(f end)" exited && is "$(f code)" 3 && is "$(f term_ms)" -1 && is $RC 0'

# ---- 2b. a child that exits 143 by itself: NOT a timer event ----------------------
pre exit143; run exit143 -t 5 $P $(o) -- "$BB" sh -c 'exit 143'
expect exit143 "end=exited code=143 term_ms=-1 (143 alone is not timer evidence)" \
  eval 'is "$(f end)" exited && is "$(f code)" 143 && is "$(f term_ms)" -1 && is "$(f kill_ms)" -1'

# ---- 3. TERM-honouring sleeper ------------------------------------------------------
pre sleeper; run sleeper -t 2 -g 3 $P $(o) -- "$BB" sleep 30
expect sleeper "end=timer-term sig=15, TERM at ~2000 ms, no KILL, wall < 4 s" \
  eval 'is "$(f end)" timer-term && is "$(f sig)" 15 && between "$(f term_ms)" 2000 2300 && is "$(f kill_ms)" -1 && is $RC 3 && [ $WALL -lt 4000 ]'

# ---- 3b. TERM handled: the child exits 143 itself after our TERM --------------------
pre term143; run term143 -t 2 -g 3 $P $(o) -- "$BB" sh -c 'trap "exit 143" TERM; sleep 30 & wait'
expect term143 "end=timer-term code=143 (raw status kept apart from the timer evidence)" \
  eval 'is "$(f end)" timer-term && is "$(f code)" 143 && is "$(f sig)" 0 && between "$(f term_ms)" 2000 2300 && is "$(f kill_ms)" -1'

# ---- 4. TERM-IGNORING child: must be KILLed --------------------------------------------
pre ignterm; run ignterm -t 2 -g 2 $P $(o) -- "$BB" sh -c 'trap "" TERM; echo ready; while :; do sleep 1; done'
expect ignterm "end=timer-kill sig=9, TERM ~2000 ms, KILL ~4000 ms, wall < 6 s, exit 4" \
  eval 'is "$(f end)" timer-kill && is "$(f sig)" 9 && between "$(f term_ms)" 2000 2300 && between "$(f kill_ms)" 4000 4300 && is $RC 4 && [ $WALL -lt 6000 ] && is "$(cat $OUT)" ready'
sleep 1
expect ignterm-nothing-left "no 'sleep 1' loop survives" eval '! ps -eo args | grep -q "[w]hile :; do sleep 1"'

# ---- 4b. TERM ignored by inheritance: fs-supervise itself started with TERM ignored ---
pre inherit
OUT=$W/cap/inherit.out; ERR=$W/cap/inherit.err
t0=$(ms); REP=$(trap '' TERM; qemu-aarch64 "$BIN" -t 2 -g 3 $P -o "$OUT" -r "$ERR" -- "$BB" sleep 30); RC=$?; WALL=$(( $(ms) - t0 ))
echo "# cmd: (trap '' TERM; fs-supervise -t 2 -g 3 -- busybox sleep 30)"$'\n'"# report: $REP"$'\n'"# exit=$RC wall_ms=$WALL" > "$FX/inherit.txt"
expect inherit "inherited SIG_IGN is reset in the child: timer-term, not timer-kill" eval 'is "$(f end)" timer-term && is "$(f sig)" 15'

# ---- 5. grandchild holding the pipe ------------------------------------------------------
pre grandchild; run grandchild -t 10 $P $(o) -- "$BB" sh -c 'sleep 30 & echo started'
expect grandchild "child exits 0; grandchild in the group killed (strays=1); pipes eof; wall < 3 s" \
  eval 'is "$(f end)" exited && is "$(f code)" 0 && is "$(f strays)" 1 && is "$(f pipes)" eof && [ $WALL -lt 3000 ] && is "$(cat $OUT)" started'

# ---- 5b. child and grandchild both hang: the group gets TERM ----------------------------
pre grouphang; run grouphang -t 2 -g 3 $P $(o) -- "$BB" sh -c 'sleep 30 & sleep 31'
expect grouphang "timer-term; the whole group dies at the TERM; wall < 4 s" \
  eval 'is "$(f end)" timer-term && is "$(f kill_ms)" -1 && [ $WALL -lt 4000 ]'
sleep 1
expect grouphang-nothing-left "no 'sleep 30'/'sleep 31' survives" eval '! ps -eo args | grep -Eq "[s]leep 3[01]$"'

# ---- 5c. grandchild escapes with setsid (subreaper + session hunt); setsid success asserted ----
pre escape; run escape -t 10 $P $(o) -- "$BB" sh -c 'setsid sh -c "cat /proc/\$\$/stat; exec sleep 33" & sleep 0.5; echo out'
st=$(grep -v '^out$' "$OUT" | head -1); spid=$(echo "$st" | cut -d' ' -f1); ssid=$(echo "$st" | cut -d' ' -f6)
expect escape "setsid succeeded (escapee pid=$spid = sid=$ssid); killed and reaped (strays=1), pipes eof, why=none, wall < 3 s" \
  eval '[ -n "$spid" ] && is "$spid" "$ssid" && is "$(f end)" exited && is "$(f strays)" 1 && is "$(f pipes)" eof && is "$(f why)" none && [ $WALL -lt 3000 ]'
sleep 1
expect escape-nothing-left "no 'sleep 33' survives" eval '! ps -eo args | grep -q "[s]leep 33"'

# ---- 6. output exceeding the cap ----------------------------------------------------------
pre flood; run flood -t 10 -c 1000 $P $(o) -- "$BB" sh -c 'yes a | head -c 100000 & yes b | head -c 100000 & yes e | head -c 5000 >&2 & yes f | head -c 5000 >&2 & wait'
expect flood "4 concurrent writers: out_total=200000 out_kept=1000 (file 1000 B); err_total=10000 err_kept=1000" \
  eval 'is "$(f end)" exited && is "$(f out_total)" 200000 && is "$(f out_kept)" 1000 && is "$(stat -c %s $OUT)" 1000 && is "$(f err_total)" 10000 && is "$(f err_kept)" 1000 && is "$(stat -c %s $ERR)" 1000'
pre endless; run endless -t 2 -c 4096 $P $(o) -- "$BB" yes
expect endless "an endless writer is stopped by the deadline on time: timer-term, out_total >> cap, kept = 4096" \
  eval 'is "$(f end)" timer-term && [ "$(f out_total)" -gt 100000 ] && is "$(f out_kept)" 4096 && [ $WALL -lt 4000 ]'
pre cap0; run cap0 -t 5 -c 0 $P $(o) -- "$BB" echo x
expect cap0 "cap 0: counted, nothing kept" eval 'is "$(f out_total)" 2 && is "$(f out_kept)" 0 && is "$(stat -c %s $OUT)" 0'

# ---- 7. environment ----------------------------------------------------------------------
pre envempty; run envempty -t 5 $(o) -- "$BB" env
expect envempty "no -e: the child sees an EMPTY environment (0 bytes from env)" eval 'is "$(f end)" exited && is "$(f out_total)" 0'
pre envone; run envone -t 5 -e FOO=bar $(o) -- "$BB" env
expect envone "-e FOO=bar: the child sees exactly FOO=bar" eval 'is "$(cat $OUT)" FOO=bar && is "$(f out_total)" 8'
for kv in LD_PRELOAD=/x.so LD_LIBRARY_PATH=/x LD_DEBUG=all GLIBC_TUNABLES=glibc.malloc.check=3 MALLOC_ARENA_MAX=1 LC_ALL=C LANG=C TZ=UTC GCONV_PATH=/x LOCPATH=/x POSIXLY_CORRECT=1; do
    k=${kv%%=*}; pre "env-$k"
    run "env-$k" -t 5 -e "$kv" $(o) -- "$BB" env
    expect "env-$k" "-e $k=… refused, exit 64, nothing started, no capture file" \
      eval 'is "$(f end)" refused && is "$(f why)" env-refused && is $RC 64 && [ ! -e $OUT ] && is "$(f ms)" -1'
done
pre envdup; run envdup -t 5 -e A=1 -e A=2 $(o) -- "$BB" env
expect envdup "duplicate key refused" eval 'is "$(f why)" env-duplicate && is $RC 64'
pre envsyntax; run envsyntax -t 5 -e 1A=1 $(o) -- "$BB" env
expect envsyntax "bad key refused" eval 'is "$(f why)" env-syntax && is $RC 64'
pre envnoeq; run envnoeq -t 5 -e FOO $(o) -- "$BB" env
expect envnoeq "KEY without = refused" eval 'is "$(f why)" env-syntax && is $RC 64'

# ---- 8. argument and path refusals ----------------------------------------------------------
pre relprog; run relprog -t 5 $(o) -- busybox true
expect relprog "relative program refused" eval 'is "$(f why)" prog-not-absolute && is $RC 64'
pre dotdot; run dotdot -t 5 $(o) -- "$W/bin/../bin/busybox" true
expect dotdot "'..' in program path refused" eval 'is "$(f why)" prog-not-absolute && is $RC 64'
pre t0; run t0 -t 0 $(o) -- "$BB" true
expect t0 "timeout 0 refused" eval 'is "$(f why)" timeout-range && is $RC 64'
pre t61; run t61 -t 61 $(o) -- "$BB" true
expect t61 "timeout 61 (> compiled max 60) refused" eval 'is "$(f why)" timeout-range && is $RC 64'
pre g11; run g11 -t 5 -g 11 $(o) -- "$BB" true
expect g11 "grace 11 (> compiled max 10) refused" eval 'is "$(f why)" grace-range'
pre bigcap; run bigcap -t 5 -c 1048577 $(o) -- "$BB" true
expect bigcap "cap > 1 MiB refused" eval 'is "$(f why)" cap-range'
pre notimeout; run notimeout $(o) -- "$BB" true
expect notimeout "missing -t refused" eval 'is "$(f why)" usage && is $RC 64'
pre lead0; run lead0 -t 05 $(o) -- "$BB" true
expect lead0 "non-canonical number refused" eval 'is "$(f why)" usage'
pre exists; : > "$W/cap/exists.out"; run exists -t 5 $(o) -- "$BB" true
expect exists "existing capture file refused (O_EXCL)" eval 'is "$(f why)" out-open && is $RC 64'
pre stdinzero; run stdinzero -t 5 -i /dev/zero $(o) -- "$BB" true
expect stdinzero "stdin from a non-null char device refused" eval 'is "$(f why)" stdin-not-file'
pre samefile; run samefile -t 5 -o "$W/cap/same" -r "$W/cap/same" -- "$BB" true
expect samefile "same file for stdout and stderr refused" eval 'is "$(f why)" same-capture-file'

# ---- 9. stdin, cwd, exec failure, signal ------------------------------------------------------
pre stdinnull; run stdinnull -t 5 $P $(o) -- "$BB" cat
expect stdinnull "default stdin is /dev/null: cat ends at once with 0 bytes" eval 'is "$(f end)" exited && is "$(f out_total)" 0 && [ $WALL -lt 2000 ]'
printf 'fs-0123456789abcdef:%s' 00112233445566778899aabbccddeeff > "$W/chal.bin"
pre stdinfile; run stdinfile -t 5 -i "$W/chal.bin" $P $(o) -- "$BB" cat
expect stdinfile "-i FILE: the child reads exactly its bytes" eval 'cmp -s $OUT $W/chal.bin && is "$(f out_total)" 52'
pre cwd; run cwd -t 5 $P $(o) -- "$BB" pwd
expect cwd "cwd is /" eval 'is "$(cat $OUT)" /'
pre enoent; run enoent -t 5 $(o) -- /nonexistent/prog
expect enoent "end=exec-failed errno=2, exit 5 (not confused with exit 127)" eval 'is "$(f end)" exec-failed && is "$(f errno)" 2 && is $RC 5'
printf 'x' > "$W/noexec"; chmod 0644 "$W/noexec"
pre eacces; run eacces -t 5 $(o) -- "$W/noexec"
expect eacces "end=exec-failed errno=13" eval 'is "$(f end)" exec-failed && is "$(f errno)" 13'
pre segv; run segv -t 5 $P $(o) -- "$BB" sh -c 'kill -SEGV $$'
expect segv "end=signaled sig=11 (not a timer event)" eval 'is "$(f end)" signaled && is "$(f sig)" 11 && is "$(f term_ms)" -1 && is $RC 2'
pre binary; run binary -t 5 $P $(o) -- "$BB" printf '\000\r\n\377a\r\r\n'
expect binary "raw bytes captured exactly (NUL, CR, LF, 0xff)" eval 'is "$(od -An -tx1 $OUT | tr -d " \n")" 000d0aff610d0d0a && is "$(f out_kept)" 8'

# ---- backstop result ---------------------------------------------------------------------------
wait $P_BACK
B=$(cat "$W/cap/backstop.res")
echo "# fs-supervise -t 60 -- busybox sleep 3000; fs-supervise SIGSTOPped for 92 s (past its 90 s alarm), then SIGCONT" > "$FX/backstop.txt"
echo "# $B" >> "$FX/backstop.txt"
REP=""; RC=$(echo "$B" | sed -n 's/^rc=\([0-9]*\).*/\1/p')
expect backstop "fs-supervise dies by its own SIGALRM (status 142) and the child dies with it" \
  eval 'is "$RC" 142 && echo "$B" | grep -q "children_left=0"'

echo "TOTAL pass=$passes fail=$fails" | tee -a "$SUM"
[ $fails = 0 ]
