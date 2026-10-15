<#
FrameShift - stage-3c console checklist (Windows PowerShell 5.1). Replaces the SIGNOFF-3c sheet
(PM decision, docs/JOURNAL.md J-118): the PC asks each confirmation at the right moment and records the
answers with UTC timestamps; the Chair gets the same evidence (checklist3c.json, checklist3c.txt).

NO DEVICE COMMAND, NO NETWORK. The file only reads files of this cycle and of the repository, runs the
observer's -Preflight (which itself touches no device), asks y/n questions on the console, and APPENDS
one entry per run to <cycle>\checklist3c.json and <cycle>\checklist3c.txt (an existing file is never
rewritten with fewer entries; an unreadable one stops the phase without writing).

Phases (devices/quest3/SIGNOFF-3c.md lists every check and the exact text printed):
  -Phase A   before BA. Automatic: host-hashes.txt (the literal Get-FileHash command of SIGNOFF-3c A)
             and the working files equal the SIGNOFF-3c host-pin table (checked FIRST; on a mismatch
             nothing else runs); fs-observe3c.ps1 -Preflight prints "preflight OK"; soundcheck.json
             Pass; the rehearsal summary (<cycle>\rehearsal-2\summary.txt) has the GO line and the Q7
             fallback note; the previews exist. Then three questions: the preview pictures (their
             absolute paths printed), the keys, points D1 to D14 (printed).
  -Phase B   the single temperature reading (PM, J-125; replaces the 10-minute settled pair), run by
             the Arbiter: -R1 -R1Utc -R1Status -R1Serial (exactly as read, all taken as TEXT, never
             rounded: -R1 three digits, tenths of deg C; -R1Utc the PC's UTC at the reading, ISO 8601
             ending in Z; -R1Status the one-digit status code of dumpsys battery; -R1Serial the serial of
             the unit read; optional -R1Charge, the level in percent). The rule: the reading three
             digits from 100 to 349 (10.0 to 34.9 deg C; 350 = 35.0 deg C and above fail; "36.2", "0"
             or "35" are malformed); the battery not charging (status 3 discharging, 4 not charging or
             5 full; 2 charging, 1 unknown or anything else fail); the unit one of the two Quest 3 units
             (review MAJOR-2: the reading is tied to a unit; fs-observe3c.ps1 compares it with -Serial);
             the reading not in the future (at most 60 s ahead of this PC's clock: a typing error) and
             at most 900 s old now, compared exactly (BA follows phase B, so an older reading could
             never be within 900 s of BA). Needs phase A passed. No question.
  -Phase E   immediately before the attempt: presence and the power button, both y. Needs phases A
             and B passed. fs-observe3c.ps1 refuses the attempt unless the LAST entry of each of A, B
             and E passed, E is at most 300 s old, every entry was written by the pinned copy of this
             file, the reading of phase B passed its rule, is before BA and at most 900 s before it, and
             E began after BF.
A key other than y or n is ignored; n, a timeout (-TimeoutSec; default 900 s per question in phase A,
300 s in phase E) or a failed check prints STOPPED and exits 1. Ctrl+C ends the run; the entry is then
written as STOP (interrupted), with the unanswered question marked "interrupted".
Console lines are wrapped at 90 characters (a path longer than that stays on one line); the files
record every text unwrapped.

Usage (from the repository root, in powershell.exe):
  fs-checklist3c.ps1 -Phase A -Cycle <cycle> -Image <img>\boot-stage3c.img [-RehearsalDir <cycle>\rehearsal-2]
  fs-checklist3c.ps1 -Phase B -Cycle <cycle> -R1 <t> -R1Utc <utc> -R1Status <dumpsys status> -R1Serial <serial> [-R1Charge <%>]
  fs-checklist3c.ps1 -Phase E -Cycle <cycle>
Exit: 0 phase passed; 1 STOP; 64 usage; 70 internal error.
The file is ASCII (Windows PowerShell 5.1 reads it the same without a byte-order mark).
#>
param(
    [string]$Phase = '',
    [string]$Cycle = '',
    [string]$Image = '',
    [string]$RehearsalDir = '',
    [string]$R1 = '',                  # review MAJOR-1: text, never [int] (an [int] parameter rounds "36.2" to 36)
    [string]$R1Utc = '',
    [string]$R1Status = '',            # review MAJOR-1: text (an [int] parameter rounds "2.6" to 3)
    [string]$R1Charge = '',
    [string]$R1Serial = '',            # review MAJOR-2: the unit the reading was taken on
    [int]$TimeoutSec = 0
)
Set-StrictMode -Version 2.0
$script:FsCl3Invocation = $MyInvocation.InvocationName
$script:FsCl3Self = Join-Path $PSScriptRoot 'fs-checklist3c.ps1'
$script:FsCl3Schema = 'frameshift.fs-checklist3c.v3'      # v2 (J-125): one Reading, not a Pair; v3 (review MAJOR-1/2): the Reading as text, with the unit's serial
$script:FsCl3PresenceMaxSec = 300      # enforced by fs-observe3c.ps1 (Test-FsObsChecklist)
$script:FsCl3TimeoutA = 900            # per question in phase A (reading D1-D14 takes time)
$script:FsCl3TimeoutE = 300            # per question in phase E
# The reading's time is the PC's UTC at the moment of the reading (WALKTHROUGH step 6 prints it with the
# dumpsys output), so it should never be ahead of this clock; the 60 s slack only absorbs a typing or
# copying delay. Anything later is a typing error or a reading not yet taken. fs-observe3c.ps1
# additionally requires it to be before BA started.
$script:FsCl3FutureSlackSec = 60
# Single temperature reading (PM, J-125): below 350 (35.0 deg C), the battery not charging, at most 900 s
# before BA (fs-observe3c.ps1 enforces the BA tie; phase B already refuses a reading older than that now).
$script:FsCl3TempLimit = 350
$script:FsCl3TempMin = 100            # review MAJOR-1: three digits, 100..349 (10.0 to 34.9 deg C); below 100 is a typing error
$script:FsCl3ReadingMaxAgeSec = 900
# review MAJOR-2: the reading is tied to a unit. The two Quest 3 units (both on v2.7, J-131/J-133).
$script:FsCl3Units = [ordered]@{ 'QUEST3UNIT1' = 'Unit 1'; 'QUEST3UNIT2' = 'Unit 2' }
# dumpsys battery status codes (android.os.BatteryManager BATTERY_STATUS_*); 3, 4 and 5 count as not charging
$script:FsCl3StatusName = @{ 1 = 'unknown'; 2 = 'charging'; 3 = 'discharging'; 4 = 'not charging'; 5 = 'full' }
$script:FsCl3StatusOk = @('3', '4', '5')     # compared as text: exactly one of these digits (review MAJOR-1)
$script:FsCl3Wrap = 90

# ------------------------------------------------------------ the texts -----
# Printed by the console and recorded verbatim; SIGNOFF-3c.md carries the same lines (test-host3c CL13).
$script:FsCl3Q = [ordered]@{
    A1 = 'Have you opened and looked at the six preview pictures listed above? (y/n)'
    A2 = 'Do you know which key to press for each thing you might see (list above)? (y/n)'
    A3 = 'I have read points D1 to D14 above and I accept them (y/n)'
    E1 = 'Are you physically at the headset now? (y/n)'
    E2 = 'Can you reach the headset''s power button now, and do you know when to use it (RECOVERY.md)? (y/n)'
}
$script:FsCl3PreviewDir = 'devices\quest3\stage3c\fixtures\preview'
# the six pictures, in the order printed, each with what it shows
$script:FsCl3Previews = [ordered]@{
    'pattern-v0.6-3f9c07ab-viewer-1032x552.png'   = 'The test pattern as one eye should see it: the bar groups and the F letters.'
    'pattern-v0.6-3f9c07ab-mixermap-1032x552.png' = 'Which part of the screen each bar group belongs to, and how many bars it has.'
    'pattern-v0.6-3f9c07ab-scanout-4128x2208.png' = 'The whole picture sent to the screen (both eyes side by side).'
    'pattern-v0.6-3f9c07ab-digits-left.png'       = 'The 8 characters to read.'
    'F-reference-u-i-m-v.png'                     = 'How an F can look: upright u, half-turn i, mirrored m, flipped top to bottom v.'
    'solid-red-v0.6-viewer-1032x552.png'          = 'The plain red field of run 3.'
}
$script:FsCl3PreviewFiles = @($script:FsCl3Previews.Keys)
$script:FsCl3Text = [ordered]@{
    PreviewsHead = 'Open each of these six pictures (paste the path into File Explorer) and look at it:'
    PreviewsTail = 'Through the lenses the pattern will look turned by about 21 degrees and shifted toward the nose; that is expected.'
    KeyLines = @(
        'Per eye (runs 1, 2): a = light, no pattern; b = dark; c = garbled; d = I can read the characters, then the 8 characters (Backspace corrects; Enter needs all 8; Esc goes back to the a/b/c/d choice); x = abort, on every question (Ctrl+C is the same as x).',
        'n (light still visible) is a key of the dark check only (y dark / n light visible / x). At the eye questions it does nothing, so light seen there means x. n pressed while a run is showing is taken as x.',
        'After run 2, only when run 3 does not follow (an eye read the characters, an eye gave the wrong characters, or the run did not commit cleanly): the bar counts, i.e. next to each of the two F letters (below it when upright) a row of 1 to 4 bars: how many at the LEFT F, then at the RIGHT F (two keys 0-4, 0 = none visible; Backspace corrects; no Enter); after d also the F u/i/m/v/0 and the line l/r/0. On the run-3 path no bar question is asked (Q7 fallback).',
        'Run 3: r = all red; p = partly red; u = one other colour; s = same as run 2; g = different garble; b = dark.',
        'Every answer is echoed on the console; a key pressed twice quickly counts once at the next question. 30 s per prompt; a timeout or x ends the session safely (after an x during a run I am still asked whether the panels are dark).',
        'I tap keys, never hold them, and wait for each answer''s echo before the next (a held key can auto-repeat). I do not click into the console window (QuickEdit is switched off for the session anyway).')
    Accept = @(
        'D1. Before run 1 the headset sets the screen brightness once, to level 127, which should give about 4.1 % of full backlight. That figure comes from reading the driver code; nobody has measured the light. The level is read back before each run.',
        'D2. The screen may light up to three times: run 1 for 3 s (a wake-up step, expected to stay dark); run 2 for 10 s (the new screen layout; if the driver refuses it, nothing lights in run 2); and run 3 for 5 s, only if I report run 2 as garbled or as light without a pattern (a plain red field, about as bright as the pattern on average and not brighter; an estimate, not a measurement). At most 18 s of light in total.',
        'D3. Run 1 repeats last time''s screen setting on purpose, as the wake-up step; last time it stayed dark. If it lights this time, I may see garbled stripes for 3 s at the same low brightness. Runs 2 and 3 never show that old setting (they may only test it without showing it); they can show only the new four-part layout.',
        'D4. Runs 2 and 3 use a new four-part screen layout, its parts stacked in the same order as normal Android (my decision J-109), set in the same single reviewed step. No hidden driver debug files are opened (J-109). Nothing else new is written.',
        'D5. The screen is deliberately switched off and on again up to two times; this has never been tried on our test boot. The headset itself waits at least 2 s before each. The fan may stop and start each time.',
        'D6. The headset itself times each lit period. Pressing x cannot shorten a period that is already running; it ends the session after it. I may look away at any time.',
        'D7. The pattern will look turned by about 21 degrees, perhaps differently in each eye, and shifted toward the nose and upward. That is expected and is not corrected in this test.',
        'D8. If the screen does not go dark when a run ends, the last picture may stay until the end command (fs-done; my n at the dark check sends it at once), the idle limit (120 s after the last activity) or the deadline (about 200 s after the test program on the headset starts, with a last safety stop 1 s later). These are not guaranteed screen-off times; switching off by hand (RECOVERY.md) always remains.',
        'D9. Questions appear only after a run has ended and the headset''s report of it has arrived. I answer from what I saw. The console shows none of the headset''s own results until all my answers are in. The headset''s results and what I saw are reported separately. What run 3 suggests, and the names given to the layouts, help explain the result; they are not a pass.',
        'D10. If a run''s report does not arrive, or the console shows a red NO RECORD / SHELL STATE UNKNOWN / NO fs-done banner with the ALARM sound, nothing more is sent: I look away and wait; the headset recovers by itself at the idle limit or the deadline.',
        'D11. Console window closed, or the collector stopped: I look away; the headset recovers by itself within 120 s without activity (the idle limit) or at the deadline (about 200 s after the test program starts). Every answer given so far is already saved (readings3c.txt).',
        'D12. If the console shows RUN 1 NOT POSSIBLE (integrity): the pattern program on the headset is not the reviewed one; nothing lights, and the end command (fs-done) follows.',
        'D13. No number is claimed for eye safety; "no light seen" does not mean that no light was emitted.',
        'D14. Time limit: fs-observe3c.ps1 refuses to start the test boot if more than 300 s (5 minutes) have passed since BA started (checked before the attempt is recorded; always on in stage 3c). Then nothing is started, the image''s one-time code (nonce) stays unused, a record of the abandoned cycle is written (build\stage3c\abandoned\), and I go back to Android for a new temperature reading and a new BA/BF.')
    Presence = @(
        'I am present, headset in hand, power button reachable, keyboard under one hand; the collector runs in powershell.exe (a console window, not ISE) with sound on, on the PC speakers and at the volume of the sound check.',
        'If anything is unexpected: x (at the dark check, n), look away and wait; the headset recovers by itself (the end command fs-done, the idle limit of 120 s, or the deadline about 200 s after the test program starts). Switch off by hand (power button) only as RECOVERY.md says.',
        'Next: paste the attempt command at once. fs-observe3c.ps1 refuses the attempt if this presence check is more than 300 s old, or if more than 300 s have passed since BA started.')
    After = @(
        'After the session: AF immediately on return to fastboot (fs-capture.ps1 -Phase AF -Serial <serial>), then fastboot -s <serial> reboot, then AA promptly in Android.',
        'AA10 temperature at 400 (40.0 deg C) or more: shut down at once (procedure as 3b F), do not wait for anything else. Even below 400, follow-up readings at +5 min and +10 min, then every 5 min while it rises and stays below 400; the highest observed reading is recorded. Shutdown and unplug are recorded as two separate observations.')
}

# ------------------------------------------------------------ helpers -------
function Get-FsCl3Sha([string]$Path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { $null } }
# SHA-256 of lines joined with LF, UTF-8 (the record of a printed block)
function Get-FsCl3TextSha([string[]]$Lines) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}
# PART-1 review MINOR-1: ASCII digits only ([0-9]; \d also matches other scripts' digits) and the exact format,
# parsed with ParseExact (invariant culture) inside a try: T24:00:00Z, :60Z, a 31 February or any other failure is
# $null (refused), never an exception and never a lenient Parse (which reads T24:00:00 as the next midnight).
$script:FsCl3UtcFormats = [string[]](@("yyyy-MM-dd'T'HH:mm:ss'Z'") + @(1..7 | ForEach-Object { "yyyy-MM-dd'T'HH:mm:ss." + ('f' * $_) + "'Z'" }))
function ConvertFrom-FsCl3Utc([string]$s) {
    if ($null -eq $s -or $s -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?Z\z') { return $null }
    try { [DateTime]::ParseExact($s, $script:FsCl3UtcFormats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') }
    catch { $null }
}
function Format-FsCl3Utc([DateTime]$t) { $t.ToUniversalTime().ToString('o') }
# Wraps one console line at $Width characters, at spaces; a word longer than the width (a path) stays whole.
# Continuation lines are indented under the text after a list marker ("D1. ", "1. ", "- ") or by two spaces.
function Format-FsCl3Wrap([string]$Line, [int]$Width = 90) {
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
function Format-FsCl3Prompt([int]$TimeoutSec) {
    $d = if ($TimeoutSec -ge 60 -and $TimeoutSec % 60 -eq 0) { $m = $TimeoutSec / 60; "$m minute$(if ($m -ne 1) { 's' })" } else { "$TimeoutSec second$(if ($TimeoutSec -ne 1) { 's' })" }
    "Press y for yes or n for no ($d)."
}
# The preview block: the head line, each picture's absolute path and what it shows, the tail line.
function Get-FsCl3PreviewLines([string]$Root) {
    $l = @($script:FsCl3Text.PreviewsHead); $i = 0
    foreach ($f in $script:FsCl3Previews.Keys) { $i++; $l += "$i. $($Root.TrimEnd('\'))\$($script:FsCl3PreviewDir)\$f"; $l += "   $($script:FsCl3Previews[$f])" }
    $l + @($script:FsCl3Text.PreviewsTail)
}

# The SIGNOFF-3c host-pin table: rows between "<!-- host pins" and "<!-- end host pins -->".
function Read-FsCl3PinTable([string]$SignoffFile) {
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
function Test-FsCl3HostPins {
    param([string]$HashesFile, [string]$SignoffFile, [string]$Root)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w } }
    $rows = Read-FsCl3PinTable $SignoffFile
    if ($null -eq $rows -or $rows.Count -eq 0) { return (& $no "no host-pin table in $SignoffFile") }
    if (-not (Test-Path -LiteralPath $HashesFile -PathType Leaf)) { return (& $no "missing: $HashesFile (run the Get-FileHash command of SIGNOFF-3c A first)") }
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
        $now = Get-FsCl3Sha $full
        if ($now -cne $r.Sha) { $bad += "$($r.Rel): working file $now != pin $($r.Sha)" }
    }
    if ($bad.Count) { return (& $no ("host pins differ (run the Get-FileHash command of WALKTHROUGH step 1 again if the files changed): " + ($bad -join '; '))) }
    [pscustomobject]@{ Ok = $true; Why = "$($rows.Count) files: host-hashes.txt and the working files equal the SIGNOFF-3c pins" }
}
function Test-FsCl3SoundCheck([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Why = "missing: $Path (run fs-session3c.ps1 -SoundCheck -SoundCheckDir <cycle>)" } }
    try { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Why = "unreadable: $Path" } }
    $sch = if ($j.PSObject.Properties['Schema']) { [string]$j.Schema } else { '' }
    $pass = ($j.PSObject.Properties['Pass'] -and $j.Pass -is [bool] -and $j.Pass)
    if ($sch -cne 'frameshift.fs-soundcheck3c.v1' -or -not $pass) { return [pscustomobject]@{ Ok = $false; Why = "soundcheck.json is not a passed sound check (Schema '$sch', Pass $(if ($j.PSObject.Properties['Pass']) { $j.Pass } else { '-' }))" } }
    $end = if ($j.PSObject.Properties['EndUtc']) { [string]$j.EndUtc } else { '?' }
    [pscustomobject]@{ Ok = $true; Why = "SOUND CHECK PASSED (soundcheck.json Pass true, ended $end)" }
}
function Test-FsCl3Rehearsal([string]$Dir) {
    $p = Join-Path $Dir 'summary.txt'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Why = "missing: $p (the rehearsal of SIGNOFF-3c A, answered on the garbled path, then s)" } }
    $t = [IO.File]::ReadAllText($p)
    $go = [regex]::Match($t, '(?m)^REHEARSAL: run-1 plus run-2 answers [0-9]+\.[0-9] s; go/no-go \(SIGNOFF-3c A, Q7\): GO \(<= 40 s\)\r?$')
    if (-not $go.Success) { return [pscustomobject]@{ Ok = $false; Why = "no GO line in $p (go/no-go must be GO (<= 40 s))" } }
    if ($t -notmatch 'not asked \(Q7 fallback\)') { return [pscustomobject]@{ Ok = $false; Why = "$p does not show the Q7 fallback (bars not asked on the run-3 path): not a rehearsal of the garbled path with the pinned files" } }
    [pscustomobject]@{ Ok = $true; Why = $go.Value.TrimEnd("`r") }
}
function Test-FsCl3Previews([string]$Root) {
    $miss = @($script:FsCl3PreviewFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path $Root $script:FsCl3PreviewDir) $_) -PathType Leaf) })
    if ($miss.Count) { return [pscustomobject]@{ Ok = $false; Why = "preview files missing: $($miss -join ', ')" } }
    [pscustomobject]@{ Ok = $true; Why = "$($script:FsCl3PreviewFiles.Count) preview files present in $($script:FsCl3PreviewDir)" }
}
# The observer's own -Preflight (no device action), run as the PM would run it.
$script:FsCl3RealPreflight = {
    param([string]$ImagePath)
    $obs = Join-Path (Split-Path -Parent $script:FsCl3Self) 'fs-observe3c.ps1'
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $obs -Image $ImagePath -Preflight | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    $im = @($out | Where-Object { $_ -cmatch '^image OK: stage 3c nonce ([0-9a-f]{16}) sha256 ([0-9a-f]{64})\z' })
    $ok = ($code -eq 0 -and $im.Count -eq 1 -and @($out | Where-Object { $_ -cmatch '^preflight OK' }).Count -eq 1)
    $n = $null; $s = $null
    if ($im.Count -eq 1 -and $im[0] -cmatch '^image OK: stage 3c nonce ([0-9a-f]{16}) sha256 ([0-9a-f]{64})\z') { $n = $Matches[1]; $s = $Matches[2] }
    [pscustomobject]@{ Ok = $ok; Why = ("exit $code; " + $(if ($out.Count) { $out[-1] } else { '(no output)' })); Nonce = $n; ImageSha = $s }
}
# Console y/n with a timeout; buffered keys are discarded before the question. Returns y, n, timeout or noconsole.
$script:FsCl3ConsoleAsk = {
    param([string]$Text, [int]$TimeoutSec)
    try { while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) } } catch { return 'noconsole' }
    Write-Host ''
    foreach ($w in (Format-FsCl3Wrap "QUESTION: $Text" $script:FsCl3Wrap)) { Write-Host $w -ForegroundColor Yellow }
    Write-Host (Format-FsCl3Prompt $TimeoutSec) -ForegroundColor Yellow
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

