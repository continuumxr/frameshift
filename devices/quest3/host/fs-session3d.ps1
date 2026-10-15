# FrameShift stage 3d: the PM's prompts (Windows PowerShell 5.1, no modules). A library, dot-sourced by fs-collect3d.ps1
# and test-host3d.ps1 after the stage-3c session library (fs-session3c.ps1, unchanged: sounds, banners, keys,
# Wait-Fs3cKey, Add-Fs3cReading, the preflight sound check). Nothing here touches the device or a port.
#
# Stage-3d differences (devices/quest3/stage3d/README.md section 6, HOST.md):
#   New-Fs3dInteract     = New-Fs3cInteract with the readings in readings3d.txt and the checkpoint schema
#                          frameshift.fs-collect3d.partial.v1 (every answer on disk at once, as stage 3c).
#   Invoke-Fs3dResetQuestion (NEW): after r1, the non-lit display reset, the ONE recorded, non-gating question of the PM
#                          decision J-130: "Anything visible during the reset (r1)?". The keys (review 2 MINOR-2: never n, which
#                          aborts elsewhere): y = yes, something was visible; b = no, it stayed dark (b = dark, as at the run-2
#                          eye questions). Both are recorded (FSR2 p=r1 item=seen obs=SEEN|NOT_SEEN) and lead on to run 2; x
#                          aborts; n is NOT an answer here: it prints what y and b mean and the question stays (it is never
#                          read as "no" and never as an abort); no answer within 30 s ends the session safely (as every
#                          prompt).
#   Invoke-Fs3dGap        = COPY of Invoke-Fs3cGap (run 2 and run 3 prompts). Differences: shorter, plainer prompt lines (PM
#                          feedback: one step at a time, clear key lists); the per-eye TILT item reads the 21-degree roll
#                          correction: 0 = level, r = turned clockwise (right end lower), l = turned counter-clockwise (left
#                          end lower), ? = can't tell (obs LEVEL / CLOCKWISE / COUNTERCLOCKWISE / UNKNOWN); the F prompt's can't-tell
#                          is ? too (stage 3c: 0), so 0 never means can't tell in stage 3d (review MINOR-2). Review 2 MAJOR-1:
#                          per eye the TILT is asked first (the PM's main goal: the 21-degree correction), then the F, then
#                          the bars; a timeout at one of these diagnostic items is recorded (TIMEOUT) and the next item is
#                          asked (stage 3c ended the session there and lost every later item), except on the run-3 path,
#                          where it still ends the session safely (no lit run 3 after an unanswered prompt; review 3
#                          MAJOR-A); x always ends the session safely; the run-3 rule (rules 1-4) is unchanged. The items,
#                          the eye and dark-check timeouts, the key-repeat window, the Q7 fallback (no bar-count prompt on the
#                          run-3 path) and `n` only at the dark check are stage 3c's.
# No machine fact is ever printed by this file.
Set-StrictMode -Version 2.0
if (-not (Get-Command Invoke-Fs3cGap -CommandType Function -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'fs-session3c.ps1') }

