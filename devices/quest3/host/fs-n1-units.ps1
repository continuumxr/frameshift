# FrameShift N1 - the units and the order (Windows PowerShell 5.1; a library: dot-source it). Read only: no device, no
# network, no write. Used by the N1 sign-off tooling (private) (phase A) and fs-observe-n1.ps1 (the attempt gate).
#
# N1 (an NCM link next to the ACM console; FS-R-013 s.5, s.9) uses the K1a kernel, so it comes AFTER K1a on each unit
# (FS-R-013 s.5: K1a -> K1g -> K1i, with N1 before the RAM-root transfer):
#   - N1 on Unit 2 (QUEST3UNIT2) opens only after BOTH K1a attempts and K1g on Unit 2 (coordinator decision
#     2026-10-16: the write guard is proven before any further new image): every K1a attempt of both units is a bound,
#     clean K1A PASS whose decoded mem step holds a valid, positive MemTotal (FS-R-013 s.2), and every Unit 2 K1g
#     attempt is a bound, clean K1G PASS. Both rules are fs-k1g-units.ps1's (Get-FsK1gK1aGate, Get-FsK1gUnit2Outcome),
#     read through it unchanged;
#   - N1 on Unit 1 (QUEST3UNIT1) opens only when Unit 1's own K1a result is a bound, clean K1A PASS with a valid
#     MemTotal AND Unit 2's N1 result is a bound, clean N1 PASS (and the PM was told: phase A question A5).
# Each N1 attempt: its own fresh nonce (a nonce-only rebuild of the reviewed N1 candidate), its own readback rows (the
# K1a READBACK-EXPECT files: same build, slot and ranges) and its own ledger entry (build\n1\attempted\<nonce>.attempted).
# Any REVIEW, FAIL, INTEGRITY FAULT, INCONCLUSIVE, unclean PASS or attempt without an outcome record blocks the next
# step (no clearance shortcut, FS-R-013 s.3). Known hardware faults, recorded and never compensated: Unit 2 IPD slider
# and proximity sensor; Unit 1 proximity sensor. N1 reads no sensor.
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
    foreach ($m in $all) {
        $n = $m.Name.Substring(0, 16)
        $note = (@([IO.File]::ReadAllLines($m.FullName)) -join ' ')
        $lm = [regex]::Match($note, ' serial=([A-Za-z0-9]+) ')
        if (-not $lm.Success) { return (& $no "${tag}: ledger entry $($m.FullName) names no serial (cannot tell whose attempt it was)") }
        if ($lm.Groups[1].Value -cne $Serial) { continue }
        $tm = [regex]::Match($note, '^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z) ')
        if (-not $tm.Success) { return (& $no "${tag}: ledger entry $($m.FullName) has no UTC time") }
        $why = "$tag, attempt nonce $n (ledger $($m.FullName))"
        $dirs = @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch ('^[0-9]{8}T[0-9]{6}Z-' + $n + '\z') })
        if ($dirs.Count -ne 1) { return (& $no "${why}: $($dirs.Count) build directories (exactly 1 expected)") }
        $ods = @(Get-ChildItem -LiteralPath $dirs[0].FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'observe.json') -PathType Leaf })
        if ($ods.Count -ne 1) { return (& $no "${why}: $($ods.Count) observe directories with observe.json (exactly 1 expected)") }
        $od = $ods[0].FullName; $oj = Join-Path $od 'observe.json'; $cj = Join-Path $od "classify-$Stage.json"
        $ob = & $rd $oj
        if ($null -eq $ob -or [string](& $pv $ob 'Stage') -cne $Stage -or [string](& $pv $ob 'Nonce') -cne $n -or [string](& $pv $ob 'Serial') -cne $Serial) { return (& $no "${why}: its observe.json is not this $Stage attempt of $Serial") }
        if (-not (Test-Path -LiteralPath $cj -PathType Leaf)) { return (& $no "${why}: no classify-$Stage.json (no outcome recorded; an attempt that cannot get one blocks for good)") }
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
                                     AfterClean = ($aw.Count -eq 0); AfterWhy = ($aw -join '; '); Mem = $mem })
    }
    foreach ($bd in @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\z' })) {
        $bn = $bd.Name.Substring($bd.Name.Length - 16)
        foreach ($oj2 in @(Get-ChildItem -LiteralPath $bd.FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'observe.json' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
            $ob2 = & $rd $oj2
            if ($null -ne $ob2 -and [string](& $pv $ob2 'Serial') -ceq $Serial -and -not (Test-Path -LiteralPath (Join-Path $led "$bn.attempted") -PathType Leaf)) {
                return (& $no "${tag}: an attempt ($oj2) has no ledger entry $led\$bn.attempted (deleted or renamed)") }
        }
    }
    if ($recs.Count -eq 0) { return (& $no "${tag}: no $Stage attempt of $unit ($Serial) in the ledger $led") }
    foreach ($r in $recs) {
        if ($r.Outcome -cne $pass) { return (& $no "${tag}: attempt nonce $($r.Nonce) is $($r.Outcome) ($($r.File)): blocked (FS-R-013 s.3: REVIEW waits for the Chair; anything else needs a new package review)") }
        if (-not $r.AfterClean) { return (& $no "${tag}: attempt nonce $($r.Nonce) is $pass but its after-session record is not clean ($($r.AfterWhy)): blocked") }
        if (-not $r.Mem.Ok) { return (& $no "${tag}: attempt nonce $($r.Nonce) is $pass but its decoded mem step has no valid, positive MemTotal ($($r.Mem.Why)): blocked and reported (FS-R-013 s.2; not a reason for another attempt)") }
    }
    $best = $null
    foreach ($r in $recs) { if ($null -eq $best -or [string]::CompareOrdinal($r.LedgerUtc, [string]$best.LedgerUtc) -gt 0) { $best = $r } }
    [pscustomobject]@{ Ok = $true; Why = "$tag nonce $($best.Nonce): $($best.Outcome), after-session record clean, $($best.Mem.Why) ($($best.File))"
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
        if (-not $lm.Success) { $found.Add("unreadable:$($m.Name)") } elseif ($lm.Groups[1].Value -ceq $Serial) { $found.Add($m.Name.Split('.')[0]) }
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
# further attempt needs the Chair's explicit authority and a new reviewed package revision.
function Get-FsN1Prereq([string]$RepoBuild, [string]$Serial) {
    $no = { param($w, $rs) [pscustomobject]@{ Ok = $false; Why = $w; Records = @($rs) } }
    if (-not (Test-FsN1Unit $Serial)) { return (& $no "'$Serial' is not one of the two units (Unit 2 QUEST3UNIT2, Unit 1 QUEST3UNIT1)" @()) }
    if ($Serial -ceq $script:FsK1aUnit1 -and -not $script:FsN1Unit1Enabled) { return (& $no "N1 runs on Unit 2 only (PM decision 2026-10-16): a Unit 1 run needs a new PM decision and package revision" @()) }
    $pa = @(Get-FsN1PriorAttempts (Join-Path $RepoBuild 'n1') $Serial)
    if ($pa.Count) { return (& $no "$(Get-FsN1UnitName $Serial) already has an N1 attempt ($($pa -join ', ')): one N1 attempt per unit; a further attempt needs the Chair's explicit authority and a new package revision (FS-R-013 s.3, s.5)" @()) }
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
    [pscustomobject]@{ Ok = $true; Why = (@($recs | ForEach-Object { "$($_.Stage.ToUpper()) $(Get-FsN1UnitName $_.Serial) nonce $($_.Nonce): $($_.Outcome)$(if ($null -ne $_.MemTotalKb) { ", MemTotal $($_.MemTotalKb) kB" })" }) -join '; '); Records = $recs }
}
