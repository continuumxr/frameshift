# Thermal control for FrameShift images — design (Quest 3 first)

Agent report, 2026-10-09, **revision 2** (after an adversarial review:
"NOT READY, source work accurate"). Offline research and design only. **No
device was touched; no adb/fastboot was run.**

**Status.** FS-R-008 §4: the Chair supports the recorded direction
(temperature-driven, display-independent fan control, per-device policies);
**this draft and any implementation are outside that concurrence.** Nothing
here changes the FS-A-007 images (FS-R-007 §4: no new blanking, watchdog or
thermal-stack change for the first experiment). This design is for later
images that run beyond a short, bounded, attended hold (PROJECT_SETUP §6A).
It implements the PM's fan policy (§6A.3, J-56): **cooling follows
temperature, not screen state; each device copies its own Meta policy; the
Quest 3S is not the Quest 3 and the Quest Pro is not the Quest 2.**

**Kernel forced-shutdown finding (FS-R-011 §6, 2026-10-11, J-104;
binding wording).** The Chair checked the exact Quest 2 tree
(`facebookincubator/oculus-linux-kernel` `6bde5fc06b25`: `kernel/umh.c`,
`kernel/reboot.c`, `drivers/thermal/thermal_core.c`,
`drivers/thermal/Kconfig`) [D]:
- With the empty static usermode-helper path, the normal helper call
  returns success without launching `/sbin/poweroff`, and with
  `THERMAL_EMERGENCY_POWEROFF_DELAY_MS=0` (Quest 2 v2.7) the generic thermal
  core schedules no backup emergency work. Required wording: **"The
  successful-no-op helper path supplies no dependable forced shutdown
  through the generic thermal core on this configuration."** Do not write
  "every call succeeds" or "the forced fallback never fires": allocation
  failure or a disabled-helper error can return nonzero and enter
  `__orderly_poweroff`'s forced fallback.
- **Quest 3** (delay 100 ms): a handled critical trip schedules an
  emergency power-off **attempt**; it does not establish a successful
  physical power-off exactly 100 ms later.
- Vendor notify paths and hardware over-temperature protection remain
  **unassessed [O]**. None of this establishes thermal protection in the
  current stage images, which do not load the thermal-zone drivers.
- **A forced, unsynchronised kernel power-off is a last-resort path, not
  graceful shutdown.** The Chair accepted raising the priority of
  FrameShift's thermal ownership and the PM's graceful-shutdown requirement
  (J-83). It is not an added gate on the bounded, attended trial (iii-b),
  but it **must inform the Quest 2 trial and sustained Valve-userspace
  operation**: this design's shutdown path (§6.3) is the primary route, and
  the kernel paths are not counted on as protection (§2.1, §7.2 R10, §8).

**Graceful emergency shutdown and thermal ownership (design, 2026-10-12):
`docs/research/emergency-shutdown-design.md`.** It answers J-83 and
FS-R-011 §6 and replaces the **mechanism** of §6.1 (shape: static C
supervisor, Python as the reference model), §6.3 "Shutdown path" and §6.5
"Watchdogs" below; their policy content stands. New source facts there:
the Quest 2 v2.7 DT has **no critical trip at all** (F1); `reboot(POWER_OFF)`
`do_exit`s its caller if power-off returns (F4); the compiled Quest 3 DTBs
have **no SoC watchdog node** (F8, corrects §6.5); `emergency_restart()`
skips the reboot notifier that clears Quest 3 crash-dump mode (F6).

**Firmware scope (read this first).**
- Unit 1 runs **v66**. The only proposed boot route uses the **stock v66
  kernel and v66 modules**. The v2.7 kernel route is **named, not proposed**
  (J-34). Every trial in §6.7 therefore uses **v66 modules on v66** unless a
  later ruling changes the route.
- Driver behaviour differs between v66 and v2.7 (fan driver above all,
  §3.1). The daemon is designed to be correct on **both**, and does not
  depend on either driver's display handling.
- v66 source facts come from Meta commit `23c97b254` (build 5010519.0.510).
  Applying them to Unit 1's `.511` modules is a **near-match hypothesis
  [C]** (FS-R-008 §4). v2.7 facts come from `dbc2bc83a`.

Tags: [M] hardware output (only from earlier probe files, cited) ·
[M-static] artifact, cited by path:line · [D] derivation · [C] hypothesis or
outside claim · [O] **open**. Every policy choice that is not Meta's is in
**§0.1 "Departures from Meta policy (PM ruling needed)"**.

**Sources** (all read-only):
- Quest 3 kernel sources (WSL): v2.7 `~/work/kgate27/src` (`dbc2bc83a`,
  5.10.246); v66 `~/work/fs006-kernel/src` (`23c97b254`). Paths starting
  `drivers/` or `arch/` are v2.7 unless marked **(v66)**.
- Quest 2 / Quest Pro source: `~/work/kgateq2/src` (`6bde5fc06`, 4.19.325).
  Stock configs: `~/work/kgate27/stock.config` (Quest 3 v2.7),
  `firmware/quest3/extracted/v66_unit1_slotA/kernel.config` (v66),
  `~/work/kgateq3s/stock.config`, `~/work/kgateq2/stock.config`,
  `~/work/kgateqpro/stock.config`.
- Compiled Quest 3 DTBs, **verified in this session** byte-identical to
  `dtc -s` of the extracted `vendor_boot_dtb0.dtb`: `~/work/dtdiff/v27.dts`
  (v2.7) and `~/work/dtdiff/v66.dts` (`v66_unit1_slotA`). Their
  thermal trips, hysteresis-free trip list and cooling maps are **identical**;
  only polling differs (v66 fan zones poll 1000 ms without averaging; v2.7
  100 ms with a 50-sample average) [M-static, `scratchpad/thermal/v66-zones.txt`
  vs `v27-zones.txt`]. The v66 PVT dtbo overlays (`~/work/fs006-power/dtbo/dtbo10.dts`,
  `dtbo12.dts`) contain no fan or thermal overrides [M-static].
- Module lists: v2.7 vendor ramdisk
  `firmware/quest3/extracted/v2.7-user_ota/vendor_ramdisk/lib/modules/`
  (`modules.load` = `modules.load.recovery`, 131); v2.7 vendor_dlkm/odm_dlkm
  `~/work/fs006-kernel/v27/{vdlkm,odmdlkm}/lib/modules/`; v66 vendor ramdisk
  `firmware/quest3/extracted/v66_unit1_slotA/vendor_ramdisk/lib/modules/`
  (76 normal / 97 recovery); v66 vendor_dlkm/odm_dlkm
  `~/work/fs006-kernel/{vdlkm,odmdlkm}/lib/modules/` (FS-A-006 extraction).
  Dependencies from `modinfo -F depends` on the `.ko` files.
- Meta's thermal HAL config: v2.7 `/etc/thermal_info_config.json` extracted
  read-only from `~/work/fs006-kernel/v27/vendor.img` to
  `~/work/thermal-design/v27vendor/thermal_info_config.json` (sha256 prefix
  `c9301ff553f65255`); v66 copy `~/work/fs006-power/thermal_info_config.json`.
  They differ only in `usb-conn` (v2.7 adds LIGHT 70 °C, hysteresis 45).
- Earlier [M] probes: FS-A-006 (private review record),
  FS-A-006 (private review record); cmdline
  FS-A-004 (private review record).

---

## 0. Key findings

1. **The kernel's autonomous CPU mitigation is one frequency step deep.**
   Every DT CPU map is `<&CPU0 0 1>` or `<&CPU2 0 1>`: `batt-virt-limit`
   (cluster 0 at 45 °C, cluster 1 at 58 °C), `surf-virt-limit` 48 °C,
   `cpu-1-x-x-limit` and `soc-limit` 89 °C [M-static
   `arch/arm64/boot/dts/oculus/eureka/eureka-thermal.dtsi:81,85,841-981,1823,1913`].
   State 1 = one OPP below the top: 2.0544→1.92 GHz (cluster 0),
   2.3616→2.208 GHz (cluster 1) [D, from the [M] LUT].
