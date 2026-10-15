# HTC Vive XR Elite

*Edited for publication: names and links removed or paraphrased.*

**Shelved** (last in the order adopted by FS-R-006 §1; no active work as of
2026-10-10).
- **SoC:** XR2 (Gen 1), SM8250 **[M]**, from its own `dtbo`. Corrected
  2026-10-08 from "XR2+ Gen 1".
- XR Elite work from an earlier, shelved device programme is not published.
- Existing material: the PM's existing XR Elite material (read-only, not in
  this repository).

**Performance envelope** (`docs/research/perf-envelope-xr-elite.md`):
- The CPU and GPU frequency tables are **identical to the Quest 2's**
  (1.8048/2.4192/2.8416 GHz; GPU bin 0, 587 MHz).
- **Fan, battery and thermal control differ completely:**
  - the fan is a MAX31760 driven **only by HTC's closed `thermal-engine`**;
  - the main 24.32 Wh pack is in the rear cradle and reports over UART,
    outside the kernel;
  - there is no kernel skin trip.
- **Safety rule:** no full-range clocks until our own fan loop and
  cradle-battery monitoring exist. Interim fan rule: ≥ 20% duty, 100% at
  ≥ 50 °C (`PROJECT_SETUP.md` §6A).

Per-device boot, kernel, DT, driver and recovery material for this target lives
here. Common userspace and build infrastructure stays outside `devices/`
(`docs/PROJECT_SETUP.md` §1.2).
