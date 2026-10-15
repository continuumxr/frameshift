# Serial loss in trial (iii): root-cause analysis and fix design


> **FS-R-010 §5 narrowing (2026-10-10, J-78):**
> - The loss location stays [O]. Two 12 289-byte reads do not establish
>   a buffer cap, do not prove the 4 MB request was ignored, and do not
>   identify `usbser.sys` as the dropping layer. The device-side errored
>   request path remains plausible.
> - A filtered or bounded dmesg without a warning does not exclude a
>   device error.
> - USBPcap records host-stack transfers, not bus-level acknowledgements.
> - Windows scheduling is not bounded by the polling interval.
> - Pacing is an availability mitigation, not a proven cure.

Question (PM, 2026-10-09): in trial (iii) (`FS-A-010`) the host lost about
1 KB in the middle of the FSB1 burst on the Quest 3 CDC-ACM serial link. Where
can bytes be dropped, why exactly there, and what is the smallest fix?

This is offline research only. No device was touched, nothing was downloaded
and nothing was committed. This note is the only file written.

Tags (ruling FS-R-001): [M] measured on hardware · [M-static] read from a named
file (cited by path:line) · [D] derived · [C] inferred / external report, not
confirmed · [O] open.

Sources used:
- Evidence: FS-A-010 (private review record)
  (trial iii) and FS-A-009 (private review record) (trial i).
- Host: `devices/quest3/host/fs-collect.ps1`, `fs-native.ps1`.
- Device: `devices/quest3/stage3a/{init.sh,fs-display.sh}`,
  `devices/quest3/common/target/fsb1-enc.sh`, `devices/quest3/common/src/fs-supervise.c`.
- Kernel: WSL `~/work/fs006-kernel/src`. This is the **5.10.198** Quest 3 tree
  ("Oculus Quest 3 kernel project build: 5010519.0.510"). Stock v66 runs
  5.10.198-01402-g1c5986fe21ee, so this is the same SUBLEVEL, but it is **not
  proven to be the v66 source**. `~/work/kgate27/src` (5.10.246, v2.7) was used
  to cross-check: its `u_serial.c` differs only in wakeup/free-request details,
  not in the TX path.
- Windows `usbser.sys`: no official document describes its receive buffer.
  Everything about it below is tagged [C], with sources at the end.

---

## 0. What the evidence shows

**Trial (iii) index** [M-static the FS-A-010 evidence (private)]:

```
W 498 7953 fs-display 4e0a...        command sent
R 498 44 8019                         the echo "fs-display <chal>\n"
R 542 12289 18605                     first read of the burst
R 12831 9910 18612                    the rest, 7 ms later
```

- **[D] The host stopped accepting data at 12,289 bytes until the application read.**
  - Nothing was read between 8,019 ms and 18,605 ms. The device runner held the
    pattern for about 10.55 s (`ms=10552` in the STEP line), then emitted the
    whole record in one go.
  - The host polls every PollMs = 50 ms [M-static `fs-collect.ps1:116-121,257-258`].
    So the whole ~23 KB burst became available within one poll interval. On USB
    that takes well under a millisecond.
  - Even so, the first read returned only 12,289 bytes. The remaining 9,910 bytes
    arrived within the 7 ms after the application drained the queue.
  - This means something below .NET held the stream at 12,289 bytes until the
    application read. Device-side buffering is far larger than that (§1.2), so
    the cap was not on the device. *[narrowed by FS-R-010 §5: no cap is established; the loss location is [O]]*
- **[M-static] The cut is at exactly stream offset 542 + 12,289 = 12,831.**
  - Line n=128 is cut after 52 of its 64 base64 characters.
  - It continues with the last 56 characters of line n=140. No foreign bytes are
    inserted at the splice.
