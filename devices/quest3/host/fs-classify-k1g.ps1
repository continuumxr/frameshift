# FrameShift K1g classifier (Windows PowerShell 5.1, no modules). Reads ONE collector output directory of
# fs-collect-k1g.ps1 (collect.json + capture.raw) and classifies the K1g run ("the boot-chain write guard is proven",
# FS-R-013 s.5/s.6; devices/quest3/k1g/). Offline; reads files only; no device, no network.
# An adapted COPY of fs-classify-k1a.ps1 (pinned, not edited); the differences (a reviewer diffs the two):
#   - exp k1g, 9 steps (K1a's eight and blkguard), the K1g banner (-Banner; frameshift@k1g), the K1a config SHA-256
#     unchanged (the exact K1a config), 95 modules; the gadget product "FrameShift K1g" with serial FS-<nonce>;
#   - FS-R-013 s.2: MemTotal is REQUIRED (Test-FsK1gMemTotal: exactly one valid, positive "MemTotal: <n> kB" line);
#     missing or malformed -> K1G REVIEW with that reason (it blocks progression; it is never a reason for another attempt);
#   - PID 1's stages (log step, fs.stages): INIT_STARTED, MODULES_READY, BLKGUARD_STARTED, BLKGUARD_DONE,
#     ACM_SETUP_ATTEMPTED, UDC_BOUND, SHELL_READY (then HOST_ACK), and fs.log's "STAGE=BLKGUARD_DONE result=<R>" equal
#     to the probe's result; otherwise K1G REVIEW;
#   - step 9 (blkguard: fs-k1g-info.sh blkguard, the report of PID 1's fsbg-probe run, Get-FsK1gGuardFacts):
#       K1G FAIL (a guard defect or a changed range: stop; never repeated automatically): the probe's RESULT FAIL or
#         fail > 0; a SERIES with fail > 0; a STOP:, FAIL: or "Mechanism phase failed" line; a CASE, ALLOW or ROW line
#         whose verdict is not PASS (a ROW before ARMED in an ABORT run is the pre-check's refusal: REVIEW, below);
#         HASHDIGEST before != after; "HASH verify" with any failed or changed node; fs-supervise's FSUP1 report for the
#         probe not end=exited code=0 (code=2 for an ABORT result: the probe's own ABORT exit) or missing; err-bytes not
#         0; a /proc/fs_blkguard line (first 8, read after the proof) other than the eight expected (the counters may
#         vary, total > 0) in a run that armed (not ABORT); a "... <n> more failing lines suppressed" line (compact mode
#         shows at most 24 failing lines). THE STEP'S HEADER IS READ FIRST: "== result FSBG-PROBE RESULT: FAIL ..." or
#         fail=<n> > 0 there is a K1G FAIL even when the step is truncated or "== guard" is missing;
#       INCONCLUSIVE (a pre-arming TIME STOP, not a guard verdict; README s.5): the RESULT is ABORT with an "ABORT: time:"
#         line and no ARMED line (a row hit its time bound, or the before-hash pass exceeded its budget: nothing was
#         attempted), or fs-supervise's timer stopped the probe before any RESULT line while /proc/fs_blkguard still shows
#         the unarmed boot state (mode protect, sealed 0, modules_disabled 0). A nonce-only repeat may be PROPOSED to the
#         Chair for it (FS-R-013 s.5); it is never automatic.
#       K1G REVIEW: the RESULT is ABORT before arming for any other reason (the pre-check refused; no armed guard test case was attempted;
#         the ABORT line is reported), or an ABORT after arming (a refused decoy re-check, or after-hash rows not verified
#         within their time bound: the invariance check is incomplete, not a changed range); fs-supervise's timer stopped
#         the probe before any RESULT line in any other state (a timing artefact);
#         the result line missing, malformed, not equal to the step's "== result" line, another nonce, mode not device,
#         "testkernel" or "forceq"; a Q11, C* or S5 series, or any series outside the device list; a required series
#         missing; the counts inconsistent (Q1=Q2=Q3 = the visible block nodes, Q4=Q5 = 6 whole disks,
#         Q6=Q7=Q12=Q13=Q14 = A3 = 6 sd disks, Q8 >= 1, Q9 >= 1, Q10 = 1 ufs-bsg node, H = H' = the HASH verify count =
#         the visible nodes + 12, N1-N6 = 7, N7-N10 = 2, N11 = 1, P1-P5,P7-P11 = 1, S1-S4 = 1, A1 = A2 = 1); the
#         five readback rows (R1-R5: boot_a, vendor_boot_a, dtbo_a, vbmeta_a, vbmeta_system_a, the expected range and
#         SHA-256 prefix, PASS) before or after ARMED missing or not matching, or the two R6 rows (misc 1048576,
#         devinfo 4096) missing; the header, PRE, ARMED, SEAL, HASH verify, POST or HASHDIGEST line missing; an
#         unexpected probe line; the step's structure (== result, == supervise, == err-bytes, == probe, == guard)
#         broken or truncated;
#   - the outcome record is <ObserveDir>\classify-k1g.json (schema frameshift.fs-classify-k1g.v1), bound to the K1g
#     checklist's phase F (the K1g sign-off tooling (private)); the Unit 1 K1g gate (fs-k1g-units.ps1) reads it.
#
#   fs-classify-k1g.ps1 -CollectDir <dir> [-ObserveDir <dir>] [-Banner <expected /proc/version>] [-ConfigSha <64 hex>]
#   . fs-classify-k1g.ps1 ; $o = Get-FsK1gOutcome -Fsb1 <Test-Fsb1Record result> [-Collected $true] [-Nonce <16 hex>] [-Banner ...]
#
# The outcome, first match wins:
#   INCONCLUSIVE        no complete, FSB1-VALID record (missing, rejected, capture inconsistent): nothing concluded
#   INTEGRITY FAULT     a runner step that did not exit 0 (timer, signal, no supervisor report), or a step wrote stderr
#   K1G FAIL            the record is valid but a K1a fact (as fs-classify-k1a.ps1, with the K1g banner and product) or
#                       a guard fact (above) is wrong
#   K1G REVIEW          every FAIL-class fact holds, but: kernel WARNING/BUG/oops-class lines (FS-R-012 s.3), the kernel
#                       log had wrapped, a step truncated at its cap, MemTotal missing or malformed, the probe ABORTed,
#                       or a REVIEW-class guard or stage fact (above)
#   K1G PASS            every fact holds
# EVERY result reports the K1a facts (kernel WARNING/BUG findings, MemTotal, the kernel log's first line, taint notes)
# and the guard facts (the probe's result line, POST and /proc/fs_blkguard counter totals, the series table, the R1-R5
# rows before and after with their SHA-256 prefixes, R6, HASH verify, HASHDIGEST, any ABORT/FAIL/STOP/SKIP line).
# Binding (as K1a): a K1g outcome needs a LIVE collect.json (no replay, no fixture overrides) and the attempt's
# observe.json (-ObserveDir: the same nonce, stage k1g, one of the two units); otherwise INCONCLUSIVE. -AllowReplay
# (offline fixtures only) lifts that and labels every output line FIXTURE. A PASS is the MACHINE SIDE only.
# Exit: 40 K1G PASS, 41 K1G REVIEW, 42 K1G FAIL, 43 INTEGRITY FAULT, 44 INCONCLUSIVE, 64 usage, 70 internal error.
[CmdletBinding()]
param(
    [string]$CollectDir = '', [string]$ObserveDir = '',
    [string]$Banner = 'Linux version 5.10.246-ga9c63e24cb76 (frameshift@k1g) (Android (8508608, based on r450784e) clang version 14.0.7 (https://android.googlesource.com/toolchain/llvm-project 4c603efb0cca074e9238af8b4106c30add4418f6), LLD 14.0.7) #1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026',
    [string]$ConfigSha = '4aa0c894655627f6ff39476ac2a45abb4c224ee0053957d5002c694b0602826b',
    [int]$Modules = 95,
    [switch]$AllowReplay
)
Set-StrictMode -Version 2.0
$script:FsK1gClsInvocation = $MyInvocation.InvocationName
$script:FsK1gClsDir = $PSScriptRoot
. (Join-Path $PSScriptRoot '..\common\host\fsb1.ps1')    # Test-Fsb1Record (read only)
. (Join-Path $PSScriptRoot 'fs-k1g-units.ps1')            # the units, the outcome record schema, Test-FsK1gMemTotal (read only)

$script:FsK1gSteps = @('kernel', 'config', 'mem', 'modules', 'kmsg', 'fs', 'usb', 'log', 'blkguard')
$script:FsK1gLatin1 = [System.Text.Encoding]::GetEncoding(28591)
$script:FsK1gStages = @('INIT_STARTED', 'MODULES_READY', 'BLKGUARD_STARTED', 'BLKGUARD_DONE', 'ACM_SETUP_ATTEMPTED', 'UDC_BOUND', 'SHELL_READY')
# ---- the guard contract (k1g/fs-k1g-info.sh blkguard; tools/blkguard/probe/fsbg-probe.c --compact, device mode) ----
$script:FsK1gGuardAllow = 'disk:ram0,disk:dm-200,disk:dm-201,disk:loop7,part:fsbg_decoy_rw'
$script:FsK1gGuardLines = @('fs_blkguard 1', 'mode: strict', 'sealed: 1', 'allow: disk:ram0 disk:dm-200 disk:dm-201 disk:loop7 part:fsbg_decoy_rw',
                            'modules_disabled: 1', 'hazards: none', '<denied>', 'targets:')
