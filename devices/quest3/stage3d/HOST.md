# Stage 3d - the host side (both Quest 3 units on v2.7)

**Status: DRAFT (2026-10-13, branch `feat/stage3d-host`, built on `feat/single-reading-userbuild`; offline only;
adversarial review GO-with-fixes, the fixes in §7; re-pointed 2026-10-14 on `fix/stage3d-modes`, §8; the standing
phase A, the carry-over and charging below 30.0 °C on `feat/host-carryover`, §9, not yet reviewed).** No device, adb, fastboot or COM port was used. It implements `README.md` §6 for the candidate
`build\stage3d\20261014T014738Z-<attempt nonce withheld>` (`fcca5ee7…4fb5`, nonce `<attempt nonce withheld>`, unspent then; spent on Unit 1 2026-10-14, J-144; fs-pattern
v0.7.1 `bfafad97…9a9a`). The first candidate (`20261013T065151Z-<attempt nonce withheld>`, `3d730337…c224`, fs-pattern v0.7)
is withdrawn (J-141: its nonce spent on Unit 2; v0.7 refused v2.7's 305 modes, MAXMODES 128). The PM's
steps: `WALKTHROUGH.md`; what the console asks and records, and the host pins: `../SIGNOFF-3d.md`.

## 1. Files (all in `devices/quest3/host/`; the stage-3c files are not edited)

| file | what |
|---|---|
| `fs-collect3d.ps1` | the collector. Dot-sources `fs-collect3c.ps1` (and through it `fs-collect.ps1`, `fs-classify3c.ps1`, `fs-session3c.ps1`) as a library; COPIES of the session, run, replay, config and summary functions with the stage-3d differences (header list). Live, replay, **rehearsal** (`-S3dRehearsal`). Parameters `S3d*` (M4) |
| `fs-session3d.ps1` | the prompts: `New-Fs3dInteract` (readings3d.txt), `Invoke-Fs3dResetQuestion` (new), `Invoke-Fs3dGap` (copy: the per-eye tilt, plainer lines) |
| `fs-classify3d.ps1` | the classifier (dot-sources `fs-classify3c.ps1`): the reset classes, the r2 checks, the per-eye layout/geometry/roll labels, the outcome, `Invoke-Fs3dClassifyDir`, the CLI (`C3d*`) |
| `fs-observe3d.ps1` | the observer (a copy of `fs-observe3c.ps1` after the single-reading fixes): stage-3d image and MANIFEST, the v2.7 baseline and vbmeta lines, the v0.7.1 pin, `-Serial` (no default), `checklist3d.json`, the no-gadget note |
| `fs-checklist3d.ps1` | the console checklist (a copy of `fs-checklist3c.ps1`: prefix `FsCl3d`, stage-3d texts, previews, rehearsal line) |
| `fs-nonceonly3d.ps1` | one nonce per run: opens both images (boot header, kernel, LZ4 ramdisk, cpio) and checks that a rebuilt candidate differs from the reviewed one only by the nonce in `/init`; dot-sourced by the observer, which requires it (§3) |
| `fixtures/stage3d/gen3d.ps1`, `fixtures/stage3d/replay/` | the synthetic session generator (copy of gen3c: s3d records, the reset, roll/eyes) and three canonical replays: `nominal-read`, `garbled-r3` (the rehearsal), `swapped-tilted` |
| `test-host3d.ps1` → its output (private) | the stage-3d suite (sections A-K, Y) |

`stage3d/tools/check-timing-3d.py` now reads the stage-3d host files (`fs-collect3d.ps1`, `fs-observe3d.ps1`) for its
host cross-check; `fixtures/check-timing-3d.txt` is regenerated (CONSISTENT, nothing pending).

## 2. README §6, item by item

1. **Image and MANIFEST:** `boot-stage3d.img`; title `FrameShift Quest 3 stage-3d image`; build root and ledger
   `build\stage3d\` (`attempted`, `abandoned`); sources `init.sh source`, `fs-phase.sh`, `fs-probe.sh`, `fs-idle.sh` of
   `stage3d\`; stock boot `e32f98c7…c024`, vendor_boot `bc0dd14d…2f5b`; and the new lines `vbmeta` (`aae4af3a…`),
   `vbmeta_system` (`28f5ccc9…`), `vbmeta digest` (`66b76196…f12a`), plus `/bin/fs-pattern` = the v0.7.1 pin. Any
   difference refuses the image, also at `-Preflight` (test-host3d G3, with the v0.7 pin among the refused; G6 on the
   real candidate and G6b on the withdrawn one, read only).
2. **Gadget:** `FS-<nonce>` as before; the product `FrameShift stage3d` is in the image (the host matches the serial).
   The fastboot serial is the run's `-Serial` (§4), never Unit 1 by default.
3. **Verbs and grammars unchanged:** the 3c verb table, FSPM1, FSXE1, FSK1, FSB1 parsers are reused unchanged.
4. **`exp=s3d_<ph>`** in the config, the replay, the classifier (`$script:S3dExp`). A 3c tool refuses a 3d session
   and vice versa (D8).
5. **r1 is not lit.** Its `go`/`end` markers print plain lines ("DISPLAY RESET running (it should stay dark)"), no
   LOOK/ENDED banner, no START/END sound, no per-eye readings, no dark check. **The one question** (PM J-130): after
   r1's record (valid, or a refusal with ran=1, or an FSB1-rejected record), "Anything visible during the reset?
   y = yes, b = no, it stayed dark, x = abort" (banner "DISPLAY RESET DONE - ONE QUESTION", the ANSWER sound). The
   keys are `y` and `b` (`b` = dark, as at the run-2 eye questions), never `n`, which aborts elsewhere (review 2
   MINOR-2): an `n` there is not an answer and not an abort; a line says what `y` and `b` mean and the question stays
   (B9). The answer is recorded (`FSR2 p=r1 item=seen obs=SEEN|NOT_SEEN`) and **never gates**: y and b both lead to
   run 2 (B1, A3). x aborts (no run 2). A timeout (30 s) ends the session safely like every prompt (an unanswered
   console is not a state in which to light run 2). **No question when the headset skipped the reset** (a valid record
   whose reset step is a skip: nothing was shown; review 2 MINOR-4, B10). During the reset, `x` is an abort (noted at
   once; the question is still asked, then no run 2); `n` is discarded (the question follows). After `x`/`n` in the
   LOOK cue: nothing runs. The reset answer's own key pressed again (held or doubled) is ignored as a repeat until run
   2's `go` marker and at least 600 ms after the answer (adversarial review MAJOR-1); after that, `x` and `n` abort as
   in stage 3c (p0 included).
   **Classes:** `RESET-DONE` (exit 0 `reset_done shown=0`, precondition `active`, the `reset_off` commit then a
   `reset_on_single|split` commit, both rc 0, post_state active 0 then 1, `reset_close close_rc=0`, buffer
   `black=1`), `ALREADY-INACTIVE` (exit 0 `already_inactive`, no commit), `RESET-NOT-DONE` (any other exit: 50, 60, 31,
   a hang). Never "SHOWN". `shown=1`, a commit on a non-black buffer, or `reset_done` without its facts is a runner
   inconsistency (INCONCLUSIVE).
6. **r2's skip reasons** are the device's (`p0-write-missing`, `probe-late`, `brightness-not-verified`,
   `run1-not-run`, `run1-supervisor`, `run1-not-reset`, `run1-stream`, `pause-fault`): r2's "previous phase clean"
   check uses exactly `gate_reset`'s facts (supervisor exit 0, exit `reset_done|already_inactive shown=0`); a run 2
   executed after a failed reset is a runner inconsistency. r2's pause is measured from the reset's end
   (`t0_ms + elapsed_ms`).
7. **r2 per eye:** r2's start record must carry `roll=21 eyes=swap`. The PM answers per eye (d/c/a/b, the 8
   characters), the dark check, then per eye: after d the **tilt first** (the PM's main goal, the 21-degree
   correction), then the F, then the bars; after c the bars only (review 2 MAJOR-1). The tilt: `0` level, `r`
   turned clockwise (right end lower), `l` turned counter-clockwise (left end lower), `?` can't tell (obs LEVEL /
   CLOCKWISE / COUNTERCLOCKWISE / UNKNOWN). **A timeout (30 s) at a tilt, F or bar question is recorded (TIMEOUT) and
   the next item is asked** (review 2 MAJOR-1: stage 3c ended the session there; its real run lost the left tilt and
   every right-eye item that way); an item is NOT_ASKED only when less than 10 s (LayoutMinSec) remain before the
   cut-off; x still ends the session safely; **on the run-3 path a layout timeout still ends the session safely**: no
   lit run 3 after an unanswered prompt (review 3 MAJOR-A, safety first; C6; the PM may decide otherwise); the run-3 rule is unchanged (rules 1-4 read the eye answers and the dark
   check, not the layout items; C6). A 0 bar names the mixer whose plane was expected there (eyes=swap: LM0 4, LM1 3,
   LM2 2, LM3 1; review 2 MINOR-5). "Can't tell" is `?` in the F prompt too (stage 3c used `0`), so `0` only
   ever means "level" in stage 3d (review MINOR-2). The classifier labels each eye against its own expectation (left 1|2,
   right 3|4, F upright, level): "as designed" / "the OTHER eye's picture: the eye-swap assumption is wrong" /
   half-turn / mirror / layout fault; and the summaries `GEOMETRY:` (the swap) and `ROLL:` (level in both eyes, or a
   remaining tilt with its direction per eye). Diagnostic, never a PASS. No expected order is shown to the PM.
   **Q7 fallback** unchanged: no bar-count prompt on the run-3 path.
8. **Integrity pin** `bfafad97c7ca11ef4e41a6be8aae4fde5ca529d8955d9b77d6fc603495049a9a` (fs-pattern v0.7.1, J-141; v0.7
   was `7c9fa98c…0674`) (collector p0 gate, classifier, observer MANIFEST check). A mismatch: "NOTHING RUNS (integrity)", fs-done, `INTEGRITY FAULT` (exit 12).
9. **Timing unchanged.** The r1 human window H_r1 stays 20 s: it now holds the one reset question (one key; the
   rehearsal measures it). So G = 34/68/82/64 and the per-phase limits are unchanged; `New-Fs3dCfg` states the
   constants and `check-timing-3d.py` cross-checks them against the device (CONSISTENT). `DESIGN_G`/`DESIGN_LIM` stay.
10. **Replay fixtures:** all 27 `fixtures/image` scenarios run through `fs-collect3d` replay and `fs-classify3d`
    (test-host3d F; the sim ones with the replacement's digest as the pin; with the built-in pin they are an
    INTEGRITY FAULT). `c-modules-refused` has an empty capture (no shell): nothing to replay (refused).
11. **Module index refusal:** when no gadget appears within the wait, `fs-observe3d` makes one more read-only
    `fastboot devices`; the unit back in fastboot is recorded as `NoGadgetNote` "consistent with the module index
    refusal (wrong build?) or an init failure; the reason is only in the device's RAM log" (G4).

12. **`opt_skipped` (the `eos` record; J-142 MINOR).** fs-pattern counts in `opt_skipped` every optional record it did
    not write, of two kinds: (1) since v0.7.1, mode records **left out by design** (a mode at index 48 or above that is not
    the expected 4128x2208@90 mode is not logged, only counted: v2.7's 305 modes give 257, the `-late` lists of 308 give
    258); (2) optional records **dropped by the budget** (`FSP_OPT_MAX` 38912 bytes, `FSP_OPT_MAX_SOLID` 10240): only
    after exactly one `step=opt_budget` record (`max`, `used`, `first_skipped`). So: no `opt_budget` record means nothing
    was dropped, and `opt_skipped` = the connector's modes - the mode records; an `opt_budget` record means the later
    optional records (property and blob logging) were dropped and are counted too. The host does not parse
    `opt_skipped`; the classifier's facts never rely on an optional record. Tested on the mock streams (test-host3d E3:
    reset-v27, reset-v27-late, quad-v27, quad-v27-late, solid-v27 by design; reset-max, quad-max by budget).

**Outcomes** (`fs-classify3d.ps1`, exit code): `PASS (machine side)` 10 = P0 OK, r1 RESET-DONE or ALREADY-INACTIVE,
R2 SHOWN-QUAD; `INTEGRITY FAULT` 12; stage 1 not PASS 13; `INCONCLUSIVE` 14; `NO-DISPLAY` 15 (r2); `DISPLAY FAIL` 16
(r2); `PRECONDITION UNMET: CRTC ACTIVE` 17 (r2 found the CRTC active after the reset); `RESET ONLY` 18 (the reset ran,
run 2 not run or skipped for another reason); `RESET NOT DONE` 19. A clean reset followed by the device skipping r2 for
`run1-not-reset` or `run1-supervisor` (its gate saw the reset NOT clean) is a host/device INCONSISTENCY (14), not RESET
ONLY (review 2 MINOR-4). **STAGE PASS** = the machine PASS plus r2 OPTICAL PASS (all 8
characters in each eye in run 2).

## 3. Both units, one nonce per run (J-133)

- `-Serial` is a parameter everywhere and has no default: the reading (`fs-checklist3d -Phase B -R1Serial`), the
  captures (`<withheld capture tool> -Serial` with `<withheld rows file>`, which names the unit as `{serial}`), the attempt
  (`fs-observe3d -Serial`). The observer refuses: no or an unknown serial; a reading of another unit; BA/BF summaries
  of another unit; and, at its one read-only `fastboot devices`, any attached device other than `-Serial` (G2).
- The candidate's nonce serves one run (after J-141: Unit 1 next, then Unit 2). The next run uses a rebuild with a fresh nonce
  (`build-image.sh` picks one) that `fs-nonceonly3d.ps1` compares with the reviewed candidate **by opening both images**
  (review 2 MAJOR-2): the same image size; the boot header page byte-identical except the ramdisk size (bytes 12-15);
  the kernel bytes and everything after the ramdisk identical; the ramdisk padding zero; both ramdisks unpacked here
  (LZ4 legacy, cpio newc; each equal to its MANIFEST's `ramdisk.lz4` / `ramdisk.cpio`), the same cpio size, the same
  entries with identical cpio headers and identical bytes, except `/init`, whose bytes may differ only where the
  reference's nonce stands (replaced by the candidate's, same size); every `## ramdisk files` line equal to the file
  in its own image; and, as before, every MANIFEST line and record file equal except the build time, the nonce, the
  hashes and the lz4 size. The reference must be a reviewed image (`-ReferenceSha`, default the current `fcca5ee7…4fb5`).
  **`fs-observe3d.ps1` requires it** (it dot-sources the tool): any image other than the reviewed candidate is refused,
  also at `-Preflight`, unless `Test-FsNonceOnly` against `build\stage3d\20261014T014738Z-<attempt nonce withheld>` passes;
  `observe.json` records `NonceOnly` (K3). Tested on real bytes (K1-K3): the candidate unpacked here equals its
  MANIFEST (cpio `23a7a95f…`, lz4 `c67d0d80…`); WSL `lz4 -l -9` reproduces its lz4 bytes; rebuilds made from it pass
  (only the nonce changed) or are refused (a changed busybox, module list, fs-supervise, fs-pattern, `/init` beyond the
  nonce, a larger cpio, another image size, a kernel, header or padding byte, ...). An lz4 size that crosses a
  4096-byte page changes the image size: rebuild once more. The one-attempt ledger refuses a nonce already used.
  **Delta review MAJOR-1 and a REAL rebuild (K4).** `ramdisk-scan.txt` lines 1-2 are written anew by every build (the
  scan time, the builder's temp path, the image's own hash): they may differ; line 2 must name the directory's own
  image; every other line stays identical. A real rebuild from master (`build-image.sh` in WSL, a fresh nonce,
  `FS_TEST_OUTBASE` in the test scratch: never `build\stage3d`, never ledgered) then showed two more differences that
  are not in the image: master's `build-image.sh` (b67c4023, git 7634871: a comment) and `module-list-check.py`
  (402525cd: check 5, review C MINOR-1) differ from the ones that built the candidate (605da89e / 35261647, git
  3453f94), so the MANIFEST's builder and tool hashes and `module-list-check.txt` (one more line, check 5's PASS)
  differ. The check accepted exactly these two REVIEWED builder pairs for that (first) candidate, and check 5's line
  only with the tool that has it. Since J-141 the pairs belong to each reviewed candidate (§8): the current candidate
  accepts only its own builder (`b90c0fbb…6c34` with `402525cd…f4c8`). With the one `TEST OVERRIDES` line that `FS_TEST_OUTBASE` adds removed from a copy, the real rebuild passes
  `fs-nonceonly3d` and `fs-observe3d -Preflight` (test-host3d K4: a new real build in every run, about 35 s).
