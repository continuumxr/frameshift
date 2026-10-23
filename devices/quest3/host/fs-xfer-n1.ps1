# FrameShift N1 - the PC side of the NCM link (Windows PowerShell 5.1, no modules; a library: dot-source it).
# NO DEVICE COMMAND: it never runs adb, fastboot or a COM port. It reads the PnP and network-adapter tables (read
# only), and - live, during an observed N1 attempt only - makes ONE outbound TCP session to the image's transfer-test
# responder, [fe80::<nonce>%<ifIndex>]:47201 (devices/quest3/n1/src/fs-xfer.c). It opens no listener, changes no
# adapter, driver, firewall or network setting and installs nothing.
#
#   Get-FsN1Ids <nonce>                 the device MAC (02:...), the PC adapter's expected MAC (06-...), fe80::<nonce>
#   Find-FsN1Adapter -Nonce <nonce>     the network adapter that descends from USB\VID_1D6B&PID_0104\FS-<nonce> (adapted
#                                       from devices/quest2/channel/host/fs-transport-tcp.ps1 Find-FsNcmAdapter, plus the
#                                       bound driver: service, INF, version), with every lookup injectable for fixtures
#   Get-FsN1D2hExpectedSha <nonce> <chal>   SHA-256 of the device's deterministic 8 MiB stream (C#, Add-Type)
#   Invoke-FsN1Xfer ...                 the FSX1 client: connect (retrying refused connects until the window ends),
#                                       header, 8 MiB up, 8 MiB + trailer down, every check; returns the xfer.json object
#   Invoke-FsN1XferSession ...          the live session for the collector: waits (bounded) for the adapter, records its
#                                       timeline, then Invoke-FsN1Xfer; returns the xfer.json object (and writes
#                                       <OutDir>\xfer.json only when -OutDir is given: the offline tests)
#   Start-FsN1XferJob / Wait-FsN1XferJob    the same in a background runspace (the collector's ACM engine runs meanwhile);
#                                       N1 r3: the runspace writes NO file and needs no directory; the collector writes
#                                       its result after the engine (which alone creates the output directory)
#
# The FSX1 protocol (normative text: devices/quest3/n1/README.md s.4; fs-xfer.c's header):
#   PC -> device: "FSX1 <nonce> <chal> 8388608 8388608\n", then 8388608 random bytes;
#   device -> PC: 8388608 bytes, block i = SHA-256("FSX1-D2H" || nonce || chal || uint64_be(i)), then
#                 "FSX1 END <nonce> <chal> rx=<n> rx_sha256=<hex> tx=<n> tx_sha256=<hex>\n"; the device half-closes.
# The PC closes after the trailer (no half-close: devices/quest2/channel/README.md s.4 "No half-close").
# xfer.json (schema frameshift.fs-xfer-host.v1) is the same as devices/quest3/n1/tools/xfer-client.py's, the reference
# client of the QEMU fixtures; fs-classify-n1.ps1 reads either. FS-R-011 s.4 carries over: a failed Send may have
# transmitted a prefix ("possibly partially sent"), and transport success is never record integrity (the classifier
# also needs the device's own FSB1 record of the transfer).
Set-StrictMode -Version 2.0

$script:FsN1XferSchema = 'frameshift.fs-xfer-host.v1'
$script:FsN1XferPort = 47201
$script:FsN1H2d = 8388608
$script:FsN1D2h = 8388608

