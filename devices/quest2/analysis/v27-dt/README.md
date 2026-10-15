# Quest 2 v2.7 device tree (decompiled sources withheld)

The decompiled `.dts` files of the Quest 2 v2.7 DTB/DTBO are not included in
the public repository (they are a mechanical transformation of a Meta firmware
component). Regenerate them from your own copy of the firmware with
`../extract-v27-dt.sh`; `SHA256SUMS` records the hashes of the files produced
here, and `INDEX.txt` lists the blobs' hashes. `boot-header.txt` (the boot image
header printed by AOSP `unpack_bootimg`) is also withheld; the script
regenerates it.
