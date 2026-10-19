# fs-blkguard: the boot-chain block-write guard (K1g), design and offline proof

Agent work, 2026-10-14/15, branch `feat/blkguard` (not merged). Milestone **K1g** (the plan's K1b):
`fs-blkguard` is built and proven **before any Valve software runs on a Quest** (PD-10, J-149).
Scope from J-119 (Quest boot chain and unit-unique partitions, on by default, an owner opt-out
that Valve code cannot trigger), FS-R-001 (never write boot-chain partitions), FS-R-011 D2
(the guard's known gaps) and FS-A-013 draft §3.3 (Chair class C9).

**Conduct.** Offline only: no device command, nothing on the PM's offline backup drive, nothing under `/persist`, no
download, no disassembly. Sources read: Meta's v2.7 kernel source (`~/work/kgate27/src`,
commit `dbc2bc83a`, 5.10.246), the stock v2.7 config, the Unit 2 GPT baseline.

**Tags (FS-R-001):** **[M]** measured on hardware (Android-side baselines already in the repo)
· **[M-static]** read from a named source file or artifact · **[D]** derived · **[C]** claimed
or inferred · **[O]** open. Test results are tagged **[T]** (offline run, log named).

Files: `tools/blkguard/` (patch, harness, probe, VM scripts, results). The patch is
`tools/blkguard/patches/0001-block-add-fs-blkguard-a-boot-chain-block-write-guard.patch`.

---

## 1. Summary

- A **source patch** to Meta's v2.7 kernel (GPL-2.0-only, our code): one new file pair
  (`block/fs-blkguard.c`, `block/fs-blkguard-policy.h`), one header
  (`include/linux/fs_blkguard.h`), and 82 added lines of hooks in 9 existing files; the only
  removed lines (3) are BLKROSET's second fetch of the user value. No struct, exported symbol
  or Kconfig symbol changes. Total 902 insertions.
- It refuses, while armed: write opens of guarded block devices, `write(2)`-family calls,
  `fallocate`, discard/secure-discard/zero-out ioctls, clearing read-only, partition-table
  changes (`BLKPG`, `BLKRRPART`), **every write-class bio** reaching a guarded device (the
  chokepoint under filesystems, dm, md, loop, swap and mmap), all SCSI pass-through except
  six identification commands (sd `SG_IO`, `SCSI_IOCTL_SEND_COMMAND`, bsg, `/dev/sg*`), all
  transport bsg requests (UFS BSG: query, UIC, descriptor writes), every SCSI host-driver
  ioctl (Meta's `ufs-qcom` `UFS_IOCTL_QUERY`, which can write `bBootLunEn`), START/STOP UNIT,
  `SG_SCSI_RESET`, eject/close-tray and persistent-reservation ioctls.
- **Identification by GPT partition name**, as parsed by the kernel's own EFI partition
  scanner, evaluated at each access (never device numbers). A disk that carries any protected
  name is **boot storage**: its whole-disk node and all its other partitions are guarded too,
  so a name missing from the list is still protected.
- **One-way.** Boot default `protect`. One arming request through `/proc/fs_blkguard` seals
  it; the mode can never be lowered; `strict` requires `kernel.modules_disabled=1`. There is no
  sysfs or proc off switch. The owner opt-out is the boot flag `fs_blkguard=off` (J-119).
- **CRC-neutral [T]**: kgate gate mode PASS on the patched Quest 3 build; Module.symvers
  byte-identical to the unpatched build (§8.1). **VM proof [T]**: QEMU aarch64 (generic arm64
  kernel) and UML, both from the same tree and commit, all configurations PASS, decoys
  unchanged; an unpatched kernel makes the probe ABORT; every hook mutant is detected (§8.3).

## 2. Policy

### 2.1 Modes and arming

| state | meaning | how it is reached |
|---|---|---|
| `off` | nothing guarded | boot flag `fs_blkguard=off` only (the owner opt-out; Valve code cannot change the command line of a `fastboot boot` image, and cannot write the boot partitions that would carry one) |
| `protect` | boot storage guarded; other disks free | **the boot default** (armed from the first instruction, before any disk is probed); or a request `protect [allow=...]` |
| `strict` | every block device guarded except the allowlist | a request `strict [allow=...]`, accepted only if `kernel.modules_disabled=1` |

- The **first accepted request seals** the guard: every later write to `/proc/fs_blkguard`
  returns `EPERM`. A request may never set a mode below the current one (`strict` →
  `protect`, anything → `off`: refused). Requests need `CAP_SYS_ADMIN` in the initial user
  namespace.
- Our initramfs sends exactly one request, then **reads the state back** and refuses
  `switch_root` unless it shows the expected mode, `sealed: 1`, the expected allowlist and
  `modules_disabled: 1`. A Valve process that runs later finds the guard sealed.
- **Unsealed protect at boot** is a deliberate safe default: if our initramfs failed to arm,
  boot storage is still guarded; the read-back check then stops the boot.

### 2.1a The module latch and the signing alternative (FS-R-013 §6(2))

- **`modules_disabled=1` is required for `strict` only.** The boot-default `protect` state does
  not require it: requiring it there would defeat the early protection (the guard is armed before
  any module can be loaded). The order for every strict arming (K1g, R-1): **load the complete
  required module closure first, then latch `kernel.modules_disabled=1`, then arm and seal, read
  the state back, and refuse the hand-off (`switch_root`; in K1g, the probe ABORTs) on any
  disagreement.** `protect` plus `modules_disabled` may be a later composition for reviewed Valve
  execution; `protect` with arbitrary module loading is **not** the equivalent boundary.
- **Correction (the signing alternative, FS-A-013 §3.3 as worded):** an already-built module
  *can* technically be signed without rebuilding its source (appending a signature with the
  kernel's `sign-file` and our key is a post-build step). Whether the kernel enforces signatures
  (`MODULE_SIG`/`MODULE_SIG_FORCE`, which is a kernel config change with its own CRC
  consequences), whether the module is ABI-compatible, its provenance, and the right to
  redistribute a modified (signed) vendor binary are **separate questions**. The earlier wording
  ("modules without published source could not be signed") conflated them. This does not change
  K1a/K1g's chosen approach: the latch, with no signing.

### 2.2 Identification

- **What is read [M-static]:** `hd_struct->info->volname`, filled by
  `block/partitions/efi.c` from the GPT entry name when the disk is scanned (UFS: when
  `ufs_qcom` probes; `SCSI_UFS_QCOM=m`, stock config :1980). The guard looks it up **live**
  at each decision under RCU, so a disk that appears late (asynchronous UFS probe, module load)
  is covered as soon as its partitions exist. No device number, LUN letter or major/minor is
  used anywhere (FS-R-001: "never transfer that device-node mapping").
- **Why names, not UUIDs:** names are what the Quest GPT is built from and what the measured
  baseline shows; per-unit UUID identity is not established [O]. The partition-type GUID is
  not kept by the 5.10 block layer.
- **Protected names** (`fsbg_protected_names[]`; a trailing `_a`/`_b` is ignored, matching is
  exact and case-sensitive): every boot-chain and firmware name of the Unit 2 v2.7 GPT [M],
  plus SM8550/Android names a later firmware may add (`init_boot`, `modem`, `dsp`, `cdsp`,
  `bluetooth`, `toolsfv`, `vbmeta_vendor`), plus the unit-unique and Android-state names of
  J-119 (`persist`, `ssd`, `vision`, `misc`, `keystore`, `frp`, `modemst1/2`, `fsg`, `fsc`,
  `devinfo`, `metadata`, `super`). `userdata` is deliberately **not** listed (C6).
- **Boot storage ("marker disks"):** a disk with at least one protected name. On the Quest 3
  that is every UFS LUN `sda`–`sdf` [D from the baseline]: `sda` carries `persist`, `misc`,
  `frp`, `super`; `sdb`/`sdc` the `xbl` copies; `sdd` `cdt`/`ddr`; `sde` the A/B firmware set;
  `sdf` `modemst*`/`fsg`. The harness checks all 87 measured partitions (§8.2).
- **Sticky marks:** once a disk's request queue has been seen carrying a protected name (at
  arming, every disk is evaluated; afterwards at every decision), it stays boot storage for the
  rest of the boot, even if its partitions disappear. This closes the review's sd unbind/rebind
  window, where a fresh gendisk on the same queue is writable before its partition scan
  (`protect` mode only; `strict` refuses unlisted disks anyway). Pointers are compared, never
  dereferenced; a reused pointer can only over-protect.
- **Partition tables cannot be changed under the guard:** `BLKPG` and `BLKRRPART` are refused
  on boot storage (and on everything in strict mode), so the kernel's partition view of boot
  storage stays what the scanner read from the unmodified disk. A re-scan after a device
  removal reads the same, unmodified GPT.

### 2.3 Verdict order (`fsbg_verdict`)

1. mode `off` → allow;
2. partition with a protected name → **deny** (never allowlistable; an allowlist entry naming a
   protected partition is rejected at parse time and ignored at decision time);
3. whole-disk node of boot storage → **deny** (covers the GPT headers, backup GPT and gaps;
   never allowlistable);
4. allowlist (`disk:<gendisk name>` for a whole-disk node; `part:<GPT name>` for a partition)
   → allow;
5. `strict` → **deny**; `protect` → deny on boot storage, allow elsewhere.

### 2.4 Allowlists

| use | request | effect |
|---|---|---|
| **R-1** (RAM root, PD-3) | `strict allow=disk:ram0` | only the brd node that holds the RAM root image is writable; dm-verity on top is read-only and needs no entry (FS-R-011 D2: "A verity target is read-only"); every UFS LUN, zram, loop and dm node is refused |
| later stages, after the Chair rules C6 | `protect allow=part:userdata` | boot storage refused except `userdata`; other disks free; dm devices on `userdata` work because the leaf decides |
| K1g probe boot | `strict allow=disk:ram0,disk:dm-200,disk:dm-201,disk:loop7,part:fsbg_decoy_rw` | decoy names only; no Quest partition is named `fsbg_decoy_rw` |

`disk:` entries are exact whole-disk names; they never cover the disk's partitions.

### 2.5 Errors, counters and log

- Refusals return **`EPERM`**. A write-class bio refused at `submit_bio_checks()` ends with
  `BLK_STS_IOERR`, which the writer sees as **`EIO`** (filesystem, dm, loop, mmap writeback).
- Per-path counters (`open`, `write`, `fallocate`, `discard`, `zeroout`, `roset`, `blkpg`,
  `rrpart`, `bio`, `scsi`, `sg`, `bsg`), a 32-entry ring of the last refusals (path, node,
  GPT name, reason, pid, comm) and a rate-limited `pr_warn`.
- `/proc/fs_blkguard` (0600) shows: mode, sealed, allowlist, `modules_disabled`, **build
  hazards** (§6), the counters, **the verdict for every block node and partition**, and the log.
  The verdict table is a zero-risk way to check identification on the device.

## 3. Coverage: every write path and where it is refused

All hooks run before the kernel's own mode and capability checks, so a refusal is counted even
for a caller the kernel would also refuse (this is what makes the probe design in §7 work).

| path | hook (file, function) | result |
|---|---|---|
| `open(O_WRONLY/O_RDWR)` of a node; in-kernel `blkdev_get*` with `FMODE_WRITE` (mount rw, swapon, dm/md table load, loop on a path, LIO iblock, `f_mass_storage` backing file) | `fs/block_dev.c` `__blkdev_get()` (not for the internal whole-disk open of a partition) | `EPERM` |
| `write`, `pwrite`, `writev`, `pwritev2`, AIO, io_uring, `sendfile`/`splice` into the node, `O_DIRECT` writes, writes by a loop worker into its backing node | `blkdev_write_iter()` | `EPERM` (also for descriptors opened **before** arming) |
| `fallocate` (zero range, punch hole) | `blkdev_fallocate()` | `EPERM` (before the page-cache truncation) |
| `BLKDISCARD`, `BLKSECDISCARD` | `block/ioctl.c` `blk_ioctl_discard()` | `EPERM` (before the `FMODE_WRITE` check and the page-cache truncation) |
| `BLKZEROOUT` | `blk_ioctl_zeroout()` | `EPERM` |
| `BLKROSET` clearing read-only (Valve's `blockdev --setrw` in `kernelsetup.sh`, `restore-calibration`, `factory_reset`) | `blkdev_roset()` | `EPERM`; setting read-only stays allowed |
| `BLKPG` add/delete/resize (native and compat) | `blkpg_do_ioctl()` | `EPERM` |
| `BLKRRPART` | `blkdev_reread_part()` | `EPERM` |
| **any write-class bio**: filesystems (incl. journal replay of a read-only mount and writes after a remount), dm/md remaps (incl. tables loaded before arming), loop, swap, page-cache writeback of `mmap(MAP_SHARED)`, `blkdev_issue_discard/zeroout` from any kernel caller | `block/blk-core.c` `submit_bio_checks()`, before partition remapping | `EIO`; empty `REQ_OP_WRITE` flushes pass (no data) |
| `SG_IO` on an sd node, `SCSI_IOCTL_SEND_COMMAND`, `CDROM_SEND_PACKET`, bsg on a SCSI device (`/dev/bsg/H:C:T:L`, incl. the UFS RPMB and boot well-known LUNs), `/dev/sg*` opened read-only | `block/scsi_ioctl.c` `blk_verify_command()`, before the `CAP_SYS_RAWIO` bypass | `EPERM` unless the opcode is TEST UNIT READY, REQUEST SENSE, INQUIRY, MODE SENSE(6/10), READ CAPACITY(10/16) or REPORT LUNS |
| `/dev/sg*` `SG_IO` and the legacy `write(2)` interface on an `O_RDWR` fd (which skips `blk_verify_command`) | `drivers/scsi/sg.c` `sg_new_write()`, `sg_write()` | `EPERM`, same opcode rule |
| **SCSI host-driver ioctls** reached through sd or sg (`scsi_ioctl()`/`scsi_compat_ioctl()` → `hostt->ioctl`): Meta's `ufs-qcom` `UFS_IOCTL_QUERY` (0x5388) accepts `WRITE_ATTR bBootLunEn` with no capability check [M-static, `drivers/scsi/ufs/ufs-qcom.c:2699-2727`, `:3447-3452`] (found by the adversarial review) | `drivers/scsi/scsi_ioctl.c`, before the dispatch (only when the host has an ioctl) | `EPERM`, all host ioctls |
| `SCSI_IOCTL_START_UNIT`/`STOP_UNIT`; `SG_SCSI_RESET` (sd and sg); `CDROMEJECT`/`CDROMCLOSETRAY` | `scsi_ioctl_common()`; `scsi_ioctl_reset()` (`scsi_error.c`), before its capability check; `blk_send_start_stop()` | `EPERM` |
| `IOC_PR_*` persistent reservations (PERSISTENT RESERVE OUT, which a device may keep across power cycles) | `blkdev_common_ioctl()`, by the node's verdict | `EPERM` |
| transport bsg: **UFS BSG** (`/dev/bsg/ufs-bsg*`: query requests incl. attribute/flag/descriptor writes such as `bBootLunEn` and the configuration descriptor, UIC commands), FC, SAS | `block/bsg.c` `bsg_sg_io()`, before the `CAP_SYS_RAWIO` check | `EPERM`, all requests |

Stock config facts that close other routes [M-static, `firmware/quest3/extracted/v2.7-user_ota/kernel.config`]:
`# CONFIG_DEVMEM` (:2714), `# CONFIG_KEXEC` (:440), `# CONFIG_HIBERNATION` (:540),
`# CONFIG_DEBUG_FS` (:7029), `# CONFIG_PROC_KCORE` (:6466), `# CONFIG_FUNCTION_ERROR_INJECTION`
(:7229, so no BPF `override_return`), `# CONFIG_BPF_LSM` (:233), `# CONFIG_KGDB` (:7031),
`# CONFIG_MMC` (:4715), `# CONFIG_MTD` (:1791), `# CONFIG_TARGET_CORE` (:2046), no NVMe,
`# CONFIG_MODULE_SIG` (:820). With `modules_disabled=1`, no new kernel code can be loaded,
so nothing can patch the guard's state.

## 4. FS-R-011 D2: the gaps the Chair named

| D2 gap | answer |
|---|---|
| write-open denial does not cover all mounted-filesystem writes | the bio hook refuses every write-class bio to a guarded device, whatever opened it; under R-1 no UFS filesystem is mounted read-write, and a rw mount is refused at open |
| device-mapper reconfiguration | a new table that opens a guarded device for write fails at open; a read-only table whose read-only flag is later cleared, or a table loaded before arming, still ends at the leaf bio check (tested: S1, S2, S3) |
| previously opened descriptors | checked at use (`write_iter`, `fallocate`, ioctls) and at the bio layer (tested: P-series with descriptors opened before arming) |
| SG_IO / UFS BSG and other pass-through | opcode allowlist at the common `blk_verify_command` chokepoint plus `sg.c`; all transport bsg refused; all SCSI host-driver ioctls (UFS query), START/STOP UNIT, resets and PR refused (tested: C-series in VM, Q6–Q14 on device) |
| GPIO, I2C and battery-NVM writers | **outside a block guard**: handled by the named controls (FS-A-013 §3.7; writer inventory) |
| one-way latch does not settle module/kexec bypass | `strict` cannot be armed unless `kernel.modules_disabled=1`; `KEXEC`/`KEXEC_FILE` not set; `/proc/fs_blkguard` reports any build hazard |
| writable dm allowlists need identity and backing-range constraints | the leaf decides: a dm device can be allowlisted by exact name, but its remapped bios are checked again against the device they reach, so an allowlisted dm can never write boot storage; R-1 needs no writable dm at all |

## 5. What stays allowed (the emergency shutdown design and the boot flow)

- **All reads** of every block device: `fs-thermald`'s read of `super` (`O_RDONLY` open,
  `pread`, `BLKGETSIZE64`; `emergency-shutdown-design.md` §7.3) is unaffected.
- **pstore**: `ramoops` is RAM, `/dev/pmsg0` is a character device; neither is a block device
  (design F29). The on-disk `pstore` partition (`sde49`) is protected; `PSTORE_BLK` is not set.
- **The thermal service's writes** are sysfs/hwmon/cpufreq/KGSL, the softdog and `reboot(2)`:
  not block devices.
- **The RAM root** (`ram0`) in R-1 via the allowlist; tmpfs `var`/`/etc`.
- Kernel-internal SCSI commands (sd's own `SYNCHRONIZE CACHE`/`START STOP UNIT`, UFS HPB) are
  not userspace pass-through and are not affected.

## 6. Not covered: residual risks of the guard itself

1. **Kernel code is trusted.** A kernel driver issuing SCSI commands internally
   (`scsi_execute`), or the secure world, is outside the hooks. After `modules_disabled=1` only
   Meta's built-in code and our own exists.
2. **Before the seal**, `protect` is active but an unsealed guard accepts one request from any
   `CAP_SYS_ADMIN` process. Only our initramfs runs then; the read-back check refuses
   `switch_root` if anyone else got there first.
3. **`protect` mode with modules loadable** (product, later) can be bypassed by a malicious
   module (J-119's "root is trusted" model); `strict` (R-1, K1g) cannot be armed that way.
4. **Device settings, not data**, remain writable by root through sysfs: sd `cache_type`
   (MODE SELECT, possibly saved by the device), UFS `wb_on` (a WriteBooster flag query),
   `rpm_lvl`/`spm_lvl`/`auto_hibern8`, UFS HPB tunables, `scsi_device` `delete`/`rescan`
   [M-static, `drivers/scsi/ufs/ufs-sysfs.c`, `drivers/scsi/sd.c`]. None writes a partition;
   Valve's writer inventory names no user of them. Masking them is possible later.
5. **Identification relies on the kernel's GPT parse.** If a LUN's GPT could not be parsed it
   would have no partitions, so in `protect` mode it would not be recognised as boot storage.
   In `strict` (R-1, K1g) it is refused anyway. The K1g pre-check requires every UFS node to
   show a `deny-*` verdict before anything else runs.
6. **Over-protection off the Quest (conservative, accepted for K1g and the isolated R-1
   experiment, FS-R-013 §6(4))**: a USB disk with a partition named, say, `boot` becomes boot
   storage in `protect` mode; SCSI pass-through and host ioctls are refused on every device while
   armed, and in `strict` every unlisted disk (USB disks included) is refused. This is
   deliberate over-protection for the experiments. A product-wide departure from the owner's
   narrower policy (J-119) needs its own usability and scope decision; the experimental acceptance
   does not settle the product default.
7. **Names are trusted as written by Meta.** A future firmware that renamed a partition to
   something unlisted would still be protected via its disk; one that moved a boot partition to
   a new LUN with no listed name would not be (in `protect` mode). Re-check the list against the
   GPT of every firmware we support.
8. **Not proven on the device yet** [O]: K1g is the on-device step (§7).
9. **PCI DMA** (review, speculative): `CONFIG_PCI=y`; root can reach a PCIe device's BARs and
   config space through sysfs and, if the SMMU allows, program DMA into kernel memory. Not
   closed by this patch (5.10 `LOCKDOWN_PCI_ACCESS` needs the lockdown LSM, not built) and not
   in the hazard list [O].
10. **Cost:** a write to a disk without protected names that is not on the allowlist (protect
   mode) compares its partition names against the list per bio; boot storage and the R-1
   allowlist hit early exits. Not measured on the device [O].
11. **What the guard does not settle (FS-R-013 §6(3), stated plainly):** the guard is a block
   and SCSI/UFS-pass-through boundary. It does **not** cover: device settings reachable through
   sysfs (item 4); **GPIO, I2C**, firmware loading and other **firmware/NVM** writers (battery
   NVM, SWD, EEPROMs: the writer inventory's named controls); **EFI variables** (no efivarfs in
   our images; the UEFI variable store is a protected partition, but a firmware-mediated path is
   not a block path); **PCI/DMA** (item 9); and any other privileged kernel or device interface.
   It assumes a **trusted kernel and secure world** (item 1). Guard counters and unchanged sampled
   hashes are evidence for the tested paths and ranges only; they do not prove the absence of
   firmware-level or persistent-setting effects. For R-1 the narrow console composition is
   preferred with UFS **unloaded** if the complete module/firmware/thermal closure permits; if UFS
   is loaded, the reachable device-setting sysfs paths are handled by activation review and
   access controls.

## 7. The K1g proof: `fsbg-probe` and its safety design

`tools/blkguard/probe/fsbg-probe.c` (static binary; runs as PID 1 or under our stage init).

### 7.1 Sequence (one boot, Unit 2 first, `fastboot boot`, PM present, PD-5)

1. **Pre-check, no armed guard test case attempted:** `/proc/fs_blkguard` exists and reports version 1; the boot
   state is `protect`, unsealed (or `off` when the run is meant to start unarmed); in device
   mode the build hazards are `none` (or `modules` before the latch). Otherwise **ABORT**.
2. **Decoys, RAM only:** a 16 MiB GPT image on tmpfs (written by the probe itself) attached to
   `loop6` with partitions `xbl_a`, `persist` (with a swap header), `boot_a`, `modemst1`,
   `fsbg_decoy_rw`, `fsbg_decoy_ro`; `ram1` with a pattern; descriptors to `ram1` opened before
   arming; `dm-200` = linear over `ram1`; `loop7` over an `O_RDWR` fd of `ram1`.
3. **Hash before** (reads only; PM decision 2026-10-15), aligned with
   the readback proposal (private) §5/§5.1. Every row is exactly one read-only
   `O_RDONLY | O_DIRECT` open (no second open without `O_DIRECT`: FS-R-014 §3.3; the only ioctl is
   `BLKGETSIZE64`; K1g r3: every read is whole 4096-byte blocks, the Quest 3's UFS logical block size, and only the
   row's bytes are hashed; a rounded read past the node's end fails closed), runs in a child bounded like
   `timeout -k 5 <n>` on the unit, n = the time left in its pass, at most 10 s (TERM at the limit, KILL
   5 s later; the before-pass must end 8 s after the probe's start, else `ABORT: time:` before arming; the
   after-pass by 20 s; the VM runs use 60 s rows and a 120 s before-pass; K1g README §5), and is
   accepted **fail-closed**: it must hash exactly the bytes it requires (the probe's equivalent of
   checking dd's `<n> bytes` summary), it must not be the empty-input hash `e3b0c442…b855`, and
   a read error, short read, mismatch, refused open or timeout STOPs: **the first failed row stops
   every later read** (FS-R-014 §3.2); real storage is never re-read after an error (PROPOSAL §5.1:
   no retry; only the RAM decoys get one retry for a stale writeback error). **Content-read
   allowlist (FS-R-014 §3.1):** enumeration and guard coverage are sysfs metadata and the guard's
   verdict table; content is read only from the decoys and the partitions of the accepted readback
   rows, checked by the kernel's partition name of the node's device BEFORE any open; `persist` is
   never opened for anything; no whole LUN and no other partition is read. Rows: the decoys, and the
   readback rows **R1–R5** (`boot_a`
   61,607,936 B, `vendor_boot_a` 5,058,560 B, `dtbo_a` 12,564 B, `vbmeta_a` 5,632 B,
   `vbmeta_system_a` 3,136 B: plain SHA-256 of the AVB-covered range, which must equal
   PROPOSAL §3's expected v2.7 values), **R6** (`misc` = 1,048,576 B, `devinfo` = 4,096 B), then
   **R7d** (`misc` whole) and **R8** (`devinfo` whole), whose before/after pairs must be equal.
   Each readback name must be carried by **exactly one** node (zero or several → ABORT: the
   row would be ambiguous).
   Any failed row → **ABORT before arming**: no armed guard test case attempted (decoy set-up and
   the before-pass reads have run).
4. **Arm:** `kernel.modules_disabled=1`, then the sealing request (§2.4); read back mode,
   seal and latch; check that a second request is refused (**seal test**); check that **every
   real block node** has a `deny-*` verdict in the guard's own table, else **ABORT**.
5. **Mechanism phase on decoys** with full capabilities and real data (cases below). Before
   each case in device mode the target is re-verified as RAM-backed (`ramN`, our `loop6` whose
   backing file is the tmpfs image, our `loop7`, our `dm-20x`); anything else → **ABORT**.
6. **Protected phase**, only if **every** mechanism case passed: the Q-series (read-only, zero-length or refused cases; Q5 and Q13 are state-changing operations whose execution is prevented by the dropped `CAP_SYS_ADMIN` and the expected guard refusal, FS-R-015 §4; correction 2026-10-19)
   on every real node, `/dev/sg*` and `/dev/bsg/*`. **No write-mode open of a real node** (Q11
   is not run on a Quest: PM decision 2026-10-15; it runs on the QEMU/UML test kernels only).
7. **Hash after**, same boot, the same rows with the same fail-closed acceptance; every hash must
   equal its before value (R1–R5 also the expected value). Result line `FSBG-PROBE RESULT: PASS|FAIL|ABORT
   nonce=<fresh id>`; PID 1 powers off (stage init: returns to fastboot as in FS-A-013 §2).

A case **passes** only if the call fails with an expected errno **and** the guard's counter for
that path moved by the expected amount **and** no other counter moved. A guard that is absent,
or whose hook did not run, cannot pass a case even when the kernel refuses the call by itself.

**What the device run proves about the real storage (the on-device proof):**
1. **Identification:** after arming, the guard's own verdict table shows a `deny-*` verdict for
   **every** real block node (each UFS LUN and every partition; the probe ABORTs otherwise), and
   the Quest's boot-chain and unit-unique names are all visible (ABORT if any is missing).
2. **Enforcement on the real nodes:** Q1–Q10 and Q12–Q14 on every real node, sg and bsg node:
   each is refused by the stock kernel anyway (or is a read), so it passes **only if the guard's
   counter for that path moved by exactly one**, which shows the hook ran and decided "deny" for
   that real node before the kernel's own check.
3. **The hooks behind those verdicts work:** the mechanism phase sends real data through every
   write path on RAM-backed decoys carrying the same protected names (N, P, S series).
4. **Nothing changed:** the fail-closed before/after rows, including R1–R5 against the expected
   v2.7 values.

The write-mode open hook on a real node is therefore shown by (1) and the decoy cases N1/N2/N11/S3,
not by opening a real node; the QEMU and UML runs (Q11 with a test kernel) show the same open
refused on disks that carry the same names.

### 7.2 Cases

| id | target | operation | expect |
|---|---|---|---|
| N1–N2 | each decoy node | `open(O_RDWR)`, `open(O_WRONLY)` | `EPERM`, open +1 |
| N3–N5 | each decoy node | `BLKDISCARD`, `BLKSECDISCARD`, `BLKZEROOUT` on an `O_RDONLY` fd | `EPERM`, discard/zeroout +1 |
| N6 | each decoy node | `BLKROSET` 0 | `EPERM`, roset +1 |
| N7–N10 | decoy whole disks | `BLKPG` delete / add (overlapping `xbl_a`) / resize; `BLKRRPART` | `EPERM`, blkpg/rrpart +1 |
| N11 | `loop6p2` (`persist`, swap header) | `swapon` | `EPERM`, open +1 |
| P1–P11 | descriptors opened before arming (`ram1`; in the boot-`off` run also `loop6p1` = `xbl_a`, and the host decoy in VM) | `pwrite`, `pwritev`, `O_DIRECT pwrite`, AIO, `sendfile`, `fallocate` ×2, `BLKDISCARD`, `BLKZEROOUT`, `mmap`+`msync` | `EPERM` (write/fallocate/discard/zeroout +1); mmap: `EIO`, bio ≥ 1 |
| S1 | `dm-200` (rw linear over `ram1`, made before arming; allowlisted) | `O_DIRECT` write | `EIO`, bio ≥ 1 (the leaf refuses) |
| S2 | `dm-201` (read-only linear over `xbl_a`, made after arming; allowlisted) | clear its ro flag, `O_DIRECT` write | `EIO`, bio ≥ 1 |
| S3 | new `dm-202` | load a **rw** linear table over `persist` | `EPERM`, open +1 |
| S4 | `loop7` (over an `O_RDWR` fd of `ram1`; allowlisted) | `O_DIRECT` write | `EIO`, write ≥ 1 (the loop worker's `write_iter`) |
| S5 (protect run) | `loop4` (GPT decoy when armed) | detach, re-attach to a blank image (no partitions), `open(O_RDWR)` | `EPERM`, open +1 (sticky mark) |
| A1, A2 | `loop6p5` (`part:` allowlist), `ram0` (`disk:` allowlist) | write + read back | success, no counter moves (positive controls) |
| C1–C12 (VM only) | a SCSI decoy disk and its sg/bsg nodes | real `WRITE(10)` with data via sd `SG_IO`, `SCSI_IOCTL_SEND_COMMAND`, sg `SG_IO`, sg legacy `write`, bsg; `UNMAP`, `WRITE SAME(16)`, `SECURITY PROTOCOL OUT`, `WRITE BUFFER`, `MODE SELECT`, `FORMAT UNIT`, `SYNCHRONIZE CACHE` | `EPERM`, scsi/sg +1 |
| C13–C18 (VM only) | SCSI decoy, sg node | `SCSI_IOCTL_STOP_UNIT`, `START_UNIT`, `SG_SCSI_RESET` (sd, sg), host ioctl `0x5388`, `IOC_PR_REGISTER` | `EPERM`, scsi-ioctl/pr +1 |
| C19 (VM only, QEMU UFS) | `/dev/bsg/ufs-bsg0` | the Q10 UFS query with **full** capabilities (the stock kernel would execute it) | `EPERM`, bsg +1 |
| A3, A4 | SCSI disk | `INQUIRY`, `READ CAPACITY(16)` via `SG_IO` | success (the allowlist works) |
| Q1, Q2 | each real node except `persist` (never opened) | `BLKDISCARD`/`BLKZEROOUT` on an **`O_RDONLY`** fd, zero length | `EPERM` +1 · without the guard: `EBADF` |
| Q3 | each real node except `persist` | `BLKROSET` 0 with **`CAP_SYS_ADMIN` dropped** | `EPERM` +1 · without: `EACCES` |
| Q4, Q5 | real whole disks | `BLKPG` delete of nonexistent partition 250; `BLKRRPART`; `CAP_SYS_ADMIN` dropped | `EPERM` +1 · without: `EACCES` |
| Q6, Q7 | real sd disks | `SG_IO` `WRITE(10)` of **0 blocks** with **no data buffer**, and `SYNCHRONIZE CACHE`; `O_RDONLY` fd, **`CAP_SYS_RAWIO` dropped** | `EPERM`, scsi +1 · without: `EPERM` from the kernel's command filter, scsi +0 |
| Q8, Q9 | `/dev/sg*`, `/dev/bsg/H:C:T:L` (incl. RPMB/boot W-LUNs) | as Q6 | `EPERM`, sg/scsi +1 · without: `EPERM`, +0 |
| Q10 | `/dev/bsg/ufs-bsg*` | a 36-byte `struct ufs_bsg_request` (u32 `msgcode` QUERY_REQ, UPIU header, query opcode **READ DESCRIPTOR**, DEVICE descriptor; read-only), `CAP_SYS_RAWIO` dropped | `EPERM`, bsg +1 · without: `EPERM` from the capability check, +0 |
| Q12 | real sd disks | host ioctl `UFS_IOCTL_QUERY` as a **READ** of `bBootLunEn` | `EPERM`, scsi-ioctl +1 · without: the attribute is read (nothing written) |
| Q13 | real sd disks | `IOC_PR_REGISTER`, `CAP_SYS_ADMIN` dropped | `EPERM` +1 · without: refused by the capability check |
| Q14 | real sd disks | `SG_SCSI_RESET_NOTHING` (a no-op), admin and rawio dropped | `EPERM` +1 · without: `EACCES` |
| Q11 (**QEMU/UML only**, never on a Quest) | each VM disk node, last | `open(O_RDWR)`, closed at once, **no write** | `EPERM`, open +1 · without: the open succeeds → **STOP** |

### 7.3 Why a guard failure cannot write to the Quest's storage

- **Absent or unarmed guard:** the pre-check stops before any decoy or real-node operation.
- **Guard present but a hook broken:** the mechanism phase finds it first, on RAM-backed decoys
  that go through the same code paths. A failure there writes only RAM or tmpfs, and stops the
  run before the protected phase.
- **Protected phase:** every Q1–Q10, Q13 and Q14 operation is one the stock kernel refuses by
  itself with the probe's reduced fd mode or capabilities; in Q6–Q10 the command also carries no
  data and transfers nothing even if executed (WRITE of zero blocks, cache flush, descriptor
  read); Q14 is the reset no-op. Q12 has no kernel backstop (Meta's query ioctl checks no
  capability), so it is built as a **read** query: unguarded, it reads one attribute. The guard
  is proven by its counter, not by the refusal.
- **No write-mode open of a real node** is made on the Quest (Q11 runs only on test kernels):
  every operation on real storage is either refused by the stock kernel or a read.
- **The hashing rows** are reads only and fail closed (a short read, an error, a timeout or the
  empty-input hash STOPs; nothing passes on an exit status alone).
- **Every VM-only mode** (vm mode with its data-carrying writes, `fsbg.testkernel` with Q11's write-mode open,
  devicesim, forceq, prebudget, `--boot-off`, `--protect`) is refused by one gate unless the platform is
  **positively** a test VM (device tree `linux,dummy-virt`, or UML) **and not a Quest** by any marker (device
  tree compatible/model containing qcom, oculus, meta, anorak, eureka, Quest or Qualcomm, or the Quest's stock
  boot arguments such as `qcom_dload_mode`, measured on v2.7). On the unit none of them is even read: the probe
  is not PID 1 there and `init.sh` passes only `--compact --nonce` (pinned by the builder). Tests:
  `tools/blkguard/probe/test/test-identity.c` (15 cases) and the QEMU run `quest-ident` (FS-A-014 draft MAJOR).

### 7.4 Residual risk of the probe (honest list)

1. **The write-mode open hook is not exercised on a real node** (Q11 dropped on the device by
   PM decision): it is proven on the real nodes only through the verdict table and the same
   decision function used by Q1–Q10 and Q12–Q14, and on decoys and VM disks directly.
   **Q12** has no kernel backstop: without the guard it would read one UFS attribute.
2. **Zero-length/no-data SCSI commands** in Q6–Q9 are never sent with the guard present, and
   are refused by the kernel's command filter without it; executing them would additionally rely
   on the UFS device honouring SBC (`TRANSFER LENGTH` 0 = no transfer) [C].
3. **Reading** only the readback partitions (R1–R5 over their AVB ranges, `misc` and `devinfo` whole; FS-R-014 §3.1)
   is a read of boot storage under Linux; reads change nothing [D], but it is new on these LUNs.
4. **Same-boot hashing** cannot see a write that a device would apply later or outside the
   hashed ranges (for example a UFS attribute); those paths are refused before they reach the
   device (Q6–Q10).
5. The probe itself is our code: a bug in it could misreport. Its VM runs (§8.3) exercise the
   device code paths: the `devicesim` QEMU run (VM only, refused elsewhere) runs the 16-name
   storage check, R1–R6 against the expected v2.7 values on disks holding the local v2.7 OTA
   images, no Q11, compact output, tmpfs `/dev`, the 32 MiB `/run` and the probe as a child of
   PID 1; only the build-hazard check is waived (the generic test kernel has hazards the K1g build
   does not). Q10 runs in QEMU on a UFS host model (`ufshcd-pci` with a test-only PCI id; the
   `ufs-device` and `ufs-strict` runs, C19 in vm mode). Q12 cannot run in QEMU (`UFS_IOCTL_QUERY`
   comes from Qualcomm's `ufs-qcom` vendor driver, which binds only to Qualcomm UFS hardware) and
   runs in UML (`scsi_debug`'s host ioctl, the same `scsi_ioctl` path). Not covered offline: the
   unit's own UFS driver and its timing; the probe measures its pace before arming and stops
   then if the proof would not fit (K1g README §5).

## 8. Offline evidence

### 8.1 CRC neutrality (kgate)

`tools/blkguard/kgate/build_quest3.sh` builds Meta's tree at `dbc2bc83a` plus the patch
(`a9c63e24c`) with the K1a option set already gated (group "a"), the same clang r450784e
toolchain and environment as FS-A-006, LTO and CFI on. `check_quest3.sh` gates it exactly as
`validation/run_validation.sh` gates the unpatched group-a build. Result [T]
(`tools/blkguard/kgate/results/check-quest3-a-blkguard.log`):

- **kgate `RESULT: PASS (exit 0)`**: `crc` 2601/2601 vendor-required (symbol, CRC) pairs;
  `module-layout` 0xb1f01218; `baseline` 0 of 14059 stock-build exports changed or removed,
  0 added; `export-collision`, `namespace`, `gpl-only`, `btf-kinds` (no kinds beyond stock),
  `config-binding`, `input-binding` (decoded `__ksymtab*`/`__kcrctab*` = Module.symvers, Image =
  objcopy of vmlinux) all PASS; the same two WARNs as the unpatched build (pahole probe,
  allowlisted toolchain entries).
- `Module.symvers` **byte-identical** to the unpatched group-a build (15 931 rows); the 14 059
  vmlinux exports identical; `.config` identical; no `__ksymtab` entry names the guard (its
  six hook functions are global but not exported); no compiler warning under `CONFIG_WERROR`.

### 8.2 Unit tests (userspace harness of the decision logic)

`tools/blkguard/harness/run.sh` extracts `block/fs-blkguard-policy.h` **from the patch** and
compiles it unchanged with ASan/UBSan. It checks the name rule, the verdict order, all three
modes, all 87 measured Unit 2 partitions in `protect`, `strict` and product
(`protect allow=part:userdata`) form, all 256 × 32 (opcode, service action) SCSI pairs, the
parser (good, bad, boundary lengths, embedded NUL, 2 000 000 token-fuzz inputs) and the one-way
transition rule, and the CDB-length rule (nothing under 6 bytes passes). **Result [T]: 74 272 checks, 0 failures** (ASan/UBSan clean).

### 8.3 VM test

- **QEMU aarch64 [T]** (PM-approved `qemu-system-arm`, QEMU 10.2.1, `-M virt -cpu
  cortex-a57`): `build_qemu_kernel.sh` builds a generic arm64 kernel (upstream arm64 `defconfig`
  + virtio) from the same tree, the same fs-blkguard commit and the test-only build fix below;
  four Meta vendor drivers that do not build outside their SoC config are switched off (none is
  block code). `run_qemu.sh` boots the probe as PID 1 with two host-file decoys, virtio-blk
  (`vda`) and virtio-scsi `scsi-hd` (`sda` with sg and bsg nodes), each 16 MiB, random fill,
  GPT with Quest names, **hashed on the host before and after every run** (results for the probe
  source recorded in `results/qemu-summary.txt`, 2026-10-16):

| QEMU run | boot state → arming | result | decoy images |
|---|---|---|---|
| strict-bootprotect | protect → `strict` | **PASS 213/213** | both unchanged |
| strict-bootoff | off → `strict` | **PASS 223/223** | both unchanged |
| protect | protect → `protect allow=part:fsbg_decoy_rw` | **PASS 181/181** | both unchanged |
| device-mode | protect → `strict` | **PASS 157/157** | both unchanged |
| k1g-layout (tmpfs `/dev`, 32 MiB `/run`, child of PID 1, compact) | protect → `strict` | **PASS 157/157** | both unchanged |
| devicesim (every device path, §7.4(5); two more disks with the Quest names, `boot_a`/`vendor_boot_a`/`dtbo_a`/`vbmeta_a`/`vbmeta_system_a` holding the local v2.7 OTA images) | protect → `strict` | **PASS 205/205**; R1–R5 = the expected v2.7 values before and after, R6 sizes | all four unchanged |
| devicesim-dupname (negative: the decoys also carry `boot_a`) | — | **ABORT** before arming: `boot_a` on 3 nodes | all unchanged |
| devicesim-timeout (negative: `fsbg.prebudget=1`, VM only) | — | **ABORT: time:** before arming (no armed guard test case attempted) | all unchanged |
| ufs-strict (a QEMU UFS host: `ufshcd-pci` with a test-only PCI id, `ufs-bsg0`, well-known LUNs, one LU) | protect → `strict` | **PASS 224/224** incl. C19 (a UFS query with full capabilities refused, bsg +1) | all unchanged |
| ufs-device | protect → `strict` | **PASS 177/177** incl. **Q10** on `ufs-bsg0` and Q9 on the well-known LUNs (Q12 skipped: no vendor ioctl) | all unchanged |
| devicesim under load (the mutation build running alongside; probe revision `2aa1f153…`, `qemu-devicesim-under-load.log`) | — | **ABORT** before arming: R1 (58.75 MiB, emulated SHA-256) hit the 10 s device row bound | all unchanged |

  The SCSI-path cases ran against a real virtio-scsi disk with real data (WRITE(10), UNMAP,
  WRITE SAME, SECURITY PROTOCOL OUT, WRITE BUFFER, MODE SELECT, FORMAT UNIT, through sd, sg and
  bsg). virtio-scsi has no host-driver ioctl, so C16/Q12 run only in UML (scsi_debug has one).
  The host hash proved its worth once: an earlier probe build wrote its own GPT over the
  virtio-scsi decoy before arming (a probe bug, fixed), and the host hash flagged it.
- **UML instead [T]:** an x86_64 User-Mode-Linux kernel from the same Meta tree with the same
  fs-blkguard commit (`a9c63e24c`) plus one **test-only** commit that lets Meta's !SMP scheduler
  code build (`tools/blkguard/vm/uml-test-only-build-fix.patch`: two `#ifdef`s and two
  `static inline`s in `kernel/sched`, never in a device kernel). The block layer, SCSI
  midlayer, sd, sg, bsg, loop, brd and dm code under test is architecture-independent.
  Decoys: a host-file disk (16 MiB, random fill, GPT `xbl_a, tz_a, persist, boot_a, vbmeta_a,
  modemst1, fsbg_decoy_ro, userdata`) attached as `loop5` over hostfs and **hashed on the
  host**; `scsi_debug` (a RAM SCSI disk with sd, sg and bsg nodes, GPT written pre-arm); brd,
  the tmpfs loop decoy, dm and loop stacks. Logs: `tools/blkguard/vm/results/`.

| run | boot state → arming | result | host decoy |
|---|---|---|---|
| strict-bootprotect (the K1g shape, vm mode) | protect → `strict` | **PASS 192/192** | unchanged |
| strict-bootoff (descriptors opened before arming on protected-name decoys) | off → `strict` | **PASS 212/212** | unchanged |
| protect (product shape; sticky test S5) | protect → `protect allow=part:fsbg_decoy_rw` | **PASS 170/170** | unchanged |
| device-mode (the device Q-series incl. Q12 on scsi_debug; test kernel) | protect → `strict` | **PASS 82/82** | unchanged |
| k1g-layout (tmpfs `/dev`, 32 MiB `/run`, child of PID 1, compact) | protect → `strict` | **PASS 82/82** | unchanged |
| unpatched kernel (same tree, no fs-blkguard) | — | **ABORT** at pre-check, 0 cases | unchanged |

- **Mutation test [T]** (`mutants_uml.sh`, `results/mutants/`): each hook disabled in turn
  in the test tree (bio, open, write_iter, block ioctls, `blk_verify_command`, sg, SCSI ioctls,
  sticky mark). **Every mutant made the probe FAIL** on the cases that use that hook. With the
  bio hook gone the host-file decoy **did change** (mmap writeback through `loop5p1`), which
  shows the host hash would catch a real leak. In the `device-mode` runs with the protected
  phase forced (`fsbg.forceq`, VM only), every Q-case with a missing hook failed with the
  kernel's own refusal (`EBADF`, `EACCES`, `EPERM` from the command filter or capability
  check, `EINVAL` from the host driver) and **no protected-phase node hash changed**; the open
  mutant hit Q11's STOP after an open/close that changed nothing.

### 8.4 Adversarial review (one agent reviewer, read-only, 2026-10-15)

| finding | severity | disposition |
|---|---|---|
| Meta's `ufs-qcom` host ioctl `UFS_IOCTL_QUERY` writes `bBootLunEn` (persistent boot-LUN select) through `scsi_ioctl()` with no capability check; no hook saw it | BLOCKER | **fixed**: all host-driver ioctls refused while armed; tests C16, Q12; mutant `no-scsi-ioctl` |
| `protect` mode: the boot-storage mark came only from the live partition table, so an sd unbind/rebind opened a window before the partition scan; a capacity-0 variant via STOP UNIT | MAJOR | **fixed**: sticky marks per request queue, all disks marked at arming; STOP/START UNIT refused; test S5; mutant `no-sticky`. `strict` was not affected |
| BLKROSET checked one user fetch and used a second | MINOR | **fixed**: single fetch |
| `protect` arming does not require `modules_disabled=1` | MINOR | open: Chair question 2 |
| START/STOP UNIT, `SG_SCSI_RESET`, eject, `IOC_PR_*` not filtered | MINOR | **fixed** (refused while armed); sd `cache_type`, UFS `wb_on` documented (§6 item 4) |
| a 1-byte sg CDB (`SG_NEXT_CMD_LEN`) let the filter read an unset byte | NIT | **fixed**: the filter takes the CDB length; < 6 bytes refused |
| hooks not exported (a future `=m` caller would not link) | NIT | kept: exporting would add symbols (CRC neutrality); all callers are built in |
| per-bio partition scan cost | NIT | documented (§6 item 10) |
| PCI DMA through sysfs | speculative | documented (§6 item 9) |

## 9. Open questions

**PM decisions (2026-10-15), applied:**
1. `qemu-system-arm` installed by the PM; QEMU results in §8.3.
2. **Q11 is not run on a Quest**; kept in QEMU/UML. The on-device proof is stated in §7.1.
3. **Hash-read the boot partitions before and after: yes**, reads only, rows aligned with
   the readback proposal (private) §5/§5.1 (fail-closed byte counts, bounded like
   `timeout -k`; §7.1 step 3).
4. **`super` and `metadata` stay protected** until the install decision (C6/PD-9).

**The Chair's rulings (FS-R-013 §6, 2026-10-16), applied:**
1. **Bring K1g: YES**, with the exact patch, probe source/binary, exact-image kgate result,
   VM/mutation evidence, allowlists, timing and the expected refusal/counter table: the concrete
   package is `devices/quest3/k1g/` (README.md). The no-Q11 rule is kept.
2. **`modules_disabled` coupling: ACCEPTED for strict mode**, not for the boot-default protect
   state (§2.1a); the signing-alternative wording is corrected (§2.1a).
3. **Residuals: conditionally acceptable for a narrow R-1 console composition**, not as a
   root-containment claim (§6 item 11).
4. **Refusal on USB disks: ACCEPTED for K1g and the isolated R-1 experiment** as conservative
   over-protection (§6 item 6); the product default is a separate decision.

## 10. How to run (WSL, offline)

```sh
bash tools/blkguard/harness/run.sh                 # decision logic, ~1 min
bash tools/blkguard/kgate/build_quest3.sh          # patched group-a build, ~80 min
FW=<checkout>/firmware bash tools/blkguard/kgate/check_quest3.sh   # kgate gate + symvers comparison
bash tools/blkguard/vm/build_uml.sh [unpatched]    # UML test kernel(s), ~12 min each
bash tools/blkguard/vm/run_uml.sh                  # the probe in UML, all configurations
bash tools/blkguard/vm/build_qemu_kernel.sh        # generic arm64 test kernel
bash tools/blkguard/vm/run_qemu.sh                 # QEMU aarch64 (qemu-system-arm), all configurations
```

The kernel work trees are `~/work/blkguard/src` (shared clone of `~/work/kgate27/src`, branch
`fs-blkguard`) and `~/work/blkguard/src-um` (plus the UML test-only build fix).
