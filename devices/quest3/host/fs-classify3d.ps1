# FrameShift outcome classifier, STAGE 3D (v2.7, both Quest 3 units), Windows PowerShell 5.1, no modules.
# Design: devices/quest3/stage3d/README.md section 6 (the host interface) and devices/quest3/stage3d/HOST.md; the
# stage-3c classifier (fs-classify3c.ps1, DESIGN.md revision 3 section 11) with these stage-3d differences only:
#   - the records are exp=s3d_<ph> (README 6.4); the fs-pattern pin is v0.7.1 bfafad97...9a9a (J-141; README 6.8);
#   - r1 is the NON-LIT display reset (README 3, 6.5): its classes are RESET-DONE, ALREADY-INACTIVE and RESET-NOT-DONE
#     (never "SHOWN"); its facts are the reset records (reset_precondition, buffer black=1, the reset_off and reset_on_*
#     commits, post_state 0 then 1, reset_close, exit reason reset_done|already_inactive shown=0); r2's "previous phase
#     clean" check uses exactly the device gate's facts (fs-phase.sh gate_reset), and r2's pause is measured from the
#     reset's end (t0_ms + elapsed_ms);
#   - r2's start record must carry roll=21 eyes=swap (README 6.7);
#   - the readings (readings3d.txt) hold ONE r1 item, `seen` (the recorded, non-gating question "Anything visible during
#     the reset (r1)?", keys y / b, PM J-130) and, for r2, the per-eye readings with the tilt as LEVEL / CLOCKWISE /
#     COUNTERCLOCKWISE / UNKNOWN (the 21-degree roll check); the optical stage result is r2's only;
#   - the layout labels read the per-EYE expectation (README 6.7): left eye bars 1|2, right eye 3|4, F upright, level;
#     3|4 in the left eye = the swap assumption is wrong; a remaining tilt (and its direction) = the roll is wrong.
#     Diagnostic labels (GEOMETRY, ROLL), never a PASS;
#   - outcomes: PASS (machine side) = P0 OK, r1 RESET-DONE or ALREADY-INACTIVE, R2 SHOWN-QUAD; new RESET ONLY (the reset
#     ran, run 2 did not show) and RESET NOT DONE; STAGE PASS = that machine PASS plus r2 OPTICAL PASS. Review 2 MINOR-4:
#     a clean reset (RESET-DONE / ALREADY-INACTIVE) followed by the device skipping r2 for run1-not-reset or
#     run1-supervisor (its gate saw the reset NOT clean) is a host/device INCONSISTENCY (INCONCLUSIVE), not RESET ONLY;
#   - review 2 MINOR-5: a 0 bar names the mixer whose plane was expected there (eyes=swap: LM0 4, LM1 3, LM2 2, LM3 1).
# Everything else (FSPM1/FSXE1 parsing, slices, the quad post_plane check, probes, the run-3 rule and interpretation)
# is the stage-3c library's code, called unchanged (fs-classify3c.ps1 is dot-sourced and never edited).
#
# CLI: fs-classify3d.ps1 -C3dDir <fs-collect3d output dir> (-C3dObserveDir <fs-observe3d output dir> | -C3dStage1Class <class>)
#                        [-C3dPatternPin <sha256>: default the built-in v0.7.1 pin] [-C3dReadings <readings3d.txt>]
#   Exit: 10 PASS (machine side), 12 INTEGRITY FAULT, 13 stage 1 not PASS, 14 INCONCLUSIVE, 15 NO-DISPLAY, 16 DISPLAY FAIL,
#         17 PRECONDITION UNMET (r2 found the CRTC active), 18 RESET ONLY, 19 RESET NOT DONE, 64 usage, 70 internal error.
# M4: the parameter names (C3d*) collide with none of fs-classify3c.ps1's, fs-classify.ps1's or fs-collect.ps1's; the bound
# arguments are snapshotted before the dot-source.
param(
    [string]$C3dDir = '',
    [string]$C3dObserveDir = '',
    [string]$C3dStage1Class = '',
    [string]$C3dPatternPin = '',
    [string]$C3dReadings = ''
)
$script:Fc3dArgs = @{} + $PSBoundParameters
$script:Fc3dInvocation = $MyInvocation.InvocationName
. (Join-Path $PSScriptRoot 'fs-classify3c.ps1')        # the stage-3c library (returns early when dot-sourced)
Set-StrictMode -Version 2.0

# ------------------------------------------------------------ protocol ------
$script:S3dPhases = @('p0', 'r1', 'r2', 'r3')
$script:S3dExp = @{ p0 = 's3d_p0'; r1 = 's3d_r1'; r2 = 's3d_r2'; r3 = 's3d_r3' }
$script:S3dSteps = @{ p0 = @('hash', 'probe0'); r1 = @('probe1', 'pattern1'); r2 = @('probe2', 'pattern2'); r3 = @('probe3', 'pattern3') }
$script:S3dMode = @{ r1 = 'reset'; r2 = 'show-off-quad'; r3 = 'show-off-solid' }
$script:S3dPatternPin = 'bfafad97c7ca11ef4e41a6be8aae4fde5ca529d8955d9b77d6fc603495049a9a'   # fs-pattern v0.7.1 (J-141, MAXMODES fix; stage3d/build-image.sh, MANIFEST /bin/fs-pattern; README 6.8)
$script:S3dRoll = '21'; $script:S3dEyes = 'swap'                                               # fs-phase.sh ROLL / EYES (README 6.7)
$script:S3dExpectBars = @{ left = '12'; right = '34' }                                          # eyes=swap: left eye "1 | 2", right eye "3 | 4" (README 4, 6.7)
$script:S3dMixerOfBars = @{ '4' = 'LM0'; '3' = 'LM1'; '2' = 'LM2'; '1' = 'LM3' }                # the mixer map for eyes=swap (README 6.7): LM0 4, LM1 3, LM2 2, LM3 1
$script:S3dStage = '3d'
$script:S3dResetGood = @('RESET-DONE', 'ALREADY-INACTIVE')

