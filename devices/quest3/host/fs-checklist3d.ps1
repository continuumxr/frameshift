<#
FrameShift - stage-3d console checklist (Windows PowerShell 5.1), for either Quest 3 unit (both on v2.7).
A COPY of fs-checklist3c.ps1 (after the single-reading review fixes: the reading as typed text with the unit's
serial, the exact age). The only differences (a reviewer diffs the two): the function and variable prefix FsCl3d; the
files checklist3d.json / checklist3d.txt (schema frameshift.fs-checklist3d.v1); the pin table SIGNOFF-3d.md; the
preflight is fs-observe3d.ps1 -Preflight ("image OK: stage 3d nonce ..."); the rehearsal is fs-collect3d.ps1's
(<cycle>\rehearsal\summary.txt: "REHEARSAL: reset plus run-2 answers ... GO (<= 40 s)", the reset question answered and
the Q7 fallback shown) AND, review 2 MAJOR-1, the TIMED rehearsal of the read path (<cycle>\rehearsal-read\summary.txt:
"REHEARSAL (read path): ... GO (every item answered, at least 10 s to spare)", 9 of 9 run-2 items); the previews are stage 3d's (rendered by fs-pattern v0.7; v0.7.1 draws the same picture, per eye); the printed texts (the keys, points
D1 to D14, presence, after) describe stage 3d in plain, short lines (PM feedback). The sound check is stage 3c's
Invoke-Fs3cSoundCheck, run by fs-collect3d.ps1 -S3dSoundCheck (J-143 review MAJOR-1: soundcheck.json schema
frameshift.fs-soundcheck3d.v1 with its made record; a fs-session3c.ps1 -SoundCheck file no longer counts): its key-reach test already covers
every key of stage 3d (y/n/x, d/c/a/b, the hex characters, 0-4, u/i/m/v, 0/r/l/?, the run-3 keys).

J-143 (PM): a STANDING phase-A acceptance, and the sound check and rehearsals carry over (stage3d/HOST.md section 9).
  - The accepted content (questions A1-A3, the preview list, the preview pictures' SHA-256, the keys, D1 to D14) is
    hashed (Get-FsCl3dAcceptBlocks). A full acceptance writes <repo>\captures\standing\phase-a.json (schema
    frameshift.fs-standing-a3d.v1: the UTC time, the cycle, the accepted blocks and their SHA-256, the text SHA-256 and
    this tool's own SHA-256 = its SIGNOFF-3d pin). Phase A of a later cycle asks nothing when that record is intact and
    its text hash equals the current text, whatever the checklist version (PM, on J-143 open question 1: a code-only
    change asks nothing): it writes a per-cycle A entry (Acceptance.Mode 'standing') naming the record, its SHA-256, the
    checklist version that relied on it (ToolPin) and the one that took it (RecordToolPin). That automatic entry, written when the cycle starts (before B), is
    the "A" of the observer's A, B, E order. A changed text or picture asks only about the changed lines (question
    R1). A record that is unreadable or
    whose stored text does not match its own hashes (edited), or that no phase-A PASS entry of its originating cycle on
    this PC gave (made up, or copied without its cycle folder), is refused: STOP. This is not proof against a deliberate
    local forgery of both files.
  - A sound check or rehearsal passes FRESH from this cycle's own files (as before; then recorded in
    <repo>\captures\standing\carryover.json), or is CARRIED OVER from the latest such record unless (a) the
    session/collector tool set changed (Get-FsCl3dToolSet: fs-session3c, fs-collect3d, everything they dot-source, and
    the two rehearsal replays), (b) it is another calendar day on this PC (local date), or (c) the PM declared new
    speakers (-NewSpeakers, recorded in <repo>\captures\standing\speakers.json; a carried pass must be newer). The A
    entry records the pass relied on (path, SHA-256, tool-set hash, date, cycle).

NO DEVICE COMMAND, NO NETWORK. Phases (devices/quest3/SIGNOFF-3d.md lists every check and the exact text printed):
  -Phase A   at the start of the cycle (before B): host-hashes.txt (the literal Get-FileHash command of SIGNOFF-3d A)
             and the working files equal the SIGNOFF-3d host-pin table (checked FIRST); fs-observe3d.ps1 -Preflight
             prints "preflight OK"; the sound check and both rehearsals (the garbled path; the timed read path), fresh or
             carried over; the previews exist. Then the standing acceptance, or the questions (all, or the changes only).
  -Phase B   the single temperature reading on THIS unit, run by the Arbiter: -R1 -R1Utc -R1Status -R1Serial (typed
             text: three digits 100-349, the PC's UTC; status 3/4/5 below 350, or status 2 (charging) only below 300
             (J-145); one of the two units; at most 900 s old, exactly).
  -Phase E   immediately before the attempt: presence and the power button, both y.
fs-observe3d.ps1 refuses the attempt unless the LAST entry of each of A, B and E passed (A for this nonce, with an
intact standing record and the carried passes unchanged), E is at most 300 s old, every entry was written by the
pinned copy of this file, B's reading passes the same rules, was taken on the attempt's -Serial, is before BA and at
most 900 s before it, BA10 passes the same temperature rule, and E began after BF.
Usage (from the repository root, in powershell.exe):
  fs-checklist3d.ps1 -Phase A -Cycle <cycle> -Image <img>\boot-stage3d.img [-NewSpeakers] [-RehearsalDir <cycle>\rehearsal] [-RehearsalReadDir <cycle>\rehearsal-read]
  fs-checklist3d.ps1 -Phase B -Cycle <cycle> -R1 <t> -R1Utc <utc> -R1Status <dumpsys status> -R1Serial <serial> [-R1Charge <%>]
  fs-checklist3d.ps1 -Phase E -Cycle <cycle>
Exit: 0 phase passed; 1 STOP; 64 usage; 70 internal error. The file is ASCII.
#>
param(
    [string]$Phase = '',
    [string]$Cycle = '',
    [string]$Image = '',
    [string]$RehearsalDir = '',
    [string]$RehearsalReadDir = '',
    [string]$R1 = '',                  # review MAJOR-1: text, never [int] (an [int] parameter rounds "36.2" to 36)
    [string]$R1Utc = '',
    [string]$R1Status = '',            # review MAJOR-1: text (an [int] parameter rounds "2.6" to 3)
    [string]$R1Charge = '',
    [string]$R1Serial = '',            # review MAJOR-2: the unit the reading was taken on
    [switch]$NewSpeakers,              # J-143 (c): the PM declares a new speaker setup (no earlier pass carries over)
    [int]$TimeoutSec = 0
)
Set-StrictMode -Version 2.0
$script:FsCl3dInvocation = $MyInvocation.InvocationName
$script:FsCl3dSelf = Join-Path $PSScriptRoot 'fs-checklist3d.ps1'
$script:FsCl3dSchema = 'frameshift.fs-checklist3d.v1'      # the stage-3d checklist (the stage-3c v3 rules: one Reading as typed text with the unit's serial)
$script:FsCl3dPresenceMaxSec = 300      # enforced by fs-observe3d.ps1 (Test-FsObsChecklist)
$script:FsCl3dTimeoutA = 900            # per question in phase A (reading D1-D14 takes time)
$script:FsCl3dTimeoutE = 300            # per question in phase E
# The reading's time is the PC's UTC at the moment of the reading (WALKTHROUGH step 6 prints it with the
# dumpsys output), so it should never be ahead of this clock; the 60 s slack only absorbs a typing or
# copying delay. Anything later is a typing error or a reading not yet taken. fs-observe3d.ps1
# additionally requires it to be before BA started.
$script:FsCl3dFutureSlackSec = 60
# Single temperature reading (PM, J-125; J-145): below 350 (35.0 deg C) with the battery status 3, 4 or 5, or below 300
# (30.0 deg C) while charging (status 2); at most 900 s before BA (fs-observe3d.ps1 enforces the BA tie; phase B already refuses a reading older than that now).
$script:FsCl3dTempLimit = 350
$script:FsCl3dTempMin = 100            # review MAJOR-1: three digits, 100..349 (10.0 to 34.9 deg C); below 100 is a typing error
$script:FsCl3dReadingMaxAgeSec = 900
# review MAJOR-2: the reading is tied to a unit. The two Quest 3 units (both on v2.7, J-131/J-133).
$script:FsCl3dUnits = [ordered]@{ 'QUEST3UNIT1' = 'Unit 1'; 'QUEST3UNIT2' = 'Unit 2' }
# dumpsys battery status codes (android.os.BatteryManager BATTERY_STATUS_*); 3, 4 and 5 count as not charging (below 350);
# 2 (charging) counts only below 300 (J-145, FsCl3dChargingLimit); 1 never
$script:FsCl3dStatusName = @{ 1 = 'unknown'; 2 = 'charging'; 3 = 'discharging'; 4 = 'not charging'; 5 = 'full' }
$script:FsCl3dStatusOk = @('3', '4', '5')     # compared as text: exactly one of these digits (review MAJOR-1)
# J-145 (PM): a reading taken while charging (status 2) is accepted only below 300 (30.0 deg C); otherwise unchanged
$script:FsCl3dChargingLimit = 300
$script:FsCl3dWrap = 90
# J-143: the standing records live in <repo>\captures\standing (gitignored, per PM, durable across cycles)
$script:FsCl3dStandingSchema = 'frameshift.fs-standing-a3d.v1'
$script:FsCl3dLedgerSchema = 'frameshift.fs-carryover3d.v1'
$script:FsCl3dSpeakersSchema = 'frameshift.fs-speakers3d.v1'
# J-143 (a): the session/collector tool set and the made record of a sound check or rehearsal: fs-carry3d.ps1, shared
# with fs-collect3d.ps1 (which writes the records). It has no param block (nothing binds in this scope).
. (Join-Path $PSScriptRoot 'fs-carry3d.ps1')
$script:FsCl3dToolSetFiles = $script:FsCarry3dToolSetFiles

