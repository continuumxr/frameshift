#!/bin/bash
# FrameShift — build one Quest 3 stage-1 test image (run inside WSL).
#
# One image per attempt: every run generates a fresh nonce (FS-R-003 §6). The
# observer refuses an image directory that has already been used.
#
# Enforced (FS-R-004 §6): selected stock baseline hashes, reviewed busybox and
# fs-reboot hashes, static ELF with no interpreter or NEEDED entries, required
# applets present in busybox's own applet table, kernel bytes unchanged, and
# no header difference beyond the two intended ones.
#
# Output: build/stage1/<UTC>-<nonce>/ with boot-stage1.img, MANIFEST.txt,
# ramdisk.list, header-diff.txt, applets.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
STOCK_BOOT=${FS_TEST_STOCK_BOOT:-$ROOT/firmware/quest3/v66_unit1_slotA/boot.img}   # override: negative tests only
STOCK_VBOOT=$ROOT/firmware/quest3/v66_unit1_slotA/vendor_boot.img
HERE=$ROOT/devices/quest3/stage1
AOSP=$ROOT/build/third_party/mkbootimg
BUSYBOX=${FS_TEST_BUSYBOX:-$ROOT/build/third_party/busybox/busybox}            # override: negative tests only
FS_REBOOT=$ROOT/build/stage1-tools/fs-reboot

# Reviewed inputs (FS-A-004). Changing any of these is a reviewable change.
EXPECT_STOCK_BOOT=49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50
EXPECT_STOCK_VBOOT=1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf
EXPECT_BUSYBOX=c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02
EXPECT_FS_REBOOT=c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29
EXPECT_AOSP=d2bb0af5ba6d3198a3e99529c97eda1be0b5a093
# Every applet init.sh and its helpers call (shell builtins included, so the
# check does not depend on which ones ash implements internally).
REQUIRED_APPLETS="sh mount mknod mkdir cut cat echo printf sync reboot sleep insmod mdev ls tr sed grep basename setsid kill ln uname sha256sum stty mv rm chmod"

NONCE=$(openssl rand -hex 8)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=$ROOT/build/stage1/$STAMP-$NONCE
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

sha() { sha256sum "$1" | cut -c1-64; }
die() { echo "BUILD REFUSED: $*" >&2; exit 1; }
for t in python3 cpio lz4 readelf file openssl; do command -v $t >/dev/null || die "missing tool $t"; done

# --- 1. reviewed inputs ---------------------------------------------------------
[ "$(sha "$STOCK_BOOT")"  = "$EXPECT_STOCK_BOOT" ]  || die "stock boot is not the selected baseline"
[ "$(sha "$STOCK_VBOOT")" = "$EXPECT_STOCK_VBOOT" ] || die "stock vendor_boot is not the selected baseline"
[ -f "$FS_REBOOT" ]                                 || die "fs-reboot helper missing (required)"
[ "$(sha "$BUSYBOX")"   = "$EXPECT_BUSYBOX" ]       || die "busybox hash differs from the reviewed binary"
[ "$(sha "$FS_REBOOT")" = "$EXPECT_FS_REBOOT" ]     || die "fs-reboot hash differs from the reviewed binary"
# The AOSP checkout's own git config must not blind these checks: no fsmonitor
# hook, no hidden untracked files, no redirected work tree.
ag() { git -c core.fsmonitor=false -c status.showUntrackedFiles=all -c core.worktree="$AOSP" -C "$AOSP" "$@"; }
[ "$(ag rev-parse HEAD)" = "$EXPECT_AOSP" ]              || die "AOSP mkbootimg commit differs"
[ -z "$(ag status --porcelain --ignored --untracked-files=all)" ] || die "AOSP mkbootimg working tree is modified (ignored files included)"
[ -z "$(ag ls-files -v | grep -v '^H ')" ]               || die "AOSP mkbootimg has assume-unchanged/skip-worktree entries"
# Python sees only the reviewed sources (re-reviews F5, final MINOR-6): no
# bytecode read from or written to the AOSP tree (a planted gki/__pycache__/*.pyc
# would otherwise run in place of gki/*.py), no user site-packages (.pth), no
# PYTHONPATH/PYTHONHOME/PYTHONSTARTUP from the caller.
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP
export PYTHONPYCACHEPREFIX="$W/pycache" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1

