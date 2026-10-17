# FrameShift K1a classifier (Windows PowerShell 5.1, no modules). Reads ONE collector output directory of
# fs-collect-k1a.ps1 (collect.json + capture.raw) and classifies the K1a run (the K1a walkthrough (private)
# "What counts as K1a PASS"; FS-A-013 s.2.2 K1a). Offline; reads files only; no device, no network.
#
#   fs-classify-k1a.ps1 -CollectDir <dir> [-ObserveDir <dir>] [-Banner <expected /proc/version>] [-ConfigSha <64 hex>]
#   . fs-classify-k1a.ps1 ; $o = Get-FsK1aOutcome -Fsb1 <Test-Fsb1Record result> [-Collected $true] [-Banner ...] [-ConfigSha ...]
#
# It re-reads capture.raw, checks its SHA-256 against collect.json, and runs Test-Fsb1Record itself (exp k1a, the
# fixed step list, the collect.json nonce and challenge). The outcome, first match wins:
#   INCONCLUSIVE        no complete, FSB1-VALID record (missing, rejected, capture inconsistent): nothing concluded
#   INTEGRITY FAULT     a step that did not exit 0 (timer, signal, no supervisor report), or a step wrote stderr
#   K1A FAIL            the record is valid but a K1a fact is wrong: /proc/version is not the pinned banner (another
#                       kernel booted), the running config's SHA-256 is not the gated k1a.config, a module refusal
#                       (MODULE_FAIL, MODULES_READY not ok=95 fail=0, /proc/modules not 95), a symbol-version or
#                       vermagic line in the kernel log (modver-matches > 0), devtmpfs absent, the gadget not bound
#   K1A REVIEW          every K1a fact holds, but the kernel log has WARNING/BUG/oops-class lines (FS-R-012 s.3: a
#                       new warning pauses for review; they are listed, never folded into a PASS), or the kernel log
#                       had wrapped (its first line is not at boot time: early lines unseen; review MAJOR-1), or a
#                       step's output was truncated at its cap (review MINOR-8)
#   K1A PASS            every K1a fact holds and the kernel log has no WARNING/BUG/oops-class line
# EVERY result lists the kernel WARNING/BUG findings (FS-R-012 s.3: reported in every phase; K1a has one record
# phase, which reads the kernel log from boot to the runner), MemTotal (reported, no threshold) and the kernel log's
# first line (if it does not start at boot time the ring buffer has wrapped and earlier lines are not seen).
# Binding (review MAJOR-3, MINOR-8): a K1a outcome needs a LIVE collect.json (no replay, no fixture overrides) and the
# attempt's observe.json (-ObserveDir: the same nonce, stage k1a, one of the two K1a units); otherwise INCONCLUSIVE.
# -AllowReplay (offline fixtures only) lifts that and labels every output line FIXTURE. A PASS is the MACHINE SIDE
# only: the return to fastboot is checked at AF (<withheld capture tool> -Phase AF).
# The outcome record (PM request: K1a on both units, Unit 2 first): when the result is bound to the observed attempt
# (-ObserveDir, not a fixture) AND the attempt's checklist holds phase F (the after-session facts: AF, AA, follow-ups,
# recovery, dump mode), the classifier writes <ObserveDir>\classify-k1a.json (schema
# frameshift.fs-classify-k1a.v1: nonce, serial, unit, outcome, reason, the SHA-256 of capture.raw, collect.json and
# observe.json). fs-observe-k1a.ps1 and the K1a sign-off tooling (private) refuse a Unit 1 attempt until a Unit 2 attempt has one.
# Exit: 30 K1A PASS, 31 K1A REVIEW, 32 K1A FAIL, 33 INTEGRITY FAULT, 34 INCONCLUSIVE, 64 usage, 70 internal error.
[CmdletBinding()]
param(
    [string]$CollectDir = '', [string]$ObserveDir = '',
    [string]$Banner = 'Linux version 5.10.246-gdbc2bc83a2b6 (frameshift@k1a) (Android (8508608, based on r450784e) clang version 14.0.7 (https://android.googlesource.com/toolchain/llvm-project 4c603efb0cca074e9238af8b4106c30add4418f6), LLD 14.0.7) #1 SMP PREEMPT Wed Oct 14 00:00:00 UTC 2026',
    [string]$ConfigSha = '4aa0c894655627f6ff39476ac2a45abb4c224ee0053957d5002c694b0602826b',
    [int]$Modules = 95,
    [switch]$AllowReplay
)
Set-StrictMode -Version 2.0
$script:FsK1aClsInvocation = $MyInvocation.InvocationName
$script:FsK1aClsDir = $PSScriptRoot
. (Join-Path $PSScriptRoot '..\common\host\fsb1.ps1')    # Test-Fsb1Record (read only)
. (Join-Path $PSScriptRoot 'fs-k1a-units.ps1')            # the two K1a units, the outcome record schema (read only)

