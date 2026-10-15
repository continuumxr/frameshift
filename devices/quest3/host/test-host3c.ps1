# FrameShift host fixtures, STAGE 3C (interactive, per phase), Windows PowerShell 5.1. No device, no
# adb/fastboot, no COM port, no network. Exit 0 only if every check passes. test-host3b.ps1 and
# test-host2.ps1 are unchanged and must still pass on their own (section Y runs them with -Regression).
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host3c.ps1 [-Scratch <dir>] [-OutFile <file>]
#       [-Regression [-BeforeDir <dir with test-host3b.txt and test-host2.txt from before>]] [-WriteFixtures]
# Replay transport (fs-collect3c's, re-anchored per host write) + ScriptedKeySource (anchor:delayMs:key)
# + a recording sound sink and console. DESIGN.md revision 3 section 12.3 "Host" cases 1-23 map to:
#   A  nominal sessions (1), the canonical replay fixtures, the CLI replay
#   B  a timeout at every prompt type (2)              C  `x` at every prompt and during each phase (3)
#   D  `n` at a reading, a layout item, the dark check (4)
#   E  ignored keys; keys pressed during a phase, buffered keys drained and logged (5)
#   F  characters and bars entry, Backspace, invalid keys, early Enter, Esc; echoes (6)
#   G  layout items: when they are asked (7)           H  the run-3 rule, every row (8)
#   I  guards G = 34/68/82/64 with DoneReserve; 144 s; countdown (9)
#   J  the 110 s gap cap (10)                          K  lost record / idle path: nothing sent (11)
#   L  an FSB1-rejected slice (12)                     M  FSXE1 ran=0 / ran=1 (13)
#   N  stray bytes during the prompts (14)             O  FSPM1 markers, grammar, banners and sounds (15)
#   P  sounds, the SoundPlayer fallback, -SoundCheck (16)
#   Q  classifier re-slicing equals the collector's; CLI (17)
#   R  FSR2 format, monotonic times, no machine facts before the readings (18)
#   S  every section-11 outcome, layout label, interpretation and runner inconsistency (19)
#   T  the M4 dot-source parameter scope (21)         U  replay-token re-derivation (22)
#   V  per-slice FSB1 validation (23)                  W  fs-phase command line vs ^[a-z0-9 -]{1,64}\z
#   X  fs-observe3c.ps1 (copy, unconditional dwell gate, 3c MANIFEST list, S3c launch line)
#   CL the console checklist (PM decision J-118): fs-checklist3c.ps1 phases A, B, E (all y; n, timeout at each
#      item; every automatic check of A; the single-reading rule of B, J-125; prerequisites), the fs-observe3c.ps1 gate
#      (missing phases, stale presence, refusal without any device action), SIGNOFF-3c / WALKTHROUGH consistency
#   Z  interface cross-check against the device's fs-pattern v0.6 mock streams (stage3c/fixtures/sim)
#   Z2 END TO END: every device whole-image capture (stage3c/fixtures/image/*) through fs-collect3c replay + fs-classify3c
#   BR the build-review fixes (2026-10-12): p0 integrity gate, Ctrl+C/console mode/incremental readings, the run-3 gate
#      facts, key repeat, READ without characters, n during a run, key reach, summary on a key, recovery line, banners
#   UB the stage-3d user-build capture rows (before-after/commands-userbuild.tsv) against fs-capture.ps1's allowlist
#   Y  stage-3b behaviour unchanged: pinned files, test-host3b / test-host2 (20)
param([string]$Scratch = '', [string]$OutFile = '', [switch]$Regression, [string]$BeforeDir = '', [switch]$WriteFixtures)
$ErrorActionPreference = 'Stop'
$T3Dir = $PSScriptRoot
if (-not $OutFile) { $OutFile = Join-Path $T3Dir 'test-host3c.output.txt' }
. (Join-Path $T3Dir 'fs-collect3c.ps1')
. (Join-Path $T3Dir 'fixtures\stage3c\gen3c.ps1')
. (Join-Path $T3Dir 'fs-observe3c.ps1')
. (Join-Path $T3Dir 'fs-checklist3c.ps1')
$T3Root = [IO.Path]::GetFullPath((Join-Path $T3Dir '..\..\..'))
$T3Q3 = Join-Path $T3Root 'devices\quest3'
$T3Fix = Join-Path $T3Dir 'fixtures\stage3c'
if (-not $Scratch) { $Scratch = Join-Path ([IO.Path]::GetTempPath()) ("fs-host3c-" + (New-FsHex 4)) }
$null = New-Item -ItemType Directory -Force -Path $Scratch
$script:pass = 0; $script:fail = 0; $script:skip = 0
$script:log = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $script:log.Add($s); Write-Host $s }
function Check([string]$name, [bool]$cond, [string]$detail = '') { if ($cond) { $script:pass++; Say "PASS  $name" } else { $script:fail++; Say "FAIL  $name $detail" } }
function Skip([string]$name, [string]$why) { $script:skip++; Say "SKIP  $name ($why)" }
Say "== test-host3c  $(Get-Date -Format o)  PowerShell $($PSVersionTable.PSVersion)  scratch=$Scratch"

# ------------------------------------------------------------------ helpers --
$script:T3Snd = New-Fs3cSounds
$script:T3N = 0
function T3Keys([string[]]$k, $g) {
    @($k | ForEach-Object { $e = $_; foreach ($ph in 'r1', 'r2', 'r3') { for ($i = 0; $i -lt 8; $i++) { $e = $e.Replace("{$($ph):$i}", $g.Tokens.C[$ph].Substring($i, 1)) } }; $e })
}
function T3Chars([string]$ph, [int]$d = 200) { @(0..7 | ForEach-Object { "p:$($d):{$($ph):$_}" }) + @("p:$($d):Enter") }
# one scripted session: generate the capture, replay it with scripted keys
function T3Run {
    param([string]$Tag, [object[]]$Spec, [bool]$Done = $true, [string[]]$Keys = @(), [hashtable]$Ov = @{}, [scriptblock]$Player = $null, [string]$GenName = '')
    $script:T3N++
    $gn = if ($GenName) { $GenName } else { $Tag }
    $dir = Join-Path $Scratch ("{0:D3}-{1}" -f $script:T3N, $Tag)
    $g = New-G3Session -Name $gn -Spec $Spec -Done $Done -Path (Join-Path $dir 'src\capture.raw')
    $ui = New-Fs3cUi -Kind record
    $ks = New-Fs3cScriptedKeySource -Script (T3Keys $Keys $g)
    $Ov = @{} + $Ov; if (-not $Ov.ContainsKey('PatternPin')) { $Ov['PatternPin'] = $script:G3Pin }   # the fixture fs-pattern digest (p0 integrity gate)
    if ($Player) { $sink = New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd -Player $Player -Fallback { param($s, $n) $s.Played.Add("fallback:$n") } }
    else { $sink = New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd }
    $r = Invoke-Fs3cReplay -RawPath (Join-Path $dir 'src\capture.raw') -OutDirX (Join-Path $dir 'out') -Overrides $Ov -Ui $ui -Keys $ks -Sound $sink -Sounds $script:T3Snd
    [pscustomobject]@{ G = $g; R = $r; Ui = $ui; Ks = $ks; Sink = $sink; Dir = $dir; Out = (Join-Path $dir 'out') }
}
function T3Clean($x) { @($x.R.Replay.Divergence).Count -eq 0 -and @($x.R.Replay.UnperformedWrites).Count -eq 0 -and $x.R.Replay.RecaptureIsSourcePrefix }
function T3It($x, [string]$ph, [string]$item) { @($x.R.ReadingObjs | Where-Object { $_.Ph -ceq $ph -and $_.Item -ceq $item })[0] }
function T3Obs($x, [string]$ph, [string]$item) { $i = T3It $x $ph $item; if ($null -eq $i) { '' } else { [string]$i.Obs } }
function T3Sent($x, [string]$ph) { @($x.R.Sent | Where-Object { $_ -cmatch "^fs-phase $ph " }).Count -eq 1 }
function T3Ph($x, [string]$ph) { @($x.R.Phases | Where-Object { $_.Ph -ceq $ph })[0] }
function T3Items($x, [string]$ph) { (@($x.R.ReadingObjs | Where-Object { $_.Ph -ceq $ph } | ForEach-Object { "$($_.Item)=$($_.Obs)" }) -join ',') }
function T3EvMs($x, [string]$pattern) { $e = @($x.R.Events | Where-Object { $_ -match $pattern })[0]; if ($e) { [long]($e.Split(' ')[0]) } else { $null } }
function T3Desc($x) { "sent=$(@($x.R.Sent | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' }) -join ',') end=$($x.R.EndReason) stop=$($x.R.StopReason) done=$($x.R.DoneSent) div=$(@($x.R.Replay.Divergence) -join ';') items=$((@('r1','r2','r3') | ForEach-Object { T3Items $x $_ }) -join ' / ')" }
$SP1 = @(@{ Ph = 'p0' }, @{ Ph = 'r1' }); $SP2 = $SP1 + @(@{ Ph = 'r2' }); $SP3 = $SP2 + @(@{ Ph = 'r3' })
$KR1 = @('p:1500:b', 'p:900:b', 'p:800:y')
$KR2C = @('p:1800:c', 'p:900:c', 'p:800:y')                                          # r2 garbled, dark y: on the run-3 path no bars (Q7 fallback)
$KR2CB = $KR2C + @('p:1500:1', 'p:400:2', 'p:1500:3', 'p:400:4')                     # the same where the run-3 rule does not hold (bars asked)
$KR2CD = @('p:1000:c', 'p:1000:d') + (T3Chars 'r2') + @('p:1000:y')                 # r2 left garbled, right read correctly: rule 3, the bars ARE asked
$KR3S = @('p:2000:s', 'p:900:s', 'p:800:y')
$KX = @('p:500:x')

# ------------------------------------------------------------------ A --------
Say '== A. nominal sessions, canonical replay fixtures, the CLI replay'
$CAN = @{}
foreach ($cn in $script:G3Canon.Keys) {
    $c = $script:G3Canon[$cn]
    $script:T3N++
    $dir = Join-Path $Scratch ("{0:D3}-canon-{1}" -f $script:T3N, $cn)
    $g = New-G3Session -Name $cn -Spec $c.Spec -Done $c.Done -Path (Join-Path $dir 'src\capture.raw')
    $keys = Expand-G3Keys $c.Keys $g.Tokens.C['r2']
    [IO.File]::WriteAllLines((Join-Path $dir 'src\keys.txt'), [string[]]$keys)
    $fx = Join-Path $T3Fix "replay\$cn"
    if ($WriteFixtures) {
        $null = New-Item -ItemType Directory -Force -Path $fx
        foreach ($f in 'capture.raw', 'capture.raw.idx', 'keys.txt') { Copy-Item -LiteralPath (Join-Path $dir "src\$f") -Destination (Join-Path $fx $f) -Force }
    }
    $same = $true
    foreach ($f in 'capture.raw', 'capture.raw.idx', 'keys.txt') {
        $a1 = Join-Path $fx $f; $b1 = Join-Path $dir "src\$f"
        if (-not (Test-Path -LiteralPath $a1)) { $same = $false; continue }
        if ((Get-FsSha256Hex ([IO.File]::ReadAllBytes($a1))) -cne (Get-FsSha256Hex ([IO.File]::ReadAllBytes($b1)))) { $same = $false }
    }
    Check "A0 canonical fixture replay\$cn (capture.raw, .idx, keys.txt) is byte-identical to the generator's output" $same
    $ui = New-Fs3cUi -Kind record; $ks = New-Fs3cScriptedKeySource -Script $keys; $sink = New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd
    $r = Invoke-Fs3cReplay -RawPath (Join-Path $fx 'capture.raw') -OutDirX (Join-Path $dir 'out') -Overrides @{ PatternPin = $script:G3Pin } -Ui $ui -Keys $ks -Sound $sink -Sounds $script:T3Snd
    $CAN[$cn] = [pscustomobject]@{ G = $g; R = $r; Ui = $ui; Ks = $ks; Sink = $sink; Dir = $dir; Out = (Join-Path $dir 'out') }
}
$a = $CAN['nominal-read']
Check 'A1 nominal (r2 read in both eyes): p0, r1, r2 sent once each with the chained <prev>; no r3 (rule 2); fs-done; COLLECTED-VALID; no replay divergence' `
    ((T3Clean $a) -and (T3Sent $a 'p0') -and (T3Sent $a 'r1') -and (T3Sent $a 'r2') -and -not (T3Sent $a 'r3') -and $a.R.DoneSent -and $a.R.Status -ceq 'COLLECTED-VALID' -and
     $a.R.R3Rule.Rule -eq 2 -and (@($a.R.Sent) -join '|') -match "fs-phase r1 [0-9a-f]{32} $($a.G.Sha16['p0'])\|fs-phase r2 [0-9a-f]{32} $($a.G.Sha16['r1'])\|fs-done$") (T3Desc $a)
Check 'A2 nominal readings: r1 DARK/DARK/DARK_NOW; r2 READ <chal8> in each eye, DARK_NOW, bars 12 u l / 34 u r' `
    ((T3Items $a 'r1') -ceq 'left=DARK,right=DARK,dark=DARK_NOW' -and (T3It $a 'r2' 'left').Chars -ceq $a.G.Tokens.C['r2'].Substring(0, 8).ToUpperInvariant() -and
     (T3Items $a 'r2') -ceq 'left=READ,right=READ,dark=DARK_NOW,bars_left=BARS,orient_left=UPRIGHT,tilt_left=LEFT_LOW,bars_right=BARS,orient_right=UPRIGHT,tilt_right=RIGHT_LOW' -and (T3It $a 'r2' 'bars_right').Bars -ceq '34') (T3Items $a 'r2')
$a = $CAN['garbled-r3']
Check 'A3 garbled path: r2 garbled in both eyes -> run 3 requested (rules 1-5 hold), r3 sent once with r2''s sha16, r3 SAME_AS_R2, fs-done' `
    ((T3Clean $a) -and (T3Sent $a 'r3') -and $a.R.R3Rule.Allow -and (@($a.R.Sent) -join '|') -match "fs-phase r3 [0-9a-f]{32} $($a.G.Sha16['r2'])\|fs-done$" -and (T3Items $a 'r3') -ceq 'left=SAME_AS_R2,right=SAME_AS_R2,dark=DARK_NOW' -and $a.R.Status -ceq 'COLLECTED-VALID') (T3Desc $a)
$p = T3Ph $a 'r2'
Check 'A3b Q7 fallback (PM rehearsal 2026-10-12): on the run-3 path the bar counts are not asked: bars_left/right NOT_ASKED (answer_ms -1), no BARS prompt shown, events bars-not-asked (Q7 fallback), r2 phase Q7Fallback "not asked (Q7 fallback)"; session.json carries it' `
    ((T3Items $a 'r2') -ceq 'left=GARBLED,right=GARBLED,dark=DARK_NOW,bars_left=NOT_ASKED,bars_right=NOT_ASKED' -and (T3It $a 'r2' 'bars_left').AnswerMs -eq -1 -and
     @($a.Ui.Transcript | Where-Object { $_ -cmatch 'BARS' }).Count -eq 0 -and @($a.R.Events | Where-Object { $_ -match 'bars-not-asked r2/bars_(left|right) \(Q7 fallback: run-3 path\)' }).Count -eq 2 -and
     $null -ne $p.Q7Fallback -and (@($p.Q7Fallback.Items) -join ',') -ceq 'bars_left,bars_right' -and $p.Q7Fallback.Note -ceq 'not asked (Q7 fallback)' -and
     (@((Get-Content -Raw (Join-Path $a.Out 'session.json') | ConvertFrom-Json).Phases | Where-Object { $_.Ph -ceq 'r2' })[0]).Q7Fallback.Note -ceq 'not asked (Q7 fallback)') "$(T3Items $a 'r2') q7=$($p.Q7Fallback | ConvertTo-Json -Compress)"
$a = $CAN['r2-ran1-emit']
Check 'A4 canonical r2-ran1-emit: FSXE1 ran=1 emit-1 after a partial record -> r2 readings and dark check, no r3, fs-done, COLLECTED-REJECTED' `
    ((T3Clean $a) -and (T3Items $a 'r2') -ceq 'left=LIT,right=LIT,dark=DARK_NOW' -and -not (T3Sent $a 'r3') -and $a.R.DoneSent -and $a.R.Status -ceq 'COLLECTED-REJECTED' -and (T3Ph $a 'r2').Refusal.Ran -eq 1 -and (T3Ph $a 'r2').Refusal.Error -ceq 'emit-1') (T3Desc $a)
$x = T3Run 'a5-all-dark' $SP2 $true ($KR1 + @('p:1500:b', 'p:900:b', 'p:800:y'))
Check 'A5 r2 dark in both eyes: no run 3 (rule 2), fs-done' ((T3Clean $x) -and -not (T3Sent $x 'r3') -and $x.R.R3Rule.Rule -eq 2 -and $x.R.DoneSent) (T3Desc $x)
# the CLI replay with a key script (child process)
$cdir = Join-Path $Scratch 'cli-replay'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $T3Dir 'fs-collect3c.ps1') -S3cReplay (Join-Path $T3Fix 'replay\garbled-r3\capture.raw') -S3cOutDir $cdir -S3cKeyScript (Join-Path $T3Fix 'replay\garbled-r3\keys.txt') -S3cReplayPin $script:G3Pin
$code = $LASTEXITCODE
Check 'A6 fs-collect3c.ps1 -S3cReplay ... -S3cKeyScript (CLI): exit 10, STATUS COLLECTED-VALID, four phases FSB1 VALID, run-3 rule held, fs-done sent; session.json, readings3c.txt, phase-p0..r3.raw written' `
    ($code -eq 10 -and ($out -join "`n") -match 'STATUS: COLLECTED-VALID' -and @($out | Where-Object { $_ -match '^PHASE (p0|r1|r2|r3): FSB1 VALID' }).Count -eq 4 -and ($out -join "`n") -match 'RUN-3 RULE: held' -and
     ($out -join "`n") -match 'RECOVERY: fs-done sent' -and (Test-Path (Join-Path $cdir 'session.json')) -and (Test-Path (Join-Path $cdir 'readings3c.txt')) -and @(Get-ChildItem $cdir -Filter 'phase-*.raw').Count -eq 4) "exit $code $($out -join ' / ')"

# the rehearsal transport (paced on the real clock) on a short session, and the rehearsal timing summary
$pdir = Join-Path $Scratch 'paced'
$gp = New-G3Session -Name 'paced' -Spec @(@{ Ph = 'p0'; Rec = 'ran0' }) -Done $true -Path (Join-Path $pdir 'src\capture.raw')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rp = Invoke-Fs3cReplay -RawPath (Join-Path $pdir 'src\capture.raw') -OutDirX (Join-Path $pdir 'out') -Overrides @{ PatternPin = $script:G3Pin } -Paced
$el = $sw.ElapsedMilliseconds
Check "A7 the paced replay (rehearsal transport) runs a short session on the real clock ($el ms) through the same code: no divergence, p0 refused ran=0, fs-done" `
    (@($rp.Replay.Divergence).Count -eq 0 -and @($rp.Replay.UnperformedWrites).Count -eq 0 -and $el -ge 4000 -and $rp.DoneSent -and (@($rp.Phases)[0]).Refusal.Ran -eq 0) "$el ms $($rp.StopReason) $(@($rp.Replay.Divergence) -join ';')"
$rs = (Write-Fs3cSummary $CAN['garbled-r3'].R $true) -join "`n"
$a = $CAN['garbled-r3']; $w2 = ((T3It $a 'r2' 'dark').AnswerMs - (T3It $a 'r2' 'left').PromptMs) / 1000.0
Check 'A8 the rehearsal summary gives the run-1 and run-2 answer times and the go/no-go against 40 s (SIGNOFF-3c A, Q7); r2 = first prompt to the last ANSWER (the dark check; the Q7 NOT_ASKED bars lines carry no answer and add no time); the summary names the Q7 fallback' `
    ($rs -match 'REHEARSAL: r1 answers took 3\.2 s' -and $rs -match 'REHEARSAL: r2 answers took 3\.5 s' -and $rs -match 'run-1 plus run-2 answers 6\.7 s; go/no-go \(SIGNOFF-3c A, Q7\): GO' -and
     [Math]::Abs($w2 - 3.5) -lt 0.06 -and $rs -match 'PHASE r2: .*bars_left, bars_right not asked \(Q7 fallback\)') "$rs w2=$w2"
$fr = New-Fs3cInteract -Ui (New-Fs3cUi -Kind record) -Keys (New-Fs3cScriptedKeySource -Script @()) -Sound (New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd)
$fo = @(); foreach ($v in @(@('r1', 'left', 'GARBLED', 19044, 25702), @('r1', 'right', 'GARBLED', 25873, 30458), @('r1', 'dark', 'DARK_NOW', 30474, 35451), @('r2', 'left', 'GARBLED', 52179, 64593),
                             @('r2', 'right', 'GARBLED', 64607, 66567), @('r2', 'dark', 'DARK_NOW', 66577, 70176), @('r2', 'bars_left', 'NOT_ASKED', 70186, -1), @('r2', 'bars_right', 'NOT_ASKED', 70190, -1))) {
    $fo += Add-Fs3cReading -X $fr -Ph $v[0] -Item $v[1] -Obs $v[2] -PromptMs $v[3] -AnswerMs $v[4] }
$rs2 = (Write-Fs3cSummary ([pscustomobject]@{ Status = 'COLLECTED-VALID'; StopReason = $null; EndReason = $null; Sent = @(); Phases = @(); R3Rule = $null; Capture = [pscustomobject]@{ Path = 'x'; Bytes = 0; Sha256 = '-'; Consistent = $true }; SlicesConsistent = $true; CaptureError = $null; ReadingsFile = 'x'; Readings = @(); DoneSent = $true; DoneReply = 'FSD1 queued END'; ReadingObjs = $fo; DeviceDeadlineSec = 200 }) $true) -join "`n"
Check 'A8b the rehearsal go/no-go still sums the run-1 and run-2 ANSWER times: the PM rehearsal''s answer stamps (r1 16.4 s) with run 2 as on the Q7 path (bars NOT_ASKED) -> r2 18.0 s, 34.4 s, GO' `
    ($rs2 -match 'REHEARSAL: r1 answers took 16\.4 s' -and $rs2 -match 'REHEARSAL: r2 answers took 18\.0 s' -and $rs2 -match 'run-1 plus run-2 answers 34\.4 s; go/no-go \(SIGNOFF-3c A, Q7\): GO') $rs2
$fo3 = @($fo | Where-Object { $_.Item -notlike 'bars_*' })
$fo3 += Add-Fs3cReading -X $fr -Ph 'r2' -Item 'bars_left' -Key '-' -Obs 'BARS' -Bars '12' -PromptMs 70186 -AnswerMs 86200
$fo3 += Add-Fs3cReading -X $fr -Ph 'r2' -Item 'bars_right' -Key '-' -Obs 'BARS' -Bars '34' -PromptMs 86210 -AnswerMs 102379
$rs3 = (Write-Fs3cSummary ([pscustomobject]@{ Status = 'COLLECTED-VALID'; StopReason = $null; EndReason = $null; Sent = @(); Phases = @(); R3Rule = $null; Capture = [pscustomobject]@{ Path = 'x'; Bytes = 0; Sha256 = '-'; Consistent = $true }; SlicesConsistent = $true; CaptureError = $null; ReadingsFile = 'x'; Readings = @(); DoneSent = $true; DoneReply = 'FSD1 queued END'; ReadingObjs = $fo3; DeviceDeadlineSec = 200 }) $true) -join "`n"
Check 'A8c the same measure on the first rehearsal''s shape (two bar questions answered, r2 50.2 s): 66.6 s, NO-GO, "stop and report (the Q7 fallback is already applied)"' `
    ($rs3 -match 'REHEARSAL: r1 answers took 16\.4 s' -and $rs3 -match 'REHEARSAL: r2 answers took 50\.2 s' -and $rs3 -match 'run-1 plus run-2 answers 66\.6 s; go/no-go \(SIGNOFF-3c A, Q7\): NO-GO \(> 40 s\): stop and report \(the Q7 fallback is already applied\)') $rs3

# ------------------------------------------------------------------ B --------
Say '== B. a timeout at every prompt type -> TIMEOUT, NOT_ASKED for the rest, fs-done'
$kd = @('p:1000:d') + (T3Chars 'r2') + @('p:1000:b', 'p:1000:y', 'p:1000:1', 'p:300:2')
$bcases = @(
    @('b1-left', $SP1, @(), 'r1', 'left', 'left=TIMEOUT,right=NOT_ASKED,dark=NOT_ASKED'),
    @('b2-right', $SP1, @('p:1000:b'), 'r1', 'right', 'left=DARK,right=TIMEOUT,dark=NOT_ASKED'),
    @('b3-chars', $SP1, @('p:1000:d', 'p:500:1'), 'r1', 'chars_left', 'left=READ,chars_left=TIMEOUT,right=NOT_ASKED,dark=NOT_ASKED'),
    @('b4-dark', $SP1, @('p:1000:b', 'p:1000:b'), 'r1', 'dark', 'left=DARK,right=DARK,dark=TIMEOUT'),
    @('b5-bars', $SP2, ($KR1 + $KR2CD), 'r2', 'bars_left', 'left=GARBLED,right=READ,dark=DARK_NOW,bars_left=TIMEOUT,bars_right=NOT_ASKED,orient_right=NOT_ASKED,tilt_right=NOT_ASKED'),
    @('b6-orient', $SP2, ($KR1 + $kd), 'r2', 'orient_left', 'left=READ,right=DARK,dark=DARK_NOW,bars_left=BARS,orient_left=TIMEOUT,tilt_left=NOT_ASKED'),
    @('b7-tilt', $SP2, ($KR1 + $kd + @('p:1000:u')), 'r2', 'tilt_left', 'left=READ,right=DARK,dark=DARK_NOW,bars_left=BARS,orient_left=UPRIGHT,tilt_left=TIMEOUT'),
    @('b8-r3-left', $SP3, ($KR1 + $KR2C), 'r3', 'left', 'left=TIMEOUT,right=NOT_ASKED,dark=NOT_ASKED'),
    @('b9-r3-dark', $SP3, ($KR1 + $KR2C + @('p:1000:r', 'p:1000:r')), 'r3', 'dark', 'left=UNIFORM_RED,right=UNIFORM_RED,dark=TIMEOUT'))
foreach ($bc in $bcases) {
    $x = T3Run $bc[0] $bc[1] $true $bc[2]
    $it = T3It $x $bc[3] $bc[4]
    $tms = T3EvMs $x "reading p=$($bc[3]) item=$($bc[4]) key=- obs=TIMEOUT"
    $okT = ($null -ne $it -and $null -ne $tms -and ($tms - $it.PromptMs) -ge 30000 -and ($tms - $it.PromptMs) -le 30100)
    Check "B $($bc[0]): $($bc[3]) $($bc[4]) TIMEOUT after 30 s, NOT_ASKED for the rest ($($bc[5])), safe finish, fs-done, no further phase" `
        ((T3Clean $x) -and (T3Items $x $bc[3]) -ceq $bc[5] -and $okT -and $x.R.DoneSent -and (T3Ph $x $bc[3]).GapSafe -ceq 'timeout' -and @($x.R.SoundsPlayed | Where-Object { $_ -like 'ALARM@*' }).Count -ge 1) "$(T3Desc $x) t=$tms"
}

# ------------------------------------------------------------------ C --------
Say '== C. x at every prompt and during each phase'
$kdx = @('p:1000:d') + (T3Chars 'r2') + @('p:1000:b', 'p:1000:y', 'p:1000:1', 'p:300:2')
$ccases = @(
    @('c1-left', $SP1, @('p:1000:x'), 'r1', 'left=ABORT,right=NOT_ASKED,dark=NOT_ASKED'),
    @('c2-right', $SP1, @('p:1000:b', 'p:1000:x'), 'r1', 'left=DARK,right=ABORT,dark=NOT_ASKED'),
    @('c3-chars', $SP1, @('p:1000:d', 'p:300:1', 'p:300:x'), 'r1', 'left=READ,chars_left=ABORT,right=NOT_ASKED,dark=NOT_ASKED'),
    @('c4-dark', $SP1, @('p:1000:b', 'p:1000:b', 'p:1000:x'), 'r1', 'left=DARK,right=DARK,dark=ABORT'),
    @('c5-bars', $SP2, ($KR1 + $KR2CD + @('p:1000:x')), 'r2', 'left=GARBLED,right=READ,dark=DARK_NOW,bars_left=ABORT,bars_right=NOT_ASKED,orient_right=NOT_ASKED,tilt_right=NOT_ASKED'),
    @('c6-orient', $SP2, ($KR1 + $kdx + @('p:1000:x')), 'r2', 'left=READ,right=DARK,dark=DARK_NOW,bars_left=BARS,orient_left=ABORT,tilt_left=NOT_ASKED'),
    @('c7-tilt', $SP2, ($KR1 + $kdx + @('p:1000:u', 'p:1000:x')), 'r2', 'left=READ,right=DARK,dark=DARK_NOW,bars_left=BARS,orient_left=UPRIGHT,tilt_left=ABORT'),
    @('c8-r3-left', $SP3, ($KR1 + $KR2C + @('p:1000:x')), 'r3', 'left=ABORT,right=NOT_ASKED,dark=NOT_ASKED'),
    @('c9-r3-dark', $SP3, ($KR1 + $KR2C + @('p:1000:r', 'p:1000:r', 'p:1000:x')), 'r3', 'left=UNIFORM_RED,right=UNIFORM_RED,dark=ABORT'))
foreach ($cc in $ccases) {
    $x = T3Run $cc[0] $cc[1] $true $cc[2]
    Check "C $($cc[0]): x records ABORT ($($cc[4])), NOT_ASKED for the rest, safe finish, fs-done, no further phase" `
        ((T3Clean $x) -and (T3Items $x $cc[3]) -ceq $cc[4] -and $x.R.DoneSent -and (T3Ph $x $cc[3]).GapSafe -ceq 'abort') (T3Desc $x)
}
$lit = @(
    @('c10-during-r1', $SP1, @('i:3000:x', 'p:1500:y'), 'r1'),
    @('c11-during-r2', $SP2, ($KR1 + @('j:4000:x', 'p:1500:y')), 'r2'),
    @('c12-during-r3', $SP3, ($KR1 + $KR2C + @('k:4000:x', 'p:1500:y')), 'r3'))
foreach ($lc in $lit) {
    $x = T3Run $lc[0] $lc[1] $true $lc[2]
    $p = T3Ph $x $lc[3]
    $nx = @{ r1 = 'r2'; r2 = 'r3'; r3 = '' }[$lc[3]]
    Check "C $($lc[0]): x during the lit phase is noted at once (banner ABORT NOTED, ALARM), no command mid-phase; after the record only the dark check is asked (readings ABORT, no layout items), then fs-done" `
        ((T3Clean $x) -and $p.AbortNoted -and (T3Items $x $lc[3]) -ceq 'left=ABORT,right=ABORT,dark=DARK_NOW' -and $x.R.DoneSent -and (-not $nx -or -not (T3Sent $x $nx)) -and
         @($x.Ui.Transcript | Where-Object { $_ -match 'ABORT NOTED - the device finishes this hold' }).Count -eq 1 -and @($x.R.SoundsPlayed | Where-Object { $_ -like 'ALARM@*' }).Count -ge 1) (T3Desc $x)
}
$x = T3Run 'c13-during-p0' @(@{ Ph = 'p0' }) $true @('g:500:x')
Check 'C c13: x during p0 (nothing lit): no prompts, run 1 not sent, fs-done' ((T3Clean $x) -and (T3Ph $x 'p0').AbortNoted -and @($x.R.Readings).Count -eq 0 -and -not (T3Sent $x 'r1') -and $x.R.DoneSent) (T3Desc $x)
$x = T3Run 'c14-during-cue' @(@{ Ph = 'p0' }) $true @('c:1000:x')
Check 'C c14: x during the 3 s LOOK cue: run 1 not sent, fs-done' ((T3Clean $x) -and -not (T3Sent $x 'r1') -and $x.R.DoneSent -and $x.R.EndReason -match 'LOOK cue') (T3Desc $x)

# ------------------------------------------------------------------ D --------
Say '== D. n (light still visible now): a key of the DARK CHECK only (PM rehearsal feedback); x aborts at every prompt'
$x = T3Run 'd1-reading' $SP1 $true @('p:1000:n', 'p:700:x')
Check 'D1 n at an eye reading is not a key there (ignored, logged; no LIGHT_NOW); x then aborts: ABORT, safe finish, fs-done' `
    ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'left=ABORT,right=NOT_ASKED,dark=NOT_ASKED' -and @($x.R.Events | Where-Object { $_ -match 'key-ignored r1/left key=n' }).Count -eq 1 -and (T3Ph $x 'r1').GapSafe -ceq 'abort' -and $x.R.DoneSent) (T3Desc $x)
$x = T3Run 'd2-layout' $SP2 $true ($KR1 + $KR2CD + @('p:1000:n', 'p:700:x'))
Check 'D2 n at a layout item (bars) is ignored (logged); x aborts: bars_left ABORT, no LIGHT_NOW, safe finish, no run 3' `
    ((T3Clean $x) -and (T3Obs $x 'r2' 'bars_left') -ceq 'ABORT' -and @($x.R.Events | Where-Object { $_ -match 'key-ignored r2/bars_left key=n' }).Count -eq 1 -and @($x.R.ReadingObjs | Where-Object { $_.Obs -ceq 'LIGHT_NOW' }).Count -eq 0 -and -not (T3Sent $x 'r3') -and $x.R.DoneSent) (T3Desc $x)
$x = T3Run 'd4-chars' $SP1 $true @('p:1000:d', 'p:300:1', 'p:300:n', 'p:700:x')
Check 'D4 n in the character entry is ignored (logged); x ends it: READ, characters not recorded (chars_left ABORT), safe finish' `
    ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'left=READ,chars_left=ABORT,right=NOT_ASKED,dark=NOT_ASKED' -and @($x.R.Events | Where-Object { $_ -match 'key-ignored r1/chars_left key=n' }).Count -eq 1 -and $x.R.DoneSent) (T3Desc $x)
$x = T3Run 'd5-r3-reading' $SP3 $true ($KR1 + $KR2C + @('p:1000:n', 'p:700:r', 'p:900:r', 'p:800:y'))
Check 'D5 n at a run-3 eye reading is ignored (logged); the next valid key answers' ((T3Clean $x) -and (T3Items $x 'r3') -ceq 'left=UNIFORM_RED,right=UNIFORM_RED,dark=DARK_NOW' -and @($x.R.Events | Where-Object { $_ -match 'key-ignored r3/left key=n' }).Count -eq 1) (T3Desc $x)
$trD = @($CAN['nominal-read'].Ui.Transcript) + @($CAN['garbled-r3'].Ui.Transcript)
Check 'D6 the per-eye prompt lines are short and offer no n (runs 1-3; "a = light, no pattern ... d = I can read the characters ... x = abort"); n = light visible is offered only by the dark check' `
    (@($trD | Where-Object { $_ -match 'n = light' -and $_ -notmatch '^DARK CHECK' -and $_ -notmatch '^\[BANNER info\] DARK CHECK' }).Count -eq 0 -and
     @($trD | Where-Object { $_ -ceq 'RUN 2 - LEFT EYE:  a = light, no pattern   b = dark   c = garbled   d = I can read the characters   x = abort' }).Count -eq 2 -and
     @($trD | Where-Object { $_ -cmatch '^RUN 3 - RIGHT EYE:  r = all red .* x = abort$' }).Count -eq 1 -and @($trD | Where-Object { $_ -match '^RUN [123] - (LEFT|RIGHT) EYE:' -and $_.Length -gt 140 }).Count -eq 0)
$x = T3Run 'd3-dark' $SP1 $true @('p:1000:b', 'p:1000:b', 'p:1000:n')
Check 'D3 n at the dark check: LIGHT_NOW, safe finish, no run 2' ((T3Clean $x) -and (T3Obs $x 'r1' 'dark') -ceq 'LIGHT_NOW' -and -not (T3Sent $x 'r2') -and $x.R.DoneSent) (T3Desc $x)
$D3 = $x

# ------------------------------------------------------------------ E --------
Say '== E. ignored keys, keys during a phase, buffered keys'
$x = T3Run 'e1-ignored' $SP2 $true (@('p:500:q', 'p:300:z', 'p:300:b', 'p:900:b', 'p:800:y') + $KX)
Check 'E1 keys outside the prompt''s set are ignored (logged), the timeout keeps running, the answer is the next valid key' `
    ((T3Clean $x) -and (T3Obs $x 'r1' 'left') -ceq 'DARK' -and @($x.R.Events | Where-Object { $_ -match 'key-ignored r1/left key=(q|z)' }).Count -eq 2) (T3Desc $x)
$x = T3Run 'e2-buffered' $SP2 $true (@('i:2000:c', 'i:60000:a') + $KR1 + $KX)
$p = T3Ph $x 'r1'
Check 'E2 a key pressed during the lit phase is discarded and logged (never an answer); a key still buffered when the prompt appears is drained, logged and counted (discarded=1)' `
    ((T3Clean $x) -and @($p.KeysDiscarded | Where-Object { $_ -like 'c@*' }).Count -eq 1 -and (T3It $x 'r1' 'left').Discarded -eq 1 -and (T3Obs $x 'r1' 'left') -ceq 'DARK' -and
     @($x.R.Events | Where-Object { $_ -match 'keys-discarded before r1/left n=1 keys=a' }).Count -eq 1 -and ($x.R.Readings[0]) -match ' discarded=1$') (T3Desc $x)

