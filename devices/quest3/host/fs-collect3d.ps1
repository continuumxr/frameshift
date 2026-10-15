# FrameShift stage-3d serial collector: the interactive, per-phase session on v2.7 (Windows PowerShell 5.1, no modules).
# Design: devices/quest3/stage3d/README.md section 6 and devices/quest3/stage3d/HOST.md. The stage-3c collector
# (fs-collect3c.ps1, DESIGN.md revision 3) is DOT-SOURCED as a library and never edited (it returns early when
# dot-sourced); so are fs-collect.ps1, fs-classify3c.ps1 and fs-session3c.ps1 through it.
#
# LIVE (only with the PM's sign-off; started by fs-observe3d.ps1 -ThenCollect):
#   fs-collect3d.ps1 -S3dPort COM7 -S3dNonce <16 hex> -S3dBootStartUtc <observe.json BootStartUtc>
#                    [-S3dHandoffUtc <observe.json HandoffUtc: evidence only>] -S3dOutDir <new dir>
# REPLAY (offline; a capture plus its index through the same session code):
#   fs-collect3d.ps1 -S3dReplay <capture.raw> [-S3dReplayIndex <idx>] -S3dOutDir <new dir> [-S3dKeyScript <file>] [-S3dReplayPin <64 hex>]
# SOUND CHECK (no headset; J-143): fs-collect3d.ps1 -S3dSoundCheck -S3dOutDir <cycle>: the stage-3c sound check
#   (Invoke-Fs3cSoundCheck) written as <cycle>\soundcheck.json (schema frameshift.fs-soundcheck3d.v1) with its made record
#   (MadeUtc, ToolSetSha256; fs-carry3d.ps1). A rehearsal summary ends with the same record ("REHEARSAL MADE: ...").
# REHEARSALS (no headset; SIGNOFF-3d A, two go/no-go results, both required by fs-checklist3d phase A): a recorded
#   stage-3d session replayed in real time, with the console keys, the real sounds and banners; the summary (behind the
#   s key, as live) prints the go/no-go line of the path rehearsed:
#   the garbled path (reset question, run 2 c c y, run 3):  ...\replay\garbled-r3\capture.raw -S3dOutDir <cycle>\rehearsal
#   the read path, TIMED (review 2 MAJOR-1: run 2 read in both eyes with the 8 characters, the dark check, then per eye
#   the tilt, the F and the bars; the run-2 window is real: the cut-off run-2 end + 110 s):
#                                                           ...\replay\nominal-read\capture.raw -S3dOutDir <cycle>\rehearsal-read
#   fs-collect3d.ps1 -S3dReplay <capture.raw> -S3dOutDir <new dir> -S3dRehearsal -S3dReplayPin f6a9c3e2b1d0a4958877665544332211ffeeddccbbaa99887766554433221100
#   In a rehearsal the console shows the 8 characters of run 2 when run 2 starts (a replay has no picture to read).
# Exit: 10 every phase sent has a VALID record, 11 a record rejected or refused (FSXE1), 14 INCONCLUSIVE, 20 refused to
#   start (nothing sent), 70 internal error. The verdicts are fs-classify3d.ps1's.
#
# ---- the stage-3d differences from fs-collect3c.ps1 (a reviewer diffs the copies against their originals) ----------
#   New-Fs3dCfg       COPY of New-Fs3cCfg: Stage '3d', exp s3d_<ph>, the v0.7.1 pin, kernel 5.10.246-gd7102a837402 (v2.7).
#                     The timing constants are UNCHANGED (README 6.9): PHASE_WORST 23/38/47/39, RunnerMargin 5, Banner 2,
#                     DoneReserve 3, HumanSec 3/20/25/15 -> G 34/68/82/64. H_r1 stays 20 s: the r1 human window now holds the
#                     one reset question (PM J-130), so nothing is recomputed (tools/check-timing-3d.py reads these here).
#   Invoke-Fs3dSession COPY of Invoke-Fs3cSession. Differences: (1) r1 is the NON-LIT reset: its go/end markers print plain
#                     lines, no LOOK/ENDED banner and no START/END sound; x during the reset is an abort (noted at once), n is
#                     discarded (logged); the reset answer's key (y or b; review 2 MINOR-2: never n) is ignored as a repeat
#                     until run 2's go marker and at least 600 ms after the answer (review MAJOR-1: a held or doubled answer
#                     key must not reach run 2; in each poll the keys are read before the markers); elsewhere x and n abort
#                     as in stage 3c (MINOR-4), p0 included; (2) after r1's record: the ONE reset question
#                     (Invoke-Fs3dResetQuestion; recorded, never gating: y and b both lead to run 2; x aborts; n is not an
#                     answer there; a timeout ends the session safely), no per-eye readings and no dark check; no question
#                     when the headset SKIPPED the reset (review 2 MINOR-4: nothing was shown); (3) the LOOK cue after p0
#                     names the reset; (4) runs 2 and 3 use Invoke-Fs3dGap (the per-eye tilt first, a layout-item timeout
#                     skips only that item; review 2 MAJOR-1); (5) the stage label 3d and New-Fs3dInteract (readings3d.txt);
#                     (6) RehearsalShowChars (a rehearsal replay only): run 2's 8 characters printed at its go marker.
#   Invoke-Fs3dRun / Invoke-Fs3dReplay / Write-Fs3dSummary / Save-Fs3dSummary / Show-Fs3dSummaryOnKey: COPIES of the 3c
#                     functions with readings3d.txt, the 3d session and config, and the rehearsal lines
#                     (Get-Fs3dRehearsalLines: the garbled path's 40-s line, or the timed read path's GO/NO-GO).
#   CLI: COPY of the 3c CLI block with the S3d parameter names; DEADLINE 200 / ACK_WINDOW 150 (stage3d/init.sh).
#   Reused unchanged: Invoke-Fs3cPhase, Test-Fs3cGuard, Get-Fs3cP0Integrity, Get-Fs3cReplayTokens, New-Fs3cReplayTransport,
#                     Save-Fs3cSessionJson, Get-Fs3cErrorRecovery, Assert-Fs3cConsole, and everything fs-collect3c.ps1 reuses.
# M4: this file's parameters are named S3d*; they collide with none of fs-collect3c.ps1's (S3c*), fs-collect.ps1's or the
# session's; the bound arguments are snapshotted BEFORE the dot-sources ($script:Fs3dArgs).
[CmdletBinding()]
param(
    [string]$S3dPort = '', [string]$S3dNonce = '', [string]$S3dOutDir = '',
    [string]$S3dReplay = '', [string]$S3dReplayIndex = '', [string]$S3dKeyScript = '',
    [string]$S3dBootStartUtc = '',
    [string]$S3dHandoffUtc = '',
    [int]$S3dHostMarginSec = 15,
    [string]$S3dKernel = '5.10.246-gd7102a837402',
    [string]$S3dPid1 = '/bin/busybox,sh,/init',
    [int]$S3dPollMs = 50,
    [long]$S3dGiveUpMs = -1,
    [switch]$S3dRehearsal,
    [switch]$S3dNoDone,
    [string]$S3dReplayPin = '',
    [switch]$S3dSoundCheck,
    [switch]$S3dParamEcho
)
$script:Fs3dArgs = @{} + $PSBoundParameters
$script:Fs3dInvocation = $MyInvocation.InvocationName
$script:Fs3dDefaults = @{ S3dPort = ''; S3dNonce = ''; S3dOutDir = ''; S3dReplay = ''; S3dReplayIndex = ''; S3dKeyScript = ''; S3dBootStartUtc = ''; S3dHandoffUtc = ''
                          S3dHostMarginSec = 15; S3dKernel = '5.10.246-gd7102a837402'; S3dPid1 = '/bin/busybox,sh,/init'; S3dPollMs = 50; S3dGiveUpMs = [long]-1
                          S3dRehearsal = $false; S3dNoDone = $false; S3dParamEcho = $false; S3dReplayPin = ''; S3dSoundCheck = $false }