# ------------------------------------------------------------ r1: the reset ------
# The reset facts of a pattern1 step (fs-pattern v0.7 `reset`, stage3d/src/fs-pattern.c): the stage-3b run parse
# (Get-FsS3bRun: kind, code, mode, the FSP1 stream checks) plus the reset records. ExitMs = t0_ms + elapsed_ms (the
# monotonic end of the reset; r2's pause is measured from it).
function Get-Fs3dReset {
    param([hashtable]$St, [string]$Chal8)
    $r = Get-FsS3bRun $St 1 $Chal8
    foreach ($n in 'State', 'Black', 'Commits', 'PostActive', 'ResetCloseRc', 'ExitReason', 'Shown', 'ExitMs', 'Facts') { $r | Add-Member NoteProperty $n $null }
    $r.Commits = @(); $r.PostActive = @(); $r.Facts = @()
    if ($r.Kind -cne 'run') { return $r }
    $recs = @($r.Recs)
    $one = { param([string]$s) $x = @($recs | Where-Object { $_.Step -ceq $s }); if ($x.Count -eq 1) { $x[0] } else { $null } }
    $pc = & $one 'reset_precondition'; if ($null -ne $pc) { $r.State = [string]$pc.Kv['state'] }
    $bf = & $one 'buffer'; if ($null -ne $bf) { $r.Black = [string]$bf.Kv['black'] }
    $r.Commits = @($recs | Where-Object { $_.Step -ceq 'commit' } | ForEach-Object { [pscustomobject]@{ Rc = $_.Rc; Attempt = [string]$_.Kv['attempt']; Layout = [string]$_.Kv['layout'] } })
    $r.PostActive = @($recs | Where-Object { $_.Step -ceq 'post_state' } | ForEach-Object { [string]$_.Kv['active'] })
    $rc = & $one 'reset_close'; if ($null -ne $rc) { $r.ResetCloseRc = [string]$rc.Kv['close_rc'] }
    $ex = & $one 'exit'; $st0 = & $one 'start'
    if ($null -ne $ex) {
        $r.ExitReason = [string]$ex.Kv['reason']; $r.Shown = [string]$ex.Kv['shown']
        if ($null -ne $st0 -and [string]$st0.Kv['t0_ms'] -cmatch '^[0-9]{1,15}\z' -and [string]$ex.Kv['elapsed_ms'] -cmatch '^[0-9]{1,15}\z') { $r.ExitMs = [long]$st0.Kv['t0_ms'] + [long]$ex.Kv['elapsed_ms'] }
    }
    $r
}
# The r1 class from the reset facts (README 6.5). Returns @{ Class; Reason; Gate; Inconsistent }.
function Get-Fs3dResetClass {
    param($R)
    $o = { param($c, $w, [bool]$gate = $false, [bool]$inc = $false) [pscustomobject]@{ Class = $c; Reason = $w; Gate = $gate; Inconsistent = $inc } }
    if ($R.Shown -cne '0') { return (& $o 'INCONCLUSIVE' "runner inconsistency: the reset reports shown=$($R.Shown) (it may scan out only black)" $false $true) }
    if (@($R.Commits).Count -gt 0 -and $R.Black -cne '1') { return (& $o 'INCONCLUSIVE' "runner inconsistency: a reset commit without the all-black buffer (buffer black=$($R.Black))" $false $true) }
    $cm = @($R.Commits)
    if ($R.Code -eq 0 -and $R.ExitReason -ceq 'reset_done') {
        $ok = ($R.State -ceq 'active' -and $cm.Count -eq 2 -and $cm[0].Rc -eq 0 -and $cm[0].Attempt -ceq '0' -and $cm[0].Layout -ceq 'reset_off' -and
               $cm[1].Rc -eq 0 -and $cm[1].Layout -cmatch '^reset_on_(single|split)\z' -and (@($R.PostActive) -join ',') -ceq '0,1' -and $R.ResetCloseRc -ceq '0')
        if (-not $ok) { return (& $o 'INCONCLUSIVE' "runner inconsistency: exit reset_done without its facts (precondition $($R.State); commits $(@($cm | ForEach-Object { "$($_.Attempt)/$($_.Layout)=$($_.Rc)" }) -join ' '); post_state active $(@($R.PostActive) -join ','); close_rc $($R.ResetCloseRc))" $false $true) }
        return (& $o 'RESET-DONE' "the reset ran: the handed-over CRTC disabled (reset_off), re-enabled dark on an all-black buffer ($($cm[1].Layout)), closed (close_rc 0); nothing but black scanned out" $true)
    }
    if ($R.Code -eq 0 -and $R.ExitReason -ceq 'already_inactive') {
        if ($R.State -cne 'already_inactive' -or $cm.Count -ne 0) { return (& $o 'INCONCLUSIVE' "runner inconsistency: exit already_inactive with precondition '$($R.State)' and $($cm.Count) commit(s)" $false $true) }
        return (& $o 'ALREADY-INACTIVE' 'the CRTC was already provably inactive: nothing committed (exit 0, already_inactive)' $true)
    }
    if ($R.Code -eq 0) { return (& $o 'INCONCLUSIVE' "runner inconsistency: exit 0 with reason '$($R.ExitReason)'" $false $true) }
    $what = if ($script:S3cNoDisp.ContainsKey([int]$R.Code)) { " ($($script:S3cNoDisp[[int]$R.Code]))" } else { '' }
    & $o 'RESET-NOT-DONE' "fs-pattern reset exit $($R.Code)$what, reason $($R.ExitReason); commits $(@($cm | ForEach-Object { "$($_.Attempt)/$($_.Layout)=$($_.Rc)" }) -join ' '); the device gates run 2 off (run1-supervisor / run1-not-reset)"
}

