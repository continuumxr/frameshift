# FrameShift Quest 2 - TCP transport for the stage-1 NCM channel (Windows PowerShell 5.1,
# no modules, no downloads). DOT-SOURCED by a future Quest 2 collector; it has no CLI.
# Design: devices/quest2/channel/README.md section 4. Offline draft: never run against a device.
#
# What it carries over from devices/quest3/host/COLLECTOR.md (the D1-class rules), adapted to
# one-request-per-TCP-connection:
#  1. Fixed commands only. New-FsTcpCommand is the only builder: a verb from a fixed table, the
#     attempt nonce, and a host-generated lowercase-hex token of fixed length; the final text is
#     re-checked against ^[a-z0-9 -]{1,64}\z. No quote, $, ;, backslash, CR or LF can appear.
#  2. One write site. Exactly one socket send in this file ($sock.Send($reqBytes)); $reqBytes is
#     assigned once, from ASCII($cmd + LF); $cmd is assigned once, from New-FsTcpCommand.
#     Device bytes are data only and never reach a write (test-transport-tcp.ps1 section B scans
#     this source; section F proves it dynamically against a hostile device).
#  3. Send gate (Get-FsTcpSendGate), checked immediately before every connection:
#       - the transport is not stopped (any failure stops it for good; nothing is sent again);
#       - the previous record was framed correctly AND confirmed by the caller
#         (Confirm-FsTcpRecord -Known), i.e. the device state is known;
#       - until an FSV1 has been confirmed as verified, the only verb allowed is fs-verify;
#       - the host give-up (BootStartUtc + DEADLINE - margin) has not been reached, and for the
#         pre-runner verbs (fs-verify, fs-ack, fs-status) the ack-window give-up neither;
#         fs-done is exempt from the ack-window cap only (as the Quest 3 collector, NIT7);
#       - until the first request has been sent: the start refusal (>= 60 s to the give-up,
#         >= 30 s of the ack window; live mode cannot lower these) - mandatory, FS-R-008;
#       - fs-collect only with RunnerLimitSec set and MinRemainMs >= RunnerWorstMs, TimeoutMs >=
#         RunnerTimeoutMs (derived from the device bounds; revision 3, re-review m9);
#       - after connecting, the device has sent nothing (no unsolicited byte, no early close)
#         during PreSendQuietMs; otherwise nothing is sent;
#       - revision 2 (review m8): the time part (give-up, ack window, runner guard, start
#         refusal) is evaluated AGAIN immediately before the write; if it fails there the
#         socket is aborted (RST), nothing is sent and the transport stops.
#     Live mode takes the address and ScopeId only from the Find-FsNcmAdapter result (-Adapter),
#     and Set-FsTcpDeadlines may run once per transport (review m9).
#     Any refusal: the transport stops, the result is INCONCLUSIVE for the caller.
#  4. Framing: a response is valid only if the device closed the connection (EOF) after exactly
#     one record: one printable-ASCII line "<TAG> ... END\n" (FSV1 FSA1 FSS1 FSD1, or the FSR1
#     refusal), or, for fs-collect, an FSB1 record (optional leading empty line, printable lines,
#     last line "FSB1 END ...", final LF) whose content the caller validates with
#     common/host/fsb1.ps1 Test-Fsb1Record. Its nonce= field must be the attempt nonce. A
#     timeout, a reset, an oversize response, a missing LF, a CR, a second line or trailing
#     bytes: the transport stops.
#  5. Raw capture: every response byte is appended, as received, to <OutDir>\capture.raw (with a
#     SHA-256 computed while writing and re-checked from disk at Close), and also saved alone as
#     <OutDir>\responses\<seq>-<verb>.raw with its own SHA-256 in the index. Index (FSIDX2):
#       FSIDX2 nonce=<n16> mode=<live|fixture> transport=tcp addr=<addr> port=<port>
#       C <seq> <offset> <ms> ok|fail <reason>      connection attempt
#       W <offset> <ms> <command>                  request written (after the send returned)
#       R <offset> <length> <ms>                   response bytes read
#       E <seq> <offset> <ms> <end> <len> <sha256> end of that response
#       N <offset> <ms> <text>                     host event (stop reason, deadlines)
#  6. Timing (FS-R-007 B1, FS-R-008): absolute UTC deadlines from BootStartUtc
#     (Get-FsTcpHostDeadlines), converted to the transport's monotonic Stopwatch only AFTER the
#     preparation (adapter lookup, transport construction), from a fresh read: transport clock
#     first, UTC second (Set-FsTcpDeadlines). Every connect and read is capped by the give-up.
#  7. Device-derived text reaches the console or a stored reason only through
#     ConvertTo-FsTcpPrintable (\xNN for anything outside [ -~]).
Set-StrictMode -Version 2.0

