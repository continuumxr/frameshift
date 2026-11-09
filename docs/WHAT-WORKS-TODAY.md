# What works today

*Status as of 2026-11-08 UTC. Written for the FrameShift project. Licence: CC-BY-4.0.*

*FrameShift is an independent project. It is not affiliated with, endorsed by or sponsored by Valve or Meta. Steam, SteamOS, Meta and Quest are trademarks of their respective owners.*

## Can I try it yet?

**Not yet.** FrameShift is not usable as a SteamOS headset today. There is no installer, no
release and no bootable SteamOS image for a Quest. What is proven so far: on a Quest 3, we have
booted a shell, shown a correct test image on the panels, booted a kernel we built ourselves, read
the temperature sensors we need, and proven a guard that refuses writes to the headset's boot
storage. SteamOS itself has run only in an emulator, as far as a text console. An installable
tester image is planned for the V3 milestone, when the Quest 3's Touch Plus controllers work.
There are no dates. We plan by milestones, and we report each result at the level it was shown.

## Milestones

Evidence levels, strongest first: **on hardware**, **in an emulator**, **offline** (builds and
tests, no headset), **design only**, **not started**.

| Milestone | What it means | Status | Evidence |
|---|---|---|---|
| M1 | First shell from our own kernel and startup program | Passed | On hardware |
| M2 | Correct test image on both panels | Passed | On hardware |
| K1a | Our own kernel boots and loads Meta's stock modules | Passed on both test units | On hardware |
| T0 | Thermal sensors identified and read | Passed on both test units | On hardware |
| K1g | Storage write guard (refuses writes to boot storage) | Passed on both test units: 411 of 411 cases as expected, 402 of them refusals | On hardware |
| N1 | USB network link to the PC | Passed on both test units (8 MiB each way, matching hashes); one unit needed a third run: earlier runs failed on our own PC-side tool, and both stay on the record | On hardware |
| R-1 | SteamOS boots to a text console | Valve's image reaches the console behind the guard. Its full check now fits in a Quest 3's memory. Not run on a headset. | In an emulator only |
| K1i | Kernel for Steam (IPC, 48-bit addresses, rebuilt modules) | Built; offline compatibility gate passed; device run pending | Offline |
| Thermal service | Fan, speed caps and shutdown rules | Simulated scenarios pass; device stages pending | Offline |
| GPU and compositor | Graphics on the Quest's GPU, then the panels | Not started | Not started |
| Controllers, tracking, audio | Head tracking, Touch Plus, sound | Not started | Not started |

Also design only: installed boot, updates, factory reset and a way back to Horizon OS.

A failed or unclear result stays on the record. N1 is an example.

## Which headsets

- **Quest 3:** all hands-on work is here today, on two test units.
- **Quest 3S:** developed alongside the Quest 3. Build and research work only so far. No FrameShift
  image has run on it.
- **Quest 2 and Quest Pro:** after SteamOS boots on the Quest 3. The Quest 2 has 6 GB of memory,
  so it will read the system image from the PC over USB instead of holding it in memory.

## Safety first

- **Nothing has been flashed.** Every run so far was a temporary boot, or ran under stock Horizon
  OS. The next normal power-on starts Horizon OS as usual.
- **A write guard in the kernel** refuses every way of writing the boot chain and the headset's
  unit-unique partitions. It is proven on hardware, and it must be proven again on every new
  kernel.
- **Thermal and battery limits come first.** The thermal service must be proven before the first
  SteamOS boot and the first GPU load. Never beyond the manufacturer's clock tables. Until then,
  runs are short, bounded and attended.
- **Valve's update and firmware tools never run on a Quest.** Read the guide's
  [Things never to do](HOW-FRAMESHIFT-WORKS.md#things-never-to-do-warnings) before touching any
  headset.

## How to follow along

- [How FrameShift works](HOW-FRAMESHIFT-WORKS.md): the plain-language guide to the design, the
  safety systems and every test so far.
- [JOURNAL.md](JOURNAL.md): the day-by-day record, including results that did not go as hoped.
- The [README](../README.md) carries the project's single status line.

Every package is checked by independent adversarial reviews, and by an external reviewer who has
reviewed and accepted the results above. FrameShift is developed with AI assistance, disclosed in
the README. Every device action is approved by a human owner.
