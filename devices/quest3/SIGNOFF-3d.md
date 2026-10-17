# Sign-off reference - Stage 3d run (v2.7, either Quest 3 unit): what the console checklist asks and records

**Status: DRAFT (2026-10-13; host side of stage 3d, branch `feat/stage3d-host`; re-pointed 2026-10-14 to the v0.7.1
candidate, branch `fix/stage3d-modes`; not yet reviewed). *Later (2026-10-14): the host side was reviewed and merged
(J-136..J-138, J-142); the candidate below ran on Unit 1 and its nonce is spent; a nonce-only rebuild ran on Unit 2
(J-144, J-146). 2026-10-14 branch `feat/host-carryover`: the standing phase A and the carry-over of the sound check and
rehearsals (J-143), a reading while charging accepted below 300 (J-145); not yet reviewed.*** The image is the stage-3d CANDIDATE
(`build\stage3d\20261014T014738Z-<attempt nonce withheld>\`, `boot-stage3d.img` SHA-256
`fcca5ee791ee6e9dcf696eba16c676de1c26ab60ce82211c49a457e9cca24fb5`, nonce `<attempt nonce withheld>`, unspent then (spent 2026-10-14 on Unit 1, J-144; the
rebuild `<attempt nonce withheld>` spent on Unit 2, J-146), still the reference of every nonce-only rebuild; fs-pattern v0.7.1
`bfafad97c7ca11ef4e41a6be8aae4fde5ca529d8955d9b77d6fc603495049a9a` (the MAXMODES fix, J-141), built into
`fs-classify3d.ps1`; `fs-probe.sh` `f0fda865...7173` (the v2.7 mode-validation dmesg lines counted, not kept); builder `build-image.sh`
`b90c0fbb...6c34` with `module-list-check.py` `402525cd...f4c8`). The first v0.7.1 build (`96cc15aa...3fad`, nonce
`2b2596964c0812b1`) was superseded before any boot and is withdrawn. The first
candidate (`20261013T065151Z-<attempt nonce withheld>`, `3d730337...c224`, fs-pattern v0.7 `7c9fa98c...0674`) is WITHDRAWN: its
nonce was spent on Unit 2 (J-141, a safe refusal: v0.7 allowed 128 modes, v2.7 has 305); the tools refuse it.
**Both units** run the same v2.7 build (J-131/J-133): **Unit 1** (`QUEST3UNIT1`) and **Unit 2**
(`QUEST3UNIT2`) both passed (J-144, J-146); the image fits both (its MANIFEST says so). Each
run needs its own single-use nonce: every next run uses a nonce-only rebuild
checked with `fs-nonceonly3d.ps1` (WALKTHROUGH step 0), which opens both images and both ramdisks; `fs-observe3d.ps1`
refuses, also at `-Preflight`, any image that is neither the reviewed candidate nor such a rebuild of it, and never a
withdrawn candidate. One temporary boot (`fastboot boot`) per run, no retry. The commands are in `stage3d/WALKTHROUGH.md`; the host design in
`stage3d/HOST.md`.

The checklist is `devices\quest3\host\fs-checklist3d.ps1` (a copy of `fs-checklist3c.ps1` with the stage-3d texts),
run three times per cycle: `-Phase A` at the start of the cycle (before B; with the PM's standing acceptance and
carried-over passes it asks nothing, J-143), `-Phase B` after the temperature reading, `-Phase E` immediately before
the attempt. Each run appends one entry to `<cycle>\checklist3d.json` (schema `frameshift.fs-checklist3d.v1`) and
`<cycle>\checklist3d.txt`. Any `n`, timeout (15 minutes per question in phase A, 5 in phase E) or failed check prints
`STOPPED. Nothing was sent to the headset. Tell the Arbiter: <reason>` and exits 1: nothing is booted.

`fs-observe3d.ps1` **refuses the attempt** (exit 2, before any device query) unless `-Serial` names one of the two units
and `<cycle>\checklist3d.json` holds the last entries of A, B and E as passed (A for this image's nonce, in the order A,
B, E; E at most 300 s old; every entry by the pinned `fs-checklist3d.ps1`); A's acceptance holds (J-143: the standing
record A relied on is unchanged since, intact, for A's text, with A naming the pinned checklist as the version relying on it; or the questions A asked were
answered `y`; the sound check and rehearsal files A relied on are unchanged, from the same tool set and the same PC day);
B's reading passes its rules again as typed text (three digits from 100 to 349; status exactly 3, 4 or 5, or status 2
only below 300, J-145), was taken on **this unit** (`R1Serial` = `-Serial`), at or
before BA's start and at most 900 s before it; BA's own BA10 `dumpsys battery` (from the BA SUMMARY of this nonce and
serial) is 100 to 349 with the same battery rule and a level above 50; the reading is later than every other BA of the
cycle; E started at or after BF's start; and the BA/BF must-be rows of this nonce and serial hold (BA04 `_a`, BA16
`66b76196...f12a`, BA20 `user`, BA23 the unit's serial, BF02 `current-slot: a`). Then its one read-only `fastboot devices`
must show exactly that unit. The PM still types the nonce into `-ConfirmNonce`. This file is the reference of what the
console asks and prints; the lines below are printed verbatim (`test-host3d.ps1` H4 checks it).

---

## A. At the start of the cycle - `fs-checklist3d.ps1 -Phase A` (nothing below touches the headset)

- **Host pins match, checked FIRST.** From the repository root, in `powershell.exe`:

  `Get-FileHash -Algorithm SHA256 -LiteralPath devices\quest3\host\fs-collect3d.ps1, devices\quest3\host\fs-session3d.ps1, devices\quest3\host\fs-classify3d.ps1, devices\quest3\host\fs-observe3d.ps1, devices\quest3\host\fs-checklist3d.ps1, devices\quest3\host\fs-nonceonly3d.ps1, devices\quest3\host\fs-carry3d.ps1, devices\quest3\host\fs-collect3c.ps1, devices\quest3\host\fs-session3c.ps1, devices\quest3\host\fs-classify3c.ps1, devices\quest3\host\fs-collect.ps1, devices\quest3\host\fs-classify.ps1, devices\quest3\host\fs-classify3b.ps1, devices\quest3\host\fs-native.ps1, <withheld capture tool>, <withheld rows file>, devices\quest3\stage1\fs-proto.ps1, devices\quest3\common\host\fsb1.ps1, devices\quest3\stage3d\tools\check-timing-3d.py | Format-Table Hash, Path -AutoSize | Out-String -Width 400 | Tee-Object <cycle>\host-hashes.txt`

  `Get-FileHash` prints upper-case hex; the table is lower-case (compared case-insensitively). Any difference: STOP.

  <!-- host pins (stage 3d host side, 2026-10-13; review 2 fixes 2026-10-13: the six 3d files and fs-capture re-pinned; delta review 2026-10-13: re-pinned; 2026-10-14 J-141: fs-classify3d, fs-observe3d, fs-nonceonly3d re-pinned for the v0.7.1 candidate fcca5ee7; 2026-10-14 J-143/J-145, branch feat/host-carryover: fs-checklist3d, fs-observe3d, fs-collect3d re-pinned; then fs-checklist3d, fs-observe3d again (the PM: no renewal question R2); the review fixes of 14107af: fs-checklist3d, fs-observe3d, fs-collect3d re-pinned, fs-carry3d new; the delta review of 6f2973f: the four re-pinned; recompute after any host-file change) -->
  | file | SHA-256 | kind |
  |---|---|---|
  | `devices\quest3\host\fs-collect3d.ps1` | `ace04eb37de54bd842862fe453d9ef75c6df35b470e30f67e088b320be6c5d6a` | 3d, new (the collector: the reset question, per-eye tilt; dot-sources fs-collect3c) |
  | `devices\quest3\host\fs-session3d.ps1` | `f55c4a221729f09503236f3451405f87f2d69a69245cfd4df0cd3e9e0a6c0add` | 3d, new (the prompts) |
  | `devices\quest3\host\fs-classify3d.ps1` | `fbe821a184936cb52ffeb4cd2493636388bb2fa4abd36d960d25b41f878065e2` | 3d, new (fs-pattern v0.7.1 pin inside, J-141; the reset classes) |
  | `devices\quest3\host\fs-observe3d.ps1` | `428685119713c88744ce973000aa371435a7467ec1f8f1981140efbc98d76b1a` | 3d, new (v2.7 baseline, the v0.7.1 pin, the unit serial, the checklist gate incl. the J-143 standing record and carried passes, the J-145 battery rule; refuses a withdrawn candidate) |
  | `devices\quest3\host\fs-checklist3d.ps1` | `793bc137fa1bd3c723878413750dfea95d649c2806e336599fa0c35cfe9de7bf` | 3d, new (the console checklist; J-143 the standing phase A and the carry-over, J-145 charging below 300) |
  | `devices\quest3\host\fs-nonceonly3d.ps1` | `37fb298587fc886f0138b4169d04c863edb867a2956320616c063866ff87cc80` | 3d, new (one nonce per run: opens both images; the reviewed-candidate table, J-141; required by the observer) |
  | `devices\quest3\host\fs-carry3d.ps1` | `ed49bcbeedc01ef3d8a58df776bae5a70815e93cc2a8a9784c7fd014723ba260` | 3d, new (J-143: the session/collector tool set and the made record of a sound check or rehearsal; dot-sourced by fs-collect3d and fs-checklist3d) |
  | `devices\quest3\host\fs-collect3c.ps1` | `b7ec42ce5d16b4e4b59141d7387bfd79e9836c24ae68dd66aefe19727f764e33` | reused library (dot-sourced by fs-collect3d) |
  | `devices\quest3\host\fs-session3c.ps1` | `a7db33bdc460b0416a7c4bda23fa68cbea9dffdf11a6d6313491963cc90486f3` | reused library; the sound check (-SoundCheck) |
  | `devices\quest3\host\fs-classify3c.ps1` | `351ac4e4ef7106e2e3deccf25ebb6d04397c679ce34ffaedd7208132cb70d684` | reused library (dot-sourced by fs-classify3d) |
  | `devices\quest3\host\fs-collect.ps1` | `2b90d641a15065da522e885df6cb627cd01e48608f7a20faea4cd07698068089` | reused, pinned (dot-sourced) |
  | `devices\quest3\host\fs-classify.ps1` | `ed5d07eabe2568853800d24e5065f0817af64acdd0c2e633426fd40a71138380` | reused, pinned (dot-sourced) |
  | `devices\quest3\host\fs-classify3b.ps1` | `aa0db5173c9fcb6a957bd62f49cc992d4bf55e547cdf24f77964ed792949b649` | reused, pinned (dot-sourced via fs-classify) |
  | `devices\quest3\host\fs-native.ps1` | `101ddfb15d35986705692f973c0ad74c5797dfb82e9947d719fea1eed7a99b80` | reused, pinned |
  | `<withheld capture tool>` | `72c0f3bfa1647316b7c0d2c92b86fce2125118f72273ba5bde93e18b59227eca` | revision 10 (BA/BF/AF/AA; {serial}, the persist refusal; -Serial required) |
  | `<withheld rows file>` | `c16631e9cd6498ea6f94457be0ad99f3f3db68f79295cebd3a591ce2a21853d2` | the user-build rows for either unit (data) |
  | `devices\quest3\stage1\fs-proto.ps1` | `52e007eb6c9ced48aacd5fe42e8bfd5e988e4003dcd3b662ea1e68429e09ed85` | reused, pinned |
  | `devices\quest3\common\host\fsb1.ps1` | `1f84c633e8cf358fce3e006cef996bae9b372ee2914a97a0c5ab864312f0a703` | reused, pinned |
  | `devices\quest3\stage3d\tools\check-timing-3d.py` | `a0227bd6000ebdda137352a525bc8758901b411a2b0f00464066c3c0893ee1ed` | 3d timing (reads the 3d host files) |
  <!-- end host pins -->
- **Preflight** (check `preflight`): `fs-observe3d.ps1 -Image <...>\boot-stage3d.img -Preflight` (MANIFEST, image hash,
  the v2.7 baseline: stock boot `e32f98c7...c024`, vendor_boot `bc0dd14d...2f5b`, vbmeta `aae4af3a...f215`,
  vbmeta_system `28f5ccc9...bc50`, vbmeta digest `66b76196...f12a`, `/bin/fs-pattern` = the v0.7.1 pin `bfafad97...9a9a`, the stage3d
  sources, a fresh nonce; no device action) prints `preflight OK`.
- **Carry-over (J-143)** of the three checks below: each pass records when and with which tools it was made (the
  sound check's `MadeUtc` and `ToolSetSha256`, a rehearsal summary's last line `REHEARSAL MADE: <utc> with tool set
  <sha256> replay <sha256> <path>`; `fs-carry3d.ps1`; a rehearsal must name the expected replay of its kind, `garbled-r3`
  or `nominal-read`, with that replay's current SHA-256). Each passes FRESH from this cycle's own file, or is CARRIED OVER
  from the latest earlier pass (recorded in `captures\standing\carryover.json`), and in both cases counts only unless (a) the session/collector
  tool set changed (`fs-session3c.ps1`, `fs-collect3d.ps1` and every file they dot-source: `fs-native`, `fs-collect3c`,
  `fs-collect`, `fs-session3d`, `fs-classify3d`, `fs-classify3c`, `fs-classify`, `fs-classify3b`, `fs-carry3d`, `fs-proto`, `fsb1`; and
  the two rehearsal replays) since it was made, (b) it was made on another calendar day of this PC (local date), or (c) it
  was made before the PM's last declaration of new speakers (`-Phase A -NewSpeakers`, recorded in
  `captures\standing\speakers.json`; not repeated on the re-run). A carried pass must also still have its recorded
  SHA-256 and pass its check again. A refusal
  prints `needed: ...` naming what to run and why. The A entry records the pass relied on (mode, path, SHA-256, tool
  set, day, cycle).
- **Sound check passed** (check `soundcheck`): `<cycle>\soundcheck.json` from `fs-collect3d.ps1 -S3dSoundCheck
  -S3dOutDir <cycle>` (the stage-3c sound check run by the stage-3d collector, schema `frameshift.fs-soundcheck3d.v1` with
  its made record; its key-reach test covers every stage-3d key; a `fs-session3c.ps1 -SoundCheck` file does not count), or carried over. The
  only protection against a silent audio failure: keep these speakers and this volume (a change: `-NewSpeakers`).
- **Rehearsal passed, garbled path** (check `rehearsal`): `<cycle>\rehearsal\summary.txt` from `fs-collect3d.ps1
  -S3dReplay devices\quest3\host\fixtures\stage3d\replay\garbled-r3\capture.raw -S3dOutDir <cycle>\rehearsal -S3dRehearsal
  -S3dReplayPin f6a9c3e2b1d0a4958877665544332211ffeeddccbbaa99887766554433221100`, answered on the garbled path (reset
  question `b`; run 2 `c`, `c`, `y`; run 3 `s`, `s`, `y`; then `s`), must hold `REHEARSAL: reset plus run-2 answers ... s;
  go/no-go (SIGNOFF-3d A): GO (<= 40 s)`, the reset answer and the Q7 note `not asked (Q7 fallback)`.
- **Rehearsal passed, read path, TIMED** (check `rehearsal-read`): `<cycle>\rehearsal-read\summary.txt` from the same
  command with `...\replay\nominal-read\capture.raw -S3dOutDir <cycle>\rehearsal-read`, answered as live (reset question
  `b`; each eye `d` and the 8 characters the console shows at run 2's start, `REHEARSAL ONLY: ...`; the dark check `y`;
  per eye any tilt, F and bar keys: the replay has no picture; then `s`), must hold `REHEARSAL (read path): run-2 answers took ... s from the
  first prompt; 9 of 9 items answered` and `REHEARSAL (read path): the last answer ... s before the cut-off (...);
  go/no-go (SIGNOFF-3d A): GO (every item answered, at least 10 s to spare)`, with the reset answer. The rehearsal uses
  the live give-up (160 s after the collector starts), so the cut-off is the earlier of run-2 end + 110 s and the
  give-up - 3 s, as live.
- **Standing acceptance** (check `standing`, J-143): `captures\standing\phase-a.json` (schema
  `frameshift.fs-standing-a3d.v1`) holds the PM's last acceptance: its UTC time, the cycle, the accepted text in blocks
  (questions A1-A3, the preview list with `<repository>` paths, the three pictures' SHA-256, the keys, D1 to D14), each
  block's and the whole text's SHA-256, and the checklist's own SHA-256 (its pin). If it is intact and its text SHA-256
  equals the current text, phase A asks **nothing**, also when only the checklist code changed (PM decision), and
  records the record's path and SHA-256 and the checklist version that relied on it (Acceptance mode `standing`,
  `ToolPin` this checklist, `RecordToolPin` the one that took the acceptance): this automatic entry, written at the start of the cycle, is the
  "A" of the A, B, E order. If the text or a picture changed, only the changed lines are printed (`CHANGES SINCE YOUR
  ACCEPTANCE OF ...`) and question R1 is asked. With no record, the
  full phase A below (A1-A3). Each acceptance rewrites the record (the earlier one kept in `history\`). A record that is
  unreadable, of another schema, malformed, dated in the future, whose stored text does not match its own SHA-256
  (edited), or that no phase-A PASS entry of its originating cycle on this PC gave (mode full or changes, naming the
  record's SHA-256, with its `y` answers, by the checklist version the record names, for this text; a later phase A of
  that cycle relying on it is not the origin: a record made up, or copied from another PC without its cycle folder) is refused: STOP, nothing is asked; the Arbiter moves it aside. This ties the record to that
  cycle's own record; it is not proof against a deliberate local forgery of both.
- **Phase A's day and order** (J-143 review): phase A, and the passes it relied on, hold for its own PC day only:
  phases B and E and the observer refuse on a new day (`new day: ... run step 2 (phase A) again`). On the same day,
  phase A refuses to run again once B has passed after it (no entry is written; the A, B, E order, J-140).
- **Previews present** (check `previews`): the three files below exist. The as-seen, panels and mixer-map pictures show
  the expected bars and the level view: they are not shown before the session (WALKTHROUGH step 17 opens them after the
  PM's description is recorded; delta review MINOR-2).

Then, only for a full acceptance (no standing record yet), it prints and asks (each answer `y` or `n`):

**THE THREE PREVIEW PICTURES**, then question A1 `Have you opened and looked at the three preview pictures listed above? (y/n)`:

```
Open each of these three pictures (paste the path into File Explorer) and look at it:
1. <repository>\devices\quest3\stage3d\fixtures\preview\pattern-v0.7-3f9c07ab-digits-left.png
   The 8 characters to read.
2. <repository>\devices\quest3\stage3d\fixtures\preview\F-reference-u-i-m-v.png
   How an F can look: upright u, upside down i, mirrored m, flipped top to bottom v.
3. <repository>\devices\quest3\stage3d\fixtures\preview\solid-red-v0.7-viewer-1032x552.png
   The plain red field of run 3.
In each eye, note whether the text is level or turned, and which way. The pictures of the expected view are shown only after the session.
```

**THE KEYS (what to press for what you see)**, then question A2 `Do you know which key to press for each thing you might see (list above)? (y/n)`:

- After the display reset, one question: y = yes, I saw something; b = no, it stayed dark (b means dark, as in run 2); x = abort. n is not an answer there (nothing happens). The answer is recorded only; run 2 follows either way.
- Run 2, each eye: d = I can read the 8 characters (then type them; Backspace fixes; Enter needs all 8; Esc goes back), c = garbled, a = light but no pattern, b = dark, x = abort.
- Dark check (both eyes): y = dark, n = light still visible (the session then ends safely), x = abort.
- If asked, each eye in this order: the tilt (0 level, r turned clockwise, l turned counter-clockwise, ? can't tell); the letter F (u upright, i upside down, m mirrored, v flipped top-bottom, ? can't tell); the bars next to the LEFT F, then the RIGHT F (two keys 0-4, 0 = none). No bar question if run 3 follows.
- Run 3 (only if run 2 was garbled or light without a pattern): r = all red, p = partly red, u = one other colour, s = same as run 2, g = a different garble, b = dark.
- x aborts at any time. n aborts too while phase 0, the LOOK cue, run 2 or run 3 is running (it means light). At the reset question and at the eye, tilt, F and bar questions n does nothing.
- 30 s per question. A timeout at the reset question, an eye question or the dark check ends the session safely; a timeout at a tilt, F or bar question skips only that question (but ends the session safely when run 3 could follow). Ctrl+C is the same as x. Tap keys, do not hold them; wait for each answer to be echoed. Do not click into the console window.

**WHAT I ACCEPT (points D1 to D14)**, then question A3 `I have read points D1 to D14 above and I accept them (y/n)`: the list of section D below.

After a change (J-143), instead: the changed lines only (`- new:`, `- removed:`, `- picture changed, open it again:`),
then question R1 `I have read the changes listed above (and opened any changed picture), and I accept them together with the rest of my earlier acceptance (y/n)`.
An `n` or a timeout stops phase A and leaves the standing record as it was.

## B. Single temperature reading - `fs-checklist3d.ps1 -Phase B` (on THIS unit)

One reading, read-only, taken with the PM: `adb -s <serial> shell dumpsys battery; [DateTime]::UtcNow.ToString('o')`
(the time is **the PC's UTC at the reading**, the last line printed). The Arbiter runs phase B with it: `-R1 <t> -R1Utc
<utc> -R1Status <status> -R1Serial <serial>` (optionally `-R1Charge`), each typed exactly as printed. The rule (the
stage-3c rule after the single-reading review, with the PM's J-145 change): the temperature three digits from 100
to 349 (`range-100-349`); the battery (`battery-rule`): status 3, 4 or 5 (discharging, not charging, full) below 350, or
status 2 (charging) only **below 300** (30.0 °C, J-145); status 1 never; the unit one of the two Quest 3 units
(`known-unit`), equal to the attempt's `-Serial`; not in the future (at most 60 s ahead); at most 900 s before BA
(exact). Otherwise STOP: wait (or unplug the charger), take a new reading.

## C. BA, then BF (the user-build rows, the unit's serial)

`<withheld capture tool> -Phase BA -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file>`
must print `PHASE BA OK` (BA01-BA10, BA16-BA24; BA11-BA15 "not captured"; **the 5-minute dwell starts now**); after
`adb -s <serial> reboot bootloader`, the same with `-Phase BF` must print `PHASE BF OK`. `<withheld capture tool>` requires
`-Serial` (revision 10). The observer machine-checks the "must be" rows from these captures before any device query and
refuses the attempt on a mismatch: BA04 `_a`, BA10 temperature 100 to 349, status 3, 4 or 5 (or status 2 below 300, J-145), level above 50, BA16
`66b76196...f12a`, BA20 `user`, BA23 the unit's serial, BF02 `current-slot: a`. Item D13 is what the PM accepted about
the dwell gate.

## D. What I accept (printed by phase A before question A3)

- D1. First the headset sets the screen brightness once, to level 127 (about 4 % of full backlight, from the driver code; nobody has measured the light). It is read back before each run.
- D2. Then the display reset: the screen is switched off, on again showing only black, and off. Nothing should be visible. One question follows: did I see anything? My answer is recorded and does not stop the test.
- D3. Then run 2 shows the test pattern for 10 s. It is drawn per eye: each eye gets its own half, turned against the panel's 21-degree tilt. I describe what I actually see; there is no expected answer to aim for. If the driver refuses it, nothing lights.
- D4. Run 3 shows a plain red field for 5 s, only if I report run 2 as garbled or as light without a pattern. At most 15 s of light in total.
- D5. On this firmware (v2.7) the backlight may stay dim or dark in run 2 (a known open point). I report what I saw; a follow-up build may follow.
- D6. The headset itself times each lit period. Pressing x cannot shorten a period that is already running; it ends the session after it. I may look away at any time.
- D7. If the screen does not go dark when a run ends, the picture may stay until the end command (fs-done), the idle limit (120 s) or the deadline (about 200 s after the test program starts, with a last safety stop 1 s later). These are not guaranteed screen-off times; switching off by hand (RECOVERY.md) always remains.
- D8. Questions appear only after a run has ended and its report has arrived. I answer from what I saw. The console shows none of the headset's own results until my answers are in. The swap and tilt labels help explain the result; they are not a pass.
- D9. If a report does not arrive, or a red NO RECORD / SHELL STATE UNKNOWN / NO fs-done banner appears with the ALARM sound, nothing more is sent: I look away and wait; the headset recovers by itself.
- D10. Console window closed, or the collector stopped: I look away; the headset recovers by itself within 120 s (the idle limit) or at the deadline. My answers so far are already saved (readings3d.txt).
- D11. If the console shows NOTHING RUNS (integrity): the pattern program on the headset is not the reviewed one; nothing is shown, and fs-done follows.
- D12. No number is claimed for eye safety; "no light seen" does not mean that no light was emitted.
- D13. Time limit: the test boot is refused if more than 300 s have passed since BA started. Then nothing starts, the one-time code (nonce) stays unused, and I go back to Android for a new temperature reading and a new BA/BF.
- D14. On v2.7 the before/after checks show the build and slot only; partition contents are not compared (not captured on a user build; <withheld document>).

## E. Presence - `fs-checklist3d.ps1 -Phase E` (after BF, immediately before the attempt)

Needs phases A and B passed. It prints **PRESENCE** and **AFTER THE SESSION**:

- I am present, headset in hand, power button reachable, keyboard under one hand; the collector runs in powershell.exe (a console window, not ISE) with sound on, on the PC speakers and at the volume of the sound check.
- If anything is unexpected: x (at the dark check, n), look away and wait; the headset recovers by itself (fs-done, the idle limit of 120 s, or the deadline about 200 s after the test program starts). Switch off by hand (power button) only as RECOVERY.md says.
- Next: paste the attempt command at once. fs-observe3d.ps1 refuses the attempt if this presence check is more than 300 s old, or if more than 300 s have passed since BA started.
- After the session: AF immediately on return to fastboot (<withheld capture tool> -Phase AF), then fastboot -s <serial> reboot, then AA promptly in Android.
- AA10 temperature at 400 (40.0 deg C) or more: shut down at once (procedure as 3b F), do not wait for anything else. Even below 400, follow-up readings at +5 min and +10 min, then every 5 min while it rises and stays below 400; the highest observed reading is recorded. Shutdown and unplug are recorded as two separate observations.

and asks, both must be `y`:

- E1 `Are you physically at the headset now? (y/n)`
- E2 `Can you reach the headset's power button now, and do you know when to use it (RECOVERY.md)? (y/n)`

Then, within 300 s, the attempt (this command runs `fastboot boot`, the one temporary boot; typed only after the
sign-off): `powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-observe3d.ps1
-Image <img>\boot-stage3d.img -Serial <serial> -ConfirmNonce <nonce> -BaSummary <cycle>\BA\SUMMARY.txt -BfSummary
<cycle>\BF\SUMMARY.txt -ThenCollect`, with `<cycle>` = `captures\<nonce>`. After a dwell refusal: a new reading
(`-Phase B`; the observer refuses a reading taken before an earlier BA of the cycle), BA/BF with `-CapturesRoot
<cycle>\retry-1`, `-Phase E`, and the attempt with
`-BaSummary <cycle>\retry-1\<nonce>\BA\SUMMARY.txt -BfSummary <cycle>\retry-1\<nonce>\BF\SUMMARY.txt -ChecklistFile <cycle>\checklist3d.json`.

## F. After (recorded by the captures, not by the checklist)

- **AF immediately** on return to fastboot (`<withheld capture tool> -Phase AF ... -Serial <serial> -CommandsFile ...<withheld rows file>`),
  then `fastboot -s <serial> reboot`, then AA promptly in Android.
- AA10: **at 400 (40 °C) or more: shut down at once**; follow-ups at +5 and +10 min, then every 5 min while it rises.
- The PM's free-text description goes verbatim into `notes.txt` (with the tilt seen per eye). Only after it the
  expected-view pictures (`pattern-v0.7-3f9c07ab-asseen-`, `-panels-`, `-mixermap-1032x552.png`) may be opened. Then the Arbiter
  runs `fs-classify3d.ps1 -C3dDir <observe dir>\collect -C3dObserveDir <observe dir>` (the v0.7.1 pin is built in).
- On v2.7 the before/after compare shows identity and slot only (`<withheld document>`): a stage-3d
  result is "no change visible to read-only, non-root queries", never "partitions unchanged".

## What is recorded (for the Chair)

`checklist3d.json` / `checklist3d.txt` (as `SIGNOFF-3c.md` "What the checklist records", schema
`frameshift.fs-checklist3d.v1`; the A entry also records `Acceptance` (mode, the standing record's path and SHA-256, the
text SHA-256, the tool pin, the acceptance time and cycle, the questions asked), `SoundCheck`, `Rehearsal`,
`RehearsalRead` (fresh or carried: path, SHA-256, tool-set SHA-256, day, cycle), `LocalDate`, `ToolSetSha256`,
`NewSpeakers`); per PM, in `captures\standing\`: `phase-a.json` (+ `history\`), `carryover.json`, `speakers.json`; `observe.json` with `Serial`, `Unit`, the checklist fields, BA10's values and, without a
gadget, `NoGadgetNote`; in `<observe dir>\collect`: `capture.raw` + `.idx`, `phase-<ph>.raw`, `session.json` (Stage 3d),
`readings3d.txt` (FSR2: r1 `seen`; r2 per eye with `tilt_<eye>` LEVEL / CLOCKWISE / COUNTERCLOCKWISE / UNKNOWN),
`summary.txt`; the classifier's report (r1 RESET-DONE / ALREADY-INACTIVE / RESET-NOT-DONE, R2, optical, GEOMETRY, ROLL);
`observe.json` also records `MustBe` (the BA/BF must-be values) and `NonceOnly` (the reviewed candidate, or the
nonce-only rebuild it was checked against).