2. **No DT cooling map targets the GPU, the 110 °C CPU emergency trips, the
   95 °C GPU `tj_cfg` trips or DDR 90 °C** (the trips carry phandles that
   nothing references; `~/work/dtdiff/v27.dts:26443-26448,28135-28140`)
   [M-static]. So **at the DT level** no zone drives the GPU devfreq cooling
   device (`drivers/gpu/msm/kgsl_pwrscale.c:796`) [D]. Other runtime binders
   are not excluded by this (e.g. a userspace writer) [O].
3. **No tsens zone has a critical trip.** The only kernel `critical` trips are
   the PMIC temp-alarm zones at 145 °C, present only if
   `qcom-spmi-temp-alarm.ko` is loaded [M-static].
4. **Fan drivers differ by firmware:**
   - **v66:** on BLANK the fan is set to 0 (**(v66)**
     `drivers/staging/oculus/pwm-tach-fan.c:459-468`); while blanked,
     cooling-device requests are only stored (`:421-429`) and
     **`cur_state` reads 0** (`:389-391`); there is no `silent_rpm` and no
     ramp. Applying this to Unit 1's `.511` module is [C] (FS-R-008 §4).
   - **v2.7:** BLANK caps at `silent_rpm` (4000 on Quest 3; `:677-686`),
     cooling requests are capped while off (`:580-586`).
   - **Both:** the hwmon `rpm` write is **not** display-gated (**(v66)**
     `:305-321,214-233`; v2.7 `:398-415,289-325`) [M-static].
5. **The battery "ground truth" can freeze silently.** When pmic_glink is
   down, `battery_chg_write` returns 0 without sending ("return the last
   known values until it comes back up", `drivers/power/supply/qti_battery_charger.c:469-479`;
   reads similarly gated at `:440-441`). The `battery` supply then serves
   stale values, `batt-virt` falls back to them, and cooling/charge writes
   silently do nothing [M-static]. The driver also sets its state to UP at
   probe (`:3312`), before ADSP is known to run [M-static].
6. **Virtual sensors return the last value, not an error, when an input
   fails** (`drivers/staging/oculus/virtual_sensor.c:498-522`; initial value
   0) [M-static].
7. **`battery_charger` cooling state 1 disables USB Type-C CC**
   (`qti_battery_charger.c:1902-1930`): `usb-conn` ≥ 60 °C cuts charging
   **and our USB channel**, and with 25 °C hysteresis it stays off until
   the connector is below 35 °C (`eureka-thermal.dtsi:1951-1955`) [M-static].
8. **Charge-limit interfaces are not usable as thermal controls on Quest 3:**
   there is no `qcom,thermal-mitigation` in the DT (`v27.dts:19475-19479`),
   so `thermal_fcc_ua` stays 0; `restrict_cur` rejects any value above it
   (`:2077`); `restrict_chg` sends FCC = min(restrict, thermal) = **0** to
   ADSP (`:1429-1435,2114-2116`) [M-static]. **The design writes no ADSP
   charge setting**; any such write needs separate PM approval.
9. **Quest 2 / Quest Pro:** `qcom-spmi-temp-alarm` is built in and its 4.19
   driver **clears** both override bits, keeping PMIC stage 2/3
   (`~/work/kgateq2/src/drivers/thermal/qcom-spmi-temp-alarm.c:251-258`).
   Their fan driver (identical file to v2.7) **defers probe until a DRM panel
   exists** (`pwm-tach-fan.c:1101-1107`; 4.19 has no
   `QCOM_PANEL_EVENT_NOTIFIER`), and their DT sources set no
   `oculus,silent-rpm` (blank → 0 rpm) [M-static source; compiled-DTB check
   [O]].
10. **`cpufreq.default_governor=performance` comes from the vendor_boot DTB
    `/chosen/bootargs`** (`v27.dts:2082`), not the config (`CONFIG_CMDLINE=""`,
    `stock.config:524`; default schedutil `:598`) [M-static].

### 0.1 Departures from Meta policy (PM ruling needed)

**PM ruling (2026-10-09): P1–P10 ACCEPTED as proposed; P11 REJECTED in
favour of Meta's L4 (CPU 1.92 GHz / GPU 545 MHz) until soak tests justify
more. All eleven are to be revisited before the first public release
(J-63).**

Everything the daemon does that Meta's firmware does not, or does
differently. Before the ruling, each was a **proposal** [D]. "Meta" means the
device's own DT and `thermal_info_config.json`.

