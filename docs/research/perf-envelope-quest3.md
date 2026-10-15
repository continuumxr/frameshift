# Quest 3 — safe CPU/GPU operating range (research, 2026-10-08)

*Edited for publication: names and links removed or paraphrased.*

Agent report. Web research plus local artifacts; no device action. Scratch
copies: `scratchpad/agents/oc-q3/` (`q3.dts`, `tz.txt`).

**Tags:**
- [M-static]: the v2.7 `vendor_boot_dtb0.dtb`;
- [M]: FS-A-006 (private review record);
- [C]: community claims or inference;
- [O]: open.

**PM policy (2026-10-08):** use the full hardware-supported range with
thermal protection. No beyond-spec overclocking (no firmware changes).

## Topology [M-static]

- 6 CPUs in 2 frequency domains: cpu0-1 (dmips 1024) and cpu2-5
  (dmips 1075). This suggests one core type [C].
- `qcom,cpufreq-hw-epss` with `dcvsh0/1` LMh IRQs: hardware limits
  management clamps the CPUs independently of the OS.

## CPU

| | domain 0 (cpu0-1) | domain 1 (cpu2-5) |
|---|---|---|
| hardware max (firmware LUT) | 2.05 GHz [C] (Geekbench eureka run, https://browser.geekbench.com/v5/cpu/22480546) | 2.36 GHz [C] |
| LUT size | 9 OPPs (`thermal-cpufreq-0` max state 8) [M] | 11 OPPs (`thermal-cpufreq-1` max state 10) [M]. Values [O] |

**Meta app levels:** L0 0.69, L1 1.09, L2 1.38, L3 1.65, L4 1.92, L5 2.05,
L6 2.21, L8 2.36 GHz
(https://developers.meta.com/horizon/documentation/native/android/os-cpu-gpu-levels/).
- **Sustained:** L4 1.92 GHz. L5 2.05 GHz only when trading GPU for CPU.
- **Burst:** L6 2.21 GHz needs CPU Boost: ≤45 s each, ≤20% of runtime,
  disabled under throttling
  (https://developers.meta.com/horizon/essentials/boost-cpu-gpu-levels/).
- **L8:** undocumented availability.

**DT limits** [M-static]:
- `cpu-1-*-limit` and `soc-limit` at 89 °C;
- `batt-virt-limit` at 45/58 °C;
- `surf-virt-limit` at 48 °C;
- per-core emergency 110 °C, reset-mon 115 °C.

## GPU (Adreno740v3, chipid 0x43050b00) [M-static]

- **DT pwrlevels:**
  - bins 0x00/0x92/0xa8: 690, 640, 599, 545, 492, 456, 421, 350, 317,
    285 MHz;
  - bin 0xa7 adds 788/750/730. Likely the XR2+ Gen 2 bin [C].
- **This unit** has 10 levels (`thermal-devfreq-0` max state 9), so a
  **690 MHz max** [M].
- **Meta app levels:** L0 285 … L6 640 MHz. **690 MHz is never exposed to
  apps.**
  - L4 545 MHz is the main sustained budget.
  - L5 599 needs a trade or dynamic resolution.
  - L6 640 needs both, "when thermals allow".
- **Trips:** `gpuss-0..7` `tj_cfg` 95 °C, reset-mon 115 °C.
- **No DT cooling map targets the GPU.** In Android, GPU throttling comes
  from `perf_service`. Its table has not been read [O].
- A GPU current limiter IRQ (`freq_limiter_irq`) exists.

## Thermal, fan and battery

- **Fan** [M-static]: steps at 3700/4500/5000/5500 rpm; `max-rpm` 8500,
  `silent-rpm` 4000. The DT never uses the top ~35% of the fan's range.
  - SoC zones trip it at 60/75/80/85 °C.
  - `batt-virt` at 45/49/53 °C.
  - `surf-virt` (skin) at 42/44/46 °C.
- **Skin:** fan 42–46 °C, CPU cap 48 °C, shutdown 60 °C (perf_service).
- **Battery:**
  - The 5060 mAh pack sits under the fan and board [C, iFixit].
  - Caps at 45/58 °C; shutdown 65 °C.
  - Idle reading 30–31 °C [M].
- **Other trips:** DDR 90 °C, NSP 95 °C; PMIC alarms at 95/115/145 °C.
- **USB connector:** charging cut at 60 °C.

## Community

- About 2–2.2 h of battery in demanding games, i.e. ~9–10 W [C].
- No reports of damage at max levels, and no reports of unlocked governors
  on the Quest 3 [O].
- Overheat shutdowns appear only as anecdotes [C].

## Risks

1. **Fan not driven at full clocks.** Linux did not drive the fan in stage
   1 [D]. On panel blank the v2.7 driver caps the fan at `silent_rpm`
   (4000 RPM on the Quest 3, DT `oculus,silent-rpm`), it does not stop it
   (corrected, FS-R-006 §4). A headless system needs an explicit fan policy
   with tach/failure handling. This is the biggest risk.
2. **GPU thermal control is not established.** The kernel has a GPU
   devfreq cooling device and a thermal max-frequency QoS path; whether
   any DT zone drives them autonomously is [O]. SteamOS needs its own
   verified governor: battery, skin and SoC zones in; GPU devfreq and CPU
   caps out.
3. **Battery heat is the binding constraint,** not SoC Tj. The cell sits
   under the SoC, and Meta caps from 45 °C.
4. **Skin limit 48 °C.** Long sessions are a sustained load.
5. **Skin and battery zones need the ADSP `battery` supply** (FS-A-006).

## Proposed envelope [D/C, for the PM]

- **Allow the full LUT:** CPU 2.05/2.36 GHz, GPU 690 MHz.
- **Sustained targets:** CPU ≤ 1.92–2.05 GHz, GPU ≤ 599–640 MHz.
- **Protection:**
  - all DT step_wise zones and the fan restored;
  - GPU throttle on `batt-virt` ≥ 45 °C, `surf-virt` ≥ 48 °C and `gpuss`
    ≥ 95 °C;
  - a hard shutdown watchdog at 115/65/60 °C (SoC/battery/skin).
- **Do not run 690 MHz** until a thermal soak test.

## Read-only confirmations (under the PM's standing read-only authorisation)

- `cat /sys/devices/system/cpu/cpufreq/policy*/scaling_available_frequencies`
- `cat /sys/devices/system/cpu/cpufreq/policy*/cpuinfo_max_freq`
- `cat /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies`
- `cat /sys/class/kgsl/kgsl-3d0/max_gpuclk`
- `ls /odm/etc/ | grep -i thermal`, and the `thermal_info_config.json`
  location

## Confirmed on Unit 1 (v66, Android, read-only, 2026-10-08T17:48Z) [M]

Source: FS-A-006 (private review record) (exact
commands inside).

- **CPU policy0 (cpu0-1):** 691200 960000 1094400 1228800 1382400 1516800
  1651200 1920000 **2054400** kHz.
- **CPU policy2 (cpu2-5):** the same, plus 2208000 and **2361600** kHz.
- **CPU governor:** `walt`.
- **GPU:** Adreno740v3; available 690/640/599/545/492/456/421/350/317/285
  MHz; `max_gpuclk` **690 MHz**; governor `msm-adreno-tz`; 10 pwrlevels.
  That confirms this unit's bin.
- **Meta's thermal and power configs** are on the vendor partition:
  `/vendor/etc/thermal_info_config.json`, `powerhint.cfg`,
  `powerhint_holdout.cfg`, `vr_runtime_power_mitigation.json`. Readable
  offline from the vendor images.
- **Idle temperatures:** SoC ~29 °C, battery 25 °C, skin (`surf-virt`)
  ~27 °C.

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
