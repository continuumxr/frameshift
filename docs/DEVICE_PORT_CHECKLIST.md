# Device port checklist — differentials that MUST be checked

*Edited for publication: names and links removed or paraphrased.*

**Status:** binding (PM, 2026-10-08). Every new device port, and every new
firmware baseline of an existing device, must complete this checklist
**before** any image of ours runs on it beyond a short, bounded hold.

**Why:** on these headsets, much of the protection that keeps the hardware
safe lives in the vendor's userspace (Android services, closed daemons),
which our images replace. Two devices with the same SoC can differ
completely in cooling, fan control, battery path and limits; the XR Elite
and Quest 2 share CPU/GPU tables but nothing else (`docs/research/perf-envelope-xr-elite.md`).

**Principle — copy the device's own controls.**
- Extract the original device's control parameters from its stock
  firmware: device tree, vendor configs, logged values, and closed-binary
  strings.
- Reproduce them in our stack so the hardware operates nominally.
- Never invent a curve or limit when the vendor's is recoverable.
- Where it is not recoverable, use the most conservative documented
  value, and mark it [O] until verified.

**Where findings go:**
- each device's answers: `docs/research/<device>-*.md`;
- the summary: the status matrix at the end of this file;
- decisions: `docs/JOURNAL.md`;
- the binding requirements: `docs/PROJECT_SETUP.md` §6A.

---

## A. Thermal

| # | check | what to extract / copy | why |
|---|---|---|---|
| A1 | Thermal zones and sensors (SoC tsens, PMIC, ADC thermistors, virtual sensors) | DT `thermal-zones`: every sensor, trip, governor (`step_wise` vs `user_space`), cooling map | Zones on the `user_space` governor do **nothing** without the vendor daemon |
| A2 | Kernel-enforced vs userspace-enforced limits | Which trips act in the kernel, and which only through a daemon (Meta `perf_service`, HTC `thermal-engine`, thermal HAL) | Everything userspace-only must be reimplemented by us |
| A3 | Vendor thermal policy | `thermal_info_config.json`, `thermal-engine.conf`, `powerhint*`, `pnp.xml`, compiled-in thresholds (binary strings, logs) | The source values for our watchdog |
| A4 | Skin and surface limits | Skin and front-panel virtual sensors and their LIGHT/SEVERE/SHUTDOWN thresholds | Users wear these on their faces |
| A5 | SoC emergency and reset trips | Per-core isolation, reset-mon, LMh/DCVS hardware limits, GPU current limiter, **PMIC stage-2 hardware over-temperature shutdown** | The last line of defence; know exactly what remains. **Loading `qcom-spmi-temp-alarm` can disable PMIC stage-2 shutdown (`SHUTDOWN_CTRL1_OVERRIDE_S2`)**, so keep it enabled or replace it explicitly (J-34) |
| A6 | GPU thermal coverage | Whether any kernel cooling map or devfreq cooling path targets the GPU, and whether a zone drives it | Quest 3: a devfreq cooling device and thermal max-frequency path exist (`kgsl_pwrscale.c`); autonomous use [O] (FS-R-006 §4). Our stack must provide and verify GPU limits |
| A7 | Thermal stack modules | Which driver modules (`tsens`, `adc5`, `temp-alarm`, `bcl`, `virtual_sensor`) must load for zones to exist | Stage 1 on the Quest 3 loaded none, so no zone existed |

## B. Fan and cooling

