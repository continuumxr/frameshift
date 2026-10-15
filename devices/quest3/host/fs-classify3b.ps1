# FrameShift outcome classifier, STAGE 3B (trial (iii-b)), Windows PowerShell 5.1.
# Dot-sourced by fs-classify.ps1 (which keeps its stage-2a/3a rules unchanged).
# Implements devices/quest3/common/OUTCOMES.md §9 exactly (first match wins):
#   machine side (§9.4): valid FSB1, integrity, run 1's accepted commit and clean close,
#     run 2 executed from a provably inactive CRTC (show-off precondition rc=0), committed
#     and held, pause >= 2000 ms between run 1's close and run 2's commit (FSP1 monotonic
#     stamps), brightness 127 read back before each run that ran;
#   optical side (§9.5): the PM's readings, per run and per eye (a readings file, FSR1).
#
#   $o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 <Test-Fsb1Record result, exp=stage3b> `
#            -Nonce <n16> -Challenge <c32> [-Collected $true] [-PatternPin <sha256>] [-Readings <string[]>]
#   $o.Outcome   PASS (machine side) | RUN 1 ONLY | PRECONDITION UNMET: CRTC ACTIVE | NO-DISPLAY |
#                DISPLAY FAIL | INTEGRITY FAULT | INCONCLUSIVE | <stage-1 class>
#   $o.Optical   OPTICAL PASS | ONE-EYE ONLY | LIT BUT GARBLED (lighting finding, not PASS) | BOTH DARK |
#                DARK | NOT RECORDED | INCONCLUSIVE
#   $o.Labels    extra registered labels (e.g. 'RUN 1 DARK, RUN 2 LIT')
#   $o.Registered the combined registered result (OUTCOMES §9.6)
#   $o.Rule, $o.Reason, $o.StepClasses, $o.Run1, $o.Run2 (parsed facts), $o.PauseMs
Set-StrictMode -Version 2.0

$script:S3bSteps = @('hash', 'probe1', 'pattern1', 'probe2', 'pattern2')
$script:S3bPatternPin = '4c36e4d97b7a04b0e8695c3731a7f679b3034598d50e3b52f523b19b4c6b02a6'   # fs-pattern v0.5 (stage3b/build-image.sh)
$script:S3bNoDisp = @{ 10 = 'no device'; 11 = 'not a DRM node'; 12 = 'driver is not msm_drm'; 20 = 'no connected connector'; 21 = 'atomic/planes/properties unusable';
                       30 = 'mode refused by the policy'; 40 = 'buffer/framebuffer failed'; 50 = 'every TEST_ONLY attempt rejected' }

