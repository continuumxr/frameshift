# FrameShift host fixtures, stage 2a and stage 3a (Windows PowerShell 5.1). No device, no
# adb/fastboot, no COM port. Exit 0 only if every check passes.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\test-host2.ps1 [-Scratch <dir>] [-OutFile <file>]
#   -OutFile  where the log is written (default: test-host2.output.txt beside this script)
#   -HostDir  the code under test (default: this directory). Used to run section F against
#             the reviewed revision: -HostDir <da0ad56 copy> -Only F (there F must FAIL)
#   -Only F   run section F only
# Sections:
#   N  BLAKE2b (RFC 7693, OUTCOMES KAT, Python hashlib)
#   C  command construction: device bytes can never reach a write
#   R  Replay of every capture in fixtures\replay\CASES.tsv through fs-collect.ps1
#   X  Replay robustness: tampered index, divergence, refusals
#   K  outcome classifier: every OUTCOMES §6 rule and precedence edge, §3-§5 classes,
#      and step 8 `inv` (informational: never changes the class; OUTCOMES rev 4)
#   L  step-4 `list` rule versions (fixtures\listing-rule.ps1; FS-R-009 §4): v1 (registered) on
#      the real trial (i) record and CLI, amended rule A (v2A) on device, qemu and negative cases
#   S  stage-3a classifier: every OUTCOMES §8 rule, the FSP1 stream check (vs Python
#      check_stream.py), the -Stage 3a collector/classifier CLI
#   O  fs-observe.ps1 (fix round 6, e2e B1): sign-off gate, manifest/ledger refusals, exactly one
#      fake `fastboot boot`, no serial session; then a dry end-to-end observer -> collector ->
#      classifier (-ObserveDir) run with a fake fastboot and a fake serial device
#   M  misc rule: PowerShell port vs common/tools/misc_rule.py, full output, case for case
#   G  E1 git checks: PowerShell (Windows git) and POSIX sh (WSL dash and bash --posix)
#   B  before/after command data: read-only allowlist (withheld: SKIP)
#   F  review findings of da0ad56 (fixtures\findings-da0ad56.ps1)
param([string]$Scratch = '', [string]$OutFile = '', [string]$HostDir = '', [string]$Only = '')
$ErrorActionPreference = 'Stop'
$CODE = if ($HostDir) { [IO.Path]::GetFullPath($HostDir) } else { $PSScriptRoot }
$FIXDIR = Join-Path $PSScriptRoot 'fixtures'
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'test-host2.output.txt' }
. (Join-Path $CODE 'fs-collect.ps1')       # dot-sourced: defines functions, runs nothing
. (Join-Path $CODE 'fs-classify.ps1')
. (Join-Path $CODE 'fs-miscrule.ps1')
. (Join-Path $CODE 'fs-gitcheck.ps1')
. (Join-Path $CODE 'fs-observe.ps1')
. (Join-Path $FIXDIR 'synth.ps1')
$HOSTDIR = $CODE
$ROOT = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if (-not $Scratch) { $Scratch = Join-Path ([IO.Path]::GetTempPath()) ("fs-host2-" + (New-FsHex 4)) }
$null = New-Item -ItemType Directory -Force -Path $Scratch
$script:pass = 0; $script:fail = 0; $script:skip = 0
$script:log = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $script:log.Add($s); Write-Host $s }
function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Say "PASS  $name" } else { $script:fail++; Say "FAIL  $name $detail" }
}
function Skip([string]$name, [string]$why) { $script:skip++; Say "SKIP  $name ($why)" }
function B([string]$s) { ,([System.Text.Encoding]::GetEncoding(28591).GetBytes($s)) }
$python = $null
foreach ($cand in 'python', 'python3') { try { $v = & $cand -I -c 'import sys;print(sys.version_info[0])' 2>$null; if ($v -eq '3') { $python = $cand; break } } catch {} }
Say "== test-host2  $(Get-Date -Format o)  PowerShell $($PSVersionTable.PSVersion)  code=$CODE  scratch=$Scratch  python=$python"
if ($Only -ne 'F') {

# ------------------------------------------------------------------ N --------
Say '== N. BLAKE2b-512 (host computation for OUTCOMES §5 b2chal)'
Check 'N1 empty input = OUTCOMES §5 KAT' ((Get-FsBlake2bHex @()) -ceq $script:S2Kat)
Check 'N2 "abc" = RFC 7693 Appendix A' ((Get-FsBlake2bHex (B 'abc')) -ceq 'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923')
if ($python) {
    $inputs = @('', 'a1b2c3d4e5f60718:c3c3a1b2c3d4e5f60718293a4b5c6d7e', ('x' * 127), ('y' * 128), ('z' * 129), ('w' * 256), ('v' * 1000))
    $k = 0
    foreach ($s in $inputs) {
        $k++
        $hexin = [FsHostNative]::Hex((B $s))
        $py = (& $python -I -c "import hashlib,sys;print(hashlib.blake2b(bytes.fromhex(sys.argv[1][1:])).hexdigest())" "h$hexin")   # prefix: PS 5.1 drops empty native arguments
        Check "N3.$k length $($s.Length) equals Python hashlib" ((Get-FsBlake2bHex (B $s)) -ceq $py)
    }
} else { Skip 'N3 Python hashlib cross-check' 'python not found' }

# ------------------------------------------------------------------ C --------
Say '== C. commands: fixed verbs, host tokens, [a-z0-9 -] only'
$okCmds = @(@('fs-verify', ('a' * 32)), @('fs-ack', ('0' * 16)), @('fs-status', ''), @('fs-valve', ('f' * 32)), @('fs-display', ('e' * 32)), @('fs-done', ''))
foreach ($c in $okCmds) { Check "C1 accepted: $($c[0])" ((New-FsCommand $c[0] $c[1]) -cmatch '^[a-z0-9 -]+\z') }
$bad = @(   # parenthesised: in PowerShell ',' binds tighter than '+'
    @('fs-verify', ('a' * 31)), @('fs-verify', ('A' * 32)), @('fs-verify', (('a' * 32) + "`n")), @('fs-verify', (('a' * 30) + '"x')),
    @('fs-verify', (('a' * 30) + "';")), @('fs-ack', (('0' * 15) + '$')), @('fs-status', 'x'), @('fs-done', '"'),
    @('cat', '/proc/cmdline'), @('fs-verify', ''), @('fs-valve', (('f' * 32) + ' ; reboot')), @('"', ''), @('fs-verify', (('a' * 32) + "`r"))
)
$k = 0
foreach ($c in $bad) { $k++; $threw = $false; try { $null = New-FsCommand $c[0] $c[1] } catch { $threw = $true }; Check "C2.$k refused: '$($c[0])' + '$($c[1] -replace "`n", '\n' -replace "`r", '\r')'" $threw }
$src = [IO.File]::ReadAllText((Join-Path $HOSTDIR 'fs-collect.ps1'))
$calls = [regex]::Matches($src, '\.WriteBytes\(')
Check 'C3 exactly one WriteBytes call site in fs-collect.ps1 (Invoke-FsPhase)' ($calls.Count -eq 1) "found $($calls.Count)"
$wArgs = [regex]::Matches($src, '\.WriteBytes\(([^\r\n]*)'); $cmdAssign = [regex]::Matches($src, '\$cmd\s*=')
Check 'C4 ...and it writes exactly ASCII($cmd + LF), with $cmd assigned once, from New-FsCommand' ($wArgs.Count -eq 1 -and
    $wArgs[0].Groups[1].Value.StartsWith('[System.Text.Encoding]::ASCII.GetBytes($cmd + "`n"))') -and $cmdAssign.Count -eq 1 -and
    $src.Substring($cmdAssign[0].Index, [Math]::Min(60, $src.Length - $cmdAssign[0].Index)) -match '^\$cmd = New-FsCommand -Verb \$Verb -Arg \$Arg')
Check 'C5 no ReadExisting/ReadLine/ReadTo (text decoding) in the capture path' (-not ($src -match 'ReadExisting|\.ReadLine\(|\.ReadTo\('))

# ------------------------------------------------------------------ R --------
Say '== R. Replay of synthetic and real-encoder captures (fixtures\replay)'
$FX = Join-Path $FIXDIR 'replay'
$man = @{}
foreach ($l in [IO.File]::ReadAllLines((Join-Path $FX 'MANIFEST.sha256'))) { if ($l -cmatch '^([0-9a-f]{64})  (\S+)\z') { $man[$Matches[2]] = $Matches[1] } }
$mok = $true
foreach ($n in $man.Keys) { if ((Get-FsSha256Hex ([IO.File]::ReadAllBytes((Join-Path $FX $n)))) -cne $man[$n]) { $mok = $false; Say "   manifest mismatch: $n" } }
Check "R0 fixtures\replay matches MANIFEST.sha256 ($($man.Count) files)" $mok
$results = @{}
foreach ($row in [IO.File]::ReadAllLines((Join-Path $FX 'CASES.tsv'))) {
    if (-not $row -or $row.StartsWith('#')) { continue }
    $c = $row.Split("`t")
    $name = $c[0]; $wantStatus = $c[1]; $wantStop = $c[2]; $wantSent = $c[3]; $wantFsb = $c[4]; $wantClass = $c[5]; $ovs = $c[6]
    $ov = @{}
    if ($ovs -ne '-') { foreach ($kv in $ovs.Split(';')) { $p = $kv.Split('=', 2); if ($p[0] -ceq 'Steps') { $ov.Steps = $p[1].Split('|') } elseif ($p[1] -cmatch '^\d+$') { $ov[$p[0]] = [int]$p[1] } else { $ov[$p[0]] = $p[1] } } }
    $out = Join-Path $Scratch "replay-$name"
    try { $r = Invoke-FsReplay -RawPath (Join-Path $FX "$name.raw") -OutDir $out -Overrides $ov } catch { Check "R $name" $false "threw: $($_.Exception.Message)"; continue }
    $results[$name] = $r
    $verbs = if (@($r.Sent).Count) { (@($r.Sent) | ForEach-Object { $_.Split(' ')[0] }) -join ',' } else { 'none' }
    $fsb = if ($null -eq $r.Fsb1) { '-' } else { $r.Fsb1.Reason }
    $stopOk = ($wantStop -eq '-' -and -not $r.StopReason) -or ($wantStop -ne '-' -and $r.StopReason -and $r.StopReason.Contains($wantStop))
    $cls = '-'
    if ($wantClass -ne '-') {
        if ($ov.ContainsKey('Stage') -and $ov.Stage -ceq '3a') {
            $o = Get-FsStage3aOutcome -Stage1Class 'PASS' -Fsb1 $r.Fsb1Decoded -Nonce $r.Nonce -Challenge $r.Challenge -Collected ([bool]$r.RecordComplete)
        } else {
            $o = Get-FsStage2aOutcome -Stage1Class 'PASS' -Kernel $(if ($r.Verified) { $r.Kernel } else { '' }) -Fsb1 $r.Fsb1Decoded -Nonce $r.Nonce -Challenge $r.Challenge -Collected ([bool]$r.RecordComplete)
        }
        $cls = $o.Outcome
    }
    $ok = ($r.Status -ceq $wantStatus) -and $stopOk -and ($verbs -ceq $wantSent) -and ($fsb -ceq $wantFsb) -and ($cls -ceq $wantClass) -and
          $r.Capture.Consistent -and $r.Replay.RecaptureIsSourcePrefix -and (@($r.Replay.Divergence).Count -eq 0)
    Check ("R {0,-34} {1} | sent={2} | fsb1={3} | class={4}" -f $name, $r.Status, $verbs, $fsb, $cls) $ok `
        "(want $wantStatus / '$wantStop' / $wantSent / $wantFsb / $wantClass; stop='$($r.StopReason)' consistent=$($r.Capture.Consistent) prefix=$($r.Replay.RecaptureIsSourcePrefix) div=$(@($r.Replay.Divergence) -join ';'))"
}
# properties that need more than the table
if ($results.ContainsKey('continuation-after-verify')) {
    Check 'R+1 continuation: the 3 writes a blind collector made are NOT made' (@($results['continuation-after-verify'].Replay.UnperformedWrites).Count -eq 3)
}
if ($results.ContainsKey('pre-continuation')) {
    Check 'R+2 pre-continuation: zero bytes sent' (@($results['pre-continuation'].Sent).Count -eq 0 -and @($results['pre-continuation'].Replay.UnperformedWrites).Count -eq 1)
}
foreach ($n in 'good-lf', 'good-crlf', 'good-crcrlf', 'binary-noise-pre', 'good-split-reads') {
    if (-not $results.ContainsKey($n)) { continue }
    $r = $results[$n]
    $src = [IO.File]::ReadAllBytes((Join-Path $FX "$n.raw")); $re = [IO.File]::ReadAllBytes($r.Capture.Path)
    Check "R+3 $n re-capture is byte-identical to the source and its SHA-256 matches" ($src.Length -eq $re.Length -and (Get-FsSha256Hex $src) -ceq $r.Capture.Sha256)
}
foreach ($n in 'good-lf', 'good-crlf') {
    if (-not $results.ContainsKey($n)) { continue }
    $ph = @($results[$n].Phases)
    Check "R+4 $n echo recognised as echo on every phase, never as completion" (@($ph | Where-Object { $_.Echo -cne 'exact' }).Count -eq 0)
}
if ($results.ContainsKey('no-echo-leading-newline')) { Check 'R+5 no-echo target: echo absent on every phase' (@($results['no-echo-leading-newline'].Phases | Where-Object { $_.Echo -cne 'absent' }).Count -eq 0) }
foreach ($n in 'truncated-record', 'late-record', 'no-prompt-after-record', 'continuation-after-record', 'verify-echoed-challenge', 'verify-no-prompt') {
    if ($results.ContainsKey($n)) { Check "R+6 $n : fs-done not sent (state unknown or unverified)" (-not $results[$n].DoneSent) }
}
if ($results.ContainsKey('good-lf')) {
    $j = Join-Path $Scratch 'replay-good-lf\collect.json'
    Save-FsCollectJson -Result $results['good-lf'] -Path $j
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -CollectDir (Join-Path $Scratch 'replay-good-lf') -Stage1Class PASS
    Check 'R+7 fs-classify.ps1 CLI on the good-lf collection: OUTCOME PASS (rule 7)' (($cl -join "`n") -match 'OUTCOME: PASS ' -and $LASTEXITCODE -eq 10) ($cl -join ' / ')
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -CollectDir (Join-Path $Scratch 'replay-good-lf') -Stage1Class 'TRANSPORT/SHELL FAILURE'
    Check 'R+8 fs-classify.ps1 CLI with stage 1 not PASS: that class (rule 1), exit 13' (($cl -join "`n") -match 'OUTCOME: TRANSPORT/SHELL FAILURE' -and $LASTEXITCODE -eq 13)
}

# ------------------------------------------------------------------ X --------
Say '== X. Replay robustness and refusals'
$g = Join-Path $FX 'good-lf.raw'; $gi = [IO.File]::ReadAllLines("$g.idx")
function Try-Replay([string]$raw, [string]$idx, [string]$out, [string]$nonce = '') {
    try { $null = Invoke-FsReplay -RawPath $raw -IndexPath $idx -OutDir $out -Nonce $nonce; return 'ok' } catch { return $_.Exception.Message }
}
$t = Join-Path $Scratch 'x-gap.idx'; $lines = [System.Collections.Generic.List[string]]$gi
$rIx = @(for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k].StartsWith('R ')) { $k } }); $lines.RemoveAt($rIx[4]); [IO.File]::WriteAllLines($t, $lines)
Check 'X1 index with a missing read chunk (mid-capture) is refused' ((Try-Replay $g $t (Join-Path $Scratch 'x1')) -match 'not contiguous|write offset')
$t = Join-Path $Scratch 'x-hdr.idx'; $lines = [System.Collections.Generic.List[string]]$gi; $lines[0] = 'FSIDX1 nonce=XYZ mode=live port=-'; [IO.File]::WriteAllLines($t, $lines)
Check 'X2 index with a bad header is refused' ((Try-Replay $g $t (Join-Path $Scratch 'x2')) -match 'bad header')
$t = Join-Path $Scratch 'x-short.raw'; $rb = [IO.File]::ReadAllBytes($g); [IO.File]::WriteAllBytes($t, $rb[0..($rb.Length - 2)])
Check 'X3 capture shorter than its index is refused' ((Try-Replay $t "$g.idx" (Join-Path $Scratch 'x3')) -match 'index covers')
Check 'X4 -Nonce differing from the index nonce is refused' ((Try-Replay $g "$g.idx" (Join-Path $Scratch 'x4') 'ffffffffffffffff') -match 'differs')
$null = New-Item -ItemType Directory -Force (Join-Path $Scratch 'x5')
Check 'X5 existing output directory is refused (captures are never overwritten)' ((Try-Replay $g "$g.idx" (Join-Path $Scratch 'x5')) -match 'already exists')
$t = Join-Path $Scratch 'x-div.idx'; $lines = [System.Collections.Generic.List[string]]$gi
for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -cmatch '^W \d+ \d+ fs-status\z') { $lines[$k] = $lines[$k] -replace 'fs-status\z', 'fs-done' } }
[IO.File]::WriteAllLines($t, $lines)
$r = Invoke-FsReplay -RawPath $g -IndexPath $t -OutDir (Join-Path $Scratch 'x6')
Check 'X6 divergence (collector write differs from the recorded write): reported, no further device bytes, INCONCLUSIVE' (@($r.Replay.Divergence).Count -ge 1 -and $r.Status -ceq 'INCONCLUSIVE' -and $r.StopReason -match 'fs-status: silent')
$cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-collect.ps1') -Port 'COM7;x' -Nonce ('0' * 16) -OutDir (Join-Path $Scratch 'x7')
Check 'X7 CLI refuses a malformed -Port (no port is opened), exit 20' ($LASTEXITCODE -eq 20 -and ($cli -join ' ') -match 'Port must be given explicitly' -and -not (Test-Path (Join-Path $Scratch 'x7')))
$cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-collect.ps1') -Nonce ('0' * 16) -OutDir (Join-Path $Scratch 'x8')
Check 'X8 CLI refuses to run without -Port (never auto-picks), exit 20' ($LASTEXITCODE -eq 20 -and ($cli -join ' ') -match 'Port must be given explicitly')
$cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-collect.ps1') -Replay $g -OutDir (Join-Path $Scratch 'x9')
Check 'X9 CLI replay of good-lf: exit 10, collect.json written' ($LASTEXITCODE -eq 10 -and (Test-Path (Join-Path $Scratch 'x9\collect.json')))
# FS-R-007 B1: live mode needs the conservative origin; both refusals come before any gadget query or port
$cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-collect.ps1') -Port COM999 -Nonce ('0' * 16) -HandoffUtc ([DateTime]::UtcNow.ToString('o')) -OutDir (Join-Path $Scratch 'x10')
Check 'X10 B1 live CLI with -HandoffUtc but no -BootStartUtc: refused (Th is evidence, never the origin), exit 20, nothing written' ($LASTEXITCODE -eq 20 -and ($cli -join ' ') -match 'BootStartUtc' -and ($cli -join ' ') -match 'nothing was sent' -and -not (Test-Path (Join-Path $Scratch 'x10'))) ($cli -join ' / ')
$cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-collect.ps1') -Port COM999 -Nonce ('0' * 16) -BootStartUtc ([DateTime]::UtcNow.ToString('o')) -HandoffUtc ([DateTime]::UtcNow.AddSeconds(-30).ToString('o')) -OutDir (Join-Path $Scratch 'x11')
Check 'X11 B1 live CLI with -HandoffUtc earlier than -BootStartUtc: refused (inconsistent observer times), exit 20' ($LASTEXITCODE -eq 20 -and ($cli -join ' ') -match 'precedes -BootStartUtc') ($cli -join ' / ')

