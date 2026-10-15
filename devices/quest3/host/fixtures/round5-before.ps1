# FrameShift host — before/after probe for the coordinated round (collector rev 3,
# classifier rev 3: stage-2a step 8 `inv`, stage 3a). Run it against this tree and
# against a copy of the previous revision (5a8308d); every probe must FAIL there and
# PASS here. No device, no COM port.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File fixtures\round5-before.ps1 [-HostDir <host dir under test>]
param([string]$HostDir = '')
$ErrorActionPreference = 'Stop'
$FIX = $PSScriptRoot
$CODE = if ($HostDir) { [IO.Path]::GetFullPath($HostDir) } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $CODE 'fs-collect.ps1')
. (Join-Path $CODE 'fs-classify.ps1')
. (Join-Path $FIX 'synth.ps1')                      # this tree's fixture helpers (8-step stage 2a, stage 3a)
$pass = 0; $fail = 0
function P([string]$name, [scriptblock]$probe) {
    $ok = $false; $why = ''
    try { $ok = [bool](& $probe) } catch { $why = $_.Exception.Message }
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name $why" }
}
$N = 'a1b2c3d4e5f60718'; $C = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'
Write-Output "== round-5 probes, code under test: $CODE"
P 'P1 stage 2a: a correct 8-step record (step 8 inv, informational) classifies PASS' {
    $o = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = (Get-Stage2aGoodSteps -Nonce $N -Chal $C) }) -Nonce $N -Challenge $C
    $o.Outcome -ceq 'PASS' }
P 'P2 stage 2a: an inv tool fault does not change PASS' {
    $s = Get-Stage2aGoodSteps -Nonce $N -Chal $C; $s[7] = New-SynthStep 8 'inv' @() @() @{ why = 'strays-alive' }
    (Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $s }) -Nonce $N -Challenge $C).Outcome -ceq 'PASS' }
P 'P3 the collector accepts the fs-display verb' { (New-FsCommand 'fs-display' ('e' * 32)) -ceq ('fs-display ' + ('e' * 32)) }
P 'P4 the classifier has a stage-3a function and classifies a committed run as PASS (machine side)' {
    (Get-FsStage3aOutcome -Stage1Class PASS -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = (Get-Stage3aGoodSteps -Nonce $N -Chal $C) }) -Nonce $N -Challenge $C).Outcome -ceq 'PASS (machine side)' }
P 'P5 the stage-3a replay capture collects COLLECTED-VALID through fs-display' {
    $out = Join-Path ([IO.Path]::GetTempPath()) ('r5-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $r = Invoke-FsReplay -RawPath (Join-Path $FIX 'replay\3a-committed.raw') -OutDir $out -Overrides @{ Stage = '3a' }
    $r.Status -ceq 'COLLECTED-VALID' -and @($r.Replay.Divergence).Count -eq 0 }
P 'P6 the default host give-up follows the image deadline (stage 2a 260 s: 245 000 ms)' { (New-FsCollectCfg -Nonce $N).GiveUpMs -eq 245000 }
Write-Output "TOTAL: $pass passed, $fail failed"
