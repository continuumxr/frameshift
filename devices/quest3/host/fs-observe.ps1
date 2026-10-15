<#
FrameShift — stage-2a / stage-3a / stage-3b observer (Windows PowerShell 5.1). ONE attempt.

Fix round 6 (e2e review B1). The stage-1 observer (stage1/host-observe.ps1) runs
its own fs-verify/fs-ack session. PID 1 records only the FIRST ack, so a stage-1
observer followed by fs-collect.ps1 burns the attempt (the collector's own ack is
never recorded). This observer therefore runs NO session at all:
  - it verifies the image against its MANIFEST and the repository sources, and
    the one-shot nonce against the attempt ledger (build/stage2a|stage3a/attempted);
  - ONLY with the PM's live sign-off (-ConfirmNonce = this attempt's nonce,
    exactly as stage 1: checked before anything is written or queried; never
    defaulted, never inferred) it registers the attempt and runs exactly one
    `fastboot -s <serial> boot <image>` (never retried, never anything else);
  - it records the handoff time Th (when `fastboot boot` returned) and watches
    for the USB gadget whose serial is FS-<nonce>. It never opens the port.
  - it writes <OutDir>\observe.json and prints the collector command; with
    -ThenCollect it starts fs-collect.ps1 itself, with -BootStartUtc (the budget
    origin) and -HandoffUtc = Th (evidence only; FS-R-007 B1, below).
The collector does fs-verify / fs-ack / fs-status / the runner / fs-done. The
stage-1 class is derived afterwards from observe.json plus the collector's verified
FSV1 (fs-classify.ps1 -ObserveDir).

Fix round 7 (re-review of 685da7c):
  - SF1: the ledger is the FIXED <repo>\build\stage<2a|3a>\attempted, and the image must sit
    directly in <repo>\build\stage<2a|3a>\<stamp>-<nonce>\. A copied build folder elsewhere
    (which would otherwise get a fresh ledger) is refused.
  - NIT4 (superseded by FS-R-007 B1, below).

Chair ruling FS-R-007 B1 (revision 9):
  - the collector's budget origin is ALWAYS BootStartUtc: the host UTC time taken just BEFORE
    `fastboot boot` is invoked (T0 cannot precede it), for every handoff class. observe.json
    BudgetOriginUtc = BootStartUtc; the collector gets it as -BootStartUtc.
  - HandoffUtc (Th, when `fastboot boot` returned) is kept as separate evidence (-HandoffUtc):
    a successful return does not prove that Th precedes T0.

Stage 3b (FS-R-010 §6, revision 10): the BA-to-attempt dwell cap is ENFORCED BEFORE THE BOOT.
  -BaSummary and -BfSummary (the capture tool's <phase>\SUMMARY.txt of THIS cycle; tool withheld) are required:
  both must be "PHASE BA OK"/"PHASE BF OK" summaries for this nonce and serial, BF not before BA,
  and the host's UTC time just before the boot must be at most 300 s after BA started (the
  header time of the BA summary). Otherwise nothing is booted, the attempt is NOT registered
  (the nonce stays unspent), and an abandoned-cycle record is written to
  <repo>\build\stage3b\abandoned\<UTC>-<nonce>.txt: return to Android, take a new settled pair,
  new BA/BF (into a new captures directory) and try again.
  The gate is evaluated just before the attempt is registered, which is less than 1 s
  (the ledger write and the output directory) before BootStartUtc is taken; observe.json
  records both DwellSec (at the gate) and DwellAtBootStartSec (at BootStartUtc).

Usage:
  fs-observe.ps1 -Stage 2a|3a|3b -Image <build dir>\boot-stage2a.img -Preflight       (no device action)
  fs-observe.ps1 -Stage 2a|3a -Image <...> -ConfirmNonce <nonce> [-ThenCollect]     (the attempt; PM sign-off)
  fs-observe.ps1 -Stage 3b -Image <...> -ConfirmNonce <nonce> -BaSummary <BA\SUMMARY.txt> -BfSummary <BF\SUMMARY.txt> [-ThenCollect]
