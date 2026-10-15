#!/bin/bash
# FrameShift stage-2a — offline qemu-user fixture for the T1 set (FS-R-006 §5 A).
# Run inside WSL: bash t1-qemu-fixture.sh <outdir>
#
# Stages the four pinned Valve files into a scratch tree $ST/valve/{bin,lib}
# OUTSIDE the repo, verifies them against T1-pins.json with elfpin.py, then runs
# them under qemu-aarch64 exactly as fs-valve will on the device:
#   env -i /valve/lib/ld-linux-aarch64.so.1 --inhibit-cache --library-path /valve/lib /valve/bin/<prog> ...
# `qemu-aarch64 -L $ST` makes guest absolute paths resolve inside $ST first
# (falling back to the host), so the guest sees the same /valve paths as the
# device. qemu itself must be handed the loader by its host path ($ST/valve/...);
# `-0 /valve/lib/ld-linux-aarch64.so.1` keeps the guest's argv[0] identical to
# the device. The host is checked to lack every fallback path the loader could use. qemu's -strace records every guest open/exec so we can show which
# files the loader actually opened. No device, no adb/fastboot, nothing installed.
set -u
OUT=${1:?usage: t1-qemu-fixture.sh <outdir>}
HERE=$(cd "$(dirname "$0")" && pwd)
PINS=$HERE/../T1-pins.json
SRC=$HOME/sfroot-full
ST=$HOME/work/t1pin/stage            # scratch only; holds Valve binaries; never in the repo
QEMU=$(command -v qemu-aarch64) || { echo "qemu-aarch64 absent"; exit 2; }
mkdir -p "$OUT"
LOG=$OUT/fixture-transcript.txt
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

say "# T1 qemu fixture  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "host: $(uname -srm)"
say "qemu: $QEMU  $($QEMU --version | head -1)"
say "qemu sha256: $(sha256sum "$QEMU" | cut -c1-64)"
say "binfmt_misc qemu-aarch64: $(head -1 /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || echo absent) (not used: qemu is invoked explicitly)"
for p in /lib/ld-linux-aarch64.so.1 /usr/lib/ld-linux-aarch64.so.1 /lib/libc.so.6 /usr/lib/libc.so.6 /etc/ld.so.preload /valve; do
  [ -e "$p" ] && say "HOST HAS $p (would be a fallback target!)" || say "host lacks $p (good)"
done

# --- stage --------------------------------------------------------------------
rm -rf "$ST"; mkdir -p "$ST/valve/bin" "$ST/valve/lib"
install -m 0755 "$SRC/usr/lib/ld-linux-aarch64.so.1" "$ST/valve/lib/ld-linux-aarch64.so.1"
install -m 0755 "$SRC/usr/lib/libc.so.6"             "$ST/valve/lib/libc.so.6"
install -m 0755 "$SRC/usr/bin/uname"                 "$ST/valve/bin/uname"
install -m 0755 "$SRC/usr/bin/b2sum"                 "$ST/valve/bin/b2sum"
say ""; say "## staged tree ($ST)"; (cd "$ST" && find . -printf '%M %s %p\n' | sort -k3) | tee -a "$LOG"
say ""; say "## pin check (elfpin.py check)"
python3 -I "$HERE/elfpin.py" check "$PINS" "$ST/valve" 2>&1 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" = 0 ] || { say "PIN CHECK FAILED - stopping"; exit 1; }

# --- run helper -----------------------------------------------------------------
# Child is launched with an EMPTY environment (env -i, no assignments), cwd /,
# absolute paths only. qemu's own QEMU_* variables are cleared by env -i too.
L=/valve/lib/ld-linux-aarch64.so.1
RUNL="$L --inhibit-cache --library-path /valve/lib"
n=0
run() {   # run <label> <stdin-file|-> <guest argv...>
  local label=$1 in=$2; shift 2; n=$((n+1))
  local o=$OUT/step$n.out e=$OUT/step$n.err s=$OUT/step$n.strace
  if [ "$in" = - ]; then in=/dev/null; fi
  local g=$1; shift   # guest program: qemu loads it from the host path $ST$g, argv[0] stays $g (-0)
  ( cd / && env -i "$QEMU" -L "$ST" -0 "$g" -strace -D "$s" "$ST$g" "$@" < "$in" > "$o" 2> "$e" ); local rc=$?
  set -- "$g" "$@"
  say ""; say "## step $n: $label"
  say "argv: $*"; say "stdin: $in ($(stat -c %s "$in") bytes)"; say "rc=$rc"
  say "stdout ($(stat -c %s "$o") bytes, sha256 $(sha256sum < "$o" | cut -c1-64)):"; sed 's/^/  | /' "$o" | tee -a "$LOG"
  [ -s "$e" ] && { say "stderr:"; sed 's/^/  ! /' "$e" | tee -a "$LOG"; }
  say "files the guest opened/exec'd (qemu -strace; result after '='):"
  grep -E '(openat|execve|readlink|access|faccessat|newfstatat|statx)\(' "$s" | sed -E 's/^[0-9]+ //' | sed 's/^/  > /' | tee -a "$LOG" >/dev/null
  grep -E '(openat|execve)\(' "$s" | grep -v ' = -1' | grep -oE '"/[^"]*"' | sort -u | sed 's/^/  opened-ok: /' | tee -a "$LOG"
}