# ------------------------------------------------------------------ F --------
Say '== F. characters and bars entry; echoes'
$x = T3Run 'f1-chars' $SP2 $true (@('p:1000:d', 'p:200:{r1:0}', 'p:200:g', 'p:200:{r1:1}', 'p:200:{r1:2}', 'p:200:Enter', 'p:200:?', 'p:200:Backspace', 'p:200:{r1:3}', 'p:200:{r1:4}', 'p:200:{r1:5}', 'p:200:{r1:6}', 'p:200:{r1:7}', 'p:200:{r1:0}', 'p:200:Enter', 'p:900:b', 'p:800:y') + $KX)
$want = $x.G.Tokens.C['r1'].Substring(0, 8).ToUpperInvariant()
Check 'F1 characters: valid keys upper-cased, an invalid key ignored, an early Enter refused (logged), Backspace removes a ?, a 9th key ignored; READ <8 chars> echoed' `
    ((T3Clean $x) -and (T3It $x 'r1' 'left').Chars -ceq $want -and @($x.R.Events | Where-Object { $_ -match 'chars-early-enter r1/left len=3' }).Count -eq 1 -and @($x.R.Events | Where-Object { $_ -match 'key-ignored r1/chars_left key=g' }).Count -eq 1 -and
     @($x.R.Events | Where-Object { $_ -match 'chars-ninth-ignored' }).Count -eq 1 -and @($x.Ui.Transcript | Where-Object { $_ -ceq "LEFT EYE: READ $want" }).Count -eq 1) (T3Desc $x)
$x = T3Run 'f2-esc-timeout' $SP1 $true @('p:5000:d', 'p:1000:1', 'p:1000:Esc')
$it = T3It $x 'r1' 'left'; $tms = T3EvMs $x 'reading p=r1 item=left key=- obs=TIMEOUT'
Check 'F2 Esc in character entry discards the characters and returns to the reading prompt, whose own 30 s timeout keeps running (TIMEOUT 30 s after the reading prompt)' `
    ((T3Clean $x) -and $it.Obs -ceq 'TIMEOUT' -and ($tms - $it.PromptMs) -ge 30000 -and ($tms - $it.PromptMs) -le 30100 -and @($x.Ui.Transcript | Where-Object { $_ -match 'characters discarded; back to the a/b/c/d choice' }).Count -eq 1) "$(T3Desc $x) t=$($tms - $it.PromptMs)"
$x = T3Run 'f3-esc-change' $SP2 $true (@('p:3000:d', 'p:500:1', 'p:500:Esc', 'p:1000:c', 'p:900:b', 'p:800:y') + $KX)
Check 'F3 a mistaken d is changed with Esc: the reading becomes GARBLED (no chars_left line)' ((T3Clean $x) -and (T3Obs $x 'r1' 'left') -ceq 'GARBLED' -and $null -eq (T3It $x 'r1' 'chars_left')) (T3Desc $x)
$x = T3Run 'f4-bars' $SP2 $true ($KR1 + $KR2CD + @('p:1000:1', 'p:300:Backspace', 'p:300:2', 'p:300:1', 'p:1000:3', 'p:300:4', 'p:500:u', 'p:500:r'))
Check 'F4 bars (off the run-3 path, here rule 3): two keys 0-4, Backspace allowed, no Enter: bars_left 21, bars_right 34; echoed; the prompt explains itself (the F letters, 1 to 4 short bars, LEFT F then RIGHT F, 0 = none visible) and shows no bar order' `
    ((T3Clean $x) -and (T3It $x 'r2' 'bars_left').Bars -ceq '21' -and (T3It $x 'r2' 'bars_right').Bars -ceq '34' -and @($x.Ui.Transcript | Where-Object { $_ -ceq 'LEFT EYE BARS: 2 1' }).Count -eq 1 -and
     @($x.Ui.Transcript | Where-Object { $_ -ceq 'LEFT EYE BARS: next to each of the two F letters (below it when upright) there is a row of 1 to 4 bars (see the preview).' }).Count -eq 1 -and
     @($x.Ui.Transcript | Where-Object { $_ -match 'at the LEFT F, then at the RIGHT F \(two keys, 0 = none visible\).*x = abort' }).Count -eq 2 -and
     @($x.Ui.Transcript | Where-Object { $_ -match '1 [|] 2|3 [|] 4' }).Count -eq 0 -and $x.R.R3Rule.Rule -eq 3) (T3Desc $x)
$tA = @($CAN['garbled-r3'].Ui.Transcript) + @($CAN['nominal-read'].Ui.Transcript)
Check 'F5 every answer is echoed in words (LEFT EYE: GARBLED, RIGHT EYE: READ <8>, DARK CHECK: DARK, RIGHT EYE: STRIPES/GARBLE THE SAME AS RUN 2, ... BARS: 1 2)' `
    (@($tA | Where-Object { $_ -ceq 'LEFT EYE: GARBLED' }).Count -ge 1 -and @($tA | Where-Object { $_ -cmatch '^RIGHT EYE: READ [0-9A-F]{8}$' }).Count -ge 1 -and @($tA | Where-Object { $_ -ceq 'DARK CHECK: DARK' }).Count -ge 3 -and
     @($tA | Where-Object { $_ -ceq 'RIGHT EYE: STRIPES/GARBLE THE SAME AS RUN 2' }).Count -eq 1 -and @($tA | Where-Object { $_ -ceq 'LEFT EYE BARS: 1 2' }).Count -ge 1)

# ------------------------------------------------------------------ G --------
Say '== G. layout items'
$x = T3Run 'g1-a-b' $SP3 $true ($KR1 + @('p:1000:a', 'p:1000:b', 'p:1000:y') + $KX)
Check 'G1 r2 readings a/b: no layout item is asked; run 3 is requested (rule 2 holds through a)' ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=LIT,right=DARK,dark=DARK_NOW' -and (T3Sent $x 'r3')) (T3Desc $x)
$x = T3Run 'g2-c-d' $SP2 $true ($KR1 + @('p:1000:c', 'p:1000:d') + (T3Chars 'r2') + @('p:800:y', 'p:1000:1', 'p:300:2', 'p:1000:3', 'p:300:4', 'p:500:u', 'p:500:r'))
Check 'G2 bars after c or d; orient and tilt only after d; run 3 not requested when an eye read the characters correctly (rule 3)' `
    ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=GARBLED,right=READ,dark=DARK_NOW,bars_left=BARS,bars_right=BARS,orient_right=UPRIGHT,tilt_right=RIGHT_LOW' -and $x.R.R3Rule.Rule -eq 3 -and -not (T3Sent $x 'r3')) (T3Desc $x)
$x = T3Run 'g3-cutoff' $SP2 $true ($KR1 + @('p:29000:c', 'p:29000:d') + (T3Chars 'r2') + @('p:27200:y', 'p:14000:1', 'p:300:2'))
Check 'G3 a layout item with < 10 s to the prompt cut-off is NOT_ASKED (no safe-finish trigger; also orient/tilt); RUN 3 NO LONGER POSSIBLE shown at the countdown; r3 not requested (rule 3); fs-done' `
    ((T3Clean $x) -and (T3Obs $x 'r2' 'bars_right') -ceq 'NOT_ASKED' -and (T3Obs $x 'r2' 'orient_right') -ceq 'NOT_ASKED' -and (T3Obs $x 'r2' 'bars_left') -ceq 'BARS' -and $null -eq (T3Ph $x 'r2').GapSafe -and
     @($x.R.Events | Where-Object { $_ -match 'layout-not-asked r2/bars_right' }).Count -eq 1 -and $null -eq (T3Ph $x 'r2').Q7Fallback -and
     @($x.Ui.Transcript | Where-Object { $_ -match '^RUN 3 NO LONGER POSSIBLE' }).Count -eq 1 -and $x.R.R3Rule.Rule -eq 3 -and $x.R.DoneSent) (T3Desc $x)
$a = $CAN['garbled-r3']
Check 'G4 layout items are never asked in r1 or r3' ((T3Items $a 'r1') -ceq 'left=DARK,right=DARK,dark=DARK_NOW' -and (T3Items $a 'r3') -ceq 'left=SAME_AS_R2,right=SAME_AS_R2,dark=DARK_NOW')
$x = T3Run 'g5-q7-dwrong' $SP3 $true ($KR1 + @('p:1000:c', 'p:1000:d') + @(1..8 | ForEach-Object { 'p:200:?' }) + @('p:200:Enter', 'p:1000:y', 'p:900:u', 'p:900:l') + $KR3S)
$q = Invoke-Fs3cClassifyDir -DirX $x.Out -S1X 'PASS' -PinX $script:G3Pin
$ql = $q.Lines -join "`n"
Check 'G5 Q7 fallback with a d eye whose characters are wrong (still the run-3 path): no bars for either eye (NOT_ASKED), orient/tilt still asked for the d eye, run 3 requested; the classifier: no LAYOUT line for the c eye, the d eye''s F/line with "bars not asked (Q7 fallback)", one READINGS NOTE, no INCONCLUSIVE (code 10)' `
    ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=GARBLED,right=READ,dark=DARK_NOW,bars_left=NOT_ASKED,bars_right=NOT_ASKED,orient_right=UPRIGHT,tilt_right=LEFT_LOW' -and (T3Sent $x 'r3') -and
     $q.Code -eq 10 -and $ql -notmatch 'LAYOUT left eye' -and $ql -match 'LAYOUT right eye: bars - F UPRIGHT line LEFT_LOW: bars not asked \(Q7 fallback\)' -and
     $ql -match 'READINGS NOTE: r2 bars_left, bars_right not asked \(Q7 fallback') "$(T3Desc $x) | $($q.Lines -join ' / ')"

# ------------------------------------------------------------------ H --------
Say '== H. the run-3 rule (DESIGN 5.8)'
function HRun([string]$layout = 'quad_vig', [int]$code = 0, [bool]$hc = $true, [bool]$cc = $true) {
    [pscustomobject]@{ Kind = 'run'; Code = $code; HeldClean = $hc; CloseClean = $cc; CommitLayout = $layout } }
function HIt([string]$l, [string]$r, [string]$d, [string]$lc = '', [string]$rc = '') {
    @{ left = [pscustomobject]@{ Obs = $l; Chars = $lc; Key = '' }; right = [pscustomobject]@{ Obs = $r; Chars = $rc; Key = '' }; dark = [pscustomobject]@{ Obs = $d; Chars = ''; Key = '' } } }
$H8 = 'abcdef01'
$hcases = @(
    @('quad clean, c/c, dark y', $true, (HRun), (HIt 'GARBLED' 'GARBLED' 'DARK_NOW'), $true, 0),
    @('a/b, dark y (rule 2 holds through a)', $true, (HRun), (HIt 'LIT' 'DARK' 'DARK_NOW'), $true, 0),
    @('quad_dma committed, c/a', $true, (HRun 'quad_dma'), (HIt 'GARBLED' 'LIT' 'DARK_NOW'), $true, 0),
    @('b/b (no a or c)', $true, (HRun), (HIt 'DARK' 'DARK' 'DARK_NOW'), $false, 2),
    @('d/d correct (no a or c)', $true, (HRun), (HIt 'READ' 'READ' 'DARK_NOW' 'ABCDEF01' 'ABCDEF01'), $false, 2),
    @('c + d correct', $true, (HRun), (HIt 'GARBLED' 'READ' 'DARK_NOW' '' 'ABCDEF01'), $false, 3),
    @('c + d wrong characters', $true, (HRun), (HIt 'GARBLED' 'READ' 'DARK_NOW' '' 'ABCDEF0?'), $true, 0),
    @('c/c, dark check TIMEOUT', $true, (HRun), (HIt 'GARBLED' 'GARBLED' 'TIMEOUT'), $false, 4),
    @('c/c, dark check LIGHT_NOW', $true, (HRun), (HIt 'GARBLED' 'GARBLED' 'LIGHT_NOW'), $false, 4),
    @('record not VALID', $false, (HRun), (HIt 'GARBLED' 'GARBLED' 'DARK_NOW'), $false, 1),
    @('r2 NO-DISPLAY (exit 50)', $true, (HRun 'quad_vig' 50), (HIt 'GARBLED' 'GARBLED' 'DARK_NOW'), $false, 1),
    @('a split_probe commit (never allowed)', $true, (HRun 'split_probe'), (HIt 'GARBLED' 'GARBLED' 'DARK_NOW'), $false, 1),
    @('unclean close', $true, (HRun 'quad_vig' 0 $true $false), (HIt 'GARBLED' 'GARBLED' 'DARK_NOW'), $false, 1),
    @('no run facts', $true, $null, (HIt 'GARBLED' 'GARBLED' 'DARK_NOW'), $false, 1))
foreach ($hc in $hcases) {
    $d = Get-Fs3cR3Decision -R2Valid $hc[1] -R2Run $hc[2] -Items $hc[3] -Chal8 $H8
    Check "H $($hc[0]) -> $(if ($hc[4]) { 'run 3 requested' } else { "not requested (rule $($hc[5]))" })" ($d.Allow -eq $hc[4] -and $d.Rule -eq $hc[5]) "$($d.Allow) $($d.Why)"
}
$it = HIt 'GARBLED' 'GARBLED' 'DARK_NOW'; $it['bars_left'] = [pscustomobject]@{ Obs = 'BARS'; Bars = '00'; Chars = ''; Key = '-' }
Check 'H layout items never affect the rule (bars 00 recorded, still requested)' ((Get-Fs3cR3Decision -R2Valid $true -R2Run (HRun) -Items $it -Chal8 $H8).Allow)
$x = T3Run 'h-r2-nodisplay' @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; Code = 50 }) $true ($KR1 + $KR2CB)
Check 'H session: r2 NO-DISPLAY (no quad accepted) with garbled readings -> not the run-3 path: the bars are asked (no Q7 fallback); no run 3 (rule 1), fs-done; the reason printed only after the readings' `
    ((T3Clean $x) -and -not (T3Sent $x 'r3') -and $x.R.R3Rule.Rule -eq 1 -and $x.R.DoneSent -and (T3Obs $x 'r2' 'bars_left') -ceq 'BARS' -and (T3Obs $x 'r2' 'bars_right') -ceq 'BARS' -and $null -eq (T3Ph $x 'r2').Q7Fallback -and
     [array]::FindIndex([string[]]$x.Ui.Transcript, [Predicate[string]]{ param($l) $l -match '^RUN 3 NOT REQUESTED' }) -gt [array]::FindIndex([string[]]$x.Ui.Transcript, [Predicate[string]]{ param($l) $l -ceq 'READINGS COMPLETE FOR RUN 2' })) (T3Desc $x)

# ------------------------------------------------------------------ I --------
Say '== I. guards (G = PHASE_WORST + 5 + PostMin + DoneReserve 3)'
$cf = New-Fs3cCfg -NonceX ('0' * 16)
Check 'I1 guards p0 34, r1 68, r2 82, r3 64 s; PHASE_WORST 23/38/47/39 (build review); DoneReserve 3 in every guard; give-up = 200 - 15 = 185 s' `
    ($cf.GuardSec['p0'] -eq 34 -and $cf.GuardSec['r1'] -eq 68 -and $cf.GuardSec['r2'] -eq 82 -and $cf.GuardSec['r3'] -eq 64 -and $cf.PhaseWorstSec['p0'] -eq 23 -and $cf.PhaseWorstSec['r1'] -eq 38 -and $cf.PhaseWorstSec['r2'] -eq 47 -and $cf.PhaseWorstSec['r3'] -eq 39 -and $cf.DoneReserveSec -eq 3 -and $cf.GiveUpMs -eq 185000 -and
     @('p0', 'r1', 'r2', 'r3' | Where-Object { $cf.GuardSec[$_] -lt $cf.PhaseWorstSec[$_] + 5 + 3 }).Count -eq 0)
foreach ($ph in 'p0', 'r1', 'r2', 'r3') {
    $lim = 185000 - 1000 * $cf.GuardSec[$ph]
    $g1 = Test-Fs3cGuard -Cfg $cf -PhX $ph -NowMs $lim; $g2 = Test-Fs3cGuard -Cfg $cf -PhX $ph -NowMs ($lim + 1000)
    Check "I2 $($ph): admitted at its limit (send at $($lim / 1000) s, left = G), refused 1 s later (left = G - 1 s)" ($g1.Ok -and -not $g2.Ok -and $g2.Why -match "needs G = $($cf.GuardSec[$ph]) s")
}
foreach ($ph in 'r1', 'r2', 'r3') { Check "I3 the 3b counterexample: $ph sent at 144 s after BootStart is refused" (-not (Test-Fs3cGuard -Cfg $cf -PhX $ph -NowMs 144000).Ok) }
Check 'I3b p0 at 144 s (41 s left >= 34) would be admitted (the lit phases carry the larger guards)' ((Test-Fs3cGuard -Cfg $cf -PhX 'p0' -NowMs 144000).Ok)
$base = T3Run 'i-base' $SP3 $true ($KR1 + $KR2C + $KR3S) -GenName 'guard'
$T1 = (T3Ph $base 'r1').SendMs; $T2 = (T3Ph $base 'r2').SendMs; $T3 = (T3Ph $base 'r3').SendMs
Check 'I4 the base session sends p0, r1, r2, r3 (guards with the default give-up)' ((T3Clean $base) -and (T3Sent $base 'r3')) (T3Desc $base)
$gcases = @(
    @('r1', 68000, $SP1, $KR1, $true), @('r1', 67000, @(@{ Ph = 'p0' }), @(), $false),
    @('r2', 82000, $SP2, ($KR1 + $KR2C), $true), @('r2', 81000, $SP1, $KR1, $false),
    @('r3', 64000, $SP3, ($KR1 + $KR2C + $KR3S), $true), @('r3', 63000, $SP2, ($KR1 + $KR2C), $false))
foreach ($gc in $gcases) {
    $at = @{ r1 = $T1; r2 = $T2; r3 = $T3 }[$gc[0]]
    $x = T3Run "i-$($gc[0])-$($gc[1])" $gc[2] $true $gc[3] @{ GiveUpMs = [long]($at + $gc[1]) } -GenName 'guard'
    $p = T3Ph $x $gc[0]
    if ($gc[4]) { $ok = (T3Clean $x) -and (T3Sent $x $gc[0]) -and $p.GuardLeftMs -eq $p.GuardNeedMs }
    else { $ok = (T3Clean $x) -and -not (T3Sent $x $gc[0]) -and $p.NotRunWhy -match '^guard:' -and $p.GuardLeftMs -eq ($p.GuardNeedMs - 1000) -and $x.R.DoneSent }
    Check "I5 session: $($gc[0]) with $([long]($gc[1] / 1000)) s left at its send -> $(if ($gc[4]) { 'sent' } else { 'not sent (guard), fs-done' })" $ok "$(T3Desc $x) left=$($p.GuardLeftMs) need=$($p.GuardNeedMs)"
}
$trI = @($base.Ui.Transcript)
Check 'I6 countdown: each r1 prompt shows "N s left to keep RUN 2 possible", each r2 prompt "... RUN 3 possible" (3: no bars on the run-3 path, Q7), each r3 prompt the safe-finish cut-off' `
    (@($trI | Where-Object { $_ -cmatch '^[0-9]+ s left to keep RUN 2 possible$' }).Count -eq 3 -and @($trI | Where-Object { $_ -cmatch '^[0-9]+ s left to keep RUN 3 possible$' }).Count -eq 3 -and
     @($trI | Where-Object { $_ -cmatch '^[0-9]+ s left before the safe-finish cut-off$' }).Count -eq 3)

# ------------------------------------------------------------------ J --------
Say '== J. the 110 s gap cap'
$kj = @('p:29000:d') + @(0..7 | ForEach-Object { "p:3500:{r1:$_}" }) + @('p:500:Enter', 'p:29000:d') + @(0..7 | ForEach-Object { "p:3500:{r1:$_}" })
$x = T3Run 'j-gapcap' $SP1 $true $kj
$p = T3Ph $x 'r1'; $tms = T3EvMs $x 'reading p=r1 item=chars_right key=- obs=TIMEOUT'
Check 'J1 prompts close at last_phase_end + 110 s at the latest: the right-eye character entry is cut at the gap cap (TIMEOUT), then fs-done' `
    ((T3Clean $x) -and (T3Obs $x 'r1' 'chars_right') -ceq 'TIMEOUT' -and ($tms - $p.EndMs) -ge 110000 -and ($tms - $p.EndMs) -le 110100 -and $x.R.DoneSent) "$(T3Desc $x) t=$($tms - $p.EndMs)"
Check 'J2 IDLE_S 120 s >= the host gap cap 110 s + 10 s' ($cf.IdleSec -ge $cf.GapCapSec + 10)

# ------------------------------------------------------------------ K --------
Say '== K. lost record / idle path: nothing is sent'
$x = T3Run 'k1-trunc' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Rec = 'trunc' }) $false @()
$p = T3Ph $x 'r1'
$sum = (Write-Fs3cSummary $x.R) -join "`n"
Check 'K1 r1 record cut (no completion by send + PHASE_WORST + 5 s = 43 s): no prompts, nothing more sent (no fs-done), INCONCLUSIVE; the PM is told to look away; the summary names the idle limit' `
    ((T3Clean $x) -and $p.State -cne 'complete' -and ($p.DeadlineMs - $p.SendMs) -eq 43000 -and -not $x.R.DoneSent -and @($x.R.Readings).Count -eq 0 -and $x.R.Status -ceq 'INCONCLUSIVE' -and
     @($x.Ui.Transcript | Where-Object { $_ -match 'NO RECORD FOR RUN 1 BY ITS DEADLINE' }).Count -eq 1 -and $sum -match 'idle limit \(120 s') (T3Desc $x)
$x = T3Run 'k2-noprompt' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Rec = 'noprompt' }) $false @()
Check 'K2 a complete record without a settled prompt: no prompts, no fs-done (state unknown)' ((T3Clean $x) -and (T3Ph $x 'r1').Prompt -cne 'prompt' -and -not $x.R.DoneSent -and @($x.R.Readings).Count -eq 0) (T3Desc $x)

# ------------------------------------------------------------------ L --------
Say '== L. FSB1-rejected slices'
$x = T3Run 'l1-r1-reject' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Rec = 'reject' }) $true @('p:1000:c', 'p:900:c', 'p:800:y')
Check 'L1 r1 record rejected (line-count): readings and dark check (light may have happened), no run 2, fs-done, COLLECTED-REJECTED' `
    ((T3Clean $x) -and (T3Ph $x 'r1').Fsb1Ok -eq $false -and (T3Ph $x 'r1').Fsb1Reason -ceq 'line-count' -and (T3Items $x 'r1') -ceq 'left=GARBLED,right=GARBLED,dark=DARK_NOW' -and -not (T3Sent $x 'r2') -and $x.R.DoneSent -and $x.R.Status -ceq 'COLLECTED-REJECTED') (T3Desc $x)
$L1 = $x
$x = T3Run 'l2-r2-reject' @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; Rec = 'reject' }) $true ($KR1 + @('p:1000:c', 'p:900:c', 'p:800:y'))
Check 'L2 r2 record rejected: per-eye readings and dark check only (no layout items), no run 3, fs-done' ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=GARBLED,right=GARBLED,dark=DARK_NOW' -and -not (T3Sent $x 'r3') -and $x.R.DoneSent) (T3Desc $x)
$x = T3Run 'l3-p0-reject' @(@{ Ph = 'p0'; Rec = 'reject' }) $true @()
Check 'L3 p0 record rejected: no prompts (nothing lit), no run 1, fs-done' ((T3Clean $x) -and @($x.R.Readings).Count -eq 0 -and -not (T3Sent $x 'r1') -and $x.R.DoneSent) (T3Desc $x)

# ------------------------------------------------------------------ M --------
Say '== M. FSXE1 refusals'
$x = T3Run 'm1-r2-ran0' @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; Rec = 'ran0' }) $true $KR1
Check 'M1 r2 FSXE1 ran=0 (nothing ran): no prompts for r2, fs-done, COLLECTED-REJECTED' ((T3Clean $x) -and (T3Items $x 'r2') -ceq '' -and (T3Ph $x 'r2').Refusal.Ran -eq 0 -and $x.R.DoneSent -and $x.R.Status -ceq 'COLLECTED-REJECTED') (T3Desc $x)
$x = T3Run 'm2-r1-ran1' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Rec = 'ran1' }) $true @('p:1000:a', 'p:900:a', 'p:800:y')
Check 'M2 r1 FSXE1 ran=1 after begin/go/end markers: START/END fired, readings and dark check, no run 2, fs-done' `
    ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'left=LIT,right=LIT,dark=DARK_NOW' -and -not (T3Sent $x 'r2') -and $x.R.DoneSent -and (@((T3Ph $x 'r1').Markers | ForEach-Object { ($_ -split '@')[0] }) -join ',') -ceq 'begin,go,end' -and
     @($x.R.SoundsPlayed | Where-Object { $_ -like 'END@*' }).Count -eq 1) (T3Desc $x)
$x = T3Run 'm4-p0-ran1' @(@{ Ph = 'p0'; Rec = 'ran1'; Error = 'record-too-large'; RefusalLine = 'FSXE1 p=p0 ran=1 error=record-too-large lines=400 max=360 END' }) $true @()
Check 'M4 p0 FSXE1 ran=1 record-too-large lines=400 max=360: no prompts, no run 1, fs-done' ((T3Clean $x) -and @($x.R.Readings).Count -eq 0 -and (T3Ph $x 'p0').Refusal.Error -ceq 'record-too-large' -and -not (T3Sent $x 'r1') -and $x.R.DoneSent) (T3Desc $x)
$x = T3Run 'm5-noran' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Rec = 'ran1'; RefusalLine = 'FSXE1 p=r1 error=step2 END' }) $true @('p:1000:b', 'p:900:b', 'p:800:y')
Check 'M5 an FSXE1 without a readable ran= is treated as ran=1 (light may have happened): readings and dark check, fs-done' ((T3Clean $x) -and (T3Ph $x 'r1').Refusal.Ran -eq 1 -and (T3Items $x 'r1') -ceq 'left=DARK,right=DARK,dark=DARK_NOW' -and $x.R.DoneSent) (T3Desc $x)
Check 'M6 Get-Fs3cRefusalInfo: p=- ran=0 usage; ran=1 record-too-large lines=N max=M; not an FSXE1 record -> $null' `
    ((Get-Fs3cRefusalInfo 'FSXE1 p=- ran=0 error=usage END').Ran -eq 0 -and (Get-Fs3cRefusalInfo 'FSXE1 p=r2 ran=1 error=record-too-large lines=1546 max=1545 END').Error -ceq 'record-too-large' -and
     $null -eq (Get-Fs3cRefusalInfo 'FSXE1 p=r2 ran=1 error=x') -and $null -eq (Get-Fs3cRefusalInfo 'FSDE1 error=x END'))

# ------------------------------------------------------------------ N --------
Say '== N. stray bytes during the prompts'
$x = T3Run 'n1-stray' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Stray = "`nstray kernel text`n~ # "; StrayMs = 2000 }) $false @('p:1500:b', 'p:900:b', 'p:800:y')
Check 'N1 bytes after the settled prompt during the prompts: the prompt in progress is finished, no new prompt (dark NOT_ASKED), no run 2; fs-done refused by the send gate (bytes after the settled prompt)' `
    ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'left=DARK,right=DARK,dark=NOT_ASKED' -and (T3Ph $x 'r1').GapSafe -ceq 'stray' -and -not $x.R.DoneSent -and $x.R.DoneReply -match 'arrived after the settled prompt' -and -not (T3Sent $x 'r2')) (T3Desc $x)

# ------------------------------------------------------------------ O --------
Say '== O. FSPM1 markers'
$a = $CAN['nominal-read']
$snames = @($a.R.SoundsPlayed | ForEach-Object { ($_ -split '@')[0] }) -join ','
Check 'O1 sounds at the right events: START (LOOK cue after p0), START at r1 go, END at r1 end, ANSWER, START/END for r2, ANSWER, FINISH at fs-done' ($snames -ceq 'START,START,END,ANSWER,START,END,ANSWER,FINISH') $snames
Check 'O2 banners at go/end (RUN n STARTING - LOOK, black on yellow; RUN n ENDED, black on green); begin/rec log only' `
    (@($a.Ui.Transcript | Where-Object { $_ -ceq '[BANNER look] RUN 1 STARTING - LOOK | keep looking into the lenses until RUN ENDED' }).Count -eq 1 -and @($a.Ui.Transcript | Where-Object { $_.StartsWith('[BANNER ended] RUN 2 ENDED') }).Count -eq 1 -and
     @($a.Ui.Transcript | Where-Object { $_ -match '(^|[^a-z])(begin|rec)([^a-z]|$)' -and $_.StartsWith('[BANNER') }).Count -eq 0)
$NX = $script:G3Nonce
$bad = @("FSPM1 n=$NX p=r1 e=begin t=60000 END", "FSPM1 n=ffffffffffffffff p=r1 e=go t=62000 END", "FSPM1 n=$NX p=r1 e=gone t=62000 END", "FSPM1 n=$NX p=r2 e=end t=65000 END", "FSPM1 n=$NX p=r1 e=rec t=67000 END")
$x = T3Run -Tag 'o3-badmarkers' -Spec @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Markers = $bad }, @{ Ph = 'r2' }) -Done $true -Keys ($KR1 + $KX)
$p = T3Ph $x 'r1'
Check 'O3 a wrong-nonce, malformed or other-phase marker is logged and ignored (no banner, no sound); the record is still VALID and the session continues' `
    ((T3Clean $x) -and (@($p.Markers | ForEach-Object { ($_ -split '@')[0] }) -join ',') -ceq 'begin,rec' -and @($p.MarkerNotes).Count -eq 3 -and $p.Fsb1Ok -and
     @($x.R.SoundsPlayed | Where-Object { $_ -like 'END@*' }).Count -eq 1 -and (T3Sent $x 'r2')) "$(T3Desc $x) notes=$(@($p.MarkerNotes) -join ';')"
$x = T3Run -Tag 'o4-split' -Spec @(@{ Ph = 'p0' }, @{ Ph = 'r1'; SplitMarkers = $true }, @{ Ph = 'r2' }) -Done $true -Keys ($KR1 + $KX)
Check 'O4 markers split across reads are reassembled (begin, go, end, rec; START and END fired)' ((T3Clean $x) -and (@((T3Ph $x 'r1').Markers | ForEach-Object { ($_ -split '@')[0] }) -join ',') -ceq 'begin,go,end,rec' -and @($x.R.SoundsPlayed | Where-Object { $_ -like 'START@*' }).Count -ge 3) (T3Desc $x)
$x = T3Run 'o5-skip' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Skip = 'brightness-not-verified'; Markers = 'skip' }, @{ Ph = 'r2'; Skip = 'run1-not-run'; Markers = 'skip' }) $true ($KR1 + $KR1)
Check 'O5 a skip marker shows RUN n SKIPPED (neutral, no reason before the readings); no START/END for that run' `
    ((T3Clean $x) -and @($x.Ui.Transcript | Where-Object { $_ -ceq '[BANNER info] RUN 1 SKIPPED | nothing is shown in this run' }).Count -eq 1 -and @($x.R.SoundsPlayed | Where-Object { $_ -like 'END@*' }).Count -eq 0 -and $x.R.R3Rule.Rule -eq 1) (T3Desc $x)
$O5 = $x
$mOk = ConvertFrom-Fs3cMarker -Line "FSPM1 n=$NX p=r2 e=go t=123456 END" -NonceX $NX
$mMax = "FSPM1 n=$NX p=r3 e=begin t=999999999999 END"
$mcases = @(
    @('valid go', "FSPM1 n=$NX p=r2 e=go t=123456 END", $true), @('t with 13 digits', "FSPM1 n=$NX p=r2 e=go t=1234567890123 END", $false),
    @('unknown event', "FSPM1 n=$NX p=r2 e=done t=1 END", $false), @('upper-case nonce', "FSPM1 n=$($NX.ToUpperInvariant()) p=r2 e=go t=1 END", $false),
    @('trailing space', "FSPM1 n=$NX p=r2 e=go t=1 END ", $false), @('phase r4', "FSPM1 n=$NX p=r4 e=go t=1 END", $false),
    @('no END', "FSPM1 n=$NX p=r2 e=go t=1", $false), @('negative t', "FSPM1 n=$NX p=r2 e=go t=-1 END", $false), @('a CR inside', "FSPM1 n=$NX p=r2`r e=go t=1 END", $false))
foreach ($mc in $mcases) { $m = ConvertFrom-Fs3cMarker -Line $mc[1] -NonceX $NX; Check "O6 FSPM1 grammar: $($mc[0]) -> $(if ($mc[2]) { 'accepted' } else { 'ignored' })" ($m.Ok -eq $mc[2]) $m.Why }
Check "O7 the longest marker the grammar allows is $($mMax.Length + 1) bytes with its newline (<= 64), never contains FSB1; a 65-byte line is refused" `
    ($mOk.E -ceq 'go' -and $mOk.T -eq 123456 -and ($mMax.Length + 1) -le 64 -and (ConvertFrom-Fs3cMarker -Line $mMax -NonceX $NX).Ok -and -not ($mMax.Contains('FSB1')) -and -not (ConvertFrom-Fs3cMarker -Line $mMax -NonceX $NX -RawLength 65).Ok)

# ------------------------------------------------------------------ P --------
Say '== P. sounds, the fallback, the sound check'
$okw = $true; $durs = @{}
foreach ($k in $script:T3Snd.Keys) {
    $b = $script:T3Snd[$k].Bytes
    $hdr = [System.Text.Encoding]::ASCII.GetString($b, 0, 4) + [System.Text.Encoding]::ASCII.GetString($b, 8, 4)
    $rate = [BitConverter]::ToInt32($b, 24); $bits = [BitConverter]::ToInt16($b, 34); $chn = [BitConverter]::ToInt16($b, 22); $dl = [BitConverter]::ToInt32($b, 40)
    $durs[$k] = [Math]::Round($dl / 88200.0, 2)
    if ($hdr -cne 'RIFFWAVE' -or $rate -ne 44100 -or $bits -ne 16 -or $chn -ne 1 -or $dl -ne $b.Length - 44 -or $script:T3Snd[$k].Sha256 -cne (Get-FsSha256Hex $b)) { $okw = $false }
}
Check 'P1 five in-memory WAVs (no files): RIFF/WAVE, PCM 16-bit, 44.1 kHz, mono; START 0.4 s, END 0.6 s, ANSWER 0.5 s, FINISH 1.0 s, ALARM 0.9 s; SHA-256 recorded' `
    ($okw -and @($script:T3Snd.Keys) -join ',' -ceq 'START,END,ANSWER,FINISH,ALARM' -and $durs['START'] -eq 0.4 -and $durs['END'] -eq 0.6 -and $durs['ANSWER'] -eq 0.5 -and $durs['FINISH'] -eq 1.0 -and $durs['ALARM'] -eq 0.9) ($durs | Out-String)
$sj = Get-Content -Raw (Join-Path $CAN['garbled-r3'].Out 'session.json') | ConvertFrom-Json
Check 'P2 session.json carries each WAV''s SHA-256 (equal to a fresh generation: deterministic)' ($sj.Sounds.START.Sha256 -ceq $script:T3Snd['START'].Sha256 -and $sj.Sounds.ALARM.Sha256 -ceq (New-Fs3cSounds)['ALARM'].Sha256)
$x = T3Run 'p3-soundfail' $SP2 $true ($KR1 + $KX) -Player { param($s, $n) throw 'simulated SoundPlayer failure' } -GenName 'p3'
Check 'P3 SoundPlayer.Play throws: the fallback (SystemSounds.Exclamation + bell) runs for every sound, each failure is logged in session.json, the session is unaffected' `
    ((T3Clean $x) -and @($x.R.SoundFailures).Count -ge 5 -and @($x.Sink.Played | Where-Object { $_ -like 'fallback:*' }).Count -eq @($x.R.SoundFailures).Count -and $x.R.DoneSent -and (T3Sent $x 'r2')) (T3Desc $x)
$live = New-Fs3cSoundSink -Kind live -Sounds $script:T3Snd -Player { param($s, $n) throw 'no audio device' } -Fallback { param($s, $n) $s.Played.Add("fb:$n") }
$live.Play('END', 5)
Check 'P4 a live sink with a failing player records the failure and calls the fallback (asynchronous Play, never PlaySync: static)' (@($live.Failures).Count -eq 1 -and @($live.Played) -contains 'fb:END' -and
    ([IO.File]::ReadAllText((Join-Path $T3Dir 'fs-session3c.ps1'))) -match '\.Play\(\)' -and ([IO.File]::ReadAllText((Join-Path $T3Dir 'fs-session3c.ps1'))) -notmatch 'PlaySync\(')
function T3SoundCheck([string[]]$keys, [int]$seed = 7, [int]$to = 30) {
    $ui = New-Fs3cUi -Kind record; $ks = New-Fs3cScriptedKeySource -Script $keys; $sk = New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd
    $xx = New-Fs3cInteract -Ui $ui -Keys $ks -Sound $sk -PollMsX 5
    Invoke-Fs3cSoundCheck -X $xx -Sounds $script:T3Snd -Seed $seed -TimeoutSec $to
}
$rng = New-Object System.Random 7; $names = @($script:T3Snd.Keys); $picks = @(1..3 | ForEach-Object { $names[$rng.Next(0, $names.Count)] })
$idk = @{ START = 's'; END = 'e'; ANSWER = 'a'; FINISH = 'f'; ALARM = 'l' }
$reach = @($script:Fs3cReachKeys)
$sk1 = @(1..5 | ForEach-Object { 'p:150:y' }) + @($picks | ForEach-Object { "p:150:$($idk[$_])" }) + @($reach | ForEach-Object { "p:150:$_" })
$sc = T3SoundCheck $sk1
Check 'P5 -SoundCheck pass: each sound named and heard (y), three unnamed sounds identified (s/e/a/f/l), the key-reach test a b c d x y n r p u s g i m v l 0 1 2 3 4 Esc e f 5 6 7 8 9 ? Enter Backspace (build review MINOR-6); WAV hashes recorded' `
    ($sc.Pass -and @($sc.Named).Count -eq 5 -and @($sc.Blind | Where-Object { $_.Ok }).Count -eq 3 -and @($sc.Reach | Where-Object { $_.Ok }).Count -eq 32 -and $sc.Sounds.FINISH.Sha256 -ceq $script:T3Snd['FINISH'].Sha256) $sc.Why
