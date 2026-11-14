# The FrameShift journey

*A short, plain-language summary of how FrameShift got where it is. Status as of 2026-11-14 UTC.
Licence: CC-BY-4.0.*

## What FrameShift is

FrameShift aims to run Valve's SteamOS for the Steam Frame on Meta Quest headsets that are
already unlocked. Valve has published the Steam Frame's ARM image, so this is a port of the real
SteamOS, not a lookalike. FrameShift supplies what sits underneath it: a Linux kernel built from
Meta's published source, a thin layer of its own startup and safety software, and the PC tools
that load and check it. Valve's image itself stays unmodified.

The Meta Quest 3 comes first, with the Meta Quest 3S developed alongside it. The Meta Quest 2 and
Meta Quest Pro follow once SteamOS boots on the Quest 3. FrameShift is early-stage work: there is
no release and no installer yet.

## The principles we work by

- **SteamOS stays unmodified.** We change the Meta side, not Valve's system.
- **You download SteamOS from Valve.** FrameShift never redistributes Valve's image or any part of
  it. You download Valve's signed image from Valve, guided by the installer.
- **Firmware stays on your headset.** Meta's drivers and firmware are used from the owner's own
  headset, or rebuilt from Meta's published source. None is copied into this project.
- **Safety first.** Valve's update and firmware tools never run on a Quest. We never write the
  boot chain and never push clocks beyond the manufacturer's limits. Each protection is proven on
  a headset before the step that needs it, and until the thermal service is proven, test runs are
  short and attended, with temperature limits.
- **Boot before flash.** Everything so far has run by temporary boot from a PC. Nothing was written
  to a headset, and the next normal power-on starts Meta Horizon OS as usual.
- **One-way install.** When an installer exists, installing FrameShift will replace the headset's
  operating system. FrameShift will not offer a supported way back to Meta Horizon OS, and says so
  before anything is written.
- **Clean-room development.** Other software may be studied to learn how it behaves. Only
  functional facts are written down, and our own code is written from them, never copied.
- **Honest results.** Each result is reported at the level it was shown: on a headset, in an
  emulator, or offline. Failures stay on the record.

## Milestones so far

**Starting out (early October 2026).** We studied Valve's published image to learn what a Quest
would need to run it. One early finding shaped everything after it: Valve's update tools would
try to rewrite a headset's boot firmware. So they never run on a Quest, and FrameShift will handle
updates itself.

**A first shell (8 October).** On a Meta Quest 3, our own small startup program ran on Meta's
stock kernel, proved over USB that it was the program we built, and returned the headset to Meta
Horizon OS.

**Display test: first light, then a correct picture (9 to 14 October).** The first display tests
lit the panels, but the picture was garbled. We found out why and changed the layout. On
13 October a correct test image appeared, and a day later it was correct on both test units on
Meta Horizon OS v2.7, the release FrameShift builds for, with the eye order and panel tilt
corrected.

**Our own kernel (17 October).** A kernel we built from Meta's published source booted on both
units, with all of Meta's stock driver modules loaded from the headset and no kernel warnings.

**Temperature sensor test (18 October).** Under stock Meta Horizon OS, we identified and read the
sensors our thermal service needs. The first run found an error in our own fan table; after the
fix, it matched on both units.

**Boot-storage guard test (20 and 23 October).** Our kernel now refuses every way of writing the
boot chain. On each unit it handled 411 test cases exactly as expected, and the protected storage
was unchanged. An earlier attempt had stopped itself safely before starting, with nothing written.

**USB network test (8 November).** The link that will carry SteamOS into the headset's memory
moved 8 MiB each way with matching checksums on both units. On one unit it took a third run: our
own PC-side tool had been too slow, not the headset.

**SteamOS in an emulator.** Valve's unmodified SteamOS reaches a text console in an emulated ARM
machine, verified against Valve's signed manifest, with our guard armed and Valve's risky services
switched off. The emulator exposed a real memory problem, now fixed: the full check fits in a
Meta Quest 3's memory.

**Kernel test: the kernel for Steam (13 to 14 November).** The kernel for Steam adds the extra
features SteamOS needs and passed its offline checks. Its first headset run booted cleanly and the
guard passed again, but our own information script misread some kernel settings, so the run is
recorded as not passed. After the fix, it passed on both test headsets on 14 November.

## What comes next

1. The full thermal and battery service, tested in three groups: watching the sensors with CPU
   limits first, then the fan and the battery, then throttling and safe shutdown.
2. **SteamOS boots on a headset:** Valve's unmodified image, loaded into memory over USB, reaching
   a text console. This is the first big milestone.
3. The GPU test (graphics on the Quest's GPU), then the SteamOS desktop in the headset, head
   tracking and the Meta Quest 3's Touch Plus controllers.
4. An installable test image for testers once the controllers work. You will download Valve's
   signed SteamOS image from Valve, guided by the installer. Updates are planned to be off by
   default; the details of turning them on are not settled yet.

We plan by milestones, not dates. [What works today](WHAT-WORKS-TODAY.md) has the current status,
and [How FrameShift works](HOW-FRAMESHIFT-WORKS.md) explains the design and the safety systems.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