| # | proposal | Meta's own behaviour | why proposed | if rejected |
|---|---|---|---|---|
| P1 | **Fan floor 3700 rpm** (Quest 3's lowest Meta level) whenever the system is awake | 0 rpm until a fan trip (60 °C SoC, 45 °C battery, 42 °C skin) | §6A.3 earlier wording "fan must run whenever CPU/GPU loaded"; avoids load detection | pure Meta trips (rule 1), plus tach checks only when commanded |
| P2 | **No quiet cap while the screen is off** in version 1 (the daemon always applies full temperature demand) | v2.7 caps at `silent_rpm` while blanked (never yields); v66 stops the fan | rule 2 allows but does not require a cap; a cap that yields needs a yield threshold Meta never defined | add a cap at `silent_rpm` that yields at Meta's second fan trip (needs a ruling on the threshold) |
| P3 | **Graded CPU/GPU caps per severity** (§6.3 table) | Meta's per-severity actions are in `perf_service` code, not in the JSON [O] | the kernel's own mitigation is one step (§0.1); something must act at LIGHT–SEVERE | NORMAL caps only, plus the shutdown thresholds |
| P4 | **Fan floors per severity** (4500/5000/5500 at LIGHT/MODERATE/SEVERE) | fan only from fan trips | fan before throttle | Meta fan trips only |
| P5 | **usb-conn ≥ 70 °C → orderly shutdown** | v2.7 LIGHT at 70 °C (hyst 45; Android action [O]); v66 none; kernel cuts USB CC at 60 °C | a connector at 70 °C after USB is already cut means an external heat source or fault | log only; rely on the kernel 60 °C USB cut |
| P6 | **Battery ≤ 3 % and discharging → orderly shutdown** | Android BatteryService shuts down at 0 % [C, AOSP]; Meta value [O] | margin for a clean shutdown without Android | shut down at 0 % (psy `capacity`) |
| P7 | **PMIC die temperature (ADC) 95 °C → SEVERE, 115 °C → SHUTDOWN** (only while temp-alarm is not loaded, §5) | PMIC zones 95/115 passive (no maps), 145 °C critical, hardware stages | replaces the PMIC zones we do not load | 145 °C only (Meta's critical) |
| P8 | **Fan fault → SEVERE now; shutdown after 120 s or at Meta's 2nd fan-trip temperatures** | `perf_service` detects "cooling device failure" [M-static string]; reaction [O] | §6A.3 rule 4: throttle, then orderly shutdown | different timings |
| P9 | **Sensor fault → SEVERE now; shutdown after 120 s or with a second faulted class** | Meta [O] | §6A.3 rule 4: missing/stale sensors fail safe | different timings |
| P10 | **No suspend at all** (sleep targets masked) | Android suspends; the fan stops with the system | rule 3 allows suspend if not hot; masking is stricter and avoids the v2.7 resume quirk (§3.1) | implement "no suspend while hot" (cool first or postpone) |
| P11 | **NORMAL caps = §6A.5 sustained targets** (CPU 2.0544 GHz both clusters, GPU 599 MHz) | Meta apps: sustained L4 1.92 GHz / 545 MHz; boost by request | PROJECT_SETUP §6A.5 already sets these | Meta L4 (1.92 GHz / 545 MHz) |

Not departures: schedutil (§6A.4 allows schedutil or walt); leaving Meta's
kernel zones as they are; the 5500 rpm ceiling (Meta's top level on
Quest 3). **Not proposed:** fan above Meta's top level (Quest 3 DT `max-rpm`
8500 is never used by Meta); any ADSP charge write (§0.8).

---

## 1. Inventory (Quest 3)

### 1.1 Sensor sources

**tsens** (`qcom,tsens-v2`, two controllers with `uplow` and `critical`
IRQs; `v27.dts:26108-26124`). Driver `qcom_tsens.ko`. The driver masks
critical interrupts as "unused on Linux" (`drivers/thermal/qcom/tsens.c:466-468`).

| controller | sensor → zone |
|---|---|
| tsens0 `c263000` | 0 aoss-0 · 1 cpuss-0 · 2 cpuss-1 · 3–6 cpu-0-{0,1}-{0,1} (cpu0–1) · 7–14 cpu-1-{0..3}-{0,1} (cpu2–5) · 15 ddr |
| tsens1 `c265000` | 0 aoss-1 · 1–3 nspss-0..2 · 4 video · 5–6 camera-0/1 · 7–14 gpuss-0..7 |

**PMIC ADC** (`qcom,spmi-adc5-gen3` on pmk8550, `v27.dts:20673ff`).
`qcom-spmi-adc5-gen3.ko` + `qcom-vadc-common.ko`. Channels with
`qcom,adc-tm-type = 1` are threshold-monitored
(`drivers/iio/adc/qcom-spmi-adc5-gen3.c:666-772`).

| channel (reg) | zone | role |
|---|---|---|
| soc_therm 0x146 | soc-fan / soc-limit / soc-usr | board thermistor near the SoC |
| pcb1/2/3_therm 0x148/0x45/0x46 | pcb1/2/3-usr | board; virtual-sensor inputs |
| pogo_therm 0x74b | pogo-usr | virtual-sensor input |
| pm8550b_usb_therm 0x747 | usb-conn | USB-C connector |
| chg_therm 0x74d | chg-usr | charger area |
| rf_therm 0x145, xo_therm 0x44 | rf-usr, sys-therm-0 | — |
| glacier/canyon/jackson L,R | cam0..5-usr | cameras |
| die temps 0x103, 0x203, 0x303, 0x503, 0x703, 0x718 | (none) | the `thermal` io-channels of six temp-alarm nodes (pmxr2230, pm8550vs-c, -d, pm8550ve-f, pm8550b, pm8550b-lite); readable via iio |
| pmk8550_die_temp 0x03 | (none) | PMK8550 die; **not** a temp-alarm io-channel |

**PMIC temp-alarm** (8 instances, `qcom,spmi-temp-alarm`): pm8550b@a00,
pm8550b-lite@c00, pm8550ve-f, pm8550vs-c/d/e/g, pmxr2230. Six have an ADC
channel; **pm8550vs-e and -g have none** (`v27.dts:20257-20515,21019ff`).
DT trips 95/115/145 °C (critical at 145); lite 125/135/145.

**BCL** (`qcom,bcl-v5` ×2): pm8550b-bcl-lvl0..2, pm8550b-ibat-lvl0/1,
pmxr2230-bcl-lvl0..2; no cooling maps. `bcl_pmic5.ko`, `bcl_soc.ko`.

**Power-supply zones** (registered by the power-supply core for supplies
with TEMP [C, standard 5.10]): `battery` (ADSP battmgr via
`qti_battery_charger_main.ko`), `usb`, `bq27z561-0`. On stock Android
`bq27z561-0` reads fail (-19) and battery data comes from `battery` [M,
FS-A-006 §0]. **`battery` is only as fresh as ADSP/pmic_glink (§0.5).**

**Virtual sensors** (`virtual_sensor.ko`, `eureka-thermal.dtsi:1967-2061`).
Output = Σ(coeffᵢ·avgᵢ)/10000 + intercept (m°C), blended between charging
and discharging over 10 s (`virtual_sensor.c:25-28,525-527`):

| sensor | inputs | discharging (°C form) | fault handling |
|---|---|---|---|
| battery (`batt-virt-*`) | bq27z561-0, pcb3, pogo | 0.5008·bq27 + 0.4519·pcb3 + 0.0227·pogo − 3.768; charging 1.0·bq27 (dtsi `:1989-1994`) | bq27 outside −40…125 °C or erroring → replaced by `battery` ×1.0; result replaced by `battery` if they differ by > 25 °C (dtsi `:1972-1985`) |
| surface (`surf-virt-*`) | bq27, pcb1, pcb3, pogo, soc-usr | 0.0125·bq27 + 0.1313·pcb1 + 0.5494·pcb3 + 0.0029·pogo + 0.0288·soc + 6.605 (dtsi `:2053-2054`) | bq27 → `battery` estimate |
| display (`disp-virt`) | bq27, pcb3, pogo, usb-conn | 0.2648·bq27 + 0.5076·pcb3 + 0.0243·pogo + 0.6303·usb − 15.051 (dtsi `:2020-2021`) | bq27 → `battery` estimate |

Probe defers until every input, estimator and fallback zone exists
(`virtual_sensor.c:974-979,1035-1048,1198-1202`). Because both the bq27
estimate and the fallback resolve to `battery`, **a stale `battery` makes
batt-virt stale too** [D].

### 1.2 Cooling devices

| cooling device | provider (.ko) | states | effect |
|---|---|---|---|
| `thermal-cpufreq-0` / `-1` | `qcom-cpufreq-hw.ko` (`drivers/cpufreq/qcom-cpufreq-hw.c:398-405`) | 0–8 / 0–10 [M] | caps cluster max frequency |
| `pwm-tach-fan0` | `pwm-tach-fan.ko` | 0–4 → 0/3700/4500/5000/5500 rpm (`eureka-thermal.dtsi:7-9`) | target rpm |
| `thermal-devfreq-0` (GPU) | `msm_kgsl.ko` (`kgsl_pwrscale.c:796`) | 0–9 [M] | thermal max-frequency QoS → `thermal_pwrlevel` (`:670-695`); no DT map |
| `battery_charger` | `qti_battery_charger_main.ko` (`:3290`) | 0–1 | 1 = USB CC off (`:1902-1930`) |
| cpufreq-cdev, ddr-cdev, qmi, userspace cdev | `qti_cpufreq_cdev`, `ddr_cdev`, `qti_qmi_cdev`, `qti_userspace_cdev` | — | not referenced by any zone; not needed |
| CPU hotplug / thermal-pause | — | — | DT nodes exist (`v27.dts:13408,13455`); drivers not built (`stock.config:3247,3254`) |
| LMh | EPSS firmware; `qcom-cpufreq-hw` handles `dcvsh0/1` IRQs and exposes `cpuN/dcvsh_freq_limit` (0444, `qcom-cpufreq-hw.c:354-359`) | — | hardware clamp; `QTI_THERMAL_LIMITS_DCVS` not set (`stock.config:3248`) |

### 1.3 Zones with cooling maps (default `step_wise`, `stock.config:3219`; identical trips/maps in v66)

| zone(s) | sensor | trips °C (hysteresis) | action | source (dtsi) |
|---|---|---|---|---|
| cpu-*-fan (12), cpuss-*-fan (2), gpuss-*-fan (8), nspss-*-fan (3) | tsens | 60 (15) / 75 (10) / 80 (3) / 85 (3) | fan 1/2/3/4 | `:202-825,987-1090,1128-1710`; hysteresis `v27.dts:26505-26530` |
| soc-fan | soc_therm | 60/75/80/85 | fan 1–4 | `:1755-1807` |
| batt-virt-fan | battery virt | 45/49/53 (2) | fan 2/3/4 | `:20-59` |
| surf-virt-fan | surface virt | 42/44/46 | fan 2/3/4 | `:1857-1897` |
| batt-virt-limit | battery virt | 45, 58 (2) | cluster 0 −1 step; cluster 1 −1 step | `:61-89` |
| surf-virt-limit | surface virt | 48 (1) | cluster 1 −1 step | `:1898-1917` |
| cpu-1-x-x-limit (8), soc-limit | tsens cpu2–5 / soc_therm | 89 | cluster 1 −1 step | `:826-985,1808-1827` |
| usb-conn | usb_therm | 60 (25) | USB CC off until < 35 °C | `:1946-1963` |

v2.7 tsens fan zones poll at 100 ms with a Meta 50-sample average
(`drivers/thermal/thermal_of.c:106-162`), so sysfs shows ~5 s averages; v66
polls at 1 s without averaging [M-static, DTB diff]. step_wise honours
hysteresis (`gov_step_wise.c:118-153`). Zones without maps (`*-usr` at
125 °C, base tsens, `tj_cfg`, DDR, BCL, PMIC) are monitoring placeholders;
writable trips (`CONFIG_THERMAL_WRITABLE_TRIPS=y`) are how the HAL gets
threshold events [C; `perf_service` strings `trip_point`,
`THERMAL_GENL_EVENT_TZ_TRIP_UP`, v66 binary `~/work/fs006-power/perf_service.bin`].

### 1.4 Modules

Positions are line numbers in `modules.load`. v2.7's ramdisk list is
alphabetical, so **load order comes from dependencies** (modprobe).

| module | v66 ramdisk (normal/recovery) | v66 vendor_dlkm / odm | v2.7 ramdisk | v2.7 vendor_dlkm / odm | depends |
|---|---|---|---|---|---|
| `qcom_tsens.ko` | –/– | 207 / – | 98 | 182 / – | — |
| `qcom-vadc-common.ko` | –/– | 61 / – | 99 | 37 / – | — |
| `qcom-spmi-adc5-gen3.ko` | –/– | 62 / – | 94 | 38 / – | qcom-vadc-common |
| `qcom-spmi-temp-alarm.ko` | –/– | 204 / – | 96 | 179 / – | — (**§5**) |
| `bcl_pmic5.ko` (+ `bcl_soc.ko`) | –/– | 203 / – | 14 (15) | 176 (177) / – | — |
| `pwm-qti-lpg.ko` | –/89 | 113 / – | 66 | 94 / – | — |
| `panel_event_notifier.ko` | 29/29 | 161 / – | 54 | 144 / – | — |
| `pwm-tach-fan.ko` | 39/39 | – / 18 | 67 | – / 6 | panel_event_notifier |
| `qcom-cpufreq-hw.ko` | 41/41 | 27 / – | 72 | 22 / – | — |
| `qti_battery_charger_main.ko` | –/– | 111 / – | 106 | 93 / – | panel_event_notifier, pmic_glink |
| bq27xxx | built in (`BATTERY_BQ27XXX=y`, v66 `kernel.config:2984-2985`) | | — | 91, 92 / – (`=m`) | — |
| `virtual_sensor.ko` | –/– | – / 12 | — | – / 26 | — |
| `msm_kgsl.ko` | –/– | 39 / – | — | 33 / – | iommu, scm, llcc, clk… |
| `qcom_soc_wdt.ko` | –/– | 173 / – | — | 153 / – | qcom_wdt_core |
| `qcom_q6v5_pas.ko`, `smp2p.ko` (ADSP start) | –/– | 122, 185 / – | 88, 117 | 104, 163 / – | — |

Meta's charger-mode minimal set loads `bcl_pmic5`, `bcl_soc`,
`qcom-spmi-adc5-gen3`, **`qcom-spmi-temp-alarm`** and `qcom_tsens`
(`~/work/fs006-power/rc/init.insmod.charger.cfg:7-8,25-26,31`, v66)
[M-static]. Built in (v2.7 config, v66 same where checked): thermal core with
step_wise and writable trips (`stock.config:3212-3229`); schedutil and
performance (`:598-604`); `SOFT_WATCHDOG=y` (`:3279`); `MAGIC_SYSRQ=y`;
`PSTORE_PMSG=y`; `PANIC_TIMEOUT=-1`; `THERMAL_EMERGENCY_POWEROFF_DELAY_MS=100`.
`qcom-spmi-temp-alarm.c` is identical in v66 and v2.7 [M-static, diff].

---

## 2. Kernel vs Android

### 2.1 The kernel alone (with §1.4 loaded) [M-static]

- Fan from SoC (60–85 °C), battery (45–53 °C) and skin (42–46 °C) zones,
  up to 5500 rpm — **on v66 only while the display is "on"** (§0.4).
- CPU: one step per cluster (§0.1). GPU: nothing at the DT level (§0.2).
- USB CC off at `usb-conn` 60 °C.
- Shutdown: only PMIC 145 °C critical → `orderly_poweroff`, if temp-alarm
  is loaded. Otherwise hardware: LMh, tsens reset-mon 115 °C [C], PMIC
  stages [C]. *(FS-R-011 §6, J-104: with the empty static usermode-helper
  path, `orderly_poweroff`'s helper is a successful no-op; on the Quest 3
  the 100 ms `THERMAL_EMERGENCY_POWEROFF_DELAY_MS` schedules an emergency,
  unsynchronised power-off **attempt** after a handled critical trip, not a
  guaranteed power-off. That is a last resort, not graceful shutdown.)*
- Without the modules (stage 1, FS-A-007): none of the above.

### 2.2 Android userspace

Meta `perf_service` (thermal HAL) reads `thermal_info_config.json`. No sensor
has `BindedCdevInfo`; per-severity actions live in `perf_service` and
`vr_runtime_power_mitigation.json` [M-static; code meanings [O]].

| sensor | LIGHT | MODERATE | SEVERE | SHUTDOWN | hyst | v2.7 JSON lines |
|---|---|---|---|---|---|---|
| batt-virt-usr | 58 | 61 | 63 | **65** | 2/2/1/1 | `:4-23` |
| surf-virt-usr | 48 | 50 | 52 | **60** | 1/1/1/5 | `:1113-1137` |
| cpu-*, cpuss-*, gpuss-*, nspss-*, soc-usr | 89 | 92 | 95 | **115** | 2/2/2/5 | `:149-787,1088-1112` |
| usb-conn | 70 (v2.7 only) | — | — | — | 45 | `:1153-1175` |
| BCL levels / ibat | 1 / 11500 mA | — | — | — | — | `:858-1057` |

Shutdown on SHUTDOWN severity is done by Android's ThermalManagerService
[C, AOSP]; BatteryService adds battery-temperature and empty-battery
shutdowns [C; Meta values [O]]. `perf_service` detects fan failure ("cooling
device failure detected for:") [M-static]; reaction [O]. JEITA/charging
live in ADSP firmware (FS-A-006 §2).

### 2.3 The gap [D]

Shutdown at 115/65/60 °C; graded CPU throttling; any GPU limit; skin and
battery LIGHT–SEVERE mitigation; fan policy independent of the display
(critical on v66); fan-failure and sensor-failure (incl. stale battery path)
handling; low-battery shutdown; a sane governor.

---

## 3. Fan

### 3.1 Driver interface and behaviour

| | v66 (`(v66) pwm-tach-fan.c`) | v2.7 (`pwm-tach-fan.c`) |
|---|---|---|
| hwmon attrs | `force_failure` (0600), `pwm`, `rpm` (`:336-338`) | + `rpm_per_sec`, `silent_rpm` (`:477-490`) |
| `rpm` write | target; no display gate; **no clamp to max-rpm** in `set_rpm_locked` (`:214-233`) | target, clamped to max-rpm, no display gate (`:289-325`) |
| `rpm` read | measured tach | median of 3 measured values (`:417-423`) |
| ramp | none | 0 → ≤ `silent_rpm`: jump; otherwise `rpm_per_sec` (Quest 3: 100) (`:869-887`) |
| blank | **fan → 0**; cdev requests stored, applied on unblank (`:421-429,459-468`) | capped at `silent_rpm` 4000 (`:580-586,677-686`) |
| `cur_state` | **0 while blanked**; `max_state + 1` if pwm ≠ 0 and no tach for 15 s, display on only (`:384-399`) | `max_state + 1` once stalled ≥ 9 s after the 6 s detection (`:530-563`) |
| stall | `has_failure` after 6 s without tach (`:363-375`) | same idea (`:507-528`); recovery raises PWM by 50 every 6 s (`:783-819`) |
| suspend | `:946-990` | fan → 0 at late suspend; resume branch looks inverted (`:1337-1378`) [D] |
| probe | `is_display_on = true`; no PWM write | same (`:1186,1277-1278`) |

Common facts: DT max-rpm 8500, min-pwm 51, max-pwm 255; `oculus,cold-boot-pwm`
absent, so the driver default **84** applies (`COLD_BOOT_PWM`, v2.7 `:49`,
v66 `:45`). v2.7 DT adds `rpm-per-sec` 100, `silent-rpm` 4000, `panels`
(`v27.dts:32255-32275`); v66 DT has none of these (`panel` instead,
`v66.dts:31847-31863`). **During a stall `rpm` freezes at its last value**
(v2.7 failure branch skips the median update, `:890-909`); it reads 0 only
after a disable (`:235-236`). Any tach edge clears "failed", so a slow fan is
not detected by the driver [D]. Power-on fan state (checklist B5) [O].

### 3.2 How stock decides

Kernel step_wise zones only; `perf_service` monitors the cdev but binds
nothing [D].

### 3.3 Fan policy (daemon) [D]

- **Demand is computed by the daemon** from this device's Meta fan zones:
  per zone, the step_wise rule with that zone's trips and hysteresis, read
  at runtime from `thermal_zone*/trip_point_N_{temp,hyst}` and asserted
  equal to the device config (§6.1). Level = max over zones; rpm =
  `cooling-levels[level]`. This works when the v66 driver hides demand
  (cdev 0 while blanked).
- **The cdev `cur_state` is only a cross-check:** a mismatch with our
  demand for > 10 s while not blanked is logged; `cur_state > max_state`
  is a fan fault (F1).
- **Target** = max(Meta demand, P1 floor, P4 severity floor), clamped to
  Meta's top level (Quest 3: 5500; clamp done by the daemon, since v66 does
  not clamp). Written to hwmon `rpm` every 1 s cycle, so a blank (v66 → 0,
  v2.7 → 4000) is overridden within one cycle on either firmware.
- **Ramp allowance** before tach checks: |Δrpm| / `rpm_per_sec` + 15 s
  where a ramp applies (v2.7: 0 → 5500 ≈ 55 s + 15 s; changes entirely
  ≤ 4000 jump); 15 s on v66 (no ramp).
- **Tach checks** after the allowance:
  - F1 `cur_state > max_state` (never "= 5": on the Quest 3S state 5 is
    7500 rpm, legitimate);
  - F2 target > 0 and `rpm` = 0 for > 20 s;
  - F3 |`rpm` − target| > max(500, 15 %) for > 45 s;
  - F4 `pwm` = max-pwm and `rpm` < 0.85 × target for > 45 s;
  - **F5 frozen `rpm`**: the exact same value for > 30 s while target > 0
    (a stall freezes the reading); thresholds validated in T3a;
  - F6 hwmon missing, or any write/read error;
  - F7 kmsg "Fan stall recovery attempt" (v2.7 `:798-799`) → immediate F-check.
- **Implementation refinements** (fs-thermald part 1,
  `devices/thermal/CORE-SPEC.md` K-24…K-49; a false shutdown on a healthy
  fan counts as a defect like a missed one):
  - checks also run inside the ramp allowance against a continuous
    expected minimum speed `x` that follows the driver's ramp (K-36,
    K-43); the credit for a fan already ahead of `x` on a target change
    uses the median of the last three readings (K-46);
  - an F3 episode inside the allowance ends when the fan reads the level
    it missed (K-47); a stuck or slow fan never does, so its timer runs on
    across back-to-back allowances, while a healthy fan's noise or lag
    cannot keep one alive;
  - F6 is a rate: the read/write/absence condition on 5 of the last 20
    ticks (K-44); a tick without the readings a check needs holds that
    check's timer (K-45), so a dead fan with flaky reads still reaches
    trip 2 at once; the start-up self-test retries a failed fan read on
    the next two ticks (K-48); F9's noise floor is 25 % (K-49);
  - healthy envelope (assumed, swept in simulation, to be checked by
    T3a): ramp 0-2000 rpm/s, rotor lag ≤ 1 s and ≥ 900 rpm/s, tach noise
    ≤ ±10 %, ≤ 2 % failed reads, demand alternating every 3-6 s; outside
    it a false trip-2 shutdown was seen (2 s lag, round-5 review), so T3a
    measures the rotor lag on both units and a lag above 1 s means these
    rules are revisited before TS;
  - **declared limit:** while demand alternates faster than the ramp, a
    fan stuck at any speed between the alternating targets is not an F3
    (half-periods up to about 7 s without tach noise, about 8-10 s with
    ±2-5 % noise, since a noisy high reading can end an early episode);
    the tier floors (SoC 89/92/95 °C → 4500/5000/5500) end the
    alternation at LIGHT and the fan is then caught (sustained full load:
    F3 and trip 2 about 53 s after the load starts); F2/F5/F9 apply
    throughout.
