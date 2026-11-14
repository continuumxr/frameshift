# Meta Quest 3: display test, revision 1

The first display test image: Meta's stock kernel, FrameShift's startup program and `fs-pattern`,
our own program that draws one static test pattern on the headset's panels through the kernel's
display interface (KMS).

| path | what it does |
|---|---|
| `src/fs-pattern.c` | the test-pattern program: a per-eye pattern with a readable challenge code, shown for a bounded time |
| `fs-display.sh` | runs the display step once per session, under the supervisor, and records the result |
| `init.sh` | the startup program (PID 1), built on [../common/](../common/) |
| `build-image.sh`, `tools/build.sh` | build the image and the static ARM64 program (bit-identical rebuilds) |
| `test-builder.sh`, `test-image.sh`, `tools/` | offline builder checks, an image harness, render and output-stream checks, a policy harness |
| `fixtures/` | recorded results and preview images of the pattern |

**Result:** recorded as inconclusive: no light was seen and part of the serial record was lost; the
cause was understood and fixed in the next revisions ([stage3b/](../stage3b/) to
[stage3d/](../stage3d/)).

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
