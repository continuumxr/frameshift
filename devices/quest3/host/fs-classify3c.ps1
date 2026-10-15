# FrameShift outcome classifier, STAGE 3C (interactive, per phase), Windows PowerShell 5.1, no modules.
# Design: devices/quest3/stage3c/DESIGN.md revision 3, section 11 (proposed OUTCOMES section 10),
# with the protocol facts of section 5 (FSPM1 markers, FSXE1 refusals, per-phase FSB1 records) and the
# readings record of section 8.5 (FSR2).
#
# Also the shared stage-3c protocol library: fs-collect3c.ps1 dot-sources this file for the per-phase
# experiment ids and step lists, the FSPM1/FSXE1 parsers, the run-3 rule (DESIGN 5.8) and the run facts
# it needs for control flow (never shown to the PM before the readings).
#
# CLI (after the session; machine and optical results stay separate, FS-R-011 section 3):
#   fs-classify3c.ps1 -C3cDir <fs-collect3c output dir> (-C3cObserveDir <fs-observe3c output dir> | -C3cStage1Class <class>)
#                     [-C3cPatternPin <sha256>: default the built-in v0.6 pin $script:S3cPatternPin] [-C3cReadings <readings3c.txt>]
#   Inputs: capture.raw + capture.raw.idx (the phase slices are RE-DERIVED here and must equal the
#   collector's, else INCONCLUSIVE), session.json, readings3c.txt, observe.json.
#   Exit: 10 PASS (machine side), 12 INTEGRITY FAULT, 13 stage 1 not PASS, 14 INCONCLUSIVE, 15 NO-DISPLAY,
#         16 DISPLAY FAIL, 17 PRECONDITION UNMET (not reached in 3c: see RUN 1 ONLY), 18 RUN 1 ONLY,
#         64 usage, 70 internal error (as 3b; revision 1's exit 19 is withdrawn).
#
# M4 (DESIGN 8.1): the parameter names of this file collide with none of fs-collect.ps1's or
# fs-classify.ps1's; it never reads or assigns $Stage (or any other name of those param() blocks).
#
# FSP1 value grammar (pinned: stage3b/tools/check_stream.py, fs-classify.ps1 Test-FsFsp1Stream): keys
# [a-z_0-9]+, values [A-Za-z0-9_./%-]+. ONE list encoding (integration pass; DESIGN 6.2, stage3c/README 5
# item 1): a v0.6 plan list is '.'-separated with no %XX, the stage-3b packed-list convention (prop_list
# names=SRC%2EX.a%2Fb: '.' separates the elements): quad_vig=71.97.100.103, quad_dma=115.134.112.131,
# pipe_vig=vig-0.vig-1.vig-2.vig-3, max_upscale_vig=20.20.20.20, zpos_before_vig=0.0.0.0, zpos_set=0.0.1.1;
# an unavailable attempt reads quad_<x>=unavailable-missing|unavailable-ambiguous and its other lists '-'.
# ConvertTo-Fs3cIntList accepts exactly that form (anything else, a %XX value included, reads as no list).
# Per-attempt keys carry _vig/_dma. Keys are lower case; post_plane: slot plane crtc_id fb_id crtc_x crtc_y
# crtc_w crtc_h src_x src_y src_w src_h src_frac zpos, CRTC_X/Y raw signed, SRC_* in whole pixels (raw >> 16)
# with src_frac = the OR of the fractional parts (0). The selected planes' type comes from plane_caps
# (plane=<id> ... max_upscale=<n> smart=<id|none>) or the plan's max_upscale_vig / max_upscale_dma lists.
#
# Q7 fallback (DESIGN 15 Q7, PM rehearsal 2026-10-12): on the run-3 path the collector does not ask the bar counts; the
# readings carry bars_<eye> NOT_ASKED and session.json's r2 phase names them (Q7Fallback). Such an item is expected:
# no LAYOUT line for a `c` eye (nothing was asked), a `d` eye's F/line still reported; one READINGS NOTE line; never
# a reason for INCONCLUSIVE.
param(
    [string]$C3cDir = '',
    [string]$C3cObserveDir = '',
    [string]$C3cStage1Class = '',
    [string]$C3cPatternPin = '',
    [string]$C3cReadings = ''
)
$script:Fc3cArgs = @{} + $PSBoundParameters
$script:Fc3cInvocation = $MyInvocation.InvocationName
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'fs-classify.ps1')     # read only: Test-FsFsp1Stream, Get-FsS3HashClass, Test-FsS2ToolFault, Get-FsS3bRun, Get-FsS3bProbeBl, Get-FsStage1Class, Test-Fsb1Record
# the capture-index reader and the line/record finders of the pinned collector (already loaded when fs-collect3c.ps1 dot-sources this file)
if (-not (Get-Command Read-FsCaptureIndex -CommandType Function -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'fs-collect.ps1') }

# ------------------------------------------------------------ protocol ------
$script:S3cPhases = @('p0', 'r1', 'r2', 'r3')
$script:S3cExp = @{ p0 = 's3c_p0'; r1 = 's3c_r1'; r2 = 's3c_r2'; r3 = 's3c_r3' }
$script:S3cSteps = @{ p0 = @('hash', 'probe0'); r1 = @('probe1', 'pattern1'); r2 = @('probe2', 'pattern2'); r3 = @('probe3', 'pattern3') }
$script:S3cMode = @{ r1 = 'show'; r2 = 'show-off-quad'; r3 = 'show-off-solid' }
$script:S3cPatternPin = '066bdc3ee01e5974518f96e8311c071c8f3aed302cadefa42c1273d5196b27bc'   # fs-pattern v0.6, build-review rebuild (stage3c/build-image.sh EXPECT_FS_PATTERN, BUILD-RECORD.txt)
$script:S3cZpos = @(0, 0, 1, 1)
$script:S3cNoDisp = @{ 10 = 'no device'; 11 = 'not a DRM node'; 12 = 'driver is not msm_drm'; 20 = 'no connected connector'; 21 = 'atomic/planes/properties unusable'
                       30 = 'mode refused by the policy'; 40 = 'buffer/framebuffer failed'; 50 = 'no quad attempt accepted or available (nothing committed)' }
$script:S3cMarkerRe = '^FSPM1 n=([0-9a-f]{16}) p=(p0|r1|r2|r3) e=(begin|go|end|skip|rec) t=([0-9]{1,12}) END\z'
$script:S3cMarkerMax = 64       # bytes, the newline included (DESIGN 5.4)
$script:S3cRefusalTag = 'FSXE1'

# FSPM1 (DESIGN 5.4). A marker is informational only: a wrong nonce, a bad grammar, an over-long line
# or another phase is reported and ignored. Returns @{ Ok; Why; Ph; E; T }.
function ConvertFrom-Fs3cMarker {
    param([string]$Line, [string]$NonceX, [string]$PhX = '', [int]$RawLength = -1)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Ph = $null; E = $null; T = $null } }
    if ($null -eq $Line -or -not $Line.StartsWith('FSPM1', [StringComparison]::Ordinal)) { return (& $no 'not a marker') }
    $len = if ($RawLength -ge 0) { $RawLength } else { $Line.Length + 1 }
    if ($len -gt $script:S3cMarkerMax) { return (& $no "marker longer than $($script:S3cMarkerMax) bytes ($len)") }
    if ($Line -cnotmatch $script:S3cMarkerRe) { return (& $no 'marker grammar') }
    $m = $Matches
    if ($m[1] -cne $NonceX) { return (& $no "marker nonce $($m[1]) is not the image nonce") }
    if ($PhX -and $m[2] -cne $PhX) { return (& $no "marker for phase $($m[2]) during phase $PhX") }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; Ph = $m[2]; E = $m[3]; T = [long]$m[4] }
}
# Markers in a slice, with the order check (begin < go|skip < end < rec; none after the record started).
function Get-Fs3cSliceMarkers {
    param([byte[]]$Bytes, [string]$NonceX, [string]$PhX)
    $t = $script:S2L1.GetString($Bytes)
    $ok = New-Object System.Collections.Generic.List[object]; $notes = New-Object System.Collections.Generic.List[string]
    $inRec = $false
    foreach ($raw in $t.Split([char]10)) {
        $l = $raw.TrimEnd([char]13)
        if ($l.StartsWith('FSB1 BEGIN', [StringComparison]::Ordinal)) { $inRec = $true }
        if (-not $l.StartsWith('FSPM1', [StringComparison]::Ordinal)) { continue }
        $m = ConvertFrom-Fs3cMarker -Line $l -NonceX $NonceX -PhX $PhX -RawLength ($raw.Length + 1)
        if (-not $m.Ok) { $notes.Add("marker ignored: $($m.Why)"); continue }
        if ($inRec) { $notes.Add("marker $($m.E) inside or after the record (ignored)"); continue }
        $ok.Add($m)
    }
    $seq = @($ok | ForEach-Object { $_.E }) -join ','
    $legal = @('begin,rec', 'begin,go,end,rec', 'begin,skip,rec', 'begin,go,rec', 'begin,go,end', 'begin,go', 'begin,skip', 'begin', '')
    if ($legal -notcontains $seq) { $notes.Add("marker order '$seq' is not begin, go|skip, end, rec") }
    if ($ok.Count -gt 4) { $notes.Add("$($ok.Count) markers (at most 4 per phase)") }
    [pscustomobject]@{ Markers = $ok.ToArray(); Sequence = $seq; Notes = $notes.ToArray() }
}