Exit: 0 attempt made (or preflight OK); 2 refused (nothing booted); 3 no PM sign-off
(nothing written, no device queried); 70 internal error before the boot.
#>
param(
    [ValidateSet('2a', '3a', '3b')][string]$Stage = '2a',
    [string]$Image = '',
    [string]$Serial = 'QUEST3UNIT1',
    [switch]$Preflight,
    [string]$ConfirmNonce = '',
    [int]$GadgetWaitSec = 90,
    [switch]$ThenCollect,
    [string]$FastbootExe = 'C:\platform-tools\fastboot.exe',
    [string]$BaSummary = '',            # stage 3b: this cycle's BA SUMMARY.txt (dwell gate)
    [string]$BfSummary = ''             # stage 3b: this cycle's BF SUMMARY.txt
)
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\stage1\fs-proto.ps1')     # Invoke-FsNative, Get-FsFastbootSerials, Get-FsHandoffClass, Get-FsGadget, Register-FsAttempt, Test-FsAttemptFree (read only)

$script:FsObsBaseline = @{
    StockBoot  = '49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50'
    StockVboot = '1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf'
}
# Per stage: the image file name, the MANIFEST title, and the repository sources whose
# recorded hashes must equal the reviewed files (the image was built from them).
$script:FsObsStage = @{
    '2a' = @{ Img = 'boot-stage2a.img'; Title = 'stage-2a image'; Sources = [ordered]@{ 'init.sh source' = 'stage2a\init.sh'; 'fs-valve.sh' = 'stage2a\fs-valve.sh'; 'fs-inv.sh' = 'stage2a\fs-inv.sh' } }
    '3a' = @{ Img = 'boot-stage3a.img'; Title = 'stage-3a image'; Sources = [ordered]@{ 'init.sh source' = 'stage3a\init.sh'; 'fs-display.sh' = 'stage3a\fs-display.sh' } }
    '3b' = @{ Img = 'boot-stage3b.img'; Title = 'stage-3b image'; Sources = [ordered]@{ 'init.sh source' = 'stage3b\init.sh'; 'fs-display.sh' = 'stage3b\fs-display.sh'; 'fs-probe.sh' = 'stage3b\fs-probe.sh' } }
}
$script:FsObsDwellMaxSec = 300      # stage 3b: BA start to the boot, at most 5 min (FS-R-010 §6)

# Stage 3b dwell gate: parses one capture-tool SUMMARY.txt (tool withheld; the header format is kept). Returns @{ Ok; Why; StartUtc }.
function Read-FsObsPhaseSummary {
    param([string]$Path, [string]$Phase, [string]$Nonce, [string]$Serial)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = "$Phase summary: $w"; StartUtc = $null } }
    if (-not $Path) { return (& $no 'not given (-BaSummary/-BfSummary are required for stage 3b)') }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (& $no "missing: $Path") }
    $lines = @([IO.File]::ReadAllLines($Path) | Where-Object { $_ -ne '' })
    if ($lines.Count -lt 2) { return (& $no 'too short') }
    $re = '^# fs-capture\.ps1 phase ' + $Phase + ' nonce ([0-9a-f]{16}) serial (\S+)  (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\z'
    if ($lines[0] -cnotmatch $re) { return (& $no 'header is not a capture summary of this phase') }
    if ($Matches[1] -cne $Nonce) { return (& $no "nonce $($Matches[1]) is not this attempt's $Nonce") }
    if ($Matches[2] -cne $Serial) { return (& $no "serial $($Matches[2]) is not $Serial") }
    $t = [DateTime]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    if ($lines[-1] -cnotmatch ('^PHASE ' + $Phase + ' OK: ')) { return (& $no "the phase did not end OK ('$($lines[-1])')") }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; StartUtc = $t }
}
function Test-FsObsDwell {
    param([string]$BaSummary, [string]$BfSummary, [string]$Nonce, [string]$Serial, [DateTime]$NowUtc)
    $ba = Read-FsObsPhaseSummary $BaSummary 'BA' $Nonce $Serial
    if (-not $ba.Ok) { return [pscustomobject]@{ Ok = $false; Why = $ba.Why; Abandon = $false; BaUtc = $null; ElapsedSec = $null } }
    $bf = Read-FsObsPhaseSummary $BfSummary 'BF' $Nonce $Serial
    if (-not $bf.Ok) { return [pscustomobject]@{ Ok = $false; Why = $bf.Why; Abandon = $false; BaUtc = $ba.StartUtc; ElapsedSec = $null } }
    if ($bf.StartUtc -lt $ba.StartUtc) { return [pscustomobject]@{ Ok = $false; Why = 'BF started before BA'; Abandon = $false; BaUtc = $ba.StartUtc; ElapsedSec = $null } }
    $el = ($NowUtc.ToUniversalTime() - $ba.StartUtc).TotalSeconds
    if ($el -lt 0) { return [pscustomobject]@{ Ok = $false; Why = 'BA start is in the future (clock step or wrong file)'; Abandon = $false; BaUtc = $ba.StartUtc; ElapsedSec = $el } }
    if ($el -gt $script:FsObsDwellMaxSec) {
        return [pscustomobject]@{ Ok = $false; Abandon = $true; BaUtc = $ba.StartUtc; ElapsedSec = $el
                                  Why = ("dwell cap expired: {0:N0} s since BA started (max {1} s): return to Android, take a new settled pair and new BA/BF, then try again" -f $el, $script:FsObsDwellMaxSec) }
    }
    [pscustomobject]@{ Ok = $true; Why = ("dwell {0:N0} s since BA started (max {1} s)" -f $el, $script:FsObsDwellMaxSec); Abandon = $false; BaUtc = $ba.StartUtc; ElapsedSec = $el }
}

