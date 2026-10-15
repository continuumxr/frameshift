# fs-collect: the stage-2a serial collector (design)

**Answers:** FS-R-005 §5 D1, FS-A-006 §5.5 item 1, FS-R-006 §5 B (the host
side of FSB1).

**Status:** offline, revision 2 (2026-10-09). This revision fixes the
adversarial review of `da0ad56`, which said NOT READY. Fixture results:
- replay: `test-host2.ps1` sections R and X;
- review findings: section F. Each finding's fixture fails on `da0ad56` and
  passes now.

**The live serial path has never been run.** No device, adb, fastboot or COM
port was used to build or test it.

## 1. What D1 was

The FS-A-005 post-PASS diagnostics (scratch `serial-collect.ps1`; FS-A-005
§8 D1; transcripts in FS-A-005 (private review record)):

1. **Commands were built by string concatenation, with quote characters
   inside the command text:** `"<cmd>; echo __FS''_END_n__"` (pass 1:
   `__FS"_END_n__`).
2. Pass 1's marker reached ash as one unbalanced `"`. The shell went into a
   **continuation state** (PS2 `> `), and each next command was swallowed
   into an open string.
3. The collector **did not know the shell state**. It waited 30 s per
   command, logged "no end marker", and **kept sending**.
4. Pass 2 sent a "repair" `"` **blind**. It *opened* a string. Pass 3's
   identical `"` closed it, and the swallowed text ran as one command name.
5. Reads used `SerialPort.ReadExisting()`, which decodes through an
   `Encoding` (bytes above 0x7F become `?`).

**The class of bug:** the meaning of the bytes sent depended on a parser
state the host was guessing.

## 2. How the redesign removes the class

| D1 failure | rule in `fs-collect.ps1` | fixtures |
|---|---|---|
| Quote characters inside commands | `New-FsCommand` is the only builder: a verb from a fixed table plus a host-generated lowercase-hex token of fixed length. The final text is re-checked against `^[a-z0-9 -]{1,64}\z`. **No quote, `$`, `;`, backslash, CR or LF can appear** | C1–C2 |
| Device text flowing into what is sent | **Device bytes are data only.** There is exactly one `WriteBytes` call, and it writes `ASCII($cmd + LF)`. `$cmd` is assigned once, from `New-FsCommand` | C3–C4 (strict source scan), F6k |
| Blind "repair" keystrokes | None exist | `pre-continuation` |
| **Sending into an unverified state (rule 3, the send gate; revision 2)** | **Immediately before every write** (`Get-FsSendGate`), the collector first reads whatever has arrived. It then requires one of: <br>• **the first command:** no byte has arrived at all, or the tail of the **whole capture** is a primary prompt, quiet for 150 ms. That exact prompt, ESC bytes included, becomes the *expected prompt*; <br>• **every later command:** **zero bytes since the last settled prompt**, and the capture's tail byte-identical to the expected prompt. <br>In both cases the host give-up time must not have been reached. Otherwise the command is **not sent**, nothing is ever sent again, and the result is INCONCLUSIVE. `fs-done` passes through the same gate | F1a–F1h: a continuation, `Password: ` or a second prompt arriving during the 2.5 s ack settle; `login:/Password:`, a pager or bare output before the first command; a changed prompt; a quiet-settle positive control |
| Echo mistaken for output | A completion is a line that **starts with a record tag**, is newline-terminated, and comes after the send offset. No command contains a tag. FSV1, FSS1 and FSB1 carry fresh host tokens | `record-not-at-line-start`, `verify-echoed-challenge`, `spliced-*` |
| Continuation state | PS2 tail after a command, PS2 after a completion, or PS2 before anything was sent: stop | `continuation-after-verify`, `pre-continuation`, `continuation-after-record`, F1a |
| Partial output, silent or echo-only target | `partial` / `silent` / `echo-only` / `no-completion`: stop | `truncated-*`, `status-partial`, `silent`, `echo-only`, `late-record` |
| Missing data reported as data | Every stop is **INCONCLUSIVE** with its reason. `fs-valve` is sent **once** | all of the above |
| Text decoding in the capture | `SerialPort.Read(byte[])`, `DiscardNull=false`, `ParityReplace=0`. Raw bytes are appended as read, with a SHA-256 computed while writing and re-checked from disk | `binary-noise-pre`, R+3 |
| **Device text on the operator console (revision 2)** | All operator output and every stored reason that quotes device text go through `ConvertTo-FsPrintable`. Anything outside `[ -~]` becomes `\xNN`, so ESC, OSC 52, BEL and spoofed status lines are inert | F4a (collector CLI), F4b (classifier CLI) |

