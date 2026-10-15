# Slotting in an unmodified Valve image — feasibility and architecture

*Edited for publication: names and links removed or paraphrased.*

Agent report, 2026-10-10. **Offline research only.** No device was touched,
nothing was committed, and nothing was written to the PM's archive. No binaries or
images were downloaded. Online access was limited to HTML directory listings,
one 376-byte build manifest, one 107-byte text pointer, and Valve's public
help and EULA pages.

**Local reads** (all read-only):
- the Frame recovery image `firmware/SteamOS/steamframe-oobe-repair-20260922.5153644-0.3.0.img`
  (btrfs superblock only, by byte offset; the image was not mounted or
  changed);
- the clean rootfs copy in WSL `~/sfroot-full` (the kernel-mount copy, J-06);
- FS-A-001 (private review record), `FS-A-002.md` and `FS-A-003.md`, and
  FS-A-002 (private review record);
- `docs/JOURNAL.md`, `docs/PROJECT_SETUP.md` and `devices/quest3/README.md`;
- `docs/research/valve-packages-licensing.md`, `community-quest-repos-2.md`,
  `FS-A-006-ports.md` and `FS-A-006-quest-projects.md`;
- the Quest 3 kernel configs in `firmware/quest3/extracted/*/kernel.config`.

**Tags (FS-R-001):**
- **[M-static]** read from a named file, image or listing (provenance given);
- **[D]** derived from such reads;
- **[C]** inferred, or a claim made by an external source;
- **[O]** open.

**Not legal advice.** The licensing points build on
`valve-packages-licensing.md`, which no lawyer has reviewed either.

**Chair rulings on this report (FS-R-011 §7, 2026-10-11, J-104; binding,
prospective; no device action authorised).** The report below is kept as
written on 2026-10-10, with dated notes where a ruling changes it.
- **D1 Runtime adaptation (§4.1, §5.4 Chair 1): ACCEPT the technical
  architecture.** A verified Valve rootfs adapted by a reviewed FrameShift
  runtime layer can satisfy FS-R-001 R3; rewriting Valve's rootfs bytes is
  not required. The accepted object is the **complete reviewed
  composition**: Valve input identity, trusted verity root, FrameShift
  layer, kernel/DT/initramfs, activation policy and permitted storage.
  Hiding `/boot` and masking named services are controls within it, not
  writer containment on their own. Activation is reviewed through
  dependencies, sockets, timers, generators and direct helper calls as well
  as enabled units; a package/executable diff (L6) is an alarm and review
  aid, not proof that no writer exists. **Not** a ready-to-boot package and
  **not** a legal conclusion about runtime modification.
- **D2 Kernel guard (L1; §5.4 Chair 2): RETAIN the revised deferral.** Not
  mandatory before any Valve file executes or before every narrowly
  controlled Valve-rootfs PoC; known helper paths must be addressed before
  the proposed Valve-userspace launch; an **effective write boundary** must
  be demonstrated before broad, unreviewed stock-service activation or any
  automatic update/installer operation. The L1 design is not yet a
  complete boundary (write-open denial misses mounted-filesystem writes; dm
  reconfiguration and already-open descriptors; SG_IO/UFS BSG and other
  pass-through routes; GPIO, I2C and battery-NVM writers; module/kexec
  bypass of the latch; identity and backing-range constraints for writable
  dm allowlists). A verity target needs no write exception. **Investigate
  SELinux, capabilities and device policy too** (§3.3 note).
- **D3 Shadowing and allowlist (§5.4 Chair 3–4): ACCEPT** as conservative
  policy, using actual per-file/package licences (not authorship or a
  metadata label). A directly invoked proprietary writer needs an effective
  technical prevention path; a unit mask cannot cover every invocation. Add
  the BLE programmer, the charger/NVM writer and `systemd-repart` to the
  writer inventory and activation review before Valve userspace is proposed
  for execution. Additive driver/API integration is preferred; that
  establishes no compatibility or licensing permission.
- **D4 Storage (§4.3, §5.4 Chair 5).** Dedicated **Unit 2**: scoping a
  separately reviewed installer on storage assigned to FrameShift is
  accepted (boot chain and unit-unique partitions preserved, Unit 2's own
  firmware inputs); this is not concurrence to write a partition table,
  flash a boot slot or run an installer. The proposed route for unflashed
  units was **not concurred** (§4.3 note). External USB storage and Unit 2
  storage are the alternatives to investigate. Persistent inactive-slot boot
  (S4) is a separate package.
- **D5 Flashing-package inputs (§5.4 Chair 6): ACCEPT exclusion.** Valve's
  whole-device flashing packages are rejected categorically; for an accepted recovery image, parse and verify the exact
  allowlisted rootfs range; never hand the whole image or Valve's flashing
  machinery to a Quest; the GPT is input metadata, never a target
  partition-table instruction.
- **D6 "Valve binaries":** FOSS rights follow the component's licence;
  whether licence-audited FOSS packages fall within the PM's "no Valve
  binaries" exception is a **PM decision [O]**. "Our own code only" is
  inaccurate for images containing BusyBox, a kernel or static glibc.
- **D7 Stable builds: ACCEPT the direction** (pinned, reviewed build during
  bring-up; updates afterwards with paired FrameShift/Valve versions and a
  separately reviewed updater), with an explicit exception decision still
  needed. Distinguish four things: **signature authentication** (which key
  signed it), **manifest branch** (what the signed manifest says),
  **official recovery provenance** (that it is Valve's published recovery
  image) and **public release designation** (what Valve announced as
  stable). A trusted "stable" key does not by itself establish a stable
  manifest branch. The recovery manifest says **main/OOBE**, so R1 as the
  first-install base needs an **explicit PM policy exception** for that
  exact input, separately pinned and reviewed, never relabelled stable
  [O]. Anchor the keys and the reviewed allowlist independently (a keyring
  downloaded beside an image cannot authenticate itself), and bind the
  verity digest to the trusted FrameShift policy. Excluding package-repo
  assembly and hotfix repos as inputs is a reasonable scope choice, not
  proof that every package there is a preview. The 2026-10-08 stable
  announcement stays [C] until its official article and matching signed
  manifest are supplied.
- **Licensing correction:** Valve's Frame-specific download page presents
  the backup-image EULA (§4.1 note).

---

## 0. Summary

1. **"The Valve image" exists in two official forms, and both are public.**
   - **(R) A recovery image.** Valve's public recovery directory, beside the
     Steam Deck repair images, carries
     `steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2` and `.img.zip`
     (3.8 GiB each). That is the file we already hold. The directory also
     carries a separate flashing package (never used) [M-static, listing
     2026-10-10]. The image is a raw GPT disk with a btrfs rootfs
     (§1.1).
   - **(U) Signed update bundles.** Every build is published as a signed
     RAUC bundle plus a casync chunk store. Together they reconstruct the raw
     btrfs slot image byte for byte (§1.2).
   - No Valve support page linking either form was found by this pass.
     *[Update 2026-10-11 (J-86, J-97): the PM reports that Valve's Steam Frame
     download page, `store.steampowered.com/steamos/download/?ver=steamframe`,
     offers v0.3.0 [PM report; not fetched by the Arbiter].]* The recovery
     directory listing shows no checksum file next to the recovery image
     [M-static, listing].
