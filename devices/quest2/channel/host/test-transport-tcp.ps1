# FrameShift Quest 2 - fixtures for host/fs-transport-tcp.ps1 (Windows PowerShell 5.1; offline).
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest2\channel\host\test-transport-tcp.ps1
# The device side runs in WSL (wsl.exe), reached over Windows <-> WSL localhost forwarding:
#   - the simulated PID 1 (common/target/pid1-hold.sh, read only) with fs-rpcd (aarch64, under
#     qemu-aarch64) as its child: tools/host-fixture-wsl.sh sim
#   - a scripted misbehaving device: tools/evil_device.py
# Never touches a device, never runs adb/fastboot, never configures a host adapter.
# Sections: A adapter discovery (injected PnP/NetAdapter data), B commands + D1 source scan,
# C timing, D real flow (IPv4, IPv6 loopback, FSB1 collect), E device refusals seen by the host
# (wrong nonce, replayed challenge), F hostile device + D1 dynamic checks, G capture integrity,
# H send gate. Writes fixtures/host/RESULTS.txt.
[CmdletBinding()] param([string]$Only = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = (Resolve-Path (Join-Path $here '..')).Path
# public copy: the fs-rpcd binary is withheld and busybox is a gitignored build input; without them the
# real-responder sections D/E/G/H are skipped (not failed)
$haveBuild = (Test-Path (Join-Path $root 'build\fs-rpcd')) -and (Test-Path (Join-Path $root '..\..\..\build\third_party\busybox\busybox'))
. (Join-Path $here 'fs-transport-tcp.ps1')
. (Join-Path $root '..\..\quest3\common\host\fsb1.ps1')        # Test-Fsb1Record (read only)
$fx = Join-Path $root 'fixtures\host'
$null = New-Item -ItemType Directory -Force -Path $fx
$work = Join-Path $env:TEMP ('fsq2tcp-' + (New-FsTcpHex 4))
$null = New-Item -ItemType Directory -Path $work
$wslScript = (& wsl.exe -e wslpath -a ((Join-Path $root 'tools\host-fixture-wsl.sh') -replace '\\', '/')).Trim()
$results = New-Object System.Collections.Generic.List[string]
$NONCE = '0123456789abcdef'
function Res([string]$id, [bool]$ok, [string]$detail = '') {
    $l = '{0} {1} {2}' -f $id, $(if ($ok) { 'PASS' } else { 'FAIL' }), (ConvertTo-FsTcpPrintable $detail)
    $results.Add($l); Write-Host $l
}
function Want([string]$s) { return ($Only -eq '' -or $Only.Contains($s)) }
$script:outN = 0
function NewOut { $script:outN++; Join-Path $work ('t{0:d3}' -f $script:outN) }
function Deadlines([int]$ago = 5, [int]$dl = 120, [int]$aw = 100) { Get-FsTcpHostDeadlines -OriginUtc ([DateTime]::UtcNow.AddSeconds(-$ago)) -DeviceDeadlineSec $dl -AckWindowSec $aw -HostMarginSec 15 }
function NewT([string]$addr, [int]$port, [string]$nonce = $NONCE, [int]$quiet = 100, [int]$runner = 0) {
    $t = New-FsTcpTransport -Address $addr -Port $port -Nonce $nonce -OutDir (NewOut) -Mode fixture -PreSendQuietMs $quiet -RunnerLimitSec $runner
    $null = Set-FsTcpDeadlines -Transport $t -Deadlines (Deadlines)
    $t
}
# (PS 5.1: native stderr under EAP Stop becomes a terminating error; these calls tolerate it)
function Wsl([string[]]$a) { $ErrorActionPreference = 'Continue'; $o = & wsl.exe -e @a 2>$null; return $o }
function WslOk([string[]]$a) { $ErrorActionPreference = 'Continue'; $null = & wsl.exe -e @a 2>$null; return ($LASTEXITCODE -eq 0) }
$procs = New-Object System.Collections.Generic.List[object]
function StartWsl([string]$argline) {
    $p = Start-Process -FilePath 'wsl.exe' -ArgumentList "-e bash $wslScript $argline" -WindowStyle Hidden -PassThru
    $procs.Add($p); $p
}
function WaitFor([string[]]$test, [int]$sec = 40) {
    $t = [DateTime]::UtcNow.AddSeconds($sec)
    while ([DateTime]::UtcNow -lt $t) { if (WslOk $test) { return $true }; Start-Sleep -Milliseconds 300 }
    return $false
}

# Reference per-verb loop (how a future collector plugs the transport in): verify -> ack ->
# status (<= 3 tries) -> optional collect -> done. Returns a verdict object; never sends after a stop.
function Invoke-RefFlow($T, [switch]$Collect, [switch]$NoDone, [string]$Exp = 'fixture', [string[]]$Steps = @('uname', 'echo'), [string]$ReadyStage = '') {
    $v = [ordered]@{ Verdict = 'INCONCLUSIVE'; Why = ''; Ack = $null; Record = $null; Chal = $null }
    $c = New-FsTcpHex 16
    $r = Invoke-FsTcpRequest -Transport $T -Verb 'fs-verify' -Arg $c
    if ($r.Framing -ne 'ok') { $v.Why = "verify: $($r.Framing)"; return [pscustomobject]$v }
    $bad = Test-FsTcpVerify -Record $r.Record -Nonce $T.Nonce -Challenge $c -ReadyStage $ReadyStage
    if ($bad) { Confirm-FsTcpRecord -Transport $T -Result $r -Known $false -Why $bad; $v.Why = "verify: $bad"; return [pscustomobject]$v }
    Confirm-FsTcpRecord -Transport $T -Result $r -Known $true -Verified
    $tok = New-FsTcpHex 8; $v.Ack = $tok
    $r = Invoke-FsTcpRequest -Transport $T -Verb 'fs-ack' -Arg $tok
    if ($r.Framing -ne 'ok') { $v.Why = "ack: $($r.Framing)"; return [pscustomobject]$v }
    if ($r.Record.Tag -ne 'FSA1') { Confirm-FsTcpRecord -Transport $T -Result $r -Known $true; $v.Why = "ack refused: $($r.Record.Text)"; return [pscustomobject]$v }
    Confirm-FsTcpRecord -Transport $T -Result $r -Known $true
    $state = 'none'
    for ($i = 0; $i -lt 3 -and $state -eq 'none'; $i++) {
        Start-Sleep -Milliseconds 2500
        $r = Invoke-FsTcpRequest -Transport $T -Verb 'fs-status'
        if ($r.Framing -ne 'ok') { $v.Why = "status: $($r.Framing)"; return [pscustomobject]$v }
        $state = Get-FsTcpAckState -Record $r.Record -Token $tok
        if ($state -eq 'invalid' -or $state -eq 'failed') { Confirm-FsTcpRecord -Transport $T -Result $r -Known $false -Why "$state FSS1"; $v.Why = "$state FSS1"; return [pscustomobject]$v }
        Confirm-FsTcpRecord -Transport $T -Result $r -Known $true
    }
    if ($state -ne 'ours') { $v.Why = "ack state $state" }
    elseif ($Collect) {
        $c2 = New-FsTcpHex 16; $v.Chal = $c2
        $r = Invoke-FsTcpRequest -Transport $T -Verb 'fs-collect' -Arg $c2 -TimeoutMs $T.RunnerTimeoutMs -MinRemainMs $T.RunnerWorstMs
        if ($r.Framing -ne 'ok') { $v.Why = "collect: $($r.Framing)"; return [pscustomobject]$v }
        $v.Record = $r
        # a framed record leaves the device idle (state known) whatever it says; only a VALID
        # FSB1 is a collection. FSR1 (runner refused/failed) or an invalid FSB1: INCONCLUSIVE,
        # then the gated fs-done below (review m10).
        Confirm-FsTcpRecord -Transport $T -Result $r -Known $true
        if ($r.Record.Tag -ne 'FSB1') { $v.Why = "collect refused: $($r.Record.Text)" }
        else {
            $d = Test-Fsb1Record -Bytes $r.Bytes -Exp $Exp -Nonce $T.Nonce -Challenge $c2 -Steps $Steps
            if ($d.Ok) { $v.Verdict = 'COLLECTED' } else { $v.Why = "FSB1 rejected: $($d.Reason)" }
        }
    } else { $v.Verdict = 'ACKED' }
    if (-not $NoDone) {
        $r = Invoke-FsTcpRequest -Transport $T -Verb 'fs-done'
        if ($r.Framing -eq 'ok' -and $r.Record.Text -ceq 'FSD1 queued END') { Confirm-FsTcpRecord -Transport $T -Result $r -Known $true; $v.Why += ' done-queued' }
        else { $v.Why += " done: $($r.Framing)" }
    }
    [pscustomobject]$v
}

try {
# ================================================================ A
if (Want 'A') {
    $par = "USB\VID_1D6B&PID_0104\FS-$NONCE"
    $mi = 'USB\VID_1D6B&PID_0104&MI_00\6&1A2B3C&0&0000'
    $ad = [pscustomobject]@{ IfIndex = 23; Name = 'Ethernet 7'; Description = 'UsbNcm Host Device'; Mac = '06-01-23-45-67-89'; Status = 'Up'; PnpId = $mi }
    $other = [pscustomobject]@{ IfIndex = 5; Name = 'Wi-Fi'; Description = 'Intel Wi-Fi'; Mac = 'AA-BB-CC-DD-EE-FF'; Status = 'Up'; PnpId = 'PCI\VEN_8086&DEV_0001\3&1' }
    $kids = @{ $par = @($mi) }
    $gc = { param($id) if ($kids.ContainsKey($id)) { return $kids[$id] }; @() }.GetNewClosure()
    $ll = { param($i) @('fe80::1c2d:3e4f:5a6b:7c8d%23') }
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par, 'USB\VID_1D6B&PID_0104\FS-fedcba9876543210', 'PCI\X') }.GetNewClosure() -GetChildren $gc -ListAdapters { @($ad, $other) }.GetNewClosure() -GetLinkLocal $ll
    Res A1-adapter-found ($null -eq $g.Refusal -and $g.Adapter.IfIndex -eq 23 -and $g.DeviceAddress -eq 'fe80::0123:4567:89ab:cdef' -and $g.MacMatches) "if=$($g.Adapter.IfIndex) dev=$($g.DeviceAddress) mac=$($g.MacMatches)"
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @('USB\VID_1D6B&PID_0104\FS-fedcba9876543210') } -GetChildren $gc -ListAdapters { @($ad) }.GetNewClosure() -GetLinkLocal $ll
    Res A2-other-nonce-ignored ($null -ne $g.Refusal -and $null -eq $g.Adapter) $g.Refusal
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par) }.GetNewClosure() -GetChildren $gc -ListAdapters { @($other) }.GetNewClosure() -GetLinkLocal $ll
    Res A3-no-adapter-under-parent ($g.Refusal -like 'expected one network adapter*found 0') $g.Refusal
    $ad2 = [pscustomobject]@{ IfIndex = 24; Name = 'Ethernet 8'; Description = 'UsbNcm Host Device #2'; Mac = '06-01-23-45-67-89'; Status = 'Up'; PnpId = 'USB\VID_1D6B&PID_0104&MI_02\6&1A2B3C&0&0002' }
    $kids2 = @{ $par = @($mi, $ad2.PnpId) }
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par) }.GetNewClosure() -GetChildren { param($id) if ($kids2.ContainsKey($id)) { $kids2[$id] } else { @() } }.GetNewClosure() -ListAdapters { @($ad, $ad2) }.GetNewClosure() -GetLinkLocal $ll
    Res A4-two-adapters-refused ($g.Refusal -like '*found 2') $g.Refusal
    $down = $ad.PSObject.Copy(); $down.Status = 'Disconnected'
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par) }.GetNewClosure() -GetChildren $gc -ListAdapters { @($down) }.GetNewClosure() -GetLinkLocal $ll
    Res A5-adapter-down-refused ($g.Refusal -like "*'Disconnected', not Up") $g.Refusal
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par) }.GetNewClosure() -GetChildren $gc -ListAdapters { @($ad) }.GetNewClosure() -GetLinkLocal { param($i) @() }
    Res A6-no-ipv6-linklocal-refused ($g.Refusal -like '*no IPv6 link-local*') $g.Refusal
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par, $par.ToLowerInvariant()) }.GetNewClosure() -GetChildren $gc -ListAdapters { @($ad) }.GetNewClosure() -GetLinkLocal $ll
    Res A7-duplicate-parent-refused ($g.Refusal -like 'two parents*') $g.Refusal
    $wm = $ad.PSObject.Copy(); $wm.Mac = '02-00-00-00-00-01'
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par) }.GetNewClosure() -GetChildren $gc -ListAdapters { @($wm) }.GetNewClosure() -GetLinkLocal $ll
    Res A8-mac-mismatch-is-evidence-only ($null -eq $g.Refusal -and -not $g.MacMatches) "MacMatches=$($g.MacMatches) (recorded, not a refusal; host_addr->adapter MAC is [C])"
    # grandchild (composite parent -> interface -> net adapter) is found (depth <= 3)
    $kids3 = @{ $par = @('X\1'); 'X\1' = @($mi) }
    $g = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par) }.GetNewClosure() -GetChildren { param($id) if ($kids3.ContainsKey($id)) { $kids3[$id] } else { @() } }.GetNewClosure() -ListAdapters { @($ad) }.GetNewClosure() -GetLinkLocal $ll
    Res A9-grandchild-adapter ($null -eq $g.Refusal) ''
    $gOk = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par) }.GetNewClosure() -GetChildren $gc -ListAdapters { @($ad) }.GetNewClosure() -GetLinkLocal $ll
    function LiveRefusal([scriptblock]$mk) { try { $x = & $mk; if ($x) { $null = Close-FsTcpTransport $x }; return '' } catch { return $_.Exception.Message } }
    $m = LiveRefusal { New-FsTcpTransport -Address 'fe80::0123:4567:89ab:cdef' -ScopeId 23 -Port 47101 -Nonce $NONCE -OutDir (NewOut) -Mode live }
    Res A10-live-needs-adapter-object ($m -like '*needs the Find-FsNcmAdapter result*') $m
    $m = LiveRefusal { New-FsTcpTransport -Adapter $gOk -ScopeId 24 -Port 47101 -Nonce $NONCE -OutDir (NewOut) -Mode live -ReadyStage RPC_READY }
    Res A11-live-scope-must-be-adapter-ifindex ($m -like '*ScopeId 24 is not the adapter ifIndex 23*') $m
    $m = LiveRefusal { New-FsTcpTransport -Adapter $gOk -Address 'fe80::1' -Port 47101 -Nonce $NONCE -OutDir (NewOut) -Mode live -ReadyStage RPC_READY }
    Res A12-live-wrong-linklocal-refused ($m -like '*differs from the adapter-derived*') $m
    $gBad = Find-FsNcmAdapter -Nonce $NONCE -ListDevices { @($par) }.GetNewClosure() -GetChildren $gc -ListAdapters { @($ad) }.GetNewClosure() -GetLinkLocal { param($i) @() }
    $m = LiveRefusal { New-FsTcpTransport -Adapter $gBad -Port 47101 -Nonce $NONCE -OutDir (NewOut) -Mode live -ReadyStage RPC_READY }
    Res A14-live-refused-adapter-refused ($m -like '*adapter lookup refused*') $m
    $m = LiveRefusal { New-FsTcpTransport -Adapter $gOk -Port 47101 -Nonce 'fedcba9876543210' -OutDir (NewOut) -Mode live -ReadyStage RPC_READY }
    Res A15-live-adapter-other-nonce ($m -like '*another nonce*') $m
    $m = LiveRefusal { New-FsTcpTransport -Adapter $gOk -Port 47101 -Nonce $NONCE -OutDir (NewOut) -Mode live -MinStartRemainMs 1000 -ReadyStage RPC_READY }
    Res A16-live-start-thresholds-fixed ($m -like '*cannot be lowered*') $m
    # revision 4 (final re-review R1): -ReadyStage is mandatory in live mode
    $m = LiveRefusal { New-FsTcpTransport -Adapter $gOk -Port 47101 -Nonce $NONCE -OutDir (NewOut) -Mode live }
    Res A17-live-needs-ready-stage ($m -like '*live mode needs -ReadyStage*') $m
    $m = LiveRefusal { New-FsTcpTransport -Adapter $gOk -Port 47101 -Nonce $NONCE -OutDir (NewOut) -Mode live -ReadyStage 'rpc ready' }
    Res A18-ready-stage-format ($m -like '*ReadyStage must be*') $m
    $t = New-FsTcpTransport -Adapter $gOk -Port 47101 -Nonce $NONCE -OutDir (NewOut) -Mode live -ReadyStage RPC_READY
    $hdr = (Get-Content -LiteralPath $t.IdxPath -TotalCount 1)
    $null = Close-FsTcpTransport $t
    Res A13-live-address-scope-from-adapter ("$($t.Ip)" -eq 'fe80::123:4567:89ab:cdef%23') "$($t.Ip) | $hdr"
}

