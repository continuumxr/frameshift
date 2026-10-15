<#
FrameShift - stage-3c observer (Windows PowerShell 5.1). ONE attempt.

A COPY of fs-observe.ps1 reduced to stage 3c (devices/quest3/stage3c/DESIGN.md revision 3, sections
8.1, 10, 12.2). Dot-sourcing the original is unsafe: it applies the BA dwell gate only when -Stage 3b.
The only differences from fs-observe.ps1 (a reviewer diffs the two, R-D):
  - the stage set is 3c only: no stage parameter (and no variable of that name), the image
    boot-stage3c.img, the MANIFEST title "FrameShift Quest 3 stage-3c image", the fixed build root and
    ledger <repo>\build\stage3c\ (attempted, abandoned);
  - the MANIFEST sources (DESIGN 12.2): init.sh, fs-phase.sh, fs-probe.sh and fs-idle.sh of stage3c\;
  - the dwell gate (BA -> boot <= 300 s, FS-R-010 section 6) is UNCONDITIONAL (3b's stage condition removed);
  - the collector launched by -ThenCollect, and the NEXT/THEN lines, are fs-collect3c.ps1 with the S3c
    parameter names (-S3cPort, -S3cNonce, -S3cBootStartUtc, -S3cHandoffUtc, -S3cOutDir) and
    fs-classify3c.ps1 (-C3cDir, -C3cObserveDir);
  - the file is ASCII (the original's section signs and dashes are spelled out), so it reads the
    same in Windows PowerShell 5.1 without a byte-order mark;
  - the console checklist gate (PM decision J-118, replacing the SIGNOFF-3c sheet): after -Preflight's
    return and BEFORE any device query, the dwell gate and the attempt registration, <cycle>\checklist3c.json
    (fs-checklist3c.ps1; default: found from -BaSummary <cycle>\BA\SUMMARY.txt in <cycle>\, or for
    <dir>\<nonce>\BA\SUMMARY.txt in <dir>\<nonce>\ or <dir>\; or -ChecklistFile) must hold the LAST
    entries of phases A, B and E as PASS, A for this attempt's nonce, in the order A, B, E, E (presence)
    at most 300 s old, every entry written by the copy of fs-checklist3c.ps1 pinned in the SIGNOFF-3c
    host-pin table (schema frameshift.fs-checklist3c.v3), phase B's single temperature reading (PM,
    J-125; it replaces the settled pair) recorded as passed and re-checked by the same text rules as
    phase B (review MAJOR-1: the reading three digits from 100 to 349, the status exactly 3, 4 or 5),
    taken on THIS unit (review MAJOR-2: its R1Serial equals -Serial), at or before BA's start and at most
    900 s before it (an old reading does not carry over to a new BA after an abandoned cycle), BA's
    own machine-captured battery row BA10 (dumpsys battery, from the BA SUMMARY of this nonce and
    serial, its file hash checked) below 350 with status 3, 4 or 5 (review MAJOR-1), and phase E
    started at or after BF's start; otherwise the attempt is refused (exit 2) with no device action.
    Second review (MINOR-1..5): every UTC time is read with ConvertFrom-FsObsUtc (ASCII digits, ParseExact
    in a try: T24:00:00Z or :60Z refused, never parsed leniently); BA10's temperature 100 to 349 and its
    level above 50 (exactly one level line); Reading.Ok a JSON boolean true; the reading later than every
    other BA of the cycle (Test-FsObsReadingFirstBa: the BA SUMMARY files under the checklist's directory
    and this nonce's abandoned-cycle records), so an old reading never carries over to a new BA.
    observe.json records the checklist file and checklist3c.txt with their SHA-256 and the BA10 values.
    -Preflight does not need the checklist;
  - -Serial has no default (review MAJOR-2): an attempt needs it, and it must be one of the two Quest 3
    units (Unit 1 QUEST3UNIT1, Unit 2 QUEST3UNIT2); otherwise refused (exit 2) before anything is
    written or any device is queried;
  - the dwell refusal and the abandoned-cycle record say "a new temperature reading" (J-125) where
    fs-observe.ps1 says "a new settled pair".
Everything else (sign-off gate before anything is written or queried, manifest/baseline/ledger checks,
exactly one `fastboot -s <serial> boot <image>`, never retried, BootStartUtc taken before the boot, the
gadget watch that never opens the port, observe.json) is the stage-3b observer's code, unchanged.

Usage:
  fs-observe3c.ps1 -Image <build dir>\boot-stage3c.img -Preflight       (no device action)
  fs-observe3c.ps1 -Image <...> -Serial <unit serial> -ConfirmNonce <nonce> -BaSummary <BA\SUMMARY.txt> -BfSummary <BF\SUMMARY.txt> [-ChecklistFile <cycle>\checklist3c.json] [-ThenCollect]
Exit: 0 attempt made (or preflight OK); 2 refused (nothing booted; also without a valid console checklist); 3 no PM sign-off
(nothing written, no device queried); 70 internal error before the boot.
#>
param(
    [string]$Image = '',
    [string]$Serial = '',               # review MAJOR-2: no default; an attempt needs the unit's serial
    [switch]$Preflight,
    [string]$ConfirmNonce = '',
    [int]$GadgetWaitSec = 90,
    [switch]$ThenCollect,
    [string]$FastbootExe = 'C:\platform-tools\fastboot.exe',
    [string]$BaSummary = '',            # this cycle's BA SUMMARY.txt (dwell gate)
    [string]$BfSummary = '',            # this cycle's BF SUMMARY.txt
    [string]$ChecklistFile = ''         # this cycle's checklist3c.json (default: found from -BaSummary, Get-FsObsChecklistPath)
)
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\stage1\fs-proto.ps1')     # Invoke-FsNative, Get-FsFastbootSerials, Get-FsHandoffClass, Get-FsGadget, Register-FsAttempt, Test-FsAttemptFree (read only)

$script:FsObsBaseline = @{
    StockBoot  = '49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50'
    StockVboot = '1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf'
}
# Per stage: the image file name, the MANIFEST title, and the repository sources whose
# recorded hashes must equal the reviewed files (the image was built from them).
$script:FsObsStage = @{
    '3c' = @{ Img = 'boot-stage3c.img'; Title = 'stage-3c image'; Sources = [ordered]@{ 'init.sh source' = 'stage3c\init.sh'; 'fs-phase.sh' = 'stage3c\fs-phase.sh'; 'fs-probe.sh' = 'stage3c\fs-probe.sh'; 'fs-idle.sh' = 'stage3c\fs-idle.sh' } }
}
$script:FsObs3cLabel = '3c'
# review MAJOR-2: the two Quest 3 units (both on v2.7, J-131/J-133); -Serial must be one of them
$script:FsObsUnits = [ordered]@{ 'QUEST3UNIT1' = 'Unit 1'; 'QUEST3UNIT2' = 'Unit 2' }
function Test-FsObsUnit([string]$Serial) { $Serial -cmatch '^[A-Za-z0-9]{6,32}\z' -and (@($script:FsObsUnits.Keys) -ccontains $Serial) }   # case-sensitive (an [ordered] dictionary's Contains is not)
$script:FsObsDwellMaxSec = 300      # BA start to the boot, at most 5 min (FS-R-010 section 6); unconditional for stage 3c
# Second review MINOR-1: a UTC time is yyyy-MM-ddTHH:mm:ss[.f to .fffffff]Z in ASCII digits ([0-9]: \d also matches
# other scripts' digits), read with ParseExact (invariant culture) in a try. Returns a UTC [DateTime] or $null (refused):
# T24:00:00Z, :60Z, 2026-02-30 and anything else malformed are $null, never an exception, never a lenient Parse.
$script:FsObsUtcFormats = [string[]](@("yyyy-MM-dd'T'HH:mm:ss'Z'") + @(1..7 | ForEach-Object { "yyyy-MM-dd'T'HH:mm:ss." + ('f' * $_) + "'Z'" }))
$script:FsObsUtcRe = '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?Z'
function ConvertFrom-FsObsUtc([string]$s) {
    if ($null -eq $s -or $s -cnotmatch ('^' + $script:FsObsUtcRe + '\z')) { return $null }
    try { [DateTime]::ParseExact($s, $script:FsObsUtcFormats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }
    catch { $null }
}

# Stage 3b dwell gate: parses one fs-capture.ps1 SUMMARY.txt. Returns @{ Ok; Why; StartUtc }.
function Read-FsObsPhaseSummary {
    param([string]$Path, [string]$Phase, [string]$Nonce, [string]$Serial)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "$Phase summary: $w"; StartUtc = $null } }
    if (-not $Path) { return (& $no 'not given (-BaSummary/-BfSummary are required for stage 3c)') }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (& $no "missing: $Path") }
    $lines = @([IO.File]::ReadAllLines($Path) | Where-Object { $_ -ne '' })
    if ($lines.Count -lt 2) { return (& $no 'too short') }
    $re = '^# fs-capture\.ps1 phase ' + $Phase + ' nonce ([0-9a-f]{16}) serial (\S+)  (' + $script:FsObsUtcRe + ')\z'
    if ($lines[0] -cnotmatch $re) { return (& $no 'header is not an fs-capture.ps1 summary of this phase') }
    $hN = $Matches[1]; $hS = $Matches[2]; $hT = $Matches[3]
    if ($hN -cne $Nonce) { return (& $no "nonce $hN is not this attempt's $Nonce") }
    if ($hS -cne $Serial) { return (& $no "serial $hS is not $Serial") }
    $t = ConvertFrom-FsObsUtc $hT
    if ($null -eq $t) { return (& $no "header time '$hT' is not a valid UTC time") }
    if ($lines[-1] -cnotmatch ('^PHASE ' + $Phase + ' OK: ')) { return (& $no "the phase did not end OK ('$($lines[-1])')") }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; StartUtc = $t }
}
function Test-FsObsDwell {
    param([string]$BaSummary, [string]$BfSummary, [string]$Nonce, [string]$Serial, [DateTime]$NowUtc)
    $ba = Read-FsObsPhaseSummary $BaSummary 'BA' $Nonce $Serial
    if (-not $ba.Ok) { return [pscustomobject]@{ Ok = $false; Why = $ba.Why; Abandon = $false; BaUtc = $null; ElapsedSec = $null } }
    $bf = Read-FsObsPhaseSummary $BfSummary 'BF' $Nonce $Serial
    if (-not $bf.Ok) { return [pscustomobject]@{ Ok = $false; Why = $bf.Why; Abandon = $false; BaUtc = $ba.StartUtc; ElapsedSec = $null } }
    if ($bf.StartUtc -lt $ba.StartUtc) { return [pscustomobject]@{ Ok = $false; Why = 'BF started before BA'; Abandon = $false; BaUtc = $ba.StartUtc; ElapsedSec = $null } }
    $el = ($NowUtc.ToUniversalTime() - $ba.StartUtc).TotalSeconds
    if ($el -lt 0) { return [pscustomobject]@{ Ok = $false; Why = 'BA start is in the future (clock step or wrong file)'; Abandon = $false; BaUtc = $ba.StartUtc; ElapsedSec = $el } }
    if ($el -gt $script:FsObsDwellMaxSec) {
        return [pscustomobject]@{ Ok = $false; Abandon = $true; BaUtc = $ba.StartUtc; ElapsedSec = $el
                                  Why = ("dwell cap expired: {0:N0} s since BA started (max {1} s): return to Android, take a new temperature reading and new BA/BF, then try again" -f $el, $script:FsObsDwellMaxSec) }
    }
    [pscustomobject]@{ Ok = $true; Why = ("dwell {0:N0} s since BA started (max {1} s)" -f $el, $script:FsObsDwellMaxSec); Abandon = $false; BaUtc = $ba.StartUtc; ElapsedSec = $el }
}

