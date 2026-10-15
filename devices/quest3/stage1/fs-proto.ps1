# FrameShift stage-1 host protocol library (Windows PowerShell 5.1).
# Dot-sourced by host-observe.ps1 and test-host.ps1. Pure functions where
# possible, so every acceptance rule can be exercised by host-only fixtures.
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- clock ----
$script:FsClock = [System.Diagnostics.Stopwatch]::StartNew()
function Get-FsMs { [long]$script:FsClock.ElapsedMilliseconds }   # monotonic

# ------------------------------------------------------- native commands ----
# Runs an executable with both output streams drained asynchronously and a hard
# timeout. Never throws for stderr output or non-zero exit; reports instead.
function Invoke-FsNative {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$ArgList = @(), [int]$TimeoutMs = 60000)
    $quoted = $ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $start = Get-FsMs
    try { $null = $p.Start() } catch {
        return [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false
                                  StartMs = $start; EndMs = (Get-FsMs); Error = $_.Exception.Message }
    }
    # Once started: a fault after Start() is returned as Error (never thrown),
    # and a still-running process gets a Kill() attempt (best effort: if Kill
    # itself fails, the process may outlive the wrapper).
    $out = ''; $err = ''; $code = $null; $exited = $false; $fault = $null
    try {
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        $exited = $p.WaitForExit($TimeoutMs)
        if (-not $exited) { try { $p.Kill() } catch {} ; $null = $p.WaitForExit(5000) }
        if ($tOut.Wait(5000)) { $out = $tOut.Result }
        if ($tErr.Wait(5000)) { $err = $tErr.Result }
        if ($exited) { $code = $p.ExitCode }
    } catch {
        $fault = 'wrapper fault after start: ' + $_.Exception.Message
        try { if (-not $p.HasExited) { $p.Kill() } } catch {}
    } finally { $p.Dispose() }
    [pscustomobject]@{ ExitCode = $code; StdOut = $out; StdErr = $err; TimedOut = (-not $exited -and -not $fault)
                       StartMs = $start; EndMs = (Get-FsMs); Error = $fault }
}

# Serials currently in fastboot mode, parsed from `fastboot devices` stdout.
function Get-FsFastbootSerials {
    param([string]$FastbootExe, [int]$TimeoutMs = 15000)
    $r = Invoke-FsNative -Exe $FastbootExe -ArgList @('devices') -TimeoutMs $TimeoutMs
    $list = @()
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        if ($line -match '^(\S+)\s+fastboot\s*$') { $list += $Matches[1] }
    }
    $ok = (-not $r.Error) -and (-not $r.TimedOut) -and ($r.ExitCode -eq 0)
    [pscustomobject]@{ Serials = $list; Raw = $r; Ok = $ok }   # Ok=false: absence is NOT evidence
}

# Classify the `fastboot boot` invocation itself (FS-R-004 §5).
function Get-FsHandoffClass {
    param([Parameter(Mandatory)]$Result)
    if ($Result.Error)    { return 'INCONCLUSIVE' }          # could not run the host command
    if ($Result.TimedOut) { return 'INCONCLUSIVE' }          # handoff uncertain
    $all = "$($Result.StdOut)`n$($Result.StdErr)"
    if ($all -cmatch 'FAILED \(remote:') { return 'DEVICE_REJECTED' }  # explicit device refusal
    # success needs rc 0, positive protocol evidence, and no FAILED anywhere
    if ($Result.ExitCode -eq 0 -and $all -cnotmatch 'FAILED' -and $all -cmatch 'OKAY|Finished') { return 'HANDOFF_ACKNOWLEDGED' }
    return 'INCONCLUSIVE'                                     # e.g. status read failed: uncertain
}

