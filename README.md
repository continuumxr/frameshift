# FrameShift

**FrameShift runs Valve's SteamOS for the Steam Frame, unmodified, on Meta Quest headsets that are
already unlocked.**

> **Status: early development; nothing to install yet.** There is no release, no installer and no
> bootable SteamOS image. This repository holds FrameShift's own code, kernel patches, offline
> tools and test fixtures, plus plain-language guides to the design and the results so far.

**New here?** Start with these three guides:

- [What works today](docs/WHAT-WORKS-TODAY.md): the one-page answer to "can I try it yet?".
- [How FrameShift works](docs/HOW-FRAMESHIFT-WORKS.md): the design, the boot path, the safety
  systems and every test so far, in plain language.
- [The FrameShift journey](docs/JOURNEY.md): how the project got here, milestone by milestone.

---

## What FrameShift is

Valve has published the operating system image of the Steam Frame, its ARM-based headset.
FrameShift ports that real SteamOS to Meta Quest headsets, starting with the **Meta Quest 3**,
with the **Meta Quest 3S** developed alongside it. The **Meta Quest 2** and **Meta Quest Pro**
follow once SteamOS boots on the Quest 3.

FrameShift does not change Valve's system. It supplies what sits underneath it:

- a Linux kernel built from Meta's published kernel source, with a small set of safety patches;
- a thin layer of FrameShift's own startup, safety and service software laid over Valve's files;
- the PC tools that build, load and check it.

## Where it stands

In plain words, on two Meta Quest 3 test units, using temporary boots from a PC (nothing flashed):

- **Passed:** a first shell from our own startup program; a correct test image on both panels
  (display test); our own kernel booting with Meta's stock driver modules; the temperature sensors
  the thermal service needs, found and read (temperature sensor test); a kernel guard that refuses
  every write to the headset's boot storage (boot-storage guard test, 411 of 411 cases); a USB
  network link to the PC (USB network test); and the kernel for Steam, which adds the kernel
  features SteamOS needs (kernel test), on both test headsets (2026-11-14).
- **In an emulator only:** Valve's unmodified SteamOS reaching a text console behind our guard.
- **Next:** the full thermal and battery service, then SteamOS on a headset, then graphics (GPU
  test), the desktop in the headset, head tracking and the Touch Plus controllers. A test image for
  testers is planned for when the controllers work.

We plan by milestones, not dates. Every result is reported at the level it was shown (on
hardware, in an emulator, or offline), and results that did not go as hoped stay on the record.

## How it works, in brief

1. **Valve's SteamOS image**, byte-for-byte as Valve ships it. Downloaded by the user from Valve;
   never edited and never redistributed by FrameShift.
2. **The FrameShift layer:** our own files over Valve's, which switch off Valve services that must
   not run on a Quest (updaters, firmware writers, partitioning tools) and add our own services
   (thermal and battery, device health, updates, the USB link).
3. **The FrameShift kernel:** built reproducibly from Meta's published source. It loads the kinds
   of Meta driver modules a Quest needs (display, GPU, power and battery, sensors, USB, Wi-Fi) from
   the owner's own headset, or rebuilt from Meta's published source.
4. **Meta's bootloader and boot chain:** never touched.

Safety comes from parts we own: a kernel guard that refuses writes to the boot chain, a lockdown
of special restart modes, and our own thermal and battery service. The details are in
[How FrameShift works](docs/HOW-FRAMESHIFT-WORKS.md).

## Principles

- **SteamOS unmodified, downloaded by you from Valve.** FrameShift never ships Valve's files.
- **Meta firmware stays on your headset.** Meta's drivers and firmware are used from the owner's
  own headset at run time, or rebuilt from Meta's published source. None is copied into this
  project.
- **Safety first.** Valve's update and firmware tools never run on a Quest. FrameShift never writes
  the boot chain, fuses or secure-boot state, and never pushes clocks beyond the manufacturer's
  limits. Each protection is proven on a headset before the step that needs it, and test runs are
  short, bounded and attended until the thermal service is proven.
- **Clean-room development.** Other software may be studied to learn how it behaves. Only
  functional facts are written down, and FrameShift's code is written from them, never copied.
