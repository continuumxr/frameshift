# FrameShift K1g - the two units and the ORDER GATE (Windows PowerShell 5.1; a library: dot-source it). Read only: no
# device, no network, no write. Used by the K1g sign-off tooling (private) (phase A) and fs-observe-k1g.ps1 (the attempt gate).
#
# K1g ("the boot-chain write guard is proven", FS-R-013 s.5/s.6) runs on BOTH Quest 3 units, one at a time, AFTER K1a
# (FS-R-013 s.5: K1a -> K1g -> K1i):
#   - a K1g attempt on Unit 2 (QUEST3UNIT2) opens only when BOTH units' K1a attempts are done and every K1a attempt
#     in the K1a ledger (build\k1a\attempted) of Unit 2 AND of Unit 1 has a bound, write-once classify-k1a.json of
#     K1A PASS whose after-session record (checklist phase F) is clean, exactly as fs-k1a-units.ps1's Unit 1 gate
#     defines clean (AF and AA ended OK, back by itself, no dump mode, no recovery fault, follow-ups finished, highest
#     reading below 400), PLUS the FS-R-013 s.2 MemTotal check the pinned K1a classifier does not make: the bound
#     capture.raw of each K1a attempt is decoded again (Test-Fsb1Record, exp k1a, its collect.json challenge) and its
#     mem step must hold exactly one valid, positive "MemTotal: <n> kB" line (missing or malformed blocks K1g; it is
#     never a reason for another K1a attempt);
#   - a K1g attempt on Unit 1 (QUEST3UNIT1) opens only when the K1a gate above holds AND every Unit 2 K1g attempt in
#     the K1g ledger (build\k1g\attempted) has a bound classify-k1g.json (schema frameshift.fs-classify-k1g.v1) of
#     K1G PASS with a clean after-session record, AND phase A of the Unit 1 cycle answered A5 (Unit 2's K1g result was
#     reported to the PM; fs-observe-k1g.ps1 checks that A5 approved the current record): K1a's Unit 1 rule, mirrored.
#   K1A/K1G REVIEW, FAIL, INTEGRITY FAULT, INCONCLUSIVE, an unclean PASS, a missing or non-binding record, or an
#   attempt with no record block (fail-closed; no clearance shortcut, FS-R-013 s.3).
#   The K1a part is fail-closed over EVERY K1a attempt of both units: each must be a bound, clean K1A PASS. A K1a repeat
#   the Chair might authorise after an INCONCLUSIVE (or any other non-PASS) would therefore still block K1g: such a
#   repeat needs a reviewed revision of this gate (for example naming the superseded attempt), not a workaround.
#   NO AUTOMATIC REPEAT (FS-R-013 s.5: "Successful execution does not itself create standing-repeat authority"): a unit
#   that already has ANY K1g attempt in the K1g ledger (whatever its outcome, or none) is refused a new K1g attempt
#   (Get-FsK1gPriorAttempts); a repeat needs a reviewed package revision or the Chair's ruling.
#   THE ONE SUPERSESSION (gate revision r1, k1g/CHANGES-gate-r1.md; FS-R-016 s.3, s.5): $script:FsK1gSupersession below
#   recognises exactly one historical K1g attempt, Unit 2's r2 attempt 0cbd71dd67acc301 (K1G REVIEW: the probe ABORTed
#   before arming, cases=0; J-207), as superseded FOR PROGRESSION by the reviewed r3 candidate lineage. It stays a
#   K1G REVIEW (never read as a PASS); its ledger entry, observer, collector and record stay in place. Only when that
#   record is exactly the pinned one, after its ordinary evidence bindings have validated:
#     - no automatic repeat (Get-FsK1gPriorAttempts, both discovery paths: the ledger and the observe.json enumeration):
#       Unit 2 may have ONE further K1g attempt, and only while the checkout's K1g candidate table is the pinned r3 one
#       (the observer then accepts only the r3 candidate or a nonce-only rebuild of it); once that attempt is registered,
#       another is refused, whatever its outcome (or none);
#     - Unit 2's outcome (Get-FsK1gUnit2Outcome: Unit 1's K1g gate, and N1's gate, which reads it unchanged): the ONE other
#       Unit 2 attempt (the successor), later than it and of the r3 lineage by its bound evidence, must be a bound, clean
#       K1G PASS. No successor, any other outcome, an unclean PASS, a second successor or any unbound file blocks.
#   While the committed evidence of that attempt is in the checkout, a Unit 2 K1g ledger WITHOUT it is refused (not read
#   as "no attempt"); and on the supersession path the attempt.lock Register-FsAttempt leaves in each attempted image
#   directory is a third discovery path (a hidden or renamed attempt still counts).
#   There is no switch, no blanket REVIEW exclusion, no ledger deletion and no "latest record wins" rule.
# Each K1g attempt: its own fresh nonce (a nonce-only rebuild of the reviewed K1g candidate), its own readback rows
# (the readback rows (private), one set per unit; the same build, slot and ranges) and its own
# ledger entry (build\k1g\attempted\<nonce>.attempted, the note names the serial). The spent-nonce ledger is shared with
# K1a's: a nonce in build\k1a\attempted is spent for K1g too (fs-observe-k1g.ps1).
# Known hardware faults, recorded and never compensated: Unit 2 IPD slider and proximity sensor; Unit 1 proximity sensor.
# K1g reads no sensor, so neither fault affects a K1g result.
# Residual risk (as K1a's gate, documented, not detected): the gate trusts the records' fields and the files they bind; a
# deliberate hand edit of a record, a capture or collect.json (FSB1 carries no MAC), or the removal of a whole attempt
# directory together with its ledger entry is not detected. That would be falsification of a test record.
# The one exception: the historical record the supersession recognises is pinned byte for byte (its record and ledger
# entry, in build\k1g and in the committed evidence copies), so an edit of THAT record is detected.
. (Join-Path $PSScriptRoot 'fs-k1a-units.ps1')            # the K1a units, outcome schema and pins (read only)
. (Join-Path $PSScriptRoot '..\common\host\fsb1.ps1')     # Test-Fsb1Record (read only): the K1a MemTotal re-check
$script:FsK1gUnit2 = 'QUEST3UNIT2'
$script:FsK1gUnit1 = 'QUEST3UNIT1'
$script:FsK1gUnitNames = [ordered]@{ 'QUEST3UNIT2' = 'Unit 2'; 'QUEST3UNIT1' = 'Unit 1' }
$script:FsK1gOutcomes = @('K1G PASS', 'K1G REVIEW', 'K1G FAIL', 'INTEGRITY FAULT', 'INCONCLUSIVE')
$script:FsK1gClassifySchema = 'frameshift.fs-classify-k1g.v1'
# The classifier's expected facts, as pinned (= fs-classify-k1g.ps1's parameter defaults; a host test checks they agree).
# The banner's release token (5.10.246-ga9c63e24cb76) is confirmed by the coordinator after the K1g kernel build; it is
# also the FSV1 kernel release in fs-collect-k1g.ps1 (the same host test checks all three).
$script:FsK1gPinBanner = 'Linux version 5.10.246-ga9c63e24cb76 (frameshift@k1g) (Android (8508608, based on r450784e) clang version 14.0.7 (https://android.googlesource.com/toolchain/llvm-project 4c603efb0cca074e9238af8b4106c30add4418f6), LLD 14.0.7) #1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026'
$script:FsK1gPinConfigSha = '4aa0c894655627f6ff39476ac2a45abb4c224ee0053957d5002c694b0602826b'   # the exact K1a config
$script:FsK1gPinModules = 95
$script:FsK1gUnitsDir = $PSScriptRoot
# FS-R-013 s.3, the Chair's identity/slot after-check sentence, VERBATIM (every place that labels it verbatim uses
# this text exactly), and the K1g addition, always as a separate line labelled as the K1g addition.
$script:FsK1gChairSentence = 'misc, devinfo and partition-content invariance were not measured.'
$script:FsK1gAddition = 'Within the K1g boot, the probe''s fail-closed read rows measured the listed ranges before and after the guard cases.'
$script:FsK1gK1aSteps = @('kernel', 'config', 'mem', 'modules', 'kmsg', 'fs', 'usb', 'log')
# The K1a classifiers whose records the K1g gate accepts: the pinned one (SIGNOFF-k1a) and its proposed revision r2 (which
# also requires MemTotal). Either way the gate re-checks MemTotal itself.
$script:FsK1gK1aClassifiers = @('fs-classify-k1a.ps1', 'fs-classify-k1a-r2.ps1')
# THE ONE SUPERSESSION (gate revision r1; FS-R-016 s.3, s.5). Every value is pinned here; none is taken from a record.
# Naming any other attempt needs a reviewed edit of this file (a host pin of SIGNOFF-k1g and SIGNOFF-n1).
#   - the historical record (FS-R-016 s.3): Unit 2's serial, the nonce, the outcome, the SHA-256 of the full bound
#     classify-k1g.json (in build\k1g AND in the committed evidence copy, byte for byte), its guard result line (the
#     pre-arming ABORT, cases=0), the start of its reason (the classifier's ABORT-before-arming item, which must be the
#     reason's only item), and the SHA-256 of its ledger entry (both copies);
#   - the r3 lineage (FS-R-016 s.4): the reviewed candidate image and its directory (its nonce), the r3 probe binary, and
#     the SHA-256 of fs-nonceonly-k1g.ps1 holding that candidate as the current reviewed one. r2 and r3 share the kernel
#     banner, config and module count, so those prove nothing here; the lineage is the observer's nonce-only candidate
#     check (against the pinned table) at the attempt, and, afterwards, the successor's bound observe.json, its ledger
#     entry and its build MANIFEST (Test-FsK1gSupersedingCandidate);
#   - the ruling: FS-R-016, and the SHA-256 of relays\FS-R-016.md read with CR-LF as LF (its committed LF bytes): the supersession
#     is refused if the committed ruling file is missing or differs.
$script:FsK1gSupersession = [ordered]@{
    Serial               = 'QUEST3UNIT2'
    Nonce                = '0cbd71dd67acc301'
    Outcome              = 'K1G REVIEW'
    ClassifySha256       = 'b01996d74606a219b347982a8be24e47014da7f9974def08d39f9aeeb8f593bd'
    LedgerSha256         = '14ba6565424f051527f9f8ba4059a07983801672cfbccdb3cf4b25ed343842ad'
    GuardResult          = 'FSBG-PROBE RESULT: ABORT nonce=0cbd71dd67acc301 cases=0 pass=0 fail=0 mode=device'
    ReasonStart          = 'no FAIL-class fact; review before any further run: the guard probe ABORTed before arming: no armed guard test case was attempted ('
    EvidenceClassify     = 'devices\quest3\evidence\unit2-k1g-20261019\observe\classify-k1g.json'
    EvidenceLedger       = 'devices\quest3\evidence\k1g-attempt-ledger-20261019\0cbd71dd67acc301.attempted'
    SupersededBy         = '1ee9f1059d91b1f100e6bde31910980c65befa42c5dd5b8de12e38d187ff2ce4'
    SupersededByDir      = '20261019T031348Z-1c8ade5c6ec2b063'
    ProbeSha256          = 'c1de030c51f1ee4b785c96b1f497bc6339d2b404f2431f07edf3aac39375077d'
    CandidateTableSha256 = '085f149429324f4b23f9b8b3c9f44880e2cbcb0a507758232adbb13d4a2bac1b'
    Ruling               = 'FS-R-016'
    RulingSections       = 's.3, s.5'
    RulingSha256         = 'a3d138f990e7435a4c2d57ac0793bb1bc7a834c0e806cc430a3a5c6e79569b9d'
}
$script:FsK1gRepoRoot = Join-Path $PSScriptRoot '..\..\..'      # the evidence copies and relays\ (the host tests point it elsewhere)