- **On a fan fault:** P8.
- **Daemon exit/crash:** `ExecStopPost` writes `rpm` = top level and the
  minimum CPU/GPU caps.
- **Suspend:** P10 (sleep targets masked; logind ignores suspend keys).

---

## 4. Governors and caps

### 4.1 CPU

- Config default schedutil (v66 `kernel.config:599`, v2.7 `:598`); the DTB
  bootargs force `performance` (§0.10; [M] cmdline). Android uses `walt` [M].
- **Early unit** `fs-cpufreq-safe` (DefaultDependencies=no,
  Before=sysinit.target; or in the initramfs) for `policy0` and `policy2`:
  1. `scaling_governor` ← `schedutil`;
  2. `scaling_max_freq` ← NORMAL cap (P11);
  3. read back. If the governor write fails, keep `performance` but keep the
     cap. If the cap cannot be written or read back, write the value of
     `cpuinfo_min_freq` (read-only; used as the value) to
     `scaling_max_freq`; if that fails too, power off.
- Appending `cpufreq.default_governor=schedutil` to our cmdline: whether it
  wins over the DTB bootargs is [O]; until verified, the `performance`
  window is boot-time only.
- Effective limit = min(user cap, cooling QoS, LMh). Verified via
  `scaling_cur_freq`; `dcvsh_freq_limit` logged.