$sc = T3SoundCheck (@('p:150:y', 'p:150:n') + @(1..3 | ForEach-Object { 'p:150:y' }) + @($picks | ForEach-Object { "p:150:$($idk[$_])" }) + @($reach | ForEach-Object { "p:150:$_" }))
Check 'P6 -SoundCheck fail: a sound not heard' (-not $sc.Pass)
$wrong = @($picks | ForEach-Object { if ($idk[$_] -ceq 's') { 'p:150:e' } else { 'p:150:s' } })
$sc = T3SoundCheck (@(1..5 | ForEach-Object { 'p:150:y' }) + $wrong + @($reach | ForEach-Object { "p:150:$_" }))
Check 'P7 -SoundCheck fail: an unnamed sound misidentified' (-not $sc.Pass -and @($sc.Blind | Where-Object { -not $_.Ok }).Count -eq 3)
$sc = T3SoundCheck (@(1..5 | ForEach-Object { 'p:150:y' }) + @($picks | ForEach-Object { "p:150:$($idk[$_])" }) + @('p:150:a', 'p:150:q', 'p:150:b') + @($reach | Select-Object -Skip 2 | ForEach-Object { "p:150:$_" }))
Check 'P8 -SoundCheck key reach: a wrong key is a recorded miss, the same key is asked again; still a pass' ($sc.Pass -and @($sc.ReachMisses) -contains 'b<-q')
$sc = T3SoundCheck (@(1..5 | ForEach-Object { 'p:150:y' }) + @($picks | ForEach-Object { "p:150:$($idk[$_])" }) + @('p:150:a')) -to 1
Check 'P9 -SoundCheck key reach: a key not pressed in time fails the check (nothing is booted)' (-not $sc.Pass -and @($sc.Reach | Where-Object { -not $_.Ok }).Count -ge 1)

# ------------------------------------------------------------------ Q --------
Say '== Q. classifier: re-slicing, CLI'
foreach ($cn in 'nominal-read', 'garbled-r3') {
    $o = $CAN[$cn].Out
    [byte[]]$raw = [IO.File]::ReadAllBytes((Join-Path $o 'capture.raw'))
    $sl = Get-Fs3cSlices -Raw $raw -Events (Read-Fs3cIndexEvents -Path (Join-Path $o 'capture.raw.idx') -RawLength $raw.Length)
    $sj = Get-Content -Raw (Join-Path $o 'session.json') | ConvertFrom-Json
    $eq = ($sl.Count -eq @($sj.Slices).Count)
    for ($i = 0; $eq -and $i -lt $sl.Count; $i++) { $eq = ($sl[$i].Start -eq [long]$sj.Slices[$i].Start -and $sl[$i].End -eq [long]$sj.Slices[$i].End -and $sl[$i].Sha256 -ceq [string]$sj.Slices[$i].Sha256 -and $sl[$i].How -ceq 'phase-end') }
    $files = ($sl.Count -gt 0 -and @($sl | Where-Object { (Get-FsSha256Hex ([IO.File]::ReadAllBytes((Join-Path $o "phase-$($_.Ph).raw")))) -cne $_.Sha256 }).Count -eq 0)
    Check "Q1 $($cn): the classifier's slices (W offset .. phase-end N line) equal the collector's; phase-<ph>.raw files carry them" ($eq -and $files)
}
$q = Invoke-Fs3cClassifyDir -DirX $CAN['nominal-read'].Out -S1X 'PASS' -PinX $script:G3Pin
Check 'Q2 nominal: P0 OK, R1 SHOWN, R2 SHOWN-QUAD [quad_vig], r3 NOT RUN; OUTCOME PASS (machine side); REGISTERED STAGE PASS; code 10' `
    ($q.Code -eq 10 -and $q.Outcome.Phases['p0'].Class -ceq 'P0 OK' -and $q.Outcome.Phases['r2'].Class -ceq 'R2 SHOWN-QUAD' -and $q.Outcome.Phases['r2'].Tag -ceq 'quad_vig' -and $q.Outcome.Phases['r3'].Class -ceq 'NOT RUN' -and
     ($q.Lines -join "`n") -match 'REGISTERED: STAGE PASS: machine PASS \(machine side\) \(layout quad_vig\)') ($q.Lines -join ' / ')
$q = Invoke-Fs3cClassifyDir -DirX $CAN['garbled-r3'].Out -S1X 'PASS' -PinX $script:G3Pin
Check 'Q3 garbled path: R3 SHOWN-QUAD-SOLID with the run-3 rule held; interpretation T2 [C]; REGISTERED not a stage PASS ... R2 optical LIT BUT GARBLED; R3 ... -> interpretation T2 [C]' `
    ($q.Code -eq 10 -and $q.Outcome.Phases['r3'].Class -ceq 'R3 SHOWN-QUAD-SOLID' -and $q.Outcome.Interpretation.Code -ceq 'T2' -and ($q.Lines -join "`n") -match 'REGISTERED: not a stage PASS: machine PASS \(machine side\) \(layout quad_vig\); SCANOUT TE 181/s BLU 181/s .*R2 optical LIT BUT GARBLED; R3 left=SAME_AS_R2 right=SAME_AS_R2 -> interpretation T2 \[C\]') ($q.Lines -join ' / ')
Check 'Q3b Q7 fallback: the classifier treats the bars not asked on the run-3 path as expected: no LAYOUT line, one READINGS NOTE, no INCONCLUSIVE, optical and outcome unchanged' `
    ($q.Code -eq 10 -and @($q.Lines | Where-Object { $_ -like 'LAYOUT*' }).Count -eq 0 -and @($q.Lines | Where-Object { $_ -ceq 'READINGS NOTE: r2 bars_left, bars_right not asked (Q7 fallback: the run-3 path; DESIGN 15 Q7)' }).Count -eq 1 -and
     $q.Outcome.ReadingsOk -and $q.Outcome.Optical['r2'].Class -ceq 'LIT BUT GARBLED' -and @($q.Outcome.Layout.Keys).Count -eq 0) ($q.Lines -join ' / ')
$td = Join-Path $Scratch 'q-tamper'; Copy-Item -Recurse -LiteralPath $CAN['garbled-r3'].Out -Destination $td
$sjt = Get-Content -Raw (Join-Path $td 'session.json') | ConvertFrom-Json; $sjt.Slices[1].End = [long]$sjt.Slices[1].End - 1
[IO.File]::WriteAllText((Join-Path $td 'session.json'), ($sjt | ConvertTo-Json -Depth 8))
$q = Invoke-Fs3cClassifyDir -DirX $td -S1X 'PASS' -PinX $script:G3Pin
Check 'Q4 a session.json whose slices differ from the re-derived ones: refused, INCONCLUSIVE (code 14)' ($q.Code -eq 14 -and ($q.Lines -join "`n") -match 'slices re-derived .* differ') ($q.Lines -join ' / ')
$od = Join-Path $Scratch 'q-observe'; $null = New-Item -ItemType Directory -Force -Path $od
[IO.File]::WriteAllText((Join-Path $od 'observe.json'), (([pscustomobject]@{ Stage = '3c'; Nonce = $script:G3Nonce; HandoffClass = 'HANDOFF_ACKNOWLEDGED'; GadgetSeen = $true }) | ConvertTo-Json))
$cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $T3Dir 'fs-classify3c.ps1') -C3cDir $CAN['nominal-read'].Out -C3cObserveDir $od -C3cPatternPin $script:G3Pin
$code = $LASTEXITCODE
Check 'Q5 fs-classify3c.ps1 CLI with -C3cObserveDir: STAGE-1 CLASS PASS (derived), OUTCOME PASS (machine side), exit 10' ($code -eq 10 -and ($cl -join "`n") -match 'STAGE-1 CLASS: PASS' -and ($cl -join "`n") -match 'OUTCOME: PASS \(machine side\)') "exit $code $($cl -join ' / ')"
$cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $T3Dir 'fs-classify3c.ps1') -C3cDir $CAN['nominal-read'].Out -C3cStage1Class PASS
$code = $LASTEXITCODE
Check 'Q6 ...without -C3cPatternPin: the built-in v0.6 pin (066bdc3e...27bc, the build-review rebuild) is used; the fixture digest differs -> p0 INTEGRITY FAULT, exit 12' ($code -eq 12 -and ($cl -join "`n") -match "PHASE p0 : INTEGRITY FAULT - hash: fs-pattern digest $($script:G3Pin) != pin $($script:S3cPatternPin)" -and $script:S3cPatternPin -ceq '066bdc3ee01e5974518f96e8311c071c8f3aed302cadefa42c1273d5196b27bc') "exit $code"
$q = Invoke-Fs3cClassifyDir -DirX $D3.Out -S1X 'PASS' -PinX $script:G3Pin
Check 'Q7 n at the dark check -> LABEL RETAINED-FRAME OBSERVATION (safety-relevant finding)' (@($q.Outcome.Labels | Where-Object { $_ -match '^RETAINED-FRAME OBSERVATION after run 1 \(dark' }).Count -eq 1) ($q.Lines -join ' / ')
$q = Invoke-Fs3cClassifyDir -DirX $L1.Out -S1X 'PASS' -PinX $script:G3Pin
Check 'Q8 an FSB1-rejected r1: r1 INCONCLUSIVE (FSB1 rejected: line-count), r1 optical LIT BUT GARBLED, session INCONCLUSIVE' ($q.Outcome.Phases['r1'].Reason -match 'FSB1 rejected: line-count' -and $q.Outcome.Optical['r1'].Class -ceq 'LIT BUT GARBLED' -and $q.Code -eq 14)
$q = Invoke-Fs3cClassifyDir -DirX $O5.Out -S1X 'PASS' -PinX $script:G3Pin
Check 'Q9 the skip session: r1 SKIPPED, session INCONCLUSIVE; markers begin,skip,rec reported' ($q.Outcome.Phases['r1'].Class -ceq 'SKIPPED' -and $q.Code -eq 14 -and ($q.Lines -join "`n") -match 'markers: begin,skip,rec')

# ------------------------------------------------------------------ R --------
Say '== R. FSR2 records, timestamps, no machine facts before the readings'
$allR = @(); foreach ($k in $CAN.Keys) { $allR += @($CAN[$k].R.Readings) }
Check "R1 every FSR2 line ($($allR.Count)) matches the DESIGN 8.5 grammar and parses; readings3c.txt equals session.json Readings" `
    (@($allR | Where-Object { $_ -cnotmatch $script:S3cFsr2Re }).Count -eq 0 -and $allR.Count -gt 20 -and
     ([IO.File]::ReadAllText((Join-Path $CAN['garbled-r3'].Out 'readings3c.txt'))) -ceq ((@($CAN['garbled-r3'].R.Readings) | ForEach-Object { "$_`n" }) -join ''))
$mono = $true
foreach ($k in $CAN.Keys) { $last = -1; foreach ($o in @($CAN[$k].R.ReadingObjs)) { if ($o.PromptMs -lt $last -or ($o.AnswerMs -ge 0 -and $o.AnswerMs -lt $o.PromptMs)) { $mono = $false }; $last = $o.PromptMs } }
Check 'R2 prompt_ms monotonic on the transport clock, answer_ms >= prompt_ms (or -1), UTC stamps ISO 8601' ($mono -and @($allR | Where-Object { $_ -cnotmatch 'prompt_utc=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z ' }).Count -eq 0)
$forbid = '(^|[^A-Za-z])([Cc]ommit|[Ll]ayout|[Qq]uad|[Tt]opology|VALID|[Vv]alid|REJECT|[Rr]eject|SHOWN|INCONCLUSIVE|NO-DISPLAY|expected|rule [0-9])([^A-Za-z]|$)|rc=|PASS|FSB1|sha256|1 [|] 2|3 [|] 4'
$leak = @()
foreach ($t in @($CAN['nominal-read'], $CAN['garbled-r3'], $CAN['r2-ran1-emit'], $L1)) {
    $tr = [string[]]$t.Ui.Transcript
    $li = -1; for ($i = 0; $i -lt $tr.Length; $i++) { if ($tr[$i] -like 'READINGS COMPLETE FOR RUN *') { $li = $i } }
    for ($i = 0; $i -lt $li; $i++) { if ($tr[$i] -cmatch $forbid) { $leak += $tr[$i] } }
}
Check 'R3 before the readings are complete the console shows no machine fact (no commit/rc/layout/topology/verdict, no record status, no expected bar order, no rule)' ($leak.Count -eq 0) ($leak -join ' | ')

# ------------------------------------------------------------------ S --------
Say '== S. classifier outcomes (synthetic records)'
$CH = @{ p0 = (Get-G3Hex 'S/p0' 32); r1 = (Get-G3Hex 'S/r1' 32); r2 = (Get-G3Hex 'S/r2' 32); r3 = (Get-G3Hex 'S/r3' 32) }
function S3In([string]$ph, [hashtable]$o = @{}, [hashtable]$f = @{}) {
    $st = Get-G3Steps -Ph $ph -Chal $CH[$ph] -O $o
    $p = [ordered]@{ Ph = $ph; Sent = $true; NotRunWhy = ''; Refusal = $null; Complete = $true; Fsb1 = [pscustomobject]@{ Ok = $true; Reason = 'valid'; Detail = ''; Steps = $st }; Chal = $CH[$ph]; ChainOk = $true; R3RuleHeld = $true; Markers = $null }
    foreach ($k in $f.Keys) { $p[$k] = $f[$k] }
    [pscustomobject]$p
}
function SNot([string]$ph, [string]$why = 'not requested') { [pscustomobject]@{ Ph = $ph; Sent = $false; NotRunWhy = $why; Refusal = $null; Complete = $false; Fsb1 = $null; Chal = ''; ChainOk = $true; R3RuleHeld = $false; Markers = $null } }
function SOut($ins, [string[]]$rl = $null, [string]$pin = $script:G3Pin) { Get-Fs3cOutcome -S1Class 'PASS' -Phases $ins -ReadingLines $rl -Pin $pin }
function FsrL([string]$ph, [string]$item, [string]$obs, [string]$chars = '', [string]$bars = '', [string]$key = '-') {
    "FSR2 p=$ph item=$item key=$key obs=$obs" + $(if ($chars) { " chars=$chars" } else { '' }) + $(if ($bars) { " bars=$bars" } else { '' }) + ' prompt_ms=1000 answer_ms=2000 prompt_utc=2026-10-11T00:00:01.000Z answer_utc=2026-10-11T00:00:02.000Z discarded=0' }