function Test-FsK1gUnit([string]$Serial) { $Serial -cmatch '^[A-Za-z0-9]{6,32}\z' -and (@($script:FsK1gUnitNames.Keys) -ccontains $Serial) }
function Get-FsK1gUnitName([string]$Serial) { if (Test-FsK1gUnit $Serial) { [string]$script:FsK1gUnitNames[$Serial] } else { '' } }
function Get-FsK1gFileSha([string]$Path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { '' } }
function Get-FsK1gTextSha([string]$Text) { $sh = [Security.Cryptography.SHA256]::Create(); try { -join ($sh.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) } finally { $sh.Dispose() } }

# FS-R-013 s.2: MemTotal is REQUIRED: exactly one "MemTotal:" line in the mem step, and it is a valid, positive integer kB
# (ASCII digits, no leading zero, at most 16 digits). Returns @{ Ok; Value (long kB or $null); Why }.
function Test-FsK1gMemTotal([string]$MemText) {
    if ($null -eq $MemText) { $MemText = '' }
    $all = @([regex]::Matches($MemText, '(?m)^MemTotal:.*$'))
    if ($all.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Value = $null; Why = 'MemTotal is missing from the mem step' } }
    if ($all.Count -ne 1) { return [pscustomobject]@{ Ok = $false; Value = $null; Why = "the mem step holds $($all.Count) MemTotal lines (exactly one expected)" } }
    $l = $all[0].Value.TrimEnd("`r")
    if ($l -cnotmatch '^MemTotal:[ \t]+([1-9][0-9]{0,15}) kB\z') { return [pscustomobject]@{ Ok = $false; Value = $null; Why = "MemTotal is malformed ('$(($l -replace '[^ -~]', '?'))'; a positive integer kB required)" } }
    [pscustomobject]@{ Ok = $true; Value = [long]$Matches[1]; Why = "MemTotal $($Matches[1]) kB" }
}

