# Section F of test-host2.ps1: one or more fixtures per finding of the
# adversarial review of da0ad56 (devices/quest3/host). Dot-sourced by
# test-host2.ps1 after the code under test ($CODE) has been dot-sourced.
# Every check is wrapped so that the same file can run against the reviewed
# revision (test-host2.ps1 -HostDir <da0ad56 copy> -Only F), where these checks
# are expected to FAIL, and against the current revision, where they must PASS.
# Uses only: Check, Say, Skip, B, $CODE, $Scratch, $ROOT, $python, $FIXDIR.

function FCheck([string]$name, [scriptblock]$body) {
    try { $r = & $body; Check $name ([bool]$r) } catch { Check $name $false "(threw: $($_.Exception.Message))" }
}
function Invoke-Exact([string]$Exe, [string]$ArgLine, [hashtable]$Env = @{}) {   # exact command line; stdout as bytes
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.Arguments = $ArgLine
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.Close()
        $te = $p.StandardError.ReadToEndAsync()
        $ms = New-Object System.IO.MemoryStream
        $p.StandardOutput.BaseStream.CopyTo($ms)
        $p.WaitForExit()
        [pscustomobject]@{ Code = $p.ExitCode; Out = $ms.ToArray(); Text = [Text.Encoding]::GetEncoding(28591).GetString($ms.ToArray()); Err = $te.Result }
    } finally { $p.Dispose() }
}
function Test-AllPrintable([byte[]]$b) { foreach ($x in $b) { if (($x -lt 0x20 -or $x -gt 0x7e) -and $x -ne 10 -and $x -ne 13) { return $false } }; return $true }
$q = [string][char]34
$PSX = 'powershell.exe'; $PSA = '-NoProfile -ExecutionPolicy Bypass -File '

# ---- probe captures (the reviewer's construction) ----
$FL1 = [Text.Encoding]::GetEncoding(28591); $FE = [string][char]27
$FN = 'a1b2c3d4e5f60718'; $FV = '0f1e2d3c4b5a69788796a5b4c3d2e1f0'; $FA = '5a5a0123456789ab'; $FC = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'
$FK = '5.10.198-01402-g1c5986fe21ee'; $FP = "~ # $FE[6n"; $FPS2 = "> $FE[6n"
$FSV1x = "FSV1 nonce=$FN resp=$(Get-FsSha256Hex (B "$($FN):$FV")) kernel=$FK pid1=/bin/busybox,sh,/init stages=X END"
$FD = Join-Path $Scratch 'findings'; $null = New-Item -ItemType Directory -Force $FD
function New-Probe([string]$name, $parts) {   # parts: @('R', text[, dt]) / @('W', cmd)
    $raw = New-Object IO.MemoryStream; $ix = @("FSIDX1 nonce=$FN mode=synthetic port=-"); $ms = 0
    foreach ($p in $parts) {
        $ms += $(if ($p.Count -gt 2) { $p[2] } else { 50 })
        if ($p[0] -eq 'R') { $b = $FL1.GetBytes($p[1]); $ix += "R $($raw.Length) $($b.Length) $ms"; $raw.Write($b, 0, $b.Length) }
        else { $ix += "W $($raw.Length) $ms $($p[1])" }
    }
    $rp = Join-Path $FD "$name.raw"; [IO.File]::WriteAllBytes($rp, $raw.ToArray()); [IO.File]::WriteAllLines("$rp.idx", $ix); $rp
}
function Run-Probe([string]$name, $parts) { Invoke-FsReplay -RawPath (New-Probe $name $parts) -OutDir (Join-Path $FD "$name-out") }
$head = @(@('R', $FP), @('W', "fs-verify $FV"), @('R', "fs-verify $FV`n$FSV1x`n$FP"), @('W', "fs-ack $FA"), @('R', "fs-ack $FA`nFSA1 queued END`n$FP"))

Say '== F. review findings of da0ad56 (each fails on da0ad56, passes after)'
# BLOCKER 1: the send gate
FCheck 'F1a [B1] continuation arriving during the ack settle: fs-status NOT sent' {
    $r = Run-Probe 'settle-continuation' ($head + @(@('R', "`n$FPS2", 2000), @('W', 'fs-status')))
    (@($r.Sent).Count -eq 2) -and $r.Status -ceq 'INCONCLUSIVE' -and -not $r.DoneSent }
