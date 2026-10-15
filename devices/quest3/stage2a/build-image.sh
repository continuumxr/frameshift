#!/bin/bash
# FrameShift — build ONE Quest 3 stage-2a test image (experiment (i): the four
# pinned Valve files on the stock kernel). Run inside WSL:
#   wsl.exe -e bash <repo>/devices/quest3/stage2a/build-image.sh
#
# Extends the PROVEN stage-1 builder (devices/quest3/stage1/build.sh): same
# stock boot/vendor_boot baselines, same repack method (AOSP mkbootimg at the
# pinned commit, stock kernel bytes, stock header fields), same intended
# header differences only. One image per attempt: a fresh nonce every run.
#
# Refuses (nonzero, nothing published) unless EVERY check passes:
#   a. E1 clean-checkout check of the AOSP mkbootimg tree
#      (devices/quest3/host/fs-gitcheck.sh: --git-dir/--work-tree, GIT_* unset,
#      core.worktree refused; FS-R-005 §5 E1);
#   b. pinned SHA-256 of every input: stock boot, vendor_boot, stock kernel,
#      the vendor module list (modules.load.recovery, 97 entries) and the
#      vendor ramdisk file list, busybox, fs-reboot, fs-reboot-final,
#      fs-supervise, the common target scripts, T1-pins.json and the four
#      Valve files (hard-coded here AND in T1-pins.json; both must agree);
#      elfpin.py check on the staged Valve tree; static-ELF checks; the
#      busybox applet table; no CR in the local scripts;
#   c. the ramdisk: exact file list, no collision with the vendor ramdisk, the
#      union (vendor + ours) lacks /etc/ld.so.preload, /etc/ld.so.cache, /usr,
#      /lib/libc.so.6, /lib/ld-linux-aarch64.so.1; no ELF executable or shared
#      object other than the expected ones; tools/t1-ramdisk-scan.sh on the
#      FINAL image: the only BLAKE2 hit is /valve/bin/b2sum;
#   d. repack and AOSP re-unpack: kernel bytes unchanged, only "ramdisk size"
#      and "boot.img signature size" differ, every file inside the image equal
#      to the staged file;
#   e. MANIFEST.txt with the full SHA-256 and size of every input, every
#      ramdisk file and the image.
#
# Output: build/stage2a/<UTC>-<nonce>/ (gitignored: the image carries Valve
# binaries and is never committed): boot-stage2a.img, MANIFEST.txt,
# ramdisk.list, ramdisk.sha256, applets.txt, header-diff.txt,
# ramdisk-scan.txt, elfpin-check.txt, gitcheck.txt.
#
# FS_TEST_* variables point inputs elsewhere for the NEGATIVE fixtures only
# (test-builder.sh); every pin still applies, and the MANIFEST says so.
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
Q3=$ROOT/devices/quest3
HERE=$Q3/stage2a
COMMON=$Q3/common
AOSP=$ROOT/build/third_party/mkbootimg
FW=$ROOT/firmware/quest3/v66_unit1_slotA
STOCK_BOOT=${FS_TEST_STOCK_BOOT:-$FW/boot.img}
STOCK_VBOOT=${FS_TEST_STOCK_VBOOT:-$FW/vendor_boot.img}
BUSYBOX=${FS_TEST_BUSYBOX:-$ROOT/build/third_party/busybox/busybox}
FS_REBOOT=${FS_TEST_FS_REBOOT:-$ROOT/build/stage1-tools/fs-reboot}
FS_SUPERVISE=${FS_TEST_FS_SUPERVISE:-$COMMON/build/fs-supervise}
FS_REBOOT_FINAL=${FS_TEST_FS_REBOOT_FINAL:-$COMMON/build/fs-reboot-final}
VALVE_ROOT=${FS_TEST_VALVE_ROOT:-$HOME/sfroot-full}
OUTBASE=${FS_TEST_OUTBASE:-$ROOT/build/stage2a}
PINS=$HERE/T1-pins.json
INIT_SRC=$HERE/init.sh
VALVE_RUNNER=$HERE/fs-valve.sh
INV=$HERE/fs-inv.sh
PID1_HOLD=$COMMON/target/pid1-hold.sh
FSB1_ENC=$COMMON/target/fsb1-enc.sh
FS_DONE=$COMMON/target/fs-done
ELFPIN=$HERE/tools/elfpin.py
SCAN=$HERE/tools/t1-ramdisk-scan.sh
GITCHECK=$Q3/host/fs-gitcheck.sh

