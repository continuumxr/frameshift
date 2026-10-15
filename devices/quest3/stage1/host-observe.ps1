<#
FrameShift — Quest 3 stage-1 host observer (Windows PowerShell 5.1). ONE attempt.

Runs exactly one `fastboot -s <serial> boot <image>` and observes. It never
flashes, erases, changes slots, or retries the boot command (FS-R-004 §3).
The only other device interaction is the challenge/ack exchange with OUR shell
over the ACM port, and only if the gadget carries this attempt's nonce.

Refuses to run unless:
  - the image hash and nonce match the build's MANIFEST.txt;
  - the manifest's stock boot/vendor_boot hashes are the selected baseline;
  - exactly one fastboot device is present and it is the expected serial;
  - this image directory has never been used for an attempt.

Usage:
  powershell -ExecutionPolicy Bypass -File host-observe.ps1 -Image <dir>\boot-stage1.img
#>
param(
    [Parameter(Mandatory)][string]$Image,
    [string]$Serial = 'QUEST3UNIT1',
    [int]$PassWindowSec = 120,
    [int]$TotalSec = 360,
    [switch]$Preflight,         # run every pre-invocation check, then stop (no device action)
    [string]$ConfirmNonce = ''  # PM live sign-off: must equal this attempt's nonce, or no boot
)
$ErrorActionPreference = 'Continue'          # native stderr must never abort us
. (Join-Path $PSScriptRoot 'fs-proto.ps1')
# Fail closed (host re-review F1): under StrictMode a failed expression inside an
# `if` condition ends only that statement, which would skip an abort. Until the
# attempt is registered, any terminating error ends the script with exit 2 (it
# is reported on the console only: nothing may be written before the sign-off
# gate). After registration the trap only logs; `continue` in a script-level
# trap resumes after the whole enclosing top-level statement, so the boot
# command and every watch iteration carry their own try/catch and never reach
# it (final review MAJOR-1).
$script:Registered = $false
trap {
    if (-not $script:Registered) { Write-Host "ABORT: unexpected error before any device action: $($_.Exception.Message)"; exit 2 }
    try { Log "observer error (observation continues): $($_.Exception.Message)" } catch { }
    continue
}
function Get-Sha256([string]$Path) {   # $null on any failure; callers treat $null as a mismatch
    try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { $null }
}

# Selected baseline (FS-A-004 §1) and expected target identity.
$EXPECT_STOCK_BOOT  = '49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50'
$EXPECT_STOCK_VBOOT = '1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf'
$EXPECT_KERNEL      = '5.10.198-01402-g1c5986fe21ee'
$EXPECT_PID1        = '/bin/busybox,sh,/init'
$FASTBOOT = 'C:\platform-tools\fastboot.exe'
$ADB      = 'C:\platform-tools\adb.exe'

$ImagePath = (Resolve-Path $Image).Path            # absolute: hashed file == booted file
$dir = Split-Path -Parent $ImagePath
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$ledger = Join-Path $repoRoot 'build\stage1\attempted'
# Until registration the log is precheck-<ts>.log (preflight-<ts>.log with
# -Preflight). Only a registered attempt writes observe-<ts>.log, so an abort
# before the boot (e.g. no fastboot device yet) does not consume the image
# directory (host re-review F3).
$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$prefix = 'precheck-'; if ($Preflight) { $prefix = 'preflight-' }
$log = Join-Path $dir ($prefix + $ts + '.log')
function Log([string]$m) {
    $line = '{0}  +{1,8}ms  {2}' -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff'), (Get-FsMs), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $line
}
function Stop-Attempt([string]$cls, [string]$why) { Log "OUTCOME: $cls ($why)"; Log "log: $log"; exit 0 }

