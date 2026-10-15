# FrameShift host fixtures, STAGE 3D (v2.7, both Quest 3 units), Windows PowerShell 5.1. No device, no adb/fastboot,
# no COM port, no network. Exit 0 only if every check passes.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host3d.ps1 [-Scratch <dir>] [-OutFile <file>] [-WriteFixtures]
# Reads (never writes) the main checkout's gitignored build\stage3d candidates for the MANIFEST checks ($HOME\
# Downloads\frameshift, or -MainRoot); skipped if absent.
#   A  canonical replays (nominal, garbled/run 3, swapped and tilted), the transcript (no lit banner for the reset), the CLI
#      replay, the paced rehearsal and its summary line
#   B  the reset question (PM J-130): y and n both lead to run 2 (never gating), x and a timeout end safely, x / n during
#      the reset, a refused or rejected reset record, the run-2 guard after the question
#   C  the run-2 prompts: per-eye tilt keys, F keys, bars, the Q7 fallback, plain prompt lines, n only at the dark check
#   D  the classifier: the reset classes, outcomes and exit codes, roll/eyes, pause from the reset, layout and geometry
#      labels, the readings grammar, the integrity gate
#   E  the device's fs-pattern v0.7 / v0.7.1 mock streams (stage3d/fixtures/sim: reset*, quad-vig*, and the v2.7-shaped
#      reset-v27*, quad-v27* with 305/308 modes) through the host parsers; what eos opt_skipped counts
#   F  END TO END: every stage3d/fixtures/image capture through fs-collect3d replay and fs-classify3d
#   G  fs-observe3d.ps1 (MANIFEST, v2.7 baseline, vbmeta lines, the v0.7.1 pin (v0.7 refused), the unit's serial, the
#      module-refusal note); the real current candidate's MANIFEST, the withdrawn first candidate refused (read only)
#   H  fs-checklist3d.ps1 and the observer gate (both units), the SIGNOFF-3d texts and pin table, the WALKTHROUGH-3d;
#      H7-H13 (J-143) the standing phase-A acceptance and the carry-over of the sound check and rehearsals (re-acceptance
#      of changes only, forged/old records, tools/day/speakers), (J-145) charging accepted below 300, the tool set;
#      H14 phase A's PC day (B, E, observer) and no phase A after B on the same day; H15 the made record's writer; H16 a second A in the originating cycle
#   I  timing: New-Fs3dCfg guards, check-timing-3d.py CONSISTENT on the 3d host files
#   J  M4: the parameter scope of the dot-sourced libraries
#   K  fs-nonceonly3d.ps1 (one nonce per run): images rebuilt from the real candidate (read only) with WSL lz4, the observer's
#      nonce-only requirement; K4 a real rebuild by the main checkout's build-image.sh (or, with -K4StageDir <dir>, by
#      that devices\quest3\stage3d directory bound over the main checkout's in a WSL bwrap: before a merge, this branch's)
#   Y  the stage-3c host files are unchanged by this branch
param([string]$Scratch = '', [string]$OutFile = '', [switch]$WriteFixtures, [string]$MainRoot = '<repo>', [string]$K4StageDir = '')
$ErrorActionPreference = 'Stop'
$T3Dir = $PSScriptRoot
if (-not $OutFile) { $OutFile = Join-Path $T3Dir 'test-host3d.output.txt' }
. (Join-Path $T3Dir 'fs-collect3d.ps1')
. (Join-Path $T3Dir 'fixtures\stage3d\gen3d.ps1')
. (Join-Path $T3Dir 'fs-observe3d.ps1')
. (Join-Path $T3Dir 'fs-checklist3d.ps1')
. (Join-Path $T3Dir 'fs-nonceonly3d.ps1')
$T3Root = [IO.Path]::GetFullPath((Join-Path $T3Dir '..\..\..'))
$T3Q3 = Join-Path $T3Root 'devices\quest3'
$T3Fix = Join-Path $T3Dir 'fixtures\stage3d'
if (-not $Scratch) { $Scratch = Join-Path ([IO.Path]::GetTempPath()) ("fs-host3d-" + (New-FsHex 4)) }
$null = New-Item -ItemType Directory -Force -Path $Scratch
$script:pass = 0; $script:fail = 0; $script:skip = 0
$script:log = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $script:log.Add($s); Write-Host $s }
function Check([string]$name, [bool]$cond, [string]$detail = '') { if ($cond) { $script:pass++; Say "PASS  $name" } else { $script:fail++; Say "FAIL  $name $detail" } }
function Skip([string]$name, [string]$why) { $script:skip++; Say "SKIP  $name ($why)" }
Say "== test-host3d  $(Get-Date -Format o)  PowerShell $($PSVersionTable.PSVersion)  scratch=$Scratch"
$U1 = 'QUEST3UNIT1'; $U2 = 'QUEST3UNIT2'

# ------------------------------------------------------------------ helpers --
$script:T3Snd = New-Fs3cSounds
$script:T3N = 0
function T3Keys([string[]]$k, $g) {
    @($k | ForEach-Object { $e = $_; foreach ($ph in 'r1', 'r2', 'r3') { for ($i = 0; $i -lt 8; $i++) { $e = $e.Replace("{$($ph):$i}", $g.Tokens.C[$ph].Substring($i, 1)) } }; $e })
}
function T3Chars([string]$ph, [int]$d = 200) { @(0..7 | ForEach-Object { "p:$($d):{$($ph):$_}" }) + @("p:$($d):Enter") }
# A scripted key source whose N-th prompt (Arm 'p', counted from 1) gets NO key: the head of the script is not armed there,
# so that prompt times out and the head goes to the next prompt (review 2 MAJOR-1: a timeout at one layout item).
function New-T3Keys([string[]]$Script, [int[]]$Silent = @()) {
    $in = New-Fs3cScriptedKeySource -Script $Script
    if (@($Silent).Count -eq 0) { return $in }
    $w = [pscustomobject]@{ Kind = 'scripted'; In = $in; N = 0; Silent = @($Silent); Q = $in.Q; Consumed = $in.Consumed }
    $w | Add-Member ScriptMethod Arm { param([string]$a, [long]$now) if ($a -ceq 'p') { $this.N++; if ($this.Silent -contains $this.N) { $this.In.Cur = 'p'; if ($this.In.Q.Count) { $this.In.Q[0].Due = $null }; return } }; $this.In.Arm($a, $now) }
    $w | Add-Member ScriptMethod Read { param([long]$now) $this.In.Read($now) }
    $w | Add-Member ScriptMethod Drain { param([long]$now) ,$this.In.Drain($now) }
    $w | Add-Member ScriptMethod NextDueMs { param([long]$now) $this.In.NextDueMs($now) }
    $w
}
function T3Run {
    param([string]$Tag, [object[]]$Spec, [bool]$Done = $true, [string[]]$Keys = @(), [hashtable]$Ov = @{}, [string]$GenName = '', [int[]]$Silent = @())
    $script:T3N++
    $gn = if ($GenName) { $GenName } else { $Tag }
    $dir = Join-Path $Scratch ("{0:D3}-{1}" -f $script:T3N, $Tag)
    $g = New-G3dSession -Name $gn -Spec $Spec -Done $Done -Path (Join-Path $dir 'src\capture.raw')
    $ui = New-Fs3cUi -Kind record
    $ks = New-T3Keys (T3Keys $Keys $g) $Silent
    $Ov = @{} + $Ov; if (-not $Ov.ContainsKey('PatternPin')) { $Ov['PatternPin'] = $script:G3dPin }
    $sink = New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd
    $r = Invoke-Fs3dReplay -RawPath (Join-Path $dir 'src\capture.raw') -OutDirX (Join-Path $dir 'out') -Overrides $Ov -Ui $ui -Keys $ks -Sound $sink -Sounds $script:T3Snd
    [pscustomobject]@{ G = $g; R = $r; Ui = $ui; Ks = $ks; Sink = $sink; Dir = $dir; Out = (Join-Path $dir 'out') }
}
function T3Clean($x) { @($x.R.Replay.Divergence).Count -eq 0 -and @($x.R.Replay.UnperformedWrites).Count -eq 0 -and $x.R.Replay.RecaptureIsSourcePrefix }
function T3It($x, [string]$ph, [string]$item) { @($x.R.ReadingObjs | Where-Object { $_.Ph -ceq $ph -and $_.Item -ceq $item })[0] }
function T3Sent($x, [string]$ph) { @($x.R.Sent | Where-Object { $_ -cmatch "^fs-phase $ph " }).Count -eq 1 }
function T3Ph($x, [string]$ph) { @($x.R.Phases | Where-Object { $_.Ph -ceq $ph })[0] }
function T3Items($x, [string]$ph) { (@($x.R.ReadingObjs | Where-Object { $_.Ph -ceq $ph } | ForEach-Object { "$($_.Item)=$($_.Obs)" }) -join ',') }
function T3Desc($x) { "sent=$(@($x.R.Sent | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' }) -join ',') end=$($x.R.EndReason) stop=$($x.R.StopReason) done=$($x.R.DoneSent) div=$(@($x.R.Replay.Divergence) -join ';') items=$((@('r1','r2','r3') | ForEach-Object { T3Items $x $_ }) -join ' / ')" }
function T3Cls($x) { Invoke-Fs3dClassifyDir -DirX $x.Out -S1X 'PASS' -PinX $script:G3dPin }
$SP1 = @(@{ Ph = 'p0' }, @{ Ph = 'r1' }); $SP2 = $SP1 + @(@{ Ph = 'r2' }); $SP3 = $SP2 + @(@{ Ph = 'r3' })
$KR1 = @('p:1500:b')                                                         # the reset question: nothing seen (b = it stayed dark; review 2 MINOR-2)
$KDD = @('p:1800:d') + (T3Chars 'r2' 250) + @('p:1200:d') + (T3Chars 'r2' 250) + @('p:900:y')   # r2 read in both eyes, dark y
$KLAY = @('p:1200:0', 'p:900:u', 'p:900:1', 'p:300:2', 'p:1200:0', 'p:900:u', 'p:900:3', 'p:300:4')   # per eye: level, F upright, bars (12 / 34) (review 2 MAJOR-1 order)
$KR2C = @('p:1800:c', 'p:900:c', 'p:800:y')                                  # r2 garbled, dark y: the run-3 path (no bars)
$KR2B = @('p:1800:b', 'p:900:b', 'p:800:y')                                  # r2 dark in both eyes: no run 3 (rule 2)

# ------------------------------------------------------------------ A --------
Say '== A. canonical replays, the transcript, the CLI replay, the rehearsal'
$CAN = @{}
foreach ($cn in $script:G3dCanon.Keys) {
    $c = $script:G3dCanon[$cn]
    $script:T3N++
    $dir = Join-Path $Scratch ("{0:D3}-canon-{1}" -f $script:T3N, $cn)
    $g = New-G3dSession -Name $cn -Spec $c.Spec -Done $c.Done -Path (Join-Path $dir 'src\capture.raw')
    $keys = Expand-G3dKeys $c.Keys $g.Tokens.C['r2']
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
    $r = Invoke-Fs3dReplay -RawPath (Join-Path $fx 'capture.raw') -OutDirX (Join-Path $dir 'out') -Overrides @{ PatternPin = $script:G3dPin } -Ui $ui -Keys $ks -Sound $sink -Sounds $script:T3Snd
    $CAN[$cn] = [pscustomobject]@{ G = $g; R = $r; Ui = $ui; Ks = $ks; Sink = $sink; Dir = $dir; Out = (Join-Path $dir 'out') }
}
$a = $CAN['nominal-read']; $ca = T3Cls $a
Check 'A1 nominal: p0, r1 (the reset), r2 sent once each with the chained <prev>; the one reset question answered b (stayed dark); r2 read in both eyes, then per eye the tilt (level), the F (upright), the bars (1|2 left, 3|4 right) in that order (review 2 MAJOR-1); no r3 (rule 2); fs-done; COLLECTED-VALID; readings3d.txt' `
    ((T3Clean $a) -and (T3Sent $a 'p0') -and (T3Sent $a 'r1') -and (T3Sent $a 'r2') -and -not (T3Sent $a 'r3') -and $a.R.DoneSent -and $a.R.Status -ceq 'COLLECTED-VALID' -and
     (@($a.R.Sent) -join '|') -match "fs-phase r1 [0-9a-f]{32} $($a.G.Sha16['p0'])\|fs-phase r2 [0-9a-f]{32} $($a.G.Sha16['r1'])\|fs-done$" -and (T3Items $a 'r1') -ceq 'seen=NOT_SEEN' -and
     (T3Items $a 'r2') -ceq 'left=READ,right=READ,dark=DARK_NOW,tilt_left=LEVEL,orient_left=UPRIGHT,bars_left=BARS,tilt_right=LEVEL,orient_right=UPRIGHT,bars_right=BARS' -and
     (T3It $a 'r2' 'bars_left').Bars -ceq '12' -and (T3It $a 'r2' 'bars_right').Bars -ceq '34' -and (Test-Path (Join-Path $a.Out 'readings3d.txt')) -and -not (Test-Path (Join-Path $a.Out 'readings3c.txt'))) (T3Desc $a)
Check 'A1b nominal classified: exit 10, P0 OK, RESET-DONE (reset seen: NOT_SEEN), R2 SHOWN-QUAD roll=21 eyes=swap, OPTICAL PASS; GEOMETRY "the eye swap holds", ROLL "level in both eyes"; REGISTERED: STAGE PASS' `
    ($ca.Code -eq 10 -and $ca.Outcome.Phases['r1'].Class -ceq 'RESET-DONE' -and $ca.Outcome.R1Seen -ceq 'NOT_SEEN' -and $ca.Outcome.Phases['r2'].Reason -match 'roll=21 eyes=swap' -and
     $ca.Outcome.Optical['r2'].Class -ceq 'OPTICAL PASS' -and $ca.Outcome.Geometry -match 'the eye swap holds' -and $ca.Outcome.Roll -match 'level in both eyes' -and $ca.Outcome.Registered -match '^STAGE PASS: ') ($ca.Lines -join ' / ')
$a = $CAN['garbled-r3']; $cg = T3Cls $a
Check 'A2 garbled path: r2 garbled in both eyes -> run 3 requested (rules 1-5), the bar counts NOT asked (Q7 fallback), r3 SAME_AS_R2, fs-done; classified exit 10, not a stage PASS, interpretation T2' `
    ((T3Clean $a) -and (T3Sent $a 'r3') -and $a.R.R3Rule.Allow -and (T3Items $a 'r2') -ceq 'left=GARBLED,right=GARBLED,dark=DARK_NOW,bars_left=NOT_ASKED,bars_right=NOT_ASKED' -and
     (T3Items $a 'r3') -ceq 'left=SAME_AS_R2,right=SAME_AS_R2,dark=DARK_NOW' -and $cg.Code -eq 10 -and $cg.Outcome.Registered -match '^not a stage PASS' -and $cg.Outcome.Interpretation.Code -ceq 'T2' -and
     @($cg.Outcome.Q7NotAsked).Count -eq 2) "$(T3Desc $a) | $($cg.Lines -join ' / ')"
$a = $CAN['swapped-tilted']; $cs = T3Cls $a
Check 'A3 swapped and tilted: the reset question answered y (recorded SEEN, run 2 still follows: never gating); run 2 read in both eyes, bars 3|4 left / 1|2 right, tilt clockwise left / counter-clockwise right; classified STAGE PASS with GEOMETRY "swap assumption is wrong", ROLL "remaining tilt" and the R1 OBSERVATION label' `
    ((T3Clean $a) -and (T3Items $a 'r1') -ceq 'seen=SEEN' -and (T3Sent $a 'r2') -and (T3It $a 'r2' 'tilt_left').Obs -ceq 'CLOCKWISE' -and (T3It $a 'r2' 'tilt_right').Obs -ceq 'COUNTERCLOCKWISE' -and
     $cs.Code -eq 10 -and $cs.Outcome.Registered -match '^STAGE PASS: ' -and $cs.Outcome.Geometry -match 'eye-swap assumption is wrong' -and $cs.Outcome.Roll -match 'remaining tilt \(left=CLOCKWISE, right=COUNTERCLOCKWISE\)' -and
     @($cs.Outcome.Labels | Where-Object { $_ -match '^R1 OBSERVATION' }).Count -eq 1 -and $cs.Outcome.Layout['left'].Label -match "OTHER eye's picture") ($cs.Lines -join ' / ')
$tr = @($CAN['nominal-read'].Ui.Transcript)
$snd = @($CAN['nominal-read'].R.SoundsPlayed | ForEach-Object { ($_ -split '@')[0] })
Check 'A4 the reset is not lit (README 6.5): no LOOK/STARTING or ENDED banner and no START/END sound for it, plain "DISPLAY RESET running (it should stay dark)" lines, the question banner "DISPLAY RESET DONE - ONE QUESTION"; RUN 2 has its LOOK and ENDED banners; nothing says RUN 1 or SHOWN; sounds START (cue), ANSWER, START, END, ANSWER, FINISH' `
    (@($tr | Where-Object { $_ -match 'RESET.*(STARTING|ENDED)|RUN 1|SHOWN' }).Count -eq 0 -and @($tr | Where-Object { $_ -ceq 'DISPLAY RESET running (it should stay dark)' }).Count -eq 1 -and
     @($tr | Where-Object { $_ -match '^\[BANNER answer\] DISPLAY RESET DONE - ONE QUESTION' }).Count -eq 1 -and @($tr | Where-Object { $_ -match '^\[BANNER look\] RUN 2 STARTING - LOOK' }).Count -eq 1 -and
     ($snd -join ',') -ceq 'START,ANSWER,START,END,ANSWER,FINISH') "sounds $($snd -join ',')"
$cdir = Join-Path $Scratch 'cli-replay'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $T3Dir 'fs-collect3d.ps1') -S3dReplay (Join-Path $T3Fix 'replay\garbled-r3\capture.raw') -S3dOutDir $cdir -S3dKeyScript (Join-Path $T3Fix 'replay\garbled-r3\keys.txt') -S3dReplayPin $script:G3dPin
$code = $LASTEXITCODE
Check 'A5 fs-collect3d.ps1 -S3dReplay ... -S3dKeyScript (CLI): exit 10, COLLECTED-VALID, four phases FSB1 VALID, r1 reset seen NOT_SEEN, run-3 rule held, fs-done; session.json (Stage 3d), readings3d.txt, phase-*.raw written' `
    ($code -eq 10 -and ($out -join "`n") -match 'STATUS: COLLECTED-VALID' -and @($out | Where-Object { $_ -match '^PHASE (p0|r1|r2|r3): FSB1 VALID' }).Count -eq 4 -and ($out -join "`n") -match 'PHASE r1: FSB1 VALID; .*reset seen: NOT_SEEN' -and
     ($out -join "`n") -match 'RUN-3 RULE: held' -and ($out -join "`n") -match 'RECOVERY: fs-done sent' -and (Get-Content -Raw (Join-Path $cdir 'session.json') | ConvertFrom-Json).Stage -ceq '3d' -and
     (Test-Path (Join-Path $cdir 'readings3d.txt')) -and @(Get-ChildItem $cdir -Filter 'phase-*.raw').Count -eq 4) "exit $code $($out -join ' / ')"
$pdir = Join-Path $Scratch 'paced'
$gp = New-G3dSession -Name 'paced' -Spec @(@{ Ph = 'p0'; Rec = 'ran0' }) -Done $true -Path (Join-Path $pdir 'src\capture.raw')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rp = Invoke-Fs3dReplay -RawPath (Join-Path $pdir 'src\capture.raw') -OutDirX (Join-Path $pdir 'out') -Overrides @{ PatternPin = $script:G3dPin } -Paced
$el = $sw.ElapsedMilliseconds
Check "A6 the rehearsal transport (paced on the real clock, no headset) runs a short session through the same code ($el ms): no divergence, p0 refused ran=0, fs-done" `
    (@($rp.Replay.Divergence).Count -eq 0 -and $el -ge 4000 -and $rp.DoneSent -and (@($rp.Phases)[0]).Refusal.Ran -eq 0) "$el ms $(@($rp.Replay.Divergence) -join ';')"
$rs = (Write-Fs3dSummary $CAN['garbled-r3'].R $true) -join "`n"
Check 'A7 the rehearsal summary: the reset question and the run-2 answer times and the go/no-go against 40 s (SIGNOFF-3d A); the summary names the reset answer and the Q7 fallback (what fs-checklist3d phase A checks)' `
    ($rs -match 'REHEARSAL: reset question answers took 1\.5 s' -and $rs -match 'REHEARSAL: run-2 answers took 3\.5 s' -and $rs -match 'REHEARSAL: reset plus run-2 answers 5\.0 s; go/no-go \(SIGNOFF-3d A\): GO \(<= 40 s\)' -and
     $rs -match '(?m)^PHASE r1: FSB1 VALID; .*reset seen: NOT_SEEN' -and $rs -match 'not asked \(Q7 fallback\)' -and $rs -notmatch 'read path') $rs
$rn = (Write-Fs3dSummary $CAN['nominal-read'].R $true) -join "`n"
Check 'A8 review 2 MAJOR-1, the TIMED rehearsal of the read path: on the nominal-read replay the summary prints the read-path lines (9 of 9 run-2 items, the per-eye times of the reading, tilt, F and bars, the spare time before the cut-off run-2 end + 110 s) and GO (every item answered, at least 10 s to spare); no garbled-path line' `
    ($rn -match '(?m)^REHEARSAL \(read path\): run-2 answers took [0-9]+\.[0-9] s from the first prompt; 9 of 9 items answered$' -and $rn -match '(?m)^REHEARSAL \(read path\): left eye: reading and characters [0-9.]+ s; tilt [0-9.]+ s; orient [0-9.]+ s; bars [0-9.]+ s$' -and
     $rn -match '(?m)^REHEARSAL \(read path\): the last answer [0-9]+\.[0-9] s before the cut-off \(run-2 end \+ 110 s\); go/no-go \(SIGNOFF-3d A\): GO \(every item answered, at least 10 s to spare\)$' -and $rn -notmatch 'reset plus run-2') $rn
$ch = @(Get-Content -LiteralPath (Join-Path $T3Dir 'fs-collect3d.ps1') | Where-Object { $_ -match 'RehearsalShowChars' })
Check 'A9 a rehearsal (replay with -S3dRehearsal) prints run 2''s 8 characters at its go marker ("REHEARSAL ONLY: ..."); a live session never does (RehearsalShowChars is set only on the replay path of the CLI; a live -S3dReplayPin or rehearsal is refused)' `
    (@($ch | Where-Object { $_ -match '^\s+\$ov\.RehearsalShowChars = \$true$' }).Count -eq 1 -and (Get-Content -Raw -LiteralPath (Join-Path $T3Dir 'fs-collect3d.ps1')) -match '(?s)if \(\$reh\) \{\s+\$ov\.RehearsalShowChars = \$true.{0,400}\$ov\.GiveUpMs = \[long\]160000' -and @($ch | Where-Object { $_ -match 'RehearsalShowChars = \$false' }).Count -eq 1 -and
     @($CAN['nominal-read'].Ui.Transcript | Where-Object { $_ -match 'REHEARSAL ONLY' }).Count -eq 0) ($ch -join ' | ')

# ------------------------------------------------------------------ B --------
Say '== B. the reset question (recorded, never gating; PM J-130)'
$x = T3Run 'b1-seen-y' $SP2 $true (@('p:1500:y') + $KR2B)
Check 'B1 y (something visible): recorded SEEN with its echo; run 2 is sent all the same; fs-done' ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'seen=SEEN' -and (T3Sent $x 'r2') -and $x.R.DoneSent -and
    @($x.Ui.Transcript | Where-Object { $_ -ceq 'RESET: SOMETHING WAS VISIBLE (recorded; run 2 still follows)' }).Count -eq 1) (T3Desc $x)
$x = T3Run 'b2-seen-x' $SP1 $true @('p:1500:x')
Check 'B2 x at the reset question: ABORT recorded, run 2 NOT sent, red SAFE FINISH, fs-done' ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'seen=ABORT' -and -not (T3Sent $x 'r2') -and $x.R.DoneSent -and
    $x.R.EndReason -match '^SAFE FINISH after the display reset: x at the reset question' -and @($x.Ui.Transcript | Where-Object { $_ -match '^\[BANNER abort\] SAFE FINISH' }).Count -eq 1) (T3Desc $x)
$x = T3Run 'b3-seen-timeout' $SP1 $true @()
Check 'B3 no answer within 30 s: TIMEOUT recorded, run 2 NOT sent (as every prompt), fs-done' ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'seen=TIMEOUT' -and -not (T3Sent $x 'r2') -and $x.R.DoneSent -and $x.R.EndReason -match 'timed out' -and
    (T3It $x 'r1' 'seen').PromptMs + 30000 -le ($x.R.Exchanges | Where-Object { $_.Verb -ceq 'fs-done' }).SendMs) (T3Desc $x)
$x = T3Run 'b4-x-during-reset' $SP1 $true @('i:600:x', 'p:1500:b')
Check 'B4 x during the reset: ABORT NOTED at once (red banner, ALARM), the question still asked and recorded, then no run 2, fs-done' ((T3Clean $x) -and (T3Ph $x 'r1').AbortNoted -and (T3Items $x 'r1') -ceq 'seen=NOT_SEEN' -and
    -not (T3Sent $x 'r2') -and $x.R.DoneSent -and $x.R.EndReason -match 'ABORT \(x\) noted during THE DISPLAY RESET' -and @($x.Ui.Transcript | Where-Object { $_ -match '^\[BANNER abort\] ABORT NOTED \| the reset finishes' }).Count -eq 1) (T3Desc $x)
$x = T3Run 'b5-n-during-reset' $SP2 $true (@('i:600:n') + $KR1 + $KR2B)
Check 'B5 n during the reset is discarded (logged), not an abort: the question, then run 2' ((T3Clean $x) -and -not (T3Ph $x 'r1').AbortNoted -and (T3Sent $x 'r2') -and @($x.R.Events | Where-Object { $_ -match 'key-discarded during r1 key=n' }).Count -eq 1) (T3Desc $x)
$x = T3Run 'b6-reset-ran1' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Rec = 'ran1' }) $true $KR1
$y = T3Run 'b6b-reset-ran0' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Rec = 'ran0' }) $true @()
$z = T3Run 'b6c-reset-reject' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Rec = 'reject' }) $true $KR1
Check 'B6 a reset refused with ran=1 or an FSB1-rejected reset record: the question is asked (the reset may have run), then no run 2, fs-done; refused with ran=0: no question, fs-done' `
    ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'seen=NOT_SEEN' -and -not (T3Sent $x 'r2') -and $x.R.DoneSent -and (T3Clean $y) -and (T3Items $y 'r1') -ceq '' -and $y.R.DoneSent -and -not (T3Sent $y 'r2') -and
     (T3Clean $z) -and (T3Items $z 'r1') -ceq 'seen=NOT_SEEN' -and -not (T3Sent $z 'r2') -and $z.R.DoneSent -and $z.R.Status -ceq 'COLLECTED-REJECTED') "$(T3Desc $x) || $(T3Desc $y) || $(T3Desc $z)"
$x = T3Run 'b8-held-b' $SP2 $true (@('p:1500:b', 'j:300:b') + $KR2B)
$y = T3Run 'b8b-n-in-run2' $SP2 $true (@('p:1500:b', 'j:4000:n') + @('p:1500:y'))
$z = T3Run 'b8c-n-in-p0' @(@{ Ph = 'p0' }) $true @('g:500:n')
Check 'B8 review MAJOR-1: the reset answer (b) pressed again (held or doubled, arriving during run 2 before its go marker) is ignored as a repeat (logged), not an abort: run 2 runs and is answered normally; an n during run 2 after its go marker is still taken as x (stage 3c MINOR-4: one safety question, no run 3); n during p0 aborts as in stage 3c (review MINOR-1)' `
    ((T3Clean $x) -and -not (T3Ph $x 'r2').AbortNoted -and (T3Items $x 'r2') -ceq 'left=DARK,right=DARK,dark=DARK_NOW' -and @($x.R.Events | Where-Object { $_ -match 'key-repeat-ignored during r2 key=b' }).Count -eq 1 -and
     (T3Clean $y) -and (T3Ph $y 'r2').AbortNoted -and (T3Items $y 'r2') -ceq 'left=ABORT,right=ABORT,dark=DARK_NOW' -and $y.R.DoneSent -and
     (T3Clean $z) -and (T3Ph $z 'p0').AbortNoted -and -not (T3Sent $z 'r1') -and $z.R.DoneSent) "$(T3Desc $x) || $(T3Desc $y) || $(T3Desc $z)"
