# FrameShift host — before/after probe for fix round 6 (package reviews of cf251bb).
# Run against this tree and against a copy of cf251bb; every probe must FAIL there and PASS
# here. No device, no COM port.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File fixtures\round6-before.ps1 [-HostDir <host dir under test>]
param([string]$HostDir = '')
$ErrorActionPreference = 'Stop'
$FIX = $PSScriptRoot
$CODE = if ($HostDir) { [IO.Path]::GetFullPath($HostDir) } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $CODE 'fs-collect.ps1')
. (Join-Path $CODE 'fs-classify.ps1')
. (Join-Path $FIX 'synth.ps1')
$pass = 0; $fail = 0
function P([string]$name, [scriptblock]$probe) {
    $ok = $false; $why = ''
    try { $ok = [bool](& $probe) } catch { $why = $_.Exception.Message }
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name $why" }
}
function Invoke-R6Replay([string]$case, [hashtable]$ov = @{}) {
    Invoke-FsReplay -RawPath (Join-Path $FIX "replay\$case.raw") -OutDir (Join-Path ([IO.Path]::GetTempPath()) ('r6-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))) -Overrides $ov
}
Write-Output "== round-6 probes, code under test: $CODE"
P 'B1  already-acked: stop at the first FSS1 with a foreign ack, no fs-valve, gated fs-done' {
    $r = Invoke-R6Replay 'already-acked'; ($r.StopReason -match 'foreign ack') -and -not $r.ValveSent -and $r.DoneSent -and @($r.Sent | Where-Object { $_ -ceq 'fs-status' }).Count -eq 1 }
P 'S2  runner refusal (FSVE1): terminal at once, INCONCLUSIVE, gated fs-done' {
    $r = Invoke-R6Replay 'runner-refused-2a'; ($r.StopReason -match 'the runner refused') -and $r.DoneSent }
P 'S1  the ack window caps the phases before the runner' {
    $r = Invoke-R6Replay 'ack-window-reached' @{ AckGiveUpMs = 3000 }; $r.StopReason -match 'ack window reached' }
P 'B1  fs-observe.ps1 exists and defines Invoke-FsObserve (no session)' {
    $f = Join-Path $CODE 'fs-observe.ps1'; (Test-Path $f) -and ([IO.File]::ReadAllText($f) -match 'function Invoke-FsObserve') }
P 'B1  the classifier derives the stage-1 class from observe.json + the verified FSV1 (Get-FsStage1Class)' {
    (Get-FsStage1Class -Observe ([pscustomobject]@{ Nonce = 'a'; Stage = '2a'; HandoffClass = 'HANDOFF_ACKNOWLEDGED'; GadgetSeen = $true }) -Collect ([pscustomobject]@{ Nonce = 'a'; Stage = '2a'; Verified = $true })).Class -ceq 'PASS' }
P 'nit stage-3a own-SIGALRM reason is one string (argument-mode concatenation fixed)' {
    $N = 'a1b2c3d4e5f60718'; $C = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'
    $st = Get-Stage3aGoodSteps -Nonce $N -Chal $C; $st[1] = New-SynthStep 2 'pattern' @() @() @{ end = 'signaled'; code = [long]-1; sig = [long]14 }
    $o = Get-FsStage3aOutcome -Stage1Class PASS -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $st }) -Nonce $N -Challenge $C
    $o.Outcome -ceq 'DISPLAY FAIL' -and $o.Reason -match 'its own SIGALRM backstop' }
Write-Output "TOTAL: $pass passed, $fail failed"