- **Delta review MINOR-1:** an image that hashes to the reviewed candidate is accepted as such only in the reviewed
  directory (`20261014T014738Z-<attempt nonce withheld>`) with the reviewed nonce; a copy elsewhere (its MANIFEST nonce
  edited) or under another stamp is refused (K3).
- **The BA/BF must-be rows are machine-checked** (review 2 MINOR-1, `Test-FsObsMustBe`, before any device query):
  BA04 `_a`, BA16 `66b76196…f12a`, BA20 `user`, BA23 the unit's serial, BF02 `current-slot: a`, each row exit 0 with its
  file's recorded SHA-256; BA10 temperature 100-349, status 3/4/5, level above 50 (`Test-FsObsBa10`, as the second
  single-reading review; since J-145 status 2 only below 300). `observe.json` records `MustBe` (G7).
- The image applies to both units (same vbmeta digest `66b76196…f12a`, J-131). Since the v0.7.1 builder (J-141) its
  MANIFEST says "For the Quest 3 units on Horizon OS v2.7 (...; both units, J-131) only." (review 2 MINOR-6, fixed with
  the builder change). The text below is the first candidate's history: its MANIFEST said "For Quest
  3 Unit 2 … only" (review 2 MINOR-6). That sentence is written by `build-image.sh` (reviewed, merged) into the
  MANIFEST next to the image (it is not in the image). It is left as it is: changing the builder changes its recorded
  hash (a MANIFEST line), breaks the bit-identical rebuild fixture of `3d730337` and makes every rebuild differ from
  the reviewed MANIFEST, which the nonce-only check refuses. The host never reads the sentence; `IMAGE.md`, SIGNOFF-3d
  and the WALKTHROUGH say the image fits both units. A builder change can fix it with the next reviewed build (§6).

