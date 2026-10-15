# Stage-3d synthetic session captures (test only; never used on a live path). Windows PowerShell 5.1.
# A COPY of ..\stage3c\gen3c.ps1 (the prefix G3dd instead of G3d). Differences: the records are exp=s3d_<ph>; the identity
# is v2.7 (kernel 5.10.246-gd7102a837402); r1 is the reset of fs-pattern v0.7 (stage3d/src/fs-pattern.c `reset`: start
# mode=reset, reset_precondition, buffer black=1, reset_plan, the reset_off and reset_on_* commits, two post_state, the
# post_planes, reset_close, exit reason reset_done|already_inactive shown=0; or a failed reset); r2's start record is
# v0.7 with roll=21 eyes=swap; the canonical fixtures are stage 3d's (the reset question, per-eye tilt keys).
#   . gen3d.ps1
#   $g = New-G3ddSession -Name nominal -Spec @( @{Ph='p0'}, @{Ph='r1'}, @{Ph='r2'} ) -Done $true -Path <dir>\capture.raw
# r1 options: Reset 'done' (default) | 'inactive' | 'off-reject' (50 reset_off_rejected) | 'on-reject' (50 reset_on_rejected)
#   | 'unknown' (31 crtc_state_unknown) | 'shown' (exit reset_done shown=1: a runner inconsistency) | 'nocommit' (exit
#   reset_done without the commits); Skip as gen3c. r2 options: Roll, Eyes (the start record), StartMs.
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\synth.ps1')

$script:G3dNonce = '3d3d3d3d00c0ffee'
$script:G3dPin = 'f6a9c3e2b1d0a4958877665544332211ffeeddccbbaa99887766554433221100'   # the fixture "fs-pattern" digest (as gen3c)
$script:G3dPrompt = '~ # '
$script:G3dKernel = '5.10.246-gd7102a837402'
$script:G3dPid1 = '/bin/busybox,sh,/init'
function Get-G3dHex { param([string]$Seed, [int]$Chars)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = -join ($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Seed)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    while ($h.Length -lt $Chars) { $h += $h }
    $h.Substring(0, $Chars)
}

