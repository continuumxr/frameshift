# FrameShift admission rule r2: offline tests of the ONE shared battery/temperature rule (Windows PowerShell 5.1). No device,
# no network, no sound, no write outside -OutFile. Silent (FS_SILENT=1 is set; nothing here plays a sound).
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host-admission-r2.ps1 [-OutFile <path>]
# Sections:
#   P  Test-FsAdmissionBatteryRule (fs-admission-r2.ps1) against an independent integer oracle; the boundary cases (status 2 at
#      69/70/71 %, 29.9/30.0/34.9/35.0 deg C); status 3/4/5 unchanged; status 1 and malformed text never
#   W  the observers' wrapper Test-FsObsBatteryRule (K1g, N1) answers exactly as the shared function
#   X  parity: the T0 checker's Python mirror (ts/tools/t0_check.py) answers as the PowerShell rule (needs python)
#   S  source: the four enforcing tools dot-source the shared file and hold no second copy of the rule; the SIGNOFF host-pin
#      tables of K1g and N1 pin fs-admission-r2.ps1 as the working file
# The end-to-end cases (phase B of the checklists, BA10 and the recorded reading at the observers) are in test-host-k1g.ps1
# (L4, L4b, O8, O8b) and test-host-n1.ps1 (ADM1, ADM2); the T0 session in test-host-t0.ps1 (admission cases) and
# ts/tools/test_t0.py (the checker, run under WSL with a native fs-thermald test build).
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
. (Join-Path $here 'fs-admission-r2.ps1')

# independent oracle (integers): the battery rule alone. Below 35.0 deg C for every admitted status; status 3/4/5 then pass;
# status 2 passes below 30.0 deg C, or (below 35.0) with the level above 70 %. (The level above 50 % and the 10.0 deg C floor
# are the callers' named checks, tested end to end in test-host-k1g.ps1 and test-host-n1.ps1.)
function Oracle([int]$T, [int]$S, [int]$L) {
    if ($T -ge 350) { return $false }
    if ($S -ge 3 -and $S -le 5) { return $true }
    if ($S -eq 2) { return ($T -lt 300 -or $L -gt 70) }
    $false
}
function Ok3([string]$t, [string]$s, [string]$l) { $null -eq (Test-FsAdmissionBatteryRule $t $s $l) }

$temps = 100, 250, 299, 300, 301, 340, 349, 350, 351, 400
$levels = 0, 51, 69, 70, 71, 99, 100
$statuses = 1, 2, 3, 4, 5, 0, 6, 9
$bad = @(); $cnt = 0
foreach ($t in $temps) { foreach ($l in $levels) { foreach ($s in $statuses) {
    $got = Ok3 "$t" "$s" "$l"; $want = Oracle $t $s $l; $cnt++
    if ($got -ne $want) { $bad += "T=$t S=$s L=$l got $got want $want" } } } }
T "P1 the rule against the oracle on the grid ($cnt cases: $($temps.Count) temperatures x $($levels.Count) levels x $($statuses.Count) statuses)" ($bad.Count -eq 0) ($bad -join '; ')

# the boundary cases: status 2 at 69/70/71 % x 29.9 / 30.0 / 34.9 / 35.0 deg C
$expect = [ordered]@{
    '299/2/69' = $true;  '299/2/70' = $true;  '299/2/71' = $true      # 29.9 deg C: charging passes at any level (above 50 %, held by the caller)
    '300/2/69' = $false; '300/2/70' = $false; '300/2/71' = $true      # 30.0 deg C: only above 70 %
    '349/2/69' = $false; '349/2/70' = $false; '349/2/71' = $true      # 34.9 deg C: only above 70 %
    '350/2/69' = $false; '350/2/70' = $false; '350/2/71' = $false     # 35.0 deg C: never
    '350/2/100' = $false; '399/2/100' = $false
}
$bad = @(); foreach ($k in $expect.Keys) { $p = $k.Split('/'); if ((Ok3 $p[0] $p[1] $p[2]) -ne $expect[$k]) { $bad += "$k expected $($expect[$k])" } }
T 'P2 status 2 boundaries: 29.9 C passes at 69/70/71 %; 30.0 C and 34.9 C pass only at 71 % (fail at 69 % and at exactly 70 %); 35.0 C fails at every level' ($bad.Count -eq 0) ($bad -join '; ')

$bad = @(); foreach ($s in '3', '4', '5') { foreach ($l in '51', '70', '100', '') { foreach ($t in '100', '299', '300', '349') { if (-not (Ok3 $t $s $l)) { $bad += "S=$s L=$l T=$t refused" } } }
    foreach ($t in '350', '351', '999') { if (Ok3 $t $s '100') { $bad += "S=$s T=$t accepted" } } }