if (-not ('FsN1Stream' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Security.Cryptography;
using System.Text;
public static class FsN1Stream {
    // SHA-256 over the device -> PC stream: block i = SHA-256("FSX1-D2H" || nonce || chal || uint64_be(i)), 32 bytes each
    public static string ExpectedD2hSha(string nonce, string chal, int bytes) {
        byte[] pre = Encoding.ASCII.GetBytes("FSX1-D2H" + nonce + chal);
        byte[] m = new byte[pre.Length + 8];
        Buffer.BlockCopy(pre, 0, m, 0, pre.Length);
        using (SHA256 inner = SHA256.Create())
        using (SHA256 outer = SHA256.Create()) {
            byte[] chunk = new byte[65536];
            int fill = 0;
            for (long i = 0; i < bytes / 32; i++) {
                for (int k = 0; k < 8; k++) m[pre.Length + k] = (byte)(i >> (56 - 8 * k));
                byte[] b = inner.ComputeHash(m);
                Buffer.BlockCopy(b, 0, chunk, fill, 32);
                fill += 32;
                if (fill == chunk.Length) { outer.TransformBlock(chunk, 0, fill, null, 0); fill = 0; }
            }
            outer.TransformFinalBlock(chunk, 0, fill);
            return Hex(outer.Hash);
        }
    }
    // the stream itself (fixtures: the PowerShell device emulator of the N1 host suite (private))
    public static byte[] D2hStream(string nonce, string chal, int bytes) {
        byte[] pre = Encoding.ASCII.GetBytes("FSX1-D2H" + nonce + chal);
        byte[] m = new byte[pre.Length + 8];
        Buffer.BlockCopy(pre, 0, m, 0, pre.Length);
        byte[] o = new byte[bytes];
        using (SHA256 inner = SHA256.Create()) {
            for (long i = 0; i < bytes / 32; i++) {
                for (int k = 0; k < 8; k++) m[pre.Length + k] = (byte)(i >> (56 - 8 * k));
                Buffer.BlockCopy(inner.ComputeHash(m), 0, o, (int)(i * 32), 32);
            }
        }
        return o;
    }
    public static string Hex(byte[] b) { StringBuilder s = new StringBuilder(b.Length * 2); foreach (byte x in b) s.Append(x.ToString("x2")); return s.ToString(); }
    public static string Sha(byte[] b, int off, int len) { using (SHA256 h = SHA256.Create()) return Hex(h.ComputeHash(b, off, len)); }
}
'@
}

function Test-FsN1Hex([string]$S, [int]$Len) { $S -cmatch ('^[0-9a-f]{' + $Len + '}\z') }
function Get-FsN1Ids([string]$Nonce) {
    if (-not (Test-FsN1Hex $Nonce 16)) { throw 'refused: nonce must be 16 lowercase hex' }
    $b = @(0, 2, 4, 6, 8 | ForEach-Object { $Nonce.Substring($_, 2) })
    [pscustomobject]@{ DevMac = '02:' + ($b -join ':'); HostMac = ('06-' + ($b -join '-')).ToUpperInvariant()
                       LinkLocal = 'fe80::{0}:{1}:{2}:{3}' -f $Nonce.Substring(0, 4), $Nonce.Substring(4, 4), $Nonce.Substring(8, 4), $Nonce.Substring(12, 4)
                       Serial = "FS-$Nonce"; Port = $script:FsN1XferPort }
}
function Get-FsN1D2hExpectedSha([string]$Nonce, [string]$Chal) { [FsN1Stream]::ExpectedD2hSha($Nonce, $Chal, $script:FsN1D2h) }
function ConvertTo-FsN1Printable([string]$S) {
    if ($null -eq $S) { return '' }
    $b = New-Object System.Text.StringBuilder
    foreach ($ch in $S.ToCharArray()) { if ([int]$ch -ge 0x20 -and [int]$ch -le 0x7e) { [void]$b.Append($ch) } else { [void]$b.AppendFormat('\x{0:x2}', [int]$ch) } }
    $b.ToString()
}
function Get-FsN1UtcText { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture) }