# ================================================================ B
if (Want 'B') {
    $cases = @(
        @('fs-verify', ('a' * 32), "fs-verify $NONCE $('a' * 32)"), @('fs-ack', ('b' * 16), "fs-ack $NONCE $('b' * 16)"),
        @('fs-status', '', "fs-status $NONCE"), @('fs-done', '', "fs-done $NONCE"), @('fs-collect', ('c' * 32), "fs-collect $NONCE $('c' * 32)"))
    $ok = $true; foreach ($c in $cases) { if ((New-FsTcpCommand -Verb $c[0] -Nonce $NONCE -Arg $c[1]) -cne $c[2]) { $ok = $false } }
    Res B1-commands-exact $ok ''
    $bad = @(@('fs-reboot', ''), @('FS-STATUS', ''), @('fs-status', 'x'), @('fs-verify', ''), @('fs-verify', ('A' * 32)), @('fs-verify', ('a' * 31)),
             @('fs-verify', (('a' * 32) + "`n")), @('fs-ack', "'bbbbbbbbbbbbbbb"), @('fs-ack', 'bbbbbbbb;reboot'), @('fs-ack', 'bbbbbbbbbbbbbbb$'), @('fs-done', ' '))
    $n = 0; foreach ($c in $bad) { try { $null = New-FsTcpCommand -Verb $c[0] -Nonce $NONCE -Arg $c[1] } catch { $n++ } }
    Res B2-command-refusals ($n -eq $bad.Count) "$n/$($bad.Count) refused"
    $n = 0; foreach ($nn in @('0123456789ABCDEF', '0123', "0123456789abcdef`n", '0123456789abcdeg')) { try { $null = New-FsTcpCommand -Verb 'fs-status' -Nonce $nn } catch { $n++ } }
    Res B3-nonce-refusals ($n -eq 4) "$n/4"
    # ---- D1 static scan of the module source ----
    function Scan-Module([string]$path) {
        $src = Get-Content -LiteralPath $path
        $code = @($src | Where-Object { $_ -notmatch '^\s*#' })
        $w = @($code | Where-Object { $_ -match '\.(Send|SendTo|SendAsync|BeginSend|SendFile|SendPackets|Write|WriteAsync|BeginWrite|WriteByte)\s*\(' })
        $sends = @($w | Where-Object { $_ -match '\.Send\w*\s*\(' })
        $other = @($w | Where-Object { $_ -notmatch '\.Send\w*\s*\(' -and $_ -notmatch '\$(this\.Fs|rf|buf)\.Write\(' })
        $rq = @($code | Where-Object { $_ -match '\$reqBytes\s*=' })
        $cm = @($code | Where-Object { $_ -match '\$cmd\s*=' })
        $net = @($code | Where-Object { $_ -match 'GetStream|NetworkStream|TcpClient|UdpClient|\.SendTo\(' })
        $f = @()
        if ($sends.Count -ne 1 -or $sends[0] -notmatch '^\s*\$sent = \$sock\.Send\(\$reqBytes\)\s*$') { $f += "socket sends: $($sends.Count)" }
        if ($other.Count) { $f += "other write sites: $($other -join ' | ')" }
        if ($rq.Count -ne 1 -or $rq[0] -notmatch '^\s*\$reqBytes = \[System\.Text\.Encoding\]::ASCII\.GetBytes\(\$cmd \+ "`n"\)\s*$') { $f += "reqBytes assignments: $($rq.Count)" }
        if ($cm.Count -ne 1 -or $cm[0] -notmatch '^\s*try \{ \$cmd = New-FsTcpCommand -Verb \$Verb -Nonce \$T\.Nonce -Arg \$Arg \}\s*$') { $f += "cmd assignments: $($cm.Count)" }
        if ($net.Count) { $f += "other network APIs: $($net.Count)" }
        return ,$f
    }
    $mod = Join-Path $here 'fs-transport-tcp.ps1'
    $f = Scan-Module $mod
    Res B4-d1-one-write-site ($f.Count -eq 0) ($f -join '; ')
    # scan sensitivity: each mutation must be caught
    $srcText = [IO.File]::ReadAllText($mod)
    $muts = @(
        @('second-send', '$sent = $sock.Send($reqBytes)', "`$sent = `$sock.Send(`$reqBytes)`n                `$null = `$sock.Send(`$res.Bytes)"),
        @('device-bytes-in-request', '$reqBytes = [System.Text.Encoding]::ASCII.GetBytes($cmd + "`n")', "`$reqBytes = [System.Text.Encoding]::ASCII.GetBytes(`$cmd + `"`n`")`n                `$reqBytes = `$buf.ToArray()"),
        @('cmd-from-arg', 'try { $cmd = New-FsTcpCommand -Verb $Verb -Nonce $T.Nonce -Arg $Arg }', "try { `$cmd = New-FsTcpCommand -Verb `$Verb -Nonce `$T.Nonce -Arg `$Arg }`n    `$cmd = `$Arg"),
        @('stream-write', '$T.Append($piece, $T.NowMs()); $buf.Write($piece, 0, $n)', "`$T.Append(`$piece, `$T.NowMs()); `$buf.Write(`$piece, 0, `$n); `$sock.GetStream().Write(`$piece, 0, `$n)"))
    $caught = 0
    foreach ($m in $muts) {
        if (-not $srcText.Contains($m[1])) { Res "B5-mutation-$($m[0])" $false 'anchor not found'; continue }
        $p = Join-Path $work "mut-$($m[0]).ps1"; [IO.File]::WriteAllText($p, $srcText.Replace($m[1], $m[2]))
        $mf = Scan-Module $p
        if ($mf.Count -gt 0) { $caught++ }
        Res "B5-mutation-$($m[0])-caught" ($mf.Count -gt 0) ($mf -join '; ')
    }
    # B7 (rev 3): the device bounds the runner guard is derived from match fs-rpcd.c's #defines
    $csrc = [IO.File]::ReadAllText((Join-Path $root 'src\fs-rpcd.c'))
    $map = [ordered]@{ ReqMs = 'REQ_MS'; TrailMs = 'TRAIL_MS'; ReapMs = 'REAP_MS'; ReapKillMs = 'REAP_KILL_MS'; SweepMs = 'SWEEP_MS'; WriteMs = 'WRITE_MS'; CollectSMax = 'COLLECT_S_MAX' }
    $bad7 = @()
    foreach ($k in $map.Keys) {
        $m = [regex]::Match($csrc, "(?m)^#define $($map[$k])\s+(\d+)\b")
        if (-not $m.Success -or [long]$m.Groups[1].Value -ne [long]$script:FsTcpDev[$k]) { $bad7 += "$k/$($map[$k])" }
    }
    Res B7-device-bounds-match-fs-rpcd-c ($bad7.Count -eq 0) $(if ($bad7.Count) { 'mismatch: ' + ($bad7 -join ' ') } else { ($map.Keys | ForEach-Object { "$_=$($script:FsTcpDev[$_])" }) -join ' ' })
    $pr = ConvertTo-FsTcpPrintable ("$([char]27)]52;c;$([char]7) \x41 $([char]0x2028)")
    Res B6-printable ($pr -ceq '\x1b]52;c;\x07 \\x41 \u2028') $pr
}