# ------------------------------------------------------------ the texts -----
# Printed by the console and recorded verbatim; SIGNOFF-3d.md carries the same lines (test-host3d CL13).
$script:FsCl3dQ = [ordered]@{
    A1 = 'Have you opened and looked at the three preview pictures listed above? (y/n)'
    A2 = 'Do you know which key to press for each thing you might see (list above)? (y/n)'
    A3 = 'I have read points D1 to D14 above and I accept them (y/n)'
    R1 = 'I have read the changes listed above (and opened any changed picture), and I accept them together with the rest of my earlier acceptance (y/n)'
    E1 = 'Are you physically at the headset now? (y/n)'
    E2 = 'Can you reach the headset''s power button now, and do you know when to use it (RECOVERY.md)? (y/n)'
}
$script:FsCl3dPreviewDir = 'devices\quest3\stage3d\fixtures\preview'
# the three pictures, in the order printed, each with what it shows (stage 3d: rendered by fs-pattern v0.7, the same picture as v0.7.1). Delta review MINOR-2: the
# as-seen, panels and mixer-map pictures show the expected bars and the level picture, so they are not shown before the
# session (WALKTHROUGH step 17 opens them after the PM's description is recorded)
$script:FsCl3dPreviews = [ordered]@{
    'pattern-v0.7-3f9c07ab-digits-left.png'       = 'The 8 characters to read.'
    'F-reference-u-i-m-v.png'                     = 'How an F can look: upright u, upside down i, mirrored m, flipped top to bottom v.'
    'solid-red-v0.7-viewer-1032x552.png'          = 'The plain red field of run 3.'
}
$script:FsCl3dPreviewFiles = @($script:FsCl3dPreviews.Keys)
$script:FsCl3dText = [ordered]@{
    PreviewsHead = 'Open each of these three pictures (paste the path into File Explorer) and look at it:'
    PreviewsTail = 'In each eye, note whether the text is level or turned, and which way. The pictures of the expected view are shown only after the session.'
    KeyLines = @(
        'After the display reset, one question: y = yes, I saw something; b = no, it stayed dark (b means dark, as in run 2); x = abort. n is not an answer there (nothing happens). The answer is recorded only; run 2 follows either way.',
        'Run 2, each eye: d = I can read the 8 characters (then type them; Backspace fixes; Enter needs all 8; Esc goes back), c = garbled, a = light but no pattern, b = dark, x = abort.',
        'Dark check (both eyes): y = dark, n = light still visible (the session then ends safely), x = abort.',
        'If asked, each eye in this order: the tilt (0 level, r turned clockwise, l turned counter-clockwise, ? can''t tell); the letter F (u upright, i upside down, m mirrored, v flipped top-bottom, ? can''t tell); the bars next to the LEFT F, then the RIGHT F (two keys 0-4, 0 = none). No bar question if run 3 follows.',
        'Run 3 (only if run 2 was garbled or light without a pattern): r = all red, p = partly red, u = one other colour, s = same as run 2, g = a different garble, b = dark.',
        'x aborts at any time. n aborts too while phase 0, the LOOK cue, run 2 or run 3 is running (it means light). At the reset question and at the eye, tilt, F and bar questions n does nothing.',
        '30 s per question. A timeout at the reset question, an eye question or the dark check ends the session safely; a timeout at a tilt, F or bar question skips only that question (but ends the session safely when run 3 could follow). Ctrl+C is the same as x. Tap keys, do not hold them; wait for each answer to be echoed. Do not click into the console window.')
    Accept = @(
        'D1. First the headset sets the screen brightness once, to level 127 (about 4 % of full backlight, from the driver code; nobody has measured the light). It is read back before each run.',
        'D2. Then the display reset: the screen is switched off, on again showing only black, and off. Nothing should be visible. One question follows: did I see anything? My answer is recorded and does not stop the test.',
        'D3. Then run 2 shows the test pattern for 10 s. It is drawn per eye: each eye gets its own half, turned against the panel''s 21-degree tilt. I describe what I actually see; there is no expected answer to aim for. If the driver refuses it, nothing lights.',
        'D4. Run 3 shows a plain red field for 5 s, only if I report run 2 as garbled or as light without a pattern. At most 15 s of light in total.',
        'D5. On this firmware (v2.7) the backlight may stay dim or dark in run 2 (a known open point). I report what I saw; a follow-up build may follow.',
        'D6. The headset itself times each lit period. Pressing x cannot shorten a period that is already running; it ends the session after it. I may look away at any time.',
        'D7. If the screen does not go dark when a run ends, the picture may stay until the end command (fs-done), the idle limit (120 s) or the deadline (about 200 s after the test program starts, with a last safety stop 1 s later). These are not guaranteed screen-off times; switching off by hand (RECOVERY.md) always remains.',
        'D8. Questions appear only after a run has ended and its report has arrived. I answer from what I saw. The console shows none of the headset''s own results until my answers are in. The swap and tilt labels help explain the result; they are not a pass.',
        'D9. If a report does not arrive, or a red NO RECORD / SHELL STATE UNKNOWN / NO fs-done banner appears with the ALARM sound, nothing more is sent: I look away and wait; the headset recovers by itself.',
        'D10. Console window closed, or the collector stopped: I look away; the headset recovers by itself within 120 s (the idle limit) or at the deadline. My answers so far are already saved (readings3d.txt).',
        'D11. If the console shows NOTHING RUNS (integrity): the pattern program on the headset is not the reviewed one; nothing is shown, and fs-done follows.',
        'D12. No number is claimed for eye safety; "no light seen" does not mean that no light was emitted.',
        'D13. Time limit: the test boot is refused if more than 300 s have passed since BA started. Then nothing starts, the one-time code (nonce) stays unused, and I go back to Android for a new temperature reading and a new BA/BF.',
        'D14. On v2.7 the before/after checks show the build and slot only; partition contents are not compared (not captured on a user build; <withheld document>).')
    Presence = @(
        'I am present, headset in hand, power button reachable, keyboard under one hand; the collector runs in powershell.exe (a console window, not ISE) with sound on, on the PC speakers and at the volume of the sound check.',
        'If anything is unexpected: x (at the dark check, n), look away and wait; the headset recovers by itself (fs-done, the idle limit of 120 s, or the deadline about 200 s after the test program starts). Switch off by hand (power button) only as RECOVERY.md says.',
        'Next: paste the attempt command at once. fs-observe3d.ps1 refuses the attempt if this presence check is more than 300 s old, or if more than 300 s have passed since BA started.')
    After = @(
        'After the session: AF immediately on return to fastboot (<withheld capture tool> -Phase AF), then fastboot -s <serial> reboot, then AA promptly in Android.',
        'AA10 temperature at 400 (40.0 deg C) or more: shut down at once (procedure as 3b F), do not wait for anything else. Even below 400, follow-up readings at +5 min and +10 min, then every 5 min while it rises and stays below 400; the highest observed reading is recorded. Shutdown and unplug are recorded as two separate observations.')
}