**Recovery is never a command into an unknown state.** `fs-done` is sent
only when:
- the challenge verified;
- the last phase ended with its completion and a settled expected prompt;
- the send gate passes.

Otherwise nothing more is sent. PID 1's deadline then reboots the device at
T0 + DEADLINE of its image: 260 s for stage 2a, 170 s for stage 3a, with the
backstop 1 s later.

**Fix round 6 (e2e review):** two terminal states recover at once, through
the gate:
- a **foreign ack** (FSS1 shows a token this collector did not send);
- a **runner refusal** (`FSVE1`/`FSDE1 … END` instead of a record).

Both are INCONCLUSIVE, and fs-done follows.

## 3. Protocol, as sent

```
(read only; ≥1 s and until 150 ms quiet)   -> stop unless empty or a primary prompt
fs-verify <32 hex>          -> FSV1 … END; must verify (nonce, sha256(nonce:challenge), kernel, pid1)
fs-ack <16 hex>             -> FSA1 queued END
(2.5 s, reading) fs-status  -> FSS1 … acked=<token> … HOST_ACK; at most 3 times, each through the gate;
                               acked=<another token> -> stop at once (foreign ack), gated fs-done
(all of the above: before BootStartUtc + ACK_WINDOW - 15 s; the "ack window" cap)
fs-valve <32 hex>  (once)   -> FSB1 BEGIN … FSB1 END, then the prompt   (-Stage 2a)
fs-display <32 hex> (once)  -> the same, exp=stage3a                       (-Stage 3a)
FSVE1/FSDE1 error=… END     -> the runner refused: terminal, INCONCLUSIVE, gated fs-done
(stage 3a: N beep-1 + host beep, 10 s read-only pause for the PM, N beep-2 + second host beep; §11)
fs-done                     -> FSD1 queued END   (only from a known, verified state, through the gate)
```

After the exchange, the **whole** `capture.raw` (read back from disk, hash
checked) goes to `common/host/fsb1.ps1` `Test-Fsb1Record`.

The stage-2a and stage-3a inits keep the stage-1 `fs-verify`, `fs-ack` and
`fs-status` helpers (`stage2a/init.sh`, `stage3a/init.sh` §5).
- PID 1 records only the **first** valid ack.
- **The boot is done by `fs-observe.ps1`, which runs no session.** The
  stage-1 `host-observe.ps1` must not be used with these images: its own
  fs-ack would burn the attempt (B1).

## 4. Timing table (for FS-A-007)

**Revision 3 (coordinated round).**
- `-Stage 2a|3a` selects the runner verb (`fs-valve` / `fs-display`), the
  experiment id, the step list, and **the image's own deadline**.
- Stage 2a uses 8 steps (OUTCOMES rev 4: step 8 `inv`, informational). Its
  deadline is `stage2a/init.sh` `DEADLINE=260`.
- Stage 3a uses `hash,pattern`. Its deadline is `stage3a/init.sh`
  `DEADLINE=170`.
- `stage2a/tools/check-timing.py` reads these numbers from their sources and
  fails if they disagree. That covers the init files, the runners'
  `fs-supervise` timeouts, the compiled `fs-supervise` waits, and this
  collector's defaults.