$script:FsTcpCmdSpec = [ordered]@{
    'fs-verify'  = '^[0-9a-f]{32}\z'
    'fs-ack'     = '^[0-9a-f]{16}\z'
    'fs-status'  = $null
    'fs-done'    = $null
    'fs-collect' = '^[0-9a-f]{32}\z'
}
$script:FsTcpTag = @{ 'fs-verify' = 'FSV1'; 'fs-ack' = 'FSA1'; 'fs-status' = 'FSS1'; 'fs-done' = 'FSD1'; 'fs-collect' = 'FSB1' }
$script:FsTcpPreRunner = @('fs-verify', 'fs-ack', 'fs-status')
$script:FsTcpLineMax = 1024                    # a single-line record (fs-rpcd writes < 700 bytes)
$script:FsTcpRecordMax = 8MB + 4096            # FSB1 decoder limit plus the leading line
# Revision 3 (re-review m9): the device-side bounds of one fs-collect, from src/fs-rpcd.c (the host
# fixture B7 checks these against its #defines). Worst case from the write to the device's FIN:
#   request read + trailing window  REQ_MS 3000 + TRAIL_MS 75  (the device may take that long
#                                   before it starts the runner)
#   the runner                      T = the image's -T (RunnerLimitSec)
#   reap                            REAP_MS 2000 + REAP_KILL_MS 2000
#   orphan sweep                    SWEEP_MS 2000 (before the record is sent)
#   record write                    WRITE_MS 30000 (fs-rpcd's own bound for sending up to 8 MiB)
# RunnerTimeoutMs = T + all of the above: the read timeout an fs-collect must allow, so a valid
# record is never cut off by the host. RunnerWorstMs = RunnerTimeoutMs + 5000 margin (the Quest 3
# collector's RunnerMarginSec): the time that must be left before the host give-up to send it.
$script:FsTcpDev = @{ ReqMs = 3000; TrailMs = 75; ReapMs = 2000; ReapKillMs = 2000; SweepMs = 2000; WriteMs = 30000; MarginMs = 5000; CollectSMax = 104 }

function ConvertTo-FsTcpPrintable {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 0x20 -and $c -le 0x7e -and $c -ne 0x5c) { [void]$sb.Append($ch) }
        elseif ($c -eq 0x5c) { [void]$sb.Append('\\') }
        elseif ($c -le 0xff) { [void]$sb.Append(('\x{0:x2}' -f $c)) }
        else { [void]$sb.Append(('\u{0:x4}' -f $c)) }
    }
    $sb.ToString()
}

function New-FsTcpHex {
    param([int]$Bytes = 16)
    $b = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    -join ($b | ForEach-Object { $_.ToString('x2') })
}

function Get-FsTcpSha256Hex {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

function Test-FsTcpNonce { param([string]$Nonce) return ($Nonce -cmatch '^[0-9a-f]{16}\z') }

# The device address is a function of the nonce: the 64-bit nonce IS the interface identifier.
function Get-FsTcpLinkLocal {
    param([Parameter(Mandatory)][string]$Nonce)
    if (-not (Test-FsTcpNonce $Nonce)) { throw 'refused: nonce must be 16 lowercase hex' }
    'fe80::{0}:{1}:{2}:{3}' -f $Nonce.Substring(0, 4), $Nonce.Substring(4, 4), $Nonce.Substring(8, 4), $Nonce.Substring(12, 4)
}
# The MAC the gadget gives the host side (f_ncm host_addr), Windows spelling. Evidence only.
function Get-FsTcpHostMac {
    param([Parameter(Mandatory)][string]$Nonce)
    if (-not (Test-FsTcpNonce $Nonce)) { throw 'refused: nonce must be 16 lowercase hex' }
    ('06-{0}-{1}-{2}-{3}-{4}' -f $Nonce.Substring(0, 2), $Nonce.Substring(2, 2), $Nonce.Substring(4, 2), $Nonce.Substring(6, 2), $Nonce.Substring(8, 2)).ToUpperInvariant()
}

# ------------------------------------------------------------ commands -----
# The ONLY way a byte reaches the device.
function New-FsTcpCommand {
    param([Parameter(Mandatory)][string]$Verb, [Parameter(Mandatory)][string]$Nonce, [string]$Arg = '')
    if (-not $script:FsTcpCmdSpec.Contains($Verb)) { throw "refused: verb '$(ConvertTo-FsTcpPrintable $Verb)' is not in the command table" }
    if (-not (Test-FsTcpNonce $Nonce)) { throw 'refused: nonce must be 16 lowercase hex' }
    $re = $script:FsTcpCmdSpec[$Verb]
    if ($null -eq $re) {
        if ($Arg -ne '') { throw "refused: $Verb takes no argument" }
        $text = "$Verb $Nonce"
    } else {
        if ($Arg -cnotmatch $re) { throw "refused: argument for $Verb does not match $re" }
        $text = "$Verb $Nonce $Arg"
    }
    if ($text -cnotmatch '^[a-z0-9 -]{1,64}\z') { throw 'refused: command text outside [a-z0-9 -]{1,64}' }
    return $text
}

# ------------------------------------------------------------- adapter -----
# Finds the Windows network adapter of the FS-<nonce> NCM gadget. The scriptblocks are injectable
# for fixtures; the defaults read PnP and NetAdapter state (read only, no configuration change).
# Binding rule: the adapter's PnP instance must be a descendant (depth <= 3) of exactly the
# parent USB\VID_1D6B&PID_0104\FS-<nonce>. Refusals (nothing is sent): no such parent, not
# exactly one adapter under it, adapter not Up, no IPv6 link-local address on it (IPv6 unbound).
function Find-FsNcmAdapter {
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
          [scriptblock]$GetLinkLocal = { param($ifIndex)
              @(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like 'fe80:*' } | ForEach-Object { [string]$_.IPAddress }) })
    if (-not (Test-FsTcpNonce $Nonce)) { throw 'refused: nonce must be 16 lowercase hex' }
    $want = "FS-$Nonce"
    $r = [ordered]@{ Nonce = $Nonce; Parent = $null; Serials = @(); Adapter = $null; HostLinkLocal = @(); MacExpected = (Get-FsTcpHostMac $Nonce)
                     MacMatches = $false; DeviceAddress = (Get-FsTcpLinkLocal $Nonce); Refusal = $null }
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
    $r.MacMatches = (([string]$a.Mac).ToUpperInvariant() -eq $r.MacExpected)
    if ($a.Status -ne 'Up') { $r.Refusal = "adapter ifIndex $($a.IfIndex) is '$(ConvertTo-FsTcpPrintable $a.Status)', not Up"; return [pscustomobject]$r }
    $r.HostLinkLocal = @(& $GetLinkLocal $a.IfIndex)
    if ($r.HostLinkLocal.Count -lt 1) { $r.Refusal = "adapter ifIndex $($a.IfIndex) has no IPv6 link-local address (IPv6 not bound?)"; return [pscustomobject]$r }
    [pscustomobject]$r
}

