# How FrameShift works

**Licence:** CC-BY-4.0 (our own documentation; see [NOTICE](../NOTICE)).

*A plain-language guide to what FrameShift is, how it boots, how it keeps a headset safe, and what
has actually been shown so far. It is updated at each milestone. **Current as of 2026-11-14 UTC.**
[What works today](WHAT-WORKS-TODAY.md) has the one-page status, and [The FrameShift
journey](JOURNEY.md) tells the story so far.*

**Who this is for:** technically curious users, testers and contributors. Like the project itself,
this guide assumes you already have an unlocked headset. FrameShift provides no unlock material.

---

## The short version

- **What it is.** FrameShift ports Valve's SteamOS for the Steam Frame headset to Meta Quest
  headsets. Valve's operating system image is used **unmodified**.
- **Which headsets.** The Meta Quest 3 and Meta Quest 3S first, then the Meta Quest 2 and Meta
  Quest Pro. Today all hands-on work is on the Quest 3. The other three are build and research
  work only.
- **How it fits together.** Valve's image sits on top. Under it are a thin layer of FrameShift's own
  files and a FrameShift-built Linux kernel (made from Meta's published source). Meta's bootloader
  is never touched.
- **Where it stands.** Early development. There is no release, no installer and no bootable
  SteamOS image yet.
- **Proven on real hardware (Meta Quest 3, two test units).** A first shell. A correct test image on
  the panels. A FrameShift-built kernel that boots. The sensors the thermal service needs, found and
  read. A guard that refuses writes to the headset's boot storage. A USB network link to the PC. The
  kernel for Steam, with the features SteamOS needs. All of this used temporary boots or stock Meta
  Horizon OS; nothing was flashed.
- **SteamOS itself has run only in an emulator**, and only as far as a text console. On a headset,
  only a few individual Valve programs have run (in early trials), and nothing graphical from
  SteamOS has run anywhere.
- **Safety comes first.** The write guard, a restart-request lockdown, and a thermal and battery
  service are the protections. Early runs are short, bounded and attended.
- **Not started:** the GPU, graphics, the SteamOS desktop in the headset, head tracking and
  controllers. **Design only:** installed boot and updates.
- **What comes next.** The kernel test (the kernel for Steam) passed on both units. Next is the
  thermal service on that kernel, then the first SteamOS boot on a headset, then graphics. The first
  installable test image is planned for the controller milestone.
- **Honest reporting.** Every claim is labelled with how it was shown, and failed or unclear
  results stay on the record.

---

## Contents

1. [The big picture](#1-the-big-picture)
2. [The boot path](#2-the-boot-path)
3. [Our kernel](#3-our-kernel)
4. [Safety systems](#4-safety-systems)
5. [How SteamOS is loaded and protected](#5-how-steamos-is-loaded-and-protected)
6. [Updates, power and reset](#6-updates-power-and-reset)
7. [What has been tested](#7-what-has-been-tested)
8. [What comes next](#8-what-comes-next)
9. [Principles](#9-principles)
10. [How claims are checked](#10-how-claims-are-checked)

---

## 1. The big picture

**What FrameShift is.** Valve published the operating system image (SteamOS, a Linux-based system)
of the Steam Frame, its headset built on an ARM processor. FrameShift ports that SteamOS,
**unmodified**, to Meta Quest headsets.

The first targets are the **Meta Quest 3 and the Meta Quest 3S**, developed together, followed by
the **Meta Quest 2 and the Meta Quest Pro**. After the first SteamOS boot (section 5), all four are
meant to move forward together.

Today the hands-on work is on the Quest 3 only. The work on the other three is offline (build and
research only), and no FrameShift image has run on them. The project has two Quest 3 test units and
one Quest 2 unit.

**The shape of it: unmodified SteamOS plus a thin FrameShift layer.** From the top down:

1. **Valve's SteamOS** (the Steam Frame build), byte-for-byte as Valve ships it: systemd (the
   system that starts and supervises services), Steam, SteamVR, the desktop. Never edited.
2. **The FrameShift layer.** Our files only, laid over Valve's: switches that turn off Valve
   services, settings, and our own services (thermal and battery, device health, updates, the USB
   link).
3. **The FrameShift kernel.** The kernel is the core of the operating system that talks to the
   hardware. Ours is built from Meta's published Quest kernel source, plus our safety patches, and
   uses the Quest's own drivers.
4. **Meta's bootloader and boot chain** (the first software that runs at power-on). Never touched.

What this means in practice:

- **Valve's image is not changed.** The image file is never edited, and it is checked
  byte-for-byte when it is used. Everything Quest-specific lives in a separate layer of our own
  files placed over Valve's files. Where a Valve service must not run on a Quest, the layer
  switches it off with a systemd "mask". It never replaces the contents of a Valve file.
- **The layer does override some of the image's effective behaviour:** the masks, hidden boot and
  firmware folders, and settings that apply safety limits to every service. Every such override is
  listed with the code that applies it.
- **The kernel is ours, built from Meta's published source.** Valve's own kernel is written for the
  Steam Frame's chip and cannot drive a Quest. So FrameShift builds a kernel from the source code
  Meta publishes for each Quest firmware release, with a small, reviewed set of changes.
- **The bootloader stays Meta's.** FrameShift never replaces or writes the Quest's boot chain.

**Why this way.**

- **Users get real SteamOS.** Running Valve's own build, rather than something SteamOS-like
  assembled from other parts, means Valve's software runs as Valve designed it, apart from the
  listed overrides. Updates can follow Valve's releases.
- **No redistribution.** Because Valve's image is used unmodified, FrameShift does not need to ship
  Valve's files at all. Users get SteamOS from Valve; FrameShift ships only its own code.
- **Safety lives in parts we own.** Valve's software was written for different hardware. Some of it
  writes firmware and boot partitions on the Steam Frame, and on a Quest those writes could damage
  the headset. Instead of editing Valve's software, FrameShift contains it. The pieces are a kernel
  guard that refuses boot-storage writes, masks on risky services, and our own thermal and battery
  service (section 4 says how far each has been proven).
- **Simple for users.** The project keeps to this route on purpose. Building a custom distribution
  stays a fallback only.

**What it is built for, and against.** The target hardware runs Meta Horizon OS, which is
Android-based. Android normally owns the headset's thermal protection, battery protection and
shutdown decisions. When FrameShift runs, Android does not. FrameShift must therefore provide those
protections itself before anything demanding runs (section 4).

---

## 2. The boot path

### 2.1 Today: a temporary boot, nothing flashed

Every FrameShift image run on a headset so far used **`fastboot boot`**. Fastboot is the Quest's
bootloader mode for talking to a PC over USB. With this command:

1. The PC sends a boot image into the headset's memory. The image holds our kernel and our small
   startup program (the "initramfs", the first program that runs once the kernel is up).
2. Meta's bootloader starts it **once**.
3. The image sends its results to the PC over a USB serial console (a plain text connection).
4. When the test is done, or a deadline is reached, the headset returns to the bootloader or to
   Meta Horizon OS.

Nothing is written to the headset's storage by FrameShift. The next normal power-on boots Meta
Horizon OS as usual.

What every test image does:

- **It proves it is running.** The PC sends a fresh one-time challenge and the image answers it,
  so a result cannot be confused with an earlier run.
- **It reports in a framed, checksummed record.** Damaged or incomplete records are rejected, never
  patched up.
- **It always returns the headset.** A deadline built into the image's first process returns the
  headset to the bootloader or to Meta Horizon OS, even if the PC side gives up.
- **"No lasting effect" is checked, not assumed.** Even a temporary boot runs firmware and kernel
  code. Each attempt is therefore bracketed by read-only before-and-after checks of the headset's
  identity, active slot and boot partitions, and by temperature readings.

The headset also loads, from its own storage, the parts Meta's bootloader always supplies: the
device tree (a description of the hardware) and Meta's vendor ramdisk. FrameShift reads them. It
does not ship or change them.

### 2.2 Planned: an installed boot (design only)

For a finished product, a headset should boot FrameShift when it is switched on, without a PC.

The chosen model is **slot takeover, with no dual-boot**. Quest headsets keep two copies of their
system ("A/B slots") for updates. FrameShift would install into one slot the way a Meta Horizon OS
update does, so a normal power-on boots FrameShift.

This is **research and design only**. No install has been tried and none is planned before the
first SteamOS boot. Any install method gets its own reviewed package and a bounded validation cycle
on a test unit before anything is offered to anyone. The design's goals are:

- a normal power-on must never put FrameShift's data at risk from a single wrong choice;
- an interrupted install must be recoverable;
- **installation is one-way.** Installing FrameShift replaces the headset's operating system.
  FrameShift provides no tool, guide or support for returning a headset to Meta Horizon OS, and
  the installer will say so plainly before it writes anything.

---

## 3. Our kernel

### 3.1 Starting point: Meta's published source

Meta publishes the GPL source of each Quest kernel release. FrameShift's Quest 3 kernel is built
from the exact published source of Meta Horizon OS v2.7 (Linux 5.10), the firmware version the
project targets.

The build is **reproducible**: rebuilding it gives bit-identical files. That lets anyone check that
a published kernel came from the published source and our recorded changes.

**The first FrameShift kernel** adds only what Valve's userspace needs to start, and nothing that
changes the kernel's internal interfaces:

- device nodes managed by the kernel (`devtmpfs`);
- file handles and automount support;
- Btrfs, the filesystem of Valve's root;
- extended attributes for in-memory filesystems.

An offline gate (`tools/kgate/`) checks every exported kernel symbol's version fingerprint against
the ones Meta's own driver modules expect. This is how we know those modules will load unchanged.

### 3.2 Meta's modules

Much of the Quest's hardware support (display, GPU, power and battery, sensors, fan, USB, Wi-Fi) is
in Meta's **loadable driver modules**. The first kernel and the guard kernel (section 4.1) load
**Meta's stock modules, unchanged, from the headset's own storage**. FrameShift ships none of
Meta's binaries and publishes no module list; the list is taken from the owner's own firmware.

That works only while our kernel keeps exactly the internal layout those modules were built
against. The kernel for Steam (section 3.3) cannot do that. It uses a module set **rebuilt from
Meta's published source** in the same reproducible build.

How well do the rebuilt modules match Meta's? Built with the first kernel's settings, all but one
matched the stock modules in the sections compared. The only differences were their version stamp
and build ID. That supports, but does not prove, that they come from the same code. The one
exception is a module whose published source has a few platform names removed.

### 3.3 The kernel for Steam (kernel test: passed on both units)

The kernel for Steam adds things that Valve's userspace and the Steam Frame build expect and
Meta's kernel lacks:

- **System V IPC and POSIX message queues.** These are ways for programs to talk to each other.
  Some systemd features use them, and the Steam client is reported to rely on them (community
  reports, not yet confirmed by us).
- **48-bit virtual addresses**, as in the kernel Valve ships with the Steam Frame build. Meta's
  kernel uses 39-bit. With 39-bit addresses, x86-64 and Windows programs running through
  translation layers get a much smaller address space (512 GiB instead of 128 TiB). A program that
  needs a fixed high address would fail. Nothing in Valve's image was found to strictly require
  48-bit.
- **The storage write guard** (section 4.1) and **the restart lockdown** (section 4.2), as
  separately named patch series.

These changes alter the kernel's internal layout, so the full module set has to be rebuilt (section
3.2). An emulator test showed that the IPC options alone are enough to make the kernel refuse
Meta's stock modules. Doing the IPC and 48-bit changes in one step avoids a second rebuild. A
39-bit control build is kept, to tell the two changes apart if the 48-bit one fails.

**Status: passed on both units.**

- Both variants rebuild bit-identically, and every rebuilt module resolves against its own kernel.
- In an emulator, both kernels refused one of Meta's stock modules, as predicted, while the earlier
  guard kernel accepted it.
- **First headset run (Quest 3, one unit, 2026-11-13 UTC): not passed.** The kernel booted cleanly,
  loaded its modules, and the write guard passed its full test again. But our own information
  script misread some kernel settings (it read only the first character of each value), so the
  run could not show that the new features were set as intended and is recorded as not passed.
  The script was fixed and tested offline.
- **2026-11-14 UTC, both units: passed.** Rebuilt modules loaded, all new settings read whole and
  correct, restart lockdown in tethered mode with download mode off, guard 411 of 411 again, no
  kernel warning. One unit passed on its replacement run, the other on its single run.

---

## 4. Safety systems

Each system below says what it protects against, how it works in brief, and how far it has been
tested. Until a protection is proven on the device, trials stay short, bounded and attended.

### 4.1 The storage write guard (fs-blkguard): **proven on hardware (both units)**

**Protects against:** any program, ours or Valve's, writing to the Quest's boot chain or its
unit-unique partitions.

Valve's update tools rewrite the whole boot chain on the Steam Frame after updates, and find their
target partitions by name. On a Quest, such a write could make the headset unbootable. FrameShift
does not rely on the names happening to differ.

**How it works:**

- It is a patch to our kernel (GPL-2.0, in `tools/blkguard/`). While it is armed, it refuses every
  way of writing a protected disk:
  - opening it for writing;
  - ordinary writes, discards and zero-outs;
  - partition-table changes;
  - low-level storage commands passed straight to the hardware;
  - every write request that reaches the disk, whatever filesystem or layer it came through.
- Protected partitions are recognised by their partition names as the kernel itself reads them. A
  disk carrying any protected name counts as boot storage, and all of it is guarded. A name missing
  from the list is therefore still covered.
- It starts in a protective mode as soon as the kernel starts. Our initramfs then raises it to a
  stricter mode (only after module loading has been switched off for good) and **seals** it. From
  then on it cannot be lowered or switched off while the system runs. The initramfs reads the
  state back, and refuses to start the next stage if it is not exactly as expected.
- The only opt-out is a kernel boot option, set when the boot image is built on the PC, so only the
  owner can use it.

**How it was tested:**

- **Offline,** in two kinds of virtual machine (QEMU and User-Mode Linux) and against simulated
  disks: tens of thousands of policy checks. Each of the guard's hooks was deliberately disabled in
  turn, and every disabled hook was caught. A fingerprint check shows the patch leaves Meta's
  module interface unchanged.
- **On hardware (boot-storage guard test), both Quest 3 units, 2026-10-20 and 2026-10-23 UTC:
  passed.** A probe in the test image tried **411 cases; all 411 behaved as expected, and 402 of
  them were refusals** of write or write-like requests, across 14 kinds of request. The guard was
  strict and sealed with the expected settings. Every protected partition the probe hashed was
  unchanged afterwards.
- **An earlier attempt, on 2026-10-19, needed a closer look before going on.** The kernel booted
  cleanly, but the probe stopped itself before arming because its reads were the wrong size for
  this storage. Nothing was written. The probe was fixed before the replacement attempt.
- **Every new kernel repeats the test.** It passed again on the kernel for Steam, on both units.

### 4.2 The restart lockdown and read-only fuses: **built into the kernel for Steam (on hardware: active on both units)**

**Protects against:** restart requests that do more than restart.

On these chips, the kernel turns a restart "reason" string into a code stored in a power-management
chip. Some codes make the headset start in special firmware-download or crash-dump modes, or
select other special boot modes. A script written for Android or for the Steam Frame could send
such a string by mistake. A headset sitting in a dump mode stays powered, with no operating system
watching its temperature.

**How it works:**

- The kernel accepts exactly three restart requests:
  - a plain restart;
  - "restart to the bootloader";
  - "restart to FrameShift's recovery" (on an installed system only).

  Exact matches only. Any other request is refused before anything shuts down.
- Download and dump modes are never armed, including through boot options. The controls for them,
  and the stored restart code, are read-only from programs.
- **Read-only fuses:** the chip's one-time-programmable fuse area is made read-only from programs
  too. The kernel can still read it.
- Whether the system is installed or tethered to a PC is fixed at boot and cannot be changed later.
- An owner who really needs a special mode can boot an image without the filter from the PC, as
  with the guard's opt-out.

**Tested so far:** offline unit tests of the patched code (about 1,300 checks, where Meta's stock
code fails 152 of them), bit-identical kernel builds, and emulator tests of the refused requests.
On hardware, as part of the kernel test, its state (tethered mode, download mode off, no write
access) was read back on both units; refusal of special requests is shown offline and in the
emulator.

### 4.3 The thermal and battery service (fs-thermald): **first step passed on two units**

**Protects against:** overheating and battery damage once Android is not running.

Meta keeps the skin (outer surface) temperature and battery shutdown limits in Android's userspace.
The kernel alone mitigates only partly (for example, with one CPU frequency step), and nothing in
it reliably forces a shutdown. A FrameShift system needs its own protection, and the project's rule
is that it is proven before the first SteamOS boot and the first GPU load.

**How it works (design and offline build):**

- It reads the headset's temperature sensors, the battery (through the Quest's own battery
  firmware, loaded from the headset), and the fan.
- **Cooling follows temperature, never screen state.** Each device follows its own Meta policy and
  thresholds, and clocks are never pushed beyond the manufacturer's tables.
- It works in levels. As temperatures rise it raises the fan floor and caps CPU and GPU speed. At
  Meta's shutdown limits, or at 3 % battery while discharging, it shuts the headset down
  gracefully, with timed forced fallbacks if a clean shutdown stalls.
- A missing, frozen or implausible sensor, or a faulty fan, makes it fail safe: fan up, speeds
  capped, shutdown if the fault persists. It warns the user before acting and names the faulty
  part.

**How it was tested:**

- **Offline:** hundreds of simulated scenarios, with the C implementation checked against an
  independent reference model. Review rounds removed false-shutdown and missed-shutdown paths.
- **On hardware (temperature sensor test), both Quest 3 units, 2026-10-18 UTC: passed.** This test
  runs under stock Meta Horizon OS, with no FrameShift image. It identified the sensors the service
  needs and read them through a short CPU load and cool-down. The headsets' fan-trip tables matched
  the service's built-in table on both units. The first run had found an error in that table and a
  timing defect in the test. Both were corrected and the test was re-run.
- **What it does not show:** it is not a test of FrameShift's own protection. The fan did not need
  to spin in the passing runs, so fan control was not exercised. Those are the thermal service
  tests, to run on the kernel for Steam.

### Things never to do (warnings)

These are warnings, not instructions. Each one can leave a headset unbootable or permanently changed.

- **Never write the boot-chain partitions** (the early boot firmware Meta signs, such as xbl, tz,
  hyp, aop and abl). FrameShift never does, and its write guard refuses it.
- **Never use emergency-download or flashing tools** to "recover" a headset. Hold the power button
  to turn it off instead, and ask for help.
- **Never choose "Switch Boot Slot"** in the bootloader menu unless a documented procedure tells you
  to. It changes which copy of the system starts, in ways that are hard to undo.
- **Never install Valve's own SteamOS update bundle on a Quest.** It carries the Steam Frame's
  kernel and boot firmware, and its updater would try to write them. FrameShift handles updates
  itself (section 6.1).
- **Never send special restart commands to the bootloader** beyond the plain restart and "restart to
  bootloader". Some trigger crash-dump or factory modes. FrameShift's kernel refuses them
  (section 4.2).

### 4.4 Supporting designs (design only)

- **Graceful emergency shutdown:** who powers the headset off, in what order, with what time
  limits, and what happens if a power-off call does not complete.
- **Device health:** a faulty sensor or peripheral never stops the headset from booting or being
  used. The user gets a short notice at each boot naming the faulty part, and safety faults go to
  the thermal shutdown path. This came from real sensor faults on the test units, which are
  recorded and factored into results, never compensated for.
- **Crash reporting is designed to be off by default.** Valve's crash-reporting hooks would be
  masked, so nothing would be sent from a FrameShift headset. Crash data stays on the device.

---

## 5. How SteamOS is loaded and protected

**"SteamOS boots"** is the first big milestone: Valve's unmodified SteamOS 0.4.5 starts on a
Meta Quest 3 and reaches a controlled text console, with no graphics yet.

**It is in progress: designed and tested in an emulator only. It has not run on a headset.**

The planned run:

1. **Boot.** The kernel for Steam and our initramfs start by `fastboot boot`, as in section 2.1.
   Nothing is flashed.
2. **Load.** A USB network link (proven on both units) carries Valve's signed SteamOS image from the
   PC **into the headset's memory**. It is never written to the headset's storage.
3. **Verify, twice.**
   - The image is mounted read-only through **dm-verity**, which checks every block against a
     reviewed hash tree each time it is read.
   - The whole image is also read through once, and its hash must equal the value in **Valve's own
     signed manifest**.
4. **Compose.** Our layer is placed over Valve's files (an "overlay"). It holds:
   - **109** unit masks for Valve services that must not run on a Quest (updaters, firmware and
     controller writers, partitioning and repair tools and others), plus a few masks for udev
     (device management), sysctl (kernel settings) and generator entries;
   - our settings and our own services.

   Valve's boot files and firmware folder are hidden.
5. **Lock down, then hand over.** Module loading is switched off, the storage guard is armed in its
   strict mode and sealed, and only then is Valve's own systemd started. It reaches our console
   target: a USB serial console, an SSH login on the USB link (keys only), and an automatic
   acceptance check.

**Emulator results so far.** These come from QEMU, an emulated ARM machine, running a kernel built
from the same Meta source with the guard, and Valve's real 0.4.5 image:

- Valve's unmodified systemd reached the console target with the guard armed. dm-verity accepted
  our hash tree and returned errors for deliberately corrupted data.
- All 109 masks held. No updater, partitioner or repair tool was started.
- With the masks removed as a test, Valve's services did run their writers, and the guard refused
  the write against a decoy disk. The decoy disks were unchanged.
- Shutdown, power-key and plain-restart paths worked.
- Restarts with special reason strings showed an incompatibility in our own procedure: Valve's
  newer systemd needs a different command form. The procedure is fixed and worked in a re-run.
- **A real problem was found and fixed.** The full read-through in step 3 first ran the emulated
  8 GiB machine out of memory. With the revised memory plan, the full check of Valve's image
  completes in an 8 GiB emulator with memory to spare, so it fits a Meta Quest 3. The Meta Quest 2
  (6 GB) will read the image from the PC instead.

Before SteamOS may boot on a headset, it needs:

- the boot-storage guard test passed (done on both units);
- the USB network test passed (done on both units);
- the kernel test passed on the kernel for Steam (done on both units);
- the thermal service tests passed on that kernel;
- a review of the exact package before use, with the session length treated as extended operation.

---

## 6. Updates, power and reset

These are **design decisions**. None is built for the headset yet, and some apply only to an
installed headset. **You download Valve's signed SteamOS image from Valve yourself,** guided by
the installer.

### 6.1 Updates

- **Valve's updater never runs on a Quest.** Steam's normal update screen is served by FrameShift's
  own update service instead.
- **Stable only, reviewed first.** Only Valve **stable** releases that FrameShift has reviewed are
  offered. A beta option may come later; it is not being built now.
- **Off by default.** Planned: updates are off by default; the details of turning them on are
  not settled yet.
- **From Valve, verified.** An update comes from Valve, never from FrameShift, and is checked
  against Valve's signature and FrameShift's reviewed list. FrameShift never hosts Valve's files.
  An update takes effect on the next restart, with automatic rollback.
- **No firmware updaters run on the headset.** The Quest's firmware stays Meta's.
- **The Steam client keeps updating itself** as it does on the Steam Frame. A "Restore Steam
  client" action is the safety net.

### 6.2 Power, restart and reset

- **Shut down** is a clean power-off with the emergency-shutdown timers behind it.
- **Restart,** in a tethered session, is a plain restart that lands in Meta Horizon OS. The PC
  starts FrameShift again. "Restart to bootloader" stays a PC-tool and developer option.
- **Sleep** is screen-off for now. Real suspend is a later goal, once it is proven safe.
- **The power button** works as on the Steam Frame, plus a 5-second hold that powers off cleanly
  even if Steam has hung.
- **Factory reset.** Steam's own Factory Reset button does nothing harmful at first. "Reset
  FrameShift", in FrameShift's menu and the PC tool, erases FrameShift's own data only (by
  destroying the encryption keys of its data volumes).

### 6.3 No way back to Meta Horizon OS

**Installation is one-way.** FrameShift provides no tool, guide or support for returning an
installed headset to Meta Horizon OS, and holds no Meta restore image. FrameShift itself never
writes boot storage, and its guard refuses such writes by design. The installer will state this
plainly before it writes anything.

---

## 7. What has been tested

Evidence levels, from strongest to weakest:

- **On hardware:** run on a Quest, with recorded output.
- **In an emulator:** run in QEMU or a similar virtual machine, or against a simulated device.
- **Offline:** builds, unit tests and fixtures, with no headset.
- **Design only:** written and reviewed, not built for a headset.
- **Not started.**

All hardware runs were by temporary boot or under stock Meta Horizon OS. Nothing was flashed. Dates
are UTC.

### On hardware (Meta Quest 3)

- **First shell (2026-10-08), one unit: passed.** An interactive shell from a kernel and initramfs
  we control, with a fresh challenge.
- **Early trials (2026-10-09 to 10-11), one unit.** Four genuine Valve programs under our init on
  the stock kernel, and two first display tests. Each reached our init. The outcomes were recorded
  as they came: a defect in our own test rule (fixed), an inconclusive record, and an image that lit
  up but was garbled.
- **Display test: a correct image on the panels (2026-10-13 and 10-14): passed.** A test pattern
  readable in each eye, with eye order and panel tilt corrected. Run first on one unit with older
  firmware, then on both units with Meta Horizon OS v2.7. **Not shown:** calibrated stereo,
  tracking, sustained use.
- **First kernel boot (2026-10-17), both units: passed.** A FrameShift-built kernel booted and
  loaded all of Meta's stock modules from the headset with no kernel warning.
- **Temperature sensor test (2026-10-18), both units, under stock Meta Horizon OS: passed after a
  corrected re-run.** The sensors the thermal service needs were found and read under a short CPU
  load, and the fan-trip tables matched. **Not shown:** FrameShift's own thermal protection.
- **Boot-storage guard test (2026-10-19 to 10-23), both units: passed.** On one unit the first
  attempt stopped before arming (nothing written) and the replacement attempt **passed**; the other
  unit **passed** on its one attempt. Each pass: 411 of 411 cases, 402 of them refusals, protected
  partitions unchanged, no kernel warning.
- **USB network test (2026-10-21 to 11-08), both units: passed.** A network link over the USB
  cable, next to the serial console, carried 8 MiB each way between our kernel and the PC, with
  matching hashes on both sides and no kernel warning. On one unit it passed on the third run: the
  first run stopped on our own PC-side tool before anything was sent, and the second failed because
  that tool took about 28 seconds to find the new network adapter while the headset listens for 10.
  Both stay on the record. With a faster tool, the adapter was ready in under 2 seconds. The other
  unit passed on its first attempt. **Not shown:** sustained or high-throughput networking.
- **Kernel test (2026-11-13 to 11-14), both units: passed after a corrected re-run on one unit.**
  The first run on one unit was recorded as not passed, because our own information script
  misread some kernel settings (section 3.3). After the fix, that unit's replacement run and the
  other unit's single run both passed: rebuilt modules loaded, new settings correct, restart
  lockdown in tethered mode with download mode off, guard 411 of 411 again.

### In an emulator

- **SteamOS boots (emulator only).** Valve's unmodified systemd reached our console target behind
  the guard and the masks. The full check of Valve's image completes in an 8 GiB emulator with
  memory to spare. A headset run comes after the thermal service tests.
- **Module refusal.** Meta's stock modules are refused by the kernel for Steam, as predicted.

### Offline

- **Thermal service:** levels, caps, fan rules, fail-safe and shutdown path. Simulated scenarios
  only; the device tests are pending, on the kernel for Steam.
- **Restart lockdown and read-only fuses:** only safe restart requests accepted, dump and download
  modes never armed. Offline unit tests pass; the builds are bit-identical. On hardware, its state
  was read back on both units during the kernel test.
- **Meta Quest 3S, Meta Quest 2 and Meta Quest Pro:** offline work only. No FrameShift run yet.

### Design only

- Installed boot and updates.

### Not started

- **GPU test and compositor:** graphics on the GPU, then on the panels, then Valve's compositors.
- **Everything a user sees and moves:** the desktop in the headset, head tracking, controllers and
  hands.

---

## 8. What comes next

The project plans by milestones, not dates.

1. **Thermal service tests:** the full thermal and battery service on the kernel for Steam, in
   three groups: first watching the sensors with CPU limits, then the fan and the battery
   (through the headset's own battery firmware), then throttling and the shutdown path.
2. **SteamOS boots** on a headset (section 5).
3. **GPU test.**
   - First, an internal test renders an image offscreen.
   - Then a FrameShift kernel module presents the Quest's GPU to Valve's own, unchanged graphics
     driver, in the form the Steam Frame build expects.
   - Then the panels.
   - Then Valve's compositors (the programs that combine windows into the final picture).
4. **The headset experience.**
   - The SteamOS desktop visible in the headset at a fixed position.
   - Head rotation.
   - Full head tracking (position and rotation) with an open-source tracker. Its pass mark is to
     match Meta Horizon OS, measured on the same headset.
   - The Meta Quest 3's bundled Touch Plus controllers.
5. **With the controllers, an installable test image for testers.** Before then, in parallel: the
   installed boot and PC installer, the update service, a long sustained-load thermal test, a legal
   and licence check, tester documentation and a feedback channel. You download Valve's signed
   image from Valve, guided by the installer.

The Meta Quest 3S is developed in tandem with the Meta Quest 3. The Meta Quest 2 and Meta Quest Pro
follow, and all four move together after the first SteamOS boot.

---

## 9. Principles

- **Owner control.** Owners keep full administrator control of their headset and its OS.
  FrameShift blocks only unauthenticated or hidden routes to system privileges, and safety settings
  have documented owner opt-outs. Restrictions in test images are scoped to the experiment.
- **Safety first.** Valve's update and firmware machinery never runs on a Quest. FrameShift never
  writes the boot chain, fuses or secure-boot state, and never overclocks beyond the manufacturer's
  tables. Each new protection is proven on the device before the step that needs it. Until the
  thermal service is proven, runs are short, bounded and attended, with temperature limits before,
  during and after: a run may start only below 40 °C, and it stops at 43 °C. See
  [Things never to do](#things-never-to-do-warnings).
- **Boot before flash; never brick.** Every image is first proven by a temporary boot (`fastboot
  boot`, nothing written) before writing it to a headset is even proposed. Any future install or
  update method must show, before it is used, that every failure leaves the headset able to start,
  and it never touches the boot chain. FrameShift assumes an already-unlocked headset; how to
  unlock one is outside its scope.
- **One-way install.** Installing FrameShift replaces the headset's operating system. There is no
  supported way back to Meta Horizon OS.
- **No redistribution of Valve or Meta files.** This repository contains no Valve or Meta software,
  firmware or images. Users get SteamOS from Valve. Meta's drivers and firmware are used from the
  user's own headset at run time, or rebuilt from Meta's published source.
- **Clean-room study.** Third-party software may be studied privately to learn how it works. What
  is learned is written down as functional facts, never as code, and FrameShift's code is written
  from those facts. Study notes and disassembly stay private and are never published.
- **Evidence honesty.** Results are reported at the level they were shown, failures included, and
  never re-graded afterwards.

---

## 10. How claims are checked

- **Evidence levels.** Every result in this guide says how it was shown: on hardware, in an
  emulator, offline, or design only.
- **Reviewed before use.** Every change that runs on a headset is reviewed before use, and every
  boot is approved and attended by the headset's owner.
- **One attempt, no automatic retries.** Each attempt uses a fresh one-time code that binds the
  result to that attempt. A result that is not clean blocks the next step until it is understood.
- **Reproducible builds.** Kernels, modules and tools are rebuilt bit-identically, and the exact
  files that were reviewed are the files that run.
- **AI assistance.** FrameShift is developed with the help of AI tools. A human project owner
  directs the work, reviews it and signs off on every change and every device action.

*This guide is updated at each milestone. Corrections to earlier statements are made visibly.*

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
