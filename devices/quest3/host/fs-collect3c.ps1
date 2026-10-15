# FrameShift stage-3c serial collector: the interactive, per-phase session (Windows PowerShell 5.1, no modules).
# Design: devices/quest3/stage3c/DESIGN.md revision 3 (sections 4, 5, 8, 9, 10). Stage-3b behaviour is
# untouched: the pinned fs-collect.ps1 is DOT-SOURCED (it returns early when dot-sourced) and never edited.
#
# LIVE (only with the PM's sign-off; never run by fixtures; started by fs-observe3c.ps1 -ThenCollect):
#   fs-collect3c.ps1 -S3cPort COM7 -S3cNonce <16 hex> -S3cBootStartUtc <observe.json BootStartUtc>
#                    [-S3cHandoffUtc <observe.json HandoffUtc: evidence only>] -S3cOutDir <new dir>
# REPLAY (offline; a capture plus its index through the same session code):
#   fs-collect3c.ps1 -S3cReplay <capture.raw> [-S3cReplayIndex <idx>] -S3cOutDir <new dir> [-S3cKeyScript <file>] [-S3cReplayPin <64 hex>]
#   (-S3cReplayPin, replay only: the fs-pattern digest the p0 integrity gate expects; default the built-in v0.6 pin.
#    The synthetic fixtures carry the fixture digest f6a9c3e2...1100.)
# REHEARSAL (SIGNOFF-3c A, the Q7 go/no-go): a replay paced in real time, with the console keys, the real
#   sounds and banners; prints the time the run-1 and run-2 answers took (behind the s key, as live):
#   fs-collect3c.ps1 -S3cReplay devices\quest3\host\fixtures\stage3c\replay\garbled-r3\capture.raw -S3cOutDir <new dir> -S3cRehearsal
#                    -S3cReplayPin f6a9c3e2b1d0a4958877665544332211ffeeddccbbaa99887766554433221100
# Build review (2026-10-12): p0 integrity gate before any lit phase (MAJOR-1); Ctrl+C = x, QuickEdit off, every answer
#   on disk at once (MAJOR-2, MINOR-9); `n` during a phase = x (MINOR-4); the machine summary goes to summary.txt and is
#   shown only on the s key, after the notes (MINOR-7); "fs-done NOT sent" only when it was not (MINOR-10); a red SAFE
#   FINISH banner (NIT a); PHASE_WORST 23/38/47/39 and G 34/68/82/64 (device MINOR-2/NIT-3).
# Q7 fallback (DESIGN 15 Q7, applied after the PM rehearsal 2026-10-12: r1 16.4 s + r2 50.2 s = 66.6 s, NO-GO): after a
#   VALID run 2 the gap is given the run-3 rule (DESIGN 5.8 rules 1-4) as -BarsQ7; on that path the bar counts are not
#   asked (FSR2 NOT_ASKED; the r2 phase record's Q7Fallback names the items: "not asked (Q7 fallback)").
# Exit (no verdict code is 0, 1 or 2): 10 every phase sent has a VALID record, 11 a phase record was
#   rejected or refused (FSXE1), 14 INCONCLUSIVE (a phase without a complete record, or the capture is
#   inconsistent), 20 refused to start (nothing sent), 70 internal error. The verdicts are fs-classify3c.ps1's.
#
# ---- M4: the dot-source scope hazard (DESIGN 8.1, R-A M4) ---------------------------------------------
# A dot-sourced script binds ITS param() block in the caller's scope. Therefore:
#   1. every parameter of this file is named S3c* and collides with none of fs-collect.ps1's
#      (Port, Nonce, OutDir, Replay, ReplayIndex, BootStartUtc, HandoffUtc, Stage, ...);
#   2. the bound arguments are snapshotted BEFORE the dot-source ($script:Fs3cArgs) and read only from
#      that snapshot afterwards (Get-Fs3cArg), as is this script's own InvocationName;
#   3. no -Stage is ever passed to an fs-collect.ps1 function, and no variable named $Stage (or any other
#      name of fs-collect.ps1's param block) is read or assigned in the 3c host files; the stage label is
#      $script:Fs3cStageLabel = '3c' (test-host3c case 21 checks all of this).
#
# ---- copy/override list (DESIGN 8.1; R-D diffs every copy against its original) ------------------------
#   reused by call, unedited: New-FsCommand (verb table extended at run time with fs-phase), New-FsCapture,
#     New-FsRawSerialTransport, Read-FsCaptureIndex, Get-FsHostDeadlines, ConvertTo-FsTransportDeadlines,
#     Get-FsLiveStartRefusal, Get-FsRegionLines, Get-FsTailState, Get-FsRawTail, Find-FsRecordLine,
#     Find-FsFsb1End, Get-FsIncompleteState, Get-FsEchoState, Read-FsInto, Get-FsSendGate, Set-FsSettled,
#     Invoke-FsPhase (the gated fs-done and the pre-runner commands), Get-FsPhaseStop; Test-FsVerify,
#     Test-FsAck, Get-FsRecords, Get-FsGadget, New-FsHex (fs-proto.ps1); Test-Fsb1Record (fsb1.ps1).
#   Invoke-Fs3cPhase = COPY of Invoke-FsPhase. Differences: -OnPoll (a scriptblock run every loop
#     iteration of the completion and prompt waits: FSPM1 markers -> banners/sounds, keys -> abort noted /
#     discarded and logged) and -NextWake (the idle target is capped by the next scripted key time, so a
#     replay polls keys at their time; live, the transport's Idle is <= PollMs anyway). Nothing else.
#   Invoke-Fs3cSession: the pre-runner sequence of Invoke-FsCollect (initial drain, fs-verify, fs-ack,
#     fs-status with the ack-window cap PhaseCapMs, the foreign-ack stop) COPIED verbatim; then the
#     per-phase loop (new); then the gated fs-done block COPIED, including `PhaseCapMs = $null` before
#     fs-done (NIT7); the 3a/3b beep-1/beep-2 pause and the 3b report text are DROPPED (replaced by the
#     DESIGN 8.2 prompts). The 3a/3b display cue is replaced by the LOOK cue after p0.
#   New-Fs3cCfg: COPY of New-FsCollectCfg with the stage-3c fields (per-phase Exp/Steps/PHASE_WORST,
#     DoneReserve, IDLE_S, guards) and the same key names for the reused functions; no -Stage, no
#     $script:FsStageSpec (the pinned table is not edited).
#   Invoke-Fs3cRun REPLACES Invoke-FsCollectRun: the capture-consistency checks are copied; the FSB1
#     validation is per phase slice (DESIGN 5.6), up to 4 records; the slices are re-derived from the
#     file on disk and must equal the session's.
#   Get-Fs3cReplayTokens REPLACES Get-FsReplayTokens: one challenge per `fs-phase <ph> <chal> <prev>`
#     write; <prev> is never taken from the capture: the session recomputes it from the replayed records,
#     and a different recorded <prev> is a replay divergence (and is reported).
#   New-Fs3cReplayTransport: COPY of New-FsReplayTransport. Differences: each recorded segment after a
#     host write is re-anchored at the time the collector actually makes that write (the device's response
#     times stay relative to the send, so prompts of any length can be replayed), and -Paced (rehearsal)
#     runs it on the real clock.
#   CLI block: COPIED (BootStartUtc parse, future-origin refusal, Get-FsHostDeadlines, the fail-fast
#     refusal, gadget/port checks, the fresh conversion AFTER the preparation) with DEADLINE 200 and
#     ACK_WINDOW 150 (stage3c/init.sh) and the S3c parameter names. The sounds are generated and loaded
#     during the preparation, i.e. before the conversion.
[CmdletBinding()]
param(
    [string]$S3cPort = '', [string]$S3cNonce = '', [string]$S3cOutDir = '',
    [string]$S3cReplay = '', [string]$S3cReplayIndex = '', [string]$S3cKeyScript = '',
    [string]$S3cBootStartUtc = '',          # live, REQUIRED: the budget origin = observe.json BootStartUtc (FS-R-007 B1)
    [string]$S3cHandoffUtc = '',            # live, optional: evidence only, never a budget origin
    [int]$S3cHostMarginSec = 15,
    [string]$S3cKernel = '5.10.198-01402-g1c5986fe21ee',
    [string]$S3cPid1 = '/bin/busybox,sh,/init',
    [int]$S3cPollMs = 50,
    [long]$S3cGiveUpMs = -1,                # replay only: the give-up on the replay clock (fixtures, guard tests)
    [switch]$S3cRehearsal,
    [switch]$S3cNoDone,
    [string]$S3cReplayPin = '',            # replay only: the fs-pattern digest of the p0 integrity gate (default the built-in v0.6 pin)
    [switch]$S3cParamEcho                   # test-host3c case 21: print the snapshot and the live S3c* values after the dot-source, then exit 0
)
# M4 rule 2: snapshot the arguments and this script's invocation BEFORE the dot-source
$script:Fs3cArgs = @{} + $PSBoundParameters
$script:Fs3cInvocation = $MyInvocation.InvocationName
$script:Fs3cStageLabel = '3c'
$script:Fs3cDefaults = @{ S3cPort = ''; S3cNonce = ''; S3cOutDir = ''; S3cReplay = ''; S3cReplayIndex = ''; S3cKeyScript = ''; S3cBootStartUtc = ''; S3cHandoffUtc = ''
                          S3cHostMarginSec = 15; S3cKernel = '5.10.198-01402-g1c5986fe21ee'; S3cPid1 = '/bin/busybox,sh,/init'; S3cPollMs = 50; S3cGiveUpMs = [long]-1
                          S3cRehearsal = $false; S3cNoDone = $false; S3cParamEcho = $false; S3cReplayPin = '' }
function Get-Fs3cArg { param([string]$Name)
    if ($script:Fs3cArgs.ContainsKey($Name)) { $v = $script:Fs3cArgs[$Name]; if ($v -is [System.Management.Automation.SwitchParameter]) { return [bool]$v }; return $v }
    return $script:Fs3cDefaults[$Name]
}
. (Join-Path $PSScriptRoot 'fs-collect.ps1')        # pinned; returns early when dot-sourced (binds its own param block here: never read by 3c code)
. (Join-Path $PSScriptRoot 'fs-classify3c.ps1')     # the stage-3c protocol library (exp/steps, FSPM1, FSXE1, run facts, the run-3 rule)
. (Join-Path $PSScriptRoot 'fs-session3c.ps1')      # banners, sounds, keys, prompts
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# DESIGN 5.1: the one new verb, added at run time (the pinned table in fs-collect.ps1 is not edited)
$script:FsCmdSpec['fs-phase'] = '^(p0|r1|r2|r3) [0-9a-f]{32} [0-9a-f]{16}\z'
$script:Fs3cZero16 = '0000000000000000'