# The adapter of THIS attempt: the PnP parent USB\VID_1D6B&PID_0104\FS-<nonce> (exactly one), its descendants (depth <= 3),
# exactly one network adapter among them, its driver (service, INF, version), its status and its IPv6 link-local
# addresses. Refusal is set (and the lookup stops) at the first thing that is not so. Read only.
function Find-FsN1Adapter {
    param([Parameter(Mandatory)][string]$Nonce,
          [scriptblock]$ListDevices = { Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object InstanceId },
          [scriptblock]$GetChildren = { param($id)
              $p = $null
              try { $p = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Children' -ErrorAction Stop } catch { return @() }
              if ($p -and ($p.PSObject.Properties.Name -contains 'Data') -and $p.Data) { return @($p.Data) }
              return @() },
          [scriptblock]$ListAdapters = { @(Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
              [pscustomobject]@{ IfIndex = [int]$_.ifIndex; Name = [string]$_.Name; Description = [string]$_.InterfaceDescription
                                 Mac = [string]$_.MacAddress; Status = [string]$_.Status; PnpId = [string]$_.PnPDeviceID } }) },
          [scriptblock]$GetDriver = { param($id)
              $r = [ordered]@{ Service = $null; InfPath = $null; DriverVersion = $null; DriverProvider = $null }
              foreach ($k in @(@('Service', 'DEVPKEY_Device_Service'), @('InfPath', 'DEVPKEY_Device_DriverInfPath'), @('DriverVersion', 'DEVPKEY_Device_DriverVersion'), @('DriverProvider', 'DEVPKEY_Device_DriverProvider'))) {
                  try { $p = Get-PnpDeviceProperty -InstanceId $id -KeyName $k[1] -ErrorAction Stop; if ($p -and $p.PSObject.Properties['Data']) { $r[$k[0]] = [string]$p.Data } } catch { }
              }
              [pscustomobject]$r },
          [scriptblock]$GetLinkLocal = { param($ifIndex)
              @(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like 'fe80:*' } | ForEach-Object { [string]$_.IPAddress + ' ' + [string]$_.AddressState }) })
    $ids = Get-FsN1Ids $Nonce
    $want = $ids.Serial
    $r = [ordered]@{ Nonce = $Nonce; Utc = (Get-FsN1UtcText); Parent = $null; Serials = @(); Adapter = $null; Driver = $null; HostLinkLocal = @()
                     MacExpected = $ids.HostMac; MacMatches = $false; DeviceAddress = $ids.LinkLocal; Refusal = $null }
    $parents = @(@(& $ListDevices) | Where-Object { $_ -match '^USB\\VID_1D6B&PID_0104\\[^\\]+$' })
    foreach ($p in $parents) {
        $serial = ($p -split '\\')[-1]
        $r.Serials += $serial
        if ($serial -ieq $want) { if ($r.Parent) { $r.Refusal = "two parents carry $want"; return [pscustomobject]$r }; $r.Parent = $p }
    }
    if (-not $r.Parent) { $r.Refusal = "no USB\VID_1D6B&PID_0104\$want device present"; return [pscustomobject]$r }
    $desc = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $frontier = @($r.Parent)
    for ($depth = 0; $depth -lt 3 -and $frontier.Count; $depth++) {
        $next = @()
        foreach ($id in $frontier) { foreach ($ch in @(& $GetChildren $id)) { if ($ch -and $desc.Add([string]$ch)) { $next += [string]$ch } } }
        $frontier = $next
    }
    $mine = @(@(& $ListAdapters) | Where-Object { $_.PnpId -and $desc.Contains($_.PnpId) })
    if ($mine.Count -ne 1) { $r.Refusal = "expected one network adapter under $want, found $($mine.Count)"; return [pscustomobject]$r }
    $a = $mine[0]
    $r.Adapter = $a
    $r.Driver = & $GetDriver $a.PnpId
    $r.MacMatches = (([string]$a.Mac).ToUpperInvariant() -eq $r.MacExpected)
    if ($a.Status -ne 'Up') { $r.Refusal = "adapter ifIndex $($a.IfIndex) is '$(ConvertTo-FsN1Printable $a.Status)', not Up"; return [pscustomobject]$r }
    $r.HostLinkLocal = @(& $GetLinkLocal $a.IfIndex)
    if (@($r.HostLinkLocal | Where-Object { $_ -match ' Preferred$' }).Count -lt 1) { $r.Refusal = "adapter ifIndex $($a.IfIndex) has no preferred IPv6 link-local address yet ($(@($r.HostLinkLocal) -join ', '))"; return [pscustomobject]$r }
    [pscustomobject]$r
}

