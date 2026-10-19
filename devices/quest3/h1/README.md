# H-1 / H-2: the ordered, bounded module loader (Quest 3, later images)

**Status (2026-10-16):** offline library, reviewed by two internal adversarial reviewers (§8); **not
part of any image yet** and **not a Chair-concurred package**. FS-R-013 §10 ACCEPTS H-1 and H-2 "for
later packages" with conditions (mapped in §2.6); each image that adopts this library (K1i, TS T1+,
R-1) brings it inside its own reviewed package. Nothing here touched a device, `/persist` or the PM's offline backup drive.

> **Correction (FS-R-014 §8, 2026-10-18; README rev 1).** The Chair NOTED the later H-1/H-2 changes
> (H1-F1 to H1-F7, §5). They **require their own concrete composition package**: nothing in this
> library is concurred for an image until a package that adopts it is reviewed. The corrected
> nautilus history stays visible: `nautilus.ko` **was** in the earlier 95-module closure (K1a,
> stage 3d). Source inspection [M-static, `drivers/staging/oculus/nautilus.c` in `dbc2bc83a2b6`;
> the Chair's independent inspection, re-checked by us read-only] shows that probe obtains its
> resources and selects the default pinctrl state but does not call the driver's explicit
> regulator/clock enable routine. That supports a narrower source conclusion only. It does **not**
> measure projector darkness and does not exclude inherited hardware state [O]. It does not
> require another K1a boot or block the unchanged closure. See H1-F4 (§5).
**K1a and stage 3d are unchanged**: K1a's pinned `devices/quest3/k1a/init.sh` keeps its own loader and
its 95-module list (it is read here, read-only, as the negative control of §6).

Design: `docs/research/device-health-design.md` rev 2.1, rules **H-1** (S/E/F three-phase loading) and
**H-2** (firmware-loader fallback settings), findings A1–A5, A9, A10, A15. Acceptance and conditions:
FS-R-013 (private review record) §10.

**Clean room.** Facts below come from Meta's published GPL kernel source (v2.7 tree `dbc2bc83a2b6`,
WSL `~/work/kgate27/src`), its stock config, the decompiled v2.7 runtime DT (`~/work/dtdiff/v27.dts`),
and the pinned v2.7 module indexes (`modules.dep`/`.softdep`/`.alias` of the vendor_boot ramdisk,
vendor_dlkm and odm_dlkm), read as data. No binary was disassembled; no code was copied. None of these
inputs is committed (the derived lists and the report are our own records of facts).

Tags (FS-R-001): **[M]** measured on hardware · **[M-static]** read from a named artifact (file:line) ·
**[D]** derived · **[C]** inferred, unconfirmed · **[O]** open.

| file | what |
|---|---|
| `target/fs-modload.sh` | the library (busybox ash, sourced by a PID 1 init): `fsml_run` |
| `lists/{k1i,ts-t1,ts-t2,ts-t3b}.phases` | the derived phase lists (generated; LF; the loader's input) |
| `tools/derive-phases.py` | derives and checks the lists from the DT and the module indexes (§4) |
| `fixtures/derive/REPORT.txt` | the derivation report (`--check` run): every module, its phase, readiness and reason |
| `tools/test-modload.sh`, `tools/kmodel-insmod.sh` | the test harness: the library under the reviewed busybox (aarch64, qemu-user) on a simulated `/sys`, with a simulated module loader (§6) |
| `fixtures/test/RESULTS.txt` | the last full test run |

---

## 1. Facts the loader rests on

| # | fact | tag |
|---|---|---|
| L1 | `do_init_module()` calls `async_synchronize_full()` for **every** module loaded without the `async_probe` parameter, unconditionally (`kernel/module.c:3799-3800`). It waits for all pending async work, including probes scheduled by earlier modules | [M-static] |
| L2 | The generic module parameter `async_probe` sets `async_probe_requested` (`kernel/module.c:3979-3981`); the value is not parsed (`async_probe=0` also requests it). Such a module skips L1 | [M-static] |
| L3 | A driver probes asynchronously if its type is `PROBE_PREFER_ASYNCHRONOUS`, or if its type is the default and its module was loaded with `async_probe`; `PROBE_FORCE_SYNCHRONOUS` stays synchronous (`drivers/base/dd.c:778-796`); asynchronous probes are scheduled with `async_schedule_dev` (`:1103-1121`) | [M-static] |
| L4 | `/sys/module/<m>/initstate` reads `coming` while the module's init runs; `do_init_module()` sets `MODULE_STATE_LIVE` (`kernel/module.c:3784`) **before** L1's wait (`:3799-3800`). So a plain `insmod` that is blocked in `async_synchronize_full()` behind another module's hung async probe already reads **`live`**: its own init is done, only its `insmod` has not returned. A failed init frees the module (`show_initstate`, `:1201-1223`) | [M-static] |
| L5 | A module whose dependency is still `coming` waits for it up to 30 s (`resolve_symbol_wait`, `kernel/module.c:1515-1530`) | [M-static] |
| L6 | A driver registered by a module is linked as `/sys/module/<m>/drivers/<bus>:<driver>` (`drivers/base/module.c:23-30, 55-70`); its bound devices are the symlinks in the driver directory | [M-static] |
| L7 | **A userspace deadline does not cancel a module init or a pending probe.** An init blocked uninterruptibly continues in the kernel whatever userspace does; killing the `insmod` process does not undo or stop it (FS-R-013 §10). The loader never kills the child: a deadline only ends its own wait, and the record says so (`cancel=none`, `insmod=blocked`) | FS-R-013 §10; [D] |
| L8 | `CONFIG_FW_LOADER_USER_HELPER=y` and `CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y` (stock.config:1727-1728); `force_sysfs_fallback` therefore defaults to 1 (`drivers/base/firmware_loader/fallback_table.c:19-21`); both settings are 0/1 `uintvec` sysctls under `/proc/sys/kernel/firmware_config/` (`fallback_table.c:24-43`, `kernel/sysctl.c:2258-2265`); `ignore_sysfs_fallback` overrides the forced fallback (design A2) | [M-static] |
| L9 | H-2 disables the **stated sysfs fallback** only: it does not bound a driver's own direct file I/O or any other driver stall (FS-R-013 §10), and drivers built into the kernel may request firmware before PID 1 runs (design A5, O-H3) | FS-R-013 §10; [O] |
| L10 | `pwm-tach-fan`'s "No active panel, deferring probe" path exists only when `CONFIG_QCOM_PANEL_EVENT_NOTIFIER` is off (`drivers/staging/oculus/pwm-tach-fan.c:1053-1108`); it is `=m` (stock.config:5709, K1a's config:5644) and the fan registers through `panel_event_notifier_register` instead (`:1188-1210`). **The fan's probe does not wait for the display.** The fan treats any `devm_regulator_get` error, including `-EPROBE_DEFER`, as "no vdd supply" (`:1118-1122`); only fw_devlink (default on, `drivers/base/core.c:1525`; no override in the v2.7 bootargs) orders it after its `bob` supply, so **adopting images must not set `fw_devlink=permissive|off`** | [M-static]; [D] |
| L11 | `virtual_sensor` looks up by name its input zones (`virtual_sensor.c:1035-1048`), its fault-estimator zones (`:915-985`, defer at `:974-979`) and, for `battery_virtual_sensor` only, its fallback zone `battery` (`:1198-1202`; v27.dts `fallback-thermal-zone`, the only one); it defers until they exist unless `meta,hotpluggable` is set (`:1005-1009`; 0 hits in the v2.7 DT). The **DT** zones (`pcb1/pcb3/pogo/soc-usr`, `usb-conn`, and `batt-virt-usr`/`surf-virt-usr` themselves) are registered at boot by the thermal core whether or not a sensor driver exists (`drivers/thermal/thermal_of.c:1171-1220`), so they never cause a defer and a `tz:` check on them proves nothing. The real by-name probe suppliers are the two power-supply zones, `bq27z561-0` (the gauge, `bq27xxx_battery_i2c.c:208`) and `battery` (the charger psy), created by the psy core (`power_supply_core.c:1055-1070`) | [M-static] |
| L12 | The glink SMEM edge needs SMEM (`qcom_smem_alloc`/`get` return `-EPROBE_DEFER` until SMEM probed, `drivers/soc/qcom/smem.c:479-480`); SMEM (built in, `CONFIG_QCOM_SMEM=y`) defers until its hwlock exists (`smem.c:1064-1070`; v27.dts `qcom,smem` `hwlocks`) → `qcom_hwspinlock`, and only then creates `qcom-socinfo` (`:1081`), whose part info `icc-rpmh` reads at probe (`icc-rpmh.c:322-327`) | [M-static] |
| L13 | Built in (no module): softdog (`CONFIG_SOFT_WATCHDOG=y`), SMEM, GENI SE wrapper (`CONFIG_MSM_GENI_SE=y`), pstore pmsg. Modules: `smp2p` (`CONFIG_QCOM_SMP2P=m`), `msm_qmp` (`CONFIG_MSM_QMP=m`) | [M-static] stock.config |
| L14 | The anorak ADSP descriptor sets `.auto_boot = false` (`drivers/remoteproc/qcom_q6v5_pas.c:967-979`, applied at `:755`): loading `qcom_q6v5_pas` only registers the remoteproc (`offline`); something must write `start` to its `state` (the loader does, `FSML_RPROC_START`, §2.2). The battery psy registers at probe whether or not the ADSP runs (`qti_battery_charger.c:3336`), so `psy:battery` proves the driver, not live battery data | [M-static] |
| L15 | `qcom-dload-mode`'s `download_mode` parameter exists as soon as the module is loaded and reads 0 by default (`qcom-dload-mode.c:109`; `CONFIG_POWER_RESET_QCOM_DOWNLOAD_MODE_DEFAULT` not set, stock.config:3009); the hardware disarm and the notifiers are in its **probe** (`:306-347`) | [M-static] |