# ---------------------------------------------------------- preconditions --
if (@(Get-ChildItem -Path $dir -Filter 'observe-*.log').Count -gt 0) {
    Write-Host 'ABORT: this image directory was already used for an attempt; build a fresh image.'; exit 2
}
$manifest = Get-Content (Join-Path $dir 'MANIFEST.txt') -Raw
function ManifestValue([string]$pattern) { if ($manifest -match $pattern) { $Matches[1] } else { $null } }
$Nonce     = ManifestValue 'nonce:\s+([0-9a-f]{16})'
$imgSha    = ManifestValue 'OUTPUT IMAGE:\s+\S+\s+sha256=([0-9a-f]{64})'
$bootSha   = ManifestValue 'stock boot:\s+\S+\s+sha256=([0-9a-f]{64})'
$vbootSha  = ManifestValue 'stock vboot:\s+\S+\s+sha256=([0-9a-f]{64})'
$actualSha = Get-Sha256 $ImagePath
# PM sign-off gate (PM, 2026-10-08): a real attempt only with the PM's explicit
# live sign-off, passed as this attempt's nonce. Checked before any log file is
# written or any device is queried. Never defaulted, never inferred.
if (-not $Preflight -and ($ConfirmNonce -cne $Nonce -or -not $Nonce)) {
    Write-Host 'ABORT: no PM sign-off for this attempt (-ConfirmNonce must equal the attempt nonce). Nothing written, no device action.'
    exit 3
}
Log "attempt: serial=$Serial nonce=$Nonce image=$ImagePath"
if (-not (Test-FsAttemptFree -Dir $dir -Nonce $Nonce -LedgerDir $ledger)) { Log "ABORT: nonce $Nonce was already attempted (ledger $ledger) or this directory is locked"; exit 2 }
Log "image sha256 actual=$actualSha manifest=$imgSha"
if (-not $Nonce -or -not $imgSha -or -not $actualSha -or $actualSha -cne $imgSha) { Log 'ABORT: image does not match its manifest (or could not be hashed)'; exit 2 }
if ($bootSha -cne $EXPECT_STOCK_BOOT -or $vbootSha -cne $EXPECT_STOCK_VBOOT) { Log 'ABORT: manifest baseline is not the selected slot-A baseline'; exit 2 }
$initSrcSha = ManifestValue 'init\.sh source:\s+sha256=([0-9a-f]{64})'
$repoInitSha = Get-Sha256 (Join-Path $PSScriptRoot 'init.sh')
if (-not $initSrcSha -or -not $repoInitSha -or $initSrcSha -cne $repoInitSha) { Log "ABORT: image was built from a different init.sh ($initSrcSha) than the reviewed one ($repoInitSha)"; exit 2 }

if ($Preflight) { Log 'PREFLIGHT OK: image, manifest, baseline, init.sh binding and attempt freshness verified; no device action taken'; exit 0 }

$fb = Get-FsFastbootSerials -FastbootExe $FASTBOOT
Log ('fastboot devices: [' + ($fb.Serials -join ',') + '] stderr=' + ($fb.Raw.StdErr -replace "`r?`n", ' | '))
if (-not $fb.Ok -or $fb.Serials.Count -ne 1 -or $fb.Serials[0] -ne $Serial) { Log 'ABORT: need exactly one fastboot device, the expected serial'; exit 2 }

# Atomic one-attempt registration, immediately before the only device action.
$reg = Register-FsAttempt -Dir $dir -Nonce $Nonce -LedgerDir $ledger -Note "image=$actualSha"
if (-not $reg.Ok) { Log "ABORT: $($reg.Reason)"; exit 2 }
$script:Registered = $true
$precheckLog = $log
$log = Join-Path $dir ('observe-' + $ts + '.log')
Add-Content -Path $log -Value (Get-Content -LiteralPath $precheckLog) -Encoding UTF8   # carry the precheck lines over
Log "attempt registered: $($reg.Files -join ', ')  (log continues here from $precheckLog)"

# ---------------------------------------------------------------- handoff --
Log "COMMAND: `"$FASTBOOT`" -s $Serial boot `"$ImagePath`""
$r = $null
try { $r = Invoke-FsNative -Exe $FASTBOOT -ArgList @('-s', $Serial, 'boot', $ImagePath) -TimeoutMs 120000 }
catch {   # handoff unknown: classified INCONCLUSIVE, observed, never retried
    $r = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false
                            StartMs = (Get-FsMs); EndMs = (Get-FsMs); Error = 'observer fault: ' + $_.Exception.Message }
}
Log "fastboot boot: start=+$($r.StartMs)ms end=+$($r.EndMs)ms rc=$($r.ExitCode) timedout=$($r.TimedOut) error=$($r.Error)"
Log ('  stdout: ' + ($r.StdOut -replace "`r?`n", ' | '))
Log ('  stderr: ' + ($r.StdErr -replace "`r?`n", ' | '))
$handoff = Get-FsHandoffClass -Result $r
$ThMs = $r.EndMs
Log "HANDOFF CLASS: $handoff  (Th=+${ThMs}ms)"
if ($handoff -eq 'DEVICE_REJECTED') {
    $after = Get-FsFastbootSerials -FastbootExe $FASTBOOT
    Log ('device state after: fastboot=[' + ($after.Serials -join ',') + '] query_ok=' + $after.Ok)
    Stop-Attempt $handoff 'explicit device refusal; no automatic retry'
}
if ($handoff -eq 'INCONCLUSIVE') {
    Log 'handoff uncertain (e.g. status read failed after Booting): continuing OBSERVATION ONLY; the boot command is never retried'
}

