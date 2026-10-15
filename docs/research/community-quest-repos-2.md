# Community Quest repos, pass 2: everything outside the display path

*Edited for publication: names and links removed or paraphrased.*

Agent report, 2026-10-10. A non-display review of the two community repos,
plus the two forks of them that turned up during this pass. Every source was
read offline. Nothing was built or run, and no device was touched. Display,
DSC, compositor and mesa scan-out topics belong to the separate
oculus-linux-kernel review and to `display-clues-kexec-quest1.md`. This note
only flags them where they meet a non-display item.

## Sources and what changed

| Short | Repo | Read at | Change since our last read |
|---|---|---|---|
| **Q1** | nicolas-riera/Quest1-SteamOS | `b7467ff` (2026-10-07) | **none**: `main` and tag `build-2` are still `b7467ff` (`git ls-remote`, 2026-10-10) |
| **QK** | YusufOzmen01/quest-kexec | `e61edbd` (2026-10-04) | **none**: `main` and tag `v1.0.1-qpro` are still `e61edbd` |
| **QK2** | machachu56/quest-kexec-q2, branch `quest2-port` | `9c96c19` (2026-10-07) | **new to us**: 20 commits on top of `e61edbd` that port QK to the **Quest 2** and run Steam Frame userspace on it |
| **NQ1** | Noculus-VR/Quest1-SteamOS | `4734634` (2026-10-10) | 4 commits on top of `b7467ff`, CI only (`.github/workflows/main.yml`) |

Clones (source only, read-only):
`%TEMP%\claude\...\scratchpad\dl\{q1-steamos-r2,quest-kexec-r2,qkx-q2-fork-r2,noculus-q1-fork-r2}`.

For cross-checks against our own material I used:
- our Meta kernel trees in WSL (`~/work/kgate27/src` = Quest 3 v2.7 5.10.246;
  `~/work/kgateq2/src` = Quest 2 4.19.325);
- the stock configs in `firmware/quest{2,3}/.../kernel.config`;
- the first-stage fstabs in WSL (`~/work/fs-unpack/v66a/.../fstab.eureka`,
  `~/work/kgateq2/ref/rd/fstab.hollywood`,
  `~/work/kgateq3s/ref/x/rd/first_stage_ramdisk/fstab.panther`);
- the Frame rootfs copy `~/sfroot-full`.

Tags follow FS-R-001:
- **[M-static]**: read in a named file, with a line or commit reference;
- **[C]**: the repo's own claim, not verified by us (the repos' own tags
  [H]/[M]/[L]/[V]/[I] all count as [C] here);
- **[D]**: our inference;
- **[O]**: open.

Device abbreviations: Q3 = Quest 3 (5.10, SDE, XR2 Gen 2), Q2 = Quest 2 and
QPro = Quest Pro (4.19, XR2 Gen 1, `qcom,kona`), Q1 = Quest 1 (4.4, MSM8998).

---

## 0. Answers in brief

1. **Neither upstream repo has moved.** Everything new is in QK2. That fork
   runs the Steam Frame userspace on a Quest 2, as a chroot under Alpine. It
   drives SyncBoss (IMU and Touch) **without any Meta library**, gets Turnip on
   KGSL working, has 3DoF Monado, and streams the tracking cameras. It is the
   closest prior art to FrameShift's Quest 2 stage, and it is not yet in our
   index.
2. **Rootfs storage on Q2/Q3/QPro is the open problem.** Q1's
   approach (mount userdata, loop-mount `holo.img`) only works because the
   Quest 1's Android 10 has no metadata encryption. Q3 userdata is ext4 with
   `metadata_encryption=aes-256-xts:wrappedkey_v0` and FBE v2
   (`fstab.eureka`, v66) [M-static]. A fastboot-booted Linux cannot mount it
   [D]. QK writes images straight to the raw blocks of a pinned file and
   rebuilds them with dm-linear in the initramfs
   (`tools/device/qkx_fsmap.c:1-19`, `qkx_rawcp.c:1-17`, `qkx-mount-os:1-9`)
   [M-static]. *(Adopting that route for FrameShift was **not concurred**,
   FS-R-011 §7 D4, 2026-10-11, J-104. Offline investigation only; external
   USB storage or storage on dedicated Unit 2 are the alternatives to
   investigate. `docs/research/valve-image-slot-in.md` §4.3.)*
3. **The SyncBoss MCU protocol is the same on Q1 and Q2.** The command and
   packet numbers match across two independent RE efforts:
   - IMU enable is 110 (0x6e);
   - start controller radio / beacon mode is 133 (0x85);
   - headset IMU packets are type 80 (0x50);
   - controller packets are type 143 (0x8f).

   Sources: Q1 `docs/syncboss-imu.md:20`, `controllers-native.md:48,94`; QK2
   `docs/QUEST2_PORT.md:353-363` [M-static]. Q3 ships the same driver family
   (`CONFIG_SYNCBOSS*`, `META_SWD_SYNCBOSS_NRF52XXX`, Q3 `kernel.config:5247-5259`)
   [M-static]. Its protocol is likely close but unverified [C/O].
4. **Most Q1 kernel backports are not needed on Q2/Q3.** Our own trees
   [M-static] show:
   - Q2 4.19 already has `statx`, `pidfd_send_signal` and `pidfd_open`
     (`unistd.h:733-742`);
   - both Q2 and Q3 KGSL have timeline ioctls (`kgsl_timeline.c` present);
   - both `f_ncm.c` already initialise `ndp_sign` (Q2 `:532`, Q3 `:540`).

   The Frame's systemd 257.7 probes `memory_recursiveprot` before using it
   (strings in `libsystemd-shared-257.7-2.2.so`) [M-static]. Q2 4.19 accepts
   `nsdelegate` (`cgroup.c:1868`) [M-static], so Q1's cgroup2 patch is
   unnecessary there [D]. What Q2/Q3 still lack is the config list (§1.3).
5. **Thermal safety is confirmed by an independent party.** QK2 found that on
   Q2 "CPU thermal zones use the user_space policy, so nothing throttles" once
   Android's thermal-engine is gone. They capped clocks by hand
   (`rootfs/etc/local.d/qkx-thermal.start:1-9`; `QUEST2_PORT.md:227-230`)
   [M-static/C]. This matches our thermal design (§6). None of the repos has a
   fan policy.
6. **Meta's own hand tracking is reachable in two ways:**
   - QK proved it in a full alternate Android on QPro
     (`hand_tracking_opt_in 1`, `KEXEC_ANDROID_WORKING_SETUP.md:300-308`) [C];
   - Q1 mapped a container-free route: Meta's `trackingservice` plus a single
     stub binder daemon ("Path M", `docs/tracking-6dof.md:65-178`) [C].

   Both depend on Meta's power-state, proximity and TE gates (§4.4).
7. **Licensing.**
   - QK and QK2 are GPL-2.0, and QK2's Monado driver is BSL-1.0.
   - Q1 has **no licence file**. Only its kernel patch (GPL-2.0, README) and
     its Monado patch (BSL-1.0, SPDX) are licensed. Everything else is all
     rights reserved by default [D].
   - QK's v1.0.1 release ships a 1.78 GB "ROM" ZIP, i.e. modified Meta Android
     images (§8). FrameShift must not use it.

---

## 1. Boot, init, rootfs, kernel config

### 1.1 Initramfs and PID 1

- **Q1** [M-static, `initrd/init:1-89`]:
  - busybox init; configfs gadget NCM+ACM with IAD class codes `0xEF/0x02/0x01`
    (`:26`); `udhcpd`, `telnetd` and a respawned shell on `ttyGS0`;
  - `holo` mode: mount userdata (found by `PARTNAME=userdata`), `losetup` +
    mount `holo.img`, `mount --move` of `/dev /run /proc /sys`, then
    `switch_root` to `/usr/lib/systemd/systemd --log-target=kmsg` (`:61-83`);
  - a busybox `telnetd` + `udhcpd` rescue path is chrooted into the new root
    before the switch, so it survives `switch_root` (`:75-82`);
  - mount failure leaves the initramfs shell running (`:85-89`).
