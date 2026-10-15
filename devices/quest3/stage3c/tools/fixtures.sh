#!/bin/bash
# FrameShift stage 3c — offline fixtures for fs-pattern v0.6 (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/stage3c/tools/fixtures.sh
# Derived from stage3b/tools/fixtures.sh (v0.5, unchanged); every v0.5 check is kept (unit tests,
# render, refusals, stdout contract, strace close-before-write, signals, clamp, backstop, framing of
# every stream), plus the v0.6 checks at the end (DESIGN.md §12.3): show-off-quad/show-off-solid
# refusals, the property logging against the mock model, the WHOLE show path against the mock DRM
# device (plane selection, attempt order, split probe never committed, zpos {0,0,1,1}, post_state /
# post_plane with the converted CRTC_X, stream bounds), the static checks against v0.5, the v0.6
# picture (quadrant map, centre line, white/mean envelope incl. the worst-case nonce bbbbbbbb), the
# solid red field, the preview port byte for byte, and the previews for the PM.
# Runs the exact aarch64 build/fs-pattern (and the -DFSP_UNIT_TEST build) under qemu-aarch64
# (user mode). No DRM device exists here; "show*" is only exercised on absent/non-DRM paths (and
# against the unit-test build's mock device), and "holdtest" uses /dev/null as the mock card0.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest3/stage3c
S3B="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest3/stage3b
S3A="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"/devices/quest3/stage3a
PREV=$HERE/fixtures/preview
BIN=$HERE/build/fs-pattern
UT=$HERE/build/fs-pattern-unittest
FX=$HERE/fixtures
SUM=$FX/RESULTS.txt
# refuse BEFORE touching any result file
[ -e /dev/dri ] && { echo "REFUSED: /dev/dri exists on this host" >&2; exit 1; }
W=$(mktemp -d)
trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$FX" "$FX/sim" "$PREV"
find "$FX" -maxdepth 1 \( -name '*.txt' -o -name '*.log' \) ! -name 'regress-*' ! -name 'encode-timing.txt' ! -name 'dmesg-timing.txt' \
    ! -name 'check-timing-3c.txt' -delete   # stale outputs (the timing outputs of the other tools are kept)
find "$FX/sim" "$PREV" -maxdepth 1 -type f -delete
Q="qemu-aarch64 $BIN"
: > "$SUM"
fails=0

res() {  # res <name> <PASS|FAIL> <detail>
    echo "$1 $2 $3" | tee -a "$SUM"
    [ "$2" = PASS ] || fails=$((fails + 1))
}
ms() { echo $(( $(date +%s%N) / 1000000 )); }
# the verdict of a "CHECK <name...> PASS|FAIL [detail]" line is its FIRST standalone PASS/FAIL field (build review NIT:
# a plain grep counted substrings such as EX_COMMITFAIL inside a detail)
npass() { awk '/^CHECK /{for(i=2;i<=NF;i++) if($i=="PASS"||$i=="FAIL"){if($i=="PASS")n++; break}} END{print n+0}' "$1"; }
lfail() { awk '/^CHECK /{for(i=2;i<=NF;i++) if($i=="PASS"||$i=="FAIL"){if($i=="FAIL")print; break}}' "$1"; }
run() {  # run <name> <expected exit> <cmd...>: output to fixtures/<name>.txt
    local name=$1 want=$2; shift 2
    "$@" > "$FX/$name.txt" 2>&1; local rc=$?
    echo "# exit=$rc" >> "$FX/$name.txt"
    if [ "$rc" = "$want" ]; then res "$name" PASS "exit=$rc"; else res "$name" FAIL "exit=$rc want=$want"; fi
}
stream() {  # stream <expect> <file>: framing/len/crc/seq/eos check
    local out; out=$(python3 -I "$HERE/tools/check_stream.py" --expect "$1" "$2"); local rc=$?
    local n; n=$(basename "$2" .txt)
    [ $rc = 0 ] && res "stream_$n" PASS "$(echo "$out" | cut -d' ' -f3-)" \
                || res "stream_$n" FAIL "$(echo "$out" | cut -d' ' -f3-) (expected $1)"
}

echo "binary sha256=$(sha256sum "$BIN" | cut -c1-64)" | tee -a "$SUM"
echo "unittest sha256=$(sha256sum "$UT" | cut -c1-64)" | tee -a "$SUM"
echo "qemu: $(qemu-aarch64 --version | head -1)" | tee -a "$SUM"