| # | check | what to extract / copy | why |
|---|---|---|---|
| B1 | Fan hardware and driver | Controller (PWM/LPG, MAX31760, …), tach, regulator, enable GPIOs | The driver must load and the supply must be on |
| B2 | Who drives the fan | A kernel curve (DT cooling levels) or a vendor daemon (sysfs `pwm_control`) | XR Elite: userspace only. Quest 2/3: kernel curve, but only if the zones exist |
| B3 | Fan curve and limits | rpm/duty steps, trip temperatures, min and max duty, silent rpm, ramp rate | Copy it exactly; otherwise use the interim rule (≥ 20% duty, 100% at ≥ 50 °C) |
| B4 | Fan behaviour on blank, suspend, accessory modes | Blank or panel-off behaviour (Quest 3 v2.7: capped at `silent_rpm` 4000; Quest 3 v66, Quest 2, Quest Pro: stops on blank; Quest 3S: `silent_rpm` 5000; Quest 1 fork: stops on POWERDOWN [C]) | Display state is not a cooling control: an explicit fan policy with tach/failure handling (FS-R-006 §4) |
| B7 | **This device's own fan policy** (PROJECT_SETUP §6A.3, PM 2026-10-09) | Extract from **this device's** firmware and DT: fan hardware, zones, trips, levels, quiet speed, blank and suspend behaviour. Never copy from a sibling (3S ≠ 3, Pro ≠ 2) | Implement: temperature-driven; screen-off quiet cap that yields to temperature; fan off only in suspend, no suspend while hot; tach-failure → throttle → shutdown |
| B5 | Fan power-on default | Duty at power-on, before any driver or daemon acts | Decides how safe an early boot is |
| B6 | Passive cooling path | Heat path, battery placement relative to the SoC (teardowns) | Decides which zone is the binding limit |

## C. Battery, charging and power

| # | check | what to extract / copy | why |
|---|---|---|---|
| C1 | Battery path | PMIC fuel gauge, external gauge (bq27…), ADSP battery manager (pmic_glink), external pack over UART (XR Elite cradle) | Decides whether the kernel can see battery state at all |
| C2 | Charger control | In-kernel charger (SMB5) or remote-processor firmware (ADSP battmgr); what must start for it | Charging protection may need a co-processor |
| C3 | JEITA and charge-temperature limits | Current/voltage per temperature band; hardware and software JEITA | Copy it; never charge outside the bands |
| C4 | Battery temperature limits | Fan, throttle and shutdown thresholds from DT and vendor configs | Battery temperature is usually the binding limit |
| C5 | Brown-out and low-voltage (BCL) | VPH/VBAT levels and their responses | Matters on external power banks |
| C6 | USB connector protection | Connector thermal trips and charge-current reduction | Fires start at connectors |
| C7 | Battery age and health | Cell age, cycle count, swelling inspection | Quest 1/2 cells are 5–7 years old |
| C8 | Battery profile | Model, capacity, the vendor's battery profile writes (e.g. `batt_profile`) | Gauge accuracy and charge termination |

## D. CPU and GPU performance

| # | check | what to extract / copy | why |
|---|---|---|---|
| D1 | CPU frequency tables (firmware LUT) | `scaling_available_frequencies` per policy (read-only probe), or logged LUT | The hardware ceiling. Never exceed it: community reports say forcing past it **permanently damaged a headset** (JOURNAL J-30) |
| D2 | GPU levels and speed bin | DT pwrlevels per bin; the unit's actual bin (`gpu_available_frequencies`) | Same SoC, different bins. Never force another bin. GPU levels are kernel-defined, so a module *can* overclock; that is beyond-spec and needs a separate decision (J-30) |
| D3 | Vendor performance levels and caps | Meta CPU/GPU levels, HTC pnp levels, boost rules | Basis for our sustained targets |
| D4 | Default governor | The kernel default (Quest 1/2: `performance`!), the vendor's governor (walt, msm-adreno-tz) | The `performance` default pins all clusters at max |
| D5 | Core-control and hotplug policies | Isolation, prime-core pinning, cpusets | Vendor workload placement |

## E. Display and panels

