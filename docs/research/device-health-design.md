# Device health: faulty sensors and peripherals never block the headset (design, rev 2)

**Status:** design only, revision 2, 2026-10-15. Revision 0 (`46d027b`) was reviewed
adversarially: **NO-GO** (1 blocker, 5 major, 8 minor); revision 1 (`632ca22`) applied all of it.
The delta review of revision 1 returned **GO-with-fixes** (4 major, 6 minor); every fix is applied
here. The change tables are at the end. Nothing here authorises a device action.

**Licence:** CC-BY-4.0 (our own documentation; `docs/PROVENANCE-POLICY.md` §6). The service it
designs, `fs-healthd`, is to be our own code under Apache-2.0.

**Method and rules followed.**
- Offline only. No headset was touched; no adb or fastboot was run; nothing was downloaded;
  `/persist` and the PM's offline backup drive were not used.
- No Meta, Valve or Qualcomm binary was disassembled or decompiled. Facts come from Meta's
  published GPL kernel source and the compiled device tree, kernel configs, module lists, and
  Valve rootfs **unit files, udev rule files, configuration files and file names** only.
- No AI-directed text was found in the sources read.

**Tags** (FS-R-001): **[M]** measured on hardware · **[M-static]** read from a named artifact
(file:line) · **[D]** derived, with the derivation stated · **[C]** inferred, unconfirmed ·
**[O]** open.

**Sources** (read-only):
- Quest 3 v2.7 kernel source `~/work/kgate27/src` (`dbc2bc83a`), its stock config
  `~/work/kgate27/stock.config`, and the compiled runtime DT `~/work/dtdiff/v27.dts` (WSL).
  Kernel paths below (`kernel/…`, `drivers/…`) are in that tree.
- The v2.7 module lists: `vendor_boot` recovery list (131 modules,
  `devices/quest3/stage3d/provenance/modules.txt`), `odm_dlkm` (26) and `vendor_dlkm` (246)
  `modules.load` in `~/work/fs006-kernel/v27/{odmdlkm,vdlkm}`.
- Quest 3S DT sources `~/work/kgate27/src/arch/arm64/boot/dts/oculus/panther/`; Quest 2 and
  Quest Pro DT sources `~/work/kgateq2/src/arch/arm64/boot/dts/oculus/{hollywood,seacliff}/`.
- Valve 0.3.0 rootfs `~/sfroot-full`. The 0.4.5 rootfs (`~/work/rootfs045/rootfs.img`) was **not**
  mounted; every Valve-side finding below must be rechecked on 0.4.5 [O].
- Repo (master unless marked): `docs/PROJECT_SETUP.md` (§3 milestones, §6A safety),
  `thermal-control-design.md` (TCD), `emergency-shutdown-design.md` (ESD),
  `devices/thermal/PLAN.md` and `devices/thermal/CORE-SPEC.md` (merged to master in `02a3717`),
  `tracking-input-route.md`, `usb-link-design.md`, `display-geometry-stereo.md`,
  the Horizon observation plan and results (private), the private review records,
  `devices/quest3/stage3d/init.sh` (master) and `devices/quest3/k1a/init.sh` (**branch
  `feat/k1a-kernel`**), and JOURNAL J-129–J-141.

---

## The requirement (PM, 2026-10-15)

In the PM's words (intent kept, lightly condensed):

> A faulty proximity sensor (Unit 1) or a faulty IPD sensor (Unit 2) must not impede the
> functionality of the headset. It should still boot and operate as normal, minus those inputs.
> Build in a detection system that pops up an alert or toast when the user first boots up, to let
> them know which sensor is faulty. It shouldn't be persistent: just "hey, FYI, this is
> malfunctioning." It should apply to **any** sensor or peripheral that is faulty. In the case of
> temperature or safety, it does a graceful shutdown.

The PM also wants a polished, long-term product, not patches.

Why it matters on real units:
- **Unit 1** has a faulty proximity sensor; **Unit 2** has faulty proximity and IPD sensors (PM
  report, J-133).
- On stock Horizon, Unit 2's faulty IPD sensor keeps Android from finishing its boot (J-141). So on stock
  software a faulty IPD sensor already blocks the boot. FrameShift must not repeat that.

### Decisions recorded (2026-10-15)

| # | Decision | By |
|---|---|---|
| H-Q1 | **The notice is shown once on every boot while the fault persists; FrameShift saves nothing about it; a Device health list is always available** | PM |
| H-Q3 | **Sleep needs proximity AND stillness, or the power button. While proximity is unavailable, the rule is stillness + no input + a timer** (§2.5) | PM |
| H-Q7 | **An optional "don't remind me about this part" comes at P1, off by default** | PM |
| H-Q2 | Information-only faults are included in the toast, after the functional ones, marked "no effect on use" | Arbiter |
| H-Q5 | The IPD-sensor modules are first loaded at V0, where IPD is first used | Arbiter |
| H-Q6 | Both firmware-loader settings are applied (`ignore_sysfs_fallback=1` and `force_sysfs_fallback=0`), with the 1 s timeout kept | Arbiter |
| Crash reporting | **Valve's crash reporting is off by default on FrameShift:** the crash hook (`60-crash-hook.conf`'s `kernel.core_pattern` pipe) and `steamos-log-submitter` are masked. Crash data stays on the headset, or in our own local log with no identifiers. An opt-in may be reconsidered later only if Valve welcomes reports (a possible Valve-letter item) (A19) | PM |
| H-Q4 / D-T3 | **The product read of calibration is approved in principle.** Each user's own headset may read only its own proximity and IPD calibration files from `/persist`, read-only, at runtime; values stay on the device, are never logged or exported; `/persist` is never modified or remounted. It needs its own designed, Chair-reviewed package (FS-R-012 §8 conditions) before it runs on any headset; Unit 2's IPD calibration is treated as unreliable. **The development-time no-`/persist` rule (J-132) is unchanged.** Until the reader exists, and whenever calibration is missing or invalid: proximity is off and idle blanking applies; IPD uses the in-headset alignment (§2.5–§2.7) | PM |

---

## 0. The answer in brief

1. **Graceful degradation is a rule, not a feature.** No sensor or peripheral that is not
   safety-relevant may block the boot, the SteamOS session or SteamVR. Every consumer treats a
   missing or misbehaving part as "no input" and carries on (§1, §3).
2. **Safety stays with its owners.** Heat, fan, battery and charging-safety faults are owned by
   `fs-thermald`, which already detects them and runs the graceful shutdown (ESD; PLAN R12–R26,
   R43–R50). Eye safety of the infrared emitters is owned by the tracking process `fs-trackd`,
   whose safe state is "emitters off", with the kernel's close path as the backstop. Neither is a
   `fs-healthd` part. **One owner per fault, one notice per fault** (§1, §2.1).
3. **Degrade at once, announce after confirmation.** The owner of a device stops using a bad
   input on the **first** implausible sample and stays degraded for the rest of the boot. Only the
   *notice* waits for confirmation (§5).
4. **A new, small service, `fs-healthd`,** decides which faults to announce. It observes
   passively (sysfs structure, kernel log lines from the journal, our own boot record, and health
   reports from the processes that own devices). It reads **no sensor values itself**, never opens
   a device, never writes to hardware, never touches `/persist` (§6).
5. **The notice:** one short toast on every boot while a fault persists, early in the session,
   listing every confirmed fault in plain words and auto-dismissing after about 10 s; plus an
   always-available Device health list. FrameShift stores nothing about it (§4).
6. **Delivery** reuses the thermal notice consumers: the SteamVR overlay notification through our
   bridge (consumer (b) of PLAN §2.1); the journal always; no warning screen; the LED only for
   display faults, through the single LED owner (§4.4).
7. **Proximity needs per-unit calibration**: without it the kernel never sends the "prox enable"
   command, on any unit (§2.3 note). The PM approved, in principle, a product read of each
   headset's own proximity and IPD calibration (D-T3). Its reader, `fs-calread`, is sketched in
   §2.7 and placed at V0, behind its own Chair-reviewed package. Whenever calibration is missing or
   invalid (and until the reader exists): proximity is off and **our own idle-blanking rule**
   applies (§2.5, a V0 requirement), and IPD uses the **in-headset alignment procedure** (§2.6).
   One new leak was found: the kernel prints the proximity calibration values to the kernel log,
   which Valve's journal stores (A18, rule H-14).
8. **Audit (§3):** our stage init tolerates module failures and lowers the firmware timeout, but
   its plain `insmod` sequence lets one hung asynchronous probe stall every later module, possibly
   including the thermal service's modules (A1, the review's blocker). Rules H-1 to H-13 fix the
   load order, the firmware fallback, systemd and udev ordering, consumers and the driver.
9. **Milestones (§7):** R-1 gets the loader, firmware and ordering rules (H-1 is a Chair item: it
   changes the pinned PID 1 loader). `fs-healthd` itself, the toast, idle blanking and IPD
   alignment and the calibration reader come at **V0**, where the faulty parts are first loaded
   and used. IMU health and proximity (first used when SyncBoss is opened) come at V1, cameras and
   controllers at V2–V4; all-device tables and the Device health page at P1.

---

## 1. Principles

**P-H1 · Degrade, don't block.** A non-safety part that is missing, fails to probe, returns
errors, or returns nonsense removes only its own input. The boot continues, the session starts,
SteamVR presents the headset, and every feature that does not need that part works as normal.

**P-H2 · Safety faults belong to their safety owner.**
- **Heat and battery** (fan, thermal zones, battery gauge and the ADSP battery path, PMIC
  temperatures, `usb-conn`): owned by `fs-thermald`. Its fail-safe rules decide (sensor fault →
  SEVERE, shutdown after 120 s unless it recovers; TCD §6.4, ESD §3.3, PLAN R12–R15, R22–R26).
  *With a dead fan the headset will not stay on: that is intended and is the PM's own rule.*
- **Eye safety of infrared emitters** (flood LEDs, the depth projector, the SyncBoss proximity IR
  LED): owned by `fs-trackd`, the only process that drives them (tracking doc §8). Their safe state
  is "off", not a shutdown. If an emitter cannot be switched off, `fs-trackd` requests a normal
  shutdown, which `fs-thermald` bounds and announces like any detected shutdown (PLAN R9,
  `shutdown-requested`, CORE-SPEC K-19). If `fs-trackd` itself dies, the kernel's close path is the
  backstop (§2.1).
- `fs-healthd` never detects, reports or notifies on any of these parts.

**P-H3 · One owner per fault.** Each part has exactly one owner that degrades it and one notice
source. Heat and battery: `fs-thermald`. Infrared emitters: `fs-trackd` (escalating through
`fs-thermald`). Every other part: its **device owner** degrades it (`fs-ipd` for IPD, the bridge driver
for display, `fs-trackd` for SyncBoss, IMU and cameras, the system for the rest) and `fs-healthd`
decides the notice. Two services never show two notices for one fault (§2.1, §2.2).

**P-H4 · Observe, never actuate.** `fs-healthd` reads only structure (is the driver bound, does
the node exist), the kernel log through the journal, our own boot record and owner reports. It
reads **no sensor value**, because on this hardware even a "read" can be a write: an AK09973 raw
read in its idle mode first writes a measurement command (`ak09973.c:666-668`, mode 0 set at probe
`:962`). It never opens a device whose open changes state (SyncBoss: opening powers and resets the
MCU), never writes sysfs, never starts a remote processor, never powers a camera, never triggers an
MCU firmware update, never reads `/persist` (only `fs-calread` does, §2.7).

**P-H5 · Never wait without a bound.** Every wait on a device, file, probe, firmware request or
peer has a deadline, and the deadline's expiry is a normal, handled outcome (§3.2).

**P-H6 · Absent by design is not a fault.** Each model has its own table of parts. A part the model
does not have, that the kernel does not build, or that an image deliberately does not load or use,
is never reported (§5.3).

**P-H7 · Tell the user plainly, once per boot, and move on.** Short, non-technical words; no
serial numbers, MAC addresses, unique IDs or raw values (§4).

**P-H8 · Safety and notices never compete.** A thermal warning or shutdown notice always takes the
screen; a health toast waits or is dropped. The notice path never delays any safety action (PLAN
R49 / CORE-SPEC K-22).