# ------------------------------------------------------------- records -----
# A record is one complete line: "<TAG> key=value ... END". Anything else,
# including a prefixed, truncated or unterminated line, is not a record.
function ConvertFrom-FsRecord {
    param([string]$Line, [Parameter(Mandatory)][string]$Tag)
    if ($null -eq $Line) { return $null }
    $l = $Line.TrimEnd("`r")
    if ($l -cnotmatch ('^' + [regex]::Escape($Tag) + '((?: [a-z0-9]+=[^ ]*)*) END$')) { return $null }
    $h = @{}
    foreach ($kv in ($Matches[1].Trim() -split ' ')) {
        if ($kv) { $pair = $kv -split '=', 2; $h[$pair[0]] = $pair[1] }
    }
    $h
}
function Get-FsRecords {
    param([string]$Text, [Parameter(Mandatory)][string]$Tag)
    $recs = @()
    if (-not $Text) { return ,$recs }
    foreach ($line in ($Text -split "`n")) {
        $r = ConvertFrom-FsRecord -Line $line -Tag $Tag
        if ($null -ne $r) { $recs += ,$r }
    }
    ,$recs
}
function Get-FsExpectedResponse {
    param([Parameter(Mandatory)][string]$Nonce, [Parameter(Mandatory)][string]$Challenge)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes("$($Nonce):$($Challenge)"))
        -join ($bytes | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}
function New-FsHex { param([int]$Bytes = 16)
    $b = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    -join ($b | ForEach-Object { $_.ToString('x2') })
}

# Command-execution proof (FS-R-004 §2): exact nonce, target-computed response,
# expected kernel and expected PID 1 command line, all in one complete record.
function Test-FsVerify {
    param([string]$Text, [string]$Nonce, [string]$Challenge, [string]$Kernel, [string]$Pid1)
    $want = Get-FsExpectedResponse -Nonce $Nonce -Challenge $Challenge
    $why = 'no complete FSV1 record'
    foreach ($r in (Get-FsRecords -Text $Text -Tag 'FSV1')) {
        if ($r['nonce']  -cne $Nonce)  { $why = 'nonce mismatch';  continue }
        if ($r['resp']   -cne $want)   { $why = 'bad response';    continue }
        if ($r['kernel'] -cne $Kernel) { $why = 'kernel mismatch'; continue }
        if ($r['pid1']   -cne $Pid1)   { $why = 'pid1 mismatch';   continue }
        return [pscustomobject]@{ Ok = $true; Reason = 'verified'; Record = $r }
    }
    [pscustomobject]@{ Ok = $false; Reason = $why; Record = $null }
}

# Holding-state proof: PID 1 recorded this acknowledgement token.
function Test-FsAck {
    param([string]$Text, [string]$Nonce, [string]$AckToken)
    $why = 'no complete FSS1 record'
    foreach ($r in (Get-FsRecords -Text $Text -Tag 'FSS1')) {
        if ($r['nonce'] -cne $Nonce)    { $why = 'nonce mismatch'; continue }
        if ($r['acked'] -cne $AckToken) { $why = 'ack token not recorded by PID 1'; continue }
        if ((',' + $r['stages'] + ',') -notlike '*,HOST_ACK,*') { $why = 'HOST_ACK stage absent'; continue }
        return [pscustomobject]@{ Ok = $true; Reason = 'host-ack confirmed'; Record = $r }
    }
    [pscustomobject]@{ Ok = $false; Reason = $why; Record = $null }
}