# FSXE1 p=<ph|-> ran=<0|1> error=<why> END (DESIGN 5.2). An unreadable `ran` is treated as ran=1 (light
# may have happened: the safe direction for the prompts). Returns @{ Ph; Ran; RanRaw; Error; Raw }.
function Get-Fs3cRefusalInfo {
    param([string]$Line)
    $r = ConvertFrom-FsRecord -Line $Line -Tag 'FSXE1'
    if ($null -eq $r) { return $null }
    $ranRaw = if ($r.ContainsKey('ran')) { [string]$r['ran'] } else { '' }
    $ran = if ($ranRaw -ceq '0') { 0 } else { 1 }
    $err = if ($r.ContainsKey('error')) { [string]$r['error'] } else { '' }
    [pscustomobject]@{ Ph = $(if ($r.ContainsKey('p')) { [string]$r['p'] } else { '' }); Ran = $ran; RanRaw = $ranRaw; Error = $err; Raw = (ConvertTo-FsPrintable $Line) }
}

# ------------------------------------------------------------ run facts ------
# A v0.6 '.'-separated number list (1..8 canonical decimals, no %XX; see the header). Anything else
# (a '-' placeholder, unavailable-<why>, a %XX-encoded or ','-separated value) yields no number.
function ConvertTo-Fs3cIntList { param([string]$V)     # wrap the call in @(): the numbers go to the pipeline
    if (-not $V -or $V -cnotmatch '^(0|[1-9][0-9]{0,9})(\.(0|[1-9][0-9]{0,9})){0,7}\z') { return }
    foreach ($x in $V.Split('.')) { [long]$x }
}
# A pattern step (pattern1/2/3) parsed: the stage-3b facts (Get-FsS3bRun: kind, code, mode, commit, hold,
# close, monotonic stamps, precondition) plus the v0.6 records: commit layout, test_commit list, plan,
# plane_caps, post_plane (per slot), post_state, zpos.
function Get-Fs3cRun {
    param([hashtable]$St, [int]$Run, [string]$Chal8)
    $r = Get-FsS3bRun $St $Run $Chal8
    $r | Add-Member NoteProperty CommitLayout $null
    $r | Add-Member NoteProperty TestCommits @()
    $r | Add-Member NoteProperty Plan $null
    $r | Add-Member NoteProperty PlaneCaps @()
    $r | Add-Member NoteProperty PostPlanes @()
    $r | Add-Member NoteProperty PostState $null
    $r | Add-Member NoteProperty ZposSet $null
    $r | Add-Member NoteProperty ZposOutsideQuad $false
    if ($r.Kind -cne 'run') { return $r }
    $recs = @($r.Recs)
    $cm = @($recs | Where-Object { $_.Step -ceq 'commit' })
    if ($cm.Count -eq 1 -and $cm[0].Kv.ContainsKey('layout')) { $r.CommitLayout = $cm[0].Kv['layout'] }
    $r.TestCommits = @($recs | Where-Object { $_.Step -ceq 'test_commit' } | ForEach-Object { [pscustomobject]@{ Layout = $_.Kv['layout']; Rc = $_.Rc; Result = $_.Kv['result'] } })
    $pl = @($recs | Where-Object { $_.Step -ceq 'plan' })
    if ($pl.Count -ge 1) { $r.Plan = $pl[0].Kv; if ($pl[0].Kv.ContainsKey('zpos_set')) { $r.ZposSet = @(ConvertTo-Fs3cIntList $pl[0].Kv['zpos_set']) } }
    $r.PlaneCaps = @($recs | Where-Object { $_.Step -ceq 'plane_caps' } | ForEach-Object { $_.Kv })
    $r.PostPlanes = @($recs | Where-Object { $_.Step -ceq 'post_plane' } | ForEach-Object { $_.Kv })
    $ps = @($recs | Where-Object { $_.Step -ceq 'post_state' }); if ($ps.Count -ge 1) { $r.PostState = $ps[0].Kv }
    foreach ($x in @($recs | Where-Object { $_.Step -ceq 'test_commit' -or $_.Step -ceq 'commit' })) {
        if ($x.Kv['layout'] -cnotmatch '^quad_(vig|dma)\z' -and @($x.Kv.Keys | Where-Object { $_ -like 'zpos*' }).Count) { $r.ZposOutsideQuad = $true }
    }
    if ($r.Mode -ceq 'show' -and $null -ne $r.ZposSet) { $r.ZposOutsideQuad = $true }
    $r
}
# The committed quad layout against the plan after the kernel's right-half conversion (E17):
# slot k: SRC_X 1032k, CRTC_X 0/1032/0/1032, W 1032, Y 0, H 2208, zpos 0/0/1/1.
function Test-Fs3cQuadPost {
    param($RunX)
    $o = [ordered]@{ Ok = $false; Why = ''; Unconverted = $false; ZposBad = $false; TypeBad = $false; TypeNote = '' }
    if ($RunX.CommitLayout -cnotmatch '^quad_(vig|dma)\z') { $o.Why = "committed layout '$($RunX.CommitLayout)' is not quad_vig/quad_dma"; return [pscustomobject]$o }
    $pp = @($RunX.PostPlanes)
    if ($pp.Count -ne 4) { $o.Why = "$($pp.Count) post_plane records (4 expected)"; return [pscustomobject]$o }
    $slots = @{}
    for ($i = 0; $i -lt 4; $i++) { $k = if ($pp[$i].ContainsKey('slot') -and $pp[$i]['slot'] -cmatch '^[0-3]\z') { [int]$pp[$i]['slot'] } else { $i }; $slots[$k] = $pp[$i] }
    if ($slots.Count -ne 4) { $o.Why = 'post_plane slots are not 0..3'; return [pscustomobject]$o }
    $num = { param($h, [string]$key) if ($h.ContainsKey($key) -and $h[$key] -cmatch '^[0-9]{1,15}\z') { [long]$h[$key] } else { $null } }
    $px = { param($v, [long]$want) $null -ne $v -and $v -eq $want }     # SRC_* in whole pixels (raw >> 16), src_frac separately
    $bad = New-Object System.Collections.Generic.List[string]; $unconv = 0
    for ($k = 0; $k -lt 4; $k++) {
        $h = $slots[$k]
        if (-not $h.ContainsKey('src_frac') -or [string]$h['src_frac'] -cne '0') { $bad.Add("slot $k src_frac=$(if ($h.ContainsKey('src_frac')) { $h['src_frac'] } else { 'absent' }) (expected 0: whole-pixel source)") }
        $cx = & $num $h 'crtc_x'; $conv = [long](1032 * ($k % 2)); $plan = [long](1032 * $k)
        if ($cx -ne $conv) { if ($k -ge 2 -and $cx -eq $plan) { $unconv++ } else { $bad.Add("slot $k crtc_x=$cx (expected $conv)") } }
        if (-not (& $px (& $num $h 'src_x') $plan)) { $bad.Add("slot $k src_x=$(& $num $h 'src_x') (expected $plan)") }
        if ((& $num $h 'crtc_w') -ne 1032 -or -not (& $px (& $num $h 'src_w') 1032)) { $bad.Add("slot $k width") }
        if ((& $num $h 'crtc_y') -ne 0 -or (& $num $h 'src_y') -ne 0) { $bad.Add("slot $k y") }
        if ((& $num $h 'crtc_h') -ne 2208 -or -not (& $px (& $num $h 'src_h') 2208)) { $bad.Add("slot $k height") }
        if ((& $num $h 'zpos') -ne $script:S3cZpos[$k]) { $o.ZposBad = $true; $bad.Add("slot $k zpos=$(& $num $h 'zpos') (expected $($script:S3cZpos[$k]))") }
    }
    if ($null -eq $RunX.ZposSet -or (@($RunX.ZposSet) -join ',') -cne '0,0,1,1') { $o.ZposBad = $true; $bad.Add("plan zpos_set '$(@($RunX.ZposSet) -join ',')' is not 0,0,1,1 by slot") }
    # type of the committed planes (max_upscale: VIG 20, DMA 1), from plane_caps of the committed plane ids, else the plan list
    $want = if ($RunX.CommitLayout -ceq 'quad_vig') { 20 } else { 1 }
    $ups = @()
    foreach ($k in 0..3) {
        $pid0 = [string]$slots[$k]['plane']
        $cap = @($RunX.PlaneCaps | Where-Object { [string]$_['plane'] -ceq $pid0 -and $_.ContainsKey('max_upscale') })
        if ($pid0 -and $cap.Count -ge 1) { $ups += [long](@(ConvertTo-Fs3cIntList $cap[0]['max_upscale'])[0]) }
    }
    $pk = if ($want -eq 20) { 'max_upscale_vig' } else { 'max_upscale_dma' }
    if ($ups.Count -ne 4 -and $null -ne $RunX.Plan) {
        if ($RunX.Plan.ContainsKey($pk)) { $l = @(ConvertTo-Fs3cIntList $RunX.Plan[$pk]); if ($l.Count -eq 4) { $ups = $l } }
    }
    if ($ups.Count -eq 4) { if (@($ups | Where-Object { $_ -ne $want }).Count) { $o.TypeBad = $true; $bad.Add("selected plane max_upscale $($ups -join '/') is not all $want for $($RunX.CommitLayout)") } }
    else { $o.TypeNote = 'type check not possible (no max_upscale for the committed planes)' }
    if ($unconv -eq 2 -and $bad.Count -eq 0) { $o.Unconverted = $true; $o.Why = 'post_plane CRTC_X reads the unconverted 2064/3096 for the right half (finding: the kernel did not take the global-coordinate path, E17)'; return [pscustomobject]$o }
    if ($unconv -gt 0) { $bad.Add('right-half CRTC_X partly unconverted') }
    if ($bad.Count) { $o.Why = 'post_plane/plan does not match: ' + ($bad -join '; '); return [pscustomobject]$o }
    $o.Ok = $true; $o.Why = "post_plane matches the plan after the right-half conversion (SRC_X 0/1032/2064/3096, CRTC_X 0/1032/0/1032, zpos 0/0/1/1)$(if ($o.TypeNote) { '; ' + $o.TypeNote })"
    [pscustomobject]$o
}
# A probe step: backlight writes and read-backs, interrupt samples (TE/BLU rates), dmesg flags.
function Get-Fs3cProbeFacts {
    param([hashtable]$St)
    $bl = Get-FsS3bProbeBl $St
    $t = $script:S2L1.GetString([byte[]]$St['out'])
    $w0 = [regex]::Matches($t, '(?m)^write_rc=0 readback=127$').Count
    $samples = New-Object System.Collections.Generic.List[object]
    $pt = ''; $te = New-Object System.Collections.Generic.List[long]; $blu = New-Object System.Collections.Generic.List[long]; $inIrq = $false
    foreach ($raw in $t.Split([char]10)) {
        $l = $raw.TrimEnd([char]13)
        # stage3c/fs-probe.sh (README 5 item 10): "== point <name> run=<ph> up=<s>" (pre, go+1, mid, end, post), each sample
        # under "-- irq" or "-- irq (+0.5 s)" (mid), ending "-- at <uptime>"
        if ($l -cmatch '^== point (\S+)') { $pt = $Matches[1]; $inIrq = $false; continue }
        if ($l -cmatch '^-- irq') { $inIrq = $true; $te.Clear(); $blu.Clear(); continue }
        if (-not $inIrq) { continue }
        if ($l -cmatch '^-- at ([0-9]+(?:\.[0-9]+)?)') {
            $samples.Add([pscustomobject]@{ Point = $pt; T = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture); Te = @($te.ToArray()); Blu = @($blu.ToArray()) })
            $inIrq = $false; continue
        }
        if ($l -cmatch '^\s*[0-9]+:((?:\s+[0-9]+)+)') {
            $sum = [long]0; foreach ($n in [regex]::Matches($Matches[1], '[0-9]+')) { $sum += [long]$n.Value }
            if ($l -match 'te-edge-isr') { $te.Add($sum) } elseif ($l -match 'blu-pwm-isr') { $blu.Add($sum) }
        }
    }
    $rate = { param($a, $b, [string]$kind)
        $x = @($a.$kind); $y = @($b.$kind)
        if ($x.Count -eq 0 -or $x.Count -ne $y.Count -or $b.T -le $a.T) { return $null }
        $d = 0.0; for ($i = 0; $i -lt $x.Count; $i++) { $d += ($y[$i] - $x[$i]) }
        [Math]::Round($d / $x.Count / ($b.T - $a.T)) }
    $go = @($samples | Where-Object { $_.Point -match '^go' }) | Select-Object -First 1
    $en = @($samples | Where-Object { $_.Point -match '^end' }) | Select-Object -Last 1
    if ($null -eq $en) { $en = @($samples | Where-Object { $_.Point -match '^mid' }) | Select-Object -Last 1 }
    $teR = $null; $bluR = $null
    if ($null -ne $go -and $null -ne $en) { $teR = & $rate $go $en 'Te'; $bluR = & $rate $go $en 'Blu' }
    $flags = @([regex]::Matches($t, '(?im)^\[\s*[0-9]+\.[0-9]+\].*?\b(underrun|fault|timeout|esd)') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
    [pscustomobject]@{ Writes = $bl.Writes; Readbacks = @($bl.Readbacks); WriteOk127 = $w0; Note = $bl.Note; Samples = $samples.ToArray(); TeRate = $teR; BluRate = $bluR; DmesgFlags = $flags }
}

