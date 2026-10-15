# Stage 3b boot image: trial (iii-b), the revised display test

**Status:** built and fixture-tested **offline only**, 2026-10-10. No device, adb,
fastboot or COM port was used. The whole-image harness runs the image's own
initramfs under qemu-user in a bwrap sandbox on the build host (as for stage 3a);
the image has **not** been booted anywhere.

~~**Not yet for a device.** FS-R-010 is preparation concurrence, not concurrence to
execute.~~ **Concurred to execute (FS-R-011 §1, 2026-10-11, J-104)**, for exactly
this image on Unit 1, once, attended; ~~not yet run~~ **run 2026-10-11 (J-107;
nonce spent): machine side PASS, run 1 dark, run 2 lit but garbled [PM report];
evidence FS-A-012 (private review record), report in FS-A-012**. Use needed the PM's attended
sign-off (`../SIGNOFF.md`, trial (iii-b), with FS-R-011 clarifications A and B).

**What it is.** A separate `fastboot boot` image for Unit 1 (Quest 3, v66,
slot A): the stage-3a image's bring-up and PID 1 deadline (DEADLINE 200 s), the
stage-3b runner (`README.md` §1): bright `fs-pattern` v0.5 twice (3 s, then 10 s
from an inactive CRTC), bounded read-only probes, the one backlight write (127),
one paced FSB1 record. It carries no Valve file.

**What success means.** The PM reading all 8 characters correctly **in each eye**
in one committed run (`../common/OUTCOMES.md` §9.5). The classifier gives the
machine side; a lit-but-garbled image is a lighting finding, not a PASS.

**Recovery:** `../RECOVERY.md` (stage-3b rows).

## 1. The image

| | |
|---|---|
| file | `build/stage3b/20261010T194509Z-6cf0f15867f14edc/boot-stage3b.img` (gitignored) |
| SHA-256 | **`ea60d6cddb2d14d16e208d16f6aef0ebc8798c1e9e74c223d73438bd92705841`** |
| size | 43,151,360 B |
| nonce | `6cf0f15867f14edc` (USB serial `FS-6cf0f15867f14edc`), fresh from the builder (`openssl rand -hex 8`). One attempt only; ledger `build/stage3b/attempted` |
| builder | `stage3b/build-image.sh` `49b2a8f14492703467278be2a69029c51098ed796a0ca229e2fc2ea3727af11e`; records in the build directory (MANIFEST.txt, ramdisk.list, ramdisk.sha256, applets.txt, header-diff.txt, ramdisk-scan.txt, gitcheck.txt) |
| stock boot | `49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50` |
| kernel | `f34165b35a826052ce5b520d9313387c96970b498733f1a7b141dcf4afc94e7b`, byte-identical (AOSP re-unpack) |
| header | only `ramdisk size` and `boot.img signature size` differ from stock |
| ramdisk | `ramdisk.lz4` `e752da4762d102c502534965331fece24c32af35497042bb1dbd4826d804346e` (1,936,330 B); cpio `afbe181505c000937c9e41fd16a080eb4a4f3b6ab4c8fc33159a3af5f6cbecde` (3,354,112 B, `--reproducible`) |
| vendor_boot | `1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf`; modules list `1ec0253f…6745` (97); file list `403e891e…c040` (111) |
| E1 | AOSP mkbootimg `d2bb0af5ba6d3198a3e99529c97eda1be0b5a093` CLEAN; note: mode bits not checkable on this drvfs checkout |
| scan | `stage2a/tools/t1-ramdisk-scan.sh` `73e969ca…c524`: no BLAKE2 hit |
| reproducibility | same nonce and stamp twice → one image (`test-builder.sh`, §7) |
| superseded | development builds in `build/stage3b-superseded/`, never candidates: `536b41ac…fc13`, `2972deb1…ae0d`; earlier candidates withdrawn before review: `a09ff582…6be0` (nonce `8b1a9e00e2a3a9bc`; replaced after the adversarial review, M1), `00aca656…795a` (nonce `79683f1bf07ee35e`; replaced within the same fix round when pattern2's cap was raised to 20480), `c620c1b8…76bd` (nonce `d4ad74bb5d64f949`; the bdf5451 version, withdrawn in the final round for 20-line pacing, the 25 s planning start and pattern2's 28672 cap) |

### Contents (our ramdisk; the vendor ramdisk is stock)

Directories: `bin config dev lib lib/fs proc run sys tmp`.

