# FrameShift N1 collector (Windows PowerShell 5.1, no modules). One session for one N1 image (devices/quest3/n1/: the
# K1a kernel + the K1a PID 1 with NCM as a second gadget function; runner fs-n1, FSB1 exp=n1; the transfer-test
# responder /bin/fs-xfer). An adapted copy of fs-collect-k1a.ps1 (not edited); the differences:
#   - the stage: verb fs-n1 (a 32-hex challenge), exp n1, steps kernel,mem,modules,net,xfer,log, RunnerWorstSec 126
#     (n1/fs-n1.sh; n1/tools/check-bounds-n1.py), the device runner start limit T0 + 74 s;
#   - THE PC SIDE OF THE NCM LINK: before the ACM engine runs, a background runspace (fs-xfer-n1.ps1 Start-FsN1XferJob)
#     looks for THIS attempt's network adapter (descending from USB\VID_1D6B&PID_0104\FS-<nonce>; at most 60 s:
#     bounded enumeration; the timeline is recorded), then retries ONE outbound TCP session to
#     [fe80::<nonce>%<ifIndex>]:47201 (refused until the runner's xfer step listens), moves 8 MiB each way and checks
#     the hashes; adapter wait, connects and the session itself end at the host give-up (BootStartUtc + 200 - 15 s)
#     at the latest (per-call socket timeouts are capped by that deadline). The ACM engine (the pinned
#     fs-collect.ps1: fs-verify, fs-ack, fs-status, fs-n1 once, the gated fs-done) runs unchanged meanwhile; the
#     runspace is waited for (bounded) afterwards and the collector writes its result as xfer.json into the output
#     directory;
#   - N1 r3 (devices/quest3/n1/CHANGES-r3.md; the r2 live refusal of J-234): the output directory must be NEW. Only the
#     engine creates it (fs-collect.ps1 New-FsCapture, which refuses an existing one); this script never does, and the
#     background runspace writes no file (r2 created the directory here for the runspace, so the engine refused every
#     live run before anything was sent). collect.json also records the SHA-256 of the three host files that ran
#     (HostTools: the provenance the N1 order gate checks for the one N1 r3 attempt, fs-n1-units.ps1);
#   - the replay CLI takes -N1ReplayXfer <xfer.json> (a fixture's PC side, e.g. the QEMU harness's), copied as is.
# The runspace opens no listener, changes no adapter, driver, firewall or network setting and installs nothing.
#
# THE RUNNER START GATE (T0 + 74 s: the device's own time refusal): the engine sends the runner only if
#   (host give-up) - now >= RunnerWorstSec + RunnerMarginSec, i.e. no later than BootStartUtc + 200 - 15 - 126 - 5 =
#   BootStartUtc + 54 s <= T0 + 54 s < T0 + 74 s. A later start is not sent: INCONCLUSIVE, fs-done recovers at once.
#
# LIVE (only after the Chair's ruling on the N1 package and the PM's sign-off; never run by fixtures):
#   fs-collect-n1.ps1 -N1Port COM7 -N1Nonce <16 hex> -N1BootStartUtc <observe.json BootStartUtc> [-N1HandoffUtc <...>] -N1OutDir <new dir>
# REPLAY (offline): fs-collect-n1.ps1 -N1Replay <capture.raw> [-N1ReplayIndex <idx>] [-N1ReplayXfer <xfer.json>] -N1OutDir <new dir>
# Exit: 10 record collected, FSB1-valid; 11 collected, FSB1 rejected; 14 INCONCLUSIVE; 15 collect.json not written (no
#   result: nothing to classify, whatever the status); 20 refused to start (nothing sent); 70 internal error. The N1
#   verdict is fs-classify-n1.ps1's (it also needs xfer.json).
[CmdletBinding()]
param(
    [string]$N1Port = '', [string]$N1Nonce = '', [string]$N1OutDir = '',
    [string]$N1Replay = '', [string]$N1ReplayIndex = '', [string]$N1ReplayXfer = '',
    [string]$N1BootStartUtc = '', [string]$N1HandoffUtc = '',
    [int]$N1HostMarginSec = 15,
    [int]$N1PollMs = 50,
    [string]$N1ReplayKernel = '', [string]$N1ReplayPid1 = '', [int]$N1ReplayGiveUpSec = 0
)
$script:FsN1Args = @{} + $PSBoundParameters
$script:FsN1Invocation = $MyInvocation.InvocationName
$script:FsN1Defaults = @{ N1Port = ''; N1Nonce = ''; N1OutDir = ''; N1Replay = ''; N1ReplayIndex = ''; N1ReplayXfer = ''; N1BootStartUtc = ''; N1HandoffUtc = ''
                          N1HostMarginSec = 15; N1PollMs = 50; N1ReplayKernel = ''; N1ReplayPid1 = ''; N1ReplayGiveUpSec = 0 }
