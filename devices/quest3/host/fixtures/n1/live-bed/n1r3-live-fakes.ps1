# FrameShift N1 r3 - THE LIVE-PATH TEST BED, main part (test-host-n1.ps1 section LV). TEST ONLY. No device, no COM port,
# no PnP or network-adapter query, no network beyond ::1.
#
# This file is NEVER loaded by a shipped host file. Section LV copies fs-collect-n1.ps1 (the shipped r3 file, or the r2
# file of fixtures\n1\r2-host) into a temporary tree beside unchanged copies of its libraries, and inserts ONE line into
# that copy, just before its CLI ("if ($script:FsN1Invocation -eq '.') { return }"), that dot-sources this file. The
# collector's live branch then runs byte for byte as shipped (the test checks that removing that one line gives the
# shipped bytes back). This file replaces only the hardware edges the live branch reaches:
#   Get-FsGadget              the PnP lookup -> the configured gadget FS-<nonce> on the configured COMn
#   New-FsRawSerialTransport  the COM port -> a scripted ACM device: the N1 QEMU harness capture (c-full) delivered by
#                             the replay transport of the pinned engine (every write must equal the recorded one), plus
#                             the device's xfer step: when fs-n1 <chal> is written, an FSX1 responder starts on ::1 and
#                             the rest of the record is held back until it has served the PC side (at most 60 s)
#   New-FsHex                 the random host tokens -> the capture's own tokens (the device answers are recorded)
#   New-FsN1Cfg               the real one, then the harness's kernel release and PID 1 (as -N1ReplayKernel/-Pid1 do)
# Every event is appended to <bed>\host\n1r3-bed.log; the configuration is <bed>\host\n1r3-bed.json.
$script:N1BedDir = $PSScriptRoot
$script:N1BedCfg = [IO.File]::ReadAllText((Join-Path $script:N1BedDir 'n1r3-bed.json')) | ConvertFrom-Json
$script:N1BedLogPath = Join-Path $script:N1BedDir 'n1r3-bed.log'
function Write-N1BedLog([string]$Line) { [IO.File]::AppendAllText($script:N1BedLogPath, "$([DateTime]::UtcNow.ToString('o')) $Line`n") }
Write-N1BedLog 'bed loaded'
$script:N1BedTokens = New-Object 'System.Collections.Generic.Queue[string]'
foreach ($tk in @($script:N1BedCfg.Tokens)) { $script:N1BedTokens.Enqueue([string]$tk) }

function New-FsHex { param([int]$Bytes = 16)
    if ($script:N1BedTokens.Count -eq 0) { throw 'test bed: an unexpected New-FsHex call (no recorded token left)' }
    $t = $script:N1BedTokens.Dequeue()
    if ($t.Length -ne 2 * $Bytes) { throw "test bed: New-FsHex $Bytes asked; the next recorded token has $($t.Length) hex digits" }
    Write-N1BedLog "token $Bytes"
    $t
}

function Get-FsGadget { param([Parameter(Mandatory)][string]$Nonce)
    $ok = ($Nonce -ceq [string]$script:N1BedCfg.Nonce)
    Write-N1BedLog "gadget lookup $Nonce -> $(if ($ok) { [string]$script:N1BedCfg.Port } else { 'none' })"
    [pscustomobject][ordered]@{ Present = $true; SerialOk = $ok; Serials = @("FS-$($script:N1BedCfg.Nonce)")
                                ComPort = $(if ($ok) { [string]$script:N1BedCfg.Port } else { $null }); Parent = "USB\VID_1D6B&PID_0104\FS-$($script:N1BedCfg.Nonce)" }
}

${function:New-FsN1CfgReal} = ${function:New-FsN1Cfg}
function New-FsN1Cfg {
    param([Parameter(Mandatory)][string]$Nonce, [long]$GiveUpMs = -1, [long]$AckGiveUpMs = -1, $Timing = $null, [int]$HostMarginSec = 15)
    $c = New-FsN1CfgReal @PSBoundParameters
    $c.Kernel = [string]$script:N1BedCfg.Kernel; $c.Pid1 = [string]$script:N1BedCfg.Pid1
    $c
}

