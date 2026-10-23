# FrameShift N1 - the units and the order (Windows PowerShell 5.1; a library: dot-source it). Read only: no device, no
# network, no write. Used by the N1 sign-off tooling (private) (phase A) and fs-observe-n1.ps1 (the attempt gate).
#
# N1 (an NCM link next to the ACM console; FS-R-013 s.5, s.9) uses the K1a kernel, so it comes AFTER K1a on each unit
# (FS-R-013 s.5: K1a -> K1g -> K1i, with N1 before the RAM-root transfer):
#   - N1 on Unit 2 (QUEST3UNIT2) opens only after BOTH K1a attempts and K1g on Unit 2 (coordinator decision
#     2026-10-16: the write guard is proven before any further new image): every K1a attempt of both units is a bound,
#     clean K1A PASS whose decoded mem step holds a valid, positive MemTotal (FS-R-013 s.2), and Unit 2's K1g outcome is
#     a bound, clean K1G PASS as fs-k1g-units.ps1's Get-FsK1gUnit2Outcome reads it (its gate revision r1: the r2 K1G
#     REVIEW 0cbd71dd67acc301 stays REVIEW, superseded for progression by the one r3 successor, FS-R-016 s.5, s.6).
#     Both rules are fs-k1g-units.ps1's (Get-FsK1gK1aGate, Get-FsK1gUnit2Outcome), read through it unchanged;
#   - N1 on Unit 1 (QUEST3UNIT1) opens only when Unit 1's own K1a result is a bound, clean K1A PASS with a valid
#     MemTotal AND Unit 2's N1 result is a bound, clean N1 PASS (and the PM was told: phase A question A5).
# Each N1 attempt: its own fresh nonce (a nonce-only rebuild of the reviewed N1 candidate), its own readback rows (the
# K1a READBACK-EXPECT files: same build, slot and ranges) and its own ledger entry (build\n1\attempted\<nonce>.attempted).
# Any REVIEW, FAIL, INTEGRITY FAULT, INCONCLUSIVE, unclean PASS or attempt without an outcome record blocks the next
# step (no clearance shortcut, FS-R-013 s.3). Known hardware faults, recorded and never compensated: Unit 2 IPD slider
# and proximity sensor; Unit 1 proximity sensor. N1 reads no sensor.
# THE ONE N1 SUPERSESSION (N1 gate revision r1, n1/CHANGES-r3.md): $script:FsN1Supersession below recognises exactly one
#   historical N1 attempt, Unit 2's r2 attempt 611fa148f12d76bb: registered and booted, then its collector refused at
#   start (the r2 host-tool defect, J-234), so it has NO outcome record. It stays without an outcome (never a PASS, never
#   a result); its ledger entry, observer record and the transfer job's xfer.json stay in place. Only when it is exactly
#   as pinned (byte for byte, both copies, no outcome anywhere) and the Chair's ruling is pinned:
#     - no automatic repeat (Get-FsN1Prereq): Unit 2 may have ONE further N1 attempt (N1 r3), only while the checkout's
#       candidate table and its r3 collector and PC-side library are the pinned files; three discovery paths (the
#       ledger, every observe.json, every attempt.lock); once that attempt is registered, another is refused, whatever
#       its outcome (or none);
#     - Unit 2's N1 outcome (Get-FsN1StageOutcome, the dormant Unit 1 rule): the ONE other Unit 2 attempt, later than it,
#       of the r3 lineage by its bound evidence, must be a bound, clean N1 PASS.
#   While the committed evidence of that attempt is in the checkout, a Unit 2 N1 ledger WITHOUT it is refused. There is
#   no switch, no blanket exclusion, no ledger deletion and no "latest record wins" rule.
# The K1a units library and the shared FSB1 decoder are dot-sourced, never edited.
. (Join-Path $PSScriptRoot 'fs-k1a-units.ps1')           # the two units, Get-FsK1aUnit2Outcome, the K1a pins (read only)
. (Join-Path $PSScriptRoot '..\common\host\fsb1.ps1')    # Test-Fsb1Record (read only)
. (Join-Path $PSScriptRoot 'fs-k1g-units.ps1')           # the K1g gate: both units' K1a (with MemTotal), Unit 2's K1g (read only)
$script:FsN1UnitsDir = $PSScriptRoot
# PM decision 2026-10-16 (a): N1 runs on Unit 2 only; a Unit 1 run is optional, for later. Coordinator decision
# 2026-10-16: N1 on Unit 2 runs after both K1a attempts and after K1g on Unit 2 (Get-FsN1Prereq). The
# Unit 1 rule below stays written but is not open: a Unit 1 attempt is refused until a new PM decision and package
# revision set this to $true.
$script:FsN1Unit1Enabled = $false
$script:FsN1ClassifySchema = 'frameshift.fs-classify-n1.v1'
$script:FsN1Outcomes = @('N1 PASS', 'N1 REVIEW', 'N1 FAIL', 'INTEGRITY FAULT', 'INCONCLUSIVE')
$script:FsN1Steps = @('kernel', 'mem', 'modules', 'net', 'xfer', 'log')
$script:FsN1K1aSteps = @('kernel', 'config', 'mem', 'modules', 'kmsg', 'fs', 'usb', 'log')
# THE ONE N1 SUPERSESSION (N1 gate revision r1, devices/quest3/n1/CHANGES-r3.md; for the Chair). Every value is pinned
# here; none is taken from a record. Naming any other attempt needs a reviewed edit of this file (a SIGNOFF-n1 host pin).
#   - the historical attempt: Unit 2's N1 r2 attempt 611fa148f12d76bb (J-234). It was registered and booted; then the
#     r2 collector refused at its start ("output directory already exists", exit 20; it sent nothing on the ACM console)
#     and the classifier found no collect.json (exit 70). It has NO outcome record. Pinned: its serial, nonce, image, build
#     and observe directories, the SHA-256 of its ledger entry (build\n1 AND the committed evidence copy), attempt.lock,
#     observe.json and observe.log (both copies), the transfer job's xfer.json (both copies: "stopped", 0 bytes), the
#     committed console transcript of the attempt (its refusal, recovery and exit lines) and classifier transcript; and
#     the ABSENCE of any outcome: no classify-n1.json, no collect.json, no capture.raw, nothing else in its directories;
#   - its after-session facts (Chair-view review MAJOR-2; FS-R-017 s.2 accepted K1g gate r1 because recognition requires
#     clean after-session facts): the SHA-256 of the committed checklist-n1.json and its phase F facts. That phase F is
#     clean False for ONE recorded reason only, accepted by the PM (J-234): the two follow-up readings were taken 1 s
#     apart (the PC slept), so follow-ups-finished failed (FollowUpsNote). Every other phase F fact must be clean and as
#     recorded (Test-FsN1SupersededChecklist); any other non-clean reason refuses;
#   - the r3 lineage: the image is unchanged (the reviewed candidate b1ba58d65e7ffa1a, 82eefa8a..., through the pinned
#     candidate table fs-nonceonly-n1.ps1); the host tools are the r3 ones: the SHA-256 of fs-collect-n1.ps1 and
#     fs-xfer-n1.ps1 (the r2 collector refused every live run). At the attempt the checkout's files must be exactly these;
#     afterwards the successor's own bound collect.json (HostTools, written by the r3 collector) must name them;
#   - the ruling: the Chair's ruling that authorises the one replacement attempt, by name and by the SHA-256 of its
#     committed LF bytes. UNTIL THE CHAIR RULES, Ruling and RulingSha256 are empty and the supersession is NOT APPLIED
#     (fail-closed): the one-line pin of the ruling is the only edit expected after the Chair's ruling.
$script:FsN1Supersession = [ordered]@{
    Serial                = 'QUEST3UNIT2'
    Nonce                 = '611fa148f12d76bb'
    ImageSha256           = '18cb5c28b3d0d48ad549ab7da31a10ec92b8b6773c7fb7851e0c35360b415a37'
    BuildDir              = '20261020T155655Z-611fa148f12d76bb'
    ObserveDir            = 'observe-20261021T161305Z'
    LedgerSha256          = '55164769eda57b14b0199be68bf3cf222230be3d85ac2cd62a4f80226b5f128e'
    LockSha256            = '8f400e9b5174069d373a8700ab8141fa61ce99754f3e54edef36195c38e7dd72'
    ObserveJsonSha256     = '827112b432c3160ed18d3d0e11c548856e2e4c3b67f1c325a2a4b6d5d8188ca0'
    ObserveLogSha256      = 'f3aa66ba51bc2ae610f7a66647172c706069f7bb3996ae6ea651a6f69603c116'
    XferJsonSha256        = '3b857ba2d26ae348b4c1a7d47f55496c4969e639553478ad14257394d8cbae9c'
    ConsoleSha256         = 'ddd2b49049810e10ea1af206b070f8c898df53e65d02cd368403f016afd8e658'
    ClassifyConsoleSha256 = '043fa34159bfb75fbe1a2d182367c694f4ba6908060f704bd1ee693c848ec6e0'
    RefusalLine           = 'REFUSED/ERROR: refused: output directory already exists: <repo>\build\n1\20261020T155655Z-611fa148f12d76bb\observe-20261021T161305Z\collect'
    RecoveryLine          = 'RECOVERY: nothing was sent to the device by this run (the ACM console)'
    ExitLine              = 'collector exit: 20'
    ClassifyLine          = 'ERROR: no collect.json in <repo>\build\n1\20261020T155655Z-611fa148f12d76bb\observe-20261021T161305Z\collect'
    EvidenceDir           = 'devices\quest3\evidence\unit2-n1-20261021'
    EvidenceLedger        = 'devices\quest3\evidence\n1-attempt-ledger-20261021\611fa148f12d76bb.attempted'
    EvidenceConsole       = 'f\console-attempt-20261021T161256Z.txt'
    EvidenceClassify      = 'classify-console.txt'
    EvidenceChecklist     = 'checklist-n1.json'
    ChecklistSha256       = '33b76723f0d7505abffaf44c5e44998a2093b670920a0881cfe7759a4329f887'
    FollowUpsNote         = 'reading 2 is less than 240 s after reading 1'
    ReviewedImage         = '82eefa8a7d263bbe0a36370070149418820a155e35fc906ff6377ecc1f480436'
    ReviewedNonce         = 'b1ba58d65e7ffa1a'
    CandidateTableSha256  = 'a8fecbfd36c0308cdcf4b20877548ab8c2c02c1cbed135ddc06079059ab3031f'
    CollectorSha256       = 'dea946938cea13b728298852dc891e306dd62cdeaceaa16303365083d67f63ba'
    EngineSha256          = '2b90d641a15065da522e885df6cb627cd01e48608f7a20faea4cd07698068089'
    XferLibSha256         = '2b9320ce581f4821334924e5bfffe474d0fed432d7701d190bcf9d48fec93a7e'
    Revision              = 'N1 r3'
    Ruling                = 'FS-R-018'
    RulingSections        = 's.3, s.4'
    RulingSha256          = '7fef506fafefbeb64996e55207dbbe9dbc5a015c6271d90c315d49acc986f6b9'
}
$script:FsN1RepoRoot = Join-Path $PSScriptRoot '..\..\..'      # the evidence copies and relays\ (the host tests point it elsewhere)
# review A F1: the historical attempt must be in build\n1 (a ledger without it is refused, whether or not the committed
# evidence is in the working tree). Only the host tests switch this off, for their fixture ledgers that never held it.
$script:FsN1HistoryRequired = $true
function Get-FsN1FileSha([string]$Path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { '' } }
# the SHA-256 of a text file read with every CR-LF as LF (its committed LF bytes); '' if unreadable
function Get-FsN1LfSha([string]$Path) {
    try { [byte[]]$b = [IO.File]::ReadAllBytes($Path) } catch { return '' }
    $l1 = [Text.Encoding]::GetEncoding(28591)
    [byte[]]$lf = $l1.GetBytes($l1.GetString($b).Replace("`r`n", "`n"))
    $sh = [Security.Cryptography.SHA256]::Create(); try { -join ($sh.ComputeHash($lf) | ForEach-Object { $_.ToString('x2') }) } finally { $sh.Dispose() }
}
# the lines of a transcript (UTF-16LE or UTF-8, with or without a BOM), trailing CR/space removed; @() if unreadable
function Get-FsN1TextLines([string]$Path) {
    try { [byte[]]$b = [IO.File]::ReadAllBytes($Path) } catch { return @() }
    $t = if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
         elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
         else { [Text.Encoding]::UTF8.GetString($b) }
    @($t -split "`n" | ForEach-Object { $_.TrimEnd("`r", ' ') })
}
# the names in a directory (files and directories, hidden included), sorted ordinally; $null if it is not a directory
function Get-FsN1DirNames([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $n = [string[]]@(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }); [Array]::Sort($n, [StringComparer]::Ordinal); ,$n
}
# N1 r3 delta review: EVERY serial= value in a ledger entry or attempt.lock text (any number of lines or fields)
function Get-FsN1NoteSerials([string]$Note) { @([regex]::Matches([string]$Note, 'serial=(\S*)') | ForEach-Object { $_.Groups[1].Value }) }
# $true only when the text names a serial and EVERY serial= value is exactly Unit 1's (the only traces a Unit 2 path skips)
function Test-FsN1OnlyUnit1([string]$Note) { $v = @(Get-FsN1NoteSerials $Note); ($v.Count -gt 0) -and (@($v | Where-Object { $_ -cne $script:FsK1aUnit1 }).Count -eq 0) }
# a property of a parsed JSON object by its EXACT name (case-sensitive; another spelling is absent); $null if absent
function Get-FsN1Prop($o, [string]$n) {
    if ($null -eq $o -or -not ($o -is [psobject])) { return $null }
    $p = @($o.PSObject.Properties | Where-Object { $_.Name -ceq $n })
    if ($p.Count -ne 1) { return $null }
    $p[0].Value
}
# The pins themselves: well-formed, naming Unit 2 and a collector refusal at start, and the ruling pinned and committed
# as pinned. Returns @{ Ok; Why; Ref }.
function Test-FsN1SupersessionPins {
    $s = $script:FsN1Supersession
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "the supersession of the N1 r2 attempt $($s.Nonce) is not applied: $w"; Ref = '' } }
    $hx = @('ImageSha256', 'LedgerSha256', 'LockSha256', 'ObserveJsonSha256', 'ObserveLogSha256', 'XferJsonSha256', 'ConsoleSha256', 'ClassifyConsoleSha256', 'ChecklistSha256', 'ReviewedImage', 'CandidateTableSha256', 'CollectorSha256', 'EngineSha256', 'XferLibSha256')
    if ([string]$s.Serial -cne $script:FsK1aUnit2 -or [string]$s.Nonce -cnotmatch '^[0-9a-f]{16}\z' -or [string]$s.ReviewedNonce -cnotmatch '^[0-9a-f]{16}\z' -or
        [string]$s.BuildDir -cne "20261020T155655Z-$($s.Nonce)" -or [string]$s.ObserveDir -cnotmatch '^observe-[0-9]{8}T[0-9]{6}Z\z' -or
        @($hx | Where-Object { [string]$s[$_] -cnotmatch '^[0-9a-f]{64}\z' }).Count -gt 0 -or
        [string]$s.RefusalLine -cnotlike "REFUSED/ERROR: refused: output directory already exists: *\build\n1\$($s.BuildDir)\$($s.ObserveDir)\collect" -or
        [string]$s.RecoveryLine -cne 'RECOVERY: nothing was sent to the device by this run (the ACM console)' -or [string]$s.ExitLine -cne 'collector exit: 20' -or
        [string]$s.ClassifyLine -cnotlike "ERROR: no collect.json in *\build\n1\$($s.BuildDir)\$($s.ObserveDir)\collect" -or
        [string]$s.EvidenceChecklist -cne 'checklist-n1.json' -or [string]$s.FollowUpsNote -cnotmatch '^reading [0-9] is less than 240 s after reading [0-9]\z') {
        return (& $no 'its pinned values are malformed or name something other than a Unit 2 N1 attempt whose collector refused at start (exit 20) and whose after-session record is unclean for the follow-up spacing alone') }
    if (-not [string]$s.Ruling -and -not [string]$s.RulingSha256) { return (& $no "no ruling is pinned yet: it awaits the Chair's ruling on $($s.Revision) (until then Unit 2 keeps its one spent N1 attempt)") }
    if ([string]$s.Ruling -cnotmatch '^FS-R-[0-9]{3}\z' -or [string]$s.RulingSha256 -cnotmatch '^[0-9a-f]{64}\z' -or [string]$s.RulingSections -cnotmatch '^(s\.[0-9]+(, s\.[0-9]+)*)?\z') { return (& $no 'its ruling pin is malformed') }
    $rh = Get-FsN1LfSha (Join-Path $script:FsN1RepoRoot "relays\$($s.Ruling).md")
    if (-not $rh) { return (& $no "the ruling file relays\$($s.Ruling).md is missing") }
    if ($rh -cne [string]$s.RulingSha256) { return (& $no "relays\$($s.Ruling).md has SHA-256 $rh (CR-LF read as LF), not the pinned $($s.RulingSha256)") }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; Ref = "$($s.Ruling)$(if ($s.RulingSections) { " $($s.RulingSections)" })" }
}
# The historical attempt's after-session record (review MAJOR-2; FS-R-017 s.2): the committed checklist-n1.json in $Ev
# (the evidence directory), byte for byte as pinned, and its phase F facts. Clean False for ONE reason only: the
# follow-up spacing (follow-ups-finished failed with the pinned FollowUpsNote; the PM accepted the late readings, J-234).
# Every other phase F fact is clean and as recorded: AF and AA ended OK (bound to the committed SUMMARY.txt files),
# AA10 300, both follow-up readings 250 (bound to their committed raw files), back by itself y, dump mode n, no recovery
# fault, highest 300, the answers F1-F6 and the workaround record as recorded. Any other non-clean reason, or any other
# fact, refuses. Returns @{ Ok; Why }.
function Test-FsN1SupersededChecklist([string]$Ev) {
    $s = $script:FsN1Supersession
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "its after-session record is not the recognised one: $w" } }
    # N1 r3 delta review: every fact by its EXACT property name (Get-FsN1Prop) and its JSON type: a boolean is [bool], a
    # count or temperature written as a number is [int]/[long], a text is [string] (a "True" or "300" string refuses)
    $pv = { param($o, [string]$n) Get-FsN1Prop $o $n }
    $isB = { param($x, [bool]$v) ($x -is [bool]) -and $x -eq $v }
    $isS = { param($x, [string]$v) ($x -is [string]) -and $x -ceq $v }
    $isI = { param($x, [long]$v) ($x -is [int] -or $x -is [long]) -and $x -eq $v }
    $cf = Join-Path $Ev $s.EvidenceChecklist
    $h = Get-FsN1FileSha $cf
    if ($h -cne [string]$s.ChecklistSha256) { return (& $no "the committed checklist $cf has SHA-256 '$h', not the pinned $($s.ChecklistSha256)") }
    $j = try { [IO.File]::ReadAllText($cf) | ConvertFrom-Json } catch { $null }
    if (-not (& $isS (& $pv $j 'Schema') 'frameshift.fs-checklist-n1.v1')) { return (& $no 'it is not an N1 checklist (schema)') }
    $en = @(& $pv $j 'Entries')
    $fe = @($en | Where-Object { & $isS (& $pv $_ 'Phase') 'F' })
    if ($en.Count -lt 1 -or $fe.Count -ne 1 -or -not (& $isS (& $pv $en[$en.Count - 1] 'Phase') 'F')) { return (& $no "$($fe.Count) phase F entries (exactly one, the last entry, expected)") }
    $f = $fe[0]
    if (-not (& $isS (& $pv $f 'Result') 'PASS') -or -not (& $isS (& $pv $f 'Nonce') ([string]$s.Nonce)) -or -not (& $isS (& $pv $f 'Serial') ([string]$s.Serial)) -or -not (& $isS (& $pv $f 'Tool') 'the N1 sign-off tooling (private)')) {
        return (& $no 'its phase F entry is not the recorded after-session facts of this attempt of Unit 2') }
    # the checks: AF, AA and AA10 OK; follow-ups-finished failed, for the spacing alone; every Name a string, every Ok a boolean
    $cks = @(& $pv $f 'Checks')
    $ck = @($cks | ForEach-Object { "$(& $pv $_ 'Name')=$(& $pv $_ 'Ok')" }) -join '|'
    $ckT = @($cks | Where-Object { -not ((& $pv $_ 'Name') -is [string]) -or -not ((& $pv $_ 'Ok') -is [bool]) }).Count
    $fu = @($cks | Where-Object { & $isS (& $pv $_ 'Name') 'follow-ups-finished-below-400' })
    if ($ckT -or $ck -cne 'af-ended-ok=True|aa-ended-ok=True|aa10-below-400=True|follow-ups-finished-below-400=False' -or $fu.Count -ne 1 -or -not (& $isS (& $pv $fu[0] 'Detail') ([string]$s.FollowUpsNote))) {
        return (& $no "its phase F checks are '$ck'$(if ($ckT) { " ($ckT with a Name that is not a string or an Ok that is not a JSON boolean)" }) (only follow-ups-finished may fail, and only for '$($s.FollowUpsNote)')") }
    $qs = @(& $pv $f 'Questions')
    $qa = @($qs | ForEach-Object { "$(& $pv $_ 'Id')=$(& $pv $_ 'Answer')" }) -join '|'
    $qaT = @($qs | Where-Object { -not ((& $pv $_ 'Id') -is [string]) -or -not ((& $pv $_ 'Answer') -is [string]) }).Count
    if ($qaT -or $qa -cne 'F1=y|F2=n|F3=y|F4=y|F5=y|F6=y') { return (& $no "its phase F answers are '$qa' (back by itself y, dump mode n, the workaround answers as recorded; each Id and Answer a string)") }
    $af = & $pv $f 'After'
    if ($null -eq $af) { return (& $no 'its phase F entry has no After record') }
    foreach ($kv in @(@('Clean', $false), @('AfOk', $true), @('AaOk', $true), @('ReturnedByItself', $true), @('DumpMode', $false), @('RecoveryFault', $false), @('FollowUpsFinished', $false))) {
        if (-not (& $isB (& $pv $af $kv[0]) $kv[1])) { return (& $no "After.$($kv[0]) is '$(& $pv $af $kv[0])', not the recorded $($kv[1]) (the follow-up spacing must be the only non-clean reason)") } }
    if (-not (& $isS (& $pv $af 'FollowUpsNote') ([string]$s.FollowUpsNote))) { return (& $no "After.FollowUpsNote is '$(& $pv $af 'FollowUpsNote')', not '$($s.FollowUpsNote)'") }
    foreach ($k in 'Aa10Temp', 'MaxTemp') { $x = & $pv $af $k; if (-not (& $isI $x 300)) { return (& $no "After.$k is '$x'$(if ($null -ne $x) { " ($($x.GetType().Name))" }), not the recorded number 300 (below 400)") } }
    if ($null -ne (& $pv $af 'FollowUpsOffUtc')) { return (& $no 'After.FollowUpsOffUtc is set (not recorded)') }
    foreach ($kv in @(@('AfSha256', 'AF\SUMMARY.txt'), @('AaSha256', 'AA\SUMMARY.txt'))) {
        $sh = Get-FsN1FileSha (Join-Path $Ev $kv[1]); if (-not $sh -or -not (& $isS (& $pv $af $kv[0]) $sh)) { return (& $no "After.$($kv[0]) does not equal the committed $($kv[1]) ('$sh')") } }
    $rd = @(& $pv $af 'FollowUps')
    if ($rd.Count -ne 2) { return (& $no "$($rd.Count) follow-up readings (the 2 recorded expected)") }
    for ($i = 0; $i -lt 2; $i++) {
        $r = $rd[$i]; $sh = Get-FsN1FileSha (Join-Path $Ev "followup-$($i + 1)-battery.txt")
        # as recorded: N a number, Temp the reading's text '250'
        if (-not (& $isI (& $pv $r 'N') ($i + 1)) -or -not (& $isS (& $pv $r 'Temp') '250') -or -not $sh -or -not (& $isS (& $pv $r 'RawSha256') $sh)) { return (& $no "follow-up reading $($i + 1) is not the recorded one (N $($i + 1), Temp '250', bound to the committed followup-$($i + 1)-battery.txt)") } }
    $wk = & $pv $af 'Workaround'
    foreach ($k in 'At0b', 'AtBA', 'AtAA', 'AtFollowUps') { if (-not (& $isB (& $pv $wk $k) $true)) { return (& $no "After.Workaround.$k is not the recorded True") } }
    $wy = "after-session facts recorded for nonce $($s.Nonce) ($($s.Serial)): clean False (AF ok True, AA ok True, AA10 300, follow-ups $($s.FollowUpsNote), back by itself y, dump mode n, highest 300)"
    if (-not (& $isS (& $pv $f 'Why') $wy)) { return (& $no "its phase F summary is not the recorded one ('$(& $pv $f 'Why')')") }
    [pscustomobject]@{ Ok = $true; Why = "its after-session record (checklist-n1.json $($s.ChecklistSha256)) is clean but for the follow-up spacing alone ('$($s.FollowUpsNote)'; the PM accepted the late readings, J-234): AF and AA OK, AA10 300, back by itself, no dump mode, highest 300" }
}
# The historical attempt in $N1Root (build\n1), byte for byte as pinned, with NO outcome anywhere (build copy and the
# committed evidence copy), and its after-session facts (Test-FsN1SupersededChecklist). Returns @{ Ok; Why }.
function Test-FsN1SupersededAttempt([string]$N1Root) {
    $s = $script:FsN1Supersession
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "the N1 attempt $($s.Nonce) is not the recognised historical attempt: $w" } }
    $ev = Join-Path $script:FsN1RepoRoot $s.EvidenceDir
    $led = Join-Path $N1Root "attempted\$($s.Nonce).attempted"
    foreach ($c in @(@($led, 'LedgerSha256', 'its ledger entry'), @((Join-Path $script:FsN1RepoRoot $s.EvidenceLedger), 'LedgerSha256', 'the committed ledger copy'))) {
        $h = Get-FsN1FileSha $c[0]; if ($h -cne [string]$s[$c[1]]) { return (& $no "$($c[2]) $($c[0]) has SHA-256 '$h', not the pinned $($s[$c[1]])") } }
    $note = try { (@([IO.File]::ReadAllLines($led)) -join ' ') } catch { '' }
    if ($note -cnotmatch (' n1 image=' + $s.ImageSha256 + ' serial=' + $s.Serial + ' ')) { return (& $no 'its ledger entry does not name the pinned image and Unit 2') }
    $dirs = @(Get-ChildItem -LiteralPath $N1Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch ('^[0-9]{8}T[0-9]{6}Z-' + $s.Nonce + '\z') })
    if ($dirs.Count -ne 1 -or $dirs[0].Name -cne [string]$s.BuildDir) { return (& $no "$($dirs.Count) build directories of the nonce (exactly $($s.BuildDir) expected)") }
    $bd = $dirs[0].FullName
    $lk = Get-FsN1FileSha (Join-Path $bd 'attempt.lock'); if ($lk -cne [string]$s.LockSha256) { return (& $no "its attempt.lock has SHA-256 '$lk', not the pinned $($s.LockSha256)") }
    $obs = @(Get-ChildItem -LiteralPath $bd -Directory -Force -ErrorAction SilentlyContinue)
    if ($obs.Count -ne 1 -or $obs[0].Name -cne [string]$s.ObserveDir) { return (& $no "$($obs.Count) directories in $bd (exactly the one observe directory $($s.ObserveDir) expected)") }
    $od = $obs[0].FullName; $eo = Join-Path $ev 'observe'
    foreach ($c in @(@('observe.json', 'ObserveJsonSha256'), @('observe.log', 'ObserveLogSha256'), @('collect\xfer.json', 'XferJsonSha256'))) {
        foreach ($root in @($od, $eo)) { $h = Get-FsN1FileSha (Join-Path $root $c[0]); if ($h -cne [string]$s[$c[1]]) { return (& $no "$(Join-Path $root $c[0]) has SHA-256 '$h', not the pinned $($s[$c[1]])") } } }
    # NO OUTCOME: the observe directory holds the observer's two files and collect\, which holds the job's xfer.json only
    # (no collect.json, no capture.raw, no classify-n1.json), in the build and in the committed evidence copy
    foreach ($root in @($od, $eo)) {
        $a = Get-FsN1DirNames $root; $b = Get-FsN1DirNames (Join-Path $root 'collect')
        if ($null -eq $a -or ($a -join '|') -cne 'collect|observe.json|observe.log' -or $null -eq $b -or ($b -join '|') -cne 'xfer.json') {
            return (& $no "$root does not hold exactly observe.json, observe.log and collect\xfer.json (an outcome record, a collect.json or another file was added, or one is missing)") }
    }
    foreach ($root in @($bd, $ev)) { $cj = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -Filter 'classify-n1*' -ErrorAction SilentlyContinue); if ($cj.Count) { return (& $no "an outcome record exists: $($cj[0].FullName)") } }
    $pv = { param($o, [string]$n) Get-FsN1Prop $o $n }      # exact property names (N1 r3 delta review)
    $ob = try { [IO.File]::ReadAllText((Join-Path $od 'observe.json')) | ConvertFrom-Json } catch { $null }
    if ([string](& $pv $ob 'Stage') -cne 'n1' -or [string](& $pv $ob 'Nonce') -cne [string]$s.Nonce -or [string](& $pv $ob 'Serial') -cne [string]$s.Serial -or [string](& $pv $ob 'ImageSha256') -cne [string]$s.ImageSha256 -or
        [string](& $pv $ob 'NonceOnly') -cne "a nonce-only rebuild of the reviewed candidate ($($s.ReviewedNonce) -> $($s.Nonce); fs-nonceonly-n1 checks passed)") { return (& $no 'its observe.json is not this N1 attempt of Unit 2 from the reviewed candidate') }
    $x = try { [IO.File]::ReadAllText((Join-Path $od 'collect\xfer.json')) | ConvertFrom-Json } catch { $null }
    $isI0 = { param($v) ($v -is [int] -or $v -is [long]) -and $v -eq 0 }      # a JSON number 0, not the text '0'
    if ([string](& $pv $x 'Result') -cne 'stopped' -or [string](& $pv $x 'Nonce') -cne [string]$s.Nonce -or -not (& $isI0 (& $pv (& $pv $x 'H2d') 'Bytes')) -or -not (& $isI0 (& $pv (& $pv $x 'D2h') 'Bytes')) -or -not (& $isI0 (& $pv $x 'ConnectAttempts'))) {
        return (& $no 'its xfer.json is not the stopped transfer job (no connection, 0 bytes)') }
    $cl = @(Get-FsN1TextLines (Join-Path $ev $s.EvidenceConsole)); $ch = Get-FsN1FileSha (Join-Path $ev $s.EvidenceConsole)
    if ($ch -cne [string]$s.ConsoleSha256) { return (& $no "the committed console transcript $($s.EvidenceConsole) has SHA-256 '$ch', not the pinned $($s.ConsoleSha256)") }
    foreach ($ln in @($s.RefusalLine, $s.RecoveryLine, $s.ExitLine)) { if (@($cl | Where-Object { $_ -ceq [string]$ln }).Count -ne 1) { return (& $no "its console transcript does not hold the line '$ln' exactly once") } }
    $kl = @(Get-FsN1TextLines (Join-Path $ev $s.EvidenceClassify)); $kh = Get-FsN1FileSha (Join-Path $ev $s.EvidenceClassify)
    if ($kh -cne [string]$s.ClassifyConsoleSha256 -or @($kl | Where-Object { $_ -ceq [string]$s.ClassifyLine }).Count -ne 1) { return (& $no "the committed classifier transcript $($s.EvidenceClassify) is not the pinned one ('no collect.json')") }
    $fc = Test-FsN1SupersededChecklist $ev
    if (-not $fc.Ok) { return (& $no $fc.Why) }
    [pscustomobject]@{ Ok = $true; Why = "the N1 r2 attempt $($s.Nonce) of Unit 2 stays WITHOUT AN OUTCOME (its collector refused at start: 'output directory already exists', exit 20, nothing sent on the console; no collect.json; its transfer job stopped with 0 bytes; ledger $($s.LedgerSha256); $($fc.Why))" }
}
# An N1 ledger without the historical attempt is refused (not read as "no attempt"; review A F1: unconditional, also
# when the committed evidence is missing from the working tree). Returns '' or the refusal.
function Get-FsN1HistoryMissing([string]$N1Root) {
    $s = $script:FsN1Supersession
    if (-not $script:FsN1HistoryRequired) { return '' }
    if (Test-Path -LiteralPath (Join-Path $N1Root "attempted\$($s.Nonce).attempted") -PathType Leaf) { return '' }
    "the historical Unit 2 N1 attempt $($s.Nonce) (no outcome; committed evidence $($s.EvidenceLedger)) is missing from this N1 ledger ($(Join-Path $N1Root 'attempted')): an attempt directory or ledger entry was removed, or this working copy lacks the shared build\n1; blocked"
}
# The outcome side's hidden-attempt path (the supersession, Unit 2): every attempt.lock in a directory directly under
# $N1Root, hidden directories included, that is not exactly Unit 1's (N1 r3 delta review, as the prior side: a lock
# naming no serial, an unknown serial, or any serial= value other than exactly Unit 1's counts as Unit 2's):
# @{ File; Nonce } (Nonce '' if the directory name is not <stamp>-<nonce>).
function Get-FsN1UnitLocks([string]$N1Root) {
    $out = @()
    foreach ($bd in @(Get-ChildItem -LiteralPath $N1Root -Directory -Force -ErrorAction SilentlyContinue)) {
        $lk = Join-Path $bd.FullName 'attempt.lock'
        if (-not (Test-Path -LiteralPath $lk)) { continue }
        $note = try { (@([IO.File]::ReadAllLines($lk)) -join ' ') } catch { '' }
        $bn = if ($bd.Name -cmatch '^[0-9]{8}T[0-9]{6}Z-([0-9a-f]{16})\z') { $Matches[1] } else { '' }
        if (-not (Test-FsN1OnlyUnit1 $note)) { $out += [pscustomobject]@{ File = $lk; Nonce = $bn } }
    }
    $out
}
# Review A F2, a fourth discovery path: every committed N1 ledger copy (devices\quest3\evidence\n1-attempt-ledger-*\
# <nonce>.attempted) that names Unit 2, or no serial, other than the historical attempt's own: the nonces. A successor
# whose build directory and ledger entry were removed is still found once its ledger copy is committed (the procedure
# commits it with the session's evidence, as for r2).
function Get-FsN1CommittedOthers {
    $s = $script:FsN1Supersession
    $ev = Join-Path $script:FsN1RepoRoot 'devices\quest3\evidence'
    $out = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $ev -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^n1-attempt-ledger-' })) {
        foreach ($m in @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
            $note = if ($m.PSIsContainer) { '' } else { try { (@([IO.File]::ReadAllLines($m.FullName)) -join ' ') } catch { '' } }
            if (Test-FsN1OnlyUnit1 $note) { continue }      # skipped only if EVERY serial= value is exactly Unit 1's
            if ($m.Name -ceq "$($s.Nonce).attempted") { continue }
            $out += $(if ($m.Name -cmatch '^([0-9a-f]{16})\.attempted\z') { $Matches[1] } else { "unreadable:$($m.Name)" })
        }
    }
    $out
}
# NO AUTOMATIC REPEAT, the one exception: may Unit 2 have its ONE further N1 attempt (N1 r3)? Only if the pins and the
# ruling hold, the checkout's candidate table and r3 host tools are the pinned ones, every earlier-attempt trace of Unit 2
# (FOUR discovery paths: the ledger, every observe.json under build\n1, every attempt.lock, the committed ledger copies;
# any trace naming a serial other than exactly Unit 1's counts as Unit 2's: review A F5) is the historical attempt's
# own, and that attempt is exactly as pinned with no outcome. Once the further attempt is registered (its ledger entry,
# attempt.lock or observe.json), it is another trace and this refuses, whatever its outcome (or none). Returns @{ Ok; Why }
# (Why '' when this is not Unit 2).
function Test-FsN1SupersededPrior([string]$N1Root, [string]$Serial, [string[]]$Nonces) {
    $s = $script:FsN1Supersession
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w } }
    if ($Serial -cne $script:FsK1aUnit2) { return (& $no '') }
    $pp = Test-FsN1SupersessionPins
    if (-not $pp.Ok) { return (& $no $pp.Why) }
    foreach ($c in @(@('fs-nonceonly-n1.ps1', 'CandidateTableSha256', 'the N1 candidate table'), @('fs-collect-n1.ps1', 'CollectorSha256', 'the N1 collector'), @('fs-collect.ps1', 'EngineSha256', 'the collector engine'), @('fs-xfer-n1.ps1', 'XferLibSha256', 'the PC side of the NCM link'))) {
        $h = Get-FsN1FileSha (Join-Path $script:FsN1UnitsDir $c[0])
        if ($h -cne [string]$s[$c[1]]) { return (& $no "the supersession of $($s.Nonce) is not applied: $($c[2]) $($c[0]) has SHA-256 '$h', not the pinned $($s.Revision) file $($s[$c[1]])") } }
    if (@($Nonces | Where-Object { [string]$_ -cne [string]$s.Nonce }).Count) { return (& $no "Unit 2 has an N1 attempt other than the historical $($s.Nonce) ($(@($Nonces | Where-Object { [string]$_ -cne [string]$s.Nonce }) -join ', ')): the one further attempt is spent or in progress; no other is permitted") }
    $br = [IO.Path]::GetFullPath($N1Root).TrimEnd('\', '/')
    $ledF = Join-Path $br "attempted\$($s.Nonce).attempted"; $obsF = Join-Path $br "$($s.BuildDir)\$($s.ObserveDir)\observe.json"
    foreach ($m in @(Get-ChildItem -LiteralPath (Join-Path $br 'attempted') -Force -ErrorAction SilentlyContinue)) {
        $note = if ($m.PSIsContainer) { '' } else { try { (@([IO.File]::ReadAllLines($m.FullName)) -join ' ') } catch { '' } }
        if (-not (Test-FsN1OnlyUnit1 $note) -and $m.FullName -cne $ledF) { return (& $no "Unit 2 has an N1 ledger entry other than the historical one ($($m.FullName)), or one that names no serial: the one further attempt is spent or in progress (or cannot be told apart); no other is permitted") } }
    foreach ($oj in @(Get-ChildItem -LiteralPath $br -Recurse -Depth 2 -Force -File -Filter 'observe.json' -ErrorAction SilentlyContinue)) {
        $sr = try { [string]([IO.File]::ReadAllText($oj.FullName) | ConvertFrom-Json).Serial } catch { '?' }
        if ($sr -cne $script:FsK1aUnit1 -and $oj.FullName -cne $obsF) { return (& $no "Unit 2 has an N1 observer record other than the historical one ($($oj.FullName)), or one that cannot be read: the one further attempt is spent or in progress (or cannot be told apart); no other is permitted") } }
    foreach ($bd in @(Get-ChildItem -LiteralPath $br -Directory -Force -ErrorAction SilentlyContinue)) {
        $lk = Join-Path $bd.FullName 'attempt.lock'
        if (-not (Test-Path -LiteralPath $lk) -or $bd.Name -ceq [string]$s.BuildDir) { continue }
        $ln = try { (@([IO.File]::ReadAllLines($lk)) -join ' ') } catch { '' }
        if (-not (Test-FsN1OnlyUnit1 $ln)) { return (& $no "Unit 2 has an N1 attempt.lock other than the historical one ($lk), or one that names no unit: the one further attempt is spent or in progress; no other is permitted") }
    }
    $co = @(Get-FsN1CommittedOthers)
    if ($co.Count) { return (& $no "the committed N1 ledger copies name a Unit 2 N1 attempt other than the historical one ($($co -join ', ')): the one further attempt is spent; no other is permitted") }
    $sv = Test-FsN1SupersededAttempt $br
    if (-not $sv.Ok) { return (& $no "the supersession of $($s.Nonce) is not applied: $($sv.Why)") }
    [pscustomobject]@{ Ok = $true; Why = "Unit 2's only earlier N1 attempt: $($sv.Why), superseded for progression (not a result, never a PASS) under $($pp.Ref): ONE further Unit 2 N1 attempt ($($s.Revision): the reviewed candidate $($s.ReviewedNonce) or a nonce-only rebuild of it, with the $($s.Revision) collector; once registered, no other)" }
}
# The successor's r3 lineage, from its own bound evidence: its observe.json (bound by its record) names the reviewed
# candidate or a nonce-only rebuild of it, exactly as fs-observe-n1.ps1 writes them; its ledger entry names that image;
# and its collect.json (bound by its record) was written by the r3 collector (HostTools). Returns @{ Ok; Why }.
function Test-FsN1SupersedingAttempt($Rec, [string]$LedgerFile) {
    $s = $script:FsN1Supersession
    $pv = { param($o, [string]$n) Get-FsN1Prop $o $n }      # exact property names (N1 r3 delta review)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "the Unit 2 N1 attempt $($Rec.Nonce) is not shown to be the $($s.Revision) attempt: $w" } }
    $ob = try { [IO.File]::ReadAllText((Join-Path $Rec.Dir 'observe.json')) | ConvertFrom-Json } catch { $null }
    $nt = [string](& $pv $ob 'NonceOnly'); $isha = [string](& $pv $ob 'ImageSha256')
    $okC = ($nt -ceq "the reviewed candidate ($($s.ReviewedImage))" -and $isha -ceq [string]$s.ReviewedImage -and [string]$Rec.Nonce -ceq [string]$s.ReviewedNonce) -or
           ($nt -ceq "a nonce-only rebuild of the reviewed candidate ($($s.ReviewedNonce) -> $($Rec.Nonce); fs-nonceonly-n1 checks passed)" -and $isha -cmatch '^[0-9a-f]{64}\z')
    if (-not $okC) { return (& $no "its observe.json names '$nt' (image '$isha')") }
    $note = try { (@([IO.File]::ReadAllLines($LedgerFile)) -join ' ') } catch { '' }
    if ($note -cnotmatch (' image=' + $isha + ' ')) { return (& $no "its ledger entry $LedgerFile does not name the image $isha") }
    $cj = try { [IO.File]::ReadAllText((Join-Path $Rec.Dir 'collect\collect.json')) | ConvertFrom-Json } catch { $null }
    $ht = & $pv $cj 'HostTools'
    if ([string](& $pv $ht 'Collector') -cne [string]$s.CollectorSha256 -or [string](& $pv $ht 'XferLib') -cne [string]$s.XferLibSha256 -or [string](& $pv $ht 'Engine') -cne [string]$s.EngineSha256) { return (& $no "its collect.json was not written by the $($s.Revision) collector (HostTools '$(& $pv $ht 'Collector')' / '$(& $pv $ht 'XferLib')')") }
    [pscustomobject]@{ Ok = $true; Why = "the $($s.Revision) attempt (image $isha, the $($s.Revision) collector)" }
}
function Test-FsN1Unit([string]$Serial) { Test-FsK1aUnit $Serial }
function Get-FsN1UnitName([string]$Serial) { Get-FsK1aUnitName $Serial }

