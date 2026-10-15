#!/bin/bash
# FrameShift — build ONE Quest 3 stage-3d test image: the stage-3c interactive per-phase
# display run rebuilt for Quest 3 Unit 2's own stock Horizon OS v2.7 (build 52433670036000520,
# kernel 5.10.246-gd7102a837402) with the PM's stage-3d changes (stage3d/README.md): run 1 is a
# non-lit DISPLAY RESET (fs-pattern v0.7.1 "reset"), run 2 the per-eye picture (eyes swapped,
# pre-rotated by the roll). A separate image from stages 2a-3c (unchanged; their images stay
# reproducible); no Valve file. Derived from stage3c/build-image.sh. Run in WSL:
#   wsl.exe -e bash <repo>/devices/quest3/stage3d/build-image.sh
#
# Extends the PROVEN stage-1 builder (devices/quest3/stage1/build.sh): the same repack
# method (AOSP mkbootimg at the pinned commit, stock kernel bytes, stock header fields), on the
# stock v2.7 boot/vendor_boot from the official full OTA (q3_52433670036000520.zip; payload
# new_partition_info hashes and the AVB chain verified, stage3d/IMAGE.md "Inputs"). The v2.7
# stock boot.img already carries "boot.img signature size: 0", so the ONLY intended header
# difference is "ramdisk size". One image per attempt: a fresh nonce every run.
#
# Refuses (nonzero, nothing published) unless EVERY check passes:
#   0. AVB provenance (tools/avb-check.py): the pinned v2.7 vbmeta + vbmeta_system give the
#      vbmeta digest Unit 2 reported at run time (ro.boot.vbmeta.digest, 66b76196...f12a,
#      evidence/unit2-v27-baseline-20261012), and the boot and vendor_boot images match their
#      hash descriptors in that vbmeta;
#   a. E1 clean-checkout check of the AOSP mkbootimg tree
#      (devices/quest3/host/fs-gitcheck.sh: --git-dir/--work-tree, GIT_* unset,
#      core.worktree refused; FS-R-005 §5 E1);
#   b. pinned SHA-256 of every input: stock boot, vendor_boot, stock kernel,
#      the vendor module list (modules.load.recovery, 131 entries on v2.7; provenance only) and the
#      vendor ramdisk file list (143), OUR module list stage3d/modules.load.v66 (95: the proven v66 set,
#      PM decision J-129; tools/module-list-check.py: every entry present in the v2.7 vendor ramdisk,
#      the list closed under modules.dep/softdep, the display/USB/backlight/LED/fan closure inside it,
#      no excluded v2.7 module reachable, and none of a FIXED forbidden set of 38 (the 36 v2.7-only
#      modules + the 2 v66 debug modules) in or reachable from the list), vbmeta, vbmeta_system, busybox, fs-reboot,
#      fs-reboot-final, fs-supervise, fs-pattern (v0.7.1), the common target scripts (incl.
#      fsb1-pace.sh); fs-probe.sh (stage 3c's plus the v2.7 dmesg filter, J-141), init.sh, fs-phase.sh and fs-idle.sh are
#      recorded; static-ELF checks; the busybox applet table; no CR in the local
#      scripts; no debugfs (mount or path) in any non-comment script line
#      (PM decision J-109 #2);
#   c. the ramdisk: exact file list, no collision with the vendor ramdisk, the
#      union (vendor + ours) lacks /etc/ld.so.preload, /etc/ld.so.cache, /usr,
#      /lib/libc.so.6, /lib/ld-linux-aarch64.so.1, /valve; no ELF executable
#      or shared object other than the expected five;
#      stage3d/tools/ramdisk-scan-3d.sh (t1-ramdisk-scan.sh with the v2.7 vendor_boot) on
#      the FINAL image: no BLAKE2 hit;
#   d. repack and AOSP re-unpack: kernel bytes unchanged, only "ramdisk size" differs
#      (v2.7 stock signature size is already 0), every file inside the image equal to the
#      staged file;
#   e. MANIFEST.txt with the full SHA-256 and size of every input, every
#      ramdisk file and the image.
#
# Output: build/stage3d/<UTC>-<nonce>/ (gitignored): boot-stage3d.img,
# MANIFEST.txt, ramdisk.list, ramdisk.sha256, applets.txt, header-diff.txt,
# ramdisk-scan.txt, gitcheck.txt, avb-check.txt.
#
# FS_TEST_* variables point inputs elsewhere for the NEGATIVE fixtures only
# (test-builder.sh); every pin still applies, and the MANIFEST says so.
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
Q3=$ROOT/devices/quest3
HERE=$Q3/stage3d
S2A=$Q3/stage2a
COMMON=$Q3/common
AOSP=$ROOT/build/third_party/mkbootimg
FW=$ROOT/firmware/quest3/v2.7-user_ota
STOCK_BOOT=${FS_TEST_STOCK_BOOT:-$FW/boot.img}
STOCK_VBOOT=${FS_TEST_STOCK_VBOOT:-$FW/vendor_boot.img}
VBMETA=${FS_TEST_VBMETA:-$FW/vbmeta.img}
VBMETA_SYSTEM=$FW/vbmeta_system.img
AVBCHECK=$HERE/tools/avb-check.py
BUSYBOX=${FS_TEST_BUSYBOX:-$ROOT/build/third_party/busybox/busybox}
FS_REBOOT=${FS_TEST_FS_REBOOT:-$ROOT/build/stage1-tools/fs-reboot}
FS_SUPERVISE=${FS_TEST_FS_SUPERVISE:-$COMMON/build/fs-supervise}
FS_REBOOT_FINAL=${FS_TEST_FS_REBOOT_FINAL:-$COMMON/build/fs-reboot-final}
FS_PATTERN=${FS_TEST_FS_PATTERN:-$HERE/build/fs-pattern}
OUTBASE=${FS_TEST_OUTBASE:-$ROOT/build/stage3d}
INIT_SRC=${FS_TEST_INIT:-$HERE/init.sh}
RUNNER=$HERE/fs-phase.sh
PROBE=$HERE/fs-probe.sh
IDLE=${FS_TEST_IDLE:-$HERE/fs-idle.sh}
MODLIST_SRC=${FS_TEST_MODLIST:-$HERE/modules.load.v66}      # installed as /lib/fs/modules.load (init.sh loads it)
MODCHECK=$HERE/tools/module-list-check.py
MOD_ROOTS=msm_drm,dwc3-msm,leds-qti-tri-led,tps65132-regulator,blu_fw_driver,mp3314,pwm-qti-lpg,msm_ext_display,panel_event_notifier,dispcc0-anorak,dispcc1-anorak,ucsi_glink,pwm-tach-fan
PID1_HOLD=$COMMON/target/pid1-hold.sh
FSB1_ENC=$COMMON/target/fsb1-enc.sh
FSB1_PACE=${FS_TEST_FSB1_PACE:-$COMMON/target/fsb1-pace.sh}
FS_DONE=$COMMON/target/fs-done
SCAN=$HERE/tools/ramdisk-scan-3d.sh
GITCHECK=$Q3/host/fs-gitcheck.sh