## 2. The library (`target/fs-modload.sh`)

### 2.1 Use and integration contract

```sh
. /lib/fs/fs-modload.sh
FSML_LIST=/lib/fs/modules.phases          # one of lists/*.phases, staged by the builder
FSML_LIST_SHA=<sha256 of that list>       # pinned by the builder (required)
FSML_MD=/lib/modules                      # the module files
FSML_INDEX="/lib/modules/modules.dep=<sha256> /lib/modules/modules.softdep=<sha256> ..."   # pinned
FSML_LOG=/run/fs-init/modules.log FSML_RUN=/run/fs-init/ml FSML_DL_S=10 FSML_S_MAX=90 ...   # every knob assigned
FSML_RPROC_START=3000000.remoteproc-adsp FSML_RPROC_WAIT=15   # TS T3b / R-1 only
rc=0; fsml_run || rc=$?    # 0 HANDOFF OK · 1 HANDOFF REFUSED · 2 refused before any module load
```

Each adopting package states how it meets each item:
1. **No workload unless 0.** The caller starts no workload (the thermal service's run, a trial runner,
   `switch_root` to the OS) unless `fsml_run` returned **0**. On 1 or 2 a stage image takes its fail
   path (record, LEDs, bounded reboot); a product image hands over to the thermal fail-safe (design
   H-1 item 1).
2. **Pins.** `FSML_LIST_SHA` and every `FSML_INDEX` file are hash-pinned by the builder (the K1a
   pattern: `MODDEP_SHA`, `MODSOFTDEP_SHA`). A wrong or unpinned list, or an unpinned index, refuses.
3. **Every knob assigned explicitly.** PID 1 inherits `name=value` words of the kernel command line as
   its environment (`init/main.c:556-567`), so the init assigns every `FSML_*` knob itself. The
   test-only knobs (`FSML_ROOT`, `FSML_UPTIME`, `FSML_INSMOD`) are ignored unless `FSML_TEST=1`, and
   every effective value is recorded in the `START` line.
4. **Shell state.** `fsml_run` runs with `set +eu` and the default `IFS`, and restores the caller's on
   return; under `set -e` call it as `fsml_run || rc=$?`.
5. **Bound.** The §2.4 bound fits the image's own deadline, or the image says what happens when it does
   not (a stage image's PID 1 deadline reboots; a product image's thermal fail-safe acts).
6. **After the handoff, no plain module load** while F async probes may be pending (a later plain load
   would block in L1 behind a hung F probe: the A1 hazard moved downstream): either `FSML_LATCH=1`
   (the module latch, FS-A-013 §3.3, R-1; set after phase F whatever the outcome, design H-1 item 5),
   or the next stage loads modules only with `async_probe`.
7. **TS T3b / R-1: the ADSP start (H1-F6, Arbiter requirement).** These packages set
   `FSML_RPROC_START=3000000.remoteproc-adsp` and stage `adsp.mdt` on `firmware_class.path` (H-2 turns
   the sysfs fallback off; the loader records the path it sees). The loader starts the ADSP explicitly
   at the end of phase S and waits for `running` with a bounded wait (`FSML_RPROC_WAIT`); an absent
   `running` is an **S-readiness failure**: the handoff is refused.
8. **fw_devlink stays on** (L10).
9. **The S ceiling's safe path.** When the loader refuses for the S ceiling (or any S failure), the image
   takes its safe path: a stage image returns to fastboot through its PID 1 fail path / deadline, a
   product image shuts down through the thermal fail-safe. The ceiling does not cancel a blocked init
   (FS-R-013 §10); the image does not wait for it.
10. **The classifier reports READY-BLOCKED.** Every `FINDING ready-blocked` line of the record is reported
   as a finding by the adopting package's classifier/host tools (even when the handoff was OK).

### 2.2 Order of operations

1. **Pre-checks** (no module loaded on any failure, return 2): the log is writable (else a line on
   stderr); `FSML_RUN` is an absolute, writable directory (stale `*.rc`/`*.err` files are removed);
   every budget is 1–9999 s with no leading zero (ash reads a leading zero as octal); the poll interval
   is 0.01–5 s; the options are known.
2. **H-2** before any module: write `force_sysfs_fallback=0`, `ignore_sysfs_fallback=1`,
   `/sys/class/firmware/timeout=1` (H-Q6 keeps the 1 s timeout); **read each back**; a mismatch, a
   missing file or an unreadable file → `FWCFG REFUSED`, return 2.
3. **Index pins**: each `FSML_INDEX` file's SHA-256 must match; no pins → refused (return 2).
4. **List**: its SHA-256 must equal `FSML_LIST_SHA`; then syntax (phase letter; a name of
   `[A-Za-z0-9_.-]` ending `.ko` whose module name is an identifier; known readiness atoms, no empty
   atom; no `auto` atom anywhere on an S line; no duplicate; phases grouped S → E/e → F; a last line
   without a newline is read; the shell's entry count must equal awk's), then **closure and order**
   against the pinned index: every `modules.dep` dependency is listed earlier; every `softdep pre:`
   target that exists in `FSML_MD` is listed earlier; every listed module is in the index. Any fault →
   return 2.
5. **Phase S** — plain `insmod`, list order, each with its own deadline `min(FSML_DL_S, time to the
   ceiling)`; **never skipped by any budget**. Phase S has a **ceiling** `FSML_S_MAX` (Arbiter decision,
   H1-F7): reaching it is an **S-readiness failure** — the run stops there, the S modules not yet
   attempted are recorded `MODULE_NOT_ATTEMPTED reason=s-ceiling` (outcome `NOT-ATTEMPTED`; never treated
   as done), E and F are not loaded (`SKIPPED reason=s-ceiling`), `S_CEILING reached` is recorded with
   FS-R-013's point that the ceiling does not cancel a blocked init, and the handoff is refused
   (`S:ceiling:REACHED`). The wait for one module ends when its `insmod` returns, when the deadline passes, or
   1 s after its `initstate` turned `live` without the `insmod` returning (L4: its init is done; the
   `insmod` is blocked in the global async wait → recorded `result=LIVE insmod=blocked child=<pid>`).
   Then one S readiness window `min(FSML_READY_S, the ceiling)` for the S modules that can still become
   ready — **none when an S module already FAILED** (S cannot be ready; the run goes straight on). Then,
   if `FSML_RPROC_START` is set and S is ready, the **explicit remoteproc start**: write `start` to its
   `state`, wait for `running` up to `min(FSML_RPROC_WAIT, the ceiling)`; not registered, or not
   `running` in time → S not ready (`S:rproc-<name>:<state>`), refused (H1-F6).
6. **Phase E** — plain `insmod`, each with `min(FSML_DL_E, time left)`, inside
   `min(start + FSML_BUDGET_E, T0 + FSML_BUDGET_TOTAL)`; on exhaustion the rest of E is
   `MODULE_SKIPPED reason=budget-e|budget-total`; then a readiness wait for the **required** (`E`)
   entries inside the same end time (none when a required entry already FAILED or was skipped). E is
   loaded even when S is not ready (the LED, USB and display are the notice channels).