- **QK** [M-static, `initramfs/init.sh:1-104`]:
  - ECM-only gadget with fixed MACs, so the host interface name stays stable
    (`:37-40`);
  - a `telnetd` respawn loop, because the new OS shares the process table and
    "has killed it before" (`:74-76`);
  - only PID 1 may `switch_root`, so the launcher touches `/tmp/qkx-launch`
    and the init loop execs `qkx-switch` (`:102-104`);
  - a watchdog disarm/keepalive/warm-reset control through
    `/proc/qkx_bootdone` from their kernel patch (`:22-24`).
- **QK2** adds on Q2:
  - init falls back to the shell if `rootfs.map` fails (`QUEST2_PORT.md:202`);
  - init warm-resets if the host does not configure the gadget within 30 s;
  - LED colours mark the init stages (`:174-178`) [C].
- **Transfer.** All three match FS-A-004's design. Two items are new to us:
  1. the busybox rescue daemons chrooted into the new root before
     `switch_root` (Q1);
  2. respawning the shell because the new OS kills it (QK).

  Both help Q3/Q2 stage 2 debugging. Both are independent of SoC and kernel
  [D].

### 1.2 Rootfs layout and storage

- **Q1 (Quest 1).** It mounts userdata ext4 rw and loop-mounts
  `/data/steamos/holo.img` [M-static, `initrd/init:62-65`]. The image is ext4
  without `metadata_csum`/`metadata_csum_seed`/`orphan_file`
  (`tools/mkholo.sh:7`). `/data/steamos` is "a new top-level directory, so it
  is not file-based-encrypted" (`docs/rootfs-build.md:78-79`) [C]. The proposed
  `install` mode would receive `holo.img.xz` over the USB network into
  userdata (`rootfs-build.md:71-85`; not implemented) [M-static].
- **QK (QPro).** Userdata is "metadata-encrypted by dm-default-key and
  file-encrypted by FBE, so a kexec'd kernel cannot read the filesystem at all"
  [C, `qkx_fsmap.c:4-6`]. Their method [M-static, `qkx_fsmap.c`, `qkx_rawcp.c`,
  `tools/device/qkx-install.sh`, `qkx-mount-os`]:
  1. create the file on f2fs, pin it (`F2FS_IOC_SET_PIN_FILE`) and allocate
     it fully;
  2. list its extents (FIEMAP);
  3. write the image **to those raw partition blocks** (`qkx_rawcp copy`),
     then verify it;
  4. in the initramfs, rebuild the file with dm-linear and mount it.

  Further details:
  - the userdata device is "verified 1:1 under dm-default-key"
    (`qkx-install.sh:17`);
  - from Android these files "look like garbage, which is expected" (`:5-7`);
  - `/metadata` is a tmpfs, "the real one holds the stock OS's encryption
    keys" (`qkx-mount-os:8-9`);
  - the vendor fstab is rewritten to drop `/metadata`
    (`qkx-patch-fstab:24-38`, file-relative).
- **QK2 (Q2).** The same pinned-image method boots Alpine (8 GiB) and a 24 GiB
  SteamOS image. Q2 userdata is `sda9`, resolved by name
  (`QUEST2_PORT.md:183-202,316-321`) [C].
- **Our fstabs** [M-static]:
  - Q3 (`fstab.eureka`, v66) and Q3S (`fstab.panther`): userdata **ext4**,
    `fileencryption=...v2+inlinecrypt_optimized+wrappedkey_v0`,
    `metadata_encryption=aes-256-xts:wrappedkey_v0`, `checkpoint=block`;
  - Q2 (`fstab.hollywood`): userdata **f2fs**, `fileencryption=ice:aes-256-cts:v1`.
    Its keydirectory is under `/metadata/vold/metadata_encryption`, but there
    is no `metadata_encryption=` option.
- **Transfer.**
  - **Q3/Q3S** [D]: Q1's direct mount fails. Hardware-wrapped keys mean Linux
    can never decrypt userdata. Adapting the QK route was not concurred
    (FS-R-011 §7 D4) *[removed for publication]*. The alternatives are
    external USB storage or a partition we may legitimately use, which needs
    a Chair ruling.
  - **Q2**: the QK2 recipe is proven on the same hardware [C]. Without
    metadata encryption the f2fs metadata may be plaintext [D].
  - **QPro**: proven [C]. **Q1**: Q1's mount route works [C].
- **ext4 feature flags.** Images for 4.19/5.10 must be made with
  `-O ^orphan_file` (the feature arrived in 5.15). QK2 also disables
  `metadata_csum_seed`, `casefold`, `fast_commit` and `large_dir`
  (`tools/steamos-rootfs.sh:75-77`) [M-static]. For Q3, `^orphan_file` is the
  one that matters [D].

### 1.3 Kernel config fragments

- **Q1 fragment** [M-static, `kernel/steamos.config` (39 lines)]:
  - SYSVIPC, POSIX_MQUEUE;
  - UTS/IPC/PID/USER namespaces;
  - CGROUP_PIDS, CGROUP_DEVICE, CHECKPOINT_RESTORE, BPF_SYSCALL;
  - FHANDLE, DEVTMPFS (automount off), AUTOFS4;
  - OVERLAY, SQUASHFS(XZ/LZ4), BTRFS, BINFMT_MISC;
  - VETH, `NETFILTER_XT_MATCH_ADDRTYPE`;
  - USB ACM/serial, HIDDEV, SND_USB_AUDIO, `HW_RANDOM_MSM_LEGACY=y`.
- **QK2 Q2 target config** [M-static, `kernel/patches/quest2/quest2_target_defconfig`,
  compared with our stock Q2 v2.7 config]:
  - adds SYSVIPC, POSIX_MQUEUE, PID_NS, USER_NS, IPC_NS, FHANDLE, DEVTMPFS and
    SOFTLOCKUP_DETECTOR;
  - does **not** add CGROUP_PIDS/DEVICE, AUTOFS, SQUASHFS, BTRFS, BINFMT_MISC,
    CHECKPOINT_RESTORE or USERFAULTFD (still unset);
  - the minimum for a SteamOS **chroot** plus the Steam client [C, `QUEST2_PORT.md:322`].
- **Our stock configs** [M-static]:
  - Q3 v2.7 lacks SYSVIPC, POSIX_MQUEUE, CGROUP_PIDS, CGROUP_DEVICE, USER_NS,
    PID_NS, CHECKPOINT_RESTORE, FHANDLE, DEVTMPFS, BTRFS, AUTOFS and SQUASHFS
    (`kernel.config:36,37,164,169,178,179,181,210,1717,6395,6422,6423,6494`);
  - Q3 already has BINFMT_MISC, VETH, OVERLAY, USERFAULTFD, BPF_SYSCALL,
    CGROUP_BPF, BINDERFS, ext4, `HW_RANDOM_MSM_LEGACY=m` and ZRAM=m;
  - Q2 v2.7 additionally lacks BINFMT_MISC and USERFAULTFD, and has F2FS=y.
- **Transfer.**
  - The Q1 fragment is a sound checklist for any rebuilt kernel on all
    devices.
  - For a **stock-kernel** Stage 2 on Q3, QK2 shows the Steam client runs in a
    chroot without systemd once SYSVIPC and namespaces exist. Q3 stock has
    neither SYSVIPC nor PID_NS, so even QK2's chroot route needs a rebuilt Q3
    kernel [D].
  - Every rebuilt kernel goes through the tools/kgate rules (FS-R-006).

### 1.4 systemd adaptations

- **Q1** [M-static, `kernel/backport_syscalls.py:1-9`, `quest1-kernel.patch` cgroup and kobject hunks]:
  - systemd 258 on 4.4 needed `statx`, `pidfd_open`, `pidfd_send_signal` and
    `waitid(P_PIDFD)`, a cgroup2 option-tolerance patch (`nsdelegate`,
    `favordynmods`, `memory_*`) and synthetic uevents (`kobject_synth_uevent`).
  - Userspace (`device/native-setup.sh`):
    - systemd-resolved is masked ("can't bind on 4.4", `:35-37`);
    - systemd-firstboot is masked and `machine-id` is pre-created (`:38-40`);
    - `serial-getty@ttyGS0` autologins root (`:24-29`);
    - systemd-networkd serves DHCP on usb0 (`:9-23`).
  - pacman's sandbox is disabled for lack of Landlock (`firstboot.sh:8-9`).