2. **What we use unchanged, and what must never run.** Only the **rootfs
   partition** is used, unmodified, and only **read-only**.
   - **Never used:** the kernel, the DTBs, `/boot` (U-Boot,
     `bootfw.tar.xz`, `kernelsetup.sh`), the initramfs and the ESP/efi
     partitions.
   - **Must never run:** the update and boot-registration chain (RAUC,
     atomupd, `steamos-bootconf`/`splctl`, `setubootenv`, systemd-repart).
   - **Also must never run.** This pass found three device writers new to the
     inventory, beyond the boot chain [M-static]:
     - `steamvr-program-ble.service` bit-bangs SWD over `gpiochip9` with
       openocd and runs `nrf52_recover`, a mass erase;
     - `deckard-charger` writes battery-pack NVM registers;
     - `vrconfig_write` writes `/persist`.
   - **Do not run on a Quest:** the Frame hardware daemons (fan, FPGA, LED,
     DSP, audio setup and so on).
   - **Expected to run unmodified [C]:** the Steam client and SteamVR's
     generic parts. That rests on community evidence, not yet on ours.
3. **Recommended architecture: "Valve rootfs as a read-only lower layer"**
   (option B, §3). The layers, bottom to top:
   - our kernel and initramfs;
   - the unmodified image, behind dm-verity;
   - a read-only overlay root, with our layer on top. It hides `/boot`, adds
     our drivers and units, and masks the dangerous units;
   - Valve's own `/etc`-overlay pattern, with the persistent upper on our
     `/var`.

   The real boundary is **in components we own**:
   *(FS-R-011 §7 D1/D2: these are controls within the reviewed composition;
   the guard is deferred and not yet a complete boundary; see the rulings
   above.)*
   - a kernel block-write guard;
   - never exposing Frame-named partitions;
   - an ingest **allowlist/diff gate**: an image whose build we have not
     reviewed does not boot.

   Updates come from Valve's signed stable bundles, verified against
   `stable_keyring.pem` and installed by **our** installer, never by RAUC.
   *(FS-R-011 §7 D7: pinned build during bring-up; updates later via a
   separately reviewed updater; keys anchored independently.)*
4. **Biggest unknowns:**
   - Does the SSA/EULA wording ("modify", "derivative works", "tamper")
     reach runtime layering and masking?
   - Does the OOBE build insist on updating itself through atomupd?
   - Where does a 10 GiB image live on an encrypted Quest 3 `userdata`?
   - Does the Steam client make hardware-identity assumptions?
5. **The first prototypes are all offline:** an ingest tool, the inventory
   and diff gate, a layer builder, a static analysis with
   `systemctl --root`, and later a QEMU boot with Quest-named decoy
   partitions. Decisions for the PM and the Chair are in §5.4.

---

## 1. What "the Valve image" is

### 1.1 The recovery image (form R)

**Where it lives** [M-static, listing of `https://steamdeck-images.steamos.cloud/recovery/`, 2026-10-10]. The directory holds 22 files: the Deck
recovery, repair and oobe-repair images, and the Frame entries (the two
recovery-image entries below, and a separate flashing package that is never
used):

| file | size | date |
|---|---|---|
| `steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2` | 3.8 GiB | 2026-09-22 |
| `steamframe-oobe-repair-20260922.5153644-0.3.0.img.zip` | 3.8 GiB | 2026-09-22 |

- **Our copy is this file.** The `.bz2` we hold has the size listed, and its
  SHA-256 is `3a4a077f…a97106676` (FS-A-001 §10) [M-static]. The listing
  carries no checksums, so Valve publishes no hash for comparison
  [M-static].
- **Only one Frame recovery build exists so far** (0.3.0, 2026-09-22)
  [M-static]. On the Deck, Valve refreshes recovery images only a few times
  a year (dates in the same listing) [M-static].
- **The separate flashing package** [contents not read]. **It must never be
  used with a Quest, and our installer must refuse it** (§2.1).
- **No linking page found by this pass.** No Valve support page linking the
  Frame recovery files was found here. *[Update (J-86, J-97): the PM reports
  that `store.steampowered.com/steamos/download/?ver=steamframe` offers
  v0.3.0 [PM report]; whether it carries terms or a checksum is [O].]* The Steam Frame help wizard lists only
  "Getting Started" and a "Feature and Troubleshooting Guide", and the body
  of that guide did not render for the fetch tool. The Deck download page
  (`store.steampowered.com/steamos/download/?ver=steamdeck`) offers only the
  Deck image, under the "SteamOS and Steam Client Back-Up Image" EULA
  [M-static].

**What is inside** [M-static, FS-A-001 §1, re-checked here]:

| # | label | size | content |
|---|---|---|---|
| 0 | `esp` | 256 MiB | FAT32; holds a staging copy of U-Boot and `adsp_lite_sm8650.mbn` |
| 1 | `efi-A` | 64 MiB | FAT32 |
| 2 | `rootfs-A` | 5120 MiB | **btrfs**, label `rootfs-A`, starting at byte 335,561,728 |
| 3 | `var-A` | 256 MiB | ext4 (DPS `/var`) |
| 4 | `home` | 100 MiB | ext4 (DPS `/home`) |

- **The btrfs superblock**, read here [M-static, offset 335,561,728 +
  64 KiB]:
  - sector and node size 4096; crc32c checksums; `total_bytes` 5,368,709,120;
  - incompat flags `0x355`: `MIXED_BACKREF`, `MIXED_GROUPS`,
    `COMPRESS_ZSTD`, `EXTENDED_IREF`, `SKINNY_METADATA`, `NO_HOLES`;
  - compat_ro `FREE_SPACE_TREE` and `FREE_SPACE_TREE_VALID`;
  - **no** `BLOCK_GROUP_TREE`, `EXTENT_TREE_V2`, `RAID_STRIPE_TREE` or
    `SIMPLE_QUOTA`.

  **[D]** A 5.10 btrfs driver supports every flag present. zstd arrived in
  4.14 and the free-space tree in 4.5. Our v2.7 kernel gate already allows
  `BTRFS=m` (`devices/quest3/README.md`). Re-check this for **every** ingested
  image, because a RAUC slot image may be built differently (§1.2).
- **The kernel, DTBs and boot firmware live *inside* the rootfs**, under
  `/boot`:
  - `Image-6.18.0-gfbdbca41fd45` and `initrd.uImage`;
  - `bootfw.tar.xz` (14 Qualcomm images);
  - `uboot_*.img` and `uboot.env`;
  - `kernelsetup.sh`.

  [M-static, FS-A-001 §2–3.] **Hiding `/boot` is therefore a rootfs-level
  job** (§3).
- **The build identity is split** [M-static]:
  - `/usr/lib/os-release` (package `filesystem`) says
    `BUILD_ID=20260922.6152327`;
  - `/etc/os-release` (no owning package, written 7 minutes later) says
    `BUILD_ID=20260922.5152327`.

  `5152327` is an **OOBE-channel** build: `vr/oobe/20260922.5152327/`
  exists, and its manifest reads branch `main`, version 0.3.0, SteamVR
  2.17.10, `"skip": true` [M-static]. **[C]** The recovery image is the
  build-`6152327` OS, stamped as an OOBE build at image time. It is not a
  plain stable or rc slot image. *(FS-R-011 §7 D7, J-104: because this
  manifest says main/OOBE, the recovery image does not meet a literal
  "manifest branch must equal stable" rule; using it as the first-install
  base needs an explicit PM policy exception [O].)*