### 4.2 GPU

- `msm-adreno-tz` is the kgsl default (`stock.config:3932`; v66
  `kernel.config:3951`; `drivers/gpu/msm/adreno.c:1329`); verify
  `/sys/class/kgsl/kgsl-3d0/devfreq/governor`.
- Caps via `max_pwrlevel` (0 = 690, 1 = 640, 2 = 599, 3 = 545, 4 = 492,
  5 = 456, 6 = 421, 7 = 350, 8 = 317, 9 = 285 MHz [M]); effective level =
  max(`thermal_pwrlevel`, `max_pwrlevel`) (`kgsl_pwrctrl.c:71-90`). Not
  `max_gpuclk` (its store sets `thermal_pwrlevel`, `:381-385`).
- If `msm_kgsl.ko` is not loaded the GPU is unused; logged, caps skipped.

---

## 5. PMIC temp-alarm and stage-2 shutdown

### 5.1 Logic (`drivers/thermal/qcom/qcom-spmi-temp-alarm.c`, identical in v66)

- Probe reads SUBTYPE and DIG_MAJOR/MINOR (`:787-805`) and picks a path
  (`:815-822`):
  - **GEN2, dig_major ≥ 2 (TEMP_DAC):** programs the DT trips into
    `TEMP_DAC_STG1..3` (`:307-333,561-596`); never touches `SHUTDOWN_CTRL1`.
  - **LITE (0xC0):** programs `LITE_TEMP_CFG1/2` (`:335-400,610-642`); never
    touches the override.
  - **GEN1 or GEN2 dig_major = 1 (legacy):** `qpnp_tm_update_critical_trip_temp`
    with the DT critical trip (`:721-724`):
    - invalid or below the lowest stage-2 threshold → S2 kept (`:424-428`);
    - ≤ the highest stage-2 threshold → **S2 disabled** (`:430-434`);
    - above it (our 145 °C) → **S2 disabled if an ADC channel exists**
      (`:435-444`);
    - GEN2 revisions 0x0001/0x0002/0x0100/0x0101 force S2 on (`:445-459`);
    - `SHUTDOWN_CTRL1` written with `OVERRIDE_S2` if disabled (`:461-466`).
