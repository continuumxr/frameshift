# Stage 3c: design of the next display run on Quest 3 Unit 1 (interactive, per phase)

**Status (2026-10-12): revision 3 + integration pass + build-review fixes (see below); CANDIDATE image only.** (Revision 3 itself was written before anything was
built.) No device was touched. Revision 2 applied
`docs/research/display-pipeline-and-geometry.md` and the PM decisions of J-109
(explicit zpos in the commit; no debugfs this run). Revision 3 applies the R-A
adversarial review of revision 2, checked against the near-match kernel source
(`~/work/fs006-kernel/src` @ `23c97b254`, `techpack/display/msm/sde/`, read-only).
The reviews are done (J-111..J-114; run as R-A, R-B, fs-pattern, rebuild/mutation, R-C, R-D and the Q7 review, not as named in §12.6).

**Integration pass (2026-10-11, after both halves were built; a CANDIDATE image exists,
see IMAGE.md; nothing run on a device, nothing committed).** Interface decisions taken
where revision 3 left room or the two halves differed, now one rule on both sides:
FSP1 plan lists are `.`-separated with no `%XX`, per-attempt keys carry `_vig`/`_dma`
(§6.2); `post_plane`/`plane_caps` key sets (§6.5); the `rec` marker precedes only an
`emit-<rc>` refusal (§5.2, §5.4); the host classifier pins fs-pattern v0.6 `3c33e1a2…08d6`.
The encode measurement (§9.1) and §15 Q1 (a), (d) are recorded. No device-side
source changed; the harness's simulated monotonic stamps were made per phase.

**Build-review fixes (2026-10-12; R-B device, R-B fs-pattern helper, R-B build/mutation
helper, R-C host; a new CANDIDATE image, see IMAGE.md; nothing run on a device, nothing
committed).** Every finding and its fix. The PM constraints are unchanged: one 127
backlight write, DRM commits incl. the explicit zpos only, no debugfs, holds 3/10/5 s
device-enforced, DEADLINE 200 + backstop 201, no lit-phase retry.

| finding | fix | where |
|---|---|---|
| R-B MINOR-1: a refusal before `/run/fsb3c` existed left no `closed` file, so a later p0 was accepted | `$D` is made (mkdir -m 0700, `-L` check kept) before the first refusal check; new scenario `c-usage-then-p0` (malformed first command, then p0 → `order`); `c-order` now also sends r1 after the refused r2 (→ `order`) | §5.2, §12.3; `fs-phase.sh`, harness |
| R-B MINOR-2: the encoder END pass was not in the timing model; a cold 0.75 s repetition unrecorded | END pass 1.5 × 0.16 = 0.24 s per phase added; the cold repetition recorded in `fixtures/encode-timing.txt` (`ENCODE_COLD`) and counted; rule PHASE_WORST ≥ W + 0.5 s → **PHASE_WORST 23/38/47/39, G 34/68/82/64**, limits r1 117 / r2 103 / r3 121 s; DEADLINE 200 / backstop 201 unchanged | §9.1, §9.3, §9.4; `fs-phase.sh`, `check-timing-3c.py`, `fs-collect3c.ps1` |
| R-B NIT-1: pacer rc 3 after `rec` read as record-too-large | every pacer failure after `rec` is `emit-<rc>` (rc 3 included) | §5.2; `fs-phase.sh` |
| R-B NIT-2: the debugfs refusal is lexical | documented as a lexical guard; plus a mount whitelist (below) | §12.2; `build-image.sh`, IMAGE §2 |
| R-B NIT-3: waitsup TQ 2 s tight | **TQ 3 s** (probe windows r1 24 ≥ 24, r2 32 ≥ 31, r3 26 ≥ 26; timing recomputed above) | §9.1; `fs-phase.sh` |
| fs-pattern MAJOR (policy wording, no code change): "2 × 2064 only TEST_ONLY" | stated: run 1 (`show`) deliberately commits the reviewed v0.5 2 × 2064 split as the wake step (§6.1, Q16, PM "run 1 unchanged"); the TEST_ONLY-only rule applies to the quad modes (runs 2/3); `check_static.py` checks both | §6.1; README §3, SIGNOFF-3c D, `check_static.py`, `fs-pattern.c` header |
| fs-pattern MINOR: essential record bytes uncapped in code | connector / mode / plane / plane_caps records are essential only up to **3 / 24 / 20 / 20** (the counts of the maximum fixtures, `FSP_ESS_*`); every further one is an optional record inside the opt budget; `check-timing-3c.py` asserts the counts against the fixtures; a unit test (63 now) | §6.5; `fs-pattern.c` (new binary `066bdc3e…27bc`) |
| fs-pattern MINOR: split-probe static check | `check_static.py`: the split probe's `a_commit` carries TEST_ONLY; `ok` is assigned only in the quad loop; the quad branch commits only `qtag` | §12.3 |
| fs-pattern NITs | `plan attempts=` = the number of TEST_ONLY requests planned (split probe + available quads); the mock converts CRTC_X only on the quadpipe topology; SET_CLIENT_CAP (per fd, needed for atomic) noted in the ioctl set | §6.5; unit-test mock |
| build/mutation helper MAJOR 1: no phase sent after a refusal | `c-order` sends r1 after the refused r2; `c-usage-then-p0`; both expect `/run/fsb3c/closed` | §12.3 |
| build/mutation helper MAJOR 2: the one-write rule checked from probe text only | the harness counts write-closes on the fake `panel0-backlight/brightness` (inotify IN_CLOSE_WRITE): exactly 1 per session with p0, 0 otherwise | §12.3 |
| build/mutation helper MAJOR 3: "fs-idle never writes the tty" unchecked | the harness accounts for every capture line (banner, echoed commands in order, record/marker/refusal lines, prompt; anything else is stray); the builder refuses a tty/console name in `fs-idle.sh` | §12.3; `build-image.sh` |
| build/mutation helper MINOR 4: the debugfs refusal is evadable | the builder also refuses any non-comment `mount` line other than init.sh's five reviewed mounts (a lint, not a proof; IMAGE §2); three negative builder fixtures (quoted, variables, octal) and a tty-write fixture | `build-image.sh`, `test-builder.sh` |
| build/mutation helper MINOR 5: pace PASS used bound + 2 s | the paced time must be within the analytic bound itself (all 63 pace checks pass) | `pace_evidence.py` |
| build/mutation helper NIT 6: "FAIL" substring counting | `fixtures.sh` counts the first standalone PASS/FAIL field of a CHECK line | `fixtures.sh` |
| R-C MAJOR-1: lit phases not gated on p0 integrity | after a VALID p0 the collector requires the hash step MEASURED and equal to the pin (`Get-Fs3cP0Integrity`); otherwise `RUN 1 NOT POSSIBLE (integrity)` → `fs-done`; replays take `-S3cReplayPin` | §8.2; `fs-collect3c.ps1` |
| R-C MAJOR-2: Ctrl+C / a closed window | Ctrl+C is read as input and taken as `x` (the safe finish, `fs-done`); every reading is appended to `readings3c.txt` and checkpointed in `session.json` at once; "console closed: look away; the device recovers within 120 s idle or T0 + 200 s" | §8.2; `fs-session3c.ps1`, `fs-collect3c.ps1`, WALKTHROUGH, SIGNOFF-3c |
| R-C MAJOR-3: r3 "previous phase clean" used the post_plane comparison | the classifier uses the device gate's facts (exit 0, commit rc=0, hold to the deadline, close_rc=0, quad for r2); an unconverted CRTC_X stays a finding of r2; test S14r3 | §11.1; `fs-classify3c.ps1` |
| R-C MINOR-1 | integrity before the multi-write check in p0 (the 3b order) | §11.1 |
| R-C MINOR-2 | the previous answer's key is ignored for 600 ms at a prompt's start (key repeat; raised from 400 ms, R-D) | §8.2 |
| R-C MINOR-3 | `d`, then a timeout/x/n in the entry: "READ, characters not recorded"; optical class `READ, CHARACTERS NOT RECORDED` | §8.2, §11.2 |
| R-C MINOR-4 | `n` during a phase (or before it, or in the cue) = `x` | §8.2 |
| R-C MINOR-5 | SIGNOFF A: the sound check is the only protection against a silent audio failure; PC speakers stay the output | SIGNOFF-3c A |
| R-C MINOR-6 | key reach adds `e f 5 6 7 8 9 ? Enter Backspace` | §8.4 |
| R-C MINOR-7 | the machine summary goes to `summary.txt`; on the console only after the `s` key, after the notes | §8.2 |
| R-C MINOR-8 | the host-pin check is first (before the sound check and the rehearsal), with the literal `Get-FileHash` command (upper-case hex) | SIGNOFF-3c A, WALKTHROUGH |
| R-C MINOR-9 | QuickEdit off for the session (SetConsoleMode), restored after | §8.4 |
| R-C MINOR-10 | "fs-done NOT sent" only when it was not | `fs-collect3c.ps1` |
| R-C NITs a–g | red SAFE FINISH banner; rule numbering (§5.8 rules 1–5 used everywhere); LAYOUT DIFFERS only when r3 was shown; a distinct dark-check banner; ASCII dashes in the PM documents; key-source failures logged; "y = yes, n = no" | §8.2, §11.3; host files, docs |

