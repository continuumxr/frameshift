# Step-4 `--list` rule, version 2: amended rule A (FS-R-009 §4)

**Status: adopted per FS-R-009 §4 (amended option A); merged to master after
trial (iii).** Trial (iii) is classified with the reviewed `fs-classify.ps1`
that precedes this change. Option B (`LD_TRACE_LOADED_OBJECTS=1`, `LISTING-RULE-B.md`) is **not
adopted** (FS-R-009 §4).

## 1. Why

On trial (i) (Quest 3, nonce `<attempt nonce withheld>`) step 4,
`ld.so --list /valve/bin/b2sum`, printed four lines where the registered
rule (T1-PINS §3, OUTCOMES §5) allows exactly three. The extra first line,
`\t (0x0000007fb78d0000)`, is the main program's own map. Its name is
empty, and glibc 2.39 prints it whenever an uninitialised byte
(`mode_trace_program`) happens to be set. See
FS-A-009 (private review record) and `listing-evidence/`. In the
logged qemu reproduction, 51 four-line runs were recorded (42 with the
unnamed map below the loader, 9 above it). The "below the loader" condition
proposed in FS-A-009 §4 was therefore dropped.

## 2. The rule (v2A)

The step-4 stdout must be exactly one of:
1. the three required lines of v1, each LF-terminated, fully anchored and
   in this order:
   `\tlinux-vdso.so.1 (0x[0-9a-f]{16})`,
   `\tlibc.so.6 => /valve/lib/libc.so.6 (0x[0-9a-f]{16})`,
   `\t/lib/ld-linux-aarch64.so.1 => /valve/lib/ld-linux-aarch64.so.1 (0x[0-9a-f]{16})`;
2. **one** optional first line matching `^\t \(0x[0-9a-f]{16}\)$`,
   followed by those same three lines.

The optional line's address must be **nonzero** and **distinct** from the
three required addresses. There is no ordering condition. Only one
optional line is allowed, and only in first position. Anything else fails,
including:
- 5 or more lines;
- a named extra line;
- the optional line placed anywhere other than first;
- CRLF line endings;
- upper-case or wrong-length hex;
- an unterminated last line.

The other step-4 requirements are unchanged under both versions: process
end, code 0, no strays, pipes at EOF, capture not truncated, and empty
stderr (OUTCOMES §3/§5). Steps 1–3 and 5–8 are unchanged.

## 3. Versioning (host side only)

`host/fs-classify.ps1`, "§5 step-4 `list` rule":
- **v1**: the registered rule. It applies by default to the runs registered
  under it (`$script:S2ListRuleV1Runs`, by nonce; today only trial (i)).
  Trial (i) therefore re-classifies **exactly as registered**: COMPATIBILITY
  FAIL, rule 6, "not exactly 3 terminated lines". Fixtures L06 and L08 check
  this, L08 line for line against FS-A-009 (private review record).
- **v2A**: amended rule A, the default for every other nonce.
- **Registered runs are locked to v1 (FS-R-009 §3).** Asking for any other
  rule for such a run is refused, and a trial (i) result can never be
  re-graded:
  - CLI: `-ListRule v2A` gives `usage: rule-version refused for registered
    run: …`, exit 64, no OUTCOME line;
  - functions: INCONCLUSIVE, rule 0 ("refused before §6"), with that reason;
  - fixtures L18a–c.
- For any other run, `-ListRule v1|v2A` (CLI and functions) may select the
  version; the name is case-sensitive.
- An unknown name is refused: CLI usage, exit 64; functions INCONCLUSIVE,
  rule 0, `unknown list rule version` (L09, L11). It never falls back to v1
  silently, and never lands on rule 8.
- Every stage-2a result names the rule it applied: the `ListRule` field, and
  the CLI line `Step-4 list rule applied: …`. A v2A pass on step 4 reads
  `ok (list rule v2 (A): 4 lines, unnamed-map line accepted)` or
  `… 3 lines)`. v1 notes are byte-identical to the registered output.

No other implementation of the rule exists. No Python checker reads step 4,
and the image runs no check of its own; `fs-valve.sh` only captures.

## 4. Fixtures (`host/fixtures/listing-rule.ps1`, test-host2 section L)

Each source is hash-checked before use. Git may check text out with CRLF,
so files are read with CRLF converted to LF and then compared with the
recorded SHA-256.

| case | v1 | v2A |
|---|---|---|
| real device output (trial (i) `capture.raw` decoded, SHA-256 = `collect.json`; equals `decoded/4.out`) | FAILED (as registered) | OK (fixture only, **not a re-grade**) |
| qemu 3-line `b2sum`, `uname` (`evidence/fixture/step2.out`, `step3.out`) | OK | OK |
| qemu 4-line, unnamed map **below** the loader (`qemu-raw.log` B-a72-b2sum run 1) | FAILED | OK |
| qemu 4-line, unnamed map **above** the loader (B-a72-b2sum run 3; B-a72-uname run 5) | FAILED | OK |
| synthetic: above the loader / above the vDSO / address 0x…01 | — | OK |
| 33 negatives (L14.01–33): duplicate optional line; two optional lines; 5 lines (extra unnamed or named mapping); named first or last line; optional line 2nd/3rd/last; duplicate address (libc, loader, vDSO); zero address; upper-case, 15- and 17-digit, no-`0x` address; malformed required address; two spaces / no tab / trailing space; altered paths (libc `/usr/lib`, loader target `/lib`, interpreter `/XYZ`, 3-line libc); missing vDSO; CRLF; unterminated (4- and 3-line); empty; optional line alone | FAILED | FAILED |
| whole record: the default is v1 for nonce `<attempt nonce withheld>` and v2A for any other; v2A masks no other failure (L15–L17) | | |
| registered-run lock: v2A on trial (i) refused by the CLI (exit 64) and the functions (INCONCLUSIVE rule 0) (L18a–c) | allowed | refused |

## 5. What a re-run of trial (i) needs

Rule A is **host-side only**. The image content (`fs-valve.sh`,
`fs-supervise`, `/init`) does not change. Even so, **the current image
cannot be reused**:
- Its nonce `<attempt nonce withheld>` is spent. The attempt ledger
  `build/stage2a/attempted` refuses it (one attempt per nonce; IMAGE.md),
  and FS-A-009 (private review record) records it.
- A re-run therefore needs a **rebuild with a fresh nonce**
  (`build-image.sh`), giving a new image hash and a new MANIFEST, plus a new
  sign-off sheet and the PM's live `-ConfirmNonce`.
- The new nonce is not in `$script:S2ListRuleV1Runs`, so v2A applies to it
  by default. Classification output names the rule.
- Before the attempt: adversarial review of this change (classifier and
  section L), then the host suite (test-host2) and `stage2a/test-host.ps1`
  on the rebuilt harness captures.

Documents to update on merge:
- OUTCOMES §5 `list` row, T1-PINS §3 and the IMAGE.md step-4 row (done on this branch);
- the FS-A-007 "anchored three-line rule" wording (relay text: superseded, not edited);
- the JOURNAL entry.