# The K1a MemTotal re-check (FS-R-013 s.2) over one attempt's bound collector output: collect.json (its nonce and
# challenge) and capture.raw, decoded again. Returns @{ Ok; Why; MemTotal }.
function Test-FsK1gK1aCaptureMem([string]$CollectDir) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; MemTotal = $null } }
    try { $c = [IO.File]::ReadAllText((Join-Path $CollectDir 'collect.json')) | ConvertFrom-Json } catch { return (& $no 'collect.json unreadable') }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $n = [string](& $pv $c 'Nonce'); $ch = [string](& $pv $c 'Challenge')
    if ($n -cnotmatch '^[0-9a-f]{16}\z' -or $ch -cnotmatch '^[0-9a-f]{32}\z') { return (& $no 'collect.json carries no nonce or runner challenge: the K1a record cannot be decoded again') }
    try { [byte[]]$b = [IO.File]::ReadAllBytes((Join-Path $CollectDir 'capture.raw')) } catch { return (& $no 'capture.raw unreadable') }
    $r = Test-Fsb1Record -Bytes $b -Exp 'k1a' -Nonce $n -Challenge $ch -Steps $script:FsK1gK1aSteps
    if (-not $r.Ok) { return (& $no "the bound capture.raw is not a valid K1a record (FSB1 $($r.Reason) $($r.Detail))") }
    $mem = $null
    foreach ($st in $r.Steps) { if ([string]$st['id'] -ceq 'mem') { $mem = [System.Text.Encoding]::GetEncoding(28591).GetString([byte[]]$st['out']) } }
    $m = Test-FsK1gMemTotal $mem
    [pscustomobject]@{ Ok = $m.Ok; Why = $m.Why; MemTotal = $m.Value }
}

# One unit's attempts in one ledger (the K1a or the K1g one), as fs-k1a-units.ps1's Get-FsK1aUnit2Outcome walks Unit 2's,
# for any unit and stage. EVERY ledger entry <BuildRoot>\attempted\<nonce>.attempted whose note names $Serial must
# resolve to exactly one <stamp>-<nonce> build directory with exactly one observe-*\observe.json of this stage, nonce and
# serial, and next to it a $RecordName that binds it (schema, nonce, serial, Fixture the JSON boolean false, one of the
# five outcomes, the SHA-256 of observe.json, collect\collect.json and collect\capture.raw, a classifier of
# $ClassifierFiles in this checkout, the pinned banner/config/module count); an observe.json of $Serial without its
# ledger entry blocks too. $Extra (optional) { param($dir) -> @{ Ok; Why } } adds a check per attempt (the K1a MemTotal).
# Returns @{ Ok; Why; Records = [ { Nonce; Outcome; File; Sha256; Utc; LedgerUtc; Dir; AfterClean; AfterWhy; ExtraOk; ExtraWhy } ]; Ledger }.
function Get-FsK1gUnitRecords {
    param([string]$BuildRoot, [string]$Serial, [string]$Stage, [string]$RecordName, [string]$Schema, [string[]]$Outcomes,
          [string[]]$ClassifierFiles, [string]$PinBanner, [string]$PinConfigSha, [int]$PinModules, [string]$What, [scriptblock]$Extra = $null)
    $unit = Get-FsK1gUnitName $Serial
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Records = @(); Ledger = $null } }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $rd = { param([string]$f) try { [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $null } }
    if (-not $BuildRoot -or -not (Test-Path -LiteralPath $BuildRoot -PathType Container)) { return (& $no "no $What build root '$BuildRoot'") }
    $clsShas = @($ClassifierFiles | ForEach-Object { Get-FsK1gFileSha (Join-Path $script:FsK1gUnitsDir $_) } | Where-Object { $_ })
    $led = Join-Path $BuildRoot 'attempted'
    $all = @(Get-ChildItem -LiteralPath $led -Force -ErrorAction SilentlyContinue)     # every entry, no filter
    $odd = @($all | Where-Object { $_.PSIsContainer -or $_.Name -cnotmatch '^[0-9a-f]{16}\.attempted\z' })
    if ($odd.Count) { return (& $no "unexpected $What ledger file $($odd[0].FullName) (not <16 hex>.attempted): blocked") }
    $recs = New-Object System.Collections.Generic.List[object]
    foreach ($m in $all) {
        $n = $m.Name.Substring(0, 16)
        $note = (@([IO.File]::ReadAllLines($m.FullName)) -join ' ')
        $lm = [regex]::Match($note, ' serial=([A-Za-z0-9]+) ')
        if (-not $lm.Success) { return (& $no "$What ledger entry $($m.FullName) names no serial: cannot tell whose attempt it was; blocked") }
        if ($lm.Groups[1].Value -cne $Serial) { continue }
        $tm = [regex]::Match($note, '^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z) ')
        if (-not $tm.Success) { return (& $no "$What ledger entry $($m.FullName) has no UTC time (yyyy-MM-ddTHH:mm:ss[.fffffff]Z): blocked") }
        $why = "$unit $What attempt nonce $n (ledger $($m.FullName))"
        $dirs = @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch ('^[0-9]{8}T[0-9]{6}Z-' + $n + '\z') })
        if ($dirs.Count -ne 1) { return (& $no "${why}: $($dirs.Count) build directories (exactly 1 expected); blocked") }
        $ods = @(Get-ChildItem -LiteralPath $dirs[0].FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'observe.json') -PathType Leaf })
        if ($ods.Count -ne 1) { return (& $no "${why}: $($ods.Count) observe directories with observe.json (exactly 1 expected); blocked") }
        $od = $ods[0].FullName; $oj = Join-Path $od 'observe.json'; $cj = Join-Path $od $RecordName
        $ob = & $rd $oj
        if ($null -eq $ob -or [string](& $pv $ob 'Stage') -cne $Stage -or [string](& $pv $ob 'Nonce') -cne $n -or [string](& $pv $ob 'Serial') -cne $Serial) { return (& $no "${why}: its observe.json is not this $unit $What attempt; blocked") }
        if (-not (Test-Path -LiteralPath $cj -PathType Leaf)) { return (& $no "${why}: no $RecordName, no outcome recorded; an attempt that has none (no console, an interrupted observer, phase F or the classifier not yet run) blocks: blocked") }
        $c = & $rd $cj
        $fx = & $pv $c 'Fixture'
        $colJ = Join-Path $od 'collect\collect.json'; $colR = Join-Path $od 'collect\capture.raw'
        $col = if (Test-Path -LiteralPath $colJ -PathType Leaf) { & $rd $colJ } else { $null }
        $ok = ($null -ne $c -and [string](& $pv $c 'Schema') -ceq $Schema -and [string](& $pv $c 'Nonce') -ceq $n -and [string](& $pv $c 'Serial') -ceq $Serial -and
               ($fx -is [bool]) -and -not $fx -and ($Outcomes -ccontains [string](& $pv $c 'Outcome')) -and [string](& $pv $c 'ObserveJsonSha256') -ceq (Get-FsK1gFileSha $oj) -and
               $null -ne $col -and [string](& $pv $col 'Nonce') -ceq $n -and [string](& $pv $c 'CollectJsonSha256') -ceq (Get-FsK1gFileSha $colJ) -and
               (Test-Path -LiteralPath $colR -PathType Leaf) -and [string](& $pv $c 'CaptureSha256') -ceq (Get-FsK1gFileSha $colR) -and ($clsShas -ccontains [string](& $pv $c 'ClassifierSha256')) -and
               [string](& $pv $c 'BannerSha256') -ceq (Get-FsK1gTextSha $PinBanner) -and [string](& $pv $c 'ConfigSha') -ceq $PinConfigSha -and [string](& $pv $c 'Modules') -ceq [string]$PinModules)
        if (-not $ok) { return (& $no "${why}: its $RecordName does not bind this attempt (schema, nonce, serial, fixture, outcome, the SHA-256 of observe.json, collect\collect.json and collect\capture.raw, a classifier of this checkout ($($ClassifierFiles -join ', ')) and its pinned banner, config and module count); blocked") }
        $af = & $pv $c 'After'; $aw = @()
        if ($null -eq $af) { $aw += 'no after-session record' }
        else {
            foreach ($kv in @(@('Clean', $true), @('AfOk', $true), @('AaOk', $true), @('ReturnedByItself', $true), @('DumpMode', $false), @('RecoveryFault', $false), @('FollowUpsFinished', $true))) {
                $x = & $pv $af $kv[0]; if (-not ($x -is [bool]) -or $x -ne $kv[1]) { $aw += "$($kv[0]) is '$x'" } }
            $mt = & $pv $af 'MaxTemp'; if ($null -eq $mt -or [string]$mt -cnotmatch '^[0-9]{1,4}\z' -or [int]$mt -ge 400) { $aw += "highest reading '$mt' (below 400 required)" }
        }
        $ex = if ($null -ne $Extra) { & $Extra $od } else { [pscustomobject]@{ Ok = $true; Why = '' } }
        $recs.Add([pscustomobject]@{ Nonce = $n; Outcome = [string]$c.Outcome; File = $cj; Sha256 = (Get-FsK1gFileSha $cj); Utc = [string](& $pv $c 'Utc'); LedgerUtc = $tm.Groups[1].Value; Dir = $od
                                     AfterClean = ($aw.Count -eq 0); AfterWhy = ($aw -join '; '); ExtraOk = [bool]$ex.Ok; ExtraWhy = [string]$ex.Why })
    }
    foreach ($bd in @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\z' })) {
        $bn = $bd.Name.Substring($bd.Name.Length - 16)
        foreach ($oj2 in @(Get-ChildItem -LiteralPath $bd.FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'observe.json' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
            $ob2 = & $rd $oj2
            if ($null -ne $ob2 -and [string](& $pv $ob2 'Serial') -ceq $Serial -and -not (Test-Path -LiteralPath (Join-Path $led "$bn.attempted") -PathType Leaf)) {
                return (& $no "a $unit $What attempt ($oj2) has no ledger entry $led\$bn.attempted (deleted or renamed): blocked") }
        }
    }
    [pscustomobject]@{ Ok = $true; Why = "$($recs.Count) $unit $What attempt(s) bound"; Records = $recs.ToArray(); Ledger = $led }
}