# checklist3c.json: { Schema; Entries: [ ... ] }. Returns @{ Ok; Why; Entries }.
function Read-FsCl3File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Ok = $true; Why = 'new'; Entries = @() } }
    try { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Why = "unreadable checklist file $Path (not overwritten)"; Entries = @() } }
    if ($null -eq $j -or -not $j.PSObject.Properties['Schema'] -or [string]$j.Schema -cne $script:FsCl3Schema -or -not $j.PSObject.Properties['Entries']) {
        return [pscustomobject]@{ Ok = $false; Why = "$Path is not a $($script:FsCl3Schema) file (not overwritten)"; Entries = @() }
    }
    [pscustomobject]@{ Ok = $true; Why = 'read'; Entries = @($j.Entries) }
}
# the LAST entry of a phase, as a result string (PASS, STOP, or '' when the phase never ran)
function Get-FsCl3LastResult([object[]]$Entries, [string]$Ph) {
    $l = ''
    foreach ($e in $Entries) { if ($null -ne $e -and $e.PSObject.Properties['Phase'] -and [string]$e.Phase -ceq $Ph) { $l = if ($e.PSObject.Properties['Result']) { [string]$e.Result } else { '?' } } }
    $l
}
function Add-FsCl3Check($E, [string]$Name, [bool]$Ok, [string]$Detail, [scriptblock]$Say) {
    $E.Checks += [ordered]@{ Name = $Name; Ok = $Ok; Detail = $Detail }
    & $Say ("  check {0}: {1} - {2}" -f $Name, $(if ($Ok) { 'OK' } else { 'FAILED' }), $Detail)
}
# The question is recorded BEFORE it is asked (answer "interrupted"), so a Ctrl+C leaves it in the STOP entry.
function Invoke-FsCl3Question($E, [string]$Key, [scriptblock]$Ask, [scriptblock]$NowUtc, [int]$TimeoutSec) {
    $text = $script:FsCl3Q[$Key]
    $q = [ordered]@{ Id = $Key; Text = $text; Answer = 'interrupted'; AskedUtc = (Format-FsCl3Utc (& $NowUtc)); AnsweredUtc = $null; TimeoutSec = $TimeoutSec }
    $E.Questions += $q
    $a = [string](& $Ask $text $TimeoutSec)
    if (@('y', 'n', 'timeout', 'noconsole') -cnotcontains $a) { $a = 'invalid' }
    $q.Answer = $a; $q.AnsweredUtc = Format-FsCl3Utc (& $NowUtc)
    $a
}
# Prints a block (title, then each item) and records its title, line count and SHA-256 (title line and items, unwrapped, LF, UTF-8).
function Write-FsCl3Block($E, [string]$Title, [string[]]$Lines, [scriptblock]$Say) {
    & $Say ''; & $Say "== $Title"; foreach ($l in $Lines) { & $Say "  $l" }
    $E.Blocks += [ordered]@{ Title = $Title; Lines = @($Lines).Count; Sha256 = (Get-FsCl3TextSha (@("== $Title") + @($Lines))) }
}