# The stage-3c interaction object with the stage-3d readings file and checkpoint schema.
function New-Fs3dInteract {
    param($Ctx = $null, [Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Keys, [Parameter(Mandatory)]$Sound,
          [DateTime]$UtcBase = [DateTime]::MinValue, [long]$UtcBaseMs = 0, [int]$PollMsX = 50, [string]$OutDirX = '')
    $x = New-Fs3cInteract -Ctx $Ctx -Ui $Ui -Keys $Keys -Sound $Sound -UtcBase $UtcBase -UtcBaseMs $UtcBaseMs -PollMsX $PollMsX -OutDirX $OutDirX
    $x.ReadingsPath = $(if ($OutDirX) { Join-Path $OutDirX 'readings3d.txt' } else { '' })
    $x | Add-Member -Force ScriptMethod Checkpoint { param([string]$line)
        $enc = New-Object System.Text.UTF8Encoding($false)
        if ($this.ReadingsPath) { try { [IO.File]::AppendAllText($this.ReadingsPath, "$line`n", $enc) } catch { $this.Events.Add("$($this.Now()) readings-append-failed $($_.Exception.Message)") } }
        if ($this.SessionPath) {
            try {
                $cp = [ordered]@{ Schema = 'frameshift.fs-collect3d.partial.v1'; Note = 'checkpoint written after every reading; the collector replaces it with the final session.json when it finishes'
                                  Nonce = $(if ($null -ne $this.Ctx) { $this.Ctx.Cfg.Nonce } else { $null }); UpdatedUtc = $this.Utc($this.Now())
                                  Sent = $(if ($null -ne $this.Ctx) { @($this.Ctx.Sent.ToArray()) } else { @() }); Readings = @($this.Readings.ToArray()); Events = @($this.Events.ToArray()) }
                [IO.File]::WriteAllText($this.SessionPath, (($cp | ConvertTo-Json -Depth 4) + "`n"), $enc)
            } catch { $this.Events.Add("$($this.Now()) checkpoint-failed $($_.Exception.Message)") }
        }
    }
    $x
}

# The one question after the reset (PM J-130). Returns @{ Safe = $null|'abort'|'timeout'|'stray'; SafeWhy; Item; NextLost }.
#   -AbortNoted: x was pressed during the reset; the question is still asked (the observation is the useful part), then
#                the session ends safely whatever the answer.
#   -NextGuardMs: run 2's guard (the countdown "N s left to keep RUN 2 possible").
function Invoke-Fs3dResetQuestion {
    param([Parameter(Mandatory)]$X, [Parameter(Mandatory)][long]$LastEndMs, [Parameter(Mandatory)][long]$GiveUpMsX, [int]$DoneReserveSec = 3, [int]$GapCapSec = 110,
          [int]$PromptTimeoutSec = 30, [long]$NextGuardMs = 0, [bool]$AbortNoted = $false)
    $cutoff = [Math]::Min($GiveUpMsX - [long]$DoneReserveSec * 1000, $LastEndMs + [long]$GapCapSec * 1000)
    $res = [ordered]@{ Safe = $null; SafeWhy = ''; Item = $null; NextLost = $false; CutoffMs = $cutoff }
    $now = $X.Now()
    $X.Poll()
    $dr = @($X.Keys.Drain($now))
    if ($dr.Count) { $X.Event("keys-discarded before r1/seen n=$($dr.Count) keys=$($dr -join ',')") }
    if ($X.Stray) {
        $res.Item = Add-Fs3cReading -X $X -Ph 'r1' -Item 'seen' -Obs 'NOT_ASKED' -PromptMs $now
        $res.Safe = 'stray'; $res.SafeWhy = 'bytes arrived from the device after the settled prompt (the shell state changed)'
        return [pscustomobject]$res
    }
    $X.Ui.Banner('answer', 'DISPLAY RESET DONE - ONE QUESTION', 'Anything visible during the reset? y = yes, b = no, it stayed dark, x = abort')
    $X.Sound.Play('ANSWER', $now)
    $X.Keys.Arm('p', $now)
    $left = [long][Math]::Floor(($GiveUpMsX - $NextGuardMs - $now) / 1000)
    if (-not $AbortNoted -and $left -gt 0) { $X.Ui.Line("$left s left to keep RUN 2 possible") }
    $X.Ui.Line('RESET: did you see anything (light, a picture, a flash) during the reset?   y = yes, something   b = no, it stayed dark   x = abort')
    $tick = { if (-not $res.NextLost -and -not $AbortNoted -and ($GiveUpMsX - $NextGuardMs - $X.Now()) -le 0) { $res.NextLost = $true; $X.Ui.Line('RUN 2 NO LONGER POSSIBLE: answer; the session then ends with fs-done.'); $X.Event('next-lost r2') } }
    $dl = [Math]::Min($now + [long]$PromptTimeoutSec * 1000, $cutoff)
    # review 2 MINOR-2: n is not an answer here (elsewhere it aborts); it is taken, explained, and the question stays
    while ($true) {
        $w = Wait-Fs3cKey -X $X -Allowed @('y', 'b', 'x', 'n') -DeadlineMs $dl -OnTick $tick -Label 'r1/seen'
        if ($w.TimedOut -or $w.Key -cne 'n') { break }
        $X.Event('reset-question n is not an answer (y or b)')
        $X.Ui.Line('RESET: n is not an answer here. Press y if you saw anything, b if it stayed dark (x = abort).')
    }
    if ($w.TimedOut) {
        $res.Item = Add-Fs3cReading -X $X -Ph 'r1' -Item 'seen' -Obs 'TIMEOUT' -PromptMs $now -Discarded $dr.Count
        $X.Ui.Line('RESET: TIMEOUT'); $res.Safe = 'timeout'; $res.SafeWhy = 'the reset question timed out'
    } else {
        $map = @{ y = @('SEEN', 'SOMETHING WAS VISIBLE (recorded; run 2 still follows)'); b = @('NOT_SEEN', 'NOTHING VISIBLE (it stayed dark)'); x = @('ABORT', 'ABORT') }
        $res.Item = Add-Fs3cReading -X $X -Ph 'r1' -Item 'seen' -Key $w.Key -Obs $map[$w.Key][0] -PromptMs $now -AnswerMs $w.Ms -Discarded $dr.Count
        $X.Ui.Line("RESET: $($map[$w.Key][1])")
        if ($w.Key -ceq 'x') { $res.Safe = 'abort'; $res.SafeWhy = 'x at the reset question' }
    }
    if ($null -eq $res.Safe -and $X.Stray) { $res.Safe = 'stray'; $res.SafeWhy = 'bytes arrived from the device after the settled prompt (the shell state changed)' }
    $X.Event("reset-question safe=$($res.Safe)")
    [pscustomobject]$res
}

$script:Fs3dTiltKeys = [ordered]@{ '0' = @('LEVEL', 'LEVEL'); r = @('CLOCKWISE', 'TURNED CLOCKWISE (right end lower)'); l = @('COUNTERCLOCKWISE', 'TURNED COUNTER-CLOCKWISE (left end lower)'); '?' = @('UNKNOWN', "CAN'T TELL") }
# review MINOR-2: "can't tell" is ? in BOTH the F and the tilt prompt (0 is LEVEL in the tilt prompt and nothing in the F prompt)
$script:Fs3dOrientKeys = [ordered]@{ u = @('UPRIGHT', 'F UPRIGHT'); i = @('HALF_TURN', 'F UPSIDE DOWN (half-turn)'); m = @('MIRRORED', 'F MIRRORED'); v = @('VFLIP', 'F FLIPPED TOP-BOTTOM'); '?' = @('UNKNOWN', "F: CAN'T TELL") }

# COPY of Invoke-Fs3cGap (fs-session3c.ps1) for runs 2 and 3. Differences: the prompt lines (shorter) and the tilt item
# (Fs3dTiltKeys); see the header. Same parameters and result.
function Invoke-Fs3dGap {
    param([Parameter(Mandatory)]$X, [Parameter(Mandatory)][string]$Ph, [string]$Mode = 'full', [bool]$Layout = $false,
          [Parameter(Mandatory)][long]$LastEndMs, [Parameter(Mandatory)][long]$GiveUpMsX, [int]$DoneReserveSec = 3, [int]$GapCapSec = 110,
          [int]$PromptTimeoutSec = 30, [int]$LayoutMinSec = 10, [string]$NextName = '', [long]$NextGuardMs = 0, [scriptblock]$BarsQ7 = $null)
    $runN = $Ph.Substring(1, 1)
    $cutoff = [Math]::Min($GiveUpMsX - [long]$DoneReserveSec * 1000, $LastEndMs + [long]$GapCapSec * 1000)
    $res = [ordered]@{ Safe = $null; SafeWhy = ''; Items = @{}; NextLost = $false; CutoffMs = $cutoff; FirstPromptMs = $null; LastAnswerMs = $null; BarsQ7 = @(); LayoutTimeouts = @() }
    $st = @{ Lost = $false; First = $true; LastKey = ''; LastMs = [long]-100000 }
    $ru = { [long]$st.LastMs + $script:Fs3cRepeatMs }
    $acc = { param($w) if ($null -ne $w -and -not $w.TimedOut) { $st.LastKey = [string]$w.Key; $st.LastMs = [long]$w.Ms } }
    $tick = {
        if ($NextName -and -not $st.Lost -and ($GiveUpMsX - $NextGuardMs - $X.Now()) -le 0) {
            $st.Lost = $true; $res.NextLost = $true
            $X.Ui.Line("RUN $($NextName.Substring(1,1)) NO LONGER POSSIBLE: finish the answers; the session then ends with fs-done.")
            $X.Event("next-lost $NextName")
        }
    }
    $countdown = {
        $now = $X.Now()
        if ($NextName) {
            $n = [long][Math]::Floor(($GiveUpMsX - $NextGuardMs - $now) / 1000)
            if ($n -gt 0) { $X.Ui.Line("($n s left to keep RUN $($NextName.Substring(1,1)) possible)") }
            elseif (-not $st.Lost) { & $tick }
        } else {
            $X.Ui.Line("($([long][Math]::Max(0, [Math]::Floor(($cutoff - $now) / 1000))) s left)")
        }
    }
    $begin = {
        param([string]$item)
        $now = $X.Now()
        $X.Poll()
        $dr = @($X.Keys.Drain($now))
        if ($dr.Count) { $X.Event("keys-discarded before $Ph/$item n=$($dr.Count) keys=$($dr -join ',')") }
        if ($st.First) {
            $st.First = $false; $res.FirstPromptMs = $now
            if ($Mode -ceq 'darkonly') { $X.Ui.Banner('answer', "RUN $runN ENDED - ONE SAFETY QUESTION", 'after your x: are both panels dark now?') }
            else { $X.Ui.Banner('answer', "RUN $runN ENDED - ANSWER NOW", 'what you saw, one eye at a time; the panels are off') }
            $X.Sound.Play('ANSWER', $now)
        }
        $X.Keys.Arm('p', $now)
        [pscustomobject]@{ Ms = $now; Discarded = $dr.Count }
    }
    $deadlineFor = { param([long]$from) [Math]::Min($from + [long]$PromptTimeoutSec * 1000, $cutoff) }
    $rest = {
        param([string[]]$items)
        foreach ($it in $items) { if (-not $res.Items.ContainsKey($it)) { $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Obs 'NOT_ASKED' -PromptMs $X.Now() } }
    }
    $safe = { param([string]$kind, [string]$why) $res.Safe = $kind; $res.SafeWhy = $why }
    $Eyes = @('left', 'right')
    $echoEye = { param([string]$eye) $eye.ToUpperInvariant() + ' EYE' }

    if ($Mode -ceq 'darkonly') {
        foreach ($e in $Eyes) { $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Obs 'ABORT' -PromptMs $X.Now() }
    } else {
        foreach ($e in $Eyes) {
            if ($null -ne $res.Safe -or $X.Stray) { break }
            $b = & $begin $e
            $dl = & $deadlineFor $b.Ms
            $answered = $false
            while (-not $answered) {
                & $countdown
                if ($Ph -ceq 'r3') {
                    $X.Ui.Line("RUN 3, $(& $echoEye $e):   r = all red   p = partly red   u = one other colour   s = same as run 2   g = a different garble   b = dark   x = abort")
                    $allowed = @('r', 'p', 'u', 's', 'g', 'b', 'x')
                } else {
                    $X.Ui.Line("RUN $runN, $(& $echoEye $e):   d = I can read the 8 characters   c = garbled   a = light, no pattern   b = dark   x = abort")
                    $allowed = @('a', 'b', 'c', 'd', 'x')
                }
                $w = Wait-Fs3cKey -X $X -Allowed $allowed -DeadlineMs $dl -OnTick $tick -Label "$Ph/$e" -RepeatKey $st.LastKey -RepeatUntilMs (& $ru)
                & $acc $w
                if ($w.TimedOut) {
                    $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Obs 'TIMEOUT' -PromptMs $b.Ms -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e): TIMEOUT"); & $safe 'timeout' "$e reading timed out"; break
                }
                if ($w.Key -ceq 'x') { $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key 'x' -Obs 'ABORT' -PromptMs $b.Ms -AnswerMs $w.Ms -Discarded $b.Discarded
                                        $X.Ui.Line("$(& $echoEye $e): ABORT"); & $safe 'abort' "x at the $e reading"; break }
                if ($Ph -ceq 'r3') {
                    $m = $script:Fs3cReadKeys3[$w.Key]
                    $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key $w.Key -Obs $m[0] -PromptMs $b.Ms -AnswerMs $w.Ms -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e): $($m[1])"); $answered = $true; continue
                }
                if ($w.Key -cne 'd') {
                    $m = $script:Fs3cReadKeys12[$w.Key]
                    $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key $w.Key -Obs $m[0] -PromptMs $b.Ms -AnswerMs $w.Ms -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e): $($m[1])"); $answered = $true; continue
                }
                $cs = $X.Now(); $cdl = & $deadlineFor $cs
                $buf = ''
                $X.Ui.Line("$(& $echoEye $e): type the 8 characters (0-9, A-F; ? = unreadable), then Enter.   Backspace = fix   Esc = back   x = abort")
                $back = $false; $cend = $null; $firstCh = $true
                while ($true) {
                    $ck = Wait-Fs3cKey -X $X -Allowed ($script:Fs3cHexKeys + @('Enter', 'Backspace', 'Esc', 'x')) -DeadlineMs $cdl -OnTick $tick -Label "$Ph/chars_$e" `
                        -RepeatKey $(if ($firstCh) { $st.LastKey } else { '' }) -RepeatUntilMs (& $ru)
                    $firstCh = $false; & $acc $ck
                    if ($ck.TimedOut) { $cend = @('-', 'TIMEOUT', $ck.Ms); break }
                    switch -CaseSensitive ($ck.Key) {
                        'Esc'       { $back = $true }
                        'x'         { $cend = @('x', 'ABORT', $ck.Ms) }
                        'Backspace' { if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1) }; $X.Ui.Line("  characters: $buf") }
                        'Enter'     { if ($buf -cmatch '^[0-9A-F?]{8}\z') { $cend = @('ok', 'READ', $ck.Ms) } else { $X.Ui.Line("  $($buf.Length) of 8 characters: keep typing (Enter needs all 8)"); $X.Event("chars-early-enter $Ph/$e len=$($buf.Length)") } }
                        default     { if ($buf.Length -lt 8) { $buf += $ck.Key.ToUpperInvariant(); $X.Ui.Line("  characters: $buf") } else { $X.Event("chars-ninth-ignored $Ph/$e key=$($ck.Key)") } }
                    }
                    if ($back -or $null -ne $cend) { break }
                }
                if ($back) {
                    $X.Ui.Line("$(& $echoEye $e): characters discarded; back to the d/c/a/b choice"); $X.Event("chars-esc $Ph/$e")
                    if ($X.Now() -ge $dl) {
                        $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Obs 'TIMEOUT' -PromptMs $b.Ms -Discarded $b.Discarded
                        $X.Ui.Line("$(& $echoEye $e): TIMEOUT"); & $safe 'timeout' "$e reading timed out (after Esc)"; break
                    }
                    continue
                }
                if ($cend[0] -ceq 'ok') {
                    $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key 'd' -Obs 'READ' -Chars $buf -PromptMs $b.Ms -AnswerMs $cend[2] -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e): READ $buf"); $answered = $true; continue
                }
                $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key 'd' -Obs 'READ' -PromptMs $b.Ms -AnswerMs $cs -Discarded $b.Discarded
                $X.Ui.Line("$(& $echoEye $e): READ, characters not recorded")
                $ci = "chars_$e"
                $res.Items[$ci] = Add-Fs3cReading -X $X -Ph $Ph -Item $ci -Key $cend[0] -Obs $cend[1] -PromptMs $cs -AnswerMs $(if ($cend[0] -ceq '-') { -1 } else { $cend[2] })
                switch ($cend[1]) {
                    'TIMEOUT'   { $X.Ui.Line("$(& $echoEye $e) CHARACTERS: TIMEOUT"); & $safe 'timeout' "$e characters timed out" }
                    'ABORT'     { $X.Ui.Line("$(& $echoEye $e) CHARACTERS: ABORT"); & $safe 'abort' "x during the $e characters" }
                }
                break
            }
        }
    }
    # ---- dark check
    if ($null -eq $res.Safe -and -not $X.Stray) {
        $wasFirst = $st.First
        $b = & $begin 'dark'
        $dl = & $deadlineFor $b.Ms
        if (-not $wasFirst) { $X.Ui.Banner('info', 'DARK CHECK - ARE BOTH PANELS DARK NOW?', 'y = dark | n = light still visible | x = abort') }
        & $countdown
        $X.Ui.Line('DARK CHECK, both eyes now:   y = dark   n = light still visible   x = abort')
        $w = Wait-Fs3cKey -X $X -Allowed @('y', 'n', 'x') -DeadlineMs $dl -OnTick $tick -Label "$Ph/dark" -RepeatKey $st.LastKey -RepeatUntilMs (& $ru)
        & $acc $w
        if ($w.TimedOut) { $res.Items['dark'] = Add-Fs3cReading -X $X -Ph $Ph -Item 'dark' -Obs 'TIMEOUT' -PromptMs $b.Ms -Discarded $b.Discarded; $X.Ui.Line('DARK CHECK: TIMEOUT'); & $safe 'timeout' 'dark check timed out' }
        else {
            $map = @{ y = @('DARK_NOW', 'DARK'); n = @('LIGHT_NOW', 'LIGHT VISIBLE'); x = @('ABORT', 'ABORT') }
            $res.Items['dark'] = Add-Fs3cReading -X $X -Ph $Ph -Item 'dark' -Key $w.Key -Obs $map[$w.Key][0] -PromptMs $b.Ms -AnswerMs $w.Ms -Discarded $b.Discarded
            $X.Ui.Line("DARK CHECK: $($map[$w.Key][1])")
            if ($w.Key -ceq 'n') { & $safe 'light' 'dark check: light visible' }
            elseif ($w.Key -ceq 'x') { & $safe 'abort' 'x at the dark check' }
        }
    }
    # ---- layout items (run 2 only, per eye whose reading was c or d, left first): after d the TILT first, then the F, then
    #      the bars (review 2 MAJOR-1); after c the bars only; no bars on the run-3 path (Q7). A timeout at one item is
    #      recorded and the next item is asked; x ends the session safely.
    if ($Layout -and $Mode -ceq 'full' -and $null -eq $res.Safe -and -not $X.Stray) {
        $q7 = ($null -ne $BarsQ7 -and [bool](& $BarsQ7 $res.Items))
        foreach ($e in $Eyes) {
            $rd = $res.Items[$e]
            if ($null -eq $rd -or ($rd.Key -cne 'c' -and $rd.Key -cne 'd')) { continue }
            $items = @(); if ($rd.Key -ceq 'd') { $items += "tilt_$e"; $items += "orient_$e" }; $items += "bars_$e"
            foreach ($it in $items) {
                if ($null -ne $res.Safe -or $X.Stray) { break }
                if ($q7 -and $it -like 'bars_*') {
                    $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Obs 'NOT_ASKED' -PromptMs $X.Now()
                    $res.BarsQ7 += $it
                    $X.Event("bars-not-asked $Ph/$it (Q7 fallback: run-3 path)"); continue
                }
                if (($cutoff - $X.Now()) -lt [long]$LayoutMinSec * 1000) {
                    $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Obs 'NOT_ASKED' -PromptMs $X.Now()
                    $X.Event("layout-not-asked $Ph/$it (< $LayoutMinSec s to the cut-off)"); continue
                }
                $b = & $begin $it
                $dl = & $deadlineFor $b.Ms
                & $countdown
                if ($it -like 'bars_*') {
                    $X.Ui.Line("$(& $echoEye $e), BARS: how many bars next to the LEFT F, then next to the RIGHT F?   two keys 0-4 (0 = none)   Backspace = fix   x = abort")
                    $buf = ''; $fin = $null; $firstB = $true
                    while ($null -eq $fin) {
                        $k = Wait-Fs3cKey -X $X -Allowed @('0', '1', '2', '3', '4', 'Backspace', 'x') -DeadlineMs $dl -OnTick $tick -Label "$Ph/$it" `
                            -RepeatKey $(if ($firstB) { $st.LastKey } else { '' }) -RepeatUntilMs (& $ru)
                        $firstB = $false; & $acc $k
                        if ($k.TimedOut) { $fin = @('-', 'TIMEOUT', -1); break }
                        if ($k.Key -ceq 'x') { $fin = @('x', 'ABORT', $k.Ms); break }
                        if ($k.Key -ceq 'Backspace') { if ($buf.Length) { $buf = $buf.Substring(0, $buf.Length - 1) }; $X.Ui.Line("  bars: $buf"); continue }
                        $buf += $k.Key; $X.Ui.Line("  bars: $buf")
                        if ($buf -cmatch '^[0-4]{2}\z') { $fin = @('-', 'BARS', $k.Ms) }
                    }
                    if ($fin[1] -ceq 'BARS') {
                        $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Obs 'BARS' -Bars $buf -PromptMs $b.Ms -AnswerMs $fin[2] -Discarded $b.Discarded
                        $X.Ui.Line("$(& $echoEye $e) BARS: $($buf.Substring(0,1)) | $($buf.Substring(1,1))")
                    } else {
                        $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Key $fin[0] -Obs $fin[1] -PromptMs $b.Ms -AnswerMs $fin[2] -Discarded $b.Discarded
                        $X.Ui.Line("$(& $echoEye $e) BARS: $($fin[1] -replace '_', ' ')")
                    }
                } else {
                    if ($it -like 'orient_*') { $map = $script:Fs3dOrientKeys
                        $X.Ui.Line("$(& $echoEye $e), the letter F:   u = upright   i = upside down   m = mirrored   v = flipped top-bottom   ? = can't tell   x = abort") }
                    else { $map = $script:Fs3dTiltKeys
                        $X.Ui.Line("$(& $echoEye $e), is the text level?   0 = level   r = turned clockwise (right end lower)   l = turned counter-clockwise (left end lower)   ? = can't tell   x = abort") }
                    $k = Wait-Fs3cKey -X $X -Allowed (@($map.Keys) + @('x')) -DeadlineMs $dl -OnTick $tick -Label "$Ph/$it" -RepeatKey $st.LastKey -RepeatUntilMs (& $ru)
                    & $acc $k
                    if ($k.TimedOut) { $fin = @('-', 'TIMEOUT', -1, 'TIMEOUT') }
                    elseif ($k.Key -ceq 'x') { $fin = @('x', 'ABORT', $k.Ms, 'ABORT') }
                    else { $fin = @($k.Key, $map[$k.Key][0], $k.Ms, $map[$k.Key][1]) }
                    $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Key $fin[0] -Obs $fin[1] -PromptMs $b.Ms -AnswerMs $fin[2] -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e) $(if ($it -like 'orient_*') { 'F' } else { 'TILT' }): $($fin[3])")
                }
                switch ($res.Items[$it].Obs) {
                    'TIMEOUT'   {
                        $res.LayoutTimeouts += $it
                        # review 3 MAJOR-A (safety): on the run-3 path an unanswered console must not be followed by a lit run 3:
                        # the session ends safely there (as stage 3c); on the read path (no run 3) the next item is asked
                        if ($q7) { & $safe 'timeout' "$it timed out (run 3 could follow: the session ends safely)" }
                        else { $X.Event("layout-timeout $Ph/$it (recorded; the next item follows)") } }
                    'ABORT'     { & $safe 'abort' "x at $it" }
                }
            }
        }
    }
    if ($null -ne $res.Safe -or $X.Stray) {
        $rem = New-Object System.Collections.Generic.List[string]
        foreach ($it in 'left', 'right', 'dark') { $rem.Add($it) }
        if ($Layout -and $Mode -ceq 'full') {
            foreach ($e in $Eyes) {
                $rd = $res.Items[$e]
                if ($null -eq $rd -or ($rd.Key -cne 'c' -and $rd.Key -cne 'd')) { continue }
                if ($rd.Key -ceq 'd') { $rem.Add("tilt_$e"); $rem.Add("orient_$e") }; $rem.Add("bars_$e")
            }
        }
        & $rest $rem.ToArray()
        if ($X.Stray -and $null -eq $res.Safe) { & $safe 'stray' 'bytes arrived from the device after the settled prompt (the shell state changed)' }
    }
    $last = @($res.Items.Values | Where-Object { $_.AnswerMs -ge 0 } | ForEach-Object { $_.AnswerMs } | Sort-Object -Descending)
    if ($last.Count) { $res.LastAnswerMs = $last[0] }
    $X.Ui.Line("ANSWERS COMPLETE FOR RUN $runN")
    $X.Event("readings-complete $Ph safe=$($res.Safe)")
    [pscustomobject]$res
}