- **`latest-oobe-test-image.txt`** on the update server points at a
  `goldmaster/20260810.5091707` bundle [C; read through a summarising fetch
  tool].

### 1.2 Signed update bundles plus chunk store (form U)

The server is `https://steamdeck-images.steamos.cloud/vr/`. Its listing on
2026-10-10 shows [M-static]:
- 129 build directories, up to `20261009.6183636`;
- the subdirectories `oobe/`, `goldmaster/`, `mr/`, `staging/` and
  `chunks.castr/`;
- the keyrings `stable_keyring.pem` and `insecure_keyring.pem`.

The bundle and its trust chain:
- **Bundle contents.** Each `deckard-<build>-<ver>.raucb` holds `UUID`,
  `manifest.raucm` and `rootfs.img.caibx`, and **no hook scripts**
  (FS-A-003 §5a) [M-static].
- **Installed by RAUC as a raw image.** `/etc/rauc/system.conf` has
  `type=raw` slots, `use-desync=true`, keyring `/etc/rauc/trusted_keys/`
  and `compatible=steamos-aarch64` [M-static]. The rootfs slot image is
  therefore exactly what `desync extract` rebuilds from the index and the
  chunk store. Every chunk is checked against the digest recorded in the
  signed index [D, from casync's design].
- **Size.** A full rebuild is about 3.7 GiB of chunks for a slot image of
  about 10 GiB (FS-A-003 §5a). That is twice the 5 GiB `rootfs-A` of the
  recovery image. **[O]** Whether the recovery `rootfs-A` equals any
  published slot image byte for byte.
- **Signing.** Only builds on the `stable` branch are signed with the key a
  default install trusts. Dev branches use `CN=steamos-dev-images`
  (FS-A-003 §5a) [M-static]. The stable keyring's certificate is public. It
  is a public key, not a credential [D]. *(FS-R-011 §7 D7: a trusted
  "stable" signing key does not by itself establish a stable manifest
  branch; check both, and anchor the keyring independently of the
  download.)*
- **A caution on the URL.** Valve's own `rauc.service` override filters log
  lines matching `_DO_NOT_SHARE_URL` [M-static,
  `rauc.service.d/override.conf`]. `atomupd`'s `client.conf` embeds service
  credentials (FS-A-003 §5a; not reproduced). **[O]** Whether Valve regards
  the unauthenticated `vr/` path as intended for third parties. It must not
  be settled by reading or using the credentials.

### 1.3 Legal ways for a user to obtain it, unmodified

| route | what the user gets | integrity | standing |
|---|---|---|---|
| **R1. The user downloads the recovery image** from Valve's public `/recovery/` directory | the 0.3.0 OOBE disk image | no Valve hash; we pin hashes we have observed | **the clearest "public download"**: the same directory serves the Deck images Valve links officially [C]. EULA terms apply to the user [C] |
| **U1. The user's own machine fetches the signed stable bundle plus chunks** from `vr/` (our installer drives `desync`) | any stable build, byte-exact | **cryptographic**: CMS signature against `stable_keyring.pem`, plus chunk digests | publicly reachable, but intent unknown (§1.2) [O] |
| U2. Image taken from the user's own Steam Frame | whatever that Frame runs | the user copies it themselves | legal for the owner [C]. Few users have both devices. Never ask for it |
| P. Assembled from Valve's public package repos (QK2 style) | a pacman-built rootfs, **not "the image"** | `SigLevel = Optional` upstream; needs our own pinning | see `valve-packages-licensing.md` §5. Mixes branches and is not stable-signed |
| D. Ask Valve | permission, or an official download | — | free; run it in parallel (licensing §5.1 item 3) |

**Recommendation [D]:**
- **U1 as the main route.** It gives a signed chain and every stable
  release.
- **R1 accepted for first install**, but only when the file's SHA-256 is in
  our signed allowlist.
- **Never P** for "the image".
- **Do D in parallel.**

**What every route needs:**
- the user accepts Valve's terms themselves;
- FrameShift hosts no Valve bytes;
- no credential or `DO_NOT_SHARE` value is ever used.

---

## 2. What is used unmodified, and what must never run

### 2.1 Never used, or never present in the running system

| component | why | how it stays out |
|---|---|---|
| Valve kernel `6.18.0-gfbdbca41fd45`, DTBs, `/usr/lib/modules/6.18*` | SM8650 kernel. The Quest 3 is `anorak` with no mainline support (Do-not 14). Our kernel is the Meta v2.7 tree [M-static] | we boot our kernel. Its modules come from our layer |
| `/boot/kernelsetup.sh`, `bootfw.tar.xz`, `uboot_*.img`, `uboot.env` (package `deckard-uboot`) | writes the Qualcomm boot chain and edits the GPT of `/dev/sdb` (Do-not 1; FS-A-001 §5) | our root layer makes `/boot` an **opaque directory**, so these files are absent from the running namespace. Plus the kernel guard (§3.3) |
| Valve's `initrd.uImage` and mkinitcpio hooks (`blockdev_ro`, `partsets`, `factory_reset`, `etc_overlay`, `deckard_fw`) | `factory_reset` writes `ubootenv_*` and runs mkfs (FS-A-002 §2.1) | our own initramfs. Valve's hooks are never run |
| ESP, `efi-A`, `var-A`, `home` partitions of the recovery image | the ESP holds SM8650 DSP firmware and a U-Boot staging copy. `efi-A` holds `SteamOS/partsets`, and its presence arms `steamos-boot.service` (`ConditionPathExists=/efi/SteamOS`) [M-static] | the installer extracts **only the `rootfs-A` byte range**; the rest is discarded. Whether `var-A` holds anything the OOBE build needs is **[O]** (Phase 0) |
| Valve's whole-device flashing packages | flashing of the Frame boot chain [C] | the installer refuses any input that is not a GPT disk image with the expected layout |

### 2.2 Present but must never run (mask, and back it with the kernel guard)

The owning packages and licences come from the image's pacman database
(`usr/lib/holo/pacmandb/local`) [M-static]:

| unit or entry point | package (licence) | action | enabled where |
|---|---|---|---|
| `rauc.service` (D-Bus `de.pengutronix.rauc`), `rauc-override.sh`, `post-install.sh`, `bootloader-custom-backend.sh` | `rauc` (LGPL-2.1+), `steamos-customizations-deckard` (LGPLv2+) | RAUC install → finalize → `kernelsetup.sh` | D-Bus or Steam activated |
| `atomupd.service` (D-Bus `com.steampowered.Atomupd1`) | `atomupd-daemon` (MIT) | fetches updates and drives RAUC | D-Bus activated |
| `steamos-boot.service` → `steamos-bootconf` → `splctl` | `steamos-efi` (GPL2), `deckard-uboot-splctl` (GPL-2.0+) | writes the `bootenv` partition | `/etc/.../graphical.target.wants` |
| `setubootenv.service` | `deckard-hw-support` (**Proprietary**) | points `fw_setenv` at `ubootenv_<slot>` | `/etc/.../multi-user.target.wants` |
| `holo-post-update-shutdown.service`, `steamos-post-update.service` | steamos-customizations | finalize without boot install; cache cleanup | `/usr/lib/.../shutdown.target.wants`, `local-fs.target.wants` |
| **`systemd-repart.service`**, with `/usr/lib/repart.d/90-home.conf` (`Type=home`) | systemd (LGPL-2.1+) | **can add a `home` partition to the disk backing `/`**: a GPT write on the Quest's LUN 0 [D] | **`/usr/lib/.../sysinit.target.wants` and `initrd-root-fs.target.wants`**, i.e. on by default |
| `systemd-boot-update`, `systemd-bless-boot`, `systemd-sysupdate*`, `systemd-pcrlock-*` | systemd | ESP and boot-loader writes; no transfer files in the image | preset only, or inert |
| **`steamvr-program-ble.service`** → `program_ble.sh` → `openocd` (`adapter driver linuxgpiod`, SWD on `gpiochip9` lines 50/51, srst 164, then `nrf52_recover; program …`) | SteamVR resources (SSA) | **toggles GPIO lines and mass-erases and flashes an nRF52.** On a Quest, `gpiochip9` lines are unrelated hardware [D] | `/etc/.../multi-user.target.wants` |
| **`deckard-charger.service`** → `update_pack_nvm.py` | `deckard-charger` (**Proprietary**) | writes MAX1720x battery-pack NVM registers (limited write cycles). Gated on the Frame EEPROM strap and `max1720x_bat_*` sysfs [M-static] | `/etc/.../basic.target.wants` |
| `vrconfig_write` | deckard (Proprietary) | `blockdev --setrw` and a git commit into `/persist` | callers [O] |
| `steamos-firmware-update` | steamos-customizations | fwupd; **does not parse** in 0.3.0 (Do-not 15) | Steam client |

### 2.3 Frame-hardware services (mask; replace with our own where needed)

All of these are enabled on the Frame [M-static, `/etc/systemd/system/*.wants`]:
- `deckard-fan-control` (MIT);
- `deckard-fpga`, `deckard-fpga-resume`, `deckard-led-control`,
  `deckard-typec-logger`, `deckard-power-monitor`,
  `deckard-boot-images` (predistort);
- `deckard-audio-setup`;
- `dsp_service` (`ConditionPathExists=/dev/adsp`, which loads SM8650 DSP
  images);
- `iris-driver-rebind`, `steamvr-v4l2loopback`,
  `steamvr-set-kernel-thread-priorities`;
- `softapmanager`, `gpu-trace`;
- the `usb-gadget.target` group (adbd).

**[D] Each one is either inert on a Quest or actively wrong.**
- **Fan:** PROJECT_SETUP §6A already rules out Valve's fan control.
- **Battery:** the Quest's battery is on the ADSP over pmic_glink
  (FS-A-006).
- **Display:** the Frame display needs the FPGA over `spidev`.

**Where Valve's Steam UI expects a runtime interface, our daemons provide
it.** For example, `vrdevice_path battery_capacity` reads
`/run/deckardcharger/battery_percent` [M-static]. **[C]** Whether Steam
actually reads it is open.

**Telemetry and privacy (PM choice).** `steamos-log-submitter` and
`steamos-dump-info` are Valve diagnostics. Recommendation: mask them by
default [D].

### 2.4 Expected to run unmodified

- **Base OS:** systemd 257.7, NetworkManager, PipeWire/WirePlumber,
  gamescope, steamos-manager, FEX, Mesa userspace (§3.5) [M-static versions;
  FS-A-006-userspace].
- **The Steam client.** It ships as `deckard-steam-rel` (SSA) and
  self-updates into `/home`. This is Valve's **app** update channel. It
  writes only the user's home, and it is **not** the OS updater the safety
  rules forbid [D].
- **SteamVR's generic runtime:** vrserver, vrcompositor, vrclient,
  vrwebhelper, in `/opt/steamvr` (`deckard-steamvr-rel`, SSA) [M-static].
  **[C]** Community evidence says these run on non-Frame Quests: Q1 runs
  SteamVR 2.17 at about 40 fps with its own driver, and QK2 shows the Steam
  UI on a Quest 2.
- **Not usable:** `driver_cv`, `XRService` and the DSP images (SM8650-signed,
  Frame cameras), and the `frame_hmd`/`deckard` resource drivers. On the
  Frame the HMD path runs through `cv` and the FPGA [M-static, FS-A-001 §6;
  C for the role].

---

## 3. Architecture options that keep the Valve rootfs byte-unmodified

### 3.1 The common base for every option

1. **Our kernel** (Meta v2.7 plus the gate-passed options) and **our
   initramfs**. A DT `model` string that matches none of `POC-F POC-E EV1
   EV2 EV3 DV1 DV2 MP mte` (R1).
2. **No `rauc.slot=` on our command line** [D]. That closes
   `kernelsetup.sh` gate 1 and leaves RAUC unable to name a booted slot.
   FS-A-001 §5.3 assumed `rauc.slot` was needed "for updates to work". It is
   not, because Valve's updater is never used.
3. **The Valve image file holds byte-identical content.** It is opened
   **read-only** behind **dm-verity**. The hash tree is computed by our
   installer *after* verifying the image, and is stored separately; the
   image itself is untouched.
   - The Quest 3 v2.7 kernel already has `DM_VERITY=y`, `BLK_DEV_DM=y`,
     `BLK_DEV_LOOP=y` and `OVERLAY_FS=y` [M-static, `kernel.config`].
   - **[D]** This both proves "unmodified" at every boot and stops btrfs from
     writing (mount with `ro,nologreplay`).
   - This mirrors Valve's own design: `steamos-verity` keeps a separate
     verity device and root hash [M-static].
4. **No Frame partition names anywhere** (Do-not 13). No `efi`, `esp`,
   `partsets` or `bootenv`. Our `var` and `home` are our own block devices
   (§4.3).

### 3.2 The options

**(A) systemd-sysext and confext.**
- **How it works.** Our additions ship as extension images: sysext for
  `/usr` and `/opt`, confext for `/etc`. Valve's systemd merges them.
- **What the image provides** [M-static]:
  - it ships `systemd-sysext.service`, `systemd-confext.service` and
    `systemd-sysext.socket`;
  - the preset says `enable systemd-sysext.service`, but it is **not enabled
    in `/etc`**, and there is no `extensions` directory.
- **Pros:**
  - a standard, discoverable mechanism (`systemd-sysext status`);
  - it works with an `ID=_any` extension-release, or one matching
    `ID=steamos`.
- **Cons:**
  - the merge happens after `local-fs`, i.e. **after udev coldplug and
    after `sysinit.target.wants`**. Our modules, firmware paths, udev rules
    and early masks would arrive too late, and `systemd-repart` runs first
    [D];
  - masks need confext, and confext cannot override Valve's `/etc` entries
    early enough either [D];
  - safety depends on Valve's systemd behaving.
- **Verdict:** a good **packaging format** for our layers. Not sufficient as
  the activation mechanism.

**(B) An initramfs-built overlay root (recommended).**
- **How it works.** Our initramfs:
  1. opens the verity device and mounts btrfs read-only at
     `/run/fs/valve`;
  2. builds `/` as a **read-only overlay**:
     `lowerdir=/run/fs/layers/quest:/run/fs/valve`, with no upper;
  3. mounts our `var`, then Valve's own `/etc` overlay pattern: lower = the
     composed `/etc`, upper = `/var/lib/overlays/etc/upper`. This copies
     `etc_overlay`'s logic [M-static];
  4. mounts `/home`;
  5. switches root to Valve's systemd.
- **What our layer (`quest`) contains:**
  - **opaque `/boot`.** The Frame kernel, boot firmware and
    `kernelsetup.sh` simply do not exist;
  - **whiteouts** for FOSS writer entry points that need not exist, such as
    `/usr/lib/rauc/*.sh` and `/etc/rauc`;
  - **masks** in `/etc/systemd/system` (§2.2, §2.3);
  - our fstab;
  - `/usr/lib/modules/<our kver>`;
  - our udev rules, units, daemons, SteamVR driver, Monado and Vulkan ICD
    JSON;
  - `/etc/machine-id` handling.
- **Pros:**
  - every adaptation is in place **before PID 1 starts**;
  - it works whatever Valve's units do;
  - updates are a file swap;
  - Valve's image stays byte-exact (verity).
- **Cons:**
  - the closest of all options to "modification" in a lay reading (§4.1);
  - masks are a **denylist** at runtime. That is why the ingest gate (§3.4)
    must turn this into an allowlist.

**(C) A container or chroot.**
- **How it works.** Our minimal host (busybox or Alpine-style, as in QK2)
  owns PID 1, `/dev`, power and thermal. Valve's userspace runs either:
  - **(C1)** as a plain chroot without systemd, as QK2 does: Steam is started
    by our scripts; or
  - **(C2)** as an `nspawn`-style system container with Valve's systemd as
    the container's PID 1.
- **Pros:**
  - the **strongest isolation**. The container never sees `/dev/sd*`, so the
    boot chain is unreachable even to root inside, given no `CAP_MKNOD` and
    a device cgroup;
  - our safety supervisor lives outside Valve's world;
  - C1 is QK2-proven on a Quest 2 [C].
- **Cons:**
  - C1 loses Valve's whole session and service model: steamos-manager,
    NetworkManager, the gamescope session, suspend. That is the opposite of
    "everything comes up and runs as intended";
  - C2: in a container udev does not run. `/sys` is read-only, so udevd's
    condition fails. Input hotplug, DRM master, logind seats, suspend and
    poweroff all need host-side brokering;
  - many Valve units carry container conditions;
  - **highest integration and maintenance cost** [D].
- **Verdict:** **keep it as the fallback.** It is also the earliest
  Stage-2 smoke test, if Valve's systemd will not boot as PID 1 on our
  kernel.

**(D) Bind mounts and namespace tricks.**
- **Variants:**
  - a curated non-devtmpfs `/dev` without the boot LUN nodes;
  - bind-mounting `/dev/null` or our fail-closed stub over FOSS writers
    (`splctl`, `steamos-bootconf`, `rauc`, `steamos-finalize-install`);
  - separate mount namespaces for selected services.
- **Assessment:**
  - useful as **defence in depth**;
  - **not a boundary**: root can `mknod` any block device by major:minor,
    and Valve's own code already defeats `blockdev --setro`
    (FS-A-002 §2.2 item 3);
  - a curated `/dev` also breaks hotplug unless we re-implement node
    creation.
- **Verdict:** use the stubs inside (B), because the stubs log attempts for
  the gate. Do not rely on (D) alone.

**Baseline for contrast: repack or patch the image** (the prior art: basit,
reverie, Q1).
- **basit and MaSi:** loop-mount, `rsync` to ext4, restore setuid bits,
  truncate machine-id, apply masks into the image.
- **reverie:** flips the btrfs `ro` property and edits fstab.
- **Q1:** Holo Core preview plus the Frame's `steam.tar.zst` and
  `/opt/steamvr` in an ext4 image.

All of them create a **modified derivative**, and none can show it is
byte-identical to Valve's.

### 3.3 Neutralising the dangerous services without modifying the image

Layered, outermost first. **Only L1 is a boundary; the rest are
defence-in-depth or detection.**

*FS-R-011 §7 D2 (J-104): L1 as designed is **not yet a complete boundary**
(gaps listed in the rulings at the top), and its timing is deferred: it is
needed before broad stock-service activation or automatic update/installer
operation, not before every controlled PoC. The SELinux dismissal in the L1
row is withdrawn as a conclusion: the lack of stock Arch udev relabelling
does not prove SELinux unusable, since our initramfs can establish labels
and policy before handoff; SELinux, capabilities and device policy are to be
investigated alongside the source patch. L4 masks and L5 stubs do not stop
a directly invoked proprietary writer (D3).*

| layer | mechanism | defeats | owned by us across Valve updates? |
|---|---|---|---|
| **L1. Kernel block-write guard** ("fs-blkguard") | a small in-tree patch, or LSM. It denies write opens, discard, `BLKPG` and clearing `BLKROSET` on every block device **except** an allowlist set by our initramfs (our verity, var and home dm devices). It is a one-way latch, armed before `switch_root` | `kernelsetup.sh` (GPT and boot-chain writes), `splctl`/`bootenv`, `factory_reset`, `systemd-repart`, `vrconfig_write`, any future writer — **even as root** | yes: the kernel is ours. **Needs a design and a tools/kgate check.** `BPF_LSM` is off in v2.7 [M-static], so it is a source patch. SELinux (`=y`) cannot label boot-LUN nodes, because Arch's udev does not relabel, so it is not a practical fit [C] |
| L2. Never expose Frame layout | no `efi`/`esp`/`partsets`/`bootenv`/`uboot*`. Valve's `/boot` hidden by an opaque dir. No `rauc.slot=` | `steamos-boot` (condition false), `kernelsetup.sh` gates 1 and 4, `fstab` by-partsets mounts (`nofail`) | yes |
| L3. Kernel command line | `systemd.mask=` for each unit in §2.2 and §2.3. `fstab=no`, with our own mount units (also blocks `PARTLABEL=syspersist` → `/persist`) | unit activation, whatever `/etc` says. **[C]** `systemd-debug-generator` writes into `generator.early`, which outranks `/etc`; verify in the VM | yes (boot image) |
| L4. Masks in our layer | `/etc/systemd/system/<unit>` → `/dev/null`, including D-Bus-activated `rauc` and `atomupd`. Masks are the **documented** admin mechanism; they edit no Valve file | the same set, plus D-Bus activation | yes (layer is per build) |
| L5. Fail-closed stubs, FOSS files only | our `fs-refuse` bound over `splctl`, `steamos-bootconf`, `rauc`, `steamos-finalize-install` and `steamos-firmware-update`. It logs its argv to our journal namespace and exits 1 | manual or unexpected invocation; **detection** | yes |
| L6. Ingest gate (§3.4) | a new image boots only if its writer inventory and enabled-unit set match a reviewed policy | **unknown future writers** | yes |

**Licence note for L5 [M-static]:** every file we would shadow is FOSS
*(per pacman licence labels; FS-R-011 §7 D3 requires the actual
per-file/package licence to be checked, not the label alone)*:
- `steamos-customizations` LGPLv2+;
- `rauc` LGPL-2.1+;
- `steamos-efi` GPL2;
- `splctl` GPL-2.0+;
- `atomupd` MIT.

**Proprietary or SSA files** (`deckard-hw-support`, `deckard-charger`,
Steam, SteamVR) are **never shadowed or whited out, only masked at unit
level** [D].

### 3.4 Updates: "the user slots in a new Valve image"

1. **Acquire** (§1.3): either U1, which fetches the signed stable bundle and
   rebuilds `rootfs.img` with `desync`, or R1, a file the user supplies.
2. **Verify:**
   - U1: CMS signature against `stable_keyring.pem`, plus the manifest
     `branch == stable`, plus chunk digests;
   - R1: SHA-256 in our **signed allowlist** *(FS-R-011 §7 D7: R1's
     manifest says main/OOBE, so R1 needs an explicit PM exception; it
     never passes a "branch == stable" check)*;
   - both: GPT and partition checks, and the btrfs feature set ⊆ what our
     kernel supports.
3. **Inventory and diff gate:**
   - mount read-only in the installer's sandbox;
   - list the enabled-unit closure (`/etc` and `/usr` wants, presets,
     D-Bus activation files);
   - scan for writers. Patterns: FS-A-002 §2 plus `openocd`,
     `linuxgpiod`, `nvmem`, `register_store`, `spidev`, `/dev/gpiochip`,
     `i2c-dev`, `fw_setenv`, `sgdisk`, `dd of=`, `blockdev --setrw`, mkfs,
     `efibootmgr`, repart configs;
   - compare with the **policy for that build**, a small JSON file signed by
     FrameShift that holds the image hash, the mask list and the layer
     version.
   - **Unknown build or any delta → do not boot it.** Report "not yet
     reviewed" and stay on the current image.

   This turns the runtime denylist into an ingest-time allowlist. It is
   R3's "diff gate" from FS-A-002 §3, kept. *(FS-R-011 §7 D1: the diff is an
   alarm and review aid, not proof that no writer exists; activation review
   covers dependencies, sockets, timers, generators and direct helper calls
   too.)*