# A valid, positive MemTotal in a mem step's text: exactly one "MemTotal: <digits> kB" line, no leading zero, > 0.
function Get-FsN1MemTotal([string]$MemText) {
    $m = [regex]::Matches([string]$MemText, '(?m)^MemTotal:[ \t]+([0-9]+) kB\r?$')
    if ($m.Count -ne 1) { return [pscustomobject]@{ Ok = $false; Why = "$($m.Count) well-formed MemTotal lines (exactly 1 required)"; Kb = $null } }
    $v = $m[0].Groups[1].Value
    if ($v -cnotmatch '^[1-9][0-9]{0,11}\z') { return [pscustomobject]@{ Ok = $false; Why = "MemTotal '$v' is not a positive decimal without a leading zero"; Kb = $null } }
    [pscustomobject]@{ Ok = $true; Why = "MemTotal $v kB"; Kb = [long]$v }
}

# The MemTotal of a K1a or N1 record, decoded from the attempt's own capture.raw (FS-R-013 s.2).
function Get-FsN1RecordMemTotal([string]$CollectDir, [string]$Stage) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Kb = $null } }
    try { $c = [IO.File]::ReadAllText((Join-Path $CollectDir 'collect.json')) | ConvertFrom-Json } catch { return (& $no "no readable collect.json in $CollectDir") }
    $steps = if ($Stage -ceq 'k1a') { $script:FsN1K1aSteps } else { $script:FsN1Steps }
    [byte[]]$b = [IO.File]::ReadAllBytes((Join-Path $CollectDir 'capture.raw'))
    $d = Test-Fsb1Record -Bytes $b -Exp $Stage -Nonce ([string]$c.Nonce) -Challenge ([string]$c.Challenge) -Steps $steps
    if (-not $d.Ok) { return (& $no "the record does not decode (FSB1 $($d.Reason))") }
    $mem = @($d.Steps | Where-Object { [string]$_['id'] -ceq 'mem' })
    if ($mem.Count -ne 1) { return (& $no 'no mem step') }
    Get-FsN1MemTotal ([Text.Encoding]::GetEncoding(28591).GetString([byte[]]$mem[0]['out']))
}

