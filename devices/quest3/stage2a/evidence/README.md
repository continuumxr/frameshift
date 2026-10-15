# Stage 2a T1 evidence (withheld)

This folder held inspection output of the four pinned Valve files (readelf and
strings cross-checks, the ld.so environment-variable list, the ELF-pin JSON),
a scan of the stock vendor ramdisk, and qemu transcripts of the Valve binaries
(including their version banners). That is third-party binary and tool output,
so it is not published here. Our own conclusions, the hashes and the pins are in
`../T1-PINS.md` and `../T1-pins.json`; the tool that produced the evidence is
`../tools/t1-pin.sh` (run it on your own copy of the Steam Frame image).
