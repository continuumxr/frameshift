# FSB1 — the result record (framing v1)

**Answers:** FS-R-006 §5 B (attempt nonce, challenge, step identifiers, byte
counts, newline handling, rejection of incomplete or ambiguous records).

**Status:** offline, 2026-10-09. Implemented and fixture-tested.
- **Two adversarial reviews.** The first (rev 1) found nothing in the
  framing. The second (05a2dd2) found nothing blocking in FSB1. Its nit
  added an `absent` step to `valid-t1`, which now has 7 steps.
- **Encoder revision 5** (2026-10-09, coordinated round after the host
  review, `host/COLLECTOR.md` §6): `fsb1_emit` writes **one empty line
  before `FSB1 BEGIN`**. The framing and both decoders are unchanged.
  Fixtures `noecho-prompt-emitted` (VALID) and `noecho-prompt-joined`
  (`no-begin`, what revision 4 produced without echo).
- ~~Not yet used on a device.~~ **Used on a device (status 2026-10-11):**
  trial (i) (stage 2a, 2026-10-09), trial (iii) (stage 3a, 2026-10-10:
  the record was damaged on the serial link and rejected, `line-count`)
  and trial (iii-b) (stage 3b, paced, 2026-10-11: VALID, J-107).

**Implementations:**

| role | file | runs on |
|---|---|---|
| encoder | `target/fsb1-enc.sh` | busybox ash (the reviewed stage-1 busybox 1.37) |
| decoder, reference | `tools/fsb1.py` | Python 3, stdlib only |
| decoder, collector side | `host/fsb1.ps1` | Windows PowerShell 5.1, beside `stage1/fs-proto.ps1` |

The two decoders are independent code. Both must return the same verdict and
the same first rejection code for every input. `host/test-fsb1.ps1` checks
this against `fixtures/fsb1/RESULTS-python.txt`: they agree on 38 of 38
cases.

Terms: MUST, MUST NOT and MAY are used as in RFC 2119.

---

## 1. What the record proves, and what it does not

- **Integrity, not authentication.** `rec_sha256` and the payload hashes
  detect damage, truncation, reordering and ambiguity. They are not a MAC:
  there is no secret on the device, so anyone holding a record could
  recompute them.
- **Execution evidence comes from content.**
  - Command execution is shown by the stage-1 `FSV1` response.
  - Valve execution is **supported**, not proven, by the `b2chal` step: a
    BLAKE2b-512 digest of a fresh host challenge.
    - Nothing else in the image is known to compute BLAKE2b from
      userspace. The builder's byte scan finds no other implementation,
      busybox has no BLAKE2 applet, and the kernel's BLAKE2b is unreachable
      without AF_ALG hash.
    - That scan is evidence, not proof (T1-PINS §6). Provenance comes from
      the pinned, hashed files and the reviewed invocation (FS-R-006 §5 F).
  - Neither comes from the framing.
- **Nonce and challenge are carried for binding.** The decoder rejects a
  record made for another attempt (nonce) or another request (challenge).

## 2. Transport model and newline handling

- The target writes the record as text lines, each ending in exactly one
  `\n` (0x0A). It writes the whole record with one `cat` of a file built in
  RAM (`fsb1_emit`), **preceded by one empty line** (revision 5).
- **Why the empty line.** With echo, the echoed command line ends in `\n`
  and BEGIN starts a line. Without echo (a tty mode this design must not
  rely on), BEGIN would follow the prompt on the same line
  (`~ # ESC[6nFSB1 BEGIN …`). The decoders look for a line that **starts**
  with `FSB1 BEGIN`, so the record would be `no-begin`. The empty line is
  outside the record, and §4 ignores it.
- The record travels over ttyGS0 (CDC-ACM). Stage 1 sets the tty `raw -echo`,
  but busybox ash then runs interactively and may change termios while
  reading a line (`stage1/init.sh` §6). So the design does **not** depend on
  the tty mode.