T 'P3 status 3/4/5 unchanged: accepted at every level (or an unknown level) from 10.0 to 34.9 C; 35.0 C and above refused' ($bad.Count -eq 0) ($bad -join '; ')

$bad = @()
foreach ($s in '1', '0', '6', '7', '9', '', '22', '2 ', ' 2', 'x', '-1', '3 ', '03') { if (Ok3 '300' $s '100') { $bad += "status '$s' accepted at 300/100 %" } }
foreach ($s in '1', '0', '6', '') { if (Ok3 '250' $s '100') { $bad += "status '$s' accepted at 250/100 %" } }
T "P4 status 1, 0, 6-9 and malformed status text ('', '22', '2 ', ' 2', 'x', '-1', '3 ', '03') never pass, even at 100 %" ($bad.Count -eq 0) ($bad -join '; ')

$bad = @()
foreach ($l in '', 'x', '071', '+71', '71.0', '101', '-5', ' 71', '71 ', '0x47', "$([char]0x0667)$([char]0x0661)") { if (Ok3 '340' '2' $l) { $bad += "level '$l' accepted" } }
if ($null -eq (Test-FsAdmissionBatteryRule '340' '2' $null)) { $bad += 'level $null accepted' }
if (-not (Ok3 '299' '2' '')) { $bad += 'status 2 at 29.9 C refused for an unknown level (the level above 50 % is the caller''s check)' }
T "P5 status 2 above 30.0 C with an unknown or malformed level ('', null, 'x', '071', '+71', '71.0', '101', '-5', padded, hex, non-ASCII digits) is refused: the level must be the text 0-100 without a leading zero" ($bad.Count -eq 0) ($bad -join '; ')

$bad = @(); foreach ($t in '', 'x', '29.9', '-1', '12345', ' 300', '30 ') { if (Ok3 $t '3' '80') { $bad += "temperature '$t' accepted" } }
T "P6 malformed temperature text ('', 'x', '29.9', '-1', five digits, padded) is refused for every status" ($bad.Count -eq 0) ($bad -join '; ')

$why = Test-FsAdmissionBatteryRule '305' '2' '70'
T 'P7 the refusal reason names the status, the temperature, the level and both limits (30.0 C; 35.0 C with the level above 70 %)' ($why -like '*status 2*305*70 %*below 300*below 350*above 70 %*') $why
$why1 = Test-FsAdmissionBatteryRule '300' '1' '90'
T 'P8 the refusal reason of status 1 names the accepted forms' ($why1 -like '*status 1 is not 3, 4 or 5*nor 2*below 300*below 350*above 70 %*') $why1
$why2 = Test-FsAdmissionBatteryRule '350' '2' '100'
T 'P9 35.0 C is refused by the rule itself with a reason naming the limit' ($why2 -like '*350*35.0 deg C*') $why2
T 'P10 the limits are the documented ones: 35.0 C (350), 30.0 C (300), the status 2 level above 70 %, the level above 50 %, the floor 100' ($script:FsAdmTempLimit -eq 350 -and $script:FsAdmChargingLimit -eq 300 -and $script:FsAdmChargingHighLevel -eq 70 -and $script:FsAdmLevelAbove -eq 50 -and $script:FsAdmTempMin -eq 100) "$($script:FsAdmTempLimit)/$($script:FsAdmChargingLimit)/$($script:FsAdmChargingHighLevel)/$($script:FsAdmLevelAbove)/$($script:FsAdmTempMin)"

# W: the observers' wrapper is the same function
foreach ($ob in 'fs-observe-k1g.ps1', 'fs-observe-n1.ps1') {
    $f = Join-Path $here $ob
    $res = & { param($file, $ts, $ls, $ss) . $file
        $o = New-Object System.Collections.Generic.List[string]
        foreach ($t in $ts) { foreach ($l in $ls) { foreach ($s in $ss) { $a = Test-FsObsBatteryRule "$t" "$s" "$l"; $b2 = Test-FsAdmissionBatteryRule "$t" "$s" "$l"; if ([string]$a -cne [string]$b2) { $o.Add("T=$t S=$s L=$l wrapper '$a' shared '$b2'") } } } }
        $o.Add("TWOARG-299:$(if ($null -eq (Test-FsObsBatteryRule '299' '2')) { 'accepted' } else { 'refused' })")
        $o.Add("TWOARG-340:$(if ($null -eq (Test-FsObsBatteryRule '340' '2')) { 'accepted' } else { 'refused' })")
        $o } $f $temps $levels $statuses
    $diff = @($res | Where-Object { $_ -notlike 'TWOARG-*' })
    T "W $ob Test-FsObsBatteryRule answers exactly as the shared rule on the grid; with no level, status 2 passes below 30.0 C and not above" ($diff.Count -eq 0 -and ($res -contains 'TWOARG-299:accepted') -and ($res -contains 'TWOARG-340:refused')) ($res -join '; ')
}