| path | size | SHA-256 | source |
|---|---|---|---|
| `/init` | 12,327 | `51b68b18c8a01de6ca994fd223e6f7f1f3075d30373ea0dab56de21a92103cfc` | `stage3b/init.sh` `4446330f9cced820cacafb64d312256afb0ae72ff9a8eb24bdca7685e34820d6`, nonce substituted |
| `/bin/busybox` | 1,981,032 | `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02` | stage-1 busybox 1.37 (reviewed) |
| `/bin/fs-reboot` | 1,400 | `c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29` | stage-1 helper (backstop) |
| `/bin/fs-reboot-final` | 808 | `ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e` | `common/build` |
| `/bin/fs-supervise` | 676,952 | `77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74` | `common/build` |
| `/bin/fs-pattern` | 643,432 | **`4c36e4d97b7a04b0e8695c3731a7f679b3034598d50e3b52f523b19b4c6b02a6`** | `stage3b/build`, v0.5 (`BUILD-RECORD.txt`) |
| `/bin/fs-display` | 9,461 | `f32783762d4762d45f55712a1f01d31a056cddc97533dd143793d5278ff88504` | `stage3b/fs-display.sh` |
| `/bin/fs-done` | 705 | `7ad5f1106acd828fa3e9d6da9cfa0e50d66431b4b2d3a951ce39f12375064959` | `common/target/fs-done` |
| `/lib/fs/pid1-hold.sh` | 7,556 | `4294c9d57f3a94eba9847596aa614f557e7b4278cfeb5a22e38955fdd5b81dc4` | `common/target`, rev 5 (unchanged) |
| `/lib/fs/fsb1-enc.sh` | 4,943 | `11e44d2fa386d06c596c03ff54ecfb5aeeea4790a560c8e65bf26e76733bf1a7` | `common/target`, rev 5 (unchanged) |
| `/lib/fs/fsb1-pace.sh` | 3,255 | `71ce176e09c21b2304b0be90543f2c0da26b0a5c0aed3c3bb23cf8a2b412404c` | `common/target` (new, pinned) |
| `/lib/fs/fs-probe.sh` | 9,489 | `8ee8d9f292ba1d1f442da59e90873738f69f7e143cedfd82cab0c010ee36be2a` | `stage3b/fs-probe.sh` |

## 2. What the builder enforces

Stage 3a's checks (`../stage3a/IMAGE.md` §2), with the stage-3b inputs:
- the pins: stock boot/vendor_boot/kernel/module and file lists, busybox,
  fs-reboot, fs-reboot-final, fs-supervise, **fs-pattern v0.5**, pid1-hold.sh,
  fsb1-enc.sh, **fsb1-pace.sh**, fs-done; init.sh, fs-display.sh and
  **fs-probe.sh** are recorded (fs-observe.ps1 checks the recorded hashes against
  the repository before any boot);
- static-ELF checks for the five binaries; the applet table includes every applet
  the scripts use (now also `tail`, `dmesg`); no BLAKE2 applet; LF-only scripts
  with the busybox shebang;
- the exact ramdisk list (an injected file is refused); no symlinks; no vendor
  collision; the union lacks the loader paths and `/valve`; only the five ELF
  files; BLAKE2 scan of the final image;
- kernel bytes unchanged, header differences only `ramdisk size` and
  `boot.img signature size`, every file in the image equal to the staged file;
- a fresh nonce per build (fixtures may fix nonce and stamp; such a MANIFEST says
  TEST OVERRIDES and is refused by fs-observe.ps1 and test-image.sh).

## 3. What it does, step by step

1. Stage-1 §0; `fs_hold_init 200 150`; the backstop; the 97 modules;
   MODULES_READY.
2. **irq0** (new): a fork-free read of the `te-edge-isr`/`blu-pwm-isr` lines of
   `/proc/interrupts` into `/run/fs.irq0`.
3. The DRM node (as stage 3a); USB, gadget (`FrameShift stage3b`), helpers, the
   shell on ttyGS0; `fs_hold_loop`.
4. **Host** (`fs-observe.ps1 -Stage 3b … -BaSummary … -BfSummary … -ThenCollect`):
   the dwell gate (≤ 300 s since BA started; evaluated just before the attempt is
   registered, < 1 s before BootStartUtc; observe.json records the dwell at both
   instants), one `fastboot boot`, then the
   collector: fs-verify, fs-ack, fs-status, **the two-period cue**
   (`=== LOOK INTO THE LENSES NOW: a FIRST lit period (run 1, about 3 seconds)
   should start about 3.5 to 6.5 seconds from now, then a DARK gap of at least 2
   seconds, then a SECOND lit period (run 2, about 10 seconds) … ===`), 3 s
   read-only, then
   `fs-display <chal>` once.