# ------------------------------------------------------------------ K --------
Say '== K. outcome classifier (OUTCOMES.md rev 3)'
$KN = 'a1b2c3d4e5f60718'; $KC = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'; $KK = $script:SynKernel
$pins = Get-FsS2Pins
function Good { Get-Stage2aGoodSteps -Nonce $KN -Chal $KC }
function Rec($steps) { [pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $steps } }
function Put($steps, [int]$i, [string]$out = $null, [string]$err = $null, [hashtable]$f = @{}) {
    $o = $steps[$i - 1]
    [byte[]]$ob = $o['out']; if ($null -ne $out) { $ob = B $out }
    [byte[]]$eb = $o['err']; if ($null -ne $err) { $eb = B $err }
    $steps[$i - 1] = New-SynthStep $i $o['id'] $ob $eb $f
    ,$steps
}
$hashOut = (($pins | ForEach-Object { "$($_.Sha256)  $($_.Path)`n" }) -join '')
$hl = @($pins | ForEach-Object { "$($_.Sha256)  $($_.Path)" })
$kcases = New-Object System.Collections.Generic.List[object]
function KC([string]$name, [string]$want, [int]$rule, [scriptblock]$make, [string]$stage1 = 'PASS', [bool]$collected = $true, [string]$note = '') {
    $kcases.Add([pscustomobject]@{ Name = $name; Want = $want; Rule = $rule; Make = $make; Stage1 = $stage1; Collected = $collected; Note = $note })
}
KC 'K01 all steps correct' 'PASS' 7 { Rec (Good) }
KC 'K02 stage 1 DEVICE_REJECTED (valid record ignored)' 'DEVICE_REJECTED' 1 { Rec (Good) } 'DEVICE_REJECTED'
KC 'K03 stage 1 TRANSPORT/SHELL FAILURE' 'TRANSPORT/SHELL FAILURE' 1 { Rec (Good) } 'TRANSPORT/SHELL FAILURE'
KC 'K04 stage 1 INCONCLUSIVE beats a valid record' 'INCONCLUSIVE' 1 { Rec (Good) } 'INCONCLUSIVE'
KC 'K05 stage 1 not PASS beats a rejected record (1 before 2)' 'DEVICE_REJECTED' 1 { [pscustomobject]@{ Ok = $false; Reason = 'no-end'; Steps = $null } } 'DEVICE_REJECTED'
KC 'K06 no FSB1 record' 'INCONCLUSIVE' 2 { $null }
KC 'K07 FSB1 rejected (no-end)' 'INCONCLUSIVE' 2 { [pscustomobject]@{ Ok = $false; Reason = 'no-end'; Steps = $null } }
KC 'K08 valid record but completed after the collection deadline' 'INCONCLUSIVE' 2 { Rec (Good) } 'PASS' $false
KC 'K09 decoded step list is not the stage-2a list' 'INCONCLUSIVE' 2 { $s = Good; Rec @($s[0], $s[1], $s[2], $s[3], $s[4], $s[5]) }
KC 'K10 hash end=nosup (TOOL FAULT)' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 '' '' @{ end = 'nosup'; code = [long]-1; ms = [long]-1; pipes = 'none'; why = 'no-report' }) }
KC 'K11 hash why=capture-write-failed (TOOL FAULT)' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 $null $null @{ why = 'capture-write-failed' }) }
KC 'K12 hash exec-failed EACCES 13 (TOOL FAULT)' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 '' '' @{ end = 'exec-failed'; code = [long]-1; errno = [long]13 }) }
KC 'K13 hash exec-failed ENOEXEC 8 (UNPARSEABLE)' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 '' '' @{ end = 'exec-failed'; code = [long]-1; errno = [long]8 }) }
KC 'K14 hash extra stdout line' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 ($hashOut + "extra`n")) }
KC 'K15 hash lines out of pin order' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 (($hl[1], $hl[0], $hl[2], $hl[3]) -join "`n") ) }
KC 'K16 hash code=1 with empty stderr' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 $null $null @{ code = [long]1 }) }
KC 'K17 hash code=0 with a stderr line' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 (($hl[0..2] -join "`n") + "`n") "sha256sum: can't open '/valve/bin/b2sum': No such file or directory`n") }
KC 'K18 hash path reported twice' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 ((@($hl[0], $hl[0], $hl[1], $hl[2], $hl[3]) -join "`n") + "`n")) }
KC 'K19 hash unterminated last line' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 ($hl -join "`n")) }
KC 'K20 hash capture truncated (out_kept < out_total)' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 $null $null @{ out_total = [long]9999 }) }
KC 'K21 hash only three paths' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 (($hl[0..2] -join "`n") + "`n")) }
KC 'K22 hash uppercase digest' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 ($hashOut.ToUpperInvariant())) }
KC 'K23 hash stderr in another format' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 (($hl[0..2] -join "`n") + "`n") "sha256sum: /valve/bin/b2sum: Permission denied`n" @{ code = [long]1 }) }
KC 'K24 absent: stderr not empty' 'INCONCLUSIVE' 4 { Rec (Put (Good) 2 '' "sh: oops`n") }
KC 'K25 absent: unknown path' 'INCONCLUSIVE' 4 { Rec (Put (Good) 2 "/etc/passwd`n") }
KC 'K26 absent: paths out of list order' 'INCONCLUSIVE' 4 { Rec (Put (Good) 2 "/usr`n/etc/ld.so.preload`n") }
KC 'K27 absent: code=1' 'INCONCLUSIVE' 4 { Rec (Put (Good) 2 $null $null @{ code = [long]1 }) }
KC 'K28 absent: exec-failed ENOEXEC (not a tool fault, UNPARSEABLE)' 'INCONCLUSIVE' 4 { Rec (Put (Good) 2 '' '' @{ end = 'exec-failed'; code = [long]-1; errno = [long]8 }) }
KC 'K29 hash UNPARSEABLE + absent mismatch (rev 3: 3 before 4)' 'INTEGRITY FAULT' 3 { $s = Put (Good) 1 ($hashOut + "extra`n"); Rec (Put $s 2 "/usr`n") }
KC 'K30 hash digest differs from its pin' 'INTEGRITY FAULT' 3 { Rec (Put (Good) 1 ($hashOut -replace $pins[1].Sha256, ('0' * 64))) }
KC 'K31 hash: pinned file missing (can''t open, code 1)' 'INTEGRITY FAULT' 3 { Rec (Put (Good) 1 (($hl[0..2] -join "`n") + "`n") "sha256sum: can't open '/valve/bin/b2sum': No such file or directory`n" @{ code = [long]1 }) }
KC 'K32 hash: pinned path is a directory (can''t read)' 'INTEGRITY FAULT' 3 { Rec (Put (Good) 1 ((@($hl[0], $hl[2], $hl[3]) -join "`n") + "`n") "sha256sum: can't read '/valve/lib/libc.so.6': Is a directory`n" @{ code = [long]1 }) }
KC 'K33 absent: /usr exists' 'INTEGRITY FAULT' 3 { Rec (Put (Good) 2 "/usr`n") }
KC 'K34 absent: two paths, in order' 'INTEGRITY FAULT' 3 { Rec (Put (Good) 2 "/etc/ld.so.preload`n/lib/libc.so.6`n") }
KC 'K35 integrity mismatch + Valve TOOL FAULT (3 before 5)' 'INTEGRITY FAULT' 3 { $s = Put (Good) 2 "/usr`n"; Rec (Put $s 3 $null $null @{ why = 'strays-alive' }) }
KC 'K36 integrity mismatch + Valve FAILED (3 before 6)' 'INTEGRITY FAULT' 3 { $s = Put (Good) 2 "/usr`n"; Rec (Put $s 5 "6.0`n") }
KC 'K37 diag why=strays-alive (Valve TOOL FAULT)' 'INCONCLUSIVE' 5 { Rec (Put (Good) 3 $null $null @{ why = 'strays-alive' }) }
KC 'K38 uname end=refused' 'INCONCLUSIVE' 5 { Rec (Put (Good) 5 '' '' @{ end = 'refused'; code = [long]-1; why = 'bad-option' }) }
KC 'K39 b2kat exec-failed EACCES 13' 'INCONCLUSIVE' 5 { Rec (Put (Good) 6 '' '' @{ end = 'exec-failed'; code = [long]-1; errno = [long]13 }) }
KC 'K40 list end=unreaped' 'INCONCLUSIVE' 5 { Rec (Put (Good) 4 $null $null @{ end = 'unreaped'; why = 'none' }) }
KC 'K41 Valve TOOL FAULT + another step FAILED (5 before 6)' 'INCONCLUSIVE' 5 { $s = Put (Good) 3 $null $null @{ why = 'no-proc' }; Rec (Put $s 7 "nope`n") } 'PASS' $true 'failing-1'
KC 'K42 diag exited code=1' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 3 $null $null @{ code = [long]1 }) }
KC 'K43 list signaled SIGILL' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 4 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]4 }) }
KC 'K44 uname timer-term (hang; code 143 is raw status)' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 5 '' '' @{ end = 'timer-term'; code = [long]143; term_ms = [long]20000 }) }
KC 'K45 uname timer-kill' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 5 '' '' @{ end = 'timer-kill'; code = [long]-1; sig = [long]9; term_ms = [long]20000; kill_ms = [long]21000 }) }
KC 'K46 b2kat exec-failed ENOEXEC 8' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 6 '' '' @{ end = 'exec-failed'; code = [long]-1; errno = [long]8 }) }
KC 'K47 b2kat exec-failed ELIBBAD 80' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 6 '' '' @{ end = 'exec-failed'; code = [long]-1; errno = [long]80 }) }
KC 'K48 b2chal strays=1 with why=none' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 7 $null $null @{ strays = [long]1 }) }
KC 'K49 b2chal pipes=open with why=none' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 7 $null $null @{ pipes = 'open' }) }
KC 'K50 diag output over the cap (why=none)' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 3 $null $null @{ out_total = [long]2000000 }) }
KC 'K51 uname wrote to stderr' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 5 $null "warning`n") }
KC 'K52 diag missing version.version line' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 3 "version.release=`"stable`"`npath.system_dirs[0x0]=`"/usr/lib/`"`ndl_pagesize=0x1000`n") }
KC 'K53 diag shows an env[ line' 'COMPATIBILITY FAIL' 6 { $d = [Text.Encoding]::ASCII.GetString((Good)[2]['out']) + "env[0x0]=`"LD_PRELOAD=x`"`n"; Rec (Put (Good) 3 $d) }
KC 'K54 list has 4 lines' 'COMPATIBILITY FAIL' 6 { $d = [Text.Encoding]::ASCII.GetString((Good)[3]['out']) + "`tlibx.so => /x (0x0000000000000000)`n"; Rec (Put (Good) 4 $d) }
KC 'K55 list resolves libc outside /valve/lib' 'COMPATIBILITY FAIL' 6 { $d = [Text.Encoding]::ASCII.GetString((Good)[3]['out']) -replace '=> /valve/lib/libc', '=> /usr/lib/libc'; Rec (Put (Good) 4 $d) }
KC 'K56 list last line unterminated' 'COMPATIBILITY FAIL' 6 { $d = [Text.Encoding]::ASCII.GetString((Good)[3]['out']).TrimEnd("`n"); Rec (Put (Good) 4 $d) }
KC 'K57 uname reports another kernel' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 5 "6.18.0`n") }
KC 'K58 b2kat wrong digest' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 6 (('0' * 128) + "  -`n")) }
KC 'K59 b2chal wrong digest' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 7 (('1' * 128) + "  -`n")) }
KC 'K60 b2chal newline variant' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 7 ((Get-FsBlake2bHex (B "$($KN):$KC`n")) + "  -`n")) } 'PASS' $true 'newline variant'
KC 'K61 diag exited 143 on its own (not a timeout)' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 3 $null $null @{ code = [long]143 }) } 'PASS' $true 'not a timeout'
KC 'K62 two FAILED steps: lowest reported first' 'COMPATIBILITY FAIL' 6 { $s = Put (Good) 5 "6.0`n"; Rec (Put $s 3 $null $null @{ code = [long]2 }) } 'PASS' $true 'lowest-3'
KC 'K64 hash mismatch + absent TOOL FAULT (rev 3)' 'INTEGRITY FAULT' 3 { $s = Put (Good) 1 ($hashOut -replace $pins[1].Sha256, ('0' * 64)); Rec (Put $s 2 $null $null @{ why = 'capture-write-failed' }) }
KC 'K65 hash mismatch + absent UNPARSEABLE (rev 3)' 'INTEGRITY FAULT' 3 { $s = Put (Good) 1 ($hashOut -replace $pins[1].Sha256, ('0' * 64)); Rec (Put $s 2 "/etc/passwd`n") }
KC 'K66 hash TOOL FAULT + absent mismatch (rev 3, symmetric)' 'INTEGRITY FAULT' 3 { $s = Put (Good) 1 $null $null @{ why = 'strays-alive' }; Rec (Put $s 2 "/usr`n") }
KC 'K67 Valve step killed by outside SIGKILL (e.g. OOM): TOOL FAULT' 'INCONCLUSIVE' 5 { Rec (Put (Good) 4 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]9 }) }
KC 'K68 Valve step killed by outside SIGTERM: TOOL FAULT' 'INCONCLUSIVE' 5 { Rec (Put (Good) 6 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]15 }) }
KC 'K69 Valve step SIGHUP / SIGINT: TOOL FAULT' 'INCONCLUSIVE' 5 { $s = Put (Good) 5 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]1 }; Rec (Put $s 7 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]2 }) }
KC 'K70 Valve step SIGSEGV: still compatibility FAIL' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 5 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]11 }) }
KC 'K71 hash step killed by outside SIGKILL: integrity unmeasured' 'INCONCLUSIVE' 4 { Rec (Put (Good) 1 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]9 }) }
KC 'K72 both integrity steps TOOL FAULT' 'INCONCLUSIVE' 4 { $s = Put (Good) 1 $null $null @{ why = 'no-proc' }; Rec (Put $s 2 $null $null @{ why = 'no-proc' }) }
KC 'K73 Valve SIGABRT stays FAILED' 'COMPATIBILITY FAIL' 6 { Rec (Put (Good) 3 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]6 }) }
KC 'K63 hash mismatch AND stderr line together' 'INTEGRITY FAULT' 3 { Rec (Put (Good) 1 ((@(($hl[0] -replace '^.{64}', ('e' * 64)), $hl[1], $hl[2]) -join "`n") + "`n") "sha256sum: can't open '/valve/bin/b2sum': No such file or directory`n" @{ code = [long]1 }) }
KC 'K74 inv TOOL FAULT (why=strays-alive): noted, still PASS' 'PASS' 7 { Rec (Put (Good) 8 $null $null @{ why = 'strays-alive' }) } 'PASS' $true 'inv-info'
KC 'K75 inv exited 1 with stderr: noted, still PASS' 'PASS' 7 { Rec (Put (Good) 8 "== /proc/modules`n" "cat: read error: I/O error`n" @{ code = [long]1 }) } 'PASS' $true 'inv-info'
KC 'K76 inv timer-kill: noted, still PASS' 'PASS' 7 { Rec (Put (Good) 8 '' '' @{ end = 'timer-kill'; code = [long]-1; sig = [long]9; term_ms = [long]10000; kill_ms = [long]12000 }) } 'PASS' $true 'inv-info'
KC 'K77 inv: every path absent: noted, still PASS' 'PASS' 7 { Rec (Put (Good) 8 "== /proc/modules`n(absent)`n== /sys/class/remoteproc`n(none)`n== end`n") } 'PASS' $true 'inv-info'
KC 'K78 inv end=nosup: noted, still PASS' 'PASS' 7 { Rec (Put (Good) 8 '' '' @{ end = 'nosup'; code = [long]-1; ms = [long]-1; pipes = 'none'; why = 'no-report' }) } 'PASS' $true 'inv-info'
KC 'K79 inv TOOL FAULT + Valve FAILED: still COMPATIBILITY FAIL (inv never escalates or masks)' 'COMPATIBILITY FAIL' 6 { $s = Put (Good) 8 $null $null @{ why = 'no-proc' }; Rec (Put $s 5 "6.0`n") }
KC 'K80 inv TOOL FAULT + integrity mismatch: still INTEGRITY FAULT' 'INTEGRITY FAULT' 3 { $s = Put (Good) 8 $null $null @{ why = 'no-proc' }; Rec (Put $s 2 "/usr`n") }
KC 'K81 the seven-step (revision 3) list: not the stage-2a list (framing, rule 2)' 'INCONCLUSIVE' 2 { $s = Good; Rec @($s[0..6]) }
foreach ($kcase in $kcases) {   # (not $kc: PowerShell names are case-insensitive; $kc is $KC)
    $f = & $kcase.Make
    $o = Get-FsStage2aOutcome -Stage1Class $kcase.Stage1 -Kernel $KK -Fsb1 $f -Nonce $KN -Challenge $KC -Collected $kcase.Collected -Pins $pins
    $ok = ($o.Outcome -ceq $kcase.Want -and $o.Rule -eq $kcase.Rule)
    switch -regex ($kcase.Note) {
        '^newline variant$' { $ok = $ok -and ($o.Reason -match 'newline variant') }
        '^not a timeout$'   { $ok = $ok -and ($o.Reason -match 'not a timeout') }
        '^lowest-3$'        { $ok = $ok -and ($o.Reason -match 'step 3 diag') -and @($o.Failing).Count -eq 2 }
        '^failing-1$'       { $ok = $ok -and @($o.Failing).Count -eq 1 }
        '^inv-info$'        { $iv = @($o.StepClasses | Where-Object { $_.Id -ceq 'inv' }); $ok = $ok -and $iv.Count -eq 1 -and $iv[0].Class -ceq 'INFO' -and $iv[0].Notes -match 'noted only|sections=' }
    }
    Check ("{0,-62} -> {1} (rule {2})" -f $kcase.Name, $o.Outcome, $o.Rule) $ok "want $($kcase.Want) rule $($kcase.Rule); reason: $($o.Reason)"
}
Say '   (rule 8 is the catch-all; OUTCOMES says it is unreachable when §3-§4 hold, and no input reaches it here)'

