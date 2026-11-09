# FrameShift thermal rule r3: offline tests of the ONE shared admission rule, the stop threshold and the follow-up rule
# (Windows PowerShell 5.1). No device, no network, no sound, no write outside -OutFile. Silent (FS_SILENT=1 is set).
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host-admission-r3.ps1 [-OutFile <path>]
# Sections:
#   P  Test-FsAdmissionR3BatteryRule (fs-admission-r3.ps1) against an independent integer oracle; the boundaries 39.9/40.0 C,
#      status 1-5 (and malformed), the level (not the rule's: the callers' named check, here only that it is ignored)
#   T  Test-FsThermalR3Stop: 429 no, 430 yes
#   F  Get-FsFollowUpR3Problems: one reading equal / lower / higher than AA10, at the ceiling, too early, too late (419/420/421 s), no AA10; two or
#      more readings (the series rule: timing, not rising, the last below 400); a reading at 430
#   W  the observers' wrapper Test-FsObsBatteryRule (K1g, N1) answers exactly as the shared function
#   S  source: the four enforcing K1g/N1 tools dot-source fs-admission-r3.ps1 and hold no second copy of the rule; the
#      SIGNOFF host-pin tables of K1g and N1 pin it as the working file; fs-wait-admission.sh carries r3 with the same limits
# The end-to-end cases are in test-host-k1g.ps1 (O8, O8b, L4, L4b, L7, L7b, L7c, L9) and test-host-n1.ps1 (ADM1, ADM2, ADM3).
param([string]$OutFile = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:FS_SILENT = '1'
$here = $PSScriptRoot
$script:n = 0; $script:fail = 0; $script:log = New-Object System.Collections.Generic.List[string]
function T([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:n++; if (-not $Ok) { $script:fail++ }
    $l = "{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { "  [$Detail]" } else { '' })
    $script:log.Add($l); Write-Output $l
}
function Sha([string]$p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }
. (Join-Path $here 'fs-admission-r3.ps1')

# independent oracle (integers): below 40.0 deg C and the status 2, 3, 4 or 5 (the floor 100 and the level above 50 % are
# the callers' named checks, tested end to end in test-host-k1g.ps1 and test-host-n1.ps1)
function Oracle([int]$T, [int]$S) { ($T -lt 400) -and ($S -ge 2 -and $S -le 5) }
function Ok3([string]$t, [string]$s, [string]$l) { $null -eq (Test-FsAdmissionR3BatteryRule $t $s $l) }

$temps = 100, 250, 299, 300, 349, 350, 351, 398, 399, 400, 401, 429, 430, 999
$levels = 0, 50, 51, 70, 71, 100
$statuses = 0, 1, 2, 3, 4, 5, 6, 9
$bad = @(); $cnt = 0
foreach ($t in $temps) { foreach ($l in $levels) { foreach ($s in $statuses) {
    $got = Ok3 "$t" "$s" "$l"; $want = Oracle $t $s; $cnt++
    if ($got -ne $want) { $bad += "T=$t S=$s L=$l got $got want $want" } } } }
T "P1 the rule against the oracle on the grid ($cnt cases: $($temps.Count) temperatures x $($levels.Count) levels x $($statuses.Count) statuses)" ($bad.Count -eq 0) ($bad -join '; ')

$bad = @()
foreach ($s in '2', '3', '4', '5') {
    if (-not (Ok3 '399' $s '51')) { $bad += "39.9 C status $s refused" }
    if (Ok3 '400' $s '100') { $bad += "40.0 C status $s accepted" }
}
if (Ok3 '399' '1' '100') { $bad += '39.9 C status 1 accepted' }
T 'P2 the boundaries: 39.9 C (399) accepted for status 2, 3, 4 and 5; 40.0 C (400) refused for every status; status 1 refused at 39.9 C' ($bad.Count -eq 0) ($bad -join '; ')

$bad = @()
foreach ($s in '1', '0', '6', '7', '9', '', '22', '2 ', ' 2', 'x', '-1', '3 ', '03') { if (Ok3 '300' $s '100') { $bad += "status '$s' accepted" } }
T "P3 status 1, 0, 6-9 and malformed status text ('', '22', '2 ', ' 2', 'x', '-1', '3 ', '03') never pass" ($bad.Count -eq 0) ($bad -join '; ')

$bad = @(); foreach ($t in '', 'x', '29.9', '-1', '12345', ' 300', '30 ') { if (Ok3 $t '3' '80') { $bad += "temperature '$t' accepted" } }
T "P4 malformed temperature text ('', 'x', '29.9', '-1', five digits, padded) is refused" ($bad.Count -eq 0) ($bad -join '; ')

$bad = @(); foreach ($l in '', $null, 'x', '50', '0', '100') { if ($null -ne (Test-FsAdmissionR3BatteryRule '350' '2' $l)) { $bad += "level '$l' changed the answer" } }
T 'P5 the level does not change the rule (status 2 at 35.0 C passes with any level text; the level above 50 % is the callers'' named check, battery-above-50 / BA10)' ($bad.Count -eq 0) ($bad -join '; ')

$w1 = Test-FsAdmissionR3BatteryRule '400' '3' '80'; $w2 = Test-FsAdmissionR3BatteryRule '300' '1' '80'
T 'P6 the refusal reasons name the limit (400, 40.0 deg C, thermal r3) and the accepted statuses (2, 3, 4 or 5)' ($w1 -like '*400*40.0 deg C*thermal r3*' -and $w2 -like '*status 1 is not 2, 3, 4 or 5*thermal r3*') "$w1 / $w2"
T 'P7 the limits are the documented ones: ceiling 400, floor 100, level above 50, stop 430, follow-ups 270/420/570/240 s' ($script:FsAdmR3FuOneMaxSec -eq 420 -and $script:FsAdmR3TempLimit -eq 400 -and $script:FsAdmR3TempMin -eq 100 -and $script:FsAdmR3LevelAbove -eq 50 -and $script:FsAdmR3StopAt -eq 430 -and $script:FsAdmR3FuFirstSec -eq 270 -and $script:FsAdmR3FuSecondSec -eq 570 -and $script:FsAdmR3FuGapSec -eq 240) "$($script:FsAdmR3TempLimit)/$($script:FsAdmR3TempMin)/$($script:FsAdmR3LevelAbove)/$($script:FsAdmR3StopAt)"

# T: the stop
$bad = @()
foreach ($t in '429', 429, '399', '000', '') { if (Test-FsThermalR3Stop $t) { $bad += "'$t' is a stop" } }
foreach ($t in '430', 430, '431', '450', '999') { if (-not (Test-FsThermalR3Stop $t)) { $bad += "'$t' is not a stop" } }
T 'T1 the stop: 429 (42.9 C) is not, 430 (43.0 C) and above are (text or int); empty is not a reading' ($bad.Count -eq 0) ($bad -join '; ')

# F: the follow-up rule
$aa = [DateTime]::new(2026, 11, 8, 7, 0, 0, [DateTimeKind]::Utc)
function Fu([int[]]$T, [double[]]$Min, $Aa10, $AaEnd = $aa) { @(Get-FsFollowUpR3Problems $T ([DateTime[]]@($Min | ForEach-Object { $aa.AddSeconds([int](60 * $_)) })) $AaEnd $Aa10) }
$cases = [ordered]@{
    'one equal to AA10 (350/350)'                  = @((Fu @(350) @(5) 350), '')
    'one lower than AA10 (340/350)'                = @((Fu @(340) @(5) 350), '')
    'one at 399 with AA10 399'                     = @((Fu @(399) @(5) 399), '')
    'one at exactly 270 s'                         = @((Fu @(340) @(4.5) 350), '')
    'one higher than AA10 (351/350)'               = @((Fu @(351) @(5) 350), '*higher than AA10*continue*')
    'one at 400 with AA10 410 (the ceiling)'       = @((Fu @(400) @(5) 410), '*not below 400*')
    'one at 269 s'                                 = @((Fu @(340) @(4.4833) 350), '*less than about 5 min*')
    'one at 419 s (PM cap 2026-11-09)'             = @((Fu @(340) @(6.9833) 350), '')
    'one at exactly 420 s'                         = @((Fu @(340) @(7) 350), '')
    'one at 421 s: second required'                = @((Fu @(340) @(7.0167) 350), '*more than about 7 min (420 s)*continue*')
    'one late (+12 min) and lower: second required' = @((Fu @(300) @(12) 350), '*more than about 7 min (420 s)*')
    'one late (+12 min) and higher'                = @((Fu @(360) @(12) 350), '*more than about 7 min*higher than AA10*')
    'two: late first (8 min), second lower (12)'   = @((Fu @(340, 335) @(8, 12) 350), '')
    'one without AA10'                             = @((Fu @(340) @(5) $null), '*no AA10*')
    'one at 430 with AA10 440'                     = @((Fu @(430) @(5) 440), '*430 (43.0 deg C) or more*')
    'one at 429 with AA10 429 (ceiling)'           = @((Fu @(429) @(5) 429), '*not below 400*')
    'none'                                         = @((Fu @() @() 350), '*no follow-up reading*')
    'two: higher then equal (360, 360; AA10 350)'  = @((Fu @(360, 360) @(5, 10) 350), '')
    'two: falling (360, 355)'                      = @((Fu @(360, 355) @(5, 10) 350), '')
    'two: rising (360, 361)'                       = @((Fu @(360, 361) @(5, 10) 350), '*rising or concerning*')
    'two: the last at 400 (410, 400)'              = @((Fu @(410, 400) @(5, 10) 405), '*rising or concerning*')
    'two: the second at 9 min (540 s)'             = @((Fu @(360, 350) @(5, 9) 350), '*second reading is less than about 10 min*')
    'two: 239 s apart (6.0, 9.9833 min)'           = @((Fu @(360, 350) @(6, 9.9833) 350), '*less than 240 s after reading 1*')
    'two: a reading at 430'                        = @((Fu @(430, 420) @(5, 10) 420), '*430 (43.0 deg C) or more*')
    'two: lower then a voluntary rise (340, 345)'  = @((Fu @(340, 345) @(5, 10) 350), '*rising or concerning*')
    'three: rising then falling below 400'         = @((Fu @(380, 390, 385) @(5, 10, 15) 370), '')
    'three: still rising'                          = @((Fu @(380, 390, 395) @(5, 10, 15) 370), '*rising or concerning*')
}
$bad = @(); foreach ($k in $cases.Keys) { $p = @($cases[$k][0]); $want = $cases[$k][1]
    if ($want -ceq '' -and $p.Count) { $bad += "$k : not finished: $($p -join '; ')" }
    if ($want -cne '' -and ($p.Count -eq 0 -or ($p -join '; ') -notlike $want)) { $bad += "$k : '$($p -join '; ')' is not like '$want'" } }
T "F1 the follow-up rule ($($cases.Count) cases): one reading not higher than AA10 and below 400, 270 to 420 s after AA, finishes; higher, at 400, early, later than 420 s, no AA10 or none: not finished; two or more: the series rule (570 s, 240 s apart, not rising, the last below 400); any reading at 430: not finished" ($bad.Count -eq 0) ($bad -join ' | ')
$p1 = @(Fu @(351) @(5) 350); $p2 = @(Fu @(400) @(5) 410)
T 'F2 a higher or ceiling single reading names what to do next (a second reading at least 240 s later / every 5 min)' (($p1 -join ' ') -like '*second reading at least 240 s later*' -and ($p2 -join ' ') -like '*continue every 5 min*') "$($p1 -join '; ') / $($p2 -join '; ')"
$pnA = @(Fu @(340) @(1) 350 $null)
T 'F3 without an AA end time the timing is not judged here (the caller records "no AA end time"); the comparison with AA10 still is' ($pnA.Count -eq 0) ($pnA -join '; ')

# W: the observers' wrapper is the same function
foreach ($ob in 'fs-observe-k1g.ps1', 'fs-observe-n1.ps1') {
    $f = Join-Path $here $ob
    $res = & { param($file, $ts, $ls, $ss) . $file
        $o = New-Object System.Collections.Generic.List[string]
        foreach ($t in $ts) { foreach ($l in $ls) { foreach ($s in $ss) { $a = Test-FsObsBatteryRule "$t" "$s" "$l"; $b2 = Test-FsAdmissionR3BatteryRule "$t" "$s" "$l"; if ([string]$a -cne [string]$b2) { $o.Add("T=$t S=$s L=$l wrapper '$a' shared '$b2'") } } } }
        $o.Add("TWOARG-399:$(if ($null -eq (Test-FsObsBatteryRule '399' '2')) { 'accepted' } else { 'refused' })")
        $o.Add("TWOARG-400:$(if ($null -eq (Test-FsObsBatteryRule '400' '5')) { 'accepted' } else { 'refused' })")
        $o } $f $temps $levels $statuses
    $diff = @($res | Where-Object { $_ -notlike 'TWOARG-*' })
    T "W $ob Test-FsObsBatteryRule answers exactly as the shared r3 rule on the grid; with no level, status 2 at 39.9 C passes and status 5 at 40.0 C does not" ($diff.Count -eq 0 -and ($res -contains 'TWOARG-399:accepted') -and ($res -contains 'TWOARG-400:refused')) ($res -join '; ')
}

# S: the source
$files = 'fs-checklist-k1g.ps1', 'fs-observe-k1g.ps1', 'fs-checklist-n1.ps1', 'fs-observe-n1.ps1'
$bad = @()
foreach ($f in $files) {
    $t = [IO.File]::ReadAllText((Join-Path $here $f))
    if ($t -cnotmatch "(?m)^\. \(Join-Path \`$PSScriptRoot 'fs-admission-r3\.ps1'\)") { $bad += "$f does not dot-source fs-admission-r3.ps1" }
    if ($t -cmatch "fs-admission-r2\.ps1'\)") { $bad += "$f still dot-sources fs-admission-r2.ps1" }
    if ($t -cnotmatch 'Test-FsAdmissionR3BatteryRule') { $bad += "$f never calls the shared rule" }
    if ($t -cmatch '-lt \$script:\w*ChargingLimit' -or $t -cmatch '\$script:FsAdm(Temp|Charging)\w*' -or $t -cmatch '-ge 350\b' -or $t -cmatch '-l[te] 400\b' -or $t -cmatch '-ge 400\b') { $bad += "$f still holds an r2 limit or a literal 350/400 rule" }
}
foreach ($f in 'fs-checklist-k1g.ps1', 'fs-checklist-n1.ps1') {
    $t = [IO.File]::ReadAllText((Join-Path $here $f))
    if ($t -cnotmatch 'Get-FsFollowUpR3Problems') { $bad += "$f does not call the shared follow-up rule" }
    if ($t -cmatch 'below-400' -or $t -cmatch 'range-100-349') { $bad += "$f still names an r2 check" }
}
T 'S1 the four enforcing PowerShell tools (K1g and N1 checklists and observers) dot-source fs-admission-r3.ps1, call the shared rule (the checklists also the shared follow-up rule) and hold no r2 limit or literal 350/400 rule' ($bad.Count -eq 0) ($bad -join '; ')
$q3 = Split-Path -Parent $here
$wk = Sha (Join-Path $here 'fs-admission-r3.ps1'); $bad = @()
foreach ($sg in 'SIGNOFF-k1g.md', 'SIGNOFF-n1.md') {
    $tx = [IO.File]::ReadAllText((Join-Path $q3 $sg))
    $m = [regex]::Match($tx, '\| `devices\\quest3\\host\\fs-admission-r3\.ps1` \| `([0-9a-f]{64})` \|')
    if (-not $m.Success) { $bad += "$sg has no fs-admission-r3.ps1 pin row" } elseif ($m.Groups[1].Value -cne $wk) { $bad += "$sg pins $($m.Groups[1].Value), the working file is $wk" }
    if ($tx -cmatch 'fs-admission-r2\.ps1') { $bad += "$sg still names fs-admission-r2.ps1" }
}
T 'S2 SIGNOFF-k1g.md and SIGNOFF-n1.md pin fs-admission-r3.ps1 as the working file and no longer name fs-admission-r2.ps1 (make-signoff-k1g.ps1 and make-signoff-n1.ps1 were run after the last change)' ($bad.Count -eq 0) (($bad -join '; ') + " [$wk]")
$sh = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $q3)) 'tools\session\fs-wait-admission.sh'))
$shOk = ($sh -cmatch 'r1\|r2\|r3\)' -and $sh -cmatch 'r3\) \[ "\$t" -ge 100 \] && \[ "\$t" -le 399 \] && \[ "\$l" -gt 50 \]' -and $sh -cmatch 'case "\$s" in 2\|3\|4\|5\) return 0' -and $sh -cmatch 'stop=430' -and $sh -cmatch 'stop=400')
T 'S3 tools/session/fs-wait-admission.sh offers r3 with the same limits (100..399, level above 50, status 2-5; ALERT at 430) and keeps r1/r2 (ALERT at 400)' $shOk ''

$log.Add("TOTAL: $n cases, $fail failed")
Write-Output "TOTAL: $n cases, $fail failed"
if ($OutFile) { [IO.File]::WriteAllText($OutFile, (($log -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false))) }
if ($fail) { exit 1 } else { exit 0 }