# --- long-running checks first, in the background ----------------------------
# full clamp: 999 s requested -> held exactly to the 10 s compiled max
( t0=$(ms); $Q holdtest c1a2b3c4 999 /dev/null > "$FX/hold-clamp-full.txt" 2>&1; rc=$?
  echo "# exit=$rc wall_ms=$(( $(ms) - t0 ))" >> "$FX/hold-clamp-full.txt" ) &
P_CLAMP=$!
# backstop: SIGSTOP during the hold, SIGCONT at 18 s, after the alarm due at hold+5 = 15 s -> SIGALRM (142)
( $Q holdtest b0b0b0b0 999 /dev/null > "$FX/backstop.txt" 2>&1 & p=$!
  sleep 2; kill -STOP $p; sleep 16; tc=$(ms); kill -CONT $p; wait $p; rc=$?; td=$(ms)
  echo "# exit=$rc died_ms_after_sigcont=$(( td - tc ))" >> "$FX/backstop.txt" ) 2>/dev/null &
P_BACK=$!

# --- unit tests (v0.5's plus the v0.6 selection, zpos, budgets, caps parse, solid word) ---
qemu-aarch64 "$UT" > "$FX/unittest.txt" 2>&1; rc=$?
echo "# exit=$rc" >> "$FX/unittest.txt"
[ $rc = 0 ] && res unittest PASS "$(grep -c ' PASS$' "$FX/unittest.txt") unit tests" \
            || res unittest FAIL "$(grep ' FAIL$' "$FX/unittest.txt" | tr '\n' ' ')"

# --- (a) render -----------------------------------------------------------------
for n in 3f9c07ab 01234567 89abcdef; do
    run "render-$n" 0 $Q render $n 4128 2208 "$W/$n.ppm"
    python3 -I "$HERE/tools/check_render.py" "$W/$n.ppm" $n "$FX" "preview-$n" > "$FX/check-$n.log" 2>&1
    rc=$?
    [ $rc = 0 ] && res "check-$n" PASS "$(npass "$FX/check-$n.log") checks" \
                || res "check-$n" FAIL "$(lfail "$FX/check-$n.log" | head -3 | tr '\n' ' ')"
done
rm -f "${FX:?}"/preview-01234567-scanout.png "${FX:?}"/preview-89abcdef-scanout.png "${FX:?}"/preview-01234567-viewer.png "${FX:?}"/preview-89abcdef-viewer.png
$Q render 3f9c07ab 4128 2208 "$W/again.ppm" > /dev/null
cmp -s "$W/3f9c07ab.ppm" "$W/again.ppm" && res render-deterministic PASS "identical bytes" || res render-deterministic FAIL ""
cmp -s "$W/3f9c07ab.ppm" "$W/01234567.ppm" && res render-nonce-differs FAIL "" || res render-nonce-differs PASS ""
echo "render 3f9c07ab ppm sha256=$(sha256sum "$W/3f9c07ab.ppm" | cut -c1-64)" | tee -a "$SUM"
run render-odd-size 0 $Q render 3f9c07ab 1552 1664 "$W/odd.ppm"

# --- (b) no device / not a DRM device -----------------------------------------------
run nodev-default 10 $Q show 3f9c07ab 5
grep -q 'step=open rc=-2 errno=2 dev=/dev/dri/card0 at=stat len=' "$FX/nodev-default.txt" \
    && res nodev-default-record PASS "open rc=-2 ENOENT" || res nodev-default-record FAIL ""
grep -q 'step=exit rc=0 code=10 reason=no_device shown=0' "$FX/nodev-default.txt" \
    && res nodev-default-exit PASS "" || res nodev-default-exit FAIL ""
run nodev-path 10 $Q show 3f9c07ab 5 /nonexistent/card0
echo plain > "$W/regular"
run notdrm-regular 11 $Q show 3f9c07ab 5 "$W/regular"
run notdrm-devnull 11 $Q show 3f9c07ab 5 /dev/null
grep -q 'error=not_drm_chardev' "$FX/notdrm-devnull.txt" && res notdrm-devnull-record PASS "" || res notdrm-devnull-record FAIL ""