# ------------------------------------------------------------- session -----
# Runs the verification and acknowledgement exchange over any transport with
# Write([string]) and ReadAvailable() -> [string] methods. Every wait is
# bounded; any transport exception ends the session with Error set.
function Invoke-FsSession {
    param([Parameter(Mandatory)]$Transport, [string]$Nonce, [string]$Kernel, [string]$Pid1,
          [long]$PassDeadlineMs, [int]$StepTimeoutMs = 10000, [int]$PollMs = 200)
    $res = [ordered]@{ Verified = $false; VerifyReason = 'not attempted'; VerifiedAtMs = $null
                       Acked = $false; AckReason = 'not attempted'; AckedAtMs = $null
                       Stages = $null; Transcript = ''; Error = $null }
    try {
        $ch = New-FsHex 16
        $Transport.Write("fs-verify $ch`n")
        $buf = ''; $t0 = Get-FsMs; $v = $null
        while ((Get-FsMs) - $t0 -lt $StepTimeoutMs) {
            $buf += [string]$Transport.ReadAvailable()
            $v = Test-FsVerify -Text $buf -Nonce $Nonce -Challenge $ch -Kernel $Kernel -Pid1 $Pid1
            if ($v.Ok) { break }
            Start-Sleep -Milliseconds $PollMs
        }
        $res.Transcript += $buf
        $res.VerifyReason = $v.Reason
        if ($v.Ok) {
            $res.Stages = $v.Record['stages']
            $at = Get-FsMs
            if ($at -le $PassDeadlineMs) { $res.Verified = $true; $res.VerifiedAtMs = $at }
            else { $res.VerifyReason = "verified after the PASS deadline ($at > $PassDeadlineMs ms)" }
        }
        if ($res.Verified) {
            $ack = New-FsHex 8
            $Transport.Write("fs-ack $ack`n")
            Start-Sleep -Milliseconds 2500                  # PID 1 polls once per second
            $Transport.Write("fs-status`n")
            $buf = ''; $t0 = Get-FsMs; $a = $null
            while ((Get-FsMs) - $t0 -lt $StepTimeoutMs) {
                $buf += [string]$Transport.ReadAvailable()
                $a = Test-FsAck -Text $buf -Nonce $Nonce -AckToken $ack
                if ($a.Ok) { break }
                Start-Sleep -Milliseconds $PollMs
            }
            $res.Transcript += $buf
            $res.AckReason = $a.Reason
            if ($a.Ok) { $res.Acked = $true; $res.AckedAtMs = Get-FsMs; $res.Stages = $a.Record['stages'] }
        }
    } catch { $res.Error = $_.Exception.Message }
    [pscustomobject]$res
}

# Real serial transport: every blocking operation bounded, control lines and
# handshake set explicitly. Caller must Dispose() in a finally block.
function New-FsSerialTransport {
    param([Parameter(Mandatory)][string]$PortName, [int]$ReadTimeoutMs = 500, [int]$WriteTimeoutMs = 2000)
    $sp = New-Object System.IO.Ports.SerialPort $PortName, 115200, 'None', 8, 'One'
    $sp.Handshake    = [System.IO.Ports.Handshake]::None
    $sp.DtrEnable    = $true          # CDC-ACM: assert DTR so the gadget sees an open port
    $sp.RtsEnable    = $true
    $sp.ReadTimeout  = $ReadTimeoutMs
    $sp.WriteTimeout = $WriteTimeoutMs
    $sp.NewLine      = "`n"
    $t = [pscustomobject]@{ Port = $sp }
    $t | Add-Member ScriptMethod Open    { if (-not $this.Port.IsOpen) { $this.Port.Open() } }
    $t | Add-Member ScriptMethod Write   { param($s) $this.Port.Write([string]$s) }
    $t | Add-Member ScriptMethod ReadAvailable { if ($this.Port.IsOpen) { $this.Port.ReadExisting() } else { throw 'port closed' } }
    $t | Add-Member ScriptMethod Dispose { try { if ($this.Port.IsOpen) { $this.Port.Close() } } finally { $this.Port.Dispose() } }
    $t
}