# --- 2. static ELF requirements ------------------------------------------------
for b in "$BUSYBOX" "$FS_REBOOT"; do
    file -b "$b" | grep -q "ARM aarch64" || die "$b is not aarch64"
    readelf -h "$b" | grep -q "Type:.*EXEC" || die "$b is not a static executable (ET_EXEC)"
    if readelf -l "$b" | grep -q INTERP; then die "$b has a program interpreter"; fi
    if readelf -d "$b" 2>/dev/null | grep -q NEEDED; then die "$b has dynamic dependencies"; fi
done

# --- 3. busybox applets from its own dispatch table -----------------------------
# busybox keeps applet names as one sorted, NUL-separated table beginning with
# "[" and "[["; `busybox --list` prints exactly this table. Read it from the
# binary (we cannot execute aarch64 code here) and require every applet used.
python3 - "$BUSYBOX" > "$W/applets.txt" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"\x00[\x00[[\x00")
assert i >= 0, "applet table not found"
names, p = [], i + 1
while True:
    j = d.index(b"\x00", p)
    s = d[p:j]
    if not s or not all(0x21 <= c < 0x7f for c in s): break
    if names and s.decode() <= names[-1]: break     # table is strictly sorted
    names.append(s.decode()); p = j + 1
assert len(names) > 100, "implausibly short applet table"
print("\n".join(names))
PY
missing=""
for a in $REQUIRED_APPLETS; do grep -qx "$a" "$W/applets.txt" || missing="$missing $a"; done
[ -z "$missing" ] || die "busybox applet table lacks:$missing"

# --- 4. unpack stock with AOSP tooling ------------------------------------------
python3 "$AOSP/unpack_bootimg.py" --boot_img "$STOCK_BOOT" --out "$W/stock" > "$W/stock.txt"
python3 "$AOSP/unpack_bootimg.py" --boot_img "$STOCK_VBOOT" --out "$W/vstock" > /dev/null
lz4 -dc "$W/vstock/vendor_ramdisk00" | cpio -t 2>/dev/null | sort > "$W/vendor.list"

# --- 5. our ramdisk --------------------------------------------------------------
R=$W/rd
mkdir -p "$R/bin" "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp" "$R/config"
sed "s/@NONCE@/$NONCE/" "$HERE/init.sh" | tr -d '\r' > "$R/init"
chmod 0755 "$R/init"
grep -q "NONCE=\"$NONCE\"" "$R/init"                       || die "nonce substitution failed"
[ "$(tr -cd '\r' < "$R/init" | wc -c)" -eq 0 ]              || die "CR characters left in init"
[ "$(tr -cd '$' < "$R/init" | wc -c)" -eq "$(tr -cd '$' < "$HERE/init.sh" | wc -c)" ] \
                                                            || die "init lost characters during substitution"
head -1 "$R/init" | grep -qx '#!/bin/busybox sh'           || die "init shebang wrong"
install -m 0755 "$BUSYBOX"   "$R/bin/busybox"
install -m 0755 "$FS_REBOOT" "$R/bin/fs-reboot"
( cd "$R" && find . -mindepth 1 | sed 's#^\./##' | sort | cpio -o -H newc -R 0:0 --quiet ) > "$W/ramdisk.cpio"
lz4 -l -9 -q "$W/ramdisk.cpio" "$W/ramdisk.lz4"                  # same legacy framing as stock
cpio -t < "$W/ramdisk.cpio" 2>/dev/null | sort > "$W/ramdisk.list"
printf '%s\n' bin bin/busybox bin/fs-reboot config dev init proc run sys tmp > "$W/ramdisk.expected"
cmp -s "$W/ramdisk.list" "$W/ramdisk.expected"              || die "ramdisk contents differ from the expected list"
coll=$(comm -12 "$W/ramdisk.list" "$W/vendor.list" | while read -r p; do
          lz4 -dc "$W/vstock/vendor_ramdisk00" | cpio -t -v 2>/dev/null | awk -v p="$p" '$NF==p && $1!~/^d/{print p}'
       done)
[ -z "$coll" ] || die "file collisions with vendor ramdisk: $coll"

# --- 6. repack: stock kernel bytes, our ramdisk, stock header fields -------------
os_version=$(awk -F': ' '/^os version/{print $2}' "$W/stock.txt")
os_patch=$(awk -F': ' '/^os patch level/{print $2}' "$W/stock.txt")
hv=$(awk -F': ' '/^boot image header version/{print $2}' "$W/stock.txt")
python3 "$AOSP/mkbootimg.py" --header_version "$hv" \
    --kernel "$W/stock/kernel" --ramdisk "$W/ramdisk.lz4" \
    --os_version "$os_version" --os_patch_level "$os_patch" \
    --output "$W/boot-stage1.img"          # moved into $OUT only after every check

