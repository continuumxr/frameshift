#!/bin/bash
# FrameShift stage 3a — before/after regression for the review fixes.
#   regress.sh <binary> <source.c> <label> <outfile>
# Each REG line is PASS when the binary/source shows the FIXED behaviour.
#   R1-R7  first review  (fail on v0.1, pass from v0.2)
#   R8-R11 second review (fail on v0.3, pass on v0.4)
# Offline: qemu-aarch64, mock card0 = /dev/null, no DRM ioctls. On v0.1 the
# blocked-stdout cases take ~150 s (they end only by its SIGALRM).
set -u
BIN=$1; SRC=$2; LABEL=$3; OUT=$4
HERE="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest3/stage3a
CLANG=$HOME/toolchains/clang-r450784e/bin/clang
UAPI=$HOME/work/kgate27/src/include/uapi/drm
Q="qemu-aarch64 $BIN"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
: > "$OUT"
reg() { echo "REG $LABEL $1 $2 $3" | tee -a "$OUT"; }
ms() { echo $(( $(date +%s%N) / 1000000 )); }
# close-before-write: after the last rt_sigtimedwait, close(3) must come before the next write(1,...)
close_first() { awk '/rt_sigtimedwait\(/{s=NR; c=0; w=0} s && !c && /close\(3\)/{c=NR} s && !w && / write\(1,/{w=NR} END{exit !(s && c && (!w || c < w))}' "$1"; }

# R1 (first review, blocker): stdout FIFO full, nobody drains; hold 3 s; TERM at 5 s.
r1() {
    local F=$W/fifo1; mkfifo "$F"; exec 3<>"$F"; head -c 65536 /dev/zero >&3
    local t0; t0=$(ms)
    $Q holdtest a1b2c3d4 3 /dev/null >&3 2>/dev/null & local p=$!
    ( sleep 5; kill -TERM $p 2>/dev/null ) & local k=$!
    wait $p; local rc=$?; local dt=$(( $(ms) - t0 )); kill $k 2>/dev/null; exec 3>&-
    [ $rc = 0 ] && [ $dt -lt 4500 ] && reg R1-blocked-stdout-hold PASS "exit=$rc ms=$dt" \
                                   || reg R1-blocked-stdout-hold FAIL "exit=$rc ms=$dt (hold 3 s requested)"
}
# R1b: same blocked FIFO, hold 999 s, TERM at 2 s.
r1b() {
    local F=$W/fifo2; mkfifo "$F"; exec 4<>"$F"; head -c 65536 /dev/zero >&4
    $Q holdtest a1b2c3d4 999 /dev/null >&4 2>/dev/null & local p=$!
    sleep 2; local t1; t1=$(ms); kill -TERM $p; wait $p; local rc=$?; local dt=$(( $(ms) - t1 )); exec 4>&-
    [ $rc = 70 ] && [ $dt -lt 1000 ] && reg R1b-blocked-stdout-term PASS "exit=$rc term_to_exit_ms=$dt" \
                                     || reg R1b-blocked-stdout-term FAIL "exit=$rc term_to_exit_ms=$dt"
}
r1 > /dev/null & P1=$!
r1b > /dev/null & P2=$!

# R2: alarm re-armed to hold+5. hold 3, SIGSTOP at 1 s, SIGCONT at 10 s -> 142.
$Q holdtest a1b2c3d4 3 /dev/null > "$W/r2.txt" 2>&1 & p=$!
sleep 1; kill -STOP $p; sleep 9; kill -CONT $p; wait $p 2>/dev/null; rc=$?
[ $rc = 142 ] && reg R2-alarm-rearmed PASS "exit=142" || reg R2-alarm-rearmed FAIL "exit=$rc"

# R3: stdout on a tty refused with exit 3 and no output.
script -qec "$Q holdtest a1b2c3d4 1 /dev/null" /dev/null > "$W/r3.txt" 2>&1; rc=$?
n=$(grep -c FSP1 "$W/r3.txt")
[ $rc = 3 ] && [ "$n" = 0 ] && reg R3-tty-stdout-refused PASS "exit=3 records=0" \
                            || reg R3-tty-stdout-refused FAIL "exit=$rc records=$n"

# R4: framing len/crc/seq/eos.
$Q holdtest a1b2c3d4 1 /dev/null > "$W/r4.txt" 2>&1
s=$(python3 -I "$HERE/tools/check_stream.py" --expect complete "$W/r4.txt" | cut -d' ' -f3-)
case $s in COMPLETE*) reg R4-framing PASS "$s";; *) reg R4-framing FAIL "$s";; esac

# R5: the fd is closed before the hold_end record is written (syscall order, qemu -strace).
(cd "$W" && qemu-aarch64 -strace "$BIN" holdtest a1b2c3d4 1 /dev/null > "$W/r5.txt" 2> "$W/r5.strace")
close_first "$W/r5.strace" && reg R5-close-before-hold_end-write PASS "strace: close(3) precedes write(1)" \
                           || reg R5-close-before-hold_end-write FAIL "strace: write(1) before close(3)"

