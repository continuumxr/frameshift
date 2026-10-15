#!/bin/bash
# FrameShift stage-2a — negative fixtures for elfpin.py check (FS-R-006 §3 lesson:
# a gate must actually reject). Run inside WSL after t1-qemu-fixture.sh has staged
# ~/work/t1pin/stage. Each case copies the good tree, breaks one thing, and
# requires `elfpin.py check` to exit non-zero. Prints PASS/FAIL per case.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PINS=$HERE/../T1-pins.json
GOOD=$HOME/work/t1pin/stage/valve
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
fresh() { rm -rf "$W/t"; cp -a "$GOOD" "$W/t"; }
expect_reject() {   # expect_reject <label>
  if python3 -I "$HERE/elfpin.py" check "$PINS" "$W/t" > "$W/o" 2>&1; then
    echo "FAIL (accepted): $1"; fails=$((fails+1))
  else
    echo "PASS (rejected): $1"; grep REFUSED "$W/o" | cut -c1-150 | sed "s/^/      /"
  fi
}
fresh; python3 -I "$HERE/elfpin.py" check "$PINS" "$W/t" >/dev/null && echo "PASS (accepted): unmodified tree" || { echo "FAIL: unmodified tree rejected"; fails=$((fails+1)); }

fresh; python3 -I - "$W/t/bin/uname" <<'PY'
import sys; p=sys.argv[1]; d=bytearray(open(p,'rb').read()); i=d.find(b"/lib/ld-linux-aarch64.so.1\0"); d[i+1:i+4]=b"LIB"; open(p,'wb').write(d)
PY
expect_reject "uname PT_INTERP altered (/LIB/...)"

fresh; printf '\0' >> "$W/t/bin/b2sum"; expect_reject "b2sum one byte appended"
fresh; python3 -I - "$W/t/lib/libc.so.6" <<'PY'
import sys; p=sys.argv[1]; d=bytearray(open(p,'rb').read()); d[-1]^=1; open(p,'wb').write(d)
PY
expect_reject "libc last byte flipped (size unchanged)"
fresh; rm "$W/t/lib/libc.so.6"; expect_reject "libc missing"
fresh; cp "$W/t/lib/libc.so.6" "$W/t/lib/libextra.so"; expect_reject "extra file in lib/"
fresh; mkdir -p "$W/t/lib/glibc-hwcaps"; touch "$W/t/lib/glibc-hwcaps/x"; expect_reject "extra subdirectory file"
fresh; mv "$W/t/bin/uname" "$W/t/bin/uname.real"; ln -s uname.real "$W/t/bin/uname"; expect_reject "uname replaced by a symlink"
fresh; chmod 0644 "$W/t/bin/b2sum"; expect_reject "b2sum not executable"
fresh; cp "$W/t/bin/b2sum" "$W/t/bin/uname"; expect_reject "uname replaced by b2sum"
echo "negative fixtures: $fails failure(s)"; exit $fails