$SG = @((S3In 'p0'), (S3In 'r1'), (S3In 'r2'), (SNot 'r3'))
function SWith([int]$i, $p) { $l = @($SG); $l[$i] = $p; ,$l }
$scases = @(
    @('S01 p0, r1, r2 good (quad_vig)', $SG, 'PASS (machine side)', @{ r2 = 'R2 SHOWN-QUAD' }),
    @('S02 quad_vig rejected, quad_dma committed (115/134/112/131)', (SWith 2 (S3In 'r2' @{ Layout = 'quad_dma' })), 'PASS (machine side)', @{ r2 = 'R2 SHOWN-QUAD' }),
    @('S03 p0 hash is not the v0.6 pin', (SWith 0 (S3In 'p0' @{ Pin = ('0' * 64) })), 'INTEGRITY FAULT', @{ p0 = 'INTEGRITY FAULT' }),
    @('S03b p0 hash not the pin AND two write lines: INTEGRITY FAULT first (build review MINOR-1, the 3b order)', (SWith 0 (S3In 'p0' @{ Pin = ('0' * 64); TwoWrites = $true })), 'INTEGRITY FAULT', @{ p0 = 'INTEGRITY FAULT' }),
    @('S04 p0 two write lines (runner inconsistency)', (SWith 0 (S3In 'p0' @{ TwoWrites = $true })), 'INCONCLUSIVE', @{ p0 = 'INCONCLUSIVE' }),
    @('S05 p0 read-back 255', (SWith 0 (S3In 'p0' @{ Readback = '255' })), 'INCONCLUSIVE', @{ p0 = 'BRIGHTNESS NOT VERIFIED' }),
    @('S06 r1 skipped', (SWith 1 (S3In 'r1' @{ Skip = 'probe-late' })), 'INCONCLUSIVE', @{ r1 = 'SKIPPED' }),
    @('S07 r1 unclean close, r2 skipped', @((S3In 'p0'), (S3In 'r1' @{ CloseRc = '-5' }), (S3In 'r2' @{ Skip = 'run1-close-not-clean' }), (SNot 'r3')), 'RUN 1 ONLY', @{ r1 = 'R1 SHOWN, UNCLEAN CLOSE'; r2 = 'SKIPPED' }),
    @('S08 r1 unclean close but r2 executed (runner inconsistency)', (SWith 1 (S3In 'r1' @{ CloseRc = '-5' })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S09 r2 exit 50: no quad attempt accepted (split probe accepted, never committed)', (SWith 2 (S3In 'r2' @{ Code = 50 })), 'RUN 1 ONLY', @{ r2 = 'NO-DISPLAY' }),
    @('S10 r2 exit 31: CRTC still active', (SWith 2 (S3In 'r2' @{ Code = 31 })), 'RUN 1 ONLY', @{ r2 = 'PRECONDITION UNMET: CRTC ACTIVE' }),
    @('S11 r2 real commit with layout split_probe (runner inconsistency)', (SWith 2 (S3In 'r2' @{ SplitCommit = $true })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S12 r2 post_plane zpos 0/0/1/0 (runner inconsistency)', (SWith 2 (S3In 'r2' @{ ZposPost = $true })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S13 r2 quad_vig on max_upscale 1 planes (type mismatch: runner inconsistency)', (SWith 2 (S3In 'r2' @{ TypeDma = $true })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S14 r2 CRTC_X unconverted 2064/3096 (a finding, not an inconsistency)', (SWith 2 (S3In 'r2' @{ Unconverted = $true })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S14r3 r2 CRTC_X unconverted (the finding) and r3 run under the rule: r3 classified on the gate facts (R3 SHOWN-QUAD-SOLID), not a runner inconsistency (build review MAJOR-3)', @((S3In 'p0'), (S3In 'r1'), (S3In 'r2' @{ Unconverted = $true }), (S3In 'r3')), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE'; r3 = 'R3 SHOWN-QUAD-SOLID' }),
    @('S15 r2 pause 1466 ms (< 2000)', (SWith 2 (S3In 'r2' @{ StartMs = [long]25000 })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S16 r1 plan carries zpos_set (zpos outside a quad attempt)', (SWith 1 (S3In 'r1' @{ Zpos = $true })), 'INCONCLUSIVE', @{ r1 = 'INCONCLUSIVE' }),
    @('S17 a backlight write line in probe2', (SWith 2 (S3In 'r2' @{ ProbeWrite = $true })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S18 r2 chain mismatch', (SWith 2 (S3In 'r2' @{} @{ ChainOk = $false })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S19 r3 run under the rule', @((S3In 'p0'), (S3In 'r1'), (S3In 'r2'), (S3In 'r3')), 'PASS (machine side)', @{ r3 = 'R3 SHOWN-QUAD-SOLID' }),
    @('S20 r3 run although the rule did not hold', @((S3In 'p0'), (S3In 'r1'), (S3In 'r2'), (S3In 'r3' @{} @{ R3RuleHeld = $false })), 'INCONCLUSIVE', @{ r3 = 'INCONCLUSIVE' }),
    @('S21 r3 mode show-off-quad (not show-off-solid)', @((S3In 'p0'), (S3In 'r1'), (S3In 'r2'), (S3In 'r3' @{ Mode = 'show-off-quad' })), 'PASS (machine side)', @{ r3 = 'INCONCLUSIVE' }),
    @('S22 r3 after an r2 that did not commit (runner inconsistency)', @((S3In 'p0'), (S3In 'r1'), (S3In 'r2' @{ Code = 50 }), (S3In 'r3')), 'INCONCLUSIVE', @{ r3 = 'INCONCLUSIVE' }),
    @('S23 r2 refused ran=0', (SWith 2 ([pscustomobject]@{ Ph = 'r2'; Sent = $true; NotRunWhy = ''; Refusal = (Get-Fs3cRefusalInfo 'FSXE1 p=r2 ran=0 error=time END'); Complete = $true; Fsb1 = $null; Chal = $CH['r2']; ChainOk = $true; R3RuleHeld = $false; Markers = $null })), 'INCONCLUSIVE', @{ r2 = 'REFUSED' }),
    @('S24 r1 timer-kill (hang), r2 skipped', @((S3In 'p0'), (S3In 'r1' @{} @{ Fsb1 = [pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = @((Get-G3Steps -Ph 'r1' -Chal $CH['r1'] -O @{})[0], (New-SynthStep 2 'pattern1' @() @() @{ end = 'timer-kill'; code = [long]-1; sig = [long]9; term_ms = [long]9000; kill_ms = [long]12000 })) } }), (S3In 'r2' @{ Skip = 'run1-supervisor' }), (SNot 'r3')), 'DISPLAY FAIL', @{ r1 = 'DISPLAY FAIL'; r2 = 'SKIPPED' }),
    @('S25 r2 FSB1 rejected', (SWith 2 (S3In 'r2' @{} @{ Fsb1 = [pscustomobject]@{ Ok = $false; Reason = 'rec-hash'; Detail = ''; Steps = $null } })), 'INCONCLUSIVE', @{ r2 = 'INCONCLUSIVE' }),
    @('S26 r2 not run (guard)', (SWith 2 (SNot 'r2' 'guard: 70 s left')), 'RUN 1 ONLY', @{ r2 = 'NOT RUN' }),
    @('S27 an empty -Pin falls back to the built-in v0.6 pin (3b convention): the fixture digest differs', $SG, 'INTEGRITY FAULT', @{ p0 = 'INTEGRITY FAULT' }))
foreach ($sc in $scases) {
    $pin = if ($sc[0] -like 'S27*') { '' } else { $script:G3Pin }
    $o = SOut $sc[1] $null $pin
    $ok = ($o.Outcome -ceq $sc[2]); foreach ($k in $sc[3].Keys) { if ($o.Phases[$k].Class -cne $sc[3][$k]) { $ok = $false } }
    if ($sc[0] -like 'S14*') { $ok = $ok -and @($o.Labels | Where-Object { $_ -match 'FINDING \(r2\).*unconverted' }).Count -eq 1 -and -not $o.Phases['r2'].Inconsistent -and -not $o.Phases['r3'].Inconsistent }
    if ($sc[0] -match '^S(04|08|11|12|13|15|16|17|18|20|22) ') { $ok = $ok -and (@($o.Phases.Values | Where-Object { $_.Inconsistent -and $_.Reason -match 'runner inconsistency' }).Count -ge 1) }
    Check "$($sc[0]) -> session $($sc[2]); $(($sc[3].Keys | ForEach-Object { "$_ $($sc[3][$_])" }) -join ', ')" $ok "$($o.Outcome) | $((@('p0','r1','r2','r3') | ForEach-Object { "$_=$($o.Phases[$_].Class): $($o.Phases[$_].Reason)" }) -join ' | ')"
}
$U8 = $CH['r2'].Substring(0, 8).ToUpperInvariant(); $U1 = $CH['r1'].Substring(0, 8).ToUpperInvariant()
$ocases = @(
    @('S30 r2 READ correct in both eyes', $SG, @((FsrL 'r2' 'left' 'READ' $U8), (FsrL 'r2' 'right' 'READ' $U8), (FsrL 'r2' 'dark' 'DARK_NOW')), 'r2', 'OPTICAL PASS', 'STAGE PASS'),
    @('S31 one eye correct', $SG, @((FsrL 'r2' 'left' 'READ' $U8), (FsrL 'r2' 'right' 'GARBLED'), (FsrL 'r2' 'dark' 'DARK_NOW')), 'r2', 'ONE-EYE ONLY', 'not a stage PASS'),
    @('S32 garbled / lit', $SG, @((FsrL 'r2' 'left' 'GARBLED'), (FsrL 'r2' 'right' 'LIT'), (FsrL 'r2' 'dark' 'DARK_NOW')), 'r2', 'LIT BUT GARBLED', 'not a stage PASS'),
    @('S33 both dark', $SG, @((FsrL 'r2' 'left' 'DARK'), (FsrL 'r2' 'right' 'DARK'), (FsrL 'r2' 'dark' 'DARK_NOW')), 'r2', 'DARK', 'not a stage PASS'),
    @('S34 timeout', $SG, @((FsrL 'r2' 'left' 'TIMEOUT'), (FsrL 'r2' 'right' 'NOT_ASKED'), (FsrL 'r2' 'dark' 'NOT_ASKED')), 'r2', 'NOT RECORDED', 'not a stage PASS'),
    @('S35 correct in both eyes in an r2 that committed nothing: contradicts', (SWith 2 (S3In 'r2' @{ Code = 50 })), @((FsrL 'r2' 'left' 'READ' $U8), (FsrL 'r2' 'right' 'READ' $U8)), 'r2', 'INCONCLUSIVE', 'not a stage PASS'),
    @('S36 correct in both eyes with r2''s record rejected: cannot be confirmed', (SWith 2 (S3In 'r2' @{} @{ Fsb1 = [pscustomobject]@{ Ok = $false; Reason = 'rec-hash'; Detail = ''; Steps = $null } })), @((FsrL 'r2' 'left' 'READ' $U8), (FsrL 'r2' 'right' 'READ' $U8)), 'r2', 'INCONCLUSIVE', 'not a stage PASS'),
    @('S37 r1 correct in both eyes, r2 NO-DISPLAY (RUN 1 ONLY): stage PASS from run 1', (SWith 2 (S3In 'r2' @{ Code = 50 })), @((FsrL 'r1' 'left' 'READ' $U1), (FsrL 'r1' 'right' 'READ' $U1), (FsrL 'r1' 'dark' 'DARK_NOW')), 'r1', 'OPTICAL PASS', 'STAGE PASS'),
    @('S38 malformed readings line', $SG, @('FSR2 p=r2 item=left key=a obs=lit prompt_ms=1 answer_ms=2 prompt_utc=x answer_utc=y discarded=0'), 'r2', 'INCONCLUSIVE', 'not a stage PASS'),
    @('S39 lower-case characters are not the challenge text', $SG, @((FsrL 'r2' 'left' 'READ' $U8), "FSR2 p=r2 item=right key=d obs=READ chars=$($U8.ToLowerInvariant()) prompt_ms=1 answer_ms=2 prompt_utc=x answer_utc=y discarded=0"), 'r2', 'INCONCLUSIVE', 'not a stage PASS'))
foreach ($oc in $ocases) {
    $o = SOut $oc[1] $oc[2]
    Check "$($oc[0]) -> $($oc[3]) optical $($oc[4]); $($oc[5])" ($o.Optical[$oc[3]].Class -ceq $oc[4] -and $o.Registered.StartsWith($oc[5])) "$($o.Optical[$oc[3]].Class) ($($o.Optical[$oc[3]].Why)) | $($o.Registered)"
}
$o = SOut $SG @((FsrL 'r2' 'left' 'GARBLED'), (FsrL 'r2' 'right' 'GARBLED'), (FsrL 'r2' 'dark' 'LIGHT_NOW' '' '' 'n'))
Check 'S40 dark check LIGHT_NOW -> RETAINED-FRAME OBSERVATION label' (@($o.Labels | Where-Object { $_ -match 'RETAINED-FRAME OBSERVATION after run 2 \(dark' }).Count -eq 1)
$o = Get-Fs3cOutcome -S1Class 'PASS' -Phases $SG -ReadingLines @((FsrL 'r2' 'left' 'DARK')) -Pin $script:G3Pin -SessionReadings @((FsrL 'r2' 'left' 'LIT'))
Check 'S41 readings3c.txt different from session.json readings: optical INCONCLUSIVE' ($o.Optical['r2'].Class -ceq 'INCONCLUSIVE' -and $o.ReadingsWhy -match 'differs')
$o = Get-Fs3cOutcome -S1Class 'DEVICE_REJECTED' -Phases $SG -Pin $script:G3Pin
Check 'S42 stage 1 not PASS: that class, never a verdict from record text' ($o.Outcome -ceq 'DEVICE_REJECTED')
$lcases = @(
    @('12', 'UPRIGHT', 'all four planes staged as planned; this eye shows buffer half 0', '[D]'), @('34', 'UPRIGHT', 'buffer half 1', '[D]'),
    @('21', 'HALF_TURN', 'in-buffer 180 degrees does not match the mounting', '[C]'), @('43', 'MIRRORED', 'left-right mirror', '[C]'),
    @('12', 'VFLIP', 'vertical flip', '[C]'), @('12', 'HALF_TURN', 'contradictory', '-'), @('34', 'MIRRORED', 'contradictory', '-'),
    @('21', 'UPRIGHT', 'exchanged position: layout fault', '[D]'), @('10', 'UPRIGHT', 'not scanned or not readable: layout fault', '[C]'), @('13', 'UNKNOWN', 'unexpected bar pair', '[C]'),
    @('12', 'NOT_ASKED', 'bars as planned for buffer half 0 (F not read)', '[D]'))
foreach ($lc in $lcases) { $l = Get-Fs3cLayoutLabel -Bars $lc[0] -Orient $lc[1]; Check "S43 layout bars $($lc[0]) F $($lc[1]) -> '$($lc[2])' $($lc[3])" ($l.Label -match [regex]::Escape($lc[2]) -and $l.Tag -ceq $lc[3]) "$($l.Label) $($l.Tag)" }
$l = Get-Fs3cLayoutLabel -Bars '20' -Orient 'UPRIGHT' -CharsCorrect $true
Check 'S44 correct characters and a 0 side: noted as an inconsistency' ($l.Inconsistent -and $l.Label -match 'contradicts the correct characters')
$o = SOut $SG @((FsrL 'r2' 'left' 'GARBLED'), (FsrL 'r2' 'right' 'GARBLED'), (FsrL 'r2' 'dark' 'DARK_NOW'), (FsrL 'r2' 'bars_left' 'BARS' '' '12'), (FsrL 'r2' 'bars_right' 'BARS' '' '21'))
Check 'S45 both eyes show the same buffer half -> half mapping fault label' (@($o.Labels | Where-Object { $_ -match 'both eyes show buffer half 0: half mapping fault' }).Count -eq 1)
function S3Pair([string]$l, [string]$r) { @{ left = [pscustomobject]@{ Obs = $l }; right = [pscustomobject]@{ Obs = $r } } }
$icases = @(
    @('GARBLED', 'GARBLED', 'UNIFORM_RED', 'UNIFORM_RED', $true, 'T1'), @('LIT', 'DARK', 'UNIFORM_RED', 'UNIFORM_RED', $true, 'T1'), @('GARBLED', 'DARK', 'SAME_AS_R2', 'SAME_AS_R2', $true, 'T2'),
    @('GARBLED', 'GARBLED', 'DIFFERENT', 'DIFFERENT', $true, 'T3'), @('LIT', 'LIT', 'PARTIAL_RED', 'PARTIAL_RED', $true, 'T4'), @('DARK', 'GARBLED', 'UNIFORM_OTHER', 'UNIFORM_OTHER', $true, 'T5'),
    @('GARBLED', 'GARBLED', 'DARK', 'DARK', $true, 'T6'), @('GARBLED', 'GARBLED', 'UNIFORM_RED', 'SAME_AS_R2', $true, '-'), @('GARBLED', 'GARBLED', 'UNIFORM_RED', 'UNIFORM_RED', $false, '-'))
foreach ($ic in $icases) {
    $it = Get-Fs3cR3Interpretation -R2Items (S3Pair $ic[0] $ic[1]) -R3Items (S3Pair $ic[2] $ic[3]) -Comparable $ic[4]
    Check "S46 run-3 interpretation: r2 $($ic[0])/$($ic[1]), r3 $($ic[2])/$($ic[3]), same tag $($ic[4]) -> $($ic[5])" ($it.Code -ceq $ic[5] -and ($ic[5] -ne '-' -or $it.Text -match $(if ($ic[4]) { 'eyes disagree' } else { 'LAYOUT DIFFERS' }))) "$($it.Code) $($it.Text)"
}
$o = SOut @((S3In 'p0'), (S3In 'r1'), (S3In 'r2'), (S3In 'r3' @{ Layout = 'quad_dma' })) @((FsrL 'r2' 'left' 'GARBLED'), (FsrL 'r2' 'right' 'GARBLED'), (FsrL 'r3' 'left' 'UNIFORM_RED'), (FsrL 'r3' 'right' 'UNIFORM_RED'))
Check 'S47 r2 quad_vig and r3 quad_dma: LAYOUT DIFFERS, no comparison' ($o.Interpretation.Text -match 'LAYOUT DIFFERS')
$pf = Get-Fs3cProbeFacts (Get-G3Steps -Ph 'r1' -Chal $CH['r1'] -O @{ Dmesg = $true })[0]
Check 'S48 scan-out signature: TE/BLU rates from the go+1 s -> end interrupt samples (181/s), dmesg flags (underrun) [informational]' ($pf.TeRate -eq 181 -and $pf.BluRate -eq 181 -and @($pf.DmesgFlags) -contains 'underrun') "$($pf.TeRate) $($pf.BluRate) $(@($pf.DmesgFlags) -join ',')"
$sm = Get-Fs3cSliceMarkers -Bytes (SB "fs-phase r1 x y`nFSPM1 n=$NX p=r1 e=go t=1 END`nFSPM1 n=$NX p=r1 e=begin t=2 END`n`nFSB1 BEGIN v=1`nFSPM1 n=$NX p=r1 e=end t=3 END`n") -NonceX $NX -PhX 'r1'
Check 'S49 marker cross-check: an out-of-order sequence and a marker inside the record are noted (informational, never a verdict)' (@($sm.Notes | Where-Object { $_ -match 'inside or after the record' }).Count -eq 1 -and @($sm.Notes | Where-Object { $_ -match "order 'go,begin'" }).Count -eq 1)

# ------------------------------------------------------------------ T --------
Say '== T. M4: the dot-source parameter scope'
$pv = @{ S3cPort = 'COM42'; S3cNonce = '0123456789abcdef'; S3cOutDir = 'C:\nonexistent\o'; S3cReplay = 'C:\nonexistent\r.raw'; S3cReplayIndex = 'C:\nonexistent\r.idx'; S3cKeyScript = 'C:\nonexistent\k.txt'
        S3cBootStartUtc = '2026-10-11T08:00:00.0000000Z'; S3cHandoffUtc = '2026-10-11T08:00:11.0000000Z'; S3cHostMarginSec = 17; S3cKernel = 'k-test'; S3cPid1 = 'p-test'; S3cPollMs = 37; S3cGiveUpMs = 123456
        S3cReplayPin = ('ab' * 32) }
$argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $T3Dir 'fs-collect3c.ps1'))
foreach ($k in $pv.Keys) { $argl += "-$k"; $argl += [string]$pv[$k] }
$argl += '-S3cRehearsal'; $argl += '-S3cNoDone'; $argl += '-S3cParamEcho'
$eo = & powershell.exe @argl 2>&1
$code = $LASTEXITCODE
$ej = $null; try { $ej = ($eo | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json } catch {}
$same = ($null -ne $ej)
if ($same) { foreach ($k in $pv.Keys) { if ([string]$ej.Snapshot.$k -cne [string]$pv[$k] -or [string]$ej.Live.$k -cne [string]$pv[$k]) { $same = $false } }; foreach ($k in 'S3cRehearsal', 'S3cNoDone', 'S3cParamEcho') { if (-not $ej.Snapshot.$k -or -not $ej.Live.$k) { $same = $false } } }
Check 'T1 fs-collect3c.ps1 run with EVERY S3c parameter at a non-default value: each survives the dot-source of fs-collect.ps1 unchanged (snapshot and live), no ValidateSet exception, exit 0; the fs-phase verb is added at run time' `
    ($code -eq 0 -and $same -and $ej.StageLabel -ceq '3c' -and $ej.FsPhaseVerb -ceq '^(p0|r1|r2|r3) [0-9a-f]{32} [0-9a-f]{16}\z') "exit $code $($eo -join ' / ')"
$collNames = 'Port|Nonce|OutDir|Replay|ReplayIndex|BootStartUtc|HandoffUtc|Stage|DeviceDeadlineSec|HostMarginSec|AckWindowSec|PreDoneMs|Exp|Steps|Kernel|Pid1|StepTimeoutMs|RecordTimeoutMs|PromptWaitMs|PromptSettleMs|AckSettleMs|AckStatusTries|InitialDrainMs|PollMs|NoDone|TestCaptureFailAfterBytes|TestCaptureFailOnClose'
$clsNames = 'CollectDir|Stage1Class|ObserveDir|ListRule|Readings'
$pinned = [IO.File]::ReadAllText((Join-Path $T3Dir 'fs-collect.ps1'))
$pm = [regex]::Match($pinned, '(?s)\nparam\((.*?)\n\)\n')
$declared = @([regex]::Matches($pm.Groups[1].Value, '\$([A-Za-z0-9]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Check "T2 the static list of fs-collect.ps1 param() names used by T3 equals the pinned file's param block ($($declared.Count) names)" ((($declared | Sort-Object) -join '|') -ceq ((($collNames -split '\|') | Sort-Object) -join '|')) ($declared -join ',')
$hits = @()
foreach ($f in 'fs-collect3c.ps1', 'fs-session3c.ps1', 'fs-classify3c.ps1') {
    $n = 0
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $T3Dir $f))) {
        $n++; if ($l.TrimStart().StartsWith('#')) { continue }
        if ($l -match "(?i)(\$|\$\{|Variable\s+(-Name\s+)?)(script:|global:|local:)?($collNames|$clsNames)(\b|\})") { $hits += "${f}:$n" }
    }
}
$n = 0; foreach ($l in [IO.File]::ReadAllLines((Join-Path $T3Dir 'fs-observe3c.ps1'))) { $n++; if (-not $l.TrimStart().StartsWith('#') -and $l -match '(?i)\$(script:)?Stage\b') { $hits += "fs-observe3c.ps1:$n" } }
Check 'T3 static: no 3c host file reads or assigns $Stage or any other name of fs-collect.ps1''s (or fs-classify.ps1''s) param() block; fs-observe3c.ps1 has no $Stage' ($hits.Count -eq 0) ($hits -join ' ')
$src3 = [IO.File]::ReadAllText((Join-Path $T3Dir 'fs-collect3c.ps1'))
$iSnap = $src3.IndexOf('$script:Fs3cArgs = @{} + $PSBoundParameters'); $iDot = $src3.IndexOf(". (Join-Path `$PSScriptRoot 'fs-collect.ps1')")
Check 'T4 the arguments and the invocation name are snapshotted BEFORE the dot-source; no -Stage is passed to any fs-collect.ps1 function' ($iSnap -gt 0 -and $iDot -gt $iSnap -and $src3.IndexOf('$script:Fs3cInvocation = $MyInvocation.InvocationName') -lt $iDot -and $src3 -notmatch '(?m)^[^#]*\s-Stage\s')
$hz = Join-Path $Scratch 'm4-hazard.ps1'
[IO.File]::WriteAllText($hz, ("param([string]`$Port = 'MINE')`n. '" + (Join-Path $T3Dir 'fs-collect.ps1') + "'`n`"port=[`$Port]`"`ntry { `$Stage = '3c'; 'threw=False' } catch { 'threw=True' }`n"))
$ho = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hz -Port COM5
Check 'T5 the hazard is real (control): a script whose own -Port is COM5 loses it to fs-collect.ps1''s param block when it dot-sources the pinned file, and its $Stage then carries ValidateSet 2a/3a/3b (assigning 3c throws)' (($ho -join ' ') -ceq 'port=[] threw=True') ($ho -join ' ')

# ------------------------------------------------------------------ U --------
Say '== U. replay tokens'
$ix = Read-FsCaptureIndex -Path (Join-Path $T3Fix 'replay\garbled-r3\capture.raw.idx') -RawLength ([IO.File]::ReadAllBytes((Join-Path $T3Fix 'replay\garbled-r3\capture.raw'))).Length
$tk = Get-Fs3cReplayTokens $ix
$g = $CAN['garbled-r3'].G
Check 'U1 Get-Fs3cReplayTokens: one challenge per fs-phase write (p0..r3), validated by the command regex; the recorded <prev> kept only for the comparison' `
    ($tk.C['p0'] -ceq $g.Tokens.C['p0'] -and $tk.C['r3'] -ceq $g.Tokens.C['r3'] -and $tk.RecordedPrev['r1'] -ceq $g.Sha16['p0'] -and $tk.RecordedPrev['p0'] -ceq ('0' * 16) -and $tk.V -ceq $g.Tokens.V)
Check 'U2 the replayed session recomputes every <prev> from its own decode and it equals the recorded one (PrevCheck)' (@($CAN['garbled-r3'].R.Replay.PrevCheck | Where-Object { -not $_.Same }).Count -eq 0 -and @($CAN['garbled-r3'].R.Replay.PrevCheck).Count -eq 4)
$x = T3Run 'u3-badprev' @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; Prev = 'deadbeefdeadbeef' }) $true $KR1
Check 'U3 a capture whose recorded <prev> does not match the replayed record: divergence (never trusted), PrevCheck r2 differs, nothing further delivered' `
    (@($x.R.Replay.Divergence).Count -ge 1 -and $x.R.Replay.Divergence[0] -match "recorded write was 'fs-phase r2 [0-9a-f]{32} deadbeefdeadbeef'" -and @($x.R.Replay.PrevCheck | Where-Object { $_.Ph -ceq 'r2' -and -not $_.Same }).Count -eq 1) (T3Desc $x)

# ------------------------------------------------------------------ V --------
Say '== V. per-slice FSB1 validation'
$fs = $CAN['garbled-r3'].R.Fsb1
Check 'V1 a 4-record capture: VALID x4, each slice validated on its own (Test-Fsb1Record per slice, one BEGIN each)' (@('p0', 'r1', 'r2', 'r3' | Where-Object { $fs[$_].Ok -and $fs[$_].Reason -ceq 'valid' }).Count -eq 4)
$x = T3Run 'v2-r3-reject' @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2' }, @{ Ph = 'r3'; Rec = 'reject' }) $true ($KR1 + $KR2C + $KR3S)
$q = Invoke-Fs3cClassifyDir -DirX $x.Out -S1X 'PASS' -PinX $script:G3Pin
Check 'V2 the last slice rejected: that phase INCONCLUSIVE, the earlier phases unaffected (P0 OK, R1 SHOWN, R2 SHOWN-QUAD); COLLECTED-REJECTED' `
    ((T3Clean $x) -and $x.R.Fsb1['r3'].Ok -eq $false -and $x.R.Fsb1['r2'].Ok -and $x.R.Status -ceq 'COLLECTED-REJECTED' -and $q.Outcome.Phases['r3'].Class -ceq 'INCONCLUSIVE' -and
     $q.Outcome.Phases['r2'].Class -ceq 'R2 SHOWN-QUAD' -and $q.Outcome.Phases['p0'].Class -ceq 'P0 OK' -and $q.Outcome.Outcome -ceq 'PASS (machine side)') (T3Desc $x)

# ------------------------------------------------------------------ W --------
Say '== W. the fs-phase command line'
$c64 = New-FsCommand -Verb 'fs-phase' -Arg "r3 $('f' * 32) $('0' * 16)"
Check "W1 the longest fs-phase line is $($c64.Length) characters and matches ^[a-z0-9 -]{1,64}\z (and the verb regex of DESIGN 5.1)" ($c64.Length -eq 61 -and $c64 -cmatch '^[a-z0-9 -]{1,64}\z' -and $script:FsCmdSpec['fs-phase'] -ceq '^(p0|r1|r2|r3) [0-9a-f]{32} [0-9a-f]{16}\z')
$wbad = @("r4 $('a' * 32) $('0' * 16)", "r1 $('A' * 32) $('0' * 16)", "r1 $('a' * 32) $('0' * 15)", "r1  $('a' * 32) $('0' * 16)", "p0 $('a' * 32)", "r1 $('a' * 32) $('0' * 16) x", "r1 $('a' * 31)g $('0' * 16)")
$wr = @($wbad | Where-Object { $r0 = $true; try { $null = New-FsCommand -Verb 'fs-phase' -Arg $_; $r0 = $false } catch {}; -not $r0 })
Check 'W2 New-FsCommand refuses every malformed fs-phase argument (phase r4, upper-case hex, short prev, double space, missing prev, extra word, non-hex)' ($wr.Count -eq 0) ($wr -join ' | ')
$allSent = @(); foreach ($k in $CAN.Keys) { $allSent += @($CAN[$k].R.Sent) }
Check 'W3 every command sent in the sessions matches ^[a-z0-9 -]{1,64}\z; the pinned fs-collect.ps1 has no fs-phase verb (added at run time only)' (@($allSent | Where-Object { $_ -cnotmatch '^[a-z0-9 -]{1,64}\z' }).Count -eq 0 -and $pinned -notmatch 'fs-phase')

# ------------------------------------------------------------------ X --------
Say '== X. fs-observe3c.ps1'
$fq = Join-Path $Scratch 'fakeq3'; $null = New-Item -ItemType Directory -Force -Path (Join-Path $fq 'stage3c')
foreach ($f in 'init.sh', 'fs-phase.sh', 'fs-probe.sh', 'fs-idle.sh') { [IO.File]::WriteAllText((Join-Path $fq "stage3c\$f"), "# fixture $f`n") }
# the observer reads the checklist's pin from <Q3>\SIGNOFF-3c.md: the fixture pins this repository's fs-checklist3c.ps1
$script:clPinReal = Get-FsCl3Sha $script:FsCl3Self
[IO.File]::WriteAllText((Join-Path $fq 'SIGNOFF-3c.md'), "# fixture`n<!-- host pins (fixture) -->`n| file | SHA-256 | kind |`n|---|---|---|`n| ``devices\quest3\host\fs-checklist3c.ps1`` | ``$($script:clPinReal)`` | fixture |`n<!-- end host pins -->`n")
function New-ObsBuild3c([string]$nonceX, [string]$idleHash = '', [switch]$Overrides) {
    $base = Join-Path $Scratch ("obs3c-" + (New-FsHex 3)); $bd = Join-Path $base "build\stage3c\20261011T090000Z-$nonceX"
    $null = New-Item -ItemType Directory -Force -Path $bd
    $img = Join-Path $bd 'boot-stage3c.img'; [IO.File]::WriteAllBytes($img, [byte[]](1..64 | ForEach-Object { [byte]$_ }))
    $h = { param($f) (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $fq $f)).Hash.ToLower() }
    if (-not $idleHash) { $idleHash = & $h 'stage3c\fs-idle.sh' }
    $m = "FrameShift Quest 3 stage-3c image (interactive display run, fs-pattern v0.6) - ONE ATTEMPT ONLY`nbuilt:            20261011T090000Z`nnonce:            $nonceX   (USB serial FS-$nonceX)`n" +
         "OUTPUT IMAGE:     boot-stage3c.img  size=64  sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $img).Hash.ToLower())`n`n" +
         "stock boot        49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50  x`nstock vendor_boot 1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf  x`n" +
         "init.sh source    $(& $h 'stage3c\init.sh')  (recorded)`nfs-phase.sh       $(& $h 'stage3c\fs-phase.sh')  (recorded)`nfs-probe.sh       $(& $h 'stage3c\fs-probe.sh')  (recorded)`nfs-idle.sh        $idleHash  (recorded)`n" +
         $(if ($Overrides) { "TEST OVERRIDES: DEADLINE=30`n" } else { '' })
    [IO.File]::WriteAllText((Join-Path $bd 'MANIFEST.txt'), $m, (New-Object System.Text.UTF8Encoding($false)))
    [pscustomobject]@{ Img = $img; Root = (Join-Path $base 'build\stage3c'); Dir = $bd; Base = $base }
}
# review MAJOR-1/2: a BA summary carries BA10 (dumpsys battery) with its file next to it, as fs-capture.ps1 writes
# them (Out-File -Encoding ascii, CRLF); the header names the unit's serial
$script:T3Bat = "Current Battery Service state:`n  AC powered: false`n  USB powered: true`n  status: 3`n  health: 2`n  present: true`n  level: 80`n  scale: 100`n  temperature: 300`n  technology: Li-ion"
function New-Summary3c([string]$dir, [string]$phase, [string]$nonceX, [string]$utc, [string]$serial = 'QUEST3UNIT1', [string]$battery = $script:T3Bat, [switch]$NoBa10) {
    $null = New-Item -ItemType Directory -Force -Path $dir; $p = Join-Path $dir 'SUMMARY.txt'
    $rows = @("${phase}01`t0`t1`tab`tf")
    if ($phase -ceq 'BA' -and -not $NoBa10) {
        $bp = Join-Path $dir 'BA10.txt'; @($battery -split "`n") | Out-File -FilePath $bp -Encoding ascii
        [byte[]]$bb = [IO.File]::ReadAllBytes($bp); $rows += "BA10`t0`t$($bb.Length)`t$(Get-FsSha256Hex $bb)`t$bp"
    }
    [IO.File]::WriteAllLines($p, [string[]](@("# fs-capture.ps1 phase $phase nonce $nonceX serial $serial  $utc", '# adb x  fastboot y  commands z', "# id`texit`tbytes`tsha256`tfile") + $rows + @("PHASE $phase OK: 15 rows captured in $dir"))); $p
}
function Invoke-Obs3c($b, [string]$nonceX, [string]$ba, [string]$bf, [DateTime]$clock, [bool]$pre = $false, [string]$clf = '', [string]$serial = 'QUEST3UNIT1') {
    $script:fk3 = [pscustomobject]@{ Calls = (New-Object System.Collections.Generic.List[string]); Clock = $clock; Lines = (New-Object System.Collections.Generic.List[string]) }
    Invoke-FsObserve -ImagePath $b.Img -Serial $serial -ConfirmNonce $nonceX -Preflight $pre -BuildRoot $b.Root -Q3 $fq -GadgetWaitSec 10 -BaSummary $ba -BfSummary $bf -ChecklistFile $clf `
        -Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) $f = $script:fk3; $f.Calls.Add(($ArgList -join ' ')); $f.Clock = $f.Clock.AddMilliseconds(300)
            if ($ArgList[0] -ceq 'devices') { return [pscustomobject]@{ ExitCode = 0; StdOut = "QUEST3UNIT1`tfastboot`r`n"; StdErr = ''; TimedOut = $false; Error = $null } }
            $f.Clock = $f.Clock.AddSeconds(11); [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = "Booting OKAY`n"; TimedOut = $false; Error = $null } } `
        -Gadget { param([string]$N0) [pscustomobject]@{ Present = $true; SerialOk = $true; Serials = @("FS-$N0"); ComPort = 'COM9'; Parent = 'x' } } `
        -NowUtc { $script:fk3.Clock } -Sleep { param([int]$Ms) $script:fk3.Clock = $script:fk3.Clock.AddMilliseconds($Ms) } -Say { param([string]$Line) $script:fk3.Lines.Add($Line) }
}
# the console checklist fixtures (J-118): a fake repository (two pinned files, the previews, a SIGNOFF pin table),
# a cycle (host-hashes.txt by the literal Get-FileHash pipeline, soundcheck.json, the rehearsal summary written by
# the collector's own Save-Fs3cSummary from the garbled-r3 replay), scripted y/n answers and a fake clock
function New-Cl3Root {
    $root = Join-Path $Scratch ("cl3root-" + (New-FsHex 3)); $hd = Join-Path $root 'devices\quest3\host'
    $null = New-Item -ItemType Directory -Force -Path $hd
    foreach ($f in 'fake-a.ps1', 'fake-b.ps1') { [IO.File]::WriteAllText((Join-Path $hd $f), "# fixture $f`n") }
    $pd = Join-Path $root $script:FsCl3PreviewDir; $null = New-Item -ItemType Directory -Force -Path $pd
    foreach ($f in $script:FsCl3PreviewFiles) { [IO.File]::WriteAllBytes((Join-Path $pd $f), [byte[]](1, 2, 3)) }
    $rows = @(foreach ($f in 'fake-a.ps1', 'fake-b.ps1') { "| ``devices\quest3\host\$f`` | ``$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $hd $f)).Hash.ToLower())`` | fixture |" })
    [IO.File]::WriteAllText((Join-Path $root 'SIGNOFF-3c.md'), "# fixture`n<!-- host pins (fixture) -->`n| file | SHA-256 | kind |`n|---|---|---|`n$($rows -join "`n")`n<!-- end host pins -->`n")
    $root
}
function New-Cl3Cycle([string]$root, [string]$cyc = '') {
    if (-not $cyc) { $cyc = Join-Path $Scratch ("cl3cyc-" + (New-FsHex 3)) }; $null = New-Item -ItemType Directory -Force -Path $cyc
    Push-Location -LiteralPath $root
    try { $null = Get-FileHash -Algorithm SHA256 -LiteralPath devices\quest3\host\fake-a.ps1, devices\quest3\host\fake-b.ps1 | Format-Table Hash, Path -AutoSize | Out-String -Width 400 | Tee-Object -FilePath (Join-Path $cyc 'host-hashes.txt') }
    finally { Pop-Location }
    [IO.File]::WriteAllText((Join-Path $cyc 'soundcheck.json'), "{`"Schema`": `"frameshift.fs-soundcheck3c.v1`", `"Pass`": true, `"EndUtc`": `"2026-10-11T07:00:00.0000000Z`"}`n")
    $rd = Join-Path $cyc 'rehearsal-2'; $null = New-Item -ItemType Directory -Force -Path $rd
    $null = Save-Fs3cSummary $CAN['garbled-r3'].R $rd $true
    $cyc
}
$script:cl3Clock = [DateTime]::Parse('2026-10-11T08:00:00Z').ToUniversalTime(); $script:cl3Nonce = 'c0de3c0000000001'; $script:cl3PfOk = $true; $script:cl3PfCalls = 0
$script:cl3Serial = 'QUEST3UNIT1'      # the unit of the fixture cycles (New-Cl3Valid's reading; New-Summary3c's default)
$script:cl3Pf = { param([string]$i) $script:cl3PfCalls++; [pscustomobject]@{ Ok = $script:cl3PfOk; Why = $(if ($script:cl3PfOk) { 'exit 0; preflight OK: fixture' } else { 'exit 2; ABORT: image refused: fixture' }); Nonce = $script:cl3Nonce; ImageSha = ('ab' * 32) } }
function Get-Cl3Opt([string]$root, [hashtable]$more = @{}) {
    $o = @{ Root = $root; SignoffFile = (Join-Path $root 'SIGNOFF-3c.md'); Image = 'C:\fixture\boot-stage3c.img'; Preflight = $script:cl3Pf; TimeoutSec = 30 }
    foreach ($k in $more.Keys) { $o[$k] = $more[$k] }; $o
}
function CL3Run([string]$cyc, [string]$ph, [string[]]$ans = @(), [hashtable]$opt = @{}) {
    $script:cl3Ans = New-Object System.Collections.Generic.List[string]; foreach ($a in $ans) { $script:cl3Ans.Add($a) }
    $script:cl3Asked = New-Object System.Collections.Generic.List[string]; $script:cl3Said = New-Object System.Collections.Generic.List[string]; $script:cl3To = New-Object System.Collections.Generic.List[int]
    Invoke-FsCl3Phase -Phase $ph -Cycle $cyc -Opt $opt -NowUtc { $script:cl3Clock } -Say { param([string]$l) $script:cl3Said.Add($l) } `
        -Ask { param([string]$t, [int]$to) $script:cl3Asked.Add($t); $script:cl3To.Add($to); $script:cl3Clock = $script:cl3Clock.AddSeconds(3)
               if ($script:cl3Ans.Count) { $a = $script:cl3Ans[0]; $script:cl3Ans.RemoveAt(0); $a } else { 'timeout' } }
}
# a complete checklist (A, B, E all y) whose presence (E) ends exactly at $endUtc (it starts at $endUtc - 6 s);
# A at end - 1600 s, the single temperature reading (J-125: 300, battery status 5 full) at end - 800 s, B at
# end - 790 s: a BA between end - 800 s and end - 100 s and a BF before end - 6 s satisfy the observer's tie;
# returns the cycle directory
function New-Cl3Valid([string]$cyc, [string]$root, [string]$nonceX, [DateTime]$endUtc) {
    $script:cl3Nonce = $nonceX; $script:cl3PfOk = $true
    if (-not (Test-Path -LiteralPath (Join-Path $cyc 'host-hashes.txt'))) { $null = New-Cl3Cycle $root $cyc }
    $script:cl3Clock = $endUtc.AddSeconds(-1600)
    $null = CL3Run $cyc 'A' @('y', 'y', 'y') (Get-Cl3Opt $root)
    $script:cl3Clock = $endUtc.AddSeconds(-790)
    $null = CL3Run $cyc 'B' @() (Get-Cl3Opt $root @{ R1 = '300'; R1Utc = (Format-FsCl3Utc $endUtc.AddSeconds(-800)); R1Status = '5'; R1Charge = '80'; R1Serial = $script:cl3Serial })
    $script:cl3Clock = $endUtc.AddSeconds(-6)
    $null = CL3Run $cyc 'E' @('y', 'y') (Get-Cl3Opt $root)
    $cyc
}
$CLRoot = New-Cl3Root

$TX = [DateTime]::Parse('2026-10-11T09:00:00Z').ToUniversalTime()
$n1 = 'c0de3c0000000001'; $b1 = New-ObsBuild3c $n1
$ba = New-Summary3c (Join-Path $b1.Base 'cap\BA') 'BA' $n1 '2026-10-11T08:56:00.0000000Z'; $bf = New-Summary3c (Join-Path $b1.Base 'cap\BF') 'BF' $n1 '2026-10-11T08:57:30.0000000Z'
$null = New-Cl3Valid (Join-Path $b1.Base 'cap') $CLRoot $n1 $TX.AddSeconds(-60)          # the default: <cycle of -BaSummary>\checklist3c.json
$o = Invoke-Obs3c $b1 $n1 $ba $bf $TX
$oj = Get-Content -Raw (Join-Path $o.OutDir 'observe.json') | ConvertFrom-Json
Check 'X1 dwell 240 s: registered in build\stage3c\attempted, one fastboot boot; observe.json Stage 3c with DwellSec; NEXT is fs-collect3c.ps1 with -S3cPort/-S3cNonce/-S3cBootStartUtc/-S3cHandoffUtc/-S3cOutDir' `
    ($o.Exit -eq 0 -and $script:fk3.Calls.Count -eq 2 -and (Test-Path (Join-Path $b1.Root "attempted\$n1.attempted")) -and $oj.Stage -ceq '3c' -and [double]$oj.DwellSec -eq 240.3 -and
     $oj.NextCommand -match "fs-collect3c\.ps1 -S3cPort COM9 -S3cNonce $n1 -S3cBootStartUtc \S+ -S3cHandoffUtc \S+ -S3cOutDir " -and (@($script:fk3.Lines) -match 'THEN: fs-classify3c\.ps1 -C3cDir').Count -eq 1) "$($o.Why) $($oj.NextCommand)"
$n2 = 'c0de3c0000000002'; $b2 = New-ObsBuild3c $n2
$ba2 = New-Summary3c (Join-Path $b2.Base 'cap\BA') 'BA' $n2 '2026-10-11T08:54:59.0000000Z'; $bf2 = New-Summary3c (Join-Path $b2.Base 'cap\BF') 'BF' $n2 '2026-10-11T08:57:00.0000000Z'
$null = New-Cl3Valid (Join-Path $b2.Base 'cap') $CLRoot $n2 $TX.AddSeconds(-30)
$o = Invoke-Obs3c $b2 $n2 $ba2 $bf2 $TX
Check 'X2 dwell 301 s: refused before the boot (unconditional gate), not registered, abandoned-cycle record (stage 3c)' ($o.Exit -eq 2 -and $o.Why -match 'dwell cap expired' -and $script:fk3.Calls.Count -eq 1 -and -not (Test-Path (Join-Path $b2.Root "attempted\$n2.attempted")) -and
    @(Get-ChildItem -LiteralPath (Join-Path $b2.Root 'abandoned') -Filter "*-$n2.txt").Count -eq 1) $o.Why
$o = Invoke-Obs3c $b2 $n2 '' '' $TX $false (Join-Path $b2.Base 'cap\checklist3c.json')
Check 'X3 no BA/BF summaries: refused (the gate is unconditional for 3c)' ($o.Exit -eq 2 -and $o.Why -match 'required for stage 3c')
$n3 = 'c0de3c0000000003'; $b3 = New-ObsBuild3c $n3 ('0' * 64)
$o = Invoke-Obs3c $b3 $n3 $ba $bf $TX
Check 'X4 a MANIFEST whose fs-idle.sh hash is not the repository''s: refused (3c sources: init.sh, fs-phase.sh, fs-probe.sh, fs-idle.sh)' ($o.Exit -eq 2 -and $o.Why -match 'fs-idle.sh') $o.Why
$n4 = 'c0de3c0000000004'; $b4 = New-ObsBuild3c $n4 -Overrides
$o = Invoke-Obs3c $b4 $n4 $ba $bf $TX $true
Check 'X5 TEST OVERRIDES in the MANIFEST: refused, even for -Preflight' ($o.Exit -eq 2 -and $o.Why -match 'TEST OVERRIDES') $o.Why
$n5 = 'c0de3c0000000005'; $b5 = New-ObsBuild3c $n5
$o = Invoke-Obs3c $b5 $n5 '' '' $TX $true
Check 'X6 -Preflight: preflight OK, no device action' ($o.Exit -eq 0 -and $o.Why -match '^preflight OK' -and $script:fk3.Calls.Count -eq 0)
$obsSrc = [IO.File]::ReadAllText((Join-Path $T3Dir 'fs-observe3c.ps1'))
Check 'X7 static: the -ThenCollect launch is fs-collect3c.ps1 with the S3c names; no fs-collect.ps1 launch remains; the file is ASCII' ($obsSrc -match "'fs-collect3c\.ps1'\) -S3cPort" -and $obsSrc -notmatch "'fs-collect\.ps1'" -and -not ($obsSrc -match '[^\x00-\x7f]'))

# ------------------------------------------------------------------ CL -------
Say '== CL. the console checklist (fs-checklist3c.ps1, J-118) and the fs-observe3c.ps1 gate'
$cyc = New-Cl3Cycle $CLRoot; $script:cl3Nonce = 'c0de3c00000000c1'; $script:cl3PfOk = $true; $script:cl3PfCalls = 0
$script:cl3Clock = [DateTime]::Parse('2026-10-11T08:00:00Z').ToUniversalTime()
$ra = CL3Run $cyc 'A' @('y', 'y', 'y') (Get-Cl3Opt $CLRoot)
$aSaid = $script:cl3Said -join "`n"
$rb = CL3Run $cyc 'B' @() (Get-Cl3Opt $CLRoot @{ R1 = '312'; R1Utc = '2026-10-11T07:51:30Z'; R1Status = '5'; R1Charge = '81'; R1Serial = 'QUEST3UNIT1' })
$script:cl3Clock = $script:cl3Clock.AddSeconds(900)
$re = CL3Run $cyc 'E' @('y', 'y') (Get-Cl3Opt $CLRoot)
$eSaid = $script:cl3Said -join "`n"
$cj = Get-Content -Raw (Join-Path $cyc 'checklist3c.json') | ConvertFrom-Json
$ct = [IO.File]::ReadAllText((Join-Path $cyc 'checklist3c.txt'))
$en = @($cj.Entries)
$isoRe = '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z\z'
$qOk = $true; foreach ($q in @($en | ForEach-Object { @($_.Questions) })) { if ([string]$q.Text -cne $script:FsCl3Q[[string]$q.Id] -or [string]$q.Answer -cne 'y' -or [string]$q.AskedUtc -cnotmatch $isoRe -or [string]$q.AnsweredUtc -cnotmatch $isoRe) { $qOk = $false } }
Check 'CL1 all y: phases A, B, E pass (exit 0 each); checklist3c.json holds three PASS entries, A with the five automatic checks OK and the nonce, the questions A1-A3 and E1-E2 with their exact text, the answer y and UTC asked/answered times; B the single temperature reading (J-125: 312, status 5 full, 519 s old, ok, recorded as typed text with the unit QUEST3UNIT1 Unit 1; checks reading-input, range-100-349, not-charging, known-unit, not-in-future, at-most-15-min-old); schema v3; checklist3c.txt the same, readable' `
    ($ra.Exit -eq 0 -and $rb.Exit -eq 0 -and $re.Exit -eq 0 -and $cj.Schema -ceq 'frameshift.fs-checklist3c.v3' -and $en.Count -eq 3 -and (@($en | ForEach-Object { "$($_.Phase)=$($_.Result)" }) -join ',') -ceq 'A=PASS,B=PASS,E=PASS' -and
     (@($en[0].Checks | ForEach-Object { "$($_.Name)=$($_.Ok)" }) -join ',') -ceq 'host-pins=True,preflight=True,soundcheck=True,rehearsal=True,previews=True' -and $en[0].Nonce -ceq 'c0de3c00000000c1' -and
     (@($en[0].Questions | ForEach-Object { $_.Id }) -join ',') -ceq 'A1,A2,A3' -and (@($en[2].Questions | ForEach-Object { $_.Id }) -join ',') -ceq 'E1,E2' -and $qOk -and
     [double]$en[1].Reading.AgeSec -eq 519 -and $en[1].Reading.Ok -eq $true -and $en[1].Reading.R1 -is [string] -and $en[1].Reading.R1 -ceq '312' -and $en[1].Reading.R1Status -ceq '5' -and [string]$en[1].Reading.R1StatusName -ceq 'full' -and $en[1].Reading.R1Charge -ceq '81' -and
     $en[1].Reading.R1Serial -ceq 'QUEST3UNIT1' -and $en[1].Reading.R1Unit -ceq 'Unit 1' -and
     (@($en[1].Checks | ForEach-Object { "$($_.Name)=$($_.Ok)" }) -join ',') -ceq 'reading-input=True,range-100-349=True,not-charging=True,known-unit=True,not-in-future=True,at-most-15-min-old=True' -and -not $en[1].PSObject.Properties['Pair'] -and $en[2].EndUtc -cmatch $isoRe -and $en[0].ToolSha256 -ceq (Get-FsCl3Sha $script:FsCl3Self) -and
     @([regex]::Matches($ct, '(?m)^== phase [ABE]: PASS ')).Count -eq 3 -and $ct -match [regex]::Escape("`"$($script:FsCl3Q.E2)`"  answer y at ") -and $ct -match 'reading: 312 at 2026-10-11T07:51:30\.0000000Z \(battery status 5 full; charge 81; unit QUEST3UNIT1 Unit 1\); 519 s old at phase B; ok True') "$($ra.Why) | $($rb.Why) | $($re.Why)"
$pvLines = Get-FsCl3PreviewLines $CLRoot
$blkOk = ((@($en[0].Blocks | ForEach-Object { $_.Title }) -join '|') -ceq 'THE SIX PREVIEW PICTURES|THE KEYS (what to press for what you see)|WHAT I ACCEPT (points D1 to D14)' -and
          [string]$en[0].Blocks[0].Sha256 -ceq (Get-FsCl3TextSha (@('== THE SIX PREVIEW PICTURES') + $pvLines)) -and [int]$en[0].Blocks[2].Lines -eq 14 -and
          [string]$en[0].Blocks[2].Sha256 -ceq (Get-FsCl3TextSha (@('== WHAT I ACCEPT (points D1 to D14)') + $script:FsCl3Text.Accept)) -and @($en[2].Blocks).Count -eq 2 -and @($en[1].Blocks).Count -eq 0 -and
          @($en | ForEach-Object { @($_.Questions) } | Where-Object { [int]$_.TimeoutSec -ne 30 }).Count -eq 0 -and @([regex]::Matches($ct, '(?m)^   printed "[^"]+" \(\d+ lines\) sha256 [0-9a-f]{64}$')).Count -eq 5)
Check 'CL1b LOW 10: each entry records every printed block (title, line count, SHA-256 of the unwrapped lines) and each question its timeout; checklist3c.txt lists the blocks' $blkOk ''
$nz = { param($t) (([string]$t -replace '\s+', ' ').Trim()) }
$aNz = & $nz $aSaid; $eNz = & $nz $eSaid
Check 'CL2 phase A prints the six preview pictures (absolute paths, one per line, each with what it shows), the keys and points D1-D14 (every line) before the matching question; phase E prints presence and the after-session temperatures; the rehearsal check quotes the GO line' `
    (@($pvLines + $script:FsCl3Text.KeyLines + $script:FsCl3Text.Accept | Where-Object { $aNz.IndexOf((& $nz $_)) -lt 0 }).Count -eq 0 -and
     @($aSaid -split "`n") -ccontains "  1. $CLRoot\devices\quest3\stage3c\fixtures\preview\pattern-v0.6-3f9c07ab-viewer-1032x552.png" -and @($script:FsCl3PreviewFiles | Where-Object { $aSaid.IndexOf("$CLRoot\devices\quest3\stage3c\fixtures\preview\$_") -lt 0 }).Count -eq 0 -and
     $aNz.IndexOf((& $nz $script:FsCl3Text.Accept[-1])) -lt $aNz.IndexOf('PHASE A PASSED') -and @($script:FsCl3Text.Presence + $script:FsCl3Text.After | Where-Object { $eNz.IndexOf((& $nz $_)) -lt 0 }).Count -eq 0 -and
     $aNz -match 'check rehearsal: OK - REHEARSAL: run-1 plus run-2 answers [0-9.]+ s; go/no-go \(SIGNOFF-3c A, Q7\): GO \(<= 40 s\)') ''
$c9ba = New-Summary3c (Join-Path $cyc 'BA') 'BA' 'c0de3c00000000c1' (Format-FsCl3Utc ([DateTime]::Parse($rb.Entry.Reading.R1Utc).ToUniversalTime().AddSeconds(120)))
$c9bf = New-Summary3c (Join-Path $cyc 'BF') 'BF' 'c0de3c00000000c1' (Format-FsCl3Utc ([DateTime]::Parse($en[2].StartUtc).ToUniversalTime().AddSeconds(-60)))
$ok = Test-FsObsChecklist -Path (Join-Path $cyc 'checklist3c.json') -Nonce 'c0de3c00000000c1' -NowUtc ([DateTime]::Parse($en[2].EndUtc).ToUniversalTime().AddSeconds(10)) -ToolPin $script:clPinReal -BaSummary $c9ba -BfSummary $c9bf -Serial 'QUEST3UNIT1'
Check 'CL3 fs-observe3c Test-FsObsChecklist accepts it 10 s after E (pinned tool, the temperature reading 120 s before BA on this unit, BA10 300 status 3, presence after BF; checklist3c.txt hashed)' ($ok.Ok -and $ok.AgeSec -eq 10 -and $ok.Sha256 -cmatch '^[0-9a-f]{64}\z' -and $ok.ReadingToBaSec -eq 120 -and $ok.TxtSha256 -ceq (Get-FsCl3Sha (Join-Path $cyc 'checklist3c.txt')) -and
    $ok.Ba10.Temp -eq 300 -and $ok.Ba10.Status -eq 3 -and $ok.Ba10.Level -eq 80 -and $ok.Why -match 'unit QUEST3UNIT1\) 120 s before BA \(max 900 s\); BA10 temperature 300, status 3, level 80;') $ok.Why

# an n, a timeout (or no console) at each item -> STOP, exit 1, the later questions not asked, recorded
$bad = @()
foreach ($ans in 'n', 'timeout', 'noconsole') {
    foreach ($case in @(@('A', 0), @('A', 1), @('A', 2), @('E', 0), @('E', 1))) {
        $c2 = New-Cl3Cycle $CLRoot; $script:cl3Nonce = 'c0de3c00000000c2'
        if ($case[0] -ceq 'E') { $null = New-Cl3Valid $c2 $CLRoot 'c0de3c00000000c2' ([DateTime]::Parse('2026-10-11T08:30:00Z').ToUniversalTime()) }
        $al = @(@('y', 'y', 'y')[0..($case[1])]); $al[$case[1]] = $ans
        $script:cl3Clock = [DateTime]::Parse('2026-10-11T08:40:00Z').ToUniversalTime()
        $r = CL3Run $c2 $case[0] $al (Get-Cl3Opt $CLRoot)
        $last = @((Get-Content -Raw (Join-Path $c2 'checklist3c.json') | ConvertFrom-Json).Entries)[-1]
        $qid = "$($case[0])$($case[1] + 1)"
        $good = ($r.Exit -eq 1 -and $last.Phase -ceq $case[0] -and $last.Result -ceq 'STOP' -and $script:cl3Asked.Count -eq ($case[1] + 1) -and @($last.Questions).Count -eq ($case[1] + 1) -and
                 [string]@($last.Questions)[-1].Answer -ceq $ans -and [string]@($last.Questions)[-1].Id -ceq $qid -and $last.Why -match [regex]::Escape($script:FsCl3Q[$qid]) -and
                 @($script:cl3Said | Where-Object { $_ -cmatch "^STOPPED\. Nothing was sent to the headset\. Tell the Arbiter: phase $($case[0]) - answer " }).Count -eq 1 -and $script:cl3Said[-1] -cnotmatch '^recorded:' -and [IO.File]::ReadAllText((Join-Path $c2 'checklist3c.txt')) -match "(?m)^== phase $($case[0]): STOP ")
        $vt = Test-FsObsChecklist -Path (Join-Path $c2 'checklist3c.json') -Nonce 'c0de3c00000000c2' -NowUtc $script:cl3Clock -Serial 'QUEST3UNIT1'
        if (-not $good -or $vt.Ok -or $vt.Why -notmatch "phase $($case[0]) (did not pass|is missing)") { $bad += "$ans@$qid exit=$($r.Exit) asked=$($script:cl3Asked.Count) obs=$($vt.Why)" }
    }
}
Check 'CL4 an n, a timeout and "no console" at each of A1, A2, A3, E1, E2: "STOPPED. Nothing was sent to the headset. Tell the Arbiter: phase <X> - <reason>" printed last, exit 1, the later questions not asked, the STOP entry (with the answer and the question) recorded in both files; fs-observe3c refuses that checklist (15 cases)' ($bad.Count -eq 0) ($bad -join ' | ')

# every automatic check of A stops the phase before any question
$acases = @(
    @('no host-hashes.txt', { param($c) Remove-Item -LiteralPath (Join-Path $c 'host-hashes.txt') }, 'host-pins', $false),
    @('a host-hashes.txt hash differs', { param($c) $p = Join-Path $c 'host-hashes.txt'; $t = [IO.File]::ReadAllText($p); $h = [regex]::Match($t, '[0-9A-F]{64}').Value; [IO.File]::WriteAllText($p, $t.Replace($h, ('0' * 64))) }, 'host-pins', $false),
    @('host-hashes.txt of another checkout', { param($c) $p = Join-Path $c 'host-hashes.txt'; $t = [IO.File]::ReadAllText($p); [IO.File]::WriteAllText($p, $t.Replace($CLRoot, 'C:\other\frameshift')) }, 'host-pins', $false),
    @('a pinned file changed after the hashes', { param($c) Add-Content -LiteralPath (Join-Path $CLRoot 'devices\quest3\host\fake-b.ps1') -Value '# changed' }, 'host-pins', $false),
    @('preflight not OK', { param($c) $script:cl3PfOk = $false }, 'preflight', $true),
    @('no soundcheck.json', { param($c) Remove-Item -LiteralPath (Join-Path $c 'soundcheck.json') }, 'soundcheck', $true),
    @('soundcheck.json Pass false', { param($c) [IO.File]::WriteAllText((Join-Path $c 'soundcheck.json'), '{"Schema": "frameshift.fs-soundcheck3c.v1", "Pass": false}') }, 'soundcheck', $true),
    @('no rehearsal summary', { param($c) Remove-Item -LiteralPath (Join-Path $c 'rehearsal-2\summary.txt') }, 'rehearsal', $true),
    @('rehearsal NO-GO', { param($c) $p = Join-Path $c 'rehearsal-2\summary.txt'; $t = [IO.File]::ReadAllText($p); [IO.File]::WriteAllText($p, ($t -replace 'answers [0-9.]+ s; go/no-go \(SIGNOFF-3c A, Q7\): GO \(<= 40 s\)', 'answers 66.6 s; go/no-go (SIGNOFF-3c A, Q7): NO-GO (> 40 s): stop and report (the Q7 fallback is already applied)')) }, 'rehearsal', $true),
    @('rehearsal GO without the Q7 fallback', { param($c) $p = Join-Path $c 'rehearsal-2\summary.txt'; $t = [IO.File]::ReadAllText($p); [IO.File]::WriteAllText($p, $t.Replace('not asked (Q7 fallback)', '')) }, 'rehearsal', $true),
    @('a preview missing', { param($c) Rename-Item -LiteralPath (Join-Path (Join-Path $CLRoot $script:FsCl3PreviewDir) 'F-reference-u-i-m-v.png') -NewName 'F-ref.bak' }, 'previews', $true))
$bad = @()
foreach ($ac in $acases) {
    $rt = New-Cl3Root; $c3 = New-Cl3Cycle $rt; $script:cl3PfOk = $true; $script:cl3PfCalls = 0; $script:cl3Nonce = 'c0de3c00000000c3'
    $saveRoot = $CLRoot; $CLRoot = $rt
    try { & $ac[1] $c3 } finally { $CLRoot = $saveRoot }
    $r = CL3Run $c3 'A' @('y', 'y', 'y') (Get-Cl3Opt $rt)
    $last = @((Get-Content -Raw (Join-Path $c3 'checklist3c.json') | ConvertFrom-Json).Entries)[-1]
    $failedNames = @(@($last.Checks) | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name })
    $pfExpected = if ($ac[3]) { 1 } else { 0 }        # pins fail -> nothing else runs (not even the preflight)
    if (-not ($r.Exit -eq 1 -and $last.Result -ceq 'STOP' -and $script:cl3Asked.Count -eq 0 -and @($last.Questions).Count -eq 0 -and ($failedNames -join ',') -ceq $ac[2] -and $script:cl3PfCalls -eq $pfExpected)) {
        $bad += "$($ac[0]): exit $($r.Exit) asked $($script:cl3Asked.Count) failed '$($failedNames -join ',')' preflight calls $($script:cl3PfCalls) why $($r.Why)" }
}
$script:cl3PfOk = $true
Check "CL5 phase A automatic checks ($($acases.Count) cases: host-hashes missing / a hash differs / another checkout / a pinned file changed afterwards; preflight; soundcheck missing / not passed; rehearsal missing / NO-GO / no Q7 fallback; a preview missing): STOP, exit 1, no question asked, exactly that check failed; on a pin mismatch the preflight is not even run" ($bad.Count -eq 0) ($bad -join ' | ')

# B: the single temperature reading (PM, J-125). Phase A ends at 07:58:09 (three questions at 3 s each), so phase B
# runs at 07:58:09: a reading at 07:43:09 is exactly 900 s old, 07:59:09 is exactly 60 s ahead.
# Review MAJOR-1: the values are passed as the TEXT typed (as the CLI passes them); "36.2", "0", "35", a status "2.6"
# are malformed (an [int] parameter rounded them: 36.2 -> 36 passed); 099 is well-formed but out of range.
# Review MAJOR-2: -R1Serial is required and must be one of the two units. Review MINOR: the age is compared exactly
# (900.04 s fails; with the 0.1 s rounding it passed as 900.0).
# Columns: name, R1, R1Utc, R1Status, expected exit, expected failed checks, [R1Serial: default Unit 1; '<none>' = not given]
$bcl = @(
    @('pass: 349, status 3 discharging', '349', '2026-10-11T07:50:00Z', '3', 0, ''),
    @('pass: status 4 not charging', '300', '2026-10-11T07:50:00Z', '4', 0, ''),
    @('pass: status 5 full', '300', '2026-10-11T07:50:00Z', '5', 0, ''),
    @('pass: the lowest, 100', '100', '2026-10-11T07:50:00Z', '5', 0, ''),
    @('pass: Unit 2', '300', '2026-10-11T07:50:00Z', '5', 0, '', 'QUEST3UNIT2'),
    @('boundary: exactly 900 s old', '349', '2026-10-11T07:43:09Z', '5', 0, ''),
    @('boundary: exactly 60 s ahead of the PC clock', '300', '2026-10-11T07:59:09Z', '5', 0, ''),
    @('fail: 350', '350', '2026-10-11T07:50:00Z', '5', 1, 'range-100-349'),
    @('fail: 099 (well-formed, below 100: a typing error)', '099', '2026-10-11T07:50:00Z', '5', 1, 'range-100-349'),
    @('fail: charging (status 2)', '300', '2026-10-11T07:50:00Z', '2', 1, 'not-charging'),
    @('fail: 349 but charging', '349', '2026-10-11T07:50:00Z', '2', 1, 'not-charging'),
    @('fail: 350 and charging', '350', '2026-10-11T07:50:00Z', '2', 1, 'range-100-349,not-charging'),
    @('fail: status 1 unknown', '300', '2026-10-11T07:50:00Z', '1', 1, 'not-charging'),
    @('fail: 901 s old', '300', '2026-10-11T07:43:08Z', '5', 1, 'at-most-15-min-old'),
    @('fail (MINOR, exact age): 900.04 s old (rounded to 900.0 it passed)', '300', '2026-10-11T07:43:08.96Z', '5', 1, 'at-most-15-min-old'),
    @('fail: 61 s in the future', '300', '2026-10-11T07:59:10Z', '5', 1, 'not-in-future'),
    @('fail (MAJOR-1): 36.2 (an [int] rounded it to 36 and passed)', '36.2', '2026-10-11T07:50:00Z', '5', 1, 'reading-input'),
    @('fail (MAJOR-1): 0', '0', '2026-10-11T07:50:00Z', '5', 1, 'reading-input'),
    @('fail (MAJOR-1): 35 (two digits: degrees, not tenths)', '35', '2026-10-11T07:50:00Z', '5', 1, 'reading-input'),
    @('fail (MAJOR-1): 312.0', '312.0', '2026-10-11T07:50:00Z', '5', 1, 'reading-input'),
    @('fail (MAJOR-1): 1000', '1000', '2026-10-11T07:50:00Z', '5', 1, 'reading-input'),
    @('fail (MAJOR-1): status 2.6 (an [int] rounded it to 3 and passed)', '300', '2026-10-11T07:50:00Z', '2.6', 1, 'reading-input'),
    @('fail (MAJOR-1): status 3.0', '300', '2026-10-11T07:50:00Z', '3.0', 1, 'reading-input'),
    @('fail: status 6 (not a dumpsys code)', '300', '2026-10-11T07:50:00Z', '6', 1, 'reading-input'),
    @('fail: status not given', '300', '2026-10-11T07:50:00Z', $null, 1, 'reading-input'),
    @('fail: a time without Z', '300', '2026-10-11T07:50:00', '5', 1, 'reading-input'),
    @('fail: the reading not given', $null, '2026-10-11T07:50:00Z', '5', 1, 'reading-input'),
    @('fail (MAJOR-2): no -R1Serial', '300', '2026-10-11T07:50:00Z', '5', 1, 'reading-input', '<none>'),
    @('fail (MAJOR-2): a serial that is not one of the two units', '300', '2026-10-11T07:50:00Z', '5', 1, 'known-unit', 'QUEST2UNIT'),
    @('fail (MAJOR-2): a unit serial in the wrong case', '300', '2026-10-11T07:50:00Z', '5', 1, 'known-unit', 'quest3unit1'))
$bad = @()
foreach ($bc in $bcl) {
    $c4 = New-Cl3Cycle $CLRoot; $script:cl3Clock = [DateTime]::Parse('2026-10-11T07:58:00Z').ToUniversalTime()
    $null = CL3Run $c4 'A' @('y', 'y', 'y') (Get-Cl3Opt $CLRoot)
    $ser = if ($bc.Count -gt 6) { $bc[6] } else { 'QUEST3UNIT1' }
    $more = @{ R1Utc = $bc[2] }; if ($null -ne $bc[1]) { $more.R1 = $bc[1] }; if ($null -ne $bc[3]) { $more.R1Status = $bc[3] }; if ($ser -cne '<none>') { $more.R1Serial = $ser }
    $r = CL3Run $c4 'B' @() (Get-Cl3Opt $CLRoot $more)
    $fn = @(@($r.Entry.Checks) | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name }) -join ','
    $rdOk = if ($r.Entry.PSObject.Properties['Reading']) { $r.Entry.Reading.Ok } else { $null }
    if ($r.Exit -ne $bc[4] -or $fn -cne $bc[5] -or $script:cl3Asked.Count -ne 0 -or ($bc[4] -eq 1 -and ($r.Entry.Result -cne 'STOP' -or $rdOk -eq $true)) -or ($bc[4] -eq 0 -and $rdOk -ne $true)) { $bad += "$($bc[0]): exit $($r.Exit) failed '$fn'" }
}
$c5 = New-Cl3Cycle $CLRoot
$r = CL3Run $c5 'B' @() (Get-Cl3Opt $CLRoot @{ R1 = '300'; R1Utc = '2026-10-11T07:55:00Z'; R1Status = '5'; R1Serial = 'QUEST3UNIT1' })
if ($r.Exit -ne 1 -or $r.Why -notmatch 'phase A has not passed') { $bad += "B without A: exit $($r.Exit) $($r.Why)" }
Check "CL6 phase B, the single temperature reading (J-125; review MAJOR-1/2, MINOR; $($bcl.Count) cases, every value as typed text): 349 not charging passes (status 3, 4, 5), 100 passes, Unit 2 passes, exactly 900 s old and exactly 60 s ahead pass; 350, 099, charging (status 2), unknown (1), 901 s old, 900.04 s old (exact age), 61 s ahead fail, each naming its check; 36.2, 0, 35, 312.0, 1000, a status 2.6 / 3.0 / 6, a missing status/time/reading/serial are malformed (reading-input); a serial of no Quest 3 unit (or in the wrong case) fails known-unit; B before A STOPs; nothing is asked" ($bad.Count -eq 0) ($bad -join ' | ')

# E prerequisites
$bad = @()
$c6 = New-Cl3Cycle $CLRoot; $null = CL3Run $c6 'A' @('y', 'y', 'y') (Get-Cl3Opt $CLRoot)
$r = CL3Run $c6 'E' @('y', 'y') (Get-Cl3Opt $CLRoot)
if ($r.Exit -ne 1 -or $r.Why -notmatch 'phase B' -or $script:cl3Asked.Count -ne 0) { $bad += "E without B: $($r.Why) asked $($script:cl3Asked.Count)" }
$c7 = New-Cl3Valid (New-Cl3Cycle $CLRoot) $CLRoot 'c0de3c00000000c7' ([DateTime]::Parse('2026-10-11T08:30:00Z').ToUniversalTime())
$null = CL3Run $c7 'A' @('n') (Get-Cl3Opt $CLRoot)
$r = CL3Run $c7 'E' @('y', 'y') (Get-Cl3Opt $CLRoot)
if ($r.Exit -ne 1 -or $r.Why -notmatch 'phase A has not passed' -or $script:cl3Asked.Count -ne 0) { $bad += "E after a later A STOP: $($r.Why)" }
$c8 = New-Cl3Cycle $CLRoot; [IO.File]::WriteAllText((Join-Path $c8 'checklist3c.json'), '{ not json')
$r = CL3Run $c8 'A' @('y', 'y', 'y') (Get-Cl3Opt $CLRoot)
if ($r.Exit -ne 1 -or $r.Why -notmatch 'unreadable' -or [IO.File]::ReadAllText((Join-Path $c8 'checklist3c.json')) -cne '{ not json' -or (Test-Path (Join-Path $c8 'checklist3c.txt'))) { $bad += "corrupt file: $($r.Why)" }
Check 'CL7 phase E needs A and B passed (the LAST entry of each): without B, or after a later failed A, it STOPs before asking; an unreadable checklist3c.json is never overwritten (STOP, nothing written)' ($bad.Count -eq 0) ($bad -join ' | ')

# the fs-observe3c gate on its own
$nv = 'c0de3c00000000c9'; $T9 = [DateTime]::Parse('2026-10-11T08:30:00Z').ToUniversalTime()
$c9 = New-Cl3Valid (New-Cl3Cycle $CLRoot) $CLRoot $nv $T9
$j9 = Join-Path $c9 'checklist3c.json'; $src9 = [IO.File]::ReadAllText($j9)
function CL3Mut([string]$name, [scriptblock]$mut) {
    # each mutated file in its own directory: the observer scans the checklist's directory for other BA summaries (second review MINOR-3)
    $d = Join-Path $Scratch ("cl3mut-" + (New-FsHex 3)); $null = New-Item -ItemType Directory -Force -Path $d; $p = Join-Path $d 'checklist3c.json'; $j = $src9 | ConvertFrom-Json; & $mut $j
    [IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 8)); $p
}
$U2 = 'QUEST3UNIT2'
$mkBat = { param([string]$t, [string]$st) $script:T3Bat.Replace('temperature: 300', "temperature: $t").Replace('status: 3', "status: $st") }
$gc = @(
    @('E exactly 300 s old', $j9, $T9.AddSeconds(300), $true, 'presence confirmed 300 s ago'),
    @('E 301 s old', $j9, $T9.AddSeconds(301), $false, 'phase E \(presence\) is 301 s old \(max 300 s\)'),
    @('E in the future', $j9, $T9.AddSeconds(-1), $false, 'in the future'),
    @('no file', (Join-Path $c9 'none.json'), $T9, $false, 'missing'),
    @('not given', '', $T9, $false, 'not given'),
    @('corrupt', (& { $p = Join-Path $Scratch 'cl3-corrupt.json'; [IO.File]::WriteAllText($p, '{'); $p }), $T9, $false, 'unreadable|not a frameshift'),
    @('phase A missing', (CL3Mut 'noA' { param($j) $j.Entries = @($j.Entries | Where-Object { $_.Phase -cne 'A' }) }), $T9, $false, 'phase A is missing'),
    @('phase B missing', (CL3Mut 'noB' { param($j) $j.Entries = @($j.Entries | Where-Object { $_.Phase -cne 'B' }) }), $T9, $false, 'phase B is missing'),
    @('phase E missing', (CL3Mut 'noE' { param($j) $j.Entries = @($j.Entries | Where-Object { $_.Phase -cne 'E' }) }), $T9, $false, 'phase E is missing'),
    @('a later E STOP after the PASS', (CL3Mut 'Estop' { param($j) $x = ($j.Entries[-1] | ConvertTo-Json -Depth 6 | ConvertFrom-Json); $x.Result = 'STOP'; $x.Why = "answer 'n'"; $j.Entries = @($j.Entries) + @($x) }), $T9, $false, 'phase E did not pass'),
    @('E PASS without the y to E2', (CL3Mut 'noE2' { param($j) $j.Entries[-1].Questions = @($j.Entries[-1].Questions | Select-Object -First 1) }), $T9, $false, 'lacks the answer y to question E2'),
    @('B reading not ok', (CL3Mut 'rdno' { param($j) $j.Entries[1].Reading.Ok = $false }), $T9, $false, 'does not record a passing temperature reading'),
    # review MAJOR-1: the observer applies phase B's text rules to what the file holds
    @('B reading edited to 350', (CL3Mut 'rd350' { param($j) $j.Entries[1].Reading.R1 = '350' }), $T9, $false, "temperature reading '350' is not three digits from 100 to 349"),
    @('B reading edited to 349', (CL3Mut 'rd349' { param($j) $j.Entries[1].Reading.R1 = '349' }), $T9, $true, 'temperature reading 349 \(battery status 5, unit QUEST3UNIT1\) 400 s before BA'),
    @('B reading edited to the number 349 (not the typed text)', (CL3Mut 'rdn349' { param($j) $j.Entries[1].Reading.R1 = 349 }), $T9, $false, "temperature reading '349' is not three digits"),
    @('B reading edited to 36.2', (CL3Mut 'rd362' { param($j) $j.Entries[1].Reading.R1 = '36.2' }), $T9, $false, "temperature reading '36\.2' is not three digits"),
    @('B reading edited to 099', (CL3Mut 'rd099' { param($j) $j.Entries[1].Reading.R1 = '099' }), $T9, $false, "temperature reading '099' is not three digits from 100 to 349"),
    @('B status edited to 2 (charging)', (CL3Mut 'rdchg' { param($j) $j.Entries[1].Reading.R1Status = '2' }), $T9, $false, "battery status '2' is not 3, 4 or 5"),
    @('B status edited to 2.6', (CL3Mut 'rd26' { param($j) $j.Entries[1].Reading.R1Status = '2.6' }), $T9, $false, "battery status '2\.6' is not 3, 4 or 5"),
    @('B status edited to the number 3', (CL3Mut 'rdn3' { param($j) $j.Entries[1].Reading.R1Status = 3 }), $T9, $false, "battery status '3' is not 3, 4 or 5"),
    @('B status edited to 3 (discharging)', (CL3Mut 'rddis' { param($j) $j.Entries[1].Reading.R1Status = '3' }), $T9, $true, 'battery status 3, unit QUEST3UNIT1\) 400 s before BA'),
    @('a v2 checklist (the reading as numbers, no unit)', (CL3Mut 'v2' { param($j) $j.Schema = 'frameshift.fs-checklist3c.v2' }), $T9, $false, 'not a frameshift\.fs-checklist3c\.v3 file'),
    @('a v1 checklist (the settled pair)', (CL3Mut 'v1' { param($j) $j.Schema = 'frameshift.fs-checklist3c.v1' }), $T9, $false, 'not a frameshift\.fs-checklist3c\.v3 file'),
    # review MAJOR-2: the reading belongs to the attempt's unit; no default unit
    @('the reading taken on Unit 2, the attempt on Unit 1', (CL3Mut 'rdU2' { param($j) $j.Entries[1].Reading.R1Serial = 'QUEST3UNIT2' }), $T9, $false, "taken on unit 'QUEST3UNIT2', not on this attempt's unit QUEST3UNIT1 \(Unit 1\)"),
    @('the reading without a unit', (CL3Mut 'rdU0' { param($j) $j.Entries[1].Reading.PSObject.Properties.Remove('R1Serial') }), $T9, $false, "taken on unit '', not on this attempt's unit"),
    @('no -Serial', $j9, $T9, $false, "no unit: -Serial '' is not one of the two Quest 3 units", @{ Serial = '' }),
    @('-Serial of no Quest 3 unit', $j9, $T9, $false, "no unit: -Serial 'QUEST2UNIT'", @{ Serial = 'QUEST2UNIT' }),
    @('the reading and the attempt on Unit 2, BA/BF summaries of Unit 1', (CL3Mut 'rdU2b' { param($j) $j.Entries[1].Reading.R1Serial = 'QUEST3UNIT2' }), $T9, $false, 'cannot tie the temperature reading to BA: BA summary: serial QUEST3UNIT1 is not QUEST3UNIT2', @{ Serial = $U2 }),
    @('everything on Unit 2', (CL3Mut 'rdU2c' { param($j) $j.Entries[1].Reading.R1Serial = 'QUEST3UNIT2' }), $T9, $true, 'unit QUEST3UNIT2\) 400 s before BA', @{ Serial = $U2; BaSerial = $U2 }),
    # review MAJOR-1: BA's own machine-captured dumpsys battery (BA10), from the BA SUMMARY of this nonce and serial
    @('BA10 temperature 349, status 4', $j9, $T9, $true, 'BA10 temperature 349, status 4, level 80', @{ Battery = (& $mkBat '349' '4') }),
    @('BA10 temperature 350', $j9, $T9, $false, 'BA10 \(dumpsys battery at BA\): temperature 350 at BA is not below 350', @{ Battery = (& $mkBat '350' '3') }),
    @('BA10 charging (status 2)', $j9, $T9, $false, 'BA10 \(dumpsys battery at BA\): battery status 2 at BA is not 3, 4 or 5', @{ Battery = (& $mkBat '300' '2') }),
    @('BA10 status 1 (unknown)', $j9, $T9, $false, 'battery status 1 at BA is not 3, 4 or 5', @{ Battery = (& $mkBat '300' '1') }),
    @('BA10 without a status line', $j9, $T9, $false, "does not hold exactly one 'temperature:' and one 'status:' line \(found 1 and 0\)", @{ Battery = $script:T3Bat.Replace("  status: 3`n", '') }),
    @('BA10 with two status lines', $j9, $T9, $false, "found 1 and 2", @{ Battery = $script:T3Bat.Replace("  status: 3`n", "  status: 3`n  status: 2`n") }),
    @('BA10.txt changed after the capture', $j9, $T9, $false, 'not the [0-9a-f]{64} recorded at BA \(changed after the capture\)', @{ MutBa10 = { param($d) Add-Content -LiteralPath (Join-Path $d 'BA10.txt') -Value '  temperature: 200' } }),
    @('BA10.txt missing', $j9, $T9, $false, 'BA10 \(dumpsys battery at BA\): missing: ', @{ MutBa10 = { param($d) Remove-Item -LiteralPath (Join-Path $d 'BA10.txt') } }),
    @('no BA10 row in the BA SUMMARY', $j9, $T9, $false, 'the BA SUMMARY has 0 BA10 rows', @{ NoBa10 = $true }),
    @('the BA10 row exited 1', $j9, $T9, $false, 'the BA10 row did not exit 0', @{ MutBa10 = { param($d) $sp = Join-Path $d 'SUMMARY.txt'; [IO.File]::WriteAllText($sp, ([IO.File]::ReadAllText($sp) -replace "(?m)^BA10`t0`t", "BA10`t1`t")) } }),
    @('out of order (B after E)', (CL3Mut 'order' { param($j) $j.Entries[1].EndUtc = '2026-10-11T08:31:00.0000000Z' }), $T9.AddSeconds(90), $false, 'order A, B, E'),
    @('another nonce', $j9, $T9, $false, 'not this attempt'),
    # LOW 9: every entry by the pinned checklist
    @('no pin for fs-checklist3c.ps1', $j9, $T9, $false, 'no pin for fs-checklist3c\.ps1', @{ Pin = '' }),
    @('an entry written by another fs-checklist3c.ps1', (CL3Mut 'tool' { param($j) $j.Entries[0].ToolSha256 = ('ab' * 32) }), $T9, $false, '1 entries were not written by the pinned fs-checklist3c\.ps1'),
    # MEDIUM 5 / J-125: the reading and the presence tied to this BA/BF (c9: the reading at T9 - 800 s, E from T9 - 6 s; BA at T9 - 400 s, BF at T9 - 200 s)
    @('the reading exactly 900 s before BA', (CL3Mut 'p900' { param($j) $j.Entries[1].Reading.R1Utc = (Format-FsCl3Utc $T9.AddSeconds(-1300)) }), $T9, $true, 'temperature reading 300 \(battery status 5, unit QUEST3UNIT1\) 900 s before BA \(max 900 s\)'),
    @('the reading 901 s before BA (a reading from before an abandoned cycle)', (CL3Mut 'p901' { param($j) $j.Entries[1].Reading.R1Utc = (Format-FsCl3Utc $T9.AddSeconds(-1301)) }), $T9, $false, 'the temperature reading is 901 s before BA started \(max 900 s\): a reading from before an abandoned cycle'),
    @('the reading exactly at BA start', (CL3Mut 'p0' { param($j) $j.Entries[1].Reading.R1Utc = (Format-FsCl3Utc $T9.AddSeconds(-400)) }), $T9, $true, ' 0 s before BA'),
    @('the reading after BA started', (CL3Mut 'pafter' { param($j) $j.Entries[1].Reading.R1Utc = (Format-FsCl3Utc $T9.AddSeconds(-399)) }), $T9, $false, 'is after BA started'),
    @('BF starting exactly when presence started', $j9, $T9, $true, 'presence after BF', @{ Bf = $T9.AddSeconds(-6) }),
    @('presence started before BF', $j9, $T9, $false, 'before BF started', @{ Bf = $T9.AddSeconds(-5) }),
    @('no BA summary', $j9, $T9, $false, 'cannot tie the temperature reading to BA: BA summary: (not given|missing)', @{ BaPath = '' }),
    @('BA summary of another nonce', $j9, $T9, $false, 'BA summary: nonce c0de3c00000000fe', @{ BaNonce = 'c0de3c00000000fe' }),
    @('no BF summary', $j9, $T9, $false, 'cannot tie the presence check to BF: BF summary', @{ BfPath = '' }))
$bad = @()
$k8 = 0
foreach ($g in $gc) {
    $k8++; $ex = if ($g.Count -gt 5) { $g[5] } else { @{} }
    $nn = if ($g[0] -ceq 'another nonce') { 'c0de3c00000000ff' } else { $nv }
    $baT = if ($ex.ContainsKey('Ba')) { $ex.Ba } else { $T9.AddSeconds(-400) }; $bfT = if ($ex.ContainsKey('Bf')) { $ex.Bf } else { $T9.AddSeconds(-200) }
    $baN = if ($ex.ContainsKey('BaNonce')) { $ex.BaNonce } else { $nv }
    $baS = if ($ex.ContainsKey('BaSerial')) { $ex.BaSerial } else { 'QUEST3UNIT1' }
    $batTxt = if ($ex.ContainsKey('Battery')) { $ex.Battery } else { $script:T3Bat }
    $baDir = Join-Path $Scratch "cl8-$k8\BA"
    $baP = New-Summary3c $baDir 'BA' $baN (Format-FsCl3Utc $baT) $baS $batTxt -NoBa10:([bool]$ex.ContainsKey('NoBa10')); $bfP = New-Summary3c (Join-Path $Scratch "cl8-$k8\BF") 'BF' $nv (Format-FsCl3Utc $bfT) $baS
    if ($ex.ContainsKey('MutBa10')) { & $ex.MutBa10 $baDir }
    if ($ex.ContainsKey('BaPath')) { $baP = $ex.BaPath }; if ($ex.ContainsKey('BfPath')) { $bfP = $ex.BfPath }
    $pin = if ($ex.ContainsKey('Pin')) { $ex.Pin } else { $script:clPinReal }
    $ser = if ($ex.ContainsKey('Serial')) { $ex.Serial } else { 'QUEST3UNIT1' }
    $v = Test-FsObsChecklist -Path $g[1] -Nonce $nn -NowUtc $g[2] -ToolPin $pin -BaSummary $baP -BfSummary $bfP -Serial $ser
    if ($v.Ok -ne $g[3] -or $v.Why -notmatch $g[4]) { $bad += "$($g[0]): ok=$($v.Ok) $($v.Why)" }
}
Check "CL8 Test-FsObsChecklist ($($gc.Count) cases): E at 300 s accepted, at 301 s, in the future, missing/unreadable file, a missing phase A/B/E, a later STOP, a missing y, a reading not passed refused; review MAJOR-1: the file's reading and status re-checked as typed text (350, 099, 36.2, the number 349, status 2, 2.6, the number 3 refused; 349 / status 3 accepted), a v1/v2 file refused, and BA's own BA10 dumpsys battery (349/4 accepted; 350, status 2, status 1, no or two status lines, a BA10.txt changed after the capture or missing, no BA10 row, a BA10 row that failed: each refused); review MAJOR-2: the reading taken on another unit or without one, no -Serial, a -Serial of no unit, BA/BF summaries of another unit refused, everything on Unit 2 accepted; phases out of order, another nonce; no pin / an entry not by the pinned tool (LOW 9); the reading 900 s before BA or at BA's start accepted, 901 s or after BA refused (J-125), presence from BF's start accepted, before it refused, BA/BF summary missing or of another nonce (MEDIUM 5): each with the reason" ($bad.Count -eq 0) ($bad -join ' | ')

# Invoke-FsObserve refuses without a valid checklist, with no device action
$bad = @()
$k9 = 0
foreach ($oc in @(@('no checklist', $null), @('presence 301 s old', 301), @('phase B missing', -1))) {
    $k9++; $nx = "c0de3c00000000d$k9"
    $bx = New-ObsBuild3c $nx
    $bax = New-Summary3c (Join-Path $bx.Base 'cap\BA') 'BA' $nx '2026-10-11T08:58:00.0000000Z'; $bfx = New-Summary3c (Join-Path $bx.Base 'cap\BF') 'BF' $nx '2026-10-11T08:59:00.0000000Z'
    if ($null -ne $oc[1]) {
        $null = New-Cl3Valid (Join-Path $bx.Base 'cap') $CLRoot $nx $TX.AddSeconds(-[Math]::Abs($oc[1]))
        if ($oc[1] -lt 0) { $jp = Join-Path $bx.Base 'cap\checklist3c.json'; $j = Get-Content -Raw $jp | ConvertFrom-Json; $j.Entries = @($j.Entries | Where-Object { $_.Phase -cne 'B' }); [IO.File]::WriteAllText($jp, ($j | ConvertTo-Json -Depth 8)) }
    }
    $o = Invoke-Obs3c $bx $nx $bax $bfx $TX
    if (-not ($o.Exit -eq 2 -and $o.Why -match '^REFUSED: console checklist: .*nothing booted, no device action' -and $script:fk3.Calls.Count -eq 0 -and $null -eq $o.OutDir -and
              -not (Test-Path (Join-Path $bx.Root "attempted\$nx.attempted")) -and -not (Test-Path (Join-Path $bx.Root 'abandoned')))) { $bad += "$($oc[0]): exit $($o.Exit) calls $($script:fk3.Calls.Count) $($o.Why)" }
}
# a <dir>\<nonce>\BA\SUMMARY.txt layout (fs-capture.ps1 -CapturesRoot <dir>): the checklist is also found in <dir>
$nx = 'c0de3c00000000e1'; $bx = New-ObsBuild3c $nx
$bax = New-Summary3c (Join-Path $bx.Base "cyc\$nx\BA") 'BA' $nx '2026-10-11T08:58:00.0000000Z'; $bfx = New-Summary3c (Join-Path $bx.Base "cyc\$nx\BF") 'BF' $nx '2026-10-11T08:59:00.0000000Z'
$null = New-Cl3Valid (Join-Path $bx.Base 'cyc') $CLRoot $nx $TX.AddSeconds(-20)
$o = Invoke-Obs3c $bx $nx $bax $bfx $TX
if (-not ($o.Exit -eq 0 -and $o.Observe.ChecklistFile -ceq (Join-Path $bx.Base 'cyc\checklist3c.json') -and [double]$o.Observe.ChecklistPresenceAgeSec -eq 20)) { $bad += "<dir>\<nonce> layout: exit $($o.Exit) $($o.Why)" }
# the WALKTHROUGH's dwell retry: a new pair (-Phase B again) and new BA/BF in <cycle>\retry-1\<nonce>\, -ChecklistFile <cycle>\checklist3c.json
$nx = 'c0de3c00000000e2'; $bx = New-ObsBuild3c $nx
$bax = New-Summary3c (Join-Path $bx.Base "cyc\retry-1\$nx\BA") 'BA' $nx '2026-10-11T08:58:00.0000000Z'; $bfx = New-Summary3c (Join-Path $bx.Base "cyc\retry-1\$nx\BF") 'BF' $nx '2026-10-11T08:59:00.0000000Z'
$null = New-Cl3Valid (Join-Path $bx.Base 'cyc') $CLRoot $nx $TX.AddSeconds(-20)
$o = Invoke-Obs3c $bx $nx $bax $bfx $TX
if (-not ($o.Exit -eq 2 -and $o.Why -match 'console checklist: missing: .*retry-1\\c0de3c00000000e2\\checklist3c\.json' -and $script:fk3.Calls.Count -eq 0)) { $bad += "retry without -ChecklistFile: exit $($o.Exit) $($o.Why)" }
$o = Invoke-Obs3c $bx $nx $bax $bfx $TX $false (Join-Path $bx.Base 'cyc\checklist3c.json')
if (-not ($o.Exit -eq 0 -and $o.Observe.ChecklistFile -ceq (Join-Path $bx.Base 'cyc\checklist3c.json'))) { $bad += "retry with -ChecklistFile: exit $($o.Exit) $($o.Why)" }
# MEDIUM 5 end to end: after an abandoned cycle, the OLD reading with a NEW BA 20 min later is refused before any device action
$nx = 'c0de3c00000000e3'; $bx = New-ObsBuild3c $nx
$null = New-Cl3Valid (Join-Path $bx.Base 'cyc') $CLRoot $nx $TX.AddSeconds(-1300)
$bax = New-Summary3c (Join-Path $bx.Base "cyc\retry-1\$nx\BA") 'BA' $nx '2026-10-11T08:58:00.0000000Z'; $bfx = New-Summary3c (Join-Path $bx.Base "cyc\retry-1\$nx\BF") 'BF' $nx '2026-10-11T08:59:00.0000000Z'
$script:cl3Clock = $TX.AddSeconds(-30); $null = CL3Run (Join-Path $bx.Base 'cyc') 'E' @('y', 'y') (Get-Cl3Opt $CLRoot)
$o = Invoke-Obs3c $bx $nx $bax $bfx $TX $false (Join-Path $bx.Base 'cyc\checklist3c.json')
if (-not ($o.Exit -eq 2 -and $o.Why -match 'the temperature reading is 1.?980 s before BA started \(max 900 s\)' -and $script:fk3.Calls.Count -eq 0 -and -not (Test-Path (Join-Path $bx.Root "attempted\$nx.attempted")))) { $bad += "old reading, new BA: exit $($o.Exit) $($o.Why)" }
$oj1 = Get-Content -Raw (Join-Path $b1.Dir ((Get-ChildItem -LiteralPath $b1.Dir -Directory -Filter 'observe-*')[0].Name + '\observe.json')) | ConvertFrom-Json
$ol1 = [IO.File]::ReadAllText((Join-Path $b1.Dir ((Get-ChildItem -LiteralPath $b1.Dir -Directory -Filter 'observe-*')[0].Name + '\observe.log')))
Check 'CL9 fs-observe3c refuses the attempt without a valid console checklist (none at <cycle>\checklist3c.json, presence 301 s old, phase B missing; after an abandoned cycle the old temperature reading with a new BA): exit 2, NO fastboot call (not even devices), not registered, no abandoned-cycle record; the default path is found for <cycle>\BA\SUMMARY.txt (X1) and <dir>\<nonce>\BA\SUMMARY.txt; the dwell retry (<cycle>\retry-1) needs -ChecklistFile and then passes; X1 records the checklist, checklist3c.txt (SHA-256), the tool pin and the reading to BA in observe.json and observe.log' `
    ($bad.Count -eq 0 -and $oj1.ChecklistFile -match 'cap\\checklist3c\.json$' -and $oj1.ChecklistSha256 -cmatch '^[0-9a-f]{64}\z' -and [double]$oj1.ChecklistPresenceAgeSec -eq 60 -and
     $oj1.ChecklistTxtFile -match 'cap\\checklist3c\.txt$' -and $oj1.ChecklistTxtSha256 -cmatch '^[0-9a-f]{64}\z' -and $oj1.ChecklistToolPin -ceq $script:clPinReal -and [double]$oj1.ChecklistReadingToBaSec -eq 620 -and -not $oj1.PSObject.Properties['ChecklistPairToBaSec'] -and
     $oj1.Serial -ceq 'QUEST3UNIT1' -and $oj1.Unit -ceq 'Unit 1' -and $oj1.Ba10Temperature -eq 300 -and $oj1.Ba10Status -eq 3 -and $oj1.Ba10Level -eq 80 -and $oj1.Ba10Sha256 -cmatch '^[0-9a-f]{64}\z' -and
     $ol1 -match 'console checklist: phases A, B, E passed; presence confirmed 60 s ago \(max 300 s\); temperature reading 300 \(battery status 5, unit QUEST3UNIT1\) 620 s before BA \(max 900 s\); BA10 temperature 300, status 3, level 80; presence after BF; tool = pin') ($bad -join ' | ')

# review MAJOR-2 end to end: the attempt names its unit (no default); a unit that is not the one attached is refused at fastboot devices
$bad = @()
$nx = 'c0de3c00000000f1'; $bx = New-ObsBuild3c $nx
$bax = New-Summary3c (Join-Path $bx.Base 'cap\BA') 'BA' $nx '2026-10-11T08:58:00.0000000Z'; $bfx = New-Summary3c (Join-Path $bx.Base 'cap\BF') 'BF' $nx '2026-10-11T08:59:00.0000000Z'
$null = New-Cl3Valid (Join-Path $bx.Base 'cap') $CLRoot $nx $TX.AddSeconds(-20)
foreach ($sv in @('', 'QUEST2UNIT', 'quest3unit1')) {
    $o = Invoke-Obs3c $bx $nx $bax $bfx $TX $false '' $sv
    if (-not ($o.Exit -eq 2 -and $o.Why -match "^REFUSED: -Serial '$sv' is not one of the two Quest 3 units .*nothing booted, no device action" -and $script:fk3.Calls.Count -eq 0 -and $null -eq $o.OutDir -and
              -not (Test-Path (Join-Path $bx.Root "attempted\$nx.attempted")))) { $bad += "-Serial '$sv': exit $($o.Exit) calls $($script:fk3.Calls.Count) $($o.Why)" }
}
$o = Invoke-Obs3c $bx $nx $bax $bfx $TX $true '' ''
if (-not ($o.Exit -eq 0 -and $o.Why -match '^preflight OK')) { $bad += "-Preflight without -Serial: exit $($o.Exit) $($o.Why)" }
# everything on Unit 2 (reading, BA/BF), but the attached device (the fake fastboot) is Unit 1: refused at fastboot devices, nothing booted
$nx = 'c0de3c00000000f2'; $bx = New-ObsBuild3c $nx
$bax = New-Summary3c (Join-Path $bx.Base 'cap\BA') 'BA' $nx '2026-10-11T08:58:00.0000000Z' 'QUEST3UNIT2'; $bfx = New-Summary3c (Join-Path $bx.Base 'cap\BF') 'BF' $nx '2026-10-11T08:59:00.0000000Z' 'QUEST3UNIT2'
$script:cl3Serial = 'QUEST3UNIT2'; try { $null = New-Cl3Valid (Join-Path $bx.Base 'cap') $CLRoot $nx $TX.AddSeconds(-20) } finally { $script:cl3Serial = 'QUEST3UNIT1' }
$o = Invoke-Obs3c $bx $nx $bax $bfx $TX $false '' 'QUEST3UNIT2'
if (-not ($o.Exit -eq 2 -and $o.Why -match 'need exactly one fastboot device, QUEST3UNIT2 \(got: QUEST3UNIT1\)' -and (@($script:fk3.Calls) -join ';') -ceq 'devices' -and
          -not (Test-Path (Join-Path $bx.Root "attempted\$nx.attempted")))) { $bad += "Unit 2 attempt, Unit 1 attached: exit $($o.Exit) calls $(@($script:fk3.Calls) -join ';') $($o.Why)" }
Check 'CL9b review MAJOR-2: an attempt without -Serial, with a serial of no Quest 3 unit, or with a wrongly cased serial is refused (exit 2) before any device query or registration; -Preflight needs no serial; a cycle wholly on Unit 2 with Unit 1 attached is refused at the one read-only fastboot devices query (nothing booted, not registered)' ($bad.Count -eq 0) ($bad -join ' | ')

# static: no device or network command in the checklist; ASCII
$clSrc = [IO.File]::ReadAllText($script:FsCl3Self)
$natives = @([regex]::Matches($clSrc, '&\s+[A-Za-z0-9_.-]+\.exe\b[^\n]*') | ForEach-Object { $_.Value })
Check 'CL10 static: fs-checklist3c.ps1 is ASCII with LF endings; its only native call is powershell.exe ... fs-observe3c.ps1 -Preflight; no Invoke-FsNative, adb/fastboot executable, Start-Process, serial port or network call' `
    (-not ($clSrc -match '[^\x00-\x7f]') -and $clSrc.IndexOf("`r") -lt 0 -and $natives.Count -eq 1 -and $natives[0] -match '^& powershell\.exe .*-File \$obs -Image \$ImagePath -Preflight' -and
     $clSrc -notmatch 'Invoke-FsNative|adb\.exe|fastboot\.exe|FastbootExe|Start-Process|SerialPort|Invoke-WebRequest|Invoke-RestMethod|Net\.WebClient|System\.Net\.|Get-FsGadget') ($natives -join ' | ')

# the CLI (child processes): usage, A on an empty cycle, B, E with a 1 s timeout
$c10 = New-Cl3Cycle $CLRoot; $script:cl3Clock = [DateTime]::UtcNow.AddSeconds(-30); $null = CL3Run $c10 'A' @('y', 'y', 'y') (Get-Cl3Opt $CLRoot)
$clx = Join-Path $T3Dir 'fs-checklist3c.ps1'
$u = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx; $uc = $LASTEXITCODE
$ce = Join-Path $Scratch 'cl3-empty'; $null = New-Item -ItemType Directory -Force -Path $ce
$oa = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase A -Cycle $ce -Image 'C:\none\boot-stage3c.img'; $ac = $LASTEXITCODE
$r1u = [DateTime]::UtcNow.AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
$obc = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase B -Cycle $c10 -R1 320 -R1Utc $r1u -R1Status 2 -R1Serial QUEST3UNIT1; $bcc = $LASTEXITCODE
# review MAJOR-1 through the real CLI (the bug was the [int] parameter binding): -R1 36.2 and -R1Status 2.6 are refused as malformed
$o362 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase B -Cycle $c10 -R1 36.2 -R1Utc $r1u -R1Status 5 -R1Serial QUEST3UNIT1; $c362 = $LASTEXITCODE
$o26 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase B -Cycle $c10 -R1 320 -R1Utc $r1u -R1Status 2.6 -R1Serial QUEST3UNIT1; $c26 = $LASTEXITCODE
$o0 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase B -Cycle $c10 -R1 0 -R1Utc $r1u -R1Status 5 -R1Serial QUEST3UNIT1; $c0 = $LASTEXITCODE
# review MAJOR-2 through the CLI: no -R1Serial is malformed
$ons = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase B -Cycle $c10 -R1 320 -R1Utc $r1u -R1Status 5; $cns = $LASTEXITCODE
$ob = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase B -Cycle $c10 -R1 320 -R1Utc $r1u -R1Status 5 -R1Charge 77 -R1Serial QUEST3UNIT1; $bc = $LASTEXITCODE
$oe = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase E -Cycle $c10 -TimeoutSec 1; $ec = $LASTEXITCODE
$ej = @((Get-Content -Raw (Join-Path $c10 'checklist3c.json') | ConvertFrom-Json).Entries)
$ea = @((Get-Content -Raw (Join-Path $ce 'checklist3c.json') | ConvertFrom-Json).Entries)
$mal = { param($e0, [string]$ck) $e0.Phase -ceq 'B' -and $e0.Result -ceq 'STOP' -and -not $e0.PSObject.Properties['Reading'] -and (@($e0.Checks | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name }) -join ',') -ceq $ck }
Check 'CL11 CLI: no arguments -> usage, exit 64; -Phase A on an empty cycle -> STOP (host-hashes.txt missing, checked first), exit 1, recorded; -Phase B (the Arbiter''s single reading) with -R1Status 2 (charging) -> STOP, exit 1; review MAJOR-1: -R1 36.2, -R1Status 2.6 and -R1 0 (an [int] parameter rounded them) -> STOP reading-input, exit 1; review MAJOR-2: no -R1Serial -> STOP reading-input; then with -R1Status 5 -R1Serial -> exit 0, PASS appended, the values recorded as the typed text; -Phase E with -TimeoutSec 1 and no key -> STOP (timeout or no console), exit 1, recorded' `
    ($uc -eq 64 -and ($u -join ' ') -match '^usage: fs-checklist3c\.ps1' -and ($u -join ' ') -match '-R1Serial <serial>' -and $ac -eq 1 -and $ea.Count -eq 1 -and $ea[0].Result -ceq 'STOP' -and $ea[0].Checks[0].Detail -match 'host-hashes\.txt' -and
     $bcc -eq 1 -and $ej.Count -eq 8 -and $ej[1].Phase -ceq 'B' -and $ej[1].Result -ceq 'STOP' -and $ej[1].Reading.R1Status -ceq '2' -and $ej[1].Reading.Ok -eq $false -and
     $c362 -eq 1 -and (& $mal $ej[2] 'reading-input') -and $ej[2].Checks[0].Detail -match "reading '36\.2'" -and $c26 -eq 1 -and (& $mal $ej[3] 'reading-input') -and $ej[3].Checks[0].Detail -match "battery status '2\.6'" -and
     $c0 -eq 1 -and (& $mal $ej[4] 'reading-input') -and $cns -eq 1 -and (& $mal $ej[5] 'reading-input') -and $ej[5].Checks[0].Detail -match "unit ''" -and
     $bc -eq 0 -and $ej[6].Phase -ceq 'B' -and $ej[6].Result -ceq 'PASS' -and $ej[6].Reading.R1 -ceq '320' -and $ej[6].Reading.R1Charge -ceq '77' -and $ej[6].Reading.R1Serial -ceq 'QUEST3UNIT1' -and $ec -eq 1 -and $ej[7].Phase -ceq 'E' -and $ej[7].Result -ceq 'STOP' -and
     @('timeout', 'noconsole') -ccontains [string]@($ej[7].Questions)[0].Answer) "usage $uc; A $ac; B(charging) $bcc $($obc -join ' / '); 36.2 $c362; 2.6 $c26; 0 $c0; no serial $cns; B $bc $($ob -join ' / '); E $ec $($oe -join ' / ')"

# second review of the single-reading branch (MINOR-1..5): malformed times refused (in process and through the CLI),
# the BA10 floor and level, Reading.Ok a JSON boolean, the reading tied to the first BA after it
$bad = @()
$ar = [string][char]0x0665; $fw = [string][char]0xFF15      # an Arabic-Indic and a fullwidth digit five (\d matched them)
foreach ($u0 in @(@('T24:00:00Z', '2026-10-11T24:00:00Z'), @(':60Z', '2026-10-11T07:59:60Z'), @('Arabic-Indic digit', "2026-10-11T07:${ar}0:00Z"), @('fullwidth digit', "2026-10-11T07:${fw}0:00Z"),
                  @('31 September', '2026-09-31T07:50:00Z'), @('eight fraction digits', '2026-10-11T07:50:00.12345678Z'))) {
    $c4 = New-Cl3Cycle $CLRoot; $script:cl3Clock = [DateTime]::Parse('2026-10-11T07:58:00Z').ToUniversalTime()
    $null = CL3Run $c4 'A' @('y', 'y', 'y') (Get-Cl3Opt $CLRoot)
    try { $r = CL3Run $c4 'B' @() (Get-Cl3Opt $CLRoot @{ R1 = '300'; R1Utc = $u0[1]; R1Status = '5'; R1Serial = 'QUEST3UNIT1' })
          $fn = @(@($r.Entry.Checks) | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name }) -join ','
          if ($r.Exit -ne 1 -or $fn -cne 'reading-input' -or $r.Entry.Result -cne 'STOP') { $bad += "phase B in process, $($u0[0]): exit $($r.Exit) failed '$fn'" } }
    catch { $bad += "phase B in process, $($u0[0]): threw $($_.Exception.Message)" }
}
foreach ($u0 in @('2026-10-11T07:50:00Z', '2026-10-11T07:50:00.5Z', '2026-10-11T07:50:00.1234567Z')) {
    $c4 = New-Cl3Cycle $CLRoot; $script:cl3Clock = [DateTime]::Parse('2026-10-11T07:58:00Z').ToUniversalTime()
    $null = CL3Run $c4 'A' @('y', 'y', 'y') (Get-Cl3Opt $CLRoot)
    $r = CL3Run $c4 'B' @() (Get-Cl3Opt $CLRoot @{ R1 = '300'; R1Utc = $u0; R1Status = '5'; R1Serial = 'QUEST3UNIT1' })
    if ($r.Exit -ne 0) { $bad += "phase B in process, well-formed $($u0): exit $($r.Exit) $($r.Why)" }
}
# the CLI (child processes): no exception (exit 70), a STOP at reading-input (exit 1)
$c18 = New-Cl3Cycle $CLRoot; $script:cl3Clock = [DateTime]::UtcNow.AddSeconds(-30); $null = CL3Run $c18 'A' @('y', 'y', 'y') (Get-Cl3Opt $CLRoot)
$k18 = 0
foreach ($u0 in @('2026-10-11T24:00:00Z', '2026-10-11T07:59:60Z', "2026-10-11T07:${ar}0:00Z")) {
    $k18++
    $o18 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $clx -Phase B -Cycle $c18 -R1 320 -R1Utc $u0 -R1Status 5 -R1Serial QUEST3UNIT1; $x18 = $LASTEXITCODE
    $e18 = @((Get-Content -Raw (Join-Path $c18 'checklist3c.json') | ConvertFrom-Json).Entries)
    if ($x18 -ne 1 -or $e18.Count -ne (1 + $k18) -or -not (& $mal $e18[-1] 'reading-input')) { $bad += "CLI -R1Utc '$u0': exit $x18 entries $($e18.Count) $(@($o18)[-1])" }
}
# Test-FsObsChecklist in process (it is called without a try): forged times in the file are refused, never accepted
$T18 = [DateTime]::Parse('2026-10-11T08:30:00Z').ToUniversalTime(); $n18 = 'c0de3c0000000018'
$c18v = New-Cl3Valid (New-Cl3Cycle $CLRoot) $CLRoot $n18 $T18
$s18 = [IO.File]::ReadAllText((Join-Path $c18v 'checklist3c.json'))
$mut18 = { param([scriptblock]$m) $d = Join-Path $Scratch ("cl18mut-" + (New-FsHex 3)); $null = New-Item -ItemType Directory -Force -Path $d; $p = Join-Path $d 'checklist3c.json'; $j = $s18 | ConvertFrom-Json; & $m $j; [IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 8)); $p }
$ba18 = { param([string]$tag, [string]$bat = $script:T3Bat, [string]$baUtc = (Format-FsCl3Utc $T18.AddSeconds(-400)))
          @((New-Summary3c (Join-Path $Scratch "cl18-$tag\BA") 'BA' $n18 $baUtc 'QUEST3UNIT1' $bat), (New-Summary3c (Join-Path $Scratch "cl18-$tag\BF") 'BF' $n18 (Format-FsCl3Utc $T18.AddSeconds(-200)))) }
$k18 = 0
foreach ($g in @(
    @('R1Utc T24:00:00Z (the lenient Parse threw, or on another runtime accepted it as the next midnight)', (& $mut18 { param($j) $j.Entries[1].Reading.R1Utc = '2026-10-11T24:00:00Z' }), $false, "no valid UTC time of the temperature reading \('2026-10-11T24:00:00Z'\)"),
    @('R1Utc :60Z', (& $mut18 { param($j) $j.Entries[1].Reading.R1Utc = '2026-10-11T08:16:60Z' }), $false, 'no valid UTC time of the temperature reading'),
    @('R1Utc with an Arabic-Indic digit', (& $mut18 { param($j) $j.Entries[1].Reading.R1Utc = "2026-10-11T08:1${ar}:00Z" }), $false, 'no valid UTC time of the temperature reading'),
    @('E EndUtc T24:00:00Z', (& $mut18 { param($j) $j.Entries[2].EndUtc = '2026-10-10T24:00:00Z' }), $false, "phase E has no valid UTC end time \('2026-10-10T24:00:00Z'\)"),
    @('B EndUtc with a fullwidth digit', (& $mut18 { param($j) $j.Entries[1].EndUtc = "2026-10-11T08:${fw}0:00Z" }), $false, 'phase B has no valid UTC end time'),
    @('E StartUtc :60Z', (& $mut18 { param($j) $j.Entries[2].StartUtc = '2026-10-11T08:29:60Z' }), $false, 'phase E has no valid UTC start time'),
    @('the BA SUMMARY header at T24:00:00Z', (Join-Path $c18v 'checklist3c.json'), $false, 'BA summary: header', @{ BaUtc = '2026-10-11T24:00:00.0000000Z' }),
    @('Reading.Ok the text "true" (it compared equal to $true)', (& $mut18 { param($j) $j.Entries[1].Reading.Ok = 'true' }), $false, 'Reading\.Ok must be the JSON boolean true'),
    @('Reading.Ok the number 1', (& $mut18 { param($j) $j.Entries[1].Reading.Ok = 1 }), $false, 'Reading\.Ok must be the JSON boolean true'),
    @('the unchanged file', (Join-Path $c18v 'checklist3c.json'), $true, 'BA10 temperature 300, status 3, level 80'),
    @('BA10 temperature 099 (below the typed reading''s floor)', (Join-Path $c18v 'checklist3c.json'), $false, 'temperature 099 at BA is below 100', @{ Bat = $script:T3Bat.Replace('temperature: 300', 'temperature: 099') }),
    @('BA10 temperature 50', (Join-Path $c18v 'checklist3c.json'), $false, 'temperature 50 at BA is below 100', @{ Bat = $script:T3Bat.Replace('temperature: 300', 'temperature: 50') }),
    @('BA10 temperature 100', (Join-Path $c18v 'checklist3c.json'), $true, 'BA10 temperature 100, status 3', @{ Bat = $script:T3Bat.Replace('temperature: 300', 'temperature: 100') }),
    @('BA10 level 50', (Join-Path $c18v 'checklist3c.json'), $false, 'battery level 50 at BA is not above 50', @{ Bat = $script:T3Bat.Replace('level: 80', 'level: 50') }),
    @('BA10 level 51', (Join-Path $c18v 'checklist3c.json'), $true, 'level 51', @{ Bat = $script:T3Bat.Replace('level: 80', 'level: 51') }),
    @('BA10 without a level line', (Join-Path $c18v 'checklist3c.json'), $false, "exactly one 'level:' line \(found 0\)", @{ Bat = $script:T3Bat.Replace("  level: 80`n", '') }))) {
    $k18++; $ex = if ($g.Count -gt 4) { $g[4] } else { @{} }
    $bat = if ($ex.ContainsKey('Bat')) { $ex.Bat } else { $script:T3Bat }; $bu = if ($ex.ContainsKey('BaUtc')) { $ex.BaUtc } else { Format-FsCl3Utc $T18.AddSeconds(-400) }
    $sm = & $ba18 "g$k18" $bat $bu
    try { $v = Test-FsObsChecklist -Path $g[1] -Nonce $n18 -NowUtc $T18 -ToolPin $script:clPinReal -BaSummary $sm[0] -BfSummary $sm[1] -Serial 'QUEST3UNIT1'
          if ($v.Ok -ne $g[2] -or $v.Why -notmatch $g[3]) { $bad += "$($g[0]): ok=$($v.Ok) $($v.Why)" } }
    catch { $bad += "$($g[0]): threw $($_.Exception.Message)" }
}
# MINOR-3: the reading is tied to the FIRST BA after it (c18v: the reading at T18 - 800 s; this BA at T18 - 400 s)
$fb = { param([string]$tag, [string]$firstBa, [string]$abandonBa = '', [string]$abandonNonce = $n18)
    $cy = Join-Path $Scratch "cl18fb-$tag"; $null = New-Item -ItemType Directory -Force -Path $cy
    Copy-Item -LiteralPath (Join-Path $c18v 'checklist3c.json') -Destination (Join-Path $cy 'checklist3c.json')
    if ($firstBa) { $null = New-Summary3c (Join-Path $cy 'BA') 'BA' $n18 $firstBa }
    $rb = New-Summary3c (Join-Path $cy "retry-1\$n18\BA") 'BA' $n18 (Format-FsCl3Utc $T18.AddSeconds(-400)); $rf = New-Summary3c (Join-Path $cy "retry-1\$n18\BF") 'BF' $n18 (Format-FsCl3Utc $T18.AddSeconds(-200))
    $ad = Join-Path $cy 'abandoned'
    if ($abandonBa) { $null = New-Item -ItemType Directory -Force -Path $ad; [IO.File]::WriteAllText((Join-Path $ad "20261011T081000Z-$abandonNonce.txt"), "ABANDONED CYCLE (fixture)`nBA started: $abandonBa`nchecked at: x`n") }
    Test-FsObsChecklist -Path (Join-Path $cy 'checklist3c.json') -Nonce $n18 -NowUtc $T18 -ToolPin $script:clPinReal -BaSummary $rb -BfSummary $rf -Serial 'QUEST3UNIT1' -AbandonedDir $ad }