- **[D] Exactly 1,024 bytes were lost.**
  - Every DATA line with n < 249 has the fixed form `FSB1 DATA i=2 s=o n=NNN ` +
    64 base64 characters + LF = 89 bytes. Lines n=127 and n=141 measure 89.
  - The rest of n=128 is 12 + 1 = 13 bytes. Lines n=129..139 are 11 × 89 = 979
    bytes. The head of n=140 is 24 + 8 = 32 bytes.
  - Total: 13 + 979 + 32 = **1,024**.
- **[M-static] The first byte of the burst is a lone LF.**
  - At offset 542 the capture has `\n`, then `FSB1 BEGIN`.
  - This is `fsb1_emit`'s `printf '\n'`, a separate write() from the `cat` that
    follows [M-static `fsb1-enc.sh:97`].
  - So **12,289 = 1 + 12 × 1,024**, and the lost range is bytes [12,289, 13,313)
    counted from that LF, which is the next 1,024-byte unit.
- **[M-static the FS-A-009 evidence (private)] Trial (i) shows the same structure.**
  - `R 540 12289 5430`, then `R 12829 7080 5436`.
  - Offset 540 is also the lone LF before `FSB1 BEGIN`, and the record was
    `COLLECTED-VALID` (no loss).

**[D] Trial (i) was not safer because its burst was shorter.**
- Trial (i) hit the same 12,289-byte cap: the queue was full and the device still
  had 7,080 bytes pending. *[narrowed by FS-R-010 §5: no cap is established; the loss location is [O]]* It was in the same at-risk state and survived it.
- A single clean run in that state shows the loss is intermittent. It does not
  show a size threshold.

---

## 1. Where can bytes be dropped on this path?

The path: `cat` → tty write → n_tty → u_serial kfifo → u_serial USB requests →
UDC/USB link → xHCI → usbser.sys → .NET SerialPort → `fs-collect` capture.

### 1.1 Device tty (n_tty, tty_io): lossless for this writer [M-static]

- **Settings.** The shell is started with `stty -F /dev/ttyGS0 raw -echo` and
  `setsid sh -c 'exec 0</dev/ttyGS0 1>/dev/ttyGS0 2>&1; exec sh'`
  [M-static `stage3a/init.sh:269-270`; stage2a `init.sh:251-252`, same lines].
  - `raw` turns off IXON, IXOFF and OPOST. The capture contains no CR, which is
    consistent with OPOST off.
  - The descriptor is opened without O_NONBLOCK.
- **Writes are split, not dropped.** `do_tty_write` splits each write into
  2,048-byte chunks [M-static `drivers/tty/tty_io.c:996-1000`] and loops until
  the whole count is written.
- **n_tty blocks when the driver is full.** With OPOST off, `n_tty_write` calls
  `tty->ops->write`, advances by the count the driver accepted, and when the
  driver takes nothing it sleeps on `write_wait`. It returns `-EAGAIN` only for a
  non-blocking file [M-static `drivers/tty/n_tty.c:2352`; the relevant loop is
  about 2401-2427].
- **[D] Conclusion:** a blocking writer cannot lose bytes in n_tty.
  - IXON is off, so a stray ^S could only have paused output, and pausing never
    drops bytes.
  - The host sent nothing during the burst: there is no W line between 7,953 and
    29,891 ms.
  - ECHO is off, and ash is not reading the line while the runner is in the
    foreground.

### 1.2 u_serial (gadget): lossless except one error path [M-static]

Source: `drivers/usb/gadget/function/u_serial.c` (fs006 5.10.198).

- **`gs_write` (l.732-746)** does `kfifo_in` and returns the number of bytes it
  accepted. It never discards; n_tty retries the remainder. The FIFO is
  `WRITE_BUF_SIZE` 8,192 bytes (l.81).