function Save-FsCl3Entry([string]$Cycle, [object[]]$Prev, $E) {
    $jp = Join-Path $Cycle 'checklist3c.json'; $tp = Join-Path $Cycle 'checklist3c.txt'
    $all = @($Prev) + @([pscustomobject]$E)
    $doc = [ordered]@{ Schema = $script:FsCl3Schema; Note = 'stage-3c console checklist (J-118; single temperature reading J-125, typed text with the unit, review MAJOR-1/2): one entry per run of fs-checklist3c.ps1; fs-observe3c.ps1 needs the last A, B and E entries PASS and E at most 300 s old'; Entries = $all }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($jp, (($doc | ConvertTo-Json -Depth 8) -replace "`r`n", "`n") + "`n", $enc)
    $t = New-Object System.Collections.Generic.List[string]
    $t.Add("== phase $($E.Phase): $($E.Result)  start $($E.StartUtc)  end $($E.EndUtc)  tool sha256 $($E.ToolSha256)")
    foreach ($c in @($E.Checks)) { $t.Add("   check $($c.Name): $(if ($c.Ok) { 'OK' } else { 'FAILED' }) - $($c.Detail)") }
    if ($E.Contains('Reading') -and $null -ne $E.Reading) { $p = $E.Reading; $t.Add("   reading: $($p.R1) at $($p.R1Utc) (battery status $($p.R1Status) $($p.R1StatusName); charge $(if ($p.R1Charge) { $p.R1Charge } else { '-' }); unit $($p.R1Serial) $(if ($p.R1Unit) { $p.R1Unit } else { '(unknown)' })); $($p.AgeSec) s old at phase B; ok $($p.Ok)") }
    foreach ($b in @($E.Blocks)) { $t.Add("   printed `"$($b.Title)`" ($($b.Lines) lines) sha256 $($b.Sha256)") }
    foreach ($q in @($E.Questions)) { $t.Add("   asked $($q.AskedUtc)  `"$($q.Text)`"  answer $($q.Answer) at $($q.AnsweredUtc)") }
    $t.Add("   $($E.Result): $($E.Why)")
    [IO.File]::AppendAllText($tp, (($t -join "`n") + "`n"), $enc)
    $jp
}

# One phase. $Opt: Root, SignoffFile, Image, RehearsalDir, Preflight (scriptblock), R1, R1Utc, R1Status,
# R1Charge, R1Serial (the reading's values as text), TimeoutSec (0 or absent: 900 s in phase A, 300 s in phase E).
# $Ask { param($Text, $TimeoutSec) -> y|n|timeout|noconsole }; $NowUtc { -> [DateTime] UTC };
# $Say { param($Line) } receives the console lines already wrapped at 90 characters.
# Returns @{ Exit; Why; Entry; JsonPath }.
function Invoke-FsCl3Phase {
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string]$Cycle, [hashtable]$Opt = @{},
          [Parameter(Mandatory)][scriptblock]$Ask, [Parameter(Mandatory)][scriptblock]$NowUtc, [Parameter(Mandatory)][scriptblock]$Say)
    $fsCl3OuterSay = $Say
    $Say = { param([string]$Line) foreach ($w in (Format-FsCl3Wrap $Line $script:FsCl3Wrap)) { & $fsCl3OuterSay $w } }
    $stopLine = { param($w) "STOPPED. Nothing was sent to the headset. Tell the Arbiter: $w" }
    $res = [pscustomobject]@{ Exit = 1; Why = ''; Entry = $null; JsonPath = $null }
    $to = if ($Opt.ContainsKey('TimeoutSec') -and [int]$Opt.TimeoutSec -gt 0) { [int]$Opt.TimeoutSec } elseif ($Phase -ceq 'A') { $script:FsCl3TimeoutA } else { $script:FsCl3TimeoutE }
    if (@('A', 'B', 'E') -cnotcontains $Phase) { $res.Why = "unknown phase '$Phase' (A, B or E)"; & $Say (& $stopLine $res.Why); return $res }
    if (-not (Test-Path -LiteralPath $Cycle -PathType Container)) { $res.Why = "cycle directory $Cycle does not exist"; & $Say (& $stopLine $res.Why); return $res }
    $prev = Read-FsCl3File (Join-Path $Cycle 'checklist3c.json')
    if (-not $prev.Ok) { $res.Why = $prev.Why; & $Say (& $stopLine $res.Why); return $res }
    $e = [ordered]@{ Phase = $Phase; Result = 'STOP'; Why = 'interrupted before the phase ended (Ctrl+C or an error)'; StartUtc = (Format-FsCl3Utc (& $NowUtc)); EndUtc = $null
                     Tool = 'fs-checklist3c.ps1'; ToolSha256 = (Get-FsCl3Sha $script:FsCl3Self); Cycle = $Cycle; Checks = @(); Blocks = @(); Questions = @() }
    & $Say "== STAGE 3C CONSOLE CHECKLIST, PHASE $Phase (nothing here touches the headset)"
    $stop = { param($w) $e.Why = $w }
    # the phase body: a scriptblock, so that each `return` ends the phase (the entry is saved in finally, also on Ctrl+C)
    $body = {
        if ($Phase -ceq 'A') {
            $root = [string]$Opt.Root
            $hp = Test-FsCl3HostPins -HashesFile (Join-Path $Cycle 'host-hashes.txt') -SignoffFile ([string]$Opt.SignoffFile) -Root $root
            Add-FsCl3Check $e 'host-pins' $hp.Ok $hp.Why $Say
            if (-not $hp.Ok) { & $stop 'the host pins do not match (checked first; nothing else is run): stop, nothing is booted'; return }
            $img = [string]$Opt.Image
            if (-not $img) { $pf = [pscustomobject]@{ Ok = $false; Why = 'no -Image given'; Nonce = $null; ImageSha = $null } } else { $pf = & $Opt.Preflight $img }
            Add-FsCl3Check $e 'preflight' ([bool]$pf.Ok) ("fs-observe3c.ps1 -Preflight: $($pf.Why)") $Say
            $e.Image = $img; $e.Nonce = $pf.Nonce; $e.ImageSha256 = $pf.ImageSha
            $sc = Test-FsCl3SoundCheck (Join-Path $Cycle 'soundcheck.json'); Add-FsCl3Check $e 'soundcheck' $sc.Ok $sc.Why $Say
            $rd = if ($Opt.ContainsKey('RehearsalDir') -and $Opt.RehearsalDir) { [string]$Opt.RehearsalDir } else { Join-Path $Cycle 'rehearsal-2' }
            $rh = Test-FsCl3Rehearsal $rd; Add-FsCl3Check $e 'rehearsal' $rh.Ok $rh.Why $Say
            $pv = Test-FsCl3Previews $root; Add-FsCl3Check $e 'previews' $pv.Ok $pv.Why $Say
            $failed = @($e.Checks | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name })
            if ($failed.Count) { & $stop "automatic check failed: $($failed -join ', '); nothing is asked; nothing is booted"; return }
            Write-FsCl3Block $e 'THE SIX PREVIEW PICTURES' (Get-FsCl3PreviewLines $root) $Say
            $a = Invoke-FsCl3Question $e 'A1' $Ask $NowUtc $to; if ($a -cne 'y') { & $stop "answer '$a' to: $($script:FsCl3Q.A1)"; return }
            Write-FsCl3Block $e 'THE KEYS (what to press for what you see)' $script:FsCl3Text.KeyLines $Say
            $a = Invoke-FsCl3Question $e 'A2' $Ask $NowUtc $to; if ($a -cne 'y') { & $stop "answer '$a' to: $($script:FsCl3Q.A2)"; return }
            Write-FsCl3Block $e 'WHAT I ACCEPT (points D1 to D14)' $script:FsCl3Text.Accept $Say
            $a = Invoke-FsCl3Question $e 'A3' $Ask $NowUtc $to; if ($a -cne 'y') { & $stop "answer '$a' to: $($script:FsCl3Q.A3)"; return }
            $e.Result = 'PASS'; $e.Why = "automatic checks OK (nonce $($e.Nonce)); previews, keys and points D1 to D14 confirmed"
        } elseif ($Phase -ceq 'B') {
            $la = Get-FsCl3LastResult $prev.Entries 'A'
            if ($la -cne 'PASS') { & $stop 'phase A has not passed in this cycle (run -Phase A first)'; return }
            # review MAJOR-1: every value is the text that was typed, checked as text; nothing is converted before the
            # check (an [int] parameter or cast rounds "36.2" to 36 and "2.6" to 3) and nothing is rounded
            $v = { param($k) if ($Opt.ContainsKey($k) -and $null -ne $Opt[$k]) { [string]$Opt[$k] } else { '' } }
            $r1s = & $v 'R1'; $uts = & $v 'R1Utc'; $sts = & $v 'R1Status'; $chs = & $v 'R1Charge'; $ser = & $v 'R1Serial'
            $t1 = ConvertFrom-FsCl3Utc $uts
            $inOk = ($r1s -cmatch '^[0-9]{3}\z' -and $null -ne $t1 -and $sts -cmatch '^[1-5]\z' -and $ser -cmatch '^[A-Za-z0-9]{6,32}\z' -and ($chs -ceq '' -or $chs -cmatch '^(100|[1-9]?[0-9])\z'))
            Add-FsCl3Check $e 'reading-input' $inOk ("reading '$r1s' at '$uts', battery status '$sts', unit '$ser'$(if ($chs) { ", charge '$chs'" }) (the reading: three digits, tenths of deg C; the PC's UTC yyyy-MM-ddTHH:mm:ss[.f]Z; the dumpsys battery status: one digit 1-5; the unit's serial; the charge 0-100 if given)") $Say
            if (-not $inOk) { & $stop 'the temperature reading is incomplete or malformed (-R1 three digits, -R1Utc the PC UTC, -R1Status one digit, -R1Serial): type the values exactly as read'; return }
            $r1 = [int]$r1s; $sn = $script:FsCl3StatusName[[int]$sts]
            $unit = if (@($script:FsCl3Units.Keys) -ccontains $ser) {   # case-sensitive (an [ordered] dictionary's Contains is not)
                [string]$script:FsCl3Units[$ser] } else { '' }
            # the age is compared exactly (review MINOR: no 0.1 s rounding before the comparison); AgeSec is for display only
            $now = (& $NowUtc).ToUniversalTime(); $ageTicks = ($now - $t1).Ticks; $age = [Math]::Round($ageTicks / 10000000.0, 1)
            $inRange = ($r1 -ge $script:FsCl3TempMin -and $r1 -lt $script:FsCl3TempLimit); $notChg = ($script:FsCl3StatusOk -ccontains $sts); $known = [bool]$unit
            $past = ($t1 -le $now.AddSeconds($script:FsCl3FutureSlackSec)); $fresh = ($ageTicks -le [TimeSpan]::FromSeconds($script:FsCl3ReadingMaxAgeSec).Ticks)
            Add-FsCl3Check $e 'range-100-349' $inRange "reading $r1s (must be 100 to 349: 10.0 to 34.9 deg C; 350 = 35.0 deg C and above fail)" $Say
            Add-FsCl3Check $e 'not-charging' $notChg "battery status $sts ($sn) (must be 3 discharging, 4 not charging or 5 full; 2 charging and 1 unknown fail)" $Say
            Add-FsCl3Check $e 'known-unit' $known "unit $ser $(if ($unit) { "($unit)" } else { '(not one of the two Quest 3 units)' }) (Unit 1 QUEST3UNIT1, Unit 2 QUEST3UNIT2; fs-observe3c.ps1 requires it to equal the attempt's -Serial)" $Say
            Add-FsCl3Check $e 'not-in-future' $past "reading at $(Format-FsCl3Utc $t1) (the PC's UTC at the reading), now $(Format-FsCl3Utc $now) (at most $($script:FsCl3FutureSlackSec) s ahead: a typing delay)" $Say
            Add-FsCl3Check $e 'at-most-15-min-old' $fresh "the reading is $age s old now (at most $($script:FsCl3ReadingMaxAgeSec) s, compared exactly; it must also be at most $($script:FsCl3ReadingMaxAgeSec) s before BA, which fs-observe3c.ps1 checks)" $Say
            $ok = ($inRange -and $notChg -and $known -and $past -and $fresh)
            $e.Reading = [ordered]@{ R1 = $r1s; R1Utc = (Format-FsCl3Utc $t1); R1Status = $sts; R1StatusName = $sn; R1Charge = $chs; R1Serial = $ser; R1Unit = $unit; AgeSec = $age
                                     Rule = "three digits from $($script:FsCl3TempMin) to $($script:FsCl3TempLimit - 1) (35.0 deg C and above fail); battery not charging (dumpsys status 3, 4 or 5); a Quest 3 unit, equal to the attempt's -Serial (fs-observe3c.ps1); the PC's UTC, not in the future (at most $($script:FsCl3FutureSlackSec) s ahead); at most $($script:FsCl3ReadingMaxAgeSec) s old now and at most $($script:FsCl3ReadingMaxAgeSec) s before BA (fs-observe3c.ps1), compared exactly"; Ok = $ok }
            if (-not $ok) { & $stop 'the temperature reading does not meet the rule: wait (and unplug the charger if the battery is charging), then take a new reading'; return }
            $e.Result = 'PASS'; $e.Why = "temperature reading $r1s at $(Format-FsCl3Utc $t1), battery $sn, $unit ($ser): within the rule; BA must start within $($script:FsCl3ReadingMaxAgeSec) s of the reading"
        } else {
            if ((Get-FsCl3LastResult $prev.Entries 'A') -cne 'PASS') { & $stop 'phase A has not passed in this cycle'; return }
            if ((Get-FsCl3LastResult $prev.Entries 'B') -cne 'PASS') { & $stop 'phase B (the temperature reading) has not passed in this cycle'; return }
            Write-FsCl3Block $e 'PRESENCE (immediately before the attempt)' $script:FsCl3Text.Presence $Say
            Write-FsCl3Block $e 'AFTER THE SESSION' $script:FsCl3Text.After $Say
            $a = Invoke-FsCl3Question $e 'E1' $Ask $NowUtc $to; if ($a -cne 'y') { & $stop "answer '$a' to: $($script:FsCl3Q.E1)"; return }
            $a = Invoke-FsCl3Question $e 'E2' $Ask $NowUtc $to; if ($a -cne 'y') { & $stop "answer '$a' to: $($script:FsCl3Q.E2)"; return }
            $e.Result = 'PASS'; $e.Why = "presence confirmed at $(@($e.Questions)[-1].AnsweredUtc); the attempt must start within $($script:FsCl3PresenceMaxSec) s"
        }
    }
    try { $null = & $body }
    finally {
        $e.EndUtc = Format-FsCl3Utc (& $NowUtc)
        $res.Entry = [pscustomobject]$e; $res.Why = $e.Why
        $res.JsonPath = Save-FsCl3Entry $Cycle $prev.Entries $e
        & $Say ''; & $Say "recorded: $($res.JsonPath)"
        if ($e.Result -ceq 'PASS') { $res.Exit = 0; & $Say "PHASE $Phase PASSED: $($e.Why)" }
        else { & $Say (& $stopLine "phase $Phase - $($e.Why)") }
    }
    $res
}