# --------------------------------------------------------------- timing -----
function Get-FsTcpHostDeadlines {
    param([Parameter(Mandatory)][DateTime]$OriginUtc, [Parameter(Mandatory)][int]$DeviceDeadlineSec,
          [Parameter(Mandatory)][int]$AckWindowSec, [Parameter(Mandatory)][int]$HostMarginSec)
    if ($OriginUtc.Kind -ne [DateTimeKind]::Utc) { throw 'refused: BootStartUtc must be a UTC time' }
    if ($AckWindowSec -gt $DeviceDeadlineSec -or $HostMarginSec -lt 1) { throw 'refused: inconsistent timing parameters' }
    [pscustomobject]@{ OriginUtc = $OriginUtc; GiveUpUtc = $OriginUtc.AddSeconds($DeviceDeadlineSec - $HostMarginSec)
                       AckGiveUpUtc = $OriginUtc.AddSeconds($AckWindowSec - $HostMarginSec); DeviceDeadlineUtc = $OriginUtc.AddSeconds($DeviceDeadlineSec) }
}

# ------------------------------------------------------------ transport -----
function New-FsTcpTransport {
    param([string]$Address = '', [Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Nonce,
          [Parameter(Mandatory)][string]$OutDir, [int]$ScopeId = 0, [ValidateSet('live', 'fixture')][string]$Mode = 'live',
          $Adapter = $null,                                   # Find-FsNcmAdapter result; REQUIRED in live mode
          [int]$ConnectTimeoutMs = 3000, [int]$PreSendQuietMs = 100, [int]$PollMs = 20,
          [int]$MinStartRemainMs = 60000, [int]$MinStartAckRemainMs = 30000,
          [int]$RunnerLimitSec = 0,                         # the image's fs-rpcd -T; 0 = this image has no runner
          [string]$ReadyStage = '')                         # the init's ready stage (Quest 2: RPC_READY); REQUIRED in live mode
    if (-not (Test-FsTcpNonce $Nonce)) { throw 'refused: nonce must be 16 lowercase hex' }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'refused: port' }
    # Revision 2 (review m9): in live mode the address and the scope come from the adapter object
    # (fe80::<nonce> on ITS ifIndex), and the start thresholds cannot be lowered.
    if ($null -ne $Adapter) {
        if ($Adapter.Refusal) { throw "refused: adapter lookup refused: $(ConvertTo-FsTcpPrintable $Adapter.Refusal)" }
        if ($Adapter.Nonce -cne $Nonce) { throw 'refused: adapter was found for another nonce' }
        if ($null -eq $Adapter.Adapter -or [int]$Adapter.Adapter.IfIndex -le 0) { throw 'refused: adapter has no ifIndex' }
        $want = Get-FsTcpLinkLocal $Nonce
        if ($Address -ne '' -and $Address -cne $want) { throw 'refused: address differs from the adapter-derived fe80::<nonce>' }
        if ($ScopeId -ne 0 -and $ScopeId -ne [int]$Adapter.Adapter.IfIndex) { throw "refused: ScopeId $ScopeId is not the adapter ifIndex $($Adapter.Adapter.IfIndex)" }
        $Address = $want; $ScopeId = [int]$Adapter.Adapter.IfIndex
    } elseif ($Mode -eq 'live') { throw 'refused: live mode needs the Find-FsNcmAdapter result (-Adapter)' }
    if ($Mode -eq 'live' -and ($MinStartRemainMs -lt 60000 -or $MinStartAckRemainMs -lt 30000)) { throw 'refused: live start thresholds cannot be lowered' }
    if ($Address -eq '') { throw 'refused: no address' }
    # revision 4 (final re-review R1): the ready stage is part of the transport, mandatory live
    if ($ReadyStage -ne '' -and $ReadyStage -cnotmatch '^[A-Z0-9_]{1,32}\z') { throw 'refused: ReadyStage must be [A-Z0-9_]{1,32}' }
    if ($Mode -eq 'live' -and $ReadyStage -eq '') { throw 'refused: live mode needs -ReadyStage (the init''s ready stage, e.g. RPC_READY)' }
    if ($RunnerLimitSec -lt 0 -or $RunnerLimitSec -gt $script:FsTcpDev.CollectSMax) { throw "refused: RunnerLimitSec must be 0..$($script:FsTcpDev.CollectSMax) (fs-rpcd -T)" }
    $rto = 0; $rworst = 0
    if ($RunnerLimitSec -gt 0) {
        $d = $script:FsTcpDev
        $rto = [long]$RunnerLimitSec * 1000 + $d.ReqMs + $d.TrailMs + $d.ReapMs + $d.ReapKillMs + $d.SweepMs + $d.WriteMs
        $rworst = $rto + $d.MarginMs
    }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { throw 'refused: address is not an IP literal' }
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($ip.IsIPv6LinkLocal) {
            if ($ScopeId -le 0) { throw 'refused: a link-local address needs the adapter ifIndex as ScopeId' }
            $ip.ScopeId = $ScopeId
        } elseif ($ScopeId -ne 0) { throw 'refused: ScopeId only with a link-local address' }
    } elseif ($ScopeId -ne 0) { throw 'refused: ScopeId only with IPv6' }
    if ($Mode -eq 'live' -and -not ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and $ip.IsIPv6LinkLocal -and $Address -ceq (Get-FsTcpLinkLocal $Nonce))) {
        throw 'refused: live mode talks only to fe80::<nonce> on the gadget adapter'
    }
    if (Test-Path -LiteralPath $OutDir) { throw "refused: output directory already exists: $OutDir" }
    $null = New-Item -ItemType Directory -Path $OutDir
    $null = New-Item -ItemType Directory -Path (Join-Path $OutDir 'responses')
    $rawPath = Join-Path $OutDir 'capture.raw'
    $fs = [System.IO.File]::Open($rawPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $ixs = [System.IO.File]::Open("$rawPath.idx", [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $ix = New-Object System.IO.StreamWriter($ixs, (New-Object System.Text.UTF8Encoding($false)))
    $ix.NewLine = "`n"
    $shown = $Address; if ($ScopeId -gt 0) { $shown = "$Address%$ScopeId" }
    $ix.WriteLine("FSIDX2 nonce=$Nonce mode=$Mode transport=tcp addr=$shown port=$Port"); $ix.Flush()
    $t = [pscustomobject]@{
        Ip = $ip; Port = $Port; Nonce = $Nonce; Mode = $Mode; OutDir = $OutDir; RawPath = $rawPath; IdxPath = "$rawPath.idx"
        Fs = $fs; Ix = $ix; Sha = [System.Security.Cryptography.SHA256]::Create(); Length = [long]0
        Clock = [System.Diagnostics.Stopwatch]::StartNew(); ConnectTimeoutMs = $ConnectTimeoutMs; PreSendQuietMs = $PreSendQuietMs; PollMs = $PollMs
        Seq = 0; State = 'ready'; StopReason = $null; Verified = $false; Last = $null; Started = $false
        MinStartRemainMs = $MinStartRemainMs; MinStartAckRemainMs = $MinStartAckRemainMs
        RunnerLimitSec = $RunnerLimitSec; RunnerTimeoutMs = $rto; RunnerWorstMs = $rworst; ReadyStage = $ReadyStage
        GiveUpMs = $null; AckGiveUpMs = $null; Timing = $null; Closed = $false; Sha256 = $null
    }
    $t | Add-Member ScriptMethod NowMs { [long]$this.Clock.ElapsedMilliseconds }
    $t | Add-Member ScriptMethod Append {
        param([byte[]]$b, [long]$ms)
        if ($b.Length -eq 0) { return }
        try {
            $this.Fs.Write($b, 0, $b.Length); $this.Fs.Flush()
            $this.Ix.WriteLine("R $($this.Length) $($b.Length) $ms"); $this.Ix.Flush()
        } catch { throw (New-Object System.IO.IOException("capture write failed: $($_.Exception.Message)")) }
        $null = $this.Sha.TransformBlock($b, 0, $b.Length, $null, 0)
        $this.Length += $b.Length
    }
    $t | Add-Member ScriptMethod Note { param([string]$text) $this.Ix.WriteLine("N $($this.Length) $($this.NowMs()) $(ConvertTo-FsTcpPrintable $text)"); $this.Ix.Flush() }
    $t | Add-Member ScriptMethod IxLine { param([string]$line) $this.Ix.WriteLine($line); $this.Ix.Flush() }
    $t
}

# Converts the absolute deadlines AFTER the preparation: transport clock first, UTC second.
function Set-FsTcpDeadlines {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)]$Deadlines)
    if ($null -ne $Transport.GiveUpMs) { throw 'refused: deadlines are already set (one conversion per transport)' }   # review m9
    $nowMs = $Transport.NowMs()
    $nowUtc = [DateTime]::UtcNow
    if ($Deadlines.OriginUtc -gt $nowUtc) { throw 'refused: BootStartUtc is later than now' }
    $rem = [long][Math]::Floor(($Deadlines.GiveUpUtc - $nowUtc).TotalMilliseconds)
    $ack = [long][Math]::Floor(($Deadlines.AckGiveUpUtc - $nowUtc).TotalMilliseconds)
    $Transport.GiveUpMs = $nowMs + $rem
    $Transport.AckGiveUpMs = $nowMs + $ack
    $Transport.Timing = [pscustomobject]@{ OriginUtc = $Deadlines.OriginUtc.ToString('o'); GiveUpUtc = $Deadlines.GiveUpUtc.ToString('o')
                                           AckGiveUpUtc = $Deadlines.AckGiveUpUtc.ToString('o'); ConvertedAtUtc = $nowUtc.ToString('o')
                                           ConvertedAtMs = $nowMs; RemainMs = $rem; AckRemainMs = $ack }
    $Transport.Note("deadlines origin=$($Deadlines.OriginUtc.ToString('o')) giveup_ms=$($Transport.GiveUpMs) ack_giveup_ms=$($Transport.AckGiveUpMs) at_ms=$nowMs")
    $Transport.Timing
}
# Live start refusals on the converted remaining times ($null = may start). Same thresholds as
# the Quest 3 collector; the Quest 2 timers themselves are still [O] (its own thermal assessment).
function Get-FsTcpStartRefusal {
    param([Parameter(Mandatory)]$Transport, [int]$MinRemainMs = -1, [int]$MinAckRemainMs = -1)
    if ($MinRemainMs -lt 0) { $MinRemainMs = $Transport.MinStartRemainMs }
    if ($MinAckRemainMs -lt 0) { $MinAckRemainMs = $Transport.MinStartAckRemainMs }
    if ($null -eq $Transport.GiveUpMs) { return 'deadlines not set' }
    $now = $Transport.NowMs()
    if ($Transport.GiveUpMs - $now -lt $MinRemainMs) { return "start refused: only $([Math]::Max(0, [long][Math]::Floor(($Transport.GiveUpMs - $now) / 1000))) s left before the host give-up" }
    if ($Transport.AckGiveUpMs - $now -lt $MinAckRemainMs) { return "start refused: only $([Math]::Max(0, [long][Math]::Floor(($Transport.AckGiveUpMs - $now) / 1000))) s of the ack window left" }
    return $null
}