# ================================================================ C
if (Want 'C') {
    $o = [DateTime]::SpecifyKind([DateTime]'2026-10-09T12:00:00', 'Utc')
    $d = Get-FsTcpHostDeadlines -OriginUtc $o -DeviceDeadlineSec 260 -AckWindowSec 150 -HostMarginSec 15
    Res C1-deadline-math ($d.GiveUpUtc -eq $o.AddSeconds(245) -and $d.AckGiveUpUtc -eq $o.AddSeconds(135)) "$($d.GiveUpUtc.ToString('o')) $($d.AckGiveUpUtc.ToString('o'))"
    $ok = $false; try { $null = Get-FsTcpHostDeadlines -OriginUtc ([DateTime]::Now) -DeviceDeadlineSec 260 -AckWindowSec 150 -HostMarginSec 15 } catch { $ok = $true }
    Res C2-local-time-refused $ok ''
    # preparation counts: origin 10 s ago, 1.5 s of "preparation" after the transport exists
    $origin = [DateTime]::UtcNow.AddSeconds(-10)
    $t = New-FsTcpTransport -Address '127.0.0.1' -Port 1 -Nonce $NONCE -OutDir (NewOut) -Mode fixture
    Start-Sleep -Milliseconds 1500
    $tm = Set-FsTcpDeadlines -Transport $t -Deadlines (Get-FsTcpHostDeadlines -OriginUtc $origin -DeviceDeadlineSec 120 -AckWindowSec 100 -HostMarginSec 15)
    $expect = (120 - 15 - 10 - 1.5) * 1000
    Res C3-preparation-shortens-budget ([Math]::Abs($tm.RemainMs - $expect) -lt 400 -and $t.GiveUpMs -eq $tm.ConvertedAtMs + $tm.RemainMs -and $tm.ConvertedAtMs -ge 1500) "remain=$($tm.RemainMs) expect~$expect at_ms=$($tm.ConvertedAtMs)"
    $ok = $false; try { $null = Set-FsTcpDeadlines -Transport $t -Deadlines (Deadlines) } catch { $ok = $_.Exception.Message -like '*already set*' }
    Res C10-second-conversion-refused $ok ''
    $null = Close-FsTcpTransport $t
    function TD([int]$ago, [int]$dl, [int]$aw, [int]$runner = 0) {   # a fresh transport per deadline set (one conversion each)
        $x = New-FsTcpTransport -Address '127.0.0.1' -Port 1 -Nonce $NONCE -OutDir (NewOut) -Mode fixture -RunnerLimitSec $runner
        $null = Set-FsTcpDeadlines -Transport $x -Deadlines (Get-FsTcpHostDeadlines -OriginUtc ([DateTime]::UtcNow.AddSeconds(-$ago)) -DeviceDeadlineSec $dl -AckWindowSec $aw -HostMarginSec 15)
        $x
    }
    $t = New-FsTcpTransport -Address '127.0.0.1' -Port 1 -Nonce $NONCE -OutDir (NewOut) -Mode fixture
    $ok = $false; try { $null = Set-FsTcpDeadlines -Transport $t -Deadlines (Get-FsTcpHostDeadlines -OriginUtc ([DateTime]::UtcNow.AddSeconds(30)) -DeviceDeadlineSec 120 -AckWindowSec 100 -HostMarginSec 15) } catch { $ok = $_.Exception.Message -like '*later than now*' }
    Res C4-future-origin-refused $ok ''
    $null = Close-FsTcpTransport $t
    $t = TD 50 120 100
    $sr = Get-FsTcpStartRefusal -Transport $t; $g = Get-FsTcpSendGate -Transport $t -Verb 'fs-verify'
    Res C5-start-refusal-60s-enforced-by-gate ($sr -like 'start refused: only * s left before the host give-up' -and $g -eq $sr) "refusal=[$sr] gate=[$g]"
    $null = Close-FsTcpTransport $t
    $t = TD 5 260 50
    $sr = Get-FsTcpStartRefusal -Transport $t; $g = Get-FsTcpSendGate -Transport $t -Verb 'fs-verify'
    Res C6-start-refusal-ack-window-enforced-by-gate ($sr -like '*of the ack window left' -and $g -eq $sr) "gate=[$g]"
    $null = Close-FsTcpTransport $t
    # gate mid-session (first request already sent: Started): ack window over, give-up not
    $t = TD 40 120 50 10; $t.Verified = $true; $t.Started = $true
    $gv = Get-FsTcpSendGate -Transport $t -Verb 'fs-status'; $gd = Get-FsTcpSendGate -Transport $t -Verb 'fs-done'; $gc = Get-FsTcpSendGate -Transport $t -Verb 'fs-collect' -MinRemainMs $t.RunnerWorstMs -TimeoutMs $t.RunnerTimeoutMs
    Res C7-ack-window-caps-pre-runner-only ($gv -like 'ack-window*' -and $null -eq $gd -and $null -eq $gc) "status=[$gv] done=[$gd] collect=[$gc]"
    $null = Close-FsTcpTransport $t
    $t = TD 110 120 50; $t.Verified = $true; $t.Started = $true
    $gd = Get-FsTcpSendGate -Transport $t -Verb 'fs-done'
    Res C8-give-up-stops-everything ($gd -like 'host give-up*') $gd
    $null = Close-FsTcpTransport $t
    $t = TD 5 120 100 10; $t.Verified = $true; $t.Started = $true
    $gm = Get-FsTcpSendGate -Transport $t -Verb 'fs-collect' -MinRemainMs 200000 -TimeoutMs $t.RunnerTimeoutMs
    Res C9-runner-guard-min-remaining ($gm -like 'less than 200000 ms*') $gm
    $g0 = Get-FsTcpSendGate -Transport $t -Verb 'fs-collect' -TimeoutMs $t.RunnerTimeoutMs
    Res C11-collect-needs-runner-guard ($g0 -like 'fs-collect needs a runner guard MinRemainMs >= RunnerWorstMs*') $g0
    # revision 3 (re-review m9): the guard is derived from T (10 s here): worst = T + 3.075 + 4 + 2 + 30 + 5 s
    $wantTo = 10000 + 3000 + 75 + 2000 + 2000 + 2000 + 30000; $wantWorst = $wantTo + 5000
    Res C13-runner-worst-derived ($t.RunnerTimeoutMs -eq $wantTo -and $t.RunnerWorstMs -eq $wantWorst) "timeout=$($t.RunnerTimeoutMs) worst=$($t.RunnerWorstMs)"
    $g1 = Get-FsTcpSendGate -Transport $t -Verb 'fs-collect' -MinRemainMs ($t.RunnerWorstMs - 1) -TimeoutMs $t.RunnerTimeoutMs
    Res C14-guard-below-worst-refused ($g1 -like 'fs-collect needs a runner guard*got*') $g1
    $g2 = Get-FsTcpSendGate -Transport $t -Verb 'fs-collect' -MinRemainMs $t.RunnerWorstMs -TimeoutMs (10000 + 4000)
    Res C15-timeout-below-runner-timeout-refused ($g2 -like 'fs-collect needs TimeoutMs >= RunnerTimeoutMs*') $g2
    $g3 = Get-FsTcpSendGate -Transport $t -Verb 'fs-collect' -MinRemainMs $t.RunnerWorstMs -TimeoutMs $t.RunnerTimeoutMs
    Res C16-derived-guard-accepted ($null -eq $g3) "gate=[$g3]"
    $null = Close-FsTcpTransport $t
    $t = TD 5 120 100; $t.Verified = $true; $t.Started = $true
    $g4 = Get-FsTcpSendGate -Transport $t -Verb 'fs-collect' -MinRemainMs 999999 -TimeoutMs 999999
    Res C17-no-runner-limit-no-collect ($g4 -like 'fs-collect refused: this transport has no RunnerLimitSec*') $g4
    $null = Close-FsTcpTransport $t
    $ok = $false; try { $null = New-FsTcpTransport -Address '127.0.0.1' -Port 1 -Nonce $NONCE -OutDir (NewOut) -Mode fixture -RunnerLimitSec 105 } catch { $ok = $_.Exception.Message -like '*RunnerLimitSec must be 0..104*' }
    Res C18-runner-limit-above-cap-104-refused $ok ''
    # an invocation below the guard is never sent (no connection: port 1 would refuse)
    $t = TD 5 120 100 10; $t.Verified = $true; $t.Started = $true
    $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-collect' -Arg (New-FsTcpHex 16) -TimeoutMs 90000 -MinRemainMs 1000
    Res C19-invoke-below-guard-not-sent ($r.End -eq 'gate' -and -not $r.Sent -and $t.State -eq 'stopped') $r.Framing
    $null = Close-FsTcpTransport $t
    # the start refusal holds only until the first request has been sent
    $t = TD 50 120 100; $t.Started = $true
    $g = Get-FsTcpSendGate -Transport $t -Verb 'fs-verify'
    Res C12-start-refusal-only-before-first-send ($null -eq $g) "gate=[$g]"
    $null = Close-FsTcpTransport $t
}