# One run's step: skip record, or a parsed fs-pattern run. Never throws on device data.
function Get-FsS3bRun { param([hashtable]$St, [int]$Run, [string]$Chal8)
    $r = [ordered]@{ Run = $Run; Kind = $null; Why = ''; Code = $null; Fsp1 = $null; Recs = @(); Committed = $false; HeldClean = $false
                     CloseClean = $false; StartMs = $null; HeldMs = $null; CloseMs = $null; CloseRc = $null; Mode = $null
                     CrtcActive = $null; ActiveProp = $null; GetCrtcRc = $null; Precond = $null }
    $tf = Test-FsS2ToolFault $St
    $out = $script:S2L1.GetString([byte[]]$St['out'])
    if ($null -ne $tf) { $r.Kind = 'toolfault'; $r.Why = $tf; return [pscustomobject]$r }
    if ($St['end'] -ceq 'exited' -and $St['code'] -eq 0 -and $out -cmatch "^FSK1 run=$Run skipped reason=([a-z0-9-]{1,40}) END\n\z") {
        $r.Kind = 'skip'; $r.Why = $Matches[1]; return [pscustomobject]$r
    }
    if (@('timer-term', 'timer-kill', 'signaled', 'exec-failed') -ccontains $St['end']) {
        $r.Kind = 'hang'; $r.Why = "end=$($St['end']) sig=$($St['sig']) term_ms=$($St['term_ms']) kill_ms=$($St['kill_ms']) errno=$($St['errno'])"; return [pscustomobject]$r
    }
    if ($St['end'] -cne 'exited') { $r.Kind = 'other'; $r.Why = "end=$($St['end'])"; return [pscustomobject]$r }
    $fs = Test-FsFsp1Stream ([byte[]]$St['out'])
    $r.Fsp1 = "$($fs.Status) ($($fs.Why))"
    $bad = $null
    if ($fs.Status -cne 'COMPLETE') { $bad = "FSP1 stream $($fs.Status): $($fs.Why)" }
    elseif ($St['out_kept'] -ne $St['out_total']) { $bad = 'FSP1 capture truncated (kept < total)' }
    elseif ($St['err_total'] -ne 0) { $bad = "fs-pattern wrote $($St['err_total']) bytes to stderr" }
    else {
        $wrong = @($fs.Records | Where-Object { $_.Nonce -cne $Chal8 })
        $ex = @($fs.Records | Where-Object { $_.Step -ceq 'exit' })
        if ($wrong.Count) { $bad = "FSP1 nonce $($wrong[0].Nonce) is not chal[0:8] $Chal8" }
        elseif ($ex.Count -ne 1 -or $ex[0].Kv['code'] -cne [string]$St['code']) { $bad = "FSP1 exit code does not equal the process exit code $($St['code'])" }
    }
    if ($bad) { $r.Kind = 'unsound'; $r.Why = $bad; return [pscustomobject]$r }
    $recs = @($fs.Records); $r.Recs = $recs; $r.Kind = 'run'; $r.Code = [long]$St['code']
    $st0 = @($recs | Where-Object { $_.Step -ceq 'start' })
    if ($st0.Count -eq 1) { $r.Mode = $st0[0].Kv['mode'] }
    $cs = @($recs | Where-Object { $_.Step -ceq 'crtc_state' })
    if ($cs.Count -eq 1) { $r.CrtcActive = $cs[0].Kv['active']; $r.ActiveProp = $cs[0].Kv['active_prop']; $r.GetCrtcRc = $cs[0].Kv['getcrtc_rc'] }
    $pc = @($recs | Where-Object { $_.Step -ceq 'precondition' })
    if ($pc.Count -eq 1) { $r.Precond = [pscustomobject]@{ Rc = $pc[0].Rc; Active = $pc[0].Kv['active']; ActiveProp = $pc[0].Kv['active_prop']; GetCrtcRc = $pc[0].Kv['getcrtc_rc'] } }
    $cm = @($recs | Where-Object { $_.Step -ceq 'commit' })
    $hs = @($recs | Where-Object { $_.Step -ceq 'hold_start' })
    $he = @($recs | Where-Object { $_.Step -ceq 'hold_end' })
    $ex = @($recs | Where-Object { $_.Step -ceq 'exit' })[0]
    $r.Committed = ($cm.Count -eq 1 -and $cm[0].Rc -eq 0)
    if ($hs.Count -eq 1 -and $hs[0].Kv['start_ms'] -cmatch '^[0-9]{1,15}\z') { $r.StartMs = [long]$hs[0].Kv['start_ms'] }
    if ($he.Count -eq 1) {
        if ($he[0].Kv['held_ms'] -cmatch '^[0-9]{1,15}\z') { $r.HeldMs = [long]$he[0].Kv['held_ms'] }
        if ($he[0].Kv['close_ms'] -cmatch '^[0-9]{1,15}\z') { $r.CloseMs = [long]$he[0].Kv['close_ms'] }
        $r.CloseRc = $he[0].Kv['close_rc']
    }
    $r.HeldClean = ($r.Committed -and $he.Count -eq 1 -and $he[0].Rc -eq 0 -and $he[0].Kv['reason'] -ceq 'deadline' -and
                    $ex.Rc -eq 0 -and $ex.Kv['code'] -ceq '0' -and $ex.Kv['reason'] -ceq 'held_to_deadline' -and $ex.Kv['shown'] -ceq '1')
    $r.CloseClean = ($r.HeldClean -and $r.CloseRc -ceq '0')
    [pscustomobject]$r
}

# The backlight evidence in a probe step's text: write lines, read-back values.
function Get-FsS3bProbeBl { param([hashtable]$St)
    $t = $script:S2L1.GetString([byte[]]$St['out'])
    $w = [regex]::Matches($t, '(?m)^== backlight-write node=/sys/class/backlight/panel0-backlight/brightness value=127 ').Count
    $rb = [regex]::Matches($t, '(?m)^(?:write_rc=\S+ )?readback=(\S+)$')
    $vals = @($rb | ForEach-Object { $_.Groups[1].Value })
    [pscustomobject]@{ Writes = $w; Readbacks = $vals; End = $St['end']; Note = "end=$($St['end']) out=$($St['out_kept'])/$($St['out_total']) bytes" }
}