# --- 7. verify with AOSP re-unpack; accept only the intended differences --------
python3 "$AOSP/unpack_bootimg.py" --boot_img "$W/boot-stage1.img" --out "$W/ours" > "$W/ours.txt"
[ "$(sha "$W/ours/kernel")"  = "$(sha "$W/stock/kernel")" ] || die "KERNEL BYTES CHANGED"
[ "$(sha "$W/ours/ramdisk")" = "$(sha "$W/ramdisk.lz4")" ]  || die "ramdisk mismatch after repack"
diff "$W/stock.txt" "$W/ours.txt" > "$W/header-diff.txt" || true
[ "$(wc -l < "$W/stock.txt")" -eq "$(wc -l < "$W/ours.txt")" ] || die "header field count differs"
changed=$(paste -d'|' "$W/stock.txt" "$W/ours.txt" | awk -F'|' '$1!=$2{split($1,a,":"); print a[1]}' | sort | tr '\n' ';')
[ "$changed" = "boot.img signature size;ramdisk size;" ] || die "unexpected header differences: '$changed'"
grep -qx 'boot.img signature size: 0' "$W/ours.txt"      || die "signature section not as intended"
# the init and binaries actually packed in the final image must equal the expected ones
mkdir -p "$W/x" && ( cd "$W/x" && lz4 -dc "$W/ours/ramdisk" | cpio -id --quiet init bin/fs-reboot bin/busybox )
cmp -s "$W/x/init" "$R/init"                          || die "init inside the image differs from the expected init"
[ "$(sha "$W/x/bin/busybox")" = "$EXPECT_BUSYBOX" ]     || die "busybox inside the image differs"
[ "$(sha "$W/x/bin/fs-reboot")" = "$EXPECT_FS_REBOOT" ] || die "fs-reboot inside the image differs"

# every check passed: publish
mkdir -p "$OUT"
mv "$W/boot-stage1.img" "$OUT/boot-stage1.img"
mv "$W/header-diff.txt" "$OUT/header-diff.txt"

cp "$W/ramdisk.list" "$OUT/ramdisk.list"; cp "$W/applets.txt" "$OUT/applets.txt"

# --- 8. manifest -------------------------------------------------------------------
{
echo "FrameShift Quest 3 stage-1 image — ONE ATTEMPT ONLY, never reuse"
echo "built:          $STAMP"
echo "nonce:          $NONCE   (USB serial will be FS-$NONCE)"
echo "stock boot:     $STOCK_BOOT  sha256=$(sha "$STOCK_BOOT")  (enforced)"
echo "stock vboot:    $STOCK_VBOOT  sha256=$(sha "$STOCK_VBOOT")  (enforced)"
echo "kernel:         sha256=$(sha "$W/stock/kernel")  (byte-identical to stock: verified by AOSP re-unpack)"
echo "ramdisk.cpio:   sha256=$(sha "$W/ramdisk.cpio")"
echo "ramdisk.lz4:    sha256=$(sha "$W/ramdisk.lz4")"
echo "init:           sha256=$(sha "$R/init")  (init.sh with nonce substituted; identical to the init inside the image)"
echo "init.sh source: sha256=$(sha "$HERE/init.sh")"
echo "busybox:        sha256=$(sha "$BUSYBOX")  (enforced; static, no INTERP/NEEDED; $(wc -l < "$W/applets.txt") applets in table; required present)"
echo "fs-reboot:      sha256=$(sha "$FS_REBOOT")  (enforced; static, no INTERP/NEEDED)"
echo "OUTPUT IMAGE:   $OUT/boot-stage1.img  sha256=$(sha "$OUT/boot-stage1.img")"
echo "AOSP mkbootimg: $EXPECT_AOSP  (enforced)"
echo
echo "Intended and enforced differences from stock boot.img (AOSP re-unpack):"
echo "  - ramdisk replaced (Android generic first-stage ramdisk -> FrameShift stage-1 initramfs)"
echo "  - boot signature section (4096 B, GKI) not carried over"
echo "  - kernel bytes, header version, os_version, os_patch_level unchanged"
echo
echo "Header diff:"
cat "$OUT/header-diff.txt"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
