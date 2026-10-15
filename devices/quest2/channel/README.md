# Quest 2 stage-1 channel: USB NCM + fixed-verb TCP responder (offline)

**Status:** offline draft, revision 6 (final gate-hardening pass), 2026-10-09. Nothing here has run on a
device. No adb or fastboot was run and nothing was downloaded. The author
makes no commits; the coordinator commits.
- **Revision 1** is commit `e0d364f`.
- **Revision 2** (the answer to the adversarial review of `e0d364f`) is
  commit `a0ab780`.
- **Revision 3** (the answer to the re-review of `a0ab780`) is commit
  `58817ec`.
- **Revision 4** (the answer to the final re-review of `58817ec`) is commit
  `e6e5cf0`.
- **Revision 5** (the answer to the verification pass of `e6e5cf0`) is
  commit `9758eda`.
- **Revision 6** is the final gate-hardening pass: 2 MINOR gate gaps and 1
  nit from the review of `9758eda`, after which gate iteration stops (§11).
  Whether revision 6 is committed yet: see the JOURNAL (the git history is
  not published). This file does not track it.
- **`devices/quest3/` was only read; no tracked file there changed.** One
  side effect: revision 1's fixture import of
  `quest3/common/tools/fsb1.py` (re)wrote the gitignored cache
  `devices/quest3/common/tools/__pycache__/fsb1.cpython-314.pyc`. Same
  Python (3.14.4) and same source, so the bytes are identical to any
  earlier cache. Revision 2 harnesses cannot write bytecode (§5.3).

This answers PORT-PLAN rev 2 §1.3 and Q2-P0 items 3 and 4. It needs its own
review, relay and Chair ruling before any device use.

**Chair ruling (FS-R-011 §4, 2026-10-11, J-104): ACCEPT continued offline
work.** The full implementation and the exact binary (`fs-rpcd`
`da19367be1f2d3c73d7476cb203e3109a0af277758ac552aa72bf81bf3cc8c4c`
[M-static]) were supplied in the consolidated FS-A-011 (sent 2026-10-11,
J-103). The Chair checked the segment layout and the timing checker, and a
native build of the source passed 11 targeted live-TCP checks [D]. The NCM
preparation and Windows adapter-selection design are acceptable for
continued offline assembly. Binding for the eventual candidate:
- **UDC:** use the observed Quest 2 UDC identity **`a600000.dwc3`
  explicitly**; never silently fall back to whichever UDC happens to exist
  (§3.1 note). The current code's `FS_UDC_EXPECT` is optional; the
  candidate must set it (no code changed yet).
- **Trailing-request check:** a bounded quiet window, not proof that the
  peer will never send another byte (§2, §4).
- **Host send failure:** a short `Socket.Send` can transmit a prefix before
  failing. The failure record keeps **"possibly partially sent"**
  ambiguity; `Sent=false` is never proof that nothing reached the device
  (§4 note).
- **FSB1 validation stays necessary** beyond TCP framing: connection
  closure or drain completion is not a substitute for record integrity.
- **No Quest 2 execution is concurred.** The Quest 2's own complete
  candidate, PID 1 deadline, effective firmware inputs, thermal/recovery
  procedure (FS-R-011 §6: no dependable forced shutdown through the generic
  thermal core on the v2.7 config) and timing budget still need review. **Do
  not lengthen the Quest 2 DEADLINE merely to fit this channel's
  preparation estimate** (§4 timing check, §6 item 7).

**Tags:** [M-static] named artifact, [D] derivation, [C] hypothesis, [O] open,
[F] offline fixture result (WSL/qemu/Windows localhost; not a device).

## 1. Layout

| path | role |
|---|---|
| `src/fs-rpcd.c` | the responder (static aarch64, clang r450784e). Same compile flags as `quest3/common` `fs-supervise`; the link adds `-z separate-code` since revision 6 |
| `target/fs-ncm.sh` | busybox-ash library sourced by the Quest 2 PID 1: configfs NCM gadget, IPv6 link-local, responder start |
| `host/fs-transport-tcp.ps1` | Windows PowerShell 5.1 TCP transport, dot-sourced by a future Quest 2 collector |
| `host/test-transport-tcp.ps1` | host fixtures (sections A–H) |
| `tools/build.sh` | builds `build/fs-rpcd`, checks it, writes `build/BUILD.txt`. Fixture-only builds: `fs-rpcd.asan` (ASan/UBSan), `fs-rpcd.native` + `shim-nowait.so` |
| `tools/undef-gate.sh`, `tools/fs-rpcd.undef.allow`, `tools/src-gate.sh` | the object gate (allowlist, pin, execve relocation count, no svc), the reviewed allowlist, the textual source gate (revision 4) |
| `tools/check-timing.py` | revision 4: the Quest 2 timing check (parametric DEADLINE; the `-T` cap); `fixtures/timing/` |
| `tools/obj-scan.py` | the fail-closed raw scan of fs-rpcd.o (structure; svc/hvc/smc encodings; `$d` in code; relocations into `.text`), called by `undef-gate.sh` |
| `tools/seg-check.py` | revision 6: the linked binary's executable pages hold only code sections |
| `tools/elf-mutate.py` | revision 6, fixtures only: crafts the malformed objects m1–m11 from a temp copy |
| `tools/fixtures-build.sh` | revision 3: crafted temp-copy variants (`syscall(SYS_execve)`, `system`, `popen`, `execvp`, `posix_spawn`, `dlopen`) must be rejected; writes `fixtures/buildgate/RESULTS.txt` |
| `tools/fixtures-device.sh` | device fixtures (sections D, G, L, I) |
| `tools/device_cases.py`, `rpc.py`, `evil_device.py`, `sim-pid1.sh`, `host-fixture-wsl.sh`, `shim_nowait.c` | fixture helpers. Python is stdlib only, run with `-I -B` |
| `fixtures/device/*.txt`, `fixtures/host/RESULTS.txt`, `fixtures/buildgate/RESULTS.txt` | results |
| `build/fs-rpcd`, `build/BUILD.txt`, `build/fs-rpcd.undef` | the repo `.gitignore` ignores `build/`, so commit these with `git add -f`, as `quest3/common/build` was. The x86_64 builds are never shipped |