FCheck 'F1b [B1] "Password: " arriving during the ack settle: fs-status NOT sent' {
    $r = Run-Probe 'settle-password' ($head + @(@('R', 'Password: ', 2000), @('W', 'fs-status')))
    (@($r.Sent).Count -eq 2) -and -not $r.DoneSent }
FCheck 'F1c [B1] a second, identical prompt arriving during the settle: still bytes after the settled prompt, NOT sent' {
    $r = Run-Probe 'settle-prompt-again' ($head + @(@('R', "`n$FP", 2000), @('W', 'fs-status')))
    (@($r.Sent).Count -eq 2) }
FCheck 'F1d [B1] "login: root / Password: " before the first command: nothing sent' {
    $r = Run-Probe 'pre-password' @(@('R', "login: root`nPassword: "), @('W', "fs-verify $FV"), @('R', "`n"))
    (@($r.Sent).Count -eq 0) -and $r.Status -ceq 'INCONCLUSIVE' }
FCheck 'F1e [B1] pager "--More-- (42%)" before the first command: nothing sent' {
    $r = Run-Probe 'pre-pager' @(@('R', '--More-- (42%)'), @('W', "fs-verify $FV"))
    (@($r.Sent).Count -eq 0) }
FCheck 'F1f [B1] output ending in a newline (no prompt) before the first command: nothing sent' {
    $r = Run-Probe 'pre-output' @(@('R', "some output`n"), @('W', "fs-verify $FV"))
    (@($r.Sent).Count -eq 0) }
FCheck 'F1g [B1] the prompt changes between commands (/ # instead of ~ #): fs-status NOT sent' {
    $r = Run-Probe 'prompt-changed' @(@('R', $FP), @('W', "fs-verify $FV"), @('R', "fs-verify $FV`n$FSV1x`n$FP"), @('W', "fs-ack $FA"),
        @('R', "fs-ack $FA`nFSA1 queued END`n/ # $FE[6n"), @('W', 'fs-status'))
    (@($r.Sent).Count -eq 2) }
FCheck 'F1h [B1] positive control: a quiet settle still sends fs-status' {
    $r = Run-Probe 'settle-quiet' ($head + @(@('W', 'fs-status'), @('R', "fs-status`nFSS1 nonce=$FN stages=X,HOST_ACK acked=$FA END`n$FP")))
    (@($r.Sent) -join ',') -match 'fs-status' }
FCheck 'F1i [B1] COLLECTOR.md states the send gate (rule 3)' { ([IO.File]::ReadAllText((Join-Path $CODE 'COLLECTOR.md'))) -match 'send gate' }

