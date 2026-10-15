# FS-A-006 research — kernel rebuild feasibility and module map

Agent report, 2026-10-08. Offline and read-only. Scratch files are in WSL
`~/work/fs006-kernel/`: partition copies, a shallow checkout in `src/`, v2.7
partitions in `v27/`, and the symbol lists `req_versions.txt` and
`core_syms_needed.txt`. A stdlib-only `payload.py` extractor is in the
Windows scratch directory.

## A1. Source

- **Stock build** [M-static]: `5.10.198-01402-g1c5986fe21ee`, clang 12.0.7
  (r416183b1), built 2024-06-16. Vendor incremental `50105190000000511`.
- **Public match:** `facebookincubator/oculus-linux-kernel` branch
  `oculus-quest3-kernel-master`, commit **`23c97b254ef48348b919cff89c2b0a22ecccef82`**
  "build: 5010519.0.510" [D].
  - SUBLEVEL 198; `android/ACK_SHA` = `android12-5.10-2023-11_r2`.
  - The internal sha `1c5986fe21ee` is not public; the public tree is a
    squash [M-static].
- **Gaps between the public and internal trees:**
  - 45 stock Kconfig symbols are absent from the public tree. Only
    `OCULUS_EUREKA=y` (dts Makefile only) and `UEFI_LOGS=m` (shipped
    prebuilt) are enabled [D].
  - All 2555 core symbols that the vendor modules import are exported by the
    public source [D].
- **Start from the stock `kernel.config`, not the defconfig.**
  `oculus_anorak_defconfig` differs in 7 entries, including `SLUB_DEBUG`
  (layout-changing) and LTO FULL vs THIN [D].
- **Vendor driver sources** are also present: techpack display, camera,
  audio, eva, mmrm and video, plus `drivers/gpu/msm` (kgsl) [M-static].

## A2. Module loading and the four options

**Stock config** [M-static]:
- `MODVERSIONS=y`.
- No module signing, no forced loading, no `TRIM_UNUSED_KSYMS`.
- `CFI_CLANG=y`, `LTO_CLANG_THIN=y`, `DEBUG_INFO_BTF=y`.

**vermagic** [M-static]: all 395 vendor, odm and ramdisk modules carry
`5.10.198-01402-g1c5986fe21ee SMP preempt mod_unload modversions aarch64`.
- With CRCs, the kernel ignores the release part of vermagic
  (`kernel/module.c:1379`) [M-static].
- Still set `LOCALVERSION="-01402-g1c5986fe21ee"` with
  `LOCALVERSION_AUTO=n` [D].

**What the modules need from vmlinux** [D]: 2555 (symbol, CRC) pairs,
including `module_layout` = `0xac904f16`.

**The four options** [D, source grep at 23c97b2]:
- **DEVTMPFS:** a prototype `#ifdef` only.
- **FHANDLE:** `fhandle.o` only; the EXPORTFS it selects is already y.
- **AUTOFS_FS:** no conditionals in `include/` or `kernel/`.
- **BTRFS_FS:** use **`=m`**. Built-in (`=y`) would force LZO to y, which
  collides with the stock `lzo*.ko`.

None of the four is expected to change CRCs. **The main risk [O] is whether
the public squash reproduces the internal tree's types.**

**Offline check:**
1. Build 23c97b2 with clang-r416183b (`ARCH=arm64 LLVM=1`), using the stock
   `kernel.config` + `olddefconfig`.
2. `Module.symvers` must match `req_versions.txt` 100%, including
   `module_layout`.
3. Add the four options, rebuild, and diff: only additions are expected.

The host lacks gcc, flex and bison, so even kconfig can't run yet.

## A3. GKI

Not an official GKI build. Of the 2487 vendor-imported symbols listed in the
ABI XML, only 785 CRCs match ACK, and `module_layout` differs. **An official
GKI kernel would reject the vendor modules** [D].

## B. Subsystem map (v66)

**Partitions:** the slot images have no modem, dsp or bluetooth partition.
- `adsp_a` is FAT16 and holds `adsp.mdt`/`b00–b31`, `spss1p.*`,
  `battmgr.jsn` and `sp_license.mbn` (`DSP.XT.1.1-00626-HALLIDAY-1`).
- It is not in `fstab.eureka`; bootloader use is [C].