function Get-Fs3dArg { param([string]$Name)
    if ($script:Fs3dArgs.ContainsKey($Name)) { $v = $script:Fs3dArgs[$Name]; if ($v -is [System.Management.Automation.SwitchParameter]) { return [bool]$v }; return $v }
    return $script:Fs3dDefaults[$Name]
}
. (Join-Path $PSScriptRoot 'fs-collect3c.ps1')       # the stage-3c collector library (fs-collect.ps1, fs-classify3c.ps1, fs-session3c.ps1)
. (Join-Path $PSScriptRoot 'fs-classify3d.ps1')      # the stage-3d protocol (exp, pin, the reset)
. (Join-Path $PSScriptRoot 'fs-session3d.ps1')       # the stage-3d prompts
. (Join-Path $PSScriptRoot 'fs-carry3d.ps1')         # J-143: the tool set and the made record of a sound check / rehearsal
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Fs3dStageLabel = '3d'

# ------------------------------------------------------------------ config ----
# COPY of New-Fs3cCfg (see the header). G_k = PHASE_WORST_k + RunnerMargin 5 + PostMin_k + DoneReserve 3.
function New-Fs3dCfg {
    param([string]$NonceX, [long]$GiveUpMsX = -1, [long]$AckGiveUpMsX = -1, [string]$KernelX = '5.10.246-gd7102a837402',
          [string]$Pid1X = '/bin/busybox,sh,/init', $TimingX = $null, [int]$PollMsX = 50, [bool]$NoDoneX = $false)
    $c = @{ Nonce = $NonceX; Stage = $script:Fs3dStageLabel; RunVerb = 'fs-phase'; RefusalTag = 'FSXE1'; DeviceDeadlineSec = 200; AckWindowSec = 150
            Kernel = $KernelX; Pid1 = $Pid1X; StepTimeoutMs = 10000; PromptWaitMs = 3000; AckSettleMs = 2500; AckStatusTries = 2; InitialDrainMs = 1000
            NoDone = $NoDoneX; PromptSettleMs = 150; Timing = $TimingX; PollMs = $PollMsX
            RunnerMarginSec = 5; DoneReserveSec = 3; BannerSec = 2; IdleSec = 120; GapCapSec = 110; PromptTimeoutSec = 30; CueMs = 3000; LayoutMinSec = 10
            RehearsalShowChars = $false     # a rehearsal (replay) only: print run 2's 8 characters at its go marker (review 2 MAJOR-1)
            PhaseWorstSec = @{ p0 = 23; r1 = 38; r2 = 47; r3 = 39 }; HumanSec = @{ p0 = 3; r1 = 20; r2 = 25; r3 = 15 }   # unchanged (README 6.9); r1's 20 s holds the reset question
            Exp = $script:S3dExp; Steps = $script:S3dSteps; PatternPin = $script:S3dPatternPin }
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

# ------------------------------------------------------- the session ---------
$script:Fs3dRunName = @{ p0 = 'PHASE 0'; r1 = 'THE DISPLAY RESET'; r2 = 'RUN 2'; r3 = 'RUN 3' }
function Invoke-Fs3dSession {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)]$Capture, [Parameter(Mandatory)][hashtable]$Tokens, [Parameter(Mandatory)][hashtable]$Cfg,
          [Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Keys, [Parameter(Mandatory)]$Sound, [DateTime]$UtcBase = [DateTime]::MinValue, [long]$UtcBaseMs = 0,
          [string]$OutDirX = '')
    $ctx = [pscustomobject]@{ T = $Transport; C = $Capture; Cfg = $Cfg; Sent = (New-Object System.Collections.Generic.List[string])
                              SettledLen = $null; ExpectedPrompt = $null; LastByteMs = [long]-1; PhaseCapMs = $Cfg.AckGiveUpMs }
    $script:FsLastCtx = $ctx
    $X = New-Fs3dInteract -Ctx $ctx -Ui $Ui -Keys $Keys -Sound $Sound -UtcBase $UtcBase -UtcBaseMs $UtcBaseMs -PollMsX $Cfg.PollMs -OutDirX $OutDirX
    $res = [ordered]@{
        Schema = 'frameshift.fs-collect3d.v1'; Stage = $script:Fs3dStageLabel; RunVerb = 'fs-phase'; DeviceDeadlineSec = $Cfg.DeviceDeadlineSec
        GapCapSec = $Cfg.GapCapSec; DoneReserveSec = $Cfg.DoneReserveSec
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
    $st = @{ Known = $false; R2Valid = $false; R2Run = $null; R2Items = $null; EndWhy = $null; Alarm = $false
             RepKey = ''; RepUntil = [long]0; RepGo = $false }     # review MAJOR-1: the reset answer's key, ignored as a repeat
    $s3abort = @{ Noted = $false; Ms = $null; Ph = $null }
    try {
        $null = & {
            $Transport.Open()
            # ---- COPIED from Invoke-FsCollect (pre-runner sequence), unchanged (as in fs-collect3c.ps1) ----
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
            $p = Invoke-FsPhase $ctx 'fs-verify' $Tokens.V $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSV1' } -Tag 'FSV1'
            $phases.Add($p)
            if ($p.State -cne 'complete') { $res.StopReason = Get-FsPhaseStop $p; return }
            $v = Test-FsVerify -Text $p.Completion -Nonce $Cfg.Nonce -Challenge $Tokens.V -Kernel $Cfg.Kernel -Pid1 $Cfg.Pid1
            $res.VerifyReason = $v.Reason
            if (-not $v.Ok) { $res.StopReason = "fs-verify: record does not verify ($($v.Reason))"; return }
            $res.Verified = $true; $res.VerifyRecord = $p.Completion; $res.Kernel = $v.Record['kernel']
            if ($p.Prompt -cne 'prompt') { $res.StopReason = "fs-verify: completed, then prompt $($p.Prompt)"; return }
            $st.Known = $true
            $st.Known = $false
            $p = Invoke-FsPhase $ctx 'fs-ack' $Tokens.A $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSA1' } -Tag 'FSA1'
            $phases.Add($p)
            if ($p.State -cne 'complete') { $res.StopReason = Get-FsPhaseStop $p; return }
            if ($p.Prompt -cne 'prompt') { $res.StopReason = "fs-ack: completed, then prompt $($p.Prompt)"; return }
            $st.Known = $true
            if ($p.Completion -cne 'FSA1 queued END') { $res.StopReason = "fs-ack: refused ($(ConvertTo-FsPrintable $p.Completion))"; return }
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
                $fr = @((Get-FsRecords -Text $p.Completion -Tag 'FSS1') | Where-Object { $_['nonce'] -ceq $Cfg.Nonce })
                if ($fr.Count -and $fr[0]['acked'] -cmatch '^[0-9a-f]{1,64}\z' -and $fr[0]['acked'] -cne $Tokens.A) {
                    $res.ForeignAck = $fr[0]['acked']
                    $res.StopReason = "foreign ack: PID 1 recorded acked=$($fr[0]['acked']), not this collector's token (another host session is attached); no experiment request is sent"
                    return
                }
            }
            if (-not $res.Acked) { $res.StopReason = "ack not recorded by PID 1 after $($Cfg.AckStatusTries) fs-status ($($res.AckReason))"; return }
            $ctx.PhaseCapMs = $null
            # ---- end of the copied pre-runner sequence ----

            # ---- stage 3d: the phases (README 6) ----
            $prevSha = $script:Fs3cZero16
            $s3keys = $Keys; $s3x = $X; $s3abortRef = $s3abort
            foreach ($s3ph in 'p0', 'r1', 'r2', 'r3') {
                $chal = [string]$Tokens.C[$s3ph]
                $name = $script:Fs3dRunName[$s3ph]
                $s3lit = ($s3ph -ceq 'r2' -or $s3ph -ceq 'r3')                 # stage 3d: r1 is NOT lit
                $s3reset = ($s3ph -ceq 'r1')
                $pr = [ordered]@{ Ph = $s3ph; Chal = $chal; Prev = $prevSha; Sent = $false; NotRunWhy = ''; GuardNeedMs = $null; GuardLeftMs = $null
                                  SendMs = $null; SendOffset = $null; DeadlineMs = $null; State = $null; Prompt = $null; CompletedMs = $null; EndMs = $null
                                  SliceStart = $null; SliceEnd = $null; SliceSha256 = $null; Refusal = $null; Fsb1Ok = $null; Fsb1Reason = $null; Fsb1Detail = $null
                                  Sha16 = $null; Markers = @(); MarkerNotes = @(); KeysDiscarded = @(); AbortNoted = $false; GapMode = $null; GapSafe = $null
                                  GapSafeWhy = $null; NextLost = $false; R3Rule = $null; Integrity = $null; Q7Fallback = $null; ResetSeen = $null; LayoutTimeouts = @() }
                $p3.Add($pr)
                if ($s3ph -ceq 'r3') {
                    $dec = Get-Fs3cR3Decision -R2Valid $st.R2Valid -R2Run $st.R2Run -Items $st.R2Items -Chal8 ([string]$Tokens.C['r2']).Substring(0, 8)
                    $pr.R3Rule = $dec; $res.R3Rule = $dec
                    if (-not $dec.Allow) {
                        $pr.NotRunWhy = "run-3 rule: $($dec.Why)"; $st.EndWhy = "RUN 3 NOT REQUESTED ($($dec.Why))"
                        $X.Ui.Line("RUN 3 NOT REQUESTED: $($dec.Why)"); return
                    }
                }
                # keys pressed since the last prompt: x (and n, except before the reset) = abort; anything else discarded and
                # logged. The reset answer's own key (y or b, held or doubled) is ignored as a repeat (review MAJOR-1).
                $now = $X.Now(); $k = $Keys.Read($now)
                while ($null -ne $k) {
                    if ($k -ceq $st.RepKey -and (-not $st.RepGo -or $now -lt $st.RepUntil)) { $X.Event("key-repeat-ignored before $s3ph key=$k (the reset answer's key)") }
                    elseif ($k -ceq 'x' -or ($k -ceq 'n' -and -not $s3reset)) { $s3abort.Noted = $true; $s3abort.Ms = $now; $s3abort.Ph = "before-$s3ph"; $X.Event("abort-noted before $s3ph key=$k") } else { $X.Event("key-discarded before $s3ph key=$k") }
                    $k = $Keys.Read($now)
                }
                if ($s3abort.Noted) {
                    $pr.NotRunWhy = 'abort (x) before this phase'; $st.EndWhy = "ABORT (x) noted: $name is not run"; $st.Alarm = $true
                    $X.Ui.Banner('abort', 'ABORT NOTED', "$name is not run; fs-done follows"); return
                }
                $g = Test-Fs3cGuard -Cfg $Cfg -PhX $s3ph -NowMs $Transport.NowMs()
                $pr.GuardNeedMs = $g.NeedMs; $pr.GuardLeftMs = $g.LeftMs
                if (-not $g.Ok) {
                    $pr.NotRunWhy = "guard: $($g.Why)"; $st.EndWhy = "$name NOT POSSIBLE (guard G = $($Cfg.GuardSec[$s3ph]) s): $($g.Why)"
                    $X.Ui.Line("$name NOT POSSIBLE: not enough time left (guard $($Cfg.GuardSec[$s3ph]) s)"); return
                }
                $st.Known = $false
                $Keys.Arm(@{ p0 = 'g'; r1 = 'i'; r2 = 'j'; r3 = 'k' }[$s3ph], $Transport.NowMs())
                $s3ms = @{ Off = [long]$Capture.Length; InRec = $false; Seen = (New-Object System.Collections.Generic.List[string]); Notes = (New-Object System.Collections.Generic.List[string]); Disc = (New-Object System.Collections.Generic.List[string]) }
                $s3name = $name; $s3nonce = $Cfg.Nonce
                $X.Ui.Line("$name : request sent")
                $onPoll = {
                    param($c, [long]$from)
                    # stage 3d: the keys are read BEFORE the markers of this poll (a key read in the same poll as run 2's go marker
                    # counts as pressed before it: the conservative side for the reset answer's repeat, review MAJOR-1)
                    # keys during the phase: x = abort noted at once (and n, as stage 3c MINOR-4, except during the reset, where the
                    # reset question follows); the reset answer's key until run 2's go marker (and 600 ms after the answer) is a
                    # repeat, ignored (review MAJOR-1); anything else discarded and logged
                    $kn = $c.T.NowMs(); $kk = $s3keys.Read($kn)
                    while ($null -ne $kk) {
                        if ($kk -ceq $st.RepKey -and (-not $st.RepGo -or $kn -lt $st.RepUntil)) { $s3ms.Disc.Add("$kk@$kn"); $s3x.Event("key-repeat-ignored during $s3ph key=$kk (the reset answer's key)") }
                        elseif (($kk -ceq 'x' -or ($kk -ceq 'n' -and -not $s3reset)) -and -not $s3abortRef.Noted) {
                            $s3abortRef.Noted = $true; $s3abortRef.Ms = $kn; $s3abortRef.Ph = $s3ph
                            $why0 = if ($kk -ceq 'n') { 'n (light) taken as x: ' } else { '' }
                            if ($s3lit) { $s3x.Ui.Banner('abort', 'ABORT NOTED - the headset finishes this run (<= 10 s)', "$($why0)look away if you wish; one safety question, then fs-done") }
                            elseif ($s3reset) { $s3x.Ui.Banner('abort', 'ABORT NOTED', 'the reset finishes; one question, then fs-done (no run 2)') }
                            else { $s3x.Ui.Banner('abort', 'ABORT NOTED', "$($why0)nothing is shown; fs-done after this phase") }
                            $s3x.Sound.Play('ALARM', $kn); $s3x.Event("abort-noted during $s3ph key=$kk")
                        } else { $s3ms.Disc.Add("$kk@$kn"); $s3x.Event("key-discarded during $s3ph key=$kk") }
                        $kk = $s3keys.Read($kn)
                    }
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
                                if ($s3ph -ceq 'r2' -and $mk.E -ceq 'go') { $st.RepGo = $true }
                                if ($s3ph -ceq 'r2' -and $mk.E -ceq 'go' -and $Cfg.RehearsalShowChars) { $s3x.Ui.Line("REHEARSAL ONLY: in each eye you would read these 8 characters: $(([string]$Tokens.C['r2']).Substring(0, 8).ToUpperInvariant())") }
                                if ($s3lit) {
                                    switch -CaseSensitive ($mk.E) {
                                        'go'   { $s3x.Ui.Banner('look', "$s3name STARTING - LOOK", 'keep looking into the lenses until RUN ENDED'); $s3x.Sound.Play('START', $s3x.Now()) }
                                        'end'  { $s3x.Ui.Banner('ended', "$s3name ENDED", 'the panels should be off; questions follow in a moment'); $s3x.Sound.Play('END', $s3x.Now()) }
                                        'skip' { $s3x.Ui.Banner('info', "$s3name SKIPPED", 'nothing is shown in this run') }
                                    }
                                } elseif ($s3reset) {
                                    switch -CaseSensitive ($mk.E) {      # stage 3d: the reset is not lit: plain lines, no LOOK banner, no sound
                                        'go'   { $s3x.Ui.Line('DISPLAY RESET running (it should stay dark)') }
                                        'end'  { $s3x.Ui.Line('DISPLAY RESET finished') }
                                        'skip' { $s3x.Ui.Line('DISPLAY RESET SKIPPED by the headset') }
                                    }
                                }
                            }
                        }
                    }
                }
                $p = Invoke-Fs3cPhase $ctx 'fs-phase' "$s3ph $chal $prevSha" ([int](($Cfg.PhaseWorstSec[$s3ph] + 5) * 1000)) {
                    param($L)
                    $e = Find-FsFsb1End $L
                    $f = Find-FsRecordLine $L 'FSXE1'
                    if ($null -eq $e) { return $f }
                    if ($null -eq $f) { return $e }
                    if ($f.Index -lt $e.Index) { return $f } else { return $e }
                } -Tag 'FSB1' -OnPoll $onPoll -NextWake { $s3keys.NextDueMs($Transport.NowMs()) }
                $phases.Add($p)
                $pr.Markers = $s3ms.Seen.ToArray(); $pr.MarkerNotes = $s3ms.Notes.ToArray(); $pr.KeysDiscarded = $s3ms.Disc.ToArray(); $pr.AbortNoted = ($s3abort.Noted -and $s3abort.Ph -ceq $s3ph)
                if ($p.State -ceq 'not-sent') { $pr.NotRunWhy = "send gate: $($p.Gate)"; $res.StopReason = Get-FsPhaseStop $p; return }
                $pr.Sent = $true; $pr.SendMs = $p.SendMs; $pr.SendOffset = $p.SendOffset; $pr.DeadlineMs = $p.DeadlineMs; $pr.State = $p.State; $pr.Prompt = $p.Prompt; $pr.CompletedMs = $p.CompletedMs
                $pr.EndMs = $Transport.NowMs(); $pr.SliceStart = $p.SendOffset; $pr.SliceEnd = $Capture.Length
                $Capture.NoteEvent("phase-end p=$s3ph state=$($p.State) prompt=$(if ($p.Prompt) { $p.Prompt } else { '-' })", $Transport.NowMs())
                [byte[]]$slice = $Capture.Bytes($p.SendOffset)
                $pr.SliceSha256 = Get-FsSha256Hex $slice
                if ($p.State -cne 'complete') {
                    $st.EndWhy = "$name : no complete record by the phase deadline ($($p.State)); nothing more is sent"; $res.StopReason = (Get-FsPhaseStop $p) + ' (no complete record by the phase deadline)'
                    $X.Ui.Banner('abort', "NO RECORD FOR $name BY ITS DEADLINE", 'LOOK AWAY and wait: the headset recovers by itself (idle limit, or the deadline)'); $X.Sound.Play('ALARM', $X.Now())
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
                    $st.EndWhy = "$name : completed, then prompt $($p.Prompt): no questions, nothing more is sent"; $res.StopReason = "fs-phase $($s3ph): completed, then prompt $($p.Prompt): fs-done not sent"
                    $X.Ui.Banner('abort', 'SHELL STATE UNKNOWN', 'LOOK AWAY and wait: the headset recovers by itself (idle limit, or the deadline)'); $X.Sound.Play('ALARM', $X.Now())
                    return
                }
                $st.Known = $true
                $ranOrValid = ($null -eq $pr.Refusal -or $pr.Refusal.Ran -eq 1)
                # review 2 MINOR-4: a reset the headset SKIPPED (a valid record whose reset step is a skip) showed nothing and
                # changed nothing: no question (the classifier reads the skip from the record; r2 is gated off by the device)
                $s3skipped = $false
                if ($s3reset -and $valid) { $s3skipped = ((Get-Fs3dReset @($dec.Steps)[1] $chal.Substring(0, 8)).Kind -ceq 'skip') }
                if ($s3skipped) {
                    $pr.GapMode = 'reset-skipped'; $X.Event('reset-question not asked: the headset skipped the display reset')
                    $X.Ui.Line('DISPLAY RESET SKIPPED by the headset: no question (nothing was shown).')
                } elseif ($s3reset -and $ranOrValid) {
                    # stage 3d (PM J-130): the ONE recorded, non-gating question after the reset
                    $rq = Invoke-Fs3dResetQuestion -X $X -LastEndMs $pr.EndMs -GiveUpMsX $Cfg.GiveUpMs -DoneReserveSec $Cfg.DoneReserveSec -GapCapSec $Cfg.GapCapSec `
                        -PromptTimeoutSec $Cfg.PromptTimeoutSec -NextGuardMs ([long]$Cfg.GuardSec['r2'] * 1000) -AbortNoted $pr.AbortNoted
                    $pr.GapMode = 'reset-question'; $pr.GapSafe = $rq.Safe; $pr.GapSafeWhy = $rq.SafeWhy; $pr.NextLost = $rq.NextLost; $pr.ResetSeen = $rq.Item.Obs
                    if ($rq.Item.AnswerMs -ge 0 -and @('y', 'b') -ccontains [string]$rq.Item.Key) { $st.RepKey = [string]$rq.Item.Key; $st.RepUntil = [long]$rq.Item.AnswerMs + $script:Fs3cRepeatMs }
                    if ($null -ne $rq.Safe) {
                        $st.EndWhy = "SAFE FINISH after the display reset: $($rq.SafeWhy)"; if ($rq.Safe -cne 'stray') { $st.Alarm = $true }
                        $X.Ui.Banner('abort', 'SAFE FINISH - no further run', $rq.SafeWhy)
                        return
                    }
                } elseif ($s3lit -and $ranOrValid) {
                    $mode = if ($pr.AbortNoted) { 'darkonly' } elseif ($valid) { 'full' } else { 'readings' }
                    $nextPh = @{ r2 = 'r3'; r3 = '' }[$s3ph]
                    $ng = if ($nextPh) { [long]$Cfg.GuardSec[$nextPh] * 1000 } else { [long]0 }
                    $q7sb = $null
                    if ($s3ph -ceq 'r2' -and $valid) {
                        $s3q7Run = $st.R2Run; $s3q7C8 = ([string]$Tokens.C['r2']).Substring(0, 8)
                        $q7sb = { param($items) (Get-Fs3cR3Decision -R2Valid $true -R2Run $s3q7Run -Items $items -Chal8 $s3q7C8).Allow }
                    }
                    $gap = Invoke-Fs3dGap -X $X -Ph $s3ph -Mode $mode -Layout ($s3ph -ceq 'r2' -and $valid) -LastEndMs $pr.EndMs -GiveUpMsX $Cfg.GiveUpMs `
                        -DoneReserveSec $Cfg.DoneReserveSec -GapCapSec $Cfg.GapCapSec -PromptTimeoutSec $Cfg.PromptTimeoutSec -LayoutMinSec $Cfg.LayoutMinSec -NextName $nextPh -NextGuardMs $ng -BarsQ7 $q7sb
                    $pr.GapMode = $mode; $pr.GapSafe = $gap.Safe; $pr.GapSafeWhy = $gap.SafeWhy; $pr.NextLost = $gap.NextLost
                    $pr.LayoutTimeouts = @($gap.LayoutTimeouts)
                    if (@($gap.BarsQ7).Count) { $pr.Q7Fallback = [ordered]@{ Items = @($gap.BarsQ7); Note = 'not asked (Q7 fallback)'; Why = 'run-3 path: DESIGN 5.8 rules 1-4 held after the dark check (DESIGN 15 Q7)' } }
                    if ($s3ph -ceq 'r2') { $st.R2Items = $gap.Items }
                    if ($null -ne $gap.Safe) {
                        $st.EndWhy = "SAFE FINISH after $($name): $($gap.SafeWhy)"; if ($gap.Safe -cne 'stray') { $st.Alarm = $true }
                        $X.Ui.Banner('abort', 'SAFE FINISH - no further run', $gap.SafeWhy)
                        return
                    }
                }
                if ($null -ne $pr.Refusal) { $st.EndWhy = "$name REFUSED by the headset ($($pr.Refusal.Raw)): no further run"; $st.Alarm = $true; return }
                if (-not $valid) { $st.EndWhy = "$name : the record is not valid ($($pr.Fsb1Reason)): no further run"; $st.Alarm = $true; return }
                if ($s3abort.Noted) { $st.EndWhy = "ABORT (x) noted during $($name): no further run"; $st.Alarm = $true; return }
                if ($s3ph -ceq 'p0') {
                    $ig = Get-Fs3cP0Integrity -StepList @($dec.Steps) -Pin $Cfg.PatternPin
                    $pr.Integrity = [ordered]@{ Ok = $ig.Ok; Class = $ig.Class; Why = (ConvertTo-FsPrintable $ig.Why) }
                    $X.Event("p0-integrity $($ig.Class)")
                    if (-not $ig.Ok) {
                        $st.EndWhy = "NOTHING RUNS (integrity): $($ig.Class)"; $st.Alarm = $true
                        $X.Ui.Banner('abort', 'NOTHING RUNS (integrity)', 'the pattern program on the headset is not the reviewed one; nothing is shown; fs-done follows'); return
                    }
                }
                $prevSha = $pr.Sha16
                if ($s3ph -ceq 'p0') {
                    $X.Ui.Banner('look', 'LOOK INTO THE LENSES NOW', 'the display reset follows (it should stay dark), then one question, then RUN 2 (10 s)')
                    $X.Sound.Play('START', $X.Now()); $X.Event('look-cue')
                    $Keys.Arm('c', $Transport.NowMs())
                    $u = [Math]::Min($Transport.NowMs() + $Cfg.CueMs, $Cfg.GiveUpMs)
                    while ($Transport.NowMs() -lt $u) {
                        $X.Poll()
                        $kk = $Keys.Read($Transport.NowMs())
                        while ($null -ne $kk) { if ($kk -ceq 'x' -or $kk -ceq 'n') { $s3abort.Noted = $true; $s3abort.Ms = $Transport.NowMs(); $s3abort.Ph = 'cue'; $X.Event("abort-noted during cue key=$kk") } else { $X.Event("key-discarded during cue key=$kk") }; $kk = $Keys.Read($Transport.NowMs()) }
                        $X.Idle($u)
                    }
                    if ($s3abort.Noted) { $st.EndWhy = 'ABORT (x) noted during the LOOK cue: nothing is run'; $st.Alarm = $true; $X.Ui.Banner('abort', 'ABORT NOTED', 'nothing is run; fs-done follows'); $X.Sound.Play('ALARM', $X.Now()); return }
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
        if ($st.Known -and $res.Verified -and -not $Cfg.NoDone) {
            $ctx.PhaseCapMs = $null
            try {
                $p = Invoke-FsPhase $ctx 'fs-done' '' $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSD1' } -Tag 'FSD1' -NoPrompt
                $phases.Add($p)
                if ($p.State -ceq 'not-sent') { $res.DoneReply = Get-FsPhaseStop $p }
                else { $res.DoneSent = $true; $res.DoneReply = if ($p.State -ceq 'complete') { ConvertTo-FsPrintable $p.Completion } else { $p.State } }
            } catch { $res.DoneReply = 'error: ' + (ConvertTo-FsPrintable $_.Exception.Message) }
        }
        if ($res.DoneSent) {
            $la = @($Sound.Played | Where-Object { $_ -like 'ALARM@*' } | ForEach-Object { [long]($_.Split('@')[1]) }) | Select-Object -Last 1
            if ($null -ne $la) { $u = $la + 1000; while ($Transport.NowMs() -lt $u) { $Transport.Idle($u) } }
            $X.Sound.Play('FINISH', $X.Now())
            $X.Ui.Banner('abort', 'FINISH: fs-done sent', 'the headset reboots to fastboot (about 1 s); do not touch anything else')
        } elseif ($res.Verified) {
            $X.Sound.Play('ALARM', $X.Now())
            $X.Ui.Banner('abort', 'NO fs-done (state unknown or gated)', 'LOOK AWAY and wait: the headset recovers by itself (idle limit 120 s, or T0 + 200 s)')
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

# ------------------------------------------------------- Invoke-Fs3dRun ------
# COPY of Invoke-Fs3cRun with the stage-3d session and readings3d.txt.
function Invoke-Fs3dRun {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)][string]$OutDirX, [Parameter(Mandatory)][hashtable]$Tokens, [Parameter(Mandatory)][hashtable]$Cfg,
          [string]$Mode, [string]$PortName = '-', [Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Keys, [Parameter(Mandatory)]$Sound, [Parameter(Mandatory)]$Sounds,
          [DateTime]$UtcBase = [DateTime]::MinValue, [long]$UtcBaseMs = 0)
    $cap = New-FsCapture -Dir $OutDirX -Nonce $Cfg.Nonce -Mode $Mode -PortName $PortName
    $r = Invoke-Fs3dSession -Transport $Transport -Capture $cap -Tokens $Tokens -Cfg $Cfg -Ui $Ui -Keys $Keys -Sound $Sound -UtcBase $UtcBase -UtcBaseMs $UtcBaseMs -OutDirX $OutDirX
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
    $rd = Join-Path $OutDirX 'readings3d.txt'
    [IO.File]::WriteAllText($rd, ((@($r.Readings) | ForEach-Object { "$_`n" }) -join ''), (New-Object System.Text.UTF8Encoding($false)))
    $o.ReadingsFile = $rd
    [pscustomobject]$o
}

