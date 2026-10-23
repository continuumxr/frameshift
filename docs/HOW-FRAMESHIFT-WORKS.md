# How FrameShift works

**Licence:** CC-BY-4.0 (our own documentation; [PROVENANCE-POLICY.md](PROVENANCE-POLICY.md) §6).

*A plain-language guide to what FrameShift is, how it boots, how it keeps a headset safe, and what
has actually been shown so far. It is updated at each milestone. **Current as of 2026-10-23 UTC**
(journal up to J-244). The status line of the root [README](../README.md) is the project's single
status source and may lag this guide between exports. [JOURNAL.md](JOURNAL.md) is the day-by-day
record; "J-222" and similar labels are its entry numbers.*

**Who this is for:** technically curious users, testers and contributors. Like the project itself,
this guide assumes you already have an unlocked headset.

---

## The short version

- **What it is.** FrameShift ports Valve's SteamOS for the Steam Frame headset to Meta Quest
  headsets. Valve's operating system image is used **unmodified**.
- **Which headsets.** Quest 3 and Quest 3S first, then Quest 2 and Quest Pro. Today all hands-on
  work is on the Quest 3. The other three are build and research work only.
- **How it fits together.** Valve's image sits on top. Under it are a thin layer of FrameShift's own
  files and a FrameShift-built Linux kernel (made from Meta's published source). Meta's bootloader
  is never touched.
- **Where it stands.** Early development. There is no release, no installer and no bootable
  SteamOS image yet.
- **Proven on real hardware (Quest 3, two test units).** A first shell. A correct test image on the
  panels. A FrameShift-built kernel that boots. The sensors the thermal service needs, found and
  read. All of this used temporary boots or stock Horizon OS; nothing was flashed.
- **The storage write guard** (a kernel feature that refuses writes to the headset's boot storage)
  **passed on hardware on one unit**: 411 test cases, all as expected, 402 of them refusals. The
  second unit is still to do.
- **SteamOS itself has run only in an emulator**, and only as far as a text console. That run found
  a real memory problem, which is being fixed. On a headset, only a few individual Valve programs
  have run (in early trials), and nothing graphical from SteamOS has run anywhere.
- **Safety comes first.** The write guard, a restart-request lockdown (offline tests only), and a
  thermal and battery service (offline build; its first hardware step passed) are the planned
  protections. Early runs are short, bounded and attended.
- **Not started:** the GPU, graphics, the SteamOS desktop in the headset, head tracking and
  controllers. **Design only:** installed boot, updates, factory reset and a way back to Horizon OS.
- **What comes next.** The guard on the second unit, then the Steam-ready kernel (K1i), then the
  thermal service on that kernel, then the first SteamOS boot on a headset (R-1), then graphics.
  The first installable test image is planned for the controller milestone (V3).
- **Honest reporting.** Every claim is labelled with how it was shown, and failed or unclear
  results stay on the record.

---

## Contents

1. [The big picture](#1-the-big-picture)
2. [The boot path](#2-the-boot-path)
3. [Our kernel](#3-our-kernel)
4. [Safety systems](#4-safety-systems)
5. [How SteamOS is loaded and protected (R-1)](#5-how-steamos-is-loaded-and-protected-r-1)
6. [Updates, reset and Return to Horizon](#6-updates-reset-and-return-to-horizon)
7. [What has been tested](#7-what-has-been-tested)
8. [What comes next](#8-what-comes-next)
9. [Principles](#9-principles)
10. [How claims are checked](#10-how-claims-are-checked)

---

## 1. The big picture

**What FrameShift is.** Valve published the operating system image (SteamOS, a Linux-based system)
of the Steam Frame, its headset built on an ARM processor. FrameShift ports that SteamOS,
**unmodified**, to Meta Quest headsets.

The first targets are the **Quest 3 and the Quest 3S**, developed together for a joint launch,
followed by the **Quest 2 and the Quest Pro**. After the first SteamOS boot milestone (R-1,
section 5), all four are meant to move forward in lockstep.

Today the hands-on work is on the Quest 3 only. The work on the other three is offline (build and
research only), and no FrameShift image has run on them. The project has two Quest 3 test units and
one Quest 2 unit, and no Quest 3S or Quest Pro unit yet.

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

- **Valve's image is not changed.** In the planned design, the image file is never edited, and it
  is checked byte-for-byte when it is used. Everything Quest-specific lives in a separate layer of
  our own files placed over Valve's files. Where a Valve service must not run on a Quest, the
  layer switches it off with a systemd "mask". It never replaces the contents of a Valve file.
- **The layer does override some of the image's effective behaviour:** the masks, hidden boot and
  firmware folders, and settings that apply safety limits to every service. Every such override is
  listed in the package that uses it.
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

**What it is built for, and against.** The target hardware runs Meta's Horizon OS, which is
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
   Horizon OS.

Nothing is written to the headset's storage by FrameShift. The next normal power-on boots Horizon
OS as usual.

What every test image does:

- **It proves it is running.** The PC sends a fresh one-time challenge and the image answers it,
  so a result cannot be confused with an earlier run.
- **It reports in a framed, checksummed record.** Damaged or incomplete records are rejected, never
  patched up.
- **It always returns the headset.** A deadline built into the image's first process returns the
  headset to the bootloader or Horizon, even if the PC side gives up.
- **"No lasting effect" is checked, not assumed.** Even a temporary boot runs firmware and kernel
  code. Each attempt is therefore bracketed by read-only before-and-after checks of the headset's
  identity, active slot and boot partitions, and by temperature readings.

The headset also loads, from its own storage, the parts Meta's bootloader always supplies: the
device tree (a description of the hardware) and Meta's vendor ramdisk. FrameShift reads them. It
does not ship or change them.

### 2.2 Planned: an installed boot (design only)

For a finished product, a headset should boot FrameShift when it is switched on, without a PC.

The owner's chosen model is **slot takeover, with no dual-boot**. Quest headsets keep two copies of
their system ("A/B slots") for updates. FrameShift would install into one slot the way a Horizon
OS update does, so a normal power-on boots FrameShift.

This is **research and design only**. No install has been tried and none is planned before R-1.
Any install needs its own reviewed package and a bounded install-and-restore validation cycle on a
test unit before anything is offered to anyone. The design's goals, set by the owner, are:

- a normal power-on must never put FrameShift's data at risk from a single wrong choice;
- an interrupted install must be recoverable;
- there must always be a documented way back to Horizon OS (section 6.3).

---

## 3. Our kernel

### 3.1 Starting point: Meta's published source

Meta publishes the GPL source of each Quest kernel release. FrameShift's Quest 3 kernel is built
from the exact published source of Horizon OS v2.7 (Linux 5.10), the firmware version the project
targets.

The build is **reproducible**: rebuilding it gives bit-identical files. That lets anyone check that
a published kernel came from the published source and our recorded changes.

**K1a, the first FrameShift kernel,** adds only what Valve's userspace needs to start, and nothing
that changes the kernel's internal interfaces:

- device nodes managed by the kernel (`devtmpfs`);
- file handles and automount support;
- Btrfs, the filesystem of Valve's root;
- extended attributes for in-memory filesystems.

An offline gate (`tools/kgate/`) checks every exported kernel symbol's version fingerprint against
the ones Meta's own driver modules expect. This is how we know those modules will load unchanged.

### 3.2 Meta's modules

Much of the Quest's hardware support (display, GPU, sensors, fan, battery, Wi-Fi) is in Meta's
**loadable driver modules**. K1a and K1g (the kernel used for the write-guard test, section 4.1)
load **Meta's stock modules, unchanged, from the headset's own storage** (95 of them). FrameShift
ships none of Meta's binaries.

That works only while our kernel keeps exactly the internal layout those modules were built
against. The Steam-ready kernel (K1i) cannot do that. It uses a module set **rebuilt from Meta's
published source** in the same reproducible build.

How well do the rebuilt modules match Meta's? Built with K1a's settings, all but one matched the
stock modules in the sections compared. The only differences were their version stamp and build ID.
That supports, but does not prove, that they come from the same code. The one exception is a module
whose published source has a few platform names removed.

### 3.3 K1i: the kernel for Steam (in progress)

K1i adds things that Valve's userspace and the Frame build expect and Meta's kernel lacks:

- **System V IPC and POSIX message queues.** These are ways for programs to talk to each other.
  Some systemd features use them, and the Steam client is reported to rely on them (community
  reports, not yet confirmed by us).
- **48-bit virtual addresses**, as in the kernel Valve ships with the Frame build. Meta's kernel
  uses 39-bit. With 39-bit addresses, x86-64 and Windows programs running through translation
  layers get a much smaller address space (512 GiB instead of 128 TiB). A program that needs a
  fixed high address would fail. Nothing in Valve's image was found to strictly require 48-bit.
- **The storage write guard** (section 4.1) and **the restart-state lockdown** (section 4.2), as
  separately named patch series.

These changes alter the kernel's internal layout, so the full module set has to be rebuilt (section
3.2). An emulator test showed that the IPC options alone are enough to make the kernel refuse
Meta's stock modules. Doing the IPC and 48-bit changes in one step avoids a second rebuild, gate
and review round. A 39-bit control image is kept, to tell the two changes apart if the 48-bit one
fails.

**Status: built and analysed offline, not run on a headset.**

- Both variants rebuild bit-identically.
- Every rebuilt module resolves against its own kernel.
- In an emulator, both K1i kernels refused one of Meta's stock modules, while the earlier guard
  kernel accepted it.
- The device-run package is built but not yet submitted. The restart-lockdown builds were still
  running at the time of writing.

---

## 4. Safety systems

Each system below says what it protects against, how it works in brief, and how far it has been
tested. Until a protection is proven on the device, trials stay short, bounded and attended.

### 4.1 The storage write guard (fs-blkguard): **proven on hardware (one unit)**

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
- **On hardware (milestone K1g), Quest 3 Unit 2, 2026-10-20 UTC: PASS.** A probe in the test image
  tried **411 cases; all 411 behaved as expected, and 402 of them were refusals** of write or
  write-like requests, across 14 kinds of request. The guard was strict and sealed with the
  expected settings. Every protected partition the probe hashed was unchanged afterwards (J-222).
- **The first attempt, on 2026-10-19, came out REVIEW** (a result that needs a human look before
  going on). The kernel booted cleanly, but the probe stopped itself before arming because its
  reads were the wrong size for this storage. Nothing was written. The fix was reviewed before the
  replacement attempt (J-207, J-212).
- **Still to do:** the same test on Unit 1, and again on every new kernel (K1i included).

### 4.2 The restart-state lockdown and read-only fuses: **in progress (offline tests only)**

**Protects against:** restart requests that do more than restart.

On these chips, the kernel turns a restart "reason" string into a code stored in a power-management
chip. Some codes make the headset start in special firmware-download or crash-dump modes, or
select other special boot modes. A script written for Android or for the Steam Frame could send
such a string by mistake. A headset sitting in a dump mode stays powered, with no operating system
watching its temperature.

**How it works** (patch series SA-C1, for K1i):

- The kernel accepts exactly three restart requests:
  - a plain restart;
  - "restart to the bootloader";
  - "restart to FrameShift's recovery" (on an installed system only).

  Exact matches only. Any other request is refused before anything shuts down.
- Download and dump modes are never armed, including through boot options. The controls for them,
  and the stored restart code, are read-only from programs.
- **Read-only fuses (owner decision):** the chip's one-time-programmable fuse area is made
  read-only from programs too. The kernel can still read it.
- Whether the system is installed or tethered to a PC is fixed at boot and cannot be changed later.
- An owner who really needs a special mode can boot an image without the filter from the PC, as
  with the guard's opt-out.

**Tested so far:** offline unit tests of the patched code (about 1,300 checks, where Meta's stock
code fails 152 of them), with internal reviews applied. The kernel builds have just started, and
the emulator tests come after them. **Nothing has run on a headset.** The device run comes with
K1i.

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
  independent reference model. Several rounds of internal review removed false-shutdown and
  missed-shutdown paths.
- **On hardware (milestone T0), both Quest 3 units, 2026-10-18 UTC: PASS.** T0 runs under stock
  Horizon OS, with no FrameShift image. It identified the sensors the service needs and read them
  through a short CPU load and cool-down. The headsets' fan-trip tables matched the service's
  built-in table on both units. The first run had found an error in that table and a timing defect
  in the test. Both were corrected and the test was re-run (J-197, J-205, J-206).
- **What T0 does not show:** it is not a test of FrameShift's own protection. The fan did not need
  to spin in the passing runs, so fan control was not exercised. Those are stages T1 to T5, to run
  on the K1i kernel.

### Things never to do (warnings)

These are warnings, not instructions. Each one can leave a headset unbootable or permanently changed.

- **Never write the boot-chain partitions** (the early boot firmware Meta signs, such as xbl, tz, hyp, aop and abl).
  FrameShift never does, and its write guard refuses it.
- **Never use emergency-download or flashing tools** to "recover" a headset. Hold the power button to turn it off
  instead, and ask for help.
- **Never choose "Switch Boot Slot"** in the bootloader menu unless a documented procedure tells you to. It changes
  which copy of the system starts, in ways that are hard to undo.
- **Never install Valve's own SteamOS update bundle on a Quest.** It carries the Steam Frame's kernel and boot
  firmware, and its updater would try to write them. FrameShift handles updates itself (section 6.1).
- **Never send special restart commands to the bootloader** beyond the plain restart and "restart to bootloader".
  Some trigger crash-dump or factory modes. FrameShift's kernel refuses them (section 4.2).

### 4.4 Supporting designs (design only)

- **Graceful emergency shutdown:** who powers the headset off, in what order, with what time
  limits, and what happens if a power-off call does not complete.
- **Device health:** a faulty sensor or peripheral never stops the headset from booting or being
  used. The user gets a short notice at each boot naming the faulty part, and safety faults go to
  the thermal shutdown path. This came from real sensor faults on the test units, which are
  recorded and factored into results, never compensated for.
- **Crash reporting is designed to be off by default.** Valve's crash-reporting hooks would be
  masked, so nothing would be sent from a FrameShift headset. Crash data stays on the device.

Details: [thermal-control-design.md](research/thermal-control-design.md),
[emergency-shutdown-design.md](research/emergency-shutdown-design.md),
[device-health-design.md](research/device-health-design.md) and
[PROJECT_SETUP.md](PROJECT_SETUP.md) §6A.

---

## 5. How SteamOS is loaded and protected (R-1)

R-1, **"SteamOS boots"**, is the first big milestone. Valve's unmodified SteamOS 0.4.5 starts on a
Quest 3 and reaches a controlled text console, with no graphics yet.

**It is in progress: designed and tested in an emulator only. It has not run on a headset.**

The planned run:

1. **Boot.** The K1i kernel and our initramfs start by `fastboot boot`, as in section 2.1. Nothing
   is flashed.
2. **Load.** A USB network link (N1, built and reviewed; device test pending) carries Valve's
   signed SteamOS image from the PC **into the headset's memory**. It is never written to the
   headset's storage.
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
- Restarts with special reason strings showed a real incompatibility in our own procedure: Valve's
  newer systemd needs a different command form. The procedure is fixed; the emulator re-run is
  still to come.
- **A real problem was found.** The full read-through in step 3 ran the emulated 8 GiB machine out
  of memory and stopped it. The memory plan is being revised before any device package.

Before R-1 may run on a headset, it needs:

- K1g passed (done on Unit 2);
- the K1i kernel run;
- the thermal service stages T1 to T5 on that kernel;
- the N1 link test;
- a review of the session length as extended operation;
- concurrence from the external review board on the concrete package.

---

## 6. Updates, reset and Return to Horizon

These are **design decisions** (owner decisions recorded 2026-10-19 UTC). None is built for the
headset yet. Each needs its own reviewed package, and some apply only to an installed headset.

### 6.1 Updates

- **Valve's updater never runs on a Quest.** Steam's normal update screen is served by FrameShift's
  own update service instead.
- **Stable only, reviewed first.** Only Valve **stable** releases that FrameShift has reviewed are
  offered. A beta option may come later; it is not being built now.
- **From Valve, verified.** The headset downloads Valve's signed update directly from Valve. It
  checks the update against Valve's signature and FrameShift's reviewed list. The PC tool is the
  offline fallback. FrameShift never hosts Valve's files. An update takes effect on the next
  restart, with automatic rollback.
- **No firmware updaters run on the headset.** The Quest's firmware stays Meta's.
- **The Steam client keeps updating itself** as it does on the Frame. A "Restore Steam client"
  action is the safety net.

### 6.2 Power, restart and reset

- **Shut down** is a clean power-off with the emergency-shutdown timers behind it.
- **Restart,** in a tethered session, is a plain restart that lands in Horizon OS. The PC starts
  FrameShift again. "Restart to bootloader" stays a PC-tool and developer option.
- **Sleep** is screen-off for now. Real suspend is a later goal, once it is proven safe.
- **The power button** works as on the Frame, plus a 5-second hold that powers off cleanly even if
  Steam has hung.
- **Factory reset.** Steam's own Factory Reset button does nothing harmful at first. "Reset
  FrameShift", in FrameShift's menu and the PC tool, erases FrameShift's own data only (by
  destroying the encryption keys of its data volumes) and never touches anything of Horizon's.

### 6.3 Return to Horizon

**PC-guided only.** FrameShift erases its own data and restarts into the bootloader. The PC tool
then restores Meta's own boot image and walks the user through Meta's own factory reset.

An in-headset "switch back" button is not planned. FrameShift itself must never write boot storage,
and the guard refuses it by design.

---

## 7. What has been tested

Evidence levels, from strongest to weakest:

- **On hardware:** run on a Quest, with recorded output.
- **In an emulator:** run in QEMU or a similar virtual machine, or against a simulated device.
- **Offline:** builds, unit tests and fixtures, with no headset.
- **Design only:** written and reviewed, not built for a headset.
- **Not started.**

All hardware runs were by temporary boot or under stock Horizon OS. Nothing was flashed. Dates are
UTC. The names in bold (M1, K1a and so on) are the project's milestone codes.

### On hardware (Quest 3)

- **M1, first shell (2026-10-08), one unit: passed.** An interactive shell from a kernel and
  initramfs we control, with a fresh challenge.
- **Early trials (2026-10-09 to 10-11), one unit.** Four genuine Valve programs under our init on
  the stock kernel, and two first display tests. Each reached our init. The outcomes were recorded
  as they came: a test-rule defect (fixed), an inconclusive record, and an image that lit up but
  was garbled.
- **M2, correct image on the panels (2026-10-13 and 10-14): passed.** A test pattern readable in
  each eye, with eye order and panel tilt corrected. Run first on Unit 1 with older firmware, then
  on both units with Horizon OS v2.7. **Not shown:** calibrated stereo, tracking, sustained use.
- **K1a, our own kernel boots (2026-10-17), both units: passed.** A FrameShift-built kernel booted
  and loaded all 95 of Meta's stock modules with no kernel warning.
- **T0, thermal sensors identified (2026-10-18), both units, under stock Horizon OS: passed after a
  corrected re-run.** The sensors the thermal service needs were found and read under a short CPU
  load, and the fan-trip tables matched. **Not shown:** FrameShift's own thermal protection.
- **K1g, storage write guard (2026-10-19 to 10-23), both units: passed.** On Unit 2 the first
  attempt came out REVIEW (the probe stopped before arming; nothing written) and the replacement
  attempt **passed**. Unit 1 **passed** on its one attempt (2026-10-23). Each pass: 411 of 411
  cases, 402 of them refusals, protected partitions unchanged, no kernel warning.
- **N1, USB network link (2026-10-21 and 10-23), Unit 2: not yet passed.** The first run stopped
  on our own PC-side tool before anything was sent (fixed). The second run brought the headset's
  side of the link up exactly as designed, but our PC-side tool took about 28 seconds to find the
  new network adapter while the headset listens for 10, so the transfer never started: **N1 FAIL**,
  a timing problem in our own PC tool. A faster tool is built; another run needs a new review.

### In an emulator

- **R-1, SteamOS boots (emulator only).** Valve's unmodified systemd reached our console target
  behind the guard and the masks. The memory problem found in the full read-through has a fix: the
  full check of Valve's image now completes in an 8 GB emulator with memory to spare. Quest 2
  (6 GB) will read the image from the PC instead. A device run has not yet been proposed.
- **K1i module refusal.** Meta's stock modules are refused by the K1i kernel, as predicted.

### Offline

- **Thermal service, parts 1 and 2:** levels, caps, fan rules, fail-safe and shutdown path.
  Simulated scenarios only; device stages T1 to T5 are pending, on K1i.
- **K1i, the kernel for Steam:** IPC features, 48-bit addresses and the rebuilt module set. Built
  bit-identically; the device run is pending.
- **Restart lockdown (SA-C1) and read-only fuses:** only safe restart requests accepted, dump and
  download modes never armed. Offline unit tests pass; the builds are done and bit-identical.
- **Quest 3S, Quest 2 and Quest Pro:** offline work only. No FrameShift run yet.

### Design only

- Installed boot, updates, factory reset and Return to Horizon. Owner decisions are recorded.

### Not started

- **G1 to G3, GPU and compositor:** graphics on the GPU, then on the panels, then Valve's
  compositors.
- **V0 to V5, everything a user sees and moves:** the desktop in the headset, head tracking,
  controllers and hands.

The day-by-day record, including every result that did not go as hoped, is in
[JOURNAL.md](JOURNAL.md).

---

## 8. What comes next

The order below is the owner's. The project plans by milestones, not dates (the milestone table is
in [PROJECT_SETUP.md](PROJECT_SETUP.md) §3).

1. **K1g on Unit 1,** and **N1** (the USB network link) on Unit 2.
2. **K1i:** the Steam-ready kernel with its rebuilt modules and the restart lockdown, booted on both
   units, with the guard proven again on it.
3. **TS T1 to T5:** the full thermal and battery service on K1i (sensors, CPU and GPU caps, fan,
   battery through the headset's own battery firmware, the shutdown path).
4. **R-1, SteamOS boots,** after the memory plan is revised (section 5).
5. **G1 to G3, the GPU.**
   - First, an internal test renders an image offscreen.
   - Then a FrameShift kernel module presents the Quest's GPU to Valve's own, unchanged graphics
     driver, in the form the Frame build expects.
   - Then the panels.
   - Then Valve's compositors (the programs that combine windows into the final picture).
6. **V0 to V3, the headset experience.**
   - **V0:** the SteamOS desktop visible in the headset at a fixed position.
   - **V1:** head rotation.
   - **V2:** full 6DoF head tracking (position and rotation) with an open-source tracker. Its pass
     mark is to match Horizon OS, measured on the same headset.
   - **V3:** the Quest 3's bundled controllers.
7. **At V3, an installable test image for testers.** Before then, in parallel: the installed boot
   and PC installer, Return to Horizon, the update service, the thermal soak test (a long
   sustained-load run), a legal and licence check, tester documentation and a feedback channel. The
   installer will fetch Valve's signed image from Valve.

The Quest 3S is developed in tandem with the Quest 3 for a joint launch. The Quest 2 and Quest Pro
follow, and all four move together after R-1.

---

## 9. Principles

- **Owner control.** Owners keep full administrator control of their headset and its OS.
  FrameShift blocks only unauthenticated or hidden routes to system privileges, and safety settings
  have documented owner opt-outs. Restrictions in test images are scoped to the experiment.
- **Safety first.** Valve's update and firmware machinery never runs on a Quest. FrameShift never
  writes the boot chain, fuses or secure-boot state, and never overclocks beyond the manufacturer's
  tables. Each new protection is proven on the device before the step that needs it. Until the
  thermal service is proven, runs are short, bounded and attended, with temperature limits before,
  during and after. The full rules are in [PROJECT_SETUP.md](PROJECT_SETUP.md) §6A and the
  ["Do not go here" list](JOURNAL.md#do-not-go-here) in the journal.
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

- **Evidence tags.** Project documents tag claims as measured on hardware, read from a named file,
  derived, inferred, or open (see the root [README](../README.md)). This guide uses plain words for
  the same levels.
- **Reviews.** Every package and report is checked by internal adversarial reviews (independent
  reviewers looking for safety gaps, overclaims and mistakes) before it goes further. Every boot
  attempt on a headset also needs the concurrence of an external review board on the exact
  package, plus the owner's sign-off at the headset.
- **One attempt, no automatic retries.** Each attempt uses a fresh one-time code that binds the
  result to that attempt. A result that is not clean blocks the next step until it is reviewed.
- **Reproducible builds.** Kernels, modules and tools are rebuilt bit-identically, and the exact
  files that were reviewed are the files that run.
- **AI assistance.** FrameShift is developed with AI assistance, disclosed in the root
  [README](../README.md). A human project owner directs the work and approves every device action.

*This guide is updated at each milestone. Corrections to earlier statements are recorded visibly in
the journal's Corrections table.*
