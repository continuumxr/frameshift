# Stage 3d - the PM's step-by-step (one unit per run; both units passed, J-144 and J-146)

**Status: DRAFT (2026-10-13, host side of stage 3d; re-pointed 2026-10-14 to the v0.7.1 candidate, J-141; 2026-10-14
J-143/J-145: the standing phase A, the carry-over of the sound check and rehearsals, charging below 30.0 °C; not yet
reviewed).** One step at a time: the Arbiter gives the next step only after checking the result of the current one.
Every command runs in a `powershell.exe` console window from `<repo>`.

**A new run, in short (the PM):** the temperature reading → B → BA and BF → E → the attempt (steps 5 to 9). The sound
check, the rehearsals and the phase-A questions come up only when step 2 says they are needed (J-143): a new day, new
speakers, changed session tools, or a changed checklist text.

Placeholders:

- `<serial>`: the unit of this run: Unit 1 (`QUEST3UNIT1`) or Unit 2 (`QUEST3UNIT2`). Both run the same v2.7
  build (J-131, J-133); the image fits both (its MANIFEST says so).
- `<img>`: the image directory of this run; `<nonce>`: its 16-hex nonce (the end of the directory name).
- `<cycle>`: `captures\<nonce>` (create it first; the captures, the checklist and any sound check or rehearsal go there).

If anything is unexpected: press `x` (Ctrl+C is the same), look away and wait. The headset recovers by itself (the end
command, the idle limit of 120 s, or the deadline about 200 s after the test program starts). Switch it off by hand
only as `RECOVERY.md` says. Do not click into the console window.

---

### Before the boot (nothing touches the headset)

**0-pre. The pattern binary (the Arbiter).** `devices\quest3\stage3d\build\fs-pattern` is gitignored, so a merge
does not update it. Before any rebuild, check that its SHA-256 is the one in `stage3d/BUILD-RECORD.txt`
(v0.7.1: `bfafad97…9a9a`). If it is not, run `wsl.exe -e bash -lc 'cd <repo>/devices/quest3/stage3d && bash tools/build.sh'`
and check again. The builder refuses a wrong binary anyway, but the refusal blocks the run (J-142).

**0. A fresh nonce for this run (the Arbiter).** Each run uses its own one-time image. The reviewed candidate
`build\stage3d\20261014T014738Z-<attempt nonce withheld>` (fs-pattern v0.7.1) is the reference; its nonce was spent on Unit 1
(J-144), and the rebuild `20261014T062407Z-<attempt nonce withheld>` on Unit 2 (J-146). The first candidate
`20261013T065151Z-<attempt nonce withheld>` is withdrawn (its nonce spent, J-141), and so is the first v0.7.1 build
`20261014T012519Z-2b2596964c0812b1` (superseded, never booted): never use either. For each run the Arbiter rebuilds in
WSL (`wsl.exe -e bash <repo>/devices/quest3/stage3d/build-image.sh`)
and checks that only the nonce changed:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-nonceonly3d.ps1 -Reference build\stage3d\20261014T014738Z-<attempt nonce withheld> -Candidate <img>`
It must print `NONCE-ONLY REBUILD: OK` (it opens both images and both ramdisks: only the nonce in `/init` may differ).
`fs-observe3d.ps1` runs the same check itself and refuses any image that is neither the reviewed candidate nor a
nonce-only rebuild of it (also at `-Preflight`). If it reports that the image sizes differ, rebuild once more.

**1. Host pins (the Arbiter).** (Create `<cycle>` first.)
`Get-FileHash -Algorithm SHA256 -LiteralPath devices\quest3\host\fs-collect3d.ps1, devices\quest3\host\fs-session3d.ps1, devices\quest3\host\fs-classify3d.ps1, devices\quest3\host\fs-observe3d.ps1, devices\quest3\host\fs-checklist3d.ps1, devices\quest3\host\fs-nonceonly3d.ps1, devices\quest3\host\fs-carry3d.ps1, devices\quest3\host\fs-collect3c.ps1, devices\quest3\host\fs-session3c.ps1, devices\quest3\host\fs-classify3c.ps1, devices\quest3\host\fs-collect.ps1, devices\quest3\host\fs-classify.ps1, devices\quest3\host\fs-classify3b.ps1, devices\quest3\host\fs-native.ps1, <withheld capture tool>, <withheld rows file>, devices\quest3\stage1\fs-proto.ps1, devices\quest3\common\host\fsb1.ps1, devices\quest3\stage3d\tools\check-timing-3d.py | Format-Table Hash, Path -AutoSize | Out-String -Width 400 | Tee-Object <cycle>\host-hashes.txt`
Nothing to report; step 2 checks it against `SIGNOFF-3d.md`.

**2. Start of the cycle: phase A (the Arbiter, before anything else).**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-checklist3d.ps1 -Phase A -Cycle <cycle> -Image <img>\boot-stage3d.img`
(add `-NewSpeakers` only on the first run after the PM says the speakers or the volume changed; do **not** repeat it
when step 2 is run again after steps 3 and 4, or the new sound check would count as older than the declaration). It
checks the pins and the image, then:

- **the sound check and the two rehearsals:** this cycle's own, or the latest earlier ones, carried over while the
  session tools are unchanged, it is the same day on this PC, and no new speakers were declared;
- **the PM's standing acceptance** (`captures\standing\phase-a.json`): while the texts and the pictures are word for
  word unchanged, phase A asks nothing (also after a change of the checklist code alone).

Every sound check and rehearsal counts only on the day it was made, with the current session tools, and after the last
`-NewSpeakers` (each records when and with which tools it was made).

Usually it ends with `PHASE A PASSED` and no question: go on with step 5. If it `STOPPED` with `needed: ...` lines, do
only what they name (steps 3 and 4), then run step 2 again. If it shows changes, the PM reads only those and answers the
one question (`y` or `n`). The first time (no standing acceptance yet) it shows the three pictures, the keys and points
D1 to D14 with three questions. Report `PHASE A PASSED`, or the `STOPPED` line.
Phase A holds for its own day (PC date) only: after a stand-down into a new day, start again at step 2 (phase B in
step 5, phase E in step 8 and the attempt in step 9 refuse with `new day: ...`; BA and BF do not check it). On the same day, once B has passed, phase A refuses to run again (it would break the A, B, E
order): after a refusal of the attempt, continue with a new reading (step 5).

**3. Only if step 2 names it: the sound check.**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-collect3d.ps1 -S3dSoundCheck -S3dOutDir <cycle>`
Press `y` for each sound you hear, name the three unnamed ones, then press each key it asks for. Report the last
line (`SOUND CHECK PASSED`). Keep these speakers and this volume.

**4. Only if step 2 names them: the two rehearsals (no headset; recorded sessions in real time).**
(a) The garbled path:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-collect3d.ps1 -S3dReplay devices\quest3\host\fixtures\stage3d\replay\garbled-r3\capture.raw -S3dOutDir <cycle>\rehearsal -S3dRehearsal -S3dReplayPin f6a9c3e2b1d0a4958877665544332211ffeeddccbbaa99887766554433221100`
Answer: reset question `b` (it stayed dark); run 2 `c`, `c`, then `y`; run 3 `s`, `s`, then `y`. At the end press `s`.
Report the line `REHEARSAL: reset plus run-2 answers ...`. It must say **GO**.
(b) The read path, **timed** (the real 110-second window after run 2):
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-collect3d.ps1 -S3dReplay devices\quest3\host\fixtures\stage3d\replay\nominal-read\capture.raw -S3dOutDir <cycle>\rehearsal-read -S3dRehearsal -S3dReplayPin f6a9c3e2b1d0a4958877665544332211ffeeddccbbaa99887766554433221100`
When run 2 starts the console shows `REHEARSAL ONLY: ... 8 characters: ...`. Answer: reset question `b`; each eye `d`, then
those 8 characters, Enter; the dark check `y`; then in each eye any tilt key, any F key and any two bar keys (the
replay has no picture; only the time counts). At the end press `s`. Report the last line `REHEARSAL (read path): ...`. It must say **GO**.
Then step 2 again.

**5. Temperature reading (on this unit).** With the headset in Android:
`adb -s <serial> shell dumpsys battery; [DateTime]::UtcNow.ToString('o')`
Report the `temperature`, `status` and `level` lines and the time on the last line (the PC's UTC). The rule (J-145):
`status: 3`, `4` or `5` with the temperature below 350; `status: 2` (charging) only with the temperature below 300. If
not, wait (or unplug the charger) and read again. The Arbiter runs:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-checklist3d.ps1 -Phase B -Cycle <cycle> -R1 <t> -R1Utc <utc> -R1Status <status> -R1Serial <serial>`
(values exactly as printed). Then go on at once: BA must start within 15 minutes of the reading.

### The boot

