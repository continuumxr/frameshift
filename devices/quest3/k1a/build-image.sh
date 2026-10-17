#!/bin/bash
# FrameShift — build ONE Quest 3 K1a test image: "our own kernel boots" (FS-A-013 §2.2 K1a; PROJECT_SETUP §3).
# The FrameShift-built K1a kernel (k1a/kernel/: Meta's v2.7 source dbc2bc83a2b6 + tools/kgate/validation/requests/
# quest3-k1a.txt, pinned toolchain and build identity, kgate PASS against Meta's stock vendor modules) in place of
# the stock kernel, plus our ramdisk: the stage-3d PID 1 with the display parts removed and a read-only report
# runner (k1a/init.sh, k1a/fs-k1a.sh). The unit's own stock v2.7 vendor_boot is NOT part of the image: with
# `fastboot boot` the bootloader takes the vendor ramdisk (Meta's modules), the DT and the vendor command line from
# the slot. No Valve file. No panel write. Derived from stage3d/build-image.sh. Run in WSL:
#   wsl.exe -e bash <checkout>/devices/quest3/k1a/build-image.sh
#
# Scripts and pins come from the checkout this file is in; gitignored inputs (firmware, AOSP mkbootimg, busybox,
# fs-reboot, fs-supervise, fs-reboot-final) from FS_INPUT_ROOT (default: the main checkout); the kernel from
# FS_K1A_KERNEL (default: the K1a build's arch/arm64/boot/Image in WSL).
#
# Refuses (nonzero, nothing published) unless EVERY check passes:
#   0. AVB provenance of the stock v2.7 inputs (stage3d/tools/avb-check.py): the pinned vbmeta + vbmeta_system give
#      the vbmeta digest Unit 2 reported at run time and the stock boot/vendor_boot match their hash descriptors (the
#      stock boot is used for its header fields only; the vendor_boot for the module index and the scans);
#   a. E1 clean-checkout check of the AOSP mkbootimg tree (devices/quest3/host/fs-gitcheck.sh);
#   k. THE KERNEL: the K1a Image has the pinned SHA-256; its banner is the pinned one (release, toolchain and our
#      pinned build identity); its embedded IKCONFIG equals k1a/kernel/k1a.config (pinned); the committed kgate
#      result tools/kgate/validation/quest3/check-k1a.json is a gate-mode PASS (exit 0, build k1a, no waiver) for
#      exactly this Image and config, with the 2601/2601 vendor-required CRCs, module_layout and 0 changed vmlinux
#      CRCs; the vermagic string the stock modules carry is in the Image;
#   b. pinned SHA-256 of every other input (stock boot, vendor_boot, the vendor module list and file list, OUR module
#      list stage3d/modules.load.v66 (95; stage3d/tools/module-list-check.py against the v2.7 vendor ramdisk),
#      vbmeta, vbmeta_system, busybox, fs-reboot, fs-reboot-final, fs-supervise, the common target scripts);
#      init.sh, fs-k1a.sh and fs-k1a-info.sh recorded; static-ELF checks; the busybox applet table; no CR; the
#      lexical guards of stage 3d (no debugfs, the five reviewed mounts only, no backlight_changes_blocked) plus K1a's:
#      no DRM node, backlight or panel path in any non-comment line;
#   c. the ramdisk: exact file list, no collision with the vendor ramdisk, the union lacks the loader paths, only the
#      four expected ELF files; ramdisk-scan-3d.sh on the FINAL image (no BLAKE2 hit; AF_ALG hash off in OUR kernel's
#      config);
#   d. repack and AOSP re-unpack: the kernel bytes in the image ARE the pinned K1a Image; the header differs from
#      stock only in "kernel size" and "ramdisk size" (v2.7 stock signature size is already 0); every file inside
#      the image equals the staged file;
#   e. MANIFEST.txt with the full SHA-256 and size of every input, every ramdisk file and the image.
#
# Output: $FS_INPUT_ROOT/build/k1a/<UTC>-<nonce>/ (gitignored): boot-k1a.img, MANIFEST.txt, ramdisk.list,
# ramdisk.sha256, applets.txt, header-diff.txt, ramdisk-scan.txt, gitcheck.txt, avb-check.txt, module-list-check.txt,
# kernel-check.txt.
#
# FS_TEST_* variables point inputs elsewhere for the NEGATIVE fixtures only (test-builder.sh); every pin still
# applies, and the MANIFEST says so.
set -euo pipefail
umask 022

HERE=$(cd "$(dirname "$0")" && pwd)
Q3=$(cd "$HERE/.." && pwd)
CHECKOUT=$(cd "$Q3/../.." && pwd)
ROOT=${FS_INPUT_ROOT:-<repo>}
S3D=$Q3/stage3d
COMMON=$Q3/common
AOSP=$ROOT/build/third_party/mkbootimg
FW=$ROOT/firmware/quest3/v2.7-user_ota
STOCK_BOOT=${FS_TEST_STOCK_BOOT:-$FW/boot.img}
STOCK_VBOOT=${FS_TEST_STOCK_VBOOT:-$FW/vendor_boot.img}
VBMETA=${FS_TEST_VBMETA:-$FW/vbmeta.img}
VBMETA_SYSTEM=$FW/vbmeta_system.img
AVBCHECK=$S3D/tools/avb-check.py
K1A_KERNEL=${FS_TEST_KERNEL:-${FS_K1A_KERNEL:-$HOME/work/kgate27/out-k1a/arch/arm64/boot/Image}}
K1A_CONFIG=${FS_TEST_K1A_CONFIG:-$HERE/kernel/k1a.config}
K1A_GATE=${FS_TEST_GATE:-$CHECKOUT/tools/kgate/validation/quest3/check-k1a.json}
BUSYBOX=${FS_TEST_BUSYBOX:-$ROOT/build/third_party/busybox/busybox}
FS_REBOOT=${FS_TEST_FS_REBOOT:-$ROOT/build/stage1-tools/fs-reboot}
FS_SUPERVISE=${FS_TEST_FS_SUPERVISE:-$ROOT/devices/quest3/common/build/fs-supervise}
FS_REBOOT_FINAL=${FS_TEST_FS_REBOOT_FINAL:-$ROOT/devices/quest3/common/build/fs-reboot-final}
OUTBASE=${FS_TEST_OUTBASE:-$ROOT/build/k1a}
INIT_SRC=${FS_TEST_INIT:-$HERE/init.sh}
RUNNER=${FS_TEST_RUNNER:-$HERE/fs-k1a.sh}
INFO=${FS_TEST_INFO:-$HERE/fs-k1a-info.sh}
MODLIST_SRC=${FS_TEST_MODLIST:-$S3D/modules.load.v66}       # installed as /lib/fs/modules.load (init.sh loads it)
MODCHECK=$S3D/tools/module-list-check.py
MOD_ROOTS=msm_drm,dwc3-msm,leds-qti-tri-led,tps65132-regulator,blu_fw_driver,mp3314,pwm-qti-lpg,msm_ext_display,panel_event_notifier,dispcc0-anorak,dispcc1-anorak,ucsi_glink,pwm-tach-fan
PID1_HOLD=$COMMON/target/pid1-hold.sh
FSB1_ENC=$COMMON/target/fsb1-enc.sh
FSB1_PACE=${FS_TEST_FSB1_PACE:-$COMMON/target/fsb1-pace.sh}
FS_DONE=$COMMON/target/fs-done
SCAN=$S3D/tools/ramdisk-scan-3d.sh
GITCHECK=$Q3/host/fs-gitcheck.sh

