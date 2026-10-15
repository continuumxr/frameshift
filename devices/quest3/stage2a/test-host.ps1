# FrameShift — host-side check of the whole-image harness captures (Windows
# PowerShell 5.1). Run AFTER test-image.sh (WSL) for stage 2a or stage 3a:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\stage2a\test-host.ps1 -Dir build\stage2a-harness
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\stage2a\test-host.ps1 -Dir build\stage3a-harness
# For every scenario directory (meta.json, capture.raw, capture.raw.idx):
#   1. common/host/fsb1.ps1 Test-Fsb1Record over the WHOLE capture (the collector's
#      call), with the image nonce, the runner challenge and the stage's step list;
#      it must agree with the Python decoder's verdict recorded by the harness;
#   2. host/fs-classify.ps1: Get-FsStage2aOutcome (OUTCOMES §6) or
#      Get-FsStage3aOutcome (OUTCOMES §8) with stage-1 class PASS; it must equal the
#      scenario's expected outcome;
#   3. every full host exchange: host/fs-collect.ps1 -Stage 2a|3a -Replay of the
#      capture (the live engine; tokens from the recorded writes) must end
#      COLLECTED-VALID with no divergence, every recorded write made and a byte-exact
#      re-capture; host/fs-classify.ps1 -Stage 2a|3a -CollectDir on its output must
#      print the same OUTCOME.
# Verdicts are read from collect.json and the OUTCOME: line, not from exit codes.
# Touches no device and no COM port. Writes <Dir>\host-results.txt.
param([Parameter(Mandatory)][string]$Dir)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Q3 = Split-Path -Parent $PSScriptRoot
. (Join-Path $Q3 'common\host\fsb1.ps1')
. (Join-Path $Q3 'host\fs-classify.ps1')
$Dir = (Resolve-Path $Dir).Path
$out = New-Object System.Collections.Generic.List[string]
$fail = 0
function Say([string]$s) { $script:out.Add($s); Write-Output $s }
function Chk([bool]$ok, [string]$label) { if (-not $ok) { $script:fail++ }; Say ("{0}  {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $label) }
function Get-RelHash([string]$p) { (Get-FileHash (Join-Path $Q3 $p) -Algorithm SHA256).Hash.ToLower() }

Say "# test-host.ps1  $(Get-Date -Format s)  dir=$Dir"
Say "# fsb1.ps1 $(Get-RelHash 'common\host\fsb1.ps1')  fs-classify.ps1 $(Get-RelHash 'host\fs-classify.ps1')  fs-collect.ps1 $(Get-RelHash 'host\fs-collect.ps1')"
foreach ($sd in @(Get-ChildItem -LiteralPath $Dir -Directory | Sort-Object Name)) {
    $mp = Join-Path $sd.FullName 'meta.json'
    if (-not (Test-Path -LiteralPath $mp)) { continue }
    $m = Get-Content -Raw -LiteralPath $mp | ConvertFrom-Json
    $stg = if ($m.stage -ceq 'stage3a') { '3a' } else { '2a' }
    Say ""
    Say "## $($m.scenario) ($($m.stage), plan $($m.plan), mods: $(@($m.mods) -join ','))"
    if ($m.plan -notlike 'full*') { Say "     (no runner request in this scenario: nothing to decode; the harness checked the reboot)"; continue }
    [byte[]]$raw = [IO.File]::ReadAllBytes((Join-Path $sd.FullName 'capture.raw'))
    $d = Test-Fsb1Record -Bytes $raw -Exp $m.exp -Nonce $m.nonce -Challenge $m.challenge -Steps @($m.steps)
    $py = (Get-Content -LiteralPath (Join-Path $sd.FullName 'fsb1-python.txt') -TotalCount 1)
    Chk ($d.Ok) "fsb1.ps1 Test-Fsb1Record over the whole capture: $(if ($d.Ok) { 'VALID' } else { "REJECT $($d.Reason) $($d.Detail)" })"
    Chk (($d.Ok -and $py -ceq 'VALID') -or (-not $d.Ok -and $py -like "REJECT $($d.Reason)*")) "agrees with the Python decoder ($py)"
    if ($d.Ok) {
        foreach ($st in $d.Steps) { Say ("     step {0} {1,-7} end={2} code={3} sig={4} errno={5} ms={6} term_ms={7} kill_ms={8} out={9}B err={10}B why={11}" -f $st['i'], $st['id'], $st['end'], $st['code'], $st['sig'], $st['errno'], $st['ms'], $st['term_ms'], $st['kill_ms'], $st['out_len'], $st['err_len'], $st['why']) }
    }
    if ($stg -ceq '3a') { $o = Get-FsStage3aOutcome -Stage1Class 'PASS' -Fsb1 $d -Nonce $m.nonce -Challenge $m.challenge }
    else { $o = Get-FsStage2aOutcome -Stage1Class 'PASS' -Kernel $m.kernel -Fsb1 $d -Nonce $m.nonce -Challenge $m.challenge }
    Say "     OUTCOME $($o.Outcome) (rule $($o.Rule)) $($o.Reason)"
    foreach ($c in $o.StepClasses) { Say ("       {0} {1,-7} {2,-11} {3}" -f $c.I, $c.Id, $c.Class, $c.Notes) }
    Chk ($o.Outcome -ceq $m.expect.outcome) "classifier (stage $stg) outcome = expected '$($m.expect.outcome)'"
    if ($m.plan -ceq 'full') {
        $rd = Join-Path $sd.FullName 'replay-collect'
        if (Test-Path -LiteralPath $rd) { Remove-Item -Recurse -Force -LiteralPath $rd }
        $co = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Q3 'host\fs-collect.ps1') -Stage $stg -Replay (Join-Path $sd.FullName 'capture.raw') -OutDir $rd -Nonce $m.nonce -Kernel $m.kernel -Pid1 $m.pid1
        $cx = $LASTEXITCODE
        foreach ($l in $co) { Say "     | $l" }
        $jp = Join-Path $rd 'collect.json'
        if (-not (Test-Path -LiteralPath $jp)) { Chk $false "fs-collect.ps1 -Replay wrote no collect.json (exit $cx)"; continue }
        $j = Get-Content -Raw -LiteralPath $jp | ConvertFrom-Json
        Chk ($j.Status -ceq 'COLLECTED-VALID' -and $j.Stage -ceq $stg) "fs-collect.ps1 -Stage $stg -Replay: status $($j.Status), stage $($j.Stage), runner $($j.RunVerb) (exit $cx)"
        Chk (@($j.Replay.Divergence).Count -eq 0 -and $j.Replay.RecaptureIsSourcePrefix -and @($j.Replay.UnperformedWrites).Count -eq 0) "replay: no divergence, every recorded write made, re-capture is a byte-exact prefix ($($j.Replay.ConsumedBytes)/$($j.Replay.SourceBytes) bytes)"
        $ko = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Q3 'host\fs-classify.ps1') -Stage $stg -CollectDir $rd -Stage1Class PASS
        $kx = $LASTEXITCODE
        foreach ($l in $ko) { Say "     | $l" }
        $ol = @($ko | Where-Object { $_ -like 'OUTCOME: *' })
        $got = if ($ol.Count -eq 1 -and $ol[0] -cmatch '^OUTCOME: (PASS \(machine side\)|PASS|COMPATIBILITY FAIL|INTEGRITY FAULT|NO-DISPLAY|DISPLAY FAIL|INCONCLUSIVE)\s') { $Matches[1] } else { '?' }
        Chk ($got -ceq $m.expect.outcome) "fs-classify.ps1 -Stage $stg -CollectDir on the replay: OUTCOME $got (exit $kx); expected $($m.expect.outcome)"
    }
}
Say ""
Say "TOTAL: $(if ($fail -eq 0) { 'all host checks PASS' } else { "$fail FAIL" })"
[IO.File]::WriteAllLines((Join-Path $Dir 'host-results.txt'), $out.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
exit $(if ($fail -eq 0) { 0 } else { 1 })
