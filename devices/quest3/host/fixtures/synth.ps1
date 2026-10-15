# Synthetic-fixture helpers (test only; never used on a live path).
#   - New-SynthStep / New-SynthFsb1: FSB1 records in the exact FSB1-SPEC §3
#     form (an independent host-side encoder for fixtures; the real encoder is
#     common/target/fsb1-enc.sh, whose output is also replayed: valid.txt).
#   - New-Synth / Add-Dev / Add-Host / Save-Synth: a capture plus index, as
#     fs-collect.ps1 writes them, for Replay.
#   - Get-Stage2aGoodSteps: the eight stage-2a steps as a correct target
#     would produce them (OUTCOMES §2, §4, §5; pins from stage2a/T1-pins.json;
#     step 8 `inv` is informational, revision 4).
#   - New-SynthFsp1 / Get-Stage3aGoodSteps: FSP1 streams (fs-pattern's log
#     format, with an independent bitwise CRC-32) and the two stage-3a steps of
#     a target whose display commit succeeded (OUTCOMES §8).
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\fs-native.ps1')

$script:SynL1 = [System.Text.Encoding]::GetEncoding(28591)
$script:SynKernel = '5.10.198-01402-g1c5986fe21ee'
$script:SynPid1 = '/bin/busybox,sh,/init'
$script:SynKat = '786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce'
function SB([string]$s) { ,$script:SynL1.GetBytes($s) }

function Get-SynthPins {
    $j = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\stage2a\T1-pins.json') | ConvertFrom-Json
    @(foreach ($f in $j.files) { [pscustomobject]@{ Path = "/valve/$($f.path)"; Sha256 = $f.sha256 } })
}

# One step in the decoded form Test-Fsb1Record returns.
function New-SynthStep {
    param([int]$I, [string]$Id, [byte[]]$Out = @(), [byte[]]$Err = @(), [hashtable]$F = @{})
    if ($null -eq $Out) { $Out = [byte[]]@() }; if ($null -eq $Err) { $Err = [byte[]]@() }
    $st = [ordered]@{ i = [long]$I; id = $Id; end = 'exited'; code = [long]0; sig = [long]0; errno = [long]0; ms = [long]12
                      term_ms = [long]-1; kill_ms = [long]-1; out_total = [long]$Out.Length; out_kept = [long]$Out.Length
                      err_total = [long]$Err.Length; err_kept = [long]$Err.Length; strays = [long]0; pipes = 'eof'; why = 'none'
                      out_len = [long]$Out.Length; out_sha256 = (Get-FsSha256Hex $Out); err_len = [long]$Err.Length; err_sha256 = (Get-FsSha256Hex $Err) }
    foreach ($k in $F.Keys) { $st[$k] = $F[$k] }
    $h = @{}; foreach ($k in $st.Keys) { $h[$k] = $st[$k] }
    $h['out'] = $Out; $h['err'] = $Err
    $h
}
$script:SynKeys = @('i','id','end','code','sig','errno','ms','term_ms','kill_ms','out_total','out_kept','err_total','err_kept','strays','pipes','why','out_len','out_sha256','err_len','err_sha256')

function New-SynthFsb1 {   # -> record text with '\n' terminators
    param([string]$Exp, [string]$Nonce, [string]$Chal, [object[]]$Steps)
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("FSB1 BEGIN v=1 exp=$Exp nonce=$Nonce chal=$Chal steps=$($Steps.Count)")
    foreach ($st in $Steps) {
        $L.Add('FSB1 STEP ' + (($script:SynKeys | ForEach-Object { "$_=$($st[$_])" }) -join ' '))
        foreach ($sx in 'o', 'e') {
            [byte[]]$b = $st['err']; if ($sx -eq 'o') { $b = $st['out'] }   # direct assignment keeps an empty array
            if ($b.Length -eq 0) { continue }
            $t = [Convert]::ToBase64String($b); $n = 0
            for ($p = 0; $p -lt $t.Length; $p += 64) { $L.Add("FSB1 DATA i=$($st['i']) s=$sx n=$n " + $t.Substring($p, [Math]::Min(64, $t.Length - $p))); $n++ }
        }
    }
    $body = (($L | ForEach-Object { "$_`n" }) -join '')
    $L.Add("FSB1 END v=1 nonce=$Nonce chal=$Chal lines=$($L.Count) rec_sha256=$(Get-FsSha256Hex (SB $body))")
    (($L | ForEach-Object { "$_`n" }) -join '')
}