4. **Install:**
   - write to the **inactive** image slot (our own A/B of image files);
   - compute the verity tree;
   - flip our boot pointer;
   - keep the previous slot for fallback, with a boot counter in our
     initramfs.

   **RAUC, atomupd and `post-install.sh` never run.**
5. **Inside SteamOS:**
   - Steam's "check for updates" calls `steamos-update` (LGPLv2+). Our layer
     provides a `steamos-update` and `steamos-select-branch` that talk to our
     updater. basit stubs these to stop atomupd hanging Steam
     (FS-A-006-ports) [M-static];
   - only `stable` is offered (J-07).

### 3.5 Where the Quest-specific pieces plug in (all our own packages and layers)

| need | our component | interface into the Valve world |
|---|---|---|
| Display | our kernel's DRM driver (Meta `msm_drm` techpack) and panels | KMS for gamescope, and `VK_KHR_display` for vrcompositor's direct mode. **Avoid** Q1's fake-display Vulkan layer injected into vrcompositor (§4.1) |
| GPU | our Mesa (Turnip on KGSL, as QK2 and Yusuf did) | an **additive** Vulkan ICD JSON in our layer. Never shadow `deckard-mesa-*` ("custom" licence) |
| HMD, tracking and controllers | Monado with our Quest driver (BSL-1.0 base from QK2), or our own OpenVR HMD driver | SteamVR's **published OpenVR driver API**, the sanctioned third-party extension point, registered with `vrpathreg adddriver` or `openvrpaths` external drivers. No SteamVR file touched |
| Audio | ALSA UCM and WirePlumber configs for the Quest codec | additive files in `/usr/share/alsa/ucm2` and `/etc/wireplumber` (our layer) |
| Thermal, fan, battery, emergency shutdown | our safety supervisor (PROJECT_SETUP §6A; `thermal-control-design.md`) | started **by our initramfs** with `argv[0]` starting `@`. systemd's documented "root storage daemon" convention spares it at shutdown [C, systemd.io]. So it runs whatever Valve's unit graph does. Kernel thermal trips stay as the last resort (J-79). Also exposes `power_supply`/UPower and the `/run/deckardcharger` interface if Steam needs it [O] |
| Quest subsystem firmware (ADSP, GPU zap and so on) | read **from the user's own Quest partitions**, read-only, through `firmware_class.path` (Q1 pattern) | never shipped: the "have vs ship" rule (PROJECT_SETUP §5) |
| Kernel modules | ours | `/usr/lib/modules/<our kver>` in our layer |
| steamos-manager platform data | our config | `/etc` layer. Whether steamos-manager has a per-platform config hook is **[O]** |