# COPY of Invoke-Fs3cReplay with New-Fs3dCfg and Invoke-Fs3dRun.
function Invoke-Fs3dReplay {
    param([Parameter(Mandatory)][string]$RawPath, [string]$IndexPath, [Parameter(Mandatory)][string]$OutDirX, [string]$NonceX = '',
          [hashtable]$Overrides = @{}, $Ui = $null, $Keys = $null, $Sound = $null, $Sounds = $null, [switch]$Paced)
    if (-not $IndexPath) { $IndexPath = "$RawPath.idx" }
    [byte[]]$raw = [IO.File]::ReadAllBytes($RawPath)
    $ix = Read-FsCaptureIndex -Path $IndexPath -RawLength $raw.Length
    if ($NonceX -and $NonceX -cne $ix.Nonce) { throw "refused: -S3dNonce $NonceX differs from the index nonce $($ix.Nonce)" }
    $cfg = New-Fs3dCfg -NonceX $ix.Nonce
    foreach ($k in $Overrides.Keys) {
        if (@('Stage', 'RunVerb', 'RefusalTag', 'GuardSec') -ccontains $k) { continue }
        if (-not $cfg.ContainsKey($k)) { throw "unknown setting $k" }; $cfg[$k] = $Overrides[$k]
    }
    if ($null -eq $Sounds) { $Sounds = New-Fs3cSounds }
    if ($null -eq $Ui) { $Ui = New-Fs3cUi -Kind record }
    if ($null -eq $Keys) { $Keys = New-Fs3cScriptedKeySource -Script @() }
    if ($null -eq $Sound) { $Sound = New-Fs3cSoundSink -Kind record -Sounds $Sounds }
    $t = New-Fs3cReplayTransport -Raw $raw -Index $ix -PollMsX $cfg.PollMs -Paced:$Paced
    $tk = Get-Fs3cReplayTokens $ix
    $base = if ($Paced) { [DateTime]::UtcNow } else { [DateTime]::Parse('2026-10-13T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
    $r = Invoke-Fs3dRun -Transport $t -OutDirX $OutDirX -Tokens $tk -Cfg $cfg -Mode 'replay' -Ui $Ui -Keys $Keys -Sound $Sound -Sounds $Sounds -UtcBase $base -UtcBaseMs 0
    $r | Add-Member NoteProperty ReplaySource ([ordered]@{ Raw = $RawPath; Sha256 = (Get-FsSha256Hex $raw); Index = $IndexPath })
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

# The rehearsal lines (SIGNOFF-3d A). The path is read from the answers:
#   - the garbled path (run 3 ran or the Q7 fallback): the reset question plus the run-2 answers within 40 s, as stage 3c;
#   - the read path (review 2 MAJOR-1, TIMED): both eyes READ with 8 characters, the dark check y, and per eye the tilt, the
#     F and the bars answered (none TIMEOUT / NOT_ASKED / ABORT), the last answer at least 10 s (LayoutMinSec) before the
#     run-2 cut-off (min(give-up - 3 s, run-2 end + 110 s), as the live session computes it).
function Get-Fs3dRehearsalLines { param($r)
    $ic = [Globalization.CultureInfo]::InvariantCulture
    $out = New-Object System.Collections.Generic.List[string]
    $r2 = @($r.ReadingObjs | Where-Object { $_.Ph -ceq 'r2' }); $r3 = @($r.ReadingObjs | Where-Object { $_.Ph -ceq 'r3' })
    $q7 = @($r.Phases | Where-Object { $_.Ph -ceq 'r2' -and $_.PSObject.Properties['Q7Fallback'] -and $null -ne $_.Q7Fallback }).Count -gt 0     # the run-3 path (review 3 N1)
    $span = { param($it) $a = @($it | Where-Object { $_.AnswerMs -ge 0 } | ForEach-Object { $_.AnswerMs } | Sort-Object -Descending); $p0m = @($it | ForEach-Object { $_.PromptMs } | Sort-Object)[0]
              if ($a.Count) { ($a[0] - $p0m) / 1000.0 } else { 0.0 } }
    if ($r3.Count -gt 0 -or $q7) {
        $sum = 0.0
        foreach ($ph in 'r1', 'r2') {
            $it = @($r.ReadingObjs | Where-Object { $_.Ph -ceq $ph })
            if ($it.Count -eq 0) { $out.Add("REHEARSAL: no $ph answers"); continue }
            $d = & $span $it
            $sum += $d; $out.Add([string]::Format($ic, "REHEARSAL: {0} answers took {1:0.0} s", $(if ($ph -ceq 'r1') { 'reset question' } else { 'run-2' }), $d))
        }
        $out.Add([string]::Format($ic, "REHEARSAL: reset plus run-2 answers {0:0.0} s; go/no-go (SIGNOFF-3d A): {1}", $sum, $(if ($sum -le 40.0) { 'GO (<= 40 s)' } else { 'NO-GO (> 40 s): stop and report' })))
        return $out.ToArray()
    }
    # the read path
    $want = @('left', 'right', 'dark', 'tilt_left', 'orient_left', 'bars_left', 'tilt_right', 'orient_right', 'bars_right')
    $by = @{}; foreach ($x in $r2) { $by[[string]$x.Item] = $x }
    $bad = @($want | Where-Object { -not $by.ContainsKey($_) -or @('TIMEOUT', 'NOT_ASKED', 'ABORT') -ccontains [string]$by[$_].Obs })
    $eyesOk = ($by.ContainsKey('left') -and $by['left'].Obs -ceq 'READ' -and $by.ContainsKey('right') -and $by['right'].Obs -ceq 'READ' -and $by.ContainsKey('dark') -and $by['dark'].Obs -ceq 'DARK_NOW')
    $p2 = @($r.Phases | Where-Object { $_.Ph -ceq 'r2' -and $_.Sent })
    if ($r2.Count -eq 0 -or $p2.Count -eq 0) { $out.Add('REHEARSAL (read path): no run-2 answers; go/no-go (SIGNOFF-3d A): NO-GO: stop and report'); return $out.ToArray() }
    # review 3 MINOR-1: the cut-off from the session's own constants, and which bound applied
    $dr = if ($r.PSObject.Properties['DoneReserveSec'] -and $null -ne $r.DoneReserveSec) { [long]$r.DoneReserveSec } else { 3 }
    $gc = if ($r.PSObject.Properties['GapCapSec'] -and $null -ne $r.GapCapSec) { [long]$r.GapCapSec } else { 110 }
    $cutG = [long]$r.GiveUpMs - $dr * 1000; $cutE = [long]$p2[0].EndMs + $gc * 1000
    $cut = [Math]::Min($cutG, $cutE); $cutWhy = if ($cutE -le $cutG) { "run-2 end + $gc s" } else { "give-up - $dr s" }
    $last = @($r2 | Where-Object { $_.AnswerMs -ge 0 } | ForEach-Object { [long]$_.AnswerMs } | Sort-Object -Descending)
    $spare = if ($last.Count) { ($cut - $last[0]) / 1000.0 } else { 0.0 }
    $d = & $span $r2
    $out.Add([string]::Format($ic, "REHEARSAL (read path): run-2 answers took {0:0.0} s from the first prompt; {1} of {2} items answered{3}", $d, ($want.Count - $bad.Count), $want.Count, $(if ($bad.Count) { ' (not: ' + ($bad -join ', ') + ')' } else { '' })))
    foreach ($e in 'left', 'right') {
        $t = foreach ($k in "tilt_$e", "orient_$e", "bars_$e") { if ($by.ContainsKey($k) -and $by[$k].AnswerMs -ge 0) { [string]::Format($ic, '{0} {1:0.0} s', $k.Split('_')[0], ($by[$k].AnswerMs - $by[$k].PromptMs) / 1000.0) } else { "$($k.Split('_')[0]) -" } }
        $c0 = if ($by.ContainsKey($e) -and $by[$e].AnswerMs -ge 0) { [string]::Format($ic, '{0:0.0} s', ($by[$e].AnswerMs - $by[$e].PromptMs) / 1000.0) } else { '-' }
        $out.Add("REHEARSAL (read path): $e eye: reading and characters $c0; $($t -join '; ')")
    }
    $go = ($bad.Count -eq 0 -and $eyesOk -and $spare -ge 10.0)
    $out.Add([string]::Format($ic, "REHEARSAL (read path): the last answer {0:0.0} s before the cut-off ({2}); go/no-go (SIGNOFF-3d A): {1}", $spare,
        $(if ($go) { 'GO (every item answered, at least 10 s to spare)' } elseif (-not $eyesOk) { 'NO-GO (both eyes d with the 8 characters and the dark check y are needed): repeat or report' } else { 'NO-GO (an item not answered or less than 10 s to spare): repeat or report' }), $cutWhy))
    $out.ToArray()
}
# COPY of Write-Fs3cSummary: the stage-3d wording; the rehearsal lines (Get-Fs3dRehearsalLines) name the path rehearsed.
# J-143 (review of 14107af, MAJOR-1): a rehearsal summary ends with its made record (UTC time, the tool-set SHA-256 and,
# delta review MINOR-1, the replay rehearsed: its SHA-256 and path; fs-carry3d.ps1). $Made @{ Utc; ToolSet; Replay;
# ReplaySha } overrides (fixtures); else now, this repository's tool set, and the replay's own SHA-256.
function Write-Fs3dSummary { param($r, [bool]$Rehearsal = $false, $Made = $null)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("STATUS: $($r.Status)")
    if ($r.StopReason) { $out.Add("STOP:   $($r.StopReason)") }
    if ($r.EndReason) { $out.Add("END:    $($r.EndReason)") }
    $out.Add("SENT:   $(@($r.Sent) -join ' | ')")
    foreach ($p in @($r.Phases)) {
        if (-not $p.Sent) { $out.Add("PHASE $($p.Ph): not run ($($p.NotRunWhy))"); continue }
        $f = if ($null -ne $p.Refusal) { "REFUSED $($p.Refusal.Raw)" } elseif ($null -ne $p.Fsb1Ok) { if ($p.Fsb1Ok) { 'FSB1 VALID' } else { "FSB1 REJECT $($p.Fsb1Reason) $($p.Fsb1Detail)" } } else { "no complete record ($($p.State))" }
        $out.Add("PHASE $($p.Ph): $f; guard left $([long]($p.GuardLeftMs / 1000)) s of $([long]($p.GuardNeedMs / 1000)) s; markers $(@($p.Markers) -join ',')$(if (@($p.MarkerNotes).Count) { ' (' + (@($p.MarkerNotes) -join '; ') + ')' })$(if ($p.PSObject.Properties['ResetSeen'] -and $p.ResetSeen) { "; reset seen: $($p.ResetSeen)" })$(if ($p.GapSafe) { "; questions ended: $($p.GapSafeWhy)" })$(if ($p.PSObject.Properties['LayoutTimeouts'] -and @($p.LayoutTimeouts).Count) { "; timed out (skipped): $(@($p.LayoutTimeouts) -join ', ')" })$(if ($p.PSObject.Properties['Q7Fallback'] -and $null -ne $p.Q7Fallback) { "; $(@($p.Q7Fallback.Items) -join ', ') $($p.Q7Fallback.Note)" })")
    }
    if ($null -ne $r.R3Rule) { $out.Add("RUN-3 RULE: $(if ($r.R3Rule.Allow) { 'held' } else { $r.R3Rule.Why })") }
    $out.Add("CAPTURE: $($r.Capture.Path) bytes=$($r.Capture.Bytes) sha256=$($r.Capture.Sha256) consistent=$($r.Capture.Consistent) slices=$($r.SlicesConsistent)")
    if ($r.CaptureError) { $out.Add("CAPTURE ERROR: $($r.CaptureError)") }
    $out.Add("READINGS: $($r.ReadingsFile) ($(@($r.Readings).Count) FSR2 lines)")
    if (-not $r.DoneSent) { $out.Add("RECOVERY: fs-done NOT sent (state unknown, unverified or gated): the idle limit (120 s after the last activity) or the PID 1 deadline (T0+$($r.DeviceDeadlineSec) s, backstop +1 s) reboots the headset") }
    else { $out.Add("RECOVERY: fs-done sent; reply: $($r.DoneReply)") }
    if ($Rehearsal) { foreach ($l in @(Get-Fs3dRehearsalLines $r)) { $out.Add($l) } }
    $out.Add("THEN: fs-classify3d.ps1 -C3dDir <this dir> -C3dObserveDir <observe dir>   (after the PM's free-text description is in notes.txt)")
    if ($Rehearsal) {
        $mu = if ($null -ne $Made -and $Made.ContainsKey('Utc')) { [DateTime]$Made.Utc } else { [DateTime]::UtcNow }
        $mt = if ($null -ne $Made -and $Made.ContainsKey('ToolSet')) { [string]$Made.ToolSet } else { (Get-FsCarry3dToolSet).Sha256 }
        $mp = if ($null -ne $Made -and $Made.ContainsKey('Replay')) { [string]$Made.Replay } else { '' }
        $ms = if ($null -ne $Made -and $Made.ContainsKey('ReplaySha')) { [string]$Made.ReplaySha } elseif ($mp) { Get-FsCarry3dSha $mp } else { '' }
        $out.Add((Get-FsCarry3dRecordLine $mu $mt $ms $mp))
    }
    foreach ($l in $out) { Write-Output (ConvertTo-FsPrintable $l) }
}
function Save-Fs3dSummary { param($r, [string]$Dir, [bool]$Rehearsal = $false, $Made = $null)
    $p = Join-Path $Dir 'summary.txt'
    [IO.File]::WriteAllText($p, ((@(Write-Fs3dSummary $r $Rehearsal $Made) | ForEach-Object { "$_`n" }) -join ''), (New-Object System.Text.UTF8Encoding($false)))
    $p
}
function Show-Fs3dSummaryOnKey { param($r, [string]$Path, $Keys, [bool]$Rehearsal = $false)
    Write-Output "SESSION OVER. The machine summary is in $Path. It is not shown before your answers and notes.txt are done."
    Write-Output 'Press s to show it here now, or x to leave it in the file.'
    $null = $Keys.Drain(0)
    while ($true) {
        $k = $Keys.Read(0)
        if ($k -ceq 's') { foreach ($l0 in [IO.File]::ReadAllLines($Path)) { Write-Output $l0 }; return }      # the saved summary as written (with its made record)
        if ($k -ceq 'x') { Write-Output "(not shown; it is in $Path)"; return }
        Start-Sleep -Milliseconds 100
    }
}

# ------------------------------------------------------------------ CLI -----
if ($script:Fs3dInvocation -eq '.') { return }
if (Get-Fs3dArg 'S3dParamEcho') {
    $live = [ordered]@{}; foreach ($n in @($script:Fs3dDefaults.Keys | Sort-Object)) { $v = Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue; if ($v -is [System.Management.Automation.SwitchParameter]) { $v = [bool]$v }; $live[$n] = $v }
    $snap = [ordered]@{}; foreach ($n in @($script:Fs3dDefaults.Keys | Sort-Object)) { $snap[$n] = Get-Fs3dArg $n }
    Write-Output (([pscustomobject]@{ Snapshot = $snap; Live = $live; StageLabel = $script:Fs3dStageLabel; Exp = $script:S3dExp['r1']; Pin = $script:S3dPatternPin; FsPhaseVerb = $script:FsCmdSpec['fs-phase'] }) | ConvertTo-Json -Depth 4 -Compress)
    exit 0
}
$exitCode = 70; $r = $null; $started = $false; $script:Fs3dCm = $null; $soundExit = $null
try {
    $od = [string](Get-Fs3dArg 'S3dOutDir')
    if (-not $od) { throw 'refused: -S3dOutDir is required (a new directory)' }
    if (Get-Fs3dArg 'S3dSoundCheck') {
        # J-143 (review of 14107af, MAJOR-1): the stage-3c sound check (Invoke-Fs3cSoundCheck, unchanged), written as
        # <dir>\soundcheck.json with the stage-3d schema and its made record (MadeUtc: the UTC time it was written, just after it ended; the tool-set SHA-256)
        if ([string](Get-Fs3dArg 'S3dReplay') -or [string](Get-Fs3dArg 'S3dPort')) { throw 'refused: -S3dSoundCheck takes only -S3dOutDir' }
        $snd = New-Fs3cSounds; $ui = New-Fs3cUi -Kind console; Assert-Fs3cConsole
        $started = $true
        $script:Fs3dCm = Enter-Fs3cConsoleMode
        $xx = New-Fs3cInteract -Ui $ui -Keys (New-Fs3cConsoleKeySource) -Sound (New-Fs3cSoundSink -Kind live -Sounds $snd)
        $res = Invoke-Fs3cSoundCheck -X $xx -Sounds $snd
        $doc = [ordered]@{}; foreach ($pp in $res.PSObject.Properties) { $doc[$pp.Name] = $pp.Value }
        $doc.Schema = $script:FsCarry3dSoundSchema; $doc.Stage = '3d'; $doc.MadeUtc = [DateTime]::UtcNow.ToString('o'); $doc.ToolSetSha256 = (Get-FsCarry3dToolSet).Sha256
        if (-not (Test-Path -LiteralPath $od)) { $null = New-Item -ItemType Directory -Path $od }
        $sp = Join-Path $od 'soundcheck.json'
        [IO.File]::WriteAllText($sp, ((([pscustomobject]$doc) | ConvertTo-Json -Depth 6) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "soundcheck.json: $sp"
        $soundExit = $(if ($res.Pass) { 0 } else { 1 })
    } else {
    $rp = [string](Get-Fs3dArg 'S3dReplay'); $pt = [string](Get-Fs3dArg 'S3dPort'); $nx = [string](Get-Fs3dArg 'S3dNonce')
    $margin = [int](Get-Fs3dArg 'S3dHostMarginSec')
    if ($rp) {
        if ($pt) { throw 'refused: -S3dPort and -S3dReplay are exclusive' }
        $reh = [bool](Get-Fs3dArg 'S3dRehearsal')
        $ov = @{ Kernel = [string](Get-Fs3dArg 'S3dKernel'); Pid1 = [string](Get-Fs3dArg 'S3dPid1'); PollMs = [int](Get-Fs3dArg 'S3dPollMs'); NoDone = [bool](Get-Fs3dArg 'S3dNoDone')
                 GiveUpMs = [long]((200 - $margin) * 1000); AckGiveUpMs = [long]((150 - $margin) * 1000) }
        if ([long](Get-Fs3dArg 'S3dGiveUpMs') -ge 0) { $ov.GiveUpMs = [long](Get-Fs3dArg 'S3dGiveUpMs') }
        $pinR = [string](Get-Fs3dArg 'S3dReplayPin')
        if ($pinR) { if ($pinR -cnotmatch '^[0-9a-f]{64}\z') { throw 'refused: -S3dReplayPin is 64 lowercase hex' }; $ov.PatternPin = $pinR }
        if ($reh) {
            $ov.RehearsalShowChars = $true
            # review 3 MINOR-1: the live give-up is about 160 s after the collector starts (the stage-3c runs: 160.5 s, 159.0 s),
            # not the replay's 185 s: a rehearsal uses 160 s unless -S3dGiveUpMs is given
            if ([long](Get-Fs3dArg 'S3dGiveUpMs') -lt 0) { $ov.GiveUpMs = [long]160000 }
        }
        $snd = New-Fs3cSounds
        $ui = New-Fs3cUi -Kind console
        if ($reh) { Assert-Fs3cConsole; $keys = New-Fs3cConsoleKeySource; $sink = New-Fs3cSoundSink -Kind live -Sounds $snd }
        else {
            $ksf = [string](Get-Fs3dArg 'S3dKeyScript')
            $kl = if ($ksf) { [IO.File]::ReadAllLines($ksf) } else { @() }
            $keys = New-Fs3cScriptedKeySource -Script $kl; $sink = New-Fs3cSoundSink -Kind record -Sounds $snd
        }
        $started = $true
        if ($reh) { $script:Fs3dCm = Enter-Fs3cConsoleMode }
        $r = Invoke-Fs3dReplay -RawPath $rp -IndexPath ([string](Get-Fs3dArg 'S3dReplayIndex')) -OutDirX $od -NonceX $nx -Overrides $ov -Ui $ui -Keys $keys -Sound $sink -Sounds $snd -Paced:$reh
        if (@($r.Replay.Divergence).Count) { Write-Output (ConvertTo-FsPrintable "REPLAY DIVERGENCE: $(@($r.Replay.Divergence) -join '; ')") }
        if ($reh) { $sp = Save-Fs3dSummary $r $od $true @{ Replay = $rp }; Show-Fs3dSummaryOnKey $r $sp $keys $true }
        else { Write-Fs3dSummary $r $reh }
    } else {
        if ($pt -cnotmatch '^COM[0-9]{1,3}\z') { throw 'refused: -S3dPort must be given explicitly as COMn (never chosen automatically)' }
        if ($nx -cnotmatch '^[0-9a-f]{16}\z') { throw 'refused: -S3dNonce must be the image nonce (16 lowercase hex)' }
        if ([string](Get-Fs3dArg 'S3dReplayPin')) { throw 'refused: -S3dReplayPin is for a replay only (a live session uses the built-in fs-pattern v0.7.1 pin)' }
        $bsu = [string](Get-Fs3dArg 'S3dBootStartUtc'); $hou = [string](Get-Fs3dArg 'S3dHandoffUtc')
        if (-not $bsu) { throw 'refused: -S3dBootStartUtc (observe.json BootStartUtc, taken just before fastboot boot was invoked) is required: it is the budget origin; -S3dHandoffUtc is evidence only (FS-R-007 B1)' }
        $parseU = { param([string]$v) [DateTime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        $origin = & $parseU $bsu
        $hoEv = $null
        if ($hou) { $hoEv = & $parseU $hou; if ($hoEv -lt $origin) { throw 'refused: -S3dHandoffUtc precedes -S3dBootStartUtc (inconsistent observer times)' } }
        $cliUtc = [DateTime]::UtcNow
        if ($origin -gt $cliUtc) { throw "refused: -S3dBootStartUtc $($origin.ToString('o')) is later than now $($cliUtc.ToString('o')) (clock step or bad input; a future origin would inflate the budget)" }
        $ddl = 200; $ackw = 150                                      # stage3d/init.sh DEADLINE and ACK_WINDOW
        $dl = Get-FsHostDeadlines -OriginUtc $origin -DeviceDeadlineSec $ddl -AckWindowSec $ackw -HostMarginSec $margin
        $pre = ConvertTo-FsTransportDeadlines -Deadlines $dl -NowMs 0 -NowUtc ([DateTime]::UtcNow)
        $why = Get-FsLiveStartRefusal -RemainMs $pre.RemainMs -AckRemainMs $pre.AckRemainMs -AckWindowSec $ackw
        if ($why) { throw "refused: $why" }
        $g = Get-FsGadget -Nonce $nx
        if (-not $g.SerialOk) { throw "refused: no USB gadget with serial FS-$nx is present" }
        if ($g.ComPort -cne $pt) { throw "refused: $pt is not the port registered under FS-$nx (that is '$($g.ComPort)')" }
        $snd = New-Fs3cSounds
        $sink = New-Fs3cSoundSink -Kind live -Sounds $snd
        $ui = New-Fs3cUi -Kind console
        Assert-Fs3cConsole
        $keys = New-Fs3cConsoleKeySource
        $tokens = @{ V = (New-FsHex 16); A = (New-FsHex 8); C = @{ p0 = (New-FsHex 16); r1 = (New-FsHex 16); r2 = (New-FsHex 16); r3 = (New-FsHex 16) } }
        $t = New-FsRawSerialTransport -PortName $pt -PollMs ([int](Get-Fs3dArg 'S3dPollMs'))
        $nowMs = [long]$t.NowMs(); $nowU = [DateTime]::UtcNow
        $cv = ConvertTo-FsTransportDeadlines -Deadlines $dl -NowMs $nowMs -NowUtc $nowU
        $why = Get-FsLiveStartRefusal -RemainMs $cv.RemainMs -AckRemainMs $cv.AckRemainMs -AckWindowSec $ackw
        if ($why) { throw "refused (after $([long]($nowU - $cliUtc).TotalSeconds) s of preparation): $why" }
        $timing = [ordered]@{ BudgetOrigin = 'BootStartUtc'; BootStartUtc = $origin.ToString('o'); HandoffUtcEvidence = $(if ($hoEv) { $hoEv.ToString('o') } else { $null })
                              GiveUpUtc = $dl.GiveUpUtc.ToString('o'); AckGiveUpUtc = $dl.AckGiveUpUtc.ToString('o'); DeviceDeadlineNoEarlierThanUtc = $dl.DeviceDeadlineUtc.ToString('o')
                              CollectorStartUtc = $cliUtc.ToString('o'); ConvertedAtUtc = $nowU.ToString('o'); ConvertedAtMs = $nowMs
                              PreparationMs = [long]($nowU - $cliUtc).TotalMilliseconds; RemainMsAtConversion = $cv.RemainMs; AckRemainMsAtConversion = $cv.AckRemainMs }
        $cfg = New-Fs3dCfg -NonceX $nx -GiveUpMsX $cv.GiveUpMs -AckGiveUpMsX $cv.AckGiveUpMs -KernelX ([string](Get-Fs3dArg 'S3dKernel')) -Pid1X ([string](Get-Fs3dArg 'S3dPid1')) `
            -TimingX $timing -PollMsX ([int](Get-Fs3dArg 'S3dPollMs')) -NoDoneX ([bool](Get-Fs3dArg 'S3dNoDone'))
        Write-Output "HOST GIVE-UP: $($dl.GiveUpUtc.ToString('o')) = BootStartUtc $($origin.ToString('o')) + $ddl s - $margin s (device deadline no earlier than $($dl.DeviceDeadlineUtc.ToString('o'))); $([long][Math]::Floor($cv.RemainMs / 1000)) s left after $([long]($nowU - $cliUtc).TotalSeconds) s of preparation"
        $started = $true
        $script:Fs3dCm = Enter-Fs3cConsoleMode
        $r = Invoke-Fs3dRun -Transport $t -OutDirX $od -Tokens $tokens -Cfg $cfg -Mode 'live' -PortName $pt -Ui $ui -Keys $keys -Sound $sink -Sounds $snd -UtcBase $nowU -UtcBaseMs $nowMs
        $r | Add-Member NoteProperty ConsoleMode @($script:Fs3dCm.Notes)
        try { Save-Fs3cSessionJson -Result $r -Path (Join-Path $od 'session.json') }
        catch { Write-Output (ConvertTo-FsPrintable "SESSION.JSON NOT WRITTEN: $($_.Exception.Message)") }
        $sp = Save-Fs3dSummary $r $od $false
        Show-Fs3dSummaryOnKey $r $sp $keys $false
    }
    }
    $exitCode = if ($null -ne $soundExit) { $soundExit } else { switch ($r.Status) { 'COLLECTED-VALID' { 10 } 'COLLECTED-REJECTED' { 11 } default { 14 } } }
} catch {
    Write-Output (ConvertTo-FsPrintable "REFUSED/ERROR: $($_.Exception.Message)")
    $ctx = $script:FsLastCtx
    if (-not $started -or $null -eq $ctx) { Write-Output 'RECOVERY: nothing was sent to the headset by this run'; $exitCode = 20 }
    else {
        Write-Output (ConvertTo-FsPrintable "SENT:   $(@($ctx.Sent) -join ' | ')")
        Write-Output (Get-Fs3cErrorRecovery $ctx)
        $exitCode = 70
    }
} finally { Exit-Fs3cConsoleMode $script:Fs3dCm }
exit $exitCode