- **`gs_start_tx` (l.229-296)** builds each USB request with at most
  `in->maxpacket` bytes and keeps up to `QUEUE_SIZE` = 16 requests in flight
  (l.80, 249-262). It sets `req->zero` when the FIFO is empty after this packet.
  - f_acm declares bulk wMaxPacketSize 512 at high speed and 1,024 at SuperSpeed
    [M-static `f_acm.c:213,220,241,248`].
  - [D] Device-side buffering beyond the host is therefore about
    16 × 1,024 + 8,192 + 2,048 ≈ 26 KB at SuperSpeed. That is more than this
    whole record.
- **[D] Packet alignment.** Every tty chunk is 2,048 bytes and the FIFO is
  drained in maxpacket units. So after the lone LF, every packet in the burst is
  a full 1,024 bytes at SuperSpeed (512 at high speed), except the final tail.
  - The observed numbers fit this exactly: a cap at 1 + 12 × 1,024, and a loss
    of one 1,024-byte unit aligned to it. *[narrowed by FS-R-010 §5: no cap is established; the loss location is [O]]*
- **`gs_write_complete` (l.464-488) is the only device-side loss path.**
  - If a request completes with any status other than 0 or `-ESHUTDOWN`, the
    driver logs `pr_warn("%s: unexpected %s status %d")` and returns the request
    to the pool. **Its data is not resent.**
  - A failed IN request at SuperSpeed would lose exactly 1,024 bytes.
  - `-ESHUTDOWN` (disconnect) is ruled out: the session continued and `fs-done`
    completed at 29,966 ms [M-static `collect.json`].

### 1.3 USB link and xHCI

- Bulk transfers are flow-controlled: the device NAKs or holds packets until the
  host issues IN tokens. A packet that the host fails to acknowledge is retried
  by the hardware.
- [C] Silent loss on the wire is therefore not expected. A packet can still be
  lost after it is acknowledged, if the host software throws away the buffer it
  was received into.

### 1.4 usbser.sys (Windows 11 in-box CDC-ACM driver): the prime suspect [C]

- **The cap is not the size we asked for.** `fs-collect` requests a 4 MB input
  queue: `ReadBufferSize = 4MB` → `SetupComm` [M-static `fs-collect.ps1:239`].
  ~~The observed cap was nevertheless 12,289 bytes in two separate runs.
  [D] The driver therefore keeps its own bounded buffer and ignores or limits
  `dwInQueue`.~~ *[narrowed by FS-R-010 §5: not established; the loss location is [O]]* Two first reads of 12,289 bytes were observed; they
  do not establish a buffer cap or that the 4 MB request was ignored.
- **Field reports describe the same failure.**
  - SEGGER's knowledge base (June 2019) reports that on Windows 10 the CDC-ACM
    driver sometimes loses a whole bulk-IN packet during large IN transfers. The
    packet is seen ACKed on a bus analyser but never delivered to the
    application; Windows 7 is not affected.
  - SEGGER also reports that the read API (ReadFile, overlapped ReadFile,
    ReadFileEx) made no difference. The only workarounds were reading in small
    chunks or adding delays to the transfers.
  - An OSR thread (2025-26) reports whole lost 64- and 512-byte packets with
    usbser.sys, with Wireshark showing the device sent them. There is no
    Microsoft response.
  - Older (pre-Win10) reports put usbser's buffer at about 16 KB, and say the
    driver stops issuing IN requests once it is full.
- [C] None of this is official Microsoft documentation. The Microsoft Learn
  page for Usbser.sys says nothing about buffering.

### 1.5 .NET SerialPort and fs-collect: not a dropping layer [M-static + C]

- `ReadBytes` reads `BytesToRead` bytes with the byte API and copies a short
  read correctly [M-static `fs-collect.ps1:243-250`].
- No `DiscardInBuffer` or `PurgeComm` call exists anywhere in the host scripts
  [M-static grep of `devices/quest3/host/*.ps1`].
- [C] For the byte API, `SerialStream` passes `ReadFile` straight through. The
  `SerialPort` character buffer is used only by the char/string readers.
  `BytesToRead` = `ClearCommError().cbInQue` + 0. ~~So 12,289 was usbser's own
  queue count.~~ *[narrowed by FS-R-010 §5: not established; the loss location is [O]]*