---

## 2. Inventory: Quest 3 (eureka, v2.7)

Every part below is declared in the Quest 3 v2.7 runtime DT (`~/work/dtdiff/v27.dts`, line given)
and/or the v2.7 module lists [M-static]. Roles are from names, drivers and research notes; a role
not shown in source is marked [C].

**Classes.**
- **S** — safety. Owned by `fs-thermald` (heat, battery) or `fs-trackd` (infrared emitters).
  Listed here only so that ownership is explicit.
- **F** — functional. The user loses a visible function. Degrade, then notify.
- **E** — essential function (a subclass of F). Nothing useful can replace it (for example the
  display). The device still does not shut down for it; the notice uses the channels that remain.
- **I** — informational. FrameShift does not use the part today, or its loss has no visible effect.
  Logged, listed and in the toast (H-Q2).
- **N** — not used by FrameShift and not checked (we do not power or stream it). Never reported.
- **P** — unavailable by policy (something it needs is withheld on purpose). Logged once as
  policy; never a fault, never a notice.

### 2.1 Safety parts (class S): not `fs-healthd` parts

| Part | DT node / driver (module, partition) | Owner and its detection (existing design) |
|---|---|---|
| Fan | `pwm-tach-fan@0` in `/vendor` (v27.dts:32115 block); `pwm-tach-fan.ko` (odm_dlkm) | `fs-thermald`: tach checks F1–F9, fan-zone fault F8; P8 → SEVERE, shutdown after 120 s (PLAN R21–R23, R51–R57) |
| SoC / skin / board thermal zones | tsens (`qcom_tsens.ko`), PMIC ADC (`qcom-spmi-adc5-gen3.ko`), Meta virtual sensors `battery_virtual_sensor`, `display_virtual_sensor`, `surface_virtual_sensor` (`virtual_sensor.ko`, odm_dlkm) | `fs-thermald`: sensor fault P9, class minimum counts, stuck-tsens rule, hot anomaly (R12–R14, R53, R55) |
| Battery gauge | `ti,bq27z561` at I2C 0x55 on `i2c@980000` (v27.dts:5124); `bq27xxx_battery_i2c.ko` + `bq27xxx_battery.ko` (vendor_dlkm) | `fs-thermald`: battery class (R15) |
| ADSP battery and charger path | `qcom,battery_charger` under `pmic_glink`; `qti_battery_charger_main.ko`; ADSP remoteproc | `fs-thermald`: R15; P6 battery empty; P13 low; J-145 charging too warm (R17, R19) |
| USB connector temperature | zone `usb-conn` | `fs-thermald`: P5, ≥ 70 °C → shutdown (R16) |
| PMIC die temperatures | PMIC ADC channels | `fs-thermald`: P7, required before READY (R50, part 2) |
| PMIC temperature alarm | `qcom-spmi-temp-alarm.ko` — **never loaded** without a design that keeps stage-2 shutdown (PROJECT_SETUP §6A item 3, J-34) | — |
| IR flood LEDs | `pmxr2230_torch2/3`, 140 mA cap, hardware strobe from PMIC GPIO 1 (tracking doc §8.0) | `fs-trackd` Layer 1: current, mode and trigger never written; exposure and strobe bounded; watchdog |
| Depth projector | `oculus,nautilus` with its SAFETYBOSS MCU (`nautilus.ko`, odm_dlkm) | **never enabled** (tracking doc §8 item 3). **Correction (2026-10-16, H-1 work, finding H1-F4):** `nautilus.ko` (also in the v2.7 vendor_boot ramdisk) **is** entry 1 of K1a's 95-module list (`devices/quest3/stage3d/modules.load.v66`) and has probed on every stage image since stage 3d (its DT node is `status = "ok"`, with a clock, pinctrl and `vdd-supply`); whether its probe powers anything is [O]. K1a and stage 3d keep their Chair-concurred list unchanged. Later lists (K1i, TS, R-1) drop it; it comes back only in a reviewed tracking package together with the IR-emitter safety ownership above (Arbiter decision 2026-10-16; disclosed in FS-A-014) |
| SyncBoss proximity IR LED | `meta,prox-ir-supply` on the SyncBoss node (v27.dts:25726 block) | Driven by the SyncBoss firmware when proximity is enabled [C]. Proximity is never enabled under FrameShift today (§2.3 note), so the LED is expected off [C]; if proximity is ever enabled, `fs-trackd` owns it |

**Who turns the emitters off if `fs-trackd` dies.** The strobe follows camera exposure and SyncBoss
scheduling. When `fs-trackd`'s process ends, the kernel closes its descriptors: stopping the last
SyncBoss stream sends the MCU its sleep command (type 90, `syncboss_spi_core.c:1610-1630`
[M-static], tracking doc §2.3), and closing the camera session stops streaming [C, camera
request-manager release path]. With no exposure there is no strobe [C]. This backstop is tested
by killing `fs-trackd` during a fault-injection run at V2, with the emitters observed (photodiode,
tracking doc §8.0) before any user session relies on it [O until then].

The charger input itself (`cy,cypd3177` USB-PD sink, built in: `CONFIG_CHARGER_CYPD3177=y`
[M-static stock.config]) is split: its **safety** is the ADSP/PMIC hardware plus `fs-thermald`'s
battery tiers; its **function** (charging at the expected rate) is an F row below, with a
suppression rule so the two never both speak (§2.3, row 17).

### 2.2 Functional, informational and policy parts: identification

"Device owner" is the process that degrades the input; `fs-healthd` decides the notice.

