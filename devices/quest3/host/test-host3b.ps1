# FrameShift host fixtures, STAGE 3B (trial (iii-b)), Windows PowerShell 5.1. No device, no
# adb/fastboot, no COM port. Exit 0 only if every check passes. test-host2.ps1 (stages 2a/3a)
# is unchanged and must still pass on its own.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host3b.ps1 [-Scratch <dir>] [-OutFile <file>]
# Sections:
#   C  collector stage spec: 3b values; 2a/3a values and the 3a texts unchanged
#   K  stage-3b classifier, machine side: every OUTCOMES §9.4 rule and edge (synthetic records)
#   R  stage-3b optical side and the registered result (OUTCOMES §9.5, §9.6; FSR1 readings)
#   P  replays of the whole-image harness captures (stage3b/fixtures/image) through
#      fs-collect.ps1 -Stage 3b, the classifier, the CLI; a capture re-chunked at every paced
#      chunk boundary and mid-line (collector-side reassembly); a cut-short record; the guard
#   E  paced vs unpaced emission (stage3b/fixtures/pace): PowerShell decoder VALID, same bytes,
#      same rec_sha256, for the representative and the MAXIMUM record
#   D  the damaged trial-(iii) capture is still rejected (line-count), and its registered
#      stage-3a outcome (INCONCLUSIVE, rule 2) is reproduced by the unchanged classifier
#   O  fs-observe.ps1 -Stage 3b: the BA dwell gate (<= 300 s, enforced before the boot), the
#      abandoned-cycle record, and the 3b MANIFEST/sources check
#   T  timing: stage3b/tools/check-timing-3b.py and stage2a/tools/check-timing.py CONSISTENT
param([string]$Scratch = '', [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$HOSTDIR = $PSScriptRoot
$FIXDIR = Join-Path $PSScriptRoot 'fixtures'
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'test-host3b.output.txt' }
. (Join-Path $HOSTDIR 'fs-collect.ps1')
. (Join-Path $HOSTDIR 'fs-classify.ps1')
. (Join-Path $HOSTDIR 'fs-observe.ps1')
. (Join-Path $FIXDIR 'synth.ps1')
$ROOT = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$Q3 = Join-Path $ROOT 'devices\quest3'
$S3B = Join-Path $Q3 'stage3b'
if (-not $Scratch) { $Scratch = Join-Path ([IO.Path]::GetTempPath()) ("fs-host3b-" + (New-FsHex 4)) }
$null = New-Item -ItemType Directory -Force -Path $Scratch
$script:pass = 0; $script:fail = 0; $script:skip = 0
$script:log = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $script:log.Add($s); Write-Host $s }
function Check([string]$name, [bool]$cond, [string]$detail = '') { if ($cond) { $script:pass++; Say "PASS  $name" } else { $script:fail++; Say "FAIL  $name $detail" } }
function Skip([string]$name, [string]$why) { $script:skip++; Say "SKIP  $name ($why)" }
function B([string]$s) { ,([System.Text.Encoding]::GetEncoding(28591).GetBytes($s)) }
$python = $null
foreach ($cand in 'python', 'python3') { try { $v = & $cand -I -c 'import sys;print(sys.version_info[0])' 2>$null; if ($v -eq '3') { $python = $cand; break } } catch {} }
Say "== test-host3b  $(Get-Date -Format o)  PowerShell $($PSVersionTable.PSVersion)  scratch=$Scratch  python=$python"

# ------------------------------------------------------------------ C --------
Say '== C. collector stage spec'
$c3b = New-FsCollectCfg -Nonce ('0' * 16) -Stage 3b
$c3a = New-FsCollectCfg -Nonce ('0' * 16) -Stage 3a
$c2a = New-FsCollectCfg -Nonce ('0' * 16) -Stage 2a
Check 'C1 3b: fs-display, exp stage3b, 5 steps hash,probe1,pattern1,probe2,pattern2, deadline 200, ack 150, RunnerWorst 75, margin 5, cue 3 s, pre-done 10 s, beeps 300/700, 2 fs-status tries' `
    ($c3b.RunVerb -ceq 'fs-display' -and $c3b.Exp -ceq 'stage3b' -and (@($c3b.Steps) -join ',') -ceq 'hash,probe1,pattern1,probe2,pattern2' -and $c3b.DeviceDeadlineSec -eq 200 -and
     $c3b.AckWindowSec -eq 150 -and $c3b.RunnerWorstSec -eq 75 -and $c3b.RunnerMarginSec -eq 5 -and $c3b.DisplayCueMs -eq 3000 -and $c3b.PreDoneMs -eq 10000 -and
     $c3b.Beep1Ms -eq 300 -and $c3b.Beep2Ms -eq 700 -and $c3b.AckStatusTries -eq 2 -and $c3b.GiveUpMs -eq 185000)
Check 'C2 3a unchanged: exp stage3a, steps hash,pattern, deadline 170, RunnerWorst 42; 2a unchanged: deadline 260, RunnerWorst 127, 8 steps, 3 tries' `
    ($c3a.Exp -ceq 'stage3a' -and (@($c3a.Steps) -join ',') -ceq 'hash,pattern' -and $c3a.DeviceDeadlineSec -eq 170 -and $c3a.RunnerWorstSec -eq 42 -and
     $c2a.DeviceDeadlineSec -eq 260 -and $c2a.RunnerWorstSec -eq 127 -and @($c2a.Steps).Count -eq 8 -and $c2a.AckStatusTries -eq 3)
$csrc = [IO.File]::ReadAllText((Join-Path $HOSTDIR 'fs-collect.ps1'))
Check 'C3 the stage-3a cue and beep texts are still in the code, unchanged' ($csrc.Contains("'=== LOOK INTO THE LENSES NOW: the test pattern appears in 3 seconds and lasts up to 10 seconds ==='") -and
    $csrc.Contains('BEEP 1: KEEP LOOKING INTO THE LENSES. The panels should now be DARK.'))
Check 'C4 the stage-3b cue: first lit period (about 3 s) about 3.5-6.5 s after the cue, a dark gap of at least 2 s (the guarantee; no "2.5 s" promise), then about 10 s; per eye and per period; keep looking until the second (low) beep (SIGNOFF E), never "until BEEP 1"' ($script:FsCue3b -match 'FIRST lit period \(run 1, about 3 seconds\) should start about 3\.5 to 6\.5 seconds from now' -and
    $script:FsCue3b -match 'DARK gap of at least 2 seconds' -and $script:FsCue3b -notmatch '2\.5' -and $script:FsCue3b -match 'SECOND lit period \(run 2, about 10 seconds\)' -and $script:FsCue3b -match 'EACH EYE and EACH PERIOD' -and
    $script:FsCue3b -match 'Keep looking until the SECOND \(LOW\) BEEP\.' -and $script:FsCue3b -notmatch 'until BEEP 1')
Check 'C5 the stage-3b report prompt gives the FSR1 form for both periods and both eyes, and says no light seen is not zero emitted light or exposure' ((@($script:FsReport3b) -join "`n") -match 'FSR1 run=1 eye=left' -and (@($script:FsReport3b) -join "`n") -match 'FSR1 run=2 eye=right' -and (@($script:FsReport3b) -join "`n") -match 'READ = the characters' -and (@($script:FsReport3b) -join "`n") -match 'not zero emitted light or zero exposure')