$script:FsK1gGuardDeniedRe = '^denied: open=([0-9]+) write=([0-9]+) fallocate=([0-9]+) discard=([0-9]+) zeroout=([0-9]+) roset=([0-9]+) blkpg=([0-9]+) rrpart=([0-9]+) bio=([0-9]+) scsi=([0-9]+) sg=([0-9]+) bsg=([0-9]+) scsi-ioctl=([0-9]+) pr=([0-9]+) total=([0-9]+)\z'
$script:FsK1gFsupRe = '^FSUP1 end=(exited|signaled|timer-term|timer-kill|exec-failed|unreaped|refused|internal) code=(-?[0-9]+) sig=[0-9]+ errno=[0-9]+ ms=-?[0-9]+ term_ms=-?[0-9]+ kill_ms=-?[0-9]+ out_total=[0-9]+ out_kept=[0-9]+ err_total=[0-9]+ err_kept=[0-9]+ strays=[0-9]+ pipes=(eof|open|none) why=[a-z-]+ END\z'
# the readback rows R1-R5 (the readback proposal (private) s.3; the probe's rr[] table): the range in bytes and the SHA-256 prefix
$script:FsK1gRootRows = [ordered]@{
    R1 = @('boot_a', 61607936, '7fe59729491b40b6'); R2 = @('vendor_boot_a', 5058560, '7e0cfe93e0e9867a'); R3 = @('dtbo_a', 12564, 'a02fdeede1c1466f')
    R4 = @('vbmeta_a', 5632, '1674552357aa0ca1'); R5 = @('vbmeta_system_a', 3136, 'a462b6dab7e67a72') }
$script:FsK1gR6 = [ordered]@{ misc = 1048576; devinfo = 4096 }
# the device series (PM decision 2026-10-15: no Q11 on a Quest; no C*, no S5)
$script:FsK1gSeries = @('H', "H'", 'N1', 'N2', 'N3', 'N4', 'N5', 'N6', 'N7', 'N8', 'N9', 'N10', 'N11', 'P1', 'P2', 'P3', 'P4', 'P5', 'P7', 'P8', 'P9', 'P10', 'P11',
                        'S1', 'S2', 'S3', 'S4', 'A1', 'A2', 'Q1', 'Q2', 'Q3', 'Q4', 'Q5', 'Q6', 'Q7', 'Q8', 'Q9', 'Q10', 'Q12', 'Q13', 'Q14', 'A3')
$script:FsK1gWholeDisks = 6       # sda..sdf (Quest 3 UFS LUNs as whole sd disks)
$script:FsK1gUfsBsg = 1           # /dev/bsg/ufs-bsg*
# review MINOR: the pinned counts of the device-mode case table: N1-N6 on the 7 decoy nodes, N7-N10 on the 2 decoy whole
# disks, N11 once, the P series once each, S1-S4 and A1/A2 once each; A3 once per whole sd disk; H = H' = the visible nodes
# + 12 (7 decoy rows + the 5 readback rows R1-R5)
$script:FsK1gFixedCounts = [ordered]@{ N1 = 7; N2 = 7; N3 = 7; N4 = 7; N5 = 7; N6 = 7; N7 = 2; N8 = 2; N9 = 2; N10 = 2; N11 = 1
    P1 = 1; P2 = 1; P3 = 1; P4 = 1; P5 = 1; P7 = 1; P8 = 1; P9 = 1; P10 = 1; P11 = 1; S1 = 1; S2 = 1; S3 = 1; S4 = 1; A1 = 1; A2 = 1 }
# FS-R-014 s.3.1: the content rows are fixed: 7 decoy rows + R1-R5 + R7d (misc) + R8 (devinfo) = 14, before and after
$script:FsK1gHashRows = 14
$script:FsK1gScopeRe = '^PRE scope: content reads only R1-R5, R6, R7d \(misc\), R8 \(devinfo\); never opened: (/dev/[a-z0-9]+)\z'
$script:FsK1gPersistSkipRe = '^SKIP  Q\*    (/dev/[a-z0-9]+) +persist: never opened \(FS-R-014 s\.3\.1\)\z'
$script:FsK1gDecoyRowRe = '^/dev/(ram1|loop6(p[1-46])?)\z'

function ConvertTo-FsK1gPrintable([string]$s) {
    $b = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -ge 0x20 -and [int]$ch -le 0x7e) { [void]$b.Append($ch) } else { [void]$b.AppendFormat('\x{0:x2}', [int]$ch) } }
    $b.ToString()
}