- **Trip writes reach hardware:** with writable trips, a write to a PMIC
  zone's trip calls `set_trip_temp`: the TEMP_DAC and LITE ops rewrite
  hardware stage thresholds; the legacy op re-runs the override logic for
  critical trips (`:469-486`) [M-static].
- Quest 3 inputs: critical 145 °C on all 8; ADC on 6. Each instance's path
  is hardware-defined: **[O]**. Stock Android always loads the module, so
  stock protection = the driver's choice [D].

### 5.2 Options

| option | protection state | gains | risks / cost |
|---|---|---|---|
| **A. Do not load** (current practice) | PMIC registers as left by bootloader/hardware [O] | no override from our side | no PMIC zones or 145 °C poweroff; **pm8550vs-e/-g are unmonitored** (no ADC channel); register retention across warm reboot [O] |
| **B. Load stock module** | as stock Android | Meta-equivalent; zones + critical poweroff | legacy-path instances with ADC get S2 disabled (as on Android); not undone by unloading [D] |
| **C. Load with a DT change** | S2 kept on legacy instances (`:424-428` / `:438-443`) | stock binary | boot-chain artifact change; separate review |
| **D. Patched module** | S2 kept | explicit | rebuilt module needs the kgate ABI review; not proposed |
| **E. Gate B on a register check** | B only if every instance is TEMP_DAC or LITE | deterministic | needs a pre-load register read path [O] |

**Recommendation [D]:** **A** through the trials, with the daemon reading
the six ADC die temperatures and applying **P7 (95 °C SEVERE, 115 °C
SHUTDOWN)** — one rule, used everywhere in this document. pm8550vs-e/-g stay
unmonitored under A (residual risk R4). Then T0 reads SUBTYPE/DIG/
SHUTDOWN_CTRL1 for all 8; if all are TEMP_DAC or LITE, propose **B**, else C
or D, each with Chair review. **Under B, the daemon and any other software
must never write a PMIC zone trip** (generally: the daemon writes no trip
point at all). Quest 2/Pro: the built-in 4.19 driver keeps S2 (§0.9).

---

## 6. Userspace thermal daemon (`fs-thermald`)

### 6.1 Shape [D]

- One process, Python 3 stdlib only, ~400–500 lines: a **pure decision
  function** `decide(state, readings, now) → (actions, state)` plus a thin
  I/O layer with a configurable sysfs root (fixtures).
- *(2026-10-12, PM decision J-118: Meta's thresholds are read from the
  user's own headset at runtime, and the values here become the built-in
  fallback; see `emergency-shutdown-design.md` §4.5, revision 4. Text kept
  as written. **PM decision 2026-10-15:** on Virtual A/B devices, every
  v2.7 unit included, the values here are always used, never Meta's
  runtime values; the runtime path stays for non-Virtual-A/B firmware
  (v66). The built-in Quest 3 set equals the reviewed v66 file; v2.7
  differs only in `usb-conn` LIGHT 70 °C, covered by P5.)*
- **Per-device config file**: zones, trips, hysteresis, fan levels, top
  level, virtual-sensor coefficients, thresholds, each annotated with its
  source line. A test asserts every value against the cited sources, and at
  runtime the daemon asserts the kernel's trip values equal the config.
- Period 1 s. systemd: `Type=notify`, `WatchdogSec=10`, `Restart=on-failure`,
  `StartLimitBurst=3`, `StartLimitIntervalSec=60`, `StartLimitAction=poweroff`,
  `OOMScoreAdjust=-1000`, **`DefaultDependencies=no`** (so the shutdown
  transaction does not stop it; §6.3). Load-producing units
  `Requires=`/`After=fs-thermald.service`.
- READY only after the self-test (§6.4).
- **Trial override file** (`/etc/fs-thermald/attended-trial`): honoured
  only in trial builds. The image build **fails** if the file or the
  override code path's enable flag is present in a non-trial image
  (manifest check in the build script, with a negative test).

### 6.2 Inputs

| class | sources | required |
|---|---|---|
| SoC | tsens zones (cpu-*, cpuss-*, gpuss-*, nspss-*, ddr), soc-usr | yes (≥ 1 per cluster, ≥ 2 GPU, soc_therm) |
| **battery** | `battery` zone; `power_supply/battery/{temp,voltage_now,current_now,capacity,status}`; batt-virt-usr; **ADSP state** (`/sys/class/remoteproc/*/name` = adsp → `state` = `running`) | yes (in trials T1–T3a: "absent by design", see §6.4) |
| skin | surf-virt-usr; recomputed from pcb1/pcb3/pogo/soc + battery with the device's Meta coefficients | yes |
| USB | usb-conn | yes |
| PMIC | six ADC die temps (§1.1) | yes under option A |
| BCL | bcl zones | log only |
| fan | hwmon `rpm`, `pwm`; cdev `cur_state`; kmsg | yes |
| state | `scaling_cur_freq`, `dcvsh_freq_limit`, kgsl `clock_mhz` | log |

### 6.3 Levels and actions

Levels use Meta's severity thresholds and hysteresis per sensor (§2.2);
system level = max. **The cap values are P3/P4/P11 proposals.**

| level | trigger (any) | CPU cap (both) | GPU `max_pwrlevel` | fan floor |
|---|---|---|---|---|
| NORMAL | — | 2054400 (P11) | 2 (599) | 3700 (P1) |
| LIGHT | skin ≥ 48, battery ≥ 58, SoC ≥ 89 | 1651200 | 4 (492) | 4500 |
| MODERATE | skin ≥ 50, battery ≥ 61, SoC ≥ 92 | 1382400 | 6 (421) | 5000 |
| SEVERE | skin ≥ 52, battery ≥ 63, SoC ≥ 95, PMIC die ≥ 95 (P7), fan fault (P8), sensor fault (P9) | 1094400 | 8 (317) | 5500 |
| SHUTDOWN | skin ≥ 60, battery ≥ 65, SoC ≥ 115, PMIC die ≥ 115 (P7), usb-conn ≥ 70 (P5), battery ≤ 3 % discharging (P6), escalations (P8/P9) | — | — | 5500 |