# Console checklist gate (J-118): the last entries of phases A, B and E of fs-checklist3c.ps1 passed (A for this
# nonce, in the order A, B, E), E (presence) at most FsObsChecklistMaxAgeSec old, every entry written by the pinned
# fs-checklist3c.ps1, the single temperature reading of B (J-125) passed, below 350 and not charging, and tied to this
# BA (reading <= BA start, BA start - reading <= FsObsReadingToBaMaxSec), and E begun at or after BF's start.
# Returns @{ Ok; Why; Path; Sha256; EUtc; AgeSec; TxtPath; TxtSha256; ReadingToBaSec }.
$script:FsObsChecklistMaxAgeSec = 300
$script:FsObsReadingToBaMaxSec = 900
# Default: fs-capture.ps1 (default captures root <repo>\captures, <cycle> = captures\<nonce>) writes
# <cycle>\BA\SUMMARY.txt, so the checklist is looked for in the BA directory's parent (<cycle>) and then its
# grandparent (for <dir>\<nonce>\BA: <dir>); the first that exists is used.
function Get-FsObsChecklistPath([string]$ChecklistFile, [string]$BaSummary) {
    if ($ChecklistFile) { return $ChecklistFile }
    if (-not $BaSummary) { return '' }
    $d = Split-Path -Parent $BaSummary; $first = ''
    for ($i = 0; $i -lt 2; $i++) {
        $d = if ($d) { Split-Path -Parent $d } else { '' }
        if (-not $d) { break }
        $c = Join-Path $d 'checklist3c.json'
        if (-not $first) { $first = $c }
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    $first
}
# The pin of fs-checklist3c.ps1 in the SIGNOFF-3c host-pin table ($Q3\SIGNOFF-3c.md), or $null.
function Get-FsObsChecklistPin([string]$Q3) {
    $p = Join-Path $Q3 'SIGNOFF-3c.md'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $in = $false
    foreach ($l in [IO.File]::ReadAllLines($p)) {
        if ($l -match '<!-- end host pins') { break }
        if ($l -match '<!-- host pins') { $in = $true; continue }
        if ($in -and $l -cmatch '^\s*\|\s*`devices\\quest3\\host\\fs-checklist3c\.ps1`\s*\|\s*`([0-9a-f]{64})`\s*\|') { return $Matches[1] }
    }
    $null
}
# Review MAJOR-1: BA's own machine-captured battery row. In the BA SUMMARY.txt that Read-FsObsPhaseSummary has
# accepted (this nonce, this serial, PHASE BA OK) the BA10 row must have exit 0, its file BA10.txt (next to the
# SUMMARY) must hash to the recorded SHA-256, and its dumpsys battery text must hold exactly one temperature line
# below 350 and exactly one status line of 3, 4 or 5. Returns @{ Ok; Why; Temp; Status; Level; File; Sha256 }.
function Test-FsObsBa10 {
    param([string]$BaSummary)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "BA10 (dumpsys battery at BA): $w"; Temp = $null; Status = $null; Level = $null; File = $null; Sha256 = $null } }
    if (-not $BaSummary -or -not (Test-Path -LiteralPath $BaSummary -PathType Leaf)) { return (& $no 'no BA SUMMARY.txt') }
    $rows = @([IO.File]::ReadAllLines($BaSummary) | Where-Object { $_ -cmatch '^BA10\t' })
    if ($rows.Count -ne 1) { return (& $no "the BA SUMMARY has $($rows.Count) BA10 rows (exactly 1 expected)") }
    $c = $rows[0].Split("`t")
    if ($c.Count -ne 5 -or $c[1] -cne '0') { return (& $no "the BA10 row did not exit 0 ('$($rows[0])')") }
    if ($c[3] -cnotmatch '^[0-9a-f]{64}\z' -or (Split-Path -Leaf $c[4]) -cne 'BA10.txt') { return (& $no "the BA10 row has no SHA-256 or names another file ('$($rows[0])')") }
    $f = Join-Path (Split-Path -Parent $BaSummary) 'BA10.txt'
    $h = Get-FsObsSha $f
    if (-not $h) { return (& $no "missing: $f") }
    if ($h -cne $c[3]) { return (& $no "$f has SHA-256 $h, not the $($c[3]) recorded at BA (changed after the capture)") }
    $t = [IO.File]::ReadAllText($f)
    $tm = [regex]::Matches($t, '(?m)^[ \t]*temperature:[ \t]*([0-9]+)[ \t]*\r?$'); $sm = [regex]::Matches($t, '(?m)^[ \t]*status:[ \t]*([0-9]+)[ \t]*\r?$')
    $lm = [regex]::Matches($t, '(?m)^[ \t]*level:[ \t]*([0-9]+)[ \t]*\r?$')
    if ($tm.Count -ne 1 -or $sm.Count -ne 1) { return (& $no "$f does not hold exactly one 'temperature:' and one 'status:' line (found $($tm.Count) and $($sm.Count))") }
    $tv = $tm[0].Groups[1].Value; $sv = $sm[0].Groups[1].Value; $lv = if ($lm.Count -eq 1) { $lm[0].Groups[1].Value } else { $null }
    if ($tv -cnotmatch '^[0-9]{1,4}\z' -or [int]$tv -ge 350) { return (& $no "temperature $tv at BA is not below 350 (35.0 deg C)") }
    # second review MINOR-2: the same floor as the typed reading (below 100 = 10.0 deg C is not a plausible reading)
    if ([int]$tv -lt 100) { return (& $no "temperature $tv at BA is below 100 (10.0 deg C): not a plausible reading (100 to 349)") }
    if ($sv -cnotmatch '^[345]\z') { return (& $no "battery status $sv at BA is not 3, 4 or 5 (discharging, not charging, full): the battery was charging or its state unknown") }
    # second review MINOR-5: BA10's level is machine-checked too (SIGNOFF C: level > 50)
    if ($lm.Count -ne 1 -or $lv -cnotmatch '^[0-9]{1,3}\z') { return (& $no "$f does not hold exactly one 'level:' line (found $($lm.Count))") }
    if ([int]$lv -le 50) { return (& $no "battery level $lv at BA is not above 50") }
    [pscustomobject]@{ Ok = $true; Why = "BA10 temperature $tv, status $sv$(if ($null -ne $lv) { ", level $lv" })"; Temp = [int]$tv; Status = [int]$sv; Level = $(if ($null -ne $lv) { [int]$lv } else { $null }); File = $f; Sha256 = $h }
}
# Second review MINOR-3: the reading is tied to the first BA after it. Refused if another BA SUMMARY.txt under the
# cycle directory (down to <cycle>\a\b\BA: <cycle>\BA, <cycle>\<nonce>\BA, <cycle>\retry-N\<nonce>\BA), or an abandoned-cycle record of this nonce
# ("BA started:" line), started at or after the reading and before this BA: the reading is from before an abandoned
# (or earlier) cycle. A SUMMARY whose header cannot be read refuses too (the safe side). Returns @{ Ok; Why }.
function Test-FsObsReadingFirstBa {
    param([string]$CycleDir, [string]$BaSummary, [DateTime]$BaUtc, [DateTime]$ReadingUtc, [string]$Nonce, [string]$AbandonedDir = '')
    $yes = [pscustomobject]@{ Ok = $true; Why = 'the first BA after the reading' }
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w } }
    $self = try { (Resolve-Path -LiteralPath $BaSummary -ErrorAction Stop).ProviderPath } catch { [IO.Path]::GetFullPath($BaSummary) }
    $others = @()
    if ($CycleDir -and (Test-Path -LiteralPath $CycleDir -PathType Container)) {
        $others = @(Get-ChildItem -LiteralPath $CycleDir -Recurse -Depth 3 -File -Filter 'SUMMARY.txt' -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -ceq 'BA' -and $_.FullName -ine $self })
    }
    foreach ($o in $others) {
        $h = @([IO.File]::ReadAllLines($o.FullName) | Select-Object -First 1)
        $m = if ($h.Count) { [regex]::Match([string]$h[0], '^# fs-capture\.ps1 phase BA nonce \S+ serial \S+  (' + $script:FsObsUtcRe + ')\z') } else { $null }
        $ot = if ($null -ne $m -and $m.Success) { ConvertFrom-FsObsUtc $m.Groups[1].Value } else { $null }
        if ($null -eq $ot) { return (& $no "another BA of this cycle ($($o.FullName)) has no readable start time: cannot show the reading is newer than it; take a new reading (-Phase B), then a new BA/BF") }
        if ($ot -ge $ReadingUtc -and $ot -lt $BaUtc) { return (& $no ("the temperature reading ({0}) is from before an earlier BA of this cycle ({1}, started {2}): an old reading does not carry over to a new BA; take a new reading (-Phase B), then -Phase E" -f $ReadingUtc.ToString('o'), $o.FullName, $ot.ToString('o'))) }
    }
    if ($AbandonedDir -and (Test-Path -LiteralPath $AbandonedDir -PathType Container)) {
        foreach ($a in @(Get-ChildItem -LiteralPath $AbandonedDir -File -Filter "*-$Nonce.txt" -ErrorAction SilentlyContinue)) {
            $bl = @([IO.File]::ReadAllLines($a.FullName) | Where-Object { $_ -cmatch '^BA started: ' })
            $at = if ($bl.Count -eq 1) { ConvertFrom-FsObsUtc ($bl[0].Substring(12)) } else { $null }
            if ($null -eq $at) { return (& $no "abandoned-cycle record $($a.FullName) has no readable BA start: take a new reading (-Phase B), then a new BA/BF") }
            if ($at -ge $ReadingUtc -and $at -lt $BaUtc) { return (& $no ("the temperature reading ({0}) is from before an abandoned cycle (its BA started {1}; record {2}): take a new reading (-Phase B), then -Phase E" -f $ReadingUtc.ToString('o'), $at.ToString('o'), $a.FullName)) }
        }
    }
    $yes
}
function Test-FsObsChecklist {
    param([string]$Path, [string]$Nonce, [DateTime]$NowUtc, [string]$ToolPin = '', [string]$BaSummary = '', [string]$BfSummary = '', [string]$Serial = '', [string]$AbandonedDir = '')
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "console checklist: $w"; Path = $Path; Sha256 = $null; EUtc = $null; AgeSec = $null; TxtPath = $null; TxtSha256 = $null; ReadingToBaSec = $null; Ba10 = $null } }
    if ($null -eq $AbandonedDir) { $AbandonedDir = '' }
    # review MAJOR-2: no default unit
    if (-not (Test-FsObsUnit $Serial)) { return (& $no "no unit: -Serial '$Serial' is not one of the two Quest 3 units (Unit 1 QUEST3UNIT1, Unit 2 QUEST3UNIT2)") }
    if (-not $Path) { return (& $no 'not given (-ChecklistFile, or -BaSummary <cycle>\BA\SUMMARY.txt with <cycle>\checklist3c.json)') }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (& $no "missing: $Path (run fs-checklist3c.ps1 -Phase A, B and E)") }
    try { $j = (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path) | ConvertFrom-Json } catch { return (& $no "unreadable: $Path") }
    if ($null -eq $j -or -not $j.PSObject.Properties['Schema'] -or [string]$j.Schema -cne 'frameshift.fs-checklist3c.v3' -or -not $j.PSObject.Properties['Entries']) { return (& $no "$Path is not a frameshift.fs-checklist3c.v3 file (single temperature reading as typed text with the unit, J-125, review MAJOR-1/2)") }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }     # a missing property is $null (strict mode)
    $last = @{}; foreach ($en in @($j.Entries)) { $ph0 = & $pv $en 'Phase'; if ($null -ne $ph0) { $last[[string]$ph0] = $en } }
    $t = @{}
    $need = @{ A = @('A1', 'A2', 'A3'); B = @(); E = @('E1', 'E2') }
    foreach ($ph in 'A', 'B', 'E') {
        if (-not $last.ContainsKey($ph)) { return (& $no "phase $ph is missing (run fs-checklist3c.ps1 -Phase $ph)") }
        $en = $last[$ph]
        if ([string](& $pv $en 'Result') -cne 'PASS') { return (& $no "phase $ph did not pass (its last entry: $(& $pv $en 'Result'): $(& $pv $en 'Why'))") }
        $ids = @(@(& $pv $en 'Questions') | Where-Object { [string](& $pv $_ 'Answer') -ceq 'y' } | ForEach-Object { [string](& $pv $_ 'Id') })
        foreach ($q in $need[$ph]) { if ($ids -cnotcontains $q) { return (& $no "phase $ph lacks the answer y to question $q") } }
        $s = [string](& $pv $en 'EndUtc')
        $t[$ph] = ConvertFrom-FsObsUtc $s
        if ($null -eq $t[$ph]) { return (& $no "phase $ph has no valid UTC end time ('$s')") }
    }
    # the single temperature reading (J-125): recorded as passed, and its values re-checked here
    $rd = & $pv $last['B'] 'Reading'
    $rOk = & $pv $rd 'Ok'
    if (-not ($rOk -is [bool]) -or -not $rOk) { return (& $no 'phase B does not record a passing temperature reading (Reading.Ok must be the JSON boolean true)') }
    # review MAJOR-1: the same text rules as phase B (a number, or text that is not exactly three digits, is refused)
    $rT = & $pv $rd 'R1'; $rS = & $pv $rd 'R1Status'; $rU = & $pv $rd 'R1Serial'
    if (-not ($rT -is [string]) -or $rT -cnotmatch '^[0-9]{3}\z' -or [int]$rT -lt 100 -or [int]$rT -ge 350) { return (& $no "phase B's temperature reading '$rT' is not three digits from 100 to 349 (35.0 deg C and above fail)") }
    if (-not ($rS -is [string]) -or $rS -cnotmatch '^[345]\z') { return (& $no "phase B's battery status '$rS' is not 3, 4 or 5 (discharging, not charging, full): the battery was charging or its state unknown") }
    # review MAJOR-2: the reading was taken on this unit
    if (-not ($rU -is [string]) -or $rU -cne $Serial) { return (& $no "phase B's temperature reading was taken on unit '$rU', not on this attempt's unit $Serial ($($script:FsObsUnits[$Serial])): take a reading on $Serial (fs-checklist3c.ps1 -Phase B -R1Serial $Serial)") }
    if ([string](& $pv $last['A'] 'Nonce') -cne $Nonce) { return (& $no "phase A was run for nonce '$(& $pv $last['A'] 'Nonce')', not this attempt's $Nonce") }
    if ($t['B'] -lt $t['A'] -or $t['E'] -lt $t['B']) { return (& $no 'the phases did not pass in the order A, B, E') }
    $age = ($NowUtc.ToUniversalTime() - $t['E']).TotalSeconds
    if ($age -lt 0) { return (& $no 'phase E (presence) is in the future (clock step or wrong file)') }
    if ($age -gt $script:FsObsChecklistMaxAgeSec) { return (& $no ("phase E (presence) is {0:N0} s old (max {1} s): run fs-checklist3c.ps1 -Phase E again immediately before the attempt" -f $age, $script:FsObsChecklistMaxAgeSec)) }
    # every entry written by the pinned checklist (LOW 9)
    if ($ToolPin -cnotmatch '^[0-9a-f]{64}\z') { return (& $no 'no pin for fs-checklist3c.ps1 in the SIGNOFF-3c host-pin table') }
    $foreign = @(@($j.Entries) | Where-Object { [string](& $pv $_ 'ToolSha256') -cne $ToolPin })
    if ($foreign.Count) { return (& $no ("{0} entries were not written by the pinned fs-checklist3c.ps1 (pin {1}; e.g. phase {2} ToolSha256 '{3}'): use a new cycle directory with the pinned files" -f $foreign.Count, $ToolPin, (& $pv $foreign[0] 'Phase'), (& $pv $foreign[0] 'ToolSha256'))) }
    # the reading and the presence belong to THIS BA/BF (MEDIUM 5): an old PASS does not carry over to a new BA
    $ba = Read-FsObsPhaseSummary $BaSummary 'BA' $Nonce $Serial
    if (-not $ba.Ok) { return (& $no "cannot tie the temperature reading to BA: $($ba.Why)") }
    $bf = Read-FsObsPhaseSummary $BfSummary 'BF' $Nonce $Serial
    if (-not $bf.Ok) { return (& $no "cannot tie the presence check to BF: $($bf.Why)") }
    # review MAJOR-1: BA's own dumpsys battery row (machine-captured at attempt time, this nonce and serial)
    $b10 = Test-FsObsBa10 $BaSummary
    if (-not $b10.Ok) { return (& $no $b10.Why) }
    $r1s = [string](& $pv $rd 'R1Utc')
    $r1 = ConvertFrom-FsObsUtc $r1s
    if ($null -eq $r1) { return (& $no "phase B has no valid UTC time of the temperature reading ('$r1s')") }
    $p2b = ($ba.StartUtc - $r1).TotalSeconds
    if ($p2b -lt 0) { return (& $no ("the temperature reading ({0}) is after BA started ({1}): it must be taken before BA" -f $r1.ToString('o'), $ba.StartUtc.ToString('o'))) }
    if ($p2b -gt $script:FsObsReadingToBaMaxSec) { return (& $no ("the temperature reading is {0:N0} s before BA started (max {1} s): a reading from before an abandoned cycle does not count; take a new reading (fs-checklist3c.ps1 -Phase B), then a new BA/BF and -Phase E" -f $p2b, $script:FsObsReadingToBaMaxSec)) }
    # second review MINOR-3: the reading belongs to the FIRST BA after it (no other BA of this cycle, and no abandoned
    # cycle's BA of this nonce, started at or after the reading and before this BA)
    $fb = Test-FsObsReadingFirstBa -CycleDir (Split-Path -Parent $Path) -BaSummary $BaSummary -BaUtc $ba.StartUtc -ReadingUtc $r1 -Nonce $Nonce -AbandonedDir $AbandonedDir
    if (-not $fb.Ok) { return (& $no $fb.Why) }
    $es = [string](& $pv $last['E'] 'StartUtc')
    $eStart = ConvertFrom-FsObsUtc $es
    if ($null -eq $eStart) { return (& $no "phase E has no valid UTC start time ('$es')") }
    if ($eStart -lt $bf.StartUtc) { return (& $no ("phase E (presence) started at {0}, before BF started ({1}): run fs-checklist3c.ps1 -Phase E again after BF" -f $eStart.ToString('o'), $bf.StartUtc.ToString('o'))) }
    $tp = Join-Path (Split-Path -Parent $Path) 'checklist3c.txt'
    [pscustomobject]@{ Ok = $true; Why = ("phases A, B, E passed; presence confirmed {0:N0} s ago (max {1} s); temperature reading {2} (battery status {3}, unit {6}) {4:N0} s before BA (max {5} s); {7}; presence after BF; tool = pin" -f $age, $script:FsObsChecklistMaxAgeSec, $rT, $rS, $p2b, $script:FsObsReadingToBaMaxSec, $rU, $b10.Why); Path = $Path
                       Sha256 = (Get-FsObsSha $Path); EUtc = $t['E']; AgeSec = [Math]::Round($age, 1); TxtPath = $tp; TxtSha256 = (Get-FsObsSha $tp); ReadingToBaSec = [Math]::Round($p2b, 1); Ba10 = $b10 }
}