# Step 9: the guard facts. $Text = the blkguard step's stdout; $Nonce = the record's nonce; $Truncated = the step was
# cut at its cap. Returns @{ Fail; Abort; Review (lists of reasons); Result; ResultLine; PostTotal; GuardTotal; Denied;
# Series (ordered id -> "pass/fail"); Rows (R1..R5 -> before/after node and prefix); R6; HashVerify; Digest; Lines (the
# ABORT/FAIL/STOP/SKIP lines); GuardLines; Nodes; Fsup; ErrBytes }.
function Get-FsK1gGuardFacts([string]$Text, [string]$Nonce, [bool]$Truncated = $false) {
    $fail = New-Object System.Collections.Generic.List[string]; $abort = New-Object System.Collections.Generic.List[string]; $rev = New-Object System.Collections.Generic.List[string]
    $g = [ordered]@{ Fail = $fail; Abort = $abort; Review = $rev; Result = $null; ResultLine = $null; PostTotal = $null; GuardTotal = $null; Denied = $null
                     Series = [ordered]@{}; Rows = [ordered]@{}; R6 = [ordered]@{}; HashVerify = $null; Digest = $null; Lines = @(); GuardLines = @(); Nodes = $null; Fsup = $null; ErrBytes = $null
                     Pace = $null; TimeStop = $false; ArmedAbort = $false; Scope = $null; PersistSkip = @() }
    $P = { param([string]$s) ConvertTo-FsK1gPrintable $s }
    if ($null -eq $Text) { $Text = '' }
    $L = @($Text.Split("`n") | ForEach-Object { $_.TrimEnd("`r") })
    if ($L.Count -and $L[$L.Count - 1] -eq '') { $L = @($L | Select-Object -First ($L.Count - 1)) }
    # THE HEADER FIRST (review MAJOR): fs-k1g-info.sh prints the probe's RESULT line as the step's first line, so a cut-off
    # report still carries it. A header that says FAIL, or fail=<n> with n > 0, is a K1G FAIL whatever follows (truncated,
    # == guard missing, structure broken). A PASS header with a truncated step stays REVIEW (below).
    $hdrFlag = $false
    $h0 = @($L | Where-Object { $_.StartsWith('== result ', [StringComparison]::Ordinal) } | Select-Object -First 1)
    if ($h0.Count -and $h0[0] -cmatch '^== result FSBG-PROBE RESULT: (PASS|FAIL|ABORT) .*\bfail=([0-9]+)\b') {
        if ($Matches[1] -ceq 'FAIL' -or [long]$Matches[2] -gt 0) { $hdrFlag = $true; $fail.Add("guard: the step's result header reports a failure ($(& $P ($h0[0].Substring(10))))") }
    } elseif ($h0.Count -and $h0[0] -cmatch '^== result FSBG-PROBE RESULT: FAIL\b') { $hdrFlag = $true; $fail.Add("guard: the step's result header reports FAIL ($(& $P ($h0[0].Substring(10))))") }
    # the structure: == result, == supervise, == err-bytes, == probe, == guard, once each, in this order
    $ix = [ordered]@{}
    foreach ($k in 'result', 'supervise', 'err-bytes', 'probe', 'guard') {
        $hits = @(for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -ceq "== $k" -or $L[$i].StartsWith("== $k ", [StringComparison]::Ordinal)) { $i } })
        $ix[$k] = if ($hits.Count -eq 1) { $hits[0] } else { -1 }
    }
    $order = @($ix.Values)
    $structOk = (@($order | Where-Object { $_ -lt 0 }).Count -eq 0)
    for ($i = 1; $structOk -and $i -lt $order.Count; $i++) { if ($order[$i] -le $order[$i - 1]) { $structOk = $false } }
    if (-not $structOk) {
        $rev.Add("blkguard step: the report structure (== result, == supervise, == err-bytes, == probe, == guard, once each, in order) is broken$(if ($Truncated) { ' (the step was truncated at its cap)' })")
        return [pscustomobject]$g
    }
    $resHead = $L[$ix['result']].Substring(9).Trim()          # '== result ' then the probe's first RESULT line (or nothing)
    # fs-supervise's report of the probe (PID 1, init.sh section 2b)
    $sup = @($L[($ix['supervise'] + 1)..($ix['err-bytes'] - 1)] | Where-Object { $_ -ne '' })
    if ($ix['err-bytes'] - $ix['supervise'] -eq 1) { $sup = @() }
    $fsupEnd = $null; $fsupCode = $null
    if ($sup.Count -eq 1 -and $sup[0] -cmatch $script:FsK1gFsupRe) { $fsupEnd = $Matches[1]; $fsupCode = [long]$Matches[2]; $g.Fsup = $sup[0] }
    else { $g.Fsup = $(if ($sup.Count) { & $P ($sup -join ' | ') } else { '(none)' }) }
    if ($L[$ix['err-bytes']] -cmatch '^== err-bytes[ \t]+([0-9]{1,12})\z') { $g.ErrBytes = [long]$Matches[1] }
    if ($null -eq $g.ErrBytes) { $rev.Add("blkguard step: the err-bytes line is malformed ('$(& $P $L[$ix['err-bytes']])')") }
    elseif ($g.ErrBytes -ne 0) { $fail.Add("guard: the probe wrote $($g.ErrBytes) bytes to stderr (0 required)") }
    $pl = @(); if ($ix['guard'] - $ix['probe'] -gt 1) { $pl = @($L[($ix['probe'] + 1)..($ix['guard'] - 1)]) }
    $gl = @(); if ($L.Count - 1 -gt $ix['guard']) { $gl = @($L[($ix['guard'] + 1)..($L.Count - 1)]) }
    $g.GuardLines = @($gl | ForEach-Object { & $P $_ })
    # ---- the probe's compact report, line by line ----
    $armedAt = -1; $hdr = $false; $pre = $false; $seal = $false; $res = @(); $lines = New-Object System.Collections.Generic.List[string]
    $rowsB = @(); $rowsA = @(); $r6 = @(); $digest = $null; $hv = $null; $post = $null; $nodes = $null; $unexp = @(); $dupS = @(); $preRows = @(); $supp = @()
    for ($i = 0; $i -lt $pl.Count; $i++) {
        $l = $pl[$i]
        if ($l -ceq '') { continue }
        if ($i -eq 0) {
            if ($l -ceq "fsbg-probe: nonce=$Nonce mode=device arm=strict boot=protect") { $hdr = $true; continue }
            if ($l -cmatch '^fsbg-probe: ') { $rev.Add("guard: the probe header is '$(& $P $l)', not 'fsbg-probe: nonce=$Nonce mode=device arm=strict boot=protect'"); $hdr = $true; continue }
        }
        if ($l -cmatch '^PRE guard: ') { if ($l -cmatch '^PRE guard: mode=protect sealed=0 modules_disabled=0 hazards=(modules|none)\z') { $pre = $true } else { $rev.Add("guard: unexpected boot state '$(& $P $l)' (mode=protect sealed=0 modules_disabled=0 hazards=modules|none expected)") }; continue }
        if ($l -cmatch '^PRE boot storage visible: ([0-9]{1,6}) block nodes\z') { $nodes = [int]$Matches[1]; continue }
        if ($l -cmatch $script:FsK1gScopeRe) { if ($null -eq $g.Scope) { $g.Scope = $Matches[1] } else { $unexp += $l }; continue }
        if ($l -cmatch $script:FsK1gPersistSkipRe) { $g.PersistSkip += $Matches[1]; continue }
        # the probe's pace after the before-hash pass (README s.5): recorded and reported, not judged
        if ($l -cmatch '^PRE pace: sha256=(armv8-ce|portable( \([a-zA-Z0-9_ -]+\))?) before-pass=([0-9]+\.[0-9]{2}) s budget=([0-9]+) s hashed=([0-9]+) MiB cpu0=(\S*) kHz cpu([0-9]+)=(\S*) kHz governor=(\S*)\z') { if ($null -eq $g.Pace) { $g.Pace = & $P $l } else { $unexp += $l }; continue }
        if ($l -cmatch '^ROW (H''|H|R6) +(\S+) +(.*)\z') {
            $tag = $Matches[1]; $node = $Matches[2]; $rest = $Matches[3]
            if ($tag -ceq 'R6') {
                if ($rest -cmatch '^(misc|devinfo) size=([0-9]+) expect=([0-9]+)\z') { $r6 += [pscustomobject]@{ Name = $Matches[1]; Node = $node; Size = [long]$Matches[2]; Expect = [long]$Matches[3]; Before = ($armedAt -lt 0) } }
                else { $unexp += $l }
                continue
            }
            if ($tag -ceq 'H' -and ($rest -ceq '-> not read (an earlier row hit its time bound)' -or $rest -ceq '-> not read (stopped after an earlier failure)')) { $lines.Add((& $P $l)); if ($armedAt -lt 0) { $preRows += (& $P $l) } else { $unexp += $l }; continue }
            if ($rest -cmatch '^bytes=([0-9]+)/([0-9]+) sha256=([0-9a-f]{0,16})( \(expected value\))? -> (.+)\z') {
                $row = [pscustomobject]@{ Tag = $tag; Node = $node; Got = [long]$Matches[1]; Want = [long]$Matches[2]; Prefix = $Matches[3]; Expected = [bool]$Matches[4]; Verdict = $Matches[5]; Before = ($armedAt -lt 0); Line = $l }
                # an after-row that hit its time bound is an incomplete check, not a changed range (README s.5): REVIEW
                if ($row.Verdict -cne 'PASS') { $lines.Add((& $P $l)); if ($tag -ceq 'H' -and $row.Before) { $preRows += (& $P $l) } elseif ($tag -ceq "H'" -and $row.Verdict -ceq 'timeout') { $rev.Add("guard: an after-hash row hit its time bound (the invariance check is incomplete, not a changed range): $(& $P $l)") } else { $fail.Add("guard: a hash row did not pass: $(& $P $l)") } }
                if ($tag -ceq 'H') { $rowsB += $row } else { $rowsA += $row }
            } else { $unexp += $l }
            continue
        }
        if ($l -cmatch '^ARMED: (.*)\z') { if ($Matches[1] -ceq "strict allow=$($script:FsK1gGuardAllow)") { if ($armedAt -lt 0) { $armedAt = $i } } else { $rev.Add("guard: armed with '$(& $P $l)', not strict allow=$($script:FsK1gGuardAllow)"); if ($armedAt -lt 0) { $armedAt = $i } }; continue }
        if ($l -ceq 'SEAL: re-arming refused (EPERM) -> PASS') { $seal = $true; continue }
        if ($l -cmatch '^(CASE|ALLOW) ') { if ($l -cnotmatch '-> PASS\z') { $lines.Add((& $P $l)); $fail.Add("guard: $(& $P $l)") }; continue }
        if ($l -cmatch '^STOP: ') { $lines.Add((& $P $l)); $fail.Add("guard: $(& $P $l)"); continue }
        if ($l -cmatch '^FAIL: ') { $lines.Add((& $P $l)); $fail.Add("guard: $(& $P $l)"); continue }
        if ($l -cmatch '^Mechanism phase failed') { $lines.Add((& $P $l)); $fail.Add("guard: $(& $P $l)"); continue }
        if ($l -cmatch '^ABORT: ') { $lines.Add((& $P $l)); $abort.Add((& $P $l)); continue }
        if ($l -cmatch '^SKIP ') { $lines.Add((& $P $l)); continue }
        # the probe prints at most 24 failing lines in compact mode, then this count (the full log in RAM keeps them)
        if ($l -cmatch '^\.\.\. ([0-9]+) more failing lines suppressed( \(see /run/fsbg/full\.log\))?\z') { $lines.Add((& $P $l)); $supp += (& $P $l); continue }
        if ($l -cmatch '^WARN: ') { $lines.Add((& $P $l)); $rev.Add("guard: $(& $P $l) (a test-kernel warning on a device run)"); continue }
        if ($l -cmatch '^HASH verify: ([0-9]+) nodes, ([0-9]+) failed or changed\z') { $hv = @([int]$Matches[1], [int]$Matches[2]); continue }
        if ($l -cmatch '^POST guard counters: total=(-?[0-9]+)\z') { $post = [long]$Matches[1]; continue }
        if ($l -cmatch '^SERIES (\S+) +pass=([0-9]+) fail=([0-9]+)\z') {
            $sid = $Matches[1]; $sp = [int]$Matches[2]; $sf = [int]$Matches[3]
            if ($g.Series.Contains($sid)) { $dupS += $sid } else { $g.Series[$sid] = [pscustomobject]@{ Pass = $sp; Fail = $sf } }
            continue
        }
        if ($l -cmatch '^HASHDIGEST before=([0-9a-f]{32}) after=([0-9a-f]{32})\z') { $digest = @($Matches[1], $Matches[2]); continue }
        if ($l -cmatch '^FSBG-PROBE RESULT: ') { $res += $l; continue }
        $unexp += $l
    }
    $g.Lines = $lines.ToArray(); $g.Nodes = $nodes; $g.PostTotal = $post
    if ($null -ne $hv) { $g.HashVerify = "$($hv[0]) nodes, $($hv[1]) failed or changed" }
    if ($null -ne $digest) { $g.Digest = "before=$($digest[0]) after=$($digest[1])" }
    # the result line (exactly one, the probe's last line, equal to the step's "== result" line)
    $rkind = $null
    if ($res.Count -ne 1) { $rev.Add("guard: $($res.Count) FSBG-PROBE RESULT lines (exactly one expected)$(if ($Truncated) { '; the step was truncated' })") }
    else {
        $g.ResultLine = & $P $res[0]
        if ($res[0] -cmatch '^FSBG-PROBE RESULT: (PASS|FAIL|ABORT) nonce=(\S+) cases=([0-9]+) pass=([0-9]+) fail=([0-9]+) mode=(\S+)(.*)\z') {
            $rkind = $Matches[1]; $rn = $Matches[2]; $rc = [int]$Matches[3]; $rp = [int]$Matches[4]; $rf = [int]$Matches[5]; $rm = $Matches[6]; $rx = $Matches[7]
            $g.Result = $rkind
            if ($rkind -ceq 'FAIL' -and -not $hdrFlag) { $fail.Add("guard: the probe's result is FAIL ($(& $P $res[0]))") }
            if ($rf -gt 0 -and -not ($hdrFlag -and $rkind -ceq 'FAIL')) { $fail.Add("guard: the probe counted $rf failed case(s)") }
            if ($rn -cne $Nonce) { $rev.Add("guard: the probe's result carries nonce '$(& $P $rn)', not the record's $Nonce") }
            if ($rm -cne 'device') { $rev.Add("guard: the probe ran in mode '$(& $P $rm)', not device") }
            if ($rx -cmatch '\btestkernel\b') { $rev.Add('guard: the result says testkernel (a test-kernel run, never a device result)') }
            if ($rx -cmatch '\bforceq\b') { $rev.Add('guard: the result says forceq (a forced protected phase, VM only)') }
            if ($rx -cnotmatch '^( testkernel| forceq)*\z') { $rev.Add("guard: unexpected text after the result's mode ('$(& $P $rx)')") }
            if ($rc -ne $rp + $rf) { $rev.Add("guard: the result's cases=$rc is not pass+fail ($rp+$rf)") }
            if ($pl.Count -and @($pl | Where-Object { $_ -ne '' })[-1] -cne $res[0]) { $rev.Add('guard: the result line is not the probe''s last line') }
        } else { $rev.Add("guard: malformed result line '$(& $P $res[0])'") }
        if ($resHead -cne $res[0]) { $rev.Add("guard: the step's '== result' line ('$(& $P $resHead)') is not the probe's result line") }
    }
    $isAbort = ($rkind -ceq 'ABORT')
    # a probe stopped by fs-supervise's timer before any result and before arming (no ARMED line; the guard still in its
    # boot state): no armed guard test case was attempted, so its pre-arming rows are reported like an ABORT run's, not judged
    $stoppedUnarmed = ($res.Count -eq 0 -and @('timer-term', 'timer-kill') -ccontains $fsupEnd -and -not $resHead -and
                       $armedAt -lt 0 -and $gl.Count -ge 5 -and $gl[1] -ceq 'mode: protect' -and $gl[2] -ceq 'sealed: 0' -and $gl[4] -ceq 'modules_disabled: 0')
    # a hash row that failed before arming is the pre-check's refusal (ABORT: no armed guard test case attempted); in any other run it is a FAIL
    foreach ($pr in $preRows) { if ($isAbort -or $stoppedUnarmed) { $abort.Add("pre-check row: $pr") } else { $fail.Add("guard: a hash row before arming did not pass: $pr") } }
    # suppressed failing lines: failures existed (FAIL), or, in an ABORT run, more refused pre-check rows
    foreach ($sl in $supp) { if ($isAbort) { $abort.Add("pre-check: $sl") } else { $fail.Add("guard: $sl") } }
    # fs-supervise's report: end=exited with the probe's own exit code (0 PASS, 2 ABORT). The supervisor's timer stopping
    # the probe BEFORE it printed any result (timer-term/timer-kill, no RESULT line) is a timing artefact, not a guard
    # defect: REVIEW (review MAJOR). With a result line, anything but end=exited and the expected code is a FAIL.
    $wantCode = if ($isAbort) { 2 } else { 0 }
    $timerNoRes = ($res.Count -eq 0 -and @('timer-term', 'timer-kill') -ccontains $fsupEnd -and -not $resHead)
    # unarmed after the stop: no ARMED line, and /proc/fs_blkguard still in the boot state (nothing latched, armed or sealed)
    if ($stoppedUnarmed) { $g.TimeStop = $true; $rev.Add("guard: fs-supervise's timer stopped the probe before it printed a result ($($g.Fsup)) and before arming (the guard is still in its boot state): a time stop, no armed guard test case attempted$(if ($abort.Count) { " ($($abort -join ' / '))" })") }
    elseif ($timerNoRes) { $rev.Add("guard: fs-supervise's timer stopped the probe before it printed a result ($($g.Fsup)): a timing artefact, not a guard verdict") }
    elseif ($fsupEnd -cne 'exited' -or $fsupCode -ne $wantCode) { $fail.Add("guard: fs-supervise's report of the probe is not end=exited code=$wantCode ($($g.Fsup))") }
    if (-not $isAbort) {
        # (an ABORT run has no after rows: its HASHDIGEST "after" and the failed pre-check row's tally are expected; reported only)
        foreach ($s in $g.Series.Keys) { $v = $g.Series[$s]; if ($v.Fail -gt 0) { $fail.Add("guard: series $s has $($v.Fail) failed case(s)") } }
        if ($null -ne $digest -and $digest[0] -cne $digest[1]) { $fail.Add("guard: HASHDIGEST before $($digest[0]) != after $($digest[1]) (a hashed range changed)") }
        if ($null -ne $hv -and $hv[1] -ne 0) { $fail.Add("guard: HASH verify reports $($hv[1]) failed or changed node(s)") }
    }
    # /proc/fs_blkguard (first 8 lines, read after the proof): judged in a run that armed (not an ABORT before arming)
    if ($gl.Count -ge 7 -and $gl[6] -cmatch $script:FsK1gGuardDeniedRe) { $g.GuardTotal = [long]$Matches[15]; $g.Denied = $gl[6] }
    if ($timerNoRes) { $rev.Add('guard: /proc/fs_blkguard after a timer-stopped probe is reported, not judged') }
    elseif (-not $isAbort) {
        if ($Truncated -and $gl.Count -lt 8) { $rev.Add("guard: /proc/fs_blkguard shows $($gl.Count) of 8 lines (the step was truncated)") }
        else {
            $gd = @()
            for ($k = 0; $k -lt 8; $k++) {
                $have = if ($k -lt $gl.Count) { $gl[$k] } else { '<missing>' }
                $want = $script:FsK1gGuardLines[$k]
                if ($want -ceq '<denied>') { if ($have -cnotmatch $script:FsK1gGuardDeniedRe -or [long]$Matches[15] -le 0) { $gd += "line 7 '$(& $P $have)' (denied: ... total=<n>, total > 0)" } }
                elseif ($have -cne $want) { $gd += "line $($k + 1) '$(& $P $have)' (expected '$want')" }
            }
            if ($gl.Count -gt 8) { $gd += "$($gl.Count) lines (8 expected)" }
            if ($gd.Count) { $fail.Add("guard: /proc/fs_blkguard after the proof differs: $($gd -join '; ')") }
            if ($null -ne $g.GuardTotal -and $null -ne $post -and $g.GuardTotal -lt $post) { $rev.Add("guard: /proc/fs_blkguard total $($g.GuardTotal) is below the probe's POST total $post (counters only grow)") }
        }
    }
    # pre-arming rows that failed for a reason other than time (content differs, short read, ...) are review-class facts:
    # with them a time stop is not "only" a time stop (K1G REVIEW, not INCONCLUSIVE)
    $nonTimeRows = @($preRows | Where-Object { $_ -notmatch '-> (timeout|not read \(an earlier row hit its time bound\))$' })
    if ($stoppedUnarmed) {
        if ($nonTimeRows.Count) { $g.TimeStop = $false; $rev.Add("guard: pre-arming row(s) failed for a reason other than time: $($nonTimeRows -join ' / ')") }
        return [pscustomobject]$g     # no armed guard test case was attempted; the structure checks below apply to a completed run only
    }
    if ($isAbort) {
        if ($abort.Count -eq 0) { $abort.Add('the result is ABORT with no ABORT line') }
        if ($armedAt -ge 0) {
            # an ABORT after arming (a refused decoy re-check, or after-hash rows not verified in time): never PASS; the
            # FAIL-class facts above (a failed case, a changed range) still count; otherwise REVIEW
            $g.ArmedAbort = $true
            $rev.Add("guard: the probe stopped after arming (ABORT): $($abort -join ' / ')")
        } elseif (@($abort | Where-Object { $_.StartsWith('ABORT: time: ', [StringComparison]::Ordinal) }).Count) {
            # a pre-arming time stop: INCONCLUSIVE (Get-FsK1gOutcome), but only when nothing else in the report is a
            # review-class fact (a wrong boot state, header, nonce or mode keeps it K1G REVIEW)
            $g.TimeStop = ($rev.Count -eq 0 -and $nonTimeRows.Count -eq 0)
        }
        return [pscustomobject]$g     # the structure checks below apply to a completed run only
    }
    if ($abort.Count) { $rev.Add("guard: ABORT/pre-check lines in a run whose result is not ABORT: $($abort -join ' / ')") }
    # REVIEW-class structure (a run that armed)
    if (-not $hdr) { $rev.Add('guard: the probe header line is missing') }
    if (-not $pre) { $rev.Add('guard: the PRE guard line is missing or unexpected') }
    if ($null -eq $nodes) { $rev.Add('guard: the PRE boot storage visible line is missing') }
    if ($armedAt -lt 0) { $rev.Add('guard: the ARMED line is missing') }
    if (-not $seal -and @($fail | Where-Object { $_ -like 'guard: FAIL: *' }).Count -eq 0) { $rev.Add('guard: the SEAL line is missing') }
    if ($null -eq $hv) { $rev.Add('guard: the HASH verify line is missing') }
    if ($null -eq $post) { $rev.Add('guard: the POST guard counters line is missing') }
    if ($null -eq $digest) { $rev.Add('guard: the HASHDIGEST line is missing') }
    if ($null -eq $g.Pace) { $rev.Add('guard: the PRE pace line is missing') }
    if ($null -eq $g.Scope) { $rev.Add('guard: the PRE scope line (the FS-R-014 s.3.1 content-read allowlist) is missing') }
    if (@($g.PersistSkip).Count -ne 1 -or ($null -ne $g.Scope -and $g.PersistSkip[0] -cne $g.Scope)) { $rev.Add("guard: persist must be named once as never opened (PRE scope '$($g.Scope)', SKIP lines $(@($g.PersistSkip).Count))") }
    $okNodes = @($rowsB + $rowsA | Where-Object { $_.Expected } | ForEach-Object { $_.Node }) + @($r6 | ForEach-Object { $_.Node })
    $outside = @($rowsB + $rowsA | Where-Object { $_.Node -cnotmatch $script:FsK1gDecoyRowRe -and $okNodes -cnotcontains $_.Node } | ForEach-Object { $_.Node } | Select-Object -Unique)
    if ($outside.Count) { $rev.Add("guard: content row(s) on node(s) outside the FS-R-014 s.3.1 allowlist: $($outside -join ', ')") }
    if ($null -ne $g.Scope -and @($rowsB + $rowsA | Where-Object { $_.Node -ceq $g.Scope }).Count) { $rev.Add("guard: a content row on the never-opened node $($g.Scope)") }
    if ($unexp.Count) { $rev.Add("guard: unexpected probe line(s): $(@($unexp | Select-Object -First 3 | ForEach-Object { "'$(& $P $_)'" }) -join ', ')$(if ($unexp.Count -gt 3) { " (+$($unexp.Count - 3))" })") }
    if ($dupS.Count) { $rev.Add("guard: series listed twice: $($dupS -join ', ')") }
    # the readback rows R1-R5 before and after ARMED, and R6
    foreach ($rk in $script:FsK1gRootRows.Keys) {
        $x = $script:FsK1gRootRows[$rk]
        $b = @($rowsB | Where-Object { $_.Expected -and $_.Want -eq $x[1] -and $_.Prefix -ceq $x[2] })
        $a = @($rowsA | Where-Object { $_.Expected -and $_.Want -eq $x[1] -and $_.Prefix -ceq $x[2] })
        $g.Rows[$rk] = [pscustomobject]@{ Part = $x[0]; Range = $x[1]; Prefix = $x[2]; Before = $(if ($b.Count -eq 1) { "$($b[0].Node) $($b[0].Prefix) $($b[0].Verdict)" } else { "$($b.Count) rows" }); After = $(if ($a.Count -eq 1) { "$($a[0].Node) $($a[0].Prefix) $($a[0].Verdict)" } else { "$($a.Count) rows" }) }
        if ($b.Count -ne 1 -or -not $b[0].Before -or $b[0].Got -ne $x[1] -or $b[0].Verdict -cne 'PASS') { $rev.Add("guard: readback row $rk ($($x[0]), $($x[1]) bytes, sha256 $($x[2])...) before arming is missing or does not match ($($b.Count) rows)") }
        if ($a.Count -ne 1 -or $a[0].Before -or $a[0].Got -ne $x[1] -or $a[0].Verdict -cne 'PASS') { $rev.Add("guard: readback row $rk ($($x[0])) after the cases (ROW H') is missing or does not match ($($a.Count) rows)") }
        elseif ($b.Count -eq 1 -and $a[0].Node -cne $b[0].Node) { $rev.Add("guard: readback row $rk was read from $($b[0].Node) before and $($a[0].Node) after") }
    }
    $nExp = @($rowsB | Where-Object { $_.Expected }).Count + @($rowsA | Where-Object { $_.Expected }).Count
    if ($nExp -ne 10) { $rev.Add("guard: $nExp expected-value rows (10 expected: R1-R5 before and after)") }
    foreach ($nm in $script:FsK1gR6.Keys) {
        $rr = @($r6 | Where-Object { $_.Name -ceq $nm })
        $g.R6[$nm] = $(if ($rr.Count -eq 1) { "$($rr[0].Node) size=$($rr[0].Size) expect=$($rr[0].Expect)" } else { "$($rr.Count) rows" })
        if ($rr.Count -ne 1 -or -not $rr[0].Before -or $rr[0].Size -ne $script:FsK1gR6[$nm] -or $rr[0].Expect -ne $script:FsK1gR6[$nm]) { $rev.Add("guard: the R6 row $nm (size $($script:FsK1gR6[$nm])) before arming is missing or does not match") }
    }
    # the series: the device list exactly (no Q11, no C*, no S5), and the counts
    $extra = @($g.Series.Keys | Where-Object { $script:FsK1gSeries -cnotcontains $_ })
    if ($extra.Count) { $rev.Add("guard: series not in the device list (Q11, C* and S5 never run on a Quest): $($extra -join ', ')") }
    $miss = @($script:FsK1gSeries | Where-Object { -not $g.Series.Contains($_) })
    if ($miss.Count) { $rev.Add("guard: required series missing: $($miss -join ', ')") }
    $cnt = { param([string]$s) if ($g.Series.Contains($s)) { $g.Series[$s].Pass + $g.Series[$s].Fail } else { -1 } }
    $inc = @()
    if ($null -ne $nodes) { foreach ($s in 'Q1', 'Q2', 'Q3') { if ((& $cnt $s) -ne $nodes - 1) { $inc += "$s=$(& $cnt $s) (visible block nodes $nodes minus persist = $($nodes - 1))" } } }
    foreach ($s in 'Q4', 'Q5', 'Q6', 'Q7', 'Q12', 'Q13', 'Q14') { if ((& $cnt $s) -ne $script:FsK1gWholeDisks) { $inc += "$s=$(& $cnt $s) ($($script:FsK1gWholeDisks) expected)" } }
    foreach ($s in 'Q8', 'Q9') { if ((& $cnt $s) -lt 1) { $inc += "$s=$(& $cnt $s) (at least 1)" } }
    if ((& $cnt 'Q10') -ne $script:FsK1gUfsBsg) { $inc += "Q10=$(& $cnt 'Q10') ($($script:FsK1gUfsBsg) ufs-bsg node expected)" }
    if ($null -ne $hv -and ((& $cnt 'H') -ne $hv[0] -or (& $cnt "H'") -ne $hv[0])) { $inc += "H=$(& $cnt 'H') H'=$(& $cnt "H'") (HASH verify $($hv[0]) nodes)" }
    # the pinned decoy and readback counts (the probe's device-mode case table)
    foreach ($s in $script:FsK1gFixedCounts.Keys) { if ((& $cnt $s) -ne $script:FsK1gFixedCounts[$s]) { $inc += "$s=$(& $cnt $s) ($($script:FsK1gFixedCounts[$s]) expected)" } }
    if ((& $cnt 'A3') -ne $script:FsK1gWholeDisks) { $inc += "A3=$(& $cnt 'A3') ($($script:FsK1gWholeDisks) whole sd disks expected)" }
    foreach ($s in 'H', "H'") { if ((& $cnt $s) -ne $script:FsK1gHashRows) { $inc += "$s=$(& $cnt $s) ($($script:FsK1gHashRows) content rows expected: 7 decoys, R1-R5, R7d, R8)" } }
    if ($inc.Count) { $rev.Add("guard: the case counts are inconsistent: $($inc -join '; ')") }
    if ($null -ne $post -and $post -le 0) { $rev.Add("guard: the POST guard counters total is $post (the cases move counters)") }
    [pscustomobject]$g
}

