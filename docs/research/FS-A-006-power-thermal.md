# FS-A-006 research — Quest 3 power, fuel gauge, thermal and fan

Agent report, 2026-10-08. Offline and read-only. Scratch files are in WSL
`~/work/fs006-power`.

**Kernel source matches our build exactly.** The vendor incremental
`50105190000000511` (`vendor_a.img /build.prop`) corresponds to commit
**`23c97b2`** "build: 5010519.0.510" on branch `oculus-quest3-kernel-master`
of github.com/facebookincubator/oculus-linux-kernel [M-static]. The
file:line citations below are from that commit.

## 0. Correction from a read-only Android probe (2026-10-08T06:27Z, standing read-only authorisation)

Source: FS-A-006 (private review record). Stock
Android, slot A, up 1 h 18 m, with `remoteproc-adsp` **running**
(`fw=adsp.mdt`), CDSP running and SPSS running.

- **The same errors occur in Android [M]:** `i2c_geni 980000.i2c: IO lines in
  bad state` and `bq27xxx-battery 0-0055: bus error reading chip memory: -6`,
  repeating. Also `virtual-sensor …: bq27z561-0: error getting temp: -19`.
- **`/sys/class/power_supply/bq27z561-0`: `PRESENT=0` [M].**
- **Battery data comes from the ADSP-backed `battery` supply [M]:** Full, 100%,
  4.440872 V, 30.0 °C, Health Good, model
  `6468368_META_EUREKA_5060MAH_…`. Also present: `usb` (online, 5.16 V,
  150 mA), `ucsi-source-psy`, `cypd3177`, `wireless`.
- **Cooling devices [M]:** `pwm-tach-fan0` 0/4, `battery_charger` 0/1, the
  cpufreq clusters, cdsp, ufs, ddr, and `panel0-backlight` 255/255.

**Consequences:**
- The bq27 "IO lines in bad state" error in our stage-1 trial is **not caused
  by our init**. It occurs on stock Android on this unit too [M].
- The "the ADSP powers the gauge bus" hypothesis below is **not supported**.
  With the ADSP running, Linux's bq27 path still fails [M].
- Battery state on this platform comes from ADSP battmgr through pmic_glink
  [M]. Whether the ADSP reads the external gauge over its own bus is [O].
- For the port, **battery state = start the ADSP + `qti_battery_charger`**.
  The Linux bq27 node can be ignored, as stock does [D].

## 1. Fuel gauge and bus

**DT** (`vendor_boot_dtb0.dtb`; `eureka-base.dtsi:38-45`) [M-static]:
- `/soc/i2c@980000` is `qcom,i2c-geni`. In default pinctrl, gpio94 is SDA and
  gpio95 is SCL, both with **bias-pull-up**. In sleep pinctrl they are gpio
  with bias-disable.
- The bus node has **no supply property**.
- `fuel-gauge@0x55` is `ti,bq27z561`, with only `reg`.
- The PVT dtbo overlays (entries 10 and 12) do not touch this.

**The error** [M-static]:
- `i2c-msm-geni.c:1521-1525` prints "IO lines in bad state" when
  `SE_GENI_IOS` shows SCL or SDA low before a transfer, and returns -ENXIO.
  bq27 logs it at `bq27xxx_battery.c:1462`.
- The 365 s error is the 360 s poll (`bq27xxx_battery.c:1232`). The lines
  were still low then [M]/[D].

**The driver is present:** `BATTERY_BQ27XXX=y` and `BQ27XXX_I2C=y`, and the
i2c-geni driver is in the recovery set (line 81) [M-static].

**What powers the pull-ups and the gauge is [O] in the DT.** ADSP firmware
strings (`vendor /firmware/adsp.*`) include `battmngr_plat_scpqchg2s_extfg_r1`,
`battman_i2c_power_control` and `battman_pm_gpio_set_output_level`
[M-static].

**Superseded hypothesis (see §0) [C]:** ADSP battmgr powers the gauge's I2C through a
PMIC GPIO, and we never started the ADSP.
- In Android, every module (including bq27) probes before
  `/sys/kernel/boot_adsp/boot` is written, so Android's first gauge read also
  comes before the ADSP starts [D].
- Yet the gauge works in Android: the thermal configs read `bq27z561-0` [D].
- So something later powers the bus, which fits the ADSP.

**Modules missing from our 97** (all in vendor_dlkm `modules.load`) [M-static]:
`qcom_q6v5_pas`, `qcom_q6v5`, `qcom_sysmon`, `mdt_loader`, `smp2p`,
`adsp_loader_dlkm`, `qti_battery_charger_main`.

## 2. Charger and battery architecture

- **pmic_glink is the link to the ADSP.** `/soc/qcom,pmic_glink` uses channel
  `PMIC_RTR_ADSP_APPS`, subsystem `lpass` and PD `msm/adsp/charger_pd`. Its
  children are `qcom,battery_charger` (also a cooling device), `qcom,ucsi`,
  `qcom,altmode` and `meta,usbvdm-glink` [M-static].