# The FSX1 client. -Address/-ScopeId: the device's fe80::<nonce> and the adapter's ifIndex (live), or ::1/0 (fixtures).
# -Mode: ok (the protocol) or, for negative fixtures only, bad-header | short. -WindowMs: connects are retried (refused or
# timed out: nothing listens yet) until that many ms after the call. Returns the xfer.json object (never throws for a
# session outcome; Result says what happened).
function Invoke-FsN1Xfer {
    param([Parameter(Mandatory)][string]$Nonce, [Parameter(Mandatory)][string]$Chal, [Parameter(Mandatory)][string]$Address, [int]$ScopeId = 0,
          [int]$Port = 47201, [long]$WindowMs = 60000, [int]$ConnectTimeoutMs = 2500, [int]$RetryMs = 250, [int]$IoTimeoutMs = 20000,
          [ValidateSet('ok', 'bad-header', 'short')][string]$Mode = 'ok', [string]$Client = 'devices/quest3/host/fs-xfer-n1.ps1', [bool]$Fixture = $false,
          $Adapter = $null, [string]$ExpectedD2hSha = '', $Sync = $null, $DeadlineUtc = $null)
    if (-not (Test-FsN1Hex $Nonce 16) -or -not (Test-FsN1Hex $Chal 32)) { throw 'refused: nonce 16 hex, challenge 32 hex' }
    if (-not $Fixture -and ($Mode -cne 'ok' -or $Address -cne (Get-FsN1Ids $Nonce).LinkLocal -or $ScopeId -le 0 -or $Port -ne $script:FsN1XferPort)) {
        throw 'refused: a live session goes to fe80::<nonce> on the adapter ifIndex, port 47201, mode ok'
    }
    $ip = [Net.IPAddress]::Parse($Address); if ($ScopeId -gt 0) { $ip.ScopeId = $ScopeId }
    $ep = New-Object Net.IPEndPoint($ip, $Port)
    $expD = if ($ExpectedD2hSha) { $ExpectedD2hSha } else { Get-FsN1D2hExpectedSha $Nonce $Chal }
    $r = [ordered]@{ Schema = $script:FsN1XferSchema; Client = $Client; Fixture = $Fixture; Mode = $Mode; Nonce = $Nonce; Challenge = $Chal; Port = $Port
                     Address = $Address; ScopeId = $ScopeId; StartUtc = (Get-FsN1UtcText); EndUtc = $null; Adapter = $Adapter
                     ConnectAttempts = 0; ConnectRefused = 0; ConnectedAfterMs = $null; Result = $null
                     H2d = [ordered]@{ Bytes = 0; Sha256 = $null; Ms = $null }
                     D2h = [ordered]@{ Bytes = 0; Sha256 = $null; ExpectedSha256 = $expD; Ms = $null }
                     Trailer = $null; TrailerFields = $null; Checks = $null; Notes = @() }
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    [byte[]]$blob = New-Object byte[] $script:FsN1H2d; $rng.GetBytes($blob); $rng.Dispose()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $s = $null
    while ($sw.ElapsedMilliseconds -lt $WindowMs) {
        if ($null -ne $Sync -and $Sync.Stop) { $r.Notes += 'stopped by the collector before a connection'; break }
        $r.ConnectAttempts++
        $c = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetworkV6, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
        try {
            $ar = $c.BeginConnect($ep, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne($ConnectTimeoutMs)) { $c.EndConnect($ar); $s = $c; break }
            $c.Close()
        } catch [Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::ConnectionRefused) { $r.ConnectRefused++ }
            $c.Close()
        } catch { $c.Close() }
        Start-Sleep -Milliseconds $RetryMs
    }
    if ($null -eq $s) { $r.Result = 'connect-timeout'; $r.EndUtc = Get-FsN1UtcText; return [pscustomobject]$r }
    $r.ConnectedAfterMs = $sw.ElapsedMilliseconds
    # review m1: once connected the session is bounded by an absolute deadline too (the window end), not only per call
    $dlU = if ($null -ne $DeadlineUtc) { [DateTime]$DeadlineUtc } else { [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $WindowMs - $sw.ElapsedMilliseconds) + $IoTimeoutMs) }
    $left = { [int][Math]::Max(1, [Math]::Min($IoTimeoutMs, ($dlU - [DateTime]::UtcNow).TotalMilliseconds)) }
    $over = { [DateTime]::UtcNow -ge $dlU }
    $s.ReceiveTimeout = (& $left); $s.SendTimeout = (& $left); $s.NoDelay = $true
    try {
        $hc = if ($Mode -ceq 'bad-header') { if ($Chal -cne ('0' * 32)) { '0' * 32 } else { '1' * 32 } } else { $Chal }
        [byte[]]$hdr = [Text.Encoding]::ASCII.GetBytes("FSX1 $Nonce $hc $($script:FsN1H2d) $($script:FsN1D2h)`n")
        $n = if ($Mode -ceq 'short') { [int]($script:FsN1H2d / 2) } elseif ($Mode -ceq 'bad-header') { 0 } else { $script:FsN1H2d }
        $t = [Diagnostics.Stopwatch]::StartNew()
        $sent = 0
        try {
            $off = 0; while ($off -lt $hdr.Length) { $off += $s.Send($hdr, $off, $hdr.Length - $off, [Net.Sockets.SocketFlags]::None) }
            while ($sent -lt $n) {
                if (& $over) { throw 'the session deadline passed' }
                $s.SendTimeout = (& $left)
                $sent += $s.Send($blob, $sent, [Math]::Min(65536, $n - $sent), [Net.Sockets.SocketFlags]::None)
            }
        } catch {
            $r.Result = 'send-error'; $r.Notes += "send: $(ConvertTo-FsN1Printable $_.Exception.Message) after $sent bytes (possibly partially sent; FS-R-011 s.4)"
        }
        $r.H2d.Bytes = $sent; $r.H2d.Sha256 = [FsN1Stream]::Sha($blob, 0, $sent); $r.H2d.Ms = $t.ElapsedMilliseconds
        if ($Mode -cne 'ok' -and -not $r.Result) { $r.Result = "closed-early (fixture mode $Mode)" }
        if (-not $r.Result) {
            $ms = New-Object IO.MemoryStream
            [byte[]]$buf = New-Object byte[] 65536
            $t2 = [Diagnostics.Stopwatch]::StartNew()
            try {
                while ($true) {
                    if (& $over) { $r.Notes += 'the session deadline passed while receiving'; break }
                    $s.ReceiveTimeout = (& $left)
                    $k = $s.Receive($buf, 0, $buf.Length, [Net.Sockets.SocketFlags]::None)
                    if ($k -le 0) { break }
                    $ms.Write($buf, 0, $k)
                    if ($ms.Length -gt $script:FsN1D2h) {
                        $tail = $ms.ToArray()
                        if ([Array]::IndexOf($tail, [byte]10, $script:FsN1D2h) -ge 0 -or $ms.Length -gt $script:FsN1D2h + 512) { break }
                    }
                }
            } catch { $r.Notes += "receive: $(ConvertTo-FsN1Printable $_.Exception.Message) after $($ms.Length) bytes" }
            [byte[]]$got = $ms.ToArray()
            $dn = [Math]::Min($got.Length, $script:FsN1D2h)
            $r.D2h.Bytes = $dn; $r.D2h.Sha256 = [FsN1Stream]::Sha($got, 0, $dn); $r.D2h.Ms = $t2.ElapsedMilliseconds
            $rest = if ($got.Length -gt $script:FsN1D2h) { [Text.Encoding]::GetEncoding(28591).GetString($got, $script:FsN1D2h, $got.Length - $script:FsN1D2h) } else { '' }
            $nl = $rest.IndexOf("`n")
            if ($nl -ge 0) {
                $line = $rest.Substring(0, $nl)
                $r.Trailer = ConvertTo-FsN1Printable $line
                $f = $line.Split(' ')
                $kv = [ordered]@{}
                foreach ($x in @($f | Select-Object -Skip 4)) { $i = $x.IndexOf('='); if ($i -gt 0) { $kv[$x.Substring(0, $i)] = $x.Substring($i + 1) } }
                if ($f.Count -eq 8 -and $f[0] -ceq 'FSX1' -and $f[1] -ceq 'END' -and (@($kv.Keys) -join ',') -ceq 'rx,rx_sha256,tx,tx_sha256') {
                    $r.TrailerFields = $kv
                    $r.Checks = [ordered]@{ TrailerNonceChal = ($f[2] -ceq $Nonce -and $f[3] -ceq $Chal)
                                            DeviceRxMatchesSent = ($kv.rx -ceq [string]$script:FsN1H2d -and $kv.rx_sha256 -ceq $r.H2d.Sha256 -and $r.H2d.Bytes -eq $script:FsN1H2d)
                                            DeviceTxMatchesReceived = ($kv.tx -ceq [string]$script:FsN1D2h -and $kv.tx_sha256 -ceq $r.D2h.Sha256 -and $dn -eq $script:FsN1D2h)
                                            ReceivedIsExpected = ($r.D2h.Sha256 -ceq $expD)
                                            NothingAfterTrailer = ($rest.Length -eq $nl + 1) }
                }
            }
            if ($dn -lt $script:FsN1D2h) { $r.Result = 'recv-short' }
            elseif ($null -eq $r.TrailerFields) { $r.Result = 'bad-trailer' }
            elseif (@($r.Checks.Values | Where-Object { -not $_ }).Count -eq 0) { $r.Result = 'ok' }
            else { $r.Result = 'mismatch' }
        }
    } finally { try { $s.Close() } catch { } }
    $r.EndUtc = Get-FsN1UtcText
    [pscustomobject]$r
}