foreach ($g in @(
    @('an earlier BA of the cycle 100 s after the reading (the abandoned first cycle), the retry BA within 900 s of the old reading', 'e1', (Format-FsCl3Utc $T18.AddSeconds(-700)), '', $false, 'is from before an earlier BA of this cycle'),
    @('an earlier BA exactly at the reading', 'e2', (Format-FsCl3Utc $T18.AddSeconds(-800)), '', $false, 'is from before an earlier BA of this cycle'),
    @('an earlier BA before the reading (a new reading after the abandoned cycle)', 'e3', (Format-FsCl3Utc $T18.AddSeconds(-801)), '', $true, '400 s before BA'),
    @('an earlier BA with an unreadable start time', 'e4', '2026-10-11T24:00:00.0000000Z', '', $false, 'has no readable start time'),
    @('an abandoned-cycle record of this nonce whose BA started after the reading', 'a1', '', (Format-FsCl3Utc $T18.AddSeconds(-650)), $false, 'is from before an abandoned cycle'),
    @('an abandoned-cycle record of another nonce', 'a2', '', (Format-FsCl3Utc $T18.AddSeconds(-650)), $true, '400 s before BA', 'c0de3c00000000aa'),
    @('an abandoned-cycle record whose BA was before the reading', 'a3', '', (Format-FsCl3Utc $T18.AddSeconds(-900)), $true, '400 s before BA'))) {
    $an = if ($g.Count -gt 6) { $g[6] } else { $n18 }
    try { $v = & $fb $g[1] $g[2] $g[3] $an; if ($v.Ok -ne $g[4] -or $v.Why -notmatch $g[5]) { $bad += "$($g[0]): ok=$($v.Ok) $($v.Why)" } } catch { $bad += "$($g[0]): threw $($_.Exception.Message)" }
}
# end to end: the WALKTHROUGH retry with the OLD reading (not -Phase B again) and the retry BA 10 min after it: refused, no device action
$nx = 'c0de3c00000000e4'; $bx = New-ObsBuild3c $nx
$null = New-Cl3Valid (Join-Path $bx.Base 'cyc') $CLRoot $nx $TX.AddSeconds(-20)            # the reading at TX - 820 s
$null = New-Summary3c (Join-Path $bx.Base 'cyc\BA') 'BA' $nx (Format-FsCl3Utc $TX.AddSeconds(-760))   # the first (abandoned) BA after it
$bax = New-Summary3c (Join-Path $bx.Base "cyc\retry-1\$nx\BA") 'BA' $nx (Format-FsCl3Utc $TX.AddSeconds(-200)); $bfx = New-Summary3c (Join-Path $bx.Base "cyc\retry-1\$nx\BF") 'BF' $nx (Format-FsCl3Utc $TX.AddSeconds(-100))
$o = Invoke-Obs3c $bx $nx $bax $bfx $TX $false (Join-Path $bx.Base 'cyc\checklist3c.json')
if (-not ($o.Exit -eq 2 -and $o.Why -match 'is from before an earlier BA of this cycle' -and $script:fk3.Calls.Count -eq 0 -and -not (Test-Path (Join-Path $bx.Root "attempted\$nx.attempted")))) { $bad += "retry with the old reading: exit $($o.Exit) calls $($script:fk3.Calls.Count) $($o.Why)" }
Check 'CL18 second review (MINOR-1..5): -R1Utc T24:00:00Z, :60Z, an Arabic-Indic or fullwidth digit, 31 September, eight fraction digits -> phase B STOP reading-input (in process and through the CLI: exit 1, never 70); well-formed times with 0, 1 or 7 fraction digits pass; Test-FsObsChecklist (called without a try) refuses a forged R1Utc/EndUtc/StartUtc (T24, :60, non-ASCII digits) and a BA SUMMARY header at T24 instead of accepting or throwing; Reading.Ok "true" or 1 refused; BA10 temperature 099/50 refused, 100 accepted; BA10 level 50 or none refused, 51 accepted; the reading tied to the first BA after it: an earlier BA of the cycle (or this nonce''s abandoned-cycle record) at or after the reading refuses, one before it does not, another nonce''s record is ignored, an unreadable one refuses; end to end the WALKTHROUGH retry with the old reading is refused before any device action' ($bad.Count -eq 0) ($bad -join ' | ')

