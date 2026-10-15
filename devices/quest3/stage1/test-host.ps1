# FrameShift stage-1 host-only fixtures (Windows PowerShell 5.1). No device.
# Exercises every acceptance rule in fs-proto.ps1 with positive and negative
# cases (FS-R-004 §2-§3, §5). Exit code 0 only if every check passes.
. (Join-Path $PSScriptRoot 'fs-proto.ps1')
$ErrorActionPreference = 'Stop'      # deliberately strict: the wrapper must cope
$N  = '85f367d0157d5990'; $K = '5.10.198-01402-g1c5986fe21ee'; $P1 = '/bin/busybox,sh,/init'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++; Write-Host "PASS  $name" } else { $script:fail++; Write-Host "FAIL  $name" }
}
function Rec($nonce, $resp, $kernel, $pid1) { "FSV1 nonce=$nonce resp=$resp kernel=$kernel pid1=$pid1 stages=INIT_STARTED,SHELL_READY END" }

Write-Host "== A. record acceptance (Test-FsVerify / Test-FsAck) =="
$ch = New-FsHex 16; $good = Get-FsExpectedResponse -Nonce $N -Challenge $ch
Check 'A1 positive: complete record, all fields match'      (Test-FsVerify -Text (Rec $N $good $K $P1) -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok
Check 'A2 echo-only output cannot pass'                       (-not (Test-FsVerify -Text "fs-verify $ch`n" -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)
Check 'A3 wrong nonce cannot pass'                            (-not (Test-FsVerify -Text (Rec 'ffffffffffffffff' $good $K $P1) -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)
Check 'A4 wrong PID 1 cannot pass'                            (-not (Test-FsVerify -Text (Rec $N $good $K '/sbin/init') -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)
Check 'A5 wrong kernel cannot pass'                           (-not (Test-FsVerify -Text (Rec $N $good '6.18.0' $P1) -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)
Check 'A6 response = challenge (echoed) cannot pass'          (-not (Test-FsVerify -Text (Rec $N $ch $K $P1) -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)
Check 'A7 incomplete record (no END) cannot pass'             (-not (Test-FsVerify -Text ((Rec $N $good $K $P1) -replace ' END$','') -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)
Check 'A8 truncated record cannot pass'                       (-not (Test-FsVerify -Text (Rec $N $good $K $P1).Substring(0, 40) -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)
Check 'A9 record embedded after other text cannot pass'       (-not (Test-FsVerify -Text ('echo ' + (Rec $N $good $K $P1)) -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)
Check 'A10 CRLF line ending still parses (positive)'          (Test-FsVerify -Text ((Rec $N $good $K $P1) + "`r`n") -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok
Check 'A11 echo + correct record in same buffer passes'       (Test-FsVerify -Text ("fs-verify $ch`n" + (Rec $N $good $K $P1) + "`n") -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok
$ack = New-FsHex 8
Check 'A12 ack positive'                                      (Test-FsAck -Text "FSS1 nonce=$N stages=SHELL_READY,HOST_ACK acked=$ack END" -Nonce $N -AckToken $ack).Ok
Check 'A13 ack without HOST_ACK stage cannot confirm'         (-not (Test-FsAck -Text "FSS1 nonce=$N stages=SHELL_READY acked=$ack END" -Nonce $N -AckToken $ack).Ok)
Check 'A14 ack with other token cannot confirm'               (-not (Test-FsAck -Text "FSS1 nonce=$N stages=SHELL_READY,HOST_ACK acked=deadbeef END" -Nonce $N -AckToken $ack).Ok)
Check 'A15 echoed fs-ack command cannot confirm'              (-not (Test-FsAck -Text "fs-ack $ack`n" -Nonce $N -AckToken $ack).Ok)
Check 'A16 lowercase tag is not a record (case-sensitive)'    (-not (Test-FsVerify -Text ((Rec $N $good $K $P1) -creplace '^FSV1', 'fsv1') -Nonce $N -Challenge $ch -Kernel $K -Pid1 $P1).Ok)

Write-Host "== B. sessions over fake transports =="
function New-FakeDevice([string]$mode) {
    $d = [pscustomobject]@{ Mode = $mode; Out = ''; Stages = 'INIT_STARTED,MODULES_READY,ACM_SETUP_ATTEMPTED,UDC_BOUND,SHELL_READY'; Acked = 'none'; Reads = 0 }
    $d | Add-Member ScriptMethod Write {
        param($s)
        if ($this.Mode -eq 'disconnect-write') { throw 'device disconnected (write)' }
        if ($this.Mode -eq 'echo') { $this.Out += $s; return }
        if ($this.Mode -eq 'silent') { return }
        if ($s -match '^fs-verify ([0-9a-f]+)') {
            $r = Get-FsExpectedResponse -Nonce $N -Challenge $Matches[1]
            $this.Out += "FSV1 nonce=$N resp=$r kernel=$K pid1=$P1 stages=$($this.Stages) END`n"
        } elseif ($s -match '^fs-ack ([0-9a-f]+)') {
            if ($this.Mode -ne 'no-ack') { $this.Acked = $Matches[1]; $this.Stages += ',HOST_ACK' }
            $this.Out += "FSA1 queued END`n"
        } elseif ($s -match '^fs-status') {
            $this.Out += "FSS1 nonce=$N stages=$($this.Stages) acked=$($this.Acked) END`n"
        }
    }
    $d | Add-Member ScriptMethod ReadAvailable {
        $this.Reads++
        if ($this.Mode -eq 'disconnect-read') { throw 'device disconnected (read)' }
        if ($this.Mode -eq 'disconnect-after-verify' -and $this.Reads -gt 1) { throw 'device disconnected (read)' }
        if ($this.Mode -eq 'split' -and $this.Out.Length -gt 10) {
            $h = [int]($this.Out.Length / 2); $x = $this.Out.Substring(0, $h); $this.Out = $this.Out.Substring($h); return $x
        }
        $x = $this.Out; $this.Out = ''; return $x
    }
    $d
}
$far = (Get-FsMs) + 600000
$s = Invoke-FsSession -Transport (New-FakeDevice 'good') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs $far -StepTimeoutMs 3000
Check 'B1 positive device: verified and host-ack confirmed'   ($s.Verified -and $s.Acked -and -not $s.Error)
$s = Invoke-FsSession -Transport (New-FakeDevice 'split') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs $far -StepTimeoutMs 3000
Check 'B2 record split across reads: verified'                ($s.Verified)
$s = Invoke-FsSession -Transport (New-FakeDevice 'echo') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs $far -StepTimeoutMs 2000
Check 'B3 echo-only device: NOT verified'                     (-not $s.Verified -and -not $s.Acked)
$t0 = Get-FsMs
$s = Invoke-FsSession -Transport (New-FakeDevice 'silent') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs $far -StepTimeoutMs 2000
Check 'B4 silent device: NOT verified, returns in bounded time' (-not $s.Verified -and ((Get-FsMs) - $t0) -lt 6000)
$s = Invoke-FsSession -Transport (New-FakeDevice 'disconnect-write') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs $far -StepTimeoutMs 2000
Check 'B5 disconnect on write: error recorded, NOT verified'  (-not $s.Verified -and $s.Error -like '*disconnected*')
$s = Invoke-FsSession -Transport (New-FakeDevice 'disconnect-read') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs $far -StepTimeoutMs 2000
Check 'B6 disconnect before reply: error recorded, NOT verified'   (-not $s.Verified -and $s.Error -like '*disconnected*')
$s = Invoke-FsSession -Transport (New-FakeDevice 'good') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs ((Get-FsMs) - 1) -StepTimeoutMs 2000
Check 'B7 correct reply after PASS deadline: NOT verified'    (-not $s.Verified -and $s.VerifyReason -like '*deadline*')
$s = Invoke-FsSession -Transport (New-FakeDevice 'no-ack') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs $far -StepTimeoutMs 2000
Check 'B8 verified but PID 1 never records ack: acked=false'  ($s.Verified -and -not $s.Acked)
$s = Invoke-FsSession -Transport (New-FakeDevice 'disconnect-after-verify') -Nonce $N -Kernel $K -Pid1 $P1 -PassDeadlineMs $far -StepTimeoutMs 2000
Check 'B9 disconnect during ack phase: verified, NOT acked, error' ($s.Verified -and -not $s.Acked -and $s.Error -like '*disconnected*')

Write-Host "== C. native command wrapper (ErrorActionPreference=Stop in scope) =="
$r = Invoke-FsNative -Exe 'cmd.exe' -ArgList @('/c', 'echo Sending boot.img & echo OKAY [ 0.1s] 1>&2 & exit /b 0') -TimeoutMs 10000
Check 'C1 stderr status + rc 0: captured, no exception, HANDOFF_ACKNOWLEDGED' ($r.ExitCode -eq 0 -and $r.StdErr -like '*OKAY*' -and (Get-FsHandoffClass $r) -eq 'HANDOFF_ACKNOWLEDGED')
$t0 = Get-FsMs
$r = Invoke-FsNative -Exe 'powershell.exe' -ArgList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -TimeoutMs 1500
Check 'C2 hung process: killed at timeout, INCONCLUSIVE'      ($r.TimedOut -and ((Get-FsMs) - $t0) -lt 10000 -and (Get-FsHandoffClass $r) -eq 'INCONCLUSIVE')
$r = Invoke-FsNative -Exe 'cmd.exe' -ArgList @('/c', "echo FAILED (remote: 'unknown command') 1>&2 & exit /b 1") -TimeoutMs 10000
Check 'C3 explicit device refusal: DEVICE_REJECTED'           ((Get-FsHandoffClass $r) -eq 'DEVICE_REJECTED')
$r = Invoke-FsNative -Exe 'cmd.exe' -ArgList @('/c', 'echo FAILED (Write to device failed (no link)) 1>&2 & exit /b 1') -TimeoutMs 10000
Check 'C4 link failure: INCONCLUSIVE, not rejected'           ((Get-FsHandoffClass $r) -eq 'INCONCLUSIVE')
$r = Invoke-FsNative -Exe 'C:\definitely\missing\fastboot.exe' -ArgList @('devices') -TimeoutMs 5000
Check 'C5 missing executable: error captured, INCONCLUSIVE'   ($r.Error -and (Get-FsHandoffClass $r) -eq 'INCONCLUSIVE')
$r = Invoke-FsNative -Exe 'cmd.exe' -ArgList @('/c', 'echo OKAY 1>&2 & echo FAILED (remote: oops) & exit /b 0') -TimeoutMs 10000
Check 'C6 rc 0 but FAILED in output: not acknowledged'        ((Get-FsHandoffClass $r) -ne 'HANDOFF_ACKNOWLEDGED')

$r = Invoke-FsNative -Exe 'cmd.exe' -ArgList @('/c', 'exit /b 0') -TimeoutMs 10000
Check 'C7 rc 0 with no output at all: INCONCLUSIVE (no positive evidence)' ((Get-FsHandoffClass $r) -eq 'INCONCLUSIVE')
$r = Invoke-FsNative -Exe 'cmd.exe' -ArgList @('/c', 'echo note: previous attempt failed 1>&2 & echo Booting OKAY 1>&2 & exit /b 0') -TimeoutMs 10000
Check 'C8 lowercase "failed" + OKAY + rc 0: HANDOFF_ACKNOWLEDGED' ((Get-FsHandoffClass $r) -eq 'HANDOFF_ACKNOWLEDGED')
$r = Invoke-FsNative -Exe 'cmd.exe' -ArgList @('/c', 'echo Booting FAILED (Status read failed (Too many links)) 1>&2 & exit /b 1') -TimeoutMs 10000
Check 'C9 status read failed after Booting: INCONCLUSIVE, not rejected' ((Get-FsHandoffClass $r) -eq 'INCONCLUSIVE')
$fq = Get-FsFastbootSerials -FastbootExe 'C:\definitely\missing\fastboot.exe' -TimeoutMs 3000
Check 'C10 failed fastboot query reports Ok=false (absence is not evidence)' (-not $fq.Ok)

Write-Host "== D. serial transport configuration (no port needed) =="
$tr = New-FsSerialTransport -PortName 'COM250'
Check 'D1 handshake explicitly None'                          ($tr.Port.Handshake -eq [System.IO.Ports.Handshake]::None)
Check 'D2 DTR and RTS explicitly asserted'                    ($tr.Port.DtrEnable -and $tr.Port.RtsEnable)
Check 'D3 read/write timeouts bounded (not infinite)'         ($tr.Port.ReadTimeout -eq 500 -and $tr.Port.WriteTimeout -eq 2000)
$opened = $true; try { $tr.Open() } catch { $opened = $false }
Check 'D4 nonexistent port: open fails cleanly'               (-not $opened)
$disposed = $true; try { $tr.Dispose() } catch { $disposed = $false }
Check 'D5 dispose after failed open does not throw'           ($disposed)

Write-Host "== E. gadget association by nonce =="
$parent = "USB\VID_1D6B&PID_0104\FS-$N"; $child = 'USB\VID_1D6B&PID_0104&MI_00\6&1A2B3C&0&0000'
$list = { @('PCI\VEN_8086&DEV_1234\x', $parent, $child) }.GetNewClosure()
$kids = { param($id) if ($id -eq $parent) { @($child) } else { @() } }.GetNewClosure()
$port = { param($id) if ($id -eq $child) { 'COM7' } else { $null } }.GetNewClosure()
$g = Get-FsGadget -Nonce $N -ListDevices $list -GetChildren $kids -GetPortName $port
Check 'E1 our gadget: serial ok, COM port found on child'     ($g.SerialOk -and $g.ComPort -eq 'COM7')
$bad = "USB\VID_1D6B&PID_0104\FS-ffffffffffffffff"
$g = Get-FsGadget -Nonce $N -ListDevices ({ @($bad) }.GetNewClosure()) -GetChildren $kids -GetPortName ({ param($id) 'COM9' })
Check 'E2 wrong serial: no association, no port'              ($g.Present -and -not $g.SerialOk -and -not $g.ComPort)
$g = Get-FsGadget -Nonce $N -ListDevices ({ @($bad, $parent, $child) }.GetNewClosure()) -GetChildren $kids -GetPortName $port
Check 'E3 two gadgets: picks the nonce-bearing one'           ($g.SerialOk -and $g.ComPort -eq 'COM7')
$upper = "USB\VID_1D6B&PID_0104\FS-$($N.ToUpper())"
$g = Get-FsGadget -Nonce $N -ListDevices ({ @($upper) }.GetNewClosure()) -GetChildren ({ param($id) @() }) -GetPortName ({ param($id) 'COM3' })
Check 'E4 instance ID uppercased by Windows still matches'    ($g.SerialOk -and $g.ComPort -eq 'COM3')

$g = Get-FsGadget -Nonce $N -ListDevices ({ @("USB\VID_1D6B&PID_0104\FS-$N") }.GetNewClosure())
Check 'E5 default PnP/registry lookups on an absent instance: no throw under Stop/StrictMode' ($g.SerialOk -and -not $g.ComPort)

Write-Host "== F. outcome classes =="
$v = [pscustomobject]@{ Verified = $true }; $nv = [pscustomobject]@{ Verified = $false }
Check 'F1 rejected handoff stays DEVICE_REJECTED'             ((Get-FsOutcome -Handoff 'DEVICE_REJECTED' -GadgetNonceSeen $true -Session $v) -eq 'DEVICE_REJECTED')
Check 'F2 uncertain handoff stays INCONCLUSIVE'               ((Get-FsOutcome -Handoff 'INCONCLUSIVE' -GadgetNonceSeen $false -Session $null) -eq 'INCONCLUSIVE')
Check 'F3 verified session: PASS'                             ((Get-FsOutcome -Handoff 'HANDOFF_ACKNOWLEDGED' -GadgetNonceSeen $true -Session $v) -eq 'PASS')
Check 'F4 nonce gadget, no verification: TRANSPORT/SHELL'     ((Get-FsOutcome -Handoff 'HANDOFF_ACKNOWLEDGED' -GadgetNonceSeen $true -Session $nv) -eq 'TRANSPORT/SHELL FAILURE')
Check 'F5 timing hint only: INCONCLUSIVE'                     ((Get-FsOutcome -Handoff 'HANDOFF_ACKNOWLEDGED' -GadgetNonceSeen $false -Session $null -TimingHint 'fastboot returned at 200s') -eq 'INCONCLUSIVE')

Check 'F6 uncertain handoff but verified challenge: PASS'   ((Get-FsOutcome -Handoff 'INCONCLUSIVE' -GadgetNonceSeen $true -Session $v) -eq 'PASS')
Check 'F7 uncertain handoff, nonce gadget, no verify: TRANSPORT/SHELL' ((Get-FsOutcome -Handoff 'INCONCLUSIVE' -GadgetNonceSeen $true -Session $nv) -eq 'TRANSPORT/SHELL FAILURE')

Write-Host "== G. one-attempt lock =="
$tmp = Join-Path $env:TEMP ("fs-lock-" + (New-FsHex 4)); $L = Join-Path $tmp 'ledger'
$d1 = Join-Path $tmp 'a'; $d2 = Join-Path $tmp 'b'; $d3 = Join-Path $tmp 'c'
New-Item -ItemType Directory -Force -Path $d1, $d2, $d3 | Out-Null
Check 'G1 first registration succeeds'                        (Register-FsAttempt -Dir $d1 -Nonce $N -LedgerDir $L).Ok
Check 'G2 same directory again: refused'                      (-not (Register-FsAttempt -Dir $d1 -Nonce $N -LedgerDir $L).Ok)
Check 'G3 copied image (same nonce, new directory): refused'  (-not (Register-FsAttempt -Dir $d2 -Nonce $N -LedgerDir $L).Ok)
Check 'G4 fresh nonce in a new directory: allowed'            (Register-FsAttempt -Dir $d3 -Nonce 'aaaaaaaaaaaaaaaa' -LedgerDir $L).Ok
Check 'G5 freshness probe sees the used nonce'                (-not (Test-FsAttemptFree -Dir $d2 -Nonce $N -LedgerDir $L))
$r6 = Register-FsAttempt -Dir (Join-Path $tmp 'missing') -Nonce 'bbbbbbbbbbbbbbbb' -LedgerDir $L   # lock cannot be created
Check 'G6 partial registration: refused, reason says the nonce is consumed' (-not $r6.Ok -and $r6.Reason -like '*now consumed*' -and -not (Test-FsAttemptFree -Dir $d3 -Nonce 'bbbbbbbbbbbbbbbb' -LedgerDir $L))
Remove-Item -Recurse -Force $tmp

Write-Host "== H. observer pre-boot gates (scratch replica, fastboot/adb replaced by a nonexistent path) =="
# The replica is host-observe.ps1 with ONLY the two tool paths replaced; it is
# run only if no real tool path survives the replacement.
$rt = Join-Path $env:TEMP ("fs-obs-" + (New-FsHex 4))
$rs = Join-Path $rt 'devices\quest3\stage1'; $ad = Join-Path $rt 'att'
New-Item -ItemType Directory -Force -Path $rs, $ad | Out-Null
$src = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'host-observe.ps1'))
$noexe = Join-Path $rt 'no-such-dir\none.exe'
$obs = $src.Replace("'C:\platform-tools\fastboot.exe'", "'$noexe'").Replace("'C:\platform-tools\adb.exe'", "'$noexe'")
$safe = ($obs -notmatch 'platform-tools') -and ($obs -ne $src)
Check 'H0 replica contains no real fastboot/adb path'         $safe
if ($safe) {
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText((Join-Path $rs 'host-observe.ps1'), $obs, $utf8)
    Copy-Item (Join-Path $PSScriptRoot 'fs-proto.ps1') $rs
    $ini = Join-Path $rs 'init.sh'; [System.IO.File]::WriteAllText($ini, "#!/bin/busybox sh`n# replica`n")
    $img = Join-Path $ad 'boot-stage1.img'; [System.IO.File]::WriteAllBytes($img, [byte[]](1..255))
    $on = 'cccccccccccccccc'
    $sha = { param($f) (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLower() }
    $man = @("nonce: $on",
             "stock boot:  x.img sha256=49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50",
             "stock vboot: y.img sha256=1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf",
             "init.sh source: sha256=$(& $sha $ini)",
             "OUTPUT IMAGE: boot-stage1.img sha256=$(& $sha $img)") -join "`n"
    $mf = Join-Path $ad 'MANIFEST.txt'; [System.IO.File]::WriteAllText($mf, $man)
    function Invoke-Replica([string[]]$more) {
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $rs 'host-observe.ps1') -Image $img @more
        $LASTEXITCODE
    }
    Check 'H1 healthy replica: preflight OK (exit 0)'           ((Invoke-Replica @('-Preflight')) -eq 0)
    Move-Item $ini "$ini.away"
    Check 'H2 init.sh unreadable/missing: ABORT (exit 2), not skipped' ((Invoke-Replica @('-Preflight')) -eq 2)
    Move-Item "$ini.away" $ini
    $hold = [System.IO.File]::Open($img, 'Open', 'Read', 'None')
    try { $rc = Invoke-Replica @('-Preflight') } finally { $hold.Dispose() }
    Check 'H3 image cannot be hashed: ABORT (exit 2), not skipped' ($rc -eq 2)
    [System.IO.File]::WriteAllText($mf, (($man -split "`n") | Where-Object { $_ -notlike 'init.sh source:*' }) -join "`n")
    Check 'H4 manifest without init.sh binding: ABORT (exit 2)' ((Invoke-Replica @('-Preflight')) -eq 2)
    [System.IO.File]::WriteAllText($mf, $man)
    $before = @(Get-ChildItem $ad).Count
    Check 'H5 no sign-off: exit 3 and nothing written'          (((Invoke-Replica @()) -eq 3) -and @(Get-ChildItem $ad).Count -eq $before)
    $rc = Invoke-Replica @('-ConfirmNonce', $on)
    $ledgerHit = Test-Path (Join-Path $rt "build\stage1\attempted\$on.attempted")
    Check 'H6 signed off, no fastboot device: ABORT before registration' ($rc -eq 2 -and -not $ledgerHit -and -not (Test-Path (Join-Path $ad 'attempt.lock')))
    Check 'H7 that abort leaves precheck-*.log, no observe-*.log' (@(Get-ChildItem $ad -Filter 'precheck-*.log').Count -ge 1 -and @(Get-ChildItem $ad -Filter 'observe-*.log').Count -eq 0)
    Check 'H8 directory not consumed: preflight still OK'       ((Invoke-Replica @('-Preflight')) -eq 0)
}
Remove-Item -Recurse -Force $rt

Write-Host "== I. observer after registration (scratch replica, FAKE fastboot, adb absent) =="
# A replica of host-observe.ps1 runs a full attempt against a fake fastboot.exe
# compiled here (it answers `devices` with the expected serial and acknowledges
# `boot`, recording every call). One fault is injected per case; observation
# must continue, end in an OUTCOME line, and the boot command must run once.
$it = Join-Path $env:TEMP ("fs-obsI-" + (New-FsHex 4))
$fakeDir = Join-Path $it 'fake'; New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
$fake = Join-Path $fakeDir 'fake-fastboot.exe'
Add-Type -OutputAssembly $fake -OutputType ConsoleApplication -TypeDefinition @'
using System; using System.IO;
public static class FakeFastboot {
    public static int Main(string[] a) {
        string d = AppDomain.CurrentDomain.BaseDirectory;
        File.AppendAllText(Path.Combine(d, "calls.txt"), string.Join(" ", a) + Environment.NewLine);
        if (a.Length == 1 && a[0] == "devices") { Console.WriteLine("QUEST3UNIT1\tfastboot"); return 0; }
        if (Array.IndexOf(a, "boot") >= 0) {
            Console.Error.WriteLine("Sending 'boot.img' (1 KB)    OKAY [  0.001s]");
            Console.Error.WriteLine("Booting                      OKAY [  0.001s]");
            Console.Error.WriteLine("Finished. Total time: 0.002s");
            return 0;
        }
        return 1;
    }
}
'@
function New-ObsReplica([string]$Root, [string]$Inject, [string]$Nonce) {
    $rs = Join-Path $Root 'devices\quest3\stage1'; $ad = Join-Path $Root 'att'
    New-Item -ItemType Directory -Force -Path $rs, $ad | Out-Null
    $src = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'host-observe.ps1'))
    $noexe = Join-Path $Root 'no-such-dir\none.exe'
    $anchor = ". (Join-Path `$PSScriptRoot 'fs-proto.ps1')"
    $obs = $src.Replace("'C:\platform-tools\fastboot.exe'", "'$fake'").Replace("'C:\platform-tools\adb.exe'", "'$noexe'")
    $obs = $obs.Replace($anchor, $anchor + "`n" + $Inject)
    $safe = ($obs -notmatch 'platform-tools') -and $obs.Contains($Inject) -and $obs.Contains("'$fake'")
    if ($safe) {
        [System.IO.File]::WriteAllText((Join-Path $rs 'host-observe.ps1'), $obs, (New-Object System.Text.UTF8Encoding($true)))
        Copy-Item (Join-Path $PSScriptRoot 'fs-proto.ps1') $rs
        $ini = Join-Path $rs 'init.sh'; [System.IO.File]::WriteAllText($ini, "#!/bin/busybox sh`n# replica`n")
        $img = Join-Path $ad 'boot-stage1.img'; [System.IO.File]::WriteAllBytes($img, [byte[]](1..255))
        $man = @("nonce: $Nonce",
                 "stock boot:  x.img sha256=49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50",
                 "stock vboot: y.img sha256=1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf",
                 "init.sh source: sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $ini).Hash.ToLower())",
                 "OUTPUT IMAGE: boot-stage1.img sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $img).Hash.ToLower())") -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $ad 'MANIFEST.txt'), $man)
    }
    [pscustomobject]@{ Safe = $safe; Script = (Join-Path $rs 'host-observe.ps1'); Img = (Join-Path $ad 'boot-stage1.img'); Att = $ad; Nonce = $Nonce }
}
function Invoke-ObsCase($rep) {
    Remove-Item (Join-Path $fakeDir 'calls.txt') -ErrorAction SilentlyContinue
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rep.Script -Image $rep.Img -ConfirmNonce $rep.Nonce -TotalSec 12 -PassWindowSec 4
    $rc = $LASTEXITCODE
    $logf = @(Get-ChildItem $rep.Att -Filter 'observe-*.log')
    $text = ''; if ($logf.Count -eq 1) { $text = [System.IO.File]::ReadAllText($logf[0].FullName) }
    $calls = @(); $cf = Join-Path $fakeDir 'calls.txt'; if (Test-Path $cf) { $calls = @(Get-Content $cf) }
    $bootIdx = -1; for ($k = 0; $k -lt $calls.Count; $k++) { if ($calls[$k] -match '\bboot\b') { $bootIdx = $k } }
    $boots = @($calls | Where-Object { $_ -match '\bboot\b' }).Count
    $after = 0; if ($bootIdx -ge 0) { $after = @($calls[($bootIdx + 1)..($calls.Count)] | Where-Object { $_ -eq 'devices' }).Count }
    [pscustomobject]@{ Rc = $rc; Log = $text; Boots = $boots; DevicesAfterBoot = $after }
}

# I1: one fault in the first watch iteration
$inj1 = @'
$script:injCount = 0
$script:origGadget = ${function:Get-FsGadget}
function Get-FsGadget { param([string]$Nonce) $script:injCount++; if ($script:injCount -eq 1) { throw 'INJECTED watch fault' }; & $script:origGadget -Nonce $Nonce }
'@
$rep = New-ObsReplica (Join-Path $it 'r1') $inj1 'dddddddddddddddd'
Check 'I0 replicas use the fake fastboot and no real tool path'  $rep.Safe
if ($rep.Safe) {
    $o = Invoke-ObsCase $rep
    Check 'I1 fault in a watch iteration: logged, observation continues' ($o.Rc -eq 0 -and $o.Log -match 'watch iteration error \(observation continues\): INJECTED watch fault' -and $o.DevicesAfterBoot -ge 2)
    Check 'I2 ...and the run still ends with an OUTCOME line'      ($o.Log -match 'OUTCOME: INCONCLUSIVE')
    Check 'I3 ...and the boot command ran exactly once'            ($o.Boots -eq 1)
}

# I4: the boot wrapper itself throws after the process ran
$inj2 = @'
$script:origNative = ${function:Invoke-FsNative}
function Invoke-FsNative { param([string]$Exe, [string[]]$ArgList = @(), [int]$TimeoutMs = 60000)
    $res = & $script:origNative -Exe $Exe -ArgList $ArgList -TimeoutMs $TimeoutMs
    if ($ArgList -contains 'boot') { throw 'INJECTED boot-wrapper fault' }
    $res
}
'@
$rep = New-ObsReplica (Join-Path $it 'r2') $inj2 'eeeeeeeeeeeeeeee'
if ($rep.Safe) {
    $o = Invoke-ObsCase $rep
    Check 'I4 boot wrapper fault: handoff INCONCLUSIVE, observed, OUTCOME logged' ($o.Rc -eq 0 -and $o.Log -match 'HANDOFF CLASS: INCONCLUSIVE' -and $o.Log -match 'INJECTED boot-wrapper fault' -and $o.DevicesAfterBoot -ge 2 -and $o.Log -match 'OUTCOME: INCONCLUSIVE')
    Check 'I5 ...and the boot command was not retried'            ($o.Boots -eq 1)
} else { Check 'I0b second replica safe' $false }

# I6: trap path before registration (nonexistent image): exit 2, no device call
Remove-Item (Join-Path $fakeDir 'calls.txt') -ErrorAction SilentlyContinue
$null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rep.Script -Image (Join-Path $it 'no-such.img') -ConfirmNonce $rep.Nonce
Check 'I6 pre-registration error (no such image): exit 2 via trap, no fastboot call' ($LASTEXITCODE -eq 2 -and -not (Test-Path (Join-Path $fakeDir 'calls.txt')))
Remove-Item -Recurse -Force $it -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "TOTAL: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
