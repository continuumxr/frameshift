# HTC Vive XR Elite — CPU/GPU range and thermal, fan and battery limits (research, 2026-10-08)

*Edited for publication: names and links removed or paraphrased.*

Agent report. Offline firmware plus web; no device action. The PM's existing
XR Elite material was read-only; extraction was done on copies.

**Sources** [M-static]:
- HTC firmware v2.0.999.960 slot B (the PM's existing XR Elite material):
  - `boot_b.img`: boot header v2, 4 DTBs; base msm-id 0x164 v2.1;
  - `dtbo_b.img`: entry 5 "HTC A01", board-id 0x50/0x01, merged with
    fdtoverlay;
  - `unpacked/vendor_b.img`, read with debugfs.
- A live bugreport from the PM's unit (build `SKQ1.230810.001`, 2026-09-30),
  in the PM's existing XR Elite material.
  It is a static artifact of earlier hardware output.

## CPU and GPU

| | hardware max (this unit) | HTC VR levels (WaveVR → `ANDR-PERF-PNPUTIL`) | kernel trips (work without Android) |
|---|---|---|---|
| silver cpu0-3 | 300–**1804.8 MHz** (EPSS LUT, bugreport l.213796) | every level pins **min = 1804.8** | core isolation at 110 °C (hyst 10) |
| gold cpu4-6 | 710.4–**2419.2** | low 1075.2–1478.4; med 1478.4–1862.4; high min 1862.4 (max presumably 2419.2 [O]) | isolation at 110 °C; **no 90 °C gold limit zone** (the Quest 2 has one); pop-mem 95 °C → cpu@400 to its minimum |
| prime cpu7 | 844.8–**2841.6** | low 1305.6–1632; med 1632–2073.6; high pinned **2073.6** | cpufreq-1x 75 °C → cpu7-notify ([O] effect); isolation at 110 °C; pop-mem 95 °C → cpu@700 to its minimum |
| GPU Adreno 650 | **587 MHz, bin 0**: 587/525/490/441.6/400/305 (bugreport l.181614 = DT speed-bin 0) | pinned per level: low **400**, med **490**, high **587** | gpuss-max-step 95 °C → minimum level; gpu-skin-avg 64.6 °C → -1 step ([O] whether defined); tsens 100 °C → GPU/NPU/CDSP/modem mitigation |

- The DT's 670 MHz bins (1, 2, 4) do not apply to this unit. HTC's overlay
  does not touch kgsl.
- HTC's real rule file, `vendor/etc/pnp.xml` (+ `pnp_turbo_off.xml`), is
  obfuscated. The level values come from its logged writes.
  `powerhint.xml` is the unused QTI stock file.

## Fan, battery and skin

- **Fan:** a MAX31760 controller on I2C (`max31760@50`), with fan-alert,
  shutdown and fan-fail lines and its own 5 V regulator;
  `CONFIG_SENSORS_MAX31760=y`.
  - **There is no fan curve in the DT or kernel.** HTC's closed
    `vendor/bin/thermal-engine` (8.9 MB) drives
    `/sys/class/htc_fan/max31760/pwm_control`, `fan_rpm` and `ramp_rate`.
  - Logged settings: `fd_min=20`, `fd_max=50` (% duty), `reboot=105` (a
    thermal reboot at 105 °C).
  - Observed: max_temp 24–55 °C at 17–28% duty, about 3100–4200 rpm.
  - `thermal-engine.conf` is empty; HTC's thresholds are compiled into the
    binary [O].
- **Battery:**
  - The headset holds only a **390 mAh hot-swap cell** (`htc_eya_390mah`,
    4.4 V, on the PMIC fuel gauge).
  - Its charging by temperature: 3–15 °C at 190 mA; 15–48 °C at 383 mA;
    48–57 °C at 260 mA / 4.1 V. Software JEITA is on; SMB max 80 °C.
  - **The main 24.32 Wh pack sits in the rear cradle.** Its temperature and
    current reach Android over UART (`htc,battery-cradle`,
    `CONFIG_HTC_CRADLE`, `com.htc.cradleuart`), **not** through the kernel
    thermal framework. The 24.32 Wh figure is [C], from HTC's spec page.
- **Brown-out protection (BCL):** VPH 3.0/2.75/2.5 V and VBAT
  3.0/2.8/2.6 V levels cap the GPU and isolate cpu4-7. PMIC trips at
  95/115/145 °C.
- **Skin:** no kernel skin trip. All board thermistors (sdm, lcm-l/r, xo,
  wifi, conn, smb, ufs) use the `user_space` governor, which does nothing
  without a daemon. The panel backlight is temperature-compensated between
  41 and 47 °C.

## Community [C]

- An overheating popup after about 30 min of PC streaming, in glasses mode
  on an 18 W power bank; the fan seemed slow
  (https://forum.htc.com/topic/16164-black-screen-while-streaming-pc-vr-games-overheating/).
- HTC warns that not all power banks are stable.
- No published clocks, Geekbench results or sustained-temperature data [O].

## Versus the Quest 2

1. **Identical CPU and GPU frequency tables**, so the ceilings carry over.
2. **HTC runs the prime core higher** (1.3–2.07 GHz, against the Quest 2's
   1.0752 GHz in most VR levels). It pins silver at max, and pins the GPU to
   one clock per level.
3. **Fan:** the Quest 2 has a kernel DT curve; the XR Elite's fan is
   **userspace-only**.
4. **No kernel 90 °C gold-limit zone** on the XR Elite.
5. **Battery:** the Quest 2's is on the PMIC with DT trips; the XR Elite's
   main pack is outside the PMIC, visible only over UART.
6. **Shutdown values:** the Quest 2's are in a readable JSON file; the XR
   Elite's are compiled into a binary, except the 105 °C reboot.

**Verdict:** reuse the Quest 2 **frequency ceilings**; **not** its thermal,
fan or battery policy.

## Safety risks

- **Highest: the fan under SteamOS.** Without HTC's thermal-engine, nothing
  drives `pwm_control`. The MAX31760's power-on duty is unknown [O].
  - **Do not run full-range clocks until our own fan loop exists.**
  - Interim rule: ≥ 20% duty at all times, 100% at any max-temp ≥ 50 °C,
    until HTC's curve is known.
- **The cradle battery is unprotected outside Android** unless the cradle
  UART protocol is reimplemented. Only the pack's own protection circuit
  remains [O].
- **No kernel skin trip.** A userspace daemon is needed; the Quest 2's
  47/51/52/60 °C can serve as the model.
- **Glasses mode on external power** risks brownouts. Prefer the cradle or
  a known-good PD supply.
- **Never force the 670 MHz GPU bins.** That would be beyond-spec.
- An older DTB copy in the PM's existing XR Elite material (4 GPU bins, speed-bin
  register at `@19b`) does not match the v2.0 DTB (`@419b`); it is probably from v1.0.
  Use the v2.0 `boot_b.img` DTB.

## Correction

`PROJECT_SETUP.md` §1 listed the XR Elite as "XR2+ Gen 1". HTC's spec page
says Snapdragon **XR2** [C]. Its tables match the Quest 2's XR2 Gen 1
exactly [M-static]. Corrected to XR2 (Gen 1).