# A timer-stopped probe (no result, the guard unarmed) is a time stop only if its review facts are exactly the ones such a
# stop produces (no result line, the timer, /proc not judged); anything else keeps it K1G REVIEW (review MINOR 1).
function Test-FsK1gTimeStopOnly($g) {
    foreach ($x in $g.Review) {
        if ($x -cnotmatch '^guard: (0 FSBG-PROBE RESULT lines|fs-supervise''s timer stopped the probe before it printed a result .* and before arming|/proc/fs_blkguard after a timer-stopped probe is reported, not judged)') { return $false }
    }
    return $true
}

function Get-FsK1gOutcome {
    param([Parameter(Mandatory)]$Fsb1, [bool]$Collected = $true, [string]$Banner, [string]$ConfigSha, [int]$Modules = 95, [string]$Nonce = '')
    $facts = New-Object System.Collections.Generic.List[string]
    $fails = New-Object System.Collections.Generic.List[string]
    $warn = New-Object System.Collections.Generic.List[string]
    $o = [ordered]@{ Outcome = 'INCONCLUSIVE'; Reason = ''; Facts = $facts; Failing = $fails; Warnings = $warn; WarningCount = $null; BugCount = $null
                     MemTotal = $null; MemTotalOk = $false; MemTotalWhy = 'not reported'; KmsgFirst = $null; Steps = @(); Truncated = @(); Wrapped = $null; TaintLines = @(); TaintCount = $null
                     Guard = $null; Stages = $null }
    if (-not $Collected -or $null -eq $Fsb1 -or -not $Fsb1.Ok) {
        $o.Reason = $(if ($null -ne $Fsb1 -and -not $Fsb1.Ok) { "no valid record (FSB1 $($Fsb1.Reason) $($Fsb1.Detail))" } else { 'no complete record' })
        return [pscustomobject]$o
    }
    $out = @{}
    $bad = @(); $trunc = @{}
    foreach ($st in $Fsb1.Steps) {
        $id = [string]$st['id']
        $out[$id] = $script:FsK1gLatin1.GetString([byte[]]$st['out'])
        $o.Steps += [pscustomobject]@{ I = $st['i']; Id = $id; End = $st['end']; Code = $st['code']; Sig = $st['sig']; OutLen = $st['out_len']; ErrLen = $st['err_len'] }
        if ($st.ContainsKey('out_total') -and $st.ContainsKey('out_kept') -and [long]$st['out_total'] -gt [long]$st['out_kept']) { $o.Truncated += "$id ($($st['out_total']) bytes, $($st['out_kept']) kept)"; $trunc[$id] = $true }
        if ($st['end'] -cne 'exited' -or [long]$st['code'] -ne 0) { $bad += "step $($st['i']) $id end=$($st['end']) code=$($st['code'])" }
        elseif ([long]$st['err_len'] -ne 0) { $bad += "step $($st['i']) $id wrote $($st['err_len']) bytes to stderr" }
    }
    # the kernel-log findings are reported whatever the outcome (FS-R-012 s.3)
    $k = [string]$out['kmsg']
    if ($k -cmatch '(?m)^== kmsg-lines (\d+) first=(.*)$') { $o.KmsgFirst = $Matches[2].TrimEnd("`r"); $facts.Add("kmsg: $($Matches[1]) lines, first '$(ConvertTo-FsK1gPrintable $o.KmsgFirst)'") }
    if ($k -cmatch '(?m)^== warnings (\d+) warning-lines, (\d+) bug-lines, (\d+) lines$') {
        $o.WarningCount = [long]$Matches[1]; $o.BugCount = [long]$Matches[2]
        $wl = $k.Substring($k.IndexOf($Matches[0]) + $Matches[0].Length).Split("`n") | Where-Object { $_ -ne '' }
        foreach ($l in $wl) { $warn.Add((ConvertTo-FsK1gPrintable $l)) }
    }
    $o.Wrapped = -not ([string]$o.KmsgFirst -cmatch '^(<[0-9]+>)?\[\s*0\.0+')
    if ($k -cmatch '(?m)^== taint-lines (\d+)\r?$') { $o.TaintCount = [long]$Matches[1]; $after = $k.Substring($k.IndexOf($Matches[0]) + $Matches[0].Length).Split("`n"); foreach ($l in $after) { if ($l.StartsWith('== ')) { break }; if ($l.Trim() -ne '') { $o.TaintLines += (ConvertTo-FsK1gPrintable $l.TrimEnd("`r")) } } }
    # FS-R-013 s.2: MemTotal required (reported in every result)
    $mt = Test-FsK1gMemTotal ([string]$out['mem'])
    $o.MemTotalOk = $mt.Ok; $o.MemTotalWhy = $mt.Why; if ($mt.Ok) { $o.MemTotal = "$($mt.Value) kB" }
    # the guard facts (step 9), reported in every result
    $o.Guard = Get-FsK1gGuardFacts ([string]$out['blkguard']) $Nonce ([bool]$trunc['blkguard'])
    if ($bad.Count) { $o.Outcome = 'INTEGRITY FAULT'; $o.Reason = ($bad -join '; '); return [pscustomobject]$o }
    # the K1a facts, with the K1g banner and product
    $kn = [string]$out['kernel']
    $pv = if ($kn -cmatch "(?m)^== proc-version\n(.*)$") { $Matches[1] } else { '' }
    if ($pv -ceq $Banner) { $facts.Add('kernel: /proc/version is the pinned K1g banner (our build booted)') } else { $fails.Add("kernel: /proc/version '$(ConvertTo-FsK1gPrintable $pv)' is not the pinned K1g banner") }
    $c = [string]$out['config']
    if ($c -cmatch '(?m)^== config_sha256 ([0-9a-f]{64})$' -and $Matches[1] -ceq $ConfigSha) { $facts.Add("config: sha256(zcat /proc/config.gz) = $ConfigSha (the exact K1a config)") }
    else { $fails.Add('config: the running config is not the gated K1a config (or not reported)') }
    $md = [string]$out['modules']
    $ready = $md -cmatch "(?m)STAGE=MODULES_READY ok=$Modules fail=0 "
    $loaded = $md -cmatch "(?m)^== loaded $Modules$"
    $mf = @([regex]::Matches($md, '(?m)MODULE_FAIL (\S+)') | ForEach-Object { $_.Groups[1].Value })
    if ($ready -and $loaded -and $mf.Count -eq 0) { $facts.Add("modules: MODULES_READY ok=$Modules fail=0; $Modules in /proc/modules; no MODULE_FAIL") }
    else { $fails.Add("modules: ready=$ready loaded=$loaded MODULE_FAIL=$($mf -join ',')") }
    if ($k -cmatch '(?m)^== modver-matches 0\r?$') { $facts.Add('kmsg: no symbol-version or vermagic refusal') }
    else { $fails.Add('kmsg: symbol-version or vermagic lines in the kernel log (or not reported)') }
    $fsx = [string]$out['fs']
    if ($fsx -cmatch '(?m)^nodev\s+devtmpfs$') { $facts.Add('fs: devtmpfs registered (DEVTMPFS=y)') } else { $fails.Add('fs: devtmpfs not in /proc/filesystems') }
    $u = [string]$out['usb']
    $prodOk = if ($Nonce) { $u -cmatch ('(?m)^== product FrameShift K1g serial=FS-' + $Nonce + '$') } else { $u -cmatch '(?m)^== product FrameShift K1g serial=FS-[0-9a-f]{16}$' }
    if ($u -cmatch '(?m)^== udc a600000\.dwc3 state=configured$' -and $u -cmatch '(?m)^== config-functions acm\.gs0 $' -and $prodOk) { $facts.Add('usb: UDC a600000.dwc3 configured; ACM only; product FrameShift K1g, serial FS-<nonce>') }
    else { $fails.Add('usb: the gadget is not the bound ACM-only "FrameShift K1g" gadget of this nonce') }
    $gd = $o.Guard
    foreach ($f in $gd.Fail) { $fails.Add($f) }
    if ($fails.Count) { $o.Outcome = 'K1G FAIL'; $o.Reason = ($fails -join '; '); return [pscustomobject]$o }
    if ($null -eq $o.WarningCount) { $o.Outcome = 'K1G FAIL'; $o.Reason = 'kmsg: the warning counts are missing'; return [pscustomobject]$o }
    $facts.Add("guard: $($gd.ResultLine); POST total $($gd.PostTotal); /proc/fs_blkguard total $($gd.GuardTotal); HASH verify $($gd.HashVerify); HASHDIGEST $($gd.Digest)")
    # PID 1's stages (log step) and the BLKGUARD_DONE result
    $lg = [string]$out['log']; $sv = @()
    $si = $lg.IndexOf("== fs.stages`n")
    $stg = if ($si -ge 0) { @($lg.Substring($si + 13).Split("`n") | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne '' }) } else { @() }
    $o.Stages = ($stg -join ',')
    $head = @($stg | Select-Object -First $script:FsK1gStages.Count)
    $tail = @($stg | Select-Object -Skip $script:FsK1gStages.Count)
    if ($si -lt 0) { $sv += 'the log step has no fs.stages section' }
    elseif (($head -join ',') -cne ($script:FsK1gStages -join ',') -or @($tail | Where-Object { $_ -cne 'HOST_ACK' }).Count -or $tail.Count -gt 1) { $sv += "PID 1's stages are '$(ConvertTo-FsK1gPrintable $o.Stages)', not $($script:FsK1gStages -join ',')[,HOST_ACK]" }
    $bd = [regex]::Matches($lg, '(?m)STAGE=BLKGUARD_DONE result=(\S*)')
    if ($bd.Count -ne 1) { $sv += "fs.log has $($bd.Count) STAGE=BLKGUARD_DONE lines (exactly one expected)" }
    elseif ($bd[0].Groups[1].Value -cne $(if ($gd.Result) { [string]$gd.Result } else { 'none' })) { $sv += "fs.log's STAGE=BLKGUARD_DONE result=$($bd[0].Groups[1].Value) is not the probe's result $(if ($gd.Result) { $gd.Result } else { 'none (no result line)' })" }
    $rv = @()
    if ($gd.Result -ceq 'ABORT' -and -not $gd.ArmedAbort) { $rv += "the guard probe ABORTed before arming: no armed guard test case was attempted ($($gd.Abort -join ' / '))" }
    foreach ($x in $gd.Review) { $rv += $x }
    $nTime = $rv.Count                 # the guard's own facts; everything added below is a review fact of its own
    foreach ($x in $sv) { $rv += "stages: $x" }
    if (-not $mt.Ok) { $rv += "mem: $($mt.Why) (FS-R-013 s.2: MemTotal is required; this blocks progression and is never a reason for another attempt)" }
    if ($warn.Count -gt 0 -or $o.WarningCount -gt 0 -or $o.BugCount -gt 0) { $rv += "the kernel log has $($o.WarningCount) WARNING and $($o.BugCount) BUG/oops-class lines ($($warn.Count) lines listed; FS-R-012 s.3)" }
    if ($o.Wrapped) { $rv += "the kernel log had wrapped (first line '$(ConvertTo-FsK1gPrintable ([string]$o.KmsgFirst))', not at boot time): earlier lines, including any boot WARNING, were not seen" }
    if (@($o.Truncated).Count) { $rv += "step output truncated at its cap: $(@($o.Truncated) -join '; ')" }
    # INCONCLUSIVE only when the time stop is the only review-class fact: a kernel WARNING, MemTotal missing, a wrapped
    # log, a truncated step or a stage mismatch alongside it keeps the outcome K1G REVIEW (review MINOR 1)
    $timeOnly = $gd.TimeStop -and ($rv.Count -eq $nTime) -and ($gd.Result -ceq 'ABORT' -or (Test-FsK1gTimeStopOnly $gd))
    if ($gd.TimeStop -and -not $timeOnly) { $rv += 'the guard proof also stopped on time before arming (no armed guard test case attempted); with the facts above this is K1G REVIEW, not INCONCLUSIVE' }
    if ($timeOnly) {
        # README s.5: a pre-arming time stop is not a guard verdict and not a K1g result: INCONCLUSIVE (it blocks progression;
        # a nonce-only repeat may be PROPOSED to the Chair, FS-R-013 s.5; never automatic)
        $o.Outcome = 'INCONCLUSIVE'
        $o.Reason = "the guard proof stopped on time before arming (no armed guard test case attempted; the guard was never armed and modules were not latched; decoy set-up and hashing had run); not a guard verdict. A nonce-only repeat may be proposed to the Chair (FS-R-013 s.5), never automatic. Facts: $($rv -join '; ')"
    } elseif ($rv.Count) {
        $o.Outcome = 'K1G REVIEW'
        $o.Reason = "no FAIL-class fact; review before any further run: $($rv -join '; ')"
    } else {
        $o.Outcome = 'K1G PASS'; $o.Reason = 'every K1g fact holds: our K1g build booted with the exact K1a config and 95 modules; the guard proof PASSED (armed strict and sealed, every series passed, the readback ranges unchanged); MemTotal valid; no kernel WARNING/BUG/oops-class line'
    }
    [pscustomobject]$o
}