### 1.6 Which drop point fits all the facts best

| candidate | fits loss at the first read's end | fits exactly 1,024 | fits trial (i) clean | verdict |
|---|---|---|---|---|
| n_tty / tty_io | no (blocking, lossless) | no | — | excluded [M-static] |
| u_serial kfifo (`gs_write`) | no (never discards) | no | — | excluded [M-static] |
| u_serial `gs_write_complete` error | only by coincidence, or if host behaviour caused the error | **yes** (one SuperSpeed request) | yes (intermittent) | possible, needs dmesg [O] |
| USB wire | no (hardware retry) | — | — | not expected [C] |
| **usbser.sys, packet dropped while its queue sits at its cap** *[narrowed by FS-R-010 §5: a candidate only; no cap is established]* | **yes**: the boundary *is* the cap [narrowed: "coincides with the first read's end"] | **yes** (one packet) | **yes** (race) | **most consistent** [D]/[C] |
| .NET / fs-collect | no | no | — | excluded [M-static] |

**[D] Most consistent explanation:**
1. The device dumped ~23 KB at once.
2. Windows' usbser.sys queue filled to its cap (1 + 12 packets = 12,289 bytes)
   and sat there for up to one 50 ms poll interval.
   *[narrowed by FS-R-010 §5: the cap is not established, and Windows
   scheduling is not bounded by the poll interval; this whole sequence is a
   hypothesis, the location is [O]]*
3. During that window exactly one further 1,024-byte packet was taken off the
   bus and discarded.
4. After the application drained the queue, the rest arrived intact.

The position of the loss is the strongest argument. A device-side loss would
have to coincide by chance with the host's buffer boundary, which is ~26 KB away
from anything the device can see.

**[O] The root cause is not pinned.** Two cases cannot be told apart offline:
usbser discarding a packet the device sent, and a device request completing with
an error because of something the host did at that moment.

**The single measurement that pins it:**
- Take a host-side USB capture (USBPcap + Wireshark) of a reproduction burst
  (§4.4). If the missing 1,024 bytes appear on the bus as an acknowledged bulk-IN
  transfer, the Windows stack dropped them.
- USBPcap is a download and a driver install, so the PM must decide on it.
- **No-install substitute:** run `dmesg | grep -i 'unexpected'` on the device
  right after the repro burst (read-only, before any reboot). Add a host
  `ClearCommError` lpErrors log (CE_RXOVER/CE_OVERRUN). If dmesg has no
  `gs_write_complete ... unexpected` line, the device-side path is excluded.
- Also record the link speed. `cat /sys/class/udc/*/current_speed` (read-only)
  says whether the unit is one SuperSpeed packet (1,024) or two high-speed
  packets (512).

---

## 2. Is 12,289 meaningful?

- **[D] Yes, as a cap, not as a buffer size + 1.** *[narrowed by FS-R-010 §5: no cap is established; the loss location is [O]]* The
  whole of this section is a hypothesis about a host-side cap; two equal
  first reads do not establish one.
  - It recurs exactly in both trials.
  - It equals 1 (the lone-LF short packet) + 12 full 1,024-byte packets, which
    is also 1 + 6 × 2,048 tty chunks. At high speed it would be 1 + 24 × 512.
- [D] So the driver's limit is reached in whole packets or transfers. Its true
  byte capacity lies somewhere in [12,289, 13,312]. Alternatively the driver
  stops posting reads once fewer than one transfer's worth of space is free.
- [C] Which of these it is depends on usbser internals that are not documented.
- [D] It is not the .NET queue: we asked for 4 MB. It is not a .NET read size
  either: `Read` asked for `BytesToRead`.