# The latest record of a list (by ledger UTC), and the rule "every record is <Pass>, clean (and its extra check holds)".
function Get-FsK1gCleanPass($Records, [string]$Pass, [string]$Review, [string]$UnitWhat, [string]$Consequence) {
    if (@($Records).Count -eq 0) { return [pscustomobject]@{ Ok = $false; Why = "no $UnitWhat attempt in the ledger: $Consequence"; Best = $null } }
    foreach ($r in $Records) {
        if ($r.Outcome -ceq $Review) { return [pscustomobject]@{ Ok = $false; Why = "$UnitWhat attempt nonce $($r.Nonce) is $Review ($($r.File)): blocked; the Chair reviews it (FS-R-012 s.3, FS-R-013 s.3: no clearance shortcut)"; Best = $null } }
        if ($r.Outcome -cne $Pass) { return [pscustomobject]@{ Ok = $false; Why = "$UnitWhat attempt nonce $($r.Nonce) is $($r.Outcome) ($($r.File)): blocked; a new package review first"; Best = $null } }
        if (-not $r.AfterClean) { return [pscustomobject]@{ Ok = $false; Why = "$UnitWhat attempt nonce $($r.Nonce) is $Pass but its after-session record is not clean ($($r.AfterWhy)): blocked; a new package review first"; Best = $null } }
        if (-not $r.ExtraOk) { return [pscustomobject]@{ Ok = $false; Why = "$UnitWhat attempt nonce $($r.Nonce) is $Pass, but $($r.ExtraWhy) (FS-R-013 s.2: MemTotal required; this blocks progression and is never a reason for another attempt)"; Best = $null } }
    }
    $best = $null
    foreach ($r in $Records) { if ($null -eq $best -or [string]::CompareOrdinal($r.LedgerUtc, [string]$best.LedgerUtc) -gt 0) { $best = $r } }
    [pscustomobject]@{ Ok = $true; Why = "$UnitWhat attempt nonce $($best.Nonce): $($best.Outcome), after-session record clean ($($best.File))"; Best = $best }
}

