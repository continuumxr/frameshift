#!/bin/bash
# FrameShift stage-2a — confirm no BLAKE2 implementation is reachable in the
# stage-1 image's initramfs (FS-A-006 §4 discrimination; FS-R-006 §5 F).
# Run inside WSL: bash t1-ramdisk-scan.sh <build-dir> <outdir> [<image file>]
#   <image file> defaults to <build-dir>/boot-stage1.img (the original use); the
#   stage-2a/3a builders pass their own image (fix round 6, N3: labels name it).
#
# The bootloader concatenates vendor_boot's ramdisk and our boot ramdisk, so
# both are scanned, unpacked from the actual images (not from ramdisk.list).
# Checks: busybox applet table; every regular file for BLAKE2 strings and the
# BLAKE2 message schedule (sigma) table; loader fallback paths; and the stock
# kernel's config for a userspace-reachable BLAKE2b (AF_ALG hash).
# Positive control: the same byte scan applied to Valve's b2sum must hit.
set -euo pipefail
B=${1:?usage: t1-ramdisk-scan.sh <build-dir> <outdir> [<image file>]}
OUT=${2:?}
IMG=${3:-$B/boot-stage1.img}
IMGN=$(basename "$IMG")
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"
AOSP=$ROOT/build/third_party/mkbootimg
VBOOT=$ROOT/firmware/quest3/v66_unit1_slotA/vendor_boot.img
EXPECT_VBOOT=1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$OUT"; R=$OUT/ramdisk-scan.txt; : > "$R"
say() { printf '%s\n' "$*" | tee -a "$R"; }
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 PYTHONPYCACHEPREFIX="$W/pyc"

say "# initramfs BLAKE2 scan of $IMGN  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "boot image:   $IMG sha256=$(sha256sum "$IMG" | cut -c1-64)"
v=$(sha256sum "$VBOOT" | cut -c1-64)
say "vendor_boot:  $VBOOT sha256=$v $( [ "$v" = "$EXPECT_VBOOT" ] && echo '(= the pinned stock vendor_boot)' || echo '(MISMATCH)')"
python3 "$AOSP/unpack_bootimg.py" --boot_img "$IMG" --out "$W/boot" > /dev/null
python3 "$AOSP/unpack_bootimg.py" --boot_img "$VBOOT" --out "$W/vboot" > /dev/null
mkdir -p "$W/x/ours" "$W/x/vendor"
(cd "$W/x/ours"   && lz4 -dc "$W/boot/ramdisk"            | cpio -id --quiet --no-absolute-filenames)
(cd "$W/x/vendor" && lz4 -dc "$W/vboot/vendor_ramdisk00"  | cpio -id --quiet --no-absolute-filenames)
ls "$W/vboot" | grep -q '^vendor_ramdisk01$' && say "WARNING: more than one vendor ramdisk fragment" || say "vendor ramdisk fragments: 1 (vendor_ramdisk00)"
(cd "$W/x/ours" && find . -mindepth 1 | sed 's#^\./##' | sort) > "$W/ours.list"
say "our ramdisk entries: $(wc -l < "$W/ours.list") ; identical to build ramdisk.list: $(cmp -s "$W/ours.list" "$B/ramdisk.list" && echo yes || echo NO)"
say "vendor ramdisk entries: $(cd "$W/x/vendor" && find . -mindepth 1 | wc -l) (regular files: $(cd "$W/x/vendor" && find . -type f | wc -l))"
say ""; say "## vendor ramdisk: file kinds"
(cd "$W/x/vendor" && find . -type f -print0 | xargs -0 file -b | sed -E 's/, BuildID\[[^]]*\]=[0-9a-f]+//; s/, (not )?stripped//; s/, with debug_info//' | sort | uniq -c | sort -rn) | tee -a "$R"
say ""; say "## vendor ramdisk: non-module, non-text files (anything executable-looking)"
(cd "$W/x/vendor" && find . -type f ! -name '*.ko' -print0 | xargs -0 file | grep -viE ':\s+(ASCII|UTF-8|Unicode|empty|very short)' || echo "(none)") | tee -a "$R"
say ""; say "## vendor ramdisk: ELF executables (ET_EXEC/ET_DYN, not relocatable .ko)"
(cd "$W/x/vendor" && find . -type f -print0 | xargs -0 file | grep -E 'ELF .*(executable|shared object)' || echo "(none)") | tee -a "$R"

say ""; say "## busybox applet table (from build applets.txt, $(wc -l < "$B/applets.txt") applets)"
say "BLAKE2/b2sum applets: $(grep -iE 'b2|blake' "$B/applets.txt" | tr '\n' ' ' || true)$(grep -qiE 'b2|blake' "$B/applets.txt" || echo none)"
say "hash applets present: $(grep -E 'sum$|^crc32$' "$B/applets.txt" | tr '\n' ' ')"