# ------------------------------------------------------------ helpers -------
function Get-FsCl3dSha([string]$Path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { $null } }
# SHA-256 of lines joined with LF, UTF-8 (the record of a printed block)
function Get-FsCl3dTextSha([string[]]$Lines) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}
# the second single-reading review (MINOR-1), as fs-checklist3c.ps1: ASCII digits, the exact format, ParseExact in a try
$script:FsCl3dUtcFormats = [string[]](@("yyyy-MM-dd'T'HH:mm:ss'Z'") + @(1..7 | ForEach-Object { "yyyy-MM-dd'T'HH:mm:ss." + ('f' * $_) + "'Z'" }))
function ConvertFrom-FsCl3dUtc([string]$s) {
    if ($null -eq $s -or $s -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z\z') { return $null }
    try { [DateTime]::ParseExact($s, $script:FsCl3dUtcFormats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }
    catch { $null }
}
function Format-FsCl3dUtc([DateTime]$t) { $t.ToUniversalTime().ToString('o') }
# Wraps one console line at $Width characters, at spaces; a word longer than the width (a path) stays whole.
# Continuation lines are indented under the text after a list marker ("D1. ", "1. ", "- ") or by two spaces.
function Format-FsCl3dWrap([string]$Line, [int]$Width = 90) {
    if ($null -eq $Line -or $Line.Length -le $Width) { return ,@([string]$Line) }
    $ind = [regex]::Match($Line, '^ *').Value
    $mk = [regex]::Match($Line, '^ *(D\d+\. |\d+\. |- |QUESTION: )')
    $cont = if ($mk.Success) { ' ' * $mk.Length } else { $ind + '  ' }
    $out = New-Object System.Collections.Generic.List[string]; $cur = $ind; $empty = $true
    foreach ($w in ($Line.Substring($ind.Length) -split ' ')) {
        if ($empty) { $cur += $w; $empty = $false; continue }
        # a word that would not fit on a continuation line either (a long path) stays on the current line
        if (($cur.Length + 1 + $w.Length) -le $Width -or ($cont.Length + $w.Length) -gt $Width) { $cur += ' ' + $w } else { $out.Add($cur); $cur = $cont + $w }
    }
    $out.Add($cur)
    ,$out.ToArray()
}
function Format-FsCl3dPrompt([int]$TimeoutSec) {
    $d = if ($TimeoutSec -ge 60 -and $TimeoutSec % 60 -eq 0) { $m = $TimeoutSec / 60; "$m minute$(if ($m -ne 1) { 's' })" } else { "$TimeoutSec second$(if ($TimeoutSec -ne 1) { 's' })" }
    "Press y for yes or n for no ($d)."
}
# The preview block: the head line, each picture's absolute path and what it shows, the tail line.
function Get-FsCl3dPreviewLines([string]$Root) {
    $l = @($script:FsCl3dText.PreviewsHead); $i = 0
    foreach ($f in $script:FsCl3dPreviews.Keys) { $i++; $l += "$i. $($Root.TrimEnd('\'))\$($script:FsCl3dPreviewDir)\$f"; $l += "   $($script:FsCl3dPreviews[$f])" }
    $l + @($script:FsCl3dText.PreviewsTail)
}

# The SIGNOFF-3d host-pin table: rows between "<!-- host pins" and "<!-- end host pins -->".
function Read-FsCl3dPinTable([string]$SignoffFile) {
    if (-not (Test-Path -LiteralPath $SignoffFile -PathType Leaf)) { return $null }
    $rows = New-Object System.Collections.Generic.List[object]; $in = $false
    foreach ($l in [IO.File]::ReadAllLines($SignoffFile)) {
        if ($l -match '<!-- end host pins') { break }
        if ($l -match '<!-- host pins') { $in = $true; continue }
        if ($in -and $l -cmatch '^\s*\|\s*`([^`]+)`\s*\|\s*`([0-9a-f]{64})`\s*\|') { $rows.Add([pscustomobject]@{ Rel = $Matches[1]; Sha = $Matches[2] }) }
    }
    ,$rows.ToArray()
}
# host-hashes.txt (Format-Table Hash, Path | Out-String -Width 400 | Tee-Object; UTF-16 from Tee-Object in
# PS 5.1, read with BOM detection) against the pin table, and every working file against its pin.
function Test-FsCl3dHostPins {
    param([string]$HashesFile, [string]$SignoffFile, [string]$Root)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w } }
    $rows = Read-FsCl3dPinTable $SignoffFile
    if ($null -eq $rows -or $rows.Count -eq 0) { return (& $no "no host-pin table in $SignoffFile") }
    if (-not (Test-Path -LiteralPath $HashesFile -PathType Leaf)) { return (& $no "missing: $HashesFile (run the Get-FileHash command of SIGNOFF-3d A first)") }
    $seen = @{}
    foreach ($l in ([IO.File]::ReadAllText($HashesFile) -split "`r?`n")) {
        if ($l -match '^\s*([0-9A-Fa-f]{64})\s+(\S.*?)\s*$') { $seen[[IO.Path]::GetFullPath($Matches[2]).ToLowerInvariant()] = $Matches[1].ToLowerInvariant() }
    }
    $bad = @()
    foreach ($r in $rows) {
        $full = [IO.Path]::GetFullPath((Join-Path $Root $r.Rel))
        $k = $full.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $bad += "$($r.Rel): not in host-hashes.txt (expected path $full)"; continue }
        if ($seen[$k] -cne $r.Sha) { $bad += "$($r.Rel): host-hashes.txt $($seen[$k]) != pin $($r.Sha)" }
        $now = Get-FsCl3dSha $full
        if ($now -cne $r.Sha) { $bad += "$($r.Rel): working file $now != pin $($r.Sha)" }
    }
    if ($bad.Count) { return (& $no ("host pins differ (run the Get-FileHash command of WALKTHROUGH step 1 again if the files changed): " + ($bad -join '; '))) }
    [pscustomobject]@{ Ok = $true; Why = "$($rows.Count) files: host-hashes.txt and the working files equal the SIGNOFF-3d pins" }
}
function Test-FsCl3dSoundCheck([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Why = "missing: $Path (run fs-collect3d.ps1 -S3dSoundCheck -S3dOutDir <cycle>)" } }
    try { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Why = "unreadable: $Path" } }
    $sch = if ($j.PSObject.Properties['Schema']) { [string]$j.Schema } else { '' }
    $pass = ($j.PSObject.Properties['Pass'] -and $j.Pass -is [bool] -and $j.Pass)
    # J-143 review MAJOR-1: the stage-3d sound check (fs-collect3d.ps1 -S3dSoundCheck) records when and with which tools
    if ($sch -cne $script:FsCarry3dSoundSchema -or -not $pass) { return [pscustomobject]@{ Ok = $false; Why = "soundcheck.json is not a passed stage-3d sound check (Schema '$sch', Pass $(if ($j.PSObject.Properties['Pass']) { $j.Pass } else { '-' }); fs-collect3d.ps1 -S3dSoundCheck writes $($script:FsCarry3dSoundSchema))" } }
    $end = if ($j.PSObject.Properties['EndUtc']) { [string]$j.EndUtc } else { '?' }
    [pscustomobject]@{ Ok = $true; Why = "SOUND CHECK PASSED (soundcheck.json Pass true, ended $end)" }
}
# Review 2 MAJOR-1: the TIMED rehearsal of the read path (<cycle>\rehearsal-read, the nominal-read replay): its summary
# must hold the read-path GO line (every item answered, at least 10 s to spare before the run-2 cut-off) and show the
# reset answer.
function Test-FsCl3dRehearsalRead([string]$Dir) {
    $p = Join-Path $Dir 'summary.txt'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Why = "missing: $p (the TIMED rehearsal of the read path, SIGNOFF-3d A: replay nominal-read, answered with the 8 characters, the tilt, the F and the bars in each eye, then s)" } }
    $t = [IO.File]::ReadAllText($p)
    $go = [regex]::Match($t, '(?m)^REHEARSAL \(read path\): the last answer [0-9]+\.[0-9] s before the cut-off \((run-2 end \+ [0-9]+ s|give-up - [0-9]+ s)\); go/no-go \(SIGNOFF-3d A\): GO \(every item answered, at least 10 s to spare\)\r?$')
    if (-not $go.Success) { return [pscustomobject]@{ Ok = $false; Why = "no read-path GO line in $p (every item answered with at least 10 s to spare): repeat the timed rehearsal or report" } }
    if ($t -notmatch '(?m)^REHEARSAL \(read path\): run-2 answers took [0-9]+\.[0-9] s from the first prompt; 9 of 9 items answered\r?$' -or $t -notmatch '(?m)^PHASE r1: FSB1 VALID; .*reset seen: (SEEN|NOT_SEEN)') { return [pscustomobject]@{ Ok = $false; Why = "$p does not show 9 of 9 run-2 items and the reset answer: not a stage-3d rehearsal of the read path with the pinned files" } }
    $tl = @([regex]::Matches($t, '(?m)^REHEARSAL \(read path\): (left|right) eye: .*$') | ForEach-Object { $_.Value.TrimEnd("`r") })
    [pscustomobject]@{ Ok = $true; Why = ($go.Value.TrimEnd("`r") + $(if ($tl.Count) { ' | ' + ($tl -join ' | ') } else { '' })) }
}
function Test-FsCl3dRehearsal([string]$Dir) {
    $p = Join-Path $Dir 'summary.txt'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Why = "missing: $p (the rehearsal of SIGNOFF-3d A, answered on the garbled path, then s)" } }
    $t = [IO.File]::ReadAllText($p)
    $go = [regex]::Match($t, '(?m)^REHEARSAL: reset plus run-2 answers [0-9]+\.[0-9] s; go/no-go \(SIGNOFF-3d A\): GO \(<= 40 s\)\r?$')
    if (-not $go.Success) { return [pscustomobject]@{ Ok = $false; Why = "no GO line in $p (go/no-go must be GO (<= 40 s))" } }
    if ($t -notmatch 'not asked \(Q7 fallback\)' -or $t -notmatch '(?m)^PHASE r1: FSB1 VALID; .*reset seen: (SEEN|NOT_SEEN)') { return [pscustomobject]@{ Ok = $false; Why = "$p does not show the reset question and the Q7 fallback (bars not asked on the run-3 path): not a stage-3d rehearsal of the garbled path with the pinned files" } }
    [pscustomobject]@{ Ok = $true; Why = $go.Value.TrimEnd("`r") }
}
function Test-FsCl3dPreviews([string]$Root) {
    $miss = @($script:FsCl3dPreviewFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path $Root $script:FsCl3dPreviewDir) $_) -PathType Leaf) })
    if ($miss.Count) { return [pscustomobject]@{ Ok = $false; Why = "preview files missing: $($miss -join ', ')" } }
    [pscustomobject]@{ Ok = $true; Why = "$($script:FsCl3dPreviewFiles.Count) preview files present in $($script:FsCl3dPreviewDir)" }
}
# ------------------------------------------------- J-143: the standing acceptance and the carry-over -----
# The accepted content as blocks (title + lines): the three questions, the preview list (paths with the placeholder
# <repository>, so the text does not depend on where the repository is), the pictures' SHA-256, the keys, D1 to D14.
function Get-FsCl3dAcceptBlocks([string]$Root) {
    $pics = @(foreach ($f in $script:FsCl3dPreviewFiles) { $h = Get-FsCl3dSha (Join-Path (Join-Path $Root $script:FsCl3dPreviewDir) $f); "$f  $(if ($h) { $h } else { 'missing' })" })
    @([ordered]@{ Title = 'THE QUESTIONS OF PHASE A'; Lines = @($script:FsCl3dQ.A1, $script:FsCl3dQ.A2, $script:FsCl3dQ.A3) },
      [ordered]@{ Title = 'THE THREE PREVIEW PICTURES'; Lines = @(Get-FsCl3dPreviewLines '<repository>') },
      [ordered]@{ Title = 'THE PREVIEW PICTURES (SHA-256)'; Lines = $pics },
      [ordered]@{ Title = 'THE KEYS (what to press for what you see)'; Lines = @($script:FsCl3dText.KeyLines) },
      [ordered]@{ Title = 'WHAT I ACCEPT (points D1 to D14)'; Lines = @($script:FsCl3dText.Accept) })
}
# SHA-256 of one block ("== <title>" then its lines) and of the whole text (every block in order), LF, UTF-8
function Get-FsCl3dBlockSha($B) { Get-FsCl3dTextSha ([string[]](@("== $([string]$B.Title)") + @($B.Lines | ForEach-Object { [string]$_ }))) }
function Get-FsCl3dBlocksSha([object[]]$Blocks) {
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($b in $Blocks) { $all.Add("== $([string]$b.Title)"); foreach ($l in @($b.Lines)) { $all.Add([string]$l) } }
    Get-FsCl3dTextSha $all.ToArray()
}
function Get-FsCl3dStandingDir([hashtable]$Opt) { if ($Opt.ContainsKey('StandingDir') -and $Opt.StandingDir) { [string]$Opt.StandingDir } else { Join-Path ([string]$Opt.Root) 'captures\standing' } }
# The PC's calendar day (local date) of a UTC time; $Opt.LocalDate overrides (fixtures)
function Get-FsCl3dLocalDateFn([hashtable]$Opt) { if ($Opt.ContainsKey('LocalDate') -and $Opt.LocalDate -is [scriptblock]) { $Opt.LocalDate } else { { param([DateTime]$u) $u.ToUniversalTime().ToLocalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } } }
# phase-a.json: State none | intact | damaged (unreadable, another schema, a malformed field, or a stored block or text
# that does not match its own SHA-256: edited, or not written by the checklist; the link to the originating cycle,
# Test-FsCl3dStandingLink, is checked separately). Returns @{ State; Why; Path; Sha256; Rec; AcceptedUtc }.
function Read-FsCl3dStanding([string]$Dir) {
    $p = Join-Path $Dir 'phase-a.json'
    $r = [pscustomobject]@{ State = 'none'; Why = "no standing acceptance yet ($p)"; Path = $p; Sha256 = $null; Rec = $null; AcceptedUtc = $null }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $r }
    $r.Sha256 = Get-FsCl3dSha $p
    $bad = { param($w) $r.State = 'damaged'; $r.Why = "the standing acceptance $p is refused: $w"; $r }
    try { $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { return (& $bad 'unreadable') }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    if ([string](& $pv $j 'Schema') -cne $script:FsCl3dStandingSchema) { return (& $bad "not a $($script:FsCl3dStandingSchema) record") }
    $ts = [string](& $pv $j 'TextSha256'); $tp = [string](& $pv $j 'ToolPin'); $au = ConvertFrom-FsCl3dUtc ([string](& $pv $j 'AcceptedUtc'))
    if ($ts -cnotmatch '^[0-9a-f]{64}\z' -or $tp -cnotmatch '^[0-9a-f]{64}\z' -or $null -eq $au) { return (& $bad 'its text SHA-256, tool pin or acceptance time is missing or malformed') }
    $blocks = @(& $pv $j 'Blocks')
    if ($blocks.Count -eq 0) { return (& $bad 'it holds no accepted text') }
    foreach ($b in $blocks) {
        $t = & $pv $b 'Title'
        if (-not ($t -is [string]) -or $null -eq (& $pv $b 'Lines')) { return (& $bad 'a block without a title or lines') }
        if ((Get-FsCl3dBlockSha $b) -cne [string](& $pv $b 'Sha256')) { return (& $bad "its stored block '$t' does not match its own SHA-256 (edited, or not written by the checklist)") }
    }
    if ((Get-FsCl3dBlocksSha $blocks) -cne $ts) { return (& $bad 'its stored text does not match its own text SHA-256 (edited, or not written by the checklist)') }
    $r.State = 'intact'; $r.Rec = $j; $r.AcceptedUtc = $au; $r.Why = "standing acceptance of $(Format-FsCl3dUtc $au) (cycle $(& $pv $j 'Cycle'))"; $r
}
# Review of 14107af MINOR-1: a standing record counts only if its originating cycle (Rec.Cycle) holds a phase-A PASS entry
# that gave the acceptance (mode full or changes) naming this record's SHA-256 (Acceptance.StandingSha256), with the y
# answers of its questions, written by the checklist version the record names (ToolSha256 = Rec.ToolPin), for the record's
# text SHA-256. A record made up for another cycle, or copied from another PC without its cycle folder, is refused. This
# ties the record to that cycle's own record on this PC; it does not prove that nobody edited both.
# Returns $null when the link holds, else why.
function Test-FsCl3dStandingLink($St) {
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $cyc = [string](& $pv $St.Rec 'Cycle')
    $cf = if ($cyc) { Join-Path $cyc 'checklist3d.json' } else { '' }
    if (-not $cf -or -not (Test-Path -LiteralPath $cf -PathType Leaf)) { return "its originating cycle '$cyc' has no checklist3d.json on this PC (made up, or copied from another PC without its cycle folder)" }
    try { $j = [IO.File]::ReadAllText($cf) | ConvertFrom-Json } catch { return "the originating cycle's $cf is unreadable" }
    if ([string](& $pv $j 'Schema') -cne $script:FsCl3dSchema) { return "the originating cycle's $cf is not a $($script:FsCl3dSchema) file" }
    # delta review of 6f2973f, MAJOR-1: only an entry that GAVE the acceptance (mode full or changes) is the origin; a later
    # phase A of the same cycle (a next-day resume, or a re-run before B) relies on the record in mode standing and names
    # the same SHA-256, and must not be taken as the origin
    $hits = @(@(& $pv $j 'Entries') | Where-Object { [string](& $pv $_ 'Phase') -ceq 'A' -and [string](& $pv $_ 'Result') -ceq 'PASS' -and [string](& $pv (& $pv $_ 'Acceptance') 'StandingSha256') -ceq [string]$St.Sha256 -and
                                                     [string](& $pv (& $pv $_ 'Acceptance') 'Mode') -cmatch '^(full|changes)\z' })
    if ($hits.Count -eq 0) { return "no phase-A PASS entry of its originating cycle ($cf) gave this record (SHA-256 $($St.Sha256))" }
    $a = $hits[-1]; $acc = & $pv $a 'Acceptance'; $mode = [string](& $pv $acc 'Mode')
    $need = @{ full = @('A1', 'A2', 'A3'); changes = @('R1') }
    $yes = @(@(& $pv $a 'Questions') | Where-Object { [string](& $pv $_ 'Answer') -ceq 'y' } | ForEach-Object { [string](& $pv $_ 'Id') })
    foreach ($q in @($need[$mode]) + @(@(& $pv $acc 'Asked') | ForEach-Object { [string]$_ })) { if ($yes -cnotcontains $q) { return "the originating entry lacks the answer y to $q" } }
    if ([string](& $pv $a 'ToolSha256') -cne [string]$St.Rec.ToolPin) { return "the originating entry was written by checklist $(& $pv $a 'ToolSha256'), the record names $($St.Rec.ToolPin)" }
    if ([string](& $pv $a 'TextSha256') -cne [string]$St.Rec.TextSha256) { return 'the originating entry accepted another text' }
    $null
}
function Save-FsCl3dJson([string]$Path, $Doc) {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path, (($Doc | ConvertTo-Json -Depth 8) -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
}
# Writes phase-a.json (the earlier one is kept in history\). Returns @{ Path; Sha256; TextSha256 }.
function Save-FsCl3dStanding([string]$Dir, [object[]]$Blocks, [DateTime]$NowUtc, [string]$LocalDate, [string]$Cycle, [string]$Mode, [string]$ToolPin, [string[]]$Asked, $Previous) {
    $p = Join-Path $Dir 'phase-a.json'
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $hd = Join-Path $Dir 'history'; $null = New-Item -ItemType Directory -Force -Path $hd
        Copy-Item -LiteralPath $p -Destination (Join-Path $hd ('phase-a-until-{0}.json' -f $NowUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))) -Force
    }
    $bl = @(foreach ($b in $Blocks) { [ordered]@{ Title = [string]$b.Title; Lines = [string[]]@($b.Lines | ForEach-Object { [string]$_ }); Sha256 = (Get-FsCl3dBlockSha $b) } })
    $doc = [ordered]@{ Schema = $script:FsCl3dStandingSchema
        Note = 'stage-3d STANDING phase-A acceptance (PM, J-143): valid while the text SHA-256 equals the current text and ToolPin equals the pinned fs-checklist3d.ps1; any change needs a new acceptance (only the changes are asked)'
        AcceptedUtc = (Format-FsCl3dUtc $NowUtc); AcceptedLocalDate = $LocalDate; Cycle = $Cycle; Mode = $Mode; ToolPin = $ToolPin; TextSha256 = (Get-FsCl3dBlocksSha $bl)
        Questions = @($Asked); Previous = $Previous; Blocks = $bl }
    Save-FsCl3dJson $p $doc
    [pscustomobject]@{ Path = $p; Sha256 = (Get-FsCl3dSha $p); TextSha256 = $doc.TextSha256 }
}
# The lines that changed since the accepted blocks (what phase A shows for a re-acceptance: only the changes)
function Get-FsCl3dChangeLines([object[]]$Old, [object[]]$New, [string]$Root) {
    $out = New-Object System.Collections.Generic.List[string]
    $shown = { param([string]$l) $l.Replace('<repository>', $Root.TrimEnd('\')) }
    foreach ($nb in $New) {
        $obs = @($Old | Where-Object { [string]$_.Title -ceq [string]$nb.Title })
        $ol = if ($obs.Count) { [string[]]@($obs[0].Lines | ForEach-Object { [string]$_ }) } else { [string[]]@() }
        $nl = [string[]]@($nb.Lines | ForEach-Object { [string]$_ })
        if ($obs.Count -and (Get-FsCl3dBlockSha $obs[0]) -ceq (Get-FsCl3dBlockSha $nb)) { continue }
        $out.Add("$(if ($obs.Count) { 'CHANGED' } else { 'NEW' }): $($nb.Title)")
        $pic = ([string]$nb.Title -ceq 'THE PREVIEW PICTURES (SHA-256)')
        $add = @($nl | Where-Object { $ol -cnotcontains $_ }); $rem = @($ol | Where-Object { $nl -cnotcontains $_ })
        foreach ($l in $add) { if ($pic) { $out.Add("- picture changed, open it again: $($Root.TrimEnd('\'))\$($script:FsCl3dPreviewDir)\$(($l -split '  ')[0])") } else { $out.Add("- new: $(& $shown $l)") } }
        if (-not $pic) { foreach ($l in $rem) { $out.Add("- removed: $(& $shown $l)") } }
        if (-not $add.Count -and -not $rem.Count) { $out.Add('- the same lines in another order') }
    }
    foreach ($ob in $Old) { if (@($New | Where-Object { [string]$_.Title -ceq [string]$ob.Title }).Count -eq 0) { $out.Add("REMOVED: $($ob.Title)") } }
    ,$out.ToArray()
}
# J-143 (a): the session/collector tool set, each file's SHA-256 (or 'missing') and the set's SHA-256 (fs-carry3d.ps1)
function Get-FsCl3dToolSet([string]$Root) { Get-FsCarry3dToolSet $Root }
# carryover.json (Passes) and speakers.json (Switches): { Schema; Note; <Prop>: [...] }. Returns @{ Ok; Why; Items }.
function Read-FsCl3dList([string]$Path, [string]$Schema, [string]$Prop) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Ok = $true; Why = 'none'; Items = @() } }
    try { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Why = "unreadable: $Path"; Items = @() } }
    if ($null -eq $j -or -not $j.PSObject.Properties['Schema'] -or [string]$j.Schema -cne $Schema -or -not $j.PSObject.Properties[$Prop]) { return [pscustomobject]@{ Ok = $false; Why = "$Path is not a $Schema file"; Items = @() } }
    [pscustomobject]@{ Ok = $true; Why = 'read'; Items = @($j.$Prop | Where-Object { $null -ne $_ }) }
}
function Add-FsCl3dListItems([string]$Path, [string]$Schema, [string]$Prop, [string]$Note, [object[]]$Items) {
    $cur = Read-FsCl3dList $Path $Schema $Prop
    if (-not $cur.Ok) { throw $cur.Why }
    Save-FsCl3dJson $Path ([ordered]@{ Schema = $Schema; Note = $Note; $Prop = @(@($cur.Items) + @($Items | ForEach-Object { [pscustomobject]$_ })) })
}
# The latest declared speaker switch (UTC), $null when none; 'bad' when a switch time is unreadable (no carry-over)
function Get-FsCl3dLastSwitch([object[]]$Items) {
    $last = $null
    foreach ($s in $Items) { $t = if ($s.PSObject.Properties['Utc']) { ConvertFrom-FsCl3dUtc ([string]$s.Utc) } else { $null }; if ($null -eq $t) { return 'bad' }; if ($null -eq $last -or $t -gt $last) { $last = $t } }
    $last
}
# One sound check or rehearsal. Every pass carries its made record (fs-carry3d.ps1: the UTC time and the tool-set SHA-256
# it was made with), and every pass, FRESH from this cycle's own file or CARRIED OVER from the latest recorded pass, counts
# only if (a) it was made with the current tool set, (b) on today's PC local date (not in the future), (c) after the last
# declared speaker change (review of 14107af, MAJOR-1: a fresh file was taken on trust); a carried one also needs its
# recorded SHA-256. Returns @{ Ok; Why; Rec } (Rec: Mode, Kind, Path, Sha256, ToolSetSha256, MadeUtc, AcceptedUtc, LocalDate, Cycle).
function Test-FsCl3dMadeRules {
    param($Made, $ToolSet, [DateTime]$NowUtc, [scriptblock]$LocalDate, $LastSwitch, $OldFiles = $null)
    $why = @(); $today = & $LocalDate $NowUtc; $d = & $LocalDate $Made.MadeUtc
    if ($Made.ToolSetSha256 -cne $ToolSet.Sha256) {
        $chg = @(); if ($null -ne $OldFiles) { $old = @{}; foreach ($f in @($OldFiles)) { if ($f.PSObject.Properties['File']) { $old[[string]$f.File] = [string]$f.Sha256 } }; $chg = @(foreach ($f in $ToolSet.Files) { if (-not $old.ContainsKey($f.File) -or $old[$f.File] -cne $f.Sha256) { Split-Path -Leaf $f.File } }) }
        $why += "(a) the session/collector tools changed since it was made$(if ($chg.Count) { ' (' + ($chg -join ', ') + ')' })"
    }
    if ($Made.MadeUtc -gt $NowUtc.AddSeconds($script:FsCl3dFutureSlackSec)) { $why += "it is recorded as made in the future ($(Format-FsCl3dUtc $Made.MadeUtc))" }
    elseif ($d -cne $today) { $why += "(b) it was made on $d, today is $today (PC local date)" }
    if ($LastSwitch -is [string]) { $why += '(c) the speaker-setup record has an unreadable time (safe side: nothing counts)' }
    elseif ($null -ne $LastSwitch -and $Made.MadeUtc -le $LastSwitch) { $why += "(c) new speakers were declared at $(Format-FsCl3dUtc $LastSwitch), after it was made" }
    ,@($why)
}
# Delta review of 6f2973f, MINOR-1: a rehearsal names the replay it rehearsed; it must be the expected one for its kind
# (garbled-r3 for the garbled path, nominal-read for the timed read path), by path and by the current SHA-256 of that
# replay in $Root. Returns $null when it is, else why.
function Test-FsCl3dReplay($Made, [string]$Kind, [string]$Root) {
    if ($Kind -ceq 'soundcheck') { return $null }
    $rel = $script:FsCarry3dReplays[$Kind]; $want = Get-FsCl3dSha (Join-Path $Root $rel); $tail = '\' + (Split-Path -Leaf (Split-Path -Parent $rel)) + '\capture.raw'
    $rp = ([string]$Made.ReplayPath).Replace('/', '\')
    if (-not $rp.EndsWith($tail, [StringComparison]::OrdinalIgnoreCase)) { return "it rehearsed '$($Made.ReplayPath)', not the expected replay ...$tail" }
    if (-not $want -or [string]$Made.ReplaySha256 -cne $want) { return "its replay SHA-256 $($Made.ReplaySha256) is not the current $rel ($want)" }
    $null
}
function Resolve-FsCl3dPass {
    param([string]$Kind, [string]$FreshFile, [scriptblock]$Test, [string]$Cycle, $ToolSet, [DateTime]$NowUtc, [scriptblock]$LocalDate, $Ledger, $LastSwitch, [bool]$NewSpeakers, [string]$Redo, [string]$Root = $script:FsCarry3dRoot)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "needed: $Redo. $w"; Rec = $null } }
    $today = & $LocalDate $NowUtc
    $arg = { param([string]$f) if ($Kind -ceq 'soundcheck') { $f } else { Split-Path -Parent $f } }
    if (Test-Path -LiteralPath $FreshFile -PathType Leaf) {
        $t = & $Test (& $arg $FreshFile)
        if (-not $t.Ok) { return (& $no "This cycle's own $Kind does not pass: $($t.Why)") }
        $mr = Read-FsCarry3dMade $Kind $FreshFile
        if (-not $mr.Ok) { return (& $no "This cycle's own $Kind has no made record: $($mr.Why)") }
        $w = Test-FsCl3dMadeRules $mr $ToolSet $NowUtc $LocalDate $LastSwitch
        $rw = Test-FsCl3dReplay $mr $Kind $Root; if ($rw) { $w = @($w) + @($rw) }
        if ($w.Count) { return (& $no "This cycle's own $Kind ($FreshFile, made $(Format-FsCl3dUtc $mr.MadeUtc)) does not count: $($w -join '; ')") }
        $full = [IO.Path]::GetFullPath($FreshFile)
        return [pscustomobject]@{ Ok = $true; Why = "fresh (this cycle, made $(Format-FsCl3dUtc $mr.MadeUtc)): $($t.Why)"; Rec = [ordered]@{ Mode = 'fresh'; Kind = $Kind; Path = $full; Sha256 = (Get-FsCl3dSha $full); ToolSetSha256 = $ToolSet.Sha256
                                   MadeUtc = (Format-FsCl3dUtc $mr.MadeUtc); AcceptedUtc = (Format-FsCl3dUtc $NowUtc); LocalDate = $today; Cycle = $Cycle; Why = "fresh in this cycle: $($t.Why)" } }
    }
    if ($NewSpeakers) { return (& $no "New speakers were declared (-NewSpeakers): nothing earlier carries over; run it in this cycle ($FreshFile)") }
    if (-not $Ledger.Ok) { return (& $no "The carry-over record cannot be read: $($Ledger.Why)") }
    $best = $null; $bestT = $null
    foreach ($it in @($Ledger.Items | Where-Object { $_.PSObject.Properties['Kind'] -and [string]$_.Kind -ceq $Kind })) {
        $t0 = if ($it.PSObject.Properties['MadeUtc']) { ConvertFrom-FsCl3dUtc ([string]$it.MadeUtc) } else { $null }
        if ($null -ne $t0 -and ($null -eq $bestT -or $t0 -gt $bestT)) { $best = $it; $bestT = $t0 }
    }
    if ($null -eq $best) { return (& $no "No earlier $Kind pass is recorded (nothing to carry over); run it in this cycle ($FreshFile)") }
    $pv = { param([string]$n) if ($best.PSObject.Properties[$n]) { [string]$best.$n } else { '' } }
    $path = & $pv 'Path'; $why = @()
    $h = if ($path) { Get-FsCl3dSha $path } else { $null }
    if (-not $h) { $why += "its file is missing ($path)" }
    elseif ($h -cne (& $pv 'Sha256')) { $why += "its file $path changed since (SHA-256 $h, recorded $(& $pv 'Sha256'))" }
    else {
        $t = & $Test (& $arg $path); if (-not $t.Ok) { $why += "its file no longer passes: $($t.Why)" }
        $mr = Read-FsCarry3dMade $Kind $path
        if (-not $mr.Ok) { $why += "its made record: $($mr.Why)" }
        elseif ($mr.MadeUtc -ne $bestT -or $mr.ToolSetSha256 -cne (& $pv 'ToolSetSha256')) { $why += 'its made record differs from the carry-over record' }
        else { $w2 = Test-FsCl3dMadeRules $mr $ToolSet $NowUtc $LocalDate $LastSwitch $(if ($best.PSObject.Properties['ToolSet']) { @($best.ToolSet) } else { $null }); $why += $w2
               $rw = Test-FsCl3dReplay $mr $Kind $Root; if ($rw) { $why += $rw } }
    }
    $src = "the $Kind made $(Format-FsCl3dUtc $bestT) (cycle $(& $pv 'Cycle'), $path)"
    if ($why.Count) { return (& $no "No carry-over of ${src}: $($why -join '; ')") }
    [pscustomobject]@{ Ok = $true; Why = "carried over: $src; same tools, same day ($today), no speaker change since"
                       Rec = [ordered]@{ Mode = 'carried'; Kind = $Kind; Path = $path; Sha256 = $h; ToolSetSha256 = $ToolSet.Sha256; MadeUtc = (Format-FsCl3dUtc $bestT); AcceptedUtc = (& $pv 'AcceptedUtc'); LocalDate = (& $LocalDate $bestT); Cycle = (& $pv 'Cycle')
                                         Why = "carried over from $src" } }
}