# --------------------------------------------------- gadget association -----
# Finds our gadget by its parent USB instance (VID_1D6B&PID_0104\FS-<nonce>)
# and the COM port registered under that parent or its child interfaces.
# Enumeration is injectable for fixtures.
function Get-FsGadget {
    param([Parameter(Mandatory)][string]$Nonce,
          [scriptblock]$ListDevices = { Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object InstanceId },
          [scriptblock]$GetChildren = { param($id)
              $p = $null
              try { $p = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Children' -ErrorAction Stop } catch { return @() }
              if ($p -and ($p.PSObject.Properties.Name -contains 'Data') -and $p.Data) { return @($p.Data) }
              return @() },
          [scriptblock]$GetPortName = { param($id)
              $i = $null
              try { $i = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters" -Name PortName -ErrorAction Stop } catch { return $null }
              if ($i -and ($i.PSObject.Properties.Name -contains 'PortName')) { return $i.PortName }
              return $null })
    $ids = @(& $ListDevices)
    $parents = @($ids | Where-Object { $_ -match '^USB\\VID_1D6B&PID_0104\\[^\\]+$' })
    $want = "FS-$Nonce"
    $g = [ordered]@{ Present = ($parents.Count -gt 0); SerialOk = $false; Serials = @(); ComPort = $null; Parent = $null }
    foreach ($p in $parents) {
        $serial = ($p -split '\\')[-1]
        $g.Serials += $serial
        if ($serial -ine $want) { continue }          # mismatch: never talk to it
        $g.SerialOk = $true; $g.Parent = $p
        foreach ($id in @($p) + @(& $GetChildren $p)) {
            if (-not $id) { continue }
            $port = & $GetPortName $id
            if ($port) { $g.ComPort = $port; break }
        }
    }
    [pscustomobject]$g
}

# ---------------------------------------------------------- final class ----
# Evidence ladder kept separate (FS-R-004 §5): handoff, gadget (this attempt
# reached enumeration), stages (from a verified record), command execution,
# holding state. Timing-only observations never upgrade a class.
function Get-FsOutcome {
    param([string]$Handoff, [bool]$GadgetNonceSeen, $Session, [string]$TimingHint)
    if ($Handoff -eq 'DEVICE_REJECTED') { return 'DEVICE_REJECTED' }
    # A verified nonce challenge proves our init executed, whatever the fastboot
    # status read said; the handoff class is still reported separately.
    if ($Session -and $Session.Verified) { return 'PASS' }
    if ($GadgetNonceSeen) { return 'TRANSPORT/SHELL FAILURE' }
    return 'INCONCLUSIVE'
}

# --------------------------------------------------------- attempt lock ----
# Atomic one-attempt guard (adversarial host review, finding 2): a per-nonce
# marker in a shared ledger directory (so a copied image with the same nonce is
# refused) plus a per-directory lock, both created with CreateNew.
function Register-FsAttempt {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Nonce,
          [Parameter(Mandatory)][string]$LedgerDir, [string]$Note = '')
    $null = New-Item -ItemType Directory -Force -Path $LedgerDir
    $made = @()
    foreach ($f in @((Join-Path $LedgerDir "$Nonce.attempted"), (Join-Path $Dir 'attempt.lock'))) {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($f, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $made += $f                                   # the marker exists from here on
            $w = New-Object System.IO.StreamWriter($fs); $fs = $null   # the writer owns the stream
            try { $w.WriteLine("$((Get-Date).ToUniversalTime().ToString('o')) $Note") } finally { $w.Dispose() }
        } catch {
            $why = "registration failed at $f ($($_.Exception.Message))"
            if ($made.Count -gt 0) { $why += '; already created: ' + ($made -join ', ') + ' (this nonce is now consumed; nothing was booted)' }
            return [pscustomobject]@{ Ok = $false; Reason = $why; Files = $made }
        } finally { if ($fs) { $fs.Dispose() } }
    }
    [pscustomobject]@{ Ok = $true; Reason = 'registered'; Files = $made }
}
function Test-FsAttemptFree {
    param([string]$Dir, [string]$Nonce, [string]$LedgerDir)
    -not ((Test-Path (Join-Path $LedgerDir "$Nonce.attempted")) -or (Test-Path (Join-Path $Dir 'attempt.lock')))
}