- **QK2** claims "Holo Core follows current Arch, whose systemd (≥258)
  requires Linux ≥5.4 with cgroup v2 only. The 4.19 vendor kernel cannot boot
  it unmodified" [C, `QUEST2_PORT.md:30-33`]. They therefore run SteamOS as a
  chroot from Alpine/OpenRC and never test systemd as PID 1 [M-static, `steamos-rootfs.sh:8-10`].
- **Our cross-checks** [M-static]:
  - Q2 4.19 has the pidfd/statx syscalls (above);
  - Q2's cgroup2 parser accepts only `nsdelegate` (`cgroup.c:1858-1876`);
  - Q3 5.10 accepts `nsdelegate`, `memory_localevents` and
    `memory_recursiveprot` (`cgroup.c:1896-1928`);
  - the Frame's systemd is **257.7**, not 258. It carries the message "This
    kernel version does not support 'memory_recursiveprot', not using mount
    option".

  [D]: the Frame's systemd needs neither the Q1 cgroup patch nor syscall
  backports on Q2/Q3. Q1 itself shows systemd 258 running as PID 1 on a
  patched 4.4 [C], so QK2's "cannot" is too strong. The real Q2/Q3 gaps are
  the config options in §1.3 [D].
- **Transfer to Q3:**
  - the masks for resolved and firstboot, and the pre-created machine-id
    (stage 2 headless target);
  - Landlock is absent in 5.10 too (introduced in 5.13), so pacman's sandbox
    would need the same change if pacman ever runs on the device [D].

### 1.5 Firmware paths, module loading, udev, cgroups

- **Firmware.**
  - Q1 links `system/vendor/firmware/*` and `modem_a`'s `image/*` into a
    single `/run/fw`. It sets `firmware_class.path` and
    `/sys/class/firmware/timeout`=2, because there is "no ueventd to answer
    the user-helper fallback" [M-static, `device/holo-android-blobs.sh:23-27`].
  - Absent prox calibration files otherwise stall SyncBoss open by 4× the
    fallback timeout (`syncboss-imu.md:66-68`) [C].
  - QK2 saw a stall of about 4 minutes and used a 1 s timeout
    (`QUEST2_PORT.md:350-351`) [C].
  - QK mounts a pinned, verified copy of `modem_a` read-only for the ADSP
    request, and never opens `modem_a` itself (`qkx-launch-android:43-62`)
    [M-static].
  - Transfer: all devices. Q3 has `FW_LOADER_USER_HELPER(_FALLBACK)=y`
    (`kernel.config:1727-1728`) [M-static], so the same stall applies [D].
    FS-A-004 rev 3 already handles fallback stalls.
- **Module loading.**
  - QK found that stock vendor dlkms fail `module_layout` on a rebuilt kernel.
    All 12 audio modules and `bcmdhd` had to be rebuilt and spliced into
    vendor images (`KEXEC_ANDROID_WORKING_SETUP.md:358-403,478-500`) [C].
  - Audio modules "must load during boot: late insertion missed the initial
    DSP/PDR readiness notification" (`:485-486`) [C].
  - Transfer: Q3 stock-kernel stages keep vermagic intact. A rebuilt Q3
    kernel inherits exactly this problem (tools/kgate) [D].
- **udev and device permissions.**
  - Q1 udev rules: `kgsl-3d0` and `ion` group `render` 0660;
    `binder|hwbinder|vndbinder` 0666 (`device/holo-steam-session.sh:93-103`,
    `holo-monado.sh:15-16`) [M-static].
  - QK2 simply `chmod 0666`s kgsl, ion and DRI (`rootfs/etc/local.d/qkx-gpu.start:1-5`)
    [M-static]. That is weaker; do not copy it.
  - Coldplug: Q1 backports synthetic uevents on 4.4. 4.19 and 5.10 already
    have them [D].
- **cgroups.** Silent beyond the cgroup2 option patch and the missing config
  items.
- **Paranoid network.**
  - Q1 and QK2 both add groups `aid_inet` 3003 / `aid_net_raw` 3004 to the
    Steam user (Q1 `device/firstboot.sh:3-7`; QK2 `steamos-rootfs.sh:43-47`)
    [M-static].
  - Q2 v2.7 has `CONFIG_ANDROID_PARANOID_NETWORK=y` (`kernel.config:929`)
    [M-static]. **Q3 v2.7 does not** (no match) [M-static].
  - Transfer: needed on Q2/QPro and Q1, not on Q3 [D].

### 1.6 cmdline and boot image

- **Q1** [M-static]:
  - boot image v0, kernel string `skip_initramfs` patched to `want_initramfs`,
    "abl always passes skip_initramfs on this legacy-SAR device"
    (`tools/build-boot.sh:99-100`);
  - `rng_core.default_quality=700` added (`tools/mknative.sh:39`);
  - AVB 1.0 signing of the boot image (`build-boot.sh:113-120`).
- **Release script** [M-static, `release/boot-quest1.sh:37-75`]:
  - refuses more than one device;
  - checks `ro.product.device` and `getvar product`, and requires an
    unlocked headset;
  - asks for Enter before `fastboot boot`;
  - never flashes.
- **Transfer.** The guard pattern matches ours. `skip_initramfs` is
  Quest 1-only (legacy SAR) [D]. Q2 v2.7's boot header and cmdline handling
  are already covered by our Q2 channel work.

---

## 2. GPU stack outside the display path

- **Q1 (Adreno 540, blob through libhybris).**
  - Setup [M-static, `docs/rootfs-build.md:38-45`, `device/holo-android-blobs.sh`,
    `holo-android-hals.sh`]:
    - libhybris built with the halium-11.0 headers ("version set to 10");
    - `system_a` mounted `ro,noload`, APEX bind-mounts, a pre-split property
      area (`tools/mkproparea.py`);
    - `hwservicemanager`, gralloc allocator and configstore run as systemd
      units ("libvulkan asks it ... and waits forever without it",
      `holo-android-hals.sh:6`).
  - `src/bionictls` parks a fake bionic TLS in glibc's `getrandom_buf` slot.
    That slot is unused only when the kernel has **no vDSO getrandom**
    (`bionictls.c:1-11`) [M-static].
  - Extension gating [C, `docs/adreno-vk-extensions.md:13-31`]: the blob hides
    extensions per SDK level and per "A5xx class", and `qgl_config.txt`
    overrides win. Timeline semaphores need KGSL ioctls 0x58-0x5d, which their
    4.4 lacks. **The blob never exports timeline or OPAQUE_FD semaphores**
    (SYNC_FD only).
  - GPU governor: `msm-adreno-tz` never ramps up without Android, so they force
    `performance` while presenting and restore `msm-adreno-tz` on stop
    (`comp_window_mdp.c:185-189`, `holo-monado.sh:37`) [M-static].
- **QK2 (Q2, Adreno 650).**
  - **Turnip on KGSL**, Mesa 25.1.9, `-Dfreedreno-kmds=msm,kgsl`;
    `vulkaninfo` reports Vulkan 1.3 [C, `QUEST2_PORT.md:235-243`].
  - Zink provides GL 4.6/EGL/GBM for the SteamOS image (`:328-333`).
  - Firmware `a650_sqe.fw`, `a650_gmu.bin`, `a650_zap.*` is copied into the
    rootfs, with no blobs in the repo [C].
  - Mesa patch: report the msm_drm node through `VK_EXT_physical_device_drm`
    (`patches/mesa/0001`). **This is display-path territory: handed to the
    display review.**