- [D] If the first transfer had not been a 1-byte short packet, the count would
  probably have been 12,288. The "+1" is the LF from `fsb1_emit`, not an
  off-by-one in a buffer.

---

## 3. Could the device side be overwriting or interleaving?

- **Pipe / tee.** None on the output path [M-static].
  - The child's stdout goes to fs-supervise's pipe, which is drained into RAM
    files `/run/fsb/2.out` and `2.err`, never to the tty
    [M-static `fs-display.sh:13-16,41`].
  - The record is built in a RAM file and emitted by `printf '\n'; cat REC`
    [M-static `fsb1-enc.sh:97`]: one writer, blocking, with no pipe between
    `cat` and the tty.
  - fs-supervise's own pipe writes retry on EINTR and partial writes
    [M-static `fs-supervise.c:278-279`]. Its integrity was in any case
    confirmed by the STEP fields `dropped=0 overflows=0` inside the record.
- **u_serial overwriting.** No [M-static, §1.2]. kfifo_in never overwrites; it
  accepts less. The only loss path is a failed request, which is a drop, not an
  overwrite.
- **Shell echo interleaving.** No [M-static + D].
  - The tty has `-echo`. Ash line editing echoes only while it reads a line, and
    it was waiting on the foreground runner.
  - The host wrote nothing during the burst.
  - The splice contains no foreign bytes.

---

## 4. Fix design (ranked)

The integrity rules worked: line count and rec_sha256 rejected the record, and
the outcome was INCONCLUSIVE, not wrong [M-static `collect.json` Status
`COLLECTED-REJECTED`]. **This is an availability bug, not an integrity bug.**
The fix must keep FSB1 a single-shot record with the existing rules.

### Rank 1: (a) device-side pacing in `fsb1_emit` (recommended)

- **Change.** Emit the finished record in blocks of about 1 KB with a short
  sleep between blocks. The bytes stay identical: same record, same rec_sha256,
  same lines. Only timing changes. A sketch, to be reviewed, not built here:
  ```sh
  fsb1_emit() { [ -f "$1" ] || return 2; printf '\n'
      awk '{ print; if (NR % 10 == 0) { fflush(); system("usleep 100000") } }' "$1"; }
  ```
  - That is 10 lines (≈ 890 bytes) every 100 ms ≈ 9 KB/s.
  - `awk` is already an applet the encoder uses. `usleep` is in the busybox
    applet table [M-static `build/stage2a/20261009T085209Z-93a1501f0b1fb692/applets.txt:258`].
  - An equivalent `while IFS= read -r` loop works too. Whichever form is chosen,
    byte identity with `cat` must be proven by fixture, not assumed.
- **Why it removes the failure mode** [D]:
  - The worst gap between host reads is about 50 ms poll + ~16 ms Windows timer
    granularity + the Detect re-parse (7 ms observed at 12 KB; it grows with
    the record). That is well under 100 ms.
  - At ≈ 900 bytes per 100 ms, usbser's queue never holds more than about
    2 KB, against a cap of 12 KB. It never reaches the state in which the
    packet vanished. *[narrowed by FS-R-010 §5: no cap is established; the loss location is [O]]* Windows scheduling is also not bounded by the
    poll interval; pacing is an availability mitigation, not a proven cure.
  - This matches SEGGER's only working workaround ("add a delay") [C].
- **Cost.**
  - About 2.6 s for the 23 KB 3a record and about 2.2 s for the 19.4 KB 2a
    record.
  - The emit time scales with record size: ceil(bytes / 890) × 0.1 s. It must be
    added to the runner budget in `devices/quest3/common/DEADLINE.md` and to
    `RunnerWorstSec` for 2a and 3a [M-static `fs-collect.ps1:140-145`].
  - Needs a new image build. The boot is of the same kind as the trials already
    run; no new risk class.
- **Limits.**
  - It only removes the failure mode if the loss needs a full or near-full
    driver queue. That is the most consistent reading [D] but not proven [O].
  - It does not address the device-side error path, should dmesg ever show it.

