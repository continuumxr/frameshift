# Section L of test-host2.ps1: the versioned step-4 `list` rule (fs-classify.ps1
# "§5 step-4 `list` rule"; stage2a/LISTING-RULE-A.md; ruling FS-R-009 §4).
#   v1  = the registered rule (exactly 3 lines); the default for the run registered under it
#         (trial (i), nonce 93a1501f0b1fb692).
#   v2A = amended rule A (adopted, FS-R-009 §4); the default otherwise: optional ONE first
#         unnamed-map line `\t (0x<16 hex>)`, nonzero and distinct from the 3 required addresses,
#         then the 3 lines. No ordering condition.
# Sources (each checked against a recorded hash before use, so a wrong copy fails, never passes):
#   (a) the real device output: trial (i), Quest 3, nonce 93a1501f0b1fb692, decoded from
#       relays/FS-A-009-raw/observe/collect/capture.raw (SHA-256 = collect.json) and compared with
#       relays/FS-A-009-raw/decoded/4.out;
#   (b) the qemu 3-line outputs: stage2a/evidence/fixture/step2.out (b2sum) and step3.out (uname),
#       SHA-256 as recorded in fixture-transcript.txt;
#   (c) qemu 4-line outputs from relays/FS-A-009-raw/listing-evidence/qemu-raw.log, with the unnamed
#       map BELOW the loader (B-a72-b2sum run 1) and ABOVE it (B-a72-b2sum run 3, B-a72-uname run 5);
#   (d) negative cases built from (a).
# The v2A result on the real output is a FIXTURE check of the rule only. It is NOT a re-grade of
# trial (i): that run stays classified under v1 as registered (FS-R-009 §4).
# Git may check these text files out with CRLF (core.autocrlf); bytes are read with CRLF -> LF and
# then checked against the recorded hash, so the normalisation can never hide a difference.
# Needs (from test-host2.ps1): Check, Say, B, $Scratch, $ROOT, $HOSTDIR; fs-classify.ps1, synth.ps1.

Say '== L. step-4 list rule versions (v1 registered; v2A = amended rule A, FS-R-009 section 4)'
function Read-LfBytes([string]$rel) {
    [byte[]]$b = [IO.File]::ReadAllBytes((Join-Path $ROOT $rel))
    $o = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -eq 13 -and $i + 1 -lt $b.Length -and $b[$i + 1] -eq 10) { continue }; $o.Add($b[$i]) }
    ,$o.ToArray()
}
function LStep([byte[]]$out) { New-SynthStep 4 'list' $out @() }
function LClass([byte[]]$out, [string]$rule) { Get-FsS2ValveClass (LStep $out) $script:SynKernel ('0' * 16) ('0' * 32) $rule }
$L1 = [System.Text.Encoding]::GetEncoding(28591)

# ---- (a) the real device record
$realDir = 'relays\FS-A-009-raw\observe\collect'
$rj = Get-Content -Raw (Join-Path $ROOT "$realDir\collect.json") | ConvertFrom-Json
[byte[]]$rraw = Read-LfBytes "$realDir\capture.raw"
$rawOk = ((Get-FsSha256Hex $rraw) -ceq $rj.Capture.Sha256)
Check 'L01 real trial (i) capture.raw (CRLF->LF) has the SHA-256 recorded in collect.json' $rawOk "got $(Get-FsSha256Hex $rraw) want $($rj.Capture.Sha256)"
$rrec = Test-Fsb1Record -Bytes $rraw -Exp 'stage2a' -Nonce $rj.Nonce -Challenge $rj.Challenge -Steps $script:S2Steps
Check 'L02 real record decodes: FSB1 valid, 8 steps, nonce 93a1501f0b1fb692' ($rrec.Ok -and @($rrec.Steps).Count -eq 8 -and $rj.Nonce -ceq '93a1501f0b1fb692') "reason $($rrec.Reason)"
[byte[]]$real4 = @($rrec.Steps)[3]['out']
$real4Text = $L1.GetString($real4)
Check 'L03 real step 4 bytes = relays/FS-A-009-raw/decoded/4.out, 4 lines, first is the main-map line' (
    $real4Text -ceq $L1.GetString((Read-LfBytes 'relays\FS-A-009-raw\decoded\4.out')) -and
    $real4Text.Split([char]10).Count -eq 5 -and $real4Text.StartsWith("`t (0x0000007fb78d0000)`n", [StringComparison]::Ordinal))
