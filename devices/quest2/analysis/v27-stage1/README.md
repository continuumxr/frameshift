# Meta Quest 2 v2.7 boot image analysis

Offline, read-only tools that inspect the owner's own Quest 2 v2.7 firmware:

| path | what it does |
|---|---|
| `bootcheck.py` | checks the boot image header and layout |
| `vbmeta.py` | lists the verified-boot (AVB) descriptors |
| `vendor-scan.sh` | reads the stock vendor image's start-up (rc) scripts, read-only, to list what Android sets up at boot |
| `INDEX.txt` | the commands and the SHA-256 of every input image |

Their outputs are not included, because they reproduce Meta firmware content. Run the tools on
your own firmware to regenerate them.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
