# Stage 3c boot image: the interactive per-phase display run

**Status: CANDIDATE, not final (the build-review rebuild of 2026-10-12, DESIGN "Build-review fixes";
reviews done J-111..J-114 (R-B, R-C, rebuild/mutation, R-D, Q7 review); then the PM's sign-off).** Built and fixture-tested **offline only**, 2026-10-12.
The previous candidate `e1856cd2…0aad90` (nonce `3296cd623cc7da0f`) is **withdrawn** (never booted). No device, adb, fastboot or COM
port was used; the image had not been booted anywhere (as of 2026-10-12; it ran on Unit 1 on 2026-10-13, J-125, nonce spent). The whole-image harness runs the image's own
initramfs under qemu-user in a bwrap sandbox on the build host (as for stages 3a/3b). Any change
found by the reviews means a new build with a new nonce; this candidate is then withdrawn.

**What it is.** A separate `fastboot boot` image for Unit 1 (Quest 3, v66 (Unit 1), slot A): the
stage-3b image's bring-up and PID 1 deadline (DEADLINE 200 s, backstop 201 s), plus `/bin/fs-phase`
(one paced FSB1 record per phase p0/r1/r2/r3, live FSPM1 markers, FSXE1 refusals), the stage-3c probe,
fs-pattern v0.6 (run 1 v0.5 path; run 2 four planes x 1032 px with zpos {0,0,1,1}; run 3 the red
field), the device-side idle limit and the one backlight write (127). It carries no Valve file.
Execution needs the PM's executive decision (J-107 decision 3) with every condition DESIGN.md lists.

**What success means.** The PM reading all 8 characters correctly in each eye in a machine-shown run
(DESIGN §11.4; 3b §9.6). The run-3 interpretation and the layout labels are diagnostic, never a PASS.

## 1. The image (CANDIDATE)

| | |
|---|---|
| file | `build/stage3c/20261012T010256Z-<attempt nonce withheld>/boot-stage3c.img` (gitignored) |
| SHA-256 | **`9d3ad98400ac94f42b291a66b0420576df5ad8ee447e831d971fcaba9bd914bd`** (CANDIDATE) |
| size | 43,167,744 B |
| nonce | `<attempt nonce withheld>` (USB serial `FS-<attempt nonce withheld>`), fresh from the builder (`openssl rand -hex 8`). One attempt only |
| builder | `stage3c/build-image.sh` `25b4a0094805d0e11279ea64a3f0ced1e39297b40647461b0c343816441688da`; records in the build directory (MANIFEST.txt, ramdisk.list, ramdisk.sha256, applets.txt, header-diff.txt, ramdisk-scan.txt, gitcheck.txt) |
| stock boot | `49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50` |
| kernel | `f34165b35a826052ce5b520d9313387c96970b498733f1a7b141dcf4afc94e7b`, byte-identical (AOSP re-unpack) |
| header | only `ramdisk size` (1886092 → 1950169) and `boot.img signature size` (4096 → 0) differ from stock |
| ramdisk | `ramdisk.lz4` `eb175203a973a4b04090ce9feb3c2a0d8d80aeb2eb3232d0c025cad2f9997431` (1,950,169 B); cpio `dfa846d4c98ce6eae033991b50562e1f20c100a623b2933ab16879afd11f8cc2` (3,384,320 B, `--reproducible`) |
| vendor_boot | `1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf`; modules list `1ec0253f…6745` (97); file list `403e891e…c040` (111) |
| E1 | AOSP mkbootimg `d2bb0af5ba6d3198a3e99529c97eda1be0b5a093` CLEAN; note: mode bits not checkable on this drvfs checkout |
| scan | `stage2a/tools/t1-ramdisk-scan.sh` `73e969ca…c524`: no BLAKE2 hit |
| superseded | development builds in `build/stage3c-dev/` (TEST OVERRIDES, never candidates); the withdrawn candidate `build/stage3c/20261011T223941Z-3296cd623cc7da0f/` |

### Contents (our ramdisk; the vendor ramdisk is stock)

Directories: `bin config dev lib lib/fs proc run sys tmp`.

| path | size | SHA-256 | source |
|---|---|---|---|
| `/init` | 13,150 | `04ee28e8cf757cf60ec118a0cf5db7250661aa58b06ad304f59459073c6faaec` | `stage3c/init.sh` `479fd2c65d68df580e4b621fc63e9cc5fa83df84a88c2ab5a22310a641a69fbe`, nonce substituted |
| `/bin/busybox` | 1,981,032 | `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02` | stage-1 busybox 1.37 (reviewed) |
| `/bin/fs-reboot` | 1,400 | `c393eef56e387f03148f6d919f788d9b3af605d571f4f54f60c2061122491f29` | stage-1 helper (backstop) |
| `/bin/fs-reboot-final` | 808 | `ec52c93441012bf00f9717f2bdbb2ea3dba98703a7babab8ad3e26a0f60cf08e` | `common/build` |
| `/bin/fs-supervise` | 676,952 | `77f7a70a7904a7091db8e132b6c8f0ee68e6187f94d4690ec2a42a26f5206a74` | `common/build` |
| `/bin/fs-pattern` | 664,168 | **`066bdc3ee01e5974518f96e8311c071c8f3aed302cadefa42c1273d5196b27bc`** | `stage3c/build`, v0.6, build-review rebuild (`BUILD-RECORD.txt`) |
| `/bin/fs-phase` | 14,062 | `3d9b9bec5132ceadb6aa722c16e410ee307b801db6bf6850b67afd26f788f877` | `stage3c/fs-phase.sh` |
| `/bin/fs-done` | 705 | `7ad5f1106acd828fa3e9d6da9cfa0e50d66431b4b2d3a951ce39f12375064959` | `common/target/fs-done` |
| `/lib/fs/pid1-hold.sh` | 7,556 | `4294c9d57f3a94eba9847596aa614f557e7b4278cfeb5a22e38955fdd5b81dc4` | `common/target`, rev 5 (unchanged) |
| `/lib/fs/fsb1-enc.sh` | 4,943 | `11e44d2fa386d06c596c03ff54ecfb5aeeea4790a560c8e65bf26e76733bf1a7` | `common/target`, rev 5 (unchanged) |
| `/lib/fs/fsb1-pace.sh` | 3,255 | `71ce176e09c21b2304b0be90543f2c0da26b0a5c0aed3c3bb23cf8a2b412404c` | `common/target` (unchanged) |
| `/lib/fs/fs-probe.sh` | 10,666 | `f043af6fa9a6e3bec726339c329b094ece28883e5f97cf8acb0cb9c035bb9c4f` | `stage3c/fs-probe.sh` |
| `/lib/fs/fs-idle.sh` | 2,276 | `989472569328413928b5c2ab01b53060aa3a99081cf66209e45d161737ed6124` | `stage3c/fs-idle.sh` |

The host pins (DESIGN §12.4) are taken by `fs-observe3c.ps1 -Preflight`; this file records the
device side only.

## 2. What the builder enforces

Stage 3b's checks (`../stage3b/IMAGE.md` §2) with the stage-3c inputs: the pins (stock boot,
vendor_boot, kernel, module and file lists, busybox, fs-reboot, fs-reboot-final, fs-supervise,
**fs-pattern v0.6**, pid1-hold.sh, fsb1-enc.sh, fsb1-pace.sh, fs-done; init.sh, fs-phase.sh,
fs-probe.sh and **fs-idle.sh** recorded); static-ELF checks; the applet table (no new applet:
`rm`, `kill`, `tail`, `mkfifo` were already in it); LF-only scripts with the busybox shebang; **no
`debugfs` or `/sys/kernel/debug` in any non-comment line of any script** (new; PM decision J-109
#2); **build review:** every non-comment line naming `mount`/`umount` must be one of init.sh's five
reviewed mounts (proc, sysfs, two tmpfs, configfs), and `fs-idle.sh` may name no tty or console. These
are **lints over the script text, not proofs** (a command name built at run time passes them); the
run-time evidence is the harness (inotify on the fake debugfs tree, the backlight write count, the tty
accounting, §7); the exact ramdisk list (`bin/fs-phase`, `lib/fs/fs-idle.sh` new, `bin/fs-display` gone); no
symlinks, no vendor collision, the union lacks the loader paths and `/valve`, only the five ELF
files; the BLAKE2 scan; kernel bytes unchanged; header differences only as above; every file equal to
the staged one; a fresh nonce per build (TEST OVERRIDES images are refused by test-image.sh and
fs-observe3c.ps1).

## 3. What it does, step by step

1. Stage-1 §0; `fs_hold_init 200 150`; **`/run/fs.deadline` = T0 + 200** (fork-free); the backstop;
   the 97 modules; MODULES_READY; the irq0 sample (as 3b).
2. The DRM node; USB, gadget (`FrameShift stage3c`), the helpers; **`/lib/fs/fs-idle.sh` started
   (one fork, stdio /dev/null)**; the shell on ttyGS0; `fs_hold_loop`.
3. **Host** (`fs-observe3c.ps1 … -ThenCollect`): the unconditional dwell gate, one `fastboot boot`,
   then `fs-collect3c.ps1`: fs-verify, fs-ack, fs-status, then per phase `fs-phase <ph> <chal>
   <prev>` under its guard G_k, the PM's prompts between phases, the gated `fs-done`.
4. **Device, `fs-phase`** (README §1, DESIGN §5): the refusal checks (usage, bad-nonce, order,
   already-run, chain, time, begin), the lock, `begin`; the phase's two steps (p0 hash ∥ probe0;
   r-phases: gates, the pause for r2/r3, probe, `go`, the pattern step, `end`, or `skip` and the skip
   step); the record; `rec`; the paced emission; the device's own sha16; nothing more on the tty.