$x = T3Run 'b9-n-at-question' $SP2 $true (@('p:1500:n', 'p:800:b') + $KR2B)
$y = T3Run 'b9b-y' $SP2 $true (@('p:1500:n', 'p:700:n', 'p:800:y') + $KR2B)
$qt = @($x.Ui.Transcript | Where-Object { $_ -match '^\[BANNER answer\] DISPLAY RESET DONE' -or $_ -match '^RESET: did you see' })
Check 'B9 review 2 MINOR-2: the reset question''s keys are y (something visible) and b (it stayed dark), never n: an n there is not an answer and not an abort (the question stays, a line says what y and b mean, logged); then b -> NOT_SEEN, or y -> SEEN, and run 2 runs normally (not aborted)' `
    ((T3Clean $x) -and (T3Items $x 'r1') -ceq 'seen=NOT_SEEN' -and (T3It $x 'r1' 'seen').Key -ceq 'b' -and (T3Sent $x 'r2') -and -not (T3Ph $x 'r2').AbortNoted -and (T3Items $x 'r2') -ceq 'left=DARK,right=DARK,dark=DARK_NOW' -and
     @($x.Ui.Transcript | Where-Object { $_ -ceq 'RESET: n is not an answer here. Press y if you saw anything, b if it stayed dark (x = abort).' }).Count -eq 1 -and @($x.R.Events | Where-Object { $_ -match 'reset-question n is not an answer' }).Count -eq 1 -and
     ($qt -join ' ') -match 'y = yes, b = no, it stayed dark, x = abort' -and ($qt -join ' ') -match 'b = no, it stayed dark   x = abort' -and ($qt -join ' ') -notmatch 'n = ' -and
     (T3Clean $y) -and (T3Items $y 'r1') -ceq 'seen=SEEN' -and (T3Sent $y 'r2') -and -not (T3Ph $y 'r2').AbortNoted -and @($y.R.Events | Where-Object { $_ -match 'reset-question n is not an answer' }).Count -eq 2) "$(T3Desc $x) || $(T3Desc $y)"
$x = T3Run 'b10-reset-skipped' @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Skip = 'p0-write-missing'; Markers = 'skip' }, @{ Ph = 'r2'; Skip = 'run1-not-run'; Markers = 'skip' }) $true @()
Check 'B10 review 2 MINOR-4: a reset the headset skipped (a valid record whose reset step is a skip): no reset question (nothing recorded for r1, logged, a plain line); run 2 is still requested (the device gates it: skipped); fs-done' `
    ((T3Clean $x) -and (T3Items $x 'r1') -ceq '' -and (T3Ph $x 'r1').GapMode -ceq 'reset-skipped' -and @($x.R.Events | Where-Object { $_ -match 'reset-question not asked: the headset skipped the display reset' }).Count -eq 1 -and
     @($x.Ui.Transcript | Where-Object { $_ -match '^\[BANNER answer\] DISPLAY RESET DONE' }).Count -eq 0 -and @($x.Ui.Transcript | Where-Object { $_ -ceq 'DISPLAY RESET SKIPPED by the headset: no question (nothing was shown).' }).Count -eq 1 -and (T3Sent $x 'r2') -and $x.R.DoneSent) (T3Desc $x)
$x0 = T3Run 'b7-guard-base' $SP2 $true ($KR1 + $KR2B) -GenName 'guard'
$t1 = (T3Ph $x0 'r1').SendMs
$x = T3Run 'b7-guard' $SP2 $true ($KR1 + $KR2B) @{ GiveUpMs = [long]($t1 + 70000) } -GenName 'guard'
Check 'B7 the run-2 guard (G 82 s) after the question: with the give-up 70 s after the reset was sent, the reset runs (G 68 s), the question shows "RUN 2 NO LONGER POSSIBLE", run 2 is not sent (guard), fs-done' `
    ((T3Sent $x 'r1') -and -not (T3Sent $x 'r2') -and (T3Ph $x 'r2').NotRunWhy -match '^guard:' -and $x.R.DoneSent -and (T3Ph $x 'r1').NextLost -and
     @($x.Ui.Transcript | Where-Object { $_ -match '^RUN 2 NO LONGER POSSIBLE' }).Count -eq 1) (T3Desc $x)

# ------------------------------------------------------------------ C --------
Say '== C. run-2 prompts: per-eye tilt (the 21-degree roll check), F, bars, the Q7 fallback'
$x = T3Run 'c1-tilt-keys' $SP2 $true ($KR1 + $KDD + @('p:1200:?', 'p:900:i', 'p:900:1', 'p:300:2', 'p:1200:l', 'p:900:?', 'p:900:3', 'p:300:4'))
Check 'C1 the tilt keys: ? = UNKNOWN, l = COUNTERCLOCKWISE; the F keys i = HALF_TURN, ? = can''t tell (review MINOR-2: ? in both prompts, 0 only = level); echoes in words; the tilt prompt names level / clockwise (right end lower) / counter-clockwise (left end lower) / can''t tell' `
    ((T3Clean $x) -and (T3It $x 'r2' 'tilt_left').Obs -ceq 'UNKNOWN' -and (T3It $x 'r2' 'tilt_right').Obs -ceq 'COUNTERCLOCKWISE' -and (T3It $x 'r2' 'orient_left').Obs -ceq 'HALF_TURN' -and (T3It $x 'r2' 'orient_right').Obs -ceq 'UNKNOWN' -and
     @($x.Ui.Transcript | Where-Object { $_ -ceq "LEFT EYE, is the text level?   0 = level   r = turned clockwise (right end lower)   l = turned counter-clockwise (left end lower)   ? = can't tell   x = abort" }).Count -eq 1 -and
     @($x.Ui.Transcript | Where-Object { $_ -ceq 'RIGHT EYE TILT: TURNED COUNTER-CLOCKWISE (left end lower)' }).Count -eq 1 -and @($x.Ui.Transcript | Where-Object { $_ -ceq 'LEFT EYE BARS: 1 | 2' }).Count -eq 1) (T3Desc $x)
$x = T3Run 'c2-q7-oneeye' $SP3 $true ($KR1 + @('p:1800:c', 'p:1200:d', 'p:300:1', 'p:300:1', 'p:300:1', 'p:300:1', 'p:300:1', 'p:300:1', 'p:300:1', 'p:300:1', 'p:300:Enter', 'p:900:y', 'p:900:r', 'p:900:u') + @('p:2000:s', 'p:900:s', 'p:800:y'))
Check 'C2 Q7 fallback: left garbled, right d with wrong characters (the run-3 path): no bar question in either eye (NOT_ASKED), but the right eye''s F and tilt are asked; run 3 follows' `
    ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=GARBLED,right=READ,dark=DARK_NOW,bars_left=NOT_ASKED,tilt_right=CLOCKWISE,orient_right=UPRIGHT,bars_right=NOT_ASKED' -and (T3Sent $x 'r3') -and
     @($x.Ui.Transcript | Where-Object { $_ -match 'BARS:' }).Count -eq 0) (T3Desc $x)
$x = T3Run 'c3-n-at-eye' $SP2 $true ($KR1 + @('p:1500:n', 'p:300:b', 'p:900:b', 'p:800:n'))
$lines = @($CAN['nominal-read'].Ui.Transcript + $CAN['garbled-r3'].Ui.Transcript | Where-Object { $_ -match '=' -and $_ -notmatch '^\[BANNER' })
Check 'C3 n at an eye question does nothing (key-ignored); n at the dark check = light visible -> SAFE FINISH, fs-done; every key prompt line is one line of at most 170 characters and offers x = abort' `
    ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=DARK,right=DARK,dark=LIGHT_NOW' -and @($x.R.Events | Where-Object { $_ -match 'key-ignored r2/left key=n' }).Count -eq 1 -and $x.R.EndReason -match 'dark check: light visible' -and $x.R.DoneSent -and
     @($lines | Where-Object { $_.Length -gt 170 }).Count -eq 0 -and @($lines | Where-Object { $_ -match '   [a-z0-9?] = ' -and $_ -notmatch 'x = abort' }).Count -eq 0) "$(T3Desc $x) | long: $(@($lines | Where-Object { $_.Length -gt 170 }) -join ' | ')"

# review 2 MAJOR-1: a timeout at one diagnostic item (tilt, F, bars) is recorded and the NEXT item is asked (stage 3c ended
# the session there and lost every later item); x still ends safely; the run-3 rule is unchanged (rules 1-4)
$x = T3Run 'c4-tilt-timeout' $SP2 $true ($KR1 + $KDD + @('p:900:u', 'p:900:1', 'p:300:2', 'p:1200:0', 'p:900:u', 'p:900:3', 'p:300:4')) -Silent @(5)
Check 'C4 review 2 MAJOR-1: no answer at the LEFT tilt (30 s): TIMEOUT recorded, the left F and bars and the whole right eye are still asked and answered; no safe finish (the session ends normally, fs-done); logged' `
    ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=READ,right=READ,dark=DARK_NOW,tilt_left=TIMEOUT,orient_left=UPRIGHT,bars_left=BARS,tilt_right=LEVEL,orient_right=UPRIGHT,bars_right=BARS' -and
     -not (T3Ph $x 'r2').GapSafe -and $x.R.EndReason -notmatch 'SAFE FINISH' -and $x.R.DoneSent -and @($x.R.Events | Where-Object { $_ -match 'layout-timeout r2/tilt_left' }).Count -eq 1) (T3Desc $x)
$x = T3Run 'c5-all-silent' $SP2 $true ($KR1 + $KDD)
$c5 = (Get-Fs3dRehearsalLines $x.R) -join "`n"
Check 'C5 no answer at any tilt/F/bar question: each asked item times out in turn and the next is asked while at least 10 s (LayoutMinSec) remain before the cut-off (run-2 end + 110 s); the rest NOT_ASKED; no safe finish, fs-done; the read-path rehearsal line says NO-GO naming the items' `
    ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=READ,right=READ,dark=DARK_NOW,tilt_left=TIMEOUT,orient_left=TIMEOUT,bars_left=TIMEOUT,tilt_right=TIMEOUT,orient_right=NOT_ASKED,bars_right=NOT_ASKED' -and
     @($x.R.Events | Where-Object { $_ -match 'layout-not-asked r2/orient_right' }).Count -eq 1 -and $x.R.EndReason -notmatch 'SAFE FINISH' -and $x.R.DoneSent -and
     $c5 -match '3 of 9 items answered \(not: tilt_left, orient_left, bars_left, tilt_right, orient_right, bars_right\)' -and $c5 -match 'NO-GO') "$(T3Desc $x) | $c5"
$x = T3Run 'c6-q7-timeout' $SP2 $true ($KR1 + @('p:1800:c', 'p:1200:d') + @(0..7 | ForEach-Object { 'p:300:1' }) + @('p:300:Enter', 'p:900:y', 'p:900:u') + @('p:2000:s', 'p:900:s', 'p:800:y')) -Silent @(5)
Check 'C6 review 3 MAJOR-A (safety): on the run-3 path a timeout at a tilt/F question still ends the session safely (TIMEOUT recorded, the rest NOT_ASKED, SAFE FINISH): no lit run 3 after an unanswered prompt; fs-done' `
    ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=GARBLED,right=READ,dark=DARK_NOW,bars_left=NOT_ASKED,tilt_right=TIMEOUT,orient_right=NOT_ASKED,bars_right=NOT_ASKED' -and -not (T3Sent $x 'r3') -and
     $x.R.EndReason -match '^SAFE FINISH after RUN 2: tilt_right timed out \(run 3 could follow' -and $x.R.DoneSent) (T3Desc $x)