function Get-FsObsSha([string]$Path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { $null } }

# Parses and checks a stage-2a/3a MANIFEST.txt against the image file and the repository.
# Returns @{ Ok; Why; Nonce; ImageSha }.
function Test-FsObsManifest {
    param([string]$ImagePath, [string]$Q3)
    $spec = $script:FsObsStage[$script:FsObs3cLabel]
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Nonce = $null; ImageSha = $null } }
    if ((Split-Path -Leaf $ImagePath) -cne $spec.Img) { return (& $no "image file is not $($spec.Img)") }
    $mf = Join-Path (Split-Path -Parent $ImagePath) 'MANIFEST.txt'
    if (-not (Test-Path -LiteralPath $mf -PathType Leaf)) { return (& $no 'MANIFEST.txt missing') }
    $m = [IO.File]::ReadAllText($mf)
    $v = { param($re) if ($m -cmatch $re) { $Matches[1] } else { $null } }
    $nonce = & $v '(?m)^nonce:\s+([0-9a-f]{16})\s'
    # every refusal from here on carries the nonce, so the sign-off gate is judged on its own
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Nonce = $nonce; ImageSha = $null } }
    if ($m -cnotmatch "(?m)^FrameShift Quest 3 $([regex]::Escape($spec.Title)) ") { return (& $no "MANIFEST is not a $($spec.Title) manifest") }
    if ($m -cmatch '(?m)^TEST OVERRIDES') { return (& $no 'MANIFEST records TEST OVERRIDES: a fixture build, never an attempt image') }
    $isha = & $v ('(?m)^OUTPUT IMAGE:\s+' + [regex]::Escape($spec.Img) + '\s+size=\d+\s+sha256=([0-9a-f]{64})\s*$')
    if (-not $nonce -or -not $isha) { return (& $no 'MANIFEST lacks the nonce or the image hash') }
    $dirName = Split-Path -Leaf (Split-Path -Parent $ImagePath)
    if ($dirName -cnotmatch ('^\d{8}T\d{6}Z-' + $nonce + '\z')) { return (& $no "image directory '$dirName' does not carry the manifest nonce") }
    $act = Get-FsObsSha $ImagePath
    if ($act -cne $isha) { return (& $no "image sha256 $act != MANIFEST $isha") }
    if ((& $v '(?m)^stock boot\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.StockBoot) { return (& $no 'MANIFEST stock boot is not the selected slot-A baseline') }
    if ((& $v '(?m)^stock vendor_boot\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.StockVboot) { return (& $no 'MANIFEST stock vendor_boot is not the selected slot-A baseline') }
    foreach ($k in $spec.Sources.Keys) {
        $rec = & $v ('(?m)^' + [regex]::Escape($k) + '\s+([0-9a-f]{64})\s')
        $repo = Get-FsObsSha (Join-Path $Q3 $spec.Sources[$k])
        if (-not $rec -or $rec -cne $repo) { return (& $no "image was built from another $k ($rec) than the repository's ($repo)") }
    }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; Nonce = $nonce; ImageSha = $isha }
}

# The observer, with every device-facing dependency injectable (fixtures pass fakes):
#   $Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) -> Invoke-FsNative-shaped result }
#   $Gadget   { param([string]$Nonce) -> Get-FsGadget-shaped result }
#   $NowUtc   { -> [DateTime] UTC }    $Sleep { param([int]$Ms) }    $Say { param([string]$Line) }
function Invoke-FsObserve {
    param([Parameter(Mandatory)][string]$ImagePath, [string]$Serial = '',
          [string]$ConfirmNonce = '', [bool]$Preflight = $false, [Parameter(Mandatory)][string]$BuildRoot, [Parameter(Mandatory)][string]$Q3,
          [int]$GadgetWaitSec = 90, [Parameter(Mandatory)][scriptblock]$Fastboot, [Parameter(Mandatory)][scriptblock]$Gadget,
          [Parameter(Mandatory)][scriptblock]$NowUtc, [Parameter(Mandatory)][scriptblock]$Sleep, [Parameter(Mandatory)][scriptblock]$Say,
          [string]$BaSummary = '', [string]$BfSummary = '', [string]$ChecklistFile = '')
    $r = [ordered]@{ Exit = 70; Why = ''; OutDir = $null; Observe = $null }
    $mf = Test-FsObsManifest -ImagePath $ImagePath -Q3 $Q3
    # PM sign-off gate (as stage 1): before anything is written or any device is queried.
    if (-not $Preflight -and (-not $mf.Nonce -or $ConfirmNonce -cne $mf.Nonce)) {
        $r.Exit = 3; $r.Why = 'no PM sign-off for this attempt (-ConfirmNonce must equal the attempt nonce): nothing written, no device action'
        & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    if (-not $mf.Ok) { $r.Exit = 2; $r.Why = "image refused: $($mf.Why)"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    # review MAJOR-2: an attempt names its unit; there is no default (nothing written, no device queried yet)
    if (-not $Preflight -and -not (Test-FsObsUnit $Serial)) {
        $r.Exit = 2; $r.Why = "REFUSED: -Serial '$Serial' is not one of the two Quest 3 units (Unit 1 QUEST3UNIT1, Unit 2 QUEST3UNIT2): nothing booted, no device action"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    $dir = Split-Path -Parent $ImagePath
    # SF1: one fixed ledger per stage; the image must live in the stage's build directory
    $br = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\', '/')
    if ([IO.Path]::GetFullPath((Split-Path -Parent $dir)).TrimEnd('\', '/') -ine $br) {
        $r.Exit = 2; $r.Why = "image is not in $br\<stamp>-<nonce>\ (a copied build folder would escape the one-attempt ledger)"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    $LedgerDir = Join-Path $br 'attempted'
    if (-not (Test-FsAttemptFree -Dir $dir -Nonce $mf.Nonce -LedgerDir $LedgerDir)) {
        $r.Exit = 2; $r.Why = "nonce $($mf.Nonce) was already attempted (ledger $LedgerDir) or the image directory is locked"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    & $Say "image OK: stage $($script:FsObs3cLabel) nonce $($mf.Nonce) sha256 $($mf.ImageSha)"
    if ($Preflight) { $r.Exit = 0; $r.Why = 'preflight OK: manifest, image, baseline, sources and attempt freshness verified; no device action'; & $Say $r.Why; return [pscustomobject]$r }
    # console checklist (J-118): before any device query, the dwell gate and the attempt registration
    $clPin = Get-FsObsChecklistPin $Q3
    $cl = Test-FsObsChecklist -Path (Get-FsObsChecklistPath $ChecklistFile $BaSummary) -Nonce $mf.Nonce -NowUtc (& $NowUtc) -ToolPin $clPin -BaSummary $BaSummary -BfSummary $BfSummary -Serial $Serial -AbandonedDir (Join-Path $br 'abandoned')
    if (-not $cl.Ok) { $r.Exit = 2; $r.Why = "REFUSED: $($cl.Why): nothing booted, no device action"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    & $Say "console checklist OK: $($cl.Why) ($($cl.Path))"
    $q = & $Fastboot @('devices') 15000
    $serials = @(); foreach ($line in ([string]$q.StdOut -split "`r?`n")) { if ($line -match '^(\S+)\s+fastboot\s*$') { $serials += $Matches[1] } }
    if ($q.Error -or $q.TimedOut -or $q.ExitCode -ne 0 -or $serials.Count -ne 1 -or $serials[0] -cne $Serial) {
        $r.Exit = 2; $r.Why = "need exactly one fastboot device, $Serial (got: $($serials -join ','))"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    $dwOk = $null
    if ($true) {   # stage 3c: the dwell gate is unconditional (3b: only with -Stage 3b)
        # FS-R-010 section 6: BA to the attempt at most 5 min, enforced BEFORE the boot and before the attempt is registered
        $dw = Test-FsObsDwell -BaSummary $BaSummary -BfSummary $BfSummary -Nonce $mf.Nonce -Serial $Serial -NowUtc (& $NowUtc)
        if (-not $dw.Ok) {
            if ($dw.Abandon) {
                $ad = Join-Path $br 'abandoned'
                $null = New-Item -ItemType Directory -Force -Path $ad
                $af = Join-Path $ad ("{0}-{1}.txt" -f (& $NowUtc).ToString('yyyyMMddTHHmmssZ'), $mf.Nonce)
                $txt = @("ABANDONED CYCLE (stage 3c, FS-R-010 section 6): nothing was booted; the attempt was not registered; nonce $($mf.Nonce) is unspent",
                         "BA started: $($dw.BaUtc.ToString('o'))", "checked at: $((& $NowUtc).ToString('o'))", ("elapsed: {0:N1} s (max {1} s)" -f $dw.ElapsedSec, $script:FsObsDwellMaxSec),
                         "BA summary: $BaSummary", "BF summary: $BfSummary", 'next: return to Android, a new temperature reading, new BA/BF (fs-capture.ps1 -CapturesRoot <new dir>), then the attempt')
                [IO.File]::WriteAllText($af, (($txt -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
                $r.Why = "REFUSED: $($dw.Why). Abandoned-cycle record: $af"
            } else { $r.Why = "REFUSED: $($dw.Why)" }
            $r.Exit = 2; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
        }
        & $Say "dwell gate OK: $($dw.Why)"
        $dwOk = $dw; $dwAt = (& $NowUtc)
    }
    $reg = Register-FsAttempt -Dir $dir -Nonce $mf.Nonce -LedgerDir $LedgerDir -Note "stage$($script:FsObs3cLabel) image=$($mf.ImageSha)"
    if (-not $reg.Ok) { $r.Exit = 2; $r.Why = $reg.Reason; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    $out = Join-Path $dir ('observe-' + (& $NowUtc).ToString('yyyyMMddTHHmmssZ'))
    $null = New-Item -ItemType Directory -Path $out
    $r.OutDir = $out
    $logPath = Join-Path $out 'observe.log'
    $L = { param($line) $t = "$((& $NowUtc).ToString('o'))  $line"; Add-Content -LiteralPath $logPath -Value $t -Encoding UTF8; & $Say $t }
    & $L "attempt registered: $($reg.Files -join ', ')"
    $o = [ordered]@{ Schema = 'frameshift.fs-observe.v1'; Stage = $script:FsObs3cLabel; Nonce = $mf.Nonce; Serial = $Serial; Image = $ImagePath; ImageSha256 = $mf.ImageSha
                     BootStartUtc = $null; HandoffUtc = $null; BudgetOriginUtc = $null; HandoffClass = $null; BootRc = $null; BootStdOut = ''; BootStdErr = ''; BootError = $null
                     GadgetSeen = $false; GadgetUtc = $null; ComPort = $null; WrongSerials = @(); GadgetWaitSec = $GadgetWaitSec; NextCommand = $null }
    $o.BootStartUtc = (& $NowUtc).ToString('o')          # taken BEFORE fastboot is invoked: the budget origin (FS-R-007 B1)
    $o.BudgetOriginUtc = $o.BootStartUtc
    if ($null -ne $dwOk) {   # the return package proves BA -> boot <= 300 s (review m6)
        $o.BaStartUtc = $dwOk.BaUtc.ToString('o'); $o.DwellCheckedUtc = $dwAt.ToString('o')
        $o.DwellSec = [Math]::Round(($dwAt - $dwOk.BaUtc).TotalSeconds, 1)
        $o.DwellAtBootStartSec = [Math]::Round(([DateTime]::Parse($o.BootStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() - $dwOk.BaUtc).TotalSeconds, 1)
        $o.DwellMaxSec = $script:FsObsDwellMaxSec; $o.BaSummary = $BaSummary; $o.BfSummary = $BfSummary
        & $L ("dwell gate: BA started {0}; checked {1}: {2} s; at BootStartUtc {3} s (max {4} s); BA {5}; BF {6}" -f $o.BaStartUtc, $o.DwellCheckedUtc, $o.DwellSec, $o.DwellAtBootStartSec, $script:FsObsDwellMaxSec, $BaSummary, $BfSummary)
    }
    $o.ChecklistFile = $cl.Path; $o.ChecklistSha256 = $cl.Sha256; $o.ChecklistPresenceUtc = $cl.EUtc.ToString('o'); $o.ChecklistPresenceAgeSec = $cl.AgeSec
    $o.ChecklistTxtFile = $cl.TxtPath; $o.ChecklistTxtSha256 = $cl.TxtSha256; $o.ChecklistToolPin = $clPin; $o.ChecklistReadingToBaSec = $cl.ReadingToBaSec
    $o.Unit = $script:FsObsUnits[$Serial]; $o.Ba10Temperature = $cl.Ba10.Temp; $o.Ba10Status = $cl.Ba10.Status; $o.Ba10Level = $cl.Ba10.Level; $o.Ba10Sha256 = $cl.Ba10.Sha256
    & $L "console checklist: $($cl.Why); file $($cl.Path) sha256 $($cl.Sha256); $($cl.TxtPath) sha256 $($cl.TxtSha256)"
    & $L "COMMAND: fastboot -s $Serial boot `"$ImagePath`"   (once; never retried)"
    $b = $null
    try { $b = & $Fastboot @('-s', $Serial, 'boot', $ImagePath) 120000 }
    catch { $b = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false; Error = 'observer fault: ' + $_.Exception.Message } }
    $th = & $NowUtc
    $o.HandoffUtc = $th.ToString('o'); $o.BootRc = $b.ExitCode; $o.BootStdOut = [string]$b.StdOut; $o.BootStdErr = [string]$b.StdErr; $o.BootError = $b.Error
    $o.HandoffClass = Get-FsHandoffClass -Result $b
    & $L "fastboot boot returned: rc=$($b.ExitCode) timedout=$($b.TimedOut) error=$($b.Error) class=$($o.HandoffClass)  Th=$($o.HandoffUtc)"
    if ($o.HandoffClass -cne 'DEVICE_REJECTED') {
        $end = $th.AddSeconds($GadgetWaitSec)
        while ((& $NowUtc) -lt $end) {
            $g = $null
            try { $g = & $Gadget $mf.Nonce } catch { & $L "gadget query error (watch continues): $($_.Exception.Message)" }
            if ($g) {
                foreach ($w in @($g.Serials)) { if ($w -and $w -cne "FS-$($mf.Nonce)" -and $o.WrongSerials -notcontains $w) { $o.WrongSerials += $w; & $L "gadget with a WRONG serial ${w}: ignored" } }
                if ($g.SerialOk -and $g.ComPort) {
                    $o.GadgetSeen = $true; $o.GadgetUtc = (& $NowUtc).ToString('o'); $o.ComPort = $g.ComPort
                    & $L "GADGET FS-$($mf.Nonce) on $($g.ComPort) at Th+$([int]((& $NowUtc) - $th).TotalSeconds)s (the port is not opened here)"
                    break
                }
            }
            & $Sleep 1000
        }
        if (-not $o.GadgetSeen) { & $L "no gadget FS-$($mf.Nonce) within $GadgetWaitSec s: the PID 1 deadline / recovery table applies" }
        & $L "collector budget origin: BootStartUtc $($o.BootStartUtc) (before fastboot boot; every handoff class). Th $($o.HandoffUtc) is evidence only"
    }
    if ($o.GadgetSeen) {
        $o.NextCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-collect3c.ps1 -S3cPort $($o.ComPort) -S3cNonce $($mf.Nonce) -S3cBootStartUtc $($o.BootStartUtc) -S3cHandoffUtc $($o.HandoffUtc) -S3cOutDir `"$out\collect`""
        & $L "NEXT: $($o.NextCommand)"
        & $L "THEN: fs-classify3c.ps1 -C3cDir `"$out\collect`" -C3cObserveDir `"$out`""
    }
    [IO.File]::WriteAllText((Join-Path $out 'observe.json'), (([pscustomobject]$o | ConvertTo-Json -Depth 4) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r.Exit = 0; $r.Why = "attempt made: handoff $($o.HandoffClass), gadget $($o.GadgetSeen)"; $r.Observe = [pscustomobject]$o
    [pscustomobject]$r
}

if ($MyInvocation.InvocationName -eq '.') { return }
# ------------------------------------------------------------------ CLI -----
$exit = 70
try {
    if (-not $Image) { Write-Output 'usage: fs-observe3c.ps1 -Image <dir>\boot-stage3c.img (-Preflight | -Serial <unit serial> -ConfirmNonce <nonce> -BaSummary <file> -BfSummary <file> [-ChecklistFile <file>] [-ThenCollect])'; exit 64 }
    $q3 = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $imgPath = (Resolve-Path -LiteralPath $Image).Path
    $buildRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path "build\stage$($script:FsObs3cLabel)"     # FIXED: <repo>\build\stage3c (SF1)
    $fb = $FastbootExe
    $res = Invoke-FsObserve -ImagePath $imgPath -Serial $Serial -ConfirmNonce $ConfirmNonce -Preflight ([bool]$Preflight) `
        -BuildRoot $buildRoot -Q3 $q3 -GadgetWaitSec $GadgetWaitSec `
        -Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) Invoke-FsNative -Exe $fb -ArgList $ArgList -TimeoutMs $TimeoutMs } `
        -Gadget { param([string]$N) Get-FsGadget -Nonce $N } -NowUtc { [DateTime]::UtcNow } -Sleep { param([int]$Ms) Start-Sleep -Milliseconds $Ms } `
        -Say { param([string]$Line) Write-Host $Line } -BaSummary $BaSummary -BfSummary $BfSummary -ChecklistFile $ChecklistFile     # Write-Host: the function's pipeline output is its result object only
    $exit = $res.Exit
    if ($res.Exit -eq 0 -and $res.Observe -and $res.Observe.GadgetSeen -and $ThenCollect) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fs-collect3c.ps1') -S3cPort $res.Observe.ComPort `
            -S3cNonce $res.Observe.Nonce -S3cBootStartUtc $res.Observe.BootStartUtc -S3cHandoffUtc $res.Observe.HandoffUtc -S3cOutDir (Join-Path $res.OutDir 'collect')
        Write-Output "collector exit: $LASTEXITCODE"
    }
} catch { Write-Output "OBSERVER ERROR: $($_.Exception.Message)"; $exit = 70 }
exit $exit