**The device deadline.**
- PID 1 reboots at T0 + DEADLINE; the backstop follows at + 1 s
  (`common/DEADLINE.md`).
- T0 is fixed by PID 1 after the kernel starts.

**The budget origin is BootStartUtc (revision 9, Chair ruling FS-R-007 B1).**
- `fs-observe.ps1` records **BootStartUtc**, the host's UTC time taken just
  **before** it invokes `fastboot boot`. The device cannot start PID 1 before
  the command is invoked, so **BootStartUtc ≤ T0**, whatever the handoff class.
- Th (`HandoffUtc`, when `fastboot boot` returned) is **evidence only**. A
  successful return does not prove that Th precedes T0: host scheduling,
  process completion and output handling can delay it past T0. Earlier
  revisions used Th as the origin for an acknowledged handoff; the Chair's
  counterexample (start 0, T0 2, Th 60, collector 80) showed a runner budget
  reaching 186 s against a device deadline at 172 s.
- The collector takes `-BootStartUtc` (required live) and `-HandoffUtc`
  (optional, recorded in `collect.json` Timing). `-HandoffUtc` alone is refused.

**Host give-up = BootStartUtc + DEADLINE − 15 s; ack give-up = BootStartUtc + ACK_WINDOW − 15 s.**
- Both are computed as **absolute UTC** times.
- They are converted to the transport's monotonic clock (a Stopwatch) only
  **after the preparation**: the gadget lookup and the transport construction.
  The conversion reads the transport clock first, then UTC, and computes
  remaining = deadline − now from that fresh read. Nothing computed before the
  preparation is carried over, so a slow gadget discovery shortens the budget
  instead of extending it.
- Live mode refuses to start with less than 60 s left before the give-up, or
  less than 30 s of the ack window. It checks once before the preparation (fail
  fast) and again after it (binding; exit 20, nothing sent).
- From then on, every wait is capped by the give-up time on the monotonic
  clock: the phase deadlines, the prompt wait, the ack settle, and the record
  deadline `min(send + 240 s, give-up)`. The send gate checks the give-up and
  (before the runner) the ack give-up before **every** phase.
- Immediately before the runner, the run-time guard requires
  give-up − now ≥ runner worst case + margin + post-record time
  (2a: 127 + 5 + 0 s; 3a: 42 + 5 + 11 s). Otherwise: INCONCLUSIVE, no runner,
  and fs-done only through the send gate from the established shell state.
- At give-up the collector stops, sends nothing more, and says "host gave
  up … before the device deadline".

**The guarantee.** The host stops before BootStartUtc + DEADLINE − 15 s, which is
≤ T0 + DEADLINE − 15 s because BootStartUtc ≤ T0. Any runner it sends has its
worst case end by the same time. Assumptions:
- BootStartUtc is taken before `fastboot boot` is invoked (`fs-observe.ps1`;
  `check-timing.py` M1, test-host2 O23);
- the host UTC clock does not jump between BootStartUtc and the conversion
  (same machine, minutes apart);
- the transport clock is monotonic after the conversion (Stopwatch).

`check-timing.py` checks constant consistency (part 1) and this clock model
statically and as arithmetic (part 2, M1–M4); it is not a device measurement.
`fixtures\b1-timing.ps1` runs the real observer → live collector command line
against a simulated device side (test-host2 section T).

| phase (host) | bound (worst case) | cumulative from collector start |
|---|---|---|
| initial drain | 1 s, up to +3 s while bytes keep arriving | 4 s |
| fs-verify | 10 s completion + 3 s prompt | 17 s |
| fs-ack | 10 s + 3 s | 30 s |
| fs-status × 3 (2a) / × 2 (3a, revision 8) | (2.5 s settle + 10 s + 3 s) × tries | 76.5 s (2a) / 61 s (3a) |
| 3a only: display cue before the runner | 3 s | |
| runner (`fs-valve` / `fs-display`) | min(240 s, give-up − now) | give-up |
| 3a only: beep 1 + pre-done pause + beep 2 (revision 8) | 0.3 s + 10 s + 0.7 s = 11 s | |
| fs-done | 10 s, also capped by give-up | give-up |

