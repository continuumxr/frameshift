# Meta Quest 3: display test, revision 4 (Meta Horizon OS v2.7)

The interactive display test rebuilt for Meta Horizon OS v2.7, the release FrameShift builds for,
with the eye order and panel tilt corrected.

| path | what it does |
|---|---|
| `src/fs-pattern.c` | the test-pattern program (revision 0.7.1) |
| `fs-phase.sh`, `fs-idle.sh`, `fs-probe.sh`, `init.sh` | the per-phase runner, the idle limit, read-only probes and the startup program |
| `build-image.sh`, `tools/build.sh` | the image builder and the program build |
| `tools/avb-check.py`, `tools/ota-payload-check.py` | offline provenance checks of the owner's own stock v2.7 firmware: the official update package, its signed partition hashes and verified-boot descriptors |
| `tools/module-closure.py`, `tools/module-list-check.py` | compute and check which of Meta's driver modules the image needs, from the owner's own vendor ramdisk |
| `tools/dt-props-compare.py`, `tools/v27-modes.py` | compare device-tree display properties and modes between firmware releases |
| `tools/` (other) | previews, and render, stream and static checks |
| `test-builder.sh`, `test-image.sh`, `fixtures/` | offline builder and image checks and their recorded results |

The module list the builder uses is derived from the owner's own firmware and is not published
here; the builder refuses to start without it. The script that re-checks the stock inputs against
a headset baseline is not included either: it needs the owner's own read-only capture of their
headset.

**Result:** a correct image on both units on Meta Horizon OS v2.7 (2026-10-14).

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