# The observer's own -Preflight (no device action), run as the PM would run it.
$script:FsCl3dRealPreflight = {
    param([string]$ImagePath)
    $obs = Join-Path (Split-Path -Parent $script:FsCl3dSelf) 'fs-observe3d.ps1'
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $obs -Image $ImagePath -Preflight | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    $im = @($out | Where-Object { $_ -cmatch '^image OK: stage 3d nonce ([0-9a-f]{16}) sha256 ([0-9a-f]{64})\z' })
    $ok = ($code -eq 0 -and $im.Count -eq 1 -and @($out | Where-Object { $_ -cmatch '^preflight OK' }).Count -eq 1)
    $n = $null; $s = $null
    if ($im.Count -eq 1 -and $im[0] -cmatch '^image OK: stage 3d nonce ([0-9a-f]{16}) sha256 ([0-9a-f]{64})\z') { $n = $Matches[1]; $s = $Matches[2] }
    [pscustomobject]@{ Ok = $ok; Why = ("exit $code; " + $(if ($out.Count) { $out[-1] } else { '(no output)' })); Nonce = $n; ImageSha = $s }
}
# Console y/n with a timeout; buffered keys are discarded before the question. Returns y, n, timeout or noconsole.
$script:FsCl3dConsoleAsk = {
    param([string]$Text, [int]$TimeoutSec)
    try { while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) } } catch { return 'noconsole' }
    Write-Host ''
    foreach ($w in (Format-FsCl3dWrap "QUESTION: $Text" $script:FsCl3dWrap)) { Write-Host $w -ForegroundColor Yellow }
    Write-Host (Format-FsCl3dPrompt $TimeoutSec) -ForegroundColor Yellow
    $dl = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $dl) {
        if ([Console]::KeyAvailable) {
            $c = [string]([Console]::ReadKey($true).KeyChar)
            if ($c -ceq 'y' -or $c -ceq 'Y') { Write-Host '  answer: y (yes)'; return 'y' }
            if ($c -ceq 'n' -or $c -ceq 'N') { Write-Host '  answer: n (no)'; return 'n' }
            Write-Host '  (only y or n counts)'
        }
        Start-Sleep -Milliseconds 50
    }
    'timeout'
}