**Record budget and runner worst case.** Assume (planning only; the run-time
guard enforces the real remaining time) that the collector starts about 20 s
after BootStartUtc (boot, then the gadget). Since FS-R-007 B1 this figure
includes the `fastboot boot` transfer (~11 s), so B and the spare column below
are optimistic; the run-time guard enforces the real remaining time, which
decides whether a run proceeds, not safety. The worst-case budget
for the record is then **B = DEADLINE − 15 − 20 − before − cue − post**: before = 76.5 s (2a) / 61 s (3a),
cue = 3 s and post = 11 s for stage 3a only (revision 8: the host time after the runner is sent must fit too).

The runner's worst case **W** is the sum, over steps, of:
- the step timeout t;
- the grace g;
- the `fs-supervise` waits: 3 s reap, 3 s stray hunt and 1 s drain;
- 1 s of encoding.

Add 2 s of emission.

| stage | DEADLINE (init.sh) | host give-up | B | steps (t / g) | W | spare |
|---|---|---|---|---|---|---|
| 2a | 260 s (backstop 261) | BootStartUtc + 245 s | 148.5 s | 1–7: 5 / 2; 8 `inv`: 10 / 2 | 127 s | 21.5 s |
| 3a | 170 s (backstop 171) | BootStartUtc + 155 s | 60.0 s (= 170 − 15 − 20 − 61 − 3 − 11; was 58.5 s without cue/post, 3 tries) | `hash` 3 / 2; `pattern` 16 / 3 | 42 s | 18.0 s (run-time guard 42 + 5 s: 13.0 s to spare) |

**Consequence.** Even if every host phase and every step runs to its worst
case, the host has the whole record before it gives up, and it gives up
15 s before the device's earliest reboot. In the normal case the record
arrives within seconds of the request: the steps take milliseconds, and
`pattern` about 10 s.

**Replay** uses a virtual clock from collector start. Give-up defaults to
(stage DEADLINE − 15 s): 245 000 ms for stage 2a, 155 000 ms for stage 3a.
An override `Stage=3a` in `fixtures/replay/CASES.tsv` selects stage 3a.

## 5. Capture files, errors and Replay

`<OutDir>` must not exist. It receives:
- `capture.raw`: the device-to-host bytes;
- `capture.raw.idx`:
  ```
  FSIDX1 nonce=<n16> mode=live|replay|synthetic port=COMn|-
  R <offset> <length> <ms>      a read
  W <offset> <ms> <command>     a write that completed (logged only after the write returned)
  ```
- `collect.json`.

**Errors (revision 2):**
- A failing capture write (disk full) is an engine stop: INCONCLUSIVE,
  `capture write failed`, no `fs-done`.
- A failing close still yields the hash computed while writing, and a
  CAPTURE ERROR line.
- A failing write to the port is not logged as a `W` line, and stops
  everything.
- The CLI always prints a `RECOVERY:` line, even after an error. It writes
  `collect.json` if it can, and says so if it cannot.
- Live `Flush` and `Close` run on a background thread with a 2 s and 3 s
  bound, so a vanished CDC-ACM device cannot hang the host.

Fixtures: F6a–F6e.

**Exit codes.** No verdict uses 0, 1 or 2, so a PowerShell crash can never
be read as a verdict.

| code | meaning |
|---|---|
| 10 | collected, FSB1-valid |
| 11 | collected, FSB1 rejected |
| 14 | INCONCLUSIVE |
| 20 | refused to start; nothing sent |
| 70 | internal error after start |

**`-Replay <capture.raw>`** runs the same engine over a replay transport:
- Recorded chunks arrive at their recorded times (virtual clock).
- It **never delivers bytes recorded after a host write until the collector
  makes that write**. Writing early, or writing something else, is
  divergence (X6).
- The re-capture must be a byte-exact prefix of the source.