Run: `wsl.exe -e bash …/tools/build.sh`, `wsl.exe -e bash …/tools/fixtures-device.sh`,
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File …\host\test-transport-tcp.ps1`.

## 2. Wire protocol

One TCP connection = one request line = one record, then the device closes.

| request (exact) | record |
|---|---|
| `fs-verify <n16> <c32>` | `FSV1 nonce=<n16> resp=sha256("<n16>:<c32>") kernel=… pid1=… stages=… END` |
| `fs-ack <n16> <t16>` | `FSA1 queued END` (writes `/run/host_ack`; first ack per boot only) |
| `fs-status <n16>` | `FSS1 nonce=<n16> stages=… acked=<token\|none\|invalid> END` |
| `fs-done <n16>` | `FSD1 queued END` / `FSD1 error=write END` (writes `/run/fs.collected`) |
| `fs-collect <n16> <c32>` | the fixed runner's stdout (an FSB1 record), byte for byte; only with `-c`; once per boot |
| anything else | `FSR1 nonce=<n16> error=<code> END` |

**Grammar.** `^[a-z0-9 -]{1,64}\n`, single spaces only. The charset check
runs over the **raw bytes** before any string use.
- A further byte in the **same segment** is refused as `trailing`.
- So is one arriving within **75 ms** after the newline (revision 2).
- EOF in that window (a half-close) is accepted.
- Bytes arriving later are drained and ignored, never parsed (§3.3).

**Refusal codes** (fixed table): `grammar too-long trailing timeout empty
no-newline verb args nonce replay ack-already collect-already no-runner
seen-full write runner runner-exit runner-output runner-timeout
runner-too-large runner-killed runner-unreaped`.
- `runner-killed` (revision 3): the runner had not exited 2 s after its
  stdout closed, and was SIGKILLed and reaped.
- `runner-unreaped`: even after SIGKILL it could not be reaped within
  2 s.

The host treats every `FSR1`, these included, as INCONCLUSIVE.

**Record formats versus the Quest 3 helpers:**
- **Same:** the tags, keys, order and `END`.
- **Different** (fs-rpcd is not a shell), in the FSV1 `kernel`/`pid1`/`stages`
  and FSS1 `stages` fields:
  - every byte outside 0x21–0x7e becomes `?`, **and so does `+`**
    (revision 4);
  - `+` is reserved as the **truncation marker**: a field longer than 200
    bytes is cut to 199 bytes plus `+`, so a trailing `+` means "cut";
  - a file longer than fs-rpcd reads (4096 bytes) is marked the same way;
  - trailing commas are stripped;
  - an empty field is printed as `-`. A field that was cut and is empty
    after stripping is printed as **`-+`**, so it is still marked
    (revision 5, N-a; fixtures V19, V20, E9).
- **The `+` → `?` rule applies to every field, the kernel release
  included** (revision 5, N-b).
  - A release string that contains `+` (e.g. a `-dirty+` local build)
    would therefore not match an exact `-Kernel` comparison on the host.
  - The stock v2.7 release, `4.19.325-cip128-st12-g49638c7a8637`, has no
    `+`.
- **The host refuses a truncated `stages` field** (FSV1 and FSS1): a cut
  list could have lost an `ERROR_` entry. Revision 4, final re-review R1;
  fixtures V11–V17, E7, F22.
- FSS1 `acked` is the token from `fs.acked` only if it is 1–64 lowercase
  hex on one line. A missing file gives `none`, anything else `invalid`.
- FSB1 is passed through unchanged, including the encoder's leading empty
  line.

**Changes from PORT-PLAN §1.3** [D]:
1. Verbs are the lowercase Quest 3 names (the collector grammar is
   `[a-z0-9 -]`).
2. **Every request carries the nonce**, so a stale image or another unit
   refuses (`error=nonce`).
3. `FSR1` carries the device nonce, which the host checks.
4. `fs-collect` takes a fresh challenge (FSB1 binds `chal`), not a step id.
5. **`fs-done` is accepted in every stage**, stage 1 included.
   - It only writes `fs.collected`, which can only shorten PID 1's hold
     (`pid1-hold.sh`).
   - The host sends it only after a verified FSV1 (send gate).
   - Accepting it in stage 1 gives an immediate, verified recovery instead
     of waiting for the deadline.
   - Gating it on `-c` would remove that, and gain nothing a forged
     request could not already get by waiting.
6. **No respawn loop:** one `fs-rpcd` per boot, which exits after 64
   connections.
   - A respawned responder would be a new process the host cannot tell
     apart, and its in-memory replay table would be empty.
   - If the responder dies, the host gets refused connections
     (INCONCLUSIVE) and PID 1's deadline recovers (fixture I4).
   - The persistent rules survive a restart anyway: ack-once (`host_ack` or
     `fs.acked`) and collect-once (`fs.collect-started`).
7. **Addressing:**
   - the plan's option A relied on the kernel's EUI-64 address from a
     nonce-derived `dev_addr`;
   - this package (since revision 1) uses the **nonce itself as the interface id**
     (`fe80::<nonce>`), with `addr_gen_mode=1` (no kernel address), a manual
     `ip -6 addr add`, and DAD off (`accept_dad=0`, `dad_transmits=0`;
     busybox `ip` has no `nodad`);
   - the address is then exact and needs no EUI-64 bit flip (§3.2).
8. No `udhcpd` and no busybox `nc` (§3.2, §3.3).

## 3. Device side

### 3.1 Gadget (`fs_ncm_udc`, `fs_ncm_gadget`, `fs_ncm_role`)

- **UDC found at runtime:** wait ≤ 10 s; exactly one entry in
  `/sys/class/udc`; name in `[A-Za-z0-9._-]`; optional `FS_UDC_EXPECT`
  (v59: `a600000.dwc3`; v2.7 [O] until Q2-P1). *(FS-R-011 §4, J-104: the
  eventual candidate sets `FS_UDC_EXPECT=a600000.dwc3` explicitly and never
  falls back to whichever UDC exists; v2.7 Android reads the same name,
  note at the end.)*
- **Identity:** `0x1d6b/0x0104`, class `ef/02/01` (IAD; `f_ncm.c:148-155`),
  serial **`FS-<nonce>`**, function `ncm.fs`.
- **MACs from the nonce:** `dev_addr` `02:<n0..n9>`, `host_addr`
  `06:<n0..n9>` (locally administered, distinct).
- **Every configfs write is read back with an exact comparison**, failing
  through `fail()`. Revision 2 adds the manufacturer, product and
  configuration strings and the function link (`-L` and `-d`).
- The interface is `functions/ncm.fs/ifname` **and** must be the netdev
  carrying `dev_addr`.
- `default` IPv6 sysctls are set (and read back) before the bind, so the new
  netdev never generates an EUI-64 address or runs DAD.
- **Role:** `dr_mode=drd` should follow VBUS [D].
  - `mode=peripheral` is written only if the UDC is still `not attached`
    after 5 s. This is a **best-effort, not enforced** fallback: the write's
    return code and readback are logged, and a failure does not `fail()`.
  - Without device mode there is no link: the host refuses or ends
    INCONCLUSIVE, and PID 1's deadline recovers. VBUS may still attach
    later.
- Numeric settings (`FS_UDC_WAIT`, `FS_ROLE_WAIT`, `FS_RPC_WAIT`,
  `FS_RPC_PORT`) are validated as decimals before use.

### 3.2 Addressing: IPv6 link-local, no DHCP (decision)

**Device address = `fe80::<n0-3>:<n4-7>:<n8-11>:<n12-15>/64`.** The
64-bit nonce *is* the interface identifier.

**Why IPv6 link-local** [D]:
- no daemon on the device: no `udhcpd` parsing host packets;
- no host configuration: Windows gives an IPv6-bound adapter its own
  `fe80::`, and the host connects to `fe80::<nonce>%<ifIndex>`;
- the address is a pure function of the nonce.

**Bring-up** (`fs_ncm_net`), each sysctl read back:
1. `disable_ipv6=0`, `addr_gen_mode=1`, `accept_dad=0`, `dad_transmits=0`,
   `accept_ra=0`, `autoconf=0`, `router_solicitations=0`.
   - `all/accept_dad` is checked to be 0: 4.19 skips DAD only if both are
     below 1 (`addrconf.c:3969`).
2. Link up, then `ip -6 addr add`. The reviewed busybox `ip` has **no
   `nodad`** [F], hence the sysctls.
3. Wait (≤ 10 s) until `/proc/net/if_inet6` shows **exactly one** address
   on the interface: ours, prefix 64, scope link, flags `80` (permanent,
   not tentative). A second, kernel-generated address is refused (L6).

**IPv4 is not configured.** Fallback, if Windows IPv6 binding fails in
practice: a fixed `169.254.x.y/16` from the nonce plus Windows APIPA,
still without DHCP. `fs-rpcd` supports IPv4 (localhost fixtures); APIPA
timing is [O].

### 3.3 Responder: a static C binary, not busybox `nc -e` (decision)

The reviewed busybox `nc` was measured under qemu [F]
(`nc -l -p P -e prog`, small `nc.c` build):
- it binds the **wildcard `*:P`**, with no bind-address option;
- `-w` is a **connect** timeout only;
- one exec per connection, with a closed port between respawns. A
  concurrent client was **reset**;
- unread input at close makes an **RST**;
- `-ll` forks without bound.

`fs-rpcd` (bounds compile-time; `build.sh` checks they are unchanged):
- **Bind:** only the given address.
  - Revision 2 refuses `::`, `0.0.0.0`, multicast, broadcast and
    v4-mapped addresses.
  - A link-local address needs `-i` (scope id from `if_nametoindex`).
  - `IPV6_V6ONLY`, backlog 1. `EADDRNOTAVAIL` is retried for ≤ 10 s.
- **Process state (revision 2):** at start, every signal disposition is
  reset to default, the mask is emptied, the working directory is `/`, and
  then SIGPIPE is ignored.
  - The runner child resets every disposition to default again, empties its
    mask and sets `umask 077` before `execve`.
  - Fixtures SIG1/SIG2 run with a parent that ignored SIGCHLD, SIGPIPE and
    SIGTERM, blocked SIGUSR1 and SIGALRM, and set umask 0.
- **Per connection, one at a time:**
  - ≤ 3 s **total** from accept to the newline;
  - ≤ 64 characters;
  - `trailing` as in §2: the same segment, or within 75 ms. Later bytes are
    drained, not parsed (T1, T2);
  - response write ≤ 30 s;
  - FIN plus a ≤ 300 ms / 64 KiB drain, so the close is not an RST.
  - The host's 100 ms quiet period runs *before* it writes and the device's
    75 ms window *after* it reads, so the two cannot interact.
- **Lifetime:** ≤ 64 connections, then it exits.
- **No shell from fs-rpcd's code.**
  - Source: one `execve` (the `-c` runner path) and no
    `system`/`popen`/`posix_spawn`/other `exec*`.
  - Object: `llvm-nm -u` of `fs-rpcd.o` lists `execve` and no shell-capable
    libc function (`build/fs-rpcd.undef`).
  - **The binary does contain the string `/bin/sh`.** Static glibc links
    `popen`/`posix_spawn`/`execvpe` through libio. Revision 1's claim of
    "no shell string" was wrong: its gate could never fire (review M1).
    Nothing is claimed about unreachable glibc internals.
- **The runner** (`fs-collect` only):
  - argv only (`runner <c32>`), environment `PATH=/bin:/sbin`, stdin and
    stderr on `/dev/null`, its own process group;
  - stdout captured in memory, ≤ 8 MiB (exactly 8 MiB is accepted, one more
    byte is `runner-too-large`), within ≤ `-T` s;
  - **`-T` ≤ 104 s** (revision 4, R3; was 240). 104 s is the largest T any
    DEADLINE ≤ 299 can serve (the PID 1 clamp), computed by
    `tools/check-timing.py` from the sources (§4); `build.sh` runs that
    check;
  - sent only if the runner exited 0 and the output is printable ASCII + LF
    ending in LF; otherwise an `FSR1`. Partial output is never sent.
- **Reap: `fs-rpcd` never blocks in `waitpid`** (revision 2, review M2;
  revision 3 codes).
  1. After the runner's stdout closes, poll `WNOHANG` for ≤ 2 s. Reaped:
     normal result.
  2. Otherwise SIGKILL its group and the runner, and poll for ≤ 2 s more.
     Reaped now: `runner-killed` (X3).
  3. Still not reaped: give up and refuse with `runner-unreaped` (X5).
     - A runner in uninterruptible sleep (D state) is then an **unreaped
       child**: not exited, so not even a zombie yet.
     - It runs no more user code once it leaves D state with SIGKILL
       pending.
- **Strays, revision 3 (re-review m11):** `fs-rpcd` makes itself a **child
  subreaper** (`prctl(PR_SET_CHILD_SUBREAPER)`) at start.
  - After every collect it first SIGKILLs the runner's process group.
  - It then sweeps `/proc` for live processes whose parent is `fs-rpcd`. It
    covers **the runner's descendants that become orphans within the 2 s
    sweep window**, including ones that called `setsid` or double-forked.
    It SIGKILLs and reaps them (WNOHANG only), repeating while new orphans
    appear, for at most 2 s (revision 4 wording, R4).
  - The count is logged (`FSRPC swept=N orphans`).
  - **Covered:** strays in the runner's group (X4), a `setsid` stray (X6),
    and a double-forked `setsid` stray (X7).
  - **Not covered:**
    - a process the kernel will not kill (D state);
    - a descendant that is not yet orphaned when the sweep ends, i.e. whose
      parent is itself unkillable;
    - anything that is not a descendant of the runner.
  - A stray that keeps stdout open after the runner exits 0 holds the pipe
    open. That case ends as `runner-timeout` at `-T`, not as success, and
    the stray is killed (X4).
- **State:**
  - challenges are remembered for the process lifetime (replay →
    `replay`). The table lives in memory, but there is no respawn (§2
    item 6);
  - ack-once: refused if `host_ack` or `fs.acked` exists;
  - collect-once: `RUNDIR/fs.collect-started`, created O_EXCL **before** the
    fork, so a restarted responder refuses too (K1, K2).
- **Files:**
  - writes only `RUNDIR/{host_ack,fs.collected}` (O_EXCL temp file plus
    rename) and the `fs.collect-started` marker;
  - appends `fs.rpc.log` (regular file only);
  - reads regular files only (`O_NOFOLLOW|O_NONBLOCK`, `fstat`).
- **The log** holds table strings and numbers only (V9, M32).
- `build/fs-rpcd`: static aarch64, ELF minimum kernel 3.7.0, bit-identical
  rebuild checked (`BUILD.txt`).

### 3.4 PID 1 integration

Sketch for the Quest 2 init (not written here; Q2-P0 item 2):

```sh
. /lib/fs/pid1-hold.sh; . /lib/fs/fs-ncm.sh
fs_hold_init "$DEADLINE" "$ACK_WINDOW"; fs_start_backstop      # first (common/DEADLINE.md)
…governor, mounts…
fs_ncm_ids; fs_ncm_udc; fs_ncm_gadget; fs_ncm_role; fs_ncm_net  # fail() before RPC_READY
fs_rpc_start                                                    # child; waits for its "listening" line
stage RPC_READY; fs_hold_loop                                   # unchanged semantics
```

- **`fs_rpc_start` (revision 2, review m7):** `RPC_READY` is recorded only
  after:
  - the responder's own `FSRPC listening port=<port>` line appears in
    `fs.rpc.log` (≤ `FS_RPC_WAIT`, 12 s, which covers the 10 s bind retry);
  - **and** its PID is still alive.
  - It refuses a stale log line, and it `fail()`s if the responder exits
    first (G18–G22).
  - **Revision 3 (re-review N1):** every failure inside `fs_rpc_start` first
    SIGKILLs the responder and reaps it (bounded: `wait` only once `/proc`
    shows it gone or a zombie), and only then calls `fail()`.
    - The responder can therefore never come up during `fail()`'s ERR_DELAY
      and verify, ack or collect after the boot was declared failed.
    - "Alive" is read from `/proc/<pid>/stat`, because `kill -0` also
      succeeds on a zombie.
    - Fixtures G19, G20 and G23. G23's responder only starts listening after
      the 2 s wait: it is dead, and never listened, during the emulated
      ERR_DELAY.
  - **Host side:** `fail()` appends `ERROR_<stage>` to `fs.stages` (as every
    Quest 3 init does).
    - `Test-FsTcpVerify` refuses an FSV1 whose `stages` carry any
      `ERROR_*`, so nothing is acked or collected (E5, F20).
    - With `-ReadyStage RPC_READY` (the Quest 2 init's ready stage) it also
      requires that stage (E6).
    - Quest 3 itself never needed the ERROR_ check: its shell only exists
      after the last `fail()` point. Quest 2 adds it because a responder
      survives the boot's own failure path only if N1's kill fails.
- The responder only writes `host_ack` (recorded by PID 1) and
  `fs.collected` (only shortens the hold).
- Fixtures I1–I5 [F]: the real `pid1-hold.sh` and real `fs-rpcd` under
  qemu, with a fake reboot syscall.
- **Residual:** `&` forks from PID 1 (as the Quest 3 shell loop); a fork
  failure there is the known S5 class.

## 4. Host transport (`host/fs-transport-tcp.ps1`)

**API:**
- `Find-FsNcmAdapter`, `New-FsTcpTransport`, `Get-FsTcpHostDeadlines`,
  `Set-FsTcpDeadlines`, `Get-FsTcpStartRefusal`, `Get-FsTcpSendGate`,
  `Get-FsTcpTimeGate`, `Invoke-FsTcpRequest`, `Confirm-FsTcpRecord`,
  `Close-FsTcpTransport`;
- for the collector: `Test-FsTcpVerify`, `Get-FsTcpAckState`.

*FS-R-011 §4 (J-104): if `$sock.Send` fails or is short, the request may
have been partly transmitted. The failure record must say "possibly
partially sent"; `Sent=false` must never be read as proof that nothing
reached the device. A COLLECTED result still requires `Test-Fsb1Record`;
TCP closure or drain is not record integrity.*

`Invoke-RefFlow` (test file) is the per-verb collector loop.
- **Revision 2 (review m10):** a collect is `COLLECTED` only if the record is
  FSB1 **and** `Test-Fsb1Record` accepts it.
- An FSR1, or a rejected FSB1, is INCONCLUSIVE, followed by the gated
  fs-done (D5).

| D1-class rule (COLLECTOR.md) | here | fixtures |
|---|---|---|
| fixed verbs + host hex tokens | `New-FsTcpCommand`; nonce + token regexes; final `^[a-z0-9 -]{1,64}\z` | B1–B3 |
| one write site | one `$sock.Send($reqBytes)`; `$reqBytes`, `$cmd` assigned once; no streams; source scan + 4 mutations | B4, B5 |
| send gate | before every connection:<br>• not stopped;<br>• the previous record framed **and** confirmed;<br>• fs-verify first, then only after a verified FSV1;<br>• give-up and ack-window give-up (fs-done exempt from the ack window only);<br>• **revision 2:** the start refusal (≥ 60 s / ≥ 30 s; live mode cannot lower them) until the first request is sent;<br>• **revision 3:** fs-collect only with `RunnerLimitSec` set (the image's `-T`), `MinRemainMs ≥ RunnerWorstMs` and `TimeoutMs ≥ RunnerTimeoutMs` (below);<br>• nothing received during a 100 ms quiet period after connecting.<br>**Revision 2 (m8):** the time part is evaluated **again immediately before the write**; on failure the socket is aborted (RST), nothing is sent, and the transport stops | H1–H7, C5–C12, F6, F14, F18, E2 |
| INCONCLUSIVE on any unverified state | any timeout, reset, cap, missing LF, CR, extra line, trailing bytes, wrong tag or wrong record nonce stops the transport for good | F1–F13, E1 |
| raw capture | `capture.raw` (SHA-256 while writing, re-checked from disk), `responses/<seq>-<verb>.raw`, index `FSIDX2` (`C/W/R/E/N`) | G1–G4 |
| device text inert | `ConvertTo-FsTcpPrintable` (`\xNN`, `\\`) | B6, F9 |
| timing from BootStartUtc | absolute UTC deadlines, converted once (revision 2: a second `Set-FsTcpDeadlines` is refused) after preparation, transport clock first. Every connect and read is capped by the give-up; fs-verify/ack/status also by the ack-window give-up | C1–C10 |

**Runner guard (revision 3, re-review m9).** From the device's own bounds
in `fs-rpcd.c` (fixture B7 checks the transport's copies against the
`#define`s):