# --- usage -----------------------------------------------------------------------------
run usage-noargs 2 $Q
run usage-upper-nonce 2 $Q show DEADBEEF 5
run usage-short-nonce 2 $Q show abc 5
run usage-hold-zero 2 $Q show 3f9c07ab 0
run usage-hold-nondigit 2 $Q show 3f9c07ab 1e3
run usage-hold-7digits 2 $Q show 3f9c07ab 1000000
run usage-extra-arg 2 $Q holdtest 3f9c07ab 5 /dev/null extra
run usage-path-201 2 $Q show 3f9c07ab 5 "/$(head -c 200 /dev/zero | tr '\0' x)"

# --- stdout contract ----------------------------------------------------------------------
script -qec "$Q holdtest a1b2c3d4 1 /dev/null" /dev/null > "$FX/stdout-tty.txt" 2>&1; rc=$?
echo "# exit=$rc" >> "$FX/stdout-tty.txt"
[ $rc = 3 ] && ! grep -q FSP1 "$FX/stdout-tty.txt" && res stdout-tty-refused PASS "exit=3, nothing written" \
                                                   || res stdout-tty-refused FAIL "exit=$rc"
$Q holdtest a1b2c3d4 1 /dev/null > /dev/null; rc=$?
[ $rc = 0 ] && res stdout-devnull-accepted PASS "exit=0" || res stdout-devnull-accepted FAIL "exit=$rc"
$Q holdtest a1b2c3d4 1 /dev/null | cat > "$FX/stdout-pipe.txt"; rc=${PIPESTATUS[0]}
echo "# exit=$rc" >> "$FX/stdout-pipe.txt"
grep -q 'step=start .* out=pipe ' "$FX/stdout-pipe.txt" && [ $rc = 0 ] && res stdout-pipe-accepted PASS "out=pipe" \
                                                         || res stdout-pipe-accepted FAIL "exit=$rc"
# blocked stdout (reviewer's blockedout.sh, equivalent): full FIFO nobody drains
F=$W/fifo; mkfifo "$F"; exec 3<>"$F"; head -c 65536 /dev/zero >&3
t0=$(ms); $Q holdtest a1b2c3d4 3 /dev/null >&3 2>/dev/null; rc=$?; dt=$(( $(ms) - t0 ))
[ $rc = 0 ] && [ $dt -lt 4500 ] && res blocked-stdout-hold PASS "exit=0 wall_ms=$dt (hold 3 s; records dropped, not waited for)" \
                                || res blocked-stdout-hold FAIL "exit=$rc wall_ms=$dt"
$Q holdtest a1b2c3d4 999 /dev/null >&3 2>/dev/null & p=$!
sleep 2; t1=$(ms); kill -TERM $p; wait $p; rc=$?; dt=$(( $(ms) - t1 ))
[ $rc = 70 ] && [ $dt -lt 1000 ] && res blocked-stdout-term PASS "exit=70 term_to_exit_ms=$dt" \
                                 || res blocked-stdout-term FAIL "exit=$rc term_to_exit_ms=$dt"
exec 3>&-

# --- (c) hold, clamp, signals (mock card0 = /dev/null) ------------------------------------
t0=$(ms); run hold-3s 0 $Q holdtest a1b2c3d4 3 /dev/null; dt=$(( $(ms) - t0 ))
held=$(sed -n 's/.*step=hold_end .*held_ms=\([0-9]*\).*/\1/p' "$FX/hold-3s.txt")
[ -n "$held" ] && [ "$held" -ge 3000 ] && [ "$held" -lt 3100 ] && res hold-3s-duration PASS "held_ms=$held wall_ms=$dt" \
    || res hold-3s-duration FAIL "held_ms=$held wall_ms=$dt"
# syscall order, not the program's own claim: after the last rt_sigtimedwait,
# close(3) must precede the next write(1,...) (the hold_end record)
close_first() { awk '/rt_sigtimedwait\(/{s=NR; c=0; w=0} s && !c && /close\(3\)/{c=NR} s && !w && / write\(1,/{w=NR} END{exit !(s && c && (!w || c < w))}' "$1"; }
(cd "$W" && qemu-aarch64 -strace "$BIN" holdtest a1b2c3d4 1 /dev/null > "$FX/strace-hold.txt" 2> "$FX/strace-hold.log")
close_first "$FX/strace-hold.log" && res strace-close-before-write PASS "deadline: close(3) precedes write(1)" \
    || res strace-close-before-write FAIL ""
