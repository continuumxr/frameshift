#!/bin/bash
# FrameShift N1 — negative fixtures for build-image.sh, the reproducibility and nonce-only checks (run inside WSL):
#   wsl.exe -e bash <checkout>/devices/quest3/n1/test-builder.sh [CANDIDATE_DIR]
# Derived from k1a/test-builder.sh (every K1a case is kept, against the N1 builder). Each case points ONE input
# elsewhere through the builder's FS_TEST_* variables and requires: a nonzero exit, the expected "BUILD REFUSED: ..."
# reason, and nothing published (the case's own FS_TEST_OUTBASE stays empty). Tampered copies live only in WSL scratch
# (~/work/fsbuild-neg/n1). N1 adds: fs-xfer (tampered, missing, a build record naming another binary or another
# source) and the no-listener lints (a listening applet in the runner or init, fs-xfer named outside the runner, a
# third fs-xfer line, a network command in the info helper).
# Then: two builds with the same nonce and stamp must be bit-identical (repro-same-nonce); two builds with
# different nonces must pass tools/nonce-only-n1.py (nonce-only), and a rebuild whose /init differs beyond the
# nonce must fail it (nonce-only-negative). With CANDIDATE_DIR the candidate is rebuilt with its own nonce and
# stamp and must be bit-identical (candidate-rebuild) and nonce-only against the repro build.
# Writes fixtures/builder/RESULTS.txt.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${FS_INPUT_ROOT:-<repo>}
CHECKOUT=$(cd "$HERE/../../.." && pwd)
B=$HERE/build-image.sh
NO=$HERE/tools/nonce-only-n1.py
FX=$HERE/fixtures/builder
S=$HOME/work/fsbuild-neg/n1
KIMG=${FS_K1A_KERNEL:-$HOME/work/kgate27/out-k1a/arch/arm64/boot/Image}
rm -rf "${S:?}" "${FX:?}"; mkdir -p "$S" "$FX"
R=$FX/RESULTS.txt
echo "# n1 builder negatives  $(date -u +%Y-%m-%dT%H:%M:%SZ); build-image.sh sha256=$(sha256sum "$B" | cut -c1-64)" > "$R"

# flip FILE [OFFSET]: flip one bit at OFFSET (default: the middle of the file); the copy must then differ from its source
# (review MAJOR-1: a silent flip failure made a negative case build an accepted image)
flip() { python3 -I -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); o=int(sys.argv[2],0) if len(sys.argv)>2 else len(b)//2; b[o]^=1; open(p,"wb").write(b)' "$@"     || { echo "FATAL: flip $* failed" | tee -a "$R"; exit 2; }; }
differs() { cmp -s "$1" "$2" && { echo "FATAL: tampered copy $2 equals $1" | tee -a "$R"; exit 2; }; return 0; }

fail=0; n=0
case_() {   # case_ NAME EXPECTED-REASON-REGEX VAR=VALUE...
    local name=$1 want=$2; shift 2
    local o=$S/out-$name; mkdir -p "$o"
    n=$((n + 1))
    env "$@" FS_TEST_OUTBASE="$o" bash "$B" > "$FX/$name.log" 2>&1; local rc=$?
    local why; why=$(grep -m1 '^BUILD REFUSED' "$FX/$name.log" || true)
    local left; left=$(find "$o" -mindepth 1 | wc -l)
    if [ $rc -ne 0 ] && printf '%s\n' "$why" | grep -Eq "$want" && [ "$left" -eq 0 ]; then
        echo "PASS  $name  rc=$rc  $why" | tee -a "$R"
    else
        echo "FAIL  $name  rc=$rc  published=$left  $why (wanted /$want/)" | tee -a "$R"; fail=$((fail + 1))
    fi
}