# ================================================================ D / E / G / H (real responder)
if (-not $haveBuild -and ((Want 'D') -or (Want 'E') -or (Want 'G') -or (Want 'H'))) {
    $results.Add('D0-wsl-device-ready SKIP (withheld evidence / build inputs: build/fs-rpcd and the reviewed busybox are not in the public copy; sections D/E/G/H not run)'); Write-Host $results[-1]
} elseif (Want 'D' -or Want 'E' -or Want 'G' -or Want 'H') {
    $tag = 'h' + (New-FsTcpHex 3)
    $null = StartWsl "sim $tag 47851 127.0.0.1 $NONCE 200 180"
    $tag6 = 'h' + (New-FsTcpHex 3)
    $null = StartWsl "sim $tag6 47852 ::1 $NONCE 200 180"
    $tagc = 'h' + (New-FsTcpHex 3)
    $null = StartWsl "sim $tagc 47853 127.0.0.1 $NONCE 200 180 fsb1"
    $tagf = 'h' + (New-FsTcpHex 3)
    $null = StartWsl "sim $tagf 47854 127.0.0.1 $NONCE 200 180 fail"
    $ready = (WaitFor @('grep', '-q', 'listening', "/tmp/fsq2host-$tag/run/fs.rpc.log")) -and (WaitFor @('grep', '-q', 'listening', "/tmp/fsq2host-$tag6/run/fs.rpc.log")) -and (WaitFor @('grep', '-q', 'listening', "/tmp/fsq2host-$tagc/run/fs.rpc.log")) -and (WaitFor @('grep', '-q', 'listening', "/tmp/fsq2host-$tagf/run/fs.rpc.log"))
    Res D0-wsl-device-ready $ready "tags $tag $tag6 $tagc $tagf"
    if ($ready) {
      if (Want 'D' -or Want 'G') {
        $t = NewT '127.0.0.1' 47851
        $v = Invoke-RefFlow $t -ReadyStage 'SHELL_READY'
        Start-Sleep -Milliseconds 2500
        $rec = @(Wsl @('cat', "/tmp/fsq2host-$tag/rec"))
        $first = if ($rec.Count) { ($rec[0] -split ' ')[1] } else { '' }
        Res D1-flow-ipv4-acked-done-reboot ($v.Verdict -eq 'ACKED' -and $v.Why -like '*done-queued*' -and $first -eq 'collected' -and $t.State -eq 'ready') "verdict=$($v.Verdict) why=$($v.Why) device-first-reboot=$first"
        $stages = @(Wsl @('cat', "/tmp/fsq2host-$tag/run/fs.stages"))
        Res D2-pid1-recorded-our-ack (($stages -join ',') -eq 'INIT_STARTED,SHELL_READY,HOST_ACK' -and ((Wsl @('cat', "/tmp/fsq2host-$tag/run/fs.acked")) -join '') -eq $v.Ack) "stages=$($stages -join ',')"
        $sha = Close-FsTcpTransport $t
        # ---- G: capture integrity ----
        $raw = [IO.File]::ReadAllBytes($t.RawPath)
        $ix = Get-Content -LiteralPath $t.IdxPath
        $okh = $ix[0] -cmatch '^FSIDX2 nonce=0123456789abcdef mode=fixture transport=tcp addr=127\.0\.0\.1 port=47851\z'
        $off = 0; $okr = $true; $e = @(); $w = @()
        foreach ($l in $ix | Select-Object -Skip 1) {
            if ($l -cmatch '^R (\d+) (\d+) (\d+)\z') { if ([long]$Matches[1] -ne $off) { $okr = $false }; $off += [long]$Matches[2] }
            elseif ($l -cmatch '^E (\d+) (\d+) (\d+) (\w[\w-]*) (\d+) ([0-9a-f]{64})\z') { $e += , @($Matches[1], $Matches[2], $Matches[4], $Matches[5], $Matches[6]) }
            elseif ($l -cmatch '^W (\d+) (\d+) (fs-[a-z]+ [0-9a-f ]+)\z') { $w += $Matches[3] }
            elseif ($l -cmatch '^(C \d+ \d+ \d+ (ok|fail .*)|N \d+ \d+ [ -~]+)\z') { }
            else { $okr = $false }
        }
        $oke = $true; $start = 0
        foreach ($x in $e) {
            $len = [int]$x[3]; $endOff = [long]$x[1]
            $slice = New-Object byte[] $len; [Array]::Copy($raw, $endOff - $len, $slice, 0, $len)
            $file = Get-ChildItem -LiteralPath (Join-Path $t.OutDir 'responses') -Filter ('{0:d3}-*.raw' -f [int]$x[0])
            if ((Get-FsTcpSha256Hex $slice) -ne $x[4] -or (Get-FsTcpSha256Hex ([IO.File]::ReadAllBytes($file.FullName))) -ne $x[4] -or $x[2] -ne 'eof') { $oke = $false }
        }
        Res G1-index-wellformed ($okh -and $okr -and $off -eq $raw.Length) "R bytes=$off raw=$($raw.Length)"
        Res G2-per-response-sha256 ($oke -and $e.Count -eq $t.Seq) "$($e.Count) responses"
        Res G3-capture-sha256-recheck ($sha -eq (Get-FsTcpSha256Hex $raw)) $sha
        $devlog = @(Wsl @('cat', "/tmp/fsq2host-$tag/run/fs.rpc.log"))
        $okv = ($w.Count -eq $t.Seq)
        Res G4-writes-logged-after-send ($okv -and @($w | Where-Object { $_ -cnotmatch '^[a-z0-9 -]{1,64}\z' }).Count -eq 0) "$($w.Count) W lines; device log: $(@($devlog | Where-Object { $_ -like '*seq=*' }).Count) requests"
        # IPv6 loopback (scope 0) through the same code
        $t6 = NewT '::1' 47852
        $v6 = Invoke-RefFlow $t6 -NoDone -ReadyStage 'SHELL_READY'
        Res D3-flow-ipv6-loopback ($v6.Verdict -eq 'ACKED') "why=$($v6.Why)"
        $null = Close-FsTcpTransport $t6
        # FSB1 over TCP, validated by the existing PowerShell decoder (common/host/fsb1.ps1)
        $tc = NewT '127.0.0.1' 47853 -runner 20
        $vc = Invoke-RefFlow $tc -Collect -ReadyStage 'SHELL_READY'
        $fsb = 'not collected'
        if ($vc.Verdict -eq 'COLLECTED') { $fsb = Test-Fsb1Record -Bytes $vc.Record.Bytes -Exp 'fixture' -Nonce $NONCE -Challenge $vc.Chal -Steps @('uname', 'echo') }
        $fsbOk = ($fsb -isnot [string]) -and $fsb.Ok
        $fsbWhy = if ($fsb -is [string]) { $fsb } else { "$($fsb.Reason) $($fsb.Detail)" }
        $other = 'n/a'
        if ($vc.Verdict -eq 'COLLECTED') { $o2 = Test-Fsb1Record -Bytes $vc.Record.Bytes -Exp 'fixture' -Nonce $NONCE -Challenge (New-FsTcpHex 16) -Steps @('uname', 'echo'); $other = $o2.Reason }
        Res D4-fsb1-collect-valid ($vc.Verdict -eq 'COLLECTED' -and $fsbOk -and $other -eq 'chal-mismatch') "bytes=$(if ($vc.Record) { $vc.Record.Bytes.Length }) decoder=$fsbWhy; other challenge -> $other; flow=$($vc.Why)"
        $null = Close-FsTcpTransport $tc
        # a framed FSR1 instead of FSB1 (the runner failed) is NOT a collection: INCONCLUSIVE, then
        # the gated fs-done (review m10)
        $tf = NewT '127.0.0.1' 47854 -runner 20
        $vf = Invoke-RefFlow $tf -Collect -ReadyStage 'SHELL_READY'
        Start-Sleep -Milliseconds 2500
        $recf = @(Wsl @('cat', "/tmp/fsq2host-$tagf/rec"))
        $firstf = if ($recf.Count) { ($recf[0] -split ' ')[1] } else { '' }
        Res D5-collect-refusal-is-inconclusive-then-done ($vf.Verdict -eq 'INCONCLUSIVE' -and $vf.Why -like '*collect refused: FSR1 nonce=0123456789abcdef error=runner-exit END*done-queued*' -and $firstf -eq 'collected') "verdict=$($vf.Verdict) why=$($vf.Why) device-first-reboot=$firstf"
        $null = Close-FsTcpTransport $tf
      }
      if (Want 'E') {
        # wrong nonce: the transport's nonce is not the device's -> FSR1 nonce=<device> -> framing stop
        $t = NewT '127.0.0.1' 47853 'fedcba9876543210'
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        Res E1-wrong-nonce-stops ($r.Framing -like 'record nonce 0123456789abcdef is not the attempt nonce' -and $t.State -eq 'stopped') $r.Framing
        $r2 = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        Res E2-nothing-after-stop ($r2.End -eq 'gate' -and -not $r2.Sent) $r2.Framing
        $null = Close-FsTcpTransport $t
        # replayed challenge: the host never reuses one; forced here -> FSR1 replay -> not verified
        $t = NewT '127.0.0.1' 47853
        $c = New-FsTcpHex 16
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg $c
        $ok1 = ($r.Framing -eq 'ok' -and $null -eq (Test-FsTcpVerify -Record $r.Record -Nonce $NONCE -Challenge $c))
        Confirm-FsTcpRecord -Transport $t -Result $r -Known $true -Verified
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg $c
        $isRep = ($r.Framing -eq 'ok' -and $r.Record.Tag -eq 'FSR1' -and $r.Record.Fields['error'] -eq 'replay')
        Res E3-replayed-challenge-refused-by-device ($ok1 -and $isRep) "$($r.Record.Text)"
        $vb = Test-FsTcpVerify -Record $r.Record -Nonce $NONCE -Challenge $c
        Confirm-FsTcpRecord -Transport $t -Result $r -Known $false -Why $vb
        Res E4-refusal-not-verified ($vb -like 'not an FSV1*' -and $t.State -eq 'stopped') $vb
        $null = Close-FsTcpTransport $t
        # revision 3 (re-review N1): a failed boot (ERROR_<stage> in stages) is never verified
        $cc = New-FsTcpHex 16; $rr = Get-FsTcpSha256Hex ([Text.Encoding]::ASCII.GetBytes("${NONCE}:$cc"))
        $recE = [pscustomobject]@{ Tag = 'FSV1'; Fields = @{ nonce = $NONCE; resp = $rr; kernel = 'k'; pid1 = '/init'; stages = 'INIT_STARTED,ERROR_rpc' } }
        $e5 = Test-FsTcpVerify -Record $recE -Nonce $NONCE -Challenge $cc
        Res E5-error-stage-refused ($e5 -like 'boot declared failed: stages carry ERROR_rpc') $e5
        $recR = [pscustomobject]@{ Tag = 'FSV1'; Fields = @{ nonce = $NONCE; resp = $rr; kernel = 'k'; pid1 = '/init'; stages = 'INIT_STARTED' } }
        $e6 = Test-FsTcpVerify -Record $recR -Nonce $NONCE -Challenge $cc -ReadyStage 'RPC_READY'
        $e7 = Test-FsTcpVerify -Record $recR -Nonce $NONCE -Challenge $cc
        Res E6-ready-stage-required-when-given ($e6 -eq 'ready stage RPC_READY absent' -and $null -eq $e7) "with=[$e6] without=[$e7]"
        # revision 4 (final re-review R1): fs-rpcd marks a cut field with a trailing '+'
        $recT = [pscustomobject]@{ Tag = 'FSV1'; Fields = @{ nonce = $NONCE; resp = $rr; kernel = 'k'; pid1 = '/init'; stages = 'INIT_STARTED,RPC_READY,S001,S002+' } }
        $e8 = Test-FsTcpVerify -Record $recT -Nonce $NONCE -Challenge $cc -ReadyStage 'RPC_READY'
        Res E7-truncated-stages-refused ($e8 -like 'stages field truncated*') $e8
        $fsF = [pscustomobject]@{ Tag = 'FSS1'; Fields = @{ nonce = $NONCE; stages = 'INIT_STARTED,RPC_READY,ERROR_net'; acked = 'none' } }
        $fsT = [pscustomobject]@{ Tag = 'FSS1'; Fields = @{ nonce = $NONCE; stages = 'INIT_STARTED,RPC_READY,HOST_ACK,S9+'; acked = '0011223344556677' } }
        $fsO = [pscustomobject]@{ Tag = 'FSS1'; Fields = @{ nonce = $NONCE; stages = 'INIT_STARTED,RPC_READY,HOST_ACK'; acked = '0011223344556677' } }
        $a1 = Get-FsTcpAckState -Record $fsF -Token '0011223344556677'; $a2 = Get-FsTcpAckState -Record $fsT -Token '0011223344556677'; $a3 = Get-FsTcpAckState -Record $fsO -Token '0011223344556677'
        Res E8-ackstate-error-and-truncation ($a1 -eq 'failed' -and $a2 -eq 'invalid' -and $a3 -eq 'ours') "error=$a1 truncated=$a2 clean=$a3"
        # rev 5 (N-a): a field cut after nothing but separators arrives as "-+" and is refused too
        $e9 = Get-FsTcpStagesProblem -Stages '-+'
        $e9b = Get-FsTcpStagesProblem -Stages '-'
        Res E9-dash-plus-refused-as-truncated ($e9 -like 'stages field truncated*' -and $null -eq $e9b) "-+ => [$e9]; - => [$e9b]"
      }
      if (Want 'H') {
        $t = NewT '127.0.0.1' 47853
        $before = @(Wsl @('cat', "/tmp/fsq2host-$tagc/run/fs.rpc.log")).Count
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-ack' -Arg (New-FsTcpHex 8)
        Start-Sleep -Milliseconds 300
        $after = @(Wsl @('cat', "/tmp/fsq2host-$tagc/run/fs.rpc.log")).Count
        Res H1-first-verb-must-be-verify ($r.End -eq 'gate' -and -not $r.Sent -and $before -eq $after) "$($r.Framing); device log lines $before -> $after"
        $null = Close-FsTcpTransport $t
        $t = NewT '127.0.0.1' 47853
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        $before = @(Wsl @('cat', "/tmp/fsq2host-$tagc/run/fs.rpc.log")).Count
        $r2 = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        Start-Sleep -Milliseconds 300
        $after = @(Wsl @('cat', "/tmp/fsq2host-$tagc/run/fs.rpc.log")).Count
        Res H2-unconfirmed-record-blocks ($r.Framing -eq 'ok' -and $r2.End -eq 'gate' -and $r2.Framing -like '*not confirmed*' -and $before -eq $after) $r2.Framing
        $null = Close-FsTcpTransport $t
        $t = NewT '127.0.0.1' 47853
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        Confirm-FsTcpRecord -Transport $t -Result ([pscustomobject]@{ Seq = 99 }) -Known $true
        Res H3-confirm-wrong-seq-stops ($t.State -eq 'stopped') $t.StopReason
        $n = 0; foreach ($vb in 'fs-verify', 'fs-status', 'fs-done') { $x = Invoke-FsTcpRequest -Transport $t -Verb $vb -Arg $(if ($vb -eq 'fs-verify') { New-FsTcpHex 16 } else { '' }); if ($x.End -eq 'gate' -and -not $x.Sent) { $n++ } }
        Res H4-stopped-is-final ($n -eq 3) "$n/3 refused"
        $null = Close-FsTcpTransport $t
        $t = New-FsTcpTransport -Address '127.0.0.1' -Port 47853 -Nonce $NONCE -OutDir (NewOut) -Mode fixture
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        Res H5-no-deadlines-no-send ($r.End -eq 'gate' -and $r.Framing -like '*deadlines not set*') $r.Framing
        $null = Close-FsTcpTransport $t
        $t = NewT '127.0.0.1' 47859
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        Res H6-connect-refused-stops ($r.End -eq 'connect-failed' -and -not $r.Sent -and $t.State -eq 'stopped') $r.Framing
        $null = Close-FsTcpTransport $t
        # H7 (review m8): the gate passes before the connection, but the give-up falls inside the
        # 600 ms quiet period: the time gate is re-checked before the write, nothing is sent, RST.
        $t = New-FsTcpTransport -Address '127.0.0.1' -Port 47853 -Nonce $NONCE -OutDir (NewOut) -Mode fixture -PreSendQuietMs 600 -MinStartRemainMs 0 -MinStartAckRemainMs 0
        $null = Set-FsTcpDeadlines -Transport $t -Deadlines (Get-FsTcpHostDeadlines -OriginUtc ([DateTime]::UtcNow.AddMilliseconds(-104700)) -DeviceDeadlineSec 120 -AckWindowSec 120 -HostMarginSec 15)
        $before = @(Wsl @('cat', "/tmp/fsq2host-$tagc/run/fs.rpc.log"))
        $g0 = Get-FsTcpSendGate -Transport $t -Verb 'fs-verify'
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        Start-Sleep -Milliseconds 4000
        $after = @(Wsl @('cat', "/tmp/fsq2host-$tagc/run/fs.rpc.log"))
        $newl = @($after | Select-Object -Skip $before.Count)
        Res H7-time-gate-rechecked-before-write ($null -eq $g0 -and $r.End -eq 'gate-late' -and -not $r.Sent -and $t.State -eq 'stopped' -and $newl.Count -eq 1 -and $newl[0] -match 'verb=- result=(reset|empty|timeout)$') "gate-before=[$g0] end=$($r.End) $($r.Framing); device: $($newl -join ' | ')"
        $null = Close-FsTcpTransport $t
      }
    }
}