# ------------------------------------------------------------ run-3 rule ------
# DESIGN 5.8 rules 1-4 (rule 5, guard G3, is checked by the collector immediately before the send).
#   -R2Valid  r2's record VALID; -R2Run  Get-Fs3cRun of pattern2 (or $null); -Items  r2's reading objects
#   (hashtable item -> object with Key/Obs/Chars); -Chal8  r2's chal[0:8].
# Returns @{ Allow; Rule; Why }. Used for control flow only; never printed before the readings are complete.
function Get-Fs3cR3Decision {
    param([bool]$R2Valid, $R2Run, $Items, [string]$Chal8)
    $no = { param([int]$n, [string]$w) [pscustomobject]@{ Allow = $false; Rule = $n; Why = "rule $($n): $w" } }
    $clean = ($R2Valid -and $null -ne $R2Run -and $R2Run.Kind -ceq 'run' -and $R2Run.Code -eq 0 -and $R2Run.HeldClean -and $R2Run.CloseClean -and
              [string]$R2Run.CommitLayout -cmatch '^quad_(vig|dma)\z')
    if (-not $clean) { return (& $no 1 'run 2 did not commit a quad layout, hold and close cleanly (or its record is not VALID)') }
    $get = { param([string]$k) if ($null -ne $Items -and $Items.ContainsKey($k)) { $Items[$k] } else { $null } }
    $l = & $get 'left'; $r = & $get 'right'; $d = & $get 'dark'
    $obs = { param($x) if ($null -eq $x) { '' } else { [string]$x.Obs } }
    if (@((& $obs $l), (& $obs $r)) -cnotcontains 'LIT' -and @((& $obs $l), (& $obs $r)) -cnotcontains 'GARBLED') { return (& $no 2 'neither eye reported run 2 as lit without a pattern (a) or garbled (c)') }
    $want = $Chal8.ToUpperInvariant()
    foreach ($x in @($l, $r)) { if ($null -ne $x -and $x.Obs -ceq 'READ' -and [string]$x.Chars -ceq $want) { return (& $no 3 'an eye read the 8 characters correctly in run 2 (the question is answered)') } }
    if ((& $obs $d) -cne 'DARK_NOW') { return (& $no 4 'the run-2 dark check is not y (dark now)') }
    [pscustomobject]@{ Allow = $true; Rule = 0; Why = 'rules 1-4 hold (rule 5, guard G3, is checked at the send)' }
}

# ------------------------------------------------------------ readings -------
$script:S3cFsr2Re = '^FSR2 p=(r1|r2|r3) item=(left|right|chars_left|chars_right|dark|bars_left|bars_right|orient_left|orient_right|tilt_left|tilt_right) key=(Enter|Esc|Backspace|[a-z0-9?]|-) obs=(LIT|DARK|GARBLED|READ|BARS|UPRIGHT|HALF_TURN|MIRRORED|VFLIP|LEFT_LOW|RIGHT_LOW|LEVEL|UNKNOWN|UNIFORM_RED|PARTIAL_RED|UNIFORM_OTHER|SAME_AS_R2|DIFFERENT|DARK_NOW|LIGHT_NOW|TIMEOUT|ABORT|NOT_ASKED)(?: chars=([0-9A-F?]{8}))?(?: bars=([0-4]{2}))? prompt_ms=([0-9]{1,12}) answer_ms=(-1|[0-9]{1,12}) prompt_utc=(\S+) answer_utc=(\S+) discarded=([0-9]{1,6})\z'
function ConvertFrom-Fs3cReadings {
    param([string[]]$Lines)
    $m = @{}
    foreach ($l in @($Lines | Where-Object { $_ -and -not $_.StartsWith('#') })) {
        if ($l -cnotmatch $script:S3cFsr2Re) { throw "readings: malformed line '$(ConvertTo-FsPrintable $l)'" }
        $k = "$($Matches[1]):$($Matches[2])"
        if ($m.ContainsKey($k)) { throw "readings: $k given twice" }
        if (($Matches[4] -ceq 'BARS') -xor ($null -ne $Matches[6] -and $Matches[6] -ne '')) { throw "readings: bars= is required with BARS and only with BARS" }
        $m[$k] = [pscustomobject]@{ Ph = $Matches[1]; Item = $Matches[2]; Key = $Matches[3]; Obs = $Matches[4]; Chars = $(if ($Matches[5]) { $Matches[5] } else { '' })
                                    Bars = $(if ($Matches[6]) { $Matches[6] } else { '' }); PromptMs = [long]$Matches[7]; AnswerMs = [long]$Matches[8] }
    }
    $m
}
function Get-Fs3cPhaseItems { param($Rd, [string]$PhX)
    $h = @{}; if ($null -eq $Rd) { return $h }
    foreach ($k in $Rd.Keys) { if ($k.StartsWith("$($PhX):")) { $h[$k.Substring(3)] = $Rd[$k] } }
    $h
}