$c = LClass $real4 'v1'
Check 'L04 v1 (registered) on the real output: FAILED "not exactly 3 terminated lines" (registered behaviour preserved)' ($c.Class -ceq 'FAILED' -and $c.Notes -ceq 'content: not exactly 3 terminated lines') $c.Notes
$c = LClass $real4 'v2A'
Check 'L05 v2A (amended rule A) on the real output: OK, 4 lines, unnamed-map line accepted [fixture only, not a re-grade]' ($c.Class -ceq 'OK' -and $c.Notes -match '4 lines, unnamed-map line accepted') $c.Notes

# whole-record classification of the real run under the default rule = the registered result
$ro = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $rj.Kernel -Fsb1 $rrec -Nonce $rj.Nonce -Challenge $rj.Challenge -Collected ([bool]$rj.RecordComplete)
Check 'L06 real record, default rule for its nonce: v1 applied, COMPATIBILITY FAIL rule 6, lowest failing step 4 (as registered, relays/FS-A-009-raw/classify.txt)' (
    $ro.Outcome -ceq 'COMPATIBILITY FAIL' -and $ro.Rule -eq 6 -and $ro.Reason -ceq 'lowest failing step 4 list: content: not exactly 3 terminated lines' -and
    $ro.ListRule -match '^list rule v1 ' -and @($ro.Failing).Count -eq 1) "$($ro.Outcome) $($ro.Rule) $($ro.Reason) [$($ro.ListRule)]"
$ro1 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $rj.Kernel -Fsb1 $rrec -Nonce $rj.Nonce -Challenge $rj.Challenge -Collected ([bool]$rj.RecordComplete) -ListRule v1
Check 'L07 real record, explicit -ListRule v1: identical to the default' ($ro1.Outcome -ceq $ro.Outcome -and $ro1.Reason -ceq $ro.Reason -and $ro1.ListRule -ceq $ro.ListRule)

# CLI on a copy of the real collection: every registered line, in order, plus the rule line
$rd = Join-Path $Scratch 'l-real'; $null = New-Item -ItemType Directory -Force -Path (Join-Path $rd 'collect')
[IO.File]::WriteAllBytes((Join-Path $rd 'collect\capture.raw'), $rraw)
[IO.File]::WriteAllBytes((Join-Path $rd 'collect\collect.json'), (Read-LfBytes "$realDir\collect.json"))
[IO.File]::WriteAllBytes((Join-Path $rd 'observe.json'), (Read-LfBytes 'relays\FS-A-009-raw\observe\observe.json'))
$cl = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 2a -CollectDir (Join-Path $rd 'collect') -ObserveDir $rd)
$clx = $LASTEXITCODE
$reg = @($L1.GetString((Read-LfBytes 'relays\FS-A-009-raw\classify.txt')).TrimEnd("`n").Split([char]10))
$want = New-Object System.Collections.Generic.List[string]
foreach ($x in $reg) { if ($x -cmatch '^exit=') { continue }; if ($x.StartsWith('Separate gates', [StringComparison]::Ordinal)) { $want.Add('Step-4 list rule applied: list rule v1 (registered, T1-PINS \xa73: exactly 3 lines)') }; $want.Add($x) }
Check 'L08 CLI on the real collection (default rule for its nonce): the registered classify.txt output line for line, plus "Step-4 list rule applied: list rule v1", exit 11' (
    ($cl -join "`n") -ceq ($want -join "`n") -and $clx -eq 11 -and ($reg -ccontains 'exit=11')) ("exit $clx / " + ($cl -join ' / '))
