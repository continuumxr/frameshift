# Valve Frame image: writer inventory and activation review

Agent report, 2026-10-12. Answers FS-R-011 §7 D3 ("add the BLE
programmer, charger/NVM writer and systemd-repart to the writer inventory
and activation review") and D1/D2 (activation through dependencies,
sockets, timers, generators and direct helper calls; a unit mask does not
cover every invocation). Feeds DEVICE_PORT_CHECKLIST H8 and the L6 ingest
gate (`valve-image-slot-in.md` §3.3–3.4).

**Scope and conduct.** Offline only. No device command, nothing on drive
E:, no download, nothing committed. No Valve file was executed: every
read was `grep`/`strings`/`file`/`tar -t`, plus one streamed `grep` over
the Steam bootstrap tarball's members.

**Inputs (read-only):**
- WSL `~/sfroot-full`: the kernel-mount copy of `rootfs-A` from
  `steamframe-oobe-repair-20260922.5153644-0.3.0.img`, build
  `20260922.6152327` (provenance: `devices/quest3/stage2a/T1-PINS.md` §1).
  Because it is a kernel-mount copy, small files are intact, unlike the
  FS-A-001 `btrfs restore`;
- the pacman database `usr/lib/holo/pacmandb/local` (owners and licence
  labels);
- FS-A-002 (private review record) (fstab, units, `kernelsetup.sh`);
- the Quest 3 Unit 2 v2.7 baseline
  `devices/quest3/evidence/unit2-v27-baseline-20261012/partitions-by-name.txt`
  (an Android-side hardware capture already in the repo).

**Tags (FS-R-001):**
- **[M-static]** read from a named file of the image above;
- **[M]** a hardware observation (Android, from the baseline file named
  above);
- **[D]** derived from such reads;
- **[C]** inferred, or claimed by an external source;
- **[O]** open.

**Licences.** "Licence" below means the pacman `%LICENSE%` **label**.
FS-R-011 §7 D3 requires the actual per-file licence before any file is
stubbed or whited out. Only one file was checked per file: `90-home.conf`
carries an LGPL-2.1+ SPDX header [M-static]. Every other stub/whiteout
proposal below is conditional on that check [O].

**Not exhaustive.** This inventory is a review aid. It does not show that
no other writer exists (FS-R-011 §7 D1).

---

## 0. Summary

- **36 inventoried writer entries** plus **one group of 15 present but
  uncalled low-level tools**:
  - block, partition and boot-environment writers: B1–B17;
  - `/persist` and EEPROM writers: P1–P4;
  - battery and charger writers: C1–C5;
  - MCU, BLE, FPGA, GPIO and SPI writers: M1–M10.
- **Every entry can be run directly by root.** Beyond that, **20 of the
  36 have a trigger that is not their own unit:**
  - pkexec or polkit: B7–B10, P2, M5;
  - D-Bus: B2, B3, B13, C4, C5;
  - the Steam client: M6, which drives B3, B4 and B7–B9;
  - `select_steamvr.sh`: M1;
  - in-process code in a SteamVR driver: M2;
  - a sleep hook: B4;
  - udev: P4, M4, M8, M9;
  - generators: B16.

  For these, **a unit mask is not sufficient** (§2).

**Highest risk on a Quest 3, in order:**

1. **B7 `format-device.sh`** (deckard-hw-support, Proprietary).
   - It accepts any `/dev/sd[a-z]`. It zeroes the start of the disk, then
     writes a new GPT and `mkfs`.
   - On the Quest 3, `sda`–`sdf` are the UFS LUNs. They hold the boot
     chain: `xbl` on `sdb`/`sdc`, `cdt`/`ddr` on `sdd`, and `tz`, `hyp`,
     `abl` and others on `sde` [M].
   - It is reachable three ways:
     - pkexec with `allow_active=yes`;
     - the `steamos-manager` `FormatDevice` method;
     - the Steam client, whose binaries name the helper and the method
       [M-static strings].
2. **M2 `driver_cv.so`** (SteamVR, SSA).
   - It runs inside `vrserver` as the unprivileged `steamos` user.
   - It opens `/dev/gpiochip9` and `/dev/spidev0.1` directly. It also
     contains a controller firmware updater (erase, commit, reboot)
     [M-static strings].
   - `steamos` is in the `gpiod` and `spidev` groups. Valve's udev rules
     open **every** `gpiochip*` to `gpiod` (M4).
   - No unit mask applies: no unit starts it directly.
3. **M1 `steamvr-program-ble.service`** (SteamVR, SSA, plus openocd, GPL).
   - It drives SWD over `gpiochip9` lines 50, 51 and 164. It programs an
     nRF52 and runs `nrf52_recover` (a mass erase) when the AP lock is
     detected.
   - Its pre-step unloads `spi_hid` and rebinds `spi0.1` to spidev.
   - It is enabled by default.
   - It runs through `select_steamvr.sh`, which **prefers a
     Steam-downloaded SteamVR under `/home`**. The executed
     `program_ble.sh` can therefore lie outside the verified image.
4. **P2 `restore-calibration`** (deckard-hw-support, Proprietary).
   - pkexec, `allow_active=yes`.
   - It runs `blockdev --setrw /dev/sdd*`. On the Quest 3, `sdd` holds
     `cdt`/`ddr` [M].
   - It then runs `mke2fs` on whatever is mounted at `/persist`.
5. **B6 `systemd-repart`** (systemd, LGPL).
   - Enabled in `sysinit.target.wants`, with `--dry-run=no`.
   - `90-home.conf` satisfies its condition.
   - It adds a GPT entry on the disk backing `/`. Whether it can resolve
     that disk under our overlay-on-verity root is [O]; [D] likely not.
6. **B1–B4: the boot-chain and update chain** (already known).
   - New [M] evidence: Quest 3 labels match many `kernelsetup.sh` names
     (`tz`, `hyp`, `xbl`, `devcfg`, `qupfw`, `shrm`, `cpucp`, `aop`, `uefi`,
     `keymaster`, `uefisecapp`).
   - `aopconfig`, `cpucpconfig` and `xblconfig` are absent; the Quest
     uses `aop_config` and `xbl_config`.
   - Gate 4 therefore fails [D]. The `sgdisk` steps still precede it
     (FS-A-001 §5).