# ================================================================ F (hostile device)
if (Want 'F') {
    $etag = 'e' + (New-FsTcpHex 3)
    $base = 47900
    $null = StartWsl "evil $etag $base $NONCE"
    $ready = WaitFor @('test', '-f', "/tmp/fsq2host-$etag/evil/READY")
    Res F0-evil-ready $ready $etag
    if ($ready) {
        $modes = @((Wsl @('cat', "/tmp/fsq2host-$etag/evil/READY")) | ForEach-Object { $p = $_ -split ' '; [pscustomobject]@{ Mode = $p[0]; Port = [int]$p[1] } })
        function P([string]$m) { ($modes | Where-Object { $_.Mode -eq $m }).Port }
        function ELog([string]$m) { @(Wsl @('cat', "/tmp/fsq2host-$etag/evil/$m.log")) }
        function EConn([string]$m) { @(Wsl @('cat', "/tmp/fsq2host-$etag/evil/$m.conn")).Count }
        function One([string]$m, [int]$to = 3000, [string]$verb = 'fs-verify') {
            $t = NewT '127.0.0.1' (P $m)
            $a = if ($verb -eq 'fs-verify') { New-FsTcpHex 16 } else { '' }
            $r = Invoke-FsTcpRequest -Transport $t -Verb $verb -Arg $a -TimeoutMs $to
            $null = Close-FsTcpTransport $t
            [pscustomobject]@{ T = $t; R = $r }
        }
        $x = One 'silent' 2000; Res F1-silent-timeout ($x.R.End -eq 'timeout' -and $x.T.State -eq 'stopped') $x.R.Framing
        $x = One 'partial'; Res F2-partial-record ($x.R.End -eq 'eof' -and $x.R.Framing -eq 'no LF: incomplete record' -and $x.T.State -eq 'stopped') $x.R.Framing
        $x = One 'nolf'; Res F3-no-final-lf ($x.R.Framing -eq 'no LF: incomplete record') $x.R.Framing
        $x = One 'extra'; Res F4-trailing-bytes ($x.R.Framing -like 'more than one line*') $x.R.Framing
        $x = One 'tworec'; Res F5-two-records ($x.R.Framing -like 'more than one line*') $x.R.Framing
        $x = One 'banner'; Start-Sleep -Milliseconds 500
        $bl = ELog 'banner'
        Res F6-unsolicited-bytes-nothing-sent ($x.R.End -eq 'unsolicited' -and -not $x.R.Sent -and @($bl | Where-Object { $_ -ne "b''" }).Count -eq 0) "end=$($x.R.End) device saw: $($bl -join ' ')"
        # through the WSL relay a device RST arrives as a FIN: either way the record is incomplete
        $x = One 'rst'; Res F7-reset-mid-record-via-relay (($x.R.End -eq 'reset' -or $x.R.Framing -eq 'no LF: incomplete record') -and $x.T.State -eq 'stopped') "end=$($x.R.End) bytes=$($x.R.Bytes.Length) framing=$($x.R.Framing)"
        # a true RST: an in-process Windows listener sends 10 bytes, then aborts (linger 0)
        $ps = [powershell]::Create()
        $null = $ps.AddScript({
            $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 47991); $l.Start()
            $c = $l.AcceptSocket(); $b = New-Object byte[] 200; $null = $c.Receive($b)
            $null = $c.Send([System.Text.Encoding]::ASCII.GetBytes('FSV1 nonce')); Start-Sleep -Milliseconds 300
            $c.LingerState = New-Object System.Net.Sockets.LingerOption($true, 0); $c.Close(); $l.Stop() })
        $h = $ps.BeginInvoke(); Start-Sleep -Milliseconds 500
        $t = NewT '127.0.0.1' 47991
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16) -TimeoutMs 3000
        $null = Close-FsTcpTransport $t; $null = $h.AsyncWaitHandle.WaitOne(3000); $ps.Dispose()
        Res F7b-true-reset-mid-record ($r.End -eq 'reset' -and $r.Bytes.Length -eq 10 -and $t.State -eq 'stopped') "end=$($r.End) bytes=$($r.Bytes.Length)"
        $x = One 'huge' 10000; Res F8-oversize-cap ($x.R.End -eq 'cap' -and $x.R.Bytes.Length -le 1024 + 65536) "end=$($x.R.End) bytes=$($x.R.Bytes.Length)"
        $x = One 'esc'; Res F9-escape-bytes-inert ($x.T.State -eq 'stopped' -and $x.T.StopReason -notmatch '[\x00-\x1f\x7f]' -and $x.R.Framing -eq 'not a well-formed single-line record') "$($x.T.StopReason)"
        $x = One 'wrongnonce'; Res F10-record-nonce-mismatch ($x.R.Framing -like 'record nonce ffffffffffffffff is not*') $x.R.Framing
        $x = One 'slowdrip' 2000; Res F11-slow-drip-timeout ($x.R.End -eq 'timeout') "end=$($x.R.End) bytes=$($x.R.Bytes.Length)"
        $x = One 'closenoresp'; Res F12-close-without-record ($x.R.Framing -eq 'empty response') $x.R.Framing
        $x = One 'crlf'; Res F13-crlf ($x.R.Framing -eq 'CR in response') $x.R.Framing
        # replayed old FSV1 (correct nonce, response for another challenge): framed ok, verification fails,
        # the collector does not accept it, and nothing more is ever sent
        $t = NewT '127.0.0.1' (P 'replayfsv1')
        $c = New-FsTcpHex 16
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg $c
        $vb = Test-FsTcpVerify -Record $r.Record -Nonce $NONCE -Challenge $c
        Confirm-FsTcpRecord -Transport $t -Result $r -Known $false -Why $vb
        $r2 = Invoke-FsTcpRequest -Transport $t -Verb 'fs-done'
        Start-Sleep -Milliseconds 300
        Res F14-replayed-fsv1-rejected ($r.Framing -eq 'ok' -and $vb -like 'bad response*' -and $r2.End -eq 'gate' -and (EConn 'replayfsv1') -eq 1) "verify=$vb; connections=$(EConn 'replayfsv1')"
        $null = Close-FsTcpTransport $t
        # foreign / old ack token in FSS1
        $t = NewT '127.0.0.1' (P 'foreignack')
        $v = Invoke-RefFlow $t -NoDone
        Res F15-foreign-ack-detected ($v.Why -eq 'ack state foreign') $v.Why
        $null = Close-FsTcpTransport $t
        # ---- D1 dynamic: framing-valid records full of command text; the device sees ONLY host commands
        $t = NewT '127.0.0.1' (P 'inject')
        $v = Invoke-RefFlow $t -NoDone        # verify ok; ack -> FSS1 (not FSA1) = refusal path; stops sending
        $t2 = NewT '127.0.0.1' (P 'inject')
        $c = New-FsTcpHex 16
        $r = Invoke-FsTcpRequest -Transport $t2 -Verb 'fs-verify' -Arg $c
        Confirm-FsTcpRecord -Transport $t2 -Result $r -Known $true -Verified
        for ($i = 0; $i -lt 3; $i++) { $r = Invoke-FsTcpRequest -Transport $t2 -Verb 'fs-status'; if ($r.Framing -eq 'ok') { Confirm-FsTcpRecord -Transport $t2 -Result $r -Known $true } }
        $r = Invoke-FsTcpRequest -Transport $t2 -Verb 'fs-done'
        $null = Close-FsTcpTransport $t; $null = Close-FsTcpTransport $t2
        Start-Sleep -Milliseconds 500
        $seen = @(ELog 'inject')
        $hostW = @()
        foreach ($tt in @($t, $t2)) { $hostW += @(Get-Content -LiteralPath $tt.IdxPath | Where-Object { $_ -cmatch '^W ' } | ForEach-Object { ($_ -split ' ', 4)[3] }) }
        $want = @($hostW | ForEach-Object { "b'$_\n'" })
        $leak = @($seen | Where-Object { $_ -match 'fs-done_|fs-ack_ffff' })
        Res F16-d1-device-sees-only-host-commands ((($seen -join '|') -ceq ($want -join '|')) -and $leak.Count -eq 0 -and $seen.Count -eq 7) "device saw $($seen.Count) lines; host wrote $($hostW.Count); leaks=$($leak.Count)"
        Res F17-d1-every-request-in-grammar (@($hostW | Where-Object { $_ -cnotmatch '^fs-(verify [0-9a-f]{16} [0-9a-f]{32}|ack [0-9a-f]{16} [0-9a-f]{16}|status [0-9a-f]{16}|done [0-9a-f]{16})\z' }).Count -eq 0) ($hostW -join ' / ')
        $t = NewT '127.0.0.1' (P 'inject2')
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16)
        $r2 = Invoke-FsTcpRequest -Transport $t -Verb 'fs-done'
        $null = Close-FsTcpTransport $t
        Start-Sleep -Milliseconds 300
        Res F18-embedded-command-line-stops ($r.Framing -like 'more than one line*' -and $r2.End -eq 'gate' -and (EConn 'inject2') -eq 1) "framing=$($r.Framing); connections=$(EConn 'inject2')"
        $t = NewT '127.0.0.1' (P 'errorstage')
        $v = Invoke-RefFlow $t
        $null = Close-FsTcpTransport $t
        Start-Sleep -Milliseconds 300
        Res F20-failed-boot-not-acked ($v.Verdict -eq 'INCONCLUSIVE' -and $v.Why -like 'verify: boot declared failed*' -and (EConn 'errorstage') -eq 1 -and $t.State -eq 'stopped') "why=$($v.Why) connections=$(EConn 'errorstage')"
        # F21-F23 (revision 4, R1): a NAIVE caller confirms every record as Known/Verified; the
        # transport itself still stops on ERROR_ in an FSS1, a truncated stages field, or a
        # missing ReadyStage, and sends nothing more
        $t = New-FsTcpTransport -Address '127.0.0.1' -Port (P 'errorstatus') -Nonce $NONCE -OutDir (NewOut) -Mode fixture -ReadyStage RPC_READY
        $null = Set-FsTcpDeadlines -Transport $t -Deadlines (Deadlines)
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16); Confirm-FsTcpRecord -Transport $t -Result $r -Known $true -Verified
        $okV = $t.State -eq 'ready'
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-status'; Confirm-FsTcpRecord -Transport $t -Result $r -Known $true
        $r2 = Invoke-FsTcpRequest -Transport $t -Verb 'fs-done'
        $null = Close-FsTcpTransport $t; Start-Sleep -Milliseconds 300
        Res F21-transport-refuses-error-in-fss1 ($okV -and $t.StopReason -like '*boot declared failed: stages carry ERROR_x*' -and $r2.End -eq 'gate' -and (EConn 'errorstatus') -eq 2) "$($t.StopReason); connections=$(EConn 'errorstatus')"
        $t = New-FsTcpTransport -Address '127.0.0.1' -Port (P 'truncstages') -Nonce $NONCE -OutDir (NewOut) -Mode fixture -ReadyStage RPC_READY
        $null = Set-FsTcpDeadlines -Transport $t -Deadlines (Deadlines)
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16); Confirm-FsTcpRecord -Transport $t -Result $r -Known $true -Verified
        $null = Close-FsTcpTransport $t
        Res F22-transport-refuses-truncated-stages ($t.State -eq 'stopped' -and -not $t.Verified -and $t.StopReason -like '*truncated*') $t.StopReason
        $t = New-FsTcpTransport -Address '127.0.0.1' -Port (P 'good') -Nonce $NONCE -OutDir (NewOut) -Mode fixture -ReadyStage RPC_READY
        $null = Set-FsTcpDeadlines -Transport $t -Deadlines (Deadlines)
        $r = Invoke-FsTcpRequest -Transport $t -Verb 'fs-verify' -Arg (New-FsTcpHex 16); Confirm-FsTcpRecord -Transport $t -Result $r -Known $true -Verified
        $null = Close-FsTcpTransport $t
        Res F23-transport-enforces-ready-stage ($t.State -eq 'stopped' -and -not $t.Verified -and $t.StopReason -like '*ready stage RPC_READY absent*') $t.StopReason
        $t = NewT '127.0.0.1' (P 'good')
        $v = Invoke-RefFlow $t
        Res F19-good-device-control ($v.Verdict -eq 'ACKED' -and $v.Why -like '*done-queued*') "$($v.Verdict) $($v.Why)"
        $null = Close-FsTcpTransport $t
    }
}
} catch {
    Res 'HARNESS' $false ("exception: " + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage)
} finally {
    $ErrorActionPreference = 'Continue'
    foreach ($tg in @(Get-Variable -Name tag, tag6, tagc, tagf, etag -ErrorAction SilentlyContinue)) { if ($tg.Value) { $null = & wsl.exe -e bash $wslScript stop $tg.Value 2>$null } }
    foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
}
$np = @($results | Where-Object { $_ -match ' PASS ' -or $_ -match ' PASS$' }).Count
$ns = @($results | Where-Object { $_ -match ' SKIP ' }).Count
$nrun = $results.Count - $ns
$hdr = @("fs-transport-tcp.ps1 sha256=$(Get-FsTcpSha256Hex ([IO.File]::ReadAllBytes((Join-Path $here 'fs-transport-tcp.ps1'))))",
         $(if ($haveBuild) { "fs-rpcd sha256=$(Get-FsTcpSha256Hex ([IO.File]::ReadAllBytes((Join-Path $root 'build\fs-rpcd'))))" } else { 'fs-rpcd absent (withheld from the public copy)' }),
         "powershell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString); device side in WSL (qemu-aarch64) over localhost")
$tline = if ($ns) { "TOTAL $np/$nrun PASS, $ns SKIP" } else { "TOTAL $np/$($results.Count) PASS" }
if ($Only -eq '') { [IO.File]::WriteAllLines((Join-Path $fx 'RESULTS.txt'), [string[]]($hdr + $results + $tline)) }
Write-Host $tline
if ($np -eq $nrun) { exit 0 } else { exit 1 }