# Optical per phase (DESIGN 11.2), r1/r2. $Shown: 'shown' | 'not' | 'unknown'.
function Get-Fs3cOptical {
    param($Items, [string]$Chal8, [string]$Shown)
    $want = $Chal8.ToUpperInvariant()
    $get = { param([string]$k) if ($Items.ContainsKey($k)) { $Items[$k] } else { $null } }
    $l = & $get 'left'; $r = & $get 'right'
    $ok = { param($x) $null -ne $x -and $x.Obs -ceq 'READ' -and $x.Chars -ceq $want }
    $lit = { param($x) $null -ne $x -and @('LIT', 'GARBLED', 'READ') -ccontains $x.Obs }
    $desc = (@('left', 'right') | ForEach-Object { $x = & $get $_; "$_=$(if ($null -eq $x) { 'none' } else { $x.Obs + $(if ($x.Chars) { ':' + $x.Chars } else { '' }) })" }) -join ' '
    if ((& $ok $l) -and (& $ok $r)) {
        if ($Shown -ceq 'shown') { return [pscustomobject]@{ Class = 'OPTICAL PASS'; Why = 'all 8 characters read correctly in each eye in a run the record shows committed and held' } }
        if ($Shown -ceq 'not') { return [pscustomobject]@{ Class = 'INCONCLUSIVE'; Why = 'both eyes read correctly, but the record shows that run made no commit: CONTRADICTS the record' } }
        return [pscustomobject]@{ Class = 'INCONCLUSIVE'; Why = 'both eyes read correctly, but the record is absent or unusable for that run: the commit cannot be confirmed' }
    }
    if ((& $ok $l) -or (& $ok $r)) {
        if ($Shown -ceq 'shown') { return [pscustomobject]@{ Class = 'ONE-EYE ONLY'; Why = "correct reading in one eye only ($desc): a display result to investigate, not a PASS" } }
        if ($Shown -ceq 'not') { return [pscustomobject]@{ Class = 'INCONCLUSIVE'; Why = "a correct one-eye reading ($desc) in a run the record shows made no commit: CONTRADICTS the record" } }
        return [pscustomobject]@{ Class = 'INCONCLUSIVE'; Why = "a correct one-eye reading ($desc) for which the record is absent or unusable: cannot be confirmed" }
    }
    # build review MINOR-3: `d` (read) answered, then a timeout, x or n during the character entry: the PM said the
    # characters were readable but none were recorded. Not a garble and not a PASS.
    $readNo = { param($x) $null -ne $x -and $x.Obs -ceq 'READ' -and -not $x.Chars }
    if ((& $readNo $l) -or (& $readNo $r)) { return [pscustomobject]@{ Class = 'READ, CHARACTERS NOT RECORDED'; Why = "an eye was answered d (read) but its characters were not recorded (a timeout or x during the entry): $desc" } }
    if ((& $lit $l) -or (& $lit $r)) { return [pscustomobject]@{ Class = 'LIT BUT GARBLED'; Why = $desc } }
    if ($null -ne $l -and $null -ne $r -and $l.Obs -ceq 'DARK' -and $r.Obs -ceq 'DARK') { return [pscustomobject]@{ Class = 'DARK'; Why = 'no light seen in either eye (not a measurement of zero emitted light)' } }
    [pscustomobject]@{ Class = 'NOT RECORDED'; Why = "timeout, abort or not asked ($desc)" }
}

# Layout reading per eye (DESIGN 11.2 table; diagnostic labels, never a PASS).
function Get-Fs3cLayoutLabel {
    param([string]$Bars, [string]$Orient, [bool]$CharsCorrect = $false)
    if (-not $Bars) { return [pscustomobject]@{ Label = 'not recorded'; Tag = '-'; Half = $null; Inconsistent = $false } }
    $half = if (@('12', '21') -ccontains $Bars) { 0 } elseif (@('34', '43') -ccontains $Bars) { 1 } else { $null }
    $o = if ($Orient) { $Orient } else { 'NOT_ASKED' }
    $mk = { param($l, $t, [bool]$inc = $false) [pscustomobject]@{ Label = $l; Tag = $t; Half = $half; Inconsistent = $inc } }
    if ($Bars.Contains('0')) {
        $r = & $mk 'a 0 side: that mixer''s plane not scanned or not readable: layout fault' '[C]'
        if ($CharsCorrect) { $r.Label += '; contradicts the correct characters (inconsistency)'; $r.Inconsistent = $true }
        return $r
    }
    if (@('12', '34') -ccontains $Bars) {
        switch -CaseSensitive ($o) {
            'UPRIGHT'   { return (& $mk "all four planes staged as planned; this eye shows buffer half $half" '[D]') }
            'VFLIP'     { return (& $mk 'a vertical flip in the path (bars keep their order, the F is turned over): geometry finding' '[C]') }
            'HALF_TURN' { return (& $mk 'contradictory (a half-turn would swap the bars): inconsistency' '-' $true) }
            'MIRRORED'  { return (& $mk 'contradictory (a mirror would swap the bars): inconsistency' '-' $true) }
            default     { return (& $mk "bars as planned for buffer half $half (F not read)" '[D]') }
        }
    }
    if (@('21', '43') -ccontains $Bars) {
        switch -CaseSensitive ($o) {
            'HALF_TURN' { return (& $mk 'in-buffer 180 degrees does not match the mounting: geometry finding, not a fault' '[C]') }
            'MIRRORED'  { return (& $mk 'a left-right mirror in the path: geometry finding' '[C]') }
            'UPRIGHT'   { return (& $mk 'the two planes of that half exchanged position: layout fault' '[D]') }
            default     { return (& $mk "bars swapped for buffer half $half (F not read or not decisive)" '[C]') }
        }
    }
    & $mk "unexpected bar pair $($Bars.Substring(0,1)) $($Bars.Substring(1,1)): layout fault" '[C]'
}

# Run-3 interpretation (DESIGN 11.3).
function Get-Fs3cR3Interpretation {
    param($R2Items, $R3Items, [bool]$Comparable)
    if (-not $Comparable) { return [pscustomobject]@{ Code = '-'; Text = 'LAYOUT DIFFERS: no comparison'; Tag = '-' } }
    $g = { param($h, [string]$k) if ($null -ne $h -and $h.ContainsKey($k)) { [string]$h[$k].Obs } else { '' } }
    $l3 = & $g $R3Items 'left'; $r3 = & $g $R3Items 'right'
    if ($l3 -cne $r3) { return [pscustomobject]@{ Code = '-'; Text = "eyes disagree (left $l3, right $r3): reported per eye; no interpretation"; Tag = '-' } }
    $r2 = @((& $g $R2Items 'left'), (& $g $R2Items 'right'))
    $garb = $r2 -ccontains 'GARBLED'; $litOrGarb = $garb -or ($r2 -ccontains 'LIT')
    switch -CaseSensitive ($l3) {
        'UNIFORM_RED'   { if ($litOrGarb) { return [pscustomobject]@{ Code = 'T1'; Text = 'our pixels reach the panel through this layout; the run-2 garble depends on content: suspect the compression/fetch path under detailed content'; Tag = '[C]' } } }
        'SAME_AS_R2'    { if ($garb) { return [pscustomobject]@{ Code = 'T2'; Text = 'the stripes do not depend on our frame: suspect the panel/DSC/timing side, or a throughput fault the quad layout did not cure'; Tag = '[C]' } } }
        'DIFFERENT'     { if ($garb) { return [pscustomobject]@{ Code = 'T3'; Text = 'data reaches the panel but is corrupted depending on content: pipe fetch, format or stride path'; Tag = '[C]' } } }
        'PARTIAL_RED'   { return [pscustomobject]@{ Code = 'T4'; Text = 'part of the staging fails even for flat content: a plane/mixer fault'; Tag = '[C]' } }
        'UNIFORM_OTHER' { return [pscustomobject]@{ Code = 'T5'; Text = 'channel order or format mismatch (blue = R/B swap, XR24 read as AB24)'; Tag = '[C]' } }
        'DARK'          { return [pscustomobject]@{ Code = 'T6'; Text = 'the second off->on did not light the panel: wake is unreliable'; Tag = '[O]' } }
    }
    [pscustomobject]@{ Code = '-'; Text = "no table row matches (run 2 $($r2 -join '/'), run 3 $l3)"; Tag = '-' }
}

