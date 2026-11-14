# Meta Quest 3: display test, revision 3

An interactive display test: the PC steps the headset through several display phases, one at a
time, and the person wearing the headset reads what each eye shows between phases.

| path | what it does |
|---|---|
| `src/fs-pattern.c` | the test-pattern program (revision 0.6), with a layout that fits the display pipes |
| `fs-phase.sh` | runs one display phase per PC request and answers with its own checksummed record |
| `fs-idle.sh` | ends the session if the PC goes quiet for too long |
| `fs-probe.sh` | read-only display probes |
| `init.sh`, `build-image.sh`, `tools/build.sh` | the startup program, the image builder and the program build |
| `tools/` | previews, and render, stream and static checks |
| `test-builder.sh`, `test-image.sh`, `fixtures/` | offline builder and image checks and their recorded results |

**Result:** a correct image on the panels of one unit, on older Meta Horizon OS firmware
(2026-10-13).

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