**Battery and charger (C1–C2) is lower than the earlier summary implied.**
- In 0.3.0, `update_pack_nvm.py` writes MAX1720x **shadow-RAM** registers.
  It unlocks write protection first. The NVM-commit command is present but
  commented out [M-static].
- Both scripts gate on the Frame EEPROM strap and on Frame-specific
  `power_supply` names that a Quest lacks [D].
- A future build could enable the commit. The charge daemon also writes
  charger setpoints and a BCL enable (§6A class). So the unit must still
  stay masked and be ingest-gated.

---

## 1. Inventory

Columns: **writes** = what it changes; **activation** = every entry path
found; **Quest exposure** = what the Quest presents to it [D unless
tagged].

### 1.1 Block devices, partitions, boot environment, EFI (B)

| ID | component (package, licence label) | writes | activation | Quest exposure | tag |
|---|---|---|---|---|---|
| B1 | `/boot/kernelsetup.sh` (deckard-uboot, GPL-2.0+) | 14 bootfw images to `${name}_${slot}`; `uboot_*`, `ubootfw_*`, `ubootenv_*` via `dd`; `sgdisk -d/-c/-n` on `/dev/sdb`; `splctl set-bootfw-slot` | `steamos-finalize-install` (without `--no-boot-install`) ← `post-install.sh` ← RAUC; direct root invocation | Many labels exist on Quest LUNs [M]; gates in FS-A-001 §5; `/dev/sdb` holds `xbl_a` under Android naming [M] | [M-static] FS-A-001/002 |
| B2 | RAUC (rauc, LGPL-2.1+), `pre-/post-install.sh`, `bootloader-custom-backend.sh`, `steamos-finalize-install`, `steamos-chroot` (steamos-customizations, LGPLv2+) | raw rootfs slot, `mkfs` of the other `var`, other `efi`, then B1 | D-Bus `de.pengutronix.rauc` → `rauc.service`; `rauc install` CLI; driven by B3 | inert without `rauc.slot=` and partsets [D] | [M-static] |
| B3 | atomupd (atomupd-daemon, MIT; steamos-atomupd-client, LGPL2.1) | drives B2; fetches bundles | D-Bus `com.steampowered.Atomupd1` (Valve polkit rule grants `steamos` custom-update, downgrade, branch switch, trusted-key management); callers `steamos-update`, `steamos-select-branch`, `dupdate`, `steamos-prepare-oobe-test`, steamos-reset `factory-reset`; Steam client (strings `Atomupd1`, `steamos-update`) | network-dependent; then B2 | [M-static] |
| B4 | `steamos-bootconf` → `splctl` (steamos-efi, GPL2; deckard-uboot-splctl, GPL-2.0+) | `bootenv` partition (boot counts, slots) | `steamos-boot.service` (graphical.target.wants, `ConditionPathExists=/efi/SteamOS`); **system-sleep hook `hibernate-post.sh`** (`--set boot-attempts 0`); `bootloader-custom-backend.sh`; `holo-sync-var`; steamos-reset; helper `steamos-reboot-other` (Steam strings; its target `/usr/bin/steamos-reboot` is absent in 0.3.0 [M-static]) | no `bootenv` label on Quest 3 [M] | [M-static] |
| B5 | `setubootenv.service` → `setubootenv` (deckard-hw-support, Proprietary); `fw_setenv` (uboot-tools, GPL) | `/etc/fw_env.config` → `ubootenv_<slot>`; `fw_setenv` writes that partition | multi-user.target.wants; `fw_setenv` callers: B1, `splctl` (strings), busybox | no `ubootenv_*` on Quest [M] | [M-static] |
| B6 | **`systemd-repart`** (systemd, LGPL-2.1+) + `/usr/lib/repart.d/90-home.conf` (steamos-customizations; SPDX LGPL-2.1+) | adds a `Type=home` GPT partition on the disk backing `/` | `sysinit.target.wants` (Valve `/usr`); `initrd-root-fs.target.wants` (Valve initrd only); `ExecStart … --dry-run=no`; `ConditionDirectoryNotEmpty=/usr/lib/repart.d` met; also any root caller | depends on whether `/`'s backing disk resolves to a UFS LUN. Overlay over verity: [D] likely unresolvable, **[O]** | [M-static] |
| B7 | **`/usr/lib/hwsupport/format-device.sh`** via `steamos-polkit-helpers/steamos-format-device` / `-format-sdcard` (deckard-hw-support, Proprietary) | `dd` zero first 1024 sectors; `parted mklabel gpt/msdos`; `mkfs.ext4`/`mkfs.exfat`; `f3probe --destructive` unless `--skip-validation` | pkexec (`org.valve.steamos.policy`, `allow_active=yes`); `steamos-manager` root daemon `Storage1.FormatDevice` (`platform.toml`, all platforms); Steam client binaries name both | **accepts `/dev/sd[a-z]`, the Quest UFS LUNs** [M-static]. Which path Steam would pass is [O]. `format-sdcard` hard-codes `/dev/mmcblk0` (absent on Quest) | [M-static] |
| B8 | `trim-devices.sh` via `steamos-trim-devices` (deckard-hw-support, Proprietary); `fstrim.service`/`.timer` (util-linux) | discard on rw-mounted ext4/btrfs | pkexec; `steamos-manager` `TrimDevices`; Steam strings; timer present, not enabled | our `var`/`home` only. A write class under D2 | [M-static] |
| B9 | steamos-reset (`steamos-reset-tool`, `steamos-reset.sh`, `factory-reset`; GPL); `steamos-factory-reset-config` (customizations, LGPLv2+) | `/esp/efi/steamos/factory-reset/*.cfg` (consumed by the Valve initramfs `factory_reset`: `mkfs`, `dd` to `ubootenv`); atomupd update; `steamos-bootconf` | `steamos-manager` `FactoryReset1.PrepareFactoryReset` (`platform.toml`); pkexec `steamos-factory-reset-config` (Steam strings); CGI scripts in `usr/share/steamos-reset/cgi` (server [O]) | no ESP on Quest; Valve initramfs never used [D] | [M-static] |
| B10 | `steamos-prepare-oobe-test` (customizations, LGPLv2+) | atomupd `custom-update` to the other slot; optional factory-reset config | pkexec (own policy) | as B3/B9 | [M-static] |
| B11 | `steamcl-install`, `steamos-boot-install` (steamos-efi, GPL2; customizations) | ESP files; `efibootmgr` (EFI variables) | B2 via `steamos-finalize-install` | no EFI and no ESP on Quest [D] | [M-static] |
| B12 | systemd boot units: `systemd-boot-random-seed` (sysinit.target.wants), `systemd-bootctl.socket` → `systemd-bootctl@` (sockets.target.wants), `systemd-boot-update`, `systemd-bless-boot` (+ generator), `systemd-hibernate-clear`, `systemd-sysupdate(.timer)`, `systemd-pcr*`/`tpm2-setup` (systemd, LGPL-2.1+) | ESP files, EFI variables, TPM | enabled or socket-activated as listed; conditions on EFI variables or `measured-uki`; sysupdate has no transfer files | no EFI or TPM on Quest [D]; varlink method set of `bootctl` in v257 [O] | [M-static] |
| B13 | udisks2 (GPL-2.0+) | format, partition, power-off via D-Bus API | D-Bus activation; polkit: `modify-device` = yes, `modify-device-system`/`open-device-system` = `auth_admin_keep`, `power-off-drive` = yes; Valve rule grants eject/power-off/unmount to `wheel` (`steamos` ∈ `wheel`) | UFS LUNs are "system" devices → admin auth [C]; whether `steamos` has a password is [O] | [M-static] |
| B14 | `predistort_images.sh` (deckard-boot-images, Proprietary) | files under `/esp/efi/SteamOS` | `deckard-boot-images.service` (multi-user.target.wants) | no ESP on Quest [D] | [M-static] |
| B15 | `steamos-readonly`, `makerootfsrw` (customizations, LGPLv2+) | `mount -o remount,rw /`; `btrfs property set / ro false` | manual; called by `enter_ship_mode.sh` (C3) | fails on the verity/overlay root [D] | [M-static] |
| B16 | `systemd-gpt-auto-generator`, `systemd-fstab-generator` + fstab `x-systemd.growfs` (`/home`) → `systemd-growfs@` | mounts (journal replay); filesystem growth | generators run at every boot and reload | inert with `fstab=no` and no discoverable root disk [D]; `systemd.gpt_auto=0` [C] | [M-static] |
| B17 | Valve initramfs hooks `factory_reset`, `blockdev_ro`, `partsets` (customizations); `mkinitcpio-generate-shutdown-ramfs` | `mkfs`/`dd` (factory_reset); `/run/initramfs` only (shutdown ramfs) | Valve initrd only; halt/reboot/kexec target wants | our initramfs replaces Valve's [D] | [M-static] |

