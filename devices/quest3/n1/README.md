# Quest 3 N1: an NCM USB network link next to the ACM console (offline package)

**Status (2026-10-17): N1 r2, the FS-R-014 §5 delta, built and packaged OFFLINE on `feat/n1-r2`: a bounded
kernel-log check AFTER the transfer (the log step), required and evaluated by the classifier (§3, §6); a fixture
where a WARNING appears only once the transfer has begun (`c-kmsg-post`: never an unqualified PASS); the 23 s
responder budget qualified (§3, §4). Candidate `build\n1\20261018T005854Z-b1ba58d65e7ffa1a` (`82eefa8a…0436`, a
nonce-only-style rebuild on the unchanged K1a kernel; never booted); the r1 candidate `5550b45a…cebd` is withdrawn
(never booted). FS-R-014 §5 withholds execution until this delta is reviewed and Unit 2 K1g has passed; one Unit 2
attempt only. Nothing was booted. No adb, fastboot or COM port was used; no device command was run;
nothing was installed or changed on the PC.** FS-R-013 §5 and §9 accept *preparing* N1 ("a distinct package within
the kernel/USB classes ... Keep ACM continuity, bounded enumeration and no unintended listener") and place it before
R-1's RAM-root transfer. N1 runs on **Unit 2 only**, after **both K1a attempts** and after **K1g on Unit 2** (§1).

Tags: [M] hardware output · [M-static] artifact · [D] derivation · [C] hypothesis · [O] open. Everything here is
[M-static] or [D] (fixtures under qemu-user, bwrap, WSL namespaces, PowerShell on loopback), never [M].

## 1. What N1 is, and its order

N1 boots the **unchanged K1a kernel** (`../k1a/`, same Image, config, gate result, 95 stock modules) by one temporary
`fastboot boot`, with the K1a PID 1 extended by one thing: **an NCM network function next to the ACM console**, carrying
IPv6 link-local only, with **one bounded transfer test** (8 MiB each way, SHA-256 on both sides) as the image's only
listener. It is the link R-1's RAM-root transfer will use (FS-R-013 §9 C3/C12).

The three conditions of FS-R-013 §9 and how the package meets them:

| condition | how (where) |
|---|---|
| **ACM continuity** | ACM is created and linked first (interfaces 0-1, Windows `MI_00`, the same COM-port path as K1a); NCM is linked second and is **never fatal** (`init.sh` 4b/4c): a setup failure before the bind gives ACM-only (`NCM_SKIPPED`); a bind failure with NCM linked drops NCM and retries the bind ACM-only once (`NCM_DROPPED`); a network failure after the bind leaves ACM alone (`NCM_NET_FAILED`); and a one-shot guard (`init.sh` 6b) rebinds ACM-only if a host is attached (UDC state default, powered or addressed) but neither configures the gadget nor acks within 30 s of SHELL_READY, checked again right before acting (`NCM_FALLBACK`; the bind retried once), so a PC that cannot enumerate the composite should then get the console [C: re-enumeration as ACM-only under the same serial is untested on Windows]; "not attached" changes nothing. Fixtures: c-ncm-skip, c-ncm-bind-fail, c-bind-fail, c-ncm-ifname, c-ncm-fallback |
| **bounded enumeration** | device: one bind plus at most one ACM-only retry, no wait loops in PID 1 for the network (DAD off: the address becomes permanent at the first DAD work run, milliseconds), the guard bounded to 30 s (at most 31 one-second iterations); PC: the collector's background client looks for **this attempt's** adapter (descending from `USB\VID_1D6B&PID_0104\FS-<nonce>`) at most 60 s and records every state change (the timeline); its connects and the session itself (every socket call's timeout is capped by the deadline) end at the host give-up (BootStartUtc + 185 s) at the latest, and the collector stops it when the ACM session ends (`host/fs-xfer-n1.ps1`) |
| **no unintended listener** | nothing in the image listens except `/bin/fs-xfer` (`src/fs-xfer.c`), started once by the runner's step 5 under fs-supervise (designed to end within 23 s by its own phase limits, which it tests only while waiting, its other loops bounded by byte counts; hard stops: its alarm at 25 s, fs-supervise TERM at 26 s and KILL at 27 s; its listening socket is closed at the first good accept; one session; a peer must be link-local on the NCM interface); a builder lint (lexical: an obfuscated name is not caught; the scripts are reviewed and pinned) refuses any listening or daemon applet or `eval` in any script and any `fs-xfer` outside the runner's two step lines; the image's fs-xfer has no loopback mode (`-DFSX_FIXTURE` native twin only); the record lists **every** socket table before (step 4) and after (step 6) the transfer; the harness also proves a connect is refused before and after. The PC side opens no listener either (outbound only) |

**Order (enforced by `host/fs-n1-units.ps1`, phase A of the N1 sign-off tooling (private) and `fs-observe-n1.ps1`, before any
device query):**
- **N1 on Unit 2** (`QUEST3UNIT2`) only after **both K1a attempts and K1g on Unit 2** (coordinator decision
  2026-10-16, so that K1g's write guard is proven before any further new image): every K1a attempt of both units is
  a bound, clean K1A PASS whose decoded `mem` step holds a valid, positive MemTotal (FS-R-013 §2's manual check,
  enforced here), and every Unit 2 K1g attempt is a bound, clean K1G PASS. The rules are K1g's own
  (`host/fs-k1g-units.ps1` `Get-FsK1gK1aGate`, `Get-FsK1gUnit2Outcome`, read unchanged and pinned in the N1 sign-off sheet (private));
  phase A prints the three prior records and asks A5.
- **N1 runs on Unit 2 only (PM decision 2026-10-16 (a)).** A Unit 1 run is optional and can be added later: the
  observer, phase A and the order gate refuse Unit 1 (`fs-n1-units.ps1` `$FsN1Unit1Enabled = $false`). The dormant
  Unit 1 rule stays written for that later decision: Unit 1's own clean K1A PASS (with MemTotal) **and** Unit 2's clean
  N1 PASS, reported to the PM (A5).
- **One N1 attempt per unit** (FS-R-013 §3, §5: no automatic further attempt, no standing-repeat authority): any
  earlier N1 attempt of the unit (any outcome, PASS included, or none) refuses a new one; a further attempt needs the
  Chair's explicit authority and a new package revision.
- Any REVIEW, FAIL, INTEGRITY FAULT, INCONCLUSIVE, unclean PASS or attempt without an outcome record blocks the next
  step (no clearance shortcut, FS-R-013 §3). Each attempt: its own fresh nonce (a nonce-only rebuild of the reviewed
  N1 candidate), its own readback rows (K1a's, unchanged), its own ledger entry (`build\n1\attempted`).
- N1 needs **its own Chair package** (FS-A-014 or later; FS-R-013 §13 lists FS-A-014's contents, which N1 may join
  or follow). Known hardware faults (Unit 2 IPD and proximity, Unit 1 proximity) are recorded, never compensated;
  N1 reads no sensor.

## 2. The kernel: unchanged (no kernel change needed)

The K1a config already builds everything N1 needs [M-static, `../k1a/kernel/k1a.config`]: `CONFIG_USB_CONFIGFS_NCM=y`,
`CONFIG_USB_F_NCM=y`, `CONFIG_USB_U_ETHER=y`, `CONFIG_USB_CONFIGFS_ACM=y`, `CONFIG_IPV6=y`, `CONFIG_INET=y`; NCM is
built in, not a module, so the image loads no new module and the 95-module list is K1a's. The builder pins the same
Image (`087f0e72…1840`), config (`4aa0c894…826b`) and kgate PASS as K1a, and the nonce-only check requires the same
kernel bytes. Facts from the v2.7 source (`~/work/kgate27/src`, read, not copied) [M-static]:
- `f_ncm.c`: the netdev is registered at the first bind (`ncm_bind` → `gether_register_netdev`); before that the
  configfs `ifname` reads `(unnamed net_device)` (`u_ether.c gether_get_ifname`), so `init.sh` reads it after the
  bind and uses it only as a plain `[a-z0-9]` name that carries `dev_addr`; `dev_addr`/`host_addr` can only be written
  before the function is linked (refcnt), so `init.sh` writes and reads them back before the link;
- `f_ncm.c` 1364-1371: a 1-byte zero pad after an NTB (what the Windows host driver sends instead of a ZLP) is
  accepted (the upstream fix "Avoid dropping datagrams of properly parsed NTBs" is present);
- `CONFIG_USB_CONFIGFS_NCM_DEBUG=y` (stock) only adds the `ss_bulk_maxburst` attribute (not used);
- `addrconf.c addrconf_dad_begin`: with `accept_dad` below 1 on the interface and in `all`, a new address completes
  DAD **before** the `IF_READY` check, i.e. it becomes permanent at the first (asynchronous, milliseconds) DAD work
  run, carrier or not (also seen in the harness on the WSL kernel); fs-xfer retries its bind on `EADDRNOTAVAIL` for
  the gap. So PID 1 never waits for the link; traffic flows once the PC's driver activates the data interface.

## 3. The image (`build-image.sh`, `init.sh`, `fs-n1.sh`, `fs-n1-info.sh`, `src/fs-xfer.c`)

Built by `build-image.sh` (derived from K1a's; every K1a check kept). Additions: **n1** fs-xfer pinned
(`cb136c1f…7310`, 675,608 bytes) and tied to `build-record/BUILD-xfer.txt` (this binary, this checkout's
`src/fs-xfer.c`); **n2** the no-listener lint; **n3** the info helper runs no writing or network command (`ip`
included). Ramdisk: K1a's plus `/bin/fs-n1`, `/bin/fs-xfer`, `/lib/fs/fs-n1-info.sh` (five ELF files in the union).

**PID 1 (`init.sh`)** = K1a's with: product "FrameShift N1"; **4b** NCM (`ncm.fs`) linked after `acm.gs0`, MACs from
the nonce (`dev_addr` `02:<nonce bytes 0-4>`, `host_addr` `06:<nonce bytes 0-4>`, as the Quest 2 channel design),
IPv6 `default` sysctls set and read back before the bind (`addr_gen_mode=1` no kernel address, `accept_dad=0`,
`dad_transmits=0`, `accept_ra=0`, `autoconf=0`, `router_solicitations=0`; `all/accept_dad` 0); the bind with the
ACM-only retry; **4c** after ttyGS0: the interface's own sysctls (the same, plus `disable_ipv6=0`), link up, **one**
address `fe80::<nonce>/64` (the 64-bit nonce is the interface identifier); no IPv4, no DHCP, no route, no daemon;
`/run/fs.ncm` (state, interface, address, port; written through a temporary file and renamed) for the runner; **6b** the ACM-continuity guard (one child, bounded by
the uptime clock and an iteration cap, never fatal). Kept: the deadline 200 s, backstop 201 s, ack window 150 s, the
module index pins and loader, the role, the helpers, the console shell, the hold. **No panel write; no block
device; nothing written to storage by FrameShift's tools** (as K1a; the cycle's `adb reboot bootloader` writes the
misc message as in every stage).

**The runner (`fs-n1 <challenge>`):** once per boot; one paced FSB1 record `exp=n1`, 6 steps under fs-supervise:
`kernel` (uname, /proc/version, cmdline, the running config's SHA-256 with the K1a and N1 option lines), `mem`,
`modules` (the loader's lines and K1a's kmsg section unchanged: refusals, taint notes, WARNING/BUG lines), `net`
(gadget, NCM function, `/run/fs.ncm`, interfaces, the NCM interface's attributes and IPv6 settings, `if_inet6`,
`fib_trie`, `ipv6_route`, **every socket table before**), `xfer` (`/bin/fs-xfer`), `log` (**first the post-transfer
kernel-log check**, then `fs.log`, stages, **every socket table after**, the interface counters). Reads use `grep -H`
(few forks: under QEMU every fork costs).

**The post-transfer kernel-log check (FS-R-014 §5; `fs-n1-info.sh` `kmsg_post`).** Step 3's read (K1a's section,
unchanged) precedes the transfer, so it alone cannot show a WARNING/BUG raised by the transfer. The log step (step 6,
after fs-xfer has ended) therefore pauses 1 s (deferred teardown may still log) and reads the whole kernel log once
more (one plain `dmesg`: no option, never a clear; its stderr captured; one `awk` pass), **first** in the role (no cap
on the later sections can cut it: fs-supervise keeps the head of a step's output), and prints: `read=ok|fail rc= bytes=`; the
line count; the first and last line's first 16 bytes; the refusal, taint and WARNING/BUG/oops counts (step 3's
filters); the last ≤ 30 matching lines (≤ 200 bytes each) and the last ≤ 10 ncm/usb0/gadget/dwc3 lines (≤ 160
bytes); and an end marker. Worst case 8,167 bytes with every count at its longest, so the later sections keep r1's
16,384 bytes of the 24,576-byte cap (checked by `check-bounds-n1.py`). **Coverage:** the implemented check accepts the
post read as extending step 3's when its first line's first 16 characters equal step 3's and it has no fewer lines;
anything else is "coverage not proven". The rule relies on every line's `[timestamp]` prefix
(`CONFIG_PRINTK_TIME=y`, no `printk.time=0`). **Qualification (FS-R-015 §5):** the comparison uses the first 16
characters, not the complete first line, and timestamp prefixes can repeat; matching that prefix plus a
non-decreasing line count is a retention heuristic, not proof of lossless continuous coverage. A clean result is
therefore reported as **"no wrap detected by the implemented check"**, not as an unconditional continuity proof; the
classifier's machine field value `continuous` (and its PASS reason text) keeps its implementation-defined meaning. A
stronger future continuity claim would compare retained-prefix content or suitable sequence boundaries. The kernel's buffer is 256 KiB on the unit (the stock vendor command line's
`log_buf_len=256K` overrides `CONFIG_LOG_BUF_SHIFT=17`'s 128 KiB; K1a record <attempt nonce withheld>'s `cmdline`); on both units the K1a boot had logged about 710 lines with the
first line still `[    0.000000]` [M, K1a records <attempt nonce withheld> and <attempt nonce withheld>], so a wrap would itself be a finding.
Coverage ends at this read (after the transfer, before `fs-done`): a line logged later is not seen.
**Bounds** (`tools/check-bounds-n1.py`, 17/17; r2: the log step 4 → 6 s and 16384 → 24576 bytes for the
post-transfer read): MAXLINES 2666; RUNNER_WORST 126 s (steps 108 s worst case incl. fs-supervise's 7.5 s per step,
emission 13.4 s, writes 2 s, margin 2 s) → the device's own `time` refusal unless it starts by **T0 + 74 s**; the
collector sends it only before **BootStartUtc + 54 s** (stage 3c sent its runner at about BootStartUtc + 32 s [M,
FS-A-012-raw collect.json]). The deadline stays 200 s (as K1a; not lengthened). **fs-xfer's 23 s is a design budget,
not a hard maximum** (FS-R-014 §5): LISTEN 10 s + SESSION 12 s + DRAIN 1 s, but its phase deadlines are tested only
when it waits (a `poll()` after `EAGAIN`, and the bind-retry loop's pause); while data keeps arriving or leaving,
while it hashes or computes the stream (CPU), and while it writes its report lines, no deadline is tested. Those
loops are bounded by byte counts (the header line, 8 MiB each way, the 64 KiB drain), so an overrun is limited by
throughput and CPU speed, not by a clock. (`src/fs-xfer.c`'s own comment, pinned and unchanged in r2, still reads as
if only a hung loop could pass the budget; to be reworded at its next rebuild.) Its hard bounds are its alarm (SIGALRM, the
default action, at 25 s) and fs-supervise (TERM at the step's 26 s, KILL 1 s later); RUNNER_WORST counts the step at
t + g + 7.5 = 34.5 s like every step, so no fs-xfer timing assumption enters it.

## 4. FSX1, the transfer test (normative; `src/fs-xfer.c`)

`fs-xfer -n <nonce> -c <challenge> -a fe80::<nonce> -i <if> -p 47201` (or `-i none`: prints `result=no-ncm`):
- listens on exactly `[fe80::<nonce>%<if>]:47201` (`IPV6_V6ONLY`, backlog 1; the address must be exactly
  fe80::<nonce>; `::1` only in the native `-DFSX_FIXTURE` twin, never in the image); `bind` retried on `EADDRNOTAVAIL` and the accept, together ≤ 10 s from the
  start; a peer that is not link-local on this interface is closed and counted (at most 4); **the listening socket is
  closed at the first good accept**;
- PC → device, within 2 s: `FSX1 <nonce> <challenge> 8388608 8388608\n` (exact; else `bad-header`, nothing sent),
  then 8,388,608 bytes (any content), hashed with SHA-256 (own FIPS 180-4 code, self-tested at start);
- device → PC: 8,388,608 bytes of the stream `block i = SHA-256("FSX1-D2H" ‖ nonce ‖ chal ‖ uint64_be(i))` (nonce and
  chal as their ASCII hex strings), then
  `FSX1 END <nonce> <chal> rx=<n> rx_sha256=<h> tx=<n> tx_sha256=<h>\n`; header to trailer ≤ 12 s;
- half-close, drain ≤ 1 s / 64 KiB until the PC's EOF, close; printable report lines (`FSX1 start/listen/accept/
  closed-listener/header/rx/tx/drain/result`); exit 0 for any session outcome, 64 usage, 70 internal; no exec, fork,
  file open or write (source scan in `tools/build-xfer.sh`); a 25 s `alarm()` backstop. The ≤ 10 s, ≤ 2 s, ≤ 12 s
  and ≤ 1 s above are tested only when fs-xfer waits (§3 Bounds): they are its design budget, the alarm and
  fs-supervise are the hard stops.
The PC checks: what it sent hashes to the device's `rx_sha256`, what it received hashes to the device's `tx_sha256`
**and** to the expected stream (recomputed independently in C#, Python and C: fixture X1). The classifier
cross-checks the device's FSB1 record, the PC's `xfer.json` and the expected stream.

## 5. The PC side (Windows 11) and the PM-side steps

**How Windows binds it** [doc, research 2026-10-16; on this PC [M] read-only]: the gadget is a composite (`EF/02/01`,
IAD); `usbccgp` makes one child per interface collection: `MI_00` = ACM (usbser, a COM port, as in every stage; seen
under earlier `FS-<nonce>` serials on this PC) and `MI_02` = NCM with the compatible ID
`USB\Class_02&SubClass_0d&Prot_00`. Windows 11 ships the inbox host driver **UsbNcm** (`usbncm.inf`, "UsbNcm Host
Device"; Microsoft lists it for Windows 11; Windows 10 1903+ per the Factory OS docs) matching exactly that ID; on
this PC `C:\Windows\INF\usbncm.inf` is present (DriverVer 10.0.26100.9711) [M]. So **no driver install and no MS OS
descriptors are expected** [C until the run]. Expected behaviour [doc/C]: the adapter's MAC is the gadget's
`host_addr` (`06-…`); Windows gives it a random link-local address (RandomizeIdentifiers is Enabled here [M]) after
about 1 s of DAD and, with no DHCP server, an APIPA IPv4 address later; the network is "Unidentified network"
(Public profile); outbound TCP from the PC needs no firewall rule or prompt; each new serial (each nonce) is a new
device instance, a new "Ethernet N" adapter, a new ifIndex and a new COM number (old ones remain as non-present
devices). Windows will send ND/RS/MLD, DHCPv4 discovers, LLMNR/mDNS/SSDP/NetBIOS on the link: the device has no
socket for any of them (its tables prove it) and its kernel only answers ND/MLD. WSL here runs in the default NAT
mode (no `.wslconfig`) [M]; mirrored mode would also show the adapter to WSL (recorded by phase A, not a stop).

**The PM-side steps** (the run walkthrough (private), step N0 and phase A; **nothing is installed or changed**):
1. Nothing to install. Phase A checks automatically (read only) that `usbncm.inf` matches the NCM class with the
   UsbNcm service and that IPv6 is not disabled (`Tcpip6\Parameters\DisabledComponents` absent or 0); a failure STOPS.
2. During the run, do not touch the new adapter, its network profile or the firewall; dismiss no prompt by
   changing a setting. The collector finds the adapter by the nonce's USB serial (never by name or number).
3. If Windows does not bind UsbNcm (a yellow mark on the NCM child), **install nothing and change no setting (PM
   decision 2026-10-16 (b))**: the run still ends normally (the console is unaffected; the transfer records
   `no-adapter`); record what happened (the classifier's PC timeline, a Device Manager screenshot of the NCM child) and
   review it first. Any later driver step (pointing the `MI_02` child at the inbox UsbNcm, or an image exposing the
   `WINNCM` MS OS descriptor) would be a new PM decision; neither is in this package.
4. Afterwards nothing needs cleaning up for the run; the accumulating non-present adapters are cosmetic (removing
   them would be a PC change: a PM decision).

## 6. What counts as N1 PASS (`host/fs-classify-n1.ps1`)

INCONCLUSIVE (no valid record) → INTEGRITY FAULT (a step not exited 0, stderr); then a missing `xfer.json` of this
nonce and challenge, or (live) one not made by the PowerShell client on the adapter of this attempt's `FS-<nonce>`
device, turns any further outcome into INCONCLUSIVE → **N1 FAIL** (a K1a kernel fact: banner, config, the NCM/IPv6 options, modules, refusals; **MemTotal not a
valid positive kB value** (FS-R-013 §2); ACM not first or NCM not bound; any `NCM_*` failure (each keeps the fact
"ACM continuity held"); MACs not the nonce's; not exactly one IPv6 address on the interface, fe80::<nonce>/64 scope
link permanent; its IPv6 settings; one of the tables tcp, tcp6, udp, udp6, raw, raw6, packet not read; fs-xfer's result not `ok`; the device's and the PC's
hashes or sizes disagree, or the stream is not the expected one; the peer not link-local on the NCM interface; no
closed-listener line; **the post-transfer kernel-log result missing, malformed or incomplete** (parsed as a strict
sequence: line 0 of the log step, each field once, the listed lines as announced, the end marker, then `fs.log`; the
cap cannot explain a gap since it is printed first), step 3's line count or taint count missing, or a refusal line
in the post read) →
**N1 REVIEW** (kernel WARNING/BUG lines **in step 3's read or in the post-transfer read** (those first seen after
step 3 are named as such); a wrapped log; **the post-transfer read unreadable, its coverage across the transfer not
proven (wrapped, cleared)**; a new taint line after step 3; a truncated step; **any TCP LISTEN
row or UDP, UDP-Lite, raw or packet socket before or after the transfer, any TCP row before it, and after it any TCP
row other than the closing session on port 47201**; a PC adapter MAC other than `host_addr`; the NCM adapter not at
interface collection `MI_02`; an IPv4 local address other than
loopback; a drain anomaly; a rejected foreign peer; a PC driver other than the inbox UsbNcm) → **N1 PASS**. A
recorded outcome needs a live, observed attempt and phase F; `classify-n1.json` is written once and binds
`observe.json`, `collect.json`, `capture.raw` and `xfer.json`.

FS-R-013 §3's rules carry over unchanged from K1a (the N1 sign-off tooling (private) phases B, E, F; `fs-observe-n1.ps1`):
admission by a single fresh reading on the named unit (status 3/4/5 below 35 °C or status 2 below 30 °C, battery
above 50 %; BA10 the same); BA/BF, presence, typed nonce, BA-to-boot ≤ 300 s; deadline 200 s, backstop 201 s;
AF at once, then Android and AA; follow-ups at about +5 and +10 min after AA, continuing while rising or concerning;
≥ 40 °C: shut down and cool at once (physical shutdown precedes any reading; never restart for a reading); Th + 260 s
is a fallback, never a reason to wait through heat; dump mode: recover at once, never EDL or flashing tools; identity and slot before and after, with "misc, devinfo and partition-content invariance were not measured."

## 7. Tests (all offline)

| suite | result | file |
|---|---|---|
| fs-xfer build (clang r450784e, static, bit-identical, limits, no exec/fork/open) | built | `build-record/BUILD-xfer.txt` |
| builder negatives and reproducibility (`test-builder.sh`) | **57/57** | `fixtures/builder/RESULTS.txt` |
| QEMU harness of the image (`test-image.sh`) | **24/24 scenarios** (r2: `c-kmsg-post`, `-unreadable`, `-wrapped`) | `fixtures/image/RESULTS.txt` |
| bounds (`tools/check-bounds-n1.py`) | **17/17, RESULT PASS** | `fixtures/bounds.txt` |
| host side (the N1 host suite (private), incl. a real fresh-nonce rebuild) | **103/103** | the N1 host suite (private) |

**The harness** (`tools/image-harness-n1.py`) runs the ramdisk unpacked from the built image as PID 1 in a bwrap
sandbox under qemu-aarch64, each scenario in its own `unshare -rnm`; the NCM link is a **veth pair** between the
sandbox's network namespace (`usb0`, MAC = dev_addr; its real sysfs bind-mounted) and a "PC" namespace (`hst0`, MAC =
host_addr) where the reference client `tools/xfer-client.py` runs; the sandbox keeps CAP_NET_ADMIN only. Real: the
image's userspace, fs-supervise, fs-xfer (aarch64), the WSL kernel's IPv6 (address states, socket tables, counters),
the 8 MiB transfers. Fake: the kernel facts (as K1a), configfs/UDC (plain files; the NCM bind failure is a seccomp
ENODEV on the first write-open of `UDC` while NCM is linked; the kernel fails the write itself, which busybox
`echo` also reports as a failure; writes to `dev_addr`/`host_addr` after the link get EBUSY, as f_ncm), USB
enumeration (the UDC state is a fixed file: the guard's last-second race is not exercised), Windows. The kernel log
is a fixed text answered through `syslog(2)`; in `c-kmsg-post` the harness appends a WARNING the moment it sees the
device's port-47201 session ESTABLISHED (A's `/proc/net/tcp6`), i.e. after step 3's read and once the transfer has
begun; `-unreadable` refuses every read after the first (EPERM), `-wrapped` drops the first two lines from them.

**Internal adversarial review (2026-10-16, two read-only reviewers):** device side GO-with-fixes (MAJOR: the guard's
last-check race, stale harness fixtures; MINOR m1-m9), host side GO-with-fixes (MAJOR: no gate against a repeat N1
attempt; MINOR m1-m11). Applied: every MAJOR; device m1, m2, m3, m5, m6, m7 (EBUSY model, TCP decoy, unattached
scenario), m9 (wording); host m1-m10 and the m11 repeat fixtures. Documented, not changed: device m4 (the lexical lint;
an allowlist or a busybox without listener applets would be a PM decision, the busybox being shared with every stage),
m8 (no SO_REUSEADDR: one run per boot), the UDC write fault faked at open (m7); host m11's runspace test is covered
only by the stop/wait path of X9 and the reviewer's own probe.

**N1 r2 review (2026-10-17, two read-only reviewers, `review/REVIEWS-n1.md` RD2/RH2):** device side GO-with-fixes (no
MAJOR: the 256 KiB buffer fact, the read's timing, the output bound, lints); host side GO-with-fixes (MAJOR: two new
cases red and stale evidence at the reviewed commit; the post-section parser not strict enough). All applied before
the candidate and the evidence above were made.

## 8. What the tests cannot show

f_ncm and dwc3 on the unit (bind, enumeration, NTB handling, throughput), Windows' actual binding, adapter MAC and
timing, firewall behaviour on the PM's PC, and the kernel itself: these are the run's [O]. The harness's IPv6 is the
WSL 6.18 kernel's, not 5.10's (the 5.10 source facts of §2 are [M-static]). QEMU timing is not device timing; the
bounds come from `check-bounds-n1.py`. The post-transfer read sees the kernel log up to step 6 only; a line logged
during the record's emission, `fs-done` or the reboot is not in the record (the K1a after-session checks are
unchanged).

## 9. Open items and PM decisions

1. **The Chair package** for N1 (FS-A-014 or later) and the PM's sign-off; N1 on Unit 2 after both K1a attempts and
   after K1g on Unit 2 (coordinator decision 2026-10-16).
2. **Unit 2 only** (PM decision 2026-10-16 (a)); a Unit 1 run is optional, later, by a new decision and revision.
3. **No driver install** (PM decision 2026-10-16 (b)): if UsbNcm does not bind, nothing is installed or changed;
   the run is recorded and reviewed first (§5 step 3).
4. **The transfer size** (8 MiB each way, ≥ ~1.4 MiB/s needed within 12 s) is a link test, not a throughput
   benchmark for R-1; a larger transfer would need a longer deadline or its own step budget.

## 10. Files

| file | role |
|---|---|
| `init.sh`, `fs-n1.sh`, `fs-n1-info.sh` | PID 1, the runner, the read-only fact helper |
| `src/fs-xfer.c`, `tools/build-xfer.sh`, `build-record/BUILD-xfer.txt` | the responder, its build and record |
| `build-image.sh`, `test-builder.sh` | the image builder (K1a's checks + n1-n3), its negatives and reproducibility |
| `test-image.sh`, `tools/image-harness-n1.py`, `tools/xfer-client.py` | the QEMU harness with the veth NCM link and the reference client |
| `tools/check-bounds-n1.py`, `tools/nonce-only-n1.py` | the bounds, the nonce-only rebuild check |
| `../host/fs-xfer-n1.ps1` | the PC side: adapter lookup, the FSX1 client, the background session |
| `../host/fs-collect-n1.ps1`, `fs-classify-n1.ps1`, `fs-n1-units.ps1` | collector, classifier, order and MemTotal gate |
| the N1 sign-off tooling (private), `fs-observe-n1.ps1`, `fs-nonceonly-n1.ps1` | adapted copies of the K1a tools (not edited) |
| the N1 sign-off tooling (private), the N1 sign-off sheet (private), the N1 host suite (private) | the host pins, the host tests |
| the run walkthrough (private) | the eventual run (reviewed; byte-equal execution) |
| `review/REVIEWS-n1.md` | the internal review records: verdicts, findings, dispositions |