# ---------------------------------------------------------------- FSP1 runs ----
# r1 of stage 3d: fs-pattern v0.7 `reset` (the record set of stage3d/fixtures/image/c-sim-all fsp1-r1.txt).
function Get-G3dResetRecs { param([string]$Reset = 'done')
    $r = New-Object System.Collections.Generic.List[object]
    $r.Add(@('start', 0, 'mode=reset ver=0.7 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180 t0_ms=20000'))
    $r.Add(@('open', 0, 'dev=/dev/dri/card0 major=226 minor=0')); $r.Add(@('version', 0, 'drv=msm_drm major=1 minor=4 patch=0'))
    $act = if ($Reset -ceq 'inactive') { '0' } else { '1' }
    $r.Add(@('crtc_state', 0, "idx=-1 w=4128 h=2208 vrefresh=90 getcrtc_rc=0 mode_valid=1 fb=0 active_prop=22 active=$act in_list=1 interlaced=0 expected=1"))
    if ($Reset -ceq 'unknown') {
        $r.Add(@('reset_precondition', 0, 'required=crtc_state_readable getcrtc_rc=-22 active_prop=22 active=-1 state=unknown'))
        $r.Add(@('exit', 0, 'code=31 reason=crtc_state_unknown shown=0 closed_at_exit=1 elapsed_ms=40')); return ,$r.ToArray()
    }
    if ($Reset -ceq 'inactive') {
        $r.Add(@('reset_precondition', 0, 'required=crtc_state_readable getcrtc_rc=0 active_prop=22 active=0 state=already_inactive'))
        $r.Add(@('exit', 0, 'code=0 reason=already_inactive shown=0 closed_at_exit=1 elapsed_ms=60')); return ,$r.ToArray()
    }
    $r.Add(@('reset_precondition', 0, 'required=crtc_state_readable getcrtc_rc=0 active_prop=22 active=1 state=active'))
    $r.Add(@('chosen_mode', 0, 'idx=-1 w=4128 h=2208 vrefresh=90 why=crtc_current_expected expected=1'))
    $r.Add(@('buffer', 0, 'w=4128 h=2208 handle=1 pitch=16512 size=36458496 fb=207 mode_blob=208 format=0x34325258 black=1'))
    $r.Add(@('reset_plan', 0, 'conn=55 crtc=155 objs=6 props=11 planes_off=4 overflow=0 reenable_attempts=2 helper=1'))
    if ($Reset -ceq 'off-reject') {
        $r.Add(@('test_commit', -22, 'attempt=0 modeset=1 layout=reset_off objs=6 props=11 planes_off=4 overflow=0 result=rejected'))
        $r.Add(@('exit', 0, 'code=50 reason=reset_off_rejected shown=0 closed_at_exit=1 elapsed_ms=300')); return ,$r.ToArray()
    }
    $r.Add(@('test_commit', 0, 'attempt=0 modeset=1 layout=reset_off objs=6 props=11 planes_off=4 overflow=0 result=accepted'))
    if ($Reset -cne 'nocommit') { $r.Add(@('commit', 0, 'attempt=0 modeset=1 layout=reset_off commit_ms=120')) }
    $r.Add(@('post_state', 0, 'topology_val=0 topology_name=sde_none active=0 mode_id=0 mode_valid=0 fb=0'))
    for ($k = 0; $k -lt 4; $k++) { $r.Add(@('post_plane', 0, "slot=$k plane=$(@(71, 97, 100, 103)[$k]) crtc_id=0 fb_id=0 crtc_x=0 crtc_y=0 crtc_w=0 crtc_h=0 src_x=0 src_y=0 src_w=0 src_h=0 src_frac=0 zpos=0")) }
    $r.Add(@('test_commit', -7, 'attempt=1 modeset=1 layout=reset_on_single objs=6 props=19 planes_off=3 overflow=0 result=rejected'))
    if ($Reset -ceq 'on-reject') {
        $r.Add(@('test_commit', -7, 'attempt=2 modeset=1 layout=reset_on_split objs=6 props=27 planes_off=2 overflow=0 result=rejected'))
        $r.Add(@('exit', 0, 'code=50 reason=reset_on_rejected shown=0 closed_at_exit=1 elapsed_ms=900')); return ,$r.ToArray()
    }
    $r.Add(@('test_commit', 0, 'attempt=2 modeset=1 layout=reset_on_split objs=6 props=27 planes_off=2 overflow=0 result=accepted'))
    if ($Reset -cne 'nocommit') { $r.Add(@('commit', 0, 'attempt=2 modeset=1 layout=reset_on_split commit_ms=643')) }
    $r.Add(@('post_state', 0, 'topology_val=14 topology_name=sde_quadpipe_dsc4hsmerge active=1 mode_id=208 mode_valid=1 fb=207'))
    $r.Add(@('post_plane', 0, 'slot=0 plane=71 crtc_id=155 fb_id=207 crtc_x=0 crtc_y=0 crtc_w=2064 crtc_h=2208 src_x=0 src_y=0 src_w=2064 src_h=2208 src_frac=0 zpos=0'))
    $r.Add(@('post_plane', 0, 'slot=1 plane=97 crtc_id=155 fb_id=207 crtc_x=0 crtc_y=0 crtc_w=2064 crtc_h=2208 src_x=2064 src_y=0 src_w=2064 src_h=2208 src_frac=0 zpos=0'))
    $r.Add(@('reset_close', 0, 'close_rc=0 close_ms=534'))
    $sh = if ($Reset -ceq 'shown') { 1 } else { 0 }
    $r.Add(@('exit', 0, "code=0 reason=reset_done shown=$sh closed_at_exit=0 elapsed_ms=1600"))
    ,$r.ToArray()
}
function Get-G3dRun1Recs { param([int]$Code = 0, [string]$CloseRc = '0', [switch]$NoCommit, [switch]$Zpos)
    $r = New-Object System.Collections.Generic.List[object]
    $r.Add(@('start', 0, 'mode=show ver=0.6 hold_req=3 hold=3 hold_max=10 clamped=0 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180 t0_ms=19980'))
    $r.Add(@('open', 0, 'dev=/dev/dri/card0 major=226 minor=0')); $r.Add(@('version', 0, 'drv=msm_drm major=1 minor=4 patch=0'))
    $r.Add(@('crtc_state', 0, 'idx=-1 w=4128 h=2208 vrefresh=90 getcrtc_rc=0 mode_valid=1 fb=0 active_prop=22 active=1 in_list=1 interlaced=0 expected=1'))
    $r.Add(@('plane_caps', 0, 'plane=71 read_rc=0 caps_bytes=600 max_linewidth=5120 pipe_idx=0 max_upscale=20 smart=none zpos=0 nv12=1'))
    if ($Zpos) { $r.Add(@('plan', 0, 'attempts=3 use_current=1 modeset_allowed=1 helper=1 zpos_set=0.0.1.1')) } else { $r.Add(@('plan', 0, 'attempts=3 use_current=1 modeset_allowed=1 helper=1')) }
    $r.Add(@('test_commit', 0, 'attempt=3 modeset=1 layout=split objs=6 props=27 planes_off=2 overflow=0 result=accepted'))
    if (-not $NoCommit) {
        $r.Add(@('commit', 0, 'attempt=3 modeset=1 layout=split commit_ms=657'))
        $r.Add(@('post_state', 0, 'topology_name=sde_quadpipe_dsc4hsmerge dsc_mode_val=2 active=1 core_clk=550000000'))
        $r.Add(@('hold_start', 0, 'hold_s=3 start_ms=20000 deadline_ms=23000 alarm_s=8'))
        $r.Add(@('hold_end', 0, "reason=deadline sig=0 held_ms=3000 late_ms=0 fd_closed=1 close_rc=$CloseRc close_ms=534"))
        $r.Add(@('exit', 0, "code=$Code reason=held_to_deadline shown=1 closed_at_exit=0 elapsed_ms=3560"))
    } else { $r.Add(@('exit', 0, "code=$Code reason=x shown=0 closed_at_exit=1 elapsed_ms=40")) }
    ,$r.ToArray()
}
# run 2 (show-off-quad) or run 3 (show-off-solid). -Layout quad_vig|quad_dma; -Code 0|50|31|60;
# -Unconverted (CRTC_X 2064/3096 read back), -ZposPost (a post_plane zpos other than 0/0/1/1), -SplitCommit,
# -TypeDma (quad_vig committed on max_upscale 1 planes), -StartMs (the pause), -CloseRc.
function Get-G3dQuadRecs {
    param([string]$Mode = 'show-off-quad', [int]$Hold = 10, [string]$Layout = 'quad_vig', [int]$Code = 0, [long]$StartMs = 27000, [switch]$Unconverted,
          [switch]$ZposPost, [switch]$SplitCommit, [switch]$TypeDma, [string]$CloseRc = '0', [string]$Active = '0', [string]$Roll = '21', [string]$Eyes = 'swap')
    $r = New-Object System.Collections.Generic.List[object]
    $ro = if ($Mode -ceq 'show-off-quad') { " roll=$Roll eyes=$Eyes" } else { '' }
    $r.Add(@('start', 0, "mode=$Mode ver=0.7 hold_req=$Hold hold=$Hold hold_max=10 clamped=0 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180$ro t0_ms=$($StartMs - 20)"))
    $r.Add(@('crtc_state', 0, "idx=-1 w=0 h=0 vrefresh=0 getcrtc_rc=0 mode_valid=0 fb=0 active_prop=22 active=$Active in_list=0 interlaced=0 expected=0"))
    if ($Code -eq 31) {
        $r.Add(@('precondition', -16, 'required=crtc_inactive getcrtc_rc=0 active_prop=22 active=1'))
        $r.Add(@('exit', 0, 'code=31 reason=crtc_active shown=0 closed_at_exit=1 elapsed_ms=40'))
        return ,$r.ToArray()
    }
    $r.Add(@('precondition', 0, 'required=crtc_inactive getcrtc_rc=0 active_prop=22 active=0'))
    $vig = @(71, 97, 100, 103); $dma = @(115, 134, 112, 131)
    for ($k = 0; $k -lt 4; $k++) { $up = if ($TypeDma) { 1 } else { 20 }; $r.Add(@('plane_caps', 0, "plane=$($vig[$k]) read_rc=0 caps_bytes=600 max_linewidth=5120 pipe_idx=$k max_upscale=$up smart=none zpos=0 nv12=1")) }
    $r.Add(@('plane_caps', 0, 'plane=115 read_rc=0 caps_bytes=500 max_linewidth=5120 pipe_idx=3 max_upscale=1 smart=none zpos=0 nv12=0')); $r.Add(@('plane_caps', 0, 'plane=134 read_rc=0 caps_bytes=500 max_linewidth=5120 pipe_idx=3 max_upscale=1 smart=115 zpos=0 nv12=0'))
    $r.Add(@('plane_caps', 0, 'plane=112 read_rc=0 caps_bytes=500 max_linewidth=5120 pipe_idx=2 max_upscale=1 smart=none zpos=0 nv12=0')); $r.Add(@('plane_caps', 0, 'plane=131 read_rc=0 caps_bytes=500 max_linewidth=5120 pipe_idx=2 max_upscale=1 smart=112 zpos=0 nv12=0'))
    $uv = if ($TypeDma) { '1.1.1.1' } else { '20.20.20.20' }
    $r.Add(@('plan', 0, "attempts=3 split_probe=1 quad_vig=71.97.100.103 quad_dma=115.134.112.131 pipe_vig=vig-0.vig-1.vig-2.vig-3 pipe_dma=dma-3.dma-3.dma-2.dma-2 max_upscale_vig=$uv max_upscale_dma=1.1.1.1 zpos_before_vig=0.0.0.0 zpos_before_dma=0.0.0.0 zpos_set=0.0.1.1 splash_set=match"))
    $r.Add(@('test_commit', 0, 'attempt=0 modeset=1 layout=split_probe objs=6 props=27 planes_off=0 overflow=0 result=accepted'))
    if ($Code -eq 50) {
        $r.Add(@('test_commit', -22, 'attempt=1 modeset=1 layout=quad_vig objs=8 props=49 planes_off=0 overflow=0 result=rejected'))
        $r.Add(@('test_commit', -22, 'attempt=2 modeset=1 layout=quad_dma objs=8 props=49 planes_off=0 overflow=0 result=rejected'))
        $r.Add(@('exit', 0, 'code=50 reason=every_attempt_rejected shown=0 closed_at_exit=1 elapsed_ms=300'))
        return ,$r.ToArray()
    }
    if ($Layout -ceq 'quad_dma') { $r.Add(@('test_commit', -22, 'attempt=1 modeset=1 layout=quad_vig objs=8 props=49 planes_off=0 overflow=0 result=rejected')) }
    $r.Add(@('test_commit', 0, "attempt=$(if ($Layout -ceq 'quad_dma') { 2 } else { 1 }) modeset=1 layout=$Layout objs=8 props=49 planes_off=0 overflow=0 result=accepted"))
    $cl = if ($SplitCommit) { 'split_probe' } else { $Layout }
    $r.Add(@('commit', 0, "attempt=1 modeset=1 layout=$cl commit_ms=880"))
    $r.Add(@('post_state', 0, 'topology_val=14 topology_name=sde_quadpipe_dsc4hsmerge dsc_mode_val=2 control_val=0 active=1 mode_valid=1 core_clk=550000000 core_ab=16000000000 core_ib=16000000000'))
    $ids = if ($Layout -ceq 'quad_dma') { $dma } else { $vig }
    for ($k = 0; $k -lt 4; $k++) {
        $cx = if ($Unconverted) { 1032 * $k } else { 1032 * ($k % 2) }
        $z = if ($ZposPost -and $k -eq 3) { 0 } else { @(0, 0, 1, 1)[$k] }
        $r.Add(@('post_plane', 0, "slot=$k plane=$($ids[$k]) crtc_id=155 fb_id=300 crtc_x=$cx crtc_y=0 crtc_w=1032 crtc_h=2208 src_x=$(1032 * $k) src_y=0 src_w=1032 src_h=2208 src_frac=0 zpos=$z"))
    }
    if ($Code -eq 60) { $r.Add(@('exit', 0, 'code=60 reason=commit_failed shown=0 closed_at_exit=1 elapsed_ms=900')); return ,$r.ToArray() }
    $r.Add(@('hold_start', 0, "hold_s=$Hold start_ms=$StartMs deadline_ms=$($StartMs + 1000 * $Hold) alarm_s=$($Hold + 5)"))
    $r.Add(@('hold_end', 0, "reason=deadline sig=0 held_ms=$(1000 * $Hold) late_ms=0 fd_closed=1 close_rc=$CloseRc close_ms=530"))
    $r.Add(@('exit', 0, "code=$Code reason=held_to_deadline shown=1 closed_at_exit=0 elapsed_ms=$(1000 * $Hold + 1000)"))
    ,$r.ToArray()
}
# A probe step's stdout (stage-3b format: == point / -- irq / -- at; the one backlight write only in p0).
function Get-G3dProbe { param([string]$Role, [double]$Up0 = 30.0, [switch]$Write, [string]$Readback = '127', [switch]$TwoWrites, [switch]$Dmesg)
    $sb = New-Object System.Text.StringBuilder
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $null = $sb.Append("FSPR1 helper=$Role start up=$($Up0.ToString('0.00', $inv))`n")
    $te = 1000; $t = $Up0
    $pts = if ($Role -ceq 'p0') { @('irq0', 'mods') } else { @('pre', 'go1', 'mid', 'end', 'post') }
    foreach ($p in $pts) {
        $dt = if ($p -ceq 'go1') { 1.5 } elseif ($p -ceq 'mid') { 2.0 } elseif ($p -ceq 'end') { 2.0 } else { 0.2 }
        $t += $dt; if (@('mid', 'end', 'post') -ccontains $p) { $te += [int](181 * $dt) } elseif ($p -ceq 'go1') { $te += 90 }
        $irqs = " 210:  $te  0  GICv3  te-edge-isr`n 211:  $te  0  GICv3  blu-pwm-isr`n-- at $($t.ToString('0.00', $inv))`n"
        $pn = if ($p -ceq 'go1') { 'go+1' } else { $p }
        $null = $sb.Append("== point $pn run=$Role up=$($t.ToString('0.00', $inv))`n-- irq`n$irqs")
        if (($p -ceq 'mods' -or $p -ceq 'mid') -and $Dmesg) { $null = $sb.Append("[   31.123456] msm_drm: sde underrun detected intf 1`n-- dmesg: 1 new matching line(s), 1 shown`n") }
        if ($p -ceq 'mods' -and $Write) {
            $null = $sb.Append("== backlight-write node=/sys/class/backlight/panel0-backlight/brightness value=127 up=$($t.ToString('0.00', $inv))`nwrite_rc=0 readback=$Readback`n")
            if ($TwoWrites) { $null = $sb.Append("== backlight-write node=/sys/class/backlight/panel0-backlight/brightness value=127 up=$($t.ToString('0.00', $inv))`nwrite_rc=0 readback=$Readback`n") }
        }
        if ($p -ceq 'pre' -and -not $Write) { $null = $sb.Append("== backlight-verify node=/sys/class/backlight/panel0-backlight/brightness (read only)`nreadback=$Readback`n") }
    }
    $null = $sb.Append("FSPR1 helper=$Role end up=$(($t + 0.3).ToString('0.00', $inv))`n")
    $sb.ToString()
}
# The decoded steps of one phase. $O: options (see New-G3dSession).
function Get-G3dSteps { param([string]$Ph, [string]$Chal, [hashtable]$O)
    $c8 = $Chal.Substring(0, 8)
    $opt = { param([string]$k, $d) if ($O.ContainsKey($k)) { $O[$k] } else { $d } }
    switch ($Ph) {
        'p0' {
            $pin = & $opt 'Pin' $script:G3dPin
            return @((New-SynthStep 1 'hash' (SB "$pin  /bin/fs-pattern`n")),
                     (New-SynthStep 2 'probe0' (SB (Get-G3dProbe -Role 'p0' -Write -Readback (& $opt 'Readback' '127') -TwoWrites:([bool](& $opt 'TwoWrites' $false))))))
        }
        'r1' {
            if ($O.ContainsKey('Skip')) { $s = "FSK1 run=1 skipped reason=$($O['Skip']) END`n"; $code = [long]0 }
            else {
                $rr = [string](& $opt 'Reset' 'done')
                $s = New-SynthFsp1 -Nonce8 $c8 -Recs (Get-G3dResetRecs -Reset $rr)
                $code = [long]$(switch -CaseSensitive ($rr) { 'off-reject' { 50 } 'on-reject' { 50 } 'unknown' { 31 } default { 0 } })
            }
            return @((New-SynthStep 1 'probe1' (SB (Get-G3dProbe -Role 'r1' -Up0 40 -Readback (& $opt 'Readback' '127') -Dmesg:([bool](& $opt 'Dmesg' $false))))),
                     (New-SynthStep 2 'pattern1' (SB $s) @() @{ code = $code; ms = [long]3600 }))
        }
        default {
            $n = $Ph.Substring(1, 1)
            $mode = if ($Ph -ceq 'r3') { 'show-off-solid' } else { 'show-off-quad' }
            $hold = if ($Ph -ceq 'r3') { 5 } else { 10 }
            $start = if ($Ph -ceq 'r3') { [long]45000 } else { [long]27000 }
            if ($O.ContainsKey('Skip')) { $s = "FSK1 run=$n skipped reason=$($O['Skip']) END`n"; $code = [long]0 }
            else {
                $s = New-SynthFsp1 -Nonce8 $c8 -Recs (Get-G3dQuadRecs -Mode (& $opt 'Mode' $mode) -Hold $hold -Layout (& $opt 'Layout' 'quad_vig') -Code (& $opt 'Code' 0) -StartMs (& $opt 'StartMs' $start) `
                    -Unconverted:([bool](& $opt 'Unconverted' $false)) -ZposPost:([bool](& $opt 'ZposPost' $false)) -SplitCommit:([bool](& $opt 'SplitCommit' $false)) -TypeDma:([bool](& $opt 'TypeDma' $false)) -CloseRc (& $opt 'CloseRc' '0') `
                    -Roll ([string](& $opt 'Roll' '21')) -Eyes ([string](& $opt 'Eyes' 'swap')))
                $code = [long](& $opt 'Code' 0)
            }
            return @((New-SynthStep 1 "probe$n" (SB (Get-G3dProbe -Role $Ph -Up0 (50 + 15 * [int]$n) -Readback (& $opt 'Readback' '127') -Write:([bool](& $opt 'ProbeWrite' $false))))),
                     (New-SynthStep 2 "pattern$n" (SB $s) @() @{ code = $code; ms = [long](1000 * $hold + 1200) }))
        }
    }
}
function Get-G3dMarker { param([string]$NonceX, [string]$Ph, [string]$E, [long]$T) "FSPM1 n=$NonceX p=$Ph e=$E t=$T END" }