# ------------------------------------------------------------ machine side ------
# COPY of Get-Fs3cPhaseMachine (fs-classify3c.ps1). Differences: the r1 branch (the reset classes above); r2's previous
# phase is the reset (its gate facts; the pause from its ExitMs); r2's start record roll/eyes; the p0 text names v0.7.1.
function Get-Fs3dPhaseMachine {
    param($P, [hashtable]$Prev, [string]$Pin)
    $o = [ordered]@{ Ph = $P.Ph; Class = $null; Reason = ''; Tag = $null; Run = $null; Probe = $null; Notes = @(); Shown = 'unknown'; Clean = $false; GateClean = $false; Scanout = $null; Inconsistent = $false }
    $fin = { param($c, $w, [string]$sh = 'unknown') $o.Class = $c; $o.Reason = $w; $o.Shown = $sh; [pscustomobject]$o }
    $inc = { param($w) $o.Inconsistent = $true; & $fin 'INCONCLUSIVE' "runner inconsistency: $w" }
    if (-not $P.Sent) { return (& $fin 'NOT RUN' "not run: $($P.NotRunWhy)" 'not') }
    if ($null -ne $P.Refusal) { return (& $fin 'REFUSED' "FSXE1 ran=$($P.Refusal.Ran) error=$($P.Refusal.Error)" $(if ($P.Refusal.Ran -eq 0) { 'not' } else { 'unknown' })) }
    if (-not $P.Complete) { return (& $fin 'INCONCLUSIVE' 'no complete record by the phase deadline') }
    if ($null -eq $P.Fsb1 -or -not $P.Fsb1.Ok) { return (& $fin 'INCONCLUSIVE' "FSB1 rejected: $(if ($null -ne $P.Fsb1) { $P.Fsb1.Reason + ' ' + $P.Fsb1.Detail } else { 'no record' })") }
    $stp = @($P.Fsb1.Steps)
    if ((@($stp | ForEach-Object { $_['id'] }) -join ',') -cne ($script:S3dSteps[$P.Ph] -join ',')) { return (& $fin 'INCONCLUSIVE' 'decoded steps are not the stage-3d list for this phase') }
    if (-not $P.ChainOk) { return (& $inc 'the chain argument of this phase does not equal the previous record''s rec_sha256[0:16]') }
    $c8 = $P.Chal.Substring(0, 8)
    if ($P.Ph -ceq 'p0') {
        $h = $stp[0]; $pr = Get-Fs3cProbeFacts $stp[1]; $o.Probe = $pr
        $tf = Test-FsS2ToolFault $h
        if (-not $Pin) { return (& $fin 'INCONCLUSIVE' 'no fs-pattern v0.7.1 pin: integrity unmeasured') }
        $hc = if ($null -ne $tf) { @{ Class = 'TOOL FAULT'; Mismatch = $false; Notes = $tf } } else { Get-FsS3HashClass $h $Pin }
        if ($hc.Class -ceq 'MEASURED' -and $hc.Mismatch) { return (& $fin 'INTEGRITY FAULT' "hash: $($hc.Notes)") }
        if ($pr.Writes -gt 1) { return (& $inc "$($pr.Writes) backlight write lines in p0") }
        if ($hc.Class -cne 'MEASURED') { return (& $fin 'INCONCLUSIVE' "hash tool fault: $($hc.Class) ($($hc.Notes))") }
        if ($pr.Writes -ne 1 -or $pr.WriteOk127 -lt 1) { return (& $fin 'BRIGHTNESS NOT VERIFIED' "probe0: writes=$($pr.Writes) readback=$(@($pr.Readbacks) -join ',') ($($pr.Note))") }
        $o.Clean = $true
        return (& $fin 'P0 OK' 'hash equals the v0.7.1 pin; exactly one write line with write_rc=0 readback=127')
    }
    $runN = [int]$P.Ph.Substring(1, 1)
    $pr = Get-Fs3cProbeFacts $stp[0]; $o.Probe = $pr
    if ($pr.Writes -ne 0) { return (& $inc "a backlight write line in probe$runN (the only write belongs to p0)") }
    if ($runN -eq 1) {
        # ---- stage 3d: the non-lit reset
        $rs = Get-Fs3dReset $stp[1] $c8; $o.Run = $rs; $o.Shown = 'not'
        switch -CaseSensitive ($rs.Kind) {
            'toolfault' { return (& $fin 'INCONCLUSIVE' "our side failed in the reset step: $($rs.Why)" 'not') }
            'skip'      { return (& $fin 'SKIPPED' "the reset skipped ($($rs.Why))" 'not') }
            'hang'      { return (& $fin 'RESET-NOT-DONE' "the reset hung or was not runnable: $($rs.Why)" 'not') }
            'other'     { return (& $fin 'INCONCLUSIVE' "the reset $($rs.Why)" 'not') }
            'unsound'   { return (& $fin 'INCONCLUSIVE' "the reset's evidence unreadable: $($rs.Why)" 'not') }
        }
        if ($rs.Mode -cne 'reset') { return (& $fin 'INCONCLUSIVE' "run 1 mode is '$($rs.Mode)', not reset" 'not') }
        if (@($pr.Readbacks).Count -lt 1 -or @($pr.Readbacks)[0] -cne '127') { return (& $inc 'the reset ran but probe1 does not show the read-back 127') }
        $cl = Get-Fs3dResetClass $rs
        $o.GateClean = $cl.Gate; $o.Clean = $cl.Gate
        if ($cl.Inconsistent) { $o.Inconsistent = $true }
        return (& $fin $cl.Class $cl.Reason 'not')
    }
    $run = Get-Fs3cRun $stp[1] $runN $c8; $o.Run = $run
    $o.GateClean = ($run.Kind -ceq 'run' -and $run.Code -eq 0 -and $run.HeldClean -and $run.CloseClean -and
                    ($runN -ne 2 -or [string]$run.CommitLayout -cmatch '^quad_(vig|dma)\z'))
    $prevPh = 'r' + ($runN - 1)
    switch -CaseSensitive ($run.Kind) {
        'toolfault' { return (& $fin 'INCONCLUSIVE' "our side failed in the pattern step: $($run.Why)") }
        'skip'      { return (& $fin 'SKIPPED' "run $runN skipped ($($run.Why))" 'not') }
        'hang'      { return (& $fin 'DISPLAY FAIL' "run $runN hung or was not runnable: $($run.Why)") }
        'other'     { return (& $fin 'INCONCLUSIVE' "run $runN $($run.Why)") }
        'unsound'   { return (& $fin 'INCONCLUSIVE' "run $runN evidence unreadable: $($run.Why)") }
    }
    $pv = $Prev[$prevPh]
    if ($null -eq $pv -or -not $pv.GateClean) {
        if ($runN -eq 2) { return (& $inc "r2 executed although r1 is not a clean reset (RESET-DONE or ALREADY-INACTIVE with all its facts; the device's gate_reset needs exit code=0 reason=reset_done|already_inactive shown=0)") }
        return (& $inc "r3 executed without r2's a clean quad commit and close (exit 0, commit rc=0, hold to the deadline, close_rc=0, a quad layout)")
    }
    if ($runN -eq 3 -and -not $P.R3RuleHeld) { return (& $inc 'r3 executed although the host run-3 rule (DESIGN 5.8) did not hold') }
    if ($run.Mode -cne $script:S3dMode[$P.Ph]) { return (& $fin 'INCONCLUSIVE' "run $runN mode is '$($run.Mode)', not $($script:S3dMode[$P.Ph])") }
    if ($runN -eq 2) {
        $sr = @(@($run.Recs) | Where-Object { $_.Step -ceq 'start' })
        $ro = if ($sr.Count -eq 1) { [string]$sr[0].Kv['roll'] } else { '' }; $ey = if ($sr.Count -eq 1) { [string]$sr[0].Kv['eyes'] } else { '' }
        if ($ro -cne $script:S3dRoll -or $ey -cne $script:S3dEyes) { return (& $fin 'INCONCLUSIVE' "run 2's start record carries roll=$ro eyes=$ey, not roll=$($script:S3dRoll) eyes=$($script:S3dEyes) (README 6.7)") }
    }
    if ($run.ZposOutsideQuad) { return (& $inc 'zpos set outside a quad attempt') }
    if (@($pr.Readbacks).Count -lt 1 -or @($pr.Readbacks)[0] -cne '127') { return (& $inc "run $runN ran but probe$runN does not show the read-back 127") }
    $o.Scanout = "TE $(if ($null -ne $pr.TeRate) { "$($pr.TeRate)/s" } else { 'n/a' }) BLU $(if ($null -ne $pr.BluRate) { "$($pr.BluRate)/s" } else { 'n/a' }) topology=$(if ($null -ne $run.PostState -and $run.PostState.ContainsKey('topology_name')) { $run.PostState['topology_name'] } else { 'n/a' }) dmesg-flags=$(if (@($pr.DmesgFlags).Count) { @($pr.DmesgFlags) -join ',' } else { 'none' })"
    if ($run.Code -eq 31) {
        if ($null -ne $run.Precond -and $run.Precond.Rc -eq -16 -and -not $run.Committed) { return (& $fin 'PRECONDITION UNMET: CRTC ACTIVE' "run $runN found the CRTC not provably inactive (active=$($run.Precond.Active) active_prop=$($run.Precond.ActiveProp) getcrtc_rc=$($run.Precond.GetCrtcRc)) and committed nothing" 'not') }
        return (& $fin 'INCONCLUSIVE' "run $runN exit 31 without the precondition record")
    }
    $preOk = ($null -ne $run.Precond -and $run.Precond.Rc -eq 0 -and $run.Precond.Active -ceq '0' -and $run.CrtcActive -ceq '0')
    if (-not $preOk) { return (& $fin 'INCONCLUSIVE' "run $runN has no proof of an inactive CRTC at start (precondition rc=0, crtc_state active=0)") }
    if ($script:S3cNoDisp.ContainsKey([int]$run.Code)) {
        $tcs = (@($run.TestCommits) | ForEach-Object { "$($_.Layout)=$($_.Rc)" }) -join ' '
        if ($run.Committed) { return (& $inc "exit $($run.Code) with a commit record") }
        return (& $fin 'NO-DISPLAY' "run $($runN): fs-pattern exit $($run.Code) ($($script:S3cNoDisp[[int]$run.Code])); test_commit $tcs" 'not')
    }
    if ($run.Code -eq 60 -or $run.Code -eq 1) { return (& $fin 'DISPLAY FAIL' "run $($runN): fs-pattern exit $($run.Code)") }
    if ($run.Committed -and [string]$run.CommitLayout -cnotmatch '^quad_(vig|dma)\z') { return (& $inc "a real commit with layout '$($run.CommitLayout)' in r$runN") }
    if ($run.Code -ne 0 -or -not $run.HeldClean) { return (& $fin 'INCONCLUSIVE' "run $($runN): exit $($run.Code) without commit rc=0, hold_end reason=deadline and exit shown=1") }
    $q = Test-Fs3cQuadPost $run
    if ($q.ZposBad) { return (& $inc $q.Why) }
    if ($q.TypeBad) { return (& $inc $q.Why) }
    $o.Tag = $run.CommitLayout
    if (-not $q.Ok) { $o.Notes = @($q.Why); return (& $fin 'INCONCLUSIVE' $q.Why) }
    # the pause: r2 from the reset's end (t0_ms + elapsed_ms), r3 from r2's close (as stage 3c)
    $end = if ($runN -eq 2) { $pv.Run.ExitMs } elseif ($null -ne $pv.Run.StartMs -and $null -ne $pv.Run.HeldMs -and $null -ne $pv.Run.CloseMs) { $pv.Run.StartMs + $pv.Run.HeldMs + $pv.Run.CloseMs } else { $null }
    if ($null -eq $end -or $null -eq $run.StartMs) { return (& $fin 'INCONCLUSIVE' 'monotonic stamps for the pause are missing') }
    $pause = $run.StartMs - $end
    $o.Notes = @("pause $pause ms")
    if ($pause -lt 2000) { return (& $inc "pause between r$($runN - 1)'s end and r$($runN)'s commit is $pause ms (< 2000)") }
    if (-not $run.CloseClean) { return (& $fin 'INCONCLUSIVE' "run $runN committed and held but close_rc=$($run.CloseRc)" 'shown') }
    $o.Clean = $true
    if ($runN -eq 2) { return (& $fin 'R2 SHOWN-QUAD' "committed $($run.CommitLayout) roll=$($script:S3dRoll) eyes=$($script:S3dEyes) from an inactive CRTC (DRM state; physical panel-off not proven), $($q.Why); held; clean close; pause $pause ms; read-back 127" 'shown') }
    return (& $fin 'R3 SHOWN-QUAD-SOLID' "committed $($run.CommitLayout) (solid red), $($q.Why); held; clean close; pause $pause ms; read-back 127" 'shown')
}