- **Our cross-check** [M-static]:
  - Q2 4.19 and Q3 5.10 KGSL both carry `kgsl_timeline.c` and
    `IOCTL_KGSL_TIMELINE_CREATE` (Q2 `msm_kgsl.h:1809`, Q3 `:1935`);
  - Q3 has `QCOM_KGSL=m`, `DMABUF_HEAPS=y`, `SYNC_FILE=y`, but no
    `DEVFREQ_GOV_QCOM_ADRENO_TZ` in its config (`kernel.config:3928,3929,4964,4968`);
  - Q2 has `ION=y`, `DEVFREQ_GOV_QCOM_ADRENO_TZ=y` (`:3996,4973`).
- **Transfer.**
  - **Q3 (A740) / Q2 (A650)** [D]:
    - QK2 shows Turnip-KGSL is the realistic GPU route on stock Meta kernels.
      That is also the Frame's own driver (`steamframe-stack.md:22`).
    - Turnip provides timeline semaphores and OPAQUE_FD natively, so Q1's whole
      compat layer (§3.2) would be **unnecessary** [D, needs a Turnip-on-A740
      KGSL check].
    - Whether Turnip's KGSL backend supports A740 in the Mesa version we pin
      is **[O]**.
  - libhybris on Q3 is a risk: Android 14 vendor, Q1 built against halium-11
    headers. Avoid it unless Path M (§4.4) is chosen [D]. 4.19 and 5.10 have
    no vDSO getrandom (it arrived in 6.11), so the bionictls assumption would
    still hold [D].
  - Governor: on Q3 the KGSL devfreq governor name and its autonomy without
    Android are **[O]** (FS-R-006 already lists GPU devfreq autonomy as [O]).
    Q1's force-performance-while-presenting is a candidate, bounded by our
    thermal policy, and never beyond spec.

---

## 3. VR runtime

### 3.1 Monado configuration

- **Q1** [M-static, `device/holo-monado.sh:18-43`]:
  - Monado `cfa6078` plus `quest1-monado.patch` (`rootfs-build.md:18`);
  - `monado-service` as a system unit with `UMask=0000` so the steamos user
    can connect;
  - `LD_PRELOAD=libbionictls.so`, `XDG_RUNTIME_DIR=/run/monado`;
  - `XRT_COMPOSITOR_SCALE_PERCENTAGE=85`, `XRT_COMPOSITOR_COMPUTE=0`: the
    graphics path takes 5.7 ms vs 17.7 ms for compute on the A540 (`:30-32`)
    [C];
  - `xr-run` wrapper for clients (`:46-52`).
- **QK2** [C, `QUEST2_PORT.md:388-406`]:
  - Monado pinned in `patches/monado/BASE` with a `quest2` driver;
  - fixed 1.6 m head height and Oculus Touch profile;
  - it must report 120 Hz (the panel mode) "or the motion judders";
  - Monado needs `/dev/bus/usb` to exist and is built without libusb.
- **Transfer.**
  - Monado as the device-side OpenXR runtime is the common choice on all
    three projects.
  - The systemd unit pattern (UMask, runtime dir) is reusable on Q3/Q2 [D].
  - The compositor and scale numbers are A540-specific and display-path.

### 3.2 The custom SteamVR driver (`src/steamvr-quest1`)

- **Architecture** [M-static, `driver_quest1.cpp:1-24`]:
  - `driver_quest1` is an **OpenXR client of Monado** inside vrserver;
  - poses come from `xrLocateSpace` at 250 Hz;
  - it declares identity distortion, so vrcompositor composites an
    undistorted side-by-side image;
  - frames arrive from a **simulated direct-mode display** implemented in the
    Vulkan layer (`src/vklayer-steamvr/quest1_display.c:1-17`) as OPAQUE_FD
    memory over a unix socket;
  - they are blitted into OpenXR swapchains, and Monado distorts and scans
    out;
  - pacing comes from `xrWaitFrame`.
- **Manifest and controllers.**
  - `hmd_presence ["*.*"]`, `alwaysActivate` (`quest1/driver.vrdrivermanifest`)
    [M-static].
  - Controllers are read back from Monado as OpenXR actions and exposed as
    `oculus_touch`, using SteamVR's own Touch profile
    (`docs/controllers-native.md:249-278`) [C].
- **Compat layer** (`quest1_compat.c:1-20`) [M-static]:
  - timeline-semaphore emulation (memfd counter + futex, one submit worker
    thread);
  - name-only extensions stripped at `vkCreateDevice`.
- **An internal contradiction (for the display review).**
  - `steamvr-port.md:197-205` argues that vrcompositor tolerates having no
    WSI [C].
  - The implemented driver says "vrcompositor 2.17 still needs a working
    direct-mode window" (`driver_quest1.cpp:12-13`), which is why the fake
    `VK_KHR_display` exists [M-static].
- **Status:** SteamVR at about 40 fps (README:17-18) [C].
- **Steam Frame pieces kept and replaced** [C, `docs/steamframe-stack.md`, README]:
  - **kept**: vrserver, vrcompositor, vrclient (also the OpenXR runtime for
    apps), vrwebhelper, the arm64 Steam client;
  - **replaced**:
    - `driver_cv.so` + `libArcturusPerception.so`: ARMv9 build with SVE and
      RCPC2, "unusable on the Quest" (`steamvr-port.md:94`);
    - gamescope's openvr session: Xvfb + `xscreen` quad layer instead;
    - Turnip: the blob instead.
  - QK2 plans the **reverse** direction: Monado's own `steamvr_drv` inside the
    SteamOS chroot (`TODO.md:37`) [C].
- **Transfer.**
  - **Q3**: Cortex-A715/A510 are ARMv9.0 with SVE2 and RCPC2. `driver_cv`'s
    ISA would probably execute [D]. Its hardware assumptions (`dsp_service`,
    `XRService`, Frame display FPGA over `spidev`, Frame cameras;
    `steamframe-stack.md:43-48`) make it unusable anyway [D].
  - **Q2/QPro**: v8.2 cores without SVE, so `libArcturusPerception` cannot
    run [D].
  - All devices need either a custom OpenVR HMD driver (Q1 pattern) or
    Monado-as-SteamVR-driver (QK2 plan). With Turnip on Q2/Q3, a
    vrcompositor-native path (real `VK_KHR_display`/KMS, as on the Frame) may
    remove the Q1 layer entirely.
  - Q1's driver source has **no licence**: learn from it, do not copy (§8).
- **The Frame stack map is reusable for every device.**
  `docs/steamframe-stack.md` [C] covers:
  - session startup (`:98-129`);
  - `steamvr.service` steps (`:111-119`);
  - required Vulkan extensions;
  - vrlink (V4L2 HEVC + dma-buf, `:68-94`);
  - FEX/Proton ARM64EC/Lepton (`:133-171`);
  - the Frame kernel config notes (`:173-178`).

  Of the 17 extensions vrcompositor requires on its default (non-facet) path
  (`steamvr-port.md:116-140`) [C], Vulkan 1.2/1.3 core is not needed, and
  `useFacetRenderer` must stay off on weaker GPUs. Use this as an offline
  checklist for Q3/Q2 GPU stage planning; verify against our own Frame rootfs
  copy before citing.

---

## 4. Tracking and input

### 4.1 SyncBoss (IMU, proximity, controller radio)

- **Q1, through Meta's `libsyncboss.so` via libhybris** [C, `docs/syncboss-imu.md`, `controllers-native.md`]:
  - `syncboss_init` with options `{0,0,1,1}`. Byte 3 turns telemetry **off**;
    otherwise init spins in `WaitForProperty` (`syncboss-imu.md:69-70`).
  - IMU enable is MCU command 0x6e. Records arrive at about 1 kHz in m/s² and
    rad/s, with a µs timestamp and temperature (`:17-61`).
  - Controller beacon mode is 0x85. The pairing list lives **on the MCU**
    (max 6, data reg 0x7c), with no host file (`controllers-native.md:13-24`).
  - Controller data is dropped silently if the controller firmware differs
    from what the library expects, unless
    `SYNCBOSS_DISABLE_FW_VERSION_CHECK=1` (`:110-114`).
  - Proximity: `/dev/syncboss_powerstate0` messages (PROX_ON=2/OFF=3)
    (`comp_window_mdp.c:68-71,209-226`) [M-static].
  - One owner only: "two stream pumps cannot coexist" (`tracking-6dof.md:49-56`).