# review 2 MAJOR-1: the human window at stage-3c speeds (the real 3c run: the left eye's d and 8 characters 12.7 s, the right
# eye's 10.2 s, the dark check 2.5 s, the bars 20.7 s; the practice run: the tilt 7.3 s, the F 8.4 s), the cut-off run-2 end
# + 110 s, the skip margin 10 s. The keys are timed from each prompt; the replay clock is the session clock.
$K3cEye = { param([string]$first, [int]$per, [int]$enter) @("p:$($first):d") + @(0..7 | ForEach-Object { "p:$($per):{r2:$_}" }) + @("p:$($enter):Enter") }
$K3cSpeed = @('p:3000:b') + (& $K3cEye 2000 1100 1900) + (& $K3cEye 1500 900 1500) + @('p:2500:y')
$x = T3Run 'c7-3c-speeds' $SP2 $true ($K3cSpeed + @('p:7300:0', 'p:8400:u', 'p:10000:1', 'p:10700:2', 'p:7300:0', 'p:8400:u', 'p:10000:3', 'p:10700:4'))
$c7 = @(Get-Fs3dRehearsalLines $x.R)
$p2e = (T3Ph $x 'r2').EndMs; $c7t = @($x.R.ReadingObjs | Where-Object { $_.Ph -ceq 'r2' } | ForEach-Object { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0} +{1:0.0}', $_.Item, ($_.AnswerMs - $p2e) / 1000.0) })
Say "      timing at stage-3c speeds (answer times after the run-2 end): $($c7t -join ', ')"
foreach ($l in $c7) { Say "      $l" }
$x2 = T3Run 'c7b-3c-speeds-F-timeout' $SP2 $true ($K3cSpeed + @('p:7300:0', 'p:10000:1', 'p:10700:2', 'p:7300:0', 'p:8400:u', 'p:10000:3', 'p:10700:4')) -Silent @(6)
$p2e2 = (T3Ph $x2 'r2').EndMs; $c7u = @($x2.R.ReadingObjs | Where-Object { $_.Ph -ceq 'r2' } | ForEach-Object { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}={1} +{2:0.0}', $_.Item, $_.Obs, $(if ($_.AnswerMs -ge 0) { ($_.AnswerMs - $p2e2) / 1000.0 } else { ($_.PromptMs - $p2e2) / 1000.0 })) })
Say "      with the 3c run's F timeout at the left F: $($c7u -join ', ')"
Check 'C7 review 2 MAJOR-1, the human window at stage-3c speeds (HOST.md): all 9 run-2 items answered, the last at least 10 s before the cut-off (run-2 end + 110 s): read-path GO; with the 3c run''s 30-s F timeout at the left F, both tilts (the main goal) and the right F are still answered (the right bars at most time out at the cut-off)' `
    ((T3Clean $x) -and (T3Items $x 'r2') -ceq 'left=READ,right=READ,dark=DARK_NOW,tilt_left=LEVEL,orient_left=UPRIGHT,bars_left=BARS,tilt_right=LEVEL,orient_right=UPRIGHT,bars_right=BARS' -and ($c7 -join ' ') -match 'GO \(every item answered, at least 10 s to spare\)' -and
     (T3Clean $x2) -and (T3It $x2 'r2' 'tilt_left').Obs -ceq 'LEVEL' -and (T3It $x2 'r2' 'orient_left').Obs -ceq 'TIMEOUT' -and (T3It $x2 'r2' 'bars_left').Obs -ceq 'BARS' -and (T3It $x2 'r2' 'tilt_right').Obs -ceq 'LEVEL' -and
     (T3It $x2 'r2' 'orient_right').Obs -ceq 'UPRIGHT' -and @('TIMEOUT', 'NOT_ASKED', 'BARS') -ccontains (T3It $x2 'r2' 'bars_right').Obs) "$($c7 -join ' / ') || $(T3Desc $x2)"

# ------------------------------------------------------------------ D --------
Say '== D. the classifier (fs-classify3d.ps1)'
$dc = @(
    @('d1-done', @{ }, $SP2, ($KR1 + $KR2B), 'RESET-DONE', 'PASS (machine side)', 10),
    @('d1-inactive', @{ Reset = 'inactive' }, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Reset = 'inactive' }, @{ Ph = 'r2' }), ($KR1 + $KR2B), 'ALREADY-INACTIVE', 'PASS (machine side)', 10),
    @('d1-off-reject', @{ Reset = 'off-reject' }, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Reset = 'off-reject' }, @{ Ph = 'r2'; Skip = 'run1-supervisor'; Markers = 'skip' }), ($KR1 + $KR2B), 'RESET-NOT-DONE', 'RESET NOT DONE', 19),
    @('d1-on-reject', @{ Reset = 'on-reject' }, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Reset = 'on-reject' }, @{ Ph = 'r2'; Skip = 'run1-supervisor'; Markers = 'skip' }), ($KR1 + $KR2B), 'RESET-NOT-DONE', 'RESET NOT DONE', 19),
    @('d1-unknown', @{ Reset = 'unknown' }, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Reset = 'unknown' }, @{ Ph = 'r2'; Skip = 'run1-supervisor'; Markers = 'skip' }), ($KR1 + $KR2B), 'RESET-NOT-DONE', 'RESET NOT DONE', 19),
    @('d1-shown', @{ Reset = 'shown' }, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Reset = 'shown' }, @{ Ph = 'r2'; Skip = 'run1-not-reset'; Markers = 'skip' }), ($KR1 + $KR2B), 'INCONCLUSIVE', 'INCONCLUSIVE', 14),
    @('d1-nocommit', @{ Reset = 'nocommit' }, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Reset = 'nocommit' }, @{ Ph = 'r2'; Skip = 'run1-not-reset'; Markers = 'skip' }), ($KR1 + $KR2B), 'INCONCLUSIVE', 'INCONCLUSIVE', 14),
    @('d1-on-reject-r2-ran', @{}, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Reset = 'on-reject' }, @{ Ph = 'r2' }), ($KR1 + $KR2B), 'RESET-NOT-DONE', 'INCONCLUSIVE', 14),
    @('d1-skip', @{}, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Skip = 'p0-write-missing'; Markers = 'skip' }, @{ Ph = 'r2'; Skip = 'run1-not-run'; Markers = 'skip' }), ($KR1 + $KR2B), 'SKIPPED', 'INCONCLUSIVE', 14),
    @('d1-r2-x', @{}, $SP1, @('p:1500:x'), 'RESET-DONE', 'RESET ONLY', 18),
    @('d1-done-r2-notreset', @{}, @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; Skip = 'run1-not-reset'; Markers = 'skip' }), $KR1, 'RESET-DONE', 'INCONCLUSIVE', 14),
    @('d1-inactive-r2-supervisor', @{}, @(@{ Ph = 'p0' }, @{ Ph = 'r1'; Reset = 'inactive' }, @{ Ph = 'r2'; Skip = 'run1-supervisor'; Markers = 'skip' }), $KR1, 'ALREADY-INACTIVE', 'INCONCLUSIVE', 14),
    @('d1-done-r2-pausefault', @{}, @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; Skip = 'pause-fault'; Markers = 'skip' }), $KR1, 'RESET-DONE', 'RESET ONLY', 18))
$bad = @()
foreach ($d in $dc) {
    $x = T3Run $d[0] $d[2] $true $d[3]
    $c = T3Cls $x
    if (-not ((T3Clean $x) -and $null -ne $c.Outcome -and $c.Outcome.Phases['r1'].Class -ceq $d[4] -and $c.Outcome.Outcome -ceq $d[5] -and $c.Code -eq $d[6])) { $bad += "$($d[0]): r1 $($c.Outcome.Phases['r1'].Class) outcome $($c.Outcome.Outcome) code $($c.Code) $(T3Desc $x)" }
    if ($d[0] -ceq 'd1-on-reject-r2-ran' -and $c.Outcome.Phases['r2'].Reason -notmatch 'runner inconsistency: r2 executed although r1 is not a clean reset') { $bad += "d1-on-reject-r2-ran r2 '$($c.Outcome.Phases['r2'].Reason)'" }
    if ($d[0] -ceq 'd1-shown' -and $c.Outcome.Phases['r1'].Reason -notmatch 'shown=1') { $bad += "d1-shown '$($c.Outcome.Phases['r1'].Reason)'" }
    if ($d[0] -cmatch '^d1-(done-r2-notreset|inactive-r2-supervisor)$' -and $c.Outcome.Reason -notmatch '^host/device inconsistency: the host reads r1 as (RESET-DONE|ALREADY-INACTIVE), but the device skipped r2 as if the reset were not clean') { $bad += "$($d[0]) reason '$($c.Outcome.Reason)'" }
}
Check "D1 the reset classes and outcomes ($($dc.Count) sessions): reset_done -> RESET-DONE, already_inactive -> ALREADY-INACTIVE (both PASS machine with r2), reset_off/on rejected and crtc_state_unknown -> RESET-NOT-DONE (RESET NOT DONE, exit 19, the device skipping r2), shown=1 or reset_done without its commits -> runner inconsistency, a run 2 executed after a failed reset -> runner inconsistency, a skipped reset -> INCONCLUSIVE, x at the question -> RESET ONLY (exit 18); review 2 MINOR-4: a clean reset (RESET-DONE / ALREADY-INACTIVE) and the device skipping r2 for run1-not-reset / run1-supervisor -> host/device INCONSISTENCY (INCONCLUSIVE, 14), for pause-fault still RESET ONLY; never SHOWN" ($bad.Count -eq 0) ($bad -join ' | ')
$x = T3Run 'd2-roll' @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; Roll = '0'; Eyes = 'direct' }) $true ($KR1 + $KR2B); $c = T3Cls $x
$y = T3Run 'd2-active' @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; Code = 31 }) $true ($KR1 + $KR2B + @('p:1200:0', 'p:300:0')); $cy = T3Cls $y
$z = T3Run 'd2-pause' @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2'; StartMs = 23000 }) $true ($KR1 + $KR2B); $cz = T3Cls $z
Check 'D2 r2''s start record roll=0 eyes=direct -> INCONCLUSIVE naming it (README 6.7); r2 exit 31 (CRTC active) -> PRECONDITION UNMET, exit 17; r2''s hold 1.4 s after the reset''s end (t0_ms + elapsed_ms) -> pause < 2000 ms, runner inconsistency' `
    ($c.Outcome.Phases['r2'].Class -ceq 'INCONCLUSIVE' -and $c.Outcome.Phases['r2'].Reason -match 'roll=0 eyes=direct, not roll=21 eyes=swap' -and $cy.Code -eq 17 -and $cy.Outcome.Outcome -ceq 'PRECONDITION UNMET: CRTC ACTIVE' -and
     $cz.Outcome.Outcome -ceq 'INCONCLUSIVE' -and $cz.Outcome.Phases['r2'].Reason -match 'pause between r1''s end and r2''s commit is 1400 ms') "$($c.Outcome.Phases['r2'].Reason) | $($cy.Code) | $($cz.Outcome.Phases['r2'].Reason)"
$x = T3Run 'd3-pin' @(@{ Ph = 'p0'; Pin = ('0' * 64) }) $true @(); $c = Invoke-Fs3dClassifyDir -DirX $x.Out -S1X 'PASS'
Check 'D3 integrity: p0 VALID but its digest is not the pin -> NOTHING RUNS (integrity) (red banner), r1 never sent, fs-done; the classifier with the built-in v0.7.1 pin -> INTEGRITY FAULT, exit 12' `
    ((T3Clean $x) -and $x.R.EndReason -match '^NOTHING RUNS \(integrity\)' -and -not (T3Sent $x 'r1') -and $x.R.DoneSent -and @($x.Ui.Transcript | Where-Object { $_ -match '^\[BANNER abort\] NOTHING RUNS \(integrity\)' }).Count -eq 1 -and
     $c.Code -eq 12 -and $c.Outcome.Phases['p0'].Reason -match "pin $($script:S3dPatternPin)") "$(T3Desc $x) | $($c.Lines -join ' / ')"
$lt = @(
    @('left', '12', 'UPRIGHT', 'LEVEL', 'as designed', 'as-designed', 'level'),
    @('right', '34', 'UPRIGHT', 'CLOCKWISE', 'as designed', 'as-designed', 'still turned CLOCKWISE'),
    @('left', '34', 'UPRIGHT', 'COUNTERCLOCKWISE', "OTHER eye's picture", 'swapped', 'COUNTER-CLOCKWISE'),
    @('right', '21', 'HALF_TURN', 'UNKNOWN', "other eye's picture in reverse order", 'swapped', 'could not tell'),
    @('right', '43', 'HALF_TURN', 'LEVEL', 'turned by a half-turn', 'as-designed', 'level'),
    @('left', '21', 'HALF_TURN', 'LEVEL', 'turned by a half-turn: the 180-degree mount', 'as-designed', 'level'),
    @('left', '21', 'MIRRORED', '', 'mirrored left-right', 'as-designed', 'tilt not recorded'),
    @('right', '43', 'UPRIGHT', 'LEVEL', 'two planes of this eye exchanged', 'as-designed', 'level'),
    @('left', '12', 'VFLIP', 'LEVEL', 'vertical flip', 'as-designed', 'level'),
    @('left', '10', 'UPRIGHT', 'LEVEL', 'a 0 side \(the RIGHT F: no bars where LM2''s 2 bar\(s\) belong\)', '', 'level'),
    @('right', '04', 'UPRIGHT', 'LEVEL', 'a 0 side \(the LEFT F: no bars where LM1''s 3 bar\(s\) belong\)', '', 'level'),
    @('left', '00', 'UPRIGHT', 'LEVEL', 'the LEFT F: no bars where LM3''s 1 bar\(s\) belong; the RIGHT F: no bars where LM2''s 2 bar\(s\) belong', '', 'level'),
    @('left', '13', 'UPRIGHT', 'LEVEL', 'unexpected bar pair 1 \| 3', '', 'level'))
$bad = @()
foreach ($l in $lt) { $lb = Get-Fs3dLayoutLabel -Eye $l[0] -Bars $l[1] -Orient $l[2] -Tilt $l[3]; if ($lb.Label -notmatch $l[4] -or $lb.Swap -cne $l[5] -or $lb.Roll -notmatch $l[6]) { $bad += "$($l[0]) $($l[1]) $($l[2]) $($l[3]): '$($lb.Label)' swap '$($lb.Swap)' roll '$($lb.Roll)'" } }
Check "D4 the per-eye layout labels ($($lt.Count) cases): this eye's own bars (left 1|2, right 3|4) upright = as designed; the other eye's bars = the swap is wrong; reversed bars with a half-turn / mirror / upright F; a 0 side naming the mixer expected there (review 2 MINOR-5, eyes=swap: LM0 4, LM1 3, LM2 2, LM3 1); an unexpected pair; the tilt words (level / clockwise / counter-clockwise / could not tell)" ($bad.Count -eq 0) ($bad -join ' | ')
function FsrL([string]$ph, [string]$item, [string]$obs, [string]$key = '-') { "FSR2 p=$ph item=$item key=$key obs=$obs prompt_ms=1 answer_ms=2 prompt_utc=x answer_utc=y discarded=0" }
$pe = @(
    @((FsrL 'r1' 'left' 'DARK'), 'r1 has only the item seen'), @((FsrL 'r2' 'seen' 'SEEN'), 'r1 has only the item seen'), @((FsrL 'r2' 'tilt_left' 'LEFT_LOW'), 'malformed'),
    @((FsrL 'r1' 'seen' 'SEEN'), ''), @((FsrL 'r2' 'tilt_left' 'COUNTERCLOCKWISE'), ''))
$bad = @()
foreach ($p in $pe) { $err = ''; try { $null = ConvertFrom-Fs3dReadings @($p[0]) } catch { $err = $_.Exception.Message }; if (($p[1] -and $err -notmatch $p[1]) -or (-not $p[1] -and $err)) { $bad += "$($p[0]) -> '$err'" } }
Check 'D5 the stage-3d readings grammar: r1 holds only `seen`, `seen` only r1; the tilt is LEVEL/CLOCKWISE/COUNTERCLOCKWISE/UNKNOWN (the stage-3c LEFT_LOW is malformed)' ($bad.Count -eq 0) ($bad -join ' | ')
$x = T3Run 'd6-one-eye' $SP2 $true ($KR1 + @('p:1800:d') + (T3Chars 'r2' 250) + @('p:1200:c', 'p:900:y', 'p:1200:1', 'p:300:2', 'p:900:u', 'p:900:0', 'p:1200:3', 'p:300:4')); $c = T3Cls $x
Check 'D6 run 2 read in one eye only: ONE-EYE ONLY, machine PASS but not a stage PASS (the stage needs both eyes in run 2)' ($c.Outcome.Optical['r2'].Class -ceq 'ONE-EYE ONLY' -and $c.Code -eq 10 -and $c.Outcome.Registered -match '^not a stage PASS') ($c.Lines -join ' / ')
$td = Join-Path $Scratch 'd7-partial'; Copy-Item -Recurse -LiteralPath $CAN['garbled-r3'].Out -Destination $td
$bdx = Join-Path $Scratch 'd7-cp'; $null = New-Item -ItemType Directory -Force -Path $bdx
$xB = New-Fs3dInteract -Ui (New-Fs3cUi -Kind record) -Keys (New-Fs3cScriptedKeySource -Script @()) -Sound (New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd) -OutDirX $bdx
$null = Add-Fs3cReading -X $xB -Ph 'r1' -Item 'seen' -Key 'n' -Obs 'NOT_SEEN' -PromptMs 10 -AnswerMs 20
Copy-Item -LiteralPath (Join-Path $bdx 'session.json') -Destination (Join-Path $td 'session.json') -Force
$q = Invoke-Fs3dClassifyDir -DirX $td -S1X 'PASS' -PinX $script:G3dPin
Check 'D7 every answer on disk at once in readings3d.txt with a frameshift.fs-collect3d.partial.v1 checkpoint; the classifier refuses such a checkpoint (INCONCLUSIVE, 14)' `
    (@([IO.File]::ReadAllLines((Join-Path $bdx 'readings3d.txt'))).Count -eq 1 -and (Get-Content -Raw (Join-Path $bdx 'session.json') | ConvertFrom-Json).Schema -ceq 'frameshift.fs-collect3d.partial.v1' -and $q.Code -eq 14 -and ($q.Lines -join ' ') -match 'checkpoint') ($q.Lines -join ' / ')
$q = Invoke-Fs3dClassifyDir -DirX (Join-Path $Scratch 'cli-replay') -S1X 'PASS' -PinX $script:G3dPin
$q3c = Invoke-Fs3cClassifyDir -DirX $CAN['nominal-read'].Out -S1X 'PASS' -PinX $script:G3dPin
Check 'D8 the stage-3c classifier refuses a stage-3d session (Stage 3d) and the stage-3d classifier reads it (the CLI replay of A5: exit 10)' ($q3c.Code -eq 14 -and ($q3c.Lines -join ' ') -match 'stage 3d, not 3c' -and $q.Code -eq 10) "$($q3c.Lines -join ' / ')"

# ------------------------------------------------------------------ E --------
Say '== E. the device''s fs-pattern v0.7 / v0.7.1 mock streams (stage3d/fixtures/sim) through the host parsers'
$simDir = Join-Path $T3Q3 'stage3d\fixtures\sim'
function ZStep([string]$f, [int]$runN) {
    [byte[]]$b = [IO.File]::ReadAllBytes((Join-Path $simDir $f)); $t = [System.Text.Encoding]::GetEncoding(28591).GetString($b)
    $n8 = [regex]::Match($t, '^FSP1 nonce=([0-9a-f]{8}) ').Groups[1].Value; $code = [regex]::Match($t, '(?m)step=exit rc=[-0-9]+ code=([0-9]+) ').Groups[1].Value
    [pscustomobject]@{ St = (New-SynthStep 2 "pattern$runN" $b @() @{ code = [long]$code }); N8 = $n8 }
}
$zc = @(@('reset.txt', 'RESET-DONE'), @('reset-inactive.txt', 'ALREADY-INACTIVE'), @('reset-off-reject.txt', 'RESET-NOT-DONE'), @('reset-on-reject.txt', 'RESET-NOT-DONE'), @('reset-max.txt', 'RESET-DONE'),
        @('reset-v27.txt', 'RESET-DONE'), @('reset-v27-late.txt', 'RESET-DONE'))     # J-142 MINOR: the v2.7-shaped streams (fs-pattern v0.7.1, 305 / 308 modes)
$bad = @()
foreach ($z in $zc) {
    if (-not (Test-Path -LiteralPath (Join-Path $simDir $z[0]))) { $bad += "$($z[0]) absent"; continue }
    $s = ZStep $z[0] 1; $rs = Get-Fs3dReset $s.St $s.N8; $cl = Get-Fs3dResetClass $rs
    if ($rs.Kind -cne 'run' -or $cl.Class -cne $z[1]) { $bad += "$($z[0]): kind $($rs.Kind) $($rs.Why) class $($cl.Class) $($cl.Reason)" }
}
Check "E1 the device's reset streams ($($zc.Count): reset, reset-inactive, reset-off-reject, reset-on-reject, reset-max; J-142: the v2.7-shaped reset-v27 and reset-v27-late of fs-pattern v0.7.1) parse as COMPLETE FSP1 runs and classify as RESET-DONE / ALREADY-INACTIVE / RESET-NOT-DONE" ($bad.Count -eq 0) ($bad -join ' | ')
$bad = @()
foreach ($z in @(@('quad-vig.txt', '21', 'swap'), @('quad-vig-roll0-direct.txt', '0', 'direct'), @('quad-v27.txt', '21', 'swap'), @('quad-v27-late.txt', '21', 'swap'))) {
    if (-not (Test-Path -LiteralPath (Join-Path $simDir $z[0]))) { $bad += "$($z[0]) absent"; continue }
    $s = ZStep $z[0] 2; $rn = Get-Fs3cRun $s.St 2 $s.N8; $sr = @(@($rn.Recs) | Where-Object { $_.Step -ceq 'start' })[0]
    if ($rn.Kind -cne 'run' -or [string]$sr.Kv['roll'] -cne $z[1] -or [string]$sr.Kv['eyes'] -cne $z[2] -or -not (Test-Fs3cQuadPost $rn).Ok) { $bad += "$($z[0]): roll $($sr.Kv['roll']) eyes $($sr.Kv['eyes']) $((Test-Fs3cQuadPost $rn).Why)" }
}
$fp = [IO.File]::ReadAllText((Join-Path $T3Q3 'stage3d\fs-phase.sh'))
Check 'E2 the v0.7 / v0.7.1 quad streams carry roll/eyes in the start record (quad-vig, J-142: quad-v27 and quad-v27-late: 21/swap; roll0-direct: 0/direct) and their post_plane matches the stage-3c quad check; stage3d/fs-phase.sh prints exp=s3d_<ph>, the FSPM1/FSXE1 grammar, ROLL=21 EYES=swap and gate_reset''s reasons' `
    ($bad.Count -eq 0 -and $fp.Contains('"s3d_$PH"') -and $fp.Contains("printf 'FSPM1 n=%s p=%s e=%s t=%s END\n'") -and $fp.Contains("printf 'FSXE1 p=%s ran=%s error=%s END\n'") -and $fp -cmatch '(?m)^ROLL=21$' -and $fp -cmatch '(?m)^EYES=swap$' -and
     $fp.Contains('why=run1-not-reset')) ($bad -join ' | ')
# J-142 MINOR: what eos opt_skipped counts (HOST.md section 2, item 12). Two kinds: (1) v0.7.1 mode records left out BY
# DESIGN (modes at index 48 and above that are not the expected 4128x2208@90 mode: not logged, counted); (2) optional
# records DROPPED BY THE BUDGET (FSP_OPT_MAX), which only happens after one step=opt_budget record. So on the v2.7 streams
# opt_skipped = modes - mode records and there is no opt_budget record; on the -max streams every mode is logged, there is
# exactly one opt_budget record and opt_skipped counts the dropped records.
$bad = @(); $osk = @()
foreach ($z in @(@('reset-v27.txt', 'design', 257), @('reset-v27-late.txt', 'design', 258), @('quad-v27.txt', 'design', 257), @('quad-v27-late.txt', 'design', 258), @('solid-v27.txt', 'design', 257), @('reset-max.txt', 'budget', 56), @('quad-max.txt', 'budget', 52), @('quad-vig.txt', 'none', 0))) {
    $t = [IO.File]::ReadAllText((Join-Path $simDir $z[0]))
    $sk = [int][regex]::Match($t, '(?m)step=eos .*\bopt_skipped=([0-9]+) ').Groups[1].Value; $nb = [regex]::Matches($t, '(?m) step=opt_budget ').Count
    $nm = [regex]::Matches($t, '(?m) step=mode ').Count; $cm = [int][regex]::Match($t, '(?m) step=chosen_connector .*?\bmodes=([0-9]+) ').Groups[1].Value
    $osk += "$($z[0]): modes $cm, mode records $nm, opt_budget $nb, opt_skipped $sk"
    $ok = switch ($z[1]) { 'design' { $nb -eq 0 -and $sk -eq ($cm - $nm) -and $nm -ge 48 } 'budget' { $nb -eq 1 -and $nm -eq $cm -and $sk -gt 0 } default { $nb -eq 0 -and $sk -eq 0 } }
    if (-not $ok -or $sk -ne $z[2]) { $bad += $osk[-1] }
}
foreach ($l in $osk) { Say "      $l" }
Check 'E3 J-142 MINOR, the meaning of opt_skipped: on the v2.7-shaped streams it counts the mode records left out by design (opt_skipped = modes - mode records: 305 - 48 = 257, 308 - 50 = 258; no opt_budget record); on the -max streams every mode is logged and it counts the optional records dropped after the one opt_budget record (budget); 0 when neither happens' ($bad.Count -eq 0) ($bad -join ' | ')

# ------------------------------------------------------------------ F --------
# END TO END: every device whole-image capture (stage3d/fixtures/image, the candidate's own /init under qemu/bwrap) through
# fs-collect3d replay and fs-classify3d (stage 1 given as PASS). The sim-* scenarios replace /bin/fs-pattern: they run with
# the replacement's digest as the pin (and with the built-in pin, p0 is an INTEGRITY FAULT). Deviating scenarios (the harness
# played a faulty host) diverge exactly where the harness deviated.
Say '== F. end to end: the stage-3d whole-image captures through fs-collect3d replay + fs-classify3d'
$E2Dir = Join-Path $T3Q3 'stage3d\fixtures\image'
$E2Ov = @{ Kernel = '6.18.33.2-microsoft-standard-WSL2'; Pid1 = '/usr/bin/qemu-aarch64,/bin/busybox,/bin/busybox,sh,/init' }
$EK2G = @('p:1800:c', 'p:900:c', 'p:800:y'); $EK2D = @('p:1800:b', 'p:900:b', 'p:800:y'); $EK3 = @('p:2000:r', 'p:900:r', 'p:800:y')
$EK2SK = @('p:1800:b', 'p:900:b', 'p:800:y')
$EPass = @{ p0 = 'P0 OK'; r1 = 'RESET-DONE'; r2 = 'R2 SHOWN-QUAD'; r3 = 'R3 SHOWN-QUAD-SOLID' }
$E2 = [ordered]@{
    'c-sim-all'          = @{ Keys = $KR1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Interp = 'T1' }
    'c-markers'          = @{ Keys = $KR1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Interp = 'T1'; Markers = $true }
    'c-no-debugfs'       = @{ Keys = $KR1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Interp = 'T1' }
    'c-sim-r3-hold'      = @{ Keys = $KR1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Interp = 'T1' }
    'c-sim-r2-dma'       = @{ Keys = $KR1 + $EK2G + $EK3; Sent = 'p0,r1,r2,r3,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = $EPass; Interp = '-' }
    'c-pause'            = @{ Keys = $KR1 + $EK2D; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 10; Outcome = 'PASS (machine side)'; Phases = @{ p0 = 'P0 OK'; r1 = 'RESET-DONE'; r2 = 'R2 SHOWN-QUAD'; r3 = 'NOT RUN' } }
    'c-sim-r2-reject'    = @{ Keys = $KR1 + $EK2SK; Sent = 'p0,r1,r2,fs-done'; Div = "^collector wrote 'fs-done'; recorded write was 'fs-phase r3 "; Code = 15; Outcome = 'NO-DISPLAY'; Phases = @{ p0 = 'P0 OK'; r1 = 'RESET-DONE'; r2 = 'NO-DISPLAY'; r3 = 'NOT RUN' } }
    'c-sim-active'       = @{ Keys = $KR1 + $EK2SK; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 17; Outcome = 'PRECONDITION UNMET: CRTC ACTIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'RESET-DONE'; r2 = 'PRECONDITION UNMET: CRTC ACTIVE' } }
    'c-sim-reset-fail'   = @{ Keys = $KR1 + $EK2SK; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 19; Outcome = 'RESET NOT DONE'; Phases = @{ p0 = 'P0 OK'; r1 = 'RESET-NOT-DONE'; r2 = 'SKIPPED' }; Why = @{ r1 = 'reset_on_rejected'; r2 = 'run1-supervisor' } }
    'c-pause-fault'      = @{ Keys = $KR1 + $EK2SK; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 18; Outcome = 'RESET ONLY'; Phases = @{ p0 = 'P0 OK'; r1 = 'RESET-DONE'; r2 = 'SKIPPED' }; Why = @{ r2 = 'pause-fault' } }
    'c-nodrm'            = @{ Keys = $KR1 + $EK2SK; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 19; Outcome = 'RESET NOT DONE'; Phases = @{ p0 = 'P0 OK'; r1 = 'RESET-NOT-DONE'; r2 = 'SKIPPED' }; Why = @{ r1 = 'no device'; r2 = 'run1-supervisor' } }
    'c-probe-hang'       = @{ Keys = $KR1 + $EK2SK; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'SKIPPED'; r2 = 'SKIPPED' }; Why = @{ r1 = 'probe-late'; r2 = 'run1-not-run' } }
    'c-no-backlight'     = @{ Keys = $KR1 + $EK2SK; Sent = 'p0,r1,r2,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'BRIGHTNESS NOT VERIFIED'; r1 = 'SKIPPED'; r2 = 'SKIPPED' }; Why = @{ r1 = 'p0-write-missing'; r2 = 'run1-not-run' } }
    'c-record-too-large' = @{ Keys = $KR1; Sent = 'p0,r1,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'REFUSED'; r2 = 'NOT RUN' }; Why = @{ r1 = 'ran=1 error=record-too-large' }; Readings = 'r1' }
    'c-step-fail'        = @{ Keys = $KR1; Sent = 'p0,r1,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'REFUSED'; r2 = 'NOT RUN' }; Why = @{ r1 = 'ran=1 error=step1' }; Readings = 'r1' }
    'c-time'             = @{ Keys = @(); Sent = 'p0,fs-done'; Div = ''; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'REFUSED'; r1 = 'NOT RUN' }; Why = @{ p0 = 'ran=0 error=time' }; Readings = '' }
    'c-idle'             = @{ Keys = $KR1; Sent = 'p0,r1,r2'; Div = "^collector wrote 'fs-phase r2 [0-9a-f]{32} [0-9a-f]{16}'; recorded write was '\(none"; Code = 19; Outcome = 'RESET NOT DONE'; Phases = @{ p0 = 'P0 OK'; r1 = 'RESET-NOT-DONE'; r2 = 'INCONCLUSIVE' }; NoDone = $true }
    'c-idle-stuck'       = @{ Keys = @(); Sent = 'p0,r1'; Div = "^collector wrote 'fs-phase r1 [0-9a-f]{32} [0-9a-f]{16}'; recorded write was '\(none"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'INCONCLUSIVE' }; NoDone = $true }
    'c-order'            = @{ Keys = @(); Sent = 'p0,r1'; Div = "^collector wrote 'fs-phase r1 [0-9a-f]{32} [0-9a-f]{16}'; recorded write was 'fs-phase r2 "; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'INCONCLUSIVE' }; NoDone = $true }
    'c-usage-then-p0'    = @{ Keys = @(); Sent = 'p0'; Div = "^collector wrote 'fs-phase p0 [0-9a-f]{32} 0{16}'; recorded write was 'fs-phase p0 nothex 0{16}'"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'INCONCLUSIVE' }; NoDone = $true }
    'c-repeat'           = @{ Keys = @(); Sent = 'p0,r1'; Div = "^collector wrote 'fs-phase r1 [0-9a-f]{32} [0-9a-f]{16}'; recorded write was 'fs-phase p0 "; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'INCONCLUSIVE' }; NoDone = $true }
    'c-chain-bad'        = @{ Keys = @(); Sent = 'p0,r1'; Div = "^collector wrote 'fs-phase r1 [0-9a-f]{32} (?!f{16})[0-9a-f]{16}'; recorded write was 'fs-phase r1 [0-9a-f]{32} f{16}'"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'P0 OK'; r1 = 'INCONCLUSIVE' }; NoDone = $true }
    'c-done-early'       = @{ Keys = @(); Sent = 'fs-verify,fs-ack'; Div = "^collector wrote 'fs-ack [0-9a-f]{16}'; recorded write was 'fs-done'"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'NOT RUN' }; NoDone = $true; Pre = $true }
    'c-modules-real'     = @{ Keys = @(); Sent = 'fs-verify,fs-ack'; Div = "^collector wrote 'fs-ack [0-9a-f]{16}'; recorded write was 'fs-done'"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'NOT RUN' }; NoDone = $true; Pre = $true }
    'c-no-ack'           = @{ Keys = @(); Sent = 'fs-verify,fs-ack'; Div = "^collector wrote 'fs-ack [0-9a-f]{16}'; recorded write was '\(none"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'NOT RUN' }; NoDone = $true; Pre = $true }
    'c-ack-no-done'      = @{ Keys = @(); Sent = 'p0'; Div = "^collector wrote 'fs-phase p0 [0-9a-f]{32} 0{16}'; recorded write was '\(none"; Code = 14; Outcome = 'INCONCLUSIVE'; Phases = @{ p0 = 'INCONCLUSIVE' }; NoDone = $true }
    'c-modules-refused'  = @{ Empty = $true }
}
function E2P0Digest([string]$src) {
    [byte[]]$b = [IO.File]::ReadAllBytes($src); if ($b.Length -eq 0) { return '' }
    $ix0 = Read-FsCaptureIndex -Path "$src.idx" -RawLength $b.Length
    $s0 = @((Get-Fs3cSlices -Raw $b -Events (Read-Fs3cIndexEvents -Path "$src.idx" -RawLength $b.Length)) | Where-Object { $_.Ph -ceq 'p0' })
    if ($s0.Count -lt 1) { return '' }
    $d0 = Test-Fsb1Record -Bytes $s0[0].Bytes -Exp 's3d_p0' -Nonce $ix0.Nonce -Challenge $s0[0].Chal -Steps $script:S3dSteps['p0']
    if (-not $d0.Ok) { return '' }
    $m0 = [regex]::Match($script:S2L1.GetString([byte[]]@($d0.Steps)[0]['out']), '^([0-9a-f]{64})  /bin/fs-pattern\n\z'); if ($m0.Success) { $m0.Groups[1].Value } else { '' }
}
$E2Have = @(Get-ChildItem -LiteralPath $E2Dir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'capture.raw') } | ForEach-Object { $_.Name })
$E2Res = New-Object System.Collections.Generic.List[string]
if ($E2Have.Count -eq 0) { Skip 'F end to end' 'stage3d/fixtures/image not present' }
else {
    Check "F0 every stage-3d whole-image scenario has an end-to-end expectation here and vice versa ($($E2Have.Count) captures)" ((@($E2Have | Sort-Object) -join ',') -ceq (@($E2.Keys | Sort-Object) -join ',')) "captures: $($E2Have -join ',')"
    $real = 0; $repl = 0
    foreach ($sn in $E2.Keys) {
        $e = $E2[$sn]; $src = Join-Path $E2Dir "$sn\capture.raw"
        if ($e.ContainsKey('Empty')) {
            $rt = [IO.File]::ReadAllText((Join-Path $E2Dir "$sn\result.txt"))
            $err = ''; try { $null = Invoke-Fs3dReplay -RawPath $src -OutDirX (Join-Path $Scratch "e2e-$sn") } catch { $err = $_.Exception.Message }
            Check "F ${sn}: the module index refusal has no shell (an empty capture: no gadget, nothing for the collector); the device reboots error-modules at about T0 + 60 s (README 6.11; the observer's no-gadget note, G7); a replay of it is refused" `
                ((Get-Item $src).Length -eq 0 -and $rt -match 'first reboot reason = error-modules' -and $rt -match 'T0\+6[0-4]' -and $err) "$err"
            continue
        }
        $script:T3N++
        $od = Join-Path $Scratch ("{0:D3}-e2e-{1}" -f $script:T3N, $sn)
        $dg = E2P0Digest $src
        $ovE = @{} + $E2Ov; if ($dg) { $ovE['PatternPin'] = $dg }
        if ($dg -ceq $script:S3dPatternPin) { $real++ } elseif ($dg) { $repl++ }
        $ui = New-Fs3cUi -Kind record; $ks = New-Fs3cScriptedKeySource -Script $e.Keys; $sink = New-Fs3cSoundSink -Kind record -Sounds $script:T3Snd
        $r = Invoke-Fs3dReplay -RawPath $src -OutDirX $od -Overrides $ovE -Ui $ui -Keys $ks -Sound $sink -Sounds $script:T3Snd
        $sent = (@($r.Sent | ForEach-Object { $w = $_ -split ' '; if ($w[0] -ceq 'fs-phase') { $w[1] } elseif (@('fs-verify', 'fs-ack', 'fs-status') -ccontains $w[0]) { if ($e.ContainsKey('Pre')) { $w[0] } else { $null } } else { $w[0] } } | Where-Object { $_ }) -join ',')
        $div = @($r.Replay.Divergence)
        $divOk = if ($e.Div) { $div.Count -ge 1 -and $div[0] -cmatch $e.Div } else { $div.Count -eq 0 -and @($r.Replay.UnperformedWrites).Count -eq 0 -and @($r.Replay.PrevCheck | Where-Object { -not $_.Same }).Count -eq 0 }
        $c = Invoke-Fs3dClassifyDir -DirX $od -S1X 'PASS' -PinX $(if ($dg) { $dg } else { $script:S3dPatternPin })
        $o = $c.Outcome
        $phOk = $true; $phDesc = @()
        foreach ($k in $e.Phases.Keys) { if ($null -eq $o -or $o.Phases[$k].Class -cne $e.Phases[$k]) { $phOk = $false }; $phDesc += "$k=$(if ($o) { $o.Phases[$k].Class } else { '?' })" }
        if ($e.ContainsKey('Why')) { foreach ($k in $e.Why.Keys) { if ($null -eq $o -or $o.Phases[$k].Reason -notmatch [regex]::Escape($e.Why[$k])) { $phOk = $false; $phDesc += "$k why '$($o.Phases[$k].Reason)'" } } }
        $extra = $true; $xd = @()
        if ($e.ContainsKey('Interp')) { if ($null -eq $o.Interpretation -or $o.Interpretation.Code -cne $e.Interp) { $extra = $false; $xd += "interp $(if ($o.Interpretation) { $o.Interpretation.Code })" } }
        if ($e.Phases['r2'] -ceq 'R2 SHOWN-QUAD') { $pn = @($o.Phases['r2'].Notes) -join ';'; if ($pn -notmatch 'pause ([0-9]+) ms' -or [long]$Matches[1] -lt 2000 -or $o.Phases['r2'].Reason -notmatch 'roll=21 eyes=swap') { $extra = $false; $xd += "r2 '$pn' '$($o.Phases['r2'].Reason)'" } }
        if ($e.ContainsKey('Readings')) { $rp0 = (@($r.ReadingObjs | ForEach-Object { $_.Ph } | Sort-Object -Unique) -join ','); if ($rp0 -cne $e.Readings) { $extra = $false; $xd += "readings for '$rp0'" } }
        if ($e.ContainsKey('Markers')) { foreach ($k in 'p0', 'r1', 'r2', 'r3') { $pp = @($r.Phases | Where-Object { $_.Ph -ceq $k })[0]; $want = if ($k -ceq 'p0') { 'begin,rec' } else { 'begin,go,end,rec' }; if ((@($pp.Markers | ForEach-Object { ($_ -split '@')[0] }) -join ',') -cne $want -or @($pp.MarkerNotes).Count) { $extra = $false; $xd += "$k markers" } } }
        if ($e.ContainsKey('NoDone')) { if ($r.DoneSent) { $extra = $false; $xd += 'fs-done sent' } } elseif (-not $r.DoneSent) { $extra = $false; $xd += 'no fs-done' }
        if ($o -and $o.Phases['r1'].Class -match 'SHOWN') { $extra = $false; $xd += 'r1 SHOWN' }
        $ok = ($sent -ceq $e.Sent -and $divOk -and $r.Replay.RecaptureIsSourcePrefix -and $null -ne $o -and $c.Code -eq $e.Code -and $o.Outcome -ceq $e.Outcome -and $phOk -and $extra)
        Check ("F {0}: collector sent {1}; {2}; classified -> {3} (exit {4}); {5}" -f $sn, $e.Sent, $(if ($e.Div) { 'the replay diverges exactly where the harness host deviated' } else { 'no divergence' }), $e.Outcome, $e.Code, (($e.Phases.Keys | Sort-Object | ForEach-Object { "$_ $($e.Phases[$_])" }) -join ', ')) $ok `
            "sent=$sent div=$($div -join ' ; ') prefix=$($r.Replay.RecaptureIsSourcePrefix) code=$($c.Code) outcome=$(if ($o) { $o.Outcome }) $($phDesc -join ' ') $($xd -join ' ')"
        $E2Res.Add(("{0,-19} exit {1,-3} {2,-32} {3}" -f $sn, $c.Code, $(if ($o) { $o.Outcome } else { '-' }), ((@('p0', 'r1', 'r2', 'r3') | ForEach-Object { if ($o) { "$_=$($o.Phases[$_].Class)" } }) -join ' | ')))
    }
    # the sim captures with the built-in pin: p0 is an INTEGRITY FAULT naming the replacement's digest, and the collector stops
    $src = Join-Path $E2Dir 'c-sim-all\capture.raw'
    $od = Join-Path $Scratch 'e2e-integrity'
    $r = Invoke-Fs3dReplay -RawPath $src -OutDirX $od -Overrides $E2Ov -Keys (New-Fs3cScriptedKeySource -Script @())
    $c = Invoke-Fs3dClassifyDir -DirX $od -S1X 'PASS'
    Check "F1 c-sim-all with the built-in v0.7.1 pin: the collector stops after p0 (NOTHING RUNS (integrity)), fs-done, r1 never sent; INTEGRITY FAULT (exit 12); the genuine scenarios ($real) measured exactly the v0.7.1 pin bfafad97...9a9a, the sim ones ($repl) the replacement" `
        ($r.EndReason -match '^NOTHING RUNS \(integrity\)' -and $r.DoneSent -and @($r.Sent | Where-Object { $_ -like 'fs-phase r1 *' }).Count -eq 0 -and $c.Code -eq 12 -and $real -ge 8 -and $repl -ge 10) "$($r.EndReason) code $($c.Code) real $real repl $repl"
    foreach ($l in $E2Res) { Say "      e2e  $l" }
}

# ------------------------------------------------------------------ fixtures of the checklist (G, H) --------
# A fake repository root for fs-checklist3d: one pinned fake host file, the three previews, and (J-143) the
# session/collector tool-set files (fake bytes; a test changes one to force new rehearsals).
function New-Cl3dRoot {
    $root = Join-Path $Scratch ("cl3droot-" + (New-FsHex 3)); $hd = Join-Path $root 'devices\quest3\host'
    $null = New-Item -ItemType Directory -Force -Path $hd
    foreach ($f in 'fake-a.ps1') { [IO.File]::WriteAllText((Join-Path $hd $f), "# fixture $f`n") }
    $pd = Join-Path $root $script:FsCl3dPreviewDir; $null = New-Item -ItemType Directory -Force -Path $pd
    foreach ($f in $script:FsCl3dPreviewFiles) { [IO.File]::WriteAllBytes((Join-Path $pd $f), [byte[]](1, 2, 3)) }
    foreach ($f in $script:FsCl3dToolSetFiles) { $tp = Join-Path $root $f; $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tp); [IO.File]::WriteAllText($tp, "# fixture $f`n") }
    [IO.File]::WriteAllText((Join-Path $root 'SIGNOFF-3d.md'), "# fixture`n<!-- host pins (fixture) -->`n| file | SHA-256 | kind |`n|---|---|---|`n| ``devices\quest3\host\fake-a.ps1`` | ``$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $hd 'fake-a.ps1')).Hash.ToLower())`` | fixture |`n<!-- end host pins -->`n")
    $root
}
$CLR = New-Cl3dRoot
$script:T3Day = { param([DateTime]$u) $u.ToUniversalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }   # the fixtures' "PC local date": UTC
# A cycle's own sound check and rehearsals (fresh files): soundcheck.json ending at $scEnd, both rehearsal summaries
# J-143 review MAJOR-1: each pass carries its made record (the time $scEnd and the tool set of $root, or $ts)
function New-Cl3dSoundJson([string]$path, [DateTime]$made, [string]$ts) {
    [IO.File]::WriteAllText($path, "{`"Schema`": `"frameshift.fs-soundcheck3d.v1`", `"Pass`": true, `"EndUtc`": `"$(Format-FsCl3dUtc $made)`", `"MadeUtc`": `"$(Format-FsCl3dUtc $made)`", `"ToolSetSha256`": `"$ts`"}`n")
}
function New-Cl3dCycleFiles([string]$cyc, [DateTime]$scEnd, [string]$root = $CLR, [string]$ts = '') {
    $null = New-Item -ItemType Directory -Force -Path $cyc
    if (-not $ts) { $ts = (Get-FsCl3dToolSet $root).Sha256 }
    [IO.File]::WriteAllText((Join-Path $cyc 'host-hashes.txt'), "`r`nHash Path`r`n---- ----`r`n$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'devices\quest3\host\fake-a.ps1')).Hash) $(Join-Path $root 'devices\quest3\host\fake-a.ps1')`r`n")
    New-Cl3dSoundJson (Join-Path $cyc 'soundcheck.json') $scEnd $ts
    $d1 = Join-Path $cyc 'rehearsal'; $null = New-Item -ItemType Directory -Force -Path $d1; $null = Save-Fs3dSummary $CAN['garbled-r3'].R $d1 $true (New-Cl3dMade $scEnd $ts $root 'rehearsal')
    $d2 = Join-Path $cyc 'rehearsal-read'; $null = New-Item -ItemType Directory -Force -Path $d2; $null = Save-Fs3dSummary $CAN['nominal-read'].R $d2 $true (New-Cl3dMade $scEnd $ts $root 'rehearsal-read')
}
# the made record of a rehearsal: time, tool set, and (delta review MINOR-1) the replay of that kind in $root (or $kindR's)
function New-Cl3dMade([DateTime]$made, [string]$ts, [string]$root, [string]$kindR) {
    $rp = Join-Path $root $script:FsCarry3dReplays[$kindR]; @{ Utc = $made; ToolSet = $ts; Replay = $rp; ReplaySha = (Get-FsCl3dSha $rp) }
}
# Phase A of fs-checklist3d (the real code) on the fake root at $atUtc; every question answered $ans (recorded in $script:clAsked)
function Invoke-Cl3dA([string]$cyc, [string]$nonceX, [DateTime]$atUtc, [string]$sd, [hashtable]$more = @{}, [string]$ans = 'y', [string]$root = $CLR) {
    $null = New-Item -ItemType Directory -Force -Path $cyc
    $script:clAsked = New-Object System.Collections.Generic.List[string]; $script:clSaid = New-Object System.Collections.Generic.List[string]
    $pfn = [scriptblock]::Create("param([string]`$i) [pscustomobject]@{ Ok = `$true; Why = 'exit 0; preflight OK: fixture'; Nonce = '$nonceX'; ImageSha = ('ab' * 32) }")
    $o = @{ Root = $root; SignoffFile = (Join-Path $root 'SIGNOFF-3d.md'); Image = 'C:\fixture\boot-stage3d.img'; Preflight = $pfn; TimeoutSec = 30; StandingDir = $sd; LocalDate = $script:T3Day }
    foreach ($k in $more.Keys) { $o[$k] = $more[$k] }
    $script:clA = $atUtc; $script:clAns = $ans
    Invoke-FsCl3dPhase -Phase A -Cycle $cyc -Opt $o -Ask { param([string]$t, [int]$to) $script:clAsked.Add($t); $script:clAns } -NowUtc { $script:clA } -Say { param([string]$l) $script:clSaid.Add($l) }
}