# SHOULD-FIX 2: E1 bypasses (PowerShell twin, Windows git)
$FG = Join-Path $FD 'git'; $null = New-Item -ItemType Directory -Force $FG
function FGit { param([string[]]$a) $o = & git -c user.name=f -c user.email=f@x -c init.defaultBranch=main -c core.autocrlf=false @a 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($a -join ' '): $o" }; ($o | Out-String).Trim() }
function FRepo($d) { $null = FGit @('init', '-q', $d); [IO.File]::WriteAllText("$d\mkbootimg.py", "print(1)`n"); [IO.File]::WriteAllText("$d\README", "r`n"); $null = FGit @('-C', $d, 'add', '-A'); $null = FGit @('-C', $d, 'commit', '-q', '-m', 'x'); FGit @('-C', $d, 'rev-parse', 'HEAD') }
FCheck 'F2a [S2] git replace <pin> <evil> (HEAD == pin, status clean): refused for the replace ref' {
    $c = FRepo "$FG\rep"; [IO.File]::WriteAllText("$FG\rep\mkbootimg.py", "EVIL`n"); $null = FGit @('-C', "$FG\rep", 'commit', '-q', '-am', 'e'); $e = FGit @('-C', "$FG\rep", 'rev-parse', 'HEAD')
    $null = FGit @('-C', "$FG\rep", 'reset', '-q', '--soft', $c); $null = FGit @('-C', "$FG\rep", 'replace', $c, $e); $null = FGit @('-C', "$FG\rep", 'update-index', '-q', '--refresh')
    $r = Test-FsGitCheckout -Repo "$FG\rep" -ExpectCommit $c
    (-not $r.Ok) -and (($r.Failures -join ' ') -match 'replace refs present') -and (($r.Failures -join ' ') -match 'file content differs') }
FCheck 'F2b [S2] objects/info/alternates present: refused' {
    $c = FRepo "$FG\alt"; $null = New-Item -ItemType Directory -Force "$FG\alt\.git\objects\info"; [IO.File]::WriteAllText("$FG\alt\.git\objects\info\alternates", "$FG\rep\.git\objects`n")
    $r = Test-FsGitCheckout -Repo "$FG\alt" -ExpectCommit $c; (-not $r.Ok) -and (($r.Failures -join ' ') -match 'alternates') }
FCheck 'F2c [S2] info/grafts present: refused' {
    $c = FRepo "$FG\grf"; [IO.File]::WriteAllText("$FG\grf\.git\info\grafts", "$c`n")
    $r = Test-FsGitCheckout -Repo "$FG\grf" -ExpectCommit $c; (-not $r.Ok) -and (($r.Failures -join ' ') -match 'grafts') }
FCheck 'F2d [S2] modification hidden from status by assume-unchanged AND a matching size/mtime: found by --no-filters content compare' {
    $c = FRepo "$FG\cmp"; [IO.File]::WriteAllText("$FG\cmp\mkbootimg.py", "print(2)`n"); $null = FGit @('-C', "$FG\cmp", 'update-index', '--assume-unchanged', 'mkbootimg.py')
    $r = Test-FsGitCheckout -Repo "$FG\cmp" -ExpectCommit $c; (-not $r.Ok) -and (($r.Failures -join ' ') -match 'file content differs from the pinned tree') }
FCheck 'F2e [S2] a nested repository / file outside the pinned tree is found by the file-system walk' {
    $c = FRepo "$FG\nest"; $null = New-Item -ItemType Directory "$FG\nest\gki"; $null = FGit @('init', '-q', "$FG\nest\gki"); [IO.File]::WriteAllText("$FG\nest\gki\hashlib.py", "x`n")
    $r = Test-FsGitCheckout -Repo "$FG\nest" -ExpectCommit $c; (-not $r.Ok) -and (($r.Failures -join ' ') -match 'gki/') -and (($r.Failures -join ' ') -match 'file-system walk|filesystem walk') }
FCheck 'F2f [S2] mode bits: Windows check states it cannot see exec bits (Evidence.mode_bits)' {
    $c = FRepo "$FG\mode"; $r = Test-FsGitCheckout -Repo "$FG\mode" -ExpectCommit $c; $r.Ok -and ($r.Evidence.Contains('mode_bits')) }
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
$toWsl = { param($p) '/mnt/' + $p.Substring(0, 1).ToLowerInvariant() + ($p.Substring(2) -replace '\\', '/') }
$gfx = Join-Path $FIXDIR 'gitcheck\run-gitcheck-fixtures.sh'
foreach ($sh in @(@('dash'), @('bash', '--posix'))) {
    if (-not $wsl) { Skip "F2g [S2] sh fixtures under WSL $($sh -join ' ')" 'wsl.exe not found'; continue }
    FCheck "F2g [S2] fs-gitcheck.sh under WSL $($sh -join ' '): all E1 fixtures incl. replace/filter/fileMode/env/alternates/grafts/nested/symlink" {
        $ErrorActionPreference = 'Continue'   # git warnings on stderr are output, not errors
        $o = @(& wsl.exe -e @sh (& $toWsl $gfx) (& $toWsl (Join-Path $CODE 'fs-gitcheck.sh')) 2>&1 | ForEach-Object { "$_" })
        foreach ($l in $o) { if ($l -match '^(FAIL|INFO|TOTAL|NOTE)') { Say "   [$($sh -join ' ')] $l" } }
        $LASTEXITCODE -eq 0 -and @($o | Where-Object { $_ -match '^TOTAL: \d+ passed, 0 failed' }).Count -eq 1 }
}
$gbash = 'C:\Program Files\Git\bin\sh.exe'
if (Test-Path $gbash) {
    FCheck 'F2h [S2] fs-gitcheck.sh under Git Bash (MSYS): all applicable E1 fixtures' {
        $msys = { param($p) '/' + $p.Substring(0, 1).ToLowerInvariant() + ($p.Substring(2) -replace '\\', '/') }
        $ErrorActionPreference = 'Continue'
        $o = @(& $gbash (& $msys $gfx) (& $msys (Join-Path $CODE 'fs-gitcheck.sh')) 2>&1 | ForEach-Object { "$_" })
        foreach ($l in $o) { if ($l -match '^(FAIL|INFO|TOTAL)') { Say "   [git-bash] $l" } }
        $LASTEXITCODE -eq 0 -and @($o | Where-Object { $_ -match '^TOTAL: \d+ passed, 0 failed' }).Count -eq 1 }
} else { Skip 'F2h Git Bash' 'not installed' }

# SHOULD-FIX 3: byte-exact binary captures (the capture tooling is withheld from this copy)
Skip 'F3a-F3d [S3] byte-exact binary capture checks' 'withheld'

# SHOULD-FIX 4: device bytes on the operator console
FCheck 'F4a [S4] FSA1 value with ESC/OSC/BEL: the collector CLI output is printable ASCII only' {
    $rp = New-Probe 'ack-esc' @(@('R', $FP), @('W', "fs-verify $FV"), @('R', "fs-verify $FV`n$FSV1x`n$FP"), @('W', "fs-ack $FA"),
        @('R', "fs-ack $FA`nFSA1 t=$FE]0;STATUS:_COLLECTED-VALID$([char]7)$FE]52;c;ZXZpbA==$([char]7) END`n$FP"))
    $r = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-collect.ps1') + $q + " -Replay $q$rp$q -OutDir $q$FD\ack-esc-cli$q")
    (Test-AllPrintable $r.Out) -and $r.Text -match '\\x1b\]0;' }
FCheck 'F4b [S4] classifier notes quoting device output (ESC, OSC 52, BEL in the hash step): CLI output printable only' {
    $st = Get-Stage2aGoodSteps -Nonce $FN -Chal $FC
    $st[0] = New-SynthStep 1 'hash' (B ("$FE]52;c;ZXZpbA==$([char]7)$FE[2J spoof`n"))
    $rec = New-SynthFsb1 -Exp 'stage2a' -Nonce $FN -Chal $FC -Steps $st
    $rp = New-Probe 'note-esc' ($head + @(@('W', 'fs-status'), @('R', "fs-status`nFSS1 nonce=$FN stages=X,HOST_ACK acked=$FA END`n$FP"),
        @('W', "fs-valve $FC"), @('R', "fs-valve $FC`n$rec$FP"), @('W', 'fs-done'), @('R', "fs-done`nFSD1 queued END`n")))
    $null = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-collect.ps1') + $q + " -Replay $q$rp$q -OutDir $q$FD\note-esc-out$q")
    $r = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-classify.ps1') + $q + " -CollectDir $q$FD\note-esc-out$q -Stage1Class PASS")
    (Test-AllPrintable $r.Out) -and $r.Text -match 'OUTCOME: INCONCLUSIVE' }

# SHOULD-FIX 5: classifier casts and exit codes
FCheck 'F5a [S5] exec-failed with errno=4294967309 is a TOOL FAULT (INCONCLUSIVE, rule 5), not a compatibility FAIL' {
    $st = Get-Stage2aGoodSteps -Nonce $FN -Chal $FC
    $st[4] = New-SynthStep 5 'uname' @() @() @{ end = 'exec-failed'; code = [long]-1; errno = [long]4294967309 }
    $o = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $FK -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $st }) -Nonce $FN -Challenge $FC -Collected $true
    $o.Outcome -ceq 'INCONCLUSIVE' -and $o.Rule -eq 5 }
