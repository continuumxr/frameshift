# Quest 1 and Quest 2 — safe CPU/GPU operating range (research, 2026-10-08)

*Edited for publication: names and links removed or paraphrased.*

Agent report. Offline: firmware already on disk, plus web sources; no device
action. Meta's public level table
(https://developers.meta.com/horizon/documentation/native/android/os-cpu-gpu-levels/)
matches the firmware.

**Scratch** (`scratchpad/agents/oc-q12/`):
- `dtb/dtb0-2.dts`: kona base DTBs;
- `dtbo/ov0-5.dts`: hollywood overlays (ov4 = PVT-B);
- `vendor/`: powerhint.cfg and thermal_info_config.json, from the Quest 2
  v2.7 vendor image;
- `q1/`: 14 vs1 DTBs and the Quest 1 powerhint.json /
  thermal_info_config.json, from the PM's existing Quest 1 material
  (firmware `q1_49845030443200410`).

**PM policy:** full hardware-supported range with thermal protection; no
beyond-spec overclocking.

## Quest 2 (XR2 / kona, "hollywood")

| subsystem | hardware max | Meta caps | community | kernel trips (work without Android) |
|---|---|---|---|---|
| CPU silver (cpu0-3) | firmware LUT [O]; SD865-class 1.80 GHz [C] | policy0 max **1804800**; SUSTAINED_PERFORMANCE pins min 1.8048 [M-static] | none found [O] | cpu-0-x-step at 110 °C isolates the core |
| CPU gold (cpu4-6) | LUT [O]; 2.42 GHz [C] | policy4 max **2419200**. L0–L8 = 0.71/0.94/1.17/1.38/1.48/1.86/2.15/2.05/2.42 GHz; L5–L6 dual-core mode; L8 pins 2.42 [M-static + Meta doc] | Boost: +25% CPU (+45% dual-core), ≤45 s, disabled under throttling | cpu-1-x-limit at **90 °C** (hyst 5) throttles; depth per level via `cdev0_upper_limit` [M-static] |
| CPU prime (cpu7) | LUT [O]; 2.84 GHz [C] | policy7 max **2841600**. Pinned to 1075200 in most VR levels; L4/boost ≤ 2457600; L8 uncapped. Apps run on cpuset 4-6 | — | cpu7-notify 75 °C; apc-1 120 °C |
| GPU (Adreno 650) | **587 MHz**: kgsl max_pwrlevel 0 matches DT speed-bin 0 (587/525/490/441.6/400/305); the 670 MHz bins do not apply [M-static] | L0–L5 = 305/400/442/490/525/587. L5 needs dynamic resolution; off in Battery Saver | 2022: top level raised 490 → 525 MHz. QGT developer: "increased temps, noise and battery drain" [C] | gpuss-max-step at **95 °C** |

**Fan** (ov4, kernel `pwm-tach-fan`, max-rpm 7000) [M-static]:
- CPU/GPU at 70/80/90 °C → 5000/6000/7000 rpm;
- front-panel virtual sensor at 40/44/50 °C;
- battery at 45/50/55 °C.

**Other kernel trips:**
- USB-C charging reduced at 53 °C, suspended at 55 °C.
- PMIC trips at 95/115/145 °C.
- LMh (`QTI_THERMAL_LIMITS_DCVS=y`).

**Userspace thresholds** (thermal HAL, `thermal_info_config.json`)
[M-static]. Whether kernel DT zones also mitigate skin/battery on the Quest
1/2 is to be checked (as on the Quest 3, FS-R-006 §4):
- **Skin:** LIGHT 47, MODERATE 51, SEVERE 52, SHUTDOWN 60 °C.
- **Battery:** LIGHT 53, SEVERE 58, SHUTDOWN 59 °C.
- **CPU/GPU:** SEVERE 95, SHUTDOWN 115 °C.
- The DT `batt-virt` trips (58.5/60/64 °C) use the `user_space` governor, so
  they do nothing without a daemon.

## Quest 1 (MSM8998, "monterey" / vs1)

| subsystem | hardware max | Meta caps | community | thermal |
|---|---|---|---|---|
| CPU silver | DT max **1900800** [M-static] | up to 1900800 | — | msm-thermal: hotplug 105 °C, therm-reset 115 °C, core-limit 70 °C (function [C]) |
| CPU gold | DT table up to 2592000. Per-speed-bin tops: bin0 2592, bin1 **2304**, bin2/3 2457.6 MHz; unit bins [O] | max **2304000** (L0–L4 = 0.98/1.34/1.65/1.96/2.30 GHz) [M-static + doc] | — | LMh-lite |
| GPU (Adreno 540) | **710 MHz**; table 710/670/596/515/414/342/257 | public L4 = 670; internal VR_MODE_GPU_5 = **710** [M-static powerhint.json] | Quest1-SteamOS forces `performance` while the panels are on, so it runs at 710 [M-static] | GPU LM 6000 mA, max-power 5448 mW |

**Fan** (`oculus,fan`, PWM 0/120/255): full speed at 85 °C tsens or 48 °C
battery. The fork notes it runs while the panels are lit and stops on
POWERDOWN [M-static].

**Userspace HAL:** CPU/GPU SEVERE 95 °C; battery SHUTDOWN 56 °C.

## Proposed envelope ("full range" = Meta's own ceilings)

- **Quest 2:** silver ≤ 1.8048, gold ≤ 2.4192, prime ≤ 2.8416 GHz; GPU
  ≤ 587 MHz. No higher OPP exists for this bin.
- **Quest 1:** silver ≤ 1.9008, gold ≤ 2.304 GHz; GPU ≤ 710 MHz. Gold above
  2.304 GHz exists only on some speed bins and is never shipped by Meta, so
  it is outside the envelope.
- **Sustained:** Meta's normal app ceiling is L4 (Quest 2: 1.48 GHz /
  525 MHz). L5 and above are conditional or burst. No source documents
  sustained temperatures at max clocks [O].