# ------------------------------------------------------------ readings -------
# FSR2 lines of stage 3d (readings3d.txt): r1 has the one item `seen`; the tilt is LEVEL/CLOCKWISE/COUNTERCLOCKWISE/UNKNOWN.
$script:S3dFsr2Re = '^FSR2 p=(r1|r2|r3) item=(seen|left|right|chars_left|chars_right|dark|bars_left|bars_right|orient_left|orient_right|tilt_left|tilt_right) key=(Enter|Esc|Backspace|[a-z0-9?]|-) obs=(SEEN|NOT_SEEN|LIT|DARK|GARBLED|READ|BARS|UPRIGHT|HALF_TURN|MIRRORED|VFLIP|LEVEL|CLOCKWISE|COUNTERCLOCKWISE|UNKNOWN|UNIFORM_RED|PARTIAL_RED|UNIFORM_OTHER|SAME_AS_R2|DIFFERENT|DARK_NOW|LIGHT_NOW|TIMEOUT|ABORT|NOT_ASKED)(?: chars=([0-9A-F?]{8}))?(?: bars=([0-4]{2}))? prompt_ms=([0-9]{1,12}) answer_ms=(-1|[0-9]{1,12}) prompt_utc=(\S+) answer_utc=(\S+) discarded=([0-9]{1,6})\z'
function ConvertFrom-Fs3dReadings {
    param([string[]]$Lines)
    $m = @{}
    foreach ($l in @($Lines | Where-Object { $_ -and -not $_.StartsWith('#') })) {
        if ($l -cnotmatch $script:S3dFsr2Re) { throw "readings: malformed line '$(ConvertTo-FsPrintable $l)'" }
        $k = "$($Matches[1]):$($Matches[2])"
        if ($m.ContainsKey($k)) { throw "readings: $k given twice" }
        if (($Matches[2] -ceq 'seen') -xor ($Matches[1] -ceq 'r1')) { throw "readings: r1 has only the item seen, and seen only r1 ('$(ConvertTo-FsPrintable $l)')" }
        if (($Matches[4] -ceq 'BARS') -xor ($null -ne $Matches[6] -and $Matches[6] -ne '')) { throw "readings: bars= is required with BARS and only with BARS" }
        $m[$k] = [pscustomobject]@{ Ph = $Matches[1]; Item = $Matches[2]; Key = $Matches[3]; Obs = $Matches[4]; Chars = $(if ($Matches[5]) { $Matches[5] } else { '' })
                                    Bars = $(if ($Matches[6]) { $Matches[6] } else { '' }); PromptMs = [long]$Matches[7]; AnswerMs = [long]$Matches[8] }
    }
    $m
}