# The device's xfer step: an FSX1 responder on ::1 in a runspace (the same protocol as test-host-n1.ps1's Start-Emu and
# n1/src/fs-xfer.c); its port is published in the AppDomain for the PC side's adapter stand-in (n1r3-live-fakes-xfer.ps1).
function Start-N1BedResponder([string]$N, [string]$Ch) {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::IPv6Loopback, 0); $l.Start()
    $port = ([Net.IPEndPoint]$l.LocalEndpoint).Port
    $rs = [PowerShell]::Create()
    $null = $rs.AddScript({ param($L, $N, $Ch)
        $L.Server.ReceiveTimeout = 0
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not $L.Pending()) { if ([DateTime]::UtcNow -ge $deadline) { $L.Stop(); return 'no connection within 60 s' }; Start-Sleep -Milliseconds 50 }
        $s = $L.AcceptSocket(); $L.Stop(); $s.ReceiveTimeout = 15000; $s.SendTimeout = 15000
        $hdr = New-Object Collections.Generic.List[byte]; $b1 = New-Object byte[] 1
        while ($s.Receive($b1) -eq 1) { $hdr.Add($b1[0]); if ($b1[0] -eq 10 -or $hdr.Count -gt 200) { break } }
        if ([Text.Encoding]::ASCII.GetString($hdr.ToArray()) -cne "FSX1 $N $Ch 8388608 8388608`n") { $s.Close(); return 'bad-header' }
        $buf = New-Object byte[] 65536; $sha = [Security.Cryptography.SHA256]::Create(); $got = 0
        while ($got -lt 8388608) { $k = $s.Receive($buf, 0, [Math]::Min(65536, 8388608 - $got), 'None'); if ($k -le 0) { break }; $null = $sha.TransformBlock($buf, 0, $k, $null, 0); $got += $k }
        $null = $sha.TransformFinalBlock($buf, 0, 0); $rh = [FsN1Stream]::Hex($sha.Hash)
        [byte[]]$d = [FsN1Stream]::D2hStream($N, $Ch, 8388608)
        $th = [FsN1Stream]::Sha($d, 0, $d.Length)
        $off = 0; while ($off -lt $d.Length) { $off += $s.Send($d, $off, [Math]::Min(65536, $d.Length - $off), 'None') }
        $null = $s.Send([Text.Encoding]::ASCII.GetBytes("FSX1 END $N $Ch rx=$got rx_sha256=$rh tx=8388608 tx_sha256=$th`n"))
        $s.Shutdown('Send'); try { while ($s.Receive($buf) -gt 0) { } } catch { }; $s.Close(); "served rx=$got"
    }).AddArgument($l).AddArgument($N).AddArgument($Ch)
    $h = $rs.BeginInvoke()
    [AppDomain]::CurrentDomain.SetData('n1r3.bed.port', [int]$port)
    Write-N1BedLog "device xfer step listening on [::1]:$port (fs-n1 $Ch)"
    [pscustomobject]@{ Ps = $rs; H = $h; Port = $port }
}

function New-FsRawSerialTransport {
    param([Parameter(Mandatory)][string]$PortName, [int]$PollMs = 50)
    if ($PortName -cne [string]$script:N1BedCfg.Port) { throw "test bed: the collector asked for $PortName, not the gadget's $($script:N1BedCfg.Port)" }
    [byte[]]$raw = [IO.File]::ReadAllBytes([string]$script:N1BedCfg.Capture)
    $ix = Read-FsCaptureIndex -Path ([string]$script:N1BedCfg.Index) -RawLength $raw.Length
    $inner = New-FsReplayTransport -Raw $raw -Index $ix -PollMs $PollMs
    Write-N1BedLog "transport created for $PortName (not opened)"
    $t = [pscustomobject]@{ Inner = $inner; Kind = 'test-bed-acm'; PollMs = $PollMs; Hold = $false; HoldEnd = [DateTime]::MinValue; Emu = $null }
    $t | Add-Member ScriptMethod Open { Write-N1BedLog 'transport OPENED' }
    $t | Add-Member ScriptMethod NowMs { $this.Inner.NowMs() }
    $t | Add-Member ScriptMethod Held {
        if (-not $this.Hold) { return $false }
        if ($this.Emu.H.IsCompleted -or [DateTime]::UtcNow -ge $this.HoldEnd) {
            $this.Hold = $false
            $res = if ($this.Emu.H.IsCompleted) { try { [string](@($this.Emu.Ps.EndInvoke($this.Emu.H)) | Select-Object -Last 1) } catch { "error: $($_.Exception.Message)" } } else { 'not finished within 60 s' }
            Write-N1BedLog "device xfer step ended: $res; the record follows"
            return $false
        }
        $true
    }
    $t | Add-Member ScriptMethod ReadBytes { param([long]$untilMs)
        if ($this.Held()) { return ,([byte[]]@()) }
        $b = $this.Inner.ReadBytes($untilMs)
        return ,([byte[]]$b)
    }
    $t | Add-Member ScriptMethod WriteBytes { param([byte[]]$b)
        $text = [Text.Encoding]::GetEncoding(28591).GetString($b).TrimEnd([char]10)
        Write-N1BedLog "write: $text"
        $this.Inner.WriteBytes($b)
        if ($this.Inner.Divergence.Count) { Write-N1BedLog "DIVERGENCE: $(@($this.Inner.Divergence) -join ' | ')" }
        if ($text -cmatch '^fs-n1 ([0-9a-f]{32})\z') { $this.Emu = Start-N1BedResponder ([string]$script:N1BedCfg.Nonce) $Matches[1]; $this.Hold = $true; $this.HoldEnd = [DateTime]::UtcNow.AddSeconds(60) }
    }
    $t | Add-Member ScriptMethod Idle { param([long]$untilMs) if ($this.Held()) { Start-Sleep -Milliseconds 50; return }; $this.Inner.Idle($untilMs) }
    $t | Add-Member ScriptMethod Beep { param([int]$f, [int]$ms) Write-N1BedLog "beep $f/$ms (silent)" }
    $t | Add-Member ScriptMethod Dispose { Write-N1BedLog "transport disposed; divergence $($this.Inner.Divergence.Count)" }
    $t
}
