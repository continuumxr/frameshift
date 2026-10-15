# Quest 2 v2.7 stage-1 offline analysis

The tool outputs that were here are withheld from the public copy
[removed for publication]: `boot-layout.txt` (boot header fields and the
ramdisk listing), `vbmeta.txt` (AVB descriptors) and `vendor-scan.txt`
(lines quoted from the stock vendor image's init scripts). They reproduce
content of Meta firmware verbatim. The tools are included (`bootcheck.py`,
`vbmeta.py`, `vendor-scan.sh`); `INDEX.txt` gives the commands and the
SHA-256 of every input image, so you can regenerate the outputs from your own
firmware.