# --- pins (each change is a reviewable change) ----------------------------------
EXPECT_AOSP=d2bb0af5ba6d3198a3e99529c97eda1be0b5a093
# v2.7 stock inputs (stage3d/build-image.sh, stage3d/IMAGE.md "Inputs"): the official full OTA q3_52433670036000520.zip
EXPECT_STOCK_BOOT=e32f98c74bcce5c25b098393f7804e19fbba2f0c2034c49a4fcf6aa9a8cdc024
EXPECT_STOCK_VBOOT=bc0dd14de41834a601513123b2225a677fa4212dfa4505bf964228cea40d2f5b
EXPECT_VBMETA=aae4af3a1740d568a1bcd1104f1b30b2998082def674e00c319acfab10faf215
EXPECT_VBMETA_SYSTEM=28f5ccc91f25665dda5db1abf1fc3bd3fcea58f30cb33827642cddf6f9c8bc50
EXPECT_VBMETA_DIGEST=66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a   # Unit 2 runtime (getprop, 2026-10-12)
EXPECT_STOCK_KERNEL=db61c073962bf1df38cbb09cbb01f03e5595822754ffea1dc75166555f7d545e    # 5.10.246-gd7102a837402 (replaced by K1a)
EXPECT_MODLIST=0dd1deb02e5e9183e66c14682f94339da34fd56152a12208b22868ca231f66f4         # lib/modules/modules.load.recovery
EXPECT_MODLIST_N=131
EXPECT_VLIST=c01d89a16159be9ad67ee6bf32fd11a14827068a4e23e298f33bdea0d621b2ce           # sorted vendor ramdisk path list
EXPECT_VLIST_N=143
EXPECT_FSMODLIST=1b93d77d029146cf93289be87de51514c6ab7b96987f9c467a7f13f6e2a6463f       # stage3d/modules.load.v66 (J-129)
EXPECT_FSMODLIST_N=95
EXPECT_BUSYBOX=c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02         # stage 1
EXPECT_FS_REBOOT=c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29       # stage 1
EXPECT_FS_SUPERVISE=77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74    # common rev 4 README
EXPECT_FS_REBOOT_FINAL=ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e # common rev 4 README
EXPECT_PID1_HOLD=4294c9d57f3a94eba9847596aa614f557e7b4278cfeb5a22e38955fdd5b81dc4       # common rev 5
EXPECT_FSB1_ENC=11e44d2fa386d06c596c03ff54ecfb5aeeea4790a560c8e65bf26e76733bf1a7        # common rev 5
EXPECT_FS_DONE=7ad5f1106acd828fa3e9d6da9cfa0e50d66431b4b2d3a951ce39f12375064959         # common rev 4
EXPECT_FSB1_PACE=71ce176e09c21b2304b0be90543f2c0da26b0a5c0aed3c3bb23cf8a2b412404c        # common, stage 3b
# THE K1a KERNEL (k1a/kernel/record/run1: build run 1; the run-2 rebuild comparison in k1a/kernel/BUILD-RECORD.txt; kgate check-k1a.json)
EXPECT_K1A_KERNEL=087f0e72999922909e9583b95ae956f0186d6c1a337b71308b845456689e1840
EXPECT_K1A_KERNEL_SIZE=42967552
EXPECT_K1A_CONFIG=4aa0c894655627f6ff39476ac2a45abb4c224ee0053957d5002c694b0602826b
EXPECT_K1A_BANNER='Linux version 5.10.246-gdbc2bc83a2b6 (frameshift@k1a) (Android (8508608, based on r450784e) clang version 14.0.7 (https://android.googlesource.com/toolchain/llvm-project 4c603efb0cca074e9238af8b4106c30add4418f6), LLD 14.0.7) #1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026'
EXPECT_K1A_RELEASE=5.10.246-gdbc2bc83a2b6
EXPECT_VERMAGIC_FLAGS="SMP preempt mod_unload modversions aarch64"
EXPECT_GATE_REQUIRED=2601
EXPECT_GATE_LAYOUT=0xb1f01218
EXPECT_GATE_REFERENCE=daf9546ea2ca4e99a22d67aa9cf1ec67686c0a6d6b6633a38319096ecafb63aa    # profile reference_sha256 (stock v2.7 modules)
EXPECT_GATE_BASELINE=7b5cfa8f54c41945e38f493196a55bfe1baff454f2c7e82e93d4959aa684b28d     # profile stock_build_symvers_sha256
EXPECT_K1A_VMLINUX=8686b77c44ae1ebffa8f3844b3ef0162c30a332b379b2075aec9698e930fb8ca       # kernel/record/run1/manifest.txt
EXPECT_K1A_SYMVERS=0ce513c3af499dff91fd634f0ac940c50f9b5fe84f3bf6867776fe27d5ded621       # kernel/record/run1/manifest.txt
# every applet init.sh, fs-k1a.sh, fs-k1a-info.sh, fsb1-enc.sh, fsb1-pace.sh, pid1-hold.sh and fs-done call
REQUIRED_APPLETS="sh mount mknod mkdir cut cat echo printf sync reboot sleep insmod mdev ls tr sed grep basename setsid kill ln uname sha256sum stty mv rm rmdir chmod base64 awk wc head mkfifo tail dmesg zcat ip"

