# Meta Quest 3: USB network test

A USB network function (NCM) next to the USB serial console, on the first FrameShift kernel. This
is the link that will later carry SteamOS from the PC into the headset's memory.

| path | what it does |
|---|---|
| `init.sh` | the startup program, with the network function added beside the serial console; IPv6 link-local only, derived from the session's one-time challenge |
| `src/fs-xfer.c` | the image's only network listener: a bounded transfer test that receives and sends 8 MiB and checks SHA-256 on both sides |
| `fs-n1.sh`, `fs-n1-info.sh` | the step runner and its read-only fact helper, including a kernel-log check after the transfer |
| `build-image.sh`, `tools/build-xfer.sh` | build the image and the transfer program |
| `tools/xfer-client.py` | a reference PC side of the transfer test, for offline fixtures |
| `tools/` (other) | bound checks, an image harness and a nonce-only rebuild check |
| `test-builder.sh`, `test-image.sh`, `fixtures/` | offline checks and their recorded results |

**Result:** passed on both units (by 2026-11-08): 8 MiB each way with matching hashes and no kernel
warning. On one unit it took a third run, because our own PC-side tool was too slow to find the
new network adapter.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