# ------------------------------------------------------------ machine side ------
# One phase's machine class (DESIGN 11.1, first match wins). $P: @{ Ph; Sent; NotRunWhy; Refusal; Complete;
# Fsb1 (Test-Fsb1Record result or $null); Chal; ChainOk; R3RuleHeld }. $Prev: the earlier phases' results.
function Get-Fs3cPhaseMachine {
    param($P, [hashtable]$Prev, [string]$Pin)
    $o = [ordered]@{ Ph = $P.Ph; Class = $null; Reason = ''; Tag = $null; Run = $null; Probe = $null; Notes = @(); Shown = 'unknown'; Clean = $false; GateClean = $false; Scanout = $null; Inconsistent = $false }
    $fin = { param($c, $w, [string]$sh = 'unknown') $o.Class = $c; $o.Reason = $w; $o.Shown = $sh; [pscustomobject]$o }
    $inc = { param($w) $o.Inconsistent = $true; & $fin 'INCONCLUSIVE' "runner inconsistency: $w" }
    if (-not $P.Sent) { return (& $fin 'NOT RUN' "not run: $($P.NotRunWhy)" 'not') }
    if ($null -ne $P.Refusal) { return (& $fin 'REFUSED' "FSXE1 ran=$($P.Refusal.Ran) error=$($P.Refusal.Error)" $(if ($P.Refusal.Ran -eq 0) { 'not' } else { 'unknown' })) }
    if (-not $P.Complete) { return (& $fin 'INCONCLUSIVE' 'no complete record by the phase deadline') }
    if ($null -eq $P.Fsb1 -or -not $P.Fsb1.Ok) { return (& $fin 'INCONCLUSIVE' "FSB1 rejected: $(if ($null -ne $P.Fsb1) { $P.Fsb1.Reason + ' ' + $P.Fsb1.Detail } else { 'no record' })") }
    $stp = @($P.Fsb1.Steps)
    if ((@($stp | ForEach-Object { $_['id'] }) -join ',') -cne ($script:S3cSteps[$P.Ph] -join ',')) { return (& $fin 'INCONCLUSIVE' 'decoded steps are not the stage-3c list for this phase') }
    if (-not $P.ChainOk) { return (& $inc 'the chain argument of this phase does not equal the previous record''s rec_sha256[0:16]') }
    $c8 = $P.Chal.Substring(0, 8)
    if ($P.Ph -ceq 'p0') {
        $h = $stp[0]; $pr = Get-Fs3cProbeFacts $stp[1]; $o.Probe = $pr
        $tf = Test-FsS2ToolFault $h
        if (-not $Pin) { return (& $fin 'INCONCLUSIVE' 'no fs-pattern v0.6 pin (the built-in S3cPatternPin is empty and none was passed): integrity unmeasured') }
        $hc = if ($null -ne $tf) { @{ Class = 'TOOL FAULT'; Mismatch = $false; Notes = $tf } } else { Get-FsS3HashClass $h $Pin }
        # integrity first, then the write count (build review MINOR-1, the stage-3b order)
        if ($hc.Class -ceq 'MEASURED' -and $hc.Mismatch) { return (& $fin 'INTEGRITY FAULT' "hash: $($hc.Notes)") }
        if ($pr.Writes -gt 1) { return (& $inc "$($pr.Writes) backlight write lines in p0") }
        if ($hc.Class -cne 'MEASURED') { return (& $fin 'INCONCLUSIVE' "hash tool fault: $($hc.Class) ($($hc.Notes))") }
        if ($pr.Writes -ne 1 -or $pr.WriteOk127 -lt 1) { return (& $fin 'BRIGHTNESS NOT VERIFIED' "probe0: writes=$($pr.Writes) readback=$(@($pr.Readbacks) -join ',') ($($pr.Note))") }
        $o.Clean = $true
        return (& $fin 'P0 OK' 'hash equals the v0.6 pin; exactly one write line with write_rc=0 readback=127')
    }
    $runN = [int]$P.Ph.Substring(1, 1)
    $pr = Get-Fs3cProbeFacts $stp[0]; $o.Probe = $pr
    $run = Get-Fs3cRun $stp[1] $runN $c8; $o.Run = $run
    # build review MAJOR-3: the facts the DEVICE gate of the next run checks (fs-phase.sh gate_prev): a run that
    # exited 0 with commit rc=0, hold_end reason=deadline, exit shown=1 and close_rc=0; for run 2 also a quad commit.
    # The next run's "previous phase clean" check below uses exactly these, never the post_plane comparison (an
    # unconverted CRTC_X stays a FINDING of run 2 and does not make run 3 a runner inconsistency).
    $o.GateClean = ($run.Kind -ceq 'run' -and $run.Code -eq 0 -and $run.HeldClean -and $run.CloseClean -and
                    ($runN -ne 2 -or [string]$run.CommitLayout -cmatch '^quad_(vig|dma)\z'))
    if ($pr.Writes -ne 0) { return (& $inc "a backlight write line in probe$runN (the only write belongs to p0)") }
    $prevPh = 'r' + ($runN - 1)
    switch -CaseSensitive ($run.Kind) {
        'toolfault' { return (& $fin 'INCONCLUSIVE' "our side failed in the pattern step: $($run.Why)") }
        'skip'      { return (& $fin 'SKIPPED' "run $runN skipped ($($run.Why))" 'not') }
        'hang'      { return (& $fin 'DISPLAY FAIL' "run $runN hung or was not runnable: $($run.Why)") }
        'other'     { return (& $fin 'INCONCLUSIVE' "run $runN $($run.Why)") }
        'unsound'   { return (& $fin 'INCONCLUSIVE' "run $runN evidence unreadable: $($run.Why)") }
    }
    if ($runN -ge 2) {
        $pv = $Prev[$prevPh]
        if ($null -eq $pv -or -not $pv.GateClean) { return (& $inc "r$runN executed without r$($runN - 1)'s clean $(if ($runN -eq 2) { 'close' } else { 'quad commit and close' }) (the device gate's facts: exit 0, commit rc=0, hold to the deadline, close_rc=0$(if ($runN -eq 3) { ', a quad layout' }))") }
    }
    if ($runN -eq 3 -and -not $P.R3RuleHeld) { return (& $inc 'r3 executed although the host run-3 rule (DESIGN 5.8) did not hold') }
    if ($run.Mode -cne $script:S3cMode[$P.Ph]) { return (& $fin 'INCONCLUSIVE' "run $runN mode is '$($run.Mode)', not $($script:S3cMode[$P.Ph])") }
    if ($run.ZposOutsideQuad) { return (& $inc 'zpos set outside a quad attempt') }
    if (@($pr.Readbacks).Count -lt 1 -or @($pr.Readbacks)[0] -cne '127') { return (& $inc "run $runN ran but probe$runN does not show the read-back 127") }
    $o.Scanout = "TE $(if ($null -ne $pr.TeRate) { "$($pr.TeRate)/s" } else { 'n/a' }) BLU $(if ($null -ne $pr.BluRate) { "$($pr.BluRate)/s" } else { 'n/a' }) topology=$(if ($null -ne $run.PostState -and $run.PostState.ContainsKey('topology_name')) { $run.PostState['topology_name'] } else { 'n/a' }) dmesg-flags=$(if (@($pr.DmesgFlags).Count) { @($pr.DmesgFlags) -join ',' } else { 'none' })"
    if ($runN -eq 1) {
        if ($script:S3cNoDisp.ContainsKey([int]$run.Code)) { return (& $fin 'NO-DISPLAY' "run 1: fs-pattern exit $($run.Code) ($($script:S3cNoDisp[[int]$run.Code])): no real commit" 'not') }
        if ($run.Code -eq 60 -or $run.Code -eq 1) { return (& $fin 'DISPLAY FAIL' "run 1: fs-pattern exit $($run.Code)") }
        if ($run.Code -ne 0 -or -not $run.HeldClean) { return (& $fin 'INCONCLUSIVE' "run 1: exit $($run.Code) without commit rc=0, hold_end reason=deadline and exit shown=1") }
        if (-not $run.CloseClean) { return (& $fin 'R1 SHOWN, UNCLEAN CLOSE' "run 1 committed and held; close_rc=$($run.CloseRc)" 'shown') }
        $o.Clean = $true
        return (& $fin 'R1 SHOWN' "run 1 committed (layout $($run.CommitLayout)), held and closed cleanly" 'shown')
    }
    # r2 / r3
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
    $pv = $Prev[$prevPh]
    if ($null -eq $pv.Run -or $null -eq $pv.Run.StartMs -or $null -eq $pv.Run.HeldMs -or $null -eq $pv.Run.CloseMs -or $null -eq $run.StartMs) { return (& $fin 'INCONCLUSIVE' 'monotonic stamps for the pause are missing') }
    $pause = $run.StartMs - ($pv.Run.StartMs + $pv.Run.HeldMs + $pv.Run.CloseMs)
    $o.Notes = @("pause $pause ms")
    if ($pause -lt 2000) { return (& $inc "pause between r$($runN - 1)'s close and r$($runN)'s commit is $pause ms (< 2000)") }
    if (-not $run.CloseClean) { return (& $fin 'INCONCLUSIVE' "run $runN committed and held but close_rc=$($run.CloseRc)" 'shown') }
    $o.Clean = $true
    if ($runN -eq 2) { return (& $fin 'R2 SHOWN-QUAD' "committed $($run.CommitLayout) from an inactive CRTC (DRM state; physical panel-off not proven), $($q.Why); held; clean close; pause $pause ms; read-back 127" 'shown') }
    return (& $fin 'R3 SHOWN-QUAD-SOLID' "committed $($run.CommitLayout) (solid red), $($q.Why); held; clean close; pause $pause ms; read-back 127" 'shown')
}