## Risks

1. **Both kernels default to the `performance` CPU governor**
   (`CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y`). Without Android's power HAL, every
   cluster, including the Quest 2 prime core, sits at maximum. SteamOS must
   set schedutil (CPU) and msm-adreno-tz (GPU) and apply its own caps.
2. **Skin and battery shutdown thresholds are enforced by userspace**
   (the thermal HAL); kernel DT zones may still mitigate (the Quest 3 has
   `batt-virt-limit`/`surf-virt-limit` CPU maps, FS-R-006 §4; the Quest
   1/2 equivalents are to be checked). FrameShift must reimplement the
   userspace part: 47–52 °C skin, 53–59 °C battery on the Quest 2, 56 °C on
   the Quest 1, plus charge throttling on the Quest 1.
3. **Fan curves are kernel and DT-defined.** On the Quest 1, use
   HSYNC_SUSPEND rather than POWERDOWN (as the fork does), or the fan stops.
4. **Battery age:** Quest 1 cells (3648 mAh) are about 7 years old, Quest 2
   about 5. No swelling reports were found [O]; one Quest 2 charging-fire
   forum report exists. **Avoid sustained max clocks while charging.**
5. **Quest 2: resolved (2026-10-09, J-36)** [M]. The PM's unit reports
   1.8048 / 2.4192 / 2.8416 GHz CPU tops and a 305–587 MHz GPU table
   (Adreno 650v3), matching the static analysis above. **Quest 1: still
   open:** its LUT tops and speed bins need the same read-only probe.

## Community report (2026-10-08) [C]

Community reports suggest that the CPUs can be run up to the OEM-defined
maximum but not beyond it (an attempt to force higher clocks reportedly left
a headset unbootable), while the GPU can be pushed well beyond its intended
limits with a kernel module alone.

Assessment [D/C]:
- **CPU:** consistent with the firmware-owned frequency table (EPSS/OSM LUT).
  Forcing beyond it reportedly **left a headset unbootable**. This confirms the PM policy: CPU
  stays within the OEM table.