$cl = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 2a -CollectDir (Join-Path $rd 'collect') -ObserveDir $rd -ListRule v3)
Check 'L09 CLI -ListRule v3 (unknown): usage, exit 64, no OUTCOME line' ($LASTEXITCODE -eq 64 -and ($cl -join ' ') -notmatch 'OUTCOME') ($cl -join ' / ')
$cl = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 3a -CollectDir (Join-Path $rd 'collect') -ObserveDir $rd -ListRule v2A)
Check 'L10 CLI -Stage 3a with -ListRule: usage, exit 64 (the rule is stage 2a only)' ($LASTEXITCODE -eq 64) ($cl -join ' / ')
$uo = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $rj.Kernel -Fsb1 $rrec -Nonce $rj.Nonce -Challenge $rj.Challenge -ListRule 'V2A'
$uo2 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 $rrec -Nonce ('b' * 16) -Challenge $rj.Challenge -ListRule 'v3'
Check 'L11 function, unknown rule (V2A wrong case on the real record; v3 on another nonce): INCONCLUSIVE rule 0 "unknown list rule version" (not rule 8; never a silent v1)' (
    $uo.Outcome -ceq 'INCONCLUSIVE' -and $uo.Rule -eq 0 -and $uo.Reason.StartsWith('unknown list rule version', [StringComparison]::Ordinal) -and
    $uo2.Outcome -ceq 'INCONCLUSIVE' -and $uo2.Rule -eq 0 -and $uo2.Reason.StartsWith('unknown list rule version', [StringComparison]::Ordinal) -and $uo.ListRule -match 'refused') "$($uo.Rule) $($uo.Reason) / $($uo2.Rule) $($uo2.Reason)"

# L18 (FS-R-009 §3): the registered run is locked to v1; v2A on it is refused, never a verdict
$cl = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HOSTDIR 'fs-classify.ps1') -Stage 2a -CollectDir (Join-Path $rd 'collect') -ObserveDir $rd -ListRule v2A)
$clx = $LASTEXITCODE; $clt = $cl -join ' / '
Check 'L18a CLI -ListRule v2A on the real trial (i) collection: refused, exit 64, "rule-version refused for registered run" citing FS-R-009 section 3, no OUTCOME/STAGE-1 line' (
    $clx -eq 64 -and $clt -match 'rule-version refused for registered run' -and $clt -match 'FS-R-009 \\xa73' -and $clt -notmatch 'OUTCOME|STAGE-1|PASS') "exit $clx / $clt"
$lo = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $rj.Kernel -Fsb1 $rrec -Nonce $rj.Nonce -Challenge $rj.Challenge -Collected ([bool]$rj.RecordComplete) -ListRule v2A
Check 'L18b function -ListRule v2A on the real record: INCONCLUSIVE rule 0 "rule-version refused for registered run", no step classes (not a PASS, not rule 8)' (
    $lo.Outcome -ceq 'INCONCLUSIVE' -and $lo.Rule -eq 0 -and $lo.Reason.StartsWith('rule-version refused for registered run', [StringComparison]::Ordinal) -and
    $lo.Reason -match 'FS-R-009' -and @($lo.StepClasses).Count -eq 0) "$($lo.Outcome) $($lo.Rule) $($lo.Reason)"
$lc = $null; try { $null = Resolve-FsS2ListRule 'v2A' $rj.Nonce } catch { $lc = $_.Exception.Message }
Check 'L18c Resolve-FsS2ListRule v2A for the registered nonce throws the refusal; v1 and the default (v1) are allowed' (
    $null -ne $lc -and $lc.StartsWith('rule-version refused for registered run', [StringComparison]::Ordinal) -and
    (Resolve-FsS2ListRule 'v1' $rj.Nonce) -ceq 'v1' -and (Resolve-FsS2ListRule '' $rj.Nonce) -ceq 'v1' -and (Resolve-FsS2ListRule '' ('c' * 16)) -ceq 'v2A') $lc

# ---- (b) qemu 3-line outputs (stage2a evidence)
foreach ($q in @(@('step2.out', 'f737bd66133e456bbd7f2fe9bcef9960f30caced749fffcd51190e843518d71d', 'b2sum'),
                 @('step3.out', '5fe7cba6bbb2ee51067df4ca6be85d50a39c2880fe0630dc2642f8b6268c456c', 'uname'))) {
    [byte[]]$qb = Read-LfBytes "devices\quest3\stage2a\evidence\fixture\$($q[0])"
    $c1 = LClass $qb 'v1'; $c2 = LClass $qb 'v2A'
    Check "L12 qemu 3-line --list $($q[2]) ($($q[0]), SHA-256 as in fixture-transcript.txt): OK under v1 and under v2A" (
        (Get-FsSha256Hex $qb) -ceq $q[1] -and $c1.Class -ceq 'OK' -and $c1.Notes -ceq 'ok' -and $c2.Class -ceq 'OK' -and $c2.Notes -match '3 lines') "v1 $($c1.Notes) / v2A $($c2.Notes)"
}