## 4. Rehearsals (no headset): two, both GO

1. **The garbled path:** `fs-collect3d.ps1 -S3dReplay devices\quest3\host\fixtures\stage3d\replay\garbled-r3\capture.raw
   -S3dOutDir <cycle>\rehearsal -S3dRehearsal -S3dReplayPin f6a9c3e2…1100`: the session in real time with the real
   banners, sounds and keys (reset `b`; run 2 `c` `c` `y`; run 3 `s` `s` `y`); the summary line `REHEARSAL: reset plus
   run-2 answers … s; go/no-go (SIGNOFF-3d A): GO (<= 40 s)` (the stage-3c Q7 bound), with the reset answer and the Q7
   note.
2. **The read path, TIMED** (review 2 MAJOR-1): the same with `...\replay\nominal-read\capture.raw -S3dOutDir
   <cycle>\rehearsal-read`. At run 2's go marker a rehearsal (never a live session) prints `REHEARSAL ONLY: in each eye
   you would read these 8 characters: …`; the PM answers as live: `d` and the characters in each eye, the dark check,
   then per eye any tilt, F and bar keys (the replay has no picture: no expected layout is suggested; review 3 MINOR-2).
   The run-2 window is real: the replay clock is the session clock, and a rehearsal uses the live give-up, 160 s after
   the collector starts (the stage-3c runs: 160.5 s and 159.0 s; a replay otherwise uses 185 s), so the cut-off is the
   earlier of run-2 end + 110 s and the give-up - 3 s, as live; the summary names the bound that applied (review 3
   MINOR-1). The summary prints `REHEARSAL (read path): run-2 answers took … s from the first
   prompt; N of 9 items answered`, the per-eye times, and `… the last answer … s before the cut-off (run-2 end + 110 s);
   go/no-go (SIGNOFF-3d A): GO (every item answered, at least 10 s to spare)` or NO-GO.

Phase A of the checklist requires both GO lines (checks `rehearsal` and `rehearsal-read`; H1, H2).

## 4a. The human window of run 2 at stage-3c speeds (review 2 MAJOR-1)

The device's cut-off is run-2 end + 110 s (`GapCapSec`, 10 s inside the 120-s idle limit); an item is asked only if at
least 10 s (`LayoutMinSec`) remain; each prompt waits at most 30 s. Speeds: the real stage-3c run (the left eye's `d`
and 8 characters 12.7 s, the right eye's 10.2 s, the dark check 2.5 s, the bars 20.7 s) and the stage-3c practice run
(the tilt 7.3 s, the F 8.4 s). Replayed with these key timings (test-host3d C7). The table gives the time each answer
was given, after the run-2 end; each question is asked when the previous answer is given (so the left bars question is
ASKED at +41.1 and ANSWERED at +61.8):

| item | left eye: answered at | right eye: answered at |
|---|---|---|
| reading + 8 characters | +12.7 | +22.9 |
| (dark check) | +25.4 | |
| tilt (asked first) | +32.7 (asked +25.4) | +69.1 (asked +61.8) |
| F | +41.1 (asked +32.7) | +77.5 (asked +69.1) |
| bars | +61.8 (asked +41.1, 69 s left) | +98.2 (asked +77.5, 32 s left) |

All 9 answered, the last 11.8 s before the cut-off: GO. With the stage-3c run's 30-s timeout at the left F (C7b):
left tilt +32.7, left F TIMEOUT +62.7, left bars +83.4, right tilt +90.7, right F +99.1, right bars asked with 10.9 s
left and TIMEOUT at +110: both tilts (the main goal) are answered. With stage 3c's order (bars, F, tilt) and its
end-on-timeout, the same run lost the left tilt and the whole right eye (its `readings3c.txt`). The margin at
stage-3c speeds is small (11.8 s): the timed rehearsal shows the PM's own speed before the run.

## 5. Tests and evidence

`test-host3d.ps1` (no device): A canonical replays, the transcript, the CLI replay, both rehearsals (A7, A8: the timed
read path); B the reset question (B9 the y/b keys and `n`, B10 a skipped reset); C the run-2 prompts (C4-C6 a timeout at
a layout item, C7 the human window at stage-3c speeds); D the classifier (D1 the reset/skip inconsistency, D4 the mixer
of a 0 bar); E the device's v0.7 / v0.7.1 mock streams (E1/E2 with the v2.7-shaped reset-v27, reset-v27-late, quad-v27,
quad-v27-late; E3 what `opt_skipped` counts); F all 27 whole-image captures end to end; G the observer (G7 the must-be
rows, G8 the nonce-only requirement; the real candidate's MANIFEST, read only from the main checkout); H the checklist
(both rehearsals), SIGNOFF-3d and the WALKTHROUGH, H7-H13 the standing phase A, the carry-over and charging below
300 (§9); I timing; J M4 and static checks; K the nonce-only check on real
bytes (K1-K3; needs the main checkout's candidate and WSL `lz4`); Y the stage-3c host files unchanged (skips when the
single-reading branch is absent, review 2 MINOR-7). Results: its output (private).

## 6. Open (for the review and the PM)

1. Battery status 5 ("full") on AC counts as "not charging" (the reviewed rule: 3, 4 or 5). Status 2 (charging) is
   accepted since J-145 only below 300 (30.0 °C) (§9).
2. The stage-3d image may light dim or dark in run 2 (`README` §7.1); the classifier still reports the machine
   result; the PM's description decides the follow-up.
3. On the user build the before/after compare cannot show that no partition byte changed (`<withheld document>`).
4. The live transport and the console were exercised only through replay and the stage-3c run; the stage-3d prompts
   have not met the PM (the two rehearsals are the first contact).
5. The MANIFEST's "Unit 2 only" sentence (§3): fixed by the v0.7.1 builder (J-141): "both units".
6. Phase A shows only the digits, F reference and red-field pictures. The as-seen, panels and mixer-map pictures,
   which show the expected bars and tilt, are offered only after the PM's description is recorded (WALKTHROUGH
   step 17; delta review MINOR-2). Point D3 no longer says the pattern "should look upright and level" (final
   review MINOR).
7. The human-window margin at stage-3c speeds is 11.8 s (§4a); a slower PM loses the last bar question, never the tilt.

## 7. Review 2 fixes (adversarial review of `e44f60c`, GO-with-fixes)

MAJOR-1 (tilt first, a layout timeout skips only that item, the window at 3c speeds, the timed read-path rehearsal
required by phase A): §2.7, §4, §4a. MAJOR-2 (the nonce-only check opens both images; the observer requires it): §3.
MINOR-1 (the must-be rows machine-checked): §3. MINOR-2 (the reset question y/b; what n does where, stated plainly in the
keys text and SIGNOFF-3d): §2.5. MINOR-3 (no expected bar order in the preview text): §6.6. MINOR-4 (no question after a
skipped reset; the reset/skip inconsistency): §2.5, outcomes. MINOR-5 (the mixer of a 0 bar): §2.7. MINOR-6 (WALKTHROUGH
step 9 says the command runs `fastboot boot`; the "Unit 2 only" wording): §3, WALKTHROUGH, IMAGE.md, SIGNOFF-3d.
MINOR-7 (section Y skips when the branch is absent): §5. The delta review (GO-with-fixes): MAJOR-1 (ramdisk-scan.txt
lines 1-2, the reviewed builder pairs, a real rebuild in K4) and MINOR-1 (the reviewed image only as the reviewed
directory) in §3; MINOR-2 (the as-seen, panels and mixer-map pictures only after the session: phase A shows three
pictures); MINOR-3 (§4a's table gives asked and answered times). A third (adversarial) review of these fixes: MAJOR-A (a layout
timeout on the run-3 path ends safely, §2.7), MINOR-1 (the rehearsal's give-up and cut-off as live, §4), MINOR-2 (the
rehearsal does not script the expected layout), MINOR-3 (the test output regenerated), MINOR-4 (the must-be rows read
only the command's stdout, an adb notice on stderr is ignored), N1 (the rehearsal path read from the Q7 record), N2
(the layout timeouts in the summary and session.json); N3 is covered by K3 (a real nonce-only rebuild accepted by the
observer's -Preflight). Also ported from the second single-reading review: strict UTC
parsing, the BA10 floor and level, `Reading.Ok` a boolean, the reading tied to the first BA after it.

## 8. The v0.7.1 candidate (J-141, branch `fix/stage3d-modes`)

The Unit 2 run (J-141) ended in a safe refusal: fs-pattern v0.7 allowed 128 modes (MAXMODES) and v2.7 reports 305.
fs-pattern v0.7.1 (`bfafad97…9a9a`) fixes it, and `fs-probe.sh` (`f0fda865…7173`; its one change vs stage 3c) counts
the 66 v2.7 mode-validation dmesg lines per probe point instead of keeping them, so the real panel/DSI lines stay within
the 80-line / 4096-byte budget. `build-image.sh` (`b90c0fbb…6c34`, with `module-list-check.py` `402525cd…f4c8`,
unchanged) pins fs-pattern and writes the both-units MANIFEST sentence. The new candidate is
`build\stage3d\20261014T014738Z-<attempt nonce withheld>` (`fcca5ee7…4fb5`, 44,875,776 bytes, nonce `<attempt nonce withheld>`; cpio
`23a7a95f…` (3,414,016 B), lz4 `c67d0d80…` (1,963,122 B); `/init` 15,973 bytes as before). It serves Unit 1 next;
Unit 2 then gets a nonce-only rebuild of it. The first v0.7.1 build `20261014T012519Z-2b2596964c0812b1` (`96cc15aa…3fad`,
builder `8870bbce…012c`, the stage-3c fs-probe.sh) was superseded before any boot (never booted; its nonce never used)
and is withdrawn.

- `fs-nonceonly3d.ps1` keeps a table of reviewed candidates (`$FsNoCandidates`): image hash -> directory, the builder
  pairs reviewed for it, and a withdrawal reason. The current candidate accepts only its own pair (b90c0fbb /
  402525cd); the superseded 96cc15aa (8870bbce / 402525cd) is withdrawn. The first candidate (3d730337, pairs 605da89e / 35261647 and b67c4023 / 402525cd) is withdrawn: kept for
  history, its CLI comparison never exits 0. A pair of another candidate is "not a reviewed builder version" (K2).
- `fs-observe3d.ps1` refuses a withdrawn candidate as the image or as the reviewed reference (G9); the first candidate
  is refused earlier anyway: its MANIFEST `/bin/fs-pattern` is v0.7 (G6b), and its nonce is in the ledger
  (`build\stage3d\attempted\<attempt nonce withheld>.attempted`, `attempt.lock`). The new nonce is not, so it is free.
- `fs-classify3d.ps1` and `fs-observe3d.ps1` carry the v0.7.1 pin; `fs-collect3d.ps1` takes it from the classifier.
  The SIGNOFF-3d pins of these three files are re-computed.
- test-host3d: G3 refuses the v0.7 pin; G6 the new candidate (unspent); G6b the withdrawn one; G9 the table;
  K1-K4 on the new candidate's bytes (nonces read from the MANIFEST). K4 builds with the main checkout's
  `build-image.sh`; before the merge, `-K4StageDir <this branch's devices\quest3\stage3d>` binds this branch's
  sources over the main checkout's path in a WSL `bwrap` (as the candidate was built), the main checkout unchanged.

