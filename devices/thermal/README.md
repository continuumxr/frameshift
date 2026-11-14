# Thermal and battery service

FrameShift's own thermal and battery protection, for when Android is not running.
`fs-thermald` is the single owner of the fan, the CPU and GPU speed caps and the shutdown
decision; `fs-metacfg` reads Meta's thermal configuration, read-only, from the owner's own
headset. Built and tested offline; the device tests come on the kernel for Steam.

**What it does:** it reads the temperature sensors, the battery and the fan. As temperatures rise
it raises the fan floor and caps speeds; at Meta's shutdown limits, or at low battery while
discharging, it shuts the headset down gracefully, with timed forced fallbacks. A missing,
frozen or implausible sensor, or a faulty fan, makes it fail safe. Clocks are never pushed beyond
the manufacturer's tables. See
[How FrameShift works](../../docs/HOW-FRAMESHIFT-WORKS.md#4-safety-systems).

| path | what it does |
|---|---|
| `src/fs-thermald.c`, `src/thermald_core.c`, `src/thermald_accept.c`, `src/thermald_tables.c` | start-up and input/output, the decision core, input acceptance, and the built-in tables |
| `src/thermald_exec.c`, `src/fs-poweroff-final.c` | carry out a shutdown: graceful first, then timed forced fallbacks if a clean shutdown stalls |
| `src/fs-thermald-watch.c` | watches the service's heartbeat under SteamOS and starts a clean shutdown if it stops |
| `src/fs-noticed.c`, `src/warnscreen/` | tell the user: status LED patterns, a static warning screen and a record for the next boot |
| `src/fs-metacfg.c` | the read-only reader of Meta's thermal configuration from the active system partition |
| `stage/pid1-hold-ts.sh` | the test images' first process, with the thermal shutdown branch |
| `valve/` | the systemd units, drop-ins and masks the service adds over Valve's image (no Valve file is edited) |
| `tables/known-firmware.tsv` | the known firmware rows (hashes only) |
| `tools/ref/` | independent Python reference models of the core and the reader, and their tests |
| `tools/sim/` | a simulated sensor tree, over a hundred scenarios, a simulated fan and a fan sweep |
| `tools/fix/` | writes synthetic test images with invented values |
| `tools/mcrec.py` | decodes a reader record and writes a derived table locally |
| `tools/test_*.py`, `tools/stage/`, `tools/check_poweroff.py` | the offline suites |
| `tools/test_real_local.sh` | an optional local check against the owner's own firmware (nothing from it is committed) |
| `tools/build.sh`, `tools/build_warnscreen.sh`, `tools/run_all.sh` | build everything (native and static ARM64) and run every suite |
| `fixtures/` | the recorded results of the suites |

The service keeps the thresholds it needs in its own built-in tables (`src/thermald_tables.c`).
The derived tables of Meta's thermal configuration are not published: generate them locally from
your own headset's firmware with `fs-metacfg` and `tools/mcrec.py --derived` into
`tables/derived/`. The `tables` and `accept` suites need them and report FAIL without them.

Run everything in WSL: `bash devices/thermal/tools/run_all.sh` (it rewrites the committed
`fixtures/*/RESULTS.txt` files with the results of your run).

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