- **What a tty can do to the bytes, and how FSB1 handles it:**
  - ONLCR (`\n` → `\r\n`, possibly applied more than once). The decoder
    strips **all trailing `\r`** from each line before using it. A
    CRLF-translated record therefore validates (`valid-crlf`,
    `valid-crcrlf`, and `valid-pty`: a real Linux pty with ONLCR set).
  - **A `\r` anywhere except at the end of a line is rejected**
    (`bad-char`). So is any byte outside 0x20–0x7E inside the record.
  - **Payload bytes never cross the tty raw.** Every payload is RFC 4648
    base64. Its alphabet (`A–Z a–z 0–9 + / =`) has no CR, LF, NUL, XON/XOFF
    or other control character, so no line discipline can translate it
    silently. A payload containing `\n`, `\r\n`, NUL or 0xFF is carried
    exactly: fixture steps `text` and `bytes` carry all 256 byte values,
    and the decoded bytes are compared with the raw capture files.
- **Hashes are defined over bytes that never cross the tty in raw form:**
  - `out_sha256` and `err_sha256` are SHA-256 of the exact bytes the child
    wrote (as captured by `fs-supervise`, up to its cap).
  - `rec_sha256` is SHA-256 of the canonical record text (§4.4). It uses
    `\n` terminators, whatever arrived on the wire.
  - Line terminators are never part of a payload.

## 3. Grammar

A record is a contiguous run of logical lines:

```
FSB1 BEGIN v=1 exp=<exp> nonce=<n16> chal=<c32> steps=<N>
FSB1 STEP i=1 id=<id> <supervisor fields> out_len=<a> out_sha256=<h64> err_len=<b> err_sha256=<h64>
FSB1 DATA i=1 s=o n=0 <base64, 64 chars>
FSB1 DATA i=1 s=o n=1 <base64, 1..64 chars>
FSB1 DATA i=1 s=e n=0 <base64>
FSB1 STEP i=2 id=<id> ...
...
FSB1 END v=1 nonce=<n16> chal=<c32> lines=<L> rec_sha256=<h64>
```

**Tokens:**

| token | form |
|---|---|
| `<exp>` | `[a-z0-9_]{1,16}`: the experiment id, e.g. `stage2a`; fixtures use `fixture`, `t1demo` |
| `<n16>` | exactly 16 lowercase hex characters: the image's attempt nonce (stage 1: `FS-<nonce>` USB serial) |
| `<c32>` | exactly 32 lowercase hex characters: the host's fresh challenge for this request |
| `<N>` | 1–32; must equal the length of the host's expected step list |
| `<id>` | `[a-z0-9_]{1,16}` |
| numbers | canonical decimal: `0` or no leading zero; `-1` only where noted |

**Supervisor fields.** These are exactly the `fs-supervise` report keys, in
this order: `end code sig errno ms term_ms kill_ms out_total out_kept
err_total err_kept strays pipes why` (see `src/fs-supervise.c`).
- `end` ∈ `exited signaled timer-term timer-kill exec-failed unreaped
  refused internal nosup`.
- `nosup` is written by the encoder when `fs-supervise` produced no
  well-formed report. Its field values are then fixed: `code=-1`, all
  times `-1`, counts `0`, `pipes=none`, `why=no-report`.
- `code`, `ms`, `term_ms` and `kill_ms` may be `-1`.
- `pipes` ∈ `eof open none`.
- `why` is `[a-z-]{1,32}`. fs-supervise revision 2 emits `none`, `strays-alive`,
  `no-proc`, `capture-write-failed`, or a refusal/internal reason. The
  framing does not interpret it; OUTCOMES §3 treats any `why≠none` as a tool
  fault.

**STEP and DATA rules:**
- STEP lines are numbered `i=1..N` in order.
- After each STEP line come its stdout DATA lines (`s=o`, `n=0,1,…`), then
  its stderr DATA lines (`s=e`, `n=0,1,…`).
