# Meta Quest 3: first Valve programs

An early trial image that ran a few genuine programs from Valve's published Steam Frame image,
read-only, under FrameShift's startup program on Meta's stock kernel. It checked whether Valve's
ARM programs start on a Quest at all.

| path | what it does |
|---|---|
| `init.sh` | the startup program (PID 1), built on [../common/](../common/) |
| `fs-valve.sh` | runs each pinned Valve program once under the supervisor and records how it ended |
| `fs-inv.sh` | a read-only inventory step (informational only) |
| `T1-pins.json` | the hashes of the Valve files the trial used (hashes only; no Valve file is in this repository) |
| `tools/elfpin.py`, `tools/t1-pin.sh`, `tools/t1-pin-negative.sh`, `tools/t1-qemu-fixture.sh` | derive and check those pins from the user's own download of Valve's image (with negative cases that must be refused), and run the pinned programs offline under QEMU user emulation |
| `tools/t1-ramdisk-scan.sh` | confirms that no BLAKE2 hashing implementation is reachable in a finished image's startup ramdisk; the later display-test builders reuse it |
| `tools/image-harness.py` | runs a whole image's startup code offline under QEMU user emulation; the first display test reuses it |

The image builder for this trial is not included: the image it produced contained Valve files
from the user's own download, which must never be redistributed.

**Result:** the programs started under our startup program, but the trial was recorded as not
passed because of a defect in our own listing rule (since fixed). It is described in
[How FrameShift works](../../../docs/HOW-FRAMESHIFT-WORKS.md#7-what-has-been-tested).

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