# The PM's readings: exactly 4 lines "FSR1 run=<1|2> eye=<left|right> obs=<DARK|LIT|GARBLED|READ> [chars=<8 of 0-9A-F?>]"
function ConvertFrom-FsS3bReadings { param([string[]]$Lines)
    $m = @{}
    foreach ($l in @($Lines | Where-Object { $_ -and -not $_.StartsWith('#') })) {
        if ($l -cnotmatch '^FSR1 run=([12]) eye=(left|right) obs=(DARK|LIT|GARBLED|READ)(?: chars=([0-9A-F?]{8}))?\z') { throw "readings: malformed line '$l'" }
        $k = "$($Matches[1]):$($Matches[2])"
        if ($m.ContainsKey($k)) { throw "readings: run $($Matches[1]) eye $($Matches[2]) given twice" }
        if (($Matches[3] -ceq 'READ') -xor ($null -ne $Matches[4] -and $Matches[4] -ne '')) { throw "readings: chars= is required with READ and only with READ ('$l')" }
        $m[$k] = [pscustomobject]@{ Obs = $Matches[3]; Chars = $(if ($Matches[3] -ceq 'READ') { $Matches[4] } else { $null }) }
    }
    foreach ($k in '1:left', '1:right', '2:left', '2:right') { if (-not $m.ContainsKey($k)) { throw "readings: run/eye $k missing" } }
    $m
}