# The whole session (DESIGN 11.1-11.4). $Phases: list of phase inputs (as Get-Fs3cPhaseMachine), in order
# p0..r3 (absent phases as Sent=$false). $ReadingLines: readings3c.txt lines or $null.
function Get-Fs3cOutcome {
    param([Parameter(Mandatory)][string]$S1Class, [Parameter(Mandatory)]$Phases, [string[]]$ReadingLines = $null, [string]$Pin = '', [string[]]$SessionReadings = $null,
          [string[]]$Q7Items = @())       # the r2 items the collector did not ask under the Q7 fallback (session.json Phases r2 Q7Fallback.Items)
    if (-not $Pin) { $Pin = $script:S3cPatternPin }      # the stage-3b convention (fs-classify3b.ps1: an empty -PatternPin means the built-in pin)
    $o = [ordered]@{ Outcome = $null; Reason = ''; Phases = [ordered]@{}; Optical = [ordered]@{}; Dark = [ordered]@{}; Layout = [ordered]@{}; Interpretation = $null
                     Labels = @(); Notes = @(); Registered = ''; ReadingsOk = $true; ReadingsWhy = ''; Q7NotAsked = @() }
    if ($S1Class -cne 'PASS') { $o.Outcome = $S1Class; $o.Reason = 'stage 1 did not PASS; any record text is data only'; $o.Registered = "not a stage PASS: machine $S1Class"; return [pscustomobject]$o }
    $byPh = @{}; foreach ($p in @($Phases)) { $byPh[$p.Ph] = $p }
    $prev = @{}
    foreach ($ph in $script:S3cPhases) {
        $p = $byPh[$ph]; if ($null -eq $p) { $p = [pscustomobject]@{ Ph = $ph; Sent = $false; NotRunWhy = 'not requested'; Refusal = $null; Complete = $false; Fsb1 = $null; Chal = ''; ChainOk = $true; R3RuleHeld = $false } }
        $m = Get-Fs3cPhaseMachine -P $p -Prev $prev -Pin $Pin
        $prev[$ph] = $m; $o.Phases[$ph] = $m
    }
    # readings
    $rd = $null
    if ($null -ne $ReadingLines) {
        try { $rd = ConvertFrom-Fs3cReadings $ReadingLines } catch { $o.ReadingsOk = $false; $o.ReadingsWhy = ConvertTo-FsPrintable $_.Exception.Message }
        if ($o.ReadingsOk -and $null -ne $SessionReadings -and ((@($ReadingLines | Where-Object { $_ }) -join "`n") -cne (@($SessionReadings | Where-Object { $_ }) -join "`n"))) {
            $o.ReadingsOk = $false; $o.ReadingsWhy = 'readings3c.txt differs from the readings in session.json'; $rd = $null
        }
    } else { $o.ReadingsOk = $false; $o.ReadingsWhy = 'no readings file' }
    $labels = New-Object System.Collections.Generic.List[string]
    foreach ($ph in 'r1', 'r2', 'r3') {
        $it = Get-Fs3cPhaseItems $rd $ph
        $mm = $o.Phases[$ph]; $pin8 = if ($byPh.ContainsKey($ph) -and $byPh[$ph].Chal) { $byPh[$ph].Chal.Substring(0, 8) } else { '00000000' }
        if ($ph -ne 'r3') {
            if (-not $o.ReadingsOk) { $o.Optical[$ph] = [pscustomobject]@{ Class = $(if ($o.ReadingsWhy -eq 'no readings file') { 'NOT RECORDED' } else { 'INCONCLUSIVE' }); Why = $o.ReadingsWhy } }
            elseif ($it.Count -eq 0) { $o.Optical[$ph] = [pscustomobject]@{ Class = 'NOT RECORDED'; Why = 'no readings for this run (not run or not asked)' } }
            else { $o.Optical[$ph] = Get-Fs3cOptical -Items $it -Chal8 $pin8 -Shown $mm.Shown }
        } else {
            $o.Optical[$ph] = [pscustomobject]@{ Class = $(if ($it.Count) { 'RUN-3 READINGS' } else { 'NOT RECORDED' }); Why = (@('left', 'right') | ForEach-Object { "$_=$(if ($it.ContainsKey($_)) { $it[$_].Obs } else { 'none' })" }) -join ' ' }
        }
        foreach ($k in @('dark', 'left', 'right', 'chars_left', 'chars_right', 'bars_left', 'bars_right', 'orient_left', 'orient_right', 'tilt_left', 'tilt_right')) {
            if ($it.ContainsKey($k) -and $it[$k].Obs -ceq 'LIGHT_NOW') { $labels.Add("RETAINED-FRAME OBSERVATION after run $($ph.Substring(1)) ($k = light still visible): a safety-relevant finding"); break }
        }
        if ($it.ContainsKey('dark')) { $o.Dark[$ph] = $it['dark'].Obs }
        if ($ph -ceq 'r2') {
            $halves = @()
            foreach ($e in 'left', 'right') {
                $b = if ($it.ContainsKey("bars_$e") -and $it["bars_$e"].Obs -ceq 'BARS') { $it["bars_$e"].Bars } else { '' }
                $or = if ($it.ContainsKey("orient_$e")) { $it["orient_$e"].Obs } else { '' }
                $cc = ($it.ContainsKey($e) -and $it[$e].Obs -ceq 'READ' -and $it[$e].Chars -ceq $pin8.ToUpperInvariant())
                if (-not $b -and -not $it.ContainsKey("bars_$e")) { continue }
                # Q7 fallback: bars not asked on the run-3 path is expected; a layout line only where something was asked (F, line)
                $q7e = (@($Q7Items) -ccontains "bars_$e" -and $it.ContainsKey("bars_$e") -and $it["bars_$e"].Obs -ceq 'NOT_ASKED')
                if ($q7e) { $o.Q7NotAsked += "bars_$e"; if (-not $it.ContainsKey("orient_$e") -and -not $it.ContainsKey("tilt_$e")) { continue } }
                $lab = Get-Fs3cLayoutLabel -Bars $b -Orient $or -CharsCorrect $cc
                if ($q7e) { $lab = [pscustomobject]@{ Label = 'bars not asked (Q7 fallback); F and line as recorded'; Tag = '-'; Half = $null; Inconsistent = $false } }
                $tilt = if ($it.ContainsKey("tilt_$e")) { $it["tilt_$e"].Obs } else { '-' }
                $o.Layout[$e] = [pscustomobject]@{ Bars = $b; Orient = $or; Tilt = $tilt; Label = $lab.Label; Tag = $lab.Tag; Inconsistent = $lab.Inconsistent }
                if ($null -ne $lab.Half) { $halves += $lab.Half }
            }
            if ($halves.Count -eq 2 -and $halves[0] -eq $halves[1]) { $labels.Add("LAYOUT: both eyes show buffer half $($halves[0]): half mapping fault [C]") }
        }
    }
    $r2m = $o.Phases['r2']; $r3m = $o.Phases['r3']
    if ($r3m.Class -cne 'NOT RUN') {
        if ($r3m.Shown -ceq 'shown') {
            $comp = ($r2m.Shown -ceq 'shown' -and $r2m.Tag -and $r2m.Tag -ceq $r3m.Tag)
            $o.Interpretation = Get-Fs3cR3Interpretation -R2Items (Get-Fs3cPhaseItems $rd 'r2') -R3Items (Get-Fs3cPhaseItems $rd 'r3') -Comparable $comp
        } else {
            # build review NIT c: "LAYOUT DIFFERS" only when run 3 was shown; a run 3 that was not shown has no interpretation
            $o.Interpretation = [pscustomobject]@{ Code = '-'; Text = "run 3 not machine-shown ($($r3m.Class)): no interpretation"; Tag = '-' }
        }
    }
    foreach ($ph in $script:S3cPhases) { foreach ($n in @($o.Phases[$ph].Notes)) { if ($n -match 'finding') { $labels.Add("FINDING ($ph): $n") } } }
    # session machine class
    $p0 = $o.Phases['p0'].Class; $r1 = $o.Phases['r1'].Class; $r2 = $r2m.Class
    $r3Bad = ($r3m.Inconsistent)
    $incon = @($script:S3cPhases | Where-Object { $o.Phases[$_].Inconsistent })
    if ($p0 -ceq 'INTEGRITY FAULT') { $o.Outcome = 'INTEGRITY FAULT'; $o.Reason = "p0: $($o.Phases['p0'].Reason)" }
    elseif ($incon.Count) { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = "$($incon[0]): $($o.Phases[$incon[0]].Reason)" }     # any runner inconsistency (DESIGN 11.1), also a defect for FS-A-012
    elseif ($p0 -ceq 'P0 OK' -and $r1 -ceq 'R1 SHOWN' -and $r2 -ceq 'R2 SHOWN-QUAD' -and -not $r3Bad) { $o.Outcome = 'PASS (machine side)'; $o.Reason = "P0 OK, R1 SHOWN, R2 SHOWN-QUAD (layout $($r2m.Tag))" }
    elseif ($p0 -cne 'P0 OK') { $o.Outcome = $(if ($p0 -ceq 'INTEGRITY FAULT') { 'INTEGRITY FAULT' } else { 'INCONCLUSIVE' }); $o.Reason = "p0: $p0 ($($o.Phases['p0'].Reason))" }
    elseif ($r1 -ceq 'R1 SHOWN' -or $r1 -ceq 'R1 SHOWN, UNCLEAN CLOSE') {
        if (@('NOT RUN', 'SKIPPED', 'PRECONDITION UNMET: CRTC ACTIVE', 'NO-DISPLAY') -ccontains $r2) { $o.Outcome = 'RUN 1 ONLY'; $o.Reason = "r1 $r1; r2 $r2 ($($r2m.Reason))" }
        elseif ($r2 -ceq 'DISPLAY FAIL') { $o.Outcome = 'DISPLAY FAIL'; $o.Reason = "r2: $($r2m.Reason)" }
        elseif ($r2 -ceq 'R2 SHOWN-QUAD' -and $r3Bad) { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = "r3: $($r3m.Reason)" }
        elseif ($r2 -ceq 'R2 SHOWN-QUAD') { $o.Outcome = 'RUN 1 ONLY'; $o.Reason = "r1 $r1 (not a clean close); r2 R2 SHOWN-QUAD" }
        else { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = "r2: $r2 ($($r2m.Reason))" }
    }
    elseif ($r1 -ceq 'NO-DISPLAY' -or $r1 -ceq 'DISPLAY FAIL') { $o.Outcome = $r1; $o.Reason = "r1: $($o.Phases['r1'].Reason)" }
    else { $o.Outcome = 'INCONCLUSIVE'; $o.Reason = "r1: $r1 ($($o.Phases['r1'].Reason))" }
    # registered line
    $passPh = @('r1', 'r2' | Where-Object { $o.Optical[$_].Class -ceq 'OPTICAL PASS' -and $o.Phases[$_].Shown -ceq 'shown' })
    $stagePass = ($passPh.Count -gt 0 -and $p0 -ceq 'P0 OK' -and @('PASS (machine side)', 'RUN 1 ONLY') -ccontains $o.Outcome)
    $sc = @('r2', 'r1' | Where-Object { $o.Phases[$_].Scanout }) | Select-Object -First 1
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("machine $($o.Outcome)$(if ($o.Outcome -ceq 'PASS (machine side)') { ' (layout ' + $r2m.Tag + ')' })")
    if ($sc) { $parts.Add("SCANOUT $($o.Phases[$sc].Scanout) ($sc)") }
    foreach ($ph in 'r1', 'r2') { $parts.Add("$($ph.ToUpperInvariant()) optical $($o.Optical[$ph].Class)") }
    if ($null -ne $o.Interpretation) { $parts.Add("R3 $($o.Optical['r3'].Why) -> interpretation $($o.Interpretation.Code) $($o.Interpretation.Tag)") }
    foreach ($l in $labels) { $parts.Add($l) }
    $o.Labels = $labels.ToArray()
    $o.Registered = "$(if ($stagePass) { 'STAGE PASS' } else { 'not a stage PASS' }): " + ($parts -join '; ')
    [pscustomobject]$o
}