- An empty stream has no DATA lines.
- Every DATA line except the last of its stream carries exactly 64 base64
  characters. The last carries 4–64 characters, a multiple of 4.
- The base64 is canonical (§4.6).

**END rules:**
- `lines` is the number of lines from BEGIN up to the line before END.
- `rec_sha256` is defined in §4.4.
- END repeats the nonce and the challenge. Both copies must match.

## 4. Decoder procedure (normative; first failure wins)

Both decoders implement exactly this order. The rejection code is the first
check that fails.

1. **Input limit.** More than 8 MiB → `too-large`.
2. **Logical lines.**
   - Decode the bytes as Latin-1 (1:1).
   - Split on `\n`.
   - Remove every trailing `\r` from each piece.
   - A final piece without a `\n` is an *unterminated* line.
3. **Framing.**
   1. Lines starting `FSB1 BEGIN`: none → `no-begin`; more than one →
      `multiple-begin`.
   2. The first **terminated** line after BEGIN that starts `FSB1 END`:
      none → `no-end`.
   3. Any line outside BEGIN…END containing `FSB1` → `stray-fsb1-line`.
   4. Any line inside with a byte outside 0x20–0x7E → `bad-char`.
4. **END and the record hash.**
   1. END must match its grammar → `bad-end`.
   2. `v=1` → `version`.
   3. `lines` must equal the count → `line-count`.
   4. `rec_sha256` must equal SHA-256 over every line from BEGIN to the
      line before END, **each followed by exactly one `\n`**, ASCII →
      `rec-hash`.
5. **BEGIN and identity.**
   1. BEGIN must match its grammar → `bad-begin`.
   2. `v=1` → `version`.
   3. `exp` must be the expected experiment → `exp-mismatch`.
   4. The nonce, in both BEGIN and END, must equal the attempt nonce →
      `nonce-mismatch`.
   5. The challenge, in both, must equal the host's challenge →
      `chal-mismatch`.
   6. `steps` must equal the expected count → `step-count`.
6. **Body.** Each line is a STEP or a DATA line, else `bad-line`.
   - **STEP:**
     1. grammar → `bad-step`;
     2. an id already seen → `duplicate-step`;
     3. `i` must be the previous `i` + 1 → `step-order`;
     4. `i` beyond the list → `step-count`;
     5. `id` must equal the expected id at position `i` → `step-id`;
     6. cross-field consistency (§5) → `step-inconsistent`.
   - **DATA:**
     1. grammar → `bad-data`;
     2. before any STEP → `bad-line`;
     3. its `i` must be the current step, `s=o` must not follow `s=e`, and
        `n` must count from 0 without gaps, else `data-order`.
   - **At the end of each step**, for each stream:
     1. line widths as §3 → `bad-data`;
     2. base64 must decode strictly and **re-encode to the identical
        text** → `bad-data`. This rejects non-zero pad bits and any
        second spelling of the same bytes;
     3. the decoded length must equal `*_len`, and `*_len` must equal
        `*_kept` (except for `nosup`) → `length-mismatch`;
     4. SHA-256 of the decoded bytes must equal `*_sha256` →
        `payload-hash`.
7. The number of steps must equal the expected count → `step-count`.
8. Otherwise the result is **VALID**, with every step's fields and decoded
   payloads.

Lines outside the record that do not contain `FSB1` (the echoed command, a
prompt) are ignored.

## 5. Cross-field consistency (`step-inconsistent`)

| `end` | required |
|---|---|
| any | `out_kept ≤ out_total`, `err_kept ≤ err_total` |
| `exited` | `0 ≤ code ≤ 255`, `sig=0`, `term_ms=-1`, `kill_ms=-1` |
| `signaled` | `code=-1`, `sig>0`, `term_ms=-1`, `kill_ms=-1` |
| `timer-term` | `term_ms ≥ 0`, `kill_ms=-1` (`code`/`sig` are the raw status) |
| `timer-kill` | `term_ms ≥ 0`, `kill_ms ≥ 0` |