# ------------------------------------------------------------------ G --------
Say '== G. fs-observe3d.ps1'
$fq = Join-Path $Scratch 'fakeq3'; $null = New-Item -ItemType Directory -Force -Path (Join-Path $fq 'stage3d')
foreach ($f in 'init.sh', 'fs-phase.sh', 'fs-probe.sh', 'fs-idle.sh') { [IO.File]::WriteAllText((Join-Path $fq "stage3d\$f"), "# fixture $f`n") }
$script:clPinReal = Get-FsCl3dSha $script:FsCl3dSelf
[IO.File]::WriteAllText((Join-Path $fq 'SIGNOFF-3d.md'), "# fixture`n<!-- host pins (fixture) -->`n| file | SHA-256 | kind |`n|---|---|---|`n| ``devices\quest3\host\fs-checklist3d.ps1`` | ``$($script:clPinReal)`` | fixture |`n<!-- end host pins -->`n")
function New-ObsBuild3d([string]$nonceX, [hashtable]$mut = @{}) {
    $base = Join-Path $Scratch ("obs3d-" + (New-FsHex 3)); $bd = Join-Path $base "build\stage3d\20261013T090000Z-$nonceX"
    $null = New-Item -ItemType Directory -Force -Path $bd
    $img = Join-Path $bd 'boot-stage3d.img'; [IO.File]::WriteAllBytes($img, [byte[]](1..64 | ForEach-Object { [byte]$_ }))
    $h = { param($f) (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $fq $f)).Hash.ToLower() }
    $v = @{ boot = 'e32f98c74bcce5c25b098393f7804e19fbba2f0c2034c49a4fcf6aa9a8cdc024'; vboot = 'bc0dd14de41834a601513123b2225a677fa4212dfa4505bf964228cea40d2f5b'; vbmeta = 'aae4af3a1740d568a1bcd1104f1b30b2998082def674e00c319acfab10faf215'
            vbsys = '28f5ccc91f25665dda5db1abf1fc3bd3fcea58f30cb33827642cddf6f9c8bc50'; digest = '66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a'; pin = $script:S3dPatternPin; title = 'stage-3d image'; over = '' }
    foreach ($k in $mut.Keys) { $v[$k] = $mut[$k] }
    $m = "FrameShift Quest 3 $($v.title) (v2.7 interactive per-phase display run, fs-pattern v0.7.1) - ONE ATTEMPT ONLY`nbuilt:            20261013T090000Z`nnonce:            $nonceX   (USB serial FS-$nonceX)`n" +
         "OUTPUT IMAGE:     boot-stage3d.img  size=64  sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $img).Hash.ToLower())`n`n" +
         "stock boot        $($v.boot)  x`nstock vendor_boot $($v.vboot)  x`nvbmeta            $($v.vbmeta)  x`nvbmeta_system     $($v.vbsys)  x`nvbmeta digest     $($v.digest)  (computed)`n" +
         "init.sh source    $(& $h 'stage3d\init.sh')  (recorded)`nfs-phase.sh       $(& $h 'stage3d\fs-phase.sh')  (recorded)`nfs-probe.sh       $(& $h 'stage3d\fs-probe.sh')  (recorded)`nfs-idle.sh        $(& $h 'stage3d\fs-idle.sh')  (recorded)`n" +
         "`n## ramdisk files`n$($v.pin)  686392  /bin/fs-pattern  x`n" + $v.over
    [IO.File]::WriteAllText((Join-Path $bd 'MANIFEST.txt'), $m, (New-Object System.Text.UTF8Encoding($false)))
    [pscustomobject]@{ Img = $img; Root = (Join-Path $base 'build\stage3d'); Dir = $bd; Base = $base; ImgSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $img).Hash.ToLower() }
}
$script:T3Bat = "Current Battery Service state:`n  AC powered: false`n  status: 3`n  level: 80`n  temperature: 300"
# a BA/BF SUMMARY as fs-capture.ps1 writes it: BA10 (dumpsys battery), and the must-be rows (review 2 MINOR-1) BA04 _a, BA16 the
# v2.7 vbmeta digest, BA20 user, BA23 the serial, BF02 current-slot a (on stderr after "# stderr"); $vals overrides a value
function New-Summary3d([string]$dir, [string]$phase, [string]$nonceX, [string]$utc, [string]$ser, [hashtable]$vals = @{}) {
    $null = New-Item -ItemType Directory -Force -Path $dir; $p = Join-Path $dir 'SUMMARY.txt'; $rows = @("${phase}01`t0`t1`tab`tf")
    $row = { param([string]$id, [string]$text, [string]$ex = '0') $fp = Join-Path $dir "$id.txt"; @($text -split "`n") | Out-File -FilePath $fp -Encoding ascii; [byte[]]$bb = [IO.File]::ReadAllBytes($fp); "$id`t$ex`t$($bb.Length)`t$(Get-FsSha256Hex $bb)`t$fp" }
    $v = @{ BA04 = '_a'; BA16 = '66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a'; BA20 = 'user'; BA23 = $ser; BF02 = "# stderr`ncurrent-slot: a`nFinished. Total time: 0.001s"; Exit = @{} }
    foreach ($k in $vals.Keys) { $v[$k] = $vals[$k] }
    if ($phase -ceq 'BA') {
        $bp = Join-Path $dir 'BA10.txt'; @($script:T3Bat -split "`n") | Out-File -FilePath $bp -Encoding ascii; [byte[]]$bb = [IO.File]::ReadAllBytes($bp); $rows += "BA10`t0`t$($bb.Length)`t$(Get-FsSha256Hex $bb)`t$bp"
        foreach ($id in 'BA04', 'BA16', 'BA20', 'BA23') { if ($null -ne $v[$id]) { $rows += & $row $id $v[$id] $(if ($v.Exit.ContainsKey($id)) { $v.Exit[$id] } else { '0' }) } }
    }
    if ($phase -ceq 'BF' -and $null -ne $v['BF02']) { $rows += & $row 'BF02' $v['BF02'] $(if ($v.Exit.ContainsKey('BF02')) { $v.Exit['BF02'] } else { '0' }) }
    [IO.File]::WriteAllLines($p, [string[]](@("# fs-capture.ps1 phase $phase nonce $nonceX serial $ser  $utc", '# adb x  fastboot y  commands z', "# id`texit`tbytes`tsha256`tfile") + $rows + @("PHASE $phase OK: rows captured in $dir"))); $p
}
function Invoke-Obs3d($b, [string]$nonceX, [string]$ba, [string]$bf, [DateTime]$clock, [bool]$pre = $false, [string]$clf = '', [string]$ser = $U2, [string]$attached = $U2, [bool]$gadget = $true, [bool]$backInFb = $true, [string]$revSha = '', [string]$revDir = $script:FsNoReviewedDir) {
    $script:fk3 = [pscustomobject]@{ Calls = (New-Object System.Collections.Generic.List[string]); Clock = $clock; Lines = (New-Object System.Collections.Generic.List[string]); Attached = $attached; Booted = $false; Back = $backInFb }
    Invoke-FsObserve -ImagePath $b.Img -Serial $ser -ConfirmNonce $nonceX -Preflight $pre -BuildRoot $b.Root -Q3 $fq -GadgetWaitSec 10 -BaSummary $ba -BfSummary $bf -ChecklistFile $clf -ReviewedSha $(if ($revSha) { $revSha } else { $b.ImgSha }) -ReviewedDir $(if ($revSha) { $revDir } else { Split-Path -Leaf $b.Dir }) `
        -Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) $f = $script:fk3; $f.Calls.Add(($ArgList -join ' ')); $f.Clock = $f.Clock.AddMilliseconds(300)
            if ($ArgList[0] -ceq 'devices') { $o0 = if (-not $f.Booted -or $f.Back) { "$($f.Attached)`tfastboot`r`n" } else { '' }; return [pscustomobject]@{ ExitCode = 0; StdOut = $o0; StdErr = ''; TimedOut = $false; Error = $null } }
            $f.Booted = $true; $f.Clock = $f.Clock.AddSeconds(11); [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = "Booting OKAY`n"; TimedOut = $false; Error = $null } } `
        -Gadget $(if ($gadget) { { param([string]$N0) [pscustomobject]@{ Present = $true; SerialOk = $true; Serials = @("FS-$N0"); ComPort = 'COM9'; Parent = 'x' } } } else { { param([string]$N0) [pscustomobject]@{ Present = $false; SerialOk = $false; Serials = @(); ComPort = $null; Parent = $null } } }) `
        -LocalDate $script:T3Day -NowUtc { $script:fk3.Clock } -Sleep { param([int]$Ms) $script:fk3.Clock = $script:fk3.Clock.AddMilliseconds($Ms) } -Say { param([string]$Line) $script:fk3.Lines.Add($Line) }
}
# a complete checklist3d whose presence ends at $endUtc; the reading on $ser. Phase A is the real checklist's (J-143: a full
# acceptance recorded in this cycle's own standing directory, the cycle's own sound check and rehearsals); B and E by the tool.
function New-Cl3dValid([string]$cyc, [string]$nonceX, [DateTime]$endUtc, [string]$ser, [string]$r1 = '300', [string]$st = '5') {
    New-Cl3dCycleFiles $cyc $endUtc.AddSeconds(-1800)
    $ra = Invoke-Cl3dA $cyc $nonceX $endUtc.AddSeconds(-1700) (Join-Path $cyc 'standing')
    $rb = Invoke-FsCl3dPhase -Phase B -Cycle $cyc -Opt @{ LocalDate = $script:T3Day; R1 = $r1; R1Utc = (Format-FsCl3dUtc $endUtc.AddSeconds(-800)); R1Status = $st; R1Serial = $ser } -Ask { 'y' } -NowUtc { $endUtc.AddSeconds(-790) }.GetNewClosure() -Say { param($l) }
    $re = Invoke-FsCl3dPhase -Phase E -Cycle $cyc -Opt @{ LocalDate = $script:T3Day } -Ask { param($t, $to) 'y' } -NowUtc { $endUtc.AddSeconds(-6) }.GetNewClosure() -Say { param($l) }
    if ($ra.Exit -ne 0 -or $rb.Exit -ne 0 -or $re.Exit -ne 0) { throw "fixture checklist not built: $($ra.Why) / $($rb.Why) / $($re.Why)" }
    $cyc
}
$TX = [DateTime]::Parse('2026-10-13T09:00:00Z').ToUniversalTime()
$n1 = 'c0de3d0000000001'; $b1 = New-ObsBuild3d $n1
$ba = New-Summary3d (Join-Path $b1.Base 'cap\BA') 'BA' $n1 '2026-10-13T08:56:00.0000000Z' $U2; $bf = New-Summary3d (Join-Path $b1.Base 'cap\BF') 'BF' $n1 '2026-10-13T08:57:30.0000000Z' $U2
$null = New-Cl3dValid (Join-Path $b1.Base 'cap') $n1 $TX.AddSeconds(-60) $U2
$o = Invoke-Obs3d $b1 $n1 $ba $bf $TX
$oj = Get-Content -Raw (Join-Path $o.OutDir 'observe.json') | ConvertFrom-Json
Check 'G1 an attempt on Unit 2: the console checklist (checklist3d.json, the reading on Unit 2, BA10) and the dwell gate pass; registered in build\stage3d\attempted; exactly one fastboot boot after one fastboot devices; observe.json Stage 3d, Serial/Unit 2; NEXT fs-collect3d.ps1 with the S3d names, THEN fs-classify3d.ps1' `
    ($o.Exit -eq 0 -and (@($script:fk3.Calls) -join ';') -ceq "devices;-s $U2 boot $($b1.Img)" -and (Test-Path (Join-Path $b1.Root "attempted\$n1.attempted")) -and $oj.Stage -ceq '3d' -and $oj.Serial -ceq $U2 -and $oj.Unit -ceq 'Unit 2' -and
     $oj.NextCommand -match "fs-collect3d\.ps1 -S3dPort COM9 -S3dNonce $n1 -S3dBootStartUtc \S+ -S3dHandoffUtc \S+ -S3dOutDir " -and (@($script:fk3.Lines) -match 'THEN: fs-classify3d\.ps1 -C3dDir').Count -eq 1 -and $oj.ChecklistFile -match 'checklist3d\.json$') "$($o.Why) $(@($script:fk3.Calls) -join ';')"
$bad = @()
$n2 = 'c0de3d0000000002'; $b2 = New-ObsBuild3d $n2
$ba2 = New-Summary3d (Join-Path $b2.Base 'cap\BA') 'BA' $n2 '2026-10-13T08:56:00.0000000Z' $U2; $bf2 = New-Summary3d (Join-Path $b2.Base 'cap\BF') 'BF' $n2 '2026-10-13T08:57:30.0000000Z' $U2
$null = New-Cl3dValid (Join-Path $b2.Base 'cap') $n2 $TX.AddSeconds(-60) $U2
$o = Invoke-Obs3d $b2 $n2 $ba2 $bf2 $TX $false '' $U2 $U1
if (-not ($o.Exit -eq 2 -and $o.Why -match "need exactly one fastboot device, $U2 \(got: $U1\)" -and (@($script:fk3.Calls) -join ';') -ceq 'devices' -and -not (Test-Path (Join-Path $b2.Root "attempted\$n2.attempted")))) { $bad += "Unit 2 cycle, Unit 1 attached: $($o.Exit) $($o.Why)" }
$o = Invoke-Obs3d $b2 $n2 $ba2 $bf2 $TX $false '' $U1 $U1
if (-not ($o.Exit -eq 2 -and $o.Why -match "taken on unit '$U2', not on this attempt's unit $U1" -and $script:fk3.Calls.Count -eq 0)) { $bad += "-Serial Unit 1 with a Unit-2 cycle: $($o.Exit) $($o.Why)" }
$o = Invoke-Obs3d $b2 $n2 $ba2 $bf2 $TX $false '' ''
if (-not ($o.Exit -eq 2 -and $o.Why -match "^REFUSED: -Serial '' is not one of the two Quest 3 units" -and $script:fk3.Calls.Count -eq 0)) { $bad += "no -Serial: $($o.Exit) $($o.Why)" }
Check 'G2 the unit is a parameter (J-133, review MAJOR-2): a Unit-2 cycle with Unit 1 attached is refused at the read-only fastboot devices (not registered); -Serial Unit 1 with a Unit-2 reading refused before any device query; no -Serial refused' ($bad.Count -eq 0) ($bad -join ' | ')
$bad = @()
foreach ($mc in @(@{ boot = '49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50' }, @{ vbmeta = ('0' * 64) }, @{ vbsys = ('0' * 64) }, @{ digest = ('1' * 64) }, @{ pin = '066bdc3ee01e5974518f96e8311c071c8f3aed302cadefa42c1273d5196b27bc' },
                  @{ pin = '7c9fa98c3d04d2cc43663ac85429829d204048270ddf75a62919e6185a950674' }, @{ title = 'stage-3c image' }, @{ over = "TEST OVERRIDES: DEADLINE=30`n" })) {
    $nx = 'c0de3d00000000' + (New-FsHex 1); $bx = New-ObsBuild3d $nx $mc
    $o = Invoke-Obs3d $bx $nx '' '' $TX $true
    $want = switch ($mc.Keys | Select-Object -First 1) { 'boot' { 'stock boot' } 'vbmeta' { 'MANIFEST vbmeta is not' } 'vbsys' { 'vbmeta_system' } 'digest' { 'vbmeta digest' } 'pin' { 'is not the reviewed fs-pattern v0\.7\.1 \(bfafad97' } 'title' { 'not a stage-3d image manifest' } 'over' { 'TEST OVERRIDES' } }
    if (-not ($o.Exit -eq 2 -and $o.Why -match $want -and $script:fk3.Calls.Count -eq 0)) { $bad += "$($mc.Keys): $($o.Exit) $($o.Why)" }
}
$nx = 'c0de3d00000000f0'; $bx = New-ObsBuild3d $nx; $o = Invoke-Obs3d $bx $nx '' '' $TX $true '' ''
if (-not ($o.Exit -eq 0 -and $o.Why -match '^preflight OK' -and $script:fk3.Calls.Count -eq 0)) { $bad += "preflight: $($o.Exit) $($o.Why)" }
Check 'G3 the stage-3d MANIFEST (README 6.1, 6.8): refused even at -Preflight for the v66 stock boot, another vbmeta / vbmeta_system / vbmeta digest, an fs-pattern other than v0.7.1 (the v0.6 pin; J-141: the v0.7 pin 7c9fa98c...0674 of the withdrawn candidate), a stage-3c title, TEST OVERRIDES; -Preflight of a good one: preflight OK, no device action, no -Serial needed' ($bad.Count -eq 0) ($bad -join ' | ')
$n7 = 'c0de3d0000000007'; $b7 = New-ObsBuild3d $n7
$ba7 = New-Summary3d (Join-Path $b7.Base 'cap\BA') 'BA' $n7 '2026-10-13T08:56:00.0000000Z' $U1; $bf7 = New-Summary3d (Join-Path $b7.Base 'cap\BF') 'BF' $n7 '2026-10-13T08:57:30.0000000Z' $U1
$null = New-Cl3dValid (Join-Path $b7.Base 'cap') $n7 $TX.AddSeconds(-60) $U1
$o = Invoke-Obs3d $b7 $n7 $ba7 $bf7 $TX $false '' $U1 $U1 $false $true
$oj7 = Get-Content -Raw (Join-Path $o.OutDir 'observe.json') | ConvertFrom-Json
$n8 = 'c0de3d0000000008'; $b8 = New-ObsBuild3d $n8
$ba8 = New-Summary3d (Join-Path $b8.Base 'cap\BA') 'BA' $n8 '2026-10-13T08:56:00.0000000Z' $U1; $bf8 = New-Summary3d (Join-Path $b8.Base 'cap\BF') 'BF' $n8 '2026-10-13T08:57:30.0000000Z' $U1
$null = New-Cl3dValid (Join-Path $b8.Base 'cap') $n8 $TX.AddSeconds(-60) $U1
$o8 = Invoke-Obs3d $b8 $n8 $ba8 $bf8 $TX $false '' $U1 $U1 $false $false
$oj8 = Get-Content -Raw (Join-Path $o8.OutDir 'observe.json') | ConvertFrom-Json
Check 'G4 README 6.11: on Unit 1, no gadget within the wait: one more read-only fastboot devices; the unit back in fastboot -> NoGadgetNote "consistent with the module index refusal (wrong build?)"; not back -> "the PID 1 deadline / recovery table applies"; no NEXT command' `
    ($o.Exit -eq 0 -and (@($script:fk3.Calls | Select-Object -First 1)) -ceq 'devices' -and $oj7.NoGadgetNote -match 'consistent with the module index refusal \(wrong build\?\)' -and -not $oj7.NextCommand -and
     $oj8.NoGadgetNote -match 'not \(yet\) in fastboot' -and $oj7.Unit -ceq 'Unit 1') "$($oj7.NoGadgetNote) | $($oj8.NoGadgetNote)"
# review 2 MINOR-1: the BA/BF must-be rows machine-checked before any device query
$bad = @()
$mbCases = @(
    @('BA04 _b', 'BA', @{ BA04 = '_b' }, "BA04 \(ro\.boot\.slot_suffix\) is '_b', not '_a'"),
    @('BA16 another vbmeta digest', 'BA', @{ BA16 = ('1' * 64) }, 'BA16 \(ro\.boot\.vbmeta\.digest, the v2\.7 build stage 3d is made from\) is ''1{64}'''),
    @('BA20 userdebug', 'BA', @{ BA20 = 'userdebug' }, "BA20 \(ro\.build\.type\) is 'userdebug', not 'user'"),
    @('BA23 the other unit', 'BA', @{ BA23 = $U1 }, "BA23 \(ro\.serialno, this unit\) is '$U1', not '$U2'"),
    @('BA04 not captured', 'BA', @{ BA04 = $null }, 'BA04: the SUMMARY has 0 BA04 rows'),
    @('BA20 row exit 1', 'BA', @{ Exit = @{ BA20 = '1' } }, 'BA20: the row did not exit 0'),
    @('BF02 current-slot b', 'BF', @{ BF02 = "# stderr`ncurrent-slot: b`nFinished. Total time: 0.001s" }, "BF02 \(getvar current-slot\) is 'b', not 'a'"),
    @('BF02 not captured', 'BF', @{ BF02 = $null }, 'BF02: the SUMMARY has 0 BF02 rows'),
    @('BA16 file changed after the capture', 'BA', @{}, 'BA16: .*changed after it', { param($d) Add-Content -LiteralPath (Join-Path $d 'BA16.txt') -Value 'x' }))
foreach ($mc in $mbCases) {
    $nx = 'c0de3d000000' + (New-FsHex 2); $bx = New-ObsBuild3d $nx
    $baV = if ($mc[1] -ceq 'BA') { $mc[2] } else { @{} }; $bfV = if ($mc[1] -ceq 'BF') { $mc[2] } else { @{} }
    $bax = New-Summary3d (Join-Path $bx.Base 'cap\BA') 'BA' $nx '2026-10-13T08:56:00.0000000Z' $U2 $baV; $bfx = New-Summary3d (Join-Path $bx.Base 'cap\BF') 'BF' $nx '2026-10-13T08:57:30.0000000Z' $U2 $bfV
    if ($mc.Count -gt 4) { & $mc[4] (Join-Path $bx.Base 'cap\BA') }
    $null = New-Cl3dValid (Join-Path $bx.Base 'cap') $nx $TX.AddSeconds(-60) $U2
    $o = Invoke-Obs3d $bx $nx $bax $bfx $TX
    if (-not ($o.Exit -eq 2 -and $o.Why -match '^REFUSED: BA/BF must-be rows: ' -and $o.Why -match $mc[3] -and $script:fk3.Calls.Count -eq 0 -and -not (Test-Path (Join-Path $bx.Root "attempted\$nx.attempted")))) { $bad += "$($mc[0]): exit $($o.Exit) calls $($script:fk3.Calls.Count) $($o.Why)" }
}
$batSave = $script:T3Bat; $script:T3Bat = $script:T3Bat.Replace('level: 80', 'level: 50')
try {
    $nx = 'c0de3d00000000d5'; $bx = New-ObsBuild3d $nx
    $bax = New-Summary3d (Join-Path $bx.Base 'cap\BA') 'BA' $nx '2026-10-13T08:56:00.0000000Z' $U2; $bfx = New-Summary3d (Join-Path $bx.Base 'cap\BF') 'BF' $nx '2026-10-13T08:57:30.0000000Z' $U2
    $null = New-Cl3dValid (Join-Path $bx.Base 'cap') $nx $TX.AddSeconds(-60) $U2
    $o = Invoke-Obs3d $bx $nx $bax $bfx $TX
    if (-not ($o.Exit -eq 2 -and $o.Why -match 'battery level 50 at BA is not above 50' -and $script:fk3.Calls.Count -eq 0)) { $bad += "BA10 level 50: exit $($o.Exit) $($o.Why)" }
} finally { $script:T3Bat = $batSave }
Check "G7 review 2 MINOR-1: the BA/BF must-be rows are machine-checked from this nonce's captures before any device query ($($mbCases.Count + 1) refusals: BA04 _b, BA16 another digest, BA20 userdebug, BA23 the other unit, BA04 not captured, a BA20 row that failed, BF02 slot b, BF02 not captured, a BA16 file changed after the capture, BA10 level 50); G1 records MustBe (BA04 _a, BA16, BA20 user, BA23, BF02 a) and NonceOnly in observe.json" `
    ($bad.Count -eq 0 -and $oj.MustBe.BA04 -ceq '_a' -and $oj.MustBe.BA20 -ceq 'user' -and $oj.MustBe.BA23 -ceq $U2 -and $oj.MustBe.BF02 -ceq 'a' -and $oj.MustBe.BA16 -ceq '66b7619671a8a8dcb75262812e7ce1bd176af6aa32cd76dc3548b9c942e9f12a' -and
     $oj.NonceOnly -match '^the reviewed candidate ') ($bad -join ' | ')
# review 3 MINOR-4: an adb notice on stderr (after the "# stderr" line fs-capture writes) is not the value
$nx = 'c0de3d00000000d6'; $bx = New-ObsBuild3d $nx
$bax = New-Summary3d (Join-Path $bx.Base 'cap\BA') 'BA' $nx '2026-10-13T08:56:00.0000000Z' $U2 @{ BA04 = "_a`n# stderr`n* daemon not running; starting now at tcp:5037`n* daemon started successfully" }
$bfx = New-Summary3d (Join-Path $bx.Base 'cap\BF') 'BF' $nx '2026-10-13T08:57:30.0000000Z' $U2
$null = New-Cl3dValid (Join-Path $bx.Base 'cap') $nx $TX.AddSeconds(-60) $U2
$o = Invoke-Obs3d $bx $nx $bax $bfx $TX
Check 'G7b review 3 MINOR-4: a must-be row whose capture carries an adb notice on stderr (after "# stderr") is read from its stdout only: BA04 _a accepted, the attempt proceeds' ($o.Exit -eq 0 -and (@($script:fk3.Lines) -join ' ') -match 'must-be rows OK: BA04 _a') $o.Why
# review 2 MAJOR-2: an image that is not the reviewed candidate needs a passing nonce-only check against it, also at -Preflight
$nx = 'c0de3d00000000e8'; $bx = New-ObsBuild3d $nx
$o = Invoke-Obs3d $bx $nx '' '' $TX $true '' '' $U2 $true $true ('ab' * 32)
Check 'G8 review 2 MAJOR-2: an image whose SHA-256 is not the reviewed candidate''s is refused even at -Preflight unless it is a nonce-only rebuild of the reviewed candidate (here no reference in the build root: refused, naming it), no device action' `
    ($o.Exit -eq 2 -and $o.Why -match "^image refused: not the reviewed candidate (ab){32} and not a nonce-only rebuild of it \(.*$([regex]::Escape($script:FsNoReviewedDir))\): reference: no MANIFEST\.txt" -and $script:fk3.Calls.Count -eq 0) $o.Why
# J-141: the withdrawn first candidate is never a reference (nor an image): an observer given it as the reviewed candidate refuses
$nx = 'c0de3d00000000e9'; $bx = New-ObsBuild3d $nx
$o = Invoke-Obs3d $bx $nx '' '' $TX $true '' '' $U2 $true $true '3d730337c6fa9e0b5aa6dbbe9da382770ad7b104de0399887b7bfd1c30fcc224' '20261013T065151Z-7a22c3d2ff0fef44'
$wdOld = Get-FsNoWithdrawn '3d730337c6fa9e0b5aa6dbbe9da382770ad7b104de0399887b7bfd1c30fcc224'; $wdNew = Get-FsNoWithdrawn $script:FsNoReviewedSha
Check "G9 J-141: the reviewed-candidate table: the current candidate $($script:FsNoReviewedDir) ($($script:FsNoReviewedSha.Substring(0, 8))...) is not withdrawn; the first one (3d730337...c224, 7a22c3d2ff0fef44) is withdrawn (nonce spent, fs-pattern v0.7); an observer given it as the reviewed candidate refuses even at -Preflight (image refused: the reviewed reference ... is a WITHDRAWN candidate), no device action" `
    (-not $wdNew -and $wdOld -match 'spent on Unit 2 \(J-141\)' -and $wdOld -match 'MAXMODES 128' -and $script:FsNoReviewedDir -ceq '20261014T014738Z-13ed21be49c7b4ba' -and (Get-FsNoWithdrawn '96cc15aabc647e9da4b1d5b0f95214bd42445aa66c4eb1a8c79210f273113fad') -match '^superseded before any boot' -and
     $o.Exit -eq 2 -and $o.Why -match '^image refused: the reviewed reference 3d730337\S+ is a WITHDRAWN candidate \(nonce 7a22c3d2ff0fef44 spent' -and $script:fk3.Calls.Count -eq 0) $o.Why