| # | Part | DT node (v27.dts line) | Driver / module (partition) | Device owner | Class |
|---|---|---|---|---|---|
| 1 | **Proximity sensor** (IR prox, read by the SyncBoss MCU) | `syncboss_nrf@0` → `powerstate@0` with `meta,syncboss-has-prox` and **no** `meta,syncboss-has-no-prox-cal` (25751-25754) | `syncboss_spi.ko`, `syncboss_powerstate.ko` (odm_dlkm) | `fs-trackd` → bridge driver | F when `fs-calread` supplied a valid calibration (§2.7); **P** when calibration is missing or invalid (§2.3 note) |
| 2 | **IPD sensors** (lens position): AMS AS5510 Hall sensor and AKM AK09973 magnetometer | `as5510@0x56` (5462) and `ak09973@0x10` (5455) on `i2c@a98000`; both named in `ro.iad.sysfs_nodes` (`display-geometry-stereo.md` §0 item 4) | `as5510.ko`; `ak09973.ko` + `industrialio-triggered-buffer.ko`, `kfifo_buf.ko` (odm_dlkm, vendor_dlkm) | **`fs-ipd`** (a small helper outside `vrserver` that reads the sensors and holds any conversion, §2.7) → bridge driver (**millimetres only**: `SetDisplayEyeToHead` translation, `Prop_UserIpdMeters_Float`) | F (the conversion to mm comes from `fs-calread` when valid, §2.7; else the alignment, §2.6) |
| 3 | **SyncBoss MCU** (nRF52833; IMU, controller radio, prox, timesync) | `syncboss_nrf@0`, SPI 8 MHz (25726) | `syncboss_spi.ko`, `syncboss_direct_channel.ko`, `syncboss_miscfifo.ko`, `syncboss_timesync.ko`, `miscfifo.ko`; `meta_swd.ko` (SWD, **firmware updater: never triggered**) | `fs-trackd` | F |
| 4 | **IMU** (on SyncBoss, message type 80) | via SyncBoss | as row 3 | `fs-trackd` → head rotation (V1+) | F |
| 5 | **Controller radio** (on SyncBoss; types 133/143 [C]) | via SyncBoss | as row 3 | `fs-trackd` → controllers (V3+) | F |
| 6 | **Tracking cameras** ×4 (`CAM_OG_LEFT/RIGHT`, `CAM_OV7251_LEFT/RIGHT`) and **RGB cameras** ×2 | six `qcom,cam-sensor` nodes (12655–12823; labels from `eureka-camera.dtsi`, `tracking-input-route.md` §2.1) | `camera.ko` (vendor_dlkm), `sensorlock.ko` (odm_dlkm; TrustZone power gate) | `fs-trackd` (V2+); passthrough later | F from V2; **N before** |
| 7 | **Display panels** | DSI panels, `display_panels` (vendor node) | `msm_drm.ko` and its closure | compositor / bridge | E |
| 8 | **Backlight unit** (BLU MCU over UART, plus LED driver and panel bias) | `oculus,blu` (vendor node); `tps65132@3e` on `i2c@988000` (5247) | `blu_fw_driver.ko`, `mp3314.ko`, `tps65132-regulator.ko` (odm_dlkm) | compositor / bridge | E |
| 9 | **GPU** | `qcom,gpu-model = "Adreno740v3"` | `msm_kgsl.ko` (vendor_dlkm) | compositor (G1+) | E |
| 10 | **Speakers** (two smart amps) | `max98388@38` "RightSpk", `max98388@39` on `i2c@984000` | `snd-soc-max98388.ko` (odm_dlkm), LPASS/ADSP audio stack (`spf_core_dlkm.ko`, `q6_dlkm.ko`, macro modules) | system audio (Valve's PipeWire) | F |
| 11 | **Headphone output** (3.5 mm) | `ak4333@10` with `headset-det-gpio` on `i2c@984000` | `snd-soc-ak4333.ko` (odm_dlkm) | system audio | F |
| 12 | USB-C audio switch | `fsa4480@42` on `i2c@988000` | **driver not built**: `# CONFIG_QCOM_FSA4480_I2C is not set` (stock.config:5685) | — | **absent by design**; never reported |
| 13 | **Microphones** | LPASS VA macro, SoundWire DMIC (`swr2` va master) [C: mic topology] | `lpass_cdc_va_macro_dlkm.ko`, `swr_dmic_dlkm.ko` (vendor_dlkm) | system audio | F |
| 14 | **Wi-Fi** (QCA6490, PCIe) | `qcom,cnss-qca6490@b0000000` (13368) | `cnss2.ko` (asynchronous probe, `cnss2/main.c:4233`), `wlan.ko`, `cnss_*` (vendor_dlkm) | system (NetworkManager) | F |
| 15 | **Bluetooth** (QCA6490) | `bt_qca6490` (2998) | `btpower.ko`, `bt_fm_slim.ko` (vendor_dlkm) | system (BlueZ) | F |
| 16 | **USB-C data** | dwc3 controller and PHYs | `dwc3-msm.ko`, `phy-msm-*`, `ucsi_glink.ko`, `altmode-glink.ko` | system | E in development images; F in the product |
| 17 | **Charging function** (USB-PD sink) | `cypd3177@08` on `i2c@988000` (5224) | built in (`CONFIG_CHARGER_CYPD3177=y`) | ADSP / PMIC | F (safety part is S, §2.1) |
| 18 | **USB accessories**: charging dock, external battery ("lehua"), PD firmware initiator | `oculus,charging_dock`, `oculus,external_battery`, `meta,pdfu_initiator`, `meta,usbvdm_cypd` (vendor node) | `charging_dock.ko`, `external_battery.ko`, `pdfu_initiator.ko`, `usbvdm*.ko` (odm_dlkm) | not used by FrameShift yet | I; **absent accessory = normal** |
| 19 | **Power button** | `pmk8550` PON `pwrkey` (20561) | `pm8941-pwrkey.ko` (vendor_dlkm) | logind / Valve's `70-steamos-power-button.rules`; stuck-key filter: `fs-inputd` (row note) | F |
| 20 | **Volume up** | `gpio_keys/vol_up` (5062) | gpio-keys, built in (`CONFIG_KEYBOARD_GPIO=y`) | Steam / PipeWire; filter `fs-inputd` | F |
| 21 | **Volume down** | PON `resin` (20569), `linux,code` 0x72 | `pm8941-pwrkey.ko` | as row 20 | F |
| 22 | **Status LEDs** | tri-LED `qcom,leds@ef00` on pmxr2230 (21197); `gpio-leds/led0` "indicator" (vendor node) | `leds-qti-tri-led.ko`, `leds-gpio.ko` | **the single LED owner** (§4.4) | I (the LED is itself a notice channel) |
| 23 | **Flicker / ambient light sensor** (ST VD6283) | `vd6283@0x20` on `i2c@a98000` (5469) | `vd6281_adapter.ko` (odm_dlkm) | not used yet (passthrough anti-flicker [C]) | I |
| 24 | Magnetometer on SyncBoss | `meta,mag-supply` on the SyncBoss node | via SyncBoss | not used | N [C: role] |
| 25 | **CDSP** (compute DSP) | `qcom,msm-fastrpc-compute` | `cdsp-loader.ko`, `frpc-adsprpc.ko` | `fs-trackd` (C-DSP checkpoint) | F only when used; the fallback is the CPU |
| 26 | Real-time clock | PMIC RTC | `rtc-pm8xxx.ko` (module); `CONFIG_RTC_HCTOSYS=y`, device `rtc0` (stock.config:4810-4811) | the kernel sets the system time when `rtc0` registers (`drivers/rtc/class.c:431-434`) | **log only** (no notice; we never set the clock) |
| 27 | Headset haptics | `qcom,hv-haptics@f000` on pm8550b (20277) | **driver not built**: `# CONFIG_INPUT_QCOM_HV_HAPTICS is not set` | — | **absent by design**; never reported |
| 28 | UFS storage | — | `ufs_qcom.ko` | the boot itself | out of scope: no degradation is possible; a storage failure is a boot failure, handled by the boot path |

**Stuck keys (rows 19–21), known limitation.** A key that is stuck at power-on acts **before** any
FrameShift code runs: the PMIC's own long-press power-off and the bootloader's key combinations
(for example volume-down at power-on) are outside our control. Once the system runs, a stuck key is
ignored by **`fs-inputd`**, a small input filter in our layer that sits between the key devices and
their consumers. Its design is [O] and comes with the input stack at V0 (options: an exclusive
evdev grab with re-injection through `uinput`, or, for the power key only, a logind drop-in); it
is not part of `fs-healthd`.

### 2.3 What a fault looks like, how it is detected, and how it degrades

Detection primitives:
- **D1 · Bound check.** The DT node is present with status okay, its module loaded, but the device
  has no `driver` link in sysfs after the probe window → probe failed or deferred. Read-only sysfs
  structure; no attribute values.
- **D2 · Load record.** Our initramfs records every module result (`MODULE_OK`, `MODULE_FAIL`,
  `MODULE_TIMEOUT` with its `initstate`, H-1) to `/run/fs-init/modules.log`, which survives
  `switch_root`. `fs-healthd` reads it.
- **D3 · Expected node.** The class node the part should create exists: an IIO device, an input
  device by name, an ALSA card, `wlan0`, `hci0`, an LED class device, a misc device. Existence
  only.
- **D4 · Kernel log patterns.** A fixed, per-model list of driver error lines, read from the
  journal's kernel transport (`_TRANSPORT=kernel`), because `CONFIG_SECURITY_DMESG_RESTRICT=y`
  (stock.config:6590) keeps `/dev/kmsg` from unprivileged readers. Examples: `[AK09973] I2C Read
  Error` (`ak09973.c:313`), `[AK09973]i2c read failure` and `Device ID Error` (`:862-873`),
  as5510 `Failed to initialize device registers` (`as5510.c:262`). Matched by fixed strings; nothing
  from the log is ever executed.
- **D6 · Owner report.** The device owner reports `ok` / `fault:<code>` / `unused` for its parts
  over a local socket (§6.3). This is the **only** route for sensor values: the owner reads them,
  applies H-6, degrades at once, and reports.

There is no "D5" in `fs-healthd`: value plausibility is the device owner's job (P-H4).

**When:** a **boot check** (B) once, starting with `fs-healthd`, bounded to 60 s; **runtime** (R)
from owner reports and new kernel-log lines. Nothing is checked before a part is meant to be in use
(class N).

| # | Part | How a fault shows | Owner's degradation (at once) | `fs-healthd` detection (for the notice) | Notice wording (plain) |
|---|---|---|---|---|---|
| 1 | Proximity | **Without valid calibration: never enabled** (note below; policy, not a fault). With calibration: stuck "worn", stuck "removed", or flapping | Without calibration: not used at all; the bridge declares **no proximity sensor** to SteamVR; sleep follows §2.5. With calibration: `fs-trackd` drops the input on the first contradiction with activity, keeps it dropped for the boot, and sleep falls back to §2.5 | Without calibration: none (P; Device health shows "proximity: off, calibration not available"; no toast). With calibration: D6 from `fs-trackd` (proximity "removed" while the user is visibly active in ≥ 3 episodes, or > 6 transitions a minute while the IMU shows steady wear) | "FYI: the proximity sensor isn't working. The headset won't sleep as soon as you take it off; it will sleep after a few minutes of no movement, or press the power button." |
| 2 | IPD sensors | Probe fails (no node: AK09973 WHO-AM-I fail; AS5510 register init fail → `-ENODEV`); AS5510 reads return **an empty read** on an I2C failure and `-EAGAIN` on parity or compensation errors (`as5510.c:119-134`); AK09973 reads return **0 with success** on an I2C failure (`ak09973.c:311-315`), so a dead device looks like a value stuck at exactly 0; values out of range, stuck while the wheel moves, or the two sensors disagree | `fs-ipd` (the only reader) hands the bridge the **aligned IPD** (§2.6) whenever the sensors are absent, the calibration is missing or invalid (§2.7), or a sample is implausible — the first bad sample is enough, and the sensors are not used again that boot | D1/D2/D3 (B); D4 `[AK09973] I2C Read Error` and the probe lines (B, R); D6 from `fs-ipd`: stuck-at-0 together with that log line, AS5510 empty reads, and the two-sensor cross-check (both follow the lens carriage, so their changes must move together [D]) | "FYI: the lens-distance (IPD) sensor isn't working. Use IPD alignment in FrameShift settings so the picture matches your lenses." |
| 3 | SyncBoss MCU | Open fails (`enable_mcu failed`, `syncboss_powerstate.c:316-325`), no messages, or resets | `fs-trackd`: fixed pose for the boot (rows 4, 5 follow) | D6 (B when `fs-trackd` starts; R) | "FYI: the motion and controller chip isn't responding. Head tracking and controllers are off; the desktop and flat games still work." |
| 4 | IMU | No type-80 messages at the expected rate; NaN or saturated gyro/accelerometer values; rates beyond the sensor's range; accelerometer magnitude far from 1 g at rest | `fs-trackd`: **on the first implausible sample**, fixed-pose mode for the rest of the boot (H-9). Idle blanking falls back to "no input + timer" (§2.5) | D6 | "FYI: the head-motion sensor isn't working. The view will stay fixed in front of you." |
| 5 | Controller radio | Radio start fails; no controller data although controllers are on | `fs-trackd`: controllers off for the boot | D6 (from V3) | "FYI: the controller radio isn't working. Touch controllers won't connect; Bluetooth gamepads still work." |
| 6 | Cameras | Stream start fails; no start-of-frame within its window; frozen frames (identical or zero-variance); one camera dark while its pair sees light | `fs-trackd`: on the first implausible frame set, the camera is dropped; with too few cameras, **3DoF plus fade** (tracking doc §8 item 6) for the boot; RGB lost → passthrough off | D6 (from V2) | "FYI: a tracking camera isn't working. Tracking is limited to looking around (no walking)." |
| 7 | Display panels | Probe or commit failure; one eye dark | Nothing replaces a panel; the session keeps running | D1/D3 (B); D6 from the compositor or bridge (commit errors) (R) | LED "display fault" pattern through the LED owner, and one tone if audio works (§4.4) |
| 8 | Backlight unit | BLU MCU not responding; backlight node missing | As row 7 | D1/D3 (B) | As row 7 |
| 9 | GPU | KGSL probe or firmware failure; GPU hang | As row 7 at V0+; a GPU hang is the compositor's recovery path | D1/D3 (B); D6 from the compositor | As row 7 |
| 10 | Speakers | Amp probe fails; ALSA card missing; speaker-protection errors in the log | The other speaker or headphones; one amp lost → mono on the working side [C: needs a mixer profile] | D1/D3/D4 (B) | "FYI: a built-in speaker isn't working. Sound will be quieter or one-sided; headphones still work." |
| 11 | Headphone output | Probe fails | Speakers only | D1/D3 (B); jack-detection faults are not detectable without a plug event, so only probe-level faults are reported | "FYI: the headphone jack isn't working. Use the built-in speakers or Bluetooth headphones." |
| 13 | Microphones | Codec or DMIC missing; capture device absent | Voice input off | D1/D3 (B) | "FYI: the microphone isn't working. Voice chat won't work." |
| 14 | Wi-Fi | `cnss2` probe or firmware failure; no `wlan0` | Offline; Steam's offline mode | D1/D2/D3 (B; asynchronous probe, so within the 60 s window) | "FYI: Wi-Fi isn't working. Steam will run in offline mode." |
| 15 | Bluetooth | No `hci0`; firmware load failure | No BT devices | D3/D4 (B) | "FYI: Bluetooth isn't working. Bluetooth headphones and gamepads won't connect." |
| 16 | USB-C data | Controller or PHY probe fails | Product: no PC link. Development: the boot path's own failure (no host link) | D1 (B) | "FYI: the USB-C data connection isn't working. Charging still works." |
| 17 | Charging function | PD sink probe fails; a charger is attached but the battery stays "not charging" for 10 min | Charging may be at the default 5 V rate or not at all; `fs-thermald`'s battery tiers still protect | D1 (B); "not charging" comes from `fs-thermald`'s state file (it already reads the supply nodes), **suppressed** while it reports any battery or charging reason (J-145, battery tiers), while the battery is full, or while the battery temperature is outside the charging window | "FYI: the headset isn't charging normally. Try another charger or cable." |
| 18 | USB accessories | Accessory attached but its driver reports errors | Accessory features off | D4 (R) | "FYI: the attached accessory isn't working with this headset." |
| 19–21 | Buttons | A key held "down" for > 30 s, or chatter (> 10 events a second) | `fs-inputd` ignores the key until it is released and pressed again (§2.2 note) | D6 from `fs-inputd` | "FYI: the volume-down button seems stuck. It will be ignored until it works again." |
| 22 | LEDs | LED class device missing | No LED feedback; the toast still works | D3 (B) | "FYI: the status light isn't working." |
| 23 | Flicker / ambient light sensor | Probe fails | None today | D1/D4 (B) | "FYI: the light sensor isn't working (no effect on use)." |
| 25 | CDSP | Remote processor fails to start | CPU fallback | D6 (only when offload is enabled) | (journal only; not a part the user knows) |
| 26 | RTC | Read error, or a time before the image's build date at boot | Time from the network | D4 (B) | (journal only) |

**Without calibration, proximity is unavailable on every unit, not only on Units 1 and 2
[M-static; D].**
- The Quest 3 DT gives the powerstate node `meta,syncboss-has-prox` and **not**
  `meta,syncboss-has-no-prox-cal` (v27.dts:25751-25754), so `requires_prox_cal` is true
  (`syncboss_powerstate.c:501`).
- The calibration (`PROX_PS_CAL_VERSION`, `PROX_PS_CANC`, `PROX_PS_THDL`, `PROX_PS_THDH`) is
  requested through the firmware loader on the first open (`:37-50`, `:90-122`). Under Android it
  is served from Meta's calibration store [C: consistent with the `prox/` names in
  `/persist/calibration`, J-131]. FrameShift does not read `/persist` (PM, J-132).
- With no valid calibration, `push_prox_cal_and_enable_wake()` **returns before** the
  enable/disable message is queued (`:136-140`; the enable is at `:178-183`). So the kernel never
  sends "prox enable" to the MCU on any unit. What the MCU does with proximity after its own reset
  is [C: presumably disabled].
- Therefore (PM decision D-T3/H-Q4): proximity works only once `fs-calread` (§2.7) supplies the
  unit's own valid calibration. Until the reader exists, and whenever the calibration is missing
  or invalid: **no proximity input and no proximity fault notice**, and sleep follows §2.5. The
  kernel's "failed read prox calibration data" line is then expected policy, not detection. Units 1
  and 2's faulty proximity sensors become visible (and detectable as faulty) only once calibration
  is supplied and SyncBoss is opened (V1).