These rules mean **an exit status of 143 is never read as a timeout.** A
child that exits 143 on its own is `end=exited code=143 term_ms=-1`. A
child that exits 143 from a TERM handler after our timer is
`end=timer-term code=143 term_ms=<n>`. Both appear in the `fs-supervise`
fixtures (`exit143`, `term143`).

## 6. Duplicates, retries and ambiguity

- The target runs one step runner once per attempt. The runner refuses to
  start if its record file exists (`fsb1_begin` returns 3), so it can
  never append to an earlier record.
- The host sends the request **once** and never re-sends it (FS-R-005 §5):
  missing completion means INCONCLUSIVE.
- Two BEGIN lines in the captured window, even identical ones, are
  `multiple-begin`. Any FSB1 text outside the record is `stray-fsb1-line`.
  Neither can be resolved by picking one.

## 7. Encoder obligations (`target/fsb1-enc.sh`)

- **Inputs validated before writing:**
  - nonce: 16 hex;
  - challenge: 32 hex;
  - `exp` and `id`: token form;
  - `N`: 1–32.
- **Capture and reporting:**
  - Payloads are the `fs-supervise` capture files, encoded with busybox
    `base64 -w 64`. Empty files produce no DATA lines.
  - `*_len` comes from `wc -c` and `*_sha256` from busybox `sha256sum`,
    both over the capture file.
  - The supervisor fields are copied **only** if the report is exactly one
    line matching the FSUP1 grammar. Otherwise the fixed `nosup` set is
    written.
- **Output:**
  - The record is built in a RAM file.
  - END is appended last, from `wc -l` and `sha256sum` of the file so far.
  - It is emitted by a single `cat`, after one `printf '\n'` (revision 5).
    `fsb1_emit` returns 2, and prints nothing, if the record file is
    missing.
- **Applets used:** `sh cat printf base64 awk sha256sum cut wc sed grep tr`.
  All are in the stage-1 busybox applet table
  (`build/stage1/20261008T024856Z-112740d1bd6a4ecf/applets.txt`). A stage-2a
  builder must add `base64 awk wc head` to its required-applet list (stage
  1 did not need them).

## 8. Fixtures (`fixtures/fsb1/`, generated by `tools/fixtures-fsb1.sh`)

**How the fixture records were made:**
- `valid.txt` was produced by the real encoder, run by the reviewed
  stage-1 busybox (SHA-256 `c2f279d1…ec02`) under qemu-aarch64. Each of its
  7 steps ran under the aarch64 `fs-supervise`.
- `PAYLOADS.tsv` holds SHA-256 values of the raw capture files, made with
  the host's `sha256sum`, not by the encoder. `PAYLOADS-check.txt`
  compares the expected contents (all 256 byte values, CRLF text, KAT
  lines) computed by Python.
- `valid-t1.txt` is the same chain with the four pinned Valve files, staged
  only in WSL (`~/work/t1pin/stage`, never in the repo):
  - `hash`, `absent`, `diag`, `list`, `uname`, `b2kat`, `b2chal` (the OUTCOMES §2 list);
  - the BLAKE2b results agree with Python `hashlib`
    (`valid-t1-check.txt`);
  - the `--list-diagnostics` output contains **no `env[…]` line**: the
    loader saw an empty environment.