# R6: no legacy SETCRTC path (source).
n=$(grep -c 'DRM_IOCTL_MODE_SETCRTC' "$SRC")
[ "$n" = 0 ] && reg R6-no-legacy-setcrtc PASS "" || reg R6-no-legacy-setcrtc FAIL "$n occurrences"

# R7: the real commit is one ioctl attempt (source).
grep -q 'a_commit(g_fd, &a, plan\[ok\].modeset ? DRM_MODE_ATOMIC_ALLOW_MODESET : 0, 1)' "$SRC" \
    && reg R7-real-commit-no-retry PASS "" || reg R7-real-commit-no-retry FAIL "real commit goes through the 100-try wrapper"

# R8 (second review, should-fix 1+2): mode policy and empty values, same checks
# compiled against this source (tools/policy_harness.c).
ver=$(sed -n 's/^#define FSP_VERSION *"0\.\([0-9]\)".*/\1/p' "$SRC")
if [ "$ver" = 3 ] || [ "$ver" = 4 ]; then
    "$CLANG" --target=aarch64-linux-gnu -static -O2 -std=c11 -D_GNU_SOURCE -D__user= -I"$UAPI" \
        -DFSP_UNIT_TEST -DHV="$ver" "-DFSP_SRC=\"$SRC\"" -Wno-unused-function -Wno-unused-variable \
        -fuse-ld=lld -o "$W/harness" "$HERE/tools/policy_harness.c" 2> "$W/harness.err" \
        || { reg R8-policy-harness FAIL "compile: $(head -1 "$W/harness.err")"; ver=; }
    if [ -n "$ver" ]; then
        qemu-aarch64 "$W/harness" > "$W/harness.txt"; rc=$?
        cp "$W/harness.txt" "${OUT%.txt}-harness.txt"
        f=$(grep -c ' FAIL ' "$W/harness.txt")
        [ $rc = 0 ] && reg R8-policy-harness PASS "$(grep -c ' PASS ' "$W/harness.txt") checks" \
                    || reg R8-policy-harness FAIL "$f failed: $(grep ' FAIL ' "$W/harness.txt" | cut -d' ' -f2 | tr '\n' ' ')"
    fi
else
    reg R8-policy-harness N/A "only for v0.3/v0.4 sources"
fi

# R9 (nit 1): a non-DRM path is never opened: stat first (qemu -strace).
(cd "$W" && qemu-aarch64 -strace "$BIN" show a1b2c3d4 1 /dev/null > /dev/null 2> "$W/r9.strace"); rc=$?
if [ $rc = 11 ] && ! grep -q 'openat(AT_FDCWD,"/dev/null"' "$W/r9.strace"; then
    reg R9-stat-before-open PASS "exit=11, /dev/null never opened"
else
    reg R9-stat-before-open FAIL "exit=$rc; $(grep -o 'openat(AT_FDCWD,"/dev/null",[A-Z_|]*)' "$W/r9.strace" | head -1)"
fi

# R10 (nit 2): file-size limit -> EFBIG counted as dropped, not death by SIGXFSZ.
bash -c "ulimit -f 0; exec $Q holdtest a1b2c3d4 1 /dev/null > $W/r10.txt" 2>/dev/null; rc=$?
[ $rc = 0 ] && reg R10-sigxfsz-ignored PASS "exit=0 under ulimit -f 0" \
            || reg R10-sigxfsz-ignored FAIL "exit=$rc (153 = SIGXFSZ)"

# R11 (nit 3): close precedes the hold_end write after a SIGTERM too.
(cd "$W" && { qemu-aarch64 -strace "$BIN" holdtest a1b2c3d4 999 /dev/null > "$W/r11.txt" 2> "$W/r11.strace" & p=$!; sleep 2; kill -TERM $p; wait $p; })
close_first "$W/r11.strace" && grep -q 'reason=signal sig=15' "$W/r11.txt" \
    && reg R11-close-before-write-on-term PASS "strace order after SIGTERM" \
    || reg R11-close-before-write-on-term FAIL ""

# R12 (PM decision): compiled hold maximum is 10 s.
$Q holdtest a1b2c3d4 999 /dev/null > "$W/r12.txt" 2>&1 & p=$!
sleep 1; kill -TERM $p; wait $p
grep -q 'hold_req=999 hold=10 hold_max=10 clamped=1' "$W/r12.txt" && reg R12-hold-max-10s PASS "999 -> 10" \
    || reg R12-hold-max-10s FAIL "$(grep -o 'hold=[0-9]* hold_max=[0-9]*' "$W/r12.txt")"

wait $P1 $P2      # r1/r1b append their own REG lines to $OUT