function Invoke-FsK1gClassifyDir {
    param([Parameter(Mandatory)][string]$CollectDir, [string]$ObserveDir = '', [string]$Banner, [string]$ConfigSha, [int]$Modules = 95, [bool]$AllowReplay = $false)
    $cj = Join-Path $CollectDir 'collect.json'
    if (-not (Test-Path -LiteralPath $cj -PathType Leaf)) { throw "no collect.json in $CollectDir" }
    $c = [IO.File]::ReadAllText($cj) | ConvertFrom-Json
    if ($c.Stage -cne 'k1g' -or $c.Exp -cne 'k1g') { throw "collect.json is not a K1g session (stage '$($c.Stage)', exp '$($c.Exp)')" }
    $raw = Join-Path $CollectDir 'capture.raw'
    [byte[]]$b = [IO.File]::ReadAllBytes($raw)
    $sha = Get-Fsb1Sha256Hex $b
    $consistent = ($sha -ceq [string]$c.Capture.Sha256) -and [bool]$c.Capture.Consistent
    $fsb1 = $null
    if ($c.ValveSent -and $c.Challenge -cmatch '^[0-9a-f]{32}\z') {
        $fsb1 = Test-Fsb1Record -Bytes $b -Exp 'k1g' -Nonce ([string]$c.Nonce) -Challenge ([string]$c.Challenge) -Steps $script:FsK1gSteps
    }
    $o = Get-FsK1gOutcome -Fsb1 $fsb1 -Collected ($consistent -and [string]$c.Status -like 'COLLECTED*') -Banner $Banner -ConfigSha $ConfigSha -Modules $Modules -Nonce ([string]$c.Nonce)
    $isReplay = ($c.PSObject.Properties['Replay'] -and $null -ne $c.Replay) -or ($c.PSObject.Properties['FixtureOverrides'] -and $null -ne $c.FixtureOverrides)
    $bind = @(); $serial = ''; $obSha = ''
    if ($isReplay -and -not $AllowReplay) { $bind += 'collect.json is a replay or carries fixture overrides (not a live collection)' }
    if (-not $AllowReplay) {
        $oj = if ($ObserveDir) { Join-Path $ObserveDir 'observe.json' } else { '' }
        if (-not $oj -or -not (Test-Path -LiteralPath $oj -PathType Leaf)) { $bind += 'no observe.json of the attempt (-ObserveDir)' }
        else {
            $ob = [IO.File]::ReadAllText($oj) | ConvertFrom-Json
            if ([string]$ob.Nonce -cne [string]$c.Nonce) { $bind += "observe.json nonce $($ob.Nonce) is not the collected $($c.Nonce)" }
            if ([string]$ob.Stage -cne 'k1g') { $bind += "observe.json stage '$($ob.Stage)' is not k1g" }
            if (-not (Test-FsK1gUnit ([string]$ob.Serial))) { $bind += "observe.json unit '$($ob.Serial)' is not a K1g unit (Unit 2 QUEST3UNIT2, Unit 1 QUEST3UNIT1)" }
            else { $serial = [string]$ob.Serial; $obSha = Get-FsK1gFileSha $oj }
        }
    }
    if ($bind.Count) { $o.Reason = "not tied to a live, observed K1g attempt ($($bind -join '; ')); the record said: $($o.Outcome) ($($o.Reason))"; $o.Outcome = 'INCONCLUSIVE' }
    $o | Add-Member NoteProperty Fixture ([bool]($isReplay -and $AllowReplay))
    $o | Add-Member NoteProperty CaptureSha256 $sha
    $o | Add-Member NoteProperty CaptureConsistent $consistent
    $o | Add-Member NoteProperty Nonce ([string]$c.Nonce)
    $o | Add-Member NoteProperty CollectStatus ([string]$c.Status)
    $o | Add-Member NoteProperty Bound ([bool](-not $AllowReplay -and $bind.Count -eq 0))
    $o | Add-Member NoteProperty Serial $serial
    $o | Add-Member NoteProperty ObserveJsonSha256 $obSha
    $o | Add-Member NoteProperty CollectJsonSha256 (Get-FsK1gFileSha $cj)
    $o | Add-Member NoteProperty DoneSent ([bool]$c.DoneSent)
    $o
}