# ------------------------------------------------------------------ config ----
# Copy of New-FsCollectCfg with the stage-3c fields (DESIGN 9.1, 9.3). G_k = PHASE_WORST_k + RunnerMargin 5
# + PostMin_k + DoneReserve 3; PostMin = banner/sound 2 s + H_k (p0: the 3 s cue, no banner term).
function New-Fs3cCfg {
    param([string]$NonceX, [long]$GiveUpMsX = -1, [long]$AckGiveUpMsX = -1, [string]$KernelX = '5.10.198-01402-g1c5986fe21ee',
          [string]$Pid1X = '/bin/busybox,sh,/init', $TimingX = $null, [int]$PollMsX = 50, [bool]$NoDoneX = $false)
    $c = @{ Nonce = $NonceX; Stage = $script:Fs3cStageLabel; RunVerb = 'fs-phase'; RefusalTag = 'FSXE1'; DeviceDeadlineSec = 200; AckWindowSec = 150
            Kernel = $KernelX; Pid1 = $Pid1X; StepTimeoutMs = 10000; PromptWaitMs = 3000; AckSettleMs = 2500; AckStatusTries = 2; InitialDrainMs = 1000
            NoDone = $NoDoneX; PromptSettleMs = 150; Timing = $TimingX; PollMs = $PollMsX
            RunnerMarginSec = 5; DoneReserveSec = 3; BannerSec = 2; IdleSec = 120; GapCapSec = 110; PromptTimeoutSec = 30; CueMs = 3000; LayoutMinSec = 10
            PhaseWorstSec = @{ p0 = 23; r1 = 38; r2 = 47; r3 = 39 }; HumanSec = @{ p0 = 3; r1 = 20; r2 = 25; r3 = 15 }   # build review: TQ 3 s, END pass, cold repetition
            Exp = $script:S3cExp; Steps = $script:S3cSteps; PatternPin = $script:S3cPatternPin }
    if ($GiveUpMsX -lt 0) { $GiveUpMsX = [long](($c.DeviceDeadlineSec - 15) * 1000) }
    if ($AckGiveUpMsX -lt 0) { $AckGiveUpMsX = [long](($c.AckWindowSec - 15) * 1000) }
    $c.GiveUpMs = $GiveUpMsX; $c.AckGiveUpMs = $AckGiveUpMsX
    $g = @{}
    foreach ($ph in 'p0', 'r1', 'r2', 'r3') {
        $post = if ($ph -ceq 'p0') { $c.HumanSec[$ph] } else { $c.BannerSec + $c.HumanSec[$ph] }
        $g[$ph] = $c.PhaseWorstSec[$ph] + $c.RunnerMarginSec + $post + $c.DoneReserveSec
    }
    $c.GuardSec = $g       # p0 34, r1 68, r2 82, r3 64
    $c
}
# The guard immediately before each fs-phase (DESIGN 9.3), on the monotonic transport clock.
function Test-Fs3cGuard {
    param([Parameter(Mandatory)][hashtable]$Cfg, [Parameter(Mandatory)][string]$PhX, [Parameter(Mandatory)][long]$NowMs)
    $need = [long]$Cfg.GuardSec[$PhX] * 1000; $left = $Cfg.GiveUpMs - $NowMs
    $why = if ($left -ge $need) { 'ok' } else { "$([long][Math]::Floor($left / 1000)) s left before the host give-up; $PhX needs G = $($Cfg.GuardSec[$PhX]) s (PHASE_WORST $($Cfg.PhaseWorstSec[$PhX]) + margin $($Cfg.RunnerMarginSec) + post-phase minimum + DoneReserve $($Cfg.DoneReserveSec))" }
    [pscustomobject]@{ Ok = ($left -ge $need); NeedMs = $need; LeftMs = $left; Why = $why }
}

# Build review MAJOR-1: the integrity of the pattern program, from p0's VALID record, BEFORE any lit phase. Only a
# MEASURED digest equal to the pin lets run 1 be requested (the classifier's p0 rules; a tool fault, an unparseable
# hash step, a mismatch or no pin: RUN 1 NOT POSSIBLE (integrity), then fs-done). Returns @{ Ok; Class; Why }.
function Get-Fs3cP0Integrity {
    param($StepList, [string]$Pin)
    $h = @($StepList)[0]
    if ($null -eq $h) { return [pscustomobject]@{ Ok = $false; Class = 'NO HASH STEP'; Why = 'the p0 record has no hash step' } }
    if (-not $Pin) { return [pscustomobject]@{ Ok = $false; Class = 'NO PIN'; Why = 'no fs-pattern pin: integrity unmeasured' } }
    $tf = Test-FsS2ToolFault $h
    if ($null -ne $tf) { return [pscustomobject]@{ Ok = $false; Class = 'TOOL FAULT'; Why = "hash step: $tf" } }
    $hc = Get-FsS3HashClass $h $Pin
    if ($hc.Class -ceq 'MEASURED' -and -not $hc.Mismatch) { return [pscustomobject]@{ Ok = $true; Class = 'MEASURED'; Why = $hc.Notes } }
    if ($hc.Class -ceq 'MEASURED') { return [pscustomobject]@{ Ok = $false; Class = 'INTEGRITY FAULT'; Why = $hc.Notes } }
    [pscustomobject]@{ Ok = $false; Class = [string]$hc.Class; Why = [string]$hc.Notes }
}

# -------------------------------------------------------- Invoke-Fs3cPhase ----
# COPY of Invoke-FsPhase (fs-collect.ps1). Differences (only): -OnPoll, -NextWake (see the header).
function Invoke-Fs3cPhase {
    param($Ctx, [string]$Verb, [string]$Arg = '', [int]$TimeoutMs, [scriptblock]$Detect, [string]$Tag, [switch]$NoPrompt,
          [scriptblock]$OnPoll = $null, [scriptblock]$NextWake = $null)
    $cmd = New-FsCommand -Verb $Verb -Arg $Arg
    $ph = [ordered]@{ Verb = $Verb; Command = $cmd; SendOffset = $null; SendMs = $null; DeadlineMs = $null; HostDeadline = $false
                      State = $null; Gate = $null; Completion = $null; CompletedMs = $null; Prompt = $null; Echo = $null }
    $why = Get-FsSendGate $Ctx
    if ($null -ne $why) { $ph.State = 'not-sent'; $ph.Gate = $why; return [pscustomobject]$ph }
    $Ctx.SettledLen = $null                                    # consumed by this send
    $start = $Ctx.C.Length
    $t0 = $Ctx.T.NowMs()
    try { $Ctx.T.WriteBytes([System.Text.Encoding]::ASCII.GetBytes($cmd + "`n")) }
    catch { throw "write of '$cmd' failed (it may have been partly sent): $($_.Exception.Message)" }
    $Ctx.C.NoteWrite($cmd, $t0)                                # logged only after the write succeeded
    $Ctx.Sent.Add($cmd)
    $cap = $Ctx.Cfg.GiveUpMs
    if ($null -ne $Ctx.PhaseCapMs -and $Ctx.PhaseCapMs -lt $cap) { $cap = $Ctx.PhaseCapMs }
    $deadline = [Math]::Min($t0 + $TimeoutMs, $cap)
    $ph.SendOffset = $start; $ph.SendMs = $t0; $ph.DeadlineMs = $deadline; $ph.HostDeadline = ($deadline -eq $cap)
    $done = $null; $lastData = $t0
    while ($Ctx.T.NowMs() -lt $deadline) {
        if ($null -ne $OnPoll) { & $OnPoll $Ctx $start }       # 3c: markers and keys, every iteration
        if ((Read-FsInto $Ctx $deadline) -gt 0) {
            $lastData = $Ctx.T.NowMs()
            if ($null -ne $OnPoll) { & $OnPoll $Ctx $start }
            $done = & $Detect (Get-FsRegionLines ($Ctx.C.Bytes($start)))
            if ($null -ne $done) { break }
            continue
        }
        # a continuation prompt after the echo, then quiet: stop waiting early (nothing is sent either way)
        if ($Ctx.C.Length -gt $start -and (Get-FsTailState ($Ctx.C.Bytes($start))) -ceq 'continuation' -and
            $Ctx.T.NowMs() -ge $lastData + $Ctx.Cfg.PromptWaitMs) { break }
        $until = [Math]::Min($deadline, $lastData + $Ctx.Cfg.PromptWaitMs)
        if ($until -le $Ctx.T.NowMs()) { $until = $deadline }
        if ($null -ne $NextWake) { $nw = [long](& $NextWake); if ($nw -gt $Ctx.T.NowMs() -and $nw -lt $until) { $until = $nw } }   # 3c
        $Ctx.T.Idle($until)
    }
    $region = $Ctx.C.Bytes($start)
    if ($null -eq $done) {
        $ph.State = Get-FsIncompleteState -Region $region -Cmd $cmd -Tag $Tag
        $ph.Echo = Get-FsEchoState -Region $region -Cmd $cmd -Completion $null -Tag $Tag
        return [pscustomobject]$ph
    }
    $ph.State = 'complete'; $ph.Completion = $done.Line; $ph.CompletedMs = $Ctx.T.NowMs()
    $ph.Echo = Get-FsEchoState -Region $region -Cmd $cmd -Completion $done -Tag $Tag
    if ($NoPrompt) { $ph.Prompt = 'not-awaited'; return [pscustomobject]$ph }
    # The prompt must be the tail AND the line must have gone quiet for PromptSettleMs (ash writes
    # "~ # " and then ESC[6n; a prompt seen mid-write is not yet a settled state).
    $afterOff = $start + $done.End
    $pdl = [Math]::Min($ph.CompletedMs + $Ctx.Cfg.PromptWaitMs, $cap)
    $quiet = $Ctx.T.NowMs()
    while ($true) {
        if ($null -ne $OnPoll) { & $OnPoll $Ctx $start }       # 3c
        $st = Get-FsTailState ($Ctx.C.Bytes($afterOff))
        $isP = ($st -ceq 'prompt' -or $st -ceq 'continuation')
        if ($isP -and $Ctx.T.NowMs() -ge $quiet + $Ctx.Cfg.PromptSettleMs) { break }
        if ($Ctx.T.NowMs() -ge $pdl) { break }
        $until = $pdl
        if ($isP) { $until = [Math]::Min($pdl, $quiet + $Ctx.Cfg.PromptSettleMs) }
        if ((Read-FsInto $Ctx $until) -gt 0) { $quiet = $Ctx.T.NowMs() } else { $Ctx.T.Idle($until) }
    }
    $ph.Prompt = switch ($st) { 'prompt' { 'prompt' } 'continuation' { 'continuation' } default { 'missing' } }
    if ($ph.Prompt -ceq 'prompt' -and -not (Set-FsSettled $Ctx)) { $ph.Prompt = 'unexpected-prompt' }
    return [pscustomobject]$ph
}