# ------------------------------------------------------------ slices ---------
# The capture index with its W and N lines in order (the pinned Read-FsCaptureIndex validates the file,
# this keeps the N lines it ignores). Returns the list of @{ Kind; Offset; Ms; Text }.
function Read-Fs3cIndexEvents {
    param([Parameter(Mandatory)][string]$Path, [long]$RawLength)
    $null = Read-FsCaptureIndex -Path $Path -RawLength $RawLength      # throws on any malformed or inconsistent index
    $ev = New-Object System.Collections.Generic.List[object]
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        if ($l -cmatch '^([WN]) (0|[1-9][0-9]{0,8}) (0|[1-9][0-9]{0,11}) ([ -~]{1,200})\z') { $ev.Add([pscustomobject]@{ Kind = $Matches[1]; Offset = [long]$Matches[2]; Ms = [long]$Matches[3]; Text = $Matches[4] }) }
    }
    ,$ev.ToArray()
}
# Phase slices (DESIGN 5.6): from the fs-phase W line's offset to the collector's `phase-end p=<ph>` N line
# (the end of the settled prompt, or the phase deadline); without that N line, to the next W line or the end.
function Get-Fs3cSlices {
    param([byte[]]$Raw, $Events)
    $ev = @($Events)
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ev.Count; $i++) {
        $e = $ev[$i]
        if ($e.Kind -cne 'W' -or $e.Text -cnotmatch '^fs-phase (p0|r1|r2|r3) ([0-9a-f]{32}) ([0-9a-f]{16})\z') { continue }
        $ph = $Matches[1]; $chal = $Matches[2]; $pv = $Matches[3]
        $end = [long]$Raw.Length; $how = 'end-of-capture'
        for ($j = $i + 1; $j -lt $ev.Count; $j++) {
            if ($ev[$j].Kind -ceq 'N' -and $ev[$j].Text -cmatch "^phase-end p=$ph( |\z)") { $end = $ev[$j].Offset; $how = 'phase-end'; break }
            if ($ev[$j].Kind -ceq 'W') { $end = $ev[$j].Offset; $how = 'next-write'; break }
        }
        $n = [int]($end - $e.Offset); if ($n -lt 0) { $n = 0 }
        $b = New-Object byte[] $n; [Array]::Copy($Raw, [int]$e.Offset, $b, 0, $n)
        $out.Add([pscustomobject]@{ Ph = $ph; Chal = $chal; Prev = $pv; Start = $e.Offset; End = $end; How = $how; Sha256 = (Get-FsSha256Hex $b); Bytes = $b; SendMs = $e.Ms })
    }
    ,$out.ToArray()
}
function Get-Fs3cRecSha16 { param([byte[]]$Bytes)
    $m = [regex]::Match($script:S2L1.GetString($Bytes), '(?m)^FSB1 END v=1 nonce=[0-9a-f]{16} chal=[0-9a-f]{32} lines=[0-9]+ rec_sha256=([0-9a-f]{64})\r?$')
    if ($m.Success) { $m.Groups[1].Value.Substring(0, 16) } else { $null }
}
# The completion of a slice: FSB1 record or FSXE1 refusal (the first of them), or none.
function Get-Fs3cSliceCompletion { param([byte[]]$Bytes)
    $lines = Get-FsRegionLines $Bytes
    $e = Find-FsFsb1End $lines; $f = Find-FsRecordLine $lines 'FSXE1'
    if ($null -ne $f -and ($null -eq $e -or $f.Index -lt $e.Index)) { return [pscustomobject]@{ Kind = 'refusal'; Line = $f.Line } }
    if ($null -ne $e) { return [pscustomobject]@{ Kind = 'record'; Line = $e.Line } }
    [pscustomobject]@{ Kind = 'none'; Line = $null }
}