The synthetic captures come from `fixtures/gen-replay.ps1` (deterministic,
`MANIFEST.sha256`), modelled on the real ash bytes in FS-A-005. Two cases
replay the real encoder's output. The section-F probes are built at test
time, the way the reviewer built them.

## 6. Finding for the FSB1 encoder (common)

`no-echo-record-joins-prompt`: without an echo, `FSB1 BEGIN` follows the
prompt on the same line, and the whole-capture decode returns `no-begin`.
Proposed: `fsb1_emit` prints an empty line first. `no-echo-leading-newline`
validates.

**Adopted** (common encoder revision 5, coordinated round). `fsb1_emit`
now writes the empty line itself. Evidence:
- common fixtures `noecho-prompt-emitted` (VALID) and `noecho-prompt-joined`
  (`no-begin`; revision 4: 37/38);
- here, the replay case `3a-no-echo`.

The stage-2a/3a runners no longer print their own empty line.

## 7. Not covered offline

- `New-FsRawSerialTransport` has never run against a real port. Only the
  bounded-timeout mechanism is tested (F6e, a blocking call abandoned).
- The live gadget check (`Get-FsGadget`) is exercised only through the CLI
  refusal paths (X7, X8, F6h).
- Prompt recognition assumes ash's `…# ` PS1 and `> ` PS2, as seen in
  FS-A-005. A different PS1 does not cause a send: it stops the run,
  INCONCLUSIVE.

## 8. Review of da0ad56: findings and fixtures

| finding | fix | fixture (fails on da0ad56 → passes) |
|---|---|---|
| **BLOCKER 1**: sends into unverified states (bytes during the ack settle ignored; before the first command only PS2 blocked) | send gate (rule 3, §2) | F1a–F1g (F1h positive control, F1i doc) |
| S2: E1 bypasses (replace, clean filter, fileMode, environment config, alternates, grafts) | `fs-gitcheck.ps1` / `.sh` revision 2 (README) | F2a–F2c, F2g (WSL dash, bash --posix), F2h (Git Bash) |
| S3: binary captures corrupted by PowerShell `>` | byte-exact pull (tooling withheld) | F3a–F3d (public copy: SKIP, withheld) |
| S4: device bytes reach the console unescaped | `ConvertTo-FsPrintable` at every print site | F4a, F4b |
| S5: `[int]` casts drop the TOOL FAULT check; verdict codes collide with crash codes | `[long]` comparisons, errors → INCONCLUSIVE, exit 10–14/64/70 | F5a–F5d |
| nits | capture/close errors, W after write, bounded close, timing, misc args, `-OutFile`, strict C4 | F6a–F6k |

## 12. Revision 9 (Chair ruling FS-R-007 B1: conservative origin, preparation counted)

