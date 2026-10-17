<#
FrameShift - K1a observer (Windows PowerShell 5.1). ONE attempt: our own kernel (K1a) by `fastboot boot`, on one of the
two units (Unit 2 first, then Unit 1).

An adapted COPY of fs-observe3d.ps1 (not edited). The differences (a reviewer diffs the two):
  - the image boot-k1a.img, the MANIFEST title "FrameShift Quest 3 K1a image", the fixed build root and ledger
    <repo>\build\k1a\ (attempted, abandoned), the MANIFEST sources init.sh, fs-k1a.sh, fs-k1a-info.sh and build-image.sh
    of k1a\; the MANIFEST must carry the pinned K1a kernel (087f0e72...1840), its config (4aa0c894...826b), the kgate
    result line, and the same v2.7 stock baseline, vbmeta, vbmeta_system and vbmeta digest as stage 3d (no fs-pattern);
  - the units (fs-k1a-units.ps1; PM request: K1a on both units): Unit 2 (QUEST3UNIT2) first; Unit 1 (QUEST3UNIT1)
    is refused unless every Unit 2 attempt in this ledger has a bound, clean K1A PASS (Get-FsK1aUnit2Outcome: its
    observe.json and the classifier's classify-k1a.json with the after-session facts of checklist phase F; a K1A
    REVIEW blocks it until the Chair's review and a new package revision, FS-R-012 s.3; anything else blocks Unit 1 until a new package review) and phase A of the Unit 1 cycle answered A5 (the PM was told
    Unit 2's result). Each attempt: its own fresh nonce, phase A for that serial (its readback R0 names it), its own
    ledger entry (the note names the serial); any other serial is refused;
  - one nonce per run: the image must be the current reviewed K1a candidate, or a nonce-only rebuild of it
    (fs-nonceonly-k1a.ps1's Test-FsNonceOnlyK1a: both images opened, the kernel bytes identical and = the pinned K1a
    Image, only the nonce in /init differs); a withdrawn K1a candidate is never accepted;
  - the console checklist is the K1a checklist's, private (<cycle>\checklist-k1a.json, schema frameshift.fs-checklist-k1a.v1,
    its pin in the SIGNOFF-k1a host-pin table): phases A (A1-A4 answered y, incl. the readback precondition), B (the
    single reading, the same rules) and E (presence), no standing acceptance, no sound check, no rehearsals; and
    (review MAJOR-4) the readback transcripts phase A CHECKED (R0-R5 PASS) still hash as recorded, R0 naming this unit;
  - the collector launched by -ThenCollect, and the NEXT/THEN lines, are fs-collect-k1a.ps1 (-K1aPort, -K1aNonce,
    -K1aBootStartUtc, -K1aHandoffUtc, -K1aOutDir) and fs-classify-k1a.ps1 (-CollectDir, -ObserveDir).
Everything else (the sign-off gate before anything is written or queried, the ledger, the BA/BF must-be rows, BA10, the
unconditional dwell gate BA -> boot <= 300 s, exactly one `fastboot -s <serial> boot <image>`, never retried,
BootStartUtc taken before the boot, the gadget watch that never opens the port, the no-gadget note, observe.json) is
the stage-3d observer's code, unchanged.

Usage:
  fs-observe-k1a.ps1 -Image <build dir>\boot-k1a.img -Preflight       (no device action)
  fs-observe-k1a.ps1 -Image <...> -Serial <QUEST3UNIT2 | QUEST3UNIT1> -ConfirmNonce <nonce> -BaSummary <BA\SUMMARY.txt> -BfSummary <BF\SUMMARY.txt> [-ChecklistFile <cycle>\checklist-k1a.json] [-ThenCollect]
Exit: 0 attempt made (or preflight OK); 2 refused (nothing booted); 3 no PM sign-off (nothing written, no device
queried); 70 internal error before the boot.
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
    [string]$ChecklistFile = ''         # this cycle's checklist-k1a.json (default: found from -BaSummary, Get-FsObsChecklistPath)
)
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\stage1\fs-proto.ps1')     # Invoke-FsNative, Get-FsFastbootSerials, Get-FsHandoffClass, Get-FsGadget, Register-FsAttempt, Test-FsAttemptFree (read only)
. (Join-Path $PSScriptRoot 'fs-k1a-units.ps1')         # the two K1a units and the Unit 1 gate (Get-FsK1aUnit2Outcome; read only)
. (Join-Path $PSScriptRoot 'fs-nonceonly-k1a.ps1')      # Test-FsNonceOnlyK1a, the reviewed K1a candidate (its parameters K1aNo* and fs-nonceonly3d's Reference, Candidate, ReferenceSha collide with none of this file's)