**Q7 fallback and PM rehearsal feedback (2026-10-12; host only, no device change: image
`9d3ad984…`, nonce `b7cf9a0bfb559dcb` unchanged; made on branch `wip/q7-prompt-fallback`;
reviewed (GO) and merged, `a5c1651`, J-114).** The PM rehearsal
(replay transport, garbled path; `captures/b7cf9a0bfb559dcb/rehearsal/`) gave run-1 answers
16.4 s and run-2 answers 50.2 s, of which the two bar-count prompts took ≈ 48 s:
66.6 s, **NO-GO** against 40 s. The reviewed fallback of §15 Q7 is applied: **no bar
counts on the run-3 path** (§8.2). Run 2 on that path is then left, right, dark (the
rehearsal's own answer stamps give r2 18.0 s, r1 + r2 = 34.4 s). The PM's feedback on
the prompts is applied with it: `n` (light visible) is a key of the **dark check only**
(§8.2); the per-eye lines are short; the bar-count prompt, still asked off the run-3
path, explains itself.

| item | change | where |
|---|---|---|
| Q7 fallback | after a VALID run 2 the gap evaluates the run-3 rule (§5.8 rules 1-4) on the readings after the dark check; when it holds, `bars_left`/`bars_right` are not asked: FSR2 `NOT_ASKED`, event `bars-not-asked r2/<item> (Q7 fallback: run-3 path)`, the r2 phase in `session.json` carries `Q7Fallback` ("not asked (Q7 fallback)"). Nothing is shown on the console (the rule is control flow only). F/line of a `d` eye on that path are still asked. The countdown is not consulted, so the prompt set never depends on timing | §8.2, §15 Q7; `fs-session3c.ps1`, `fs-collect3c.ps1` |
| classifier | a Q7 `NOT_ASKED` bar item is expected: no LAYOUT line for a `c` eye, the `d` eye's F/line reported with "bars not asked (Q7 fallback)", one `READINGS NOTE` line; never INCONCLUSIVE | §11.4; `fs-classify3c.ps1` |
| PM feedback 1 | the bar-count prompt (off the run-3 path: rule 1, 2 or 3 fails) explains itself: "next to each of the two F letters (below it when upright) there is a row of 1 to 4 bars (see the preview). Press how many bars you see at the LEFT F, then at the RIGHT F (two keys, 0 = none visible)"; no bar order is shown | §8.2 |
| PM feedback 2 | `n` removed from the per-eye readings (runs 1-3), the character entry and the layout items: there it is an ignored key (logged); `x` aborts at every prompt; `n` stays on the dark check (light visible → safe finish) and, during a lit phase, before it and in the LOOK cue, is still taken as `x` | §8.2 |
| PM feedback 3 | per-eye lines: `RUN k - LEFT EYE:  a = light, no pattern   b = dark   c = garbled   d = I can read the characters   x = abort`; run 3: `r = all red   p = partly red   u = one other colour   s = same as run 2   g = different garble   b = dark   x = abort` | §8.2 |
| rehearsal go/no-go | unchanged measure: run-1 plus run-2 answer time, each from the phase's first prompt to its last answer (a Q7 `NOT_ASKED` item carries no answer and adds no time); a NO-GO now reads "stop and report (the Q7 fallback is already applied)" | SIGNOFF-3c A; `fs-collect3c.ps1` |
| tests | test-host3c: the garbled-path key scripts drop the bars (canonical `garbled-r3/keys.txt` regenerated, capture unchanged); bars/n cases moved off the run-3 path; new A3b, A8b, D4-D6, G5, Q3b | §12.3 |

**Console checklist (J-118; 2026-10-12; host and PM documents only, no device change: image
`9d3ad984…`, nonce `b7cf9a0bfb559dcb` unchanged; branch `feat/console-checklist`, not yet
reviewed).** PM decision: the SIGNOFF-3c sheet is replaced by a checklist in the console. The new
`host/fs-checklist3c.ps1` (no device command, no network) runs three times per cycle and appends
each run, with UTC timestamps and the exact question text, to `<cycle>\checklist3c.json` and
`checklist3c.txt` (the Chair's evidence): **A** before BA verifies from the files the host pins
(`host-hashes.txt` and the working files against the SIGNOFF-3c table, first), the observer's
`-Preflight`, `soundcheck.json` Pass, the rehearsal's GO line (with the Q7 note) and the previews,
then asks the previews / readings-and-keys / section-D questions with their text printed; **B**
records the settled pair (`-R1 -R1Utc -R2 -R2Utc`) and the 3b rule (+ at least 600 s apart, not in
the future); **E** asks presence and manual recovery immediately before the attempt. Any `n`,
timeout or failed check is STOP (exit 1). `fs-observe3c.ps1` gains one gate, after the
`-Preflight` return and before any device query, the dwell gate and the attempt registration: the
last A, B and E entries passed (A for this nonce, in order) and E at most 300 s old, otherwise
exit 2 with no device action (`-ChecklistFile`, default found from `-BaSummary`); `observe.json`
records the checklist file, its SHA-256 and the presence age. SIGNOFF-3c.md becomes the reference
of what the console asks and prints (the same lines, checked by test-host3c CL13); the WALKTHROUGH
runs the phases at steps 5, 6 and 9 (and now gives the `-BaSummary` path that `<withheld capture tool>
-CapturesRoot <cycle>` actually writes, `<cycle>\<nonce>\BA\SUMMARY.txt`; superseded by the review
fixes below: `<cycle>` = `captures\<nonce>`, no `-CapturesRoot`). Re-pinned:
`fs-observe3c.ps1`; new pin: `fs-checklist3c.ps1`. Tests: test-host3c section CL.

**Console checklist review fixes (2026-10-12; host and PM documents only, image and nonce
unchanged).** The review of `84f49ba` found: (M1) the committed test output came from a worktree
without `misc.img` (Y2/Y3 failed): regenerated in a full clone with the gitignored inputs; (M2) A3
now reads "I have read points D1 to D14 above and I accept them"; (M3) `<withheld capture tool>` writes
`<CapturesRoot>\<nonce>\<phase>`, so `-CapturesRoot <cycle>` with `<cycle>` = `captures\<nonce>`
nested the nonce twice: the WALKTHROUGH now defines `<cycle>` = `captures\<nonce>`, runs BA, BF
and AF without `-CapturesRoot`, and the attempt takes `-BaSummary <cycle>\BA\SUMMARY.txt` (SIGNOFF
E too); `-CapturesRoot <cycle>\retry-1` with `-ChecklistFile` remains for a dwell retry; (M4) step 1
says to re-run the host hashes (15 files). (Medium) `fs-observe3c.ps1`'s checklist gate now ties
phase B to this BA (reading 2 at or before BA's start and at most 900 s before it: an old PASS no
longer survives a dwell abandon) and phase E to this BF (E started at or after BF's start), and
requires every entry's `ToolSha256` to equal the `fs-checklist3c.ps1` pin of the SIGNOFF-3c table;
`observe.json` adds `checklist3c.txt` and its SHA-256, the tool pin and the pair-to-BA time. The
per-question time is 900 s in phase A (reading D1-D14) and 300 s in phase E. (Low) the 60 s
"not in the future" slack is documented (clock difference); Ctrl+C is tested (a child process
raising the pipeline stop at E2: STOP entry, the open question recorded as `interrupted`); each
printed block's SHA-256 is recorded. Wording (PM): plain-language A1, A2, E2, section D (no
driver jargon; references in brackets), the prompt `Press y for yes or n for no (N minutes).`,
`STOPPED. Nothing was sent to the headset. Tell the Arbiter: <reason>` as the last line, the
preview pictures with absolute paths, console lines wrapped at 90 characters. Re-pinned:
`fs-checklist3c.ps1`, `fs-observe3c.ps1`. Tests: CL1b, CL14b, CL16, CL17 new; CL2-CL4, CL8, CL9,
CL12, CL13 extended.

**Single temperature reading (PM, J-125; 2026-10-13; host and PM documents only, no device change;
branch `feat/single-reading-userbuild`, not yet reviewed).** PM executive decision (J-125, made a
requirement in J-126; an FS-R-010 §6 procedure change, to be disclosed in FS-A-012). It replaces the
settled pair: two readings at least 10 minutes apart, both below 350, the second at most the first
+ 5. The new rule is **one reading below 350 (35.0 °C), taken at most 15 minutes (900 s) before BA
starts, with the battery not charging at that moment.** "Not charging" means `dumpsys battery`
`status` 3 (discharging), 4 (not charging) or 5 (full). Status 2 (charging) fails, and so does 1
(unknown). Rationale: the two Unit 1 pairs of J-125 failed only because the battery was charging
(220 → 260). The rule now targets that cause directly, and the wait drops from 10 minutes to none.

- `fs-checklist3c.ps1 -Phase B`:
  - takes `-R1 -R1Utc -R1Status` (optionally `-R1Charge`); the pair form (`-R2 -R2Utc`) is
    removed;
  - checks `reading-input`, `below-350`, `not-charging`, `not-in-future` (at most 60 s ahead, as
    before) and `at-most-15-min-old` (at most 900 s old when phase B runs: BA follows B, so an
    older reading could never be within 900 s of BA);
  - records `Reading` (`R1`, `R1Utc`, `R1Status`, `R1StatusName`, `R1Charge`, `AgeSec`, `Rule`,
    `Ok`) in place of `Pair`;
  - the schema becomes `frameshift.fs-checklist3c.v2`, so an old v1 cycle file is not mixed in.
- `fs-observe3c.ps1`'s checklist gate:
  - requires a v2 file whose last B entry has `Reading.Ok` true;
  - re-checks `R1` < 350 and `R1Status` in {3, 4, 5};
  - ties the reading to BA: at or before BA's start and **at most 900 s before it** (the same
    bound as the pair's reading 2). The E-after-BF tie is unchanged;
  - `observe.json` field `ChecklistPairToBaSec` becomes `ChecklistReadingToBaSec`;
  - the dwell refusal and the abandoned-cycle record say "a new temperature reading".
- Printed text: D14 now ends "a new temperature reading and a new BA/BF" (SIGNOFF-3c D, checked
  by CL13).
- Documents: SIGNOFF-3c B and the WALKTHROUGH step 6 describe the single reading; the Arbiter
  runs phase B. §13 B and §14 step 4 below are the historical revision-3 drafts and are superseded
  here.
- Re-pinned: `fs-checklist3c.ps1`, `fs-observe3c.ps1`.
- Tests (test-host3c):
  - CL6 is rewritten (16 cases): 349 not charging passes with status 3, 4 or 5; exactly 900 s old
    and exactly 60 s ahead pass; 350, charging, unknown, 901 s old, 61 s ahead and malformed input
    fail;
  - CL8 gains the observer's boundaries: 900 s before BA and at BA's start accepted, 901 s and
    after BA refused; a reading edited to 350 or a status edited to 2 refused; a v1 file refused;
  - CL1, CL3, CL9, CL11, CL14 and CL17 are updated.
- The same branch adds the stage-3d user-build capture rows (`<withheld rows file>`
  and `<withheld document>`, test-host3c UB). They do not change stage 3c.

**Review fixes of the single-reading branch (2026-10-13; review GO-with-fixes, J-135; host and PM
documents only, no device change; branch `feat/single-reading-userbuild`, rebased on master 9847d0f+).**

- **MAJOR-1, the reading is text.** `-R1`, `-R1Status` (and `-R1Charge`) were `[int]` parameters,
  so `-R1 36.2` rounded to 36 and passed, `-R1 0` passed, and `-R1Status 2.6` rounded to 3. Now:
  - every value is a `[string]` and is checked as typed: the reading `^[0-9]{3}\z` (ASCII digits only;
    `\d` would also match other scripts' digits) and from 100 to 349 (check `range-100-349`; 350 = 35.0 °C and
    above fail), the status `^[1-5]\z` as input and `^[345]\z` to pass (`not-charging`);
  - `checklist3c.json` records the typed text; the schema becomes `frameshift.fs-checklist3c.v3`;
  - `fs-observe3c.ps1` applies the same text rules to the file (a number, or text that is not exactly
    three digits from 100 to 349, or a status other than exactly `3`, `4` or `5`, is refused);
  - and it cross-checks BA's own machine-captured `dumpsys battery` row **BA10** at attempt time
    (`Test-FsObsBa10`): from the BA `SUMMARY.txt` that `Read-FsObsPhaseSummary` accepted (this nonce,
    this serial, `PHASE BA OK`), the BA10 row must have exit 0, `BA10.txt` must hash to the recorded
    SHA-256, and its text must hold exactly one `temperature:` line below 350 and exactly one
    `status:` line of 3, 4 or 5. `observe.json` records `Ba10Temperature`, `Ba10Status`,
    `Ba10Level`, `Ba10Sha256`.
- **MAJOR-2, the reading belongs to a unit.** `-R1Serial` is required (`reading-input`) and must be
  one of the two Quest 3 units (`known-unit`); `Reading.R1Serial`/`R1Unit` are recorded. The observer
  has no default `-Serial` any more: an attempt without it, or with a serial of no Quest 3 unit, is
  refused (exit 2) before anything is written or any device is queried; the reading's `R1Serial`
  must equal `-Serial`; the BA/BF summaries must name it (as before). `-Preflight` needs no serial.
- **MAJOR-3, both units on the v2.7 user build.** `<withheld rows file>` names the
  unit as `{serial}`; `<withheld capture tool>` revision 9 substitutes `-Serial`, refuses such a file without
  an explicit `-Serial`, adds `shell id` (recorded only) to its allowlist, refuses anything naming
  `persist` before the allowlist (J-132) and `root`/`unroot`/`remount`/`verity` in its deny scan, and
  copies `#NOT-CAPTURED` lines (rows 11-15) into `SUMMARY.txt`. [removed for publication].
- **MINORs:** the BA10 rule reads "status 3/4/5" (not "not 2"); the WALKTHROUGH says the UTC time is
  the PC's UTC at the reading (`adb ... dumpsys battery; [DateTime]::UtcNow.ToString('o')`); phase
  B's age is compared exactly (ticks; `AgeSec` is display only: 900.04 s now fails); `RECOVERY.md`
  §1 states the single-reading rule.
- Tests (test-host3c): CL6 (30 cases, the MAJOR-1/2 and exact-age negatives), CL8 (52 cases: the text
  re-check, BA10, the unit), CL9 and CL9b (no default serial; Unit 2 cycle with Unit 1 attached),
  CL11 (the real CLI with `-R1 36.2`, `-R1Status 2.6`, `-R1 0`, no `-R1Serial`), UB1-UB6 (both units,
  `{serial}`, the persist and root refusals, a fake-adb capture end to end into the BA10 check).
  `fixtures/single-reading-before.ps1` runs 13 probes of the findings against the reviewed files of `9456035`:
  all 13 fail there for the reasons named (`single-reading-before.9456035.txt`) and pass now (`.after.txt`).
  `test-host3c.ps1 -Regression` in a full clone: 324 passed, 0 failed, 2 skipped (CL15 and Z2.2 need a
  `build\stage3c` candidate, absent in a clone); test-host2 456/456 there (its 3 real-dump misc cases need the
  gitignored `firmware\` dump; Y2 now expects 459 only when that dump is present), test-host3b 116/116.
- Re-pinned: `fs-checklist3c.ps1`, `fs-observe3c.ps1`, `<withheld capture tool>`.

**Second review of the single-reading branch (2026-10-13; GO-with-fixes, five MINORs; branch
`feat/single-reading-userbuild`).**

- **MINOR-1, malformed times are refused, never parsed.** Every UTC time the checklist or the observer reads
  (`-R1Utc`; the file's `EndUtc`, `StartUtc`, `R1Utc`; the BA/BF SUMMARY header) must be
  `yyyy-MM-ddTHH:mm:ss[.f to .fffffff]Z` in ASCII digits (`[0-9]`, not `\d`, which matches other scripts'
  digits) and is read with `ParseExact` (invariant culture) inside a try (`ConvertFrom-FsCl3Utc`,
  `ConvertFrom-FsObsUtc`). The lenient `[DateTime]::Parse` (no try) let such times through the `\d` regex into an
  exception (here, Windows PowerShell 5.1, `T24:00:00Z` and `:60Z` threw; the reviewer's runtime read `T24:00:00Z`
  as the next midnight and accepted it): the checklist CLI exited 70 instead of a STOP, and the observer's gate threw
  instead of refusing. Now every such time is a refusal. `fixtures/single-reading-before2.ps1` runs 8 probes of
  the five MINORs: all fail against `24553fc` (`single-reading-before2.24553fc.txt`) and pass now (`.after.txt`).
- **MINOR-2, BA10 temperature floor.** BA10's temperature must be 100 to 349, as the typed reading.
- **MINOR-3, an old reading does not carry over.** The reading must be later than every other BA of the
  cycle: the observer looks for every `BA\SUMMARY.txt` under the checklist's cycle directory (the first BA in
  `<cycle>\BA`, a retry in `<cycle>\retry-N\<nonce>\BA`) and for this nonce's abandoned-cycle records
  (`build\stage3c\abandoned\`); a BA (or an abandoned cycle's BA) that started at or after the reading and
  before this BA refuses the attempt: "take a new reading". So the reading is tied to the first BA after it,
  as D14 says ("a new temperature reading").
- **MINOR-4, the unit is always named.** `<withheld capture tool>` revision 10: `-Serial` is required (no Unit-1
  default; refused before anything runs); without `-CommandsFile` it uses `<withheld rows file>` (both units
  run the v2.7 user build, J-131/J-133); the root-shell `<withheld rows file>` only when named. The WALKTHROUGH (steps
  6, 7, 8, 10 retry, 17) and SIGNOFF-3c (C, E, F) pass `-Serial <serial>` and the user-build file, and
  `fastboot -s <serial> reboot`.
- **MINOR-5:** `Reading.Ok` must be a JSON boolean `true` (the text "true" is refused); the regex wording
  above matches the code; the observer also machine-checks BA10's level: exactly one `level:` line, above
  50 (SIGNOFF-3c C).
- Tests: test-host3c CL18 (in process and through the CLI: T24:00:00Z, :60Z, Arabic-Indic and fullwidth digits,
  31 September, eight fraction digits; forged file times and a T24 BA header; Reading.Ok "true"/1; BA10 099/50/100,
  level 50/51/none; the first-BA tie with an earlier BA, an abandoned-cycle record, another nonce's record, an
  unreadable one; the WALKTHROUGH retry with the old reading end to end), CL14b and UB3 (revision 10), test-host2
  P17-P18 (no `-Serial` refused; the default file is the user build's; P runs name `-Serial` and `<withheld rows file>`).
  `test-host3c.ps1 -Regression`: 325 passed, 0 failed, 2 skipped (CL15, Z2.2: no `build\stage3c` candidate in a
  clone); test-host2 458/458, test-host3b 116/116. `single-reading-before2.ps1`: 0/8 against `24553fc`, 8/8 now;
  `single-reading-before.ps1` still 13/13. Re-pinned: `fs-checklist3c.ps1`, `fs-observe3c.ps1`, `<withheld capture tool>`.

**Revision 3 changes (R-A review).**

| finding | change | sections |
|---|---|---|
| **B1** zpos 0 × 4 aliases the per-stage pipe slots | zpos is now **{0, 0, 1, 1}**: left pair at stage 1, right pair at stage 2 (as stock). New evidence row E15 | §1, §2 (E15), §3, §6.2, §7, §10, §11.1 (R2 SHOWN-QUAD, runner inconsistency), §12.3, §12.6, §13 D, §15 Q1 |
| **M1** `pipe_idx` is per pipe type | VIG vs DMA told apart by the caps blob's `max_upscale` (VIG 20, DMA 1); exactly 4 candidates or `unavailable:ambiguous`; fixture with DMA blobs at `pipe_idx` 0–3. Evidence row E16 | §2 (E16), §6.2, §12.3, §15 Q1 |
| **M2** the kernel rewrites CRTC_X for the right half | `post_plane` expects CRTC_X 0/1032/0/1032 and SRC_X 0/1032/2064/3096. Evidence row E17 | §2 (E17), §6.5, §7, §11.1, §12.3 |
| **M3** a refusal after the phase ran | `FSXE1` carries `ran=0\|1`; `ran=1` is handled like an FSB1-rejected record (readings + dark check, no next lit phase, `fs-done`) | §5.2, §5.7, §5.10, §12.3 |
| **M4** dot-sourcing `fs-collect.ps1` binds its param block in the caller's scope | `fs-collect3c.ps1` uses distinct parameter names, snapshots its arguments before the dot-source; a test-host3c case | §8.1, §12.3 |
| minor: copy/override list | explicit list of the `fs-collect.ps1` pieces that are reused, copied or replaced | §8.1 |
| minor: prompts | dark check still asked after `x` during a lit phase; Esc in character entry returns to the reading prompt; every answer echoed | §8.2 |
| minor: guards | `G_k` += DoneReserve 3 s; the 144 s counterexample restated per lit phase; (d, d) = 29 keys | §9.3, §9.4 |
| minor: timing | encode re-timed at a 56 KiB stream; r1 TW 2 s justified; the pause loop bounded | §5.3, §9.1, §12.3 |
| run 3 | **HOLD 5 s** (PHASE_WORST 37, G3 62, ≈ 8 s planning slack); the Q7 rehearsal is a go/no-go item | §1, §4, §5.3, §6.4, §9, §10, §13, §14, §15 Q7 |
| content | red luminance "comparable to, not above" the pattern mean [C]; a vertical-flip row; `i` defined as a half-turn; the preview shows every F variant | §6.3, §6.4, §8.2, §10, §11.2, §13 |
| Q16 | run 1 kept on the v0.5 split commit; SIGNOFF D discloses the 3 s 2 × 2064 garble if run 1 were lit | §6.1, §13 D, §15 Q16 |
| Q1(e) | lastclose resets custom properties, so the explicit zpos is required after run 1. Evidence row E18 | §2 (E18), §3 |
| build plan | §15 Q1 replaced by the B1/M1/M2 source citations; new propsim, host and replay fixtures | §12.3, §12.5, §15 Q1 |

**Authority.** The run happens under the PM's executive decision (J-107 decision 3):
repeat/diagnostic temporary `fastboot boot` runs on Unit 1 in the current stage line.
That decision still requires a full review of every new image and host-tool change,
a fresh nonce, the deadline and backstop, read-only probes, the settled pair, the
dwell gate, AF/AA, the ≥ 40 °C rule, and the PM present with sign-off. Anything
this design marks **new write class** goes to the Chair first and is **not**
implemented (J-107 Arbiter scope). Results go to the Chair afterwards in FS-A-012.

Tags (FS-R-001): [M] measured on hardware · [M-static] read from a named file ·
[D] derived · [C] inferred or hypothesis · [O] open.

Sources read: `docs/JOURNAL.md` J-107–J-109; `docs/research/display-pipeline-and-geometry.md`
(cited below as "research §x"); FS-R-010 (private review record), `FS-R-011.md`; `stage3b/*`
(incl. `src/fs-pattern.c` v0.5 `draw_eye`); `common/{OUTCOMES,FSB1-SPEC,DEADLINE,MISC-RULE}.md`,
`common/target/*`; `host/fs-collect.ps1`, `fs-observe.ps1`, `fs-classify3b.ps1`;
`SIGNOFF.md`; `RECOVERY.md`; `docs/research/serial-loss-trial3.md`,
`display-bringup-quest3.md` §2.1; `evidence/stock-display-20261010/capture-lit.txt`;
the decoded trial-(iii-b) payloads (scratchpad `garble/`: `3-pattern1.txt`,
`5-pattern2.txt`, probes).

---

## 1. What changes from stage 3b

1. **Interactive per-phase flow.** Stage 3b used one `fs-display` command and one
   record. Stage 3c uses four phase commands (`p0`, `r1`, `r2`, and `r3` if needed),
   one FSB1 record per phase, and PM prompts between phases while the panel is off.
2. **Run 2 commits 4 planes × 1032 px, one per layer mixer, with explicit zpos
   {0, 0, 1, 1}** (left pair at blend stage 1, right pair at stage 2, as stock;
   research D1; PM decision J-109 #1; E15). Planes are chosen from their capabilities
   blobs (pipe type from `max_upscale`, index from `pipe_idx`, E16): VIG0–3 first (the
   kernel's own splash layout), the stock DMA half-pairs as the second attempt. The 2 × 2064 layout that garbled is kept **only as a
   TEST_ONLY probe and is never committed** in run 2 or run 3. Run 1 is unchanged.
3. **A diagnostic pattern** (research D3): a distinct, chiral marker per mixer
   quadrant, a centre line per half to read the panel roll, the per-run characters
   kept, inside the reviewed brightness envelope (§6.3).
4. **Optional run 3.** Same layout and brightness as run 2, a **5 s** hold, with a
   plain red full-field frame. It runs only if the PM reports run 2 as garbled or lit with
   no pattern.
5. **More read-only logging (GET ioctls, sysfs, /proc only).** A post-commit state
   snapshot, the planes' capabilities fields, full property lists, a wider dmesg
   filter, more TE/BLU interrupt points. **No debugfs mount** (PM decision J-109 #2);
   the underrun-counter read is a proposal for the Chair (§7.1).
6. **Live phase markers** (`FSPM1`), with banners and audible sounds on the host.
7. **A device-side idle limit** (120 s) on top of the unchanged DEADLINE 200 s and
   backstop 201 s.

Everything else in the safety envelope (§10) is unchanged.

---

## 2. Evidence this design rests on

| # | fact | tag | source |
|---|---|---|---|
| E1 | Run 2 committed `4128x2208x90vid` from an inactive CRTC, layout **split** (2 × 2064, planes 71+97, modeset). The single 4128-wide attempt was rejected with rc=−7 (E2BIG). | [M-static] | `5-pattern2.txt` seq 63–65 |
| E2 | Run 1 also committed split + modeset on the **active** splash CRTC (planes_off=2), held 3 s, close_rc=0. TE stayed 0, no light (splash-handoff path skips the panel power-on, research §A.6). | [M-static] | `3-pattern1.txt` seq 127–133; J-108 |
| E3 | Before run 1, all 20 planes had **zpos = 0**; 71/97/100/103 were bound to CRTC 155 (splash). Twenty planes imply the driver's custom-client mode, where every plane's zpos defaults to 0 and the maximum is 10. | [M-static]; [D] | `3-pattern1.txt` seq 89–124; research §A.3 (`sde_plane.c:4162-4178`, `sde_kms.c:2185-2191`) |
| E4 | Plane ids map to pipes: 71/97/100/103 = VIG0–3; 106–121 = DMA0–5 rect 0; 124–140 = DMA0–5 rect 1; 143–152 = VIG rect 1. Each plane's `capabilities` blob carries `pipe_idx`, and the rect-1 planes carry `primary_smart_plane_id`. All support XR24 and report `max_linewidth=5120`. | [D] from [M-static] | research §A.3 (`sde_kms.c:2166-2200`, `sde_plane.c:3972-4041`); `3-pattern1.txt` seq 37–124 |
| E5 | Stock Android scans out 4 rects of 1032: 115+134 (DMA3 rect 0/1) on the left half, 112+131 (DMA2 rect 0/1) on the right; src_x 0/1032/2064/3096; multirect parallel; AB24 UBWC; 4 mixers; core_clk_rate 503028768. | [M] | `capture-lit.txt` 374–434; research §A.3 |
| E6 | The CRTC `core_clk` property read **550000000** before run 1; `core_ab`/`core_ib` read 16e9. Unset votes mean the kernel votes these maxima. | [M-static]; [M-static] source | `3-pattern1.txt` seq 87; research §A.4 (`sde_core_perf.c:133-140`) |
| E7 | Connector topology_name was `sde_none` (0) before both runs; `dsc_mode` 0. `mode_properties` is 5473 B (logged as length only, rc=−27). The connector `capabilities` blob (id 56) was not logged. | [M-static] | seq 59–60, 85 |
| E8 | The mode requires 4 LM / 4 DSC / 2 INTF (`qcom,display-topology = <4 4 2>`; the kernel adds mixers until clock per LM ≤ max). `qcom,disable-default-pps`: no PPS is sent. A KMS client neither can nor needs to touch DSC. | [M-static] | research §A.2; stock dmesg `capture-lit.txt` 487–493 |
| E9 | **Per-rect width limit.** Each rect must deliver its width in one 2.154 µs line (vtotal 5158): W_max ≈ 550 MHz / (5158 × 90 × 1.05) ≈ **1128 px**. 2064 px needs ≈ 1.006 GHz; 1032 px needs 503 MHz. The SDE driver does not check this (an over-wide rect passes TEST_ONLY and underruns); mainline DPU splits on the same criterion. Lowering the refresh rate does not help (VFP-stretch DFPS). | [D] from [M-static] | research §A.4 |
| E10 | The splash handoff staged VIG0–3 (71/97/100/103), one per mixer. | [M-static] | research §0 item 3; `display-handoff-dark.md` §2 |
| E11 | Staging rules: at most **2 planes per blend stage per half** in the atomic check (the commit-time stage slots are per CRTC: E15); a pair sharing a stage in a half must be contiguous in x with equal y/h; the lower-id-left rule is waived on anorak (`qcom,sde-pipe-order-version = <1>`); with `sspp_layout` none, global x ≥ 2064 moves to the right half and a plane must not cross x = 2064; no `meta,swap-mixers` in the v66 DTB, so LM0/LM1 are the left half. If both rects of one SSPP are staged and `multirect_mode` is unset, the driver picks the multirect mode itself. | [M-static] | research §A.3 (`sde_crtc.c:5866-5890`, `:1849-1928`, `:5955-6018`, `:3925-3945`; `sde_hw_catalog.c:627`, `:4094`, `:4109`) |
| E12 | **Precedent:** `machachu56/quest-kexec-q2` drove a Quest 2 through Meta's stock SDE driver; one plane across both mixers gave "rows of small purple blocks", one half-width plane per mixer (XR24 linear, no modifier) displayed correctly. | [M-static] / [C] causal claim | research §B.1 |
| E13 | Panels are mounted 180° and rolled ≈ 21° in-plane (`ro.boot.bootloader_screen_rotation=201`, comment "21 + 180"); lens axes sit nasal and high of each panel's centre; the 480/456 px recovery margins keep text inside the visible lens area. | [M-static] / [D] / [C] | research §C.1, §C.3, §C.7; `display-bringup-quest3.md` §2.1 |
| E14 | The PM saw fine regular R/G/B stripes ("raw LCD pattern"), **no structure at all**, could not tell the phase boundaries, and heard no console beeps. | [M] (PM report) | J-107; J-109 PM decision 3 |
| E15 | **Stage slots are per CRTC, not per half.** The atomic check counts planes per (zpos, layout), so four planes at zpos 0, two per half, pass TEST_ONLY (`sde_crtc.c:5866-5890`, reset at `:5871`, limit at `:5885`). The commit-time blend setup runs once per CRTC and indexes `stage_idx = zpos_cnt[pstate->stage]++` per stage only (`:2053`, `:2134-2139`) into `stage[SDE_STAGE_MAX][PIPES_PER_STAGE]` with `PIPES_PER_STAGE` = 2 (`sde_hw_ctl.h:74`, `sde_hw_mdss.h:35`): the third and fourth plane at one stage alias into the next stage's slots. With zpos {0, 0, 1, 1} each stage holds exactly 2. Without a base layer, stage = zpos + `SDE_STAGE_0` (`:5894`), so {0, 0, 1, 1} gives stages 1 and 2, as stock (E5). | [M-static] (R-A) | near-match tree @ `23c97b254` |
| E16 | **`pipe_idx` is per pipe type**: VIG n, RGB n and DMA n all report `pipe_idx` = n (`sde_plane.c:4031-4040`). The same blob carries `max_upscale` (`:4018`): 20 for VIG (`MAX_UPSCALE_RATIO`, `sde_hw_catalog.c:74`, `:1541`), 1 for DMA (`SSPP_UNITY_SCALE`, `:76`, `:1829`). Rect-1 planes carry `primary_smart_plane_id` (`sde_plane.c:3985`). | [M-static] (R-A) | near-match tree |
| E17 | **The kernel rewrites CRTC_X for the right half.** With `sspp_layout` none, a plane at global x ≥ 2064 gets `crtc_x -= 2064` and layout RIGHT in the stored plane state (`sde_crtc.c:5991-5999`). A GET of CRTC_X after the commit therefore reads 0/1032/0/1032 for the planned 0/1032/2064/3096; SRC_X is not rewritten. | [M-static] (R-A) | near-match tree |
| E18 | **lastclose resets custom properties** (incl. plane `zpos`) to their defaults (`sde_kms.c:2710-2770`, called from `sde_kms_lastclose` at `:2811`). After run 1's close every plane's zpos is back at its default; run 2 must set it explicitly. | [M-static] (R-A Q1(e)) | near-match tree |

---

## 3. Match stock: what the run-2 commit sets (research §A.8)

The existing write class is one atomic commit setting FB_ID, CRTC_ID, SRC_X/Y/W/H
and CRTC_X/Y/W/H on planes, MODE_ID and ACTIVE on the CRTC, and CRTC_ID on the
connector, plus the one reviewed brightness write. **PM decision J-109 #1:** an
explicit `zpos` on the quad planes is part of that reviewed commit (a standard DRM
plane property, runtime state only, nothing persistent), not a new write class. It
is disclosed in FS-A-012.

| item | stock (E5) | stage 3c run 2 / run 3 | write class |
|---|---|---|---|
| rects | 4 × 1032, one per LM | 4 planes: `SRC_X` = `CRTC_X` = 0/1032/2064/3096 (global coordinates), `SRC_W` = `CRTC_W` = 1032, y 0, h 2208, no scaling | existing |
| pipes | DMA3 r0+r1 (left), DMA2 r0+r1 (right) | **a0 `quad_vig`: VIG0–3** (expected 71/97/100/103, the splash set, E10; no multirect). **a1 `quad_dma`: the stock DMA half-pairs** (expected 115+134 / 112+131). Selected from each plane's capabilities blob (type from `max_upscale`, index from `pipe_idx`, rect from `primary_smart_plane_id`; E16), never from hard-coded ids (§6.2) | existing (ids and blobs are GET only) |
| zpos | stage 1 (left), stage 2 (right) | **`zpos` = {0, 0, 1, 1}** for the planes at x 0/1032/2064/3096, set in the same commit. The left pair sits at stage 1, the right pair at stage 2, exactly as stock. Each stage then holds exactly 2 contiguous planes of one half with equal y/h: within the ≤ 2-per-stage-per-half check (E11) **and** the per-CRTC stage slots of the blend setup (E15). zpos 0 on all four would pass TEST_ONLY and then alias the third and fourth plane into the next stage's slots at commit (E15). Explicit values are required in any case: run 1's lastclose resets zpos to its default (E18) | **reviewed commit (PM J-109 #1)** |
| multirect | parallel (auto) | not set; for `quad_dma` the driver selects it (E11) | — |
| `sspp_layout` | left/right | not set (none); the kernel converts global x, no plane crosses x = 2064 | — |
| pixel format | AB24 + UBWC, fb 4160 wide | **XR24 linear** dumb buffer, pitch 16512. UBWC is not required and a dumb buffer cannot be UBWC; XR24/AB24 differ only in R/B order (research §A.5) | existing |
| clock / bandwidth | votes 503 MHz, ≈ 6.2 GB/s | **unset**: the kernel votes the maximum, 550 MHz and 16 GB/s (E6). Linear needs ≈ 3.3 GB/s average, ≈ 7.6 GB/s line-burst peak [D] | — |
| rotation | `ROTATE_0` (1) | not set (default 0°); 180° per half drawn in the buffer, as v0.5 | — |
| DSC / topology | from the DT (E8) | **never set `topology_control` or `dsc_mode`** (or any DSC property). `topology_name` and `dsc_mode` are logged after the commit | — |
| panel wake | normal enable from inactive | unchanged: run 1 consumes the splash (2 × 2064, reported dark in trial (iii-b): no panel-on sent [D], BLU IRQ 0 [M]; not zero emission, FS-R-010 §2; E2), lastclose, then run 2's full modeset from a provably inactive CRTC | existing |

**Consequences.**
- If TEST_ONLY rejects both quad attempts (or neither has 4 eligible planes), run 2
  commits **nothing**: exit 50, NO-DISPLAY, with each attempt's rc and the split
  probe's rc in the record. There is no fallback to the 2 × 2064 commit (E9: it is
  known to garble). Run 3 is then not requested (§5.8 rule 1).
- If a quad layout is committed and the PM still reports a garble, the throughput
  explanation (E9) is wrong or incomplete. Run 3 then separates content-dependent
  from content-independent faults (§11.3), and FS-A-012 proposes the next step
  (e.g. the §7.1 underrun read).

**Precedent and credit.** The one-plane-per-mixer layout follows the public work of
`machachu56/quest-kexec-q2` (branch `quest2-port` @ `9c96c192d`, Quest 2 on Meta's
stock SDE driver; research §B.1), which found and documented the same failure class
and its cure. **No code is copied**: fs-pattern keeps its own reviewed request
builder. The repository's licence checked 2026-10-12: GPL-2.0 (root LICENSE; its Monado driver files BSL-1.0; research "Licence check"); citation only; FS-A-012 and the stage-3c README credit the project.

---

## 4. Session flow

```
host (fs-collect3c)                         device (/bin/fs-phase, fs-pattern v0.6)
-------------------                         ---------------------------------------
fs-verify / fs-ack / fs-status   (unchanged, stage-1 helpers)
guard G0 ─ fs-phase p0 <c0> 0000000000000000 ─▶ FSPM1 begin · hash ∥ probe0 (mods, WRITE 127, read-back)
                                              ◀─ FSPM1 rec · FSB1 record s3c_p0 · prompt
banner LOOK NOW + sound START (3 s cue, no prompt: nothing is lit yet)
guard G1 ─ fs-phase r1 <c1> <p0.sha16> ────▶ FSPM1 begin · probe1 pre · FSPM1 go · run 1 show 3 s (v0.5 commit path)
           banner/sound at go and end        FSPM1 end · post · FSPM1 rec · record s3c_r1 · prompt
PROMPTS (panel off): left, right [, chars], dark-check   → readings, timestamped
guard G2 ─ fs-phase r2 <c2> <r1.sha16> ────▶ (≥ 2 s since run 1's close, device-enforced) · probe2 pre ·
                                             FSPM1 go · run 2 show-off-quad 10 s · FSPM1 end · post ·
                                             FSPM1 rec · record s3c_r2 · prompt
PROMPTS (panel off): left, right [, chars], dark-check, then layout items (§8.2)
if R3 rule (§5.8) and guard G3:
         ─ fs-phase r3 <c3> <r2.sha16> ────▶ run 3 show-off-solid 5 s (red field) · record s3c_r3
PROMPTS: left, right (run-3 key set), dark-check
fs-done (gated) ───────────────────────────▶ FSD1 queued · PID 1 reboots to fastboot (~1 s)
```

Each lit phase shows **different characters**: the first 8 hex digits of *that
phase's* challenge. A correct run-2 reading therefore cannot be a frame retained
from run 1 [D].

---

## 5. Protocol

### 5.1 Host → device commands

Only through `New-FsCommand` (fixed verb table, global check `^[a-z0-9 -]+$`). One
new verb, added to `$script:FsCmdSpec` at run time by `fs-collect3c.ps1` (the pinned
`fs-collect.ps1` file is not edited):

```
fs-phase <ph> <chal> <prev>
  <ph>   = p0 | r1 | r2 | r3
  <chal> = 32 lowercase hex, fresh per phase (New-FsHex 16)
  <prev> = 16 lowercase hex: the first 16 hex of rec_sha256 of the previous
           phase's VALID record, as the host decoded it; p0: 0000000000000000
FsCmdSpec['fs-phase'] = '^(p0|r1|r2|r3) [0-9a-f]{32} [0-9a-f]{16}\z'
```

Unchanged: `fs-verify`, `fs-ack`, `fs-status`, `fs-done` (no argument). Each command
is sent **once**. A phase is never retried (FS-R-005 §5, FSB1-SPEC §6).

### 5.2 Device refusals (`/bin/fs-phase`)

A refusal prints exactly one line, `FSXE1 p=<ph|-> ran=<0|1> error=<why> END`.
`ran=0`: nothing of the phase ran (no marker precedes it, no step was spawned).
`ran=1`: the phase's steps ran (the lit step included, for r1–r3), so markers
(`begin`, `go`, `end`, `skip`) may precede it; no complete record exists.
**The `rec` marker (integration pass, one rule on both sides):** `rec` means "the
paced emission starts now" (§5.4), so it is printed only after every pre-emission
check has passed. `step<i>`, `end` and `record-too-large` are decided **before**
`rec`: no `rec` precedes them. `emit-<rc>` is the only refusal after `rec`: the
sequence is `… rec`, then possibly a partial record, then the `FSXE1` line. With the
pinned pacer (`fsb1-pace.sh`, rc 2/3/4 returned before any byte is written) an
`emit-<rc>` arrives in practice right after `rec` with no record bytes; a partial
record would need a tty write failure, which the pacer does not report (the host
then sees no completion: nothing is sent, §5.7). The marker is informational only
either way; the host's handling of `ran=1` does not depend on it. The host treats either
as terminal for the session: INCONCLUSIVE for that phase, no further phase, then
the gated `fs-done`. A `ran=1` refusal of a lit phase is handled like an
FSB1-rejected record (§5.7): readings and dark check first. Checks, in order:

| why | ran | condition |
|---|---|---|
| `usage` | 0 | not exactly 3 arguments, or bad grammar (same as the host regex) |
| `bad-nonce` | 0 | `/run/fs.nonce` is not 16 hex |
| `order` | 0 | `<ph>` is not the next allowed phase: p0 → r1 → r2 → r3. Nothing after r3. r3 only after r2. Nothing after a refusal of any phase (`/run/fsb3c/closed`; build review: `/run/fsb3c` is made before the first check, so even a `usage` refusal of the very first command closes the session). |
| `already-run` | 0 | `mkdir /run/fsb3c/<ph>` fails (one run per phase per boot) |
| `chain` | 0 | `<prev>` ≠ the device's own `/run/fsb3c/<prevph>.sha16`, which it took from its own END line. For p0: ≠ 16 zeros. |
| `time` | 0 | `/run/fs.deadline` − uptime < `PHASE_WORST_<ph>` + 5 s (device-side headroom; `init.sh` writes `/run/fs.deadline` = T0 + DEADLINE, fork-free, right after `fs_hold_init`) |
| `begin` | 0 | the encoder's `begin` failed; it runs before the first step is spawned |
| `step<i>`/`end`/`emit-<rc>` | 1 | an encoder failure after the steps were spawned (as 3b); after the `rec` marker every pacer failure is `emit-<rc>`, rc 3 included (build review NIT-1) |
| `record-too-large lines=N max=M` | 1 | the finished record exceeds `MAXLINES_<ph>` (as 3b `FSDE1`). The phase did run; the record is not emitted. |

`ran` is fixed by the refusal point in `fs-phase.sh` (a static table, checked by
`c-record-too-large` and a new `c-step-fail` fixture), never by the host.

The chain check is defence in depth for "no lit phase after a lost or invalid record"
(§5.7). A host without a valid previous record has no `<prev>` to send.

### 5.3 Per-phase FSB1 records

The framing is unchanged (FSB1 v1, `fsb1-enc.sh` rev 5, `fsb1-pace.sh`, 20 lines per
0.1 s). Each phase has its own `exp`, its own challenge, and a fixed step list. A run
that does not happen is still a step: `FSK1 run=<n> skipped reason=<why> END`, under
`fs-supervise -t 2 -g 1 -c 256`, as in 3b.

| phase | exp | steps (i: id, program, fs-supervise bounds) | MAXLINES |
|---|---|---|---|
| p0 | `s3c_p0` | 1 `hash` `busybox sha256sum /bin/fs-pattern` `-t 2 -g 1 -c 256` (concurrent) · 2 `probe0` `fs-probe.sh p0` `-t 8 -g 1 -c 16384` (irq0, mods incl. cmdline and dmesg, **the write 127** and read-back) | 360 |
| r1 | `s3c_r1` | 1 `probe1` `fs-probe.sh r1` `-t 24 -g 1 -c 16384` (read-back, pre, go+1 s irq, mid pair at 1.5 s, end irq, post) · 2 `pattern1` `fs-pattern show <c1[0:8]> 3` `-t 9 -g 3 -c 57344` | 1545 |
| r2 | `s3c_r2` | 1 `probe2` `fs-probe.sh r2` `-t 32 -g 1 -c 16384` (mid at 5 s) · 2 `pattern2` `fs-pattern show-off-quad <c2[0:8]> 10` `-t 16 -g 3 -c 57344` | 1545 |
| r3 | `s3c_r3` | 1 `probe3` `fs-probe.sh r3` `-t 26 -g 1 -c 16384` (mid at 2.5 s) · 2 `pattern3` `fs-pattern show-off-solid <c3[0:8]> 5` `-t 11 -g 3 -c 28672` | 945 |

MAXLINES matches the caps (3b review M1 rule): 4 framing lines + every stdout at
its cap/48 + the hash stderr cap. That gives p0 4 + 6 + 6 + 342 = 358 ≤ 360;
r1/r2 4 + 342 + 1195 = 1541 ≤ 1545; r3 4 + 342 + 598 = 944 ≤ 945.
`check-timing-3c.py` asserts these numbers. No record within its caps can be
refused.

**Device-side gates (registered skips, not refusals).**
- r1: the p0 write evidence exists (`/run/fsb3c/p0.bl` = `127`, write_rc 0); probe1's
  pre has finished within TW = 2 s; the read-back is `127`. Otherwise the skip reason
  is `brightness-not-verified`, `probe-late` or `p0-write-missing`.
  *Why TW = 2 s for r1 (3b used TW1 = 3 s):* in 3b, probe1 did the mods read (dmesg,
  cmdline), the write and the read-back before pre1, all inside TW1. In 3c those
  moved to p0, so probe1's pre is one builtin read-back plus the builtin node
  snapshot, no dmesg and no fork: the same work 3b's pre2 did under TW2 = 2 s. A late
  pre only skips the run (`probe-late`, the safe direction; fixture `c-probe-hang`).
- r2: run 1's gate exactly as 3b: supervisor `end=exited code=0 sig=0 … strays=0
  pipes=eof why=none`, `commit rc=0`, `hold_end rc=0 reason=deadline … close_rc=0`,
  `exit … shown=1`, `eos … dropped=0`. Also: the read-back is 127, and the pause is
  ≥ 2 s since run 1's close. The device waits (fork-free) until uptime ≥
  `r1.end_up` + 2.0. **The wait is bounded:** it computes `rem = r1.end_up + 2.0 −
  uptime` once; if `rem` > 2.0 or either uptime is unreadable, the run is skipped
  (`pause-fault`); otherwise it loops at most 20 × `read -t 0.1` on the private FIFO,
  re-reading `/proc/uptime` each time, and skips (`pause-fault`) if the condition is
  still false after the 20th iteration. So PAUSE ≤ 2 s plus loop overhead, as §9.1
  assumes. The same loop serves r3. Run 2 itself commits only from a provably inactive
  CRTC (exit 31 otherwise).
- r3: run 2 committed a **quad** layout, held and closed cleanly (the same grep set on
  pattern2's stdout plus `commit … layout=quad_`); read-back 127; pause ≥ 2 s since
  run 2's close; inactive CRTC (exit 31). The device does not know the PM's readings.
  The host decides whether to request r3 (§5.8).

### 5.4 Live phase markers (`FSPM1`)

**Grammar** (one line, written by `fs-phase` with one `printf` builtin, ≤ 64 bytes):

```
FSPM1 n=<nonce16> p=<p0|r1|r2|r3> e=<begin|go|end|skip|rec> t=<uptime_ms> END\n
```

`t` is `/proc/uptime` × 1000, read with the `read` builtin (fork-free). It is the
boot-time clock, not fs-pattern's CLOCK_MONOTONIC. The two agree within a boot when
there is no suspend [C].

| event | when | host action |
|---|---|---|
| `begin` | after all refusal checks pass and the lock is taken | log only |
| `go` | the pattern step has been spawned (the commit follows within about 0.1–1.5 s, E1/E2) | banner **RUN n STARTING – LOOK** (black on yellow) + sound START |
| `skip` | the run is replaced by its skip step | banner RUN n SKIPPED (neutral, no reason shown before the readings) |
| `end` | the pattern step's supervisor has returned (the fd is closed, the hold is over) | banner **RUN n ENDED** (black on green) + sound END |
| `rec` | immediately before `fsb1_emit_paced`, after every pre-emission check (§5.2) | log only (the record follows; only an `emit-<rc>` refusal can follow instead) |

**Coexistence with FSB1 and the serial-loss lessons.**
- At most 4 markers per phase (< 260 bytes), all **before** the record's leading
  empty line; **none** during or after the paced emission, so the paced chunk sizes
  (≤ 2.3 KB per write, FSB1-SPEC §9) are unchanged.
- A marker never contains `FSB1` (so `stray-fsb1-line` cannot trigger) or a CR, and it
  sits outside BEGIN…END. The decoder ignores it as a non-record line (FSB1-SPEC §4).
- Markers are **informational only**. The classifier never derives a verdict from them;
  it cross-checks their order and nonce and reports a mismatch as a note.
- The host parses markers with a strict regex; a wrong nonce or bad grammar is logged
  and ignored. **No marker can cause a write.** Writes come only from the fixed
  command table.
- The host keeps reading the port every 50 ms in every state, including prompts.
  Sounds play **asynchronously** (`SoundPlayer.Play()`, never `PlaySync`).
- After the record, `fs-phase` writes nothing and exits. The shell prompt follows. The
  send gate (zero bytes since the settled prompt) stays meaningful.

### 5.5 Challenge and nonce binding

- Every record's BEGIN/END carry the image nonce and **that phase's** challenge. The
  host validates each phase slice with `Test-Fsb1Record -Exp s3c_<ph> -Nonce <n>
  -Challenge <c_ph> -Steps <list>` (`common/host/fsb1.ps1`, unchanged).
- The pattern nonce (`chal[0:8]`) differs per phase, so a reading names its run.
- The chain argument binds phase k+1 to the host's decode of phase k's record.
- The record of the first phase does not prove a stage-1 handoff on its own. That
  comes from the verified FSV1 earlier, as before.

### 5.6 Capture slicing

One raw capture, `capture.raw`, plus `capture.raw.idx`, both unchanged in format.
The slice of phase k runs from its W line's send offset to the end of its settled
prompt (or the phase deadline). Each slice is saved as `phase-<ph>.raw` with its
SHA-256 and validated on its own, so a slice contains at most one BEGIN.
`fs-classify3c.ps1` re-derives the slices from `capture.raw` and the index, and
refuses if they differ from the collector's.

### 5.7 Lost or invalid phase records

| situation | prompts? | next lit phase? | recovery |
|---|---|---|---|
| record complete and VALID, prompt settled | yes | if the guard and rules allow | — |
| record complete but FSB1-rejected (e.g. serial loss), prompt settled | **yes**, for that run (light may have happened) | **no**, never | gated `fs-done` |
| refusal `FSXE1 … ran=0` | no (nothing ran) | no | gated `fs-done` |
| refusal `FSXE1 … ran=1` (`step<i>`, `end`, `emit-<rc>`, `record-too-large`), prompt settled | **yes** for r1–r3, exactly as an FSB1-rejected record: per-eye readings and the dark check (light may have happened); p0: none (not lit) | **no**, never | gated `fs-done` |
| no completion by the phase deadline (PHASE_WORST_k + 5 s, capped by the give-up) | no (state unknown; the panel state is unknown too) | no | **nothing is sent** (the collector's no-write-from-an-unknown-state rule, `host/COLLECTOR.md`; not one of the run-3 rules of §5.8, which are numbered 1–5 everywhere). The device's idle limit (§5.9) or DEADLINE recovers. The PM is told to look away and wait. |
| bytes arrive while idle or prompting (the tail changed) | the prompt in progress is finished; no new prompt | no | no `fs-done` (gate refuses). Idle limit or DEADLINE. |

A lit phase is **never** re-sent or retried. "Continue only if safe" means: the next
lit phase only after a VALID previous record and a settled prompt.

### 5.8 The run-3 rule (host, after run 2's readings)

The host sends `fs-phase r3` only if **all** of these hold:
1. r2's record is VALID, and its pattern step committed a **quad** layout, held and
   closed cleanly (from the decoded record; used for control flow only, not shown to
   the PM).
2. At least one eye's run-2 reading is `a` (lit, no pattern) or `c` (garbled).
3. Neither eye is `d` with the correct 8 characters. A correct reading in either eye
   means run 2 already answered the question.
4. The run-2 dark check is `y` (dark now).
5. Guard G3 passes (§9.3).

Otherwise the session goes to the gated `fs-done`. The reason (rule number) is
printed only after the readings are complete. The layout items (§8.2) never affect
this rule.

### 5.9 Device idle limit (`/lib/fs/fs-idle.sh`, started by `init.sh`)

- Started once by `init.sh` (a PID 1 subshell, before SHELL_READY) with stdin,
  stdout and stderr on `/dev/null`. It **never writes the tty**.
- Its loop forks nothing: `read -t 1` on a private FIFO and a builtin `read` of
  `/proc/uptime`. It stays unarmed until `/run/fsb3c/activity` exists (p0 started).
  Before p0, the ack window and DEADLINE cover.
- `fs-phase` writes the uptime to `/run/fsb3c/activity` at each phase start and end,
  and holds `/run/fsb3c/running` during a phase.
- **Rule:** if no phase is running and now − activity ≥ **IDLE_S = 120 s**, it
  writes `/run/fs.collected` (token `idle`). If a phase has been "running" for ≥
  IDLE_S + 60 s (a stuck runner), it does the same. `pid1-hold.sh` (rev 5, pinned,
  unchanged) reboots within about 1 s of seeing that file. This is the existing
  `fs-done` path: it can only **shorten** the hold and never touches DEADLINE.
- The host keeps every gap below IDLE_S − 10 = 110 s: prompts close at
  `last_phase_end + 110 s` at the latest (§8.3).
- The value: if the host crashes after r1 (record at ≥ ~45 s), the device recovers by
  ≈ 165 s instead of 200 s. If the device firing goes unnoticed, the only cost is a
  failed next send.

### 5.10 The `fs-done` path

Unchanged verb and gate (`Invoke-FsPhase 'fs-done' … -NoPrompt`). It is sent only
from a known state (the last phase completed with a settled, expected prompt) and
only before the give-up. It is sent on: the normal session end, `x` (abort), any
prompt timeout, a dark-check `n` (light still visible), a guard refusal of the next
phase, the run-3 rule false, an FSB1-rejected record, or a refusal (`ran=0`
directly; `ran=1` after the readings and dark check). Prompts are cut at `GiveUp −
DoneReserve` (3 s) so `fs-done` can still pass the gate; DoneReserve is also part of
every guard (§9.3).

---

## 6. fs-pattern v0.6

### 6.1 Modes

```
fs-pattern show            NONCE HOLD_S [DEV]  # run 1: v0.5 `show` commit path, TEST_ONLY order, layouts and hold, unchanged; v0.6 picture
fs-pattern show-off-quad   NONCE HOLD_S [DEV]  # run 2: inactive-CRTC precondition (exit 31 as v0.5), split probe (TEST_ONLY only), quad_vig, quad_dma
fs-pattern show-off-solid  NONCE HOLD_S [DEV]  # run 3: as show-off-quad, buffer = solid red; NONCE only labels the stream
fs-pattern show-off        NONCE HOLD_S [DEV]  # kept, = v0.5 (fixtures only; not called by fs-phase)
fs-pattern render | render-solid | holdtest    # offline
```

**Policy (build review, wording only).** Run 1 (`show`) deliberately **commits** the
reviewed v0.5 2 × 2064 split request: it is the wake step (Q16; PM: "run 1 unchanged").
The rule "the 2 × 2064 split only as TEST_ONLY" applies to the **quad modes** (runs 2
and 3, `show-off-quad` / `show-off-solid`): there the split request is a probe and only
a quad layout can be committed. `check_static.py` checks both halves of this rule.

`FSP_HOLD_MAX_S` stays 10. `hold()` is **textually identical** to v0.5 (static
fixture). Exit codes: v0.5's table (31 = precondition unmet, 50 = every attempt
rejected). There is no new exit code.

**Run 1 stays on the v0.5 plan** (its accepted layout on this path is split,
2 × 2064, E2). It is the known-dark takeover step that preceded the full enable
which lit run 2. Keeping its commit unchanged preserves that wake sequence; it is
not a display attempt. **R-A (Q16): kept.** The panel wake comes from run 2's full
modeset from an inactive CRTC and does not depend on run 1's plane layout, so a quad
run 1 would gain nothing for the wake and would change a proven step. If run 1 were
lit after all, the PM would see the known 2 × 2064 garble for 3 s, inside the
reviewed envelope; SIGNOFF D discloses this.

### 6.2 The 4-plane plan (show-off-quad, show-off-solid)

**Plane facts read (GET only).** For every plane: GETPLANE, the property list, and
the `capabilities` blob (GETPROPBLOB, as v0.5 already does for `max_linewidth`),
parsed for the `key=value` entries `pipe_idx`, `max_upscale` and
`primary_smart_plane_id` (key names and encoding from the near-match source, E16).
**`pipe_idx` alone does not name a pipe**: it is the index within the pipe's type, so
VIG0 and DMA0 both report 0 (E16). The type comes from `max_upscale`: **20 → VIG**,
**1 → DMA**; any other value, or a missing key, makes the plane `type=unknown` (not
selectable). Whether `NV12` appears in `pixel_formats` is logged per plane as a
corroboration only, never a gate (DMA format lists may carry YUV formats on some
catalogs).

**Eligible plane:** GETPLANE ok, XR24 in its format list, possible on our CRTC
index, type ≠ cursor, `crtc_id` 0 or ours, all 10 layout properties and `zpos`
found, and the capabilities blob parsed with `pipe_idx` and `max_upscale` present.

**Exactly four candidates.** Each attempt builds its candidate set from the eligible
planes by rule, then requires **exactly** one plane per slot (4 in all). Zero
candidates for a slot → `unavailable:missing`; two or more for a slot (e.g. two
rect-0 planes claiming VIG2) → `unavailable:ambiguous`. An unavailable attempt
issues no TEST_ONLY.

**Attempts** (each TEST_ONLY with ALLOW_MODESET; the first accepted **quad** attempt
is committed once; no retry):

| # | tag | planes (rule; expected on v66) | geometry | may be committed? |
|---|---|---|---|---|
| p | `split_probe` | v0.5 `split` request (pri + helper, 2 × 2064, modeset), built by the unchanged v0.5 code | v0.5 | **never**: TEST_ONLY only, rc logged |
| a0 | `quad_vig` | slots k = 0…3: the eligible plane with type **VIG** (`max_upscale` 20), `pipe_idx` = k and **no** `primary_smart_plane_id` (rect 0). Expected 71/97/100/103 (the splash set, E10) | plane k (k = 0…3): `SRC_X` = `CRTC_X` = 1032·k, `SRC_W` = `CRTC_W` = 1032, `SRC_Y` = `CRTC_Y` = 0, `SRC_H` = `CRTC_H` = 2208, **`zpos` = 0, 0, 1, 1** for k = 0, 1, 2, 3 | yes |
| a1 | `quad_dma` | slots: type **DMA** (`max_upscale` 1) `pipe_idx` 3 rect 0; the plane whose `primary_smart_plane_id` is that rect 0's id (DMA3 rect 1); DMA `pipe_idx` 2 rect 0; its rect 1. Expected 115, 134, 112, 131 (stock, E5) | same x order 0/1032/2064/3096 and values, **`zpos` = 0, 0, 1, 1**; `multirect_mode` unset (the driver selects it, E11) | yes, only if a0 is rejected or unavailable |

**Why this geometry is legal (E11, E15).** Each half holds exactly two planes, and
the two planes of a half share one zpos (left 0 → stage 1, right 1 → stage 2): ≤ 2
per stage per half in the atomic check, and exactly 2 per stage in the commit-time
stage slots, which are counted per CRTC (E15). Each pair is contiguous (0|1032,
2064|3096) with equal y/h.
No plane crosses x = 2064. The lower drm id is on the left in every pair (71<97,
100<103; 115<134, 112<131); the rule is waived on anorak, but keeping it costs
nothing. The four planes fill all four mixers exactly, so every rect is 1032 px,
inside the ≈ 1128 px per-rect limit (E9).

**Not set:** `sspp_layout`, `multirect_mode`, `topology_control`, `dsc_mode`,
`core_clk`/`core_ab`/`core_ib`/LLCC/DRAM votes, `rotation`. `zpos` is set **only** in
quad attempts, **only** to the fixed values {0, 0, 1, 1} by slot (slot k gets
`k / 2`, integer division, i.e. a compile-time table `FSP_QUAD_Z[4] = {0, 0, 1, 1}`),
through one new wrapper `a_plane_z(plane, …, z)` = `a_plane` + one `a_prop(zpos, z)`;
the request builder, `a_plane`, `a_plane_off` and `a_prop` are unchanged. Static
fixture `static-no-new-set`: the set of property names passed to `a_prop` is the
v0.5 set plus `zpos`; `zpos` appears only inside `a_plane_z`; `a_plane_z` is called
only with `FSP_QUAD_Z[k]`.

**Records.** `plan` gains `attempts=<n>`, `split_probe=0|1`,
`quad_vig=<id.id.id.id|unavailable-<why>>`, `quad_dma=<…>`, per attempt
`pipe_vig`/`pipe_dma=<type-pipe_idx per selected plane, e.g. vig-0.vig-1.vig-2.vig-3>`,
`max_upscale_vig`/`max_upscale_dma=<per selected plane>`,
`zpos_before_vig`/`zpos_before_dma=<v.v.v.v>` (GET), `zpos_set=0.0.1.1` and
`splash_set=match|differs` (the selected VIG ids against 71/97/100/103; logged, never
a gate); an unavailable attempt's lists read `-`. **List encoding (integration pass,
one encoding on both sides):** FSP1 values allow only `[A-Za-z0-9_./%-]`, so a list is
`.`-separated with no `%XX`, the stage-3b packed-list convention (`prop_list
names=` separates its elements with `.`); revision 3's `71,97,100,103`, `vig:0`,
`unavailable:missing`, `0,0,1,1` are written `71.97.100.103`, `vig-0`,
`unavailable-missing`, `0.0.1.1`. The per-attempt `_vig`/`_dma` suffix replaces
revision 3's unsuffixed `pipe`/`max_upscale`/`zpos_before` (ambiguous across two
attempts). The host reads exactly this form (`ConvertTo-Fs3cIntList`); a `%XX`- or
`,`-encoded list reads as no list (a zpos mismatch, §11.1). Every `test_commit` record carries
`layout=split_probe|quad_vig|quad_dma` and its rc; the `commit` record carries the
committed quad tag. If no quad attempt is accepted: exit 50 (NO-DISPLAY), nothing
committed, whatever the split probe returned.

### 6.3 The picture (all show modes except show-off-solid)

Drawn per eye in viewer coordinates (2064 × 2208), then rotated 180° into that
eye's buffer half, exactly as v0.5 (`rect()` mapping unchanged). Levels unchanged:
field mid-grey **0x80**, every mark white **0xFF** (FS-R-010 §4). With u = 21 px
(v0.5's unit), bt = 8, centre (1032, 1104), and the recovery margins M_X = 480,
M_Y = 456 (E13; scaled with the size in offline renders):

| mark | v0.5 | v0.6 |
|---|---|---|
| edge frame, corner square | white | **removed**: outside the 480/456 visible-area margins [C], and the corner square's orientation role passes to the F markers. This frees white area for the markers below |
| 8 characters + underline | centred above the cross; the string spans x ≈ 538–1525, across the mixer seam at 1032 | **unchanged** (per-run characters from the challenge). Crossing the seam is useful: a missing or shifted plane cuts the string |
| cross | 368 px arms | vertical arm kept (it marks the seam); the horizontal arm becomes the centre line |
| **centre line** | — | y = 1104, x = M_X … 2064 − M_X (1104 px), bt thick: one per half, to read the roll |
| link bars (1 / 2 per half) | below the cross | replaced by the quadrant groups |
| **quadrant groups** | — | one per mixer: an **"F"** (the existing hex-font glyph, cell u, 105 × 147 px; chiral) above **k bars** (2u × 8u, gap 2u). Centred at x = 756 (viewer-left part of the eye) and x = 1308 (viewer-right part); F top y = 1351, bars y = 1540–1708 (inside M_Y) |

**Which mixer carries which group.** Because of the in-buffer 180°, the viewer-right
part of an eye sits in the *left* 1032 columns of that buffer half:

| mixer | buffer x | seen in the eye of half | viewer side | bars |
|---|---|---|---|---|
| LM0 | 0–1031 | 0 | right | 2 |
| LM1 | 1032–2063 | 0 | left | 1 |
| LM2 | 2064–3095 | 1 | right | 4 |
| LM3 | 3096–4127 | 1 | left | 3 |

So an upright, correctly staged image reads **"1 | 2"** in one eye and **"3 | 4"**
in the other, left to right, each with an upright F.

**Brightness envelope [D, design estimate; `check_render` asserts].** Same levels,
the same single reviewed write of 127, and **less** white than v0.5: removing the
frame and corner squares frees ≈ 165 k px, the centre lines, F markers and 10 bars
add ≈ 86 k px. White share ≈ 2.6–2.9 % for typical nonces and ≤ 3.1 % for the
worst-case nonce (`bbbbbbbb`), against v0.5's fixtures of 3.51–3.76 %; the mean
stays ≤ v0.5's 132.8/255; the peak is unchanged (0xFF). `check_render.py` asserts
`white_ppm ≤ 37618` and `mean_x1000 ≤ 132777` for every fixture nonce and the worst
case.

**What the PM will see, and why it is expected [C].** The in-buffer 180° cancels the
180° mounting (as v0.5 assumed from the DT and composer orientation, E13). It does
**not** cancel the ≈ 21° in-plane roll. Expect:
- each eye's pattern rotated by about 21°, the centre line visibly sloped, possibly
  in opposite directions in the two eyes;
- the pattern's centre shifted toward the nose and upward (lens axis offset), and
  the panel edges out of view.

This is **not a fault**. Compensating the roll, the lens offsets and the per-eye
geometry belongs to the later rendering stage (eye-to-head transform, projection,
distortion; research §C.4), not to the KMS commit. An upside-down or mirrored F is
reported as a geometry finding, not a failure (§11.2).

### 6.4 The solid frame (run 3)

- XRGB8888 `0x00FF0000` (bytes B=00 G=00 R=FF X=00) in every pixel of the 4128×2208
  buffer. There is no text, frame or marks.
- **Why red (re-checked against the research).**
  1. A single primary: the panel shows a uniform red field or something else.
     Stripes identical to run 2 point away from our frame content.
  2. Channel order: XR24 and AB24 differ **only** in R/B order (research §A.5), so a
     uniform **blue** field is exactly the signature of the pipe reading our buffer
     as AB24/RGBA. A grey field cannot show this.
  3. A missing plane shows as a non-red quarter (key `p`, §8.2), so run 3 also
     checks the four-plane staging without any detail in the content.
  4. Luminance: **comparable to, not above, the pattern's mean [C].** Under an
     sRGB-like panel response, red Y = 0.2126 against the v0.6 pattern's mean
     (≈ 0.971 × 0.216 + 0.029 × 1.0 ≈ 0.239) and white's peak of 1.0 [D under that
     assumption]. The real panel transfer and the subpixel balance are unknown, so
     the claim is only "comparable, not above" [C], not a measured ratio.
- **Alternatives rejected.** Green: Y = 0.715, above the reviewed mean. White/grey:
  can't separate channel errors. Blue: Y = 0.072, possibly too dim to judge
  uniformity at a 4 % duty.
- The backlight stays at the single reviewed write of 127. **Hold 5 s** (R-A: a
  uniform field is judged in seconds; the shorter hold buys the guard room of §9.3
  and halves run 3's lit time).
- `render-solid` and `check_render.py --solid` verify every pixel offline.

### 6.5 Read-only logging additions (GET ioctls only; no new ioctl beyond v0.5's set)

| addition | where | essential/optional | size bound |
|---|---|---|---|
| `post_state` once, right after the real commit returns (blocking commit, so the state is applied), before `hold_start`: connector `topology_val/topology_name/dsc_mode_val/control_val`; CRTC `ACTIVE/MODE_ID/core_clk/core_ab/core_ib/llcc_ab/llcc_ib/dram_ab/dram_ib`; GETCRTC `mode_valid/fb` | all show modes | **essential** | ~0.5 KB |
| `post_plane` per committed plane, keys `slot plane crtc_id fb_id crtc_x crtc_y crtc_w crtc_h src_x src_y src_w src_h src_frac zpos`: CRTC_X/Y raw signed GET values (the kernel's right-half CRTC_X rewrite, E17, is **not** undone on the device); SRC_* in whole pixels (raw >> 16) with `src_frac` = the OR of the four 16.16 fractional parts (expected 0; the host requires 0) | all show modes | essential | ≤ 4 × 0.25 KB |
| `plane_caps` per plane: `plane read_rc caps_bytes max_linewidth pipe_idx max_upscale smart zpos nv12` (`smart` = `primary_smart_plane_id`; an absent value reads `none`) | all show modes | essential for the quad modes (selection inputs, also summarised in `plan`); optional in `show` | 20 × ~0.15 KB |
| `FSP_BLOB_MAX` 4096 → **8192** (`mode_properties` 5473 B now logged in full) | all | optional | 23 × ≤ 720 B encoded |
| connector `capabilities` blob (prop id from the list; E7) | show, show-off-quad | optional | ≤ 8192 raw |
| full `prop_list`/`prop_vals` of connector, CRTC and every plane | show (as v0.5) **and show-off-quad** | optional | within FSP_OPT_MAX |
| show-off-solid: topology, `mode_properties`, plane caps and post-state only | — | — | — |

- `FSP_OPT_MAX` 20480 → **38912** (not 40960 as in revision 1, because the caps
  records are now essential), and a separate **`FSP_OPT_MAX_SOLID` = 10240** for
  show-off-solid. Stream bounds, in bytes: essential 12254 (3b run 1: 31689 − 19435
  opt) + post ≤ 1536 + plan/caps/test records ≤ 4096 + opt. show/show-off-quad:
  + 38912 = 56798 ≤ the 57344 cap; show-off-solid: + 10240 = 28126 ≤ the 28672 cap
  (546 B margin each; in run 3 the `mode_properties` blob may be cut, it is logged in
  full in r1/r2). `check-timing-3c.py` and a propsim maximum fixture must assert these
  bounds; they are design targets, not tested maxima (Q14).
- **`post_plane` expectation (E17).** For a committed quad layout, slot k = 0…3 is
  expected to read back `SRC_X` = 0/1032/2064/3096 and **`CRTC_X` = 0/1032/0/1032**
  (the planned global x minus 2064 for x ≥ 2064), `SRC_W` = `CRTC_W` = 1032, y 0,
  h 2208, zpos 0/0/1/1. The classifier (§11.1) and the propsim fixture apply this
  conversion; reading back the unconverted 2064/3096 for CRTC_X would itself be a
  finding (the kernel did not take the global-coordinate path).
- The opt cut rule is unchanged: the first record that does not fit becomes
  `opt_budget`, and the seq stays gap-free.
- **Essential-record cap (build review).** The per-object records are essential only
  up to the counts the stream bounds were measured at (the mock-model maximum
  fixtures): `connector` 3, `mode` 24, `plane` 20, `plane_caps` 20 (`FSP_ESS_CONNECTORS`,
  `FSP_ESS_MODES`, `FSP_ESS_PLANES`, compile-time, capped by `#error`). Every further
  one is an **optional** record (it counts against the opt budget and may be cut by
  it), so the essential bytes stay within the measured bound whatever counts the
  device reports. The selection inputs (`g_caps`) are kept for every plane either way.
- `plan attempts=<n>` is the number of TEST_ONLY requests planned (split probe, if
  any, plus the available quad attempts), not the number made.
- The ioctl set is v0.5's; it includes `DRM_IOCTL_SET_CLIENT_CAP` (per fd: universal
  planes and ATOMIC, needed for any atomic request), which changes no device state
  beyond that file descriptor.
- **Hold time.** The post-commit snapshot runs inside the hold. The deadline is
  computed from `commit_t0`, as in v0.5, so the snapshot shortens nothing and
  lengthens nothing. It costs ≈ 50 GET ioctls (well under 100 ms [C]). The image-time
  bound (alarm HOLD_S + 5 from the commit) is unchanged.
- **Limit.** Property values are the atomic software state, not hardware registers.
  `core_clk` is a request, not the running clock [D]. No underrun counter is read
  (§7.1).
- Not added: a second snapshot mid-hold. It would need a change to `hold()`. probeN's
  mid sysfs snapshot (TE/BLU counters, crtc-0 nodes) covers mid-hold.

### 6.6 Version and build

`FSP_VERSION "0.6"`. The `start` record reports `mode=show|show-off-quad|show-off-solid`.
Toolchain, headers and `libc.a` are as v0.5. Bit-identical rebuild. The unit-test
build gets the plane-selection, picture and solid tests (§12.3).

---

## 7. Probes (`stage3c/fs-probe.sh`)

Roles: `p0` (irq0, mods, write, read-back; no go/end wait) and `r1|r2|r3`
(read-back, pre, go+1 s, mid, end, post). The node list is unchanged from 3b,
read-only: sysfs and /proc only, never card0, **never debugfs, and no mount of it**
(PM decision J-109 #2). The only write is p0's `127` to
`panel0-backlight/brightness`, exactly once per boot. Never written or read, as in
3b: `blu_default_duty`, `blu_max_overlap_us`, `fifo_trim`,
`backlight_changes_blocked`, debugfs, `oculus,blu`. The 3b decoy-file harness check
is kept.

Changes:
- **dmesg filter** (case-insensitive):
  `dsi|sde|drm|blu|splash|panel|backlight|bl_|warn|smmu|fault|underrun|iommu|timeout|esd|dsc`.
  Budget per point: the last **80** matching lines, each ≤ **200** B, ≤ **4096** B in
  all. Read at mods, mid and post. Never at pre, so nothing slow runs right before a
  commit. Re-time with `tools/dmesg-timing.sh` on the 1 MB synthetic log (3b: 0.48 s
  under qemu). The budget is TW/TQ ≥ 2 s.
- **TE/BLU interrupt samples** (builtins only, ≤ 4 lines × 200 B each): irq0 (init),
  mods, pre, **go + 1.0 s** (after the commit, expected), mid + mid+0.5 s, **end**
  (immediately at the end file), and post. The classifier computes the deltas per
  interval.
- The probe cap is raised to 16384 for r-phases (2 dmesg points × 4096 + ≈ 4 KB).
  Over-long output is cut gracefully, as in 3b (informational step).

**This run's machine evidence of a clean scan-out** (no debugfs):
1. TE and BLU interrupt rates over go+1 s → mid → end, against the stock lit
   signature of ≈ 182/s each and run 2's ≈ 181/s (research §A.6, J-108);
2. the GET-ioctl state from fs-pattern: the committed quad layout, `post_plane`
   (positions as planned after the right-half CRTC_X conversion, zpos 0/0/1/1; §6.5,
   E17), `post_state` (ACTIVE, mode, `topology_name`, the votes);
3. the dmesg filter (any `underrun`, `fault`, `timeout`, `esd` line in the window).

Limit: these show that the panel timing ran and that the kernel accepted and holds
the planned state. They do **not** prove the absence of pipe underruns. Only the
encoder's counter does, and it is in debugfs (§7.1).

### 7.1 Proposed for the Chair (FS-A-012), not in this run

The research's proof read (research §A.8 item 12, D2): mount debugfs **inside our own
initramfs** and read, before and after the run-2 commit, small and bounded:
- `/sys/kernel/debug/dri/0/encoder<id>/status` ("intf / vsync / underrun" counters
  per physical encoder, `sde_encoder.c:5330-5352`, `:5556`);
- `crtc<id>/status` (mixers, per-plane stage, src/dst, multirect) and
  `crtc<id>/state` (core_clk and bandwidth votes, the running clock).

It is not a device-persistent write, but it is a new action in the image. The PM
decided not to do it in this run (J-109 #2). FS-A-012 asks the Chair whether it may
be added to a later run, with this run's results as the motivation.

---

## 8. Host: the interactive session

### 8.1 Files and reuse (stage-3b behaviour untouched)

- `host/fs-collect3c.ps1` **dot-sources** the pinned `fs-collect.ps1`, which returns
  early when dot-sourced (`InvocationName -eq '.'`). It reuses its transport, capture,
  send gate, `Read-FsInto`, `Set-FsSettled`, `Get-FsTailState` and clock helpers;
  what it copies or replaces is listed below.
- **Dot-source scope hazard (R-A M4).** A dot-sourced script runs in the caller's
  scope, so `fs-collect.ps1`'s `param()` block binds **its** parameter variables
  (`$Port`, `$Nonce`, `$OutDir`, `$Stage`, … with their defaults and validation
  attributes) in `fs-collect3c.ps1`'s script scope. A same-named variable of the
  caller is overwritten, and `$Stage` gains `[ValidateSet('2a','3a','3b')]`, so any
  later `$Stage = '3c'` throws. It also sets `Set-StrictMode -Version 2.0` and
  `$ErrorActionPreference = 'Stop'` in that scope. Rules:
  1. `fs-collect3c.ps1`'s own parameters use **distinct names** that collide with none
     of `fs-collect.ps1`'s (prefix `S3c`: `-S3cPort`, `-S3cNonce`, `-S3cOutDir`,
     `-S3cBootStartUtc`, `-S3cReplay`, …); no variable named `$Stage` is used anywhere
     in the 3c host files (the stage label is `$script:Fs3cStageLabel = '3c'`).
  2. Before the dot-source, it **snapshots** its bound arguments
     (`$script:Fs3cArgs = @{} + $PSBoundParameters`) and reads them only from that
     snapshot afterwards.
  3. It never passes `-Stage` to any `fs-collect.ps1` function (see the list below).
  4. `test-host3c.ps1` case 21 (§12.3) runs `fs-collect3c.ps1` with every parameter
     set to a non-default value and asserts that each survives the dot-source
     unchanged, that no `ValidateSet` exception occurs, and that the dot-sourced
     defaults (`$Stage = '2a'`, …) are never read by 3c code (static check).
- It adds the `fs-phase` verb to the command table at run time, and defines
  `Invoke-Fs3cPhase` (a copy of `Invoke-FsPhase` with a marker callback and the
  `FSXE1` refusal tag) and `Invoke-Fs3cSession`.
- **Copy/override list** (everything not listed is reused by call, unedited; each
  copy is diffed against its original by R-D, and the differences are listed in the
  copy's header):

  | `fs-collect.ps1` piece | 3c treatment | why |
  |---|---|---|
  | pre-runner sequence of `Invoke-FsCollect` (initial drain, `fs-verify`, `fs-ack`, `fs-status`, the ack-window cap `PhaseCapMs`) | **copied** verbatim into `Invoke-Fs3cSession` (it is inline code, not a callable function) | the 3b function runs exactly one runner verb |
  | the gated `fs-done` block | **copied**, including the `PhaseCapMs = $null` reset before `fs-done` (NIT7) and after the ack; the 3a/3b beep-1/beep-2 pause is dropped (replaced by §8.2 prompts) | recovery must never be blocked by the ack window |
  | live clock conversion (CLI block: `BootStartUtc` parse and future-origin refusal, `Get-FsHostDeadlines`, `ConvertTo-FsTransportDeadlines`, `Get-FsLiveStartRefusal`, gadget/port checks, the fresh conversion **after** the preparation) | the helper **functions are called**; the CLI block (skipped when dot-sourced) is **copied** into `fs-collect3c.ps1` with DEADLINE 200, ACK_WINDOW 150 | the CLI block does not run under a dot-source |
  | `$script:FsStageSpec`, `New-FsCollectCfg` (`-Stage` ValidateSet 2a/3a/3b) | **not used**; `New-Fs3cCfg` is a copy of `New-FsCollectCfg` with the stage-3c fields (per-phase Exp/Steps/PHASE_WORST, DoneReserve, IDLE_S) and the same key names | `-Stage '3c'` would throw; the pinned table is not edited |
  | `Invoke-FsCollectRun` (one `Test-Fsb1Record` over the whole capture) | **replaced** by `Invoke-Fs3cRun`: capture-consistency checks copied; FSB1 validation **per phase slice** (§5.6), up to 4 records | a whole-capture validation would see 4 BEGINs and reject |
  | `Get-FsReplayTokens` (matches `fs-valve`/`fs-display` only) | **replaced** by `Get-Fs3cReplayTokens`: one token set per `fs-phase <ph> <chal> <prev>` write, validated by the command table; `<prev>` is recomputed from the replayed records and compared, never trusted | replay of a 3c capture must re-derive every phase |
  | `stage3b/tools/check-timing-3b.py` checks M1–M3 (BootStartUtc before the boot, the origin passed to the collector, live deadlines from the origin with the conversion after the preparation) | **retargeted** in `check-timing-3c.py` to `fs-observe3c.ps1` and `fs-collect3c.ps1`'s copied CLI block (same regexes, new file names) | the checks would otherwise pass vacuously on the unchanged 3b files |
  | `fs-observe.ps1` | **copied** as `fs-observe3c.ps1` (next bullet): the lines that change are the stage set (3c only), the unconditional dwell gate (3b's `if ($Stage -ceq '3b')` removed), the MANIFEST file list (§12.2), and the launch line for `fs-collect3c.ps1` with the `S3c` parameter names | dot-sourcing would keep the 3b-only dwell condition |
- `host/fs-session3c.ps1`: banners, sounds, the key source (live console or
  scripted), prompts, and the readings file. `-SoundCheck` runs the preflight.
- `host/fs-observe3c.ps1` is a **copy** of `fs-observe.ps1`, reduced to stage 3c,
  with the dwell gate **unconditional**. Dot-sourcing is unsafe here: the original
  applies the dwell gate only when `-Stage 3b`. It launches `fs-collect3c.ps1`. A
  reviewer diffs it against `fs-observe.ps1`.
- `host/fs-classify3c.ps1` (new).
- `fs-collect.ps1`, `fs-observe.ps1`, `fs-classify*.ps1`, `fs-proto.ps1`,
  `fs-native.ps1` and `fsb1.ps1` keep their pinned bytes. `test-host3b.ps1` (116) and
  `test-host2.ps1` (459) must still pass unchanged.

### 8.2 Prompts (only between phases, only after the phase record and a settled prompt)

- **Before every prompt:** drain the console key buffer. Discarded keys are logged
  with their time (`discarded=<n>`), so a key pressed during a lit hold is never taken
  as an answer. The port keeps being read throughout.
- **Order:** left reading, right reading, dark check; then, after run 2 only, the
  layout items. The safety-relevant dark check comes before the optional items.
- **Per-eye reading** (runs 1 and 2), left eye first, then right, one short line
  (PM rehearsal feedback, 2026-10-12): `RUN 2 - LEFT EYE:  a = light, no pattern
  b = dark   c = garbled   d = I can read the characters   x = abort`.
  `a` = lit, no pattern · `b` = dark · `c` = garbled · `d` = read (then type 8
  characters, `0-9 A-F ?`, Backspace allowed, Enter; validated `^[0-9A-F?]{8}$`; own
  30 s timeout; **Esc** discards the typed characters and returns to this eye's
  reading prompt, so a mistaken `d` can be changed; the reading prompt's own timeout
  keeps running) · `x` = abort. Other keys are ignored, and the timeout keeps running.
  **`n` is not a key here** (nor in the character entry or the layout items: an ignored
  key, logged); it belongs to the dark check, which follows every pair of eye readings.
  Light still visible at an eye prompt: press `x` (safe finish), then say so in the notes.
- **Every answer is echoed** at once in words (e.g. `LEFT EYE: GARBLED`,
  `RIGHT EYE: READ 3F0A9C1B`, `DARK CHECK: DARK`), so a mis-key is visible to the PM
  and the Arbiter. Apart from Esc in character entry, an answer is not re-asked; a
  correction goes into `notes.txt` and is reported next to the recorded key.
- **Dark check** (after the per-eye readings): "Are both panels DARK now?" `y` = dark ·
  `n` = light visible → safe finish (no further lit phase) · `x`. The only prompt that
  takes `n`.
- **Layout items (run 2 only; per eye whose reading was `c` or `d`; left eye first):**
  - `bars`: the bar counts seen, left part then right part of that eye: two keys from
    `1 2 3 4`, or `0` = nothing readable on that side. Validated `^[0-4]{2}$`,
    Backspace allowed, no Enter. The prompt explains itself (PM feedback: the bare
    question was not understood): "LEFT EYE BARS: next to each of the two F letters (below it when upright) there
    is a row of 1 to 4 bars (see the preview). Press how many bars you see at
    the LEFT F, then under the RIGHT F (two keys, 0 = none visible). Backspace = correct
    x = abort". No bar order is shown.
  - **Q7 fallback (applied after the PM rehearsal 2026-10-12, §15 Q7): no `bars` on the
    run-3 path.** After the dark check the host evaluates the run-3 rule (§5.8 rules
    1-4; rule 5, the guard, and the countdown are not consulted, so the prompt set never
    depends on timing). When it holds, `bars_left`/`bars_right` are recorded `NOT_ASKED`
    without a prompt (event `bars-not-asked r2/<item> (Q7 fallback: run-3 path)`; the r2
    phase in `session.json` carries `Q7Fallback`: "not asked (Q7 fallback)"). Nothing is
    shown on the console. The bars are therefore asked only when run 3 does not follow
    by rule: an eye read the characters correctly (rule 3), or run 2 did not commit a
    quad layout cleanly (rule 1). A `d` eye with wrong characters on the run-3 path is
    still asked `orient` and `tilt`.
  - only if the reading was `d`: `orient` (the F markers): `u` upright (a tilt is
    fine) · `i` **turned by a half-turn** (rotated 180°: the long top arm now at the
    bottom, the arms pointing left) · `m` mirrored left–right (long arm at the top,
    arms pointing left) · `v` flipped top–bottom (long arm at the bottom, arms
    pointing right) · `0` can't tell; the preview sheet shows each of the four
    variants (§13 A); then `tilt` (the centre
    line): `l` left end lower · `r` right end lower · `0` level or can't tell.
  - Asked only while ≥ 10 s remain before the prompt cut-off (§8.3); otherwise
    recorded `NOT_ASKED` with no safe-finish trigger. `x` aborts (`n` is not a key here).
  - On the run-3 path (garbled) the layout items cost nothing (Q7 fallback above); when
    the characters were read, run 3 is not requested anyway (§5.8 rule 3), so the
    longer `d` items take no time from run 3.
- **Run 3 key set** (no characters on the frame): `r` = uniform RED field · `p` =
  partly red (an area dark or another colour) · `u` = uniform field of another
  colour · `s` = stripes/garble that look the SAME as run 2 · `g` = garble DIFFERENT
  from run 2 · `b` = dark · `x`. This departs from a/b/c/d on purpose: run 3
  asks a different question. `g` replaces "n = different" because `n` means "light
  visible" at the dark check. The line: `RUN 3 - LEFT EYE:  r = all red   p = partly
  red   u = one other colour   s = same as run 2   g = different garble   b = dark
  x = abort`.
- **Timeout:** 30 s per prompt, shortened to the gap deadline (§8.3). A timeout records
  `TIMEOUT` for that item and `NOT_ASKED` for the rest, then the safe finish (`fs-done`).
  `x` records `ABORT` and does the same.
- **`x` during a lit phase** is noted at once, and the banner says "ABORT NOTED – the
  device finishes this hold (≤ 10 s); one safety question, then fs-done". No command
  is sent mid-phase: the send gate forbids it, and the hold is device-enforced.
  Looking away is always allowed. After that phase's record and settled prompt, the
  host **still asks the dark check** ("Are both panels DARK now?", `y`/`n`/`x`; the
  per-eye readings and layout items are recorded `ABORT`/`NOT_ASKED`), because a
  retained frame is a safety finding whether or not the PM aborted. Then `fs-done`.
- **Build review (host).** Before any lit phase the collector checks p0's integrity:
  the hash step must be MEASURED and equal to the fs-pattern pin, otherwise
  `RUN 1 NOT POSSIBLE (integrity)` and `fs-done` (R-C MAJOR-1). In an interactive
  session **Ctrl+C is read as a key and is `x`** (the safe finish); QuickEdit is off
  (R-C MAJOR-2, MINOR-9). Every reading is appended to `readings3c.txt` at once and
  `session.json` holds a checkpoint, so a closed window loses no answer; a closed
  console means: look away, the device recovers within 120 s (idle limit) or by
  T0 + 200 s. **`n` during a phase** (or before it, or in the LOOK cue) is taken as
  `x` (MINOR-4). At a prompt's start the previous answer's key is ignored for 600 ms
  (key repeat, MINOR-2). `d` followed by a timeout or `x` in the character entry
  records the eye as READ with no characters ("READ, characters not recorded",
  MINOR-3). A safe finish shows a red SAFE FINISH banner; the dark check has its own
  banner. After the session the machine summary is written to `summary.txt` and shown
  only when the PM presses `s` (MINOR-7).
- **No machine facts before the readings.** Before a phase's readings are complete,
  the console shows only: the phase name, STARTING/ENDED/SKIPPED banners, "record
  received". It shows no commit rc, layout, topology or verdict, and **no expected
  bar order**. Machine facts print after the session (FS-R-011 §3: machine and optical
  stay separate).

### 8.3 Gap deadline and countdown

At each prompt the host shows `N s left to keep RUN k+1 possible`, where
N = `GiveUp − G_{k+1} − now` (§9.3). Prompt timeout = min(30 s, `GiveUp − DoneReserve −
now`, `last_phase_end + 110 s − now`). When N reaches 0 during the prompts, the host
says "RUN k+1 NO LONGER POSSIBLE" and finishes the readings. It is not a timeout, and
the session ends with `fs-done`.

### 8.4 Sounds and banners

- **Sounds:** 16-bit 44.1 kHz PCM WAVs generated in memory at start-up (no files, no
  download). Each WAV's SHA-256 goes into `session.json`. Played with
  `System.Media.SoundPlayer` (`Load()` once, then `Play()` async). If `Play` throws:
  `[System.Media.SystemSounds]::Exclamation.Play()` plus a console bell, and the
  failure is logged.

  | name | shape | used at |
  |---|---|---|
  | START | 660 → 880 Hz rising, 2 × 0.2 s | `go`, and the LOOK cue after p0 |
  | END | 880 → 440 Hz falling, 0.6 s | `end` |
  | ANSWER | 3 × 0.1 s pips at 1000 Hz | first prompt of each gap |
  | FINISH | 330 Hz, 1.0 s | `fs-done` sent |
  | ALARM | 1200/600 Hz × 3 | abort, timeout, refusal, lost record |

- **Banners:** 5-line, full-width blocks via `Write-Host -BackgroundColor`. Yellow =
  LOOK/STARTING, green = ENDED/ANSWER, cyan = info, red = ABORT/SAFE FINISH. Run in
  `powershell.exe` (a console host: `[Console]::KeyAvailable`/`ReadKey` work; not ISE).
- **Preflight sound check** (`fs-session3c.ps1 -SoundCheck`, before BA, nothing touches
  the device):
  1. Each sound plays with its name, and the PM presses `y` per sound heard.
  2. Then 3 sounds play in random order without names, and the PM identifies each
     (`s`/`e`/`a`/`f`/`l`).
  3. A key-reach test follows: press `a b c d x y n r p u s g i m v l 0 1 2 3 4 Esc
     e f 5 6 7 8 9 ? Enter Backspace` one-handed (J-108 open item; the hex characters,
     Enter and Backspace added by the build review, MINOR-6).

  The sound check is the only protection against a silent audio failure during the
  session (a failing `Play()` falls back to the system sound and a bell, logged); the
  PC speakers stay the output (R-C MINOR-5).

  All must pass, or nothing is booted. `soundcheck.json` records the time, results and
  WAV hashes.

### 8.5 Readings record (`readings3c.txt`, plus the same in `session.json`)

```
FSR2 p=<r1|r2|r3> item=<left|right|chars_left|chars_right|dark|bars_left|bars_right|orient_left|orient_right|tilt_left|tilt_right> key=<k|-> obs=<OBS> [chars=<8>] [bars=<2>] prompt_ms=<transport ms> answer_ms=<ms|-1> prompt_utc=<ISO> answer_utc=<ISO|-> discarded=<n>
OBS ∈ LIT DARK GARBLED READ | BARS | UPRIGHT HALF_TURN MIRRORED VFLIP | LEFT_LOW RIGHT_LOW LEVEL | UNKNOWN | UNIFORM_RED PARTIAL_RED UNIFORM_OTHER SAME_AS_R2 DIFFERENT | DARK_NOW LIGHT_NOW | TIMEOUT ABORT NOT_ASKED
```

The transport clock is the collector's Stopwatch, so readings order against the
capture's index lines. The PM's free-text description goes verbatim into `notes.txt`
afterwards, as in J-107. Readings and phase records live in the same session
directory (`phase-<ph>.raw`, `readings3c.txt`) but are never merged into one verdict.

---

## 9. Timing and deadline

### 9.1 Device per-phase worst case (stage-3b model: step worst = t + g + reap 3 + strays 3 + drain 1; encode 1 s/step; GATE 1 s; emission = 1 + ⌈MAXLINES/20⌉ × 0.11 s)

| phase | components | W (s) | `PHASE_WORST` |
|---|---|---|---|
| p0 | max(probe0 8+1+7 = 16, hash 2+1+7 = 10) + GATE 1 + encode 1 + 1.005 + END pass 0.24 + emission(360: 18 chunks) 2.98 | 22.22 | **23** |
| r1 | TW 2 + pattern1 (9+3+7 = 19) + TQ 3 + GATE 1 + encode 1.005 + 1.125 + END pass 0.24 + emission(1545: 78 chunks) 9.58 | 36.95 | **38** |
| r2 | PAUSE ≤ 2 + TW 2 + pattern2 (16+3+7 = 26) + TQ 3 + GATE 1 + encode 1.005 + 1.125 + 0.24 + 9.58 | 45.95 | **47** |
| r3 | PAUSE ≤ 2 + TW 2 + pattern3 (11+3+7 = 21; hold 5) + TQ 3 + GATE 1 + encode 1.005 + 1 + 0.24 + emission(945: 48 chunks) 6.28 | 37.52 | **39** |

**Build review (MINOR-2, NIT-3; this table is the current one).** The encode term is
`max(1 s, 1.5 × measured)` per step with the **cold repetition** (0.75 s for the
57344-byte step, now recorded as `ENCODE_COLD` in `fixtures/encode-timing.txt`)
counted, plus the encoder's **END pass** (1.5 × 0.16 = 0.24 s, once per phase), and
**TQ = 3 s**. The margins fell below 0.5 s (p0 even below 0), so the rule is now
PHASE_WORST ≥ W + 0.5 s: **23 / 38 / 47 / 39** (revision 3: 22 / 36 / 45 / 37).
Probe `-t` still covers its window: r1 2 + 19 + 3 = 24 ≤ 24, r2 31 ≤ 32, r3 26 ≤ 26.
The guards (§9.3) and the walk-through (§9.4) are recomputed; DEADLINE 200 / backstop
201 stay. The paragraphs below record the revision-3 reasoning that led here.

Probe `-t` covers its window (r1: 2 + 19 + 2 = 23 ≤ 24; r2: 2 + 26 + 2 = 30 ≤ 32;
r3: 2 + 21 + 2 = 25 ≤ 26). pattern3's `-t 11` keeps the `-t ≥ hold + 5 + 1`
contract for hold 5. The concurrent hash ends inside p0's W. Realistic durations
(from E1/E2 and 3b fixtures): p0 ≈ 3 s, r1 ≈ 12 s, r2 ≈ 20 s, r3 ≈ 13 s.

**Encode re-timed at the 56 KiB stream (R-A).** The "encode 1 s per step" term was
measured in 3b on streams up to ≈ 31 KB. The r1/r2 pattern streams may now reach
the 57344-byte cap (§6.5). Before the build sign-off, `tools/encode-timing.sh` runs
`fsb1-enc.sh` rev 5 under qemu on a synthetic 57344-byte stdout plus a 16384-byte
probe stdout (r2's maximum record) and on the 28672-byte r3 maximum.
`check-timing-3c.py` uses `max(1 s, measured × 1.5)` per step; if that exceeds 1 s,
PHASE_WORST, the guards and §9.4 are recomputed and the design returns to the PM
before any build.

**Encode measured (integration pass; `fixtures/encode-timing.txt`, IMAGE.md §4).**
Under qemu-user, 3 repetitions: probe 16384 B ≤ 0.67 s, pattern 57344 B 0.61–0.67 s
(an earlier cold repetition 0.75 s), pattern 28672 B ≤ 0.58 s, END ≤ 0.16 s. ×1.5 gives
1.005 s (1.13 s for the cold outlier) for a 56 KiB pattern step: **just over** the
1 s term. Applying the rule above (`max(1 s, 1.5 × measured)` per step): r1/r2
encode = 1.005 (probe) + 1.005 (pattern) = 2.01 s, or 1.005 + 1.13 = 2.13 s with the
cold outlier, against the 2 s in the table: W r1 35.58 → 35.71 s, r2 44.58 → 44.71 s,
still ≤ PHASE_WORST 36 / 45 (the rounding up absorbs it); r3 (28672 B: 0.87 s → 1 s;
probe 1.005 s) 36.28 → 36.29 s ≤ 37. **PHASE_WORST, the guards and §9.4 therefore stay
as they are**, and the RunnerMargin 5 s of every guard is untouched. The real device
(native cores, no emulation) is expected to be faster than qemu-user [C]. Recorded
here for the PM per the rule above (it exceeds 1 s, so the PM sees it before the
build sign-off); no number in §9.1–§9.4 changes.

**Re-check after revision 3.** Only r3 changes (hold 5 s: pattern3 `-t 11`, probe3
`-t 26`, PHASE_WORST 42 → 37). Caps and MAXLINES are unchanged, and the extra
GETs of the type check (`max_upscale` is in the blob already read) cost nothing.

**Re-check after revision 2.** No device-side number changes: the step lists,
fs-supervise bounds, stdout caps and MAXLINES are as before, and no probe point is
added (no debugfs). In show-off-quad the setup does at most 3 TEST_ONLY calls
(split probe, quad_vig, quad_dma) against 4 in revision 1 and 2 in v0.5 show-off,
plus ≈ 20 caps-blob GETs; all before `commit_t0` and inside the setup alarm
(FSP_SETUP_BUDGET_S 30) and the 1 s setup allowance of the `-t ≥ hold + 5 + 1`
contract [C: milliseconds each; `check-timing-3c.py` re-asserts the contract]. The
streams stay within their caps through the opt budgets of §6.5.

### 9.2 DEADLINE: unchanged at 200 s, backstop 201 s

We do not lengthen it (FS-R-011 §4 spirit; FS-R-010 §6 ceiling). The session does not
need to fit its worst case. Instead, every lit phase is admitted by a guard (§9.3),
and anything that does not fit is **not run**, which is the safe direction. The
deadline stays the hard bound on image time. Run 2, the main experiment, has a wide
margin in the expected case. Run 3 is best-effort.

### 9.3 Host guards (immediately before each `fs-phase`, on the monotonic transport clock, origin BootStartUtc; give-up = BootStart + 200 − 15 = 185 s)

`G_k = PHASE_WORST_k + RunnerMargin 5 + PostMin_k + DoneReserve 3`, where PostMin =
banner/sound 2 s + the minimum human window H_k (p0: the 3 s cue, no prompts). H_k
covers the core readings (per-eye, dark check); the run-2 layout items are
best-effort (§8.2) and not part of H_2. DoneReserve (R-A) keeps the minimum human
window from eating the 3 s that `fs-done` needs before the give-up (§5.10).

| phase | PHASE_WORST | H_k | **guard G_k** |
|---|---|---|---|
| p0 | 23 | cue 3 (no banner term) | **34 s** |
| r1 | 38 | 20 | **68 s** |
| r2 | 47 | 25 | **82 s** |
| r3 | 39 | 15 | **64 s** |

(Build review: from PHASE_WORST 23/38/47/39; revision 3 had 33/66/80/62.)

The phase's record deadline is `send + PHASE_WORST_k + 5 s`, capped by the give-up.

### 9.4 Budget walk-through (seconds after BootStartUtc)

| event | planning (expected, run 2 garbled) | run 2 read (`d`, `d`) | worst pre-runner/p0 | all r1 prompts maximal |
|---|---|---|---|---|
| collector converted (3b planning value) | 25 | 25 | 25 | 25 |
| fs-verify/ack/status done | 33 | 33 | 86 (61 s worst, 3b model) | 33 |
| p0 sent (G0 34) | 33: left 152 ✓ | 33 | 86: left 99 ✓ | 33 |
| p0 done + 3 s cue | 39 | 39 | 112 | 39 |
| r1 sent (G1 68) | 39: left 146 ✓ | 39 | 112: left 73 ✓ | 39 |
| r1 done | 51 | 51 | 150 (W) | 51 |
| r1 prompts (b, b, y) | +2 +15 → 68 | 68 | prompts until 182 → fs-done | 3 × 29 → 140 |
| r2 sent (G2 82) | 68: left 117 ✓ (35 s slack) | 68 ✓ | — | 140: left 45 ✗ → fs-done |
| r2 done | 88 | 88 | | |
| r2 prompts | c, c, y (3 keys; no bars on the run-3 path, Q7 fallback; revision 3 planned c, bars, c, bars, y): +2 +25 → 115 | d+8+Enter, d+8+Enter, y (21 keys), then bars 2 + orient 1 + tilt 1 per eye (8 keys): **29 keys**, +2 ≈ 70 → ≈ 160 (≤ cut-off 182, ≤ gap cap 88 + 110 = 198) | | |
| r3 sent (G3 64) | 115: left 70 ✓ (6 s slack) | not requested (rule 3) → fs-done ≈ 162 | | |
| r3 done, prompts, fs-done | 128, ≈ 142, ≈ 144 | | | |

- Run 1 is admitted even with the worst pre-runner and the worst p0 [D].
- Run 2 is admitted if the run-1 prompts take ≤ ≈ 50 s in total (r2 must be sent
  by 185 − 82 = 103 s; r1 done at 51 s plus a 2 s banner). Revision 3 had 52 s, revision
  2 55 s; the DoneReserve and the build-review PHASE_WORST account for the difference.
- Run 3 is admitted if the run-1 plus run-2 prompts take ≤ ≈ 46 s in total
  (r3 by 185 − 64 = 121; 51 + 2 + P1 + 20 + 2 + P2 ≤ 121). With the 5 s hold
  (PHASE_WORST 39 after the build review) and the DoneReserve, the planning slack
  (P1 15 + P2 25 = 40 s) is ≈ 6 s (revision 3: ≈ 8 s). Whether the PM fits it is a go/no-go item of the
  rehearsal (Q7, §13 A). The countdown (§8.3) shows the PM the remaining time.
- Every session ends by `fs-done` before 185 s, or else by the idle limit or
  DEADLINE. The retained-frame and lit-time bounds are unchanged (§9.5, §10).
- `check-timing-3c.py` re-derives every number from the sources (step bounds, pacer,
  collector constants, IDLE_S, the measured encode time). It asserts G_k ≥
  PHASE_WORST_k + 5 + DoneReserve, IDLE_S ≥ host max gap + 10, and the runner guards.
- **The 3b counterexample, per lit phase.** 3b's review replayed a runner sent at
  144 s with origin BootStart. In 3c each lit phase has its own limit, `185 − G_k`:
  r1 117 s, r2 103 s, r3 121 s (build review; revision 3: 119 / 105 / 123). A send at
  144 s is refused for **every** lit phase.
  `check-timing-3c.py` and `test-host3c` case 9 test each phase at its limit
  (admitted) and at limit + 1 s (refused), and at 144 s (refused) for r1, r2 and r3
  separately. The device-side `time` refusal (§5.2) is weaker (its origin T0 is later
  than BootStart) and is defence in depth only.

### 9.5 Retained-frame bound

If a close does not blank the panel, the last frame (pattern or red field, at the
127 backlight) can stay up until the earliest of: `fs-done` (PM `n` at the dark check →
immediate), the idle limit (≤ last activity + 120 s), DEADLINE T0 + 200 s, or backstop
201 s. These are intended reboot times, not guaranteed panel-off times (FS-R-007 §4).
After that, the manual route (`RECOVERY.md`) applies.

---

## 10. Safety envelope (unchanged unless stated)

- `fastboot boot` only, no flash. Unit 1, v66 slot A. A fresh nonce from the builder,
  typed by the PM. The ledger burns it at the attempt.
- DEADLINE 200 s and backstop 201 s (pid1-hold rev 5, pinned). `fs-reboot-final`.
  Plus the idle limit (§5.9), which can only shorten.
- **One** backlight write per boot (127, normal node, p0), read back before every run.
  No other backlight, BLU, DCS, fan, topology, DSC or clock/bandwidth write. **No
  debugfs mount or read** (PM J-109 #2).
- **zpos** = {0, 0, 1, 1} on the four quad planes (left pair stage 1, right pair
  stage 2, as stock; E15), inside the reviewed atomic commit only (PM J-109 #1):
  runtime DRM state, nothing persistent (lastclose resets it, E18). No other new
  property, no other new write class.
- Holds of 3 s (r1), 10 s (r2) and **5 s (r3)**, each device-enforced.
  FSP_HOLD_MAX_S 10 is compiled in. Pause ≥ 2 s before each off→on, device-enforced
  (bounded loop, §5.3). Total lit time ≤ 18 s.
- **Up to two deliberate off→on cycles** (r2 and r3, against one in 3b). Disclosed in
  the sign-off: untested behaviour on our boot path (FS-R-007 §4). Fan stop/start as
  in 3b, now possibly twice.
- The picture keeps the reviewed levels (0x80 field, 0xFF marks) with less white
  area than v0.5 (§6.3); the red field's luminance is comparable to, not above, the
  pattern's mean [C] (§6.4).
- Settled temperature pair, BA/BF, the dwell gate ≤ 300 s (fs-observe3c,
  unconditional), the PM present with sign-off, AF immediately, AA and follow-ups, the
  ≥ 40 °C rule, physical shutdown/unplug as separate observations.
- FS-R-001 tags intact. No numerical eye-safety claim. "No light seen" is not zero
  emitted light.

---

## 11. Outcomes (proposed OUTCOMES §10; §9 untouched)

### 11.1 Machine side per phase (first match wins within each phase)

| phase | outcomes |
|---|---|
| any | **NOT RUN** (guard, rule, abort or timeout before it; the reason is kept) · **REFUSED** (`FSXE1`, reason) · **INCONCLUSIVE** (no record, FSB1 rejection, late completion, wrong step list, or a runner inconsistency) |
| p0 | **P0 OK**: hash matches the v0.6 pin, exactly one write line with `write_rc=0 readback=127` · **INTEGRITY FAULT** (hash mismatch) · **INCONCLUSIVE** (hash tool fault) · **BRIGHTNESS NOT VERIFIED** |
| r1 | 3b rules 7–15 applied to pattern1 → **R1 SHOWN** (committed, held, clean close) · **R1 SHOWN, UNCLEAN CLOSE** · **SKIPPED** (reason) · **NO-DISPLAY** (exit 10–50) · **DISPLAY FAIL** (hang, exit 60/1) · **INCONCLUSIVE** |
| r2 | **R2 SHOWN-QUAD** (precondition rc=0 with active=0; `quad_vig` or `quad_dma` committed with `post_plane` matching the plan after the right-half conversion — SRC_X 0/1032/2064/3096, CRTC_X 0/1032/0/1032 (E17) — and zpos 0/0/1/1; held; clean close; pause ≥ 2000 ms; read-back 127) · **PRECONDITION UNMET: CRTC ACTIVE** (exit 31) · **SKIPPED** · **NO-DISPLAY** (exit 50: no quad attempt accepted or available; each rc and the split probe's rc kept) · **DISPLAY FAIL** · **INCONCLUSIVE** |
| r3 | the same set with **-SOLID** (`R3 SHOWN-QUAD-SOLID`, …). It also requires mode `show-off-solid` and that the requesting rule (§5.8) held; otherwise **INCONCLUSIVE (runner inconsistency)** |

Runner-inconsistency checks (INCONCLUSIVE): more than one write line in p0, or any
write line elsewhere; r2 executed without r1's clean close; r3 executed without r2
clean, or without the host rule; pause < 2000 ms; a chain or order mismatch
between records; **a real commit with layout `split_probe`, `split` or `single` in
r2/r3; a `zpos_set` other than 0,0,1,1 by slot, a `post_plane` zpos other than
0/0/1/1, or zpos set outside a quad attempt; a selected plane whose logged type
(`max_upscale`) does not match its attempt (VIG for `quad_vig`, DMA for
`quad_dma`)** (also a defect for FS-A-012). A `post_plane` CRTC_X that reads the
unconverted 2064/3096 is not an inconsistency but a reported finding (§6.5).

**Scan-out signature (informational, per lit phase; never a verdict on its own):**
TE and BLU rates over go+1 s → mid → end, `topology_name` after the commit, and the
filtered dmesg lines, e.g. `SCANOUT TE 181/s BLU 181/s topology=<name> dmesg-flags=none`.
Compared against the stock ≈ 182/s. Not an underrun proof (§7).

**Session machine class:** **PASS (machine side)** = P0 OK + R1 SHOWN + R2
SHOWN-QUAD, with the committed tag reported. Otherwise the first failing phase's class
(RUN 1 ONLY when r1 is shown and r2 is not run, skipped, unmet or NO-DISPLAY, with the
reason). CLI exit codes: as 3b (10, 12–18). Revision 1's "FALLBACK LAYOUT" class and
exit 19 are withdrawn (no fallback commit exists).

### 11.2 Optical side per phase and eye

- From `FSR2`: LIT, DARK, GARBLED, READ (correct = exactly that phase's
  `chal[0:8]`, upper case), TIMEOUT, ABORT, NOT_ASKED.
- Per phase: OPTICAL PASS (both eyes correct, phase machine-shown) · ONE-EYE ONLY ·
  LIT BUT GARBLED · DARK · NOT RECORDED (timeout, abort or not asked) ·
  INCONCLUSIVE (contradicts the record: a correct reading in a run with no commit;
  or cannot be confirmed: the record is absent or unusable). This mirrors 3b O1–O6
  per phase.
- **Dark check per phase:** DARK_NOW or LIGHT_NOW. LIGHT_NOW is reported as a
  **retained-frame observation**, which is a safety-relevant finding.
- **Layout reading per eye (run 2; diagnostic labels, never a PASS):**

  | bars (left, right) | F | label | tag |
  |---|---|---|---|
  | 1 2 or 3 4 | upright | all four planes staged as planned; this eye shows buffer half 0 (1 2) or half 1 (3 4) | [D] |
  | 2 1 or 4 3 | half-turn (`i`) | in-buffer 180° does not match the mounting: geometry finding, not a fault | [C] |
  | 2 1 or 4 3 | mirrored (`m`) | a left–right mirror in the path: geometry finding | [C] |
  | 1 2 or 3 4 | flipped top–bottom (`v`) | a vertical flip in the path (bars keep their left–right order, the F is turned over): geometry finding | [C] |
  | 1 2 or 3 4 | half-turn or mirrored | contradictory (a half-turn or mirror would swap the bars): reported as an inconsistency | — |
  | 2 1 or 4 3 | upright | the two planes of that half exchanged position: layout fault | [D] |
  | a `0` on one side | any | that mixer's plane not scanned or not readable: layout fault | [C] |
  | both eyes the same half | any | half mapping fault | [C] |

  The eye showing "1 2" answers which eye buffer half 0 drives (research §A.1 [O]).
  `tilt` per eye records the roll direction (expected sloped, E13). A reading that
  contradicts the characters (e.g. correct characters and a `0` side) is noted as an
  inconsistency.
  **Q7 fallback:** bars not asked on the run-3 path (§8.2; `session.json` r2
  `Q7Fallback`) are expected, never a reason for INCONCLUSIVE: no layout line for a `c`
  eye, a `d` eye's F/line reported as "bars not asked (Q7 fallback); F and line as
  recorded", and one report line `READINGS NOTE: r2 bars_left, bars_right not asked
  (Q7 fallback: the run-3 path; DESIGN 15 Q7)`.

### 11.3 Run-3 interpretation (requires R2 and R3 both machine-shown with the **same** quad tag; otherwise "LAYOUT DIFFERS: no comparison")

| R2 (either eye) | R3 (both eyes) | interpretation | tag |
|---|---|---|---|
| GARBLED or LIT | UNIFORM_RED | our pixels reach the panel through this layout. The R2 garble depends on content (edges, text): suspect the compression/fetch path under detailed content | [C] |
| GARBLED | SAME_AS_R2 | the stripes do not depend on our frame. Suspect the panel/DSC/timing side, or a throughput fault the quad layout did not cure; not our buffer contents | [C] |
| GARBLED | DIFFERENT | data reaches the panel but is corrupted depending on content: pipe fetch, format or stride path | [C] |
| any | PARTIAL_RED | part of the staging fails even for flat content: a plane/mixer fault | [C] |
| any | UNIFORM_OTHER | channel order or format mismatch (blue = R/B swap, XR24 read as AB24) | [C] |
| any | DARK | the second off→on did not light the panel: wake is unreliable | [O] |
| eyes disagree | — | reported per eye; no interpretation | — |

The interpretation is a diagnostic label, never a PASS. A stage PASS still needs an
OPTICAL PASS (8 characters in each eye) in a machine-shown r1 or r2 (3b §9.6).

### 11.4 Classifier report (`fs-classify3c.ps1`)

One line per phase (machine class; layout tag, topology_name post-commit, core_clk
read, scan-out signature; per-eye optical; dark check), then the layout readings and
the run-3 interpretation, then:

```
REGISTERED: not a stage PASS: machine PASS (machine side, layout quad_vig); SCANOUT TE 181/s BLU 181/s; R2 optical LIT BUT GARBLED; R3 SAME_AS_R2 → interpretation T2 [C]
```

Inputs: `capture.raw` + idx (re-sliced), `session.json`, `readings3c.txt`, and
observe.json. Separate gates as before: the misc rule, partition/devinfo, recovery,
temperatures.

---

## 12. Implementation plan

### 12.1 Files

| path | action |
|---|---|
| `stage3c/init.sh` | from 3b: product `FrameShift stage3c`; `/bin/fs-phase` replaces `/bin/fs-display`; after `fs_hold_init`, writes `/run/fs.deadline` (T0 + DEADLINE); starts `/lib/fs/fs-idle.sh` (one fork, before SHELL_READY). DEADLINE 200. **No debugfs mount.** |
| `stage3c/fs-phase.sh` | new runner (§5): refusals, markers, gates (r3: quad layout required), per-phase steps, paced emission, sha16 chain, activity/running files |
| `stage3c/fs-probe.sh` | from 3b: roles p0/r1/r2/r3, the dmesg filter and budget, interrupt points; node list unchanged |
| `stage3c/fs-idle.sh` | new (§5.9) |
| `stage3c/src/fs-pattern.c` | v0.6 (§6): caps parsing, quad plan with `a_plane_z`, split probe, v0.6 picture, solid frame, logging, `FSP_OPT_MAX` 38912 and `FSP_OPT_MAX_SOLID` 10240 |
| `stage3c/build-image.sh`, `test-builder.sh`, `test-image.sh` | from 3b: new file list (fs-phase, fs-idle.sh, fs-probe.sh 3c, fs-pattern v0.6); same pins for busybox, fs-supervise, fs-reboot, fs-reboot-final, pid1-hold.sh, fsb1-enc.sh, fsb1-pace.sh, fs-done; applet table rechecked (no new applet expected: `setsid` is already used by init; no `mount -t debugfs` anywhere: static check) |
| `stage3c/tools/` | `build.sh`, `fixtures.sh`, `check_render.py` (+ quadrant map, white/mean bounds, `--solid`), `preview.py` (+ annotated mixer map, solid preview, and a reference sheet of the F upright, half-turned, mirrored and flipped top–bottom with the matching key), `check_propsim.py` (+ caps parsing with the `max_upscale` type check, quad_vig/quad_dma selection incl. ambiguity, zpos {0,0,1,1}, split probe, post_state, converted CRTC_X, 8 KB blob), `check_stream.py` (copy), `image-harness-3c.py`, `pace_evidence.py` (per-phase MAXLINES), `check-timing-3c.py`, `dmesg-timing.sh` (new filter), `encode-timing.sh` (new: §9.1 encode at the maximum streams) |
| `host/fs-collect3c.ps1`, `fs-session3c.ps1`, `fs-observe3c.ps1`, `fs-classify3c.ps1`, `test-host3c.ps1` | new (§8, §11) |
| `common/OUTCOMES.md` §10, `SIGNOFF.md` (new section), `RECOVERY.md` (stage-3c rows), `stage3c/README.md` (incl. the quest-kexec-q2 credit), `IMAGE.md` | docs |
| everything stage 3a/3b, `fs-collect.ps1`, `fs-observe.ps1`, the 3b classifier, the common pinned files | **unchanged** (git diff empty is a fixture) |

### 12.2 Builder and reproducibility

- Fresh nonce per build (`openssl rand -hex 8`). TEST OVERRIDES refused by fs-observe3c.
- Reproducible cpio. The candidate is rebuilt with its own nonce and stamp and must
  give a bit-identical image.
- The kernel bytes stay unchanged. The header diff is limited to ramdisk size and
  signature size.
- The BLAKE2 scan and the exact ramdisk list are as 3b.
- `fs-observe3c -Preflight` checks the MANIFEST hashes of init.sh, fs-phase.sh,
  fs-probe.sh and fs-idle.sh against the repository.

### 12.3 Offline fixtures and tests

- **fs-pattern v0.6** (qemu-aarch64):
  - the v0.5 suite;
  - selection, on caps blobs and property lists built from the trial-(iii-b) logs
    (E4) with the near-match blob keys (E16): `quad_vig` → 71/97/100/103 in VIG0–3
    order; `quad_dma` → 115, 134, 112, 131; x = 1032·k; a missing or unparsable caps
    blob, a plane bound to another CRTC, or < 4 eligible planes → that attempt
    `unavailable:<why>` with no TEST_ONLY;
  - **pipe type (M1):** the full 20-plane fixture where the DMA rect-0 blobs carry
    `pipe_idx` 0–3 (as the kernel reports them) → `quad_vig` still selects only the
    `max_upscale` 20 planes 71/97/100/103; a fixture with `max_upscale` missing or
    3 on one VIG plane → `unavailable:missing`; a fixture with two VIG rect-0 planes
    at `pipe_idx` 2 → `unavailable:ambiguous`; the same for a duplicated DMA rect 1;
  - **zpos (B1):** passed only in quad attempts, on exactly the four planes, values
    0, 0, 1, 1 by slot (left pair 0, right pair 1); a propsim model of the commit-time
    stage slots (E15) shows {0,0,1,1} filling stage 1 and stage 2 with 2 pipes each,
    and shows {0,0,0,0} overflowing stage 1 (the negative control);
  - **post_plane (M2):** propsim returns CRTC_X converted (0/1032/0/1032) and SRC_X
    unconverted; the decoder and classifier accept that as "matching the plan"; a
    propsim returning the unconverted 2064/3096 yields the finding of §6.5;
  - plan order split_probe → quad_vig → quad_dma; `show` plan byte-identical to v0.5;
  - **split probe never committed:** split accepted + both quads rejected → exit 50,
    no real commit; quad_vig rejected + quad_dma accepted → quad_dma committed;
  - render: each quadrant group lies wholly inside its mixer's buffer columns
    (LM0 2 bars, LM1 1, LM2 4, LM3 3, with an F each); the centre line spans
    M_X…ew−M_X in each half; no pixel outside {0x80, 0xFF}; white and mean bounds
    (§6.3) for the fixture nonces and `bbbbbbbb`;
  - render-solid: every pixel 0x00FF0000;
  - propsim with post-commit GETs (post_state/post_plane decoded and re-derived);
  - 8192-byte blob and the connector caps blob; opt budgets at 38912 and 10240 (boundaries);
    a maximum stream ≤ the 57344 / 28672 caps; that maximum (56 KiB) stream is the
    input of `encode-timing.sh` (§9.1);
  - static: no new ioctl, `hold()` textually identical, `a_prop` names = v0.5 set +
    `zpos` (only in `a_plane_z`, only from `FSP_QUAD_Z = {0,0,1,1}`), no SET of `sspp_layout`, `multirect_mode`,
    `topology_control`, `dsc_mode`, `core_*`/`llcc_*`/`dram_*` or `rotation`.
- **Whole image** (qemu/bwrap, the candidate's own initramfs):

  | scenario | what it checks |
  |---|---|
  | `c-nodrm` | — |
  | `c-sim-all` | replayed FSP1 for r1/r2/r3 (quad_vig) |
  | `c-sim-r2-dma` | quad_vig rejected, quad_dma committed |
  | `c-sim-r2-reject` | both quads rejected, split probe accepted → exit 50, no commit, r3 not allowed |
  | `c-sim-active` | exit 31 |
  | `c-order` | r2 before r1 → `order` |
  | `c-repeat` | `already-run` |
  | `c-chain-bad` | `chain` |
  | `c-time` | `time` with a fake `/run/fs.deadline` |
  | `c-pause` | r2 sent at once → device waits ≥ 2 s |
  | `c-idle` | no next command → reboot `collected` at last activity + 120 s ± 1 |
  | `c-idle-stuck` | — |
  | `c-no-ack`, `c-ack-no-done` (deadline T0 + 200.x), `c-done-early` | — |
  | `c-markers` | grammar, ≤ 64 B, no `FSB1`, none after `rec`, nonce correct |
  | `c-probe-hang` | — |
  | `c-no-backlight` | — |
  | `c-record-too-large` | `FSXE1 … ran=1 error=record-too-large …` |
  | `c-step-fail` | an encoder `step<i>` failure after the lit step → `FSXE1 … ran=1` |
  | `c-pause-fault` | an unreadable or implausible uptime at the pause → skip `pause-fault`; the wait never exceeds 20 iterations |
  | `c-sim-r3-hold` | r3 replay: hold 5 s, pattern3 `-t 11`, probe3 `-t 26` |
  | `c-no-debugfs` | no debugfs mount or path access during any phase (harness trace) |
  | `c-usage-then-p0` | (build review) a malformed first command (`usage`, before `/run/fsb3c` existed), then p0 → `order`; `closed` exists |

  Build review, in every scenario: the backlight node's write-closes are counted
  (inotify IN_CLOSE_WRITE): exactly 1 with p0, 0 otherwise; every capture line is the
  banner, an echoed host command (in order), a record/marker/refusal line, an empty
  line or the prompt (no stray tty output); `c-order` also sends r1 after the refused
  r2 (→ `order`). Builder: the debugfs word check plus a mount whitelist (init.sh's five
  mounts) and no tty/console name in `fs-idle.sh`, each with negative fixtures.
- **Host** (`test-host3c.ps1`, replay transport + **ScriptedKeySource** of
  `(delayMs, key)` pairs + a recording sound sink):
  1. a nominal 4-phase session;
  2. a timeout at every prompt type (left, right, chars, dark, bars, orient, tilt,
     r3) → TIMEOUT/NOT_ASKED + fs-done;
  3. `x` at every prompt and during a phase; after `x` during a lit phase the dark
     check is still asked (and only it), then fs-done;
  4. `n` at the dark check (safe finish); `n` at a reading, in the character entry and
     at a layout item is an ignored key (PM feedback 2026-10-12);
  5. ignored keys, buffered early keys discarded and logged;
  6. chars and bars entry: valid, Backspace, invalid, early Enter; Esc in character
     entry returns to the reading prompt with the timeout still running; every
     answer echoed (console transcript);
  7. layout items: asked only after `c`/`d` in run 2, orient/tilt only after `d`,
     skipped as NOT_ASKED below 10 s to the cut-off, never asked in r1/r3; no bars on
     the run-3 path (Q7 fallback), asked off it (rules 1 and 3);
  8. the run-3 decision table (every row of §5.8, mixed eyes; r2 NO-DISPLAY → no r3);
  9. guard refusals for r1/r2/r3 at G − 1 s and admission at G (G = 68/82/64 incl.
     DoneReserve, build review), a send at 144 s refused for each lit phase, plus the countdown
     texts;
  10. the 110 s gap cap;
  11. a truncated slice (no completion) → nothing sent;
  12. an FSB1-rejected slice → readings, no next phase, fs-done;
  13. `FSXE1 … ran=0` refusal → no prompts, fs-done; **`FSXE1 … ran=1` replay** (r1
      and r2, preceded by `begin`/`go`/`end` markers, and an `emit-<rc>` case with a
      partial record) → readings and dark check as for an FSB1-rejected record, no
      next phase, fs-done; p0 `ran=1` → no prompts, fs-done;
  14. stray bytes during prompts → gate refuses fs-done;
  15. markers: banners and sounds fired at the right events; wrong nonce, malformed,
      or split across reads → ignored or reassembled;
  16. SoundPlayer failure fallback; `-SoundCheck` pass and fail paths (new keys);
  17. classifier re-slicing equals the collector's slices;
  18. FSR2 format, monotonic timestamps, no machine facts and no expected bar order
      printed before readings (console transcript check);
  19. every §11 outcome and layout label from synthetic records and readings,
      including each runner inconsistency of §11.1;
  20. regression: `test-host3b.ps1` 116/116, `test-host2.ps1` 459/459, pinned hashes
      unchanged;
  21. **dot-source parameter scope (M4):** `fs-collect3c.ps1` run with every `S3c*`
      parameter at a non-default value; each value is unchanged after the dot-source,
      no `ValidateSet` exception, and a static check that no 3c host file assigns or
      reads `$Stage` or any other name from `fs-collect.ps1`'s `param()` block;
  22. replay-token re-derivation: `Get-Fs3cReplayTokens` on a 4-phase capture, and a
      capture whose recorded `<prev>` does not match the replayed record → divergence;
  23. per-slice FSB1 validation in `Invoke-Fs3cRun` on a 4-record capture (VALID ×4;
      the last slice rejected → that phase INCONCLUSIVE, the earlier phases unaffected).
  24. **end to end (integration pass):** every whole-image scenario capture of the device
      harness (`stage3c/fixtures/image/<scenario>/capture.raw` + `.idx`) replayed through
      `fs-collect3c` with scripted keys and classified by `fs-classify3c`, with the expected
      class per scenario (test-host3c section Z2); conformant scenarios replay without
      divergence and with the recomputed `<prev>` equal to the recorded one, deviating ones
      (order, repeat, bad chain, early fs-done, no ack, a host crash, r3 against the run-3
      rule) diverge exactly at the write the 3c collector does not make.
  25. **build review (section BR):** the p0 integrity gate (pin mismatch, unparseable
      hash, match; and end to end on the c-sim-all capture with the built-in pin),
      Ctrl+C as `x` through the console key source, the console mode, the reading
      checkpoints and the classifier on a checkpoint, key repeat, READ without
      characters, `n` during a run, the banners, the summary behind `s`, the recovery
      line, key-source failures, the sound-check wording and key reach, the order of
      the SIGNOFF/WALKTHROUGH host-pin check; S03b (integrity before two writes) and
      S14r3 (r3 on the gate facts).
- **Timing:** `check-timing-3c.py` CONSISTENT (§9).
- **Not covered offline** (as 3b): real DRM after `open`, whether a quad layout is
  accepted, the real caps blobs, the topology chosen, optical results, live USB
  timing, audibility in the room (only the preflight covers that).

### 12.4 Pins for the session sheet

Image SHA-256, nonce, fs-pattern v0.6 binary, and host files (`fs-collect3c.ps1`,
`fs-session3c.ps1`, `fs-observe3c.ps1`, `fs-classify3c.ps1`, the dot-sourced
`fs-collect.ps1`, `fs-proto.ps1`, `fs-native.ps1`, `fsb1.ps1`, `<withheld capture tool>`,
`fs-miscrule.ps1`, `fsb1.py`, `check-timing-3c.py`), saved as `host-hashes.txt`.

### 12.5 Order of work

1. The §15 Q1 source facts are recorded (B1/M1/M2 and Q1(e), path:line in E15–E18);
   the remaining Q1 items (a), (d) are checked and recorded; `encode-timing.sh` is run
   (§9.1); the Q7 rehearsal procedure is written. Then the PM's go to build.
2. fs-pattern v0.6 and its fixtures; the previews for the PM.
3. fs-probe/fs-phase/fs-idle/init and the image harness.
4. The host session, classifier and tests.
5. check-timing-3c.
6. Docs (incl. the credit), then reviews.

### 12.6 Review plan (memory rule: adversarial reviewers on every package)

- **R-A:** this design, adversarial: protocol and safety, timing, human factors, the
  run-1-unchanged choice (Q16), the picture's envelope.
- **R-B:** fs-pattern v0.6: no write beyond the reviewed commit + zpos {0,0,1,1},
  plane selection from caps (type from `max_upscale`, exactly 4 candidates), the split
  probe never committed, hold identity, record bounds.
- **R-C:** the device runner/idle/init: fork-freedom, the tty-silence of fs-idle,
  refusal order, gates, the chain, no debugfs.
- **R-D:** the host: send-gate preservation, prompt/timeout/abort paths, the
  no-machine-facts rule, reuse of the pinned files without edits, the dot-source
  parameter scope (§8.1), and a diff of every copied piece of the copy/override list.
- **R-E:** a verification pass over all fixes. Then the PM's sign-off. FS-A-012
  discloses everything as a PM executive decision, including zpos (J-109 #1) and the
  §7.1 proposal.

---

## 13. SIGNOFF draft: "Stage 3c run — interactive (PM executive decision, J-107)"

(The signable sheet is `../SIGNOFF-3c.md`; the build-review changes, e.g. the host-pin
check first, the sound-check note, G 34/68/82/64 and ≈ 6 s planning slack, are applied
there. This draft is kept as written for revision 3.)

**A. Before BA (nothing touches the device)**
- [ ] `fs-observe3c.ps1 -Image <...> -Preflight` printed `preflight OK`; the BA, BF,
      attempt, AF and AA commands are ready.
- [ ] Host pins match (§12.4); the output is saved as `host-hashes.txt`. Any difference: stop.
- [ ] **Sound check passed** (`fs-session3c.ps1 -SoundCheck`): I heard and named START,
      END, ANSWER, FINISH and ALARM; the key-reach test passed one-handed.
      `soundcheck.json` is saved.
- [ ] I have seen the previews: the v0.6 pattern (`pattern-v0.6-…-viewer`, with the
      bar groups and F markers), the **F reference sheet** (upright `u`, half-turn
      `i`, mirrored `m`, flipped top–bottom `v`) and the **red field**
      (`solid-red-v0.6-viewer`).
- [ ] I know the keys: per eye `a` light, no pattern · `b` dark · `c` garbled · `d` I
      can read the characters, then 8 characters (Esc goes back to the a/b/c/d choice) ·
      `x` abort (every prompt); dark check `y` dark / `n` light visible (the only prompt
      that takes `n`, PM feedback 2026-10-12); after run 2, only off the run-3 path (Q7
      fallback): bars as two digits `0-4` (the 1 to 4 bars at the LEFT F, then
      under the RIGHT F; `0` = none visible), F `u`/`i`/`m`/`v`/`0`, line `l`/`r`/`0`;
      run 3: `r` all red · `p` partly red · `u` one other colour · `s` same as run 2 ·
      `g` different garble · `b` dark. Every answer is echoed on the console. 30 s per
      prompt; a timeout or `x` ends the session safely (after an `x` during a run I am
      still asked whether the panels are dark).
- [ ] **Rehearsal passed (go/no-go, Q7):** with the replay transport and real keys,
      my run-1 plus run-2 answers (garbled path: left, right, dark; left, right, dark;
      no bar question on this path since the Q7 fallback) took ≤ 40 s in total,
      leaving the ≈ 8 s planning slack of §9.4. The first rehearsal (2026-10-12,
      66.6 s with the bar questions) was NO-GO; the Q7 fallback is applied (§15 Q7)
      and is reviewed before this sheet is signed.

**B. Settled temperature pair** (unchanged from 3b B).

**C. BA, then BF** (unchanged from 3b C; dwell ≤ 300 s enforced before the boot).

**D. What I accept**
- [ ] The one backlight write (127, before run 1), read back before each run.
      ≈ 4.1 % duty is a source-derived expectation.
- [ ] Up to three lit periods: run 1 (3 s, the wake/reset step; read DARK by the PM in trial (iii-b), uncertain, FS-R-010 §2),
      run 2 (10 s, the new 4-plane layout; if the driver refuses it, nothing is lit in
      run 2), and **only if I report run 2 garbled or lit without a pattern**, run 3
      (**5 s**, a plain red field, its brightness comparable to, not above, the
      pattern's average; an estimate, not a measurement). Total lit time ≤ 18 s.
- [ ] Run 1 keeps the old commit (2 × 2064 on the splash CRTC), which was dark last
      time. If run 1 were lit this time, I would see the known garbled stripes for
      3 s, inside the same reviewed brightness envelope.
- [ ] The run-2 (and run-3) commit sets zpos = 0, 0, 1, 1 on its four planes (left
      pair, right pair: the same stacking as stock Android) in the same reviewed
      commit (my decision J-109 #1). No debugfs is mounted (J-109 #2). No other new
      kind of write.
- [ ] **Up to two deliberate panel off→on cycles**, untested on our boot path. A pause
      ≥ 2 s before each, device-enforced. The fan may stop and start with each.
- [ ] Holds are enforced by the device. `x` cannot shorten a hold already running; it
      ends the session after it. I may look away at any time.
- [ ] The pattern will look **rolled by about 21°**, perhaps differently in each eye,
      and off-centre toward the nose and up. That is expected and is not compensated
      in this test.
- [ ] Retained frame: if a close does not blank the panel, the last frame may stay
      until `fs-done` (my `n` at the dark check triggers it at once), the idle limit (120 s), or about
      T0 + 200 s. These are not guaranteed panel-off times; the manual route remains.
- [ ] Prompts appear only after a run has ended. I answer from what I saw. The console
      shows no machine result until all my readings are in. Machine and optical
      results are reported separately (FS-R-011 §3). Run 3's interpretation and the
      layout labels are diagnostic, not a PASS.
- [ ] No numerical eye-safety claim; "no light seen" is not zero emitted light.

**E. Presence** — I am present, headset in hand, power button reachable, keyboard
under one hand.

Then: `fs-observe3c.ps1 -Image <...> -ConfirmNonce <nonce> -BaSummary <...> -BfSummary <...> -ThenCollect`

Signed (PM): ________ UTC: ________

**F. After** — AF at once; `fastboot reboot`; AA; temperature procedure as 3b F
(≥ 400 → shut down at once; at least one follow-up; highest observed reading; shutdown
and unplug as two observations). My free-text description goes in `notes.txt`.

---

## 14. The PM's step-by-step for the session (one step at a time; the Arbiter checks each result)

(The current step list is `WALKTHROUGH.md`, with the build-review changes.)

1. Run the sound check. Report: "all heard, all named, keys OK".
2. Preflight and host pins. The Arbiter confirms they match.
3. Look at the two previews and the F reference sheet. Note: through the lenses the pattern will appear
   tilted by about 21° and shifted toward the nose; that is expected.
4. Settled pair, reading 1. Wait ≥ 10 min. Reading 2. The Arbiter confirms stable
   within tolerance.
5. BA in Android. Note the start time; the 5-minute dwell starts.
6. `adb reboot bootloader`, then BF (`current-slot: a`).
7. Sign section E. Confirm presence in chat.
8. Paste the attempt command. Headset on, eyes at the lenses, one hand on the keyboard.
9. Wait for **yellow LOOK + START**. Run 1 (3 s) follows; expect dark.
10. **Green ENDED + END**, then **ANSWER**: press left, right (and characters if `d`),
    then the dark check. Watch the countdown.
11. Yellow **RUN 2 STARTING**: look for 10 s. In each eye look for: the 8
    characters, the **bar groups with an F** on the left and right parts, and **which
    end of the long centre line is lower**.
12. Green ENDED: answer left, right, dark check. If asked (not when run 3 follows: Q7
    fallback), then per eye: the bar counts, at the LEFT F then at the RIGHT F
    (`0` if none visible), the F (`u`/`i`/`m`/`v`/`0`), the line (`l`/`r`/`0`).
13. If the console says **RUN 3 STARTING**: look for 5 s at the red field. Answer
    with the run-3 keys and the dark check.
14. **FINISH** (red banner and low tone): the device reboots to fastboot. Do not touch
    anything else.
15. AF immediately, then `fastboot reboot`, then AA; follow-ups at +5 and +10 min.
16. Dictate your free-text description. Only then does the Arbiter run the classifier
    and show the machine results.

If anything is unexpected at any step (no banner, a red ALARM, light during a prompt):
press `x` (or `n` at the dark check, for light), look away, and wait. The device recovers by itself
(`fs-done`, idle limit or deadline). Use the manual route only per `RECOVERY.md`
timing.

---

## 15. Open questions and risks

| # | item | tag |
|---|---|---|
| Q1 | **Source facts, settled by R-A against the near-match tree `~/work/fs006-kernel/src` @ `23c97b254`:** **B1** zpos must be {0, 0, 1, 1}, not 0 × 4: the atomic check counts per (zpos, layout) (`sde_crtc.c:5866-5890`) but the commit-time blend setup fills `stage[stage][PIPES_PER_STAGE = 2]` per CRTC (`:2053`, `:2134-2139`; `sde_hw_ctl.h:74`; `sde_hw_mdss.h:35`), so 4 planes at one zpos alias; stage = zpos + `SDE_STAGE_0` without a base layer (`:5894`) gives stock's 1/2 (E15; this also answers former item (b)). **M1** `pipe_idx` is per type (`sde_plane.c:4031-4040`); the type comes from `max_upscale` (`:4018`; VIG 20 `sde_hw_catalog.c:74,1541`, DMA 1 `:76,1829`); key names `pipe_idx`, `max_upscale`, `primary_smart_plane_id` (`sde_plane.c:3985`) (E16; former item (c)). **M2** the right-half CRTC_X rewrite (`sde_crtc.c:5991-5999`, E17). **(e)** lastclose resets custom properties (`sde_kms.c:2710-2770`, `:2811`), so the explicit zpos is required after run 1 (E18). **Recorded in the integration pass (same tree, read-only; paths under `techpack/display/msm/sde/`):** **(a)** `zpos_max` = **10** on v66, so 0 and 1 are inside the range. The property starts at 255 (`sde_plane.c:4138`); with the custom client (`sdecustom` defaults to true, `sde_kms.c:121`) it is `mixer[0].maxblendstages − 1` (`:4162-4165`), capped at `SDE_STAGE_MAX − SDE_STAGE_0 − 1` = 12 − 1 − 1 = 10 without a base layer (`:4166-4170`; enum `sde_hw_mdss.h:210-223`), installed as range(0, zpos_max), flags 0 (`:4177-4178`). The v66 DT (dtc of `vendor_boot_dtb0.dtb`, byte-identical to `~/work/fs006-kernel/dtb0.dts`) has `qcom,sde-mixer-blendstages = <0x0b>` (11) on both MDP nodes and no `qcom,sde-mixer-stage-base-layer`; the anorak dtsi agrees (`anorak-sde-common.dtsi:152`, `:400`). The non-custom path would give 255, also ≥ 1. The atomic check rejects only zpos ≥ 11 and > 2 planes per stage per layout (`sde_crtc.c:5879`, `:5884`); the stage-pair check (`sde_crtc.c:1849-1928`) requires each same-zpos pair to be contiguous with equal y/h, which {0|1032, 2064|3096} at y 0, h 2208 satisfies; the plane-id order rule is skipped (`qcom,sde-pipe-order-version = <0x01>`). **(d)** With `multirect_mode` unset (default NONE; the enum exists only on virtual rect-1 planes, `sde_plane.c:4113-4114`, `:4188-4192`), `sde_plane_validate_multirect_v2` (`sde_plane.c:1815-1990`) selects **PARALLEL** automatically when each rect's `src_w` ≤ `maxlinewidth` (÷ 2 for UBWC) (`:1893-1899`, `:1913-1922`); v66 `qcom,sde-sspp-linewidth = <0x1400>` = 5120, so 1032-px linear rects qualify. Hard rejections there are scaling, 90° rotation, YUV, or the two rects on different xin ids (`:1840-1886`); none applies to `quad_dma` (unscaled XR24, same pipe). **Nothing found predicts the rejection of `quad_vig` or `quad_dma`.** Not determined: the runtime `sdecustom` value (either gives ≥ 1), whether the v66 binary matches this tree exactly, and the quad-pipe split path (`sde_crtc.c:5955+`) beyond the checks above. | [M-static] (B1, M1, M2, e, a, d); (a) also the real v66 DT value |
| Q2 | Plane → pipe mapping (E4) is derived from the catalog order; the caps blob confirms it at run time (type from `max_upscale`, index from `pipe_idx`, rect from `primary_smart_plane_id`; E16) and is logged. A mismatch or an ambiguity makes the attempt `unavailable`, not wrong. | [D]; [M-static] keys |
| Q3 | Topology: the mode requires 4 LM / 4 DSC / 2 INTF (E8). `post_state topology_name` confirms it for our modeset. | [D]; [M] at run |
| Q4 | Linear XR24 at ≈ 3.3 GB/s average, ≈ 7.6 GB/s line-burst peak, against the 16 GB/s default vote [D]. Underruns are not observable in this run (no debugfs); only a dmesg `underrun` line or the optical result would show them. | [C] |
| Q5 | The garble's cause: per-rect throughput (E9) is the leading explanation [D, strong], and the precedent (E12) agrees. Run 2 tests it. A quad layout that still garbles means the mechanism is wrong or incomplete; run 3 then discriminates content-dependence, it does not prove a mechanism. | [D]/[C] |
| Q6 | Does a second off→on cycle (r3) behave like the first? A DARK run 3 is itself a finding. | [O] |
| Q7 | Human time: run 3 is admitted only if the run-1 plus run-2 prompts take ≤ ≈ 48 s; with run 3's 5 s hold and the DoneReserve in every guard the planning slack is ≈ 8 s (§9.4). **Go/no-go:** the PM rehearsal (replay transport, real keys, garbled path) must show run-1 plus run-2 answers ≤ 40 s (SIGNOFF A). If it does not: drop the run-1 per-eye prompts to a single both-eyes key, or drop `bars` on the run-3 path, reviewed before sign-off; a deadline change would need its own justification (not done here). **Resolved (2026-10-12): fallback applied.** The PM rehearsal 2026-10-12 (`captures/b7cf9a0bfb559dcb/rehearsal/`) gave r1 answers 16.4 s, r2 answers 50.2 s (the two LEFT/RIGHT EYE BARS prompts ≈ 48 s): 66.6 s, NO-GO. **`bars` is dropped on the run-3 path** (§8.2; host files only, the image and nonce unchanged); the run-1 prompts are kept. With the rehearsal's own answer stamps run 2 becomes 18.0 s (left, right, dark), r1 + r2 = 34.4 s ≤ 40 s. The rehearsal is repeated on the changed host files (SIGNOFF-3c A) and the change is reviewed before sign-off. | resolved: fallback applied; re-rehearsal (SIGNOFF A) |
| Q8 | Write class: zpos is decided as part of the reviewed commit (PM J-109 #1). The quad layout and the solid frame use the existing properties. FS-R-010 §4's "keep the plane layout unchanged" governed trial (iii-b); changing the layout is the point of this run and is disclosed in FS-A-012. | decided / [D] |
| Q9 | Can the PM press keys one-handed with the headset held to the face (J-108 open item), now including digits? The key-reach test answers this; a foot pedal or numpad is the fallback. | [O] |
| Q10 | Sound audibility over room noise and the headset fan: the preflight proves audibility at that moment only. | [M] at preflight |
| Q11 | `/proc/uptime` (markers, idle limit) vs CLOCK_MONOTONIC (fs-pattern stamps) diverge only across a suspend, which the image never requests. | [C] |
| Q12 | `fs-idle.sh` must never write the tty. A stray byte would make the send gate refuse `fs-done` (safe, but it costs the early recovery). Covered by static checks and the `c-idle` fixture. | [D] |
| Q13 | The post-commit snapshot adds ioctls during the image period on the same fd. They are read-only GETs, but this is new driver interaction in the lit state. | [C] |
| Q14 | The record-size bounds (56798 / 28126 B against the 57344 / 28672 caps, 546 B margin; 1545 / 945 lines) are design targets until the propsim maximum fixture asserts them. A cut pattern stream stays INCONCLUSIVE. | [D] pending |
| Q15 | The 8-character typing while holding the headset could be slow, and it eats into the prompt budget (Q7). | [O] |
| Q16 | **Decided after R-A: kept.** Run 1 keeps the v0.5 plan, a 2 × 2064 commit on the active splash CRTC (reported dark in trial (iii-b): no panel-on sent [D], BLU IRQ 0 [M]; not zero emission, FS-R-010 §2; E2). The wake comes from run 2's full modeset from an inactive CRTC and does not depend on run 1's layout, so switching gains nothing and changes a proven step. If run 1 were lit, the 2 × 2064 garble would show for 3 s within the reviewed envelope; SIGNOFF D discloses it. | decided / [C] |
| Q17 | No debugfs this run (PM J-109 #2): no underrun counter, no running clock, no kernel-side staging dump. Evidence is TE/BLU rates, GET state and dmesg (§7); the proof read is proposed to the Chair (§7.1). | [O] |
| Q18 | Mounting: the in-buffer 180° assumes the 180° mount (E13); the ≈ 21° roll direction per eye, and whether the eyes roll oppositely, are unknown. The `orient`/`tilt` readings answer both; neither is a pass criterion. | [O] |
| Q19 | The mixer ↔ buffer-column mapping behind the quadrant labels assumes no `swap_mixers` (absent from the v66 DTB, E11). A "2 1, F upright" reading would contradict it, or show exchanged planes. | [M-static]/[C] |
| Q20 | `machachu56/quest-kexec-q2` licence: **GPL-2.0** (root LICENSE; Monado driver files BSL-1.0), checked 2026-10-12 (research "Licence check"). No code is copied; credit only. | closed |