# ------------------------------------------------------------------ K --------
Say '== K. stage-3b classifier, machine side (OUTCOMES §9.4)'
$KN = 'a1b2c3d4e5f60718'; $KC = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'; $K8 = $KC.Substring(0, 8)
$PIN = $script:S3bPatternPin
function Get-R1Recs([string]$closeRc = '0', [int]$code = 0, [switch]$NoCommit) {
    $r = New-Object System.Collections.Generic.List[object]
    $r.Add(@('start', 0, 'mode=show ver=0.5 hold_req=3 hold=3 hold_max=10 clamped=0 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180 t0_ms=19980'))
    $r.Add(@('open', 0, 'dev=/dev/dri/card0 major=226 minor=0')); $r.Add(@('version', 0, 'drv=msm_drm major=1 minor=4 patch=0'))
    $r.Add(@('crtc_state', 0, 'idx=-1 w=4128 h=2208 vrefresh=90 getcrtc_rc=0 mode_valid=1 fb=0 active_prop=22 active=1 in_list=1 interlaced=0 expected=1'))
    $r.Add(@('conn_topology', 0, 'conn=55 props=22 topology_prop=1019 topology_val=14 topology_name=sde_quadpipe_dsc4hsmerge control_prop=1020 control_val=0 dsc_mode_prop=1013 dsc_mode_val=2 mode_props_blob=201'))
    $r.Add(@('test_commit', 0, 'attempt=3 modeset=1 layout=split objs=6 props=27 planes_off=2 overflow=0 result=accepted'))
    if (-not $NoCommit) {
        $r.Add(@('commit', 0, 'attempt=3 modeset=1 layout=split commit_ms=657'))
        $r.Add(@('hold_start', 0, 'hold_s=3 start_ms=20000 deadline_ms=23000 alarm_s=8'))
        $r.Add(@('hold_end', 0, "reason=deadline sig=0 held_ms=3000 late_ms=0 fd_closed=1 close_rc=$closeRc close_ms=534"))
        $r.Add(@('exit', 0, "code=$code reason=held_to_deadline shown=1 closed_at_exit=0 elapsed_ms=3560"))
    } else { $r.Add(@('exit', 0, "code=$code reason=x shown=0 closed_at_exit=1 elapsed_ms=40")) }
    ,$r.ToArray()
}
function Get-R2Recs([string]$active = '0', [int]$code = 0, [long]$startMs = 27000, [string]$mode = 'show-off', [switch]$NoPrecond, [switch]$NoHold) {
    $r = New-Object System.Collections.Generic.List[object]
    $r.Add(@('start', 0, "mode=$mode ver=0.5 hold_req=10 hold=10 hold_max=10 clamped=0 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180 t0_ms=26980"))
    $r.Add(@('crtc_state', 0, "idx=-1 w=0 h=0 vrefresh=0 getcrtc_rc=0 mode_valid=0 fb=0 active_prop=22 active=$active in_list=0 interlaced=0 expected=0"))
    if (-not $NoPrecond) { $r.Add(@('precondition', 0, "required=crtc_inactive getcrtc_rc=0 active_prop=22 active=0")) }
    $r.Add(@('test_commit', 0, 'attempt=1 modeset=1 layout=split objs=6 props=27 planes_off=0 overflow=0 result=accepted'))
    $r.Add(@('commit', 0, 'attempt=1 modeset=1 layout=split commit_ms=900'))
    $r.Add(@('hold_start', 0, "hold_s=10 start_ms=$startMs deadline_ms=$($startMs + 10000) alarm_s=15"))
    if (-not $NoHold) { $r.Add(@('hold_end', 0, 'reason=deadline sig=0 held_ms=10000 late_ms=0 fd_closed=1 close_rc=0 close_ms=530')) }
    $r.Add(@('exit', 0, "code=$code reason=held_to_deadline shown=1 closed_at_exit=0 elapsed_ms=11000"))
    ,$r.ToArray()
}
function Get-R2Active { ,@(@('start', 0, 'mode=show-off ver=0.5 hold_req=10 hold=10 hold_max=10 clamped=0 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180 t0_ms=26980'),
    @('crtc_state', 0, 'idx=-1 w=4128 h=2208 vrefresh=90 getcrtc_rc=0 mode_valid=1 fb=0 active_prop=22 active=1 in_list=1 interlaced=0 expected=1'),
    @('precondition', -16, 'required=crtc_inactive getcrtc_rc=0 active_prop=22 active=1'),
    @('exit', 0, 'code=31 reason=crtc_active shown=0 closed_at_exit=1 elapsed_ms=40')) }
$P1OK = "FSPR1 helper=run1 start up=60.1`n== point mods run=run1 up=60.2`n== end mods up=60.4`n== backlight-write node=/sys/class/backlight/panel0-backlight/brightness value=127 up=60.4`nwrite_rc=0 readback=127`n== point pre1 run=run1 up=60.5`n== end pre1 up=60.6`nFSPR1 helper=run1 end up=65.0`n"
$P2OK = "FSPR1 helper=run2 start up=67.1`n== backlight-verify node=/sys/class/backlight/panel0-backlight/brightness (read only) up=67.1`nreadback=127`n== point pre2 run=run2 up=67.2`nFSPR1 helper=run2 end up=79.0`n"
function Get-K3b { param([string]$S1 = $null, [string]$S2 = $null, [long]$C1 = 0, [long]$C2 = 0, [string]$P1 = $P1OK, [string]$P2 = $P2OK)
    if ($null -eq $S1 -or $S1 -eq '') { $S1 = New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R1Recs) }
    if ($null -eq $S2 -or $S2 -eq '') { $S2 = New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs) }
    @((New-SynthStep 1 'hash' (SB "$PIN  /bin/fs-pattern`n")), (New-SynthStep 2 'probe1' (SB $P1)),
      (New-SynthStep 3 'pattern1' (SB $S1) @() @{ code = $C1; ms = [long]3600 }), (New-SynthStep 4 'probe2' (SB $P2)),
      (New-SynthStep 5 'pattern2' (SB $S2) @() @{ code = $C2; ms = [long]11000 }))
}
function Rec($steps) { [pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $steps } }
function KPut($steps, [int]$i, [string]$out = $null, [string]$err = $null, [hashtable]$f = @{}) {
    $o = $steps[$i - 1]
    [byte[]]$ob = $o['out']; if ($null -ne $out) { $ob = B $out }
    [byte[]]$eb = $o['err']; if ($null -ne $err) { $eb = B $err }
    $keep = @{}; foreach ($k in 'code', 'ms') { $keep[$k] = $o[$k] }; foreach ($k in $f.Keys) { $keep[$k] = $f[$k] }
    $steps[$i - 1] = New-SynthStep $i $o['id'] $ob $eb $keep
    ,$steps
}
$SKIP1 = "FSK1 run=1 skipped reason=brightness-not-verified END`n"
$kcases = New-Object System.Collections.Generic.List[object]
function KCase([string]$name, [string]$want, [int]$rule, [scriptblock]$make, [string]$stage1 = 'PASS', [bool]$collected = $true) {
    $kcases.Add([pscustomobject]@{ Name = $name; Want = $want; Rule = $rule; Make = $make; Stage1 = $stage1; Collected = $collected }) }