# the real repository: the literal Get-FileHash command of SIGNOFF-3c A against its pin table; the docs
$sgn3 = [IO.File]::ReadAllText((Join-Path $T3Q3 'SIGNOFF-3c.md')); $wtk3 = [IO.File]::ReadAllText((Join-Path $T3Q3 'stage3c\WALKTHROUGH.md'))
$rows = Read-FsCl3PinTable (Join-Path $T3Q3 'SIGNOFF-3c.md')
$cmdS = [regex]::Match($sgn3, '`(Get-FileHash -Algorithm SHA256 -LiteralPath [^`]+)`').Groups[1].Value
$cmdW = [regex]::Match($wtk3, '`(Get-FileHash -Algorithm SHA256 -LiteralPath [^`]+)`').Groups[1].Value
$lst = { param($c) @(([regex]::Match($c, '-LiteralPath (.+?) \|')).Groups[1].Value -split ',\s*' | ForEach-Object { $_.Trim() } | Sort-Object) -join ';' }
$rc = Join-Path $Scratch 'cl3-real-cycle'; $null = New-Item -ItemType Directory -Force -Path $rc
Push-Location -LiteralPath $T3Root
try { $null = Invoke-Expression ($cmdS.Replace('<cycle>', $rc)) } finally { Pop-Location }
$hpReal = Test-FsCl3HostPins -HashesFile (Join-Path $rc 'host-hashes.txt') -SignoffFile (Join-Path $T3Q3 'SIGNOFF-3c.md') -Root $T3Root
Check 'CL12 the real SIGNOFF-3c pin table: it pins fs-checklist3c.ps1 and fs-observe3c.ps1; the literal Get-FileHash command (SIGNOFF-3c and WALKTHROUGH, identical file lists = the table) run from the repository root gives a host-hashes.txt that the checklist''s host-pin check accepts (every working file equals its pin)' `
    ($rows.Count -ge 15 -and @($rows | Where-Object { $_.Rel -ceq 'devices\quest3\host\fs-checklist3c.ps1' }).Count -eq 1 -and @($rows | Where-Object { $_.Rel -ceq 'devices\quest3\host\fs-observe3c.ps1' }).Count -eq 1 -and
     $cmdS -ceq $cmdW -and (& $lst $cmdS) -ceq ((@($rows | ForEach-Object { $_.Rel } | Sort-Object)) -join ';') -and $hpReal.Ok -and
     (Get-FsObsChecklistPin $T3Q3) -ceq (Get-FsCl3Sha $script:FsCl3Self)) "$($hpReal.Why) | cmd files $(& $lst $cmdS) | observer's pin $(Get-FsObsChecklistPin $T3Q3)"
$norm = { param($t) (([string]$t -replace '\s+', ' ').Trim()) }
$sgnN = & $norm $sgn3
$allTexts = @($script:FsCl3Q.Values) + (Get-FsCl3PreviewLines '<repository>') + $script:FsCl3Text.KeyLines + $script:FsCl3Text.Accept + $script:FsCl3Text.Presence + $script:FsCl3Text.After
$miss = @($allTexts | Where-Object { $sgnN.IndexOf((& $norm $_)) -lt 0 })
Check "CL13 SIGNOFF-3c.md (now the reference of what the console asks and records) carries every line the checklist prints, verbatim ($($allTexts.Count) lines: the five questions, the preview list with <repository> for the checkout's path, keys, points D1-D14, presence, after)" ($miss.Count -eq 0) ($miss -join ' | ')
$iA = $wtk3.IndexOf('fs-checklist3c.ps1 -Phase A'); $iB = $wtk3.IndexOf('fs-checklist3c.ps1 -Phase B'); $iE = $wtk3.IndexOf('fs-checklist3c.ps1 -Phase E')
$iBA = $wtk3.IndexOf('-Phase BA'); $iPair = $wtk3.IndexOf('**6. Temperature reading'); $iAtt = $wtk3.IndexOf('fs-observe3c.ps1 -Image <img>\boot-stage3c.img -Serial <serial> -ConfirmNonce')
$wB = [regex]::Match($wtk3, '`(powershell\.exe [^`]*fs-checklist3c\.ps1 -Phase B [^`]*)`').Groups[1].Value
Check 'CL14 WALKTHROUGH: the checklist commands at the right points (A after the rehearsal and before the reading and BA; B (the single temperature reading, J-125: -R1 -R1Utc -R1Status, run by the Arbiter) after the reading, before BA; E after BF, right before the attempt command); no settled-pair step, -R2 or 10-minute wait remains in the WALKTHROUGH or SIGNOFF-3c; no "tick"/"Sign section" step remains; SIGNOFF-3c has no tick boxes' `
    ($iA -gt $wtk3.IndexOf('Rehearsal') -and $iA -lt $iPair -and $iB -gt $iPair -and $iB -lt $iBA -and $iE -gt $wtk3.IndexOf('-Phase BF') -and $iE -lt $iAtt -and $wtk3 -notmatch '(?i)\btick|Sign section' -and $sgn3 -notmatch '- \[ \]' -and
     $wB -match '-R1 <t> -R1Utc <utc> -R1Status <status> -R1Serial <serial>' -and $wtk3 -match "the UTC time is the PC's UTC at the reading" -and $wtk3 -match "-Serial <serial> -ConfirmNonce <nonce>" -and $wB -notmatch '-R2' -and ($wtk3 + $sgn3) -notmatch '-R2Utc|-R2 <t|Wait at least\s+10 min|\*\*6\. Settled pair|## B\. Settled' -and $wtk3 -match 'the Arbiter runs') "A $iA B $iB E $iE reading $iPair BA $iBA attempt $iAtt; B command '$wB'"
$attS = '-BaSummary <cycle>\BA\SUMMARY.txt -BfSummary <cycle>\BF\SUMMARY.txt -ThenCollect'
Check 'CL14b paths (MUST 3, MUST 4): <cycle> = captures\<nonce> (fs-capture.ps1''s default root writes <cycle>\<phase>); BA, BF and AF without -CapturesRoot, each with -Serial <serial> and the user-build commands file (second review MINOR-4), fastboot -s <serial> reboot (no Unit-1 serial written in); the attempt (WALKTHROUGH and SIGNOFF-3c) with -BaSummary <cycle>\BA\SUMMARY.txt -BfSummary <cycle>\BF\SUMMARY.txt; -CapturesRoot only as <cycle>\retry-1 with -ChecklistFile; step 1 says to re-run it for the 15 files' `
    ($wtk3 -match '`<cycle>` = `captures\\<nonce>`' -and $wtk3.Contains($attS) -and $sgnN.Contains($attS) -and @([regex]::Matches($wtk3 + $sgn3, '-CapturesRoot <cycle>(?!\\retry-1)')).Count -eq 0 -and
     $wtk3 -match '-Phase BA -Nonce <nonce> -Serial <serial> -CommandsFile devices\\quest3\\host\\before-after\\commands-userbuild\.tsv`' -and $wtk3 -match '-Phase BF -Nonce <nonce> -Serial <serial> -CommandsFile devices\\quest3\\host\\before-after\\commands-userbuild\.tsv`' -and $wtk3 -match '-Phase AF -Nonce <nonce> -Serial <serial> -CommandsFile devices\\quest3\\host\\before-after\\commands-userbuild\.tsv`' -and
     $wtk3 -notmatch 'QUEST3UNIT1 reboot' -and $wtk3 -match 'fastboot -s <serial> reboot' -and $sgn3 -notmatch 'fastboot -s QUEST3UNIT1 reboot' -and $wtk3.Contains('-CapturesRoot <cycle>\retry-1') -and $wtk3.Contains('-ChecklistFile <cycle>\checklist3c.json') -and
     $wtk3 -match '(?s)\*\*1\. Host pins.{0,1600}15 files') ''
$real = $null
$C3Img = @(Get-ChildItem -LiteralPath (Join-Path $T3Root 'build\stage3c') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{16}\z' -and (Test-Path (Join-Path $_.FullName 'boot-stage3c.img')) } | Sort-Object Name | Select-Object -Last 1)
if ($C3Img.Count -eq 1) {
    $real = & $script:FsCl3RealPreflight (Join-Path $C3Img[0].FullName 'boot-stage3c.img')
    Check "CL15 the checklist's real preflight (fs-observe3c.ps1 -Preflight in a child process, no device action) on the newest candidate $($C3Img[0].Name): OK with its nonce" ($real.Ok -and $C3Img[0].Name.EndsWith([string]$real.Nonce) -and $real.ImageSha -cmatch '^[0-9a-f]{64}\z') $real.Why
} else { Skip 'CL15 real preflight' 'no build\stage3c candidate present' }

# LOW 8: Ctrl+C. A real Ctrl+C stops the pipeline (PipelineStoppedException, which a script cannot catch); a child
# process runs phase E with an Ask that raises exactly that at E2: the finally block writes the STOP entry.
$c16 = New-Cl3Valid (New-Cl3Cycle $CLRoot) $CLRoot 'c0de3c0000000016' ([DateTime]::UtcNow.AddSeconds(-120))
$h16 = Join-Path $Scratch 'cl16-ctrlc.ps1'
[IO.File]::WriteAllText($h16, (@(
    'param([string]$ClFile, [string]$CycDir)',
    '. $ClFile',
    '$script:n16 = 0',
    '$null = Invoke-FsCl3Phase -Phase E -Cycle $CycDir -Opt @{} -NowUtc { [DateTime]::UtcNow } -Say { param([string]$l) Write-Host $l } -Ask { param([string]$t, [int]$to) $script:n16++; if ($script:n16 -ge 2) { throw (New-Object System.Management.Automation.PipelineStoppedException) }; ''y'' }',
    'Write-Host ''NOT REACHED''') -join "`n") + "`n")
$o16 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $h16 -ClFile $script:FsCl3Self -CycDir $c16 | ForEach-Object { [string]$_ })
$l16 = @((Get-Content -Raw (Join-Path $c16 'checklist3c.json') | ConvertFrom-Json).Entries)[-1]
$v16 = Test-FsObsChecklist -Path (Join-Path $c16 'checklist3c.json') -Nonce 'c0de3c0000000016' -NowUtc ([DateTime]::UtcNow) -ToolPin $script:clPinReal -Serial 'QUEST3UNIT1'
Check 'CL16 LOW 8: Ctrl+C during phase E (PipelineStoppedException at E2, in a child process): the entry is written as STOP (interrupted), E1 y and E2 "interrupted" recorded with the question text, checklist3c.txt has the STOP, the console shows the STOPPED line; the run does not continue; fs-observe3c refuses that checklist' `
    ($l16.Phase -ceq 'E' -and $l16.Result -ceq 'STOP' -and $l16.Why -match '^interrupted' -and (@($l16.Questions | ForEach-Object { "$($_.Id)=$($_.Answer)" }) -join ',') -ceq 'E1=y,E2=interrupted' -and
     [string]@($l16.Questions)[1].Text -ceq $script:FsCl3Q.E2 -and [IO.File]::ReadAllText((Join-Path $c16 'checklist3c.txt')) -match '(?m)^== phase E: STOP ' -and
     @($o16 | Where-Object { $_ -cmatch '^STOPPED\. Nothing was sent to the headset\. Tell the Arbiter: phase E - interrupted' }).Count -eq 1 -and @($o16 | Where-Object { $_ -match 'NOT REACHED' }).Count -eq 0 -and
     -not $v16.Ok -and $v16.Why -match 'phase E did not pass') ("output: " + ($o16 -join ' / '))

# MEDIUM 6 and the wording: per-question time 900 s in phase A and 300 s in phase E (default), the prompt line, the wrap
$c17 = New-Cl3Cycle $CLRoot; $script:cl3Nonce = 'c0de3c0000000017'; $script:cl3PfOk = $true; $script:cl3Clock = [DateTime]::Parse('2026-10-11T08:00:00Z').ToUniversalTime()
$o17 = Get-Cl3Opt $CLRoot; $o17.Remove('TimeoutSec')
$null = CL3Run $c17 'A' @('y', 'y', 'y') $o17; $toA = @($script:cl3To); $said17 = @($script:cl3Said)
$null = CL3Run $c17 'B' @() (Get-Cl3Opt $CLRoot @{ R1 = '300'; R1Utc = '2026-10-11T07:55:00Z'; R1Status = '5'; R1Serial = 'QUEST3UNIT1' })
$o17e = Get-Cl3Opt $CLRoot; $o17e.Remove('TimeoutSec'); $null = CL3Run $c17 'E' @('y', 'y') $o17e; $toE = @($script:cl3To); $said17 += @($script:cl3Said)
$long = @($said17 | Where-Object { $_.Length -gt 90 -and @($_ -split ' ' | Where-Object { $_.Length -gt 80 }).Count -eq 0 })
$wr = Format-FsCl3Wrap ('  ' + $script:FsCl3Text.Accept[7]) 90
Check 'CL17 MEDIUM 6 / wording: the default time per question is 900 s in phase A and 300 s in phase E; the prompt reads "Press y for yes or n for no (15 minutes)." / "(5 minutes)."; every console line is at most 90 characters unless it holds a word longer than 80 characters (a path); a wrapped D item continues under its text; A3 is the D1-D14 consent' `
    (($toA -join ',') -ceq '900,900,900' -and ($toE -join ',') -ceq '300,300' -and (Format-FsCl3Prompt 900) -ceq 'Press y for yes or n for no (15 minutes).' -and (Format-FsCl3Prompt 300) -ceq 'Press y for yes or n for no (5 minutes).' -and
     (Format-FsCl3Prompt 1) -ceq 'Press y for yes or n for no (1 second).' -and $long.Count -eq 0 -and @($wr).Count -ge 3 -and @($wr | Select-Object -Skip 1 | Where-Object { $_ -cnotmatch '^      \S' }).Count -eq 0 -and
     (& $nz ($wr -join ' ')) -ceq (& $nz $script:FsCl3Text.Accept[7]) -and $script:FsCl3Q.A3 -ceq 'I have read points D1 to D14 above and I accept them (y/n)' -and
     ([IO.File]::ReadAllText($script:FsCl3Self)) -match 'FsCl3TimeoutA = 900' -and ([IO.File]::ReadAllText($script:FsCl3Self)) -match 'FsCl3FutureSlackSec = 60') ("A $($toA -join ',') E $($toE -join ',') long: $($long -join ' | ')")