$obsSrc = [IO.File]::ReadAllText((Join-Path $T3Dir 'fs-observe3d.ps1'))
Check 'G5 static: fs-observe3d.ps1 is ASCII; -ThenCollect launches fs-collect3d.ps1 with the S3d names; the build root is build\stage3d; it opens no serial port and runs no session' `
    (-not ($obsSrc -match '[^\x00-\x7f]') -and $obsSrc -match "'fs-collect3d\.ps1'\) -S3dPort" -and $obsSrc -notmatch "fs-collect3c" -and $obsSrc -match 'build\\stage\$\(\$script:FsObs3dLabel\)' -and $obsSrc -notmatch 'SerialPort|New-FsRawSerialTransport|Invoke-Fs3dSession')
# the real current candidate (gitignored, in the main checkout; READ ONLY), and the withdrawn first one
$cand = Join-Path $MainRoot "build\stage3d\$($script:FsNoReviewedDir)"
$candNonce = $script:FsNoReviewedDir.Substring($script:FsNoReviewedDir.Length - 16)
$wdDir = Join-Path $MainRoot 'build\stage3d\20261013T065151Z-7a22c3d2ff0fef44'
if (Test-Path -LiteralPath (Join-Path $cand 'boot-stage3d.img')) {
    $mfr = Test-FsObsManifest -ImagePath (Join-Path $cand 'boot-stage3d.img') -Q3 $T3Q3
    $old = Get-ChildItem -LiteralPath (Join-Path $MainRoot 'build\stage3d') -Directory | Where-Object { $_.Name -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{16}\z' -and $_.Name -cne $script:FsNoReviewedDir -and (Test-Path (Join-Path $_.FullName 'boot-stage3d.img')) }
    # J-144/J-146: the candidate's nonce was spent on Unit 1 and the nonce-only rebuild 3581faf87b8706eb on Unit 2; the
    # candidate stays the REFERENCE of every nonce-only rebuild (not withdrawn). Every other build directory whose MANIFEST
    # passes is a spent rebuild (its nonce in the attempted ledger); the others are refused by the MANIFEST check.
    $isAtt = { param([string]$n0) Test-Path -LiteralPath (Join-Path $MainRoot "build\stage3d\attempted\$n0.attempted") }
    $oldBad = @(foreach ($od0 in $old) { $m0 = Test-FsObsManifest -ImagePath (Join-Path $od0.FullName 'boot-stage3d.img') -Q3 $T3Q3; if ($m0.Ok -and -not (& $isAtt $m0.Nonce)) { $od0.Name } })
    $att = & $isAtt $candNonce
    $script:gLines = New-Object System.Collections.Generic.List[string]
    $oc = Invoke-FsObserve -ImagePath (Join-Path $cand 'boot-stage3d.img') -Preflight $true -BuildRoot (Join-Path $MainRoot 'build\stage3d') -Q3 $T3Q3 -Fastboot { param($a, $t) throw 'no device in a preflight' } -Gadget { param($n) $null } -NowUtc { [DateTime]::UtcNow } -Sleep { param($ms) } -Say { param([string]$l) $script:gLines.Add($l) }
    Check "G6 the reviewed candidate build\stage3d\$($script:FsNoReviewedDir) (main checkout, read only): Test-FsObsManifest OK against this branch's stage3d sources (image $($script:FsNoReviewedSha.Substring(0, 8))..., nonce $candNonce, the v2.7 baseline, vbmeta lines, fs-pattern v0.7.1); J-144: its nonce is spent (attempted ledger), so fs-observe3d -Preflight on it exits 2 (already attempted), nothing written; it is not withdrawn (the reference of the next nonce-only rebuild); every other build directory ($(@($old).Count)) is refused by its MANIFEST or spent (J-146: 3581faf87b8706eb)" `
        ($mfr.Ok -and $mfr.Nonce -ceq $candNonce -and $mfr.ImageSha -ceq $script:FsNoReviewedSha -and $att -and $oc.Exit -eq 2 -and $oc.Why -match "nonce $candNonce was already attempted" -and $null -eq $oc.OutDir -and
         -not (Get-FsNoWithdrawn $script:FsNoReviewedSha) -and $oldBad.Count -eq 0) "$($mfr.Why) attempted $att preflight $($oc.Exit) $($oc.Why) accepted-unspent-old: $($oldBad -join ',')"
} else { Skip 'G6 the real candidate' "not present: $cand" }
if (Test-Path -LiteralPath (Join-Path $wdDir 'boot-stage3d.img')) {
    # J-141: the withdrawn first candidate (its nonce spent on Unit 2): refused by the MANIFEST check (fs-pattern v0.7) and by the ledger
    $mfw = Test-FsObsManifest -ImagePath (Join-Path $wdDir 'boot-stage3d.img') -Q3 $T3Q3
    $attW = Test-Path -LiteralPath (Join-Path $MainRoot 'build\stage3d\attempted\7a22c3d2ff0fef44.attempted')
    $script:gLines = New-Object System.Collections.Generic.List[string]
    $ow = Invoke-FsObserve -ImagePath (Join-Path $wdDir 'boot-stage3d.img') -Preflight $true -BuildRoot (Join-Path $MainRoot 'build\stage3d') -Q3 $T3Q3 -Fastboot { param($a, $t) throw 'no device in a preflight' } -Gadget { param($n) $null } -NowUtc { [DateTime]::UtcNow } -Sleep { param($ms) } -Say { param([string]$l) $script:gLines.Add($l) }
    Check 'G6b J-141: the withdrawn first candidate build\stage3d\20261013T065151Z-7a22c3d2ff0fef44 (main checkout, read only) is refused: its MANIFEST /bin/fs-pattern is v0.7 (7c9fa98c...), not the v0.7.1 pin; its nonce 7a22c3d2ff0fef44 is in the attempted ledger; fs-observe3d -Preflight on it exits 2 (image refused), nothing written' `
        (-not $mfw.Ok -and $mfw.Why -match 'is not the reviewed fs-pattern v0\.7\.1' -and $mfw.Nonce -ceq '7a22c3d2ff0fef44' -and $attW -and $ow.Exit -eq 2 -and $ow.Why -match '^image refused: MANIFEST /bin/fs-pattern is not the reviewed fs-pattern v0\.7\.1' -and $null -eq $ow.OutDir) "$($mfw.Why) | attempted $attW | $($ow.Exit) $($ow.Why)"
} else { Skip 'G6b the withdrawn candidate' "not present: $wdDir" }

# ------------------------------------------------------------------ H --------
Say '== H. fs-checklist3d.ps1, the observer gate, SIGNOFF-3d and the WALKTHROUGH'
$cyc = Join-Path $Scratch 'cl3d-cycle'; $null = New-Item -ItemType Directory -Force -Path $cyc
Push-Location -LiteralPath $CLR; try { $null = Get-FileHash -Algorithm SHA256 -LiteralPath devices\quest3\host\fake-a.ps1 | Format-Table Hash, Path -AutoSize | Out-String -Width 400 | Tee-Object -FilePath (Join-Path $cyc 'host-hashes.txt') } finally { Pop-Location }
$h1ts = (Get-FsCl3dToolSet $CLR).Sha256; $h1m = [DateTime]::Parse('2026-10-13T07:00:00Z').ToUniversalTime()
New-Cl3dSoundJson (Join-Path $cyc 'soundcheck.json') $h1m $h1ts
$rhd = Join-Path $cyc 'rehearsal'; $null = New-Item -ItemType Directory -Force -Path $rhd; $null = Save-Fs3dSummary $CAN['garbled-r3'].R $rhd $true (New-Cl3dMade $h1m $h1ts $CLR 'rehearsal')
$rrd = Join-Path $cyc 'rehearsal-read'; $null = New-Item -ItemType Directory -Force -Path $rrd; $null = Save-Fs3dSummary $CAN['nominal-read'].R $rrd $true (New-Cl3dMade $h1m $h1ts $CLR 'rehearsal-read')
$script:clk = [DateTime]::Parse('2026-10-13T08:00:00Z').ToUniversalTime(); $script:asked = New-Object System.Collections.Generic.List[string]; $script:said = New-Object System.Collections.Generic.List[string]
$pf = { param([string]$i) [pscustomobject]@{ Ok = $true; Why = 'exit 0; preflight OK: fixture'; Nonce = 'c0de3d00000000a1'; ImageSha = ('ab' * 32) } }
$H1sd = Join-Path $Scratch 'cl3d-standing'     # J-143: the standing directory of the H tests (captures\standing in a real run)
$opt = @{ Root = $CLR; SignoffFile = (Join-Path $CLR 'SIGNOFF-3d.md'); Image = 'C:\fixture\boot-stage3d.img'; Preflight = $pf; TimeoutSec = 30; StandingDir = $H1sd; LocalDate = $script:T3Day }
$ask = { param([string]$t, [int]$to) $script:asked.Add($t); $script:clk = $script:clk.AddSeconds(3); 'y' }
$ra = Invoke-FsCl3dPhase -Phase A -Cycle $cyc -Opt $opt -Ask $ask -NowUtc { $script:clk } -Say { param([string]$l) $script:said.Add($l) }
$rb = Invoke-FsCl3dPhase -Phase B -Cycle $cyc -Opt (@{} + $opt + @{ R1 = '301'; R1Utc = '2026-10-13T07:55:00Z'; R1Status = '4'; R1Serial = $U2 }) -Ask $ask -NowUtc { $script:clk } -Say { param([string]$l) $script:said.Add($l) }
$script:clk = $script:clk.AddSeconds(600)
$re = Invoke-FsCl3dPhase -Phase E -Cycle $cyc -Opt $opt -Ask $ask -NowUtc { $script:clk } -Say { param([string]$l) $script:said.Add($l) }
$cj = Get-Content -Raw (Join-Path $cyc 'checklist3d.json') | ConvertFrom-Json
$aSaid = ($script:said -join "`n")
Check 'H1 fs-checklist3d phases A, B (the reading on Unit 2, typed text), E pass; checklist3d.json schema frameshift.fs-checklist3d.v1; A''s automatic checks host-pins, preflight, soundcheck, rehearsal (the garbled path: the stage-3d GO line with the reset answer and the Q7 fallback), rehearsal-read (review 2 MAJOR-1: the timed read path GO), previews (stage3d v0.7 pictures), standing (J-143: none yet, so the full phase A: A1-A3 asked, the standing record written; the passes fresh); the stage-3d previews and points printed; the preview text names no expected bar order (review 2 MINOR-3)' `
    ($ra.Exit -eq 0 -and $rb.Exit -eq 0 -and $re.Exit -eq 0 -and $cj.Schema -ceq 'frameshift.fs-checklist3d.v1' -and (@($cj.Entries | ForEach-Object { "$($_.Phase)=$($_.Result)" }) -join ',') -ceq 'A=PASS,B=PASS,E=PASS' -and
     (@($cj.Entries[0].Checks | ForEach-Object { "$($_.Name)=$($_.Ok)" }) -join ',') -ceq 'host-pins=True,preflight=True,soundcheck=True,rehearsal=True,rehearsal-read=True,previews=True,standing=True' -and
     $cj.Entries[0].Acceptance.Mode -ceq 'full' -and (@($cj.Entries[0].Acceptance.Asked) -join ',') -ceq 'A1,A2,A3' -and $cj.Entries[0].SoundCheck.Mode -ceq 'fresh' -and $cj.Entries[0].RehearsalRead.Mode -ceq 'fresh' -and (Test-Path (Join-Path $H1sd 'phase-a.json')) -and $cj.Entries[1].Reading.R1Serial -ceq $U2 -and $cj.Entries[1].Reading.R1Unit -ceq 'Unit 2' -and
     $aSaid -match 'pattern-v0\.7-3f9c07ab-digits-left\.png' -and $aSaid -notmatch 'asseen|panels-1032|mixermap' -and (@($cj.Entries[0].Checks | Where-Object { $_.Name -ceq 'rehearsal' })[0].Detail -match '^fresh \(this cycle, made 2026-10-13T07:00:00\.0000000Z\): REHEARSAL: reset plus run-2 answers') -and (@($cj.Entries[0].Checks | Where-Object { $_.Name -ceq 'rehearsal-read' })[0].Detail -match '^fresh \(this cycle, made 2026-10-13T07:00:00\.0000000Z\): REHEARSAL \(read path\): the last answer') -and $aSaid.Contains('D2. Then the display reset') -and
     ((Get-FsCl3dPreviewLines '<r>') -join ' ') -notmatch '1 \| 2|3 \| 4') "$($ra.Why) | $($rb.Why) | $($re.Why)"
$rh2 = Join-Path $Scratch 'cl3d-reh-3c'; $null = New-Item -ItemType Directory -Force -Path $rh2; [IO.File]::WriteAllText((Join-Path $rh2 'summary.txt'), "REHEARSAL: run-1 plus run-2 answers 6.7 s; go/no-go (SIGNOFF-3c A, Q7): GO (<= 40 s)`nnot asked (Q7 fallback)`n")
$t3 = Test-FsCl3dRehearsal $rh2
$t4 = Test-FsCl3dRehearsalRead $rhd; $t5 = Test-FsCl3dRehearsalRead (Join-Path $Scratch 'no-such-rehearsal')
$rh6 = Join-Path $Scratch 'cl3d-reh-nogo'; $null = New-Item -ItemType Directory -Force -Path $rh6; [IO.File]::WriteAllText((Join-Path $rh6 'summary.txt'), (((Write-Fs3dSummary $CAN['nominal-read'].R $true) -join "`n") -replace 'GO \(every item answered, at least 10 s to spare\)', 'NO-GO (an item not answered or less than 10 s to spare): repeat or report') + "`n")
$t6 = Test-FsCl3dRehearsalRead $rh6
$rc7 = Join-Path $Scratch 'cl3d-cycle-noread'; $null = New-Item -ItemType Directory -Force -Path $rc7
foreach ($f0 in 'host-hashes.txt', 'soundcheck.json') { Copy-Item -LiteralPath (Join-Path $cyc $f0) -Destination (Join-Path $rc7 $f0) }
$null = New-Item -ItemType Directory -Force -Path (Join-Path $rc7 'rehearsal'); Copy-Item -LiteralPath (Join-Path $rhd 'summary.txt') -Destination (Join-Path $rc7 'rehearsal\summary.txt')
$o7 = @{} + $opt; $o7.StandingDir = Join-Path $Scratch 'cl3d-standing-h2'     # J-143: no earlier pass to carry over
$script:asked.Clear(); $r7 = Invoke-FsCl3dPhase -Phase A -Cycle $rc7 -Opt $o7 -Ask $ask -NowUtc { $script:clk } -Say { param([string]$l) }
Check 'H2 a stage-3c rehearsal summary does not pass the stage-3d rehearsal check; the read-path check (review 2 MAJOR-1) refuses the garbled-path summary, a missing one and a NO-GO one; phase A without the timed read-path rehearsal STOPs (rehearsal-read), nothing asked' `
    (-not $t3.Ok -and -not $t4.Ok -and -not $t5.Ok -and $t5.Why -match 'missing' -and -not $t6.Ok -and $t6.Why -match 'no read-path GO line' -and $r7.Exit -eq 1 -and $script:asked.Count -eq 0 -and
     (@($r7.Entry.Checks | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name }) -join ',') -ceq 'rehearsal-read') "$($t3.Why) | $($t4.Why) | $($t6.Why) | $($r7.Why)"
$bad = @()
$e9 = [DateTime]::Parse($cj.Entries[2].EndUtc).ToUniversalTime()
$ba9 = New-Summary3d (Join-Path $cyc 'BA') 'BA' 'c0de3d00000000a1' (Format-FsCl3dUtc ([DateTime]::Parse('2026-10-13T07:57:00Z').ToUniversalTime())) $U2
$bf9 = New-Summary3d (Join-Path $cyc 'BF') 'BF' 'c0de3d00000000a1' (Format-FsCl3dUtc ([DateTime]::Parse($cj.Entries[2].StartUtc).ToUniversalTime().AddSeconds(-30))) $U2
$v = Test-FsObsChecklist -Path (Join-Path $cyc 'checklist3d.json') -Nonce 'c0de3d00000000a1' -NowUtc $e9.AddSeconds(5) -ToolPin $script:clPinReal -BaSummary $ba9 -BfSummary $bf9 -Serial $U2 -LocalDate $script:T3Day
if (-not $v.Ok) { $bad += "Unit 2: $($v.Why)" }
$v = Test-FsObsChecklist -Path (Join-Path $cyc 'checklist3d.json') -Nonce 'c0de3d00000000a1' -NowUtc $e9.AddSeconds(5) -ToolPin $script:clPinReal -BaSummary $ba9 -BfSummary $bf9 -Serial $U1 -LocalDate $script:T3Day
if ($v.Ok -or $v.Why -notmatch "taken on unit '$U2'") { $bad += "Unit 1: $($v.Why)" }
$v = Test-FsObsChecklist -Path (Join-Path $cyc 'checklist3d.json') -Nonce 'c0de3d00000000a1' -NowUtc $e9.AddSeconds(5) -ToolPin ('ab' * 32) -BaSummary $ba9 -BfSummary $bf9 -Serial $U2 -LocalDate $script:T3Day
if ($v.Ok -or $v.Why -notmatch 'not written by the pinned fs-checklist3d\.ps1') { $bad += "pin: $($v.Why)" }
Check 'H3 the fs-observe3d gate on a fs-checklist3d cycle: accepted for Unit 2 (the reading''s unit), refused for Unit 1 and for entries not by the pinned fs-checklist3d.ps1' ($bad.Count -eq 0) ($bad -join ' | ')
# ------------------------------------------------------------------ H7-H13: J-143 and J-145 --------
# J-143 (PM): the standing phase-A acceptance and the carry-over of the sound check and the rehearsals; J-145: charging
# accepted below 300. All on the fake root ($CLR), each test with its own standing directory (captures\standing).
function New-Cl3dHashesOnly([string]$cyc, [string]$root = $CLR) {
    $null = New-Item -ItemType Directory -Force -Path $cyc
    [IO.File]::WriteAllText((Join-Path $cyc 'host-hashes.txt'), "`r`nHash Path`r`n---- ----`r`n$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'devices\quest3\host\fake-a.ps1')).Hash) $(Join-Path $root 'devices\quest3\host\fake-a.ps1')`r`n"); $cyc
}
function Copy-Cl3dDir([string]$from, [string]$to) { $null = New-Item -ItemType Directory -Force -Path $to; Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force; $to }
function T3Fails($r) { (@($r.Entry.Checks | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name }) -join ',') }
function T3Chk($r, [string]$n) { [string](@($r.Entry.Checks | Where-Object { $_.Name -ceq $n } | ForEach-Object { $_.Detail }) -join ' ') }
$D0 = [DateTime]::Parse('2026-10-14T10:00:00Z').ToUniversalTime()
$Hs = Join-Path $Scratch 'h7-standing'; $hn = 'c0de3d00000000b1'
$c1 = Join-Path $Scratch 'h7-c1'; New-Cl3dCycleFiles $c1 $D0
$ra1 = Invoke-Cl3dA $c1 $hn $D0.AddMinutes(5) $Hs; $ra1n = $script:clAsked.Count
$c2 = New-Cl3dHashesOnly (Join-Path $Scratch 'h7-c2')
$ra2 = Invoke-Cl3dA $c2 $hn $D0.AddMinutes(60) $Hs; $ra2n = $script:clAsked.Count; $s2 = ($script:clSaid -join "`n")
$e2 = $ra2.Entry
$rb2 = Invoke-FsCl3dPhase -Phase B -Cycle $c2 -Opt @{ LocalDate = $script:T3Day; R1 = '299'; R1Utc = (Format-FsCl3dUtc $D0.AddMinutes(61)); R1Status = '2'; R1Serial = $U1 } -Ask { 'y' } -NowUtc { $D0.AddMinutes(62) } -Say { param($l) }
$ba2 = New-Summary3d (Join-Path $c2 'BA') 'BA' $hn (Format-FsCl3dUtc $D0.AddMinutes(65)) $U1; $bf2 = New-Summary3d (Join-Path $c2 'BF') 'BF' $hn (Format-FsCl3dUtc $D0.AddMinutes(66)) $U1
$re2 = Invoke-FsCl3dPhase -Phase E -Cycle $c2 -Opt @{ LocalDate = $script:T3Day } -Ask { param($t, $to) 'y' } -NowUtc { $D0.AddMinutes(67) } -Say { param($l) }
$cl2 = Join-Path $c2 'checklist3d.json'
$v2 = Test-FsObsChecklist -Path $cl2 -Nonce $hn -NowUtc $D0.AddMinutes(68) -ToolPin $script:clPinReal -BaSummary $ba2 -BfSummary $bf2 -Serial $U1 -LocalDate $script:T3Day
$j2 = Get-Content -Raw $cl2 | ConvertFrom-Json
Check 'H7 J-143 the standing acceptance places A in time: cycle 1 (its own sound check and rehearsals) runs the full phase A (A1-A3) and writes captures\standing\phase-a.json; cycle 2 (no sound check, no rehearsal files) runs phase A at its start with NO question: an automatic PASS entry (Acceptance standing: the record''s path and SHA-256, cycle 1''s acceptance time) relying on cycle 1''s sound check and both rehearsals (carried: path, SHA-256, tool set, day, cycle); then B (299 while charging, J-145), BA/BF, E; the observer accepts the cycle (A, B, E in order)' `
    ($ra1.Exit -eq 0 -and $ra1n -eq 3 -and $ra1.Entry.Acceptance.Mode -ceq 'full' -and $ra2.Exit -eq 0 -and $ra2n -eq 0 -and $e2.Acceptance.Mode -ceq 'standing' -and $e2.Acceptance.StandingSha256 -ceq (Get-FsCl3dSha (Join-Path $Hs 'phase-a.json')) -and
     $e2.Acceptance.AcceptedCycle -ceq $c1 -and $e2.SoundCheck.Mode -ceq 'carried' -and $e2.SoundCheck.Path -ceq [IO.Path]::GetFullPath((Join-Path $c1 'soundcheck.json')) -and $e2.SoundCheck.Cycle -ceq $c1 -and
     $e2.Rehearsal.Mode -ceq 'carried' -and $e2.RehearsalRead.Mode -ceq 'carried' -and $e2.RehearsalRead.Sha256 -ceq (Get-FsCl3dSha (Join-Path $c1 'rehearsal-read\summary.txt')) -and $s2 -match 'STANDING ACCEPTANCE \(nothing to read or answer\)' -and
     $rb2.Exit -eq 0 -and $re2.Exit -eq 0 -and $v2.Ok -and (@($j2.Entries | ForEach-Object { $_.Phase }) -join ',') -ceq 'A,B,E' -and
     [DateTime]::Parse($j2.Entries[0].EndUtc).ToUniversalTime() -lt [DateTime]::Parse($j2.Entries[1].StartUtc).ToUniversalTime()) "$($ra1.Why) | $($ra2.Why) | $($v2.Why)"
# the observer re-checks what phase A relied on
$bad = @()
$sp = Join-Path $Hs 'phase-a.json'; [byte[]]$spb = [IO.File]::ReadAllBytes($sp)
try { [IO.File]::AppendAllText($sp, ' '); $v = Test-FsObsChecklist -Path $cl2 -Nonce $hn -NowUtc $D0.AddMinutes(68) -ToolPin $script:clPinReal -BaSummary $ba2 -BfSummary $bf2 -Serial $U1 -LocalDate $script:T3Day
      if ($v.Ok -or $v.Why -notmatch 'changed after phase A') { $bad += "standing file changed: $($v.Why)" } } finally { [IO.File]::WriteAllBytes($sp, $spb) }
$rp = Join-Path $c1 'rehearsal-read\summary.txt'; [byte[]]$rpb = [IO.File]::ReadAllBytes($rp)
try { [IO.File]::AppendAllText($rp, "x`n"); $v = Test-FsObsChecklist -Path $cl2 -Nonce $hn -NowUtc $D0.AddMinutes(68) -ToolPin $script:clPinReal -BaSummary $ba2 -BfSummary $bf2 -Serial $U1 -LocalDate $script:T3Day
      if ($v.Ok -or $v.Why -notmatch 'RehearsalRead file phase A relied on .* changed since') { $bad += "carried rehearsal changed: $($v.Why)" } } finally { [IO.File]::WriteAllBytes($rp, $rpb) }
