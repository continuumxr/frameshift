# FrameShift — project setup

*Edited for publication: names and links removed or paraphrased.*

**Read this first.** It defines what the project is, what it assumes, and what
the first work is. For the story so far — what worked, what didn't, and what not
to do — read **`docs/JOURNAL.md`**.

**Name:** the project is **FrameShift** (PM decision, 2026-10-07; formerly
"FrameShift OS"). It ports an existing OS rather than building one, so the
name carries no "OS". Use "Steam" and "SteamOS" only to explain what the
project is and how it works — never as part of our own names.

**Revised 2026-10-07** to adopt `FrameShift_Chair_Continuity_Directive.md`.
That document changed the device order, the target list and the claim-tag
vocabulary. `ERRATA-002.md` records exactly what it superseded and why; read it
if any older document appears to contradict this one.

Claim tags, per ruling **FS-R-001** (2026-10-07), which restored the
vocabulary of `CHAIR_DIRECTIVE.md` §3: **[M]** measured on hardware, with the
output shown · **[D]** derived from something measured, with the derivation
stated · **[C]** inferred, plausible, unconfirmed · **[O]** open.

**Static artifact observations are marked [M-static]**, with the artifact
named — a read of an image, a dump or a file, not an observation of running
hardware. **[M]** alone is reserved for hardware. **[C]** remains in use for
inference. The continuity directive's `[I]` tag is not used (FS-R-001;
`ERRATA-002.md` §3).

---

## 0. The premise

**Port SteamOS to standalone VR headsets.**

Valve has published a Steam Frame ARM image. This is therefore a port of
SteamOS, not the construction of something SteamOS-like out of Arch ARM or
postmarketOS. **[C] Working hypothesis:** Valve's userspace can run largely as
shipped, so the effort concentrates on the kernel, the device tree, and the
display and sensor stack. Whether that holds on Quest hardware is unproven until
a Valve-derived rootfs boots on one (FS-R-002 rev. §7).

Image in hand, at `firmware/SteamOS/`:

```
steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2     4.07 GB
steamframe-oobe-repair-20260922.5153644-0.3.0.img         7.00 GB  decompressed
```

**[M-static] Steam Frame is SM8650 — Snapdragon 8 Gen 3**, board name `deckard`. Two
witnesses inside the image: `compatible = "qcom,sm8650-deckard"` in the device
tree embedded in its U-Boot FIT, and `adsp_lite_sm8650.mbn` on its ESP. See
FS-A-001 (private review record).

**[C] The image is a research input, not proof of drop-in compatibility.** The
continuity directive is explicit on this and it is worth restating: nothing in
it has been observed running on any device we hold.

### 0.0 Distribution model (PM, 2026-10-10, J-83/J-85; Chair rulings FS-R-011 §7, J-104)

**Ship FrameShift's code plus an installer; Valve's image is never
redistributed by us.** The user obtains **Valve's image unmodified** from
Valve, and our installer slots it in (option 1 of
`docs/research/valve-packages-licensing.md`). Arbiter assessment and
architecture: `docs/research/valve-image-slot-in.md`.
*Note (FS-R-011 §7 D6, J-104): "our own code only" is inaccurate for any
image that contains BusyBox, a kernel or statically linked glibc (our stage
images already do). Track the source, licence, notice and linking
obligations of every third-party binary we ship, as for our own code.*
- **Image source:**
  - primary: the signed **stable** update bundle, fetched on the user's
    machine and verified against Valve's `stable_keyring.pem`;
    *(FS-R-011 §7 D7: the verification keys and the reviewed allowlist are
    anchored independently, and the verity digest is bound to the trusted
    FrameShift policy; a keyring downloaded beside an image cannot
    authenticate itself because its filename says stable. A trusted
    "stable" signing key does not by itself establish a stable manifest
    branch.)*
  - first install: Valve's public Frame recovery image, accepted only if
    its hash is on our signed allowlist. *(FS-R-011 §7 D7: the supplied
    recovery manifest says branch **main/OOBE**, so it does not meet a
    literal "manifest branch must equal stable" rule. Using it as the
    first-install base needs an **explicit PM policy exception** for that
    exact official recovery input, separately pinned and reviewed; it is
    never relabelled stable. Open [O], below.)*
  - We host nothing of Valve's, and we may ask Valve in parallel.
  - Valve's whole-device flashing packages are never used; only the
    verified rootfs range of the recovery image. **Exclusion accepted
    (FS-R-011 §7 D5):** the installer may reject Valve's flashing packages
    categorically and accept only reviewed rootfs inputs. For an accepted recovery image
    it parses and verifies the exact allowlisted rootfs range; the whole
    image and Valve's flashing machinery are never handed to a Quest, and
    the image's GPT is input metadata, never a target partition-table
    instruction.
- **Boot:**
  - our kernel and initramfs; the Valve rootfs byte-unmodified, read-only
    (dm-verity), with our layer overlaid;
  - Valve's `/boot`, kernel, DTBs, boot firmware and `kernelsetup.sh` are
    never used or reachable;
  - Valve's updaters (RAUC, atomupd, `steamos-boot`/`splctl`,
    `setubootenv`, `systemd-repart`) never run;
  - hardware writers are masked. New in the inventory (J-85):
    `steamvr-program-ble` (an openocd nRF52 mass erase) and
    `deckard-charger` (battery NVM writes); already known: `vrconfig_write`
    (writes `/persist`; FS-A-002 §2.1, FS-R-002 (revised) §4.C).
    *(FS-R-011 §7 D1/D3: hiding `/boot` and masking named units are
    controls, not writer containment on their own. Activation is reviewed
    through dependencies, sockets, timers, generators and direct helper
    calls as well as enabled units; a package/executable diff is an alarm
    and review aid, not proof that no writer exists. A directly invoked
    proprietary writer needs an effective technical prevention path. The
    BLE programmer, the charger/NVM writer and `systemd-repart` join the
    writer inventory and activation review before Valve userspace is
    proposed for execution.)*
- **The safety boundary lives in parts we own:** a kernel block-write
  guard, no Frame partition names, command-line masks, refusing stubs, and
  an allowlist so that a Valve build we have not reviewed never boots.
  *(FS-R-011 §7 D2: the guard's timing is deferred, see the rulings below;
  it is not yet a complete boundary.)*
- **Updates (PM agreed, J-87): over the air, on the headset.**
  - SteamOS: the FrameShift updater follows Valve's **stable** channel. It
    downloads Valve's signed update from Valve, verifies it against
    `stable_keyring.pem`, and installs only the rootfs into our inactive
    A/B slot, with automatic fallback. Valve's installer and boot-firmware
    steps never run. *(FS-R-011 §7 D7: a pinned, reviewed build during
    initial bring-up; updates only after bring-up, with paired
    FrameShift/Valve versions and a separately reviewed updater.)*
  - FrameShift layer (kernel, drivers, supervisor): OTA from our project.
  - No manual reflashing after the first install.