# --- pins (each change is a reviewable change) ----------------------------------
EXPECT_AOSP=d2bb0af5ba6d3198a3e99529c97eda1be0b5a093
# v2.7 stock inputs: the official full OTA q3_52433670036000520.zip (sha256 e4c57710...2e04), payload.bin
# new_partition_info = these hashes; vbmeta digest = Unit 2's runtime ro.boot.vbmeta.digest (stage3d/IMAGE.md)
EXPECT_STOCK_BOOT=e32f98c74bcce5c25b098393f7804e19fbba2f0c2034c49a4fcf6aa9a8cdc024
EXPECT_STOCK_VBOOT=bc0dd14de41834a601513123b2225a677fa4212dfa4505bf964228cea40d2f5b
EXPECT_VBMETA=aae4af3a1740d568a1bcd1104f1b30b2998082def674e00c319acfab10faf215
EXPECT_VBMETA_SYSTEM=28f5ccc91f25665dda5db1abf1fc3bd3fcea58f30cb33827642cddf6f9c8bc50
EXPECT_VBMETA_DIGEST=66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a   # Unit 2 runtime (getprop, 2026-10-12)
EXPECT_KERNEL=db61c073962bf1df38cbb09cbb01f03e5595822754ffea1dc75166555f7d545e          # 5.10.246-gd7102a837402 (= extracted/v2.7-user_ota/Image)
EXPECT_KREL="Linux version 5.10.246-gd7102a837402 "
EXPECT_MODLIST=0dd1deb02e5e9183e66c14682f94339da34fd56152a12208b22868ca231f66f4         # lib/modules/modules.load.recovery (= modules.load)
EXPECT_MODLIST_N=131
EXPECT_VLIST=c01d89a16159be9ad67ee6bf32fd11a14827068a4e23e298f33bdea0d621b2ce           # sorted vendor ramdisk path list
EXPECT_VLIST_N=143
# OUR module list (PM decision J-129): stage 3c's v66 modules.load.recovery minus debug-regulator and
# qti-regmap-debugfs, in v66 order; the 36 v2.7-only modules are never loaded
EXPECT_FSMODLIST=1b93d77d029146cf93289be87de51514c6ab7b96987f9c467a7f13f6e2a6463f
EXPECT_FSMODLIST_N=95
EXPECT_BUSYBOX=c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02         # stage 1
EXPECT_FS_REBOOT=c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29       # stage 1
EXPECT_FS_SUPERVISE=77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74    # common rev 4 README
EXPECT_FS_REBOOT_FINAL=ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e # common rev 4 README
EXPECT_PID1_HOLD=4294c9d57f3a94eba9847596aa614f557e7b4278cfeb5a22e38955fdd5b81dc4       # common rev 5 (magenta LED on no-host-ack)
EXPECT_FSB1_ENC=11e44d2fa386d06c596c03ff54ecfb5aeeea4790a560c8e65bf26e76733bf1a7        # common rev 5 (fsb1_emit: empty line first)
EXPECT_FS_DONE=7ad5f1106acd828fa3e9d6da9cfa0e50d66431b4b2d3a951ce39f12375064959         # common rev 4
EXPECT_FS_PATTERN=bfafad97c7ca11ef4e41a6be8aae4fde5ca529d8955d9b77d6fc603495049a9a     # stage3d v0.7.1 (J-141 MAXMODES fix; README, BUILD-RECORD.txt)
EXPECT_FSB1_PACE=71ce176e09c21b2304b0be90543f2c0da26b0a5c0aed3c3bb23cf8a2b412404c        # common, stage 3b (paced emission; unchanged)
# every applet init.sh, the helpers, fs-phase, fs-probe.sh, fs-idle.sh, fsb1-enc.sh, fsb1-pace.sh, pid1-hold.sh and fs-done call
REQUIRED_APPLETS="sh mount mknod mkdir cut cat echo printf sync reboot sleep insmod mdev ls tr sed grep basename setsid kill ln uname sha256sum stty mv rm chmod base64 awk wc head mkfifo tail dmesg"