# --- the kernel ---------------------------------------------------------------------
cp "$KIMG" "$S/Image-flip"; flip "$S/Image-flip" 0x200000; differs "$KIMG" "$S/Image-flip"
case_ kernel-tampered 'K1a kernel hash differs from the pin' FS_TEST_KERNEL="$S/Image-flip"
case_ kernel-missing 'input missing or not a regular file: /nonexistent/Image' FS_TEST_KERNEL=/nonexistent/Image
case_ kernel-stock-v27 'K1a kernel hash differs from the pin' FS_TEST_KERNEL="$ROOT/firmware/quest3/extracted/v2.7-user_ota/Image"
case_ kernel-group-a-build 'K1a kernel hash differs from the pin' FS_TEST_KERNEL="$HOME/work/kgate27/out-a/arch/arm64/boot/Image"
ln -sf "$KIMG" "$S/Image-link"
case_ kernel-symlink 'input missing or not a regular file' FS_TEST_KERNEL="$S/Image-link"
cp "$HERE/../k1a/kernel/k1a.config" "$S/k1a.config"; echo "CONFIG_SYSVIPC=y" >> "$S/k1a.config"
case_ config-tampered 'K1a config .* hash differs from the pin' FS_TEST_K1A_CONFIG="$S/k1a.config"
case_ gate-missing 'input missing or not a regular file: /nonexistent/check-k1a.json' FS_TEST_GATE=/nonexistent/check-k1a.json
G=$CHECKOUT/tools/kgate/validation/quest3/check-k1a.json
python3 -I - "$G" "$S/gate-fail.json" "$S/gate-waived.json" "$S/gate-crc.json" "$S/gate-report.json" "$S/gate-nobind.json" "$S/gate-otherref.json" "$S/gate-basechg.json" "$S/gate-extra.json" "$S/gate-othervm.json" "$S/gate-tool.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
a = dict(g); a["result"] = "FAIL"; a["exit_code"] = 1; json.dump(a, open(sys.argv[2], "w"))
b = dict(g); b["waivers"] = {"committed-profile": "pending commit"}; json.dump(b, open(sys.argv[3], "w"))
c = dict(g); c["required_result"] = dict(g["required_result"], match=g["required_result"]["match"] - 1, mismatch=1); json.dump(c, open(sys.argv[4], "w"))
d = dict(g); d["mode"] = "report-only"; json.dump(d, open(sys.argv[5], "w"))
e = dict(g); e["checks"] = [x for x in g["checks"] if x["id"] != "input-binding"]; json.dump(e, open(sys.argv[6], "w"))
f = json.loads(json.dumps(g)); f["inputs"]["reference"]["sha256"] = "0" * 64; json.dump(f, open(sys.argv[7], "w"))
h = json.loads(json.dumps(g)); h["baseline_result"]["changed"] = 1; json.dump(h, open(sys.argv[8], "w"))
x = json.loads(json.dumps(g)); x["checks"].append({"id": "unknown-new-check", "status": "PASS", "message": "x"}); json.dump(x, open(sys.argv[9], "w"))
v = json.loads(json.dumps(g)); v["inputs"]["vmlinux"]["sha256"] = "1" * 64; json.dump(v, open(sys.argv[10], "w"))
t = json.loads(json.dumps(g)); t["tool_version"] = "2.2"; json.dump(t, open(sys.argv[11], "w"))
PY
case_ gate-result-fail 'kgate result is not a gate PASS for this Image: result FAIL exit 1' FS_TEST_GATE="$S/gate-fail.json"
case_ gate-waived 'kgate result is not a gate PASS for this Image: waivers' FS_TEST_GATE="$S/gate-waived.json"
case_ gate-crc-mismatch 'kgate result is not a gate PASS for this Image: required_result' FS_TEST_GATE="$S/gate-crc.json"
case_ gate-report-only 'kgate result is not a gate PASS for this Image: mode report-only' FS_TEST_GATE="$S/gate-report.json"
case_ gate-check-missing 'kgate result is not a gate PASS for this Image: gate checks not present exactly once as PASS: \[.input-binding.\]' FS_TEST_GATE="$S/gate-nobind.json"
case_ gate-other-reference 'kgate result is not a gate PASS for this Image: gated reference 0{64} is not daf9546e' FS_TEST_GATE="$S/gate-otherref.json"
case_ gate-baseline-changed 'kgate result is not a gate PASS for this Image: baseline_result' FS_TEST_GATE="$S/gate-basechg.json"
case_ gate-extra-check 'kgate result is not a gate PASS for this Image: unexpected gate checks' FS_TEST_GATE="$S/gate-extra.json"
case_ gate-other-vmlinux 'kgate result is not a gate PASS for this Image: gated vmlinux 1{64}' FS_TEST_GATE="$S/gate-othervm.json"
case_ gate-tool-version 'kgate result is not a gate PASS for this Image: kgate tool_version 2.2' FS_TEST_GATE="$S/gate-tool.json"
case_ gate-other-build 'kgate result is not a gate PASS for this Image: build a; gated kernel' FS_TEST_GATE="$CHECKOUT/tools/kgate/validation/quest3/check-a.json"