- **QK2, with no Meta library: kernel nodes only** [C, `QUEST2_PORT.md:345-370`;
  M-static `monado/drivers/quest2/q2_driver.c:1-70`, `rootfs/usr/local/bin/qkx-controllers:1-40`]:
  - Setup: `transaction_length=512` (sysfs), keep `/dev/syncboss0` open, read
    `/dev/syncboss_stream0`, sequence alloc/release ioctls `_IOR(10,2)` /
    `_IOW(10,3)`.
  - Commands were found by a kprobe trace of the sensors HAL
    (`tools/syncboss/android-txtrace.sh`) and replay:
    - **110 [0]** enables headset IMU 0;
    - **133 [0]** starts the controller radio;
    - **90/203/204 crash the MCU**, and **46 stalls the stream**.
  - Packet formats:
    - IMU type 80: accel in g, gyro in deg/s;
    - controller type 143: `[key, flags, data]` records (0x24 buttons,
      0x63 trigger/grip inverted, 0x82 stick, 0x41 motion, 0x45 capacitive).
  - Controller IMU is an ICM-42686 at 1024 LSB/g and 8.2 LSB/dps; axes come
    from the controllers' TrackedObject calibration (`QUEST2_PORT.md:396-398`).
- **Transfer.**
  - **Q3/Q3S**: SyncBoss kernel modules ship (`SYNCBOSS_SPI/POWERSTATE/TIMESYNC/MISCFIFO=m`,
    `kernel.config:5252-5259`), and the driver directory matches Q2's file for
    file (`drivers/staging/oculus/mcu/syncboss/`, both trees) [M-static].
    QK2's library-free route is the **preferred first probe**: no libhybris,
    no Android 14 bionic [D].
  - On Q3 the bus, the start commands and the Touch Plus packet layout are
    **[O]**. Touch Plus has no IR ring, so tracking differs [C]. Finding them
    needs a kprobe on stock Android (an insmod is a state change, so it needs
    the PM's approval).
  - **Q2/QPro**: use QK2 directly (QPro SyncBoss is `spi0.0`, Q2 `spi1.0`,
    `QUEST2_PORT.md:16-17`) [C].
  - **Q1**: either route.
  - Safety: never replay unknown SyncBoss commands (§7).

### 4.2 Touch controllers

- **Q1**: full SteamVR `oculus_touch` mapping, an arm model, a two-pose IMU
  calibration, haptics through `syncboss_input_set_haptic`
  (`controllers-native.md:249-293`) [C].
- **QK2**: an Xbox-style uinput gamepad for Steam, plus Monado Touch
  (rotation and inputs). Haptics are not done [C].
- **Transfer.** QK2 for Q2/QPro now. A Q3 Touch Plus decoder is new work
  [D]. Cross-controller pairing (a PM requirement): pairing lives on the MCU
  and is done by Meta's `syncboss_input_pair` (Q1 says "Do not call") or by
  Android `OVRRemoteService` (`tracking-ipc.md:503-505`) [C]. The safest
  plan is to pair under stock Android and rely on the MCU keeping the list
  across reboots ([C] in Q1, still to be checked live).

### 4.3 Cameras

- **Q1**: all 4 OV7251 cameras, natively through libsyncboss +
  `libqcameraoculushal` (libhybris), 640×480 Y8, alternating HEADSET and LED
  exposures at 2×30 Hz (`tracking-6dof.md:17-63`; `src/qcam/qcam.c`) [C].
- **QK2**: the Q2 Spectra ioctl sequence is recorded on Android by a kernel
  module (`module/qkx_camtrace.c`) and replayed on Linux. All four stream at
  about 50 Hz RAW10. Auto exposure needs SyncBoss type-3 `a1` updates
  (`tools/camtrace/README.md`) [C].
- **Calibration.**
  - Q1: plain JSON in `/persist/calibration`, Rift S schema, parsed by
    Monado's `rift_s` (`tracking-6dof.md:85-87`) [C].
  - QK2: copy it from Android; "never mount persist from Linux"
    (`TODO.md:22-26`) [M-static].
- **Transfer.** 6DoF is beyond FrameShift's boot PoC (FS-R-001). Record both
  approaches for the tracking stage. For Q3 the camera stack is different
  silicon (5.10 camera techpack) [O].

### 4.4 Meta's tracking and hand tracking (PM requirement: keep Meta's models)

- **Q1 "Path M"** [C, `tracking-6dof.md:93-178`, `tracking-ipc.md:14-57,460-583`]:
  - `trackingservice` serves head, controllers, hands and haptics through
    ashmem regions. The public `libossdk.oculus.so` ABI is enough for a client.
  - It needs about five system_server binder services, which **one stub
    daemon** can answer. `vrpowermanager` must call back `onStateChange`
    with RUNNING.
  - It also needs the sensors HAL, `IIad`, `power@1.3`, `/persist` (a copy,
    never the raw partition rw), and fresh `/data/...` dirs.
  - Hand tracking runs inside trackingservice (Hexagon NN via fastrpc, models
    under `/system/etc/handtracking`), gated by the preference
    `hand_tracking_enabled`.
  - Gates:
    - **VrPowerManager mount state**;
    - **display TE**: the sensors HAL drops IMU data without TE timestamps,
      `/sys/bus/spi/devices/spi12.0/control/te_timestamp` on Q1;
- **QK (QPro), proven in a full alternate Android** [C, `KEXEC_ANDROID_WORKING_SETUP.md`]:
  - a declared-but-absent Dock HAL blocked `VrPowerManagerService`; the fix
    was to delete the VINTF fragment (`:32-63`);
  - `prox_close` broadcast, or `acquirePowerStateLock` (txn 3, type 1), gives
    HEADSET_MOUNTED (`:95-103,226-240`);
  - `trackingservice` needs `/data/misc/vision/insideout` (`:78`);
  - `hotplugd` must run (`:71,178-180`);
  - hand tracking with `oculussetting --set hand_tracking_opt_in 1` (`:300-308`);
  - ET/FT through a `TrackingFidelityService` transaction, CDSP online
    (`:104-113`).
- **Transfer.**
  - Both are Android-userspace routes: Q1 with stubs, QK with full Android.
  - On Q3, binder/binderfs exist (`ANDROID_BINDER_IPC=y`, `BINDERFS=y`,
    `kernel.config:6313-6314`) [M-static]. A Lepton-like container or Path M is
    possible in principle [D].
  - Q3 has `MSM_ADSPRPC=m` and no upstream FASTRPC (`:2719,1849`), so hand
    tracking's DSP path is the downstream one [M-static/D].
  - Licensing of Meta's models in a FrameShift release (have vs ship) stays
    **[O]**. Path M runs them from the device's own partitions, as Q1 does
    for every blob.

---

## 5. Audio, Wi-Fi/BT, USB, charging, battery, power

| Area | What the repos show | Transfer |
|---|---|---|
| **ADSP / audio** | **QK** [M-static]: `qkx-adsp-hold.ko` = `subsystem_get("adsp")` before Android init, with firmware from a pinned `modem_a` copy (`qkx-launch-android:43-62`); `pd_mapper` and `per_mgr`; 12 rebuilt audio dlkms; audible output on QPro [C, `WORKING_SETUP.md:478-489`]. **Q1**: no audio (README:40). **QK2**: TODO. | **Q2/QPro (4.19)**: PIL/SSR (`MSM_PIL=y`, `MSM_SUBSYSTEM_RESTART=y`, Q2 `kernel.config:4429-4430`), so the QK hold-module pattern applies [D]. **Q3 (5.10)**: `MSM_PIL`/`SSR` unset, `QCOM_Q6V5_PAS=m`, `QCOM_PDR_HELPERS=m` (`:5520,5615-5620`): the ADSP is a remoteproc started via sysfs or the modules, not `subsystem_get` [D]. QK's "load the modules before the PDR notification" lesson applies. Q3 charging and battery run through the ADSP over pmic_glink (FS-A-006), so **ADSP bring-up is a safety item on Q3, not just audio** [D]. |
| **Wi-Fi** | **Q1** (WCN3990 via modem) [M-static, `device/holo-android-modem.sh`]: `irsc_util`, `qrtr-ns`, `pd-mapper`, `rmt_storage`, `tftp_server`, a modem reference held on `/dev/subsys_modem`, then `servicemanager`+`vndservicemanager` ("cnss-daemon blocks in libbinder until a binder context manager exists", `:50-53`), then `boot_wlan`. **QPro** Broadcom BCM4389 `bcmdhd` (rebuilt module) [C]. **QK2**: TODO. | **Q3**: `CNSS2=m`, `QCA_CLD_WLAN=m` (`:2446,5270`), Qualcomm, not Broadcom [M-static]; the cnss-daemon/binder lesson probably applies [D]. **Q2**: `CNSS2=y`, `QCA_CLD_WLAN=m` [M-static]. Q1's modem route is MSM8998-only. Q1 also mounts `/persist` **rw** for the modem's RFS (`holo-android-modem.sh:25`); see §7. |
| **Bluetooth** | **QK**: BCM4361/4389 over GENI UART; a kexec UART RFR workaround limited to line 14 (`WORKING_SETUP.md:312-332`) [C]. | Kexec-specific. Q3: `MSM_BT_POWER=m`, `BTFM_SLIM=m` (`:1554-1555`) [M-static]. The repos are silent on Qualcomm BT. |
| **USB gadget** | **Q1**: NCM+ACM, IAD codes; `fix_ncm.py` for the 4.4 `ndp_sign` bug that Windows' UsbNcm hits (`kernel/fix_ncm.py:2-4`) [M-static]. **QK**: ECM only. Android's own gadget writes are sandboxed in a tmpfs `/config` so they cannot steal the debug gadget (`qkx-patch-usb:17-32`) [M-static]. **QK2**: a kexec PHY fix (`quest2/0004`) [M-static]. | `ndp_sign` is already fixed in Q2/Q3 `f_ncm.c` [M-static], so FrameShift needs no patch. Q2 v2.7 lacks `USB_CONFIGFS_ACM` (`:3628`) [M-static], which matches our NCM-only Q2 channel. QK's configfs sandbox is reusable **if** FrameShift ever runs Android daemons (Path M) beside its own gadget [D]. |
| **Charging / SMB5** | **QK**: SMB5 skips hand-run initial-status IRQ handlers after kexec; stale SPMI IRQs are disabled (`patches/0002-0003`) [M-static]. A declared but absent Dock/charging HAL blocked VrPower (above). `hvdcp_opti.rc` is hidden by default in the alternate Android (`qkx-patch-usb:34-48`) [M-static]. | Kexec-only. A fastboot-booted kernel gets a normal SMB5 probe [D]. Q2 `QPNP_SMB5=y` (`:2372`); Q3 uses the ADSP charger. Lesson for any Android-HAL route: remove declared-but-absent HALs [D]. |
| **Battery, PM, suspend** | **All repos are silent.** No battery daemon, no suspend. Q1 blanks panels only (Monado). QK2 lists "Battery, charging and thermal management" as TODO (`TODO.md:48`). QK2 disables **all deep cpuidle states** after kexec, because a CPU7 power-collapse wake failure soft-locked IPIs (`QUEST2_PORT.md:265-267`; `initramfs/init.sh` diff) [C]. | Nothing to reuse. FrameShift P10 (no suspend) stands. The cpuidle change is kexec-induced and raises power and heat; do not copy it to fastboot-booted kernels [D]. |
| **Memory** | **Q1**: a swap file thrashed; 1.5 GB lz4 zram at higher priority, `swappiness=60`, `page-cluster=0`; sshd `OOMScoreAdjust=-900`, `Nice=-10` (`device/holo-perf.sh:1-67`) [M-static]. Chromium's GPU budget capped at 192 MB (`holo-steam-session.sh:66-77`) [M-static]. | Reusable on all devices. Q3 has `ZRAM=m` + `ZSMALLOC=m` (`:1809,975`); Q2 `ZRAM=y` [M-static]. The sshd protection applies to our rescue channel [D]. |
| **Entropy** | Q1 `HW_RANDOM_MSM_LEGACY=y` + `rng_core.default_quality=700`, otherwise `systemd-random-seed` blocks for about 40 s (`steamos.config:38-39`; `mknative.sh:39`) [M-static/C]. | Q3 has `HW_RANDOM_MSM_LEGACY=m` (`:2710`). 5.10's jitter entropy makes a long block unlikely [D]; check in stage 2 logs. |

---

## 6. Thermal and fan

- **Q1** [M-static, `comp_window_mdp.c:193-196`; C]:
  - The Quest 1 fan driver (`drivers/platform/oculus/vs1-board.c`) stops the
    fan on `FB_BLANK_POWERDOWN`/`VSYNC_SUSPEND`.
  - Monado blanks with `HSYNC_SUSPEND` so the fan keeps running.
  - That is the only fan handling in the repo. There is no thermal daemon,
    and no governor work except GPU `performance` while presenting.
  - Already in `display-clues-kexec-quest1.md` §2.3.
- **QK**: none. The alternate Android runs Meta's own thermal stack.
- **QK2** [M-static, `rootfs/etc/local.d/qkx-thermal.start:1-12`; C, `QUEST2_PORT.md:227-230`]:
  - "CPU thermal zones use the user_space policy, so nothing throttles";
  - their mitigation is schedutil plus `scaling_max_freq` caps of 1.8048,
    1.9008 and 2.016 GHz (policies 0/4/7);
  - UFS devfreq is pinned to `performance` (a kexec hang suspicion);
  - 3 min of full CPU load reached 75.6 °C [C];
  - no fan handling at all, although `SENSORS_PWM_TACH_FAN=y` is in their
    config (`quest2_target_defconfig:4060`) [M-static].
- **Against FrameShift's fan policy** (temperature-driven, never stop the fan
  while hot, per-device Meta policy; `thermal-control-design.md`):
  - QK2 independently confirms our Q2 finding that `user_space` zones "do
    nothing without a daemon" (`thermal-control-design.md:677`) [D].
  - Their clock caps are **not** a policy: no fan, no skin or battery zones,
    no shutdown path. Do not copy them [D].
  - Q1's blank-mode trick is display-coupled. Our design is display-
    independent: the daemon owns the fan.
  - On Q3, the v2.7 fan driver caps at `silent_rpm` on blank (FS-R-006).
    None of the repos says anything about Q3.
  - **Nothing in these repos changes the thermal design.** One new data point
    for Q2: about 76 °C after 3 min under capped load with an unmanaged fan
    [C].