# FS_TEST_NONCE/FS_TEST_STAMP: the reproducibility fixture only (test-builder.sh rebuilds with the
# same nonce and stamp and requires a bit-identical image); the MANIFEST then says TEST OVERRIDES,
# and the observer and test-image.sh refuse such an image.
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
# its NOTE lines (e.g. "mode bits not checkable here" on a drvfs checkout) are carried into
# gitcheck.txt and the MANIFEST, never dropped (fix round 6)
E1NOTES=$(grep '^NOTE' "$W/gitcheck.err" | tr '\n' ' ' || true)
{ echo "E1 fs_gitcheck $AOSP at $EXPECT_AOSP: CLEAN (helper sha256=$(sha "$GITCHECK"))"; cat "$W/gitcheck.err"; } > "$W/gitcheck.txt"
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP
export PYTHONPYCACHEPREFIX="$W/pycache" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
# AOSP tools import their own gki/ package (no -I), but ignore PYTHON* variables (-E),
# user site (-s), never write bytecode (-B) and read none from the AOSP tree (pycache_prefix)
PYA="python3 -E -s -B -X pycache_prefix=$W/pycache"

# --- b. pinned inputs -------------------------------------------------------------
need() { [ -f "$1" ] && [ ! -L "$1" ] || die "input missing or not a regular file: $1"; }
pin() {  # pin FILE EXPECT LABEL
    need "$1"
    [ "$(sha "$1")" = "$2" ] || die "$3 hash differs from the pin ($1: $(sha "$1") != $2)"
}
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
pin "$FS_PATTERN"      "$EXPECT_FS_PATTERN"      "fs-pattern"
pin "$MODLIST_SRC"     "$EXPECT_FSMODLIST"       "module list (modules.load.v66)"
[ "$(wc -l < "$MODLIST_SRC")" -eq "$EXPECT_FSMODLIST_N" ] || die "module list does not have $EXPECT_FSMODLIST_N entries"
[ "$(tr -cd '\r' < "$MODLIST_SRC" | wc -c)" -eq 0 ] || die "CR characters in $MODLIST_SRC"
need "$MODCHECK"
for f in "$INIT_SRC" "$RUNNER" "$PROBE" "$IDLE" "$SCAN"; do need "$f"; done
for f in "$INIT_SRC" "$RUNNER" "$PROBE" "$IDLE" "$PID1_HOLD" "$FSB1_ENC" "$FSB1_PACE" "$FS_DONE"; do
    [ "$(tr -cd '\r' < "$f" | wc -c)" -eq 0 ] || die "CR characters in $f (must be LF only)"
    head -1 "$f" | grep -qx '#!/bin/busybox sh' || die "$f: shebang is not #!/bin/busybox sh"