### 1.2 `/persist` and EEPROM (P)

| ID | component (package, licence label) | writes | activation | Quest exposure | tag |
|---|---|---|---|---|---|
| P1 | `vrconfig_write` (deckard-hw-support, Proprietary) | `blockdev --setrw`, remount `/persist` rw, git commit, back to ro | **no caller** in the image's `/usr`, `/opt` or `/etc`, nor in the Steam bootstrap [M-static negative]; any root process | `/persist` comes from fstab `PARTLABEL=syspersist`; the Quest label is `persist` (`sda2`) [M] → absent unless we mount it | [M-static] |
| P2 | **`restore-calibration`** (deckard-hw-support, Proprietary) | `blockdev --setrw /dev/sdd*`; remount `/persist`; **`mke2fs -L syspersist`** on the `/persist` source; writes JSON from EEPROM; `git init` | pkexec (`org.valve.steamos.policy`, `allow_active=yes`); no other caller found | Quest `sdd` = `cdt`, `ddr` [M]: the ro flag is cleared on them. `mke2fs` hits whatever is mounted at `/persist` | [M-static] |
| P3 | `eeprom_console` (deckard-eeprom, Proprietary) | set, reset, lock, unlock, upgrade of items in an i2c `…/eeprom` nvmem | callers in the image use `get` only (`update_pack_nvm.py`, `set_mac_addresses.sh`, `restore-calibration`, `driver_cv.so`, `XRService`) [M-static]; direct invocation | Quest i2c EEPROMs [O] | [M-static] |
| P4 | `99-eeprom.rules` (deckard-eeprom) | `chmod 666` on every nvmem device of type EEPROM | udev on each nvmem add | makes any Quest nvmem EEPROM world-writable [O which] | [M-static] |

### 1.3 Battery and charger (C)

| ID | component (package, licence label) | writes | activation | Quest exposure | tag |
|---|---|---|---|---|---|
| C1 | **`update_pack_nvm.py`** (deckard-charger, Proprietary) | unlock write protection, then MAX1720x config registers via the driver's `register_store`, i.e. **shadow RAM**; NVM commit (`0x60 0xE904`) present but **commented out** in 0.3.0 | `ExecStartPre` of `deckard-charger.service` (basic.target.wants, `DefaultDependencies=no`); direct | gated on `eeprom_console get strap_revision` = `ev*`/`Bev*` and `max1720x_bat_*` sysfs; neither exists on the Quest [D] | [M-static] |
| C2 | `deckard_charge_daemon` (deckard-charger, Proprietary) | charger setpoints on `mp2652-charger` and `pm8550b-charger` (charge current/voltage, enable, termination, AICL); hot-swap pack control; **`bcl_enable`** at `c400000.spmi:pmic@1:sensor@4700` | same unit; `Restart=on-failure`, `WatchdogSec` | Frame `power_supply` names absent [D]; BCL path naming under our kernel [O] | [M-static] strings |
| C3 | `enter_ship_mode.sh` → `entershipmode.shutdown` (deckard-hw-support, Proprietary) | at shutdown: `pm8550b-charger` `charging_pause`, `ship_mode` | installs itself into `system-shutdown/` after `steamos-readonly disable`; no caller found in the image | path absent; root read-only [D] | [M-static] |
| C4 | KDE powerdevil `chargethresholdhelper` (kauth) | `charge_control_*_threshold` | D-Bus activation (`org.kde.powerdevil.chargethresholdhelper`) | Quest `power_supply` attributes [O] | [M-static] |
| C5 | `steamos-manager` `BatteryChargeLimit1` (MIT) | battery limit attribute | Steam UI | `steam-frame.toml` defines no `battery_charge_limit` [M-static] → none on Frame or Quest | [M-static] |