FCheck 'F5b [S5] signaled with sig=999999999999999 stays FAILED (not an outside signal), and code=999999999999999 on hash is UNPARSEABLE' {
    $st = Get-Stage2aGoodSteps -Nonce $FN -Chal $FC
    $st[3] = New-SynthStep 4 'list' @() @() @{ end = 'signaled'; code = [long]-1; sig = [long]999999999999999 }
    $o1 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $FK -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $st }) -Nonce $FN -Challenge $FC -Collected $true
    $st = Get-Stage2aGoodSteps -Nonce $FN -Chal $FC
    $st[0] = New-SynthStep 1 'hash' $st[0]['out'] @() @{ code = [long]999999999999999 }
    $o2 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $FK -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $st }) -Nonce $FN -Challenge $FC -Collected $true
    $o1.Outcome -ceq 'COMPATIBILITY FAIL' -and $o2.Outcome -ceq 'INCONCLUSIVE' -and $o2.Rule -eq 4 }
FCheck 'F5c [S5] an internal classifier error (malformed pins) is INCONCLUSIVE rule 8 "classifier error", never a verdict or a skipped check' {
    $st = Get-Stage2aGoodSteps -Nonce $FN -Chal $FC
    $o = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $FK -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $st }) -Nonce $FN -Challenge $FC -Collected $true -Pins @('x', 'y', 'z', 'w')
    $o.Outcome -ceq 'INCONCLUSIVE' -and $o.Rule -eq 8 -and $o.Reason -match 'classifier error' }
