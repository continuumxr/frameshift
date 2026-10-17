# Quest 3 stage 3b: trial (iii-b), the revised display test

**Status (2026-10-11): built and fixture-tested offline; CONCURRED TO EXECUTE
by FS-R-011 §1 (J-104); NOT yet run on any device.** FS-R-010 concurred with
*preparing* trial (iii-b) under its §4–§6 decisions; this package was the
promised pre-trial return (§9), reviewed in FS-R-011. The concurrence is for
exactly this image (SHA-256 `ea60d6cd…5841`, nonce `<attempt nonce withheld>`) on
Unit 1 (v66, slot A): one temporary boot, no flash, no retry,
DEADLINE 200 s / backstop 201 s, the 91 s runner guard, the PM physically
present with the attended sign-off (`devices/quest3/SIGNOFF.md`, trial
(iii-b), including FS-R-011 clarifications A (host pins `fs-proto.ps1`,
`host/fs-native.ps1`, `common/host/fsb1.ps1`) and B ("dark gap" read as a
pause of at least 2 s, darkness observed separately; run 2 only if its
inactive-CRTC precondition is established)). The six implementation choices
in §6 were accepted (FS-R-011 §3). No other backlight interface, extra commit
after refusal or improvised recovery command is covered. Stage 3a (`../stage3a/`) is spent and
unchanged: its image, builder, binary and pins still reproduce the trial-(iii)
evidence.

Tags: [M] hardware output · [M-static] artifact · [D] derivation · [C]
hypothesis · [O] open. Fixture runs are [D] evidence (qemu-user, bwrap, WSL), not [M].

**The image:** `IMAGE.md` (identity, contents, timing, outcomes, fixtures).
**Outcomes:** `../common/OUTCOMES.md` §9. **Recovery:** `../RECOVERY.md`.

## 1. What trial (iii-b) does (FS-R-010 §4)

One temporary `fastboot boot` of a new image, with a fresh nonce, on Unit 1. After
the usual stage-1 bring-up, the host runs `fs-display <chal>` once:

1. **probe1** (read-only snapshot "mods"), then **the one new write**:
   `/sys/class/backlight/panel0-backlight/brightness` = `127`, read back, then
   snapshot "pre1". Run 1 starts only if the read-back is `127`.