| # | check | what to extract / copy | why |
|---|---|---|---|
| E1 | Panel power sequencing and regulators | DT panel nodes, regulators, reset GPIOs, timings | Wrong sequencing can damage panels |
| E2 | Backlight limits and temperature compensation | Max brightness, thermal dimming (XR Elite: 41–47 °C compensation) | Panel and skin heat |
| E3 | Blank modes and side effects | What blanking turns off (the fan!) | See B4 |
| E6 | Display pipeline throughput (per-pipe width) | From this device's DT and mode: MDP max clock, mode line time (htotal/vtotal/fps), layer-mixer count and split; the widest plane one pipe can feed per line; the stock compositor's plane layout (planes per mixer, DMA vs VIG, format/modifier) | Meta's SDE driver accepts an over-wide plane without checking throughput; on the Quest 3 a 2064-px plane needs ~1.0 GHz vs the 550 MHz max, so trial (iii-b) run 2 lit garbled (J-108, J-109). Use one plane per mixer, ≤ the computed width, explicit zpos |
| E7 | Panel geometry and calibration | Panel mounting (rotation/roll/cant per eye; Quest 3: 180° + ~21° roll), scan-out orientation, per-eye resolution, lens-axis offsets; where per-unit display/lens calibration lives (names only) | Needed by the rendering stage (eye-to-head transforms, projection, distortion), not by pattern tests (J-109) |
| E5 | Per-unit hardware faults | Record known faults per unit and what they affect. **Quest 3 Unit 2 (`QUEST3UNIT2`): faulty IPD slider** (PM report, J-69); it has caused issues on newer firmware and may affect lens-distance/IPD handling in SteamOS | Wrong IPD input, misleading results on that unit |
| E8 | DRM enumeration on THIS firmware | Per firmware version: connector mode counts (DT refresh range and step sizes), CRTC/plane/encoder counts, properties per object, blob sizes; compare with every fixed limit in our display tools before a run | Quest 3: v66 lists 24 modes, v2.7 lists **305** (max refresh 120 → 240, no steps), so fs-pattern v0.7's 128-mode cap refused the J-141 run safely; fixed in v0.7.1 (J-142). Firmware updates change these counts |
| E9 | Splash handoff and the first lit frame | How the bootloader leaves the panel (lit splash vs off) on a `fastboot boot` and on an installed boot; whether the kernel skips panel-on while the splash flag is set; the reset needed before the first frame | Quest 3: under `fastboot boot` the first enable stays dark (TE 0) until a disable → dark re-enable → close cycle (J-126, J-130); installed boots keep the splash lit |
| E4 | Refresh rates | Supported panel modes per DT (72/90/120 Hz…), and modes the panel supports beyond what the vendor exposed | PM requirement: **90 Hz default, 120 Hz option where supported**. Quest 1: shipped 72 Hz, panel reported 90 Hz-capable (Carmack, OC6) [C] |

## F. Platform, boot and recovery