# ------------------------------------------------------- the session ---------
$script:Fs3cRunName = @{ p0 = 'PHASE 0'; r1 = 'RUN 1'; r2 = 'RUN 2'; r3 = 'RUN 3' }
function Invoke-Fs3cSession {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)]$Capture, [Parameter(Mandatory)][hashtable]$Tokens, [Parameter(Mandatory)][hashtable]$Cfg,
          [Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Keys, [Parameter(Mandatory)]$Sound, [DateTime]$UtcBase = [DateTime]::MinValue, [long]$UtcBaseMs = 0,
          [string]$OutDirX = '')
    $ctx = [pscustomobject]@{ T = $Transport; C = $Capture; Cfg = $Cfg; Sent = (New-Object System.Collections.Generic.List[string])
                              SettledLen = $null; ExpectedPrompt = $null; LastByteMs = [long]-1; PhaseCapMs = $Cfg.AckGiveUpMs }
    $script:FsLastCtx = $ctx
    $X = New-Fs3cInteract -Ctx $ctx -Ui $Ui -Keys $Keys -Sound $Sound -UtcBase $UtcBase -UtcBaseMs $UtcBaseMs -PollMsX $Cfg.PollMs -OutDirX $OutDirX
    $res = [ordered]@{
        Schema = 'frameshift.fs-collect3c.v1'; Stage = $script:Fs3cStageLabel; RunVerb = 'fs-phase'; DeviceDeadlineSec = $Cfg.DeviceDeadlineSec
        Nonce = $Cfg.Nonce; Status = 'INCONCLUSIVE'; StopReason = $null; EndReason = $null; Phases = @(); Exchanges = @(); GiveUpMs = $Cfg.GiveUpMs
        GuardSec = $Cfg.GuardSec; PhaseWorstSec = $Cfg.PhaseWorstSec
        Verified = $false; VerifyReason = $null; VerifyRecord = $null; Kernel = $null
        AckToken = $Tokens.A; Acked = $false; AckReason = $null; Challenge = $null; Challenges = $Tokens.C
        AckGiveUpMs = $Cfg.AckGiveUpMs; Timing = $Cfg.Timing; ForeignAck = $null; R3Rule = $null
        DoneSent = $false; DoneReply = $null; Sent = $null; TransportError = $null; CaptureError = $null; Known = $false
        Readings = @(); ReadingObjs = @(); Events = @(); SoundsPlayed = @(); SoundFailures = @(); Transcript = @()
    }
    $phases = New-Object System.Collections.Generic.List[object]
    $p3 = New-Object System.Collections.Generic.List[object]
    # Known = the last phase ended with its completion record AND a settled, expected prompt.
    $st = @{ Known = $false; R2Valid = $false; R2Run = $null; R2Items = $null; EndWhy = $null; Alarm = $false }
    $s3abort = @{ Noted = $false; Ms = $null; Ph = $null }
    try {
        $null = & {   # each 'return' below ends the exchange; nothing further is sent except the gated fs-done
            $Transport.Open()
            # ---- COPIED from Invoke-FsCollect (pre-runner sequence), unchanged ----
            # 0. read what is pending, until it is quiet; never write before the first command
            $pre = $Transport.NowMs() + $Cfg.InitialDrainMs
            $hard = [Math]::Min([Math]::Min($pre + $Cfg.PromptWaitMs, $Cfg.GiveUpMs), $Cfg.AckGiveUpMs)
            while ($Transport.NowMs() -lt $hard) {
                if ($Transport.NowMs() -ge $pre -and ($ctx.LastByteMs -lt 0 -or $Transport.NowMs() -ge $ctx.LastByteMs + $Cfg.PromptSettleMs)) { break }
                $u = if ($Transport.NowMs() -lt $pre) { $pre } else { [Math]::Min($hard, $ctx.LastByteMs + $Cfg.PromptSettleMs) }
                if ((Read-FsInto $ctx $u) -eq 0) { $Transport.Idle($u) }
            }
            if ($Capture.Length -gt 0) {
                $s0 = Get-FsTailState ($Capture.Bytes(0))
                if ($s0 -ceq 'continuation') { $res.StopReason = 'pre-continuation: the shell shows a continuation prompt before anything was sent'; return }
                if ($s0 -cne 'prompt') { $res.StopReason = "pre-unknown-state: before anything was sent the tail is '$(ConvertTo-FsPrintable (Get-FsRawTail ($Capture.Bytes(0))))', not a primary prompt"; return }
                $null = Set-FsSettled $ctx
            }
            # 1. fs-verify: fresh challenge; completion = the first complete FSV1 record
            $p = Invoke-FsPhase $ctx 'fs-verify' $Tokens.V $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSV1' } -Tag 'FSV1'
            $phases.Add($p)
            if ($p.State -cne 'complete') { $res.StopReason = Get-FsPhaseStop $p; return }
            $v = Test-FsVerify -Text $p.Completion -Nonce $Cfg.Nonce -Challenge $Tokens.V -Kernel $Cfg.Kernel -Pid1 $Cfg.Pid1
            $res.VerifyReason = $v.Reason
            if (-not $v.Ok) { $res.StopReason = "fs-verify: record does not verify ($($v.Reason))"; return }
            $res.Verified = $true; $res.VerifyRecord = $p.Completion; $res.Kernel = $v.Record['kernel']
            if ($p.Prompt -cne 'prompt') { $res.StopReason = "fs-verify: completed, then prompt $($p.Prompt)"; return }
            $st.Known = $true
            # 2. fs-ack: completion = FSA1
            $st.Known = $false
            $p = Invoke-FsPhase $ctx 'fs-ack' $Tokens.A $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSA1' } -Tag 'FSA1'
            $phases.Add($p)
            if ($p.State -cne 'complete') { $res.StopReason = Get-FsPhaseStop $p; return }
            if ($p.Prompt -cne 'prompt') { $res.StopReason = "fs-ack: completed, then prompt $($p.Prompt)"; return }
            $st.Known = $true
            if ($p.Completion -cne 'FSA1 queued END') { $res.StopReason = "fs-ack: refused ($(ConvertTo-FsPrintable $p.Completion))"; return }
            # 3. fs-status until PID 1 has recorded the token (bounded; each one only through the send gate)
            for ($try = 1; $try -le $Cfg.AckStatusTries; $try++) {
                $settle = [Math]::Min([Math]::Min($Transport.NowMs() + $Cfg.AckSettleMs, $Cfg.GiveUpMs), $Cfg.AckGiveUpMs)
                while ($Transport.NowMs() -lt $settle) { if ((Read-FsInto $ctx $settle) -eq 0) { $Transport.Idle($settle) } }
                $st.Known = $false
                $p = Invoke-FsPhase $ctx 'fs-status' '' $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSS1' } -Tag 'FSS1'
                $phases.Add($p)
                if ($p.State -cne 'complete') { $res.StopReason = Get-FsPhaseStop $p; return }
                if ($p.Prompt -cne 'prompt') { $res.StopReason = "fs-status: completed, then prompt $($p.Prompt)"; return }
                $st.Known = $true
                $a = Test-FsAck -Text $p.Completion -Nonce $Cfg.Nonce -AckToken $Tokens.A
                $res.AckReason = $a.Reason
                if ($a.Ok) { $res.Acked = $true; break }
                # A foreign ack: PID 1 records only the FIRST valid ack, so another host session
                # (e.g. a stage-1 observer) is attached. Retrying cannot help; stop now (Known stays
                # true: the gated fs-done below recovers at once).
                $fr = @((Get-FsRecords -Text $p.Completion -Tag 'FSS1') | Where-Object { $_['nonce'] -ceq $Cfg.Nonce })   # (Get-FsRecords returns ONE array: unroll it)
                if ($fr.Count -and $fr[0]['acked'] -cmatch '^[0-9a-f]{1,64}\z' -and $fr[0]['acked'] -cne $Tokens.A) {
                    $res.ForeignAck = $fr[0]['acked']
                    $res.StopReason = "foreign ack: PID 1 recorded acked=$($fr[0]['acked']), not this collector's token (another host session is attached); no experiment request is sent"
                    return
                }
            }
            if (-not $res.Acked) { $res.StopReason = "ack not recorded by PID 1 after $($Cfg.AckStatusTries) fs-status ($($res.AckReason))"; return }
            $ctx.PhaseCapMs = $null                     # the ack window no longer applies once PID 1 recorded our ack
            # ---- end of the copied pre-runner sequence ----

            # ---- stage 3c: the phases (DESIGN 4, 5.7, 5.8, 8.2) ----
            $prevSha = $script:Fs3cZero16
            $s3keys = $Keys; $s3x = $X; $s3abortRef = $s3abort
            foreach ($s3ph in 'p0', 'r1', 'r2', 'r3') {
                $chal = [string]$Tokens.C[$s3ph]
                $name = $script:Fs3cRunName[$s3ph]
                $s3lit = ($s3ph -cne 'p0')
                $pr = [ordered]@{ Ph = $s3ph; Chal = $chal; Prev = $prevSha; Sent = $false; NotRunWhy = ''; GuardNeedMs = $null; GuardLeftMs = $null
                                  SendMs = $null; SendOffset = $null; DeadlineMs = $null; State = $null; Prompt = $null; CompletedMs = $null; EndMs = $null
                                  SliceStart = $null; SliceEnd = $null; SliceSha256 = $null; Refusal = $null; Fsb1Ok = $null; Fsb1Reason = $null; Fsb1Detail = $null
                                  Sha16 = $null; Markers = @(); MarkerNotes = @(); KeysDiscarded = @(); AbortNoted = $false; GapMode = $null; GapSafe = $null
                                  GapSafeWhy = $null; NextLost = $false; R3Rule = $null; Integrity = $null; Q7Fallback = $null }
                $p3.Add($pr)
                # run 3 only by the host rule (DESIGN 5.8 rules 1-4 here, rule 5 = the guard below)
                if ($s3ph -ceq 'r3') {
                    $dec = Get-Fs3cR3Decision -R2Valid $st.R2Valid -R2Run $st.R2Run -Items $st.R2Items -Chal8 ([string]$Tokens.C['r2']).Substring(0, 8)
                    $pr.R3Rule = $dec; $res.R3Rule = $dec
                    if (-not $dec.Allow) {
                        $pr.NotRunWhy = "run-3 rule: $($dec.Why)"; $st.EndWhy = "RUN 3 NOT REQUESTED ($($dec.Why))"
                        $X.Ui.Line("RUN 3 NOT REQUESTED: $($dec.Why)"); return
                    }
                }
                # keys pressed since the last prompt: x (or n: build review MINOR-4) = abort, anything else discarded and logged
                $now = $X.Now(); $k = $Keys.Read($now)
                while ($null -ne $k) {
                    if ($k -ceq 'x' -or $k -ceq 'n') { $s3abort.Noted = $true; $s3abort.Ms = $now; $s3abort.Ph = "before-$s3ph"; $X.Event("abort-noted before $s3ph key=$k") } else { $X.Event("key-discarded before $s3ph key=$k") }
                    $k = $Keys.Read($now)
                }
                if ($s3abort.Noted) {
                    $pr.NotRunWhy = 'abort (x) before this phase'; $st.EndWhy = "ABORT (x) noted: $name is not run"; $st.Alarm = $true
                    $X.Ui.Banner('abort', 'ABORT NOTED', "$name is not run; fs-done follows"); return
                }
                # the guard, immediately before the send (DESIGN 9.3)
                $g = Test-Fs3cGuard -Cfg $Cfg -PhX $s3ph -NowMs $Transport.NowMs()
                $pr.GuardNeedMs = $g.NeedMs; $pr.GuardLeftMs = $g.LeftMs
                if (-not $g.Ok) {
                    $pr.NotRunWhy = "guard: $($g.Why)"; $st.EndWhy = "$name NOT POSSIBLE (guard G = $($Cfg.GuardSec[$s3ph]) s): $($g.Why)"
                    $X.Ui.Line("$name NOT POSSIBLE: not enough time left before the give-up (guard $($Cfg.GuardSec[$s3ph]) s)"); return
                }
                # the phase: sent once, never retried
                $st.Known = $false
                $Keys.Arm(@{ p0 = 'g'; r1 = 'i'; r2 = 'j'; r3 = 'k' }[$s3ph], $Transport.NowMs())   # scripted anchors: g/i/j/k = pressed during p0/r1/r2/r3
                $s3ms = @{ Off = [long]$Capture.Length; InRec = $false; Seen = (New-Object System.Collections.Generic.List[string]); Notes = (New-Object System.Collections.Generic.List[string]); Disc = (New-Object System.Collections.Generic.List[string]) }
                $s3name = $name; $s3nonce = $Cfg.Nonce
                $X.Ui.Line("$name : request sent")
                $onPoll = {
                    param($c, [long]$from)
                    # FSPM1 markers: complete new lines only (a marker split across reads is reassembled)
                    if ($c.C.Length -gt $s3ms.Off) {
                        $nb = $c.C.Bytes($s3ms.Off)
                        $tx = [System.Text.Encoding]::GetEncoding(28591).GetString($nb)
                        $nl = $tx.LastIndexOf([char]10)
                        if ($nl -ge 0) {
                            $s3ms.Off += ($nl + 1)
                            foreach ($raw0 in $tx.Substring(0, $nl).Split([char]10)) {
                                $l0 = $raw0.TrimEnd([char]13)
                                if ($l0.StartsWith('FSB1 BEGIN', [StringComparison]::Ordinal)) { $s3ms.InRec = $true }
                                if (-not $l0.StartsWith('FSPM1', [StringComparison]::Ordinal)) { continue }
                                $mk = ConvertFrom-Fs3cMarker -Line $l0 -NonceX $s3nonce -PhX $s3ph -RawLength ($raw0.Length + 1)
                                if (-not $mk.Ok) { $s3ms.Notes.Add("marker ignored: $($mk.Why)"); $s3x.Event("marker-ignored $s3ph $($mk.Why)"); continue }
                                if ($s3ms.InRec) { $s3ms.Notes.Add("marker $($mk.E) inside or after the record: ignored"); continue }
                                $s3ms.Seen.Add("$($mk.E)@$($mk.T)"); $s3x.Event("marker $s3ph $($mk.E) t=$($mk.T)")
                                if ($s3lit) {
                                    switch -CaseSensitive ($mk.E) {
                                        'go'   { $s3x.Ui.Banner('look', "$s3name STARTING - LOOK", 'keep looking into the lenses until RUN ENDED'); $s3x.Sound.Play('START', $s3x.Now()) }
                                        'end'  { $s3x.Ui.Banner('ended', "$s3name ENDED", 'the panels should be off; questions follow when the record is in'); $s3x.Sound.Play('END', $s3x.Now()) }
                                        'skip' { $s3x.Ui.Banner('info', "$s3name SKIPPED", 'nothing is shown in this run') }
                                    }
                                }
                            }
                        }
                    }
                    # keys during the phase: x (and n: build review MINOR-4, light reported during a run = x) = abort noted at
                    # once, the safe finish after the record; anything else discarded and logged
                    $kn = $c.T.NowMs(); $kk = $s3keys.Read($kn)
                    while ($null -ne $kk) {
                        if (($kk -ceq 'x' -or $kk -ceq 'n') -and -not $s3abortRef.Noted) {
                            $s3abortRef.Noted = $true; $s3abortRef.Ms = $kn; $s3abortRef.Ph = $s3ph
                            $why0 = if ($kk -ceq 'n') { 'n (light) taken as x: ' } else { '' }
                            if ($s3lit) { $s3x.Ui.Banner('abort', 'ABORT NOTED - the device finishes this hold (<= 10 s)', "$($why0)look away if you wish; one safety question, then fs-done") }
                            else { $s3x.Ui.Banner('abort', 'ABORT NOTED', "$($why0)no run follows; fs-done after this phase") }
                            $s3x.Sound.Play('ALARM', $kn); $s3x.Event("abort-noted during $s3ph key=$kk")
                        } else { $s3ms.Disc.Add("$kk@$kn"); $s3x.Event("key-discarded during $s3ph key=$kk") }
                        $kk = $s3keys.Read($kn)
                    }
                }
                $p = Invoke-Fs3cPhase $ctx 'fs-phase' "$s3ph $chal $prevSha" ([int](($Cfg.PhaseWorstSec[$s3ph] + 5) * 1000)) {
                    param($L)
                    $e = Find-FsFsb1End $L
                    $f = Find-FsRecordLine $L 'FSXE1'                  # a refusal (FSXE1 ... END) is terminal too
                    if ($null -eq $e) { return $f }
                    if ($null -eq $f) { return $e }
                    if ($f.Index -lt $e.Index) { return $f } else { return $e }
                } -Tag 'FSB1' -OnPoll $onPoll -NextWake { $s3keys.NextDueMs($Transport.NowMs()) }
                $phases.Add($p)
                $pr.Markers = $s3ms.Seen.ToArray(); $pr.MarkerNotes = $s3ms.Notes.ToArray(); $pr.KeysDiscarded = $s3ms.Disc.ToArray(); $pr.AbortNoted = ($s3abort.Noted -and $s3abort.Ph -ceq $s3ph)
                if ($p.State -ceq 'not-sent') { $pr.NotRunWhy = "send gate: $($p.Gate)"; $res.StopReason = Get-FsPhaseStop $p; return }
                $pr.Sent = $true; $pr.SendMs = $p.SendMs; $pr.SendOffset = $p.SendOffset; $pr.DeadlineMs = $p.DeadlineMs; $pr.State = $p.State; $pr.Prompt = $p.Prompt; $pr.CompletedMs = $p.CompletedMs
                # the slice (DESIGN 5.6): from the send offset to the end of the settled prompt (or the phase deadline); an N line marks its end
                $pr.EndMs = $Transport.NowMs(); $pr.SliceStart = $p.SendOffset; $pr.SliceEnd = $Capture.Length
                $Capture.NoteEvent("phase-end p=$s3ph state=$($p.State) prompt=$(if ($p.Prompt) { $p.Prompt } else { '-' })", $Transport.NowMs())
                [byte[]]$slice = $Capture.Bytes($p.SendOffset)
                $pr.SliceSha256 = Get-FsSha256Hex $slice
                if ($p.State -cne 'complete') {
                    $st.EndWhy = "$name : no complete record by the phase deadline ($($p.State)); nothing more is sent"; $res.StopReason = (Get-FsPhaseStop $p) + ' (no complete record by the phase deadline)'
                    $X.Ui.Banner('abort', "NO RECORD FOR $name BY ITS DEADLINE", 'LOOK AWAY and wait: the device recovers by itself (idle limit, or the deadline)'); $X.Sound.Play('ALARM', $X.Now())
                    return
                }
                $valid = $false
                if ($p.Completion.StartsWith('FSXE1 ', [StringComparison]::Ordinal)) { $pr.Refusal = Get-Fs3cRefusalInfo $p.Completion }
                else {
                    $dec = Test-Fsb1Record -Bytes $slice -Exp $Cfg.Exp[$s3ph] -Nonce $Cfg.Nonce -Challenge $chal -Steps $Cfg.Steps[$s3ph]
                    $pr.Fsb1Ok = $dec.Ok; $pr.Fsb1Reason = $dec.Reason; $pr.Fsb1Detail = $dec.Detail
                    $pr.Sha16 = Get-Fs3cRecSha16 $slice
                    $valid = ($dec.Ok -and $null -ne $pr.Sha16)
                    if ($valid -and $s3ph -ceq 'r2') { $st.R2Valid = $true; $st.R2Run = Get-Fs3cRun @($dec.Steps)[1] 2 $chal.Substring(0, 8) }
                }
                $X.Ui.Line("$name : record received")
                if ($p.Prompt -cne 'prompt') {
                    $st.EndWhy = "$name : completed, then prompt $($p.Prompt): no prompts, nothing more is sent"; $res.StopReason = "fs-phase $($s3ph): completed, then prompt $($p.Prompt): fs-done not sent"
                    $X.Ui.Banner('abort', 'SHELL STATE UNKNOWN', 'LOOK AWAY and wait: the device recovers by itself (idle limit, or the deadline)'); $X.Sound.Play('ALARM', $X.Now())
                    return
                }
                $st.Known = $true
                # the prompts (only after the record and a settled prompt; never for p0, never after ran=0)
                if ($s3lit -and ($null -eq $pr.Refusal -or $pr.Refusal.Ran -eq 1)) {
                    $mode = if ($pr.AbortNoted) { 'darkonly' } elseif ($valid) { 'full' } else { 'readings' }
                    $nextPh = @{ r1 = 'r2'; r2 = 'r3'; r3 = '' }[$s3ph]
                    $ng = if ($nextPh) { [long]$Cfg.GuardSec[$nextPh] * 1000 } else { [long]0 }
                    # Q7 fallback: the run-3 rule (DESIGN 5.8 rules 1-4) on the readings so far decides whether the bar counts are asked
                    $q7sb = $null
                    if ($s3ph -ceq 'r2' -and $valid) {
                        $s3q7Run = $st.R2Run; $s3q7C8 = ([string]$Tokens.C['r2']).Substring(0, 8)
                        $q7sb = { param($items) (Get-Fs3cR3Decision -R2Valid $true -R2Run $s3q7Run -Items $items -Chal8 $s3q7C8).Allow }
                    }
                    $gap = Invoke-Fs3cGap -X $X -Ph $s3ph -Mode $mode -Layout ($s3ph -ceq 'r2' -and $valid) -LastEndMs $pr.EndMs -GiveUpMsX $Cfg.GiveUpMs `
                        -DoneReserveSec $Cfg.DoneReserveSec -GapCapSec $Cfg.GapCapSec -PromptTimeoutSec $Cfg.PromptTimeoutSec -LayoutMinSec $Cfg.LayoutMinSec -NextName $nextPh -NextGuardMs $ng -BarsQ7 $q7sb
                    $pr.GapMode = $mode; $pr.GapSafe = $gap.Safe; $pr.GapSafeWhy = $gap.SafeWhy; $pr.NextLost = $gap.NextLost
                    if (@($gap.BarsQ7).Count) { $pr.Q7Fallback = [ordered]@{ Items = @($gap.BarsQ7); Note = 'not asked (Q7 fallback)'; Why = 'run-3 path: DESIGN 5.8 rules 1-4 held after the dark check (DESIGN 15 Q7)' } }
                    if ($s3ph -ceq 'r2') { $st.R2Items = $gap.Items }
                    if ($null -ne $gap.Safe) {
                        $st.EndWhy = "SAFE FINISH after $($name): $($gap.SafeWhy)"; if ($gap.Safe -cne 'stray') { $st.Alarm = $true }
                        $X.Ui.Banner('abort', 'SAFE FINISH - no further run', $gap.SafeWhy)            # build review NIT a: red
                        return
                    }
                }
                if ($null -ne $pr.Refusal) { $st.EndWhy = "$name REFUSED by the device ($($pr.Refusal.Raw)): no further run"; $st.Alarm = $true; return }
                if (-not $valid) { $st.EndWhy = "$name : the record is not valid ($($pr.Fsb1Reason)): no further run"; $st.Alarm = $true; return }
                if ($s3abort.Noted) { $st.EndWhy = "ABORT (x) noted during $($name): no further run"; $st.Alarm = $true; return }
                if ($s3ph -ceq 'p0') {
                    # build review MAJOR-1: no lit phase unless p0's hash step MEASURED the pinned fs-pattern
                    $ig = Get-Fs3cP0Integrity -StepList @($dec.Steps) -Pin $Cfg.PatternPin
                    $pr.Integrity = [ordered]@{ Ok = $ig.Ok; Class = $ig.Class; Why = (ConvertTo-FsPrintable $ig.Why) }
                    $X.Event("p0-integrity $($ig.Class)")
                    if (-not $ig.Ok) {
                        $st.EndWhy = "RUN 1 NOT POSSIBLE (integrity): $($ig.Class)"; $st.Alarm = $true
                        $X.Ui.Banner('abort', 'RUN 1 NOT POSSIBLE (integrity)', 'nothing is lit; fs-done follows'); return
                    }
                }
                $prevSha = $pr.Sha16
                if ($s3ph -ceq 'p0') {
                    # the LOOK cue (nothing is lit yet; no prompt), read-only; keys: x = abort
                    $X.Ui.Banner('look', 'LOOK INTO THE LENSES NOW', 'RUN 1 (about 3 s) follows in a few seconds; keep looking until RUN ENDED')
                    $X.Sound.Play('START', $X.Now()); $X.Event('look-cue')
                    $Keys.Arm('c', $Transport.NowMs())
                    $u = [Math]::Min($Transport.NowMs() + $Cfg.CueMs, $Cfg.GiveUpMs)
                    while ($Transport.NowMs() -lt $u) {
                        $X.Poll()
                        $kk = $Keys.Read($Transport.NowMs())
                        while ($null -ne $kk) { if ($kk -ceq 'x' -or $kk -ceq 'n') { $s3abort.Noted = $true; $s3abort.Ms = $Transport.NowMs(); $s3abort.Ph = 'cue'; $X.Event("abort-noted during cue key=$kk") } else { $X.Event("key-discarded during cue key=$kk") }; $kk = $Keys.Read($Transport.NowMs()) }
                        $X.Idle($u)
                    }
                    if ($s3abort.Noted) { $st.EndWhy = 'ABORT (x) noted during the LOOK cue: RUN 1 is not run'; $st.Alarm = $true; $X.Ui.Banner('abort', 'ABORT NOTED', 'RUN 1 is not run; fs-done follows'); $X.Sound.Play('ALARM', $X.Now()); return }
                }
                if ($s3ph -ceq 'r3') { $st.EndWhy = 'all runs done'; return }
            }
        }
    } catch {
        $res.TransportError = ConvertTo-FsPrintable $_.Exception.Message
        if (-not $res.StopReason) { $res.StopReason = "transport or collector error: $($res.TransportError)" }
        $st.Known = $false
    }
    try {
        if ($st.EndWhy) { $res.EndReason = $st.EndWhy; $X.Ui.Line("SESSION END: $($st.EndWhy)") }
        if ($st.Alarm) { $X.Sound.Play('ALARM', $X.Now()) }
        # ---- COPIED from Invoke-FsCollect: early recovery only from a known state, after a verified challenge, and through the send gate
        if ($st.Known -and $res.Verified -and -not $Cfg.NoDone) {
            $ctx.PhaseCapMs = $null       # recovery only shortens the hold: never blocked by the ack window (NIT7)
            try {
                $p = Invoke-FsPhase $ctx 'fs-done' '' $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSD1' } -Tag 'FSD1' -NoPrompt
                $phases.Add($p)
                if ($p.State -ceq 'not-sent') { $res.DoneReply = Get-FsPhaseStop $p }
                else { $res.DoneSent = $true; $res.DoneReply = if ($p.State -ceq 'complete') { ConvertTo-FsPrintable $p.Completion } else { $p.State } }
            } catch { $res.DoneReply = 'error: ' + (ConvertTo-FsPrintable $_.Exception.Message) }
        }
        # ---- end of the copied block
        if ($res.DoneSent) {
            # fs-done is already sent; only the FINISH sound waits until an ALARM of the last second has played
            # (one SoundPlayer sound at a time: a new Play() would cut it). The port is not read meanwhile.
            $la = @($Sound.Played | Where-Object { $_ -like 'ALARM@*' } | ForEach-Object { [long]($_.Split('@')[1]) }) | Select-Object -Last 1
            if ($null -ne $la) { $u = $la + 1000; while ($Transport.NowMs() -lt $u) { $Transport.Idle($u) } }
            $X.Sound.Play('FINISH', $X.Now())
            $X.Ui.Banner('abort', 'FINISH: fs-done sent', 'the device reboots to fastboot (about 1 s); do not touch anything else')
        } elseif ($res.Verified) {
            $X.Sound.Play('ALARM', $X.Now())
            $X.Ui.Banner('abort', 'NO fs-done (state unknown or gated)', 'LOOK AWAY and wait: the device recovers by itself (idle limit 120 s, or T0 + 200 s)')
        }
    } finally {
        $res.Exchanges = $phases.ToArray()
        $res.Phases = @($p3 | ForEach-Object { [pscustomobject]$_ })
        $res.Sent = $ctx.Sent.ToArray()
        $res.Known = $st.Known
        $res.Readings = $X.Readings.ToArray(); $res.ReadingObjs = $X.ReadingObjs.ToArray(); $res.Events = $X.Events.ToArray()
        $res.SoundsPlayed = $Sound.Played.ToArray(); $res.SoundFailures = $Sound.Failures.ToArray(); $res.Transcript = $Ui.Transcript.ToArray()
        try { $Transport.Dispose() } catch { if (-not $res.TransportError) { $res.TransportError = ConvertTo-FsPrintable $_.Exception.Message } }
        try { $Capture.Close() } catch { $res.CaptureError = $_.Exception.Message }
    }
    [pscustomobject]$res
}

# ------------------------------------------------------- Invoke-Fs3cRun ------
# REPLACES Invoke-FsCollectRun: the capture, the session, then from the file on disk: the consistency
# check (copied), the slices re-derived and compared with the session's, phase-<ph>.raw files, the
# per-slice FSB1 validation (DESIGN 5.6), readings3c.txt and session.json.
function Invoke-Fs3cRun {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)][string]$OutDirX, [Parameter(Mandatory)][hashtable]$Tokens, [Parameter(Mandatory)][hashtable]$Cfg,
          [string]$Mode, [string]$PortName = '-', [Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Keys, [Parameter(Mandatory)]$Sound, [Parameter(Mandatory)]$Sounds,
          [DateTime]$UtcBase = [DateTime]::MinValue, [long]$UtcBaseMs = 0)
    $cap = New-FsCapture -Dir $OutDirX -Nonce $Cfg.Nonce -Mode $Mode -PortName $PortName
    $r = Invoke-Fs3cSession -Transport $Transport -Capture $cap -Tokens $Tokens -Cfg $Cfg -Ui $Ui -Keys $Keys -Sound $Sound -UtcBase $UtcBase -UtcBaseMs $UtcBaseMs -OutDirX $OutDirX
    if ($null -eq $r) { throw 'session returned nothing' }
    [byte[]]$raw = [IO.File]::ReadAllBytes($cap.RawPath)
    $disk = Get-FsSha256Hex $raw
    $o = [ordered]@{}
    foreach ($pp in $r.PSObject.Properties) { $o[$pp.Name] = $pp.Value }
    $o.Capture = [ordered]@{ Path = $cap.RawPath; Index = $cap.IdxPath; Bytes = $raw.Length; Sha256 = $cap.Sha256; Sha256FromDisk = $disk
                             Consistent = ($disk -ceq $cap.Sha256 -and $raw.Length -eq $cap.Length -and -not $r.CaptureError) }
    $o.Sounds = Get-Fs3cSoundHashes $Sounds
    $sl = @(); $slOk = $false; $slWhy = ''
    try {
        $evs = Read-Fs3cIndexEvents -Path $cap.IdxPath -RawLength $raw.Length
        $sl = Get-Fs3cSlices -Raw $raw -Events $evs; $sl = @($sl)
        $sent = @($r.Phases | Where-Object { $_.Sent })
        $slOk = ($sl.Count -eq $sent.Count)
        for ($i = 0; $slOk -and $i -lt $sl.Count; $i++) {
            $slOk = ($sl[$i].Ph -ceq $sent[$i].Ph -and $sl[$i].Start -eq [long]$sent[$i].SliceStart -and $sl[$i].End -eq [long]$sent[$i].SliceEnd -and $sl[$i].Sha256 -ceq $sent[$i].SliceSha256)
        }
        if (-not $slOk) { $slWhy = 'the slices re-derived from the file differ from the session''s' }
    } catch { $slWhy = "slices not derivable: $($_.Exception.Message)" }
    $slices = New-Object System.Collections.Generic.List[object]; $fsb = [ordered]@{}
    foreach ($s in $sl) {
        $f = Join-Path $OutDirX "phase-$($s.Ph).raw"
        try { [IO.File]::WriteAllBytes($f, $s.Bytes) } catch { $slWhy += " phase-$($s.Ph).raw not written: $($_.Exception.Message)" }
        $slices.Add([ordered]@{ Ph = $s.Ph; Start = $s.Start; End = $s.End; How = $s.How; Sha256 = $s.Sha256; File = "phase-$($s.Ph).raw"; Chal = $s.Chal; Prev = $s.Prev })
        $cp = Get-Fs3cSliceCompletion $s.Bytes
        if ($cp.Kind -ceq 'record') {
            $d = Test-Fsb1Record -Bytes $s.Bytes -Exp $Cfg.Exp[$s.Ph] -Nonce $Cfg.Nonce -Challenge $s.Chal -Steps $Cfg.Steps[$s.Ph]
            $fsb[$s.Ph] = [ordered]@{ Kind = 'record'; Ok = $d.Ok; Reason = $d.Reason; Detail = $d.Detail }
        } elseif ($cp.Kind -ceq 'refusal') { $fsb[$s.Ph] = [ordered]@{ Kind = 'refusal'; Ok = $false; Reason = 'refused'; Detail = (ConvertTo-FsPrintable $cp.Line) } }
        else { $fsb[$s.Ph] = [ordered]@{ Kind = 'none'; Ok = $false; Reason = 'no-completion'; Detail = '' } }
    }
    $o.Slices = $slices.ToArray(); $o.SlicesConsistent = $slOk; $o.SlicesWhy = $slWhy; $o.Fsb1 = $fsb
    $sentPh = @($r.Phases | Where-Object { $_.Sent })
    if (-not $o.Capture.Consistent -or -not $slOk) {
        $o.Status = 'INCONCLUSIVE'
        $why = if ($r.CaptureError) { $r.CaptureError } elseif (-not $o.Capture.Consistent) { 'capture file does not match the bytes read' } else { $slWhy }
        $o.StopReason = $(if ($o.StopReason) { "$($o.StopReason); $why" } else { $why })
    } elseif ($sentPh.Count -eq 0 -or @($sentPh | Where-Object { $_.State -cne 'complete' }).Count) { $o.Status = 'INCONCLUSIVE' }
    elseif (@($fsb.Values | Where-Object { -not $_.Ok }).Count) { $o.Status = 'COLLECTED-REJECTED' }
    else { $o.Status = 'COLLECTED-VALID' }
    if ($Transport.Kind -ceq 'replay') {
        $o.Replay = [ordered]@{ Beeps = $Transport.Beeps.ToArray(); Divergence = $Transport.Divergence.ToArray(); UnperformedWrites = @($Transport.Ix.W | Select-Object -Skip $Transport.Wi | ForEach-Object Text)
                                ConsumedBytes = $raw.Length; SourceBytes = $Transport.Raw.Length; PrevCheck = @() }
    }
    $rd = Join-Path $OutDirX 'readings3c.txt'
    [IO.File]::WriteAllText($rd, ((@($r.Readings) | ForEach-Object { "$_`n" }) -join ''), (New-Object System.Text.UTF8Encoding($false)))
    $o.ReadingsFile = $rd
    [pscustomobject]$o
}
function Save-Fs3cSessionJson {
    param($Result, [string]$Path)
    $json = $Result | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

# --------------------------------------------------------------- replay ------
# REPLACES Get-FsReplayTokens: the challenges come from the recorded writes (validated by the command
# table's regexes); <prev> is recorded only for the comparison, never used as a token.
function Get-Fs3cReplayTokens {
    param($Index)
    $tk = @{ V = $null; A = $null; C = @{}; RecordedPrev = @{} }
    foreach ($w in $Index.W) {
        if ($w.Text -cmatch '^fs-verify ([0-9a-f]{32})\z' -and -not $tk.V) { $tk.V = $Matches[1] }
        elseif ($w.Text -cmatch '^fs-ack ([0-9a-f]{16})\z' -and -not $tk.A) { $tk.A = $Matches[1] }
        elseif ($w.Text -cmatch '^fs-phase (p0|r1|r2|r3) ([0-9a-f]{32}) ([0-9a-f]{16})\z' -and -not $tk.C.ContainsKey($Matches[1])) { $tk.C[$Matches[1]] = $Matches[2]; $tk.RecordedPrev[$Matches[1]] = $Matches[3] }
    }
    if (-not $tk.V) { $tk.V = New-FsHex 16 }; if (-not $tk.A) { $tk.A = New-FsHex 8 }
    foreach ($ph in 'p0', 'r1', 'r2', 'r3') { if (-not $tk.C.ContainsKey($ph)) { $tk.C[$ph] = New-FsHex 16 } }
    $tk
}
# COPY of New-FsReplayTransport with time re-anchoring at each host write (see the header) and -Paced.
function New-Fs3cReplayTransport {
    param([Parameter(Mandatory)][byte[]]$Raw, [Parameter(Mandatory)]$Index, [int]$PollMsX = 50, [switch]$Paced)
    $t = [pscustomobject]@{ Raw = $Raw; Ix = $Index; Ci = 0; Wi = 0; Now = [long]0; Shift = [long]0; PollMs = $PollMsX; Kind = 'replay'; Paced = [bool]$Paced
                            Clock = [System.Diagnostics.Stopwatch]::StartNew(); Beeps = (New-Object System.Collections.Generic.List[string])
                            Divergence = (New-Object System.Collections.Generic.List[string]); Diverged = $false }
    $t | Add-Member ScriptMethod Open { }
    $t | Add-Member ScriptMethod NowMs { if ($this.Paced) { [long]$this.Clock.ElapsedMilliseconds } else { $this.Now } }
    $t | Add-Member ScriptMethod At { param($c) [long]$c.Ms + $this.Shift }      # a chunk's time on the session clock
    $t | Add-Member ScriptMethod NextReady {    # the next deliverable chunk, or $null
        if ($this.Diverged -or $this.Ci -ge $this.Ix.R.Count) { return $null }
        $c = $this.Ix.R[$this.Ci]
        if ($this.Wi -lt $this.Ix.W.Count -and $c.Offset -ge $this.Ix.W[$this.Wi].Offset) { return $null }   # gated by a host write not yet made
        return $c
    }
    $t | Add-Member ScriptMethod ReadBytes {
        param([long]$untilMs)
        $c = $this.NextReady()
        if ($this.Paced) { $untilMs = [Math]::Min($untilMs, $this.NowMs()) }
        if ($null -eq $c -or $this.At($c) -gt $untilMs) { return ,([byte[]]@()) }
        if (-not $this.Paced -and $this.At($c) -gt $this.Now) { $this.Now = $this.At($c) }
        $this.Ci++
        $b = New-Object byte[] $c.Length; [Array]::Copy($this.Raw, [int]$c.Offset, $b, 0, [int]$c.Length)
        return ,$b
    }
    $t | Add-Member ScriptMethod WriteBytes {
        param([byte[]]$b)
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString($b).TrimEnd([char]10)
        if ($this.Diverged) { $this.Divergence.Add("after divergence: $text"); return }
        if ($this.Wi -lt $this.Ix.W.Count) {
            $gate = $this.Ix.W[$this.Wi].Offset; $delivered = if ($this.Ci -lt $this.Ix.R.Count) { $this.Ix.R[$this.Ci].Offset } else { $this.Raw.Length }
            if ($delivered -lt $gate) { $this.Divergence.Add("collector wrote '$text' before reading all bytes recorded ahead of that write ($delivered of $gate)"); $this.Diverged = $true; return }
        }
        if ($this.Wi -lt $this.Ix.W.Count -and $this.Ix.W[$this.Wi].Text -ceq $text) {
            $this.Shift = $this.NowMs() - [long]$this.Ix.W[$this.Wi].Ms      # re-anchor: the device answers relative to this send
            $this.Wi++; return
        }
        $want = if ($this.Wi -lt $this.Ix.W.Count) { $this.Ix.W[$this.Wi].Text } else { '(none: the recorded session made no further write)' }
        $this.Divergence.Add("collector wrote '$text'; recorded write was '$want'"); $this.Diverged = $true
    }
    $t | Add-Member ScriptMethod Idle {
        param([long]$untilMs)
        if ($this.Paced) { $d = [Math]::Min([long]$this.PollMs, $untilMs - $this.NowMs()); if ($d -gt 0) { Start-Sleep -Milliseconds $d }; return }
        $c = $this.NextReady()
        if ($null -ne $c -and $this.At($c) -le $untilMs) { if ($this.At($c) -gt $this.Now) { $this.Now = $this.At($c) } else { $this.Now += 1 } }
        else { $this.Now = [Math]::Max($this.Now, $untilMs) }
    }
    $t | Add-Member ScriptMethod Beep { param([int]$f, [int]$ms) $this.Beeps.Add("$f/$ms@$($this.NowMs())"); if (-not $this.Paced) { $this.Now += $ms } }
    $t | Add-Member ScriptMethod Dispose { }
    $t
}
# Replay entry point (CLI, fixtures, rehearsal). -Ui/-Keys/-Sound default to a recording console, an
# empty key script (every prompt times out) and a recording sound sink.
function Invoke-Fs3cReplay {
    param([Parameter(Mandatory)][string]$RawPath, [string]$IndexPath, [Parameter(Mandatory)][string]$OutDirX, [string]$NonceX = '',
          [hashtable]$Overrides = @{}, $Ui = $null, $Keys = $null, $Sound = $null, $Sounds = $null, [switch]$Paced)
    if (-not $IndexPath) { $IndexPath = "$RawPath.idx" }
    [byte[]]$raw = [IO.File]::ReadAllBytes($RawPath)
    $ix = Read-FsCaptureIndex -Path $IndexPath -RawLength $raw.Length
    if ($NonceX -and $NonceX -cne $ix.Nonce) { throw "refused: -S3cNonce $NonceX differs from the index nonce $($ix.Nonce)" }
    $cfg = New-Fs3cCfg -NonceX $ix.Nonce
    foreach ($k in $Overrides.Keys) {
        if (@('Stage', 'RunVerb', 'RefusalTag', 'GuardSec') -ccontains $k) { continue }        # fixed for stage 3c
        if (-not $cfg.ContainsKey($k)) { throw "unknown setting $k" }; $cfg[$k] = $Overrides[$k]
    }
    if ($null -eq $Sounds) { $Sounds = New-Fs3cSounds }
    if ($null -eq $Ui) { $Ui = New-Fs3cUi -Kind record }
    if ($null -eq $Keys) { $Keys = New-Fs3cScriptedKeySource -Script @() }
    if ($null -eq $Sound) { $Sound = New-Fs3cSoundSink -Kind record -Sounds $Sounds }
    $t = New-Fs3cReplayTransport -Raw $raw -Index $ix -PollMsX $cfg.PollMs -Paced:$Paced
    $tk = Get-Fs3cReplayTokens $ix
    $base = if ($Paced) { [DateTime]::UtcNow } else { [DateTime]::Parse('2026-10-11T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
    $r = Invoke-Fs3cRun -Transport $t -OutDirX $OutDirX -Tokens $tk -Cfg $cfg -Mode 'replay' -Ui $Ui -Keys $Keys -Sound $Sound -Sounds $Sounds -UtcBase $base -UtcBaseMs 0
    $r | Add-Member NoteProperty ReplaySource ([ordered]@{ Raw = $RawPath; Sha256 = (Get-FsSha256Hex $raw); Index = $IndexPath })
    # <prev>: recomputed by the session from the replayed records, compared with the recorded one (never trusted)
    $pc = @()
    foreach ($ph in @($r.Phases | Where-Object { $_.Sent })) {
        $rec = if ($tk.RecordedPrev.ContainsKey($ph.Ph)) { $tk.RecordedPrev[$ph.Ph] } else { $null }
        $pc += [ordered]@{ Ph = $ph.Ph; Computed = $ph.Prev; Recorded = $rec; Same = ($rec -ceq $ph.Prev) }
    }
    foreach ($ph in @($r.Phases | Where-Object { -not $_.Sent -and $tk.RecordedPrev.ContainsKey($_.Ph) })) { $pc += [ordered]@{ Ph = $ph.Ph; Computed = $null; Recorded = $tk.RecordedPrev[$ph.Ph]; Same = $false } }
    $r.Replay.PrevCheck = $pc
    [byte[]]$re = [IO.File]::ReadAllBytes($r.Capture.Path)
    $prefixOk = $re.Length -le $raw.Length
    if ($prefixOk -and $re.Length -gt 0) { $src = New-Object byte[] $re.Length; [Array]::Copy($raw, $src, $re.Length); $prefixOk = ([FsHostNative]::DiffIndices($src, $re).Length -eq 0) }
    $r.Replay.RecaptureIsSourcePrefix = $prefixOk
    try { Save-Fs3cSessionJson -Result $r -Path (Join-Path $OutDirX 'session.json') } catch {}
    $r
}

# Operator summary, AFTER the session (machine facts are printed only now, DESIGN 8.2). Device-derived
# text goes through ConvertTo-FsPrintable.
function Write-Fs3cSummary { param($r, [bool]$Rehearsal = $false)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("STATUS: $($r.Status)")
    if ($r.StopReason) { $out.Add("STOP:   $($r.StopReason)") }
    if ($r.EndReason) { $out.Add("END:    $($r.EndReason)") }
    $out.Add("SENT:   $(@($r.Sent) -join ' | ')")
    foreach ($p in @($r.Phases)) {
        if (-not $p.Sent) { $out.Add("PHASE $($p.Ph): not run ($($p.NotRunWhy))"); continue }
        $f = if ($null -ne $p.Refusal) { "REFUSED $($p.Refusal.Raw)" } elseif ($null -ne $p.Fsb1Ok) { if ($p.Fsb1Ok) { 'FSB1 VALID' } else { "FSB1 REJECT $($p.Fsb1Reason) $($p.Fsb1Detail)" } } else { "no complete record ($($p.State))" }
        $out.Add("PHASE $($p.Ph): $f; guard left $([long]($p.GuardLeftMs / 1000)) s of $([long]($p.GuardNeedMs / 1000)) s; markers $(@($p.Markers) -join ',')$(if (@($p.MarkerNotes).Count) { ' (' + (@($p.MarkerNotes) -join '; ') + ')' })$(if ($p.GapSafe) { "; prompts ended: $($p.GapSafeWhy)" })$(if ($p.PSObject.Properties['Q7Fallback'] -and $null -ne $p.Q7Fallback) { "; $(@($p.Q7Fallback.Items) -join ', ') $($p.Q7Fallback.Note)" })")
    }
    if ($null -ne $r.R3Rule) { $out.Add("RUN-3 RULE: $(if ($r.R3Rule.Allow) { 'held' } else { $r.R3Rule.Why })") }
    $out.Add("CAPTURE: $($r.Capture.Path) bytes=$($r.Capture.Bytes) sha256=$($r.Capture.Sha256) consistent=$($r.Capture.Consistent) slices=$($r.SlicesConsistent)")
    if ($r.CaptureError) { $out.Add("CAPTURE ERROR: $($r.CaptureError)") }
    $out.Add("READINGS: $($r.ReadingsFile) ($(@($r.Readings).Count) FSR2 lines)")
    if (-not $r.DoneSent) { $out.Add("RECOVERY: fs-done NOT sent (state unknown, unverified or gated): the idle limit (120 s after the last activity) or the PID 1 deadline (T0+$($r.DeviceDeadlineSec) s, backstop +1 s) reboots the device") }
    else { $out.Add("RECOVERY: fs-done sent; reply: $($r.DoneReply)") }
    if ($Rehearsal) {
        $sum = 0.0
        foreach ($ph in 'r1', 'r2') {
            $it = @($r.ReadingObjs | Where-Object { $_.Ph -ceq $ph })
            if ($it.Count -eq 0) { $out.Add("REHEARSAL: no $ph answers"); continue }
            $a = @($it | Where-Object { $_.AnswerMs -ge 0 } | ForEach-Object { $_.AnswerMs } | Sort-Object -Descending)
            $p0m = @($it | ForEach-Object { $_.PromptMs } | Sort-Object)[0]
            $d = if ($a.Count) { ($a[0] - $p0m) / 1000.0 } else { 0.0 }
            $sum += $d; $out.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture, "REHEARSAL: {0} answers took {1:0.0} s", $ph, $d))
        }
        $out.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture, "REHEARSAL: run-1 plus run-2 answers {0:0.0} s; go/no-go (SIGNOFF-3c A, Q7): {1}", $sum, $(if ($sum -le 40.0) { 'GO (<= 40 s)' } else { 'NO-GO (> 40 s): stop and report (the Q7 fallback is already applied)' })))
    }
    $out.Add("THEN: fs-classify3c.ps1 -C3cDir <this dir> -C3cObserveDir <observe dir>   (after the PM's free-text description is in notes.txt)")
    foreach ($l in $out) { Write-Output (ConvertTo-FsPrintable $l) }
}

# Build review MINOR-7: the machine summary goes to summary.txt; on an interactive console it is shown only when the
# PM presses s (after notes.txt is written), never before. x or Ctrl+C leaves it unshown (it stays in the file).
function Save-Fs3cSummary { param($r, [string]$Dir, [bool]$Rehearsal = $false)
    $p = Join-Path $Dir 'summary.txt'
    [IO.File]::WriteAllText($p, ((@(Write-Fs3cSummary $r $Rehearsal) | ForEach-Object { "$_`n" }) -join ''), (New-Object System.Text.UTF8Encoding($false)))
    $p
}
function Show-Fs3cSummaryOnKey { param($r, [string]$Path, $Keys, [bool]$Rehearsal = $false)
    Write-Output "SESSION OVER. The machine summary is in $Path. It is not shown before the readings and notes.txt are done (FS-R-011 s3)."
    Write-Output 'Press s to show it here now, or x to leave it in the file.'
    $null = $Keys.Drain(0)
    while ($true) {
        $k = $Keys.Read(0)
        if ($k -ceq 's') { Write-Fs3cSummary $r $Rehearsal; return }
        if ($k -ceq 'x') { Write-Output "(not shown; it is in $Path)"; return }
        Start-Sleep -Milliseconds 100
    }
}
# Build review MINOR-10: the recovery line of the CLI's error path names what was actually sent.
function Get-Fs3cErrorRecovery { param($Ctx)
    if (@($Ctx.Sent) -ccontains 'fs-done') { return 'RECOVERY: fs-done was sent before the collector error: the device reboots by itself (about 1 s after fs-done)' }
    'RECOVERY: fs-done NOT sent (collector error): the idle limit (120 s after the last activity) or the PID 1 deadline reboots the device (T0+DEADLINE of its image)'
}

# The prompts need an interactive console ([Console]::KeyAvailable/ReadKey): refuse to start without one
# (nothing is sent), instead of letting every prompt time out.
function Assert-Fs3cConsole {
    try { $null = [Console]::KeyAvailable } catch { throw 'refused: no interactive console for the prompts (run fs-collect3c.ps1 in powershell.exe with the keyboard attached, not in ISE and not with redirected input)' }
}

# ------------------------------------------------------------------ CLI -----
if ($script:Fs3cInvocation -eq '.') { return }
if (Get-Fs3cArg 'S3cParamEcho') {
    # test-host3c case 21: every argument as bound, and the live S3c* variables after the dot-source
    $live = [ordered]@{}; foreach ($n in @($script:Fs3cDefaults.Keys | Sort-Object)) { $v = Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue; if ($v -is [System.Management.Automation.SwitchParameter]) { $v = [bool]$v }; $live[$n] = $v }
    $snap = [ordered]@{}; foreach ($n in @($script:Fs3cDefaults.Keys | Sort-Object)) { $snap[$n] = Get-Fs3cArg $n }
    Write-Output (([pscustomobject]@{ Snapshot = $snap; Live = $live; StageLabel = $script:Fs3cStageLabel; FsPhaseVerb = $script:FsCmdSpec['fs-phase'] }) | ConvertTo-Json -Depth 4 -Compress)
    exit 0
}
$exitCode = 70; $r = $null; $started = $false; $script:Fs3cCm = $null
try {
    $od = [string](Get-Fs3cArg 'S3cOutDir')
    if (-not $od) { throw 'refused: -S3cOutDir is required (a new directory)' }
    $rp = [string](Get-Fs3cArg 'S3cReplay'); $pt = [string](Get-Fs3cArg 'S3cPort'); $nx = [string](Get-Fs3cArg 'S3cNonce')
    $margin = [int](Get-Fs3cArg 'S3cHostMarginSec')
    if ($rp) {
        if ($pt) { throw 'refused: -S3cPort and -S3cReplay are exclusive' }
        $reh = [bool](Get-Fs3cArg 'S3cRehearsal')
        $ov = @{ Kernel = [string](Get-Fs3cArg 'S3cKernel'); Pid1 = [string](Get-Fs3cArg 'S3cPid1'); PollMs = [int](Get-Fs3cArg 'S3cPollMs'); NoDone = [bool](Get-Fs3cArg 'S3cNoDone')
                 GiveUpMs = [long]((200 - $margin) * 1000); AckGiveUpMs = [long]((150 - $margin) * 1000) }
        if ([long](Get-Fs3cArg 'S3cGiveUpMs') -ge 0) { $ov.GiveUpMs = [long](Get-Fs3cArg 'S3cGiveUpMs') }
        $pinR = [string](Get-Fs3cArg 'S3cReplayPin')
        if ($pinR) { if ($pinR -cnotmatch '^[0-9a-f]{64}\z') { throw 'refused: -S3cReplayPin is 64 lowercase hex' }; $ov.PatternPin = $pinR }
        $snd = New-Fs3cSounds
        $ui = New-Fs3cUi -Kind console
        if ($reh) { Assert-Fs3cConsole; $keys = New-Fs3cConsoleKeySource; $sink = New-Fs3cSoundSink -Kind live -Sounds $snd }
        else {
            $ksf = [string](Get-Fs3cArg 'S3cKeyScript')
            $kl = if ($ksf) { [IO.File]::ReadAllLines($ksf) } else { @() }
            $keys = New-Fs3cScriptedKeySource -Script $kl; $sink = New-Fs3cSoundSink -Kind record -Sounds $snd
        }
        $started = $true
        if ($reh) { $script:Fs3cCm = Enter-Fs3cConsoleMode }          # as live: Ctrl+C = x, QuickEdit off
        $r = Invoke-Fs3cReplay -RawPath $rp -IndexPath ([string](Get-Fs3cArg 'S3cReplayIndex')) -OutDirX $od -NonceX $nx -Overrides $ov -Ui $ui -Keys $keys -Sound $sink -Sounds $snd -Paced:$reh
        if (@($r.Replay.Divergence).Count) { Write-Output (ConvertTo-FsPrintable "REPLAY DIVERGENCE: $(@($r.Replay.Divergence) -join '; ')") }
        if ($reh) { $sp = Save-Fs3cSummary $r $od $true; Show-Fs3cSummaryOnKey $r $sp $keys $true }
        else { Write-Fs3cSummary $r $reh }
    } else {
        if ($pt -cnotmatch '^COM[0-9]{1,3}\z') { throw 'refused: -S3cPort must be given explicitly as COMn (never chosen automatically)' }
        if ($nx -cnotmatch '^[0-9a-f]{16}\z') { throw 'refused: -S3cNonce must be the image nonce (16 lowercase hex)' }
        if ([string](Get-Fs3cArg 'S3cReplayPin')) { throw 'refused: -S3cReplayPin is for a replay only (a live session uses the built-in fs-pattern v0.6 pin)' }
        $bsu = [string](Get-Fs3cArg 'S3cBootStartUtc'); $hou = [string](Get-Fs3cArg 'S3cHandoffUtc')
        # FS-R-007 B1: the budget origin is BootStartUtc (before `fastboot boot` was invoked), for every handoff class.
        if (-not $bsu) { throw 'refused: -S3cBootStartUtc (observe.json BootStartUtc, taken just before fastboot boot was invoked) is required: it is the budget origin; -S3cHandoffUtc is evidence only (FS-R-007 B1)' }
        $parseU = { param([string]$v) [DateTime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        $origin = & $parseU $bsu
        $hoEv = $null
        if ($hou) { $hoEv = & $parseU $hou; if ($hoEv -lt $origin) { throw 'refused: -S3cHandoffUtc precedes -S3cBootStartUtc (inconsistent observer times)' } }
        $cliUtc = [DateTime]::UtcNow
        # N1: no tolerance. A future origin means a clock step or bad input, and would inflate the budget.
        if ($origin -gt $cliUtc) { throw "refused: -S3cBootStartUtc $($origin.ToString('o')) is later than now $($cliUtc.ToString('o')) (clock step or bad input; a future origin would inflate the budget)" }
        $ddl = 200; $ackw = 150                                      # stage3c/init.sh DEADLINE and ACK_WINDOW
        $dl = Get-FsHostDeadlines -OriginUtc $origin -DeviceDeadlineSec $ddl -AckWindowSec $ackw -HostMarginSec $margin
        # fail fast before preparing anything (the binding check is the one after the preparation)
        $pre = ConvertTo-FsTransportDeadlines -Deadlines $dl -NowMs 0 -NowUtc ([DateTime]::UtcNow)
        $why = Get-FsLiveStartRefusal -RemainMs $pre.RemainMs -AckRemainMs $pre.AckRemainMs -AckWindowSec $ackw
        if ($why) { throw "refused: $why" }
        # preparation: the gadget lookup, the sounds (generated and loaded), the transport (the port is opened later, inside the session)
        $g = Get-FsGadget -Nonce $nx
        if (-not $g.SerialOk) { throw "refused: no USB gadget with serial FS-$nx is present" }
        if ($g.ComPort -cne $pt) { throw "refused: $pt is not the port registered under FS-$nx (that is '$($g.ComPort)')" }
        $snd = New-Fs3cSounds
        $sink = New-Fs3cSoundSink -Kind live -Sounds $snd
        $ui = New-Fs3cUi -Kind console
        Assert-Fs3cConsole
        $keys = New-Fs3cConsoleKeySource
        $tokens = @{ V = (New-FsHex 16); A = (New-FsHex 8); C = @{ p0 = (New-FsHex 16); r1 = (New-FsHex 16); r2 = (New-FsHex 16); r3 = (New-FsHex 16) } }
        $t = New-FsRawSerialTransport -PortName $pt -PollMs ([int](Get-Fs3cArg 'S3cPollMs'))
        # after the preparation: a FRESH read, transport clock first, then UTC; nothing computed earlier is carried over
        $nowMs = [long]$t.NowMs(); $nowU = [DateTime]::UtcNow
        $cv = ConvertTo-FsTransportDeadlines -Deadlines $dl -NowMs $nowMs -NowUtc $nowU
        $why = Get-FsLiveStartRefusal -RemainMs $cv.RemainMs -AckRemainMs $cv.AckRemainMs -AckWindowSec $ackw
        if ($why) { throw "refused (after $([long]($nowU - $cliUtc).TotalSeconds) s of preparation): $why" }
        $timing = [ordered]@{ BudgetOrigin = 'BootStartUtc'; BootStartUtc = $origin.ToString('o'); HandoffUtcEvidence = $(if ($hoEv) { $hoEv.ToString('o') } else { $null })
                              GiveUpUtc = $dl.GiveUpUtc.ToString('o'); AckGiveUpUtc = $dl.AckGiveUpUtc.ToString('o'); DeviceDeadlineNoEarlierThanUtc = $dl.DeviceDeadlineUtc.ToString('o')
                              CollectorStartUtc = $cliUtc.ToString('o'); ConvertedAtUtc = $nowU.ToString('o'); ConvertedAtMs = $nowMs
                              PreparationMs = [long]($nowU - $cliUtc).TotalMilliseconds; RemainMsAtConversion = $cv.RemainMs; AckRemainMsAtConversion = $cv.AckRemainMs }
        $cfg = New-Fs3cCfg -NonceX $nx -GiveUpMsX $cv.GiveUpMs -AckGiveUpMsX $cv.AckGiveUpMs -KernelX ([string](Get-Fs3cArg 'S3cKernel')) -Pid1X ([string](Get-Fs3cArg 'S3cPid1')) `
            -TimingX $timing -PollMsX ([int](Get-Fs3cArg 'S3cPollMs')) -NoDoneX ([bool](Get-Fs3cArg 'S3cNoDone'))
        Write-Output "HOST GIVE-UP: $($dl.GiveUpUtc.ToString('o')) = BootStartUtc $($origin.ToString('o')) + $ddl s - $margin s (device deadline no earlier than $($dl.DeviceDeadlineUtc.ToString('o'))); $([long][Math]::Floor($cv.RemainMs / 1000)) s left after $([long]($nowU - $cliUtc).TotalSeconds) s of preparation"
        $started = $true
        $script:Fs3cCm = Enter-Fs3cConsoleMode                          # build review MAJOR-2 / MINOR-9: Ctrl+C = x, QuickEdit off
        $r = Invoke-Fs3cRun -Transport $t -OutDirX $od -Tokens $tokens -Cfg $cfg -Mode 'live' -PortName $pt -Ui $ui -Keys $keys -Sound $sink -Sounds $snd -UtcBase $nowU -UtcBaseMs $nowMs
        $r | Add-Member NoteProperty ConsoleMode @($script:Fs3cCm.Notes)
        try { Save-Fs3cSessionJson -Result $r -Path (Join-Path $od 'session.json') }
        catch { Write-Output (ConvertTo-FsPrintable "SESSION.JSON NOT WRITTEN: $($_.Exception.Message)") }
        $sp = Save-Fs3cSummary $r $od $false
        Show-Fs3cSummaryOnKey $r $sp $keys $false
    }
    $exitCode = switch ($r.Status) { 'COLLECTED-VALID' { 10 } 'COLLECTED-REJECTED' { 11 } default { 14 } }
} catch {
    Write-Output (ConvertTo-FsPrintable "REFUSED/ERROR: $($_.Exception.Message)")
    $ctx = $script:FsLastCtx
    if (-not $started -or $null -eq $ctx) { Write-Output 'RECOVERY: nothing was sent to the device by this run'; $exitCode = 20 }
    else {
        Write-Output (ConvertTo-FsPrintable "SENT:   $(@($ctx.Sent) -join ' | ')")
        Write-Output (Get-Fs3cErrorRecovery $ctx)
        $exitCode = 70
    }
} finally { Exit-Fs3cConsoleMode $script:Fs3cCm }
exit $exitCode