[byte[]]$clb = [IO.File]::ReadAllBytes($cl2)
$script:bad8 = @()
$tamper = { param([scriptblock]$mut, [string]$want, [string]$name)
    $j = [IO.File]::ReadAllText($cl2) | ConvertFrom-Json; & $mut $j
    [IO.File]::WriteAllText($cl2, ($j | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    try { $v = Test-FsObsChecklist -Path $cl2 -Nonce $hn -NowUtc $D0.AddMinutes(68) -ToolPin $script:clPinReal -BaSummary $ba2 -BfSummary $bf2 -Serial $U1 -LocalDate $script:T3Day
          if ($v.Ok -or $v.Why -notmatch $want) { $script:bad8 += "${name}: $($v.Why)" } } finally { [IO.File]::WriteAllBytes($cl2, $clb) } }
& $tamper { param($j) $j.Entries[0].PSObject.Properties.Remove('Acceptance') } 'records no acceptance' 'A without Acceptance (the pre-J-143 form)'
& $tamper { param($j) $j.Entries[0].TextSha256 = ('cd' * 32); $j.Entries[0].Acceptance.TextSha256 = ('cd' * 32) } 'covers another text' 'A claiming another text'
& $tamper { param($j) $j.Entries[0].Acceptance.Mode = 'full' } 'lacks the answer y to question A1' 'A claiming a full acceptance without the answers'
& $tamper { param($j) $j.Entries[0].SoundCheck.LocalDate = '2026-10-13' } 'SoundCheck pass \(carried\) is from 2026-10-13' 'a carried sound check of another day'
& $tamper { param($j) $j.Entries[0].Rehearsal.ToolSetSha256 = ('ef' * 32) } 'another session/collector tool set' 'a rehearsal of another tool set'
& $tamper { param($j) $j.Entries[0].Acceptance.Mode = 'renewal' } 'is not standing, full or changes' 'A claiming the removed renewal mode'
& $tamper { param($j) $j.Entries[0].Acceptance.RecordToolPin = ('cd' * 32) } "names checklist version '[0-9a-f]{64}', phase A recorded '(cd){32}'" 'A misnaming the record''s checklist version'
& $tamper { param($j) $j.Entries[0].Acceptance.ToolPin = ('cd' * 32) } 'does not name the pinned fs-checklist3d\.ps1' 'A naming another checklist as the version relying on it'
& $tamper { param($j) $j.Entries[1].Reading.R1 = '300' } "phase B's reading: battery status 2 \(charging\) with temperature 300: charging is accepted only below 300" 'B recorded as passed with 300 while charging'
$bad += $script:bad8
$oc1 = Join-Path $c1 'checklist3d.json'; $oc1b = "$oc1.moved"
try { Move-Item -LiteralPath $oc1 -Destination $oc1b
      $v = Test-FsObsChecklist -Path $cl2 -Nonce $hn -NowUtc $D0.AddMinutes(68) -ToolPin $script:clPinReal -BaSummary $ba2 -BfSummary $bf2 -Serial $U1 -LocalDate $script:T3Day
      if ($v.Ok -or $v.Why -notmatch "names the cycle '.*h7-c1', which has no checklist3d\.json on this PC") { $bad += "originating cycle record gone: $($v.Why)" } } finally { Move-Item -LiteralPath $oc1b -Destination $oc1 }
$v = Test-FsObsChecklist -Path $cl2 -Nonce $hn -NowUtc $D0.AddDays(1) -ToolPin $script:clPinReal -BaSummary $ba2 -BfSummary $bf2 -Serial $U1 -LocalDate $script:T3Day
if ($v.Ok) { $bad += 'a next-day attempt accepted' }
Check "H8 J-143 the observer re-checks phase A's reliance before any device query ($($bad.Count) of 13 failed); review of 14107af MINOR-1: refused when the standing record's originating cycle has no checklist3d.json; refused when the standing record changed after phase A, when a carried rehearsal file changed, for an A entry without an acceptance (the pre-J-143 form), claiming another text, claiming a full acceptance without its answers, claiming the removed renewal mode, misnaming the record's or its own checklist version, a carried pass of another day or another tool set; J-145: a B entry recorded as passed with 300 while charging" ($bad.Count -eq 0) ($bad -join ' | ')
# re-acceptance: only the changes are asked
$bad = @()
$Hs2 = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h9-standing2'); $d14 = $script:FsCl3dText.Accept[13]
try { $script:FsCl3dText.Accept[13] = $d14 + ' (changed for the test)'
      $r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h9-c3')) $hn $D0.AddMinutes(70) $Hs2; $s = $script:clSaid -join "`n"
      if (-not ($r.Exit -eq 0 -and $r.Entry.Acceptance.Mode -ceq 'changes' -and (@($script:clAsked) -join '|') -ceq $script:FsCl3dQ.R1 -and $s -match 'CHANGED: WHAT I ACCEPT \(points D1 to D14\)' -and $s -match '- new: D14\.' -and $s -match '\(changed for the test\)' -and
              $s -match '- removed: D14\.' -and $s -notmatch 'D1\. First' -and $s -notmatch 'THE KEYS' -and (Read-FsCl3dStanding $Hs2).Rec.TextSha256 -ceq $r.Entry.TextSha256 -and @(Get-ChildItem (Join-Path $Hs2 'history')).Count -eq 1)) { $bad += "changed D14: $($r.Why) asked $(@($script:clAsked) -join '|')" }
      $r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h9-c3b')) $hn $D0.AddMinutes(71) $Hs2
      if (-not ($r.Exit -eq 0 -and $r.Entry.Acceptance.Mode -ceq 'standing' -and $script:clAsked.Count -eq 0)) { $bad += "after the re-acceptance: $($r.Why)" }
} finally { $script:FsCl3dText.Accept[13] = $d14 }
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h9-c3c')) $hn $D0.AddMinutes(72) $Hs2 @{} 'n'
if (-not ($r.Exit -eq 1 -and $r.Entry.Acceptance.Mode -ceq 'changes' -and $script:clAsked.Count -eq 1)) { $bad += "the newer acceptance (of the changed text) is not relied on for the original text: $($r.Entry.Acceptance.Mode) $($r.Why)" }
$Hs3 = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h9-standing3'); $h9n = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h9-standing3n')
$CLR2 = New-Cl3dRoot
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h9-c4') $CLR2) $hn $D0.AddMinutes(73) $Hs3 @{} 'y' $CLR2
if (-not ($r.Exit -eq 0 -and $r.Entry.Acceptance.Mode -ceq 'standing')) { $bad += "another repository root, the same text: $($r.Why)" }
$pic = Join-Path (Join-Path $CLR2 $script:FsCl3dPreviewDir) 'F-reference-u-i-m-v.png'; [IO.File]::WriteAllBytes($pic, [byte[]](9, 9, 9))
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h9-c5') $CLR2) $hn $D0.AddMinutes(74) $Hs3 @{} 'y' $CLR2; $s = $script:clSaid -join "`n"
if (-not ($r.Exit -eq 0 -and $r.Entry.Acceptance.Mode -ceq 'changes' -and (@($script:clAsked) -join '|') -ceq $script:FsCl3dQ.R1 -and $s -match 'CHANGED: THE PREVIEW PICTURES \(SHA-256\)' -and $s -match 'picture changed, open it again: .*F-reference-u-i-m-v\.png' -and $s -notmatch 'digits-left')) { $bad += "changed picture: $($r.Why)" }
$sb = Get-FsCl3dSha (Join-Path $h9n 'phase-a.json')
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h9-c5n') $CLR2) $hn $D0.AddMinutes(75) $h9n @{} 'n' $CLR2
if (-not ($r.Exit -eq 1 -and $r.Why -match "answer 'n' to: I have read the changes" -and (Get-FsCl3dSha (Join-Path $h9n 'phase-a.json')) -ceq $sb)) { $bad += "n to R1: $($r.Why)" }
# PM decision (J-143 open question 1): a record taken by another checklist version, the same text and pictures word for
# word: NO question; the A entry records the version relying on it (ToolPin) and the record's (RecordToolPin); the record
# is not rewritten; the observer accepts the cycle
$Hs4 = Join-Path $Scratch 'h9-standing4'; $p4 = Join-Path $Hs4 'phase-a.json'
$selfReal = $script:FsCl3dSelf; $selfOld = Join-Path $Scratch 'h9-older-fs-checklist3d.ps1'
[IO.File]::WriteAllText($selfOld, [IO.File]::ReadAllText($selfReal) + "# an older checklist version (fixture)`n"); $pinOld = Get-FsCl3dSha $selfOld
$cx9 = Join-Path $Scratch 'h9-cx'; New-Cl3dCycleFiles $cx9 $D0.AddMinutes(75)
try { $script:FsCl3dSelf = $selfOld; $null = Invoke-Cl3dA $cx9 $hn $D0.AddMinutes(75.5) $Hs4 } finally { $script:FsCl3dSelf = $selfReal }
$s4 = Get-FsCl3dSha $p4
$c6 = New-Cl3dHashesOnly (Join-Path $Scratch 'h9-c6')
$r = Invoke-Cl3dA $c6 $hn $D0.AddMinutes(76) $Hs4; $s = $script:clSaid -join "`n"
$acc6 = $r.Entry.Acceptance
$null = Invoke-FsCl3dPhase -Phase B -Cycle $c6 -Opt @{ LocalDate = $script:T3Day; R1 = '280'; R1Utc = (Format-FsCl3dUtc $D0.AddMinutes(77)); R1Status = '3'; R1Serial = $U1 } -Ask { 'y' } -NowUtc { $D0.AddMinutes(78) } -Say { param($l) }
$ba6 = New-Summary3d (Join-Path $c6 'BA') 'BA' $hn (Format-FsCl3dUtc $D0.AddMinutes(80)) $U1; $bf6 = New-Summary3d (Join-Path $c6 'BF') 'BF' $hn (Format-FsCl3dUtc $D0.AddMinutes(81)) $U1
$null = Invoke-FsCl3dPhase -Phase E -Cycle $c6 -Opt @{ LocalDate = $script:T3Day } -Ask { param($t, $to) 'y' } -NowUtc { $D0.AddMinutes(82) } -Say { param($l) }
$v6 = Test-FsObsChecklist -Path (Join-Path $c6 'checklist3d.json') -Nonce $hn -NowUtc $D0.AddMinutes(83) -ToolPin $script:clPinReal -BaSummary $ba6 -BfSummary $bf6 -Serial $U1 -LocalDate $script:T3Day
if (-not ($r.Exit -eq 0 -and $acc6.Mode -ceq 'standing' -and $script:clAsked.Count -eq 0 -and $acc6.ToolPin -ceq $script:clPinReal -and $acc6.RecordToolPin -ceq $pinOld -and (Read-FsCl3dStanding $Hs4).Rec.ToolPin -ceq $pinOld -and
          (T3Chk $r 'standing') -match 'taken with checklist [0-9a-f]{64}, relied on by this checklist [0-9a-f]{64} \(code change only: no question\)' -and (Get-FsCl3dSha $p4) -ceq $s4 -and
          -not (Test-Path (Join-Path $Hs4 'history')) -and @($script:FsCl3dQ.Keys) -cnotcontains 'R2' -and $s -notmatch 'CHECKLIST PROGRAM IS NEW' -and $v6.Ok)) { $bad += "a code-only change: $($r.Why) | $($v6.Why)" }
Check "H9 J-143 re-acceptance (only the changed text): a changed point D14 shows only that line (new / removed) and asks only R1, then the record holds the new text (the old one kept in history) and the next cycle asks nothing; that newer record is not relied on for another text; the record does not depend on the repository's location (another root: standing); a changed preview picture asks only R1 naming that picture; n to R1 stops and leaves the record unchanged; PM decision: a record taken by another checklist version with the same text and pictures asks NOTHING (no R2 question exists), the A entry records both versions (ToolPin, RecordToolPin), the record is not rewritten, and the observer accepts the cycle ($($bad.Count) failed)" ($bad.Count -eq 0) ($bad -join ' | ')
# forged, damaged or future-dated records are refused (STOP, nothing asked)
$bad = @()
$forge = @(
    @('a block edited (its SHA-256 not updated)', { param($j) $j.Blocks[4].Lines[0] = 'D1. forged' }, 'stored block .* does not match its own SHA-256 \(edited, or not written by the checklist\)'),
    @('a block edited with its SHA-256 updated, the text SHA-256 not', { param($j) $j.Blocks[4].Lines[0] = 'D1. forged'; $j.Blocks[4].Sha256 = Get-FsCl3dBlockSha $j.Blocks[4] }, 'stored text does not match its own text SHA-256'),
    @('another schema', { param($j) $j.Schema = 'frameshift.fs-standing-a3c.v1' }, 'not a frameshift\.fs-standing-a3d\.v1 record'),
    @('a malformed tool pin', { param($j) $j.ToolPin = 'xyz' }, 'tool pin or acceptance time is missing or malformed'),
    @('accepted in the future', { param($j) $j.AcceptedUtc = '2027-01-01T00:00:00.0000000Z' }, 'acceptance time .* is in the future'))
$fi = 0
foreach ($f in $forge) {
    $fi++; $Hf = Copy-Cl3dDir $Hs (Join-Path $Scratch "h10-forged$fi"); $pf0 = Join-Path $Hf 'phase-a.json'
    $jf = [IO.File]::ReadAllText($pf0) | ConvertFrom-Json; & $f[1] $jf; Save-FsCl3dJson $pf0 $jf
    $r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch "h10-c$fi")) $hn $D0.AddMinutes(80) $Hf
    if (-not ($r.Exit -eq 1 -and $script:clAsked.Count -eq 0 -and (T3Fails $r) -ceq 'standing' -and (T3Chk $r 'standing') -match $f[2] -and $r.Why -match 'Nothing is relied on')) { $bad += "$($f[0]): $($r.Why)" }
}
$Hf = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h10-forged-consistent'); $pf0 = Join-Path $Hf 'phase-a.json'
$jf = [IO.File]::ReadAllText($pf0) | ConvertFrom-Json; $jf.Blocks[4].Lines[0] = 'D1. forged'; $jf.Blocks[4].Sha256 = Get-FsCl3dBlockSha $jf.Blocks[4]; $jf.TextSha256 = Get-FsCl3dBlocksSha @($jf.Blocks); Save-FsCl3dJson $pf0 $jf
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h10-cc')) $hn $D0.AddMinutes(81) $Hf
if (-not ($r.Exit -eq 1 -and $script:clAsked.Count -eq 0 -and (T3Chk $r 'standing') -match 'no phase-A PASS entry of its originating cycle .* gave this record')) { $bad += "a re-hashed record of another text (review MINOR-1): $(T3Chk $r 'standing')" }
$Hm = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h10-madeup'); $null = Save-FsCl3dStanding -Dir $Hm -Blocks (Get-FsCl3dAcceptBlocks $CLR) -NowUtc $D0 -LocalDate '2026-10-14' -Cycle (Join-Path $Scratch 'h10-no-such-cycle') -Mode 'full' -ToolPin $script:clPinReal -Asked @('A1', 'A2', 'A3') -Previous $null
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h10-cm')) $hn $D0.AddMinutes(82) $Hm
if (-not ($r.Exit -eq 1 -and $script:clAsked.Count -eq 0 -and (T3Chk $r 'standing') -match "its originating cycle '.*h10-no-such-cycle' has no checklist3d\.json on this PC")) { $bad += "a record made up with Save-FsCl3dStanding: $(T3Chk $r 'standing')" }
$Hm2 = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h10-madeup2'); $null = Save-FsCl3dStanding -Dir $Hm2 -Blocks (Get-FsCl3dAcceptBlocks $CLR) -NowUtc $D0 -LocalDate '2026-10-14' -Cycle $c2 -Mode 'full' -ToolPin $script:clPinReal -Asked @('A1', 'A2', 'A3') -Previous $null
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h10-cm2')) $hn $D0.AddMinutes(83) $Hm2
if (-not ($r.Exit -eq 1 -and (T3Chk $r 'standing') -match 'no phase-A PASS entry of its originating cycle .* gave this record')) { $bad += "a record made up for an existing cycle: $(T3Chk $r 'standing')" }
$Hp = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h10-otherpc'); $pp0 = Join-Path $Hp 'phase-a.json'; $jp0 = [IO.File]::ReadAllText($pp0) | ConvertFrom-Json; $jp0.Cycle = 'D:\other-pc\frameshift\captures\0123456789abcdef'; Save-FsCl3dJson $pp0 $jp0
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h10-cp')) $hn $D0.AddMinutes(84) $Hp
if (-not ($r.Exit -eq 1 -and (T3Chk $r 'standing') -match 'has no checklist3d\.json on this PC \(made up, or copied from another PC without its cycle folder\)')) { $bad += "a record copied from another PC: $(T3Chk $r 'standing')" }
Check "H10 J-143 a forged or damaged standing record is refused (STOP before any question; nothing relied on): a block edited without its hash, a block re-hashed without the text hash, another schema, a malformed tool pin, an acceptance time in the future; review of 14107af MINOR-1: a record re-hashed for another text, made up with Save-FsCl3dStanding (for a missing cycle or an existing one), or copied from another PC is refused: its originating cycle's phase-A PASS entry must name it ($($bad.Count) failed)" ($bad.Count -eq 0) ($bad -join ' | ')
# carry-over: (a) the tools, (b) the day, (c) the speakers, for carried AND fresh passes (review of 14107af MAJOR-1: every
# pass carries its made record); a changed file; an unreadable record; a sound check without a made record
$bad = @()
$CLR3 = New-Cl3dRoot; $Hc = Join-Path $Scratch 'h11-standing'
$ca = Join-Path $Scratch 'h11-ca'; New-Cl3dCycleFiles $ca $D0 $CLR3; $r = Invoke-Cl3dA $ca $hn $D0.AddMinutes(5) $Hc @{} 'y' $CLR3
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-cb') $CLR3) $hn $D0.AddMinutes(10) $Hc @{} 'y' $CLR3
if (-not ($r.Exit -eq 0 -and $r.Entry.Rehearsal.Mode -ceq 'carried' -and $r.Entry.Rehearsal.MadeUtc -ceq (Format-FsCl3dUtc $D0))) { $bad += "baseline: $($r.Why)" }
$cx = Join-Path $Scratch 'h11-cx'; New-Cl3dCycleFiles $cx $D0.AddMinutes(11) $CLR3            # made BEFORE the collector change below
$col = Join-Path $CLR3 'devices\quest3\host\fs-collect3d.ps1'; [IO.File]::AppendAllText($col, "# changed`n")
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-cc') $CLR3) $hn $D0.AddMinutes(15) $Hc @{} 'y' $CLR3
if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'soundcheck,rehearsal,rehearsal-read' -and $script:clAsked.Count -eq 0 -and (T3Chk $r 'rehearsal') -match '^needed: the rehearsal of the garbled path in this cycle .*\(a\) the session/collector tools changed since it was made \(fs-collect3d\.ps1\)' -and (T3Chk $r 'soundcheck') -match '\(a\) .*fs-collect3d\.ps1')) { $bad += "(a) carried, changed collector: $(T3Fails $r) $(T3Chk $r 'rehearsal')" }
$r = Invoke-Cl3dA $cx $hn $D0.AddMinutes(16) $Hc @{} 'y' $CLR3
if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'soundcheck,rehearsal,rehearsal-read' -and (T3Chk $r 'rehearsal') -match "This cycle's own rehearsal .* does not count: \(a\) the session/collector tools changed since it was made" -and (T3Chk $r 'soundcheck') -match "This cycle's own soundcheck .* does not count: \(a\)")) { $bad += "(a) FRESH, made before the collector change (the overnight case): $(T3Fails $r) $(T3Chk $r 'rehearsal')" }
$cd = Join-Path $Scratch 'h11-cd'; New-Cl3dCycleFiles $cd $D0.AddMinutes(16) $CLR3
$r = Invoke-Cl3dA $cd $hn $D0.AddMinutes(20) $Hc @{} 'y' $CLR3
if (-not ($r.Exit -eq 0 -and $r.Entry.Rehearsal.Mode -ceq 'fresh' -and $r.Entry.Acceptance.Mode -ceq 'standing')) { $bad += "(a) new rehearsals in the cycle pass (no question: the text is unchanged): $($r.Why)" }
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-ce')) $hn $D0.AddDays(1) $Hs
if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'soundcheck,rehearsal,rehearsal-read' -and (T3Chk $r 'soundcheck') -match '\(b\) it was made on 2026-10-14, today is 2026-10-15 \(PC local date\)')) { $bad += "(b) carried, new day: $(T3Fails $r) $(T3Chk $r 'soundcheck')" }
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-cf')) $hn $D0.AddMinutes(120) $Hs @{ LocalDate = { param([DateTime]$u) $u.AddHours(-10.5).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } }
if (-not ($r.Exit -eq 1 -and (T3Chk $r 'soundcheck') -match '\(b\) it was made on 2026-10-13, today is 2026-10-14')) { $bad += "(b) the PC's local date, not UTC: $(T3Chk $r 'soundcheck')" }
$ck = Join-Path $Scratch 'h11-ck'; New-Cl3dCycleFiles $ck $D0.AddDays(-5)                     # rehearsal folders copied in 5 days later
$r = Invoke-Cl3dA $ck $hn $D0.AddMinutes(90) (Join-Path $Scratch 'h11-standing-k')
if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'soundcheck,rehearsal,rehearsal-read' -and (T3Chk $r 'rehearsal-read') -match "This cycle's own rehearsal-read .* does not count: \(b\) it was made on 2026-10-09, today is 2026-10-14")) { $bad += "(b) FRESH files made 5 days earlier: $(T3Fails $r) $(T3Chk $r 'rehearsal-read')" }
$Hk = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h11-standing-spk')
$cg = Join-Path $Scratch 'h11-cg'; New-Cl3dCycleFiles $cg $D0.AddMinutes(69)                 # a sound check made BEFORE -NewSpeakers
$r = Invoke-Cl3dA $cg $hn $D0.AddMinutes(70) $Hk @{ NewSpeakers = $true }
if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'soundcheck,rehearsal,rehearsal-read' -and (T3Chk $r 'soundcheck') -match "This cycle's own soundcheck .* does not count: \(c\) new speakers were declared at 2026-10-14T11:10:00\.0000000Z, after it was made" -and $r.Entry.NewSpeakers -and
          @((Read-FsCl3dList (Join-Path $Hk 'speakers.json') $script:FsCl3dSpeakersSchema 'Switches').Items).Count -eq 1)) { $bad += "(c) FRESH, made before -NewSpeakers: $(T3Fails $r) $(T3Chk $r 'soundcheck')" }
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-ch')) $hn $D0.AddMinutes(75) $Hk
if (-not ($r.Exit -eq 1 -and (T3Chk $r 'rehearsal-read') -match '\(c\) new speakers were declared at 2026-10-14T11:10:00\.0000000Z, after it was made')) { $bad += "(c) carried, the next cycle: $(T3Chk $r 'rehearsal-read')" }
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-cn')) $hn $D0.AddMinutes(76) $Hk @{ NewSpeakers = $true }
if (-not ($r.Exit -eq 1 -and (T3Chk $r 'soundcheck') -match 'New speakers were declared \(-NewSpeakers\): nothing earlier carries over')) { $bad += "(c) -NewSpeakers, no file: $(T3Chk $r 'soundcheck')" }
$ci = Join-Path $Scratch 'h11-ci'; New-Cl3dCycleFiles $ci $D0.AddMinutes(78)                 # made after the last declaration (11:16)
$r = Invoke-Cl3dA $ci $hn $D0.AddMinutes(80) $Hk
$rj = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-cj')) $hn $D0.AddMinutes(85) $Hk
if (-not ($r.Exit -eq 0 -and $r.Entry.SoundCheck.Mode -ceq 'fresh' -and $rj.Exit -eq 0 -and $rj.Entry.SoundCheck.Mode -ceq 'carried' -and $rj.Entry.SoundCheck.Cycle -ceq $ci)) { $bad += "(c) passes made after the declaration count and carry over: $($r.Why) | $($rj.Why)" }
$c3c = Join-Path $Scratch 'h11-c3c'; New-Cl3dCycleFiles $c3c $D0.AddMinutes(86)
[IO.File]::WriteAllText((Join-Path $c3c 'soundcheck.json'), "{`"Schema`": `"frameshift.fs-soundcheck3c.v1`", `"Pass`": true, `"EndUtc`": `"$(Format-FsCl3dUtc $D0.AddMinutes(86))`"}`n")
$r = Invoke-Cl3dA $c3c $hn $D0.AddMinutes(87) (Join-Path $Scratch 'h11-standing-3c')
if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'soundcheck' -and (T3Chk $r 'soundcheck') -match 'not a passed stage-3d sound check .*fs-collect3d\.ps1 -S3dSoundCheck')) { $bad += "a fs-session3c.ps1 sound check (no made record): $(T3Fails $r) $(T3Chk $r 'soundcheck')" }
$cw = Join-Path $Scratch 'h11-cw'; New-Cl3dCycleFiles $cw $D0.AddMinutes(88)
$null = Save-Fs3dSummary $CAN['garbled-r3'].R (Join-Path $cw 'rehearsal') $true (New-Cl3dMade $D0.AddMinutes(88) (Get-FsCl3dToolSet $CLR).Sha256 $CLR 'rehearsal-read')
$r = Invoke-Cl3dA $cw $hn $D0.AddMinutes(89) (Join-Path $Scratch 'h11-standing-w')
if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'rehearsal' -and (T3Chk $r 'rehearsal') -match 'not the expected replay \.\.\.\\garbled-r3\\capture\.raw')) { $bad += "the read-path replay in the garbled-path slot: $(T3Fails $r) $(T3Chk $r 'rehearsal')" }
$cv = Join-Path $Scratch 'h11-cv'; New-Cl3dCycleFiles $cv $D0.AddMinutes(88)
$m0 = New-Cl3dMade $D0.AddMinutes(88) (Get-FsCl3dToolSet $CLR).Sha256 $CLR 'rehearsal-read'; $m0.ReplaySha = ('ee' * 32)
$null = Save-Fs3dSummary $CAN['nominal-read'].R (Join-Path $cv 'rehearsal-read') $true $m0
$r = Invoke-Cl3dA $cv $hn $D0.AddMinutes(89) (Join-Path $Scratch 'h11-standing-v')
if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'rehearsal-read' -and (T3Chk $r 'rehearsal-read') -match 'its replay SHA-256 (ee){32} is not the current')) { $bad += "a replay SHA-256 that is not the current replay's: $(T3Fails $r) $(T3Chk $r 'rehearsal-read')" }
$sc1 = Join-Path $c1 'soundcheck.json'; [byte[]]$sc1b = [IO.File]::ReadAllBytes($sc1)
try { [IO.File]::AppendAllText($sc1, ' ')
      $r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-cl')) $hn $D0.AddMinutes(95) $Hs
      if (-not ($r.Exit -eq 1 -and (T3Fails $r) -ceq 'soundcheck' -and (T3Chk $r 'soundcheck') -match 'changed since')) { $bad += "a carried file changed: $(T3Chk $r 'soundcheck')" } } finally { [IO.File]::WriteAllBytes($sc1, $sc1b) }
$Hb = Copy-Cl3dDir $Hs (Join-Path $Scratch 'h11-standing-bad'); [IO.File]::WriteAllText((Join-Path $Hb 'carryover.json'), '{ not json')
$r = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h11-cm')) $hn $D0.AddMinutes(96) $Hb
if (-not ($r.Exit -eq 1 -and (T3Chk $r 'soundcheck') -match 'carry-over record cannot be read')) { $bad += "an unreadable carry-over record: $(T3Chk $r 'soundcheck')" }
Check "H11 J-143 the carry-over rules hold for carried AND fresh passes (review of 14107af MAJOR-1; $($bad.Count) failed): (a) a changed collector file (fs-collect3d.ps1) refuses the carried passes and the cycle's own passes made before the change (the overnight case), and new ones then pass without a question; (b) a new day refuses carried passes (by the PC's local date, not UTC) and rehearsal folders made 5 days earlier; (c) -NewSpeakers refuses the cycle's own sound check made before the declaration and every earlier pass in later cycles, while passes made after it count and carry over; a fs-session3c.ps1 sound check (no made record) does not count; delta review MINOR-1: a rehearsal of the wrong replay, or of a replay whose SHA-256 is not the current one, does not count; a carried file that changed, and an unreadable carry-over record, are refused" ($bad.Count -eq 0) ($bad -join ' | ')
# J-145: phase B and the observer's BA10 at the boundaries
$bad = @()
$cb = New-Cl3dHashesOnly (Join-Path $Scratch 'h12-cb'); $null = Invoke-Cl3dA $cb $hn $D0.AddMinutes(30) $Hs
foreach ($bc in @(@('299', '2', 0), @('300', '2', 1), @('100', '2', 0), @('349', '3', 0), @('349', '4', 0), @('349', '5', 0), @('350', '3', 1), @('350', '4', 1), @('350', '5', 1), @('250', '1', 1), @('349', '2', 1))) {
    $rbx = Invoke-FsCl3dPhase -Phase B -Cycle $cb -Opt @{ LocalDate = $script:T3Day; R1 = $bc[0]; R1Utc = (Format-FsCl3dUtc $D0.AddMinutes(31)); R1Status = $bc[1]; R1Serial = $U1 } -Ask { 'y' } -NowUtc { $D0.AddMinutes(32) } -Say { param($l) }
    $bat = @($rbx.Entry.Checks | Where-Object { $_.Name -ceq 'battery-rule' })[0]; $rng = @($rbx.Entry.Checks | Where-Object { $_.Name -ceq 'range-100-349' })[0]
    if ($rbx.Exit -ne $bc[2] -or ($bc[2] -eq 1 -and $bc[0] -cne '350' -and $bat.Ok) -or ($bc[0] -ceq '350' -and $rng.Ok)) { $bad += "B $($bc[0])/$($bc[1]): exit $($rbx.Exit) $($rbx.Why)" }
    $ow = Test-FsObsBatteryRule $bc[0] $bc[1]
    if ($bc[0] -cne '350' -and ($null -eq $ow) -ne ($bc[2] -eq 0)) { $bad += "observer rule $($bc[0])/$($bc[1]): '$ow'" }
}
$batSave = $script:T3Bat
try {
    foreach ($bc in @(@('299', '2', $true), @('300', '2', $false), @('349', '3', $true), @('349', '5', $true), @('350', '4', $false), @('300', '1', $false))) {
        $script:T3Bat = "Current Battery Service state:`n  AC powered: true`n  status: $($bc[1])`n  level: 97`n  temperature: $($bc[0])"
        $bs = New-Summary3d (Join-Path $Scratch "h12-ba-$($bc[0])-$($bc[1])") 'BA' $hn '2026-10-14T10:00:00.0000000Z' $U1
        $t10 = Test-FsObsBa10 $bs
        if ($t10.Ok -ne $bc[2] -or ($bc[0] -ceq '300' -and $bc[1] -ceq '2' -and $t10.Why -notmatch 'charging is accepted only below 300')) { $bad += "BA10 $($bc[0])/$($bc[1]): $($t10.Why)" }
    }
} finally { $script:T3Bat = $batSave }
Check "H12 J-145 charging below 30.0 deg C ($($bad.Count) failed): phase B accepts 299 and 100 with status 2 and refuses 300 and 349 with status 2; 349 with status 3, 4, 5 passes and 350 fails; status 1 fails; the observer's rule and its BA10 cross-check give the same answers (BA10 299/2 accepted, 300/2 refused naming the 300 limit, 349/3 and 349/5 accepted, 350/4 and 300/1 refused); the text, unit, age and first-BA rules are unchanged (G, H3)" ($bad.Count -eq 0) ($bad -join ' | ')
# J-143 (a): the tool set is fs-session3c.ps1 and fs-collect3d.ps1 with everything they dot-source (read from the sources), and the two rehearsal replays
$seen = @{}; $todo = New-Object System.Collections.Generic.Queue[string]
foreach ($f in 'devices\quest3\host\fs-session3c.ps1', 'devices\quest3\host\fs-collect3d.ps1') { $todo.Enqueue($f) }
while ($todo.Count) {
    $f = $todo.Dequeue(); if ($seen.ContainsKey($f)) { continue }; $seen[$f] = $true
    $src = [IO.File]::ReadAllText((Join-Path $T3Root $f)); $dir = Split-Path -Parent (Join-Path $T3Root $f)
    $code0 = (($src -split "`r?`n") | ForEach-Object { if ($_ -match '^\s*#') { '' } else { $_ } }) -join "`n"
    foreach ($m in [regex]::Matches($code0, '(?:^|[\s{;])\. \(Join-Path \$PSScriptRoot ''([^'']+)''\)')) { $todo.Enqueue([IO.Path]::GetFullPath((Join-Path $dir $m.Groups[1].Value)).Substring($T3Root.TrimEnd('\').Length + 1)) }
}
$closure = @($seen.Keys | Sort-Object); $listed = @($script:FsCl3dToolSetFiles | Where-Object { $_ -notmatch '\\fixtures\\' } | Sort-Object)
$fx = @($script:FsCl3dToolSetFiles | Where-Object { $_ -match '\\fixtures\\' })
$wkx = [IO.File]::ReadAllText((Join-Path $T3Q3 'stage3d\WALKTHROUGH.md'))
Check "H13 J-143 (a) the session/collector tool set equals the dot-source closure of fs-session3c.ps1 and fs-collect3d.ps1 read from the sources ($($closure.Count) files), plus the two rehearsal replays (capture.raw and .idx) the WALKTHROUGH names, all present in this tree" `
    (($closure -join ';') -ceq ($listed -join ';') -and $fx.Count -eq 4 -and @($fx | Where-Object { -not (Test-Path -LiteralPath (Join-Path $T3Root $_)) }).Count -eq 0 -and $wkx.Contains('fixtures\stage3d\replay\garbled-r3\capture.raw') -and $wkx.Contains('fixtures\stage3d\replay\nominal-read\capture.raw')) "closure: $($closure -join ', ') | listed: $($listed -join ', ')"
# review of 14107af MAJOR-2 (phase A holds for its own PC day only: B, E and the observer refuse it on a new day) and
# MINOR-2 (phase A refuses to run again after a B PASS on the same day, without writing an entry)
$bad = @()
$N0 = [DateTime]::Parse('2026-10-14T23:55:00Z').ToUniversalTime()
$cn = New-Cl3dHashesOnly (Join-Path $Scratch 'h14-cn'); $cnj = Join-Path $cn 'checklist3d.json'
$qa = Invoke-Cl3dA $cn $hn $N0 $Hs
$qb = Invoke-FsCl3dPhase -Phase B -Cycle $cn -Opt @{ LocalDate = $script:T3Day; R1 = '280'; R1Utc = (Format-FsCl3dUtc $N0.AddMinutes(1)); R1Status = '3'; R1Serial = $U1 } -Ask { 'y' } -NowUtc { $N0.AddMinutes(1.5) } -Say { param($l) }
$ba14 = New-Summary3d (Join-Path $cn 'BA') 'BA' $hn (Format-FsCl3dUtc $N0.AddMinutes(2)) $U1; $bf14 = New-Summary3d (Join-Path $cn 'BF') 'BF' $hn (Format-FsCl3dUtc $N0.AddMinutes(3)) $U1
$qe = Invoke-FsCl3dPhase -Phase E -Cycle $cn -Opt @{ LocalDate = $script:T3Day } -Ask { param($t, $to) 'y' } -NowUtc { $N0.AddMinutes(4) } -Say { param($l) }
if (-not ($qa.Exit -eq 0 -and $qa.Entry.Acceptance.Mode -ceq 'standing' -and $qb.Exit -eq 0 -and $qe.Exit -eq 0)) { $bad += "setup: $($qa.Why) | $($qb.Why) | $($qe.Why)" }
$v = Test-FsObsChecklist -Path $cnj -Nonce $hn -NowUtc $N0.AddMinutes(4.5) -ToolPin $script:clPinReal -BaSummary $ba14 -BfSummary $bf14 -Serial $U1 -LocalDate $script:T3Day
if (-not $v.Ok) { $bad += "the same day (23:59:30): $($v.Why)" }
$v = Test-FsObsChecklist -Path $cnj -Nonce $hn -NowUtc $N0.AddMinutes(6) -ToolPin $script:clPinReal -BaSummary $ba14 -BfSummary $bf14 -Serial $U1 -LocalDate $script:T3Day
if ($v.Ok -or $v.Why -notmatch "new day: this cycle's phase A is from 2026-10-14, today is 2026-10-15 \(PC local date\): run step 2 \(phase A\) again") { $bad += "the attempt after midnight (A of 23:55): $($v.Why)" }
$n14 = @((Get-Content -Raw $cnj | ConvertFrom-Json).Entries).Count
$qa2 = Invoke-Cl3dA $cn $hn $N0.AddMinutes(4.7) $Hs
if (-not ($qa2.Exit -eq 1 -and $qa2.Why -match 'phase B has passed after it: running phase A again now would break the A, B, E order' -and $null -eq $qa2.Entry -and @((Get-Content -Raw $cnj | ConvertFrom-Json).Entries).Count -eq $n14)) { $bad += "phase A again after B, the same day: $($qa2.Why)" }
$qb2 = Invoke-FsCl3dPhase -Phase B -Cycle $cn -Opt @{ LocalDate = $script:T3Day; R1 = '280'; R1Utc = (Format-FsCl3dUtc $N0.AddMinutes(9)); R1Status = '3'; R1Serial = $U1 } -Ask { 'y' } -NowUtc { $N0.AddMinutes(10) } -Say { param($l) }
$qe2 = Invoke-FsCl3dPhase -Phase E -Cycle $cn -Opt @{ LocalDate = $script:T3Day } -Ask { param($t, $to) 'y' } -NowUtc { $N0.AddMinutes(11) } -Say { param($l) }
if (-not ($qb2.Exit -eq 1 -and $qb2.Why -match "new day: this cycle's phase A is from 2026-10-14, today is 2026-10-15" -and $qe2.Exit -eq 1 -and $qe2.Why -match 'new day: .*run step 2 \(phase A\) again')) { $bad += "B / E after midnight: $($qb2.Why) | $($qe2.Why)" }
$qa3 = Invoke-Cl3dA $cn $hn $N0.AddMinutes(12) $Hs
if (-not ($qa3.Exit -eq 1 -and $null -ne $qa3.Entry -and $qa3.Why -notmatch 'break the A, B, E order' -and (T3Chk $qa3 'soundcheck') -match '\(b\) it was made on 2026-10-14, today is 2026-10-15')) { $bad += "phase A on the new day runs (and asks for new passes): $($qa3.Why)" }
Check "H14 review of 14107af MAJOR-2 / MINOR-2 ($($bad.Count) failed): a cycle whose phase A ran at 23:55 is accepted by the observer the same day and refused after midnight (new day: run step 2 again); phases B and E refuse after midnight too; on the same day, phase A run again after a B PASS is refused without writing an entry (the A, B, E order, J-140); on the new day phase A runs again and asks for a new sound check and rehearsals" ($bad.Count -eq 0) ($bad -join ' | ')
# review of 14107af MAJOR-1, the writer side: fs-collect3d.ps1 records when and with which tools a rehearsal or sound
# check was made (fs-carry3d.ps1); a live summary has no such line; -S3dSoundCheck takes only -S3dOutDir
$bad = @()
$mdir = Join-Path $Scratch 'h15-made'; $null = New-Item -ItemType Directory -Force -Path $mdir
$rpl15 = Join-Path $T3Fix 'replay\nominal-read\capture.raw'
$t0 = [DateTime]::UtcNow; $null = Save-Fs3dSummary $CAN['nominal-read'].R $mdir $true @{ Replay = $rpl15 }; $t1 = [DateTime]::UtcNow
$mr15 = Read-FsCarry3dMade 'rehearsal-read' (Join-Path $mdir 'summary.txt')
if (-not ($mr15.Ok -and $mr15.ToolSetSha256 -ceq (Get-FsCarry3dToolSet).Sha256 -and $mr15.MadeUtc -ge $t0.AddSeconds(-1) -and $mr15.MadeUtc -le $t1.AddSeconds(1) -and
          $mr15.ReplayPath -ceq $rpl15 -and $mr15.ReplaySha256 -ceq (Get-FsCl3dSha $rpl15) -and $null -eq (Test-FsCl3dReplay $mr15 'rehearsal-read' $T3Root) -and (Test-FsCl3dReplay $mr15 'rehearsal' $T3Root) -match 'not the expected replay')) { $bad += "a rehearsal summary's made record: $($mr15.Why) $($mr15.ReplayPath)" }
$null = Save-Fs3dSummary $CAN['nominal-read'].R $mdir $true
if ((Read-FsCarry3dMade 'rehearsal-read' (Join-Path $mdir 'summary.txt')).Ok) { $bad += 'a summary that names no replay is accepted' }
if (-not ($cs0 = [IO.File]::ReadAllText((Join-Path $T3Dir 'fs-collect3d.ps1'))).Contains('$sp = Save-Fs3dSummary $r $od $true @{ Replay = $rp }')) { $bad += 'the rehearsal CLI does not record its replay' }
if (((Write-Fs3dSummary $CAN['nominal-read'].R $false) -join "`n") -match 'REHEARSAL MADE') { $bad += 'a live summary carries a made line' }
if ((Get-FsCarry3dToolSet $T3Root).Sha256 -cne (Get-FsCl3dToolSet $T3Root).Sha256 -or @($script:FsCl3dToolSetFiles) -cnotcontains 'devices\quest3\host\fs-carry3d.ps1') { $bad += 'the checklist and the collector hash different tool sets' }
$cs = [IO.File]::ReadAllText((Join-Path $T3Dir 'fs-collect3d.ps1'))
if (-not ($cs -match '\$doc\.Schema = \$script:FsCarry3dSoundSchema; \$doc\.Stage = ''3d''; \$doc\.MadeUtc = \[DateTime\]::UtcNow\.ToString\(''o''\); \$doc\.ToolSetSha256 = \(Get-FsCarry3dToolSet\)\.Sha256' -and $cs -match 'Invoke-Fs3cSoundCheck -X \$xx -Sounds \$snd')) { $bad += 'fs-collect3d.ps1 -S3dSoundCheck does not write the stage-3d schema with its made record' }
$o15 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $T3Dir 'fs-collect3d.ps1') -S3dSoundCheck -S3dOutDir (Join-Path $Scratch 'h15-sc') -S3dReplay 'x' | ForEach-Object { [string]$_ }); $c15 = $LASTEXITCODE
if (-not ($c15 -eq 20 -and ($o15 -join ' ') -match 'refused: -S3dSoundCheck takes only -S3dOutDir' -and -not (Test-Path (Join-Path $Scratch 'h15-sc\soundcheck.json')))) { $bad += "CLI: exit $c15 $($o15 -join ' / ')" }
$sj15 = Join-Path $Scratch 'h15-sound.json'; New-Cl3dSoundJson $sj15 $D0 ('ab' * 32); $ms15 = Read-FsCarry3dMade 'soundcheck' $sj15
if (-not ($ms15.Ok -and $ms15.ToolSetSha256 -ceq ('ab' * 32) -and $ms15.MadeUtc -eq $D0)) { $bad += "a stage-3d soundcheck.json: $($ms15.Why)" }
Check "H15 review of 14107af MAJOR-1, the writer: a rehearsal summary (fs-collect3d.ps1) ends with 'REHEARSAL MADE: <utc> with tool set <sha256> replay <sha256> <path>' (now, this tree's tool set = the checklist's; delta review MINOR-1: the replay given by the rehearsal CLI, checked against the expected replay of its kind; a summary naming no replay does not count); a live summary has none; -S3dSoundCheck writes soundcheck.json with the stage-3d schema, MadeUtc and ToolSetSha256 (static: the console sound check needs a person) and takes only -S3dOutDir (exit 20, nothing written) ($($bad.Count) failed)" ($bad.Count -eq 0) ($bad -join ' | ')
# delta review of 6f2973f, MAJOR-1: a second phase A in the ORIGINATING cycle (mode standing, naming the same record) must not
# become the record's "origin": (1) a next-day resume in the same cycle, (2) phase A run twice before B
$bad = @()
$D1 = $D0.AddDays(1)
function Test-H16Cycle([string]$cyc, [DateTime]$at, [string]$sd) {
    # B, BA/BF, E and the observer on a cycle whose phase A passed at $at
    $null = Invoke-FsCl3dPhase -Phase B -Cycle $cyc -Opt @{ LocalDate = $script:T3Day; R1 = '280'; R1Utc = (Format-FsCl3dUtc $at.AddMinutes(1)); R1Status = '3'; R1Serial = $U1 } -Ask { 'y' } -NowUtc { $at.AddMinutes(1.5) }.GetNewClosure() -Say { param($l) }
    $baH = New-Summary3d (Join-Path $cyc 'BA') 'BA' $hn (Format-FsCl3dUtc $at.AddMinutes(2)) $U1; $bfH = New-Summary3d (Join-Path $cyc 'BF') 'BF' $hn (Format-FsCl3dUtc $at.AddMinutes(3)) $U1
    $null = Invoke-FsCl3dPhase -Phase E -Cycle $cyc -Opt @{ LocalDate = $script:T3Day } -Ask { param($t, $to) 'y' } -NowUtc { $at.AddMinutes(4) }.GetNewClosure() -Say { param($l) }
    Test-FsObsChecklist -Path (Join-Path $cyc 'checklist3d.json') -Nonce $hn -NowUtc $at.AddMinutes(4.5) -ToolPin $script:clPinReal -BaSummary $baH -BfSummary $bfH -Serial $U1 -LocalDate $script:T3Day
}
# (1) day 2 in the same cycle
$Hg = Join-Path $Scratch 'h16-standing1'; $g1 = Join-Path $Scratch 'h16-g1'
New-Cl3dCycleFiles $g1 $D0; $qa = Invoke-Cl3dA $g1 $hn $D0.AddMinutes(5) $Hg
New-Cl3dCycleFiles $g1 $D1; $qb = Invoke-Cl3dA $g1 $hn $D1.AddMinutes(5) $Hg; $nb = $script:clAsked.Count
$vg = Test-H16Cycle $g1 $D1.AddMinutes(5) $Hg
$qc = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h16-g2')) $hn $D1.AddMinutes(20) $Hg
$lastG = @((Get-Content -Raw (Join-Path $g1 'checklist3d.json') | ConvertFrom-Json).Entries | Where-Object { $_.Phase -ceq 'A' })[-1]
if (-not ($qa.Exit -eq 0 -and $qa.Entry.Acceptance.Mode -ceq 'full' -and $qb.Exit -eq 0 -and $qb.Entry.Acceptance.Mode -ceq 'standing' -and $nb -eq 0 -and $lastG.Acceptance.Mode -ceq 'standing' -and
          $lastG.Acceptance.StandingSha256 -ceq $qa.Entry.Acceptance.StandingSha256 -and $vg.Ok -and $qc.Exit -eq 0 -and $qc.Entry.Acceptance.Mode -ceq 'standing')) { $bad += "(1) day 2 in the originating cycle: $($qb.Why) | $($vg.Why) | $($qc.Why)" }
# (2) phase A twice before B in the originating cycle
$He = Join-Path $Scratch 'h16-standing2'; $e1 = Join-Path $Scratch 'h16-e1'
New-Cl3dCycleFiles $e1 $D0; $qa = Invoke-Cl3dA $e1 $hn $D0.AddMinutes(5) $He
$qb = Invoke-Cl3dA $e1 $hn $D0.AddMinutes(6) $He; $nb = $script:clAsked.Count
$ve = Test-H16Cycle $e1 $D0.AddMinutes(6) $He
$qc = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h16-e2')) $hn $D0.AddMinutes(20) $He
if (-not ($qa.Exit -eq 0 -and $qa.Entry.Acceptance.Mode -ceq 'full' -and $qb.Exit -eq 0 -and $qb.Entry.Acceptance.Mode -ceq 'standing' -and $nb -eq 0 -and $ve.Ok -and $qc.Exit -eq 0 -and $qc.Entry.Acceptance.Mode -ceq 'standing')) { $bad += "(2) A twice before B: $($qb.Why) | $($ve.Why) | $($qc.Why)" }
# the link still needs an entry that GAVE it: with the full entry's mode rewritten to standing, phase A and the observer refuse
$gj = Join-Path $e1 'checklist3d.json'; [byte[]]$gjb = [IO.File]::ReadAllBytes($gj)
try { $j16 = [IO.File]::ReadAllText($gj) | ConvertFrom-Json; $j16.Entries[0].Acceptance.Mode = 'standing'; [IO.File]::WriteAllText($gj, ($j16 | ConvertTo-Json -Depth 10))
      $qd = Invoke-Cl3dA (New-Cl3dHashesOnly (Join-Path $Scratch 'h16-e3')) $hn $D0.AddMinutes(25) $He
      if (-not ($qd.Exit -eq 1 -and (T3Chk $qd 'standing') -match 'no phase-A PASS entry of its originating cycle .* gave this record')) { $bad += "no entry gave it: $(T3Chk $qd 'standing')" } } finally { [IO.File]::WriteAllBytes($gj, $gjb) }
Check "H16 delta review of 6f2973f MAJOR-1 ($($bad.Count) failed): a second phase A in the originating cycle (mode standing, naming the same record) is not taken as the record's origin: (1) a next-day resume in the same cycle (new passes, phase A again: no question) and (2) phase A run twice before B both lead to an attempt the observer accepts, and a later cycle relies on the record (no STOP); with no entry that gave the acceptance (full or changes), the record is refused" ($bad.Count -eq 0) ($bad -join ' | ')
$sg = Join-Path $T3Q3 'SIGNOFF-3d.md'; $wk = Join-Path $T3Q3 'stage3d\WALKTHROUGH.md'
if ((Test-Path -LiteralPath $sg) -and (Test-Path -LiteralPath $wk)) {
    $sgt = [IO.File]::ReadAllText($sg); $wkt = [IO.File]::ReadAllText($wk)
    $norm = { param($t) (([string]$t -replace '\s+', ' ').Trim()) }
    $sgn = & $norm $sgt
    $allTexts = @($script:FsCl3dQ.Values) + (Get-FsCl3dPreviewLines '<repository>') + $script:FsCl3dText.KeyLines + $script:FsCl3dText.Accept + $script:FsCl3dText.Presence + $script:FsCl3dText.After
    $miss = @($allTexts | Where-Object { $sgn.IndexOf((& $norm $_)) -lt 0 })
    Check "H4 SIGNOFF-3d.md carries every line fs-checklist3d prints, verbatim ($($allTexts.Count) lines)" ($miss.Count -eq 0) ($miss -join ' | ')
    $rows = Read-FsCl3dPinTable $sg
    $cmdS = [regex]::Match($sgt, '`(Get-FileHash -Algorithm SHA256 -LiteralPath [^`]+)`').Groups[1].Value
    $cmdW = [regex]::Match($wkt, '`(Get-FileHash -Algorithm SHA256 -LiteralPath [^`]+)`').Groups[1].Value
    $lst = { param($c) @(([regex]::Match($c, '-LiteralPath (.+?) \|')).Groups[1].Value -split ',\s*' | ForEach-Object { $_.Trim() } | Sort-Object) -join ';' }
    $rc = Join-Path $Scratch 'cl3d-real-cycle'; $null = New-Item -ItemType Directory -Force -Path $rc
    Push-Location -LiteralPath $T3Root; try { $null = Invoke-Expression ($cmdS.Replace('<cycle>', $rc)) } finally { Pop-Location }
    $hp = Test-FsCl3dHostPins -HashesFile (Join-Path $rc 'host-hashes.txt') -SignoffFile $sg -Root $T3Root
    Check 'H5 the real SIGNOFF-3d pin table: the literal Get-FileHash command (SIGNOFF-3d and WALKTHROUGH, the same file list = the table) gives a host-hashes.txt that the checklist accepts (every working file equals its pin); the observer reads fs-checklist3d.ps1''s pin from it' `
        ($rows.Count -ge 15 -and $cmdS -ceq $cmdW -and (& $lst $cmdS) -ceq ((@($rows | ForEach-Object { $_.Rel } | Sort-Object)) -join ';') -and $hp.Ok -and (Get-FsObsChecklistPin $T3Q3) -ceq $script:clPinReal) "$($hp.Why) | $(& $lst $cmdS)"
    $order = @('fs-checklist3d.ps1 -Phase A', 'fs-collect3d.ps1 -S3dSoundCheck -S3dOutDir <cycle>', 'fs-collect3d.ps1 -S3dReplay', 'dumpsys battery; [DateTime]::UtcNow', 'fs-checklist3d.ps1 -Phase B', 'fs-capture.ps1 -Phase BA', 'fs-capture.ps1 -Phase BF', 'fs-checklist3d.ps1 -Phase E', 'fs-observe3d.ps1 -Image <img>\boot-stage3d.img -Serial <serial> -ConfirmNonce', 'fs-capture.ps1 -Phase AF', 'fs-classify3d.ps1 -C3dDir')
    $idx = @($order | ForEach-Object { $wkt.IndexOf($_) })
    $mono = $true; for ($i = 1; $i -lt $idx.Count; $i++) { if ($idx[$i] -le $idx[$i - 1]) { $mono = $false } }
    Check 'H6 WALKTHROUGH (stage 3d): the steps in order (A at the start of the cycle, then only if A names them the sound check and the rehearsals, the reading with the PC''s UTC, B with -R1Serial, BA and BF with -Serial and commands-userbuild.tsv, E, the attempt with -Serial, AF, the classifier), one step at a time; J-143: the PM''s short order reading, B, BA/BF, E, attempt, -NewSpeakers; J-145: status 2 below 300; both units; a new nonce per run (fs-nonceonly3d.ps1)' `
        ($idx -notcontains -1 -and $mono -and $wkt -match 'the temperature reading .{1,3} B .{1,3} BA and BF .{1,3} E .{1,3} the attempt' -and $wkt -match '-NewSpeakers' -and $wkt -match 'do \*\*not\*\* repeat it' -and $wkt -match 'after a stand-down into a new day, start again at step 2' -and $wkt -notmatch 'fs-session3c\.ps1 -SoundCheck' -and $wkt -match 'Only if step 2 names it: the sound check' -and
         $wkt -match '`status: 2` \(charging\) only with the temperature below 300' -and $wkt -match 'Unit 1 \(`QUEST3UNIT1`\) or Unit 2' -and $wkt -match 'fs-nonceonly3d\.ps1' -and $wkt -match '-CommandsFile devices\\quest3\\host\\before-after\\commands-userbuild\.tsv' -and $wkt -match '-R1Serial <serial>') "$($order | ForEach-Object { "$_=$($wkt.IndexOf($_))" })"
} else { Skip 'H4-H6 SIGNOFF-3d / WALKTHROUGH' 'not present' }

# ------------------------------------------------------------------ I --------
Say '== I. timing (README 6.9)'
$cf = New-Fs3dCfg -NonceX ('0' * 16)
Check 'I1 New-Fs3dCfg: Stage 3d, exp s3d_<ph>, the v0.7.1 pin, kernel 5.10.246-gd7102a837402, DEADLINE 200 / ACK 150; guards G 34/68/82/64 unchanged (H_r1 20 s holds the reset question)' `
    ($cf.Stage -ceq '3d' -and $cf.Exp['r1'] -ceq 's3d_r1' -and $cf.PatternPin -ceq $script:S3dPatternPin -and $cf.Kernel -ceq '5.10.246-gd7102a837402' -and $cf.DeviceDeadlineSec -eq 200 -and $cf.AckWindowSec -eq 150 -and
     "$($cf.GuardSec['p0'])/$($cf.GuardSec['r1'])/$($cf.GuardSec['r2'])/$($cf.GuardSec['r3'])" -ceq '34/68/82/64')
$py = $null; foreach ($cand0 in 'python3', 'python', 'py') { try { $null = & $cand0 --version 2>&1; if ($LASTEXITCODE -eq 0) { $py = $cand0; break } } catch {} }
if ($py) {
    $env:PYTHONIOENCODING = 'utf-8'
    $ct = @(& $py -I -B (Join-Path $T3Q3 'stage3d\tools\check-timing-3d.py') --q3 $T3Q3 2>&1 | ForEach-Object { [string]$_ }); $cc = $LASTEXITCODE
    Check 'I2 stage3d/tools/check-timing-3d.py on this tree: TIMING 3D CONSISTENT, the host items located in fs-collect3d.ps1 / fs-observe3d.ps1 (M1-M3, guards), nothing PENDING' `
        ($cc -eq 0 -and $ct[-1] -ceq 'TIMING 3D: CONSISTENT' -and @($ct | Where-Object { $_ -match 'fs-collect3d\.ps1, fs-observe3d\.ps1' }).Count -eq 1 -and @($ct | Where-Object { $_ -match '^\s+FAIL' }).Count -eq 0) "exit $cc $($ct[-1])"
} else { Skip 'I2 check-timing-3d.py' 'no python' }