# the v2.7 OTA inputs (as stage 3d) and the pinned K1a kernel (k1a/kernel/record/run1; kgate check-k1a.json)
$script:FsObsBaseline = @{
    StockBoot    = 'e32f98c74bcce5c25b098393f7804e19fbba2f0c2034c49a4fcf6aa9a8cdc024'
    StockVboot   = 'bc0dd14de41834a601513123b2225a677fa4212dfa4505bf964228cea40d2f5b'
    Vbmeta       = 'aae4af3a1740d568a1bcd1104f1b30b2998082def674e00c319acfab10faf215'
    VbmetaSystem = '28f5ccc91f25665dda5db1abf1fc3bd3fcea58f30cb33827642cddf6f9c8bc50'
    VbmetaDigest = '66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a'
    K1aKernel    = '087f0e72999922909e9583b95ae956f0186d6c1a337b71308b845456689e1840'   # the K1a Image (build run 1; kgate PASS)
    K1aConfig    = '4aa0c894655627f6ff39476ac2a45abb4c224ee0053957d5002c694b0602826b'   # k1a/kernel/k1a.config (= the Image's IKCONFIG)
}
# Per stage: the image file name, the MANIFEST title, and the repository sources whose
# recorded hashes must equal the reviewed files (the image was built from them).
$script:FsObsStage = @{
    'k1a' = @{ Img = 'boot-k1a.img'; Title = 'K1a image'; Sources = [ordered]@{ 'init.sh source' = 'k1a\init.sh'; 'fs-k1a.sh' = 'k1a\fs-k1a.sh'; 'fs-k1a-info.sh' = 'k1a\fs-k1a-info.sh'; 'build-image.sh' = 'k1a\build-image.sh' } }
}
$script:FsObs3dLabel = 'k1a'
# K1a: both units (fs-k1a-units.ps1), Unit 2 first; Unit 1 only after Unit 2's attempt has an outcome (Invoke-FsObserve)
$script:FsObsUnits = $script:FsK1aUnitNames
function Test-FsObsUnit([string]$Serial) { Test-FsK1aUnit $Serial }   # case-sensitive
$script:FsObsDwellMaxSec = 300      # BA start to the boot, at most 5 min (FS-R-010 section 6); unconditional for stage 3d
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

# Stage 3b dwell gate: parses one <withheld capture tool> SUMMARY.txt. Returns @{ Ok; Why; StartUtc }.
function Read-FsObsPhaseSummary {
    param([string]$Path, [string]$Phase, [string]$Nonce, [string]$Serial)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "$Phase summary: $w"; StartUtc = $null } }
    if (-not $Path) { return (& $no 'not given (-BaSummary/-BfSummary are required for stage 3d)') }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (& $no "missing: $Path") }
    $lines = @([IO.File]::ReadAllLines($Path) | Where-Object { $_ -ne '' })
    if ($lines.Count -lt 2) { return (& $no 'too short') }
    $re = '^# fs-capture\.ps1 phase ' + $Phase + ' nonce ([0-9a-f]{16}) serial (\S+)  (' + $script:FsObsUtcRe + ')\z'
    if ($lines[0] -cnotmatch $re) { return (& $no 'header is not an <withheld capture tool> summary of this phase') }
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