function Save-FsN1XferJson($X, [string]$Path) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, ((($X | ConvertTo-Json -Depth 8) -replace "`r`n", "`n") + "`n"), $enc)
}

# The live session (the collector runs it in a background runspace, Start-FsN1XferJob): BOUNDED ENUMERATION - the
# adapter of THIS attempt is looked up once a second until it is Up with a preferred link-local address, or until
# AdapterWaitSec have passed, or until WindowEndUtc, or until $Sync.Stop; every change is recorded (the timeline). Then
# the FSX1 session until WindowEndUtc. Returns the object (and writes <OutDir>\xfer.json when -OutDir is given).
function Invoke-FsN1XferSession {
    param([Parameter(Mandatory)][string]$Nonce, [Parameter(Mandatory)][string]$Chal, [string]$OutDir = '',
          [Parameter(Mandatory)][DateTime]$WindowEndUtc, [int]$AdapterWaitSec = 60, $Sync = $null, [scriptblock]$Find = $null)
    $ids = Get-FsN1Ids $Nonce
    $tl = New-Object System.Collections.Generic.List[object]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $found = $null; $last = ''; $a = $null
    $expD = Get-FsN1D2hExpectedSha $Nonce $Chal        # computed before the device listens (it takes about a second)
    while ($true) {
        if ($null -ne $Sync -and $Sync.Stop) { break }
        $a = if ($null -ne $Find) { & $Find $Nonce } else { Find-FsN1Adapter -Nonce $Nonce }
        $st = if ($a.Refusal) { [string]$a.Refusal } else { 'ready' }
        if ($st -cne $last) { $tl.Add([ordered]@{ Ms = $sw.ElapsedMilliseconds; Utc = (Get-FsN1UtcText); State = (ConvertTo-FsN1Printable $st) }); $last = $st }
        if (-not $a.Refusal) { $found = $a; break }
        if ($sw.Elapsed.TotalSeconds -ge $AdapterWaitSec -or [DateTime]::UtcNow -ge $WindowEndUtc) { break }
        Start-Sleep -Milliseconds 1000
    }
    $snap = $null
    if ($null -ne $a) { $snap = [ordered]@{ Parent = $a.Parent; Serials = @($a.Serials); Adapter = $a.Adapter; Driver = $a.Driver; HostLinkLocal = @($a.HostLinkLocal); MacExpected = $a.MacExpected; MacMatches = $a.MacMatches; Refusal = $a.Refusal } }
    if ($null -eq $found) {
        $x = [ordered]@{ Schema = $script:FsN1XferSchema; Client = 'devices/quest3/host/fs-xfer-n1.ps1'; Fixture = $false; Mode = 'ok'; Nonce = $Nonce; Challenge = $Chal
                         Port = $script:FsN1XferPort; Address = $ids.LinkLocal; ScopeId = 0; StartUtc = (Get-FsN1UtcText); EndUtc = (Get-FsN1UtcText); Adapter = $snap
                         ConnectAttempts = 0; ConnectRefused = 0; ConnectedAfterMs = $null
                         Result = $(if ($null -ne $Sync -and $Sync.Stop) { 'stopped' } else { 'no-adapter' })
                         H2d = [ordered]@{ Bytes = 0; Sha256 = $null; Ms = $null }; D2h = [ordered]@{ Bytes = 0; Sha256 = $null; ExpectedSha256 = $expD; Ms = $null }
                         Trailer = $null; TrailerFields = $null; Checks = $null
                         Notes = @($(if ($null -ne $Sync -and $Sync.Stop) { "stopped by the collector after $([int]$sw.Elapsed.TotalSeconds) s with no ready adapter: $last" } else { "no ready adapter within $AdapterWaitSec s (bounded enumeration): $last" })) }
        $x = [pscustomobject]$x
    } else {
        $win = [long][Math]::Max(0, ($WindowEndUtc - [DateTime]::UtcNow).TotalMilliseconds)
        $x = Invoke-FsN1Xfer -Nonce $Nonce -Chal $Chal -Address $ids.LinkLocal -ScopeId ([int]$found.Adapter.IfIndex) -WindowMs $win -Adapter $snap -ExpectedD2hSha $expD -Sync $Sync -DeadlineUtc $WindowEndUtc
    }
    $x | Add-Member NoteProperty AdapterTimeline $tl.ToArray()
    $x | Add-Member NoteProperty AdapterWaitSec $AdapterWaitSec
    if ($OutDir) { Save-FsN1XferJson $x (Join-Path $OutDir 'xfer.json') }
    $x
}