KCase 'K01 both runs: run 1 accepted commit + clean close; run 2 off->on from an inactive CRTC; pause 3466 ms' 'PASS (machine side)' 25 { Rec (Get-K3b) }
KCase 'K02 stage 1 not PASS' 'DEVICE_REJECTED' 1 { Rec (Get-K3b) } 'DEVICE_REJECTED'
KCase 'K03 no record' 'INCONCLUSIVE' 2 { $null }
KCase 'K04 FSB1 rejected (line-count)' 'INCONCLUSIVE' 2 { [pscustomobject]@{ Ok = $false; Reason = 'line-count'; Steps = $null } }
KCase 'K05 completed after the host deadline' 'INCONCLUSIVE' 2 { Rec (Get-K3b) } 'PASS' $false
KCase 'K06 the stage-3a step list' 'INCONCLUSIVE' 3 { Rec (Get-Stage3aGoodSteps -Nonce $KN -Chal $KC) }
KCase 'K07 hash: digest is not the v0.5 pin (e.g. the v0.4 binary)' 'INTEGRITY FAULT' 4 { Rec (KPut (Get-K3b) 1 ("c7f28cc70f05387416c47d48707ab3e20bd3ba2306cf483516e353739519ad2a  /bin/fs-pattern`n")) }
KCase 'K08 hash: TOOL FAULT' 'INCONCLUSIVE' 5 { Rec (KPut (Get-K3b) 1 $null $null @{ why = 'no-proc' }) }
KCase 'K09 probe1 shows TWO backlight writes' 'INCONCLUSIVE' 6 { Rec (Get-K3b -P1 ($P1OK + "== backlight-write node=/sys/class/backlight/panel0-backlight/brightness value=127 up=61`nwrite_rc=0 readback=127`n")) }
KCase 'K10 probe2 shows a backlight write' 'INCONCLUSIVE' 6 { Rec (Get-K3b -P2 ("== backlight-write node=/sys/class/backlight/panel0-backlight/brightness value=127 up=67`n" + $P2OK)) }
KCase 'K11 run 1 step TOOL FAULT (why=strays-alive)' 'INCONCLUSIVE' 7 { Rec (KPut (Get-K3b) 3 $null $null @{ why = 'strays-alive' }) }
KCase 'K12 run 1 skipped (brightness not verified), run 2 skipped' 'INCONCLUSIVE' 8 { Rec (KPut (KPut (Get-K3b) 3 $SKIP1 $null @{ code = [long]0 }) 5 "FSK1 run=2 skipped reason=run1-not-run END`n" $null @{ code = [long]0 }) }
KCase 'K13 run 1 skipped but run 2 ran: runner inconsistency' 'INCONCLUSIVE' 6 { Rec (KPut (Get-K3b) 3 $SKIP1 $null @{ code = [long]0 }) }
KCase 'K14 run 1 timer-kill (hang)' 'DISPLAY FAIL' 9 { Rec (KPut (Get-K3b) 3 '' '' @{ end = 'timer-kill'; code = [long]-1; sig = [long]9; term_ms = [long]9000; kill_ms = [long]12000 }) }
KCase 'K15 run 1 FSP1 CRC wrong' 'INCONCLUSIVE' 10 { Rec (Get-K3b -S1 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R1Recs) -BadCrcAt 3)) }
KCase 'K16 run 1 ran but probe1 read back 255' 'INCONCLUSIVE' 11 { Rec (Get-K3b -P1 ($P1OK -replace 'readback=127', 'readback=255')) }
KCase 'K17 run 1 exit 10 (no device), run 2 skipped' 'NO-DISPLAY' 12 { Rec (KPut (Get-K3b -S1 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R1Recs -code 10 -NoCommit)) -C1 10) 5 "FSK1 run=2 skipped reason=run1-supervisor END`n" $null @{ code = [long]0 }) }
KCase 'K18 run 1 exit 60 (the commit failed), run 2 skipped' 'DISPLAY FAIL' 13 { Rec (KPut (Get-K3b -S1 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R1Recs -code 60 -NoCommit)) -C1 60) 5 "FSK1 run=2 skipped reason=run1-supervisor END`n" $null @{ code = [long]0 }) }
KCase 'K19 run 1 exit 0 without the commit record, run 2 skipped' 'INCONCLUSIVE' 14 { Rec (KPut (Get-K3b -S1 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R1Recs -NoCommit))) 5 "FSK1 run=2 skipped reason=run1-no-accepted-commit END`n" $null @{ code = [long]0 }) }
KCase 'K20 run 1 close_rc=-5, run 2 skipped' 'RUN 1 ONLY' 15 { Rec (KPut (Get-K3b -S1 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R1Recs -closeRc '-5'))) 5 "FSK1 run=2 skipped reason=run1-close-not-clean END`n" $null @{ code = [long]0 }) }
KCase 'K21 run 1 close_rc=-5 but run 2 ran: runner inconsistency' 'INCONCLUSIVE' 6 { Rec (Get-K3b -S1 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R1Recs -closeRc '-5'))) }
KCase 'K22 run 1 clean, run 2 skipped (brightness not verified before run 2)' 'RUN 1 ONLY' 16 { Rec (KPut (Get-K3b) 5 "FSK1 run=2 skipped reason=brightness-not-verified END`n" $null @{ code = [long]0 }) }
KCase 'K23 run 2 step TOOL FAULT' 'INCONCLUSIVE' 17 { Rec (KPut (Get-K3b) 5 $null $null @{ why = 'capture-write-failed' }) }
KCase 'K24 run 2 timer-kill (hang)' 'DISPLAY FAIL' 18 { Rec (KPut (Get-K3b) 5 '' '' @{ end = 'timer-kill'; code = [long]-1; sig = [long]9; term_ms = [long]16000; kill_ms = [long]19000 }) }
KCase 'K25 run 2 stream without eos' 'INCONCLUSIVE' 19 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs) -NoEos)) }
KCase 'K26 run 2 ran but probe2 has no read-back' 'INCONCLUSIVE' 20 { Rec (Get-K3b -P2 "FSPR1 helper=run2 start up=67.1`n") }
KCase 'K27 run 2 found the CRTC active: exit 31, no commit' 'PRECONDITION UNMET: CRTC ACTIVE' 21 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Active)) -C2 31) }
KCase 'K28 run 2 exit 31 without the precondition record' 'INCONCLUSIVE' 24 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs -code 31 -NoPrecond)) -C2 31) }
KCase 'K29 run 2 exit 0 but crtc_state active=1 (no proof of an inactive CRTC)' 'INCONCLUSIVE' 24 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs -active '1'))) }
KCase 'K30 run 2 exit 50 (TEST_ONLY rejected)' 'NO-DISPLAY' 22 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs -code 50)) -C2 50) }
KCase 'K31 run 2 exit 60 (commit failed)' 'DISPLAY FAIL' 22 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs -code 60)) -C2 60) }
KCase 'K32 pause 1466 ms (< 2000)' 'INCONCLUSIVE' 23 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs -startMs 25000))) }
KCase 'K33 run 2 is mode=show, not show-off' 'INCONCLUSIVE' 20 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs -mode 'show'))) }
KCase 'K34 run 2 exit 0 without hold_end' 'INCONCLUSIVE' 24 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Recs -NoHold))) }
KCase 'K35 run 2 FSP1 nonce is not chal[0:8]' 'INCONCLUSIVE' 19 { Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 'deadbeef' -Recs (Get-R2Recs))) }
KCase 'K36 run 1 skip record for a different run number (not a skip record: unsound)' 'INCONCLUSIVE' 10 { Rec (KPut (Get-K3b) 3 "FSK1 run=2 skipped reason=x END`n" $null @{ code = [long]0 }) }
KCase 'K37 probe1 cut at its cap (out_kept < out_total): informational, still PASS (machine side)' 'PASS (machine side)' 25 { Rec (KPut (Get-K3b) 2 $P1OK $null @{ out_total = [long]30000 }) }
foreach ($kcase in $kcases) {
    $f = & $kcase.Make
    $o = Get-FsStage3bOutcome -Stage1Class $kcase.Stage1 -Fsb1 $f -Nonce $KN -Challenge $KC -Collected $kcase.Collected
    Check "$($kcase.Name) -> $($kcase.Want) (rule $($kcase.Rule))" ($o.Outcome -ceq $kcase.Want -and $o.Rule -eq $kcase.Rule) "got '$($o.Outcome)' rule $($o.Rule): $($o.Reason)"
}
$o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 (Rec (Get-K3b)) -Nonce $KN -Challenge $KC
Check 'K40 PASS reports the pause (3466 ms), both brightness checks and the 5 step classes' ($o.PauseMs -eq 3466 -and $o.Brightness -match 'written once, read back 127' -and $o.Brightness -match 'read back 127 \(no write\)' -and @($o.StepClasses).Count -eq 5)
# a probe cut at its cap is still a VALID record (both decoders: out_len = out_kept)
$tsteps = Get-K3b; $tsteps = KPut $tsteps 2 $P1OK $null @{ out_total = [long]30000 }
$ttext = New-SynthFsb1 -Exp 'stage3b' -Nonce $KN -Chal $KC -Steps $tsteps
$tdec = Test-Fsb1Record -Bytes (B $ttext) -Exp 'stage3b' -Nonce $KN -Challenge $KC -Steps $script:S3bSteps
Check 'K42 a record whose probe1 was cut at its cap (out_kept < out_total) decodes VALID with fsb1.ps1 and classifies PASS (machine side)' ($tdec.Ok -and (Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 $tdec -Nonce $KN -Challenge $KC).Rule -eq 25) "$($tdec.Reason)"
$o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 ([pscustomobject]@{ Ok = $false; Reason = 'no-begin'; Steps = $null }) -Nonce $KN -Challenge $KC -Collected $false -RunnerRefusal 'FSDE1 error=record-too-large lines=2071 max=2070 END'
Check 'K43 a runner refusal is surfaced in the rule-2 reason (record-too-large lines=N)' ($o.Outcome -ceq 'INCONCLUSIVE' -and $o.Rule -eq 2 -and $o.Reason -match 'runner refusal: FSDE1 error=record-too-large lines=2071 max=2070') $o.Reason
$o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 (Rec (Get-K3b)) -Nonce $KN -Challenge $KC
Check 'K44 the rule-25 reason says DRM state, physical panel-off not proven (FS-R-010 §4)' ($o.Reason -match 'from an inactive CRTC \(DRM state; physical panel-off not proven\)' -and $o.Reason -notmatch 'off->on\)')
$o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = @(1, 2, 3, 4, 5) }) -Nonce $KN -Challenge $KC
Check 'K41 malformed decoded steps: INCONCLUSIVE, never a verdict, never a crash' ($o.Outcome -ceq 'INCONCLUSIVE') "$($o.Outcome) $($o.Reason)"