# The outcome record next to the attempt's observe.json (only for a result bound to a live, observed attempt with its
# after-session facts). Written once (FileMode CreateNew), never replaced; it carries the banner (SHA-256), config SHA-256,
# module count, MemTotal and the guard's result line that the classifier checked.
function Write-FsK1gClassifyRecord([Parameter(Mandatory)]$O, [Parameter(Mandatory)][string]$ObserveDir, [DateTime]$NowUtc = [DateTime]::UtcNow,
                                   [string]$Banner = $script:FsK1gPinBanner, [string]$ConfigSha = $script:FsK1gPinConfigSha, [int]$Modules = $script:FsK1gPinModules,
                                   $After = $null, [string]$ChecklistSha256 = '') {
    if (-not $O.Bound -or $O.Fixture -or -not (Test-FsK1gUnit ([string]$O.Serial)) -or $null -eq $After) { return $null }
    $p = Join-Path $ObserveDir 'classify-k1g.json'
    if (Test-Path -LiteralPath $p) { throw "classify-k1g.json already exists ($p): an outcome record is written once and never replaced" }
    $gr = if ($O.PSObject.Properties['Guard'] -and $null -ne $O.Guard) { [string]$O.Guard.ResultLine } else { '' }
    $mt = if ($O.PSObject.Properties['MemTotal']) { [string]$O.MemTotal } else { '' }
    $rec = [ordered]@{ Schema = $script:FsK1gClassifySchema; Utc = $NowUtc.ToUniversalTime().ToString('o'); Nonce = [string]$O.Nonce; Serial = [string]$O.Serial
                       Unit = (Get-FsK1gUnitName ([string]$O.Serial)); Outcome = [string]$O.Outcome; Reason = [string]$O.Reason; Fixture = [bool]$O.Fixture
                       CaptureSha256 = [string]$O.CaptureSha256; CollectJsonSha256 = [string]$O.CollectJsonSha256; ObserveJsonSha256 = [string]$O.ObserveJsonSha256
                       ClassifierSha256 = (Get-FsK1gFileSha (Join-Path $script:FsK1gClsDir 'fs-classify-k1g.ps1'))
                       BannerSha256 = (Get-FsK1gTextSha $Banner); ConfigSha = $ConfigSha; Modules = [string]$Modules; MemTotal = $mt; GuardResult = $gr
                       After = $After; ChecklistSha256 = $ChecklistSha256 }
    [byte[]]$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((($rec | ConvertTo-Json -Depth 8) + "`n"))
    $fs = [IO.File]::Open($p, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    $p
}

# The attempt's after-session facts: the one PASS phase F entry of this nonce in the attempt's checklist (observe.json
# ChecklistFile), this serial, written by the the K1g sign-off tooling (private) beside this file. Returns @{ Ok; Why; After; Sha256 }.
function Get-FsK1gAfterFacts([string]$ObserveDir, [string]$Nonce, [string]$Serial) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; After = $null; Sha256 = $null } }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    try { $ob = [IO.File]::ReadAllText((Join-Path $ObserveDir 'observe.json')) | ConvertFrom-Json } catch { return (& $no 'observe.json unreadable') }
    $cf = [string](& $pv $ob 'ChecklistFile')
    if (-not $cf -or -not (Test-Path -LiteralPath $cf -PathType Leaf)) { return (& $no "the attempt's checklist '$cf' is missing") }
    try { $j = [IO.File]::ReadAllText($cf) | ConvertFrom-Json } catch { return (& $no "the checklist $cf is unreadable") }
    $fs = @(@(& $pv $j 'Entries') | Where-Object { [string](& $pv $_ 'Phase') -ceq 'F' -and [string](& $pv $_ 'Result') -ceq 'PASS' -and [string](& $pv $_ 'Nonce') -ceq $Nonce })
    if ($fs.Count -eq 0) { return (& $no "phase F (after the session) has not passed for nonce $Nonce in ${cf}: run the K1g sign-off tooling (private) -Phase F once the follow-ups are finished, then classify again") }
    if ($fs.Count -ne 1) { return (& $no "${cf} holds $($fs.Count) PASS phase F entries for nonce $Nonce (exactly one is allowed)") }
    $f = $fs[0]
    if ([string](& $pv $f 'Serial') -cne $Serial) { return (& $no "the phase F entry of $cf is for unit '$(& $pv $f 'Serial')', not $Serial") }
    if ([string](& $pv $f 'ToolSha256') -cne (Get-FsK1gFileSha (Join-Path $script:FsK1gClsDir 'the K1g sign-off tooling (private)'))) { return (& $no "the phase F entry of $cf was not written by the the K1g sign-off tooling (private) beside this file") }
    $a = & $pv $f 'After'
    if ($null -eq $a) { return (& $no "the phase F entry of $cf holds no after-session facts") }
    [pscustomobject]@{ Ok = $true; Why = "phase F of $cf"; After = $a; Sha256 = (Get-FsK1gFileSha $cf) }
}