# The per-eye layout reading of stage 3d (README 6.7; diagnostic labels, never a PASS). The bars are compared with THIS
# eye's expectation (left 12, right 34) and with the other eye's; the F as stage 3c; the tilt reads the roll correction.
function Get-Fs3dLayoutLabel {
    param([string]$Eye, [string]$Bars, [string]$Orient, [string]$Tilt, [bool]$CharsCorrect = $false)
    $exp = $script:S3dExpectBars[$Eye]; $oth = $script:S3dExpectBars[$(if ($Eye -ceq 'left') { 'right' } else { 'left' })]
    $rev = { param([string]$b) -join @($b[1], $b[0]) }
    $o = if ($Orient) { $Orient } else { 'NOT_ASKED' }
    $mk = { param($l, $t, [string]$swap = '', [bool]$inc = $false) [pscustomobject]@{ Label = $l; Tag = $t; Swap = $swap; Inconsistent = $inc } }
    $lay = $null
    if (-not $Bars) { $lay = & $mk 'bars not recorded' '-' }
    elseif ($Bars.Contains('0')) {
        # review 2 MINOR-5: name the mixer expected at each 0 side (as designed for this eye; eyes=swap mixer map)
        $zs = @(); foreach ($i in 0, 1) { if ($Bars[$i] -eq [char]'0') { $eb = [string]$exp[$i]; $zs += "the $(if ($i -eq 0) { 'LEFT' } else { 'RIGHT' }) F: no bars where $($script:S3dMixerOfBars[$eb])'s $eb bar(s) belong" } }
        $lay = & $mk "a 0 side ($($zs -join '; ')): that mixer's plane not scanned or not readable: layout fault" '[C]'
        if ($CharsCorrect) { $lay.Label += '; contradicts the correct characters (inconsistency)'; $lay.Inconsistent = $true }
    } elseif ($Bars -ceq $exp) {
        switch -CaseSensitive ($o) {
            'UPRIGHT'   { $lay = & $mk "as designed: this eye shows its own picture ($($exp.Substring(0,1)) | $($exp.Substring(1,1)), F upright): the swap and the 180-degree mount hold" '[D]' 'as-designed' }
            'VFLIP'     { $lay = & $mk 'its own picture, but the F turned over: a vertical flip in the path (geometry finding)' '[C]' 'as-designed' }
            'HALF_TURN' { $lay = & $mk 'contradictory (a half-turn would swap the bars): inconsistency' '-' 'as-designed' $true }
            'MIRRORED'  { $lay = & $mk 'contradictory (a mirror would swap the bars): inconsistency' '-' 'as-designed' $true }
            default     { $lay = & $mk "bars as designed for this eye ($($exp.Substring(0,1)) | $($exp.Substring(1,1)); F not read)" '[D]' 'as-designed' }
        }
    } elseif ($Bars -ceq $oth) {
        $lay = & $mk "this eye shows the OTHER eye's picture ($($oth.Substring(0,1)) | $($oth.Substring(1,1))): the eye-swap assumption is wrong (geometry finding)" '[D]' 'swapped'
    } elseif ($Bars -ceq (& $rev $exp)) {
        switch -CaseSensitive ($o) {
            'HALF_TURN' { $lay = & $mk 'its own picture turned by a half-turn: the 180-degree mount assumption is wrong (geometry finding)' '[C]' 'as-designed' }
            'MIRRORED'  { $lay = & $mk 'its own picture mirrored left-right (geometry finding)' '[C]' 'as-designed' }
            'UPRIGHT'   { $lay = & $mk 'the two planes of this eye exchanged position: layout fault' '[D]' 'as-designed' }
            default     { $lay = & $mk "its own bars in reverse order ($($Bars.Substring(0,1)) | $($Bars.Substring(1,1)); F not read or not decisive)" '[C]' 'as-designed' }
        }
    } elseif ($Bars -ceq (& $rev $oth)) {
        $lay = & $mk "the other eye's picture in reverse order ($($Bars.Substring(0,1)) | $($Bars.Substring(1,1))): the swap is wrong and the picture turned or mirrored (geometry finding)" '[C]' 'swapped'
    } else { $lay = & $mk "unexpected bar pair $($Bars.Substring(0,1)) | $($Bars.Substring(1,1)): layout fault" '[C]' }
    $roll = switch -CaseSensitive ($Tilt) {
        'LEVEL'            { "level: the $($script:S3dRoll)-degree roll correction holds for this eye [PM report]" }
        'CLOCKWISE'        { "still turned CLOCKWISE: the roll correction is off for this eye (direction recorded) [PM report]" }
        'COUNTERCLOCKWISE' { "still turned COUNTER-CLOCKWISE: the roll correction is off for this eye (direction recorded) [PM report]" }
        'UNKNOWN'          { 'tilt: could not tell' }
        default            { 'tilt not recorded' }
    }
    $lay | Add-Member NoteProperty Roll $roll
    $lay
}