# ---- (c) qemu 4-line outputs (logged reproduction), unnamed map on both sides of the loader
$ql = @((Get-Content -LiteralPath (Join-Path $ROOT 'relays\FS-A-009-raw\listing-evidence\qemu-raw.log')))
function QRun([string]$hdr) {   # the run's stdout from its cat -A lines (^I = tab, trailing $ = end of line)
    $ix = [Array]::IndexOf($ql, $hdr); $t = ''
    if ($ix -ge 0) { for ($k = $ix + 1; $k -lt $ql.Count -and $ql[$k].StartsWith('^I', [StringComparison]::Ordinal); $k++) { $t += "`t" + $ql[$k].Substring(2).TrimEnd('$') + "`n" } }
    $t
}
function QAddr([string]$line) { [Convert]::ToUInt64(($line -replace '^.*\(0x([0-9a-f]{16})\)$', '$1'), 16) }
foreach ($q in @(@('== B-a72-b2sum run 1/15 cpu=cortex-a72 env=[] prog=b2sum lines=4', 'below'),
                 @('== B-a72-b2sum run 3/15 cpu=cortex-a72 env=[] prog=b2sum lines=4', 'above'),
                 @('== B-a72-uname run 5/15 cpu=cortex-a72 env=[] prog=uname lines=4', 'above'))) {
    $q4 = QRun $q[0]; $ll = @($q4.TrimEnd("`n").Split([char]10))
    $side = if ($ll.Count -eq 4 -and (QAddr $ll[0]) -lt (QAddr $ll[3])) { 'below' } elseif ($ll.Count -eq 4) { 'above' } else { '?' }
    $c1 = LClass (B $q4) 'v1'; $c2 = LClass (B $q4) 'v2A'
    Check ("L13 qemu 4-line, unnamed map {0} the loader ({1}): v1 FAILED, v2A OK" -f $q[1], $q[0].Substring(3, $q[0].IndexOf(' cpu=') - 3)) (
        $ll.Count -eq 4 -and $side -ceq $q[1] -and $ll[0].StartsWith("`t (0x", [StringComparison]::Ordinal) -and
        $c1.Class -ceq 'FAILED' -and $c2.Class -ceq 'OK' -and $c2.Notes -match '4 lines') "side $side; v1 $($c1.Notes) / v2A $($c2.Notes)"
}