function Stop-FsTcpTransport {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)][string]$Reason)
    if ($Transport.State -ne 'stopped') {
        $Transport.State = 'stopped'; $Transport.StopReason = (ConvertTo-FsTcpPrintable $Reason)
        try { $Transport.Note("stop $Reason") } catch { }
    }
}

# The time part of the gate. Evaluated before the connection AND again immediately before the
# single write (review m8). Until the first request has been sent, the start refusal is part of it
# (mandatory, FS-R-008); fs-collect must carry a runner guard (MinRemainMs > 0).
function Get-FsTcpTimeGate {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)][string]$Verb, [long]$MinRemainMs = 0, [long]$TimeoutMs = 0)
    if ($null -eq $Transport.GiveUpMs) { return 'deadlines not set (BootStartUtc)' }
    $now = $Transport.NowMs()
    if ($now -ge $Transport.GiveUpMs) { return 'host give-up reached (BootStartUtc + DEADLINE - margin)' }
    if ($Verb -eq 'fs-collect') {   # revision 3 (re-review m9): the guard is derived, not just > 0
        if ($Transport.RunnerLimitSec -le 0) { return 'fs-collect refused: this transport has no RunnerLimitSec (the image''s fs-rpcd -T)' }
        if ($MinRemainMs -lt $Transport.RunnerWorstMs) { return "fs-collect needs a runner guard MinRemainMs >= RunnerWorstMs ($($Transport.RunnerWorstMs) ms), got $MinRemainMs" }
        if ($TimeoutMs -lt $Transport.RunnerTimeoutMs) { return "fs-collect needs TimeoutMs >= RunnerTimeoutMs ($($Transport.RunnerTimeoutMs) ms), got $TimeoutMs" }
    }
    if ($MinRemainMs -gt 0 -and ($Transport.GiveUpMs - $now) -lt $MinRemainMs) { return "less than $MinRemainMs ms before the host give-up" }
    if ($script:FsTcpPreRunner -contains $Verb -and $now -ge $Transport.AckGiveUpMs) { return 'ack-window give-up reached (BootStartUtc + ACK_WINDOW - margin)' }
    if (-not $Transport.Started) { $sr = Get-FsTcpStartRefusal -Transport $Transport; if ($sr) { return $sr } }
    return $null
}
# $null = may send $Verb now; otherwise the reason (the caller must not send).
function Get-FsTcpSendGate {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)][string]$Verb, [long]$MinRemainMs = 0, [long]$TimeoutMs = 0)
    if ($Transport.Closed) { return 'transport closed' }
    if ($Transport.State -eq 'stopped') { return "transport stopped: $($Transport.StopReason)" }
    if ($Transport.State -eq 'pending') { return "previous record (seq $($Transport.Seq)) not confirmed: device state unknown" }
    if (-not $script:FsTcpCmdSpec.Contains($Verb)) { return 'verb not in the command table' }
    if (-not $Transport.Verified -and $Verb -ne 'fs-verify') { return "no verified FSV1 yet: only fs-verify may be sent, not $Verb" }
    return (Get-FsTcpTimeGate -Transport $Transport -Verb $Verb -MinRemainMs $MinRemainMs -TimeoutMs $TimeoutMs)
}

