# FrameShift N1 r3 - THE LIVE-PATH TEST BED, PC-side part (test-host-n1.ps1 section LV). TEST ONLY.
#
# NEVER loaded by a shipped host file. Section LV appends ONE line to a temporary COPY of fs-xfer-n1.ps1 that
# dot-sources this file, so it is loaded wherever that copy is: in the collector, and in the collector's background
# runspace (Start-FsN1XferJob loads the copy beside the collector copy). Invoke-FsN1XferSession, Start-FsN1XferJob and
# Wait-FsN1XferJob run as shipped. Replaced:
#   Find-FsN1Adapter   the PnP and network-adapter tables -> a LOOPBACK ADAPTER STAND-IN: "no device yet" until the fake
#                      device's xfer step listens (its port in the AppDomain), then one Up adapter with a preferred
#                      address under USB\VID_1D6B&PID_0104\FS-<nonce>
#   Invoke-FsN1Xfer    after asserting that it got the LIVE arguments (fe80::<nonce>, the stand-in's ifIndex 1, port
#                      47201, mode ok, not a fixture), the real client, sent to [::1]:<that port> as a FIXTURE (Fixture = true in xfer.json: the
#                      classifier never binds a test-bed result), instead of fe80::<nonce>%<ifIndex>:47201
function Find-FsN1Adapter {
    param([Parameter(Mandatory)][string]$Nonce, [scriptblock]$ListDevices, [scriptblock]$GetChildren, [scriptblock]$ListAdapters, [scriptblock]$GetDriver, [scriptblock]$GetLinkLocal)
    $ids = Get-FsN1Ids $Nonce
    $port = [AppDomain]::CurrentDomain.GetData('n1r3.bed.port')
    $r = [ordered]@{ Nonce = $Nonce; Utc = (Get-FsN1UtcText); Parent = $null; Serials = @(); Adapter = $null; Driver = $null; HostLinkLocal = @()
                     MacExpected = $ids.HostMac; MacMatches = $false; DeviceAddress = $ids.LinkLocal; Refusal = $null }
    if ($null -eq $port) { $r.Refusal = "no USB\VID_1D6B&PID_0104\$($ids.Serial) device present (test bed: the fake device's xfer step does not listen yet)"; return [pscustomobject]$r }
    $r.Parent = "USB\VID_1D6B&PID_0104\$($ids.Serial)"; $r.Serials = @($ids.Serial)
    $r.Adapter = [pscustomobject]@{ IfIndex = 1; Name = 'n1r3 test bed'; Description = 'TEST BED loopback stand-in (::1)'; Mac = $ids.HostMac; Status = 'Up'; PnpId = 'TESTBED\N1R3\0' }
    $r.Driver = [pscustomobject]@{ Service = 'TESTBED'; InfPath = 'none'; DriverVersion = 'none'; DriverProvider = 'test bed' }
    $r.MacMatches = $true; $r.HostLinkLocal = @('::1 Preferred')
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