### Rank 2: (b) host-side changes (worth doing as well; host-only, no boot)

- **A dedicated reader thread or always-pending overlapped read.** Keep a large
  `BaseStream.ReadAsync` / `BeginRead` (e.g. 64 KB) outstanding at all times
  and append completions to the capture.
  - With the .NET timeouts in use (ReadTimeout = 200 → ReadIntervalTimeout =
    MAXDWORD), the read completes as soon as any data arrives.
  - This shortens the time usbser's queue sits full, but **cannot keep it from
    filling** when the device dumps 23 KB within a microsecond-scale burst.
  - SEGGER reports that the read API made no difference [C]. So **this is not a
    fix on its own**.
- **Faster polling (PollMs 5-10).** Same limitation. Windows `Start-Sleep`
  resolution is about 15.6 ms, so 5 ms is not really achievable. The cost is
  CPU time from the O(n) Detect re-parse on every read.
- **`DataReceived` event.** It is raised from the .NET event thread. Same
  limitation as the reader thread, and it adds threading into a PowerShell 5.1
  script. Not recommended.
- **Larger `SetupComm` buffers.** Already 4 MB and evidently not honoured [D].
  No gain.
- **RTS/CTS (`Handshake.RequestToSend`).** No effect on the device.
  - f_acm only stores the control-line bits:
    `acm->port_handshake_bits = w_value;` with a FIXME that data flow is not
    gated [M-static `f_acm.c:379-392`]. u_serial never throttles TX on them.
  - The baud rate is likewise ignored by CDC-ACM.
  - [C] usbser may or may not stop issuing IN requests when it deasserts RTS
    internally. Even if it does, that is the same NAK behaviour that already
    applies at the cap, so it cannot be relied on. *[narrowed by FS-R-010 §5: no cap is established; the loss location is [O]]*
- **Cheap diagnostics to add regardless.** After each read, log
  `ClearCommError` lpErrors and cbInQue through P/Invoke in `fs-native.ps1`,
  and subscribe `ErrorReceived` to log only. This answers the [O] in §1.6 at no
  risk.

### Rank 3: (c) end-to-end protocol change (not recommended now)

- **What it would be.** A chunked transfer with per-chunk acknowledgements and
  retransmission. Example: the device emits block k, the host replies
  `fs-ack-blk k <sha>`, and the device resends on NAK or timeout.
- **Why not now.**
  - It turns the single-shot FSB1 emit into a dialogue. It adds host writes
    during the record (the send gate currently forbids any) and new device verbs.
  - A retransmit means the same bytes appear twice on the wire, so the decoder
    must rule on duplicates. FSB1 currently rejects any second BEGIN
    [M-static `FSB1-SPEC.md:230`].
  - **Needs Chair review.** It is far larger than (a) for the same practical
    effect.
- **When to reconsider.** Only if (a) plus the host reader still shows losses in
  the §4.4 repro.

### 4.4 How to test

**Offline (no device):**
1. **Encoder byte identity.** Add a fixture in `devices/quest3/common/fixtures/fsb1`.
   - For records of 0 bytes, 1 byte, exactly 1,024·k bytes, 23 KB, 64 KB, and
     the complete trial (i) record (rebuilt from the FS-A-009 evidence (private) capture offsets
     540..19,909), check `fsb1_emit_paced REC | cmp - <(printf '\n'; cat REC)`.
   - Also check elapsed ≥ (blocks − 1) × 100 ms, and that no single write
     exceeds 10 lines. strace or a timestamping reader can show this.
2. **Host chunking invariance.** Synthesise a replay index that delivers the
   trial (i) bytes as about 25 R chunks of ≤ 1 KB, 100 ms apart.
   - `Invoke-FsReplay` must give the same Status (`COLLECTED-VALID`), the same
     rec_sha256 and the same phase results.
   - Keep the trial (iii) replay as the negative fixture: it must stay
     REJECTED.