# Framing of one complete response. Returns $null (ok) or a reason; fills $Rec.
function Test-FsTcpFraming {
    param([byte[]]$Bytes, [Parameter(Mandatory)][string]$Verb, [Parameter(Mandatory)][string]$Nonce, [ref]$Rec)
    $Rec.Value = $null
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return 'empty response' }
    $latin = [System.Text.Encoding]::GetEncoding(28591)
    $text = $latin.GetString($Bytes)
    $single = '^(FSV1|FSA1|FSS1|FSD1|FSR1)( [!-~]+)* END\n\z'
    $oneLine = ($text.IndexOf([char]10) -eq $text.Length - 1)
    if ($oneLine -and $Bytes.Length -le $script:FsTcpLineMax -and $text -cmatch $single) {
        $tag = $Matches[1]
        if ($tag -ne 'FSR1' -and $tag -ne $script:FsTcpTag[$Verb]) { return "record $tag does not answer $Verb" }
        $f = [ordered]@{}
        $toks = $text.Substring(4, $text.Length - 4 - 5).Split(' ')     # between "TAG" and " END\n"
        foreach ($tk in $toks) {
            if ($tk -eq '') { continue }
            $kv = $tk.Split('=', 2)
            if ($kv.Count -ne 2 -or $kv[0] -cnotmatch '^[a-z0-9_]{1,16}\z') { $f["_word$($f.Count)"] = $tk; continue }
            if ($f.Contains($kv[0])) { return "duplicate field $($kv[0])" }
            $f[$kv[0]] = $kv[1]
        }
        switch ($tag) {
            'FSV1' { foreach ($k in 'nonce', 'resp', 'kernel', 'pid1', 'stages') { if (-not $f.Contains($k)) { return "FSV1 without $k" } } }
            'FSS1' { foreach ($k in 'nonce', 'stages', 'acked') { if (-not $f.Contains($k)) { return "FSS1 without $k" } } }
            'FSR1' { foreach ($k in 'nonce', 'error') { if (-not $f.Contains($k)) { return "FSR1 without $k" } } }
            'FSA1' { if ($text -cne "FSA1 queued END`n") { return 'FSA1 is not "FSA1 queued END"' } }
            'FSD1' { if ($text -cne "FSD1 queued END`n" -and $text -cne "FSD1 error=write END`n") { return 'FSD1 is not a known FSD1 record' } }
        }
        if ($f.Contains('nonce') -and $f['nonce'] -cne $Nonce) { return "record nonce $(ConvertTo-FsTcpPrintable $f['nonce']) is not the attempt nonce" }
        $Rec.Value = [pscustomobject]@{ Tag = $tag; Fields = $f; Text = $text.TrimEnd([char]10) }
        return $null
    }
    if ($Verb -eq 'fs-collect') {
        if ($Bytes.Length -gt $script:FsTcpRecordMax) { return 'FSB1 response too large' }
        if ($text -cmatch '[^\n\x20-\x7e]') { return 'FSB1 response has a byte outside printable ASCII + LF' }
        if ($Bytes[$Bytes.Length - 1] -ne 10) { return 'FSB1 response does not end with LF' }
        $body = $text; if ($body.StartsWith("`n")) { $body = $body.Substring(1) }
        $lines = $body.TrimEnd([char]10).Split([char]10)
        if (-not $lines[0].StartsWith('FSB1 BEGIN ', [StringComparison]::Ordinal)) { return 'FSB1 response does not start with FSB1 BEGIN' }
        if (-not $lines[$lines.Length - 1].StartsWith('FSB1 END ', [StringComparison]::Ordinal)) { return 'FSB1 response does not end with FSB1 END' }
        if ($body.EndsWith("`n`n")) { return 'FSB1 response has trailing empty lines' }
        $Rec.Value = [pscustomobject]@{ Tag = 'FSB1'; Fields = $null; Text = $null; Lines = $lines.Length }
        return $null
    }
    if ($text.IndexOf([char]13) -ge 0) { return 'CR in response' }
    if ($text.IndexOf([char]10) -lt 0) { return 'no LF: incomplete record' }
    if ($text.IndexOf([char]10) -ne $text.Length - 1) { return 'more than one line, or bytes after the record' }
    return 'not a well-formed single-line record'
}

