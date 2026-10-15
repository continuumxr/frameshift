# FrameShift host — FS-R-007 B1 timing regressions (Chair ruling on FS-A-007, §3 B1).
# Runs the REAL chain offline: fs-observe.ps1's Invoke-FsObserve (fake fastboot, fake clock) prints the
# collector command; that command is run in-process through fs-collect.ps1's LIVE command-line path with
# two global aliases standing in for the device side:
#   Get-FsGadget             -> B1-FakeGadget     (reports FS-<nonce> on COM999; optional real delay)
#   New-FsRawSerialTransport -> B1-FakeTransport  (a simulated PID 1 shell on a virtual clock; it refuses
#                                                  any port name but COM999, and never opens a port)
# PowerShell resolves an alias before a function of the same name, so the collector's own code runs
# unchanged. Nothing here runs fastboot or adb, queries a device or opens a COM port.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File fixtures\b1-timing.ps1 [-HostDir <host dir under test>] [-Only T1,T2]
# Every T1-T5 must FAIL on fbca773 (the reviewed host) and PASS after; T6-T8 preserve behaviour (PASS on both);
# T9 (nit N1 of the 5c2e3f9 review) must FAIL on 5c2e3f9 and PASS after.
param([string]$HostDir = '', [string]$Scratch = '', [string]$Only = '')
$ErrorActionPreference = 'Stop'
$FIX = $PSScriptRoot
$CODE = if ($HostDir) { [IO.Path]::GetFullPath($HostDir) } else { Split-Path -Parent $PSScriptRoot }
$Q3live = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))     # sources the fixture MANIFESTs bind to (no on-device file differs)
if (-not $Scratch) { $Scratch = Join-Path ([IO.Path]::GetTempPath()) ('fs-b1-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
$null = New-Item -ItemType Directory -Force -Path $Scratch
. (Join-Path $CODE 'fs-collect.ps1')      # functions only (dot-sourced: the CLI does not run)
. (Join-Path $CODE 'fs-observe.ps1')
$COLLECT = Join-Path $CODE 'fs-collect.ps1'
$pass = 0; $fail = 0
$want = @(); if ($Only) { $want = $Only.Split(',') }
function T([string]$id, [string]$name, [scriptblock]$probe) {
    if ($want.Count -and $want -notcontains $id) { return }
    $ok = $false; $why = ''
    try { $res = & $probe; $ok = [bool]$res.Ok; $why = [string]$res.Why } catch { $why = 'threw: ' + $_.Exception.Message + ' at ' + (($_.ScriptStackTrace -split "`n") | Select-Object -First 2) -join ' < ' }
    if ($ok) { $script:pass++; Write-Output "PASS  $id $name" } else { $script:fail++; Write-Output "FAIL  $id $name" }
    if ($why) { Write-Output "        $why" }
}

# ---------------------------------------------------------------- device side (simulated) --------
$global:B1L1 = [Text.Encoding]::GetEncoding(28591)
$global:B1P = "~ # $([char]27)[6n"
$global:B1Stages = 'INIT_STARTED,MODULES_READY,ACM_SETUP_ATTEMPTED,UDC_BOUND,SHELL_READY'
function global:B1-Sha([string]$s) { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($global:B1L1.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) }
# The record builder lives in a dynamic module: synth.ps1 keeps its state in $script: variables, and a
# module gives them a scope of their own (the simulated shell is called from inside the collector's scope).
$null = New-Module -Name B1Synth -ArgumentList (Join-Path $FIX 'synth.ps1') -ScriptBlock {
    param([string]$SynthPath)
    . $SynthPath
    function B1-Record([string]$Stage, [string]$Nonce, [string]$Chal) {     # with fsb1_emit's leading empty line
        if ($Stage -ceq '3a') { "`n" + (New-SynthFsb1 -Exp 'stage3a' -Nonce $Nonce -Chal $Chal -Steps (Get-Stage3aGoodSteps -Nonce $Nonce -Chal $Chal)) }
        else { "`n" + (New-SynthFsb1 -Exp 'stage2a' -Nonce $Nonce -Chal $Chal -Steps (Get-Stage2aGoodSteps -Nonce $Nonce -Chal $Chal)) }
    }
    Export-ModuleMember -Function B1-Record
} | Import-Module -Global -DisableNameChecking
# A PID 1 shell: echoes each command, answers ReplyMs later, then prints the prompt. fs-status shows
# acked=none for the first NoneStatuses calls, then the token of the last fs-ack. The runner's record
# comes RunnerMs after the command.
function global:New-B1FakeShell {
    param([string]$Nonce, [string]$Stage, [int]$ReplyMs = 50, [int]$NoneStatuses = 0, [int]$RunnerMs = 1000)
    $t = [pscustomobject]@{ Now = [long]0; Q = (New-Object System.Collections.Generic.List[object]); Kind = 'b1-fake-shell'; Nonce = $Nonce; Stage = $Stage
                            ReplyMs = $ReplyMs; NoneLeft = $NoneStatuses; RunnerMs = $RunnerMs; AckTok = 'none'; Opened = $false
                            Writes = (New-Object System.Collections.Generic.List[string]); Beeps = (New-Object System.Collections.Generic.List[string]) }
    $t | Add-Member ScriptMethod Put { param([long]$ms, [string]$text) $this.Q.Add([pscustomobject]@{ Ms = $ms; B = $global:B1L1.GetBytes($text) }) }
    $t | Add-Member ScriptMethod Open { $this.Opened = $true }
    $t | Add-Member ScriptMethod Dispose { }
    $t | Add-Member ScriptMethod NowMs { $this.Now }
    $t | Add-Member ScriptMethod ReadBytes { param([long]$untilMs)
        if ($this.Q.Count -eq 0 -or $this.Q[0].Ms -gt $untilMs) { return ,([byte[]]@()) }
        $c = $this.Q[0]; $this.Q.RemoveAt(0); if ($c.Ms -gt $this.Now) { $this.Now = $c.Ms }
        return ,$c.B }
    $t | Add-Member ScriptMethod Idle { param([long]$untilMs)
        if ($this.Q.Count -gt 0 -and $this.Q[0].Ms -le $untilMs) { if ($this.Q[0].Ms -gt $this.Now) { $this.Now = $this.Q[0].Ms } else { $this.Now += 1 } }
        else { $this.Now = [Math]::Max($this.Now, $untilMs) } }
    $t | Add-Member ScriptMethod Beep { param([int]$f, [int]$ms) $this.Beeps.Add("$f/$ms@$($this.Now)"); $this.Now += $ms }
    $t | Add-Member ScriptMethod WriteBytes { param([byte[]]$b)
        $cmd = $global:B1L1.GetString($b).TrimEnd([char]10); $this.Writes.Add($cmd)
        $n = $this.Now; $this.Put($n + 5, "$cmd`n")
        $at = $n + $this.ReplyMs; $prompt = $true
        if ($cmd -cmatch '^fs-verify ([0-9a-f]{32})\z') {
            $this.Put($at, "FSV1 nonce=$($this.Nonce) resp=$(B1-Sha "$($this.Nonce):$($Matches[1])") kernel=5.10.198-01402-g1c5986fe21ee pid1=/bin/busybox,sh,/init stages=$($global:B1Stages) END`n")
        } elseif ($cmd -cmatch '^fs-ack ([0-9a-f]{16})\z') { $this.AckTok = $Matches[1]; $this.Put($at, "FSA1 queued END`n")
        } elseif ($cmd -ceq 'fs-status') {
            if ($this.NoneLeft -gt 0) { $this.NoneLeft--; $this.Put($at, "FSS1 nonce=$($this.Nonce) stages=$($global:B1Stages) acked=none END`n") }
            else { $this.Put($at, "FSS1 nonce=$($this.Nonce) stages=$($global:B1Stages),HOST_ACK acked=$($this.AckTok) END`n") }
        } elseif ($cmd -cmatch '^fs-(valve|display) ([0-9a-f]{32})\z') { $at = $n + $this.RunnerMs; $this.Put($at, (B1-Record $this.Stage $this.Nonce $Matches[2]))
        } elseif ($cmd -ceq 'fs-done') { $this.Put($at, "FSD1 queued END`n"); $prompt = $false }
        if ($prompt) { $this.Put($at + 5, $global:B1P) } }
    $t.Put(100, $global:B1P)
    $t
}
function global:B1-FakeGadget { param([string]$Nonce)
    $global:B1GadgetCalls++
    if ($global:B1GadgetDelayMs -gt 0) { Start-Sleep -Milliseconds $global:B1GadgetDelayMs }    # REAL time: the preparation delay under test
    [pscustomobject]@{ Present = $true; SerialOk = $true; Serials = @("FS-$Nonce"); ComPort = 'COM999'; Parent = "USB\VID_1D6B&PID_0104\FS-$Nonce" }
}
function global:B1-FakeTransport { param([string]$PortName, [int]$PollMs = 50)
    if ($PortName -cne 'COM999') { throw "fixture: refusing port name '$PortName' (only the fake COM999)" }
    $global:B1TransportCalls++
    $s = $global:B1Sim
    $global:B1LastT = New-B1FakeShell -Nonce $s.Nonce -Stage $s.Stage -ReplyMs $s.ReplyMs -NoneStatuses $s.NoneStatuses -RunnerMs $s.RunnerMs
    $global:B1LastT
}
Set-Alias -Name Get-FsGadget -Value B1-FakeGadget -Scope Global -Force
Set-Alias -Name New-FsRawSerialTransport -Value B1-FakeTransport -Scope Global -Force
if ((Get-Command Get-FsGadget).CommandType -ne 'Alias' -or (Get-Command New-FsRawSerialTransport).CommandType -ne 'Alias') { throw 'fixture: the device-side aliases did not take precedence; stopping (no real gadget query, no port)' }

# ---------------------------------------------------------------- host side (real code) --------
function New-B1Build([string]$stage, [string]$nonce) {
    $base = Join-Path $Scratch ("b1-$stage-" + [Guid]::NewGuid().ToString('N').Substring(0, 6)); $br = Join-Path $base "build\stage$stage"
    $bd = Join-Path $br "20261009T090000Z-$nonce"; $null = New-Item -ItemType Directory -Force -Path $bd
    $img = Join-Path $bd "boot-stage$stage.img"; [IO.File]::WriteAllBytes($img, [byte[]](1..64 | ForEach-Object { [byte]$_ }))
    $h = { param($f) (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Q3live $f)).Hash.ToLower() }
    $src = if ($stage -eq '2a') { "init.sh source    $(& $h 'stage2a\init.sh')  x`nfs-valve.sh       $(& $h 'stage2a\fs-valve.sh')  x`nfs-inv.sh         $(& $h 'stage2a\fs-inv.sh')  x" }
           else { "init.sh source    $(& $h 'stage3a\init.sh')  x`nfs-display.sh     $(& $h 'stage3a\fs-display.sh')  x" }
    [IO.File]::WriteAllText((Join-Path $bd 'MANIFEST.txt'), ("FrameShift Quest 3 stage-$stage image (b1 fixture)`nnonce:            $nonce   (x)`n" +
        "OUTPUT IMAGE:     boot-stage$stage.img  size=64  sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $img).Hash.ToLower())`n" +
        "stock boot        49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50  x`nstock vendor_boot 1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf  x`n$src`n"))
    [pscustomobject]@{ Img = $img; BuildRoot = $br }
}
# The observer with a fake fastboot on a fake clock that starts $BootAgoSec before NOW (real UTC):
# BootStartUtc = now - BootAgoSec; `fastboot boot` returns BootDurSec later (Th), acknowledged or timed out.
function Invoke-B1Observe([string]$Stage, [string]$Nonce, [double]$BootAgoSec, [double]$BootDurSec, [string]$Mode = 'ack') {
    $b = New-B1Build $Stage $Nonce
    $script:b1clk = [DateTime]::UtcNow.AddSeconds(-$BootAgoSec); $script:b1dur = $BootDurSec; $script:b1mode = $Mode; $script:b1fb = 0
    $o = Invoke-FsObserve -Stage $Stage -ImagePath $b.Img -ConfirmNonce $Nonce -BuildRoot $b.BuildRoot -Q3 $Q3live -GadgetWaitSec 30 `
        -Fastboot { param([string[]]$ArgList, [int]$TimeoutMs) $script:b1fb++
            if ($ArgList[0] -ceq 'devices') { return [pscustomobject]@{ ExitCode = 0; StdOut = "QUEST3UNIT1`tfastboot`r`n"; StdErr = ''; TimedOut = $false; Error = $null } }
            $script:b1clk = $script:b1clk.AddSeconds($script:b1dur)
            if ($script:b1mode -ceq 'timeout') { return [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = "Sending 'boot.img' OKAY`nBooting"; TimedOut = $true; Error = $null } }
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = "Sending 'boot.img' (41408 KB) OKAY [ 0.892s]`nBooting OKAY [10.191s]`nFinished. Total time: 11.111s`n"; TimedOut = $false; Error = $null } } `
        -Gadget { param([string]$N) [pscustomobject]@{ Present = $true; SerialOk = $true; Serials = @("FS-$N"); ComPort = 'COM999'; Parent = "USB\VID_1D6B&PID_0104\FS-$N" } } `
        -NowUtc { $script:b1clk } -Sleep { param([int]$Ms) $script:b1clk = $script:b1clk.AddMilliseconds($Ms) } -Say { param([string]$Line) }
    if ($o.Exit -ne 0 -or -not $o.Observe -or -not $o.Observe.NextCommand) { throw "observer did not produce a collector command (exit $($o.Exit): $($o.Why))" }
    $o.Observe
}
# Runs the observer's printed collector command through fs-collect.ps1's live CLI path (in-process, aliases active).
function Invoke-B1Collect($Observe, [hashtable]$Sim, [int]$GadgetDelayMs = 0) {
    $cmd = [string]$Observe.NextCommand; $tail = $cmd.Substring($cmd.IndexOf('fs-collect.ps1') + 14)
    $sp = @{}
    foreach ($m in [regex]::Matches($tail, ' -(\w+) (?:"([^"]*)"|(\S+))')) { $sp[$m.Groups[1].Value] = $(if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }) }
    if ($sp['Port'] -cne 'COM999') { throw "fixture: the collector command names port '$($sp['Port'])', not the fake COM999" }
    $global:B1Sim = @{ Nonce = $Observe.Nonce; Stage = $Observe.Stage; ReplyMs = 50; NoneStatuses = 0; RunnerMs = 1000 }
    foreach ($k in $Sim.Keys) { $global:B1Sim[$k] = $Sim[$k] }
    $global:B1GadgetDelayMs = $GadgetDelayMs; $global:B1GadgetCalls = 0; $global:B1TransportCalls = 0; $global:B1LastT = $null
    $tA = [DateTime]::UtcNow
    $out = @(& $COLLECT @sp *>&1 | ForEach-Object { "$_" }); $exit = $LASTEXITCODE
    $jp = Join-Path $sp['OutDir'] 'collect.json'
    $j = if (Test-Path -LiteralPath $jp) { [IO.File]::ReadAllText($jp) | ConvertFrom-Json } else { $null }
    $writes = @(); if ($global:B1LastT) { $writes = @($global:B1LastT.Writes) }
    $beeps = @(); if ($global:B1LastT) { $beeps = @($global:B1LastT.Beeps) }
    [pscustomobject]@{ Args = $sp; Out = $out; Exit = $exit; J = $j; TA = $tA; Writes = [string[]]$writes; Beeps = [string[]]$beeps; Gadget = $global:B1GadgetCalls; Transport = $global:B1TransportCalls }
}
function Verbs($w) { (@($w) | Where-Object { $_ } | ForEach-Object { $_.Split(' ')[0] }) -join ',' }
function Brief($r) { "exit=$($r.Exit) writes=$(Verbs $r.Writes) stop='$(if ($r.J) { $r.J.StopReason })' giveUpMs=$(if ($r.J) { $r.J.GiveUpMs }) ackGiveUpMs=$(if ($r.J) { $r.J.AckGiveUpMs }) args=$(($r.Args.Keys | Sort-Object | ForEach-Object { "$_" }) -join '/') out='$((@($r.Out) | Where-Object { $_ -match 'HOST GIVE-UP|REFUSED' }) -join ' ')'" }
$U = { param([string]$v) [DateTime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }

Write-Output "== FS-R-007 B1 timing regressions, code under test: $CODE"
Write-Output "   (device side simulated: fake fastboot, fake gadget, simulated shell on COM999; no device, no port)"

# Closure 1: an acknowledged handoff whose host return is delayed after T0. The Chair's timeline:
# fastboot boot invoked at 0 (BootStartUtc), T0 ~2, `fastboot boot` returns at 60 (Th, acknowledged),
# collector starts at 80. A slow shell records the ack ~43 s after collector start.
T 'T1' 'stage 3a, Chair counterexample (start 0, T0 2, return 60, collector 80): the runner is refused (INCONCLUSIVE, no fs-display, gated fs-done)' {
    $ob = Invoke-B1Observe '3a' 'b1b1b1b1b1b10001' 80 60 'ack'
    $r = Invoke-B1Collect $ob @{ ReplyMs = 9000; NoneStatuses = 1; RunnerMs = 10000 }
    $ok = $r.Gadget -eq 1 -and $r.Transport -eq 1 -and $r.J -and -not $r.J.ValveSent -and @($r.Writes | Where-Object { $_ -like 'fs-display *' }).Count -eq 0 -and
          $r.J.StopReason -match 'runner budget' -and $r.J.DoneSent -and $ob.HandoffClass -ceq 'HANDOFF_ACKNOWLEDGED'
    @{ Ok = $ok; Why = (Brief $r) } }
T 'T2' 'stage 2a, the same timeline: the runner is refused (INCONCLUSIVE, no fs-valve, gated fs-done)' {
    $ob = Invoke-B1Observe '2a' 'b1b1b1b1b1b10002' 80 60 'ack'
    $r = Invoke-B1Collect $ob @{ ReplyMs = 9000; NoneStatuses = 1; RunnerMs = 3000 }
    $ok = $r.Gadget -eq 1 -and $r.Transport -eq 1 -and $r.J -and -not $r.J.ValveSent -and @($r.Writes | Where-Object { $_ -like 'fs-valve *' }).Count -eq 0 -and
          $r.J.StopReason -match 'runner budget' -and $r.J.DoneSent
    @{ Ok = $ok; Why = (Brief $r) } }
# Closure 2: delayed gadget discovery / transport preparation (20 s, real time) must not extend the
# effective host stop or the ack budget. Th = BootStartUtc here (an instant fastboot), so only the
# preparation differs from the reviewed code.
T 'T3' 'stage 2a, 20 s gadget discovery: host give-up and ack give-up on the transport clock are both <= (absolute deadline - collector start - 20 s); collection still VALID' {
    $ob = Invoke-B1Observe '2a' 'b1b1b1b1b1b10003' 10 0 'ack'
    $r = Invoke-B1Collect $ob @{ } 20000
    $o = & $U $ob.BootStartUtc
    $remGive = ($o.AddSeconds(245) - $r.TA).TotalMilliseconds; $remAck = ($o.AddSeconds(135) - $r.TA).TotalMilliseconds
    $ok = $r.J -and $r.J.GiveUpMs -le ($remGive - 20000 + 1500) -and $r.J.AckGiveUpMs -le ($remAck - 20000 + 1500) -and $r.J.Status -ceq 'COLLECTED-VALID' -and $r.J.DoneSent
    @{ Ok = $ok; Why = "bound giveUp<=$([long]($remGive - 18500)) ack<=$([long]($remAck - 18500)); " + (Brief $r) } }
T 'T4' 'stage 3a, 20 s preparation pushes the remaining budget below the 60 s start minimum: refused after preparation, nothing sent (exit 20)' {
    $ob = Invoke-B1Observe '3a' 'b1b1b1b1b1b10004' 85 0 'ack'      # 155 - 85 = 70 s at collector start, ~50 s after 20 s of preparation
    $r = Invoke-B1Collect $ob @{ } 20000
    $ok = $r.Exit -eq 20 -and @($r.Writes).Count -eq 0 -and -not $r.J -and (@($r.Out) -join ' ') -match 'refused'
    @{ Ok = $ok; Why = (Brief $r) } }
# A: the origin is BootStartUtc for every handoff class; Th is kept as evidence.
T 'T5' 'acknowledged handoff: the collector command passes -BootStartUtc (origin) and -HandoffUtc (evidence); collect.json Timing records origin BootStartUtc and the absolute give-up' {
    $ob = Invoke-B1Observe '2a' 'b1b1b1b1b1b10005' 30 11 'ack'
    $r = Invoke-B1Collect $ob @{ }
    $tm = if ($r.J -and $r.J.PSObject.Properties.Name -contains 'Timing') { $r.J.Timing } else { $null }
    $ok = $r.Args['BootStartUtc'] -ceq $ob.BootStartUtc -and $r.Args['HandoffUtc'] -ceq $ob.HandoffUtc -and $null -ne $tm -and $tm.BudgetOrigin -ceq 'BootStartUtc' -and
          $tm.BootStartUtc -ceq (& $U $ob.BootStartUtc).ToString('o') -and $tm.GiveUpUtc -ceq (& $U $ob.BootStartUtc).AddSeconds(245).ToString('o') -and $r.J.Status -ceq 'COLLECTED-VALID'
    @{ Ok = $ok; Why = (Brief $r) } }
# Closure 4: preserved behaviour.
T 'T6' 'preserved: stage 3a normal collection through the live path (handoff 11 s, collector +15 s): fs-display sent, COLLECTED-VALID, beeps, fs-done' {
    $ob = Invoke-B1Observe '3a' 'b1b1b1b1b1b10006' 15 11 'ack'
    $r = Invoke-B1Collect $ob @{ RunnerMs = 10200 }
    $ok = $r.J -and $r.J.Status -ceq 'COLLECTED-VALID' -and $r.J.ValveSent -and $r.J.DoneSent -and (Verbs $r.Writes) -ceq 'fs-verify,fs-ack,fs-status,fs-display,fs-done' -and @($r.Beeps).Count -eq 2
    @{ Ok = $ok; Why = (Brief $r) } }
T 'T7' 'preserved: stage 2a normal collection through the live path: fs-valve sent, COLLECTED-VALID, fs-done' {
    $ob = Invoke-B1Observe '2a' 'b1b1b1b1b1b10007' 15 11 'ack'
    $r = Invoke-B1Collect $ob @{ }
    $ok = $r.J -and $r.J.Status -ceq 'COLLECTED-VALID' -and $r.J.ValveSent -and $r.J.DoneSent -and (Verbs $r.Writes) -ceq 'fs-verify,fs-ack,fs-status,fs-valve,fs-done'
    @{ Ok = $ok; Why = (Brief $r) } }
T 'T8' 'preserved: uncertain handoff (fastboot boot timed out after 120 s): origin = boot START, the ack window is spent, refused at start, nothing sent (exit 20)' {
    $ob = Invoke-B1Observe '2a' 'b1b1b1b1b1b10008' 125 120 'timeout'
    $r = Invoke-B1Collect $ob @{ }
    $ok = $ob.HandoffClass -ceq 'INCONCLUSIVE' -and $r.Exit -eq 20 -and @($r.Writes).Count -eq 0 -and $r.Gadget -eq 0
    @{ Ok = $ok; Why = (Brief $r) } }
# N1 (review of 5c2e3f9): a future origin (clock step or bad input) would inflate the budget: refused outright.
T 'T9' 'a -BootStartUtc 3 s in the future is refused before any preparation (no gadget query, nothing sent, exit 20)' {
    $ob = Invoke-B1Observe '2a' 'b1b1b1b1b1b10009' 10 0 'ack'
    $fut = [DateTime]::UtcNow.AddSeconds(3).ToString('o')
    $ob.NextCommand = $ob.NextCommand -replace '-BootStartUtc \S+', "-BootStartUtc $fut" -replace '-HandoffUtc \S+', "-HandoffUtc $fut"
    $r = Invoke-B1Collect $ob @{ }
    $ok = $r.Exit -eq 20 -and $r.Gadget -eq 0 -and @($r.Writes).Count -eq 0 -and (@($r.Out) -join ' ') -match 'later than now'
    @{ Ok = $ok; Why = (Brief $r) } }
Remove-Item Alias:\Get-FsGadget, Alias:\New-FsRawSerialTransport -Force -ErrorAction SilentlyContinue
Write-Output "TOTAL: $pass passed, $fail failed"