**Firmware search path:** `/vendor/firmware/` and
`/persist/calibration/audio/` (`ueventd.rc`) [M-static].
`FW_LOADER_USER_HELPER_FALLBACK=y`, so set `firmware_class.path` [D].

**DSPs do not start at probe.** After `modprobe -b *`, init writes
`boot_adsp/boot`, `boot_cdsp/boot` and the cvp `boot` attribute
(`init.insmod.cfg`) [M-static].

"Recovery set" below means the 97 modules in vendor_ramdisk
`modules.load.recovery`.

| item | modules (where) | deps missing from the recovery set | firmware | trigger |
|---|---|---|---|---|
| ADSP | `qcom_q6v5_pas`, `adsp_loader_dlkm` (vendor_dlkm) | mdt_loader, qcom_pil_info, qcom_q6v5, qcom_ramdump, qcom_sysmon; spf_core, gpr, q6_notifier, q6_pdr, snd_event | `adsp.mdt` | sysfs `boot_adsp` |
| CDSP | `qcom_q6v5_pas`, `cdsp-loader` | as for pas | `cdsp.mdt` | sysfs `boot_cdsp` |
| SPSS | `qcom_spss`, `spss_utils` | mdt_loader, qcom_glink_spss, qcom_sysmon | `spss1p.mdt` | [O] |
| transport | `rproc_qcom_common`, `qcom_glink(_smem)`, `qmi_helpers` (recovery set); `smp2p` (vendor_dlkm) | — | — | — |
| display | `msm_drm` (recovery set; its 31-module closure is all in the recovery set) | — | none (panel: **`meta,eureka_panel_sharp`**, Sharp/Novatek dual-DSI video mode with DSC, 2064×2208 per eye, 72–120 Hz stepped in the stage-1 log; corrected from `sy103`, which is only in Qualcomm reference DTs — see `display-bringup-quest3.md`) | — |
| GPU | `msm_kgsl` (vendor_dlkm) | log_gpu_error, mdt_loader | `a740v3_sqe.fw`, `gmu_gen70200.bin`, `a740v3_zap.*`; loaded on first open [C] | — |

GPU DT: `qcom,adreno-gpu-gen7-6-0`, Adreno740v3, chipid `0x43050b00`
[M-static].

## Gate result, v2.7 (2026-10-08) [M-static]

The public tree `dbc2bc83a2b673f5d1c24ee9dadb0cd708ffda3f`, with the stock
config, clang r450784e and Meta's build environment:
- 2601/2601 vendor-required CRCs match;
- `module_layout 0xb1f01218` equals stock;
- BTF kinds ≤ 15.

See JOURNAL J-31 and FS-A-006 (private review record). The rebuild
route is a credible candidate for v2.7 [D]. **Matches the checked symbol-version interfaces; complete module compatibility and runtime behaviour remain open** (FS-R-006 §2). CFI, config-dependent
inlines, constants, export/provider relationships and runtime
initialisation are open gaps.

Step 3:
- **group (a)** (DEVTMPFS, FHANDLE, AUTOFS=m, BTRFS=m): 0 vmlinux CRCs
  changed, 0 added;
- **group (a′)** (+ USER_NS, PID_NS): 0 changed, 12 added;
- both keep 2601/2601 and `module_layout`.

## v2.7 addendum

- **Kernel** [M-static]: `5.10.246-gd7102a837402`, clang 14.0.7,
  `LTO_CLANG_FULL`. Same stock options.
- **Source:** the public match is `dbc2bc83a2b6` ("5243367.3600.520").
  SUBLEVEL 246, ACK `android12-5.10-2025-12_r1` [M-static/D].
  - LZO is already y, so `BTRFS=y` works there.
  - The toolchain mismatch (the build config names r416183b; the Image was
    built with clang 14) is [O].
- **Modules are not interchangeable:** `module_layout` is `0xb1f01218` for
  v2.7 vs `0xac904f16` for v66 [D].
- **v2.7 vendor_ramdisk:** 131 modules, **including the ADSP and battery
  stack** (q6v5_pas, adsp_loader, smp2p, qti_battery_charger_main, bcl,
  tsens, adc5-gen3, …). Still not included: kgsl, cdsp-loader, spss.
- **v2.7 vendor_dlkm:** 271 → 246. Debug and lzo modules removed; bq27xxx,
  USB-net, usbip and exfat added.
- **v2.7 firmware:** nearly identical. ueventd adds `/odm/etc/firmware/`.