| # | check | what to extract / copy | why |
|---|---|---|---|
| F1 | Watchdogs | Hardware watchdog modules (`qcom_soc_wdt`, `qcom_wdt_core`), softdog, who pets them | Unpetted watchdog → reboot. No watchdog → a hang needs a human |
| F2 | Crash-dump and download mode | `download_mode` cmdline, PANIC_ON_OOPS, crash-dump USB mode, minidump writes | Persistent effects and recovery path |
| F3 | Boot chain and slots | A/B layout, the `super` space limits for both slots | Flashing can be one-way (Quest 3 `super` cannot hold both slots) |
| F4 | Kernel module ABI | vermagic, MODVERSIONS, `module_layout`, CRCs; the vendor module set | A rebuilt kernel must match, or the modules need rebuilding |
| F5 | Kernel features for our userspace | DEVTMPFS, FHANDLE, namespaces, SYSVIPC, BTRFS, USB gadgets (ACM/NCM) | The Quest 2 has no ACM gadget |
| F6 | Recovery route | Button combinations, fastboot, sideload, rescue images | Before any device action |
| F7 | **Per-unit baseline after any firmware change** | Fingerprint, active slot, kernel and the effective firmware inputs, captured on that unit after the change; capture the changed inputs. **Quest 3 Unit 2 (`QUEST3UNIT2`)**: re-baseline before **any** FrameShift action, and never reuse its v71 identities as v2.7 identities (FS-R-011 §8, J-104) | A concurrence is bound to the exact unit and firmware it reviewed (Unit 1's v66 trial does not migrate) |

## G. Remote processors and firmware

| # | check | what to extract / copy | why |
|---|---|---|---|
| G1 | Which remoteprocs exist and what depends on them | ADSP/CDSP/SLPI/modem/SPSS; battery, audio and sensors behind them | The Quest 3 battery data needs the ADSP |
| G2 | Firmware locations and start triggers | `/vendor/firmware`, firmware partitions, the `boot_adsp` sysfs, pd-mapper | Must be reproducible without Android |
| G3 | Never-stop rules | Subsystems that must not be stopped or restarted once started | Quest 1: a modem reload hangs the SoC |

## H. Other hazards

| # | check | why |
|---|---|---|
| H1 | Laser/IR emitters, tracking cameras, eye-tracking illuminators | Eye safety: power limits and duty cycles must stay vendor-controlled |
| H2 | Audio amplifier protection (speaker temperature and excursion models) | Speaker damage without the vendor DSP |
| H3 | Haptics and motors | Overdrive |
| H4 | Accessory modes (cradles, docks, glasses mode on external power) | Power and thermal behaviour changes |
| H5 | Controllers and input devices | Which controllers the stack pairs (radio, firmware, pairing protocol), and haptics limits. PM requirement: Oculus Touch, Meta Touch, Touch Plus and MX Ink on every Quest; Touch Pro on Quest 3/Pro only (later stage). **PM requirement (2026-10-10, J-86/J-87): support BLE-connected VR controllers tracked inside-out by the headset cameras (constellation/SLAM-style)** from multiple vendors, via a future catalogue of pairing and tracking models. **Minimum: the Meta Touch series.** |
| H7 | Protected partitions and MCUs | Never mount persist/private/metadata read-write or write `/metadata`; never send unknown SyncBoss commands (90/203/204 reportedly crash the MCU); never run Meta MCU or controller firmware updaters (PROJECT_SETUP §6A item 8b). *FS-R-011 §7 D4/D5 (J-104): never hand a whole Valve recovery image, its GPT or Valve's flashing machinery to a Quest; the proposed storage route for unflashed units is not concurred, and a temporary boot that writes userdata does not guarantee recovery to Horizon* |
| H6 | Hand tracking | Tracking cameras, IR illuminators (see H1), the vendor model/runtime and its DSP/NPU use. PM requirement: keep the Quest hand-tracking models if possible (later stage; licensing [O]) |
| H8 | **Writers in the userspace we run** (writer inventory): every executable, unit, socket, timer, generator or helper that can write a partition, `/persist`, an MCU, GPIO/I2C devices or battery NVM. Valve image (FS-R-011 §7 D3, J-104): `steamvr-program-ble` (openocd nRF52 mass erase), `deckard-charger` (battery-pack NVM), `systemd-repart` (partition add), `vrconfig_write` (`/persist`), plus the updaters (RAUC, atomupd, `steamos-boot`/`splctl`, `setubootenv`) | Review activation through dependencies, sockets, timers, generators and direct helper calls, not only enabled units; a unit mask does not stop a direct invocation, so each writer needs an effective technical prevention path. A package diff is an alarm, not proof that no writer exists. Before broad stock-service activation or any automatic update/installer, demonstrate an effective write boundary (FS-R-011 §7 D2; SG_IO/UFS BSG pass-through, dm reconfiguration, open descriptors, GPIO/I2C/NVM, module/kexec bypass are open) |
| H9 | **Licence obligations of every binary we ship:** per-file/package licence (not authorship or a metadata label) for every binary in an image or installer, including BusyBox, the kernel and statically linked glibc; the matching source, notices and linking obligations. "Our own code only" is inaccurate for any image with those binaries (FS-R-011 §7 D3/D6, J-104). Proprietary components: no redistribution without a grant (public package hosting is not one) | Images go to testers and, later, the public; Valve proprietary payloads are never shipped (PROJECT_SETUP §0.0, §6A item 9) |

---

## Status matrix

✅ = extracted/known · ⚠️ = partial or userspace-only, needs our reimplementation · ❌ = not yet checked · — = not applicable

Quest Pro and Quest 3S (offline scoping, no PM unit; v2.7 OTAs held): all
areas ❌ except F (✅ v2.7 kernel gates passed, incl. ACM on the Pro; J-36). **H1 (eye- and face-tracking IR
illuminators) is a priority for the Quest Pro.**

*Status note (2026-10-10): the Quest 2 unit is now on v2.7 (J-75). The Quest 2
cells below that mention the unit (for example F, "slot b never marked
successful") describe the v59 baseline and still need to be re-read for v2.7.
Quest 3 Unit 2's faulty IPD slider (J-69) is now row E5.*

*Status note (2026-10-11, J-104): rows H6, H7 and this matrix were dropped by
accident in the J-86 edit and are restored here; H8, H9 and F7 are new. Quest 3
Unit 1 trial (iii-b) (stage 3b display, v66) is **concurred to execute** by
FS-R-011 §1 (attended, one attempt) and not yet run, so the Quest 3 E cell
still shows no admitted display result. The Quest 3 v2.7 / Unit 2 cells need
Unit 2's new baseline (F7) before any use.*

| area | Quest 3 (v2.7 target; Unit 1 v66) | Quest 2 (v2.7 target; unit on v2.7 since 2026-10-10, J-75; cells from the v59 baseline unless noted) | Quest 1 | XR Elite (shelved) |
|---|---|---|---|---|
| A thermal zones / policy | ✅ DT (incl. `batt-virt-limit` 45/58 °C, `surf-virt-limit` 48 °C CPU maps); ⚠️ shutdown thresholds userspace (`perf_service`); GPU devfreq cooling exists, autonomous policy [O] | ✅ DT + `thermal_info_config.json`; ⚠️ skin and battery userspace-only | ✅ DT + HAL JSON; ⚠️ userspace limits | ✅ DT; ⚠️ all board sensors `user_space`; HTC thresholds compiled in [O] |
| B fan | ✅ kernel curve (needs zones); ⚠️ capped at `silent_rpm` on blank | ✅ kernel curve | ✅ kernel; ⚠️ stops on POWERDOWN | ⚠️ **userspace only** (MAX31760, closed daemon) |
| C battery / charging | ⚠️ via ADSP + pmic_glink; bq27 node absent on stock; JEITA in ADSP | ✅ PMIC + DT trips; ❌ JEITA detail | ❌ | ⚠️ main pack over **cradle UART**; ✅ 390 mAh cell JEITA |
| D CPU/GPU | ✅ measured (2.05/2.36 GHz, 690 MHz) | ✅ firmware (1.80/2.42/2.84, 587 MHz); ❌ unit probe | ✅ firmware (1.90/2.30, 710 MHz); ❌ unit probe | ✅ firmware + bugreport |
| D4 default governor | config default schedutil, but the bootloader cmdline sets `cpufreq.default_governor=performance` (effective in our boots); Android uses walt | ⚠️ `performance` default | ⚠️ `performance` default | ❌ |
| E display | ⚠️ `msm_drm` probes; trial (iii) INCONCLUSIVE, no light seen (FS-R-010); trial (iii-b) concurred to execute, not yet run (FS-R-011 §1); ❌ sequencing review | ❌ | ⚠️ fork uses fbdev | ✅ backlight compensation; ❌ rest |
| F boot / recovery | ✅ stage 1; ✅ `super` constraint; ⚠️ no SoC watchdog module in stage 1; ✅ v2.7 kernel gate | ✅ v2.7 kernel gate incl. ACM (J-32); ✅ unit baseline: adb + `getvar` (J-36); ⚠️ slot b never marked successful | ❌ | shelved |
| G remoteprocs | ✅ map (ADSP/CDSP/SPSS) | ❌ | ⚠️ fork: modem never-stop | ❌ |
| H other hazards | ❌; ⚠️ H8 Valve-image writer inventory started (applies to every Quest, FS-R-011 §7 D3) | ❌ | ❌ | ❌ |

**Next for the matrix:**
- Quest 3 H-items (tracking IR/illuminators, speaker protection);
- Quest 1 battery path;
- Quest 3 Unit 2 re-baseline (F7) before any FrameShift action;
- H9 licence/source/notice record for the stage images already built
  (BusyBox, kernel, static glibc).
