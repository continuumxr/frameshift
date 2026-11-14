# What works today

*Status as of 2026-11-14 UTC. Licence: CC-BY-4.0.*

## Can I try it yet?

**Not yet.** FrameShift is not usable as a SteamOS headset today. There is no installer, no release
and no bootable SteamOS image for a Meta Quest. What is proven so far: on a Meta Quest 3, we have
booted a shell, shown a correct test image on the panels, booted a kernel we built ourselves, read
the temperature sensors we need, proven a guard that refuses writes to the headset's boot storage,
moved data over a USB network link to the PC, and booted the kernel for Steam. SteamOS itself has
run only in an emulator, as far as a text console. An installable tester image is planned for when
the Meta Quest 3's Touch Plus controllers work. There are no dates. We plan by milestones, and we
report each result at the level it was shown.

## Milestones

Evidence levels, strongest first: **on hardware**, **in an emulator**, **offline** (builds and
tests, no headset), **design only**, **not started**.

| Milestone | What it means | Status | Evidence |
|---|---|---|---|
| First shell | Our own startup program boots and answers over USB | Passed | On hardware |
| Display test | Correct test image on both panels | Passed on both test units | On hardware |
| First kernel boot | Our own kernel boots and loads Meta's stock modules from the headset | Passed on both test units | On hardware |
| Temperature sensor test | Thermal sensors identified and read | Passed on both test units | On hardware |
| Boot-storage guard test | The kernel refuses writes to boot storage | Passed on both test units: 411 of 411 cases as expected, 402 of them refusals | On hardware |
| USB network test | A USB network link to the PC | Passed on both test units (8 MiB each way, matching hashes); one unit needed a third run because of our own PC-side tool, and both earlier runs stay on the record | On hardware |
| Kernel test | The kernel for Steam (features Steam and systemd need, a larger address space, rebuilt modules, restart lockdown) | Passed on both test headsets. The first run on one headset was recorded as not passed (our own information script misread some settings); after the fix, its replacement run and the other headset's single run both passed. The guard passed 411 of 411 again | On hardware |
| SteamOS boots | Valve's unmodified SteamOS reaches a text console | Reaches the console behind the guard; its full check fits in a Meta Quest 3's memory. Not run on a headset | In an emulator only |
| Thermal service tests | Fan, speed caps and shutdown rules | Simulated scenarios pass; device tests pending | Offline |
| GPU test | Graphics on the Quest's GPU, then the panels | Not started | Not started |
| Controllers, tracking, audio | Head tracking, Touch Plus, sound | Not started | Not started |

Also design only: installed boot and updates. Planned: updates are off by default; the details of
turning them on are not settled yet. You will download Valve's signed SteamOS image from Valve
yourself, guided by the installer. Installation will be one-way: FrameShift will not
offer a supported way back to Meta Horizon OS.

A failed or unclear result stays on the record: the USB network test and the kernel test both had
runs that did not pass; those runs stay on the record.

## Which headsets

- **Meta Quest 3:** all hands-on work is here today, on two test units.
- **Meta Quest 3S:** developed alongside the Quest 3. Build and research work only so far. No
  FrameShift image has run on it.
- **Meta Quest 2 and Meta Quest Pro:** after SteamOS boots on the Quest 3. The Quest 2 has 6 GB of
  memory, so it will read the system image from the PC over USB instead of holding it in memory.

## Safety first

- **Nothing has been flashed.** Every run so far was a temporary boot, or ran under stock Meta
  Horizon OS. The next normal power-on starts Meta Horizon OS as usual.
- **A write guard in the kernel** refuses every way of writing the boot chain and the headset's
  unit-unique partitions. It is proven on hardware, and it must be proven again on every new
  kernel.
- **Thermal and battery limits come first.** The thermal service must be proven before the first
  SteamOS boot and the first GPU load. Clocks are never pushed beyond the manufacturer's tables.
  Until the service is proven, runs are short, bounded and attended.
- **Valve's update and firmware tools never run on a Quest.** Read the guide's
  [Things never to do](HOW-FRAMESHIFT-WORKS.md#things-never-to-do-warnings) before touching any
  headset.

## How to follow along

- [How FrameShift works](HOW-FRAMESHIFT-WORKS.md): the plain-language guide to the design, the
  safety systems and every test so far.
- [The FrameShift journey](JOURNEY.md): how the project got here, milestone by milestone.
- The [README](../README.md): the project overview, principles and licences.

Every change that runs on a headset is reviewed before use, and every boot is approved and attended
by the headset's owner. FrameShift is developed with the help of AI tools; a human reviews the
work and signs off.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