# Every attempt of $Serial in the ledger of $BuildRoot (build\k1a or build\n1) for $Stage (k1a or n1), each bound to its
# outcome record (classify-<stage>.json; the K1a rules of fs-k1a-units.ps1 for any unit and either stage) and clean;
# all must be the stage's PASS with a clean after-session record and (k1a and n1) a valid positive MemTotal. Returns
# @{ Ok; Why; Nonce; Outcome; File; Sha256; Utc; MemTotalKb }.
function Get-FsN1StageOutcome([string]$BuildRoot, [string]$Stage, [string]$Serial) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Nonce = $null; Outcome = $null; File = $null; Sha256 = $null; Utc = $null; MemTotalKb = $null } }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $rd = { param([string]$f) try { [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $null } }
    $unit = Get-FsN1UnitName $Serial
    if (-not $unit) { return (& $no "'$Serial' is not one of the two units") }
    if (@('k1a', 'n1') -cnotcontains $Stage) { return (& $no "unknown stage '$Stage'") }
    $schema = if ($Stage -ceq 'k1a') { $script:FsK1aClassifySchema } else { $script:FsN1ClassifySchema }
    $pass = if ($Stage -ceq 'k1a') { 'K1A PASS' } else { 'N1 PASS' }
    $outs = if ($Stage -ceq 'k1a') { $script:FsK1aOutcomes } else { $script:FsN1Outcomes }
    $cls = Join-Path $script:FsN1UnitsDir "fs-classify-$Stage.ps1"
    $tag = "$unit's $($Stage.ToUpper()) result"
    if (-not $BuildRoot -or -not (Test-Path -LiteralPath $BuildRoot -PathType Container)) { return (& $no "${tag}: no build root '$BuildRoot'") }
    $clsSha = Get-FsK1aFileSha $cls
    $led = Join-Path $BuildRoot 'attempted'
    $all = @(Get-ChildItem -LiteralPath $led -Force -ErrorAction SilentlyContinue)
    $odd = @($all | Where-Object { $_.PSIsContainer -or $_.Name -cnotmatch '^[0-9a-f]{16}\.attempted\z' })
    if ($odd.Count) { return (& $no "${tag}: unexpected ledger file $($odd[0].FullName) (not <16 hex>.attempted)") }
    $recs = New-Object System.Collections.Generic.List[object]
    $sup = $null; $supWhy = ''      # THE ONE N1 SUPERSESSION (stage n1, Unit 2): the recognised historical attempt
    foreach ($m in $all) {
        $n = $m.Name.Substring(0, 16)
        $note = (@([IO.File]::ReadAllLines($m.FullName)) -join ' ')
        $lm = [regex]::Match($note, ' serial=([A-Za-z0-9]+) ')
        if (-not $lm.Success) { return (& $no "${tag}: ledger entry $($m.FullName) names no serial (cannot tell whose attempt it was)") }
        $sa = @(Get-FsN1NoteSerials $note)      # N1 r3 delta review: every serial= value, not only the first
        if (@($sa | Where-Object { $_ -cne $lm.Groups[1].Value }).Count) { return (& $no "${tag}: ledger entry $($m.FullName) names more than one serial ($($sa -join ', ')): cannot tell whose attempt it was") }
        if ($lm.Groups[1].Value -cne $Serial) { continue }
        $tm = [regex]::Match($note, '^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z) ')
        if (-not $tm.Success) { return (& $no "${tag}: ledger entry $($m.FullName) has no UTC time") }
        if ($Stage -ceq 'n1' -and $Serial -ceq $script:FsK1aUnit2 -and $n -ceq [string]$script:FsN1Supersession.Nonce) {
            $pp = Test-FsN1SupersessionPins
            $sv = if ($pp.Ok) { Test-FsN1SupersededAttempt $BuildRoot } else { $pp }
            if ($sv.Ok) { $sup = [pscustomobject]@{ Nonce = $n; LedgerUtc = $tm.Groups[1].Value; Ref = $pp.Ref; Why = $sv.Why }; continue }
            $supWhy = " ($($sv.Why))"      # not recognised: the ordinary rule below refuses it (no outcome record)
        }
        $why = "$tag, attempt nonce $n (ledger $($m.FullName))"
        $dirs = @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch ('^[0-9]{8}T[0-9]{6}Z-' + $n + '\z') })
        if ($dirs.Count -ne 1) { return (& $no "${why}: $($dirs.Count) build directories (exactly 1 expected)") }
        $ods = @(Get-ChildItem -LiteralPath $dirs[0].FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'observe.json') -PathType Leaf })
        if ($ods.Count -ne 1) { return (& $no "${why}: $($ods.Count) observe directories with observe.json (exactly 1 expected)") }
        $od = $ods[0].FullName; $oj = Join-Path $od 'observe.json'; $cj = Join-Path $od "classify-$Stage.json"
        $ob = & $rd $oj
        if ($null -eq $ob -or [string](& $pv $ob 'Stage') -cne $Stage -or [string](& $pv $ob 'Nonce') -cne $n -or [string](& $pv $ob 'Serial') -cne $Serial) { return (& $no "${why}: its observe.json is not this $Stage attempt of $Serial") }
        if (-not (Test-Path -LiteralPath $cj -PathType Leaf)) { return (& $no "${why}: no classify-$Stage.json (no outcome recorded; an attempt that cannot get one blocks for good)$supWhy") }
        $c = & $rd $cj
        $fx = & $pv $c 'Fixture'
        $colJ = Join-Path $od 'collect\collect.json'; $colR = Join-Path $od 'collect\capture.raw'
        $col = if (Test-Path -LiteralPath $colJ -PathType Leaf) { & $rd $colJ } else { $null }
        $ok = ($null -ne $c -and [string](& $pv $c 'Schema') -ceq $schema -and [string](& $pv $c 'Nonce') -ceq $n -and [string](& $pv $c 'Serial') -ceq $Serial -and
               ($fx -is [bool]) -and -not $fx -and ($outs -ccontains [string](& $pv $c 'Outcome')) -and [string](& $pv $c 'ObserveJsonSha256') -ceq (Get-FsK1aFileSha $oj) -and
               $null -ne $col -and [string](& $pv $col 'Nonce') -ceq $n -and [string](& $pv $c 'CollectJsonSha256') -ceq (Get-FsK1aFileSha $colJ) -and
               (Test-Path -LiteralPath $colR -PathType Leaf) -and [string](& $pv $c 'CaptureSha256') -ceq (Get-FsK1aFileSha $colR) -and [string](& $pv $c 'ClassifierSha256') -ceq $clsSha -and
               [string](& $pv $c 'BannerSha256') -ceq (Get-FsK1aTextSha $script:FsK1aPinBanner) -and [string](& $pv $c 'ConfigSha') -ceq $script:FsK1aPinConfigSha -and [string](& $pv $c 'Modules') -ceq [string]$script:FsK1aPinModules)
        if ($ok -and $Stage -ceq 'n1') {
            $xj = Join-Path $od 'collect\xfer.json'
            $ok = ((Test-Path -LiteralPath $xj -PathType Leaf) -and [string](& $pv $c 'XferJsonSha256') -ceq (Get-FsK1aFileSha $xj))
        }
        if (-not $ok) { return (& $no "${why}: its classify-$Stage.json does not bind this attempt (schema, nonce, serial, fixture, outcome, the SHA-256 of observe.json, collect.json, capture.raw$(if ($Stage -ceq 'n1') { ', xfer.json' }), the pinned classifier, banner, config and module count)") }
        $af = & $pv $c 'After'; $aw = @()
        if ($null -eq $af) { $aw += 'no after-session record' }
        else {
            foreach ($kv in @(@('Clean', $true), @('AfOk', $true), @('AaOk', $true), @('ReturnedByItself', $true), @('DumpMode', $false), @('RecoveryFault', $false), @('FollowUpsFinished', $true))) {
                $x = & $pv $af $kv[0]; if (-not ($x -is [bool]) -or $x -ne $kv[1]) { $aw += "$($kv[0]) is '$x'" } }
            $mt = & $pv $af 'MaxTemp'; if ($null -eq $mt -or [string]$mt -cnotmatch '^[0-9]{1,4}\z' -or [int]$mt -ge 400) { $aw += "highest reading '$mt' (below 400 required)" }
        }
        $mem = Get-FsN1RecordMemTotal (Join-Path $od 'collect') $Stage
        $recs.Add([pscustomobject]@{ Nonce = $n; Outcome = [string]$c.Outcome; File = $cj; Sha256 = (Get-FsK1aFileSha $cj); Utc = [string](& $pv $c 'Utc'); LedgerUtc = $tm.Groups[1].Value
                                     AfterClean = ($aw.Count -eq 0); AfterWhy = ($aw -join '; '); Mem = $mem; Dir = $od; Ledger = $m.FullName })
    }
    foreach ($bd in @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\z' })) {
        $bn = $bd.Name.Substring($bd.Name.Length - 16)
        foreach ($oj2 in @(Get-ChildItem -LiteralPath $bd.FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'observe.json' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
            $ob2 = & $rd $oj2
            if ($null -ne $ob2 -and [string](& $pv $ob2 'Serial') -ceq $Serial -and -not (Test-Path -LiteralPath (Join-Path $led "$bn.attempted") -PathType Leaf)) {
                return (& $no "${tag}: an attempt ($oj2) has no ledger entry $led\$bn.attempted (deleted or renamed)") }
        }
    }
    $sn = ''
    if ($Stage -ceq 'n1' -and $Serial -ceq $script:FsK1aUnit2 -and $null -eq $sup) { $hm = Get-FsN1HistoryMissing $BuildRoot; if ($hm) { return (& $no "${tag}: $hm") } }
    if ($null -ne $sup) {
        # THE ONE N1 SUPERSESSION: exactly one successor, later than it, of the r3 lineage, no hidden attempt
        $sn = "$($sup.Why), superseded for progression (not a result, never a PASS) under $($sup.Ref)"
        if ($recs.Count -eq 0) { return (& $no "${tag}: $sn; no successor Unit 2 N1 attempt yet ($($script:FsN1Supersession.Revision) and its classifier result come first)") }
        if ($recs.Count -ne 1) { return (& $no "${tag}: $sn; but Unit 2 has $($recs.Count) N1 attempts besides it (exactly one successor is permitted): blocked") }
        $hid = @(Get-FsN1UnitLocks $BuildRoot | Where-Object { @([string]$sup.Nonce, [string]$recs[0].Nonce) -cnotcontains [string]$_.Nonce })
        if ($hid.Count) { return (& $no "${tag}: $sn; but $($hid[0].File) records a Unit 2 N1 attempt that is not in the ledger and observer records (hidden or renamed): blocked") }
        $co = @(Get-FsN1CommittedOthers | Where-Object { [string]$_ -cne [string]$recs[0].Nonce })
        if ($co.Count) { return (& $no "${tag}: $sn; but the committed N1 ledger copies name another Unit 2 N1 attempt ($($co -join ', ')): blocked") }
        $t3 = ConvertFrom-FsK1gLedgerUtc ([string]$recs[0].LedgerUtc); $t2 = ConvertFrom-FsK1gLedgerUtc ([string]$sup.LedgerUtc)
        if ($null -eq $t3 -or $null -eq $t2 -or $t3 -le $t2) { return (& $no "${tag}: $sn; but the Unit 2 N1 attempt $($recs[0].Nonce) is not later than it (ledger $($recs[0].LedgerUtc)): blocked") }
        $cd = Test-FsN1SupersedingAttempt $recs[0] ([string]$recs[0].Ledger)
        if (-not $cd.Ok) { return (& $no "${tag}: $sn; but $($cd.Why): blocked") }
        $sn = "; $($cd.Why); $sn"
    }
    if ($recs.Count -eq 0) { return (& $no "${tag}: no $Stage attempt of $unit ($Serial) in the ledger $led") }
    foreach ($r in $recs) {
        if ($r.Outcome -cne $pass) { return (& $no "${tag}: attempt nonce $($r.Nonce) is $($r.Outcome) ($($r.File)): blocked (FS-R-013 s.3: REVIEW waits for the Chair; anything else needs a new package review)") }
        if (-not $r.AfterClean) { return (& $no "${tag}: attempt nonce $($r.Nonce) is $pass but its after-session record is not clean ($($r.AfterWhy)): blocked") }
        if (-not $r.Mem.Ok) { return (& $no "${tag}: attempt nonce $($r.Nonce) is $pass but its decoded mem step has no valid, positive MemTotal ($($r.Mem.Why)): blocked and reported (FS-R-013 s.2; not a reason for another attempt)") }
    }
    $best = $null
    foreach ($r in $recs) { if ($null -eq $best -or [string]::CompareOrdinal($r.LedgerUtc, [string]$best.LedgerUtc) -gt 0) { $best = $r } }
    [pscustomobject]@{ Ok = $true; Why = "$tag nonce $($best.Nonce): $($best.Outcome), after-session record clean, $($best.Mem.Why) ($($best.File))$sn"
                       Nonce = $best.Nonce; Outcome = $best.Outcome; File = $best.File; Sha256 = $best.Sha256; Utc = $best.Utc; MemTotalKb = $best.Mem.Kb }
}