3. **Budget fixture.** Recompute the 2a and 3a runner budgets with the paced emit
   time at the maximum record size that fs-supervise's caps allow.
   `fs-collect` must still refuse a run whose budget is short.

**On-device, without a new risky boot (needs a PM/Chair decision):**
4. **Repro probe on an already-approved image.** Before `fs-done`, the shell can
   run one read-only command that writes only to the tty. It needs no files and
   changes no state. For example:
   ```sh
   awk 'BEGIN { for (i = 0; i < 400; i++) printf "PROBE n=%04d %s\n", i, "<70 fixed chars>" }'
   ```
   - Run it unpaced, then paced (`fflush(); system("usleep 100000")` every 10
     lines). A host harness, not `fs-collect`, records it with the same 50 ms
     polling and checks the n sequence for gaps.
   - Then run `dmesg | grep -i unexpected` and
     `cat /sys/class/udc/*/current_speed` (read-only).
   - Unpaced runs should show loss intermittently at the cap; paced runs must
     show none across many repetitions (e.g. 20). *[narrowed by FS-R-010 §5: no cap is established; the loss location is [O]]* FS-R-010 §5
     requests no unpaced hardware reproduction campaign.
   - Each probe is new shell input, outside `fs-collect`'s fixed verbs, so it
     needs Chair approval. It is listed here as read-only per the headset
     permissions.
5. **Optional, needs no Quest at all.** Any other CDC-ACM device on the same PC
   (e.g. a microcontroller board) running the same burst pattern shows whether
   usbser.sys alone reproduces the loss.

---

## 5. Implications for the Quest 2 NCM/TCP channel

- **[M-static] The channel is NCM + TCP only.** It has no ACM/serial path
  (`devices/quest2/channel/README.md:1,57`; no ACM/ttyGS references in
  `devices/quest2/channel/`). It uses one TCP connection per request/record.
- **[M-static] The device writes with `send_all`.** It polls for POLLOUT, retries
  EAGAIN/EINTR and partial sends, and gives up only at a deadline. It then does
  `shutdown(SHUT_WR)` plus a bounded drain, so the close cannot become an RST
  [`devices/quest2/channel/src/fs-rpcd.c:262-299`].
- **[C] TCP is not exposed to silent mid-stream loss** (standard TCP behaviour).
  - If the Windows NCM driver dropped a USB transfer, that would drop one
    Ethernet frame. TCP's sequence numbers and acknowledgements detect the
    missing segment and retransmit it.
  - The receive window throttles the sender (it blocks in `poll`), so data is
    never discarded when the host is slow.
  - The only failure modes are a stall, a timeout or a reset. All of them are
    visible as an incomplete record, and FSB1's END/line count/rec_sha256 would
    reject one anyway. That also covers the residual risk of TCP's weak 16-bit
    checksum.
- [D] So the Quest 2 channel needs no pacing for this failure mode.
- [C] The Quest 2 per-trial budgets should still allow for TCP retransmission
  delays, which are normally sub-second on a direct link.

---

## Sources (external, all [C])

- SEGGER Knowledge Base, "CDC" (Windows 10 lost IN packets; workarounds: small
  reads or delays): https://kb.segger.com/CDC
- OSR community, "About supposed bug in usbser.sys with CDC devices on some
  microcontrollers":
  https://community.osr.com/t/about-supposed-bug-in-usbser-sys-with-cdc-devices-on-some-microcontrollers/59965
- Arm/Keil forum, "usbser sys quirks explained" (pre-Win10, ~16 KB buffer, stops
  IN requests when full):
  https://community.arm.com/support-forums/f/keil-forum/32273/usbser-sys-quirks-explained
- Microsoft Learn, "USB Serial Driver (Usbser.sys)" (KMDF driver; no buffering
  details):
  https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/usb-driver-installation-based-on-compatible-ids