# The report lines of an outcome (the CLI prints them; tests read them).
function Format-FsK1gReport($o) {
    $r = New-Object System.Collections.Generic.List[string]
    if ($o.PSObject.Properties['Fixture'] -and $o.Fixture) { $r.Add('FIXTURE: an offline replay (-AllowReplay): not a run result') }
    $r.Add("OUTCOME: $($o.Outcome)")
    $r.Add((ConvertTo-FsK1gPrintable "REASON:  $($o.Reason)"))
    if ($o.PSObject.Properties['Nonce']) { $r.Add("NONCE:   $($o.Nonce)  capture sha256=$($o.CaptureSha256) consistent=$($o.CaptureConsistent)  collector=$($o.CollectStatus) fs-done-sent=$($o.DoneSent)") }
    foreach ($f in $o.Facts) { $r.Add((ConvertTo-FsK1gPrintable "FACT:    $f")) }
    foreach ($f in $o.Failing) { $r.Add((ConvertTo-FsK1gPrintable "FAILING: $f")) }
    $r.Add("MEMTOTAL: $(if ($o.MemTotalOk) { $o.MemTotal } else { "NOT VALID: $($o.MemTotalWhy)" }) (FS-R-013 s.2: required)")
    $r.Add("KERNEL WARNINGS (FS-R-012 s.3, every phase; the log from boot): $(if ($null -ne $o.WarningCount) { "$($o.WarningCount) WARNING, $($o.BugCount) BUG/oops-class, $($o.Warnings.Count) lines" } else { 'not reported' })")
    foreach ($w in $o.Warnings) { $r.Add("  $w") }
    $r.Add("TAINT NOTES (reported, never a FAIL): $(if ($null -ne $o.TaintCount) { $o.TaintCount } else { 'not reported' })")
    foreach ($tl in @($o.TaintLines)) { $r.Add("  $tl") }
    if (@($o.Truncated).Count) { $r.Add("TRUNCATED: $(@($o.Truncated) -join '; ')") }
    $g = $o.Guard
    if ($null -ne $g) {
        $r.Add("GUARD RESULT: $(if ($g.ResultLine) { $g.ResultLine } else { 'not reported' })")
        $r.Add("GUARD COUNTERS: POST total=$(if ($null -ne $g.PostTotal) { $g.PostTotal } else { '-' }); /proc/fs_blkguard total=$(if ($null -ne $g.GuardTotal) { $g.GuardTotal } else { '-' })$(if ($g.Denied) { " ($(ConvertTo-FsK1gPrintable $g.Denied))" })")
        $r.Add("GUARD FSUP1: $($g.Fsup); err-bytes $(if ($null -ne $g.ErrBytes) { $g.ErrBytes } else { '-' })")
        $r.Add("GUARD PACE: $(if ($g.Pace) { $g.Pace } else { 'not reported' })")
        $r.Add("GUARD HASH: verify $(if ($g.HashVerify) { $g.HashVerify } else { '-' }); HASHDIGEST $(if ($g.Digest) { $g.Digest } else { '-' }); visible block nodes $(if ($null -ne $g.Nodes) { $g.Nodes } else { '-' })")
        foreach ($rk in $g.Rows.Keys) { $x = $g.Rows[$rk]; $r.Add("GUARD ROW ${rk}: $($x.Part) $($x.Range) bytes expect $($x.Prefix): before $($x.Before); after $($x.After)") }
        foreach ($nm in $g.R6.Keys) { $r.Add("GUARD ROW R6: $nm $($g.R6[$nm])") }
        $r.Add("GUARD SERIES: $(if ($g.Series.Count) { (@($g.Series.Keys | ForEach-Object { "$_ $($g.Series[$_].Pass)/$($g.Series[$_].Fail)" }) -join ', ') } else { 'none' }) (pass/fail)")
        foreach ($l in @($g.Lines)) { $r.Add("GUARD LINE: $l") }
        foreach ($l in @($g.GuardLines)) { $r.Add("GUARD STATE: $l") }
    }
    if ($o.PSObject.Properties['Stages'] -and $o.Stages) { $r.Add("STAGES: $($o.Stages)") }
    $r.Add('MACHINE SIDE ONLY: the return to fastboot is checked at AF (<withheld capture tool> -Phase AF)')
    $r.Add("AFTER-ROWS (FS-R-013 s.3, verbatim): $($script:FsK1gChairSentence)")
    $r.Add("K1G ADDITION: $($script:FsK1gAddition)")
    $r.ToArray()
}