### 1.4 MCU, BLE, FPGA, GPIO, SPI (M)

| ID | component (package, licence label) | writes | activation | Quest exposure | tag |
|---|---|---|---|---|---|
| M1 | **`steamvr-program-ble.service`** → `select_steamvr.sh` → `program_ble.sh` → `openocd` (deckard-steamvr-rel, SSA; openocd, GPL); `ExecStartPre` `disable_spi_hid.sh` | `rmmod spi_hid`; rebind `spi0.1` to spidev; SWD (`linuxgpiod`, chip 9: swclk 51, swdio 50, srst 164); `program roy_dongle_fw.hex` (preverify), and `nrf52_recover` (mass erase) on AP lock | multi-user.target.wants; `setup_controller_radio.sh` (sudo, manual); **`select_steamvr.sh` executes the copy under `steamvr path` first**: a Steam-downloaded SteamVR under `/home/steamos/…` (apps 250820/330050) before `/opt/steamvr` | Quest `gpiochip9` lines 50/51/164 and `spi0.1` are unrelated hardware [O which] | [M-static] |
| M2 | **`driver_cv.so`** (deckard-steamvr-rel, SSA), loaded by `vrserver` | opens `/dev/gpiochip9` and `/dev/spidev0.1`; Roy controller firmware update (erase, commit, reboot) from `frame_controller/…/manifest.vrfirmware` | SteamVR driver load (built-in drivers dir; `steamvr enable` autostarts at boot and resume); runs as `steamos` | unprivileged access via M4; Quest chip 9 and SPI 0.1 [O] | [M-static] strings |
| M3 | deckard-fpga (Proprietary): `fpga_power_en.sh`, `fpga_load.sh` → `littlebee_config` (FPGA SPI bootloader, `gpiochip9`), `reset_fpga`, `write_reg`, `cam_setup`, `pulse_room_led` | sysfs `fpga/valve/enable`; FPGA programming; GPIO and SPI register writes | `deckard-fpga.service` (multi-user), `deckard-fpga-resume` (suspend.target.wants); tools by hand | `fpga_load.sh` exits on model `Unknown`; the enable path is absent [D]; the manual tools are ungated | [M-static] |
| M4 | udev permission rules (deckard-hw-support, Proprietary): `99-gpiod-permissions` (`gpiochip*` 0660 `gpiod`), `99-spidev-permissions` (0664 `spidev`), `45-i2c-tools` (i2c 0660 `i2c`, no members), `00-usb-permissions`, `99-hidraw-permissions`, `60/70-steam-input` (uaccess) | enable unprivileged writers | udev, every add | `steamos` ∈ `gpiod`, `spidev`, `input`, `video`, `leds`, `cdsp`, `perf`, `wheel` [M-static `/etc/group`] → **every Quest GPIO chip is writable by the session user** | [M-static] |
| M5 | `steamos-priv-write` (deckard-hw-support, Proprietary) | allowlisted sysfs (backlight, `/dev/drm_dp_aux0`, amdgpu OD, hwmon `power*_cap`, `i2c-2` `brightness`/`bmode`, LED); also grants group write | pkexec (`allow_active=yes`); Steam strings | mostly absent paths; hwmon `power*_cap` [O] | [M-static] |
| M6 | Steam client (deckard-steam-rel, SSA; self-updates in `/home`) | controller firmware over hidraw [C]; invokes B3, B4, B7–B9, M5 helpers and the steamos-manager methods (strings in `steamui.so`, `steamclient.so`, `steamwebhelper` …) | user session (`steam.service`) | the Quest itself is targeted only via the helpers above; attached Valve peripherals [C] | [M-static] strings |
| M7 | SteamVR htc/indexcontroller firmware (SSA) | Vive/Index peripheral firmware | `vrserver` lighthouse driver | no linuxarm64 lighthouse driver ships; only `driver_cv.so` is linuxarm64 [D] → not executable | [M-static] |
| M8 | `set-bluetooth-mac-address`/`set-wifi-mac-address` → `set_mac_addresses.sh` (deckard-hw-support, Proprietary) | Wi-Fi MAC via `ip link` (volatile); BT path via `btmgmt` (read part seen; set part not read) | udev `SYSTEMD_WANTS` on `hci0` add | MACs from `eeprom_console get` fail on Quest [D]; BT write volatility [O] | [M-static] |
| M9 | `deckard-led-control` (`ledcontrol`), `deckard-power-monitor`, `deckard-typec-logger`, `iris-driver-rebind`, `softapmanager`, `typec-plug-event.sh` | LED class sysfs; `/run`; driver rebind; configfs USB gadget | enabled units; udev `typec` | no storage, NVM or MCU write found in their strings [M-static]; listed for review completeness | [M-static] |
| M10 | busybox `devmem` (busybox) | physical-memory writes via `/dev/mem` | no caller found; any root process | depends on `STRICT_DEVMEM`/`/dev/mem` in our kernel [O] | [M-static] |

### 1.5 Present low-level tools with no caller found in the image (T)

`ufs-utils` (UFS descriptor/attribute/flag writes and firmware update over
BSG: the D2 pass-through route), `sgdisk`, `parted`, `f3probe`, `mkfs.*`,
`efibootmgr`, `openocd`, `gpioset`, `i2cset`/`i2ctransfer`, `fw_setenv`,
`mdadm` (with a `system-shutdown` hook), `btrfs`, `cryptsetup`, and the
busybox applets `blkdiscard`, `blockdev`, `fdisk`, `mke2fs`, `mkfs.vfat` and
`ubiupdatevol` [M-static]. **A caller-less tool is still a writer:** any
root process, or a future Valve build, can run it. Only kernel or device
policy contains it (§2).