# Console checklist gate (J-118): the last entries of phases A, B and E of the K1a sign-off tooling (private) passed (A for this
# nonce, in the order A, B, E), E (presence) at most FsObsChecklistMaxAgeSec old, every entry written by the pinned
# fs-checklist3d.ps1, the single temperature reading of B (J-125) passed (below 350 with status 3/4/5, or below 300 while
# charging, J-145; the battery level above 50 %, FS-R-012 s.5), phase A of today's PC date (J-143 review MAJOR-2), and tied to this
# BA (reading <= BA start, BA start - reading <= FsObsReadingToBaMaxSec), and E begun at or after BF's start.
# Returns @{ Ok; Why; Path; Sha256; EUtc; AgeSec; TxtPath; TxtSha256; ReadingToBaSec }.
$script:FsObsChecklistMaxAgeSec = 300
$script:FsObsReadingToBaMaxSec = 900
# J-145 (PM): the battery rule of a reading (phase B's typed reading and BA10): status 3, 4 or 5 (discharging, not
# charging, full) below 350 (checked by the caller), or status 2 (charging) only below 300 (30.0 deg C); status 1 (unknown)
# never. $T and $S are the digits as text (already checked to be digits). Returns $null when the rule holds, else why.
$script:FsObsChargingLimit = 300
function Test-FsObsBatteryRule([string]$T, [string]$S) {
    if ($S -cmatch '^[345]\z') { return $null }
    if ($S -ceq '2') { if ([int]$T -lt $script:FsObsChargingLimit) { return $null }; return "battery status 2 (charging) with temperature ${T}: charging is accepted only below $($script:FsObsChargingLimit) (30.0 deg C; J-145)" }
    "battery status $S is not 3, 4 or 5 (discharging, not charging, full), nor 2 (charging) below $($script:FsObsChargingLimit): the battery state is unknown or not accepted"
}
# Default: <withheld capture tool> (default captures root <repo>\captures, <cycle> = captures\<nonce>) writes
# <cycle>\BA\SUMMARY.txt, so the checklist is looked for in the BA directory's parent (<cycle>) and then its
# grandparent (for <dir>\<nonce>\BA: <dir>); the first that exists is used.
function Get-FsObsChecklistPath([string]$ChecklistFile, [string]$BaSummary) {
    if ($ChecklistFile) { return $ChecklistFile }
    if (-not $BaSummary) { return '' }
    $d = Split-Path -Parent $BaSummary; $first = ''
    for ($i = 0; $i -lt 2; $i++) {
        $d = if ($d) { Split-Path -Parent $d } else { '' }
        if (-not $d) { break }
        $c = Join-Path $d 'checklist-k1a.json'
        if (-not $first) { $first = $c }
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    $first
}
# The pin of the K1a sign-off tooling (private) in the SIGNOFF-k1a host-pin table ($Q3\SIGNOFF-k1a.md), or $null.
function Get-FsObsChecklistPin([string]$Q3) {
    $p = Join-Path $Q3 'SIGNOFF-k1a.md'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $in = $false
    foreach ($l in [IO.File]::ReadAllLines($p)) {
        if ($l -match '<!-- end host pins') { break }
        if ($l -match '<!-- host pins') { $in = $true; continue }
        if ($in -and $l -cmatch '^\s*\|\s*`devices\\quest3\\host\\fs-checklist-k1a\.ps1`\s*\|\s*`([0-9a-f]{64})`\s*\|') { return $Matches[1] }
    }
    $null
}
# Review MAJOR-1: BA's own machine-captured battery row. In the BA SUMMARY.txt that Read-FsObsPhaseSummary has
# accepted (this nonce, this serial, PHASE BA OK) the BA10 row must have exit 0, its file BA10.txt (next to the
# SUMMARY) must hash to the recorded SHA-256, and its dumpsys battery text must hold exactly one temperature line
# below 350 and exactly one status line of 3, 4 or 5 (or 2 with the temperature below 300, J-145), and exactly one
# level line above 50 (FS-R-012 s.5; 0-100, no leading zero, as phase B's typed level). Returns @{ Ok; Why; Temp; Status; Level; File; Sha256 }.
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
    # J-145: the same battery rule as phase B (status 3/4/5 below 350; status 2, charging, only below 300)
    $bw = Test-FsObsBatteryRule $tv $sv
    if ($bw) { return (& $no "at BA: $bw") }
    # second review MINOR-5: BA10's level is machine-checked too (SIGNOFF C: level > 50)
    if ($lm.Count -ne 1 -or $lv -cnotmatch '^(100|[1-9]?[0-9])\z') { return (& $no "$f does not hold exactly one 'level:' line of 0 to 100 (found $($lm.Count): '$lv')") }
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
    param([string]$Path, [string]$Nonce, [DateTime]$NowUtc, [string]$ToolPin = '', [string]$BaSummary = '', [string]$BfSummary = '', [string]$Serial = '', [string]$AbandonedDir = '', [scriptblock]$LocalDate = $null, $Unit2 = $null)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "console checklist: $w"; Path = $Path; Sha256 = $null; EUtc = $null; AgeSec = $null; TxtPath = $null; TxtSha256 = $null; ReadingToBaSec = $null; Ba10 = $null } }
    if ($null -eq $AbandonedDir) { $AbandonedDir = '' }
    # review MAJOR-2: no default unit
    if (-not (Test-FsObsUnit $Serial)) { return (& $no "no unit: -Serial '$Serial' is not a K1a unit (Unit 2 QUEST3UNIT2, Unit 1 QUEST3UNIT1)") }
    if (-not $Path) { return (& $no 'not given (-ChecklistFile, or -BaSummary <cycle>\BA\SUMMARY.txt with <cycle>\checklist-k1a.json)') }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (& $no "missing: $Path (run the K1a sign-off tooling (private) -Phase A, B and E)") }
    try { $j = (Get-Content -Raw -Encoding UTF8 -LiteralPath $Path) | ConvertFrom-Json } catch { return (& $no "unreadable: $Path") }
    if ($null -eq $j -or -not $j.PSObject.Properties['Schema'] -or [string]$j.Schema -cne 'frameshift.fs-checklist-k1a.v1' -or -not $j.PSObject.Properties['Entries']) { return (& $no "$Path is not a frameshift.fs-checklist-k1a.v1 file (the K1a checklist)") }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }     # a missing property is $null (strict mode)
    $last = @{}; foreach ($en in @($j.Entries)) { $ph0 = & $pv $en 'Phase'; if ($null -ne $ph0) { $last[[string]$ph0] = $en } }
    $t = @{}
    $need = @{ A = @('A1', 'A2', 'A3', 'A4'); B = @(); E = @('E1', 'E2') }
    if ($Serial -ceq $script:FsK1aUnit1) { $need.A = @('A1', 'A2', 'A3', 'A4', 'A5') }   # A5: Unit 2's result reported to the PM
    foreach ($ph in 'A', 'B', 'E') {
        if (-not $last.ContainsKey($ph)) { return (& $no "phase $ph is missing (run the K1a sign-off tooling (private) -Phase $ph)") }
        $en = $last[$ph]
        if ([string](& $pv $en 'Result') -cne 'PASS') { return (& $no "phase $ph did not pass (its last entry: $(& $pv $en 'Result'): $(& $pv $en 'Why'))") }
        $ids = @(@(& $pv $en 'Questions') | Where-Object { [string](& $pv $_ 'Answer') -ceq 'y' } | ForEach-Object { [string](& $pv $_ 'Id') })
        foreach ($q in $need[$ph]) { if ($ids -cnotcontains $q) { return (& $no "phase $ph lacks the answer y to question $q") } }
        $s = [string](& $pv $en 'EndUtc')
        $t[$ph] = ConvertFrom-FsObsUtc $s
        if ($null -eq $t[$ph]) { return (& $no "phase $ph has no valid UTC end time ('$s')") }
    }
    # both units: phase A was run for THIS unit (its -Serial; the readback below names it too)
    if ([string](& $pv $last['A'] 'Serial') -cne $Serial) { return (& $no "phase A was run for unit '$(& $pv $last['A'] 'Serial')', not this attempt's $Serial (the K1a sign-off tooling (private) -Phase A -Serial $Serial)") }
    # Unit 1: A5 approved THIS Unit 2 record: a different record after phase A needs a new phase A
    if ($Serial -ceq $script:FsK1aUnit1) {
        $ua = & $pv $last['A'] 'Unit2Outcome'
        if ($null -eq $Unit2 -or $null -eq $ua -or [string](& $pv $ua 'Nonce') -cne [string]$Unit2.Nonce -or [string](& $pv $ua 'Sha256') -cne [string]$Unit2.Sha256 ) {
            return (& $no "phase A (A5) approved another Unit 2 record than the current one ($(if ($null -ne $Unit2) { "$($Unit2.Nonce) $($Unit2.Outcome)" } else { 'none' })): run phase A again") }
    }
    # review MAJOR-4: the readback precondition (FS-R-012 s.6) as phase A CHECKED it: R0-R5 all PASS, and each transcript
    # still the file phase A hashed (an edited or replaced transcript is refused); R0's first line is this unit's serial
    $rbk = @(@(& $pv $last['A'] 'Readback') | Where-Object { $null -ne $_ })
    if ((@($rbk | ForEach-Object { [string](& $pv $_ 'Row') }) -join ',') -cne 'R0,R1,R2,R3,R4,R5') { return (& $no 'phase A records no complete readback check (R0-R5): run the K1a sign-off tooling (private) -Phase A after WALKTHROUGH step 0b') }
    foreach ($x in $rbk) {
        if ([string](& $pv $x 'Verdict') -cne 'PASS') { return (& $no "readback $(& $pv $x 'Row') did not pass in phase A ($(& $pv $x 'Verdict'))") }
        $rp = [string](& $pv $x 'Path'); $rh = Get-FsObsSha $rp
        if (-not $rh -or $rh -cne [string](& $pv $x 'Sha256')) { return (& $no "the readback transcript $rp is missing or changed since phase A checked it (SHA-256 $rh, recorded $(& $pv $x 'Sha256'))") }
    }
    $r0f = [string](& $pv $rbk[0] 'Path')
    $r0l = @([IO.File]::ReadAllLines($r0f) | ForEach-Object { ($_ -replace "[^ -~]", '').Trim() } | Where-Object { $_ -ne '' })
    if ($r0l.Count -lt 1 -or $r0l[0] -cne $Serial) { return (& $no "the readback R0 transcript names unit '$(if ($r0l.Count) { $r0l[0] })', not this attempt's $Serial") }
    # the single temperature reading (J-125): recorded as passed, and its values re-checked here
    $rd = & $pv $last['B'] 'Reading'
    $rOk = & $pv $rd 'Ok'
    if (-not ($rOk -is [bool]) -or -not $rOk) { return (& $no 'phase B does not record a passing temperature reading (Reading.Ok must be the JSON boolean true)') }
    # review MAJOR-1: the same text rules as phase B (a number, or text that is not exactly three digits, is refused)
    $rT = & $pv $rd 'R1'; $rS = & $pv $rd 'R1Status'; $rU = & $pv $rd 'R1Serial'; $rC = & $pv $rd 'R1Charge'
    if (-not ($rT -is [string]) -or $rT -cnotmatch '^[0-9]{3}\z' -or [int]$rT -lt 100 -or [int]$rT -ge 350) { return (& $no "phase B's temperature reading '$rT' is not three digits from 100 to 349 (35.0 deg C and above fail)") }
    if (-not ($rS -is [string]) -or $rS -cnotmatch '^[1-5]\z') { return (& $no "phase B's battery status '$rS' is not one digit 1 to 5") }
    # FS-R-012 s.5: the battery above 50 % (phase B's typed level; BA10's level is checked the same way)
    if (-not ($rC -is [string]) -or $rC -cnotmatch '^(100|[1-9]?[0-9])\z' -or [int]$rC -le 50) { return (& $no "phase B's battery level '$rC' is not above 50 % (FS-R-012 s.5; -R1Charge, required)") }
    # J-145: status 3/4/5 below 350, or status 2 (charging) only below 300
    $bw = Test-FsObsBatteryRule $rT $rS
    if ($bw) { return (& $no "phase B's reading: $bw") }
    # review MAJOR-2: the reading was taken on this unit
    if (-not ($rU -is [string]) -or $rU -cne $Serial) { return (& $no "phase B's temperature reading was taken on unit '$rU', not on this attempt's unit $Serial ($($script:FsObsUnits[$Serial])): take a reading on $Serial (the K1a sign-off tooling (private) -Phase B -R1Serial $Serial)") }
    if ([string](& $pv $last['A'] 'Nonce') -cne $Nonce) { return (& $no "phase A was run for nonce '$(& $pv $last['A'] 'Nonce')', not this attempt's $Nonce") }
    if ($t['B'] -lt $t['A'] -or $t['E'] -lt $t['B']) { return (& $no 'the phases did not pass in the order A, B, E') }
    # review of 14107af MAJOR-2: phase A and the passes it relied on hold for its own PC day only (a next-day resume needs a new A)
    $ldF = if ($null -ne $LocalDate) { $LocalDate } else { { param([DateTime]$u) $u.ToUniversalTime().ToLocalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } }
    $aDay = [string](& $pv $last['A'] 'LocalDate'); $tDay = & $ldF $NowUtc
    if ($aDay -cne $tDay) { return (& $no "new day: this cycle's phase A is from $(if ($aDay) { $aDay } else { 'an unknown day' }), today is $tDay (PC local date): run step 2 (phase A) again, then a new reading (phase B), BA/BF and phase E") }
    $age = ($NowUtc.ToUniversalTime() - $t['E']).TotalSeconds
    if ($age -lt 0) { return (& $no 'phase E (presence) is in the future (clock step or wrong file)') }
    if ($age -gt $script:FsObsChecklistMaxAgeSec) { return (& $no ("phase E (presence) is {0:N0} s old (max {1} s): run the K1a sign-off tooling (private) -Phase E again immediately before the attempt" -f $age, $script:FsObsChecklistMaxAgeSec)) }
    # every entry written by the pinned checklist (LOW 9)
    if ($ToolPin -cnotmatch '^[0-9a-f]{64}\z') { return (& $no 'no pin for the K1a sign-off tooling (private) in the SIGNOFF-k1a host-pin table') }
    $foreign = @(@($j.Entries) | Where-Object { [string](& $pv $_ 'ToolSha256') -cne $ToolPin })
    if ($foreign.Count) { return (& $no ("{0} entries were not written by the pinned the K1a sign-off tooling (private) (pin {1}; e.g. phase {2} ToolSha256 '{3}'): use a new cycle directory with the pinned files" -f $foreign.Count, $ToolPin, (& $pv $foreign[0] 'Phase'), (& $pv $foreign[0] 'ToolSha256'))) }
    # K1a: no standing acceptance, no sound check, no rehearsals (A1-A4 are asked every cycle, checked above)
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
    if ($p2b -gt $script:FsObsReadingToBaMaxSec) { return (& $no ("the temperature reading is {0:N0} s before BA started (max {1} s): a reading from before an abandoned cycle does not count; take a new reading (the K1a sign-off tooling (private) -Phase B), then a new BA/BF and -Phase E" -f $p2b, $script:FsObsReadingToBaMaxSec)) }
    # second review MINOR-3: the reading belongs to the FIRST BA after it (no other BA of this cycle, and no abandoned
    # cycle's BA of this nonce, started at or after the reading and before this BA)
    $fb = Test-FsObsReadingFirstBa -CycleDir (Split-Path -Parent $Path) -BaSummary $BaSummary -BaUtc $ba.StartUtc -ReadingUtc $r1 -Nonce $Nonce -AbandonedDir $AbandonedDir
    if (-not $fb.Ok) { return (& $no $fb.Why) }
    $es = [string](& $pv $last['E'] 'StartUtc')
    $eStart = ConvertFrom-FsObsUtc $es
    if ($null -eq $eStart) { return (& $no "phase E has no valid UTC start time ('$es')") }
    if ($eStart -lt $bf.StartUtc) { return (& $no ("phase E (presence) started at {0}, before BF started ({1}): run the K1a sign-off tooling (private) -Phase E again after BF" -f $eStart.ToString('o'), $bf.StartUtc.ToString('o'))) }
    $tp = Join-Path (Split-Path -Parent $Path) 'checklist-k1a.txt'
    [pscustomobject]@{ Ok = $true; Why = ("phases A, B, E passed; presence confirmed {0:N0} s ago (max {1} s); temperature reading {2} (battery status {3}, unit {6}) {4:N0} s before BA (max {5} s); {7}; presence after BF; tool = pin" -f $age, $script:FsObsChecklistMaxAgeSec, $rT, $rS, $p2b, $script:FsObsReadingToBaMaxSec, $rU, $b10.Why); Path = $Path
                       Sha256 = (Get-FsObsSha $Path); EUtc = $t['E']; AgeSec = [Math]::Round($age, 1); TxtPath = $tp; TxtSha256 = (Get-FsObsSha $tp); ReadingToBaSec = [Math]::Round($p2b, 1); Ba10 = $b10 }
}