### 3.6 Options scored [D]

Scale: ++ best, + good, 0 neutral, − weak, −− poor.

| option | legal cleanliness | robustness | update story | UX polish | safety (boot chain) | maintenance |
|---|---|---|---|---|---|---|
| A. sysext and confext only | ++ | − (late merge) | ++ | + | − alone | + |
| **B. initramfs overlay root + L1–L6** | **+** | **++** | **++** | **++** | **++** (with L1) | **+** |
| C1. chroot (QK2) | ++ | + | + | −− | ++ | − |
| C2. system container | ++ | 0 | + | 0 | ++ | −− |
| D. bind and namespace tricks only | + | − | + | + | − (not a boundary) | − |
| Repack or patch (prior art) | −− (derivative; usually redistributed) | + | − (rebuild per release) | + | depends | − |

### 3.7 Prior projects, and where they fall short

| project | how it gets "the image" | dangerous services | shortfall against our goal |
|---|---|---|---|
| hashtagbasit/SteamOS-ARM-Port | `.raucb` + casync → btrfs → **rsync to ext4** (`make-steamos-sm8650.sh:111-147,141-145`) | masks applied **into** the image (`apply-overlays.sh:266-292`); `steamos-boot` masked for a timeout reason; **no** kernelsetup, splctl or rauc handling (FS-A-006-ports) | modified derivative; its own signed images (redistribution); safety by coincidence of architecture |
| gryoza/reverie | casync → btrfs kept, but `ro=false` and fstab edited | broad masks | modified image |
| machachu56/quest-kexec-q2 | **pacman-built** from the public repos; `SigLevel = Optional` | runs no Valve systemd (chroot) | not "the image"; mixes branches; no signature checks; loses the session |
| nicolas-riera/Quest1-SteamOS | Holo Core preview + the Frame's Steam and SteamVR; ext4 image | masks resolved and firstboot | hybrid; no licence; an injected Vulkan layer; no Valve verification |