# One request: gate, connect, (quiet check), the single write, read to EOF, capture, framing.
function Invoke-FsTcpRequest {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)][string]$Verb, [string]$Arg = '',
          [int]$TimeoutMs = 10000, [long]$MinRemainMs = 0)
    $T = $Transport
    $res = [pscustomobject]@{ Seq = 0; Verb = $Verb; Command = $null; Sent = $false; End = $null; Bytes = [byte[]]@(); Sha256 = $null
                              Path = $null; Framing = $null; Record = $null; StartMs = $T.NowMs(); EndMs = $null }
    $gate = Get-FsTcpSendGate -Transport $T -Verb $Verb -MinRemainMs $MinRemainMs -TimeoutMs $TimeoutMs
    if ($gate) { $res.End = 'gate'; $res.Framing = "not sent: $gate"; Stop-FsTcpTransport $T "send gate: $gate"; return $res }
    try { $cmd = New-FsTcpCommand -Verb $Verb -Nonce $T.Nonce -Arg $Arg }
    catch { $res.End = 'gate'; $res.Framing = "not sent: $($_.Exception.Message)"; Stop-FsTcpTransport $T $res.Framing; return $res }
    $res.Command = $cmd
    $T.Seq++; $seq = $T.Seq; $res.Seq = $seq
    $deadline = [Math]::Min($T.NowMs() + $TimeoutMs, $T.GiveUpMs)
    if ($script:FsTcpPreRunner -contains $Verb) { $deadline = [Math]::Min($deadline, $T.AckGiveUpMs) }   # pre-runner phases end by the ack give-up
    $sock = New-Object System.Net.Sockets.Socket($T.Ip.AddressFamily, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp)
    $sock.NoDelay = $true
    $buf = New-Object System.IO.MemoryStream
    $end = $null
    try {
        # ---- connect (bounded) ----
        $cto = [int][Math]::Max(1, [Math]::Min([long]$T.ConnectTimeoutMs, $deadline - $T.NowMs()))
        $ar = $sock.BeginConnect($T.Ip, $T.Port, $null, $null)
        $okc = $ar.AsyncWaitHandle.WaitOne($cto)
        $cerr = $null
        if ($okc) { try { $sock.EndConnect($ar) } catch { $cerr = $_.Exception.InnerException; if (-not $cerr) { $cerr = $_.Exception } } } else { $cerr = 'connect timeout' }
        if ($cerr) {
            $T.IxLine("C $seq $($T.Length) $($T.NowMs()) fail $(ConvertTo-FsTcpPrintable ([string]$cerr).Split([char]10)[0])")
            $end = 'connect-failed'
        } else {
            $T.IxLine("C $seq $($T.Length) $($T.NowMs()) ok")
            # ---- the device must not speak first, nor close first ----
            $q = $T.NowMs() + $T.PreSendQuietMs
            while ($T.NowMs() -lt $q -and -not $sock.Poll(10000, [System.Net.Sockets.SelectMode]::SelectRead)) { }
            if ($sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) {
                $n = $sock.Available
                if ($n -gt 0) {
                    $pre = New-Object byte[] ([Math]::Min($n, 65536)); $got = $sock.Receive($pre)
                    if ($got -lt $pre.Length) { $x = New-Object byte[] $got; [Array]::Copy($pre, $x, $got); $pre = $x }
                    $T.Append($pre, $T.NowMs()); $buf.Write($pre, 0, $pre.Length)
                    $end = 'unsolicited'
                } else { $end = 'closed-before-send' }
            } else {
                # ---- the time gate again, immediately before the write (review m8) ----
                $late = Get-FsTcpTimeGate -Transport $T -Verb $Verb -MinRemainMs $MinRemainMs -TimeoutMs $TimeoutMs
                if ($late) { $end = 'gate-late'; $res.Framing = "not sent: $late"; throw 'gate-late' }
                # ---- THE single write site (D1 rule 2) ----
                $reqBytes = [System.Text.Encoding]::ASCII.GetBytes($cmd + "`n")
                $sent = $sock.Send($reqBytes)
                if ($sent -ne $reqBytes.Length) { throw "short send ($sent of $($reqBytes.Length))" }
                $res.Sent = $true; $T.Started = $true
                $T.IxLine("W $($T.Length) $($T.NowMs()) $cmd")
                # No half-close (Shutdown(Send)): the newline ends the request for fs-rpcd, and a
                # half-close through a relay can lose the response (observed: the WSL NAT localhost
                # relay delivered 1 of 10 responses after a half-close, 10 of 10 without; README 6.2).
                # ---- read to EOF, bounded by the deadline and the size cap ----
                $cap = $script:FsTcpLineMax; if ($Verb -eq 'fs-collect') { $cap = $script:FsTcpRecordMax }
                $chunk = New-Object byte[] 65536
                while ($null -eq $end) {
                    $left = $deadline - $T.NowMs()
                    if ($left -le 0) { $end = 'timeout'; break }
                    $wait = [int][Math]::Min([long]$T.PollMs, $left) * 1000
                    if (-not $sock.Poll($wait, [System.Net.Sockets.SelectMode]::SelectRead)) { continue }
                    try { $n = $sock.Receive($chunk) }
                    catch [System.Net.Sockets.SocketException] { $end = 'reset'; break }
                    if ($n -eq 0) { $end = 'eof'; break }
                    $piece = New-Object byte[] $n; [Array]::Copy($chunk, $piece, $n)
                    $T.Append($piece, $T.NowMs()); $buf.Write($piece, 0, $n)
                    if ($buf.Length -gt $cap) { $end = 'cap'; break }
                }
            }
        }
    } catch {
        if ($end -eq 'gate-late') { }                       # nothing was sent; the socket is aborted (RST) below
        elseif ($_.Exception -is [System.IO.IOException] -and $_.Exception.Message -like 'capture write failed*') { $end = 'capture-failed'; $res.Framing = ConvertTo-FsTcpPrintable $_.Exception.Message }
        else { if ($null -eq $end) { $end = 'error' }; $res.Framing = ConvertTo-FsTcpPrintable $_.Exception.Message }
    } finally {
        try { if ($end -ne 'eof') { $sock.LingerState = New-Object System.Net.Sockets.LingerOption($true, 0) } } catch { }
        try { $sock.Close() } catch { }
    }
    $res.End = $end; $res.EndMs = $T.NowMs()
    $res.Bytes = $buf.ToArray()
    $res.Sha256 = Get-FsTcpSha256Hex $res.Bytes
    $res.Path = Join-Path (Join-Path $T.OutDir 'responses') ('{0:d3}-{1}.raw' -f $seq, $Verb)
    try {
        $rf = [System.IO.File]::Open($res.Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try { $rf.Write($res.Bytes, 0, $res.Bytes.Length) } finally { $rf.Dispose() }
    } catch { $end = 'capture-failed'; $res.End = $end }
    $T.IxLine("E $seq $($T.Length) $($res.EndMs) $end $($res.Bytes.Length) $($res.Sha256)")
    $T.Last = $res
    if ($end -ne 'eof') {
        if (-not $res.Framing) { $res.Framing = "response ended: $end" }
        Stop-FsTcpTransport $T "seq $seq ${Verb}: $($res.Framing)"
        return $res
    }
    $rec = $null
    $why = Test-FsTcpFraming -Bytes $res.Bytes -Verb $Verb -Nonce $T.Nonce -Rec ([ref]$rec)
    if ($why) { $res.Framing = $why; Stop-FsTcpTransport $T "seq $seq ${Verb}: $why"; return $res }
    $res.Framing = 'ok'; $res.Record = $rec
    $T.State = 'pending'
    $res
}

