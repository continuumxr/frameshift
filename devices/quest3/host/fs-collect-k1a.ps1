# FrameShift K1a serial collector (Windows PowerShell 5.1, no modules). One session for one K1a image
# (devices/quest3/k1a/: our kernel + the stage-3d PID 1 without display parts; runner fs-k1a, FSB1 exp=k1a).
#
# The pinned stage-2a/3a/3b collector fs-collect.ps1 is DOT-SOURCED as a library (it returns early when
# dot-sourced) and NEVER edited: its send gate, capture, index, transports, phase engine (fs-verify, fs-ack,
# fs-status, the runner once, the gated fs-done), FSB1 validation and summary are used unchanged. This file only
#   - adds the verb fs-k1a (a 32-hex challenge) to the command table;
#   - builds the configuration for K1a: runner fs-k1a, refusal tag FSDE1, exp k1a, steps
#     kernel,config,mem,modules,kmsg,fs,usb,log, device deadline 200 s, ack window 150 s (k1a/init.sh),
#     RunnerWorstSec 115 + RunnerMarginSec 5 (k1a/fs-k1a.sh; k1a/tools/check-bounds-k1a.py), no display cue, no
#     beeps, no post-record pause; the expected kernel release 5.10.246-gdbc2bc83a2b6 in FSV1;
#   - the live CLI (the same steps as fs-collect.ps1's) and a replay CLI for this stage.
# THE RUNNER START GATE (T0 + 85 s: the device's own time refusal): the engine sends the runner only if
#   (host give-up) - now >= RunnerWorstSec + RunnerMarginSec, with host give-up = BootStartUtc + 200 - 15 s
#   (BootStartUtc is taken before `fastboot boot`, so it is not later than T0). So the runner starts no later
#   than BootStartUtc + 200 - 15 - 115 - 5 = BootStartUtc + 65 s <= T0 + 65 s < T0 + 85 s (the device's own
#   `time` refusal). A later start is not sent: INCONCLUSIVE, the gated fs-done recovers at once. collect.json
#   records RunnerStartNoLaterThanUtc.
#
# LIVE (only after the Chair's ruling and the PM's sign-off; never run by fixtures):
#   fs-collect-k1a.ps1 -K1aPort COM7 -K1aNonce <16 hex> -K1aBootStartUtc <observe.json BootStartUtc> [-K1aHandoffUtc <...>] -K1aOutDir <new dir>
# REPLAY (offline; a capture plus its index through the same engine):
#   fs-collect-k1a.ps1 -K1aReplay <capture.raw> [-K1aReplayIndex <idx>] -K1aOutDir <new dir>
# Exit: 10 record collected, FSB1-valid; 11 collected, FSB1 rejected; 14 INCONCLUSIVE; 20 refused to start
#   (nothing sent); 70 internal error. The K1a verdict is fs-classify-k1a.ps1's.
#
# Dot-source scope (the stage-3c M4 rule): every parameter here is named K1a* and collides with none of
# fs-collect.ps1's; the bound arguments are snapshotted BEFORE the dot-source and read only from the snapshot.
[CmdletBinding()]
param(
    [string]$K1aPort = '', [string]$K1aNonce = '', [string]$K1aOutDir = '',
    [string]$K1aReplay = '', [string]$K1aReplayIndex = '',
    [string]$K1aBootStartUtc = '', [string]$K1aHandoffUtc = '',
    [int]$K1aHostMarginSec = 15,
    [int]$K1aPollMs = 50,
    [string]$K1aReplayKernel = '',      # REPLAY FIXTURES ONLY: the FSV1 kernel release the replayed capture carries (the QEMU harness
                                        # runs on the host kernel); recorded in collect.json as FixtureOverrides
    [string]$K1aReplayPid1 = '',        # REPLAY FIXTURES ONLY: the FSV1 pid1 field of the capture (qemu-user's binfmt argv)
    [int]$K1aReplayGiveUpSec = 0        # REPLAY FIXTURES ONLY: an earlier host give-up (virtual seconds from the replay start), to
                                        # exercise the runner start gate; recorded in collect.json as FixtureOverrides
)
$script:FsK1aArgs = @{} + $PSBoundParameters
$script:FsK1aInvocation = $MyInvocation.InvocationName
$script:FsK1aDefaults = @{ K1aPort = ''; K1aNonce = ''; K1aOutDir = ''; K1aReplay = ''; K1aReplayIndex = ''; K1aBootStartUtc = ''; K1aHandoffUtc = ''
                           K1aHostMarginSec = 15; K1aPollMs = 50; K1aReplayKernel = ''; K1aReplayPid1 = ''; K1aReplayGiveUpSec = 0 }
