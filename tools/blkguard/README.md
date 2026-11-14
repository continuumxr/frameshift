# fs-blkguard: the boot-storage write guard

A patch to FrameShift's kernel (built from Meta's published Meta Quest 3 kernel source) that
refuses every way of writing the headset's boot chain and unit-unique partitions while it is
armed. It starts protective at boot, is raised to a strict mode and sealed by the startup program,
and cannot be lowered while the system runs. Its kernel patches and the C sources of its probe, harness, tests and bench are
**GPL-2.0-only** ([LICENSES/GPL-2.0-only.txt](../../LICENSES/GPL-2.0-only.txt)); its scripts and results are Apache-2.0.

| path | what it does |
|---|---|
| `patches/` | the kernel patch itself |
| `harness/` | the guard's decision logic, compiled from the patch's own policy header, under tens of thousands of checks and a fuzzer (`run.sh`, `test_policy.c`, `RESULTS.txt`) |
| `probe/fsbg-probe.c` | the probe that runs in the test image: tries every kind of write and write-like request and checks each is refused, and hashes the protected partitions before and after |
| `probe/test/`, `probe/bench/` | offline tests of the probe (identity and scope cases) and a hashing benchmark |
| `vm/` | virtual-machine tests: kernels with the guard for QEMU and User-Mode Linux, simulated disks, and a mutation test that disables one hook at a time and checks that every disabled hook is caught (`results/` keeps the summaries) |
| `kgate/` | builds the patched kernel and checks with [kgate](../kgate/) that it leaves Meta's module interface unchanged (`results/`) |

**Result on hardware:** passed on both Meta Quest 3 test headsets, on the guard kernel and again
on the kernel for Steam: 411 of 411 cases as expected, 402 of them refusals, protected partitions
unchanged.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