say ""; say "## loader fallback / collision paths in the union initramfs (must all be absent)"
for p in usr usr/lib lib/libc.so.6 lib/ld-linux-aarch64.so.1 usr/lib/libc.so.6 etc/ld.so.preload etc/ld.so.cache valve; do
  for side in ours vendor; do [ -e "$W/x/$side/$p" ] || [ -L "$W/x/$side/$p" ] && say "PRESENT in $side: /$p"; done
  { [ -e "$W/x/ours/$p" ] || [ -e "$W/x/vendor/$p" ]; } || say "absent: /$p"
done
say "/lib in vendor ramdisk: $( [ -d "$W/x/vendor/lib" ] && echo "directory ($(ls "$W/x/vendor/lib" | tr '\n' ' '))" || echo absent)"

# byte scan: (1) strings "blake2"/"b2sum"; (2) the BLAKE2b IV as 64-bit little-endian words
# (it equals SHA-512's IV, so a hit means "BLAKE2b or a SHA-512 with a u64 IV table" and must be
# investigated; busybox stores SHA-512's IV as 32-bit halves and does not hit); (3) BLAKE2 sigma
# rows as u8/u32 tables (compilers often fold these away: Valve's b2sum has none, so (3) is
# supplementary only). Positive control: Valve's b2sum must hit (1) and (2).
cat > "$W/scan.py" <<'PY'
import os, sys, re
SIGMA = [bytes([14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3]),
         bytes([11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4]),
         bytes([7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8])]
SIGMA32 = [b"".join(x.to_bytes(4, "little") for x in s) for s in SIGMA]   # uint32 tables
STR = re.compile(rb"(?i)blake2|b2sum")
import struct
IV = [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
      0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179]
IVW = [struct.pack("<Q", x) for x in IV]
IVTAB = b"".join(IVW)
hits = 0
for top in sys.argv[1:]:
    paths = [top] if os.path.isfile(top) else [os.path.join(dp, f) for dp, _, fs in os.walk(top) for f in fs]
    for p in sorted(paths):
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        d = open(p, "rb").read()
        s = sorted(set(m.group().decode().lower() for m in STR.finditer(d)))
        g = sum(row in d for row in SIGMA) + sum(row in d for row in SIGMA32)
        w = sum(x in d for x in IVW); t = IVTAB in d
        if s or g or w:
            hits += 1
            print(f"HIT {p}: strings={s} iv_u64_words={w}/8 iv_table={t} sigma_rows={g}")
print(f"scanned {sum(1 for t in sys.argv[1:] for _ in ([t] if os.path.isfile(t) else [1 for _,_,fs in os.walk(t) for _ in fs]))} files, {hits} with BLAKE2 indicators")
PY
say ""; say "## byte scan: our ramdisk (every file in the ramdisk of $IMGN)"
python3 -I "$W/scan.py" "$W/x/ours" | sed "s#$W/x/##" | tee -a "$R"
say ""; say "## byte scan: vendor ramdisk (modules, firmware lists, etc.)"
python3 -I "$W/scan.py" "$W/x/vendor" | sed "s#$W/x/##" | tee -a "$R"
say ""; say "## positive control: same scan on Valve b2sum and libc (must hit b2sum)"
python3 -I "$W/scan.py" "$HOME/sfroot-full/usr/bin/b2sum" "$HOME/sfroot-full/usr/lib/libc.so.6" "$HOME/sfroot-full/usr/lib/ld-linux-aarch64.so.1" "$HOME/sfroot-full/usr/bin/uname" | sed "s#$HOME/sfroot-full/##" | tee -a "$R"

say ""; say "## stock kernel (byte-identical in $IMGN): BLAKE2 config, from its own IKCONFIG"
python3 -I - "$W/boot/kernel" > "$W/kconfig" <<'PY'
import sys, gzip, subprocess
d = open(sys.argv[1], "rb").read()
def ik(b):
    i = b.find(b"IKCFG_ST")
    if i < 0: return None
    j = b.find(b"IKCFG_ED", i)
    return gzip.decompress(b[i + 8:j])
c = ik(d)
if c is None:
    for cmd in (["lz4", "-dc"], ["gzip", "-dc"]):
        try:
            c = ik(subprocess.run(cmd, input=d, capture_output=True).stdout)
        except Exception:
            c = None
        if c: break
sys.stdout.write(c.decode() if c else "")
PY
if [ -s "$W/kconfig" ]; then
  rel=$(grep -aoE 'Linux version [0-9][^ ]*' "$W/boot/kernel" | head -1 || true)
  say "IKCONFIG extracted ($(wc -l < "$W/kconfig") lines); kernel release string: ${rel:-?}"
  grep -E 'CONFIG_CRYPTO_BLAKE2|CONFIG_CRYPTO_LIB_BLAKE2|CONFIG_CRYPTO_USER_API|CONFIG_CRYPTO_USER=|CONFIG_CRYPTO_USER ' "$W/kconfig" | tee -a "$R"
else
  say "IKCONFIG not found in kernel image (see ~/work/fs006/q.config instead)"
fi
say ""; say "# done"
