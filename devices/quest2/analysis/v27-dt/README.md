# Meta Quest 2 v2.7 device tree

The decompiled device-tree files of the Quest 2 v2.7 firmware are not included: they are a
mechanical transformation of Meta firmware. Regenerate them from your own copy of the firmware with
`../extract-v27-dt.sh` (WSL; needs python3 and dtc). `SHA256SUMS` records the hashes of the files
it produces, and `INDEX.txt` the hashes of the input blobs.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