function Get-FsN1Arg { param([string]$Name)
    if ($script:FsN1Args.ContainsKey($Name)) { return $script:FsN1Args[$Name] }
    return $script:FsN1Defaults[$Name]
}
. (Join-Path $PSScriptRoot 'fs-collect.ps1')        # pinned; returns early when dot-sourced (its param block binds here: never read below)
. (Join-Path $PSScriptRoot 'fs-xfer-n1.ps1')        # the PC side of the NCM link
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:FsN1Spec = @{
    Verb = 'fs-n1'; Refusal = 'FSDE1'; Exp = 'n1'
    Steps = @('kernel', 'mem', 'modules', 'net', 'xfer', 'log')
    DeviceDeadlineSec = 200; AckWindowSec = 150                    # n1/init.sh DEADLINE, ACK_WINDOW (= K1a)
    RunnerWorstSec = 126; RunnerMarginSec = 5                      # n1/fs-n1.sh RUNNER_WORST
    DeviceRunnerStartLimitSec = 74                                 # T0 + 200 - 126: the device's own `time` refusal
    Kernel = '5.10.246-gdbc2bc83a2b6'; Pid1 = '/bin/busybox,sh,/init'
    AckStatusTries = 2
    AdapterWaitSec = 60                                            # the PC's bounded wait for this attempt's NCM adapter
}
$script:FsCmdSpec['fs-n1'] = '^[0-9a-f]{32}\z'