# Background runspace: the library is loaded there from THIS file (the pinned copy beside the collector). N1 r3: it
# writes no file (the result object comes back through Wait-FsN1XferJob).
function Start-FsN1XferJob {
    param([Parameter(Mandatory)][string]$Nonce, [Parameter(Mandatory)][string]$Chal,
          [Parameter(Mandatory)][DateTime]$WindowEndUtc, [int]$AdapterWaitSec = 60)
    $sync = [hashtable]::Synchronized(@{ Stop = $false })
    $ps = [PowerShell]::Create()
    $lib = Join-Path $PSScriptRoot 'fs-xfer-n1.ps1'
    $null = $ps.AddScript({ param($Lib, $Nonce, $Chal, $WindowEndUtc, $AdapterWaitSec, $Sync)
        . $Lib
        Invoke-FsN1XferSession -Nonce $Nonce -Chal $Chal -WindowEndUtc $WindowEndUtc -AdapterWaitSec $AdapterWaitSec -Sync $Sync
    }).AddArgument($lib).AddArgument($Nonce).AddArgument($Chal).AddArgument($WindowEndUtc).AddArgument($AdapterWaitSec).AddArgument($sync)
    [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke(); Sync = $sync }
}
# Waits at most TimeoutMs (bounded); a session still running then is told to stop and abandoned. Returns the xfer.json
# object, or $null (then the collector writes no xfer.json: the classifier says INCONCLUSIVE for the transfer).
function Wait-FsN1XferJob($Job, [int]$TimeoutMs = 90000) {
    $done = $Job.Handle.AsyncWaitHandle.WaitOne($TimeoutMs)
    if (-not $done) { $Job.Sync.Stop = $true; $null = $Job.Handle.AsyncWaitHandle.WaitOne(5000) }
    $out = $null
    $errs = @()
    try { if ($Job.Handle.IsCompleted) { $out = @($Job.PowerShell.EndInvoke($Job.Handle)) | Select-Object -Last 1 } } catch { $out = $null; $errs += "the session ended with an error: $(ConvertTo-FsN1Printable $_.Exception.Message)" }
    try { $errs += @($Job.PowerShell.Streams.Error | ForEach-Object { ConvertTo-FsN1Printable $_.ToString() }) } catch { }
    try { $Job.PowerShell.Dispose() } catch { }
    [pscustomobject]@{ Completed = [bool]$done; Result = $out; Errors = $errs }
}