NONCE=${FS_TEST_NONCE:-$(openssl rand -hex 8)}
STAMP=${FS_TEST_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
case "$NONCE" in ????????????????) ;; *) echo "BUILD REFUSED: nonce is not 16 characters" >&2; exit 1 ;; esac
case "$NONCE" in *[!0-9a-f]*) echo "BUILD REFUSED: nonce is not lowercase hex" >&2; exit 1 ;; esac
OUT=$OUTBASE/$STAMP-$NONCE
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

sha() { sha256sum "$1" | cut -c1-64; }
sz()  { stat -c %s "$1"; }
die() { echo "BUILD REFUSED: $*" >&2; exit 1; }
for t in python3 cpio lz4 readelf file openssl git sha256sum stat; do command -v $t >/dev/null || die "missing tool $t"; done
case "$EXPECT_K1A_KERNEL $EXPECT_K1A_KERNEL_SIZE $EXPECT_K1A_CONFIG $EXPECT_K1A_BANNER" in *@K1A_*) die "the K1a kernel pins are not filled in" ;; esac
OVERRIDES=$(env | grep -E '^FS_TEST_' | sort | tr '\n' ' ' || true)

# --- 0. AVB provenance: the pinned v2.7 vbmeta chain gives Unit 2's runtime digest ----------
for f in "$VBMETA" "$VBMETA_SYSTEM" "$AVBCHECK"; do [ -f "$f" ] && [ ! -L "$f" ] || die "input missing or not a regular file: $f"; done
[ "$(sha "$VBMETA")" = "$EXPECT_VBMETA" ] || die "vbmeta hash differs from the pin ($VBMETA)"
[ "$(sha "$VBMETA_SYSTEM")" = "$EXPECT_VBMETA_SYSTEM" ] || die "vbmeta_system hash differs from the pin"
python3 -I "$AVBCHECK" --vbmeta "$VBMETA" --chain vbmeta_system="$VBMETA_SYSTEM" --hash boot="$STOCK_BOOT" \
    --hash vendor_boot="$STOCK_VBOOT" --expect-digest "$EXPECT_VBMETA_DIGEST" > "$W/avb-check.txt" 2>&1 \
    || { cat "$W/avb-check.txt" >&2; die "AVB check: the stock inputs do not reproduce Unit 2's runtime vbmeta digest and hash descriptors"; }

# --- a. E1: the AOSP checkout -----------------------------------------------------
[ -f "$GITCHECK" ] || die "E1 helper missing: $GITCHECK"
# shellcheck source=/dev/null
. "$GITCHECK"
fs_gitcheck "$AOSP" "$EXPECT_AOSP" 2> "$W/gitcheck.err" || { cat "$W/gitcheck.err" >&2; die "E1: AOSP mkbootimg checkout refused"; }
E1NOTES=$(grep '^NOTE' "$W/gitcheck.err" | tr '\n' ' ' || true)
{ echo "E1 fs_gitcheck $AOSP at $EXPECT_AOSP: CLEAN (helper sha256=$(sha "$GITCHECK"))"; cat "$W/gitcheck.err"; } > "$W/gitcheck.txt"
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP
export PYTHONPYCACHEPREFIX="$W/pycache" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
PYA="python3 -E -s -B -X pycache_prefix=$W/pycache"

need() { [ -f "$1" ] && [ ! -L "$1" ] || die "input missing or not a regular file: $1"; }
pin() {  # pin FILE EXPECT LABEL
    need "$1"
    [ "$(sha "$1")" = "$2" ] || die "$3 hash differs from the pin ($1: $(sha "$1") != $2)"
}

# --- clean checkout (review MINOR-9): the scripts that go into the image, the pins they are checked against and the gate
# result must be the committed ones (an uncommitted edit would only show up as another "recorded" hash)
if [ -z "${FS_TEST_ALLOW_DIRTY:-}" ]; then
    dirty=$(git -c safe.directory='*' -C "$CHECKOUT" status --porcelain -- devices/quest3/k1a/init.sh devices/quest3/k1a/fs-k1a.sh \
        devices/quest3/k1a/fs-k1a-info.sh devices/quest3/k1a/build-image.sh devices/quest3/k1a/kernel devices/quest3/common/target \
        devices/quest3/stage3d/modules.load.v66 devices/quest3/stage3d/tools devices/quest3/host/fs-gitcheck.sh \
        tools/kgate/validation/requests tools/kgate/validation/quest3/check-k1a.json tools/kgate/kgate.py tools/kgate/btf_kind_scan.py 2>&1) || die "git status failed in $CHECKOUT"
    [ -z "$dirty" ] || die "the checkout has uncommitted changes in the image's sources: $(printf '%s' "$dirty" | head -3 | tr '\n' ' ')"
    CHECKOUT_HEAD=$(git -c safe.directory='*' -C "$CHECKOUT" rev-parse HEAD)
else
    CHECKOUT_HEAD="DIRTY ALLOWED (FS_TEST_ALLOW_DIRTY: fixtures only)"
fi

# --- k. THE KERNEL: pinned bytes, banner, IKCONFIG, and the committed kgate PASS for exactly these bytes ----------
pin "$K1A_KERNEL" "$EXPECT_K1A_KERNEL" "K1a kernel"
[ "$(sz "$K1A_KERNEL")" -eq "$EXPECT_K1A_KERNEL_SIZE" ] || die "K1a kernel size differs from the pin"
pin "$K1A_CONFIG" "$EXPECT_K1A_CONFIG" "K1a config (k1a/kernel/k1a.config)"
need "$K1A_GATE"
REQDIR=$CHECKOUT/tools/kgate/validation/requests
for f in "$REQDIR/quest3-k1a.txt" "$REQDIR/quest3-k1a.allow" "$REQDIR/quest3.profile.json"; do need "$f"; done
python3 -I - "$K1A_KERNEL" "$K1A_CONFIG" "$K1A_GATE" "$EXPECT_K1A_BANNER" "$EXPECT_K1A_RELEASE" "$EXPECT_VERMAGIC_FLAGS" \
    "$EXPECT_GATE_REQUIRED" "$EXPECT_GATE_LAYOUT" "$REQDIR/quest3-k1a.txt" "$REQDIR/quest3-k1a.allow" "$REQDIR/quest3.profile.json" \
    "$EXPECT_GATE_REFERENCE" "$EXPECT_GATE_BASELINE" "$EXPECT_STOCK_BOOT" "$EXPECT_K1A_VMLINUX" "$EXPECT_K1A_SYMVERS" \
    > "$W/kernel-check.txt" 2>&1 <<'PY' || { cat "$W/kernel-check.txt" >&2; die "K1a kernel check: $(grep -m1 '^REFUSE' "$W/kernel-check.txt" | cut -c8-)"; }