# --- pins (each change is a reviewable change) ----------------------------------
EXPECT_AOSP=d2bb0af5ba6d3198a3e99529c97eda1be0b5a093
EXPECT_STOCK_BOOT=49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50
EXPECT_STOCK_VBOOT=1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf
EXPECT_KERNEL=f34165b35a826052ce5b520d9313387c96970b498733f1a7b141dcf4afc94e7b          # stage-1 MANIFEST
EXPECT_MODLIST=1ec0253fa9b80e7121722259ab9d6de0f1c4e5015846fea4737cd14af80a6745         # lib/modules/modules.load.recovery
EXPECT_MODLIST_N=97
EXPECT_VLIST=403e891e9eb71e638afe1fceb715f87d6da02cfe4b12df2253c33efddae1c040           # sorted vendor ramdisk path list
EXPECT_VLIST_N=111
EXPECT_BUSYBOX=c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02         # stage 1
EXPECT_FS_REBOOT=c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29       # stage 1
EXPECT_FS_SUPERVISE=77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74    # common rev 4 README
EXPECT_FS_REBOOT_FINAL=ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e # common rev 4 README
EXPECT_PID1_HOLD=4294c9d57f3a94eba9847596aa614f557e7b4278cfeb5a22e38955fdd5b81dc4       # common rev 5 (magenta LED on no-host-ack)
EXPECT_FSB1_ENC=11e44d2fa386d06c596c03ff54ecfb5aeeea4790a560c8e65bf26e76733bf1a7        # common rev 5 (fsb1_emit: empty line first)
EXPECT_FS_DONE=7ad5f1106acd828fa3e9d6da9cfa0e50d66431b4b2d3a951ce39f12375064959         # common rev 4
EXPECT_PINS_JSON=0cb7de7575dc473c9213b0fa6a7f833980c2f27f6e6d53f8b828559f718645d8       # T1-pins.json
# T1-PINS.md §2 (also in T1-pins.json; both must agree)
VALVE_PINS="lib/ld-linux-aarch64.so.1 204048 2ddc56a02f476765a21e31d69144e68bee933950fe613747d54b87a2369a037e
lib/libc.so.6 1722992 be7ee393429d493c4d3b996ed25cbb02fabb2896a77efe6d57e5993ead5bbb3b
bin/uname 67856 4295f034edf7d62f721cfe994230ba139646c7872dc2a6899aa681f76fca31f1
bin/b2sum 67864 90154680070cfcb2a3027b8fa26a8091d24333329294a2f4be7a12c7f11f6402"
# every applet init.sh, the helpers, fs-valve, fs-inv, fsb1-enc.sh, pid1-hold.sh and fs-done call
REQUIRED_APPLETS="sh mount mknod mkdir cut cat echo printf sync reboot sleep insmod mdev ls tr sed grep basename setsid kill ln uname sha256sum stty mv rm chmod base64 awk wc head mkfifo"

# FS_TEST_NONCE/FS_TEST_STAMP: the reproducibility fixture only (test-builder.sh rebuilds with the
# same nonce and stamp and requires a bit-identical image); the MANIFEST then says TEST OVERRIDES,
# and fs-observe.ps1 and test-image.sh refuse such an image.
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
pin "$FS_DONE"         "$EXPECT_FS_DONE"         "common fs-done"
pin "$PINS"            "$EXPECT_PINS_JSON"       "T1-pins.json"
for f in "$INIT_SRC" "$VALVE_RUNNER" "$INV" "$ELFPIN" "$SCAN"; do need "$f"; done
for f in "$INIT_SRC" "$VALVE_RUNNER" "$INV" "$PID1_HOLD" "$FSB1_ENC" "$FS_DONE"; do
    [ "$(tr -cd '\r' < "$f" | wc -c)" -eq 0 ] || die "CR characters in $f (must be LF only)"
    head -1 "$f" | grep -qx '#!/bin/busybox sh' || die "$f: shebang is not #!/bin/busybox sh"
done

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

