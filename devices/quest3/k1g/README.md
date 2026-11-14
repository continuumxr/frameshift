# Meta Quest 3: boot-storage guard test

The first FrameShift kernel plus the fs-blkguard patch ([tools/blkguard/](../../../tools/blkguard/)),
and a test image whose probe tries every kind of write to the headset's protected storage and
checks that each one is refused.

| path | what it does |
|---|---|
| `kernel/build-kernel-k1g.sh`, `kernel/gate-k1g.sh` | build the guard kernel reproducibly and check that its module interface is unchanged |
| `build-probe.sh` | builds the probe (`tools/blkguard/probe/fsbg-probe.c`) as a reproducible static ARM64 program |
| `init.sh` | the startup program: arms the guard in its strict mode, seals it, and checks the state before the probe runs |
| `fs-k1g.sh`, `fs-k1g-info.sh` | the step runner and its read-only fact helper |
| `build-image-k1g.sh` | builds the test image |
| `tools/` | module-load simulation, bound checks, an image harness, a nonce-only rebuild check and an image comparison |
| `test-builder-k1g.sh`, `test-image-k1g.sh`, `fixtures/` | offline checks and their recorded results |

**How a run is judged:** every protected partition the probe hashes must be unchanged afterwards,
every write or write-like request must be refused, and the kernel log must show no warning.

**Result:** passed on both units (2026-10-20 and 2026-10-23): 411 of 411 cases behaved as expected,
402 of them refusals across 14 kinds of request, protected partitions unchanged. An earlier attempt
stopped itself before arming because its reads were the wrong size for this storage; nothing was
written, and the probe was fixed.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