# The whole session (README 6). $Phases as Get-Fs3cOutcome's; $ReadingLines: readings3d.txt lines or $null.
function Get-Fs3dOutcome {
    param([Parameter(Mandatory)][string]$S1Class, [Parameter(Mandatory)]$Phases, [string[]]$ReadingLines = $null, [string]$Pin = '', [string[]]$SessionReadings = $null,
          [string[]]$Q7Items = @())
    if (-not $Pin) { $Pin = $script:S3dPatternPin }
    $o = [ordered]@{ Outcome = $null; Reason = ''; Phases = [ordered]@{}; Optical = [ordered]@{}; Dark = [ordered]@{}; Layout = [ordered]@{}; Interpretation = $null
                     R1Seen = $null; Labels = @(); Notes = @(); Registered = ''; ReadingsOk = $true; ReadingsWhy = ''; Q7NotAsked = @(); Geometry = $null; Roll = $null }
    if ($S1Class -cne 'PASS') { $o.Outcome = $S1Class; $o.Reason = 'stage 1 did not PASS; any record text is data only'; $o.Registered = "not a stage PASS: machine $S1Class"; return [pscustomobject]$o }
    $byPh = @{}; foreach ($p in @($Phases)) { $byPh[$p.Ph] = $p }
    $prev = @{}
    foreach ($ph in $script:S3dPhases) {
        $p = $byPh[$ph]; if ($null -eq $p) { $p = [pscustomobject]@{ Ph = $ph; Sent = $false; NotRunWhy = 'not requested'; Refusal = $null; Complete = $false; Fsb1 = $null; Chal = ''; ChainOk = $true; R3RuleHeld = $false } }
        $m = Get-Fs3dPhaseMachine -P $p -Prev $prev -Pin $Pin
        $prev[$ph] = $m; $o.Phases[$ph] = $m
    }
    $rd = $null
    if ($null -ne $ReadingLines) {
        try { $rd = ConvertFrom-Fs3dReadings $ReadingLines } catch { $o.ReadingsOk = $false; $o.ReadingsWhy = ConvertTo-FsPrintable $_.Exception.Message }
        if ($o.ReadingsOk -and $null -ne $SessionReadings -and ((@($ReadingLines | Where-Object { $_ }) -join "`n") -cne (@($SessionReadings | Where-Object { $_ }) -join "`n"))) {
            $o.ReadingsOk = $false; $o.ReadingsWhy = 'readings3d.txt differs from the readings in session.json'; $rd = $null
        }
    } else { $o.ReadingsOk = $false; $o.ReadingsWhy = 'no readings file' }
    $labels = New-Object System.Collections.Generic.List[string]
    # r1: the one recorded, non-gating observation (PM J-130)
    $i1 = Get-Fs3cPhaseItems $rd 'r1'
    $o.R1Seen = if ($i1.ContainsKey('seen')) { $i1['seen'].Obs } else { 'NOT RECORDED' }
    if ($o.R1Seen -ceq 'SEEN') { $labels.Add('R1 OBSERVATION: the PM saw something during the display reset, which should scan out only black: a finding to report (not a gate)') }
    foreach ($ph in 'r2', 'r3') {
        $it = Get-Fs3cPhaseItems $rd $ph
        $mm = $o.Phases[$ph]; $pin8 = if ($byPh.ContainsKey($ph) -and $byPh[$ph].Chal) { $byPh[$ph].Chal.Substring(0, 8) } else { '00000000' }
        if ($ph -ceq 'r2') {
            if (-not $o.ReadingsOk) { $o.Optical[$ph] = [pscustomobject]@{ Class = $(if ($o.ReadingsWhy -eq 'no readings file') { 'NOT RECORDED' } else { 'INCONCLUSIVE' }); Why = $o.ReadingsWhy } }
            elseif ($it.Count -eq 0) { $o.Optical[$ph] = [pscustomobject]@{ Class = 'NOT RECORDED'; Why = 'no readings for run 2 (not run or not asked)' } }
            else { $o.Optical[$ph] = Get-Fs3cOptical -Items $it -Chal8 $pin8 -Shown $mm.Shown }
        } else {
            $o.Optical[$ph] = [pscustomobject]@{ Class = $(if ($it.Count) { 'RUN-3 READINGS' } else { 'NOT RECORDED' }); Why = (@('left', 'right') | ForEach-Object { "$_=$(if ($it.ContainsKey($_)) { $it[$_].Obs } else { 'none' })" }) -join ' ' }
        }
        foreach ($k in @('dark', 'left', 'right', 'chars_left', 'chars_right', 'bars_left', 'bars_right', 'orient_left', 'orient_right', 'tilt_left', 'tilt_right')) {
            if ($it.ContainsKey($k) -and $it[$k].Obs -ceq 'LIGHT_NOW') { $labels.Add("RETAINED-FRAME OBSERVATION after run $($ph.Substring(1)) ($k = light still visible): a safety-relevant finding"); break }
        }
        if ($it.ContainsKey('dark')) { $o.Dark[$ph] = $it['dark'].Obs }
        if ($ph -ceq 'r2') {
            $sw = @(); $rl = @()
            foreach ($e in 'left', 'right') {
                $b = if ($it.ContainsKey("bars_$e") -and $it["bars_$e"].Obs -ceq 'BARS') { $it["bars_$e"].Bars } else { '' }
                $or = if ($it.ContainsKey("orient_$e")) { $it["orient_$e"].Obs } else { '' }
                $tl = if ($it.ContainsKey("tilt_$e")) { $it["tilt_$e"].Obs } else { '' }
                $cc = ($it.ContainsKey($e) -and $it[$e].Obs -ceq 'READ' -and $it[$e].Chars -ceq $pin8.ToUpperInvariant())
                if (-not $it.ContainsKey("bars_$e") -and -not $it.ContainsKey("tilt_$e") -and -not $it.ContainsKey("orient_$e")) { continue }
                $q7e = (@($Q7Items) -ccontains "bars_$e" -and $it.ContainsKey("bars_$e") -and $it["bars_$e"].Obs -ceq 'NOT_ASKED')
                if ($q7e) { $o.Q7NotAsked += "bars_$e"; if (-not $it.ContainsKey("orient_$e") -and -not $it.ContainsKey("tilt_$e")) { continue } }
                $lab = Get-Fs3dLayoutLabel -Eye $e -Bars $b -Orient $or -Tilt $tl -CharsCorrect $cc
                if ($q7e) { $lab.Label = 'bars not asked (Q7 fallback); F and tilt as recorded'; $lab.Tag = '-'; $lab.Swap = '' }
                $o.Layout[$e] = [pscustomobject]@{ Bars = $b; Orient = $or; Tilt = $(if ($tl) { $tl } else { '-' }); Label = $lab.Label; Tag = $lab.Tag; Roll = $lab.Roll; Inconsistent = $lab.Inconsistent }
                if ($lab.Swap) { $sw += "$e=$($lab.Swap)" }
                if ($tl) { $rl += "$e=$tl" }
            }
            # the geometry summary (README 6.7): the swap from the bars, the roll from the tilt
            if (($sw -join ',') -ceq 'left=as-designed,right=as-designed') { $o.Geometry = 'GEOMETRY: the eye swap holds (left eye 1 | 2, right eye 3 | 4) [D]' }
            elseif (($sw -join ',') -ceq 'left=swapped,right=swapped') { $o.Geometry = 'GEOMETRY: both eyes show the other eye''s picture: the eye-swap assumption is wrong (eyes=direct would be right) [D]' }
            elseif ($sw.Count -eq 2) { $o.Geometry = "GEOMETRY: the eyes disagree ($($sw -join ', ')): a half-mapping fault [C]" }
            elseif ($sw.Count -eq 1) { $o.Geometry = "GEOMETRY: one eye only ($($sw -join ', '))" }
            if ($o.Geometry) { $labels.Add($o.Geometry) }
            if ($rl.Count) {
                $lv = @($rl | Where-Object { $_ -match '=LEVEL$' }).Count
                $o.Roll = if ($lv -eq 2) { "ROLL: level in both eyes: the $($script:S3dRoll)-degree correction holds [PM report]" }
                          elseif (@($rl | Where-Object { $_ -match '=(COUNTER)?CLOCKWISE$' }).Count) { "ROLL: a remaining tilt ($($rl -join ', ')): the $($script:S3dRoll)-degree correction is off; its direction is recorded per eye [PM report]" }
                          else { "ROLL: $($rl -join ', ')" }
                $labels.Add($o.Roll)
            }
        }
    }
    $r2m = $o.Phases['r2']; $r3m = $o.Phases['r3']
    if ($r3m.Class -cne 'NOT RUN') {
        if ($r3m.Shown -ceq 'shown') {
            $comp = ($r2m.Shown -ceq 'shown' -and $r2m.Tag -and $r2m.Tag -ceq $r3m.Tag)
            $o.Interpretation = Get-Fs3cR3Interpretation -R2Items (Get-Fs3cPhaseItems $rd 'r2') -R3Items (Get-Fs3cPhaseItems $rd 'r3') -Comparable $comp
        } else { $o.Interpretation = [pscustomobject]@{ Code = '-'; Text = "run 3 not machine-shown ($($r3m.Class)): no interpretation"; Tag = '-' } }
    }
    foreach ($ph in $script:S3dPhases) { foreach ($n in @($o.Phases[$ph].Notes)) { if ($n -match 'finding') { $labels.Add("FINDING ($ph): $n") } } }
    # the session's machine class
    $p0 = $o.Phases['p0'].Class; $r1 = $o.Phases['r1'].Class; $r2 = $r2m.Class
    $r3Bad = $r3m.Inconsistent
    $incon = @($script:S3dPhases | Where-Object { $o.Phases[$_].Inconsistent })
    if ($p0 -ceq 'INTEGRITY FAULT') { $o.Outcome = 'INTEGRITY FAULT'; $o.Reason = "p0: $($o.Phases['p0'].Reason)" }
    elseif ($incon.Count) { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = "$($incon[0]): $($o.Phases[$incon[0]].Reason)" }
    elseif ($p0 -ceq 'P0 OK' -and $script:S3dResetGood -ccontains $r1 -and $r2 -ceq 'R2 SHOWN-QUAD' -and -not $r3Bad) { $o.Outcome = 'PASS (machine side)'; $o.Reason = "P0 OK, R1 $r1, R2 SHOWN-QUAD (layout $($r2m.Tag))" }
    elseif ($p0 -cne 'P0 OK') { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = "p0: $p0 ($($o.Phases['p0'].Reason))" }
    elseif ($script:S3dResetGood -ccontains $r1) {
        switch -CaseSensitive ($r2) {
            'NOT RUN'                          { $o.Outcome = 'RESET ONLY'; $o.Reason = "r1 $r1; r2 not run ($($r2m.Reason))" }
            'SKIPPED'                          {
                # review 2 MINOR-4: the device's gate skipping r2 because the reset was not clean, after a host-clean reset
                if ($r2m.Reason -match 'run1-not-reset|run1-supervisor') { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = "host/device inconsistency: the host reads r1 as $r1, but the device skipped r2 as if the reset were not clean ($($r2m.Reason))" }
                else { $o.Outcome = 'RESET ONLY'; $o.Reason = "r1 $r1; r2 skipped by the device ($($r2m.Reason))" } }
            'NO-DISPLAY'                       { $o.Outcome = 'NO-DISPLAY'; $o.Reason = "r2: $($r2m.Reason)" }
            'PRECONDITION UNMET: CRTC ACTIVE'  { $o.Outcome = 'PRECONDITION UNMET: CRTC ACTIVE'; $o.Reason = "r1 $r1, but r2: $($r2m.Reason)" }
            'DISPLAY FAIL'                     { $o.Outcome = 'DISPLAY FAIL'; $o.Reason = "r2: $($r2m.Reason)" }
            default                            { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = $(if ($r2 -ceq 'R2 SHOWN-QUAD') { "r3: $($r3m.Reason)" } else { "r2: $r2 ($($r2m.Reason))" }) }
        }
    }
    elseif ($r1 -ceq 'RESET-NOT-DONE') { $o.Outcome = 'RESET NOT DONE'; $o.Reason = "r1: $($o.Phases['r1'].Reason)" }
    else { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = "r1: $r1 ($($o.Phases['r1'].Reason))" }
    # the registered line
    $stagePass = ($o.Outcome -ceq 'PASS (machine side)' -and $o.Optical['r2'].Class -ceq 'OPTICAL PASS' -and $r2m.Shown -ceq 'shown')
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("machine $($o.Outcome)$(if ($o.Outcome -ceq 'PASS (machine side)') { ' (layout ' + $r2m.Tag + ')' })")
    $parts.Add("R1 $r1 (reset seen: $($o.R1Seen))")
    if ($r2m.Scanout) { $parts.Add("SCANOUT $($r2m.Scanout) (r2)") }
    $parts.Add("R2 optical $($o.Optical['r2'].Class)")
    if ($null -ne $o.Interpretation) { $parts.Add("R3 $($o.Optical['r3'].Why) -> interpretation $($o.Interpretation.Code) $($o.Interpretation.Tag)") }
    foreach ($l in $labels) { $parts.Add($l) }
    $o.Labels = $labels.ToArray()
    $o.Registered = "$(if ($stagePass) { 'STAGE PASS' } else { 'not a stage PASS' }): " + ($parts -join '; ')
    [pscustomobject]$o
}