---

## 7. Pitfalls, lessons and safety-relevant behaviour

| # | Lesson | Source | Devices | Status |
|---|---|---|---|---|
| S1 | **Never stop a Qualcomm subsystem started from Linux**: "reloading the modem after a shutdown from Linux hangs the SoC (watchdog bite → panic → reboot into Android)". Q1 also sets `restart_level=RELATED` | Q1 `holo-android-modem.sh:14-16,32-33,61-65` [M-static] | all | already in FS-A-006 |
| S2 | **Do not mount `persist` from Linux**: on Q2 "it reset the headset (likely protected storage)". Copy calibration from Android. Q1, by contrast, mounts `private` (=/persist) **rw** for the modem RFS, and says to bind a copy for tracking, "never the raw partition rw" | QK2 `QUEST2_PORT.md:383-384`, `TODO.md:22-26` [C]; Q1 `holo-android-modem.sh:25`, `tracking-6dof.md` §1.4 [M-static] | Q2 (seen), likely all [D] | **new**: add to the forbidden list (no rw mount of persist, private or metadata) |
| S3 | **Never write `/metadata`**: it holds the stock OS encryption keys. QK uses a tmpfs | QK `qkx-mount-os:8-9` [M-static] | Q2/Q3/QPro | **new** rule |
| S4 | **SyncBoss commands 90/203/204 crash the MCU; 46 stalls the stream.** Never replay unknown commands. Never call pair, unpair or firmware-update functions (`syncboss_input_update_firmware` "Never call"). If Meta's sensors HAL or trackingservice run, set `persist.ovr.skipctrlfwupdate=1` | QK2 `QUEST2_PORT.md:354-356` [C]; Q1 `controllers-native.md:58-60`, `tracking-6dof.md` §1.4 [C] | all | **new**: the Meta-firmware analogue of FS-R-001's no-updater rule |
| S5 | Absent prox calibration files stall SyncBoss open for 4× the firmware timeout (Q1) or about 4 min (Q2): set a short timeout | Q1 `syncboss-imu.md:66-68`; QK2 `:350-351` [C] | all | covered by FS-A-004 rev 3 |
| S6 | Declared-but-absent HALs block services (Dock, DeviceCert). Configstore absence makes libvulkan wait forever | QK `WORKING_SETUP.md:32-63,159`; Q1 `holo-android-hals.sh:6` [C] | any Android-HAL route | already in FS-A-006 |
| S7 | Stock dlkms fail `module_layout` on a rebuilt kernel; audio modules must load before the PDR notification | QK `:358-403,485-486` [C] | rebuilt kernels | already known |
| S8 | **Shared-block ext4 vendor images**: direct replacement "can corrupt other files"; unshare with `e2fsck -E unshare_blocks` first | QK `WORKING_SETUP.md:493-496` [C] | any image edit | **new**: matches our FS-A-006 note that `shared_blocks` cannot be mounted rw |
| S9 | A Q2 watchdog **bite comes back cold** (RAM lost), so a retained log needs a bark → warm-reset path. A long power-key press is a cold reset that loses the log | QK2 `QUEST2_PORT.md:179-180,231-234`, `quest2/0007` [C] | Q2 (Q3 [O]) | relevant to our ramoops-loss findings on Q3 (no survival in 3 trials); a hypothesis to test, not a fix |
| S10 | PMIC power-off reason (PS_HOLD / PMIC_WD / UVLO / **TFT/OTST3 thermal** / faults) read on stock after a failed run tells reset causes apart | QK `tools/why-reset.sh:1-39` (file-relative) [M-static] | all | **new**: reusable read-only post-trial probe for our classifier (PM approval per headset-permissions) |
| S11 | Do not unbind `ufshcd-qcom` live (SError panic). Android's UFS shutdown hook breaks the next link-up after kexec | QK2 `QUEST2_PORT.md:195-206` [C] | Q2/Q3 [D] | kexec-specific except the unbind rule |
| S12 | Signature checks off: QK2's pacman.conf sets `SigLevel = Optional` | QK2 `tools/steamos/pacman.conf:6` (file-relative) [M-static] | n/a | **anti-pattern**: never in FrameShift |
| S13 | Hypervisor-assigned and secure memory: do not use GIVEBACK or arbitrary hyp reassignment. On kexec, dynamic reserved pools must be fenced (no-map) or the first touch hard-hangs the SoC | QK `KEXEC_RAM_12GB_RESCUE.md:127`; QK2 `QUEST2_PORT.md:219-225` [C] | kexec only | not applicable to fastboot boot (ABL places memory) [D] |
| S14 | Q1 notes the Frame image's pacman repos carry a token marked DO_NOT_SHARE: "do not use or distribute" | Q1 `docs/phase0-recon.md:22` [M-static] | n/a | consistent with our rule never to reproduce Valve credentials |
| S15 | LSE emulation (Kryo 280 is ARMv8.0) | Q1 `kernel/lse_emul.c` | Q1 only | Q2/Q3 have `ARM64_LSE_ATOMICS=y` [M-static] |