if ($script:FsK1gClsInvocation -eq '.') { return }
$exit = 70
try {
    if (-not $CollectDir) { Write-Output 'usage: fs-classify-k1g.ps1 -CollectDir <dir> [-ObserveDir <dir>]'; exit 64 }
    if ($ObserveDir) {
        if ($Banner -cne $script:FsK1gPinBanner -or $ConfigSha -cne $script:FsK1gPinConfigSha -or $Modules -ne $script:FsK1gPinModules) {
            Write-Output 'REFUSED: with -ObserveDir (a recorded outcome) -Banner, -ConfigSha and -Modules must be the pinned values (leave them out); nothing classified, nothing recorded'; exit 64 }
        $rx = Join-Path $ObserveDir 'classify-k1g.json'
        if (Test-Path -LiteralPath $rx) {
            $ox = try { [string]([IO.File]::ReadAllText($rx) | ConvertFrom-Json).Outcome } catch { 'unreadable' }
            Write-Output "NOT RECORDED: the outcome record $rx already exists (recorded outcome: $ox) and is kept; this run classifies and records nothing"; exit 64 }
    }
    $o = Invoke-FsK1gClassifyDir -CollectDir $CollectDir -ObserveDir $ObserveDir -Banner $Banner -ConfigSha $ConfigSha -Modules $Modules -AllowReplay ([bool]$AllowReplay)
    foreach ($l in (Format-FsK1gReport $o)) { Write-Output $l }
    if ($ObserveDir) { Write-Output "OBSERVE: $ObserveDir" }
    if ($ObserveDir -and $o.Bound) { $aft = Get-FsK1gAfterFacts $ObserveDir $o.Nonce $o.Serial; if (-not $aft.Ok) { Write-Output "NOT RECORDED: $($aft.Why)" } }
    if ($ObserveDir -and $o.Bound -and $aft.Ok) { $rp = Write-FsK1gClassifyRecord -O $o -ObserveDir $ObserveDir -Banner $Banner -ConfigSha $ConfigSha -Modules $Modules -After $aft.After -ChecklistSha256 $aft.Sha256; if ($rp) { Write-Output "RECORDED: $rp (unit $(Get-FsK1gUnitName $o.Serial) $($o.Serial); report this result to the PM before any further K1g attempt)" } }
    $exit = switch ($o.Outcome) { 'K1G PASS' { 40 } 'K1G REVIEW' { 41 } 'K1G FAIL' { 42 } 'INTEGRITY FAULT' { 43 } default { 44 } }
} catch {
    Write-Output (ConvertTo-FsK1gPrintable "ERROR: $($_.Exception.Message)")
    $exit = 70
}
exit $exit