function Get-FsStage3bOutcomeCore {
    param([Parameter(Mandatory)][string]$Stage1Class, $Fsb1, [string]$Nonce, [string]$Challenge, [bool]$Collected = $true,
          [string]$PatternPin = '', [string[]]$Readings = $null, [string]$RunnerRefusal = '')
    if (-not $PatternPin) { $PatternPin = $script:S3bPatternPin }
    $rr = if ($RunnerRefusal) { "; runner refusal: $RunnerRefusal" } else { '' }
    $o = [ordered]@{ Outcome = $null; Rule = 0; Reason = ''; Optical = 'NOT RECORDED'; OpticalReason = 'no readings file'; Labels = @(); Registered = $null
                     StepClasses = @(); Run1 = $null; Run2 = $null; PauseMs = $null; Brightness = $null }
    $fin = { param($out, $rule, $why) $o.Outcome = $out; $o.Rule = $rule; $o.Reason = $why; [pscustomobject]$o }
    if ($Stage1Class -cne 'PASS') { return (& $fin $Stage1Class 1 'stage 1 did not PASS; any FSB1 text is data only') }
    if ($null -eq $Fsb1) { return (& $fin 'INCONCLUSIVE' 2 "no FSB1 record$rr") }
    if (-not $Collected) { return (& $fin 'INCONCLUSIVE' 2 "no complete record by the host collection deadline$rr") }
    if (-not $Fsb1.Ok) { return (& $fin 'INCONCLUSIVE' 2 "FSB1 rejected: $($Fsb1.Reason)$rr") }
    $steps = @($Fsb1.Steps)
    if ((@($steps | ForEach-Object { $_['id'] }) -join ',') -cne ($script:S3bSteps -join ',')) { return (& $fin 'INCONCLUSIVE' 3 'decoded steps are not the stage-3b list') }
    if ($Nonce -cnotmatch '^[0-9a-f]{16}\z' -or $Challenge -cnotmatch '^[0-9a-f]{32}\z') { return (& $fin 'INCONCLUSIVE' 3 'nonce/challenge missing') }
    $c8 = $Challenge.Substring(0, 8)
    $h = $steps[0]; $p1 = $steps[1]; $r1s = $steps[2]; $p2 = $steps[3]; $r2s = $steps[4]
    $cls = New-Object System.Collections.Generic.List[object]
    $tfh = Test-FsS2ToolFault $h
    $hc = if ($null -ne $tfh) { @{ Class = 'TOOL FAULT'; Mismatch = $false; Notes = $tfh } } else { Get-FsS3HashClass $h $PatternPin }
    $cls.Add([pscustomobject]@{ I = 1; Id = 'hash'; Class = $hc.Class; Mismatch = $hc.Mismatch; Notes = $hc.Notes })
    $b1 = Get-FsS3bProbeBl $p1; $b2 = Get-FsS3bProbeBl $p2
    $cls.Add([pscustomobject]@{ I = 2; Id = 'probe1'; Class = 'INFO'; Mismatch = $false; Notes = "$($b1.Note); backlight writes=$($b1.Writes) readback=$(@($b1.Readbacks) -join ',')" })
    $run1 = Get-FsS3bRun $r1s 1 $c8; $o.Run1 = $run1
    $cls.Add([pscustomobject]@{ I = 3; Id = 'pattern1'; Class = $run1.Kind; Mismatch = $false; Notes = $(if ($run1.Kind -ceq 'run') { "code=$($run1.Code) committed=$($run1.Committed) held=$($run1.HeldClean) close_rc=$($run1.CloseRc) crtc_active=$($run1.CrtcActive)" } else { $run1.Why }) })
    $cls.Add([pscustomobject]@{ I = 4; Id = 'probe2'; Class = 'INFO'; Mismatch = $false; Notes = "$($b2.Note); readback=$(@($b2.Readbacks) -join ',')" })
    $run2 = Get-FsS3bRun $r2s 2 $c8; $o.Run2 = $run2
    $cls.Add([pscustomobject]@{ I = 5; Id = 'pattern2'; Class = $run2.Kind; Mismatch = $false; Notes = $(if ($run2.Kind -ceq 'run') { "code=$($run2.Code) mode=$($run2.Mode) crtc_active=$($run2.CrtcActive) committed=$($run2.Committed) held=$($run2.HeldClean)" } else { $run2.Why }) })
    $o.StepClasses = $cls.ToArray()
    $bl1 = ($b1.Writes -eq 1 -and @($b1.Readbacks).Count -ge 1 -and @($b1.Readbacks)[0] -ceq '127')
    $bl2 = (@($b2.Readbacks).Count -ge 1 -and @($b2.Readbacks)[0] -ceq '127' -and $b2.Writes -eq 0)
    $o.Brightness = "before run 1: $(if ($bl1) { 'written once, read back 127' } else { 'NOT verified' }); before run 2: $(if ($bl2) { 'read back 127 (no write)' } else { 'NOT verified' })"
    # §9.4 rules 4, 5: integrity
    if ($hc.Class -ceq 'MEASURED' -and $hc.Mismatch) { return (& $fin 'INTEGRITY FAULT' 4 "hash: $($hc.Notes)") }
    if ($hc.Class -cne 'MEASURED') { return (& $fin 'INCONCLUSIVE' 5 "integrity unmeasured: hash $($hc.Class) ($($hc.Notes))") }
    # rule 6: probe1 must show at most one write (a second write is never allowed)
    if ($b1.Writes -gt 1 -or $b2.Writes -ne 0) { return (& $fin 'INCONCLUSIVE' 6 "backlight write count wrong (probe1 $($b1.Writes), probe2 $($b2.Writes)): the runner is not the registered one") }
    # rules 7-14: run 1
    switch -CaseSensitive ($run1.Kind) {
        'toolfault' { return (& $fin 'INCONCLUSIVE' 7 "our side failed in run 1's step: $($run1.Why)") }
        'skip'      { if ($run2.Kind -cne 'skip') { return (& $fin 'INCONCLUSIVE' 6 'run 1 skipped but run 2 not skipped: runner inconsistency') }
                      return (& $fin 'INCONCLUSIVE' 8 "run 1 not run ($($run1.Why)); no display experiment took place") }
        'hang'      { return (& $fin 'DISPLAY FAIL' 9 "run 1 hung or was not runnable: $($run1.Why)") }
        'other'     { return (& $fin 'INCONCLUSIVE' 14 "run 1 $($run1.Why)") }
        'unsound'   { return (& $fin 'INCONCLUSIVE' 10 "run 1 evidence unreadable: $($run1.Why)") }
    }
    if (-not $bl1) { return (& $fin 'INCONCLUSIVE' 11 'run 1 ran but probe1 does not show the single write with read-back 127: runner inconsistency') }
    if ($run1.Mode -cne 'show') { return (& $fin 'INCONCLUSIVE' 11 "run 1 mode is '$($run1.Mode)', not show") }
    if ($run2.Kind -cne 'skip' -and -not $run1.CloseClean) { return (& $fin 'INCONCLUSIVE' 6 'run 2 ran although run 1 had no accepted commit and clean close: runner inconsistency') }
    if ($script:S3bNoDisp.ContainsKey([int]$run1.Code)) { return (& $fin 'NO-DISPLAY' 12 "run 1: fs-pattern exit $($run1.Code) ($($script:S3bNoDisp[[int]$run1.Code])): no real commit was made") }
    if ($run1.Code -eq 60 -or $run1.Code -eq 1) { return (& $fin 'DISPLAY FAIL' 13 "run 1: fs-pattern exit $($run1.Code)") }
    if ($run1.Code -ne 0 -or -not $run1.HeldClean) { return (& $fin 'INCONCLUSIVE' 14 "run 1: exit $($run1.Code) without commit rc=0, hold_end reason=deadline and exit shown=1") }
    # run 1 committed and held. Rules 15-24: run 2
    if (-not $run1.CloseClean) { return (& $fin 'RUN 1 ONLY' 15 "run 1 committed and held, but its close was not clean (close_rc=$($run1.CloseRc)); run 2 not executed ($($run2.Why))") }
    switch -CaseSensitive ($run2.Kind) {
        'skip'      { return (& $fin 'RUN 1 ONLY' 16 "run 1 committed and closed cleanly; run 2 not executed ($($run2.Why)): no off->on experiment") }
        'toolfault' { return (& $fin 'INCONCLUSIVE' 17 "our side failed in run 2's step: $($run2.Why)") }
        'hang'      { return (& $fin 'DISPLAY FAIL' 18 "run 2 hung or was not runnable: $($run2.Why)") }
        'other'     { return (& $fin 'INCONCLUSIVE' 24 "run 2 $($run2.Why)") }
        'unsound'   { return (& $fin 'INCONCLUSIVE' 19 "run 2 evidence unreadable: $($run2.Why)") }
    }
    if (-not $bl2) { return (& $fin 'INCONCLUSIVE' 20 'run 2 ran but probe2 does not show the read-back 127: runner inconsistency') }
    if ($run2.Mode -cne 'show-off') { return (& $fin 'INCONCLUSIVE' 20 "run 2 mode is '$($run2.Mode)', not show-off") }
    if ($run2.Code -eq 31) {
        if ($null -ne $run2.Precond -and $run2.Precond.Rc -eq -16 -and -not $run2.Committed) {
            return (& $fin 'PRECONDITION UNMET: CRTC ACTIVE' 21 "run 2 found the CRTC not provably inactive (active=$($run2.Precond.Active) active_prop=$($run2.Precond.ActiveProp) getcrtc_rc=$($run2.Precond.GetCrtcRc)) and committed nothing: no off->on claim")
        }
        return (& $fin 'INCONCLUSIVE' 24 'run 2 exit 31 without the precondition record')
    }
    $preOk = ($null -ne $run2.Precond -and $run2.Precond.Rc -eq 0 -and $run2.Precond.Active -ceq '0' -and $run2.Precond.ActiveProp -cmatch '^[1-9][0-9]*\z' -and
              $run2.Precond.GetCrtcRc -ceq '0' -and $run2.CrtcActive -ceq '0')
    if (-not $preOk) { return (& $fin 'INCONCLUSIVE' 24 'run 2 has no proof of an inactive CRTC at start (precondition rc=0, crtc_state active=0)') }
    if ($script:S3bNoDisp.ContainsKey([int]$run2.Code)) { return (& $fin 'NO-DISPLAY' 22 "run 1 committed; run 2: fs-pattern exit $($run2.Code) ($($script:S3bNoDisp[[int]$run2.Code])): no commit in run 2") }
    if ($run2.Code -eq 60 -or $run2.Code -eq 1) { return (& $fin 'DISPLAY FAIL' 22 "run 1 committed; run 2: fs-pattern exit $($run2.Code)") }
    if ($run2.Code -ne 0 -or -not $run2.HeldClean) { return (& $fin 'INCONCLUSIVE' 24 "run 2: exit $($run2.Code) without commit rc=0, hold_end reason=deadline and exit shown=1") }
    if ($null -eq $run1.StartMs -or $null -eq $run1.HeldMs -or $null -eq $run1.CloseMs -or $null -eq $run2.StartMs) { return (& $fin 'INCONCLUSIVE' 23 'monotonic stamps for the pause are missing') }
    $o.PauseMs = $run2.StartMs - ($run1.StartMs + $run1.HeldMs + $run1.CloseMs)
    if ($o.PauseMs -lt 2000) { return (& $fin 'INCONCLUSIVE' 23 "pause between run 1's close and run 2's commit is $($o.PauseMs) ms (< 2000): not the registered experiment") }
    return (& $fin 'PASS (machine side)' 25 "run 1 committed and closed cleanly; run 2 committed from an inactive CRTC (DRM state; physical panel-off not proven) and held to its deadline; pause $($o.PauseMs) ms; brightness 127 verified before both runs [machine side only: the result is the PM's per-eye reading]")
}