function Get-FsK1aArg { param([string]$Name)
    if ($script:FsK1aArgs.ContainsKey($Name)) { return $script:FsK1aArgs[$Name] }
    return $script:FsK1aDefaults[$Name]
}
. (Join-Path $PSScriptRoot 'fs-collect.ps1')        # pinned; returns early when dot-sourced (its param block binds here: never read below)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- the K1a stage -----------------------------------------------------------------------------------------
$script:FsK1aSpec = @{
    Verb = 'fs-k1a'; Refusal = 'FSDE1'; Exp = 'k1a'
    Steps = @('kernel', 'config', 'mem', 'modules', 'kmsg', 'fs', 'usb', 'log')
    DeviceDeadlineSec = 200; AckWindowSec = 150                    # k1a/init.sh DEADLINE, ACK_WINDOW
    RunnerWorstSec = 115; RunnerMarginSec = 5                      # k1a/fs-k1a.sh RUNNER_WORST
    DeviceRunnerStartLimitSec = 85                                 # T0 + 200 - 115: the device's own `time` refusal
    Kernel = '5.10.246-gdbc2bc83a2b6'; Pid1 = '/bin/busybox,sh,/init'
    AckStatusTries = 2
}
$script:FsCmdSpec['fs-k1a'] = '^[0-9a-f]{32}\z'