FCheck 'F5d [S5] verdict exit codes never 0/1/2: classifier PASS exits 10, collector valid exits 10' {
    $rp = Join-Path $FIXDIR 'replay\good-lf.raw'
    $c = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-collect.ps1') + $q + " -Replay $q$rp$q -OutDir $q$FD\exit-codes$q")
    $k = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-classify.ps1') + $q + " -CollectDir $q$FD\exit-codes$q -Stage1Class PASS")
    $c.Code -eq 10 -and $k.Code -eq 10 }

# NITS
FCheck 'F6a [nit] disk full during capture: no throw, INCONCLUSIVE, capture error stated, fs-done not sent' {
    $r = Invoke-FsReplay -RawPath (Join-Path $FIXDIR 'replay\good-lf.raw') -OutDir "$FD\diskfull" -TestCaptureFailAfterBytes 300
    $r.Status -ceq 'INCONCLUSIVE' -and $r.StopReason -match 'capture write failed' -and -not $r.DoneSent }
FCheck 'F6b [nit] disk full, CLI: collect.json written, RECOVERY line printed, exit 14' {
    $r = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-collect.ps1') + $q + " -Replay $q$(Join-Path $FIXDIR 'replay\good-lf.raw')$q -OutDir $q$FD\diskfull-cli$q -TestCaptureFailAfterBytes 300")
    $r.Code -eq 14 -and $r.Text -match 'RECOVERY: ' -and (Test-Path "$FD\diskfull-cli\collect.json") }
FCheck 'F6c [nit] capture close fails: still a RECOVERY line, CAPTURE ERROR, exit 14 (not 2)' {
    $r = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-collect.ps1') + $q + " -Replay $q$(Join-Path $FIXDIR 'replay\good-lf.raw')$q -OutDir $q$FD\closefail-cli$q -TestCaptureFailOnClose")
    $r.Code -eq 14 -and $r.Text -match 'RECOVERY: ' -and $r.Text -match 'CAPTURE ERROR' }
FCheck 'F6d [nit] a failing write is not logged as a W line and stops everything' {
    $rp = Join-Path $FIXDIR 'replay\good-lf.raw'
    [byte[]]$raw = [IO.File]::ReadAllBytes($rp); $ix = Read-FsCaptureIndex -Path "$rp.idx" -RawLength $raw.Length
    $t = New-FsReplayTransport -Raw $raw -Index $ix
    $t | Add-Member -Force ScriptMethod WriteBytes { param([byte[]]$b) throw 'device vanished (simulated)' }
    $r = Invoke-FsCollectRun -Transport $t -OutDir "$FD\writefail" -Tokens (Get-FsReplayTokens $ix) -Cfg (New-FsCollectCfg -Nonce $ix.Nonce) -Mode 'replay'
    $w = @([IO.File]::ReadAllLines($r.Capture.Index) | Where-Object { $_ -like 'W *' })
    $w.Count -eq 0 -and @($r.Sent).Count -eq 0 -and $r.StopReason -match 'write of' -and -not $r.DoneSent }