---

## 8. Licensing and redistribution

| Repo | Licence | Reusable code | Binaries in the repo | Valve/Meta material redistributed |
|---|---|---|---|---|
| **Q1** | **No LICENSE file.** GitHub reports none (API, 2026-10-10). README says the kernel and its changes are GPL-2.0 and the Monado patch follows BSL-1.0 (`README.md:159-161`). SPDX BSL-1.0 headers are only on the Monado files [M-static] | **Kernel patch and scripts under `kernel/`**: GPL-2.0, as a derivative of Linux [D]. **Monado patch**: BSL-1.0. **Everything else** (the SteamVR driver, vklayer, qcam, sbinput, sbimu, xscreen, bionictls, `device/`, `tools/`, docs): **no licence = all rights reserved** [D]. Read and learn only; ask the author before copying | none (sources only) | None per README (`:159-160`) and the release workflow (`prerelease.yml:75-76`) [M-static]. The release holds the boot image only (kernel + Debian busybox + init). `holo.img` is unpublished because Valve's Steam/SteamVR "cannot be redistributed" [C, `README.md:46-51`]. The docs describe RE of Meta libraries "for personal interoperability use only" |
| **QK** | GPL-2.0 (`LICENSE`) [M-static] | GPL-2.0: initramfs scripts, the `qkx_fsmap`/`qkx_rawcp`/`qkx_dm` sources, the loader. Usable with GPL obligations | `module/quest_kexec.ko.pre-adsp`, `module/ion_secmap.ko.off`, `tools/device/qkx_{dm,fsmap,rawcp}` (sources present), **`initramfs/os/qkx-splash`** (512 KB static NDK binary, **no source in repo**), **`tools/turnkey/QkxFrameworkOverlay.apk`** (**no source**) [M-static]. `vrmountlock` is referenced but not in the repo (`WORKING_SETUP.md:583`) | **Release v1.0.1-qpro** carries `qkx-quest-pro-rom-current.zip` (1,785,258,528 B) [M-static, GitHub API]. Per `docs/TURNKEY_PACKAGE.md:13-15,32-34` it holds "the five prepared Android images" = **modified Meta system/system_ext/vendor/odm/product** [C]. That is a redistribution of Meta proprietary software: **FrameShift must not download, use or point to it.** README: "AI has been used heavily" |
| **QK2** | GPL-2.0, inherited; the Monado driver files are SPDX BSL-1.0 (`monado/drivers/quest2/*`) [M-static] | GPL-2.0 tools and patches; BSL-1.0 Monado driver, **usable with attribution** | none added (all text, checked with `file`) [M-static] | It builds images from Valve's package repos (base rootfs + `deckard-steam-rel`, FEX, Frame Mesa; `steamos-rootfs.sh:15-20`, `pacman.conf:10-17`, file-relative), with no credentials in the files [M-static]. Valve binaries are not redistributed in the repo. Whether an image built that way may be shared is **[O]** (Chair/PM) |
| **NQ1** | none, as Q1 | CI that builds the **public part** of `holo.img` from the public Holo Core aarch64 preview rootfs, leaving out Steam/SteamVR [M-static, `.github/workflows/main.yml:1-60,244-248`] | none | none |

Implications for FrameShift [D]:
- **Do:** reuse GPL-2.0 code from QK/QK2 with attribution and GPL compliance,
  and BSL-1.0 Monado code.
- **Do not:** copy Q1's unlicensed code; touch QK's ROM release; reproduce any
  Valve repo token or credential; enable unsigned package installs.
- A public **Holo Core aarch64 preview** rootfs exists, which Q1 and NQ1
  build from. It may give FrameShift a base image that contains no Valve
  client binaries. How it relates to our "Valve stable channel" release
  policy needs a Chair ruling **[O]**.

---

## 9. Ranked reuse list

### 9.1 Adopt now: Quest 3 stage 2/3 (offline design work; any device action needs PM sign-off)

1. **Rootfs storage.** The pinned-file route was **not concurred**
   (FS-R-011 §7 D4, J-104) *[removed for publication]*. Investigate external
   USB storage or storage on dedicated Unit 2. Keep `/metadata` off-limits.
   *Stage 2, all.*