# The caller's verdict on the last record. -Known: the record is what the caller expected and the
# device state is therefore known (a refusal or a foreign ack can be Known; a bad FSV1 response or
# an unexpected tag is not). -Verified: only for an FSV1 whose response the caller checked.
# Revision 4 (final re-review R1). The stages field of an FSV1/FSS1: $null if acceptable, else why.
#   - a trailing '+' is fs-rpcd's truncation marker ('+' never occurs in data): a cut list could
#     have lost an ERROR_ entry, so a truncated stages field is refused;
#   - any ERROR_<stage> (PID 1's fail(), as in every Quest 3 init): the boot was declared failed;
#   - -ReadyStage (when given) must be present.
function Get-FsTcpStagesProblem {
    param([AllowNull()][string]$Stages, [string]$ReadyStage = '')
    if ($null -eq $Stages -or $Stages -eq '') { return 'no stages field' }
    if ($Stages.EndsWith('+')) { return 'stages field truncated by the device (trailing +): an ERROR_ entry could be hidden' }
    $list = @($Stages.Split(','))
    $err = @($list | Where-Object { $_ -clike 'ERROR_*' })
    if ($err.Count) { return "boot declared failed: stages carry $(ConvertTo-FsTcpPrintable ($err -join ','))" }
    if ($ReadyStage -and $list -cnotcontains $ReadyStage) { return "ready stage $ReadyStage absent" }
    return $null
}