(cd "$W" && { qemu-aarch64 -strace "$BIN" holdtest a1b2c3d4 999 /dev/null > "$FX/strace-term.txt" 2> "$FX/strace-term.log" & p=$!; sleep 2; kill -TERM $p; wait $p; })
close_first "$FX/strace-term.log" && grep -q 'reason=signal sig=15' "$FX/strace-term.txt" \
    && res strace-close-before-write-term PASS "SIGTERM: close(3) precedes write(1)" || res strace-close-before-write-term FAIL ""
# stat before open: a non-DRM path is never opened (show and holdtest)
(cd "$W" && qemu-aarch64 -strace "$BIN" show a1b2c3d4 1 /dev/null > "$FX/strace-notdrm.txt" 2> "$FX/strace-notdrm.log"); rc=$?
[ $rc = 11 ] && grep -q 'newfstatat(AT_FDCWD,"/dev/null"' "$FX/strace-notdrm.log" && ! grep -q 'openat(AT_FDCWD,"/dev/null"' "$FX/strace-notdrm.log" \
    && res strace-show-stat-not-open PASS "exit=11; stat only, never opened" || res strace-show-stat-not-open FAIL "exit=$rc"
grep -q 'openat(AT_FDCWD,"/dev/null",O_RDONLY|O_NOCTTY|O_CLOEXEC)' "$FX/strace-hold.log" \
    && awk '/newfstatat\(AT_FDCWD,"\/dev\/null"/{s=NR} /openat\(AT_FDCWD,"\/dev\/null"/{o=NR} END{exit !(s && o && s < o)}' "$FX/strace-hold.log" \
    && res strace-holdtest-stat-then-open PASS "stat precedes open; O_NOCTTY" || res strace-holdtest-stat-then-open FAIL ""
# file-size limit: EFBIG counted as dropped instead of death by SIGXFSZ
bash -c "ulimit -f 0; exec $Q holdtest a1b2c3d4 1 /dev/null > $W/xfsz.txt" 2>/dev/null; rc=$?
[ $rc = 0 ] && res sigxfsz-ignored PASS "exit=0 under ulimit -f 0 (records dropped)" || res sigxfsz-ignored FAIL "exit=$rc"
# empty values: v0.4 writes "-"; the v0.3-format record (reviewer repro) stays INVALID
qemu-aarch64 "$UT" stream > "$FX/stream-sample.txt"
grep -q ' name=- ' "$FX/stream-sample.txt" && grep -q ' drv=- ' "$FX/stream-sample.txt" && grep -q ' dash=%2D ' "$FX/stream-sample.txt" \
    && res empty-value-token PASS "name=- drv=- dash=%2D" || res empty-value-token FAIL ""
grep -q 'step=hold_start .*alarm_s=8 ' "$FX/hold-3s.txt" && res hold-alarm-rearmed PASS "alarm_s=8 (hold 3 + 5)" \
    || res hold-alarm-rearmed FAIL ""
# re-armed alarm actually fires: hold 3, STOP at 1 s, CONT at 10 s -> 142
$Q holdtest a1b2c3d4 3 /dev/null > "$FX/alarm-rearm.txt" 2>&1 & p=$!
sleep 1; kill -STOP $p; sleep 9; kill -CONT $p; wait $p 2>/dev/null; rc=$?
echo "# exit=$rc" >> "$FX/alarm-rearm.txt"
[ $rc = 142 ] && res alarm-rearm-fires PASS "SIGALRM at hold+5" || res alarm-rearm-fires FAIL "exit=$rc"

sigtest() {  # sigtest <name> <signal> <num> <prefix-cmd...>
    local name=$1 sig=$2 num=$3; shift 3
    "$@" $Q holdtest d4c3b2a1 999 /dev/null > "$FX/$name.txt" 2>&1 & local p=$!
    sleep 2
    local t1; t1=$(ms); kill -"$sig" $p; wait $p; local rc=$?; local dt=$(( $(ms) - t1 ))
    echo "# exit=$rc signal_to_exit_ms=$dt" >> "$FX/$name.txt"
    grep -q 'step=start rc=0 mode=holdtest ver=0.6 hold_req=999 hold=10 hold_max=10 clamped=1' "$FX/$name.txt" \
        && res "$name-clamp-reported" PASS "999 -> 10" || res "$name-clamp-reported" FAIL ""
    if [ $rc = 70 ] && [ $dt -lt 1000 ] && grep -q "reason=signal sig=$num " "$FX/$name.txt"; then
        res "$name" PASS "exit=70 sig=$num signal_to_exit_ms=$dt"
    else
        res "$name" FAIL "exit=$rc signal_to_exit_ms=$dt"
    fi
}
sigtest sigterm TERM 15 env
sigtest sigint INT 2 env
sigtest sighup HUP 1 env
sigtest sigint-parent-ignored INT 2 bash -c 'trap "" INT; exec "$@"' x