# ------------------------------------------------------------------ L --------
if (Test-Path (Join-Path $ROOT 'relays\FS-A-009-raw\observe\collect\collect.json')) { . (Join-Path $FIXDIR 'listing-rule.ps1') }
else { Skip 'L step-4 list rule versions (fixtures\listing-rule.ps1)' 'withheld evidence: relays/FS-A-009-raw and stage2a/evidence are not in the public copy' }

# ------------------------------------------------------------------ S --------
Say '== S. stage-3a classifier (OUTCOMES §8) and FSP1 stream check'
$SN = 'a1b2c3d4e5f60718'; $SChal = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'; $S8 = $SChal.Substring(0, 8)
function S3 { param([string]$Stream = $null, [long]$Code = 0) Get-Stage3aGoodSteps -Nonce $SN -Chal $SChal -Stream $Stream -Code $Code }
function NoDisp([int]$code, [string]$why) { New-SynthFsp1 -Nonce8 $S8 -Recs (Get-Stage3aNoDisplayRecs $code $why) }
function Committed([scriptblock]$edit = $null) { $r = @(Get-Stage3aCommittedRecs); if ($edit) { $r = & $edit $r }; New-SynthFsp1 -Nonce8 $S8 -Recs $r }
function SetRec($recs, [string]$step, [object]$rc, [string]$kv) { @($recs | ForEach-Object { if ($_[0] -ceq $step) { ,@($step, $rc, $kv) } else { ,$_ } }) }
function SPut($steps, [int]$i, [string]$out = $null, [string]$err = $null, [hashtable]$f = @{}) {
    $o = $steps[$i - 1]
    [byte[]]$ob = $o['out']; if ($null -ne $out) { $ob = B $out }
    [byte[]]$eb = $o['err']; if ($null -ne $err) { $eb = B $err }
    $steps[$i - 1] = New-SynthStep $i $o['id'] $ob $eb $f
    ,$steps
}
$scases = New-Object System.Collections.Generic.List[object]
function SCase([string]$name, [string]$want, [int]$rule, [scriptblock]$make, [string]$stage1 = 'PASS', [bool]$collected = $true) {
    $scases.Add([pscustomobject]@{ Name = $name; Want = $want; Rule = $rule; Make = $make; Stage1 = $stage1; Collected = $collected })
}
SCase 'S01 committed, held to the deadline, shown=1' 'PASS (machine side)' 10 { Rec (S3) }
SCase 'S02 stage 1 not PASS' 'DEVICE_REJECTED' 1 { Rec (S3) } 'DEVICE_REJECTED'
SCase 'S03 no record' 'INCONCLUSIVE' 2 { $null }
SCase 'S04 FSB1 rejected' 'INCONCLUSIVE' 2 { [pscustomobject]@{ Ok = $false; Reason = 'no-begin'; Steps = $null } }
SCase 'S05 completed after the host deadline' 'INCONCLUSIVE' 2 { Rec (S3) } 'PASS' $false
SCase 'S06 a stage-2a step list' 'INCONCLUSIVE' 2 { Rec (Get-Stage2aGoodSteps -Nonce $SN -Chal $SChal) }
SCase 'S07 hash: digest is not the pin' 'INTEGRITY FAULT' 3 { Rec (SPut (S3) 1 (('0' * 64) + "  /bin/fs-pattern`n")) }
SCase 'S08 hash: fs-pattern missing (can''t open, code 1)' 'INTEGRITY FAULT' 3 { Rec (SPut (S3) 1 '' "sha256sum: can't open '/bin/fs-pattern': No such file or directory`n" @{ code = [long]1 }) }
SCase 'S09 hash: TOOL FAULT (why=no-proc)' 'INCONCLUSIVE' 4 { Rec (SPut (S3) 1 $null $null @{ why = 'no-proc' }) }
SCase 'S10 hash: extra stdout line (UNPARSEABLE)' 'INCONCLUSIVE' 4 { Rec (SPut (S3) 1 ("$($script:SynPatternPin)  /bin/fs-pattern`nx`n")) }
SCase 'S11 hash: uppercase digest (UNPARSEABLE)' 'INCONCLUSIVE' 4 { Rec (SPut (S3) 1 ("$($script:SynPatternPin.ToUpperInvariant())  /bin/fs-pattern`n")) }
SCase 'S12 pattern: TOOL FAULT (why=strays-alive)' 'INCONCLUSIVE' 5 { Rec (SPut (S3) 2 $null $null @{ why = 'strays-alive' }) }
SCase 'S13 pattern: outside SIGKILL' 'INCONCLUSIVE' 5 { Rec (SPut (S3) 2 '' '' @{ end = 'signaled'; code = [long]-1; sig = [long]9 }) }
SCase 'S14 pattern: exec-failed ENOENT (TOOL FAULT)' 'INCONCLUSIVE' 5 { Rec (SPut (S3) 2 '' '' @{ end = 'exec-failed'; code = [long]-1; errno = [long]2 }) }
SCase 'S15 pattern: timer-term (hang)' 'DISPLAY FAIL' 6 { Rec (SPut (S3) 2 '' '' @{ end = 'timer-term'; code = [long]143; term_ms = [long]16000 }) }
SCase 'S16 pattern: timer-kill (hang)' 'DISPLAY FAIL' 6 { Rec (SPut (S3) 2 '' '' @{ end = 'timer-kill'; code = [long]-1; sig = [long]9; term_ms = [long]16000; kill_ms = [long]19000 }) }
SCase 'S17 pattern: its own SIGALRM (stall)' 'DISPLAY FAIL' 6 { Rec (SPut (S3) 2 $null $null @{ end = 'signaled'; code = [long]-1; sig = [long]14 }) }
SCase 'S18 pattern: exec-failed ENOEXEC' 'DISPLAY FAIL' 6 { Rec (SPut (S3) 2 '' '' @{ end = 'exec-failed'; code = [long]-1; errno = [long]8 }) }
SCase 'S19 exit 0, one record''s CRC wrong' 'INCONCLUSIVE' 7 { Rec (S3 -Stream (New-SynthFsp1 -Nonce8 $S8 -Recs (Get-Stage3aCommittedRecs) -BadCrcAt 5)) }
SCase 'S20 exit 0, stream without eos' 'INCONCLUSIVE' 7 { Rec (S3 -Stream (New-SynthFsp1 -Nonce8 $S8 -Recs (Get-Stage3aCommittedRecs) -NoEos)) }
SCase 'S21 exit 0, FSP1 nonce is not chal[0:8]' 'INCONCLUSIVE' 7 { Rec (S3 -Stream (New-SynthFsp1 -Nonce8 'deadbeef' -Recs (Get-Stage3aCommittedRecs))) }
SCase 'S22 exit 0, nonce changes mid-stream' 'INCONCLUSIVE' 7 { Rec (S3 -Stream (New-SynthFsp1 -Nonce8 $S8 -Recs (Get-Stage3aCommittedRecs) -NonceAt 3)) }
SCase 'S23 stream exit code=10 but the process exited 0' 'INCONCLUSIVE' 7 { Rec (S3 -Stream (NoDisp 10 'no_device') -Code 0) }
SCase 'S24 committed stream, but stderr not empty' 'INCONCLUSIVE' 7 { Rec (SPut (S3) 2 $null "warning`n") }
SCase 'S25 committed stream, capture truncated' 'INCONCLUSIVE' 7 { Rec (SPut (S3) 2 $null $null @{ out_total = [long]99999 }) }
$k = 25
foreach ($c in @(@(10, 'no_device'), @(11, 'not_drm'), @(12, 'not_msm_drm'), @(20, 'no_connector'), @(21, 'atomic_refused'), @(30, 'mode_refused'), @(40, 'buffer_failed'), @(50, 'test_rejected'))) {
    $k++; $cc = $c
    SCase ("S{0:00} exit {1} ({2})" -f $k, $cc[0], $cc[1]) 'NO-DISPLAY' 8 ([scriptblock]::Create("Rec (S3 -Stream (NoDisp $($cc[0]) '$($cc[1])') -Code $($cc[0]))"))
}
SCase 'S34 exit 60 (real commit failed)' 'DISPLAY FAIL' 9 { Rec (S3 -Stream (NoDisp 60 'commit_failed') -Code 60) }
SCase 'S35 exit 1 (internal error in the hold)' 'DISPLAY FAIL' 9 { Rec (S3 -Stream (NoDisp 1 'hold_error') -Code 1) }
SCase 'S36 exit 0 but shown=0' 'INCONCLUSIVE' 11 { Rec (S3 -Stream (Committed { param($r) SetRec $r 'exit' 0 'code=0 reason=held_to_deadline shown=0 closed_at_exit=0 elapsed_ms=10150' })) }
SCase 'S37 exit 0 but hold_end reason=signal' 'INCONCLUSIVE' 11 { Rec (S3 -Stream (Committed { param($r) SetRec $r 'hold_end' 0 'reason=signal sig=15 held_ms=4000 late_ms=-6000 fd_closed=1 close_rc=0 close_ms=40' })) }
SCase 'S38 exit 0 but commit rc=-22' 'INCONCLUSIVE' 11 { Rec (S3 -Stream (Committed { param($r) SetRec $r 'commit' -22 'attempt=0 modeset=0 layout=single commit_ms=17' })) }
SCase 'S39 exit 70 (stopped by an outside signal)' 'INCONCLUSIVE' 11 { Rec (S3 -Stream (NoDisp 70 'interrupted') -Code 70) }
SCase 'S40 exit 2 (usage: our invocation)' 'INCONCLUSIVE' 11 { Rec (S3 -Stream (NoDisp 2 'usage') -Code 2) }
foreach ($scase in $scases) {   # (names are case-insensitive: never $sc next to $SC)
    $f = & $scase.Make
    $o = Get-FsStage3aOutcome -Stage1Class $scase.Stage1 -Fsb1 $f -Nonce $SN -Challenge $SChal -Collected $scase.Collected
    $ok = ($o.Outcome -ceq $scase.Want -and $o.Rule -eq $scase.Rule)
    if ($scase.Want -ceq 'PASS (machine side)') { $ok = $ok -and $o.Reason -match 'PM reading' }
    Check ("{0,-58} -> {1} (rule {2})" -f $scase.Name, $o.Outcome, $o.Rule) $ok "want $($scase.Want) rule $($scase.Rule); reason: $($o.Reason)"
}
# FSP1 check vs the Python reference (stage3a/tools/check_stream.py), on the synthetic streams
if ($python) {
    $cs = Join-Path $ROOT 'devices\quest3\stage3a\tools\check_stream.py'
    $streams = [ordered]@{ 'committed' = @((Committed), 'COMPLETE'); 'nodisplay' = @((NoDisp 10 'no_device'), 'COMPLETE')
                           'badcrc' = @((New-SynthFsp1 -Nonce8 $S8 -Recs (Get-Stage3aCommittedRecs) -BadCrcAt 2), 'INVALID')
                           'noeos' = @((New-SynthFsp1 -Nonce8 $S8 -Recs (Get-Stage3aCommittedRecs) -NoEos), 'INCOMPLETE')
                           'nonce' = @((New-SynthFsp1 -Nonce8 $S8 -Recs (Get-Stage3aCommittedRecs) -NonceAt 4), 'INVALID') }
    foreach ($n in $streams.Keys) {
        $fp = Join-Path $Scratch "fsp1-$n.txt"; [IO.File]::WriteAllBytes($fp, (B $streams[$n][0]))
        $want = $streams[$n][1]
        $py = & $python -I $cs --expect $want.ToLowerInvariant() $fp
        $ps = (Test-FsFsp1Stream (B $streams[$n][0])).Status
        Check "S41 FSP1 '$n': PowerShell $ps = Python ($(($py -split ' ')[2])) = $want" ($ps -ceq $want -and $LASTEXITCODE -eq 0)
    }
    $real = Join-Path $ROOT 'devices\quest3\stage3a\fixtures\stream-sample.txt'
    if (Test-Path $real) {
        $pyr = (& $python -I $cs --expect complete $real) -split ' '
        Check "S42 fs-pattern's own sample stream (unit-test build): PowerShell = Python" ((Test-FsFsp1Stream ([IO.File]::ReadAllBytes($real))).Status -ceq $pyr[2]) "python $($pyr -join ' ')"
    }
} else { Skip 'S41 FSP1 cross-check' 'python not found' }
if ($results.ContainsKey('3a-committed')) {
    $d3 = Join-Path $Scratch 'replay-3a-committed'
    Save-FsCollectJson -Result $results['3a-committed'] -Path (Join-Path $d3 'collect.json')
    Check 'S43 -Stage 3a replay: the collector sent fs-display (not fs-valve) and recorded stage 3a, deadline 170 s' ((@($results['3a-committed'].Sent) -join ',') -match 'fs-display [0-9a-f]{32}' -and $results['3a-committed'].Stage -ceq '3a' -and $results['3a-committed'].DeviceDeadlineSec -eq 170)
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 3a -CollectDir $d3 -Stage1Class PASS
    Check 'S44 fs-classify.ps1 -Stage 3a CLI: OUTCOME PASS (machine side), exit 10, and the PM-reading caveat is printed' (($cl -join "`n") -match 'OUTCOME: PASS \(machine side\)' -and ($cl -join "`n") -match 'PM reading' -and $LASTEXITCODE -eq 10) ($cl -join ' / ')
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -CollectDir $d3 -Stage1Class PASS
    Check 'S45 a stage-3a collection given to the stage-2a classifier: INCONCLUSIVE, exit 14' (($cl -join "`n") -match 'OUTCOME: INCONCLUSIVE \(the collection is stage 3a' -and $LASTEXITCODE -eq 14) ($cl -join ' / ')
}
if ($results.ContainsKey('3a-committed')) {
    $ixl = [IO.File]::ReadAllLines($results['3a-committed'].Capture.Index)
    $ci = -1; $wi = -1
    for ($k = 0; $k -lt $ixl.Count; $k++) { if ($ixl[$k] -cmatch '^N \d+ \d+ display-cue\z') { $ci = $k }; if ($ixl[$k] -cmatch '^W \d+ \d+ fs-display ') { $wi = $k } }
    $cms = if ($ci -ge 0) { [long]($ixl[$ci].Split(' ')[2]) } else { -1 }; $wms = if ($wi -ge 0) { [long]($ixl[$wi].Split(' ')[2]) } else { -1 }
    Check 'S47 stage 3a: the display cue (N display-cue) precedes the fs-display write in capture.raw.idx, by at least 3 s' ($ci -ge 0 -and $wi -gt $ci -and $wms - $cms -ge 3000) "cue line $ci @$cms, write line $wi @$wms"
}
if ($results.ContainsKey('good-lf')) {
    Check 'S48 stage 2a: no display cue in the index' (-not (@([IO.File]::ReadAllLines($results['good-lf'].Capture.Index)) -match '^N '))
}
# Revision 8 (Chair review of FS-A-007, S3): single-operator display protocol, from the capture index
function Get-IdxEvents([string]$path) {   # every W/N line with its index, kind, ms and text
    $ix = [IO.File]::ReadAllLines($path); $ev = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -lt $ix.Count; $k++) { if ($ix[$k] -cmatch '^(W|N) (\d+) (\d+) (.*)\z') { $ev.Add([pscustomobject]@{ K = $k; Kind = $Matches[1]; Ms = [long]$Matches[3]; Text = $Matches[4] }) } }
    ,$ev
}
if ($results.ContainsKey('3a-committed')) {
    $ev = Get-IdxEvents $results['3a-committed'].Capture.Index
    $wd = @($ev | Where-Object { $_.Kind -ceq 'W' -and $_.Text -like 'fs-display *' }); $b1 = @($ev | Where-Object { $_.Text -like 'beep-1 *' })
    $b2 = @($ev | Where-Object { $_.Text -like 'beep-2 *' }); $wf = @($ev | Where-Object { $_.Kind -ceq 'W' -and $_.Text -ceq 'fs-done' })
    $order = $wd.Count -eq 1 -and $b1.Count -eq 1 -and $b2.Count -eq 1 -and $wf.Count -eq 1 -and $wd[0].K -lt $b1[0].K -and $b1[0].K -lt $b2[0].K -and $b2[0].K -lt $wf[0].K
    Check 'S49 stage 3a order in capture.raw.idx: W fs-display < N beep-1 < N beep-2 < W fs-done (one of each)' $order
    $between = @($ev | Where-Object { $order -and $_.Kind -ceq 'W' -and $_.K -gt $b1[0].K -and $_.K -lt $b2[0].K })
    Check 'S50 ...the pause is read-only (no write between the beeps) and lasts >= PreDoneMs 10 s after beep 1 (+ its 300 ms)' ($order -and $between.Count -eq 0 -and ($b2[0].Ms - $b1[0].Ms) -ge 10300) "beep-1 @$(if ($b1.Count) { $b1[0].Ms }) beep-2 @$(if ($b2.Count) { $b2[0].Ms })"
    $bp = @($results['3a-committed'].Replay.Beeps)
    Check 'S51 ...two distinct host beeps (1760 Hz/300 ms, then 440 Hz/700 ms); none written to the device' ($bp.Count -eq 2 -and $bp[0] -like '1760/300@*' -and $bp[1] -like '440/700@*' -and -not (@($results['3a-committed'].Sent) -match 'beep')) ($bp -join ' ')
    Check 'S52 ...the stage-3a collector used 2 fs-status tries at most (revision 8 timing)' ((New-FsCollectCfg -Nonce ('0' * 16) -Stage 3a).AckStatusTries -eq 2 -and (New-FsCollectCfg -Nonce ('0' * 16) -Stage 2a).AckStatusTries -eq 3)
}
if ($results.ContainsKey('good-lf')) {
    Check 'S53 stage 2a: no beeps and no pause (no N lines, no replay beeps)' (-not (@([IO.File]::ReadAllLines($results['good-lf'].Capture.Index)) -match '^N ') -and @($results['good-lf'].Replay.Beeps).Count -eq 0)
}
if ($results.ContainsKey('3a-committed')) {
    # bytes arriving during the pause: a copy of 3a-committed with "\n~ # ESC[6n" inserted 5 s into the pause
    $srcRaw = Join-Path $FX '3a-committed.raw'
    [byte[]]$r0 = [IO.File]::ReadAllBytes($srcRaw); $i0 = [IO.File]::ReadAllLines("$srcRaw.idx")
    $wl = -1; for ($k = 0; $k -lt $i0.Count; $k++) { if ($i0[$k] -cmatch '^W \d+ \d+ fs-done\z') { $wl = $k } }
    $woff = [long]($i0[$wl].Split(' ')[1]); $prevMs = 0
    for ($k = 1; $k -lt $wl; $k++) { if ($i0[$k] -cmatch '^(R|W|N) \d+ (\d+)') { $v = if ($Matches[1] -ceq 'R') { [long]($i0[$k].Split(' ')[3]) } else { [long]$Matches[2] }; if ($v -gt $prevMs) { $prevMs = $v } } }
    $ins = [Text.Encoding]::GetEncoding(28591).GetBytes("`n~ # $([char]27)[6n")
    $nr = New-Object System.Collections.Generic.List[byte]; $nr.AddRange([byte[]]$r0[0..($woff - 1)]); $nr.AddRange($ins); if ($woff -lt $r0.Length) { $nr.AddRange([byte[]]$r0[$woff..($r0.Length - 1)]) }
    $ni = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $i0.Count; $k++) {
        if ($k -eq $wl) { $ni.Add("R $woff $($ins.Length) $($prevMs + 5000)") }
        $l = $i0[$k]
        if ($k -ge $wl -and $l -cmatch '^R (\d+) (\d+) (\d+)\z') { $l = "R $([long]$Matches[1] + $ins.Length) $($Matches[2]) $([Math]::Max([long]$Matches[3], $prevMs + 5000))" }
        elseif ($k -ge $wl -and $l -cmatch '^(W|N) (\d+) (\d+)(.*)\z') { $l = "$($Matches[1]) $([long]$Matches[2] + $ins.Length) $([Math]::Max([long]$Matches[3], $prevMs + 5000))$($Matches[4])" }
        $ni.Add($l)
    }
    $pr = Join-Path $Scratch 'r8-pause-bytes.raw'; [IO.File]::WriteAllBytes($pr, $nr.ToArray()); [IO.File]::WriteAllLines("$pr.idx", $ni)
    try { $rp = Invoke-FsReplay -RawPath $pr -OutDir (Join-Path $Scratch 'r8-pause-bytes-out') -Overrides @{ Stage = '3a' } } catch { $rp = [pscustomobject]@{ DoneSent = $true; Sent = @(); DoneReply = "threw: $($_.Exception.Message)"; Replay = @{ Beeps = @() } } }
    Check 'S54 stage 3a: bytes arriving during the pre-done pause: fs-done NOT sent (send gate; no re-settle), beep 2 still marks the end of the pause' (-not $rp.DoneSent -and (@($rp.Sent) -notcontains 'fs-done') -and $rp.DoneReply -match 'NOT SENT' -and @($rp.Replay.Beeps).Count -eq 2) "done=$($rp.DoneSent) reply=$($rp.DoneReply)"
}
if ($results.ContainsKey('3a-no-device')) {
    $d3 = Join-Path $Scratch 'replay-3a-no-device'
    Save-FsCollectJson -Result $results['3a-no-device'] -Path (Join-Path $d3 'collect.json')
    $cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 3a -CollectDir $d3 -Stage1Class PASS
    Check 'S46 fs-classify.ps1 -Stage 3a CLI on the no-device collection: NO-DISPLAY, exit 15' (($cl -join "`n") -match 'OUTCOME: NO-DISPLAY' -and $LASTEXITCODE -eq 15) ($cl -join ' / ')
}