## 9. The standing phase A, the carry-over, charging below 30.0 °C (J-143, J-145; branch `feat/host-carryover`)

The PM's decisions: phase A is accepted once and stays valid until what was accepted changes (J-143); the sound check
and the rehearsals carry over (J-143); a reading taken while charging counts below 300 (J-145). `fs-checklist3d.ps1` and `fs-observe3d.ps1` change, `fs-collect3d.ps1` gains `-S3dSoundCheck` and the made record of
its rehearsals, and the new `fs-carry3d.ps1` holds the tool set and the made record (shared by the collector and the
checklist); stage 3c is not touched. The PM's steps for a new run: the reading → B → BA/BF → E → the attempt (WALKTHROUGH steps 5 to 9).

**Where the records are (per PM, durable, gitignored):** `<repo>\captures\standing\`:
`phase-a.json` (+ `history\`), `carryover.json`, `speakers.json`. The per-cycle `checklist3d.json` A entry records
what it relied on.

**1. The standing acceptance.** The accepted content is five blocks: the questions A1-A3, the preview list (paths
written with `<repository>`, so a clone elsewhere hashes the same), the three preview pictures' SHA-256, the keys, D1 to
D14. Each block is hashed ("== title" and its lines, LF, UTF-8) and so is the whole text. A full acceptance (A1-A3 all
`y`) writes `phase-a.json` (schema `frameshift.fs-standing-a3d.v1`): the UTC time and PC date, the cycle, the blocks
with their SHA-256, the text SHA-256, and `ToolPin` = the SHA-256 of the `fs-checklist3d.ps1` that took it (its
SIGNOFF-3d pin; the host pins are checked first). Phase A of a later cycle:

| the record | phase A |
|---|---|
| intact, the same text and pictures (whatever the checklist version) | **no question**; the A entry `Acceptance.Mode = standing` names the record, its SHA-256, the checklist version relying on it (`ToolPin`) and the one that took it (`RecordToolPin`); the record is not rewritten |
| intact, another text or picture | only the changed lines (`- new:` / `- removed:` / `- picture changed, open it again:`), question **R1**; the record is rewritten |
| none | the full phase A (A1-A3); the record is written |
| unreadable, another schema, a malformed field, dated in the future, a stored block or text that does not match its own SHA-256 (edited), or no phase-A PASS entry of its originating cycle on this PC gave it | **STOP**, nothing asked, nothing relied on; the Arbiter moves it aside |

The earlier record is kept in `history\` on every rewrite. `n` or a timeout leaves the record unchanged. Review of
14107af, MINOR-1: the record is also tied to its originating cycle: a phase-A PASS entry of `<Cycle>\checklist3d.json`
that **gave** the acceptance (mode full or changes; delta review of 6f2973f, MAJOR-1: a later phase A of the same cycle
relying on it in mode standing names the same SHA-256 and is not the origin) must name the record's SHA-256, with its
`y` answers, written by the checklist version the record names, for the record's text. A record re-hashed by hand, made
up with `Save-FsCl3dStanding`, or copied from another PC **without its cycle folder** is refused (STOP); a copy made
together with its cycle folder is not detected. This ties the record to that
cycle's own record on this PC; it is **not** proof against a deliberate local forgery of both files (14107af's wording
"edited or forged" overstated what the hash check alone shows).

**How the standing acceptance places "A" in time.** Phase A is still run once per cycle, by the Arbiter, at the start
of the cycle (WALKTHROUGH step 2, before B). With the standing acceptance and carried-over passes it asks nothing and
writes an automatic PASS entry at that moment. That entry is the "A" of the observer's A, B, E order, which is
unchanged: the last A, B and E entries of the cycle must have passed in that order (A for this nonce), so running phase A
again between B and E still breaks the order (J-140).

**2. The carry-over.** Every sound check and rehearsal records when and with which tools it was made (review of
14107af, MAJOR-1: a file in the cycle carried no time and no tool hash and was taken on trust): `fs-collect3d.ps1
-S3dSoundCheck` writes `soundcheck.json` (schema `frameshift.fs-soundcheck3d.v1`, `MadeUtc`, `ToolSetSha256`; a
`fs-session3c.ps1 -SoundCheck` file no longer counts), and a rehearsal summary ends with `REHEARSAL MADE: <utc> with tool
set <sha256> replay <sha256> <path>` (`fs-carry3d.ps1`; delta review of 6f2973f, MINOR-1: the replay rehearsed must be
the expected one of its kind, `garbled-r3` for the garbled path and `nominal-read` for the timed read path, by path and
by the current SHA-256 of that replay). A pass counts **fresh** from this cycle's own file, or **carried over** (the latest
recorded pass of that kind by its made time, from `carryover.json`: path, SHA-256, tool-set SHA-256 and per-file hashes,
made time, PC date, cycle), and in both cases only unless:

- (a) the **session/collector tool set** changed: `fs-session3c.ps1` and `fs-collect3d.ps1` with every file they
  dot-source (`fs-native`, `fs-collect3c`, `fs-collect`, `fs-session3d`, `fs-classify3d`, `fs-classify3c`,
  `fs-classify`, `fs-classify3b`, `fs-carry3d`, `fs-proto`, `fsb1`; test-host3d H13 derives this closure from the sources) and the
  two rehearsal replays (`garbled-r3`, `nominal-read`: `capture.raw` and `.idx`). The whole closure is taken, not a
  judgement of which file affects a prompt or a cue; the refusal names the changed files;
- (b) it was made on **another calendar day** of this PC (the local date of its made time against today's), or is
  recorded in the future;
- (c) it was made before the PM's last declaration of **new speakers** (`-Phase A -NewSpeakers` appends the time to
  `speakers.json`): run the declaration once, then the sound check and rehearsals, then phase A again without the flag;
- or (carried) its file is missing, changed since (SHA-256), no longer passes its check, or its made record differs
  from the carry-over record.

Tests H11: the overnight collector change, rehearsal folders made 5 days earlier, a sound check made before
`-NewSpeakers`, all refused as fresh passes too.

**2a. Phase A's day and order (review of 14107af, MAJOR-2 and MINOR-2).** Phase A (and the passes it relied on) holds
for its own PC day only. Phases B and E and the observer refuse when A's `LocalDate` is not today (`new day: ... run step
2 (phase A) again`), so a next-day resume after a stand-down needs a new phase A (and, by rule (b), a new sound check and
rehearsals). On the same day, phase A refuses to run again once a B PASS follows it (before writing any entry, so the
cycle stays usable): a re-run between B and E asks nothing now and would be easy to do by mistake (J-140). Test H14.

A refusal prints `needed: <what to run> ... <why>` (WALKTHROUGH steps 3 and 4). Both kinds use the one tool set, so a
tool change forces both the sound check and the rehearsals.

**3. The observer** (`Test-FsObsStanding`, before any device query, after the existing pin check of every entry):
A's `Acceptance` must be present; mode `standing` with no question, or `full` / `changes` with the
questions it asked answered `y` and the record written in this cycle; the standing record still has the SHA-256 phase A
relied on, is intact (its blocks and text re-hashed here), holds phase A's text SHA-256 and is named by its originating
cycle's phase-A PASS entry (as above); A names the pinned checklist as the version relying on it (`ToolPin`) and the
record's own version (`RecordToolPin`); A's PC day is today; every sound check / rehearsal file A relied on still has its SHA-256, the same tool-set SHA-256 as A, and
A's PC date. Tests H7 (positive, A in time) and H8 (eight refusals).

**4. Charging below 30.0 °C (J-145).** Phase B (`battery-rule`, replacing `not-charging`): status 3, 4 or 5 below 350
(unchanged), or status 2 only below 300; status 1 never. The observer applies the same rule (`Test-FsObsBatteryRule`)
to B's recorded reading and to BA10. Everything else is unchanged: the typed-text parsing, the unit binding, the
900-s reading-to-BA window, the reading tied to the first BA. Boundaries tested (H12): 299/2 and 100/2 pass, 300/2
and 349/2 fail; 349/3, 4, 5 pass, 350/3, 4, 5 fail; BA10 likewise.

**5. Open (for the review and the PM).**

1. Decided (PM, after review of 14107af): a change of the checklist code alone, with word-for-word the same text and
   pictures, asks nothing; the A entry records which checklist version relied on the standing acceptance. (14107af had
   a renewal question R2; removed.)
2. Since the review fixes, every pass carries its own made time and tool set; a summary or sound check written by the
   tools of 14107af or earlier has no made record and does not count (run it again).
3. The device-side J-142 MINOR (fs-probe's filter could also hide an fps-90 mode error) waits for the next image build.
4. `captures\standing\` is local to this PC (gitignored, like `captures\`). A copy on another PC is refused unless its
   originating cycle folder is copied too (then it is not detected), so a second PC normally starts with a full phase A. The link to the originating cycle shows
   that the record matches that cycle's own entry on this PC; it does not prove that nobody edited both files.