- **Installer (PM, J-86/J-87): WebUSB first.**
  - A browser page (Chromium; fastboot and adb over WebUSB) identifies the
    model and firmware, and refuses unsupported states.
  - It copies the device's own Meta hardware firmware (never
    redistributed), verifies the user-provided Valve image, and installs.
  - Later updates happen on the headset.
  - Hosting: e.g. GitHub Pages.
  - Caveats: Valve's server may block in-browser download (the user then
    selects the file); a one-time Windows USB driver may be needed; no
    Firefox/Safari.
- **Chair rulings (FS-R-011 §7, 2026-10-11, J-104; binding).** The Chair
  questions put in FS-A-011 (R3 restatement, kernel guard, shadowing and
  allowlist, storage route, flashing-package ban) are answered as follows. They are
  prospective and authorise no device action.
  - **D1 Runtime adaptation: ACCEPT the technical architecture.** A
    verified Valve rootfs adapted by a reviewed FrameShift runtime layer
    can satisfy FS-R-001 R3's port-controlled transformation and review;
    physically rewriting Valve's rootfs bytes is not required. The accepted
    object is the **complete reviewed composition**: Valve input identity,
    trusted verity root, FrameShift layer, kernel/DT/initramfs, activation
    policy and permitted storage. This accepts an architecture, **not** a
    ready-to-boot Valve-rootfs package and **not** a legal conclusion about
    runtime modification.
  - **D2 Kernel guard timing: RETAIN the revised deferral.** The guard is
    not mandatory before any Valve file executes or before every narrowly
    controlled Valve-rootfs PoC, but known helper paths must be addressed
    before the proposed Valve-userspace launch, and an **effective write
    boundary must be demonstrated before broad, unreviewed stock-service
    activation or any automatic update/installer operation**. Keep custom
    security work off the critical path to a controlled PoC. The proposed
    guard is not yet a complete boundary: write-open denial does not cover
    all mounted-filesystem writes; device-mapper reconfiguration and
    already-open descriptors need treatment; SG_IO/UFS BSG and other
    pass-through routes remain open; GPIO, I2C and battery-NVM writers are
    outside a block-only guard; the one-way latch does not settle
    module/kexec bypass; writable dm allowlists need identity and
    backing-range constraints. (A verity target is read-only and needs no
    write exception.) **Investigate SELinux, capabilities and device policy
    alongside the source patch:** our initramfs can establish labels and
    policy before handoff; whether that contains the privileged writers
    still needs demonstration.
  - **D3 Shadowing and allowlist: ACCEPT as conservative project policy.**
    Permission follows actual per-file/package licences, not authorship or a
    metadata label. FOSS stubs/whiteouts, proprietary unit masking and no
    default process injection are the defaults; documented additive
    driver/API integration is preferred where practical (no compatibility or
    blanket licensing permission follows). Writer-inventory additions as
    above.
  - **D4 Storage: separate routes.** *Dedicated Unit 2:* scoping a
    separately reviewed installer on storage assigned to FrameShift,
    preserving the boot chain and unit-unique partitions and using Unit 2's
    own firmware inputs, is accepted; this is not concurrence to write a
    partition table, flash a boot slot or run an installer. *Unflashed
    units:* the proposed storage route was **not concurred**; offline
    investigation only. Alternatives to investigate (not executed by the ruling):
    **external USB storage** for the first full-rootfs PoC (with an
    explicit console/USB-role/charging arrangement), or separately owned
    storage on Unit 2. Persistent inactive-slot boot is a separate package.
  - **D5 Flashing-package inputs: ACCEPT exclusion** (above).
  - **D6 "Valve binaries":** FOSS rights follow each component's licence,
    not whether Valve or Collabora built it; there is no blanket basis for
    calling all repository-built FOSS packages non-redistributable. Mixed-
    image restrictions do not erase separate FOSS grants, and public
    package hosting grants nothing for proprietary components. A FOSS-only
    base may be researched offline as a control/development base; it does
    not deliver the genuine Frame SteamOS experience. This does **not**
    amend the PM's "no Valve binaries" policy (§6A item 9): PM decision
    open, below.
  - **D7 Stable builds: ACCEPT the direction** (pinned build during
    bring-up; updates later, paired versions, separately reviewed updater).
    Distinguish **signature authentication**, **manifest branch**,
    **official recovery provenance** and **public release designation**.
    Excluding package-repository assembly and hotfix repositories as
    installer inputs is a reasonable scope choice; it does not establish
    that every package in them is a preview package.
  - **Licensing correction (D1/D3/D6):** Valve's Frame-specific download
    page currently presents the backup-image EULA; its personal-use grant
    and redistribution restrictions do not settle the runtime-overlay
    question, and it states no Frame-only hardware restriction
    (`docs/research/valve-packages-licensing.md`).