| case | expected | what it shows |
|---|---|---|
| `valid` | VALID | the encoder → decoder round trip. 7 steps: CRLF text, all 256 bytes, empty, stdout+stderr with exit 7, `timer-term`, KAT, challenge |
| `valid-pty` | VALID | the record after a real Linux pty with ONLCR (23 CRLF pairs: the leading empty line and the 22 record lines). The CRLF bytes are significant; `.gitattributes` keeps this directory `-text` (J-99) |
| `valid-crlf`, `valid-crcrlf` | VALID | `\r\n` and `\r\r\n` terminators |
| `valid-echo-prompt` | VALID | the echoed command before and a prompt after the record are ignored |
| `noecho-prompt-emitted` | VALID | revision 5: no echo, the prompt directly followed by `fsb1_emit`'s output (empty line, then the record) |
| `noecho-prompt-joined` | `no-begin` | the same without the empty line: what revision 4 produced on a no-echo target |
| `valid-t1` | VALID | the genuine T1 binaries, supervised, under qemu |
| `empty`, `echo-only` | `no-begin` | nothing, or only the echo |
| `truncated-no-end`, `truncated-mid-line`, `truncated-end-unterminated` | `no-end` | truncated |
| `truncated-end-line` | `bad-end` | an END line cut short but terminated |
| `dropped-char` | `rec-hash` | one character lost on the wire |
| `missing-data-line` | `data-order` | one DATA line removed (record hash recomputed) |
| `duplicate-record` | `multiple-begin` | the record twice |
| `stray-fsb1-line` | `stray-fsb1-line` | FSB1 text after END |
| `duplicate-step` | `duplicate-step` | one step block repeated (rehashed) |
| `reordered-steps` | `step-order` | two blocks swapped, original `i` |
| `reordered-steps-renumbered` | `step-id` | swapped and renumbered |
| `missing-step` | `step-count` | the last step removed |
| `wrong-nonce`, `wrong-nonce-end-only` | `nonce-mismatch` | another attempt's nonce, in both or only in END |
| `wrong-chal` | `chal-mismatch` | another request's challenge |
| `wrong-exp`, `wrong-version` | `exp-mismatch`, `version` | |
| `tampered-payload` | `payload-hash` | one base64 character changed, record hash recomputed |
| `tampered-payload-norehash`, `tampered-step-field` | `rec-hash` | changed without recomputing |
| `length-mismatch` | `length-mismatch` | `out_len` altered |
| `noncanonical-base64` | `bad-data` | the same bytes spelled with non-zero pad bits |
| `wide-data-line` | `bad-data` | the same bytes wrapped at 76 columns |
| `step-inconsistent` | `step-inconsistent` | `end=exited` with a `term_ms` |
| `bad-step-extra-key` | `bad-step` | an extra key |
| `line-count` | `line-count` | END `lines` altered |
| `cr-inside-line` | `bad-char` | a CR inside a line (not translation-proof, so rejected) |
| `foreign-line-inside` | `bad-line` | a prompt line inside the record |

**Results:** `RESULTS-python.txt` 38/38, `RESULTS-powershell.txt` 38/38,
cross-check 38/38. Before (the revision-4 encoder, same harness, `ENC=`): 37/38, `noecho-prompt-emitted` → `no-begin` (`fixtures/round5-before/`).

## 9. Paced emission (stage 3b, FS-R-010 §5)

**What changes: only the emitter, and only for stage 3b.** `target/fsb1-pace.sh`
adds `fsb1_emit_paced REC TICK MAXLINES`; `target/fsb1-enc.sh` (revision 5) is
unchanged and the stage-2a/3a images keep `fsb1_emit`. The framing (§3), the
decoder procedure (§4) and both decoders are unchanged.

- **Same bytes.** The paced emitter writes exactly what `fsb1_emit` writes: one
  empty line, then the record file byte for byte. By default it writes 10 lines
  per chunk (`FSB1_PACE_LINES`; stage 3b sets 20, below) with a pause of 0.1 s (`FSB1_PACE_TICK`) after each
  full chunk. Only the timing differs.
- **Identity by refusal, not repair.** The emitter writes nothing and returns 4
  if the record could not be re-emitted byte for byte by the `read`/`printf`
  builtins (a byte outside 0x20–0x7E between the newlines, or no final
  newline), and returns 3 if the record has more than MAXLINES lines. The
  stage-3b runner then prints `FSDE1 error=record-too-large … END` (or
  `emit-4`), and the host classifies the missing record INCONCLUSIVE.