# ------------------------------------------------------------------ watch --
$passDeadline = $ThMs + 1000L * $PassWindowSec
$endMs = $ThMs + 1000L * $TotalSec
$gadgetNonceSeen = $false; $mismatchLogged = $false
$fbGoneMs = $null; $fbBackMs = $null; $adbMs = $null; $fqFailLogged = $false
$session = $null
while ((Get-FsMs) -lt $endMs) {
    try {
        $now = Get-FsMs; $t = [int](($now - $ThMs) / 1000)
        $g = Get-FsGadget -Nonce $Nonce
        if ($g.Present -and -not $g.SerialOk -and -not $mismatchLogged) {
            Log ("GADGET with WRONG serial(s) [" + ($g.Serials -join ',') + "] t=${t}s: no interaction"); $mismatchLogged = $true
        }
        if ($g.SerialOk -and -not $gadgetNonceSeen) {
            $gadgetNonceSeen = $true; Log "GADGET FS-$Nonce enumerated t=${t}s parent=$($g.Parent) port=$($g.ComPort)"
        }
        $fq = Get-FsFastbootSerials -FastbootExe $FASTBOOT -TimeoutMs 5000
        if ($fq.Ok) {
            $fbNow = $fq.Serials -contains $Serial
            if (-not $fbNow -and $null -eq $fbGoneMs) { $fbGoneMs = $now; Log "fastboot GONE t=${t}s" }
            if ($fbNow -and $null -ne $fbGoneMs -and $null -eq $fbBackMs) { $fbBackMs = $now; Log "fastboot RETURNED after being gone, t=${t}s" }
        } elseif (-not $fqFailLogged) { $fqFailLogged = $true; Log "fastboot query failed t=${t}s (not treated as absence)" }
        if ($null -eq $adbMs) {
            $a = Invoke-FsNative -Exe $ADB -ArgList @('devices') -TimeoutMs 5000
            if ($a.StdOut -match ([regex]::Escape($Serial) + '\s+device')) { $adbMs = $now; Log "ANDROID (adb) present t=${t}s" }
        }

        if ($g.SerialOk -and $g.ComPort -and $now -le $passDeadline -and -not ($session -and $session.Verified)) {
            $tr = $null; $session = $null                 # never re-log a previous session
            try {
                $tr = New-FsSerialTransport -PortName $g.ComPort
                $tr.Open()
                Start-Sleep -Milliseconds 500
                $session = Invoke-FsSession -Transport $tr -Nonce $Nonce -Kernel $EXPECT_KERNEL -Pid1 $EXPECT_PID1 -PassDeadlineMs $passDeadline
            } catch {
                Log ('serial open/session error: ' + $_.Exception.Message)
            } finally { if ($tr) { $tr.Dispose() } }
            if ($session) {
                Add-Content -Path $log -Value ("----- transcript -----`n" + $session.Transcript + "`n----- end -----") -Encoding UTF8
                Log "session: verified=$($session.Verified) ($($session.VerifyReason)) acked=$($session.Acked) ($($session.AckReason)) stages=$($session.Stages) error=$($session.Error)"
                if ($session.Verified) { break }
            }
        }
    } catch {   # one fault must not end observation of the only attempt
        try { Log ('watch iteration error (observation continues): ' + $_.Exception.Message) } catch { }   # a failing log must not reach the trap
    }
    Start-Sleep -Seconds 1
}

# ---------------------------------------------------------------- outcome --
$hint = 'none'
if ($fbBackMs) {
    $tb = [int](($fbBackMs - $ThMs) / 1000)
    $hint = "fastboot returned at ${tb}s"
    if ($tb -ge 45 -and $tb -le 130) { $hint += ' (consistent with init error path)' }
    elseif ($tb -ge 150 -and $tb -le 270) { $hint += ' (consistent with no-host-ack path)' }
    elseif ($tb -ge 280 -and $tb -le 360) { $hint += ' (consistent with dead-man)' }
} elseif ($adbMs) { $hint = "Android returned at $([int](($adbMs - $ThMs) / 1000))s: read ro.boot.bootreason" }
$cls = Get-FsOutcome -Handoff $handoff -GadgetNonceSeen $gadgetNonceSeen -Session $session -TimingHint $hint
Log "EVIDENCE: handoff=$handoff gadget_nonce=$gadgetNonceSeen verified=$(if ($session) { $session.Verified } else { $false }) host_ack_confirmed=$(if ($session) { $session.Acked } else { $false })"
Log "TIMING HINT (not evidence): $hint"
Stop-Attempt $cls 'see evidence line'