# ------------------------------------------------------------------ O --------
Say '== O. fs-observe.ps1: one attempt, no session; dry observer -> collector -> classifier'
$otok = $null; $oerr = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $HOSTDIR 'fs-observe.ps1'), [ref]$otok, [ref]$oerr)
$ocode = (@($otok | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')   # code tokens only: the header explains the old session
Check 'O1 the observer code opens no serial port and runs no session (no SerialPort / New-FsSerialTransport / Invoke-FsSession / New-FsCommand / fs-ack / fs-verify outside comments)' (-not ($ocode -match 'SerialPort|New-FsSerialTransport|Invoke-FsSession|New-FsCommand|WriteBytes|fs-ack|fs-verify'))
$Q3 = Join-Path $ROOT 'devices\quest3'
function New-ObsBuild([string]$stage, [string]$nonce, [string]$extra = '') {
    $base = Join-Path $Scratch ("obs-$stage-" + (New-FsHex 3)); $bd = Join-Path $base "build\stage$stage\20261009T090000Z-$nonce"
    $null = New-Item -ItemType Directory -Force -Path $bd
    $img = Join-Path $bd "boot-stage$stage.img"; [IO.File]::WriteAllBytes($img, [byte[]](1..64 | ForEach-Object { [byte]$_ }))
    $h = { param($f) (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Q3 $f)).Hash.ToLower() }
    $src = if ($stage -eq '2a') { "init.sh source    $(& $h 'stage2a\init.sh')  (recorded)`nfs-valve.sh       $(& $h 'stage2a\fs-valve.sh')  (recorded)`nfs-inv.sh         $(& $h 'stage2a\fs-inv.sh')  (recorded)" }
           else { "init.sh source    $(& $h 'stage3a\init.sh')  (recorded)`nfs-display.sh     $(& $h 'stage3a\fs-display.sh')  (recorded)" }
    $m = "FrameShift Quest 3 stage-$stage image (fixture) — ONE ATTEMPT ONLY, never reuse`nbuilt:            20261009T090000Z`nnonce:            $nonce   (USB serial FS-$nonce)`n$extra" +
         "OUTPUT IMAGE:     boot-stage$stage.img  size=64  sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $img).Hash.ToLower())`n`n" +
         "stock boot        49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50  x`nstock vendor_boot 1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf  x`n$src`n"
    [IO.File]::WriteAllText((Join-Path $bd 'MANIFEST.txt'), $m, (New-Object System.Text.UTF8Encoding($false)))
    [pscustomobject]@{ Img = $img; Ledger = (Join-Path $base "build\stage$stage\attempted"); Dir = $bd }
}
function New-FakeDevice([string]$bootMode = 'ok', [int]$gadgetAfter = 3) {
    $fk = [pscustomobject]@{ Calls = (New-Object System.Collections.Generic.List[string]); Polls = 0; Clock = [DateTime]::Parse('2026-10-09T09:00:00Z').ToUniversalTime(); Mode = $bootMode; After = $gadgetAfter; Lines = (New-Object System.Collections.Generic.List[string]) }
    $fk
}
function Invoke-ObsFake($fk, $b, [string]$confirm, [bool]$pre = $false, [string]$buildRoot = '') {
    $script:fkCur = $fk
    if (-not $buildRoot) { $buildRoot = Split-Path -Parent $b.Ledger }
    Invoke-FsObserve -Stage $(if ($b.Img -like '*stage3a*') { '3a' } else { '2a' }) -ImagePath $b.Img -ConfirmNonce $confirm -Preflight $pre -BuildRoot $buildRoot -Q3 $Q3 -GadgetWaitSec 30 `
        -Fastboot { param([string[]]$ArgList, [int]$TimeoutMs)
            $f = $script:fkCur; $f.Calls.Add(($ArgList -join ' ')); $f.Clock = $f.Clock.AddMilliseconds(300)
            if ($ArgList[0] -ceq 'devices') { return [pscustomobject]@{ ExitCode = 0; StdOut = "QUEST3UNIT1`tfastboot`r`n"; StdErr = ''; TimedOut = $false; Error = $null } }
            $f.Clock = $f.Clock.AddSeconds(11)
            if ($f.Mode -ceq 'timeout') { $f.Clock = $f.Clock.AddSeconds(109); return [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = "Sending 'boot.img' OKAY`nBooting"; TimedOut = $true; Error = $null } }
            if ($f.Mode -ceq 'reject') { return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = "Sending 'boot.img' OKAY`nBooting FAILED (remote: 'boot not allowed')`n"; TimedOut = $false; Error = $null } }
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = "Sending 'boot.img' (41408 KB) OKAY [ 0.892s]`nBooting OKAY [10.191s]`nFinished. Total time: 11.111s`n"; TimedOut = $false; Error = $null } } `
        -Gadget { param([string]$N) $f = $script:fkCur; $f.Polls++
            if ($f.Polls -lt $f.After) { return [pscustomobject]@{ Present = $false; SerialOk = $false; Serials = @(); ComPort = $null; Parent = $null } }
            [pscustomobject]@{ Present = $true; SerialOk = $true; Serials = @("FS-$N"); ComPort = 'COM9'; Parent = "USB\VID_1D6B&PID_0104\FS-$N" } } `
        -NowUtc { $script:fkCur.Clock } -Sleep { param([int]$Ms) $script:fkCur.Clock = $script:fkCur.Clock.AddMilliseconds($Ms) } `
        -Say { param([string]$Line) $script:fkCur.Lines.Add($Line) }
}
$ON = 'c0de0b5e12345678'
$b = New-ObsBuild '2a' $ON
$fk = New-FakeDevice; $o = Invoke-ObsFake $fk $b ''
Check 'O2 no -ConfirmNonce: exit 3, no fastboot call, nothing written (no ledger, no lock, no observe dir)' ($o.Exit -eq 3 -and $fk.Calls.Count -eq 0 -and -not (Test-Path $b.Ledger) -and -not (Test-Path (Join-Path $b.Dir 'attempt.lock')) -and @(Get-ChildItem $b.Dir -Directory).Count -eq 0)
$fk = New-FakeDevice; $o = Invoke-ObsFake $fk $b 'ffffffffffffffff'
Check 'O3 a wrong -ConfirmNonce: exit 3, no fastboot call' ($o.Exit -eq 3 -and $fk.Calls.Count -eq 0)
$fk = New-FakeDevice; $o = Invoke-ObsFake $fk $b '' $true
Check 'O4 -Preflight: exit 0 with no fastboot call and nothing written' ($o.Exit -eq 0 -and $fk.Calls.Count -eq 0 -and -not (Test-Path $b.Ledger))
$bt = New-ObsBuild '2a' 'c0de0b5e00000001' "TEST OVERRIDES:   FS_TEST_BUSYBOX=/x (negative fixtures only; NOT a candidate image)`n"
$fk = New-FakeDevice; $o = Invoke-ObsFake $fk $bt 'c0de0b5e00000001'
Check 'O5 a MANIFEST with TEST OVERRIDES is refused (exit 2, no fastboot call)' ($o.Exit -eq 2 -and $o.Why -match 'TEST OVERRIDES' -and $fk.Calls.Count -eq 0)
$bx = New-ObsBuild '2a' 'c0de0b5e00000002'; [IO.File]::AppendAllText($bx.Img, 'x')
$fk = New-FakeDevice; $o = Invoke-ObsFake $fk $bx 'c0de0b5e00000002'
Check 'O6 an image that does not match its MANIFEST is refused (exit 2, no fastboot call)' ($o.Exit -eq 2 -and $o.Why -match 'sha256' -and $fk.Calls.Count -eq 0)
$fk = New-FakeDevice; $o = Invoke-ObsFake $fk $b $ON
$ob = $o.Observe; $obDir = $o.OutDir
Check 'O7 the attempt: exactly two fastboot calls, `devices` then `-s <serial> boot <image>`' ($o.Exit -eq 0 -and $fk.Calls.Count -eq 2 -and $fk.Calls[0] -ceq 'devices' -and $fk.Calls[1] -ceq "-s QUEST3UNIT1 boot $($b.Img)") ($fk.Calls -join ' | ')
Check 'O8 ledger marker and image-directory lock written before the boot; observe.json written' ((Test-Path (Join-Path $b.Ledger "$ON.attempted")) -and (Test-Path (Join-Path $b.Dir 'attempt.lock')) -and (Test-Path (Join-Path $o.OutDir 'observe.json')))
Check 'O9 handoff HANDOFF_ACKNOWLEDGED, Th recorded, gadget FS-<nonce> on COM9, collector command printed with -BootStartUtc (origin) then -HandoffUtc (evidence)' ($ob.HandoffClass -ceq 'HANDOFF_ACKNOWLEDGED' -and $ob.GadgetSeen -and $ob.ComPort -ceq 'COM9' -and $ob.NextCommand -match "-Stage 2a -Port COM9 -Nonce $ON -BootStartUtc 2026-10-09T09:00:00\.3\d*Z -HandoffUtc 2026-10-09T09:00:11") $ob.NextCommand
$fk2 = New-FakeDevice; $o2 = Invoke-ObsFake $fk2 $b $ON
Check 'O10 the same nonce again: refused (one attempt per nonce), no fastboot call' ($o2.Exit -eq 2 -and $o2.Why -match 'already attempted' -and $fk2.Calls.Count -eq 0)
$br = New-ObsBuild '3a' 'c0de0b5e00000003'
$fk = New-FakeDevice 'reject'; $o = Invoke-ObsFake $fk $br 'c0de0b5e00000003'
Check 'O11 stage 3a, device refuses the boot: DEVICE_REJECTED, one boot call, no gadget wait' ($o.Exit -eq 0 -and $o.Observe.HandoffClass -ceq 'DEVICE_REJECTED' -and $fk.Calls.Count -eq 2 -and $fk.Polls -eq 0)
Check 'O12 ...and the derived stage-1 class is DEVICE_REJECTED' ((Get-FsStage1Class -Observe $o.Observe -Collect ([pscustomobject]@{ Nonce = 'c0de0b5e00000003'; Stage = '3a'; Verified = $false })).Class -ceq 'DEVICE_REJECTED')
# dry end to end: the fake serial device answers as a correct stage-2a target would (synthetic, with THIS nonce)
$OV = '0f1e2d3c4b5a69788796a5b4c3d2e1f0'; $OA = '5a5a0123456789ab'; $OC = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'
$st5 = 'INIT_STARTED,MODULES_READY,ACM_SETUP_ATTEMPTED,UDC_BOUND,SHELL_READY'
$PR = "~ # $([char]27)[6n"
$sy = New-Synth -Nonce $ON
function OD([string]$t) { Add-Dev $sy (B $t) }
OD $PR; $sy.Ms = 1000
Add-Host $sy "fs-verify $OV"; OD "fs-verify $OV`n"; OD "FSV1 nonce=$ON resp=$(Get-FsSha256Hex (B "$($ON):$OV")) kernel=$($script:SynKernel) pid1=$($script:SynPid1) stages=$st5 END`n"; OD $PR
Add-Host $sy "fs-ack $OA"; OD "fs-ack $OA`nFSA1 queued END`n"; OD $PR
Add-Host $sy 'fs-status' 2600; OD "fs-status`nFSS1 nonce=$ON stages=$st5,HOST_ACK acked=$OA END`n"; OD $PR
Add-Host $sy "fs-valve $OC"; OD "fs-valve $OC`n"; Add-Dev $sy (B ("`n" + (New-SynthFsb1 -Exp 'stage2a' -Nonce $ON -Chal $OC -Steps (Get-Stage2aGoodSteps -Nonce $ON -Chal $OC)))) -Chunk 256; OD $PR
Add-Host $sy 'fs-done'; OD "fs-done`nFSD1 queued END`n"
$raw = Join-Path $Scratch 'obs-e2e.raw'; Save-Synth $sy $raw
$cdir = Join-Path $obDir 'collect'
$r = Invoke-FsReplay -RawPath $raw -OutDir $cdir -Nonce $ob.Nonce -Overrides @{ Stage = '2a' }
Save-FsCollectJson -Result $r -Path (Join-Path $cdir 'collect.json')
Check 'O13 dry e2e: the collector (fake serial) sent exactly one fs-ack (the observer sent none), ran fs-valve once, COLLECTED-VALID' ((@($r.Sent | Where-Object { $_ -like 'fs-ack *' }).Count -eq 1) -and (@($r.Sent | Where-Object { $_ -like 'fs-valve *' }).Count -eq 1) -and $r.Status -ceq 'COLLECTED-VALID' -and $r.DoneSent) "status=$($r.Status) sent=$(@($r.Sent) -join ',')"
$cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 2a -CollectDir $cdir -ObserveDir $obDir
Check 'O14 dry e2e: fs-classify.ps1 -ObserveDir derives STAGE-1 CLASS PASS from the verified FSV1, then OUTCOME PASS (exit 10)' (($cl -join "`n") -match 'STAGE-1 CLASS: PASS' -and ($cl -join "`n") -match 'OUTCOME: PASS ' -and $LASTEXITCODE -eq 10) ($cl -join ' / ')
$cl = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-observe.ps1') -Stage 2a -Image $b.Img
Check 'O15 CLI without -ConfirmNonce or -Preflight: exit 3' ($LASTEXITCODE -eq 3 -and ($cl -join ' ') -match 'no PM sign-off')
Check 'O16 stage-1 class TRANSPORT/SHELL FAILURE when the gadget came up but no FSV1 verified' ((Get-FsStage1Class -Observe $ob -Collect ([pscustomobject]@{ Nonce = $ON; Stage = '2a'; Verified = $false })).Class -ceq 'TRANSPORT/SHELL FAILURE')
Check 'O17 stage-1 class INCONCLUSIVE when observer and collector disagree on the nonce' ((Get-FsStage1Class -Observe $ob -Collect ([pscustomobject]@{ Nonce = 'ffffffffffffffff'; Stage = '2a'; Verified = $true })).Class -ceq 'INCONCLUSIVE')
# --- fix round 7 ---
$bc = New-ObsBuild '2a' 'c0de0b5e00000004'
$cp = Join-Path $Scratch ('copied-' + (New-FsHex 3)); $null = New-Item -ItemType Directory -Path $cp
Copy-Item -Recurse -LiteralPath $bc.Dir -Destination $cp
$copied = [pscustomobject]@{ Img = (Join-Path $cp "$(Split-Path -Leaf $bc.Dir)\boot-stage2a.img"); Ledger = $bc.Ledger; Dir = (Join-Path $cp (Split-Path -Leaf $bc.Dir)) }
$fk = New-FakeDevice; $o = Invoke-ObsFake $fk $copied 'c0de0b5e00000004'
Check 'O19 SF1 a build folder copied elsewhere is refused (fixed ledger <repo>\build\stage2a\attempted), no fastboot call, nothing written' ($o.Exit -eq 2 -and $o.Why -match 'not in' -and $fk.Calls.Count -eq 0 -and -not (Test-Path (Join-Path $copied.Dir 'attempt.lock')))
$bt2 = New-ObsBuild '2a' 'c0de0b5e00000005'
$fk = New-FakeDevice 'timeout'; $o = Invoke-ObsFake $fk $bt2 'c0de0b5e00000005'
Check 'O20 fastboot boot times out: handoff INCONCLUSIVE, the budget origin is the boot START and the printed command passes it as -BootStartUtc' ($o.Exit -eq 0 -and $o.Observe.HandoffClass -ceq 'INCONCLUSIVE' -and $o.Observe.BudgetOriginUtc -ceq $o.Observe.BootStartUtc -and $o.Observe.BudgetOriginUtc -cne $o.Observe.HandoffUtc -and $o.Observe.NextCommand -match [regex]::Escape("-BootStartUtc $($o.Observe.BootStartUtc) -HandoffUtc $($o.Observe.HandoffUtc)")) "origin=$($o.Observe.BudgetOriginUtc) th=$($o.Observe.HandoffUtc)"
# --- FS-R-007 B1: the origin is BootStartUtc for EVERY handoff class (Th is evidence only) ---
Check 'O22 B1 acknowledged handoff: the budget origin is still the boot START (taken before fastboot boot), not Th; -BootStartUtc in the printed command' ($ob.BudgetOriginUtc -ceq $ob.BootStartUtc -and $ob.BootStartUtc -cne $ob.HandoffUtc -and ([DateTime]::Parse($ob.BootStartUtc) -lt [DateTime]::Parse($ob.HandoffUtc)) -and $ob.NextCommand -match [regex]::Escape("-BootStartUtc $($ob.BootStartUtc) ") -and $ob.NextCommand -notmatch 'HandoffBasis') "origin=$($ob.BudgetOriginUtc) th=$($ob.HandoffUtc)"
$obsSrc = [IO.File]::ReadAllText((Join-Path $HOSTDIR 'fs-observe.ps1'))
$iStart = $obsSrc.IndexOf('$o.BootStartUtc = (& $NowUtc)'); $mBoot = [regex]::Match($obsSrc, "Fastboot @\(.-s., .Serial, .boot., .ImagePath\)"); $iBoot = if ($mBoot.Success) { $mBoot.Index } else { -1 }
Check 'O23 B1 source order: BootStartUtc is taken before the one fastboot boot invocation (the origin precedes the command)' ($iStart -gt 0 -and $iBoot -gt $iStart) "start@$iStart boot@$iBoot"
if ($results.ContainsKey('already-acked')) {
    $sp = @($results['already-acked'].Phases | Where-Object { $_.Verb -ceq 'fs-status' })[0]
    $r7 = Invoke-FsReplay -RawPath (Join-Path $FX 'already-acked.raw') -OutDir (Join-Path $Scratch 'o21') -Overrides @{ AckGiveUpMs = [long]($sp.SendMs + 100) }
    $dp = @($r7.Phases | Where-Object { $_.Verb -ceq 'fs-done' })
    Check 'O21 NIT7 foreign ack at the very end of the ack window: the gated fs-done is still sent (after the window), the device recovers at once' ($r7.ForeignAck -and $r7.DoneSent -and $dp.Count -eq 1 -and $dp[0].SendMs -ge $sp.SendMs + 100) "done=$($r7.DoneSent) doneSend=$(if ($dp.Count) { $dp[0].SendMs }) cap=$($sp.SendMs + 100) stop=$($r7.StopReason)"
}
if ($results.ContainsKey('already-acked')) {
    $aa = $results['already-acked']
    Check 'O18 B1 already-acked: stopped at the first FSS1 showing a foreign ack (one fs-status), no fs-valve, gated fs-done sent' ($aa.ForeignAck -ceq '0123456789abcdef' -and @($aa.Sent | Where-Object { $_ -ceq 'fs-status' }).Count -eq 1 -and -not $aa.ValveSent -and $aa.DoneSent)
}