7. **Phase F** — S readiness is **re-checked without waiting** first (an S module that missed its window
   may be ready by now). If S is ready: `insmod <m> async_probe=1` (L2, L3), each with
   `min(FSML_DL_F, time left)`, inside `min(start + FSML_BUDGET_F, T0 + FSML_BUDGET_TOTAL)`; rest
   SKIPPED on exhaustion. **No plain insmod follows** the start of F (design H-1 item 3). If S is not
   ready, F is skipped as a whole (`reason=s-not-ready`), and that skip **always refuses** the handoff
   (`F:all:SKIPPED-s-not-ready`; `FSML_F_ON_S_FAIL=load` loads F instead).
8. **Settle and classify**: one bounded settle (≤ 1 s) for `insmod` results still in flight, then the
   classification with no further waiting, the verdict, and the optional latch.

### 2.3 Outcomes and readiness

`insmod` returning 0 is **not** readiness (FS-R-013 §10; L1–L3: with `async_probe` the probe may still
be pending; a deferred probe also returns 0). Every module ends with one `OUTCOME`:

| outcome | meaning |
|---|---|
| `READY` | `initstate` = `live` **and** every atom of its readiness predicate holds, and its `insmod` returned |
| `READY-BLOCKED` | as READY, but its `insmod` is still blocked (L4: typically in the global async wait behind another module's pending probe). Recorded with a `FINDING ready-blocked … covered=` line (H1-F7) |
| `PENDING` | `initstate` = `live`, predicate not met (probe pending, deferred, or no device bound) |
| `FAILED` | `insmod` returned non-zero and the module is not live (rc and the first stderr line kept), the file is missing, or a timed-out `insmod` later returned non-zero (`late=1 late_rc=<rc>`) |
| `TIMED-OUT` | the deadline passed and the module is still not `live` (`coming`, `going`, absent) |
| `SKIPPED` | not attempted: a phase or the total budget ran out, F while S was not ready, or E/F after the S ceiling |
| `NOT-ATTEMPTED` | an S module not reached before the S ceiling (an S-readiness failure, never a skip-and-continue) |

Annotations: `insmod=blocked` — no `insmod` result at the end (the child still runs; never killed);
`late=1 late_rc=<rc>` — the `insmod` returned after its deadline; `note=already-live` — `insmod`
failed (e.g. EEXIST) on a module that was already live; it is judged by its readiness.

**HANDOFF OK** iff every **S** module and every **E** (required) module is `READY` or an acceptable
`READY-BLOCKED`, the remoteproc start (if configured) reached `running`, the S ceiling was not reached,
and F was not skipped for S. A `READY-BLOCKED` module is **acceptable only if a device-readiness check
covers its function** (Arbiter decision, H1-F7): its own predicate has a device atom (`covered=own-check`),
or it is a `live` infrastructure entry whose device side the S/E roots' own checks prove
(`covered=root-checks`; the derivation's live-coverage check guarantees such a root exists, and those
roots must themselves pass here). A `READY-BLOCKED` S/E module whose check is only `auto` (or nothing)
is `covered=no` and refuses (`READY-BLOCKED-uncovered`). Every `READY-BLOCKED` module is listed on the
`HANDOFF … ready_blocked=` line and reported by the classifier (contract item 10). `e` modules are essential but best-effort (a
fault there is a device-health row, design §2.3 rows 7–9/22); F modules never gate the handoff.

Readiness predicates (comma = all must hold; every check reads sysfs only, opens no device node):

| atom | holds when |
|---|---|
| `live` | `initstate` = `live`. Only for infrastructure modules whose device side a root's predicate proves (the derivation checks that every S `live` entry is covered by such a root, §4) |
| `auto` | every driver the module registered (L6) has ≥ 1 bound device; a module that registered none is ready when live. Not allowed on S lines (a driver with no device on this board would read PENDING) |
| `bound:N` | ≥ N devices bound across the module's drivers |
| `hwmon:NAME`, `tz:TYPE`, `iiochan:LABEL`, `psy:NAME`, `udc:NAME`, `led:NAME` | an hwmon with that `name`; a thermal zone with that `type`; an IIO device with `in_temp_<LABEL>_input`; `/sys/class/power_supply/NAME`; `/sys/class/udc/NAME`; `/sys/class/leds/NAME` |
| `cpufreq:policyN` | `/sys/devices/system/cpu/cpufreq/policyN` exists |
| `rproc:NAME[=STATE]` | a remoteproc with that `name` (and, if given, whose `state` is STATE) |
| `param:M/P` | `/sys/module/M/parameters/P` exists (existence only; values are the consumer's check) |
| `path:/sys/…` | that sysfs path exists |

### 2.4 Budgets and the bound

Defaults (seconds): `FSML_S_MAX=90`, `FSML_DL_S=10`, `FSML_DL_E=10`, `FSML_DL_F=10`,
`FSML_READY_S=15`, `FSML_RPROC_WAIT=15`, `FSML_BUDGET_E=30`, `FSML_BUDGET_F=60`,
`FSML_BUDGET_TOTAL=150`, poll 0.1 s.

**Bound** [D]: every wait in phase S (each `insmod`, the readiness window, the remoteproc start) ends by
the S ceiling, so phase S ends by `T0 + FSML_S_MAX` (+ the list checks and one poll); reaching the
ceiling refuses at once (no E, no F). Otherwise E ends by `min(S_end + BUDGET_E, T0 + TOTAL)` and F by
`min(E_end + BUDGET_F, T0 + TOTAL)`, each plus at most one poll; if S already ran past `T0 + TOTAL`, E
and F are skipped. The settle adds ≤ 1 s. So the loader returns by `max(T0 + S_MAX, T0 + TOTAL) + 1 s`
plus a few polls (defaults: 151 s). A module whose init is still blocked when the loader returns is not
cancelled (FS-R-013 §10); the image's safe path does not wait for it (contract item 9). `S_MAX` must fit
the image's deadline (stage images: 200 s); each TS/K image picks `DL_S` and `S_MAX` from K1a's measured
load times [O].

### 2.5 The record (design D2)

`FSML_LOG` (default `/run/fs-init/modules.log`, survives `switch_root`; appended, never truncated), one
line per event, `FSML1 t=<s.cc since start> <EVENT> …`: `START` (every effective knob), `FWCFG`,
`INDEX`, `LIST`, `BOUND`, `PHASE`, `MODULE` (`result=LOADED|LIVE|FAILED`, rc, ms, `initstate`,
params, `insmod=blocked child=`), `MODULE_TIMEOUT` (`initstate=`, `child=`, `cancel=none`),
`MODULE_SKIPPED`, `MODULE_NOT_ATTEMPTED`, `S_CEILING`, `RPROC_START`, `S ready=yes (re-checked …)`,
`OUTCOME`, `FINDING ready-blocked`, `LATCH`, `SUMMARY`, `HANDOFF verdict=OK|REFUSED
not_ready=<phase:module:outcome,…> [f_skipped=s-not-ready] [ready_blocked=…] [insmod_blocked=…]`.
No serial numbers, MACs or sensor values (H-13): module names, states and counts only.

### 2.6 FS-R-013 §10 conditions → where they are met

| condition | met by |
|---|---|
| distinguish ready, failed, pending and timed-out | §2.3 outcomes from `initstate` (L4) + readiness predicates (L6); tests 1, 3, 3b, 8, 9, 14 |
| an insmod return is not proof that an async-probed device is ready | `PENDING`; tests 1 (F, async hang), 9 (S, rc 0 but no hwmon → refused), 3 (insmod blocked, device PENDING → refused) |
| a userspace deadline does not cancel an uninterruptible init | L7: no kill (the library's own child is checked alive), `cancel=none`, `insmod=blocked`, late results recorded; tests 3, 3b, 8, 14 |
| bound the overall bootstrap | the S ceiling (an S-readiness failure), per-insmod deadlines, phase budgets, total budget, §2.4 bound; tests 3c, 3, 6, 7, 11 |
| refuse workload handoff if required thermal/essential readiness is absent | `HANDOFF REFUSED` (rc 1) for any S or required E not READY (or READY-BLOCKED uncovered), the S ceiling, an ADSP that does not reach `running`, and an F skip; contract §2.1 item 1; tests 3, 3b, 3c, 3d, 3e, 4, 9, 10, 14 |
| never proceed by silently skipping a required thermal module | S never budget-skipped; every S attempted after earlier S failures/hangs (tests 3, 3b, 4, 14); the S ceiling records the rest `NOT-ATTEMPTED` and refuses, never continues (test 3c); a missing S file is `FAILED` and refuses; a list without its pin refuses |
| H-2 applied/read back before module loading | §2.2 item 2; test 5 (the first insmod saw `0,1,1`; four read-back failures refused with no insmod) |
| H-2 covers the sysfs fallback only | L9; the `FWCFG ok` record says so |

## 3. Not covered (stated limits)

- A child stuck in the kernel stays a process (and a stuck module stays `coming`) for the rest of the
  boot; finished children stay zombies until the shell reaps them. Neither blocks the loader.
- A module that times out in S and becomes ready later (before F's re-check, or before the end) is
  accepted (`READY late=1`): readiness is judged at the end, not at the deadline.
- Design §6.6 item 4 asks for a **QEMU kernel with test modules**, including case (c): a module that
  requests a missing firmware file must not stall with H-2's settings and must stall 60 s without them.
  This harness is qemu-user plus a simulated loader; it checks H-2 only as settings written and read
  back. Case (c) and the real-kernel run of cases (a), (b), (d) remain for that QEMU-kernel test [O].
- Firmware requests made before PID 1 by built-in drivers (A5, O-H3) and direct file I/O stalls (L9).
- Whether every F module tolerates asynchronous probing (O-H9) is a device question. A module that does
  not is moved to E (with its own deadline).
- The kernel model (§6) simulates L1–L6; it is not a kernel. The first on-device run of each adopting
  composition is the real test (a Chair item with that package).
- The runtime `softdep pre:` check covers targets present in `FSML_MD`, so it depends on what the builder
  stages (e.g. `dwc3_msm pre:` names `phy-generic`, `phy-msm-snps-eusb2`, `eud`, which no list stages).
- The DT walk follows phandle supplier properties (§4); modules pulled in only by `modules.dep` are not
  DT-walked (e.g. `tmecom-intf` → its QMP mailbox, needed only for inline-crypto key programming,
  `crypto-qti-hwkm.c:137`).

## 4. The module lists (Quest 3 v2.7)

**Derivation** (`tools/derive-phases.py`, `fixtures/derive/REPORT.txt`). For each profile: the set =
K1a's 95 (`stage3d/modules.load.v66`, sha256 `1b93d77d…463f`) **minus `nautilus.ko`** (dropped from every
later list, H1-F4) plus the profile's additions (TS README §3, including H1-F1–F3). **S** = the closure
of the thermal service's roots: the modules that create what `fs-thermald` reads or writes (PLAN §1.1,
SENSORS.md, EXEC-SPEC E-2). **E** = the closure of the essential roots (USB device controller —
required; display, LED, GPU — best-effort), minus S. **F** = the rest. A closure follows
`modules.dep`, `softdep pre:`, and **DT probe suppliers**: every phandle in a supplier property
(`clocks`, `resets`, `*-supply`, `pinctrl-N`, `interrupt-parent` — also inherited from an ancestor —,
`interrupts-extended`, `pwms`, `interconnects`, `mboxes`, `qcom,qmp`, `qcom,smem-states`, `iommus`,
`io-channels`, `power-domains`, `hwlocks`, `phys`, `usb-phy`, `dmas`, `nvmem`, `nvmem-cells`,
`memory-region`, `qcom,wrapper-core`, `wakeup-parent`, `extcon`, `qcom,bcm-voters`, `*-gpios`) of the
root's DT node and its enabled subtree, recursively, plus the parent bus, mapped to the driving module
by `modules.alias` (names compared with `-`/`_` normalised) or, for 8 compatibles whose modules carry no
alias, by the source file named in the tool. Name lookups that are not phandles are explicit rules
(L11 → `bq27xxx_battery_i2c`, `qti_battery_charger_main`; L12 → `qcom_hwspinlock` for `icc-rpmh`).
`modules.dep` order is a hard constraint; DT supplier order is applied where it does not contradict it
(otherwise that device's probe defers until its supplier loads: the report's NOTEs). The tool fails if a
closure needs a module outside the profile, if a NEVER module (`qcom-spmi-temp-alarm`, PROJECT_SETUP
§6A item 3; `ak09973`, `as5510`, H-Q5; `nautilus`, H1-F4) is in a set, if the k1i set is not exactly the
95 minus `nautilus`, if an S `live` entry is not covered by a root with a device predicate (only
`qrtr-smd` is exempt: its device appears once the ADSP runs), or if a committed list differs from the
derived one. Convention: non-root E modules are tagged `e`; a required root's own predicate catches
their failure.

| profile | for | modules | S | E (required) | e | F |
|---|---|---|---|---|---|---|
| `k1i` | K1i lineage (our kernel, the 95 minus nautilus; no tsens/ADC/ADSP) | 94 | 21 | 1 | 43 | 29 |
| `ts-t1` | TS T1 (+ tsens, ADC; fs-metacfg reads `super`) | 97 | 42 | 1 | 33 | 21 |
| `ts-t2` | TS T2 (+ KGSL, C4a; + `gpucc-anorak`) | 102 | 42 | 1 | 41 | 18 |
| `ts-t3b` | TS T3b onward, and the R-1 base (+ ADSP battery chain + `smp2p`, gauge, virtual sensors) | 113 | 66 | 1 | 28 | 18 |

S roots and their readiness:

| root | readiness | why (the thermal service's need) | profiles |
|---|---|---|---|
| `pwm-tach-fan` | `hwmon:pwmfan` | fan target and tach; cdev `pwm-tach-fan0` (PLAN §1.1, TCD §3.3) | all |
| `qcom-cpufreq-hw` | `cpufreq:policy0,cpufreq:policy2` | CPU caps (TCD §4.1); policy0 = CPUs 0–1, policy2 = CPUs 2–5 | all |
| `qcom-dload-mode` | `bound:1,param:qcom_dload_mode/download_mode` | softdog precondition (EXEC-SPEC E-2): the probe disarms dump mode (L15); the supervisor itself checks that the value reads 0 | all |
| `qcom_tsens` | `bound:2` | SoC zones; two tsens controllers (v27.dts `thermal-sensor@c263000`, `@c265000`) | T1+ |
| `qcom-spmi-adc5-gen3` | `iiochan:pmk8550_die_temp` | `soc-usr`, `pcb*-usr`, `pogo-usr`, `usb-conn` data, PMIC die channels (P7) | T1+ |
| `ufs_qcom` | `bound:1` | fs-metacfg reads `super` (design §2.7: phase S whenever the image reads `super` or `persist`) | T1+ |
| `qcom_q6v5_pas` | `rproc:3000000.remoteproc-adsp` | ADSP battery path (TCD §6.4): probe and registration; then the loader's explicit start must reach `running` (L14, §2.1 item 7, H1-F6) | T3b |
| `qti_battery_charger_main` | `psy:battery` | battery psy (SENSORS BATT); proves the driver, not live data (L14) | T3b |
| `qrtr-smd` | `live` | IPC router to the ADSP; its device appears only after the ADSP start | T3b |
| `bq27xxx_battery_i2c` | `psy:bq27z561-0` | the gauge zone every virtual sensor needs (L11) | T3b |
| `virtual_sensor` | `bound:3` | BATT and SKIN classes: the three `oculus,virtual-sensor` devices bound (their DT zones exist from boot, L11) | T3b |

E roots: `dwc3-msm` **E** `udc:a600000.dwc3` (the development host link); `msm_drm` e
`path:/sys/class/drm/card0`; `leds-qti-tri-led` e `led:red,led:green,led:blue` (its LPG instance needs
the SDAM nvmem, so `nvmem_qcom-spmi-sdam` is now in E, as K1a loaded it before the LED); `msm_kgsl` e
`path:/sys/class/kgsl/kgsl-3d0/max_pwrlevel` (T2+; GPU caps; no GPU workload in TS, so best-effort — a
GPU workload package must make it required). Ten display-path modules of the 95 that the DT walk does not
reach (panel power, backlight, the I2C/SPI/GPI buses they use) are kept with E by an explicit rule.

**Per module** (phase per profile: S, E required, e best-effort, F `async_probe`, – not in the set;
readiness as listed; rationale from the report):

| # | module | k95 | T1 | T2 | T3b | readiness | rationale (per profile where it differs) |
|---|---|---|---|---|---|---|---|
| 1 | `proxy-consumer.ko` | S | S | S | S | `live` | modules.dep of rpmh-regulator.ko |
| 2 | `cmd-db.ko` | S | S | S | S | `live` | modules.dep of qcom_rpmh.ko |
| 3 | `qcom_rpmh.ko` | S | S | S | S | `live` | modules.dep of rpmh-regulator.ko |
| 4 | `rpmh-regulator.ko` | S | S | S | S | `live` | DT vdd-supply of pwm-tach-fan@0 -> rpmh-regulator-bobb1 (qcom,rpmh-vrm-regulator) |
| 5 | `gdsc-regulator.ko` | S | S | S | S | `live` | modules.dep of clk-qcom.ko |
| 6 | `clk-qcom.ko` | S | S | S | S | `live` | modules.dep of gcc-anorak.ko |
| 7 | `clk-rpmh.ko` | S | S | S | S | `live` | DT clocks of qcom,cpufreq-hw -> qcom,rpmhclk (qcom,anorak-rpmh-clk) |
| 8 | `gcc-anorak.ko` | S | S | S | S | `live` | DT clocks of qcom,cpufreq-hw -> clock-controller@100000 (qcom,anorak-gcc) |
| 9 | `panel_event_notifier.ko` | S | S | S | S | `live` | modules.dep of pwm-tach-fan.ko |
| 10 | `qcom-scm.ko` | S | S | S | S | `live` | modules.dep of pinctrl-msm.ko |
| 11 | `qcom-pdc.ko` | S | S | S | S | `live` | softdep pre of pinctrl-msm.ko |
| 12 | `pinctrl-msm.ko` | S | S | S | S | `live` | modules.dep of pinctrl-anorak.ko |
| 13 | `pinctrl-anorak.ko` | S | S | S | S | `live` | DT interrupt-parent of pwm-tach-fan@0 -> pinctrl@f000000 (qcom,anorak-pinctrl) |
| 14 | `regmap-spmi.ko` | S | S | S | S | `live` | modules.dep of qcom-spmi-pmic.ko |
| 15 | `spmi-pmic-arb.ko` | S | S | S | S | `live` | DT parent bus of qcom,pmxr2230@1 (qcom,spmi-pmic-arb) |
| 16 | `qcom-spmi-pmic.ko` | S | S | S | S | `live` | DT parent bus of pinctrl@8800 (qcom,spmi-pmic) |
| 17 | `pinctrl-spmi-gpio.ko` | S | S | S | S | `live` | DT pinctrl-0 of pwm-tach-fan@0 -> pinctrl@8800 (qcom,pmxr2230-gpio) |
| 18 | `pwm-qti-lpg.ko` | S | S | S | S | `live` | DT pwms of pwm-tach-fan@0 -> pwms@eb00 (qcom,pwm-lpg) |
| 19 | `pwm-tach-fan.ko` | S | S | S | S | `hwmon:pwmfan` | ROOT: fan actuator and tach: hwmon pwmfan rpm/pwm/rpm_per_sec/silent_rpm, cdev pwm-tach-fan0 (PLAN §1.1, TCD §3.3) |
| 20 | `qcom-cpufreq-hw.ko` | S | S | S | S | `cpufreq:policy0,cpufreq:policy2` | ROOT: CPU cap actuator: cpufreq policy0/policy2 scaling_max_freq, governor (PLAN §1.1, TCD §4.1) |
| 21 | `qcom-dload-mode.ko` | S | S | S | S | `bound:1,param:qcom_dload_mode/download_mode` | ROOT: softdog precondition (EXEC-SPEC E-2): the probe disables dump mode/SDI (qcom-dload-mode.c:306-340), so the device must be bound; the supervisor itself checks that download_mode reads 0 |
| 22 | `iommu-logger.ko` | e | S | S | S | `auto`, `live` | modules.dep of arm_smmu.ko |
| 23 | `qcom_iommu_util.ko` | e | S | S | S | `auto`, `live` | modules.dep of arm_smmu.ko |
| 24 | `secure_buffer.ko` | e | S | S | S | `auto`, `live` | modules.dep of arm_smmu.ko |
| 25 | `icc-bcm-voter.ko` | e | S | S | S | `auto`, `live` | modules.dep of icc-rpmh.ko |
| 26 | `socinfo.ko` | e | S | S | S | `auto`, `live` | modules.dep of icc-rpmh.ko |
| 27 | `qcom_hwspinlock.ko` | e | S | S | S | `auto`, `live` | by-name lookup in icc-rpmh.ko (socinfo part info via SMEM, which needs its hwlock) |
| 28 | `icc-rpmh.ko` | e | S | S | S | `auto`, `live` | modules.dep of qnoc-anorak.ko |
| 29 | `qnoc-qos.ko` | e | S | S | S | `auto`, `live` | modules.dep of qnoc-anorak.ko |
| 30 | `qnoc-anorak.ko` | e | S | S | S | `auto`, `live` | k1i: DT interconnects of ssusb@a600000 -> interconnect@16e0000 (qcom,anorak-aggre1_noc) · ts-t1: DT interconnects of ufshc@1d84000 -> interconnect@16e0000 (qcom,anorak-aggre1_noc) |
| 31 | `arm_smmu.ko` | e | S | S | S | `auto`, `live` | k1i: DT iommus of dwc3@a600000 -> apps-smmu@15000000 (qcom,qsmmu-v500) · ts-t1: DT iommus of ufshc@1d84000 -> apps-smmu@15000000 (qcom,qsmmu-v500) |
| 32 | `qcom_glink.ko` | e | e | e | S | `auto`, `live` | modules.dep of qcom_glink_smem.ko |
| 33 | `qcom_glink_smem.ko` | e | e | e | S | `auto`, `live` | modules.dep of rproc_qcom_common.ko |
| 34 | `qcom_smd.ko` | e | e | e | S | `auto`, `live` | modules.dep of rproc_qcom_common.ko |
| 35 | `qrtr.ko` | e | e | e | S | `auto`, `live` | softdep pre of qmi_helpers.ko |
| 36 | `qmi_helpers.ko` | e | e | e | S | `auto`, `live` | k1i: modules.dep of pdr_interface.ko · ts-t3b: modules.dep of qcom_sysmon.ko |
| 37 | `rproc_qcom_common.ko` | e | e | e | S | `auto`, `live` | k1i: modules.dep of pdr_interface.ko · ts-t3b: modules.dep of qcom_sysmon.ko |
| 38 | `pdr_interface.ko` | e | e | e | S | `auto`, `live` | modules.dep of pmic_glink.ko |
| 39 | `pmic_glink.ko` | e | e | e | S | `auto`, `live` | k1i: modules.dep of altmode-glink.ko · ts-t3b: modules.dep of qti_battery_charger_main.ko |
| 40 | `gpi.ko` | e | e | e | S | `auto`, `live` | k1i: display path of the 95 (panel power, backlight, display clocks; stage 3c/3d) · ts-t3b: modules.dep of i2c-msm-geni.ko |
| 41 | `i2c-msm-geni.ko` | e | e | e | S | `auto`, `live` | k1i: display path of the 95 (panel power, backlight, display clocks; stage 3c/3d) · ts-t3b: DT parent bus of fuel-gauge@0x55 (qcom,i2c-geni) |
| 42 | `tmecom-intf.ko` | F | S | S | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t1: modules.dep of hwkm.ko |
| 43 | `hwkm.ko` | F | S | S | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t1: modules.dep of crypto-qti-hwkm.ko |
| 44 | `crypto-qti-hwkm.ko` | F | S | S | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t1: modules.dep of crypto-qti-common.ko |
| 45 | `crypto-qti-common.ko` | F | S | S | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t1: modules.dep of ufshcd-crypto-qti.ko |
| 46 | `qcom_aoss.ko` | F | F | e | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t2: DT clocks of qcom,kgsl-3d0@3d00000 -> power-controller@c300000 (qcom,anorak-aoss-qmp) · ts-t3b: modules.dep of qcom_q6v5_pas.ko |
| 47 | `phy-qcom-ufs.ko` | F | S | S | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t1: modules.dep of ufs_qcom.ko |
| 48 | `phy-qcom-ufs-qmp-v4-anarok.ko` | F | S | S | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t1: DT phys of ufshc@1d84000 -> ufsphy_mem@1d87000 (qcom,ufs-phy-qmp-v4-anarok) |
| 49 | `qcom_ipcc.ko` | F | F | e | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t2: DT interrupt-parent of power-controller@c300000 -> qcom,ipcc@ed18000 (qcom,ipcc) · ts-t3b: DT interrupt-parent of qcom,smp2p-adsp -> qcom,ipcc@ed18000 (qcom,ipcc) |
| 50 | `ufshcd-crypto-qti.ko` | F | S | S | S | `auto`, `live` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t1: modules.dep of ufs_qcom.ko |
| 51 | `ufs_qcom.ko` | F | S | S | S | `auto`, `bound:1` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t1: ROOT: fs-metacfg reads Meta's thermal config from super (T1 on; design §2.7: ufs_qcom in phase S whenever the image reads super) |
| 52 | `qcom_tsens.ko` | – | S | S | S | `bound:2` | ROOT: SoC thermal zones (cpu-*, cpuss-*, gpuss-*, nspss-*, ddr): two tsens controllers (SENSORS SOC; v27.dts thermal-sensor@c263000, @c265000) |
| 53 | `qcom-vadc-common.ko` | – | S | S | S | `live` | modules.dep of qcom-spmi-adc5-gen3.ko |
| 54 | `qcom-spmi-adc5-gen3.ko` | – | S | S | S | `iiochan:pmk8550_die_temp` | ROOT: PMIC ADC: soc-usr, pcb/pogo/usb-conn zones and the seven PMIC die channels (P7, J-171) (SENSORS PMIC) |
| 55 | `mdt_loader.ko` | – | – | e | S | `auto`, `live` | ts-t2: modules.dep of msm_kgsl.ko · ts-t3b: modules.dep of qcom_q6v5_pas.ko |
| 56 | `qcom_pil_info.ko` | – | – | – | S | `live` | modules.dep of qcom_q6v5_pas.ko |
| 57 | `qcom_ramdump.ko` | – | – | – | S | `live` | modules.dep of qcom_q6v5_pas.ko |
| 58 | `qcom_sysmon.ko` | – | – | – | S | `live` | modules.dep of qcom_q6v5.ko |
| 59 | `qcom_q6v5.ko` | – | – | – | S | `live` | modules.dep of qcom_q6v5_pas.ko |
| 60 | `smp2p.ko` | – | – | – | S | `live` | DT interrupts-extended of remoteproc-adsp@03000000 -> qcom,smp2p-adsp (qcom,smp2p) |
| 61 | `qcom_q6v5_pas.ko` | – | – | – | S | `rproc:3000000.remoteproc-adsp` | ROOT: ADSP: battery and charger path via pmic_glink (TCD §6.4; EXEC-SPEC v2.7 ADSP name). auto_boot is false for this SoC (qcom_q6v5_pas.c:967-979): the list proves probe and registration; the loader's explicit start (FSML_RPROC_START, required for T3b/R-1) must reach running within FSML_RPROC_WAIT, else S is not ready and the handoff is refused |
| 62 | `qti_battery_charger_main.ko` | – | – | – | S | `psy:battery` | ROOT: battery psy: temp/voltage/current/capacity/status, usb online (PLAN §1.1, SENSORS BATT); registered at probe whether or not the ADSP runs (qti_battery_charger.c:3336), so it proves the driver, not live battery data |
| 63 | `qrtr-smd.ko` | – | – | – | S | `live` | ROOT: IPC router transport to the ADSP (TS README §3 T3b); its rpmsg device appears only once the ADSP runs, so live is all the loader can prove (LIVE_ONLY_ROOTS) |
| 64 | `bq27xxx_battery.ko` | – | – | – | S | `live` | modules.dep of bq27xxx_battery_i2c.ko |
| 65 | `bq27xxx_battery_i2c.ko` | – | – | – | S | `psy:bq27z561-0` | ROOT: battery gauge: zone bq27z561-0 is an input of all three virtual sensors (v27.dts battery/display/surface_virtual_sensor thermal-zones) |
| 66 | `virtual_sensor.ko` | – | – | – | S | `bound:3` | ROOT: BATT and SKIN classes: batt-virt-usr, surf-virt-usr (SENSORS). The DT zones exist from boot (thermal_of.c:1171-1220), so readiness is the three bound oculus,virtual-sensor devices; each probe defers until the power-supply zones bq27z561-0 and battery exist (virtual_sensor.c:1035-1048, 915-985, 1198-1202) |
| 67 | `dwc3-msm.ko` | E | E | E | E | `udc:a600000.dwc3` | ROOT: USB-C data: the development host link (the ACM gadget binds a600000.dwc3; row 16: E in development images) |
| 68 | `dispcc0-anorak.ko` | e | e | e | e | `auto` | DT clocks of qcom,mdss_mdp@ae00000 -> clock-controller@af00000 (qcom,anorak-dispcc0) |
| 69 | `dispcc1-anorak.ko` | e | e | e | e | `auto` | display path of the 95 (panel power, backlight, display clocks; stage 3c/3d) |
| 70 | `phy-msm-snps-hs.ko` | e | e | e | e | `auto` | softdep pre of dwc3-msm.ko |
| 71 | `phy-msm-ssusb-qmp.ko` | e | e | e | e | `auto` | softdep pre of dwc3-msm.ko |
| 72 | `gh_msgq.ko` | e | e | e | e | `auto` | modules.dep of gh_rm_drv.ko |
| 73 | `gh_rm_drv.ko` | e | e | e | e | `auto` | modules.dep of mem_buf_dev.ko |
| 74 | `llcc-qcom.ko` | e | e | e | e | `auto` | modules.dep of msm_drm.ko |
| 75 | `mem_buf_dev.ko` | e | e | e | e | `auto` | modules.dep of qseecom-mod.ko |
| 76 | `msm_dma_iommu_mapping.ko` | e | e | e | e | `auto` | modules.dep of msm_drm.ko |
| 77 | `nvmem_qcom-spmi-sdam.ko` | e | e | e | e | `auto` | DT nvmem of pwms@e800 -> sdam@8400 (qcom,spmi-sdam) |
| 78 | `qti-fixed-regulator.ko` | e | e | e | e | `auto` | display path of the 95 (panel power, backlight, display clocks; stage 3c/3d) |
| 79 | `altmode-glink.ko` | e | e | e | e | `auto` | modules.dep of msm_drm.ko |
| 80 | `blu_fw_driver.ko` | e | e | e | e | `auto` | display path of the 95 (panel power, backlight, display clocks; stage 3c/3d) |
| 81 | `qseecom-mod.ko` | e | e | e | e | `auto` | modules.dep of smcinvoke_mod.ko |
| 82 | `smcinvoke_mod.ko` | e | e | e | e | `auto` | modules.dep of hdcp.ko |
| 83 | `hdcp.ko` | e | e | e | e | `auto` | modules.dep of msm_drm.ko |
| 84 | `leds-qti-tri-led.ko` | e | e | e | e | `led:red,led:green,led:blue` | ROOT: status LED: the thermal LED notice consumer and the stage LEDs (row 22; fs-noticed) |
| 85 | `mp3314.ko` | e | e | e | e | `auto` | display path of the 95 (panel power, backlight, display clocks; stage 3c/3d) |
| 86 | `msm-mmrm.ko` | e | e | e | e | `auto` | modules.dep of msm_drm.ko |
| 87 | `msm_ext_display.ko` | e | e | e | e | `auto` | modules.dep of msm_drm.ko |
| 88 | `msm_drm.ko` | e | e | e | e | `path:/sys/class/drm/card0` | ROOT: display (row 7) and the static KMS warning frame consumer (PLAN §1.1 notice consumers) |
| 89 | `spi-msm-geni.ko` | e | e | e | e | `auto` | display path of the 95 (panel power, backlight, display clocks; stage 3c/3d) |
| 90 | `tps65132-regulator.ko` | e | e | e | e | `auto` | display path of the 95 (panel power, backlight, display clocks; stage 3c/3d) |
| 91 | `msm_qmp.ko` | F | F | e | e | `auto` | k1i: in the set; not needed by any S or E root (loaded with async_probe=1) · ts-t2: DT mboxes of qcom,gmu@3d69000 -> qcom,qmp-aop (qcom,qmp-mbox) |
| 92 | `log_gpu_error.ko` | – | – | e | e | `auto` | modules.dep of msm_kgsl.ko |
| 93 | `nvmem_qfprom.ko` | – | – | e | e | `auto` | softdep pre of msm_kgsl.ko |
| 94 | `gpucc-anorak.ko` | – | – | e | e | `auto` | DT clocks of qcom,kgsl-3d0@3d00000 -> clock-controller@3d90000 (qcom,anorak-gpucc) |
| 95 | `msm_kgsl.ko` | – | – | e | e | `path:/sys/class/kgsl/kgsl-3d0/max_pwrlevel` | ROOT: GPU cap actuator (PLAN §1.1: absent -> GPU caps skipped and logged; no GPU workload in TS, so best-effort) |
| 96 | `clk-dummy.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 97 | `dcvs_fp.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 98 | `kryo_arm64_edac.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 99 | `qcom_dma_heaps.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 100 | `mem_buf.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 101 | `mem-hooks.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 102 | `qcom-dcvs.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 103 | `qcom_cpu_vendor_hooks.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 104 | `qcom_llcc_pmu.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 105 | `qcom-reboot-reason.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 106 | `qcom_wdt_core.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 107 | `rtc-pm8xxx.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 108 | `ucsi_glink.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 109 | `zsmalloc.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 110 | `zram.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 111 | `pm8941-pwrkey.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 112 | `reboot-mode.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |
| 113 | `qcom-pon.ko` | F | F | F | F | `auto` | in the set; not needed by any S or E root (loaded with async_probe=1) |

## 5. Findings and decisions

| # | finding | evidence | status |
|---|---|---|---|
| H1-F1 | **`smp2p` was missing from the TS T3b closure.** The ADSP node takes its `stop` smem-state and interrupts from `qcom,smp2p-adsp` (`smp2p.ko`, interrupt parent `qcom_ipcc`): without it `qcom_q6v5_pas` defers and the ADSP never registers | v27.dts `remoteproc-adsp@03000000` `interrupts-extended`, `qcom,smem-states`; `CONFIG_QCOM_SMP2P=m` | **Arbiter: accepted** as a technical correction; in `ts-t3b` (and the R-1 base); TS README §3 row and note |
| H1-F2 | **The bq27 gauge was missing from the TS T3b closure.** All three virtual sensors defer until the power-supply zone `bq27z561-0` exists (L11): without `bq27xxx_battery_i2c` (+ `bq27xxx_battery`, `i2c-msm-geni`, `gpi`) `batt-virt-usr` and `surf-virt-usr` never get a sensor, so BATT/SKIN read nothing at T3b | L11; v27.dts `i2c@980000/fuel-gauge@0x55`; vendor_dlkm `modules.dep` | **Arbiter: accepted**; in `ts-t3b`; TS README §3 |
| H1-F3 | **`gpucc-anorak` was missing from the TS T2 closure.** KGSL and the GMU take their clocks from `qcom,anorak-gpucc`: without it `msm_kgsl` defers and the GPU caps are absent at T2 | v27.dts `qcom,kgsl-3d0@3d00000`, `qcom,gmu@3d69000` `clocks` | **Arbiter: accepted**; in `ts-t2`/`ts-t3b`; TS README §3 |
| H1-F4 | **`nautilus.ko` (the depth-projector driver) is entry 1 of K1a's 95** and has probed on every stage image since 3d (DT node `status = "ok"`, clock, pinctrl, `vdd-supply`); design §2.1 said it was in no FrameShift list | `stage3d/modules.load.v66` line 1; v27.dts `/vendor/oculus,nautilus` | **Arbiter decision:** dropped from every later list (k1i, TS, R-1) and in NEVER; it returns only in a reviewed tracking package with the IR-emitter safety ownership; K1a and stage 3d unchanged; design §2.1 corrected on master (`1703ed2`); disclosed in FS-A-014. **FS-R-014 §8 (2026-10-18):** by source, probe does not call the explicit regulator/clock enable routine (it runs only on a write to the `enable` attribute, or on resume if enabled before suspend) [M-static]; projector darkness was **not measured** and inherited hardware state is not excluded [O]; no further K1a boot is required and the unchanged closure is not blocked |
| H1-F5 | Phase S changes the load order relative to K1a (S first; then E; F with `async_probe`). K1a's order is the one measured on hardware [M]; the new order is [D] only; the report's NOTEs list the DT suppliers that load after a consumer instance | `REPORT.txt` | the first adopting composition is checked on hardware (boot record: every OUTCOME, no PENDING in S/E) before anything relies on it |
| H1-F6 | **The ADSP does not start by itself** (L14). Without an explicit start, `running` never holds | `qcom_q6v5_pas.c:967-979` | **Arbiter decision (requirement):** T3b and R-1 start the ADSP explicitly (`adsp.mdt` on the firmware path), wait for `running` with a bounded wait, and treat an absent `running` as an S-readiness failure (handoff refused). Implemented as `FSML_RPROC_START`/`FSML_RPROC_WAIT` (§2.2 item 5; tests 3e); the list proves registration (`rproc:3000000.remoteproc-adsp`). The audio `adsp_loader_dlkm` chain is not pulled in. Disclosed to the Chair by the Arbiter |
| H1-F7 | Two policy points from review A': (a) a ceiling on phase S; (b) a module whose device is ready while its `insmod` is still blocked | review A' findings 1, 3 | **Arbiter decisions:** (a) phase S has a ceiling `FSML_S_MAX`; reaching it never skips a module and continues — it is an S-readiness failure: the rest are `NOT-ATTEMPTED`, E/F are not loaded, the handoff is refused, the image takes its safe path; the ceiling does not cancel a blocked init (FS-R-013 §10) (tests 3c). (b) such a module is `READY-BLOCKED`, distinct from READY, acceptable for the handoff only if a device-readiness check covers its function; recorded as a `FINDING` and reported by the classifier (tests 3, 3d). Disclosed to the Chair by the Arbiter |

## 6. Tests (`tools/test-modload.sh`, results in `fixtures/test/RESULTS.txt`)

The library runs in the **reviewed stage-1 busybox** (`c2f279d1…ec02`, aarch64) under qemu-user, on
a simulated `/sys` and `/proc`; `tools/kmodel-insmod.sh` stands in for the module loader and models
L1–L6 in the kernel's order (`coming` during init; `live` set **before** the `async_synchronize_full`
wait of a plain load; async/sync/forced-sync probes; bind/defer/fail; `resolve_symbol_wait`; driver
links). Required cases:

| brief item | cases |
|---|---|
| a hung async probe followed by an S module | 1 (F hang after the S modules: S READY, F `PENDING`, nothing blocked, handoff OK) + **2 negative control: K1a's own loader functions, extracted read-only from the pinned `k1a/init.sh`, stall on the plain `insmod` blocked behind the same hung probe and never reach the S module** (K1a has no per-insmod deadline and waits for each `insmod`'s return); 3 (the hang inside phase S: every S still attempted; each plain insmod recorded `LIVE insmod=blocked`; the hung device `PENDING`, the next S device `READY-BLOCKED` with a FINDING; refused with F skipped; the library's own children still running); 3b (an S init that never returns: `TIMED-OUT initstate=coming cancel=none`, the next S module still loaded); 11 (async hang and hung inits in the PM's offline backup drive E budget ends E, F unaffected) |
| a missing S module | 4 (`FAILED reason=file-missing`, other S READY, no S window waited, refused naming the F skip) |
| firmware-setting read-back failure | 5: positive (the first insmod saw `0,1,1`) and four refusals (read-only `force_sysfs_fallback`, read-only `timeout`, missing `ignore_sysfs_fallback`, missing `timeout`): rc 2, no insmod, no `/sys/module` |
| budget exhaustion in F | 6 (rest of F `SKIPPED budget-f` within the budget; S untouched and READY; handoff OK); 7 (total budget: S exempt, E/F `budget-total`) |

Arbiter decisions (H1-F6, H1-F7): 3c (**S ceiling**: the in-flight S module times out at the ceiling,
not cancelled; the rest `NOT-ATTEMPTED` and never loaded; E/F not loaded; refused with
`S:ceiling:REACHED`; bounded by the ceiling), 3d (**READY-BLOCKED**: a required E device ready behind a
hung async probe → `READY-BLOCKED`, `FINDING covered=own-check`, handoff OK listing it; with only an
`auto` check → `covered=no`, refused), 3e (**ADSP start**: `start` written, `running` within the wait →
OK; stays `offline` → S-readiness failure, F skipped, refused; not registered → refused).

Also: 8 (late S: timeout then READY `late=1 late_rc=0`), 9 (rc 0 but not ready → refused), 10 (required
E failure refuses; best-effort does not), 12 (list/index/option refusals before any insmod: 14 list
cases including the list pin, a predicate with an empty atom and an `auto` atom on S, a last line
without a newline that is still loaded, plus the index pin, missing pins, malformed / octal budgets, a
zero poll and an unwritable run directory), 13 (the latch), 14 (a dependency still `coming`: the late
failure is `FAILED late=1 late_rc=1`), 14b (S ready after its window but before F: re-checked, F
loaded), 14c (a module already live: `note=already-live`, READY), 14d (the caller's `set -eu` and
`IFS=,`: run OK, both restored), 15 (**the four real lists** against the pinned v2.7 indexes: the
runtime pin/closure/order checks pass, insmod order = list order, `async_probe=1` exactly on F). In case
15 the harness creates exactly the sysfs nodes each predicate checks, so its "all READY" is by
construction; only the order, closure and parameter checks carry evidence there. Case 15 needs the local
index (`FS_H1_INDEX`), which is not committed.

Reproduce (WSL): `FS_H1_INDEX="<vendor_boot lib/modules> <vendor_dlkm lib/modules> <odm_dlkm lib/modules>"
bash devices/quest3/h1/tools/test-modload.sh devices/quest3/h1/fixtures/test/RESULTS.txt`, and
`python3 devices/quest3/h1/tools/derive-phases.py --dts v27.dts --index <vb> --index <vd> --index <od>
--base95 devices/quest3/stage3d/modules.load.v66 --check devices/quest3/h1/lists --report
devices/quest3/h1/fixtures/derive/REPORT.txt`.

## 7. Open items

- O-H9 (design): asynchronous-probe tolerance of every F module — on the first adopting composition.
- **For the K1i package:** the QEMU-kernel loader test of design §6.6 item 4 (real kernel, test
  modules), including the missing-firmware stall case (c) with its 60 s negative control (§3).
- `DL_S`/`READY_S` per image from K1a's measured load times; the R-1 image's total bound against its
  own boot budget.
- `FSML_S_MAX`, `FSML_RPROC_WAIT` per image from measured times (K1a load times; the ADSP boot time at
  T3b).
- The readiness names (`bq27z561-0`, `3000000.remoteproc-adsp`, `pmk8550_die_temp`, the LED names) are
  [M-static] from source and DT; the T0 capture and the T1 boot record confirm them [O].

## 8. Internal adversarial review

Two read-only reviewers per the adversarial-review rule: **A** (target semantics and test validity) and
**B** (derivation, lists and facts). The first pair ran on `d905d34`; both ran again on `e765c19` (A', B').
All findings were applied in this revision unless marked otherwise.

**Verdicts before fixes:** A on `d905d34` **NO-GO** (it becomes GO once its findings 1–3 are fixed); A' on
`e765c19` **GO-with-fixes**; B on `d905d34` and B' on `e765c19` **NO-GO** for `ts-t3b` (ADSP never
starts; virtual-sensor check vacuous), **GO-with-fixes** for the other lists.

| finding (reviewer, severity) | change |
|---|---|
| L4 wrong: `live` is set before the async wait; kmodel modelled the opposite; tests 3/11 asserted kernel-impossible states (A BLOCKER, A' MAJOR) | L4 corrected; kmodel writes `live` before the wait; the wait ends 1 s after `live` (`result=LIVE insmod=blocked`); `late=1` only when an rc file appeared; tests 3, 3b, 11, 14 rebuilt on the corrected model |
| ADSP `auto_boot=false`: `running` can never hold (B BLOCKER) | L14; the list proves registration; the loader starts the ADSP explicitly and requires `running` (H1-F6, Arbiter decision; contract item 7; tests 3e) |
| `virtual_sensor` `tz:` check true from boot (B MAJOR) | L11 corrected; readiness `bound:3`; H1-F2 reworded |
| LED's SDAM nvmem supplier missed (`nvmem` property; `file_of` on mixed `_`/`-` names) (B MAJOR) | `nvmem` handled; names normalised; SDAM now E in every profile |
| `qcom-dload-mode` check met without the probe (B MAJOR/MINOR) | L15; readiness `bound:1,param:…` |
| last list line without a newline silently dropped (A MAJOR) | read loop fixed; shell/awk entry counts compared; list pinned by `FSML_LIST_SHA` (A' MINOR) |
| F skipped on an early S judgement while the verdict said OK (A MAJOR, A' MAJOR) | S re-checked before F; any `s-not-ready` skip refuses |
| S has no ceiling (A' MAJOR) | `FSML_S_MAX` ceiling, default 90 s (Arbiter decision H1-F7a): reaching it is an S-readiness failure: the S modules not yet reached are `NOT-ATTEMPTED` (never skipped-and-continued), E and F are not loaded, the handoff is refused (`S:ceiling:REACHED`) and the image takes its safe path; the ceiling does not cancel a blocked init (FS-R-013 §10); L4 handling also removes the async-hang cascade; test 3c |
| stale rc files (A MINOR) | removed at start and before each fork; run dir checked |
| rc ≠ 0 on an already-live module (EEXIST) refused falsely; late non-zero rc was TIMED-OUT (A MINOR, A' MINOR/NIT) | `note=already-live` judged by readiness; late non-zero rc → `FAILED late=1` |
| `auto` atom on S and empty atoms accepted (A MINOR, A' MINOR) | rejected |
| caller `set -e`/`set -u`/`IFS` break the run (A MINOR, A' MINOR) | neutralised and restored; `${4:-}`; `fsml_min` returns 0; test 14d |
| leading-zero budgets read as octal (A' MINOR) | rejected; poll and options validated |
| unwritable `FSML_RUN`/`FSML_LOG` undetected (A' MINOR) | checked before H-2 (rc 2) |
| knobs inherited from the kernel command line (A' MINOR) | test-only knobs need `FSML_TEST=1`; every effective value in `START`; contract item 3 |
| "children not killed" assertion vacuous (A' MINOR) | the library records `child=`; the test checks that PID |
| plain loads after the handoff (A' MINOR) | contract item 6 |
| firmware-stall case (c) and QEMU-kernel test not covered; case-15 readiness by construction; softdep check depends on staging (A, A') | stated in §3 and §6; open item |
| K1a negative control proves "no deadline", not A1 alone (A MINOR) | claim narrowed in §6 |
| supplier properties missing (`resets`, `usb-phy`, `qcom,wrapper-core`, `wakeup-parent`, `extcon`, `qcom,bcm-voters`, inherited `interrupt-parent`) (B MINOR) | added; dep-only limitation stated (§3) |
| SMEM/socinfo later than in K1a (B MINOR) | `icc-rpmh` → `qcom_hwspinlock` by-name rule (L12); hwspinlock follows icc into S/E |
| fan binds without its supply if fw_devlink is off (B MINOR) | L10; contract item 8 |
| softdep keys not normalised; unquoted `cat`/`echo`; `tr` newline; re-entrancy; log truncation (A, A' NITs) | fixed (normalised keys, quoted loops, printf, per-module state reset, log appended) |
| dead `COMPAT_MAP` entry; report without `CHECK` lines; test-12 count; phase-span assertions treating a missing line as 0 (B, A NITs) | entry removed (8); report regenerated with `--check`; counts corrected; `span` returns `none` when a line is missing |
| E dependencies tagged `e` under a required root (B NIT) | convention stated in §4 |

**Re-run after the fixes:** `test-modload.sh` **69/69** (`fixtures/test/RESULTS.txt`, with the four real lists against the pinned v2.7 indexes); `derive-phases.py --check` **PASS, 0 errors** (`fixtures/derive/REPORT.txt`). Phase-span assertions allow the budget plus 0.5 s (one poll and the record overhead under qemu-user).

**Arbiter decisions after the review (H1-F6, H1-F7), applied:** the explicit ADSP start with a bounded
wait for `running` (absence = S-readiness failure); the S ceiling `FSML_S_MAX` (an S-readiness failure,
never a skip, does not cancel a blocked init); `READY-BLOCKED` distinct from READY, acceptable only when
a device-readiness check covers it, recorded as a `FINDING`. Tests 3c, 3d, 3e added and test 3 updated.
**Final run:** `test-modload.sh` **77/77**; `derive-phases.py --check` **PASS, 0 errors**.