# Earlier N1 attempts of $Serial: every ledger entry of build\n1 naming it, and every observe.json of it (an attempt whose
# ledger entry was removed still counts). Returns the list of nonces (or 'unreadable:<file>').
function Get-FsN1PriorAttempts([string]$N1Root, [string]$Serial) {
    $found = New-Object System.Collections.Generic.List[string]
    if (-not $N1Root -or -not (Test-Path -LiteralPath $N1Root -PathType Container)) { return @() }
    foreach ($m in @(Get-ChildItem -LiteralPath (Join-Path $N1Root 'attempted') -Force -File -ErrorAction SilentlyContinue)) {
        $note = try { (@([IO.File]::ReadAllLines($m.FullName)) -join ' ') } catch { '' }
        $lm = [regex]::Match($note, ' serial=([A-Za-z0-9]+) ')
        $sa = @(Get-FsN1NoteSerials $note)      # N1 r3 delta review: an entry naming more than one serial counts for every unit
        if (-not $lm.Success -or @($sa | Where-Object { $_ -cne $lm.Groups[1].Value }).Count) { $found.Add("unreadable:$($m.Name)") } elseif ($lm.Groups[1].Value -ceq $Serial) { $found.Add($m.Name.Split('.')[0]) }
    }
    foreach ($oj in @(Get-ChildItem -LiteralPath $N1Root -Recurse -Depth 2 -File -Filter 'observe.json' -ErrorAction SilentlyContinue)) {
        $ob = try { [IO.File]::ReadAllText($oj.FullName) | ConvertFrom-Json } catch { $null }
        if ($null -ne $ob -and $ob.PSObject.Properties['Serial'] -and [string]$ob.Serial -ceq $Serial) {
            $nn = if ($ob.PSObject.Properties['Nonce']) { [string]$ob.Nonce } else { '?' }
            if (-not $found.Contains($nn)) { $found.Add($nn) }
        }
    }
    $found.ToArray()       # unrolled: callers wrap the result in @()
}