---

## 2. Proposed controls

**Key:**
- **K**: kernel or device policy;
- **U**: a mask in our layer and on the command line (`systemd.mask=`),
  including D-Bus activation;
- **UR**: a udev rule mask (same-name `/etc/udev/rules.d` entry → `/dev/null`);
- **PK**: a polkit deny rule in our `/etc/polkit-1/rules.d`;
- **S**: a FOSS stub or whiteout (only after the per-file licence check);
- **L2**: never expose the Frame layout (no `rauc.slot=`, partsets,
  `bootenv`, `uboot*`, `syspersist`, `/efi/SteamOS`, ESP);
- **G**: the ingest gate, per build.

| ID | control | unit mask sufficient? | effective technical prevention still needed |
|---|---|---|---|
| B1 | opaque `/boot`; L2; S (`steamos-finalize-install`, B1 is GPL label); K block guard | **no**: direct call via `steamos-finalize-install` | K: deny writes, `BLKPG` and ro-clear on every LUN outside the allowlist |
| B2–B3 | U `rauc`, `atomupd` (incl. D-Bus names); S `rauc`, hook scripts, `steamos-update`, `steamos-select-branch` (stubs talk to our updater); replace `/etc/rauc/system.conf`; PK deny `Atomupd1.*` | **no**: CLI and Steam client paths | K (as B1); a polkit deny alone suffices against the unprivileged Steam path |
| B4 | U `steamos-boot`; L2 (no `bootenv`/`/efi/SteamOS`); S `steamos-bootconf`/`splctl`; **remove or whiteout `hibernate-post.sh`** (a sleep hook, not a unit) | **no**: sleep hook, reset scripts, helper | K |
| B5 | U `setubootenv`; S `fw_setenv` | no | K |
| B6 | U `systemd-repart` (cmdline too); whiteout `90-home.conf` (SPDX LGPL-2.1+ confirmed) so the unit condition is false; never hand Valve's initrd units to our initramfs | **no**: `systemd-repart` runs directly as root | K: deny `BLKPG` and partition-table writes on Quest LUNs |
| B7 | **PK deny `run-steamos-polkit-helpers-steamos-format-device`/`-format-sdcard`**; U or override `steamos-manager` (system) and its D-Bus activation; Proprietary → **no whiteout** | **no**: pkexec, steamos-manager, Steam | **K mandatory before Valve userspace runs:** block-write guard over all `sd*`, plus no device nodes for boot LUNs in the session's view |
| B8 | PK deny trim helper; fstrim timer stays disabled | no | K: discard allowlist (D2) |
| B9–B10 | PK deny `steamos-factory-reset-config`, `prepare-oobe-test`; U `steamos-manager` or override `platform.toml` [O]; S steamos-reset, `steamos-factory-reset-config` (GPL/LGPL labels); no ESP | no | K |
| B11–B12 | U the boot units, `systemd-bootctl.socket`, sysupdate timer; no EFI exposed | yes, for the units; `bootctl`/`efibootmgr` remain directly callable | K (ESP absent; `efivarfs` not mounted) |
| B13 | PK deny `udisks2.modify-device*`, `format`, `open-device-system`, `power-off-drive` for all subjects; U `udisks2` if Steam does not need it [O] | no: D-Bus | K |
| B14–B17 | U units; `fstab=no`; `systemd.gpt_auto=0`; our initramfs only | yes, given L2 | K covers the residue |
| P1 | never mount any Quest partition at `/persist`; no `syspersist` label; Proprietary → no whiteout | **no**: direct root call | K: deny ro-clear and writes to `persist` (`sda2`) and other unit-unique partitions |
| P2 | **PK deny `run-restore-calibration`** | **no**: pkexec | **K mandatory:** deny `BLKROSET` clear and writes on `sdd`, and any `/persist` source |
| P3–P4 | UR `99-eeprom.rules`; do not bind at24 EEPROMs to user-visible nvmem [O] | no: direct call | K/device policy: EEPROM nodes root-only and read-only |
| C1–C2 | U `deckard-charger` (cmdline too); Proprietary → no whiteout; our supervisor owns charging (§6A) | **no**: the Python script and daemon are directly runnable | device policy: `register_store`/`power_supply` writes reserved to our supervisor (SELinux or a DAC overlay) [O]; G flags any NVM-commit change |
| C3 | none needed beyond the read-only root; G flags | yes (read-only root blocks the install step) | — |
| C4–C5 | PK deny `chargethresholdhelper` | no | device policy as C1 |
| M1 | U `steamvr-program-ble`; **pin `steamvr path` to `/opt/steamvr`** [O how]; G must cover the `/home` SteamVR copies or forbid them | **no**: `setup_controller_radio.sh`, sudo, a Steam-downloaded copy | **K/device mandatory:** no `gpiochip` node writable by non-supervisor users; `CAP_SYS_MODULE` (rmmod) and `driver_override` writes denied to the session |
| M2 | disable `driver_cv` in SteamVR settings [O: user-writable setting, so weak]; UR M4 | **no**: in-process, no unit | **K/device mandatory:** `gpiochip*` and `spidev*` 0600 root (UR on M4), `steamos` out of `gpiod`/`spidev` (a group override in our `/etc` layer [O: D3 class]), device cgroup or SELinux for `vrserver` |
| M3 | U `deckard-fpga*`; model gate stays `Unknown` (R1) | no: manual tools | as M2 |
| M4 | UR all four rules; our own rules for the nodes we need | n/a | this **is** part of the device-policy path |
| M5 | PK deny `steamos-priv-write` | no | device policy |
| M6 | PK denies above; G for Steam client updates [O] | n/a | — |
| M7–M9 | U the hardware units (`valve-image-slot-in.md` §2.3) | yes, for units | — |
| M10, T | none at unit level | n/a | **K:** `STRICT_DEVMEM`/no `/dev/mem`; block guard; BSG/SG_IO denial; module-load lock |

**What the table implies for D2 and D3:**
- Unit masks plus whiteouts address 10 of the 36 entries completely:
  B11, B12, B14–B17, C3, M7–M9, and those only given L2 and our
  initramfs.