# ------------------------------------------------------------------ J --------
Say '== J. M4: the parameter scope'
$pe = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $T3Dir 'fs-collect3d.ps1') -S3dParamEcho -S3dNonce 'abcdef0123456789' -S3dHostMarginSec 9 -S3dRehearsal
$pj = ($pe -join '') | ConvertFrom-Json
Check 'J1 fs-collect3d.ps1 -S3dParamEcho: the S3d arguments survive the dot-source of fs-collect3c.ps1 (whose S3c parameters bind in the same scope): snapshot and live values equal; stage 3d, exp s3d_r1, the v0.7.1 pin, fs-phase verb' `
    ($pj.Snapshot.S3dNonce -ceq 'abcdef0123456789' -and $pj.Live.S3dNonce -ceq 'abcdef0123456789' -and $pj.Snapshot.S3dHostMarginSec -eq 9 -and $pj.Live.S3dHostMarginSec -eq 9 -and $pj.Snapshot.S3dRehearsal -eq $true -and
     $pj.StageLabel -ceq '3d' -and $pj.Exp -ceq 's3d_r1' -and $pj.Pin -ceq $script:S3dPatternPin -and $pj.FsPhaseVerb -ceq '^(p0|r1|r2|r3) [0-9a-f]{32} [0-9a-f]{16}\z') ($pe -join '')
$srcs = @('fs-collect3d.ps1', 'fs-classify3d.ps1', 'fs-session3d.ps1', 'fs-observe3d.ps1', 'fs-checklist3d.ps1', 'fs-nonceonly3d.ps1', 'fs-carry3d.ps1') | ForEach-Object { [IO.File]::ReadAllText((Join-Path $T3Dir $_)) }
Check 'J2 the stage-3d host files are ASCII with LF endings; none runs adb, su, adb root or touches /persist' `
    (@($srcs | Where-Object { $_ -match '[^\x00-\x7f]' -or $_.IndexOf("`r") -ge 0 }).Count -eq 0 -and @($srcs | Where-Object { $_ -match 'adb\.exe|''adb''|\bsu 0\b|adb root|/persist' }).Count -eq 0)