# The K1a prerequisite of every K1g attempt: BOTH units' K1a attempts (build\k1a) bound, K1A PASS, clean, MemTotal valid.
# Returns @{ Ok; Why; Unit2; Unit1 } (Unit2/Unit1: the latest record of each unit: Nonce, Outcome, File, Sha256).
function Get-FsK1gK1aGate([string]$K1aBuildRoot) {
    $res = [ordered]@{ Ok = $false; Why = ''; Unit2 = $null; Unit1 = $null }
    $memX = { param($od) Test-FsK1gK1aCaptureMem (Join-Path $od 'collect') }
    foreach ($s in @($script:FsK1gUnit2, $script:FsK1gUnit1)) {
        $u = Get-FsK1gUnitName $s
        $w = Get-FsK1gUnitRecords -BuildRoot $K1aBuildRoot -Serial $s -Stage 'k1a' -RecordName 'classify-k1a.json' -Schema $script:FsK1aClassifySchema -Outcomes $script:FsK1aOutcomes `
            -ClassifierFiles $script:FsK1gK1aClassifiers -PinBanner $script:FsK1aPinBanner -PinConfigSha $script:FsK1aPinConfigSha -PinModules $script:FsK1aPinModules -What 'K1a' -Extra $memX
        if (-not $w.Ok) { $res.Why = "K1g needs both units' K1a outcomes first: $($w.Why)"; return [pscustomobject]$res }
        $g = Get-FsK1gCleanPass $w.Records 'K1A PASS' 'K1A REVIEW' "$u ($s) K1a" "K1g opens only after BOTH units' K1a attempts (Unit 2, then Unit 1) have a bound, clean K1A PASS"
        if (-not $g.Ok) { $res.Why = "K1g needs both units' clean K1A PASS: $($g.Why)"; return [pscustomobject]$res }
        $ref = [pscustomobject]@{ Nonce = $g.Best.Nonce; Outcome = $g.Best.Outcome; File = $g.Best.File; Sha256 = $g.Best.Sha256; MemTotal = $g.Best.ExtraWhy }
        if ($s -ceq $script:FsK1gUnit2) { $res.Unit2 = $ref } else { $res.Unit1 = $ref }
    }
    $res.Ok = $true
    $res.Why = "K1a done on both units: Unit 2 nonce $($res.Unit2.Nonce) and Unit 1 nonce $($res.Unit1.Nonce) K1A PASS, after-session records clean, $($res.Unit2.MemTotal) / $($res.Unit1.MemTotal)"
    [pscustomobject]$res
}

# THE ONE SUPERSESSION: the SHA-256 of a text file read with every CR-LF as LF (= the SHA-256 of its committed LF bytes;
# relays\ may be checked out with CR-LF on Windows). '' if unreadable.
function Get-FsK1gLfSha([string]$Path) {
    try { [byte[]]$b = [IO.File]::ReadAllBytes($Path) } catch { return '' }
    $l1 = [Text.Encoding]::GetEncoding(28591)      # ISO-8859-1: one char per byte, a byte-exact round trip
    [byte[]]$lf = $l1.GetBytes($l1.GetString($b).Replace("`r`n", "`n"))
    $sh = [Security.Cryptography.SHA256]::Create(); try { -join ($sh.ComputeHash($lf) | ForEach-Object { $_.ToString('x2') }) } finally { $sh.Dispose() }
}
# THE ONE SUPERSESSION, a third discovery path (safety review): the attempt.lock that Register-FsAttempt writes into the
# attempted image's directory with the ledger entry's note. Returns the lock files of every directory directly under
# $BuildRoot whose note names $Serial or names no serial (cannot tell): @{ File; Nonce } ('' if the directory name is
# not <stamp>-<nonce>).
function Get-FsK1gUnitLocks([string]$BuildRoot, [string]$Serial) {
    $out = @()
    foreach ($bd in @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue)) {
        $lk = Join-Path $bd.FullName 'attempt.lock'
        if (-not (Test-Path -LiteralPath $lk)) { continue }
        $note = try { (@([IO.File]::ReadAllLines($lk)) -join ' ') } catch { '' }
        $lm = [regex]::Match($note, ' serial=([A-Za-z0-9]+) ')
        $bn = if ($bd.Name -cmatch '^[0-9]{8}T[0-9]{6}Z-([0-9a-f]{16})\z') { $Matches[1] } else { '' }
        if (-not $lm.Success -or $lm.Groups[1].Value -ceq $Serial) { $out += [pscustomobject]@{ File = $lk; Nonce = $bn } }
    }
    $out
}
# THE ONE SUPERSESSION (safety review): the committed evidence says the historical attempt happened, so a Unit 2 K1g
# ledger without it (deleted, or a working copy whose build\k1g was not carried over) is refused, not read as "no
# attempt". Returns '' when the evidence ledger copy is absent from the checkout (nothing to compare), or the refusal.
function Get-FsK1gHistoryMissing([string]$BuildRoot) {
    $s = $script:FsK1gSupersession
    if (-not (Test-Path -LiteralPath (Join-Path $script:FsK1gRepoRoot $s.EvidenceLedger) -PathType Leaf)) { return '' }
    if (Test-Path -LiteralPath (Join-Path $BuildRoot "attempted\$($s.Nonce).attempted") -PathType Leaf) { return '' }
    "the historical Unit 2 K1g attempt $($s.Nonce) (K1G REVIEW; committed evidence $($s.EvidenceLedger)) is missing from this K1g ledger ($(Join-Path $BuildRoot 'attempted')): an attempt directory or ledger entry was removed, or this working copy lacks the shared build\k1g; blocked"
}
# A ledger UTC (yyyy-MM-ddTHH:mm:ss[.f-fffffff]Z) as a DateTime, or $null.
function ConvertFrom-FsK1gLedgerUtc([string]$t) {
    if ($t -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z\z') { return $null }
    try { [DateTime]::Parse($t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $null }
}
# The pins themselves: well-formed, naming a Unit 2 K1G REVIEW whose probe ABORTed before arming with cases=0, and the
# committed ruling file equal to the pinned one. Returns @{ Ok; Why; Ref } (Ref 'FS-R-016 s.3, s.5', for the messages).
function Test-FsK1gSupersessionPins {
    $s = $script:FsK1gSupersession
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "the supersession of $($s.Nonce) is not applied: $w"; Ref = '' } }
    if ([string]$s.Serial -cne $script:FsK1gUnit2 -or [string]$s.Nonce -cnotmatch '^[0-9a-f]{16}\z' -or [string]$s.Outcome -cne 'K1G REVIEW' -or
        [string]$s.GuardResult -cne "FSBG-PROBE RESULT: ABORT nonce=$($s.Nonce) cases=0 pass=0 fail=0 mode=device" -or
        [string]$s.ReasonStart -cne 'no FAIL-class fact; review before any further run: the guard probe ABORTed before arming: no armed guard test case was attempted (' -or
        @(@('ClassifySha256', 'LedgerSha256', 'SupersededBy', 'ProbeSha256', 'CandidateTableSha256', 'RulingSha256') | Where-Object { [string]$s[$_] -cnotmatch '^[0-9a-f]{64}\z' }).Count -gt 0 -or
        [string]$s.SupersededByDir -cnotmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\z' -or [string]$s.Ruling -cnotmatch '^FS-R-[0-9]{3}\z') {
        return (& $no 'its pinned values are malformed or name something other than a Unit 2 K1G REVIEW whose probe ABORTed before arming with cases=0') }
    $rf = Join-Path $script:FsK1gRepoRoot "relays\$($s.Ruling).md"
    $rh = Get-FsK1gLfSha $rf
    if (-not $rh) { return (& $no "the ruling file relays\$($s.Ruling).md is missing") }
    if ($rh -cne [string]$s.RulingSha256) { return (& $no "relays\$($s.Ruling).md has SHA-256 $rh (CR-LF read as LF), not the pinned $($s.RulingSha256)") }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; Ref = "$($s.Ruling) $($s.RulingSections)" }
}
# The historical record, as Get-FsK1gUnitRecords bound it ($Rec, its ledger entry $LedgerFile; every ordinary binding has
# already held): exactly the pinned record, byte for byte (the build copy and the committed evidence copy), its ledger
# entry (both copies), the class (K1G REVIEW; the pre-arming ABORT with cases=0; the ABORT-before-arming reason as the
# reason's only item) and a clean after-session record. Returns @{ Ok; Why }.
function Test-FsK1gSupersededRecord($Rec, [string]$LedgerFile) {
    $s = $script:FsK1gSupersession
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "the attempt $($Rec.Nonce) is not the recognised historical record: $w" } }
    if ([string]$Rec.Nonce -cne [string]$s.Nonce) { return (& $no "another nonce (only $($s.Nonce) is recognised)") }
    if ([string]$Rec.Sha256 -cne [string]$s.ClassifySha256) { return (& $no "its classify-k1g.json ($($Rec.File)) has SHA-256 $($Rec.Sha256), not the pinned $($s.ClassifySha256) (edited, or another record)") }
    $ev = Get-FsK1gFileSha (Join-Path $script:FsK1gRepoRoot $s.EvidenceClassify)
    if ($ev -cne [string]$s.ClassifySha256) { return (& $no "the committed evidence copy $($s.EvidenceClassify) has SHA-256 '$ev', not the pinned $($s.ClassifySha256)") }
    $lh = Get-FsK1gFileSha $LedgerFile
    if ($lh -cne [string]$s.LedgerSha256) { return (& $no "its ledger entry $LedgerFile has SHA-256 '$lh', not the pinned $($s.LedgerSha256)") }
    $le = Get-FsK1gFileSha (Join-Path $script:FsK1gRepoRoot $s.EvidenceLedger)
    if ($le -cne [string]$s.LedgerSha256) { return (& $no "the committed ledger copy $($s.EvidenceLedger) has SHA-256 '$le', not the pinned $($s.LedgerSha256)") }
    $c = try { [IO.File]::ReadAllText($Rec.File) | ConvertFrom-Json } catch { $null }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    if ([string]$Rec.Outcome -cne [string]$s.Outcome -or [string](& $pv $c 'Outcome') -cne [string]$s.Outcome -or [string](& $pv $c 'Serial') -cne [string]$s.Serial) { return (& $no "its outcome is $($Rec.Outcome) (only the Unit 2 K1G REVIEW is recognised)") }
    if ([string](& $pv $c 'GuardResult') -cne [string]$s.GuardResult) { return (& $no "its guard result is not the pre-arming ABORT with cases=0 ('$(& $pv $c 'GuardResult')')") }
    # the reason is the classifier's ABORT-before-arming item ALONE: the '(' ending ReasonStart is closed by the reason's
    # last character (another review item would follow that ')' after '; ')
    $rsn = [string](& $pv $c 'Reason'); $rs0 = [string]$s.ReasonStart
    $ok = $rsn.StartsWith($rs0, [StringComparison]::Ordinal)
    if ($ok) { $dp = 0; for ($i = $rs0.Length - 1; $i -lt $rsn.Length; $i++) { if ($rsn[$i] -ceq '(') { $dp++ } elseif ($rsn[$i] -ceq ')') { $dp--; if ($dp -eq 0) { break } } }; $ok = ($dp -eq 0 -and $i -eq $rsn.Length - 1) }
    if (-not $ok) { return (& $no 'its reason is not the ABORT-before-arming review reason alone') }
    if (-not $Rec.AfterClean) { return (& $no "its after-session record is not clean ($($Rec.AfterWhy))") }
    [pscustomobject]@{ Ok = $true; Why = "the r2 attempt $($s.Nonce) stays K1G REVIEW (the probe ABORTed before arming, cases=0; classify-k1g.json $($s.ClassifySha256))" }
}
# The successor's r3 lineage, from its bound evidence (r2 and r3 share the banner, config and module count): its
# observe.json (bound by its record) names the r3 candidate itself or a nonce-only rebuild of it, exactly as
# fs-observe-k1g.ps1 writes them (the observer's nonce-only check against the pinned candidate table); its ledger entry
# names the same image; and its build MANIFEST names this nonce, that image and the r3 probe binary. Returns @{ Ok; Why }.
function Test-FsK1gSupersedingCandidate($Rec, [string]$LedgerFile) {
    $s = $script:FsK1gSupersession
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "the Unit 2 K1g attempt $($Rec.Nonce) is not shown to be of the r3 lineage ($($s.SupersededBy)): $w" } }
    $ob = try { [IO.File]::ReadAllText((Join-Path $Rec.Dir 'observe.json')) | ConvertFrom-Json } catch { $null }
    $no2 = [string](& $pv $ob 'NonceOnly'); $isha = [string](& $pv $ob 'ImageSha256')
    $cn = ([string]$s.SupersededByDir).Substring(([string]$s.SupersededByDir).Length - 16)
    $what = ''
    if ($no2 -ceq "the reviewed candidate ($($s.SupersededBy))" -and $isha -ceq [string]$s.SupersededBy -and [string]$Rec.Nonce -ceq $cn) { $what = "the r3 candidate $($s.SupersededBy)" }
    elseif ($no2 -ceq "a nonce-only rebuild of the reviewed candidate ($cn -> $($Rec.Nonce); fs-nonceonly-k1g checks passed)" -and $isha -cmatch '^[0-9a-f]{64}\z') { $what = "a nonce-only rebuild of the r3 candidate $($s.SupersededBy) (image $isha)" }
    else { return (& $no "its observe.json names '$no2' (image '$isha')") }
    $note = try { (@([IO.File]::ReadAllLines($LedgerFile)) -join ' ') } catch { '' }
    if ($note -cnotmatch (' image=' + $isha + ' ')) { return (& $no "its ledger entry $LedgerFile does not name the image $isha") }
    $mf = Join-Path (Split-Path -Parent $Rec.Dir) 'MANIFEST.txt'
    $m = try { [IO.File]::ReadAllText($mf) } catch { '' }
    if ($m -cnotmatch ('(?m)^nonce:\s+' + $Rec.Nonce + '\s') -or $m -cnotmatch ('(?m)^OUTPUT IMAGE:\s+boot-k1g\.img\s+size=[0-9]+\s+sha256=' + $isha + '\s*$') -or $m -cnotmatch ('(?m)^probe binary\s+' + $s.ProbeSha256 + '\s')) {
        return (& $no "its build MANIFEST ($mf) does not name this nonce, the image $isha and the r3 probe binary $($s.ProbeSha256)") }
    [pscustomobject]@{ Ok = $true; Why = $what }
}