- Containing every directly invoked writer before Valve userspace runs
  needs three things:
  1. a **polkit deny set**. It is effective against the unprivileged Steam
     client and SteamVR, and costs nothing;
  2. a **device-node policy** for `gpiochip`, `spidev`, `i2c`, `nvmem` and
     `power_supply` writes. The block guard does not cover these
     (FS-R-011 §7 D2);
  3. the **block-write guard**, or an equivalent SELinux or device-cgroup
     boundary, covering `sd*` writes, `BLKPG`, ro-clear, discard and BSG.
- **Root-run Valve code is contained only by item 3 and by kernel-side
  device policy.** This applies to `steamos-manager -r`, `vrserver`'s
  sudo paths and the system units.

---

## 3. Activation surfaces reviewed (D1)

| surface | what was enumerated [M-static] | writers reached |
|---|---|---|
| enabled units | `/etc/systemd/system/*.wants` (basic, graphical, multi-user, sysinit, suspend, usb-gadget …) and `/usr/lib/systemd/system/*.wants` (sysinit, initrd-root-fs, local-fs, shutdown, sockets, timers) | B4, B5, B6, B12, B14, C1/C2, M1, M3, M9 |
| sockets | `systemd-bootctl.socket`, `systemd-pcrextend/pcrlock.socket`, `systemd-sysext.socket`, `dm-event.socket` and others | B12 |
| timers | enabled: `man-db`, `shadow`, `systemd-tmpfiles-clean`, `archlinux-keyring-wkd-sync` (masked in `/etc`); present, not enabled: `fstrim`, `systemd-sysupdate(-reboot)`, `btrfs-scrub@`, `e2scrub_all`, `podman-auto-update`, `mdcheck_*` | B8, B12 (if enabled later) |
| path units | `ostree-finalize-staged.path` (ostree inert), `systemd-ask-password-*`, `brltty` | none |
| generators | `gpt-auto`, `fstab`, `bless-boot`, `debug`, `system-update` (no `system-update.target.wants`), `cryptsetup`/`veritysetup`/`integritysetup`, `hibernate-resume`, `tpm2`, `zram`, `ostree`, `podman` | B12, B16 |
| udev `RUN`/`PROGRAM`/`SYSTEMD_WANTS` | `99-steamos-automount` (mmcblk only), `99-sdcard-rescan`, `typec-plug-event`, `90-mac-addresses`, `99-eeprom`, `99-leds`, `99-backlight`, `90-steam-inputplumber` (DMI), log-submitter hooks | P4, M8 |
| udev permissions | M4 rules; `steamos` group memberships | M1, M2, M3 |
| D-Bus activation | `de.pengutronix.rauc`, `com.steampowered.Atomupd1`, `com.steampowered.SteamOSManager1` (system policy: root-only send), `org.freedesktop.UDisks2`, KDE kauth helpers | B2, B3, B7–B9, B13, C4 |
| polkit/pkexec | `org.valve.steamos.policy`: 26 actions, all `allow_active=yes`, including absent `jupiter-*` helpers; `prepare-oobe-test`; `steamvr`; Atomupd and udisks2 rules | B3, B4, B7–B10, B13, P2, M5 |
| direct helper calls | Steam client strings (§1.4 M6); `select_steamvr.sh` path redirection; `driver_cv.so` in-process; root `steamos-manager` → `platform.toml` scripts; sleep and shutdown hooks (`hibernate-post.sh`, `00-ledcontrol.sh`, `mdadm.shutdown`, C3) | B3, B4, B7–B9, M1, M2, C3 |

---

## 4. Gaps [O] and the evidence that would close them

| # | open question | evidence that closes it |
|---|---|---|
| G1 | Native-Linux LUN naming on the Quest (`sda`–`sdf` order; which LUN holds `xbl`, `cdt`/`ddr`, `persist`) under our kernel | a read-only listing of `/sys/block/sd*/device` and partlabels from a FrameShift kernel. Device action, PM approval |
| G2 | Quest `gpiochip9` identity and lines 50/51/164; `spi0.1`; nvmem devices of type EEPROM; `power_supply` names; whether a BCL path matching C2 exists | read-only sysfs listing under our kernel (`/sys/class/gpio*`, `/sys/bus/spi/devices`, `/sys/bus/nvmem/devices/*/type`, `/sys/class/power_supply`) |
| G3 | Which device path the Steam client passes to `FormatDevice`/`steamos-format-device`, and whether it would list a UFS LUN | sandbox run with stubbed helpers logging argv, and decoy disks (`valve-image-slot-in.md` §5.2 item 0.7; FS-R-001 §1 isolation). The K guard makes this moot for safety |
| G4 | How the user `steamos-manager` reaches the root daemon (the system policy allows only root to send); whether an `/etc` override of `platform.toml` exists | read the public MIT source of steamos-manager 26.4.1 (online read allowed) |
| G5 | Whether `systemd-repart` resolves a backing disk under overlay-on-verity-on-loop or dm, and what it would do | `systemd-repart --dry-run=yes` against a disposable host copy in the WSL sandbox (offline) |
| G6 | Writer sets in later builds: `deckard-20261005.6135832-0.4.4.raucb` and `deckard-20261007.6021410-0.5.5.raucb` are held locally but are index-only | the casync chunk download for a reviewed build (PM approval), then rerun §1/§3 per build (G gate). Watch especially for C1's NVM commit |
| G7 | Steam-downloaded SteamVR and the Steam client self-update in `/home` change M1, M2 and M6 outside the verified image | a policy decision: pin `steamvr path` and gate or forbid `/home` SteamVR, or treat it as untrusted under K; inspect the depot contents per version (not possible offline) |
| G8 | Per-file licences for every proposed stub or whiteout (only `90-home.conf` checked) | read the SPDX or licence headers of each file to be shadowed (offline, image) |
| G9 | `bootctl` varlink method set in systemd 257 (any ESP or EFI writes) | read the systemd v257 source or man page (online read) |
| G10 | Server for `steamos-reset` CGI; callers of `enter_ship_mode.sh`, `restore-calibration`, `vrconfig_write` beyond the image and bootstrap | extend the Steam bootstrap member grep to these names (offline); later, a runtime trace in the sandbox |
| G11 | Whether `steamos` gets a password at OOBE (gates the `auth_admin` udisks paths and `sudo`) | OOBE inspection (`valve-image-slot-in.md` §5.2 item 0.8) |
| G12 | Whether SELinux, capabilities and device cgroups in our kernel can enforce M2/M4 device policy for `vrserver` while Steam still works | design note for D2, plus a QEMU test |