**Unit 2's IPD fault on Horizon** is consistent with the read behaviour above (AS5510 empty reads
and `-EAGAIN`; AK09973 zeros with success) and an Android consumer that does not tolerate it [C: the
HAL's code was not read]. `fs-ipd` must (rule H-6).

### 2.4 Other models (short)

Each model gets its own table, copied from its own DT, config and module lists (PROJECT_SETUP §6A
item 3's "per device, never assumed" rule applies here too).
- **Quest 3S (panther)**, same kernel tree: its DT declares `akm,ak09973`, `ams,as5510`,
  `meta,syncboss-has-prox` and VD6281 flicker sensors (`panther-base.dtsi`) [M-static]. The 3S has a
  stepped (three-position) lens adjustment [C, public specification], so whether both IPD sensors
  are populated, and what "plausible" means, are [O]. Its proximity calibration rule is read from
  its own DT.
- **Quest 2 (hollywood)**: an `as5510` labelled `ipd_sensor`, SyncBoss nRF52832 with proximity
  (`hollywood-*.dtsi`) [M-static]; different Wi-Fi, audio and fan hardware; its S rows come from its
  own thermal tables (ESD §3.2).
- **Quest Pro (seacliff)**: `ipd_sensor`, `prox-cal`, SyncBoss nRF52840 with proximity, and an
  eye-tracking camera `CAM_ET` (`seacliff-camera.dtsi`) [M-static]; face tracking cameras [C]. Eye
  and face tracking rows are class N until FrameShift uses them.
- **Quest 1**: different SoC and kernel; its own table when that port starts.

### 2.5 Idle blanking (V0 requirement; PM decision H-Q3)

Proximity is unavailable whenever calibration is missing or invalid, and on any unit before the
reader exists (§2.3), and there is no suspend (PROJECT_SETUP §6A P10). Without a rule of our own the
display would stay lit after the headset is taken off.

**The rule (PM, 2026-10-15):** sleep needs **proximity AND stillness**, or the power button. While
proximity is unavailable: **stillness + no input + a timer**. **At V0 there is no IMU in use**
(SyncBoss is first opened at V1), so at V0 the rule is **no input for T**, with the idle inhibit
below.
- **Owner:** the bridge driver, in our layer (no Valve file changed). It decides; the display is
  turned off through the compositor's supported standby path [C: the exact SteamVR or gamescope
  interface is chosen when the bridge is written, O-H5].
- **Blank** when, for a continuous period T (proposed 5 min; a user setting within bounds):
  the IMU shows the headset still (below a motion threshold) **and** there is no controller,
  button, keyboard or pointer input. At V0 (no IMU in use) or with an IMU fault (row 4): no input
  for T.
- **Idle inhibit:** while the running app or media player holds an idle inhibitor (for example a
  video playing), the timer does not run. The bridge honours the session's standard inhibitors
  [C: the logind `idle` inhibitor and the compositor's idle-inhibit protocol; which ones Steam and
  gamescope use is O-H5]. The power button always sleeps.
- **With proximity** (valid calibration, healthy sensor): proximity "removed" **and** still for a
  short time (proposed 10 s). Proximity alone never blanks.
- **Wake** on any motion above the threshold, any input, or the power button.
- **While blanked, rendering stops or is throttled** (the compositor is asked to stop presenting
  frames, or to drop to a minimal rate [C: mechanism O-H5]), to save battery and heat; the app may
  be paused by the session as on the Frame [C].
- **Never** a cooling control: the fan keeps following temperature while blanked (§6A item 3;
  TCD §3.3). Blanking is not suspend.
- **Pass condition (V0):** on both units, with no input for T and no idle inhibitor, the display
  turns off and frame presentation stops or drops to the minimal rate; it comes back on the first
  input or the power button; with a video playing (an inhibitor held) it stays on. **V1 adds:**
  it never blanks while the PM is wearing it and moving.

### 2.6 IPD at V0: in-headset alignment (the fallback, and always available)

The raw-to-mm conversion is per-unit data in `/persist` (J-132), and the user cannot read the
lens-wheel position. The calibrated path (§2.7) needs a Chair-reviewed reader and a conversion
whose semantics are established; until then, and whenever the calibration is missing, invalid or
unreliable (Unit 2, FS-R-012 §8), the alignment below is the IPD path. It stays available to every
user as a check and an override.

**Procedure (a V0 feature, in our settings overlay; design [C], to be validated with the PM):**
1. **Lens wheel first (optical).** A per-eye target (a fine-text card and a centred cross on a
   plain field) is shown; the user turns the wheel until both eyes see the text sharpest and the
   crosses centred. This puts the lenses on the user's eyes; it needs no software value.
2. **Rendering IPD (stereo).** Panels move with the lenses on the Quest 3 [D,
   `display-geometry-stereo.md` §2.2], so the rendering IPD should equal the lens spacing the user
   just set. The user enters a known IPD if they have one (optician or phone measurement), else the
   default (63–64 mm) is used. Then a depth check: a virtual card of known size at arm's length (and
   from V3, beside the tracked controller); the user moves a slider until its size and distance look
   right and a far grid shows no double image. Steps of 0.5 mm.
3. **Clamped** to the lens range of the model (Quest 3 about 58–70 mm [C, public specification;
   confirm from Meta's published values]).
4. **Stored** as a user setting in FrameShift's own settings (a user preference the user chose to
   set, not a fault record; never `/persist`). Re-runnable at any time.
5. **Sensors as helpers without calibration:** if `fs-ipd` has two healthy, agreeing IPD sensors
   but no valid calibration, it may detect that the wheel has moved since the last alignment and
   suggest re-running step 2. It never turns a raw value into millimetres without calibration (P).
6. **With valid calibration (§2.7):** `fs-ipd` follows the wheel live and the bridge receives millimetres, and step 2
   becomes an optional check. If the calibrated value and a fresh alignment differ by more than a
   small tolerance (proposed 2 mm), the alignment wins for that user and the calibration is not used
   for IPD again on that unit until the user resets it.

### 2.7 The calibration reader `fs-calread` (V0; its own Chair-reviewed package)

**What it is.** A one-shot, read-only helper, our own code (Apache-2.0), that reads **only this
headset's own** proximity and IPD calibration from Meta's `persist` partition and hands validated
values to their consumers. It is the product side of the PM's D-T3 approval and of FS-R-012 §8's
accepted runtime-read class. **It runs on no headset before its package is Chair-reviewed, and the
development-time no-`/persist` rule (J-132) stays in force until the PM lifts it.**

**Owner and shape.**
- `fs-calread` is a sibling of `fs-metacfg` (PLAN §1): the same spawn rules (spawned by PID 1 in
  the initramfs, killed and ignored on expiry), `O_RDONLY` open of the `persist` block device by
  partition name and size, one size ioctl, a seccomp filter after the open, no mount call, no
  device-mapper device. `persist` is never mounted or remounted, in our initramfs or under Valve's
  userspace (FS-A-013 §3.7 keeps any Quest partition away from `/persist`).
- **Its ext4 reader is a variant of `fs-metacfg`'s**, not the same acceptance: `persist` is a
  journalled, read-write ext4 [C: mounted read-write by Android, `display-geometry-stereo.md` §3],
  so the exact feature words `fs-metacfg` requires for `vendor` would reject it. The variant
  **accepts `has_journal`** and reads the main filesystem only, and **refuses** the image if it
  needs recovery (`needs_recovery` set) or carries orphan state (a nonzero orphan list head, or an
  orphan file in use), because then the on-disk tree may not match the last clean state. Any
  feature it does not know → refuse. The real feature set of the units' `persist` is [O] (from
  fixtures and documentation only, never from the PM's units while the development rule stands).
- **Write barrier:** `fs-blkguard` (FS-A-013 §3.3) is armed **before** `fs-calread` runs and is the
  technical barrier against any write to `persist`; the `O_RDONLY` open, the absence of any mount
  call and the seccomp filter (no `write` to the block descriptor, no `ioctl` beyond the size query)
  are the other three layers.
- **No core dumps:** `fs-calread` sets `PR_SET_DUMPABLE` to 0 and `RLIMIT_CORE` to 0 before it opens
  anything, so no crash of it can reach Valve's core-dump pipe (A19). `fs-ipd` does the same.
- **When:** in the initramfs, before `switch_root` and before anything opens SyncBoss, after
  `ufs_qcom` and its closure are loaded. Those load in **phase S** of H-1 whenever the image reads
  `super` (for `fs-metacfg`) or `persist`, so they are never behind phase F. `fs-calread` first
  waits for the `persist` by-name node with a bound (proposed 5 s, event-driven, then one scan),
  then reads within its own deadline (2 s, as `fs-metacfg`); either expiry → fallback.

**Which files (allowlist).** Exact paths only, no directory walk beyond resolving them; the
allowlist is in the package, not here, because the per-unit names and formats are recorded only in
the private calibration note (J-131, J-132):
- the proximity calibration file(s) under `persist/calibration/` whose contents become the four
  values the kernel requests (`PROX_PS_CAL_VERSION`, `PROX_PS_CANC`, `PROX_PS_THDL`, `PROX_PS_THDH`,
  `syncboss_powerstate.c:106-109`). Which `persist` file holds which value is [O]: until it is
  **established** (from GPL source or Meta documentation, not by guessing from a value's size), it
  is not applied (FS-R-012 §8);
- the display calibration file's two-point IPD conversion (J-132). Its field semantics (which raw
  value maps to which millimetre value, for which sensor) are [O]; until established, it is **not
  applied** and IPD uses §2.6.

**Validation before use** (any failure → that value set is discarded and the fallback applies):
- file present, regular, within a fixed size bound; strict schema (unknown or duplicate keys
  rejected); every number finite and integral where the consumer expects an integer;
- units and semantics established for every field applied (otherwise not applied);
- ranges: proximity values within the `u16` range the kernel casts them to
  (`syncboss_powerstate.c:169-171`); tighter plausibility bounds are **[O]**: no known-good unit
  exists to derive them from (both of the PM's units have faulty proximity sensors), so they come
  from GPL source or Meta documentation, or later from consenting testers' units, never as
  committed values; the IPD conversion monotonic, its two points distinct, and the converted
  current reading inside the model's lens range;
- per-unit consistency: the two IPD sensors converted must agree; for proximity, the version field
  must be one the package lists.
- **Unit 2:** its IPD calibration is treated as unreliable (FS-R-012 §8). The agreement and range
  checks are what refuse a unit like it, and the alignment (§2.6) remains the user's override. (A
  refusal keyed to a unit's identity is not used: it would need an identifier in our tables and
  logs, H-13, and Unit 2 does not run `fs-calread` while the development rule stands.)

**Hand-off without logging.**
- **Proximity:** the four values are written as four small text files into the initramfs's
  firmware staging directory in RAM (`/run/fs-fw/`, root-only, 0400; the directory
  `firmware_class.path` names, H-2), so the kernel's own firmware request on the first powerstate
  open finds them, without any `/persist` access by the kernel. The kernel reads them **once per
  boot** (`prox_cal_read_attempted`, `syncboss_powerstate.c:100-104`), so they are **deleted** by a
  root one-shot right after `fs-trackd` reports its first successful powerstate open, or 10 minutes
  after `switch_root`, whichever is first. Deleting them before the open is safe: proximity then
  stays off (fallback). The files never leave tmpfs.
- **IPD:** the validated conversion goes into one root-created tmpfs file readable only by
  **`fs-ipd`'s** user (0400). `fs-ipd` is a small separate process (no network, no core dumps,
  confined like `fs-healthd`) that reads the IPD sensors (H-6), applies the conversion and hands the
  bridge **only the resulting millimetres** over a local socket. The conversion never enters
  `vrserver`, whose crashes reach Valve's crash handling (A19), nor the journal, SteamVR's settings
  or any export.