# ------------------------------------------------------------------ Z --------
Say '== Z. interface cross-check against the device side (stage3c/fixtures/sim, fs-pattern v0.6 mock streams; skipped if absent)'
Check 'Z0 FSP1 plan lists: ONE encoding (DESIGN 6.2: dot-separated, no %XX): 0.0.1.1 -> 0,0,1,1, 71.97.100.103; a %XX-encoded, comma-separated, unavailable-missing, dash or 00.1 value reads as no list' `
    ((@(ConvertTo-Fs3cIntList '0.0.1.1') -join ',') -ceq '0,0,1,1' -and (@(ConvertTo-Fs3cIntList '71.97.100.103') -join ',') -ceq '71,97,100,103' -and @(ConvertTo-Fs3cIntList '0%2C0%2C1%2C1').Count -eq 0 -and
     @(ConvertTo-Fs3cIntList '0,0,1,1').Count -eq 0 -and @(ConvertTo-Fs3cIntList 'unavailable-missing').Count -eq 0 -and @(ConvertTo-Fs3cIntList '-').Count -eq 0 -and @(ConvertTo-Fs3cIntList '00.1').Count -eq 0)
$simDir = Join-Path $T3Q3 'stage3c\fixtures\sim'
function ZRun([string]$f, [int]$runN) {
    [byte[]]$b = [IO.File]::ReadAllBytes((Join-Path $simDir $f))
    $t = [System.Text.Encoding]::GetEncoding(28591).GetString($b)
    $n8 = [regex]::Match($t, '^FSP1 nonce=([0-9a-f]{8}) ').Groups[1].Value
    $code = [regex]::Match($t, '(?m)step=exit rc=[-0-9]+ code=([0-9]+) ').Groups[1].Value
    $st = New-SynthStep 2 "pattern$runN" $b @() @{ code = [long]$code }
    Get-Fs3cRun $st $runN $n8
}
$zc = @(
    @('quad-vig.txt', 2, { param($r) $q = Test-Fs3cQuadPost $r; $r.Kind -ceq 'run' -and $r.CommitLayout -ceq 'quad_vig' -and $q.Ok -and $r.HeldClean -and (@($r.ZposSet) -join ',') -ceq '0,0,1,1' }, 'quad_vig committed; post_plane matches after the conversion; zpos_set 0,0,1,1'),
    @('quad-dma.txt', 2, { param($r) $q = Test-Fs3cQuadPost $r; $r.CommitLayout -ceq 'quad_dma' -and $q.Ok }, 'quad_dma committed (115/134/112/131); post_plane matches'),
    @('quad-noconv.txt', 2, { param($r) $q = Test-Fs3cQuadPost $r; -not $q.Ok -and $q.Unconverted -and -not $q.ZposBad }, 'CRTC_X read back unconverted: the finding, not an inconsistency'),
    @('quad-reject.txt', 2, { param($r) $r.Kind -ceq 'run' -and $r.Code -eq 50 -and -not $r.Committed }, 'every quad attempt rejected: exit 50, nothing committed'),
    @('quad-active.txt', 2, { param($r) $r.Code -eq 31 -and $null -ne $r.Precond -and $r.Precond.Rc -eq -16 }, 'CRTC active: exit 31 with the precondition record'),
    @('solid.txt', 3, { param($r) $q = Test-Fs3cQuadPost $r; $r.Mode -ceq 'show-off-solid' -and $q.Ok -and $r.HeldClean }, 'show-off-solid committed a quad layout, post_plane matches'),
    @('show-run1.txt', 1, { param($r) $r.Mode -ceq 'show' -and $r.Committed -and -not $r.ZposOutsideQuad }, 'run 1 (show): committed, no zpos'))
foreach ($z in $zc) {
    if (-not (Test-Path -LiteralPath (Join-Path $simDir $z[0]))) { Skip "Z $($z[0])" 'device-side fixture not present'; continue }
    $r = ZRun $z[0] $z[1]
    Check "Z $($z[0]) (run $($z[1])) read by the host classifier: $($z[3])" ([bool](& $z[2] $r)) "kind=$($r.Kind) why=$($r.Why) code=$($r.Code) layout=$($r.CommitLayout) mode=$($r.Mode) $((Test-Fs3cQuadPost $r).Why)"
}
$fp = Join-Path $T3Q3 'stage3c\fs-phase.sh'
if (Test-Path -LiteralPath $fp) {
    $ft = [IO.File]::ReadAllText($fp)
    Check 'Z9 stage3c/fs-phase.sh prints the FSPM1 and FSXE1 lines in the grammar this host parses (printf formats)' ($ft.Contains("printf 'FSPM1 n=%s p=%s e=%s t=%s END\n'") -and $ft.Contains("printf 'FSXE1 p=%s ran=%s error=%s END\n'") -and $ft.Contains('"s3c_$PH"'))
} else { Skip 'Z9 fs-phase.sh' 'device-side file not present' }

# ------------------------------------------------------------------ Z2 -------
# END TO END (integration pass): every device-side whole-image capture (stage3c/fixtures/image/<scenario>/capture.raw
# + .idx, written by tools/image-harness-3c.py from the candidate's own /init under qemu/bwrap) is replayed through
# fs-collect3c (Invoke-Fs3cReplay, scripted keys) and classified by fs-classify3c (Invoke-Fs3cClassifyDir, stage 1
# given as PASS: the harness has no observer). Expectations from DESIGN 11.1/11.3 and the scenario table of 12.3.
# Two kinds of scenario:
#   conformant  the harness host sent what the 3c collector sends: the replay must not diverge, every recorded write
#               must be performed, and the <prev> the collector recomputes must equal the recorded one;
#   deviating   the harness host played a faulty or crashed host (order, repeat, bad chain, early fs-done, no ack,
#               no command, r3 against the run-3 rule): the replay must diverge at exactly that write (the 3c
#               collector does not make it), and the device's own refusal or skip in the source capture must read
#               with the host's parsers.
# sim-* scenarios replace /bin/fs-pattern (the harness mod note): classified with the built-in pin, p0 must be an
# INTEGRITY FAULT naming the replacement's digest; the rest is classified with that digest as the pin. The genuine
# scenarios are classified with the built-in pin and must give P0 OK (the pin is the image's binary).
Say '== Z2. end to end: the device whole-image captures through fs-collect3c replay + fs-classify3c (skipped if absent)'
$E2Dir = Join-Path $T3Q3 'stage3c\fixtures\image'
$E2Ov = @{ Kernel = '6.18.33.2-microsoft-standard-WSL2'; Pid1 = '/usr/bin/qemu-aarch64,/bin/busybox,/bin/busybox,sh,/init' }   # the harness's qemu-user FSV1 identity
$EK1 = @('p:1500:b', 'p:900:b', 'p:800:y')                                                                   # left dark, right dark, dark now
$EK2G = @('p:1800:c', 'p:900:c', 'p:800:y')                                                                   # run 2 garbled in both eyes (run-3 path: no bars, Q7 fallback)
$EK2GB = $EK2G + @('p:1500:1', 'p:400:2', 'p:1500:3', 'p:400:4')                                              # the same off the run-3 path (rule 1 fails): bars 12 / 34
$EK3 = @('p:2000:r', 'p:900:r', 'p:800:y')                                                                   # run 3 uniform red in both eyes
$EPass = @{ p0 = 'P0 OK'; r1 = 'R1 SHOWN'; r2 = 'R2 SHOWN-QUAD'; r3 = 'R3 SHOWN-QUAD-SOLID' }
$E2 = [ordered]@{
    'c-nodrm'            = @{ Sim = $false; KeyScript = $EK1 + $EK1; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 15; Outcome = 'NO-DISPLAY'; Phases = @{ p0 = 'P0 OK'; r1 = 'NO-DISPLAY'; r2 = 'SKIPPED'; r3 = 'NOT RUN' }; Why = @{ r2 = 'run1-supervisor' } }
    'c-sim-all'          = @{ Sim = $true; KeyScript = $EK1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Tag = 'quad_vig'; Interp = 'T1' }
    'c-sim-r2-dma'       = @{ Sim = $true; KeyScript = $EK1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Tag = 'quad_dma'; Interp = '-' }   # the harness r3 sim commits quad_vig: R2/R3 tags differ -> LAYOUT DIFFERS (DESIGN 11.3)
    'c-sim-r2-reject'    = @{ Sim = $true; KeyScript = $EK1 + $EK2GB; Sent = 'p0,r1,r2,fs-done'; Div = "^collector wrote 'fs-done'; recorded write was 'fs-phase r3 "; Code = 18; Outcome = 'RUN 1 ONLY'; Phases = @{ p0 = 'P0 OK'; r1 = 'R1 SHOWN'; r2 = 'NO-DISPLAY'; r3 = 'NOT RUN' }; Why = @{ r3 = 'rule 1' }; SrcSkip = 'FSK1 run=3 skipped reason=run2-supervisor END' }
    'c-sim-active'       = @{ Sim = $true; KeyScript = $EK1 + $EK1; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 18; Outcome = 'RUN 1 ONLY'; Phases = @{ p0 = 'P0 OK'; r1 = 'R1 SHOWN'; r2 = 'PRECONDITION UNMET: CRTC ACTIVE'; r3 = 'NOT RUN' } }
    'c-sim-unclean'      = @{ Sim = $true; KeyScript = $EK1 + $EK1; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 18; Outcome = 'RUN 1 ONLY'; Phases = @{ p0 = 'P0 OK'; r1 = 'R1 SHOWN, UNCLEAN CLOSE'; r2 = 'SKIPPED'; r3 = 'NOT RUN' }; Why = @{ r2 = 'run1-close-not-clean' } }
    'c-pause'            = @{ Sim = $true; KeyScript = $EK1 + $EK1; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = @{ p0 = 'P0 OK'; r1 = 'R1 SHOWN'; r2 = 'R2 SHOWN-QUAD'; r3 = 'NOT RUN' }; Tag = 'quad_vig'; Why = @{ r3 = 'rule 2' } }
    'c-pause-fault'      = @{ Sim = $true; KeyScript = $EK1 + $EK1; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 18; Outcome = 'RUN 1 ONLY'; Phases = @{ p0 = 'P0 OK'; r1 = 'R1 SHOWN'; r2 = 'SKIPPED'; r3 = 'NOT RUN' }; Why = @{ r2 = 'pause-fault' } }
    'c-markers'          = @{ Sim = $true; KeyScript = $EK1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Tag = 'quad_vig'; Interp = 'T1'; Markers = $true }
    'c-sim-r3-hold'      = @{ Sim = $true; KeyScript = $EK1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Tag = 'quad_vig'; Interp = 'T1' }
    'c-no-debugfs'       = @{ Sim = $true; KeyScript = $EK1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Tag = 'quad_vig'; Interp = 'T1' }
    'c-probe-hang'       = @{ Sim = $false; KeyScript = $EK1 + $EK1; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'SKIPPED'; r2 = 'SKIPPED'; r3 = 'NOT RUN' }; Why = @{ r1 = 'probe-late'; r2 = 'run1-not-run' } }
    'c-no-backlight'     = @{ Sim = $false; KeyScript = $EK1 + $EK1; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'BRIGHTNESS NOT VERIFIED'; r1 = 'SKIPPED'; r2 = 'SKIPPED'; r3 = 'NOT RUN' }; Why = @{ r1 = 'p0-write-missing'; r2 = 'run1-not-run' } }
    'c-record-too-large' = @{ Sim = $true; KeyScript = $EK1; Sent = 'p0,r1,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'REFUSED'; r2 = 'NOT RUN'; r3 = 'NOT RUN' }; Why = @{ r1 = 'ran=1 error=record-too-large' }; Readings = 'r1'; MarkSeq = @{ r1 = 'begin,go,end' } }
    'c-step-fail'        = @{ Sim = $true; KeyScript = $EK1; Sent = 'p0,r1,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'REFUSED'; r2 = 'NOT RUN'; r3 = 'NOT RUN' }; Why = @{ r1 = 'ran=1 error=step1' }; Readings = 'r1'; MarkSeq = @{ r1 = 'begin,go,end' } }
    'c-time'             = @{ Sim = $false; KeyScript = @(); Sent = 'p0,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'REFUSED'; r1 = 'NOT RUN'; r2 = 'NOT RUN'; r3 = 'NOT RUN' }; Why = @{ p0 = 'ran=0 error=time' }; Readings = '' }
    'c-idle'             = @{ Sim = $false; KeyScript = $EK1; Sent = 'p0,r1,r2'; Div = "^collector wrote 'fs-phase r2 [0-9a-f]{32} [0-9a-f]{16}'; recorded write was '\(none"; Code = 15; Outcome = 'NO-DISPLAY'; Phases = @{ p0 = 'P0 OK'; r1 = 'NO-DISPLAY'; r2 = 'INCONCLUSIVE'; r3 = 'NOT RUN' }; NoDone = $true }
    'c-idle-stuck'       = @{ Sim = $false; KeyScript = @(); Sent = 'p0,r1'; Div = "^collector wrote 'fs-phase r1 [0-9a-f]{32} [0-9a-f]{16}'; recorded write was '\(none"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'INCONCLUSIVE'; r2 = 'NOT RUN'; r3 = 'NOT RUN' }; NoDone = $true }
    'c-order'            = @{ Sim = $false; KeyScript = @(); Sent = 'p0,r1'; Div = "^collector wrote 'fs-phase r1 [0-9a-f]{32} [0-9a-f]{16}'; recorded write was 'fs-phase r2 "; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'INCONCLUSIVE' }; NoDone = $true; SrcRefusal = @('r2', 0, 'order'); SrcRefusals = @(@('r2', 0, 'order'), @('r1', 0, 'order')) }
    'c-usage-then-p0'    = @{ Sim = $false; KeyScript = @(); Sent = 'p0'; Div = "^collector wrote 'fs-phase p0 [0-9a-f]{32} 0{16}'; recorded write was 'fs-phase p0 nothex 0{16}'"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'INCONCLUSIVE'; r1 = 'NOT RUN' }; NoDone = $true; SrcRefusal = @('p0', 0, 'usage'); SrcRefusals = @(@('p0', 0, 'usage'), @('p0', 0, 'order')) }
    'c-repeat'           = @{ Sim = $false; KeyScript = @(); Sent = 'p0,r1'; Div = "^collector wrote 'fs-phase r1 [0-9a-f]{32} [0-9a-f]{16}'; recorded write was 'fs-phase p0 "; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'INCONCLUSIVE' }; NoDone = $true; SrcRefusal = @('p0', 0, 'already-run') }
    'c-chain-bad'        = @{ Sim = $false; KeyScript = @(); Sent = 'p0,r1'; Div = "^collector wrote 'fs-phase r1 [0-9a-f]{32} (?!f{16})[0-9a-f]{16}'; recorded write was 'fs-phase r1 [0-9a-f]{32} f{16}'"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'INCONCLUSIVE' }; NoDone = $true; SrcRefusal = @('r1', 0, 'chain') }
    'c-done-early'       = @{ Sim = $false; KeyScript = @(); Sent = 'fs-verify,fs-ack'; Div = "^collector wrote 'fs-ack [0-9a-f]{16}'; recorded write was 'fs-done'"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'NOT RUN' }; NoDone = $true; Pre = $true }
    'c-no-ack'           = @{ Sim = $false; KeyScript = @(); Sent = 'fs-verify,fs-ack'; Div = "^collector wrote 'fs-ack [0-9a-f]{16}'; recorded write was '\(none"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'NOT RUN' }; NoDone = $true; Pre = $true }
    'c-ack-no-done'      = @{ Sim = $false; KeyScript = @(); Sent = 'p0'; Div = "^collector wrote 'fs-phase p0 [0-9a-f]{32} 0{16}'; recorded write was '\(none"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'INCONCLUSIVE' }; NoDone = $true }
}
$E2Res = New-Object System.Collections.Generic.List[string]; $E2Repl = @{}; $script:E2RepPin = ''
# the digest the p0 hash step measured in a source capture (the sim-* fakes replace /bin/fs-pattern): the collector's p0
# integrity gate (build review MAJOR-1) is given it as the pin for those replays, exactly as the classifier is below
function E2P0Digest([string]$src) {
    [byte[]]$b = [IO.File]::ReadAllBytes($src); $ix0 = Read-FsCaptureIndex -Path "$src.idx" -RawLength $b.Length
    $all0 = Get-Fs3cSlices -Raw $b -Events (Read-Fs3cIndexEvents -Path "$src.idx" -RawLength $b.Length)
    $s0 = @($all0 | Where-Object { $_.Ph -ceq 'p0' })
    if ($s0.Count -lt 1) { return '' }
    $d0 = Test-Fsb1Record -Bytes $s0[0].Bytes -Exp 's3c_p0' -Nonce $ix0.Nonce -Challenge $s0[0].Chal -Steps $script:S3cSteps['p0']
    if (-not $d0.Ok) { return '' }
    $m0 = [regex]::Match($script:S2L1.GetString([byte[]]@($d0.Steps)[0]['out']), '^([0-9a-f]{64})  /bin/fs-pattern\n\z')
    if ($m0.Success) { $m0.Groups[1].Value } else { '' }
}
$E2Have = @(Get-ChildItem -LiteralPath $E2Dir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'capture.raw') } | ForEach-Object { $_.Name })
if ($E2Have.Count -eq 0) { Skip 'Z2 end to end' 'device-side stage3c/fixtures/image not present' }
else {
    Check "Z2.0 every device whole-image scenario has an end-to-end expectation here and vice versa ($($E2Have.Count) captures)" ((@($E2Have | Sort-Object) -join ',') -ceq (@($E2.Keys | Sort-Object) -join ',')) "captures: $($E2Have -join ',')"
    foreach ($sn in $E2.Keys) {
        $e = $E2[$sn]; $src = Join-Path $E2Dir "$sn\capture.raw"
        if (-not (Test-Path -LiteralPath $src)) { Skip "Z2 $sn" 'capture absent'; continue }
        $script:T3N++
        $od = Join-Path $Scratch ("{0:D3}-e2e-{1}" -f $script:T3N, $sn)
        $ui = New-Fs3cUi -Kind record; $ks = New-Fs3cScriptedKeySource -Script $e.KeyScript; $sink = New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd
        $ovE = @{} + $E2Ov; if ($e.Sim) { $ovE['PatternPin'] = E2P0Digest $src }
        $r = Invoke-Fs3cReplay -RawPath $src -OutDirX $od -Overrides $ovE -Ui $ui -Keys $ks -Sound $sink -Sounds $script:T3Snd
        $sent = (@($r.Sent | ForEach-Object { $w = $_ -split ' '; if ($w[0] -ceq 'fs-phase') { $w[1] } elseif (@('fs-verify', 'fs-ack', 'fs-status') -ccontains $w[0]) { if ($e.ContainsKey('Pre')) { $w[0] } else { $null } } else { $w[0] } } | Where-Object { $_ }) -join ',')
        $div = @($r.Replay.Divergence)
        $divOk = if ($e.Div) { $div.Count -ge 1 -and $div[0] -cmatch $e.Div } else { $div.Count -eq 0 -and @($r.Replay.UnperformedWrites).Count -eq 0 -and @($r.Replay.PrevCheck | Where-Object { -not $_.Same }).Count -eq 0 }
        $c = Invoke-Fs3cClassifyDir -DirX $od -S1X 'PASS'                         # the built-in v0.6 pin
        $pinNote = 'built-in pin'
        if ($e.Sim) {
            $p0r = [string]$c.Outcome.Phases['p0'].Reason
            $simOk = ($c.Code -eq 12 -and $c.Outcome.Phases['p0'].Class -ceq 'INTEGRITY FAULT' -and $p0r -cmatch "digest ([0-9a-f]{64}) != pin $($script:S3cPatternPin)")
            $rep = if ($simOk) { $Matches[1] } else { '' }
            if (-not $script:E2RepPin) { $script:E2RepPin = $rep }
            Check "Z2 $sn (sim) with the built-in pin: p0 INTEGRITY FAULT naming the replacement's digest (the harness mod note: the hash step measures the replacement), exit 12" ($simOk -and $rep -ceq $script:E2RepPin) "code $($c.Code) p0 $($c.Outcome.Phases['p0'].Class): $p0r"
            if ($rep) { $c = Invoke-Fs3cClassifyDir -DirX $od -S1X 'PASS' -PinX $rep; $pinNote = 'the replacement digest as the pin' }
        }
        $o = $c.Outcome
        $phOk = $true; $phDesc = @()
        foreach ($k in $e.Phases.Keys) { if ($null -eq $o -or $o.Phases[$k].Class -cne $e.Phases[$k]) { $phOk = $false }; $phDesc += "$k=$(if ($o) { $o.Phases[$k].Class } else { '?' })" }
        if ($e.ContainsKey('Why')) { foreach ($k in $e.Why.Keys) { if ($null -eq $o -or $o.Phases[$k].Reason -notmatch [regex]::Escape($e.Why[$k])) { $phOk = $false; $phDesc += "$k why '$($o.Phases[$k].Reason)'" } } }
        $extra = $true; $xd = @()
        if ($e.ContainsKey('Tag')) { if ($o.Phases['r2'].Tag -cne $e.Tag) { $extra = $false; $xd += "r2 tag $($o.Phases['r2'].Tag)" } }
        if ($e.ContainsKey('Interp')) { if ($null -eq $o.Interpretation -or $o.Interpretation.Code -cne $e.Interp -or ($e.Interp -ceq '-' -and $o.Interpretation.Text -cne 'LAYOUT DIFFERS: no comparison')) { $extra = $false; $xd += "interp $(if ($o.Interpretation) { $o.Interpretation.Code })" } }
        if ($e.Phases['r2'] -ceq 'R2 SHOWN-QUAD') { $pn = @($o.Phases['r2'].Notes) -join ';'; if ($pn -notmatch 'pause ([0-9]+) ms' -or [long]$Matches[1] -lt 2000) { $extra = $false; $xd += "pause note '$pn'" } }
        if ($e.ContainsKey('Readings')) { $rp = (@($r.ReadingObjs | ForEach-Object { $_.Ph } | Sort-Object -Unique) -join ','); if ($rp -cne $e.Readings) { $extra = $false; $xd += "readings for '$rp'" } }
        if ($e.ContainsKey('MarkSeq')) { foreach ($k in $e.MarkSeq.Keys) { $msq = (@(@($r.Phases | Where-Object { $_.Ph -ceq $k })[0].Markers | ForEach-Object { ($_ -split '@')[0] }) -join ','); if ($msq -cne $e.MarkSeq[$k]) { $extra = $false; $xd += "$k markers $msq" } } }
        if ($e.ContainsKey('Markers')) { foreach ($k in 'p0', 'r1', 'r2', 'r3') { $pp = @($r.Phases | Where-Object { $_.Ph -ceq $k })[0]; $want = if ($k -ceq 'p0') { 'begin,rec' } else { 'begin,go,end,rec' }; if ((@($pp.Markers | ForEach-Object { ($_ -split '@')[0] }) -join ',') -cne $want -or @($pp.MarkerNotes).Count) { $extra = $false; $xd += "$k markers" } } }
        if ($e.ContainsKey('NoDone')) { if ($r.DoneSent) { $extra = $false; $xd += 'fs-done sent' } } elseif (-not $r.DoneSent) { $extra = $false; $xd += 'no fs-done' }
        if ($e.ContainsKey('SrcRefusal') -or $e.ContainsKey('SrcSkip')) {
            [byte[]]$sb0 = [IO.File]::ReadAllBytes($src); $st0 = [System.Text.Encoding]::GetEncoding(28591).GetString($sb0)
            if ($e.ContainsKey('SrcRefusal')) {
                $sr = $e.SrcRefusal; $fl = [regex]::Match($st0, '(?m)^FSXE1 [^\r\n]*END(?=\r?$)').Value; $ri = Get-Fs3cRefusalInfo $fl
                if ($null -eq $ri -or $ri.Ph -cne $sr[0] -or $ri.Ran -ne $sr[1] -or $ri.RanRaw -cne [string]$sr[1] -or $ri.Error -cne $sr[2]) { $extra = $false; $xd += "source refusal '$fl'" }
            }
            if ($e.ContainsKey('SrcRefusals')) {   # every FSXE1 of the source, in order: the session stays closed after the first refusal
                $all = @([regex]::Matches($st0, '(?m)^FSXE1 [^\r\n]*END(?=\r?$)') | ForEach-Object { Get-Fs3cRefusalInfo $_.Value })
                $want = @($e.SrcRefusals)
                $same0 = ($all.Count -eq $want.Count)
                for ($i = 0; $same0 -and $i -lt $all.Count; $i++) { $same0 = ($all[$i].Ph -ceq $want[$i][0] -and $all[$i].Ran -eq $want[$i][1] -and $all[$i].Error -ceq $want[$i][2]) }
                if (-not $same0) { $extra = $false; $xd += "source refusals $(@($all | ForEach-Object { "$($_.Ph)/$($_.Ran)/$($_.Error)" }) -join ',')" }
            }
            if ($e.ContainsKey('SrcSkip')) {
                # the r3 slice of the source capture (the harness host's r3, sent against the host rule): its record's pattern3 step is the device gate's skip
                $evs0 = Read-Fs3cIndexEvents -Path "$src.idx" -RawLength $sb0.Length; $all0 = Get-Fs3cSlices -Raw $sb0 -Events $evs0; $sl0 = @($all0 | Where-Object { $_.Ph -ceq 'r3' })
                $d0 = if ($sl0.Count -eq 1) { Test-Fsb1Record -Bytes $sl0[0].Bytes -Exp 's3c_r3' -Nonce ((Read-FsCaptureIndex -Path "$src.idx" -RawLength $sb0.Length).Nonce) -Challenge $sl0[0].Chal -Steps $script:S3cSteps['r3'] } else { $null }
                $sk0 = if ($null -ne $d0 -and $d0.Ok) { Get-Fs3cRun @($d0.Steps)[1] 3 $sl0[0].Chal.Substring(0, 8) } else { $null }
                if ($null -eq $sk0 -or $sk0.Kind -cne 'skip' -or $sk0.Why -cne 'run2-supervisor') { $extra = $false; $xd += "source r3 not the device skip run2-supervisor ($(if ($d0) { $d0.Reason }) $(if ($sk0) { $sk0.Kind + ' ' + $sk0.Why }))" }
            }
        }
        $ok = ($sent -ceq $e.Sent -and $divOk -and $r.Replay.RecaptureIsSourcePrefix -and $null -ne $o -and $c.Code -eq $e.Code -and $o.Outcome -ceq $e.Outcome -and $phOk -and $extra)
        Check ("Z2 {0}: collector sent {1}; {2}; classified ({3}) -> {4} (exit {5}); {6}" -f $sn, $e.Sent, $(if ($e.Div) { 'the replay diverges exactly where the harness host deviated' } else { 'no divergence, every recorded write performed, <prev> = recorded' }), $pinNote, $e.Outcome, $e.Code, (($e.Phases.Keys | Sort-Object | ForEach-Object { "$_ $($e.Phases[$_])" }) -join ', ')) $ok `
            "sent=$sent div=$($div -join ' ; ') prefix=$($r.Replay.RecaptureIsSourcePrefix) code=$($c.Code) outcome=$(if ($o) { $o.Outcome }) $($phDesc -join ' ') $($xd -join ' ')"
        $E2Res.Add(("{0,-19} exit {1,-3} {2,-20} {3}" -f $sn, $c.Code, $(if ($o) { $o.Outcome } else { '-' }), ((@('p0', 'r1', 'r2', 'r3') | ForEach-Object { if ($o) { "$_=$($o.Phases[$_].Class)" } }) -join ' | ')))
        $E2Repl[$sn] = $r
    }
    $chainOk = $true; $chainN = 0
    foreach ($sn in @('c-sim-all', 'c-sim-r2-dma', 'c-nodrm', 'c-markers')) { if ($E2Repl.ContainsKey($sn)) { foreach ($pp in @($E2Repl[$sn].Phases | Where-Object { $_.Sent })) { $chainN++; if (-not $pp.Fsb1Ok -or -not $pp.Sha16) { $chainOk = $false } } } }
    Check "Z2.1 the device records of c-sim-all, c-sim-r2-dma, c-nodrm and c-markers ($chainN phases) are FSB1 VALID per slice on the host, and the sha16 chain the collector derives is the one the device accepted" ($chainOk -and $chainN -ge 14)
    # build review MAJOR-1 end to end: the c-sim-all capture (its p0 hash is the harness replacement's) replayed with the
    # built-in pin: the collector stops after p0 (RUN 1 NOT POSSIBLE (integrity)), sends fs-done, never r1
    $src = Join-Path $E2Dir 'c-sim-all\capture.raw'
    if (Test-Path -LiteralPath $src) {
        $script:T3N++; $od = Join-Path $Scratch ("{0:D3}-e2e-integrity" -f $script:T3N)
        $r = Invoke-Fs3cReplay -RawPath $src -OutDirX $od -Overrides $E2Ov -Ui (New-Fs3cUi -Kind record) -Keys (New-Fs3cScriptedKeySource -Script @()) -Sound (New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd) -Sounds $script:T3Snd
        $p0i = @($r.Phases | Where-Object { $_.Ph -ceq 'p0' })[0]
        Check 'Z2.3 MAJOR-1 end to end: c-sim-all with the built-in pin: p0 VALID but its digest is the replacement''s -> RUN 1 NOT POSSIBLE (integrity), fs-done sent, r1 never sent (the replay diverges at the r1 write)' `
            ($p0i.Fsb1Ok -and $p0i.Integrity.Class -ceq 'INTEGRITY FAULT' -and $r.EndReason -match '^RUN 1 NOT POSSIBLE \(integrity\)' -and $r.DoneSent -and @($r.Sent | Where-Object { $_ -like 'fs-phase r1 *' }).Count -eq 0 -and
             @($r.Replay.Divergence).Count -ge 1 -and $r.Replay.Divergence[0] -match "collector wrote 'fs-done'; recorded write was 'fs-phase r1 ") "$($r.EndReason) $(@($r.Replay.Divergence) -join ';')"
    }
    foreach ($l in $E2Res) { Say "      e2e  $l" }
}
# the candidate image's MANIFEST against the repository sources, as fs-observe3c -Preflight checks it (no device action)
$E2Img = @(Get-ChildItem -LiteralPath (Join-Path $T3Root 'build\stage3c') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{16}\z' -and (Test-Path (Join-Path $_.FullName 'boot-stage3c.img')) } | Sort-Object Name | Select-Object -Last 1)
if ($E2Img.Count -eq 1) {
    $mfr = Test-FsObsManifest -ImagePath (Join-Path $E2Img[0].FullName 'boot-stage3c.img') -Q3 $T3Q3
    $mtx = [IO.File]::ReadAllText((Join-Path $E2Img[0].FullName 'MANIFEST.txt'))
    Check "Z2.2 the newest candidate $($E2Img[0].Name): Test-FsObsManifest OK against the repository's init.sh/fs-phase.sh/fs-probe.sh/fs-idle.sh; its /bin/fs-pattern is the classifier's built-in v0.6 pin" `
        ($mfr.Ok -and $E2Img[0].Name.EndsWith([string]$mfr.Nonce) -and $mtx -cmatch "(?m)^$($script:S3cPatternPin)  [0-9]+  /bin/fs-pattern ") "$($mfr.Why)"
} else { Skip 'Z2.2 candidate MANIFEST' 'no build\stage3c candidate present' }

# ------------------------------------------------------------------ BR -------
Say '== BR. the build-review fixes (2026-10-12)'
# MAJOR-1: the p0 integrity gate
$x = T3Run 'br1-p0-pin-mismatch' @(@{ Ph = 'p0'; Pin = ('0' * 64) }) $true @()
$p = T3Ph $x 'p0'
Check 'BR1 MAJOR-1: p0 VALID but its hash is not the pin -> RUN 1 NOT POSSIBLE (integrity) (red banner), no lit phase, fs-done' `
    ((T3Clean $x) -and $p.Fsb1Ok -and $p.Integrity.Class -ceq 'INTEGRITY FAULT' -and $x.R.EndReason -ceq 'RUN 1 NOT POSSIBLE (integrity): INTEGRITY FAULT' -and -not (T3Sent $x 'r1') -and $x.R.DoneSent -and
     @($x.Ui.Transcript | Where-Object { $_ -ceq '[BANNER abort] RUN 1 NOT POSSIBLE (integrity) | nothing is lit; fs-done follows' }).Count -eq 1 -and
     @($x.Ui.Transcript | Where-Object { $_ -match 'LOOK INTO THE LENSES' }).Count -eq 0) (T3Desc $x)
$x = T3Run 'br1b-p0-hash-unparseable' @(@{ Ph = 'p0'; Pin = 'zz' }) $true @()
Check 'BR1b MAJOR-1: a hash step that is not the exact sha256sum form (UNPARSEABLE) -> not MEASURED -> RUN 1 NOT POSSIBLE (integrity), fs-done' `
    ((T3Clean $x) -and (T3Ph $x 'p0').Integrity.Class -ceq 'UNPARSEABLE' -and -not (T3Sent $x 'r1') -and $x.R.DoneSent) (T3Desc $x)
$x = T3Run 'br1c-p0-pin-ok' $SP2 $true ($KR1 + $KX)
Check 'BR1c MAJOR-1: the pinned digest MEASURED -> the LOOK cue and run 1 follow' ((T3Clean $x) -and (T3Ph $x 'p0').Integrity.Class -ceq 'MEASURED' -and (T3Sent $x 'r1')) (T3Desc $x)
$st0 = (Get-G3Steps -Ph 'p0' -Chal ('a' * 32) -O @{})
Check 'BR1d Get-Fs3cP0Integrity: no pin -> NO PIN (not Ok); the fixture pin -> MEASURED' (-not (Get-Fs3cP0Integrity -StepList $st0 -Pin '').Ok -and (Get-Fs3cP0Integrity -StepList $st0 -Pin $script:G3Pin).Class -ceq 'MEASURED')
# MAJOR-2: Ctrl+C = x; console mode; every answer on disk at once
$cc = New-Object System.ConsoleKeyInfo ([char]3), ([ConsoleKey]::C), $false, $false, $true
Check 'BR2 MAJOR-2: Ctrl+C (read as input) is the key x; an ordinary c is c' ((ConvertTo-Fs3cKeyName $cc) -ceq 'x' -and (ConvertTo-Fs3cKeyName (New-Object System.ConsoleKeyInfo 'c', ([ConsoleKey]::C), $false, $false, $false)) -ceq 'c')
$script:brFired = $false
$brReader = { param($now) if (-not $script:brFired -and $null -ne $script:FsLastCtx -and @($script:FsLastCtx.Sent | Where-Object { $_ -like 'fs-phase r1 *' }).Count) { $script:brFired = $true; return (New-Object System.ConsoleKeyInfo ([char]3), ([ConsoleKey]::C), $false, $false, $true) }; $null }
$script:T3N++; $bdir = Join-Path $Scratch ("{0:D3}-br2-ctrlc" -f $script:T3N)
$gB = New-G3Session -Name 'br2-ctrlc' -Spec $SP1 -Done $true -Path (Join-Path $bdir 'src\capture.raw')
$uiB = New-Fs3cUi -Kind record
$rB = Invoke-Fs3cReplay -RawPath (Join-Path $bdir 'src\capture.raw') -OutDirX (Join-Path $bdir 'out') -Overrides @{ PatternPin = $script:G3Pin } -Ui $uiB -Keys (New-Fs3cConsoleKeySource -Reader $brReader) -Sound (New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd) -Sounds $script:T3Snd
$pB = @($rB.Phases | Where-Object { $_.Ph -ceq 'r1' })[0]
$itB = (@($rB.ReadingObjs | Where-Object { $_.Ph -ceq 'r1' } | ForEach-Object { "$($_.Item)=$($_.Obs)" }) -join ',')
Check 'BR3 MAJOR-2: Ctrl+C during run 1 (console key source) acts as x: ABORT NOTED at once, after the record the one dark-check question (here a timeout), then the safe finish with fs-done; the Ctrl+C is logged' `
    (@($rB.Replay.Divergence).Count -eq 0 -and $pB.AbortNoted -and $itB -ceq 'left=ABORT,right=ABORT,dark=TIMEOUT' -and $rB.DoneSent -and @($rB.Events | Where-Object { $_ -match 'ctrl-c read as x' }).Count -eq 1 -and
     @($uiB.Transcript | Where-Object { $_ -match 'ABORT NOTED - the device finishes this hold' }).Count -eq 1) "items=$itB done=$($rB.DoneSent) end=$($rB.EndReason) div=$(@($rB.Replay.Divergence) -join ';')"
$cm = Enter-Fs3cConsoleMode; $cmOk = $true; try { Exit-Fs3cConsoleMode $cm } catch { $cmOk = $false }
Check 'BR4 MAJOR-2 / MINOR-9: Enter-Fs3cConsoleMode (Ctrl+C as input, QuickEdit off via SetConsoleMode) and Exit-Fs3cConsoleMode run without a failure, with or without a console, and say what they did' `
    ($cmOk -and @($cm.Notes).Count -eq 2 -and ($cm.Notes -join ' ') -match 'QuickEdit' -and ('Fs3cConsole' -as [type]) -ne $null) ($cm.Notes -join ' | ')