# ---- (d) negative cases (from the real output); each FAILS under v2A with the stated reason, and under v1
$R = @($real4Text.TrimEnd("`n").Split([char]10))   # 0 main-map, 1 vdso, 2 libc, 3 loader
$M = $R[0]; $V = $R[1]; $C = $R[2]; $LD = $R[3]
function J([string[]]$l) { (($l | ForEach-Object { "$_`n" }) -join '') }
$neg = @(
    @('duplicate optional line (the same unnamed-map line twice, first)', (J @($M, $M, $V, $C, $LD)), 'not 3 or 4 terminated lines'),
    @('two optional lines (different addresses), first', (J @($M, "`t (0x0000007fb78c0000)", $V, $C, $LD)), 'not 3 or 4 terminated lines'),
    @('extra mapping: 5 lines (an unnamed-map line after the loader)', (J @($M, $V, $C, $LD, "`t (0x0000007fb78c0000)")), 'not 3 or 4 terminated lines'),
    @('extra mapping: 5 lines (an extra named line after the loader)', (J @($M, $V, $C, $LD, "`tlibx.so.1 => /valve/lib/libx.so.1 (0x0000007fb78c0000)")), 'not 3 or 4 terminated lines'),
    @('extra named first line (libx.so.1)', (J @("`tlibx.so.1 (0x0000007fb78d0000)", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('extra named first line with an arrow', (J @("`tb2sum => /valve/bin/b2sum (0x0000007fb78d0000)", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('extra named line last', (J @($V, $C, $LD, "`tlibx.so.1 (0x0000007fb78d0000)")), 'line 2 does not match'),
    @('misplaced optional line: second', (J @($V, $M, $C, $LD)), 'line 2 does not match'),
    @('misplaced optional line: third', (J @($V, $C, $M, $LD)), 'line 2 does not match'),
    @('misplaced optional line: last', (J @($V, $C, $LD, $M)), 'line 2 does not match'),
    @('duplicate address: unnamed map = libc', (J @("`t (0x0000007fb7720000)", $V, $C, $LD)), "equals a required line's address"),
    @('duplicate address: unnamed map = loader', (J @("`t (0x0000007fb78fe000)", $V, $C, $LD)), "equals a required line's address"),
    @('duplicate address: unnamed map = vDSO', (J @("`t (0x0000007fb793b000)", $V, $C, $LD)), "equals a required line's address"),
    @('zero address in the unnamed-map line', (J @("`t (0x0000000000000000)", $V, $C, $LD)), 'unnamed-map address is zero'),
    @('malformed address: upper-case hex', (J @("`t (0x0000007FB78D0000)", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('malformed address: 15 hex digits', (J @("`t (0x000007fb78d0000)", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('malformed address: 17 hex digits', (J @("`t (0x00000007fb78d0000)", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('malformed address: no 0x', (J @("`t (0000007fb78d0000)", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('malformed address in a required line (vDSO, 15 digits)', (J @($M, ($V -replace '0x0000007fb793b000', '0x000007fb793b000'), $C, $LD)), 'line 2 does not match'),
    @('malformed unnamed-map line: two spaces', (J @("`t  (0x0000007fb78d0000)", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('malformed unnamed-map line: no tab', (J @(" (0x0000007fb78d0000)", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('malformed unnamed-map line: trailing space', (J @("$M ", $V, $C, $LD)), 'line 1 is not the unnamed-map line'),
    @('altered path: libc from /usr/lib (4-line form)', (J @($M, $V, ($C -replace '=> /valve/lib/libc', '=> /usr/lib/libc'), $LD)), 'line 3 does not match'),
    @('altered path: loader target /lib (4-line form)', (J @($M, $V, $C, ($LD -replace '=> /valve/lib/ld-linux', '=> /lib/ld-linux'))), 'line 4 does not match'),
    @('altered path: interpreter name /XYZ (4-line form)', (J @($M, $V, $C, ($LD -replace '^\t/lib/ld-linux', "`t/XYZ/ld-linux"))), 'line 4 does not match'),
    @('altered path: libc from /usr/lib (3-line form)', (J @($V, ($C -replace '=> /valve/lib/libc', '=> /usr/lib/libc'), $LD)), 'line 2 does not match'),
    @('missing vDSO line (unnamed map, libc, loader)', (J @($M, $C, $LD)), 'line 1 does not match'),
    @('missing vDSO line (libc, loader)', (J @($C, $LD)), 'not 3 or 4 terminated lines'),
    @('CRLF line ends', ($real4Text -replace "`n", "`r`n"), 'line 2 does not match'),
    @('unterminated output (last line without LF)', ($real4Text.TrimEnd("`n")), 'not 3 or 4 terminated lines'),
    @('unterminated output (3-line form)', ((J @($V, $C, $LD)).TrimEnd("`n")), 'not 3 or 4 terminated lines'),
    @('empty output', '', 'not 3 or 4 terminated lines'),
    @('unnamed-map line alone', (J @($M)), 'not 3 or 4 terminated lines')
)
# positives built from the device output (the ordering condition was removed by FS-R-009 §4)
foreach ($pz in @(@('unnamed map above the loader, below the vDSO', "`t (0x0000007fb7900000)"), @('unnamed map above the vDSO', "`t (0x0000ffffffff0000)"),
                  @('unnamed map at the lowest nonzero address', "`t (0x0000000000000001)"))) {
    $c2 = LClass (B (J @($pz[1], $V, $C, $LD))) 'v2A'
    Check "L14+ v2A OK: $($pz[0])" ($c2.Class -ceq 'OK') $c2.Notes
}
$k = 0
foreach ($n in $neg) {
    $k++
    $c2 = LClass (B $n[1]) 'v2A'; $c1 = LClass (B $n[1]) 'v1'
    Check ("L14.{0:00} v2A FAILED: {1}" -f $k, $n[0]) ($c2.Class -ceq 'FAILED' -and $c2.Notes.Contains($n[2]) -and $c1.Class -ceq 'FAILED') "v2A: $($c2.Notes) / v1: $($c1.Class) $($c1.Notes)"
}

# ---- whole-record (synthetic nonce): v2A changes only step 4, nothing else in §6
$KN2 = 'a1b2c3d4e5f60718'; $KC2 = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'
function LGood([string]$list) { $s = Get-Stage2aGoodSteps -Nonce $KN2 -Chal $KC2; $s[3] = New-SynthStep 4 'list' (B $list) @(); [pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $s } }
$four = "`t (0x0000ffff9a390000)`n" + $L1.GetString((Get-Stage2aGoodSteps -Nonce $KN2 -Chal $KC2)[3]['out'])
$o1 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 (LGood $four) -Nonce $KN2 -Challenge $KC2 -ListRule v1
$o2 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 (LGood $four) -Nonce $KN2 -Challenge $KC2 -ListRule v2A
$o3 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 (LGood $four) -Nonce $KN2 -Challenge $KC2
Check 'L15 synthetic record (new nonce), 4-line list: v1 COMPATIBILITY FAIL rule 6; v2A PASS rule 7; no -ListRule = v2A; each states its rule' (
    $o1.Outcome -ceq 'COMPATIBILITY FAIL' -and $o1.Rule -eq 6 -and $o1.ListRule -match '^list rule v1 ' -and
    $o2.Outcome -ceq 'PASS' -and $o2.Rule -eq 7 -and $o2.ListRule -match '^list rule v2 \(A, amended' -and
    $o3.Outcome -ceq 'PASS' -and $o3.ListRule -ceq $o2.ListRule) "$($o1.Outcome)/$($o2.Outcome)/$($o3.Outcome) [$($o3.ListRule)]"
$s5 = Get-Stage2aGoodSteps -Nonce $KN2 -Chal $KC2; $s5[3] = New-SynthStep 4 'list' (B $four) @(); $s5[4] = New-SynthStep 5 'uname' (B "6.0`n") @()
$o4 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $s5 }) -Nonce $KN2 -Challenge $KC2 -ListRule v2A
Check 'L16 v2A does not mask another step: 4-line list + wrong uname = COMPATIBILITY FAIL, lowest failing step 5' ($o4.Outcome -ceq 'COMPATIBILITY FAIL' -and $o4.Reason -match 'step 5 uname' -and @($o4.Failing).Count -eq 1) $o4.Reason
$s6 = Get-Stage2aGoodSteps -Nonce $KN2 -Chal $KC2; $s6[3] = New-SynthStep 4 'list' (B $four) @() @{ end = 'unreaped'; why = 'none' }
$o5 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $s6 }) -Nonce $KN2 -Challenge $KC2 -ListRule v2A
$s7 = Get-Stage2aGoodSteps -Nonce $KN2 -Chal $KC2; $s7[3] = New-SynthStep 4 'list' (B $four) (B "warning`n")
$o6 = Get-FsStage2aOutcome -Stage1Class PASS -Kernel $script:SynKernel -Fsb1 ([pscustomobject]@{ Ok = $true; Reason = 'valid'; Steps = $s7 }) -Nonce $KN2 -Challenge $KC2 -ListRule v2A
Check 'L17 v2A keeps the other step-4 checks: a TOOL FAULT stays INCONCLUSIVE rule 5; stderr output stays FAILED' ($o5.Outcome -ceq 'INCONCLUSIVE' -and $o5.Rule -eq 5 -and $o6.Outcome -ceq 'COMPATIBILITY FAIL' -and $o6.Reason -match 'stderr') "$($o5.Outcome) $($o5.Rule) / $($o6.Reason)"
