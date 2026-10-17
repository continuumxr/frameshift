# Sign-off reference - Stage 3c run: what the console checklist asks and records (J-118)

**Status: DRAFT** (from `stage3c/DESIGN.md` revision 3, §13; integration pass 2026-10-11; build-review
fixes 2026-10-12, DESIGN "Build-review fixes"; Q7 fallback and PM rehearsal feedback 2026-10-12, host
files only, DESIGN "Q7 fallback and PM rehearsal feedback"; **console checklist 2026-10-12, PM decision
J-118**, host files only, DESIGN "Console checklist (J-118)"; **single temperature reading 2026-10-13, PM
J-125/J-126**, host files only, DESIGN "Single temperature reading (PM, J-125)"). The reviews are done (J-111..J-114). Usable
once the PM confirms the image below (or a later rebuild, which replaces the nonce, the hash and the host
pins). The fs-pattern v0.6 pin is recorded in `host/fs-classify3c.ps1` (`$script:S3cPatternPin`). The
section "Common to all trials" of `SIGNOFF.md` applies as well.

Image `boot-stage3c.img` SHA-256
`9d3ad98400ac94f42b291a66b0420576df5ad8ee447e831d971fcaba9bd914bd`, nonce `<attempt nonce withheld>`
- **CANDIDATE** (`build\stage3c\20261012T010256Z-<attempt nonce withheld>\`, `stage3c/IMAGE.md`; fixture-tested offline only; the
build-review rebuild, which withdraws `e1856cd2...0aad90` / `3296cd623cc7da0f`). fs-pattern v0.6
binary (`/bin/fs-pattern` in the image, `stage3c/build/fs-pattern`): `066bdc3ee01e5974518f96e8311c071c8f3aed302cadefa42c1273d5196b27bc`. One temporary boot (`fastboot boot`), no retry, Unit 1
(`QUEST3UNIT1`), slot A. Results go to the Chair afterwards in FS-A-012.

**No sheet to tick any more (PM decision J-118).** The PC asks each confirmation at the moment it
applies and records the answer: `devices\quest3\host\fs-checklist3c.ps1` runs three times per cycle
(`-Phase A` before BA, `-Phase B` after the temperature reading, `-Phase E` immediately before the attempt;
`stage3c/WALKTHROUGH.md` gives the commands). Each run appends one entry to `<cycle>\checklist3c.json`
and `<cycle>\checklist3c.txt`: the automatic checks with their results, the exact text of every
question, the answer (`y`, `n`, `timeout`) and the UTC times it was asked and answered. Any `n`, any
timeout (**15 minutes per question in phase A**, 5 minutes in phase E) or any failed check prints
`STOPPED. Nothing was sent to the headset. Tell the Arbiter: <reason>` as its last line and exits 1:
nothing is booted. The checklist sends no device command and uses no network. Both files go to the
Chair with the cycle's captures (the same evidence the sheet gave). Console lines are wrapped at 90
characters (a long path stays on one line); the files keep every text unwrapped.

`fs-observe3c.ps1` **refuses the attempt** (exit 2, before any device query, the dwell gate and the
attempt registration) unless `<cycle>\checklist3c.json` (found from `-BaSummary <cycle>\BA\SUMMARY.txt`
in `<cycle>\`, or given with `-ChecklistFile`) holds the last entries of phases A, B and E as passed,
A for this image's nonce, in the order A, B, E, and E (presence) **at most 300 s old**; and also:
every entry was written by the copy of `fs-checklist3c.ps1` pinned in the table below (its
`ToolSha256`); phase B's single temperature reading is recorded as passed, three digits from 100 to 349 with the
battery status exactly 3, 4 or 5 (re-checked by the observer as text), taken on this attempt's unit
(`-Serial`, no default), and **at or before BA's start and at most 900 s (15 min) before it** (so after
an abandoned cycle an old reading does not carry over to a new BA); BA's own BA10 `dumpsys battery`
row is below 350 with status 3, 4 or 5; and phase E started at or after BF's start. The PM still types
the nonce into `fs-observe3c.ps1 -ConfirmNonce`.
This file is the reference of what the console asks and prints; the lines in the lists below are
printed verbatim (a test checks that they match the script).

---

## A. Before BA - `fs-checklist3c.ps1 -Phase A` (nothing below touches the device)

The PM runs these first (WALKTHROUGH steps 1 to 4), then the checklist verifies them from the files:

- **Host pins match, checked FIRST** (DESIGN §12.4; before the sound check and the rehearsal,
  which run these files). From the repository root, in `powershell.exe`:

  `Get-FileHash -Algorithm SHA256 -LiteralPath devices\quest3\host\fs-collect3c.ps1, devices\quest3\host\fs-session3c.ps1, devices\quest3\host\fs-observe3c.ps1, devices\quest3\host\fs-classify3c.ps1, devices\quest3\host\fs-checklist3c.ps1, devices\quest3\host\fs-collect.ps1, devices\quest3\host\fs-classify.ps1, devices\quest3\host\fs-classify3b.ps1, devices\quest3\host\fs-native.ps1, <withheld capture tool>, devices\quest3\host\fs-miscrule.ps1, devices\quest3\stage1\fs-proto.ps1, devices\quest3\common\host\fsb1.ps1, devices\quest3\common\tools\fsb1.py, devices\quest3\stage3c\tools\check-timing-3c.py | Format-Table Hash, Path -AutoSize | Out-String -Width 400 | Tee-Object <cycle>\host-hashes.txt`

  `Get-FileHash` prints **upper-case** hex; the table is lower-case (the checklist compares
  case-insensitively). The checklist (check `host-pins`) requires every file of the table in
  `host-hashes.txt`, at this repository's path, with the pinned hash, and the working file still
  equal to its pin. Any difference: STOP, nothing else is run (not even the preflight), nothing is
  booted.

  <!-- host pins (console checklist J-118, 2026-10-12: fs-checklist3c new, fs-observe3c re-pinned; review fixes 2026-10-12: both re-pinned; single temperature reading J-125, 2026-10-13: both re-pinned; review fixes 2026-10-13: fs-checklist3c, fs-observe3c, fs-capture re-pinned; second review 2026-10-13: the same three re-pinned; recompute after any host-file change) -->
  | file | SHA-256 | kind |
  |---|---|---|
  | `devices\quest3\host\fs-collect3c.ps1` | `b7ec42ce5d16b4e4b59141d7387bfd79e9836c24ae68dd66aefe19727f764e33` | 3c, new |
  | `devices\quest3\host\fs-session3c.ps1` | `a7db33bdc460b0416a7c4bda23fa68cbea9dffdf11a6d6313491963cc90486f3` | 3c, new |
  | `devices\quest3\host\fs-observe3c.ps1` | `76b47cdf04076b2d4c404f1433ee52f047449fa23cb99f8b2b2ab9d8ba504f42` | 3c, new (console checklist gate, J-118; single temperature reading tied to BA, J-125; presence to BF, tool pin) |
  | `devices\quest3\host\fs-classify3c.ps1` | `351ac4e4ef7106e2e3deccf25ebb6d04397c679ce34ffaedd7208132cb70d684` | 3c, new (fs-pattern v0.6 pin inside) |
  | `devices\quest3\host\fs-checklist3c.ps1` | `df2ba38b1756618ab45f99a16b04b6fcf1baa3ac6a8b70554212070c414ea244` | 3c, new (console checklist, J-118; review fixes; single temperature reading, J-125) |
  | `devices\quest3\host\fs-collect.ps1` | `2b90d641a15065da522e885df6cb627cd01e48608f7a20faea4cd07698068089` | reused, pinned (dot-sourced) |
  | `devices\quest3\host\fs-classify.ps1` | `ed5d07eabe2568853800d24e5065f0817af64acdd0c2e633426fd40a71138380` | reused, pinned (dot-sourced by fs-classify3c) |
  | `devices\quest3\host\fs-classify3b.ps1` | `aa0db5173c9fcb6a957bd62f49cc992d4bf55e547cdf24f77964ed792949b649` | reused, pinned (dot-sourced via fs-classify) |
  | `devices\quest3\host\fs-native.ps1` | `101ddfb15d35986705692f973c0ad74c5797dfb82e9947d719fea1eed7a99b80` | reused, pinned |
  | `<withheld capture tool>` | `72c0f3bfa1647316b7c0d2c92b86fce2125118f72273ba5bde93e18b59227eca` | revision 10 (review MAJOR-3, 2026-10-13: {serial}, shell id, the persist refusal, #NOT-CAPTURED; second review MINOR-4: -Serial required, default file <withheld rows file>) |
  | `devices\quest3\host\fs-miscrule.ps1` | `3199d8f948360f347c42d7938715a603f7c64940bff60d7a891bdf1b71e78bd7` | reused, pinned |
  | `devices\quest3\stage1\fs-proto.ps1` | `52e007eb6c9ced48aacd5fe42e8bfd5e988e4003dcd3b662ea1e68429e09ed85` | reused, pinned |
  | `devices\quest3\common\host\fsb1.ps1` | `1f84c633e8cf358fce3e006cef996bae9b372ee2914a97a0c5ab864312f0a703` | reused, pinned |
  | `devices\quest3\common\tools\fsb1.py` | `e0e11ee1d98a7537ac1b0df443409bd5de76e9b7d352bba4da75698d7708da57` | reused, pinned |
  | `devices\quest3\stage3c\tools\check-timing-3c.py` | `780dcb93cac70b56e3f607214a6d254bbccb7bd37495cb8c6ef89ab4fd6e64b8` | 3c, new |
  <!-- end host pins -->
- **Preflight** (check `preflight`): the checklist runs `fs-observe3c.ps1 -Image <...>\boot-stage3c.img
  -Preflight` itself (MANIFEST, image hash, slot-A baseline, the hashes of `stage3c/init.sh`,
  `fs-phase.sh`, `fs-probe.sh` and `fs-idle.sh`, a fresh nonce; no device action) and requires
  `preflight OK`. The nonce it reports is recorded; the attempt must use the same one.
- **Sound check passed** (check `soundcheck`): `<cycle>\soundcheck.json` from `fs-session3c.ps1
  -SoundCheck -SoundCheckDir <cycle>` with `"Pass": true` (I heard and named START, END, ANSWER,
  FINISH and ALARM, identified three unnamed sounds, and the key-reach test passed one-handed).
  **This check is the only protection against a silent audio failure during the session** (a
  failing sound falls back to the system sound and a bell and is logged, but nothing stops the
  session for it): the PC speakers it was run on stay the output, at the same volume, and are not
  changed before the boot.
- **Rehearsal passed (go/no-go, Q7)** (check `rehearsal`): `<cycle>\rehearsal-2\summary.txt` (or
  `-RehearsalDir`) from `fs-collect3c.ps1 -S3cReplay
  devices\quest3\host\fixtures\stage3c\replay\garbled-r3\capture.raw -S3cOutDir <cycle>\rehearsal-2
  -S3cRehearsal -S3cReplayPin f6a9c3e2b1d0a4958877665544332211ffeeddccbbaa99887766554433221100`,
  answered on the garbled path (run 1 `b`, `b`, `y`; run 2 `c`, `c`, `y`, no bar question; run 3
  `s`, `s`, `y`; then `s`), must hold the line `REHEARSAL: run-1 plus run-2 answers ... s; go/no-go
  (SIGNOFF-3c A, Q7): GO (<= 40 s)` (≈ 6 s planning slack of DESIGN §9.4) and the Q7 note `not asked
  (Q7 fallback)`, which only the pinned (Q7 fallback) files write. The first rehearsal (2026-10-12,
  `captures\<attempt nonce withheld>\rehearsal\`: 66.6 s) was NO-GO; it does not count.
- **Previews present** (check `previews`): the six files below exist.

Then it prints and asks (each answer `y` or `n`; another key is ignored; keys pressed before the
question are discarded). Under each question it prints `Press y for yes or n for no (15 minutes).`
(phase E: `(5 minutes).`):

**THE SIX PREVIEW PICTURES**, then question A1 `Have you opened and looked at the six preview pictures listed above? (y/n)`.
The console prints the absolute paths of this checkout (`<repository>` below):

```
Open each of these six pictures (paste the path into File Explorer) and look at it:
1. <repository>\devices\quest3\stage3c\fixtures\preview\pattern-v0.6-3f9c07ab-viewer-1032x552.png
   The test pattern as one eye should see it: the bar groups and the F letters.
2. <repository>\devices\quest3\stage3c\fixtures\preview\pattern-v0.6-3f9c07ab-mixermap-1032x552.png
   Which part of the screen each bar group belongs to, and how many bars it has.
3. <repository>\devices\quest3\stage3c\fixtures\preview\pattern-v0.6-3f9c07ab-scanout-4128x2208.png
   The whole picture sent to the screen (both eyes side by side).
4. <repository>\devices\quest3\stage3c\fixtures\preview\pattern-v0.6-3f9c07ab-digits-left.png
   The 8 characters to read.
5. <repository>\devices\quest3\stage3c\fixtures\preview\F-reference-u-i-m-v.png
   How an F can look: upright u, half-turn i, mirrored m, flipped top to bottom v.
6. <repository>\devices\quest3\stage3c\fixtures\preview\solid-red-v0.6-viewer-1032x552.png
   The plain red field of run 3.
Through the lenses the pattern will look turned by about 21 degrees and shifted toward the nose; that is expected.
```

**THE KEYS (what to press for what you see)**, then question A2 `Do you know which key to press for each thing you might see (list above)? (y/n)`:

- Per eye (runs 1, 2): a = light, no pattern; b = dark; c = garbled; d = I can read the characters, then the 8 characters (Backspace corrects; Enter needs all 8; Esc goes back to the a/b/c/d choice); x = abort, on every question (Ctrl+C is the same as x).
- n (light still visible) is a key of the dark check only (y dark / n light visible / x). At the eye questions it does nothing, so light seen there means x. n pressed while a run is showing is taken as x.
- After run 2, only when run 3 does not follow (an eye read the characters, an eye gave the wrong characters, or the run did not commit cleanly): the bar counts, i.e. next to each of the two F letters (below it when upright) a row of 1 to 4 bars: how many at the LEFT F, then at the RIGHT F (two keys 0-4, 0 = none visible; Backspace corrects; no Enter); after d also the F u/i/m/v/0 and the line l/r/0. On the run-3 path no bar question is asked (Q7 fallback).
- Run 3: r = all red; p = partly red; u = one other colour; s = same as run 2; g = different garble; b = dark.
- Every answer is echoed on the console; a key pressed twice quickly counts once at the next question. 30 s per prompt; a timeout or x ends the session safely (after an x during a run I am still asked whether the panels are dark).
- I tap keys, never hold them, and wait for each answer's echo before the next (a held key can auto-repeat). I do not click into the console window (QuickEdit is switched off for the session anyway).

**WHAT I ACCEPT (points D1 to D14)**, then question A3 `I have read points D1 to D14 above and I accept them (y/n)`:
the list of section D below.

## B. Single temperature reading - `fs-checklist3c.ps1 -Phase B` (PM, J-125; replaces the 10-minute pair of 3b B)

One reading (`adb -s <serial> shell dumpsys battery; [DateTime]::UtcNow.ToString('o')`, read-only, taken
with the PM; the time is **the PC's UTC at the reading**, the last line printed). The Arbiter runs phase B
with it: `-R1 <tenths of °C> -R1Utc <UTC> -R1Status <the status: line> -R1Serial <the unit's serial>`
(optionally `-R1Charge`, the level in percent), each **typed exactly as printed and taken as text**
(review MAJOR-1: nothing is rounded; `36.2`, `0` or a status `2.6` is malformed). Needs phase A passed.
The checklist records the reading and the rule; no question is asked. **The rule:**

- well-formed (check `reading-input`): the temperature three digits, the time `yyyy-MM-ddTHH:mm:ss[.f]Z`,
  the status one digit 1-5, the serial 6-32 letters and digits, the charge 0-100 if given;
- the temperature from 100 to 349 (10.0 to 34.9 °C; 350 = 35.0 °C and above fail) (check `range-100-349`);
- the battery is **not charging** at that moment: `status` 3 (discharging), 4 (not charging) or 5
  (full). Status 2 (charging) fails, and so does 1 (unknown) (check `not-charging`);
- the unit is one of the two Quest 3 units, Unit 1 `QUEST3UNIT1` or Unit 2 `QUEST3UNIT2` (check
  `known-unit`; review MAJOR-2). The observer requires it to equal the attempt's `-Serial`;
- the reading is not in the future: at most 60 s ahead of the PC's clock (check `not-in-future`; the
  time is the PC's own UTC, so only a typing delay is absorbed);
- the reading is **at most 15 minutes (900 s) before BA starts**. Phase B already refuses a reading
  more than 900 s old, compared exactly (check `at-most-15-min-old`). The observer refuses the attempt
  if the reading is after BA's start or more than 900 s before it, if the reading or status recorded
  in the file does not pass the same rules, if it was taken on another unit, or if BA's own BA10
  `dumpsys battery` is not below 350 with status 3, 4 or 5.

Otherwise: STOP. Wait (unplug the charger if the battery is charging), take a new reading and run
`-Phase B` again. Go on to BA promptly.

## C. BA, then BF (unchanged from 3b C; the dwell ≤ 300 s is enforced before the boot)

No checklist phase: `<withheld capture tool> -Phase BA -Nonce <nonce> -Serial <serial> -CommandsFile
<withheld rows file>` must print `PHASE BA OK` (BA10 level > 50,
temperature 100 to 349 and status 3, 4 or 5; the observer re-checks BA10's temperature, status and level from
the capture at the attempt; **the 5-minute dwell starts now**), then after `adb -s <serial> reboot bootloader`,
`<withheld capture tool> -Phase BF -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file>`
must print `PHASE BF OK` (BF02 `current-slot: a`). `-Serial` has no default (second review MINOR-4: `<withheld capture tool>`
refuses without it); without `-CommandsFile` it uses the user-build file (both units run the v2.7 user build,
J-131/J-133); the old root-shell `<withheld rows file>` only when named. Item D14 below is what the PM accepted about the
dwell gate.

## D. What I accept (printed by phase A before question A3)

- D1. Before run 1 the headset sets the screen brightness once, to level 127, which should give about 4.1 % of full backlight. That figure comes from reading the driver code; nobody has measured the light. The level is read back before each run.
- D2. The screen may light up to three times: run 1 for 3 s (a wake-up step, expected to stay dark); run 2 for 10 s (the new screen layout; if the driver refuses it, nothing lights in run 2); and run 3 for 5 s, only if I report run 2 as garbled or as light without a pattern (a plain red field, about as bright as the pattern on average and not brighter; an estimate, not a measurement). At most 18 s of light in total.
- D3. Run 1 repeats last time's screen setting on purpose, as the wake-up step; last time it stayed dark. If it lights this time, I may see garbled stripes for 3 s at the same low brightness. Runs 2 and 3 never show that old setting (they may only test it without showing it); they can show only the new four-part layout.
- D4. Runs 2 and 3 use a new four-part screen layout, its parts stacked in the same order as normal Android (my decision J-109), set in the same single reviewed step. No hidden driver debug files are opened (J-109). Nothing else new is written.
- D5. The screen is deliberately switched off and on again up to two times; this has never been tried on our test boot. The headset itself waits at least 2 s before each. The fan may stop and start each time.
- D6. The headset itself times each lit period. Pressing x cannot shorten a period that is already running; it ends the session after it. I may look away at any time.
- D7. The pattern will look turned by about 21 degrees, perhaps differently in each eye, and shifted toward the nose and upward. That is expected and is not corrected in this test.
- D8. If the screen does not go dark when a run ends, the last picture may stay until the end command (fs-done; my n at the dark check sends it at once), the idle limit (120 s after the last activity) or the deadline (about 200 s after the test program on the headset starts, with a last safety stop 1 s later). These are not guaranteed screen-off times; switching off by hand (RECOVERY.md) always remains.
- D9. Questions appear only after a run has ended and the headset's report of it has arrived. I answer from what I saw. The console shows none of the headset's own results until all my answers are in. The headset's results and what I saw are reported separately. What run 3 suggests, and the names given to the layouts, help explain the result; they are not a pass.
- D10. If a run's report does not arrive, or the console shows a red NO RECORD / SHELL STATE UNKNOWN / NO fs-done banner with the ALARM sound, nothing more is sent: I look away and wait; the headset recovers by itself at the idle limit or the deadline.
- D11. Console window closed, or the collector stopped: I look away; the headset recovers by itself within 120 s without activity (the idle limit) or at the deadline (about 200 s after the test program starts). Every answer given so far is already saved (readings3c.txt).
- D12. If the console shows RUN 1 NOT POSSIBLE (integrity): the pattern program on the headset is not the reviewed one; nothing lights, and the end command (fs-done) follows.
- D13. No number is claimed for eye safety; "no light seen" does not mean that no light was emitted.
- D14. Time limit: fs-observe3c.ps1 refuses to start the test boot if more than 300 s (5 minutes) have passed since BA started (checked before the attempt is recorded; always on in stage 3c). Then nothing is started, the image's one-time code (nonce) stays unused, a record of the abandoned cycle is written (build\stage3c\abandoned\), and I go back to Android for a new temperature reading and a new BA/BF.

## E. Presence - `fs-checklist3c.ps1 -Phase E` (after BF, immediately before the attempt)

Needs phases A and B passed. It prints **PRESENCE** and **AFTER THE SESSION**:

- I am present, headset in hand, power button reachable, keyboard under one hand; the collector runs in powershell.exe (a console window, not ISE) with sound on, on the PC speakers and at the volume of the sound check.
- If anything is unexpected: x (at the dark check, n), look away and wait; the headset recovers by itself (the end command fs-done, the idle limit of 120 s, or the deadline about 200 s after the test program starts). Switch off by hand (power button) only as RECOVERY.md says.
- Next: paste the attempt command at once. fs-observe3c.ps1 refuses the attempt if this presence check is more than 300 s old, or if more than 300 s have passed since BA started.
- After the session: AF immediately on return to fastboot (<withheld capture tool> -Phase AF -Serial <serial>), then fastboot -s <serial> reboot, then AA promptly in Android.
- AA10 temperature at 400 (40.0 deg C) or more: shut down at once (procedure as 3b F), do not wait for anything else. Even below 400, follow-up readings at +5 min and +10 min, then every 5 min while it rises and stays below 400; the highest observed reading is recorded. Shutdown and unplug are recorded as two separate observations.

and asks, both must be `y`:

- E1 `Are you physically at the headset now? (y/n)`
- E2 `Can you reach the headset's power button now, and do you know when to use it (RECOVERY.md)? (y/n)`

Then, within 300 s: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-observe3c.ps1
-Image <...>\boot-stage3c.img -Serial <serial> -ConfirmNonce <nonce> -BaSummary <cycle>\BA\SUMMARY.txt -BfSummary
<cycle>\BF\SUMMARY.txt -ThenCollect`, with `<cycle>` = `captures\<nonce>` (`<withheld capture tool>` without
`-CapturesRoot` writes `captures\<nonce>\<phase>\`; the observer finds `<cycle>\checklist3c.json`
itself). If more than 300 s have passed, run `-Phase E` again first. After a dwell refusal
(WALKTHROUGH step 10): a new temperature reading (`-Phase B`), BA/BF with `-Serial <serial> -CommandsFile
<withheld rows file> -CapturesRoot <cycle>\retry-1` (the default directory
already exists; the observer refuses a reading taken before an earlier BA of the cycle), `-Phase E`, and the attempt with
`-BaSummary <cycle>\retry-1\<nonce>\BA\SUMMARY.txt -BfSummary <cycle>\retry-1\<nonce>\BF\SUMMARY.txt -ChecklistFile <cycle>\checklist3c.json`.

## F. After (printed by phase E; recorded by the captures, not by the checklist)

- **AF immediately** on return to fastboot (`<withheld capture tool> -Phase AF -Nonce <nonce> -Serial <serial> -CommandsFile
  <withheld rows file>`), then `fastboot -s <serial> reboot`, then AA promptly in
  Android (the same command with `-Phase AA`).
- AA10 temperature and UTC from the AA capture. **At ≥ 400 (40 °C): shut down at once** (procedure
  as 3b F), do not wait for anything else.
- At least one scheduled follow-up reading even if AA10 is below 400: +5 min, +10 min; continue
  every 5 min while it rises and stays below 400. The Arbiter records each reading with its UTC time
  and the **highest observed reading** in `<observe dir>\notes.txt`.
- Shutdown and unplug recorded as two separate observations (3b F).
- My free-text description goes verbatim into `notes.txt` (corrections to a recorded key go
  there too, next to the key). Only then the Arbiter runs `fs-classify3c.ps1 -C3cDir
  <observe dir>\collect -C3cObserveDir <observe dir>` (the v0.6 pin above is built in) and
  shows the machine results. The collector's own summary is in `<observe dir>\collect\summary.txt`
  (shown on the console only when I press `s` after the session).

## What the checklist records (for the Chair)

`<cycle>\checklist3c.json` (schema `frameshift.fs-checklist3c.v3`; v2 since the single reading, J-125; v3 since the reading is typed text with the unit, review MAJOR-1/2): `Entries`, one per run, each with
`Phase`, `Result` (`PASS` or `STOP`), `Why`, `StartUtc`, `EndUtc`, `ToolSha256` (the checklist's own
SHA-256, to compare with the pin above; the observer requires it equal to the pin for every entry),
`Checks` (`Name`, `Ok`, `Detail`), `Blocks` (each printed block: `Title`, `Lines`, `Sha256` of the
title line `== <title>` and its lines, unwrapped, joined with LF, UTF-8), `Questions` (`Id`, `Text`,
`Answer`, `AskedUtc`, `AnsweredUtc`, `TimeoutSec`); phase A adds `Image`, `Nonce`, `ImageSha256`;
phase B adds `Reading` (`R1`, `R1Utc`, `R1Status`, `R1StatusName`, `R1Charge`, `R1Serial`, `R1Unit`,
`AgeSec`, `Rule`, `Ok`; the values as typed text, schema v3). `<cycle>\checklist3c.txt` holds the same, one line per check, block and question. A STOP
entry stays in the file; a later passing run of the same phase supersedes it (the observer reads the
last entry of each phase). Ctrl+C during a phase writes it as STOP (interrupted); the question being
asked is recorded with the answer `interrupted`. `observe.json` records `ChecklistFile`,
`ChecklistSha256`, `ChecklistTxtFile`, `ChecklistTxtSha256`, `ChecklistToolPin`,
`ChecklistPresenceUtc`, `ChecklistPresenceAgeSec` and `ChecklistReadingToBaSec`, the unit (`Unit`) and BA10's
`Ba10Temperature`, `Ba10Status`, `Ba10Level`, `Ba10Sha256`, and `observe.log` the gate's line.

---

### Host notes for the reviewers (not for signature)

- The collector writes, in `<observe dir>\collect`: `capture.raw` + `capture.raw.idx` (with
  `N … phase-end p=<ph>` lines marking each phase slice's end), `phase-<ph>.raw`, `session.json`
  (per-phase facts, guards, readings, events, sounds played and the five WAV SHA-256),
  `readings3c.txt` (FSR2 lines, DESIGN §8.5; appended at every answer, with a `session.json`
  checkpoint, so a closed window keeps them), `summary.txt` (the machine summary).
- FSP1 plan lists are `.`-separated with no %XX on both sides (`quad_vig=71.97.100.103`,
  `zpos_set=0.0.1.1`, `quad_dma=unavailable-missing`; DESIGN §6.2). The classifier's tests read the
  device side's mock streams (`stage3c/fixtures/sim/quad-*.txt`, `solid.txt`, `show-run1.txt`) and,
  end to end, replay every whole-image capture of the device harness
  (`stage3c/fixtures/image/<scenario>/`) through the collector and the classifier (test-host3c Z2).
- `host/test-host3c.ps1` covers the scripted sessions, the classifier, the M4 dot-source case and
  the console checklist (section CL: every answer and check of `fs-checklist3c.ps1`, the observer's
  gate, this file's printed lines and pin table); `-Regression -BeforeDir <dir>` re-runs
  `test-host3b.ps1` and `test-host2.ps1` and compares their result lines with a run taken before the
  3c files existed.
