#!/bin/bash
# K1a kernel: bit-identical rebuild check. Compares the manifests (sha256 of .config, vmlinux, Image, Module.symvers,
# System.map and every built .ko) that build-kernel.sh wrote for two builds at the SAME object path, and the two
# Images byte for byte. Offline; run in WSL.
# Usage: compare-builds.sh <manifest A> <manifest B> [<Image A> <Image B> [<build-image.sh>]]
#   Use the COMMITTED record/run1/manifest.txt as A (review m5). With build-image.sh, the Image and .config hashes of
#   both manifests must also equal the builder's EXPECT_K1A_KERNEL / EXPECT_K1A_CONFIG pins.
set -u
A=${1:?manifest A}; B=${2:?manifest B}
rc=0
for f in .config vmlinux arch/arm64/boot/Image Module.symvers System.map; do
    a=$(awk -v f="$f" '$2==f{print $1}' "$A"); b=$(awk -v f="$f" '$2==f{print $1}' "$B")
    if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "IDENTICAL $f $a"; else echo "DIFFERS   $f A=$a B=$b"; rc=1; fi
done
ka=$(grep -c '\.ko$' "$A"); kb=$(grep -c '\.ko$' "$B")
kd=$(diff <(grep '\.ko$' "$A") <(grep '\.ko$' "$B") | grep -c '^[<>]')
echo ".ko: A=$ka B=$kb differing-lines=$kd (list sha256 A $(grep '\.ko$' "$A" | sha256sum | cut -c1-16) B $(grep '\.ko$' "$B" | sha256sum | cut -c1-16))"
[ "$ka" = "$kb" ] && [ "$kd" = 0 ] || rc=1
if [ $# -ge 4 ]; then
    if cmp -s "$3" "$4"; then echo "Images byte-identical (cmp): $(stat -c %s "$3") bytes"; else echo "Images DIFFER (cmp)"; rc=1; fi
fi
if [ $# -ge 5 ]; then
    pk=$(sed -n 's/^EXPECT_K1A_KERNEL=\([0-9a-f]\{64\}\)$/\1/p' "$5"); pc=$(sed -n 's/^EXPECT_K1A_CONFIG=\([0-9a-f]\{64\}\)$/\1/p' "$5")
    for m in "$A" "$B"; do
        [ "$(awk '$2=="arch/arm64/boot/Image"{print $1}' "$m")" = "$pk" ] && [ "$(awk '$2==".config"{print $1}' "$m")" = "$pc" ] \
            && echo "PINS OK   $m: Image and .config = build-image.sh's pins" || { echo "PINS DIFFER $m (build-image.sh: Image $pk, .config $pc)"; rc=1; }
    done
fi
[ $rc = 0 ] && echo "RESULT: BIT-IDENTICAL REBUILD" || echo "RESULT: NOT IDENTICAL"
exit $rc
