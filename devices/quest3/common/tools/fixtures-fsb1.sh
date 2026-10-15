#!/bin/bash
# FrameShift common — FSB1 fixtures (run inside WSL):
#   wsl.exe -e bash <repo>/devices/quest3/common/tools/fixtures-fsb1.sh
# 1. Builds a real record with the target encoder (target/fsb1-enc.sh) run by
#    the REVIEWED stage-1 busybox under qemu-aarch64, with every step run by
#    build/fs-supervise (aarch64). Payload hashes are taken from the raw
#    capture files with the host's sha256sum, independently of the encoder.
# 2. Passes the record through a real pty (ONLCR on) to get genuine tty CRLF.
# 3. Optional: a record of the four pinned Valve T1 files under qemu, if the
#    WSL-only stage ~/work/t1pin/stage exists (nothing Valve is copied into
#    the repo; only their text output appears in the fixture).
# 4. Derives the negative fixtures (tools/fsb1_mutate.py) and runs the Python
#    decoder over all cases. The PowerShell twin runs on Windows:
#    powershell.exe -NoProfile -File devices\quest3\common\host\test-fsb1.ps1
# Touches no device.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"
HERE=$ROOT/devices/quest3/common
FX=${OUT:-$HERE/fixtures/fsb1}   # OUT=<dir>: write results elsewhere (default: the tracked fixture dir)
BB_SRC=$ROOT/build/third_party/busybox/busybox
VS=$HOME/work/t1pin/stage/valve
NONCE=5e1f0c3a9b7d2468
CHAL=c0ffee00112233445566778899aabbcc
STEPS=text,bytes,empty,both,slow,kat,chal
W=$(mktemp -d /tmp/fsb1.XXXXXX)
trap 'rm -rf "$W"' EXIT

[ "$(sha256sum "$BB_SRC" | cut -c1-64)" = c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02 ] \
    || { echo "REFUSED: busybox is not the reviewed binary"; exit 1; }
rm -rf "$FX"; mkdir -p "$FX"
mkdir -p "$W/bin"
cp "$BB_SRC" "$W/bin/busybox"; chmod 0755 "$W/bin/busybox"
for a in sh cat printf base64 awk sha256sum cut wc sed grep tr true sleep echo mkdir; do ln -s busybox "$W/bin/$a"; done
BB=$W/bin/busybox
SUP=$HERE/build/fs-supervise
ENC=${ENC:-$HERE/target/fsb1-enc.sh}   # ENC=<file>: another encoder revision (before/after)

# ---- 1. the generic record, made on the "target" side ----------------------------
cat > "$W/gen-generic.sh" <<'EOF'
. "$ENC"
R=$WD/record; D=$WD/cap
mkdir -p "$D"
fsb1_begin "$R" fixture "$NONCE" "$CHAL" 7 || exit 1
fsb1_run "$R" 1 text  "$D" 30 -- "$BB" printf 'line one\nline two\r\n\ttab\n' || exit 1
fsb1_run "$R" 2 bytes "$D" 30 -- "$BB" sh -c 'i=0; while [ $i -lt 256 ]; do printf "\\$(printf %o $i)"; i=$((i+1)); done' || exit 1
fsb1_run "$R" 3 empty "$D" 30 -- "$BB" true || exit 1
fsb1_run "$R" 4 both  "$D" 30 -- "$BB" sh -c 'echo out; echo err >&2; exit 7' || exit 1
fsb1_run "$R" 5 slow  "$D" 1 -- "$BB" sleep 30 || exit 1
fsb1_run "$R" 6 kat   "$D" 30 -- "$BB" sha256sum || exit 1
printf '%s:%s' "$NONCE" "$CHAL" > "$WD/chal.bin"
fsb1_run "$R" 7 chal  "$D" 30 -i "$WD/chal.bin" -- "$BB" sha256sum || exit 1
fsb1_end "$R" "$NONCE" "$CHAL" || exit 1
fsb1_emit "$R"
EOF
mkdir -p "$W/g"
env -i PATH="$W/bin" ENC="$ENC" WD="$W/g" NONCE=$NONCE CHAL=$CHAL BB="$BB" FSB1_SUP="$SUP" \
    /usr/bin/qemu-aarch64 "$BB" sh "$W/gen-generic.sh" > "$FX/valid.txt"
