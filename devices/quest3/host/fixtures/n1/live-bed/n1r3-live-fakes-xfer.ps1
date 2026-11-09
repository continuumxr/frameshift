# FrameShift N1 r3 - THE LIVE-PATH TEST BED, PC-side part (test-host-n1.ps1 section LV). TEST ONLY.
#
# NEVER loaded by a shipped host file. Section LV appends ONE line to a temporary COPY of fs-xfer-n1.ps1 that
# dot-sources this file, so it is loaded wherever that copy is: in the collector, and in the collector's background
# runspace (Start-FsN1XferJob loads the copy beside the collector copy). Invoke-FsN1XferSession, Start-FsN1XferJob and
# Wait-FsN1XferJob run as shipped. Replaced:
#   Find-FsN1Adapter   the PnP and network-adapter tables -> a LOOPBACK ADAPTER STAND-IN with the bed's timing
#                      (n1r3-live-fakes.ps1, fix/n1-linklocal): "no device yet" until AdapterAfterMs after the bed
#                      loaded, then one Up adapter under USB\VID_1D6B&PID_0104\FS-<nonce> whose address is Tentative
#                      for TentativeMs, then Preferred; the FIRST lookup costs FirstLookupDelayMs
#   Invoke-FsN1Xfer    after asserting that it got the LIVE arguments (fe80::<nonce>, the stand-in's ifIndex 1, port
#                      47201, mode ok, not a fixture), the real client, sent to [::1]:<that port> as a FIXTURE (Fixture = true in xfer.json: the
#                      classifier never binds a test-bed result), instead of fe80::<nonce>%<ifIndex>:47201
function Find-FsN1Adapter {
    param([Parameter(Mandatory)][string]$Nonce, [scriptblock]$ListDevices, [scriptblock]$GetChildren, [scriptblock]$ListAdapters, [scriptblock]$GetDriver, [scriptblock]$GetLinkLocal)
    $ids = Get-FsN1Ids $Nonce
    $tm = @([string][AppDomain]::CurrentDomain.GetData('n1r3.bed.timing') -split ',' | ForEach-Object { [long]$_ })
    $n = [int][AppDomain]::CurrentDomain.GetData('n1r3.bed.lookups') + 1; [AppDomain]::CurrentDomain.SetData('n1r3.bed.lookups', $n)
    $goneAtStart = ($true -eq [AppDomain]::CurrentDomain.GetData('n1r3.bed.gone'))
    if ($n -eq 1 -and $tm[2] -gt 0) { Start-Sleep -Milliseconds $tm[2] }
    $goneAtEnd = ($true -eq [AppDomain]::CurrentDomain.GetData('n1r3.bed.gone'))
    $now = [DateTime]::UtcNow.Ticks
    $el = ($now - [long][AppDomain]::CurrentDomain.GetData('n1r3.bed.t0')) / 10000
    $r = [ordered]@{ Nonce = $Nonce; Utc = (Get-FsN1UtcText); Parent = $null; Serials = @(); Adapter = $null; Driver = $null; HostLinkLocal = @()
                     MacExpected = $ids.HostMac; MacMatches = $false; DeviceAddress = $ids.LinkLocal; Refusal = $null }
    # the device left the bus (fs-done): a lookup that began after it sees no device; a slow lookup that straddled it saw
    # the parent and the Up adapter first and an empty address table last (the r3 live xfer.json: "... yet ()")
    if ($goneAtStart -or ($el -lt $tm[0])) {
        $r.Refusal = if ($goneAtStart) { "no USB\VID_1D6B&PID_0104\$($ids.Serial) device present (test bed: the device left at fs-done)" } else { "no USB\VID_1D6B&PID_0104\$($ids.Serial) device present (test bed: the adapter appears at +$($tm[0]) ms)" }
        return [pscustomobject]$r }
    if ($goneAtEnd) {
        $r.Parent = "USB\VID_1D6B&PID_0104\$($ids.Serial)"; $r.Serials = @($ids.Serial)
        $r.Adapter = [pscustomobject]@{ IfIndex = 1; Name = 'n1r3 test bed'; Description = 'TEST BED loopback stand-in (::1)'; Mac = $ids.HostMac; Status = 'Up'; PnpId = 'TESTBED\N1R3\0' }
        $r.Driver = [pscustomobject]@{ Service = 'TESTBED'; InfPath = 'none'; DriverVersion = 'none'; DriverProvider = 'test bed' }
        $r.MacMatches = $true; $r.Refusal = 'adapter ifIndex 1 has no preferred IPv6 link-local address yet ()'
        return [pscustomobject]$r }
    $r.Parent = "USB\VID_1D6B&PID_0104\$($ids.Serial)"; $r.Serials = @($ids.Serial)
    $r.Adapter = [pscustomobject]@{ IfIndex = 1; Name = 'n1r3 test bed'; Description = 'TEST BED loopback stand-in (::1)'; Mac = $ids.HostMac; Status = 'Up'; PnpId = 'TESTBED\N1R3\0' }
    $r.Driver = [pscustomobject]@{ Service = 'TESTBED'; InfPath = 'none'; DriverVersion = 'none'; DriverProvider = 'test bed' }
    $r.MacMatches = $true
    # LV7 (test-only correction, FS-A-021): the Tentative window starts at the FIRST lookup that sees the present adapter (its read time $now),
    # not at the bed's load, so the client's first view is Tentative whatever the CPU load (TentativeMs is unchanged).
    if ($null -eq [AppDomain]::CurrentDomain.GetData('n1r3.bed.tent0')) { [AppDomain]::CurrentDomain.SetData('n1r3.bed.tent0', [long]$now) }
    if ($now -lt [long][AppDomain]::CurrentDomain.GetData('n1r3.bed.tent0') + $tm[1] * 10000) { $r.HostLinkLocal = @('::1 Tentative'); $r.Refusal = "adapter ifIndex 1 has no preferred IPv6 link-local address yet (::1 Tentative)"; return [pscustomobject]$r }
    $r.HostLinkLocal = @('::1 Preferred')
    [pscustomobject]$r
}
${function:Invoke-FsN1XferReal} = ${function:Invoke-FsN1Xfer}
function Invoke-FsN1Xfer {
    param([Parameter(Mandatory)][string]$Nonce, [Parameter(Mandatory)][string]$Chal, [Parameter(Mandatory)][string]$Address, [int]$ScopeId = 0,
          [int]$Port = 47201, [long]$WindowMs = 60000, [int]$ConnectTimeoutMs = 2500, [int]$RetryMs = 250, [int]$IoTimeoutMs = 20000,
          [string]$Mode = 'ok', [string]$Client = 'devices/quest3/host/fs-xfer-n1.ps1', [bool]$Fixture = $false,
          $Adapter = $null, [string]$ExpectedD2hSha = '', $Sync = $null, $DeadlineUtc = $null)
    # the live arguments Invoke-FsN1XferSession passed must be exactly the live session's (the shipped guard would accept
    # them), checked BEFORE the bed substitutes its loopback target
    $ids = Get-FsN1Ids $Nonce
    if ($Address -cne $ids.LinkLocal -or $ScopeId -ne 1 -or $Port -ne 47201 -or $Mode -cne 'ok' -or $Fixture -or $Client -cne 'devices/quest3/host/fs-xfer-n1.ps1') {
        throw "test bed: the PC side did not call the client with the live arguments (address $Address, scope $ScopeId, port $Port, mode $Mode, fixture $Fixture)" }
    $p = @{} + $PSBoundParameters
    $p.Address = '::1'; $p.ScopeId = 0; $p.Port = [int][AppDomain]::CurrentDomain.GetData('n1r3.bed.port'); $p.Fixture = $true
    Invoke-FsN1XferReal @p
}