- **Outcome codes only** are logged: `fs-calread: prox=ok|missing|invalid:<rule>`,
  `ipd=ok|missing|invalid:<rule>|unestablished`. No values, no file contents, no serials (H-13).
- **Kernel log leak (A18):** the kernel itself prints the proximity values on read, on failure and
  on a parse error, and a dynamic-debug hex dump would print the calibration packet; rule H-14
  removes or forbids all of them before proximity calibration is ever supplied.

**Failure → fallback.** Missing, invalid, unestablished or timed out: proximity off, idle blanking
(§2.5); IPD alignment (§2.6). Device health shows "proximity: off, calibration not available" as
information (no toast; it is not a sensor fault). Nothing is retried in that boot.

**Tests (offline, for its package):** the `fs-metacfg` fixture pattern — synthetic ext4 images with
valid, missing, oversized, malformed, out-of-range, non-finite and duplicate-key calibration files;
the C reader against an independent Python reader; seccomp and syscall-list checks; a check that
no value appears in any log line or in any file outside the two hand-off files.

---

## 3. Audit: where a faulty part could block the boot or a service today

### 3.1 Findings

| # | Where | Finding | Tag | Rule |
|---|---|---|---|---|
| A1 | Our stage init loader (`devices/quest3/stage3d/init.sh:151-163` on master; the same loader in `devices/quest3/k1a/init.sh:138-150` on branch `feat/k1a-kernel`) and the 5.10 module core | A failed `insmod` is logged (`MODULE_FAIL`) and the boot continues: probe **failure** is tolerated. **But a hung asynchronous probe stalls every later module.** In this tree `do_init_module()` calls `async_synchronize_full()` for every module loaded without the `async_probe` parameter (`kernel/module.c:3799-3800`), which waits for **all** pending asynchronous work, including probes scheduled by earlier modules. Drivers that prefer asynchronous probing schedule their probes that way (`drivers/base/dd.c:1112-1121`): SyncBoss (`syncboss_spi_core.c:2181`) and Wi-Fi (`cnss2/main.c:4233`) among them. So a dead MCU or Wi-Fi chip whose probe hangs blocks **its own** plain `insmod`, and then **every later plain `insmod`**. With a per-module deadline alone, each later module would hit the deadline and a total budget would skip the rest — possibly the thermal service's modules (tsens, the gauge, the fan), so `fs-thermald`'s self-test would fail and the device would shut down for a Wi-Fi fault. In stage images the fixed deadline reboots the unit; a product init has no such deadline | [M-static]; [D] | **H-1** |
| A2 | Kernel config | `CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y` (stock.config:1728) forces the sysfs fallback for every firmware request, including `firmware_request_nowarn` (`drivers/base/firmware_loader/fallback.c:598-625`), with a 60 s default (`fallback_table.c:20-21`). With no `ueventd` to answer, each missing file stalls its caller 60 s. `ignore_sysfs_fallback` overrides even the forced fallback (`fallback.c:610-613`) | [M-static]; [D] | H-2 |
| A3 | Callers of A2 on our path | SyncBoss powerstate makes **four** calibration requests inside `open()` while holding its device mutex (`syncboss_powerstate.c:44, 106-109, 294-325`): up to 4 × 60 s at the default timeout. The SWD update path requests `syncboss.bin` (`fwupdate_manager.c:751`); `sensorlock` requests its trustlet (`sensorlock.c:337`) | [M-static] | H-2 |
| A4 | Stage images | `/sys/class/firmware/timeout` is set to 1 before any module load (`stage3d/init.sh:182`, all stage inits): this already limits A3 to about 4 s | [M-static] | H-2 keeps it and goes further |
| A5 | Built-in drivers | Drivers built into the kernel probe before our PID 1 can change the firmware settings. Whether any of them requests a missing file on our image is not established | [O] | H-2 (check on K1a's boot log) |
| A6 | AS5510 sysfs | `adc_raw_value` returns an **empty read** on an I2C error and `-EAGAIN` on parity or compensation errors (`as5510.c:119-134`). A consumer that loops on `EAGAIN` or parses an empty read can spin or crash. `sensitivity_value` and `config_value` are read-write attributes (`as5510.c:172, :206`): never written | [M-static]; [C] for the Android link | H-6 |
| A7 | AK09973 | Probe fails (`-EIO` / `-EINVAL`) on a failed or wrong WHO-AM-I read (`ak09973.c:862-873`): no IIO device appears. A raw read in mode 0 first **writes** a single-measurement command and sleeps (`:666-668`; mode 0 at probe, `:962`); an I2C read error returns zeros **with success** (`:311-315`). The IIO `reg` attribute (`:618-628`, mode 0660) gives raw register access: never touched | [M-static] | H-6, P-H4 |
| A8 | I2C | Each I2C transfer waits at most about 1 s (`i2c-msm-geni.c:368` etc., `wait_for_completion_timeout(…, HZ)`), so a dead device costs time but does not hang forever. The IPD and light-sensor bus `i2c@a98000` has **no** `qcom,bus-recovery` in the DT, unlike `i2c@980000` (v27.dts) — a stuck bus stays stuck for the boot | [M-static] | H-6, H-7 |
| A9 | SyncBoss | Its SPI driver prefers asynchronous probing (`syncboss_spi_core.c:2181`), which **does not** protect the loader: loaded plainly, its own `insmod` still waits for its probe at `async_synchronize_full()`, and so does every later plain `insmod` (A1). Opening a SyncBoss node powers and resets the MCU; a failed `enable_mcu` aborts the open (`syncboss_powerstate.c:316-325`) | [M-static]; [D] | H-1, H-8 |
| A10 | Module latch (FS-A-013 §3.3) | After `kernel.modules_disabled=1`, udev's autoload attempts fail at once instead of waiting [C]. A module that failed or timed out in the initramfs cannot be retried later, so its loss must be reported, not retried in a loop | [C] | H-1, D2 |
| A11 | Valve units and udev rules (0.3.0) | `set-bluetooth-mac-address.service` (`Requires=`/`After=` `bluetooth.service` and the `hci0` device) **is started by udev**: `90-mac-addresses.rules` adds `ENV{SYSTEMD_WANTS}="set-bluetooth-mac-address.service"` when `hci0` appears. It runs a Frame MAC script (`/usr/lib/deckard-hw-support/set_mac_addresses.sh --bluetooth`). `set-wifi-mac-address.service` (`Requires=`/`After=` the `wlan0` device, `Before=NetworkManager.service`) has no wants link or udev trigger found; if it were pulled, a Wi-Fi fault would hold NetworkManager back for the device timeout (systemd default 90 s). Both are Frame hardware support, to be masked with the other Frame-hardware units, **including the udev rule** (the coordinator adds it to FS-A-013's mask list) | [M-static 0.3.0]; [C] systemd semantics; [O] on 0.4.5 | H-4 |
| A12 | Valve units (0.3.0) | `NetworkManager-wait-online.service` is enabled (`/etc/systemd/system/network-online.target.wants/`): anything ordered after `network-online.target` waits on Wi-Fi | [M-static 0.3.0] | H-4 |
| A13 | Valve units (0.3.0) | Frame-hardware units enabled in the image: `deckard-fan-control.service` (`/usr/lib/systemd/system/multi-user.target.wants/`) and **`deckard-audio-setup.service`** (`/etc/systemd/system/default.target.wants/`; runs `/usr/share/deckard-audio-config/soundsetup.sh`). Both belong on the Frame-hardware mask list. `systemd-udev-settle.service` is pulled only by an initrd unit, not by the booted system; `systemd-backlight@.service` is masked by Valve (`/etc/systemd/system/… → /dev/null`) | [M-static 0.3.0]; [O] on 0.4.5 | H-4 |
| A14 | SteamVR | `vrserver` needs the headset from our bridge driver. If the driver failed its activation because a sensor was missing, SteamVR would report "headset not found": the whole session lost for one sensor | [C] (driver not written) | H-9 |
| A15 | Thermal gate | `fs-thermald`'s self-test and the initramfs gate refuse or shut down for **S** faults only (PLAN R26, R28); KGSL absence only skips GPU caps (PLAN §1.1). No F part is in its required set — consistent with P-H2. A1 is the one way an F fault could still reach it, through module loading; H-1 closes it | [M-static, PLAN] | H-1, H-10 |
| A16 | Deferred probes | A device whose supplier never appears stays deferred; this never blocks `insmod` [C, driver-core semantics]. It shows only as an unbound device | [C] | D1 |
| A17 | Journal | Valve's image sets `Storage=persistent` (`/usr/lib/systemd/journald.conf.d/persistent-store.conf:10`) and ships `/var/log/journal`. Every journal line, including ours, is kept across boots | [M-static 0.3.0] | H-13 |
| A18 | SyncBoss kernel messages | The powerstate driver prints calibration values at three sites: `failed to parse integer out of %s` prints the file's content (`syncboss_powerstate.c:66`); "failed read prox calibration data (ver: %u, canc: %d, thdl: %d, thdh: %d)" (`:112-115`, the version at `:113`); `prox cal read: canc: %d, thdl: %d, thdh: %d` (`:119-121`). With `CONFIG_DYNAMIC_DEBUG=y` (stock.config:6991) the SPI core can hex-dump every packet sent and received (`syncboss_spi_core.c:716`, `:1117`), which would include the SET_PROX_CAL packet. journald copies kernel messages into the persistent journal (A17); the pstore console (`CONFIG_PSTORE_CONSOLE=y`, `CONFIG_PSTORE_RAM=y`, stock.config:6512-6514) and the Qualcomm minidump (`CONFIG_QCOM_MINIDUMP=y`, `CONFIG_QCOM_MINIDUMP_PSTORE=y`, :5644-5651) copy the kernel log too, so they are safe only once the kernel log is | [M-static]; [D] | H-14 |
| A19 | Valve crash handling (0.3.0) | `kernel.core_pattern` pipes every core dump to `steamos_log_submitter` (`/usr/lib/sysctl.d/60-crash-hook.conf`), whose helpers collect the journal, kdump, minidumps and device core dumps (`steamos_log_submitter/helpers/` `journal.py`, `kdump.py`, `minidump.py`, `devcoredump.py`; hooks `coredump.py`, `devcoredump.py`), and `steamos-log-submitter.service` is enabled (`multi-user.target.wants`). A crash of any process holding calibration values (for example `vrserver`) could carry them into an upload | [M-static 0.3.0]; [C] what is uploaded; [O] on 0.4.5 | **PM decision (2026-10-15): masked by default** — the `core_pattern` pipe of `60-crash-hook.conf` and `steamos-log-submitter` (its service and udev rule), an FS-A-013 mask item; crash data stays on the headset or in our own local log with no identifiers; an opt-in only if Valve later welcomes reports (Valve-letter item). The no-dump rules for `fs-calread` and `fs-ipd` and keeping the conversion out of `vrserver` stay, as defence in depth |

### 3.2 Rules (binding for every FrameShift image and unit from R-1 on)

- **H-1 · Ordered, bounded module loading** (a change to the reviewed PID 1 loader: **a Chair
  item**, listed with the R-1 composition).
  1. **Phase S first:** the modules `fs-thermald` needs and their dependency closure (tsens, PMIC
     ADC, virtual sensors, the gauge, the ADSP battery chain, the fan, cpufreq; the list comes from
     `fs-thermald`'s device tables) load **before any other module**, plainly, in dependency order.
     Nothing asynchronous from other modules is pending yet. A hang or failure here is an S fault and
     is left to `fs-thermald`'s fail-safe (it is a safety part). **No budget ever skips an S
     module:** each is attempted, each with its own deadline.
     Some S-closure drivers prefer asynchronous probing (for example the SPMI PMIC arbiter,
     `spmi-pmic-arb.c:1896`); loading them plainly in phase S is correct, because the plain
     `insmod` of the next S module then waits for their probes, which S needs anyway.
  2. **Phase E next:** the essential closures (display, USB gadget, LED), plainly, each with a
     deadline, inside a **total phase-E budget** (proposed 30 s). On exhaustion the rest of phase E
     is recorded `MODULE_SKIPPED` and the loader moves on to phase F; a missing essential part is
     then a row 7–9 or row 16 fault.
  3. **Phase F last:** every other module is loaded **with the generic `async_probe` parameter**
     (`kernel/module.c:3979-3981`), so its init does not call `async_synchronize_full()` and its
     probes run asynchronously (`drivers/base/dd.c:778-796`). From the start of phase F, **no
     plain `insmod` follows.** Drivers that force synchronous probing still probe inside their own
     `insmod`; the per-module deadline covers them.
  4. **Deadlines:** each `insmod` runs in a child with a deadline (proposed 10 s); phase F has a
     total budget (proposed 60 s). On expiry the loader reads `/sys/module/<name>/initstate`
     (`kernel/module.c:1201-1223`) and records `MODULE_TIMEOUT <name> initstate=<coming|live|…>`
     (D2): `coming` = stuck in its init; `live` = loaded, probes may still be pending. It never
     waits for that child again (a child stuck in the kernel cannot be killed; it is reaped later).
     Failures are recorded, never retried.
  5. The module latch is set after phase F ends, whatever its outcome.
  6. **Test (QEMU, §6.6 item 4):** a test module whose driver prefers asynchronous probing and whose
     probe hangs, loaded before an S-class test module: with the old loader the S module stalls
     (negative control); with H-1 the S module is loaded first and the boot reaches its target
     within budget.
- **H-2 · No firmware stall.** Before any module load, the initramfs writes
  `/proc/sys/kernel/firmware_config/ignore_sysfs_fallback` = 1 and `force_sysfs_fallback` = 0, and
  keeps `/sys/class/firmware/timeout` = 1 (H-Q6). All three are volatile kernel settings. A missing
  file then fails at once. Firmware the image needs is staged in one directory named by
  `firmware_class.path` (FS-A-013 §3.6). The K1a boot log is checked for firmware requests made by
  built-in drivers before PID 1 (A5).
- **H-3 · Never wait without a bound.** Every wait for a device node, sysfs attribute, socket peer
  or probe result in our code has a deadline; expiry is a handled outcome, logged once.
- **H-4 · systemd and udev ordering.** Our units use `Wants=` and `After=`, never `Requires=`,
  `BindsTo=` or `Requisite=` on a `.device` unit or on any sensor or peripheral service. Every
  unit of ours sets `TimeoutStartSec=` and `JobTimeoutSec=`. `fs-console.target` and later targets
  never pull `network-online.target` or `systemd-udev-settle.service`. Valve's Frame-hardware
  units stay masked (FS-A-013 §3.7), including the MAC-address units, `deckard-audio-setup`,
  `deckard-fan-control` **and the udev rules that start units through `SYSTEMD_WANTS`**
  (`90-mac-addresses.rules`). A static lint over our layer and Valve's 0.4.5 units and udev rules
  enforces this (§6.6 item 5).
- **H-5 · Probe failure is normal.** No image treats a module or probe failure of a non-S part as a
  boot failure. Only the module index pin (a mismatched vendor index, `stage3d/init.sh:172-179`)
  and S parts (H-10) stop a boot.
- **H-6 · Tolerant consumers.** Every reader of a sensor value (the device owners): treats a
  missing node as "no sensor"; treats an empty read, a parse error, `EAGAIN` or `EIO` as "no
  sample"; treats a value stuck at exactly 0 from the AK09973 as suspect (A7); retries at most a few
  times with back-off, then stops for the rest of the boot and reports; never crashes on a bad
  value; validates ranges. Nobody writes a sensor's read-write attributes (A6, A7).
- **H-7 · Off the hot path.** Sensor reads that may cost an I2C timeout (A8) never run on a render,
  compositor or real-time tracking thread. A read that exceeds its watchdog (proposed 3 s) marks
  that bus "slow"; it is not read again this boot.
- **H-8 · SyncBoss is opened once, by its owner.** Only `fs-trackd` opens SyncBoss nodes, in a
  worker with a deadline; on failure it reports (D6) and the session continues at a fixed pose.
  Nobody else opens them, and nothing ever writes the SWD firmware-update interface (tracking doc
  §8 item 2).
- **H-9 · The headset is always presented, and degraded at once.** The bridge driver activates the
  HMD whatever the sensors do and never blocks in its initialisation or activation on a sensor.
  With no IMU, or on the **first** implausible IMU sample, it reports a valid fixed pose for the
  rest of the boot; with no proximity it declares no proximity sensor; with no usable IPD it uses
  the manual value. `fs-trackd` likewise drops a camera, or falls back to 3DoF, on the first
  implausible frame set. Confirmation (§5.1) applies only to the notice. [C: exact OpenVR
  properties are confirmed when the driver is written.]
- **H-10 · Safety gates stay narrow.** `fs-thermald`'s required set contains S parts only. Adding an
  F part to it needs this document changed and reviewed.
- **H-11 · `/persist` only through `fs-calread`.** No health check and no other component reads or
  writes `/persist`, `metadata` or any boot-chain partition. The only reader is `fs-calread` (§2.7):
  allowlisted files, read-only, no mount, product only after its Chair review, and not on the PM's
  units while the development no-`/persist` rule stands. Without it, calibration is "unavailable by
  policy".
- **H-12 · Health never blocks safety or the session.** `fs-healthd` starts after the session target
  is reached, nothing depends on it, and its failure is logged and ignored (§6.4).
- **H-13 · Nothing identifying in the journal.** Journal lines are kept across boots (A17), so our
  lines carry a part code, the rule that fired and coarse counts only: **no serial numbers, MAC
  addresses, unique IDs, calibration values or raw sensor values.**
- **H-14 · The kernel never logs calibration values.** Before `fs-calread` supplies proximity
  calibration on any headset:
  1. **Patch every printing site** of A18 in `syncboss_powerstate.c` (`:66`, `:112-116`,
     `:119-121`) so each reports only "ok", "invalid" or "parse error", without values, version or
     file content. The patch also adds a `MODULE_VERSION` string, because
     `CONFIG_MODULE_SRCVERSION_ALL` is not set (stock.config:818) and the module otherwise has no
     `srcversion` attribute [C]. It changes only strings and modinfo, so it is expected to leave
     symbol CRCs unchanged [C; checked by the kgate run]. It ships with the rebuilt module set (K1i
     lineage).
  2. **No dynamic debug for the SyncBoss modules in the product:** no `dyndbg=` or
     `<module>.dyndbg=` on the kernel command line, no `dyndbg` module parameter at load, and no
     write to the debugfs `dynamic_debug/control` (debugfs is not mounted in product images). A
     build lint checks the command line, the loader's parameters and the image for each.
  3. **Concrete gate:** `fs-calread` stages proximity files only if the `syncboss_powerstate.ko`
     the loader will load has the pinned hash of the patched build; after the load, the loader
     checks `/sys/module/syncboss_powerstate/srcversion` (and `version`) against the pinned values
     and, on any mismatch, deletes the staged files before anything opens SyncBoss.
  4. The pstore console and minidump copies of the kernel log (A18) are then clean as well.

  Filtering the lines in journald was considered and rejected: the values would still sit in the
  kernel ring buffer and its copies, and a per-message journald filter is not a supported
  mechanism [C]. H-14 is a Chair item with the `fs-calread` package.

---

## 4. The notice

### 4.1 When it is shown (PM decision H-Q1)

**Once on every boot while the fault persists; FrameShift saves nothing about it.**
- The boot check runs (bounded to 60 s). Faults confirmed by then are batched into **one** toast,
  shown once the overlay consumer is up and the boot splash has ended, after a short settle
  (proposed 10 s), and only if no thermal notice is on screen (P-H8).
- Faults confirmed later in the session (for example by `fs-trackd` once tracking starts) get one
  toast each, at most one a minute, never during a thermal notice.
- The toast auto-dismisses after about 10 s. It is not shown again in that boot for the same part.
- A **Device health** list is available at any time during the session (§4.5), built from runtime
  state only.
- Faults are re-detected on every boot; a part that works again is simply not mentioned.
- The rejected alternative (notify only on a *new* fault) needed a stored record of what had been
  announced; the PM chose not to store anything. The P1 "don't remind me about this part" option
  (H-Q7, off by default) gives quiet to users who want it.

### 4.2 What it says

- Plain words; name the part the way a user knows it; say what still works and what to do.
- No serial numbers, MAC addresses, raw values, driver or chip names, or error codes. The journal
  keeps a non-identifying detail (H-13).
- Start with "FYI:". One sentence about the fault, one about the effect or the action.
- Several faults in one boot → one toast: "FYI: 2 parts aren't working: the IPD sensor and the
  light sensor (no effect on use). See Device health for what this means." Functional faults first,
  information-only faults after (H-Q2).
- The per-part wording is in the §2.3 table. Wording lives in the consumer, keyed by a stable code
  (as for thermal notices, PLAN §2.1 (a)), so it can be improved or translated without changing
  `fs-healthd`.

### 4.3 Severity

`fs-healthd` emits one severity, **`info`**, below the thermal service's `warn` and `shutdown`
(CORE-SPEC §15). It never emits `warn` or `shutdown`: anything that would need those is an S part
(P-H2).

### 4.4 How it is delivered (the thermal notice consumers, reused)

| Consumer (PLAN §2.1) | Thermal notices | Health notices (`info`) |
|---|---|---|
| (a) the notice record and socket | `/run/fs-thermald/state` + socket | **`/run/fs-healthd/state`** + its own socket, same record style (fixed size, sequence number, non-blocking writes, never waits for a reader) |
| (b) SteamVR overlay notification via our bridge | yes | **yes — the main channel.** The same consumer reads both sources; thermal always pre-empts health. [C, carried from PLAN: OpenVR's notification API is a client-side interface, so the toast may be raised by a small companion overlay client rather than inside the driver; decided when the bridge is written] |
| (c) `fs-warnscreen` (no compositor running) | yes | **no.** An information notice is not worth taking over the panels before SteamOS is up |
| (d) LED pattern | yes | **Only for display faults** (rows 7–9), the one case with no screen. **One LED owner:** the LED is written by a single process, the thermal executor's LED consumer (PLAN §1, "device executor"; PID 1 before it starts). `fs-healthd` never writes the LED; it publishes `info:display` in its state record, and the LED owner shows a distinct "display fault" pattern below every thermal and boot-stage pattern in priority |
| (e) next-boot pstore record | yes (T4 latch) | **no.** Health faults are re-detected on the next boot |
| Tone | thermal: if audio is up | only for display faults (rows 7–9), once |
| Journal | yes | **always:** one line per confirmed fault and per clear, with the stable code and rule (H-13) |

Before SteamVR runs (R-1 is headless) the journal and the development console are the only
channels; `fs-healthd` itself starts at V0 (§7).

### 4.5 The Device health list

- Shows each part with a fault confirmed in **this** boot, its effect and the action, in the §2.3
  wording; "All parts working" otherwise. Policy states (P) such as "proximity: not available on
  FrameShift yet" are shown as information, not as faults.
- Built from `/run/fs-healthd/state` (tmpfs), read-only.
- Where it lives: our own SteamVR dashboard overlay (a supported OpenVR extension point, no Valve
  file changed), next to IPD alignment (§2.6) and the idle-blanking timer (§2.5). The full page
  comes at P1; at V0 the toast, the journal and the state file carry the information.

### 4.6 What is stored, and where

- **`fs-healthd` writes no persistent file.** Its state is in `/run/fs-healthd/state` (tmpfs).
- **The journal persists** on Valve's image (A17), so our journal lines survive reboots. They carry
  nothing identifying (H-13). FrameShift does not change journald's storage setting.
- User settings written by our settings overlay (manual IPD, idle timer, and at P1 the opt-in
  "don't remind me") live in FrameShift's own user settings; they are choices the user made, not
  fault records.
- Calibration values read by `fs-calread` exist only in two tmpfs files for that boot (§2.7);
  they are never logged (H-13, H-14) or exported.
- **`fs-healthd` never reads `/persist`**; only `fs-calread` does, read-only (H-11). Never
  `metadata`, never a write to any Meta partition.

---

## 5. False positives and flapping

### 5.1 Degrading versus announcing

- **Degrading is immediate** and belongs to the device owner (H-9): the first implausible sample
  (NaN, out-of-range rates, wrong gravity at rest, a frozen frame set, an AK09973 zero with its
  error line) drops the input for the rest of the boot. Dropping a good input by mistake costs
  little; using a bad one (a wrong pose, a wrong IPD) costs comfort and safety.
- **Announcing needs confirmation**, so the user is not alarmed by a one-off glitch:
  - **Structural boot facts** (D1–D3: unbound, missing node, failed load) are stable within a
    boot; one observation after the probe window counts, but the window is generous: the boot check
    waits up to 60 s for asynchronous probes (Wi-Fi, SyncBoss) before calling anything missing.
  - **Owner reports** (D6): the owner applies its own debounce; `fs-healthd` needs at least 2
    fault reports at least 30 s apart before it confirms. A part the owner dropped on a single bad
    sample that never repeats stays dropped and is listed in Device health as "not used this
    session", without a toast.
  - **Log patterns** (D4): a probe-failure line confirms at once; a runtime error line needs 3
    occurrences at least 30 s apart.
- **Cross-checks beat single readings.** Where two sources see the same quantity (the two IPD
  sensors; later, proximity versus IMU and input activity), a fault is named only when the sources
  disagree and the odd one out is unambiguous; otherwise the notice says "the IPD sensors".

### 5.2 Clearing, and not nagging

- A fault that clears (5 consecutive healthy reports) is **dropped silently**: no "fixed" toast;
  a journal line only. Its degraded mode stays on for the rest of the boot; it is retried on the
  next boot.
- A fault that clears and returns within the same boot is not announced again.
- Rate limit: at most one health toast a minute, and no more than 3 health toasts per boot after the
  first batched one; anything beyond goes to the list only.

### 5.3 Absent by design, unused, unavailable by policy

Never faults:
- **Absent by design:** the model does not have the part, or the kernel does not build its driver
  (Quest 3: headset haptics, row 27; the USB-C audio switch, row 12; eye tracking on anything but
  the Quest Pro).
- **Unused (N):** FrameShift does not use the part yet in this image (cameras before V2, the depth
  projector always, the SyncBoss magnetometer). Not checked, not reported.
- **Unavailable by policy (P):** something the part needs is withheld on purpose or did not pass
  validation (per-unit calibration when `fs-calread` is absent, finds nothing, or rejects it,
  §2.7: proximity and the IPD conversion; modules an image deliberately does not load, such as the
  36 vendor modules stage 3d excludes, J-129). Logged once at boot as policy; shown in Device
  health as information.

These come from **per-model tables** plus a **per-image profile** (which modules and owners the
image has), both built into `fs-healthd` and checked offline (§6.6).

---

## 6. Architecture: `fs-healthd`

### 6.1 Separate service or part of `fs-thermald`?

| | Extend `fs-thermald` | **Separate `fs-healthd` (recommended)** |
|---|---|---|
| Safety | Adds parsing (journal lines, owner messages, many tables) to the safety-critical supervisor: more code on the path that must never stall (ESD §5.1, R27, R49) | `fs-thermald` stays minimal and its reviewed core unchanged |
| Privilege | `fs-thermald` runs with real-time priority and device write access | `fs-healthd` runs unprivileged, idle priority, read-only |
| Failure | A health-check bug could delay a thermal decision | A health-check crash loses only health notices |
| Notice path | one source | two sources, one consumer; the consumer orders them (thermal first) |
| Review cost | re-review of `fs-thermald` | its own, smaller review |

**Decision: a separate service sharing the notice path.** `fs-healthd` only *reads* `fs-thermald`'s
state file, for row 17 and to stay quiet during thermal notices.

### 6.2 Shape

- **Language:** C, statically linked, the same build, harness and fixture tools as `fs-thermald`
  (PLAN §1), with a Python reference of the confirm/clear state machine for differential tests (the
  thermal pattern, R41). Rust was considered (memory safety for the parsers); C wins on one
  toolchain and one review style for our system services. The parsers (journal lines, owner
  messages) are small, fixed-format and fuzzed (§6.6).
- **Licence:** Apache-2.0, our own original code (PROVENANCE-POLICY §6). Device tables hold DT paths,
  compatibles, module names and log patterns from Meta's GPL source, as identifiers with attribution
  (J-123's rule: identifiers and thresholds, never file contents).
- **Process:** one single-threaded process; a poll loop over the journal reader, the report socket
  and a timer. It performs no sensor reads, so no bus watchdog is needed in it (H-7 applies to the
  device owners).
- **Time bounds:** boot check ≤ 60 s from start; each loop iteration bounded; the notice write never
  blocks.

### 6.3 Inputs and outputs

**Inputs (all read-only):**
- `/sys` **structure only** (bound checks, class-node existence), resolved by DT path and
  compatible, never by device number (as `fs-thermald` does, PLAN §1.1). No attribute values.
- The journal, filtered to `_TRANSPORT=kernel` (for D4; `/dev/kmsg` is restricted, A-D4), through
  the `systemd-journal` group.
- `/run/fs-init/modules.log` (the D2 record, new; written by PID 1 before `switch_root`).
- `/run/fs-thermald/state` (row 17 and quiet periods).
- **Owner reports** on `/run/fs-healthd/report.sock` (`SOCK_SEQPACKET`): fixed-size messages
  `{component, status ok|fault|unused, code}`. Each sender is checked by `SO_PEERCRED`; each owner
  may report only its own components (`fs-trackd` → SyncBoss, IMU, radio, cameras, CDSP, and
  proximity once calibration is supplied; `fs-ipd` → IPD; the bridge driver's user → display commits; `fs-inputd` → keys; the
  compositor → GPU and display, if it can be fed through the bridge [C]).

**Outputs:**
- `/run/fs-healthd/state`: one fixed-size record (sequence number, per-component status,
  confirmed-since time, the boot toast's list), written with `pwrite`.
- A non-blocking notice socket for consumers: `info:<code>[,<code>…]` (§4.3).
- Journal lines with stable codes, for example `FSH-IPD-CROSSCHECK`, `FSH-WIFI-UNBOUND` (H-13).

### 6.4 Confinement (systemd unit, sketch)

- `User=fs-health`, `SupplementaryGroups=systemd-journal`, `Nice=19`, `IOSchedulingClass=idle`,
  `CPUQuota=2%`, `MemoryMax=16M`.
- `ProtectSystem=strict`, `ReadWritePaths=/run/fs-healthd`, `InaccessiblePaths=/persist` and the
  block devices, `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`, `ProtectKernelLogs=yes`
  (it reads kernel lines only through the journal), `PrivateNetwork=yes`,
  `RestrictAddressFamilies=AF_UNIX`, `NoNewPrivileges=yes`, `DevicePolicy=closed` with **no**
  `DeviceAllow=`, `CapabilityBoundingSet=` empty, `SystemCallFilter=@system-service` plus its own
  seccomp filter after start-up (the `fs-metacfg` pattern, PLAN R35).
- `Type=notify`, `TimeoutStartSec=10`, `Restart=on-failure` with a start limit; `WantedBy=` the
  session target; **nothing `Requires=` it, it `Requires=` nothing**, and it is ordered after the
  session target so it cannot delay it (H-12).

### 6.5 Device tables

Per model (`eureka`, `panther`, `hollywood`, `seacliff`, later Quest 1) and per image profile. One
row per component:
`id · class (S/F/E/I/N/P) · device owner · DT path and compatible · module(s) and load phase (S/E/F)
· expected class node · log patterns · owner report codes · cross-check partner · notice code ·
absent-by-design / unused / policy flags`.
S rows exist only to name the owner and the load phase; a test asserts that no S row is ever checked
or notified by `fs-healthd` (§6.6). The load-phase column feeds H-1's loader list.

### 6.6 Test plan

**Offline (before any device):**
1. **Scenario suite on fake sysfs trees, journal streams and owner reports** (the `fs-thermald` SC
   pattern): each row of §2.3 with a healthy case, each fault mode, and a negative control (a glitch
   reported once must not toast). C and the Python reference must agree step by step.
2. **Unit 1 and Unit 2 fixtures:** Unit 2 — AS5510 empty reads and `-EAGAIN`, AK09973 zeros with the
   `[AK09973] I2C Read Error` line, an AK09973 that fails to probe; expected: the bridge degrades on
   the first bad sample, one IPD toast after confirmation. **Unit 1's IPD is the negative control**
   (must stay healthy). Proximity: both units produce **no** proximity notice (P), with the
   calibration log line present.
3. **`fs-ipd` H-6 tests:** `fs-ipd`'s sensor reader against the same fixtures, including a FIFO
   standing in for a hung I2C read: the read is off the render thread, the bus is marked slow, the
   fixed or manual value is used, and nothing blocks.
4. **Loader tests for H-1 and H-2 (QEMU kernel with test modules):** (a) a driver that prefers
   asynchronous probing with a hung probe, loaded before an S-class test module: the old loader
   stalls the S module (negative control); H-1 loads the S module first and reaches the target
   within budget, recording `MODULE_TIMEOUT … initstate=` for the hung one; (b) a module that
   fails; (c) a module that requests a missing firmware file: no stall with H-2's settings, a 60 s
   stall without them (negative control); (d) budget exhaustion in phase F never touches phase S.
5. **Unit and udev lint** over our layer and Valve's 0.4.5 units and rules: no `Requires=` /
   `BindsTo=` / `Requisite=` on `.device` units or sensor services; timeouts present;
   `network-online.target` and `udev-settle` not pulled; every `SYSTEMD_WANTS` in a udev rule
   resolves to an allowed or masked unit; A11–A13 rechecked.
6. **QEMU boot** (the existing Valve-userspace QEMU suite): Valve's rootfs plus our layer with
   missing Wi-Fi, missing audio and failing sensor modules: the session target is reached within
   budget; `fs-healthd` reports the faults; nothing waits.
7. **Notice consumer test:** a replay of health and thermal notices into the overlay consumer under a
   desktop SteamVR null-HMD run (the PLAN R45 harness): thermal pre-empts health; health is rate
   limited; a stalled consumer never blocks `fs-healthd`; the LED owner shows the display-fault
   pattern only below thermal patterns.
8. **Idle blanking (§2.5)** in the same harness: still + no input for T → blank; motion or input →
   wake; never blank while moving; fan demand unchanged while blanked.
9. **Fuzzing** of the journal-line matcher and the report-socket parser.
10. **Ownership test:** no S component is ever checked or notified by `fs-healthd`; no component is
    notified by two services; `fs-healthd` opens no device node (checked by its seccomp profile and
    an `strace` run in QEMU).
11. **Journal content test:** no line from `fs-healthd` matches serial, MAC or unique-ID patterns
    (H-13).

**On device (read-only observation first; each step under the PM's sign-off, one command at a
time):**
- **Ground truth under stock Horizon** (proposed; read-only; needs the PM's approval per command):
  `adb shell ls /sys/bus/i2c/drivers/as5510/ /sys/bus/i2c/drivers/ak09973/` ·
  `adb shell cat /sys/bus/i2c/drivers/as5510/0-0056/adc_raw_value` (three times, a few seconds
  apart, the wheel untouched; then once after the PM turns the lens wheel); the related kernel messages are read only if the PM approves a method.
  The AS5510 read only reads registers (`as5510.c:105-137`) [D]. **The AK09973 raw value is not
  read**, because its read writes a measurement command (A7). On Unit 2 this shows what the IPD
  fault looks like; on Unit 1 it gives the healthy reference.
- **Under our image at V0:** the same structure checks and the bridge's own reads, with
  `fs-healthd`'s verdict compared with the PM's known faults. Acceptance: Unit 2 → IPD fault
  confirmed, the session unaffected, IPD alignment usable; Unit 1 → no IPD notice.
- **Proximity:** at V1, with SyncBoss opened by `fs-trackd` under its own trial sign-off (tracking
  D-T7). Without calibration (the state of the PM's units while the development no-`/persist` rule
  stands): proximity off, no proximity notice, idle blanking works. With calibration, only if the
  PM lifts that rule for the `fs-calread` trial and the Chair has reviewed its package: Unit 1's and
  Unit 2's faulty sensors must be detected and neither unit may sleep while worn and moving [O: how
  Units 1 and 2 misbehave].
- **`fs-calread`:** offline fixtures first (§2.7); on a headset only after its Chair review and the
  PM's decision on the development rule; Unit 2's IPD calibration must be refused.

---

## 7. Milestone placement

| Milestone | What this design adds | Pass condition (observable) |
|---|---|---|
| **R-1** (SteamOS boots, headless) | H-1 ordered, bounded loader with the D2 record (**Chair item**); H-2 firmware settings; H-4 unit and udev lint and the 0.4.5 recheck; H-5, H-10, H-13. **No `fs-healthd` yet:** R-1 loads none of the faulty parts, so it could test nothing | QEMU loader and boot tests (§6.6 items 4–6) pass; R-1 reaches `fs-console.target` on both units; `/run/fs-init/modules.log` shows every module's outcome |
| **V0** (desktop in headset) | `fs-healthd` v1 (boot check, owner reports, toast via consumer (b), Device health in the journal and state file); IPD modules loaded (H-Q5) with `fs-ipd` as IPD owner (millimetres only to the bridge) and the **alignment procedure** (§2.6); **`fs-calread`** (§2.7) and the kernel log patch H-14, behind their own Chair-reviewed package (until then, the fallbacks); **idle blanking** (§2.5); display, audio, Wi-Fi, BT, buttons (`fs-inputd`) and charging rows; the LED display-fault pattern through the LED owner | On Unit 2 the toast names the IPD sensor once per boot and the desktop renders with the aligned IPD; on Unit 1 no IPD notice; with no input for T and no idle inhibitor the display blanks and rendering stops or throttles, it wakes on input or the power button, and it stays on during video (§2.5); a thermal notice pre-empts a health toast in the replay test |
| **V1** (3DoF) | SyncBoss and IMU rows via `fs-trackd` (H-8, H-9); idle blanking gains the stillness condition (never blank while worn and moving); **proximity** (first used when SyncBoss is opened) with the H-Q3 rule and its fault detection, when calibration is supplied | An injected implausible IMU sample switches to fixed pose at once; the notice follows confirmation; without calibration, proximity stays off with no notice; with calibration, neither unit sleeps while worn and moving, and a faulty proximity sensor is named where the cross-check confirms it |
| **V2–V4** | Camera, controller-radio and CDSP rows as each is first used; the emitter backstop test (§2.1) | Each row's fault injection degrades as specified; emitters are off within the bound after `fs-trackd` is killed |
| **P1** (product) | Tables for Quest 2, Quest Pro, Quest 3S (and Quest 1 later); the Device health page; H-Q7 "don't remind me" (off by default); wording review and translations | Each device's table passes its fixtures; the page lists exactly the confirmed faults |

---

## 8. Open items

**No PM decision is open in this design** (H-Q1–H-Q7 and D-T3 are recorded at the top). One PM
choice comes later: whether to lift the development no-`/persist` rule for an `fs-calread` trial on
Units 1 and 2 (§6.6); the recommendation is to decide it when the package is ready.

**For the Chair (with the R-1 composition):**
- H-1, the change to the reviewed PID 1 loader (phases, `async_probe`, deadlines, the D2 record).
- H-2's two added volatile writes (`ignore_sysfs_fallback`, `force_sysfs_fallback`), next to the
  existing timeout write.

**For the Chair (with V0, as one package):**
- `fs-calread` (§2.7): the runtime read of the unit's own allowlisted calibration files from
  `persist` under FS-R-012 §8's conditions, its fallback, and its hand-off files.
- H-14: the kernel patch removing calibration values from every SyncBoss powerstate message, the
  no-dynamic-debug rule and its lint, and the pinned-module gate.

**For FS-A-013 (Valve-writer and activation review):**
- Mask Valve's crash hook (`60-crash-hook.conf`'s `core_pattern` pipe) and `steamos-log-submitter`
  (A19): **PM decision, off by default**. Crash data stays on the headset or in our own local log
  with no identifiers; any opt-in waits for Valve's view (Valve-letter item).

**Open [O] (research):**
- O-H1: how Units 1 and 2's proximity faults actually behave; only visible with calibration
  supplied.
- O-H13: the feature set of the units' `persist` ext4 (journal, orphan handling), from fixtures
  and documentation only while the development rule stands.
- O-H14: proximity plausibility bounds (no known-good unit available).
- O-H12: which `persist` file and field holds each proximity value, and the semantics of the IPD
  two-point conversion; neither is applied until established (§2.7).
- O-H2: what Unit 2's IPD fault looks like at the sysfs level (the proposed read-only Horizon reads,
  §6.6).
- O-H3: whether any built-in driver requests firmware before our PID 1 (A5).
- O-H4: A11–A13 and A17 on Valve 0.4.5.
- O-H5: the display-standby interface for idle blanking, and how SteamVR treats an HMD with no
  proximity sensor and a fixed pose.
- O-H6: Quest 3S lens-position sensing (populated sensors and plausible ranges).
- O-H7: whether the toast is raised inside the bridge driver or by a companion overlay client
  (carried from PLAN R45).
- O-H8: the design of `fs-inputd` (stuck-key filter).
- O-H9: whether every module in phase F tolerates asynchronous probing (QEMU first, then the V0
  image); a module that does not is moved to phase E with its own deadline.
- O-H10: the emitter backstop on `fs-trackd`'s death (§2.1), measured at V2.
- O-H11: the Quest 3 lens range used to clamp IPD alignment, from Meta's published values.

---

## Change log

- **Rev 0** (2026-10-15, `46d027b`): first version.
- **Rev 1** (2026-10-15): the adversarial review of rev 0 (NO-GO) applied in full, and the PM's and
  Arbiter's decisions recorded:

| Finding | Change | Sections |
|---|---|---|
| **BLOCKER** `async_synchronize_full()` in `do_init_module()` lets one hung asynchronous probe stall every later plain `insmod`, possibly skipping S modules | Verified (`kernel/module.c:3799-3800`, `dd.c:1112-1121`, `:778-796`). H-1 rewritten: S modules and their closure first, then E, then every other module with `async_probe`; no plain `insmod` after phase F starts; `initstate` classification; budgets never skip S; a QEMU test with a hung asynchronous probe before an S module; H-1 listed as a Chair item. A1 and A9 rewritten | §0, A1, A9, A15, H-1, §6.6 item 4, §7, §8 |
| **MAJOR** proximity is never enabled without calibration on any unit | Verified (`syncboss_powerstate.c:136-140, 178-183, 501`; v27.dts:25751-25754). Row 1 and the note corrected; the calibration line is policy; class P without calibration; proximity notice only once calibration is supplied (PM decision D-T3/H-Q4) | §0, §2.2 row 1, §2.3, §7, §8 |
| **MAJOR** with proximity off and no suspend, the display never sleeps | Idle blanking added as a V0 requirement with the PM's rule | §2.5, §6.6 item 8, §7 |
| **MAJOR** AK09973 reads write a measurement command; I2C errors read as 0 with success | Verified (`ak09973.c:311-315, 618-628, 666-668, 962`). `fs-healthd` reads no sensor values; the bridge reads and reports (D6); detection by stuck-at-0 plus the log line; read-write attributes never touched; the Horizon ground-truth reads drop the AK09973 value | P-H4, §2.3, A6, A7, H-6, §6.3, §6.6 |
| **MAJOR** confirmation delayed degradation; IR emitter ownership contradiction; no backstop named; prox IR LED missing | Degrade on the first implausible sample, notice after confirmation; IR emitters owned by `fs-trackd` in P-H2/P-H3; kernel close path named as backstop (test at V2); prox IR LED added | P-H2, P-H3, §2.1, §2.3, H-9, §5.1 |
| **MAJOR** uncalibrated IPD is normal and the wheel position is unreadable | In-headset IPD alignment procedure, clamped to the lens range, as a V0 feature | §2.6, §7 |
| MINOR `set-bluetooth-mac-address` is started by udev | Corrected (`90-mac-addresses.rules`); the lint scans `SYSTEMD_WANTS`; `deckard-audio-setup.service` added | A11, A13, H-4, §6.6 item 5 |
| MINOR journald is persistent | Corrected; H-13 forbids identifying data in journal lines | A17, H-13, §4.6 |
| MINOR `DMESG_RESTRICT=y` | Kernel lines read from the journal; `ProtectKernelTunables=yes` and related; no `CAP_SYSLOG`, no device access | D4, §6.3, §6.4 |
| MINOR `ignore_sysfs_fallback` | Added to H-2 | A2, H-2 |
| MINOR fsa4480 not built | Row 12 absent by design | §2.2, §5.3 |
| MINOR RTC | Row 26 log only; the kernel sets time when `rtc0` registers; we never set the clock | §2.2, §2.3 |
| MINOR stuck keys | Known limitation before our code; `fs-inputd` named as the filter | §2.2 note, §2.3, O-H8 |
| MINOR R-1 tests none of the faulty parts | `fs-healthd` moves to V0; R-1 keeps the loader, firmware and lint rules | §0, §7 |
| MINOR one LED owner | The thermal executor's LED consumer is the only writer | §4.4 |
| MINOR citations | `k1a/init.sh` marked as on `feat/k1a-kernel`; PLAN and CORE-SPEC cited on master | Sources, A1 |
| **PM decision D-T3/H-Q4** (product calibration read approved in principle) | `fs-calread` sketched (owner, allowlist, validation, fallback, hand-off without logging) and placed at V0 behind its own Chair package; proximity works and is detectable once calibration is supplied, otherwise off with idle blanking; IPD falls back to the alignment, which also stays as an override; new finding A18 (the kernel prints proximity calibration values; the journal is persistent) with rule H-14; H-11 reworded; the development no-`/persist` rule kept | §0, §2.2, §2.3, §2.5–§2.7, A18, H-11, H-14, §4.6, §6.6, §7, §8 |
- **Rev 2** (2026-10-15): the delta review of rev 1 (GO-with-fixes) applied:

| Finding | Change | Sections |
|---|---|---|
| **MAJOR** crash uploads | Verified (`60-crash-hook.conf`, the submitter's helpers and hooks). `fs-calread` and `fs-ipd` disable core dumps; a separate `fs-ipd` keeps the conversion out of `vrserver` and hands millimetres only; A19 added and listed as an FS-A-013 item (masked by default recommended) | §2.2 row 2, §2.3, §2.6, §2.7, A19, §6.3, §8 |
| **MAJOR** H-14 coverage | Verified (`syncboss_powerstate.c:66, 112-121`; `syncboss_spi_core.c:716, 1117`; dynamic debug, pstore console and minidump in stock.config). Every site patched; no dynamic debug for SyncBoss, with a lint; pstore and minidump noted | A18, H-14, §2.7 |
| **MAJOR** `persist` is a journalled read-write ext4 | Reader variant accepts `has_journal`, refuses `needs_recovery`, orphan state and unknown features; feature set [O]; `fs-blkguard` named as the write barrier, armed first | §2.7, O-H13 |
| **MAJOR** idle blanking at V0 | No IMU at V0: no input for T; idle inhibit honoured; rendering stops or throttles while blanked; V0 and V1 pass conditions fixed | §2.5, §7 |
| MINOR proximity bounds | [O]: no known-good unit | §2.7, O-H14 |
| MINOR refusal by unit identity | Dropped | §2.7 |
| MINOR "H-14 in the running kernel" | Pinned module hash before staging; `srcversion`/`version` check after load (with the added `MODULE_VERSION`) | H-14 |
| MINOR staged files linger | Deleted after the first powerstate open or after 10 minutes | §2.7 |
| MINOR `fs-calread` deadline | `ufs_qcom` in phase S when `super` or `persist` is read; bounded wait for the `persist` node | §2.7 |
| MINOR phase E budget; asynchronous S drivers | Phase E total budget; `spmi-pmic-arb` noted as correctly plain in phase S | H-1 |
- **Rev 2.1** (2026-10-15): PM decision recorded: Valve's crash reporting is off by default (crash
  hook and `steamos-log-submitter` masked; crash data local, no identifiers; opt-in only if Valve
  welcomes reports). Decision list, A19 and §8 updated.