**None of them** keeps the image byte-identical, verifies Valve's
signatures, or puts a write boundary in the kernel [D, from the cited
reads].

---

## 4. Risks and unknowns

### 4.1 Terms ("modify", "derivative works", "tamper") versus layering and masks

**The texts:**
- **Back-up image EULA §1.2(a):** may not "modify ... or create
  derivative works" [C, terms text, read 2026-10-10 on the Deck page].
  ~~It is written for the Deck image. No Frame-specific EULA was found
  [O].~~ *Corrected (FS-R-011 §7 licensing correction, J-104): Valve's
  Frame-specific download page (`…/steamos/download/?ver=steamframe`)
  currently presents this backup-image EULA. Its personal-use grant and
  redistribution restrictions do not settle the runtime-overlay question,
  and it states no Frame-only hardware restriction (none is to be
  inferred).*
- **SSA §2.G:** the "modify" wording. **SSA §4.B:** "tamper with the
  execution of Steam" (licensing §2.2) [C].

**Our position, to put to the Chair [D]:** *(Outcome, FS-R-011 §7 D1: the
architecture is accepted; that is not a legal conclusion about runtime
modification, so the [O] items below stay open.)*
1. The user's Valve image stays **byte-identical**, and dm-verity enforces
   that.
2. We **distribute** nothing of Valve's.
3. We **alter** no Valve file. We add our own files. We choose which Valve
   OS services run through systemd masks, the documented administration
   mechanism. A Frame owner in developer mode does the same.
4. The only files we hide or shadow are under FOSS licences, which grant
   the right to modify them.
