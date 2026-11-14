# Meta Quest 3: first kernel boot

FrameShift's first own kernel, built from Meta's published Meta Horizon OS v2.7 kernel source, and
the test image that boots it.

The kernel adds only options that leave the kernel's module interface unchanged (device nodes
managed by the kernel, file handles, automount, Btrfs, extended attributes for in-memory
filesystems), so Meta's stock driver modules still load from the headset's own storage.

| path | what it does |
|---|---|
| `kernel/build-kernel.sh`, `kernel/k1a.config` | build the kernel reproducibly from Meta's source with this configuration |
| `kernel/compare-builds.sh` | checks that two builds are bit-identical |
| `kernel/gate-k1a.sh` | runs the [kgate](../../../tools/kgate/) symbol-version check against the owner's stock modules |
| `kernel/make-toolchain-pins.sh`, `kernel/*.sha256`, `kernel/toolchain.links` | pin the exact toolchain files used for the build |
| `init.sh`, `fs-k1a.sh`, `fs-k1a-info.sh` | the startup program, the step runner and its read-only fact helper (kernel, configuration, memory, modules, kernel log) |
| `build-image.sh` | builds the test image around the kernel |
| `tools/modload-sim-k1a.py`, `tools/modload-sim.sh` | simulate loading Meta's modules against a kernel build, offline |
| `tools/check-bounds-k1a.py`, `tools/image-harness-k1a.py`, `tools/nonce-only-k1a.py` | re-derive the time bounds, run the image offline, and check that a rebuilt image differs only in its one-time challenge |
| `test-builder.sh`, `test-image.sh`, `fixtures/` | offline checks and their recorded results |

**Result:** passed on both units on 2026-10-17: the kernel booted and loaded all of Meta's stock
modules with no kernel warning.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