| item | fix | fixture |
|---|---|---|
| A. origin | the budget origin is BootStartUtc (before `fastboot boot`) for every handoff class; Th kept as evidence (`-HandoffUtc`, collect.json Timing); `-HandoffUtc` alone refused; `observe.json` `BudgetOriginUtc` replaces `HandoffBasisUtc` | O9, O20, O22, O23, X10, X11; T5 |
| B. conversion | absolute UTC deadlines, converted to the monotonic transport clock after the gadget lookup and the transport construction (fresh read; nothing carried over); start refusals re-checked there | T3 (20 s gadget delay: give-up and ack give-up both 20 s earlier on the transport clock), T4 (refused after preparation) |
| C. runner | the run-time guard on the monotonic clock immediately before the runner; the send gate before every phase | T1 (3a, the Chair's counterexample), T2 (2a); replay `b1-late-2a`, `b1-late-3a` |
| nits (review of 5c2e3f9) | N1: an origin later than now is refused outright (was: up to 5 s tolerated); N4: refusal messages floor what is left and ceil what is needed; N3 wording | T9 (fails on 5c2e3f9: `fixtures/b1-timing.5c2e3f9.txt`) |
| D. unchanged | device deadlines 260 / 170, every other behaviour | T6, T7 (normal 3a/2a collection through the live path), T8 (uncertain handoff), all earlier fixtures |

Before/after: `fixtures\b1-timing.fbca773.txt` (T1–T5 and T9 FAIL, T6–T8 pass on the
reviewed host `fbca773`) and `fixtures\b1-timing.after.txt` (8/8);
`stage2a/fixtures/timing/before-HEAD-fbca773.txt` (INCONSISTENT: M2, M3a–c) and
`after.txt` (CONSISTENT).

## 11. Revision 8 (Chair review of FS-A-007: S2 captures, S3 single-operator display protocol)

| item | change | fixture |
|---|---|---|
| **S3** the PM cannot read a console prompt while looking into the lenses | stage 3a, after the record: `N … beep-1 pattern-hold-ended keep-looking` + a **host-console** beep (1760 Hz, 300 ms; `[Console]::Beep`, BEL on the host console as fallback; replay: silent, recorded) → **10 s read-only pause** (`PreDoneMs`) → `N … beep-2 fs-done-next` + a second, distinct beep (440 Hz, 700 ms) → the gated `fs-done`. Nothing is written to the device. The pause no longer re-settles the prompt: a byte during the pause makes the gate refuse `fs-done` (the device deadline recovers) | S49 (order W fs-display < N beep-1 < N beep-2 < W fs-done), S50 (no write between the beeps; ≥ 10.3 s), S51 (two distinct beeps), S53 (none in 2a), S54 (bytes during the pause: no fs-done) |
| **S3 timing** | the post-record host time (11 s) and the cue (3 s) now count against the record budget, in `check-timing.py` and in the run-time guard (`RunnerWorst + margin + PreDone + beeps` must be left before sending the runner). To keep the guard met without touching the image, stage 3a uses **2 fs-status tries** (61 s before the runner instead of 76.5 s). **3a: B 58.5 → 60.0 s; spare (B − W) 16.5 → 18.0 s; guard spare 8.5 → 13.0 s.** 2a unchanged (B 148.5 s, spare 21.5 s). With 3 tries the new pause would make 3a INCONSISTENT (B 44.5 s < 47 s: `stage2a/fixtures/timing/r8-variant-3a-tries3.txt`) | `check-timing.py` CONSISTENT (`stage2a/fixtures/timing/after.txt`); S52 |
| **S2** copy-pasteable captures | the before/after capture tool (withheld; method private): one phase at a time (BA, BF, AF, AA), read-only allowlist enforced (refused before anything runs), ASCII captures, AA boot wait, `SUMMARY.txt`, one OK/STOP line | section P (P1–P16, fake adb/fastboot; public copy: SKIP, withheld) |

## 10. Fix round 7 (re-review of 685da7c)

| item | fix | fixture |
|---|---|---|
| NIT3 the collector-start assumption | before sending the runner: (give-up − now) ≥ RunnerWorstSec + RunnerMarginSec (2a: 127 + 5 s; 3a: 42 + 5 s), else INCONCLUSIVE, no runner, gated fs-done; `check-timing.py` checks the spec against the sources | replay `runner-budget`; check-timing (before: INCONCLUSIVE at `685da7c`) |
| NIT7 fs-done after a foreign ack at the end of the ack window | fs-done is exempt from the ack-window cap (the prompt/tail gate still applies) | O21 |
| PM display cue (stage 3a) | "=== LOOK INTO THE LENSES NOW: the test pattern appears in 3 seconds and lasts up to 10 seconds ===", an `N … display-cue` index line, then a 3 s read-only wait before `fs-display` | S47 (the cue precedes the fs-display write by ≥ 3 s), S48 (none in stage 2a) |
| SF1, NIT4 (`fs-observe.ps1`) | the fixed ledger and build location; handoff basis = boot START when the handoff was not acknowledged | O19, O20 |

**Capture index (revision 5):** `N <offset> <ms> <text>` lines record host
events that are not writes. Replay ignores them.

## 9. Fix round 6 (package reviews of cf251bb)

| finding | fix | fixture |
|---|---|---|
| **B1** no runnable live chain: `host-observe` acks first, PID 1 keeps only the first ack, and the collector burns the attempt | `fs-observe.ps1`: same sign-off gate (`-ConfirmNonce`), manifest/ledger checks and one `fastboot boot` as stage 1, but **no session**. It records Th, watches the FS-<nonce> gadget, and prints (or with `-ThenCollect` runs) the collector. `fs-classify.ps1 -ObserveDir` derives the stage-1 class from observe.json plus the collector's verified FSV1 | section O, O1–O18 (dry observer → collector → classifier with a fake fastboot and a fake serial device); replay `already-acked` |
| **B1** foreign ack | stop at the first FSS1 with a foreign token: INCONCLUSIVE, no experiment request, gated fs-done. Safest: the device recovers now, and nothing is sent into a session another host may also be writing to | `already-acked`: one fs-status, no fs-valve, fs-done sent |
| **S1** ack window missing from the timing | phases before the runner are capped at BootStartUtc + ACK_WINDOW − 15 s; live mode refuses with less than 30 s of it left; `stage2a/tools/check-timing.py` checks it | `ack-window-reached`; check-timing |
| **S2** runner refusal waited for the record deadline | `FSVE1`/`FSDE1 … END` completes the runner phase: INCONCLUSIVE, gated fs-done | `runner-refused-2a`, `runner-refused-3a` |
| stage 3a: the PM confirms the panels are dark before fs-done | 3 s read-only pause with a console line (`-PreDoneMs`) | the `3a-*` replays (the pause is read-only) |

## 13. Revision 10 (FS-R-010: stage 3b, trial (iii-b))

- `-Stage 3b` (collector, classifier, observer). The runner verb is `fs-display`
  (a different image: `exp=stage3b`, steps `hash,probe1,pattern1,probe2,pattern2`),
  device deadline 200 s, ack window 150 s, `RunnerWorstSec` 75, `RunnerMarginSec` 5,
  cue 3 s, pre-done pause 10 s, beeps 300/700 ms, 2 fs-status tries. The live path,
  the send gate, the clock model (origin BootStartUtc, fresh conversion after the
  preparation) and the recovery rules are the same code as stages 2a/3a, whose
  values and texts are unchanged (`test-host2.ps1` 459/459).
- **Immediate runner guard:** `fs-display` is sent only with at least 75 + 5 + 11 =
  **91 s** left before the host give-up (`stage3b/tools/check-timing-3b.py`
  derives W = 74.4 s from the runner's implemented bounds, incl. the paced
  emission of the maximum 2070-line record at 20 lines per 0.1 s; the step caps are
  consistent with that maximum, review M1). Its planning collector start is 25 s
  (trial (iii) measured 21.7 s; conversion at 24.4 s).
- **Cue (stage 3b):** two lit periods: about 3 s after the cue run 1 (about 3 s),
  a dark gap of at least 2 s (the guarantee), run 2 (about 10 s); the first lit
  period starts about 3.5–6.5 s after the cue line; keep looking until
  the second (low) beep (as `SIGNOFF.md` E; the dark check falls between the
  beeps); note each eye and each period. Beep 1 = both runs over (keep looking:
  dark check); beep 2 = fs-done next; then the report prompt with the four `FSR1`
  lines (`fs-classify.ps1 -Stage 3b -Readings`, OUTCOMES §9.5).
- **Observer (stage 3b):** `-BaSummary`/`-BfSummary` are required and the boot is
  refused (nothing booted, nonce unspent, abandoned-cycle record) if more than
  300 s passed since BA started (FS-R-010 §6).
- The record arrives paced (20 lines per 0.1 s); the collector's reassembly is
  unchanged and is tested with the read chunks split at every chunk boundary and
  mid-line (`test-host3b.ps1` P16).