function Get-FsObsSha([string]$Path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { $null } }

# Review 2 MINOR-1: one captured row of a SUMMARY.txt that Read-FsObsPhaseSummary accepted: exactly one row <Id>, exit 0,
# its file <Id>.txt next to the SUMMARY with the recorded SHA-256. Returns @{ Ok; Why; Text }.
function Get-FsObsRowText([string]$Summary, [string]$Id) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "${Id}: $w"; Text = $null } }
    if (-not $Summary -or -not (Test-Path -LiteralPath $Summary -PathType Leaf)) { return (& $no 'no SUMMARY.txt') }
    $rows = @([IO.File]::ReadAllLines($Summary) | Where-Object { $_ -cmatch ('^' + $Id + '\t') })
    if ($rows.Count -ne 1) { return (& $no "the SUMMARY has $($rows.Count) $Id rows (exactly 1 expected)") }
    $c = $rows[0].Split("`t")
    if ($c.Count -ne 5 -or $c[1] -cne '0') { return (& $no "the row did not exit 0 ('$($rows[0])')") }
    if ($c[3] -cnotmatch '^[0-9a-f]{64}\z' -or (Split-Path -Leaf $c[4]) -cne "$Id.txt") { return (& $no "the row has no SHA-256 or names another file ('$($rows[0])')") }
    $f = Join-Path (Split-Path -Parent $Summary) "$Id.txt"
    $h = Get-FsObsSha $f
    if (-not $h) { return (& $no "missing: $f") }
    if ($h -cne $c[3]) { return (& $no "$f has SHA-256 $h, not the $($c[3]) recorded at the capture (changed after it)") }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; Text = [IO.File]::ReadAllText($f) }
}
# The BA/BF "must be" rows (<withheld rows file>, SIGNOFF-3d C): BA04 _a, BA16 the v2.7 vbmeta digest, BA20 user,
# BA23 this unit's serial, BF02 current-slot a (the getvar answer is on stderr, after the "# stderr" line).
# Returns @{ Ok; Why; Values }.
function Test-FsObsMustBe {
    param([string]$BaSummary, [string]$BfSummary, [string]$Serial)
    $vals = [ordered]@{}
    $prop = { param([string]$s, [string]$id, [string]$want, [string]$what)
        $r = Get-FsObsRowText $s $id
        if (-not $r.Ok) { return "BA/BF must-be rows: $($r.Why)" }
        # review 3 MINOR-4: only the command's stdout (fs-capture writes any stderr after a "# stderr" line: an adb notice is not the value)
        $so = ($r.Text -split "`r?`n# stderr`r?`n", 2)[0]; if ($so.StartsWith('# stderr')) { $so = '' }
        $l = @(($so -split "`r?`n") | Where-Object { $_ -ne '' })
        $v = if ($l.Count -eq 1) { $l[0].Trim() } else { "<$($l.Count) lines>" }
        $vals[$id] = $v
        if ($v -cne $want) { return "BA/BF must-be rows: $id ($what) is '$v', not '$want'" }
        $null }
    foreach ($x in @(@($BaSummary, 'BA04', '_a', 'ro.boot.slot_suffix'), @($BaSummary, 'BA16', $script:FsObsBaseline.VbmetaDigest, 'ro.boot.vbmeta.digest, the v2.7 build K1a is made for'),
                     @($BaSummary, 'BA20', 'user', 'ro.build.type'), @($BaSummary, 'BA23', $Serial, 'ro.serialno, this unit'))) {
        $w = & $prop $x[0] $x[1] $x[2] $x[3]
        if ($w) { return [pscustomobject]@{ Ok = $false; Why = $w; Values = $vals } }
    }
    $r = Get-FsObsRowText $BfSummary 'BF02'
    if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Why = "BA/BF must-be rows: $($r.Why)"; Values = $vals } }
    $cs = @([regex]::Matches($r.Text, '(?m)^(?:\(bootloader\) )?current-slot:[ \t]*(\S*)[ \t]*\r?$') | ForEach-Object { $_.Groups[1].Value })
    $vals['BF02'] = $(if ($cs.Count -eq 1) { $cs[0] } else { "<$($cs.Count) current-slot lines>" })
    if ($cs.Count -ne 1 -or $cs[0] -cne 'a') { return [pscustomobject]@{ Ok = $false; Why = "BA/BF must-be rows: BF02 (getvar current-slot) is '$($vals['BF02'])', not 'a'"; Values = $vals } }
    [pscustomobject]@{ Ok = $true; Why = "BA04 _a, BA16 $($script:FsObsBaseline.VbmetaDigest.Substring(0, 8))..., BA20 user, BA23 $Serial, BF02 a"; Values = $vals }
}