# ------------------------------------------------------------------ R --------
Say '== R. stage-3b optical side and the registered result (OUTCOMES §9.5, §9.6)'
$U8 = $K8.ToUpperInvariant()
function RL([string]$a, [string]$b, [string]$c, [string]$d) { @("FSR1 run=1 eye=left obs=$a", "FSR1 run=1 eye=right obs=$b", "FSR1 run=2 eye=left obs=$c", "FSR1 run=2 eye=right obs=$d") }
$passRec = Rec (Get-K3b)
$rcases = @(
    @('R01 run 2: all 8 read correctly in EACH eye (run 1 dark)', $passRec, (RL 'DARK' 'DARK' "READ chars=$U8" "READ chars=$U8"), 'OPTICAL PASS', 'STAGE PASS', 'RUN 1 DARK, RUN 2 LIT'),
    @('R02 run 2 correct in the left eye only', $passRec, (RL 'DARK' 'DARK' "READ chars=$U8" 'DARK'), 'ONE-EYE ONLY', 'not a stage PASS', 'RUN 1 DARK, RUN 2 LIT'),
    @('R03 lit but garbled in run 2 (lighting finding, not PASS)', $passRec, (RL 'DARK' 'DARK' 'GARBLED' 'LIT'), 'LIT BUT GARBLED (lighting finding, not PASS)', 'not a stage PASS', 'RUN 1 DARK, RUN 2 LIT'),
    @('R04 all four dark, both runs committed', $passRec, (RL 'DARK' 'DARK' 'DARK' 'DARK'), 'BOTH DARK', 'not a stage PASS', ''),
    @('R05 one character wrong in one eye, the other eye correct', $passRec, (RL 'DARK' 'DARK' "READ chars=$($U8.Substring(0,7))0" "READ chars=$U8"), 'ONE-EYE ONLY', 'not a stage PASS', ''),
    @('R06 an unreadable character (?) is not a correct reading', $passRec, (RL 'DARK' 'DARK' "READ chars=?$($U8.Substring(1))" "READ chars=?$($U8.Substring(1))"), 'LIT BUT GARBLED (lighting finding, not PASS)', 'not a stage PASS', ''),
    @('R07 run 1 correct in both eyes, run 2 skipped (RUN 1 ONLY)', (Rec (KPut (Get-K3b) 5 "FSK1 run=2 skipped reason=brightness-not-verified END`n" $null @{ code = [long]0 })), (RL "READ chars=$U8" "READ chars=$U8" 'DARK' 'DARK'), 'OPTICAL PASS', 'STAGE PASS', ''),
    @('R08 run 2 "read" in both eyes but run 2 committed nothing (precondition unmet): contradiction', (Rec (Get-K3b -S2 (New-SynthFsp1 -Nonce8 $K8 -Recs (Get-R2Active)) -C2 31)), (RL 'DARK' 'DARK' "READ chars=$U8" "READ chars=$U8"), 'INCONCLUSIVE', 'not a stage PASS', 'PRECONDITION UNMET: no off->on claim for run 2'),
    @('R09 malformed readings line', $passRec, @('FSR1 run=1 eye=left obs=dark', 'FSR1 run=1 eye=right obs=DARK', 'FSR1 run=2 eye=left obs=DARK', 'FSR1 run=2 eye=right obs=DARK'), 'INCONCLUSIVE', 'not a stage PASS', ''),
    @('R10 a missing period/eye', $passRec, @('FSR1 run=1 eye=left obs=DARK', 'FSR1 run=1 eye=right obs=DARK', 'FSR1 run=2 eye=left obs=DARK'), 'INCONCLUSIVE', 'not a stage PASS', ''),
    @('R11 a duplicated period/eye', $passRec, ((RL 'DARK' 'DARK' 'DARK' 'DARK') + 'FSR1 run=2 eye=right obs=LIT'), 'INCONCLUSIVE', 'not a stage PASS', ''),
    @('R12 READ without chars', $passRec, (RL 'DARK' 'DARK' 'READ' 'DARK'), 'INCONCLUSIVE', 'not a stage PASS', ''),
    @('R14 one-eye correct in run 2 although run 2 was skipped: contradicts the record (not ONE-EYE ONLY)', (Rec (KPut (Get-K3b) 5 "FSK1 run=2 skipped reason=brightness-not-verified END`n" $null @{ code = [long]0 })), (RL 'DARK' 'DARK' "READ chars=$U8" 'DARK'), 'INCONCLUSIVE', 'not a stage PASS', ''),
    @('R15 both eyes correct in run 1 but the record is absent', $null, (RL "READ chars=$U8" "READ chars=$U8" 'DARK' 'DARK'), 'INCONCLUSIVE', 'not a stage PASS', ''),
    @('R16 one-eye correct in run 2 with the record rejected', ([pscustomobject]@{ Ok = $false; Reason = 'line-count'; Steps = $null }), (RL 'DARK' 'DARK' 'DARK' "READ chars=$U8"), 'INCONCLUSIVE', 'not a stage PASS', ''),
    @('R13 lower-case characters are not the uppercase challenge text', $passRec, (RL 'DARK' 'DARK' "READ chars=$U8" "READ chars=$U8".ToLowerInvariant()), 'INCONCLUSIVE', 'not a stage PASS', '')
)
foreach ($rc in $rcases) {
    $o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 $rc[1] -Nonce $KN -Challenge $KC -Readings $rc[2]
    if ($rc[0] -like 'R14*') { $rc[3] = $rc[3]; if ($o.OpticalReason -notmatch 'CONTRADICTS the record') { $o.Optical = 'R14: wrong reason ' + $o.OpticalReason } }
    if ($rc[0] -like 'R15*' -or $rc[0] -like 'R16*') { if ($o.OpticalReason -notmatch 'absent or unusable') { $o.Optical = 'wrong reason ' + $o.OpticalReason } }
    $labOk = if ($rc[5]) { @($o.Labels) -contains $rc[5] } else { $true }
    Check "$($rc[0]) -> $($rc[3]); $($rc[4])" ($o.Optical -ceq $rc[3] -and $o.Registered.StartsWith($rc[4]) -and $labOk) "optical '$($o.Optical)' ($($o.OpticalReason)); registered '$($o.Registered)'; labels $(@($o.Labels) -join '|')"
}
$o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 $passRec -Nonce $KN -Challenge $KC
Check 'R20 no readings: optical NOT RECORDED; never a stage PASS' ($o.Optical -ceq 'NOT RECORDED' -and $o.Registered -match 'optical NOT RECORDED')
$o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 (Rec (KPut (Get-K3b) 1 ("c7f28cc70f05387416c47d48707ab3e20bd3ba2306cf483516e353739519ad2a  /bin/fs-pattern`n"))) -Nonce $KN -Challenge $KC -Readings (RL "READ chars=$U8" "READ chars=$U8" "READ chars=$U8" "READ chars=$U8")
Check 'R21 correct readings with an INTEGRITY FAULT record: not a stage PASS' ($o.Outcome -ceq 'INTEGRITY FAULT' -and -not $o.Registered.StartsWith('STAGE PASS')) $o.Registered

