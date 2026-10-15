# Trial sign-off sheets (FS-A-007 / FS-R-007; trials (i), (iii) and (iii-b))

The PM reads the sheet for the trial, ticks each line, and only then types
the nonce into `fs-observe.ps1 -ConfirmNonce` (FS-R-004, FS-R-007 §1). One
sheet per trial; a copy goes into the attempt log.

## Common to all trials

- [ ] Only Unit 1 (`QUEST3UNIT1`) is attached; Android is up on slot A.
- [ ] `PHASE BA OK` and `PHASE BF OK` were printed (before/after state
      captures: tooling withheld; method private); BA battery level > 50 and
      temperature < 350 (35.0 °C); BF shows `current-slot: a`.
- [ ] I understand this is one temporary boot (`fastboot boot`), never a
      flash, with no retry. If anything goes wrong, I follow
      `devices/quest3/RECOVERY.md`; recovery is **expected, not
      guaranteed**.
- [ ] I understand there is no software watchdog: a kernel hang needs the
      manual route (hold power ~15–20 s, power on; fastboot if needed).
- [ ] I understand the CPU governor is effectively `performance`, no
      thermal-zone drivers are loaded and the fan is not commanded by us;
      protection is the short hold and my attendance (PROJECT_SETUP §6A).

## Trial (i) — stage 2a, nonce `93a1501f0b1fb692`

- [ ] The device should reboot by itself at the latest at about T0 + 260 s
      (backstop 261 s). These are intended times, not guarantees; if
      nothing happens by Th + 320 s, I use the manual route.

## Trial (iii) — stage 3a, nonce `17449af173f0633a`

- [ ] **Retained-frame exposure (FS-R-007 §4):** the client requests a
      10 s hold of a dark static pattern (alarm scheduled at 15 s). Whether
      the panels and backlight turn off when it closes is **not known** on
      this firmware. If they do not, **the pattern may stay displayed until
      the device recovers**. The intended reboot at about T0 + 170 s
      (backstop 171 s) is not a guaranteed panel-off time; a kernel hang,
      suspend or failed reboot leaves it to the manual route (from
      Th + 230 s).
- [ ] **Fan:** on this firmware (v66) the fan driver stops the fan when
      the panel blanks. If the close turns the panels off, the fan (which
      we never command) may stop for the rest of the idle hold, until the
      device recovers (FS-A-008 §3). The hold is idle and attended.
- [ ] At the cue I will look into the lenses and keep looking until the
      second (low) beep. I may take the headset away from my eyes at any
      time if anything looks wrong. Removing the headset from my eyes does
      **not** stop execution: the existing limits and recovery provisions
      still apply, and the result is then reported without an optical
      reading.
- [ ] I record my reading of both eyes and the dark check **before**
      looking at the collector output. The dark check is reported
      separately; a machine PASS does not prove the panels turned off.

Signed (PM): ____________________  UTC: ____________________

---

## Trial (iii-b) — stage 3b (FS-R-010 §4–§6), image `boot-stage3b.img`

Image `ea60d6cddb2d14d16e208d16f6aef0ebc8798c1e9e74c223d73438bd92705841`,
nonce `6cf0f15867f14edc` (`stage3b/IMAGE.md`). **Concurred to execute by FS-R-011 §1**
(read with its clarifications A and B, recorded below); both earlier nonces are spent. One temporary boot,
no retry, same unit (Unit 1, `QUEST3UNIT1`) and slot (A).

### A. Prepare everything before BA (nothing below touches the device)

- [ ] Fresh host session; `fs-observe.ps1 -Stage 3b -Image <...> -Preflight` printed
      `preflight OK`; the command lines for BA, BF, the attempt, AF and AA are
      ready to paste (`stage3b/IMAGE.md` §3).