$script:FsK1aSteps = @('kernel', 'config', 'mem', 'modules', 'kmsg', 'fs', 'usb', 'log')
$script:FsK1aLatin1 = [System.Text.Encoding]::GetEncoding(28591)

function ConvertTo-FsK1aPrintable([string]$s) {
    $b = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -ge 0x20 -and [int]$ch -le 0x7e) { [void]$b.Append($ch) } else { [void]$b.AppendFormat('\x{0:x2}', [int]$ch) } }
    $b.ToString()
}

function Get-FsK1aOutcome {
    param([Parameter(Mandatory)]$Fsb1, [bool]$Collected = $true, [string]$Banner, [string]$ConfigSha, [int]$Modules = 95)
    $facts = New-Object System.Collections.Generic.List[string]
    $fails = New-Object System.Collections.Generic.List[string]
    $warn = New-Object System.Collections.Generic.List[string]
    $o = [ordered]@{ Outcome = 'INCONCLUSIVE'; Reason = ''; Facts = $facts; Failing = $fails; Warnings = $warn; WarningCount = $null; BugCount = $null
                     MemTotal = $null; KmsgFirst = $null; Steps = @(); Truncated = @(); Wrapped = $null; TaintLines = @(); TaintCount = $null }
    if (-not $Collected -or $null -eq $Fsb1 -or -not $Fsb1.Ok) {
        $o.Reason = $(if ($null -ne $Fsb1 -and -not $Fsb1.Ok) { "no valid record (FSB1 $($Fsb1.Reason) $($Fsb1.Detail))" } else { 'no complete record' })
        return [pscustomobject]$o
    }
    $out = @{}
    $bad = @()
    foreach ($st in $Fsb1.Steps) {
        $id = [string]$st['id']
        $out[$id] = $script:FsK1aLatin1.GetString([byte[]]$st['out'])
        $o.Steps += [pscustomobject]@{ I = $st['i']; Id = $id; End = $st['end']; Code = $st['code']; Sig = $st['sig']; OutLen = $st['out_len']; ErrLen = $st['err_len'] }
        if ($st.ContainsKey('out_total') -and $st.ContainsKey('out_kept') -and [long]$st['out_total'] -gt [long]$st['out_kept']) { $o.Truncated += "$id ($($st['out_total']) bytes, $($st['out_kept']) kept)" }
        if ($st['end'] -cne 'exited' -or [long]$st['code'] -ne 0) { $bad += "step $($st['i']) $id end=$($st['end']) code=$($st['code'])" }
        elseif ([long]$st['err_len'] -ne 0) { $bad += "step $($st['i']) $id wrote $($st['err_len']) bytes to stderr" }
    }
    # the kernel-log findings are reported whatever the outcome (FS-R-012 s.3)
    $k = [string]$out['kmsg']
    if ($k -cmatch '(?m)^== kmsg-lines (\d+) first=(.*)$') { $o.KmsgFirst = $Matches[2].TrimEnd("`r"); $facts.Add("kmsg: $($Matches[1]) lines, first '$(ConvertTo-FsK1aPrintable $o.KmsgFirst)'") }
    if ($k -cmatch '(?m)^== warnings (\d+) warning-lines, (\d+) bug-lines, (\d+) lines$') {
        $o.WarningCount = [long]$Matches[1]; $o.BugCount = [long]$Matches[2]
        $wl = $k.Substring($k.IndexOf($Matches[0]) + $Matches[0].Length).Split("`n") | Where-Object { $_ -ne '' }
        foreach ($l in $wl) { $warn.Add((ConvertTo-FsK1aPrintable $l)) }
    }
    # review MAJOR-1: the log must start at boot time, or early lines (and any WARNING among them) were not seen
    $o.Wrapped = -not ([string]$o.KmsgFirst -cmatch '^(<[0-9]+>)?\[\s*0\.0+')
    # review MAJOR-2: taint lines (e.g. a module licence or out-of-tree note) are reported, never a FAIL
    if ($k -cmatch '(?m)^== taint-lines (\d+)\r?$') { $o.TaintCount = [long]$Matches[1]; $after = $k.Substring($k.IndexOf($Matches[0]) + $Matches[0].Length).Split("`n"); foreach ($l in $after) { if ($l.StartsWith('== ')) { break }; if ($l.Trim() -ne '') { $o.TaintLines += (ConvertTo-FsK1aPrintable $l.TrimEnd("`r")) } } }
    $m = [string]$out['mem']
    if ($m -cmatch '(?m)^MemTotal:\s+(\d+) kB$') { $o.MemTotal = "$($Matches[1]) kB" }
    if ($bad.Count) { $o.Outcome = 'INTEGRITY FAULT'; $o.Reason = ($bad -join '; '); return [pscustomobject]$o }
    # the K1a facts
    $kn = [string]$out['kernel']
    $pv = if ($kn -cmatch "(?m)^== proc-version\n(.*)$") { $Matches[1] } else { '' }
    if ($pv -ceq $Banner) { $facts.Add('kernel: /proc/version is the pinned K1a banner (our build booted)') } else { $fails.Add("kernel: /proc/version '$(ConvertTo-FsK1aPrintable $pv)' is not the pinned banner") }
    $c = [string]$out['config']
    if ($c -cmatch '(?m)^== config_sha256 ([0-9a-f]{64})$' -and $Matches[1] -ceq $ConfigSha) { $facts.Add("config: sha256(zcat /proc/config.gz) = $ConfigSha (the gated k1a.config)") }
    else { $fails.Add('config: the running config is not the gated k1a.config (or not reported)') }
    $md = [string]$out['modules']
    $ready = $md -cmatch "(?m)STAGE=MODULES_READY ok=$Modules fail=0 "
    $loaded = $md -cmatch "(?m)^== loaded $Modules$"
    $mf = @([regex]::Matches($md, '(?m)MODULE_FAIL (\S+)') | ForEach-Object { $_.Groups[1].Value })
    if ($ready -and $loaded -and $mf.Count -eq 0) { $facts.Add("modules: MODULES_READY ok=$Modules fail=0; $Modules in /proc/modules; no MODULE_FAIL") }
    else { $fails.Add("modules: ready=$ready loaded=$loaded MODULE_FAIL=$($mf -join ',')") }
    if ($k -cmatch '(?m)^== modver-matches 0\r?$') { $facts.Add('kmsg: no symbol-version or vermagic refusal') }
    else { $fails.Add('kmsg: symbol-version or vermagic lines in the kernel log (or not reported)') }
    $fsx = [string]$out['fs']
    if ($fsx -cmatch '(?m)^nodev\s+devtmpfs$') { $facts.Add('fs: devtmpfs registered (DEVTMPFS=y)') } else { $fails.Add('fs: devtmpfs not in /proc/filesystems') }
    $u = [string]$out['usb']
    if ($u -cmatch '(?m)^== udc a600000\.dwc3 state=configured$' -and $u -cmatch '(?m)^== config-functions acm\.gs0 $') { $facts.Add('usb: UDC a600000.dwc3 configured; ACM only') }
    else { $fails.Add('usb: the gadget is not the bound ACM-only gadget') }
    if ($fails.Count) { $o.Outcome = 'K1A FAIL'; $o.Reason = ($fails -join '; '); return [pscustomobject]$o }
    if ($null -eq $o.WarningCount) { $o.Outcome = 'K1A FAIL'; $o.Reason = 'kmsg: the warning counts are missing'; return [pscustomobject]$o }
    $rv = @()
    if ($warn.Count -gt 0 -or $o.WarningCount -gt 0 -or $o.BugCount -gt 0) { $rv += "the kernel log has $($o.WarningCount) WARNING and $($o.BugCount) BUG/oops-class lines ($($warn.Count) lines listed; FS-R-012 s.3)" }
    if ($o.Wrapped) { $rv += "the kernel log had wrapped (first line '$(ConvertTo-FsK1aPrintable ([string]$o.KmsgFirst))', not at boot time): earlier lines, including any boot WARNING, were not seen" }
    if (@($o.Truncated).Count) { $rv += "step output truncated at its cap: $(@($o.Truncated) -join '; ')" }
    if ($rv.Count) {
        $o.Outcome = 'K1A REVIEW'
        $o.Reason = "every K1a fact holds; review before any further run: $($rv -join '; ')"
    } else {
        $o.Outcome = 'K1A PASS'; $o.Reason = 'every K1a fact holds; no kernel WARNING/BUG/oops-class line in the log'
    }
    [pscustomobject]$o
}