---

## 5. Method (reproducible, offline)

Read-only shell over `~/sfroot-full`:
- listed `*.wants`, generators, presets, timers, path units, sockets,
  `repart.d`, D-Bus system services, polkit actions and rules, and udev
  rules;
- grepped `RUN`/`PROGRAM`/`SYSTEMD_WANTS` in udev rules;
- read every polkit helper, `hwsupport` script, deckard-hw-support,
  deckard-charger, deckard-fpga and SteamVR `roy` script cited;
- ran `strings` on `splctl`, `eeprom_console`, `deckard_charge_daemon`,
  `ledcontrol`, `deckard_power_monitor`, `steamos-manager`, `steamosctl`,
  `driver_cv.so`, `XRService` and busybox;
- streamed `tar --to-command` over `usr/lib/steam/steam.tar.zst` with
  `grep` for helper and D-Bus method names;
- took package owners and licence labels from the pacman database;
- read the Quest LUN map from the 2026-10-12 baseline file.

Scripts lived in the session scratchpad only, not in the repository.

---

## 6. Does the Steam Frame have these protections? (2026-10-12)

PM question: "Does the Valve Steam Frame itself even have the 3 protections
you are proposing? It's supposed to be open and modifiable." Same inputs and
conduct as above (read-only `~/sfroot-full`, build `20260922.6152327`; the
embedded kernel config was read from `boot/Image-6.18.0-gfbdbca41fd45`
(`IKCFG`); the initrd member list from `boot/initrd.uImage`), plus public web
reading. Nothing executed, nothing downloaded.

**Short answer.** The Frame has **no** polkit deny set and **no** device-node
restriction: Valve deliberately grants both to the session user. It **does**
have a block-layer guard, a soft one: `blockdev --setro` on the boot and persist
LUNs, set at every boot, with a documented root opt-out. Valve's security model
is "root is trusted, guard against accidents, the owner can switch it off".
Kernel: no lockdown LSM, no SELinux, no Landlock, AppArmor built but not in
`CONFIG_LSM`, no module signing, `STRICT_DEVMEM` off,
`BLK_DEV_WRITE_MOUNTED=y`. The read-only root (btrfs `ro` property) and an
optional dm-verity root (`steamos-verity enable`) are reversible with
`steamos-readonly disable` / `steamos-devmode enable` [M-static].

**What makes our three items necessary is the Quest's hardware mapping, not a
missing Valve safeguard.** Valve's scripts hard-code the Frame's device names.
On the Quest, the same names point at other hardware:
- **Boot LUNs.** Valve locks `sdb`/`sdc`/`sdd`. The Quest's boot chain also
  spans `sde`, and its unit-unique data is on `sdf` and `sda2` [M].
- **GPIO, SPI and EEPROM nodes.** Valve's rules and code assume the Frame's
  wiring. On the Quest the same node names are different hardware (G2).
- **Recovery.** The Frame has a Valve repair image [C]. The Quest has a locked
  bootloader and no vendor reflash path for us [C]. So "reversible" on the Frame
  can mean "brick" on the Quest.

### 6.1 Polkit deny set (B7, P2 and others)

- **Frame [M-static]:** `org.valve.steamos.policy` sets
  `allow_any`/`allow_inactive`/`allow_active=yes` on **all 26 actions**. This
  includes `run-steamos-polkit-helpers-steamos-format-device` and
  `run-restore-calibration`. `allow_any` is wider than the `allow_active` noted
  in §1. The only Valve `.rules` file *adds* udisks grants for `wheel`. No deny
  exists. Password-less access is by design: the Steam UI calls these helpers
  without a prompt [M-static strings, M6].
- **Why it is safe on the Frame [M-static/D/C]:**
  - `format-device.sh` comes from the Deck. There, `sd*` can only be USB mass
    storage (internal disk `nvme0n1`, card `mmcblk0`) [C].
  - On the Frame, internal storage is UFS too (`kernelsetup.sh` runs `sgdisk` on
    `/dev/sdb`; Valve lists "UFS storage + microSD" [C]). The script itself has
    no internal-disk check, so the Frame relies on three things:
    1. the mount check: it aborts if any partition on the target disk fails to
       unmount (rootfs and `/home` live on that disk);
    2. `blockdev_ro` (§6.3): `dd` to `sdb`/`sdc`/`sdd` fails with EPERM;
    3. the UI: the Frame automounts only `mmcblk*` (`99-steamos-automount.rules`),
       so Steam offers the microSD [C; G3 still open].
  - `restore-calibration` runs `blockdev --setrw /dev/sdd*` because **on the
    Frame `sdd` is the `syspersist` LUN** [M-static: it then remounts
    `/persist`].
- **On the Quest [M/D]:**
  - `sdb`–`sdf` hold the boot chain and unit data. Nothing on them is mounted,
    and nothing sets them read-only unless we do, so checks 1 and 2 never fire.
  - `sdd` is `cdt`/`ddr`, not persist.
  - The risk is a **Quest-mapping risk**.
- **Recommendation: narrow.**
  - Deny only the actions whose targets map to Quest boot-chain or unit data,
    or to the Frame update chain: `steamos-format-device`, `restore-calibration`,
    `steamos-factory-reset-config`, `prepare-oobe-test`, `steamos-update`,
    `steamos-select-branch`, Atomupd custom-update/trusted-key, and the
    udisks2 `modify-device-system`.
  - Leave Valve's other grants as shipped: hostname, timezone, devkit-mode,
    sshd, reboot and `format-sdcard`. `format-sdcard` hard-codes `mmcblk0`,
    which the Quest lacks.
  - Owner opt-out: one documented FrameShift switch removes our rules file.
    `steamos-devmode` is the analogue.
  - Polkit does not stop the root `steamos-manager` `FormatDevice` path, so
    §6.3 remains the real backstop.