import gzip, hashlib, json, re, sys
kp, cp, gp, banner, rel, vflags, nreq, layout, rqp, alp, prp, refsha, basesha, stocksha, vmsha, svsha = sys.argv[1:17]
k = open(kp, "rb").read(); c = open(cp, "rb").read()
def refuse(m):
    print("REFUSE " + m); sys.exit(1)
if k[56:60] != b"ARM\x64":
    refuse("not an uncompressed arm64 Image (no ARM\\x64 magic at 56)")
bans = sorted(set(x.decode() for x in re.findall(rb"Linux version \d+\.\d+\.\d+[ -~]+", k)))
if bans != [banner]:
    refuse("banner differs from the pin: %r" % bans)
print("banner: " + banner)
i = k.find(b"IKCFG_ST"); j = k.find(b"IKCFG_ED", i)
if i < 0 or j < 0:
    refuse("no embedded IKCONFIG")
emb = gzip.decompress(k[i + 8:j])
if emb != c:
    refuse("embedded IKCONFIG differs from k1a.config")
print("ikconfig: %d bytes, sha256 %s (= k1a/kernel/k1a.config)" % (len(emb), hashlib.sha256(emb).hexdigest()))
vm = ("%s %s" % (rel, vflags)).encode() + b"\0"
if k.find(vm) < 0:
    refuse("the module-loader vermagic '%s %s' is not in the Image" % (rel, vflags))
print("vermagic: '%s %s' present" % (rel, vflags))
g = json.load(open(gp))
ksha = hashlib.sha256(k).hexdigest(); csha = hashlib.sha256(c).hexdigest()
inp = g.get("inputs") or {}
prob = []
if g.get("result") != "PASS" or g.get("exit_code") != 0: prob.append("result %s exit %s" % (g.get("result"), g.get("exit_code")))
if g.get("mode") != "gate": prob.append("mode %s" % g.get("mode"))
if g.get("tool_version") != "2.3": prob.append("kgate tool_version %s (2.3 expected; review m1)" % g.get("tool_version"))
if g.get("waivers"): prob.append("waivers %s" % g.get("waivers"))
if (inp.get("profile") or {}).get("build") != "k1a": prob.append("build %s" % (inp.get("profile") or {}).get("build"))
if (inp.get("kernel") or {}).get("sha256") != ksha: prob.append("gated kernel %s is not this Image %s" % ((inp.get("kernel") or {}).get("sha256"), ksha))
if (inp.get("config") or {}).get("sha256") != csha: prob.append("gated config is not k1a.config")
# review MAJOR-3: bind the PASS to the pinned reference, baseline, stock kernel, build outputs and THIS checkout's
# request list, allowlist and profile (the trust root), and require every gate check to be present and PASS
fsha = lambda f: hashlib.sha256(open(f, "rb").read()).hexdigest()
for key, want in (("reference", refsha), ("baseline_symvers", basesha), ("stock_kernel", stocksha), ("vmlinux", vmsha),
                  ("symvers", svsha), ("requested", fsha(rqp)), ("allow_config_changes", fsha(alp)), ("profile", fsha(prp))):
    if (inp.get(key) or {}).get("sha256") != want:
        prob.append("gated %s %s is not %s" % (key, (inp.get(key) or {}).get("sha256"), want))
st = {}
for x in g.get("checks", []):
    st.setdefault(x.get("id"), []).append(x.get("status"))
NEED = ["reference-integrity", "profile-committed", "build-pins", "base-config", "symvers-duplicates", "crc", "module-layout",
        "unversioned-imports", "export-collision", "namespace", "gpl-only", "baseline", "requested-options", "requested-config",
        "vermagic-image", "vermagic", "btf-kinds", "config-binding", "input-binding"]
miss = [c for c in NEED if st.get(c) != ["PASS"]]
if miss: prob.append("gate checks not present exactly once as PASS: %s" % miss)
other = sorted(c for c, v in st.items() if c not in NEED and not (c in ("requested-config-toolchain", "requested-config-allowlisted") and v == ["WARN"]))
if other: prob.append("unexpected gate checks %s" % other)
rr = g.get("required_result") or {}
if rr != {"required": int(nreq), "match": int(nreq), "mismatch": 0, "missing": 0}: prob.append("required_result %s" % rr)
br = g.get("baseline_result") or {}
if br.get("changed") != 0 or br.get("removed") != 0 or br.get("type_or_ns_changed") != 0: prob.append("baseline_result %s" % {x: br.get(x) for x in ("changed", "removed", "type_or_ns_changed")})
bad = [x for x in g.get("checks", []) if x.get("status") in ("FAIL", "ERROR")]
if bad: prob.append("failing checks %s" % [x.get("id") for x in bad])
ml = [x for x in g.get("checks", []) if x.get("id") == "module-layout" and x.get("status") == "PASS" and layout in x.get("message", "")]
if not ml: prob.append("module-layout %s not a PASS" % layout)
if prob:
    refuse("kgate result is not a gate PASS for this Image: " + "; ".join(prob))
print("kgate: PASS exit 0, build k1a, kernel %s, config %s, required %s/%s, baseline changed 0 removed 0 (added %s), module_layout %s"
      % (ksha, csha, rr["match"], rr["required"], br.get("added"), layout))
PY

# --- b. pinned inputs -------------------------------------------------------------
pin "$STOCK_BOOT"      "$EXPECT_STOCK_BOOT"      "stock boot"
pin "$STOCK_VBOOT"     "$EXPECT_STOCK_VBOOT"     "stock vendor_boot"
pin "$BUSYBOX"         "$EXPECT_BUSYBOX"         "busybox"
pin "$FS_REBOOT"       "$EXPECT_FS_REBOOT"       "fs-reboot"
pin "$FS_SUPERVISE"    "$EXPECT_FS_SUPERVISE"    "fs-supervise"
pin "$FS_REBOOT_FINAL" "$EXPECT_FS_REBOOT_FINAL" "fs-reboot-final"
pin "$PID1_HOLD"       "$EXPECT_PID1_HOLD"       "common pid1-hold.sh"
pin "$FSB1_ENC"        "$EXPECT_FSB1_ENC"        "common fsb1-enc.sh"
pin "$FSB1_PACE"       "$EXPECT_FSB1_PACE"       "common fsb1-pace.sh"
pin "$FS_DONE"         "$EXPECT_FS_DONE"         "common fs-done"
pin "$MODLIST_SRC"     "$EXPECT_FSMODLIST"       "module list (modules.load.v66)"
[ "$(wc -l < "$MODLIST_SRC")" -eq "$EXPECT_FSMODLIST_N" ] || die "module list does not have $EXPECT_FSMODLIST_N entries"
[ "$(tr -cd '\r' < "$MODLIST_SRC" | wc -c)" -eq 0 ] || die "CR characters in $MODLIST_SRC"
need "$MODCHECK"
for f in "$INIT_SRC" "$RUNNER" "$INFO" "$SCAN"; do need "$f"; done
SCRIPTS="$INIT_SRC $RUNNER $INFO $PID1_HOLD $FSB1_ENC $FSB1_PACE $FS_DONE"
for f in $SCRIPTS; do
    [ "$(tr -cd '\r' < "$f" | wc -c)" -eq 0 ] || die "CR characters in $f (must be LF only)"
    head -1 "$f" | grep -qx '#!/bin/busybox sh' || die "$f: shebang is not #!/bin/busybox sh"