5. PID 1 reboots to the bootloader ~1 s after `fs-done` (or after the idle limit's `idle` token, or
   at T0 + 200 s, backstop 201 s).

## 4. Timing (`tools/check-timing-3c.py`: CONSISTENT; `fixtures/check-timing-3c.txt`)

Per-phase worst case (fs-supervise bounds t + g + reap 3 + strays 3 + drain 1; GATE 1 s; emission
1 s + ceil(MAXLINES / 20) × 0.11 s; encode per step = max(1 s, 1.5 × measured) with the recorded cold
repetition; the encoder END pass 1.5 × 0.16 = 0.24 s; TQ 3 s; PHASE_WORST ≥ W + 0.5 s; build review):

| phase | worst case W | PHASE_WORST | MAXLINES (caps-derived) | probe -t ≥ window |
|---|---|---|---|---|
| p0 | max(probe0 16, hash 10) + 1 + 1 + 1.005 + END 0.24 + 2.98 = **22.22 s** | 23 | 360 (358) | — |
| r1 | TW 2 + pattern1 19 + TQ 3 + 1 + 1.005 + 1.125 + 0.24 + 9.58 = **36.95 s** | 38 | 1545 (1541) | 24 ≥ 24 |
| r2 | PAUSE 2 + 2 + pattern2 26 + 3 + 1 + 1.005 + 1.125 + 0.24 + 9.58 = **45.95 s** | 47 | 1545 (1541) | 32 ≥ 31 |
| r3 | PAUSE 2 + 2 + pattern3 21 + 3 + 1 + 1.005 + 1 + 0.24 + 6.28 = **37.52 s** | 39 | 945 (944) | 26 ≥ 26 |

