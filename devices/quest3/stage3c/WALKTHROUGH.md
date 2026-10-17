# Stage 3c - the PM's step-by-step for the session

**Status: DRAFT** (from `DESIGN.md` revision 3, §14; build-review fixes 2026-10-12; Q7 fallback and
PM rehearsal feedback 2026-10-12: no bar question on the run-3 path, `n` only at the dark check; console
checklist 2026-10-12, PM decision J-118: the sign-off sheet is replaced by `fs-checklist3c.ps1`, run at
steps 5, 6 and 9; review fixes 2026-10-12: `<cycle>` = `captures\<nonce>`, plain-language
questions; single temperature reading 2026-10-13, PM J-125: step 6 takes one reading, not a pair; review fixes
2026-10-13: the reading typed as text with the unit's serial, the time is the PC's UTC, `-Serial` on the attempt). One step at a
time: the Arbiter gives the next step only after checking the result of the current one. Every
command runs on the host in a `powershell.exe` console window from the repository root
(`<repo>`). Placeholders: `<cycle>` = `captures\<nonce>`, this cycle's
capture directory (today `captures\<attempt nonce withheld>`; `<withheld capture tool>` without `-CapturesRoot`
writes its phases into `<cycle>\BA`, `<cycle>\BF`, `<cycle>\AF`, and the checklist and the rehearsal
live there too), `<img>` = the build directory of the candidate image, `<nonce>` = its 16-hex nonce (the
CANDIDATE today: `build\stage3c\20261012T010256Z-<attempt nonce withheld>`, nonce `<attempt nonce withheld>`,
SHA-256 `9d3ad984...9bd914bd`; SIGNOFF-3c.md has the full values; a later rebuild gives a new
nonce). The fs-pattern v0.6 pin (`066bdc3e...27bc`) is built into `fs-collect3c.ps1`'s integrity
check and `fs-classify3c.ps1`; `-C3cPatternPin` is not needed.

If anything is unexpected at any step (no banner, a red ALARM, light during a prompt): press `x`
(at the dark check, `n` for light still visible; **Ctrl+C is the same as `x`**), look away, and wait. The device
recovers by itself (`fs-done`, the idle limit of 120 s, or the deadline at about T0 + 200 s). Use
the manual route only per `RECOVERY.md` timing. Do not click into the console window.

---

### Before the boot (nothing touches the device)

**1. Host pins (first: the later steps run these files).**
`Get-FileHash -Algorithm SHA256 -LiteralPath devices\quest3\host\fs-collect3c.ps1, devices\quest3\host\fs-session3c.ps1, devices\quest3\host\fs-observe3c.ps1, devices\quest3\host\fs-classify3c.ps1, devices\quest3\host\fs-checklist3c.ps1, devices\quest3\host\fs-collect.ps1, devices\quest3\host\fs-classify.ps1, devices\quest3\host\fs-classify3b.ps1, devices\quest3\host\fs-native.ps1, <withheld capture tool>, devices\quest3\host\fs-miscrule.ps1, devices\quest3\stage1\fs-proto.ps1, devices\quest3\common\host\fsb1.ps1, devices\quest3\common\tools\fsb1.py, devices\quest3\stage3c\tools\check-timing-3c.py | Format-Table Hash, Path -AutoSize | Out-String -Width 400 | Tee-Object <cycle>\host-hashes.txt`
(create `<cycle>` first). **Run it again now even if `<cycle>\host-hashes.txt` already exists**: the
list is now 15 files (`fs-checklist3c.ps1` added) and the pins changed with the console checklist
and again with the single temperature reading (J-125);
`Tee-Object` overwrites the old 14-file list. Run it again after any change to these files. The
hashes print in upper case; the SIGNOFF-3c A table is in lower case. The checklist (step 5) compares
`<cycle>\host-hashes.txt` with the table; the Arbiter may look too. Any difference: stop.

**2. Preflight.**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-observe3c.ps1 -Image <img>\boot-stage3c.img -Preflight`
Report the last line (`preflight OK ...`). (The checklist runs it again in step 5.)

**3. Sound check.**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-session3c.ps1 -SoundCheck -SoundCheckDir <cycle>`
Press `y` for each named sound, name the three unnamed ones (`s` START, `e` END, `a` ANSWER,
`f` FINISH, `l` ALARM), then press each key as asked, one-handed (letters, digits, `?`, Esc,
Enter, Backspace). Report: "all heard, all named, keys OK" and the last line
(`SOUND CHECK PASSED`). It writes `<cycle>\soundcheck.json` (`"Pass": true`). This is the
only check of the audio: keep these speakers and this volume for the session.

Throughout: **tap** keys, never hold them, and wait for each answer's echo before the next
(a held key can auto-repeat into the next answer; the same key within 600 ms is ignored).