done
# stage 3c (PM decision J-109 #2): no debugfs mount or path in any script line that is not a comment.
# A LEXICAL guard only (build review NIT-2): it catches the literal words "debugfs" and "/sys/kernel/debug"
# in the scripts and nothing else (not a path built at run time, not a binary, not a mount done by another
# program). The run-time evidence is the harness's inotify watch on a fake /sys/kernel/debug in every
# scenario (test-image.sh, c-no-debugfs) and check_static.py's "no debugfs path in the fs-pattern device build".
for f in "$INIT_SRC" "$RUNNER" "$PROBE" "$IDLE" "$PID1_HOLD" "$FSB1_ENC" "$FSB1_PACE" "$FS_DONE"; do
    if grep -vE '^[[:space:]]*#' "$f" | grep -qiE 'debugfs|/sys/kernel/debug'; then die "debugfs in a non-comment line of $f"; fi
done
# build review (R-B helper, mutations 7a-7c): the debugfs words can be hidden (quotes, variables, octal escapes), so
# every non-comment line that names mount/umount must also be one of the five reviewed mounts of init.sh (proc,
# sysfs, the two tmpfs, configfs). Still a lint over the script text, not a proof (a computed command name passes).
MOUNT_WHITELIST='$BB mount -t proc  proc  /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t tmpfs -o mode=0755,size=4m tmpfs /dev
$BB mount -t tmpfs -o mode=0755,size=4m tmpfs /run
mount -t configfs none /config 2>/dev/null'
for f in "$INIT_SRC" "$RUNNER" "$PROBE" "$IDLE" "$PID1_HOLD" "$FSB1_ENC" "$FSB1_PACE" "$FS_DONE"; do
    badm=$(grep -vE '^[[:space:]]*#' "$f" | grep -E '(^|[^[:alnum:]_-])u?mount([^[:alnum:]_-]|$)' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -vxF "$MOUNT_WHITELIST" || true)
    [ -z "$badm" ] || die "mount line not in the reviewed whitelist in $f: $(printf '%s' "$badm" | head -1)"
done
# stage 3d (PM decision J-129 #2): backlight_changes_blocked stays as the driver sets it; no script names it
# outside a comment (lexical, like the debugfs guard)
for f in "$INIT_SRC" "$RUNNER" "$PROBE" "$IDLE" "$PID1_HOLD" "$FSB1_ENC" "$FSB1_PACE" "$FS_DONE"; do
    if grep -vE '^[[:space:]]*#' "$f" | grep -q 'backlight_changes_blocked'; then die "backlight_changes_blocked in a non-comment line of $f"; fi
done
# build review (R-B helper, mutation 6): the idle limit never writes a tty or the console (lexical, as above)
if grep -vE '^[[:space:]]*#' "$IDLE" | grep -qE 'ttyGS|/dev/tty|/dev/console'; then die "fs-idle.sh names a tty or the console in a non-comment line"; fi

for b in "$BUSYBOX" "$FS_REBOOT" "$FS_SUPERVISE" "$FS_REBOOT_FINAL" "$FS_PATTERN"; do
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