# ------------------------------------------------------------------ P --------
Say '== P. harness captures through fs-collect.ps1 -Stage 3b, the classifier and the CLI'
$IMGFX = Join-Path $S3B 'fixtures\image'
$pcases = @(
    @('b-nodrm', 'NO-DISPLAY', 12, $false), @('b-no-backlight', 'INCONCLUSIVE', 8, $false), @('b-probe-hang', 'INCONCLUSIVE', 8, $false),
    @('b-pattern-stopped', 'DISPLAY FAIL', 9, $false), @('b-hung-pattern', 'DISPLAY FAIL', 9, $true),
    @('b-sim-go', 'PASS (machine side)', 25, $true), @('b-sim-active', 'PRECONDITION UNMET: CRTC ACTIVE', 21, $true), @('b-sim-unclean', 'RUN 1 ONLY', 15, $true))
$replays = @{}
foreach ($pc in $pcases) {
    $raw = Join-Path $IMGFX "$($pc[0])\capture.raw"
    if (-not (Test-Path -LiteralPath $raw)) { Skip "P $($pc[0])" 'no harness capture (run stage3b/test-image.sh)'; continue }
    $od = Join-Path $Scratch "replay-$($pc[0])"
    $kern = [regex]::Match([IO.File]::ReadAllText($raw), 'FSV1 nonce=[0-9a-f]{16} resp=[0-9a-f]{64} kernel=(\S+) pid1=(\S+) ')   # the sandbox kernel (WSL) and qemu-run PID 1, not the Quest's
    $r = Invoke-FsReplay -RawPath $raw -OutDir $od -Overrides @{ Stage = '3b'; Kernel = $kern.Groups[1].Value; Pid1 = $kern.Groups[2].Value }
    $replays[$pc[0]] = $r
    $ok = ($r.Status -ceq 'COLLECTED-VALID' -and $r.Stage -ceq '3b' -and $r.DeviceDeadlineSec -eq 200 -and (@($r.Sent) -join ',') -match 'fs-display [0-9a-f]{32}' -and
           (@($r.Sent) -contains 'fs-done') -and @($r.Replay.Divergence).Count -eq 0 -and $r.Replay.RecaptureIsSourcePrefix)
    Check "P1 $($pc[0]): replay COLLECTED-VALID, stage 3b, fs-display once, fs-done sent, no divergence" $ok "$($r.Status) $($r.StopReason) div=$(@($r.Replay.Divergence) -join ';')"
    $pin = $script:S3bPatternPin
    if ($pc[3]) {   # a fixture fs-pattern: first the real pin (INTEGRITY FAULT), then the measured digest for the machine logic
        $o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 $r.Fsb1Decoded -Nonce $r.Nonce -Challenge $r.Challenge -Collected ([bool]$r.RecordComplete)
        Check "P2 $($pc[0]): with the v0.5 pin the fixture fs-pattern is an INTEGRITY FAULT (rule 4)" ($o.Outcome -ceq 'INTEGRITY FAULT' -and $o.Rule -eq 4) "$($o.Outcome) $($o.Reason)"
        $pin = if ($r.Fsb1Decoded -and $r.Fsb1Decoded.Ok) { ([regex]::Match($script:S2L1.GetString([byte[]]$r.Fsb1Decoded.Steps[0]['out']), '^[0-9a-f]{64}')).Value } else { '' }
    }
    $o = Get-FsStage3bOutcome -Stage1Class PASS -Fsb1 $r.Fsb1Decoded -Nonce $r.Nonce -Challenge $r.Challenge -Collected ([bool]$r.RecordComplete) -PatternPin $pin
    Check "P3 $($pc[0]): -> $($pc[1]) (rule $($pc[2]))" ($o.Outcome -ceq $pc[1] -and $o.Rule -eq $pc[2]) "$($o.Outcome) rule $($o.Rule): $($o.Reason)"
}
if ($replays.ContainsKey('b-sim-go')) {
    $r = $replays['b-sim-go']
    $kernGo = [regex]::Match([IO.File]::ReadAllText($r.ReplaySource.Raw), 'FSV1 nonce=[0-9a-f]{16} resp=[0-9a-f]{64} kernel=(\S+) pid1=(\S+) ')
    $ix = [IO.File]::ReadAllLines($r.Capture.Index)
    $cue = [array]::FindIndex($ix, [Predicate[string]]{ param($l) $l -match '^N \d+ \d+ display-cue$' })
    $wr = [array]::FindIndex($ix, [Predicate[string]]{ param($l) $l -match '^W \d+ \d+ fs-display ' })
    $b1 = [array]::FindIndex($ix, [Predicate[string]]{ param($l) $l -match 'beep-1' })
    $b2 = [array]::FindIndex($ix, [Predicate[string]]{ param($l) $l -match 'beep-2' })
    $dn = [array]::FindIndex($ix, [Predicate[string]]{ param($l) $l -match '^W \d+ \d+ fs-done$' })
    $cms = [long]($ix[$cue].Split(' ')[2]); $wms = [long]($ix[$wr].Split(' ')[2])
    Check 'P10 order: N display-cue < W fs-display (>= 3 s later) < N beep-1 < N beep-2 < W fs-done' ($cue -ge 0 -and $cue -lt $wr -and $wr -lt $b1 -and $b1 -lt $b2 -and $b2 -lt $dn -and $wms - $cms -ge 3000) "$cue $wr $b1 $b2 $dn"
    $bp = @($r.Replay.Beeps)
    Check 'P11 two host beeps (1760 Hz/300 ms, 440 Hz/700 ms), none written to the device' ($bp.Count -eq 2 -and $bp[0] -like '1760/300@*' -and $bp[1] -like '440/700@*' -and -not (@($r.Sent) -match 'beep'))
    $d3 = Join-Path $Scratch 'cli-sim-go'; $null = New-Item -ItemType Directory -Force -Path $d3
    Copy-Item -LiteralPath $r.Capture.Path -Destination (Join-Path $d3 'capture.raw'); Save-FsCollectJson -Result $r -Path (Join-Path $d3 'collect.json')
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 3b -CollectDir $d3 -Stage1Class PASS
    Check 'P12 fs-classify.ps1 -Stage 3b CLI on a fixture-binary collection: INTEGRITY FAULT, exit 12; OPTICAL NOT RECORDED is printed' (($cl -join "`n") -match 'OUTCOME: INTEGRITY FAULT' -and ($cl -join "`n") -match 'OPTICAL: NOT RECORDED' -and $LASTEXITCODE -eq 12) ($cl -join ' / ')
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 3a -CollectDir $d3 -Stage1Class PASS
    Check 'P13 a stage-3b collection given to the stage-3a classifier: INCONCLUSIVE, exit 14' (($cl -join "`n") -match 'OUTCOME: INCONCLUSIVE \(the collection is stage 3b' -and $LASTEXITCODE -eq 14) ($cl -join ' / ')
    $rdf = Join-Path $d3 'readings.txt'; [IO.File]::WriteAllLines($rdf, [string[]](RL 'DARK' 'DARK' 'LIT' 'GARBLED'))
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 3b -CollectDir $d3 -Stage1Class PASS -Readings $rdf
    Check 'P14 ...with -Readings: the optical line LIT BUT GARBLED and a REGISTERED line' (($cl -join "`n") -match 'OPTICAL: LIT BUT GARBLED' -and ($cl -join "`n") -match 'REGISTERED: not a stage PASS') ($cl -join ' / ')
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 3a -CollectDir $d3 -Stage1Class PASS -Readings $rdf
    Check 'P15 -Readings with -Stage 3a: usage, exit 64' ($LASTEXITCODE -eq 64)
    # collector-side reassembly: re-chunk the record region at every 10-line boundary and mid-line
    $rawb = [IO.File]::ReadAllBytes((Join-Path $IMGFX 'b-sim-go\capture.raw'))
    $src = Read-FsCaptureIndex -Path (Join-Path $IMGFX 'b-sim-go\capture.raw.idx') -RawLength $rawb.Length
    $txt = $script:Latin1.GetString($rawb)
    $bg = $txt.IndexOf('FSB1 BEGIN'); $en = $txt.IndexOf("`n", $txt.IndexOf('FSB1 END')) + 1
    $cuts = New-Object System.Collections.Generic.List[long]
    $nl = 0; for ($p = $bg; $p -lt $en; $p++) { if ($rawb[$p] -eq 10) { $nl++; if ($nl % 20 -eq 0) { foreach ($d in 1, 1 + 37) { if ($p + $d -lt $en) { $cuts.Add($p + $d) } } } } }
    $ep = $txt.IndexOf('FSB1 END'); foreach ($d in 3, 50) { $cuts.Add($ep + $d) }
    $set = New-Object 'System.Collections.Generic.SortedSet[long]'; foreach ($c in $cuts) { [void]$set.Add($c) }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("FSIDX1 nonce=$($src.Nonce) mode=synthetic port=-")
    $wi = 0; $chunks = 0
    foreach ($c in $src.R) {
        while ($wi -lt $src.W.Count -and $src.W[$wi].Offset -le $c.Offset) { $lines.Add("W $($src.W[$wi].Offset) $($src.W[$wi].Ms) $($src.W[$wi].Text)"); $wi++ }
        $s0 = $c.Offset; $end = $c.Offset + $c.Length
        foreach ($k in $(if ($c.Length -gt 1) { @($set.GetViewBetween($c.Offset + 1, $end - 1)) } else { @() })) { $lines.Add("R $s0 $($k - $s0) $($c.Ms)"); $s0 = $k; $chunks++ }
        $lines.Add("R $s0 $($end - $s0) $($c.Ms)"); $chunks++
    }
    while ($wi -lt $src.W.Count) { $lines.Add("W $($src.W[$wi].Offset) $($src.W[$wi].Ms) $($src.W[$wi].Text)"); $wi++ }
    $sp = Join-Path $Scratch 'split.raw'; [IO.File]::WriteAllBytes($sp, $rawb); [IO.File]::WriteAllLines("$sp.idx", [string[]]$lines)
    $rs = Invoke-FsReplay -RawPath $sp -OutDir (Join-Path $Scratch 'split-out') -Overrides @{ Stage = '3b'; Kernel = $kernGo.Groups[1].Value; Pid1 = $kernGo.Groups[2].Value }
    Check "P16 the b-sim-go capture re-chunked at every paced chunk boundary and mid-line ($($set.Count) extra cuts, $chunks read chunks): COLLECTED-VALID, identical re-capture, same rec_sha256" `
        ($rs.Status -ceq 'COLLECTED-VALID' -and $rs.Replay.RecaptureIsSourcePrefix -and $rs.Capture.Bytes -eq $r.Capture.Bytes -and $rs.Capture.Sha256 -ceq $r.Capture.Sha256) "$($rs.Status) $($rs.StopReason)"
    # a capture cut inside the paced emission (the device stopped mid-record): no record, INCONCLUSIVE, fs-done not sent
    $cutAt = $txt.IndexOf("`n", $bg + [int](($en - $bg) / 2)) + 20
    $cb = New-Object byte[] $cutAt; [Array]::Copy($rawb, $cb, $cutAt)
    $cl2 = New-Object System.Collections.Generic.List[string]; $cl2.Add("FSIDX1 nonce=$($src.Nonce) mode=synthetic port=-")
    foreach ($ln in $lines | Select-Object -Skip 1) {
        if ($ln -cmatch '^R (\d+) (\d+) (\d+)$') { $o0 = [long]$Matches[1]; $n0 = [long]$Matches[2]; if ($o0 -ge $cutAt) { continue }; if ($o0 + $n0 -gt $cutAt) { $ln = "R $o0 $($cutAt - $o0) $($Matches[3])" } }
        elseif ($ln -cmatch '^W (\d+) ') { if ([long]$Matches[1] -gt $cutAt) { continue } }
        $cl2.Add($ln)
    }
    $cp = Join-Path $Scratch 'cut.raw'; [IO.File]::WriteAllBytes($cp, $cb); [IO.File]::WriteAllLines("$cp.idx", [string[]]$cl2)
    $rc2 = Invoke-FsReplay -RawPath $cp -OutDir (Join-Path $Scratch 'cut-out') -Overrides @{ Stage = '3b'; Kernel = $kernGo.Groups[1].Value; Pid1 = $kernGo.Groups[2].Value }
    Check 'P17 a record cut short mid-emission: INCONCLUSIVE, no record, fs-done NOT sent (the device deadline recovers)' ($rc2.Status -ceq 'INCONCLUSIVE' -and -not $rc2.RecordComplete -and -not $rc2.DoneSent) "$($rc2.Status) done=$($rc2.DoneSent) $($rc2.StopReason)"
    # the immediate runner guard: 75 + 5 + 11 = 91 s
    $sendMs = [long]($ix[$wr].Split(' ')[2])
    $rg = Invoke-FsReplay -RawPath $r.ReplaySource.Raw -OutDir (Join-Path $Scratch 'guard-out') -Overrides @{ Stage = '3b'; Kernel = $kernGo.Groups[1].Value; Pid1 = $kernGo.Groups[2].Value; GiveUpMs = [long]($sendMs - 3000 + 90000) }
    Check 'P18 runner guard: with < 91 s left (75 + 5 + 11) the runner is not sent; INCONCLUSIVE' (-not $rg.ValveSent -and $rg.StopReason -match 'runner budget: .* needs 91 s') "$($rg.StopReason)"
}