# §9.5 optical, §9.6 combined. Never throws on bad readings: they make the optical side INCONCLUSIVE.
function Add-FsS3bOptical { param($O, [string[]]$Readings, [string]$Challenge)
    if ($null -eq $Readings) { $O.Registered = "not a stage PASS: machine $($O.Outcome); optical NOT RECORDED"; return $O }
    try { $rd = ConvertFrom-FsS3bReadings $Readings }
    catch { $O.Optical = 'INCONCLUSIVE'; $O.OpticalReason = (ConvertTo-FsPrintable $_.Exception.Message); $O.Registered = "not a stage PASS: machine $($O.Outcome); optical INCONCLUSIVE (readings unusable)"; return $O }
    $want = $Challenge.Substring(0, 8).ToUpperInvariant()
    $ok = { param($x) $x.Obs -ceq 'READ' -and $x.Chars -ceq $want }
    $lit = { param($x) $x.Obs -ceq 'LIT' -or $x.Obs -ceq 'GARBLED' -or $x.Obs -ceq 'READ' }
    $shown1 = ($O.Rule -ge 6 -and $null -ne $O.Run1 -and $O.Run1.Kind -ceq 'run' -and $O.Run1.HeldClean)
    $shown2 = ($O.Outcome -ceq 'PASS (machine side)')
    # per run: 'shown' (the record shows it committed and held), 'not' (the record shows it did not
    # commit: skipped, or a no-commit exit), 'unknown' (record absent or unusable for that run)
    $st = @{}
    foreach ($r in 1, 2) {
        $run = if ($r -eq 1) { $O.Run1 } else { $O.Run2 }
        $sh = if ($r -eq 1) { $shown1 } else { $shown2 }
        if ($sh) { $st[$r] = 'shown' }
        elseif ($O.Rule -lt 6 -or $null -eq $run) { $st[$r] = 'unknown' }
        elseif ($run.Kind -ceq 'skip' -or ($run.Kind -ceq 'run' -and -not $run.Committed)) { $st[$r] = 'not' }
        else { $st[$r] = 'unknown' }
    }
    $both = @(); $one = @(); $oneRuns = @()
    foreach ($r in 1, 2) {
        $l = & $ok $rd["${r}:left"]; $g = & $ok $rd["${r}:right"]
        if ($l -and $g) { $both += $r } elseif ($l -or $g) { $one += "run $r $(if ($l) { 'left' } else { 'right' })"; $oneRuns += $r }
    }
    $labels = New-Object System.Collections.Generic.List[string]
    $r1dark = ($rd['1:left'].Obs -ceq 'DARK' -and $rd['1:right'].Obs -ceq 'DARK')
    $r2lit = ((& $lit $rd['2:left']) -or (& $lit $rd['2:right']))
    if ($r1dark -and $r2lit -and $shown2) { $labels.Add('RUN 1 DARK, RUN 2 LIT') }
    if ($O.Outcome -ceq 'PRECONDITION UNMET: CRTC ACTIVE') { $labels.Add('PRECONDITION UNMET: no off->on claim for run 2') }
    $anyLit = @('1:left', '1:right', '2:left', '2:right' | Where-Object { & $lit $rd[$_] }).Count -gt 0
    $allDark = -not $anyLit -and @('1:left', '1:right', '2:left', '2:right' | Where-Object { $rd[$_].Obs -cne 'DARK' }).Count -eq 0
    $passRun = @($both | Where-Object { ($_ -eq 1 -and $shown1) -or ($_ -eq 2 -and $shown2) })
    if ($passRun.Count) {
        $O.Optical = 'OPTICAL PASS'; $O.OpticalReason = "all 8 characters read correctly in each eye in run $($passRun[0]) (the record shows that run committed and held)"
    } elseif ($both.Count) {
        $r = $both[0]
        $O.Optical = 'INCONCLUSIVE'
        $O.OpticalReason = if ($st[$r] -ceq 'not') { "both eyes read correctly in run ${r}, but the record shows that run made no commit: CONTRADICTS the record" }
                           else { "both eyes read correctly in run ${r}, but the record is absent or unusable for that run (no record, rejected, over the size cap, tool fault, integrity fault, or not the registered run): the commit cannot be confirmed" }
    } elseif (@($oneRuns | Where-Object { $st[$_] -ceq 'shown' }).Count) {
        $O.Optical = 'ONE-EYE ONLY'; $O.OpticalReason = "correct reading in one eye only ($($one -join '; ')) in a run the record shows committed and held: a display result to investigate, not a PASS"
    } elseif ($one.Count) {
        $O.Optical = 'INCONCLUSIVE'
        $O.OpticalReason = if (@($oneRuns | Where-Object { $st[$_] -ceq 'not' }).Count) { "a correct one-eye reading ($($one -join '; ')) in a run the record shows made no commit: CONTRADICTS the record" }
                           else { "a correct one-eye reading ($($one -join '; ')) in a run for which the record is absent or unusable: cannot be confirmed" }
    } elseif ($anyLit) {
        $O.Optical = 'LIT BUT GARBLED (lighting finding, not PASS)'; $O.OpticalReason = (@('1:left', '1:right', '2:left', '2:right' | ForEach-Object { "$_=$($rd[$_].Obs)$(if ($rd[$_].Chars) { ':' + $rd[$_].Chars })" }) -join ' ')
    } elseif ($allDark -and $shown1 -and $shown2) {
        $O.Optical = 'BOTH DARK'; $O.OpticalReason = 'no light seen in either run, in either eye (not a measurement of zero emitted light); both runs committed, run 2 from an inactive CRTC'
    } else {
        $O.Optical = 'DARK'; $O.OpticalReason = 'no light reported (no light seen is not a measurement of zero emitted light or exposure)'
    }
    $O.Labels = $labels.ToArray()
    $stagePass = ($O.Optical -ceq 'OPTICAL PASS' -and ($O.Outcome -ceq 'PASS (machine side)' -or ($O.Outcome -ceq 'RUN 1 ONLY' -and $passRun -contains 1) -or
                  ($O.Outcome -ceq 'PRECONDITION UNMET: CRTC ACTIVE' -and $passRun -contains 1)))
    $O.Registered = "$(if ($stagePass) { 'STAGE PASS' } else { 'not a stage PASS' }): machine $($O.Outcome); optical $($O.Optical)$(if ($labels.Count) { '; ' + ($labels -join '; ') })"
    $O
}