5. **Device, `fs-display`** (`README.md` §1): hash (background) · probe1 (mods,
   write 127, read-back, pre1) · run 1 (`show`, 3 s; mid1, post1) · gate · pause
   ≥ 2 s · probe2 (read-back, pre2) · run 2 (`show-off`, 10 s; mid2, post2) · the
   record, paced.
6. **Host:** beep 1 (both runs over, keep looking), 10 s read-only dark check,
   beep 2, the per-eye/per-period report prompt (FSR1 lines), `fs-done`; PID 1
   execs `fs-reboot-final`.
7. AF at once in fastboot, `fastboot reboot`, AA, the temperature procedure
   (`../SIGNOFF.md` F), `fs-classify.ps1 -Stage 3b … -Readings readings.txt`.

## 4. Timing (`tools/check-timing-3b.py`: CONSISTENT)

**Runner worst case** (fs-supervise's bounds: t + g + reap 3 + strays 3 + drain 1):

| part | s | source |
|---|---|---|
| TW1: probe1 "pre1" waited for at most | 3 | `fs-display.sh` |
| run 1 step `-t 9 -g 3` (hold 3 + close margin 5 + 1) | 19 | `fs-display.sh`, `fs-pattern.c` |
| TQ: probe1 "post1", then its supervisor is killed | 2 | |
| gate, markers, forks (margin) | 1 | |
| PAUSE (fork-free) | 2 | |
| TW2: probe2 "pre2" | 2 | |
| run 2 step `-t 16 -g 3` (hold 10 + 5 + 1) | 26 | |
| TQ: probe2 "post2" | 2 | |
| encoding, 5 steps × 1 s (margin) | 5 | as stage 2a/3a |
| **paced emission of the MAXIMUM permitted record**, 20 lines per 0.1 s: 1 s + ceil(2070/20) × (0.1 + 0.01) s | **12.4** | `fsb1-pace.sh` with `FSB1_PACE_LINES=20` (fs-display.sh), MAXLINES |
| **W** | **74.4** | |

The hash step (worst 10 s) and the probe steps run concurrently and end inside W
(their bounds are checked); the skip step (worst 10 s) is shorter than either run
step. The emission term uses the **maximum** record the runner permits (2070
lines; a larger one is refused, `FSDE1 error=record-too-large`), not an expected
size: a realistic record is about 880 lines, ~5–6 s (measured 4.9 s under qemu for
876 lines; the 2070-line maximum took 11.4 s). **No record within its step caps
can exceed 2070 lines** (reviews M1, N1): 7 framing lines + every step's stdout at
its cap (hash 256 B → 6 lines, probe1 16384 → 342, pattern1 40960 → 854, probe2
12288 → 256, pattern2 28672 → 598) + the hash step's stderr at its cap (6) = 2069;
the other steps write no stderr. One paced write is at most about 1.8 KB of DATA
lines (measured maximum 2,234 bytes), far below trial (iii)'s 12,289-byte first-read
boundary. The emission bound **assumes the host drains the tty
promptly**: a stalled reader blocks `printf`, which is safe because both runs have
closed by then and the PID 1 deadline is independent of the runner.

**Host budget and guard** (`host/fs-collect.ps1 -Stage 3b`, the same clock model
as stages 2a/3a: origin BootStartUtc, fresh conversion after the preparation):

| quantity | value |
|---|---|
| device deadline | **T0 + 200 s**; backstop T0 + 201 s (FS-R-010 §6 ceiling) |
| ack window / ERR_DELAY | 150 s / 60 s (unchanged) |
| host give-up | BootStartUtc + 185 s; pre-runner phases by BootStartUtc + 135 s |
| record budget B | 200 − 15 (margin) − 25 (collector start, planning: trial (iii) measured 21.7 s, conversion at 24.4 s) − 61 (phases before the runner, 2 fs-status tries) − 3 (cue) − 11 (beep 1 + 10 s pause + beep 2) = **85 s** |
| RunnerWorstSec | **75** (≥ W = 74.4); B − W = 10.6 s spare; B − (75 + 5) = **5 s** guard spare |
| **immediate runner guard** | the collector sends `fs-display` only with **≥ 75 + 5 + 11 = 91 s** left before the give-up (FS-R-010 §6's estimate was about 95 s for W ≈ 79 s) |
| client holds | run 1: 3 s (alarm 8 s), run 2: 10 s (alarm 15 s), each from its commit start; subject to scheduling, suspend and uninterruptible kernel waits |
| panels after each close | off per the v66 close path [D, near-match source; not optically confirmed]; if not, the last frame (bright) may stay until recovery |
| retained-frame worst case | the bright pattern at the programmed backlight until recovery: intended reboot T0 + 200 s (backstop 201 s), **not a guaranteed panel-off time**; a hang, suspend or failed reboot leaves it to the manual route (from Th + 260 s) |
| control | the PM's dark check during the 10 s pause before `fs-done` |
| measured (harness, no DRM) | §7 |

The clock regressions (M1–M4) are re-run for stage 3b: BootStartUtc is taken before
the boot, the dwell gate runs before the attempt is registered and before
BootStartUtc, the collector converts to the transport clock only after the gadget
lookup and the transport, the start refusals are re-checked there, every admitted
runner ends by T0 + 200 − 15 s over the grid, and the Chair's counterexample (runner
at 144 s) is refused with origin BootStartUtc (41 s < 91 s) and would be unsafe with
origin Th.

## 5. Expected FSB1 steps (`exp=stage3b`, `steps=5`)

| i | id | expected |
|---|---|---|
| 1 | `hash` | `exited 0`, `4c36e4d97b7a04b0e8695c3731a7f679b3034598d50e3b52f523b19b4c6b02a6  /bin/fs-pattern\n` |
| 2 | `probe1` | `exited 0` (output possibly cut at 16384 bytes: informational): irq0, mods, one `backlight-write … value=127` line, `write_rc=0 readback=127`, pre1 (no dmesg), mid1, post1 |
| 3 | `pattern1` | `exited 0`, a sound FSP1 stream: `mode=show`, `commit rc=0`, `hold_end rc=0 reason=deadline … close_rc=0`, `exit code=0 reason=held_to_deadline shown=1`, `eos` |
| 4 | `probe2` | `exited 0` (possibly cut at 12288 bytes): `readback=127` (no write), pre2 (no dmesg), mid2, post2 |
| 5 | `pattern2` | `exited 0`, a sound stream: `mode=show-off`, `crtc_state active=0`, `precondition rc=0`, `commit rc=0`, held, `exit code=0 … shown=1`, `eos`; pause ≥ 2000 ms |

## 6. Outcome mapping

`../common/OUTCOMES.md` §9 (`host/fs-classify3b.ps1`): machine side PASS (machine
side) / RUN 1 ONLY / PRECONDITION UNMET: CRTC ACTIVE / NO-DISPLAY / DISPLAY FAIL /
INTEGRITY FAULT / INCONCLUSIVE; optical side OPTICAL PASS / ONE-EYE ONLY / LIT BUT
GARBLED / BOTH DARK / DARK / NOT RECORDED / INCONCLUSIVE, with the label RUN 1
DARK, RUN 2 LIT; the registered result is a STAGE PASS only with an optical PASS in
a committed run.

## 7. Offline fixtures

| suite | result |
|---|---|
| fs-pattern v0.5 (`tools/fixtures.sh`) | **109/109** (`fixtures/RESULTS.txt`; README §7) |
| paced emission (`tools/pace_evidence.py`, 20 lines per 0.1 s) | **27/27** (`fixtures/pace/RESULTS.txt`; `../common/FSB1-SPEC.md` §9): representative 876 lines, at-caps 2069, maximum 2070, refusal at 2071; largest single 20-line write 2,234 bytes (representative record; at-caps 2,178, maximum 2,180); 103 pty pauses for 104 chunks |
| kernel-log cost (`tools/dmesg-timing.sh`) | the probe's filter over a synthetic 1 MB log: 0.48 s under qemu (`fixtures/dmesg-timing.txt`); TW1/TQ margins in README §4 |
| builder (`test-builder.sh`) | **10/10**: 8 refusals (fs-pattern tampered/missing, busybox, fs-supervise, fs-reboot-final, fs-reboot, **fsb1-pace.sh**, stock boot), `inject-extra-file` refused, `repro-same-nonce` bit-identical; plus the **candidate itself rebuilt** with its own nonce and stamp: `ea60d6cd…5841` again, identical cpio (`fixtures/builder/candidate-rebuild.txt`) |
| whole image (`test-image.sh`, the candidate's own initramfs under qemu/bwrap, no DRM device) | **12/12** (`fixtures/image/RESULTS.txt`, below) |
| host (`../host/test-host3b.ps1`) | **116/116** (`../host/test-host3b.output.txt`): collector spec and texts, every §9.4 rule (37 synthetic cases, incl. a probe cut at its cap), the runner refusal surfaced, the rule-25 wording, the optical rules (16 + 2, incl. contradicts-the-record vs record-absent), replays of 8 harness captures through `fs-collect.ps1 -Stage 3b` and the classifier/CLI, the re-chunked capture (every paced chunk boundary and mid-line), a cut-short record, the 91 s runner guard, paced-vs-unpaced decode (representative, at-caps, maximum), the damaged trial-(iii) capture, the dwell gate (11 checks incl. observe.json/observe.log), both timing checks |
| host, stages 2a/3a (`../host/test-host2.ps1`, unchanged) | **459/459** with the revised host code (`../host/test-host2.output.txt`) |
| timing (`tools/check-timing-3b.py`; `../stage2a/tools/check-timing.py`) | both CONSISTENT (`fixtures/check-timing-3b.txt`) |

| scenario | result (candidate image) |
|---|---|
| `b-nodrm` | genuine fs-pattern: run 1 `exited 10` (no device); run 2 skipped `run1-supervisor`; one backlight write to the fake node, read-back 127; record VALID (137 lines, paced); `collected` reboot at T0+20.3 s |
| `b-sim-go` | run 1 and run 2 "commit" (replayed FSP1): both steps VALID, `show` then `show-off`; mid1/mid2 taken during the holds; probe2's pre2 started 2.64 s after probe1's post1 (the pause); record 344 lines in 2.1 s on the pty; runner 20.8 s |
| `b-sim-active` | run 2 exit 31 (precondition unmet), no commit; probe2 pre2 and post2 |
| `b-sim-unclean` | run 1 `close_rc=-5`: run 2 skipped `run1-close-not-clean` |
| `b-no-backlight` | no backlight node: write `nonode`, read-back none: run 1 skipped `brightness-not-verified`, run 2 skipped `run1-not-run` |
| `b-probe-hang` | every probe blocks on a FIFO "sysfs" read: run 1 skipped `probe1-late`; both probe supervisors killed after TQ (`nosup`); record still VALID; runner 13.5 s |
| `b-hung-pattern` | TERM-ignoring fs-pattern: run 1 `timer-kill`; run 2 skipped |
| `b-pattern-stopped` | the genuine fs-pattern SIGSTOPped: run 1 `timer-kill` (DISPLAY FAIL, integrity shown) |
| `b-no-ack` | `no-host-ack` at SHELL_READY+150 s; magenta LED |
| `b-ack-no-done` | `deadline` at **T0+200.7 s** (HOST_ACK did not cancel it) |
| `b-done-early` | `collected` within 3 s of fs-done |
| `b-no-udc` | `fail()`: `error-udc` at T0+60.5 s |

In every scenario PID 1 rebooted by exec of `fs-reboot-final` (pid 1), the record
(when one was due) was preceded by its empty line and decoded VALID with
`common/tools/fsb1.py`, and the paced emission was visible on the pty (≥ 0.09 s per
20-line chunk).

## 8. Changes from the stage-3a init (each justified)

| # | stage 3a | stage 3b | why |
|---|---|---|---|
| 1 | DEADLINE 170 s | **200 s** | the two-run runner's bounds (§4); FS-R-010 §6 ceiling |
| 2 | — | fork-free irq sample after MODULES_READY | the handoff-time TE/BLU counters (FS-R-010 §4 probes) |
| 3 | `fs-display`: hash, one 10 s run | the stage-3b runner | FS-R-010 §4 |
| 4 | — | `/lib/fs/fs-probe.sh`, `/lib/fs/fsb1-pace.sh` | probes and the one write; paced emission (§5) |
| 5 | product `FrameShift stage3a` | `FrameShift stage3b` | identity |

Everything else in `init.sh` is stage 3a's (and so stage 1's bring-up).

## 9. Not exercised offline; open items

**Not exercised offline:** every DRM ioctl after `open` (the v0.5 property logging
only against the mock model), both commits, the close and off→on paths, the
backlight write's effect on the BLU, the real interrupt counters and kernel log,
the fan nodes on the device, the `card0` mknod, the 97-module load, configfs/UDC,
the real reboot, the tty/USB timing of the paced emission, PID 1 signal immunity,
thermal behaviour, legibility.

**Reviews done:** the adversarial review of the first package (afc6666: no BLOCKER,
2 MAJOR, 9 MINOR, all fixed); the verification pass of the fixed package (bdf5451:
ready for the Chair, with a recommendation to restore the thin 1 s guard margin);
this final round (20 lines per 0.1 s pacing, 25 s planning collector start,
pattern2 cap 28672 with MAXLINES 2070, the dwell-instant note, the OUTCOMES
run-1 wording): guard 91 s with 5 s spare.

~~**Open:** the Chair's review.~~ **Ruled (2026-10-11):** FS-R-011 §1
concurred to execute this image (J-104). Trial (iii-b) ran on 2026-10-11
(J-107; `../../../README.md` status). Open: the analysis of the run 2 garble and
the FS-A-012 report to the Chair.