# The classifier on one fs-collect3d output directory. COPY of Invoke-Fs3cClassifyDir with the stage-3d exp, steps, pin,
# readings file, session schema and outcome. Returns @{ Code; Lines; Outcome }.
function Invoke-Fs3dClassifyDir {
    param([Parameter(Mandatory)][string]$DirX, [string]$ObsDirX = '', [string]$S1X = '', [string]$PinX = '', [string]$ReadingsX = '')
    $cDir = $DirX; $oDir = $ObsDirX; $s1 = $S1X; $pinX = $PinX
    $pre = New-Object System.Collections.Generic.List[string]
    $done = { param([int]$c, $l) [pscustomobject]@{ Code = $c; Lines = @(@($pre) + @($l) | ForEach-Object { ConvertTo-FsPrintable ([string]$_) }); Outcome = $null } }
    try {
        $j = Get-Content -Raw -ErrorAction Stop (Join-Path $cDir 'session.json') | ConvertFrom-Json
        $rawPath = Join-Path $cDir 'capture.raw'
        [byte[]]$raw = [IO.File]::ReadAllBytes($rawPath)
        $evs = Read-Fs3cIndexEvents -Path "$rawPath.idx" -RawLength $raw.Length
    } catch { return (& $done 14 ("OUTCOME: INCONCLUSIVE (cannot read the session: $($_.Exception.Message))")) }
    if ($j.PSObject.Properties['Schema'] -and [string]$j.Schema -ceq 'frameshift.fs-collect3d.partial.v1') {
        return (& $done 14 'OUTCOME: INCONCLUSIVE (session.json is the checkpoint of a collector run that did not finish: the readings in it and in readings3d.txt and the capture are evidence; no classification)')
    }
    if (-not $j.PSObject.Properties['Capture']) { return (& $done 14 'OUTCOME: INCONCLUSIVE (session.json has no capture record)') }
    if ((Get-FsSha256Hex $raw) -cne [string]$j.Capture.Sha256) { return (& $done 14 'OUTCOME: INCONCLUSIVE (capture.raw does not match the hash recorded by the collector)') }
    if ([string]$j.Stage -cne $script:S3dStage) { return (& $done 14 "OUTCOME: INCONCLUSIVE (the session is stage $($j.Stage), not 3d)") }
    if ($oDir) {
        try { $ob = Get-Content -Raw -ErrorAction Stop (Join-Path $oDir 'observe.json') | ConvertFrom-Json }
        catch { return (& $done 14 "OUTCOME: INCONCLUSIVE (cannot read observe.json: $($_.Exception.Message))") }
        $c1 = Get-FsStage1Class -Observe $ob -Collect $j
        $pre.Add("STAGE-1 CLASS: $($c1.Class) (derived: $($c1.Why))")
        if ($ob.PSObject.Properties['Serial']) { $pre.Add("UNIT: $($ob.Serial)$(if ($ob.PSObject.Properties['Unit']) { ' (' + $ob.Unit + ')' })") }
        $s1 = $c1.Class
    }
    $sl = Get-Fs3cSlices -Raw $raw -Events $evs
    $js = @($j.Slices)
    $same = ($sl.Count -eq $js.Count)
    for ($i = 0; $same -and $i -lt $sl.Count; $i++) { $same = ($sl[$i].Ph -ceq [string]$js[$i].Ph -and $sl[$i].Start -eq [long]$js[$i].Start -and $sl[$i].End -eq [long]$js[$i].End -and $sl[$i].Sha256 -ceq [string]$js[$i].Sha256) }
    if (-not $same) { return (& $done 14 'OUTCOME: INCONCLUSIVE (the phase slices re-derived from capture.raw and its index differ from the collector''s: refused)') }
    $phIn = New-Object System.Collections.Generic.List[object]
    $prevSha = '0000000000000000'
    $jp = @{}; foreach ($x in @($j.Phases)) { $jp[[string]$x.Ph] = $x }
    $nonceX = [string]$j.Nonce
    foreach ($ph in $script:S3dPhases) {
        $s = @($sl | Where-Object { $_.Ph -ceq $ph })
        if ($s.Count -eq 0) {
            $why = if ($jp.ContainsKey($ph) -and $jp[$ph].NotRunWhy) { [string]$jp[$ph].NotRunWhy } else { 'not requested' }
            $phIn.Add([pscustomobject]@{ Ph = $ph; Sent = $false; NotRunWhy = $why; Refusal = $null; Complete = $false; Fsb1 = $null; Chal = ''; ChainOk = $true; R3RuleHeld = $false; Markers = $null }); continue
        }
        $s = $s[0]
        $cp = Get-Fs3cSliceCompletion $s.Bytes
        $ref = if ($cp.Kind -ceq 'refusal') { Get-Fs3cRefusalInfo $cp.Line } else { $null }
        $dec = $null
        if ($cp.Kind -ceq 'record') { $dec = Test-Fsb1Record -Bytes $s.Bytes -Exp $script:S3dExp[$ph] -Nonce $nonceX -Challenge $s.Chal -Steps $script:S3dSteps[$ph] }
        $held = $false
        if ($ph -ceq 'r3' -and $jp.ContainsKey('r3') -and $null -ne $jp['r3'].R3Rule) { $held = ([bool]$jp['r3'].R3Rule.Allow -and [long]$jp['r3'].GuardLeftMs -ge [long]$jp['r3'].GuardNeedMs) }
        $mk = Get-Fs3cSliceMarkers -Bytes $s.Bytes -NonceX $nonceX -PhX $ph
        $phIn.Add([pscustomobject]@{ Ph = $ph; Sent = $true; NotRunWhy = ''; Refusal = $ref; Complete = ($cp.Kind -cne 'none'); Fsb1 = $dec; Chal = $s.Chal; ChainOk = ($s.Prev -ceq $prevSha); R3RuleHeld = $held; Markers = $mk })
        $sh = Get-Fs3cRecSha16 $s.Bytes; if ($sh) { $prevSha = $sh } else { $prevSha = '(none)' }
    }
    $rdPath = if ($ReadingsX) { $ReadingsX } else { Join-Path $cDir 'readings3d.txt' }
    $rl = $null; if (Test-Path -LiteralPath $rdPath) { $rl = [IO.File]::ReadAllLines($rdPath) }
    $sr = if ($j.PSObject.Properties['Readings']) { [string[]]@($j.Readings) } else { $null }
    $q7i = @(); if ($jp.ContainsKey('r2') -and $jp['r2'].PSObject.Properties['Q7Fallback'] -and $null -ne $jp['r2'].Q7Fallback) { $q7i = [string[]]@($jp['r2'].Q7Fallback.Items) }
    $o = Get-Fs3dOutcome -S1Class $s1 -Phases $phIn.ToArray() -ReadingLines $rl -Pin $pinX -SessionReadings $sr -Q7Items $q7i
    $lines = $pre
    foreach ($ph in $script:S3dPhases) {
        $m = $o.Phases[$ph]
        $opt = if ($ph -ceq 'r2' -or $ph -ceq 'r3') { "; optical $($o.Optical[$ph].Class)" } elseif ($ph -ceq 'r1') { "; reset seen: $($o.R1Seen)" } else { '' }
        $dk = if ($o.Dark.Contains($ph)) { "; dark check $($o.Dark[$ph])" } else { '' }
        $lines.Add("PHASE $ph : $($m.Class)$(if ($m.Tag) { ' [' + $m.Tag + ']' }) - $($m.Reason)$opt$dk")
        if ($m.Scanout) { $lines.Add("  SCANOUT $($m.Scanout)") }
        $pi = @($phIn | Where-Object { $_.Ph -ceq $ph })[0]
        if ($null -ne $pi.Markers) { $lines.Add("  markers: $($pi.Markers.Sequence)$(if (@($pi.Markers.Notes).Count) { ' (note: ' + (@($pi.Markers.Notes) -join '; ') + ')' })") }
        if (($ph -ceq 'r2' -or $ph -ceq 'r3') -and $o.Optical.Contains($ph)) { $lines.Add("  optical: $($o.Optical[$ph].Why)") }
    }
    foreach ($e in @($o.Layout.Keys)) { $x = $o.Layout[$e]; $lines.Add("LAYOUT $e eye: bars $(if ($x.Bars) { $x.Bars } else { '-' }) F $(if ($x.Orient) { $x.Orient } else { '-' }) tilt $($x.Tilt): $($x.Label) $($x.Tag); $($x.Roll)") }
    if ($o.Geometry) { $lines.Add($o.Geometry) }
    if ($o.Roll) { $lines.Add($o.Roll) }
    if ($null -ne $o.Interpretation) { $lines.Add("RUN-3 INTERPRETATION: $($o.Interpretation.Code) $($o.Interpretation.Text) $($o.Interpretation.Tag)") }
    if (-not $o.ReadingsOk) { $lines.Add("READINGS: $($o.ReadingsWhy)") }
    if (@($o.Q7NotAsked).Count) { $lines.Add("READINGS NOTE: r2 $(@($o.Q7NotAsked) -join ', ') not asked (Q7 fallback: the run-3 path)") }
    $lines.Add("OUTCOME: $($o.Outcome)   (stage 3d, README 6) $($o.Reason)")
    foreach ($lb in @($o.Labels)) { $lines.Add("LABEL: $lb") }
    $lines.Add("REGISTERED: $($o.Registered)")
    $lines.Add('A machine-side PASS is not the stage result: the stage passes only with all 8 characters read correctly in EACH eye in run 2 (the one lit picture run). The geometry (swap) and roll labels and the run-3 interpretation are diagnostic, never a PASS. The reset observation is recorded, never a gate.')
    $lines.Add('Separate gates, not part of this outcome: before/after (user build: identity and slot only; the partition hashes are not captured, <withheld document>), recovery, temperature.')
    $code = switch ($o.Outcome) { 'PASS (machine side)' { 10 } 'INTEGRITY FAULT' { 12 } 'INCONCLUSIVE' { 14 } 'NO-DISPLAY' { 15 } 'DISPLAY FAIL' { 16 } 'PRECONDITION UNMET: CRTC ACTIVE' { 17 } 'RESET ONLY' { 18 } 'RESET NOT DONE' { 19 } default { 13 } }
    $r0 = & $done $code @()
    $r0.Outcome = $o
    return $r0
}