# --- wait for the long checks ---------------------------------------------------------------
wait $P_CLAMP
grep -q 'hold_req=999 hold=10 hold_max=10 clamped=1' "$FX/hold-clamp-full.txt" && res hold-clamp-full-start PASS "" || res hold-clamp-full-start FAIL ""
held=$(sed -n 's/.*step=hold_end rc=0 reason=deadline .*held_ms=\([0-9]*\).*/\1/p' "$FX/hold-clamp-full.txt")
ex=$(sed -n 's/^# exit=\([0-9]*\).*/\1/p' "$FX/hold-clamp-full.txt")
[ "$ex" = 0 ] && [ -n "$held" ] && [ "$held" -ge 10000 ] && [ "$held" -lt 10200 ] \
    && res hold-clamp-full PASS "exit=0 held_ms=$held (999 requested; alarm at 15 s not reached)" || res hold-clamp-full FAIL "exit=$ex held_ms=$held"
wait $P_BACK
ex=$(sed -n 's/^# exit=\([0-9]*\).*/\1/p' "$FX/backstop.txt")
dk=$(sed -n 's/^# exit=[0-9]* died_ms_after_sigcont=\([0-9]*\).*/\1/p' "$FX/backstop.txt")
if [ "$ex" = 142 ] && ! grep -q 'step=hold_end' "$FX/backstop.txt" && [ -n "$dk" ] && [ "$dk" -lt 1000 ]; then
    res backstop PASS "SIGALRM (142), no hold_end; alarm due at 15 s, kill landed ${dk} ms after SIGCONT at 18 s (a stopped process can only die on SIGCONT)"
else
    res backstop FAIL "exit=$ex"
fi