# challenge inputs, byte-exact (written with printf, no locale involvement)
IN=$OUT/inputs; mkdir -p "$IN"
printf ''                                   > "$IN/empty.bin"
printf '%s' 'fs-7c1e09d2a4b85f36:9f2b4c6d1e8a7035b1d9c4e2f6a80317' > "$IN/challenge-nonl.bin"
printf '%s\n' 'fs-7c1e09d2a4b85f36:9f2b4c6d1e8a7035b1d9c4e2f6a80317' > "$IN/challenge-nl.bin"
say ""; say "## inputs (hex)"
for f in empty challenge-nonl challenge-nl; do say "$f.bin: $(stat -c %s "$IN/$f.bin") bytes: $(od -An -tx1 -v "$IN/$f.bin" | tr -d ' \n')"; done
say "host b2sum ($(b2sum --version | head -1), x86_64, independent implementation):"
for f in empty challenge-nonl challenge-nl; do say "  $f: $(b2sum < "$IN/$f.bin")"; done
say "host python hashlib.blake2b (independent):"
for f in empty challenge-nonl challenge-nl; do say "  $f: $(python3 -I -c 'import hashlib,sys;print(hashlib.blake2b(open(sys.argv[1],"rb").read()).hexdigest())' "$IN/$f.bin")"; done

# --- the §5.2 steps ---------------------------------------------------------------
run "ld.so --list-diagnostics"                 - $L --list-diagnostics
run "ld.so --list b2sum"                       - $RUNL --list /valve/bin/b2sum
run "ld.so --list uname"                       - $RUNL --list /valve/bin/uname
run "uname -r"                                 - $RUNL /valve/bin/uname -r
run "uname -a"                                 - $RUNL /valve/bin/uname -a
run "b2sum --version"                          - $RUNL /valve/bin/b2sum --version
run "b2sum empty (stdin)"                      "$IN/empty.bin"          $RUNL /valve/bin/b2sum
run "b2sum challenge, no trailing newline"     "$IN/challenge-nonl.bin" $RUNL /valve/bin/b2sum
run "b2sum challenge, trailing newline"        "$IN/challenge-nl.bin"   $RUNL /valve/bin/b2sum
run "b2sum -l 512 empty (explicit length)"     "$IN/empty.bin"          $RUNL /valve/bin/b2sum -l 512

# --- negative controls ----------------------------------------------------------
say ""; say "# NEGATIVE CONTROLS (each must fail or show the stated effect)"
run "NEG: b2sum exec'd directly (kernel PT_INTERP /lib/ld-linux-aarch64.so.1 absent)" - /valve/bin/b2sum
run "NEG: without --library-path (default search /usr/lib, /lib; libc absent there)" - $L --inhibit-cache /valve/bin/uname -r
mv "$ST/valve/lib/libc.so.6" "$ST/libc.so.6.hidden"
run "NEG: libc.so.6 removed from /valve/lib (must not resolve anywhere else)"   - $RUNL /valve/bin/uname -r
mv "$ST/libc.so.6.hidden" "$ST/valve/lib/libc.so.6"
# A loader-affecting variable IS honoured when present: proves why env -i matters.
( cd / && env -i LD_LIBRARY_PATH=/nonexistent-a LD_DEBUG=libs "$QEMU" -L "$ST" -0 $L "$ST$L" --inhibit-cache --library-path /valve/lib /valve/bin/uname -r > "$OUT/neg-env.out" 2> "$OUT/neg-env.err" ); rc=$?
say ""; say "## NEG: LD_DEBUG=libs + LD_LIBRARY_PATH set (shows the loader reads them; why env -i is mandatory) rc=$rc"
sed 's/^/  ! /' "$OUT/neg-env.err" | sed -E 's/^(  ! )[[:space:]]*[0-9]+:/\1PID:/' | tee -a "$LOG"
say "stdout:"; sed 's/^/  | /' "$OUT/neg-env.out" | tee -a "$LOG"

( cd / && env -i LD_PRELOAD=/valve/lib/not-there.so "$QEMU" -L "$ST" -0 $L "$ST$L" --inhibit-cache --library-path /valve/lib /valve/bin/uname -r > "$OUT/neg-preload.out" 2> "$OUT/neg-preload.err" ); rc=$?
say ""; say "## NEG: LD_PRELOAD set (--library-path does not neutralise it; the loader tries to preload) rc=$rc"
sed 's/^/  ! /' "$OUT/neg-preload.err" | tee -a "$LOG"
say "stdout:"; sed 's/^/  | /' "$OUT/neg-preload.out" | tee -a "$LOG"

# The --list interpreter line's left-hand side is the program's own PT_INTERP string
# (rtld names its map after it), so on the device it witnesses the interpreter line.
mkdir -p "$ST/valve/tmp" && cp "$ST/valve/bin/uname" "$ST/valve/tmp/uname-x"
python3 -I -c 'import sys; p=sys.argv[1]; d=bytearray(open(p,"rb").read()); i=d.find(b"/lib/ld-linux-aarch64.so.1"+bytes(1)); d[i+1:i+4]=b"XYZ"; open(p,"wb").write(d)' "$ST/valve/tmp/uname-x"
run "CONTROL: --list of a uname copy whose PT_INTERP was patched to /XYZ/... (LHS must change)" - $RUNL --list /valve/tmp/uname-x
rm -rf "$ST/valve/tmp"

# --- env -i really empties the environment ---------------------------------------
say ""; say "## env -i check: environment seen by a child of env -i"
say "bytes printed by 'env -i /usr/bin/env': $(env -i /usr/bin/env | wc -c)"
say ""; say "# done"