| component | bound |
|---|---|
| request read + trailing window | `REQ_MS` 3 s + `TRAIL_MS` 75 ms, before the runner starts |
| runner | T (the image's `-T`) |
| reap | `REAP_MS` 2 s + `REAP_KILL_MS` 2 s |
| orphan sweep | `SWEEP_MS` 2 s, before the record is sent |
| record write | `WRITE_MS` 30 s, fs-rpcd's own bound for up to 8 MiB |

- **`RunnerTimeoutMs`** = T + 39.075 s: the read timeout an fs-collect must
  allow, so a valid record is never cut off by the host.
- **`RunnerWorstMs`** = `RunnerTimeoutMs` + 5 s margin (the Quest 3
  collector's `RunnerMarginSec`): what must be left before the host
  give-up.
- **Refused:** an fs-collect with no `RunnerLimitSec`, a smaller
  `MinRemainMs` or a smaller `TimeoutMs`; `RunnerLimitSec` > 104 (the
  `-T` cap) (C11,
  C13–C19).

**Timing check (revision 4, final re-review R3): `tools/check-timing.py`.**
Modelled on Quest 3's `check-timing.py`, which was read and not modified. It
reads every input from the sources and is parametric in the still-open
Quest 2 DEADLINE.

Inputs:
- **boot to `RPC_READY`, worst success path = 37 s.** From `fs-ncm.sh`:
  `FS_UDC_WAIT` 10 + `FS_ROLE_WAIT` 5 + the address wait 10 + `FS_RPC_WAIT`
  12 (1 s per loop iteration; command time is not counted).
- **pre-runner phase, worst = 73 s.** The reference loop is verify + ack +
  3 × (2.5 s settle + status), and one request costs connect 3 s + quiet
  0.1 s + timeout 10 s = 13.1 s. These come from the transport defaults and
  `Invoke-RefFlow`; a real Quest 2 collector must re-run the check with its
  own values.
- **runner worst = T + 44.075 s**, from the `fs-rpcd.c` `#define`s and the
  5 s margin.
- **Planning assumptions (arguments):** BootStartUtc → PID 1 = 20 s (Quest
  3's figure), adapter lookup 5 s, host margin 15 s.

Results:
- Requirement: 20 + 37 + 5 + 73 + T + 44.075 ≤ DEADLINE − 15.
- **T_max = DEADLINE − 194.075 s:** 104 s for DEADLINE 299, 65 s for 260,
  5 s for 200.
- So `-T` is capped at 104 (R3 checks `COLLECT_S_MAX ≤ T_max(299)`).
- The minimum ACK_WINDOW for this pre-runner phase is 150 s.
- Results: `fixtures/timing/RESULTS.txt`, `T104-D299.txt`, and
  `T105-D299-negative.txt` (R4 FAIL).
- Before the change: `fixtures/timing/before-cap240.txt` (R3 FAIL at the old
  cap of 240).

**Adapter binding (revision 2, review m9):**
- **Live mode requires `-Adapter`** (the `Find-FsNcmAdapter` result) and,
  since revision 4, **`-ReadyStage`** (the init's ready stage, `RPC_READY`).
  - `Confirm-FsTcpRecord` itself stops the transport on an FSV1/FSS1 whose
    stages are truncated or carry `ERROR_`, and on a verifying FSV1 without
    the ready stage, whatever the caller concluded (F21–F23, A17–A18).
  - `Get-FsTcpAckState` returns `failed` for an `ERROR_` stage and
    `invalid` for truncated stages (E8).
  - The address is `fe80::<nonce>`, and the ScopeId is **that adapter's
    ifIndex**.
  - A different `-Address`/`-ScopeId`, a refused lookup, or a lookup for
    another nonce is refused (A10–A16).
- **Lookup:** the adapter's PnP instance descends (depth ≤ 3) from exactly
  one `USB\VID_1D6B&PID_0104\FS-<nonce>`, and there must be exactly one such
  adapter, Up, with an IPv6 link-local address.
- **The MAC match** (`06-…`) is evidence only [C].

**No half-close.** Through the WSL NAT localhost relay, a client
`Shutdown(Send)` lost 9 of 10 responses [F]. The transport never
half-closes. The device fixtures now run without half-close by default, as
the real host does; explicit half-close cases are T3–T5.

## 5. Fixture results

### 5.1 Totals (revision 6)

| suite | result |
|---|---|
| D-qemu: `fs-rpcd` (shipped aarch64, qemu-aarch64) | 113/113 |
| D-asan: same cases, native ASan/UBSan build | 113/113 |
| D-native: same cases + X5 (LD_PRELOAD waitpid shim) | 114/114 |
| G: `fs-ncm.sh` against a **fake** configfs/sysfs/procfs tree (plain files and directories; a sim-only `mkdir`/`ln` emulate configfs) | 23/23 |
| L: link-local in user+net namespaces (veth, real kernel IPv6) | 6/6 |
| I: real `pid1-hold.sh` + `fs-rpcd` | 5/5 |
| host A–H (PowerShell 5.1 ↔ WSL over localhost; IPv4 and `::1`) | 98/98 |
| build gate (`fixtures-build.sh`) | 43/43 |
| timing check (`check-timing.py`, DEADLINE 299/260/200) | CONSISTENT; T_max(299) = 104 s |

Exact lines and input hashes: `fixtures/device/RESULTS.txt`,
`D-*.txt`, `G.txt`, `L.txt`, `I.txt`, `fixtures/host/RESULTS.txt`.
Before/after:
- revision 2: `fixtures/device/D-before-e0d364f.txt`;
- revision 3: `fixtures/device/D-before-a0ab780.txt` (the revision-3 device
  cases run against the `a0ab780` source).
- revision 4: `fixtures/device/D-before-58817ec.txt` (V11, V12, V14, V17
  fail on the old source; it also accepted `-T 105`).

### 5.2 Cases

- **Valid flow:** V1–V9; D1; D3 (IPv6); D4 (a real FSB1 over TCP,
  validated by `quest3/common/host/fsb1.ps1`); D5 (an FSR1 collect →
  INCONCLUSIVE + done).
- **Malformed:** M01–M32.
- **Oversize:** O1–O5.
- **Slow-loris:** S1–S5, C3.
- **Trailing and half-close:** T1–T5.
- **Multiple connections:** C1–C4.
- **Reset:** R1, R2, F7, F7b.
- **Wrong nonce:** N1–N3, E1, F10.
- **Replay:** P1–P3, E3/E4, F14, F15.
- **Collect hardening:** K1–K2, X1–X7 (X6/X7: setsid strays), SIG1–SIG2.
- **Runner guard:** C11, C13–C19, B7.
- **Failed boot:** G18–G23, E5–E6, F20.
- **Build gate:** B-* in `fixtures/buildgate/RESULTS.txt`.
- **Revision 4:** field truncation V11–V17, `-T` cap U7/V18/C18, R1 host A17–A18/E7–E8/F21–F23, timing `fixtures/timing/*`.
- **Revision 5:** V19–V20, E9, and buildgate `paste_*`, `pragma` and `section_text_word`.
- **Revision 6:** buildgate B/D/E (data relocations into code), E2/E3, F (instruction relocation on a foreign word), G (trigraph), H (digraph), I (macro from a header), malformed m1–m11, `seg-*`.
- **Bind refusals:** U1–U15.
- **D1 negatives:** F16–F18, B4/B5.

### 5.3 Fixture hygiene

- Every Python call is `python3 -I -B`, and the scripts also export
  `PYTHONDONTWRITEBYTECODE=1`.
  - `-I` implies `-E`, so the variable alone is ignored.
  - `device_cases.py` additionally sets `sys.dont_write_bytecode`.
- Checked after the revision-2 runs: the `quest3` `fsb1` `.pyc` mtime is
  unchanged.

**Defects found by fixtures:**
- **M07** (revision 1): NUL truncation; `D-prefix-M07.txt`.
- **Revision 2:** exactly 8 MiB of runner output was refused as too large;
  fixed, fixture X2.

## 6. Not testable offline / open items

1. Windows `usbncm` binding to the 4.19 `f_ncm` gadget:
   - the IAD, `ef/02/01` and NTB parameters;
   - the adapter description string;
   - IPv6 binding on the PM's PC;
   - whether the adapter MAC is `host_addr` [O].
2. The real UDC name on v2.7 and the dwc3-msm role behaviour (the `mode`
   fallback) [O, Q2-P1].
3. Link-local on the real gadget: carrier timing, neighbour discovery over
   NCM, Windows Firewall or third-party filters [O].
4. 4.19 specifics are derived from source only:
   - the `addr_gen_mode`/`accept_dad` paths;
   - `if_inet6` flags `80` (the fixture kernel is WSL 6.18);
   - static glibc 2.43 on 4.19: an ENOSYS run for `clone3`/`close_range`
     is still to do.
5. **A real D-state runner cannot be made offline**, nor a D-state stray
   for the sweep. X5 simulates the
   kernel's refusal to let the runner be reaped with an LD_PRELOAD
   `waitpid` shim on a native build of the same source. X3 covers a live
   runner that closes stdout.
6. The G section uses fake configfs files: kernel formatting of
   readbacks, the attribute-creation timing and the UDC bind side effects
   are not exercised.
7. Quest 2 `DEADLINE`/`ACK_WINDOW` values ([O], own thermal assessment).
   *FS-R-011 §4: the DEADLINE is set by the Quest 2's own review (thermal,
   recovery, firmware inputs), never lengthened to fit this channel's
   preparation estimate; T_max follows from it.*
8. The Quest 2 collector, `fs-observe` for NCM, `collect.json`, exit codes,
   and the Quest 2 `init.sh`/`build.sh`.
9. Host packets reach the device kernel's IPv6/TCP stack; only the
   responder port listens.

## 7. Revision 2: review findings (adversarial review of `e0d364f`; re-review status added in revision 3)

| # | finding | disposition |
|---|---|---|
| M1 | `build.sh` `strings \| grep -q … && die` under pipefail → 141, never fired; `/bin/sh` is in the binary | **fixed** |
| M2 | blocking `waitpid` after SIGKILL: a D-state runner hangs fs-rpcd | **fixed** (re-review: partial; completed in revision 3, §8) |
| m3 | inherited signal state | **fixed** |
| m4 | a second line in a later segment was drained, not refused | **fixed** |
| m5 | wildcard binds accepted | **fixed** |
| m6 | collect-once and replay only in memory | **fixed** (collect); **reworded** (replay) |
| m7 | `RPC_READY` without checking the responder listens | **fixed** |
| m8 | send gate evaluated before connect + quiet period, not before the write | **fixed** |
| m9 | ScopeId not bound to the adapter; second `Set-FsTcpDeadlines`; start refusal and runner guard optional | **fixed** (re-review: runner guard partial; completed in revision 3, §8) |
| m10 | `Invoke-RefFlow` marked a framed FSR1 as COLLECTED | **fixed** |
| m11 | README overclaims | **fixed** (readbacks), **reworded** (the rest) (re-review: partial; completed in revision 3, §8) |
| m12 | fixture gaps | **fixed** |
| m13 | undisclosed PORT-PLAN departures | **reworded** |

**M1** (`build.sh`):
- Every ELF and strings gate now captures its output first; there are no
  `| grep -q` gates left.
- The exec check is now source plus object (`llvm-nm -u`), with a planted
  self-test proving the gate fires.
- `BUILD.txt` states "`/bin/sh` string present (static glibc
  popen/posix_spawn/execvpe); fs-rpcd's code does not call them".
- The same SIGPIPE class also affected the INTERP/NEEDED gates; fixed too.

**M2** (reap): `WNOHANG` polling only — 2 s, then SIGKILL and 2 s more, then
give up (child left unreaped; revision-2 text said "zombie", corrected in revision 3) with `runner-unreaped`. Code comment and §3.3 match.
Fixtures X3 and X5; before/after against `e0d364f` in
`D-before-e0d364f.txt`.

**m3** (signal state):
- At start: all dispositions default, empty mask, `chdir("/")`, then
  SIGPIPE ignored.
- In the child: all dispositions default, empty mask, `umask(077)`.
- Fixtures SIG1 (the runner's SigBlk/SigIgn/umask) and SIG2 (collect with
  SIGCHLD ignored by the parent).

**m4** (trailing): a 75 ms post-newline window, `MSG_PEEK`; EOF is
accepted. No interaction with the host's quiet period (§3.3). T1, T2.

**m5** (binds): `::`, `0.0.0.0`, multicast, broadcast and v4-mapped
addresses are refused (usage, exit 2). U10–U15.

**m6** (once-per-boot state):
- **Collect:** the O_EXCL marker `fs.collect-started` is created before the
  fork (K1, K2).
- **Replay:** the table stays in memory, disclosed. There is no respawn, so
  its lifetime is the boot's (§2 item 6).

**m7** (`fs_rpc_start`): waits for its own `listening` line, then checks
the PID is alive; stale log lines are refused. G18–G22.

**m8** (send gate): `Get-FsTcpTimeGate` runs again right before `Send`. On
failure it aborts with RST and stops. H7.

**m9** (host binding and timing):
- Live mode requires `-Adapter`; ScopeId is the adapter's ifIndex; live
  start thresholds cannot be lowered (A10–A16).
- One conversion per transport (C10).
- Start refusal enforced by the gate until the first send (C5, C6, C12).
- fs-collect requires `MinRemainMs > 0` (C11).

**m10** (`Invoke-RefFlow`): requires `Tag -eq 'FSB1'` and a valid
`Test-Fsb1Record`; otherwise INCONCLUSIVE, then the gated fs-done. D5.

**m11** (README):
- **Fixed:** the configfs strings and the link are now read back and
  `fail()` (G16).
- **Reworded:** the role fallback ("best effort, not enforced"); the status
  line (commit `e0d364f`, the `__pycache__` rewrite); the record field
  sanitisation (§2).

**m12** (fixture gaps):
- X1 (> 8 MiB), X2 (exactly 8 MiB), X3, X5 (unreaped), X4 (a stray →
  runner-timeout, stray killed; documented);
- the D suite now runs **without half-close by default**;
- the README notes that G uses fake configfs.

**m13** (PORT-PLAN departures): `fs-done` in every stage (kept, justified),
no respawn (justified), and the addressing change are listed in §2.

## 8. Revision 3: re-review of `a0ab780` (9 of 13 closed; 2 new MINOR; 4 partial)

| # | finding | disposition |
|---|---|---|
| N1 | a failed `fs_rpc_start` left `fs-rpcd` running during `fail()`'s ERR_DELAY | **fixed** |
| N2 | the object gate missed `syscall(SYS_execve, …)` | **fixed** |
| M2 residual | a runner killed and reaped in phase 2 was reported `runner-unreaped`; "zombie" wording | **fixed** |
| m9 residual | runner guard only `MinRemainMs > 0` | **fixed** |
| m11 residual: status line | the status line called revision 2 uncommitted | **fixed** |
| m11 residual: setsid strays | strays that called `setsid` escaped the group kill | **fixed** |

**N1** (failed `fs_rpc_start`):
- Every failure inside `fs_rpc_start` SIGKILLs the responder and reaps it
  (bounded) before `fail()`. "Alive" comes from `/proc`.
- Host: `Test-FsTcpVerify` refuses `ERROR_*` stages and, when given, requires
  the ready stage.
- Fixtures: G19/G20 now assert the responder is dead and was stopped before
  the FAIL line; G23 (late listener); E5, E6; F20 (no ack after a failed-boot
  FSV1, one connection only).

**N2** (object gate): it is now an **allowlist**
(`tools/fs-rpcd.undef.allow`, checked by `tools/undef-gate.sh`); any other
external symbol fails the build. The gate also refuses an allowlist that
names `syscall`, `system`, `popen`, `posix_spawn*`, other `exec*`,
`ptrace`, `dlopen` or `dlsym`. `fixtures-build.sh` compiles crafted variants
from a temp copy of the source, never editing it:
- `syscall(SYS_execve)`, `syscall(SYS_getpid)`, `system`, `popen`,
  `execvp`, `posix_spawn`, `dlopen` are all rejected;
- the real source passes.

**M2 residual** (reap codes):
- Phase-2 reap now gives `runner-killed`; `runner-unreaped` only for the
  give-up.
- §3.3 now says unreaped child, not zombie.
- X3 expects `runner-killed`; X5 `runner-unreaped`.
- Host handling: every FSR1 is INCONCLUSIVE.

**m9 residual** (runner guard):
- `RunnerLimitSec` (the image's `-T`) gives `RunnerTimeoutMs` (T + 39.075 s)
  and `RunnerWorstMs` (+5 s), with the numbers justified in §4.
- fs-collect needs both. B7 checks the constants against `fs-rpcd.c`.
- Fixtures C11, C13–C19.

**m11 residual, status line:** it now says which revisions are commits and
does not claim a commit state for the working tree.

**m11 residual, setsid strays:** **the code fix** (preferred): the child
subreaper plus a bounded `/proc` sweep. X6 (setsid) and X7 (double fork
plus setsid) show the stray dead and the sweep logged; limits are listed
in §3.3.

## 9. Revision 4: final re-review of `58817ec` (all closed; 4 MINOR)

| # | finding | disposition |
|---|---|---|
| R1 | the ERROR_ refusal could be defeated by truncation, and `-ReadyStage` was optional | **fixed** |
| R2 | the build gates could be bypassed by source edits | **fixed** |
| R3 | `-T` up to 240 s could never be used | **fixed** |
| R4 | §3.3 sweep wording | **reworded** |

**R1** (truncation and the ready stage):
- `fs-rpcd` turns `+` in data into `?` and marks a cut field with a trailing
  `+`, including a file longer than it reads.
- The host refuses truncated stages in FSV1 and FSS1.
- `-ReadyStage` is mandatory in live mode.
- `Confirm-FsTcpRecord` enforces both whatever the caller decides.
- `Get-FsTcpAckState` returns `failed` (ERROR_) or `invalid` (truncated).
- Fixtures V11–V18, E7, E8, F21–F23, A17, A18.

**R2** (build gates):
- `tools/src-gate.sh` refuses `asm`/`__asm`/`__asm__`/`svc`/`hvc`/`smc`
  tokens and calls of `execveat`/`vfork`/`clone`/`clone3`/`__clone`/
  `syscall` and the shell family. It requires exactly one `execve(`.
- `tools/undef-gate.sh` checks:
  - the allowlist sha256 against the pin in `build.sh`;
  - the allowlist for forbidden entries, now including
    `execveat|vfork|clone|clone3|__clone`;
  - exactly one relocation naming `execve`, and it must be `CALL26`/`JUMP26`.
    This limits execve **call sites** to one. It does not constrain the
    arguments or how often that site runs; the arguments are covered by
    source review (revision 5, V2).
    A pointer take adds `ADR_PREL_PG_HI21` + `ADD_ABS_LO12_NC` and fails;
  - no `svc`/`hvc`/`smc` instruction in the object.
- `BUILD.txt` states exactly that: textual checks plus symbol, relocation
  and instruction checks on fs-rpcd's own object, as defence in depth on top
  of source review, and not a proof about libc.
- Buildgate fixtures:
  - inline `svc` (both gates);
  - `execve` function pointer (relocation gate);
  - a second `execve` call (both gates);
  - `vfork` (both gates);
  - an edited allowlist with an unchanged pin (refused);
  - an allowlist naming a forbidden entry (refused);
  - the earlier variants.

**R3** (`-T` cap): `tools/check-timing.py` (§4) derives T_max(DEADLINE) from
the sources; T_max(299) = 104 s.
- `COLLECT_S_MAX` is lowered from 240 to 104, and the transport's
  `RunnerLimitSec` cap follows it (fixture B7).
- `build.sh` fails if the cap ever exceeds T_max(299).
- The check is parametric for the open Quest 2 DEADLINE (`--deadline`,
  `--runner-t`, `--ack-window`).
- Fixtures U7 (105 refused), V18 (104 accepted), C18, and `fixtures/timing/*`.

**R4** (§3.3 wording): the sweep is now described as covering descendants
that become orphans within the 2 s window, consistent with the
"Not covered" list.

## 10. Revision 5: verification pass of `e6e5cf0` (R1, R3, R4 closed; ready for the Chair)

| # | finding | disposition |
|---|---|---|
| V1 (MINOR) | a token-pasted `__asm__` emitting `.word`/`.byte` data put a raw svc into `.text`, past both gates | **fixed** |
| V2 (wording) | the relocation check's scope | **reworded** |
| N-a (nit) | a cut field that is empty after stripping was unmarked | **fixed** |
| N-b (nit) | the `+` rule and the kernel release | **reworded** |

**V1** (raw svc in `.text`):
- **(a) Object gate.** New `tools/obj-scan.py` (stdlib ELF parser, called by
  `undef-gate.sh`) reads every code section of `fs-rpcd.o` as raw
  little-endian words.
  - **Code section** means SHF_EXECINSTR, **or named
    `.text`/`.text.*`/`.init`/`.fini`**.
    - A second finding during this pass: a constant with
      `__attribute__((section(".text")))` lands in a *non-executable* input
      section named `.text`. lld merges it by name into the executable
      `.text` of the binary; I verified that by linking a temp copy.
    - Such a code-named non-executable section is also refused outright.
  - **It refuses:**
    - any word with `(w & 0xffe0001f)` in {`0xd4000001`, `0xd4000002`,
      `0xd4000003`} (svc/hvc/smc, any imm16);
    - any `$d` mapping symbol in a code section;
    - a code section whose size is not a multiple of 4.
  - The real object has one code section, 3221 words, and no `$d` in it.
- **(b) Source gate.** `src-gate.sh` refuses `##` and `_Pragma` anywhere;
  the real source uses neither.
- **Buildgate fixtures** (temp copies only):

  | variant | rejected by |
  |---|---|
  | `paste_word_svc` (`.word 0xd4000001`) | both gates |
  | `paste_byte_svc` (`.byte 0x01,0x00,0x00,0xd4`) | both gates |
  | `paste_word_hvc` | both gates |
  | `paste_inst_smc` (`.inst`) | both gates |
  | `paste_word_svc_imm` (`0xd401ffe1`) | both gates |
  | `pragma` | source gate |
  | `section_text_word` (no asm and no `##`) | object gate alone |

- **`BUILD.txt`** states exactly what each gate checks: the textual tokens,
  symbols, relocations, the disassembly, and the raw code words under the
  default lld section mapping.
  - It is defence in depth on top of source review, not a proof about libc.
  - A custom linker script that maps other section names into code is not
    covered; the build uses lld's default.

**V2** (relocation scope): `BUILD.txt` and §2 now say the relocation check
limits execve **call sites** to one. It does not constrain the arguments or
how often the site runs. The arguments are covered by source review: argv
is { the `-c` runner path, the validated 32-hex challenge } and env is
{ `PATH=/bin:/sbin` }.

**N-a** (empty cut field): `join_field` returns `-+` when the field was cut
and is empty after stripping. Fixture V19 (4096 LFs, then `ERROR_x` →
`-+`), V20 (uncut separators → `-`), host E9 (`-+` refused as truncated).

**N-b** (kernel release): §2 says the `+` → `?` rule applies to every field,
the kernel release included, so a release containing `+` would not match
an exact `-Kernel` compare. The stock v2.7 release has none.

## 11. Revision 6: review of `9758eda` (final gate-hardening pass)

**Framing (also in `BUILD.txt`):**
- These gates are defence in depth against accidental or careless changes.
- A determined source editor with control of the toolchain can defeat any
  static gate.
- Human source review of `src/fs-rpcd.c` therefore remains the control.

Gate iteration stops with this revision.

| # | finding | disposition |
|---|---|---|
| 1 | bypass E: a line splice builds `__asm__`; `.reloc ., R_AARCH64_ABS32, 0xd4000001` over a `nop` (lld writes svc #0 at link time) | **fixed** |
| 2 | `obj-scan.py` failed open on malformed ELF | **fixed** |
| 3 | nit H: about 1.5 KiB of `.rodata` shared the executable page | **fixed** |

**1. Bypass E (relocations into code and preprocessing):**
- **(a) Relocations into `.text` (obj-scan C3).** A relocation into `.text` is
  accepted only on two conditions:
  - its type is an instruction relocation;
  - it sits on a word of that instruction class.
- **The allowlist** is derived from the real object, which uses `CALL26`,
  `ADR_PREL_PG_HI21`, `ADD_ABS_LO12_NC` and `LDST8/32/64/128_ABS_LO12_NC`
  (577 relocations). Added siblings of the same classes: `JUMP26`,
  `ADR_PREL_PG_HI21_NC`, `LDST16_ABS_LO12_NC`, `CONDBR19`, `TSTBR14`.
  - GOT and literal-load types are not needed (static, no GOT) and are not
    allowed.
  - `ABS*`, `PREL*` and every other data relocation into code is refused.
- **Why the opcode check is needed:** an instruction relocation can still
  rewrite immediate bits.
  - ADRP-HI21 writes bits 5–23, so on a crafted word such as `0xd4e00001`
    (not an svc encoding) it could produce `svc #0` at link time.
  - Each allowed type is therefore bound to its instruction class: BL, B,
    ADRP, ADD (immediate), load/store (unsigned immediate), B.cond,
    TBZ/TBNZ. A patched word can then never become an exception-generating
    instruction (fixture F).
- **(b) Source gate.**
  - The token and call checks now also run on `clang -E` output (shipped
    target and flags), restricted by line markers to lines attributed to
    the source file itself, so system headers are not judged.
  - Raw text: a backslash-newline splice outside a preprocessor directive
    is refused, and so are trigraphs and the `%:` digraph.
  - The real source has none of them and passes.
- **Buildgate fixtures** (temp copies only). My brief did not carry the
  reviewer's B/D/E definitions, so I label them by construction:

  | variant | construction | rejected by |
  |---|---|---|
  | B | `##` + `.reloc ABS32` + `nop` | source gate (`##`); object gate (reloc type 258) |
  | D | line splice + `.inst` svc | source gate (splice); object gate (svc) |
  | E | line splice + `.reloc ABS32` + `nop` (the reported bypass) | source gate (splice); object gate (type 258) |
  | E2 | `PREL32` instead | source gate; object gate |
  | E3 | `ABS16` instead | source gate; object gate |
  | F | `ADR_PREL_PG_HI21` on `.inst 0xd4e00001` | source gate; object gate (opcode-class check) |
  | G | trigraph `??/` splice | source gate; the compiler (`-Werror,-Wtrigraphs`) |
  | H | digraph `%:%:` paste | source gate; object gate |
  | I | `#define FS_HIDE __asm__` in a local header | the **preprocessed** check alone (the raw `.c` shows no asm token); object gate |

**2. Fail closed (`obj-scan.py`).**
- **Requires:**
  - ELFCLASS64 / LE / EV_CURRENT / EM_AARCH64 / ET_REL;
  - `e_shentsize` 64, `e_shnum` ≥ 2, the section table inside the file, and
    a valid STRTAB `e_shstrndx`;
  - every section and string inside the file;
  - **exactly one code section, a PROGBITS `.text` with SHF_EXECINSTR and
    size > 0**. The real object has exactly one;
  - one sane SYMTAB;
  - RELA only, entsize 24, linked to the symtab, targeting `.text` or a
    known data section (`.rodata*`, `.data*`, `.eh_frame`, `.init_array`,
    `.fini_array`), with symbol indices in range.
- **Any parse error exits 2** (`undef-gate.sh` fails on any nonzero).
- **Fixtures m1–m11**, crafted by `tools/elf-mutate.py` from a temp copy of
  the real object:
  - m1 `e_shentsize` 0; m2 `e_shnum` 1;
  - m3 `.text` with the exec flag cleared and renamed; m4 `.text` NOBITS;
  - m5 section table past EOF; m6 bad `e_shstrndx`; m7 x86-64;
  - m8 RELA targeting `.bss`; m9 ELFCLASS32; m10 truncated; m11 SHT_REL.
  - Every one exits 2, and `undef-gate.sh` fails.

**3. Nit H (executable pages).**
- The link now uses `-Wl,-z,separate-code` (LLD 14.0.7 supports it). The
  run-to-run rebuild stays bit-identical (checked by `build.sh` and across
  two builds), and the recorded command in `BUILD.txt` is updated.
- The binary grows from 645,816 to 680,968 bytes (page padding).
- New `tools/seg-check.py` (run by `build.sh` on the linked binary) requires
  that the executable PT_LOAD's page span holds only `.text`/`.init`/`.fini`/
  `.iplt` and that no other section or segment shares those pages. It uses
  the segment's 64 KiB `p_align`, the largest AArch64 page size.
- Result: RX segment 0x230000–0x29a0b0, pages hold only code.
- Fixture `seg-default-link-refused`: the old link (no separate-code) fails
  the check, because `.eh_frame`/`.rodata` bytes fall in the executable file
  pages.
- This differs from `quest3/common`'s `fs-supervise` link flags; that build
  is not changed.

**Limits stated in `BUILD.txt`:**
- The gates judge fs-rpcd's own source text, preprocessed text, symbols,
  relocations and raw code bytes under lld's default section mapping.
- Libc is not judged.
- The relocation check limits execve call sites to one, not the arguments
  or how often the site runs.

## Note (2026-10-10, J-75): v2.7 UDC name

The unit is now on v2.7. In Android, `sys.usb.controller` and
`/sys/class/udc` both read `a600000.dwc3` (`../evidence/v27-baseline/`).
The `FS_UDC_EXPECT` comment "v2.7: [O] until Q2-P1" can therefore use
`a600000.dwc3`. Under our own PID 1 it is still to be confirmed on the
first boot. No code changed.
*Update (FS-R-011 §4, J-104): the Chair requires this identity to be used
explicitly in the candidate, with no silent fallback.*