- **Stage 3b paces 20 lines per chunk.** `stage3b/fs-display.sh` sets
  `FSB1_PACE_LINES=20` before it sources the pacer (whose default stays 10, so
  the pinned file is unchanged). One write is then at most about 1.8 KB of DATA
  lines (≤ 3.5 KB with all five STEP lines), well under the 12,289-byte first-read
  boundary at which trial (iii) lost bytes.
- **Maximum permitted record.** MAXLINES = 2070 (`stage3b/fs-display.sh`) is
  the largest record the stage-3b runner emits; the emission-time bound is
  derived from it: 1 s + ceil(2070 / 20) × (0.1 + 0.01) s = 12.4 s
  (`stage3b/tools/check-timing-3b.py`). It is **consistent with the step caps**
  (review M1): BEGIN + 5 STEP + END + every step's stdout at its cap (48 raw
  bytes per DATA line) + the hash step's stderr at its cap = 7 + 6 + 6 + 342 +
  854 + 256 + 598 = 2069 ≤ 2070, and fs-pattern, `fs-probe.sh` (`exec
  2>/dev/null`) and the skip step write no stderr, so no record within its step
  caps is ever refused (the checker asserts it). A 2070-line record is about
  185 KB, far below the 8 MiB decoder limit.
- **The bound assumes the host drains the tty promptly.** A stalled reader
  blocks the emitter's `printf`; that is safe, because both display runs have
  closed by then and the PID 1 deadline does not depend on the runner.
- **Fork-free pacing.** The pause is `read -t 0.1` on a private FIFO opened
  read-write (never blocks on open; nothing writes it), the same mechanism as
  PID 1's loop tick (`DEADLINE.md` §2 property 5). The loop forks nothing;
  `sleep 0.1` is used only if the FIFO is missing. fs-display is not PID 1, so
  a fork failure there could not panic the kernel in any case; the point is
  to keep the step runner fork-light, as DEADLINE.md asks.
- **What pacing is and is not.** It lowers the burst pressure on the CDC-ACM
  path (trial (iii) lost 1,024 bytes at the first read boundary; the cause is
  [O], FS-R-010 §5). It is not a proven cure and not a losslessness
  guarantee: a damaged record is still rejected exactly as before.

**Evidence** (`stage3b/tools/pace_evidence.py` → `stage3b/fixtures/pace/`,
27/27; `host/test-host3b.ps1` sections E and P; stage 3b's 20 lines per chunk):
- byte identity and identical `rec_sha256` (recomputed independently) for a
  representative record (876 lines), the **at-caps** record (every step's stdout
  at its cap and the hash step's stderr at its cap, random binary: 2069 lines)
  and the maximum permitted record (exactly 2070 lines), with the real encoder,
  pacer, busybox and fs-supervise under qemu-aarch64; both decoders VALID;
- the damaged trial-(iii) capture is still rejected (`line-count`) by both
  decoders;
- reassembly: the paced bytes split at every 20-line chunk boundary and at
  mid-line offsets (also inside the END line) decode VALID; through a real pty
  with ONLCR; and through `fs-collect.ps1 -Replay` with the read chunks split
  the same way; every prefix that ends before END is rejected;
- timing: the maximum record took 11.4 s under qemu (bound 12.4 s); 103 pauses
  of ≥ 80 ms were seen on the pty for 104 chunks; the largest single 20-line
  write per record (`fixtures/pace/RESULTS.txt`, the `d-*-chunk-burst` rows)
  was 2,234 bytes for the representative record, 2,180 for the maximum and
  2,178 for the at-caps record. In all three it is the first chunk (BEGIN,
  two STEP lines and 17 DATA lines); the sizes differ only in which lines
  fall in that chunk (the representative record's 17 DATA lines are 1,468
  bytes, the others' 1,399, because fewer of them are short stream-final
  lines), so 2,234 bytes is the largest write measured overall, well under
  12,289;
- refusals: 2071 lines → rc 3, nothing written; CR, TAB, DEL, a byte ≥ 0x80,
  or no final newline → rc 4, nothing written.