printf 'valid\tVALID\t-\tfixture\t%s\t%s\t%s\tgeneric\n' $NONCE $CHAL $STEPS > "$FX/CASES.tsv"

# independent payload hashes, straight from fs-supervise's capture files
: > "$FX/PAYLOADS.tsv"
for i in 1 2 3 4 5 6 7; do
    for s in out err; do
        printf 'generic\t%s\t%s\t%s\t%s\n' $i $s "$(sha256sum < "$W/g/cap/$i.$s" | cut -c1-64)" "$(stat -c %s "$W/g/cap/$i.$s")" >> "$FX/PAYLOADS.tsv"
    done
done
# and the expected contents themselves, computed by Python (not by busybox)
python3 -I - "$W/g/cap" "$NONCE" "$CHAL" > "$FX/PAYLOADS-check.txt" <<'PY' || { cat "$FX/PAYLOADS-check.txt"; echo "FSB1 FIXTURE FAILED: payload check"; exit 1; }
import hashlib, sys
d, n, c = sys.argv[1:4]
want = {
  "1.out": b"line one\nline two\r\n\ttab\n",
  "2.out": bytes(range(256)),
  "3.out": b"", "3.err": b"",
  "4.out": b"out\n", "4.err": b"err\n",
  "5.out": b"",
  "6.out": (hashlib.sha256(b"").hexdigest() + "  -\n").encode(),
  "7.out": (hashlib.sha256(("%s:%s" % (n, c)).encode()).hexdigest() + "  -\n").encode(),
}
bad = 0
for k, v in want.items():
    got = open("%s/%s" % (d, k), "rb").read()
    ok = got == v
    bad += not ok
    print("%-6s %s %d bytes" % (k, "PASS" if ok else "FAIL", len(got)))
print("TOTAL fail=%d" % bad)
sys.exit(bad != 0)
PY
cat "$FX/PAYLOADS-check.txt"
grep -h '' "$W/g/cap/"*.sup | sed 's/^/sup: /' > "$FX/valid-sup-lines.txt"

# ---- 2. through a real pty (default termios: OPOST|ONLCR) -------------------------
python3 -I - "$FX/valid.txt" "$FX/valid-pty.txt" <<'PY'
import os, pty, select, subprocess, sys, termios
m, s = pty.openpty()
assert termios.tcgetattr(s)[1] & termios.ONLCR, "ONLCR not set"
p = subprocess.Popen(["cat", sys.argv[1]], stdout=s, stderr=subprocess.DEVNULL)
os.close(s)
buf = b""
while True:
    r, _, _ = select.select([m], [], [], 2)
    if not r:
        break
    try:
        d = os.read(m, 65536)
    except OSError:
        break
    if not d:
        break
    buf += d
p.wait()
open(sys.argv[2], "wb").write(buf)
print("pty: %d bytes in, %d bytes out, CRLF pairs %d" % (os.path.getsize(sys.argv[1]), len(buf), buf.count(b"\r\n")))
PY
printf 'valid-pty\tVALID\t-\tfixture\t%s\t%s\t%s\tgeneric\n' $NONCE $CHAL $STEPS >> "$FX/CASES.tsv"

# ---- 3. optional: the T1 Valve files, supervised, under qemu ---------------------
T1STEPS=hash,absent,diag,list,uname,b2kat,b2chal
if [ -x "$VS/lib/ld-linux-aarch64.so.1" ]; then
    LD=$VS/lib/ld-linux-aarch64.so.1
    cat > "$W/gen-t1.sh" <<'EOF'
