# FrameShift — Journal

*Edited for publication: names and links removed or paraphrased.*

**What this is.** A running record of how FrameShift got from "a SteamOS image
exists for ARM" to a working port on standalone VR headsets: what we tried,
what we found, what worked, what didn't, and what is dangerous. It is written
so someone new can read it top to bottom and retrace the path — or skip
straight to **[Do not go here](#do-not-go-here)**.

It is kept current as work happens. When an earlier entry turns out wrong it is
**corrected visibly** — see [Corrections](#corrections) — not silently rewritten.

**How to read the tags.** Ruling `FS-R-001`:

- **[M]** measured on hardware, with output.
- **[M-static]** read from a named file, image or dump.
- **[D]** derived from something measured.
- **[C]** inferred, unconfirmed.
- **[O]** open.

**Where things are.**

| what | where |
|---|---|
| the plan | `docs/PROJECT_SETUP.md` |
| deferred questions | `docs/RESEARCH_NOTES.md` |
| arguments to the reviewer ("Chair") and the rulings | `relays/` |
| per-device work | `devices/<device>/` |
| firmware and images (gitignored) | `firmware/` |
| third-party binaries (gitignored) | `build/` |

---

## Where we are now

| | |
|---|---|
| **Goal** | Valve's SteamOS (the Steam Frame's ARM build) on Meta headsets in the order adopted by FS-R-006: **Quest 3 → Quest 2 → Quest Pro → Quest 3S → Quest 1 → XR Elite** (Pro and 3S offline/build only; changes applied in lockstep). |
| **As of** | 2026-10-19 (UTC), through J-217. Latest ruling **FS-R-016** (T0 complete; K1g r2 REVIEW accepted; the K1g r3 reads concurred, its gate delta next). Entry point: the root `README.md`. The relays and rulings are private review records (J-167); the journal records their effects. Public repo `continuumxr/frameshift` public since 2026-10-12 (J-118). |
| **Stage** | **M1 first shell** passed (Stage 1, FS-R-005). **M2 correct image** passed: stage 3c on Unit 1 (v66, J-125), then **stage 3d on both Quest 3 units at v2.7** (J-144, J-146). **K1a** passed: a FrameShift-built v2.7 kernel booted on both units (FS-R-013, J-193). **T0** (the first thermal-service step, under stock Android) passed on both units (FS-R-016, J-205, J-206). **K1g** r2 on Unit 2: REVIEW, the kernel booted cleanly but the probe failed closed before arming (a read-alignment defect, J-207); r3 fixes it (J-212). Earlier trials: (i) COMPATIBILITY FAIL at step 4, a listing-rule defect (FS-R-009); (iii) INCONCLUSIVE (FS-R-010); (iii-b) machine PASS, run 2 lit but garbled (J-107). |
| **Next device action** | **K1g r3** (the boot-chain guard) on Unit 2, after the Chair has reviewed the gate revision (FS-R-016); then N1 on Unit 2 and K1g on Unit 1; then K1i, the full thermal service and **R-1 "SteamOS boots"** (J-172, J-208). |
| **Units** | Quest 3 Unit 1 `QUEST3UNIT1`: v2.7 (J-131), `fastboot boot` only; faulty proximity sensor. Quest 3 Unit 2 `QUEST3UNIT2`: v2.7, slot `_a`; faulty IPD slider and proximity sensor (J-133). Quest 2 `QUEST2UNIT`: v2.7, slot b (J-75). |
| **Biggest known risk** | Valve's update machinery writes Qualcomm boot firmware. It is isolated by ruling `FS-R-001`. |
| **Biggest unknown** | Head tracking on non-Valve hardware. Parked until boot and display work — not dropped. Nearer term: whether the Quest 3 panels light at all on our `fastboot boot` path (H1 vs H2, `docs/research/display-handoff-dark.md`) [O]. |

---

## Do not go here

Paths that are dangerous, or that looked promising and don't pan out. Each one
cost us something to learn.

1. **Never let Valve's update or firmware machinery run on a non-Valve
   headset.** After every update, Valve's `/boot/kernelsetup.sh` writes Steam
   Frame's U-Boot **and the entire Qualcomm boot chain** (`xbl`, `xblconfig`,
   `tz`, `hyp`, `aop`, `uefi` and more) to partitions found by name. It also
   edits the partition table of `/dev/sdb`, which on a Quest 3 holds `xbl_a`
   [M]. At every boot, `steamos-boot.service` runs `splctl`, which writes a
   `bootenv` partition. What stops this on other hardware is coincidence — a
   text match on the device-tree `model` string, plus partition names that
   happen to differ — not design. (`FS-A-001` §5, `FS-A-002` §2, `FS-R-001`.)
2. **Never install an unmodified Valve RAUC update bundle on a Quest.** It
   brings Valve's SM8650 kernel and DTBs and re-arms item 1. Updates must go
   through a port-controlled fetch → verify → diff → transform → install step.
   (`FS-R-001` R3.)
3. **Never write boot-chain partitions on any headset**: `xbl*`, `tz`, `hyp`,
   `aop*`, `uefi*`, `abl`, `devcfg`, `cpucp`, `shrm`, `qupfw`, `keymaster`,
   `multiimg*`. On the Quest 3 `androidboot.secure_fused = "1"` [M], so the
   **ROCKNIX-ABL route the handheld ports use — replacing `abl_a`/`abl_b` —
   will not work and risks a brick.** The ABL stays Meta's.
4. **Don't keep a Quest device-tree `model` string that contains `POC-F`,
   `POC-E`, `EV1`, `EV2`, `EV3`, `DV1`, `DV2`, `MP` or `mte`** (case-sensitive
   substring). That is the gate on Valve's firmware writer. Checked: none of
   the Quest 3's 15 model strings match, and the running one is
   `Eureka (PVT1.1)` [M]. Note this is a build check, not a safety boundary
   (`FS-R-001`).
5. **Don't inspect Valve's btrfs rootfs with `btrfs restore`.** It silently
   wrote **115,344 of 185,073 files as empty** — the small, zstd-compressed
   inline ones — and printed only a buried error. Use a read-only kernel
   mount with `ro,nologreplay` and copy out. (`FS-A-002` §1.)
6. **Don't read "ships a DTB for SoC X" as "supports SoC X".** Valve's 6.18
   kernel ships DTBs for SM8250 phones but has only the SM8250 clock driver
   enabled. Check the kernel config.
7. **Don't treat `github.com/ValveSoftware/steamos_kernel` as the Steam Frame
   kernel source.** It is the old SteamOS 2 x86 archive, newest branch 4.19
   from 2019. The Frame kernel's commit is not in it [M-static].
   *(Corrected 2026-10-23, see Corrections: Valve does publish Frame kernel
   source tarballs at `holo-packages.steamos.cloud/archlinux-deckard-hotfixes/source/`;
   the 0.4.5 commit `e66bc2ca6f8c` is only in the unofficial `evlaV` mirror.)*
8. **Don't ship from Valve's dev branches.** Valve's image server carries
   `rc`, `beta`, `bc`, `main` and more. Only `stable` is a release branch by
   Valve's own config, and only stable bundles are signed with the key a
   default install trusts. FrameShift releases from `stable` only.
   (`FS-A-003` §5a.)
9. **Think before `fastboot set_active` on a Quest.** Switching to a slot
   holding a different Android version boots that Android against the shared
   `userdata`, which can migrate data one way **[C]**. Prefer experiments on
   the already-active slot. (`FS-A-004`.)
10. **Don't expect Valve's tracking firmware to load on a Quest.** SteamVR's
    `cv` driver on the Frame depends on SM8650 DSP images. Those are signed
    per SoC and OEM **[C]**.
11. **Strings in a binary are not control flow.** U-Boot conclusions drawn
    from string tables are hypotheses (`FS-R-001` §4).
12. **Don't count on ramoops/pstore surviving a reboot on the Quest 3.** It is
    configured, reserved and live [M]. But a marker written to `/dev/pmsg0`
    was gone after a warm `adb reboot` (twice) and after a reboot through
    the bootloader. Even the previous kernel's console log was gone, and the
    records were absent from the first moment adb came up — before Meta's
    `panicreporter` runs [M]. Find another way to prove a test kernel ran.
13. **Don't create partitions to satisfy Valve's expectations.** Nothing in
    Meta's boot chain reads `bootenv` or `uboot_*`. Worse, Valve's firmware
    writer checks that its target partitions *exist* before writing.
    Creating names like `xblconfig_a` would *arm* it to overwrite the
    Quest's `xbl` with Steam Frame's. Partitions we genuinely need for
    SteamOS (esp/efi/rootfs/var/home) belong inside the `userdata` area
    (`sda`), never on the boot-chain LUNs (`sdb`/`sdc`/`sde`).
14. **Don't assume Quest 3 is "SM8550 plus a new device tree".** Its platform
    is `anorak` [M]. Its main clock controller and UFS layout match SM8450
    far more than SM8550, and mainline Linux has **no** `anorak` support
    [M-static, research pass]. A mainline Quest 3 kernel is a new-SoC port.
    For now the published Meta kernel is the base.
15. **Don't "fix" Valve's broken `steamos-firmware-update` to make an image
    work.** Its syntax error happens to block its firmware-update path.
    Repairing it would re-arm that path (FS-R-002 rev. §5).
16. **Don't write diagnostics to the Quest's persistent partitions as a
    shortcut.**
    - `userdata` is encrypted; Android holds the keys.
    - `persist`, `metadata`, `misc` and `devinfo` hold calibration,
      encryption metadata and boot-control state.
    - The 2 MiB `pstore` partition is unused (all zeros) and the stock kernel
      can't write to it (`PSTORE_BLK` off).

    Any persistent logging is a separately reviewed, scoped write.
17. [removed for publication]
18. **Don't patch sources through inline heredocs or `python -c` strings in
    this environment.** Backslashes get rewritten on the way through: a
    `\`-newline continuation became a literal `\n` (the J-20 blocker), a
    `sed` once deleted every `$`, and `\\f` became a form feed. Write the
    patch as a script file, run `scan_escapes.py`, and **execute** the
    changed code: `sh -n` passes valid-but-wrong lines.
19. **Don't trust a negative test that only checks "it failed".** A harness
    that ran the wrong command (`neg label env …` without `shift`) reported
    every negative as refused. Each negative must assert its expected
    refusal reason; each new fixture gets a control run against the old code
    that must fail.
20. **Don't use a script-level PowerShell `trap { continue }` as a
    "log and carry on".** It resumes after the enclosing top-level statement,
    so inside a loop it leaves the loop. Use `try/catch` at the granularity
    you want to survive.
21. **[O] means OPEN, not "observed".** I used [O] for "observed" throughout
    FS-A-004 rev 3 and FS-A-005, and the Chair corrected it (FS-R-005 §5).
    Hardware output is [M]; a named static artifact is [M-static]; a
    derivation is [D]; a hypothesis is [C]; an unresolved question is [O].
22. **Don't send characters blindly into the target shell.** The collector
    must tell command echo apart from completion, handle continuation and
    partial output, and stop on a missing completion marker, reporting
    INCONCLUSIVE rather than sending more (FS-R-005 §5, D1). Prove this
    offline before the next collection.
23. **Don't run a headset under our own image at high load without
    thermal protection.** The skin and battery *shutdown* thresholds live
    in Android userspace; the kernel DT mitigates only partly, and the GPU's
    kernel cooling path is not shown to act autonomously (FS-R-006 §4).
    Our image must provide and verify its own thermal control (fan policy
    with tach/failure handling, temperature-based throttle/shutdown), or
    keep the hold short and bounded (`PROJECT_SETUP.md` §6A).
24. **Don't trust the stock kernel's default CPU governor.** The Quest 1/2
    stock kernels default to `performance`, so every cluster sits at
    maximum without Android's power HAL.
25. **Never force a CPU beyond the OEM frequency table.** Community reports
    say this has permanently damaged a headset (2026-10-08). [paraphrased for publication] The CPU
    table is firmware-owned. GPU overclocking through a kernel module is
    possible but beyond-spec; it is outside the envelope unless separately
    decided (J-30).

---

## Building on others

We don't reinvent what others have solved; we build on it and finish what
they haven't. This index is per device. Details: `docs/RESEARCH_NOTES.md`.

| repo | relevant to | what we take from it |
|---|---|---|
| `hashtagbasit/SteamOS-ARM-Port` (GPL-2.0) | **Quest 3 now**; all | initramfs with a USB ACM+NCM debug shell; Valve rootfs ingest from `.raucb` + casync; service mask lists; a signed updater with rollback; stock-ABL boot recipes (REDMAGIC 6, Lenovo) |
| `MaSieS4Fun/SteamOS-ARM-SM8550` | Quest 3 (bring-up material) | Armbian SM8550 kernel patch set |
| `iddqdExe` fork (commits `d08846a5`, `971ecc56`) | any stock Qualcomm ABL | appended-DTB alignment quirk in gzip v0 boot images |
| `justjoseorg` fork (commit `5557ac0d`) | Quest 3 | the list of Frame VR components — what a headset port must **keep** |
| `gryoza/reverie` | Quest 3 | rootfs extraction from Valve's casync store, plus its own updater |
| Valve `frame-public/lepton` | later (tracking) | an Android container built on Waydroid, Halium and libhybris |
| `pmaports` `device-lynx-r1` / `linux-lynx-r1` (an XR2 headset) | **Quest 2, XR Elite** | mainline 6.13 on an XR2: USB, Wi-Fi and UFS working; dual-DSC panel work stuck — the closest XR prior art |
| postmarketOS `soc/qualcomm-sm8250/linux` | **Quest 2, XR Elite** | active SM8250 community kernel (7.2) |
| `msm8916-mainline/linux-mdss-dsi-panel-driver-generator` | all (display) | turns downstream panel DT into a mainline `drm_panel` skeleton |
| `Block-Flock/pmaports-oculus-monterey`, `cstahly/quest1-bootloader-to-VR` | **Quest 1** | Quest 1 Linux on Meta's 4.4 kernel: USB networking, Wi-Fi, Monado, controllers. The UFS is 4Kn |
| Valve `initrd_shell` initramfs hook | Quest 3 | FunctionFS/adbd setup — prior art for an ADB fallback |
| `seilent` fork, branch `pocket-micro-2` | **Quest 2, XR Elite** (SM8250) | SM8250 kernel 7.2.6 via `seilent/armada`, Adreno 650 firmware |
| `nicolas-riera/Quest1-SteamOS` | **Quest 1** | SteamOS via `fastboot boot` of Meta's kernel; Monado; custom SteamVR driver; 3DoF; a map of the Frame stack |
| `facebookincubator/oculus-linux-kernel` | all Quests | Meta's per-build kernel source, device trees included |

What we **don't** take: the ROCKNIX-ABL boot route (see Do-not item 3), and the
port's handheld-specific stripping of VR components.

---

## Log

### Before 2026-10-07 — inherited from an earlier, shelved device programme

- Work from that earlier programme is not published *[removed for publication]*. A claim
  from that work that "any bad kernel is recoverable" was **rejected** as
  overreach: two recoveries are not a guarantee (`ERRATA-001`).
- The XR Elite is SM8250 [M], read from its own `dtbo`.

### 2026-10-07

**J-01 · Premise fixed: this is a port of SteamOS, not a lookalike.** Valve
published an ARM SteamOS image for the Steam Frame:
`steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2`, 4.07 GB. The work is
the kernel, device tree, display and sensors — not building a distribution.

**J-02 · First read of the Steam Frame image** [M-static] (`FS-A-001`).

- **Partition layout:** GPT with `esp`, `efi-A`, `rootfs-A`, `var-A`, `home`.
  The rootfs is **btrfs**, unlike Steam Deck's ext4.
- **U-Boot:** `2025.07-rc3` for board `deckard`. Its FIT embeds an
  `sm8650-deckard` device tree. **Steam Frame is SM8650 (Snapdragon 8 Gen 3).**
- **Display:** two DSI controllers, one panel each, with a Valve
  `drm_panel` driver on upstream `drm/msm`. No panel timings anywhere in the
  device tree.
- **Partition lookup:** the rootfs finds partitions by GUID, via
  `/SteamOS/PARTSETS`.

**J-03 · Plan reordered: Quest 3 first.** The Chair's continuity directive and
the evidence agree. The Quest 3 can `fastboot boot` a kernel without writing
anything; this requires an unlocked headset (assumed). The Quest 3 (XR2 Gen 2) is also the nearest neighbour to the
Frame's SM8650. The XR Elite is shelved and Quest Pro dropped.

**J-04 · The Frame's rootfs** [M-static].

- **Kernel:** `6.18.0-gfbdbca41fd45`. Mainline-style, with `msm` and Valve's
  `panel-deckard` built in, and the full config embedded.
- **SoC coverage:** SM8550 support is a near-miss — no SM8550 interconnect.
  SM8250 support is effectively absent.
- **Userspace:** SteamVR native ARM64 is the VR runtime, and FEX is the x86
  translation layer.
- **Tracking:** the tracking driver (`cv`) loads SM8650 DSP firmware.

**J-05 · Safety finding: Valve's updater writes boot firmware** (Do-not item 1).
Reported in `FS-A-001`. Ruling `FS-R-001` accepted it:

- isolate Valve's update machinery;
- no unmodified bundles;
- Stage 1 uses the **Quest's own stock kernel** plus a minimal initramfs, with
  mainline as a parallel track;
- pre-declared console outcomes: PASS / TRANSPORT FAILURE / INCONCLUSIVE;
- U-Boot and tracking deferred.

**J-06 · Clean extraction; the full writer inventory** (`FS-A-002`).

- **Clean extraction:** a read-only kernel mount recovered the files
  `btrfs restore` had zeroed (Do-not item 5). The image's hash is unchanged,
  and there was no btrfs tree log to replay.
- **Caller chain traced:** RAUC install → `post-install.sh` →
  `steamos-finalize-install` → `kernelsetup.sh`.
- **Second writer:** `splctl` writes a `bootenv` partition at every boot.
- **Not a threat:** `steamos-firmware-update` doesn't even parse in this build.

**J-07 · Valve's update server, and the release policy.**

- **Server:** `steamdeck-images.steamos.cloud/vr/` holds every Frame build as
  a small signed RAUC bundle plus a casync chunk store.
- **Signing:** only `stable` builds are signed with the key a default install
  trusts. 0.4.4 "Beta" — the publicly announced one — is signed with Valve's
  dev key [M-static, verified with `openssl cms`].
- **Policy (PM):** release from `stable` only, which is currently 0.3.0.
  `beta` may become an opt-in channel once the team grows. (`FS-A-003` §5a.)

**J-08 · Kernel source.** Valve's `steamos_kernel` repo turned out not to be
the Frame kernel (Do-not item 7). **Meta does publish per-build Quest 3
kernel source**, device trees included:
`facebookincubator/oculus-linux-kernel`, branch
`oculus-quest3-kernel-master`, one commit per firmware build [M-static,
two commits checked directly].

**J-09 · Community work surveyed.** Five narrow research agents covered the
port's boot path, its update handling, the forks, Meta's source, and Valve's
builds. Key lessons:

- **Valve updates:** the leading port avoids Valve's updater by design rather
  than defusing it, and ships its **own** signed updates.
- **Boot route:** it boots through a replacement ABL, which can't apply to a
  fused Quest.
- **Reusable:** its initramfs USB shell and its stock-ABL recipes.
- **Precedent:** `Quest1-SteamOS` already boots SteamOS on a Quest 1 with
  `fastboot boot`.

**J-10 · Quest 3 static baseline** (`FS-A-003` §1) [M-static], covering ten
firmware sets from v66 to Horizon OS 2.7, with OTA payloads extracted and
hash-verified.

- **Kernel line:** every build is **Linux 5.10**.
- **Built in on every stock kernel:** a USB ACM serial gadget and ramoops.
- **Ramoops region:** reserved in the stock device tree at `0xbfa00000`.
- **`DEVTMPFS` is off**, so our initramfs must create `/dev` itself.
- **Platform codename** in the drivers is `anorak`.

**J-11 · First hardware contact: read-only probe of the PM's Quest 3** [M].
Quest 3 Unit 1 (`QUEST3UNIT1`). [paraphrased for publication]

- **Active slot is `_a` (v66)**, not B as assumed.
- `secure_fused=1`.
- DT model `Eureka (PVT1.1)`, compatible `qcom,anorak oculus,eureka …`.
- Panel `meta,eureka_panel_sharp`.
- ramoops live at `0xBFA00000` (576 KiB) and pstore mounted.
- USB controller `a600000.dwc3`.
- Full UFS map:
  - `sdb` = `xbl_a` and friends;
  - `sdc` = `xbl_b`;
  - `sde` = most slotted firmware, plus `boot`/`vendor_boot`/`dtbo`;
  - `sda` = `userdata`/`super`/`persist`.
- No `bootenv` or `uboot*` partitions.

**J-12 · Tooling.** busybox-static 1.37.0 arm64 fetched from the Ubuntu
archive. The chain was verified end to end: archive signature → package
index → `.deb` hash. WSL now has `lz4`, `cpio`, `dtc`, `zstd`, `erofs-utils`,
`simg2img`, `bwrap` and `casync`. The Android boot-image, OTA-payload, LZ4,
cpio and DTB parsers are our own, validated against OTA hashes.

**J-13 · Chair ruling `FS-R-003`.**
- Stay with the stock-kernel experiment and keep preparing it offline.
- No OTA or kernel rebuild is justified yet.
- Don't switch slots just to get a source match.
- Use AOSP tooling to cross-check our parsers.
- Rewrite the initramfs sequence with staged markers. PID 1 must never exit.
- Use a fresh nonce for every attempt.
- PM process rule: the next relay is finalised only after the Chair's
  response to the previous one has been reviewed.

**J-14 · Retention tests and the bootloader's own report** [M]. Raw logs:
FS-A-004 (private review record).
- **pstore retention failed in every path tried:**
  - T1, warm reboot;
  - T1b, warm reboot with polling from the first moment adb was up, which
    rules out Meta's `panicreporter` cleaning the records;
  - T2, reboot through the bootloader.
- **T3 (forced power reset) not run.** It needs the PM's hands, and retention
  is even less likely there.
- **`fastboot getvar`:** `current-slot:a`;
  **both slots `successful:yes`, `unbootable:no`, retry count 6**;
  `max-download-size` 768 MiB; `is-userspace:no`; `kernel:uefi`.
- **Slot policy (PM):** the active slot (A) is known-good and stays untouched.
  Anything that writes goes to slot B. `fastboot boot` writes nothing, so it
  is slot-agnostic.

**J-15 · Chair rulings `FS-R-002` (original, then revised after the bundle)
and the PM's relay-timing rule.**
- **Verified:** the Chair checked all 52 bundle files against their hashes,
  and confirmed from Valve's own source that the update hook edits the GPT
  before its firmware checks.
- **Narrowed:**
  - the firmware-slot check covers the *current* slot, but the writes go to
    the *other* slot;
  - `--no-kernel` / `--no-bootloaders` don't stop `kernelsetup.sh` — only
    `--no-boot-install` does;
  - `set -e` doesn't protect code called under `if !`.
- **Added to the inventory:** the `steamos-efi` delegate, the `deckard_fw`
  initramfs hook, `vrconfig_write` (a `/persist` writer), and the chroot and
  `/etc`-overlay effects.
- **PROJECT_SETUP:** corrected per FS-R-002 rev. §7. That included a tag
  sentence my own earlier search-and-replace had mangled.

**J-16 · Stage-1 image built offline** (`devices/quest3/stage1/`).
- **Parsers cross-checked:** Google's AOSP `mkbootimg`/`unpack_bootimg`
  (commit `d2bb0af5`) agree with our hand parsers, with byte-identical kernel
  and DTB.
- **Ramdisks:** one vendor fragment holds the modules, the boot ramdisk is
  Android's generic one, and the two share no paths.
- **Modules:** Meta's **recovery** list (97) is a superset of the normal
  first-stage list (76). It adds LEDs, reboot-mode and display.
- **USB:** the controller is `dr_mode=otg` with a role switch, and the role
  can be forced to `peripheral` through sysfs [M on Android].
- **LEDs:** red, green and blue LEDs exist [M], usable as a visual stage
  signal.
- **Builder result:** the stock kernel is **byte-identical** in the new image;
  the only header differences are the ramdisk size and the dropped 4096-byte
  boot signature.
- **Still to come:** the reboot-to-fastboot helper needs an aarch64
  cross-compiler.

**J-17 · Kernel landscape for our targets** (two research passes,
[M-static], not yet re-checked by the Arbiter).

| finding | status |
|---|---|
| Quest 3's `anorak` in mainline | **zero support**: no SoC ID (549), no clock/pin/interconnect drivers, GPU chip ID `0x43050b00` absent from mainline's catalog |
| `anorak` vs SM8550 / SM8450 | clock-controller offsets match SM8450 (95/119) far better than SM8550 (0/97); the GIC address matches Qualcomm's XR part SAR2130P |
| postmarketOS (now **"Nura"**) Quest ports | none for any Quest |
| Lynx R1 (an XR2 / SM8250 headset) | in pmaports on mainline 6.13: USB, Wi-Fi and UFS work; its dual-DSC panels do not |
| Quest 3 panel | Sharp/Novatek, dual-DSI, DSC, C-PHY, 2064×2208 per eye, 72–240 Hz |
| postmarketOS panel-driver generator | gives a skeleton only for this panel (no dual-DSI; ignores Meta's extra init sequences) |
| Quest 1 | active community ports exist on Meta's 4.4 kernel |

**J-18 · Stage-1 package finished** (FS-A-004 (private review record) and its bundle).
- **A real design bug, caught by measurement before any device use.**
  Android's own boot log on the headset [M] shows modules loading in
  *dependency* order, not `modules.load` order. My earlier `modules.dep`
  lookup had used bare names against a file that uses absolute paths, so it
  reported "no dependencies". Loading in list order would have started the
  USB controller before its PHYs.
- **The fix, and its proof:** `init.sh` now resolves `modules.dep` plus
  softdeps the way modprobe does. A `bwrap`-sandboxed test against Meta's real
  module files reproduces **all 35 loads the boot log captured, in exactly
  Android's order**, with zero dependency violations.
- **Reboot helper:** `fs-reboot` was cross-compiled (1,400 bytes; it can only
  request `bootloader`) and its disassembly checked. It is never run off the
  device.
- **Host side:** `host-observe.ps1` does the one `fastboot boot`, watches for
  our USB gadget, fastboot and adb, talks to our shell on PASS, and classifies
  against timing bands declared in advance.
- **Display:** the stock kernel has **no framebuffer console** (`CONFIG_FB`,
  `DRM_FBDEV_EMULATION` and `VT` all off) [M-static]. Our test init draws
  nothing on the panels. The LEDs are the visual channel.
- **Valve follow-ups:**
  - `deckard_fw` is install-only: it adds firmware files to Valve's initramfs
    and does nothing at runtime.
  - `steamos-efi/steamos-bootconf` is a static binary, still to analyse.
  - The activation links for `steamos-boot` and `setubootenv` exist.

**J-19 · Chair ruling `FS-R-004`, and FS-A-004 revision 2.**

The Chair kept the strategy but found real flaws in the measurement and
recovery design. All are now fixed and covered by fixtures.

| flaw | fix |
|---|---|
| **PASS could be faked by terminal echo**: the observer looked for the token it had sent | a challenge whose answer, `sha256(nonce:challenge)`, is computed on the headset and never sent; complete-record parsing; required kernel and PID 1; echo off; ack confirmed separately by PID 1 |
| **The observer could hang or crash** | a bounded process wrapper; serial timeouts and cleanup; a monotonic clock; exactly one device; gadget-to-COM association by nonce, with a mismatch meaning no contact |
| **Recovery depended on USB** — logging wrote to the USB tty before rebooting | RAM-first logging, a dead-man timer that touches nothing but RAM and the reboot helper, and the helper now required |
| **Outcome classes too generous** | `DEVICE_REJECTED` / `HANDOFF_ACKNOWLEDGED` / `INCONCLUSIVE`; timing alone never upgrades a result |
| **Inputs not enforced** | the builder enforces every reviewed hash, static-ELF rules, the exact ramdisk list and the exact header diff, and reads busybox's real applet table. The observer refuses mismatched or already-used images, and images built from a different `init.sh` |

Results:
- **44/44 host fixtures pass** under Windows PowerShell 5.1 — the runtime the
  Chair could not test. One initial failure was a bad fixture, not the
  observer.
- Builder negatives refused; preflight accepts the attempt image and rejects
  stale builds.
- **Lesson:** the Chair's echo counterexample is exactly the "PASS
  indistinguishable from not running" failure the project's conventions warn
  about.

**J-20 · FS-R-004 concurrence, pre-trial review, and FS-A-004 revision 3.**

- The Chair concurred (consolidated FS-R-004) with one trial of the
  revision-2 image. Before running it, two adversarial agent reviews (target
  `init`; host side and relay claims) found a likely blocker — the gadget's
  class bytes 0/0/0 would leave Windows without a COM port — plus a 60 s
  firmware-fallback stall, an uncertain handoff that ended observation, and a
  per-directory-only attempt guard. **PM: fix first, re-review.** The
  revision-2 image was retired unrun.
- The first revision-3 draft (commit `6802d66`) went through the same two
  reviews. They found:
  - **a blocker introduced by the fix**: `init.sh:198` had a literal `\n`
    instead of a line continuation, so `fail acm` would have run on every
    healthy boot (inline-patch damage; do-not 18);
  - the observer's hash checks **failed open** under StrictMode: a failed
    `Get-FileHash` made the guard `if` throw, which skipped the abort;
  - a pre-boot abort (e.g. headset not yet in fastboot) consumed the image
    directory for good.
- Fixes: gadget section rewritten with checked writes and exact string
  readbacks of all identity values; a new **execution** fixture
  (`test-gadget.sh`, bwrap + fake configfs) whose control run against the
  buggy init fails 6/6; fail-closed hashing plus a pre-registration `trap`;
  `precheck-*.log` until registration; case-sensitive records; `--ignored`
  clean-tree check and `PYTHONPYCACHEPREFIX`; five builder negatives
  including a late one (corrupted packed init) that proves nothing is
  published.
- Results: host fixtures **67/67** (control against the old observer: 4
  fail); gadget fixture 6/6 under dash and `bash --posix`; module order
  97/97; builder negatives 5/5 with the expected reasons.
- Rebuilt: `20261008T020221Z-f6977d6318f95802`, image `e91815bb…26e0`. The
  first revision-3 image (`5c03f6f6…`) is retired unrun.
- **Third round** (one combined final pass): no blocker, but one MAJOR. My
  F1 fix added a script-level `trap { …; continue }`. In PowerShell that
  `continue` resumes after the whole enclosing *top-level* statement, which in
  the watch loop is the `while` itself, so one stray exception after the boot
  would have ended observation of the only attempt. Fixed with a `try/catch`
  per watch iteration and around the boot call, and `Invoke-FsNative` never
  throws after `Start()`. New fixtures (I0–I6) run a full replica attempt
  against a **fake `fastboot.exe`** compiled by the fixture, with injected
  faults. The control (previous observer) fails I1 and I4. Also: G7 (a real
  `write()` error via `/dev/full`, with per-case timeouts), marker
  bookkeeping, and builder hardening (`fsmonitor`, `ls-files -v`,
  `PYTHONNOUSERSITE`). The second build was retired unrun and rebuilt:
  `20261008T022357Z-8bbf1d16a0e23361`, image `4b1acecd…dac7`. Host fixtures
  74/74, gadget 7/7.
- **Fourth round** (narrow re-check of that delta): no blocker or major.
  Fixed: the AOSP checkout's own git config could hide planted files from the
  clean-tree check (`status.showUntrackedFiles=no`, `core.worktree`), and a
  failing log call inside the per-iteration `catch` could still reach the
  trap. Three new builder negatives (8/8 in all). Rebuilt:
  `20261008T024856Z-<attempt nonce withheld>`, image `efefe10d…7250`. Relay marked
  ready; the fourth-round fixes are fixture-verified, without a separate
  review pass.
- **Post-concurrence review** (report-only, of the fourth-round delta): no
  defect that should stop the trial. One false claim, held for FS-A-005
  rather than fixed (any code change would void the concurrence):
  `-c core.worktree="$AOSP"` does **not** override a `core.worktree` set in
  the checkout's own `.git/config`. Git reads the repository config during
  setup, so a redirected work tree still looks clean. The working fix is
  `git --git-dir="$AOSP/.git" --work-tree="$AOSP"`, plus unsetting `GIT_DIR`
  and `GIT_WORK_TREE`, which also blind the check. The real AOSP config has
  no such entry [M-static], and abusing it needs write access to `.git/config`.
  To do after the trial: fix `build.sh`, add a `core.worktree` negative, and
  correct relay row N-1.
- The `init.sh` binding does not tell apart rebuilds of the same `init.sh`;
  the sign-off nonce does (a retired build run with the concurred nonce exits
  3). Stated in the relay.
- **COM-port fallback (PM decision, 2026-10-08): Windows-only for this trial.**
  If Windows refuses the port, the result is "gadget seen, no COM port". A
  later attempt can use WSL: `usbipd-win` 5.3.0 is installed, and the WSL
  kernel has `cdc-acm` and `vhci-hcd` [M-static]. Linux binds ACM regardless of the
  IAD class codes. It needs a WSL transport in the observer (new reviewed
  code), since Windows loses the device once it is attached to WSL.
- **Lesson:** both blockers in this stage were found by adversarial review,
  not by our own checks. Keep the review before every Chair submission, and
  prefer fixtures that *run* code over ones that parse it.

**J-21 · Stage-1 trial: PASS.**

- 2026-10-08, PM present and signed off live. One `fastboot boot` of
  `20261008T024856Z-<attempt nonce withheld>`.
- **Result:** handoff acknowledged (`Booting OKAY [10.191s]`). Gadget
  `FS-<nonce>` appeared as **COM7**; Windows bound it with no WSL fallback.
  Challenge verified, `HOST_ACK` confirmed, PASS 25.5 s after the observer
  started. LEDs: amber, blue, green, white (holding). Nothing on the panels,
  as expected.
- **From our shell:**
  - 97/97 vendor modules loaded; `FW_TIMEOUT=1`;
  - `msm_drm` probed (DSI panel, `card0`) but drew nothing;
  - fuel gauge `bq27xxx` could not reach its chip (I2C lines unpowered);
  - no remoteproc started.
- **USB:** device mode needed PID 1's sysfs role write. There was no UDC
  before it.
- **Recovery:** `/bin/fs-reboot`, then `fastboot reboot`, back to Android
  slot A. Ten of the eleven hashed partitions were unchanged.
- **`misc` changed.** A PM-cleared control showed that an ordinary reboot
  cycle rewrites the same vendor field at `0x1010`. The `bootonce-bootloader`
  string at offset 0 comes from `adb reboot bootloader`.
- **Lessons:**
  - Before checks must save the **contents** of small partitions (`misc`,
    `devinfo`), not just their hashes.
  - Check the shell's prompt state before sending quote characters over the
    serial channel (my collection script got that wrong twice; reads only).
  - Keep holds short until battery management is understood. After recovery,
    Android showed "discharging" while on AC.
- **The first FS-A-005 draft claimed USB came up "without forcing".** The
  adversarial review caught it: `init.sh` forces the role. Corrected.

**J-22 · FS-R-005: stage 1 ACHIEVED; FS-A-006 directed (offline).**

- The Chair independently verified the raw bundle: challenge response,
  transcript, PID 1, UDC, uptime, 97 modules, partition hashes and the `misc`
  control.
- Milestone recorded for unit `QUEST3UNIT1`, build `50105190000000511`,
  kernel `5.10.198-01402-g1c5986fe21ee`, image `efefe10d…7250`.
- The Chair tightened four claims:
  - **`misc`:** ordinary reboot handling *plausibly* explains it [C]. The
    trial's own byte changes and their writers are [O], since the
    immediate-before contents are missing. Do not call the trial free of
    persistent effects.
  - **Vendor ramdisk:** the boot path made the vendor modules available to our
    PID 1 [D]. *Which* component assembled the ramdisk is not established.
  - **USB role:** [M] the UDC appeared after our writes; [C] that they were
    needed, or which of the two writes was.
  - **Remoteprocs:** "our init launched no remoteproc; their registration and
    execution state remain unmeasured". The absence of dmesg lines is not an
    inventory.
- **Corrections required before the next device proposal:**
  - the collector redesign (do-not 22);
  - E1, the builder fix using `--git-dir`/`--work-tree`, with its regression
    case;
  - complete `misc` contents before and after, with a classification rule.
- **FS-A-006 (offline), two tracks:**
  - **(A) Quest hardware dependencies.** Fuel gauge and I2C first, then
    charging, thermal and cooling. Map the remoteproc, display and
    vendor_dlkm requirements one by one. Specify exact partition sources and
    journal-replay avoidance.
  - **(B) Smallest headless test of genuine Valve ARM userspace** over the
    existing USB channel.
- FS-A-006 deliverables: the dependency map, the missing artifacts, and the
  smallest next experiment with PASS/FAIL/INCONCLUSIVE criteria and
  recovery.

**J-23 · First FS-A-006 finding: the stock kernel config vs Valve
userspace.** Source: `firmware/quest3/extracted/v66_unit1_slotA/kernel.config`.

- **Off [M-static]:** `BTRFS_FS`, `DEVTMPFS`, `FHANDLE`, `AUTOFS_FS`,
  `NFS_FS`, `BLK_DEV_NBD`, `SQUASHFS`, `F2FS_FS`.
- **On [M-static]:** `EXT4_FS`, `OVERLAY_FS`, `BLK_DEV_LOOP`, `CGROUPS`,
  `CGROUP_BPF`, `BPF_SYSCALL`, `SECCOMP`, and the USB gadgets NCM, ECM,
  RNDIS, mass storage and FunctionFS.
- **Consequences for Stage 2:**
  - Valve's btrfs rootfs cannot be mounted as it is. It needs a
    port-controlled repack, e.g. ext4 [D].
  - Booting genuine Valve **systemd** probably needs a kernel with
    `DEVTMPFS` and `FHANDLE` on. Both are systemd hard requirements [C,
    to be checked against the systemd version Valve ships].
  - That means a kernel rebuilt from Meta's published source, with module ABI
    matching the vendor modules. This is likely the crux of Stage 2 [C].
  - NFS and NBD are absent, so the PC cannot serve the rootfs over USB as a
    root filesystem.
- The **smallest** genuine-Valve-userspace test does not need systemd: Valve's
  own loader, libc and a shell or binary carried in our initramfs, executed
  over the existing channel.

**J-24 · PM decisions: v2.7 is the build target; two-unit plan.**

- **v2.7** (`5.10.246-gd7102a837402`, Android 14, the latest available
  release) is the target for the SteamOS image. The image is built against
  v2.7's kernel source (`dbc2bc83a2b6`), modules, device tree and firmware.
  Toolchain: clang **r450784e** (14.0.7), the compiler in the v2.7 Image
  banner. The PM approved the clang download.
- **Unit 1** (`QUEST3UNIT1`, v66, slot A): `fastboot boot` only,
  never flashed. It remains the known-good v66 reference.
- **Unit 2** (a second Quest 3, identity to be recorded): reserved
  for the first `fastboot flash` work. It needs its own read-only baseline
  first.
- [removed for publication]
- **Testing the v2.7 kernel on Unit 1 is a hybrid.** The v2.7 kernel and
  modules ride in our boot image and initramfs. The device tree and
  low-level firmware stay v66. The DT differs by about 970 of 32k lines
  [M-static]. Kernel-side results transfer to the target; DT- and
  firmware-dependent results do not fully transfer.
- **Earlier misreading:** I took the PM's "agreed to all your proposals" to
  include developing on v66. The PM wants v2.7. Corrected the same day.

**J-25 · Quest 2 v2.7 first look; Quest 3 v2.7 toolchain and reference.**

- **Quest 3 v2.7 toolchain:** clang `r450784e` (14.0.7) downloaded from AOSP
  `android14-release`; tarball SHA-256 `9be6c18d…`. `clang --version`
  equals the v2.7 Image banner exactly (`8508608`, LLVM `4c603efb…`).
  - The earlier 12.0.5 (`r416183b`) download is not needed for v2.7.
  - An `r416183b1` attempt broke off (HTTP/2 error); the partial file was
    deleted.
- **Quest 3 v2.7 CRC reference** (`~/work/fs006-kernel/v27req/`):
  - 272 modules (131 vendor_ramdisk + vendor_dlkm + odm_dlkm);
  - 3,538 (symbol, CRC) pairs, 0 conflicts, 2,601 that vmlinux must provide;
  - `module_layout 0xb1f01218`; vermagic `5.10.246-gd7102a837402`.
- **Quest 2 v2.7** (`docs/research/quest2-v2.7-first-look.md`):
  - Android 14, same SPL as Quest 3 v2.7;
  - kernel `4.19.325-cip128`, same clang 14.0.7;
  - boot header v2; no vendor_boot or vendor_dlkm;
  - the same userspace config gaps;
  - **no USB ACM gadget** (NCM only).
- **PM decision:** Quest 2 v2.1 is not needed; local copies removed.

**J-26 · Quest 2 unit; ACM on the Quest 2; Quest 1 outlook.**

- **The PM's Quest 2:** one unit, on **v59**. The build target is still
  v2.7. Until further decision, it is `fastboot boot` only (single unit).
- **PM decisions:**
  - add a Quest 2 offline-scoping item to FS-A-006;
  - add the USB serial gadget to any Quest 2 kernel we build.
- **Possible no-rebuild route [C]:** build `u_serial.ko` and `usb_f_acm.ko`
  as separate modules against the stock 4.19 kernel. f_acm registers the
  configfs function itself, so this works if their imported CRCs match.
- **Quest 1 outlook [D]:** the hardest of the three, but pioneered by
  Quest1-SteamOS: a 4.4 kernel with backports, LSE emulation, and the GPU
  through libhybris. Our shared userspace layer transfers; their kernel and
  graphics work is the template.
- **Gate:** `git fetch --depth 1 <sha>` from GitHub needs the full 40-char
  sha. The short form failed. v2.7 source is
  `dbc2bc83a2b673f5d1c24ee9dadb0cd708ffda3f`.

**J-27 · Performance envelope research and safety requirements.**

- **PM policy:** use the full hardware-supported clock range with thermal
  protection; no beyond-spec overclocking (no firmware changes). The PM
  asked for all research to be logged and for safety to come first. The
  device safety requirements are now `PROJECT_SETUP.md` §6A.
- **Quest 3** (`docs/research/perf-envelope-quest3.md`). Confirmed on Unit 1
  [M], FS-A-006 (private review record):
  - CPU domains max 2054.4 MHz (cpu0-1, 9 steps) and 2361.6 MHz (cpu2-5, 11
    steps); governor walt.
  - GPU 285–690 MHz in 10 levels.
  - Meta's sustained app ceiling is about 1.92–2.05 GHz CPU / 545 MHz GPU.
    690 MHz is never exposed to apps.
  - **No DT cooling map targets the GPU:** Android throttles it from
    userspace.
  - The fan steps are 3700–5500 rpm, of an 8500 rpm maximum.
  - Battery temperature is the binding constraint.
- **Quest 2 and Quest 1** (`docs/research/perf-envelope-quest1-2.md`). From
  Meta's own firmware tables, matching Meta's docs:
  - Quest 2: CPU 1.80/2.42/2.84 GHz; GPU 587 MHz (no higher step for its
    bin).
  - Quest 1: CPU 1.90/2.30 GHz; GPU 710 MHz.
  - **Both stock kernels default to the `performance` governor.**
  - Skin and battery protection is userspace-only.
  - The cells are 5–7 years old.
- **Kernel gate side issue, verified at the PM's request:** the
  environment-detected config values.
  - `CONFIG_PAHOLE_VERSION` is unused by this tree.
  - `CC_CAN_LINK`'s consumers are all off in both configs.
  - The `pahole` binary (1.31) generates the kernel's BTF. The stock v2.7
    BTF uses only kinds 1–15. Our build must too (a pass/fail check); 0 of
    the 272 vendor modules carry BTF.
- **Make:** WSL's GNU make 4.4.1 was not the cause of the first config
  failure. Meta's Makefile needs `REAL_CC` (its compiler-wrapper hook),
  which is set by the documented build environment in `README.meta.md`.
  The AOSP make 4.3 is used anyway (`~/toolchains/build-tools`, hashes
  recorded).

**J-28 · XR Elite performance envelope (offline), at the PM's request.**

- Source: `docs/research/perf-envelope-xr-elite.md`, from HTC firmware
  v2.0.999.960 slot B in an earlier, shelved programme's archive (read-only;
  copies only) plus the PM's
  live bugreport.
- **The CPU and GPU frequency tables are identical to the Quest 2's:**
  1.8048/2.4192/2.8416 GHz; GPU bin 0, 587 MHz [M-static]. The Quest 2
  ceilings can be reused.
- **Thermal, fan and battery policy cannot be reused:**
  - the fan is userspace-only (MAX31760 + HTC's closed thermal-engine; no
    kernel curve);
  - the main 24.32 Wh pack is in the rear cradle and reports over UART,
    outside the kernel;
  - there is no kernel gold-cluster limit zone and no kernel skin trip;
  - HTC's shutdown thresholds are compiled into a binary.
- **Safety:** no full-range clocks on the XR Elite until our own fan loop
  and cradle-battery monitoring exist (`PROJECT_SETUP.md` §6A item 3).
- **Correction:** the XR Elite's SoC is XR2 (Gen 1), not "XR2+ Gen 1"
  (`PROJECT_SETUP.md` §1).

**J-29 · Device port checklist (PM directive).**

- The PM asked for a list of differentials that **must** be checked for
  every device port, with the original devices' controls copied so the
  hardware operates nominally. Created `docs/DEVICE_PORT_CHECKLIST.md`.
- It covers eight areas:
  - **A** thermal;
  - **B** fan and cooling;
  - **C** battery, charging and power;
  - **D** CPU/GPU performance;
  - **E** display;
  - **F** platform, boot and recovery;
  - **G** remote processors;
  - **H** other hazards (IR emitters, speaker protection, haptics,
    accessories).
- It ends with a status matrix for the Quest 3, Quest 2, Quest 1 and XR
  Elite.
- Binding through `PROJECT_SETUP.md` §6A item 8.

**J-30 · Community report on overclocking.** [paraphrased for publication]

- Community reports: CPUs can run up to the OEM-defined maximum, and forcing
  them beyond it has permanently damaged a headset; the GPU can be pushed well
  beyond its intended limits with only a kernel module [C]. [paraphrased for publication]
- **CPU:** confirms the policy of staying within the OEM table. Added as
  do-not 25.
- **GPU:** feasible because the GPU levels are kernel-defined, but
  beyond-spec. Raised voltage corners mean heat and wear; the Quest 3 GPU
  has no kernel throttle. Kept outside the envelope. Any future GPU
  overclock needs a PM decision, Chair review, the thermal stack first, a
  soak test, and Unit 2 only.
- Recorded in `docs/research/perf-envelope-quest3.md` and
  `perf-envelope-quest1-2.md`.
- **Follow-up reports** [paraphrased for publication]:
  - Quest 2 GPU sustained 940 MHz but was very unstable (+60% over
    587 MHz);
  - Quest 3 reached 710 MHz and might go further (+3% over
    690 MHz); [paraphrased for publication]
  - the same applies to the Quest Pro and the Quest 3S respectively [C].
- **Position unchanged.** GPU overclocking stays outside the envelope; the
  Quest 2's 940 MHz is excluded as unstable. If ever revisited: the Quest
  3's 710 MHz as the first step, with a PM decision, Chair review, the
  thermal stack first, instrumentation, and Unit 2 only.
- **PM goal (later phase):** about **+20% over Meta's nominal sustained
  clocks**, if safe, not over the maximum.
  - Within the hardware tables on the Quest 3 (CPU 2.30 GHz, GPU 654 MHz)
    and on the CPUs generally.
  - Exceeds the table on the Quest 2 GPU (in-spec maximum +12%) and the
    Quest 1 GPU (+6%).
  - Tested only after the thermal stack and fan control exist, with soak
    tests.
  - Table in the perf-envelope notes.

**J-31 · Kernel rebuild gate, Quest 3 v2.7: PASSED (step 2).**

- Meta's public source `dbc2bc83a2b673f5d1c24ee9dadb0cd708ffda3f`, built
  offline with:
  - the **exact stock v2.7 config**, run through olddefconfig. Only
    environment-detected values differ: `PAHOLE_VERSION`, `CC_CAN_LINK*`;
  - clang r450784e (14.0.7, matching the stock banner);
  - AOSP make 4.3;
  - Meta's documented build environment.
- **Result [M-static]:**
  - **2601/2601** vendor-required (symbol, CRC) pairs match, 0 mismatched,
    0 missing;
  - `module_layout 0xb1f01218` equals stock;
  - **BTF:** 111,670 types, kinds 1–15 only (stock: 111,669), so pahole
    1.31 is safe for this tree.
- **Consequence (reworded after review):** a kernel rebuilt from the
  public tree is **ABI-equivalent for module loading** [D]. Its runtime
  loadability and full source identity are [O]: release hash, Image size
  and some BTF functions differ, consistent with a squashed public tree. The rebuild route to systemd is open, pending step 3:
  - group (a): DEVTMPFS, FHANDLE, AUTOFS=m, BTRFS=m;
  - group (a′): + USER_NS, PID_NS;
  - each must change no existing CRC.
- **Build pitfalls found along the way:**
  1. GitHub single-commit fetch needs the full 40-char sha.
  2. Meta's Makefile sets `CC := $(REAL_CC)`, so `REAL_CC` and the LLVM tool
     variables from `README.meta.md` are required. Without them, Kconfig
     sees an empty compiler and fails with "Illegal option --". I first
     wrongly blamed make 4.4.
  3. `link-vmlinux.sh` calls `${PYTHON}` (default `python`), so pass
     `PYTHON=python3`.
- **Build identity:** our build reports `5.10.246-gdbc2bc83a2b6`. A real
  image must set `LOCALVERSION` to match stock (`-gd7102a837402`).
- **Evidence:** FS-A-006 (private review record) (scripts, logs, config
  diff, CRC compare, reference lists, IDENTITIES).
- **Step 3, group (a): PASSED.**
  - Config verified: DEVTMPFS=y (DEVTMPFS_MOUNT off), FHANDLE=y,
    AUTOFS_FS=m, BTRFS_FS=m. `btrfs.ko` and `autofs4.ko` were built.
  - **vmlinux CRCs: 0 changed, 0 removed** (0 added; these options export
    nothing from vmlinux).
  - Vendor-required 2601/2601; BTF kinds ≤ 15.
  - Build time 66 min.
- **Step 3, group (a′) (+ NAMESPACES, USER_NS, PID_NS): PASSED.**
  - **vmlinux CRCs: 0 changed, 0 removed, 12 added** (namespace exports).
  - Vendor-required 2601/2601; `module_layout 0xb1f01218`; BTF kinds ≤ 15.
  - Build time 77 min.
  - **For the real image config:** `BTRFS_FS_POSIX_ACL` came out off;
    enable it (it is module-internal).
  - The USER_NS caveat stands [C]: vendor modules built without it treat
    IDs as the initial namespace.
- **Quest 3 v2.7 kernel route: VIABLE.** systemd's hard requirements, btrfs
  and the sandbox namespaces can be added while keeping every stock vendor
  module loadable. SYSVIPC and POSIX_MQUEUE (group b) are still excluded:
  they change struct layouts.
- Evidence: FS-A-006 (private review record).
- **Quest 2 gate (queued, PM-approved):**
  - public source `6bde5fc06b252c97761bc0963dd13c1abcf377ab` is an
    **exact** match for the v2.7 build (`5224299.2420.150`);
  - reference: 28 vendor modules, 838 symbols from vmlinux,
    `module_layout 0x74b4ebeb`;
  - the stock Quest 2 BTF already contains 2 ENUM64 entries, so its BTF
    rule is "no kinds beyond stock".

**J-32 · Quest 2 v2.7 kernel gate: PASSED.**

- Public source `6bde5fc06b252c97761bc0963dd13c1abcf377ab` (an exact match
  for build `5224299.2420.150`), stock config, clang r450784e.
- **838/838** vendor-required CRCs; `module_layout 0x74b4ebeb`; BTF kinds
  as stock (stock already carries 2 ENUM64).
- **Each step changes no existing CRC:**
  - + USB_CONFIGFS_ACM (the PM's request; F_ACM and U_SERIAL built in):
    6 added;
  - + DEVTMPFS, FHANDLE, AUTOFS4=m, BTRFS=m: 6 added;
  - + NAMESPACES, USER_NS, PID_NS: 18 added.
- **olddefconfig set COMPAT_VDSO=y** (environment-detected; off in stock).
  Force it off in the real image.
- **Build pitfall:** Meta's committed symlinks in `techpack/audio` (and
  `include/soc/internal.h`) assume their internal tree layout
  `kernel/qcom/kona`. A link `~/kernel/qcom/kona → src` fixes it. A first
  attempt that linked inside the object directory did not help (the links
  are relative to the source). The `brcm4389ar` include link points into
  Meta's internal repo; that driver is off.
- Evidence: FS-A-006 (private review record).

**J-33 · Quest Pro and Quest 3S added as offline scoping; refresh-rate and
tester requirements.**

- **PM decision:** re-add the **Quest Pro** (dropped earlier) and add the
  **Quest 3S**, both as offline scoping.
  - The PM has no units, but others may, and the kernel
    builds may be useful later.
  - Strategy: do the work on the Quest 2 and Quest 3, then port the fixes;
    the Quest Pro and Quest 3S should be ~90% complete that way.
- **Firmware** (copied from the PM's archive, cmp-verified, provenance in each
  `firmware/<dev>/PROVENANCE.txt`):
  - Quest Pro v2.7 `QPro_51503870024400340` (`seacliff`, SPL 2026-06-03);
  - Quest 3S v2.7 `3814840020600610` (`panther`, SPL 2026-06-02).
- **Same sources, device configs [M-static]:**
  - **Quest 3S** = the Quest 3 tree, kernel `5.10.246-gd7102a837402`, ACM
    present; 36 config lines differ from the Quest 3.
  - **Quest Pro** = the Quest 2 tree, kernel
    `4.19.325-cip128-st12-g49638c7a8637`, no ACM; 127 config lines differ.
  - The binaries differ, so the gates are re-run with each device's own
    config and vendor modules (running).
- **PM requirement:** **90 Hz by default on all headsets, 120 Hz optional
  where supported** (`PROJECT_SETUP.md` §3 stage 3; checklist E4). The
  Quest 1's panels are believed to be 72 Hz only [C, to verify].
- **PM requirement:** brief third-party testers in writing on the
  conditions and risks before any test (`PROJECT_SETUP.md` §6A item 9).

**J-34 · FS-A-006 adversarial review (v2.7 re-scope).**

- The gate numbers held when the reviewer recomputed them: Quest 3
  2601/2601 and Quest 2 838/838; 0 changed CRCs per group; `module_layout`.
- **Three blockers, all in experiment (ii)** (the v2.7 kernel on Unit 1):
  - it would have bulk-loaded **36 extra modules** found only in v2.7's
    `modules.load.recovery`: ADSP, charger, thermal, and the USB-PD
    controllers, which could kill the only channel;
  - **`PANIC_ON_OOPS` is off in v2.7**, so stage-1 recovery assumptions
    don't hold;
  - it had no outcome classes.
- **(ii) is demoted to "named, not proposed"**, with 8 requirements
  (FS-A-006 §5.6): a pinned module list with a named exclusion list; never
  loading v66 modules; boot-header patch levels pinned to v66;
  TZ-facing modules; oops recovery; outcome classes; the gate run on the
  exact image kernel; the full §5.5 corrections.
- **Safety finding:** `qcom-spmi-temp-alarm` can set
  `SHUTDOWN_CTRL1_OVERRIDE_S2`, **disabling the PMIC's hardware stage-2
  over-temperature shutdown** [M-static source]. Added to the checklist (A5)
  and the safety rules.
- **Wording fixes:**
  - "exact match" becomes "same build number in the commit message;
    ABI-equivalent [D]; source identity [O]";
  - the gate's coverage and limits are now stated (CFI unchecked; inline
    semantics; vermagic/LOCALVERSION rationale; export collisions 0,
    verified);
  - a v66/v2.7 module-location table was added;
  - the Quest 2 framing became retroactive disclosure, and the Quest 2
    hybrid and its `performance` governor are noted;
  - the Quest Pro and Quest 3S were added.

**J-35 · Device ordering (PM decision) and build economy.**

- **Ordering (PM, 2026-10-08):**
  - **primary:** the Quest 3 and Quest 2 (the PM's units; experiments and
    hardware work happen there);
  - **lockstep:** the Quest Pro and Quest 3S. Every build, fix and config
    change is applied to them at the same time, wherever it applies; they
    share the Quest 2 and Quest 3 kernel trees;
  - **after SteamOS boots** on the Quest 3 and Quest 2 (and presumably the
    Pro and 3S): the Quest 1 and XR Elite.
- **Build economy:** per-group isolation builds were needed to prove the
  method. Every group passed with 0 CRCs changed on the Quest 3 and Quest
  2. For the siblings, only stock plus the final superset config are built.
  (The reason first written here, "no subset can then change a CRC", is
  not sound; see Corrections and J-36.)
- **Process slip:** a patch script asserted and aborted without writing,
  and I launched the gate run without checking. I caught it within a minute,
  before it could delete the hour-long Quest 3S stock build. Rule: **verify
  that a patch landed (grep or `bash -n`) before launching anything that
  depends on it.**
- **Quest 3S stock gate: PASSED.** 2583/2583 vendor-required CRCs;
  `module_layout 0xb1f01218` (identical to the Quest 3); BTF kinds ≤ 15.

**J-36 · Quest 3S and Quest Pro kernel gates PASSED; Quest 2 unit baseline.**

- **Quest 3S** (Quest 3 tree `dbc2bc83a2b6` + Q3S config): **2583/2583**
  vendor-required CRCs from 268 modules; `module_layout 0xb1f01218`; BTF
  kinds as stock. The superset (DEVTMPFS, FHANDLE, AUTOFS=m, BTRFS=m,
  USER_NS, PID_NS) changes **0** existing CRCs (12 added).
- **Quest Pro** (Quest 2 tree `6bde5fc06b25` + QPro config): **776/776**
  from 29 modules; `module_layout 0x74b4ebeb`; BTF kinds as stock
  (2 ENUM64, as on the Quest 2). The superset **with USB_CONFIGFS_ACM**
  changes **0** existing CRCs (18 added). olddefconfig again set
  COMPAT_VDSO=y: force off in the image.
- Only stock + superset were built (PM: "why so many builds?"; J-35).
  Evidence: FS-A-006 (private review record).
- **Quest 2 unit read-only adb baseline** (PM present): the Quest 2
  unit (`QUEST2UNIT`), Rev11, v59 build `50670960048600150` (Android 12, SPL
  2023-08-05), kernel `4.19.157+`, slot `_a`.
  CPU/GPU frequency tables on the unit match the v2.7 static analysis
  (587 MHz GPU cap confirmed on hardware). Evidence:
  FS-A-006 (private review record).
- **Quest 2 `fastboot getvar all`** (PM present; `getvar` reads only, but the reboot cycle is a state change, see Corrections; back to
  Android on `_a`, build unchanged): `kernel:uefi`,
  `hw-revision:20001`, **`model-revision:Hollywood (DVT)`** (the PM states it is this unit's production label; see J-37) [paraphrased for publication]. Slot a successful (retry 6); **slot b never marked
  successful** (retry 7), so it is not a known-good fallback. `super` 6 GiB.
  Evidence
  FS-A-006 (private review record).
  - Do-not: keep the unit off Wi-Fi / decline OTAs. An update would change
    the baseline and move the slot state.
- **Narrow adversarial re-check of FS-A-006** (2 blockers, all numbers
  verified against the raw files). Fixed:
  - the bootloader readout had been called "read-only"; the reboot cycle
    is a state change (`misc` probably written, not captured). The
    procedure and a post-return `getprop` check were appended to the
    evidence;
  - the device ordering departs from FS-R-005 and now has an explicit ask;
  - the superset-only claim was reworded: no subset was gated, and every
    other config must pass the gate itself;
  - the Quest Pro stock config also defaults to the `performance`
    governor (the Quest 3S uses schedutil); slot b on the Quest 2 is still
    marked bootable with retries, so a slot-a failure could fall through to
    unknown contents [removed for publication].
  - Note: v59 Android runs schedutil on the Quest 2 [M]; the v2.7 stock
    config defaults to performance [M-static]. The v59 kernel's default is
    unknown, so whether Android userspace switches it is [D/O].

**J-37 · PM decisions confirmed; Quest 2 provenance; ordering refined.**

- **Build target:** v2.7 for the Quest 3, Quest 2, Quest Pro and Quest 3S;
  the Quest 1 and XR Elite will have different targets.
- **Units:** Unit 1 (Quest 3) and the Quest 2 unit are `fastboot boot`
  only; Unit 2 (Quest 3) is for flashing.
- **Ordering (supersedes J-35):** Quest 3 primary, Quest 2 secondary,
  Quest Pro tertiary, Quest 3S quaternary, then Quest 1 and XR Elite.
  Kernel/OS changes for the Quest 3 and Quest 2 go to the Pro and 3S in
  lockstep.
- **Quest 2 provenance (PM):** retail unit. "DVT" in
  `model-revision` is the production label on this unit, so J-36's
  "possibly pre-production" is withdrawn. Our probes ran as adb `shell`
  (uid 2000).
- **Unit 1 and Unit 2** (Quest 3, DT model `PVT1.1`): [removed for
  publication]. Open question for release reach: whether
  retail Quest 3 units have the same speed bins and frequency tables [O];
  a read-only adb check of a retail Quest 3 (no reboot) would answer
  it, low priority.
- FS-A-006 updated with these decisions before sending.

**J-38 · FS-A-006 sent.**

- The PM relayed FS-A-006 (private review record) with `FS-A-006-raw.zip` (sha256
  `e3a41195…eef2e`, 29 files, `MANIFEST.sha256` inside) on 2026-10-09.
  Awaiting FS-R-006. FS-A-007 is not drafted until the ruling arrives.
- The PM does not need retail comparison units for now.
- Docs swept for the J-36/J-37 changes: checklist matrix (Quest 2
  baseline), Quest 1/2 envelope note (Quest 2 frequency probe resolved),
  research notes heading, Quest 3 README (primary; 3S split out).

**J-39 · FS-R-006 received: v2.7 route accepted for offline development;
prepare FS-A-007.**

- **Ruling** (FS-R-006 (private review record), verbatim):
  - concurs with offline v2.7 development, per-device dependency work and
    preparation of experiment (i);
  - **adopts the PM's order** Quest 3 → Quest 2 → Quest Pro → Quest 3S →
    Quest 1 → XR Elite (supersedes FS-R-005). Shared changes may proceed
    together offline, but each device keeps its own configs, artifacts
    and gates;
  - records the unit constraints (Unit 1 and the Quest 2 temporary-boot
    only, never flashed; Unit 2 for separately reviewed flashing; Pro and
    3S offline, no tested-device claim);
  - acknowledges the disclosed probes; **authorises no further hardware
    action.**
- **The Chair checked our evidence:** all 2601 Quest 3 rows, and the four
  reference lists (2601/838/2583/776). It accepts [M-static] that the
  recorded builds pass the CRC and `module_layout` comparisons, and [D]
  that the routes are credible candidates.
- **Verified the Chair's thermal corrections in the v2.7 source myself**
  (`~/work/kgate27/src`):
  - `eureka-thermal.dtsi`: `batt-virt-limit` trips at 45/58 °C (line 61ff)
    and `surf-virt-limit` at 48 °C (line 1898ff) map to CPU cooling;
  - `kgsl_pwrscale.c`: `of_devfreq_cooling_register` (line 796) and a
    `DEV_PM_QOS_MAX_FREQUENCY` notifier (line 777);
  - `pwm-tach-fan.c`: on `DRM_PANEL_EVENT_BLANK` the fan is set to
    `min(current, silent_rpm)` (lines 677–686), not stopped. DT
    `oculus,silent-rpm` = 4000 (eureka), 5000 (panther).
- **Docs corrected** (PROJECT_SETUP §6A and kernel-gate row, checklist A/B
  rows and B4, Quest 2/3 READMEs, power-thermal note,
  both performance notes, kernel and Quest 2 research notes). The +20%
  table now shows real table steps only.
- **Before FS-A-007 (experiment (i), stock kernel + 4 Valve files):**
  - A. pin the 4 full hashes, ELF dependencies, interpreter line and
    provenance; absolute paths; controlled child environment (clear
    loader variables);
  - B. FSB1 framing: attempt nonce, challenge, step IDs, byte counts,
    defined newline handling; reject incomplete/ambiguous records;
  - C. bounded supervision with verified KILL escalation (BusyBox
    `timeout` only sends TERM); fixture with a TERM-ignoring child; 143 is
    an exit status, not proof the timer fired;
  - D. PID 1 deadline independent of HOST_ACK and collection, tested;
    recover immediately after collection (300 s is a ceiling);
  - E. decide the software watchdog explicitly; manual recovery stays;
  - F. outcome classes PASS / compatibility FAIL / integrity fault /
    INCONCLUSIVE with explicit precedence;
  - `misc` rule: accept only specifically expected boot-command
    contents/transitions; vendor-range changes are "presumed
    reboot-related", not harmless by location;
  - plus the FS-R-005 prerequisites already listed in FS-A-006 §5.5;
  - the bundle must include the exact image, helper/collector code, full
    hashes, offline fixture outputs, before/after commands, recovery
    procedure, **and the cited research notes, `PROJECT_SETUP.md` and
    `DEVICE_PORT_CHECKLIST.md`**.
- **Before any rebuilt-kernel proposal (parallel, offline):** gate scripts
  must reject (nonzero exit) on mismatch, missing symbol, changed/removed
  protected export, forbidden collision, unsatisfied requested option,
  failed extraction, empty reference or parse failure; module inventory
  keeps source paths and hashes (no `cp -n` flattening); `btfkinds.py`
  fails on missing/malformed BTF and is called a kind scanner only;
  negative fixtures for each. USER_NS/PID_NS stay out of the first
  rebuilt-kernel experiment unless needed.
- **Performance:** tuning stays outside the userspace test; only existing
  table steps (Quest 3 GPU: 640 MHz = +17.4%; 690 withheld).

**J-40 · Stage 3 in parallel; Quest 1 90 Hz; device-monitor pop-ups.**

- **PM:** develop Stage 2 and Stage 3 **in parallel**, as separate
  experiments (not one combined test). Stage 3 (an image on the panels)
  does not depend on Stage 2: the stock kernel already drives the panels
  in Android, and `msm_drm` probed in stage 1. Offline display work falls
  under FS-R-006's "per-device dependency work". The reordering (a display
  trial before Stage 2 completes; FS-R-002 §7 put headless first) needs
  the Chair: it is rolled into FS-A-007 as an ask, per the relay
  convention (no separate relay). Display feasibility research running
  (`docs/research/display-bringup-quest3.md`).
- **Quest 1 refresh rate (PM):** not 72 Hz-only. Carmack (OC6, 2019) said
  the panels can do 90 Hz; it was held back (performance, FCC
  certification) [C, press report]. The PM reports a community mod that
  enabled 90 Hz [C, source not yet found by our search]. Corrects the
  earlier "believed to be 72 Hz only" (PROJECT_SETUP §3, checklist E4,
  Quest 1 README).
- **Device-monitor pop-ups:** a local tooling hook outside this project
  opened a device monitor whenever a command merely mentioned device tools.
  Not changed by us; the fix belongs to the PM. [removed for publication]

**J-41 · Display bring-up research: a static pattern on the stock kernel
looks feasible.**

- Note: `docs/research/display-bringup-quest3.md` (agent, read-only;
  spot-checked by me).
- **Panel:** `meta,eureka_panel_sharp` (the bootloader passes
  `msm_drm.dsi_display0=meta,eureka_panel_sharp`, and stage-1 serial log
  line 638 shows it binding) — Sharp/Novatek dual-DSI, video mode, DSC;
  the stage-1 log reports a stepped refresh range of 120–72 Hz [M]. Both
  eyes are on one connector. Corrects `sy103` (FS-A-006 §2.3, kernel
  note).
- **Why stage 1 showed nothing [D]:** our init never opened
  `/dev/dri/card0`, so no frame was committed. The stock config has no
  `CONFIG_FB`, no `DRM_FBDEV_EMULATION`, no `VT` (verified in the v2.7 and
  v66 configs), so there is no `/dev/fb0` or console. The PM saw nothing
  on the panels during the stage-1 hold [M, PM observation]; whether lit
  black or off is [O].
- **Minimal route [C]:** the same 97 recovery modules stage 1 loaded; no
  firmware; `mknod /dev/dri/card0 c 226 0`; a small static C program of
  ours (dumb buffer, one TEST_ONLY atomic commit, then the real commit,
  hold the fd open: closing it blanks). Meta's own recovery uses the same
  modules without a compositor.
- **Safety:** the stock driver does power sequencing; the backlight stays
  at the boot level (the driver blocks brightness changes "until bootanim
  is done", `dsi_panel.c:3918`); never write backlight/BLU knobs; static
  dark pattern, no flashing; the fan driver starts in "display on" (closes
  the `is_display_on` item), but nothing drives it in a stage-1 image, so
  the hold stays within the dead-man or gets a monitored variant.
- **Neither Valve userspace nor the rebuilt kernel is needed** (Stage 3 in
  parallel with Stage 2, J-40).
- **Top unknowns:** whether stock recovery draws on the panels (a reboot
  into recovery would show it, but that is a device action: FS-R-006
  authorises none, so it goes to the Chair in FS-A-007); first-frame
  behaviour after the splash handoff; actual boot backlight level; heat
  with the display held and no cooling.

**J-42 · Parallel tracks: T1 pins done; kgate under review; fs-pattern built.**

- **Track 1A (FS-R-006 §5 A): T1 pins** — `devices/quest3/stage2a/`
  (`T1-PINS.md`, `T1-pins.json`, evidence, tools). No Valve binary in the
  repo (staged only in WSL `~/work/t1pin/stage`).
  - Provenance: image `steamframe-oobe-repair-20260922.5153644-0.3.0.img`
    SHA-256 `081a38c0…cc654` (= FS-A-001 §10) → GPT #2 `rootfs-A`
    (offset 335,561,728) → btrfs → `usr/lib/…`, `usr/bin/…` (`lib`, `bin`
    are symlinks). Three sources agree (mount copy, btrfs restore, Valve
    package manifests glibc-2.39-2 / coreutils-9.5-1). All four SHA-256
    and the 2,062,760-byte total match FS-A-006 §4.
  - qemu-aarch64 runs with an empty environment and absolute paths: all
    steps rc 0; negative controls fail as required; the pin gate rejects 9
    tampering cases. `b2sum` KAT and challenge digests (with and without a
    trailing newline) agree with two independent implementations.
  - Limit: qemu is not the Quest kernel (ELF loader, vDSO, CPU features
    untested).
- **Corrections to FS-A-006 §4/§5** (carried into FS-A-007): see the
  Corrections table (`--list` rule; kernel BLAKE2b; `LD_PRELOAD` not
  blocked by `--library-path`). Also: `uname`/`b2sum` list
  `ld-linux-aarch64.so.1` in DT_NEEDED; `libc.so.6` has PT_INTERP
  `/usr/lib/…`; `b2sum` needs GLIBC_2.38.
- **Track 2: `tools/kgate/`** (commit `2578f7f`): two independent
  adversarial reviews found false-PASS paths (optional enforcement inputs;
  image/config not bound; reference device not compared; incomplete
  references accepted; symlinked module dirs skipped; toolchain WARN list
  too broad; one-directional config diff). All sent back for fixing with a
  fixture per finding; a fresh review follows. **Not yet a gate.**
- **Stage 3a: `fs-pattern`** (commit `877332d`): static DRM test pattern;
  fresh nonce in block digits on both eyes, dark greys only (max 0x90,
  3.6% lit); TEST_ONLY then real commit; 120 s hard hold cap plus a 150 s
  `alarm()` backstop; offline fixtures 46/46 under qemu; binary SHA-256
  `175cece4…c11451`. Adversarial review running. **Not proposed for a
  device** until the Chair rules on FS-A-007.

**J-43 · PM: monitor fixed; Quest 1 90 Hz source; hand tracking and
controllers; recovery display; 10 s display hold.**

- **Device monitor:** the PM had the local tooling fixed. No project
  change needed. [removed for publication]
- **Quest 1 90 Hz source:** `github.com/Juspertinry/q1-modules`,
  `q1_90hz` (MIT, author Juspertinry, v4.2, Quest 1 v50 only)
  [M-static]. `tools/dtpatch.py` retimes the panel in the appended DTBs:
  refresh rate and horizontal front porch only, size-preserving; DSC and
  init sequence untouched; plus a boot-time panel-clock resync. The
  Android byte-patches (composer HAL, VrDriver, xrspd) are irrelevant to
  us. Recorded in the Quest 1 README.
- **New PM requirements (later stage):**
  - **hand tracking:** SteamOS has none; keep the Quests' hand-tracking
    models and training if possible. Licensing and the camera/DSP runtime
    are [O]: these are Meta's proprietary files, so the "have" vs "ship"
    rule applies (PROJECT_SETUP §5);
  - **cross-controller pairing:** Oculus Touch, Meta Touch, Touch Plus and
    Logitech MX Ink on the Quest 1, 2, 3/3S and Pro; Touch Pro on the Quest
    3 and Pro only. Community modders have done it; the PM can supply
    sources when we get there.
  - Recorded in PROJECT_SETUP §3 (stage 5b) and checklist H5/H6.
- **Quest 3 stock recovery lights the panels** [M, PM observation]: the
  route in `display-bringup-quest3.md` (same 97 modules, plain DRM, no
  compositor) is confirmed to produce an image on this hardware. This
  closes that unknown; no recovery reboot is needed from us.
- **Display test hold: 10 s** (PM): fs-pattern's compiled maximum drops
  from 45 s to 10 s once the current review finishes.

**J-44 · Review rounds; shared PID 1 infrastructure.**

- **kgate 2.0** (`999e6c4`): a third, fresh review still found two exit-0
  paths: (1) the base config and baseline symvers were operator-chosen,
  so a wrong-device build or a self-comparison passed; (2) a truncated
  Image passed (trailing-zero tolerance). Plus: segment gaps not compared,
  multi-member gzip accepted, export type/namespace not bound, uneven
  waiver reporting, incomplete JSON. Sent back for fixing. **Still not a
  gate.**
- **fs-pattern v0.3** (`0df7974`) under fresh review; PM decision: the hold
  cap drops to **10 s** after that review.
- **Shared infrastructure** (`devices/quest3/common/`, `e890a7a`):
  `fs-supervise` (absolute path, controlled environment refusing loader
  variables, TERM→KILL on the process group, reports exactly how the child
  ended; a TERM-ignoring child ends `timer-kill sig=9`; an own exit 143 is
  reported as `exited code=143`); FSB1 framing (base64 payloads, record
  hash, trailing-`
` tolerance only, rejection of duplicates, reorders,
  stray lines, wrong nonce/challenge) with matching Python and PowerShell
  decoders; the deadline moved into PID 1's own loop with a backstop child,
  HOST_ACK only recorded; outcome precedence; the `misc` rule (only
  empty→empty, bootonce→same, empty→bootonce accepted; vendor range
  recorded as "presumed reboot-related"). Fixtures 51/36/36/15/18.
  Adversarial review running.
  - busybox `timeout -k` returned 143 and left a background child running
    under qemu, so it is not used.
  - ~~Finding on the stage-1 image: an unreadable `/proc/uptime` would
    abort PID 1.~~ **Withdrawn** (review, J-45): busybox ash treats the
    empty value as 0, so the shell survives; the real effect would be that
    `fail()` and the ack window never fire, while the dead-man still
    covers the hold. See Corrections.
  - `.gitattributes`: on-device `target/**` files now forced to LF
    (`fs-done` has no extension; a CRLF script would fail on the headset).

**J-45 · Review of the shared infrastructure: not ready.**

- Two blockers: (1) replacing `/run/fs.log` with a FIFO stops **both**
  deadline timers, because both log to `/run` before rebooting (FS-R-006
  §5D broken); (2) `fs-supervise` reads output until EAGAIN without
  checking the clock, so several fast writers starve the deadline and the
  report is wrong (seen natively, not under qemu, so the fixtures missed
  it). Plus: inherited fds and the controlling tty leak to the child;
  inherited ignored SIGCHLD/SIGALRM break the supervisor; surviving
  descendants unreported when `/proc` is hidden; **a fork failure kills
  busybox ash, so a PID-exhausting step could take PID 1 down (kernel
  panic, crash-dump mode)**; outcome rules misclassify tool faults and a
  missing pinned file. All sent back for fixing, with native-speed timing
  fixtures added.
- Verified sound: FSB1 binding and canonical base64; Python and
  PowerShell decoders agree on 159 new fuzz cases; the `misc` rule matches
  FS-R-006 §6.

**J-46 · kgate review rounds 4–5; threat model; display and infra
progress.**

- **kgate 2.2** (`7a8782c`): round 4 showed CRCs and exports were read from
  the non-loaded `.symtab`; 2.2 decodes the Image's allocated
  `__ksymtab*`/`__kcrctab*` (8-byte PREL32 on 4.19, 12-byte on 5.10).
  Round 5 forged vmlinux+Image together: a decoy table (the kernel finds
  tables via `__start/__stop___ksymtab`, kgate via section headers), an
  unsorted table (the loader binary-searches), and a redirected export
  address. Being fixed in 2.3 (kallsyms-anchored bounds, sortedness,
  address decode, committed profile by default).
- **Threat-model decision (Arbiter):** kgate catches mismatched,
  incomplete or wrong builds from our own build process and enforces
  acceptance, decoding what the loader uses where feasible. It is **not**
  the defence against a malicious builder forging binaries; that is build
  provenance: rebuild from the pinned source, toolchain and config, and
  require a bit-identical result. A reproducibility check is being added.
  To be stated to the Chair with the gate.
- **fs-pattern v0.4** (`0a78645`): 10 s cap; strict mode policy; 85/85.
- **Shared infra rev 2** (`3d4590e`, `05a2dd2`): review fixes; PID 1 now
  reboots by `exec` of `fs-reboot-final` (bootloader, then plain restart,
  then sleep forever; never exits). Fresh review running.
- **Host collector redesign, E1, PowerShell classifier, before/after
  lists:** in progress (`devices/quest3/host/`).

**J-47 · SteamOS 0.4 stable released; host collector built.**

- **Valve released SteamOS 0.4 for Steam Frame to all users (stable) on
  2026-10-08** (Steam news, app 4165890; beta 0.4.3–0.4.5 preceded it).
  The notes list power, streaming, dashboard, CEF and accessibility
  changes; no base-OS (glibc/systemd/kernel) details are given.
- **Decision (Arbiter, for the PM):** keep FS-A-007 on the pinned
  `20260922.6152327` files. Experiment (i) tests Valve's loader and glibc
  on the Quest kernel, and switching now would invalidate the pins,
  hashes, fixtures and reviews. In parallel: obtain a 0.4 stable image
  (the PM; same path as the 0.3 repair image), extract it, and diff the
  base packages (glibc, coreutils, systemd, kernel ABI tag). Adopt 0.4
  stable as the baseline for Stage 2 onward, per the stable-only release
  policy. If 0.4 changes glibc's minimum kernel or the T1 files' ABI, it
  is reported before any device use.
- **Availability (PM report, 2026-10-09):** SteamOS 0.4 is not yet downloadable as an image; the PM will fetch it when it is.
- **Host side** (`devices/quest3/host/`, `da0ad56`): collector redesign
  (D1 removed by construction: fixed verbs plus host hex tokens, one write
  site; raw capture with SHA-256; replay engine), E1 git checks (`.ps1` and
  POSIX `.sh`), outcome classifier, misc-rule port (matches Python on all
  cases), before/after command lists; 228/228 offline. Review running.

**J-48 · kgate 2.3; reproducible kernel builds; host review.**

- **kgate 2.3** (`4ab8e93`): decodes the Image's own kallsyms (formats from
  each tree's `scripts/kallsyms.c`) and requires the kernel's
  `__start/__stop___ksymtab*` and `__start___kcrctab*` to equal the
  decoded table bounds, each entry's address to equal its kallsyms
  address, strictly sorted tables, non-overlapping sections within
  `_edata`, and the pinned 38-section set. Committed profiles required by
  default. 170/170 fixtures; all 11 real builds PASS with the committed
  profiles and no committed-profile waiver (stock builds carry only the
  expected baseline waiver). The round-5 decoy, swap and redirect attacks
  are rejected.
  - Review loop paused here: a fresh adversarial review is run before any
    rebuilt-kernel proposal (the gate is not needed for FS-A-007, which
    uses the stock kernel). Forging kallsyms as well is outside the stated
    threat model.
- **Reproducibility [M-static]:** the Quest 2 v2.7 tree rebuilds
  **bit-identically** when the object-directory path and
  `KBUILD_BUILD_TIMESTAMP/USER/HOST/VERSION` are pinned (two pinned builds:
  vmlinux, Image, Image.gz, Module.symvers identical). The FS-A-006 builds
  pinned none of these, so they differ by 27 explained bytes (three GNU
  build-ids hashing the object path; cpio mtimes). Quest 3/3S (5.10) not
  yet measured. Future gate builds pin these.
- **Host review** (`da0ad56`): not ready. A blocker: the collector could
  send into an unverified state (bytes during the ack settle, or a
  `Password:`/pager tail before the first command). Also: E1 bypassable via
  `git replace`, clean filters, `core.fileMode`, unscrubbed git env;
  binary before/after captures corrupt when typed into PowerShell
  (256 → 519 bytes); unescaped device bytes on the console; a classifier
  `[int]` overflow. Being fixed.

**J-49 · Candidate images built; two design decisions.**

- **Images** (gitignored `build/`; builders and fixtures tracked, `cba8439`):
  stage2a `b8d5e207…e10be` (nonce `77809dbabbc11f51`), stage3a
  `0a907aca…775c7a` (nonce `c7e31c52882acbe3`). Kernel bytes identical to
  stock; only the ramdisk/signature size header fields differ, as in
  stage 1. Every input pinned (97-module list, vendor files, Valve files in
  builder and `T1-pins.json`, `elfpin.py` gate); E1 via
  `host/fs-gitcheck.sh`; BLAKE2 scan on the final image. Deadlines:
  stage2a T0+180 s (ack window 120 s); stage3a T0+60 s (ack window 40 s).
  Builder refusals 9/9 and 7/7; whole-image runs (the image's own `/init` as
  PID 1 under qemu in a sandbox, fake sysfs/configfs/reboot) 9/9 and 7/7,
  replayed end to end through `fs-collect.ps1 -Replay` and the classifier.
  The stage-1 `fail()` path now execs `fs-reboot-final` too. These images
  will be **rebuilt** once `host/` is final, then reviewed.
- **Decision: no software watchdog** in either image (FS-R-006 §5E). A
  software watchdog does not protect against kernel hangs; the SoC
  watchdog would need correct petting and adds a new failure mode.
  Protection is the PID 1 deadline, the `fs-reboot-final` exec path, the
  backstop, and the PM's manual recovery (expected, not guaranteed).
- **Decision: include the read-only inventory** promised in FS-A-006 §1/§5.1
  (`/proc/modules`, remoteproc name/state, `power_supply` uevents) in
  stage2a as an informational step that cannot change the outcome class
  (only its presence and `why` are recorded). Requires a coordinated
  change to OUTCOMES, the host classifier and the init.
- Open: `fs-display` verb and a stage-3a classifier on the host side.

**J-50 · Package reviews of FS-A-007 (round 6 fixes running); tag
corrections.**

- Three reviews at `cf251bb`:
  - **images:** sound to propose; no blocker. Fix: panels-off-on-close is
    source-derived ([D], v66 [O]; worst case powered until the PID 1
    reboot); a §6A thermal statement and the `inv` driver-I/O risk for
    stage2a; reproducible cpio; restore stage-1 behaviours changed without
    need; full hashes; recovery procedure.
  - **end to end:** a **blocker**: the only observer is stage 1's
    `host-observe.ps1`, which refuses the new MANIFESTs and, if adapted,
    sends its own ack; PID 1 records only the first ack, so the collector's
    ack fails and the one-shot attempt is burned (reproduced under qemu).
    Needs a stage-2a/3a observer that runs no session. Also: the ack window
    missing from the timing model; runner refusals not terminal;
    Android-landing branch in before/after.
  - **requirements trace (Chair role):** FS-A-007 must carry a recovery
    procedure, full hashes, the bundled PROJECT_SETUP/checklist/research
    notes, the watchdog decision reconciled with §6A, a thermal and
    governor case per hold, the `inv` risk, the display-reordering ask
    with the PM's observation disclosed as a PM report, the T1 provenance
    (filename build vs BUILD_ID; rc channel; 0.4 plan), and tag fixes.
- **Tag corrections (this entry):** PM sightings are **PM reports**, not
  [M] (J-41's "saw nothing on the panels", J-43's "recovery lights the
  panels"); "confirmed to produce an image" withdrawn (recovery's minui
  path working does not show our route works). J-49's image hashes and
  180/60 s deadlines are superseded (260/170 s, J-48/`cf251bb`; final
  hashes after round 6).
- PROJECT_SETUP §6A.1 now states that FS-A-007's short, attended holds fall
  under the bounded-hold rule, with no software watchdog.

**J-51 · FS-A-007 ready for the PM to send.**

- Fix rounds 6 and 7, then a final Chair-role review (would concur with
  both trials and the reordering once fixed). Its fixes: a private
  `FS-A-007-image.zip` with both images and our three binaries (blocker:
  FS-R-006 §7 "the exact image"); thermal wording (no thermal-zone drivers
  in these boots, so the DT CPU maps are inactive; `pwm-tach-fan.ko`
  loaded but not commanded, fan state [O]; PROJECT_SETUP §6A.3 carve-out
  for short, attended holds); a per-phase read-only capture tool
  (withheld); a
  single-operator display protocol (cue, high beep, 10 s dark check, low
  beep; stage 3a uses 2 status polls to fit the budget); an FS-R-005
  trace; the stage-1 `fs-proto.ps1` bundled (hash equals the FS-R-004
  reviewed copy). A verification pass confirmed the fixes; remaining text
  items applied.
- Images unchanged since round 6: stage2a `e8775c89…51e5`, stage3a
  `d2bb28f7…cc23`. Host suite 385/385; `check-timing.py` CONSISTENT.
- `captures/` is gitignored (device data; bundled explicitly when a trial
  is reported).

**J-52 · FS-A-007 sent.**

- The PM relayed FS-A-007 (private review record) with `FS-A-007-raw.zip`
  (SHA-256 `f5e2ad183a26f6ebc9843902dca0f2d3e71ff27c0bcdfb8440826628dfff8d84`)
  and the private `FS-A-007-image.zip`
  (`80c2521a896a05bd06505e58bf0f1fbbc19155154a2895e80d9105905be0b4ec`).
  Awaiting FS-R-007. No device action until the ruling, the PM present,
  and the PM's own nonce entry.

**J-53 · FS-R-007: images accepted; live concurrence held for a host
timing fix (B1) and exposure wording (C1).**

- Ruling recorded verbatim (FS-R-007 (private review record)). The Chair independently
  verified both images (594/594 and 5/5 manifest entries; kernel bytes
  equal stage 1's; ramdisks parsed file by file; Valve pins; native
  fs-supervise and fs-pattern checks). **Concurs with the reordering**
  and with the persistent-state rules; notes the decisions. No
  rebuilt-kernel concurrence.
- **B1 (host only):** the host's guarantee "Th precedes T0" is
  unsupported: a successful `fastboot boot` return can be timestamped after
  PID 1 starts (Chair's counterexample: stage 3a runner could run past the
  device deadline). Also, the collector computed its remaining budget
  before gadget discovery and transport construction, so preparation time
  inflated the budget. Fix: BootStartUtc as the origin for every handoff;
  absolute deadlines converted to the transport's clock after preparation;
  a fresh remaining-budget check before the runner. Regression fixtures
  required. Images and nonces unchanged.
- **C1 (wording):** "panels lit at most 10/15 s" overstated. Corrected in
  stage3a IMAGE.md and README, PROJECT_SETUP §6A and the display note: the
  client hold is 10 s (alarm at 15 s); closing does not prove v66 turns
  the panels or backlight off [O]; the frame may persist until recovery;
  T0 + 170/171 s are intended reboot times, not guaranteed panel-off times.
  The on-device `init.sh` comment ("black") is recorded as errata. New
  `devices/quest3/SIGNOFF.md` puts the retained-frame exposure into the
  PM's sign-off.
- **Return package** (narrow, FS-A-008): corrected observer/collector,
  regression outputs, timing explanation, exposure wording.

**J-54 · Thermal and fan control design (task 4, first draft).**

- `docs/research/thermal-control-design.md` (agent draft; adversarial
  review pending). Key findings [M-static, Meta source/DTB]:
  - the DT CPU cooling maps reach **state 1 only** (one frequency step:
    ≈2.36→2.21 GHz, 2.05→1.92 GHz); **no DT map targets the GPU**, the 110 °C
    CPU trips, the 95 °C GPU trips or DDR (settles FS-R-006 §4's GPU
    question at the DT level: a devfreq cooling device exists, no zone binds
    it);
  - the only kernel `critical` trips are the PMIC temp-alarm zones (145 °C),
    present only if that module is loaded;
  - **the v66 fan driver stops the fan on blank** and defers thermal
    requests while the display is off (public v66-era source, near match
    to Unit 1's build); v2.7 caps at `silent_rpm` instead (J-39 applies to
    v2.7 only);
  - virtual sensors return the last value (initially 0) when an input
    fails, so a dead input can look plausible;
  - the `usb-conn` 60 °C trip disables USB-C CC (cuts our channel);
  - temp-alarm stage-2 override applies only to GEN1 and first-revision
    GEN2 alarm types; which of the 8 PMIC instances are which is [O];
  - `cpufreq.default_governor=performance` comes from the vendor_boot DTB
    bootargs.
  - Android thresholds (v2.7 thermal JSON): battery 58/61/63/65 °C, skin
    48/50/52/60 °C, SoC 89/92/95/115 °C, USB 70 °C.
- **Relevance to FS-A-007 trial (iii) on Unit 1 (v66):** if fs-pattern's
  close blanks the panel, the v66 fan driver would stop the fan for the
  rest of the hold (≤ T0 + 171 s, idle). The fan state was already [O] and
  not commanded; disclose in FS-A-008. Not a reason to change the image
  (FS-R-007 §4: no new thermal-stack change for the first experiment).
- Design proposes: schedutil + caps at boot (CPU 1.92 GHz, GPU 545 MHz), a
  fan policy with tach-failure checks, not loading temp-alarm until a
  read-only PMIC-type probe settles it, and a fail-safe `fs-thermald`;
  attended validation trials T0–T6. T0 needs read-only Android probes and a
  debugfs read: a future relay item, not run.

**J-55 · Trial order (PM).** Once FS-R-008 grants live concurrence, trial
(i) (stage 2a, Valve files) runs first, then trial (iii) (stage 3a,
display) after (i)'s comparisons complete with no STOP — matching the
Chair's stated preference (FS-R-007 §5 ask 3). Fan policy for future
images (temperature-driven; screen-off quiet cap that yields to
temperature; fan off only in suspend, no suspend while hot; tach-failure
throttle/shutdown) proposed to the PM, pending their confirmation.

**J-56 · Fan policy recorded (PM); FS-A-008 ready.**

- **Fan policy (PM, 2026-10-09):** cooling follows temperature, not screen
  state. Screen on: the device's own Meta zones. Screen off: still
  temperature-driven, an optional quiet cap that **yields** to
  temperature, optional throttling. Suspend: fan off, no suspend while hot.
  Always: tach-failure and stale-sensor fail-safe (throttle, then orderly
  shutdown). **Per device:** each port copies its own device's Meta policy
  from its own firmware and DT; the Quest 3S is not the Quest 3 and the
  Quest Pro is not the Quest 2 (PM). Where a stock driver stops the fan on
  blank, our port replaces that. Valve's Frame fan control is not used on
  Quests. Recorded in PROJECT_SETUP §6A.3, checklist B4/B7.
- **FS-A-008** (return package for FS-R-007): B1 fix reviewed (closed; nits
  applied: future origin refused, T9); a Chair-role review of the relay
  found no blocker; its fixes applied (a leftover C1 claim in
  RECOVERY.md; full `init.sh` errata; the v66 fan disclosure carried into
  PROJECT_SETUP and the sign-off sheet; harness-run provenance; tag split).

**J-57 · FS-A-008 sent.** The PM relayed FS-A-008 (private review record) with
`FS-A-008-raw.zip` (SHA-256
`bbbb7dfd994448e92c1c70a561a0cf1afb824b828e67a37af98cd73b88f03413`).
Awaiting FS-R-008. Trial-day practice (PM): the steps are given **one at a
time** as the trial proceeds, not as one block.

**J-58 · FS-R-008: B1 and C1 CLOSED; CONCUR with trial (i) and,
separately, trial (iii).**

- Ruling recorded verbatim (FS-R-008 (private review record)). Live scope: Unit 1
  only, v66 build 50105190000000511, slot A, stock kernel/DT/firmware;
  temporary boot, no flash, one attempt per trial, no retry. Images and
  nonces as FS-R-007 §1; reviewed host hashes `fs-observe.ps1`
  `b939640d…834a`, `fs-collect.ps1` `3a8d7775…8776` (checked equal in the
  working tree, 2026-10-09). Neither nonce used (no ledger yet).
- Order: (i), recovery and comparisons, then (iii) only with no STOP and a
  fresh baseline; each with its own PM sign-off and nonce.
- Editorial fixes applied (do not touch the reviewed host scripts):
  COLLECTOR.md "handoff" → "BootStartUtc"; SIGNOFF.md "removing the
  headset from the eyes does not stop execution"; the Unit 1 fan
  near-match inference tagged [C].
- Next relay: actual attempt logs, identities, raw captures,
  classifications, separate optical/dark observations, recovery outcome,
  battery/temperature readings, persistent-state comparisons; PASS / FAIL
  / INCONCLUSIVE without substituting evidence categories.

**J-59 · Trial (i) run (stage 2a, nonce <attempt nonce withheld>), 2026-10-09.**

- **Deviation:** the PM ran it **remotely, not physically present at the
  headset** (stated after the command was entered; FS-R-007/008 require the
  PM present). No intervention was needed; to be reported to the Chair.
- BA OK (100 %, 23.0 °C, slot `_a`, build `…0511`, kernel
  `5.10.198-01402-g1c5986fe21ee`); BF OK. BootStartUtc 18:22:27.27Z;
  `fastboot boot` HANDOFF_ACKNOWLEDGED, Th 18:22:38.50Z; gadget on COM8 at
  Th + 13 s (a WRONG-serial variant `FS-93A1501F0B1FB692` was seen first and
  ignored); collector: COLLECTED-VALID, FSB1 VALID, `fs-done` acknowledged
  (`FSD1 queued`), exit 10; back in fastboot.
- **Classification (pre-registered rules): stage-1 class PASS; OUTCOME
  COMPATIBILITY FAIL**, lowest failing step 4 `list`: "not exactly 3
  terminated lines". Steps 1 `hash` and 2 `absent` MEASURED clean; 3 `diag`,
  5 `uname`, 6 `b2kat`, 7 `b2chal` OK; 8 `inv` INFO.
  - [M] Valve's `uname` printed `5.10.198-01402-g1c5986fe21ee`; Valve's
    `b2sum` gave the empty-input KAT and **BLAKE2b-512 of
    `<attempt nonce withheld>:c59a60eb2c479d5ceaa48612d91d36c5` =
    `a28b0404…d006`**, recomputed independently on the host.
  - [M] step 4's `ld.so --list` printed 4 lines; the extra first line is an
    entry with an empty name and only an address (`(0x0000007fb78d0000)`);
    libc and the loader resolved to `/valve/lib/…`; exit 0. That it is the
    main program's own map entry, absent under qemu, is [C]. The rule is
    reported as it stands; no re-grade.
- **After:** AF slot state identical to BF; `getvar all` differs only in
  battery voltage (4360 → 4356 mV). AA OK. Partition hashes identical except
  `misc`; **misc rule RECORDED** (boot command `E1` unchanged; vendor words
  `0x1010–0x101b` changed, presumed reboot-related as in the stock control);
  persistent-state comparison identical (method private); slot, fingerprint,
  kernel identical [paraphrased for publication]. Boot reason after: `bootloader`.
- **Battery: 23.0 → 34.0 °C** (AA10, after Android boot, on AC, 100 %).
  That is > +5 °C, so the **cooling rule applies** (RECOVERY.md §4) before
  any further step. The cause (trial vs Android boot and charging) is [O].

**J-60 · Trial (i) report reviewed; root cause of the step-4 line.**

- Root cause [D, offline source and disassembly analysis;
  FS-A-009 (private review record), `listing-evidence/`]: the
  extra line is the **main program's own map**; glibc 2.39 prints it when
  an uninitialised flag (`mode_trace_program`, set only from
  `LD_TRACE_LOADED_OBJECTS`) happens to be true on the `--list` path, so it
  appears nondeterministically. Reproduced under qemu with `-cpu
  cortex-a72` (logged rerun: 11/15 runs for `b2sum`, 7/15 for `uname`). **Corrects J-59**, which tagged the cause [C]
  and said the line was "absent under qemu" (it is absent only with qemu's
  default CPU model, 0/30).
- The "exactly 3 lines" rule is judged defective [D]; FS-A-009 asks the
  Chair to rule on how to record the run and on a corrected rule.
- **Deviation re-assessed:** the PM's remote run breached the FS-A-007
  §5.5 start gate ("the PM is absent"), and the thermal basis lacked its
  attendance component. The Arbiter also failed to ask for explicit
  confirmation of physical presence before giving step 5. **Corrective
  rule:** the attempt step is given only after the PM confirms in chat
  that they are physically at the headset; the completed sign-off sheet is
  filed with the attempt log. FS-A-009 asks the Chair to rule on
  admissibility.
- Cooling record: 28.0 °C at 19:11:37Z (from 34.0 °C at AA).

**J-61 · PM statement on trial (i).** The PM ticked the sign-off sheet
after the attempt, and states: "I accepted the risk of not being present
and made an executive decision as PM. My override should be enough."
Recorded in FS-A-009 §1; the admissibility question still goes to the
Chair (the scope it concurred with required presence). The presence gate
(J-60) stands for future attempts.

**J-62 · FS-A-009 sent** with `FS-A-009-raw.zip` (`dfc6c2d2b3e3031d03062477b593eeaede79564c1072e88bc020f9d0bf6a2527`). Awaiting FS-R-009 (listing rule, admissibility, trial (iii)).

**J-63 · FS-R-009; thermal rulings (PM).**

- **FS-R-009** (verbatim, FS-R-009 (private review record)): trial (i) **admissible
  with the deviation recorded**; registered outcome **COMPATIBILITY FAIL,
  step 4 (listing-rule defect)** retained (option 1a; rule 8 is not a
  conversion mechanism); no promotion to PASS under a later rule. The
  loader explanation is supported (glibc commit and disassembly checked
  independently). Future listing rule: **amended A** (optional first
  address-only line, nonzero and distinct; **no "below the loader"
  condition**, which the qemu log contradicts in nine cases); option B
  rejected. A registered stage-2a PASS needs a separate attempt with a
  fresh nonce (optional, not a prerequisite). **Trial (iii): CONCUR**,
  after the cooling hold, fresh BA/BF, pre-attempt sign-off, PM physically
  present.
- **Wording corrections from FS-R-009 §5:** "no ADSP running" narrowed to
  what was measured (empty remoteproc enumeration; ADSP driver link
  absent); the cause of the temperature rise stays [O] (do not attribute
  it to charging or bootloader dwell); the image lifetime was not measured
  as 30 s (`fs-done` queued about 35 s after command launch); the readable
  gauge is a finding, not proof of reliable thermal protection.
- **Thermal rulings (PM, 2026-10-09):** P1–P10 accepted; P11 rejected
  (start at Meta's L4, 1.92 GHz / 545 MHz). All to be revisited before the
  first public release (PM). Recorded in PROJECT_SETUP §6A.3 and the
  design §0.1.

**J-64 · Listing rule v2A ready on a branch (merge after trial (iii)).**

- Branch `listing-rule-fix` (`eb541e2`, tip `6441b07`): `fs-classify.ps1`
  step-4 rule versioned. v1 (registered) for trial (i)'s nonce and
  **locked** there (`-ListRule v2A` refused, FS-R-009 §3: no promotion to
  PASS); v2A (amended A, FS-R-009 §4) for all new runs; unknown rule name
  refused. OUTCOMES rev 5; T1-PINS §3; LISTING-RULE-A.md; option B marked
  not adopted. Fixtures: section L 58 checks incl. device output, qemu
  cases on both sides of the loader, 33 negatives, the registered-run lock;
  host suite 456/456 from a clean export. Adversarial review: one gap (the
  manual override could print PASS for trial (i)), fixed.
- **Not merged:** trial (iii) is classified with the reviewed
  `fs-classify.ps1` (`762579e0…`); the branch is merged after it.
- Quest 2 port plan committed (`4ffe334`); awaiting the PM's answers on the v59
  artifact source and a schedutil switch at boot.

**J-65 · Quest 3 kernel reproducibility (task 2).**

- [M-static, `tools/kgate/validation/reproducibility-quest3.txt`] The Quest
  3 v2.7 (5.10) tree is **not** bit-reproducible with the Quest 2 method
  (same object path, pinned `KBUILD_BUILD_TIMESTAMP/USER/HOST/VERSION`):
  two builds with ASLR on differ in 25.3 MB of the Image (Module.symvers and
  all 272 `.ko` identical). With **every make under `setarch x86_64 -R`
  (ASLR off)**, two builds are **bit-identical** (vmlinux `1d855c2c…`, Image
  `fbfb86f4…`, Module.symvers `7b5cfa8f…`, all 272 `.ko`).
- Cause [D]: the stock config has `CONFIG_META_SAMPLE_PGO=y`
  (`-fprofile-sample-use=vmlinux.profdata`); in clang r450784e the attached
  profile counts depend on memory addresses, so 8 of 4,696 objects differ
  between runs; that changes inlining, and full LTO shifts the whole
  layout. Confirmed per file (printk.o: 7 distinct outputs in 20 runs with
  ASLR, 1 without ASLR or without the profile). The Quest 2 4.19 tree has
  no sample PGO.
- Every run matched the gate: `module_layout 0xb1f01218`, 2601/2601
  vendor-required CRCs, all 14,059 vmlinux CRC pairs equal the FS-A-006
  build.
- **Rule for future gate builds:** same object path, the four pins, and
  `setarch -R` for the whole build. The FS-A-006 build (unpinned, ASLR on)
  cannot be matched bit for bit. Untested: other paths or hosts.

**J-66 · v2.7 for real, not a hybrid (PM).**

- **PM direction:** the Quest 2 (and Quest 3) work targets **v2.7 only**,
  for compatibility with the latest firmware; v59 is too rare to target.
  The Quest 2 port plan is refocused on v2.7.
- **Why a v2.7 boot image on a v59 unit is a hybrid** [D]: `fastboot boot`
  replaces only the kernel, the DT in the boot image and our ramdisk for
  one boot; the boot chain (xbl, abl, tz, hyp, aop), co-processor firmware,
  DTBO and vendor partitions stay as installed. FS-A-006 §3A already named
  this hybrid as needing analysis.
- [removed for publication]
- **Quest 2 governor (PM):** PID 1 switches to `schedutil` at boot.

**J-67 · [removed for publication]**

**J-68 · Quest 2 port plan revision 2 (v2.7 only).**

- `devices/quest2/PORT-PLAN.md` rev 2 + `analysis/v27-stage1/` (agent;
  unreviewed). [M-static] the v2.7 boot and dtbo hashes match the OTA's
  vbmeta; boot header v2, raw kernel, 3-blob DTB; stage 1 keeps kernel and
  DTB byte-identical and swaps a **gzip** ramdisk (`RD_GZIP=y`, LZ4 off).
  No modules needed: gadget, display, fan, thermal, charger and watchdog
  are built in.
- **USB channel:** NCM gadget (config:3630) with IPv6 link-local (or IPv4
  + `udhcpd`), records FSV1/FSA1/FSS1/FSB1 unchanged, one per TCP
  connection; Windows `usbncm` binding and busybox `nc -l -e` behaviour
  untested [O].
- Hardware watchdog on by default and petted by a kernel thread; PID 1 must
  **never open `/dev/watchdog`** (softdog could not be stopped). 4.19 has
  no default-governor boot parameter → PID 1 sets `schedutil` (PM). Panic
  reboots immediately (`PANIC_TIMEOUT=-1`). The fan driver waits for a
  panel; quiet speed 0.
- Unit binding: compare the unit's `ro.boot.vbmeta.digest`
  with the computed `91b7f93d…` [D, own script; to cross-check with
  avbtool].
- **Open decision (for the Chair, before Q2-P2):** how to capture misc
  before/after on v2.7. Options to propose: `fastboot fetch` if the ABL
  supports it [O], or our own PID 1 reading misc read-only during the
  trial boot. The same applies to a Quest 3 on v2.7.

**J-69 · PM decisions and facts on the v2.7 move.**

- **Firmware ceiling (PM):** v2.7 is the target; do **not** move to builds
  newer than v2.7.
- **Slots (PM report):** a manual slot switch does not boot properly
  [PM report; mechanism O].
- **Quest 3 Unit 2 hardware fault (PM report):** a **faulty IPD slider**
  that has caused issues on newer firmware; it may matter for SteamOS
  (IPD sensing, lens-distance handling). To be added to the Unit 2
  baseline and the device checklist before Unit 2 is used.
- **PM question: write only the boot chain, omitting the userspace?**
  Arbiter answer: no. (a) Writing boot-chain partitions is forbidden by
  FS-R-001 (do-not 3) and would need the Chair to revisit it; (b) a
  SteamOS image still needs v2.7 vendor firmware, vendor modules and DT
  from the logical/vendor partitions, so a boot-chain-only change would be
  a new hybrid; (c) the boot chain is where bricks happen.

**J-70 · [removed for publication]**

**J-71 · [removed for publication]**

**J-72 · Quest 2 USB network channel built offline (agent; unreviewed).**

- `devices/quest2/channel/` (README first). Offline fixtures: device side
  28/28, host side 71/71. **Nothing has run on a headset.** The Quest 3
  trial tools are unchanged; their hashes still match FS-R-008 and the
  reviewed classifier.
- **Addressing:** IPv6 link-local `fe80::<nonce>/64`; the 64-bit nonce is
  the interface identifier. No DHCP, no IPv4. Duplicate-address detection
  is disabled through settings (busybox `ip` has no `nodad`). Fallback:
  fixed `169.254.x.y`.
- **Responder:** a static C program `fs-rpcd` replaces busybox `nc -e`.
  - Under qemu, `nc` listened on every interface, spawned a shell per
    connection and reset a second client.
  - `fs-rpcd` binds one address, serves one connection at a time, allows
    3 s and 64 characters per request, and never runs a shell. Its only
    exec is the fixed collect runner.
  - Build: `src/fs-rpcd.c` sha256 `09a5710b…`, binary `7c819fa1…` (AOSP
    clang r450784e, static, bit-identical rebuild; `build/BUILD.txt`).
- **Requests:** lowercase Quest 3 names, each carrying the nonce
  (`fs-verify`, `fs-ack`, `fs-status`, `fs-done`, `fs-collect`). This
  departs from the port plan's uppercase verbs. A stale image or the wrong
  unit returns a refusal record; replays are refused.
- **Host side:** `host/fs-transport-tcp.ps1`, a single send site, a
  stop-on-doubt check before each request, raw responses kept with
  SHA-256, deadlines from BootStartUtc.
- **Found and fixed during the build:**
  - the responder accepted a trailing NUL byte;
  - the WSL relay loses responses after a half-close, so the transport
    never half-closes.
- **Open [O]:**
  - Windows `usbncm` binding to the 4.19 NCM gadget;
  - the v2.7 USB controller name and role switch;
  - link-local addressing and Windows Firewall on the real gadget;
  - the adapter MAC;
  - 4.19-specific behaviour (fixtures ran on WSL 6.18);
  - Quest 2 timer values and the collector.
- **Adversarial review:** started; required before any relay.
- **Side effect:** the agent's first run rewrote the gitignored
  `devices/quest3/common/tools/__pycache__/fsb1.cpython-314.pyc` (same
  source and Python version). No tracked file changed.
- **Adversarial review of `e0d364f`** (read-only; it rebuilt the binary
  bit-identically and checked the hashes, address derivation, 4.19
  sources, timing and send discipline):
  - **2 MAJOR:**
    - the build's "no shell string" gate cannot fire (SIGPIPE under
      `pipefail`), and the binary does contain `/bin/sh` from static
      glibc, so the BUILD.txt claim is false;
    - the runner reap after SIGKILL is unbounded, so a stuck runner would
      hang the responder until DEADLINE.
  - **11 MINOR:**
    - signal state inherited by the responder and runner;
    - a second line arriving in a later segment is drained, not refused;
    - wildcard binds are accepted;
    - collect-once and replay state are kept in memory only;
    - RPC_READY is recorded without checking the responder listens;
    - the host send gate is not re-checked immediately before the write;
    - the host API's adapter and deadline bindings are weak;
    - the reference flow counts an FSR1 as COLLECTED;
    - README overclaims;
    - fixture gaps (most device cases half-close, unlike the real host);
    - three undisclosed PORT-PLAN departures.
  - Fixes delegated to the build agent; a re-review follows.
- **Revision 2 (fixes):** all 13 addressed (10 fixed; m6/m11 fixed in
  part and reworded in part; m13 reworded). Highlights:
  - build gates now capture output before checking; BUILD.txt states that
    the `/bin/sh` string comes from static glibc and that `fs-rpcd` code
    calls only `execve` (checked from its undefined-symbol list);
  - the reap is fully non-blocking: 2 s poll, SIGKILL, 2 s poll, then
    `runner-unreaped`;
  - signals and mask reset; umask 077; a 75 ms trailing-byte window;
    wildcard binds refused; an `fs.collect-started` O_EXCL marker;
    RPC_READY only after the responder's own listening line;
  - the host time gate is re-checked just before the write; adapter-bound
    scope; one-shot deadlines; mandatory start refusal and runner guard;
    FSB1 required for COLLECTED.
  - Extra bug found: exactly 8 MiB of runner output was refused.
  - Hashes: `fs-rpcd.c` `654db098…`, binary `5c1357f2…` (bit-identical
    rebuild), `fs-ncm.sh` `41f2b388…`, `fs-transport-tcp.ps1` `ea91128c…`.
  - Fixtures: device sections 36/36 (D-qemu 101/101, D-asan 101/101,
    D-native 102/102, G 22/22, L 6/6, I 5/5), host 79/79. The old source
    fails the new cases (89/97).
  - The D-state runner is simulated with a `waitpid` shim [O on real
    hardware]. The replay table is still kept in memory only (disclosed).
  - Re-review started.
- **Re-review of `a0ab780`:**
  - **Status:** 9 of 13 closed. M2, m7, m9 and m11 partly closed. The
    reviewer's own rebuild matches the binary hash, and crafted inputs
    confirm the build gates fire.
  - **New: 2 MINOR.**
    - N1: the responder is not killed when `fs_rpc_start` fails, so it
      could serve during `fail()`'s wait.
    - N2: the exec gate misses `syscall(SYS_execve, …)`; the fix is to make
      it an allowlist.
  - **Residuals:**
    - phase-2 kills are reported as `runner-unreaped`;
    - the runner guard is not tied to the device runner limit;
    - the README status line is stale;
    - a `setsid` stray survives the process-group kill.
  - No BLOCKER or MAJOR remains. Revision 3 delegated.
- **Revision 3:** all six items fixed in code.
  - N1: the responder is SIGKILLed and reaped before every `fail()` in
    `fs_rpc_start`, with liveness read from `/proc` stat. The host refuses
    an FSV1 whose stages contain `ERROR_`.
  - N2: the exec gate is now a symbol allowlist
    (`tools/fs-rpcd.undef.allow`, `undef-gate.sh`); crafted variants
    (`syscall(SYS_execve)`, `system`, `popen`, `execvp`, `posix_spawn`,
    `dlopen`) are rejected, 9/9.
  - Phase-2 kills now report `runner-killed`.
  - The host runner guard is derived from the image's `-T`:
    RunnerTimeoutMs = T + 39.075 s, RunnerWorstMs = that + 5 s.
  - The README status line is fixed.
  - Child subreaper plus a bounded `/proc` sweep kills `setsid` strays
    (X6, X7).
  - Hashes: `fs-rpcd.c` `5bd7d10d…`, binary `77b24f9f…` (bit-identical
    rebuild), `fs-ncm.sh` `116d938f…`, `fs-transport-tcp.ps1` `00fc87c9…`.
  - Fixtures: device 37/37 sections (D-qemu 103, D-asan 103, D-native 104,
    G 23, L 6, I 5), host 90/90, build gate 9/9. The `a0ab780` source
    fails exactly the new X3, X6 and X7 cases.
  - Final re-review started.
- **Final re-review of `58817ec`:**
  - **Closed:** N1, N2 and the M2/m9/m11 residuals. The reviewer's
    rebuild matches the binary hash, and the sweep is confirmed
    descendants-only, non-blocking and race-free.
  - **Reviewer's view:** ready for the Chair as offline work.
  - **4 MINOR:**
    - R1: the ERROR_ marker can be lost to the 200-byte truncation, and
      `-ReadyStage` is optional;
    - R2: the build gates can be bypassed by source edits (inline `svc`,
      a function-pointer execve, an edited allowlist), so they are defence
      in depth on top of source review;
    - R3: the `-T` 240 s cap can never be used; a Quest 2 timing check is
      needed;
    - R4: a wording nit.
  - Revision 4 delegated.
- **Revision 4:** R1–R3 fixed in code, R4 reworded.
  - Truncated fields are marked with a trailing `+` (data `+` becomes
    `?`). The host refuses truncated or `ERROR_` stages in FSV1 and FSS1.
    `-ReadyStage` is mandatory live, and the transport stops by itself on
    these.
  - New `src-gate.sh` (asm/svc/exec-family tokens). `undef-gate.sh` checks
    a pinned allowlist sha256, requires exactly one direct-call `execve`
    relocation, and rejects svc/hvc/smc in the object.
  - New `check-timing.py`: max T = DEADLINE − 194.075 s (104 s at
    299 s). The cap was lowered from 240 to 104 and is enforced in the
    build.
  - Hashes: `fs-rpcd.c` `d2711be2…`, binary `6ccb0fcc…` (bit-identical),
    `fs-transport-tcp.ps1` `7b642903…`.
  - Fixtures: device 37/37 (D-qemu 111, D-asan 111, D-native 112), host
    97/97, build gate 14/14, timing CONSISTENT.
  - A verification pass of rev 4 follows before FS-A-010.
- **Verification pass of `e6e5cf0`:**
  - R1, R3 and R4 closed. The binary rebuild matches. The truncation
    marker and host refusals behave as claimed (ASan clean).
    `check-timing.py` reads its inputs from the sources, and the 104 s cap
    is the same in all four places.
  - R2 partly closed. **V1 (MINOR):** a token-pasted `asm` emitting
    `.word 0xd4000001` (a raw `svc`) passes both gates, because objdump
    shows it as data.
  - V2: a wording point; the relocation check limits call sites, not
    arguments.
  - Nits: an all-separator cut field loses its `+` marker; the `+`→`?`
    rule also applies to the kernel release.
  - Reviewer: ready for the Chair as offline work. Revision 5 (raw-word
    svc scan, `##`/`_Pragma` ban, nits) delegated.
- **Revision 5:** V1 and N-a fixed in code; V2 and N-b reworded.
  - New `tools/obj-scan.py` scans the raw code words for svc/hvc/smc (any
    immediate). It refuses `$d` in code, and refuses code-named sections
    that are not executable. The builder found a second bypass that needs
    no asm: a `section(".text")` constant is merged into executable
    `.text` by lld.
  - `src-gate.sh` bans `##` and `_Pragma`.
  - `join_field` returns `-+` for an empty cut field.
  - Hashes: `fs-rpcd.c` `df75cd26…`, binary `da8626c3…` (bit-identical).
  - Fixtures: device 37/37 (D-qemu 113, D-asan 113, D-native 114), host
    98/98, build gate 21/21, timing CONSISTENT.
  - A narrow check of the rev 5 gate changes was requested.
- **Narrow check of `9758eda`:**
  - V2, N-a and N-b closed. The rebuild matches.
  - V1 partly closed. A line-spliced `asm` with
    `.reloc ., R_AARCH64_ABS32, 0xd4000001` over a `nop` passes every
    gate: the linker writes `svc #0`.
  - `obj-scan.py` reports OK on four malformed-ELF shapes, which only a
    broken toolchain could produce.
  - Nit: about 1.5 KiB of `.rodata` shares the executable page.
  - Reviewer: ready for the Chair. **Revision 6 is the final gate pass**:
    a relocation-type allowlist for code, token checks on preprocessed
    output, a fail-closed ELF parser, and `-z separate-code`. The gates
    remain defence in depth; source review is the control.
- **Revision 6 (final gate pass):** `fs-rpcd.c` is unchanged
  (`df75cd26…`).
  - `obj-scan.py` checks relocations into `.text` against an
    instruction-relocation allowlist, and each one must sit on a word of
    its own instruction class (this closes `.reloc` ABS/PREL and crafted
    ADRP tricks).
  - The ELF parser fails closed (m1–m11 exit 2).
  - `src-gate.sh` also checks `clang -E` output and refuses splices,
    trigraphs and digraphs.
  - The link uses `-z separate-code`, so no non-code bytes share an
    executable page (`seg-check.py`).
  - Binary `da19367b…` (680,968 B), bit-identical across two builds.
  - Fixtures: device 37/37, host 98/98, build gate 43/43, timing
    CONSISTENT.
  - **Gate iteration stops here.** Residual, stated in BUILD.txt: a
    determined source editor with control of the toolchain can defeat any
    static gate; source review is the control. Rev 6 is covered by the
    FS-A-010 package review.
- **Relay plan (Arbiter):** no relay is needed for this alone. The channel
  rolls into the next open relay, FS-A-010 (the trial (iii) report), as
  offline work for the Chair.

**J-73 · Trial (iii) executed (stage 3a display test), PM physically
present.**

- Evidence: FS-A-010 (private review record)
  - `attempt-log.md`;
  - `signoff-as-signed.md`;
  - `analysis-initial.md`;
  - `captures/`, `observe/`;
  - `fsp1-decoded-partial.txt`;
  - `EVIDENCE.sha256`.
- **Presence gate met.** The PM stated physical presence and ability to do
  the manual recovery before the attempt command was given. The sheet was
  signed (re-timed) after `PHASE BF OK`. The PM had ticked all lines in
  advance; times were written in local time, not UTC. [paraphrased for publication]
- **Registered outcome:**
  - STAGE-1 CLASS **PASS**; OUTCOME **INCONCLUSIVE** (OUTCOMES §8 rule 2,
    FSB1 line-count);
  - the collector reported COLLECTED-REJECTED; fs-done was acknowledged
    and the device recovered to fastboot by itself.
- **Cause of the rejection [M]:** about 1 KB (12 DATA lines) was lost in
  the serial transfer, right after the host's first 12 289-byte read.
  Where the bytes were dropped is [O].
- **Display program records:** 66 of 69 FSP1 records pass their own
  crc32; the 3 lost or damaged are mode-list entries. They show:
  - the modeset commit (split, modeset) was accepted, rc=0 in 657 ms;
  - the frame was held 10 s; close rc 0; `shown=1`.
- **Optical (PM):**
  - no image in either eye; black throughout;
  - the panels went dark the moment `fastboot boot` ran and relit only
    back in fastboot.
- **Reading:** the handoff assumption (ABL continuous splash keeps the
  panels lit) is contradicted [D]. Candidates are listed in
  `analysis-initial.md` [O].
- **Persistent state:** AF01–09 = BF01–09; AF10 differs only in battery
  voltage; misc RECORDED (same vendor words); persistent-state comparison identical [paraphrased for publication]; slot A.
- **Temperature: 30.0 → 44.0 → 45.0 °C (rising).** The PM powered off and
  was asked to unplug, because off-mode charging adds heat. Cause [O];
  long bootloader dwells (about 14 min before, up to about 9 min after)
  are a candidate. Streamlining the prerequisites is a safety item too
  (PM request).
- **Next:**
  - offline investigation of the display handoff and backlight;
  - a fix design for the serial loss;
  - a pattern preview image for the PM;
  - then FS-A-010.
- **Serial loss analysis** (`docs/research/serial-loss-trial3.md`, agent,
  offline):
  - **Exactly 1 024 bytes were lost** [D]: 13 + 11 × 89 + 32. That is one
    SuperSpeed bulk packet.
  - The first read of 12 289 bytes = the lone `
` from
    `fsb1-enc.sh:97` + 12 × 1 024, so it is the host driver's queue cap,
    not a buffer size. The 4 MB `ReadBufferSize` is evidently ignored [D].
  - The device tty path and `u_serial` cannot drop on a full buffer
    [M-static]. The one device-side path, an errored request not being
    resent (`u_serial.c:464-488`), is [O].
  - Most consistent explanation: Windows `usbser.sys` dropped a packet
    while its queue sat at the cap [D/C; SEGGER, OSR field reports].
  - **Fix, ranked:**
    1. pace `fsb1_emit` on the device (about 10 lines every 100 ms;
       record bytes and hash unchanged; about 2–3 s per record, to be added
       to DEADLINE and `RunnerWorstSec`; a new image);
    2. host-side logging only;
    3. chunked ACK/retransmit: not recommended (needs a Chair decision).
  - **To pin the cause:** a host USB capture (USBPcap, a download, so the
    PM's decision), or read-only `dmesg | grep -i unexpected` plus
    `current_speed` on the device right after a burst.
  - The Quest 2 TCP channel is not exposed: TCP retransmits.
- **Dark-panel investigation** (`docs/research/display-handoff-dark.md`,
  agent, offline; adversarial review pending). Sources: v66 tree
  `23c97b2` (build .510; the device runs .511), checked
  against the real v66 `msm_drm.ko`.
  - On `fastboot boot`, the ABL clears the screen to black and then
    starts the kernel. No display power-off was found on that path
    (indirect chains not traced exhaustively) [M-static]. This explains
    "dark instantly".
  - The kernel builds `active=1` from MDSS registers and the DT; it never
    reads the panel or backlight [M-static].
  - **`backlight_changes_blocked` does not exist in v66** (source and
    binary; it is v2.7 only). So `display-bringup-quest3.md` §1/§3 are
    wrong for v66, and candidate 2 is ruled out.
  - On our modeset, v66 restarts the DSI link and reprograms the backlight
    at 1000/1000 (≤ 8.2 % duty), but never sends reset, sleep-out or
    display-on.
  - Hypotheses [O]:
    - H1: the panel or BLU was physically off at takeover;
    - H2: restarting the link without re-initialising the panel broke it.
  - **Options:**
    - R0: read pstore now (time-sensitive);
    - R1: a read-only lit baseline (TE and BLU IRQs, sysfs);
    - R2: the stage 3a image plus read-only probes to separate H1 from
      H2;
    - R3: run `fs-pattern` twice, so the second run gets a full screen-on
      modeset;
    - R4: run inside normal-boot recovery (Chair).
  - Pattern previews in `docs/research/pattern-preview/`.
- **R0 not run yet:** the Quest 3 was unplugged (not rebooted) when the
  PM connected the Quest 2.
- [removed for publication]

**J-74 · PM directions after trial (iii).**

- **Pattern (PM):** "keep the pattern light, and not dark, for
  visibility. Removes one variable." This needs a new stage 3a pattern
  revision and a Chair concurrence. The prior design (dark greys, no
  full-field white) was a caution, not a measured limit. The BLU duty cap
  (≤ 8.2 %) bounds luminance at normal-use levels [M-static, v66 source].
- **Quest 2 (PM):** moved to v2.7 as a PM executive decision [removed
  for publication].
- **Quest 3 (PM report):** "the screen on the Q3 was off, not just
  'black.' The backlight definitely wasn't on." This favours H1 (the
  panel or BLU off) over a dim or black frame [PM report].
- **PM:** FS-A-010 to be prepared without the Quest 2 read. The PM agrees
  with the second trial (iii) proposals: a light/bright pattern, and the
  run-twice route (plus read-only probes).
- **R0 pstore check (Quest 3, read-only, 06:50:30Z):** `/sys/fs/pstore`
  is **empty**, so no trial (iii) kernel log survived. This agrees with
  the earlier finding that ramoops does not survive bootloader reboots on
  this unit.
- **Uptime:** 6418.72 s, i.e. Android has run continuously since about
  05:03:32Z (the AA boot). The headset was evidently in standby, not
  powered off, during the cooling period.
- Battery 25.0 °C, 100 %.
- **Online research** on the Quest 3 panels and similar dark-panel reports
  was started (PM suggestion; output `docs/research/quest3-panel-online.md`).

**J-75 · FS-A-010 package review: findings and fixes.**

- Adversarial review of the FS-A-010 draft (`99ff75f`): **2 BLOCKER, 15
  MAJOR, 15 MINOR**. The machine-side facts were verified (hashes, 1 024-B
  loss, 66/69 FSP1 crc, comparisons, timings, key ABL/kernel claims of
  `display-handoff-dark.md`).
- **BLOCKERs:**
  - a false review-status claim for `display-handoff-dark.md`;
  - the bundle/manifest did not exist as described.
- **MAJORs:**
  - optical-quote provenance and the per-eye reading;
  - the softened sign-off account;
  - tag upgrades from the notes;
  - "fully explains" the dark at handoff;
  - **a wrong bright-pattern safety basis**: the commit programs 8.2 %,
    about 2× recovery;
  - two-run timing, DEADLINE, cues and outcome registration missing;
  - a loose settled-temperature rule;
  - wrong battery charge-state facts;
  - serial-loss overclaims (link speed not recorded);
  - Quest 2 "read-only" and missing disclosures;
  - the channel revision 6 review status;
  - the consent-description consequence of the backlight correction.
- **Fixes:**
  - attempt-log corrections appended;
  - correction notes in `display-bringup-quest3.md`, stage 3a
    README/IMAGE, and Corrections rows;
  - the relay rewritten;
  - a manifest-covered bundle;
  - a narrow channel revision 6 review started.
- **Channel revision 6, narrow review:**
  - the rebuild is bit-identical (`da19367b…`);
  - V1 (including the `.reloc` bypass) is closed, and the malformed-ELF
    item is closed;
  - `seg-check` is confirmed, and fails on the old link;
  - no gate silently passes on a tool failure;
  - **nit:** `#line`, quoted includes, or `-E` flag differences can evade
    the textual gate; the object gates catch these;
  - reviewer: ready for the Chair as offline work.
- **FS-A-010 rewritten (draft rev 2)** to address B1/B2, M1–M15 and the
  minors. The bundle and manifest will be built at finalisation, after
  the Quest 2 v2.7 read and the online panel research.
- **Online panel research** (`docs/research/quest3-panel-online.md`,
  agent; sources [C]):
  - no public prior art lighting Quest panels from a non-Meta kernel, and
    nothing on Tokki;
  - two 2064×2208 fast-switch LCDs; vendor and DDIC unknown;
  - CLO's `is_skip_op_required` skip-on-splash supports the run-twice
    plan;
  - risks: DisplayDxe power cut (H1); BLU timing set by Meta userspace;
  - new read-only probes: `/proc/cmdline` and the panel/rail/BLU status
    nodes;
  - folded into FS-A-010 §5.5/§6.
- **PM:** the fixes and proposals are accepted; a new panel test will
  follow after the Quest 2 work.
- **Reference (PM screenshot, Nura Wiki "META Quest 3S (panther)", last
  edited 2026-09-28) [C]:**
  - status "not booting" [paraphrased for publication];
  - no display work is reported. It lists the display as 3664×1920
    (1832×1920 per eye) LCD.
  - The page is noted only as prior-art context: no lit panels from a
    non-Meta kernel.
- **Display clues, second look (PM suggestion):** quest-kexec (Quest Pro;
  our notes say "DRM was brought up twice before the composer") and
  Quest1-SteamOS (`fastboot boot` route) are being mined for panel
  bring-up details (agent; output
  `docs/research/display-clues-kexec-quest1.md`).
- **Safety (PM report):** firmware of this era added a "Switch Boot Slot"
  option to the bootloader menu, which "does not do anything useful but
  can actually cause a brick if triggered".
  - Recorded as a never-use rule in the Quest 2 and Quest 3 READMEs and in
    Quest 3 `RECOVERY.md`.
  - Whether the Quest 3's firmware has it is [O]. This also fits the PM's
    earlier report that manual slot switches don't boot properly.
- **Display clues from the community repos**
  (`docs/research/display-clues-kexec-quest1.md`):
  - **quest-kexec runs its atomic client twice after the kexec handoff on
    the Quest Pro.** Its comment: "The panel only lights on the second
    bring-up" [M-static/C, commit `4554025`; no mechanism given; closed
    binary].
  - This is the closest prior art for the run-twice plan.
  - Our earlier note misread its "VrPowerManager black screen": that was
    TimeWarp blanking content, not the panel.
  - Quest1-SteamOS lights its OLED panels with one `FBIOBLANK`; there is no
    dark-start report.
  - Folded into FS-A-010 §5.6/§6: run 1 synchronous and the last `card0`
    close; an optional shorter run 1; wider dmesg; DRM
    status/enabled/dpms, fan and backlight reads.
- **Community advice [C]** [paraphrased for publication]:
  - later stages need a modified Mesa driver with a custom compositor,
    because the SteamVR compositor's use of libdrm gets in the way;
  - the panels are DSC displays with quad views, so displaying directly
    does not always work;
  - reuse the stock OS's existing CRTC parameters and render with them;
  - colourful garbage lines on the screen point to a DSC mistake.
  - The public fork YusufOzmen01/oculus-linux-kernel was recently updated;
    an agent is examining it.
- **Arbiter's reading [D]:**
  - `fs-pattern` already reused the CRTC's current mode (`why=crtc_current`)
    and let the stock SDE driver apply the DT's DSC topology. Trial (iii)
    saw no light at all, not garbage.
  - The compositor and mesa point matters for later stages (the SteamVR
    compositor on libdrm).
  - A read-only "stock CRTC parameters" capture in Android (DRM debugfs
    state) fits the planned lit baseline.
- **oculus-linux-kernel fork (YusufOzmen01)**
  (`docs/research/oculus-linux-kernel-yusuf.md`):
  - all author work is Quest Pro 4.19; Quest 3 is an untouched mirror;
  - no panel power-on, DSC or topology changes, so the second bring-up
    remains unexplained;
  - a Quest Pro backlight-timing re-send fix (ghosting; not applicable to
    the Quest 3 Tokki-A path);
  - kernel side of Turnip-on-KGSL sync bridges (later stages);
  - no sign our split commit caused a DSC mismatch;
  - read-only Android captures A1–A7 proposed (debugfs state,
    `crtc/status`, dmesg, modes, cmdline);
  - folded into FS-A-010 §5.7/§6.3.
- A full non-display review of Quest1-SteamOS and quest-kexec at their
  latest commits is running (PM: "anything is helpful").
- **Quest 2 after v2.7 (08:25Z, fastboot, already in fastboot):**
  - current-slot b; ABL ad4b133f68.20260708.
  - **Android read (08:27Z; the PM booted it):**
    - fingerprint
      `oculus/hollywood/hollywood:14/UP1A.231005.007.A1/52242990024200150:user/…release-keys`,
      the **same build as our pinned zip**;
    - slot `_b`;
    - kernel `4.19.325-cip128-st12-g49638c7a8637` (our v2.7 build
      target);
    - **`ro.boot.vbmeta.digest` = `91b7f93d…`**, which matches the digest
      computed offline from the pinned OTA (J-68), so the unit binding
      works [M];
    - security patch 2026-06-03; 100 %, 31.2 °C.
  - **Q2-P1 read-only baseline in Android (adb shell,
    `evidence/v27-baseline/`):**
    - `ro.boot.dtb_idx=1`, `dtbo_idx=0`; hardware revision Rev11;
    - **`sys.usb.controller` = UDC = `a600000.dwc3`**, so the channel's
      `FS_UDC_EXPECT` for v2.7 can be `a600000.dwc3` (in Android; under our
      own init it is to be confirmed);
    - cpufreq governor `performance` on all three policies in Android:
      silver 1.8048 GHz fixed; gold max 2.4192 GHz; prime max 2.8416 GHz;
    - thermal zones, cooling devices, hwmon and LEDs are not readable
      from adb shell (SELinux); `panel0-backlight` exists;
    - battery: AC, 100 %.
- **PM product goal:** "I want to improve upon their work as well.
  Optimize it. Make it better, if we can. They walked so we can run. I'd
  really like our port to feel like a polished, professional product."
- **Quest 1 (PM):** Quest 1 units are stuck at v50 due to end-of-life
  [paraphrased for publication].
  - The Quest 1 target is therefore **v50** (Quest 1 README).
- **Quest 3 units (Arbiter recommendation to the PM):**
  - keep Unit 1 on v66 until trial (iii-b) is done (the concurred v66
    baseline);
  - baseline Unit 2 before use; note its IPD fault.
- **PM:** the Quest 2 is unplugged and shut down. FS-A-010 to proceed.
  **Quest 3 Unit 2's identity to be supplied later.**
- **Stock display state, Quest 3 Unit 1, Android (PM-approved,
  read-only), 08:35Z, screen asleep**
  (`devices/quest3/evidence/stock-display-20261010/`):
  - debugfs is **not mounted** (A1–A4 need the PM's OK to mount it);
  - cmdline `msm_drm.dsi_display0=meta,eureka_panel_sharp:`,
    `cpufreq.default_governor=performance`;
  - dmesg: panel "Sharp novatek dual video mode dsi panel with dsc";
    "default topology: lm: 4 comp_enc:4 intf: 2"; "cont_splash enabled in
    1 of 1";
  - **Android performs three mode sets during boot** (90 Hz at 6.0 s,
    72 Hz at 11.5 s, 90 Hz at 13.5 s);
  - DSI-1 connected, enabled, dpms Off (asleep); 24 modes as in trial
    (iii); DP disconnected; Virtual connected;
  - crtc-0 sysfs: `backlight_timing=55,4828,4828`, `blu_default_duty=82`
    (confirms the DT value [M]), `fifo_trim=40`;
  - `panel0-backlight` brightness 0 / max 255, `bl_power=4` (off, asleep);
  - IRQ counts: `te-edge-isr` 20085, `blu-pwm-isr` 20087.
- **Arbiter slip (no effect):** an `adb push` of a read-only script to
  `/data/local/tmp` was attempted. It would have been a write to the
  headset. It failed; the file is absent (verified). The reads were then
  streamed via stdin with no file written. Rule restated: no
  `adb push`/write without the PM's OK.
- **Stock display state, screen ON (08:41Z; PM woke the display; debugfs
  mounted with the PM's approval, runtime only, until the next reboot):**
  - DSI-1 dpms On; measured 89.8 fps; `panel0-backlight` brightness 255,
    `actual_brightness` 0 (unreliable as a light indicator), `bl_power` 0;
  - crtc-0: `backlight_timing=422,5659,5659` (asleep: 55,4828,4828),
    `blu_max_overlap_us=500`, `fifo_scanlines=741`,
    `vsync_timing=32,2208,2918@90`;
  - **TE and BLU-PWM interrupts both advance about 182/s** (33236 → 33600
    and 33255 → 33619 in 2 s), i.e. about 2 × 90 Hz, while lit. These are
    the counters the trial (iii-b) probes will compare.
  - **Android's actual layout (debugfs `state` + `crtc155/status`):**
    - 4 mixers × 1032 px, one CTL;
    - **4 planes** (IDs 112, 115, 131, 134; two multirect pairs) from one
      4160×2208 AB24 buffer with a Qualcomm compressed modifier
      (0x500000000000001);
    - each plane is 1032 px wide: src x 0 / 1032 / 2064 / 3096;
    - **plane dst/crtc x is only 0 or 1032** (two per stage). The left-eye
      source (0–2063) is on stage 1 and the right-eye source (2064–4127)
      on stage 2.
  - **Reading [D/O]:** Meta's composer places planes in a per-half
    (2064-px) coordinate space. How a plane is assigned to the right half
    is not visible in the core DRM state (SDE-specific properties) [O].
    Our trial (iii) commit used 2 planes × 2064 px at crtc x 0 and 2064 in
    full-width coordinates; TEST_ONLY accepted it.
  - This mismatch cannot explain the dark backlight, but it matters for a
    correct image. Trial (iii-b) should mirror Android's layout: 4 × 1032,
    the same stages, and the SDE properties read via GET ioctls.
- **Community repos, full review** (`docs/research/community-quest-repos-2.md`,
  agent):
  - upstream Quest1-SteamOS and quest-kexec are unchanged;
  - **new: machachu56/quest-kexec-q2 `quest2-port` `9c96c19`** (Quest 2,
    GPL-2.0; Monado driver BSL-1.0). It kexecs a 4.19 kernel and runs the
    Frame userspace in a chroot (Steam UI works), with library-free
    SyncBoss IMU and controllers (commands 110/133; packets 80/143),
    Turnip-KGSL plus Zink, 3DoF Monado and camera record/replay.
  - **Quest 3 rootfs placement:** userdata uses wrapped-key metadata
    encryption plus FBE; quest-kexec places its rootfs in a file on
    userdata [removed for publication].
  - Most Quest1-SteamOS backports are unnecessary on 4.19/5.10. Stock
    Quest 3 still lacks SysV IPC and PID namespaces, so a rebuilt kernel
    is needed (kgate).
  - New hazard rules → PROJECT_SETUP §6A 8b, checklist H7.
  - **Licences:** Quest1-SteamOS has no licence (only its kernel/Monado
    patches are reusable); quest-kexec ships closed binaries and a
    modified-ROM release (not to be used).
  - Chair question noted (FS-A-010 §7.4): sharing images built from
    Valve's public repos.

**J-76 · FS-A-010 finalised (rev 4).**

- The verification pass of rev 3 (`0a4aa6d`) closed B1–B2, all MAJORs
  except M8 (partly), and all minors.
- **3 new MAJORs, all fixed:**
  - N1: the optical PASS now needs all 8 characters **in each eye**,
    recorded per eye and per run; a one-eye result is registered
    separately.
  - N2: **the plane layout stays unchanged (2 × 2064) in both runs.**
    Android's 4 × 1032 layout is deferred; it would change commit content,
    and the right-half selection is [O].
  - N3: the state changes on Unit 1 are disclosed in §5.8: the debugfs
    mount (still mounted until reboot; no node written), the display
    woken, and the failed `adb push`. [paraphrased for publication]
- **Minors fixed:**
  - cue windows (3 s cue gap; per-eye reporting);
  - power-off check order (power off while connected, then unplug);
  - papers scope (Quest 2/3S); Quest 3S wiki "not booting";
  - "left/right half of the buffer", not eyes;
  - `actual_brightness` reads 0 while lit;
  - Q2-P1 precondition disclosure;
  - §8 list (Quest 2 README; `FS-A-006-quest-projects.md` bundled);
  - the sign-off quote cited as one verbatim chat message.
- **Added from the reviewer:** the v66 scanline formula puts Android's
  normal lit BLU at about 8.2 %, the same as our commit (§5.8, §6.1).

**J-77 · FS-A-010 sent; PM notes; end of session block.**

- **FS-A-010 SENT** by the PM with `FS-A-010-raw.zip` (sha256
  `66be50a574dc1fdd8b7d04a2a9720cf861b2b011b060bda050c71fee9b941476`).
  Awaiting FS-R-010. No further relay until the Chair rules.
- **PM notes:**
  - quest-kexec's encrypted-storage workaround may not apply to us.
    - Arbiter: our v66 fstab still uses FBE plus wrapped-key metadata
      encryption, so a fastboot-booted Linux cannot read userdata either.
    - We also have other options: a dedicated partition or slot, or a
      reformatted userdata. These are writes, so they need Chair/PM
      decisions.
  - Quest1-SteamOS's missing licence is probably an oversight. Keep things
    above board: ask the author to add a licence; until then reuse only
    the GPL kernel patch and BSL Monado patch, and reimplement anything
    else ourselves.
  - **Valve public packages:** the PM wants an agent to investigate this
    alongside the Chair's ruling. To start next session.
  - **New repo:** https://github.com/Producdevity/ArmadaVR [removed for
    publication]. To examine next session.
- **Pending:**
  - FS-R-010;
  - the Valve-packages agent;
  - the ArmadaVR review;
  - Quest 3 Unit 2's identity;
  - **Unit 1 still has debugfs mounted until its next reboot.**

**J-78 · FS-R-010 received (Chair ruling on FS-A-010).**

- FS-R-010 (private review record) (verbatim).
- **Disposition:**
  - trial (iii) report accepted, INCONCLUSIVE retained;
  - **preparation** of trial (iii-b) concurred in principle, with a
    DEADLINE ceiling of 200 s and backstop 201 s. This is not concurrence
    to execute.
  - the v66 backlight correction is accepted: "backlight stays at boot
    level" is withdrawn for v66, and the consent description understated
    the possible brightness;
  - the Quest 2 results are noted;
  - the channel implementation review is incomplete (source and binary
    absent).
- **Binding design decisions for (iii-b):**
  - mid-grey/white pattern, with a preview before execution;
  - **write `panel0-backlight` = 127 before run 1** (an added runtime
    write; not approval of BLU controls); verify the brightness before
    both runs; about 4.1 % duty is an expectation, not a measured cap;
  - **first hold 3 s, second hold 10 s**; pause ≥ 2 s; **plane layout
    unchanged**;
  - require an accepted first commit and a successful close before run 2;
    if run 2 does not find the inactive CRTC, register the unmet
    precondition and recover, with no off→on claim;
  - probes bounded, read-only, with no extra `card0` opens;
  - per-eye, per-run observations; lit-but-garbled is a lighting finding,
    not an optical PASS;
  - no numerical eye-safety claim from transition spacing.
- **Pacing:** byte-identical FSB1 and rejection rules. Demonstrate:
  identical bytes and hashes; the trial (iii) capture still rejected;
  correct operation across chunk boundaries; an emission bound from the
  **maximum** record size and line count.
- **Deadline:** justified from the implemented bounds (probes, both
  supervisor limits, pause, maximum paced emission, margin, post-record);
  runner guard about 95 s, to be recomputed. Clock regressions updated
  for the new stage.
- **Procedure:**
  - "stable within tolerance" (two readings ≥ 10 min apart, < 35 °C,
    ≤ 0.5 °C rise);
  - BA→attempt ≤ 5 min, enforced before boot; prepare everything before
    BA; if the cap expires, record the abandoned cycle and take a new
    baseline;
  - immediate AF; at ≥ 40 °C after recovery, begin shutdown/cooling
    immediately; at least one scheduled follow-up reading even if below
    40 °C; record the highest observed reading;
  - power-off verified by power menu, physical observation and
    unplugging (adb absence alone is insufficient); no restart just for
    telemetry.
  - A new image, nonce, pins, outcomes and sign-off; split BA/BF lines.
- **Quest 2:** send the complete channel folder (source, tools,
  allowlists, harnesses, the exact binary) or an accessible repository at
  the exact commit. The 104 s cap is a planning result. Thermal and
  recovery for the Quest 2 to be assessed later.
- [removed for publication]
- **Return:** the trial (iii-b) package (sources, image, pins,
  maximum-size pacing evidence, timing checks, outcomes, preview, node
  list, procedure). The Quest 2 implementation may arrive separately.

**J-79 · ArmadaVR reviewed; usermode-helper finding checked.**

- `docs/research/armadavr.md`. Producdevity/ArmadaVR `272b607`, **no
  licence** (ideas only; ask the author).
  - A Fedora + FEX + Monado/SteamVR lab in QEMU for the Quest 3 and the
    Pico Neo3 Pro Eye, on Meta's 5.10.246 kernel.
  - Quest 3 via kexec (planned). **Nothing has booted on a headset.** There is no Quest 2
    code in the repo. [paraphrased for publication]
  - New for us:
    - Turnip-KGSL on the A740 needs the newer KGSL GPUOBJ allocation
      calls (from Jbbrack03/Quest-3-Turnip-Driver `b09a4535`) [C];
    - KGSL↔DRM-syncobj and SDE `DRIVER_SYNCOBJ` patches;
    - the ADSP→PMIC-GLINK→UCSI→DWC3 wait order (QRTR service 64 first;
      `ucsi_glink` loaded explicitly) [C, QEMU only];
    - pd-mapper `SurviveFinalKillSignal`; failures power off rather than
      drop to an emergency shell.
  - Not reused: material outside FrameShift's scope [paraphrased for
    publication]. No display findings.
- **`CONFIG_STATIC_USERMODEHELPER=y` with an empty path** is in our stock
  configs, per the agent [M-static]. Arbiter check of the near-match v66
  source:
  - every usermode-helper call (`/sbin/poweroff`, `modprobe` autoload)
    fails;
  - **but** a thermal critical trip calls `orderly_poweroff(true)`, and on
    failure that forces `emergency_sync(); kernel_power_off()`
    (`kernel/reboot.c:459-475`), with a backup delayed
    `thermal_emergency_poweroff()` (`thermal_core.c:405-417`) [M-static,
    near-match].
  - So a **critical-trip shutdown is still forced, just not orderly**
    [D]. ArmadaVR's "never runs" applies to the orderly path.
  - Module autoload does not work, so our init must load modules
    explicitly (it already does).
  - Our stage images load no thermal-zone drivers. Protection remains the
    short hold plus attendance (SIGNOFF), and later stages need userspace
    thermal ownership (thermal design rev 2).

**J-80 · Valve package licensing research (for a Chair ruling; not legal
advice).**

- `docs/research/valve-packages-licensing.md`. No gated path was accessed
  and no token was used; the report quotes no credential value (Arbiter
  check).
- **Repos:** Valve's package host serves the Frame ("deckard") repos and
  the Holo Core preview without credentials, but has **no terms or licence
  notice**. Valve's SteamOS licence calls only the **Deck** mirror publicly
  available. The Frame itself uses a gated, tokened repo.
- **Licences (Valve metadata):** the Steam client and SteamVR are "Steam
  Subscriber Agreement, Proprietary"; about 17 `deckard-*` hardware
  packages are proprietary; the Frame kernels are labelled "GPL-2.0-only
  **no-source-release**"; the Arch-derived base publishes its sources.
- **Valve terms:** the Steam client is "non-redistributable" without a
  separate licence. Only the 2013 x86 bootstrapper grant exists, from
  secondary sources.
- **Precedent:** Jovian-NixOS fetches Valve's bootstrap on the user's
  machine. No takedowns found (absence of evidence).
- **Holo Core:** a public aarch64 preview with no Steam, SteamVR or
  `deckard-*` packages; it is not the Frame's shipped base.
- **Options ranked:**
  1. (a) our code plus an installer that fetches from Valve on the user's
     device, with terms shown, no patching, no token, signatures checked;
  2. (b) an open-source-only base, with full GPL compliance on us;
  3. (d) ask Valve, in parallel;
  4. (c) redistribute full images: not without Valve's licence.
- **Questions for the Chair** (to go in FS-A-011):
  - shared images built from Valve's repos fall under (c);
  - does "Valve binaries" (§6A item 9) include open-source packages built
    by Valve or Collabora?
  - "Valve stable only" = the contents of signed update bundles marked
    stable?
  - whether to authorise a written query to Valve.

**J-81 · [removed for publication]**

**J-82 · Trial (iii-b) package built offline (agent; unreviewed).**

- `devices/quest3/stage3b/` (README, IMAGE), `common/target/fsb1-pace.sh`,
  `host/fs-classify3b.ps1`, `host/test-host3b.ps1`; updated collector,
  classifier, observer, OUTCOMES §9, FSB1-SPEC §9, DEADLINE §4, COLLECTOR
  §13, SIGNOFF (trial iii-b, split BA/BF), RECOVERY (Th + 260 s) and
  PROJECT_SETUP §6A.1.
- Previews: `docs/research/pattern-preview/bright-v0.5-*`.
- **Image** `build/stage3b/20261010T181510Z-8b1a9e00e2a3a9bc/boot-stage3b.img`,
  sha256 `a09ff582…6be0`, nonce `8b1a9e00e2a3a9bc`; bit-identical rebuild.
  Never booted (sandbox harness only).
- **fs-pattern v0.5:**
  - grey 0x80 field with white marks;
  - `show` (run 1, 3 s) and `show-off` (run 2, 10 s; commits only if the
    CRTC is provably inactive, otherwise exits 31 with no commit);
  - read-only property logging within a 20 KiB budget;
  - the layout, TEST_ONLY order and hold code are unchanged from v0.4.
- **Runner:**
  - the single write is brightness 127, with read-back verification
    before each run;
  - run 2 is gated on run 1's accepted commit and clean close, a pause
    ≥ 2 s, and the read-back;
  - bounded, supervised probes; no `card0` opens, no debugfs;
  - paced emission at 10 lines per 0.1 s.
- **DEADLINE 200 s (backstop 201 s):**
  - W = 80.6 s (including paced emission of the maximum 1600-line record,
    18.6 s);
  - B = 90 s; **runner guard 97 s**.
- **Pacing evidence 20/20:** byte- and hash-identical at 878 and 1600
  lines; the trial (iii) capture is still rejected; chunk-boundary splits
  decode correctly; 17.3 s ≤ 18.6 s bound.
- **Tests:** fs-pattern 109/109, builder 10/10, image 12/12, host3b
  106/106, host2 459/459; timing checkers consistent.
- **Design choices to put to the Chair:**
  - run 2 refuses to commit if the CRTC is active;
  - a failed brightness read-back skips that run;
  - a 1600-line record cap is enforced (the step caps alone would allow
    5141);
  - dmesg deltas per probe point;
  - "after modules" = the runner's first probe plus an init interrupt
    sample;
  - the full property dump in run 1 only.
- **The stage 3a host tools changed** (new hashes; trial (iii)
  classification still reproduces). The stage 3b pins will be stated in
  FS-A-011.
- Adversarial review next.
- **Review of `afc6666`:** no BLOCKER; **2 MAJOR**:
  - **M1:** the 1600-line record cap could discard a legitimate record
    (step caps allow 5141 lines; heavy dmesg is about 1770), losing all
    commit evidence. The fix: per-step caps consistent with MAXLINES,
    graceful truncation, and a corrected "maximum record" evidence claim.
  - **M2:** the SIGNOFF thermal step contradicted itself at ≥ 40 °C.
  - 9 minors: a circular exit-31 claim; classifier labels and O3 scope;
    the pre-snapshot completion gate; unverified probe timing windows; an
    undisclosed H2 brightness case; dwell evidence not logged; wording;
    the stalled-reader note; out-of-step lists.
- **Verified sound:** every FS-R-010 §4 decision; a bit-identical rebuild;
  the only sysfs write is brightness; the layout code is unchanged; run 2
  is gated; pacing is byte-identical; W/B/guard 80.6/90/97 s; dwell
  refusal; outcomes.
- Fixes delegated: a new nonce and rebuild.
- **Fix round (agent):** all 2 MAJORs and 9 minors fixed.
  - **New candidate image** `c620c1b8…76bd`, nonce `d4ad74bb5d64f949`
    (`build/stage3b/20261010T191219Z-d4ad74bb5d64f949/`); bit-identical
    rebuild. Withdrawn: `a09ff582…` (reviewed) and `00aca656…`.
  - **Caps:** hash 256, probe1 16384, pattern1 40960, probe2 12288,
    pattern2 20480 (raised from the suggested ~16384 because run 2 carries
    the `mode_properties` blob).
  - **MAXLINES 1900:** the worst case within caps is 1898 lines (the
    checker asserts it); an over-cap probe truncates gracefully; maximum
    evidence regenerated with every step at its cap; 1901 is refused with
    nothing written.
  - Probe stderr goes to /dev/null; dmesg only at mods/mid/post, 1536 B
    each.
  - Pre-snapshot `.done` gates; a 1 MB dmesg costs 0.53 s under qemu.
  - Dwell evidence goes to observe.json/log; the H2 brightness disclosure,
    wording and classifier separation are fixed.
  - **Timing:** W = 83.9 s (paced 1900 lines = 21.9 s), B = 90 s,
    **runner guard 100 s (1 s spare: thin)**; DEADLINE 200 s; manual
    route Th + 260 s.
  - **Tests:** fs-pattern 109/109, pacing 24/24, builder 10/10, harness
    12/12 (deadline reboot T0 + 200.3 s), host3b 116/116, host2 459/459,
    timing checkers consistent.
- Verification pass requested.
- **Verification of `bdf5451`: ready for the Chair.**
  - M1, M2 and minors 1–8 closed; m9 partly (a stale IMAGE line).
  - Independently confirmed: the 1898-line worst case, graceful truncation
    (VALID record), the maximum evidence at caps, the stage 3a
    reproduction, host suites 116/116 and 459/459.
  - New minors:
    - the **thin guard margin**: in the planning model only 1 s spare; at
      run time fs-display must be sent by +85 s versus about +32 s in
      trial (iii). Tripping it refuses before display (no write, no light)
      but spends the attempt;
    - N1: the run 2 stream could theoretically exceed its 20480 cap
      (INCONCLUSIVE, fail-safe);
    - N2: the dwell is recorded at boot but not enforced at that instant.
- **Arbiter decision:** restore the margin before the Chair (20-line
  pacing, collector start 25 s, pattern2 cap 28672, a new nonce).
  Delegated.
- **Final round done:**
  - **Candidate image**
    `build/stage3b/20261010T194509Z-<attempt nonce withheld>/boot-stage3b.img`,
    sha256 `ea60d6cd…5841`, **nonce `<attempt nonce withheld>`**; identical
    rebuild. `c620c1b8…` withdrawn.
  - **Timing:** 20-line pacing (EMIT 12.4 s, largest write about 2.2 KB);
    W = 74.4 s; B = 85 s (collector start 25 s); planning spare 10.6 s;
    **guard 91 s (5 s spare)**; MAXLINES 2070 (worst case 2069, pattern2
    cap 28672); DEADLINE 200 s.
  - N2 documented (the gate runs less than 1 s before BootStartUtc; both
    values recorded).
  - **Tests:** harness 12/12, pace 27/27, builder 10/10, fixtures
    109/109, host3b 116/116, host2 459/459, timing CONSISTENT.
  - The package is ready for FS-A-011 (the reviewer's verification
    covered the substance; this round changes pacing and caps only).

**J-83 · PM directions (product, installer, safety, continuity); Unit 2
identified.**

- **Licences (PM):** ArmadaVR has no licence yet. The PM will ask its
  owner to add one and has invited a collaboration [paraphrased for
  publication].
- **Engineering principle (PM):** learn from others, then independently
  decide the best method. Prefer a more robust, reliable approach of our
  own; adopt others' methods where they prove best. Polished and
  professional, not jerry-rigged.
- **Graceful emergency shutdown (PM requirement):** design a graceful
  shutdown for critical failures (thermal, battery, hang), given that
  stock `STATIC_USERMODEHELPER` blocks the kernel's orderly poweroff
  (J-79). → design item.
- **Distribution (PM): option 1** (our code plus an installer; positive
  user experience is paramount).
  - PM idea: build everything around the **unmodified Valve image**. The
    user installs our package, then downloads and slots in Valve's image
    unmodified, and everything comes up.
  - Arbiter assessment in the reply and in PROJECT_SETUP §0.1.
- **Continuity (PM):** someone new must be able to start with the
  README.md in the root folder and pick up exactly where we left off
  [paraphrased for publication]. The same applies to the future GitHub repo.
  - **There was no root README.md**, and the JOURNAL "Where we are now"
    was stale (it still said FS-A-007 in preparation). → being fixed.
- **Quest 3 Unit 2 identified (read-only, 18:45Z):** `QUEST3UNIT2`.
  - v71 `50352750111100511`, slot `_b`, security patch 2024-07-05;
  - 96 %, 27.0 °C.
  - 93 by-name entries: 86 partitions totalling 9.51 GiB, excluding
    `userdata` (106 GiB) and whole-disk nodes.

**J-84 · [removed for publication]**

**J-85 · Valve-image slot-in architecture researched**
(`docs/research/valve-image-slot-in.md`; agent, offline). Summary in
PROJECT_SETUP §0.0.
- **Sources:**
  - Valve's public recovery directory lists
    `steamframe-oobe-repair-20260922…img.bz2/.zip` (what we hold)
    [M-static];
  - Valve's whole-device flashing packages are **never used with a
    Quest**; only the verified rootfs range of the recovery image is used;
  - signed RAUC index plus casync bundles rebuild the btrfs slot byte for
    byte [M-static/D]. Whether Valve intends `vr/` for third parties is
    [O].
- **btrfs features:** flags `0x355`, no block-group-tree. A 5.10 kernel
  supports them [D].
- **New device writers in the Valve image** [M-static], added to the
  hazards:
  - `steamvr-program-ble.service` (openocd over gpiochip9, nRF52
    `nrf52_recover`, a mass erase);
  - `deckard-charger` (battery-pack NVM register writes);
  - `vrconfig_write` (writes `/persist`);
  - also `systemd-repart` is enabled by default and could add a partition
    on LUN 0 [D].
- **Recommended:**
  - our kernel and initramfs, plus the Valve rootfs read-only behind
    dm-verity (v2.7 has DM_VERITY, overlay, loop), with our layer on top;
  - `/boot` hidden;
  - the safety boundary in our parts: a kernel block-write guard (a
    source patch; BPF-LSM is off), no Frame partition names, command-line
    masks, refusing stubs, an ingest allowlist;
  - our installer handles A/B updates, and RAUC never runs;
  - the safety supervisor is started from our initramfs.
- **Risks [O]:**
  - whether SSA/EULA "modify/tamper" reaches runtime layering;
  - OOBE forcing an update or pairing;
  - Steam client hardware checks;
  - storage on encrypted userdata (a new write class);
  - SYSVIPC is missing in the stock kernel.
- **Decisions:**
  - PM: image route, small metadata downloads and QEMU tests, installer
    platform, storage default, telemetry, outreach to Valve; [paraphrased for publication]
  - Chair (FS-A-011): R3 restatement, kernel guard, shadowing,
    allowlist, storage write route, the whole-device-package ban.

**J-86 · PM decisions on distribution, controllers, repo, installer.**

- **Unit 1 was powered down last night (PM)**, so the debugfs mount from
  J-75 is cleared.
- [removed for publication]
- **Official Frame image (PM):**
  https://store.steampowered.com/steamos/download/?ver=steamframe, still
  v0.3.0.
- **PM questions:**
  - Can Valve's updater deliver newer SteamOS OTAs and still slot in?
  - Is the project possible without modifying SteamOS?
  - Weren't we going to ship FrameShift images ourselves? The PM wants
    OTAs on the headset, not manual flashing.
  - Arbiter answer in chat; PROJECT_SETUP §0.0 to be updated after the PM
    agrees.
- **Contacting Valve:** the PM agrees. Outreach correspondence (private;
  not sent). [paraphrased for publication]
- **Controllers (PM requirement):** let users pair any VR controller they
  own (Meta, HTC, Valve, Samsung, PlayStation, others) → a later-stage
  requirement (checklist H5).
- **Storage (PM question):** with our own firmware, wouldn't we have our
  own user storage, and shouldn't all partitions be replaced? Answer in
  chat.
- **GitHub (PM):** private for now; public when there is a bootable test
  image (community testing).
- **Metadata downloads for offline tests:** approved (PM).
- **Installer (PM):** WebUSB first; later updates on the headset.

**J-87 · PM decisions: repo public before contacting Valve; OTA; [paraphrased for publication]
controllers; installer.**

- **GitHub:** the PM wants the repo **public before** Valve is contacted,
  so that Valve can see the work. This supersedes "private until a
  bootable image" (J-86) for this purpose. [paraphrased for publication]
  - A pre-publication audit (private) is running: Valve and Meta
    material, credentials, personal data, licences, history. [paraphrased for publication]
  - Creating and pushing the repo needs the PM's explicit go and repo
    details.
- **Outreach correspondence (private):** updated at the PM's request
  [paraphrased for publication].
- [removed for publication]
- **OTA approach agreed (PM):** intercept or switch off the Valve-specific
  incompatible parts and layer our own (PROJECT_SETUP §0.0, Updates).
- **Controllers (PM clarification):** BLE VR controllers with
  inside-out/SLAM-style camera tracking, from a future catalogue;
  **minimum: the Meta Touch series** (checklist H5).
- **Installer:** design for a WebUSB flow (PROJECT_SETUP §0.0).
- **Publication scope (PM):** not everything needs to go public. Omit
  Valve/Meta material, or replace it with proxy files (hashes and
  pointers).
  - Arbiter note: anything ever committed is in git history. The public
    repo should therefore be a **curated export** (a filtered history, or
    a fresh history from a cleaned tree). The full private repository
    stays local as the master. The audit will define the include/exclude
    list.
- [removed for publication]

**J-88 · [removed for publication]**

**J-89 · Pre-publication audit (private; not for publication itself).**
[paraphrased for publication]
- 220 commits, 3 branches. **Valve material: clean.** No Valve binary,
  image, keyring or credential in any revision.
- **MUST-FIX before public:**
  - extracts of Meta firmware metadata and their manifests with
    identifying data and private archive paths; [paraphrased for publication]
  - the decompiled Quest 2 v2.7 DTS (`devices/quest2/analysis/v27-dt/`);
  - docs: package-source lines; verbatim private messages from community
    members; provenance wording tied to identified units;
  - an overstatement in outreach correspondence (fixed);
  - the author identity on all commits (PM's call). [paraphrased for publication]
- **SHOULD-FIX:** small partition captures (contents benign); the `fs-rpcd`
  static-glibc binary (LGPL); LGPL notices on the glibc excerpts and ld.so
  disassembly; home paths and host name in about 60 files.
- **PM's call:** device identifiers; third-party names and handles
  (consent); journal passages. [paraphrased for publication]
- **Third-party code: none copied. Size:** 7.3 MB `.git` (no size
  problem). **No LICENSE yet:** recommended Apache-2.0 for the repo,
  GPL-2.0 for future kernel patches (own folder), optionally CC-BY-4.0
  for docs, plus a NOTICE (no Valve/Meta material, not affiliated).
- **Plan:** the public repo is a **fresh single-commit export** from a
  cleaned copy; this repo stays the private record. Local tool settings
  are now gitignored. [paraphrased for publication]

**J-90 · PM publication decisions; GitHub tooling.** [paraphrased for
publication]
- **Agreed (PM):**
  - a fresh public repository (created private first);
  - licences: Apache-2.0 for the repo, GPL-2.0-only for future kernel
    patches in their own folder, optionally CC-BY-4.0 for docs; [paraphrased for publication]
  - a NOTICE (no Valve/Meta material; not affiliated);
  - no personal e-mail address on public commits; [paraphrased for publication]
  - all audit MUST-FIX and SHOULD-FIX removals.
- **Standing publication rules (PM):**
  - **no headset serial numbers are ever disclosed** publicly;
  - **credit only people who directly contributed** (decided later, once
    there is a bootable image);
  - **remove usernames** unless they refer to another public repo or link
    to that person's work;
  - the project assumes an **already-unlocked headset**, so no unlocking
    guides, data or info go into the public repo.
- **GitHub tooling:** the GitHub command-line client was installed with
  the PM's approval (installer hash verified). The PM signs in personally;
  the Arbiter does not handle credentials. [paraphrased for publication]
- **Repo form guidance given:** Private; README off; no .gitignore; no
  licence.
- **Done (PM):** `continuumxr/frameshift` created, Private and empty, with
  the agreed description. `gh` is logged in as the PM's account [removed for publication] (scopes: repo,
  read:org, workflow, gist), verified read-only by the Arbiter.
- **Connectors:** the MCP registry search found **no GitHub connector**
  for this session, so the `gh` CLI is the route.
- **Public content rule (PM, confirmed):** the public repo contains
  **only material we developed ourselves, or have explicit permission to
  post**.
  - Excluded under this rule: copied glibc source excerpts, the
    disassembly of Valve's ld.so, any copied third-party text beyond a
    short citation, anything extracted from Meta binaries or firmware, and
    captures of third-party tool output.
  - Kept: our own analysis with citations, and data our tools generated
    from Meta's **public GPL-2.0** kernel source, with attribution.

**J-91 · [removed for publication]**

**J-92 · Sanitised public copy built (`frameshift-public`; not pushed).**
- Single commit `092ffec3…` on `main`, under the GitHub noreply identity,
  set in local config only. No remote. Exported from private `ec8a523`.
- 1,646 files examined: 981 identical, 258 sanitised, 13 new, 468
  excluded. The commit holds 1,191 files, 11 MB.
- **Excluded:**
  - raw relay evidence folders and device evidence folders (each replaced
    by a README note);
  - firmware-metadata extracts, the v2.7 DTS, built binaries, `.img` dumps,
    outreach correspondence (private), a pre-publication audit (private); [paraphrased for publication]
  - under the own-work rule: the glibc excerpts, the ld.so disassembly,
    stage2a evidence (inspections of Valve files), kgate
    `required_crcs.txt`/`inventory.tsv` (extracted from stock modules),
    the Quest 2 vendor scan and boot-header dump.
- **Sanitised:**
  - serials → `QUEST3UNIT1` / `QUEST3UNIT2` / `QUEST2UNIT` /
    `THIRDPARTYUNIT`;
  - paths → `<repo>`/`$HOME`; host → `<build-host>`;
  - 40 scripts now derive the repo root;
  - prose edits in dated records marked "[removed for publication]".
- **Added:** LICENSE (Apache-2.0), NOTICE, `kernel-patches/README.md`
  (GPL-2.0), a public README.
- **Final scan:** zero hits on serials, email, paths, host,
  third-party handles, firmware-site names or secrets; no ELF or image
  files outside the synthetic kgate fixtures.
- **Tests in the public copy:** kgate 170/170, stage1 74/74, fsb1 38/38
  ×2, gadget all pass. Some suites abort or need withheld files
  (host2/host3b sections reading raw evidence; quest2 fs-rpcd binary
  case).
- Adversarial pre-push review started. **No push until the PM's go.**
- **Review of `092ffec`:** clean on serials, personal data in files,
  third-party names, firmware-site names, Valve/Meta binaries and licence
  files. **Not ready to push.**
  - **MUST-FIX:**
    - M1: the commit identity (first name; the noreply address embeds the
      account name; a local timezone offset [paraphrased for publication]) is a PM decision; UTC dates adopted;
    - M2: Quest 2 `boot-layout.txt`/`vbmeta.txt` are verbatim
      firmware extracts → withhold;
    - M3/M4: out-of-scope material still recoverable in several docs →
      remove; [paraphrased for publication]
    - M5: fix everything before the first push, because force-pushed
      commits can stay reachable.
  - **SHOULD-FIX:**
    - S1: unmarked edits in dated records, including one factually wrong
      replacement;
    - S2: test suites abort on withheld inputs → skip cleanly;
    - S3: NUL bytes stop GitHub rendering two .md files;
    - S4/S5: remaining out-of-scope pointers and metadata;
    - S6: the reproducibility note;
    - S7: cosmetic leftovers.
  - All delegated to the export agent. The commit will be re-created once.
- **PM decision (M1):** keep the PM's first name [removed for publication] with the GitHub noreply address
  (standard practice; links the commits to the GitHub profile), with UTC
  commit dates.
- A network outage (API unreachable) interrupted the export agent twice;
  it was resumed both times, with no data loss.
- **Fixed commit `b322135`:** all M/S findings closed (the re-review
  scans are clean; README tests on a fresh clone pass with 0 FAIL, except
  one item below). New issues:
  - **S8:** a fresh Windows clone (autocrlf) converts a hash-pinned file
    to CRLF, so `fixtures-build` gets 1 FAIL → fix with
    `* text=auto eol=lf`;
  - **S9:** `run_validation.sh` overwrites committed records when inputs
    are absent → refuse;
  - polish: 19 mid-sentence markers; local-time timestamps (time zone) → UTC; [paraphrased for publication]
    small README notes.
  - Reviewer: push-private yes after S8, flip-public yes after S8. A final
    polish round is delegated, then the commit is re-created.
- **Final public commit `7b14e154…`** (the PM's first name [removed for publication] with the noreply address,
  2026-10-11T01:03:49Z UTC; 1,189 files; no remote):
  - S8: `* text=auto eol=lf`; a fresh Windows clone is byte-identical and
    pins match (fixtures-build 42 PASS / 1 SKIP);
  - S9: `run_validation.sh` refuses before writing;
  - markers moved or dropped; local time → UTC everywhere; [paraphrased for publication]
  - README counts fixed; refusing suites no longer delete committed
    outputs.
  - Fresh-clone tests: 0 FAIL, 0 aborts.
  - **Arbiter spot-check:** no remote; clean tree; a grep for serials,
    email, paths, host, third-party handles, firmware-site names, DO_NOT_SHARE values,
    local-time stamps and archive-drive paths → 0 hits [paraphrased for publication]; no file > 1 MB.
  - **Pushed (PM's go):** `main` = `7b14e154…` to
    `https://github.com/continuumxr/frameshift` (**PRIVATE**). `git
    ls-remote` confirms the single commit. The private master repo is
    untouched. Next: the PM reviews on GitHub, then flips it public; then
    outreach correspondence (private) [paraphrased for publication].

**J-93 · FS-A-011 drafted; roadmap position.**
- FS-A-011 (private review record) (DRAFT; adversarial review pending) with
  `FS-A-011-raw.zip` (952 files) and `FS-A-011-image.zip`.
- **Contents:**
  - the trial (iii-b) return package (image `ea60d6cd…`, nonce
    `<attempt nonce withheld>`; each FS-R-010 decision mapped to file and line;
    six design choices);
  - the full Quest 2 channel, including the binary `da19367b…`;
  - the distribution model, questions D1–D7;
  - the PM's decisions and state changes;
  - other findings and corrections.
- **Asks:** execute trial (iii-b); rule on the six choices; review the
  channel; rule on D1–D7; note the record.
- The review must also cover the final stage 3b margin round (`bb96b7a`),
  which no independent reviewer has checked yet.
- **Roadmap:** Stage 1 achieved; Stage 2 partly shown (trial (i));
  **Stage 3 (display) is the current gate**, with trial (iii-b) ready.
  After that: the thermal, fan and graceful-shutdown stack; graphics;
  tracking and Touch controllers; the installer and OTA around Valve's
  unmodified image; Quest 2 bring-up.
- Status sections refreshed (the README line, JOURNAL "Where we are now").
- **`continuumxr/continuum` archived** at the PM's request (via `gh`).
  - Its description now reads: "Archived. Continuum continues as
    FrameShift (SteamOS on Meta Quest headsets) under the continuumxr
    organization."
  - No content commit was made. A README pointer with a link can be added
    once FrameShift is public (archived repos can be unarchived to edit).
  - Previous description: "Continuum is a privacy-first, open-source XR
    operating system focused on preserving standalone VR/AR hardware
    beyond vendor end-of-life."

**J-94 · FS-A-011 SENT (PM), before its adversarial review completed.**
- The PM sent the DRAFT text with `FS-A-011-raw.zip` sha256
  `8b7a43952dfb1121b4b64ee09c9850e9e7be7eae1801f3a5ee28272ab8114ed4` and
  `FS-A-011-image.zip` sha256
  `84b962925981a3efd5ff5ecb3500c331ce2686fbe236878b6b6258fe047b781d`, both
  built 2026-10-11 ~03:12 UTC and unchanged since (verified).
- **Deviation from relay practice:** the adversarial review (which also
  covers the unreviewed final stage 3b margin round) was still running
  when the relay was sent. Its findings will be logged here and sent as
  **errata** in the next relay, or sooner if anything bears on trial
  (iii-b) safety. The relay file's status line now records this.
- **Process change (PM):** relay files are never made available, and
  never suggested for sending, until absolutely ready.
  - Drafts live in the private review records *[editor's note: a private working folder, not in this copy]*.
  - Bundles are built only after all reviews pass.
  - Only then is the file moved to the private review records and announced as
    "READY TO SEND".

**J-95 · FS-A-011 to be consolidated (PM).** The PM told the Chair that
  the FS-A-011 sent was incomplete, and asked for a finished, consolidated
  FS-A-011 to send instead.
- Record kept: FS-A-011 (private review record), with the zips renamed to
  `FS-A-011-sent-draft-raw.zip` and `-image.zip` (hashes in J-94).
- Work copy: the private review records (NOT READY).
- It will incorporate the running adversarial review, get a re-review,
  then the final bundles, and only then "READY TO SEND".

**J-96 · FS-A-011 review sweeps complete; J-79 corrected.**
- The main review plus sub-sweeps A/B/C and the Arbiter's own sweeps A/B/C
  have all reported on the sent draft text.
- **Key correction (BLOCKER in sweep C):** the J-79 emergency-shutdown
  reading was wrong (Corrections table).
  - On the Quest 3 a critical trip still forces an unsynced power-off,
    via the 100 ms emergency work.
  - **On the Quest 2 (v2.7 config, delay 0) a critical trip forces no
    power-off at all** [M-static config; D]. (Scope narrowed in J-99: no
    software-forced power-off via the kernel thermal core; vendor and PMIC
    protection not assessed [O]; see Corrections.)
  - This raises the priority of the graceful-shutdown / thermal-ownership
    design (PM requirement, J-83), especially for the Quest 2.
  - Arbiter check of `umh.c:397-423`, `thermal_core.c:375-386` and both
    configs.
- **Other findings, for the consolidated FS-A-011:**
  - FS-R-001 R3 quoted in full, including its review clause
    (PROJECT_SETUP §0.0 fixed); FS-R-002 §4/§6 cited (guard deferral;
    keep the build pinned during bring-up);
  - "stable" presupposed; the J-85/J-86 source tags; "no light" claims;
    the continuum archive and the network fetches to disclose;
  - the self-test scope; table-v2 not byte-identical; Quest 2 README
    narrowings; what the Chair can verify from the bundle;
  - §7 additions: the [O] on whether the first optical report preceded the
    console, and standby versus power-off;
  - citation fixes (fs-pattern.c 1357-1365, rule 15, timeline sources,
    dmesg case-insensitivity, FSDE1 printed by fs-display.sh);
  - the cue/SIGNOFF beep mismatch (the cue says "until beep 1"; SIGNOFF
    says until the second beep) → fix the host cue text;
  - new bundler paths that freeze the sent manifests; the README refresh.
- Consolidation delegated; a fresh review follows; bundles only after it
  passes.

**J-97 · Consolidated FS-A-011 revision (draft; NOT READY).**
- Every finding of the main review and the six fact-check sweeps (J-96) is
  applied to the private review records, with an appendix "Changes
  from the sent draft". The sent draft and its manifests are untouched.
- **Host-side fix (no image change):** `devices/quest3/host/fs-collect.ps1`
  stage-3b cue now says "Keep looking until the SECOND (LOW) BEEP" (it said
  "until BEEP 1"), matching `SIGNOFF.md` E (the dark check falls between the
  beeps); the stale line-9 comment now says RunnerWorstSec 75 s. Stage 2a/3a
  texts and behaviour unchanged.
  - New hash `fs-collect.ps1` `2b90d641a15065da522e885df6cb627cd01e48608f7a20faea4cd07698068089`
    (was `09052f40…a2ae1`); `test-host3b.ps1` C4 now also asserts the new cue
    text (`d50035c4…844a`); `COLLECTOR.md` §13 aligned.
  - Re-run (scratch first, then copied): `test-host3b.ps1` **116/116**,
    `test-host2.ps1` **459/459**; committed outputs updated (only times and
    scratch paths differ).
- `devices/quest2/README.md`: the FS-R-010 §7 narrowings (104 s planning cap
  with the send-time guard retained; ELF 3.7.0 annotation; thermal absence
  not established; reboot cycles are state changes), the J-96 Quest 2 thermal fact, and the stale FS-A-010 lines fixed.
- `README.md` status refreshed; "Where we are now" refreshed;
  `serial-loss-trial3.md` body cap assertions annotated; the
  `valve-image-slot-in.md` download-page [O] updated (PM report, J-86).
- Corrections rows added (FS-A-010 "not rising"; the flicker-band basis;
  [removed for publication]).
- New bundler FS-A-011 (private review record) written, **not run**
  (bundles only after the re-review passes).
- Not changed (optional item declined): a
  `pace_evidence.py` upper-bound assert (the relay states the measured
  values). The stage-3b image and everything in it are unchanged.

**J-98 · Re-review of the consolidated FS-A-011 (`bf95cec`): not ready yet.**
- All `a011-findings` items closed; the code change is clean (cue text
  and comment only; host3b 116/116, host2 459/459); the image is
  unchanged.
- **3 MAJOR:**
  - (A) the relay cites the ORIGINAL FS-R-002 §4/§7, which is superseded
    by the revised FS-R-002 (binding: revised §6/§8);
  - (B) the r2 bundler drops 6 gitignored build records;
  - (C) **some CR-significant FSB1 fixtures (`valid-crlf`, `valid-pty`,
    `echo-only`, `valid-echo-prompt`) were committed with their CRs
    stripped by autocrlf**; the working copies are the true bytes. A
    repository-integrity fix: `-text` rules and re-staging the true bytes.
    The public copy needs the same fix.
- **Minors:**
  - the image-zip container hash will differ (members identical);
  - bundler hardening;
  - pin and working-copy CRLF drift for the host `.ps1` (add `eol=lf`;
    record the host-tool hashes in SIGNOFF A);
  - §6.1 scope ("no software-forced power-off via the thermal core";
    vendor and PMIC protection not assessed [O]);
  - the disclosure list of network reads; citation details.
- Fixes delegated. The bundle will be built only after a short
  verification.

**J-99 · Re-review fixes for the consolidated FS-A-011 (draft; NOT READY).**
- **FS-R-002 citation (MAJOR-A).** The relay now cites the binding revised
  FS-R-002 §6 ("Kernel-side protection remains a later investigation"; the
  known-writer diff is "an alarm rather than proof") and §8. The original
  §4 (five guard requirements) and §7 ("pinned during bring-up") are
  labelled superseded guidance, and the Chair is asked to confirm them. D2,
  ask 5, the Appendix and §6.2 ("FS-R-002 (revised) §4.C") are fixed.
- **Bundler (MAJOR-B, B1, B2).** FS-A-011 (private review record)
  (not run in the repo):
  - adds the six gitignored text build records explicitly;
  - uses the sent bundler's streamed write method;
  - derives the repo root from its own path;
  - requires the relay to be tracked and clean, handles rename records,
    and refuses a tracked file missing from the working tree.
  - **Dry run in a temp clone** (all changes committed there, the relay
    copied to FS-A-011 (private review record)): **952 raw files**, the same set as the
    sent bundle except the two renamed `r2` paths. The would-be raw zip is
    `e6825696…8c93` (3,012,086 B; indicative only, the relay and the
    JOURNAL will still change). The image zip is **`84b96292…781d`**,
    identical to the sent one, and `IMAGE-MANIFEST.sha256` is
    byte-identical.
- **CR-significant fixtures (MAJOR-C).**
  - `.gitattributes`: `devices/quest3/common/fixtures/fsb1/** -text`;
    `text eol=lf` for `devices/*/*/*.output.txt`, `devices/quest2/channel/fixtures/**` and
    `devices/quest3/host/*.ps1`.
  - Staged with their true CRLF bytes: `valid-crlf.txt` (22 CR),
    `valid-pty.txt` (23), `valid-echo-prompt.txt` (23), `echo-only.txt`
    (1). Each equals the `fsb1_mutate.py` output, and `valid-pty` equals
    `valid.txt` with ONLCR.
  - On the staged bytes (exported with `checkout-index`), Python
    `test_fsb1.py` 38/38 and PowerShell `test-fsb1.ps1` 38/38, with the
    cross-check 38 of 38; both RESULTS files are identical to the
    committed ones.
  - No other blob changes under the new rules (`hash-object` over every
    tracked file). Fifteen working copies were re-checked out as LF (blob
    unchanged): `fs-classify.ps1` (now `ed5d07ea…`), `test-host2.ps1`,
    `test-host3b.output.txt`, `stage1/test-host.output.txt`, the channel's
    `fixtures/host/RESULTS.txt` and ten other outputs.
  - `FSB1-SPEC.md`: `valid-pty` has 23 CRLF pairs.
  - `SIGNOFF.md` A: a new `Get-FileHash` step for the pinned host tools
    (SIGNOFF is not hash-pinned; its lines after 67 moved by 7, and the
    relay's citations were updated).
- **Found, not fixed (for the PM/coordinator): relay evidence damaged at
  commit by the same mechanism.** 94 tracked `-text` files under
  FS-A-004 (private review record), `-005-raw`, `-006-raw`, `-009-raw`, `-010-raw` and
  `devices/quest2/evidence/` (a baseline folder) [paraphrased for publication] have CRs in the working
  copy but none in the blob (they were committed before the `-text`
  rules).
  - 70 of the working copies match their relay manifests (the sent
    bytes); the other 24 are in no manifest.
  - A fresh clone therefore fails those manifests.
  - The fix would be `git add --renormalize` on exactly those paths, after
    checking each against its manifest. Not done: outside this request.
- **§6.1 scope (MINOR-1).** Now "no software-forced power-off via the
  kernel thermal core"; vendor notify hooks and PMIC/TSENS hardware
  protection not assessed [O]. `reboot.c:465`. The same scope is applied in
  the relay, `armadavr.md`'s box, the J-96 Corrections row,
  `devices/quest2/README.md` and `README.md`.
- **Wording (MINOR-2, MINOR-3):**
  - the §5 network reads and their source docs (index 109,892 B);
  - the send gate in §2;
  - byte-for-byte against LF;
  - pace chunk 2,178–2,234 B;
  - stale-comment split: the `test-host3b.ps1` comment and K43 string were
    fixed, and the C4 label now names the cue assertion;
  - `serial-loss-trial3.md`: every remaining cap assertion annotated;
  - PROJECT_SETUP §0.0: `vrconfig_write` is not new.
- **Tests after all changes:** `test-host3b.ps1` **116/116**,
  `test-host2.ps1` **459/459** (outputs copied as LF); FSB1 38/38 Python and
  PowerShell.
- New hashes: `test-host3b.ps1` `d03f4bd9…f7e3` (not pinned);
  `fs-collect.ps1` unchanged `2b90d641…`.

**J-100 · Relay evidence blobs restored to the bytes the Chair received.**
- Fixes the damage found in J-99: 94 tracked `-text` evidence files under
  FS-A-004 (private review record), `-005-raw`, `-006-raw`, `-009-raw`, `-010-raw` and
  `devices/quest2/evidence/` (a baseline folder) [paraphrased for publication] had CR-stripped blobs.
- **Check before the fix (Arbiter):** every one of the 94 working copies
  is byte-identical (SHA-256) to an entry in a sent relay zip
  (the private review records) and appears in a tracked manifest. J-99's "70 match,
  24 in no manifest" came from a narrower manifest lookup; against all
  tracked manifests and the sent zips, 94 of 94 match. All differences
  were CR-only.
- `git add --renormalize` on exactly those 94 paths (all already `-text`);
  each staged blob now equals its working copy (0 mismatches). A fresh
  clone now reproduces the sent evidence bytes.
- No other file changed. The public copy (`frameshift-public`) still
  needs its own fixture/evidence check before any further push [O].

**J-101 · FS-A-011 fix-round verification passed; relay finalised.**
- Independent read-only verification of the J-99 fixes and J-100 (HEAD
  `6e6ebba`): items 1–7 PASS; **no BLOCKER or MAJOR**. Dry run in a temp
  clone: 952 raw files; image zip `84b96292…781d`, identical to the sent
  one; every member equals its committed blob; the fsb1 fixtures keep
  their CRs in the zip. All 28 tracked manifests hold for `-text`
  evidence in a fresh autocrlf clone.
- **Fixed:**
  - MINOR-1: `README.md` cited the original FS-R-002 §4/§7 as binding;
    now the revised §6 is binding and §4/§7 are superseded guidance.
  - MINOR-2: `make-bundle.py` silently skipped a tracked file deleted from
    a walked folder; it now refuses (tested: a deleted fixture → refusal;
    the clean run → 952 files, image zip `84b96292…781d`).
  - NIT-1: the J-96 entry now carries the J-99 scope note.
  - NIT-2: the relay's change list mentions J-100; README status bumped.
  - NIT-3: `devices/quest2/analysis/v27-dt/** -text` (its `SHA256SUMS`
    failed on an autocrlf checkout; blobs unchanged, all OK).
- The relay moves to FS-A-011 (private review record); the bundles are built from this
  commit and their hashes recorded in the next entry.
- Public copy: only the same four fsb1 fixtures are CR-damaged there; the
  other 268 differences are sanitisation or later private edits. Plan: a
  fresh sanitised re-export after FS-A-011, reviewed, pushed only with the
  PM's OK [O].

**J-102 · FS-A-011 (consolidated) bundles built; READY TO SEND.**
- Built by FS-A-011 (private review record) from commit `a28679f`
  (clean tree):
  - FS-A-011 (private review record): 952 files + MANIFEST, 3,015,077 B,
    SHA-256 `0055df6dbe8a99bcab9cae72a95a88edea39761989e6c2985dbc4691c2725df0`;
  - FS-A-011 (private review record): 11 files + IMAGE-MANIFEST, 19,856,259 B,
    SHA-256 `84b962925981a3efd5ff5ecb3500c331ce2686fbe236878b6b6258fe047b781d` (identical to the sent image zip).
- Checks (Arbiter): every member matches `MANIFEST.sha256`; every tracked
  member equals its committed blob (the 13 others are the gitignored build
  records and `IMAGE-MANIFEST.sha256`); the relay in the zip equals
  FS-A-011 (private review record) at `a28679f`; no excluded path; fsb1 CR counts
  22/23/23/1; `fs-rpcd` `da19367b…`; `IMAGE-MANIFEST.sha256` equals the
  frozen sent one.
- The manifests are committed with this entry. The PM sends the relay and
  both zips to the Chair, replacing the incomplete sent draft. Awaiting
  FS-R-011.

**J-103 · Consolidated FS-A-011 sent.**
- PM report (2026-10-11): the relay and both zips were sent to the Chair
  (relay `8b385ab7…9952`, raw `0055df6d…25df0`, image `84b96292…781d`),
  replacing the incomplete draft. Awaiting **FS-R-011**. No device action
  until then.

**J-104 · FS-R-011 received: CONCUR EXECUTE trial (iii-b); distribution rulings.**
- Recorded verbatim: FS-R-011 (private review record).
- **§1 Trial (iii-b): CONCUR EXECUTE**, exactly: Unit 1, v66, slot
  A, one temporary boot, no flash, no retry, nonce `<attempt nonce withheld>`, image
  `ea60d6cd…5841`, the §1.1 host pins, DEADLINE 200 / backstop 201 s, the 91 s
  guard, the PM physically present. Two clarifications before the PM signs
  and before BA:
  - **A. Host dependencies:** `fs-proto.ps1` `52e007eb…`, `fs-native.ps1`
    `101ddfb1…`, `fsb1.ps1` `1f84c633…` join the pre-BA hash check.
    **Arbiter check: all three match** (working copy = committed blob; the
    FS-A-007 and FS-A-008 zip copies of `fs-proto.ps1` are also `52e007eb…`).
    Added to SIGNOFF A.
  - **B. "Dark gap"** reads as "a pause of at least 2 s, during which actual
    darkness is observed separately; run 2 executes only if its
    inactive-CRTC precondition is established". Recorded in SIGNOFF D (the
    pinned collector cue is unchanged and is read this way).
  - Also recorded in SIGNOFF: the dwell gate runs before attempt
    registration/launch (`DwellSec` and `DwellAtBootStartSec` already
    recorded by `fs-observe.ps1`); at ≥ 40 °C act at once, never wait for the
    manual schedule; shutdown and unplug are separate observations.
- **§2:** the Chair independently parsed the image and reproduced the C, FSB1,
  timing and preview checks [D]; `fs-pattern` `4c36e4d9…`. The PowerShell
  suites and the ARM programs under QEMU were not re-run by the Chair.
- **§3:** all six implementation choices ACCEPTED. Keep the raw reason when
  the CRTC precondition is unmet (never report ACTIVE=1 unless read); an
  admitted run 1 can establish the display milestone but not a full two-run
  PASS.
- **§4 Quest 2 channel:** ACCEPT continued offline work. Use UDC
  `a600000.dwc3` explicitly; keep "possibly partially sent" on a failed
  host send; FSB1 validation stays necessary. No Quest 2 execution.
- **§5:** [removed for publication]
- **§6 Thermal:** the J-96 finding is supported but "never fires" is too
  absolute (allocation failure or a disabled helper can still reach the
  forced fallback). Required wording: "The successful-no-op helper path
  supplies no dependable forced shutdown through the generic thermal core
  on this configuration." Quest 3: the delay schedules a power-off
  *attempt*, not a guaranteed power-off at 100 ms. Not a gate for trial
  (iii-b); it must inform the Quest 2 trial and Valve userspace.
- **§7 Distribution:** D1 ACCEPT (architecture, not a package or a legal
  conclusion); D2 RETAIN the revised deferral (write boundary before broad
  stock-service activation or automatic updates; guard gaps listed;
  investigate SELinux too); D3 ACCEPT (add the BLE programmer, the
  charger/NVM writer and systemd-repart to the writer inventory); D4 Unit 2
  installer may be scoped; [removed for publication]; D5 ACCEPT; D6 and
  D7 need **PM policy decisions** (below). Licensing correction: Valve's
  Frame download page presents the backup-image EULA.
- **§8:** before any action on Unit 2, establish its new fingerprint, slot,
  kernel and firmware inputs (do not reuse v71 identities).
  Before publication: repair the exported CR fixtures and verify the
  published tree's manifests and licensing/source material.
- **Open for the PM [O]:** (D6) whether licence-audited FOSS packages fall
  within the "no Valve binaries" exception; (D7) an explicit exception for
  the exact official recovery image (manifest branch main/OOBE) as the
  first-install base, plus the official 2026-10-08 stable article and its
  signed manifest.
- **Next device action:** trial (iii-b) on Unit 1, attended, when the PM
  connects it; one step at a time.

**J-105 · Private documents brought up to FS-R-011.**
- Delegated docs pass (18 files), checked by the Arbiter:
  - `PROJECT_SETUP.md` §0.0 (D1–D7 outcomes; open PM decisions D6/D7),
    §6A (thermal wording; Unit 2 re-baseline; licence obligations), §7;
  - `DEVICE_PORT_CHECKLIST.md`: new F7 (per-unit re-baseline), H8 (writer
    inventory: BLE programmer, charger/NVM writer, systemd-repart), H9
    (licence obligations: BusyBox, kernel, static glibc); **H6, H7 and the
    status matrix restored** verbatim from `e57ec2c` (commit `d58ef82`, J-86,
    had truncated the file by 34 lines; confirmed by diff);
  - research notes: `valve-packages-licensing.md` (Frame download page
    presents the backup-image EULA; the "Deck terms" claim struck),
    `valve-image-slot-in.md` (D1–D7; "recovery is always to
    Horizon" struck), `thermal-control-design.md` (§6 wording; risk R10),
    `community-quest-repos-2.md`;
  - Quest 2 channel README and PORT-PLAN (§4); Quest 3 README, stage3b
    README/IMAGE.md, RECOVERY.md, host README (trial (iii-b) concurred, not
    run); root README (resume steps); a pre-publication audit
    (private) [paraphrased for publication].
- `SIGNOFF.md` D: the FS-R-011 §3 reading rules (CRTC label scope, skipped
  run, cut stream, run 1 milestone vs full PASS, separate reporting).
  `common/OUTCOMES.md` is left unchanged (part of the reviewed package); the
  §3 widening is carried by SIGNOFF and goes in the trial report.
- Claims checked: every stage image carries BusyBox and the stock kernel;
  our helpers are static glibc (`common/build-record/BUILD.txt`,
  `stage3b/BUILD-RECORD.txt`: `libc6-dev-arm64-cross 2.43` static).

**J-106 · Public re-export; PM public-scope directive and audit.**
- PM: "Go ahead with the public re-export." Built as an incremental 3-way
  merge of private `ec8a523..40b569f` onto the sanitised public tree, with
  the mechanical sanitiser and marked prose sanitisation. It also includes:
  - the CR fixtures restored (22/23/23/1 CRs);
  - local times converted to UTC;
  - `docs/PUBLIC-MANIFEST-CHECK.txt` (FS-R-011 §8), which classes every pin.
- First adversarial review: tree PASS. Its BLOCKER was the local WIP commit
  history (test identity, local dates, unsanitised WIP). The public push is
  always one fresh commit with the agreed identity and UTC dates.
- **PM directive (2026-10-11):** the public record contains **no mention of
  unlock methods, unlock results, rooting, or anything exploit-related**;
  only the SteamOS-port dev work, builds and procedures, for a reader who
  already has an unlocked headset.
- **Audit:** 507 rows in 118 files (four read-only auditors). Results in
  `docs/public-scope-audit/` (private, never exported).
- **PM decisions:**
  1. withhold the root-based tools, keeping the safety rule;
  2. drop all lock-state lines;
  3. rename the build-type label to "v66 (Unit 1)" in the public copy;
  4. withhold all anti-rollback / update-path research.
  The Arbiter defaults in the report apply.
- Nothing is pushed until the edits are applied, a fresh adversarial review
  passes and the PM approves the push.

**J-107 · Trial (iii-b) run (FS-R-011 §1): first light on the Quest 3 panel; run 2 lit but garbled.**
- Unit 1, v66 slot A, image `ea60d6cd…5841`, nonce `<attempt nonce withheld>`, PM present.
  Full record: FS-A-012 (private review record) (attempt log, captures, observe/collect,
  readings, classifier, misc rule, signed sheet).
- **Sequence (UTC, 2026-10-11).** Settled pair 250 (18:48:10) / 250 (18:58:41),
  stable. BA 19:01:41.57 (100 %, 250); BF 19:02:48 (`current-slot: a`).
  Presence confirmed in chat. Attempt 19:04:20.83; dwell 159.3 s at
  BootStartUtc. `fastboot boot` rc=0, HANDOFF_ACKNOWLEDGED, Th 19:04:31.99;
  gadget at Th+9 s.
- **Collector:** COLLECTED-VALID, **FSB1 VALID** (capture.raw 103458 B
  `ff90fea6…`), `FSD1 queued END`. AF 19:07:05. AA 19:09:00 (300).
  Follow-ups: 300 at +5 min, 300 at +10 min (not rising; highest observed
  300). No shutdown was needed.
- **Classifier:** STAGE-1 PASS. **Machine side PASS** (OUTCOMES §9 rule 25):
  - run 1 committed and closed on a CRTC already active (`crtc_active=1`);
  - run 2 committed from an inactive CRTC (`crtc_active=0`, show-off) and
    held;
  - pause 2278 ms; brightness 127 written once and read back before both
    runs.
  **OPTICAL: LIT BUT GARBLED; LABEL: RUN 1 DARK, RUN 2 LIT.** Not a stage
  PASS (the stage needs all 8 characters read in each eye).
- **PM readings** (verbatim in `readings-notes.txt`): "I *think* run 1 was
  dark, both eyes. I *think* run 2 was lit, but garbled, both eyes." No beeps
  were heard (host console beeps). The PM's later description: the image
  looked "almost like a raw LCD pattern" (fine regular red/green/blue
  stripes; a similar reference image is saved, not a capture). The PM could
  not tell whether the panel went dark before or at the reboot; phase
  boundaries were not distinguishable.
- **Persistent state:** devinfo identical. BA11/AA11: every hashed
  partition identical except `misc` (boot, vendor_boot, dtbo, vbmeta, abl
  on both slots, devinfo, pstore). Misc rule RECORDED: boot command
  unchanged; vendor field 0x1010–0x101b changed (the field the stock
  control changes). BF/AF identical except timing lines.
- **Reading [D]:** the panel can be lit from our boot, but only by a full
  inactive→active modeset (run 2). A commit onto the CRTC state the
  bootloader handed over (run 1) gave no light. The garble suggests a
  format mismatch between our frame and what the panel/DSI path expects
  (compression, pixel format or stride) [C]; it is analysed next from the
  captured probes.
- The signed sheet was saved as `signoff-as-signed.md`:
  - signature "PM", 12:03 PDT = 19:03 UTC, after BF and before the attempt;
  - section B values were not written on the sheet (they are in the attempt
    log); the C and F lines were left unticked;
  - the template is restored.
- **PM decisions after the run:**
  1. Next run uses **live phase markers from the headset** (the image
     prints a marker at each phase boundary; the PC shows a coloured banner
     and plays a sound for each, in real time). The preflight plays a test
     sound the PM must confirm hearing.
  2. **Analyse the captured data first**, then decide what the rerun tests.
  3. **PM executive decision: subsequent runs are authorised without a
     relay first.**
- **Arbiter scope for decision 3** (stated to the PM):
  - Covered: repeat/diagnostic temporary `fastboot boot` runs on Quest 3
    Unit 1 in the current stage line (never flashed).
  - Each run still needs: an independent adversarial review of every new
    image and host-tool change; a fresh nonce typed by the PM; the image
    deadline and backstop; read-only probes; the settled pair; the dwell
    gate; AF/AA; the ≥ 40 °C rule; the PM present with sign-off; one step
    at a time.
  - No writes beyond the reviewed backlight value; FS-R-001 intact.
  - Still to the Chair first: any flashing, Valve userspace, any Quest 2
    run, a new write class, firmware changes.
  - The results go to the Chair afterwards in FS-A-012, disclosed as a PM
    executive decision.

**J-108 · Garble analysis; first-time-reader test of the public copy; doc fixes.**
- **Garble analysis** (offline, read-only; record decoded VALID):
  - run 2 committed mode `4128x2208x90vid`, XR24 linear, as **2 planes of
    2064** (split layout);
  - stock Android uses **4 DMA pipes of 1032** (one per mixer, UBWC) at
    core_clk 503 MHz (= 1032 × 5158 × 90 × 1.05);
  - a 2064-wide pipe needs ≈ 1.006 GHz against the 550 MHz MDP maximum
    [D], so pipe starvation corrupting the DSC stream is the leading
    hypothesis;
  - a flat grey field can't become RGB stripes through a format or stride
    error [D];
  - run 1: TE 0 before and during (the panel was handed over asleep; the
    splash handoff sends no panel-on), and run 1's close reset the panel,
    so run 2's enable woke it (TE ≈ 181/s, the stock rate).
  - Next-run proposal: 4 planes of 1032 (split as fallback), more read-only
    logging (post-commit state, a larger blob buffer, a wider dmesg filter).
  - The analysis read strings from the stock recovery UI library (private
    analysis only; never published).
- **PM proposal: an interactive per-phase flow.** The host runs a phase,
  then prompts for single-key per-eye readings (a lit / b dark / c garbled /
  d read). Arbiter guardrails:
  - prompts only while the panel is off; lit holds are device-enforced;
  - per-prompt timeout leading to a safe finish; an abort key;
  - timestamped answers.
  This needs a per-phase protocol (one command and one record per phase),
  so it gets a full review. Awaiting the PM's confirmation that one-handed
  key presses work.
- **First-time-reader test** (PM idea): a fresh agent read only the public
  candidate, then answered an 18-question quiz, about 17.5 of 18 correct
  with citations.
  - Gaps found: stale dates and labels, the runner guard as 97 s instead of
    91 s, undefined jargon, the Chair's nature unstated, the FSB1 suite
    wrongly listed as refusing, the Quest 2 "never flashed" wording, and no
    outsider quickstart.
  - Replication is limited by the withheld capture tooling.
  - Fixed in the private repo (README status/state/glossary/Chair
    description, relays index, PROJECT_SETUP [C] tag and pointer, SIGNOFF
    wording) and in the public candidate (also a quickstart, a plain status,
    an architecture overview and a contributing section).

**J-109 · Display research; stage-3c design drafted; PM decisions; second reader test.**
- `docs/research/display-pipeline-and-geometry.md` (new):
  - **Why run 2 garbled.** Meta's 5.10 SDE driver doesn't check per-pipe
    throughput; clock and bandwidth are votes the userspace client passes in
    (unset means maximum, 550 MHz). With 2208 active lines in a vertical
    total of 5158, each plane must deliver its width every 2.154 µs, which
    caps a plane at about 1128 px at 550 MHz. Our 2064-px planes need about
    1.0 GHz [D]. Mainline DPU splits planes by the same rule [M-static].
  - **Precedent:** `machachu56/quest-kexec-q2`, Quest 2 through the stock
    driver. One plane across both mixers gave "rows of small purple
    blocks"; one half-width plane per mixer, XR24 linear, displayed
    correctly (licence to be checked before any reuse).
  - **Ruled out:** UBWC and AB24 are not required. DSC and topology come
    from the device tree, and `qcom,disable-default-pps` means no PPS is
    sent.
  - **Stock layout:** Android uses DMA pipes as two half-pairs; the splash
    uses VIG0–3, planes 71/97/100/103.
  - **Geometry:** panels mounted 180° plus about 21° roll
    (`bootloader_screen_rotation=201`); lens axes are offset toward the
    nose and upward. Compensation belongs in the runtime (eye-to-head
    transform, projection, distortion); per-unit calibration is in
    `/persist` (names only). Valve has published no Frame geometry format.
  - **Next:** D1, 4 × 1032 with explicit zpos (2 × 2064 as a TEST_ONLY
    probe only). D2, read-only underrun counters, which need a debugfs
    mount (a new action class). D3, a marker per quadrant plus chiral
    markers and a centre line per half.
- `devices/quest3/stage3c/DESIGN.md` drafted:
  - interactive per-phase protocol (`fs-phase`, one FSB1 record per phase,
    chained by `prev16`);
  - live `FSPM1` markers, banners and generated sounds, a blind sound check
    and a one-handed key test;
  - run 2 with 4 planes; run 3 a red field, only if run 2 is garbled;
  - DEADLINE 200/201 s unchanged, plus an idle watchdog;
  - read-only logging.
  It is to be revised with the research, then adversarially reviewed.
- **PM decisions:**
  1. Explicit **zpos** is part of the reviewed commit (a standard property
     in the same atomic commit, runtime only); disclosed in FS-A-012.
  2. **No debugfs mount in this run**; the read-only underrun read is
     proposed to the Chair in FS-A-012 for later runs.
  3. PM report: run 2 showed **no structure at all** in the garble.
  4. PM: **AI use is disclosed publicly**, models named (Claude Opus 5.5 as
     Arbiter, ChatGPT Sol 6.1 as Chair).
  5. PM agrees to the interactive flow, and wants a **standing concurrence
     for repeat runs** asked of the Chair in FS-A-012.
- **Second first-time-reader test:** 20/20 correct after the fixes.
  Remaining stale lines and jargon fixed in both repos (pacing rate per
  stage, FSB1-SPEC usage, stage-3b and recovery status, SIGNOFF title,
  editor's notes on the superseded device order and the code-block rule,
  PROJECT_SETUP §6A order, glossary rows, a single status source).

**J-110 · Public re-export pushed (private repo): single commit `2158d06`.**
- After the scope edits (J-106 decisions) and the final adversarial review,
  the first-time-reader tests (17.5/18, then 20/20) and their doc fixes, a
  targeted review of the new text found two MAJOR factual errors, both
  fixed:
  - "physically present for every boot" now says "required to be", noting
    the trial (i) remote-run deviation;
  - a wrong "there is no §0.1".
  Minors and nits were fixed in both repos.
- One orphan commit, `2158d06`: 1167 files, tree `e29912fd…`, identity
  the PM's first name [removed for publication] with the GitHub noreply address, dates +0000.
  Message: "initial public import", private HEAD 40b569f plus later
  documentation fixes, AI-assistance note.
- Checks: the local scratch history is unreachable; a scan of all objects
  found no serials, personal e-mail, local paths or out-of-scope terms
  (the only name hits are the approved commit identity).
- **PM chose to force-push** over the first export (`7b14e15`), rather
  than delete and recreate the repo. Pushed: `main` = `2158d06`; the repo
  stays **PRIVATE**. Note for the public flip: GitHub may keep the replaced
  commit reachable by its id until garbage collection.
- The local `frameshift-public` was reset to `origin/main` (the same
  tree).
- Next public steps: the PM flips the repo public when ready; add the repo
  link to the Valve letter; later exports use `<private export tooling>` (base
  `40b569f`).

**J-111 · Stage 3c built, integrated, build-reviewed and fixed; candidate `9d3ad984…`.**
- **Design reviews:**
  - R-A on rev 2: B1, zpos 0×4 aliases the right pair onto an unconfigured
    stage, so zpos is now {0,0,1,1}; M1, pipe type is told by max_upscale
    (VIG 20, DMA 1); M2, CRTC_X reads back converted for the right half;
    M3, FSXE1 carries ran=0|1; M4, the dot-source parameter hazard. Run 3
    holds 5 s.
  - Revision 3 committed (`efd18dc`). Kernel source: zpos_max 10, multirect
    auto PARALLEL.
- **Build** (two parallel halves, then integration, `71f9d62`/`90b5e96`):
  - device: fs-pattern v0.6, per-phase scripts, idle watchdog, FSPM1/FSXE1;
  - host: collect3c, session3c (banners, sounds, keys), classify3c,
    observe3c;
  - list encoding unified (`.`); 24 device scenarios replayed end to end.
  - CR bytes in the scripted keys.txt files were stripped at commit; fixed
    with -text rules (`cc58cc0`).
- **Build reviews:**
  - R-B device: safety invariants PASS; MINOR, a pre-mkdir refusal did not
    close the session; MINOR, the timing model omitted the END pass and the
    cold run.
  - fs-pattern review: code PASS, mutants caught; policy wording, run 1
    keeps the reviewed 2×2064 wake commit (the TEST_ONLY rule applies to
    runs 2/3).
  - Rebuild/mutation review: bit-identical; four test gaps (the
    refusal-closes rule, a silent second backlight write, idle writing to
    the tty, a disguised debugfs mount).
  - R-C host: MAJOR-1, lit phases were not gated on p0 integrity; MAJOR-2,
    Ctrl+C / closed console; MAJOR-3, a false run-3 runner inconsistency;
    plus ten minors (key repeat, `d` then timeout, summary shown before the
    notes, step order, QuickEdit, …).
- **All fixed:**
  - PHASE_WORST 23/38/47/39, so W + 0.5 s; guards G 34/68/82/64;
    DEADLINE 200 / backstop 201 unchanged;
  - integrity gate before run 1; Ctrl+C acts as x; readings checkpointed;
  - harness inotify on the backlight write; tty-byte accounting; a builder
    mount whitelist and a tty grep;
  - every surviving mutant is now caught.
- **Suites:** fixtures 136, builder 16, image 25, pace 63, timing
  CONSISTENT; host 294 (test-host3b 116 and test-host2 459 identical before
  and after).
- **CANDIDATE** image `9d3ad98400ac94f42b291a66b0420576df5ad8ee447e831d971fcaba9bd914bd`,
  nonce `<attempt nonce withheld>`, fs-pattern `066bdc3e…`. Withdrawn unbooted:
  `e1856cd2…` (nonce 3296cd623cc7da0f).
- **Next:** a verification review of the fixes; then the PM's rehearsal,
  sound check and key test; then the attended run (PM executive decision,
  J-107).

**J-112 · PM report: Quest 3 Unit 2 now on v2.7; stage-3c readiness.**
- PM (2026-10-12): "Q3u2 is on v2.7 now. Still has some panel issues due to IAD constructor
  crash, but I think we can either work around that or ignore it completely. If it proves to be
  an issue, we'll adjust." [PM report; the panel issue's cause is the PM's attribution, [O]].
  Before any FrameShift action on Unit 2: read-only baseline (fingerprint, slot, kernel,
  effective firmware inputs) per FS-R-011 §8; v71 identities are not v2.7 identities.
- Stage 3c: R-D verification READY (`113e87a`); then repeat window 600 ms, console-mode restore
  order, tap-don't-hold instruction, re-pinned fs-session3c (`81a96f0`). Host pins (14) checked
  and preflight OK for candidate `9d3ad984…` nonce `<attempt nonce withheld>` (no device action). PM
  sound check / rehearsal next.

**J-113 · PM sound check passed; rehearsal NO-GO (bar prompts); prompt fixes paused overnight.**
- **Sound check:** PASSED (`captures/<attempt nonce withheld>/soundcheck.json`, Pass true): all five
  sounds heard, the three blind sounds named, every reach key pressed one-handed.
- **Rehearsal** (replay of `garbled-r3`, real keys): every banner, sound, prompt, dark check and
  the safe finish worked; 11 readings saved.
  - The PM answered "garbled" throughout. Run 1 answers 16.4 s, run 2 50.2 s, total 66.6 s:
    **NO-GO** (> 40 s).
  - The two bar-count prompts took about 48 s. **PM feedback:** the bar question was not
    understood (what it referred to, how to answer); `n = light STILL visible now` on the
    eye prompts was confusing (it only makes sense at the dark check).
- **Decided:**
  - Apply the reviewed Q7 fallback: no bar prompts on the run-3 path.
  - Any bar prompt that remains must explain itself in its own text.
  - `n` is shown only at the dark check; `x` stays on every prompt.
  - Eye prompts become shorter.
- **Paused** at the PM's request (end of day): the agent applying these changes was stopped
  mid-change. Its partial, untested edits are on branch **`wip/q7-prompt-fallback`**
  (`a3959ce`); `master` is the clean, reviewed state (`81a96f0` package).
- **Resume:**
  1. finish the change from the WIP branch (or redo it), with tests, re-pins and a short
     review;
  2. the PM redoes the rehearsal (answers: run 1 b, b, y; run 2 c, c, y; run 3 s, s, y; s),
     which must be GO;
  3. connect Unit 1 for the attended stage-3c run (candidate `9d3ad984…`, nonce
     `<attempt nonce withheld>`; host pins and preflight already OK; redo both if any host file
     changes);
  4. Unit 2's read-only v2.7 baseline (FS-R-011 §8) when convenient.

**J-114 · Prompt changes finished and reviewed (Q7 fallback + PM feedback); merged.**
- The interrupted change (J-113) was finished on `wip/q7-prompt-fallback` (`f11433e`) and then
  reviewed adversarially: **GO, no safety regression**.
  - On the run-3 path no bar prompts are asked (recorded NOT_ASKED; the classifier writes a
    READINGS NOTE, never INCONCLUSIVE).
  - Where bars remain (run 3 does not follow: rules 1, 2 or 3 fail), the prompt explains
    itself. After review it now reads "next to each of the two F letters (below it when
    upright) … 1 to 4 bars".
  - `n` is shown only at the dark check; `x` stays on every prompt; `n` during a lit run is
    still taken as `x`. Eye prompts are shorter.
- **Accepted, to disclose in FS-A-012** (data loss only, no safety cost):
  - bars are skipped on the rules 1–4 decision even when run 3 then does not happen (rule 5
    G3 refusal, "no longer possible", x/timeout before the r3 send);
  - light seen at an eye prompt is now recorded as an abort (x), so the dark check that
    follows is the retained-frame evidence, not a LIGHT_NOW reading.
- Also: eol=lf rules for the pinned stage1/common host helpers (`fs-proto.ps1`, `fsb1.ps1`;
  blobs already LF; a fresh checkout would otherwise fail their pins, safely).
- Tests: test-host3c 298/0 (+1 regression skip; Y1 stage-3b unchanged); the full -Regression
  run before the last wording fix was 302/0 with test-host3b 116 and test-host2 459 identical.
  `fs-session3c.ps1` re-pinned in SIGNOFF-3c A.
- Merged fast-forward into `master`; the WIP branch was deleted.
- Next: PM rehearsal 2 into `captures/<attempt nonce withheld>/rehearsal-2` (must be GO), then the
  attended run (host pins and preflight to be re-run first, since host files changed).

**J-115 · Unit 1 cycle stood down (PM at work); Unit 2 v2.7 read-only baseline; offline work started.**
- **Stage-3c cycle `<attempt nonce withheld>`:**
  - Settled pair failed: 230 at 15:52:25 → 250 at 16:02:57 UTC; the battery was charging
    from 90 to 96 %.
  - The PM had to leave (remote for about 8 h), so the cycle was stood down **before BA**:
    no capture was taken and the nonce is unspent.
  - The host pins, preflight, sound check and rehearsal 2 (GO) remain valid unless host files
    change. The PM was given the OK to power Unit 1 off.
- **Unit 2 baseline (FS-R-011 §8), read-only adb, 16:10 UTC:**
  `devices/quest3/evidence/unit2-v27-baseline-20261012/` (devices, full getprop, uname,
  /proc/version, /proc/cmdline, battery, by-name list, /proc/partitions, SHA256SUMS).
  - Build `52433670036000520` (= v2.7), type **user** (release-keys; was v71 (Unit 2)).
  - **Slot `_a`** (was `_b`); kernel `5.10.246-gd7102a837402` (the v2.7 build target).
  - vbmeta digest `66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a`; battery
    98 %, 18.0 °C [M].
  - Not captured: `fastboot getvar all` (needs a reboot to the bootloader, a state change; PM
    OK required).
  - v71 identities are superseded. Unit 2 is now the candidate for true v2.7 trials, but tooling
    that relied on v66 (Unit 1) may need adapting [O].
  - PM report (J-112): panel issues from an "IAD constructor crash".
- **Offline agents started:** the FS-A-012 draft (the private review records, not ready), the
  quest-kexec-q2 licence check, the Unit 2 baseline script, the graceful-shutdown/thermal
  design, and the Valve writer inventory (FS-R-011 D3).

**J-116 · Offline block while the PM is at work: FS-A-012 draft, writer inventory, shutdown design, evidence-tracking fix.**
- **FS-A-012 draft** (the private review records, NOT READY): §1–§4 and §6–§8 written; §5 (stage-3c
  run) open.
  - Review 1 found a bundle BLOCKER and five MAJORs: the missing FS-R-010 §2 caveat; frame
    counters not "0 at every point" (post1 fps 0.2, frame_count 1; post2 frame_count 1); stale
    licence lines; ask (b) scope; ask (d) contradiction. All fixed (`ef73d40`).
  - New observation: run 2's BLU rate was about 106/s against TE about 180/s (stock: about
    182/s for both) [M]; its meaning is [O].
- **Evidence-tracking BLOCKER fixed:** `.gitignore` `captures/` and `*.img` had silently
  excluded relay evidence. 65 FS-A-012 files and 59 FS-A-009 (trial (i)) capture files had
  never been committed; the FS-A-009 files are byte-identical to the sent zip.
  - Exceptions `!relays/*-raw/captures/` and `!relays/*-raw/captures/*.img` added; all files
    committed byte-exact (`d8992e2`, `d957fb1`).
- **Valve writer inventory** (`docs/research/valve-writer-inventory.md`, FS-R-011 D3):
  - 36 writers plus 15 uncalled tools; unit masks plus whiteouts contain only 10.
  - Highest risks on a Quest:
    - `format-device.sh` accepts any `/dev/sd[a-z]` (on the Quest, the boot-chain LUNs);
      polkit allows it without a password, and steamos-manager FormatDevice and the Steam
      client reach it;
    - `driver_cv.so` (GPIO/SPI, controller firmware updater);
    - `steamvr-program-ble.service` (nRF52 mass-erase/flash; can run a `/home` copy);
    - `restore-calibration` (`blockdev --setrw /dev/sdd*` plus mke2fs);
    - `systemd-repart`.
  - The charger NVM writer is lower risk than previously summarised (the NVM commit is
    commented out in 0.3.0).
  - Valve userspace therefore needs a polkit deny set, a device-node policy and the block
    guard, not masks alone. 12 open gaps.
- **Emergency-shutdown / thermal-ownership design** (`docs/research/emergency-shutdown-design.md`
  rev 1):
  - single owner `fs-thermald`, tiers, graceful sequence, a stage thermal guard;
  - new facts: the Quest 2 v2.7 DT has no critical trip; the Quest 3 has no SoC watchdog node;
    an unclean reset with dump mode armed lands in crash-dump (RECOVERY.md already covers
    `05c6:900e`).
  - Review 1: **NO-GO**. B1: after a failed `reboot(POWER_OFF)` the caller do_exits while
    holding `system_transition_mutex` and the other CPUs are stopped, so no userspace fallback
    can run and the S1 guard could disable PID 1's DEADLINE reboot. M1: the softdog stays armed
    through POWER_OFF. M2: a hot runaway was ignored for 120 s. M3: RESTART into Android is
    unsafe for flashed images.
  - Revision 2 is in progress. Current stage images are unaffected (their end path is a clean
    reboot to the bootloader).
- **quest-kexec-q2 licence:** GPL-2.0 (Monado driver BSL-1.0); citation only, closed.
- **Unit 2 read-only baseline script** (the Unit 2 baseline script (private)): allowlisted,
  13 offline scenarios pass.
- Stage-3c docs: FS-R-010 §2 wording for run 1 (no "known dark"); status lines say the reviews
  are done.

**J-117 · Emergency-shutdown design: rev 2 re-review GO for presentation; rev 3 (`a1e1f3c`).**
- **Rev 2:** review-1 findings applied.
  - No userspace fallback after a failed POWER_OFF. In stage images PID 1 is the sole reboot
    caller (the guard writes TRIP; PID 1 execs `fs-poweroff-final`; PID 1's exit panics into a
    lock-free restart).
  - The softdog survives POWER_OFF, with a pet deadline.
  - Hot-runaway rule; initramfs thermal gate.
  - New facts F18–F24. F18: the Quest 2 4.19 CPU-stop leaves CPUs online, so the msm watchdog
    bites in about 12–21 s.
- **Re-review 2: GO for presentation** (not a device GO). Eight minors were folded into rev 3
  (`a1e1f3c`, F25–F30):
  - `Conflicts=shutdown.target` for the shutdown detector;
  - `CapabilityBoundingSet=~CAP_SYS_BOOT`;
  - JobTimeoutSec on every shutdown target; soft-reboot and halt masked;
  - RT-priority hardening (the CAP_SYS_NICE bypass is certain);
  - the gate uses T3's exit rule;
  - PID 1 checks TRIP first;
  - a guard-alive check;
  - `download_mode`=0 as the precondition for the softdog in S1.
  - Declared residuals: R11/K5, R12, R13, O6, R21, R22.
- **For the PM (decision box at the top of the design):**
  - P12 budgets; P13 warning; P14 unplug notice; P15/sysrq-c (Chair);
  - P16 Quest 2 stage-guard limits; P17 softdog margins;
  - the `pid1-hold.sh` change (design and harness only);
  - opening the softdog in S1;
  - Quest 3 tsens/ADC loads (deferred).
- **For the Chair:** the new action classes (power-off syscall, softdog open, sysrq, systemd
  hardening, module loads). They go in a later relay; nothing here authorises device use.

**J-118 · PM decisions (D6, checklist, Meta thermal config, backups); repo public; Frame protections research.**
- **Public repo made PUBLIC** (PM OK: "If you feel the repo is ready to be pushed public, I am okay
  with doing so"): `continuumxr/frameshift`, single commit `2158d06`. Caveat noted: the replaced
  first export `7b14e15` may stay reachable by id on GitHub until garbage collection (unlinked).
- **D6 (PM):** "If a package is truly FOSS, then we can include them" → licence-audited FOSS
  packages are allowed (with their notice/source obligations for anything we ship); proprietary
  components are not redistributed.
- **D7:** the PM asked for research into Valve's update channels (stable, beta, main, …) and prefers
  whichever Valve recommends for general users; research agent started
  (`docs/research/steamos-update-channels.md`). Decision pending that research.
- **Checklist (PM):** replace the sign-off sheets with a **checklist in the console** for the
  remaining runs (the PC tool asks each confirmation at the right moment and records the answers
  with timestamps); disclosed in FS-A-012. PM question answered: the sheet is a pre-flight
  checklist and record for the Chair, not a liability instrument.
- **Shutdown design (PM):** follow Meta literally where hardware-specific: our supervisor reads
  Meta's thermal configuration from the user's own headset at runtime and applies Meta's
  thresholds and mitigation order; nothing of Meta's is copied into the repo; fixed values only as
  fallback. Design to be updated (rev 4).
- **Backups (PM):** no further backups of any current unit; all necessary information and
  partitions are captured. Unit 2's `getvar all` waits until the PM is home.
- **Valve letter:** still recommended (proprietary components and the EULA's open
  runtime-overlay question; goodwill); the repo link can now be added. ArmadaVR: the PM has
  contacted the owner, no reply yet.
- **PM rule:** every decision needing the PM is asked in chat, not buried in relays/docs (memory).
- **Frame protections research** (`valve-writer-inventory.md` §6): the Frame has no polkit deny set
  (all 26 Valve actions `allow_any=yes`), no device-node policy (GPIO/SPI/nvmem opened on purpose),
  and a soft block guard (initramfs `blockdev_ro` on sdb/sdc/sdd, undoable). Valve's model: root
  is trusted; guards prevent accidents and are owner-removable. **The hazards are Quest-specific**
  (Frame device names land on Quest boot-chain LUNs; we replace Valve's initramfs, so even its soft
  guard is absent). Recommendation: narrow 1 and 2 to the Quest-specific hazards; keep 3 scoped to
  Quest boot-chain/unit-unique partitions, with an owner opt-out Valve code cannot trigger.

**J-119 · PM decision: Quest-specific protections only; Discord community; private community note.**
- **PM decision (protections):** keep Valve's open model ("root is trusted"); protect only
  against Quest-specific hazards:
  - deny the few Frame-specific polkit actions that would reach Quest boot storage (format,
    restore-calibration, factory reset, update/branch, udisks system-disk);
  - remap or mask the Frame-numbered device-node rules (grant the Quest nodes a working feature
    needs; charger/battery writes reserved to our supervisor per §6A);
  - one boot-chain write guard covering only the Quest bootloader and unit-unique partitions, on
    by default, with an owner opt-out that Valve code cannot trigger (a FrameShift boot flag,
    not `blockdev --setrw`).
  - Basis: `valve-writer-inventory.md` §6. Goes to the Chair with the D1–D3 follow-up.
- **Community:** the PM started a Discord server for SteamOS-on-Quest porters (mostly kexec on
  locked headsets).
  - [removed for publication]
  - Rule: share public-scope material only; never quote private messages publicly without
    permission.
- **In progress:** update-channel research (D7); the console checklist (branch
  `feat/console-checklist`, review to follow); shutdown design rev 4 (Meta config read at
  runtime).

**J-120 · PM direction: a compatibility (translation) layer after a bootable image.**
- PM: "once we have a bootable image, if we find that Valve's software commands can actually be
  tied to Quest commands, then we can write a translation layer?" Agreed, and recorded as the
  planned hardware-compatibility approach (PROJECT_SETUP §0.0):
  1. standard Linux interfaces exposed by Quest drivers;
  2. thin adapters for Frame-specific names and paths;
  3. SteamVR/OpenXR driver plugins for tracking, controllers and display.
  - Dangerous actions are blocked, not translated.
  - Behaviour is learned from public interfaces and runtime observation only; no disassembly.
  - Fits FS-R-011 D3's preference for documented additive integration. Starts at Stage 2.

**J-121 · D7 decided (PM); design principle "as close to SteamOS as possible"; 0.4 stable identified.**
- **Update-channel research** (`docs/research/steamos-update-channels.md`):
  - `stable` is Valve's public release (stable key, CN=steamdeck-images), recommended for most
    users.
  - beta, preview, rc and main use the dev key (`main` is the development head).
  - The recovery image is official rc 0.3.0 content filed under `main` (with `skip: true`); its
    own manifest defaults to `stable`.
- **PM decisions (D7):** stable now, with beta opt-in soon. Then the PM: "Ideally we would allow
  whatever is available in SteamOS out-of-the-box … We should *try* to keep the experience as
  close as possible." Hence:
  - default **stable**;
  - the user may choose any channel Valve's Frame UI offers (beta, and preview if offered);
  - verification mirrors Valve's own updater (the stable key for stable, Valve's dev key for
    beta/preview, as Valve's client does), which replaces the stricter "never trust the dev key";
  - a FrameShift notice on non-stable builds not yet checked against our layer (not a block).
- **Standing design principle (PM):** match Valve's out-of-the-box behaviour; depart only where
  Quest hardware forces it (e.g. the J-119 boot-storage protections).
- **0.4 stable identified** (PM-approved metadata fetch, ~86 KB public, no credentials;
  `docs/research/steamos-stable-0.4-metadata/`):
  - build `20261007.6125817`, version 0.4.5, branch `stable`, variant `vr`; stamped
    2026-10-08 23:21:16 UTC, 2 minutes before Valve's post "SteamOS 0.4 for Steam Frame"
    (the match is a deduction).
  - Signature: Valve publishes no separate file; it is inside the `.raucb` tail. A range read of a
    few KB needs PM approval. Stable key in the rootfs `ba942c60.0`, fingerprint D5:62:FE:…:02:D9.

**J-122 · PM decisions: shutdown settings approved; Meta config method; bundle download; letter on hold.**
- **Shutdown design (PM, all approved as recommended), for design and harness work only:**
  - P12 budgets (Valve userspace 45/55 s, stage ≤ 3 s, early jump if rising);
  - P13 user-visible warning (SEVERE, any fault, 10 % battery);
  - P14 "unplug" notice;
  - P15 / sysrq-c instant restart if the final power-off returns (also needs the Chair);
  - P16 Quest 2 stage-guard limits 60/40/45/40 °C (confirmed against Q2-P1 idle readings first);
  - P17 softdog margins 30 s, provisional;
  - the `pid1-hold.sh` TRIP-first change;
  - the softdog opened in S1 (Quest 3 only after T0 reads `download_mode`=0).
  - Quest 3 tsens/ADC module loads deferred. Nothing runs on a headset without its own review
    and the PM's sign-off.
- **Meta thermal config:** read-only user-space parse of the vendor partition (option B, no mount,
  no device-mapper); unreviewed versions use the built-in values and tell the user (P18).
  Design rev 4 (`2ca58e6`) is to be adversarially reviewed.
- **Bundle:** the PM approved downloading the full 0.4.5 stable `.raucb` ("may also be useful in
  the future") to verify the signature. Kept in the gitignored firmware area, never committed or
  published.
- **Valve letter:** "Not yet".
- **Console checklist:** branch `feat/console-checklist` (`84f49ba`); test-host2 459/459 from
  the main checkout (the 2 worktree failures were an environment artefact). Adversarial review
  next, then merge.

**J-123 · 0.4.5 signature verified; shutdown rev 4 reviewed; credits list; Meta identifiers allowed.**
- **SteamOS 0.4.5 stable signature VERIFIED** (PM approved the full bundle download;
  `docs/research/steamos-stable-0.4-metadata/SIGNATURE-CHECK.txt`, `c032e0a`):
  - `deckard-stable-20261007.6125817-0.4.5.raucb` (2,283,618 B, sha256 `e3d14c21…bb8d`; kept
    in the gitignored firmware area);
  - plain RAUC; CMS signed by CN=frame-images, which was issued by the stable root
    CN=steamdeck-images (from Valve's rootfs, not the server);
  - fails against the dev key and on a single-byte change;
  - manifest: `compatible=steamos-aarch64`, `version=20261007.6125817`; rootfs.img.caibx
    10 GiB, sha256 `692b998b…` (chunks not fetched).
- **Shutdown design rev 4 review:** GO once M1 (Virtual A/B merge-pending detection, fallback
  `vab-merge`) and M2 (the reader must never block the boot: poll timeouts, low priority, rlimits)
  are fixed. No path applies unreviewed thresholds. Rev 5 in progress.
- **PM decision:** Meta interface identifiers (JSON key names, sensor names, mitigation level
  names), threshold numbers and hashes may appear in the public design; never file contents.
- **Credits list** (PM request; `<private note, withheld>`, private, excluded from
  export, `2233e25`): 37 individuals/sources, 12 projects/organisations, 10 tools/licences.
  - Three licence obligations before any image is handed out: BusyBox (GPL-2.0), Meta's stock
    kernel (GPL-2.0), static glibc (LGPL-2.1+).
  - Open PM decisions (later): consent or pseudonyms for dump owners; guide authors; private
    sources (ask first); [removed for publication]; the PM's reference image (source unknown; private only);
    licence requests to unlicensed repos (Quest1-SteamOS, ArmadaVR).

**J-124 · Shutdown design rev 5; console checklist review (merge after fixes).**
- **Emergency-shutdown design rev 5** (`105990b`): review-4 M1 and M2 fixed.
  - F38: Virtual A/B is on; a `-cow` partition in the active slot → fallback `vab-merge`; the
    vendor incremental must match. The residual (COW wholly on userdata) is declared as R25/O27.
  - F39: `fs-metacfg` is spawned before RT elevation with `SCHED_RESET_ON_FORK` and rlimits; the
    parent waits ≤ 2 s on the pipe and pidfd (ppoll), never a blocking waitpid; a stuck helper
    is killed and the boot continues on the fallback.
  - All minors applied. O28 is closed per the PM's decision (J-123).
  - Correction carried: [removed for publication].
- **Console checklist review** (branch `feat/console-checklist`): merge after four MUST fixes:
  - test output regenerated in a real clone;
  - A3 states consent ("read … and accept");
  - capture paths follow the stage-3b convention (`<cycle>` = `captures\<nonce>`; no
    `-CapturesRoot` except for a dwell retry);
  - re-run the host pin check (15 files).
  - Also: B tied to the BA start, a longer reading time in phase A, plain-language section D,
    and clearer STOP lines. Fixes in progress in a separate clone; then merge.

**J-125 · STAGE 3 DISPLAY MILESTONE: stage-3c run on Unit 1 — STAGE PASS (first correct image); practice rerun.**
- **Before:** the console checklist was merged (`742075c`); 15 host pins and the preflight
  re-checked. Unit 2's read-only `getvar all` was taken (`1ce181c`; [removed for publication], current slot a, slot b unbootable). Two settled pairs failed while Unit 1 was charging (220 → 260); the
  PM first said "go ahead", then chose to wait for the checklist (no override used).
- **Run `<attempt nonce withheld>`** (image `9d3ad984…`), 2026-10-13, PM present:
  - Checklist A PASSED; B PASSED (260 → 260, 629 s; Arbiter-run); BA 01:37:42; BF 01:38:26;
    E PASSED 01:38:57; attempt at about 01:39.
  - Classifier (`captures/<attempt nonce withheld>/classify3c.txt`): STAGE-1 PASS; P0 OK; R1 SHOWN
    (split; optical DARK); **R2 SHOWN-QUAD [quad_vig]** (read-back SRC_X 0/1032/2064/3096,
    CRTC_X 0/1032/0/1032, zpos 0/0/1/1; held; clean close; TE 170/s, BLU 112/s; no dmesg flags),
    **OPTICAL PASS: all 8 characters read correctly in each eye**. **REGISTERED: STAGE PASS.**
    Run 3 not reached (PM answer time).
  - Persistence: devinfo identical; misc RECORDED (the same vendor field); every hashed partition
    identical except misc. AF 01:43:04; AA 01:45:56, 300; +5 min 320, +10 min 310 (highest 320).
  - PM description (verbatim in notes.txt): characters, F letters, bars and cross seen; "canted
    inward toward the center"; the same in both eyes apart from the bars.
- **Practice rerun** (PM: "without regard for the answers"; minimal log): nonce `<attempt nonce withheld>`
  (image `ed2acedb…`), a nonce-only rebuild verified against the candidate.
  - Pair 270 → 260; A, B, E PASSED; run 1 dark; run 2 displayed; **worked**.
  - Run 3 not run by design (run 2 was not reported garbled).
  - PM confirmed: **the panels are swapped** (bars 3,4 seen in the left eye, 1,2 in the right),
    and **canted inward** (clockwise left, counter-clockwise right) [PM report].
  - AA 340; +5 min 350; +10 min 330 (highest 350).
- **Findings:** the per-pipe throughput cause (J-108/J-109) is confirmed by the fix. Rendering must
  account for the eye swap and the per-eye roll. BLU about 112/s vs TE 170/s again ([O]).
- **PM decisions:** single temperature readings from now on (proposed rule: one reading
  < 35.0 °C, ≤ 15 min before BA, battery not charging; reviewed change pending; disclose in
  FS-A-012). The PM asked to run the panel test on Unit 2; the Arbiter explained that the image
  is built from Unit 1's v66 files (a hybrid on Unit 2's v2.7) and that the capture tooling needs
  root, and proposed a Unit 2 / v2.7 variant (PM decision pending).

**J-126 · PM decisions: build for v2.7 (stage 3d); single reading is a requirement; Unit 1 stays on v66 for now; display handoff explained.**
- **PM:** "we will probably need a v2.7 build anyway … If you think it prudent to build a v2.7
  image, then yes, let's go ahead." Stage 3d starts (branch `feat/stage3d-v27`):
  - the stage-3c test rebuilt on Unit 2's own stock v2.7 files, from the official OTA we hold
    for build 52433670036000520, verified against Unit 2's runtime vbmeta digest;
  - the v2.7 module list; the display assumptions re-checked from the v2.7 DT.
  - Host side (branch `feat/single-reading-userbuild`): user-build capture rows for Unit 2.
- **PM:** "please implement the single temp reading as a new requirement": one reading < 35.0 °C,
  ≤ 15 min before BA, battery not charging; replaces the 10-min pair (FS-R-010 §6 procedure
  change, PM executive decision; disclose in FS-A-012).
- **Unit 1 to v2.7?** The PM asked; the Arbiter recommended holding. Unit 1 is needed for deep display diagnostics; Unit 2 is
  already on exact v2.7; firmware moves are one-way in practice. Revisit after the first v2.7 test.
- **Run 1 dark vs run 2 lit (PM question), explanation [D/C]:**
  - On `fastboot boot` the bootloader turns the panel off at the boot command (the PM observed this
    in trial (iii)), but the kernel's continuous-splash handoff still assumes a lit panel and skips
    the panel power-on (run 1: TE 0).
  - Run 1's close fully resets the display; run 2 enables from inactive, gets the full power-on
    sequence, and lights.
  - Normal power-on keeps the splash lit, which is how stock's seamless takeover works.
  - Mitigations: test boots do one deliberate off→on cycle before the first frame; installed boots
    keep the bootloader's lit panel and draw with the correct 4-pipe layout without a modeset. To
    be verified on the first boot from an installed slot.

**J-127 · PM decisions: Unit 1 to v2.7 (PM flashes); omit lit run 1 (display reset); correct the eye swap and cant in stage 3d.**
- **Build types (PM question):** no hardware difference; it is a build configuration. [removed for publication]
- **Unit 1 → v2.7 (PM executive decision):** the PM can restore firmware on these units by flashing partitions (has done it before) and holds Unit 1's full v66 dumps, so
  the one-way concern does not apply.
  - The PM performs the flashing; FrameShift tools never write boot-chain partitions
    (FS-R-001).
  - Afterwards: Unit 1 read-only v2.7 baseline. Disclose in FS-A-012 (FS-R-010 §8 did not
    concur Quest 3 firmware changes).
- **Omit the lit run 1:** a non-lit display reset (ACTIVE=0 commit from the splash state, the same
  commit class) before the first lit frame. A fully seamless takeover is only possible on
  installed boots (the bootloader leaves the splash lit).
- **Stage 3d corrects the panels:** each eye's content goes into the buffer half that reaches that
  eye (swap), pre-rotated by the opposite cant (left counter-clockwise, right clockwise, about
  21°, parameterised); fs-pattern v0.7; the reviewed brightness bounds are unchanged.

**J-128 · PM accepts 21° as the starting cant (test and correct); stereo depth and the boot splash belong to rendering; geometry research started.**
- **Cant angle:** 21° is [C], from `ro.boot.bootloader_screen_rotation=201` (180 + 21) and the PM's
  qualitative observation of the direction (J-126). It may be rounded or vary per unit. **PM
  decision:** use 21° in stage 3d and correct it if testing shows otherwise. The angle stays a
  parameter, and angle variants can be compared in practice runs.
- **Stereo depth (PM question):** not a display-test concern. Depth comes from rendering each eye
  from its own viewpoint (IPD), with per-eye projection and lens-distortion correction. SteamVR
  on SteamOS already does this; FrameShift supplies the Quest geometry (per-eye resolution and FOV,
  distortion, IPD, eye-to-head transforms including the cant and the swap) through a SteamVR/runtime
  driver (tier 3, J-120). Preferred source: the unit's own factory calibration read at runtime,
  with public reference values as the fallback.
- **Boot splash (PM question):** Meta's bootloader logo already applies the 201° rotation. A
  SteamOS boot animation (Plymouth on the Steam Deck; the Frame is [O]) draws one flat image, so
  on the Quest it would appear split, swapped and tilted unless it is drawn per eye, rotated and
  swapped (a hardware-forced departure, the same job as fs-pattern). It needs no stereo depth.
- **Research agents:** display geometry and stereo (local evidence, driver needs, boot splash) →
  `docs/research/display-geometry-stereo.md`; a separate web-research agent on the published
  geometry. Results pending.
- **Unit 1:** the PM confirms they will flash v2.7 themselves (J-127) and will report when it is done.

**J-129 · Stage 3d built (candidate ec822b85, nonce 4e98edbf3fbc2d4e, branch `feat/stage3d-v27` 6c7f726); geometry research results; PM decisions on modules, backlight and the calibration listing.**
- **Geometry research** (`docs/research/display-geometry-stereo.md`):
  - 21° is Meta's design value [M-static: the v2.7 odm build.prop comment next to
    `ro.minui.rotation_degrees=201`]. It is one value per model; any per-unit residual is [O].
  - The "eye swap" is the 180° mount applied to the whole 4128-wide frame. Stage 3c rotated each
    half in place.
  - The Frame has no Plymouth. Its logos are pre-warped per unit from `device_config.json`. FrameShift
    needs its own per-eye KMS splash.
  - Lens distortion: there is no public Quest 3 model [O].
  - IPD comes from two magnetic sensors; the conversion to millimetres is [O].
  - Meta's per-unit calibration is under `/persist/calibration/`; the names and format are [O].
- **Stage 3d build:**
  - Inputs from the v2.7 OTA, matching Unit 2's runtime vbmeta digest `66b76196…9f12a` (the slot
    bytes are inferred, not read back).
  - fs-pattern v0.7: `eyes=swap`, `roll=21`; `roll=0 eyes=direct` gives v0.6 byte for byte.
  - The briefed ACTIVE=0-only reset would not clear the DSI splash flag [D, kernel source], so r1 is
    a three-step reset that scans out only black: disable, dark re-enable on a black buffer, then
    close. Untested on v2.7 [O].
- **PM decisions:**
  - (a) **Modules:** load the proven v66 set (minus the 2 debug modules), not v2.7's 131-module
    list. Rebuild pending, with a fresh nonce.
  - (b) **backlight_changes_blocked:** left alone. The image does not write it; a dim or dark run 2
    leads to a follow-up build.
  - (c) **Names-only listing:** a names-only listing of the calibration folder on Unit 2 [removed for publication]. Reading the contents is a new action class for the Chair.
- **Adversarial reviews:** two reviews started, (A) fs-pattern v0.7, reset and geometry, and (B) the
  image build, writes and modules.
- **WSL extract:** the v2.7 system, system_ext, odm and product partitions are extracted at
  `~/work/geom-x/` (about 2.8 GB, outside the repo), kept for now.

**J-130 · Stage 3d reviews: both GO-with-fixes; PM approves the three-step reset with a y/n observation.**
- **Review B (image build):**
  - Image, inputs and vbmeta digest independently re-verified.
  - Device writes are the same as stage 3c; nothing touches partitions, `/persist`, misc beyond 3c,
    or `backlight_changes_blocked`.
  - MAJOR: 6c7f726 loaded all 131 modules (fixed by J-129's v66 set; the reviewer simulated the
    load: 95 modules, none of the 36 pulled in, nothing missing).
  - MINORs: stale r1 wording in the MANIFEST and the fs-phase header; no device-side refusal on
    other firmware (Unit 1 at v66 would fail silently through CRC mismatches); the
    "inferred, not read back" caveat missing from the MANIFEST.
  - Fixes ordered: init checks `modules.dep` and `modules.softdep` hashes before loading and fails
    closed.
- **Review A (fs-pattern v0.7):**
  - The reset claim holds against the v2.7 kernel source, and a suspected NULL dereference was
    ruled out.
  - Only black is scanned out; the roll sign and the swap are correct.
  - `roll=0 eyes=direct` is byte-identical to v0.6.
  - Worst white is 3.09 % across roll −25..25; arguments fail closed.
  - MINORs: stale header comments; 8 empty stray `reset*.out/err` files committed; the PM approval
    of step B and the dropped r1 observation.
- **PM decision:** approves the three-step reset (disable, dark re-enable on a black buffer, close;
  backlight at 127 from p0). The host keeps one recorded, non-gating question after r1: "Anything
  visible during the reset? y/n".
- **Rebuild** with all fixes and a fresh nonce is in progress; the fixes get a delta re-review.

**J-131 · Unit 1 on v2.7 (PM flashed); baseline matches Unit 2; calibration file names listed.**
- **Firmware:** the PM flashed Unit 1 to v2.7 (J-127).
- **Read-only baselines** (`evidence/unit1-v27-baseline-20261013`; [removed for publication]):
  - Unit 1 has the same build (52433670036000520), vbmeta digest `66b76196…9f12a`, kernel, cmdline
    token set and by-name partition layout as Unit 2; only the loop-device order differs.
  - **The stage-3d image applies to both units** [M-static].
  - Battery 40–41 °C on AC at 100 % about 4–6 min after the first boot.
- **Build type:** both units are `user` builds. [removed for publication]
- **Calibration listing** (PM-approved names-only `ls -lR /persist/calibration` on Unit 1,
  `evidence/unit1-v27-persist-calib-names-20261013`):
  - `display/screen_offset.json` (2323 B) is the per-unit display offset candidate.
  - `rgb_calibration.json` (49 KB), plus camera, IMU, magnetometer, LED and microphone files.
  - `prox/min_ipd/*` (proximity thresholds).
  - `online/<numeric>` (10984 B, rewritten at runtime).
  - There is no obvious lens-distortion file. It may be inside a larger file or elsewhere [O].
  - The contents were not read; reading them is a new action class for the Chair.

**J-132 · Calibration files read off-device; PM: no further `/persist` access; offline backups used instead.**
- **Live pull of Unit 1:**
  - The PM permitted pulling the calibration files ("read them away from the headset").
  - The Arbiter pulled `/persist/calibration` (18 files) at 07:00:27Z. `/persist` is
    mounted `noatime`, so nothing on the device changed.
  - Right after the pull, the PM said they would prefer we don't touch `/persist`.
- **PM decisions:**
  - **No further `/persist` access on the headsets** (this cancels the Unit 2 listing, J-129 (c)).
  - Keep the copies and read them on the PC; they stay private and gitignored.
  - Whether the product may read calibration at runtime is decided later.
- **offline backups:** the PM pointed to the `/persist` images on the PM's offline backup drive.
  - Only our own units' images were used. Each was copied, its hash checked against the inventory,
    and extracted with read-only `debugfs`; nothing was written to the PM's offline backup drive.
  - The two third-party images were not opened.
  - The Unit 1 E: copy matches the live pull for all 17 factory files.
- **Findings** (private: `<private note, withheld>`, excluded from export):
  - `display/screen_offset.json` holds per-eye `Rotation` (residual at most 0.2° on both units, so
    21° holds), boresight, decentre at the IPD extremes, and a two-point IPD ADC → mm calibration.
  - The IPD ADC ranges differ completely between the units, consistent with different sensor parts,
    so the conversion is per unit.
  - Per-eye luminance and white point.
  - There is no full lens-distortion model.
  - `online/` and `camera_`/`imu_calibration.json` hold the tracking calibration.
- **The Chair** will be told in FS-A-012 (a PM executive decision).

**J-133 · Unit hardware faults (PM report); stage 3d rebuilt (3453f94, candidate 3d730337, nonce <attempt nonce withheld>); Unit 2 pre-check.**
- **Unit faults (PM):**
  - **Unit 2:** the IPD sensor and the proximity sensor do not work properly. The PM believes this
    causes the IAD/HAL crashes and the screen issues under Android.
  - **Unit 1:** faulty proximity sensor; everything else works.
  - **PM decision:** do not try to fix or compensate for these in testing, but keep in mind that
    they may affect results.
  - Stage 3d loads neither IPD-sensor driver (ak09973 and as5510 are among the 36 excluded
    modules).
  - Unit 2's factory IPD calibration values are treated as unreliable (private note).
- **Stage 3d rebuild 3453f94:**
  - Loads the 95-module v66 set, checked by `tools/module-list-check.py`.
  - init pins the device's `modules.dep`/`modules.softdep` and fails closed: no modules, no USB
    gadget, no LED, back in fastboot at T0+60.
  - Nothing writes `backlight_changes_blocked`, and the builder refuses scripts that do.
  - Headers and MANIFEST corrected; stray files removed; README §6.5 keeps the r1 y/n question.
  - fs-pattern is unchanged (`7c9fa98c…`).
  - All suites pass, including a bit-identical rebuild.
  - Earlier candidates `ec822b85…` and `b5ecfcdf…` were never booted.
- **Reviews started:** a delta re-review of 3453f94 and an adversarial review of
  `feat/single-reading-userbuild`.
- **Unit 2 pre-check, read-only, 07:08:14Z:** vbmeta digest `66b76196…9f12a`, build
  52433670036000520, slot `_a`, booted, AC, status 5 (full), 99 %,
  temperature 250.
- **Correction to stage 3d README §7.5:** Unit 2 is a user build. [removed for publication]
- **PM plan:** run stage 3d on **both** Unit 2 and Unit 1, to confirm that each displays correctly
  on v2.7 and to check the eye-swap and roll corrections. Each run needs its own single-use nonce
  (a nonce-only rebuild per unit, as for the J-125 practice run), and the host tools must take the
  unit's serial as a parameter rather than a pinned Unit 2 serial.

**J-134 · [removed for publication]**

**J-135 · Overnight: stage 3d merged to master (review C GO); single-reading review GO-with-fixes; host work started.**
- **Delta review C of 3453f94:** GO.
  - Fixes (a)–(g) verified.
  - The 95-module closure was re-derived and run under the image's own busybox in qemu.
  - The index refusal holds in five cases.
  - The image, nonce and fs-pattern were re-verified.
  - MINORs:
    1. Check 4 of `module-list-check.py` could not catch an addition on its own. **Fixed** (7634871):
       a fixed forbidden set of 38 as check 5, plus negatives. The image is unchanged.
    2. The init.sh comment "Meta's recovery set" is left as is, to keep the candidate
       byte-identical; noted in README §5.
    3. `c-modules-real` covers only the set; the reviewer's busybox run covers order and softdeps.
- **Merge:** `feat/stage3d-v27` merged into master (16b9dec). Builder suite 32/32, including the
  candidate rebuild: bit-identical, `3d730337…c224` (9847d0f).
- **Review of `feat/single-reading-userbuild`:** GO-with-fixes. The core rule and its boundaries
  hold, and the observer rechecks the 900 s window against BA.
  - MAJOR-1: `[int]` parameters round, so `-R1 36.2` passes as 36.
  - MAJOR-2: nothing ties the reading to a unit's serial.
  - MAJOR-3: the user-build rows are stale now that both units are v2.7 user builds.
  - MINORs: BA10 "status not 2" should be 3/4/5; `/persist` must be explicitly denied in the
    allowlist; WALKTHROUGH clock source; age rounding; RECOVERY.md.
- **Host agent started:** part 1 fixes the single-reading findings; part 2 adapts the host for
  stage 3d per README §6 (the r1 y/n question, per-eye bars plus tilt, a serial parameter for
  both units, rehearsal mode).
- **Open for the PM:** does battery status 5 ("full") while on AC count as "not charging"? The
  J-133 pre-check read AC, status 5, 99 %. adb over USB may also charge the headset.

**J-136 · Host tools built and reviewed (both GO-with-fixes); fixes in progress.**
- **Branches** (not merged): PART 1 `feat/single-reading-userbuild` 24553fc, rebased on master;
  PART 2 `feat/stage3d-host` e44f60c (stage-3d host: fs-observe3d, -session3d, -collect3d,
  -classify3d, -checklist3d, -nonceonly3d). Tests: test-host3d 79/79; test-host3c -Regression
  324/0; `fs-observe3d -Preflight` OK on 3d730337.
- **PART 1 review:** GO-with-fixes. All earlier MAJORs are fixed, and hostile inputs were refused
  (`36.2`, `099`, non-ASCII digits, wrong serial, 901 s, future times, forged BA10).
  - MINORs:
    1. Malformed dates (T24:00:00Z) crash, and were accepted in-process.
    2. No floor on BA10's temperature.
    3. An old reading could carry over after an abandoned cycle.
    4. Capture steps lack `-Serial`.
    5. Loose ends.
- **PART 2 review:** GO-with-fixes. Safety holds: only the PM-pasted observe command runs
  `fastboot boot`; the nonce ledger is written before the boot; serial mismatch is refused; pins
  match.
  - **MAJOR-1:** a layout-question timeout ends the session, the same loss as stage 3c, and the
    rehearsal skips the per-eye path. Fix: continue past a timeout; ask tilt first; add a timed
    nominal rehearsal.
  - **MAJOR-2:** `fs-nonceonly3d` does not open the image. Fix: a byte-level check that only the
    nonce differs, required by the observer for any candidate other than 3d730337.
  - MINORs:
    - machine-check the BA/BF must-be rows (slot, digest, level);
    - the `n` key wording;
    - remove the expected-bars hint, which biases the swap check;
    - report a reset/skip inconsistency;
    - name the mixer for a 0 bar;
    - state in the WALKTHROUGH that the pasted command boots;
    - make the test section Y skip.
- All fixes were sent to the host agent; a re-review follows.

**J-137 · Single-reading change merged; stage-3d host in its last fix round.**
- **Fix rounds:** PART 1 → 98c5736, PART 2 → 6bd2745.
  - Tests: test-host3c -Regression 325/0/2; test-host3d 92/92.
  - Nominal-read timing at stage-3c speeds: all 9 items fit, with 11.8 s to spare (HOST.md §4a).
- **Arbiter decision:** on the run-3 path, a timeout at a tilt or F question still ends the session
  safely (fs-done, no lit run 3). On the read path a timeout skips only that item. This is the
  conservative choice, consistent with Q7.
- **Delta re-review D:**
  - PART 1: all MINORs verified with hostile inputs. GO, so **merged into master (29a3511)**.
  - PART 2: GO-with-fixes.
    - MAJOR-1: fs-nonceonly3d refuses every REAL nonce-only rebuild (ramdisk-scan.txt lines 1-2
      vary per build; the tests copied the reference file). This fails safe but blocks Unit 1.
    - MINORs:
      - a copied 3d730337 folder with an edited nonce passes preflight (bind the reviewed nonce
        and directory);
      - three preview pictures (asseen, panels, mixermap) show the expected bars and tilt (drop
        them from the PM preview until after the readings);
      - HOST.md wording.
  - The fixes were sent to the host agent.

**J-138 · Stage-3d host tools merged; ready for the PM's sound check, rehearsals and the Unit 2 run.**
- **Fix round** 956c54a: nonce-only check proven on a REAL rebuild (test K4); the reviewed candidate
  bound to its own directory and nonce; biasing pictures removed from the pre-session preview.
- **Final review E:** GO-with-fixes.
  - Merge-time MAJOR: after the merge, `<withheld rows file>` kept CRLF, which breaks its pin.
    Fixed by renormalising; all 18 SIGNOFF-3d pins verified.
  - MINORs fixed by the Arbiter (4d1967b):
    - D3 no longer primes "upright and level";
    - fs-nonceonly3d explicitly refuses a TEST OVERRIDES line;
    - HOST.md §6.6 updated.
  - Informational: the builder hashes in a MANIFEST are self-reported. There is no device risk,
    because the image and ramdisk are compared byte for byte.
- **Merged into master:** 791879e. Tests: test-host3d 93/0/0; test-host3c -Regression 326/1. The one
  failure, CL15, is expected in the main checkout: the newest stage-3c candidate's nonce is spent.
- **Ready:**
  - Unit 2 runs candidate `20261013T065151Z-<attempt nonce withheld>` (sha256 `3d730337…c224`, nonce
    `<attempt nonce withheld>`, unspent).
  - Unit 1 gets a nonce-only rebuild with its own nonce, checked by `fs-nonceonly3d`.
  - Before the run: the sound check and two rehearsals (garbled-r3 and the timed nominal read).
- **Open for the PM:**
  1. Does status 5 ("full") on AC count as not charging?
  2. FYI, the Arbiter decision of J-137: a timeout on the run-3 path ends the session safely.
  3. Not urgent: the community member's offer (J-134).

**J-139 · PM decisions: status 5 on USB accepted; run-3-path timeout design approved; storage offer deferred.**
- **Status 5:** "full but plugged in" is accepted as not charging for the tests. The PM notes that
  a headset on USB/adb always trickle-charges when its level drops, so this cannot be avoided. The
  tools already accept status 3/4/5. The temperature bound (< 35.0 °C) still applies.
- **Approved by the PM:** the Arbiter's J-137 choice. A timeout on the run-3 path ends the session
  safely.
- **Storage offer (J-134):** [removed for publication]

**J-140 · Stage-3d Unit 2 session: rehearsals GO; the attempt refused (phase order); stood down for the PM's work.**
- **Before the attempt:**
  - Pins 18/18 and preflight OK.
  - Sound check passed.
  - Rehearsals both GO: garbled path 7.4 s; timed read path 9/9 items with 47.9 s to spare.
  - Phase A passed on the second try. The first `n` came from the PM expecting no pictures; the
    Arbiter had not said the three shown are neutral.
  - Reading 240 (status 5, full) and phase B passed; BA and BF OK.
- **The attempt was REFUSED before any device action:** phase A had been run again (16:10:31)
  between B and E, which breaks the A, B, E order. Nothing booted; nonce `<attempt nonce withheld>` is
  unspent.
- **Retry started, then stood down:** the Arbiter began the documented retry (rebooting Unit 2 to
  Android). The PM then had to leave for work, so the cycle stood down with no new reading and no
  retry BA/BF.
- **Resume after work** per `captures/<attempt nonce withheld>/attempt-log.md`: re-check pins and
  preflight; new reading; BA and BF into `retry-1`; phase E; the attempt with the retry-1 summaries.
- **Lesson:** warn against re-pasting earlier commands from scrollback.

**J-141 · Stage-3d Unit 2 run: safe refusal, fs-pattern's mode limit (128) vs v2.7's 305 modes; nothing shown; fix v0.7.1 before Unit 1.**
- **The retry went through:** reading 240 (status 3); BA and BF into `retry-1`; phase E; the attempt
  at 00:51:49Z.
  - p0 was valid.
  - **r1: fs-pattern exited code 30 `too_many_modes` before any commit** (connectors 33/55/65 with
    37/305/0 modes; MAXMODES 128).
  - r2 was skipped (`run1-supervisor`); run 3 was not requested; fs-done was sent cleanly.
  - The PM saw dark throughout, matching the records [M].
  - AF and AA OK; AA temperature 300, then 310 (falling within limits).
  - Nonce `<attempt nonce withheld>` is spent.
- **Cause [M]:** v2.7's DT raised the max refresh to 240 with no step sizes, so the DSI connector
  lists 305 modes (v66 listed far fewer). Our mock DRM model never had more than 128.
  - It is not a hardware effect; Unit 1 would fail identically.
  - Reviews A–E missed it, because no review compared the limits with the v2.7 connector's real mode
    count. **Lesson:** audit every fixed limit against the target firmware's real values before a
    run.
- **PM context:** on Unit 2 an owner-applied fix lets Android finish booting
  despite the faulty IPD sensors ([removed for publication]). It is unrelated to the stage-3d image. Logged in the attempt log.
- **PM decision:** fix first, then Unit 1, then Unit 2.
- **Fix agent started:** fs-pattern v0.7.1 raises MAXMODES and audits every fixed limit against
  v2.7. It adds a mock scenario with tonight's exact connector set, rebuilds a new candidate with a
  fresh nonce, and re-points the host pins. A focused review follows.

**J-142 · fs-pattern v0.7.1 merged; new Unit 1 candidate fcca5ee7 (nonce <attempt nonce withheld>) ready.**
- **Fix** (`fix/stage3d-modes`, merged fdb2aae):
  - **fs-pattern v0.7.1** (`bfafad97…`): MAXMODES 512. v2.7 builds 2 timing nodes × 169 rates =
    338 modes and prunes 33 (vrefresh 17–49, matching Unit 2's 66 dmesg lines), leaving 305.
    Mode records are logged up to index 48, plus the chosen mode.
  - Every other fixed limit was audited against v2.7; none is exceeded.
  - There is exactly one 4128x2208@90 mode (index 0, the stage-3c timing), and the reset and r2
    use the same timing.
  - **fs-probe.sh:** drops and counts the v2.7 mode-validation dmesg lines, so the real panel lines
    stay within budget.
  - Candidate 96cc15aa was superseded before any boot (withdrawn); 3d730337 is withdrawn (spent).
- **Reviews:** device side GO (independent mode count 305; the v0.7 control build matches the real
  failure record by record); image check (bytes, ramdisk, nonce placement, a real nonce-only
  rebuild) OK; host side no BLOCKER.
  - MAJOR (operations): the gitignored v0.7.1 binary was not on master. The Arbiter's first
    test-builder run on master refused all builds; the binary was then rebuilt (`tools/build.sh`,
    `bfafad97` verified), and WALKTHROUGH gained step 0-pre.
  - MINORs open, for the next build:
    - fs-probe's filter could also hide an fps-90 mode error (fs-pattern's commit result still
      shows a failure);
    - the meaning of opt_skipped in the docs;
    - add the v2.7-shaped streams to test-host3d section E;
    - stale "v0.7" labels.
- **On master:** builder 32/32, including a bit-identical rebuild of fcca5ee7; test-host3d 95/0/0;
  test-host3c -Regression 326/1 (CL15, the spent stage-3c practice nonce); preflight OK for
  fcca5ee7; the withdrawn candidates are refused.
- **Next:** the Unit 1 run with `build/stage3d/20261014T014738Z-<attempt nonce withheld>`. Phase A must be
  redone, because the host files changed. A new cycle directory: `captures/<attempt nonce withheld>`.

**J-143 · PM decision: a standing phase-A acceptance; sound check and rehearsals carry over.**
- **Unit 1 cycle `captures/<attempt nonce withheld>`:** pins 18/18; preflight OK; sound check passed;
  rehearsals GO (garbled path 7.2 s; read path 9/9 items, 54.3 s spare); phase A PASSED.
- **PM:** "I would like to make that the last Phase A I need to do moving forward. I know what it
  says, and I agree to all." The PM also questioned repeating the sound check and rehearsals.
- **To implement after the Unit 1 run** (host change, reviewed):
  - phase A is accepted once and stays valid until its wording (D1–D14, the keys), the preview
    pictures or the checklist itself change;
  - the sound check and the rehearsals carry over until the session/collector tools change, or
    there is a new day or a new speaker setup.
  - The accepted text is recorded with its hash, so a change forces a new acceptance.

**J-144 · STAGE 3D PASS on Unit 1 (v2.7): first correct image on v2.7, with the eye swap and the 21° roll corrected.**
- **Run:** nonce `<attempt nonce withheld>`, candidate fcca5ee7 (fs-pattern v0.7.1), attempt at 06:11:42Z.
  - The reading first showed status 2 (topping up at 100 %); the Arbiter waited for status 3
    (240) before phase B.
- **Classifier: REGISTERED STAGE PASS.**
  - P0 OK.
  - **R1 RESET-DONE:** disable, dark re-enable on black, close; the PM saw nothing (NOT_SEEN).
  - **R2 SHOWN-QUAD:** quad_vig with roll=21 and eyes=swap from an inactive CRTC; held; clean
    close.
  - **Optical PASS:** `F6CF7FDA` read correctly in each eye.
  - Left eye: bars 1|2, F upright, level. Right eye: bars 3|4, F upright, level.
  - **The swap holds [D]; the 21° roll holds in both eyes [PM report].**
  - TE 176/s, BLU 176/s, topology `sde_quadpipe_dscmerge`, no dmesg flags.
  - Run 3 was not requested.
- **Two J-126 questions answered on v2.7:**
  1. The three-step reset makes the first lit frame work under `fastboot boot`.
  2. With `backlight_changes_blocked` left set, run 2 was bright enough to read clearly (BLU
     176/s).
  - The 95-module v66 set is enough for display and USB on v2.7.
- **PM description (notes.txt):** both eyes correct, canted correctly and upright, everything
  readable, a "clear pass". The two eyes did not overlap into a 3D image. This is expected: the
  pattern is a flat picture centred per panel, with no IPD, no per-unit boresight (screen_offset.json)
  and no stereo viewpoint. Convergence belongs to the rendering stage (E7, J-129).
- **After:** AF and AA OK; AA temperature 270, then 310 at +3 and +4 min (< 400; follow-ups
  continue).
- **Evidence:** FS-A-012 (private review record) and `stage3d-<attempt nonce withheld>/`
  (the Unit 2 refusal run): captures, observe/collect and image records.
- **Next:**
  1. Unit 2 with a nonce-only rebuild (WALKTHROUGH step 0-pre and step 0).
  2. The J-143 carry-over change.
  3. The open MINORs of J-142.
  4. Fill FS-A-012 §5 with stage 3c and stage 3d.

**J-145 · PM decision: charging allowed when the reading is below 30.0 °C (to implement with the J-143 carry-over).**
- **Context:** the Unit 2 run waited for the battery to leave status 2 (charging at 97 %, reading
  210). The PM noted the headset has ample power; the rule exists for heat, not charge.
- **PM decision:** from the next run, a reading taken while charging (status 2) is accepted if it is
  **below 300 (30.0 °C)**. Otherwise the rule is unchanged: status 3/4/5 below 350. The observer's
  BA10 cross-check follows the same rule.
- Implemented and reviewed together with J-143. Tonight's Unit 2 run still waits for status 3/4/5,
  because the current tools enforce it.
- **PM, the same evening:** the post-run temperature follow-ups on an installed Android boot can end
  once the headset is back in Android at a normal temperature. Android's own thermal management and
  the ambient air cool it (Unit 1: the PM ended them at 310, +4 min).

**J-146 · STAGE 3D PASS on Unit 2 (v2.7): both Quest 3 units display correctly with the swap and roll corrections.**
- **Run:** nonce `<attempt nonce withheld>`, a nonce-only rebuild of fcca5ee7 (`46b28f01…`, checked by
  fs-nonceonly3d and the preflight). Attempt at 06:51:27Z.
  - The reading waited for status 3: 97 % charging, then full; reading 250.
- **Classifier: REGISTERED STAGE PASS.**
  - R1 RESET-DONE (NOT_SEEN).
  - R2 SHOWN-QUAD quad_vig with roll=21 and eyes=swap; held; clean close.
  - `0D63122A` read in both eyes; level and upright in both eyes; bars 1|2 and 3|4.
  - TE/BLU 176/s; no dmesg flags.
  - AA temperature 280.
- **PM:** "Same as Unit 1, everything readable, both eyes correct, clear pass."
- **Stage 3 (display) is complete on the Quest 3 for both units on v2.7.** Unit 2's sensor faults
  did not affect the display path.
- **Next:**
  1. J-143 and J-145 host changes (standing phase A; sound check and rehearsal carry-over; charging
     allowed below 30 °C), plus the J-142 MINORs.
  2. FS-A-012 §5: the stage-3c and stage-3d results and the PM executive decisions.
  3. The stage 3 (GPU) and stage 4 (SteamOS rootfs) plan, with the PM's decisions, including
     whether an early console boot of the SteamOS userspace is realistic before the GPU.

**J-147 · Three work items started, then paused overnight (PM shutting down the PC).**
- **Started on the PM's go:**
  1. Host carry-over, branch `feat/host-carryover` (J-143 standing phase A; sound check and
     rehearsal carry-over; J-145 charging below 30 °C; J-142 host MINORs).
  2. The FS-A-012 §5 draft (stage 3c and 3d results, the PM's executive decisions disclosed, Chair
     requests). It stays a DRAFT until reviews pass.
  3. The stage 3 (GPU) and stage 4 (SteamOS rootfs) plan → `docs/research/stage3-4-plan.md`.
- **Paused:** all three were stopped before committing anything. The main checkout is clean on
  master (4cf9fb9); the host clone may hold partial work in %TEMP%.
- **Resume in the morning:** continue the same three agents, or restart them from these briefs.
- No headset is needed for any of them.

**J-148 · Work items resumed; stage 3/4 plan written; FS-A-012 §5 drafted, review NO-GO (fixing); PM decisions on the public push and ask (b).**
- **Plan** (`docs/research/stage3-4-plan.md`, 7a6ad7d):
  - Valve's userspace drives the GPU only through upstream drm/msm; its Turnip builds have no KGSL
    backend [M-static].
  - Recommended route: (a) Meta's KGSL plus our own Turnip build with its KGSL backend.
  - The early console milestone is realistic, but needs our own kernel (DEVTMPFS, FHANDLE, BTRFS)
    and a RAM-over-USB rootfs.
  - Nine PM decisions (PD-1..PD-9). An adversarial review is running before they go to the PM.
- **FS-A-012 §5** (84fbf66): the review was NO-GO.
  - **B1:** both PASS runs' r1 records contain two kernel `WARNING drm_atomic_helper.c:229
    set_best_encoder` traces and sde "invalid horizontal destination -7" lines from the reset.
    Undisclosed, and not flaggable by fs-classify3d. Being source-checked.
  - **B2:** the public repo went public (J-118) before the licence/source review FS-R-011 §8
    requires; D6 and D7 were decided without the Chair.
  - **M6:** the Arbiter pulled calibration contents 2.5 min after recording that this was a Chair
    action class, with Unit 1 at 40–41 °C and no cooling advice. This is the Arbiter's error and is
    disclosed as such.
  - The fixes were sent to the drafter; a re-review follows.
- **PM decisions:**
  - **Public push:** one export after the three items, with the scope audit, the licence/source
    review (B2) and an adversarial review. The PM sees a summary before anything is pushed. The
    private repo has no remote.
  - **Ask (b):** reframed as a standing concurrence for repeat runs of reviewed display-test
    packages on both Quest 3 units at v2.7, under today's rules.
- **Attempt logs** (a654ed8): Unit 1's +4 min reading (310) and the PM ending the follow-ups;
  Unit 2 had no follow-ups (J-145).

**J-149 · PM decisions on the stage 3/4 plan (stage3-4-plan.md rev 1, 7cffe0b); the 0.4.5 rootfs download approved.**
- **Plan review:** GO-with-fixes; the fixes were applied.
  - The BLOCKER was the missing boot-chain guard before Valve userspace; it is now milestone K1b.
  - Route (a) needs a patched Turnip fork, possibly gamescope changes and a rebuilt display module.
  - The (a)/(b) re-check moved to G2.
- **PM decisions:**
  - **PD-1:** route (a), Meta's KGSL plus our patched Turnip, now. The long-term goal is upstream
    drm/msm, re-checked at G2. The PM asked first for the most stable long-term option and what is
    feasible.
  - **PD-2:** no route-(b) experiment unless (a) runs into trouble. The PM's priority is getting
    the port to users sooner.
  - **PD-4:** upstream Mesa only; do not ask Valve.
  - **PD-12:** if Meta's display module needs changing, rebuild it from Meta's published GPL
    source. Cleaner legally; still a Chair class.
  - **PD-3:** the first SteamOS boot is loaded into RAM over USB (sized RAM disk, dm-verity),
    with no storage writes.
  - **PD-5:** our own kernel boots on Unit 2 first, by temporary `fastboot boot` only, with the
    PM present.
  - **PD-10:** the fs-blkguard guard is built and tested before any Valve software runs.
  - **PD-11:** SteamOS 0.4.5 stable. The .raucb we hold is only a signed casync index, so **the PM
    approved downloading 0.4.5's public rootfs chunks** from Valve's public update server (verified
    against the signed index, seeded from 0.3.0, private and gitignored, never committed or
    published). Fallback: 0.3.0.
  - **PD-7:** the **full thermal/battery shutdown service first**, before the first GPU test and
    the first SteamOS boot (not the bounded-hold interim).
  - **PD-6:** add SysV IPC to our first kernel build now, rebuilding the affected modules.
  - **PD-8:** **research first.** The PM: "as polished a product as we can possibly make, not
    jerry-rigged together and patched to just make functional." A research agent is comparing our
    gadget, Valve's gadget and a hybrid → `docs/research/usb-link-design.md`.
  - **PD-9:** dedicated install (SteamOS takes userdata). Research a carved-out partition for a
    later dual-boot; no sharing of Android's encryption keys.
  - **PD-13** (the rootfs route for G3) is pending; it depends on the Chair's ruling on writing
    userdata (C6).
- **Agents running:** 0.4.5 rootfs assembly; USB-link research; delta review of the host
  carry-over (6f2973f); FS-A-012 fix round 2 (adds J-149 as a disclosed PM decision).

**J-150 · PM principle: a pure SteamOS image, with only the Meta side modified; PD-1 reopened for research.**
- **PM:**
  - the full thermal and battery service first fits the "ensure safety" aspect;
  - Steam's SysV IPC should be included, because "I'd rather have as complete a Steam image/package
    than not";
  - **"If we can have a 100% pure SteamOS image, and just modify the Meta parts that hook into it,
    that would be best."**
  - On USB: leans toward SteamOS's own stack, for an experience "as close to 'native' as possible"
    (passed to the PD-8 research).
- **Conflict raised by the Arbiter:** PD-1 route (a) needs a patched Turnip (and possibly gamescope
  patches) on the SteamOS side, so the image would not be pure. Route (b), upstream drm/msm in our
  kernel, keeps Valve's graphics stack unchanged but costs more kernel work.
- **PM:** relies on the Arbiter's research to pick the best long-term, most stable, most polished
  and most feasible route. **PD-1 is reopened.** A deep-research agent is comparing (a), (b), (b2)
  a newer kernel, (c) mainline, and a uAPI shim → `docs/research/gpu-route-decision.md`, with one
  reasoned recommendation and a staged path.

**J-151 · FS-A-012 fix round 2 done (3dc445f; still a DRAFT); PM decisions on its open points; USB research.**
- **FS-A-012:** re-review findings applied; manifest 647 entries, all verify.
- **PM decisions:**
  1. The stage 3/4 plan decisions (J-149/J-150) go into **FS-A-013**; FS-A-012 only points to it.
  2. Per-unit calibration values are **not** shown to the Chair; the bound only.
  3. The D7 recovery-image exception is **kept as a fallback**: 0.4.5 stable is primary, and the
     exact 0.3.0 recovery image is used only if 0.4.5 cannot be assembled. This goes to the Chair.
- **PD-8 USB research** (`docs/research/usb-link-design.md`, 56edffa):
  - Recommends Valve's own USB stack, as the PM leaned: for the product, Valve's stack plus minimal
    Quest add-on config files (no Valve file edited).
  - For development: a hybrid, with our ramdisk console handing the port to Valve's gadget and
    Developer Mode on.
  - Quest-forced changes: our own USB identity (never Valve's), a per-unit MAC seed, the f_fs
    `ready` attribute missing in 5.10.
  - An adversarial review is running before PD-8a–d go to the PM.
- **test-host3d on master:** G6/K3 fail only because nonce <attempt nonce withheld> is spent. Fixed on
  feat/host-carryover, pending its delta review.

**J-152 · USB research reviewed (GO-with-fixes); a reviewer broke the no-disassembly rule.**
- **Review of `usb-link-design.md`:** the end state holds: Valve's stack plus minimal Quest
  add-ons, never Valve's USB ID, no MTP in v1. Five MAJORs are being fixed:
  1. With Developer Mode off, usb-gadget.service fails at every boot, because 5.10 lacks f_fs
     `ready` and the adbd-pre/post units are not gated; a mandatory wait drop-in fixes it.
  2. The Developer Mode preset is not Valve's exact state; run Valve's own helper instead.
  3. There is no console after switch_root; add a dev fallback and stage PD-8a.
  4. Role switching was forced by our own init; Meta's ucsi skips eMarked cables. Needs hardware
     tests.
  5. Every Quest would enumerate as serial "frame"; a per-unit serial is needed. pid.codes needs an
     open-source licence; ask Valve for a PID as an option.
- **Rule breach:** the reviewer cited a **disassembly of Valve's adbd binary** (offsets) for one
  finding. The project rule is no disassembly of Valve binaries (PROJECT_SETUP §0.0, after J-90; J-120: behaviour is learned from public interfaces and runtime observation only). Earlier private disassembly (e.g. ABL, ld.so) predates the rule and was kept out of the public record. That evidence is
  **not used**: the point is restated as [O] for a hardware test. The disassembly output is not
  kept in the repo. Review and research briefs will state the rule explicitly from now on.


**J-153 · PM decisions PD-8a–d (USB link), on usb-link-design.md rev 1 (756baf1).**
- **PD-8a (developer images):** staged.
  - Stage A: our own console link, with Valve's usb-gadget.target masked on the command line.
  - Stage B: Valve's link with our console as an automatic fallback, only after hardware tests
    U1–U6 pass.
- **PD-8b (product):** Valve's stack as on the Frame, plus small separate Quest drop-ins (the
  mandatory ffs wait, identity, per-unit serial and MAC seed). No Valve file is edited.
- **PD-8c (identity):** the generic Linux ID (1d6b:0104) in development. For the product, an ID
  in Valve's range (ask Valve in the held letter) or pid.codes, which needs a public open-source
  licence first. Always a per-unit serial; never Valve's Frame ID.
- **PD-8d:** no MTP in v1.


**J-154 · GPU route decided: a Frame-compatible `msm` device (e′); 0.4.5 rootfs assembled; host carry-over merged.**
- **GPU research** (`docs/research/gpu-route-decision.md`, rev 1, 61d653c; adversarial review
  GO-with-fixes):
  - Valve's Turnip needs a DRM device named `msm` (version ≥ 1.6) with the display on the same
    device. On the Frame, vrcompositor drives the panels through Turnip's KHR_display.
  - (e′): rebuild Meta's GPL `msm_drm.ko` and `msm_kgsl.ko` so that together they register ONE
    `msm` device. It carries the SDE display, the drm/msm GPU uAPI on KGSL, syncobj, and a
    kernel-side split of one wide plane into four pipes.
  - SteamOS runs unchanged. Two Frame-specific Valve scripts get Quest-side drop-ins.
  - Review corrections: the effort is **about 21–38 pw to Frame parity** (not 12–22). Five traps
    are now planned work items:
    - syncobj eventfd missing in 5.10;
    - the KGSL protect table vs perf counters;
    - per-fd VA windows;
    - VM_BIND/sparse for vkd3d FL 12_0;
    - a real KGSL refactor.
  - The alternatives (a), (b), (b2), (c) and virtio native context were confirmed as worse.
- **PM decisions:**
  - **PD-1 = (e′).** Fallback: (b), studied only if an early checkpoint fails (PD-2). Long-term
    horizon: (c).
  - **PD-12 widened:** rebuild both Meta modules from GPL source and publish the changes; a Chair
    class.
  - **G1** (upstream Turnip-KGSL offscreen) is kept as an internal test tool only, never shipped.
  - **M1 = (i):** back-port the syncobj eventfd ioctl into vmlinux (a Chair class); the shim
    attaches dma_resv fences either way.
  - **Effort accepted, no route-(a) stop-gap.**
- **0.4.5 rootfs** (d2c725c, `ROOTFS-ASSEMBLY.md`):
  - Assembled from Valve's public chunk store (`steamdeck-images.steamos.cloud/vr/…castr`, derived
    from the Frame's own RAUC and desync config; client.conf not opened).
  - 55,892 chunks downloaded (3.31 GiB), each verified; seeded from 0.3.0.
  - **sha256 `692b998b…bcc3c` equals the signed manifest.** btrfs, `check --check-data-csum`
    clean.
  - Kept gitignored. The ROOTFS-ASSEMBLY note itself is not yet reviewed.
- **Host carry-over merged** (829da45; final delta review GO).
  - 19 SIGNOFF-3d pins verified on master.
  - Three new MINORs left for a follow-up: the replay .idx is not named; the replay is hashed by
    path, not by the bytes replayed; the WALKTHROUGH last-line wording; plus an untested observer
    branch.


**J-155 · PM principle: maximise our own original code, minimise Meta's, and be legally disentangled; a provenance and licence policy task.**
- **PM:** "I would love to use as little of Meta's code, and use as much of our own original as
  possible."
- **Arbiter's answer** (not legal advice; a legal review before any public release):
  - Originality is about expression, so modified or paraphrased Meta code stays derivative;
    clean-room code from specs and public interfaces is ours.
  - Meta's GPL kernel modules may be modified and redistributed under the GPL, with source
    published; that is an obligation, not an entanglement.
  - The real exposure is Meta's non-GPL firmware and proprietary parts. Never redistribute them;
    read them from the user's device at install time. SteamOS comes from Valve's servers.
  - Trademarks, device ToS and patents go to the legal review (this ties in with the FS-R-011 §8
    licence/source review).
- **Direction:** route (e′) modifies Meta's GPL modules now (legal, but Meta-derived). The
  mainline horizon (c) replaces Meta's drivers with community upstream code: the main step away
  from Meta.
- **New task:** a written provenance and licence policy plus a per-file provenance record, also
  covering the open licence review, before the next public export.


**J-156 · PM: a bridge architecture; trademark boilerplate; 0.4.5 copied beside 0.3.0; FS-A-013 soon.**
- **Bridge architecture (PM):** we never alter Meta's or Valve's firmware or images; we architect
  the bridges between them.
  - That already holds for firmware blobs and Valve's SteamOS (unchanged).
  - For route (e′) the target is now: our **own** bridge kernel module (original code, GPL-2.0 as
    kernel code) implementing the Frame-compatible `msm` device, plus **minimal hook patches** to
    Meta's GPL msm_drm/kgsl source (the KGSL entry-point refactor, protect-table alignment, SDE
    plane fan-out hooks).
  - The patch-series size is a tracked metric. This is passed to the FS-A-013 draft and the
    provenance policy.
- **Trademarks (PM):** a standard notice ("Meta and Quest are trademarks of Meta Platforms, Inc.;
  Valve, Steam, SteamOS and Steam Frame are trademarks of Valve Corporation; … not affiliated or
  endorsed"), with nominative use only. Still on the lawyer's list.
- **0.4.5:** the PM asked for a copy beside 0.3.0. It is being copied to
  `firmware/SteamOS/steamos-0.4.5-stable/` (local, gitignored), verified with SHA256SUMS.
- **PM:** FS-A-013 should reach the Chair soon; tell the PM when relays are ready.


**J-157 · FS-A-012 final review GO-with-fixes; FS-A-013 drafted (91461e3); provenance policy (0531bfa); PM decisions on K1, G1 firmware, ask (b) and licences.**
- **FS-A-012 final review:** GO-with-fixes, with 8 MAJORs:
  - the core_clk values give no [M] support for the skipped down-vote;
  - step B commits the 2 × 2064 split;
  - the ask (b) scope;
  - the tool set ask (b) covers;
  - stale 0.4.5 status;
  - the D7 exception pin;
  - "stable" rests on unsigned metadata [C];
  - the DESIGN line cites.
  Fixes were sent to the drafter.
- **0.4.5 copy:** `firmware/SteamOS/steamos-0.4.5-stable/`, verified (SHA256SUMS OK; .raucb e3d14c21…).
- **FS-A-013 draft:** includes the J-156 bridge design. Relays go in order, so it is finalised after
  FS-R-012.
- **Provenance policy and record:**
  - 2,574 files, 62 flagged.
  - **Problems:**
    - the exporter would publish FS-A-009 (private review record), including raw devinfo/misc
      partition images;
    - verbatim Valve listings and manifest in steamos-stable-0.4-metadata/;
    - attempt logs outside the public scope.
  - Fixes were sent to the policy agent: <private export tooling> exclusions on a deny-by-default basis, and a
    scope scan. Nothing is pushed.
- **PM decisions:**
  - **K1 split:** K1a (CRC-neutral options, stock vendor modules), then SysV IPC with the rebuilt
    module set.
  - **G1 firmware:** staged from the matching v2.7 OTA in a private, never-distributed test image;
    the product reads firmware from the user's headset.
  - **Ask (b) narrow:** repeat runs of the stage-3d package only, but it **includes the
    post-829da45 tool set** (J-143/J-145).
  - **Licences:** Apache-2.0 for tools, scripts and services; GPL-2.0-only for kernel patches and
    our kernel modules; CC-BY-4.0 for docs. Licence differences were explained to the PM first.


**J-158 · FS-A-013 review GO-with-fixes; PM decisions: K1 order, ADSP firmware staging, full checklist rule.**
- **FS-A-013 review:** GO-with-fixes (0 BLOCKER, 11 MAJOR, 16 MINOR). The main fixes:
  - attribution of the K1 details;
  - a C5/C4 cycle (KGSL load vs the thermal service);
  - the ADSP firmware source;
  - named unit, udev and polkit masks;
  - the module-signing vs modules_disabled latch;
  - bounding R-1 after switch_root;
  - the full checklist rule;
  - Turnip's environment for G1c/G2;
  - G3's write boundary;
  - set_active being a boot-chain slot switch;
  - "CRC-neutral" as expected [D].
  The fixes were sent to the drafter.
- **PM decisions:**
  - **K1 order:** K1a (stock modules, no USER_NS/PID_NS), then K1g (prove fs-blkguard), then K1i
    (SysV IPC plus the rebuilt modules). Proposed by the Arbiter, confirmed by the PM.
  - **ADSP firmware** for the thermal/battery service in test images: staged from the matching
    v2.7 OTA (hash-checked, private, never distributed); the product reads it from the user's
    headset.
  - **The full v2.7 DEVICE_PORT_CHECKLIST** before T6, any extended R-1 and G3; no narrowing.


**J-159 · FS-A-012 READY TO SEND; tracking/input research done.**
- **FS-A-012:** three review rounds plus the final verification; the PM confirmed §5.6's
  description of their decisions and the ask (g) proposal in chat.
  - The final relay FS-A-012 (private review record) (sha256 `48a9510d…048d`) is sent beside the bundles:
    - `FS-A-012-raw.zip` (`6700e284…e8ea`);
    - `FS-A-012-package.zip` (`2a8cd98d…f9ed`);
    - `FS-A-012-image.zip` (`91eba83b…8d2d`).
  - Built by FS-A-012 (private review record) from 353c0ad; deterministic; re-hashed after
    unzip; raw manifest 647/647. The bundled E: inventory is limited to our two units' rows.
  - Fixes made in the final file only: the post_plane seq; the ask (b) action-class list completed;
    a §5.8 row; the item 15 note.
- **Tracking/input research** (`docs/research/tracking-input-route.md`, 6256d02; not yet reviewed):
  - It recommends an open-source bridge: our own sensor daemon plus a FrameShift OpenVR driver,
    Basalt 6DoF via Monado, constellation tracking for Touch, Mercury for hands. SteamOS and
    SteamVR stay unchanged, using Valve's Oculus Touch input profiles.
  - Valve's own tracker is tied to Frame hardware (its DSP program, FPGA and CAMSS).
  - The biggest unknown is the cameras: Qualcomm's Spectra stack, with a TrustZone-owned power
    GPIO.
  - Effort: 20–45 pw to 6DoF, 60–140 pw for the full set; 3DoF early (3–6 pw).
  - Ten PM decisions (D-T1..D-T10) follow after the adversarial review.


**J-160 · PM direction on tracking: try Valve's tracker plus Meta's components; any Touch generation must track accurately; polished and legally clean.**
- **PM:** use Valve's own SteamOS tracking, porting what is needed from Meta/Horizon OS so that
  Oculus Touch, Meta Touch and Touch Plus all track accurately and consistently. A working method
  may extend to other controllers later. Open-source or our own is even better if comparable; it
  must be polished and legally clean.
- **The Arbiter's assessment** (to be checked by the running review):
  - Valve's tracker is tied to Frame hardware (DSP program, FPGA, controller models). Reusing it
    without Valve's interface or cooperation would need reverse engineering, which our rules
    exclude. → Add "a tracking interface or documentation" to the held letter to Valve.
  - Meta's stack is proprietary and not redistributable, and running it outside Horizon may breach
    Meta's terms (lawyer). Its cleanest form is running it **unchanged from the user's own headset**
    (e.g. an Android container, files never shipped).
  - Proposal: **one controller-tracking framework with swappable providers.** Default open/own
    (legally clean, extensible to other controllers); an optional Meta provider only with legal
    clearance; a future Valve provider if Valve cooperates. **Per-controller accuracy targets**
    define "supported".
  - The review was extended to evaluate this; the doc is revised after it; the decisions then go to
    the PM.
- **FS-A-012:** the PM will send the four files after work.


**J-161 · FS-A-013 round 3 (GO-with-fixes; PM: the G1 split); tracking review GO-with-fixes; export review NO-GO; open-source tracking survey started.**
- **FS-A-013 re-review:** GO-with-fixes (4 MAJOR, 18 MINOR).
  - 0.4.5 unit and writer placements are identical to the 0.3.0 inventory; no new writer.
  - 0.4.5 ships a newer Mesa/Turnip (abc426bb), gamescope and SteamVR, so the GPU-route evidence
    (0.3.0) must be re-pinned.
  - **PM decision:** **G1 is split**: (i) a short baseline with the GPU at its lowest level; (ii) a
    short throttle check, never above Meta's NORMAL cap, with fs-thermald live and the PM present.
  - The fixes were sent to the drafter. The reviewer's 9.4 GB WSL extraction of Valve content was
    deleted.
- **Tracking review:** GO-with-fixes (12 MAJOR). The open bridge stands, but:
  - the SyncBoss allow-list must go by (type, sub-type, bounds) and be enforced in a GPL kernel
    hook;
  - deny the SyncBoss firmware-update path;
  - "read-only probe" was wrong;
  - camera leads via SyncBoss/CCI;
  - IR duty bounds;
  - never mount /persist;
  - Touch Plus first on Q3 (ring Touch reportedly doesn't pair with Q3);
  - a two-layer provider design (pose API plus sensor arbitration);
  - D-T11 "polished" targets;
  - polished Touch Plus at 40–90 pw, may not converge.
  - The PM's J-160 route was answered: Valve's tracker needs Valve; Meta's stack in a container is
    plausible but heavy and needs a lawyer. The fixes were sent to the author.
- **Export review: NO-GO.**
  - The exporter refused.
  - FS-A-012.md would have been exported.
  - Unit 1's serial appears in lowercase.
  - Merge-conflict markers are not refused; one file would be written empty.
  - [removed for publication]
  - "v66 (Unit 1)" leaks; licence text is missing.
  - Fixes were sent to the policy agent. **Nothing is published.**
- **PM:** spend time investigating the best tracking/controller path; **an open-source survey agent
  was started** (`docs/research/oss-tracking-survey.md`).


**J-162 · PM tracking decisions; survey reviewed and fixed (44588e8); export fixed (CC-BY text pending the PM); prompt-injection reporting rule.**
- **OSS survey:** review GO-with-fixes; the fixes are in rev 1, 44588e8.
  - Valve's tracker is a Basalt-derived estimator inside a proprietary SLAM/relocalisation layer,
    so an open map layer is a gap.
  - Licence traps: Basalt's apriltag (ship the shared library only); OKVIS2's DBoW2 notice and CNN.
  - CPU budget: 4.7–9.1 of 6 cores at a sustained 1.92 GHz; an ARM replay is required.
  - Touch Plus quality is unknown.
- **PM decisions and questions:**
  - **No Meta provider:** Meta will not clear its models or software.
  - **Ring Touch must work on Quest 3.** FXR reportedly ported Meta binaries;
    we build our own clean implementation, with their work as pointers only.
  - **Steam Frame controllers via Valve's tracker:** needs Valve's cooperation (held letter).
  - **Basalt is the lead:** our own improved fork plus an open map layer. (Valve's derivative is
    not "open by default": BSD-3 allows proprietary derivatives.)
  - **One hand-tracking model for all Quests' cameras.**
  - **Polish over effort:** agents compress research and coding, but quality is bounded by hardware
    iterations and data.
  - Asked: are cameras usable if detected as peripherals? How does Quest track, and does it
    offload? Both go to the doc revision (rev 2).
- **Export:** all review items were fixed (0099761, 69d9ea1, 6808f1f, 80a0824). The trial export
  is clean (2,495 files; 0 serials, names, conflict markers or captures). The only remaining block
  is the CC-BY-4.0 text download, which awaits the PM. Ten conflicting files were resolved to the
  public side; their dropped private changes need review before the push.
- **PM rule:** always tell the PM about AI-directed or suspicious prompt text found by agents
  (memory saved). The case so far: Basalt GitLab issue #117 asked AI assistants to read repo files
  and create branches/MRs with glab; ignored.


**J-163 · Valve letter draft 4; the translation-layer question; PM: Horizon parity as the tracking pass mark.**
- **Valve letter draft 4** (b5d8946, still held, excluded from export). New asks:
  - 6: a USB PID in Valve's range, or Valve's preference (PD-8c);
  - 7: a documented interface to feed another headset's camera and IMU streams (with calibration)
    into SteamOS tracking, which would also enable Steam Frame controllers on a Quest (J-160/J-162);
  - 5 (extended): how Valve wants its trademarks referred to (J-156).
  - Not asked: Valve's Mesa tree (PD-4).
- **PM question:** a translation layer feeding Quest camera and IMU streams into Valve's tracker.
  Our capture and conversion side is clean. The handoff into Valve's tracker is undocumented:
  emulating the Frame's sensors (FPGA/CAMSS cameras, IMU from Valve's ADSP firmware) would need
  reverse engineering, which is against the rules, fragile across updates and legally grey. It is
  clean only with Valve's interface (ask 7). Touch tracking is ours in any case.
- **PM direction:** our own model, built to Meta's measurements. **Horizon parity is the pass
  mark**, measured black-box on the same unit; D-T11's numbers stay as floors. Adopt Meta's safety
  limits and hardware operating points as values from GPL source and the DT (J-123), never weights,
  code or config contents. Use SteamVR's Chaperone natively, matching Guardian's behaviour by
  measurement. Models are trained from scratch on clean data. Passed to the tracking doc (rev 2).


**J-164 · Tracking rev 2 (bfe8cb9); PM: offload tracking to a dedicated process.**
- **Rev 2:**
  - Ring Touch on Q3 via our own pairing (nRF52833 with the same GPL driver; the `jedi`/`ruby`
    firmware archives may include ring support [O]); stop at checkpoint C-R if pairing crypto or
    firmware blocks it.
  - Cameras declared in the DT are not powered (TrustZone sensorlock).
  - Offload: CPU + GPU first; DSP via unsigned PD is open; NPU and EVA excluded.
  - Effort: 134–289 agent pw plus 89–200 hardware sessions (+25 %), about 1–2 years of hardware
    calendar for the full set; 6DoF head is much sooner.
  - D-T1..D-T16.
  - J-163 (Horizon parity, Meta limits as values, Chaperone) arrived after rev 2 and is being
    applied as rev 2.1.
- **PM:** "offload the tracking to a dedicated process for efficiency."
  - **Software:** fs-trackd as a dedicated, isolated service with reserved cores, real-time
    priority, fixed thread budgets, lock-free IPC, and supervision by fs-thermald with a
    degradation order.
  - **Hardware:** the Hexagon DSP feasibility (unsigned PD, open toolchain) becomes an EARLY
    checkpoint before T2b. GPU compute is second; NPU and EVA stay excluded.
  - Added to rev 2.1.


**J-165 · Tracking rev 2.1 complete (eb4862b, 0984c42); PM priority: each device's own Meta controllers first.**
- **Rev 2.1:**
  - J-163: Horizon parity is the pass mark; Meta limits are taken as values (140 mA flood LEDs,
    safety timer ≤1280 ms, SyncBoss 8 MHz/150 µs); strobe duty, frame rates and the IMU rate are to
    be measured.
  - J-164: fs-trackd on 2 reserved cores, RT below SyncBoss's 51; degradation order hands →
    controller rate → head floor.
  - The CPU split is unmeasured. Without the DSP, head plus controllers fit and hands don't (mode
    switching or GPU).
  - DSP check C-DSP becomes stage T2d (unsigned PD on the CDSP; firmware and SDK licence open);
    it needs one PM-signed trial.
  - D-T1..D-T18.
- **PM:** "focus on getting the Meta controllers to work first, then we can worry about Frame/other
  controllers. Most likely, users will own the Quest 3 and controllers, or a Quest 2 and
  controllers."
  - Order on Q3: 3DoF head → 6DoF head → Touch Plus (inputs, then 6DoF) → hands → ring Touch on Q3
    → Frame/others.
  - On the Q2 port, its bundled ring Touch comes right after head tracking.
  - Reusing the Horizon pairing for bundled controllers fits this priority.
  - Still open for the PM: D-T3 (calibration source) and D-T16 (ground truth).


**J-166 · PM decisions: calibration export, no Lighthouse, Meta limits as default, no reliance on Valve, user-initiated updates, timing targets; CC-BY text downloaded.**
- **PM:**
  - head tracking in stages: agreed;
  - **D-T3 = export under Horizon plus self-calibration fallback** (never mount /persist);
  - **no Lighthouse**, so D-T16 needs another reference (the Arbiter recommends a printed-marker rig
    with a phone camera; pending);
  - Meta's safety limits and measurements are the benchmark. Exceeding one is an explicit,
    per-case PM decision, like overclocking. The Arbiter added that eye-safety (IR) limits are
    never exceeded.
- **PM questions:**
  - Does Meta dedicate 2 cores to tracking? Unknown; the 2-core figure was a planning guess. **PM:
    do not dedicate cores unless Meta does.** To be measured in an observation session on stock
    Horizon, which the PM offered.
  - How does Meta switch between controllers and hands? Public facts: the IMU going still or the
    controllers leaving view switches to hands; multimodal exists; Touch Plus is aided by hand
    tracking. Details to be measured.
- **PM:** plan as if **Valve does not respond or declines the letter's asks** (not the project);
  do not bank on Valve.
- **Updates (PM):** the user downloads SteamOS updates *through* FrameShift's on-device updater,
  which verifies Valve's signature and installs the applicable parts into the inactive slot.
  Arbiter: keep it user-initiated; Valve's server terms for third-party clients go on the lawyer's
  list.
- **Timing (PM):** something showable in 1–2 days; an image shippable to a few FXR testers in
  about 2 weeks.
  - The PM notes that Claude's sense of time is unreliable (memory saved). Plans are now made in
    PM sessions, review rounds and Chair turnarounds.
  - Arbiter proposal: (1) a branded per-eye splash demo built from the stage-3d stack; (2) a
    "FrameShift Preview" temporary-boot tester image (writes nothing; splash plus live
    diagnostics; Q3 v2.7), with a Chair request added to FS-A-013.
  - Both are being built offline; their runs need the PM.
- **CC-BY-4.0 text** downloaded with the PM's approval (3fa006b): the export's last blocker.


**J-167 · PM answers: no tester preview (wait for SteamOS); no external tracking reference (research community ports); Perfetto approved; no splash demo now; old relays withdrawn from public.**
- **Testers:** wait for SteamOS; no interim preview image.
- **D-T16:** no Lighthouse or mocap ("ridiculous"). The PM reports that others got 3DoF and 6DoF in
  their SteamOS ports. A research agent is scouring the public Quest ports
  (`docs/research/quest-ports-tracking.md`) and designing validation without external hardware.
- **Observation session on stock Horizon:** approved, including short Perfetto traces (trace files
  copied off, then deleted on the device). The session plan comes when the PM is home with a unit.
- **Splash:** SteamOS's own splash does not appear on a Quest (Frame U-Boot logos and Valve's
  lens-aware console are not run). The Arbiter proposed Meta logo → FrameShift → Steam logo,
  with Valve's logo read at runtime from the user's own image, never shipped. **PM: not now** (no
  demo). The idea is kept for the product splash.
- **Export review 2:** NO-GO on small items (wording and a redaction-order bug). Hand merges for README, JOURNAL and RECOVERY. Fixes are in progress.
- **PM: withdraw all relays from the public copy**, including the 44 already public. They remain in
  public git history (2158d06) unless it is rewritten; that is a separate PM decision.


**J-168 · PM: our own FrameShift splash (no Steam logo); next milestone, the SteamOS desktop; milestones not time; the bridge diagram.**
- **Splash:** our own FrameShift logo only; never Valve's. Artwork spec given to the PM: one
  square PNG of about 1024×1024, black or transparent background, logo centred, bold shapes; an
  optional PNG sequence for animation. It is placed per eye with the proven rotation and swap.
- **Milestone (PM):** boot to the SteamOS desktop or virtual environment and show SteamOS
  working, "as others have done". It needs the GPU, because Valve's image has no software GL. A
  research agent is surveying how community ports booted SteamOS (kernel, display, GPU,
  image changes) → `docs/research/steamos-ports-survey.md`. It also asks for the fastest SAFE path.
- **Planning (PM):** checkpoints and milestones only; time is irrelevant. The PM rejects
  "years": others booted SteamOS within weeks.
  - Arbiter: the multi-year figure applied only to full Horizon-parity tracking (head, both
    controller families, hands), never to booting SteamOS. Others used shortcuts we decline
    (unsupported shortcuts, modified images, no safety layer). Our safety gates add milestones, not
    years.
- **The PM's diagram:** Meta hardware (Quest) ⟷ FrameShift FOSS ⟷ Valve firmware (SteamOS). It
  matches the architecture: Meta firmware read from the user's device; our kernel from GPL source,
  the GPU bridge, safety, tracking, USB and display in FrameShift; SteamOS unmodified.

- **Relays in public history (PM):** "It's fine if the past relays are in the history. Just make
  sure they are removed from the public repo moving forward." No history rewrite; the next export
  deletes them and keeps them withheld.


**J-169 · Splash format: Meta's boot animation is a live 3D GLB; ours is designed once in GLB, pre-rendered for early boot, live 3D later.**
- **Read-only, names only**, from the v2.7 `system_ext` image we hold (WSL ~/work/geom-x, debugfs
  -c): `/system_ext/etc/bootanim/` holds `meta-horizonos.glb`, `meta-animation-config.json`,
  `meta-colors.png` and `meta.bin`. No contents were opened. Horizon renders its boot logo live in
  3D, in stereo, on the GPU [D].
- **Plan:**
  - The PM designs the FrameShift logo as a GLB (glTF binary, an open Khronos standard).
  - **Early boot (pre-GPU):** our KMS splash plays a pre-rendered PNG sequence per eye, with the
    proven rotation and swap.
  - **After the GPU route works:** live stereo 3D using our own renderer and an open glTF loader
    (e.g. cgltf, MIT; licence-check). Never Meta's files or program.
  - A GIF is also acceptable (converted to frames).
  - Guidance: low-poly, simple materials, a 2–4 s loop, dark/transparent background, no
    edge detail.


**J-170 · The bootloader logo stays Meta's; community tracking ports surveyed (dbeda68); PM: pass = Horizon parity.**
- **Bootloader logo (PM question):** drawn by Meta's ABL (the splash partition is empty), so it is
  part of the boot chain: never modified (FS-R-001). It includes the unlocked-state warning screen.
  The FrameShift splash starts when our kernel takes over the display.
- **Community tracking ports** (`docs/research/quest-ports-tracking.md`, not yet reviewed):
  - Only one live 6DoF attempt: cstahly/quest1-bootloader-to-VR (MIT), Basalt via Monado on
    Quest 1. Its owner rejected it (lost lock on fast motion, lag, low light).
  - Elsewhere 3DoF only (Quest1-SteamOS: no licence; Block-Flock: no licence; quest-kexec-q2:
    GPL-2.0 / BSL). YusufOzmen01's "6DoF" is Meta's own tracker in a second Android.
  - Reusable: the Basalt epipolar bug fix (`optical_flow.h:210`), 2 BSD-3 patches, MIT scripts, the
    quality-gate design, the Q2 Monado driver structure, QuestSLAM (MIT) for logging Horizon
    poses.
  - Validation without external hardware is ranked (fixture stations, Horizon pose logs, printed
    boards, self-consistency, yaw steps, slow-motion latency). It replaces D-T16.
  - AI-directed text: cstahly's docs carry handoff notes to its author's own agents (asking
    nothing of us); Quest1-SteamOS's README states it was written by Claude. Both were reported to
    the PM and ignored. Reddit and the Nura wiki were not readable; FXR was not searched.
- **PM decision (D-T11):** PASS = matching Horizon measured on the same unit; the fixed numbers
  stay as goals to beat. Published Quest 3 numbers (Duke 2024) put Horizon around 1 cm typically
  and over 10 cm in hard scenes [C].


**J-171 · Fan fix approved, with on-screen fault feedback requested; SteamOS-ports survey (a95e822); observation plan (706b0f2); logo-transition idea; external-source reading offer.**
- **K-15/K-16 fan fix: APPROVED** by the PM, after explanation. **PM request:** visual feedback
  telling the user which sensor or component is faulty before the headset shuts down. This goes
  into thermal part 2 (design below).
- **Thermal part 1** (feat/thermal-service, 19a1c61): suites pass; adversarial review running.
  - **PM decisions:** J-145 mid-run (the battery reaching 30 °C while charging) = **warn only**,
    with the normal tiers deciding any shutdown; **PMIC die-temperature channels are required
    before READY** (identified at T0).
- **SteamOS-ports survey** (`docs/research/steamos-ports-survey.md`):
  - Nobody has booted SteamOS on a Quest 3, and nobody booted Valve's Frame image unchanged on any
    Quest.
  - Quest 2 (quest-kexec-q2, GPL-2.0): a chroot rootfs with Steam, a patched gamescope, its own
    Turnip-on-KGSL plus Zink (the route-(a) style); Steam UI in both eyes plus 3DoF; CPU caps only.
  - Quest 1 (Quest1-SteamOS, no licence): Valve's generic Holo rootfs, Meta's GPU blob via
    libhybris, Big Picture and Aurora at about 40 fps.
  - No community GPU approach is faster than (e′) for a pure desktop.
  - On the Frame, the Steam UI and Plasma run inside SteamVR, so a viewable desktop needs
    vrcompositor plus our HMD driver.
  - Fastest safe path: K1a → K1g → full fs-thermald → K1i → **R-1 "SteamOS boots"** (Valve's
    systemd, unmodified 0.4.5 in RAM, no GPU) → G1 → G1c → G2 → PD-13 → **V0 "desktop in headset"
    (fixed pose, proposal)** → V1 3DoF.
  - **AI-directed text (reported to the PM):** gitlab HttpAnimations/neoframe has files addressed to AI agents (AGENTS.md, CLAUDE.md); not followed. autune1/steam-frame-tinkering has a CLAUDE.md that was not
    opened.
- **Observation plan** (the observation plan (private)): 15 PM steps, seven 30 s
  Perfetto scenarios, about 35–45 min; atrace excluded (it would setprop); never opens /dev
  nodes; an adversarial review is running. PM decisions are pending (trace files local only;
  trace_processor download; the S6 app).
- **Bootloader logo (PM clarification):** the PM wanted its format and size, to match them. It is
  embedded in Meta's ABL (not a file), so it is not extracted; we measure its on-screen size and
  position instead.
  - The PM would like an animation from the Meta symbol into the FrameShift logo. **Trademark
    concern:** J-156 says no logos; the Arbiter recommends starting from a neutral shape or glow
    at the same size and position (pending the PM).
  - The PM cannot author GLB; the Arbiter's agents can build the animation from the PM's 2D
    artwork.
- **External sources:** the PM offered to read Reddit, the Nura wiki and YouTube via ChatGPT or
  screen captures; the URLs and a prompt were given.


**J-172 · PM: splash later, R-1 "SteamOS boots" as the first big milestone, trace_processor approved; the milestone table revised; reviews of thermal part 1 and the observation plan; export trial clean.**
- **PM:**
  - splash transition: "not worry about this for now", to be revisited;
  - **R-1 "SteamOS boots"** confirmed as the first big showable milestone, then the GPU stages,
    then V0 "desktop in headset";
  - **Perfetto trace_processor download approved** (official release, gitignored tools/perfetto/);
  - trace files stay local, with their hashes in the repo.
- **Milestone table:** PROJECT_SETUP §3 rewritten (e40cf01) as M1 ✅, M2 ✅, K1a ▶, K1g, TS, K1i,
  R-1, G1, G1c/S0, G2, G3/G3s, V0, V1–V5, P1, with pass conditions. the private game plan §3 marked superseded.
- **Thermal part 1 review:** GO-with-fixes.
  - MAJOR-1: fan checks starved by oscillating demand; unbounded rpm_per_sec.
  - MAJOR-2: one missing fan zone disables all fan control.
  - MINORs: int32 overflow (confirmed with UBSan), frozen-value rule, ddr zone, cap read-back,
    policies.
  - Verified: K-15/K-16, read-only fs-metacfg (seccomp), the 2 s budget, fuzzing, real images.
  - The fixes were sent.
  - Arbiter decisions on §8: Quest 2 READY = headless idle with min caps; F4 redefined against DT
    max-rpm at T3a (the PM keeps it); O20 agreed with the soc-usr and tsens common-mode caveats;
    raw demand zone accepted; K-23 tie-breaks confirmed; part-2 additions listed (suspend/resume,
    signal 38, softdog after download_mode=0, a log-only build, a product build without overrides,
    GPU cap mandatory).
  - The PMIC channels stay required before READY (PM, stricter than the reviewer suggested).
- **Fault feedback (J-171):** designed in PLAN.md §2.1 (R43–R50); the core emits
  `warn|shutdown:<reason>[:<seconds>]` per tick; parts (b)–(e) are part 2.
- **Observation plan review:** GO-with-fixes.
  - MAJOR: syncboss_nsync dump_stats writes the kernel log (removed); tracefs is not restored by
    traced (pre-checks added); no wait timeout or abort path (fixed).
  - PM question pending: the fd-link scan may see /persist link names (filtered on the device).
- **Export:** 0 refusals at 9653677 (2,453 files); relays withdrawn, hand merges recorded; the
  observation plan is withheld from export. A final review is running before the PM sees a
  summary.


**J-173 · fd-scan approved with the filter; trace_processor downloaded; thermal fix round done (d852349); final export review (B1, M1, M2).**
- **PM:** the observation session's open-files scan is within J-132 **with the on-headset
  filter** that drops any /persist name before output (D-O6 resolved).
- **trace_processor:** the observation-plan agent declined to download it, because it had no direct
  PM consent; the PM's consent was given in chat (J-172). The Arbiter downloaded the official
  Perfetto v58.2 `windows-amd64.zip` (80,941,801 B, sha256 `5a00dbb9…1409`) into gitignored
  `tools/perfetto/v58.2/`. Nothing has been run from it yet.
- **Observation plan:** review fixes applied (7adec57).
- **Thermal part 1 fix round** (d852349):
  - F2/F5 run through the ramp after a 15 s grace; the ramp is capped at 60 s; rpm_per_sec is
    bounded to 50–2000.
  - A missing fan zone is fault F8 and the fan is still driven; trips are asserted against the
    table.
  - 64-bit arithmetic; frozen non-virtual sensors; CRITICAL/EMERGENCY fail closed.
  - Quest 2 min caps and policies; F4 measured against DT max-rpm; the contradiction rules.
  - 85/85 scenarios C = Python, native and aarch64.
  - K-32 confirmed by the Arbiter (CRITICAL/EMERGENCY latches T4 as `shutdown:<name>`).
  - A delta review is running before the merge.
- **Final export review:** GO-with-fixes after B1.
  - B1: the PROJECT_SETUP milestone-table hunk had no resolution, so the export refused at HEAD
    ('theirs' recorded).
  - M1: the manifest check must be regenerated.
  - M2: stale status rows in README and JOURNAL.
  - Minors: withheld-file references, relay leftovers, drive-letter mentions, privileged-adbd plans, a tool name to
    remove, the research index, a third-party AGENTS.md quote, the serial
    prefix.
  - The PM summary is prepared. The fixes were sent; nothing is pushed.


**J-174 · Public export ready for the PM's approval; thermal delta review GO-with-fixes; K1a and fs-blkguard started offline.**
- **Export:** all final-review items fixed (0366157..67c6810).
  - The Arbiter's own dry run at HEAD: refused 0, scope hits 0, guard 0, rules unused 0.
  - 1,327 new files included; 44 relay files withdrawn by policy; 22 conflict hunks resolved and
    recorded; the manifest check is regenerated by the exporter.
  - **Awaiting the PM's approval** to push (run in a clean clone without a remote, with the fixed
    noreply identity and UTC dates).
  - Watch item: new private commits keep adding out-of-scope text; the exporter catches it, but
    each export may need new rules.
- **Thermal delta review:** GO-with-fixes.
  - The fan fixes hold; no hot-device escape path.
  - A new false-shutdown path in the K-27 frozen-sensor rule (a steady battery temperature
    flagged as frozen).
  - An older immediate shutdown on a single transient fan read error while trip ≥1 is active.
  - Minors: tach noise plausibility; a stuck-at-lower-target window; atol in the cap read-back.
  - The fixes were sent.
- **Offline builds started:**
  - **K1a** (our kernel: expected CRC-neutral options, stock modules; gated and packaged with a
    fresh nonce; branch feat/k1a-kernel);
  - **fs-blkguard** (the K1g boot-chain write guard: a kernel patch covering all write paths
    including SG_IO, discard and BLKPG; safe-by-design probes; a QEMU proof; branch
    feat/blkguard).
  - No device actions; the K1a run awaits the Chair and the PM.


**J-175 · Public repo updated: a single clean commit force-pushed (PM-approved).**
- **PM:** approved the push. After the pros and cons of a force-push vs a normal commit, **PM:
  force-push one clean commit** (the documented method). The repo had been public for only about
  2 days; forks or clones may keep old copies, and GitHub may cache old commits by ID.
- **Procedure:**
  - fresh clone of the public repo with its remote removed;
  - `export_update.py . 40b569f HEAD(378d242)`: refused 0, scope hits 0, guard 0, rules unused 0;
    1,327 new, 44 relay files withheld;
  - `public-commit-r2.sh`: one orphan commit `f8dbd4da…`, author and committer the PM's GitHub
    noreply identity, 2026-10-15T07:46:02Z UTC, 2,454 files;
    `relays/` holds only its README;
  - the Arbiter's own scan: no serials, scope hits only in allowed negative tests and Valve's
    adbd design.
- **Pushed:** `git push --force` to continuumxr/frameshift main: 2158d06 → **f8dbd4d** (forced
  update); confirmed via the GitHub API. `../frameshift-public` was reset to origin/main.
- **Next export base:** private 378d242 → public f8dbd4d.


**J-176 · FS-A-012 SENT; the unattended Horizon observation (subset) on Unit 1; thermal round 4.**
- **FS-A-012 SENT by the PM** (2026-10-15), all four files:
  - `FS-A-012.md` `48a9510d…048d`;
  - `-raw.zip` `6700e284…e8ea`;
  - `-package.zip` `2a8cd98d…f9ed`;
  - `-image.zip` `91eba83b…8d2d`.
  The PM also asked the Chair to read Reddit, the Nura wiki and YouTube (the URLs and prompt from
  J-171). Awaiting FS-R-012; FS-A-013 is finalised after it.
- **Observation session, unattended subset** (the PM was asleep):
  - a quick re-review of the plan's fixes: GO for steps 1–7, 13 and 14; the script hashes matched
    Appendix E.
  - Identity matched (Unit 1, build …0520, digest 66b76196…, `_a`). Gate: 290,
    status 5, health 2, 100 %.
  - The static snapshot was taken (97 kB).
  - **Perfetto NOT run:** the top-level `set_event` held `bpf_trace_printk` (Android's own), so the
    stop rule applied, since traced_probes would clear it at teardown. No Perfetto sessions were
    active.
  - Instead, the read-only idle-on-desk data: snap ×2, threads ×2, top ×1 (no wearer).
  - Closing: 300, status 5, no leftovers. No other state change.
  - Evidence committed (8b3216f, no /persist strings). An analysis agent is running; the next
    Perfetto attempt should use a separate ftrace instance.
- **Thermal part 1, round 3 fixes** (529e205):
  - a continuous ramp expectation from the measured rpm (the healthy-fan false shutdown fixed);
  - F9 noise floor and 3-of-5 rule; C = Python per-episode; stuck latched, tsens only; fan reads
    6 of 10;
  - one declared limit (a fan stuck at the lower of fast-alternating targets; backstops F2/F5/F9
    and the temperature tiers);
  - 102/102 scenarios. Round-4 review running.


**J-177 · Horizon observation analysis (b1b779e): no cores reserved for tracking; a cpuset split of system/perception (0–2) vs apps (3–5).**
- **Results** (a private research note; idle, not worn, tracking paused):
  - **No cores are reserved for tracking.** Horizon splits by cpuset: CPUs 0–2 for system and
    perception (the `tracking` cpuset 0–2 is shared with sensor, compositor, MR, foreground and
    background); 3–5 for the app; top-app and root span 0–5; no kernel isolation.
  - Confidence: high for the idle layout, low–medium for worn use.
  - trackingservice: 62 threads on 0–2, no RT at idle, nice −20 for camera/world/body threads.
  - The sensors HAL holds the SyncBoss nodes, video0/1 and v4l-subdev0–19; camera threads FIFO
    48–49; `sb_control` FIFO 46.
  - `syncboss:spi_thread` FIFO 51 on CPU0.
  - CPUs: 6 × Cortex-A78C (0–1 at 2.05 GHz, 2–5 at 2.36 GHz).
  - **Offload:** `/dev/adsprpc-smd-secure` is held by trackingservice, mrsystemservice, perf_service
    and the rpc daemons; kgsl is not used by trackingservice; nobody holds `/dev/cvp`.
- **Implication (PM rule J-166: do not dedicate cores unless Meta does):** D-T18 changes from "2
  reserved cores" to Horizon's layout: tracking shares the system/perception cpuset (0–2) with
  RT/nice priorities, and games get 3–5. To be confirmed in a worn session.
- **Perfetto:** use the existing-instance approach (`instance_name: "mm_events"`). Unit 1 lacks
  that instance; creating it is one tracefs `mkdir`/`rmdir`. **PM decision pending** (recommended
  yes, after a read-only SELinux preflight). New stop rule: top-level tracing state unchanged
  after each trace.


**J-178 · FS-R-012 received (FS-R-012, private review record): display milestone ACCEPTED; standing stage-3d repeats CONCURRED (limited); follow-ups after AA retained.**
- **Accepted:** the display milestone on both Quest 3 units (readable per-eye output, eye mapping,
  subjectively level). It does **not** establish calibrated stereo, tracking, sustained operation
  or a SteamOS boot. The registrations of iii-b, 3c, practice and the 3d runs are accepted as
  stated, with departures kept.
- **§4 standing repeats CONCURRED:** fixed package only (image fcca5ee7, fs-pattern bfafad97, the
  19 host pins in package zip 2a8cd98d), both units, build …0520 slot A.
  - Each repeat needs: a fresh nonce plus the nonce-only check, the ledger, pins and preflight,
    serial/firmware/module-index checks, the checklist with fresh B and E, the PM present and
    typing, BA/BF/dwell/AF/AA, the deadline and guards, one step at a time, the §3 warning review,
    the §5 thermal conditions, and reporting in the next relay.
  - Standing phase A is accepted, but its automatic checks run each cycle. Carry-over is limited
    as implemented.
- **§5 thermal (binding):** the single reading is accepted (35.0 °C; status 2 only below 30.0;
  BA10 the same; battery above 50 %).
  - **DO NOT CONCUR with dropping follow-ups:** for repeats, keep at least one reading about
    5 min after AA, continue while rising, and apply the ≥40 °C procedure.
  - The J-145 "follow-ups end in Android" PM decision is **overridden by the binding ruling** and
    must be reflected in the tools and the walkthrough.
- **§3 reset:** the exact A/B/C reset is accepted for these repeats. The classifier's next revision
  must report kernel WARNINGs in every phase; until then, inspect every phase's decoded probe
  before another run. A new warning or changed outcome pauses repeats. Dropping step A is not
  nonce-only; it needs a package review.
- **§6:** derived-baseline exception for this display package only. Prepare a reviewed passive
  read-only row set separately. Direct readback is to be done when practical.
- **§7:** executive actions noted or accepted item by item.
  - D6/D7 accepted; a dev trust key only for an explicitly chosen dev channel, never as a
    fallback.
  - **The 0.3.0 recovery-image fallback exception accepted** (081a38c0…).
  - Rootfs assembly concurred offline; do not call "stable/0.4.5" cryptographically signed.
  - Licence: preserve notices and assess derivative sources.
- **§8:** a debugfs read-only package may be prepared (optional). The calibration runtime-read
  class is accepted in principle; **the PM's /persist prohibition stands**. The thermal-config
  package must identify the active logical view in super.
- **§9:** the v66 concurrence is CLOSED; leave backlight_changes_blocked unwritten; continue
  offline work. A rebuilt-kernel boot, GPU workload, installed slot, Valve console boot or splash
  change each needs a concrete package. **FS-A-013 should bring the stage 3/4 execution
  proposals.**

**J-179 · PM decisions (Perfetto instance yes with preflight; K1a ACM only; QEMU install); Chair survey cross-checked; HibiscusXR assessed; worn session deferred (temperature gate); thermal round 4 NO-GO; K1a offline status.**
- **PM decisions (2026-10-15, chat):**
  - **Perfetto `mm_events` instance: YES, with a preflight.** First a read-only SELinux check; then,
    with the PM present, the exact commands are listed inline for the PM's OK. To be disclosed
    to the Chair in FS-A-013 before it is used.
  - **K1a: ACM only** (NCM removed from K1a; NCM gets its own later step).
  - **QEMU (`qemu-system-arm`, Ubuntu archive) in WSL approved** for fs-blkguard's VM tests; the
    PM installs it with their sudo password.
- **Chair's tracking survey (pasted by the PM)** cross-checked: `docs/research/quest-ports-tracking.md`
  rev 0.1 addendum (`da7d5b1`). It supports the claim that no validated native 6DoF
  head-and-controller tracking exists on any Quest. Quest1-SteamOS captures cameras through Meta's
  libraries (libhybris); quest-kexec-q2 replays a recorded Meta camera start-up; reframed-vr
  (now `a92da3b`) has Pico live-capture code, tested only on replays. The three Reddit leads are
  unverified (Reddit blocks our tools); the Nura wiki sits behind a bot check (not bypassed). No
  AI-directed text was found.
- **HibiscusXR** (PM lead; `docs/research/hibiscusxr.md`, `e5b3bf5`): an Android VR OS for the
  Pico Neo 2, not on any Quest. Its hand-tracking branch is Monado Mercury with Mercury's stock,
  unlicensed models, reached through reverse-engineered vendor camera access, and was never shown
  working. AGPL-3.0. No help for tracking; a few ideas to re-implement. The project's own
  `AGENTS.md`/`CLAUDE.md` files were read as data only.
- **Worn Horizon session, attempt 1 (Unit 1, 15:07Z):** controllers could not be paired, so the
  session was planned without them (FsSample fallback; no Perfetto). The step-2 gate
  matched identity (v2.7, vbmeta 66b76196…, slot `_a`, shell uid) but **temperature 360 (36.0 °C),
  status 3** failed the < 35.0 °C entry rule. Stopped there and deferred by the PM; only one
  read-only gate reading was taken.
- **Thermal part 1, round-4 review of `529e205`: NO-GO.**
  - BLOCKER: a healthy fan with tach noise and alternating demand can get a false fan-trip2
    shutdown (K-43/K-36 hold).
  - MAJOR: a healthy fan with 0.5–2 % failed reads gets a `t4:fan` shutdown.
  - MAJOR (FS-R-012 §8): fs-metacfg reads raw `vendor_<slot>` extents without establishing the
    active logical view (snapshot/merge state).
  - Four MINORs, including a C ≠ Python divergence on F5 and two scenarios that do not test what
    they claim. The declared limit is acceptable with wider wording. Fixes are under way, then
    round 5.
- **K1a offline** (`feat/k1a-kernel` `84f876f`): kgate CRC gate PASS (2601/2601, 0 of 14,059
  exports changed); candidate image built (never booted); module-load simulation 4/4. The
  bit-identical rebuild check and the host side (collector, observer, classifier) are still to
  do. The Step 0b readback precondition is planned (read-only, AVB-covered ranges).
- **FS-A-013 draft** updated for FS-R-012 (`62ddd62`); it awaits today's facts and the final
  adversarial review.

**J-180 · K1a package complete offline (bit-identical rebuilds); thermal part 1 rounds 5 and VAB policy; fs-blkguard complete offline; PM decisions (built-in thermal table on Virtual A/B; blkguard device run without Q11); FS-A-013 carries the K1a package.**
- **K1a** (`feat/k1a-kernel` `d5153d4`):
  - Runs 2 and 3 are **bit-identical** rebuilds of run 1: Image `087f0e72…`, vmlinux `8686b77c…`,
    Module.symvers `0ce513c3…`, .config `4aa0c894…`, System.map and all 278 .ko. Run 3 used the
    final `build-kernel.sh`, which checks all toolchain pins first (`9dfa4e7`, `1d288e6`).
  - Candidate `ecbcbd4f7b6f43c0` (sha256 `42cda89e…`), ACM only, never booted.
  - Tests: builder 46/46, harness 11/11 (194 checks; the kernel-log and /proc/mounts fakes now
    served through a seccomp listener), host 52/52, module-load 4/4, readback 16/16, bounds 9/9.
  - Internal reviews: host side GO-with-fixes (all fixed); kernel/image NO-GO only for the missing
    rebuild proof, now closed.
  - Two pinned-file gaps (the WALKTHROUGH temperature rule; the SIGNOFF phase-B "battery > 50 %")
    are being fixed before the relay.
- **Time-estimate note (PM, 2026-10-15):** the offline K1a work took about a day of agent work; one
  kernel build takes about 3 h. The pacing items are Chair rounds, PM sessions and build hours.
  **FS-A-013 therefore carries the concrete K1a package** (§3.16, ask (g): one attended K1a boot
  on Unit 2 after the R0–R5 readback passes) instead of waiting for an FS-A-014 round (`a217ebe`).
- **Thermal part 1:**
  - Round 5 of `f0cb3aa`: GO-with-fixes, no BLOCKER; all four round-4 false shutdowns are gone.
  - MINORs fixed in `cf46a5d`: the noise-widened declared limit; the rotor-lag envelope ≤ 1 s,
    with a T3a measurement item.
- **PM decision (Virtual A/B):** on Virtual A/B firmware the service always uses its built-in
  table (option B; meets FS-R-012 §8 without inferring the active view).
  - Implemented in `7e900dd`: reader code `vab-policy` refuses any `ro.virtual_ab.*` value other
    than `false`, so every v2.7 Quest 3 uses the built-in table.
  - The built-in thresholds equal the values parsed from Meta's reviewed v2.7/v66 files (J-123);
    fan rules come from Meta's GPL DT. No protection is lost on v2.7.
  - J-118's runtime path stays for non-VAB firmware. Proving the update state from metadata is a
    possible later step, not planned.
  - Delta review of `7e900dd` pending.
- **fs-blkguard (K1g)** (`feat/blkguard` `f65a941`; `docs/research/fs-blkguard-design.md`):
  - Patch GPL-2.0-only, 902+/3−; kgate PASS with the patch (Module.symvers byte-identical).
  - 74,272 policy checks; QEMU 213/223/181/156; UML 192/212/170/82; 9 hook-disabled mutants all
    detected.
  - A reviewer found and closed a real hole: Meta's ufs-qcom `UFS_IOCTL_QUERY` could rewrite
    `bBootLunEn`.
  - **PM decisions for its later device run:** no Q11 (no read-write open of real boot storage);
    boot partitions hash-read before and after (reads only); super and metadata stay protected
    until the install decision.
  - Four Chair questions (C9) are in FS-A-013 ask (h).
- **Usage-limit interruption** (around 17:05Z): all agents were cut off and resumed after the
  reset. Their clones were checked before continuing.

**J-181 · K1a on both units; thermal part 1 merged; device-health design; PM: product calibration read approved; community partition-hazard note; factory-reset research started.**
- **K1a on both units (PM request).** `feat/k1a-kernel` `12086a4`; SIGNOFF-k1a `da5ca68c…`,
  16 pins; host tests 89/89, readback 18/18.
  - Order: Unit 2 first. Unit 1 only after Unit 2's hash-bound `classify-k1a.json` shows K1A PASS,
    or K1A REVIEW with an Arbiter clearance file.
  - FAIL, INTEGRITY FAULT or INCONCLUSIVE blocks Unit 1, which then needs a new package review.
  - Each unit has its own nonce, R0–R5 readback and ledger entry.
  - FS-R-012 §5 (battery > 50 %, the post-AA follow-up) is in the K1a walkthrough, checklist and
    SIGNOFF.
  - Three delta reviews; the last two MAJORs are fixed and a narrow check is running.
- **Thermal part 1 merged to master** (`02a3717`; branch head `1a334ae`).
  - The delta review of the Virtual A/B policy is GO.
  - Its MINORs are fixed: all whitespace is trimmed as in AOSP `LoadProperties`; the
    "positively established" wording is corrected to "deny-list plus the M-21a policy"; the
    row-adding condition is written down.
- **fs-blkguard** `bcd8886` applies the PM decisions: no Q11 on a headset; hash-reads before and
  after in the PROPOSAL §5.1 form; super and metadata stay protected.
- **Device health** (PM requirement: faulty sensors never block boot or use, and a once-per-boot
  notice for any faulty part; safety faults go to the thermal shutdown).
  - `docs/research/device-health-design.md`: rev 0 `46d027b` was NO-GO in review; rev 1
    `632ca22` is under delta review.
  - **The review found:**
    - without `/persist` calibration, Meta's SyncBoss driver never enables proximity on any unit;
    - a hung async-probe module can starve the thermal modules (fixed by three-phase loading,
      H-1);
    - SyncBoss prints calibration values into the persistent journal (H-14 kernel patch).
  - **PM decisions:**
    - the notice appears once every boot while a fault persists, nothing saved, plus a Device
      health list; an optional "don't remind me" at P1, off by default;
    - sleep requires proximity AND stillness, or the power button; with proximity unavailable,
      our own idle blanking applies;
    - **D-T3: the product calibration read is APPROVED in principle.** Each user's own headset may
      read its own proximity and IPD calibration files, read-only, at runtime; values stay on the
      device and are never logged or exported; /persist is never modified. `fs-calread` comes at
      V0, behind a Chair-reviewed package.
    - The development-time no-/persist rule is **unchanged**.
  - **Arbiter decisions:** info-only faults appear in the notice; the IPD modules first load at
    V0; both firmware-loader fallback settings.
- **Community note (PM screenshot):** the partition write hazards reported by the community match
  FS-R-001 and fs-blkguard, which are stricter (`5b2aee3`, private notes).
- **PM questions answered in chat:**
  - **Porting to Quest 2:** the tooling and services transfer. The 4.19 kernel gate, the
    fs-blkguard back-port, the display bring-up, the thermal fan data and tracking need per-device
    work.
  - **Factory reset:** research started (a private research note, pending).
- **FS-A-013** `ad39d72` carries all of the above (asks (g) both units, (h) blkguard, (i) device
  health). Final adversarial review next.

**J-182 · PM: Valve crash reporting OFF by default; K1a final; device-health rev 2.1.**
- **PM decision (2026-10-15): Valve's crash reporting is off by default on FrameShift.**
  - `60-crash-hook.conf` (the core_pattern pipe) and `steamos-log-submitter` are masked.
  - Crash data stays on the headset, with no identifiers.
  - An opt-in may be reconsidered only if Valve welcomes reports (a possible Valve-letter item).
  - Recorded in the device-health design (`395a021`) and FS-A-013 (`385299e`). The facts come
    from 0.3.0 and are to be rechecked on 0.4.5.
- **K1a final:** `feat/k1a-kernel` `2f9eee1`; SIGNOFF-k1a `7a05fed6…`, 16 pins; host tests 90/90.
  The narrow check of the last two MAJOR fixes is GO-with-fixes; 5 of its 6 MINORs are fixed.
  The 6th is documented as a residual risk: a deliberate hand edit of an outcome record is not
  detected.
- **Device-health design rev 2 / 2.1** (`2f08e2a`, `395a021`). The rev 1 delta review was
  GO-with-fixes, and all fixes are applied:
  - H-14 covers every print site, with a no-dyndbg lint and a srcversion gate;
  - fs-calread: no core dumps, a journalled-ext4 reader variant, fs-blkguard as the write
    barrier, the staged files deleted after use;
  - fs-ipd (millimetres only to SteamVR);
  - V0 idle blanking honours idle-inhibit, and rendering stops or throttles while blanked.

**J-183 · PM: install model (slot takeover, no dual-boot); factory-reset decisions; D-T3 decided (tracking calibration read); no reverse engineering of Meta's tracking.**
- **Install model (PM, 2026-10-15; supersedes PD-9's dual-boot research):**
  - **No dual-boot.** FrameShift installs the way a HorizonOS update does: it takes over one A/B
    slot and boots from it, and a normal power-on boots FrameShift. Apart from the bootloader
    logo, the user should never feel it isn't stock.
  - The design study a private research note (in progress) is re-scoped to this
    as its primary design. It covers: the writes, the order, interruption safety, marking boot
    success in the GPT slot attributes, A/B fallback, Horizon's slot possibly being deleted
    (one-way), return-to-Horizon by reflashing or sideloading Meta firmware, verified-boot behaviour,
    Valve's updates inside our slot, and the rulings needed (FS-R-001 scope, §6A 8b, an
    fs-blkguard install mode).
- **Factory reset** (a private research note rev 1.1, `39fae2b`; rev 1 review
  GO-with-fixes applied in `0f8c9f3`):
  - FR-Q1: **solve it first.** Nothing goes to userdata until a normal power-on can never land on
    Android's recovery screen. The slot-takeover model is the answer to pursue.
  - FR-Q2: the carved partition is **dropped**.
  - FR-Q3: the return-to-Horizon route is **accepted**. It is to be revisited under the slot model (Horizon may need reflashing).
  - **New findings:**
    - an item for FrameShift's layer (FR-C5, kept private).
    - Polkit rules apply in filename order, so our deny rules must sort first (FR-C7).
    - EFI_VARS_PSTORE=y is present in both the stock kernel and K1a, so K1a adds nothing
      (O-FR9).
- **D-T3 decided (PM):**
  - The product reads each user's own **tracking calibration** from `/persist`: camera
    intrinsics/extrinsics, IMU bias and noise, time offset. Read-only, at runtime; values stay on
    the device, are never logged or exported, and `/persist` is never modified.
  - Our converter turns it into Basalt's format; self-calibration is the fallback.
  - It needs a Chair-reviewed package.
  - The format is worked out only from the PM's own offline backups (read-only).
  - `tracking-input-route.md` rev 2.4.
- **PM question (2026-10-15): an FXR user got 6DoF and controller tracking using Meta's own
  model.**
  - Answer: **no reverse engineering of Meta's tracking software.** It breaks the no-disassembly
    rule and our legal separation, and the Valve letter states it.
  - What transfers legitimately: per-unit factory calibration (above), Horizon as a black-box
    benchmark (D-T11), and open-source constellation-tracking prior art (Monado, BSL-1.0).

**J-184 · PM: clean-room reverse-engineering policy (replaces the "no disassembly" rule); installed-boot design rev 1; FXR tracking kit analysed.**
- **Correction (Arbiter):** the "no disassembly" rule was the Arbiter's over-generalisation. It
  turned the PM's J-90 *publication* rule and the J-120 wording into a working rule, and J-152
  enforced it. The PM never forbade study, only copying and redistribution.
- **PM decision (2026-10-15): clean-room study.**
  - Meta's, Qualcomm's and Valve's binaries may be disassembled and studied privately, to learn
    how things work.
  - Findings are written up as functional facts, never code. Implementations are written only
    from those facts and never copied.
  - Disassembly output and RE notes stay private: never in the public repo, never redistributed.
  - We still never run or ship Meta's tracking software (no Meta provider).
  - The change is disclosed to the Chair (FS-A-013). A legal check comes before any public release
    that relies on RE findings.
  - Updated: PROJECT_SETUP §0 (compatibility layer); PROVENANCE-POLICY items 5 and 2. In the Valve
    letter (still held), ask 7 no longer promises "we will not reverse engineer"; it states a
    preference for a documented interface.
  - J-183's "no reverse engineering of Meta's tracking software" is narrowed accordingly: we may
    study it clean-room, and we never run or ship it.
- **Old scratch files** (2026-10-09, the dark-display investigation's ABL study) stay in the private scratch area. They
  are permitted under the new policy and never published.
- **Installed-boot design rev 1** (`5d2b5e9`, `9685e97`; review of rev 0 NO-GO, all fixes
  applied). Even T1, an in-place takeover of the active slot's boot, needs:
  - a success-mark writer (fs-bootctl, IB-C4), because ABL resets retry to 7 on a flash and
    decrements it on each boot [C, generic ABL];
  - a disclosed residual: the boot menu's "Switch Boot Slot" can start slot b's old Horizon over
    FrameShift's data, and nothing permitted prevents it;
  - recovery by holding volume-down at power-on (to be checked on Unit 2 first);
  - a restore source: Meta's signed v2.7 boot.img, padded to the full partition.
  - New option **T1-L**: a minimal read-only second-stage loader in boot, which boots our kernel
    from userdata with its own A/B. Kernel updates then never re-flash boot. It ranks above T2.
  - Replacing ABL or XBL is impossible on secure-fused units.
  - PM items IB-P1–P6 and Chair items IB-C1–C8 are listed in the doc and still to be put to the PM.
- **FXR quest-tracking-kit** (private analysis `<private note, withheld>`,
  `18ccef4`):
  - It is a Meta provider: it runs Meta's tracking software.
  - No licence and no author, so no reuse. Never to be run on our units.
  - Facts worth confirming ourselves are kept in the private analysis.
- **K1a:** RECOVERY §4b corrected (PANIC_ON_OOPS off, PANIC_TIMEOUT=-1, the misc and pstore
  effects, download mode still possible) and RECOVERY.md pinned in SIGNOFF (17 pins).

**J-185 · FS-A-013 FINAL and bundled: READY TO SEND.**
- **Reviews:**
  - Final adversarial review of the relay: GO-with-fixes (0 BLOCKER, 7 MAJOR, 8 MINOR), all applied.
  - Delta: GO-with-fixes (2 MAJOR, 5 MINOR), applied.
  - Last delta: GO, with 3 wording MINORs applied before bundling.
- **Relay:** FS-A-013 (private review record), sha256 `76465c93a4c9ac0c269b03f8e2bce813cdae2008bb055a49170948689e8db2ed`
  (`8665dab`). It carries the concrete K1a package: ask (g), one attended boot on Unit 2, then on
  Unit 1 gated on a clean Unit 2 PASS. K1a is at `e921951`; SIGNOFF `5e0bdf9e…`, 17 pins.
- **Bundles** (gitignored; manifests committed):
  - `FS-A-013-raw.zip`: `fc1eeca2…4997`, 30 entries.
  - `FS-A-013-k1a-package.zip`: `fed1fdef…98e5`, 208 entries.
  - `FS-A-013-k1a-image.zip`: `aada4a31…64a7`, 11 entries; private image zip.
- **Arbiter's independent check:** every manifest entry recomputes, no ELF members, no
  private-set files.
- **Third-party RE findings (Arbiter rule, J-184 follow-up):** they are leads only, confirmed by our
  own observation or clean-room study before we rely on them.

**J-186 · FS-A-013 sent; FS-R-013 received (FS-R-013, private review record): K1a CONCURRED on both units; readback class accepted; later classes accepted for preparation.**
- **Sent:** the PM relayed FS-A-013 (4 files, J-185) on 2026-10-15/16.
- **K1a EXECUTE:**
  - One attended attempt on Unit 2, then one on Unit 1. Unit 1 runs only after a clean Unit 2
    outcome:
    - a live, bound K1A PASS **plus a manual MemTotal check** (the classifier doesn't require it;
      to be enforced in the next reviewed classifier revision);
    - clean AF/AA;
    - no recovery fault, manual power-off or dump mode;
    - the complete follow-up series below 40 °C and not rising;
    - the evidence inspected and reported to the PM.
  - Each attempt uses its own fresh nonce-only rebuild of reference `42cda89e…`; SIGNOFF
    `5e0bdf9e…`.
  - The single-reading admission and identity/slot before/after rules apply (with the "not
    measured" sentence). Follow-ups at about +5 and +10 min after AA (already in the K1a
    WALKTHROUGH).
  - The timers do not protect against a kernel hang. Th+260 is a fallback schedule only.
  - No automatic third attempt and no standing repeats.
- **Readback:** R0–R8 accepted (Q1), and R0–R5 may run as separate precondition sessions.
  - **Q-P:** [removed for publication].
  - **Q2:** [removed for publication].
  - **Q3:** hand-entered rows are fine for now.
  - **Q4:** the R7 region method is accepted.
  - The stage-3d adjunct is accepted.
  - Inspect R0's last three lines semantically (the checker doesn't).
- **Order:** K1a → K1g → K1i, with N1 before the RAM-root transfer. USER_NS/PID_NS stay separate.
  One pinned rebuilt module set with a per-module provenance/CRC table is acceptable.
- **K1g:** bring the exact patch, probe, gate and evidence. modules_disabled only for strict mode.
  R-1 residuals are accepted conditionally (prefer UFS unloaded for the first RAM root). Refusing
  USB disks is accepted for K1g/R-1.
- **TS:** T0–T5 and the probe-only KGSL class are accepted for preparation; T1–T5 run per unit and
  per composition. The built-in table for v2.7 is accepted, with the sensor meaning still to be
  validated. K5 is preferred for R11.
- **Bridge/M1/GPU:** the direction is accepted, as one coherent integration package; the
  contract items are listed in FS-R-013 §8.
- **Valve userspace:** all three forms are accepted for preparation. C3 (verity sparse RAM load)
  needs the memory budget first. D7: the exact hash pin is acceptable for private R-1 only. N1 and
  C13 are accepted for preparation.
- **Device health:** H-1, H-2 and H-14 accepted, with conditions. The product calibration lift is
  ACCEPTED in principle, including tracking calibration; unknown fields are never applied. The archive-drive
  analysis allowance covers the tracking files.
- **Factory reset:** FR-C1 preparation; FR-C2 inside our initramfs only; FR-C3/C4 stubs; FR-C5
  (kept private); FR-C6 EFIVAR_FS off; FR-C7 early deny verified against the real ordering.
  Installed boot, GPT attributes, success marking and slot switches still need their own rulings.
  Bring one bounded install-and-restore validation cycle.
- **Perfetto mm_events:** no objection, under conditions (FS-R-013 §12).
- **Clean-room policy:** no objection. It is to be called a "provenance/implementation discipline",
  not legal clearance.
- **Crash reporting:** default-off accepted; check other paths on 0.4.5.
- **Wording correction applied:** "No validated native 6DoF head-and-controller implementation was
  found in the inspected public sources." Updated in `quest-ports-tracking.md` and
  `tracking-input-route.md`.
- **Next relay FS-A-014:** the K1a readback and attempt results; it may bring K1g and the first
  TS package.

**J-187 · Worn Horizon session attempt 2 deferred by the PM.**
- 2026-10-16, Unit 1, controllers paired.
- The gate readings were read-only, shell uid:
  - 03:31Z: 380, status 3. Not met (just booted).
  - 04:09Z: 300, status 3, 80 %. Met.
- The PM then deferred the session before any scenario ran. Nothing else was run on the headset.

**J-188 · Overnight (offline): K1a merged; installed-boot design rev 2→5; K1g, thermal part 2 and TS T0 in progress.**
- **K1a merged to master** (`efa67bf`; all 17 pins verified in the working tree). The unpinned
  run-conditions note (private; `da014e6`) adds the manual
  MemTotal check, the R0 inspection, Q-P, follow-ups at +5/+10 and the Unit 1 opening rules.
- **Clean-room ABL study** (a private facts file; static study, facts only): [removed for publication].
- **Installed-boot design** (`99926a4` rev 2 → `7a286d6` rev 3 → `0441b27` rev 4 → `64d260a`
  rev 5; reviews GO-with-fixes, all applied):
  - T1: [removed for publication].
  - Checks: G16 re-reads both slots after `fastboot reboot-bootloader`. G18 is a separate RAM-booted
    read-back of the full `boot` before the first normal boot.
  - Every lost-mark case ends in fs-bootctl (IB-C4, a required recovery input) or H1 (a raw flash
    of Meta's boot, then Meta recovery).
  - **IB-C10:** [removed for publication].
  - T1-L/L4 loaders are optional (PC-free kernel updates); T2 is last.
- **Running:** the K1g concrete package; thermal part 2 and the TS T0 package.

**J-189 · Thermal service part 2 and the TS T0 package built offline (branch `feat/thermal-part2`).**
- Nothing ran on a headset; no adb/fastboot; nothing downloaded; the archive drive and `/persist` untouched.
- **Part 2** (`devices/thermal/EXEC-SPEC.md`): the device executor (softdog only with
  `--softdog` and `download_mode` reading exactly `0`; margin 30 s; final pet `M_final`; never a
  pet after it or before a complete cycle), pre-forked A1/A2 (exact command bytes, fd hygiene,
  no `RLIMIT_RTTIME` inherited), `kill(1, 38)` literal, FST1 pstore records and the next-boot
  marker, FSN1 notice and fixed-width heartbeat records; `fs-poweroff-final` (3 syscalls,
  proven from the disassembly); the PID 1 TRIP branch (`stage/pid1-hold-ts.sh`, no forking
  fallback); the Valve layer units (static checks only; the systemd QEMU suite is still open);
  the consumers (LED `fs-noticed`; static KMS frame `fs-warnscreen` = fs-pattern v0.7.1 +
  `warn.patch`); product, trial and log-only builds with build-time exclusions; the FS-R-013 §7
  disclosures (where resets land, crash-record/minidump effects, softdog ≠ hardware guarantee).
- **CORE-SPEC rev 7 §20:** class PMIC (P7: 95/115 °C), the 7 IIO die channels by DT label, all
  required before READY (J-171 R50); the Python reference was changed by an independent agent
  from the spec text only.
- **Found and fixed (would have failed on the device):** the v2.7 ADSP remoteproc is named
  `3000000.remoteproc-adsp`; part 1 matched `adsp` only and would have raised `b:adsp` (T4 after
  120 s). A dead actuator's pipe would have killed the supervisor with SIGPIPE (all signals are
  now blocked from start-up). An LED blink polled at its own period would have aliased to a
  steady light.
- **Do not:** never rely on `download_mode` text other than `0` (the getter prints an int over a
  bool, `qcom-dload-mode.c:38,109`); never read a whole PMIC regmap through debugfs in a trial
  without a source check of clear-on-read registers (D-T0-1).
- **TS T0 package** (`devices/quest3/ts/`): trial table (Unit 2 first; compositions S/K/M),
  module closure with hashes, abort thresholds, sensors and virtual-sensor equations, firmware
  manifest (ADSP 45 files; GPU staging; source-derived trigger/load/error behaviour), 19 pinned
  Android rows, the checker (MemTotal → T0 BLOCKED) and the capture tool. Open for T3b: the
  charger protection-domain service (PD mapper, D-T0-4).
- **Internal adversarial review:** part 2 GO-with-fixes (6 MAJOR: TRIP behind a sysfs write, a torn
  heartbeat read, a `/run` write on the TRIP path, log-only READY, the gate racing async probes, the
  watcher never started); T0 NO-GO as first submitted (BLOCKER: the load abort could leave the busy
  loops running under toybox `timeout`). All fixed with tests (EXEC-SPEC §12, ts/README §9); a delta
  check followed.
- **Do not:** never wrap a trial load in `timeout` and kill the wrapper (toybox does not forward
  SIGTERM); never reboot PID 1 on a heartbeat state seen once (read twice).
- Numbering: master already holds J-188 (K1a merge); this entry is J-189 on `feat/thermal-part2`.

**J-190 · K1g concrete package complete; thermal part 2 + TS T0 merged; FS-A-014 contents ready apart from the K1a results.**
- **K1g** (`feat/k1g` `eec892c`, not merged):
  - The kernel is the exact K1a config plus fs-blkguard `a9c63e24cb76`. The kgate PASS is on this
    exact build. The rebuild is bit-identical (Image `65740722…`).
  - Candidate `20261016T105549Z-3e2e864a0e876dea`, image `f451853c…`, probe `00701e60…`.
    SIGNOFF-k1g `2b3bac2d…` (21 host pins, including RECOVERY-K1g.md; the K1a-pinned RECOVERY.md
    is untouched).
  - Tests:
    - host 71/71, smoke 11/11, builder negatives 56/56;
    - QEMU 213/223/181/157/157, plus UFS-strict 224/224 (Q10 now runs on an emulated UFS host),
      UFS-device 177/177 and devicesim 205/205;
    - UML 192/212/170/82/82;
    - mutation testing: all 8 disabled hooks caught.
  - Q12 runs only in UML and on the device: it needs Meta's ufs-qcom driver.
  - Probe: ARMv8 SHA-256. A measured gate stops the run before arming, within a total budget of
    25 s (the 200 s deadline is unchanged). A time stop before arming is INCONCLUSIVE; after
    arming it is REVIEW, never FAIL. A nonce-only repeat would need the Chair's authorisation.
  - Reviews: NO-GO (14 findings) → fixed; delta GO-with-fixes → fixed; narrow GO.
  - Order unchanged: K1g runs only after both K1a attempts.
- **Thermal part 2 and the TS T0 package merged** (`e82d462`; branch `fc661c9`). After the merge
  the K1a pins were re-verified: 17/17.
  - Reviews: T0 was NO-GO first, then fixed. Delta and narrow re-checks: GO.
  - The Arbiter's safety decisions:
    - any battery reading ≥ 40.0 °C, including `batt-virt-usr`, or a cool-down SoC reading
      ≥ 75 °C, STOPs the session at every step;
    - the checker reports a hot reading even on an invalid capture;
    - a live kill waits up to 5 s for the row's own end report.
  - Final suites: host 42/42, checker 59/59, rows 11/11, ts-info 15/15, core 121 (+121 on
    aarch64, C = Python), sweep 440.
  - **PM decisions pending:** D-T0-1 (drop the PMIC register reads), D-T0-2 (T0 runs under Android
    only), D-T0-3 ([removed for publication]),
    D-T0-4 (research an open-source PD mapper for T3b).

**J-191 · 2026-10-16 offline day: K1g final, T0 pinned, N1 and the H-1 loader built, the 0.4.5 writer review, PD mapper; PM decisions and principles.**
- **K1g** (`feat/k1g` `8971262`; SIGNOFF-k1g `62aaee9c…`; candidate `c3c92a09…`):
  - The probe refuses every VM-only mode unless the platform is positively a test VM and not a
    Quest. The kernel patch has no such flag.
  - Tests: QEMU, UML, mutation 15/15, host 71/71, the 74,272-check harness. Narrow check GO.
  - RECOVERY-K1g.md is separate; K1a's pinned RECOVERY.md is untouched.
- **TS T0** (master): SIGNOFF-t0 `7efc1932…` (19 pins plus the config dump), with `-Verify` before
  each session. D-T0-1..4 are recorded, and the T0-16 reading must be below 35 °C.
  Checker 62/62, host 47/47.
- **N1** (`feat/n1` `2cad16c`; SIGNOFF-n1 `b3152dc4…`; candidate `5550b45a…`):
  - ACM then NCM, with ACM always kept. The only listener is fs-xfer (8 MiB each way, hashed).
  - Device and host reviews both GO-with-fixes, applied.
  - **PM:** N1 runs on Unit 2 only. If Windows doesn't bind UsbNcm, install nothing and review
    first.
- **H-1/H-2 loader** (`feat/h1-loader` `e8efc14`):
  - S/E/F phases. S has a 90 s ceiling; past it the handoff is refused and nothing is skipped.
  - READY-BLOCKED is recorded as a finding. The ADSP is started explicitly for T3b and R-1.
  - Tests 77/77.
  - nautilus is dropped from later lists; K1a and stage 3d are unchanged. device-health §2.1 is
    corrected (`1703ed2`).
  - TS-list fixes: smp2p and bq27 in T3b, gpucc-anorak in T2.
  - The QEMU-kernel test stays open for K1i.
- **PD mapper** (`pd-mapper.md` rev 1, `2bf3a8e`; review GO-with-fixes, applied):
  - Use linux-msm pd-mapper with our own .jsn files, and only once K5 is in place
    (download_mode=0), because a PDR panic would otherwise land in dump mode.
  - A charger_pd DOWN is an immediate SEVERE.
  - No DSP file or RPC daemons.
  - AI-directed text found on pmaports #2936 and reported to the PM; nothing was acted on.
- **0.4.5 rootfs:** the PM copied it read-only (`~/sf045-full`, with metadata in `~/sf045-meta.txt`).
  - The writer review a private research note (rev 1 `3e94874`, plus owner control in
    `536caea`; review GO-with-fixes, applied) found:
    - items that FrameShift's layer must control (kept private);
    - a udev crash-submitter path;
    - offload mounts pulled in by basic.target;
    - the empty static usermodehelper, which already disables pipe core dumps.
  - The activation graph is unchanged from 0.3.0, and kernelsetup and bootfw are byte-identical.
  - Arbiter decisions for R-1: keep BT (masks plus a no-hci0 check), nosuid root and lower mounts,
    no crash dumps, keep the RT limit. Private facts in `<private note, withheld>`.
- **PM principles recorded:**
  - **Owner control:** owners keep full admin control of their headset and OS. R-1 restrictions are experiment-scoped.
  - **Simplicity:** keep the current route (unmodified SteamOS plus our Quest layer); a custom,
    ArmadaOS-style distro stays a fallback only.
- **Housekeeping:** a cached PDF that a research WebFetch had saved without approval was deleted
  (PM's OK).

**J-192 · Unit 1 worn Horizon session done (Perfetto instance not honoured; FsSample data); K1a Unit 2 Part 1 started then paused; PM rule change: no "meat proxy".**
- **Unit 1 worn session** (2026-10-17 ~01:37–03:40Z; controllers paired):
  - **Gate:** 310 with status 2 (charging) failed the <30.0 °C charging rule. **PM executive
    override** (an observation of stock Horizon, not a FrameShift trial; in-session ≥40 °C limits
    unchanged).
  - **Preflight:** P1 SHELL-OK. P2 PASS: Enforcing; Perfetto v50.1 on all three parts; 0 sessions;
    mm_events absent; top level tracing_on=0, nop, bpf_trace_printk; the policy has the mm_events
    rules.
  - **P3:** `mm_events` created (ino 103163, correct label, empty set_event).
  - **S0 (config A):** Perfetto **refused config A**: android.power battery_counters enum values are
    invalid in v50.1. The trace never started, and tracefs was unchanged.
  - **S0-r1 (config B):** Perfetto **ignored instance_name**. It traced the top level and **resized
    the top-level buffer_size_kb 1410→7** (total 8460→42); no events in mm_events; a 1.8 KB trace
    was pulled, verified and deleted. STOP and latch; per FS-R-013 §12 nothing was restored.
  - **P4:** our instance removed (inode and boot_id matched, empty).
  - **The top-level change persisted until a normal `adb reboot`** at the end. **To disclose in FS-A-014.**
  - **Scenarios via FsSample** (read-only): S1 idle (350), S2 head (370), S3 controllers (390;
    paused to cool, about an hour), S4 put-down (250; hands appeared ~1–2 s after the controllers
    were set down), S5 pick-up (290; the controllers took over almost instantly). Closing reading
    300; no fs-obs files left. The display never went dark (Unit 1's prox fault did not show).
  - **Lesson:** Horizon's v50.1 traced_probes does not honour `instance_name` in practice. Any
    future Perfetto use must assume top-level buffer changes (plan §1 disclosure), or use another
    method.
- **K1a Unit 2, Part 1 started** (00:10 local / 07:10Z on 10-17): the capture folder
  created; `adb devices` shows only `QUEST3UNIT2`. **Paused by the PM.** Nothing
  changed on the unit; its nonce is unspent. Resume at step 3 the same PC-local day.
- **PM rule change (2026-10-17), for runs after the current K1a attempt:**
  - read-only probes: the Arbiter runs them unattended;
  - [removed for publication];
  - test boots: the Arbiter runs every command, including the nonce and `fastboot boot`, after the
    PM's explicit chat "go" per attempt; the PM stays within physical reach but types nothing;
  - flashing and installing: unchanged.
  - These steps need the Chair to amend FS-R-013's in-person conditions. **Ask in FS-A-014.**

**J-193 · MILESTONE K1a PASSED on both Quest 3 units: FrameShift's own kernel boots with Meta's stock modules (FS-R-013).**
- **Unit 2** (`QUEST3UNIT2`, image `d40b922d…`):
  - Readback R0–R5 PASS.
  - Phase A first STOPPED (the Arbiter had skipped the host-hash command), then PASSED.
  - Admission 230, status 2, 91 %. BA, BF and E OK. Dwell 109.9 s. `fastboot boot`
    HANDOFF_ACKNOWLEDGED; gadget at Th+10 s; COLLECTED-VALID, FSB1 VALID.
  - AF OK (returned by itself).
  - AA OK (AA10 270).
  - The Arbiter's first scheduled follow-up capture failed (a shell error). The readings were
    then taken at +629 s and +878 s, both 300: the minimum-time rules were met, but later than
    the ~+5/+10 targets. **Disclose in FS-A-014.**
  - Phase F clean. **K1A PASS:** MemTotal 7839084 kB (manual check PASS); 95/95 modules; 0
    refusals; 0 WARNING / 0 BUG.
- **Unit 1** (`QUEST3UNIT1`, image `08451457…`):
  - The unit order was verified by the gate (Unit 2's clean PASS), and A5 was answered.
  - Readback R0–R5 PASS. Admission 260, status 5, 100 %. Dwell 85.9 s.
    COLLECTED-VALID.
  - AF OK, AA OK (300). Follow-ups 310 at +314 s and +610 s. Phase F clean.
  - **K1A PASS:** MemTotal 7836024 kB; 95/95 modules; 0 refusals; 0 WARNING / 0 BUG.
- **Both:** config sha `4aa0c894…` (the gated k1a.config); devtmpfs present; ACM only; taint
  1024 (the OOT flag from the vendor modules, as on stock); highest temperatures 300 and 310.
- **The spent-nonce ledger** is kept in the private evidence.
- **The order now opens K1g** (FS-R-013 §5: K1a → K1g → K1i). K1g, N1 and T0 go to the Chair in
  FS-A-014, together with these results and the PM's no-proxy rule change.

**J-194 · Record: the PM's standing authorization of read-only probes (2026-10-07); FS-A-014 finalising.**
- **Standing authorization (PM, 2026-10-07, expanded the same day):** the PM authorized
  read-only probes and non-destructive tests on the headsets, such as getprop, ls, cat of /proc
  and /sys, adb and fastboot reads, and reboots to Android or the bootloader. Anything that writes
  or changes state persistently needs the PM's explicit confirmation, and `fastboot boot` needs
  the PM's live sign-off with the PM present. This had been recorded only in the Arbiter's working
  rules. It is entered here so the Chair can check it.
  - On 2026-10-17 the Arbiter relied on it to run the K1a read-only rows, the admission reading,
    the follow-up readings and the classifier. The PM typed the
    checklists and the attempts.
- **FS-A-014:** the final review (GO-with-fixes) and the delta check (GO-with-fixes) are applied.
  The (f2) session temperature rule now requires a fresh reading below 35.0 °C, and the
  ≥ 40 °C alert-and-stop rule applies too. Finalising and bundling next.

**J-195 · Public export pushed: continuumxr/frameshift `f8dbd4d..d6cbf02` (fast-forward, PM-approved).**
- **PM approval:** the PM approved the push in advance, "when it's ready" (2026-10-17).
- **Export:** 2,736 files, 17.9 MiB; 282 added, 38 changed, 0 removed. Built from the private
  snapshot branch `export/public-20261017` (`56f52d1`). The K1g, N1 and H1 merges are not included
  and come in the next export.
- **Audit:** 0 refused, 0 scope hits, 0 guard hits. Provenance is complete. No serials, names or
  attempt nonces in documents; nothing outside the public scope.
- **Kept private:** the K1a readback and sign-off kit, T0, the installed-boot design, and two
  Valve-image notes.
- **Public README:** now a public-only README. The private README's glossary and Unit 1 lines
  were fixed.
- **Review:** the export review record (private). The adversarial review was
  GO-with-fixes; all fixes were applied and the tree re-audited, giving GO. This meets FS-R-012
  §7(9)/J-148.
- **Arbiter's own pre-push check:** remote head still at f8dbd4d; 0 serial matches; the scope
  wording is the approved form only.
- **Open:** 568 already-public fixture files still contain spent nonces (accepted, low risk).
  The two Valve-image notes stay private for now.

**J-196 · FS-A-014 sent; FS-R-014 received (FS-R-014, private review record): K1a ACCEPTED; K1g HALTED for probe fixes; T0 CONCURRED; N1 withheld; operator delegation CONCURRED.**
- **K1a:** the bounded boot/module milestone is accepted on both units.
  - The taint correction is accepted; stock taint stays unmeasured.
  - Qualifications: Unit 2's ~+5 min reading is missing (readings at +629/+878 s); Unit 1's AF
    began 218 s after fs-done and its return time was not recorded. Future AF and follow-ups must
    meet the schedule.
  - No repeat K1a is required.
  - Wording: the record says the helper read a ring buffer whose first reported line was from boot,
    not the whole log since boot.
- **K1g HALTED.** The guard direction is credible and no-Q11 stays mandatory. The probe needs:
  - §3.1: a content-read allowlist before any raw open (R1–R5 plus scoped misc/devinfo only); no
    persist access of any kind; no whole-LUN sampling;
  - §3.2: stop on the first read error, short read or mismatch;
  - §3.3: removal of the real-storage O_DIRECT→plain reopen fallback.
  - The kernel need not be rebuilt if its bytes are unchanged. Correction work started on
    `feat/k1g-r2`.
- **T0 CONCURRED:** one attended session on Unit 2, then one on Unit 1 after a clean Unit 2.
  - Uses the pinned package (SIGNOFF-t0 `7efc1932…`, rows `2355d593…`) plus the §4.1 manual
    acceptance gate, which covers two checker gaps.
  - T0-16 is optional.
  - The session stays attended because of the ADC conversions.
  - T0 can proceed independently of K1g/N1. A runbook is being prepared.
- **N1 withheld.** It needs a post-transfer kernel-log check plus classifier and fixture; the
  23 s responder budget must be qualified. It also still needs Unit 2's K1g first. Work started
  on `feat/n1-r2`.
- **Operator delegation (f1–f3) CONCURRED**, prospectively, for the packages named:
  - f1: unattended passive probes (not ADC or read-clear); stop and alert at ≥ 40 °C.
  - f2: [removed for publication];
  - f3: the Arbiter types the nonce, boot and workload commands after the PM's go; the PM stays
    within reach and presses the checklist keys.
  - A4 substitution text.
  - The RUN-UNDER-F addenda are accepted with the overrides (clerical updates).
- **Noted, with corrections:**
  - installed-boot rev 5: research only; boot_a/b are persistent boot storage;
  - H-1/H-2: needs its own package;
  - nautilus: the source shows no explicit enable; projector darkness was not measured;
  - 0.4.5 writer review: qualifications;
  - PD mapper: K5 and PDR_NOTIF_TIMEOUT=n are not equivalent; shutdown_in_progress only
    suppresses;
  - Perfetto: parse the trace offline; the 5 h persistence claim is conditional; no post-reboot
    proof; no further tracing.
- **Next relay (FS-A-015):** T0 evidence, the K1g probe delta, the N1 delta.

**J-197 · 2026-10-18 UTC. /persist read clarified; deep clean-room inspection of every source adopted; T0 on Unit 2 ran clean but came out REVIEW (T0-18 row timeout, fan-table hysteresis); K1g r2, N1 r2 and the VA48 study delivered; reframed-vr found.**
- **/persist (PM, 2026-10-17):** /persist may be read but never written, changed or remounted.
  - Chair-reviewed packages keep the read scope that was reviewed: K1g keeps the FS-R-014 §3 allowlist.
  - The lift goes to the Chair in FS-A-015.
- **Deep inspection of every source (PM, in chat, local date 2026-10-17; UTC time not recorded):** code, APKs and images from any source (stearlight now, and every source from here on) are inspected in depth under the clean-room policy (facts only, never copied) so that we are as informed as possible. Downloads still need the PM's approval per file (name, source, size).
- **T0 Unit 2** (run under FS-R-014 §4/§6):
  - Pins were verified before and after the session (PINS OK, SIGNOFF-t0 `7efc1932…`).
  - The PM answered T0-P1…P5 y in chat; identity checked.
  - Session go given; the session ran in a console window on the PM's screen.
  - **T0-17 load:** clean (abort=none). SoC peak 65.0 °C, battery 30.0 °C throughout, fan up to ~3800 rpm.
  - **T0-18 cool-down:** all 11 samples taken (SoC 42.3 → 38.2 °C, battery 30–31 °C), but the row was killed at its 330 s timeout in the final `sleep 30`, before `T0END`. This is a row-timing defect (≈ 340 s needed), not a device event. The tool still ended `PHASE T0 OK`.
  - **Follow-ups:** 31.0 °C at +365 s and 31.0 °C at +620 s (not rising). No recovery concern.
  - **T0-16** (optional): no names found.
  - **Checker:** `T0 REVIEW` (exit 41). Findings: T0-18 incomplete; **fan-zone trips differ from the table**. In 11 of 28 zones (gpuss-0…7-fan, nspss-0…2-fan), the hysteresis at trip points 0/1 is 3000 on the device but 15000/10000 in the fs-thermald table; all trip temperatures match. Under K-25 that would raise F8 (fail-safe direction: no READY, fan at top), so the table must be corrected.
  - **Manual gate §4.1:** REVIEW (G5 and G8: the T0-18 TIMEOUT; every other item passes).
  - **Unit 1 stays blocked** pending the Chair's review (§4.2).
- **K1g r2** (`feat/k1g-r2` `43df945`): FS-R-014 §3 probe fixes. The new image `d24d1559…` has the same kernel bytes as `c3c92a09`, and the probe never opens persist. SIGNOFF-k1g `ceee35b4…`. Agent review GO-with-fixes, applied. Still halted on the device until the Chair rules.
- **N1 r2** (`feat/n1-r2` `98f9434`): post-transfer kmsg read and classifier. Candidate `82eefa8a…`, SIGNOFF-n1 `d3402b14…`. Reviews GO-with-fixes, applied. A QEMU run killed by the K1g agent was voided and re-run.
- **VA48 study** (`docs/research/va-bits-k1i.md`, a88ac62): recommends VA_BITS_48 in K1i together with SysV IPC, plus a VA39 control image. **wlan.ko differs from Meta's stock module** (16 extra imports), so fixing it is a K1i precondition. PM decisions pending.
- **reframed-vr** (Producdevity), found by the PM: assessment by a read-only agent in progress.
- **Next:** a T0 r2 package (T0-18 timeout, fan-table hysteresis), then FS-A-015 (T0 evidence and manual audit, K1g and N1 deltas, the /persist-read lift, VA48).

**J-198 · 2026-10-18 UTC. PM decisions: VA48 adopted for K1i; stearlight downloads approved; deep inspection policy recorded; reframed-vr assessed.**
- **K1i addressing (PM, in chat):** all three recommendations adopted:
  - K1i switches to VA_BITS_48, together with SysV IPC;
  - a VA39 control image (SysV IPC only) is built, and booted only if VA48 fails;
  - fixing wlan.ko (it does not match Meta's stock build) is a K1i precondition.
  - Basis: `docs/research/va-bits-k1i.md` (a88ac62). Module signing stays open (owner control).
- **Downloads (PM, in chat):** approved the downloads, answering a question that listed each file by name, source and size.
  - Downloaded from github.com/amichyrpi/stearlight, release `temp-build` (2026-10-17T23:14:37Z), into `$HOME\Downloads\fs-thirdparty\stearlight\temp-build-20261017\`, outside the repo:
    - `stearlight-quest-sources.zip`: 309,650,108 B, sha256 `99bfb8d0…`;
    - `stearlight-quest.apk`: 2,104,498,870 B, sha256 `b9a92ec2…`;
    - plus `SHA256SUMS` and `.apk.sha256`.
  - Both hashes match the publisher's sums.
  - Not downloaded: `stearlight-frame-windows.zip` (1.59 GB, PC-side, low value).
  - Two clean-room agents are inspecting them (source zip; built APK), static only, never executed. Facts go to `<private note, withheld>` and `<private note, withheld>` (private).
- **Policy:** `docs/PROVENANCE-POLICY.md` §3 item 9 records the deep-inspection rule (J-197).
- **reframed-vr** (`docs/research/reframed-vr.md`, b865be3): this is ArmadaVR renamed (same repo id), so the doc is a delta on `armadavr.md`.
  - Status: Fedora 44 on Meta's 5.10 kernel at its default VA39; tested only in QEMU, never booted on a headset; no licence (facts only).
  - Leads:
    - the slot-B "successful plus unbootable" pattern seen on a second unit;
    - `dumpsys sensorservice` exposing the calibration blobs;
    - a thermal config matching ours.
- **T0 r2:** an agent is building the fixes on `feat/t0-r2` (T0-18 timeout, fan-table hysteresis).

**J-199 · 2026-10-18 UTC. Stearlight deep inspection done (clean room, static only, nothing executed).**
- **Source zip** (`<private note, withheld>`, PRIVATE, 592831c):
  - Valve's 0.4.5 `vrcompositor` paces frames from Vulkan display events (`VK_EXT_display_control`, `VK_EXT_display_surface_counter`, present-wait); the names are confirmed in our binary. Our DRM/KMS Turnip route must implement them for real; stearlight fakes them.
  - SteamVR expects `useFacetRenderer` and `renderSystemLayerInDistortPass`.
  - Valve's streaming player needs a V4L2 stateful decoder (NV12).
  - Stearlight has no VA39 workaround.
  - They binary-patch Valve files; we never do (unmodified SteamOS). Symptoms only were recorded.
  - Licence FSL-1.1-ALv2, plus GPL PRoot files: facts only.
- **APK** (`<private note, withheld>`, PRIVATE, 25bf942):
  - Ships Valve Frame **0.3.0** (byte-identical to our copy): SteamVR 2.17.10, the Steam client and gamescope.
  - An Alpine rootfs plus an overlay under PRoot, with the Khronos OpenXR loader.
  - No kernel, no modules, no Meta binaries.
  - Valve binaries are bundled (their licensing problem, not ours).
- **Leads for us:**
  - Valve's `vrenv.sh` points at the x86 `linux64` binaries (a trap for session bring-up).
  - In 0.3.0, `frame_hmd` and `frame_controller` carry resources only, no driver binary.
  - SteamVR binaries are 4K-aligned, so 4K pages are mandatory. This qualifies FS-A-006 (see Corrections).
  - L7 is corrected: the Steam client and gamescope are in the 0.3.0 OS rootfs too.
- No AI-directed text in either archive. Extracts: the APK payload was deleted; the `src-extract` folder is kept outside the repo.
- **To the GPU plan:** the Vulkan display-event extensions and the V4L2 decoder are new requirements for the R-1/R-2 graphics route.

**J-200 · 2026-10-18 UTC. K1g r2, N1 r2 and T0 r2 merged into master; pins verified.**
- **Merges** (`--no-ff`, no file overlap between the three branches): `feat/k1g-r2` 43df945 → 1c69e56; `feat/n1-r2` 98f9434 → 8588d74; `feat/t0-r2` bc2888c → a1a1e8d.
- **T0 r2** (agent report; the T0 change and review records, private):
  - T0-18 has no sleep after its last sample, and its timeout is 360 s (≈ 311 s needed).
  - Any row TIMEOUT now prints a WARNING, and the checker reports `host TIMEOUT` (never PASS). A virtual-clock test times every row against its timeout.
  - The fan-table hysteresis for gpuss-0…7 and nspss-0…2 is corrected to 3000. The error came from the thermal design research doc rev 2 §1.3, which generalised cpu-0-0-0-fan's 15/10; that doc is corrected too.
  - The FS-R-014 §4.1 manual-gate checks are built into the checker (16 fixtures).
  - A superseded-rows fixture re-checks the real Unit 2 r1 capture: still REVIEW, and the fan finding is gone.
  - A TIMEOUT of T0-15 or T0-16 now marks the load NOT-RUN (reviewer R1).
  - Tests: checker 88/88, rows 32/32, host dry run 51/51, all thermal suites.
  - Arbiter decisions: keep the §4.1 checks in r2, keep the superseded-rows mechanism (disclose it), confirm the T0-15/16 NOT-RUN rule. FS-A-015 asks the Chair to restate the §4.2 durations (load ≈ 70 s, cool-down ≈ 310 s).
- **Pins after the merge:**
  - SIGNOFF-t0 `3b9fde2b…` PINS OK. `~/fsth-build` was rebuilt from master; the old build was kept as `~/fsth-build-t0r1`.
  - SIGNOFF-k1g `ceee35b4…` and SIGNOFF-k1a `5e0bdf9e…` regenerate byte-identical. (Their make-signoff scripts have no `-Verify`; running them rewrites the file, and git shows no change.)
  - **SIGNOFF-n1 changes to `a1adc9e5…`.** The only line that differs is the pinned `fs-classify-k1g.ps1` hash (`d0d0296a…` → `b79bf247…`), because K1g r2 changed that classifier, as the N1 agent warned.
  - N1 host tests on the merged tree: 104/104. The first run failed N3 only because `devices/quest3/n1/build/fs-xfer` (an ignored build output) was missing in the main checkout. It was rebuilt with `n1/tools/build-xfer.sh` to the same binary hash; the date-only change to `BUILD-xfer.txt` was reverted; the re-run passed (the N1 host suite (private)). 104 vs the branch run's 103: case O5 (a K1a image refused by the N1 observer) runs only when `build\k1a` holds a K1a image, which the main checkout has and the agent's clone did not.
- **Unit 1 T0 stays blocked** pending the Chair. K1g stays halted on the device; N1 stays withheld.

**J-201 · 2026-10-18T04:14:28Z. FS-A-015 reviews; PM decision on /persist; go-reply lesson.**
- **Four adversarial reviews of the FS-A-015 draft:** the drafting agent's (a) and (b), plus the Arbiter's independent (a) and (b). Verdicts: GO-with-fixes, GO-with-fixes, GO-with-fixes, and NO-GO for one BLOCKER (the draft was stale against master after daf7fe23/9d0622db). Every evidence hash, time, reading and test count checks out; the bundles rebuilt byte-identical at the draft's SRC. The fixes are text, the journal and a bundle rebuild. No package change.
- **/persist (PM, in chat, at about 2026-10-18T04:14:28Z):** owner decision; hold until the Chair notes it (recommended). FS-A-015 presents the read lift as the owner's decision (the J-132 rule was the PM's own) and asks the Chair to note it. **No FrameShift agent reads /persist on a headset until the Chair has replied.**
- **The PM was told** (in chat, this block) about stearlight's AGENTS.md/CLAUDE.md: benign contributor guidance for the author's own agents, ignored.
- **Lesson (procedural departure, disclosed in FS-A-015):** two of the T0 Unit 2 replies did not meet RUN-UNDER-F-T0's literal answer rules ("a reply consisting of the word go"; "a reply other than y/yes or n/no is asked again"), but were accepted. From now on, such replies are answered and the prompt is re-posted unchanged.
- The T0-18 TIMEOUT line was unexpected output under the runbook's global rule, and was first shown to the PM in the step-13 report rather than at once. The follow-ups correctly continued. Disclosed as a departure.

**J-202 · 2026-10-18T05:10:14Z. FS-A-015 FINAL; ready for the PM to send.**
- All 33 consolidated fixes were applied (a8061312). A final verification gave GO-with-fixes; its 2 MAJOR, 3 MINOR and 6 NIT findings were applied and recorded in FS-A-015 (private review record). The Arbiter's own check: the hashes of the relay and of all 7 zips match the relay index row (f5994ca4), the asks in §9 are as intended, and the working tree is clean.
- The T0 r2 runbook and RUN-UNDER-F-T0 got a clerical update before the relay (6ef4fff4, 2b62d0ff):
  - r2 pins;
  - evidence path `unit2-t0r2-<D>`;
  - the working checker line;
  - the literal go and y/n rules;
  Neither file is a SIGNOFF-t0 pin.
- The checker's time was refined from the session record: the failed PowerShell attempt at 01:53:31Z, the working run at 01:53:54Z (the attempt log said "~01:55Z").
- `FS-A-015.md` sha256 `4e93da0deb1665b45e0a403366ccebe87b110143a40273fdf667b31452707a1b`, plus 7 zips in `relays/` (sizes and hashes in its §10).

**J-203 · 2026-10-18T18:52:50Z. FS-A-015 sent by the PM; FS-R-015 received (FS-R-015, private review record).**
- **T0 Unit 2:** REVIEW accepted and kept unchanged (exit 41; manual gate REVIEW). "Clean device side" means only that the retained observations show no thermal or recovery concern. Unit 1's fan-table agreement is still to be measured.
- **T0 r2 CONCURRED:** one attended session on Unit 2, then one on Unit 1 after a clean Unit 2 gate (checker PASS, manual gate passed, complete follow-ups, no recovery concern, report to the PM).
  - Identities: SIGNOFF-t0 `3b9fde2b…`, rows `6f70f6f6…`, dump-config `27b0e77b…`.
- **K1g r2 CONCURRED:** Unit 2, then Unit 1 through its gate, on `d24d1559…` / SIGNOFF `ceee35b4…`.
  - The LUN-level Q targets are accepted, with no r3. "Write-incapable" must be corrected wherever it describes Q5/Q13 unqualified.
  - The K8a explanatory text naming misc/devinfo is to be added clerically and shown before the checklist.
- **N1 r2 CONCURRED:** one Unit 2 attempt after Unit 2's clean K1g PASS, on `82eefa8a…` / SIGNOFF `a1adc9e5…`. Report "no wrap detected by the implemented check", not continuity.
- **Delegation:** §6 f1–f3 plus A4 extended to the r2 packages. **Explicit, unambiguous assent to the displayed unit/action is enough** (no single-word go); keep it verbatim; questions or conditions must be resolved first. Checklist keypresses are unchanged. This supersedes the addenda's stricter syntax, and incorporating it is clerical.
- **/persist:** the lift is NOTED, and the owner-policy hold is satisfied. Writes, changes and remounts stay forbidden; package scopes are unchanged; future reads need the per-action PM gate and a declared scope.
- **Research:** K1i VA48 plus SysV IPC preparation is accepted (no K1i boot). Overclaims to correct are listed in §7 (va-bits doc, F2a as a lead, 4K "must" vs p_align, community findings bounded). The FS-R-014 §7–§10 corrections and the Perfetto parse are due before those topics' next packages.
- **Order:** T0 r2 Unit 2 → T0 Unit 1; K1g Unit 2 → N1 Unit 2 → K1g Unit 1.
- **Next:** clerical incorporation into the T0/K1g/N1 addenda and runbooks; research corrections; then the T0 r2 Unit 2 session when the PM is at the device.

**J-204 · 2026-10-18T19:20:37Z. FS-R-015 clerical incorporation done; research corrections applied.**
- **Addenda and runbooks** (FS-R-015 §6 clerical): T0 ea573f1b, K1g 8e72542b, N1 58a8a88b.
  - Changes: the assent rule (explicit unambiguous assent, verbatim); f1–f3 and A4 in the K1g/N1 addenda for the first time; the K8a explanatory text shown before the K1g checklist (pinned checklist unchanged); "write-incapable" for Q5/Q13 corrected; N1 "no wrap detected by the implemented check"; limits restated.
  - No pinned file changed; SIGNOFF-t0 still PINS OK. The pinned `fs-classify-n1.ps1` keeps "continuous coverage" and "same first line", to be read with their implementation-defined meaning (N1 addendum §8).
- **Research corrections** (FS-R-014 §7–§10, FS-R-015 §7), c9f4f628, 13 files:
  - installed-boot rev 5.1; h1 README; device-health rev 2.2 (nautilus); 0.4.5 writer review rev 1.1; pd-mapper rev 1.1; va-bits-k1i rev 1; gpu-route-decision rev 1.1 (F2a and the decoder are leads); stearlight/reframed-vr notes rev 1 (bounded negatives); horizon-observation-results rev 1;
  - 9 new Corrections rows.
- **4K pages, now on firmer ground:** vrcompositor (0.3.0 and 0.4.5) and vrserver have an RW PT_LOAD with vaddr − offset = 0x1000. Meta's v2.7 kernel maps at `p_offset − (p_vaddr mod PAGE_SIZE)`, and `vm_mmap` rejects an offset that is not page-aligned. So with 16K or 64K pages it would refuse these binaries [D, not run]. steamclient.so and the other ld.so-loaded libraries were not examined.
- **Still owed:** the Perfetto offline trace parse (before any further Perfetto proposal).

**J-205 · 2026-10-18T22:45:56Z. T0 r2 on Unit 2: PASS (checker exit 40; manual gate passed). Unit 1 T0 is open.**
- Run under FS-R-015 §3/§6. Pins checked before and after: PINS OK, SIGNOFF-t0 `3b9fde2b…`.
- The PM answered T0-P1…P5 y; identity matched.
- **T0-16:** the PM's first answer was ambiguous and was clarified before any action (FS-R-015 §6). Result: no names found.
- **T0-17:** clean (abort=none). SoC peak 50.4 °C, battery 26–27 °C, the fan stayed at 0 rpm (below the 60 °C trip).
- **T0-18:** complete with its end line (SoC 36.2 → 31.4 °C, battery 27.0 °C). PHASE T0 OK, no WARNING or TIMEOUT.
- **Follow-ups:** 27.0 °C at +332 s, 27.0 °C at +584 s.
- **Checker:** T0 PASS (40), including the corrected fan table (all 28 zones match). **Manual gate G1–G8: passed.**
- **Unit 1 T0 opening conditions are all met**, and the report was given to the PM. Unit 1 still needs its own runbook pass (FS-R-015 §3).

**J-206 · 2026-10-18T23:29:28Z. T0 r2 on Unit 1: PASS (checker exit 40; manual gate passed). The T0 milestone is complete on both units.**
- Run under FS-R-015 §3/§6. Pins were OK before and after.
- The unit opened through the Unit 2 gate (J-205). T0-P1…P4 y, T0-P5 n. Identity checked.
- **T0-16:** the PM chose to run it, on the Arbiter's recommendation.
- **T0-17:** clean. SoC peak 52.6 °C, battery 26.0 °C, fan 0 rpm.
- **T0-18:** complete (38.0 → 31.8 °C).
- **Follow-ups:** 27.0 °C at +338 s and 27.0 °C at +591 s.
- **Checker:** T0 PASS (40). **Manual gate G1–G8:** passed.
- **Fan table:** Unit 1's agreement is now measured: 110 of 110 trip entries match the corrected table, the same as Unit 2.
- **Next:** K1g on Unit 2 (FS-R-015 §4), then N1 on Unit 2, then K1g on Unit 1. Then FS-A-016, with the T0 r2 outcomes and raw evidence.

**J-207 · 2026-10-19T01:47:58Z. K1g r2 on Unit 2: K1G REVIEW. The kernel booted cleanly, but the probe failed closed before arming (dtbo O_DIRECT read EINVAL). Unit 1 K1g and N1 are blocked.**
- Run under FS-R-015 §4/§6. Nonce `<attempt nonce withheld>` (spent), image `7f123ce0…`, a nonce-only rebuild of `d24d1559…`.
- **0b:** reading 23.0 °C. R0–R5 PASS. A1–A4 y, confirmed in chat. Phase B 26.0 °C. BA 27.0 °C.
- **Attempt:** `fastboot boot` HANDOFF_ACKNOWLEDGED at 01:04:49Z; gadget at Th+11 s; COLLECTED-VALID; FSB1 VALID; the unit returned to fastboot by itself. AF/AA identity and slot are unchanged. AA10 31.0 °C; follow-ups 34.0 and 33.0 °C. Phase F: clean True.
- **Kernel facts all hold:** the K1g banner, the K1a config, 95 modules, MemTotal 7839080 kB, 0 warnings. No dump mode (PC PnP check: no 05C6:900E ever registered).
- **Probe:** `ABORT: 1 hashing row(s) failed closed before arming`. Row H dtbo `/dev/sde13 bytes=0/12564 -> Invalid argument`; vbmeta, vbmeta_system, misc and devinfo were not read. The guard was never armed, and no guard case was attempted.
  - Cause [D]: `fsbg-probe.c:517` rounds O_DIRECT reads up to 512 B; on UFS (4096-byte logical blocks), 12564 B becomes 12800 B, which is unaligned, so EINVAL.
  - r1's plain-reopen fallback, removed under FS-R-014 §3.3, had masked this. The test harnesses use 512-byte sectors.
  - **K1g r3:** a probe-only fix (round to the logical block size) and a 4K-sector test, then the Chair.
- **Departures:**
  - Phase F first STOPped: an Arbiter quoting error split -FollowUps, before any question was asked. Re-run once on the PM's decision.
  - About 75 minutes of idle time before phase A (no clock was running).
  - The PM's "Phase E questions answered" was clarified to "E1 y, E2 y" before the attempt.
  - The image build was first refused for CRLF working copies of two committed RESULTS files (restored from WSL).
- **Order now:** K1g Unit 2 REVIEW blocks N1 and K1g Unit 1. The next step is K1g r3, then FS-A-016 (T0 r2 PASS × 2, K1g REVIEW, r3).

**J-208 · 2026-10-19T02:00:36Z. PM decision: keep the milestone order K1g r3 → K1i → R-1 → GPU (G1–G3) → V0.**
- Asked in chat, with the Arbiter recommending an R-1-on-K1g fast path plus a CPU-drawn "flat desktop" interim milestone. PM answer: keep the current order.
- Unit 2 may be unplugged; nothing is pending on the device.
- Offline work continuing: K1g r3 (probe 4K-alignment fix) and K1i preparation (VA48 + SysV IPC + VA39 control, wlan.ko reconciliation; preparation accepted by FS-R-015 §7, no K1i boot concurred).

**J-209 · 2026-10-19T02:49:38Z. PM decision: build R-1 offline now, in parallel; the device order is unchanged.**
- The PM asked whether R-1 needs K1g and K1i to pass before it can be worked on. Arbiter's answer:
  - the offline build needs neither;
  - a device run needs K1g's PASS (the guard must be armed before Valve userspace; PD-10);
  - K1i is not strictly needed for a console boot, but R-1 would re-run on the K1i kernel.
- PM: start the R-1 build offline now.
- The R-1 agent is working on `feat/r1`: the concrete package spec (the R-1 package spec (on an unmerged branch; not in the public copy yet)), the composition and mask overlay, the host loader, and a QEMU harness. No device run is concurred; the Chair reviews the concrete package after K1g passes.

**J-210 · 2026-10-19T03:58:45Z. wlan.ko reconciled (K1i precondition met); the R-1 package spec rev 1 and its first offline build; PM's R-1 decisions; system-actions design started.**
- **wlan.ko** (`docs/research/va-bits-k1i.md` rev 2 §6, 4c7b5c69):
  - Cause: our build had qcacld-3.0 in its debug variant (`TARGET_BUILD_VARIANT` not `user` turns on five debug features, giving the 16 extra imports), plus a git-derived build tag.
  - Fix: `TARGET_BUILD_VARIANT=user WLAN_DISABLE_BUILD_TAG=y` on the make line. No source or config change.
  - Result: modinfo, 469 imports and their CRCs, and .text/.rodata/.data are identical to stock. After stripping, only 29 bytes differ (vermagic and build ID); the build is deterministic.
  - Of the other 271 modules, 270 differ only in vermagic and build ID. socinfo.ko differs because four platform names are redacted in Meta's published source (it gets its own row in the K1i tables).
  - Arbiter call: K1i ships modules stripped, as stock does; debug copies are kept privately.
- **R-1** (`feat/r1` 47c82849, the R-1 package spec (on an unmerged branch; not in the public copy yet) rev 1; 43/43 tests; QEMU not yet run):
  - Boot: the guard kernel by `fastboot boot`.
  - Load: the FSR1 load protocol over N1's link; Valve's signed 0.4.5 `rootfs.img` (sha256 matches Valve's signed manifest) into a sized tmpfs behind a read-only loop; dm-verity with our root `e13fbeed…` plus a full read-through hash.
  - Guard: strict and sealed before the listener.
  - Composition: an overlay root with 107 masks; Valve's files unchanged.
  - Handoff: to Valve's systemd, reaching `fs-console.target` (sshd with keys only on NCM).
  - The review (GO-with-fixes; 1 blocker: the supervisors losing `/dev` etc. after switch_root) has been applied. The W21 zram correction is on the branch.
- **PM decisions (in chat):**
  - R1-5: Yes, battery live (recommended);
  - R1-6: 10 minutes (recommended);
  - R1-13: No splash for R-1 (recommended);
  - R1-9: Python, stdlib only (recommended);
  - R1-1: the K1i kernel, per J-208.
- **Arbiter technical decisions:**
  - R1-4 strict-early; R1-7 (owner control; sshd keys-only); R1-8 detach lowers; R1-10 a key per attempt; R1-12 /tmp at 256 MiB; R1-11 pin our verity root after review.
  - R1-2, R1-3, R1-14 and R1-15 go to the Chair.
- **System-actions design** (power, restart, sleep, update, reset, Return to Horizon, admin): an agent is writing the system-actions design (private for now) with decisions for the PM.

**J-211 · 2026-10-19T04:10:44Z. System-actions design (57b60b64): PM decisions; battery firmware question answered.**
- Design summary:
  - shut down = clean power-off with the ESD timers;
  - restart = plain (tethered sessions land in Horizon);
  - updates through our own `Atomupd1` provider (Valve's updater never runs);
  - Return to Horizon PC-guided;
  - reset wipes FrameShift data only;
  - a kernel-side restart-argument filter is proposed (SA-C1, Chair; details kept private).
- New facts:
  - Valve's `steamos-reboot-other` is broken in 0.4.5.
- **PM decisions (in chat):**
  - SA-P1: real suspend later. This revises TCD P10's "no kernel suspend at all" as a goal: true suspend once proven safe, in its own package; until then Sleep = screen off only.
  - SA-P5/P6/P7: stable, reviewed builds only for now, with a beta option later; stable first.
  - SA-P4: PC-guided only (recommended).
  - The rest (SA-P2, P3, P8–P13): all approved as recommended.
  - Recorded in the design doc (rev 0.1).
- **Battery firmware** (PM question): we do not and cannot write our own. The Quest 3 is secure-boot fused, and the ADSP runs only Qualcomm/Meta-signed firmware. We load Meta's signed ADSP firmware from the user's own headset at runtime (read-only; never shipped). It is not boot-chain firmware; starting it is a reviewed runtime step (T3b).

**J-212 · 2026-10-19T04:13:19Z. K1g r3 built, reviewed and merged (f83e5096); the order gate still blocks a second Unit 2 attempt, so a Chair ruling is needed.**
- **Cause confirmed** from the decoded FSB1 (VALID, 9 steps):
  - R1 and R2 passed, then dtbo hit EINVAL.
  - UFS logical block size: 4096 [M on Unit 1, FS-A-005 boot log; D on Unit 2].
  - R4 (5632) and R5 (3136) would also have failed; misc and devinfo would have passed.
- **Fix:** each read is rounded up to a fixed 4096 bytes and only the row's bytes are hashed. Past-end and short reads fail closed. BLKGETSIZE64 is still the only ioctl; every accepted rule is unchanged.
  - **The read scope widens inside the same partitions:** dtbo +3820 B, vbmeta +2560 B, vbmeta_system +960 B. This needs the Chair's concurrence.
- **Identity:**
  - probe binary `c1de030c…`;
  - candidate `1ee9f105…` (`build\k1g\20261019T031348Z-1c8ade5c6ec2b063`);
  - SIGNOFF-k1g `782e2a77…` (regenerated byte-identical after the merge);
  - kernel identical to r2 (PROBE-ONLY DELTA OK). SIGNOFF-n1 is unchanged.
- **Tests:**
  - scope 89/89 (the r2 source fails 61);
  - new QEMU 4K runs: devicesim-4k 196/196, a mismatch ABORT, r2code reproduces Unit 2's line;
  - UML strict-4k 156, k1g-layout-4k 82;
  - mutation 15/15, builder 56/56, image 11/11, host 71/71.
  - **J-207's "harnesses use 512-byte sectors" is now closed by the 4K harnesses.**
- Reviews: probe/device and host/tests, both ACCEPT WITH FIXES, all applied (REVIEWS-k1g r3; CHANGES-r3.md).
- **Gate:** `fs-k1g-units.ps1` refuses Unit 2 a second K1g attempt, and the r2 REVIEW keeps Unit 1 blocked.
  - The agent's attempt to mark the r2 attempt as superseded was **denied by the permission system as weakening a safety gate**, and the gate was left unchanged. This is correct.
  - A re-attempt needs the Chair's explicit authority, then a reviewed gate revision.
- **Housekeeping:**
  - .gitattributes now has `tools/blkguard/**/RESULTS*.txt text eol=lf`, which fixes the J-207 CRLF build refusal.
  - The main checkout's ignored `build/k1g/probe/fsbg-probe` is now the r3 binary (r2 kept as `fsbg-probe.r2-1d37e5f2`).

**J-213 · 2026-10-19T04:46:15Z. R-1 phase 2 (`feat/r1` 95fe0a60, PACKAGE.md rev 2): in QEMU, Valve's unmodified 0.4.5 systemd reached `fs-console.target` on our 5.10 kernel with the guard armed.**
- **QEMU run 1** (masks applied; real Valve image):
  - the guard was sealed strict with an empty allowlist before the load; the read-only loop and dm-verity worked afterwards (R1-4 needs no fallback);
  - the kernel accepted our verity root `e13fbeed…`; the lazy-corruption test returned EIO;
  - 173 layer entries composed; the target was reached;
  - the acceptance snapshot was clean apart from the harness kernel's binfmt_misc and our own etc/home overlays under masked names (the check was adjusted to accept exactly these);
  - the acceptance checks passed (no core dump; decoy disks unchanged).
  - Disclosed: run 1's serial log was lost because the driver script was edited while it ran; the results had been read live.
- **QEMU run 2** (masks removed, guard on): Valve's writers ran, and the guard refused `fsck.ext4` opening a decoy for writing. Run 2's decoy hashes and run 3 (read-through, the wider-target test, the reboot-argument hook) were still running at report time; nothing is claimed for them yet.
- **Built:**
  - the r1 module profile (104; no UFS, zram or KGSL);
  - `fs-r1-deadline` (11/11);
  - `fs-thermald --reroot` (thermal suites re-run in a separate build directory);
  - SA-A1, SA-A4 and SA-A8 from the system-actions design; SA-C1 left out pending the Chair;
  - drafts of the classifier, init, walkthrough, recovery note and sign-off.
- **Re-review of rev 1:** GO-with-fixes, applied. Undisclosed global drop-ins are now listed (§0); surviving initramfs processes are killed except an allowlist. Rev 2 itself has not been re-reviewed.
- **Still [O]:** guard-off runs, the remaining shutdown paths, the device image builder, the observer, QEMU proof of the re-root, and the PD mapper across the handoff.
- No new PM decision; J-171's charging rule is carried into the package.

**J-214 · 2026-10-19T05:35:32Z. FS-A-016 FINAL (49b55bc2), ready for the PM to send; session paused for the night.**
- FS-A-016 (private review record) sha256 `36918bba…bd60`. Six zips in `relays/` (raw, t0-unit2-evidence, t0-unit1-evidence, k1g-evidence, k1g-package, k1g-image); each unzipped and `sha256sum -c` clean. Hashes are in its §10 and the relay index.
- Reviews: A GO-with-fixes (16 findings); B GO-with-fixes (11 MAJOR of 28); final verification GO-with-fixes (2 MAJOR). All applied (FS-A-016-REVIEW.md); no BLOCKER. The Arbiter re-checked the relay and zip hashes and the clean tree.
- Arbiter decision: (c3-ii). The K1g gate revision goes to the Chair as its own delta before any r3 attempt; the Chair should not be asked to concur with gate code it has not seen.
- Found while drafting: N1's gate reads the same K1g Unit 2 outcome, so the gate revision also re-pins SIGNOFF-n1. Asked as (d).
- **Pending for the PM** (next session): approval in principle to prepare the reviewed K1g gate revision offline (the permission system rightly refused an agent's unasked change).
- Correction: FS-A-015 §3.2(b)'s disclosure that "the harnesses use 512-byte sectors" is superseded by the r3 4K harnesses (J-212).
- Clerical, to do: `docs/research/fs-blkguard-design.md`:302 still says "write-incapable" unqualified for Q5/Q13 (FS-R-015 §4). The comment in the pinned `fsbg-probe.c` is left as is.
- R-1's QEMU runs 2 and 3 may not have finished before the PC shut down; their results are unverified and nothing is claimed for them (J-213).

**J-215 · 2026-10-19T15:33:51Z. FS-A-016 sent by the PM; gate revision preparation approved; an offline day.**
- PM (in chat): FS-A-016 sent; the gate change may be prepared offline; an offline day.
- The K1g gate revision (recording the r2 attempt as superseded by r3; N1's gate reads the same outcome) is now authorised by the PM for **offline preparation and review only**. It goes to the Chair as its own delta (FS-A-016 (c3-ii)) before any r3 attempt. No device action.

**J-216 · 2026-10-19T15:55:51Z. FS-R-016 received (FS-R-016, private review record).**
- (a) **T0 complete**: both r2 PASS records accepted. This does not complete T1–T5, validate FrameShift thermal protection, establish suspend safety or authorise extended operation. Fan rpm stayed 0, so this was not a fan-actuation test. The Unit 1 battery-related maximum of 27.9 °C is kept distinct from the dumpsys maximum of 27.0 °C. The extra Unit 2 `/proc/uptime` read is recorded as a departure outside the fixed f1 list.
- (b) **K1g r2: REVIEW accepted.** Record sha256 `b01996d7…93bd`. The alignment diagnosis is supported. The Chair notes FS-R-015's own review gap.
- (c1–c2) **The r3 aligned reads and exact tails are concurred** (dtbo +3820, vbmeta +2560, vbmeta_system +960; 7,340 B in total), with one replacement Unit 2 attempt conditional on the gate review.
- (c3) **c3-ii:** bring the built gate delta, its tests and review, and both regenerated SIGNOFFs before execution. Only the exact historical record is recognised; both discovery paths are covered; no force switch, blanket exclusion, ledger deletion or "latest wins" rule. Each SIGNOFF should change only in its `fs-k1g-units.ps1` pin. The PM-controlled tool-permission layer is respected.
- (c4) Unit 1 r3 after a clean Unit 2 successor (this replaces the r2 Unit 1 scope). (c5) Delegation, A4 and the assent rule are extended to r3.
- (d) **N1's prerequisite is a bound, clean Unit 2 r3 PASS.**
- (e) SA-C1 comes with K1i as a separately named kernel change. The current download-mode command line must be treated explicitly, never retrofitted.
- **R-1:** a 15–20-minute session counts as extended operation (R11). K1i stays R-1's kernel, and the older K1g wording must be reconciled.
- **Clerical corrections required** (applied in the Corrections table): the R3-open wording, "never armed", the dump timeline, and the alignment review gap.
- **Agents steered:** the gate agent (its brief now superseded by §5's exact requirements), R-1 (K1i wording, R11) and K1i (SA-C1 as a separate patch series).
- Perfetto: the PM chose to download Perfetto's tool (exact file awaiting the PM's per-file approval).

**J-217 · 2026-10-19T16:06:32Z. Perfetto: the retained trace parsed offline. It holds no events.**
- **PM approvals (in chat):** the Perfetto tool download; then the stated file (linux-amd64.zip, v58.2, 14,123,443 B) and any other files Perfetto needs.
- Downloaded to `Downloads\fs-thirdparty\perfetto\v58.2` (sha256 `32c739f7…`). Only `trace_processor_shell` was extracted and run, in WSL, on a copy of the trace.
- **Result** (a private research note, new section):
  - the only retained trace (S0-desk-r1, 1,781 B, 30 s session, Perfetto v50.1) contains 0 ftrace events, 0 sched rows and no process data;
  - ftrace setup errors 0;
  - the config was the minimal instance config (`instance_name: mm_events`, 6 events) with DISCARD buffers, `write_into_file` and no flush period. trace_processor flags this as data loss and an error in our own config.
  - The cause of the empty data is [O].
- This answers FS-R-014 §10's "parsed trace findings". Any future Perfetto proposal must fix the config and bring producer-side diagnostics. Nothing is planned; it is not on the critical path.

**J-218 · 2026-10-19T21:08:21Z. The K1g gate revision (FS-R-016 §5, c3-ii) is built, tested, reviewed and pushed on `feat/k1g-gate` cb7f016b, not merged. It awaits the Chair's review in FS-A-017.**
- The only executable changed is `fs-k1g-units.ps1` (pin `adf53f8c…` → `41e8107f…`). N1 needs no code change (shared `Get-FsK1gUnit2Outcome`).
- **The exception recognises only** the Unit 2 r2 record (nonce <attempt nonce withheld>, `b01996d7…`). Before it applies:
  - the ordinary bindings must pass;
  - the build and evidence copies must match byte for byte, and so must both ledger copies;
  - the class rule must hold (pre-arming ABORT, cases=0, clean after-session);
  - FS-R-016 is pinned by name and hash.
- **Unit 2:** one further attempt, only while the r3 candidate table is pinned. Prior attempts are discovered three ways (ledger, observe.json, attempt.lock).
- **Unit 1 and N1:** they need exactly one bound, clean, r3-lineage successor PASS.
- There is no force switch, no blanket exclusion and no "latest wins". The r2 REVIEW stays named.
- **Tests:** K1g 89/89 (was 71; 18 new); N1 107/107 with 3 rebuild cases skipped (was 103).
- **Reviews:** safety and correctness, both ACCEPT WITH FIXES, all applied.
- **New pins:** SIGNOFF-k1g `38d1c21d…`; SIGNOFF-n1 `be6f7f4f…` (that one line only). SIGNOFF-k1g also has disclosed prose changes.
- **Records:** `CHANGES-gate-r1.md` and `review/gate-r1.diff`. The limits are disclosed in §8 (successor MANIFEST and ledger text are not record-bound; A5 and PRIOR RESULTS show only the successor; DEVICE_REJECTED spends the attempt).
- **Incidents, disclosed:**
  - the N1 builder wrote three unspent candidate directories into the main checkout's ignored `build\n1` (`20261019T2035…`, `…2039…`, `…2042…`), which are harmless and left in place;
  - two agents' scratch files collided (`smoke2.ps1`), so an R-1 dry-run replay ran instead, offline only.
  - Lesson: agents use unique scratch names.
- **Usage limit:** all five offline agents were cut off at the session limit and resumed afterwards; none claims partial results.

**J-219 · 2026-10-19T22:14:12Z. Public update pushed (PM approval); stray N1 directories removed (PM approval).**
- PM (in chat): "You can go ahead and push the repo updates live." "You can remove the old N1 image folders."
- **Public repo** `continuumxr/frameshift` main: `d6cbf02` → **`8f123bb`** (fast-forward; author and committer the noreply identity; 2026-10-19T21:58:11Z).
  - Pushed by the Arbiter after the reviews finished: scope/privacy and licence/correctness, both GO-with-fixes with all fixes applied, re-audit clean. The Arbiter also scanned the added lines (no serials, no email, no unlock or root wording) and re-checked the tip.
  - Content: the T0 milestone, the K1g r3, N1 r2 and H1 packages with tools/blkguard, the kgate K1g result, the thermal fix, new and corrected research notes, the journal through J-217 (redacted), and the public README through FS-R-016.
  - New exclusions: the K1g/N1 run kits and the T0 runbooks (root material), and the system-actions design (private for now) (a public edition later).
  - The blkguard patches carry the public identity in From and Signed-off-by (DCO intact).
  - Review: the export review record (private).
- `export/public-20261019` merged into master (dca60f46): policy, provenance, PROJECT_SETUP. Local `frameshift-public` fast-forwarded.
- **Open:** an SPDX-header sweep for the new scripts (the three GPL test/bench sources first); the private README still shows K1a-era status.
- `build\n1`: the three unspent, untracked candidate directories from the gate agent's diagnosis were removed. The reviewed `20261018T005854Z-b1ba58d65e7ffa1a` and the older candidates remain.

**J-220 · 2026-10-19T22:15:30Z. R-1 phase 3 (`feat/r1` 008ab878, PACKAGE.md rev 3).**
- **QEMU** (under heavy host load, so no timing claims):
  - Run 2: the guard refused Valve's fsck write-open of the decoy; nosuid stopped sudo, pkexec and su; the poweroff signal name was fixed.
  - Run 4b: the shutdown path worked (SIGRTMIN+4 → 35 s → forced poweroff). It is not a valid guard-off negative control [O].
  - Run 5: the deadline supervisor survived systemd; the hold ended and the 45 s fallback fired under TCG.
  - Run 7b: at 7.6 GiB with every tmpfs cap full, about 2.0 GiB stayed available, with no OOM; a 7 s power-key hold gave a clean poweroff.
  - Run 8: all 109 masks held (0 violations), masked D-Bus names were refused, privilege probes were denied, and plain reboot worked.
  - Run 6b: the execve audit found no updater, rauc, deckard, fsck or partitioner run.
  - Runs 3/3b (read-through) and 3c (the SA-A4 ordering test) are incomplete; nothing is claimed.
- **Components:** offline 45/45, deadline 18/18, classifier 60/60, observer 27/27 (dry run), init 52/52 (text only; never executed [O]), builder 51/51 plus one NON-SHIPPING K1g-harness image that stops before handoff.
- **Defects fixed:** the multi-marker parser (rev 2 would have stopped every attempt); the guard-refusal pattern.
- **Rev 3 review:** GO-with-fixes (4 MAJOR, applied). The FS-R-016 notes are folded in: K1i throughout; extended operation as gate G-3a; SA-A4 described as defence in depth.
- **Arbiter technical call:** keep R-1 without an ack window, and review the side effect that `fs-ack` cancels N1's 6b fallback when R-1 reuses N1's base.
- **Incidents, disclosed:** a .pyc briefly in the ignored AOSP tree, then removed; a builder-test directory collision (both re-run); PACKAGE.md emptied once by a script error and restored from the commit.

**J-221 · 2026-10-20T03:53:18Z. FS-A-017 sent; FS-R-017 received (FS-R-017, private review record): gate revision r1 ACCEPTED; the FS-A-017 §7.3 pre-execution checks are all passed.**
- **FS-R-017:**
  - gate r1 accepted (`cb7f016b`; gate `41e8107f…`; SIGNOFF-k1g `38d1c21d…`; SIGNOFF-n1 `be6f7f4f…`);
  - CONCUR with exactly one new attended Unit 2 K1g r3 attempt (fresh nonce-only rebuild), then one Unit 2 N1 attempt after a bound, clean r3 PASS, then one Unit 1 K1g r3 attempt;
  - no further Chair round, but §7.3 must be completed first;
  - the limits are accepted as consistency and provenance checks, not authentication against a hostile operator;
  - an unpinned operator note on the historical REVIEW is required beside the Unit 1 and N1 prerequisite reports;
  - Perfetto: the parse is noted; the cause stays open.
- **§7.3, done by the Arbiter on merged master:**
  1. `cb7f016b` merged unchanged (0b261f46).
  2. All 10 delta files are blob-identical to `cb7f016b`: gate `41e8107f…`, both SIGNOFFs as reviewed. Relevant merge changes: none; master's other `tools/` changes are the four export files the gate and suites don't read.
  3–5. Both suites run in full (FS_SILENT=1), with new output files:
     - K1g **89 executed, 0 failed** (S section 18/18);
     - N1 **110 executed, 0 failed** (UG 6/6; **N3, N4 and O6 executed and passed**, the real rebuild included);
     - `build\n1` is unchanged afterwards (the rebuild test cleans up).
     - Outputs: `devices/quest3/host/test-host-{k1g,n1}.merged-20261020.output.txt`.
  6. Live-ledger check (read-only, a private output file): **Unit 2 K1g open** for the one replacement; **Unit 1 K1g blocked**; **N1 blocked**. Every message names r2 as K1G REVIEW, superseded for progression.
  7. SIGNOFF pin verification: both regenerate byte-identical (`38d1c21d…`, `be6f7f4f…`).
- The operator note (verbatim) is added to the K1g and N1 RUN-UNDER-F addenda (unpinned).
- **Next:** the attended Unit 2 K1g r3 session when the PM is at the device. Then N1 on Unit 2, then Unit 1 K1g r3.

**J-222 · 2026-10-20T07:49:33Z. K1g r3 on Unit 2: K1G PASS. The boot-chain write guard is proven on the device.**
- Run under FS-R-017/016/015/014. Nonce `<attempt nonce withheld>` (the one replacement attempt, spent); image `5ced51dd…`, a nonce-only rebuild of r3 `1ee9f105…`. Evidence: `devices/quest3/evidence/unit2-k1g-r3-20261020/` and the ledger `k1g-attempt-ledger-20261020/`.
- **0b:** [removed for publication]
  A1–A4 y (confirmed). Phase B 24.0 °C (charging). BA 24.0 °C.
- **Attempt:**
  - `fastboot boot` HANDOFF_ACKNOWLEDGED at 07:29:34Z; gadget at Th+12 s; COLLECTED-VALID; FSB1 VALID;
  - returned to fastboot by itself; AF/AA identity and slot unchanged;
  - AA10 30.0 °C; follow-ups 31.0 and 31.0 °C; phase F clean True (F1 y, F2 n, F3–F6 y).
- **Classifier: K1G PASS** (record `0015417d…ec98`):
  - kernel: the K1a config, 95 modules, MemTotal 7839080 kB, 0 warnings;
  - **guard: 411/411 cases PASS in device mode; 402 denials** (open 16, write 6, fallocate 2, discard 107, zeroout 100, roset 99, blkpg 12, rrpart 8, bio 3, scsi 21, sg 9, bsg 1, scsi-ioctl 12, pr 6);
  - strict and sealed, with the exact allowlist; modules_disabled 1; hazards none;
  - 14 nodes hash-verified unchanged; R1–R5 before and after at the expected values; misc and devinfo sizes as expected.
- **Gate after the PASS:** Unit 2 K1g closed; **Unit 1 K1g open; N1 open.**
- Historical r2 attempt `<attempt nonce withheld>` remains K1G REVIEW (`b01996d7…`). The r3 successor is `<attempt nonce withheld>` (`0015417d…`).
- **Next (FS-R-017 §5 order):** N1 on Unit 2, then K1g r3 on Unit 1. The FS-R-017 operator note goes beside N1's PRIOR RESULTS and Unit 1's A5.

**J-223 · 2026-10-20T16:18:24Z. K1i built and analysed offline (`feat/k1i` a2ebe9a7, not merged); N1 image ready.**
- **K1i** (BUILD-RECORD.md; va-bits-k1i.md rev 3 §7):
  - both variants built twice, **bit-identical** per pair (Image, vmlinux, .config, Module.symvers, System.map, all 278 .ko, and the stripped sets);
  - images: K1i-48 `ee34461b…`, K1i-39 `6daa4fa0…`;
  - modpost clean; each module set passes against its own kernel's Module.symvers (278/278, 0 CRC mismatches).
  - va48 run1's "end line: 1" was a count of `^end:` lines; the run completed with rc=0.
- **module_layout, demonstrated** (QEMU load test plus static CRCs, not hardware): stock `zsmalloc.ko` is refused (-8, "disagrees about version of symbol module_layout") by **both** K1i-48 and K1i-39; the K1g kernel accepts it. Static CRC across all 272 stock modules: stock `0xb1f01218`, K1i-48 `0xe6c528ca`, K1i-39 `0x41487de7`.
  - **Finding:** the refusal comes from the IPC options, not VA48. The VA39 control also needs its own rebuilt set.
- **Module table:** 278 rows.
  - Control at the K1a config: 271 of 272 differ from stock only in vermagic and build ID ("the compared code/data sections are identical"); socinfo is the exception.
  - At K1i the comparison is a difference inventory, not an equivalence claim.
- **SA-C1** stays a separate series [O] (PLAN.md §7, G9).
- **N1 0b** (PM remote): [removed for publication]
- **N1 image** `build\n1\20261020T155655Z-<attempt nonce withheld>` (`18cb5c28…`): nonce-only OK, preflight OK. Phase A onward waits for the PM tonight.

**J-224 · 2026-10-20T16:47:43Z. TS T1 status checked; PM decisions: retarget T1 to K1i, and --skin-absent.**
- **T1** (`feat/ts-t1` 72c59d30, built on the K1g r3 kernel lineage):
  - tests: builder 72/0, rows 29/29, checker 94/94, host 70 with 1 stale expectation (S0: SIGNOFF-t1 now exists);
  - both reviews' 25 findings fixed or declared; no delta re-review yet;
  - the branch predates the gate revision, so SIGNOFF-t1 needs regeneration.
  - On K1i, T1 needs K1i's rebuilt modules: stock modules are refused on module_layout (J-223).
- **PM decisions (in chat):**
  - T1 target: "Retarget T1 to K1i (Recommended)". Finish the K1i package first (K1i boot plus the guard re-proof), then run T1–T5 once, on K1i (the R-1 composition). The K1g-kernel T1 will not go to the Chair.
  - D-T1-7: "Yes, --skin-absent (Recommended)". A trial-only flag: the missing skin sensor is recorded, not treated as a fault; product handling is decided before T2.
- Arbiter calls: a delta re-review before T1's Chair package (adversarial-review rule); rebase on master and regenerate SIGNOFF when it is retargeted.
- **Next critical path:** the K1i concrete package, with SA-C1 as a separately named kernel change (FS-R-016 (e), §7), then the K1i device run and TS T1–T5 on K1i, then R-1.

**J-225 · 2026-10-20T17:06:51Z. PM goal: an installable test image goes live for testers at V3.**
- PM (in chat): "I think once we get to the V3 I would like to push an installable image live for testing."
- V3 means R-1, G1–G3, V0–V2 (6DoF head) and V3 (Touch Plus controllers).
- **Release prerequisites planned in parallel:**
  - the installed-boot path and PC installer (research only today; they need Chair rulings);
  - Return to Horizon (SA-P4);
  - the update service (SA-P5–P7);
  - TS T1–T6 including the soak;
  - the legal and licence pre-release check;
  - tester docs and a feedback channel.
- No Valve redistribution: the installer fetches Valve's signed image from Valve.

**J-226 · 2026-10-20T17:11:42Z. PM device plan: Quest 3 and Quest 3S in tandem with a joint launch; all four devices in lockstep after R-1.**
- PM (in chat): "this should be developed in tandem with the Q3S version so they could theoretically be launched at the same time. Then we go us on getting the Q2 and QPro version working. They should all move forward from R1 together."
- PM clarified: "Q3+Q3S launch together; all 4 in lockstep after R-1"; Quest 3S hardware: "I'll get a Quest 3S".
- This supersedes the 2026-10-09 order (Q3, Q2, QPro, Q3S) adopted in FS-R-006. **Disclose it to the Chair in the next relay.**
- Until the 3S unit arrives, 3S work stays offline: the Quest 3 kernel tree with its own config; the kgate under ~/work/kgateq3s; and the 3S display, lens and camera differences studied from its own firmware.

**J-227 · 2026-10-20T17:15:50Z. PM note: the Quest 3S displays should be identical to the Quest 2's.**
- PM (in chat): "The Q3S displays should be identical to the Q2, so that world should coincidentally carry over too."
- Recorded as a lead [C, PM report]: Q2 panel work (timings, panel binding, lens geometry) may carry to the 3S, while the display controller is the Quest 3 SoC's (DPU/DSI on XR2 Gen 2). To be confirmed from the 3S firmware and device tree.

**J-228 · 2026-10-20T17:56:51Z. SA-C1 restart-state lockdown written (`feat/k1i` 33de60f4); PM decisions on module signing and fuses; R-1 long QEMU runs relaunched detached.**
- **SA-C1** (`devices/quest3/k1i/sa-c1/`, GPL-2.0 patches 0002–0009, applies cleanly, reproducible head `94f7ed0f`):
  - exact-match restart allowlist (plain; `bootloader`; `recovery` only when installed). Anything else gets EPERM from reboot(2); in-kernel callers fall back to a plain restart;
  - the boot-fixed tethered/installed mode (`fs.installed=1`, read once in setup_arch, `__ro_after_init`);
  - reboot-reason writes only 0x02/0x01 (panic 0x07);
  - dload-mode never arms dump or EDL, and the bootloader-appended download-mode options are ignored;
  - SDAM and dload sysfs are read-only; qcom_scm ignores `download_mode=1`; the involved drivers can't be unbound.
  - T-SA2 part 1: 1,305 checks plus 27 static checks pass (stock fails 152). The QEMU part waits for the build. Device-only items are [O].
  - Review: GO-with-fixes (the MAJOR `KERNEL_PARAM_OPS_FL_NOARG` fix applied; root-module and real-kernel evidence declared).
- **PM decisions (in chat):**
  - module signing: "Rely on the latch (Recommended)". No MODULE_SIG; the pre-latch root-module window is declared a residual (owner control).
  - fuses: "Yes, read-only (Recommended)". The qfprom nvmem is read-only from userspace (new patch 0010, in progress).
- **Builds:** a detached SA-C1 queue (`~/work/k1i/sac1-queue.sh`) waits for the QEMU runs to end, then runs the K1i-48 and K1i-39 SA-C1 pairs.
  - Incident: the first launch's wait test used `pgrep -x` on a 15-character truncated process name, so it started at once. It was stopped during the source clone, the partial clone was removed, and it was fixed (`ps -eo args`).
  - The queue was then stopped again for the series change (0010). It is relaunched after 0010.
- **R-1:** runs 3e (`reboot recovery` / SA-A4 ordering), 6c (`reboot bootloader` plus execve audit) and 3f (the full read-through) were started at 17:19Z as detached WSL jobs from `feat/r1` 0414f66f (with time limits).

**J-229 · 2026-10-20T18:46:48Z. PM: write a public "How FrameShift works" guide now.**
- PM asked whether a full explanation of how FrameShift works, and of everything done so far, would go to the repo. The Arbiter's answer: the pieces are public (README, PROJECT_SETUP, the redacted journal, research notes, package READMEs), but no single guide exists.
- PM decision: "Write it now (Recommended)". The guide is drafted after the K1i package agent finishes (one agent at a time), reviewed for public safety, updated at each milestone, and published with the next export after PM approval.

**J-230 · 2026-10-20T21:15:27Z. K1i device-run package built offline (`feat/k1i` a15c0b11; pins PENDING-BUILD); finding: `systemctl reboot <arg>` is refused by SteamOS 0.4.5's systemd.**
- **The K1i package** (devices/quest3/k1i/) reuses the K1g machinery. What changes:
  - the kernel and config pins, with SA-C1 identity checks;
  - our own rebuilt 95-module closure (PID 1 verifies index, dep, softdep, load list and the file set before any insmod);
  - SA-C1 restart-state facts (read-only) folded into the existing steps, so the host start limit is BootStartUtc+48 s;
  - the order gate: per unit, the unit's own K1G PASS is required; one attempt; for Unit 1, also Unit 2's K1I PASS and A5.
  - The guard probe `c1de030c…`, its rows and the 200 s deadline are unchanged.
  - Tests: builder 91/91 (a dev run; repeat on the committed tree with pins), image 25/25, host 76/76, bounds 17.
  - Reviews: device/safety and host/checker, both GO-with-fixes (2 MAJOR each), fixes applied or declared. The fixes were not re-reviewed.
  - PENDING-BUILD: the SA-C1 kernel and module-set pins, kernel gate G6, the candidate table.
  - For the Chair:
    - a new delegation ruling for K1i;
    - qfprom (0010) isn't in the 95-module closure, so it is not exercised on the device;
    - there are no device write-refusal attempts;
    - a module-set refusal probably lands in Android, with dump mode not excluded [O].
  - The agent's commit trailer names Claude Sonnet 5.5 (the model that did the work).
- **R-1 QEMU runs 3e and 6c (detached, 17:19Z):**
  - both reached END with every mask holding, the decoys unchanged, and the direct `reboot(2)` with an argument refused ("Operation not permitted").
  - Both then hit the time limit, because the harness's final `systemctl reboot recovery` / `reboot bootloader` failed with "**Too many arguments.**" SteamOS 0.4.5's systemd (257) rejects the positional reboot argument; `systemctl reboot --reboot-argument=<arg>` is needed.
  - This explains the earlier runs' missing end too. The **system-actions design, R-1's operator procedure and the harness need correcting.** Run 3f (read-through) is still running.

**J-231 · 2026-10-20T21:25:58Z. The reboot-argument fix is applied; R-1 run 3f found a real memory problem; the SA-C1 builds have started.**
- **Fix** (J-230):
  - static confirmation from the 0.4.5 `systemctl` binary's strings: `--reboot-argument=ARG` exists, and "Too many arguments." is printed for the positional form;
  - `feat/r1` e72a731a fixes the harness and the R-1 procedure and drafts; master 40bb2e71 updates system-actions-design rev 0.2;
  - tests: test_r1 45/45, classify 60/60, init 52/52, deadline 18/18.
  - Stale copies remain on `feat/k1i` and `feat/ts-t1` (they will update on merge), plus FS-A-016:937 (a sent relay, to be corrected in the next relay). The SA-C1 README and the 0003 message use `systemctl reboot edl` as an example of a refused string (to clarify).
- **R-1 run 3f** (the full read-through, Quest-sized 8 GiB VM, masks on): progress reached 7.0 GiB at 1,491 s, then **"Kernel panic - not syncing: System is deadlocked on memory"** at 5,716 s; the decoys were unchanged. Run 3d had stopped at the same point (about 7 of 10 GiB).
  - **A real R-1 design finding:** with the about 4.27 GiB tmpfs-resident image, zram off and no swap, the full read-through exhausts memory. The cause is [O]: page cache through loop and dm-verity, or tmpfs pages being unreclaimable.
  - R-1 needs a memory-plan revision before any device package (an R-1 agent, after the current work).
- **The SA-C1 build queue** started at 21:14Z, once the QEMU runs had ended. The pins match (`2204c124`, tree `18282c9b`); va48 run1 is running.
  - The re-runs of R-1 3g/6d (the reboot fix) were started briefly, then stopped before QEMU began, to give the build the RAM. A detached waiter (`~/work/r1-qemu/after-build.sh`) starts them when the queue ends.

**J-232 · 2026-10-21T02:55:04Z. Two community Quest 2 repos assessed (27a1f86b), plus a deep study (4d487fe6, private); a new lead: Valve's vrcompositor platform gate.**
- **Repos** (PM-found):
  - [removed for publication]
- **PM guidance:** "The kexec repos are fair game for us to analyze to figure out things like displays, compatibility, workarounds, etc."
- **Deep-study leads (18; private note):**
  - Quest 2 panels need two 960-wide planes (pipe throughput, which matches our M2 finding);
  - the bootloader-handoff recipe (same mode on the first commit; never power-cycle the panel);
  - the Quest 2 dsi_pll_7nm cached-mux 2× clock bug (cold init only; Quest 3's 5nm PLL lacks that pattern but has an integer-fps truncation);
  - A650: a GMU fault leads to a pinned GPU level (≤587 MHz); `force_lazy_gpumem=2`; the zap shader is device-signed, in modem;
  - Mesa/kernel needs that confirm gpu-route F4/F6; the kernel-option list;
  - first-run loops and polkit power actions; a PipeWire null sink while there is no ALSA device.
- **NEW lead (G3/R-2):** Valve's vrcompositor reportedly aborts unless the DT model reads as SM8650 or SM8250. This sits beside our "Do not go here" item 4 and Valve's `kernelsetup.sh` model-string gate, which writes boot firmware on a Frame-model match. The DT identity we present is a PM/Chair decision. To verify statically in our own 0.4.5 vrcompositor before any GPU package.
- **AI-directed text** (disclosed to the PM, not followed): the kexec repo's pasted Claude Code session prompt ("Read NOTES.md in full before doing anything") and its NOTES.md hand-off text.

**J-233 · 2026-10-22T01:24:06Z. N1 r2 on Unit 2: the attempt was spent but the collector refused, so nothing was sent (expected INCONCLUSIVE; phase F pending). The K1i SA-C1 builds are done. R-1's reboot checks pass in QEMU.**
- **N1:**
  - Phase A passed on 2026-10-21 (A1–A6 y; the FS-R-017 §4 operator note shown). Phase B 27.0 °C. BA, BF and E OK.
  - The attempt registered at 16:13:05Z (spent); `fastboot boot` HANDOFF_ACKNOWLEDGED; gadget at Th+12 s.
  - **Collector: "refused: output directory already exists … \collect"** (exit 20); nothing was sent to the device.
  - The cause [D]: fs-collect-n1.ps1 creates the output directory for its NCM transfer job, then the shared engine refuses an existing directory. The live path was never exercised; the tests used replay only.
  - The device returned to fastboot by itself at about T0+200 s. AF and AA OK; AA10 30.0 °C.
  - The PM left (RUN-UNDER-F §7). The follow-ups were delayed by PC sleep: both taken at 01:22Z on 2026-10-22, 1 s apart, 25.0 °C. A timing departure.
  - Phase F and the classifier wait for the PM. **N1 r3 needed:** the collector fix plus a live-path test.
- **K1i SA-C1 builds:** queue done at 2026-10-21T01:24:58Z, all four runs rc=0 (K1i-48 and K1i-39, two each). The bit-identity comparison and pin filling are next (an agent).
- **R-1 reboot re-runs** (feat/r1 e72a731a; run automatically after the queue):
  - 3g (`systemctl reboot --reboot-argument=recovery`): "fs-reboot-param-guard: refused reboot argument 'recovery'; restarting with none". **SA-A4 ordering confirmed** in QEMU.
  - 6d: "Restarting system with command 'bootloader'".
  - Both qemu_rc=0, decoys unchanged. These close the two R-1 [O] items (emulator evidence).

**J-234 · 2026-10-22T01:45:18Z. N1 r2 Unit 2 closed: phase F PASSED with clean False (follow-up spacing); classifier exit 70 (no collect.json), so no N1 result; the attempt is spent.**
- Phase F: F1 y, F2 n, F3–F6 y (confirmed). follow-ups-finished FAILED, because reading 2 was 1 s after reading 1 (the PC slept with the lid closed; the readings were taken on wake and reconnection).
- **PM executive decision:** "approve the late temp readings anyway. So far none have shown to be abnormal". The tool verdict is kept and the PM decision recorded beside it.
- PM: Unit 2 was unplugged right after AA, and reconnected before the readings.
- PM rule: the laptop stays open, and the PM says before closing it (no keep-awake).
- Evidence: `devices/quest3/evidence/unit2-n1-20261021/` and the ledger `n1-attempt-ledger-20261021/`.
- **N1 r3 needed:** the collector output-directory fix and a live-path test.
- FS-R-017: "Report and resolve an unexpected N1 outcome … before continuing the sequence." Reported to the PM; the cause is understood and host-only (the K1g collector is separate and proven live).

**J-235 · 2026-10-22T03:09:28Z. N1 r3 built and reviewed offline (branch `feat/n1-r3`, head `4a6bf5b8`); the gate is inert until a Chair ruling.**
- Root cause confirmed by both reviewers: `fs-collect-n1.ps1` created the output directory for the transfer job, and the shared engine's New-FsCapture refuses an existing directory, so it threw before the port opened (exit 20, nothing sent). Every live run would have refused.
- Fix: an existing directory is refused up front, and only the engine creates it. The job writes no file; `xfer.json` is saved after the engine, never throws, and goes only into the engine's directory. `collect.json` records the host-tool hashes. `fs-collect.ps1` is unchanged (no K1g pin moves).
- Live-path test LV0–LV5 (scripted ACM device, FSX1 responder on ::1, loopback adapter): the pinned r2 bytes reproduce the r2 refusal exactly; r3 gives COLLECTED-VALID, 8 MiB each way. Not testable without the device: the real port, a UsbNcm adapter, the fe80:: connect and real-time budgets.
- N1 gate revision r1 (`fs-n1-units.ps1`): recognises only attempt <attempt nonce withheld>, pinned byte for byte, and admits one r3 attempt. The historical attempt stays "without an outcome", never a PASS. The ruling pin is empty, so Unit 2 stays refused until the Chair rules.
- Tests: N1 128/0 (N3/N4/O6 run; O5 skipped, no `build\k1a` in the clone); K1g 89/0. SIGNOFF-n1 `be6f7f4f…` → `954de7db…` (three pin rows); SIGNOFF-k1g unchanged. Image unchanged (b1ba58d6).
- Reviews (safety, correctness): ACCEPT WITH FIXES, no blocker; all findings fixed (`devices/quest3/n1/CHANGES-r3.md` §10, RA3/RB3).
- Seven unattributed `%TEMP%\fsn1-host-*` directories left in place. No AI-directed text found.
- No headset, E: or /persist access. Unit 2 unplugged by the PM.

**J-236 · 2026-10-22T15:41:36Z. FS-A-018 drafted, reviewed and bundled; READY TO SEND. N1 r3 hardened (feat/n1-r3 `644b981d`); K1i pins filled (feat/k1i `ab2cf6c6`).**
- K1i: the SA-C1 build pairs are bit-identical (va48 Image `ac02bfaa…`, vmlinux `41315cc2…`, modules digest `e8c787a4…`; va39 Image `8adbe889…`). Pins filled except EXPECT_K1I_GATE (G6 not run). Host tests 76/76; six pin-state assertions rewritten (P1 weaker: checks "not PENDING" only), disclosed.
- N1 r3: the gate now pins the r2 `checklist-n1.json` (`33b76723…`) and requires follow-up spacing to be its only non-clean reason (`492c8365`). Delta review RA4: ACCEPT WITH FIXES, three MINOR fixed at `9bdd471a` (hidden/unknown-serial locks on the outcome side, type-strict and case-sensitive fact checks, every `serial=` match), plus collector exit 15 when collect.json cannot be saved. N1 130/0/0, K1g 89/0/0. SIGNOFF-n1 `19e4b8a4…`.
- FS-A-018: Chair-view review ACCEPT WITH FIXES (three MAJOR: ruling-pin fill is a runtime-byte change; non-clean phase F needs explicit concurrence; the reboot correction limited to what QEMU showed). All applied; facts check done.
- PM decisions: bundle the original session logs and journal as byte copies (no redacted copies).
- Relay FS-A-018 (private review record) SHA-256 `b3a0577d1d48c775ba8f371060c19e2a854009c8be3f94f94cd98d3037a6c96a`; bundles: n1-r3-package `4c377019…`, evidence `3917aa5e…`, raw `8b31a998…` (deterministic across runs).
- No headset, E: or /persist access.

**J-237 · 2026-10-22T15:59:46Z. FS-A-018 sent by the PM** (relay `b3a0577d…`, three bundles as listed in J-236). Awaiting FS-R-018. Until then: offline work only; no N1 r3 or Unit 1 K1g session.

**J-238 · 2026-10-22T16:02:34Z. FS-R-018 received and saved (FS-R-018 (private review record)).**
- ACCEPT Unit 2 K1g r3 PASS; N1 r2 = spent attempt WITHOUT AN OUTCOME (no INCONCLUSIVE record may be made). CONCUR one Unit 2 N1 r3 replacement after the §4 checks. Unit 1 K1g r3 may run before N1 r3 (SIGNOFF-k1g `38d1c21d…`, one attempt, operator note quoted with its timestamp in the attempt log).
- The non-clean phase F exception is for that exact event only; never a precedent for late follow-ups. The Chair notes the late readings also missed the observation window, not only spacing.
- §4: fill exactly Ruling `FS-R-018`, RulingSections `s.3, s.4`, RulingSha256 = LF sha of the committed ruling; correct UN0/UN1/UN9 with an explicit empty-ruling fixture (no skipping or weakening); then merge, suites on merged master, live-ledger check, session pin check.
- R-1 memory guidance forwarded to the running R-1 agent. K1i: no execution scope. Compositor model gate: inspect the 0.4.5 binary before choosing a DT identity.
- **Correction (Arbiter):** FS-A-018 was sent with its header still reading "DRAFT — not yet reviewed" although the Chair-view review, delta review and facts check were done (J-236). The sent file is kept unchanged as the record; disclose in FS-A-019.

**J-239 · 2026-10-22T16:45:14Z. FS-R-018 §4 pre-execution steps 1–5 done on merged master `e41b599f`; N1 r3 cleared for one Unit 2 session (step 6 at session time).**
- Ruling fill and test correction on feat/n1-r3 `a78ae504` (after merging master at `d552a9b0`, docs/relays only). Runtime diff vs `644b981d`: exactly the three ruling values (`FS-R-018`, `s.3, s.4`, `7fef506f…`). With them blanked the gate hashes to `059b7ed9…` (UN12). Gate filled `1d725bbdfb3ec8b4c05fc6110622efd04b15776414adee6ab1817c2ecc3e16a3`; SIGNOFF-n1 `8cea3cc65dfb5a50b465b70a5d73cf9268e6aea98b5386d69c7e5f6fe61ee4fc` (one row changed vs `19e4b8a4…`); SIGNOFF-k1g `38d1c21d…` unchanged; the N1 host suite (private) `1c9b8e20…` (explicit empty-ruling fixture for UN1/UN8/UN9; UN0 drops only its no-ruling condition; new UN15 checks the deployed ruling pins and file hash).
- Merged into master `e41b599f` (tree identical to `a78ae504`). Suites on merged master (FS_SILENT=1): K1g 89/0/0; N1 132/0/0 incl. the real rebuild N3/N4/O6, LV0–LV6, UN0–UN15, and O5 (the main checkout has `build\k1a`). Outputs `devices/quest3/host/test-host-{k1g,n1}.merged-20261022.output.txt`.
- Live-ledger check (read-only, FS-A-019 (private review record) → a private output file): Unit 2 K1g closed; Unit 1 K1g open; Unit 2 N1 open (historical r2 named WITHOUT AN OUTCOME); Unit 1 N1 blocked.
- Remaining before each session: session pin verification and the fresh nonce-only rebuild. The laptop must stay awake through the follow-up readings; defer the boot if the session cannot finish before the PM leaves (FS-R-018 §4).

**J-240 · 2026-10-22T17:11:08Z. R-1 memory: cause found and fixed offline (feat/r1 `972c7ca9`); read-through passes in QEMU at 8 GiB and 6 GiB (measurement).**
- Cause [D, harness kernel source; M, runs 3f/3i]: tmpfs allocates a page for every hole read through a non-user read (the loop driver's path), so the read-through materialised the sparse RAM image's holes. 3f: image 4,586,516,480 B at load end; shmem grew by 3,546,316,800 B = the hole bytes below the ~7.50 GiB read offset at the panic. No second image copy; dm-bufio ≤ 20.5 MB. PACKAGE R1-2/§5 ("holes never materialised") corrected to load-only. Claims cover the observed runs and the harness kernel only; the device kernel is [C].
- Fix (our layer only; Valve's image untouched; one backing object): a 16 MiB zero area after the hash tree in the same RAM file; a read-only dm-linear map `fsr1-valve-map` sends holes to it; verity reads data from the map and hashes from the loop. Full authentication kept (every block verified; read-through SHA-256 = Valve's). dm-zero is off in the device config. New memory lines MEM-RX, per-GiB MemAvailable/Shmem/dm-bufio, Shmem in MEM-2. One adversarial review: BLOCKER (verity parameter buffer too small) and three MINOR fixed at `da45238e`; one deliberate difference kept.
- Tests: classifier 62/62, init 53/53, receiver 45/45 (builder test not run from a worktree: environmental).
- QEMU (TCG): 8 GiB match=yes, Shmem flat 4,503,684 kB, MemAvailable at target 3,303,312 kB; 6 GiB with harness-only `fsr1.mem1=1024`: match=yes, MemAvailable at target 1,249,260 kB (below MEM-2's 1,792 MiB floor); 6 GiB with the real reserve: refused at MEM-1 (fails closed). QEMU times do not establish the device budget (V2 ≤ 150 s) [O].
- Plan: RAM-root for 8 GiB and larger (Quest 3, 3S, Pro). Quest 2 (6 GiB) cannot hold the image in RAM; zram does not help (lz4 4.12 GB, zstd 4.06 GB). Storage choice for 6 GiB goes to the PM.

**J-241 · 2026-10-22T17:26:59Z. PM decision: Quest 2 (6 GiB) gets the SteamOS image served from the PC.**
- Asked with three options (decide with the installer [recommended], headset storage now, served from PC). PM chose **"Served from PC"**: Quest 2 reads Valve's image from the PC over USB, still fully verified by dm-verity on the headset; nothing is written to the headset.
- Consequences to design: works only while tethered; needs a network/USB block-device option in the Quest 2 kernel (its own kernel, not K1i); the PC side becomes a served, read-only image; R-1 on 8 GiB+ devices stays RAM-root. To be put to the Chair with the Quest 2 package.

**J-242 · 2026-10-22T17:47:49Z. Compositor model gate studied statically in Valve's 0.4.5 (private note a private research note, `664b9644`). Nothing executed.**
- [M-static] The check is not in vrcompositor itself but in a perception library it loads for CVP motion estimation: the device-tree model must contain "SM8650" or "SM8250", or the process aborts. It runs only on that library's session path, which the compositor takes when an async-Vulkan setting is on (Valve default off; the Frame driver's settings turn it on) [D, medium confidence]. XRService has the same aborting check; other DSP clients only return false.
- **Safety hazard [M-static]:** a shared model helper does substring matching on Frame board names. Matching models arm Valve's boot-chain/U-Boot flash path (kernelsetup.sh) and FPGA programming; a manual OOBE script installs an image and may request a factory reset; steamos-manager applies Frame CPU/GPU limits on an sm8650 compatible. A Frame-like model string ("SM8650 MP …") contains a matching token, so presenting it system-wide would arm the flash path.
- Recommendation (A): keep our real DT model and compatible everywhere; stay off the CVP/XRService paths through our own settings layer (async-Vulkan off, Frame HMD driver not loaded, cv driver disabled). Fallback (B): an SM8650 model visible only to SteamVR processes in their own namespace, avoiding every helper token ([O] safety review needed). Option C (system-wide Frame model) rejected.
- Open [O]: live check that the compositor starts on route A; the systemlayer path into the library; driver_cv on a failed DSP check; Steam client checks. Decision belongs with the GPU-stage package (Chair).

**J-243 · 2026-10-23T04:20:00Z. K1g r3 on Unit 1: K1G PASS. The boot-chain write guard is now proven on both Quest 3 units.**
- Run under FS-R-018 §5 (with FS-R-017, FS-R-016, FS-R-015, FS-R-014). Nonce `<attempt nonce withheld>` (the one Unit 1 attempt, spent); image `55ca4fc9…`, a nonce-only rebuild of the r3 candidate. Evidence: `devices/quest3/evidence/unit1-k1g-r3-20261023/` and the ledger `k1g-attempt-ledger-20261023/`.
- **0b:**
  - [removed for publication]
  - **PM standing permission:** "You have my permission to `adb reboot` next time."
- **Process slips (Arbiter), both recorded in the attempt log:**
  - The host-hashes command omitted the end of the SIGNOFF-k1g §A command, so `host-hashes.txt` held hashes without paths. Phase A STOPPED at its first check with nothing sent to the headset. The PM said "yes" to the recommendation; the file was rewritten and phase A re-run (PASSED). The incomplete file is kept as `f/host-hashes-incomplete-command.txt`.
  - Phase B STOPPED at the 02:31Z reading (status 2, level 90, temperature 330): while charging the reading must be below 300. Nothing was sent to the headset; the PM let the unit cool and the Arbiter took passive readings. The Arbiter's reading loop stopped only for status 5 or below 295 and so missed a passing status-3 reading (310) at 03:12:22Z. The admitted reading was status 5, level 100, temperature 320 at 03:32:35Z (battery full, within the rule).
- **PM "Executive override: let's start the test now." declined:** the admission rule is FS-R-012 §5, enforced by the pinned phase B tool; there is no override. The PM's direction (propose admitting status 2 below 35.0 °C above 70 % charge) is recorded for FS-A-019 in FS-A-019 (private review record). The PM also remarked, on re-confirming in chat what the keypresses had already recorded: "we should change that" (recorded in the attempt log).
- **Attempt:**
  - Phase E presence confirmed; attempt registered 03:40:48Z; `fastboot boot` HANDOFF_ACKNOWLEDGED at 03:41:00Z; gadget `FS-<attempt nonce withheld>` on COM21 at Th+12 s; COLLECTED-VALID; FSB1 VALID.
  - Returned to fastboot by itself; AF/AA identity and slot unchanged (AF02–09 = BF02–09; AA = BA for 04–09, 16–21, 23: 0 differences after normalising fastboot's "Total time" footer).
  - AA10 temperature 330; follow-ups 330 and 330 (status 2 and 5, level 100); phase F clean True (F1 y, F2 n, F3–F6 n).
- **Classifier: K1G PASS** (record `75f0e6d4…17b2d`, `observe-20261023T034048Z`):
  - kernel: the K1a config, 95 modules, MemTotal 7836020 kB, 0 WARNING, 0 BUG;
  - **guard: 411/411 cases PASS in device mode; 402 denials**; 14 nodes hash-verified unchanged (digest before = after `c465f51b…`); R1–R5 before and after at the expected values; R6 misc 1048576 and devinfo 4096; strict and sealed, modules_disabled 1, hazards none; FSUP1 exited 0.
- **Gate after the PASS** (`gate-live-ledger-check-after.txt`, master `71c6dc51`): Unit 2 K1g closed; **Unit 1 K1g closed**; Unit 2 N1 open; Unit 1 N1 blocked (N1 runs on Unit 2 only, PM decision 2026-10-16.
- Report to the PM at ~04:06Z.

**J-244 · 2026-10-23T05:35:00Z. N1 r3 on Unit 2: N1 FAIL (PC side: the NCM adapter had no usable IPv6 link-local address). The one replacement attempt is spent; returns for review (FS-R-018 §3).**
- Run under FS-R-018 §3–§4 (with FS-R-017, FS-R-016, FS-R-015, FS-R-014). Nonce `<attempt nonce withheld>` (fresh nonce-only rebuild, image `e7f93e2b…`); cycle `captures\<attempt nonce withheld>`. Evidence: `devices/quest3/evidence/unit2-n1r3-20261023/` and the ledger `n1-attempt-ledger-20261023/`. Attempt registered 05:18:04Z.
- **0b:** [removed for publication]
- **Phase B** STOPPED at 04:40Z (status 2, temperature 300, rule is below 300 while charging); nothing was sent to the headset. Passive readings held at 300 until status 5 at 05:12:19Z; formal reading 05:12:39Z status 5, level 100, temperature 300: PASSED. PM go 05:16:24Z.
- **Attempt:** `fastboot boot` HANDOFF_ACKNOWLEDGED; gadget on COM22 at Th+13 s; collector COLLECTED-VALID, FSB1 VALID, fs-done sent. The transfer failed on the PC: Windows created the `UsbNcm Host Device #2` adapter (ifIndex 51, up, MAC matched) at about +28.5 s, but it never got a preferred IPv6 link-local address; 0 connect attempts, 0 bytes; the device side reported accept-timeout.
- **Classifier: N1 FAIL (exit 42).** Device-side facts were clean (K1a banner, config `4aa0c894…`, 95 modules, 0 WARNING/BUG pre and post, `usb0` up with its link-local address, no listeners, ACM continuity). Only the transfer check failed. classify-n1.json sha256 `428f4b1b…`, xfer.json `2f976236…`.
- **Return and phase F:** back in fastboot by itself, rebooted; AF02–09 = BF02–09 and AA = BA for rows 04–09, 16–21, 23 (0 differences after normalising fastboot's "Total time" footer); AA10 temperature 320; follow-ups 330 and 320; phase F PASSED (clean True, F1 y, F2 n, F3–F6 y).
- **Gate after:** Unit 2 K1g closed, Unit 1 K1g closed, **Unit 2 N1 closed** (attempt spent), Unit 1 N1 blocked (`gate-live-ledger-check-after.txt`). No third attempt; the laptop stays available through the disposition.
- **PM requests, recorded for FS-A-019 in FS-A-019 (private review record):** the assent friction ("explicitness" that wastes time; one session go should cover the session), the chat re-confirmation of already-recorded keypresses, and the admission temperature rule (propose admitting status 2 below 35.0 °C above 70 % charge). The PM also said during the attempt: "I did not \"UsbNcm Host Device\"" (the adapter appeared without a visible prompt).
- **Community and Valve repos reviewed** (private note a private research note, commit `420d1118`): an unofficial mirror holds Valve's actual Frame kernel source, and the 0.4.5 kernel commit is reachable. **PM decision: "If an official source exists, we should adopt it as our reference."** (confirming the mirror against Valve's own host is open).

---

## Corrections

Earlier claims we got wrong, kept visible on purpose.

| when | we said | actually | how we found out |
|---|---|---|---|
| JOURNAL Do-not item 7; `docs/RESEARCH_NOTES.md` section 4; J-08; `FS-A-002` §6 | "As of 2026-10-07 the Frame kernel source has not been located" | **Valve publishes it**: GPL source tarballs `linux-618-deckard-6.18.0+g<hash>` and `linux-72-deckard` in the public listing `holo-packages.steamos.cloud/archlinux-deckard-hotfixes/source/` (oldest 2026-10-01; the 6.18 commits listed are `29e952b28e50`, `4b6c9fe99a37`, `733a4be78129`, `a74502eff11e`). The 0.4.5 release commit `e66bc2ca6f8c` and the 0.3.0 commit `fbdbca41fd45` are **not** in that listing; both are in the unofficial `evlaV/deckard-linux` git mirror (Valve-authored commits). The tarballs' upstream GitLab project is not public | community-repos review of 2026-10-23 section 0A; public listing and `git ls-remote` checks, nothing downloaded |
| J-207 / FS-A-016 | "vbmeta, vbmeta_system, misc and devinfo were not read" and "no row after R2 was opened" | **No later row was opened after the R3 failure.** R3 (dtbo_a) was opened and its read failed with EINVAL before any byte was hashed | FS-R-016 §3 |
| J-207 / FS-A-016 | "the guard was never armed" | strict arming and sealing and the armed cases were **not reached**; the record still shows the boot-default `mode: protect`; zero denied counters and zero cases do not validate interception | FS-R-016 §3 |
| J-207 / FS-A-016 | "no dump mode (PC PnP check: no 05C6:900E ever registered)" and "the timeline leaves no room for a dump-mode visit" | **no dump mode was observed or reported by the PM; the retained return record is consistent with that.** The PC PnP check is a reported check, not retained hardware evidence; a short return timeline does not prove that no transient enumeration happened | FS-R-016 §3 |
| FS-A-015 / FS-R-015 (K1g r2) | the 512-byte O_DIRECT rounding was disclosed and accepted | **review gap:** the rounding was not checked against the available device block-size evidence (Unit 1's FS-A-005 log already showed 4096-byte UFS blocks); this caused the r2 REVIEW; fixed in r3 | FS-R-016 §3, §8 |
| `FS-A-015` §3.2(b) | the K1g test harnesses use 512-byte sectors (disclosed as a limitation) | superseded: K1g r3 added 4096-byte-block QEMU and UML harnesses (devicesim-4k 196/196; strict-4k, k1g-layout-4k), including a reproduction of Unit 2's EINVAL | J-212 |
| J-199 (APK leads: "SteamVR binaries are 4K-aligned, so 4K pages are mandatory"); Corrections row "`FS-A-006` (Valve OS facts)" ("so the kernel **must** use 4K pages"); `<private note, withheld>` L-A4 | `p_align` 0x1000 proves 4K pages are required | `p_align` = 0x1000 alone does not prove a binary cannot load with larger pages; the observed alignment [M-static] is kept apart from the "must". The PT_LOAD check (read-only `readelf -lW`, 2026-10-18): `vrcompositor` 0.3.0 and 0.4.5 and 0.3.0 `vrserver` have an R+X segment at offset 0 / vaddr 0 and an RW segment with `p_vaddr − p_offset` = 0x1000 [M-static; exact values in the private note]. Meta's v2.7 `binfmt_elf` maps at `p_offset − (p_vaddr mod PAGE_SIZE)` and `vm_mmap` rejects an unaligned offset (`fs/binfmt_elf.c:368-369`, `mm/util.c:561`) [M-static], so under 16/64 KiB pages this kernel would refuse those two binaries [D, not run]. `steamclient.so` and other `ld.so`-loaded objects were not examined. Retaining 4 KiB pages is accepted and changes no package | FS-R-015 §7; `<private note, withheld>` rev 1 |
| J-199 ("Our DRM/KMS Turnip route must implement them for real"; "Valve's streaming player needs a V4L2 stateful decoder"; "new requirements for the R-1/R-2 graphics route"); `gpu-route-decision.md` F2a; `<private note, withheld>` §0 item 1, L1, L14 | the display-event extensions and the V4L2 decoder are requirements | F2a is a **compatibility lead**: imported/referenced extension names do not establish mandatory use, absence of a fallback or a working Quest display path; the decoder need is a lead until confirmed | FS-R-015 §7; `gpu-route-decision.md` rev 1.1 |
| J-199 ("Stearlight has no VA39 workaround"); `<private note, withheld>` §0 item 3, §5, L15 | no VA39 workaround exists | a **bounded negative**: none was found in the sources zip (not the full repository) and the APK we read. PRoot-app and QEMU-only results (Stearlight, Reframed VR) establish neither native headset boot nor tracking | FS-R-015 §7; `stearlight.md`, `reframed-vr.md` rev 1 |
| `va-bits-k1i.md` rev 0 (J-197, J-198 basis) | 48-bit is "the only configuration Valve ships and tests"; FEX, Wine and V8 "shrink to fit"; any program that maps at a fixed **or hinted** high address fails; VA48 rides on the rebuild "at no extra cost"; matching modinfo/CRCs/sizes as "evidence of equivalence"; the loader "should reject" stock modules on `module_layout` | the shipped VA48 config does not establish Valve's full supported/tested matrix; current public FEX/Wine/V8 source does not establish the Steam-delivered versions' behaviour; a fixed high mapping fails outside the range, while an ordinary hint is ignored; "no new class of rebuild work" stands, "no extra cost" was too broad; matches support source/build correspondence, not identical code; the `module_layout` rejection remains to be demonstrated | FS-R-015 §7; `va-bits-k1i.md` rev 1 |
| J-192 ("The top-level change persisted until a normal `adb reboot`"; "traced_probes does not honour `instance_name` in practice"); FS-A-014 §5.8 (7 kB "for about five hours"; "no ftrace or process_stats data" [D: a string scan]) | the 7/42 kB state persisted for about 5 h and the reboot ended it; the trace holds no ftrace/process_stats data; the cause is that `instance_name` is not honoured | the 5 h persistence is conditional on no intervening writer (tracefs was not read between 02:01:27Z and 06:54Z); no post-reboot read establishes restoration; a string scan cannot establish absence of ftrace or process_stats protobuf data (the offline parse of the retained trace is owed, FS-R-014 §10); the snapshots support a tracing-isolation concern but not the exact cause, nor that the private instance was never used. 39.0 °C is the highest observed reading, not a continuously measured physical peak. a private research note §7's "the top level is never touched" is withdrawn | FS-R-014 §10 |
| `pd-mapper.md` rev 1 C-PD3/PD-M5 (FS-A-014 §5) | K5 (download_mode=0) **or** `QCOM_PANIC_ON_PDR_NOTIF_TIMEOUT=n` as interchangeable conditions; `shutdown_in_progress=1` "as the first step" of shutdown | not equivalent: K5 addresses only the dump-mode consequence and leaves the PDR panic/restart path; `=n` removes that panic path; a package picks one with its actual failure behaviour stated. `shutdown_in_progress=1` only suppresses failure handling (it shuts nothing down); battery/thermal handling must continue until actual shutdown and the suppression point must be justified. Mapper publication, PD notification and battery freshness are separate claims | FS-R-014 §9; `pd-mapper.md` rev 1.1 |
| FS-A-014 §5.3, `device-health-design.md` §2.1 (nautilus) | whether nautilus's probe powers anything is [O] | narrower, by source [M-static, `nautilus.c` in `dbc2bc83a2b6`]: probe obtains its resources and selects the default pinctrl state but does not call the explicit regulator/clock enable routine. Projector darkness was not measured and inherited hardware state is not excluded. The history stays visible: nautilus was in the earlier 95-module closure. No further K1a boot is required | FS-R-014 §8; `device-health-design.md` rev 2.2, H-1 README |
| J-197 (T0 Unit 2) | the wrong fan-table hysteresis "would raise F8 (fail-safe direction: no READY, fan at top)" | worse, still fail-safe: F8 on every tick is a standing **fan** fault (CORE-SPEC K-25, C-15/C-16, C-23): no READY, fan at the top, SEVERE caps from the first tick, and T4 latched for `fan` after 120 s, i.e. a `fan-failure` shutdown about 2 min after the service started (at once via `fan-trip2` if a 75 °C fan trip were active) (the T0 package (private)) | T0 r2 report (J-200) |
| `FS-A-006` (Valve OS facts) | "ELF `p_align` 64K, which works on the Quest's 4K pages" read as covering all Valve binaries | holds for the base OS binaries only; SteamVR's `vrcompositor` (and per the APK study `vrserver`, `steamclient.so`) has 4K-aligned LOAD segments, so the kernel **must** use 4K pages (K1a already does) | stearlight APK study (J-199); Arbiter `readelf -lW` on `~/sfroot-full/opt/steamvr/bin/linuxarm64/vrcompositor`: LOAD align 0x1000 |
| J-193, both K1a attempt logs | taint 1024 is the out-of-tree (OOT) flag from the vendor modules, "as stock" | 1024 is bit 10, TAINT_CRAP: it comes from 4 staging modules, including nautilus and blu_fw_driver; the OOT flag is bit 12 (4096). That stock shows the same taint is [D], not measured | FS-A-014 results fill, against the v2.7 source (2026-10-17) |
| J-192 | the Unit 1 worn session ran from about 01:37 to 03:40Z with a pause of "about an hour" | the raw files run to 06:54Z; the pause was about 4.6 h | FS-A-014 results fill, against the raw evidence file times (2026-10-17) |
| J-144, J-146 | stage 3d r1 (the reset) was clean: "dmesg-flags none" | the flag covers r2 only. Both PASS runs' r1 logged two kernel `WARNING … drm_atomic_helper.c:229 set_best_encoder` traces from step A (Meta's continuous-splash connector state meets a connector detach) and the planned −7 single-plane rejection; step A disables the CRTC, not the DSI encoder, and by source its stale encoder mask skips the clock/bandwidth down-vote [D, source only; the post_state core_clk/16e9 values are CRTC property defaults, not the votes]; step B commits the 2 × 2064 split on a black buffer [M]. TE stayed 0 through r1 [M] | FS-A-012 §5 review (J-148), decoded r1 records and the v2.7 kernel source |
| J-125 | the per-pipe throughput cause "is confirmed by the fix" | consistent with the fix: the plane count and the explicit zpos changed in the same step, so the fix does not isolate the rect width; underruns were never observed | FS-A-012 §5 review (J-148) |
| J-132 | the per-eye residual roll is "at most 0.2°", "so 21° holds" per unit | the static `Rotation` term is below 0.25 (derived from private per-unit values); the right eye's IPD-dependent `Rotation_Disparity` term is larger and how it applies is [O]; no per-unit correction is established | FS-A-012 §5 review (J-148) |
| J-144 | Unit 1 follow-ups: 310 "at +3 and +4 min" | the attempt log recorded only +3 min until `a654ed8` added the +4 min line (06:18:10Z, 310, steady) about 9.6 h later | FS-A-012 §5 drafting (J-148) |
| J-146 | Unit 2 run complete as logged | no follow-up reading was taken after AA (280), per J-145; the attempt log said so only after `a654ed8` | FS-A-012 §5 drafting (J-148) |
| J-96 Corrections row, J-99 scope, FS-A-011 §6.1 | with an empty helper path the forced fallback "never fires"; Quest 3 "forced power-off at 100 ms" | too absolute: allocation failure or a disabled helper can still reach `__orderly_poweroff`'s forced fallback. Use: "The successful-no-op helper path supplies no dependable forced shutdown through the generic thermal core on this configuration." Quest 3: the positive delay schedules an emergency power-off **attempt**, not a guaranteed physical power-off 100 ms later | FS-R-011 §6 (J-104) |
| FS-A-010 §6.4 | settled reading: "the second ≤ the first + 0.5 °C (not rising)" | "stable within tolerance", not literally "not rising" | FS-R-010 §6 |
| FS-A-010 §6.6 | one extra off→on transition "far outside the 3–30 Hz flicker band" (as an eye-safety basis) | no numerical eye-safety guarantee is claimed from the spacing of the transitions | FS-R-010 §4 |
| J-79, J-83, armadavr.md, FS-A-011 (sent draft) §6.1 | with an empty `STATIC_USERMODEHELPER_PATH`, every usermode-helper call fails, so `orderly_poweroff(true)` falls back to `emergency_sync(); kernel_power_off()`; a critical trip still forces a power-off | empty path = **successful no-op**: `call_usermodehelper_exec` returns 0 (`kernel/umh.c:397-423`), so `run_cmd` returns 0 and the forced fallback (`reboot.c:465`) **never fires**. The only forced path is `thermal_emergency_poweroff()` (`thermal_core.c:375-386`; unsynced `kernel_power_off()` then `emergency_restart()`), scheduled only if `CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS > 0`. **Quest 3 v66: 100 ms, so a forced (unsynced) power-off still happens. Quest 2 v2.7: 0, so a critical trip gets NO software-forced power-off via the kernel thermal core** [M-static config, near-match source; D]; vendor notify hooks and PMIC/TSENS hardware over-temperature protection not assessed [O] (scope added J-99) | FS-A-011 review sweep (J-96) |
| FS-A-010 §5.3 | "No light was seen, so no exposure occurred" | "no light seen" is not a measurement of zero emitted light, backlight power or exposure | FS-R-010 §2 |
| FS-A-010 §3 | FSB1 "244 arrived" against END lines=255 | END counts preceding lines: 243 preceding lines arrived (244 including END); the difference is 12 | FS-R-010 §1 |
| serial-loss note, FS-A-010 §3 | usbser.sys queue cap; the 4 MB request ignored | the location is [O]; neither is established | FS-R-010 §5 |
| display-bringup §1/§3, stage 3a README/IMAGE, FS-A-007 (sent) | v66 blocks backlight changes, so the BLU stays at the boot level during our test | the gate is v2.7-only. v66 reprograms the BLU at 1000/1000 (≈ 8.2 % duty) on our full-modeset commit [D, near-match source]; the sign-off's risk description was wrong for v66 (no light was seen) | `display-handoff-dark.md` §3; FS-A-010 review (J-75) |
| FS-A-010 draft | `display-handoff-dark.md` "adversarially reviewed" | not separately reviewed; spot-checked in the FS-A-010 package review | FS-A-010 review |
| attempt log (trial iii) | fs-done ack about 04:52:41; headset "powered on again" at 05:49; battery "charging at 100 %" | 04:53:05.3; standby throughout (uptime); BA status full, AA status discharging at 95 % on AC | FS-A-010 review |
| FS-A-009 §3, J-59 | "no ADSP running" | measured only: `/sys/class/remoteproc` empty and the ADSP driver link absent | FS-R-009 §5 |
| FS-A-009 §5 | the trial "held about 30 s"; the rise mostly from bootloader dwell/charging [C] | image lifetime not measured (`fs-done` queued about 35 s after launch); cause [O], not to be attributed | FS-R-009 §5 |
| FS-A-009 §4 option A | optional address must be below the loader's | contradicted by the qemu log (nine cases); removed | FS-R-009 §4 |
| J-59 | step-4 extra line: cause [C]; "absent under qemu" | the main program's map, printed nondeterministically via an uninitialised glibc flag [D]; appears under qemu with `-cpu cortex-a72` (11/15 logged) | offline root-cause analysis (J-60) |
| FS-A-007 §0, §3.7; stage3a IMAGE.md | lit-panel heat bounded by fs-pattern to ≤ 10/15 s | the client hold is 10 s (alarm 15 s); v66 panel/backlight off on close is [O]; the frame may persist until recovery | FS-R-007 §4 (J-53) |
| FS-A-007 §5, COLLECTOR.md §4 | the host stops before the device deadline because Th precedes T0 | a successful fastboot return is not a lower bound on T0; the origin must be BootStartUtc, and preparation time must not inflate the budget | FS-R-007 §3 (J-53) |
| J-44, common `DEADLINE.md` §1 | stage-1 `init.sh` aborts PID 1 if `/proc/uptime` is unreadable | ash evaluates the empty value as 0; PID 1 survives; only `fail()`/the ack window are lost, the dead-man still covers it | common-infra review (J-45) |
| FS-A-006 §5.2 | `--list` rule: the interpreter line has no `=>` | it does (`/lib/ld-linux-aarch64.so.1 => …`); only `linux-vdso.so.1` lacks it; an anchored three-line rule replaces it | T1 pinning (J-42) |
| FS-A-006 §4 | "no other BLAKE2 implementation in the image" | the kernel has `CRYPTO_BLAKE2B=y`, unreachable from userspace (`CRYPTO_USER_API_HASH`/`CRYPTO_USER` off); no userspace BLAKE2 in the image | T1 pinning (J-42) |
| FS-A-006 §5 | explicit `--library-path` invocation controls library loading | `LD_PRELOAD`/`LD_DEBUG` are still honoured; an empty environment (`env -i`) and absent `/etc/ld.so.preload` are required | T1 pinning, qemu (J-42) |
| FS-A-006 §2.3, kernel note | Quest 3 panel `sy103` (1280p) | `meta,eureka_panel_sharp`, dual-DSI DSC, 2064×2208 per eye; `sy103` is only in Qualcomm reference DTs | display research (J-41) |
| PROJECT_SETUP §3, checklist E4 | "the Quest 1's panels are believed to be 72 Hz only" | shipped at 72 Hz; panels reported 90 Hz-capable (Carmack, OC6) and a community mod enabled it (PM) | PM (J-40) |
| FS-A-006, J-31–J-36 | "ABI-equivalent for module loading" | "matches the checked symbol-version interfaces; complete module compatibility and runtime behaviour remain open" | FS-R-006 §2 |
| FS-A-006 §3B, PROJECT_SETUP §6A | "skin and battery limits are enforced only by Android userspace" | the Quest 3 DT has kernel CPU mitigation (`batt-virt-limit` 45/58 °C, `surf-virt-limit` 48 °C); only the shutdown thresholds are userspace | FS-R-006 §4; verified in v2.7 source (J-39) |
| FS-A-006, perf notes | "the Quest 3 GPU has no kernel thermal throttle" | `kgsl_pwrscale.c` registers a devfreq cooling device and a thermal max-frequency QoS path; whether a zone drives it autonomously is [O] | FS-R-006 §4; verified (J-39) |
| power-thermal note, PROJECT_SETUP, checklist | "the Quest 3 fan stops on panel blank" | the v2.7 driver caps it at `silent_rpm` (4000 RPM) on blank | FS-R-006 §4; verified (J-39) |
| FS-A-006 §2.1 | stock "ignores" the bq27 gauge | stock keeps accessing it (errors, virtual-sensor errors); coexistence does not show missing input is harmless | FS-R-006 §4 |
| perf notes (+20% table) | Quest 3 GPU 545 → 654 MHz; CPU 1.92 → 2.30 GHz | not table steps; use 640 MHz (+17.4%) and 2.208 GHz (+15%); never add steps | FS-R-006 §7 |
| FS-A-006 §5 | `timeout 20` bounds a step to 20 s | BusyBox `timeout` sends TERM only; needs KILL escalation | FS-R-006 §5C |
| gate scripts (`kgate*.sh`, `btfkinds.py`) | "the gate" | they report but do not enforce: a synthetic failure exited 0 | FS-R-006 §3 |
| FS-A-006 §2.5 | "kernel-side results transfer to the target" | a v2.7-kernel/v66-DT trial establishes that hybrid's result only | FS-R-006 §6 |
| J-35, `kgate-sibling.sh` | "if the superset changes no CRC, no subset can" | unsound: a subset is a different build and Kconfig options interact; only the configs actually gated are cleared | FS-A-006 narrow re-check (J-36) |
| FS-A-006 draft, J-36 | Quest 2 `getvar all` called "read-only" | the reboot cycle around it is a state change (`misc` probably written, not captured) | FS-A-006 narrow re-check (J-36) |
| setup docs | U-Boot at `/UBOOT/U-BOOT.IMG` | `/UBOOT/LIB/U-BOOT.IMG`; and it is a staging copy — U-Boot boots from `uboot_a/b` partitions | ESP walk, then `kernelsetup.sh` |
| J-02 | "the kernel probably lives in `efi-A`" | `efi-A` holds only partition-set files; the kernel is in `rootfs-A/boot` | reading `efi-A` |
| J-04 | several "file is empty / config missing" reads | artefacts of the `btrfs restore` bug | kernel-mount re-extraction |
| `FS-A-001` | "the image lacks a USB serial gadget, so we need our own kernel" | true of **Valve's** kernel only. Every stock **Quest 3** kernel has ACM built in | Quest 3 IKCONFIG scan |
| `FS-A-001` | tags `[I]` and a redefined `[M]` | Chair restored `[M]/[D]/[C]/[O]` and added explicit `[M-static]` | `FS-R-001` |
| J-07 | "0.5.5 is Valve's newest build" | 0.5.5 is a dev `main` build. The announced release is 0.4.4 beta; newest `stable` is 0.3.0 | Steam news + manifests + signatures |
| J-07 | "107 builds on the server" | 111 at the top level, plus `goldmaster/`, `mr/`, `oobe/` | full index walk |
| J-11 | "use slot B, the active baseline" | slot **A** is active | live probe |
| `FS-A-003` | "ramoops is the fallback evidence channel" | configured and live, but **not retained across any reboot tested** | retention tests T1/T1b/T2 (J-14) |
| `PROJECT_SETUP` §1 | "Quest 3 is SM8550-derived" | its platform is `anorak`; clock/UFS layout closer to SM8450; no mainline support | research pass (J-17) |
| `FS-A-002` | "`splctl` writes `bootenv` every boot" | a conditional route (needs `graphical.target` and `/efi/SteamOS`); successful writes are not established | FS-R-002 rev. §4A |
| `FS-A-002` | "`steamos-firmware-update` is inert" | its later fwupd path is blocked by the syntax error. What runs before it (a sourced colour-variable library) writes nothing, but "inert" overstated it | FS-R-002 rev. §5, then source check |
| J-16 | "`modules.dep` lists no dependencies for the USB modules" | it uses absolute paths, and my lookup used bare names. 52 of 97 modules have dependencies, and Android loads in dependency order | stock boot log on the device, then the sandbox test (J-18) |
| `FS-A-004` | "gate 4 would refuse the bootfw write" | it checks the *current* firmware slot; the writes go to the *other* slot. Device probing happens before the model check anyway | FS-R-002 rev. §2 |
| `PROJECT_SETUP` | "the **[C]** tag is not used" | my own bad search-and-replace; it should have read `[I]`. **[C]** is in use | FS-R-002 rev. §7 |
| `FS-A-004` rev 3 draft | "gadget identity is read back before the bind" | the readback line was mangled (`\n` literal) and failed on every healthy boot | second-round adversarial review (J-20) |
| `FS-A-004` rev 3 draft | "builder negatives show no image published" (publish-after-checks) | both negatives failed at step 1, before any publish logic | second-round host review (J-20) |
| J-31 | "a kernel rebuilt from the public tree loads the stock v2.7 vendor modules" | ABI-equivalent for loading [D]; runtime and full source identity [O] | FS-A-006 review (J-34) |
| J-31 (in progress) | "make 4.4.1 breaks this 5.10 tree" | the cause was the missing `REAL_CC` (Meta's compiler-wrapper hook); make 4.4 was not shown to be at fault | reading Meta's Makefile and `README.meta.md` |
| `PROJECT_SETUP` §1 | XR Elite SoC "XR2+ Gen 1" | XR2 (Gen 1): HTC spec; frequency tables identical to the Quest 2's | XR Elite envelope research (J-28) |
| `FS-A-004` r3, `FS-A-005` | tag **[O]** used to mean "observed" | **[O] = open**. Observed hardware output is [M]; static artifacts are [M-static] | FS-R-005 §5 |
| `FS-A-005` | "no remoteproc device registered or booted" | not measured; there was no inventory. Only "our init launched none" holds | FS-R-005 §4C |
| `FS-A-005` | "the kernel combined our ramdisk with the vendor ramdisk" | which boot-chain component assembled it is not established; [D] only that the modules were available to our PID 1 | FS-R-005 §4A |
| `FS-A-005` | the trial's `misc` change is localised to two fields | the immediate-before contents are missing, so the trial's byte changes are [O] | FS-R-005 §3 |
| `FS-A-005` draft | "USB role is peripheral without forcing" | PID 1 wrote `ssusb/mode=peripheral`; no UDC existed before that | adversarial review of FS-A-005 (J-21) |
| `FS-A-004` rev 3 §2C (N-1) | "`ag()` prevents a redirected work tree" | `-c core.worktree` does not override the repository's own config; the redirect still blinds the check | post-concurrence review (J-20); fix after the trial |
| `FS-A-004` rev 3, 2nd build | "after registration an error is logged and observation continues" | the trap's `continue` would have ended the watch loop | final adversarial pass (J-20) |
| `FS-A-004` rev 2 | "a copied image is refused" | only within this checkout: the ledger is local | second-round host review (J-20) |
| previous programme | "any bad XR Elite kernel is recoverable" | rejected as overreach | `ERRATA-001` |