function Get-FsStage3bOutcome {
    param([Parameter(Mandatory)][string]$Stage1Class, $Fsb1, [string]$Nonce, [string]$Challenge, [bool]$Collected = $true, [string]$PatternPin = '',
          [string[]]$Readings = $null, [string]$RunnerRefusal = '')
    $ErrorActionPreference = 'Stop'
    try { $o = Get-FsStage3bOutcomeCore -Stage1Class $Stage1Class -Fsb1 $Fsb1 -Nonce $Nonce -Challenge $Challenge -Collected $Collected -PatternPin $PatternPin -RunnerRefusal $RunnerRefusal
          $o = Add-FsS3bOptical $o $Readings $Challenge }
    catch { return [pscustomobject]@{ Outcome = 'INCONCLUSIVE'; Rule = 26; Reason = 'classifier error: ' + (ConvertTo-FsPrintable $_.Exception.Message); Optical = 'INCONCLUSIVE'
                                      OpticalReason = 'classifier error'; Labels = @(); Registered = 'not a stage PASS: classifier error'; StepClasses = @(); Run1 = $null; Run2 = $null; PauseMs = $null; Brightness = $null } }
    $o.Reason = ConvertTo-FsPrintable $o.Reason
    $o.OpticalReason = ConvertTo-FsPrintable $o.OpticalReason
    foreach ($c in @($o.StepClasses)) { $c.Notes = ConvertTo-FsPrintable $c.Notes }
    $o
}