### 6.2 Device-node policy (GPIO, SPI, i2c, nvmem, power_supply)

- **Frame [M-static]:** Valve **opens** these nodes; it does not restrict them.
  - `99-gpiod-permissions.rules`: every `gpiochip*` is 0660, group `gpiod`.
  - `99-spidev-permissions.rules`: named Frame buses (`spidev0.1`, `1.0`,
    `17.0`, `20.0`, `21.0`, `fpga_cspi`) are 0664, group `spidev`.
  - `99-eeprom.rules`: `chmod 666` on **every** EEPROM-type nvmem device.
  - `45-i2c-tools.rules`: 0660, group `i2c` (the group has no members).
  - `99-exp5-permissions.rules`: `chown steamos` on the 5 V expansion enable.
  - `steamos` is in `gpiod`, `spidev`, `cdsp`, `perf`, `leds`, `video`,
    `input` and `wheel`.
  - This is intended: `driver_cv.so` in unprivileged `vrserver` drives the
    Frame's `gpiochip9`/`spidev0.1` (M2).
  - No `power_supply` rule exists; those writes are root-only by kernel default.
- **Why it is safe on the Frame [D]:** the nodes are the Frame's own hardware,
  and Valve's code knows their line numbers.
- **On the Quest [D/O]:** the wildcard rules (`gpiochip*`, every EEPROM nvmem)
  and Frame-numbered names (`gpiochip9` lines 50/51/164, `spi0.1`) match
  **unrelated Quest hardware** (G2). The SWD bit-bang in M1 and the erase in M2
  would then toggle unknown Quest lines. This is a **Quest-mapping risk**.
  - Charger and BCL writes are the exception. They are a project safety rule
    (PROJECT_SETUP §6A), not Valve parity.
- **Recommendation: narrow.**
  - Mask only Valve's wildcard and Frame-numbered rules (M4, P4). Do not add
    blanket SELinux/device-cgroup confinement of root.
  - Grant the session user exactly the Quest nodes that a working feature
    needs, once identified (G2).
  - Root keeps full access, as on the Frame.
  - Keep the §6A reservation of `power_supply`/BCL/charger writes to our
    supervisor, as a safety item. G12 (SELinux for `vrserver`) drops to "only
    if needed".

### 6.3 Block-write guard (boot-chain partitions)

- **Frame [M-static]:**
  - **Yes, in soft form.** The Valve initramfs runs `blockdev_ro` as a late
    hook (`/etc/mkinitcpio.conf.d/steamos.conf`; `LATEHOOKS="blockdev_ro …"`
    in the shipped `initrd.uImage` config). It runs
    `blockdev --setro /dev/sdb* /dev/sdc* /dev/sdd*`.
  - The hook's comment states the intent: protect "bootloader and persist"
    from an accidental `dd`. It names the opt-out (`blockdev --setrw`).
  - Valve's own writers clear and restore the flag themselves:
    - `kernelsetup.sh` (`unlock_`/`lock_block_device`);
    - `restore-calibration` (`--setrw /dev/sdd*`);
    - the `factory_reset` hook (`--setrw /dev/sd*`).
  - Kernel side: no lockdown, `BLK_DEV_WRITE_MOUNTED=y`,
    `SCSI_UFS_BSG=y`/`BLK_DEV_BSG=y`. Nothing stops root.
- **Why it is enough on the Frame:** the list matches the Frame's LUN layout,
  and Valve publishes a repair image [C].
- **On the Quest [M/D]:**
  - We replace Valve's initramfs (B17), so **the Frame guard is not present at
    all**.
  - Copied verbatim, it would lock `xbl` (`sdb`/`sdc`) and `cdt`/`ddr`
    (`sdd`). It would leave `sde` (`tz`, `hyp`, `abl`, `aop`, `devcfg`,
    `keymaster`, `uefivarstore`, `secdata` …), `sdf` (`modemst*`, `fsg`) and
    `sda2` `persist` writable.
  - Valve's own scripts clear the flag on Frame-named LUNs as routine (e.g.
    `restore-calibration` clears `sdd*`, the Quest's `cdt`/`ddr`). A
    root-revertible flag alone is therefore undone by Valve code that does not
    know it is on a Quest.
- **Recommendation: keep, but scope and soften it:**
  - Apply it only to Quest boot-chain and unit-unique partitions: all of
    `sdb`–`sdf` plus the `sda` firmware/persist partitions, by partlabel
    allowlist from the baseline (G1). It does not cover the `sd*` disks
    generally or our own `var`/`home`.
  - Deny writes, ro-clear, `BLKPG`, discard and BSG on that set. This is the
    Valve-equivalent guard.
  - Opt-out: an owner-controlled switch that Valve code cannot trip, e.g. a
    FrameShift kernel cmdline flag or a dedicated unlock command. Not
    `BLKROSET`, which Valve scripts call by routine.
  - This keeps the Frame's spirit (on by default, the owner can turn it off)
    and closes the gap that comes from the Quest mapping.

**Net for §2:** none of the three is a Valve-parity feature, and none should
restrict root or the owner beyond Valve's model. Each is retained only as
narrowed above, because the hazard comes from Frame-specific names landing on
Quest hardware. All three get one documented FrameShift opt-out, in the manner
of Valve's developer mode.

**Sources (public, read 2026-10-12):**
- Steamworks "Load games on Steam Frame" (Developer Mode under
  Settings > System);
- Steam Deck developer FAQ (users "can turn off read-only mode", with Valve
  advising against it);
- the SteamOS Steam Frame image download page and licence (a back-up image
  exists; the licence forbids modifying that image itself);
- GamingOnLinux launch coverage (UFS storage plus a microSD slot);
- Road to VR (Quest 3 bootloader locked);
- TechSpot via search snippet (an unlocked Linux desktop on the Frame);
- no Valve statement was found on an unlocked Frame bootloader [O].