FCheck 'F6e [nit] live Flush/Close run under a bounded timeout (a 5 s blocking call is abandoned at 100 ms)' { [FsHostNative]::SelfTestTimeout() }
FCheck 'F6f [nit] host deadline derived from the device deadline: with 3 s left the collector stops itself, says so, sends nothing more' {
    $r = Invoke-FsReplay -RawPath (Join-Path $FIXDIR 'replay\good-lf.raw') -OutDir "$FD\giveup" -Overrides @{ GiveUpMs = [long]3000 }
    $r.Status -ceq 'INCONCLUSIVE' -and $r.StopReason -match 'host' -and -not $r.DoneSent -and @($r.Sent) -notcontains 'fs-done' }
FCheck 'F6g [nit] default host give-up is the image deadline - margin 15 s (rev 3: stage2a 260 s, stage3a 170 s), and COLLECTOR.md has the timing table' {
    ((New-FsCollectCfg -Nonce $FN).GiveUpMs -eq 245000) -and ((New-FsCollectCfg -Nonce $FN -Stage '3a').GiveUpMs -eq 155000) -and (([IO.File]::ReadAllText((Join-Path $CODE 'COLLECTOR.md'))) -match 'Timing table') }
FCheck 'F6h [nit] live mode refuses to start without its timing origin (-BootStartUtc since FS-R-007 B1; -HandoffUtc at da0ad56), nothing opened' {
    $r = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-collect.ps1') + $q + " -Port COM7 -Nonce $('0' * 16) -OutDir $q$FD\nohandoff$q")
    $r.Code -eq 20 -and $r.Text -match 'BootStartUtc|HandoffUtc' -and -not (Test-Path "$FD\nohandoff") }
$img1 = Join-Path $ROOT 'relays\FS-A-005-raw\misc-ctrl1.img'
$pyS = Join-Path $ROOT 'devices\quest3\common\tools\misc_rule.py'
foreach ($mc in @(@('empty first argument', ($q + $q + ' ' + $q + $img1 + $q)), @('three arguments', (($q + $img1 + $q + ' ') * 3).Trim()), @('one argument', ($q + $img1 + $q)))) {
    FCheck "F6i [nit] misc CLI, $($mc[0]): same exit status and VERDICT/usage line as misc_rule.py" {
        $a = Invoke-Exact $PSX ($PSA + $q + (Join-Path $CODE 'fs-miscrule.ps1') + $q + ' ' + $mc[1])
        if (-not $python) { return (@(14, 64) -contains $a.Code) }
        $b = Invoke-Exact $python ('-I ' + $q + $pyS + $q + ' ' + $mc[1])
        $la = @($a.Text -split "`r?`n" | Where-Object { $_ })[-1]; $lb = @($b.Text -split "`r?`n" | Where-Object { $_ })[-1]
        $a.Code -eq $b.Code -and (($la -replace 'fs-miscrule\.ps1', 'X') -ceq ($lb -replace 'misc_rule\.py', 'X')) }
}
FCheck 'F6j [nit] test-host2.ps1 takes -OutFile' { ([IO.File]::ReadAllText((Join-Path $CODE 'test-host2.ps1'))) -match '\[string\]\$OutFile' }
FCheck 'F6k [nit] C4 is a strict check (the only write is of New-FsCommand output + LF; one $cmd assignment)' {
    $s = [IO.File]::ReadAllText((Join-Path $CODE 'fs-collect.ps1'))
    $w = [regex]::Matches($s, '\.WriteBytes\(([^\r\n]*)')
    $a = [regex]::Matches($s, '\$cmd\s*=')
    $w.Count -eq 1 -and $w[0].Groups[1].Value.StartsWith('[System.Text.Encoding]::ASCII.GetBytes($cmd + "`n"))') -and $a.Count -eq 1 -and
        $s.Substring($a[0].Index, [Math]::Min(60, $s.Length - $a[0].Index)) -match '^\$cmd = New-FsCommand -Verb \$Verb -Arg \$Arg' }