function Get-FsObsSha([string]$Path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { $null } }

# Parses and checks a stage-2a/3a MANIFEST.txt against the image file and the repository.
# Returns @{ Ok; Why; Nonce; ImageSha }.
function Test-FsObsManifest {
    param([string]$Stage, [string]$ImagePath, [string]$Q3)
    $spec = $script:FsObsStage[$Stage]
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Nonce = $null; ImageSha = $null } }
    if ((Split-Path -Leaf $ImagePath) -cne $spec.Img) { return (& $no "image file is not $($spec.Img)") }
    $mf = Join-Path (Split-Path -Parent $ImagePath) 'MANIFEST.txt'
    if (-not (Test-Path -LiteralPath $mf -PathType Leaf)) { return (& $no 'MANIFEST.txt missing') }
    $m = [IO.File]::ReadAllText($mf)
    $v = { param($re) if ($m -cmatch $re) { $Matches[1] } else { $null } }
    $nonce = & $v '(?m)^nonce:\s+([0-9a-f]{16})\s'
    # every refusal from here on carries the nonce, so the sign-off gate is judged on its own
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; Nonce = $nonce; ImageSha = $null } }
    if ($m -cnotmatch "(?m)^FrameShift Quest 3 $([regex]::Escape($spec.Title)) ") { return (& $no "MANIFEST is not a $($spec.Title) manifest") }
    if ($m -cmatch '(?m)^TEST OVERRIDES') { return (& $no 'MANIFEST records TEST OVERRIDES: a fixture build, never an attempt image') }
    $isha = & $v ('(?m)^OUTPUT IMAGE:\s+' + [regex]::Escape($spec.Img) + '\s+size=\d+\s+sha256=([0-9a-f]{64})\s*$')
    if (-not $nonce -or -not $isha) { return (& $no 'MANIFEST lacks the nonce or the image hash') }
    $dirName = Split-Path -Leaf (Split-Path -Parent $ImagePath)
    if ($dirName -cnotmatch ('^\d{8}T\d{6}Z-' + $nonce + '\z')) { return (& $no "image directory '$dirName' does not carry the manifest nonce") }
    $act = Get-FsObsSha $ImagePath
    if ($act -cne $isha) { return (& $no "image sha256 $act != MANIFEST $isha") }
    if ((& $v '(?m)^stock boot\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.StockBoot) { return (& $no 'MANIFEST stock boot is not the selected slot-A baseline') }
    if ((& $v '(?m)^stock vendor_boot\s+([0-9a-f]{64})\s') -cne $script:FsObsBaseline.StockVboot) { return (& $no 'MANIFEST stock vendor_boot is not the selected slot-A baseline') }
    foreach ($k in $spec.Sources.Keys) {
        $rec = & $v ('(?m)^' + [regex]::Escape($k) + '\s+([0-9a-f]{64})\s')
        $repo = Get-FsObsSha (Join-Path $Q3 $spec.Sources[$k])
        if (-not $rec -or $rec -cne $repo) { return (& $no "image was built from another $k ($rec) than the repository's ($repo)") }
    }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; Nonce = $nonce; ImageSha = $isha }
}

