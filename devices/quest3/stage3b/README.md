# Meta Quest 3: display test, revision 2

The display test with the panel woken correctly and a bounded, read-only display probe.

| path | what it does |
|---|---|
| `src/fs-pattern.c` | the test-pattern program (revision 0.5) |
| `fs-display.sh` | runs the display step and records the result |
| `fs-probe.sh` | read-only probes of the display state, plus the one backlight setting the test needs |
| `init.sh`, `build-image.sh`, `tools/build.sh` | the startup program, the image builder and the program build |
| `tools/preview.py` | a Python port of the drawing code, checked byte for byte against the C program, that writes PNG previews |
| `tools/check_*.py`, `tools/dmesg-timing.sh`, `tools/pace_evidence.py` | offline render and stream checks, and measurements of the probe's log filter and the record pacing |
| `test-builder.sh`, `test-image.sh`, `fixtures/` | offline builder and image checks and their recorded results |

**Result:** the panels lit, but the picture was garbled: the layout asked too much of each display
pipe. The next revision ([stage3c/](../stage3c/)) changed the layout.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