done
# stage 3c/3d lexical guards (PM decisions J-109 #2, J-129 #2; build review R-B), unchanged
for f in $SCRIPTS; do
    if grep -vE '^[[:space:]]*#' "$f" | grep -qiE 'debugfs|/sys/kernel/debug'; then die "debugfs in a non-comment line of $f"; fi
done
MOUNT_WHITELIST='$BB mount -t proc  proc  /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t tmpfs -o mode=0755,size=4m tmpfs /dev
$BB mount -t tmpfs -o mode=0755,size=4m tmpfs /run
mount -t configfs none /config 2>/dev/null'
for f in $SCRIPTS; do
    badm=$(grep -vE '^[[:space:]]*#' "$f" | grep -E '(^|[^[:alnum:]_-])u?mount([^[:alnum:]_-]|$)' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -vxF "$MOUNT_WHITELIST" || true)
    [ -z "$badm" ] || die "mount line not in the reviewed whitelist in $f: $(printf '%s' "$badm" | head -1)"
done
for f in $SCRIPTS; do
    if grep -vE '^[[:space:]]*#' "$f" | grep -q 'backlight_changes_blocked'; then die "backlight_changes_blocked in a non-comment line of $f"; fi
done
# K1a (no panel writes): no DRM node, backlight or panel path in any non-comment line (lexical, like the guards above;
# the runtime evidence is the harness's inotify watch on a fake backlight node and /dev/dri in every scenario)
for f in $SCRIPTS; do
    if grep -vE '^[[:space:]]*#' "$f" | grep -qiE 'backlight|/dev/dri|card0|panel|fs-pattern|/dev/fb'; then die "a DRM, backlight or panel path in a non-comment line of $f"; fi
done
# K1a: the info helper writes nothing: no redirection into a file other than /dev/null, no tee/dd/echo-into-sysfs
# (review MINOR-7: the allowed redirections are stripped token by token, so any other '>' on the same line is still seen)
if grep -vE '^[[:space:]]*#' "$INFO" | sed -E 's#2>&1##g; s#2?>[[:space:]]*/dev/null##g' | grep -q '>'; then die "fs-k1a-info.sh redirects output into a file"; fi
if grep -vE '^[[:space:]]*#' "$INFO" | grep -qE '(^|[^[:alnum:]_-])(tee|dd|insmod|rmmod|modprobe|mknod|mkdir|rmdir|rm|mv|cp|ln|touch|chmod|chown|sysctl|mount|umount|kill|setsid|ip|ifconfig|reboot|fs-done)([^[:alnum:]_-]|$)'; then die "fs-k1a-info.sh calls a writing command"; fi

for b in "$BUSYBOX" "$FS_REBOOT" "$FS_SUPERVISE" "$FS_REBOOT_FINAL"; do
    file -b "$b" | grep -q "ARM aarch64" || die "$b is not aarch64"
    readelf -h "$b" | grep -q "Type:.*EXEC" || die "$b is not a static executable (ET_EXEC)"
    if readelf -l "$b" | grep -q INTERP; then die "$b has a program interpreter"; fi
    if readelf -d "$b" 2>/dev/null | grep -q NEEDED; then die "$b has dynamic dependencies"; fi
done

python3 -I - "$BUSYBOX" > "$W/applets.txt" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"\x00[\x00[[\x00")
assert i >= 0, "applet table not found"
names, p = [], i + 1
while True:
    j = d.index(b"\x00", p)
    s = d[p:j]
    if not s or not all(0x21 <= c < 0x7f for c in s): break
    if names and s.decode() <= names[-1]: break
    names.append(s.decode()); p = j + 1
assert len(names) > 100, "implausibly short applet table"
print("\n".join(names))
PY
missing=""
for a in $REQUIRED_APPLETS; do grep -qx "$a" "$W/applets.txt" || missing="$missing $a"; done
[ -z "$missing" ] || die "busybox applet table lacks:$missing"
if grep -qiE 'b2|blake' "$W/applets.txt"; then die "busybox has a BLAKE2 applet"; fi