# A whole session. -Spec: one hashtable per phase the collector will send, in order:
#   Ph         p0|r1|r2|r3
#   Rec        'valid' (default) | 'reject' (one DATA line dropped: line-count) | 'trunc' (cut mid-record, no prompt)
#              | 'ran0' | 'ran1' (FSXE1 after the markers) | 'ran1emit' (the rec marker, a partial record, then FSXE1) | 'noprompt'
#   Error      the FSXE1 error= text (default: chain for ran0, step2 for ran1, emit-1 for ran1emit)
#   Markers    'std' (default) | 'none' | 'skip' | an array of raw marker lines (inserted after the echo)
#   SplitMarkers  $true: each marker line arrives in two chunks (split mid-line)
#   Stray      bytes (text) that arrive StrayMs after the settled prompt (and before any further write)
#   StrayMs    default 5000
#   plus Get-G3dSteps options: Pin, Readback, TwoWrites, Skip, Code, CloseRc, NoCommit, Zpos, Layout, Unconverted,
#   ZposPost, SplitCommit, TypeDma, StartMs, Mode, ProbeWrite, Dmesg, Chal (override the challenge), Prev (override <prev>)
# -Done: the collector sends fs-done at the end. -NoncePh: overrides the nonce in records (wrong-nonce cases).
function New-G3dSession {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Spec, [bool]$Done = $true, [string]$Path = '', [string]$NonceX = $script:G3dNonce)
    $S = New-Synth -Nonce $NonceX
    $S.Ms = 0
    $tk = @{ V = (Get-G3dHex "$Name/v" 32); A = (Get-G3dHex "$Name/a" 16); C = @{} }
    foreach ($ph in 'p0', 'r1', 'r2', 'r3') { $tk.C[$ph] = Get-G3dHex "$Name/$ph" 32 }
    $writes = New-Object System.Collections.Generic.List[string]
    $sha = @{}; $recs = @{}
    $P = $script:G3dPrompt
    Add-Dev $S (SB "`n`nBusyBox v1.36.1 (2026-10-01) built-in shell (ash)`nEnter 'help' for a list of built-in commands.`n`n$P") -Dt 10
    $host1 = { param([string]$cmd, [int]$at) $S.Ms = [long]$at; Add-Host $S $cmd -Dt 0; $writes.Add($cmd) }
    $dev = { param([string]$text, [int]$dt) Add-Dev $S (SB $text) -Dt $dt }
    & $host1 "fs-verify $($tk.V)" 1400
    & $dev "fs-verify $($tk.V)`n" 3
    & $dev "FSV1 nonce=$NonceX resp=$(Get-FsExpectedResponse -Nonce $NonceX -Challenge $tk.V) kernel=$($script:G3dKernel) pid1=$($script:G3dPid1) stages=INIT_STARTED,MODULES_READY,ACM_SETUP_ATTEMPTED,UDC_BOUND,SHELL_READY END`n$P" 40
    & $host1 "fs-ack $($tk.A)" 1700
    & $dev "fs-ack $($tk.A)`nFSA1 queued END`n$P" 5
    & $host1 'fs-status' 4400
    & $dev "fs-status`nFSS1 nonce=$NonceX stages=INIT_STARTED,MODULES_READY,ACM_SETUP_ATTEMPTED,UDC_BOUND,SHELL_READY,HOST_ACK acked=$($tk.A) END`n$P" 8
    $prev = '0000000000000000'
    $at = 5000
    foreach ($sp in $Spec) {
        $ph = [string]$sp['Ph']
        $chal = if ($sp.ContainsKey('Chal')) { [string]$sp['Chal'] } else { $tk.C[$ph] }
        $tk.C[$ph] = $chal
        $pv = if ($sp.ContainsKey('Prev')) { [string]$sp['Prev'] } else { $prev }
        $kind = if ($sp.ContainsKey('Rec')) { [string]$sp['Rec'] } else { 'valid' }
        $cmd = "fs-phase $ph $chal $pv"
        & $host1 $cmd $at
        & $dev "$cmd`n" 4
        # markers
        $lit = ($ph -cne 'p0')
        $mkSpec = if ($sp.ContainsKey('Markers')) { $sp['Markers'] } else { 'std' }
        $t0 = [long](40000 + 20000 * [array]::IndexOf(@('p0', 'r1', 'r2', 'r3'), $ph))
        $holdMs = @{ p0 = 0; r1 = 1600; r2 = 11000; r3 = 6000 }[$ph]
        $mk = New-Object System.Collections.Generic.List[object]   # @(line, dtMs)
        if ($mkSpec -is [string]) {
            switch ($mkSpec) {
                'std'  { $mk.Add(@((Get-G3dMarker $NonceX $ph 'begin' $t0), 15))
                         if ($lit) { $mk.Add(@((Get-G3dMarker $NonceX $ph 'go' ($t0 + 2100)), 2100)); $mk.Add(@((Get-G3dMarker $NonceX $ph 'end' ($t0 + 2100 + $holdMs)), $holdMs)) }
                         $mk.Add(@((Get-G3dMarker $NonceX $ph 'rec' ($t0 + 4000 + $holdMs)), 1900)) }
                'skip' { $mk.Add(@((Get-G3dMarker $NonceX $ph 'begin' $t0), 15)); $mk.Add(@((Get-G3dMarker $NonceX $ph 'skip' ($t0 + 2000)), 2000)); $mk.Add(@((Get-G3dMarker $NonceX $ph 'rec' ($t0 + 2500)), 500)) }
                'none' { }
            }
        } else { $dt = 15; foreach ($l in @($mkSpec)) { $mk.Add(@([string]$l, $dt)); $dt = 1500 } }
        if ($kind -ceq 'ran0') { $mk.Clear() }
        # DESIGN 5.2/5.4 (integration pass): a ran=1 refusal decided before the emission (step<i>, end, record-too-large)
        # has no rec marker; emit-<rc> follows the rec marker (rec = "the paced emission starts now")
        if ($kind -ceq 'ran1') { $keep = @($mk | Where-Object { $_[0] -notmatch ' e=rec ' }); $mk.Clear(); foreach ($m in $keep) { $mk.Add($m) } }
        foreach ($m in $mk) {
            $line = "$($m[0])`n"
            if ($sp.ContainsKey('SplitMarkers') -and $sp['SplitMarkers']) { $h = [int]($line.Length / 2); & $dev $line.Substring(0, $h) $m[1]; & $dev $line.Substring($h) 30 }
            else { & $dev $line $m[1] }
        }
        $refErr = if ($sp.ContainsKey('Error')) { [string]$sp['Error'] } else { @{ ran0 = 'chain'; ran1 = 'step2'; ran1emit = 'emit-1' }[$kind] }
        if ($kind -ceq 'ran0') { & $dev "FSXE1 p=$ph ran=0 error=$refErr END`n$P" 30 }
        elseif ($kind -ceq 'ran1') { $rl = if ($sp.ContainsKey('RefusalLine')) { [string]$sp['RefusalLine'] } else { "FSXE1 p=$ph ran=1 error=$refErr END" }; & $dev "$rl`n$P" 400 }
        else {
            $steps = Get-G3dSteps -Ph $ph -Chal $chal -O $sp
            $rec = New-SynthFsb1 -Exp "s3d_$ph" -Nonce $NonceX -Chal $chal -Steps $steps
            $recs[$ph] = $rec
            $sha[$ph] = ([regex]::Match($rec, 'rec_sha256=([0-9a-f]{64})')).Groups[1].Value.Substring(0, 16)
            $lines = $rec.Split([char]10)
            if ($kind -ceq 'reject') { $di = [array]::FindIndex($lines, [Predicate[string]]{ param($x) $x.StartsWith('FSB1 DATA ') }); $lines = @($lines | Select-Object -First $di) + @($lines | Select-Object -Skip ($di + 1)) }
            if ($kind -ceq 'ran1emit') { $lines = @($lines | Select-Object -First 5) }
            if ($kind -ceq 'trunc') { $lines = @($lines | Select-Object -First ([int]($lines.Count / 2))) }
            # the leading empty line, then the record in paced chunks of 20 lines
            & $dev "`n" 300
            for ($i = 0; $i -lt $lines.Count; $i += 20) {
                $chunk = ((@($lines | Select-Object -Skip $i -First 20)) -join "`n")
                if ($i + 20 -lt $lines.Count) { $chunk += "`n" }
                & $dev $chunk 110
            }
            if ($kind -ceq 'ran1emit') { & $dev "`nFSXE1 p=$ph ran=1 error=$refErr END`n$P" 50 }
            elseif ($kind -ceq 'trunc') { }
            elseif ($kind -ceq 'noprompt') { }
            else { & $dev $P 20 }
            if (-not $lines[-1].StartsWith('FSB1 END') -and $kind -ceq 'reject') { }
        }
        if ($sp.ContainsKey('Stray')) { $sm = if ($sp.ContainsKey('StrayMs')) { [int]$sp['StrayMs'] } else { 5000 }; & $dev ([string]$sp['Stray']) $sm }
        if ($sha.ContainsKey($ph)) { $prev = $sha[$ph] }
        $at = [int]$S.Ms + 1000
    }
    if ($Done) { & $host1 'fs-done' $at; & $dev "fs-done`nFSD1 queued END`n" 5 }
    if ($Path) {
        $d = Split-Path -Parent $Path; if ($d -and -not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Force -Path $d }
        Save-Synth $S $Path
    }
    [pscustomobject]@{ Name = $Name; Path = $Path; Tokens = $tk; Sha16 = $sha; Records = $recs; Writes = $writes.ToArray(); NonceX = $NonceX }
}