function Get-Stage2aGoodSteps {
    param([string]$Nonce, [string]$Chal, [string]$Kernel = $script:SynKernel)
    $pins = Get-SynthPins
    $hash = (($pins | ForEach-Object { "$($_.Sha256)  $($_.Path)`n" }) -join '')
    $diag = "dl_dst_lib=`"lib`"`ndl_hwcap=0x119ff`ndl_pagesize=0x1000`ndl_platform=`"aarch64`"`n" +
            "path.prefix=`"/usr`"`npath.rtld=`"/usr/lib/ld-linux-aarch64.so.1`"`npath.system_dirs[0x0]=`"/usr/lib/`"`n" +
            "version.release=`"stable`"`nversion.version=`"2.39`"`n"
    $list = "`tlinux-vdso.so.1 (0x0000ffff9a3f0000)`n`tlibc.so.6 => /valve/lib/libc.so.6 (0x0000ffff9a200000)`n" +
            "`t/lib/ld-linux-aarch64.so.1 => /valve/lib/ld-linux-aarch64.so.1 (0x0000ffff9a3b0000)`n"
    $chal = (Get-FsBlake2bHex (SB "$($Nonce):$Chal")) + "  -`n"
    @(
        (New-SynthStep 1 'hash'   (SB $hash)),
        (New-SynthStep 2 'absent' @()),
        (New-SynthStep 3 'diag'   (SB $diag)),
        (New-SynthStep 4 'list'   (SB $list)),
        (New-SynthStep 5 'uname'  (SB "$Kernel`n")),
        (New-SynthStep 6 'b2kat'  (SB "$($script:SynKat)  -`n")),
        (New-SynthStep 7 'b2chal' (SB $chal)),
        (New-SynthStep 8 'inv'    (SB $script:SynInv))
    )
}
$script:SynInv = "== /proc/modules`nqcom_q6v5_pas 49152 0 - Live 0x0000000000000000`n== /sys/class/remoteproc`n" +
                 "-- /sys/class/remoteproc/remoteproc0/name`nadsp`n-- /sys/class/remoteproc/remoteproc0/state`noffline`n" +
                 "== /sys/bus/platform/devices/3000000.remoteproc-adsp/driver`n(absent)`n== /sys/class/power_supply`n" +
                 "-- /sys/class/power_supply/battery/uevent`nPOWER_SUPPLY_NAME=battery`n== end`n"

# ------------------------------------------------------------- stage 3a ----
$script:SynPatternPin = 'c7f28cc70f05387416c47d48707ab3e20bd3ba2306cf483516e353739519ad2a'
function Get-SynthCrc32 { param([byte[]]$B)    # bitwise (no table): independent of fs-classify.ps1's table version
    [long]$c = 4294967295
    foreach ($x in $B) {
        $c = $c -bxor [long]$x
        for ($k = 0; $k -lt 8; $k++) { if ($c -band 1) { $c = ($c -shr 1) -bxor 3988292384 } else { $c = $c -shr 1 } }
    }
    ($c -bxor 4294967295) -band 4294967295
}
# FSP1 stream: $Recs = @( @(step, rc, 'k=v k=v'), ... ). seq is the position; eos is appended
# unless -NoEos. -BadCrcAt / -Nonce8Override change one record (negative fixtures).
function New-SynthFsp1 {
    param([string]$Nonce8, [object[]]$Recs, [switch]$NoEos, [int]$BadCrcAt = -1, [int]$NonceAt = -1, [string]$OtherNonce = 'ffffffff')
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Recs) { $all.Add($r) }
    if (-not $NoEos) { $all.Add(@('eos', 0, "records=$($all.Count + 1) dropped=0 overflows=0 out=pipe")) }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $all.Count; $i++) {
        $r = $all[$i]; $n8 = if ($i -eq $NonceAt) { $OtherNonce } else { $Nonce8 }
        $body = "FSP1 nonce=$n8 seq=$i step=$($r[0]) rc=$($r[1])" + $(if ($r[2]) { " $($r[2])" } else { '' })
        $crc = Get-SynthCrc32 (SB $body)
        if ($i -eq $BadCrcAt) { $crc = $crc -bxor 1 }
        [void]$sb.Append("$body len=$($body.Length) crc=$('{0:x8}' -f $crc) END`n")
    }
    $sb.ToString()
}
function Get-Stage3aCommittedRecs {   # a show run that committed and held to its deadline (README "Sequence")
    @(
        @('start', 0, 'mode=show ver=0.4 hold_req=10 hold=10 hold_max=10 clamped=0 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180 t0_ms=9000'),
        @('open', 0, 'dev=/dev/dri/card0'),
        @('version', 0, 'drv=msm_drm'),
        @('caps', 0, 'atomic=1 universal=1'),
        @('resources', 0, 'crtcs=1 connectors=1 encoders=1'),
        @('connector', 0, 'id=32 type=DSI status=connected modes=2'),
        @('chosen_connector', 0, 'id=32'),
        @('chosen_mode', 0, 'w=4128 h=2208 vrefresh=90 from=current'),
        @('planes', 0, 'count=4'),
        @('buffer', 0, 'w=4128 h=2208 pitch=16512'),
        @('plan', 0, 'attempts=2'),
        @('test_commit', 0, 'attempt=0 modeset=0 layout=single'),
        @('commit', 0, 'attempt=0 modeset=0 layout=single commit_ms=17'),
        @('hold_start', 0, 'hold_s=10 start_ms=9100 deadline_ms=19100 alarm_s=15'),
        @('hold_end', 0, 'reason=deadline sig=0 held_ms=10000 late_ms=0 fd_closed=1 close_rc=0 close_ms=40'),
        @('exit', 0, 'code=0 reason=held_to_deadline shown=1 closed_at_exit=0 elapsed_ms=10150')
    )
}
function Get-Stage3aNoDisplayRecs { param([int]$Code, [string]$Reason)
    @(
        @('start', 0, 'mode=show ver=0.4 hold_req=10 hold=10 hold_max=10 clamped=0 setup_alarm_s=30 close_margin_s=5 dev=/dev/dri/card0 out=pipe rot=180 t0_ms=9000'),
        @('open', -2, 'errno=2 dev=/dev/dri/card0 at=stat'),
        @('exit', 0, "code=$Code reason=$Reason shown=0 closed_at_exit=0 elapsed_ms=8")
    )
}
function Get-Stage3aGoodSteps {
    param([string]$Nonce, [string]$Chal, [string]$Stream = $null, [long]$Code = 0)
    if ($null -eq $Stream -or $Stream -eq '') { $Stream = New-SynthFsp1 -Nonce8 $Chal.Substring(0, 8) -Recs (Get-Stage3aCommittedRecs) }
    @(
        (New-SynthStep 1 'hash'    (SB "$($script:SynPatternPin)  /bin/fs-pattern`n")),
        (New-SynthStep 2 'pattern' (SB $Stream) @() @{ code = $Code; ms = [long]10200 })
    )
}