- **Encode re-timed at the maximum streams** (`tools/encode-timing.sh` → `fixtures/encode-timing.txt`,
  3 repetitions under qemu on a quiet host): probe 16384 B ≤ **0.67 s**, pattern 57344 B ≤ **0.67 s**
  (0.61–0.67), pattern 28672 B ≤ 0.58 s, END ≤ 0.16 s; an earlier run gave 0.75 s for one cold
  57344-byte repetition, now recorded in the fixture as `ENCODE_COLD` and counted (× 1.5 = 1.125 s).
  With the END pass and TQ 3 s the margins fell below 0.5 s (p0 below 0), so the build review raised
  PHASE_WORST to **23 / 38 / 47 / 39** (margins 0.78 / 1.05 / 1.05 / 1.48 s); DESIGN §9.1–§9.4 carry
  the new numbers for the PM. Qemu emulation on x86 is not the device.
- **Holds** 3 / 10 / 5 s ≤ FSP_HOLD_MAX_S 10; total lit ≤ 18 s; pattern -t 9 / 16 / 11 = hold + 5 + 1.
- **Essential-record cap** (build review): connector / mode / plane / plane_caps records essential only
  up to 3 / 24 / 20 / 20 (= the maximum fixtures' counts, asserted); beyond that they are optional.
- **Stream bounds:** DESIGN 17886 B essential + 38912 = 56798 ≤ 57344; + 10240 = 28126 ≤ 28672. The
  mock-model maxima (24 modes, 3 connectors, 20 planes, 8 KiB all-%XX blobs): quad 17121 + 38912 =
  56033, show 13140 + 38912 = 52052, solid 17111 + 10240 = 27351 (`fixtures/sim/*-max.check.log`).
- **Pause:** PAUSE_CS 200 (2.00 s), at most PAUSE_ITER 20 × 0.1 s; measured in `c-pause`: r2's go
  2.64 s after a run-1 end written just before r2 was sent (build-review run; 2.70 / 2.41 s earlier).
- **Idle limit:** IDLE_S 120 ≥ host gap cap 110 + 10; STUCK_S 180. Measured: reboot at activity +
  121.6 s (`c-idle`), + 181.7 s with a "running" phase (`c-idle-stuck`).
- **Host guards** (DESIGN §9.3; cross-checked against `host/fs-collect3c.ps1` as present at the run):
  G = 34 / 68 / 82 / 64; give-up 185 s; per-lit-phase limits r1 117, r2 103, r3 121; a send at 144 s
  refused for each; clock regressions M1–M3 retargeted to fs-observe3c.ps1 / fs-collect3c.ps1 PASS.
- **dmesg filter** (wider): 0.65 s over a 1 MB synthetic log under qemu on a quiet host (0.98 s in a
  run on a loaded host; 3b's narrower filter: 0.48 s); read at mods (p0, no window), mid (inside the
  hold) and post (TQ 3 s): within the margins.

## 5. Expected FSB1 records (one per phase; `exp=s3c_<ph>`, `steps=2`)

| phase | i=1 | i=2 |
|---|---|---|
| p0 | `hash`: `exited 0`, `066bdc3e…27bc  /bin/fs-pattern\n` | `probe0`: `exited 0`; irq0, mods (cmdline, dmesg), one `backlight-write … value=127`, `write_rc=0 readback=127` |
| r1 | `probe1`: read-back 127, pre (no dmesg), go+1, mid (pair), end, post | `pattern1`: `mode=show`, the v0.5 attempts, `commit rc=0 … layout=split`, post_state, post_plane ×2, held, clean close, `eos` — or `FSK1 run=1 skipped reason=…` |
| r2 | `probe2` (mid at 5 s) | `pattern2`: `mode=show-off-quad`, `precondition rc=0`, plan, `test_commit … layout=split_probe`, `quad_vig` (and `quad_dma`), `commit … layout=quad_*`, post_state, post_plane ×4 (CRTC_X 0/1032/0/1032, SRC_X 0/1032/2064/3096, zpos 0/0/1/1), held, `eos`; or exit 31 / 50 |
| r3 | `probe3` (mid at 2.5 s) | `pattern3`: `mode=show-off-solid`, as r2 with `buffer … solid=0xff0000` |

## 6. Outcome mapping

DESIGN §11 (proposed `../common/OUTCOMES.md` §10), implemented by `../host/fs-classify3c.ps1`
(host side).

## 7. Offline fixtures

| suite | result |
|---|---|
| fs-pattern v0.6 (`tools/fixtures.sh`, qemu-aarch64) | **136/136** (`fixtures/RESULTS.txt`): the v0.5 suite kept (unit tests now **63/63**, incl. the build-review essential-record cap; render, refusals, stdout contract, strace close-before-write, signals, clamp, backstop, framing of every stream); show-off-quad/solid refusals; propsim full/off/quad/solid/repeat (52 checks); **18 whole-path scenarios against the mock DRM device** (526 checks: selection incl. DMA blobs at pipe_idx 0–3, missing/ambiguous variants, order split_probe → quad_vig → quad_dma, split never committed, exit 50/31, zpos only in quad attempts on the four planes 0,0,1,1, the set of SET properties = v0.5 + zpos, commit = last accepted TEST_ONLY, E15 stage-slot model with the {0,0,0,0} negative control, post_state/post_plane with the converted CRTC_X and the unconverted finding, pixel classes, stream bounds); static checks vs v0.5 (50: + the 2 × 2064 policy, the split probe TEST_ONLY, `ok` only in the quad loop, the quad tag, the essential cap); the v0.6 picture for 5 nonces incl. the worst case (25 checks each); render-solid; the preview port byte-identical; the previews |
| paced emission (`tools/pace_evidence.py`, 20 lines per 0.1 s) | **63/63** (`fixtures/pace/RESULTS.txt`; build review: each paced time ≤ the analytic bound itself, no 2 s allowance): per phase the at-caps record (p0 358, r1/r2 1541, r3 944 lines) and the maximum (360 / 1545 / 945) byte-identical paced vs unpaced, VALID, same rec_sha256; MAXLINES + 1 refused with nothing written; the r2 maximum through a pty (ONLCR) and split at every chunk boundary and mid-line: VALID; largest write 2,012 bytes; the damaged trial-(iii) capture still REJECTed |
| encoder timing (`tools/encode-timing.sh`) | `fixtures/encode-timing.txt` (§4; with the recorded `ENCODE_COLD` repetition) |
| kernel-log cost (`tools/dmesg-timing.sh`) | `fixtures/dmesg-timing.txt` (§4) |
| timing (`tools/check-timing-3c.py`) | **CONSISTENT** (`fixtures/check-timing-3c.txt`) |
| builder (`test-builder.sh`) | **16/16** (`fixtures/builder/RESULTS.txt`): 8 pin refusals (fs-pattern tampered/missing, busybox, fs-supervise, fs-reboot-final, fs-reboot, fsb1-pace.sh, stock boot), a script with a debugfs mount refused, **three hidden debugfs mounts refused by the mount whitelist (quoted, through variables, through an octal escape) and a tty write in fs-idle.sh refused** (build review), an injected file refused, two builds with one nonce bit-identical, and **the candidate rebuilt with its own nonce and stamp: `9d3ad984…9bd914bd` again, identical cpio** (`fixtures/builder/candidate-rebuild.txt`) |
| whole image (`test-image.sh`, the candidate's own initramfs under qemu/bwrap, no DRM device) | **25/25** (`fixtures/image/RESULTS.txt`; below). Build review, in every scenario: the backlight node's write-closes counted by inotify (exactly 1 with p0, 0 otherwise) and the tty accounting (every capture line expected) |
| end to end with the host (`../host/test-host3c.ps1` section Z2) | every `fixtures/image/<scenario>/capture.raw` replayed through `fs-collect3c` with scripted keys and classified by `fs-classify3c`: **25/25 scenarios give the expected class** (conformant ones without replay divergence and with the recomputed `<prev>` = the recorded one; deviating ones diverge exactly at the write the 3c collector does not make); the `sim-*` captures are replayed with their replacement digest as the collector's integrity pin, and c-sim-all with the built-in pin stops after p0 (`RUN 1 NOT POSSIBLE (integrity)`, Z2.3); the candidate's MANIFEST passes `fs-observe3c`'s check (Z2.2) |
| host (`../host/test-host3c.ps1 -Regression -BeforeDir`) | **294/294** (`../host/test-host3c.output.txt`; incl. section BR for the build-review fixes, test-host3b 116/116 and test-host2 459/459 with identical result lines before and after) |

| scenario | what it shows (candidate image) |
|---|---|
| `c-nodrm` | genuine fs-pattern: r1 exit 10; r2 skipped `run1-supervisor`; p0's write to the fake node, read-back 127; every record VALID; the chain |
| `c-sim-all`, `c-markers`, `c-no-debugfs` | all four phases replayed (r2 quad_vig, r3 solid): VALID records, the device's sha16 = the host decode, markers (grammar, ≤ 64 B, order, `rec` right before the record), no access to the fake `/sys/kernel/debug` (inotify, every scenario) |
| `c-sim-r2-dma` / `c-sim-r2-reject` / `c-sim-active` / `c-sim-unclean` | r2 quad_dma committed, r3 runs / exit 50, r3 sent anyway: skipped `run2-supervisor` / exit 31 / r2 skipped `run1-close-not-clean` |
| `c-order`, `c-repeat`, `c-chain-bad`, `c-time` | `FSXE1 … ran=0 error=order / already-run / chain / time`, no marker, no record; `c-order` then sends r1: refused `order` too (the session is closed) |
| `c-usage-then-p0` | (build review) a malformed first command: `FSXE1 p=p0 ran=0 error=usage`; then p0: `order`; `/run/fsb3c/closed`, no phase directory |
| `c-pause` | run 1 "ended" just before r2: r2's go 2.64 s after it (bounded wait) |
| `c-pause-fault` | an implausible run-1 end time: r2 skipped `pause-fault` at once |
| `c-idle` / `c-idle-stuck` | reboot `collected` (token `idle`) at activity + 121.6 s / + 181.7 s with a "running" phase |
| `c-no-ack`, `c-ack-no-done`, `c-done-early` | `no-host-ack` at SHELL_READY + 150 s; `deadline` at T0 + 200 s (no phase: idle limit unarmed); `collected` within 3 s of fs-done |
| `c-probe-hang` | probes blocked after p0: r1 skipped `probe-late`, both probes `nosup`, records VALID |
| `c-no-backlight` | p0 write `nonode`: r1 skipped `p0-write-missing`, r2 `run1-not-run` |
| `c-record-too-large` / `c-step-fail` | `FSXE1 p=r1 ran=1 error=record-too-large lines=N max=1545` / `error=step1`, preceded by begin/go/end, no rec, no END |
| `c-sim-r3-hold` | `show-off-solid <c3[0:8]> 5`; go→end ≥ 5 s; probe3 mid ≈ 2.5 s after go |

In every scenario PID 1 rebooted by exec of `fs-reboot-final` (pid 1), `/run/fs.deadline` = T0 + 200,
the idle limit started before SHELL_READY, no probe output named a decoy node or debugfs, the backlight
node was written exactly once when p0 ran (never otherwise), and no stray byte reached the tty.

## 8. Changes from the stage-3b init (each justified)

| # | stage 3b | stage 3c | why |
|---|---|---|---|
| 1 | — | `/run/fs.deadline` = T0 + DEADLINE after `fs_hold_init` (builtins) | fs-phase's `time` refusal (DESIGN §5.2) |
| 2 | — | `/lib/fs/fs-idle.sh` started once before SHELL_READY | the idle limit (DESIGN §5.9) |
| 3 | `/bin/fs-display` (one runner, one record) | `/bin/fs-phase` (per phase) | DESIGN §5 |
| 4 | product `FrameShift stage3b` | `FrameShift stage3c` | identity |

Everything else in `init.sh` is stage 3b's (DEADLINE 200, ACK_WINDOW 150, ERR_DELAY 60, irq0).

## 9. Not exercised offline; open items

**Not exercised offline:** every real DRM ioctl after `open` (the mock model only), every commit,
whether the driver accepts a quad layout, the real capabilities blobs and topology, the close and
off→on paths, the backlight write's effect, the real interrupts and kernel log, the fan nodes, the
`card0` mknod, the 97-module load, configfs/UDC, the real reboot, the tty/USB timing of the paced
emission, PID 1 signal immunity, thermal behaviour, legibility.

**Open:** the reviews (DESIGN §12.6); the encode note of §4 (recorded in DESIGN §9.1, for the PM);
DESIGN §15 Q1 (a) and (d) are recorded (source + the v66 DT: zpos_max 10, PARALLEL multirect
auto-selected; nothing predicts a rejection);
the quest-kexec-q2 licence (closed 2026-10-12: GPL-2.0); the stage-3c rows of `../RECOVERY.md`, `../SIGNOFF.md` and
`../common/OUTCOMES.md` §10 (docs step, outside this package).