# The Unit 1 K1g gate's own part: every Unit 2 K1g attempt (build\k1g) bound, K1G PASS, clean. Returns
# @{ Ok; Why; Nonce; Outcome; File; Sha256; Utc; Superseded } (the shape of K1a's Get-FsK1aUnit2Outcome, plus Superseded:
# $null, or the recognised historical record's Nonce, Outcome (K1G REVIEW), File, Sha256 and Ruling).
# THE ONE SUPERSESSION: when the recognised historical record is one of Unit 2's attempts, exactly as pinned, the ONE other
# Unit 2 attempt must be its successor: later than it, of the r3 lineage, a bound, clean K1G PASS. N1's gate reads this
# function unchanged (fs-n1-units.ps1), so the same rule opens N1 (FS-R-016 s.6).
function Get-FsK1gUnit2Outcome([string]$BuildRoot) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Nonce = $null; Outcome = $null; File = $null; Sha256 = $null; Utc = $null; Superseded = $null } }
    $w = Get-FsK1gUnitRecords -BuildRoot $BuildRoot -Serial $script:FsK1gUnit2 -Stage 'k1g' -RecordName 'classify-k1g.json' -Schema $script:FsK1gClassifySchema -Outcomes $script:FsK1gOutcomes `
        -ClassifierFiles @('fs-classify-k1g.ps1') -PinBanner $script:FsK1gPinBanner -PinConfigSha $script:FsK1gPinConfigSha -PinModules $script:FsK1gPinModules -What 'K1g'
    if (-not $w.Ok) { return (& $no "$($w.Why) (Unit 1 K1g blocked)") }
    $recs = @($w.Records); $sn = ''
    $sup = @($recs | Where-Object { [string]$_.Nonce -ceq [string]$script:FsK1gSupersession.Nonce })
    if ($sup.Count -eq 0) { $hm = Get-FsK1gHistoryMissing $BuildRoot; if ($hm) { return (& $no "$hm (Unit 1 K1g blocked)") } }
    if ($sup.Count -eq 1) {
        $pp = Test-FsK1gSupersessionPins
        $sv = if ($pp.Ok) { Test-FsK1gSupersededRecord $sup[0] (Join-Path $w.Ledger "$($sup[0].Nonce).attempted") } else { $pp }
        if ($sv.Ok) {
            $sref = [pscustomobject]@{ Nonce = $sup[0].Nonce; Outcome = $sup[0].Outcome; File = $sup[0].File; Sha256 = $sup[0].Sha256; Ruling = $pp.Ref }
            $sn = "$($sv.Why), superseded for progression (not a PASS) by the r3 candidate lineage $($script:FsK1gSupersession.SupersededBy) under $($pp.Ref)"
            $rest = @($recs | Where-Object { [string]$_.Nonce -cne [string]$sup[0].Nonce })
            if ($rest.Count -eq 0) { return (& $no "$sn; no successor Unit 2 (QUEST3UNIT2) K1g attempt yet: Unit 2's r3 attempt and its classifier result, reported to the PM, come first (Unit 1 K1g blocked)") }
            if ($rest.Count -ne 1) { return (& $no "${sn}; but Unit 2 has $($rest.Count) K1g attempts besides it (exactly one successor is permitted): blocked (Unit 1 K1g blocked)") }
            $r3 = $rest[0]
            $hid = @(Get-FsK1gUnitLocks $BuildRoot $script:FsK1gUnit2 | Where-Object { @($recs | ForEach-Object { [string]$_.Nonce }) -cnotcontains [string]$_.Nonce })
            if ($hid.Count) { return (& $no "${sn}; but $($hid[0].File) records a Unit 2 K1g attempt that is not in the ledger and observer records (hidden or renamed): blocked (Unit 1 K1g blocked)") }
            $t3 = ConvertFrom-FsK1gLedgerUtc ([string]$r3.LedgerUtc); $t2 = ConvertFrom-FsK1gLedgerUtc ([string]$sup[0].LedgerUtc)
            if ($null -eq $t3 -or $null -eq $t2 -or $t3 -le $t2) { return (& $no "${sn}; but the Unit 2 K1g attempt $($r3.Nonce) is not later than it (ledger $($r3.LedgerUtc)): blocked (Unit 1 K1g blocked)") }
            $g = Get-FsK1gCleanPass @($r3) 'K1G PASS' 'K1G REVIEW' 'Unit 2 (QUEST3UNIT2) K1g' 'Unit 2 first, then its classifier result, reported to the PM'
            if (-not $g.Ok) { return (& $no "$($g.Why); $sn (Unit 1 K1g blocked)") }
            $cd = Test-FsK1gSupersedingCandidate $r3 (Join-Path $w.Ledger "$($r3.Nonce).attempted")
            if (-not $cd.Ok) { return (& $no "${sn}; but $($cd.Why): blocked (Unit 1 K1g blocked)") }
            return [pscustomobject]@{ Ok = $true; Why = "$($g.Why), $($cd.Why); $sn"; Nonce = $g.Best.Nonce; Outcome = $g.Best.Outcome; File = $g.Best.File; Sha256 = $g.Best.Sha256; Utc = $g.Best.Utc; Superseded = $sref }
        }
        $sn = " ($($sv.Why))"
    }
    $g = Get-FsK1gCleanPass $recs 'K1G PASS' 'K1G REVIEW' 'Unit 2 (QUEST3UNIT2) K1g' 'Unit 2 first, then its classifier result, reported to the PM'
    if (-not $g.Ok) { return (& $no "$($g.Why)$sn (Unit 1 K1g blocked)") }
    [pscustomobject]@{ Ok = $true; Why = $g.Why; Nonce = $g.Best.Nonce; Outcome = $g.Best.Outcome; File = $g.Best.File; Sha256 = $g.Best.Sha256; Utc = $g.Best.Utc; Superseded = $null }
}

# NO AUTOMATIC REPEAT: any earlier K1g attempt of this unit in the K1g ledger (a ledger entry naming the serial, an entry
# naming no serial: cannot tell, or an observe.json of this unit under build\k1g) refuses a new one. Returns @{ Ok; Why }.
function Get-FsK1gPriorAttempts([string]$BuildRoot, [string]$Serial) {
    $u = Get-FsK1gUnitName $Serial
    $rep = 'no automatic repeat (FS-R-013 s.5: successful execution does not create standing-repeat authority); a repeat needs a reviewed package revision or the Chair''s ruling'
    $hits = @()
    $led = Join-Path $BuildRoot 'attempted'
    foreach ($m in @(Get-ChildItem -LiteralPath $led -Force -ErrorAction SilentlyContinue)) {
        if ($m.PSIsContainer) { return [pscustomobject]@{ Ok = $false; Why = "unexpected K1g ledger entry $($m.FullName): cannot tell whether $u was attempted; $rep"; Superseded = $false } }
        $note = (@([IO.File]::ReadAllLines($m.FullName)) -join ' ')
        $lm = [regex]::Match($note, ' serial=([A-Za-z0-9]+) ')
        if (-not $lm.Success) { return [pscustomobject]@{ Ok = $false; Why = "K1g ledger entry $($m.FullName) names no serial: cannot tell whether $u was attempted; $rep"; Superseded = $false } }
        if ($lm.Groups[1].Value -ceq $Serial) { $hits += $m.FullName }
    }
    if (Test-Path -LiteralPath $BuildRoot -PathType Container) {
        foreach ($oj in @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue } | ForEach-Object { Join-Path $_.FullName 'observe.json' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
            $s = try { [string]([IO.File]::ReadAllText($oj) | ConvertFrom-Json).Serial } catch { '?' }
            if ($s -ceq $Serial -or $s -ceq '?') { $hits += $oj }
        }
    }
    if ($hits.Count) {
        # THE ONE SUPERSESSION: Unit 2's one further attempt, only when every hit (both discovery paths) is the historical one
        $sv = Test-FsK1gSupersededPrior $BuildRoot $Serial $hits
        if ($sv.Ok) { return [pscustomobject]@{ Ok = $true; Why = $sv.Why; Superseded = $true } }
        $sx = if ($sv.Why) { " ($($sv.Why))" } else { '' }
        return [pscustomobject]@{ Ok = $false; Why = "$u ($Serial) already has a K1g attempt ($($hits[0])): $rep$sx"; Superseded = $false }
    }
    if ($Serial -ceq $script:FsK1gUnit2) { $hm = Get-FsK1gHistoryMissing $BuildRoot; if ($hm) { return [pscustomobject]@{ Ok = $false; Why = "$u ($Serial): $hm; $rep"; Superseded = $false } } }
    [pscustomobject]@{ Ok = $true; Why = "no earlier K1g attempt of $u"; Superseded = $false }
}

# THE ONE SUPERSESSION, no automatic repeat: may Unit 2 have its ONE further K1g attempt? Only if the pins and the ruling
# file hold, the checkout's K1g candidate table is the pinned r3 one (so the observer's nonce-only check admits only the
# r3 candidate or a nonce-only rebuild of it), every earlier-attempt hit of BOTH discovery paths is the historical
# attempt's own ledger entry or observe.json, and Unit 2's K1g attempts, bound as Get-FsK1gUnitRecords binds them, are
# exactly that one record, verified byte for byte. Once the further attempt is registered (its ledger entry, or an
# observe.json), it is another hit and this refuses. Returns @{ Ok; Why } (Why '' when this is not Unit 2).
function Test-FsK1gSupersededPrior([string]$BuildRoot, [string]$Serial, [string[]]$Hits) {
    $s = $script:FsK1gSupersession
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w } }
    if ($Serial -cne $script:FsK1gUnit2) { return (& $no '') }      # the pins are checked next (their serial must be Unit 2's)
    $pp = Test-FsK1gSupersessionPins
    if (-not $pp.Ok) { return (& $no $pp.Why) }
    $ct = Get-FsK1gFileSha (Join-Path $script:FsK1gUnitsDir 'fs-nonceonly-k1g.ps1')
    if ($ct -cne [string]$s.CandidateTableSha256) { return (& $no "the supersession of $($s.Nonce) is not applied: the K1g candidate table fs-nonceonly-k1g.ps1 has SHA-256 '$ct', not the pinned $($s.CandidateTableSha256) that holds the r3 candidate $($s.SupersededBy) as the current reviewed one") }
    $br = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\', '/')
    $ledF = [IO.Path]::GetFullPath((Join-Path $br "attempted\$($s.Nonce).attempted"))
    foreach ($h in $Hits) {
        $hf = [IO.Path]::GetFullPath($h)
        $isLed = ($hf -ceq $ledF)
        $isObs = ((Split-Path -Leaf $hf) -ceq 'observe.json' -and (Split-Path -Leaf (Split-Path -Parent $hf)) -cmatch '^observe-' -and
                  (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $hf))) -cmatch ('^[0-9]{8}T[0-9]{6}Z-' + $s.Nonce + '\z') -and
                  [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $hf)))).TrimEnd('\', '/') -ceq $br)
        if (-not ($isLed -or $isObs)) { return (& $no "Unit 2 has a K1g attempt other than the historical $($s.Nonce), or an observe.json that cannot be read ($h): the one further attempt is spent or in progress (or cannot be told apart); no other is permitted") }
    }
    # the third discovery path: an attempt.lock of Unit 2 (or naming no serial) anywhere but the historical directory
    foreach ($lk in @(Get-FsK1gUnitLocks $BuildRoot $script:FsK1gUnit2)) {
        if ([string]$lk.Nonce -cne [string]$s.Nonce) { return (& $no "Unit 2 has a K1g attempt other than the historical $($s.Nonce) ($($lk.File), an attempt.lock without its ledger entry or observer record shown above): the one further attempt is spent or in progress; no other is permitted") } }
    $w = Get-FsK1gUnitRecords -BuildRoot $BuildRoot -Serial $script:FsK1gUnit2 -Stage 'k1g' -RecordName 'classify-k1g.json' -Schema $script:FsK1gClassifySchema -Outcomes $script:FsK1gOutcomes `
        -ClassifierFiles @('fs-classify-k1g.ps1') -PinBanner $script:FsK1gPinBanner -PinConfigSha $script:FsK1gPinConfigSha -PinModules $script:FsK1gPinModules -What 'K1g'
    if (-not $w.Ok) { return (& $no "the supersession of $($s.Nonce) is not applied: $($w.Why)") }
    if (@($w.Records).Count -ne 1) { return (& $no "the supersession of $($s.Nonce) is not applied: Unit 2 has $(@($w.Records).Count) bound K1g attempts (exactly the historical one expected)") }
    $sv = Test-FsK1gSupersededRecord $w.Records[0] (Join-Path $w.Ledger "$($w.Records[0].Nonce).attempted")
    if (-not $sv.Ok) { return (& $no $sv.Why) }
    [pscustomobject]@{ Ok = $true; Why = "Unit 2's only earlier K1g attempt: $($sv.Why), superseded for progression (not a PASS) by the r3 candidate lineage $($s.SupersededBy) under $($pp.Ref): ONE further Unit 2 K1g attempt, from that lineage only (once registered, no other)" }
}