# stock images (AOSP tooling), kernel and vendor module list
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$STOCK_BOOT" --out "$W/stock" > "$W/stock.txt"
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$STOCK_VBOOT" --out "$W/vstock" > /dev/null
[ "$(sha "$W/stock/kernel")" = "$EXPECT_KERNEL" ] || die "stock kernel bytes differ from the stage-1 kernel"
[ ! -e "$W/vstock/vendor_ramdisk01" ] || die "more than one vendor ramdisk fragment"
mkdir -p "$W/vx"
( cd "$W/vx" && lz4 -dc "$W/vstock/vendor_ramdisk00" | cpio -id --quiet --no-absolute-filenames )
( cd "$W/vx" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/vendor.list"
[ "$(sha "$W/vendor.list")" = "$EXPECT_VLIST" ] && [ "$(wc -l < "$W/vendor.list")" -eq "$EXPECT_VLIST_N" ] \
    || die "vendor ramdisk file list differs from the pin"
[ "$(sha "$W/vx/lib/modules/modules.load.recovery")" = "$EXPECT_MODLIST" ] \
    && [ "$(wc -l < "$W/vx/lib/modules/modules.load.recovery")" -eq "$EXPECT_MODLIST_N" ] \
    || die "vendor modules.load.recovery differs from the stage-1 list"

# Valve files: hard-coded pins == T1-pins.json; copy the real paths; elfpin.py gate
python3 -I - "$PINS" > "$W/pins-json.txt" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
assert j["staged_root"] == "/valve"
for f in j["files"]:
    print(f["path"], f["size"], f["sha256"], f["rootfs_real_path"])
PY
[ "$(cut -d' ' -f1-3 "$W/pins-json.txt")" = "$VALVE_PINS" ] || die "T1-pins.json disagrees with the builder's hard-coded Valve pins"
[ -d "$VALVE_ROOT" ] || die "Valve rootfs copy missing: $VALVE_ROOT"
V=$W/stage/valve
mkdir -p "$V/lib" "$V/bin"
while read -r p size want real; do
    src=$VALVE_ROOT$real
    need "$src"
    [ "$(sz "$src")" = "$size" ] || die "Valve $p: size $(sz "$src") != pin $size"
    [ "$(sha "$src")" = "$want" ] || die "Valve $p: sha256 $(sha "$src") != pin $want"
    install -m 0755 "$src" "$V/$p"
    [ "$(sha "$V/$p")" = "$want" ] || die "Valve $p changed while staging"
done < "$W/pins-json.txt"
python3 -I "$ELFPIN" check "$PINS" "$V" > "$W/elfpin-check.txt" 2>&1 || { cat "$W/elfpin-check.txt" >&2; die "elfpin.py check refused the staged Valve tree"; }

# --- c. the ramdisk -----------------------------------------------------------------
R=$W/rd
mkdir -p "$R/bin" "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp" "$R/config" "$R/lib/fs" "$R/valve/lib" "$R/valve/bin"
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
install -m 0755 "$VALVE_RUNNER"    "$R/bin/fs-valve"
install -m 0755 "$INV"             "$R/bin/fs-inv"
install -m 0644 "$PID1_HOLD"       "$R/lib/fs/pid1-hold.sh"
install -m 0644 "$FSB1_ENC"        "$R/lib/fs/fsb1-enc.sh"
for p in lib/ld-linux-aarch64.so.1 lib/libc.so.6 bin/uname bin/b2sum; do install -m 0755 "$V/$p" "$R/valve/$p"; done
if [ -n "${FS_TEST_INJECT:-}" ]; then                                     # NEGATIVE FIXTURE ONLY: SRC:RAMDISK/PATH
    mkdir -p "$R/$(dirname "${FS_TEST_INJECT#*:}")"; install -m 0644 "${FS_TEST_INJECT%%:*}" "$R/${FS_TEST_INJECT#*:}"
fi
find "$R" -exec touch -h -d @0 {} +                                      # fixed mtimes (the nonce still differs per image)
( cd "$R" && find . -mindepth 1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/ramdisk.list"
printf '%s\n' bin bin/busybox bin/fs-done bin/fs-inv bin/fs-reboot bin/fs-reboot-final bin/fs-supervise bin/fs-valve \
    config dev init lib lib/fs lib/fs/fsb1-enc.sh lib/fs/pid1-hold.sh proc run sys tmp \
    valve valve/bin valve/bin/b2sum valve/bin/uname valve/lib valve/lib/ld-linux-aarch64.so.1 valve/lib/libc.so.6 \
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
for p in etc/ld.so.preload etc/ld.so.cache usr usr/lib/libc.so.6 lib/libc.so.6 lib/ld-linux-aarch64.so.1; do
    if [ -e "$W/union/$p" ] || [ -L "$W/union/$p" ]; then die "loader path present in the union initramfs: /$p"; fi
done
( cd "$W/union" && find . -type f -print0 | xargs -0 file | grep -E 'ELF .*(executable|shared object)' | cut -d: -f1 | sed 's#^\./##' | LC_ALL=C sort ) > "$W/union-elf.txt"
printf '%s\n' bin/busybox bin/fs-reboot bin/fs-reboot-final bin/fs-supervise valve/bin/b2sum valve/bin/uname valve/lib/ld-linux-aarch64.so.1 valve/lib/libc.so.6 \
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
    --output "$W/boot-stage2a.img"
$PYA "$AOSP/unpack_bootimg.py" --boot_img "$W/boot-stage2a.img" --out "$W/ours" > "$W/ours.txt"
[ "$(sha "$W/ours/kernel")"  = "$(sha "$W/stock/kernel")" ] || die "KERNEL BYTES CHANGED"
[ "$(sha "$W/ours/ramdisk")" = "$(sha "$W/ramdisk.lz4")" ]  || die "ramdisk mismatch after repack"
diff "$W/stock.txt" "$W/ours.txt" > "$W/header-diff.txt" || true
[ "$(wc -l < "$W/stock.txt")" -eq "$(wc -l < "$W/ours.txt")" ] || die "header field count differs"
changed=$(paste -d'|' "$W/stock.txt" "$W/ours.txt" | awk -F'|' '$1!=$2{split($1,a,":"); print a[1]}' | sort | tr '\n' ';')
[ "$changed" = "boot.img signature size;ramdisk size;" ] || die "unexpected header differences: '$changed'"
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
bash "$SCAN" "$W/scanin" "$W/scanout" "$W/boot-stage2a.img" > "$W/scan.stdout" 2>&1 || { cat "$W/scan.stdout" >&2; die "t1-ramdisk-scan.sh failed"; }
S=$W/scanout/ramdisk-scan.txt
grep -q '; identical to build ramdisk.list: yes$' "$S"                         || die "scan: unpacked ramdisk differs from ramdisk.list"
# Allowed hits: Valve's b2sum (the implementation under test), and the text of
# /bin/fs-valve, which names /valve/bin/b2sum (the string only: no IV, no sigma).
ours_hits=$(sed -n '/^## byte scan: our ramdisk/,/^## byte scan: vendor/p' "$S" | grep '^HIT ' | LC_ALL=C sort || true)
ours_names=$(printf '%s\n' "$ours_hits" | cut -d: -f1 | tr '\n' ' ')
[ "$ours_names" = "HIT ours/bin/fs-valve HIT ours/valve/bin/b2sum " ]            || die "scan: BLAKE2 indicators in our ramdisk beyond the expected two: '$ours_names'"
printf '%s\n' "$ours_hits" | grep -qx "HIT ours/bin/fs-valve: strings=\['b2sum'\] iv_u64_words=0/8 iv_table=False sigma_rows=0" \
                                                                               || die "scan: /bin/fs-valve hit is more than the b2sum path string"
file -b "$R/bin/fs-valve" | grep -q 'script' || die "/bin/fs-valve is not a script"
sed -n '/^## byte scan: vendor ramdisk/,/^## positive control/p' "$S" | grep -q ', 0 with BLAKE2 indicators$' || die "scan: BLAKE2 indicators in the vendor ramdisk"
sed -n '/^## positive control/,/^## stock kernel/p' "$S" | grep -q '^HIT usr/bin/b2sum:' || die "scan: positive control did not hit"
present=$(grep '^PRESENT in' "$S" || true)
[ "$present" = "PRESENT in ours: /valve" ]                                     || die "scan: unexpected loader/collision paths: '$present'"
sed -n '/ELF executables (ET_EXEC/,/^$/p' "$S" | grep -qx '(none)'             || die "scan: ELF executables in the vendor ramdisk"
grep -qx '# CONFIG_CRYPTO_USER_API_HASH is not set' "$S"                       || die "scan: kernel AF_ALG hash state not confirmed"

# --- publish ---------------------------------------------------------------------------
mkdir -p "$OUT"
mv "$W/boot-stage2a.img" "$OUT/boot-stage2a.img"
cp "$W/header-diff.txt" "$W/ramdisk.list" "$W/ramdisk.sha256" "$W/applets.txt" "$W/elfpin-check.txt" "$W/gitcheck.txt" "$OUT/"
cp "$S" "$OUT/ramdisk-scan.txt"

# --- e. manifest --------------------------------------------------------------------------
src_of() {
    case "$1" in
        init) echo "stage2a/init.sh ($(sha "$INIT_SRC")) with nonce" ;;
        bin/busybox) echo "$BUSYBOX" ;;
        bin/fs-reboot) echo "$FS_REBOOT" ;;
        bin/fs-reboot-final) echo "$FS_REBOOT_FINAL" ;;
        bin/fs-supervise) echo "$FS_SUPERVISE" ;;
        bin/fs-done) echo "common/target/fs-done" ;;
        bin/fs-valve) echo "stage2a/fs-valve.sh" ;;
        bin/fs-inv) echo "stage2a/fs-inv.sh" ;;
        lib/fs/pid1-hold.sh) echo "common/target/pid1-hold.sh" ;;
        lib/fs/fsb1-enc.sh) echo "common/target/fsb1-enc.sh" ;;
        valve/*) echo "Valve rootfs-A $(grep "^${1#valve/} " "$W/pins-json.txt" | cut -d' ' -f4) (T1-pins.json)" ;;
        *) echo "?" ;;
    esac
}
IMG_SHA=$(sha "$OUT/boot-stage2a.img")
{
echo "FrameShift Quest 3 stage-2a image (experiment (i)) — ONE ATTEMPT ONLY, never reuse"
echo "CONTAINS VALVE BINARIES (glibc LGPL, coreutils GPL-3): PM and Chair only, never published"
echo "built:            $STAMP"
echo "nonce:            $NONCE   (USB serial FS-$NONCE)"
[ -n "$OVERRIDES" ] && echo "TEST OVERRIDES:   $OVERRIDES(negative fixtures only; NOT a candidate image)"
echo "OUTPUT IMAGE:     boot-stage2a.img  size=$(sz "$OUT/boot-stage2a.img")  sha256=$IMG_SHA"
echo
echo "## inputs (sha256 enforced unless noted)"
echo "stock boot        $(sha "$STOCK_BOOT")  $STOCK_BOOT"
echo "stock vendor_boot $(sha "$STOCK_VBOOT")  $STOCK_VBOOT"
echo "stock kernel      $(sha "$W/stock/kernel")  (byte-identical in the output: AOSP re-unpack)"
echo "vendor modules    $(sha "$W/vx/lib/modules/modules.load.recovery")  lib/modules/modules.load.recovery ($EXPECT_MODLIST_N modules)"
echo "vendor file list  $(sha "$W/vendor.list")  ($EXPECT_VLIST_N entries)"
echo "T1-pins.json      $(sha "$PINS")"
echo "AOSP mkbootimg    $EXPECT_AOSP  (E1 fs_gitcheck CLEAN; helper $(sha "$GITCHECK"))"
echo "E1 notes          ${E1NOTES:-none}"
echo "elfpin.py         $(sha "$ELFPIN")  (recorded; check output in elfpin-check.txt)"
echo "t1-ramdisk-scan   $(sha "$SCAN")  (recorded; output in ramdisk-scan.txt)"
echo "init.sh source    $(sha "$INIT_SRC")  (recorded)"
echo "fs-valve.sh       $(sha "$VALVE_RUNNER")  (recorded)"
echo "fs-inv.sh         $(sha "$INV")  (recorded)"
echo "build-image.sh    $(sha "$0")  (recorded)"
echo "ramdisk.cpio      $(sha "$W/ramdisk.cpio")  size=$(sz "$W/ramdisk.cpio")"
echo "ramdisk.lz4       $(sha "$W/ramdisk.lz4")  size=$(sz "$W/ramdisk.lz4")"
echo
echo "## ramdisk files (sha256  size  path  source); directories: $(cd "$R" && find . -mindepth 1 -type d | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
while read -r h s p; do echo "$h  $s  /$p  $(src_of "$p")"; done < "$W/ramdisk.sha256"
echo
echo "## checks passed"
echo "E1 git check; every pin above; elfpin.py check; static ELF (aarch64, ET_EXEC, no INTERP/NEEDED) for busybox, fs-reboot, fs-reboot-final, fs-supervise;"
echo "applets present: $REQUIRED_APPLETS; no BLAKE2 applet;"
echo "exact ramdisk list; no symlinks; no vendor collision (only shared directories); union lacks /etc/ld.so.preload /etc/ld.so.cache /usr /lib/libc.so.6 /lib/ld-linux-aarch64.so.1;"
echo "only the 8 expected ELF files in the union; BLAKE2 scan of the final image: only /valve/bin/b2sum hits (plus the b2sum path string in the /bin/fs-valve script); kernel AF_ALG hash off;"
echo "kernel bytes unchanged; header differs only in ramdisk size and boot.img signature size; every file in the image equals the staged file."
echo
echo "## header diff"
cat "$OUT/header-diff.txt"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