- **The ADSP runs the charger and gauge logic.**
  `/soc/remoteproc-adsp@03000000` is `qcom,anorak-adsp-pas`, with firmware
  `adsp.mdt` and ssr name `lpass` (`qcom_q6v5_pas.c:967-976`). The ADSP has a
  QBG (pm8550b) gauge and an external-gauge variant; which is active is [O].
- **Protection-domain maps:** the jsn files cover root_pd, sensor_pd and
  audio_pd. There is **no charger_pd jsn** [M-static].
- **PDR is state only.** Clients come up when the rpmsg channel does
  (`pmic_glink.c:170-195,552-557`), so pd-mapper may not be needed for
  battery data [D].
- **Power supplies:** `battery`, `usb` and `wireless` register at probe
  (`qti_battery_charger.c:2899`). Their values come from the ADSP [D].
- **Android start sequence** [M-static]:
  - `init.anorak.rc` runs `insmod_sh` with `init.insmod.cfg`: `modprobe -b *`
    from vendor_dlkm and odm_dlkm, then `boot_adsp/boot` and `boot_cdsp`.
  - Services: `pd_mapper`, `per_mgr`, `qrtr-ns`, and `health-hal-2-1`
    (which waits for `battery` and `usb`).
  - **Meta's minimal set is `/vendor/etc/init.insmod.charger.cfg`: 38 modules,
    then boot the ADSP.**
- **Protection without the OS:**
  - PMIC temp-alarm critical trips at 145 °C [M-static].
  - battmgr configures JEITA, thermal thresholds and the charger watchdog.
    Without the ADSP, none of that is configured [D].
  - PMIC defaults and pack-side protection: [C] or [O].

## 3. Thermal and fan

- **The fan** is `/vendor/pwm-tach-fan@0` [M-static]:
  - LPG PWM on `pmxr2230 pwms@eb00`; tach on gpio147.
  - Levels 0, 3700, 4500, 5000 and 5500 RPM.
  - **On panel blank it is capped at `silent_rpm`, not stopped**
    (v2.7 `drivers/staging/oculus/pwm-tach-fan.c`: the BLANK/BLANK_LP
    handler sets `min(current, silent_rpm)`; DT `oculus,silent-rpm` =
    4000 on `eureka`, 5000 on `panther`). Corrected per FS-R-006 §4;
    the earlier "stops" was wrong. Behaviour when the panel was never
    unblanked (`is_display_on` initial state) is [O].
- **104 zones, all step_wise** [M-static]:
  - Fan zones on CPU, cpuss, GPU and NSP at 60/75/80/85 °C; `soc-fan`;
    `batt-virt-fan` at 45/49/53 °C; `surf-virt-fan` at 42/44/46 °C.
  - Limit zones at 89 °C on cluster 2's cpufreq.
  - `batt-virt-limit` at 45/58 °C; `usb-conn` at 60 °C, which lowers charge
    current.
- **Virtual sensors** need the `battery` power supply, or their probe defers.
  They also read `bq27z561-0` (`virtual_sensor.c:739-786,905-907`)
  [M-static].
- **Userspace** [M-static]:
  - Meta's `perf_service` (odm) implements IPower and IThermal, configured by
    `thermal_info_config.json`.
  - SHUTDOWN thresholds: CPU/GPU/NSP and `soc-usr` 115 °C, `batt-virt-usr`
    65 °C, `surf-virt-usr` 60 °C.
  - There is no thermal-engine.
- **In our stage-1 boot** [D]:
  - `qcom_tsens`, `qcom-spmi-adc5-gen3`, `qcom-spmi-temp-alarm`,
    `bcl_pmic5` and `virtual_sensor` were not loaded.
  - With no zones, the fan probe requested state 0. **The fan was never
    enabled by Linux** (`pwm-tach-fan.c:179-231,888-909`). Its real state
    is whatever the bootloader left [O].
  - No kernel CPU throttling either. What remained: LMh, the tsens critical
    IRQ, and PMIC stage-3 shutdown [C].

## 4. Minimal dependency list (not an implementation)

**(a) Read battery state:**
1. From vendor_dlkm: `smp2p`, `qcom_q6v5_pas`, `qti_battery_charger_main`,
   with `modules.dep` resolving the rest.
2. A read-only vendor mount, so `/vendor/firmware/adsp.*` is on the
   firmware path.
3. Start the ADSP, through `adsp_loader_dlkm` and `boot_adsp/boot`, or
   through remoteproc sysfs [C].
4. Optional: pd-mapper. The open-source linux-msm one reads the same jsn
   files [C].

**(b) Fan and thermal protection:**
1. Add `qcom_tsens`, `qcom-spmi-adc5-gen3`, `qcom-spmi-temp-alarm`, and
   optionally `bcl_pmic5`/`bcl_soc`.
2. Add `virtual_sensor` (odm_dlkm), which needs (a).
3. An explicit fan policy with tach/failure handling, independent of
   display state (blanking caps the fan at `silent_rpm`; FS-R-006 §4).
4. Add a small zone-polling shutdown watchdog in place of perf_service's
   thresholds [D].

**The bounded reference to start from:** `init.insmod.charger.cfg`.