. "$ENC"
R=$WD/record; D=$WD/cap
mkdir -p "$D"
X="$LD --inhibit-cache --library-path $VS/lib"
fsb1_begin "$R" t1demo "$NONCE" "$CHAL" 7 || exit 1
fsb1_run "$R" 1 hash  "$D" 20 -- "$BB" sha256sum "$VS/lib/ld-linux-aarch64.so.1" "$VS/lib/libc.so.6" "$VS/bin/uname" "$VS/bin/b2sum" || exit 1
fsb1_run "$R" 2 absent "$D" 20 -- "$BB" sh -c 'for p in /etc/ld.so.preload /usr /lib/libc.so.6 /lib/ld-linux-aarch64.so.1 /usr/lib/libc.so.6; do [ -e "$p" ] || [ -L "$p" ] && echo "$p"; done; exit 0' || exit 1
fsb1_run "$R" 3 diag  "$D" 20 -- "$LD" --list-diagnostics || exit 1
fsb1_run "$R" 4 list  "$D" 20 -- $X --list "$VS/bin/b2sum" || exit 1
fsb1_run "$R" 5 uname "$D" 20 -- $X "$VS/bin/uname" -r || exit 1
fsb1_run "$R" 6 b2kat "$D" 20 -- $X "$VS/bin/b2sum" || exit 1
printf '%s:%s' "$NONCE" "$CHAL" > "$WD/chal.bin"
fsb1_run "$R" 7 b2chal "$D" 20 -i "$WD/chal.bin" -- $X "$VS/bin/b2sum" || exit 1
fsb1_end "$R" "$NONCE" "$CHAL" || exit 1
fsb1_emit "$R"
EOF
    mkdir -p "$W/t2"
    env -i PATH="$W/bin" ENC="$ENC" WD="$W/t2" NONCE=$NONCE CHAL=$CHAL BB="$BB" FSB1_SUP="$SUP" LD="$LD" VS="$VS" \
        /usr/bin/qemu-aarch64 "$BB" sh "$W/gen-t1.sh" > "$FX/valid-t1.txt"
    printf 'valid-t1\tVALID\t-\tt1demo\t%s\t%s\t%s\tt1\n' $NONCE $CHAL $T1STEPS >> "$FX/CASES.tsv"
    for i in 1 2 3 4 5 6 7; do
        for s in out err; do
            printf 't1\t%s\t%s\t%s\t%s\n' $i $s "$(sha256sum < "$W/t2/cap/$i.$s" | cut -c1-64)" "$(stat -c %s "$W/t2/cap/$i.$s")" >> "$FX/PAYLOADS.tsv"
        done
    done
    python3 -I - "$W/t2/cap" "$NONCE" "$CHAL" > "$FX/valid-t1-check.txt" <<'PY' || { cat "$FX/valid-t1-check.txt"; echo "FSB1 FIXTURE FAILED: T1 check"; exit 1; }
import hashlib, sys
d, n, c = sys.argv[1:4]
kat = hashlib.blake2b(b"").hexdigest()
chal = hashlib.blake2b(("%s:%s" % (n, c)).encode()).hexdigest()
o = lambda i: open("%s/%d.out" % (d, i), "rb").read().decode()
r = []
r.append(("hash: 4 lines, pinned SHA-256 values", [l.split()[0][:8] for l in o(1).splitlines()] == ["2ddc56a0", "be7ee393", "4295f034", "90154680"]))
r.append(("b2kat = BLAKE2b-512('') + '  -'", o(6) == kat + "  -\n"))
r.append(("b2chal = BLAKE2b-512(nonce:chal) by Python hashlib", o(7) == chal + "  -\n"))
r.append(("list: 3 lines, libc and ld.so resolved under the stage", len(o(4).splitlines()) == 3 and "/valve/lib/libc.so.6" in o(4)))
r.append(("absent: only listed paths (WSL host: some exist; framing demo)", all(l in ("/etc/ld.so.preload", "/usr", "/lib/libc.so.6", "/lib/ld-linux-aarch64.so.1", "/usr/lib/libc.so.6") for l in o(2).splitlines())))
r.append(("diag: no env[ line (empty environment)", not any(l.startswith("env[") for l in o(3).splitlines())))
for k, v in r:
    print("%-55s %s" % (k, "PASS" if v else "FAIL"))
sys.exit(0 if all(v for _, v in r) else 1)
PY
    cat "$FX/valid-t1-check.txt"
    echo "T1 note: paths in valid-t1.txt are under the WSL stage directory; uname -r is the WSL host kernel (qemu-user)" > "$FX/valid-t1-NOTE.txt"
else
    echo "T1 stage absent: valid-t1 skipped" | tee "$FX/valid-t1-NOTE.txt"
fi

# ---- 4. derived cases and the Python decoder -------------------------------------
python3 -I "$HERE/tools/fsb1_mutate.py" "$FX" $NONCE $CHAL $STEPS
python3 -I "$HERE/tools/test_fsb1.py" "$FX"