# X: parity with the T0 checker's Python mirror (ts/tools/t0_check.py admission_battery_ok); skipped when no python is installed
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $chk = Join-Path (Split-Path -Parent $here) 'ts\tools\t0_check.py'
    $code = @'
import importlib.util, sys
sp = importlib.util.spec_from_file_location('t0_check', sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
for t in (100, 250, 299, 300, 301, 340, 349, 350, 351, 400):
    for l in (0, 51, 69, 70, 71, 99, 100):
        for s in (1, 2, 3, 4, 5, 0, 6, 9):
            print(t, s, l, 1 if m.admission_battery_ok(s, t, l) else 0)
print('X', 1 if m.admission_battery_ok(2, 340, None) else 0, 1 if m.admission_battery_ok(2, 299, None) else 0)
'@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("adm-r2-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.py')
    [IO.File]::WriteAllText($tmp, $code)
    $out = @(& python -I $tmp $chk 2>&1); Remove-Item -LiteralPath $tmp -Force
    $bad = @(); $cnt = 0
    foreach ($ln in $out) { $f = ([string]$ln).Trim().Split(' ')
        if ($f.Count -eq 4) { $cnt++; $ps = Ok3 $f[0] $f[1] $f[2]; if ($ps -ne ($f[3] -eq '1')) { $bad += "T=$($f[0]) S=$($f[1]) L=$($f[2]) python $($f[3]) powershell $ps" } }
        elseif ($f.Count -eq 3 -and $f[0] -ceq 'X') { if ($f[1] -ne '0' -or $f[2] -ne '1') { $bad += "unknown level: python 34.0 C/$($f[1]) 29.9 C/$($f[2]) (want 0/1)" } }
        else { $bad += "python output: $ln" } }
    T "X1 the T0 checker's Python mirror answers exactly as the PowerShell rule on the same grid ($cnt cases), and refuses status 2 above 30.0 C with an unknown level" ($bad.Count -eq 0 -and $cnt -eq 560) (($bad | Select-Object -First 5) -join '; ')
} else { $log.Add('SKIP  X1: no python on the PATH') }

# S: the source
$files = 'fs-checklist-k1g.ps1', 'fs-observe-k1g.ps1', 'fs-checklist-n1.ps1', 'fs-observe-n1.ps1', 'fs-t0-capture.ps1'
$bad = @()
foreach ($f in $files) {
    $t = [IO.File]::ReadAllText((Join-Path $here $f))
    if ($t -cnotmatch "(?m)^\. \(Join-Path \`$PSScriptRoot 'fs-admission-r2\.ps1'\)") { $bad += "$f does not dot-source fs-admission-r2.ps1" }
    if ($t -cnotmatch 'Test-FsAdmissionBatteryRule') { $bad += "$f never calls the shared rule" }
    if ($t -cmatch '-lt \$script:\w*ChargingLimit' -or $t -cmatch '\$script:\w*StatusOk\b') { $bad += "$f still holds its own copy of the charging rule" }
}
T 'S1 the five enforcing PowerShell tools (K1g and N1 checklists and observers, the T0 capture) dot-source fs-admission-r2.ps1, call the shared rule and hold no second copy of it' ($bad.Count -eq 0) ($bad -join '; ')
$q3 = Split-Path -Parent $here
$wk = Sha (Join-Path $here 'fs-admission-r2.ps1'); $bad = @()
foreach ($sg in 'SIGNOFF-k1g.md', 'SIGNOFF-n1.md', 'SIGNOFF-t0.md') {
    $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $q3 $sg)), '\| `devices\\quest3\\host\\fs-admission-r2\.ps1` \| `([0-9a-f]{64})` \|')
    if (-not $m.Success) { $bad += "$sg has no fs-admission-r2.ps1 pin row" } elseif ($m.Groups[1].Value -cne $wk) { $bad += "$sg pins $($m.Groups[1].Value), the working file is $wk" }
}
T 'S2 SIGNOFF-k1g.md, SIGNOFF-n1.md and SIGNOFF-t0.md pin fs-admission-r2.ps1 as the working file (make-signoff-k1g.ps1, make-signoff-n1.ps1 and make-signoff-t0.ps1 were run after the last change)' ($bad.Count -eq 0) (($bad -join '; ') + " [$wk]")

$log.Add("TOTAL: $n cases, $fail failed")
Write-Output "TOTAL: $n cases, $fail failed"
if ($OutFile) { [IO.File]::WriteAllText($OutFile, (($log -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false))) }
if ($fail) { exit 1 } else { exit 0 }
