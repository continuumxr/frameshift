# Quest 3 thermal service (TS): device inputs

This folder holds the device-side inputs of FrameShift's thermal and battery service for the Quest 3
(the service itself is in `devices/thermal/`):

| file | what |
|---|---|
| `SENSORS.md` | sensor identities, units, mappings and virtual-sensor equations; the PMIC channels |
| `FIRMWARE.md`, `firmware-manifest.tsv` | firmware files (hashes only), triggers, load/start and error behaviour (ADSP, GPU staging) |
| `target/fs-ts-info.sh`, `tools/test_ts_info.sh` | the composition identity rows each TS image's runner reads first (read-only), with their tests |
| `fixtures/ts-info/` | the recorded results of those tests |

**Withheld from this public copy:** the T0 package (the first TS step, an Android-side probe under stock
Horizon: its rows, capture tool, checker, sign-off sheet and fixtures) and its README, because the probe
includes a row outside the public scope (see the root `README.md`, "About this public copy"). T0, the Android-side
baseline, passed on both Quest 3 units (2026-10-18/19 UTC); the later stages (T1–T5) run on FrameShift's own
kernel and have not run yet.