- **One-way install.** Installing FrameShift will replace the headset's operating system. There is
  no supported way back to Meta Horizon OS.
- **An already-unlocked headset is assumed.** FrameShift provides no unlock material, and how a
  headset is unlocked is outside its scope.
- **Non-commercial, hobbyist, open source.** FrameShift is a volunteer project, not a product, and
  is not sold.
- **AI-assisted, human-reviewed.** FrameShift is developed with the help of AI tools. A human
  directs the work, reviews it and signs off on every change and every device action.

## What is in this repository

| path | what |
|---|---|
| [docs/](docs/) | the three plain-language guides |
| [devices/quest3/](devices/quest3/) | the Meta Quest 3 work: shared startup code, the test-image packages for each stage, the module loader, the thermal inputs |
| [devices/thermal/](devices/thermal/) | the thermal and battery service, with its simulator and reference models |
| [devices/quest2/](devices/quest2/) | Meta Quest 2 offline work: the USB channel and firmware analysis tools |
| [devices/quest3s/](devices/quest3s/), [devices/questpro/](devices/questpro/), [devices/quest1/](devices/quest1/), [devices/xre/](devices/xre/) | notes for later or shelved targets |
| [tools/kgate/](tools/kgate/) | the offline kernel symbol-version gate |
| [tools/blkguard/](tools/blkguard/) | fs-blkguard, the boot-storage write guard: kernel patch, probe and virtual-machine tests |
| [kernel-patches/](kernel-patches/) | where the kernel patches are, and their licence |

Each folder has a short README saying what its code does.

**About this public tree.** This repository is a curated public view of FrameShift: code, patches,
tools, fixtures, results and summaries. Our working records (build and test logs, plans and
day-to-day notes) are kept private, and no device serial numbers are published. Some code comments,
test labels and recorded test outputs refer to internal development records that are not published.
Some offline suites need inputs that are not in the repository (your own firmware, pinned
third-party build tools, built images) and refuse to start without them.

## Trying the offline tests

Nothing here talks to a headset.

```
# WSL (Ubuntu), from the repository root
bash tools/kgate/test_kgate.sh                       # kernel gate: 170 cases
python3 devices/quest3/common/tools/test_fsb1.py     # record decoder: 38 cases
bash devices/thermal/tools/run_all.sh                # thermal service: build and all suites
                                                     # (rewrites the committed RESULTS files)

# Windows PowerShell 5.1, from the repository root
powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\common\host\test-fsb1.ps1
```

Two thermal suites (`tables` and `accept`) need thermal tables derived from your own headset's
firmware, which are not published; without them, `run_all.sh` reports those two as FAIL.

The environment used for development: Windows 11 with PowerShell 5.1 for the PC-side tools, and
WSL Ubuntu with the AOSP clang toolchain that matches Meta's kernels for builds and fixtures. Meta
publishes its kernel sources per release at `github.com/facebookincubator/oculus-linux-kernel`.

## Contributing

Issues and pull requests are welcome. Contribute only your own work, under the licences below,
and never add Valve or Meta software, firmware, images or credentials. Changes that affect what
runs on a headset are reviewed before any device use; a merged change does not by itself mean it
has run on a headset.

## Licences

Licences are per folder and per file (see [NOTICE](NOTICE)):

- **Code:** Apache License 2.0 ([LICENSE](LICENSE)).
- **Kernel parts** (kernel patches, fs-blkguard's C sources, FrameShift's own kernel modules):
  GPL-2.0-only ([LICENSES/GPL-2.0-only.txt](LICENSES/GPL-2.0-only.txt);
  [kernel-patches/README.md](kernel-patches/README.md)).
- **Documentation:** CC-BY-4.0 ([LICENSES/CC-BY-4.0.txt](LICENSES/CC-BY-4.0.txt)).

Where a file carries an SPDX-License-Identifier header, that header applies.

## Disclaimer

FrameShift is unofficial, experimental software, provided "as is" without warranty of any kind.
Installing it replaces your headset's operating system and cannot be undone with FrameShift. It
may void your manufacturer's warranty, may affect your Meta or Steam account, and may permanently
damage your device or erase your data. You use it entirely at your own risk; to the extent the law
allows, the FrameShift contributors accept no liability for any damage or loss.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