function Confirm-FsTcpRecord {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)]$Result, [Parameter(Mandatory)][bool]$Known, [switch]$Verified, [string]$Why = '')
    if ($Transport.State -ne 'pending' -or $null -eq $Transport.Last -or $Result.Seq -ne $Transport.Last.Seq) {
        Stop-FsTcpTransport $Transport 'confirm of a record that is not the pending one'; return
    }
    if (-not $Known) { Stop-FsTcpTransport $Transport "seq $($Result.Seq) not accepted by the caller: $Why"; return }
    # revision 4 (R1): the transport itself refuses a record whose stages are truncated or carry
    # ERROR_, and (for the verifying FSV1) one without the transport's ReadyStage - whatever the
    # caller concluded. Mandatory in live mode because ReadyStage is.
    if ($null -ne $Result.Record -and $null -ne $Result.Record.Fields -and $Result.Record.Fields.Contains('stages')) {
        $rs = ''; if ($Verified) { $rs = $Transport.ReadyStage }
        $sp = Get-FsTcpStagesProblem -Stages $Result.Record.Fields['stages'] -ReadyStage $rs
        if ($sp) { Stop-FsTcpTransport $Transport "seq $($Result.Seq): $sp"; return }
    }
    if ($Verified) {
        if ($Result.Verb -ne 'fs-verify' -or $null -eq $Result.Record -or $Result.Record.Tag -ne 'FSV1') { Stop-FsTcpTransport $Transport '-Verified on a record that is not an FSV1'; return }
        $Transport.Verified = $true
    }
    $Transport.State = 'ready'
}

function Close-FsTcpTransport {
    param([Parameter(Mandatory)]$Transport)
    $T = $Transport
    if ($T.Closed) { return $T.Sha256 }
    $T.Closed = $true
    $null = $T.Sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    $T.Sha256 = -join ($T.Sha.Hash | ForEach-Object { $_.ToString('x2') })
    $T.Ix.WriteLine("N $($T.Length) $($T.NowMs()) close sha256=$($T.Sha256) state=$($T.State)")
    foreach ($d in @($T.Sha, $T.Fs, $T.Ix)) { try { $d.Dispose() } catch { } }
    $disk = Get-FsTcpSha256Hex ([System.IO.File]::ReadAllBytes($T.RawPath))
    if ($disk -ne $T.Sha256) { throw "capture hash mismatch: written $($T.Sha256), on disk $disk" }
    $T.Sha256
}

# ------------------------------------------------------- record checks -----
# For the collector (the transport itself never interprets content beyond framing).
# Revision 3 (re-review N1): an FSV1 whose stages carry a failure marker (ERROR_<stage>, written
# by PID 1's fail() as in every Quest 3 init) is refused: the boot was declared failed, so nothing
# is acked or collected (the caller confirms Known=$false; PID 1's own fail() path reboots).
# -ReadyStage (the Quest 2 init's RPC_READY) is required when given, as stage 1 required
# SHELL_READY implicitly.
function Test-FsTcpVerify {
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Nonce, [Parameter(Mandatory)][string]$Challenge,
          [string]$Kernel = '', [string]$Pid1 = '', [string]$ReadyStage = '')
    if ($Record.Tag -ne 'FSV1') { return "not an FSV1 ($($Record.Tag))" }
    $want = Get-FsTcpSha256Hex ([System.Text.Encoding]::ASCII.GetBytes("${Nonce}:$Challenge"))
    if ($Record.Fields['nonce'] -cne $Nonce) { return 'nonce mismatch' }
    if ($Record.Fields['resp'] -cne $want) { return 'bad response (not sha256(nonce:challenge) for THIS challenge)' }
    if ($Kernel -and $Record.Fields['kernel'] -cne $Kernel) { return 'kernel mismatch' }
    if ($Pid1 -and $Record.Fields['pid1'] -cne $Pid1) { return 'pid1 mismatch' }
    return (Get-FsTcpStagesProblem -Stages $Record.Fields['stages'] -ReadyStage $ReadyStage)
}
# 'ours' | 'none' | 'foreign' | 'invalid' | 'failed'
function Get-FsTcpAckState {
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Token)
    if ($Record.Tag -ne 'FSS1') { return 'invalid' }
    # revision 4 (R1): 'failed' for an ERROR_ stage, 'invalid' for a truncated stages field
    $sp = Get-FsTcpStagesProblem -Stages $Record.Fields['stages']
    if ($sp -like 'boot declared failed*') { return 'failed' }
    if ($sp) { return 'invalid' }
    $a = $Record.Fields['acked']
    if ($a -ceq 'none') { return 'none' }
    if ($a -ceq $Token) { return 'ours' }
    if ($a -cmatch '^[0-9a-f]{1,64}\z') { return 'foreign' }
    return 'invalid'
}