# --- framing of EVERY fixture stream ----------------------------------------------------------
for f in "$FX"/*.txt; do
    case $(basename "$f") in
        RESULTS.txt|unittest.txt|regress-*.txt|stream-neg-*.txt) continue ;;
        encode-timing.txt|dmesg-timing.txt|check-timing-3c.txt) continue ;;   # the other tools' reports (kept above), not FSP1 streams
        backstop.txt|alarm-rearm.txt) stream incomplete "$f" ;;   # killed by SIGALRM: no eos, by design
        stdout-tty.txt) stream empty "$f" ;;                      # refused: nothing written
        *) stream complete "$f" ;;
    esac
done
# negative stream fixtures: the validator must reject tampering
src=$FX/hold-3s.txt
sed '3d' "$src" > "$FX/stream-neg-gap.txt"                         # a middle record lost
grep -v 'step=eos' "$src" > "$FX/stream-neg-noeos.txt"             # tail lost
sed '2s/rc=0/rc=1/' "$src" > "$FX/stream-neg-crc.txt"               # one byte changed
python3 -I "$HERE/tools/check_stream.py" --expect invalid "$FX/stream-neg-gap.txt" > /dev/null \
    && res stream-neg-gap PASS "seq gap -> INVALID" || res stream-neg-gap FAIL ""
python3 -I "$HERE/tools/check_stream.py" --expect incomplete "$FX/stream-neg-noeos.txt" > /dev/null \
    && res stream-neg-noeos PASS "no eos -> INCOMPLETE" || res stream-neg-noeos FAIL ""
python3 -I "$HERE/tools/check_stream.py" --expect invalid "$FX/stream-neg-crc.txt" > /dev/null \
    && res stream-neg-crc PASS "changed byte -> INVALID (crc)" || res stream-neg-crc FAIL ""
python3 -I "$HERE/tools/check_stream.py" --expect invalid "$S3A/fixtures/input/emptyval-v0.3.txt" > /dev/null \
    && res stream-neg-emptyval-v0.3 PASS "v0.3 empty value (name=) -> INVALID; v0.6 writes name=- (stream_stream-sample)" \
    || res stream-neg-emptyval-v0.3 FAIL ""

# ================= v0.6 additions (DESIGN.md §6, §12.3) ==========================================
# (d) the new modes on no device / non-DRM paths: the same refusals as show
run showquad-nodev 10 $Q show-off-quad 3f9c07ab 10
grep -q 'step=start rc=0 mode=show-off-quad ver=0.6 hold_req=10 hold=10' "$FX/showquad-nodev.txt" && grep -q 'step=exit rc=0 code=10 reason=no_device shown=0' "$FX/showquad-nodev.txt" \
    && res showquad-nodev-records PASS "mode=show-off-quad ver=0.6; exit 10" || res showquad-nodev-records FAIL ""
run showsolid-nodev 10 $Q show-off-solid 3f9c07ab 5
grep -q 'step=start rc=0 mode=show-off-solid ver=0.6 hold_req=5 hold=5' "$FX/showsolid-nodev.txt" && res showsolid-nodev-records PASS "mode=show-off-solid; exit 10" || res showsolid-nodev-records FAIL ""
run showquad-notdrm 11 $Q show-off-quad 3f9c07ab 3 /dev/null
run showsolid-notdrm 11 $Q show-off-solid 3f9c07ab 3 /dev/null
run showoff-v05-nodev 10 $Q show-off 3f9c07ab 10
run usage-quad-extra 2 $Q show-off-quad 3f9c07ab 3 /dev/null extra
run usage-solid-hold-zero 2 $Q show-off-solid 3f9c07ab 0
run usage-show-other 2 $Q show-off-quads 3f9c07ab 3
run usage-render-solid-args 2 $Q render-solid 3f9c07ab 4128 2208
# (e) the start-of-run logging against the mock model (unit-test build): framing + round trip
for v in full off quad solid repeat; do
    qemu-aarch64 "$UT" propsim $v > "$FX/propsim-$v.txt" 2>&1; rc=$?
    python3 -I -B "$HERE/tools/check_propsim.py" propsim $v "$FX/propsim-$v.txt" > "$FX/check-propsim-$v.log" 2>&1
    if [ $? = 0 ] && [ $rc = 0 ]; then res "propsim-$v" PASS "$(npass "$FX/check-propsim-$v.log") checks; $(wc -c < "$FX/propsim-$v.txt") bytes"
    else res "propsim-$v" FAIL "$(lfail "$FX/check-propsim-$v.log" | head -3 | tr '\n' ' ')"; fi
done
# (f) the WHOLE show path against the mock DRM device (stream on stdout, the mock's atomic log on stderr)
for s in show-run1 off-v05 quad-vig quad-dma quad-reject quad-active quad-vig2dup quad-vig2up3 quad-vig2upnone quad-dmadup \
         quad-vig1other quad-capsmissing quad-noconv quad-max show-max solid solid-max blob-8193; do
    qemu-aarch64 "$UT" sim $s > "$FX/sim/$s.txt" 2> "$FX/sim/$s.mock.log"; rc=$?
    python3 -I -B "$HERE/tools/check_propsim.py" sim $s "$FX/sim/$s.txt" "$FX/sim/$s.mock.log" > "$FX/sim/$s.check.log" 2>&1
    if [ $? = 0 ]; then res "sim-$s" PASS "exit=$rc; $(npass "$FX/sim/$s.check.log") checks; $(wc -c < "$FX/sim/$s.txt") bytes; $(grep -o 'essential_bytes=[0-9]* opt_bytes=[0-9]*' "$FX/sim/$s.check.log")"
    else res "sim-$s" FAIL "exit=$rc $(lfail "$FX/sim/$s.check.log" | head -3 | tr '\n' ' ')"; fi
    python3 -I "$HERE/tools/check_stream.py" --expect complete "$FX/sim/$s.txt" > /dev/null || res "stream_sim-$s" FAIL "not COMPLETE"
done
# (g) static: against the v0.5 source (DESIGN §6.2, §12.3)
python3 -I -B "$HERE/tools/check_static.py" "$HERE/src/fs-pattern.c" "$S3B/src/fs-pattern.c" > "$FX/check-static.log" 2>&1
[ $? = 0 ] && res static-v06 PASS "$(npass "$FX/check-static.log") checks (hold/request builder identical to v0.5, no new ioctl, a_prop set = v0.5 + zpos only in a_plane_z with FSP_QUAD_Z = {0,0,1,1}, never-set names read-only, no sysfs/debugfs path, no new exit code)" \
           || res static-v06 FAIL "$(lfail "$FX/check-static.log" | head -3 | tr '\n' ' ')"
# (h) the v0.6 picture, independently checked; the stdlib preview port validated byte for byte
for n in 3f9c07ab 01234567 89abcdef 4e0addd8 bbbbbbbb; do
    $Q render $n 4128 2208 "$W/v6-$n.ppm" > "$FX/render-v06-$n.txt" 2>&1
    python3 -I -B "$HERE/tools/check_render.py" "$W/v6-$n.ppm" $n "$W" "chk-$n" > "$FX/check-v06-$n.log" 2>&1
    if [ $? = 0 ]; then res "check-v06-$n" PASS "$(npass "$FX/check-v06-$n.log") checks; $(grep -o 'white_ppm=[0-9]* mean_x1000=[0-9]*' "$FX/check-v06-$n.log")"
    else res "check-v06-$n" FAIL "$(lfail "$FX/check-v06-$n.log" | head -3 | tr '\n' ' ')"; fi
    python3 -I -B "$HERE/tools/preview.py" $n "$W" "pv-$n" --against "$W/v6-$n.ppm" > "$FX/preview-$n.log" 2>&1
    grep -q 'IDENTICAL' "$FX/preview-$n.log" && res "preview-port-$n" PASS "Python port == C render, byte for byte" || res "preview-port-$n" FAIL ""
done
wp=$(sed -n 's/.* lit_ppm=\([0-9]*\) .*/\1/p' "$FX/render-v06-bbbbbbbb.txt"); mn=$(sed -n 's/.* mean_x1000=\([0-9]*\) .*/\1/p' "$FX/render-v06-bbbbbbbb.txt")
[ -n "$wp" ] && [ "$wp" -le 37618 ] && [ "$mn" -le 132777 ] && res render-worst-case-envelope PASS "bbbbbbbb (most white of any nonce): white_ppm=$wp <= 37618, mean_x1000=$mn <= 132777 (v0.5 4e0addd8: 37618 / 132777)" \
    || res render-worst-case-envelope FAIL "white_ppm=$wp mean=$mn"