# ------------------------------------------------------------------ E --------
Say '== E. paced vs unpaced emission (PowerShell decoder)'
$PX = Join-Path $S3B 'fixtures\pace'
foreach ($n in 'representative', 'at-caps', 'maximum') {
    $u = Join-Path $PX "$n-unpaced.rec"; $p = Join-Path $PX "$n-paced.rec"
    if (-not (Test-Path $u) -or -not (Test-Path $p)) { Skip "E $n" 'run stage3b/tools/pace_evidence.py'; continue }
    [byte[]]$ub = [IO.File]::ReadAllBytes($u); [byte[]]$pb = [IO.File]::ReadAllBytes($p)
    $du = Test-Fsb1Record -Bytes $ub -Exp 'stage3b' -Nonce '3b3b3b3b0011aa55' -Challenge 'c0ffee3b0123456789abcdef01234567' -Steps @('hash', 'probe1', 'pattern1', 'probe2', 'pattern2')
    $dp = Test-Fsb1Record -Bytes $pb -Exp 'stage3b' -Nonce '3b3b3b3b0011aa55' -Challenge 'c0ffee3b0123456789abcdef01234567' -Steps @('hash', 'probe1', 'pattern1', 'probe2', 'pattern2')
    $hu = [regex]::Match($script:Latin1.GetString($ub), 'rec_sha256=([0-9a-f]{64})').Groups[1].Value
    $hp = [regex]::Match($script:Latin1.GetString($pb), 'rec_sha256=([0-9a-f]{64})').Groups[1].Value
    $lines = ([regex]::Matches($script:Latin1.GetString($pb), "`n")).Count - 1
    Check "E1 $n ($lines lines): paced bytes == unpaced bytes; fsb1.ps1 VALID on both; same rec_sha256" (([FsHostNative]::DiffIndices($ub, $pb)).Length -eq 0 -and $ub.Length -eq $pb.Length -and $du.Ok -and $dp.Ok -and $hu -ceq $hp -and $hu.Length -eq 64) "$($du.Reason)/$($dp.Reason)"
}
if (Test-Path (Join-Path $PX 'maximum-paced.rec')) {
    $pb = [IO.File]::ReadAllBytes((Join-Path $PX 'maximum-paced.rec'))
    Check 'E2 the maximum record has exactly MAXLINES = 2070 record lines (+ the leading empty line)' (([regex]::Matches($script:Latin1.GetString($pb), "`n")).Count -eq 2071)
    $cb = [IO.File]::ReadAllBytes((Join-Path $PX 'at-caps-paced.rec'))
    Check 'E3 the at-caps record (every step at its cap, the hash stderr at its cap) has 2069 lines <= MAXLINES 2070' (([regex]::Matches($script:Latin1.GetString($cb), "`n")).Count -eq 2070)
}