- **Hardware compatibility approach (PM, 2026-10-12, J-120; FS-R-011 D3 "documented additive
  driver/API integration"):** once a Valve userspace boots (Stage 2), Valve's Frame-specific
  hardware use is mapped onto the Quest in three tiers, never by modifying Valve's binaries:
  1. **same standard interface:** Quest drivers expose the standard Linux interfaces Valve's
     software already uses (backlight, power_supply, thermal/hwmon, input, DRM/GPU), so no
     translation is needed;
  2. **thin adapters:** where Valve hard-codes Frame specifics (GPIO/SPI/I2C numbers, device
     names, sysfs paths), small shims (udev rules, symlinks, services) point them at Quest
     equivalents;
  3. **plugins via documented APIs:** tracking, controllers (Touch via SyncBoss) and the headset
     display through the SteamVR/OpenXR driver interfaces.
  - Dangerous Frame-specific actions (firmware updaters, disk formatting) are **blocked, not
    translated** (J-119 Quest-specific protections).
  - Valve's behaviour is learned only from public interfaces and from observing it run in our own
    environment (calls made, files opened); no disassembly of Valve binaries (J-90 rule).
  - Start of the mapping table: `docs/research/valve-writer-inventory.md` (the Frame-specific
    devices and paths Valve touches).
- **Decided PM policy (2026-10-12, J-118):** D6: licence-audited FOSS packages are allowed (with
  their notice/source obligations for anything we ship); proprietary components are not
  redistributed. D7 (J-121): default Valve **stable**; the user may choose any channel Valve's Frame UI offers; verification mirrors Valve's own updater; a FrameShift notice on non-stable builds not yet checked against our layer. **Design principle (PM):** keep the experience as close to SteamOS out of the box as possible; depart only where Quest hardware forces it.
- **Open PM policy decisions [O] (FS-R-011 §7 D6/D7, as asked of the PM; see the line above):**
  - **D6:** do licence-audited FOSS packages fall within an exception to
    the "no Valve binaries" release policy?
  - **D7:** an explicit exception for the exact official recovery image
    (manifest branch main/OOBE) as the first-install base, separately
    pinned and reviewed; and supply the official 2026-10-08 stable
    announcement article (still [C] to the Chair) with its matching signed
    manifest when resolving the release-policy mapping.

### 0.1 What this project does NOT include

**Getting code onto a device is a solved precondition, not a topic.** Every
target is assumed to be an already-unlocked headset; how it got there is
outside this project and must not be re-litigated here. If a question of that
kind arises, it is answered elsewhere and imported as a fact.

An earlier, shelved device programme is not published. The claim once made
for it, that recovery is guaranteed for any bad image, was rejected by the
chair on 2026-10-07 and is withdrawn.

---

## 1. Target hardware

| device | SoC | GPU | basis |
|---|---|---|---|
| Quest 3 / 3S | XR2 Gen 2, Qualcomm platform **`anorak`** | Adreno 740-class (chip ID 0x43050b00) | **[M]** `qcom,anorak` on the running unit; **[M-static]** clock/UFS layout closer to SM8450 than SM8550, no mainline support (research pass, 2026-10-07) |
| Quest 2 | XR2 Gen 1 | Adreno 650 | **[C]** SM8250-derived |
| Quest 1 | MSM8998, Snapdragon 835 | Adreno 540 | **[D]** from the PM's existing Quest 1 material |
| Quest Pro | XR2+ Gen 1 (`kona` family) | Adreno 650-class | **[M-static]** v2.7 OTA; built from the **Quest 2 kernel tree**. Offline scoping, no PM unit (2026-10-08) |
| Quest 3S | XR2 Gen 2 (`panther`) | Adreno 740-class | **[M-static]** v2.7 OTA; built from the **Quest 3 kernel tree**. Offline scoping, no PM unit (2026-10-08) |
| Vive XR Elite | SM8250, XR2 (Gen 1) — corrected from "XR2+ Gen 1" (`docs/research/perf-envelope-xr-elite.md`) | Adreno 650 | **[M]** from its own `dtbo`; CPU/GPU frequency tables identical to the Quest 2's [M-static] |

Reference point, not a target: **[M-static]** Steam Frame is SM8650.

**Quest Pro is dropped** — the PM does not hold one. Earlier documents list it;
they are superseded on this point. *(Status note, 2026-10-10: this was itself
superseded on 2026-10-08. The Quest Pro was re-added as an offline/build target
(J-33), and it is third in the order adopted by FS-R-006 §1. See the table above
and §7.)*

### 1.1 What the family picture actually is

Four targets, four SoC generations. The earlier claim that three of five
targets shared the SM8250 family does not survive the revised list.

- **XR Elite and Quest 2: same SoC tables, different everything else
  (updated 2026-10-08).** Both are XR2 (Gen 1), SM8250-class, with Adreno
  650.
  - Their CPU and GPU frequency tables are **identical**
    (1.8048/2.4192/2.8416 GHz; GPU bin 0, 587 MHz) [M-static: the Quest 2
    v2.7 and XR Elite v2.0 firmware].
  - Their **fan, battery and thermal control differ completely**
    (`docs/research/perf-envelope-xr-elite.md`).
  - We now hold the Quest 2 v2.7 device tree (in its boot image,
    `firmware/quest2/v2.7-user_ota/`).
- **Quest 3 is less close to Steam Frame than first assumed.** Its platform is
  `anorak` [M]. A research pass found its main clock controller and UFS layout
  match **SM8450** far better than SM8550, and found **no mainline support** for
  `anorak` at all [M-static, not yet re-checked by the Arbiter]. Community
  SM8550/SM8650 ports are useful for userspace and process, not for its kernel.
  The stock Meta kernel (published per build) is the practical base for now.
- **Quest 1 has a different SoC** (MSM8998, 2017), so kernel and device-tree work
  won't carry over from the others. Userspace integration, build tooling,
  diagnostics and the update pipeline should, and `nicolas-riera/Quest1-SteamOS`
  is direct prior art for it.

**[O] Do not plan around any of the family claims until device trees are
compared.** `CHAIR_DIRECTIVE.md` §5.1 item 11 holds.

### 1.2 Order of work

*(Status note, 2026-10-10: the current order is Quest 3 → Quest 2 → Quest Pro
→ Quest 3S → Quest 1 → XR Elite, adopted by FS-R-006 §1. See §7. The text
below is the original 2026-10-07 reasoning.)*

**Quest 3 first**, per the continuity directive. Then Quest 2, then Quest 1.
The XR Elite is a later workstream and should not redirect the Quest bring-up.
The reasoning is in `ERRATA-002.md` §2. The short form: **[C]** temporary
boot (`fastboot boot`) is expected to let a kernel be tested on the Quest 3
without a persistent partition write; that is still to be demonstrated on
this device and image arrangement.

Per-device material lives in `devices/<device>/`:

```
devices/quest3/   devices/quest2/   devices/quest1/   devices/xre/
```

Keep common userspace and build infrastructure separable from per-device boot,
kernel, DT, drivers and recovery procedures.

---

## 2. The first work, in order

### 2.1 Inspect the Steam Frame image — **done, reported in FS-A-001 (private review record)**

Partition layout, boot path, U-Boot, and the embedded `sm8650-deckard` device
tree are read and reported, and so is the rootfs (`FS-A-001`/`FS-A-002`). The
rootfs was extracted through a read-only kernel mount after `btrfs restore`
proved unreliable; the scope of that verification is in FS-R-002 (revised).

Two results from it that change later stages:

- **[C] Hypothesis: SteamOS is built around a mainline-style `drm/msm` kernel.**
  Valve's own kernel uses upstream DSI bindings [M-static]. Whether SteamOS
  userspace *requires* that, or can run on a downstream display/GPU stack, is
  open (FS-R-002 rev. §7).
- **[D] The rootfs locates its partitions by partition GUID**, through
  `/SteamOS/PARTSETS/` on its `efi` partition — not by label or path.

### 2.2 Establish a read-only Quest 3 baseline

Per the continuity directive's first engineering decision, and **before** any
write. Record, for the specific unit:

- Firmware and build identifiers; exact model.
- A/B layout and active slot.
- `boot` / `vendor_boot` / `init_boot` / `dtbo` / `vbmeta` structure as
  applicable.
- Stock image hashes, preserved.
- Recovery entry, confirmed by observation.
- Available boot logs, and whether a `ramoops`/pstore region is configured.

**[O] Do not assume another headset's layout applies.** Firmware changes can
invalidate prior reads.

### 2.3 Solve the console problem

**This gates everything after it.** There is no obvious serial port on a
headset, and a kernel that fails silently is indistinguishable from a kernel
that was never flashed.

**[M-static] The Steam Frame image does not solve this for us.** Its device tree
carries `stdout-path = "serial0:115200n8"` — Valve had a UART and used it.

Candidates, per device: USB gadget serial brought up early; an early
framebuffer; deliberate, timed reboots into the bootloader; the headset LEDs.
**`ramoops`/pstore is configured on the Quest 3 but was not retained across any
reboot tested** [M] (`JOURNAL.md` J-14). Temporary boot avoids deliberate
partition writes; it still runs firmware and kernel code, so the absence of
other persistent effects is not established (FS-R-003 §6).

**Do not proceed past first boot without a console.** Every later stage is
debugging, and debugging without output is guessing.

### 2.4 Verify the community ports before borrowing from them

**[O]** Inspect, do not assume: `project-barry/pb-os`,
`hashtagbasit/SteamOS-ARM-Port`, `MaSieS4Fun/SteamOS-ARM-SM8550`. Check current
contents rather than prior summaries, and check architecture, licensing, ABI,
boot flow and hardware dependencies before reusing anything.

Specifically **do not** assume that U-Boot can
simply replace an Android `boot` image, or that an existing SM8550/SM8650 port
supplies a suitable Quest 3 kernel or DT.

---

## 3. Staging

**Milestones (revised 2026-10-14, J-149–J-170; Quest 3 first).** Planning is by milestones and
checkpoints, never by time (PM, J-168). Each pass condition is observable. Status: ✅ passed,
▶ next, ○ planned. The earlier stage numbers are kept in brackets for reference.

| # | milestone | pass condition | status |
|---|---|---|---|
| M1 [stage 1] | first shell | an interactive shell from a kernel and initramfs we control, with a fresh nonce (the stock kernel may be reused) | ✅ 2026-10-08 (FS-A-005) |
| M2 [stage 3, display] | correct image on the panels | all 8 characters read in each eye, the eye swap and 21° roll corrected, on v2.7. **PM requirement: 90 Hz by default, 120 Hz where supported** (checklist E4; Quest 1 note, J-40) | ✅ stage 3c Unit 1 v66 (J-125); stage 3d **both units** v2.7 (J-144, J-146) |
| K1a | our own kernel boots | a FrameShift-built kernel (expected CRC-neutral options; stock vendor modules; no USER_NS/PID_NS) boots by temporary `fastboot boot` on Unit 2 and reaches our PID 1 | ▶ (FS-A-013) |
| K1g | boot-chain write guard proven | fs-blkguard refuses every boot-chain write in its probe set, repeated on every new kernel (PD-10) | ○ |
| TS | full thermal and battery service | fs-thermald stages T0–T5 pass on the device (sensors incl. PMIC channels identified, fan, battery via ADSP, throttle, the shutdown path) with user-visible fault feedback; T6 soak only after the full v2.7 checklist (PD-7, J-158, J-171) | ○ (part 1 built offline) |
| K1i | kernel for Steam | SysV IPC plus the rebuilt vendor module set boots and passes K1g again (PD-6) | ○ |
| **R-1** [stage 2] | **SteamOS boots** | Valve's unmodified 0.4.5 rootfs, loaded into RAM over USB (dm-verity), reaches a controlled systemd console target on the Quest 3, with Valve's risky units masked and the guard and module latch armed; no GPU yet. **First big showable milestone** (J-171) | ○ |
| G1 | GPU test tool | upstream Turnip on KGSL renders a known offscreen image: (i) GPU locked at its lowest level; (ii) throttle check up to Meta's NORMAL cap with fs-thermald live (J-161). Internal tool only, never shipped | ○ |
| G1c / S0 [stage 4] | Frame-compatible GPU device | our bridge module presents the `msm` device; Valve's own Turnip renders offscreen, unchanged (route e′, PD-1, J-156) | ○ |
| G2 | GPU to the panels | Valve's stack drives the panels through our bridge (plane fan-out, syncobj eventfd, M1); route (a)/(b) re-check here | ○ |
| G3 / G3s | compositor | gamescope and vrcompositor run; G3s: VM_BIND/sparse for vkd3d FL 12_0 | ○ |
| **V0** [stage 5a] | **desktop in headset** | the SteamOS desktop / Steam UI visible in the headset at a fixed pose (needs vrcompositor plus our HMD driver; storage per PD-13) | ○ |
| V1 | 3DoF virtual environment | head rotation tracking (SyncBoss IMU) in SteamVR's environment | ○ |
| V2 [stage 5b] | 6DoF head | our own Basalt fork plus an open map layer; PASS = match Horizon measured on the same unit (D-T11, J-170); validated without external hardware | ○ |
| V3 | bundled controllers | Touch Plus on Quest 3 (inputs, then 6DoF; Quest 2 port: ring Touch right after head tracking) (J-165) | ○ |
| V4 | hands | our own hand-tracking model, trained from scratch on clean data, working across all Quest cameras (J-162) | ○ |
| V5 | cross-compatibility | ring Touch on Quest 3 (our own pairing), later Frame and other controllers (Frame controllers need Valve's cooperation) | ○ |
| P1 | product | dedicated install (PD-9), user-initiated SteamOS updates verified against Valve's signature (J-166), FrameShift splash (J-169), a game launched from Steam | ○ |

Tracking and controllers (V-rows): Meta's proprietary tracking, models and binaries are not used
(J-162). Details: `docs/research/tracking-input-route.md`, `stage3-4-plan.md`,
`gpu-route-decision.md`, `steamos-ports-survey.md`.

Each pass condition is chosen to be **distinguishable from the stage never
having run**. That is not pedantry — it is the single most common way this
project's predecessor wasted time.

Stage 1's real target, per the continuity directive, is a minimal observable
ARM Linux boot reaching an interactive shell or a similarly decisive marker.
Headless userspace (Stage 2) comes before panel and GPU work: proving that
userspace boots does not need either (FS-R-002 rev. §7).

### 3.1 Favourable and unfavourable

**Favourable:** SM8250 and SM8550 have real mainline support, which matters
for the Quest 2 and XR Elite. Adreno 650 is supported by mainline Freedreno.
**The Quest 3's `anorak` platform has no mainline support** and its GPU chip ID
is absent from mainline's catalog [M-static, research pass], so for the Quest 3
the GPU stage depends on the downstream kernel or on new mainline work. The rootfs is Valve's and already assumes a headset's display
topology — **[M-static]** two independent DSI controllers, one panel each, with
per-eye regulator control.

**Unfavourable:** the display panels are the hard part and always are. Dual
MIPI DSI with unknown timings, almost certainly needing a driver written or
adapted. **[M-static] The Steam Frame image gives us no timings** — its panel driver
is out-of-tree and private, and its device tree carries no timing properties at
all. It shows the shape of a headset panel binding, not data. **[C]** On a port
of this kind this is normally the single largest piece of work.

---

## 4. A cheap parallel track

**Android plus a container plus box64.** Every target can run an ARM64 Linux
userspace in a chroot or proot with box64 and the x86 Steam client, without
replacing anything.

This is worth running alongside, not instead:

- It risks nothing — no kernel, no partition writes.
- It answers "is this SoC fast enough under x86 translation, and are these
  panels usable for flat games" on working hardware with working drivers,
  **before** Stages 1–3 are built.
- **[C]** For many owners it may be the better product outright.

**[D]** It is strictly information-positive about the risky track, and cheap.

---

## 5. Vendor blobs and HALs

The PM can extract blobs and HALs from the firmware. **[O]** What is needed is not
yet enumerated and depends on findings from §2.1 and §2.2 — at minimum the
Adreno firmware for Stage 3, and whatever the sensor stack turns out to need.

`CHAIR_DIRECTIVE.md` §5.1 item 12 stands: "we have it on the device" and "users
can have it" are different questions. Record the licence position for anything
we intend to ship, separately from anything we merely test with.

---

## 6. Working conventions, carried over

These earned their place on the previous project and are not optional:

- **Tag every claim** — **[M]**, **[M-static]**, **[D]**, **[C]**, **[O]**. The failure mode is
  inference presented as measurement.
- **Give every test a pass condition that cannot be confused with the test not
  running**, and state what would falsify it before building it. Give verdicts
  an INCONCLUSIVE branch.
- **Prefer device data to more planning.** When a probe would settle a key
  unknown, propose the probe.
- **Verify from source** — the device, the pulled files, the image. Never by
  judging which claim sounds more plausible.
- **Searches are not exhaustive until proved so.** Resolve indirect branches
  and fallthrough edges before saying "only" or "exactly one".
- **"Therefore impossible" is the highest-risk sentence available.** Two
  branches reading the same mutable variable at different times are not
  mutually exclusive.
- **Scope claims to what was shown.** The recurring miss is an overreaching
  adjective, not bad analysis.
- **Relays are written only when something needs to go before the chair** — a
  discovery, a question, a spot check, or a blocker. Not for routine
  back-and-forth. Relay numbers are never skipped; unsent information is rolled
  into the open relay.

## 6A. Device safety requirements (PM, 2026-10-08)

The PM's standing instruction: **log all research and discoveries, and put
safety first.** These requirements bind every image we boot on a headset.
Research basis:
- `docs/research/FS-A-006-power-thermal.md`
- `docs/research/perf-envelope-quest3.md`
- `docs/research/perf-envelope-quest1-2.md`

*Numbering (2026-10-11): items 8a and 8b were added after item 9 and keep
their numbers because relays and rulings cite them; item 9 was moved after
them so the list reads 1–8, 8a, 8b, 9. No item was renumbered.*

1. **Our images replace Android's thermal and battery protection.**
   - Skin and battery **shutdown** thresholds are enforced by Android
     userspace (`perf_service` / the thermal HAL). The kernel DT also has
     some mitigation (Quest 3: `batt-virt-limit` CPU maps at 45/58 °C,
     `surf-virt-limit` at 48 °C). Corrected per FS-R-006 §4.
   - The Quest 3 GPU has a kernel devfreq cooling device and a thermal
     max-frequency path; whether an autonomous temperature-to-GPU policy
     is present and effective is [O] (FS-R-006 §4).
   - These kernel mechanisms do not prove adequate protection in our
     environment: we provide and verify the controls our system needs.
   - Any image that runs for more than a short, bounded, attended hold
     must carry its own protection (for FS-A-007's images, which hold at
     most 260 s and 170 s (backstops at 261 s and 171 s; intended reboot
     times, not guarantees) with the PM present, no load beyond idle and a
     static pattern whose client hold is 10 s (alarm at 15 s), the
     bounded-hold rule 2 applies instead; the displayed frame may persist
     until recovery if v66's release path leaves it on [O] (FS-R-007 §4); no
     software watchdog is used, J-49; for the stage-3b image of trial (iii-b),
     prepared under FS-R-010: a hold of at most 200 s (backstop 201 s; intended
     times, not guarantees), two static bright-pattern runs with client holds
     of 3 s and 10 s (alarms at 8 s and 15 s) at least 2 s apart, the one
     runtime write `panel0-backlight` brightness = 127, the PM present and the
     temperature procedure of `devices/quest3/SIGNOFF.md` trial (iii-b); the
     bounded-hold rule 2 applies, and the frame may persist until recovery
     [O]; **concurred to execute by FS-R-011 §1** for exactly that image,
     once, attended):
     - the thermal-zone drivers;
     - the fan driven;
     - a temperature watchdog that throttles and then shuts down.
   - Shutdown limits (Meta's own): SoC 115 °C; battery 65 °C (Quest 3),
     59 °C (Quest 2), 56 °C (Quest 1); skin 60 °C.
   - **Kernel forced-shutdown path (FS-R-011 §6, J-104).** With the empty
     static usermode-helper path, "the successful-no-op helper path
     supplies no dependable forced shutdown through the generic thermal
     core on this configuration" (Quest 2 v2.7,
     `THERMAL_EMERGENCY_POWEROFF_DELAY_MS=0`; exact tree `6bde5fc0` checked
     by the Chair) [M-static config; D]. Allocation failure or a disabled
     helper can still reach `__orderly_poweroff`'s forced fallback, so
     never write that it "never fires". On the Quest 3 v66 (delay 100 ms) a
     handled critical trip schedules an emergency power-off **attempt**; it
     does not establish a physical power-off 100 ms later. Vendor notify
     paths and hardware over-temperature protection are unassessed [O], and
     our current stage images load no thermal-zone drivers, so none of this
     is thermal protection in them. **A forced, unsynchronised kernel
     power-off is a last resort, not graceful shutdown.** FrameShift's
     thermal ownership and the PM's graceful-shutdown requirement (J-83)
     have raised priority: they must be designed in before the Quest 2
     trial and before sustained Valve-userspace operation. (Not an added
     gate on the bounded, attended trial (iii-b).)
2. **Holds without that stack are short and bounded.**
   - An unconditional timer, and a userspace dead-man that ACK does not
     cancel (FS-A-006 §5).
   - A kernel hang falls back to the PM's manual recovery.
3. **The fan must run whenever the CPU or GPU is loaded.**
   - **Loading `qcom-spmi-temp-alarm` can disable the PMIC's hardware
     stage-2 over-temperature shutdown.** No image loads it without an
     explicit design that keeps stage-2 enabled or replaces it (J-34).
     Whether the override is selected depends on temperature, ADC
     availability, PMIC subtype and revision; loading alone does not
     establish the protection state (FS-R-006 §4).
   - **XR Elite (when un-shelved): the fan is userspace-only** (a MAX31760
     driven by HTC's closed thermal-engine), and its main battery's
     temperature arrives over the cradle UART, outside the kernel. No
     full-range clocks until our own fan loop and cradle-battery monitoring
     exist. Interim fan rule: ≥ 20% duty at all times, 100% at ≥ 50 °C.
   - On the Quest 3, Linux did not drive the fan in the stage-1 boot.
   - Display state is not a cooling control (FS-R-006 §4). The Quest 3 v2.7
     fan driver caps the fan at `silent_rpm` (4000 RPM) during blank; the
     Quest 1 fork reports the fan stopping on POWERDOWN blank [C]. Every
     image that runs beyond a short, bounded, attended hold has an explicit
     fan policy with tach/failure handling, independent of the panel. For
     FS-A-007's two images (intended holds ≤ 261 s / 171 s, attended, idle
     load plus a static pattern with a 10 s client hold that may persist
     until recovery [O]) the protection is the time bound and the
     PM's attendance, plus the hardware's own LMh and PMIC protection [C];
     `pwm-tach-fan.ko` is loaded but not commanded by us, so the fan runs
     at whatever state the bootloader and the driver's probe leave it [O].
     On Unit 1's v66 firmware the fan driver **stops the fan on panel
     blank** [M-static, v66-era source, Meta commit 23c97b25 (checked by the Chair, FS-R-008 §4); applying it to Unit 1's .511 module is [C], a near-match hypothesis]; so in the
     display trial the fan may stop after the close, if the close blanks
     the panel [O] (FS-A-008 §3).
   - **Fan policy for our images (PM decision, 2026-10-09; J-56).** Cooling
     follows **temperature, not screen state**:
     1. **Screen on:** temperature-driven, using that device's own Meta
        fan zones, trips and levels.
     2. **Screen off (awake):** still temperature-driven; the fan may be
        capped at that device's quiet speed (Quest 3 v2.7: `silent_rpm`
        4000) for noise, **but the cap yields** when temperatures cross a
        threshold; the CPU/GPU may also be throttled while the screen is
        off.
     3. **Suspended:** fan off (the driver suspends with the system); **no
        suspend while hot** — cool first or postpone.
     4. **Always:** tach-failure detection (fan commanded but not spinning,
        or rpm implausible) → throttle, then orderly shutdown; missing or
        stale sensors fail safe.
     - **Per device, never assumed:** each port copies **its own** device's
       Meta policy (zones, trips, levels, quiet speed, blank and suspend
       behaviour, fan hardware) from that device's own firmware and DT.
       **The Quest 3S is not the Quest 3, and the Quest Pro is not the
       Quest 2**: different components (Quest 3S DT `oculus,silent-rpm`
       = 5000 vs Quest 3 4000 already differs). Where a device's stock
       driver stops the fan on blank (v66 Quest 3, Quest 2, Quest Pro;
       Quest 1 fork [C]), our port replaces that with rule 2.
     - **Valve's Steam Frame fan control is not used** on any Quest: it is
       built for the Frame's hardware, and FS-R-001 keeps Valve platform
       code off the Quest. Our per-device layer (Meta's kernel driver plus
       our temperature daemon, `docs/research/thermal-control-design.md`)
       provides the policy.
     - **Departures from Meta's policy (PM ruling 2026-10-09,
       `docs/research/thermal-control-design.md` §0.1):** accepted for
       development images: fan floor 3700 rpm awake (P1); no screen-off
       quiet cap in v1 (P2); graded CPU/GPU caps (P3) and fan floors (P4)
       per severity; usb-conn ≥ 70 °C → shutdown (P5); battery ≤ 3 % and
       discharging → shutdown (P6); PMIC die 95 °C SEVERE / 115 °C shutdown
       (P7); fan fault and sensor fault → SEVERE, shutdown after 120 s
       (P8, P9); no suspend for now (P10). Normal caps start at Meta's L4,
       CPU 1.92 GHz / GPU 545 MHz (P11 rejected). **All to be revisited
       before the first public release.**
4. **Never leave CPUs at the kernel's default `performance` governor
   unattended.**
   - The stock Quest 1 and Quest 2 kernels default to it, which pins every
     cluster at maximum.
   - Set schedutil/walt (CPU) and msm-adreno-tz (GPU), with our own caps.
5. **Performance envelope:** the full hardware-supported range is allowed,
   but sustained targets stay at Meta's ceilings until a thermal soak test.
   - Quest 3: CPU ≤ 2.05 GHz, GPU ≤ 599–640 MHz.
   - Quest 2: Meta's L4.
   - The Quest 3's 690 MHz GPU step is withheld until soak-tested.
   - **No beyond-spec overclocking:** no firmware or LUT changes.
6. **Battery.**
   - The battery temperature is the binding thermal constraint.
   - No sustained maximum clocks while charging.
   - Quest 1 and Quest 2 cells are 5–7 years old; inspect for swelling before
     long sessions.
7. **Every device action stays read-only by default.**
   - `fastboot boot` needs the PM's live sign-off, with the PM present.
   - Unit 1 is never flashed.
   - Flashing happens only on Unit 2, after its baseline, and with the PM's
     explicit authorisation.
   - **Unit 2 re-baseline (FS-R-011 §8, J-104).** Before **any** FrameShift
     action on Unit 2, establish its fingerprint, slot, kernel and effective
     firmware inputs, and capture the inputs the new baseline needs. Never
     reuse v71 identities as v2.7 identities. Unit 1's v66 concurrence does
     not migrate to Unit 2 or another firmware.
   - Never write boot-chain partitions without a ruling (FS-R-001).
8. **Every device port completes `docs/DEVICE_PORT_CHECKLIST.md`** (PM,
   2026-10-08): thermal, fan, battery, performance, display, boot,
   remoteproc and other hazards. Copy the original device's own controls;
   never invent a curve or a limit. This applies before any of our images
   runs beyond a short, bounded hold.
8a. **Every finding is logged.**
   - Research goes to `docs/research/`, and decisions and discoveries to
     `docs/JOURNAL.md`.
   - Device output is kept as raw files with exact commands
     (the private review records).
   - All of it is committed.
8b. **Partition, MCU and package hazards** (from community work,
   `docs/research/community-quest-repos-2.md`, 2026-10-10; claims [C]
   unless noted):
   - Never mount `persist`, `private` or `metadata` read-write; on a
     Quest 2, mounting persist reportedly reset the headset.
   - Never write `/metadata`: it holds the stock encryption keys.
   - Never send unknown SyncBoss commands. Commands 90, 203 and 204
     reportedly crash the MCU. Never run Meta's controller or SyncBoss
     firmware updaters.
   - Never disable package signature checks (one fork's `pacman.conf`
     does).
   - Never use the bootloader menu's "Switch Boot Slot" (PM: can brick).
   - Useful read-only post-trial probe: the PMIC power-off/reset reason,
     which separates a thermal shutdown from a watchdog reset.
   - **Writers in the Valve image (FS-R-011 §7 D3, J-104):**
     `steamvr-program-ble` (openocd nRF52 mass erase over GPIO),
     `deckard-charger` (battery-pack NVM writes), `systemd-repart` (could add
     a partition) and `vrconfig_write` (`/persist`) are in the writer
     inventory and activation review before Valve userspace is proposed
     for execution. A unit mask does not stop a direct invocation; each
     needs an effective technical prevention path.
9. **Third-party testers (PM, 2026-10-08).** Anyone outside the project
   who tests our images — e.g. on Quest Pro or Quest 3S units — is first
   briefed in writing on the conditions and risks, and gives informed
   consent. They get **reviewed `fastboot boot`-only images**: nothing
   written to the device. They also get a written recovery procedure and
   the before/after checks. **No Valve binaries** go into images handed to
   third parties until the licensing position allows it. The device
   checklist must be completed for their model first. *(FS-R-011 §7 D6,
   J-104: FOSS rights follow each component's licence; whether
   licence-audited FOSS packages fall within an exception to this rule is
   an open PM decision [O], §0.0. Images we hand out already carry
   BusyBox, a kernel and static glibc: their source, licence and notice
   obligations apply.)*

---

## 7. Current state

*As of 2026-10-11 (JOURNAL through J-108; latest ruling FS-R-011). The
"where we are" row is current (trial (iii-b) run, J-107); the PM directions,
units and relays rows were last brought up to date at J-104 (FS-R-011), and
the other rows at J-84 (2026-10-10). The root `README.md` status line is the
single current-status source: where this table differs, the README wins. The
summary, open items and resume steps are there.*

| item | status |
|---|---|
| **where we are (2026-10-11)** | **Stage 1 ACHIEVED** (FS-R-005). **Trial (i)** (stage 2a, 2026-10-09): registered COMPATIBILITY FAIL at step 4 (a listing-rule defect), admissible with the deviation recorded (FS-R-009). **Trial (iii)** (stage 3a display, 2026-10-10): registered INCONCLUSIVE (FSB1 serial loss); no light seen (FS-R-010); FS-R-011 §3 keeps it INCONCLUSIVE. **Trial (iii-b)** (stage 3b, image `ea60d6cd…5841`, nonce `6cf0f15867f14edc`): **CONCUR EXECUTE (FS-R-011 §1, J-104)** — Unit 1, v66 (Unit 1) slot A, one temporary boot, no flash, no retry, the PM present, with clarifications A/B recorded in `devices/quest3/SIGNOFF.md`. **Run 2026-10-11 (J-107):** stage-1 class PASS, FSB1 VALID, machine side PASS; optical [PM report] run 1 dark, run 2 lit but garbled (first panel light; not a stage PASS); raw evidence FS-A-012 (private review record), report in FS-A-012 (not yet written). **Cause of the garble found (J-108/J-109):** our 2 × 2064 planes exceed per-pipe throughput at the 550 MHz MDP max; the stage-3c rerun (`devices/quest3/stage3c/DESIGN.md`) uses 4 × 1032 planes with explicit zpos, an interactive per-phase flow and an optional run 3, under the PM's executive decision (J-107). Quest 2 channel, distribution and storage work continue offline only (FS-R-011 §4, §7, §9). |
| **PM directions (2026-10-10, J-83)** | distribution **option 1** (our code plus an installer; PM idea: build around an unmodified Valve image; *the architecture is accepted by FS-R-011 §7 D1, as an architecture only; D6/D7 PM decisions open, §0.0*); **graceful emergency shutdown** required (design pending); an additional OTA package source allowed (hashes recorded); continuity via the root `README.md`. J-83 points to an Arbiter assessment "in PROJECT_SETUP §0.1"; §0.1 holds no such assessment. The assessment is §0.0 (Distribution model) and `docs/research/valve-image-slot-in.md` (J-85) |
| **release policy** | **decided (PM, 2026-10-07): FrameShift releases only from Valve's `stable` channel** (newest: **SteamOS 0.4 for Steam Frame, stable, reported released 2026-10-08** [C]: FS-R-011 §7 D7 keeps it [C] until the exact official article and the matching signed manifest are supplied; previously 0.3.0). Offline tests keep using the pinned rootfs `20260922.6152327` (rc) until a 0.4 stable image is obtained and diffed (J-47). A FrameShift `beta` channel tracking Valve `beta` may be added as opt-in once the team grows — `FS-A-003` §5a |
| Steam Frame image inspected | done. The rootfs was re-extracted through a read-only kernel mount: 162 genuine zero-length files, one unreadable directory. The Chair verified the 52-file evidence bundle against its manifest — `FS-A-002` §1, FS-R-002 (revised) §1 |
| Steam Frame extracts | `firmware/SteamOS/extracted/` (kernel config, `kernelsetup.sh`, DTB, U-Boot) |
| **safety: Valve's update machinery** | **isolated by `FS-R-001`**, confirmed from source by FS-R-002 (revised). Never run Valve's hooks or unreviewed services on a Quest. Inventory in `FS-A-002` §2, with additions from FS-R-002 rev. §3–4: the `steamos-efi` delegate, `deckard_fw`, `vrconfig_write` → `/persist`, chroot and overlay effects |
| **build target (PM, 2026-10-08; confirmed 2026-10-09)** | **v2.7**, the latest release, for the **Quest 3, Quest 2, Quest Pro and Quest 3S**. The Quest 1 and XR Elite will have different targets. Quest 3 v2.7: kernel `5.10.246-gd7102a837402`, public source `dbc2bc83a2b673f5d1c24ee9dadb0cd708ffda3f`, clang r450784e (14.0.7). Quest 2 v2.7: kernel `4.19.325-cip128`, the same clang. JOURNAL J-24/J-25 |
| **device ordering (PM, 2026-10-09; supersedes 2026-10-08)** | **1 Quest 3 (primary) · 2 Quest 2 (secondary) · 3 Quest Pro (tertiary) · 4 Quest 3S (quaternary)**, then Quest 1 and XR Elite. Kernel and OS changes for the Quest 3/Quest 2 are applied to the Pro and 3S simultaneously (lockstep, offline/build). **Adopted by the Chair (FS-R-006 §1)**, superseding FS-R-005's order; each device keeps its own configs, artifacts and gates, and shared source does not establish shared hardware behaviour. JOURNAL J-35, J-37, J-39 |
| **added targets (PM, 2026-10-08)** | **Quest Pro** and **Quest 3S**: offline scoping; v2.7 OTAs held (`firmware/questpro/`, `firmware/quest3s/`); same kernel trees as the Quest 2 and Quest 3 respectively; **gates PASSED** (Q3S 2583/2583, QPro 776/776 incl. ACM; superset changes no CRC; J-36). JOURNAL J-33 |
| **units (PM, 2026-10-08)** | All units are unlocked headsets (assumed by the project). **Unit 1** = Quest 3 `QUEST3UNIT1`, v66 slot A: **`fastboot boot` only, never flashed by FrameShift**. **Unit 2** = the PM's second Quest 3: reserved for the first `fastboot flash` work, after its own baseline. **Quest 2** (`QUEST2UNIT`, **retail**; bootloader label `Hollywood (DVT)` is production on this unit): `fastboot boot` only; never flashed by FrameShift. The no-flash policy for Unit 1 and the Quest 2 stands on its own (FS-R-006 §6). **Target firmware for real trials: v2.7 on the unit itself** (PM, 2026-10-09, J-66): a v2.7 boot image on older firmware is a hybrid; never newer than v2.7. Unit 2 has a faulty IPD slider (PM report). **Update 2026-10-10:** **Unit 2** identified as `QUEST3UNIT2`: v71 `50352750111100511`, slot `_b` (J-83). The **Quest 2** is on **v2.7** (`52242990024200150`, slot b; J-74/J-75): its stock firmware was moved to Meta's official v2.7 by the PM (PM executive decision), not by FrameShift. **Update 2026-10-11 (FS-R-011 §8, J-104):** Unit 2's stock firmware was updated by the PM (official firmware); before any FrameShift action on Unit 2, a new baseline (fingerprint, slot, kernel, effective firmware inputs) is required; the v71 identities above are not v2.7 identities (§6A item 7). |
| Quest 3 firmware | Unit 1: **active slot A v66 (known-good, untouched)**; slot B v72. Meta publishes kernel source for v66 (`.510` user, nearest to our `.511`), v72 (exact), v76, v84 and v2.7. Stage 1 used slot A's stock kernel by temporary boot — no OTA, no slot switch (FS-R-003 §1) |
| Quest 3 baseline | static inventory (`FS-A-003` §1) **and live probe done** (`FS-A-004` §1): active slot **A** (v66); no `bootenv` |
| Quest 2 firmware | **v2.7 OTA held** (`firmware/quest2/ota/q2_52242990024200150.zip`; boot, dtbo, vendor and IKCONFIG extracted). Kernel 4.19 CIP; boot header v2 (DTB in boot); **no USB ACM gadget in stock** — `docs/research/quest2-v2.7-first-look.md` |
| XR Elite `dtbo` | held, in the PM's existing XR Elite material |
| XR Elite | workstream shelved |
| console strategy | USB ACM gadget, built into every stock Quest 3 kernel. **ramoops is configured but not retained across any reboot tested** [M]. Independent evidence comes instead from timed reboot-to-bootloader plus LED stage colours (design, `FS-A-004`) |
| relays | `FS-A-001` → `FS-R-001` · `FS-A-002` → `FS-R-002` (revised) · `FS-A-003` → `FS-R-003` · `FS-A-004` rev 1 → `FS-R-004` · rev 2 → `FS-R-004` consolidated (concur; image retired unrun) · rev 3 → `FS-R-004` consolidated rev 3 (concur) → trial PASS 2026-10-08 → `FS-A-005` → `FS-R-005`: **stage 1 ACHIEVED**; `FS-A-006` (offline plan) → `FS-R-006` (2026-10-09): **v2.7 route accepted for offline development; prepare FS-A-007 (experiment (i)); no hardware action authorised**; `FS-A-007` (trial (i) stage 2a and, separately, display trial (iii) stage 3a, plus the reordering ask): **sent 2026-10-09 → `FS-R-007`: images accepted; live concurrence held for a host timing fix and exposure wording; return package `FS-A-008` → `FS-R-008`: **CONCUR with trial (i) and, separately, trial (iii)** (2026-10-09)**, with `FS-A-007-raw.zip` and the private `FS-A-007-image.zip`; earlier bundles `FS-A-004-bundle.zip`, `FS-A-004-image.zip`, `FS-A-005-raw.zip`. **Update 2026-10-10:** trial (i) → `FS-A-009` → `FS-R-009` (admissible with the deviation; COMPATIBILITY FAIL retained; amended listing rule A; trial (iii) concurred); trial (iii) → `FS-A-010` → `FS-R-010` (INCONCLUSIVE retained; trial (iii-b) **preparation** concurred); **Update 2026-10-11:** `FS-A-011` (consolidated; the incomplete sent draft is disregarded) → **`FS-R-011`: CONCUR EXECUTE trial (iii-b)**; Quest 2 channel accepted for continued offline work; D1–D7 ruled (J-104). Full index: the relay index (private) |
| stage-1 builder | `devices/quest3/stage1/`: `init.sh`, `build.sh`, `fs-reboot.c`, `fs-proto.ps1`, `host-observe.ps1`, `test-host.ps1` (74 fixtures), `test-gadget.sh`, `test-modorder.sh`. **Stage 1 PASS 2026-10-08** with image `20261008T024856Z-112740d1bd6a4ecf` (FS-A-005, FS-R-005). Open corrections before the next device proposal: collector redesign, E1 (`--git-dir`/`--work-tree`), full `misc` capture *(status 2026-10-10: these were addressed in the FS-A-007/FS-A-008 host tools, `devices/quest3/host/` and `common/MISC-RULE.md`, which were used in trials (i) and (iii); FS-R-007/008)*. Later stages: `stage2a/` (trial i), `stage3a/` (trial iii, spent), `stage3b/` (trial iii-b, built; concurred to execute by FS-R-011 §1; not yet run) |
| **kernel rebuild gate** | **step 2 PASSED (J-31):** Quest 3 v2.7 public source, stock config, clang r450784e → **2601/2601** vendor-required CRCs match, `module_layout 0xb1f01218` equal, BTF kinds ≤ 15. Step 3 groups (a) DEVTMPFS/FHANDLE/AUTOFS=m/BTRFS=m and (a′) +USER_NS/PID_NS **PASSED** (0 existing CRCs changed) → **Quest 3 v2.7 kernel route a credible candidate** [D] (group b SYSVIPC/POSIX_MQUEUE still excluded; **Matches the checked symbol-version interfaces; complete module compatibility and runtime behaviour remain open** (FS-R-006 §2)); **Quest 2 v2.7 gate PASSED** (exact source `6bde5fc06b25`; 838/838; ACM + groups a/a′ change no CRC; J-32); **Quest 3S 2583/2583 and Quest Pro 776/776 PASSED** (stock + superset only; J-36). Evidence FS-A-006 (private review record); work dir WSL `~/work/kgate27`. Toolchain: `~/toolchains/clang-r450784e`, AOSP make 4.3 in `~/toolchains/build-tools`; Meta's build environment from `README.meta.md` |
| **safety** | `PROJECT_SETUP.md` §6A and `docs/DEVICE_PORT_CHECKLIST.md` (binding). Performance envelopes: `docs/research/perf-envelope-*.md` |
| research notes | `docs/research/`: FS-A-006 notes (ports, quest-projects, userspace, power-thermal, kernel), quest2-v2.7-first-look, perf-envelope-quest3 / -quest1-2 / -xr-elite; since then: thermal-control-design, display-bringup-quest3, display-handoff-dark, quest3-panel-online, display-clues-kexec-quest1, oculus-linux-kernel-yusuf, serial-loss-trial3, community-quest-repos-2, armadavr, valve-packages-licensing (index: `docs/RESEARCH_NOTES.md` §10) |

Material outside this repo, read-only: the PM's existing Quest 1 / XR Elite
material.