# ------------------------------------------------------------------ T --------
Say '== T. FS-R-007 B1 timing: origin BootStartUtc, preparation counted (fixtures\b1-timing.ps1: observer -> live collector CLI; simulated device side, no port)'
$tb = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $FIXDIR 'b1-timing.ps1') -HostDir $HOSTDIR -Scratch (Join-Path $Scratch 'b1'))
$tn = 0
foreach ($l in $tb) {
    if ($l -cmatch '^(PASS|FAIL)  (T\d+) (.*)$') { $tn++; Check "$($Matches[2]) $($Matches[3])" ($Matches[1] -ceq 'PASS') }
    elseif ($l -cmatch '^\s{8}\S') { Say $l }
}
Check 'T0 fixtures\b1-timing.ps1 ran all 9 regressions (T1-T5 fail on fbca773: b1-timing.fbca773.txt; T9 fails on 5c2e3f9: b1-timing.5c2e3f9.txt)' ($tn -eq 9) ($tb -join ' / ')

# ------------------------------------------------------------------ M --------
Say '== M. misc rule: fs-miscrule.ps1 vs common/tools/misc_rule.py (full output, case for case)'
$RAW = Join-Path $ROOT 'relays\FS-A-005-raw'
if (-not (Test-Path (Join-Path $RAW 'misc-ctrl0.img'))) { Skip 'M misc rule cases and M+ CLI cases' 'withheld evidence: the relays/FS-A-005-raw misc dumps are not in the public copy' } else {
$ctrl0 = [IO.File]::ReadAllBytes((Join-Path $RAW 'misc-ctrl0.img')); $ctrl1 = [IO.File]::ReadAllBytes((Join-Path $RAW 'misc-ctrl1.img'))
$after = [IO.File]::ReadAllBytes((Join-Path $RAW 'misc-after.img'))
$mp = Join-Path $ROOT 'firmware\quest3\unit1_nonslotted\misc.img'
$march = if (Test-Path $mp) { [IO.File]::ReadAllBytes($mp) } else { $null }
function Ed([byte[]]$img, [int]$off, [byte[]]$data) { $b = [byte[]]$img.Clone(); [Array]::Copy($data, 0, $b, $off, $data.Length); ,$b }
function Pad32([string]$s) { $b = New-Object byte[] 32; $x = B $s; [Array]::Copy($x, $b, $x.Length); ,$b }
$mcases = New-Object System.Collections.Generic.List[object]
function MC($n, $b, $a, $w, $src) { $mcases.Add([pscustomobject]@{ N = $n; B = $b; A = $a; W = $w; Src = $src }) }
# the 18 cases of common/tools/test_misc_rule.py, rebuilt identically
MC 'real-control-ctrl0-ctrl1' $ctrl0 $ctrl1 'RECORDED' 'py'
MC 'real-trial-after-eq-ctrl0' $after $ctrl0 'UNCHANGED' 'py'
MC 'identical' $ctrl1 $ctrl1 'UNCHANGED' 'py'
MC 'c-E1-to-E0' $ctrl0 (Ed $ctrl0 0 (New-Object byte[] 32)) 'STOP' 'py'
MC 'c-recovery' $ctrl0 (Ed $ctrl0 0 (Pad32 'boot-recovery')) 'STOP' 'py'
MC 'c-junk-after-nul' $ctrl0 (Ed $ctrl0 0x1f ([byte[]]@(1))) 'STOP' 'py'
MC 'c-before-unexpected' (Ed $ctrl0 0 (Pad32 'boot-recovery')) (Ed $ctrl0 0 (Pad32 'boot-recovery')) 'STOP' 'py'
MC 'o-status-field' $ctrl0 (Ed $ctrl0 0x20 ([byte[]]@(0x41))) 'STOP' 'py'
MC 'o-just-below-v' $ctrl0 (Ed $ctrl0 0x100f ([byte[]]@(1))) 'STOP' 'py'
MC 'o-just-above-v' $ctrl0 (Ed $ctrl0 0x101c ([byte[]]@(3))) 'STOP' 'py'
MC 'o-vab-message' $ctrl0 (Ed $ctrl0 0x8008 ([byte[]]@(1))) 'STOP' 'py'
MC 'o-slot-suffix' $ctrl0 (Ed $ctrl0 0x800 (B '_b')) 'STOP' 'py'
MC 'v-and-other' $ctrl0 (Ed $ctrl1 0x1400 ([byte[]]@(0))) 'STOP' 'py'
MC 'truncated-after' $ctrl0 ([byte[]]$ctrl1[0..($ctrl1.Length - 2)]) 'INCONCLUSIVE' 'py'
MC 'empty-before' ([byte[]]@()) $ctrl1 'INCONCLUSIVE' 'py'
if ($null -ne $march) {
    MC 'real-dump-march-to-ctrl0' $march $ctrl0 'RECORDED' 'py'
    $e1 = Pad32 'bootonce-bootloader'
    MC 'c-E0-to-E1-only' $march (Ed $march 0 $e1) 'EXPECTED' 'py'
    MC 'c-E0-unchanged' $march $march 'UNCHANGED' 'py'
}
# extra edges (not in the Python suite; Python is still run on each)
MC 'x-v-high-byte-0x101b' $ctrl0 (Ed $ctrl0 0x101b ([byte[]]@(0x7f))) 'RECORDED' 'extra'
MC 'x-v-first-byte-0x1010' $ctrl0 (Ed $ctrl0 0x1010 ([byte[]]@(0xaa))) 'RECORDED' 'extra'
MC 'x-c-E0-to-other' (Ed $ctrl0 0 (New-Object byte[] 32)) (Ed $ctrl0 0 (Pad32 'bootonce-recovery')) 'STOP' 'extra'
MC 'x-c-E0-to-E1-plus-V' (Ed $ctrl0 0 (New-Object byte[] 32)) $ctrl1 'RECORDED' 'extra'
MC 'x-o-last-byte' $ctrl0 (Ed $ctrl0 0xFFFFF ([byte[]]@(1))) 'STOP' 'extra'
MC 'x-o-many-runs' $ctrl0 (Ed (Ed (Ed (Ed (Ed (Ed (Ed (Ed (Ed $ctrl0 0x2000 ([byte[]]@(1))) 0x2002 ([byte[]]@(1))) 0x2004 ([byte[]]@(1))) 0x2006 ([byte[]]@(1))) 0x2008 ([byte[]]@(1))) 0x200a ([byte[]]@(1))) 0x200c ([byte[]]@(1))) 0x200e ([byte[]]@(1))) 0x2010 ([byte[]](1, 1, 1))) 'STOP' 'extra'
MC 'x-oversize-after' $ctrl0 ([byte[]]($ctrl1 + [byte[]]@(0))) 'INCONCLUSIVE' 'extra'
MC 'x-both-empty' ([byte[]]@()) ([byte[]]@()) 'INCONCLUSIVE' 'extra'
$md = Join-Path $Scratch 'misc'; $null = New-Item -ItemType Directory -Force $md
$pyScript = Join-Path $ROOT 'devices\quest3\common\tools\misc_rule.py'
$agreeN = 0
foreach ($m in $mcases) {
    $r = Get-FsMiscVerdict -Before $m.B -After $m.A
    $mine = @($r.Lines) + @("VERDICT $($r.Verdict)")
    $detail = ''
    $ok = ($r.Verdict -ceq $m.W)
    if ($python) {
        $bp = Join-Path $md "$($m.N).before"; $ap = Join-Path $md "$($m.N).after"
        [IO.File]::WriteAllBytes($bp, $m.B); [IO.File]::WriteAllBytes($ap, $m.A)
        $py = @(& $python -I $pyScript $bp $ap); $prc = $LASTEXITCODE
        $same = ($py.Count -eq $mine.Count) -and ($prc -eq 10 + $r.Rank)
        if ($same) { for ($k = 0; $k -lt $py.Count; $k++) { if ($py[$k] -cne $mine[$k]) { $same = $false; $detail = "line $k differs: py='$($py[$k])' ps='$($mine[$k])'" } } }
        else { $detail = "py rc=$prc lines=$($py.Count), ps rc=$(10 + $r.Rank) lines=$($mine.Count)" }
        if ($same) { $agreeN++ }
        $ok = $ok -and $same
    }
    Check ("M {0,-28} {1,-12} ({2})" -f $m.N, $r.Verdict, $m.Src) $ok $detail
}
if ($python) { Say "   CROSS-CHECK fs-miscrule.ps1 = misc_rule.py (all lines, VERDICT, exit status) on $agreeN of $($mcases.Count) cases" }
else { Skip 'M python cross-check' 'python not found' }
if ($null -eq $march) { Say '   (firmware misc.img absent: the 3 March-dump cases were skipped, as in test_misc_rule.py)' }
$cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-miscrule.ps1') (Join-Path $RAW 'misc-ctrl0.img') (Join-Path $RAW 'misc-ctrl1.img')
Check 'M+ fs-miscrule.ps1 CLI on the real control: VERDICT RECORDED, exit 12' ($LASTEXITCODE -eq 12 -and ($cli[-1] -ceq 'VERDICT RECORDED'))
foreach ($ec in @(@('missing capture file', (Join-Path $Scratch 'no-such-before.img')), @('unreadable capture (a directory)', $Scratch))) {
    $cli = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-miscrule.ps1') $ec[1] (Join-Path $RAW 'misc-ctrl1.img')); $psrc = $LASTEXITCODE
    $okE = ($psrc -eq 14 -and $cli[-1] -ceq 'VERDICT INCONCLUSIVE')
    if ($python) { $py = @(& $python -I $pyScript $ec[1] (Join-Path $RAW 'misc-ctrl1.img')); $okE = $okE -and ($LASTEXITCODE -eq 14) -and ($py[-1] -ceq 'VERDICT INCONCLUSIVE') -and $py.Count -eq $cli.Count }
    Check "M+ $($ec[0]): VERDICT INCONCLUSIVE, exit 14 in both implementations (never an EXPECTED-like code)" $okE "ps rc=$psrc"
}
# the remaining CLI cases of test_misc_rule.py (rev 4): unchanged 10, short capture 14, usage 64, codes disjoint from 0/1/2
$shortP = Join-Path $md 'cli-short.img'; [IO.File]::WriteAllBytes($shortP, [byte[]]$ctrl1[0..4095])
foreach ($cc in @(@('cli-unchanged', @((Join-Path $RAW 'misc-ctrl0.img'), (Join-Path $RAW 'misc-ctrl0.img')), 10, 'VERDICT UNCHANGED'),
                  @('cli-short-after', @((Join-Path $RAW 'misc-ctrl0.img'), $shortP), 14, 'VERDICT INCONCLUSIVE'),
                  @('cli-usage', @((Join-Path $RAW 'misc-ctrl0.img')), 64, $null))) {
    $cli = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-miscrule.ps1') @($cc[1])); $psrc = $LASTEXITCODE
    $okC = ($psrc -eq $cc[2]) -and ($null -eq $cc[3] -or $cli[-1] -ceq $cc[3])
    if ($python) { $null = @(& $python -I $pyScript @($cc[1])); $okC = $okC -and ($LASTEXITCODE -eq $cc[2]) }
    Check "M+ $($cc[0]): exit $($cc[2]) in both implementations" $okC "ps rc=$psrc"
}
}  # end of the section-M evidence guard
$cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -CollectDir (Join-Path $Scratch 'no-such-dir') -Stage1Class PASS
Check 'K+ fs-classify.ps1 CLI on an unreadable collection: INCONCLUSIVE, exit 14' ($LASTEXITCODE -eq 14 -and ($cli -join ' ') -match 'OUTCOME: INCONCLUSIVE')