5. Steam and SteamVR run **unaltered**. Our HMD driver uses Valve's public
   OpenVR driver API (the same route as Monado, ALVR and others).
6. **We inject nothing into Valve processes.** No `LD_PRELOAD` and no
   Vulkan layer into Steam or vrcompositor by default.

**Still open:**
- **[O]** Whether a runtime overlay of a whole root counts as a "derivative
  work" under the EULA.
- **[O]** How EU interoperability exceptions apply (Software Directive
  Art. 5–6). Out of scope; it needs a lawyer.
- **[O]** Valve's stance on the Frame userspace running on non-Valve
  hardware. This is a reason for option D, asking Valve.

### 4.2 Will Steam and SteamVR run on non-Frame hardware unmodified?

- **`vrdevice_path`** (Proprietary) maps the Frame's hardware: EEPROM,
  `/dev/imu`, `spidev20.0`, FPGA, cameras, MAX1720x/pm8550b battery paths
  [M-static].
  - On a Quest, `model` returns `Unknown`, and the device paths do not
    exist.
  - Its known consumers are Valve's hardware services, which we mask.
  - **[O]** Whether the Steam client or vrserver calls it (for example for
    battery or IPD).
- **Hardware identity checks:**
  - none found in the files read;
  - **[O]** for the Steam client binary: a Frame-specific UI mode, device
    registration, or the EEPROM serial through `eeprom_console`;
  - **[C]** community runs (Q1: SteamVR 2.17; QK2: Steam UI) show no hard
    lock.
- **SteamVR's HMD path on the Frame** is `cv` plus the FPGA display. We
  must supply our own HMD driver and a real KMS display path.
  - `frame_hmd` is `resourceOnly` with an empty `hmd_presence` [M-static].
  - `select_steamvr.sh` picks between `/opt/steamvr` and another
    installation [M-static]. The selection logic is not read in full [O].
- **The OOBE build.** The recovery image is an OOBE build: `"skip": true`,
  and `steamos-finish-oobe-migration` references `/home/doorstop` and
  `/home/steamvr` [M-static].
  - **[O]** Whether the first-run flow insists on an atomupd update, or on
    pairing Frame controllers, before reaching Steam. If it does, either
    U1-built stable images or our own first-run handling are needed.
  - **This is the main reason U1, not R1, is the primary route.**
- **Kernel gaps on the Steam side:** SYSVIPC and POSIX_MQUEUE are still
  excluded from the v2.7 gate because they change layouts (J-31). QK2 says
  the Steam client needs SYSVIPC [C]. This is a **kernel-track blocker**
  that is independent of the slot-in design.

### 4.3 Storage placement on the Quest 3

**What we need:**
- two image slots of about 10 GiB each (stable U1), or 5 GiB (R1);
- `var` (a few GiB);
- `home` for Steam and games, which can be large.

**The constraint.** Q3 `userdata` is ext4 with
`metadata_encryption=aes-256-xts:wrappedkey_v0` plus FBE v2. A Linux we boot
can **never** decrypt it (community-quest-repos-2 §1.2) [M-static fstab, D].

**Options:**

| option | how | pros | cons and decisions |
|---|---|---|---|
| S2. External USB storage | the image on a USB-C SSD | no internal writes at all | the single USB-C port conflicts with the PC link and charging; poor UX |
| S3. New partitions in the `sda` area | shrink or replace `userdata` (Do-not 13 permits only `sda`, never `sdb`/`sdc`/`sde`) | clean block devices; fastest | destroys Android userdata; a GPT write on the LUN that also holds `persist`; needs a Chair ruling |
| S4. Persistent boot | flash our boot image to the inactive slot's `boot` (Unit 2's planned first flash), versus `fastboot boot` every time | untethered UX | ABL slot retry and success marking without Android's boot-control HAL **[O]**; the "Switch Boot Slot" warning (devices/quest3) |

**Recommendation [D]:** *(superseded in part by FS-R-011 §7 D4, J-104;
see the note below)*
- **S3 as an opt-in "dedicated headset" mode later.**
- **S4 is a separate Chair question**; the first prototype uses
  `fastboot boot`.

*FS-R-011 §7 D4 (J-104):*
- *The proposed route for unflashed units was **not concurred**; offline
  investigation only. [removed for publication]*
- *S2 (external USB storage) is to be investigated for the first
  full-rootfs PoC, with an explicit console/USB-role/charging arrangement.*
- *S3-like storage on dedicated **Unit 2**: scoping a separately reviewed
  installer is accepted; nothing is written by that acceptance.*
- *S4 (persistent inactive-slot boot) remains a separate package.*

### 4.4 First-boot UX

**PC installer first [D].** Fastboot is required anyway, and acquisition
and verification are easier on a PC. `desync` is cross-platform Go, and
Windows first suits the PM. The flow:
1. **Device checks:** model, v2.7, slot, battery (an unlocked headset is assumed).
2. **Valve's terms:** show links. The user accepts them; we never
   pre-accept.
3. **Image source:** "download the stable image from Valve for me" (U1) or
   "use a file I downloaded" (R1).
4. **Verify and gate.**
5. **Stage:** the staging route is open [O] (FS-R-011 §7 D4).
6. **First boot:** `fastboot boot` with our signed image.
7. **On the headset:** our splash screen, then Valve's own first-run
   screens. **The user signs into Steam themselves; FrameShift never
   handles credentials.**

**Later:** an on-device updater once Wi-Fi works.

~~**Recovery is always to Horizon OS:** the ABL is untouched, and booting is
non-persistent.~~ *Withdrawn (FS-R-011 §7 D4, J-104): a temporary boot
leaves ABL untouched, but writes to internal storage can still compromise
Android recovery. No unconditional recovery claim is made.*

### 4.5 Other risks

- **Availability.** Valve can move or close `vr/` or `/recovery/` at any
  time. Our installer must fail gracefully, and must keep the last verified
  image [D].
- **New Valve builds** can add writers or units. The L6 gate catches them,
  at the cost of a review lag per build. The UX shows "new Valve version
  pending review" [D].
- **Frame `/etc` drift.** Valve's `/etc` lower layer changes per build. Our
  persistent `/etc` upper may then hold stale copies; the same problem
  exists on a Frame after updates. Keep our upper minimal: user changes
  only. Policy masks live in the read-only per-build layer [D].
- **`MIXED_GROUPS`, `ZSTD` and so on are fine on 5.10.** A future image with
  `BLOCK_GROUP_TREE` (5.19+) or `RAID_STRIPE_TREE` would **not mount**. The
  ingest feature check refuses it [D].

---

## 5. Recommendation and phased plan

### 5.1 Recommended architecture [D]

**Option B plus L1–L6 and U1-first acquisition.** Concretely, the boot
proceeds in seven steps:

1. Our boot image: kernel, DT and initramfs.
2. The initramfs arms fs-blkguard with our allowlist.
3. It opens the image read-only through verity, after checking the policy
   for that build ID.
4. It composes the read-only overlay root (our `quest` layer over Valve).
5. It mounts `var` and the `/etc` overlay in Valve's own pattern, then
   `home`.
6. It starts the `@`-safety supervisor.
7. It hands over to Valve's systemd, with `systemd.mask=…` and `fstab=no`
   on the command line.

From there, Valve's userspace starts as designed, minus masked services,
plus ours. **Option C1 stays as the Stage-2 fallback.**
*(FS-R-011 §7 D1/D2: this composition is the accepted architecture; step 2's
guard is deferred per D2 and is not yet a complete boundary.)*