2. **Safety rules S2, S3, S4, S10 and S12** into `DEVICE_PORT_CHECKLIST.md`
   and PROJECT_SETUP §6A:
   - never mount persist, private or metadata rw;
   - never replay unknown SyncBoss commands or run Meta firmware updaters;
   - add PMIC PON-reason capture to the post-trial probe set;
   - never disable package signatures.

   *All devices, now.*
3. **Rescue-shell robustness.** Run busybox `telnetd`/`udhcpd` chrooted into
   the new root before `switch_root` (Q1 `init:75-82`), and keep a respawn
   loop (QK `init.sh:74-76`). *Stage 2, all.*
4. **Headless systemd target hygiene:**
   - mask resolved and firstboot, pre-create machine-id
     (Q1 `native-setup.sh:31-42`);
   - zram + sshd OOM protection (Q1 `holo-perf.sh`);
   - a short `firmware_class` timeout and a single firmware path.

   *Stage 2, all.*
5. **Kernel-config checklist** (Q1 `steamos.config` + QK2 defconfig delta),
   reconciled against Q3 stock (§1.3). This is input to the tools/kgate
   decision on whether Stage 2 needs a rebuilt kernel (SYSVIPC and PID_NS
   alone force one for the Steam client). *Q3 now, Q2/QPro lockstep.*
6. **SyncBoss library-free probe plan for Q3**: QK2's kprobe-on-`queue_tx_packet`
   tracing method plus replay of only the two benign start commands. Needs
   the PM's approval for the insmod on stock. *Stage 3+, deferred past the
   boot PoC per FS-R-001, but the plan can be written now.*
7. **ADSP-first ordering on Q3**: start the ADSP (remoteproc) and load
   pmic_glink and battery modules before userspace relies on charge or
   battery state (QK lesson, Q3 charger on the ADSP). *Stage 2, safety.*

### 9.2 Later: Quest 2 / Quest Pro

1. **QK2 as the Q2 reference implementation:**
   - SyncBoss IMU and Touch without Meta libraries
     (`monado/drivers/quest2/q2_driver.c`, BSL-1.0; `qkx-controllers`);
   - Turnip-KGSL + Zink build recipe (`tools/build-userspace.sh mesa|mesa-holo`,
     `tools/builder/Containerfile*`);
   - GTK2 build for `steamui.so` (`tools/steamos/build-gtk2.sh`), FFmpeg
     soname links, `lsof` for the webhelper.
2. Paranoid-network groups 3003/3004 (Q2 has `ANDROID_PARANOID_NETWORK=y`).
3. The ADSP hold-module pattern (`subsystem_get`) for 4.19 audio; audio
   modules loaded before PDR.
4. The camera record/replay method (`module/qkx_camtrace.c`,
   `tools/camtrace/`) for the later 6DoF stage. Calibration copied from
   Android, never by mounting persist.
5. QK's Android-HAL lessons (Dock/DeviceCert VINTF, `hotplugd`, `prox_close`,
   `/data/misc/vision/insideout`, configfs sandbox) for a Meta hand-tracking
   route.
6. **Not to reuse:** the kexec loader and its SMB5, UFS, PHY, GPU-RSC,
   reserved-memory and cpuidle patches. They exist only because of kexec.
   FrameShift fastboot-boots unlocked units.

### 9.3 Quest 1

1. Q1 is the full reference: kernel fragment, syscall backports, LSE
   emulation, `fix_ncm`, systemd PID 1, libhybris + bionictls + `mkproparea`,
   SyncBoss via libsyncboss, Monado driver, SteamVR driver and compat layer,
   Steam client on ANGLE-Vulkan.
2. **Licence caveat:** only the kernel parts (GPL-2.0) and the Monado patch
   (BSL-1.0) may be copied. For the rest, ask nicolas-riera for a licence
   before reuse.
3. The NQ1 CI builds the public part of `holo.img`, but it is untested.

---

## 10. Where the repos are silent, or claims are unverified

- **Silent in all repos:**
  - battery and charging management;
  - suspend and resume;
  - a fan control policy;
  - Q3-class hardware (5.10, SDE, XR2 Gen 2, Touch Plus, Qualcomm Wi-Fi 7 /
    BT on Q3);
  - Q3 SyncBoss bus and command set;
  - Q3 camera stack;
  - hand-tracking licensing.
- **Unverified claims that matter:**
  - QK2's "systemd ≥258 needs ≥5.4": contradicted in practice by Q1 on a
    patched 4.4;
  - the Q2 persist-mount reset cause ("likely protected storage");
  - Q1's MCU keeping the pairing list across reboots ([I] in their own tags);
  - Path M's stub sufficiency (never run);
  - the TE gate on Q2/Q3;
  - Turnip KGSL on A740;
  - QK2's 1-in-4 jump failures (unknown cause, kexec only).
- **Open for FrameShift:**
  - [O] KGSL devfreq governor behaviour on Q3 without Android;
  - [O] whether a public Holo Core base fits our release policy.

---

## 11. Proposed update to the memory index `community-work-index` (text only)

Replace the Quest 1 and "Examined 2026-10-08" lines and add a Quest 2 line:

> **Quest 2 / Quest Pro:** machachu56/quest-kexec-q2 branch `quest2-port`
> (`9c96c19`, 2026-10-07; GPL-2.0, Monado driver BSL-1.0). It kexecs a
> patched 4.19 on Quest 2 and runs Steam Frame userspace as a chroot. It
> drives SyncBoss with **no Meta libs** (cmd 110 = IMU, 133 = radio; 90/203/204
> crash the MCU) and has Turnip-KGSL+Zink, 3DoF Monado and camera
> record/replay. Do not mount persist. Its thermal is caps only. See
> docs/research/community-quest-repos-2.md.
>
> **QK (YusufOzmen01/quest-kexec `e61edbd`, unchanged 2026-10-10):** reuse the
> `/metadata`-as-tmpfs rule, the
> configfs sandbox, `why-reset.sh` (PMIC PON reasons). Do NOT touch its
> v1.0.1 ROM ZIP (modified Meta images). `qkx-splash` and the overlay APK
> have no source.
>
> **Quest1-SteamOS (`b7467ff`, unchanged; NO LICENCE except kernel GPL-2.0 +
> Monado BSL-1.0):** systemd 258 as PID 1 on 4.4, libsyncboss SyncBoss,
> SteamVR driver plus timeline-semaphore compat layer, Path M
> (trackingservice + binder stubs, for Meta hand tracking), Frame stack map.
> Its cgroup and pidfd backports are not needed on Q2/Q3 (checked in our
> trees). Fork Noculus-VR: CI for the public `holo.img` part only.

---

## Evidence index

- Clones: `scratchpad/dl/q1-steamos-r2` (`b7467ff`),
  `quest-kexec-r2` (`e61edbd`), `qkx-q2-fork-r2` (`9c96c19`, branch
  `quest2-port`), `noculus-q1-fork-r2` (`4734634`).
- Remote state: `git ls-remote` (2026-10-10). GitHub REST API for licence,
  releases and forks; release asset sizes as quoted.
- Our trees: WSL `~/work/kgate27/src` (Q3 5.10.246), `~/work/kgateq2/src`
  (Q2 4.19.325). The lines cited are in `include/uapi/asm-generic/unistd.h`,
  `kernel/cgroup/cgroup.c`, `drivers/gpu/msm/kgsl_timeline.c`,
  `include/uapi/linux/msm_kgsl.h` and `drivers/usb/gadget/function/f_ncm.c`.
- Configs: `firmware/quest3/extracted/v2.7-user_ota/kernel.config`,
  `firmware/quest2/v2.7-user_ota/kernel.config`.
- Fstabs: WSL `~/work/fs-unpack/v66a/vr/first_stage_ramdisk/fstab.eureka`,
  `~/work/kgateq2/ref/rd/fstab.hollywood`,
  `~/work/kgateq3s/ref/x/rd/first_stage_ramdisk/fstab.panther`.
- Frame systemd: WSL `~/sfroot-full/usr/lib/systemd/libsystemd-shared-257.7-2.2.so` (strings).
