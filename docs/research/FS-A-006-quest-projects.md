# FS-A-006 research — Quest-specific projects (Quest1-SteamOS, quest-kexec)

Agent report, 2026-10-08. Sources were read offline.
- **Q1** = nicolas-riera/Quest1-SteamOS at `b7467ff` (2026-10-07).
- **QK** = YusufOzmen01/quest-kexec at `e61edbd` (2026-10-04).

**Premise correction:** QK boots a second copy of Meta's **Android** on a
Quest Pro, using kexec and a patched 4.19 kernel. It contains no SteamOS
work. Its lessons still apply: Meta peripherals running without the normal
boot path.

## How userspace ran, and on which kernel

- **Q1: full systemd as PID 1.** The initramfs mounts userdata, loop-mounts
  `/data/steamos/holo.img` (ext4 without `metadata_csum`), and runs
  `switch_root` (`initrd/init:61-83`; `docs/rootfs-build.md:12`) [M-static].
- **Q1 kernel:** Meta's 4.4 source, rebuilt (`kernel/steamos.config:4-39`).
  - Added options:
    - SYSVIPC, POSIX_MQUEUE;
    - UTS, IPC, PID and USER namespaces;
    - CGROUP_PIDS/DEVICE, CHECKPOINT_RESTORE, BPF_SYSCALL;
    - FHANDLE, DEVTMPFS (automount off), AUTOFS4;
    - OVERLAY, SQUASHFS, BTRFS, BINFMT_MISC, VETH;
    - USB ACM, HW_RANDOM. Without HW_RANDOM, `systemd-random-seed`
      blocks for about 40 s.
  - Backports for systemd 258: statx and the pidfd family. These are not
    needed on 5.10 [D].
  - A cgroup2 mount-option tolerance patch ("PID 1 freezes" without it).
  - Synthetic uevents for udev coldplug.
  - LSE atomics emulation, for an ARMv8.0 CPU [M-static].
- **QK:** Android init via `switch_root`. Chroot mode "does not get far"
  without PID_NS (`initramfs/os/qkx-launch-android:4-16,34-41`) [M-static].

## Power, thermal and fan

- **Q1:**
  - Android's thermal, power and perfmgr HALs are not run [D].
  - **The fan driver stops the fan on FB_BLANK_POWERDOWN.** They blank with
    HSYNC_SUSPEND instead (`0835027`, `comp_window_mdp.c:193-196`)
    [M-static].
  - The GPU devfreq governor `msm-adreno-tz` never ramps up without
    Android. They force `performance` (`comp_window_mdp.c:147-151`)
    [M-static].
- **QK:**
  - **The ADSP must be started explicitly.** They use `subsystem_get("adsp")`
    via a hold module, with firmware from the modem_a image, plus pd_mapper
    and per_mgr. Without it there is no adsprpcd transport, and audio PDR
    fails (`qkx-launch-android:43-62`; `docs/KEXEC_ANDROID_WORKING_SETUP.md:207-210`)
    [M-static].
  - A declared but absent Dock/charging HAL blocked `VrPowerManagerService`
    (the black-screen root cause, `WORKING_SETUP.md:34-48`) [M-static].
  - The SMB5 charger needed fixes after kexec (`patches/0002-0003`). The
    Quest Pro uses an in-kernel SMB5 charger, unlike the Quest 3 [D].

## Display and GPU

- **Q1:** Monado drives MDSS fbdev ioctls. The Adreno blob runs through
  libhybris, which needs:
  - read-only system_a and modem_a, with `firmware_class.path`;
  - a synthetic property area;
  - hwservicemanager, gralloc and configstore (libvulkan waits forever
    without configstore);
  - kgsl and ion accessible to the `render` group;
  - SyncBoss telemetry turned off.

  Sources: `device/holo-android-blobs.sh`, `holo-android-hals.sh`,
  `docs/steam-gpu.md:52`, `docs/syncboss-imu.md:66-70` [M-static].
- **QK:** DRM was brought up twice before the composer
  (`qkx-launch-android:63-73`) [M-static].

## Pitfalls [M-static]

- **Q1:**
  - Never stop a Qualcomm subsystem started from Linux. A modem reload hangs
    the SoC (`device/holo-android-modem.sh`).
  - Swap on a file thrashes; use zram (`holo-perf.sh`).
  - systemd-resolved is masked on 4.4.
  - The pacman sandbox is off (no Landlock).
- **QK:**
  - Modules built for its own kernel fail `module_layout`, so 12 audio
    modules had to be rebuilt (`WORKING_SETUP.md:478-488`).
  - QSEE/SPSS are disabled in the DT.
  - `hotplugd` is needed by the sensors HAL.
  - The boot watchdog is disarmed from userspace.

## Transfer to the Quest 3

- **Charging runs on the ADSP.** The Quest 3 config has
  `QTI_BATTERY_CHARGER=m`, `QTI_PMIC_GLINK=m`, `QCOM_GLINK=m` and
  `QCOM_Q6V5_PAS=m` (`kernel.config:2989,5651,5649,5502`) [M-static].
  Charging and battery reporting run through ADSP firmware over pmic_glink,
  and the remoteproc loader is a module [D]. Starting the ADSP with the
  stock vendor_dlkm modules keeps vermagic intact [D].
- **More gaps in the stock config, beyond FHANDLE, DEVTMPFS, BTRFS and
  AUTOFS:** PID_NS, USER_NS, SYSVIPC, CGROUP_PIDS/DEVICE,
  CHECKPOINT_RESTORE, SQUASHFS [M-static, per the agent].
- **Options for userspace on the stock kernel:**
  - an ext4 root image;
  - a static or mdev `/dev`;
  - accept that systemd degrades;
  - or rebuild the kernel, at the cost of vendor-module vermagic and
    module_layout compatibility [D].
- **Transfers directly:**
  - read-only firmware partitions with `firmware_class.path`;
  - an NCM+ACM rescue shell that survives `switch_root`;
  - zram (`ZRAM=m`);
  - never stopping started subsystems;
  - avoiding declared-but-absent HALs.
- **To check on the Quest 3:** whether fan control is tied to the display
  blank state [C].
- **Does not transfer:**
  - the Q1 4.4 syscall backports and LSE emulation;
  - the fbdev display path (the Quest 3 has `FB` and `DRM_MSM` off, so the
    display is likely the techpack `msm_drm` module [C]);
  - QK's kexec-specific fixes.
- **[O]:** the cause of the bq27xxx "IO lines in bad state" error.