- **No charging control.** No writes to `restrict_cur`, `restrict_chg`, the
  `battery_charger` cdev or `charge_control_limit` (§0.8). §6A.6 ("no
  sustained maximum clocks while charging") is met by the caps.
- *(2026-10-12: the mechanism below is superseded by
  `emergency-shutdown-design.md` §5.2 "Who calls `reboot(POWER_OFF)`, and
  what happens if it returns" to §5.4 (revision 2): pre-cool first; request
  `poweroff.target` by `SIGRTMIN+4`; bounded `sync` and **one**
  `reboot(POWER_OFF)` (stage: PID 1 only; Valve: a pre-forked actuator at
  T5); no userspace fallback after it, only the softdog and hardware
  watchdogs. Text kept as written.)*
- **Shutdown path** (each step independent of the previous one's success):
  1. log + `/dev/pmsg0` record; fan to top level; minimum caps;
  2. `systemctl poweroff --no-block`; `poweroff.target` is configured with
     `JobTimeoutSec=60`, `JobTimeoutAction=poweroff-force`;
  3. fs-thermald keeps running (DefaultDependencies=no) and, if still alive
     30 s later, calls `reboot(LINUX_REBOOT_CMD_POWER_OFF)` itself
     (independent of PID 1). `sysrq-o` is not added: it reaches the same
     `kernel_power_off` path.
- **Reboots are last resorts only, never a thermal action.** The remaining
  reset paths are: softdog (`RuntimeWatchdogSec`, PID 1 frozen) and the SoC
  watchdog (kernel hung). A frozen system cannot act, so a reset is
  accepted there [D]; where it lands is the bootloader's choice
  (Android would bring its own thermal stack [C]). With
  `qcom_dload_mode.download_mode=1` (cmdline [M]) a bark/panic may instead
  enter ramdump mode and stay powered without OS thermal control [O] (R7).

### 6.4 Sensor failure: fail safe

- **Self-test at start:** every required zone exists, reads in −20…125 °C,
  and is not erroring. Failure → no READY; fan top level, SEVERE caps,
  poweroff after 60 s unless the trial override file is present.
- **Per cycle (P9):** read error or out of −20…125 °C; jump > 10 °C/s on
  slow sensors (battery, skin, board); **stale virtual sensor** (identical
  m°C for 120 s while an input moved > 1 °C, or |kernel − recomputed| > 5 °C
  for 30 s → use the recomputed value and flag).
- **Battery class (ADSP path):**
  - ADSP remoteproc not `running` → battery-class fault;
  - `temp`, `voltage_now` and `current_now` **all** unchanged for > 60 s
    while the system is awake → stale → battery-class fault (live ADSP
    readings move sample to sample [C]; threshold tuned in T3b);
  - any psy read error → fault.
  A battery-class fault is SEVERE at once and SHUTDOWN after 120 s, because
  the binding constraint (§6A.6) is then unobserved.
- **Trials without ADSP (T1–T3a):** the battery class is "absent by design",
  allowed only with the trial override file, the §6A.2 bounded hold and the
  PM present.
- A fault never lowers a level.

### 6.5 Watchdogs

*(2026-10-12: superseded by `emergency-shutdown-design.md` §5.4–§5.5:
fs-thermald owns the softdog and systemd's `RuntimeWatchdogSec` is off.
**Correction (F8 there):** the compiled v66 and v2.7 Quest 3 DTBs contain no
`qcom,msm-watchdog` (or `qcom,gh-watchdog`) node, so `qcom_soc_wdt` would
bind nothing; the Quest 3 has no Linux-petted SoC watchdog [M-static]. Text
kept as written.)*
fs-thermald ← systemd watchdog (10 s); systemd ← `RuntimeWatchdogSec=30`
(softdog); kernel ← `qcom_soc_wdt` if loaded (bark 11 s,
`arch/arm64/configs/vendor/anorak.config:316-319`). Download-mode handling
needs its own review (persistent-state rules) [O]. The §6A.2 dead-man stays
in every trial image until T5 passes.

### 6.6 Logging

Every 5 s (1 s above NORMAL): all inputs, level, caps written and read back,
fan demand/target/rpm/pwm/cur_state, ADSP state, LMh limits → persistent
journal (size-capped). Level changes, faults, write failures and shutdown
reasons also → `/dev/pmsg0` (pstore; FS-R-007 §5 Ask 4 rule). At start:
config hash, firmware identity (v66/v2.7), module list, self-test result.

### 6.7 Validation

**Offline:** fixture sysfs trees for both driver generations (v66: cdev 0
while blanked, `rpm` → 0 on blank; v2.7: cap 4000) — idle, ramps through
every level and back, each sensor missing/erroring/frozen/jumping, stale
`battery` with ADSP down, fan F1–F7, write failures, daemon kill, shutdown
fallback; Android traces from T0 replayed; config-vs-source test; systemd
unit test in a container (restart, start limit, shutdown transaction with
DefaultDependencies=no); build check for the override file.

**On device: staged, attended, Unit 1, `fastboot boot` with the PM's live
sign-off, v66 kernel and v66 modules** (the v2.7 route is not proposed).
Every trial keeps the §6A.2 bounded hold and manual recovery; any abort →
power off.

| trial | adds (v66 modules) | measures | abort if |
|---|---|---|---|
| **T0** read-only Android probe | nothing (stock v66) | zones and idle values; PMIC registers (§5.2 E); fan rpm/state; 60 s two-core load: zone temperatures, CPU/GPU freqs, fan | n/a (read-only); stop the load if any SoC zone ≥ 75 °C |
| **T1** monitor only | `qcom_tsens`, `qcom-vadc-common`, `qcom-spmi-adc5-gen3`; daemon log-only | zones present; idle values within ±3 °C of Android (SoC ~29, battery 25–31, skin ~27 [M]) | required zone missing; SoC ≥ 60, board ≥ 40 °C |
| **T2** governor + caps, **idle only** | §4 unit | governor/caps read back at idle; **no load** (load waits for fan control) | any readback mismatch; SoC ≥ 60 °C |
| **T3a** fan control | fan writes (`pwm-qti-lpg`, `panel_event_notifier`, `pwm-tach-fan`) | tach vs target at 3700/4500/5500; ramp; re-assert after a blank if the stage blanks; `force_failure`=1 → F1/F2/F5 detected within **≤ 25 s** and handled; frozen-rpm behaviour | tach mismatch > 30 s outside the test; any temperature +5 °C |
| **T3b** battery path | ADSP start, `qti_battery_charger_main`, `virtual_sensor` (bq27 built in on v66) | `battery` vs Android (±2 °C); voltage/current variation (staleness thresholds); batt-virt/surf-virt vs Android | stale or > 3 °C off; ADSP not running |
| **T4** throttle levels + modest load | test config with thresholds at idle + 3 °C | each level's caps applied/read back; hysteresis; 1–2 cores, short GPU pattern | SoC ≥ 75, battery ≥ 45, skin ≥ 42 °C; any write failure |
| **T5** shutdown path | test SHUTDOWN at battery-virt idle + 2 °C; injected sensor loss and ADSP stop | orderly poweroff time; fallback; fail-safe | not off within 90 s → manual recovery |
| **T6** soak | real thresholds | 10 → 30 → 60 min at NORMAL caps; discharging, then charging | skin ≥ 46, battery ≥ 45, SoC ≥ 85 °C, any fault |

An image may exceed the §6A.2 bounded hold only after T5 passes **and** the
full v2.7 `DEVICE_PORT_CHECKLIST` is complete (§6A item 8; PM, J-158). T6
is the first such run; sustained operation follows only after T6 passes. Note:
`usb-conn` ≥ 60 °C ends a trial's USB channel until < 35 °C (§0.7).

---

## 7. Open questions, risks, plan

### 7.1 Open [O]

1. PMIC temp-alarm SUBTYPE/DIG/revision and SHUTDOWN_CTRL1 per instance;
   retention across warm reboot.
2. Meta's per-severity actions (`perf_service`, `vr_runtime_power_mitigation.json`).
3. Precedence of an appended `cpufreq.default_governor=`.
4. Fan state at power-on and as the bootloader leaves it.
5. Whether BLANK events fire in our stages (the design does not depend on it).
6. Whether `battery` psy values move sample to sample with live ADSP (staleness threshold).
7. Download-mode behaviour on panic/bark.
8. Quest 3S and Quest Pro `thermal_info_config.json` (not extracted).
9. Quest 2/Pro compiled DTB/dtbo: `silent-rpm`, `panels`; whether a DRM panel registers in our boot.
10. tsens reset-mon 115 °C enforcement; GPU hardware limiter coverage.
11. Android/Meta battery shutdown temperature and level.
12. Exact match of v66 source (`.510`) to Unit 1's `.511` modules (FS-R-008 §4).

### 7.2 Risks

- **R1 (high):** v66 fan stops on blank and hides demand (§0.4) →
  daemon-computed demand, `rpm` re-assert every cycle.
- **R2 (high):** stale battery path looks healthy (§0.5–0.6) → ADSP state
  and psy staleness checks; battery-class fault → shutdown.
- **R3 (high):** `usb-conn` ≥ 60 °C cuts the USB channel (§0.7) → pmsg logging.
- **R4:** option A leaves pm8550vs-e/-g unmonitored; option B can disable S2 (§5).
- **R5:** daemon death → watchdog, `ExecStopPost`, start-limit poweroff; kernel zones remain.
- **R6:** single-step kernel mitigation is not protection (§0.1).
- **R7:** download-mode hang while hot.
- **R8:** tsens averaging (v2.7) or 1 s polling (v66) delays kernel fan steps; LMh covers transients [C].
- **R9:** suspend stops the fan → P10.
- **R10 (high; FS-R-011 §6, J-104):** the kernel's own thermal shutdown is
  not dependable: on the Quest 2 v2.7 config "the successful-no-op helper
  path supplies no dependable forced shutdown through the generic thermal
  core on this configuration"; on the Quest 3 the 100 ms delay schedules
  only an unsynchronised power-off attempt; vendor notify paths and
  hardware over-temperature protection are unassessed [O] → fs-thermald's
  graceful shutdown path (§6.3) is the primary route, verified in T5 before
  any Quest 2 trial beyond a bounded hold and before sustained
  Valve-userspace operation. Design: `emergency-shutdown-design.md`
  (its R11–R21 extend this list).

### 7.3 Incremental plan

1. **Phase 0 (offline):** this design; `fs-thermald` skeleton (pure core,
   fixtures for v66 and v2.7 drivers); config-vs-source test; build check;
   extract 3S/Pro JSONs; adversarial review; PM rulings on §0.1.
2. **Phase 1 (T0, read-only).** Commands for the PM's approval, **not run**
   (Unit 1, v66):
   - `adb shell 'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(cat $z/temp) $(cat $z/policy)"; done'`
   - `adb shell 'for c in /sys/class/thermal/cooling_device*; do echo "$(cat $c/type) $(cat $c/cur_state)/$(cat $c/max_state)"; done'`
   - `adb shell 'for h in /sys/class/hwmon/hwmon*; do echo "$h $(cat $h/name)"; done'`, then `cat` that hwmon's `rpm pwm`
   - `adb shell cat /sys/class/power_supply/battery/temp /sys/class/power_supply/battery/voltage_now /sys/class/power_supply/battery/current_now /sys/class/power_supply/battery/capacity`
   - `adb shell cat /sys/devices/system/cpu/cpu0/dcvsh_freq_limit /sys/devices/system/cpu/cpu2/dcvsh_freq_limit`
   - `adb shell cat /sys/class/kgsl/kgsl-3d0/devfreq/governor /sys/class/kgsl/kgsl-3d0/max_pwrlevel /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel`
   - **Short load (changes CPU load for 60 s; abort at SoC ≥ 75 °C):**
     `adb shell 'for i in 1 2; do timeout 60 sh -c "while :; do :; done" & done; for t in $(seq 1 12); do sleep 5; cat /sys/class/thermal/thermal_zone*/temp | tr "\n" " "; cat /sys/class/hwmon/hwmon*/rpm 2>/dev/null; echo; done'`
3. **Phase 2 (T1)** monitoring only → **Phase 3 (T2)** governor, idle →
   **Phase 4 (T3a, T3b)** fan, then battery path → **Phase 5 (T4, T5)**
   graded control and shutdown → **Phase 6 (T6)** soak, the first run beyond
   the bounded hold (it needs T5 and the full checklist, §6.7); sustained
   operation only after T6 passes.

---

## 8. Per-device delta (each device copies its own Meta policy)

| item | Quest 3 (eureka) | Quest 2 (hollywood) | Quest Pro (seacliff) | Quest 3S (panther) |
|---|---|---|---|---|
| kernel / tree | 5.10; v66 `23c97b254` on Unit 1, v2.7 `dbc2bc83a` | 4.19.325, `6bde5fc06` | 4.19.325, Quest 2 tree (J-36) | 5.10.246, Quest 3 tree |
| thermal stack | modules (§1.4) | **built in**: `THERMAL_TSENS`, `QTI_ADC_TM`, `QCOM_SPMI_ADC5`, `QCOM_SPMI_TEMP_ALARM`, `QTI_BCL_PMIC5`, `QTI_VIRTUAL_SENSOR`, `VIRTUAL_SENSOR`, `SENSORS_PWM_TACH_FAN`, `QTI_THERMAL_LIMITS_DCVS` (`kgateq2/stock.config:2547-2562,4056-4061,4594`) | built in (`kgateqpro/stock.config:2571-2586,4082-4087`) | modules: ramdisk tsens 95, ADC 91, temp-alarm 93, BCL 11, fan 64; vendor_dlkm incl. **virtual_sensor 178**; fan also odm 6 (`~/work/kgateq3s/ref/x/`) |
| temp-alarm S2 | §5; option A for now | driver clears override → S2/S3 kept (`…/qcom-spmi-temp-alarm.c:251-258`) | same source as Quest 2 [D] | `=m` (`kgateq3s/stock.config:3241`); same 5.10 driver [D]; PMIC types and DT trips **[O]** |
| zone governors | step_wise | many `user_space` and `single_step` (`hollywood-thermal.dtsi:136-1416`); user_space zones do nothing without a daemon | `single_step` fan zones (`seacliff-fan.dtsi`) | step_wise |
| fan | 1; levels 0/3700/4500/5000/5500; top 5500; v2.7 silent 4000, 100 rpm/s; v66 stops on blank | 1; 0–7000 by 1000 (`hollywood-fan.dtsi:49-52`); **probe waits for a DRM panel**; no `silent-rpm` in DTS → blank stops it [D] | **2 fans**; 0/1600…2600 (`seacliff-fan.dtsi:74-96`); `panels` on both (`seacliff-panel.dtsi:476-482`) → same probe/blank behaviour [D] | 1; levels 0/3000/4000/5000/6500/**7500** (`panther-thermal.dtsi:7-9`); silent 5000; 150 rpm/s (`panther-base.dtsi:31-34`) |
| first fan trips | battery 45, skin 42, SoC 60 | battery 45, front panel 40, CPU/GPU 70 (perf-envelope-quest1-2) | [O] | **battery 35, skin 35**, CPU tsens 62, soc_therm 60 (`panther-thermal.dtsi:20-61,211-250,1648-1670,1746-1790`) |
| virtual sensors | §1.1 | QTI + Meta virtual sensors (built in); coefficients [O] | [O] | **own inputs**: battery = 0.8628·bq27 + 0.1393·surf1 − 0.108 (charging 1.0·bq27; fallback zone bq27 itself, 25 °C); surface = 0.0212·bq27 + 0.0362·chg + 0.1008·soc + 0.3351·surf1 + 0.3765·surf2 + 1.973; display = bq27, pcb1, surf1, surf2 (`panther-thermal.dtsi:1861-1917`). **No fault estimator:** a failing bq27 leaves them stale [D] |
| kernel CPU maps | §1.3 | cpu-1-x-limit 90 °C (perf-envelope-quest1-2) | [O] | batt 45/58, skin 48, 89 °C (`panther-thermal.dtsi:67-90,784-798,1697-1711,1793-1807`) |
| userspace thresholds | §2.2 | skin 47/51/52/**60**; battery 53/–/58/**59**; CPU/GPU 95/**115** (v2.7 JSON) | **[O]** | **[O]** |
| default CPU governor | schedutil config; `performance` via DTB bootargs | `performance` in config (`stock.config:546`) | `performance` in config (`:546`) | schedutil config (`:598`); bootargs [O] |
| GPU governor | msm-adreno-tz (kgsl module) | `DEVFREQ_GOV_QCOM_ADRENO_TZ=y` (`:4973`) | same (`kgateqpro/stock.config:4970`) | msm-adreno-tz expected [O] |
| LMh | EPSS + cpufreq-hw dcvsh | `msm_lmh_dcvs` built in | same | `QTI_THERMAL_LIMITS_DCVS` not set (`kgateq3s/stock.config:3248`); firmware LMh [O] |
| battery path | ADSP battmgr (pmic_glink) | PMIC in kernel (checklist C) | [O] | **[O]** |
| design changes | baseline | fan probe/panel dependency must be solved first (reviewed DT or driver route); daemon covers user_space zones; governor from `performance`; **no dependable forced shutdown through the generic thermal core** (emergency delay 0, empty helper path; FS-R-011 §6), and its compiled v2.7 DT has no critical trip at all (`emergency-shutdown-design.md` F1): the graceful shutdown path (that file) must be verified before the Quest 2 trial | as Quest 2, **per-fan** tach checks and demand | daemon config from panther: 7500 top, 35 °C first trips, own coefficients, F1 as `> max_state`; extract the JSON |