# stock images (AOSP tooling), kernel and vendor module list
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$STOCK_BOOT" --out "$W/stock" > "$W/stock.txt"
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$STOCK_VBOOT" --out "$W/vstock" > /dev/null
[ "$(sha "$W/stock/kernel")" = "$EXPECT_KERNEL" ] || die "stock kernel bytes differ from the pinned v2.7 kernel"
grep -aqF "$EXPECT_KREL" "$W/stock/kernel" || die "stock kernel release string is not 5.10.246-gd7102a837402"
[ ! -e "$W/vstock/vendor_ramdisk01" ] || die "more than one vendor ramdisk fragment"
mkdir -p "$W/vx"
( cd "$W/vx" && lz4 -dc "$W/vstock/vendor_ramdisk00" | cpio -id --quiet --no-absolute-filenames )
( cd "$W/vx" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/vendor.list"
[ "$(sha "$W/vendor.list")" = "$EXPECT_VLIST" ] && [ "$(wc -l < "$W/vendor.list")" -eq "$EXPECT_VLIST_N" ] \
    || die "vendor ramdisk file list differs from the pin"
[ "$(sha "$W/vx/lib/modules/modules.load.recovery")" = "$EXPECT_MODLIST" ] \
    && [ "$(wc -l < "$W/vx/lib/modules/modules.load.recovery")" -eq "$EXPECT_MODLIST_N" ] \
    || die "vendor modules.load.recovery differs from the pinned v2.7 list"
# the device-side pins in init.sh (image review B) must be the pinned vendor_boot's modules.dep / modules.softdep
for kv in MODDEP_SHA:modules.dep MODSOFTDEP_SHA:modules.softdep; do
    v=$(sed -n "s/^${kv%%:*}=\([0-9a-f]\{64\}\)$/\1/p" "$INIT_SRC")
    [ -n "$v" ] && [ "$v" = "$(sha "$W/vx/lib/modules/${kv#*:}")" ] || die "init.sh ${kv%%:*} is not the pinned vendor_boot's ${kv#*:}"
done
# our module list against the v2.7 vendor modules (J-129): present, closed, covers the roots, excludes the rest
python3 -I "$MODCHECK" "$MODLIST_SRC" "$W/vx/lib/modules" "$MOD_ROOTS" > "$W/module-list-check.txt" 2>&1 \
    || { cat "$W/module-list-check.txt" >&2; die "module list check failed (tools/module-list-check.py)"; }

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
install -m 0755 "$RUNNER"          "$R/bin/fs-phase"
install -m 0755 "$FS_PATTERN"      "$R/bin/fs-pattern"
install -m 0644 "$PID1_HOLD"       "$R/lib/fs/pid1-hold.sh"
install -m 0644 "$FSB1_ENC"        "$R/lib/fs/fsb1-enc.sh"
install -m 0644 "$FSB1_PACE"       "$R/lib/fs/fsb1-pace.sh"
install -m 0644 "$PROBE"           "$R/lib/fs/fs-probe.sh"
install -m 0644 "$IDLE"            "$R/lib/fs/fs-idle.sh"
install -m 0644 "$MODLIST_SRC"     "$R/lib/fs/modules.load"
if [ -n "${FS_TEST_INJECT:-}" ]; then                                     # NEGATIVE FIXTURE ONLY: SRC:RAMDISK/PATH
    mkdir -p "$R/$(dirname "${FS_TEST_INJECT#*:}")"; install -m 0644 "${FS_TEST_INJECT%%:*}" "$R/${FS_TEST_INJECT#*:}"
fi
find "$R" -exec touch -h -d @0 {} +                                      # fixed mtimes (the nonce still differs per image)
( cd "$R" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/ramdisk.list"
printf '%s\n' bin bin/busybox bin/fs-done bin/fs-pattern bin/fs-phase bin/fs-reboot bin/fs-reboot-final bin/fs-supervise \
    config dev init lib lib/fs lib/fs/fs-idle.sh lib/fs/fs-probe.sh lib/fs/fsb1-enc.sh lib/fs/fsb1-pace.sh lib/fs/modules.load lib/fs/pid1-hold.sh proc run sys tmp \
    | LC_ALL=C sort > "$W/ramdisk.expected"
cmp -s "$W/ramdisk.list" "$W/ramdisk.expected" || { diff "$W/ramdisk.expected" "$W/ramdisk.list" >&2 || true; die "ramdisk contents differ from the expected list"; }
if find "$R" -type l | grep -q .; then die "symlink in the staged ramdisk"; fi
( cd "$R" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | while read -r f; do printf '%s  %s  %s\n' "$(sha256sum "$f" | cut -c1-64)" "$(stat -c %s "$f")" "$f"; done ) > "$W/ramdisk.sha256"
# collisions: a path in both ramdisks must be a directory in both
while read -r p; do
    if [ -d "$R/$p" ] && [ -d "$W/vx/$p" ] && [ ! -L "$W/vx/$p" ]; then continue; fi
    die "collision with the vendor ramdisk: /$p"
done < <(LC_ALL=C comm -12 "$W/ramdisk.list" "$W/vendor.list")
# the union, unpacked in boot order (vendor first, then ours)
mkdir -p "$W/union"; cp -a "$W/vx/." "$W/union/"; cp -a "$R/." "$W/union/"
for p in etc/ld.so.preload etc/ld.so.cache usr usr/lib/libc.so.6 lib/libc.so.6 lib/ld-linux-aarch64.so.1 valve; do
    if [ -e "$W/union/$p" ] || [ -L "$W/union/$p" ]; then die "loader path present in the union initramfs: /$p"; fi
done
( cd "$W/union" && find . -type f -print0 | xargs -0 file | grep -E 'ELF .*(executable|shared object)' | cut -d: -f1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/union-elf.txt"
printf '%s\n' bin/busybox bin/fs-pattern bin/fs-reboot bin/fs-reboot-final bin/fs-supervise \
    | LC_ALL=C sort > "$W/union-elf.expected"
cmp -s "$W/union-elf.txt" "$W/union-elf.expected" || { diff "$W/union-elf.expected" "$W/union-elf.txt" >&2 || true; die "unexpected ELF executables/shared objects in the union initramfs"; }

( cd "$R" && LC_ALL=C sort "$W/ramdisk.list" | cpio -o -H newc -R 0:0 --reproducible --quiet ) > "$W/ramdisk.cpio"   # --reproducible: renumbered inodes, dev 0 (N1)
lz4 -l -9 -q "$W/ramdisk.cpio" "$W/ramdisk.lz4"

# --- d. repack: stock kernel bytes, our ramdisk, stock header fields ------------------
os_version=$(awk -F': ' '/^os version/{print $2}' "$W/stock.txt")
os_patch=$(awk -F': ' '/^os patch level/{print $2}' "$W/stock.txt")
hv=$(awk -F': ' '/^boot image header version/{print $2}' "$W/stock.txt")
$PYA "$AOSP/mkbootimg.py" --header_version "$hv" \
    --kernel "$W/stock/kernel" --ramdisk "$W/ramdisk.lz4" \
    --os_version "$os_version" --os_patch_level "$os_patch" \
    --output "$W/boot-stage3d.img"
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$W/boot-stage3d.img" --out "$W/ours" > "$W/ours.txt"
[ "$(sha "$W/ours/kernel")"  = "$(sha "$W/stock/kernel")" ] || die "KERNEL BYTES CHANGED"
[ "$(sha "$W/ours/ramdisk")" = "$(sha "$W/ramdisk.lz4")" ]  || die "ramdisk mismatch after repack"
diff "$W/stock.txt" "$W/ours.txt" > "$W/header-diff.txt" || true
[ "$(wc -l < "$W/stock.txt")" -eq "$(wc -l < "$W/ours.txt")" ] || die "header field count differs"
changed=$(paste -d'|' "$W/stock.txt" "$W/ours.txt" | awk -F'|' '$1!=$2{split($1,a,":"); print a[1]}' | sort | tr '\n' ';')
[ "$changed" = "ramdisk size;" ] || die "unexpected header differences: '$changed'"   # v2.7 stock signature size is 0 already
grep -qx 'boot.img signature size: 0' "$W/stock.txt"     || die "stock v2.7 boot.img signature size is not 0"
grep -qx 'boot.img signature size: 0' "$W/ours.txt"      || die "signature section not as intended"
# every file inside the final image equals the staged file
mkdir -p "$W/back" && ( cd "$W/back" && lz4 -dc "$W/ours/ramdisk" | cpio -id --quiet --no-absolute-filenames )
( cd "$W/back" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/back.list"
cmp -s "$W/back.list" "$W/ramdisk.list" || die "image ramdisk path list differs from the staged list"
( cd "$W/back" && find . -type f | sed 's#^\./##' | LC_ALL=C sort | while read -r f; do printf '%s  %s  %s\n' "$(sha256sum "$f" | cut -c1-64)" "$(stat -c %s "$f")" "$f"; done ) > "$W/back.sha256"
cmp -s "$W/back.sha256" "$W/ramdisk.sha256" || die "a file inside the image differs from the staged file"
[ "$(stat -c %a "$W/back/init")" = 755 ] || die "init is not mode 0755 inside the image"

# c (on the final image). t1-ramdisk-scan.sh reads <dir>/boot-stage1.img, ramdisk.list, applets.txt
mkdir -p "$W/scanin" "$W/scanout"
cp "$W/ramdisk.list" "$W/applets.txt" "$W/scanin/"
bash "$SCAN" "$W/scanin" "$W/scanout" "$W/boot-stage3d.img" > "$W/scan.stdout" 2>&1 || { cat "$W/scan.stdout" >&2; die "t1-ramdisk-scan.sh failed"; }
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
mv "$W/boot-stage3d.img" "$OUT/boot-stage3d.img"
cp "$W/header-diff.txt" "$W/ramdisk.list" "$W/ramdisk.sha256" "$W/applets.txt" "$W/gitcheck.txt" "$W/avb-check.txt" "$W/module-list-check.txt" "$OUT/"
cp "$S" "$OUT/ramdisk-scan.txt"

# --- e. manifest --------------------------------------------------------------------------
src_of() {
    case "$1" in
        init) echo "stage3d/init.sh ($(sha "$INIT_SRC")) with nonce" ;;
        bin/busybox) echo "$BUSYBOX" ;;
        bin/fs-reboot) echo "$FS_REBOOT" ;;
        bin/fs-reboot-final) echo "$FS_REBOOT_FINAL" ;;
        bin/fs-supervise) echo "$FS_SUPERVISE" ;;
        bin/fs-done) echo "common/target/fs-done" ;;
        bin/fs-phase) echo "stage3d/fs-phase.sh" ;;
        bin/fs-pattern) echo "$FS_PATTERN" ;;
        lib/fs/pid1-hold.sh) echo "common/target/pid1-hold.sh" ;;
        lib/fs/fsb1-enc.sh) echo "common/target/fsb1-enc.sh" ;;
        lib/fs/fsb1-pace.sh) echo "common/target/fsb1-pace.sh" ;;
        lib/fs/fs-probe.sh) echo "stage3d/fs-probe.sh (stage3c's + the v2.7 mode-validation dmesg filter, J-141)" ;;
        lib/fs/fs-idle.sh) echo "stage3d/fs-idle.sh (= stage3c/fs-idle.sh)" ;;
        lib/fs/modules.load) echo "stage3d/modules.load.v66 (the proven v66 set, J-129)" ;;
        *) echo "?" ;;
    esac
}
IMG_SHA=$(sha "$OUT/boot-stage3d.img")
{
echo "FrameShift Quest 3 stage-3d image (v2.7 interactive per-phase display run, fs-pattern v0.7.1) — ONE ATTEMPT ONLY, never reuse"
DL=$(sed -n 's/^DEADLINE=\([0-9]*\)$/\1/p' "$INIT_SRC")
echo "For the Quest 3 units on Horizon OS v2.7 (build 52433670036000520, kernel 5.10.246-gd7102a837402, vbmeta digest 66b76196...f12a; both units, J-131) only. No Valve file. Phases p0 r1 r2 [r3]: r1 = display reset, no picture (A: disable the handed-over CRTC, MODE_ID/ACTIVE/CRTC_ID 0 and its planes off; B: a dark re-enable on an all-black buffer to end the continuous splash; C: close, lastclose powers the panel off), r2 = 10 s (4 planes x 1032, zpos 0,0,1,1; per-eye picture, eyes=swap, roll=21), r3 = 5 s (red field) (fs-pattern compiled cap 10 s); one write: panel0-backlight brightness=127; idle limit 120 s; PID 1 deadline T0+$DL s, backstop T0+$((DL + 1)) s (init.sh DEADLINE)"
echo "built:            $STAMP"
echo "nonce:            $NONCE   (USB serial FS-$NONCE)"
[ -n "$OVERRIDES" ] && echo "TEST OVERRIDES:   $OVERRIDES(negative fixtures only; NOT a candidate image)"
echo "OUTPUT IMAGE:     boot-stage3d.img  size=$(sz "$OUT/boot-stage3d.img")  sha256=$IMG_SHA"
echo
echo "## inputs (sha256 enforced unless noted)"
echo "stock boot        $(sha "$STOCK_BOOT")  $STOCK_BOOT"
echo "stock vendor_boot $(sha "$STOCK_VBOOT")  $STOCK_VBOOT"
echo "vbmeta            $(sha "$VBMETA")  $VBMETA"
echo "vbmeta_system     $(sha "$VBMETA_SYSTEM")  $VBMETA_SYSTEM"
echo "vbmeta digest     $EXPECT_VBMETA_DIGEST  (computed = Unit 2 runtime ro.boot.vbmeta.digest; boot and vendor_boot match their hash descriptors; avb-check.txt, tool $(sha "$AVBCHECK"))"
echo "CAVEAT            the bytes on Unit 2's slot a are INFERRED from the OTA (the runtime vbmeta digest, kernel string, vendor command line and bootconfig match), NOT read back: AVB's hash descriptors are not enforced at boot on these units; the OTA payload signature was not verified"
echo "device-side check init.sh refuses to load any module unless /lib/modules/modules.dep = $(sha "$W/vx/lib/modules/modules.dep") and modules.softdep = $(sha "$W/vx/lib/modules/modules.softdep") (the pinned vendor_boot's): mismatch -> no module, reboot error-modules at T0+60 s"
echo "stock kernel      $(sha "$W/stock/kernel")  (5.10.246-gd7102a837402; byte-identical in the output: AOSP re-unpack)"
echo "vendor modules    $(sha "$W/vx/lib/modules/modules.load.recovery")  lib/modules/modules.load.recovery ($EXPECT_MODLIST_N modules; provenance only, NOT loaded as a list)"
echo "loaded modules    $(sha "$MODLIST_SRC")  stage3d/modules.load.v66 -> /lib/fs/modules.load ($EXPECT_FSMODLIST_N modules, the proven v66 set, J-129; module-list-check.txt, tool $(sha "$MODCHECK"))"
echo "vendor file list  $(sha "$W/vendor.list")  ($EXPECT_VLIST_N entries)"
echo "AOSP mkbootimg    $EXPECT_AOSP  (E1 fs_gitcheck CLEAN; helper $(sha "$GITCHECK"))"
echo "E1 notes          ${E1NOTES:-none}"
echo "ramdisk-scan-3d   $(sha "$SCAN")  (recorded; output in ramdisk-scan.txt)"
echo "init.sh source    $(sha "$INIT_SRC")  (recorded)"
echo "fs-phase.sh       $(sha "$RUNNER")  (recorded)"
echo "fs-probe.sh       $(sha "$PROBE")  (recorded)"
echo "fs-idle.sh        $(sha "$IDLE")  (recorded)"
echo "fsb1-pace.sh      $(sha "$FSB1_PACE")  (pinned)"
echo "build-image.sh    $(sha "$0")  (recorded)"
echo "ramdisk.cpio      $(sha "$W/ramdisk.cpio")  size=$(sz "$W/ramdisk.cpio")"
echo "ramdisk.lz4       $(sha "$W/ramdisk.lz4")  size=$(sz "$W/ramdisk.lz4")"
echo
echo "## ramdisk files (sha256  size  path  source); directories: $(cd "$R" && find . -mindepth 1 -type d | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
while read -r h s p; do echo "$h  $s  /$p  $(src_of "$p")"; done < "$W/ramdisk.sha256"
echo
echo "## checks passed"
echo "AVB: vbmeta digest = Unit 2 runtime, boot/vendor_boot hash descriptors MATCH; module list (95) present, closed under modules.dep/softdep, display/USB/backlight/LED/fan closure inside, no v2.7-only module reachable; no backlight_changes_blocked in any non-comment script line; E1 git check; every pin above; v2.7 kernel release string; static ELF (aarch64, ET_EXEC, no INTERP/NEEDED) for busybox, fs-reboot, fs-reboot-final, fs-supervise, fs-pattern;"
echo "applets present: $REQUIRED_APPLETS; no BLAKE2 applet; no debugfs in any non-comment script line;"
echo "exact ramdisk list; no symlinks; no vendor collision (only shared directories); union lacks /etc/ld.so.preload /etc/ld.so.cache /usr /lib/libc.so.6 /lib/ld-linux-aarch64.so.1 /valve;"
echo "only the 5 expected ELF files in the union; BLAKE2 scan of the final image: no hit; kernel AF_ALG hash off;"
echo "kernel bytes unchanged; header differs only in ramdisk size (stock signature size already 0); every file in the image equals the staged file."
echo
echo "## header diff"
cat "$OUT/header-diff.txt"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