# ------------------------------------------------------------------ K --------
Say '== K. one nonce per run: fs-nonceonly3d.ps1 (review 2 MAJOR-2: both images opened)'
$wslOk = $false; try { $null = & wsl.exe -e sh -c 'command -v lz4 >/dev/null'; $wslOk = ($LASTEXITCODE -eq 0) } catch { }
if ((Test-Path -LiteralPath (Join-Path $cand 'boot-stage3d.img')) -and $wslOk) {
    # REBUILDS of the real candidate (read only): its ramdisk unpacked here, the nonce put into /init (same size), recompressed
    # with WSL `lz4 -l -9` (the builder's command), the image re-assembled (header ramdisk size, the kernel and the tail
    # copied), and the record files re-recorded as build-image.sh records them. A mutation hook changes the cpio, the image or
    # the directory to make each negative.
    $kRef = Read-FsNoBootImage (Join-Path $cand 'boot-stage3d.img')
    # the reference's nonce and image hash, read from its MANIFEST (G6 checks both against the reviewed-candidate table)
    $kRefNonce = [regex]::Match([IO.File]::ReadAllText((Join-Path $cand 'MANIFEST.txt')), '(?m)^nonce:\s+([0-9a-f]{16})\s').Groups[1].Value
    $kS8 = $script:FsNoReviewedSha.Substring(0, 8)
    $kWork = Join-Path $Scratch 'k3d-work'; $null = New-Item -ItemType Directory -Force -Path $kWork
    $toWsl = { param([string]$pth) $f = [IO.Path]::GetFullPath($pth); '/mnt/' + $f.Substring(0, 1).ToLowerInvariant() + $f.Substring(2).Replace('\', '/') }
    $lz4 = { param([string]$inp, [string]$outp) $null = & wsl.exe -e lz4 -l -9 -q -f (& $toWsl $inp) (& $toWsl $outp); if ($LASTEXITCODE -ne 0) { throw "wsl lz4 failed ($LASTEXITCODE)" } }
    $l1 = [Text.Encoding]::GetEncoding(28591)
    $hx = { param([byte[]]$b, [int]$o = 0, [int]$n = -1) Get-FsNoBytesSha $b $o $n }
    $kEnt = { param([string]$name) @($kRef.Entries | Where-Object { $_.Name -ceq $name })[0] }
    function New-K3dRebuild([string]$nonceX, [scriptblock]$cpioMut = $null, [scriptblock]$imgMut = $null, [scriptblock]$dirMut = $null, [string]$root = (Join-Path $Scratch 'k3d')) {
        $d = Join-Path $root "20261013T120000Z-$nonceX"; $null = New-Item -ItemType Directory -Force -Path $d
        [byte[]]$cp = $kRef.Cpio.Clone()
        $ie = & $kEnt 'init'
        $ib = $l1.GetBytes($l1.GetString($cp, [int]$ie.Off, [int]$ie.Size).Replace($kRefNonce, $nonceX)); [Array]::Copy($ib, 0, $cp, [int]$ie.Off, $ib.Length)
        if ($cpioMut) { $r0 = & $cpioMut $cp; if ($r0 -is [byte[]]) { $cp = $r0 } }
        $ci = Join-Path $kWork "$nonceX.cpio"; $co = Join-Path $kWork "$nonceX.lz4"; [IO.File]::WriteAllBytes($ci, $cp); & $lz4 $ci $co
        [byte[]]$lz = [IO.File]::ReadAllBytes($co)
        $pg = 4096; $rp = [long]([Math]::Ceiling($lz.Length / [double]$pg) * $pg); $tail = $kRef.Bytes.Length - $kRef.SigOff
        [byte[]]$img = New-Object byte[] ([int]($kRef.RamdiskOff + $rp + $tail))
        [Array]::Copy($kRef.Bytes, 0, $img, 0, [int]$kRef.RamdiskOff)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$lz.Length), 0, $img, 12, 4)
        [Array]::Copy($lz, 0, $img, [int]$kRef.RamdiskOff, $lz.Length)
        if ($tail -gt 0) { [Array]::Copy($kRef.Bytes, [int]$kRef.SigOff, $img, [int]($kRef.RamdiskOff + $rp), [int]$tail) }
        if ($imgMut) { $r1 = & $imgMut $img $lz.Length; if ($r1 -is [byte[]]) { $img = $r1 } }
        $ip = Join-Path $d 'boot-stage3d.img'; [IO.File]::WriteAllBytes($ip, $img)
        foreach ($f in 'MANIFEST.txt', 'ramdisk.sha256', 'ramdisk.list', 'applets.txt', 'avb-check.txt', 'module-list-check.txt', 'gitcheck.txt', 'ramdisk-scan.txt', 'header-diff.txt') { Copy-Item -LiteralPath (Join-Path $cand $f) -Destination (Join-Path $d $f) }
        # re-record as the builder does: the nonce, the build time, the image, the cpio and lz4, every ramdisk file line, ramdisk.sha256, header-diff
        $m = [IO.File]::ReadAllText((Join-Path $d 'MANIFEST.txt'), [Text.Encoding]::UTF8).Replace($kRefNonce, $nonceX)
        $m = $m -replace '(?m)^built:            \S+', 'built:            20261013T120000Z'
        $m = $m -replace '(?m)^OUTPUT IMAGE:     boot-stage3d\.img  size=\d+  sha256=[0-9a-f]{64}', "OUTPUT IMAGE:     boot-stage3d.img  size=$($img.Length)  sha256=$(Get-FsNoSha $ip)"
        $m = $m -replace '(?m)^ramdisk\.cpio      [0-9a-f]{64}  size=\d+', "ramdisk.cpio      $(& $hx $cp)  size=$($cp.Length)"
        $m = $m -replace '(?m)^ramdisk\.lz4       [0-9a-f]{64}  size=\d+', "ramdisk.lz4       $(& $hx $lz)  size=$($lz.Length)"
        $ents = Read-FsNoCpio $cp; $rs = [IO.File]::ReadAllText((Join-Path $d 'ramdisk.sha256'))
        foreach ($en in $ents) {
            if ($en.Size -le 0) { continue }
            $h1 = & $hx $cp ([int]$en.Off) ([int]$en.Size)
            $m = [regex]::Replace($m, '(?m)^[0-9a-f]{64}  \d+  /' + [regex]::Escape($en.Name) + '  ', "$h1  $($en.Size)  /$($en.Name)  ")
            $rs = [regex]::Replace($rs, '(?m)^[0-9a-f]{64}  \d+  ' + [regex]::Escape($en.Name) + '$', "$h1  $($en.Size)  $($en.Name)")
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $d 'MANIFEST.txt'), $m, $enc); [IO.File]::WriteAllText((Join-Path $d 'ramdisk.sha256'), $rs, $enc)
        [IO.File]::WriteAllText((Join-Path $d 'header-diff.txt'), ([IO.File]::ReadAllText((Join-Path $d 'header-diff.txt')) -replace '> ramdisk size: \d+', "> ramdisk size: $($lz.Length)"), $enc)
        # delta review MAJOR-1: the rebuild's OWN ramdisk-scan.txt, as build-image.sh writes it (lines 1-2: the scan time, the
        # builder's temp path and this image's hash)
        $sc = @([IO.File]::ReadAllText((Join-Path $d 'ramdisk-scan.txt')) -split "`n")
        $sc[0] = '# initramfs BLAKE2 scan of boot-stage3d.img  2026-10-13T12:00:31Z'; $sc[1] = "boot image:   /tmp/tmp.K3d$($nonceX.Substring(12))/boot-stage3d.img sha256=$(Get-FsNoSha $ip)"
        [IO.File]::WriteAllText((Join-Path $d 'ramdisk-scan.txt'), ($sc -join "`n"), $enc)
        if ($dirMut) { & $dirMut $d }
        $d
    }
    # the builder's compression reproduced: the reference cpio through WSL lz4 gives the reference's own lz4 bytes
    $rc0 = Join-Path $kWork 'ref.cpio'; $rl0 = Join-Path $kWork 'ref.lz4'; [IO.File]::WriteAllBytes($rc0, $kRef.Cpio); & $lz4 $rc0 $rl0
    $sameLz = ((Get-FsNoSha $rl0) -ceq $kRef.Lz4Sha)
    $okd = New-K3dRebuild 'b0b0000000000001'
    $k1 = Test-FsNonceOnly -Ref $cand -Cand $okd
    $cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $T3Dir 'fs-nonceonly3d.ps1') -Reference $cand -Candidate $okd; $clic = $LASTEXITCODE
    Check "K1 review 2 MAJOR-2, the positive control is a real image: the reviewed candidate $kS8 (nonce $kRefNonce; read only) is unpacked here (boot header v4, LZ4 legacy, cpio newc: its cpio and lz4 equal the MANIFEST's ramdisk.cpio 23a7a95f... and ramdisk.lz4 c67d0d80...); WSL lz4 -l -9 reproduces its lz4 bytes; a rebuild with only the nonce changed (same image size) is a NONCE-ONLY REBUILD (CLI exit 0)" `
        ($kRef.Ok -and $kRef.Version -eq 4 -and $kRef.CpioSha -ceq '23a7a95fcbb34dacdadcaffec83853de697c0d551c1e6aaa9fed490649cde417' -and $kRef.Lz4Sha -ceq 'c67d0d8019039616283cb147122eb5cf19766113bf5a2dd78ce004399d35e236' -and $kRefNonce -ceq $candNonce -and $sameLz -and
         $k1.Ok -and $k1.CandNonce -ceq 'b0b0000000000001' -and $clic -eq 0 -and ($cli -join ' ') -match '^NONCE-ONLY REBUILD: OK') "$($k1.Diffs -join ' / ') || $($cli -join ' / ') || sameLz $sameLz"
    # the negatives: each is refused, naming what differs
    # a mutation that flips one byte of a ramdisk file (an unbound scriptblock: it runs in New-K3dRebuild's scope, no closure)
    $flip = { param([string]$name, [int]$at) [scriptblock]::Create("param([byte[]]`$c) `$e = & `$kEnt '$name'; `$c[[int]`$e.Off + $at] = [byte](`$c[[int]`$e.Off + $at] -bxor 0x5a)") }
    $kc = [ordered]@{
        'a changed busybox'                 = @{ N = 'b0b0000000000002'; Cpio = (& $flip 'bin/busybox' 4000); Want = 'ramdisk /bin/busybox differs' }
        'a changed module list'             = @{ N = 'b0b0000000000003'; Cpio = (& $flip 'lib/fs/modules.load' 10); Want = 'ramdisk /lib/fs/modules.load differs' }
        'a changed fs-supervise'            = @{ N = 'b0b0000000000004'; Cpio = (& $flip 'bin/fs-supervise' 5000); Want = 'ramdisk /bin/fs-supervise differs' }
        'a changed fs-pattern'              = @{ N = 'b0b0000000000005'; Cpio = (& $flip 'bin/fs-pattern' 6000); Want = 'ramdisk /bin/fs-pattern differs' }
        '/init changed beyond the nonce'    = @{ N = 'b0b0000000000006'; Cpio = { param([byte[]]$c) $e = & $kEnt 'init'; $t = $l1.GetString($c, [int]$e.Off, [int]$e.Size); $i0 = $t.IndexOf('DEADLINE=200'); $b0 = $l1.GetBytes('DEADLINE=900'); [Array]::Copy($b0, 0, $c, [int]$e.Off + $i0, $b0.Length) }; Want = 'ramdisk /init differs beyond the nonce' }
        'a larger cpio (512 zero bytes)'    = @{ N = 'b0b0000000000007'; Cpio = { param([byte[]]$c) [byte[]]$c2 = New-Object byte[] ($c.Length + 512); [Array]::Copy($c, $c2, $c.Length); ,$c2 }; Want = 'the cpio sizes differ' }
        'a different image size'            = @{ N = 'b0b0000000000008'; Img = { param([byte[]]$i, [int]$n) [byte[]]$i2 = New-Object byte[] ($i.Length + 4096); [Array]::Copy($i, $i2, $i.Length); ,$i2 }; Want = 'the image sizes differ|the regions' }
        'a kernel byte'                     = @{ N = 'b0b0000000000009'; Img = { param([byte[]]$i, [int]$n) $i[4096 + 100000] = [byte]($i[4096 + 100000] -bxor 1) }; Want = 'the kernel bytes differ' }
        'a header byte (the command line)'  = @{ N = 'b0b000000000000a'; Img = { param([byte[]]$i, [int]$n) $i[44 + 3] = [byte]($i[44 + 3] -bxor 1) }; Want = 'the boot image headers differ beyond the ramdisk size' }
        'a byte in the ramdisk padding'     = @{ N = 'b0b000000000000b'; Img = { param([byte[]]$i, [int]$n) $i[[int]$kRef.RamdiskOff + $n + 7] = 1 }; Want = "candidate: non-zero bytes in the ramdisk's page padding" }
        'a changed applets list'            = @{ N = 'b0b000000000000c'; Dir = { param([string]$d) Add-Content -LiteralPath (Join-Path $d 'applets.txt') -Value 'dd' }; Want = 'applets\.txt differs' }
        'ramdisk-scan line 2 naming the reference image' = @{ N = 'b0b0000000000020'; Dir = { param([string]$d) $p0 = Join-Path $d 'ramdisk-scan.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace 'sha256=[0-9a-f]{64}', ('sha256=' + $script:FsNoReviewedSha))) }; Want = "candidate ramdisk-scan\.txt line 2 names image $kS8\S+, not this directory's image" }
        'ramdisk-scan line 1 malformed'     = @{ N = 'b0b0000000000021'; Dir = { param([string]$d) $p0 = Join-Path $d 'ramdisk-scan.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace '  2026-10-13T12:00:31Z', '  yesterday')) }; Want = 'candidate ramdisk-scan\.txt line 1 is not' }
        'ramdisk-scan line 3 changed'       = @{ N = 'b0b0000000000022'; Dir = { param([string]$d) $p0 = Join-Path $d 'ramdisk-scan.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace '\(= the pinned stock vendor_boot\)', '(MISMATCH)')) }; Want = 'ramdisk-scan\.txt line 3 differs' }
        'an unreviewed build-image.sh'      = @{ N = 'b0b0000000000023'; Dir = { param([string]$d) $p0 = Join-Path $d 'MANIFEST.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace '(?m)^build-image\.sh    [0-9a-f]{64}', ('build-image.sh    ' + ('e' * 64)))) }; Want = 'candidate: built by build-image\.sh ''e{64}''.*not a reviewed builder version' }
        'the withdrawn candidate''s builder (b67c4023 / 402525cd, reviewed only for 3d730337)' = @{ N = 'b0b0000000000024'; Dir = { param([string]$d) $p0 = Join-Path $d 'MANIFEST.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace '(?m)^build-image\.sh    [0-9a-f]{64}', 'build-image.sh    b67c40233b0be590d6fd153021e75847df9853b6402875c0cf37126f00093d2d')) }; Want = 'not a reviewed builder version' }
        'the superseded candidate''s builder (8870bbce / 402525cd, reviewed only for 96cc15aa)' = @{ N = 'b0b0000000000028'; Dir = { param([string]$d) $p0 = Join-Path $d 'MANIFEST.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace '(?m)^build-image\.sh    [0-9a-f]{64}', 'build-image.sh    8870bbceef462410fb5af5d15130d8495f5c0faf5bc454edab25e0a425fe012c')) }; Want = 'candidate: built by build-image\.sh ''8870bbce\S+'' .*not a reviewed builder version' }
        'a module-list-check line changed'  = @{ N = 'b0b0000000000025'; Dir = { param([string]$d) $p0 = Join-Path $d 'module-list-check.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace 'PASS 95 entries', 'PASS 96 entries')) }; Want = 'module-list-check\.txt differs \(beyond check 5\)' }
        'check 5''s line missing with the check-5 tool' = @{ N = 'b0b0000000000026'; Dir = { param([string]$d) $p0 = Join-Path $d 'module-list-check.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace "CHECK no_forbidden_module_in_or_reachable_from_the_list \(38 forbidden\) PASS \[\]\r?\n", '')) }; Want = 'candidate module-list-check\.txt has 0 check-5 PASS line\(s\); its tool 402525cd\S+ means 1' }
        'the new builder with the old module-list tool' = @{ N = 'b0b0000000000027'; Dir = { param([string]$d) $p0 = Join-Path $d 'MANIFEST.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace '(?m)(^loaded modules\s.*module-list-check\.txt, tool )[0-9a-f]{64}', '${1}35261647eb53711dded95e391f2c7e2742031dababbd5215f55b6b7e0468e8ca')) }; Want = 'candidate: built by build-image\.sh ''[0-9a-f]{64}'' with module-list-check tool ''35261647\S+'': not a reviewed builder version' }
        'a MANIFEST /init line of another size' = @{ N = 'b0b000000000000d'; Dir = { param([string]$d) $p0 = Join-Path $d 'MANIFEST.txt'; [IO.File]::WriteAllText($p0, ([IO.File]::ReadAllText($p0) -replace '  15973  /init  ', '  15974  /init  ')) }; Want = '/init' }
    }
    $bad = @(); $kRes = @()
    foreach ($kn in $kc.Keys) {
        $v = $kc[$kn]
        $dk = New-K3dRebuild $v.N $(if ($v.ContainsKey('Cpio')) { $v.Cpio } else { $null }) $(if ($v.ContainsKey('Img')) { $v.Img } else { $null }) $(if ($v.ContainsKey('Dir')) { $v.Dir } else { $null })
        $rk = Test-FsNonceOnly -Ref $cand -Cand $dk
        $kRes += "$kn -> $(@($rk.Diffs)[0])"
        if ($rk.Ok -or ($rk.Diffs -join ' | ') -notmatch $v.Want) { $bad += "${kn}: ok=$($rk.Ok) $($rk.Diffs -join ' / ')" }
        Remove-Item -LiteralPath $dk -Recurse -Force
    }
    $k4 = Test-FsNonceOnly -Ref $cand -Cand $cand
    if ($k4.Ok -or ($k4.Diffs -join ' ') -notmatch 'nonces are the same') { $bad += "same nonce: $($k4.Diffs -join ' / ')" }
    $k6 = Test-FsNonceOnly -Ref $okd -Cand (New-K3dRebuild 'b0b000000000000e')
    if ($k6.Ok -or ($k6.Diffs -join ' ') -notmatch "is not the reviewed candidate $kS8") { $bad += "unreviewed reference: $($k6.Diffs -join ' / ')" }
    # the first version's positive control (the record files with a 12-byte "image") is refused now
    $k7d = New-K3dRebuild 'b0b000000000000f' $null $null { param([string]$d) $p0 = Join-Path $d 'boot-stage3d.img'; [IO.File]::WriteAllBytes($p0, [Text.Encoding]::ASCII.GetBytes('image 12 b f')); $h0 = Get-FsNoSha $p0
        $p1 = Join-Path $d 'MANIFEST.txt'; [IO.File]::WriteAllText($p1, ([IO.File]::ReadAllText($p1) -replace 'OUTPUT IMAGE:     boot-stage3d\.img  size=\d+  sha256=[0-9a-f]{64}', "OUTPUT IMAGE:     boot-stage3d.img  size=12  sha256=$h0")) }
    $k7 = Test-FsNonceOnly -Ref $cand -Cand $k7d
    if ($k7.Ok -or ($k7.Diffs -join ' ') -notmatch 'candidate image: not an Android boot image') { $bad += "12-byte image: $($k7.Diffs -join ' / ')" }
    foreach ($l in $kRes) { Say "      nonce-only negative: $l" }
    Check "K2 review 2 MAJOR-2: each of $($kc.Count + 3) non-nonce-only rebuilds of the real candidate is refused, naming what differs: a changed busybox, module list, fs-supervise, fs-pattern (each with its MANIFEST line re-recorded: the image comparison catches it), /init changed beyond the nonce, a larger cpio, a different image size, a kernel byte, a header byte, a byte in the ramdisk padding, the applets list, ramdisk-scan.txt (line 2 naming another image, line 1 malformed, line 3 changed; delta review MAJOR-1), an unreviewed builder, the withdrawn candidates' builder pairs (3d730337's b67c4023, 96cc15aa's 8870bbce; J-141: each reference only with its own pairs), the new builder with the old module-list tool, a changed module-list check line or check 5's line missing, a MANIFEST /init line of another size; the same nonce; an unreviewed reference; the first version's 12-byte positive control" ($bad.Count -eq 0) ($bad -join ' | ')
    # the observer requires it (review 2 MAJOR-2): a build root holding the reviewed candidate and the rebuilds (copies)
    $kbr = Join-Path $Scratch 'k3d-obs\build\stage3d'; $null = New-Item -ItemType Directory -Force -Path $kbr
    $refCopy = Join-Path $kbr $script:FsNoReviewedDir; Copy-Item -LiteralPath $cand -Destination $refCopy -Recurse
    Get-ChildItem -LiteralPath $refCopy -Directory | Remove-Item -Recurse -Force       # only the candidate's own files (not an observe-* dir)
    Remove-Item -LiteralPath (Join-Path $refCopy 'attempt.lock') -Force -ErrorAction SilentlyContinue   # J-144: the real candidate is spent; this copy tests the nonce-only logic
    $okObs = New-K3dRebuild 'b0b0000000000011' $null $null $null $kbr
    $badObs = New-K3dRebuild 'b0b0000000000012' (& $flip 'bin/busybox' 4000) $null $null $kbr
    $obsPre = { param([string]$img) $script:kLines = New-Object System.Collections.Generic.List[string]
        Invoke-FsObserve -ImagePath $img -Preflight $true -BuildRoot $kbr -Q3 $T3Q3 -Fastboot { param($a, $t) throw 'no device in a preflight' } -Gadget { param($n) $null } -NowUtc { [DateTime]::UtcNow } -Sleep { param($ms) } -Say { param([string]$l) $script:kLines.Add($l) } }
    $oA = & $obsPre (Join-Path $refCopy 'boot-stage3d.img'); $lA = @($script:kLines)
    $oB = & $obsPre (Join-Path $okObs 'boot-stage3d.img'); $lB = @($script:kLines)
    $oC = & $obsPre (Join-Path $badObs 'boot-stage3d.img')
    # delta review MINOR-1: the reviewed image copied into another directory (its MANIFEST nonce edited to match), or into a
    # directory of the reviewed nonce with another stamp: refused (the reviewed image only as the reviewed directory)
    $cpA = Join-Path $kbr '20261013T120000Z-b0b0000000000013'; $null = New-Item -ItemType Directory -Force -Path $cpA
    Copy-Item -Path (Join-Path $refCopy '*') -Destination $cpA
    $pA = Join-Path $cpA 'MANIFEST.txt'; [IO.File]::WriteAllText($pA, [IO.File]::ReadAllText($pA).Replace($kRefNonce, 'b0b0000000000013'), (New-Object System.Text.UTF8Encoding($false)))
    $oD = & $obsPre (Join-Path $cpA 'boot-stage3d.img')
    $cpB = Join-Path $kbr "20261013T999999Z-$kRefNonce"; $null = New-Item -ItemType Directory -Force -Path $cpB
    Copy-Item -Path (Join-Path $refCopy '*') -Destination $cpB
    $oE = & $obsPre (Join-Path $cpB 'boot-stage3d.img')
    Remove-Item -LiteralPath $cpA, $cpB -Recurse -Force
    Check "K3 review 2 MAJOR-2, the observer (fs-observe3d -Preflight, real stage3d sources): the reviewed candidate -> preflight OK (`"candidate: the reviewed candidate`"); delta review MINOR-1: the reviewed image copied into another directory with its MANIFEST nonce edited, or into a directory of the reviewed nonce with another stamp -> refused; a nonce-only rebuild of it -> preflight OK (`"candidate: a nonce-only rebuild of the reviewed candidate ($kRefNonce -> b0b0000000000011 ...)`"); a rebuild with a changed busybox -> refused (image refused: not the reviewed candidate and not a nonce-only rebuild ... ramdisk /bin/busybox differs)" `
        ($oA.Exit -eq 0 -and ($lA -join ' ') -match "candidate: the reviewed candidate \($kS8" -and $oB.Exit -eq 0 -and ($lB -join ' ') -match "candidate: a nonce-only rebuild of the reviewed candidate \($kRefNonce -> b0b0000000000011" -and
         $oC.Exit -eq 2 -and $oC.Why -match "^image refused: not the reviewed candidate $kS8\S+ and not a nonce-only rebuild of it .*ramdisk /bin/busybox differs" -and
         $oD.Exit -eq 2 -and $oD.Why -match "^image refused: it hashes to the reviewed candidate $kS8\S+, but its directory is '20261013T120000Z-b0b0000000000013' and its MANIFEST nonce b0b0000000000013" -and
         $oE.Exit -eq 2 -and $oE.Why -match "its directory is '20261013T999999Z-$kRefNonce'") "$($oA.Why) | $($oB.Why) | $($oC.Why) | $($oD.Why) | $($oE.Why)"
    # K4 delta review MAJOR-1, end to end: a REAL nonce-only rebuild by the main checkout's stage3d/build-image.sh (WSL; a
    # fresh random nonce; FS_TEST_OUTBASE = this scratch, never build\stage3d, never ledgered; the main checkout is only read).
    # FS_TEST_OUTBASE makes the builder add one "TEST OVERRIDES:" MANIFEST line (the observer refuses such a MANIFEST): a COPY
    # without that one line is checked; every other byte is the builder's.
    $k4Fw = Join-Path $MainRoot 'firmware\quest3\v2.7-user_ota\boot.img'
    if (Test-Path -LiteralPath $k4Fw) {
        $k4Out = Join-Path $Scratch 'k4-realbuild'; $null = New-Item -ItemType Directory -Force -Path $k4Out
        $k4Root = '/mnt/' + $MainRoot.Substring(0, 1).ToLowerInvariant() + $MainRoot.Substring(2).Replace('\', '/')
        $ea4 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        # -K4StageDir: that devices\quest3\stage3d bound (WSL bwrap) over the main checkout's path, so the builder runs those
        # sources and records main-checkout paths; the main checkout itself is not changed (output in this scratch)
        $k4Pre = @(); if ($K4StageDir) { $k4Pre = @('bwrap', '--dev-bind', '/', '/', '--bind', (& $toWsl $K4StageDir), "$k4Root/devices/quest3/stage3d") }
        try { $k4Log = @(& wsl.exe -e env "FS_TEST_OUTBASE=$(& $toWsl $k4Out)" @k4Pre bash "$k4Root/devices/quest3/stage3d/build-image.sh" 2>&1 | ForEach-Object { [string]$_ }); $k4Rc = $LASTEXITCODE } finally { $ErrorActionPreference = $ea4 }
        $k4Src = @(Get-ChildItem -LiteralPath $k4Out -Directory | Where-Object { $_.Name -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{16}\z' })
        if ($k4Rc -eq 0 -and $k4Src.Count -eq 1) {
            $k4Dir = Join-Path $kbr $k4Src[0].Name; $null = New-Item -ItemType Directory -Force -Path $k4Dir
            Copy-Item -Path (Join-Path $k4Src[0].FullName '*') -Destination $k4Dir
            $k4M = Join-Path $k4Dir 'MANIFEST.txt'; $k4T = [IO.File]::ReadAllText($k4M, [Text.Encoding]::UTF8)
            $k4Ov = @($k4T -split "`n" | Where-Object { $_ -match '^TEST OVERRIDES:' })
            [IO.File]::WriteAllText($k4M, ((@($k4T -split "`n" | Where-Object { $_ -notmatch '^TEST OVERRIDES:' })) -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
            $k4R = Test-FsNonceOnly -Ref $cand -Cand $k4Dir
            $k4O = & $obsPre (Join-Path $k4Dir 'boot-stage3d.img'); $k4L = @($script:kLines)
            $k4Raw = Test-FsNonceOnly -Ref $cand -Cand $k4Src[0].FullName
            Say "      real rebuild $($k4Src[0].Name): $($k4R.RefNonce) -> $($k4R.CandNonce), image $($k4R.CandImageSha); nonce-only $($k4R.Ok); preflight exit $($k4O.Exit): $(@($k4L | Where-Object { $_ -match '^candidate: ' }) -join '')"
            Check 'K4 delta review MAJOR-1, a REAL nonce-only rebuild (the main checkout''s build-image.sh in WSL, or -K4StageDir''s bound over it, a fresh nonce, output in this scratch: never build\stage3d, never ledgered): with only the one TEST OVERRIDES line (added by FS_TEST_OUTBASE) removed, it passes fs-nonceonly3d (its own ramdisk-scan.txt lines 1-2; the current candidate''s reviewed builder pair) and fs-observe3d -Preflight ("candidate: a nonce-only rebuild"); as built (with that line) it is refused (MANIFEST line count)' `
                ($k4Ov.Count -eq 1 -and $k4Ov[0] -match '^TEST OVERRIDES:   FS_TEST_OUTBASE=\S+ \(negative fixtures only; NOT a candidate image\)' -and $k4R.Ok -and $k4O.Exit -eq 0 -and ($k4L -join ' ') -match "candidate: a nonce-only rebuild of the reviewed candidate \($kRefNonce -> " -and
                 -not $k4Raw.Ok -and ($k4Raw.Diffs -join ' ') -match 'MANIFEST line counts differ') "$($k4R.Diffs -join ' / ') | $($k4O.Why) | $($k4Ov -join ' ')"
        } else { Check 'K4 a REAL nonce-only rebuild by build-image.sh' $false "build rc $k4Rc, dirs $($k4Src.Count): $(@($k4Log | Select-Object -Last 3) -join ' / ')" }
    } else { Skip 'K4 a real nonce-only rebuild' "the firmware inputs are not present: $k4Fw" }
} else { Skip 'K1-K3 nonce-only' "the candidate ($cand) or WSL lz4 is not available" }

# ------------------------------------------------------------------ Y --------
Say '== Y. the stage-3c host files are unchanged by the stage-3d work'
# review 2 MINOR-7: the single-reading branch as a local branch or as origin/...; absent (or git failing): SKIP, never a crash
$yRef = $null
try {
    $ea0 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    foreach ($rf in 'feat/single-reading-userbuild', 'origin/feat/single-reading-userbuild') {
        $null = & git -C $T3Root rev-parse --verify --quiet "$rf^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) { $yRef = $rf; break }
    }
} catch { $yRef = $null } finally { $ErrorActionPreference = $ea0 }
if ($yRef) {
    $pinned = @('devices/quest3/host/fs-collect3c.ps1', 'devices/quest3/host/fs-session3c.ps1', 'devices/quest3/host/fs-classify3c.ps1', 'devices/quest3/host/fs-observe3c.ps1', 'devices/quest3/host/fs-checklist3c.ps1',
                'devices/quest3/host/fs-collect.ps1', 'devices/quest3/host/fs-classify.ps1', 'devices/quest3/host/fs-classify3b.ps1', 'devices/quest3/host/fs-native.ps1', 'devices/quest3/host/fs-capture.ps1', 'devices/quest3/stage1/fs-proto.ps1', 'devices/quest3/common/host/fsb1.ps1')
    $df = $null
    try { $ErrorActionPreference = 'Continue'; $df = @(& git -C $T3Root diff --name-only $yRef -- @pinned 2>$null | Where-Object { $_ }); $dfc = $LASTEXITCODE } catch { $df = $null } finally { $ErrorActionPreference = 'Stop' }
    if ($null -eq $df -or $dfc -ne 0) { Skip 'Y1' "git diff against $yRef failed" }
    else { Check "Y1 the stage-3c host files and the shared helpers are byte-identical to the single-reading branch ($yRef; the stage-3d tools dot-source or copy them; nothing of 3c is edited)" ($df.Count -eq 0) ($df -join ' ') }
} else { Skip 'Y1' 'the branch feat/single-reading-userbuild is not in this repository (neither local nor origin/)' }

Say ("TOTAL: {0} passed, {1} failed, {2} skipped" -f $script:pass, $script:fail, $script:skip)
[IO.File]::WriteAllLines($OutFile, [string[]]$script:log, (New-Object System.Text.UTF8Encoding($false)))
if ($script:fail -ne 0) { exit 1 }
exit 0