# THE ORDER GATE for one K1g attempt. Unit 2: the K1a gate. Unit 1: the K1a gate and Unit 2's clean K1G PASS (A5 is
# checked by the observer against the checklist). Returns @{ Ok; Why; K1a; Unit2 }.
function Get-FsK1gOrderGate([string]$Serial, [string]$K1gBuildRoot, [string]$K1aBuildRoot) {
    $r = [ordered]@{ Ok = $false; Why = ''; K1a = $null; Unit2 = $null }
    if (-not (Test-FsK1gUnit $Serial)) { $r.Why = "'$Serial' is not a K1g unit (Unit 2 QUEST3UNIT2, Unit 1 QUEST3UNIT1)"; return [pscustomobject]$r }
    $pa = Get-FsK1gPriorAttempts $K1gBuildRoot $Serial
    if (-not $pa.Ok) { $r.Why = $pa.Why; return [pscustomobject]$r }
    $k = Get-FsK1gK1aGate $K1aBuildRoot
    $r.K1a = $k
    if (-not $k.Ok) { $r.Why = $k.Why; return [pscustomobject]$r }
    if ($Serial -ceq $script:FsK1gUnit1) {
        $u = Get-FsK1gUnit2Outcome $K1gBuildRoot
        $r.Unit2 = $u
        if (-not $u.Ok) { $r.Why = "Unit 1 K1g before Unit 2's K1g result: $($u.Why)"; return [pscustomobject]$r }
        $r.Ok = $true; $r.Why = "$($k.Why); $($u.Why)"; return [pscustomobject]$r
    }
    $r.Ok = $true; $r.Why = if ($pa.Superseded) { "$($k.Why); $($pa.Why)" } else { $k.Why }   # the historical REVIEW stays named
    [pscustomobject]$r
}