# checklist3d.json: { Schema; Entries: [ ... ] }. Returns @{ Ok; Why; Entries }.
function Read-FsCl3dFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Ok = $true; Why = 'new'; Entries = @() } }
    try { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Why = "unreadable checklist file $Path (not overwritten)"; Entries = @() } }
    if ($null -eq $j -or -not $j.PSObject.Properties['Schema'] -or [string]$j.Schema -cne $script:FsCl3dSchema -or -not $j.PSObject.Properties['Entries']) {
        return [pscustomobject]@{ Ok = $false; Why = "$Path is not a $($script:FsCl3dSchema) file (not overwritten)"; Entries = @() }
    }
    [pscustomobject]@{ Ok = $true; Why = 'read'; Entries = @($j.Entries) }
}
# the LAST entry of a phase, as a result string (PASS, STOP, or '' when the phase never ran)
function Get-FsCl3dLastResult([object[]]$Entries, [string]$Ph) {
    $l = ''
    foreach ($e in $Entries) { if ($null -ne $e -and $e.PSObject.Properties['Phase'] -and [string]$e.Phase -ceq $Ph) { $l = if ($e.PSObject.Properties['Result']) { [string]$e.Result } else { '?' } } }
    $l
}
function Add-FsCl3dCheck($E, [string]$Name, [bool]$Ok, [string]$Detail, [scriptblock]$Say) {
    $E.Checks += [ordered]@{ Name = $Name; Ok = $Ok; Detail = $Detail }
    & $Say ("  check {0}: {1} - {2}" -f $Name, $(if ($Ok) { 'OK' } else { 'FAILED' }), $Detail)
}
# The question is recorded BEFORE it is asked (answer "interrupted"), so a Ctrl+C leaves it in the STOP entry.
function Invoke-FsCl3dQuestion($E, [string]$Key, [scriptblock]$Ask, [scriptblock]$NowUtc, [int]$TimeoutSec) {
    $text = $script:FsCl3dQ[$Key]
    $q = [ordered]@{ Id = $Key; Text = $text; Answer = 'interrupted'; AskedUtc = (Format-FsCl3dUtc (& $NowUtc)); AnsweredUtc = $null; TimeoutSec = $TimeoutSec }
    $E.Questions += $q
    $a = [string](& $Ask $text $TimeoutSec)
    if (@('y', 'n', 'timeout', 'noconsole') -cnotcontains $a) { $a = 'invalid' }
    $q.Answer = $a; $q.AnsweredUtc = Format-FsCl3dUtc (& $NowUtc)
    $a
}
# Prints a block (title, then each item) and records its title, line count and SHA-256 (title line and items, unwrapped, LF, UTF-8).
function Write-FsCl3dBlock($E, [string]$Title, [string[]]$Lines, [scriptblock]$Say) {
    & $Say ''; & $Say "== $Title"; foreach ($l in $Lines) { & $Say "  $l" }
    $E.Blocks += [ordered]@{ Title = $Title; Lines = @($Lines).Count; Sha256 = (Get-FsCl3dTextSha (@("== $Title") + @($Lines))) }
}

