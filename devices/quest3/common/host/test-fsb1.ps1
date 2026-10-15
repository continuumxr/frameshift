# FrameShift FSB1 host fixtures (Windows PowerShell 5.1). No device.
#   powershell.exe -NoProfile -File devices\quest3\common\host\test-fsb1.ps1
# Runs every case in fixtures\fsb1\CASES.tsv through Test-Fsb1Record, checks
# VALID payloads against PAYLOADS.tsv (hashes of fs-supervise's raw capture
# files), then cross-checks each verdict/reason against the Python decoder's
# RESULTS-python.txt. Exit 0 only if everything matches.
param([string]$FixDir = '')   # -FixDir <dir>: read cases/write results there (default: the tracked fixture dir)
. (Join-Path $PSScriptRoot 'fsb1.ps1')
$ErrorActionPreference = 'Stop'
$FX = if ($FixDir) { $FixDir } else { Join-Path $PSScriptRoot '..\fixtures\fsb1' }
$payloads = @{}
foreach ($row in [IO.File]::ReadAllLines((Join-Path $FX 'PAYLOADS.tsv'))) {
    if (-not $row) { continue }
    $c = $row.Split("`t"); $payloads["$($c[0])|$($c[1])|$($c[2])"] = @($c[3], [long]$c[4])
}
$py = @{}
foreach ($row in [IO.File]::ReadAllLines((Join-Path $FX 'RESULTS-python.txt'))) {
    if ($row -cmatch '^(\S+)\s+(PASS|FAIL) got=(\S+)') { $py[$Matches[1]] = $Matches[3] }
}
$out = New-Object System.Collections.Generic.List[string]
$pass = 0; $fail = 0; $agree = 0
foreach ($row in [IO.File]::ReadAllLines((Join-Path $FX 'CASES.tsv'))) {
    if (-not $row) { continue }
    $c = $row.Split("`t")
    $name = $c[0]; $expect = $c[1]; $reason = $c[2]
    $bytes = [IO.File]::ReadAllBytes((Join-Path $FX "$name.txt"))
    $r = Test-Fsb1Record -Bytes $bytes -Exp $c[3] -Nonce $c[4] -Challenge $c[5] -Steps ($c[6].Split(','))
    $got = if ($r.Ok) { 'VALID' } else { 'REJECT' }
    $why = if ($r.Ok) { '-' } else { $r.Reason }
    $good = ($got -ceq $expect -and $why -ceq $reason)
    $extra = ''
    if ($good -and $r.Ok) {
        foreach ($st in $r.Steps) {
            foreach ($s in 'out', 'err') {
                $want = $payloads["$($c[7])|$($st['i'])|$s"]
                if ((Get-Fsb1Sha256Hex $st[$s]) -cne $want[0] -or $st[$s].Length -ne $want[1]) { $good = $false; $extra = " payload mismatch step $($st['i']) $s" }
            }
        }
        if ($good) { $extra = " ($($r.Steps.Count) steps, payloads = raw captures)" }
    }
    $mine = "$got/$why"
    if ($py.ContainsKey($name) -and $py[$name] -ceq $mine) { $agree++ } else { $good = $false; $extra += " DISAGREES with python ($($py[$name]))" }
    if ($good) { $pass++ } else { $fail++ }
    $out.Add(('{0,-28} {1,-4} got={2} want={3}/{4}{5}' -f $name, $(if ($good) { 'PASS' } else { 'FAIL' }), $mine, $expect, $reason, $extra))
}
$out.Add("CROSS-CHECK powershell = python on $agree of $($pass + $fail) cases")
$out.Add("TOTAL pass=$pass fail=$fail")
$out | ForEach-Object { Write-Host $_ }
[IO.File]::WriteAllText((Join-Path $FX 'RESULTS-powershell.txt'), (($out -join "`n") + "`n"))
if ($fail -eq 0) { exit 0 } else { exit 1 }