$Q render-solid 00000000 4128 2208 "$W/solid.ppm" > "$FX/render-solid.txt" 2>&1; rc=$?
python3 -I -B "$HERE/tools/check_render.py" "$W/solid.ppm" 00000000 "$W" chk-solid --solid > "$FX/check-solid.log" 2>&1
[ $? = 0 ] && [ $rc = 0 ] && grep -q 'solid_words=9114624 ' "$FX/render-solid.txt" && res render-solid PASS "every pixel R=255 G=0 B=0; every word 0x00FF0000 (solid_words=9114624)" || res render-solid FAIL "rc=$rc"
python3 -I -B "$HERE/tools/preview.py" --solid "$W" pv-solid --against "$W/solid.ppm" > "$FX/preview-solid.log" 2>&1
grep -q 'IDENTICAL' "$FX/preview-solid.log" && res preview-port-solid PASS "port == C render-solid" || res preview-port-solid FAIL ""
$Q render 3f9c07ab 4128 2208 "$W/again6.ppm" > /dev/null
cmp -s "$W/v6-3f9c07ab.ppm" "$W/again6.ppm" && res render-v06-deterministic PASS "identical bytes" || res render-v06-deterministic FAIL ""
# the previews for the PM (DESIGN §13 A): the pattern (viewer, scanout, mixer map, digits), the F reference sheet, the red field
if python3 -I -B "$HERE/tools/preview.py" 3f9c07ab "$PREV" pattern-v0.6-3f9c07ab --against "$W/v6-3f9c07ab.ppm" > "$PREV/PREVIEWS.txt" 2>&1 \
   && python3 -I -B "$HERE/tools/preview.py" --fref "$PREV" F-reference-u-i-m-v >> "$PREV/PREVIEWS.txt" 2>&1 \
   && python3 -I -B "$HERE/tools/preview.py" --solid "$PREV" solid-red-v0.6 --against "$W/solid.ppm" >> "$PREV/PREVIEWS.txt" 2>&1; then
    res previews PASS "fixtures/preview/: pattern-v0.6-3f9c07ab-{viewer,scanout,mixermap,digits-left}, F-reference-u-i-m-v, solid-red-v0.6-viewer"
else res previews FAIL ""; fi
cmp -s "$W/v6-3f9c07ab.ppm" "$W/3f9c07ab.ppm" && res v06-is-the-render-checked-above PASS "section (a) renders are v0.6 too" || res v06-is-the-render-checked-above FAIL ""

echo "TOTAL failures=$fails" | tee -a "$SUM"
exit $fails