# The N1 gate for one unit. $RepoBuild = <repo>\build. Returns @{ Ok; Why; Records = @(...) }.
# One N1 attempt per unit (FS-R-013 s.3 and s.5: no automatic further attempt, no standing-repeat authority; review M1):
# any earlier N1 attempt of the unit, whatever its outcome (PASS included) or without one, refuses a new attempt; a
# further attempt needs the Chair's explicit authority and a new reviewed package revision. The one such revision:
# THE ONE N1 SUPERSESSION (Test-FsN1SupersededPrior, N1 r3); its Why is appended to the result's Why (the historical
# attempt stays named in the phase A order-check line and the observer's "N1 order OK" line), never to the Records.
function Get-FsN1Prereq([string]$RepoBuild, [string]$Serial) {
    $no = { param($w, $rs) [pscustomobject]@{ Ok = $false; Why = $w; Records = @($rs) } }
    if (-not (Test-FsN1Unit $Serial)) { return (& $no "'$Serial' is not one of the two units (Unit 2 QUEST3UNIT2, Unit 1 QUEST3UNIT1)" @()) }
    if ($Serial -ceq $script:FsK1aUnit1 -and -not $script:FsN1Unit1Enabled) { return (& $no "N1 runs on Unit 2 only (PM decision 2026-10-16): a Unit 1 run needs a new PM decision and package revision" @()) }
    $pa = @(Get-FsN1PriorAttempts (Join-Path $RepoBuild 'n1') $Serial)
    $supWhy = ''
    if ($pa.Count) {
        $sv = Test-FsN1SupersededPrior (Join-Path $RepoBuild 'n1') $Serial $pa
        if (-not $sv.Ok) { return (& $no "$(Get-FsN1UnitName $Serial) already has an N1 attempt ($($pa -join ', ')): one N1 attempt per unit; a further attempt needs the Chair's explicit authority and a new package revision (FS-R-013 s.3, s.5)$(if ($sv.Why) { " ($($sv.Why))" })" @()) }
        $supWhy = $sv.Why
    } elseif ($Serial -ceq $script:FsK1aUnit2) {
        $hm = Get-FsN1HistoryMissing (Join-Path $RepoBuild 'n1'); if ($hm) { return (& $no "Unit 2 ($Serial): $hm" @()) }
    }
    if ($Serial -ceq $script:FsK1aUnit2) {
        # coordinator decision 2026-10-16: after BOTH K1a attempts and after K1g on Unit 2 (K1g's own gate functions)
        $ka = Get-FsK1gK1aGate (Join-Path $RepoBuild 'k1a')
        $nw = { param($t) (([string]$t -replace "^K1g needs both units' (K1a outcomes first|clean K1A PASS): ", '') -replace '\bK1g opens only after\b', 'N1 on Unit 2 opens only after' -replace ' \(Unit 1 K1g blocked\)\z', '') }
        if (-not $ka.Ok) { return (& $no "N1 on Unit 2 needs both K1a attempts first: $(& $nw $ka.Why)" @()) }
        $kg = Get-FsK1gUnit2Outcome (Join-Path $RepoBuild 'k1g')
        if (-not $kg.Ok) { return (& $no "N1 on Unit 2 needs Unit 2's clean K1G PASS first (the write guard proven): $(& $nw $kg.Why)" @()) }
        $mk = { param($t) if ([string]$t -cmatch 'MemTotal ([0-9]+) kB') { [long]$Matches[1] } else { $null } }
        $recs = @([pscustomobject]@{ Stage = 'k1a'; Serial = $script:FsK1aUnit2; Nonce = $ka.Unit2.Nonce; Outcome = $ka.Unit2.Outcome; File = $ka.Unit2.File; Sha256 = $ka.Unit2.Sha256; MemTotalKb = (& $mk $ka.Unit2.MemTotal) },
                  [pscustomobject]@{ Stage = 'k1a'; Serial = $script:FsK1aUnit1; Nonce = $ka.Unit1.Nonce; Outcome = $ka.Unit1.Outcome; File = $ka.Unit1.File; Sha256 = $ka.Unit1.Sha256; MemTotalKb = (& $mk $ka.Unit1.MemTotal) },
                  [pscustomobject]@{ Stage = 'k1g'; Serial = $script:FsK1aUnit2; Nonce = $kg.Nonce; Outcome = $kg.Outcome; File = $kg.File; Sha256 = $kg.Sha256; MemTotalKb = $null })
    } else {
        # the dormant Unit 1 rule (not open: PM decision 2026-10-16)
        $k = Get-FsN1StageOutcome (Join-Path $RepoBuild 'k1a') 'k1a' $Serial
        if (-not $k.Ok) { return (& $no "N1 on $(Get-FsN1UnitName $Serial) needs its clean K1A PASS first: $($k.Why)" @()) }
        $recs = @([pscustomobject]@{ Stage = 'k1a'; Serial = $Serial; Nonce = $k.Nonce; Outcome = $k.Outcome; File = $k.File; Sha256 = $k.Sha256; MemTotalKb = $k.MemTotalKb })
        $n2 = Get-FsN1StageOutcome (Join-Path $RepoBuild 'n1') 'n1' $script:FsK1aUnit2
        if (-not $n2.Ok) { return (& $no "N1 on Unit 1 needs Unit 2's clean N1 PASS first: $($n2.Why)" $recs) }
        $recs += [pscustomobject]@{ Stage = 'n1'; Serial = $script:FsK1aUnit2; Nonce = $n2.Nonce; Outcome = $n2.Outcome; File = $n2.File; Sha256 = $n2.Sha256; MemTotalKb = $n2.MemTotalKb }
    }
    [pscustomobject]@{ Ok = $true; Why = ((@($recs | ForEach-Object { "$($_.Stage.ToUpper()) $(Get-FsN1UnitName $_.Serial) nonce $($_.Nonce): $($_.Outcome)$(if ($null -ne $_.MemTotalKb) { ", MemTotal $($_.MemTotalKb) kB" })" }) -join '; ') + $(if ($supWhy) { "; $supWhy" } else { '' })); Records = $recs }
}