- [ ] The host tools match their pins (FS-A-011 §1.1): `Get-FileHash -Algorithm SHA256
      devices\quest3\host\fs-observe.ps1, devices\quest3\host\fs-collect.ps1,
      devices\quest3\host\fs-classify.ps1, devices\quest3\host\fs-classify3b.ps1,
      devices\quest3\host\fs-miscrule.ps1,
      devices\quest3\common\tools\fsb1.py, devices\quest3\stage3b\tools\check-timing-3b.py,
      devices\quest3\stage1\fs-proto.ps1, devices\quest3\host\fs-native.ps1,
      devices\quest3\common\host\fsb1.ps1`
      printed exactly the pinned hashes (the pinned capture tool is withheld
      from this copy). The last three are the loaded dependencies
      added by **FS-R-011 §1A**: `fs-proto.ps1`
      `52e007eb6c9ced48aacd5fe42e8bfd5e988e4003dcd3b662ea1e68429e09ed85` (the reviewed
      FS-A-007/008 copy), `fs-native.ps1`
      `101ddfb15d35986705692f973c0ad74c5797dfb82e9947d719fea1eed7a99b80`, `fsb1.ps1`
      `1f84c633e8cf358fce3e006cef996bae9b372ee2914a97a0c5ab864312f0a703`. A different
      helper needs review before execution; the output is saved with this cycle's captures
      (`host-hashes.txt`). Any difference: stop, nothing is booted.