# ------------------------------------------------------------------ D --------
Say '== D. the damaged trial-(iii) capture'
$tdir = Join-Path $ROOT 'relays\FS-A-010-raw\observe\collect'
if (-not (Test-Path (Join-Path $tdir 'capture.raw'))) { Skip 'D1-D4 the damaged trial-(iii) capture' 'withheld evidence: relays/FS-A-010-raw is not in the public copy' } else {
[byte[]]$traw = [IO.File]::ReadAllBytes((Join-Path $tdir 'capture.raw'))
$tj = Get-Content -Raw (Join-Path $tdir 'collect.json') | ConvertFrom-Json
$td = Test-Fsb1Record -Bytes $traw -Exp 'stage3a' -Nonce $tj.Nonce -Challenge $tj.Challenge -Steps @('hash', 'pattern')
Check 'D1 fsb1.ps1 still REJECTs the trial-(iii) capture with line-count' (-not $td.Ok -and $td.Reason -ceq 'line-count') "$($td.Reason) $($td.Detail)"
$to = Get-FsStage3aOutcome -Stage1Class PASS -Fsb1 $td -Nonce $tj.Nonce -Challenge $tj.Challenge -Collected ([bool]$tj.RecordComplete)
Check 'D2 the unchanged stage-3a classifier reproduces the registered outcome: INCONCLUSIVE, OUTCOMES §8 rule 2, FSB1 rejected: line-count' ($to.Outcome -ceq 'INCONCLUSIVE' -and $to.Rule -eq 2 -and $to.Reason -match 'line-count') "$($to.Outcome) $($to.Rule) $($to.Reason)"
$cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 3a -CollectDir $tdir -ObserveDir (Split-Path -Parent $tdir)
Check 'D3 fs-classify.ps1 -Stage 3a CLI on the bundled trial-(iii) directories: STAGE-1 PASS, OUTCOME INCONCLUSIVE rule 2 line-count, exit 14 (the registered result)' (($cl -join "`n") -match 'STAGE-1 CLASS: PASS' -and ($cl -join "`n") -match 'OUTCOME: INCONCLUSIVE   \(OUTCOMES (§|\\xa7)8 rule 2\) FSB1 rejected: line-count' -and $LASTEXITCODE -eq 14) ($cl -join ' / ')
$td3 = Test-Fsb1Record -Bytes $traw -Exp 'stage3b' -Nonce $tj.Nonce -Challenge $tj.Challenge -Steps $script:S3bSteps
Check 'D4 ...and decoded as stage 3b it is rejected too (line-count is checked before the experiment id)' (-not $td3.Ok -and $td3.Reason -ceq 'line-count')
}  # end of the section-D evidence guard

# ------------------------------------------------------------------ O --------
Say '== O. fs-observe.ps1 -Stage 3b: the BA dwell gate'
function New-ObsBuild3b([string]$nonce, [string]$probeHash = '') {
    $base = Join-Path $Scratch ("obs3b-" + (New-FsHex 3)); $bd = Join-Path $base "build\stage3b\20261010T090000Z-$nonce"
    $null = New-Item -ItemType Directory -Force -Path $bd
    $img = Join-Path $bd 'boot-stage3b.img'; [IO.File]::WriteAllBytes($img, [byte[]](1..64 | ForEach-Object { [byte]$_ }))
    $h = { param($f) (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Q3 $f)).Hash.ToLower() }
    if (-not $probeHash) { $probeHash = & $h 'stage3b\fs-probe.sh' }
    $m = "FrameShift Quest 3 stage-3b image (display test trial (iii-b), fs-pattern v0.5) — ONE ATTEMPT ONLY, never reuse`nbuilt:            20261010T090000Z`nnonce:            $nonce   (USB serial FS-$nonce)`n" +
         "OUTPUT IMAGE:     boot-stage3b.img  size=64  sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $img).Hash.ToLower())`n`n" +
         "stock boot        49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50  x`nstock vendor_boot 1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf  x`n" +
         "init.sh source    $(& $h 'stage3b\init.sh')  (recorded)`nfs-display.sh     $(& $h 'stage3b\fs-display.sh')  (recorded)`nfs-probe.sh       $probeHash  (recorded)`n"
    [IO.File]::WriteAllText((Join-Path $bd 'MANIFEST.txt'), $m, (New-Object System.Text.UTF8Encoding($false)))
    [pscustomobject]@{ Img = $img; Root = (Join-Path $base 'build\stage3b'); Dir = $bd; Base = $base }
}
function New-Summary([string]$dir, [string]$phase, [string]$nonce, [string]$utc, [string]$final = '', [string]$serial = 'QUEST3UNIT1') {
    $null = New-Item -ItemType Directory -Force -Path $dir
    if (-not $final) { $final = "PHASE $phase OK: 15 rows captured in $dir" }
    $p = Join-Path $dir 'SUMMARY.txt'
    [IO.File]::WriteAllLines($p, [string[]]@("# fs-capture.ps1 phase $phase nonce $nonce serial $serial  $utc", "# adb x  fastboot y  commands z", "# id`texit`tbytes`tsha256`tfile", "${phase}01`t0`t1`tab`tf", $final))
    $p
}
function Invoke-Obs3b($b, [string]$nonce, [string]$ba, [string]$bf, [DateTime]$clock) {
    $script:fk3 = [pscustomobject]@{ Calls = (New-Object System.Collections.Generic.List[string]); Polls = 0; Clock = $clock; Lines = (New-Object System.Collections.Generic.List[string]) }
    Invoke-FsObserve -Stage 3b -ImagePath $b.Img -ConfirmNonce $nonce -Preflight $false -BuildRoot $b.Root -Q3 $Q3 -GadgetWaitSec 10 -BaSummary $ba -BfSummary $bf `
        -Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) $f = $script:fk3; $f.Calls.Add(($ArgList -join ' ')); $f.Clock = $f.Clock.AddMilliseconds(300)
            if ($ArgList[0] -ceq 'devices') { return [pscustomobject]@{ ExitCode = 0; StdOut = "QUEST3UNIT1`tfastboot`r`n"; StdErr = ''; TimedOut = $false; Error = $null } }
            $f.Clock = $f.Clock.AddSeconds(11); [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = "Booting OKAY`n"; TimedOut = $false; Error = $null } } `
        -Gadget { param([string]$N) $f = $script:fk3; $f.Polls++; [pscustomobject]@{ Present = $true; SerialOk = $true; Serials = @("FS-$N"); ComPort = 'COM9'; Parent = 'x' } } `
        -NowUtc { $script:fk3.Clock } -Sleep { param([int]$Ms) $script:fk3.Clock = $script:fk3.Clock.AddMilliseconds($Ms) } -Say { param([string]$Line) $script:fk3.Lines.Add($Line) }
}
$T0 = [DateTime]::Parse('2026-10-10T09:00:00Z').ToUniversalTime()
$n1 = 'c0de3b0000000001'; $b1 = New-ObsBuild3b $n1
$ba = New-Summary (Join-Path $b1.Base 'cap\BA') 'BA' $n1 '2026-10-10T08:56:00.0000000Z'; $bf = New-Summary (Join-Path $b1.Base 'cap\BF') 'BF' $n1 '2026-10-10T08:57:30.0000000Z'
$o = Invoke-Obs3b $b1 $n1 $ba $bf $T0
$ojson = Get-Content -Raw (Join-Path $o.OutDir 'observe.json') | ConvertFrom-Json
$olog = [IO.File]::ReadAllText((Join-Path $o.OutDir 'observe.log'))
Check 'O1b the dwell result is in observe.json (BaStartUtc, DwellSec 240.3, DwellAtBootStartSec, max 300) and in observe.log' ($ojson.BaStartUtc -match '^2026-10-10T08:56:00' -and [double]$ojson.DwellSec -eq 240.3 -and [double]$ojson.DwellAtBootStartSec -ge 240.3 -and [double]$ojson.DwellAtBootStartSec -le 300 -and $ojson.DwellMaxSec -eq 300 -and $olog -match 'dwell gate: BA started 2026-10-10T08:56:00') "$($ojson.DwellSec) $($ojson.DwellAtBootStartSec)"
Check 'O1 BA 240 s before: the dwell gate passes; the attempt is registered and booted (devices, then boot)' ($o.Exit -eq 0 -and $script:fk3.Calls.Count -eq 2 -and $script:fk3.Calls[1] -match ' boot ' -and (Test-Path (Join-Path $b1.Root "attempted\$n1.attempted")) -and (@($script:fk3.Lines) -match 'dwell gate OK: dwell 240 s').Count -ge 1) "$($o.Why) | $($script:fk3.Lines -join ' | ')"
$n2 = 'c0de3b0000000002'; $b2 = New-ObsBuild3b $n2
$ba = New-Summary (Join-Path $b2.Base 'cap\BA') 'BA' $n2 '2026-10-10T08:54:59.0000000Z'; $bf = New-Summary (Join-Path $b2.Base 'cap\BF') 'BF' $n2 '2026-10-10T08:57:00.0000000Z'
$o = Invoke-Obs3b $b2 $n2 $ba $bf $T0
$ab = @(Get-ChildItem -LiteralPath (Join-Path $b2.Root 'abandoned') -Filter "*-$n2.txt" -ErrorAction SilentlyContinue)
Check 'O2 BA 301 s before: REFUSED before the boot (only the read-only devices query), attempt NOT registered, abandoned-cycle record written' ($o.Exit -eq 2 -and $o.Why -match 'dwell cap expired' -and $script:fk3.Calls.Count -eq 1 -and $script:fk3.Calls[0] -ceq 'devices' -and
    -not (Test-Path (Join-Path $b2.Root "attempted\$n2.attempted")) -and $ab.Count -eq 1 -and ([IO.File]::ReadAllText($ab[0].FullName)) -match 'nonce c0de3b0000000002 is unspent') "$($o.Why) calls=$($script:fk3.Calls -join ',')"