# ------------------------------------------------------------------ G --------
Say "== G. E1 git checks (PowerShell; $(& git --version))"
$GT = Join-Path $Scratch 'git'; $null = New-Item -ItemType Directory -Force $GT
function GitQ { param([string[]]$a) $r = Invoke-FsGit 'git' (@('-c', 'user.name=fixture', '-c', 'user.email=fixture@invalid', '-c', 'init.defaultBranch=main', '-c', 'core.autocrlf=false') + $a); if ($r.Code -ne 0) { throw "git $($a -join ' '): $($r.Err)" }; $r.Out.Trim() }
function MkRepo([string]$d) {
    $null = New-Item -ItemType Directory -Force $d
    $null = GitQ @('-C', $d, 'init', '-q')
    [IO.File]::WriteAllText((Join-Path $d 'mkbootimg.py'), "print(`"mkbootimg`")`n"); [IO.File]::WriteAllText((Join-Path $d 'README'), "data`n")
    $null = GitQ @('-C', $d, 'add', '-A'); $null = GitQ @('-C', $d, 'commit', '-q', '-m', 'fixture')
    GitQ @('-C', $d, 'rev-parse', 'HEAD')
}
function GRef([string]$name, [string]$repo, [string]$commit, [string]$must) {
    $r = Test-FsGitCheckout -Repo $repo -ExpectCommit $commit
    $txt = ($r.Failures -join ' | ')
    Check "$name (refused: $(if ($txt.Length -gt 140) { $txt.Substring(0, 140) } else { $txt }))" ((-not $r.Ok) -and ($must -eq '' -or $txt.Contains($must))) $txt
}
$c = MkRepo "$GT\clean"
Check 'G1 clean checkout accepted' (Test-FsGitCheckout -Repo "$GT\clean" -ExpectCommit $c).Ok
$c = MkRepo "$GT\untracked"; [IO.File]::WriteAllText("$GT\untracked\hashlib.py", "evil`n")
GRef 'G2 planted untracked hashlib.py' "$GT\untracked" $c 'hashlib.py'
$c = MkRepo "$GT\ignored"; [IO.File]::WriteAllText("$GT\ignored\.git\info\exclude", "*.pyc`n"); [IO.File]::WriteAllText("$GT\ignored\gki.pyc", 'x')
GRef 'G4 planted ignored file' "$GT\ignored" $c 'gki.pyc'
$c = MkRepo "$GT\shownone"; $null = GitQ @('-C', "$GT\shownone", 'config', 'status.showUntrackedFiles', 'no'); [IO.File]::WriteAllText("$GT\shownone\hashlib.py", "evil`n")
GRef 'G5 status.showUntrackedFiles=no cannot hide a planted file' "$GT\shownone" $c 'hashlib.py'
# E1: core.worktree redirect
$c = MkRepo "$GT\e1"; $null = New-Item -ItemType Directory "$GT\e1alt"; Copy-Item "$GT\e1\mkbootimg.py", "$GT\e1\README" "$GT\e1alt\"
[IO.File]::WriteAllText("$GT\e1\hashlib.py", "evil`n"); $null = GitQ @('-C', "$GT\e1", 'config', 'core.worktree', ("$GT\e1alt" -replace '\\', '/'))
$old = Invoke-FsGit 'git' @('-c', 'core.fsmonitor=false', '-c', 'status.showUntrackedFiles=all', '-c', "core.worktree=$GT\e1", '-C', "$GT\e1", 'status', '--porcelain', '--ignored', '--untracked-files=all')
Check 'G6c CONTROL: the stage-1 ag() form reports the redirected checkout clean (E1 reproduced)' ($old.Code -eq 0 -and $old.Out.Trim() -eq '') "out='$($old.Out.Trim())' err='$($old.Err.Trim())'"
GRef 'G6 core.worktree redirect: refused for the config entry' "$GT\e1" $c 'core.worktree is set'
GRef 'G6b core.worktree redirect: explicit --work-tree status finds the planted file' "$GT\e1" $c 'hashlib.py'
# environment
$c = MkRepo "$GT\envwt"; $null = New-Item -ItemType Directory "$GT\envwtalt"; Copy-Item "$GT\envwt\mkbootimg.py", "$GT\envwt\README" "$GT\envwtalt\"; [IO.File]::WriteAllText("$GT\envwt\hashlib.py", "evil`n")
$env:GIT_WORK_TREE = "$GT\envwtalt"
try { GRef 'G7 GIT_WORK_TREE in the caller''s environment is removed' "$GT\envwt" $c 'hashlib.py' } finally { Remove-Item Env:GIT_WORK_TREE }
$c = MkRepo "$GT\envgd"; [IO.File]::WriteAllText("$GT\envgd\hashlib.py", "evil`n")
$env:GIT_DIR = "$GT\clean\.git"; $env:GIT_INDEX_FILE = "$GT\clean\.git\index"
try { GRef 'G8 GIT_DIR/GIT_INDEX_FILE in the caller''s environment are removed' "$GT\envgd" $c 'hashlib.py' } finally { Remove-Item Env:GIT_DIR; Remove-Item Env:GIT_INDEX_FILE }
$c = MkRepo "$GT\au"; $null = GitQ @('-C', "$GT\au", 'update-index', '--assume-unchanged', 'mkbootimg.py'); Add-Content "$GT\au\mkbootimg.py" 'x'
GRef 'G9 assume-unchanged entry' "$GT\au" $c 'assume-unchanged'
$c = MkRepo "$GT\sw"; $null = GitQ @('-C', "$GT\sw", 'update-index', '--skip-worktree', 'README')
GRef 'G10 skip-worktree entry' "$GT\sw" $c 'skip-worktree'
$c = MkRepo "$GT\head"; [IO.File]::WriteAllText("$GT\head\README", "y`n"); $null = GitQ @('-C', "$GT\head", 'commit', '-q', '-am', 'second')
GRef 'G12 HEAD is not the pinned commit' "$GT\head" $c 'not the pinned'
$c = MkRepo "$GT\gfreal"; $null = New-Item -ItemType Directory "$GT\gf"; Copy-Item "$GT\gfreal\mkbootimg.py", "$GT\gfreal\README" "$GT\gf\"; [IO.File]::WriteAllText("$GT\gf\.git", "gitdir: $($GT -replace '\\', '/')/gfreal/.git`n")
GRef 'G13 .git is a gitfile' "$GT\gf" $c 'gitfile'
$c = MkRepo "$GT\jreal"; $null = New-Item -ItemType Directory "$GT\jn"; Copy-Item "$GT\jreal\mkbootimg.py", "$GT\jreal\README" "$GT\jn\"
try { $null = New-Item -ItemType Junction -Path "$GT\jn\.git" -Target "$GT\jreal\.git"; GRef 'G14 .git is a junction' "$GT\jn" $c 'link or junction' } catch { Skip 'G14 .git junction' $_.Exception.Message }
GRef 'G15 relative repository path' 'clean' $c 'not absolute'
GRef 'G16 malformed pinned commit' "$GT\clean" 'ABCDEF' '40 lowercase hex'
# POSIX sh twin, under the builder's environment (WSL)
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($wsl) {
    $toWsl = { param($p) '/mnt/' + $p.Substring(0, 1).ToLowerInvariant() + ($p.Substring(2) -replace '\\', '/') }
    $fx = & $toWsl (Join-Path $FIXDIR 'gitcheck\run-gitcheck-fixtures.sh'); $ck = & $toWsl (Join-Path $HOSTDIR 'fs-gitcheck.sh')
    foreach ($sh in @(@('dash'), @('bash', '--posix'))) {
        $o = & wsl.exe -e @sh $fx $ck 2>&1 | ForEach-Object { "$_" }
        $tot = @($o | Where-Object { $_ -match '^TOTAL:' })
        foreach ($l in $o) { Say "   [$($sh -join ' ')] $l" }
        Check "G-sh fixtures under WSL $($sh -join ' '): $(if ($tot) { $tot[-1] } else { 'no TOTAL line' })" ($LASTEXITCODE -eq 0 -and $tot.Count -eq 1 -and $tot[0] -match ', 0 failed')
    }
} else { Skip 'G-sh fixtures' 'wsl.exe not found' }

# ------------------------------------------------------------------ B --------
Say '== B. before/after command data'
Skip 'B before/after command data (read-only allowlist)' 'withheld'

# ------------------------------------------------------------------ P --------
Skip 'P before/after capture tool with fake adb/fastboot' 'withheld'

}   # end of: if ($Only -ne 'F')

# ------------------------------------------------------------------ F --------
. (Join-Path $FIXDIR 'findings-da0ad56.ps1')

# ------------------------------------------------------------------ end ------
Say "TOTAL: $($script:pass) passed, $($script:fail) failed, $($script:skip) skipped"
[IO.File]::WriteAllText($OutFile, (($script:log | ForEach-Object { "$_`n" }) -join ''), (New-Object System.Text.UTF8Encoding($false)))
if ($script:fail -eq 0) { exit 0 } else { exit 1 }