- [ ] I have seen the preview of the bright pattern
      (`docs/research/pattern-preview/bright-v0.5-3f9c07ab-viewer-1032x552.png`):
      a mid-grey field with a white frame, a white square at the top-left, white
      characters (the attempt's own 8 characters, not `3F9C07AB`) underlined, a
      white cross, and 1 bar on one eye's half, 2 on the other.
- [ ] I understand the readings I will give: for EACH EYE and EACH PERIOD (run 1,
      run 2): DARK, LIT (no pattern), GARBLED, or READ with the characters; I give
      them **before** looking at the collector output.

### B. Settled temperature pair (a gate; FS-R-010 §6)

- [ ] Reading 1 (`adb -s QUEST3UNIT1 shell dumpsys battery`, read-only):
      temperature ______ (tenths of °C) at UTC ________, charge ____ %.
- [ ] Reading 2, **at least 10 min later**: temperature ______ at UTC ________,
      charge ____ %.
- [ ] Both are below 350 (35.0 °C) and reading 2 ≤ reading 1 + 5 (0.5 °C):
      **stable within tolerance** (this is not a claim that the temperature is
      "not rising"). Otherwise: wait and take a new pair.

### C. BA, then BF (split lines; each ticked only after its phase)

- [ ] **BA** (Android; tooling withheld, method private) printed
      `PHASE BA OK`; BA battery level > 50 and temperature < 350; BA started at UTC
      ________ (the header of `BA\SUMMARY.txt`). **The 5-minute dwell starts now.**
- [ ] **BF** (fastboot, after `adb reboot bootloader`) printed `PHASE BF OK`;
      BF shows `current-slot: a`.
- [ ] I understand that `fs-observe.ps1 -Stage 3b` **refuses to boot** if more than
      **300 s** have passed since BA started (checked on the host clock **before** the
      attempt registration and launch, so the boot itself starts a few seconds later;
      both `DwellSec` and `DwellAtBootStartSec` are recorded; a host check, not an
      instantaneous cutoff at exactly 300 s, FS-R-011 §1). Then nothing is booted, the nonce stays unspent, an
      abandoned-cycle record is written (`build\stage3b\abandoned\`), and I return
      to Android, take a **new settled pair** and **new BA/BF** (into a new captures
      directory).

### D. What I accept for this attempt

- [ ] **The one new write:** before run 1 the image writes `127` to the normal
      backlight node `panel0-backlight/brightness` (runtime only) and reads it back
      before each run. The expected backlight duty of **about 4.1 %** is derived
      from the source, **not a measured optical cap**.
- [ ] **If the panel is already lit at handoff** (hypothesis H2), the driver might
      apply the 127 at once instead of at run 1's enable: a change of light about
      0–3 s **before** run 1's commit, without the pattern. Light without the
      pattern before run 1 is reported as such (LIT), not as run 1's pattern.
- [ ] **Two lit periods, one deliberate panel off→on cycle:** run 1 (about 3 s),
      starting about 3.5–6.5 s after the cue; then **a pause of at least 2 s, during
      which actual darkness is observed separately; run 2 executes only if its
      inactive-CRTC precondition is established** (FS-R-011 §1B: the collector's cue
      still says "a DARK gap of at least 2 seconds" and is read this way; it cannot
      promise optical darkness, see "Retained frame" below); then run 2 (about 10 s). Run 1's
      close and run 2's enable are Meta's normal driver paths, but this cycle is
      **untested** on our boot path. If run 2 finds the display still active, it
      commits nothing ("precondition unmet").
- [ ] **Fan:** on this firmware the fan driver stops the fan when the panel blanks:
      the fan may stop after run 1, start again with run 2, and stop again after
      run 2, until recovery. The hold is idle and attended.
- [ ] **Retained frame:** if a close does not turn the panels off, the **bright**
      pattern may stay displayed until the device recovers. The intended reboot at
      about **T0 + 200 s** (backstop 201 s) is not a guaranteed panel-off time; a
      kernel hang, suspend or failed reboot leaves it to the manual route (from
      **Th + 260 s**, `RECOVERY.md`).
- [ ] **How results are read (FS-R-011 §3):** "PRECONDITION UNMET: CRTC ACTIVE" also
      covers a failure to *establish* inactivity; the raw reason is kept, and ACTIVE=1 is
      reported only if that value was actually read. A run skipped because brightness 127
      was not verified does not prove the earlier write had no optical effect. A cut
      pattern stream stays INCONCLUSIVE. An admitted run 1 can establish the display
      milestone without run 2, but not the full two-run PASS or an off→on result; a
      correct optical reading cannot override rejected framing, an unsound stream or a
      runner inconsistency. Machine result, per-run/per-eye readings, persistent-state
      checks and recovery/temperatures are reported separately.
- [ ] No numerical eye-safety guarantee is claimed from the spacing of the
      transitions. I may look away at any time; that does not stop execution, and
      the result is then reported without an optical reading.
- [ ] "No light seen" is **not** a measurement of zero emitted light or of zero
      exposure (FS-R-010 §2).

### E. Presence, immediately before the attempt command

- [ ] I am physically present with the headset, I will look into the lenses at the
      cue and keep looking until the second (low) beep, and I can reach the power
      button for the manual route.

Then: `fs-observe.ps1 -Stage 3b -Image <...> -ConfirmNonce 6cf0f15867f14edc -BaSummary <BA\SUMMARY.txt> -BfSummary <BF\SUMMARY.txt> -ThenCollect`.

Signed (PM): ____________________  UTC: ____________________

### F. After the attempt (in this order)

- [ ] My readings, per eye and per period, recorded **before** viewing the
      collector output (they become `readings.txt`, four `FSR1` lines).
- [ ] The dark check during the 10 s pause, recorded separately.
- [ ] **AF immediately** on return to fastboot, then
      `fastboot -s QUEST3UNIT1 reboot`, then AA promptly in Android.
- [ ] AA battery temperature ______ at UTC ________. **At ≥ 400 (40 °C): start the
      shutdown/cooling procedure at once** (below), do not wait for anything else.
- [ ] **At least one scheduled follow-up reading even if the AA temperature is below 400** (trial
      (iii) showed a delayed rise): +5 min ______, +10 min ______. Continue every
      5 min while it rises and stays below 400; **at ≥ 400 shut down at once (no
      further readings; the manual fallback schedule in `RECOVERY.md` is never a reason
      to wait while hot, FS-R-011 §1)**. **Highest observed reading:** ______ (the highest reading
      taken, not an asserted true peak).
- [ ] **Shutdown/cooling procedure:** power off from the **power menu** while still
      connected; confirm by **physical observation** (screen and LEDs off, no
      response) that the device is off and not in standby (adb disappearing alone
      is not enough); then **unplug**. Record the shutdown observation and the unplug
      as **two separate observations** (FS-R-011 §1). Do not restart the device solely to read the
      temperature.