- **GPU:** plausible. The GPU clock and voltage levels come from the
  kernel's DT pwrlevels and the clock driver, not a firmware LUT, so a
  module can add levels. That is **beyond-spec**:
  - higher clocks need higher voltage corners, which means heat, stability
    risk and long-term silicon wear;
  - the Quest 3 GPU's kernel thermal path (a devfreq cooling device and
    a thermal max-frequency QoS notifier in `kgsl_pwrscale.c`) exists, but
    whether an autonomous temperature-to-GPU policy is present and
    effective is [O] (FS-R-006 §4);
  - battery temperature is already the binding limit.

  The Quest 3 DT's 730/750/788 MHz levels belong to another speed bin
  (likely the XR2+ Gen 2) and are not validated for this unit's silicon.
- **Position:** outside the current envelope. Any GPU overclock would need:
  - a separate PM decision and Chair review;
  - the full thermal stack, fan and watchdog first;
  - instrumented soak tests;
  - Unit 2 only.

### Follow-up community report (2026-10-08) [C]

A further report claims GPU overclocks on both headsets: the Quest 2 held
940 MHz but was very unstable, and the Quest 3 reached 710 MHz and could
probably go further. It also claims the same results carry over to the
Quest Pro and the Quest 3S respectively.

Arbiter's reading [D/C]:
- **Quest 2: 940 MHz** is +60% over its 587 MHz stock top (bin 0), and
  reportedly very unstable. Instability at that clock is the expected sign of an
  under-volted or over-stressed GPU. This is outside any safe envelope.
- **Quest 3: 710 MHz** is +2.9% over its 690 MHz stock top. A small step,
  but still beyond this unit's validated table. The device tree's other bin
  goes to 730/750/788 MHz [M-static].
- **Transfer claims:**
  - Quest Pro ↔ Quest 2: both XR2-family Gen 1; the Quest Pro is XR2+ Gen 1.
  - Quest 3S ↔ Quest 3: both XR2 Gen 2.
  - Plausible at the SoC level [C]. Bins, cooling and voltage tables can
    differ per unit and device.
- **Unknown:** method (DT pwrlevel edit vs. module), voltage corner used,
  temperatures, duration, and whether "held" means minutes or hours.
- **Position unchanged:** GPU overclocking stays outside the envelope. A
  future experiment would need:
  - a separate PM decision and Chair review;
  - our thermal stack, fan and watchdog first;
  - instrumentation (temperatures, rail voltage if readable, error
    counters);
  - Unit 2 only.

  If ever tried, the Quest 3's 710 MHz (+3%) is the obvious first step, and
  the Quest 2's 940 MHz is excluded as unstable.

## PM performance goal (2026-10-08): +20% over nominal sustained clocks, later phase

The PM's goal: about **20% above Meta's normal sustained operating clocks**
(not above max), where safe. To be tested in a later phase, after the
thermal stack, fan control and watchdog exist, with soak tests.

| part | nominal sustained | +20% (arithmetic) | highest **table step** ≤ +20% | table max | note |
|---|---|---|---|---|---|
| Quest 3 CPU (cpu2-5) | 1.92 GHz | 2.30 GHz | **2.208 GHz** (+15.0%) | 2.3616 GHz | 2.30 is not a step |
| Quest 3 GPU | 545 MHz | 654 MHz | **640 MHz** (+17.4%) | 690 MHz | 654 is not a step; 690 withheld (never exposed to apps) |
| Quest 2 CPU (gold) | 1.4784 GHz | 1.774 GHz | **1.7664 GHz** (+19.5%) | 2.4192 GHz | |
| Quest 2 GPU | 525 MHz | 630 MHz | **587 MHz** (+11.8%) | 587 MHz | at max |
| XR Elite GPU | ~490 MHz (HTC med) | 588 MHz | **587 MHz** (+19.8%) | 587 MHz | at max |
| Quest 1 GPU | 670 MHz | 804 MHz | **710 MHz** (+6.0%) | 710 MHz | at max |

**Rule (FS-R-006 §7):** only existing table steps are used; no step is
introduced to meet a percentage. A table step is not evidence of
sustainable operation; each needs soak testing under our thermal stack.

Where +20% exceeds the table, the in-spec maximum is the ceiling unless a
separate beyond-spec decision is made (see the community-report notes).