if ($script:FsCl3Invocation -eq '.') { return }
# ------------------------------------------------------------------ CLI -----
$exit = 70
try {
    if (@('A', 'B', 'E') -cnotcontains $Phase -or -not $Cycle) {
        Write-Output 'usage: fs-checklist3c.ps1 -Phase A|B|E -Cycle <cycle dir> [-Image <img>\boot-stage3c.img] [-R1 <t> -R1Utc <utc> -R1Status <status> -R1Serial <serial> [-R1Charge <%>]]   (no device action)'; exit 64
    }
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path          # FIXED: the repository of this file
    $cyc = if (Test-Path -LiteralPath $Cycle -PathType Container) { (Resolve-Path -LiteralPath $Cycle).Path } else { $Cycle }
    $opt = @{ Root = $root; SignoffFile = (Join-Path $root 'devices\quest3\SIGNOFF-3c.md'); Image = $Image; RehearsalDir = $RehearsalDir; Preflight = $script:FsCl3RealPreflight; TimeoutSec = $TimeoutSec }
    # review MAJOR-1: the reading's values are passed on as the typed text (string parameters; checked by phase B)
    foreach ($k in 'R1', 'R1Utc', 'R1Status', 'R1Charge', 'R1Serial') { if ($PSBoundParameters.ContainsKey($k)) { $opt[$k] = [string]$PSBoundParameters[$k] } }
    $res = Invoke-FsCl3Phase -Phase $Phase -Cycle $cyc -Opt $opt -Ask $script:FsCl3ConsoleAsk -NowUtc { [DateTime]::UtcNow } -Say { param([string]$Line) Write-Host $Line }
    $exit = $res.Exit
} catch { Write-Output "CHECKLIST ERROR: $($_.Exception.Message)"; $exit = 70 }
exit $exit