$o = Invoke-Obs3b $b2 $n2 $ba $bf $T0.AddSeconds(-2)
Check 'O3 the same image with a fresh cycle (BA 299 s before) is then accepted: the nonce was not spent' ($o.Exit -eq 0 -and $script:fk3.Calls.Count -eq 2) $o.Why
$n3 = 'c0de3b0000000003'; $b3 = New-ObsBuild3b $n3
$ba3 = New-Summary (Join-Path $b3.Base 'cap\BA') 'BA' $n3 '2026-10-10T08:58:00.0000000Z'
$o = Invoke-Obs3b $b3 $n3 $ba3 '' $T0
Check 'O4 no -BfSummary: refused, no boot, no abandoned record' ($o.Exit -eq 2 -and $o.Why -match 'BF summary: not given' -and $script:fk3.Calls.Count -eq 1 -and -not (Test-Path (Join-Path $b3.Root 'abandoned'))) $o.Why
$bfx = New-Summary (Join-Path $b3.Base 'cap\BFx') 'BF' 'ffffffffffffffff' '2026-10-10T08:59:00.0000000Z'
$o = Invoke-Obs3b $b3 $n3 $ba3 $bfx $T0
Check 'O5 a BF summary of another nonce: refused' ($o.Exit -eq 2 -and $o.Why -match "nonce ffffffffffffffff is not this attempt") $o.Why
$bfs = New-Summary (Join-Path $b3.Base 'cap\BFs') 'BF' $n3 '2026-10-10T08:59:00.0000000Z' 'PHASE BF STOP: BF03 exit 1'
$o = Invoke-Obs3b $b3 $n3 $ba3 $bfs $T0
Check 'O6 a BF that did not end OK: refused' ($o.Exit -eq 2 -and $o.Why -match 'did not end OK') $o.Why
$bfe = New-Summary (Join-Path $b3.Base 'cap\BFe') 'BF' $n3 '2026-10-10T08:57:00.0000000Z'
$o = Invoke-Obs3b $b3 $n3 $ba3 $bfe $T0
Check 'O7 BF started before BA: refused' ($o.Exit -eq 2 -and $o.Why -match 'BF started before BA') $o.Why
$baf = New-Summary (Join-Path $b3.Base 'cap\BAf') 'BA' $n3 '2026-10-10T09:05:00.0000000Z'; $bff = New-Summary (Join-Path $b3.Base 'cap\BFf') 'BF' $n3 '2026-10-10T09:06:00.0000000Z'
$o = Invoke-Obs3b $b3 $n3 $baf $bff $T0
Check 'O8 a BA start in the future: refused (clock step or wrong file)' ($o.Exit -eq 2 -and $o.Why -match 'in the future') $o.Why
$n4 = 'c0de3b0000000004'; $b4 = New-ObsBuild3b $n4 ('0' * 64)
$o = Invoke-Obs3b $b4 $n4 $ba3 $bfe $T0
Check 'O9 a 3b image built from another fs-probe.sh than the repository''s: refused (MANIFEST sources check)' ($o.Exit -eq 2 -and $o.Why -match 'fs-probe.sh') $o.Why
$bao = New-Summary (Join-Path $b3.Base 'cap\BAo') 'BA' $n3 '2026-10-10T08:58:00.0000000Z' '' 'OTHERSERIAL1'
$o = Invoke-Obs3b $b3 $n3 $bao $bff $T0
Check 'O10 a BA summary of another serial: refused' ($o.Exit -eq 2 -and $o.Why -match 'serial OTHERSERIAL1') $o.Why

# ------------------------------------------------------------------ T --------
Say '== T. timing checks'
if ($python) {
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $t3 = & $python -I -B (Join-Path $S3B 'tools\check-timing-3b.py') 2>&1
    Check 'T1 stage3b/tools/check-timing-3b.py: TIMING 3B CONSISTENT (W 74.4 s <= B 85 s; guard 91 s; DEADLINE 200; caps consistent with MAXLINES 2070; 20 lines per chunk)' ($LASTEXITCODE -eq 0 -and ($t3 -join "`n") -match 'TIMING 3B: CONSISTENT' -and ($t3 -join "`n") -match 'W = .* = 74\.4 s' -and ($t3 -join "`n") -match '= 91 s left' -and ($t3 -join "`n") -match '= 2069 <= MAXLINES 2070' -and ($t3 -join "`n") -match 'pacing: 20 lines per chunk \(fs-display.sh override') (($t3 | Select-Object -Last 3) -join ' / ')
    $t2 = & $python -I -B (Join-Path $Q3 'stage2a\tools\check-timing.py') 2>&1
    Check 'T2 stage2a/tools/check-timing.py (stages 2a and 3a, unchanged): TIMING CONSISTENT with the revised collector' ($LASTEXITCODE -eq 0 -and ($t2 -join "`n") -match 'TIMING: CONSISTENT')
} else { Skip 'T timing' 'python not found' }

Say ("TOTAL: {0} passed, {1} failed, {2} skipped" -f $script:pass, $script:fail, $script:skip)
[IO.File]::WriteAllLines($OutFile, [string[]]$script:log, (New-Object System.Text.UTF8Encoding($false)))
if ($script:fail -ne 0) { exit 1 }
exit 0
