# FS-A-006 research — community SteamOS-on-ARM ports

Agent report, 2026-10-08. Offline. Clones are in WSL `~/work/fs006`.

**Commits read:**
- hashtagbasit/SteamOS-ARM-Port `58253820`. Upstream HEAD `aab5fea4` adds
  UI, update and SM8750 changes only.
- MaSieS4Fun `7eecdb23`, reverie `ac8cc05b`.
- Quest1-SteamOS `b7467ff1`.
- pb-os `f2ffd9f8`, a derivative of basit.
- Meta's published kernel: branch `oculus-quest3-kernel-master` at
  `bcbad930` (`git ls-remote`).

## Most reusable

**A. Quest1-SteamOS is our exact pattern on an older Quest.**
- **Boot:** `fastboot boot` of Meta's kernel plus a busybox initramfs. It
  mounts userdata, loop-mounts `/data/steamos/holo.img` (ext4) and runs
  `switch_root` into systemd (`README.md:13,80-88`; `initrd/init:61-83`)
  [M-static].
- **Kernel:** they **rebuilt** Meta's kernel. Config fragment:
  `kernel/steamos.config:1-39` [M-static].
- **Rootfs:** public Holo Core aarch64 `system.rootfs.zst`, plus the Frame's
  `steam.tar.zst`, `/opt/steamvr` and gtk2 (`docs/rootfs-build.md:12,24-26`)
  [M-static].
- **Image:** `mkfs.ext4 -O ^orphan_file,^metadata_csum_seed,^metadata_csum`
  (`tools/mkholo.sh:7`) [M-static]. The image sits in a new top-level
  `/data/steamos`, outside file-based encryption (`rootfs-build.md:79`).
  The Quest 3 has `FS_ENCRYPTION=y` [M-static].
- **Userspace** (`device/native-setup.sh:9-40`) [M-static]:
  - `set-default multi-user.target`;
  - mask firstboot; `machine-id-setup`;
  - mask resolved (a 4.4-era limitation);
  - networkd `usb0` at 192.168.77.1 with a DHCP server;
  - `serial-getty@ttyGS0` with autologin; sshd.

**B. basit mounts the `/etc` overlay before `switch_root`.**
- Valve's `etc.mount` overlays `/etc` from `/var/lib/overlays/etc`. Without
  the early mount, enabled services such as sshd never start.
- Sources: `kernel-common/initramfs/init:170-180` (commit `f08eaa6`);
  fstab written to both layers (`make-steamos-sm8650.sh:457-464`)
  [M-static].

**C. A USB debug shell that survives `switch_root`.**
- **basit:** an ACM + NCM gadget with telnetd at 172.16.42.1. The shell
  lives on a tmpfs and runs `chroot /proc/1/root` (`init:41-81`).
- **Quest1:** telnetd and udhcpd chrooted from `/run/holo-init`, with
  `systemd --log-target=kmsg` (`initrd/init:22-56,77-83`) [M-static].

## Kernel

- **basit and pb-os:** ROCKNIX mainline, plus the fragment
  `external-and-mods/kernel-common/steamos.config:1-89`. Notable:
  - FTRACE is required. steamos-manager stalls Game Mode for about 3 min
    without tracefs, and mangoapp aborts (`:62-70`).
  - binder with anbox-* names. On the Quest the names are
    `binder,hwbinder,vndbinder`.

  [M-static]
- **MaSi:** Armbian mainline, with DEVTMPFS, FHANDLE, AUTOFS and BTRFS=m
  [M-static].
- **No port runs Valve userspace on an unrebuilt vendor kernel** [D].
- **Stock Quest 3 5.10 gaps:** DEVTMPFS, FHANDLE, AUTOFS, BTRFS, USER_NS,
  SYSVIPC, POSIX_MQUEUE, CGROUP_PIDS, CGROUP_DEVICE, CHECKPOINT_RESTORE,
  TMPFS_XATTR, TMPFS_POSIX_ACL, EROFS, KEY_DH_OPERATIONS,
  CRYPTO_USER_API_HASH [M-static].
- **VA_BITS=39** is the same FEX problem Quest1 flagged
  (`steamframe-stack.md:190`) [M-static].
- [O] Does the Quest 3 accept a self-built kernel from
  `oculus-quest3-kernel-master` via `fastboot boot`?

## Rootfs

- **basit and MaSi repack btrfs to ext4.** They loop-mount the btrfs
  read-only, then `rsync -aHAX --filter="-x btrfs.*"`
  (`make-steamos-sm8650.sh:141-145`). Afterwards they restore setuid bits
  (`:291-313`) and truncate machine-id (`:440`) [M-static].
- **Reverie keeps btrfs.** It sets `btrfs property set ro false` and strips
  the by-partsets, `/persist`, `/home`, `/var`, `/efi` and `/esp` fstab
  lines (`assemble-reverie.sh:136-142,246-253,368-376`) [M-static].

## systemd units masked

**basit** (`apply-overlays.sh:266-292`) [M-static]:
- `deckard-*`: audio-setup, fan-control, fpga, led-control, typec-logger,
  charger, power-monitor, boot-images;
- `steamvr-*` system units;
- `set-wifi-mac-address`, iwd;
- adbd, usb-gadget;
- **`steamos-boot`** (it waits 90 s for `by-partsets/self/efi`), `efi.mount`,
  `esp.mount`, `systemd-repart`.

**Reverie also masks:** `home`, `var`, `persist` and `syspersist` mounts,
`steamos-offload.target`, `steamos-boot-registration`, growfs,
`journal-flush`, fstrim (`assemble-reverie.sh:177-229`) [M-static].

**Updater stubs (basit):** `jupiter-initial-firmware-update`,
`jupiter-dock-updater`, a custom `steamos-update` and
`steamos-select-branch`, which avoids atomupd hanging Steam
(`apply-overlays.sh:213-248`) [M-static].

No port touches kernelsetup, splctl, bootenv or rauc masking [M-static,
grep]. Our FS-R-001 isolation remains our own requirement.

## Firmware

**Quest1 (vendor kernel)** (`device/holo-android-blobs.sh:8-27`,
`holo-android-modem.sh:14-63`) [M-static]:
- read-only system and modem partitions;
- a `/run/fw` symlink farm, with `firmware_class.path` pointed at it;
- `/sys/class/firmware/timeout`=2;
- `/dev/subsys_modem` held open; `irsc_util`, `pd-mapper` and
  `tftp_server` run;
- **never stop the modem.**

**Do not copy** basit's adbd/usb-gadget masks. Valve's own `usb-ncm-gadget@`
needs `/etc/systemd/system/adbd.service.d/steamos-devkit-enabled`
[M-static].

[O] Does Valve's Turnip build include the KGSL backend? Only the string
`kgsl_profiling_suballoc` was found.

## Not applicable to a Quest

DTB selection by model, FAT KERNEL partitions, UFS installers, mainline DTS, and LSE emulation.