# The canonical stored fixtures (..\stage3d\replay\<name>\capture.raw + .idx + keys.txt): regenerated by test-host3d.ps1
# and compared byte for byte with the stored copies. Keys: after the reset the one question (y = something visible, b = it
# stayed dark; review 2 MINOR-2), then run 2; per eye the tilt, the F, then the bars (review 2 MAJOR-1).
$script:G3dCanon = [ordered]@{
    'nominal-read' = @{ Spec = @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2' }); Done = $true
        Keys = @('p:1500:b', 'p:2000:d', 'p:400:{c0}', 'p:300:{c1}', 'p:300:{c2}', 'p:300:{c3}', 'p:300:{c4}', 'p:300:{c5}', 'p:300:{c6}', 'p:300:{c7}', 'p:400:Enter',
                 'p:1500:d', 'p:400:{c0}', 'p:300:{c1}', 'p:300:{c2}', 'p:300:{c3}', 'p:300:{c4}', 'p:300:{c5}', 'p:300:{c6}', 'p:300:{c7}', 'p:400:Enter', 'p:900:y',
                 'p:1200:0', 'p:900:u', 'p:900:1', 'p:300:2', 'p:1200:0', 'p:900:u', 'p:900:3', 'p:300:4')
        Notes = 'the reset seen: no; run 2 read correctly in both eyes, bars 1|2 left and 3|4 right, F upright, level: the swap and roll corrections hold; no run 3 (rule 2); fs-done' }
    'garbled-r3' = @{ Spec = @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2' }, @{ Ph = 'r3' }); Done = $true
        Keys = @('p:1500:b', 'p:1800:c', 'p:900:c', 'p:800:y', 'p:2000:s', 'p:900:s', 'p:800:y')
        Notes = 'the reset seen: no; run 2 garbled in both eyes: run 3 (red field) is requested; no bar counts on this path (Q7 fallback); run 3 SAME_AS_R2; fs-done. The rehearsal fixture (SIGNOFF-3d A).' }
    'swapped-tilted' = @{ Spec = @(@{ Ph = 'p0' }, @{ Ph = 'r1' }, @{ Ph = 'r2' }); Done = $true
        Keys = @('p:1500:y', 'p:2000:d', 'p:400:{c0}', 'p:300:{c1}', 'p:300:{c2}', 'p:300:{c3}', 'p:300:{c4}', 'p:300:{c5}', 'p:300:{c6}', 'p:300:{c7}', 'p:400:Enter',
                 'p:1500:d', 'p:400:{c0}', 'p:300:{c1}', 'p:300:{c2}', 'p:300:{c3}', 'p:300:{c4}', 'p:300:{c5}', 'p:300:{c6}', 'p:300:{c7}', 'p:400:Enter', 'p:900:y',
                 'p:1200:r', 'p:900:u', 'p:900:3', 'p:300:4', 'p:1200:l', 'p:900:u', 'p:900:1', 'p:300:2')
        Notes = 'the reset seen: yes (recorded, run 2 follows); run 2 read in both eyes but bars 3|4 left and 1|2 right (the swap is wrong) and tilted clockwise left, counter-clockwise right (the roll is wrong): a STAGE PASS with the geometry findings' }
}
function Expand-G3dKeys { param([string[]]$Keys, [string]$Chal)
    @($Keys | ForEach-Object { $k = $_; for ($i = 0; $i -lt 8; $i++) { $k = $k.Replace("{c$i}", $Chal.Substring($i, 1)) }; $k })
}