# --- the other pinned inputs (as stage 3d) ---------------------------------------------
cp "$ROOT/build/third_party/busybox/busybox" "$S/busybox"; printf '\0' >> "$S/busybox"
case_ busybox-tampered 'busybox hash differs from the pin' FS_TEST_BUSYBOX="$S/busybox"
case_ fs-supervise-missing 'input missing or not a regular file: /nonexistent/fs-supervise' FS_TEST_FS_SUPERVISE=/nonexistent/fs-supervise
cp "$ROOT/devices/quest3/common/build/fs-reboot-final" "$S/fs-reboot-final"; flip "$S/fs-reboot-final"; differs "$ROOT/devices/quest3/common/build/fs-reboot-final" "$S/fs-reboot-final"
case_ fs-reboot-final-tampered 'fs-reboot-final hash differs from the pin' FS_TEST_FS_REBOOT_FINAL="$S/fs-reboot-final"
cp "$ROOT/build/stage1-tools/fs-reboot" "$S/fs-reboot"; printf 'x' >> "$S/fs-reboot"
case_ fs-reboot-tampered 'fs-reboot hash differs from the pin' FS_TEST_FS_REBOOT="$S/fs-reboot"
cp "$HERE/../common/target/fsb1-pace.sh" "$S/fsb1-pace.sh"; echo "# x" >> "$S/fsb1-pace.sh"
case_ fsb1-pace-tampered 'common fsb1-pace.sh hash differs from the pin' FS_TEST_FSB1_PACE="$S/fsb1-pace.sh"
case_ stock-boot-v66 'AVB check' FS_TEST_STOCK_BOOT="$ROOT/firmware/quest3/v66_unit1_slotA/boot.img"
case_ stock-vboot-v66 'AVB check' FS_TEST_STOCK_VBOOT="$ROOT/firmware/quest3/v66_unit1_slotA/vendor_boot.img"
case_ vbmeta-v66 'vbmeta hash differs from the pin' FS_TEST_VBMETA="$ROOT/firmware/quest3/v66_unit1_slotA/vbmeta.img"
cp "$HERE/../stage3d/modules.load.v66" "$S/modlist-plus-tsens"; echo qcom_tsens.ko >> "$S/modlist-plus-tsens"
case_ module-list-plus-tsens 'module list \(modules.load.v66\) hash differs from the pin' FS_TEST_MODLIST="$S/modlist-plus-tsens"
sed 's/^MODDEP_SHA=ae5edf11/MODDEP_SHA=ae5edf12/' "$HERE/init.sh" > "$S/init-moddep.sh"
case_ init-moddep-pin-wrong 'init.sh MODDEP_SHA is not the pinned vendor_boot' FS_TEST_INIT="$S/init-moddep.sh"
printf 'injected\n' > "$S/inject.txt"
case_ inject-extra-file 'ramdisk contents differ from the expected list' FS_TEST_INJECT="$S/inject.txt:etc/ld.so.preload"
case_ nonce-not-hex 'nonce is not lowercase hex' FS_TEST_NONCE=0123456789abcdeg
case_ nonce-short 'nonce is not 16 characters' FS_TEST_NONCE=0123456789abcde
sed 's/$/\r/' "$HERE/init.sh" > "$S/init-crlf.sh"
case_ init-crlf 'CR characters in' FS_TEST_INIT="$S/init-crlf.sh"