**4. Rehearsal (go/no-go, Q7).**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-collect3c.ps1 -S3cReplay devices\quest3\host\fixtures\stage3c\replay\garbled-r3\capture.raw -S3cOutDir <cycle>\rehearsal-2 -S3cRehearsal -S3cReplayPin f6a9c3e2b1d0a4958877665544332211ffeeddccbbaa99887766554433221100`
This replays a recorded session in real time with the real banners, sounds and prompts (the pin
is the fixture's digest; the output directory must be new: `<cycle>\rehearsal` keeps the first,
NO-GO rehearsal of 2026-10-12). Answer as on the garbled path: run 1 `b`, `b`, dark check `y`; run 2
`c`, `c`, `y` (no bar question on this path: the Q7 fallback, after the NO-GO rehearsal of
2026-10-12); run 3 `s`, `s`, `y`. At the end press `s` to show the summary (it is also saved as
`<cycle>\rehearsal-2\summary.txt`). Report the line
`REHEARSAL: run-1 plus run-2 answers ... s; go/no-go ...`. It must say **GO** (≤ 40 s).
Otherwise stop and report.

**5. Console checklist, phase A** (replaces the sheet's sections A and D).
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-checklist3c.ps1 -Phase A -Cycle <cycle> -Image <img>\boot-stage3c.img`
It checks steps 1 to 4 from the files (host pins first, then the preflight, `soundcheck.json`, the
rehearsal's GO line, the preview files) and then asks three questions, each answered with `y` or
`n` (15 minutes per question). Before the first it lists the six preview pictures with their full
paths, each with one line on what it shows: open each one (paste the path into File Explorer) and
look. Before the second it prints the keys, before the third points D1 to D14 (what you accept).
Report the last line: `PHASE A PASSED ...`, or `STOPPED. Nothing was sent to the headset. Tell the
Arbiter: ...` (then stop and report it).

**6. Temperature reading** (one reading, PM J-125; it replaces the pair 10 minutes apart).
`adb -s <serial> shell dumpsys battery; [DateTime]::UtcNow.ToString('o')` (`<serial>`: the unit of this run; for another unit
its own serial). Report the `temperature`, `status` and `level` lines and the time printed on the last
line: **the UTC time is the PC's UTC at the reading** (that line), not the headset's clock. The battery must not be charging: `status: 3` (discharging), `4` (not charging)
or `5` (full) pass; `status: 2` (charging) fails, so unplug the charger, wait, and read again. The
Arbiter runs phase B with the reading (the rule: temperature below 350, battery not charging, at
most 15 minutes before BA):
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-checklist3c.ps1 -Phase B -Cycle <cycle> -R1 <t> -R1Utc <utc> -R1Status <status> -R1Serial <serial>`
with the values exactly as printed (the temperature three digits, e.g. `312`; the status one digit; the serial
of the unit read). Nothing is rounded: `36.2`, `0` or a status `2.6` is refused as malformed.
The Arbiter reports `PHASE B PASSED` or `STOPPED ...` (then wait and take a new reading). Go on to step 7 at
once: BA must start within 15 minutes (900 s) of the reading. Phase B refuses a reading that is
already older, and the attempt is refused if the reading is more than 900 s before BA.

### The boot

**7. BA in Android.** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <withheld capture tool> -Phase BA -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file>` (it writes `<cycle>\BA\`;
`-Serial` has no default: `<withheld capture tool>` refuses without it).
Report `PHASE BA OK` and the BA start time. **The 5-minute dwell starts now.**

**8. To fastboot, BF.** `adb -s <serial> reboot bootloader`, then `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <withheld capture tool> -Phase BF -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file>` (it writes `<cycle>\BF\`).
Report `PHASE BF OK` and `current-slot: a`.

**9. Console checklist, phase E (presence), immediately before the attempt.**
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-checklist3c.ps1 -Phase E -Cycle <cycle>`
It prints the presence and after-session lines and asks "Are you physically at the headset now?"
and "Can you reach the headset's power button now, and do you know when to use it (RECOVERY.md)?";
both must be `y` (5 minutes per question). Report `PHASE E PASSED` and go straight to step 10 (the
attempt is refused if this answer is more than 300 s old).

**10. The attempt.** Paste:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-observe3c.ps1 -Image <img>\boot-stage3c.img -Serial <serial> -ConfirmNonce <nonce> -BaSummary <cycle>\BA\SUMMARY.txt -BfSummary <cycle>\BF\SUMMARY.txt -ThenCollect`
(`-Serial` has no default: the unit's serial, the same as phase B's `-R1Serial`; the observer also re-checks BA10's
`dumpsys battery`: below 350, status 3, 4 or 5)
(the observer finds `<cycle>\checklist3c.json` itself.) Headset on, eyes at the lenses, one hand on
the keyboard. If it refuses with `console checklist: ...`: nothing is booted; for a stale presence
check repeat step 9, then step 10; otherwise report. If the dwell gate refuses: nothing is booted;
take a new temperature reading (step 6, `-Phase B` again in the same `<cycle>`), new BA/BF into a new
captures directory (`<withheld capture tool> -Phase BA -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file> -CapturesRoot <cycle>\retry-1`, the same
for BF: the default `<cycle>\BA` already exists and would be refused), step 9 again, and the attempt
with `-BaSummary <cycle>\retry-1\<nonce>\BA\SUMMARY.txt -BfSummary <cycle>\retry-1\<nonce>\BF\SUMMARY.txt -ChecklistFile <cycle>\checklist3c.json`.

### The session (the console leads; one key per question)

**11. Wait for the yellow LOOK banner and the START sound** ("LOOK INTO THE LENSES NOW").
Run 1 (3 s) follows within a few seconds; expect dark. A yellow **RUN 1 STARTING - LOOK** and
later a green **RUN 1 ENDED** (falling END sound) may appear while it runs. (If instead a red
**RUN 1 NOT POSSIBLE (integrity)** appears: nothing is lit; FINISH follows.)

**12. Green ANSWER banner and three pips (ANSWER):** answer left eye, right eye (and the
8 characters after `d`), then the dark check (its own banner; `y` dark / `n` light still
visible; the dark check is the only question that takes `n`). Each answer is echoed in words; read it back. A key pressed twice quickly counts once.
Watch the countdown ("N s left to keep RUN 2 possible").

**13. Yellow RUN 2 STARTING:** look for 10 s. In each eye look for the 8 characters, the **bar
groups with an F** on the left and right parts, and **which end of the long centre line is
lower**. (Pressing `n` while a run shows counts as `x`: the run finishes, one safety question
follows, then FINISH.)

**14. Green RUN 2 ENDED, then ANSWER:** left, right, dark check. If asked (not when run 3
follows), per eye: the bar counts, i.e. next to each of the two F letters (below it when upright) a row of 1 to 4
bars: how many at the LEFT F, then at the RIGHT F (`0` if none visible; Backspace
corrects), the F (`u`/`i`/`m`/`v`/`0`), the line (`l`/`r`/`0`).

**15. Only if the console says RUN 3 STARTING:** look for 5 s at the red field. Answer with the
run-3 keys (`r` red, `p` partly red, `u` other colour, `s` same as run 2, `g` different, `b`
dark) and the dark check.

**16. FINISH (red banner, low 330 Hz tone):** `fs-done` was sent; the device reboots to
fastboot in about 1 s. Do not touch anything else. The console then says SESSION OVER: the
machine summary is in `summary.txt` and is **not** shown yet; leave it until step 18.

### After

**17. AF immediately** (`<withheld capture tool> -Phase AF -Nonce <nonce> -Serial <serial> -CommandsFile <withheld rows file>`, into `<cycle>\AF\`), then
`fastboot -s <serial> reboot`, then AA in Android (the same command with `-Phase AA`); follow-ups at +5 and +10 min (≥ 400:
shut down at once, SIGNOFF-3c F; the Arbiter records each reading with its UTC time in `notes.txt`).

**18. Dictate your free-text description** (it goes verbatim into `notes.txt`, with any
correction of a recorded key). Only then press `s` in the collector window (or open
`summary.txt`), and the Arbiter runs
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-classify3c.ps1 -C3cDir <observe dir>\collect -C3cObserveDir <observe dir>`
(the v0.6 pin is built in) and shows the machine results, the optical results per run, the layout labels and (after run 3)
the interpretation, each kept separate.

---

### What the console may show instead (and what to do)

| console | meaning | you |
|---|---|---|
| red **ABORT NOTED - the device finishes this hold** | your `x` (or Ctrl+C, or `n`) during a run | look away if you wish; answer the one dark-check question that follows |
| red **SAFE FINISH - no further run** | a timeout, `x`, `n` at the dark check, or stray device output during the answers | nothing; FINISH follows (or NO fs-done, below) |
| red **RUN 1 NOT POSSIBLE (integrity)** | the pattern program on the device is not the reviewed one | nothing is lit; FINISH follows |
| **RUN n SKIPPED** (neutral) | the device replaced that run by its skip step | nothing; questions may still follow |
| **RUN n NOT POSSIBLE** / **RUN 3 NOT REQUESTED** (after your answers) | not enough time, or the run-3 rule | nothing; FINISH follows |
| red **NO RECORD FOR RUN n BY ITS DEADLINE** + ALARM | the record did not arrive; nothing more is sent | look away and wait (idle limit or deadline) |
| red **SHELL STATE UNKNOWN** or **NO fs-done** + ALARM | the host cannot send `fs-done` safely | look away and wait; manual route only per `RECOVERY.md` |
| **RUN 3 NO LONGER POSSIBLE** during the answers | the countdown reached 0 | finish the answers; FINISH follows |
| **KEYBOARD NOT READABLE** | the console cannot read keys | answer nothing; every prompt times out, which ends the session safely |
| the console window closed or the collector stopped | no host any more (console window closed); your answers so far are on disk | look away; the device recovers within 120 s of idle (idle limit) or by T0 + 200 s (backstop 201 s) |