2. **Run 1**: `fs-pattern show <chal[0:8]> 3`, synchronous (fs-display waits on its
   supervisor's PID). It takes over the splash pipeline exactly as trial (iii) did
   (same mode policy, same TEST_ONLY order and layouts), holds the **bright**
   pattern for **3 s**, then closes the fd (on v66 a close after our commit is a
   full panel off [D, near-match source]). probe1 takes "mid1" during the hold and
   "post1" after the close.
3. **The gate**: run 2 runs only if run 1 had the **accepted commit and a clean
   close** (supervisor `end=exited code=0`, `commit rc=0`, `hold_end rc=0
   reason=deadline close_rc=0`, `exit … shown=1`, `eos … dropped=0`).
4. **A pause of at least 2 s**, then **probe2** reads the brightness back (no
   write) and takes "pre2". Run 2 starts only if the gate holds and the read-back
   is `127`.
5. **Run 2**: `fs-pattern show-off <chal[0:8]> 10`. It commits **only from a
   provably inactive CRTC** (GETCRTC ok, ACTIVE property found, ACTIVE = 0), so the
   driver takes its normal, non-splash screen-on path (supplies, reset, pre-on,
   sleep-out, display-on, backlight) [D]. If the CRTC is still active, it records
   `precondition rc=-16` and exits 31 with **no commit**: "precondition unmet: CRTC
   active", no off→on claim. Otherwise it holds the bright pattern for **10 s**,
   then closes. probe2 takes "mid2" and "post2".
6. One FSB1 record (`exp=stage3b`, 5 steps), emitted **paced** (20 lines per 0.1 s,
   byte-identical to the unpaced emission), then the host's beeps, the 10 s
   read-only dark check, `fs-done`, and the PID 1 reboot.

A run the runner does not start is still a step (`FSK1 run=<n> skipped
reason=<why> END`), so the step list never changes. The integrity hash
(`sha256sum /bin/fs-pattern`) runs concurrently from the start of `fs-display`; no
run waits for it. A run starts only after its "pre" snapshot has **finished**
(`pre1.done`/`pre2.done`), so no probe snapshot is running at a commit.

## 2. Files

| path | what |
|---|---|
| `src/fs-pattern.c` | fs-pattern **v0.5** (one file, no libdrm). With `-DFSP_UNIT_TEST`: unit tests, a `stream` sample, and `propsim` (the property logging against a mock DRM model) |
| `tools/build.sh` | WSL build of the tool and the unit-test binary (static-ELF checks, bit-identical rebuild) → `build/BUILD.txt` (= `BUILD-RECORD.txt`) |
| `tools/fixtures.sh` | the v0.4 fixtures, kept, plus the v0.5 ones → `fixtures/RESULTS.txt` |
| `tools/check_render.py` | independent render checker for the bright pattern (decodes the nonce from the pixels, checks levels and marks) |
| `tools/preview.py` | stdlib Python port of the drawing code, validated **byte for byte** against the C render, writes the PNG previews |
| `tools/check_propsim.py` | decodes the propsim stream and re-derives every logged name/value/blob from the mock's stated rules |
| `tools/check_stream.py` | the FSP1 validator (a copy of stage 3a's, unchanged) |
| `init.sh` | PID 1 (stage 3a's init: DEADLINE 200, the fork-free irq sample after MODULES_READY, product string) |
| `fs-display.sh` | the runner (§1; timing constants TW1/TW2/TQ/PAUSE/MAXLINES at its top) |
| `fs-probe.sh` | the probe helper and the one backlight write (§4) |
| `../common/target/fsb1-pace.sh` | the paced emitter (new; `fsb1-enc.sh` is unchanged) |
| `build-image.sh`, `test-builder.sh`, `test-image.sh` | builder, its negative and reproducibility fixtures, the whole-image harness driver |
| `tools/image-harness-3b.py` | the whole-image harness (derived from `stage2a/tools/image-harness.py`, which is unchanged) |
| `tools/pace_evidence.py` | the paced-emission evidence (FS-R-010 §5) → `fixtures/pace/` |
| `tools/check-timing-3b.py` | the stage-3b timing and clock-model check (`stage2a/tools/check-timing.py` unchanged) |
| `tools/dmesg-timing.sh` | the probe's kernel-log filter timed on a synthetic 1 MB log under qemu (the TW1/TQ margins) → `fixtures/dmesg-timing.txt` |
| `../host/fs-classify3b.ps1`, `../host/test-host3b.ps1` | the §9 classifier and the stage-3b host suite |

## 3. fs-pattern v0.5 (changes from v0.4; everything else is v0.4)

```
fs-pattern show     NONCE HOLD_S [DEVICE]    # run 1 (trial (iii-b): HOLD_S 3)
fs-pattern show-off NONCE HOLD_S [DEVICE]    # run 2 (HOLD_S 10): commits only from an inactive CRTC
fs-pattern render   NONCE W H OUT.ppm        # offline
fs-pattern holdtest NONCE HOLD_S MOCKPATH    # offline
```

1. **The bright pattern** (FS-R-010 §4): a **mid-grey field 0x80**; the frame,
   the cross, the corner square, the 8 characters, their underline and the link
   bars in **white 0xFF**. Geometry unchanged since v0.1 (per eye 2064 × 2208,
   rotated 180° inside each half; 1 bar on the DSI-0 half, 2 on the DSI-1 half).
   White covers 3.76 % of the pixels; the mean level is 132.8/255 (`4e0addd8`).
2. **Hold argument**: run 1 is called with 3, run 2 with 10. The compiled maximum
   stays 10 s; the alarm is HOLD_S + 5 from the commit, the setup alarm 30 s, and
   the fd is closed as soon as the hold ends, as in v0.4 (the client's own
   alarm/close structure is unchanged; `hold()` is textually identical).
3. **`show-off`**: after the `crtc_state` record, `show-off` requires the CRTC to
   be provably inactive; otherwise `precondition rc=-16` and **exit 31**, no
   buffer, no TEST_ONLY, no commit. With an inactive CRTC the v0.4 mode policy
   picks the expected 4128×2208@90 mode and the v0.4 plan gives the modeset
   attempts (single, then split): the same order and layouts as trial (iii)'s
   attempts 2 and 3. A `precondition rc=0` record proves the inactive state.
   What the driver does with an active CRTC when this run closes its fd after
   exit 31 is not claimed here; if anything is still lit, the retained-frame
   disclosure (§5) applies.
4. **Read-only property logging at start** (GET ioctls only:
   `OBJ_GETPROPERTIES`, `GETPROPERTY`, and the one new ioctl `GETPROPBLOB`):
   - `conn_topology` (essential, always): the connector's `topology_name` enum
     value and name, the **values** of `topology_control` and `dsc_mode`, and the
     `mode_properties` blob id;
   - `blob what=mode_properties` (the blob, %XX-encoded, 240 bytes per record);
   - `show` only: `plane_caps` for **every plane** (its `capabilities` blob and
     the parsed `max_linewidth`), the primary plane's capabilities blob, and the
     full property name/type list (`prop_list`, once per kind) and value list
     (`prop_vals`) of the connector, the CRTC and every plane;
   - these records are **optional**: together at most `FSP_OPT_MAX` = 20480
     bytes; the first that does not fit becomes one `opt_budget` record (same
     seq) and the rest are skipped; `eos` reports `opt_bytes`/`opt_skipped`.
     Nothing is cut silently and the seq stays gap-free.
5. **Never set `topology_control` or `dsc_mode`**: the atomic request builder,
   `a_plane`, `a_plane_off` and every `a_prop` call site are identical to v0.4
   (static fixture `static-no-new-set`); in the device build the two names occur
   only in two `pinfo_find` lookups (`static-topology-dsc-read-only`).
6. `eos` gains `opt_bytes` and `opt_skipped`; `start` reports `mode=show-off` and
   `ver=0.5`. The FSP1 format (len/crc framing, grammar) is unchanged; all new
   records are new step ids.

Exit codes: v0.4's table plus **31** = show-off precondition unmet (no commit).

**Build** (v0.5, 2026-10-10; `BUILD-RECORD.txt`):
- `src/fs-pattern.c` `fc2c4d52fd9c55aa88156dc7717647d542b43191d4c630b4c7c84394897b408a`
- `build/fs-pattern` **`4c36e4d97b7a04b0e8695c3731a7f679b3034598d50e3b52f523b19b4c6b02a6`** (643,432 B, static aarch64, stripped, bit-identical rebuild)
- `build/fs-pattern-unittest` `4db6d1c03f624f53da1f466527ff04f0cf03ba4e92450e41f1108740c9368bc6` (offline only)
- toolchain, headers and `libc.a`: as v0.4 (`clang-r450784e`, v2.7 uapi, `76a89dad…`)

**Previews** (`docs/research/pattern-preview/`, new files; the Python port is
byte-identical to the C render for all four nonces tested):

| file | what | sha256 |
|---|---|---|
| `bright-v0.5-3f9c07ab-viewer-1032x552.png` | what each eye should see (rotation undone), 1/4 scale, true levels | `99a21ab2…aaa0` |
| `bright-v0.5-3f9c07ab-scanout-4128x2208.png` | the exact buffer as scanned out | `c729bf5e…8d92` |
| `bright-v0.5-3f9c07ab-digits-left.png` | the left-half characters at 1:1 | `a86699ca…d18d` |
| `bright-v0.5-01234567-digits-left.png`, `bright-v0.5-89abcdef-digits-left.png` | every glyph at 1:1 | `c6d227ec…6218`, `753c7804…79c6` |

The characters on the panels are the first 8 hex digits of the attempt's
challenge (fresh per attempt); `3f9c07ab` is a sample. The PM sees the preview
before the attempt (FS-R-010 §4).

## 4. Probes and the one write (FS-R-010 §4; `fs-probe.sh`)

**Points.** "irq0" (init, right after MODULES_READY: the TE/BLU-PWM lines of
`/proc/interrupts`, read fork-free into RAM); "mods" (the first probe of the
runner: after modules, before any write); "pre1" (after the write, right before
run 1 starts); "mid1" (1.5 s into run 1, with a second interrupt sample 0.5 s
later); "post1" (after run 1's close); "pre2"; "mid2" (5 s into run 2, with the
second sample); "post2". A mid snapshot is skipped if the run has already ended.
The kernel log is read at mods, mid and post only, **not** at pre1/pre2 (nothing
slow runs right before a commit; mods and post cover the log).

**Nodes read** (read-only; sysfs and /proc only; `/dev/dri/card0` is never opened
by a probe and debugfs is never mounted):

| node | why |
|---|---|
| `/proc/uptime` | timestamps |
| `/proc/interrupts`: the `te-edge-isr` and `blu-pwm-isr` lines | the lit/dark signature (Android lit: both advance about 182/s; asleep: static) [M, stock-display capture] |
| `/proc/cmdline` (once, "mods") | ABL's `msm_drm.dsi_display0=` string |
| the kernel log (`busybox dmesg`, never `-c`), filtered `dsi\|sde\|drm\|blu\|splash\|panel\|backlight\|bl_\|WARN` (case-insensitive) | panel and DSI messages |
| `/sys/class/drm/card0-*/{status,enabled,dpms}` (at most 8 entries) | connector state |
| `/sys/class/drm/card0-sde-crtc-0/{backlight_timing,backlight_event,active_event,measured_fps,vsync_timing}` | BLU timing and CRTC events [M names, stock capture] |
| `/sys/class/backlight/panel0-backlight/{brightness,actual_brightness,bl_power}` | the brightness setting (weak evidence: `actual_brightness` reads 0 even when lit [M]) |
| `/sys/class/hwmon/hwmon*/name` (at most 16); for `pwmfan`: `rpm`, `pwm` | the fan, read-only |
| `/sys/class/thermal/cooling_device*/type` (at most 32); for `pwm-tach-fan0`: `cur_state` | the fan's cooling device, read-only |
| `/run/fs.irq0` | init's sample |

**The one write** (exactly once, by probe1, before run 1; the normal backlight
class node, not a forbidden control): `127` →
`/sys/class/backlight/panel0-backlight/brightness`, read back before run 1 and
before run 2. **Never written or read:** `blu_default_duty`, `blu_max_overlap_us`,
`fifo_trim`, `backlight_changes_blocked`, debugfs, `oculus,blu`
bootload/reset; no DCS (the harness provides decoy `blu_default_duty`,
`fifo_trim` and `blu_max_overlap_us` files and checks that no probe output names
them).

**Bounds.** Every sysfs value is read with the `read` builtin, one line, at most
120 bytes (`read -n`); at most 4 interrupt lines of 200 bytes; the cmdline at most
2048 bytes; the dmesg section (mods, mid, post) only the matching lines newer than
the previous point ("dmesg deltas per point"), the last 40, each cut to 160 bytes,
at most **1536 bytes** in all. `fs-probe.sh` starts with `exec 2>/dev/null`, so its
stderr is empty. fs-supervise's `-c` (**16384** for probe1, **12288** for probe2) is
the backstop: an over-long probe is **cut there gracefully** (`out_kept <
out_total`; the record stays VALID, the probe step stays informational, and the
backlight lines, which come early, survive any cut; `test-host3b.ps1` K37/K42).
fs-display waits at most TW1 = 3 s / TW2 = 2 s for "pre", at most TQ = 2 s after a
run for "post", and then kills the probe's supervisor (the step is then `nosup`,
still a valid record).

**Margins (review m4).** The filter over a synthetic **1 MB** kernel log (11,167
lines, 2,810 matching) takes about 0.48 s under qemu-aarch64 (`tools/dmesg-timing.sh`
→ `fixtures/dmesg-timing.txt`; a later point with no new lines about 0.48 s). The
mods snapshot with it, the write and pre1 (no dmesg) fit TW1 = 3 s with about 2 s to
spare under qemu; a post snapshot (≈ 0.6 s with the 1 MB log) fits TQ = 2 s. In the
harness (a small kernel log) pre1 started 0.24 s after probe1 started.

## 5. Disclosures (FS-R-010 §2, §4, §6)

- **Brightness.** The write of 127 is an explicitly added runtime write (not
  persistent). On v66 the value is stored while the panel is not enabled and
  applied at the next enable (`sde_connector.c:175-177`, `:837-852`, `:993`;
  `props.brightness` is never reset by the driver, so the read-back before run 2
  is meaningful) [M-static, near-match v66 source]. The resulting BLU duty of
  **about 4.1 %** (half of the 8.2 % that the default 1000/1000 level would
  program) is a **source-derived expectation, not a measured optical cap**.
  Whether Unit 1's `.511` module behaves exactly so is [C].
- **If the panel is already lit at handoff (H2).** The driver might then apply the
  127 at once rather than at run 1's enable [C]: a change of light about 0–3 s
  **before** run 1's commit, without the pattern. The PM could take that light for
  run 1; light without the pattern is reported as LIT (OUTCOMES §9.5), and the
  probe snapshots "mods"/"pre1" (interrupt counters, `backlight_timing`) bracket it.
- **One deliberate panel off→on cycle.** Run 1's close and run 2's enable go
  through Meta's stock driver paths (normal DRM use, no DCS injection). This is
  **untested behaviour** on our boot path (FS-R-007 §4: "additional untested
  behavior"); if the panel or BLU was physically off at handoff (H1), the enable
  may not restore it [O].
- **Fan.** On v66 the fan driver sets the fan to 0 on blank and stores cooling
  requests until unblank [M-static]. The fan **may stop after run 1's close**, may
  start again at run 2's unblank, and **may stop again after run 2's close**, until
  recovery. We never command the fan; the probes read its state only.
- **Retained-frame exposure.** If a close does not turn the panels off on v66, the
  last frame (the **bright** pattern, at the programmed backlight) **may stay
  displayed until recovery**: the PID 1 reboot is intended at T0 + 200 s (backstop
  201 s); these are intended reboot times, not guaranteed panel-off times; a kernel
  hang, suspend or failed reboot leaves it to the manual route (FS-R-007 §4). The
  PM's dark check before `fs-done` is the control.
- **Eye safety.** Static content, one commit per run, holds of 3 s and 10 s, at
  least 2 s apart; the PM may look away at any time (execution continues). **No
  numerical eye-safety guarantee is claimed from the spacing of the transitions**
  (FS-R-010 §4).
- **"No light seen" is not a measurement of zero emitted light** or of zero
  exposure (FS-R-010 §2).
- **Lit but garbled** (lines, noise, misplaced halves) is a lighting finding, not
  an optical PASS; the layout is deliberately unchanged from trial (iii) (2 planes
  × 2064 px), which may not be the layout the driver expects for a correct image
  (Android uses 4 × 1032) [O].

## 6. Implementation choices to note (each within FS-R-010)

- `show-off` **refuses to commit** when the CRTC is not provably inactive, rather
  than committing on an active CRTC: FS-R-010 §4 says to register the unmet
  precondition "and recover"; a second splash-style commit is not the registered
  experiment.
- If the brightness read-back is not 127 before a run, that run is **skipped**
  (registered), because the Chair adopted the write as a precondition ("verify the
  brightness setting before both runs").
- The "after modules" point is the runner's first probe ("mods"); init adds only a
  fork-free interrupt sample right after MODULES_READY ("irq0"), so the boot path
  gains no supervised step before the shell.
- The full property dump runs in run 1 only; run 2 logs the topology and the
  `mode_properties` blob (the state after the power cycle) to keep the record
  small.
- dmesg deltas per point: each probe point shows only the matching kernel-log lines
  newer than the previous point, the last 40, at most 1536 bytes; none at pre1/pre2.
- A run starts only after its "pre" snapshot has finished (`pre*.done`) and the
  read-back is 127.
- The paced emission writes **20 lines per 0.1 s** (`FSB1_PACE_LINES=20` set by
  fs-display before it sources the pinned pacer, whose default stays 10): one write
  is at most about 1.8 KB of DATA lines (≤ 3.5 KB even with all five STEP lines),
  far below the 12,289-byte first-read boundary at which trial (iii) lost bytes.
  This halves the emission time and restores the timing margin (IMAGE.md §4).
- The **maximum permitted record** is enforced by the emitter: **MAXLINES = 2070**
  lines; a larger record is not emitted (`FSDE1 error=record-too-large lines=N`,
  surfaced by the CLI). The step caps are **consistent with it** (review M1):
  BEGIN + 5 STEP + END + every step's stdout at its cap (48 bytes per DATA line) +
  the hash step's stderr at its cap = 7 + 6 + 6 + 342 + 854 + 256 + 598 = **2069 ≤
  2070**, and fs-pattern, fs-probe.sh and the skip step write no stderr, so **no
  record within its step caps can be refused** (`check-timing-3b.py` asserts it).
  A realistic record is about 880 lines.
- The hash step runs concurrently with the probes (no run waits for it); it is
  measured the same way and classified first.

**Residual risk (for the Chair).**
- *Refusal of a legitimate record:* none within the caps (above). Only bytes on a
  stderr that is empty by construction could push a record over: the 1-line
  margin (2070 − 2069) absorbs 48 such bytes; more would cost the record (FSDE1,
  INCONCLUSIVE). We know of no path that writes them.
- *Truncation instead of refusal:* a heavy probe (e.g. kernel-log spam during the
  off→on) is cut at its cap; the record keeps all commit evidence (the pattern
  steps are separate). A pattern step cut at its cap would make that run's stream
  unreadable (OUTCOMES §9.4 rules 10/19, INCONCLUSIVE): run 1 would need more than
  40,960 bytes (expected ≤ ≈ 31 KB: ≈ 10.5 KB of v0.4 records as measured in trial
  (iii), plus at most 20,480 bytes of optional property records); run 2 more than
  **28,672** bytes. Run 2 holds ≈ 10.5 KB of essential records plus the topology
  record and the `mode_properties` blob, which `fs-pattern` reads only up to 4096
  raw bytes. If every one of those bytes were a non-word byte, the `%XX` encoding
  would triple it to ≈ 12 KB, plus 18 record headers: **≈ 14–16 KB encoded**, so
  ≈ 25–27 KB in all, under the 28,672-byte cap (review N1; the earlier "≈ 6 KB
  encoded" assumed mostly word characters and understated the worst case). A blob
  over 4096 bytes is logged by its length only. Kernel messages cannot enter the
  pattern steps.
- The emission bound assumes the host drains the tty promptly (§4 of IMAGE.md).

## 7. Fixtures (all offline)

| suite | result |
|---|---|
| fs-pattern v0.5 (`tools/fixtures.sh`, qemu-aarch64) | **109/109**: the v0.4 suite (unit tests 45/45 incl. 17 new, render, refusals, stdout contract, strace close-before-write, signals, clamp, backstop, framing of every stream) plus show-off refusals, propsim full/off round trip (14 + 9 checks), the optional-budget path, static no-new-SET / read-only topology/dsc / only GETPROPBLOB new / layout and hold code identical to v0.4, the bright render checked for four nonces, the preview port byte-identical |
| paced emission (`tools/pace_evidence.py`) | **27/27** (`fixtures/pace/RESULTS.txt`; `../common/FSB1-SPEC.md` §9) |
| builder (`test-builder.sh`) | see `IMAGE.md` §7 |
| whole image (`test-image.sh`) | see `IMAGE.md` §7 |
| host (`../host/test-host3b.ps1`; `../host/test-host2.ps1` unchanged) | see `IMAGE.md` §7 |
| timing (`tools/check-timing-3b.py`) | CONSISTENT (`IMAGE.md` §4) |

**Not covered offline:** every DRM ioctl after `open` (the property logging is
exercised only against the mock model), the commits, the close path, the off→on
behaviour, the backlight write's effect, the real interrupts and dmesg, the
tty/USB transport timing, legibility.

## 8. Open items

- [O] Whether the panels light at all on our `fastboot boot` path (H1 vs H2,
  `docs/research/display-handoff-dark.md`).
- [O] Whether run 1's close turns the panels off on Unit 1's module (the
  `crtc_state active=0` of run 2 answers whether the CRTC was disabled).
- [O] Which eye shows which half; whether 2 × 2064 gives a correct image.
- [O] The real `capabilities`/`mode_properties` contents (logged by run 1).