function Invoke-FsK1aClassifyDir {
    param([Parameter(Mandatory)][string]$CollectDir, [string]$ObserveDir = '', [string]$Banner, [string]$ConfigSha, [int]$Modules = 95, [bool]$AllowReplay = $false)
    $cj = Join-Path $CollectDir 'collect.json'
    if (-not (Test-Path -LiteralPath $cj -PathType Leaf)) { throw "no collect.json in $CollectDir" }
    $c = [IO.File]::ReadAllText($cj) | ConvertFrom-Json
    if ($c.Stage -cne 'k1a' -or $c.Exp -cne 'k1a') { throw "collect.json is not a K1a session (stage '$($c.Stage)', exp '$($c.Exp)')" }
    $raw = Join-Path $CollectDir 'capture.raw'
    [byte[]]$b = [IO.File]::ReadAllBytes($raw)
    $sha = Get-Fsb1Sha256Hex $b
    $consistent = ($sha -ceq [string]$c.Capture.Sha256) -and [bool]$c.Capture.Consistent
    $fsb1 = $null
    if ($c.ValveSent -and $c.Challenge -cmatch '^[0-9a-f]{32}\z') {
        $fsb1 = Test-Fsb1Record -Bytes $b -Exp 'k1a' -Nonce ([string]$c.Nonce) -Challenge ([string]$c.Challenge) -Steps $script:FsK1aSteps
    }
    $o = Get-FsK1aOutcome -Fsb1 $fsb1 -Collected ($consistent -and [string]$c.Status -like 'COLLECTED*') -Banner $Banner -ConfigSha $ConfigSha -Modules $Modules
    # review MAJOR-3 / MINOR-8: the outcome is tied to a LIVE collection of the observed attempt
    $isReplay = ($c.PSObject.Properties['Replay'] -and $null -ne $c.Replay) -or ($c.PSObject.Properties['FixtureOverrides'] -and $null -ne $c.FixtureOverrides)
    $bind = @(); $serial = ''; $obSha = ''
    if ($isReplay -and -not $AllowReplay) { $bind += 'collect.json is a replay or carries fixture overrides (not a live collection)' }
    if (-not $AllowReplay) {
        $oj = if ($ObserveDir) { Join-Path $ObserveDir 'observe.json' } else { '' }
        if (-not $oj -or -not (Test-Path -LiteralPath $oj -PathType Leaf)) { $bind += 'no observe.json of the attempt (-ObserveDir)' }
        else {
            $ob = [IO.File]::ReadAllText($oj) | ConvertFrom-Json
            if ([string]$ob.Nonce -cne [string]$c.Nonce) { $bind += "observe.json nonce $($ob.Nonce) is not the collected $($c.Nonce)" }
            if ([string]$ob.Stage -cne 'k1a') { $bind += "observe.json stage '$($ob.Stage)' is not k1a" }
            if (-not (Test-FsK1aUnit ([string]$ob.Serial))) { $bind += "observe.json unit '$($ob.Serial)' is not a K1a unit (Unit 2 QUEST3UNIT2, Unit 1 QUEST3UNIT1)" }
            else { $serial = [string]$ob.Serial; $obSha = Get-FsK1aFileSha $oj }
        }
    }
    if ($bind.Count) { $o.Reason = "not tied to a live, observed K1a attempt ($($bind -join '; ')); the record said: $($o.Outcome) ($($o.Reason))"; $o.Outcome = 'INCONCLUSIVE' }
    $o | Add-Member NoteProperty Fixture ([bool]($isReplay -and $AllowReplay))
    $o | Add-Member NoteProperty CaptureSha256 $sha
    $o | Add-Member NoteProperty CaptureConsistent $consistent
    $o | Add-Member NoteProperty Nonce ([string]$c.Nonce)
    $o | Add-Member NoteProperty CollectStatus ([string]$c.Status)
    $o | Add-Member NoteProperty Bound ([bool](-not $AllowReplay -and $bind.Count -eq 0))
    $o | Add-Member NoteProperty Serial $serial
    $o | Add-Member NoteProperty ObserveJsonSha256 $obSha
    $o | Add-Member NoteProperty CollectJsonSha256 (Get-FsK1aFileSha $cj)
    $o | Add-Member NoteProperty DoneSent ([bool]$c.DoneSent)
    $o
}