# --- the lexical guards (stage 3d's, and K1a's no-panel / read-only ones) -----------------
cp "$HERE/init.sh" "$S/init-debugfs.sh"; printf '%s\n' 'mount -t debugfs none /sys/kernel/debug' >> "$S/init-debugfs.sh"
case_ init-debugfs-mount 'debugfs in a non-comment line of' FS_TEST_INIT="$S/init-debugfs.sh"
cp "$HERE/init.sh" "$S/init-devtmpfs.sh"; printf '%s\n' '$BB mount -t devtmpfs devtmpfs /dev' >> "$S/init-devtmpfs.sh"
case_ init-extra-mount 'mount line not in the reviewed whitelist' FS_TEST_INIT="$S/init-devtmpfs.sh"
cp "$HERE/init.sh" "$S/init-dri.sh"; printf '%s\n' 'mkdir -p /dev/dri && mknod -m 600 /dev/dri/card0 c 226 0' >> "$S/init-dri.sh"
case_ init-drm-node 'a DRM, backlight or panel path in a non-comment line' FS_TEST_INIT="$S/init-dri.sh"
cp "$HERE/fs-n1.sh" "$S/runner-bl.sh"; printf '%s\n' 'echo 127 > /sys/class/backlight/panel0-backlight/brightness' >> "$S/runner-bl.sh"
case_ runner-backlight-write 'a DRM, backlight or panel path in a non-comment line' FS_TEST_RUNNER="$S/runner-bl.sh"
cp "$HERE/fs-n1-info.sh" "$S/info-write.sh"; printf '%s\n' 'echo 1 > /sys/module/foo/parameters/bar' >> "$S/info-write.sh"
case_ info-redirect-write 'fs-n1-info.sh redirects output into a file' FS_TEST_INFO="$S/info-write.sh"
cp "$HERE/fs-n1-info.sh" "$S/info-insmod.sh"; printf '%s\n' 'insmod /lib/modules/btrfs.ko' >> "$S/info-insmod.sh"
case_ info-insmod 'fs-n1-info.sh calls a writing or network command' FS_TEST_INFO="$S/info-insmod.sh"
cp "$HERE/fs-n1-info.sh" "$S/info-blbc.sh"; printf '%s\n' 'cat /sys/class/drm/card0-sde-crtc-0/backlight_changes_blocked' >> "$S/info-blbc.sh"
case_ info-backlight-blocked 'backlight_changes_blocked in a non-comment line of' FS_TEST_INFO="$S/info-blbc.sh"

# --- N1: fs-xfer and the no-listener lints ------------------------------------------------------------
XB=$HERE/build/fs-xfer
cp "$XB" "$S/fs-xfer"; flip "$S/fs-xfer"; differs "$XB" "$S/fs-xfer"
case_ xfer-tampered 'fs-xfer hash differs from the pin' FS_TEST_FS_XFER="$S/fs-xfer"
case_ xfer-missing 'input missing or not a regular file: /nonexistent/fs-xfer' FS_TEST_FS_XFER=/nonexistent/fs-xfer
sed 's/^binary:     build\/fs-xfer sha256=[0-9a-f]*/binary:     build\/fs-xfer sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$HERE/build-record/BUILD-xfer.txt" > "$S/rec-otherbin.txt"
case_ xfer-record-other-binary 'fs-xfer build record does not name this binary' FS_TEST_XFER_REC="$S/rec-otherbin.txt"
sed 's/^source:     src\/fs-xfer.c sha256=[0-9a-f]*/source:     src\/fs-xfer.c sha256=1111111111111111111111111111111111111111111111111111111111111111/' "$HERE/build-record/BUILD-xfer.txt" > "$S/rec-othersrc.txt"
case_ xfer-record-other-source "fs-xfer build record does not name this checkout's src/fs-xfer.c" FS_TEST_XFER_REC="$S/rec-othersrc.txt"
cp "$HERE/fs-n1.sh" "$S/runner-nc.sh"; printf '%s
' 'nc -l -p 1234 -e /bin/sh &' >> "$S/runner-nc.sh"
case_ runner-nc-listener 'a listening or network-daemon applet \(or eval\) in a non-comment line of' FS_TEST_RUNNER="$S/runner-nc.sh"
cp "$HERE/init.sh" "$S/init-telnetd.sh"; printf '%s
' 'telnetd -l /bin/sh' >> "$S/init-telnetd.sh"
case_ init-telnetd 'a listening or network-daemon applet \(or eval\) in a non-comment line of' FS_TEST_INIT="$S/init-telnetd.sh"
cp "$HERE/init.sh" "$S/init-xfer.sh"; printf '%s
' '/bin/fs-xfer -n "$NONCE" -c 00000000000000000000000000000000 -i none &' >> "$S/init-xfer.sh"
case_ init-starts-xfer 'fs-xfer named outside the runner in' FS_TEST_INIT="$S/init-xfer.sh"
cp "$HERE/fs-n1.sh" "$S/runner-xfer3.sh"; printf '%s
' '/bin/fs-xfer -n "$n" -c "$c" -i none' >> "$S/runner-xfer3.sh"
case_ runner-third-xfer 'the runner does not start /bin/fs-xfer in exactly its two xfer step lines' FS_TEST_RUNNER="$S/runner-xfer3.sh"
cp "$HERE/fs-n1-info.sh" "$S/info-ip.sh"; printf '%s
' 'ip -6 addr show' >> "$S/info-ip.sh"
case_ info-ip 'fs-n1-info.sh calls a writing or network command' FS_TEST_INFO="$S/info-ip.sh"
cp "$HERE/fs-n1.sh" "$S/runner-eval.sh"; printf '%s
' 'x=n; eval "${x}c -l -p 1"' >> "$S/runner-eval.sh"
case_ runner-eval 'a listening or network-daemon applet \(or eval\) in a non-comment line of' FS_TEST_RUNNER="$S/runner-eval.sh"
cp "$HERE/fs-n1-info.sh" "$S/info-udhcpd.sh"; printf '%s
' 'udhcpd /etc/udhcpd.conf' >> "$S/info-udhcpd.sh"
case_ info-udhcpd 'a listening or network-daemon applet \(or eval\) in a non-comment line of' FS_TEST_INFO="$S/info-udhcpd.sh"

