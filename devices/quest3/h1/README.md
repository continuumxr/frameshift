# Meta Quest 3: ordered module loader

A small shell library for later FrameShift images (the kernel test, the thermal service tests and
the first SteamOS boot) that loads Meta's driver modules in a safe order, with time limits.

- **Safety first:** the modules for power, CPU frequency, temperature, the fan and the battery
  load first and must come up; if they do not, the loader reports a failure and the image does
  not go on.
- **Essentials next:** the modules for USB and the console must come up; display and GPU modules
  are loaded on a best-effort basis.
- **Everything else afterwards,** asynchronously, so a slow or faulty peripheral cannot stop the
  headset from booting. Faults are reported, never hidden.

| path | what it does |
|---|---|
| `target/fs-modload.sh` | the loader library (busybox shell), sourced by an image's startup program |
| `tools/kmodel-insmod.sh` | a simulated kernel module loader, for offline tests |
| `tools/test-modload.sh` | the offline test suite, using invented module names |
| `fixtures/test/RESULTS.txt` | the recorded results of that suite |

The load plans list Meta's modules by name. They, and the tool that derives them from the owner's
own module dependency data and device tree, are not published here.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
