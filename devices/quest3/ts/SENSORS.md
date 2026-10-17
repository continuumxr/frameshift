# TS sensor identities, units and mappings (Quest 3, v2.7)

FS-R-013 §7 "Before execution bring: sensor identities, units and mappings,
including virtual-sensor equations". Source of the class map, groups,
thresholds and fan rules: the built-in table in
`devices/thermal/src/thermald_tables.c` (the reviewed v66 file sensor by
sensor; every v2.7 unit runs on it, PM 2026-10-15), printed by
`fs-thermald --device eureka --dump-config`. Every name here is a Linux
sysfs name read **by name, never by number** at start-up. T0 confirms each
row on each unit under stock Android (the T0 package, private,
compares them with the table); T1 confirms them again under our kernel
composition. Tags as in `devices/thermal/PLAN.md`.

**Caution (FS-R-013 §7):** the built-in table avoids the active-view read
problem; it does not establish that copied threshold numbers have the same
meaning on every Linux-visible sensor. The T0 and T1 rows compare names,
presence, units and idle values; meaning is argued from source (the
drivers and the DT below), not from the numbers' equality.

## 1. Temperature sensors

| class | sysfs identity | driver (module) | unit | rule use | source |
|---|---|---|---|---|---|
| SOC | thermal zones `cpu-0-{0,1}-{0,1}`, `cpu-1-{0..3}-{0,1}` (≥ 1 per cluster), `cpuss-{0,1}`, `gpuss-0…7` (≥ 2), `nspss-0…2`, `ddr` (faults only) | tsens0/1 (`qcom_tsens.ko`) | m°C | Meta LIGHT 89 / MODERATE 92 / SEVERE 95 / SHUTDOWN 115 (hyst 2/2/2/5); independent siblings (O20); stuck rule (K-33/K-40) | TCD §1.1; `v27.dts:26108-26124` [M-static] |
| SOC | `soc-usr` (Meta types it SKIN; our class map: SoC, weak, F33/K-29) | soc_therm 0x146 on the PMK8550 ADC (`qcom-spmi-adc5-gen3.ko`) | m°C | as SoC; never contradicts alone | TCD §1.1 |
| SKIN | `surf-virt-usr` (virtual) | `virtual_sensor.ko` (odm_dlkm) | m°C | 48/50/52/60 (hyst 1/1/1/5); frozen rule over inputs `pcb1-usr`, `pcb3-usr`, `pogo-usr`, `soc-usr` | TCD §1.1, §2.2 |
| BATT | `batt-virt-usr` (virtual) | `virtual_sensor.ko` | m°C | 58/61/63/65 (hyst 2/2/1/1); frozen rule over `pcb3-usr`, `pogo-usr` | TCD §1.1 |
| BATT | `power_supply/battery/temp` (psy) | `qti_battery_charger_main.ko` via pmic_glink → ADSP | **deci-°C** (driver: firmware value / 10, `qti_battery_charger.c:1516-1517` [M-static]) | thresholds of `batt-virt-usr`; ×100 to m°C (CORE-SPEC §12) | — |
| USB | `usb-conn` | pm8550b_usb_therm 0x747 (ADC) | m°C | P5: T4 at ≥ 70 °C (v2.7's own LIGHT 70 is covered) | TCD §1.1, §0.7 |
| PMIC | IIO `in_temp_<label>_input` of the vadc device: `pmk8550_die_temp` (0x03), `pmxr2230_die_temp` (0x103), `pm8550vs_c_die_temp` (0x203), `pm8550vs_d_die_temp` (0x303), `pm8550ve_die_temp` (0x503), `pm8550b_die_temp` (0x703), `pm8550b_lite_die_temp` (0x718); every one required (min 7) | `vadc@9000` on pmk8550 (`qcom-spmi-adc5-gen3.ko` + `qcom-vadc-common.ko`); `SCALE_HW_CALIB_PMIC_THERM_PM7` by default | **m°C**, clamped −60000…160000 (`qcom-vadc-common.h:62-65`) | **P7: SEVERE 95, SHUTDOWN 115** (hyst 5), CORE-SPEC K-50…K-55 | `v27.dts:20777-20886`; `qcom-spmi-adc5-gen3.c:1443-1446, 1565-1568, 1685-1693`; `industrialio-core.c:990-996` [M-static] |
| AUX | `pcb1-usr`, `pcb3-usr`, `pogo-usr` | ADC | m°C | inputs of the frozen rules only; never a fault | TCD §1.1 |
| BCL | `pm8550b-bcl-lvl0…2`, `pm8550b-ibat-lvl0/1`, `pmxr2230-bcl-lvl0…2` | `bcl_pmic5.ko` | — | coverage only (no threshold, as in Meta's files) | TCD §1.1 |

**The PMIC channels required before READY are named here (J-171, R50):**
the seven labels above. They are the `thermal` io-channels of six
temp-alarm nodes (pm8550b-lite@c00 → 0x718, pm8550b@a00 → 0x703,
pm8550ve-f → 0x503, pm8550vs-c → 0x203, pm8550vs-d → 0x303, pmxr2230 →
0x103) plus the PMK8550's own die (0x03, not a temp-alarm channel).
**pm8550vs-e and pm8550vs-g have no ADC channel and stay unmonitored**
under option A (R4; `v27.dts:20479-20490` [M-static]). A processed read
starts one ADC conversion (up to 10 × 50 ms wait; no cache) [M-static].
The IIO device number is not fixed; the label is (E-33). T0 row T0-10
lists every `in_temp_*_input` on each unit; T1 reads them under our
kernel (the ADC module is in T1's closure).

## 2. Virtual-sensor equations (Meta's `virtual_sensor.ko`, `eureka-thermal.dtsi:1967-2061`)

Output = Σ(coeffᵢ · avgᵢ) / 10000 + intercept (m°C), blended between the
charging and discharging sets over 10 s (`virtual_sensor.c:25-28,525-527`)
[M-static, TCD §1.1]:

| sensor | discharging, °C form | charging | fault handling |
|---|---|---|---|
| `batt-virt-*` | 0.5008·bq27 + 0.4519·pcb3 + 0.0227·pogo − 3.768 | 1.0·bq27 | bq27 outside −40…125 °C or erroring → replaced by `battery` ×1.0; result replaced by `battery` if they differ by > 25 °C |
| `surf-virt-*` | 0.0125·bq27 + 0.1313·pcb1 + 0.5494·pcb3 + 0.0029·pogo + 0.0288·soc + 6.605 | the same set (identical in the DT) | bq27 → the `battery` estimate |
| `disp-virt` (not used by us) | 0.2648·bq27 + 0.5076·pcb3 + 0.0243·pogo + 0.6303·usb − 15.051 | — | bq27 → the `battery` estimate |

`bq27` (`bq27z561-0`) reads fail under Android (−19) and the estimate is
the `battery` psy [M, FS-A-006 §0], so **a stale `battery` makes
`batt-virt` stale too** [D]. This is why the core also watches the ADSP
state and the psy triple (C-12) and why both inputs' freezing is checked
(K-4). The recomputed skin cross-check (TCD §6.4) is not built (open).
`virtual_sensor.ko` is in odm_dlkm only: it is part of T3b's closure, so
**before T3b the SKIN and battery-virtual classes are absent** (trials
T1–T3a run with `--batt-absent` and the trial override; TCD §6.4).

## 3. Other inputs

| input | sysfs identity | unit / values | used for | source |
|---|---|---|---|---|
| ADSP | `/sys/class/remoteproc/remoteprocN/{name,state}`, name **`3000000.remoteproc-adsp`** (or `adsp`), state `running` | text: offline, suspended, running, crashed, deleted, detached, invalid | battery class (C-12): not running → fault | E-32; `remoteproc_sysfs.c:172-180, 222` [M-static]; FS-A-006 raw [M] |
| psy | `power_supply/battery/{voltage_now,current_now,capacity,status}`, `usb/online` | µV, µA, %, text, 0/1 | P6/P13, J-145, staleness (all three of temp/volt/curr equal > 60 s), P14 | each read is a glink round trip (1000 ms timeout); **with glink down the driver returns the last value** (`qti_battery_charger.c:469-479, 489-497` [M-static]): staleness and the ADSP state are the only signals |
| fan | hwmon `name`=`pwmfan`: `rpm` (target write, tach read), `pwm`, `rpm_per_sec` (50…2000 accepted), `silent_rpm`; cdev `pwm-tach-fan0` `cur_state`/`max_state` (0…4) | rpm, 0…255, rpm/s, rpm, level | fan rules (28) and F1–F9 | TCD §3; `pwm-tach-fan.ko` (in K1a's 95) |
| fan zones | the 28 `*-fan` zones' `trip_point_N_{temp,hyst}` | m°C | re-read at start-up; must equal the table (K-25 F8) | TCD §1.3 |
| CPU | `cpufreq/policy0` (CPUs 0–1), `policy2` (CPUs 2–5): `scaling_governor`, `scaling_max_freq`, `cpuinfo_min_freq` | kHz | caps (P3; NORMAL = Meta L4 1920000) | `v27.dts:2135-2256` [M-static]; minimum frequencies **[O]: T0-08 reads them** (no OPP table in DT; EPSS LUT) |
| GPU | `kgsl/kgsl-3d0/max_pwrlevel` (needs C4a, T2) | level index (3/4/6/8/9) | caps | TCD §4.2 |
| dump mode | `/sys/module/qcom_dload_mode/parameters/download_mode` | an int printed over a bool (note below) | softdog precondition (E-2: exactly `0`) | `qcom-dload-mode.c:38, 95-109` [M-static] |
| LED | `/sys/class/leds/{red,green,blue}/brightness` (0…255) | — | notice pattern (fs-noticed) | `leds-qti-tri-led.c:498, 652-654`; `v27.dts:21197-21226` [M-static] |

**Note on `download_mode`:** the parameter is declared with
`module_param_call(download_mode, param_set_download_mode, param_get_int,
&enable_dump, 0644)` over `static bool enable_dump`
(`qcom-dload-mode.c:38, 109` [M-static]): the setter parses a bool, the
**getter prints the 4-byte int at the bool's address**. On this
little-endian CPU a printed `0` means the bool (the low byte) is false
and the three following bytes are zero too [D]; a nonzero print may be a
false refusal caused by the neighbouring bytes, never a false acceptance.
So E-2's "exactly `0`" is fail-closed. The T0-11 row records the text the
stock kernel prints (stock cmdline sets `download_mode=1`); the T1 row
records it under our composition (K1a inserts the module without
arguments, so dump mode is expected disarmed [C]).