**6. BA in Android.**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File <withheld capture tool> -Phase BA -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file>`
Report `PHASE BA OK`. **The 5-minute limit starts now.**

**7. To fastboot, BF.** `adb -s <serial> reboot bootloader`, then
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File <withheld capture tool> -Phase BF -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file>`
Report `PHASE BF OK`.

**8. Checklist, phase E (presence), right before the boot.**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-checklist3d.ps1 -Phase E -Cycle <cycle>`
Two questions: at the headset? power button? Both `y`. Then step 9 at once.

**9. The attempt: this command runs `fastboot boot`, the one temporary boot of this run.** Type it only after the
sign-off, when the Arbiter asks you to confirm in chat that you are at the headset. Then paste:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-observe3d.ps1 -Image <img>\boot-stage3d.img -Serial <serial> -ConfirmNonce <nonce> -BaSummary <cycle>\BA\SUMMARY.txt -BfSummary <cycle>\BF\SUMMARY.txt -ThenCollect`
Headset on, one hand on the keyboard. A refusal boots nothing: report its line.

### The session (the console leads)

**10. Yellow LOOK INTO THE LENSES NOW.** First the display reset: it should stay **dark** (no banner, no sound).

**11. Green DISPLAY RESET DONE - ONE QUESTION.** Did you see anything during the reset? `y` = yes, `b` = no, it stayed
dark (recorded only; run 2 follows either way). `x` stops. `n` is not an answer here: nothing happens, the question
stays. (If the headset skipped the reset, there is no question.)

**12. Yellow RUN 2 STARTING - LOOK (10 s).** In each eye: the 8 characters, the two F letters with their bars, and
whether the text and the centre line are level.

**13. Green RUN 2 ENDED - ANSWER NOW.** One eye at a time: `d` (then type the 8 characters, Enter), `c` garbled, `a`
light but no pattern, `b` dark. Then the dark check (`y` dark, `n` light still visible). If asked, per eye in this order:
the tilt (`0` level, `r` turned clockwise, `l` turned counter-clockwise, `?` can't tell), the letter F (`u`/`i`/`m`/`v`,
`?` can't tell), the bars at the LEFT F then the RIGHT F (two keys 0-4). No answer within 30 s at one of these skips only
that question; the next one follows (if run 3 could follow, the session ends safely instead).

**14. Only if the console says RUN 3 STARTING:** a red field for 5 s; answer `r`/`p`/`u`/`s`/`g`/`b`, then the dark check.

**15. Red FINISH: fs-done sent.** The headset returns to fastboot. Do not touch anything else. The summary is not shown
yet.

### After

**16. AF at once.**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File <withheld capture tool> -Phase AF -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file>`
then `fastboot -s <serial> reboot`, then AA in Android (the same command with `-Phase AA`). Temperature at 400 or more:
shut down at once. Follow-ups at +5 and +10 min.

**17. Your own description** (verbatim into `notes.txt`, including the tilt you saw in each eye). Only after that, if
you wish, open the expected-view pictures in `devices\quest3\stage3d\fixtures\preview\` (`pattern-v0.7-3f9c07ab-asseen-`,
`-panels-` and `-mixermap-1032x552.png`; not shown before, so they cannot steer the answers). Then press `s` in the
collector window, and the Arbiter runs
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-classify3d.ps1 -C3dDir <observe dir>\collect -C3dObserveDir <observe dir>`.

**18. The next run.** Repeat steps 0 to 17 with a new nonce (a nonce-only rebuild, step 0), a new `<cycle>` and that unit's `-Serial`.

---

### What the console may show instead

| console | meaning | you |
|---|---|---|
| red ABORT NOTED | your `x` (during phase 0, the LOOK cue, run 2 or run 3 also `n`) | look away if you wish; answer the one question that follows |
| RESET: n is not an answer here | `n` at the reset question | press `y` (something visible) or `b` (it stayed dark) |
| red SAFE FINISH - no further run | a timeout, `x`, `n` at the dark check, or stray headset output | nothing; FINISH follows |
| red NOTHING RUNS (integrity) | the pattern program on the headset is not the reviewed one | nothing is shown; FINISH follows |
| RUN 2 / RUN 3 NOT POSSIBLE, RUN 3 NOT REQUESTED | not enough time, or the run-3 rule | nothing; FINISH follows |
| red NO RECORD / SHELL STATE UNKNOWN / NO fs-done + ALARM | the host cannot send fs-done safely | look away and wait |
| no gadget at all; the headset back in fastboot after about a minute | the module index refusal (wrong build?) or an init failure | nothing; report it |