# The outcome record next to the attempt's observe.json (only for a result bound to a live, observed attempt).
# Write once (third delta review MAJOR-1): an existing record is never replaced (FileMode CreateNew); it carries the
# banner (SHA-256), config SHA-256 and module count the classifier checked, which the Unit 1 gate compares with the pins.
function Write-FsK1aClassifyRecord([Parameter(Mandatory)]$O, [Parameter(Mandatory)][string]$ObserveDir, [DateTime]$NowUtc = [DateTime]::UtcNow,
                                   [string]$Banner = $script:FsK1aPinBanner, [string]$ConfigSha = $script:FsK1aPinConfigSha, [int]$Modules = $script:FsK1aPinModules,
                                   $After = $null, [string]$ChecklistSha256 = '') {
    if (-not $O.Bound -or $O.Fixture -or -not (Test-FsK1aUnit ([string]$O.Serial)) -or $null -eq $After) { return $null }
    $p = Join-Path $ObserveDir 'classify-k1a.json'
    if (Test-Path -LiteralPath $p) { throw "classify-k1a.json already exists ($p): an outcome record is written once and never replaced" }
    $rec = [ordered]@{ Schema = $script:FsK1aClassifySchema; Utc = $NowUtc.ToUniversalTime().ToString('o'); Nonce = [string]$O.Nonce; Serial = [string]$O.Serial
                       Unit = (Get-FsK1aUnitName ([string]$O.Serial)); Outcome = [string]$O.Outcome; Reason = [string]$O.Reason; Fixture = [bool]$O.Fixture
                       CaptureSha256 = [string]$O.CaptureSha256; CollectJsonSha256 = [string]$O.CollectJsonSha256; ObserveJsonSha256 = [string]$O.ObserveJsonSha256
                       ClassifierSha256 = (Get-FsK1aFileSha (Join-Path $script:FsK1aClsDir 'fs-classify-k1a.ps1'))
                       BannerSha256 = (Get-FsK1aTextSha $Banner); ConfigSha = $ConfigSha; Modules = [string]$Modules
                       After = $After; ChecklistSha256 = $ChecklistSha256 }
    [byte[]]$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((($rec | ConvertTo-Json -Depth 8) + "`n"))
    $fs = [IO.File]::Open($p, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    $p
}

# The attempt's after-session facts: the LAST phase F entry of the attempt's checklist (observe.json ChecklistFile),
# PASS, this nonce and serial, written by the the K1a sign-off tooling (private) beside this file. Returns @{ Ok; Why; After; Sha256 }.
function Get-FsK1aAfterFacts([string]$ObserveDir, [string]$Nonce, [string]$Serial) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; After = $null; Sha256 = $null } }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    try { $ob = [IO.File]::ReadAllText((Join-Path $ObserveDir 'observe.json')) | ConvertFrom-Json } catch { return (& $no 'observe.json unreadable') }
    $cf = [string](& $pv $ob 'ChecklistFile')
    if (-not $cf -or -not (Test-Path -LiteralPath $cf -PathType Leaf)) { return (& $no "the attempt's checklist '$cf' is missing") }
    try { $j = [IO.File]::ReadAllText($cf) | ConvertFrom-Json } catch { return (& $no "the checklist $cf is unreadable") }
    # re-review MAJOR-1: the PASS phase F entries of THIS nonce; exactly one (phase F is final once it passed)
    $fs = @(@(& $pv $j 'Entries') | Where-Object { [string](& $pv $_ 'Phase') -ceq 'F' -and [string](& $pv $_ 'Result') -ceq 'PASS' -and [string](& $pv $_ 'Nonce') -ceq $Nonce })
    if ($fs.Count -eq 0) { return (& $no "phase F (after the session) has not passed for nonce $Nonce in ${cf}: run the K1a sign-off tooling (private) -Phase F once the follow-ups are finished, then classify again") }
    if ($fs.Count -ne 1) { return (& $no "${cf} holds $($fs.Count) PASS phase F entries for nonce $Nonce (exactly one is allowed)") }
    $f = $fs[0]
    if ([string](& $pv $f 'Serial') -cne $Serial) { return (& $no "the phase F entry of $cf is for unit '$(& $pv $f 'Serial')', not $Serial") }
    if ([string](& $pv $f 'ToolSha256') -cne (Get-FsK1aFileSha (Join-Path $script:FsK1aClsDir 'the K1a sign-off tooling (private)'))) { return (& $no "the phase F entry of $cf was not written by the pinned the K1a sign-off tooling (private)") }
    $a = & $pv $f 'After'
    if ($null -eq $a) { return (& $no "the phase F entry of $cf holds no after-session facts") }
    [pscustomobject]@{ Ok = $true; Why = "phase F of $cf"; After = $a; Sha256 = (Get-FsK1aFileSha $cf) }
}