# The classifier on one fs-collect3c output directory (the CLI below, and test-host3c in process).
# Returns @{ Code (the CLI exit code); Lines (the report, printable); Outcome (Get-Fs3cOutcome or $null) }.
function Invoke-Fs3cClassifyDir {
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
    if ($j.PSObject.Properties['Schema'] -and [string]$j.Schema -ceq 'frameshift.fs-collect3c.partial.v1') {
        return (& $done 14 'OUTCOME: INCONCLUSIVE (session.json is the checkpoint of a collector run that did not finish: the readings in it and in readings3c.txt and the capture are evidence; no classification)')
    }
    if (-not $j.PSObject.Properties['Capture']) { return (& $done 14 'OUTCOME: INCONCLUSIVE (session.json has no capture record)') }
    if ((Get-FsSha256Hex $raw) -cne [string]$j.Capture.Sha256) { return (& $done 14 'OUTCOME: INCONCLUSIVE (capture.raw does not match the hash recorded by the collector)') }
    if ([string]$j.Stage -cne '3c') { return (& $done 14 "OUTCOME: INCONCLUSIVE (the session is stage $($j.Stage), not 3c)") }
    if ($oDir) {
        try { $ob = Get-Content -Raw -ErrorAction Stop (Join-Path $oDir 'observe.json') | ConvertFrom-Json }
        catch { return (& $done 14 "OUTCOME: INCONCLUSIVE (cannot read observe.json: $($_.Exception.Message))") }
        $c1 = Get-FsStage1Class -Observe $ob -Collect $j
        $pre.Add("STAGE-1 CLASS: $($c1.Class) (derived: $($c1.Why))")
        $s1 = $c1.Class
    }
    # re-derive the slices and compare with the collector's (DESIGN 5.6)
    $sl = Get-Fs3cSlices -Raw $raw -Events $evs
    $js = @($j.Slices)
    $same = ($sl.Count -eq $js.Count)
    for ($i = 0; $same -and $i -lt $sl.Count; $i++) { $same = ($sl[$i].Ph -ceq [string]$js[$i].Ph -and $sl[$i].Start -eq [long]$js[$i].Start -and $sl[$i].End -eq [long]$js[$i].End -and $sl[$i].Sha256 -ceq [string]$js[$i].Sha256) }
    if (-not $same) { return (& $done 14 'OUTCOME: INCONCLUSIVE (the phase slices re-derived from capture.raw and its index differ from the collector''s: refused)') }
    # per-phase inputs from the slices and session.json (NOT RUN reasons, the run-3 rule and guard)
    $phIn = New-Object System.Collections.Generic.List[object]
    $prevSha = '0000000000000000'
    $jp = @{}; foreach ($x in @($j.Phases)) { $jp[[string]$x.Ph] = $x }
    $nonceX = [string]$j.Nonce
    foreach ($ph in $script:S3cPhases) {
        $s = @($sl | Where-Object { $_.Ph -ceq $ph })
        if ($s.Count -eq 0) {
            $why = if ($jp.ContainsKey($ph) -and $jp[$ph].NotRunWhy) { [string]$jp[$ph].NotRunWhy } else { 'not requested' }
            $phIn.Add([pscustomobject]@{ Ph = $ph; Sent = $false; NotRunWhy = $why; Refusal = $null; Complete = $false; Fsb1 = $null; Chal = ''; ChainOk = $true; R3RuleHeld = $false; Markers = $null }); continue
        }
        $s = $s[0]
        $cp = Get-Fs3cSliceCompletion $s.Bytes
        $ref = if ($cp.Kind -ceq 'refusal') { Get-Fs3cRefusalInfo $cp.Line } else { $null }
        $dec = $null
        if ($cp.Kind -ceq 'record') { $dec = Test-Fsb1Record -Bytes $s.Bytes -Exp $script:S3cExp[$ph] -Nonce $nonceX -Challenge $s.Chal -Steps $script:S3cSteps[$ph] }
        $held = $false
        if ($ph -ceq 'r3' -and $jp.ContainsKey('r3') -and $null -ne $jp['r3'].R3Rule) { $held = ([bool]$jp['r3'].R3Rule.Allow -and [long]$jp['r3'].GuardLeftMs -ge [long]$jp['r3'].GuardNeedMs) }
        $mk = Get-Fs3cSliceMarkers -Bytes $s.Bytes -NonceX $nonceX -PhX $ph
        $phIn.Add([pscustomobject]@{ Ph = $ph; Sent = $true; NotRunWhy = ''; Refusal = $ref; Complete = ($cp.Kind -cne 'none'); Fsb1 = $dec; Chal = $s.Chal; ChainOk = ($s.Prev -ceq $prevSha); R3RuleHeld = $held; Markers = $mk })
        $sh = Get-Fs3cRecSha16 $s.Bytes; if ($sh) { $prevSha = $sh } else { $prevSha = '(none)' }
    }
    $rdPath = if ($ReadingsX) { $ReadingsX } else { Join-Path $cDir 'readings3c.txt' }
    $rl = $null; if (Test-Path -LiteralPath $rdPath) { $rl = [IO.File]::ReadAllLines($rdPath) }
    $sr = if ($j.PSObject.Properties['Readings']) { [string[]]@($j.Readings) } else { $null }
    $q7i = @(); if ($jp.ContainsKey('r2') -and $jp['r2'].PSObject.Properties['Q7Fallback'] -and $null -ne $jp['r2'].Q7Fallback) { $q7i = [string[]]@($jp['r2'].Q7Fallback.Items) }
    $o = Get-Fs3cOutcome -S1Class $s1 -Phases $phIn.ToArray() -ReadingLines $rl -Pin $pinX -SessionReadings $sr -Q7Items $q7i
    $lines = $pre
    foreach ($ph in $script:S3cPhases) {
        $m = $o.Phases[$ph]
        $opt = if ($ph -ne 'p0') { "; optical $($o.Optical[$ph].Class)" } else { '' }
        $dk = if ($o.Dark.Contains($ph)) { "; dark check $($o.Dark[$ph])" } else { '' }
        $lines.Add("PHASE $ph : $($m.Class)$(if ($m.Tag) { ' [' + $m.Tag + ']' }) - $($m.Reason)$opt$dk")
        if ($m.Scanout) { $lines.Add("  SCANOUT $($m.Scanout)") }
        $pi = @($phIn | Where-Object { $_.Ph -ceq $ph })[0]
        if ($null -ne $pi.Markers) { $lines.Add("  markers: $($pi.Markers.Sequence)$(if (@($pi.Markers.Notes).Count) { ' (note: ' + (@($pi.Markers.Notes) -join '; ') + ')' })") }
        if ($ph -ne 'p0' -and $o.Optical.Contains($ph)) { $lines.Add("  optical: $($o.Optical[$ph].Why)") }
    }
    foreach ($e in @($o.Layout.Keys)) { $x = $o.Layout[$e]; $lines.Add("LAYOUT $e eye: bars $(if ($x.Bars) { $x.Bars } else { '-' }) F $(if ($x.Orient) { $x.Orient } else { '-' }) line $($x.Tilt): $($x.Label) $($x.Tag)") }
    if ($null -ne $o.Interpretation) { $lines.Add("RUN-3 INTERPRETATION: $($o.Interpretation.Code) $($o.Interpretation.Text) $($o.Interpretation.Tag)") }
    if (-not $o.ReadingsOk) { $lines.Add("READINGS: $($o.ReadingsWhy)") }
    if (@($o.Q7NotAsked).Count) { $lines.Add("READINGS NOTE: r2 $(@($o.Q7NotAsked) -join ', ') not asked (Q7 fallback: the run-3 path; DESIGN 15 Q7)") }
    $lines.Add("OUTCOME: $($o.Outcome)   (proposed OUTCOMES s10 / DESIGN 11.1) $($o.Reason)")
    foreach ($lb in @($o.Labels)) { $lines.Add("LABEL: $lb") }
    $lines.Add("REGISTERED: $($o.Registered)")
    $lines.Add('A machine-side PASS is not the stage result: the stage passes only with all 8 characters read correctly in EACH eye in one machine-shown run (r1 or r2). Layout labels and the run-3 interpretation are diagnostic, never a PASS.')
    $lines.Add('Separate gates, not part of this outcome: misc rule (fs-miscrule.ps1), partition/slot/devinfo checks (<withheld document>), recovery, temperature.')
    $code = switch ($o.Outcome) { 'PASS (machine side)' { 10 } 'INTEGRITY FAULT' { 12 } 'INCONCLUSIVE' { 14 } 'NO-DISPLAY' { 15 } 'DISPLAY FAIL' { 16 } 'PRECONDITION UNMET: CRTC ACTIVE' { 17 } 'RUN 1 ONLY' { 18 } default { 13 } }
    $r0 = & $done $code @()        # $lines is $pre: already included
    $r0.Outcome = $o
    return $r0
}

if ($script:Fc3cInvocation -eq '.') { return }
# ------------------------------------------------------------------ CLI -----
$ErrorActionPreference = 'Stop'
try {
    $cDir = [string]$script:Fc3cArgs['C3cDir']; $oDir = [string]$script:Fc3cArgs['C3cObserveDir']; $s1 = [string]$script:Fc3cArgs['C3cStage1Class']
    if (-not $cDir -or (-not $s1 -and -not $oDir) -or ($s1 -and $oDir)) {
        Write-Output 'usage: fs-classify3c.ps1 -C3cDir <fs-collect3c output dir> (-C3cObserveDir <fs-observe3c output dir> | -C3cStage1Class <class>) [-C3cPatternPin <sha256>] [-C3cReadings <readings3c.txt>]'; exit 64 }
    $pinX = if ($script:Fc3cArgs['C3cPatternPin']) { [string]$script:Fc3cArgs['C3cPatternPin'] } else { $script:S3cPatternPin }
    if ($pinX -and $pinX -cnotmatch '^[0-9a-f]{64}\z') { Write-Output 'usage: -C3cPatternPin is 64 lowercase hex'; exit 64 }
    $res = Invoke-Fs3cClassifyDir -DirX $cDir -ObsDirX $oDir -S1X $s1 -PinX $pinX -ReadingsX ([string]$script:Fc3cArgs['C3cReadings'])
    foreach ($l in $res.Lines) { Write-Output $l }
    exit $res.Code
} catch { Write-Output (ConvertTo-FsPrintable "CLASSIFIER ERROR: $($_.Exception.Message)"); exit 70 }
