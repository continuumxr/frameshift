# TS firmware manifest and source-derived load/start behaviour (Quest 3, v2.7)

FS-R-013 §7: "Firmware manifest and source-derived load/start behavior";
§8: "exact files, hashes, triggers, secure-world interactions and
error/recovery behavior. 'Expected volatile' alone is not a sufficient
account". Machine-readable list: `firmware-manifest.tsv` (hashes only;
**no firmware byte is in the repository**, J-123/J-158; the files are
staged privately from the matching OTA into test images that are never
distributed, PM J-157/J-158). Source: v2.7 OTA
`q3_52433670036000520.zip` (sha256 `e4c57710…2e04`, recomputed
2026-10-16), `vendor.img` (`e251197f…a8cc`, payload-verified), path
`/firmware/<file>`. Kernel facts from Meta's GPL v2.7 source
(`dbc2bc83a2b6`), cited file:line [M-static]. Clean-room: header and
string facts only; no code was copied.

## 1. Which steps need firmware

| step | firmware | why |
|---|---|---|
| T0 | none (stock Android) | — |
| T1 (tsens, ADC) | none | `qcom_tsens`, `qcom-vadc-common`, `qcom-spmi-adc5-gen3` request no firmware (no firmware strings) |
| T2 (caps, C4a probe-only KGSL) | GPU files staged, **not expected to be requested** | the KGSL probe requests no firmware and changes no power state (`gen7_hwsched_probe`, `adreno_device_probe`, `gen7_gmu_probe`: `adreno_gen7_hwsched.c:1453-1493`, `adreno.c:1190-1376`, `adreno_gen7_gmu.c:2366-2460`); the first request (`a740v3_sqe.fw`) is at the **first open** of `/dev/kgsl-3d0` (`kgsl.c:1574-1575` → `adreno_first_open` → `gen7_hwsched_first_boot` → `adreno_get_firmware`, `adreno.c:82`), then the GMU file (`adreno_gen7_gmu.c:1243-1249`) and the zap (`kgsl_util.c:127`, PAS load through SCM at `:154`). C4a opens nothing. Staged anyway (FS-A-013 §3.4) so that an unexpected request cannot stall; every firmware request and the GMU state are logged by the image. "Probe alone requests no firmware" is [M-static] for this source; the C4a log confirms it on the device |
| T3a (fan) | none | `pwm-qti-lpg`, `panel_event_notifier`, `pwm-tach-fan` request none (already in K1a's 95) |
| T3b (battery) | **ADSP**: `adsp.mdt` + 44 segment files | below |
| T4–T6 | as T3b | — |

## 2. ADSP: files, trigger, start behaviour

- **Files (45):** `adsp.mdt` (9724 B; ELF32, machine 164 QDSP6, 46
  program headers, PHDR at ph00 = `.b00`, **signed: hash segment at
  ph45** (8200 B), not phdr[1]) and `adsp.b00`–`b30`, `b32`–`b43`, `b45`.
  `b31` and `b44` are zero-size segments and are never requested; vendor
  also ships `b46` past phnum (never requested). Image version
  `DSP.XT.1.1-00729-HALLIDAY-1.137669.2.154748.2` (`halliday.adsp.prodQ`).
  The adsp partition holds byte-identical copies, but **v2.7 Android loads
  `vendor:/firmware/adsp.*`** (the adsp partition is mounted nowhere;
  ueventd `firmware_directories /vendor/firmware/ …`) [M-static].
- **Name:** from `qcom_q6v5_pas.ko` match data `firmware_name "adsp.mdt"`,
  `pas_id` 1, `minidump_id` 5 (`qcom_q6v5_pas.c:967-980`); the DT node
  `remoteproc-adsp@03000000` (`qcom,anorak-adsp-pas`) has no
  `firmware-name` (`v27.dts:21535-21554`).
- **Trigger: nothing boots it at probe.** `auto_boot = false`
  (`qcom_q6v5_pas.c:754-755, 967-980`; `remoteproc_core.c:2110-2111`).
  On Android `init.insmod.cfg` writes `/sys/kernel/boot_adsp/boot`
  (`adsp_loader_dlkm.ko`, `adsp-loader.c:53-56, 226-228`). The TS image
  instead writes `start` to the remoteproc's `state`
  (`remoteproc_sysfs.c:201-207`) **once, after reading its name**, and
  never writes `stop` (`:208-213`; `boot_adsp/boot` = 0 would also stop
  it): **the ADSP is never stopped once started** (checklist G3; FS-R-013
  §7: actual ADSP-stop testing stays excluded).
- **Load path:** `rproc_boot` → `firmware_request_nowarn("adsp.mdt")`
  (`remoteproc_core.c:1828-1835`) → `mdt_loader` requests each `adsp.bNN`
  into the carveout (`mdt_loader.c:219-221, 382-383`) → authentication and
  start by the secure world (PAS, SCM): **the ADSP then runs Qualcomm/Meta
  firmware, which manages charging (JEITA)** (FS-R-013 §7 distinction).
- **Missing file behaviour:** `FW_LOADER_USER_HELPER=y` and
  `_FALLBACK=y` (stock and K1a): each missing file falls back to
  `/sys/class/firmware` and **blocks up to 60 s** while `rproc->lock` is
  held (`fallback.c:598-624`, `fallback_table.c:20-21`). So the TS image
  stages every file in `/lib/firmware` (searched without
  `firmware_class.path`, `main.c:467-473`) and applies the two H-2
  settings, `/proc/sys/kernel/firmware_config/force_sysfs_fallback` = 0
  and `ignore_sysfs_fallback` = 1 (read back), before any module load
  (`fallback.c:610-613`; FS-R-013 §10 H-2: they disable the stated sysfs
  fallback, not every possible direct-file-I/O or driver stall).
- **Battery data path:** `qcom,pmic_glink` uses channel
  `PMIC_RTR_ADSP_APPS` and the protection domain `msm/adsp/charger_pd`
  (`v27.dts:19458-19463`); `qti_battery_charger_main.ko` talks through it.
  With glink down the driver returns the **last known values**
  (`qti_battery_charger.c:469-479`) — stale, not erroring.
- **Open, T3b blocker [O]: the protection-domain service.** On Android
  the charger PD is resolved through the userspace `pd-mapper` reading
  `/vendor/firmware/battmgr.jsn` (`be8c6fba…`, 516 B) over QRTR, and
  `qrtr-smd.ko` is in vendor_dlkm only. A TS image runs no Meta userspace,
  so T3b needs either an open-source PD mapper (the `.jsn` files as data)
  or a source-backed argument that pmic_glink reaches UP without one. Not
  resolved here; T3b's package must bring it (PM decision D-T0-4).
- **Error/recovery:** a failed authentication or a crash puts the rproc in
  `crashed`; recovery is enabled (`recovery_disabled=false`) [M-static],
  so the kernel may restart it [C]. The core treats any state other than
  `running` as a battery class fault (C-12) → WARN now, T4 after 120 s.

## 3. GPU files (C4a staging only)

`a740v3_sqe.fw`, `gmu_gen70200.bin`, `a740v3_zap.mdt` + `.b00`–`.b02`
(the zap is signed: hash segment at the last header, ph02). Names from
`adreno-gpulist.h:2175-2207` (`gen7_6_0`: sqe `a740v3_sqe.fw`, gmu
`gmu_gen70200.bin`, zap `a740v3_zap`) [M-static]. `a740v3_zap.mbn` and
`.elf` are not requested. KGSL softdep: `pre: arm_smmu nvmem_qfprom`.
The zap load is a secure-world (PAS/SCM) action at first open only, never
in C4a.

## 4. Not firmware, but loaded code the image depends on (module closure)

See `README.md` §3 (each module with its partition, `modules.load`
position and sha256).