if ($script:FsK1aClsInvocation -eq '.') { return }
$exit = 70
try {
    if (-not $CollectDir) { Write-Output 'usage: fs-classify-k1a.ps1 -CollectDir <dir> [-ObserveDir <dir>]'; exit 64 }
    if ($ObserveDir) {
        # narrow review MINOR-2/3: a recorded classification uses the pinned facts only, and an existing record is kept
        # (nothing is classified or printed that could be mistaken for a recorded outcome)
        if ($Banner -cne $script:FsK1aPinBanner -or $ConfigSha -cne $script:FsK1aPinConfigSha -or $Modules -ne $script:FsK1aPinModules) {
            Write-Output 'REFUSED: with -ObserveDir (a recorded outcome) -Banner, -ConfigSha and -Modules must be the pinned values (leave them out); nothing classified, nothing recorded'; exit 64 }
        $rx = Join-Path $ObserveDir 'classify-k1a.json'
        if (Test-Path -LiteralPath $rx) {
            $ox = try { [string]([IO.File]::ReadAllText($rx) | ConvertFrom-Json).Outcome } catch { 'unreadable' }
            Write-Output "NOT RECORDED: the outcome record $rx already exists (recorded outcome: $ox) and is kept; this run classifies and records nothing"; exit 64 }
    }
    $o = Invoke-FsK1aClassifyDir -CollectDir $CollectDir -ObserveDir $ObserveDir -Banner $Banner -ConfigSha $ConfigSha -Modules $Modules -AllowReplay ([bool]$AllowReplay)
    if ($o.Fixture) { Write-Output 'FIXTURE: an offline replay (-AllowReplay): not a run result' }
    Write-Output "OUTCOME: $($o.Outcome)"
    Write-Output (ConvertTo-FsK1aPrintable "REASON:  $($o.Reason)")
    Write-Output "NONCE:   $($o.Nonce)  capture sha256=$($o.CaptureSha256) consistent=$($o.CaptureConsistent)  collector=$($o.CollectStatus) fs-done-sent=$($o.DoneSent)"
    foreach ($f in $o.Facts) { Write-Output (ConvertTo-FsK1aPrintable "FACT:    $f") }
    foreach ($f in $o.Failing) { Write-Output (ConvertTo-FsK1aPrintable "FAILING: $f") }
    Write-Output "MEMTOTAL: $(if ($o.MemTotal) { $o.MemTotal } else { 'not reported' })"
    Write-Output "KERNEL WARNINGS (FS-R-012 s.3, every phase; K1a: the one record phase, the log from boot): $(if ($null -ne $o.WarningCount) { "$($o.WarningCount) WARNING, $($o.BugCount) BUG/oops-class, $($o.Warnings.Count) lines" } else { 'not reported' })"
    foreach ($w in $o.Warnings) { Write-Output "  $w" }
    Write-Output "TAINT NOTES (reported, never a FAIL): $(if ($null -ne $o.TaintCount) { $o.TaintCount } else { 'not reported' })"
    foreach ($tl in @($o.TaintLines)) { Write-Output "  $tl" }
    if (@($o.Truncated).Count) { Write-Output "TRUNCATED: $(@($o.Truncated) -join '; ')" }
    Write-Output 'MACHINE SIDE ONLY: the return to fastboot is checked at AF (<withheld capture tool> -Phase AF); the readback after-rows stay "not measured"'
    if ($ObserveDir) { Write-Output "OBSERVE: $ObserveDir" }
    if ($ObserveDir -and $o.Bound) { $aft = Get-FsK1aAfterFacts $ObserveDir $o.Nonce $o.Serial; if (-not $aft.Ok) { Write-Output "NOT RECORDED: $($aft.Why)" } }
    if ($ObserveDir -and $o.Bound -and $aft.Ok) { $rp = Write-FsK1aClassifyRecord -O $o -ObserveDir $ObserveDir -Banner $Banner -ConfigSha $ConfigSha -Modules $Modules -After $aft.After -ChecklistSha256 $aft.Sha256; if ($rp) { Write-Output "RECORDED: $rp (unit $(Get-FsK1aUnitName $o.Serial) $($o.Serial); report this result to the PM before any further K1a attempt)" } }
    $exit = switch ($o.Outcome) { 'K1A PASS' { 30 } 'K1A REVIEW' { 31 } 'K1A FAIL' { 32 } 'INTEGRITY FAULT' { 33 } default { 34 } }
} catch {
    Write-Output (ConvertTo-FsK1aPrintable "ERROR: $($_.Exception.Message)")
    $exit = 70
}
exit $exit