function New-FsK1aCfg {
    param([Parameter(Mandatory)][string]$Nonce, [long]$GiveUpMs = -1, [long]$AckGiveUpMs = -1, $Timing = $null, [int]$HostMarginSec = 15)
    $sp = $script:FsK1aSpec
    # the engine's own constructor (stage 3b gives the closest defaults), then every stage field set for K1a
    $c = New-FsCollectCfg -Nonce $Nonce -Stage '3b' -Exp $sp.Exp -Steps $sp.Steps -DeviceDeadlineSec $sp.DeviceDeadlineSec -AckWindowSec $sp.AckWindowSec `
        -Kernel $sp.Kernel -Pid1 $sp.Pid1 -PreDoneMs 0 -DisplayCueMs 0 -AckStatusTries $sp.AckStatusTries -GiveUpMs $GiveUpMs -AckGiveUpMs $AckGiveUpMs -Timing $Timing
    $c.Stage = 'k1a'; $c.RunVerb = $sp.Verb; $c.RefusalTag = $sp.Refusal
    $c.RunnerWorstSec = $sp.RunnerWorstSec; $c.RunnerMarginSec = $sp.RunnerMarginSec
    $c.Beep1Ms = 0; $c.Beep2Ms = 0; $c.PreDoneMs = 0; $c.DisplayCueMs = 0
    if ($GiveUpMs -lt 0) { $c.GiveUpMs = [long](($sp.DeviceDeadlineSec - $HostMarginSec) * 1000) }
    if ($AckGiveUpMs -lt 0) { $c.AckGiveUpMs = [long](($sp.AckWindowSec - $HostMarginSec) * 1000) }
    $c.RecordTimeoutMs = [long](($sp.RunnerWorstSec + $sp.RunnerMarginSec) * 1000)
    # the runner start limit the engine's budget check implies, relative to the budget origin (static: 65 s)
    $c.RunnerStartLimitSec = $sp.DeviceDeadlineSec - $HostMarginSec - $sp.RunnerWorstSec - $sp.RunnerMarginSec
    if ($c.RunnerStartLimitSec -gt $sp.DeviceRunnerStartLimitSec) { throw "internal: the host runner start limit $($c.RunnerStartLimitSec) s exceeds T0 + $($sp.DeviceRunnerStartLimitSec) s" }
    $c
}

function Get-FsK1aReplayTokens {   # the tokens from the recorded writes, validated by the command table
    param($Index)
    $tk = @{ V = $null; A = $null; C = $null }
    foreach ($w in $Index.W) {
        if ($w.Text -cmatch '^fs-verify ([0-9a-f]{32})\z' -and -not $tk.V) { $tk.V = $Matches[1] }
        elseif ($w.Text -cmatch '^fs-ack ([0-9a-f]{16})\z' -and -not $tk.A) { $tk.A = $Matches[1] }
        elseif ($w.Text -cmatch '^fs-k1a ([0-9a-f]{32})\z' -and -not $tk.C) { $tk.C = $Matches[1] }
    }
    if (-not $tk.V) { $tk.V = New-FsHex 16 }; if (-not $tk.A) { $tk.A = New-FsHex 8 }; if (-not $tk.C) { $tk.C = New-FsHex 16 }
    $tk
}

function Invoke-FsK1aReplay {
    param([Parameter(Mandatory)][string]$RawPath, [string]$IndexPath, [Parameter(Mandatory)][string]$OutDir, [int]$PollMs = 50, [int]$HostMarginSec = 15,
          [string]$Kernel = '', [string]$Pid1 = '', [int]$GiveUpSec = 0)
    if (-not $IndexPath) { $IndexPath = "$RawPath.idx" }
    [byte[]]$raw = [IO.File]::ReadAllBytes($RawPath)
    $ix = Read-FsCaptureIndex -Path $IndexPath -RawLength $raw.Length
    $cfg = New-FsK1aCfg -Nonce $ix.Nonce -HostMarginSec $HostMarginSec
    $fo = [ordered]@{}
    if ($Kernel) { if ($Kernel -cnotmatch '^[0-9A-Za-z._+-]{1,64}\z') { throw 'refused: bad -K1aReplayKernel' }; $cfg.Kernel = $Kernel; $fo.Kernel = $Kernel }
    if ($Pid1) { if ($Pid1 -cnotmatch '^[0-9A-Za-z._/,+-]{1,128}\z') { throw 'refused: bad -K1aReplayPid1' }; $cfg.Pid1 = $Pid1; $fo.Pid1 = $Pid1 }
    if ($GiveUpSec -gt 0) { $cfg.GiveUpMs = [long]$GiveUpSec * 1000; $fo.GiveUpSec = $GiveUpSec }
    $t = New-FsReplayTransport -Raw $raw -Index $ix -PollMs $PollMs
    $r = Invoke-FsCollectRun -Transport $t -OutDir $OutDir -Tokens (Get-FsK1aReplayTokens $ix) -Cfg $cfg -Mode 'replay'
    $r | Add-Member NoteProperty ReplaySource ([ordered]@{ Raw = $RawPath; Sha256 = (Get-FsSha256Hex $raw); Index = $IndexPath })
    [byte[]]$re = [IO.File]::ReadAllBytes($r.Capture.Path)
    $prefixOk = $re.Length -le $raw.Length
    if ($prefixOk -and $re.Length -gt 0) { $src = New-Object byte[] $re.Length; [Array]::Copy($raw, $src, $re.Length); $prefixOk = ([FsHostNative]::DiffIndices($src, $re).Length -eq 0) }
    $r.Replay.RecaptureIsSourcePrefix = $prefixOk
    $r | Add-Member NoteProperty RunnerStartLimitSec $cfg.RunnerStartLimitSec
    $r | Add-Member NoteProperty FixtureOverrides $(if ($fo.Count) { $fo } else { $null })
    $r
}

# ------------------------------------------------------------------ CLI -----
if ($script:FsK1aInvocation -eq '.') { return }
$exit = 70; $r = $null; $started = $false
try {
    $OutDirK = Get-FsK1aArg 'K1aOutDir'
    if (-not $OutDirK) { throw 'refused: -K1aOutDir is required (a new directory)' }
    $margin = [int](Get-FsK1aArg 'K1aHostMarginSec'); $poll = [int](Get-FsK1aArg 'K1aPollMs')
    if ($margin -ne 15) { throw 'refused: -K1aHostMarginSec is fixed at 15 for K1a (the runner start gate is derived from it)' }
    $rp = Get-FsK1aArg 'K1aReplay'
    if ($rp) {
        if (Get-FsK1aArg 'K1aPort') { throw 'refused: -K1aPort and -K1aReplay are exclusive' }
        $started = $true
        $r = Invoke-FsK1aReplay -RawPath $rp -IndexPath (Get-FsK1aArg 'K1aReplayIndex') -OutDir $OutDirK -PollMs $poll -HostMarginSec $margin `
            -Kernel (Get-FsK1aArg 'K1aReplayKernel') -Pid1 (Get-FsK1aArg 'K1aReplayPid1') -GiveUpSec ([int](Get-FsK1aArg 'K1aReplayGiveUpSec'))
        if (@($r.Replay.Divergence).Count) { Write-Output (ConvertTo-FsPrintable "REPLAY DIVERGENCE: $(@($r.Replay.Divergence) -join '; ')") }
    } else {
        if ((Get-FsK1aArg 'K1aReplayKernel') -or (Get-FsK1aArg 'K1aReplayPid1') -or [int](Get-FsK1aArg 'K1aReplayGiveUpSec')) { throw 'refused: -K1aReplayKernel, -K1aReplayPid1 and -K1aReplayGiveUpSec are replay fixtures only' }
        $port = Get-FsK1aArg 'K1aPort'; $nonce = Get-FsK1aArg 'K1aNonce'
        if ($port -cnotmatch '^COM[0-9]{1,3}\z') { throw 'refused: -K1aPort must be given explicitly as COMn (never chosen automatically)' }
        if ($nonce -cnotmatch '^[0-9a-f]{16}\z') { throw 'refused: -K1aNonce must be the image nonce (16 lowercase hex)' }
        $bs = Get-FsK1aArg 'K1aBootStartUtc'
        if (-not $bs) { throw 'refused: -K1aBootStartUtc (observe.json BootStartUtc, taken just before fastboot boot) is required: it is the budget origin' }
        # review MINOR-10: the observer's exact UTC form only (yyyy-MM-ddTHH:mm:ss[.f to .fffffff]Z, ASCII digits); no lenient Parse
        $fmts = [string[]](@("yyyy-MM-dd'T'HH:mm:ss'Z'") + @(1..7 | ForEach-Object { "yyyy-MM-dd'T'HH:mm:ss." + ('f' * $_) + "'Z'" }))
        $parseU = { param([string]$v)
            if ($v -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z\z') { throw "refused: '$v' is not a UTC time yyyy-MM-ddTHH:mm:ss[.fffffff]Z" }
            [DateTime]::ParseExact($v, $fmts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }
        $origin = & $parseU $bs
        $hoEv = $null; $ho = Get-FsK1aArg 'K1aHandoffUtc'
        if ($ho) { $hoEv = & $parseU $ho; if ($hoEv -lt $origin) { throw 'refused: -K1aHandoffUtc precedes -K1aBootStartUtc (inconsistent observer times)' } }
        $cliUtc = [DateTime]::UtcNow
        if ($origin -gt $cliUtc) { throw "refused: -K1aBootStartUtc $($origin.ToString('o')) is later than now (clock step or bad input)" }
        $sp = $script:FsK1aSpec
        $dl = Get-FsHostDeadlines -OriginUtc $origin -DeviceDeadlineSec $sp.DeviceDeadlineSec -AckWindowSec $sp.AckWindowSec -HostMarginSec $margin
        $pre = ConvertTo-FsTransportDeadlines -Deadlines $dl -NowMs 0 -NowUtc ([DateTime]::UtcNow)
        $why = Get-FsLiveStartRefusal -RemainMs $pre.RemainMs -AckRemainMs $pre.AckRemainMs -AckWindowSec $sp.AckWindowSec
        if ($why) { throw "refused: $why" }
        $g = Get-FsGadget -Nonce $nonce
        if (-not $g.SerialOk) { throw "refused: no USB gadget with serial FS-$nonce is present" }
        if ($g.ComPort -cne $port) { throw "refused: $port is not the port registered under FS-$nonce (that is '$($g.ComPort)')" }
        $tokens = @{ V = (New-FsHex 16); A = (New-FsHex 8); C = (New-FsHex 16) }
        $t = New-FsRawSerialTransport -PortName $port -PollMs $poll
        $nowMs = [long]$t.NowMs(); $nowU = [DateTime]::UtcNow
        $cv = ConvertTo-FsTransportDeadlines -Deadlines $dl -NowMs $nowMs -NowUtc $nowU
        $why = Get-FsLiveStartRefusal -RemainMs $cv.RemainMs -AckRemainMs $cv.AckRemainMs -AckWindowSec $sp.AckWindowSec
        if ($why) { throw "refused (after $([long]($nowU - $cliUtc).TotalSeconds) s of preparation): $why" }
        $limitSec = $sp.DeviceDeadlineSec - $margin - $sp.RunnerWorstSec - $sp.RunnerMarginSec
        $timing = [ordered]@{ BudgetOrigin = 'BootStartUtc'; BootStartUtc = $origin.ToString('o'); HandoffUtcEvidence = $(if ($hoEv) { $hoEv.ToString('o') } else { $null })
                              GiveUpUtc = $dl.GiveUpUtc.ToString('o'); AckGiveUpUtc = $dl.AckGiveUpUtc.ToString('o'); DeviceDeadlineNoEarlierThanUtc = $dl.DeviceDeadlineUtc.ToString('o')
                              RunnerStartNoLaterThanUtc = $origin.AddSeconds($limitSec).ToString('o'); DeviceRunnerStartLimit = "T0 + $($sp.DeviceRunnerStartLimitSec) s"
                              CollectorStartUtc = $cliUtc.ToString('o'); ConvertedAtUtc = $nowU.ToString('o'); ConvertedAtMs = $nowMs
                              PreparationMs = [long]($nowU - $cliUtc).TotalMilliseconds; RemainMsAtConversion = $cv.RemainMs; AckRemainMsAtConversion = $cv.AckRemainMs }
        $cfg = New-FsK1aCfg -Nonce $nonce -GiveUpMs $cv.GiveUpMs -AckGiveUpMs $cv.AckGiveUpMs -Timing $timing -HostMarginSec $margin
        Write-Output "HOST GIVE-UP: $($dl.GiveUpUtc.ToString('o')); the runner is sent only before $($origin.AddSeconds($limitSec).ToString('o')) (BootStartUtc + $limitSec s <= T0 + $($sp.DeviceRunnerStartLimitSec) s)"
        $started = $true
        $r = Invoke-FsCollectRun -Transport $t -OutDir $OutDirK -Tokens $tokens -Cfg $cfg -Mode 'live' -PortName $port
    }
    try { Save-FsCollectJson -Result $r -Path (Join-Path $OutDirK 'collect.json') }
    catch { Write-Output (ConvertTo-FsPrintable "COLLECT.JSON NOT WRITTEN: $($_.Exception.Message)") }
    Write-FsSummary $r
    $exit = switch ($r.Status) { 'COLLECTED-VALID' { 10 } 'COLLECTED-REJECTED' { 11 } default { 14 } }
} catch {
    Write-Output (ConvertTo-FsPrintable "REFUSED/ERROR: $($_.Exception.Message)")
    $ctx = $script:FsLastCtx
    if (-not $started -or $null -eq $ctx) { Write-Output 'RECOVERY: nothing was sent to the device by this run'; $exit = 20 }
    else {
        Write-Output (ConvertTo-FsPrintable "SENT:   $(@($ctx.Sent) -join ' | ')")
        Write-Output 'RECOVERY: fs-done NOT sent (collector error): the PID 1 deadline reboots the device (T0 + 200 s)'
        $exit = 70
    }
}
exit $exit