# ---------------------------------------------------------------- captures --
function New-Synth { param([string]$Nonce, [string]$Mangle = 'lf')
    [pscustomobject]@{ Nonce = $Nonce; Mem = (New-Object System.IO.MemoryStream); Idx = (New-Object System.Collections.Generic.List[string]); Ms = [long]100; Mangle = $Mangle }
}
function ConvertTo-Mangled { param([byte[]]$B, [string]$Mangle)
    if ($Mangle -eq 'lf') { return ,$B }
    [byte[]]$rep = [byte[]](13, 13, 10); if ($Mangle -eq 'crlf') { $rep = [byte[]](13, 10) }
    $o = New-Object System.Collections.Generic.List[byte]
    foreach ($x in $B) { if ($x -eq 10) { $o.AddRange($rep) } else { $o.Add($x) } }
    ,$o.ToArray()
}
# device output: optionally mangled (tty newline translation), split into chunks of $Chunk bytes, $Dt ms apart
function Add-Dev { param($S, [byte[]]$B, [int]$Chunk = 0, [int]$Dt = 5, [switch]$Raw)
    if (-not $Raw) { $B = ConvertTo-Mangled $B $S.Mangle }
    if ($B.Length -eq 0) { return }
    $size = if ($Chunk -gt 0) { $Chunk } else { $B.Length }
    for ($p = 0; $p -lt $B.Length; $p += $size) {
        $n = [Math]::Min($size, $B.Length - $p)
        $S.Ms += $Dt
        $S.Idx.Add("R $($S.Mem.Length) $n $($S.Ms)")
        $S.Mem.Write($B, $p, $n)
    }
}
function Add-Host { param($S, [string]$Cmd, [int]$Dt = 20)
    $S.Ms += $Dt
    $S.Idx.Add("W $($S.Mem.Length) $($S.Ms) $Cmd")
}
function Save-Synth { param($S, [string]$Path)
    [IO.File]::WriteAllBytes($Path, $S.Mem.ToArray())
    $txt = "FSIDX1 nonce=$($S.Nonce) mode=synthetic port=-`n" + (($S.Idx | ForEach-Object { "$_`n" }) -join '')
    [IO.File]::WriteAllText("$Path.idx", $txt, (New-Object System.Text.UTF8Encoding($false)))
}