# The observer, with every device-facing dependency injectable (fixtures pass fakes):
#   $Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) -> Invoke-FsNative-shaped result }
#   $Gadget   { param([string]$Nonce) -> Get-FsGadget-shaped result }
#   $NowUtc   { -> [DateTime] UTC }    $Sleep { param([int]$Ms) }    $Say { param([string]$Line) }
function Invoke-FsObserve {
    param([Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][string]$ImagePath, [string]$Serial = 'QUEST3UNIT1',
          [string]$ConfirmNonce = '', [bool]$Preflight = $false, [Parameter(Mandatory)][string]$BuildRoot, [Parameter(Mandatory)][string]$Q3,
          [int]$GadgetWaitSec = 90, [Parameter(Mandatory)][scriptblock]$Fastboot, [Parameter(Mandatory)][scriptblock]$Gadget,
          [Parameter(Mandatory)][scriptblock]$NowUtc, [Parameter(Mandatory)][scriptblock]$Sleep, [Parameter(Mandatory)][scriptblock]$Say,
          [string]$BaSummary = '', [string]$BfSummary = '')
    $r = [ordered]@{ Exit = 70; Why = ''; OutDir = $null; Observe = $null }
    $mf = Test-FsObsManifest -Stage $Stage -ImagePath $ImagePath -Q3 $Q3
    # PM sign-off gate (as stage 1): before anything is written or any device is queried.
    if (-not $Preflight -and (-not $mf.Nonce -or $ConfirmNonce -cne $mf.Nonce)) {
        $r.Exit = 3; $r.Why = 'no PM sign-off for this attempt (-ConfirmNonce must equal the attempt nonce): nothing written, no device action'
        & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    if (-not $mf.Ok) { $r.Exit = 2; $r.Why = "image refused: $($mf.Why)"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    $dir = Split-Path -Parent $ImagePath
    # SF1: one fixed ledger per stage; the image must live in the stage's build directory
    $br = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\', '/')
    if ([IO.Path]::GetFullPath((Split-Path -Parent $dir)).TrimEnd('\', '/') -ine $br) {
        $r.Exit = 2; $r.Why = "image is not in $br\<stamp>-<nonce>\ (a copied build folder would escape the one-attempt ledger)"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    $LedgerDir = Join-Path $br 'attempted'
    if (-not (Test-FsAttemptFree -Dir $dir -Nonce $mf.Nonce -LedgerDir $LedgerDir)) {
        $r.Exit = 2; $r.Why = "nonce $($mf.Nonce) was already attempted (ledger $LedgerDir) or the image directory is locked"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    & $Say "image OK: stage $Stage nonce $($mf.Nonce) sha256 $($mf.ImageSha)"
    if ($Preflight) { $r.Exit = 0; $r.Why = 'preflight OK: manifest, image, baseline, sources and attempt freshness verified; no device action'; & $Say $r.Why; return [pscustomobject]$r }
    $q = & $Fastboot @('devices') 15000
    $serials = @(); foreach ($line in ([string]$q.StdOut -split "`r?`n")) { if ($line -match '^(\S+)\s+fastboot\s*$') { $serials += $Matches[1] } }
    if ($q.Error -or $q.TimedOut -or $q.ExitCode -ne 0 -or $serials.Count -ne 1 -or $serials[0] -cne $Serial) {
        $r.Exit = 2; $r.Why = "need exactly one fastboot device, $Serial (got: $($serials -join ','))"; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
    }
    $dwOk = $null
    if ($Stage -ceq '3b') {
        # FS-R-010 §6: BA to the attempt at most 5 min, enforced BEFORE the boot and before the attempt is registered
        $dw = Test-FsObsDwell -BaSummary $BaSummary -BfSummary $BfSummary -Nonce $mf.Nonce -Serial $Serial -NowUtc (& $NowUtc)
        if (-not $dw.Ok) {
            if ($dw.Abandon) {
                $ad = Join-Path $br 'abandoned'
                $null = New-Item -ItemType Directory -Force -Path $ad
                $af = Join-Path $ad ("{0}-{1}.txt" -f (& $NowUtc).ToString('yyyyMMddTHHmmssZ'), $mf.Nonce)
                $txt = @("ABANDONED CYCLE (stage 3b, FS-R-010 §6): nothing was booted; the attempt was not registered; nonce $($mf.Nonce) is unspent",
                         "BA started: $($dw.BaUtc.ToString('o'))", "checked at: $((& $NowUtc).ToString('o'))", ("elapsed: {0:N1} s (max {1} s)" -f $dw.ElapsedSec, $script:FsObsDwellMaxSec),
                         "BA summary: $BaSummary", "BF summary: $BfSummary", 'next: return to Android, a new settled pair, new BA/BF (into a new captures directory), then the attempt')
                [IO.File]::WriteAllText($af, (($txt -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
                $r.Why = "REFUSED: $($dw.Why). Abandoned-cycle record: $af"
            } else { $r.Why = "REFUSED: $($dw.Why)" }
            $r.Exit = 2; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r
        }
        & $Say "dwell gate OK: $($dw.Why)"
        $dwOk = $dw; $dwAt = (& $NowUtc)
    }
    $reg = Register-FsAttempt -Dir $dir -Nonce $mf.Nonce -LedgerDir $LedgerDir -Note "stage$Stage image=$($mf.ImageSha)"
    if (-not $reg.Ok) { $r.Exit = 2; $r.Why = $reg.Reason; & $Say "ABORT: $($r.Why)"; return [pscustomobject]$r }
    $out = Join-Path $dir ('observe-' + (& $NowUtc).ToString('yyyyMMddTHHmmssZ'))
    $null = New-Item -ItemType Directory -Path $out
    $r.OutDir = $out
    $logPath = Join-Path $out 'observe.log'
    $L = { param($line) $t = "$((& $NowUtc).ToString('o'))  $line"; Add-Content -LiteralPath $logPath -Value $t -Encoding UTF8; & $Say $t }
    & $L "attempt registered: $($reg.Files -join ', ')"
    $o = [ordered]@{ Schema = 'frameshift.fs-observe.v1'; Stage = $Stage; Nonce = $mf.Nonce; Serial = $Serial; Image = $ImagePath; ImageSha256 = $mf.ImageSha
                     BootStartUtc = $null; HandoffUtc = $null; BudgetOriginUtc = $null; HandoffClass = $null; BootRc = $null; BootStdOut = ''; BootStdErr = ''; BootError = $null
                     GadgetSeen = $false; GadgetUtc = $null; ComPort = $null; WrongSerials = @(); GadgetWaitSec = $GadgetWaitSec; NextCommand = $null }
    $o.BootStartUtc = (& $NowUtc).ToString('o')          # taken BEFORE fastboot is invoked: the budget origin (FS-R-007 B1)
    $o.BudgetOriginUtc = $o.BootStartUtc
    if ($null -ne $dwOk) {   # stage 3b: the return package proves BA -> boot <= 300 s (review m6)
        $o.BaStartUtc = $dwOk.BaUtc.ToString('o'); $o.DwellCheckedUtc = $dwAt.ToString('o')
        $o.DwellSec = [Math]::Round(($dwAt - $dwOk.BaUtc).TotalSeconds, 1)
        $o.DwellAtBootStartSec = [Math]::Round(([DateTime]::Parse($o.BootStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() - $dwOk.BaUtc).TotalSeconds, 1)
        $o.DwellMaxSec = $script:FsObsDwellMaxSec; $o.BaSummary = $BaSummary; $o.BfSummary = $BfSummary
        & $L ("dwell gate: BA started {0}; checked {1}: {2} s; at BootStartUtc {3} s (max {4} s); BA {5}; BF {6}" -f $o.BaStartUtc, $o.DwellCheckedUtc, $o.DwellSec, $o.DwellAtBootStartSec, $script:FsObsDwellMaxSec, $BaSummary, $BfSummary)
    }
    & $L "COMMAND: fastboot -s $Serial boot `"$ImagePath`"   (once; never retried)"
    $b = $null
    try { $b = & $Fastboot @('-s', $Serial, 'boot', $ImagePath) 120000 }
    catch { $b = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false; Error = 'observer fault: ' + $_.Exception.Message } }
    $th = & $NowUtc
    $o.HandoffUtc = $th.ToString('o'); $o.BootRc = $b.ExitCode; $o.BootStdOut = [string]$b.StdOut; $o.BootStdErr = [string]$b.StdErr; $o.BootError = $b.Error
    $o.HandoffClass = Get-FsHandoffClass -Result $b
    & $L "fastboot boot returned: rc=$($b.ExitCode) timedout=$($b.TimedOut) error=$($b.Error) class=$($o.HandoffClass)  Th=$($o.HandoffUtc)"
    if ($o.HandoffClass -cne 'DEVICE_REJECTED') {
        $end = $th.AddSeconds($GadgetWaitSec)
        while ((& $NowUtc) -lt $end) {
            $g = $null
            try { $g = & $Gadget $mf.Nonce } catch { & $L "gadget query error (watch continues): $($_.Exception.Message)" }
            if ($g) {
                foreach ($w in @($g.Serials)) { if ($w -and $w -cne "FS-$($mf.Nonce)" -and $o.WrongSerials -notcontains $w) { $o.WrongSerials += $w; & $L "gadget with a WRONG serial ${w}: ignored" } }
                if ($g.SerialOk -and $g.ComPort) {
                    $o.GadgetSeen = $true; $o.GadgetUtc = (& $NowUtc).ToString('o'); $o.ComPort = $g.ComPort
                    & $L "GADGET FS-$($mf.Nonce) on $($g.ComPort) at Th+$([int]((& $NowUtc) - $th).TotalSeconds)s (the port is not opened here)"
                    break
                }
            }
            & $Sleep 1000
        }
        if (-not $o.GadgetSeen) { & $L "no gadget FS-$($mf.Nonce) within $GadgetWaitSec s: the PID 1 deadline / recovery table applies" }
        & $L "collector budget origin: BootStartUtc $($o.BootStartUtc) (before fastboot boot; every handoff class). Th $($o.HandoffUtc) is evidence only"
    }
    if ($o.GadgetSeen) {
        $o.NextCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-collect.ps1 -Stage $Stage -Port $($o.ComPort) -Nonce $($mf.Nonce) -BootStartUtc $($o.BootStartUtc) -HandoffUtc $($o.HandoffUtc) -OutDir `"$out\collect`""
        & $L "NEXT: $($o.NextCommand)"
        & $L "THEN: fs-classify.ps1 -Stage $Stage -CollectDir `"$out\collect`" -ObserveDir `"$out`""
    }
    [IO.File]::WriteAllText((Join-Path $out 'observe.json'), (([pscustomobject]$o | ConvertTo-Json -Depth 4) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r.Exit = 0; $r.Why = "attempt made: handoff $($o.HandoffClass), gadget $($o.GadgetSeen)"; $r.Observe = [pscustomobject]$o
    [pscustomobject]$r
}

if ($MyInvocation.InvocationName -eq '.') { return }
# ------------------------------------------------------------------ CLI -----
$exit = 70
try {
    if (-not $Image) { Write-Output 'usage: fs-observe.ps1 -Stage 2a|3a|3b -Image <dir>\boot-stage2a|3a|3b.img (-Preflight | -ConfirmNonce <nonce> [-ThenCollect]); stage 3b also -BaSummary <file> -BfSummary <file>'; exit 64 }
    $q3 = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $imgPath = (Resolve-Path -LiteralPath $Image).Path
    $buildRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path "build\stage$Stage"     # FIXED: <repo>\build\stage2a|3a|3b (SF1)
    $fb = $FastbootExe
    $res = Invoke-FsObserve -Stage $Stage -ImagePath $imgPath -Serial $Serial -ConfirmNonce $ConfirmNonce -Preflight ([bool]$Preflight) `
        -BuildRoot $buildRoot -Q3 $q3 -GadgetWaitSec $GadgetWaitSec `
        -Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) Invoke-FsNative -Exe $fb -ArgList $ArgList -TimeoutMs $TimeoutMs } `
        -Gadget { param([string]$N) Get-FsGadget -Nonce $N } -NowUtc { [DateTime]::UtcNow } -Sleep { param([int]$Ms) Start-Sleep -Milliseconds $Ms } `
        -Say { param([string]$Line) Write-Host $Line } -BaSummary $BaSummary -BfSummary $BfSummary     # Write-Host: the function's pipeline output is its result object only
    $exit = $res.Exit
    if ($res.Exit -eq 0 -and $res.Observe -and $res.Observe.GadgetSeen -and $ThenCollect) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fs-collect.ps1') -Stage $Stage -Port $res.Observe.ComPort `
            -Nonce $res.Observe.Nonce -BootStartUtc $res.Observe.BootStartUtc -HandoffUtc $res.Observe.HandoffUtc -OutDir (Join-Path $res.OutDir 'collect')
        Write-Output "collector exit: $LASTEXITCODE"
    }
} catch { Write-Output "OBSERVER ERROR: $($_.Exception.Message)"; $exit = 70 }
exit $exit