# --- a dirty checkout (review MINOR-9): an uncommitted file among the image's sources is refused
: > "$HERE/src/dirty-probe"
case_ checkout-dirty 'the checkout has uncommitted changes in the image.s sources'
rm -f "$HERE/src/dirty-probe"

# --- reproducibility: the same nonce and stamp give the same bytes ----------------------
n=$((n + 1))
for k in 1 2; do
    env FS_TEST_NONCE=0123456789abcdef FS_TEST_STAMP=20260101T000000Z FS_TEST_OUTBASE="$S/repro$k" bash "$B" > "$FX/repro-$k.log" 2>&1
done
h1=$(sha256sum "$S"/repro1/*/boot-n1.img 2>/dev/null | cut -c1-64); h2=$(sha256sum "$S"/repro2/*/boot-n1.img 2>/dev/null | cut -c1-64)
c1=$(grep -m1 '^ramdisk.cpio' "$S"/repro1/*/MANIFEST.txt 2>/dev/null); c2=$(grep -m1 '^ramdisk.cpio' "$S"/repro2/*/MANIFEST.txt 2>/dev/null)
if [ -n "$h1" ] && [ "$h1" = "$h2" ] && [ -n "$c1" ] && [ "$c1" = "$c2" ]; then
    echo "PASS  repro-same-nonce  two builds, nonce 0123456789abcdef: image $h1 both times; $c1" | tee -a "$R"
else
    echo "FAIL  repro-same-nonce  image '$h1' vs '$h2'; cpio '$c1' vs '$c2'" | tee -a "$R"; fail=$((fail + 1))
fi

# --- nonce-only: another nonce changes /init's nonce and nothing else ------------------------
n=$((n + 1))
env FS_TEST_NONCE=fedcba9876543210 FS_TEST_STAMP=20260101T000001Z FS_TEST_OUTBASE="$S/nonce2" bash "$B" > "$FX/nonce2.log" 2>&1
FS_TEST_ALLOW_OVERRIDES=1 python3 -I -B "$NO" "$S"/repro1/20260101T000000Z-0123456789abcdef "$S"/nonce2/20260101T000001Z-fedcba9876543210 > "$FX/nonce-only.log" 2>&1; rc=$?
if [ $rc -eq 0 ] && grep -q '^NONCE-ONLY REBUILD: OK$' "$FX/nonce-only.log"; then
    echo "PASS  nonce-only  $(grep '^kernel bytes identical' "$FX/nonce-only.log")" | tee -a "$R"
else
    echo "FAIL  nonce-only  rc=$rc $(tail -1 "$FX/nonce-only.log")" | tee -a "$R"; fail=$((fail + 1))
fi
# negative: a rebuild whose /init differs beyond the nonce (one comment byte) must be refused
n=$((n + 1))
sed 's/^# Rules kept: PID 1 never exits/# Rules kept: PID 1 never Exits/' "$HERE/init.sh" > "$S/init-edit.sh"
env FS_TEST_INIT="$S/init-edit.sh" FS_TEST_NONCE=00112233445566ff FS_TEST_STAMP=20260101T000002Z FS_TEST_OUTBASE="$S/nonce3" bash "$B" > "$FX/nonce3.log" 2>&1
FS_TEST_ALLOW_OVERRIDES=1 python3 -I -B "$NO" "$S"/repro1/20260101T000000Z-0123456789abcdef "$S"/nonce3/20260101T000002Z-00112233445566ff > "$FX/nonce-only-negative.log" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q '^NONCE-ONLY REBUILD: REFUSED: the cpio archives differ beyond the nonce in /init$' "$FX/nonce-only-negative.log"; then
    echo "PASS  nonce-only-negative  $(tail -1 "$FX/nonce-only-negative.log")" | tee -a "$R"