# stock images (AOSP tooling): header fields from the stock boot; module index from the stock vendor_boot
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$STOCK_BOOT" --out "$W/stock" > "$W/stock.txt"
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$STOCK_VBOOT" --out "$W/vstock" > /dev/null
[ "$(sha "$W/stock/kernel")" = "$EXPECT_STOCK_KERNEL" ] || die "stock kernel bytes differ from the pinned v2.7 kernel"
[ ! -e "$W/vstock/vendor_ramdisk01" ] || die "more than one vendor ramdisk fragment"
mkdir -p "$W/vx"
( cd "$W/vx" && lz4 -dc "$W/vstock/vendor_ramdisk00" | cpio -id --quiet --no-absolute-filenames )
( cd "$W/vx" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/vendor.list"
[ "$(sha "$W/vendor.list")" = "$EXPECT_VLIST" ] && [ "$(wc -l < "$W/vendor.list")" -eq "$EXPECT_VLIST_N" ] \
    || die "vendor ramdisk file list differs from the pin"
[ "$(sha "$W/vx/lib/modules/modules.load.recovery")" = "$EXPECT_MODLIST" ] \
    && [ "$(wc -l < "$W/vx/lib/modules/modules.load.recovery")" -eq "$EXPECT_MODLIST_N" ] \
    || die "vendor modules.load.recovery differs from the pinned v2.7 list"
for kv in MODDEP_SHA:modules.dep MODSOFTDEP_SHA:modules.softdep; do
    v=$(sed -n "s/^${kv%%:*}=\([0-9a-f]\{64\}\)$/\1/p" "$INIT_SRC")
    [ -n "$v" ] && [ "$v" = "$(sha "$W/vx/lib/modules/${kv#*:}")" ] || die "init.sh ${kv%%:*} is not the pinned vendor_boot's ${kv#*:}"
done
python3 -I "$MODCHECK" "$MODLIST_SRC" "$W/vx/lib/modules" "$MOD_ROOTS" > "$W/module-list-check.txt" 2>&1 \
    || { cat "$W/module-list-check.txt" >&2; die "module list check failed (stage3d/tools/module-list-check.py)"; }

# --- c. the ramdisk -----------------------------------------------------------------
R=$W/rd
mkdir -p "$R/bin" "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp" "$R/config" "$R/lib/fs"
sed "s/@NONCE@/$NONCE/" "$INIT_SRC" > "$R/init"
grep -q "^NONCE=\"$NONCE\"\$" "$R/init"                                  || die "nonce substitution failed"
[ "$(grep -c '@NONCE@' "$R/init" || true)" -eq 0 ]                       || die "placeholder left in init"
[ "$(wc -c < "$R/init")" -eq $(( $(wc -c < "$INIT_SRC") + 16 - 7 )) ]    || die "init changed beyond the nonce"
chmod 0755 "$R/init"
install -m 0755 "$BUSYBOX"         "$R/bin/busybox"
install -m 0755 "$FS_REBOOT"       "$R/bin/fs-reboot"
install -m 0755 "$FS_REBOOT_FINAL" "$R/bin/fs-reboot-final"
install -m 0755 "$FS_SUPERVISE"    "$R/bin/fs-supervise"
install -m 0755 "$FS_DONE"         "$R/bin/fs-done"
install -m 0755 "$RUNNER"          "$R/bin/fs-k1a"
install -m 0644 "$PID1_HOLD"       "$R/lib/fs/pid1-hold.sh"
install -m 0644 "$FSB1_ENC"        "$R/lib/fs/fsb1-enc.sh"
install -m 0644 "$FSB1_PACE"       "$R/lib/fs/fsb1-pace.sh"
install -m 0644 "$INFO"            "$R/lib/fs/fs-k1a-info.sh"
install -m 0644 "$MODLIST_SRC"     "$R/lib/fs/modules.load"
if [ -n "${FS_TEST_INJECT:-}" ]; then                                     # NEGATIVE FIXTURE ONLY: SRC:RAMDISK/PATH
    mkdir -p "$R/$(dirname "${FS_TEST_INJECT#*:}")"; install -m 0644 "${FS_TEST_INJECT%%:*}" "$R/${FS_TEST_INJECT#*:}"
fi
find "$R" -exec touch -h -d @0 {} +                                      # fixed mtimes (the nonce still differs per image)
( cd "$R" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/ramdisk.list"
printf '%s\n' bin bin/busybox bin/fs-done bin/fs-k1a bin/fs-reboot bin/fs-reboot-final bin/fs-supervise \
    config dev init lib lib/fs lib/fs/fs-k1a-info.sh lib/fs/fsb1-enc.sh lib/fs/fsb1-pace.sh lib/fs/modules.load lib/fs/pid1-hold.sh proc run sys tmp \
    | LC_ALL=C sort > "$W/ramdisk.expected"
cmp -s "$W/ramdisk.list" "$W/ramdisk.expected" || { diff "$W/ramdisk.expected" "$W/ramdisk.list" >&2 || true; die "ramdisk contents differ from the expected list"; }
if find "$R" -type l | grep -q .; then die "symlink in the staged ramdisk"; fi
( cd "$R" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | while read -r f; do printf '%s  %s  %s\n' "$(sha256sum "$f" | cut -c1-64)" "$(stat -c %s "$f")" "$f"; done ) > "$W/ramdisk.sha256"
while read -r p; do
    if [ -d "$R/$p" ] && [ -d "$W/vx/$p" ] && [ ! -L "$W/vx/$p" ]; then continue; fi
    die "collision with the vendor ramdisk: /$p"
done < <(LC_ALL=C comm -12 "$W/ramdisk.list" "$W/vendor.list")
mkdir -p "$W/union"; cp -a "$W/vx/." "$W/union/"; cp -a "$R/." "$W/union/"
for p in etc/ld.so.preload etc/ld.so.cache usr usr/lib/libc.so.6 lib/libc.so.6 lib/ld-linux-aarch64.so.1 valve; do
    if [ -e "$W/union/$p" ] || [ -L "$W/union/$p" ]; then die "loader path present in the union initramfs: /$p"; fi
done
( cd "$W/union" && find . -type f -print0 | xargs -0 file | grep -E 'ELF .*(executable|shared object)' | cut -d: -f1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/union-elf.txt"
printf '%s\n' bin/busybox bin/fs-reboot bin/fs-reboot-final bin/fs-supervise | LC_ALL=C sort > "$W/union-elf.expected"
cmp -s "$W/union-elf.txt" "$W/union-elf.expected" || { diff "$W/union-elf.expected" "$W/union-elf.txt" >&2 || true; die "unexpected ELF executables/shared objects in the union initramfs"; }

( cd "$R" && LC_ALL=C sort "$W/ramdisk.list" | cpio -o -H newc -R 0:0 --reproducible --quiet ) > "$W/ramdisk.cpio"
lz4 -l -9 -q "$W/ramdisk.cpio" "$W/ramdisk.lz4"

# --- d. repack: OUR kernel, our ramdisk, stock header fields ------------------------
os_version=$(awk -F': ' '/^os version/{print $2}' "$W/stock.txt")
os_patch=$(awk -F': ' '/^os patch level/{print $2}' "$W/stock.txt")
hv=$(awk -F': ' '/^boot image header version/{print $2}' "$W/stock.txt")
$PYA "$AOSP/mkbootimg.py" --header_version "$hv" \
    --kernel "$K1A_KERNEL" --ramdisk "$W/ramdisk.lz4" \
    --os_version "$os_version" --os_patch_level "$os_patch" \
    --output "$W/boot-k1a.img"
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$W/boot-k1a.img" --out "$W/ours" > "$W/ours.txt"
[ "$(sha "$W/ours/kernel")"  = "$EXPECT_K1A_KERNEL" ]      || die "kernel bytes in the image are not the pinned K1a Image"
[ "$(sha "$W/ours/ramdisk")" = "$(sha "$W/ramdisk.lz4")" ] || die "ramdisk mismatch after repack"
diff "$W/stock.txt" "$W/ours.txt" > "$W/header-diff.txt" || true
[ "$(wc -l < "$W/stock.txt")" -eq "$(wc -l < "$W/ours.txt")" ] || die "header field count differs"
changed=$(paste -d'|' "$W/stock.txt" "$W/ours.txt" | awk -F'|' '$1!=$2{split($1,a,":"); print a[1]}' | sort | tr '\n' ';')
[ "$changed" = "kernel_size;ramdisk size;" ] || die "unexpected header differences: '$changed'"
grep -qx 'boot.img signature size: 0' "$W/stock.txt"     || die "stock v2.7 boot.img signature size is not 0"
grep -qx 'boot.img signature size: 0' "$W/ours.txt"      || die "signature section not as intended"
grep -qx "kernel_size: $EXPECT_K1A_KERNEL_SIZE" "$W/ours.txt" || die "header kernel size is not the K1a Image size"
mkdir -p "$W/back" && ( cd "$W/back" && lz4 -dc "$W/ours/ramdisk" | cpio -id --quiet --no-absolute-filenames )
( cd "$W/back" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/back.list"
cmp -s "$W/back.list" "$W/ramdisk.list" || die "image ramdisk path list differs from the staged list"
( cd "$W/back" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | while read -r f; do printf '%s  %s  %s\n' "$(sha256sum "$f" | cut -c1-64)" "$(stat -c %s "$f")" "$f"; done ) > "$W/back.sha256"
cmp -s "$W/back.sha256" "$W/ramdisk.sha256" || die "a file inside the image differs from the staged file"
[ "$(stat -c %a "$W/back/init")" = 755 ] || die "init is not mode 0755 inside the image"

# c (on the final image): the stage-3d scan (reads the image's own kernel config, i.e. OUR kernel's)
mkdir -p "$W/scanin" "$W/scanout"
cp "$W/ramdisk.list" "$W/applets.txt" "$W/scanin/"
bash "$SCAN" "$W/scanin" "$W/scanout" "$W/boot-k1a.img" > "$W/scan.stdout" 2>&1 || { cat "$W/scan.stdout" >&2; die "ramdisk-scan-3d.sh failed"; }
S=$W/scanout/ramdisk-scan.txt
grep -q '(= the pinned stock vendor_boot)$' "$S"                               || die "scan: the scanned vendor_boot is not the pinned v2.7 one"
grep -q '; identical to build ramdisk.list: yes$' "$S"                         || die "scan: unpacked ramdisk differs from ramdisk.list"
ours_hits=$(sed -n '/^## byte scan: our ramdisk/,/^## byte scan: vendor/p' "$S" | grep '^HIT ' || true)
[ -z "$ours_hits" ]                                                            || die "scan: BLAKE2 indicators in our ramdisk: '$ours_hits'"
sed -n '/^## byte scan: our ramdisk/,/^## byte scan: vendor/p' "$S" | grep -q ', 0 with BLAKE2 indicators$' || die "scan: our ramdisk summary missing"
sed -n '/^## byte scan: vendor ramdisk/,/^## positive control/p' "$S" | grep -q ', 0 with BLAKE2 indicators$' || die "scan: BLAKE2 indicators in the vendor ramdisk"
sed -n '/^## positive control/,/^## stock kernel/p' "$S" | grep -q '^HIT usr/bin/b2sum:' || die "scan: positive control did not hit"
present=$(grep '^PRESENT in' "$S" || true)
[ -z "$present" ]                                                              || die "scan: unexpected loader/collision paths: '$present'"
sed -n '/ELF executables (ET_EXEC/,/^$/p' "$S" | grep -qx '(none)'             || die "scan: ELF executables in the vendor ramdisk"
grep -qx '# CONFIG_CRYPTO_USER_API_HASH is not set' "$S"                       || die "scan: kernel AF_ALG hash state not confirmed"

# --- publish ---------------------------------------------------------------------------
mkdir -p "$OUT"
mv "$W/boot-k1a.img" "$OUT/boot-k1a.img"
cp "$W/header-diff.txt" "$W/ramdisk.list" "$W/ramdisk.sha256" "$W/applets.txt" "$W/gitcheck.txt" "$W/avb-check.txt" "$W/module-list-check.txt" "$W/kernel-check.txt" "$OUT/"
cp "$S" "$OUT/ramdisk-scan.txt"

# --- e. manifest --------------------------------------------------------------------------
src_of() {
    case "$1" in
        init) echo "k1a/init.sh ($(sha "$INIT_SRC")) with nonce" ;;
        bin/busybox) echo "$BUSYBOX" ;;
        bin/fs-reboot) echo "$FS_REBOOT" ;;
        bin/fs-reboot-final) echo "$FS_REBOOT_FINAL" ;;
        bin/fs-supervise) echo "$FS_SUPERVISE" ;;
        bin/fs-done) echo "common/target/fs-done" ;;
        bin/fs-k1a) echo "k1a/fs-k1a.sh" ;;
        lib/fs/pid1-hold.sh) echo "common/target/pid1-hold.sh" ;;
        lib/fs/fsb1-enc.sh) echo "common/target/fsb1-enc.sh" ;;
        lib/fs/fsb1-pace.sh) echo "common/target/fsb1-pace.sh" ;;
        lib/fs/fs-k1a-info.sh) echo "k1a/fs-k1a-info.sh" ;;
        lib/fs/modules.load) echo "stage3d/modules.load.v66 (the proven v66 set, J-129)" ;;
        *) echo "?" ;;
    esac
}
IMG_SHA=$(sha "$OUT/boot-k1a.img")
{
echo "FrameShift Quest 3 K1a image (our own kernel boots: the FrameShift-built K1a kernel + the stage-3d PID 1 without display parts) — ONE ATTEMPT ONLY, never reuse"
DL=$(sed -n 's/^DEADLINE=\([0-9]*\)$/\1/p' "$INIT_SRC")
echo "For the Quest 3 units on Horizon OS v2.7 (build 52433670036000520; vendor_boot = the slot's own stock one, module index pinned in init.sh; vbmeta digest 66b76196...f12a) only; Unit 2 first. fastboot boot ONLY. No Valve file. No panel write (the bootloader splash stays as the kernel's display driver keeps it until the reboot). One runner, fs-k1a: one FSB1 record exp=k1a (kernel,config,mem,modules,kmsg,fs,usb,log), read-only. Gadget ACM only (J-179). PID 1 deadline T0+$DL s, backstop T0+$((DL + 1)) s (init.sh DEADLINE); ack window 150 s; reboot to the bootloader ~1 s after fs-done"
echo "built:            $STAMP"
echo "nonce:            $NONCE   (USB serial FS-$NONCE)"
[ -n "$OVERRIDES" ] && echo "TEST OVERRIDES:   $OVERRIDES(negative fixtures only; NOT a candidate image)"
echo "OUTPUT IMAGE:     boot-k1a.img  size=$(sz "$OUT/boot-k1a.img")  sha256=$IMG_SHA"
echo
echo "## the kernel (kernel-check.txt)"
echo "K1a kernel        $(sha "$K1A_KERNEL")  size=$(sz "$K1A_KERNEL")  (pinned; byte-identical in the output: AOSP re-unpack)"
echo "K1a banner        $EXPECT_K1A_BANNER"
echo "K1a config        $(sha "$K1A_CONFIG")  k1a/kernel/k1a.config (= the Image's IKCONFIG; the device reports sha256(zcat /proc/config.gz), which must equal it)"
echo "kgate result      $(sha "$K1A_GATE")  tools/kgate/validation/quest3/check-k1a.json (gate-mode PASS, build k1a, for this Image and config)"
echo
echo "## inputs (sha256 enforced unless noted)"
echo "stock boot        $(sha "$STOCK_BOOT")  $STOCK_BOOT  (header fields only; its kernel $(sha "$W/stock/kernel") is NOT in the output)"
echo "stock vendor_boot $(sha "$STOCK_VBOOT")  $STOCK_VBOOT  (NOT in the output: the unit's slot provides it)"
echo "vbmeta            $(sha "$VBMETA")  $VBMETA"
echo "vbmeta_system     $(sha "$VBMETA_SYSTEM")  $VBMETA_SYSTEM"
echo "vbmeta digest     $EXPECT_VBMETA_DIGEST  (computed = Unit 2 runtime ro.boot.vbmeta.digest; avb-check.txt, tool $(sha "$AVBCHECK"))"
echo "CAVEAT            the bytes on the unit's slot are INFERRED from the OTA (the runtime vbmeta digest, kernel string, vendor command line and bootconfig match), NOT read back: AVB's hash descriptors are not enforced at boot on these units, and this image's boot hash does NOT match vbmeta"
echo "device-side check init.sh refuses to load any module unless /lib/modules/modules.dep = $(sha "$W/vx/lib/modules/modules.dep") and modules.softdep = $(sha "$W/vx/lib/modules/modules.softdep") (the pinned vendor_boot's): mismatch -> no module, reboot error-modules at T0+60 s"
echo "vendor modules    $(sha "$W/vx/lib/modules/modules.load.recovery")  lib/modules/modules.load.recovery ($EXPECT_MODLIST_N modules; provenance only, NOT loaded as a list)"
echo "loaded modules    $(sha "$MODLIST_SRC")  stage3d/modules.load.v66 -> /lib/fs/modules.load ($EXPECT_FSMODLIST_N modules, Meta's STOCK v2.7 module files from the slot's vendor ramdisk; module-list-check.txt, tool $(sha "$MODCHECK"))"
echo "vendor file list  $(sha "$W/vendor.list")  ($EXPECT_VLIST_N entries)"
echo "AOSP mkbootimg    $EXPECT_AOSP  (E1 fs_gitcheck CLEAN; helper $(sha "$GITCHECK"))"
echo "E1 notes          ${E1NOTES:-none}"
echo "ramdisk-scan-3d   $(sha "$SCAN")  (recorded; output in ramdisk-scan.txt)"
echo "init.sh source    $(sha "$INIT_SRC")  (recorded)"
echo "fs-k1a.sh         $(sha "$RUNNER")  (recorded)"
echo "fs-k1a-info.sh    $(sha "$INFO")  (recorded)"
echo "fsb1-pace.sh      $(sha "$FSB1_PACE")  (pinned)"
echo "build-image.sh    $(sha "$0")  (recorded)"
echo "checkout HEAD     $CHECKOUT_HEAD  (the image's sources are committed there)"
echo "ramdisk.cpio      $(sha "$W/ramdisk.cpio")  size=$(sz "$W/ramdisk.cpio")"
echo "ramdisk.lz4       $(sha "$W/ramdisk.lz4")  size=$(sz "$W/ramdisk.lz4")"
echo
echo "## ramdisk files (sha256  size  path  source); directories: $(cd "$R" && find . -mindepth 1 -type d | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
while read -r h s p; do echo "$h  $s  /$p  $(src_of "$p")"; done < "$W/ramdisk.sha256"
echo
echo "## checks passed"
echo "K1a kernel pinned (bytes, size, banner, IKCONFIG = k1a.config, the module-loader vermagic '<our release> SMP preempt mod_unload modversions aarch64' present; the stock modules carry the same flags) and gated (kgate PASS exit 0 for exactly this Image and config: 2601/2601 vendor-required CRCs, module_layout $EXPECT_GATE_LAYOUT, 0 changed/removed vmlinux exports);"
echo "AVB: vbmeta digest = Unit 2 runtime, stock boot/vendor_boot hash descriptors MATCH; module list (95) present, closed under modules.dep/softdep, display/USB/backlight/LED/fan closure inside, no v2.7-only module reachable; E1 git check; every pin above;"
echo "static ELF (aarch64, ET_EXEC, no INTERP/NEEDED) for busybox, fs-reboot, fs-reboot-final, fs-supervise; applets present: $REQUIRED_APPLETS; no BLAKE2 applet;"
echo "no debugfs, only the five reviewed mounts, no backlight_changes_blocked, no DRM/backlight/panel path in any non-comment script line; fs-k1a-info.sh writes nothing (lexical);"
echo "exact ramdisk list; no symlinks; no vendor collision (only shared directories); union lacks /etc/ld.so.preload /etc/ld.so.cache /usr /lib/libc.so.6 /lib/ld-linux-aarch64.so.1 /valve;"
echo "only the 4 expected ELF files in the union; BLAKE2 scan of the final image: no hit; AF_ALG hash off in the K1a kernel's config;"
echo "kernel bytes = the K1a Image; header differs from stock only in kernel size and ramdisk size (stock signature size already 0); every file in the image equals the staged file."
echo
echo "## header diff"
cat "$OUT/header-diff.txt"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