### 5.2 Phase 0: offline, now (no device; any download needs PM approval)

| # | work | output | falsifier |
|---|---|---|---|
| 0.1 | **Ingest tool v0** (Python, stdlib). Takes a recovery image; parses the GPT; checks the layout; copies the `rootfs-A` byte range; SHA-256; btrfs feature check; refuses Valve's flashing packages | `tools/ingest/` + fixtures | an image with a different layout, or a flashing package, is **accepted** |
| 0.2 | **Identity check:** is the recovery `rootfs-A` a published slot image? Needs `rootfs.img.caibx` and the manifest for builds `6152327` and `5152327`. Small metadata, **PM approval** | [M-static] yes or no | — |
| 0.3 | **Inventory and diff-gate tool** over `~/sfroot-full`: enabled-unit closure, D-Bus activation, writer scan | the policy JSON for build `20260922.6152327`; the reviewed mask list | a known writer (§2.2) missing from its output |
| 0.4 | **Layer builder:** the `quest` layer with opaque `/boot`, whiteouts and masks | a layer tarball and manifest | — |
| 0.5 | **Static boot analysis in WSL:** a read-only loop mount of a *copy* of `rootfs-A`, the overlay composed, then `systemctl --root=… list-unit-files --state=enabled` and the dependency closure from `default.target` | proof that no §2.2 or §2.3 unit is reachable | any writer unit reachable |
| 0.6 | **fs-blkguard design** plus a tools/kgate CRC check (does the patch change any vendor-required CRC?) | design note; gate result | a CRC change |
| 0.7 | **QEMU aarch64 boot.** A generic kernel with blkguard, our initramfs, and the Valve image through verity. **Decoy disks** carry Quest-like partlabels (`xbl_a`, `tz_a`, `bootenv`, `uboot_a`…) as files hashed before and after. The command line is cycled with and without masks. **Needs approval** for `qemu-system-aarch64` | evidence that nothing writes the decoys, even with the masks removed | any decoy hash changes |
| 0.8 | `var-A` and OOBE inspection (read-only mount of the image's `var-A` and `home`). Does first-run need atomupd? | [M-static] | — |

### 5.3 Later phases (each one needs the Chair and the PM's sign-off before any device use)

| phase | goal |
|---|---|
| 1 | Stage 2 headless on Unit 1 or Unit 2: `fastboot boot` our kernel. The Valve image is reached over external USB storage or Unit 2 storage (to be investigated, FS-R-011 §7 D4; Unit 2 needs its new baseline first, §8). Reach `multi-user.target` with every writer masked, observed over the existing channel |
| 2 | Display and GPU: gamescope/KMS, then vrcompositor direct mode |
| 3 | The HMD driver through the OpenVR driver API, plus Monado tracking |
| 4 | The U1 updater, with signed policies for each build and A/B image slots |
| 5 | The polished PC installer and documentation (README continuity) |

### 5.4 Decisions needed

**From the PM:**
1. **Image routes:** U1 primary, with R1 accepted only against a pinned hash
   (recommended); or R1 only; or both equal.
2. **Approval** for the small metadata downloads (0.2) and for QEMU (0.7).
3. **Installer platform order:** Windows PC first (recommended).
4. **Storage default:** S3 later as opt-in; the first route is open
   (FS-R-011 §7 D4).
5. **Telemetry:** mask `steamos-log-submitter` and `steamos-dump-info` by
   default (recommended).
6. **Whether to write to Valve** (option D), covering: the Frame userspace on
   non-Valve hardware; use of `vr/` and `/recovery/`; the
   `linux-firmware-deckard` and Frame kernel source questions.

**From the Chair:** *(all ruled in FS-R-011 §7, J-104: 1 → D1 ACCEPT; 2 →
D2 RETAIN deferral; 3–4 → D3 ACCEPT; 5 → D4 unflashed-unit route NOT CONCURRED, Unit 2
installer may be scoped, S4 separate; 6 → D5 ACCEPT. New PM decisions
D6/D7 [O]; see the rulings at the top.)*
1. **FS-R-001 R3 restated.** Proposed: "a byte-unmodified Valve rootfs,
   verified and gated, installed by FrameShift's installer and adapted at
   runtime by FrameShift layers, never by Valve's installer". Does that
   satisfy "port-controlled fetch → verify → diff → transform → install",
   with "transform" replaced by "adapt"?
2. **Is fs-blkguard (L1) a required control** before any Valve rootfs boots
   on a Quest? That revives the FS-A-002 §2.3 kernel-guard proposal.
3. **The shadowing policy:**
   - FOSS-licensed Valve and Collabora files may be whited out or stubbed;
   - proprietary and SSA files may only be masked at unit level;
   - no injection into Valve processes by default.
4. **The ingest allowlist rule:** an unreviewed Valve build never boots.
5. **The storage route for unflashed units** *[paraphrased for
   publication]*. Also whether S3 or S4 should be scoped at all.
6. **Recovery image handling:** confirm that Valve's flashing packages are
   prohibited inputs, and that only the `rootfs-A` byte range of the
   recovery image is ever used.

---

## 6. Sources

**Online (all accessed 2026-10-10):**
- `https://steamdeck-images.steamos.cloud/recovery/`: listing (the Frame
  recovery entries).
- `https://steamdeck-images.steamos.cloud/vr/`: listing (129 builds,
  keyrings, `oobe/`, `latest-oobe-test-image.txt`).
- `https://steamdeck-images.steamos.cloud/vr/oobe/` and
  `…/oobe/20260922.5152327/`: listings plus the 376 B manifest.
- `https://store.steampowered.com/steamos/download/?ver=steamdeck&l=english`:
  the Deck image EULA, §1.1–1.2.
- `https://help.steampowered.com/en/wizard/HelpWithSteamFrame` and
  `…/faqs/view/2668-0B6E-79E0-A85B`: no recovery article found (the body
  did not render).
- systemd documentation: "Storage Daemons for the Root File System"
  (systemd.io/ROOT_STORAGE_DAEMONS), the `@` argv convention [C]; the
  `systemd-debug-generator` `systemd.mask=` behaviour [C, to verify in 0.7].

**Local:**
- the recovery image, btrfs superblock;
- WSL `~/sfroot-full`:
  - enabled units in `/etc/systemd/system/*.wants` and
    `/usr/lib/systemd/system/*.wants`;
  - presets and `repart.d`;
  - the unit files cited;
  - `update_pack_nvm.py`, `program_ble.sh` and `openocd.cfg`;
  - the pacman database (owners and licences);
- FS-A-002 (private review record): `fstab`, `rauc/system.conf`,
  `rauc-override.sh`, `rauc.service.d/override.conf`, `steamos-boot.service`,
  the `etc_overlay` hook, `vrdevice_path`, `vrconfig_write`,
  `steamos-verity`, both `os-release` files;
- `firmware/quest3/extracted/{v2.7-user_ota,v66-*,v71-*}/kernel.config`;
- FS-A-001 (private review record), `FS-A-002.md` and `FS-A-003.md`; `docs/JOURNAL.md`
  (Do-not list, J-01 to J-09); `docs/PROJECT_SETUP.md`;
  `devices/quest3/README.md`;
- `docs/research/valve-packages-licensing.md`, `community-quest-repos-2.md`,
  `FS-A-006-ports.md` and `FS-A-006-quest-projects.md`.