else
    echo "FAIL  nonce-only-negative  rc=$rc $(tail -1 "$FX/nonce-only-negative.log")" | tee -a "$R"; fail=$((fail + 1))
fi
# negative: the same nonce twice is refused (a nonce is single-use)
n=$((n + 1))
mkdir -p "$S/same/20260101T000003Z-0123456789abcdef"; cp "$S"/repro2/20260101T000000Z-0123456789abcdef/* "$S/same/20260101T000003Z-0123456789abcdef/"
sed -i 's/^built: .*/built:            20260101T000003Z/' "$S/same/20260101T000003Z-0123456789abcdef/MANIFEST.txt"
FS_TEST_ALLOW_OVERRIDES=1 python3 -I -B "$NO" "$S"/repro1/20260101T000000Z-0123456789abcdef "$S/same/20260101T000003Z-0123456789abcdef" > "$FX/nonce-only-same.log" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q 'the nonces are equal' "$FX/nonce-only-same.log"; then
    echo "PASS  nonce-only-same-nonce  $(tail -1 "$FX/nonce-only-same.log")" | tee -a "$R"
else
    echo "FAIL  nonce-only-same-nonce  rc=$rc $(tail -1 "$FX/nonce-only-same.log")" | tee -a "$R"; fail=$((fail + 1))
fi

# --- the candidate itself, rebuilt with its own nonce and stamp ----------------------------
CAND=${1:-}
if [ -n "$CAND" ]; then
    n=$((n + 1))
    CAND=${CAND%/}; cn=${CAND##*-}; cs=$(basename "$CAND" | cut -d- -f1)
    env FS_TEST_NONCE="$cn" FS_TEST_STAMP="$cs" FS_TEST_OUTBASE="$S/cand" bash "$B" > "$FX/candidate-rebuild.log" 2>&1
    hc=$(sha256sum "$CAND/boot-n1.img" | cut -c1-64); hr=$(sha256sum "$S"/cand/*/boot-n1.img 2>/dev/null | cut -c1-64)
    cc=$(grep -m1 '^ramdisk.cpio' "$CAND/MANIFEST.txt"); cr=$(grep -m1 '^ramdisk.cpio' "$S"/cand/*/MANIFEST.txt 2>/dev/null)
    { echo "candidate $(basename "$CAND")"; echo "nonce $cn stamp $cs"; echo "candidate image $hc"; echo "rebuilt   image $hr"; echo "candidate $cc"; echo "rebuilt   $cr"; } > "$FX/candidate-rebuild.txt"
    if [ -n "$hr" ] && [ "$hc" = "$hr" ] && [ "$cc" = "$cr" ]; then
        echo "PASS  candidate-rebuild  nonce $cn stamp $cs: image $hc again; identical cpio" | tee -a "$R"
    else
        echo "FAIL  candidate-rebuild  '$hc' vs '$hr'" | tee -a "$R"; fail=$((fail + 1))
    fi
    n=$((n + 1))
    FS_TEST_ALLOW_OVERRIDES=1 python3 -I -B "$NO" "$CAND" "$S"/nonce2/20260101T000001Z-fedcba9876543210 > "$FX/candidate-nonce-only.log" 2>&1; rc=$?
    if [ $rc -eq 0 ]; then
        echo "PASS  candidate-nonce-only  the candidate vs a rebuild with nonce fedcba9876543210: NONCE-ONLY REBUILD: OK" | tee -a "$R"
    else
        echo "FAIL  candidate-nonce-only  rc=$rc $(tail -1 "$FX/candidate-nonce-only.log")" | tee -a "$R"; fail=$((fail + 1))
    fi
fi

# the logs name the scratch path, never device data; drop the bulky MANIFEST echo from the positive logs
for f in "$FX"/repro-*.log "$FX"/nonce2.log "$FX"/nonce3.log "$FX"/candidate-rebuild.log; do [ -f "$f" ] && sed -i '/^## ramdisk files/,$d' "$f"; done
rm -rf "${S:?}"
echo "TOTAL: $n cases, $fail failed" | tee -a "$R"
[ $fail -eq 0 ]