$bd2 = Join-Path $Scratch 'br5-incremental'; $null = New-Item -ItemType Directory -Force -Path $bd2
$xB = New-Fs3cInteract -Ui (New-Fs3cUi -Kind record) -Keys (New-Fs3cScriptedKeySource -Script @()) -Sound (New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd) -OutDirX $bd2
$null = Add-Fs3cReading -X $xB -Ph 'r1' -Item 'left' -Key 'b' -Obs 'DARK' -PromptMs 10 -AnswerMs 20
$rl1 = @([IO.File]::ReadAllLines((Join-Path $bd2 'readings3c.txt')))
$null = Add-Fs3cReading -X $xB -Ph 'r1' -Item 'right' -Key 'c' -Obs 'GARBLED' -PromptMs 30 -AnswerMs 40
$rl2 = @([IO.File]::ReadAllLines((Join-Path $bd2 'readings3c.txt'))); $cpj = Get-Content -Raw (Join-Path $bd2 'session.json') | ConvertFrom-Json
Check 'BR5 MAJOR-2: every answer is on disk at once: readings3c.txt grows by one FSR2 line per reading; session.json holds a checkpoint (schema partial) with the readings so far' `
    ($rl1.Count -eq 1 -and $rl2.Count -eq 2 -and $rl2[1] -match '^FSR2 p=r1 item=right key=c obs=GARBLED ' -and $cpj.Schema -ceq 'frameshift.fs-collect3c.partial.v1' -and @($cpj.Readings).Count -eq 2)
$td2 = Join-Path $Scratch 'br6-partial'; Copy-Item -Recurse -LiteralPath $CAN['garbled-r3'].Out -Destination $td2
Copy-Item -LiteralPath (Join-Path $bd2 'session.json') -Destination (Join-Path $td2 'session.json') -Force
$q = Invoke-Fs3cClassifyDir -DirX $td2 -S1X 'PASS' -PinX $script:G3Pin
Check 'BR6 MAJOR-2: the classifier on a directory whose session.json is still the checkpoint (the collector did not finish): INCONCLUSIVE, code 14, no classification' ($q.Code -eq 14 -and ($q.Lines -join ' ') -match 'checkpoint of a collector run that did not finish') ($q.Lines -join ' / ')
# MINOR-2: key repeat
$x = T3Run 'br7-repeat' $SP2 $true (@('p:1500:b', 'p:100:b', 'p:900:c', 'p:800:y') + $KX)
Check 'BR7 MINOR-2: the previous answer''s key within 600 ms of the next prompt is ignored (logged); the next key answers it (right GARBLED, not DARK)' `
    ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'left=DARK,right=GARBLED,dark=DARK_NOW' -and @($x.R.Events | Where-Object { $_ -match 'key-repeat-ignored r1/right key=b' }).Count -eq 1) (T3Desc $x)
$x = T3Run 'br8-repeat-d' $SP2 $true (@('p:1000:d', 'p:100:d') + (T3Chars 'r1' 300) + @('p:900:b', 'p:800:y') + $KX)
Check 'BR8 MINOR-2: a repeated d right after the d answer is not taken as the character D; the 8 characters read correctly' `
    ((T3Clean $x) -and (T3It $x 'r1' 'left').Chars -ceq $x.G.Tokens.C['r1'].Substring(0, 8).ToUpperInvariant() -and @($x.R.Events | Where-Object { $_ -match 'key-repeat-ignored r1/chars_left key=d' }).Count -eq 1) (T3Desc $x)
# MINOR-3: READ without characters
$x = T3Run 'br9-read-nochars' $SP1 $true @('p:1000:d', 'p:300:1', 'p:300:x')
$o = SOut $SG @((FsrL 'r2' 'left' 'READ' '' '' 'd'), (FsrL 'r2' 'chars_left' 'TIMEOUT'), (FsrL 'r2' 'right' 'NOT_ASKED'), (FsrL 'r2' 'dark' 'NOT_ASKED'))
Check 'BR9 MINOR-3: d, then x/timeout in the character entry: echoed "READ, characters not recorded"; the classifier reports READ, CHARACTERS NOT RECORDED (not LIT BUT GARBLED)' `
    ((T3Clean $x) -and @($x.Ui.Transcript | Where-Object { $_ -ceq 'LEFT EYE: READ, characters not recorded' }).Count -eq 1 -and (T3Obs $x 'r1' 'left') -ceq 'READ' -and
     $o.Optical['r2'].Class -ceq 'READ, CHARACTERS NOT RECORDED') "$(T3Desc $x) | $($o.Optical['r2'].Class)"
# MINOR-4: n during a run = x
$x = T3Run 'br10-n-during-r1' $SP1 $true @('i:3000:n', 'p:1500:y')
Check 'BR10 MINOR-4: n during the lit phase is taken as x: ABORT NOTED (n taken as x), the one dark-check question after the record, fs-done' `
    ((T3Clean $x) -and (T3Ph $x 'r1').AbortNoted -and (T3Items $x 'r1') -ceq 'left=ABORT,right=ABORT,dark=DARK_NOW' -and $x.R.DoneSent -and
     @($x.Ui.Transcript | Where-Object { $_ -match 'ABORT NOTED .*n \(light\) taken as x' }).Count -eq 1) (T3Desc $x)
# NIT d: the dark-check banners
Check 'BR11 NIT d: after x the first banner is "RUN 1 ENDED - ONE SAFETY QUESTION"; in a normal gap the dark check has its own banner' `
    (@($x.Ui.Transcript | Where-Object { $_ -match '^\[BANNER answer\] RUN 1 ENDED - ONE SAFETY QUESTION' }).Count -eq 1 -and
     @($CAN['nominal-read'].Ui.Transcript | Where-Object { $_ -match '^\[BANNER info\] DARK CHECK - ARE BOTH PANELS DARK NOW\?' }).Count -eq 2)
# NIT a: the red SAFE FINISH banner
$x = T3Run 'br12-safe-banner' $SP1 $true @('p:1000:b', 'p:1000:x')
Check 'BR12 NIT a: a safe finish shows a red SAFE FINISH banner' ((T3Clean $x) -and @($x.Ui.Transcript | Where-Object { $_ -match '^\[BANNER abort\] SAFE FINISH - no further run \| x at the right reading' }).Count -eq 1) (T3Desc $x)
# NIT c: no LAYOUT DIFFERS for a run 3 that was not shown
$o = SOut @((S3In 'p0'), (S3In 'r1'), (S3In 'r2'), (S3In 'r3' @{ Skip = 'run2-supervisor' })) @((FsrL 'r2' 'left' 'GARBLED'), (FsrL 'r2' 'right' 'GARBLED'))
Check 'BR13 NIT c: a run 3 that was not machine-shown has no interpretation (never "LAYOUT DIFFERS")' ($null -ne $o.Interpretation -and $o.Interpretation.Text -match '^run 3 not machine-shown' -and $o.Interpretation.Text -notmatch 'LAYOUT DIFFERS') "$($o.Interpretation.Text)"
# MINOR-7: the summary to a file, shown only on s
$sumP = Save-Fs3cSummary $CAN['garbled-r3'].R $Scratch $false
$showS = @(Show-Fs3cSummaryOnKey $CAN['garbled-r3'].R $sumP (New-Fs3cConsoleKeySource -Reader { param($n) New-Object System.ConsoleKeyInfo 's', ([ConsoleKey]::S), $false, $false, $false }) $false)
$showX = @(Show-Fs3cSummaryOnKey $CAN['garbled-r3'].R $sumP (New-Fs3cConsoleKeySource -Reader { param($n) New-Object System.ConsoleKeyInfo 'x', ([ConsoleKey]::X), $false, $false, $false }) $false)
Check 'BR14 MINOR-7: the machine summary is written to summary.txt; on the console it appears only after the s key (x leaves it in the file); nothing machine-side is printed before the key' `
    (([IO.File]::ReadAllText($sumP)) -match '^STATUS: COLLECTED-VALID' -and $showS[0] -match '^SESSION OVER' -and $showS[1] -match 'Press s' -and $showS[2] -ceq 'STATUS: COLLECTED-VALID' -and
     @($showX | Where-Object { $_ -match '^STATUS:' }).Count -eq 0 -and $showX[-1] -match 'not shown') ($showS[0..2] -join ' / ')
# MINOR-10: the recovery line of the error path
Check 'BR15 MINOR-10: the CLI error path says "fs-done NOT sent" only when fs-done was not sent' `
    ((Get-Fs3cErrorRecovery ([pscustomobject]@{ Sent = @('fs-verify x', 'fs-done') })) -match 'fs-done was sent' -and (Get-Fs3cErrorRecovery ([pscustomobject]@{ Sent = @('fs-verify x') })) -match 'fs-done NOT sent')
# NIT f: a key-source failure is logged and shown
$xF = New-Fs3cInteract -Ui (New-Fs3cUi -Kind record) -Keys (New-Fs3cConsoleKeySource -Reader { param($n) throw 'The handle is invalid.' }) -Sound (New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd)
$wF = Wait-Fs3cKey -X $xF -Allowed @('y') -DeadlineMs ($xF.Now() + 120) -Label 'br/f'
Check 'BR16 NIT f: a failing key source is logged (key-source-failure) and shown once; the prompt then times out (the safe direction)' `
    ($wF.TimedOut -and @($xF.Events | Where-Object { $_ -match 'key-source-failure The handle is invalid' }).Count -eq 1 -and @($xF.Ui.Transcript | Where-Object { $_ -match '^KEYBOARD NOT READABLE' }).Count -eq 1)
# NIT g, MINOR-6: the sound-check wording and the key-reach list
$sc = T3SoundCheck $sk1
Check 'BR17 NIT g / MINOR-6: "Heard it? y = yes, n = no" (no "any other key"); the key reach covers Enter, Backspace and every hex character of the entry' `
    (@($sc.Named).Count -eq 5 -and ($script:Fs3cReachKeys -join ' ') -match 'Enter' -and @('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f','?','Enter','Backspace','Esc' | Where-Object { $script:Fs3cReachKeys -cnotcontains $_ }).Count -eq 0 -and
     ([IO.File]::ReadAllText((Join-Path $T3Dir 'fs-session3c.ps1'))) -notmatch 'any other key = no')
# MINOR-5 / MINOR-8 (docs): the host-pin check first, the literal Get-FileHash line, the sound check as the only audio protection
$sgn = [IO.File]::ReadAllText((Join-Path $T3Q3 'SIGNOFF-3c.md')); $wtk = [IO.File]::ReadAllText((Join-Path $T3Q3 'stage3c\WALKTHROUGH.md'))
Check 'BR18 MINOR-8 / MINOR-5: SIGNOFF-3c A and the WALKTHROUGH check the host pins FIRST (before the sound check and the rehearsal) with the literal Get-FileHash command (upper-case hex noted); SIGNOFF A says the sound check is the only protection against a silent audio failure; console-closed row present' `
    ($sgn.IndexOf('Host pins match') -gt 0 -and $sgn.IndexOf('Host pins match') -lt $sgn.IndexOf('Sound check passed') -and $sgn -match 'Get-FileHash -Algorithm SHA256 -LiteralPath' -and $sgn -match 'upper-case' -and
     $sgn -match 'only protection' -and $wtk.IndexOf('Host pins') -gt 0 -and $wtk.IndexOf('Host pins') -lt $wtk.IndexOf('Sound check') -and $wtk -match 'Get-FileHash -Algorithm SHA256 -LiteralPath' -and
     $wtk -match 'console window closed' -and $sgn -match 'console window closed')

# ------------------------------------------------------------------ UB -------
if (-not ((Test-Path -LiteralPath (Join-Path $T3Dir 'fs-capture.ps1')) -and (Test-Path -LiteralPath (Join-Path $T3Dir 'before-after\commands-userbuild.tsv')) -and (Test-Path -LiteralPath (Join-Path $T3Dir 'before-after\USERBUILD.md')))) {
    Skip 'UB1-UB6' 'withheld: the before/after capture tooling is not in the public copy'
} else {
# Stage 3d, review MAJOR-3 (2026-10-13): BOTH Quest 3 units run the v2.7 user build. One rows file,
# before-after/commands-userbuild.tsv, names the unit as {serial}; fs-capture.ps1 revision 9 substitutes -Serial before
# its read-only allowlist and refuses the file without an explicit -Serial; the root-only rows are #NOT-CAPTURED lines
# (SUMMARY.txt "not captured"); anything naming persist is refused (J-132); `shell id` only records adbd's state.
Say '== UB. stage-3d user-build capture rows (commands-userbuild.tsv, both units) and fs-capture.ps1 revision 9'
$ubU1 = 'QUEST3UNIT1'; $ubU2 = 'QUEST3UNIT2'; $ubFile = Join-Path $T3Dir 'before-after\commands-userbuild.tsv'; $ubCap = Join-Path $T3Dir 'fs-capture.ps1'
$ubAll = @([IO.File]::ReadAllLines($ubFile))
$ubRows = @($ubAll | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { , $_.Split("`t") })
$ubNc = @($ubAll | Where-Object { $_ -cmatch '^#NOT-CAPTURED\t' } | ForEach-Object { $_.Split("`t")[1] })
$ubLegacy = @([IO.File]::ReadAllLines((Join-Path $T3Dir 'before-after\commands.tsv')) | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Split("`t")[2] })
$ubRefused = @(
    "adb -s {serial} shell cat /proc/version", "adb -s {serial} shell cat /proc/cmdline", "adb -s {serial} shell ls -l /dev/block/by-name/",
    "adb -s {serial} shell sha256sum /dev/block/by-name/boot_a", "adb -s {serial} shell blockdev --getsize64 /dev/block/by-name/misc",
    # J-132: anything naming persist, in any form, even forms the allowlist would otherwise take
    "adb -s {serial} shell su 0 sha256sum /dev/block/by-name/persist", "adb -s {serial} shell su 0 sha256sum /dev/block/by-name/boot_a /dev/block/by-name/persist",
    "adb -s {serial} shell getprop persist.sys.timezone", "adb -s {serial} shell getprop ro.boot.PERSIST", "fastboot -s {serial} getvar partition-size:persist",
    "adb -s {serial} shell ls /persist", "adb -s {serial} shell su 0 ls -lR /persist/calibration", "adb -s {serial} pull /persist/calibration",
    # our tools never run adb root / su on a user build, nor remount or verity changes
    "adb -s {serial} root", "adb -s {serial} unroot", "adb -s {serial} remount", "adb -s {serial} disable-verity", "adb -s {serial} shell su 0 id", "adb -s {serial} shell su",
    "adb -s {serial} shell id; reboot")
$ubT = & { . $ubCap
           $a = @{}; foreach ($u in $ubU1, $ubU2) { $a[$u] = @(foreach ($r in $ubRows) { Test-FsReadOnlyRow $r[2].Replace('{serial}', $u) $u }) }
           $x = @(foreach ($r in $ubRows) { if ($r[2] -match ' -s ') { Test-FsReadOnlyRow $r[2].Replace('{serial}', $ubU2) $ubU1 } })
           $rf = @(foreach ($c in $ubRefused) { foreach ($u in $ubU1, $ubU2) { Test-FsReadOnlyRow $c.Replace('{serial}', $u) $u } })
           $lg = @(foreach ($c in $ubLegacy) { Test-FsReadOnlyRow $c $ubU1 })
           $id = @(foreach ($u in $ubU1, $ubU2) { Test-FsReadOnlyRow "adb -s $u shell id" $u })
           [pscustomobject]@{ Acc = $a; Cross = $x; Ref = $rf; Legacy = $lg; Id = $id } }
$ubIds = @($ubRows | ForEach-Object { $_[0] })
$ubBad = @(for ($i = 0; $i -lt $ubRows.Count; $i++) { $r = $ubRows[$i]
    if ($r.Count -ne 5 -or $r[0] -cnotmatch "^$($r[1])\d\d\z" -or -not $ubT.Acc[$ubU1][$i] -or -not $ubT.Acc[$ubU2][$i] -or $r[2] -match '\bsu\b|fs-binpull|persist| root\b|unroot' -or
        ($r[2] -match ' -s ' -and $r[2] -cnotmatch ' -s \{serial\} ') -or $r[2] -match 'QUEST3UNIT') { $r[0] } })
$ubPh = @{}; foreach ($r in $ubRows) { $ubPh[$r[1]] = 1 + $(if ($ubPh.ContainsKey($r[1])) { $ubPh[$r[1]] } else { 0 }) }
Check "UB1 commands-userbuild.tsv: $($ubRows.Count) rows of 5 columns, ids of their phase, unique; the unit only as {serial} (no serial written in), no su / fs-binpull / persist / root row; every row accepted by fs-capture.ps1's allowlist for Unit 1 AND Unit 2 after the substitution, every -s row refused for one unit when it names the other; BA/BF/AF/AA rows $($ubPh['BA'])/$($ubPh['BF'])/$($ubPh['AF'])/$($ubPh['AA']); BA24/AA24 shell id; the root-only ids BA11-15/AA11-15 are #NOT-CAPTURED lines, never rows" `
    ($ubRows.Count -eq 58 -and $ubBad.Count -eq 0 -and @($ubT.Cross | Where-Object { $_ }).Count -eq 0 -and @($ubIds | Where-Object { $_ -cmatch '^(BA|AA)1[1-5]\z' }).Count -eq 0 -and @($ubIds | Select-Object -Unique).Count -eq $ubIds.Count -and
     $ubPh['BA'] -eq 19 -and $ubPh['BF'] -eq 10 -and $ubPh['AF'] -eq 10 -and $ubPh['AA'] -eq 19 -and ($ubNc -join ',') -ceq 'BA11,BA12,BA13,BA14,BA15,AA11,AA12,AA13,AA14,AA15' -and
     @($ubRows | Where-Object { $_[0] -cmatch '^(BA|AA)24\z' -and $_[2] -ceq 'adb -s {serial} shell id' }).Count -eq 2) "bad: $($ubBad -join ',') cross-accepted: $(@($ubT.Cross | Where-Object { $_ }).Count)"
$ubUb = [IO.File]::ReadAllText((Join-Path $T3Dir 'before-after\USERBUILD.md'))
Check "UB2 fs-capture.ps1 revision 9 refuses every listed read for both units ($($ubRefused.Count) forms: cat/ls/sha256sum or blockdev without su; anything naming persist (a partition, a path, a property, a getvar, a pull; J-132), even inside an allowlisted su sha256sum; adb root/unroot/remount/disable-verity; su id; a ';' chain) and still accepts shell id and every legacy commands.tsv row (Unit 1, revision 8 behaviour); USERBUILD.md lists the refused reads and says the root-only rows are not captured and our tools never run adb root or su" `
    (@($ubT.Ref | Where-Object { $_ }).Count -eq 0 -and @($ubT.Legacy | Where-Object { -not $_ }).Count -eq 0 -and $ubLegacy.Count -eq 50 -and @($ubT.Id | Where-Object { -not $_ }).Count -eq 0 -and
     $ubUb -match 'not captured' -and $ubUb -match 'our tools never run `adb root` or `su`' -and $ubUb -match '/persist' -and $ubUb.Contains('shell cat /proc/version') -and $ubUb.Contains('shell ls -l /dev/block/by-name/')) "refused-but-accepted: $(@($ubT.Ref | Where-Object { $_ }).Count); legacy refused: $(@($ubT.Legacy | Where-Object { -not $_ }).Count)"
$ubBad = @()
foreach ($ph in 'BA', 'BF', 'AF', 'AA') {
    foreach ($u in $ubU1, $ubU2) {
        $ubRoot = Join-Path $Scratch "ub-$ph-$u"
        $o = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ubCap -Phase $ph -Nonce 'c0de3d0000000001' -Serial $u -CommandsFile $ubFile -CapturesRoot $ubRoot -Adb (Join-Path $Scratch 'no\adb.exe') -Fastboot (Join-Path $Scratch 'no\fastboot.exe') | ForEach-Object { [string]$_ }); $c = $LASTEXITCODE
        $tool = if (@('BA', 'AA') -ccontains $ph) { 'adb' } else { 'fastboot' }
        if (-not ($c -eq 20 -and $o[-1] -cmatch "^REFUSED: $tool not found at " -and -not (Test-Path -LiteralPath $ubRoot))) { $ubBad += "$ph $u exit $c '$($o[-1])'" }
    }
    $ubRoot = Join-Path $Scratch "ub-$ph-default"
    $o = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ubCap -Phase $ph -Nonce 'c0de3d0000000001' -CommandsFile $ubFile -CapturesRoot $ubRoot -Adb (Join-Path $Scratch 'no\adb.exe') -Fastboot (Join-Path $Scratch 'no\fastboot.exe') | ForEach-Object { [string]$_ }); $c = $LASTEXITCODE
    # revision 10 (second review MINOR-4): -Serial is required for every file, refused before the file is read
    if (-not ($c -eq 20 -and $o[-1] -cmatch '^REFUSED: -Serial is required: name the unit \(Unit 1 QUEST3UNIT1, Unit 2 QUEST3UNIT2; no default unit\); nothing was run' -and -not (Test-Path -LiteralPath $ubRoot))) { $ubBad += "$ph default serial: exit $c '$($o[-1])'" }
}
Check 'UB3 review MAJOR-2/3: fs-capture.ps1 (child process, no device, adb/fastboot paths absent) with -CommandsFile commands-userbuild.tsv and -Serial of Unit 1 or of Unit 2: each phase passes the allowlist for every row and stops only at "REFUSED: adb/fastboot not found" (exit 20, nothing written); WITHOUT -Serial each phase is REFUSED (revision 10: -Serial is required, no default unit), nothing written' ($ubBad.Count -eq 0) ($ubBad -join ' | ')

# UB4: end to end with a compiled FAKE adb/fastboot (the unit is FAKE_SERIAL; dumpsys battery is FAKE_BATTERY): BA on
# Unit 2 -> PHASE BA OK, SUMMARY with the serial, BA11-BA15 "not captured", BA24 id recorded; the observer's BA10 check
# reads that capture; nothing but the allowlisted reads reached the fake tools (no root, su or persist).
$ubFd = Join-Path $Scratch 'ub-fake'; $null = New-Item -ItemType Directory -Force -Path $ubFd
$ubAdb = Join-Path $ubFd 'adb.exe'; $ubFb = Join-Path $ubFd 'fastboot.exe'
if (-not (Test-Path -LiteralPath $ubAdb)) {
    Add-Type -OutputType ConsoleApplication -OutputAssembly $ubAdb -TypeDefinition @'
using System; using System.IO;
public static class FakeUb {
    static string Env(string k) { return Environment.GetEnvironmentVariable(k) ?? ""; }
    static int Out(string s) { Console.Out.Write(s); return 0; }
    public static int Main(string[] a) {
        string tool = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]).ToLowerInvariant();
        File.AppendAllText(Env("FAKE_LOG"), tool + " " + string.Join("|", a) + "\n");
        string ser = Env("FAKE_SERIAL");
        if (tool == "fastboot") {
            if (a.Length == 1 && a[0] == "devices") return Out(ser + "\tfastboot\n");
            if (a.Length == 4 && a[0] == "-s" && a[1] == ser && a[2] == "getvar") { Console.Error.Write(a[3] + ": fake\nFinished. Total time: 0.001s\n"); return 0; }
            Console.Error.Write("fake fastboot: unsupported\n"); return 1;
        }
        if (a.Length == 2 && a[0] == "devices" && a[1] == "-l") return Out("List of devices attached\n" + ser + "         device product:eureka model:Quest_3 device:eureka\n\n");
        if (a.Length < 4 || a[0] != "-s" || a[1] != ser || a[2] != "shell") { Console.Error.Write("fake adb: unsupported\n"); return 1; }
        string rest = string.Join(" ", a, 3, a.Length - 3);
        if (rest == "getprop sys.boot_completed") return Out("1\n");
        if (rest == "getprop ro.serialno") return Out(ser + "\n");
        if (rest == "getprop ro.build.type") return Out("user\n");
        if (rest.StartsWith("getprop ")) return Out("fake-" + rest.Substring(8) + "\n");
        if (rest == "uname -r") return Out("5.10.246-gd7102a837402\n");
        if (rest == "dumpsys battery") return Out(Env("FAKE_BATTERY").Replace("|", "\n") + "\n");
        if (rest == "id") return Out("uid=2000(shell) gid=2000(shell) groups=2000(shell) context=u:r:shell:s0\n");
        Console.Error.Write("fake adb: unsupported\n"); return 1;
    }
}
'@
    Copy-Item -LiteralPath $ubAdb -Destination $ubFb
}
function UbCap([string]$ph, [string]$ser, [string]$bat, [string]$root, [string]$cmdFile = $ubFile, [string]$serArg = '') {
    $log = Join-Path $ubFd ("log-" + (New-FsHex 3) + '.txt'); [IO.File]::WriteAllText($log, '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = 'powershell.exe'; $q0 = [string][char]34
    $sa = if ($serArg) { "-Serial $serArg" } else { '' }
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $q0$ubCap$q0 -Phase $ph -Nonce c0de3d00000000ab $sa -CommandsFile $q0$cmdFile$q0 -CapturesRoot $q0$root$q0 -Adb $q0$ubAdb$q0 -Fastboot $q0$ubFb$q0 -BootPollMs 100"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.EnvironmentVariables['FAKE_SERIAL'] = $ser; $psi.EnvironmentVariables['FAKE_BATTERY'] = $bat; $psi.EnvironmentVariables['FAKE_LOG'] = $log
    $pp = [System.Diagnostics.Process]::Start($psi); $pp.StandardInput.Close(); $te = $pp.StandardError.ReadToEndAsync(); $oo = $pp.StandardOutput.ReadToEnd(); $pp.WaitForExit()
    [pscustomobject]@{ Code = $pp.ExitCode; Out = @($oo -split "`r?`n" | Where-Object { $_ }); Log = @([IO.File]::ReadAllLines($log)); Dir = (Join-Path (Join-Path $root 'c0de3d00000000ab') $ph) }
}
$batOk = 'Current Battery Service state:|  AC powered: true|  status: 5|  level: 99|  temperature: 250|  technology: Li-ion'
$u4 = UbCap 'BA' $ubU2 $batOk (Join-Path $ubFd 'cap-ok') $ubFile $ubU2
$u4s = if (Test-Path -LiteralPath (Join-Path $u4.Dir 'SUMMARY.txt')) { @([IO.File]::ReadAllLines((Join-Path $u4.Dir 'SUMMARY.txt'))) } else { @() }
$u4b = Test-FsObsBa10 (Join-Path $u4.Dir 'SUMMARY.txt')
$u4r = Read-FsObsPhaseSummary (Join-Path $u4.Dir 'SUMMARY.txt') 'BA' 'c0de3d00000000ab' $ubU2
$u4x = Read-FsObsPhaseSummary (Join-Path $u4.Dir 'SUMMARY.txt') 'BA' 'c0de3d00000000ab' $ubU1
$u4bad = @($u4.Log | Where-Object { $_ -match '(?i)persist|\|root(\||$)|\|su(\||$)|exec-out|reboot' })
Check 'UB4 review MAJOR-1/3 end to end (fake adb, Unit 2): fs-capture.ps1 -Phase BA with commands-userbuild.tsv -Serial QUEST3UNIT2 -> PHASE BA OK (19 rows); SUMMARY.txt names serial QUEST3UNIT2, lists BA11-BA15 as "not captured", BA24 holds the shell id output; the fake saw only allowlisted reads (no root, su, exec-out, reboot or persist); the observer''s BA10 check reads 250 / status 5 / level 99 from this capture; the summary is accepted for Unit 2 and refused for Unit 1' `
    ($u4.Code -eq 0 -and $u4.Out[-1] -cmatch '^PHASE BA OK: 19 rows captured in ' -and $u4s[0] -cmatch '^# fs-capture\.ps1 phase BA nonce c0de3d00000000ab serial QUEST3UNIT2  ' -and
     (@($u4s | Where-Object { $_ -cmatch "^BA1[1-5]`tnot-captured`t-`t-`tnot captured: " } | ForEach-Object { $_.Substring(0, 4) }) -join ',') -ceq 'BA11,BA12,BA13,BA14,BA15' -and
     ([IO.File]::ReadAllText((Join-Path $u4.Dir 'BA24.txt'))) -match '^uid=2000\(shell\)' -and $u4.Log.Count -eq 19 -and $u4bad.Count -eq 0 -and
     $u4b.Ok -and $u4b.Temp -eq 250 -and $u4b.Status -eq 5 -and $u4b.Level -eq 99 -and $u4r.Ok -and -not $u4x.Ok -and $u4x.Why -match 'serial QUEST3UNIT2 is not QUEST3UNIT1') "exit $($u4.Code) last '$($u4.Out[-1])' log $($u4.Log.Count) bad $($u4bad -join ';') ba10 $($u4b.Why) $($u4x.Why)"
$u5 = UbCap 'BA' $ubU1 'Current Battery Service state:|  AC powered: true|  status: 2|  level: 100|  temperature: 410' (Join-Path $ubFd 'cap-chg') $ubFile $ubU1
$u5b = Test-FsObsBa10 (Join-Path $u5.Dir 'SUMMARY.txt')
Check 'UB5 review MAJOR-1 negative control (fake adb, Unit 1 on AC at 410, status 2, as its 2026-10-13 baseline read): the capture itself is OK (data), but the observer''s BA10 check refuses it, naming the temperature' `
    ($u5.Code -eq 0 -and -not $u5b.Ok -and $u5b.Why -match 'temperature 410 at BA is not below 350') "$($u5.Code) $($u5b.Why)"
$ubInj = Join-Path $ubFd 'injected-persist.tsv'
[IO.File]::WriteAllLines($ubInj, [string[]](@($ubAll | Where-Object { $_ -cmatch '^BA0[1-3]\t' }) + @("BA25`tBA`tadb -s {serial} shell getprop persist.sys.locale`tba25.txt`tinjected")))
$u6 = UbCap 'BA' $ubU2 $batOk (Join-Path $ubFd 'cap-inj') $ubInj $ubU2
$ubIdc = Join-Path $ubFd 'injected-root.tsv'
[IO.File]::WriteAllLines($ubIdc, [string[]](@($ubAll | Where-Object { $_ -cmatch '^BA0[1-3]\t' }) + @("BA26`tBA`tadb -s {serial} root`tba26.txt`tinjected")))
$u7 = UbCap 'BA' $ubU2 $batOk (Join-Path $ubFd 'cap-root') $ubIdc $ubU2
Check 'UB6 J-132 / our tools never run adb root: a rows file with one injected row naming persist (getprop persist.*), or one injected `adb root`, is REFUSED as a whole (exit 20) before anything runs: the fake adb is never started, no capture directory' `
    ($u6.Code -eq 20 -and $u6.Out[-1] -cmatch '^REFUSED: row BA25 is not in the read-only allowlist' -and $u6.Log.Count -eq 0 -and -not (Test-Path -LiteralPath $u6.Dir) -and
     $u7.Code -eq 20 -and $u7.Out[-1] -cmatch '^REFUSED: row BA26 is not in the read-only allowlist' -and $u7.Log.Count -eq 0 -and -not (Test-Path -LiteralPath $u7.Dir)) "$($u6.Code) '$($u6.Out[-1])' log $($u6.Log.Count); $($u7.Code) '$($u7.Out[-1])' log $($u7.Log.Count)"

}
# ------------------------------------------------------------------ Y --------
Say '== Y. stage-3b behaviour unchanged'
$pinnedFiles = @('devices/quest3/host/fs-collect.ps1', 'devices/quest3/host/fs-observe.ps1', 'devices/quest3/host/fs-classify.ps1', 'devices/quest3/host/fs-classify3b.ps1', 'devices/quest3/host/fs-native.ps1',
                 'devices/quest3/host/fs-miscrule.ps1', 'devices/quest3/host/COLLECTOR.md', 'devices/quest3/host/test-host3b.ps1', 'devices/quest3/host/test-host2.ps1',
                 'devices/quest3/host/test-host2.output.txt', 'devices/quest3/host/test-host3b.output.txt', 'devices/quest3/host/fixtures/synth.ps1', 'devices/quest3/common/host/fsb1.ps1',
                 'devices/quest3/stage1/fs-proto.ps1', 'devices/quest3/stage3b')
$git = $null; try { $git = (Get-Command git -ErrorAction Stop).Source } catch {}
if ($git) {
    $st = & git -C $T3Root status --porcelain -- @pinnedFiles 2>&1
    $df = & git -C $T3Root diff --name-only HEAD -- @pinnedFiles 2>&1
    # fs-capture.ps1 is not in the list since revision 9 (review MAJOR-3: {serial}, shell id, the persist refusal, #NOT-CAPTURED); its
    # revision-8 behaviour on commands.tsv is test-host2.ps1 section P, run by Y2 below
    Check 'Y1 the pinned stage-3b host files (fs-capture.ps1 excepted: revision 9, test-host2 P), the common/stage-1 helpers and stage3b/** are unchanged against HEAD (git status and git diff empty)' (@($st | Where-Object { $_ }).Count -eq 0 -and @($df | Where-Object { $_ }).Count -eq 0) "$($st -join ' ') $($df -join ' ')"
} else { Skip 'Y1 pinned files' 'git not found' }
if ($Regression) {
    # test-host2 section M has 3 cases on a real misc dump that is gitignored (firmware\quest3\unit1_nonslotted\misc.img): a full
    # clone without it runs 458 checks, the main checkout 461 (P17-P18: fs-capture revision 10)
    $h2n = if (Test-Path -LiteralPath (Join-Path $T3Root 'firmware\quest3\unit1_nonslotted\misc.img')) { 461 } else { 458 }
    foreach ($t in @(@('test-host3b.ps1', 116), @('test-host2.ps1', $h2n))) {
        $of = Join-Path $Scratch "after-$($t[0]).txt"
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $T3Dir $t[0]) -Scratch (Join-Path $Scratch "reg-$($t[0])") -OutFile $of
        $code = $LASTEXITCODE
        $lines = if (Test-Path $of) { [IO.File]::ReadAllLines($of) } else { @() }
        $tot = @($lines | Where-Object { $_ -like 'TOTAL:*' })
        $passN = @($lines | Where-Object { $_ -like 'PASS  *' }).Count
        Check "Y2 $($t[0]): exit 0, $($t[1])/$($t[1]) passed, 0 failed, 0 skipped" ($code -eq 0 -and $passN -eq $t[1] -and $tot.Count -eq 1 -and $tot[0] -ceq "TOTAL: $($t[1]) passed, 0 failed, 0 skipped") "exit $code $($tot -join '')"
        if ($BeforeDir) {
            $bf0 = Join-Path $BeforeDir ($t[0] -replace '\.ps1$', '.txt')
            if (Test-Path $bf0) {
                $bl = @([IO.File]::ReadAllLines($bf0) | Where-Object { $_ -match '^(PASS|FAIL|SKIP)  ' } | ForEach-Object { $_ -replace '[0-9a-f]{40}', '<sha1>' })
                $al = @($lines | Where-Object { $_ -match '^(PASS|FAIL|SKIP)  ' } | ForEach-Object { $_ -replace '[0-9a-f]{40}', '<sha1>' })
                Check "Y3 $($t[0]): the result lines before and after are identical, commit ids of scratch fixture repositories masked ($($al.Count) lines)" (($bl -join "`n") -ceq ($al -join "`n")) "before $($bl.Count) after $($al.Count)"
            } else { Skip "Y3 $($t[0])" "no before file $bf0" }
        }
    }
} else { Skip 'Y2/Y3 regression runs' 'run with -Regression [-BeforeDir <dir>]' }

Say ("TOTAL: {0} passed, {1} failed, {2} skipped" -f $script:pass, $script:fail, $script:skip)
[IO.File]::WriteAllLines($OutFile, [string[]]$script:log, (New-Object System.Text.UTF8Encoding($false)))
if ($script:fail -ne 0) { exit 1 }
exit 0
