# FrameShift K1a - the two units and the unit order (Windows PowerShell 5.1; a library: dot-source it). Read only: no
# device, no network, no write. Used by the K1a sign-off tooling (private) (phase A) and fs-observe-k1a.ps1 (the attempt gate).
#
# K1a test-boots BOTH Quest 3 units (PM request), one at a time: Unit 2 first; Unit 1 only after Unit 2's attempt has
# a recorded, clean K1A PASS (Get-FsK1aUnit2Outcome below; coordinator decision) and the PM has been told the result
# (phase A question A5, Unit 1 only). Each unit has its own fresh nonce (a nonce-only rebuild of the reviewed candidate), its
# own readback rows (the readback rows (private) for Unit 2, the readback rows (private) for Unit 1) and its own attempt-ledger
# entry (build\k1a\attempted\<nonce>.attempted, the note names the serial).
# Known hardware faults, recorded and never compensated: Unit 2 IPD slider and proximity sensor; Unit 1 proximity
# sensor. K1a reads no sensor, so neither fault affects a K1a result.
$script:FsK1aUnit2 = 'QUEST3UNIT2'
$script:FsK1aUnit1 = 'QUEST3UNIT1'
$script:FsK1aUnitNames = [ordered]@{ 'QUEST3UNIT2' = 'Unit 2'; 'QUEST3UNIT1' = 'Unit 1' }
$script:FsK1aOutcomes = @('K1A PASS', 'K1A REVIEW', 'K1A FAIL', 'INTEGRITY FAULT', 'INCONCLUSIVE')
$script:FsK1aClassifySchema = 'frameshift.fs-classify-k1a.v1'
# third delta review MAJOR-1: the classifier's expected facts, as pinned (= fs-classify-k1a.ps1's parameter defaults; a
# host test checks they agree). A record made with any other -Banner, -ConfigSha or -Modules does not bind.
$script:FsK1aPinBanner = 'Linux version 5.10.246-gdbc2bc83a2b6 (frameshift@k1a) (Android (8508608, based on r450784e) clang version 14.0.7 (https://android.googlesource.com/toolchain/llvm-project 4c603efb0cca074e9238af8b4106c30add4418f6), LLD 14.0.7) #1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026'
$script:FsK1aPinConfigSha = '4aa0c894655627f6ff39476ac2a45abb4c224ee0053957d5002c694b0602826b'
$script:FsK1aPinModules = 95
function Get-FsK1aTextSha([string]$Text) { $sh = [Security.Cryptography.SHA256]::Create(); try { -join ($sh.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) } finally { $sh.Dispose() } }
$script:FsK1aUnitsDir = $PSScriptRoot      # this library's directory (the pinned fs-classify-k1a.ps1 beside it)

# a K1a unit: exactly one of the two serials, compared case-sensitively (an [ordered] dictionary's Contains is not)
function Test-FsK1aUnit([string]$Serial) { $Serial -cmatch '^[A-Za-z0-9]{6,32}\z' -and (@($script:FsK1aUnitNames.Keys) -ccontains $Serial) }
function Get-FsK1aUnitName([string]$Serial) { if (Test-FsK1aUnit $Serial) { [string]$script:FsK1aUnitNames[$Serial] } else { '' } }

function Get-FsK1aFileSha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }

# The Unit 1 gate, over the fixed ledger of $BuildRoot (build\k1a). EVERY ledger entry attempted\<nonce>.attempted
# whose note names Unit 2 (fs-observe-k1a.ps1 writes "... serial=<serial> unit=<unit>"; an entry naming no serial is
# unresolvable and blocks) must resolve to exactly one build directory <stamp>-<nonce> with exactly one
# observe-*\observe.json of stage k1a, this nonce, Unit 2's serial, and next to it a classify-k1a.json (schema
# frameshift.fs-classify-k1a.v1) that binds it: the same nonce and serial, Fixture the JSON boolean false, an outcome of
# the five, ObserveJsonSha256 = that observe.json's SHA-256, CollectJsonSha256 / CaptureSha256 = the SHA-256 of
# collect\collect.json / collect\capture.raw beside it (collect.json of the same nonce), and ClassifierSha256 = this
# checkout's fs-classify-k1a.ps1 (pinned in SIGNOFF-k1a). A Unit 2 attempt without such a record (for example one that
# never brought up the gadget: no collect.json, so no outcome can exist) blocks Unit 1 for good (fail-closed).
# Then (coordinator decision, FS-A-013 final review): Unit 1 opens ONLY when EVERY Unit 2 record is K1A PASS with a
# clean after-session record (the classifier binds checklist phase F: AF and AA ended OK, no recovery fault, no
# manual power-off, no dump mode, all follow-up readings finished below 40 C). A K1A REVIEW blocks Unit 1 (FS-R-012
# s.3; after the Chair's review Unit 1 needs a new reviewed package revision or the Chair's ruling); K1A FAIL, INTEGRITY FAULT, INCONCLUSIVE or an unclean PASS block it (a later
# Unit 1 attempt needs a new package review). Returns @{ Ok; Why; Nonce; Outcome; File; Sha256; Utc }.
# Residual risk (narrow review, documented, not detected): the gate trusts the record's fields and the files it binds;
# a deliberate hand edit of classify-k1a.json, of the capture or collect.json (FSB1 carries no MAC), or the removal of
# a whole attempt directory together with its ledger entry is not detected. Any of these is falsification of a test
# record; the records are evidence for the PM and the Chair, not a security boundary.
function Get-FsK1aUnit2Outcome([string]$BuildRoot) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Nonce = $null; Outcome = $null; File = $null; Sha256 = $null; Utc = $null } }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $rd = { param([string]$f) try { [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $null } }
    if (-not $BuildRoot -or -not (Test-Path -LiteralPath $BuildRoot -PathType Container)) { return (& $no "no build root '$BuildRoot'") }
    $clsSha = Get-FsK1aFileSha (Join-Path $script:FsK1aUnitsDir 'fs-classify-k1a.ps1')
    $led = Join-Path $BuildRoot 'attempted'
    $all = @(Get-ChildItem -LiteralPath $led -Force -ErrorAction SilentlyContinue)     # every entry, no filter (narrow review MINOR-4)
    $odd = @($all | Where-Object { $_.PSIsContainer -or $_.Name -cnotmatch '^[0-9a-f]{16}\.attempted\z' })
    if ($odd.Count) { return (& $no "unexpected ledger file $($odd[0].FullName) (not <16 hex>.attempted): Unit 1 blocked") }
    $marks = $all
    $recs = New-Object System.Collections.Generic.List[object]
    foreach ($m in $marks) {
        $n = $m.Name.Substring(0, 16)
        $note = (@([IO.File]::ReadAllLines($m.FullName)) -join ' ')
        $lm = [regex]::Match($note, ' serial=([A-Za-z0-9]+) ')
        if (-not $lm.Success) { return (& $no "ledger entry $($m.FullName) names no serial: cannot tell whether it was a Unit 2 attempt; Unit 1 blocked") }
        if ($lm.Groups[1].Value -cne $script:FsK1aUnit2) { continue }
        $tm = [regex]::Match($note, '^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z) ')
        if (-not $tm.Success) { return (& $no "ledger entry $($m.FullName) has no UTC time (yyyy-MM-ddTHH:mm:ss[.fffffff]Z): Unit 1 blocked") }
        $lt = $tm.Groups[1].Value
        $why = "Unit 2 attempt nonce $n (ledger $($m.FullName))"
        $dirs = @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch ('^[0-9]{8}T[0-9]{6}Z-' + $n + '\z') })
        if ($dirs.Count -ne 1) { return (& $no "${why}: $($dirs.Count) build directories (exactly 1 expected); Unit 1 blocked") }
        $ods = @(Get-ChildItem -LiteralPath $dirs[0].FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'observe.json') -PathType Leaf })
        if ($ods.Count -ne 1) { return (& $no "${why}: $($ods.Count) observe directories with observe.json (exactly 1 expected); Unit 1 blocked") }
        $od = $ods[0].FullName; $oj = Join-Path $od 'observe.json'; $cj = Join-Path $od 'classify-k1a.json'
        $ob = & $rd $oj
        if ($null -eq $ob -or [string](& $pv $ob 'Stage') -cne 'k1a' -or [string](& $pv $ob 'Nonce') -cne $n -or [string](& $pv $ob 'Serial') -cne $script:FsK1aUnit2) { return (& $no "${why}: its observe.json is not this Unit 2 K1a attempt; Unit 1 blocked") }
        if (-not (Test-Path -LiteralPath $cj -PathType Leaf)) { return (& $no "${why}: no classify-k1a.json, no outcome recorded; if its collector output exists, run fs-classify-k1a.ps1 -CollectDir $od\collect -ObserveDir $od; an attempt that has none (no console, an interrupted observer) can never get an outcome and is treated like a blocking outcome: Unit 1 blocked, a later Unit 1 attempt needs a new package review") }
        $c = & $rd $cj
        $fx = & $pv $c 'Fixture'
        $colJ = Join-Path $od 'collect\collect.json'; $colR = Join-Path $od 'collect\capture.raw'
        $col = if (Test-Path -LiteralPath $colJ -PathType Leaf) { & $rd $colJ } else { $null }
        $ok = ($null -ne $c -and [string](& $pv $c 'Schema') -ceq $script:FsK1aClassifySchema -and [string](& $pv $c 'Nonce') -ceq $n -and [string](& $pv $c 'Serial') -ceq $script:FsK1aUnit2 -and
               ($fx -is [bool]) -and -not $fx -and ($script:FsK1aOutcomes -ccontains [string](& $pv $c 'Outcome')) -and [string](& $pv $c 'ObserveJsonSha256') -ceq (Get-FsK1aFileSha $oj) -and
               $null -ne $col -and [string](& $pv $col 'Nonce') -ceq $n -and [string](& $pv $c 'CollectJsonSha256') -ceq (Get-FsK1aFileSha $colJ) -and
               (Test-Path -LiteralPath $colR -PathType Leaf) -and [string](& $pv $c 'CaptureSha256') -ceq (Get-FsK1aFileSha $colR) -and [string](& $pv $c 'ClassifierSha256') -ceq $clsSha -and
               [string](& $pv $c 'BannerSha256') -ceq (Get-FsK1aTextSha $script:FsK1aPinBanner) -and [string](& $pv $c 'ConfigSha') -ceq $script:FsK1aPinConfigSha -and [string](& $pv $c 'Modules') -ceq [string]$script:FsK1aPinModules)
        if (-not $ok) { return (& $no "${why}: its classify-k1a.json does not bind this Unit 2 attempt (schema, nonce, serial, fixture, outcome, the SHA-256 of observe.json, collect\collect.json and collect\capture.raw, the pinned classifier and its pinned banner, config and module count); Unit 1 blocked") }
        # the after-session facts (checklist phase F, bound by the classifier): every one must be the clean value
        $af = & $pv $c 'After'; $aw = @()
        if ($null -eq $af) { $aw += 'no after-session record' }
        else {
            foreach ($kv in @(@('Clean', $true), @('AfOk', $true), @('AaOk', $true), @('ReturnedByItself', $true), @('DumpMode', $false), @('RecoveryFault', $false), @('FollowUpsFinished', $true))) {
                $x = & $pv $af $kv[0]; if (-not ($x -is [bool]) -or $x -ne $kv[1]) { $aw += "$($kv[0]) is '$x'" } }
            $mt = & $pv $af 'MaxTemp'; if ($null -eq $mt -or [string]$mt -cnotmatch '^[0-9]{1,4}\z' -or [int]$mt -ge 400) { $aw += "highest reading '$mt' (below 400 required)" }
        }
        $recs.Add([pscustomobject]@{ Nonce = $n; Outcome = [string]$c.Outcome; File = $cj; Sha256 = (Get-FsK1aFileSha $cj); Utc = [string](& $pv $c 'Utc'); LedgerUtc = $lt; Dir = $od; AfterClean = ($aw.Count -eq 0); AfterWhy = ($aw -join '; ') })
    }
    # a Unit 2 attempt's observe.json without its ledger entry (a deleted or renamed entry) blocks too (narrow review MINOR-4)
    foreach ($bd in @(Get-ChildItem -LiteralPath $BuildRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\z' })) {
        $bn = $bd.Name.Substring($bd.Name.Length - 16)
        foreach ($oj2 in @(Get-ChildItem -LiteralPath $bd.FullName -Directory -Filter 'observe-*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'observe.json' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
            $ob2 = & $rd $oj2
            if ($null -ne $ob2 -and [string](& $pv $ob2 'Serial') -ceq $script:FsK1aUnit2 -and -not (Test-Path -LiteralPath (Join-Path $led "$bn.attempted") -PathType Leaf)) {
                return (& $no "a Unit 2 attempt ($oj2) has no ledger entry $led\$bn.attempted (deleted or renamed): Unit 1 blocked") }
        }
    }
    if ($recs.Count -eq 0) {
        return (& $no ("no Unit 2 (QUEST3UNIT2) K1a attempt in the ledger $led ($($marks.Count) entries): Unit 2 first, then its classifier result, reported to the PM"))
    }
    foreach ($r in $recs) {
        if ($r.Outcome -ceq 'K1A REVIEW') { return (& $no "Unit 2's K1a attempt nonce $($r.Nonce) is K1A REVIEW ($($r.File)): Unit 1 is blocked; the Chair reviews it (FS-R-012 s.3), and Unit 1 then needs a new reviewed package revision or the Chair's ruling") }
        if ($r.Outcome -cne 'K1A PASS') { return (& $no "Unit 2's K1a attempt nonce $($r.Nonce) is $($r.Outcome) ($($r.File)): Unit 1 is blocked; a later Unit 1 attempt needs a new package review") }
        if (-not $r.AfterClean) { return (& $no "Unit 2's K1a attempt nonce $($r.Nonce) is K1A PASS but its after-session record is not clean ($($r.AfterWhy)): Unit 1 is blocked; a later Unit 1 attempt needs a new package review") }
    }
    $best = $null
    foreach ($r in $recs) { if ($null -eq $best -or [string]::CompareOrdinal($r.LedgerUtc, [string]$best.LedgerUtc) -gt 0) { $best = $r } }
    [pscustomobject]@{ Ok = $true; Why = "Unit 2 attempt nonce $($best.Nonce) recorded with outcome $($best.Outcome), after-session record clean ($($best.File), classified $($best.Utc))"
                       Nonce = $best.Nonce; Outcome = $best.Outcome; File = $best.File; Sha256 = $best.Sha256; Utc = $best.Utc }
}