if ($script:Fc3dInvocation -eq '.') { return }
# ------------------------------------------------------------------ CLI -----
$ErrorActionPreference = 'Stop'
try {
    $cDir = [string]$script:Fc3dArgs['C3dDir']; $oDir = [string]$script:Fc3dArgs['C3dObserveDir']; $s1 = [string]$script:Fc3dArgs['C3dStage1Class']
    if (-not $cDir -or (-not $s1 -and -not $oDir) -or ($s1 -and $oDir)) {
        Write-Output 'usage: fs-classify3d.ps1 -C3dDir <fs-collect3d output dir> (-C3dObserveDir <fs-observe3d output dir> | -C3dStage1Class <class>) [-C3dPatternPin <sha256>] [-C3dReadings <readings3d.txt>]'; exit 64 }
    $pinX = if ($script:Fc3dArgs['C3dPatternPin']) { [string]$script:Fc3dArgs['C3dPatternPin'] } else { $script:S3dPatternPin }
    if ($pinX -and $pinX -cnotmatch '^[0-9a-f]{64}\z') { Write-Output 'usage: -C3dPatternPin is 64 lowercase hex'; exit 64 }
    $res = Invoke-Fs3dClassifyDir -DirX $cDir -ObsDirX $oDir -S1X $s1 -PinX $pinX -ReadingsX ([string]$script:Fc3dArgs['C3dReadings'])
    foreach ($l in $res.Lines) { Write-Output $l }
    exit $res.Code
} catch { Write-Output (ConvertTo-FsPrintable "CLASSIFIER ERROR: $($_.Exception.Message)"); exit 70 }