# Parses and checks a stage-2a/3a MANIFEST.txt against the image file and the repository.
# Returns @{ Ok; Why; Nonce; ImageSha }.
function Test-FsObsManifest {
    param([string]$ImagePath, [string]$Q3)
    $spec = $script:FsObsStage[$script:FsObs3dLabel]
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
    # the v2.7 vbmeta inputs and digest (as stage 3d), and the pinned K1a kernel, config and kgate result
    if ((& $v '(?m)^vbmeta\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.Vbmeta) { return (& $no 'MANIFEST vbmeta is not the v2.7 OTA vbmeta (aae4af3a...)') }
    if ((& $v '(?m)^vbmeta_system\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.VbmetaSystem) { return (& $no 'MANIFEST vbmeta_system is not the v2.7 OTA vbmeta_system (28f5ccc9...)') }
    if ((& $v '(?m)^vbmeta digest\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.VbmetaDigest) { return (& $no 'MANIFEST vbmeta digest is not 66b76196...f12a (the v2.7 build both units run)') }
    if ((& $v '(?m)^K1a kernel\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.K1aKernel) { return (& $no 'MANIFEST K1a kernel is not the pinned K1a Image (087f0e72...1840)') }
    if ((& $v '(?m)^K1a config\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.K1aConfig) { return (& $no 'MANIFEST K1a config is not the pinned k1a.config (4aa0c894...826b)') }
    if ($m -cnotmatch '(?m)^kgate result\s+[0-9a-f]{64}\s+tools/kgate/validation/quest3/check-k1a\.json \(gate-mode PASS') { return (& $no 'MANIFEST has no kgate gate-mode PASS line for check-k1a.json') }
    if ($m -cmatch '(?m)/bin/fs-pattern\s') { return (& $no 'MANIFEST lists /bin/fs-pattern: not a K1a image (no display program in K1a)') }
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
          [string]$BaSummary = '', [string]$BfSummary = '', [string]$ChecklistFile = '',
          [string]$ReviewedSha = $script:FsNoK1aReviewedSha, [string]$ReviewedDir = $script:FsNoK1aReviewedDir, [scriptblock]$LocalDate = $null)
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
        $r.Exit = 2; $r.Why = "REFUSED: -Serial '$Serial' is not a K1a unit (Unit 2 QUEST3UNIT2, Unit 1 QUEST3UNIT1): nothing booted, no device action"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
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
    # a withdrawn K1a candidate is never run, neither as the image nor as the reference of a nonce-only rebuild
    foreach ($w in @(@('image', $mf.ImageSha), @('reviewed reference', $ReviewedSha))) {
        $wd = Get-FsNoK1aWithdrawn $w[1]
        if ($wd) { $r.Exit = 2; $r.Why = "image refused: the $($w[0]) $($w[1]) is a WITHDRAWN candidate ($wd)"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    }
    # review 2 MAJOR-2: the reviewed candidate, or a nonce-only rebuild of it (both images opened), else refused
    if ($mf.ImageSha -ceq $ReviewedSha) {
        # delta review MINOR-1: the reviewed image only in the reviewed directory, with the reviewed nonce
        $rvN = if ($ReviewedDir -cmatch '-([0-9a-f]{16})\z') { $Matches[1] } else { '' }
        if ((Split-Path -Leaf $dir) -cne $ReviewedDir -or $mf.Nonce -cne $rvN) {
            $r.Exit = 2; $r.Why = "image refused: it hashes to the reviewed candidate $ReviewedSha, but its directory is '$(Split-Path -Leaf $dir)' and its MANIFEST nonce $($mf.Nonce) (the reviewed candidate is $ReviewedDir, nonce $rvN)"
            & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
        }
        $noTxt = "the reviewed candidate ($ReviewedSha)"
    }
    else {
        $refDir = Join-Path $br $ReviewedDir
        $no1 = Test-FsNonceOnlyK1a -Ref $refDir -Cand $dir -RefSha $ReviewedSha
        if (-not $no1.Ok) {
            $r.Exit = 2; $r.Why = "image refused: not the reviewed candidate $ReviewedSha and not a nonce-only rebuild of it ($refDir): $(@($no1.Diffs)[0..([Math]::Min(4, @($no1.Diffs).Count - 1))] -join '; ')"
            & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
        }
        $noTxt = "a nonce-only rebuild of the reviewed candidate ($($no1.RefNonce) -> $($no1.CandNonce); fs-nonceonly-k1a checks passed)"
    }
    & $Say "image OK: stage $($script:FsObs3dLabel) nonce $($mf.Nonce) sha256 $($mf.ImageSha)"
    & $Say "candidate: $noTxt"
    if ($Preflight) { $r.Exit = 0; $r.Why = 'preflight OK: manifest, image, K1a kernel, baseline, sources and attempt freshness verified; no device action'; & $Say $r.Why; return [pscustomobject]$r }
    # PM request (K1a on both units): Unit 1 only when Unit 2's recorded outcome allows it (Get-FsK1aUnit2Outcome; before any device query)
    $u2 = $null
    if ($Serial -ceq $script:FsK1aUnit1) {
        $u2 = Get-FsK1aUnit2Outcome $br
        if (-not $u2.Ok) { $r.Exit = 2; $r.Why = "REFUSED: Unit 1 attempt before Unit 2's result: $($u2.Why): nothing booted, no device action"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
        & $Say "unit order OK: $($u2.Why)"
    }
    # console checklist (J-118): before any device query, the dwell gate and the attempt registration
    $clPin = Get-FsObsChecklistPin $Q3
    $cl = Test-FsObsChecklist -Path (Get-FsObsChecklistPath $ChecklistFile $BaSummary) -Nonce $mf.Nonce -NowUtc (& $NowUtc) -ToolPin $clPin -BaSummary $BaSummary -BfSummary $BfSummary -Serial $Serial -AbandonedDir (Join-Path $br 'abandoned') -LocalDate $LocalDate -Unit2 $u2
    if (-not $cl.Ok) { $r.Exit = 2; $r.Why = "REFUSED: $($cl.Why): nothing booted, no device action"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    & $Say "console checklist OK: $($cl.Why) ($($cl.Path))"
    # review 2 MINOR-1: the BA/BF must-be rows, machine-checked (before any device query)
    $mb = Test-FsObsMustBe -BaSummary $BaSummary -BfSummary $BfSummary -Serial $Serial
    if (-not $mb.Ok) { $r.Exit = 2; $r.Why = "REFUSED: $($mb.Why): nothing booted, no device action"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    & $Say "must-be rows OK: $($mb.Why)"
    $q = & $Fastboot @('devices') 15000
    $serials = @(); foreach ($line in ([string]$q.StdOut -split "`r?`n")) { if ($line -match '^(\S+)\s+fastboot\s*$') { $serials += $Matches[1] } }
    if ($q.Error -or $q.TimedOut -or $q.ExitCode -ne 0 -or $serials.Count -ne 1 -or $serials[0] -cne $Serial) {
        $r.Exit = 2; $r.Why = "need exactly one fastboot device, $Serial (got: $($serials -join ','))"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    $dwOk = $null
    if ($true) {   # the dwell gate is unconditional (as stages 3c and 3d)
        # FS-R-010 section 6: BA to the attempt at most 5 min, enforced BEFORE the boot and before the attempt is registered
        $dw = Test-FsObsDwell -BaSummary $BaSummary -BfSummary $BfSummary -Nonce $mf.Nonce -Serial $Serial -NowUtc (& $NowUtc)
        if (-not $dw.Ok) {
            if ($dw.Abandon) {
                $ad = Join-Path $br 'abandoned'
                $null = New-Item -ItemType Directory -Force -Path $ad
                $af = Join-Path $ad ("{0}-{1}.txt" -f (& $NowUtc).ToString('yyyyMMddTHHmmssZ'), $mf.Nonce)
                $txt = @("ABANDONED CYCLE (K1a, FS-R-010 section 6): nothing was booted; the attempt was not registered; nonce $($mf.Nonce) is unspent",
                         "BA started: $($dw.BaUtc.ToString('o'))", "checked at: $((& $NowUtc).ToString('o'))", ("elapsed: {0:N1} s (max {1} s)" -f $dw.ElapsedSec, $script:FsObsDwellMaxSec),
                         "BA summary: $BaSummary", "BF summary: $BfSummary", 'next: return to Android, a new temperature reading, new BA/BF (<withheld capture tool> -CapturesRoot <new dir>), then the attempt')
                [IO.File]::WriteAllText($af, (($txt -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
                $r.Why = "REFUSED: $($dw.Why). Abandoned-cycle record: $af"
            } else { $r.Why = "REFUSED: $($dw.Why)" }
            $r.Exit = 2; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
        }
        & $Say "dwell gate OK: $($dw.Why)"
        $dwOk = $dw; $dwAt = (& $NowUtc)
    }
    $reg = Register-FsAttempt -Dir $dir -Nonce $mf.Nonce -LedgerDir $LedgerDir -Note "$($script:FsObs3dLabel) image=$($mf.ImageSha) serial=$Serial unit=$($script:FsObsUnits[$Serial])"
    if (-not $reg.Ok) { $r.Exit = 2; $r.Why = $reg.Reason; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    $out = Join-Path $dir ('observe-' + (& $NowUtc).ToString('yyyyMMddTHHmmssZ'))
    $null = New-Item -ItemType Directory -Path $out
    $r.OutDir = $out
    $logPath = Join-Path $out 'observe.log'
    $L = { param($line) $t = "$((& $NowUtc).ToString('o'))  $line"; Add-Content -LiteralPath $logPath -Value $t -Encoding UTF8; & $Say $t }
    & $L "attempt registered: $($reg.Files -join ', ')"
    $o = [ordered]@{ Schema = 'frameshift.fs-observe.v1'; Stage = $script:FsObs3dLabel; Nonce = $mf.Nonce; Serial = $Serial; Image = $ImagePath; ImageSha256 = $mf.ImageSha
                     BootStartUtc = $null; HandoffUtc = $null; BudgetOriginUtc = $null; HandoffClass = $null; BootRc = $null; BootStdOut = ''; BootStdErr = ''; BootError = $null
                     GadgetSeen = $false; GadgetUtc = $null; ComPort = $null; WrongSerials = @(); GadgetWaitSec = $GadgetWaitSec; NextCommand = $null; NoGadgetNote = $null }
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
    $o.MustBe = $mb.Values; $o.NonceOnly = $noTxt
    if ($null -ne $u2) { $o.Unit2OutcomeNonce = $u2.Nonce; $o.Unit2Outcome = $u2.Outcome; $o.Unit2OutcomeFile = $u2.File; $o.Unit2OutcomeSha256 = $u2.Sha256 }
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
        if (-not $o.GadgetSeen) {
            & $L "no gadget FS-$($mf.Nonce) within $GadgetWaitSec s: the PID 1 deadline / recovery table applies"
            # README 6.11: one more read-only query; the unit back in fastboot is what the module index refusal looks like
            $q2 = $null; try { $q2 = & $Fastboot @('devices') 15000 } catch { }
            $back = ($null -ne $q2 -and -not $q2.Error -and -not $q2.TimedOut -and $q2.ExitCode -eq 0 -and ([string]$q2.StdOut -split "`r?`n") -cmatch ('^' + [regex]::Escape($Serial) + '\s+fastboot\s*$'))
            $o.NoGadgetNote = if ($back) { "no gadget, and $Serial is back in fastboot: consistent with the module index refusal (wrong build?) or an init failure; the reason is only in the device's RAM log" } else { "no gadget, and $Serial is not (yet) in fastboot: the PID 1 deadline / recovery table applies" }
            & $L $o.NoGadgetNote
        }
        & $L "collector budget origin: BootStartUtc $($o.BootStartUtc) (before fastboot boot; every handoff class). Th $($o.HandoffUtc) is evidence only"
    }
    if ($o.GadgetSeen) {
        $o.NextCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-collect-k1a.ps1 -K1aPort $($o.ComPort) -K1aNonce $($mf.Nonce) -K1aBootStartUtc $($o.BootStartUtc) -K1aHandoffUtc $($o.HandoffUtc) -K1aOutDir `"$out\collect`""
        & $L "NEXT: $($o.NextCommand)"
        & $L "THEN (after AF, AA, the follow-ups and checklist phase F; WALKTHROUGH step 8): fs-classify-k1a.ps1 -CollectDir `"$out\collect`" -ObserveDir `"$out`""
    }
    [IO.File]::WriteAllText((Join-Path $out 'observe.json'), (([pscustomobject]$o | ConvertTo-Json -Depth 4) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r.Exit = 0; $r.Why = "attempt made: handoff $($o.HandoffClass), gadget $($o.GadgetSeen)"; $r.Observe = [pscustomobject]$o
    [pscustomobject]$r
}

if ($MyInvocation.InvocationName -eq '.') { return }
# ------------------------------------------------------------------ CLI -----
$exit = 70
try {
    if (-not $Image) { Write-Output 'usage: fs-observe-k1a.ps1 -Image <dir>\boot-k1a.img (-Preflight | -Serial <QUEST3UNIT2|QUEST3UNIT1> -ConfirmNonce <nonce> -BaSummary <file> -BfSummary <file> [-ChecklistFile <file>] [-ThenCollect])'; exit 64 }
    $q3 = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $imgPath = (Resolve-Path -LiteralPath $Image).Path
    $buildRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path 'build\k1a'     # FIXED: <repo>\build\k1a (SF1)
    $fb = $FastbootExe
    $res = Invoke-FsObserve -ImagePath $imgPath -Serial $Serial -ConfirmNonce $ConfirmNonce -Preflight ([bool]$Preflight) `
        -BuildRoot $buildRoot -Q3 $q3 -GadgetWaitSec $GadgetWaitSec `
        -Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) Invoke-FsNative -Exe $fb -ArgList $ArgList -TimeoutMs $TimeoutMs } `
        -Gadget { param([string]$N) Get-FsGadget -Nonce $N } -NowUtc { [DateTime]::UtcNow } -Sleep { param([int]$Ms) Start-Sleep -Milliseconds $Ms } `
        -Say { param([string]$Line) Write-Host $Line } -BaSummary $BaSummary -BfSummary $BfSummary -ChecklistFile $ChecklistFile     # Write-Host: the function's pipeline output is its result object only
    $exit = $res.Exit
    if ($res.Exit -eq 0 -and $res.Observe -and $res.Observe.GadgetSeen -and $ThenCollect) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fs-collect-k1a.ps1') -K1aPort $res.Observe.ComPort `
            -K1aNonce $res.Observe.Nonce -K1aBootStartUtc $res.Observe.BootStartUtc -K1aHandoffUtc $res.Observe.HandoffUtc -K1aOutDir (Join-Path $res.OutDir 'collect')
        Write-Output "collector exit: $LASTEXITCODE"
    }
} catch { Write-Output "OBSERVER ERROR: $($_.Exception.Message)"; $exit = 70 }
exit $exit