function New-FsN1Cfg {
    param([Parameter(Mandatory)][string]$Nonce, [long]$GiveUpMs = -1, [long]$AckGiveUpMs = -1, $Timing = $null, [int]$HostMarginSec = 15)
    $sp = $script:FsN1Spec
    $c = New-FsCollectCfg -Nonce $Nonce -Stage '3b' -Exp $sp.Exp -Steps $sp.Steps -DeviceDeadlineSec $sp.DeviceDeadlineSec -AckWindowSec $sp.AckWindowSec `
        -Kernel $sp.Kernel -Pid1 $sp.Pid1 -PreDoneMs 0 -DisplayCueMs 0 -AckStatusTries $sp.AckStatusTries -GiveUpMs $GiveUpMs -AckGiveUpMs $AckGiveUpMs -Timing $Timing
    $c.Stage = 'n1'; $c.RunVerb = $sp.Verb; $c.RefusalTag = $sp.Refusal
    $c.RunnerWorstSec = $sp.RunnerWorstSec; $c.RunnerMarginSec = $sp.RunnerMarginSec
    $c.Beep1Ms = 0; $c.Beep2Ms = 0; $c.PreDoneMs = 0; $c.DisplayCueMs = 0
    if ($GiveUpMs -lt 0) { $c.GiveUpMs = [long](($sp.DeviceDeadlineSec - $HostMarginSec) * 1000) }
    if ($AckGiveUpMs -lt 0) { $c.AckGiveUpMs = [long](($sp.AckWindowSec - $HostMarginSec) * 1000) }
    $c.RecordTimeoutMs = [long](($sp.RunnerWorstSec + $sp.RunnerMarginSec) * 1000)
    $c.RunnerStartLimitSec = $sp.DeviceDeadlineSec - $HostMarginSec - $sp.RunnerWorstSec - $sp.RunnerMarginSec
    if ($c.RunnerStartLimitSec -gt $sp.DeviceRunnerStartLimitSec) { throw "internal: the host runner start limit $($c.RunnerStartLimitSec) s exceeds T0 + $($sp.DeviceRunnerStartLimitSec) s" }
    $c
}

function Get-FsN1ReplayTokens {
    param($Index)
    $tk = @{ V = $null; A = $null; C = $null }
    foreach ($w in $Index.W) {
        if ($w.Text -cmatch '^fs-verify ([0-9a-f]{32})\z' -and -not $tk.V) { $tk.V = $Matches[1] }
        elseif ($w.Text -cmatch '^fs-ack ([0-9a-f]{16})\z' -and -not $tk.A) { $tk.A = $Matches[1] }
        elseif ($w.Text -cmatch '^fs-n1 ([0-9a-f]{32})\z' -and -not $tk.C) { $tk.C = $Matches[1] }
    }
    if (-not $tk.V) { $tk.V = New-FsHex 16 }; if (-not $tk.A) { $tk.A = New-FsHex 8 }; if (-not $tk.C) { $tk.C = New-FsHex 16 }
    $tk
}

# N1 r3: the collector (not the runspace) writes the PC side's result, once, into the directory the ENGINE created (its
# capture index exists: never a directory this run did not make), never over an existing file, and never throws (review
# B MAJOR-1: a failed xfer.json write must not lose collect.json). Returns @{ File; Note }.
function Save-FsN1XferResult($X, [string]$OutDir) {
    try {
        if ($null -eq $X) { return [pscustomobject]@{ File = $null; Note = 'no xfer.json: the PC-side session returned no result' } }
        if (-not $OutDir -or -not (Test-Path -LiteralPath (Join-Path $OutDir 'capture.raw.idx') -PathType Leaf)) { return [pscustomobject]@{ File = $null; Note = "xfer.json not written: $OutDir was not created by the engine (no capture index)" } }
        $p = Join-Path $OutDir 'xfer.json'
        if (Test-Path -LiteralPath $p) { return [pscustomobject]@{ File = $null; Note = "xfer.json not written: $p already exists" } }
        Save-FsN1XferJson $X $p
        [pscustomobject]@{ File = $p; Note = $p }
    } catch { [pscustomobject]@{ File = $null; Note = "xfer.json not written: $($_.Exception.Message)" } }
}
# N1 r3: the SHA-256 of the host files that run (collect.json HostTools)
function Get-FsN1HostTools {
    $f = { param($n) Get-FsSha256Hex ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $n))) }
    [ordered]@{ Collector = (& $f 'fs-collect-n1.ps1'); XferLib = (& $f 'fs-xfer-n1.ps1'); Engine = (& $f 'fs-collect.ps1'); Native = (& $f 'fs-native.ps1')
                Proto = (& $f '..\stage1\fs-proto.ps1'); Fsb1 = (& $f '..\common\host\fsb1.ps1') }
}

function Invoke-FsN1Replay {
    param([Parameter(Mandatory)][string]$RawPath, [string]$IndexPath, [string]$XferPath = '', [Parameter(Mandatory)][string]$OutDir, [int]$PollMs = 50, [int]$HostMarginSec = 15,
          [string]$Kernel = '', [string]$Pid1 = '', [int]$GiveUpSec = 0)
    if (-not $IndexPath) { $IndexPath = "$RawPath.idx" }
    [byte[]]$raw = [IO.File]::ReadAllBytes($RawPath)
    $ix = Read-FsCaptureIndex -Path $IndexPath -RawLength $raw.Length
    $cfg = New-FsN1Cfg -Nonce $ix.Nonce -HostMarginSec $HostMarginSec
    $fo = [ordered]@{}
    if ($Kernel) { if ($Kernel -cnotmatch '^[0-9A-Za-z._+-]{1,64}\z') { throw 'refused: bad -N1ReplayKernel' }; $cfg.Kernel = $Kernel; $fo.Kernel = $Kernel }
    if ($Pid1) { if ($Pid1 -cnotmatch '^[0-9A-Za-z._/,+-]{1,128}\z') { throw 'refused: bad -N1ReplayPid1' }; $cfg.Pid1 = $Pid1; $fo.Pid1 = $Pid1 }
    if ($GiveUpSec -gt 0) { $cfg.GiveUpMs = [long]$GiveUpSec * 1000; $fo.GiveUpSec = $GiveUpSec }
    $t = New-FsReplayTransport -Raw $raw -Index $ix -PollMs $PollMs
    $r = Invoke-FsCollectRun -Transport $t -OutDir $OutDir -Tokens (Get-FsN1ReplayTokens $ix) -Cfg $cfg -Mode 'replay'
    $r | Add-Member NoteProperty ReplaySource ([ordered]@{ Raw = $RawPath; Sha256 = (Get-FsSha256Hex $raw); Index = $IndexPath; Xfer = $(if ($XferPath) { $XferPath } else { $null }) })
    [byte[]]$re = [IO.File]::ReadAllBytes($r.Capture.Path)
    $prefixOk = $re.Length -le $raw.Length
    if ($prefixOk -and $re.Length -gt 0) { $src = New-Object byte[] $re.Length; [Array]::Copy($raw, $src, $re.Length); $prefixOk = ([FsHostNative]::DiffIndices($src, $re).Length -eq 0) }
    $r.Replay.RecaptureIsSourcePrefix = $prefixOk
    $r | Add-Member NoteProperty RunnerStartLimitSec $cfg.RunnerStartLimitSec
    $r | Add-Member NoteProperty FixtureOverrides $(if ($fo.Count) { $fo } else { $null })
    if ($XferPath) { Copy-Item -LiteralPath $XferPath -Destination (Join-Path $OutDir 'xfer.json') }
    $r
}

# ------------------------------------------------------------------ CLI -----
if ($script:FsN1Invocation -eq '.') { return }
$exit = 70; $r = $null; $started = $false; $job = $null; $OutDirK = ''
try {
    $OutDirK = Get-FsN1Arg 'N1OutDir'
    if (-not $OutDirK) { throw 'refused: -N1OutDir is required (a new directory)' }
    $hostTools = Get-FsN1HostTools
    $margin = [int](Get-FsN1Arg 'N1HostMarginSec'); $poll = [int](Get-FsN1Arg 'N1PollMs')
    if ($margin -ne 15) { throw 'refused: -N1HostMarginSec is fixed at 15 for N1 (the runner start gate is derived from it)' }
    $rp = Get-FsN1Arg 'N1Replay'
    if ($rp) {
        if (Get-FsN1Arg 'N1Port') { throw 'refused: -N1Port and -N1Replay are exclusive' }
        $started = $true
        $r = Invoke-FsN1Replay -RawPath $rp -IndexPath (Get-FsN1Arg 'N1ReplayIndex') -XferPath (Get-FsN1Arg 'N1ReplayXfer') -OutDir $OutDirK -PollMs $poll -HostMarginSec $margin `
            -Kernel (Get-FsN1Arg 'N1ReplayKernel') -Pid1 (Get-FsN1Arg 'N1ReplayPid1') -GiveUpSec ([int](Get-FsN1Arg 'N1ReplayGiveUpSec'))
        if (@($r.Replay.Divergence).Count) { Write-Output (ConvertTo-FsPrintable "REPLAY DIVERGENCE: $(@($r.Replay.Divergence) -join '; ')") }
    } else {
        if ((Get-FsN1Arg 'N1ReplayKernel') -or (Get-FsN1Arg 'N1ReplayPid1') -or [int](Get-FsN1Arg 'N1ReplayGiveUpSec') -or (Get-FsN1Arg 'N1ReplayXfer')) { throw 'refused: the -N1Replay* options are replay fixtures only' }
        # N1 r3: a new directory, checked before anything else; the engine creates it (never this script)
        if (Test-Path -LiteralPath $OutDirK) { throw "refused: output directory already exists: $OutDirK (-N1OutDir must be a new directory; the engine creates it)" }
        $port = Get-FsN1Arg 'N1Port'; $nonce = Get-FsN1Arg 'N1Nonce'
        if ($port -cnotmatch '^COM[0-9]{1,3}\z') { throw 'refused: -N1Port must be given explicitly as COMn (never chosen automatically)' }
        if ($nonce -cnotmatch '^[0-9a-f]{16}\z') { throw 'refused: -N1Nonce must be the image nonce (16 lowercase hex)' }
        $bs = Get-FsN1Arg 'N1BootStartUtc'
        if (-not $bs) { throw 'refused: -N1BootStartUtc (observe.json BootStartUtc, taken just before fastboot boot) is required: it is the budget origin' }
        $fmts = [string[]](@("yyyy-MM-dd'T'HH:mm:ss'Z'") + @(1..7 | ForEach-Object { "yyyy-MM-dd'T'HH:mm:ss." + ('f' * $_) + "'Z'" }))
        $parseU = { param([string]$v)
            if ($v -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z\z') { throw "refused: '$v' is not a UTC time yyyy-MM-ddTHH:mm:ss[.fffffff]Z" }
            [DateTime]::ParseExact($v, $fmts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }
        $origin = & $parseU $bs
        $hoEv = $null; $ho = Get-FsN1Arg 'N1HandoffUtc'
        if ($ho) { $hoEv = & $parseU $ho; if ($hoEv -lt $origin) { throw 'refused: -N1HandoffUtc precedes -N1BootStartUtc (inconsistent observer times)' } }
        $cliUtc = [DateTime]::UtcNow
        if ($origin -gt $cliUtc) { throw "refused: -N1BootStartUtc $($origin.ToString('o')) is later than now (clock step or bad input)" }
        $sp = $script:FsN1Spec
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
                              PreparationMs = [long]($nowU - $cliUtc).TotalMilliseconds; RemainMsAtConversion = $cv.RemainMs; AckRemainMsAtConversion = $cv.AckRemainMs
                              XferWindowEndUtc = $dl.GiveUpUtc.ToString('o'); XferAdapterWaitSec = $sp.AdapterWaitSec }
        $cfg = New-FsN1Cfg -Nonce $nonce -GiveUpMs $cv.GiveUpMs -AckGiveUpMs $cv.AckGiveUpMs -Timing $timing -HostMarginSec $margin
        Write-Output "HOST GIVE-UP: $($dl.GiveUpUtc.ToString('o')); the runner is sent only before $($origin.AddSeconds($limitSec).ToString('o')) (BootStartUtc + $limitSec s <= T0 + $($sp.DeviceRunnerStartLimitSec) s); the NCM transfer client runs in the background until the give-up at the latest"
        # the PC side of the NCM link, in the background (bounded: the host give-up at the latest), started only now that
        # every start refusal has passed (review m6)
        $job = Start-FsN1XferJob -Nonce $nonce -Chal $tokens.C -WindowEndUtc $dl.GiveUpUtc -AdapterWaitSec $sp.AdapterWaitSec
        $started = $true
        $r = Invoke-FsCollectRun -Transport $t -OutDir $OutDirK -Tokens $tokens -Cfg $cfg -Mode 'live' -PortName $port
    }
    if ($null -ne $job) {
        # the ACM session is over: a record means the device's xfer step (and so its listener) has ended; no record means
        # it will not come. Stop any further adapter wait or connect retry; a session already connected runs to its end
        # (bounded by its own timeouts); wait for it at most 45 s.
        $job.Sync.Stop = $true
        $w = Wait-FsN1XferJob $job 45000; $job = $null
        $xr = if ($null -ne $w.Result -and $w.Result.PSObject.Properties['Result']) { [string]$w.Result.Result } else { 'none' }
        $xs = Save-FsN1XferResult $w.Result $OutDirK
        Write-Output (ConvertTo-FsPrintable "NCM TRANSFER (PC side): $xr; completed $($w.Completed)$(if (@($w.Errors).Count) { '; errors: ' + (@($w.Errors) -join ' | ') }) -> $($xs.Note)")
        $r | Add-Member NoteProperty Xfer ([ordered]@{ Result = $xr; Completed = $w.Completed; Errors = @($w.Errors); File = $xs.File })
    }
    $r | Add-Member NoteProperty HostTools $hostTools
    $cjSaved = $true
    try { Save-FsCollectJson -Result $r -Path (Join-Path $OutDirK 'collect.json') }
    catch { $cjSaved = $false; Write-Output (ConvertTo-FsPrintable "COLLECT.JSON NOT WRITTEN: $($_.Exception.Message)") }
    Write-FsSummary $r
    $exit = switch ($r.Status) { 'COLLECTED-VALID' { 10 } 'COLLECTED-REJECTED' { 11 } default { 14 } }
    # N1 r3 delta review: without collect.json there is nothing to classify, so the run never exits 10/11/14 (exit 15)
    if (-not $cjSaved) { Write-Output "NO RESULT: collect.json was not written (status $($r.Status)): this run cannot be classified; the capture files stay as written (exit 15)"; $exit = 15 }
} catch {
    Write-Output (ConvertTo-FsPrintable "REFUSED/ERROR: $($_.Exception.Message)")
    if ($null -ne $job) {
        try { $job.Sync.Stop = $true; $wj = Wait-FsN1XferJob $job 30000; $xs = Save-FsN1XferResult $wj.Result $OutDirK
              Write-Output (ConvertTo-FsPrintable "NCM TRANSFER (PC side, after the error): $(if ($null -ne $wj.Result -and $wj.Result.PSObject.Properties['Result']) { [string]$wj.Result.Result } else { 'none' }) -> $($xs.Note)") } catch { }
    }
    $ctx = $script:FsLastCtx
    if (-not $started -or $null -eq $ctx) { Write-Output 'RECOVERY: nothing was sent to the device by this run (the ACM console)'; $exit = 20 }
    else {
        Write-Output (ConvertTo-FsPrintable "SENT:   $(@($ctx.Sent) -join ' | ')")
        Write-Output 'RECOVERY: fs-done NOT sent (collector error): the PID 1 deadline reboots the device (T0 + 200 s)'
        $exit = 70
    }
}
exit $exit