function Save-FsCl3dEntry([string]$Cycle, [object[]]$Prev, $E) {
    $jp = Join-Path $Cycle 'checklist3d.json'; $tp = Join-Path $Cycle 'checklist3d.txt'
    $all = @($Prev) + @([pscustomobject]$E)
    $doc = [ordered]@{ Schema = $script:FsCl3dSchema; Note = 'stage-3d console checklist (J-118; single temperature reading J-125, typed text with the unit, review MAJOR-1/2; standing phase A and carry-over J-143; charging below 300 J-145): one entry per run of fs-checklist3d.ps1; fs-observe3d.ps1 needs the last A, B and E entries PASS and E at most 300 s old'; Entries = $all }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($jp, (($doc | ConvertTo-Json -Depth 8) -replace "`r`n", "`n") + "`n", $enc)
    $t = New-Object System.Collections.Generic.List[string]
    $t.Add("== phase $($E.Phase): $($E.Result)  start $($E.StartUtc)  end $($E.EndUtc)  tool sha256 $($E.ToolSha256)")
    foreach ($c in @($E.Checks)) { $t.Add("   check $($c.Name): $(if ($c.Ok) { 'OK' } else { 'FAILED' }) - $($c.Detail)") }
    if ($E.Contains('Reading') -and $null -ne $E.Reading) { $p = $E.Reading; $t.Add("   reading: $($p.R1) at $($p.R1Utc) (battery status $($p.R1Status) $($p.R1StatusName); charge $(if ($p.R1Charge) { $p.R1Charge } else { '-' }); unit $($p.R1Serial) $(if ($p.R1Unit) { $p.R1Unit } else { '(unknown)' })); $($p.AgeSec) s old at phase B; ok $($p.Ok)") }
    foreach ($k in 'SoundCheck', 'Rehearsal', 'RehearsalRead') { if ($E.Contains($k) -and $null -ne $E[$k]) { $c = $E[$k]; $t.Add("   $($c.Kind): $($c.Mode) $($c.Path) sha256 $($c.Sha256) (accepted $($c.AcceptedUtc), $($c.LocalDate), cycle $($c.Cycle); tool set $($c.ToolSetSha256))") } }
    if ($E.Contains('Acceptance') -and $null -ne $E.Acceptance) { $c = $E.Acceptance; $t.Add("   acceptance: $($c.Mode); standing record $($c.StandingFile) sha256 $($c.StandingSha256) (accepted $($c.AcceptedUtc), cycle $($c.AcceptedCycle)); text sha256 $($c.TextSha256); tool pin $($c.ToolPin); asked: $(if (@($c.Asked).Count) { @($c.Asked) -join ',' } else { 'nothing' })") }
    foreach ($b in @($E.Blocks)) { $t.Add("   printed `"$($b.Title)`" ($($b.Lines) lines) sha256 $($b.Sha256)") }
    foreach ($q in @($E.Questions)) { $t.Add("   asked $($q.AskedUtc)  `"$($q.Text)`"  answer $($q.Answer) at $($q.AnsweredUtc)") }
    $t.Add("   $($E.Result): $($E.Why)")
    [IO.File]::AppendAllText($tp, (($t -join "`n") + "`n"), $enc)
    $jp
}

# One phase. $Opt: Root, SignoffFile, Image, RehearsalDir, RehearsalReadDir, Preflight (scriptblock), NewSpeakers,
# StandingDir (default <Root>\captures\standing), LocalDate (scriptblock UTC -> 'yyyy-MM-dd'; default the PC's local date), R1, R1Utc, R1Status,
# R1Charge, R1Serial (the reading's values as text), TimeoutSec (0 or absent: 900 s in phase A, 300 s in phase E).
# $Ask { param($Text, $TimeoutSec) -> y|n|timeout|noconsole }; $NowUtc { -> [DateTime] UTC };
# $Say { param($Line) } receives the console lines already wrapped at 90 characters.
# Returns @{ Exit; Why; Entry; JsonPath }.
function Invoke-FsCl3dPhase {
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string]$Cycle, [hashtable]$Opt = @{},
          [Parameter(Mandatory)][scriptblock]$Ask, [Parameter(Mandatory)][scriptblock]$NowUtc, [Parameter(Mandatory)][scriptblock]$Say)
    $fsCl3OuterSay = $Say
    $Say = { param([string]$Line) foreach ($w in (Format-FsCl3dWrap $Line $script:FsCl3dWrap)) { & $fsCl3OuterSay $w } }
    $stopLine = { param($w) "STOPPED. Nothing was sent to the headset. Tell the Arbiter: $w" }
    $res = [pscustomobject]@{ Exit = 1; Why = ''; Entry = $null; JsonPath = $null }
    $to = if ($Opt.ContainsKey('TimeoutSec') -and [int]$Opt.TimeoutSec -gt 0) { [int]$Opt.TimeoutSec } elseif ($Phase -ceq 'A') { $script:FsCl3dTimeoutA } else { $script:FsCl3dTimeoutE }
    if (@('A', 'B', 'E') -cnotcontains $Phase) { $res.Why = "unknown phase '$Phase' (A, B or E)"; & $Say (& $stopLine $res.Why); return $res }
    if (-not (Test-Path -LiteralPath $Cycle -PathType Container)) { $res.Why = "cycle directory $Cycle does not exist"; & $Say (& $stopLine $res.Why); return $res }
    $prev = Read-FsCl3dFile (Join-Path $Cycle 'checklist3d.json')
    if (-not $prev.Ok) { $res.Why = $prev.Why; & $Say (& $stopLine $res.Why); return $res }
    $ldf0 = Get-FsCl3dLocalDateFn $Opt; $today0 = & $ldf0 ((& $NowUtc).ToUniversalTime())
    $lastA = $null; $iA = -1; $k0 = 0
    foreach ($en in @($prev.Entries)) { if ($null -ne $en -and $en.PSObject.Properties['Phase'] -and [string]$en.Phase -ceq 'A') { $lastA = $en; $iA = $k0 }; $k0++ }
    $aDay = if ($null -ne $lastA -and $lastA.PSObject.Properties['LocalDate']) { [string]$lastA.LocalDate } else { '' }
    if ($Phase -ceq 'A' -and $null -ne $lastA -and $lastA.PSObject.Properties['Result'] -and [string]$lastA.Result -ceq 'PASS' -and $aDay -ceq $today0) {
        # review of 14107af MINOR-2: phase A asks nothing now, so a re-run between B and E is easy to do by mistake; it would
        # break the A, B, E order (J-140). Refused here, before any entry is written (the cycle stays usable).
        $ents = @($prev.Entries); $bAfter = $false
        for ($q = $iA + 1; $q -lt $ents.Count; $q++) { $x0 = $ents[$q]; if ($null -ne $x0 -and $x0.PSObject.Properties['Phase'] -and [string]$x0.Phase -ceq 'B' -and $x0.PSObject.Properties['Result'] -and [string]$x0.Result -ceq 'PASS') { $bAfter = $true } }
        if ($bAfter) {
            $res.Why = 'phase A already passed today in this cycle and phase B has passed after it: running phase A again now would break the A, B, E order (J-140). Go on with the next step (a new reading: phase B; then BA/BF, phase E). Phase A again only on a new day, or in a new cycle'
            & $Say (& $stopLine $res.Why); return $res
        }
    }
    $e = [ordered]@{ Phase = $Phase; Result = 'STOP'; Why = 'interrupted before the phase ended (Ctrl+C or an error)'; StartUtc = (Format-FsCl3dUtc (& $NowUtc)); EndUtc = $null
                     Tool = 'fs-checklist3d.ps1'; ToolSha256 = (Get-FsCl3dSha $script:FsCl3dSelf); Cycle = $Cycle; Checks = @(); Blocks = @(); Questions = @() }
    & $Say "== STAGE 3D CONSOLE CHECKLIST, PHASE $Phase (nothing here touches the headset)"
    $stop = { param($w) $e.Why = $w }
    # the phase body: a scriptblock, so that each `return` ends the phase (the entry is saved in finally, also on Ctrl+C)
    $body = {
        if ($Phase -ceq 'A') {
            $root = [string]$Opt.Root
            $hp = Test-FsCl3dHostPins -HashesFile (Join-Path $Cycle 'host-hashes.txt') -SignoffFile ([string]$Opt.SignoffFile) -Root $root
            Add-FsCl3dCheck $e 'host-pins' $hp.Ok $hp.Why $Say
            if (-not $hp.Ok) { & $stop 'the host pins do not match (checked first; nothing else is run): stop, nothing is booted'; return }
            $img = [string]$Opt.Image
            if (-not $img) { $pf = [pscustomobject]@{ Ok = $false; Why = 'no -Image given'; Nonce = $null; ImageSha = $null } } else { $pf = & $Opt.Preflight $img }
            Add-FsCl3dCheck $e 'preflight' ([bool]$pf.Ok) ("fs-observe3d.ps1 -Preflight: $($pf.Why)") $Say
            $e.Image = $img; $e.Nonce = $pf.Nonce; $e.ImageSha256 = $pf.ImageSha
            # J-143: the sound check and the rehearsals, fresh from this cycle or carried over (a: tools, b: day, c: speakers)
            $nowA = (& $NowUtc).ToUniversalTime(); $ldf = Get-FsCl3dLocalDateFn $Opt; $sdir = Get-FsCl3dStandingDir $Opt
            $ns = ($Opt.ContainsKey('NewSpeakers') -and [bool]$Opt.NewSpeakers)
            $ts = Get-FsCl3dToolSet $root
            $e.LocalDate = & $ldf $nowA; $e.ToolSetSha256 = $ts.Sha256; $e.NewSpeakers = $ns; $e.StandingDir = $sdir
            $spk = Join-Path $sdir 'speakers.json'
            if ($ns) { Add-FsCl3dListItems $spk $script:FsCl3dSpeakersSchema 'Switches' 'J-143 (c): new speaker setups declared by the PM (fs-checklist3d.ps1 -Phase A -NewSpeakers); a sound check or rehearsal from before the latest one does not carry over' @([ordered]@{ Utc = (Format-FsCl3dUtc $nowA); Cycle = $Cycle }) }
            $sw = Read-FsCl3dList $spk $script:FsCl3dSpeakersSchema 'Switches'
            $last = if ($sw.Ok) { Get-FsCl3dLastSwitch $sw.Items } else { 'bad' }
            $led = Read-FsCl3dList (Join-Path $sdir 'carryover.json') $script:FsCl3dLedgerSchema 'Passes'
            $rd = if ($Opt.ContainsKey('RehearsalDir') -and $Opt.RehearsalDir) { [string]$Opt.RehearsalDir } else { Join-Path $Cycle 'rehearsal' }
            $rr = if ($Opt.ContainsKey('RehearsalReadDir') -and $Opt.RehearsalReadDir) { [string]$Opt.RehearsalReadDir } else { Join-Path $Cycle 'rehearsal-read' }
            $passes = [ordered]@{
                soundcheck       = @((Join-Path $Cycle 'soundcheck.json'), { param($p) Test-FsCl3dSoundCheck $p }, 'SoundCheck', "a sound check in this cycle (WALKTHROUGH step 3: fs-collect3d.ps1 -S3dSoundCheck -S3dOutDir $Cycle)")
                rehearsal        = @((Join-Path $rd 'summary.txt'), { param($d) Test-FsCl3dRehearsal $d }, 'Rehearsal', "the rehearsal of the garbled path in this cycle (WALKTHROUGH step 4a, -S3dOutDir $rd)")
                'rehearsal-read' = @((Join-Path $rr 'summary.txt'), { param($d) Test-FsCl3dRehearsalRead $d }, 'RehearsalRead', "the timed rehearsal of the read path in this cycle (WALKTHROUGH step 4b, -S3dOutDir $rr)") }
            $fresh = @()
            foreach ($k in $passes.Keys) {
                $pz = $passes[$k]
                $x = Resolve-FsCl3dPass -Kind $k -FreshFile $pz[0] -Test $pz[1] -Cycle $Cycle -ToolSet $ts -NowUtc $nowA -LocalDate $ldf -Ledger $led -LastSwitch $last -NewSpeakers $ns -Redo $pz[3] -Root $root
                Add-FsCl3dCheck $e $k $x.Ok $x.Why $Say
                $e[$pz[2]] = $x.Rec
                if ($x.Ok -and $x.Rec.Mode -ceq 'fresh') { $fresh += $x.Rec }
            }
            $pv = Test-FsCl3dPreviews $root; Add-FsCl3dCheck $e 'previews' $pv.Ok $pv.Why $Say
            $failed = @($e.Checks | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name })
            if ($failed.Count) { & $stop "automatic check failed: $($failed -join ', '); nothing is asked; nothing is booted"; return }
            # J-143: the standing acceptance. The accepted text (questions, preview list and pictures, keys, D1 to D14)
            # against phase-a.json: intact and equal -> no question, also after a change of the checklist code alone (PM:
            # the version relying on it is recorded); changed text -> only the changes (R1); none -> the full phase A;
            # damaged -> STOP.
            $blocks = Get-FsCl3dAcceptBlocks $root; $tsha = Get-FsCl3dBlocksSha $blocks; $e.TextSha256 = $tsha
            $st = Read-FsCl3dStanding $sdir
            if ($st.State -ceq 'intact' -and $st.AcceptedUtc -gt $nowA.AddSeconds($script:FsCl3dFutureSlackSec)) { $st.State = 'damaged'; $st.Why = "the standing acceptance $($st.Path) is refused: its acceptance time $(Format-FsCl3dUtc $st.AcceptedUtc) is in the future" }
            if ($st.State -ceq 'intact') { $lw = Test-FsCl3dStandingLink $st; if ($lw) { $st.State = 'damaged'; $st.Why = "the standing acceptance $($st.Path) is refused: $lw" } }
            if ($st.State -ceq 'damaged') {
                Add-FsCl3dCheck $e 'standing' $false $st.Why $Say
                & $stop "$($st.Why). Nothing is relied on. The Arbiter moves the file aside (keep it for the record); the next phase A then asks for a full acceptance"; return
            }
            $mode = if ($st.State -ceq 'none') { 'full' } elseif ([string]$st.Rec.TextSha256 -cne $tsha) { 'changes' } else { 'standing' }
            # ToolPin: the checklist version relying on the acceptance (this file); RecordToolPin: the version that took it
            $acc = [ordered]@{ Mode = $mode; StandingFile = $st.Path; StandingSha256 = $null; TextSha256 = $tsha; ToolPin = $e.ToolSha256; RecordToolPin = $(if ($st.State -ceq 'intact') { [string]$st.Rec.ToolPin } else { $e.ToolSha256 }); AcceptedUtc = $null; AcceptedCycle = $null; Asked = @() }
            $e.Acceptance = $acc
            $ask1 = { param([string]$id) $a0 = Invoke-FsCl3dQuestion $e $id $Ask $NowUtc $to; if ($a0 -cne 'y') { & $stop "answer '$a0' to: $($script:FsCl3dQ[$id])" }; $acc.Asked += $id; $a0 }
            if ($mode -ceq 'standing') {
                $tv = if ([string]$st.Rec.ToolPin -ceq $e.ToolSha256) { "the same checklist (pin $($e.ToolSha256))" } else { "taken with checklist $($st.Rec.ToolPin), relied on by this checklist $($e.ToolSha256) (code change only: no question)" }
                Add-FsCl3dCheck $e 'standing' $true "$($st.Why): the same text and pictures (SHA-256 $tsha); $tv; no question" $Say
                Write-FsCl3dBlock $e 'STANDING ACCEPTANCE (nothing to read or answer)' @("Your acceptance of $(Format-FsCl3dUtc $st.AcceptedUtc) covers the current text and pictures exactly.", "Record: $($st.Path) (SHA-256 $($st.Sha256)).") $Say
                $acc.StandingSha256 = $st.Sha256; $acc.AcceptedUtc = Format-FsCl3dUtc $st.AcceptedUtc; $acc.AcceptedCycle = [string]$st.Rec.Cycle
            } else {
                $why0 = switch ($mode) { 'full' { $st.Why + ': the full phase A follows' } default { "$($st.Why) covers another text (SHA-256 $($st.Rec.TextSha256), now $tsha): only the changes are asked" } }
                Add-FsCl3dCheck $e 'standing' $true $why0 $Say
                if ($mode -ceq 'full') {
                    Write-FsCl3dBlock $e 'THE THREE PREVIEW PICTURES' (Get-FsCl3dPreviewLines $root) $Say
                    if ((& $ask1 'A1') -cne 'y') { return }
                    Write-FsCl3dBlock $e 'THE KEYS (what to press for what you see)' $script:FsCl3dText.KeyLines $Say
                    if ((& $ask1 'A2') -cne 'y') { return }
                    Write-FsCl3dBlock $e 'WHAT I ACCEPT (points D1 to D14)' $script:FsCl3dText.Accept $Say
                    if ((& $ask1 'A3') -cne 'y') { return }
                } else {
                    Write-FsCl3dBlock $e "CHANGES SINCE YOUR ACCEPTANCE OF $(Format-FsCl3dUtc $st.AcceptedUtc) (only these need reading)" (Get-FsCl3dChangeLines @($st.Rec.Blocks) $blocks $root) $Say
                    if ((& $ask1 'R1') -cne 'y') { return }
                }
                $prv = if ($st.State -ceq 'intact') { [ordered]@{ AcceptedUtc = (Format-FsCl3dUtc $st.AcceptedUtc); Cycle = [string]$st.Rec.Cycle; TextSha256 = [string]$st.Rec.TextSha256; ToolPin = [string]$st.Rec.ToolPin; Sha256 = $st.Sha256 } } else { $null }
                $sv = Save-FsCl3dStanding -Dir $sdir -Blocks $blocks -NowUtc (& $NowUtc) -LocalDate $e.LocalDate -Cycle $Cycle -Mode $mode -ToolPin $e.ToolSha256 -Asked ([string[]]$acc.Asked) -Previous $prv
                if ($sv.TextSha256 -cne $tsha) { throw "the standing record written does not hold the accepted text ($($sv.TextSha256) != $tsha)" }
                $acc.StandingSha256 = $sv.Sha256; $acc.AcceptedUtc = (Read-FsCl3dStanding $sdir).Rec.AcceptedUtc; $acc.AcceptedCycle = $Cycle; $acc.RecordToolPin = $e.ToolSha256
                & $Say "standing acceptance recorded: $($sv.Path) (SHA-256 $($sv.Sha256)); later cycles ask nothing while the text and the pictures stay the same"
            }
            if ($fresh.Count) {
                Add-FsCl3dListItems (Join-Path $sdir 'carryover.json') $script:FsCl3dLedgerSchema 'Passes' 'J-143: sound checks and rehearsals accepted fresh by fs-checklist3d.ps1 -Phase A; a later cycle carries the latest of each kind (by MadeUtc) over while the tool set, the PC local date and the speaker setup stay the same' `
                    @(foreach ($f in $fresh) { [ordered]@{ Kind = $f.Kind; Path = $f.Path; Sha256 = $f.Sha256; ToolSetSha256 = $f.ToolSetSha256; ToolSet = @($ts.Files); MadeUtc = $f.MadeUtc; AcceptedUtc = $f.AcceptedUtc; LocalDate = $f.LocalDate; Cycle = $f.Cycle } })
            }
            $e.Result = 'PASS'
            $e.Why = "automatic checks OK (nonce $($e.Nonce)); sound check $($e.SoundCheck.Mode), rehearsals $($e.Rehearsal.Mode)/$($e.RehearsalRead.Mode); " + $(switch ($mode) { 'standing' { "the standing acceptance of $($acc.AcceptedUtc) relied on (no question)" } 'full' { 'previews, keys and points D1 to D14 confirmed (standing acceptance recorded)' } default { 'the changes confirmed (standing acceptance renewed)' } })
        } elseif ($Phase -ceq 'B') {
            $la = Get-FsCl3dLastResult $prev.Entries 'A'
            if ($la -cne 'PASS') { & $stop 'phase A has not passed in this cycle (run -Phase A first)'; return }
            # review of 14107af MAJOR-2: phase A (and the passes it relied on) is valid for its own PC day only
            if ($aDay -cne $today0) { & $stop "new day: this cycle's phase A is from $(if ($aDay) { $aDay } else { 'an unknown day' }), today is $today0 (PC local date): run step 2 (phase A) again"; return }
            # review MAJOR-1: every value is the text that was typed, checked as text; nothing is converted before the
            # check (an [int] parameter or cast rounds "36.2" to 36 and "2.6" to 3) and nothing is rounded
            $v = { param($k) if ($Opt.ContainsKey($k) -and $null -ne $Opt[$k]) { [string]$Opt[$k] } else { '' } }
            $r1s = & $v 'R1'; $uts = & $v 'R1Utc'; $sts = & $v 'R1Status'; $chs = & $v 'R1Charge'; $ser = & $v 'R1Serial'
            $t1 = ConvertFrom-FsCl3dUtc $uts
            $inOk = ($r1s -cmatch '^[0-9]{3}\z' -and $null -ne $t1 -and $sts -cmatch '^[1-5]\z' -and $ser -cmatch '^[A-Za-z0-9]{6,32}\z' -and ($chs -ceq '' -or $chs -cmatch '^(100|[1-9]?[0-9])\z'))
            Add-FsCl3dCheck $e 'reading-input' $inOk ("reading '$r1s' at '$uts', battery status '$sts', unit '$ser'$(if ($chs) { ", charge '$chs'" }) (the reading: three digits, tenths of deg C; the PC's UTC yyyy-MM-ddTHH:mm:ss[.f]Z; the dumpsys battery status: one digit 1-5; the unit's serial; the charge 0-100 if given)") $Say
            if (-not $inOk) { & $stop 'the temperature reading is incomplete or malformed (-R1 three digits, -R1Utc the PC UTC, -R1Status one digit, -R1Serial): type the values exactly as read'; return }
            $r1 = [int]$r1s; $sn = $script:FsCl3dStatusName[[int]$sts]
            $unit = if (@($script:FsCl3dUnits.Keys) -ccontains $ser) {   # case-sensitive (an [ordered] dictionary's Contains is not)
                [string]$script:FsCl3dUnits[$ser] } else { '' }
            # the age is compared exactly (review MINOR: no 0.1 s rounding before the comparison); AgeSec is for display only
            $now = (& $NowUtc).ToUniversalTime(); $ageTicks = ($now - $t1).Ticks; $age = [Math]::Round($ageTicks / 10000000.0, 1)
            $inRange = ($r1 -ge $script:FsCl3dTempMin -and $r1 -lt $script:FsCl3dTempLimit); $known = [bool]$unit
            # J-145 (PM): status 3/4/5 below 350 (as before), or status 2 (charging) only below 300; status 1 never
            $battOk = (($script:FsCl3dStatusOk -ccontains $sts) -or ($sts -ceq '2' -and $r1 -lt $script:FsCl3dChargingLimit))
            $past = ($t1 -le $now.AddSeconds($script:FsCl3dFutureSlackSec)); $fresh = ($ageTicks -le [TimeSpan]::FromSeconds($script:FsCl3dReadingMaxAgeSec).Ticks)
            Add-FsCl3dCheck $e 'range-100-349' $inRange "reading $r1s (must be 100 to 349: 10.0 to 34.9 deg C; 350 = 35.0 deg C and above fail)" $Say
            Add-FsCl3dCheck $e 'battery-rule' $battOk "battery status $sts ($sn) with reading $r1s (3 discharging, 4 not charging or 5 full: below 350; 2 charging: only below 300, J-145; 1 unknown fails)" $Say
            Add-FsCl3dCheck $e 'known-unit' $known "unit $ser $(if ($unit) { "($unit)" } else { '(not one of the two Quest 3 units)' }) (Unit 1 QUEST3UNIT1, Unit 2 QUEST3UNIT2; fs-observe3d.ps1 requires it to equal the attempt's -Serial)" $Say
            Add-FsCl3dCheck $e 'not-in-future' $past "reading at $(Format-FsCl3dUtc $t1) (the PC's UTC at the reading), now $(Format-FsCl3dUtc $now) (at most $($script:FsCl3dFutureSlackSec) s ahead: a typing delay)" $Say
            Add-FsCl3dCheck $e 'at-most-15-min-old' $fresh "the reading is $age s old now (at most $($script:FsCl3dReadingMaxAgeSec) s, compared exactly; it must also be at most $($script:FsCl3dReadingMaxAgeSec) s before BA, which fs-observe3d.ps1 checks)" $Say
            $ok = ($inRange -and $battOk -and $known -and $past -and $fresh)
            $e.Reading = [ordered]@{ R1 = $r1s; R1Utc = (Format-FsCl3dUtc $t1); R1Status = $sts; R1StatusName = $sn; R1Charge = $chs; R1Serial = $ser; R1Unit = $unit; AgeSec = $age
                                     Rule = "three digits from $($script:FsCl3dTempMin) to $($script:FsCl3dTempLimit - 1) (35.0 deg C and above fail); dumpsys battery status 3, 4 or 5, or status 2 (charging) only below $($script:FsCl3dChargingLimit) (J-145); a Quest 3 unit, equal to the attempt's -Serial (fs-observe3d.ps1); the PC's UTC, not in the future (at most $($script:FsCl3dFutureSlackSec) s ahead); at most $($script:FsCl3dReadingMaxAgeSec) s old now and at most $($script:FsCl3dReadingMaxAgeSec) s before BA (fs-observe3d.ps1), compared exactly"; Ok = $ok }
            if (-not $ok) { & $stop 'the temperature reading does not meet the rule: wait (while charging the reading must be below 300; unplug the charger or wait for it to cool), then take a new reading'; return }
            $e.Result = 'PASS'; $e.Why = "temperature reading $r1s at $(Format-FsCl3dUtc $t1), battery $sn, $unit ($ser): within the rule; BA must start within $($script:FsCl3dReadingMaxAgeSec) s of the reading"
        } else {
            if ((Get-FsCl3dLastResult $prev.Entries 'A') -cne 'PASS') { & $stop 'phase A has not passed in this cycle'; return }
            if ($aDay -cne $today0) { & $stop "new day: this cycle's phase A is from $(if ($aDay) { $aDay } else { 'an unknown day' }), today is $today0 (PC local date): run step 2 (phase A) again, then a new reading (phase B), BA/BF and phase E"; return }
            if ((Get-FsCl3dLastResult $prev.Entries 'B') -cne 'PASS') { & $stop 'phase B (the temperature reading) has not passed in this cycle'; return }
            Write-FsCl3dBlock $e 'PRESENCE (immediately before the attempt)' $script:FsCl3dText.Presence $Say
            Write-FsCl3dBlock $e 'AFTER THE SESSION' $script:FsCl3dText.After $Say
            $a = Invoke-FsCl3dQuestion $e 'E1' $Ask $NowUtc $to; if ($a -cne 'y') { & $stop "answer '$a' to: $($script:FsCl3dQ.E1)"; return }
            $a = Invoke-FsCl3dQuestion $e 'E2' $Ask $NowUtc $to; if ($a -cne 'y') { & $stop "answer '$a' to: $($script:FsCl3dQ.E2)"; return }
            $e.Result = 'PASS'; $e.Why = "presence confirmed at $(@($e.Questions)[-1].AnsweredUtc); the attempt must start within $($script:FsCl3dPresenceMaxSec) s"
        }
    }
    try { $null = & $body }
    finally {
        $e.EndUtc = Format-FsCl3dUtc (& $NowUtc)
        $res.Entry = [pscustomobject]$e; $res.Why = $e.Why
        $res.JsonPath = Save-FsCl3dEntry $Cycle $prev.Entries $e
        & $Say ''; & $Say "recorded: $($res.JsonPath)"
        if ($e.Result -ceq 'PASS') { $res.Exit = 0; & $Say "PHASE $Phase PASSED: $($e.Why)" }
        else { & $Say (& $stopLine "phase $Phase - $($e.Why)") }
    }
    $res
}

if ($script:FsCl3dInvocation -eq '.') { return }
# ------------------------------------------------------------------ CLI -----
$exit = 70
try {
    if (@('A', 'B', 'E') -cnotcontains $Phase -or -not $Cycle) {
        Write-Output 'usage: fs-checklist3d.ps1 -Phase A|B|E -Cycle <cycle dir> [-Image <img>\boot-stage3d.img [-NewSpeakers]] [-R1 <t> -R1Utc <utc> -R1Status <status> -R1Serial <serial> [-R1Charge <%>]]   (no device action)'; exit 64
    }
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path          # FIXED: the repository of this file
    $cyc = if (Test-Path -LiteralPath $Cycle -PathType Container) { (Resolve-Path -LiteralPath $Cycle).Path } else { $Cycle }
    $opt = @{ Root = $root; SignoffFile = (Join-Path $root 'devices\quest3\SIGNOFF-3d.md'); Image = $Image; RehearsalDir = $RehearsalDir; RehearsalReadDir = $RehearsalReadDir; Preflight = $script:FsCl3dRealPreflight; TimeoutSec = $TimeoutSec; NewSpeakers = [bool]$NewSpeakers }
    # review MAJOR-1: the reading's values are passed on as the typed text (string parameters; checked by phase B)
    foreach ($k in 'R1', 'R1Utc', 'R1Status', 'R1Charge', 'R1Serial') { if ($PSBoundParameters.ContainsKey($k)) { $opt[$k] = [string]$PSBoundParameters[$k] } }
    $res = Invoke-FsCl3dPhase -Phase $Phase -Cycle $cyc -Opt $opt -Ask $script:FsCl3dConsoleAsk -NowUtc { [DateTime]::UtcNow } -Say { param([string]$Line) Write-Host $Line }
    $exit = $res.Exit
} catch { Write-Output "CHECKLIST ERROR: $($_.Exception.Message)"; $exit = 70 }
exit $exit
