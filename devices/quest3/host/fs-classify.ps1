# FrameShift outcome classifier, stage 2a and stage 3a (Windows PowerShell 5.1).
# Revision 3 (coordinated round): OUTCOMES.md revision 4: stage-2a step 8 `inv` is
# informational (class INFO; no rule reads it); §8 stage 3a (Get-FsStage3aOutcome,
# with an FSP1 stream check that mirrors stage3a/tools/check_stream.py).
# Revision 4 (FS-R-009 §4): the step-4 `list` rule is versioned: v1 (registered) for the
# runs registered under it, amended rule A (v2A) otherwise; every result names the rule applied.
# Implements devices/quest3/common/OUTCOMES.md exactly:
# §3 per-step classes, §4 integrity parses, §5 Valve content checks,
# (revision 2 of this file, adversarial review of da0ad56: no [int] casts of
# record numbers (15-digit errno/sig/code compare as [long]); any internal error
# is INCONCLUSIVE, never a skipped check; device text is escaped for display),
# §6 precedence (first match wins), §7 (a timeout is never inferred from a code).
#
#   . fs-classify.ps1
#   $o = Get-FsStage2aOutcome -Stage1Class PASS -Kernel <FSV1 kernel=> -Fsb1 <Test-Fsb1Record result> `
#            -Nonce <n16> -Challenge <c32> [-Collected $true] [-Pins <objects Path,Sha256>]
#   $o.Outcome   PASS | COMPATIBILITY FAIL | INTEGRITY FAULT | INCONCLUSIVE | <stage-1 class>
#   $o.Rule      the §6 row that matched (1-8, revision-3 numbering); 0 = list-rule version
#                refused before §6 (OUTCOMES rev 5: unknown version, or a non-v1 rule for a v1 run)
#   $o.Reason, $o.StepClasses (id, class, notes), $o.Failing (rule 6: lowest first)
#
#   $o = Get-FsStage3aOutcome -Stage1Class PASS -Fsb1 <Test-Fsb1Record result, exp=stage3a> `
#            -Nonce <n16> -Challenge <c32> [-Collected $true] [-PatternPin <sha256>]
#   $o.Outcome   PASS (machine side) | NO-DISPLAY | DISPLAY FAIL | INTEGRITY FAULT | INCONCLUSIVE | <stage-1 class>
#   A stage-3a PASS is the MACHINE SIDE ONLY: the real success criterion is the PM reading
#   the 8 characters through the lenses (OUTCOMES §8).
#
# CLI (from a collector output directory):
#   fs-classify.ps1 [-Stage 2a|3a] -CollectDir <dir> -Stage1Class <observer OUTCOME>
#   fs-classify.ps1 [-Stage 2a|3a] -CollectDir <dir> -ObserveDir <fs-observe output dir>
#   [-ListRule v1|v2A] (stage 2a only) the step-4 `list` rule version (see "§5 step-4 `list` rule"
#     below). Default: v1 for a run registered under it (trial (i)), else v2A (FS-R-009 §4).
#     The output always names the rule applied. A run registered under v1 is LOCKED to v1
#     (FS-R-009 §3): -ListRule v2A on it is refused (exit 64, no OUTCOME line).
#     (revision 4, fix round 6) the stage-1 class is DERIVED (Get-FsStage1Class): DEVICE_REJECTED
#     from the observer's handoff; PASS when the collector's FSV1 verified (our init ran, the
#     nonce challenge answered); TRANSPORT/SHELL FAILURE when the gadget with this nonce came up
#     but no FSV1 verified; INCONCLUSIVE otherwise, or when the two directories disagree.
# It re-reads capture.raw, checks its SHA-256 against collect.json, and runs
# Test-Fsb1Record itself with exp=stage2a, the stage-2a step list fixed here,
# the image nonce and the challenge sent once.
#
# The separate gates (misc rule, partition/slot/devinfo checks, recovery) are
# never merged into this outcome (OUTCOMES §6 "Separate gates").
param([string]$CollectDir, [string]$Stage1Class, [ValidateSet('2a', '3a', '3b')][string]$Stage = '2a', [string]$ObserveDir = '', [string]$ListRule = '',
      [string]$Readings = '')   # stage 3b only: the PM's per-run, per-eye readings (FSR1 lines; OUTCOMES §9.5)
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'fs-native.ps1')
. (Join-Path $PSScriptRoot '..\common\host\fsb1.ps1')
. (Join-Path $PSScriptRoot 'fs-classify3b.ps1')     # stage 3b (OUTCOMES §9); the 2a/3a rules below are unchanged

$script:S2Steps = @('hash', 'absent', 'diag', 'list', 'uname', 'b2kat', 'b2chal', 'inv')
$script:S2Integ = @('hash', 'absent')
$script:S2Valve = @('diag', 'list', 'uname', 'b2kat', 'b2chal')
$script:S3Steps = @('hash', 'pattern')
$script:S3PatternPin = 'c7f28cc70f05387416c47d48707ab3e20bd3ba2306cf483516e353739519ad2a'   # fs-pattern v0.4 (stage3a/build-image.sh)
$script:S2Absent = @('/etc/ld.so.preload', '/usr', '/lib/libc.so.6', '/lib/ld-linux-aarch64.so.1', '/usr/lib/libc.so.6')
$script:S2Kat = '786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce'
$script:S2L1 = [System.Text.Encoding]::GetEncoding(28591)

function Get-FsS2Pins {   # OUTCOMES §4 pin order: ld-linux, libc, uname, b2sum (T1-pins.json file order)
    $j = Get-Content -Raw (Join-Path $PSScriptRoot '..\stage2a\T1-pins.json') | ConvertFrom-Json
    $p = @(foreach ($f in $j.files) { [pscustomobject]@{ Path = "/valve/$($f.path)"; Sha256 = [string]$f.sha256 } })
    $want = @('/valve/lib/ld-linux-aarch64.so.1', '/valve/lib/libc.so.6', '/valve/bin/uname', '/valve/bin/b2sum')
    if ((@($p | ForEach-Object Path) -join ',') -cne ($want -join ',')) { throw 'T1-pins.json file order is not the OUTCOMES §4 pin order' }
    foreach ($x in $p) { if ($x.Sha256 -cnotmatch '^[0-9a-f]{64}\z') { throw "pin for $($x.Path) is not 64 hex" } }
    $p
}

# Splits decoded bytes into lines. Returns $null if the text is non-empty and
# does not end in '\n' (an unterminated last line), else the list of lines.
function Split-FsS2Lines { param([byte[]]$B)
    if ($null -eq $B -or $B.Length -eq 0) { return ,@() }
    $t = $script:S2L1.GetString($B)
    if (-not $t.EndsWith("`n")) { return $null }
    ,($t.Substring(0, $t.Length - 1).Split([char]10))
}

# §3 TOOL FAULT
function Test-FsS2ToolFault { param([hashtable]$St)
    if (@('refused', 'internal', 'nosup', 'unreaped') -ccontains $St['end']) { return "end=$($St['end'])" }
    if ($St['why'] -cne 'none') { return "why=$($St['why'])" }
    # OUTCOMES rev 3 (S3): a signal our timer did not send (end=signaled with KILL/TERM/INT/HUP: the OOM
    # killer, an operator, a dying session) is a TOOL FAULT, not a compatibility result
    if ($St['end'] -ceq 'signaled' -and @(1, 2, 9, 15) -contains $St['sig']) { return "killed by an outside signal sig=$($St['sig']) (not our timer)" }
    if ($St['end'] -ceq 'exec-failed' -and @(8, 80) -notcontains $St['errno']) { return "exec-failed errno=$($St['errno']) (not ENOEXEC/ELIBBAD)" }
    return $null
}

# §4 hash: returns @{ Class = MEASURED|UNPARSEABLE; Mismatch = bool; Notes }
function Get-FsS2HashClass { param([hashtable]$St, $Pins)
    $u = { param($why) @{ Class = 'UNPARSEABLE'; Mismatch = $false; Notes = $why } }
    if ($St['end'] -cne 'exited') { return (& $u "end=$($St['end'])") }
    if (@(0, 1) -notcontains $St['code'] -or $St['sig'] -ne 0) { return (& $u "code=$($St['code']) sig=$($St['sig'])") }
    if ($St['strays'] -ne 0 -or $St['pipes'] -cne 'eof') { return (& $u "strays=$($St['strays']) pipes=$($St['pipes'])") }
    # interpretation: "no other line may appear" cannot be verified from a truncated capture
    if ($St['out_kept'] -ne $St['out_total'] -or $St['err_kept'] -ne $St['err_total']) { return (& $u 'capture truncated (kept < total)') }
    $out = Split-FsS2Lines $St['out']; $err = Split-FsS2Lines $St['err']
    if ($null -eq $out -or $null -eq $err) { return (& $u 'unterminated line') }
    if (($St['code'] -eq 1) -ne ($err.Count -gt 0)) { return (& $u "code=$($St['code']) with $($err.Count) stderr line(s)") }
    $seen = @{}; $mismatch = New-Object System.Collections.Generic.List[string]; $lastPin = -1
    foreach ($l in $out) {
        if ($l -cnotmatch '^([0-9a-f]{64})  (.+)\z') { return (& $u "stdout line not '<sha256>  <path>': $l") }
        $d = $Matches[1]; $path = $Matches[2]
        $ix = -1; for ($k = 0; $k -lt $Pins.Count; $k++) { if ($Pins[$k].Path -ceq $path) { $ix = $k } }
        if ($ix -lt 0) { return (& $u "unknown path on stdout: $path") }
        if ($seen.ContainsKey($path)) { return (& $u "path twice: $path") }
        if ($ix -le $lastPin) { return (& $u "stdout not in pin order at $path") }
        $seen[$path] = $true; $lastPin = $ix
        if ($d -cne $Pins[$ix].Sha256) { $mismatch.Add("$path digest $d != pin $($Pins[$ix].Sha256)") }
    }
    foreach ($l in $err) {
        $hit = $null
        foreach ($pn in $Pins) { if ($l -cmatch ('^sha256sum: can''t (open|read) ''' + [regex]::Escape($pn.Path) + ''': .+\z')) { $hit = $pn.Path } }
        if ($null -eq $hit) { return (& $u "stderr line not the busybox can't-open/read form: $l") }
        if ($seen.ContainsKey($hit)) { return (& $u "path twice: $hit") }
        $seen[$hit] = $true; $mismatch.Add("$hit cannot be read: $l")
    }
    if ($seen.Count -ne $Pins.Count) { return (& $u "only $($seen.Count) of $($Pins.Count) pinned paths reported") }
    return @{ Class = 'MEASURED'; Mismatch = ($mismatch.Count -gt 0); Notes = $(if ($mismatch.Count) { $mismatch -join '; ' } else { 'all four digests equal the pins' }) }
}

# §4 absent
function Get-FsS2AbsentClass { param([hashtable]$St)
    $u = { param($why) @{ Class = 'UNPARSEABLE'; Mismatch = $false; Notes = $why } }
    if ($St['end'] -cne 'exited' -or $St['code'] -ne 0 -or $St['sig'] -ne 0) { return (& $u "end=$($St['end']) code=$($St['code']) sig=$($St['sig'])") }
    if ($St['strays'] -ne 0 -or $St['pipes'] -cne 'eof') { return (& $u "strays=$($St['strays']) pipes=$($St['pipes'])") }
    if ($St['err_total'] -ne 0) { return (& $u 'stderr not empty') }
    if ($St['out_kept'] -ne $St['out_total']) { return (& $u 'capture truncated (kept < total)') }
    $out = Split-FsS2Lines $St['out']
    if ($null -eq $out) { return (& $u 'unterminated line') }
    $last = -1; $found = New-Object System.Collections.Generic.List[string]
    foreach ($l in $out) {
        $ix = [Array]::IndexOf($script:S2Absent, $l)
        if ($ix -lt 0) { return (& $u "not one of the five listed paths: $l") }
        if ($ix -le $last) { return (& $u "path repeated or out of list order: $l") }
        $last = $ix; $found.Add($l)
    }
    if ($found.Count) { return @{ Class = 'MEASURED'; Mismatch = $true; Notes = 'present: ' + ($found -join ', ') } }
    return @{ Class = 'MEASURED'; Mismatch = $false; Notes = 'none of the five paths exists' }
}

# §5 step-4 `list` rule, VERSIONED (FS-R-009 §4; stage2a/LISTING-RULE-A.md). Every stage-2a
# classification states the rule it applied (result field ListRule; CLI line "Step-4 list rule applied").
#   v1  = the registered rule (T1-PINS §3, FS-A-007): exactly 3 LF-terminated lines, anchored, in order.
#         Applied by default to the runs registered under it ($script:S2ListRuleV1Runs, by nonce), so
#         trial (i) (nonce 93a1501f0b1fb692) re-classifies exactly as registered (FS-R-009 §4).
#   v2A = amended rule A, ADOPTED by FS-R-009 §4; the default for every other run: either the 3 lines
#         of v1, or ONE optional FIRST line `\t (0x<16 hex>)` (glibc 2.39 prints the main program's own,
#         unnamed map when the uninitialised mode_trace_program byte happens to be set;
#         FS-A-009 (private review record)) followed by the same 3 lines. The optional address
#         must be nonzero and distinct from the 3 required lines' addresses. No ordering condition
#         (the qemu log has the unnamed map above the loader in 9 four-line runs). Anything else fails.
# All other step-4 requirements (process end, capture, stderr; §3) are unchanged under both versions.
$script:S2ListRules = [ordered]@{
    'v1'  = 'list rule v1 (registered, T1-PINS §3: exactly 3 lines)'
    'v2A' = 'list rule v2 (A, amended, FS-R-009 §4: optional first unnamed-map line, then the 3 lines)'
}
$script:S2ListRuleDefault = 'v2A'
$script:S2ListRuleV1Runs = @('93a1501f0b1fb692')   # trial (i), Quest 3, 2026-10-09: registered under v1
$script:S2ListRe = @('^\tlinux-vdso\.so\.1 \(0x([0-9a-f]{16})\)\z',
                     '^\tlibc\.so\.6 => /valve/lib/libc\.so\.6 \(0x([0-9a-f]{16})\)\z',
                     '^\t/lib/ld-linux-aarch64\.so\.1 => /valve/lib/ld-linux-aarch64\.so\.1 \(0x([0-9a-f]{16})\)\z')
$script:S2ListMainRe = '^\t \(0x([0-9a-f]{16})\)\z'

# The rule for a run: the explicit one if given (v1 or v2A, case-sensitive), else v1 for a run
# registered under v1, else the adopted default. Two refusals, each its own reason (never a silent v1,
# never a verdict): an unknown rule name, and (FS-R-009 §3) any rule other than v1 for a run
# registered under v1: the registered result of such a run cannot be re-graded.
$script:S2ListUnknown = 'unknown list rule version'
$script:S2ListLocked = 'rule-version refused for registered run'
function Get-FsS2ListRuleRefusal { param([string]$Rule, [string]$Nonce = '')   # $null, or the refusal text
    if ($Rule -and @($script:S2ListRules.Keys) -cnotcontains $Rule) { return "$($script:S2ListUnknown): '$Rule' (v1 or v2A)" }
    if ($Rule -and $Rule -cne 'v1' -and $script:S2ListRuleV1Runs -ccontains $Nonce) {
        return "$($script:S2ListLocked): nonce $Nonce is registered under list rule v1 and may only be classified under v1 (FS-R-009 §3); '$Rule' refused"
    }
    return $null
}
function Resolve-FsS2ListRule { param([string]$Rule, [string]$Nonce = '')
    $why = Get-FsS2ListRuleRefusal $Rule $Nonce
    if ($null -ne $why) { throw $why }
    if (-not $Rule) { $Rule = $(if ($script:S2ListRuleV1Runs -ccontains $Nonce) { 'v1' } else { $script:S2ListRuleDefault }) }
    $Rule
}

# Returns $null when the rule is met, else the reason. v1 reasons are the registered texts.
function Test-FsS2ListContent { param([byte[]]$Out, [string]$Rule)
    if (@($script:S2ListRules.Keys) -cnotcontains $Rule) { throw "unknown list rule '$Rule' (v1 or v2A)" }
    $l = Split-FsS2Lines $Out
    if ($Rule -ceq 'v1') {
        if ($null -eq $l -or $l.Count -ne 3) { return 'not exactly 3 terminated lines' }
        for ($k = 0; $k -lt 3; $k++) { if ($l[$k] -cnotmatch $script:S2ListRe[$k]) { return "line $($k + 1) does not match: $($l[$k])" } }
        return $null
    }
    # v2A (amended)
    if ($null -eq $l -or ($l.Count -ne 3 -and $l.Count -ne 4)) { return 'not 3 or 4 terminated lines (list rule v2 (A))' }
    $off = $l.Count - 3
    $addr = New-Object System.Collections.Generic.List[uint64]
    for ($k = 0; $k -lt 3; $k++) {
        if ($l[$off + $k] -cnotmatch $script:S2ListRe[$k]) { return "line $($off + $k + 1) does not match: $($l[$off + $k])" }
        $addr.Add([Convert]::ToUInt64($Matches[1], 16))
    }
    if ($off -eq 1) {
        if ($l[0] -cnotmatch $script:S2ListMainRe) { return "line 1 is not the unnamed-map line '\t (0x<16 hex>)': $($l[0])" }
        [uint64]$m = [Convert]::ToUInt64($Matches[1], 16)
        if ($m -eq 0) { return 'unnamed-map address is zero' }
        if ($addr -contains $m) { return "unnamed-map address 0x$($Matches[1]) equals a required line's address" }
    }
    return $null
}

# §5 content checks: returns $null when met, else the reason
function Test-FsS2Content { param([hashtable]$St, [string]$Kernel, [string]$Nonce, [string]$Challenge, [string]$ListRule = '')
    $ListRule = Resolve-FsS2ListRule $ListRule $Nonce
    $text = $script:S2L1.GetString([byte[]]$St['out'])
    switch ($St['id']) {
        'diag' {
            $lines = $text.Split([char]10)
            foreach ($need in @('version.version="2.39"', 'version.release="stable"', 'path.system_dirs[0x0]="/usr/lib/"', 'dl_pagesize=0x1000')) {
                if ($lines -cnotcontains $need) { return "missing line $need" }
            }
            foreach ($l in $lines) { if ($l.StartsWith('env[', [StringComparison]::Ordinal)) { return "environment line present: $l" } }
            return $null
        }
        'list' { return (Test-FsS2ListContent ([byte[]]$St['out']) $ListRule) }
        'uname' { if ($text -ceq "$Kernel`n") { return $null }; return "output is not '$Kernel\n'" }
        'b2kat' { if ($text -ceq "$($script:S2Kat)  -`n") { return $null }; return 'not the BLAKE2b-512("") KAT line' }
        'b2chal' {
            $want = (Get-FsBlake2bHex ($script:S2L1.GetBytes("$($Nonce):$Challenge"))) + "  -`n"
            if ($text -ceq $want) { return $null }
            $nl = (Get-FsBlake2bHex ($script:S2L1.GetBytes("$($Nonce):$Challenge`n"))) + "  -`n"
            if ($text -ceq $nl) { return 'newline variant (digest of the challenge with a trailing newline)' }
            return 'challenge digest differs from the host computation'
        }
    }
    return "no content rule for $($St['id'])"
}

# §3 Valve step: OK or FAILED (caller has excluded TOOL FAULT)
function Get-FsS2ValveClass { param([hashtable]$St, [string]$Kernel, [string]$Nonce, [string]$Challenge, [string]$ListRule = '')
    $ListRule = Resolve-FsS2ListRule $ListRule $Nonce
    $why = New-Object System.Collections.Generic.List[string]
    if ($St['end'] -cne 'exited') {
        switch ($St['end']) {
            'signaled'    { $why.Add("signaled sig=$($St['sig'])") }
            'timer-term'  { $why.Add("timer-term (hang) term_ms=$($St['term_ms'])") }
            'timer-kill'  { $why.Add("timer-kill (hang) term_ms=$($St['term_ms']) kill_ms=$($St['kill_ms'])") }
            'exec-failed' { $why.Add("exec-failed errno=$($St['errno'])") }
            default       { $why.Add("end=$($St['end'])") }
        }
    } else {
        if ($St['code'] -ne 0) { $why.Add("exited code=$($St['code'])" + $(if ($St['code'] -eq 143) { ' (an exit status, not a timeout: OUTCOMES §7)' } else { '' })) }
        if ($St['sig'] -ne 0) { $why.Add("sig=$($St['sig'])") }
    }
    if ($St['strays'] -ne 0) { $why.Add("strays=$($St['strays'])") }
    if ($St['pipes'] -cne 'eof') { $why.Add("pipes=$($St['pipes'])") }
    if ($St['out_kept'] -ne $St['out_total']) { $why.Add("output over the cap (total $($St['out_total']), kept $($St['out_kept']))") }
    if ($St['err_total'] -ne 0) { $why.Add("stderr $($St['err_total']) bytes") }
    $c = Test-FsS2Content $St $Kernel $Nonce $Challenge $ListRule
    if ($null -ne $c) { $why.Add("content: $c") }
    if ($why.Count -eq 0) {
        # v1 notes stay byte-identical to the registered output; v2A says which form it accepted
        if ($St['id'] -ceq 'list' -and $ListRule -ceq 'v2A') {
            $ls = Split-FsS2Lines ([byte[]]$St['out']); $n = $ls.Count   # (no @(): the function returns the array as one object)
            return @{ Class = 'OK'; Notes = $(if ($n -eq 4) { 'ok (list rule v2 (A): 4 lines, unnamed-map line accepted)' } else { 'ok (list rule v2 (A): 3 lines)' }) }
        }
        return @{ Class = 'OK'; Notes = 'ok' }
    }
    return @{ Class = 'FAILED'; Notes = ($why -join '; ') }
}

# Step 8 `inv` (informational): what was recorded, as a note. Never a class that a rule reads.
function Get-FsS2InvNote { param([hashtable]$St)
    $t = $script:S2L1.GetString([byte[]]$St['out'])
    $secs = @([regex]::Matches($t, '(?m)^== (\S+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
    $n = "end=$($St['end']) code=$($St['code']) sig=$($St['sig']) why=$($St['why']) out=$($St['out_len'])B err=$($St['err_len'])B"
    if ($secs) { $n += " sections=$secs" } else { $n += ' sections=none' }
    if ($St['end'] -cne 'exited' -or $St['code'] -ne 0 -or $St['why'] -cne 'none') { $n += ' (noted only: informational, OUTCOMES §2)' }
    $n
}

# ---------------------------------------------------------------- stage 3a ----
# CRC-32 (IEEE 802.3, as zlib crc32), for the FSP1 `crc=` field.
$script:FspCrcTable = $null
function Get-FsCrc32 { param([byte[]]$B)
    if ($null -eq $script:FspCrcTable) {
        $script:FspCrcTable = New-Object 'uint32[]' 256
        for ($n = 0; $n -lt 256; $n++) {
            [uint32]$c = $n
            for ($k = 0; $k -lt 8; $k++) { if ($c -band 1) { $c = [uint32]([uint32]3988292384 -bxor ($c -shr 1)) } else { $c = [uint32]($c -shr 1) } }
            $script:FspCrcTable[$n] = $c
        }
    }
    [uint32]$c = [uint32]4294967295
    foreach ($x in $B) { $c = [uint32]($script:FspCrcTable[($c -bxor $x) -band 0xFF] -bxor ($c -shr 8)) }
    [uint32]($c -bxor [uint32]4294967295)
}

# FSP1 stream check: the stage3a/tools/check_stream.py rules (grammar, len, crc, seq, one
# nonce, eos right after exit with records = count and dropped = 0). Returns
# @{ Status = COMPLETE|INCOMPLETE|INVALID|EMPTY; Why; Records = list of @{ Step; Rc; Kv; Nonce } }
$script:FspRec = '^FSP1 nonce=([0-9a-f]{8}|none) seq=(0|[1-9][0-9]*) step=([a-z_]+) rc=(-?[0-9]+)((?: [a-z_0-9]+=[A-Za-z0-9_./%-]+)*) len=(0|[1-9][0-9]*) crc=([0-9a-f]{8}) END\z'
function Test-FsFsp1Stream { param([byte[]]$B)
    $t = $script:S2L1.GetString($B)
    $lines = $t.Split([char]10)
    $tail = $lines[$lines.Count - 1]
    $body = @(); if ($lines.Count -gt 1) { $body = $lines[0..($lines.Count - 2)] }
    $torn = ($tail -ne '' -and -not $tail.StartsWith('# '))
    $recs = @($body | Where-Object { -not $_.StartsWith('# ') })
    if ($recs.Count -eq 0 -and -not $torn) { return @{ Status = 'EMPTY'; Why = 'no records'; Records = @() } }
    $out = New-Object System.Collections.Generic.List[object]
    $nonce = $null; $eos = $false
    for ($i = 0; $i -lt $recs.Count; $i++) {
        $l = $recs[$i]
        if ($eos) { return @{ Status = 'INVALID'; Why = "record after eos at $i"; Records = $out.ToArray() } }
        if ($l -cnotmatch $script:FspRec) { return @{ Status = 'INVALID'; Why = "malformed record $i"; Records = $out.ToArray() } }
        $m = $Matches
        $bodyText = $l.Substring(0, $l.LastIndexOf(' len=', [StringComparison]::Ordinal))
        if ([long]$m[6] -ne $bodyText.Length) { return @{ Status = 'INVALID'; Why = "len mismatch at seq $($m[2])"; Records = $out.ToArray() } }
        if ((Get-FsCrc32 ($script:S2L1.GetBytes($bodyText))) -ne [Convert]::ToUInt32($m[7], 16)) { return @{ Status = 'INVALID'; Why = "crc mismatch at seq $($m[2])"; Records = $out.ToArray() } }
        if ([long]$m[2] -ne $i) { return @{ Status = 'INVALID'; Why = "seq gap/duplicate at $i"; Records = $out.ToArray() } }
        if ($null -eq $nonce) { $nonce = $m[1] } elseif ($m[1] -cne $nonce) { return @{ Status = 'INVALID'; Why = "nonce changed at seq $i"; Records = $out.ToArray() } }
        $kv = @{}; foreach ($x in [regex]::Matches($m[5], ' ([a-z_0-9]+)=([A-Za-z0-9_./%-]+)')) { $kv[$x.Groups[1].Value] = $x.Groups[2].Value }
        $out.Add(@{ Step = $m[3]; Rc = [long]$m[4]; Kv = $kv; Nonce = $m[1] })
        if ($m[3] -ceq 'eos') {
            if ($i -eq 0 -or $out[$i - 1].Step -cne 'exit') { return @{ Status = 'INVALID'; Why = 'eos not preceded by exit'; Records = $out.ToArray() } }
            if ($kv['records'] -cne [string]($i + 1)) { return @{ Status = 'INVALID'; Why = "eos records=$($kv['records']) but $($i + 1) records"; Records = $out.ToArray() } }
            if ($kv['dropped'] -cne '0') { return @{ Status = 'INVALID'; Why = "eos reports dropped=$($kv['dropped'])"; Records = $out.ToArray() } }
            $eos = $true
        }
    }
    if ($torn) { return @{ Status = 'INCOMPLETE'; Why = 'torn last line'; Records = $out.ToArray() } }
    if (-not $eos) { return @{ Status = 'INCOMPLETE'; Why = "no eos after $($recs.Count) records"; Records = $out.ToArray() } }
    return @{ Status = 'COMPLETE'; Why = "$($recs.Count) records"; Records = $out.ToArray() }
}

# OUTCOMES §8 hash parse: MEASURED (Mismatch true/false) or UNPARSEABLE
function Get-FsS3HashClass { param([hashtable]$St, [string]$Pin)
    $u = { param($why) @{ Class = 'UNPARSEABLE'; Mismatch = $false; Notes = $why } }
    if ($St['end'] -cne 'exited' -or $St['sig'] -ne 0) { return (& $u "end=$($St['end']) sig=$($St['sig'])") }
    if ($St['strays'] -ne 0 -or $St['pipes'] -cne 'eof') { return (& $u "strays=$($St['strays']) pipes=$($St['pipes'])") }
    if ($St['out_kept'] -ne $St['out_total'] -or $St['err_kept'] -ne $St['err_total']) { return (& $u 'capture truncated (kept < total)') }
    $o = $script:S2L1.GetString([byte[]]$St['out']); $e = $script:S2L1.GetString([byte[]]$St['err'])
    if ($St['code'] -eq 0 -and $e -eq '' -and $o -cmatch '^([0-9a-f]{64})  /bin/fs-pattern\n\z') {
        if ($Matches[1] -ceq $Pin) { return @{ Class = 'MEASURED'; Mismatch = $false; Notes = 'fs-pattern digest equals the pin' } }
        return @{ Class = 'MEASURED'; Mismatch = $true; Notes = "fs-pattern digest $($Matches[1]) != pin $Pin" }
    }
    if ($St['code'] -eq 1 -and $o -eq '' -and $e -cmatch "^sha256sum: can't (open|read) '/bin/fs-pattern': [^\n]+\n\z") {
        return @{ Class = 'MEASURED'; Mismatch = $true; Notes = "fs-pattern cannot be read: $($e.TrimEnd("`n"))" }
    }
    return (& $u "not the exact sha256sum form (code=$($St['code']))")
}

function Get-FsStage3aOutcomeCore {
    param([Parameter(Mandatory)][string]$Stage1Class, $Fsb1, [string]$Nonce, [string]$Challenge, [bool]$Collected = $true, [string]$PatternPin = '')
    if (-not $PatternPin) { $PatternPin = $script:S3PatternPin }
    $o = [ordered]@{ Outcome = $null; Rule = 0; Reason = ''; StepClasses = @(); Fsp1 = $null; Failing = @() }
    $fin = { param($out, $rule, $why) $o.Outcome = $out; $o.Rule = $rule; $o.Reason = $why; [pscustomobject]$o }
    $scope = ' [machine side only: the stage-3a result is the PM reading the 8 characters through the lenses on both eyes]'
    if ($Stage1Class -cne 'PASS') { return (& $fin $Stage1Class 1 'stage 1 did not PASS; any FSB1 text is data only') }
    if ($null -eq $Fsb1) { return (& $fin 'INCONCLUSIVE' 2 'no FSB1 record') }
    if (-not $Collected) { return (& $fin 'INCONCLUSIVE' 2 'record not complete by the host collection deadline') }
    if (-not $Fsb1.Ok) { return (& $fin 'INCONCLUSIVE' 2 "FSB1 rejected: $($Fsb1.Reason)") }
    $steps = @($Fsb1.Steps)
    if ((@($steps | ForEach-Object { $_['id'] }) -join ',') -cne ($script:S3Steps -join ',')) { return (& $fin 'INCONCLUSIVE' 2 'decoded steps are not the stage-3a list') }
    if ($Nonce -cnotmatch '^[0-9a-f]{16}\z' -or $Challenge -cnotmatch '^[0-9a-f]{32}\z') { return (& $fin 'INCONCLUSIVE' 2 'nonce/challenge missing') }
    $h = $steps[0]; $p = $steps[1]
    $cls = New-Object System.Collections.Generic.List[object]
    $tfh = Test-FsS2ToolFault $h
    $hc = if ($null -ne $tfh) { @{ Class = 'TOOL FAULT'; Mismatch = $false; Notes = $tfh } } else { Get-FsS3HashClass $h $PatternPin }
    $cls.Add([pscustomobject]@{ I = 1; Id = 'hash'; Class = $hc.Class; Mismatch = $hc.Mismatch; Notes = $hc.Notes })
    $tfp = Test-FsS2ToolFault $p
    $cls.Add([pscustomobject]@{ I = 2; Id = 'pattern'; Class = $(if ($null -ne $tfp) { 'TOOL FAULT' } else { "end=$($p['end'])" }); Mismatch = $false; Notes = $(if ($null -ne $tfp) { $tfp } else { "code=$($p['code']) sig=$($p['sig']) errno=$($p['errno'])" }) })
    $o.StepClasses = $cls.ToArray()
    # rule 3, 4
    if ($hc.Class -ceq 'MEASURED' -and $hc.Mismatch) { return (& $fin 'INTEGRITY FAULT' 3 "hash: $($hc.Notes)") }
    if ($hc.Class -cne 'MEASURED') { return (& $fin 'INCONCLUSIVE' 4 "integrity unmeasured: hash $($hc.Class) ($($hc.Notes))") }
    # rule 5
    if ($null -ne $tfp) { return (& $fin 'INCONCLUSIVE' 5 "our side failed in the pattern step: $tfp") }
    # rule 6
    switch -CaseSensitive ($p['end']) {
        'timer-term'  { return (& $fin 'DISPLAY FAIL' 6 "pattern hung: timer-term term_ms=$($p['term_ms'])") }
        'timer-kill'  { return (& $fin 'DISPLAY FAIL' 6 "pattern hung: timer-kill term_ms=$($p['term_ms']) kill_ms=$($p['kill_ms'])") }
        'signaled'    { return (& $fin 'DISPLAY FAIL' 6 ("pattern ended by signal $($p['sig'])" + $(if ($p['sig'] -eq 14) { ' (its own SIGALRM backstop: a stall)' } else { '' }))) }
        'exec-failed' { return (& $fin 'DISPLAY FAIL' 6 "pattern not runnable: exec-failed errno=$($p['errno'])") }
    }
    if ($p['end'] -cne 'exited') { return (& $fin 'INCONCLUSIVE' 11 "pattern end=$($p['end'])") }
    # rule 7: a sound FSP1 stream
    $fs = Test-FsFsp1Stream ([byte[]]$p['out'])
    $o.Fsp1 = "$($fs.Status) ($($fs.Why))"
    $bad = $null
    if ($fs.Status -cne 'COMPLETE') { $bad = "FSP1 stream $($fs.Status): $($fs.Why)" }
    elseif ($p['out_kept'] -ne $p['out_total']) { $bad = 'FSP1 capture truncated (kept < total)' }
    elseif ($p['err_total'] -ne 0) { $bad = "fs-pattern wrote $($p['err_total']) bytes to stderr" }
    else {
        $want8 = $Challenge.Substring(0, 8)
        $wrong = @($fs.Records | Where-Object { $_.Nonce -cne $want8 })
        $ex = @($fs.Records | Where-Object { $_.Step -ceq 'exit' })
        if ($wrong.Count) { $bad = "FSP1 nonce $($wrong[0].Nonce) is not chal[0:8] $want8" }
        elseif ($ex.Count -ne 1 -or $ex[0].Kv['code'] -cne [string]$p['code']) { $bad = "FSP1 exit code does not equal the process exit code $($p['code'])" }
    }
    if ($bad) { return (& $fin 'INCONCLUSIVE' 7 "evidence unreadable: $bad") }
    $recs = $fs.Records
    $code = [long]$p['code']
    $reasons = @{ 10 = 'no device'; 11 = 'not a DRM node'; 12 = 'driver is not msm_drm'; 20 = 'no connected connector'; 21 = 'atomic/planes/properties unusable';
                  30 = 'mode refused by the policy'; 40 = 'buffer/framebuffer failed'; 50 = 'every TEST_ONLY attempt rejected' }
    if ($reasons.ContainsKey([int]$code)) { return (& $fin 'NO-DISPLAY' 8 "fs-pattern exit $code ($($reasons[[int]$code])): no real commit was made") }
    if ($code -eq 60) { return (& $fin 'DISPLAY FAIL' 9 'fs-pattern exit 60: the real commit failed') }
    if ($code -eq 1) { return (& $fin 'DISPLAY FAIL' 9 'fs-pattern exit 1: internal error during the hold') }
    if ($code -eq 0) {
        $cm = @($recs | Where-Object { $_.Step -ceq 'commit' })
        $he = @($recs | Where-Object { $_.Step -ceq 'hold_end' })
        $ex = @($recs | Where-Object { $_.Step -ceq 'exit' })[0]
        $ok = ($cm.Count -eq 1 -and $cm[0].Rc -eq 0 -and $he.Count -eq 1 -and $he[0].Rc -eq 0 -and $he[0].Kv['reason'] -ceq 'deadline' -and
               $ex.Rc -eq 0 -and $ex.Kv['code'] -ceq '0' -and $ex.Kv['reason'] -ceq 'held_to_deadline' -and $ex.Kv['shown'] -ceq '1')
        if ($ok) { return (& $fin 'PASS (machine side)' 10 ("one frame committed and held to its deadline (held_ms=$($he[0].Kv['held_ms']))" + $scope)) }
        return (& $fin 'INCONCLUSIVE' 11 'exit 0 without commit rc=0, hold_end reason=deadline and exit shown=1')
    }
    return (& $fin 'INCONCLUSIVE' 11 "fs-pattern exit $code (usage/stdout refusal, outside stop signal, or unknown)")
}

function Get-FsStage3aOutcome {
    param([Parameter(Mandatory)][string]$Stage1Class, $Fsb1, [string]$Nonce, [string]$Challenge, [bool]$Collected = $true, [string]$PatternPin = '')
    $ErrorActionPreference = 'Stop'
    try { $o = Get-FsStage3aOutcomeCore @PSBoundParameters }
    catch { return [pscustomobject]@{ Outcome = 'INCONCLUSIVE'; Rule = 11; Reason = 'classifier error: ' + (ConvertTo-FsPrintable $_.Exception.Message); StepClasses = @(); Fsp1 = $null; Failing = @() } }
    $o.Reason = ConvertTo-FsPrintable $o.Reason
    foreach ($c in @($o.StepClasses)) { $c.Notes = ConvertTo-FsPrintable $c.Notes }
    $o
}

# Stage-1 class for a stage-2a/3a attempt (fix round 6): fs-observe.ps1 boots and watches,
# the collector verifies. Same ladder as stage1/fs-proto.ps1 Get-FsOutcome.
function Get-FsStage1Class { param($Observe, $Collect)
    if ($null -eq $Observe -or $null -eq $Collect) { return [pscustomobject]@{ Class = 'INCONCLUSIVE'; Why = 'observer or collector result missing' } }
    if ([string]$Observe.Nonce -cne [string]$Collect.Nonce) { return [pscustomobject]@{ Class = 'INCONCLUSIVE'; Why = "observer nonce $($Observe.Nonce) != collector nonce $($Collect.Nonce)" } }
    if ([string]$Observe.Stage -cne [string]$Collect.Stage) { return [pscustomobject]@{ Class = 'INCONCLUSIVE'; Why = "observer stage $($Observe.Stage) != collector stage $($Collect.Stage)" } }
    if ($Observe.HandoffClass -ceq 'DEVICE_REJECTED') { return [pscustomobject]@{ Class = 'DEVICE_REJECTED'; Why = 'fastboot boot was refused by the device' } }
    if ($Collect.Verified) { return [pscustomobject]@{ Class = 'PASS'; Why = 'the collector verified FSV1 (nonce challenge answered by our init)' } }
    if ($Observe.GadgetSeen) { return [pscustomobject]@{ Class = 'TRANSPORT/SHELL FAILURE'; Why = 'the FS-<nonce> gadget enumerated but no FSV1 verified' } }
    return [pscustomobject]@{ Class = 'INCONCLUSIVE'; Why = 'no gadget with this nonce and no verified FSV1' }
}

function Get-FsStage2aOutcomeCore {
    param([Parameter(Mandatory)][string]$Stage1Class, [string]$Kernel, $Fsb1, [string]$Nonce, [string]$Challenge,
          [bool]$Collected = $true, $Pins = $null, [string]$ListRule = '')
    $ListRule = Resolve-FsS2ListRule $ListRule $Nonce   # an unknown rule name throws: INCONCLUSIVE, never a silent v1
    if ($null -eq $Pins) { $Pins = Get-FsS2Pins }
    $o = [ordered]@{ Outcome = $null; Rule = 0; Reason = ''; StepClasses = @(); Failing = @(); ListRule = $script:S2ListRules[$ListRule] }
    $fin = { param($out, $rule, $why) $o.Outcome = $out; $o.Rule = $rule; $o.Reason = $why; [pscustomobject]$o }
    # rule 1
    if ($Stage1Class -cne 'PASS') { return (& $fin $Stage1Class 1 'stage 1 did not PASS; any FSB1 text is data only') }
    # rule 2
    if ($null -eq $Fsb1) { return (& $fin 'INCONCLUSIVE' 2 'no FSB1 record') }
    if (-not $Collected) { return (& $fin 'INCONCLUSIVE' 2 'record not complete by the host collection deadline') }
    if (-not $Fsb1.Ok) { return (& $fin 'INCONCLUSIVE' 2 "FSB1 rejected: $($Fsb1.Reason)") }
    $steps = @($Fsb1.Steps)
    if ((@($steps | ForEach-Object { $_['id'] }) -join ',') -cne ($script:S2Steps -join ',')) {
        return (& $fin 'INCONCLUSIVE' 2 'decoded steps are not the stage-2a list (decoder called with other parameters)')
    }
    if ($Kernel -cnotmatch '^[!-~]{1,64}\z') { return (& $fin 'INCONCLUSIVE' 2 'no verified FSV1 kernel release') }
    if ($Nonce -cnotmatch '^[0-9a-f]{16}\z' -or $Challenge -cnotmatch '^[0-9a-f]{32}\z') { return (& $fin 'INCONCLUSIVE' 2 'nonce/challenge missing') }

    # §3/§4/§5 per-step classes
    $cls = New-Object System.Collections.Generic.List[object]
    foreach ($st in $steps) {
        if ($st['id'] -ceq 'inv') {   # OUTCOMES rev 4: informational; noted, never escalated, never read by a rule
            $cls.Add([pscustomobject]@{ I = [long]$st['i']; Id = 'inv'; Class = 'INFO'; Mismatch = $false; Notes = (Get-FsS2InvNote $st) }); continue
        }
        $tf = Test-FsS2ToolFault $st
        if ($null -ne $tf) { $cls.Add([pscustomobject]@{ I = [long]$st['i']; Id = $st['id']; Class = 'TOOL FAULT'; Mismatch = $false; Notes = $tf }); continue }
        if ($st['id'] -ceq 'hash' -or $st['id'] -ceq 'absent') {
            $r = if ($st['id'] -ceq 'hash') { Get-FsS2HashClass $st $Pins } else { Get-FsS2AbsentClass $st }
            $cls.Add([pscustomobject]@{ I = [long]$st['i']; Id = $st['id']; Class = $r.Class; Mismatch = $r.Mismatch; Notes = $r.Notes })
        } else {
            $r = Get-FsS2ValveClass $st $Kernel $Nonce $Challenge $ListRule
            $cls.Add([pscustomobject]@{ I = [long]$st['i']; Id = $st['id']; Class = $r.Class; Mismatch = $false; Notes = $r.Notes })
        }
    }
    $o.StepClasses = $cls.ToArray()
    $integ = @($cls | Where-Object { $script:S2Integ -ccontains $_.Id }); $valve = @($cls | Where-Object { $script:S2Valve -ccontains $_.Id })
    $failing = @($valve | Where-Object { $_.Class -ceq 'FAILED' } | Sort-Object I)
    $o.Failing = @($failing | ForEach-Object { "$($_.I) $($_.Id): $($_.Notes)" })
    # rule 3 (rev 3): an integrity step that MEASURED a mismatch, even if the other one is a TOOL FAULT or
    # UNPARSEABLE (a step that did not work measures nothing, so it can never produce rule 3)
    $r3 = @($integ | Where-Object { $_.Class -ceq 'MEASURED' -and $_.Mismatch })
    if ($r3.Count) {
        $other = @($integ | Where-Object { $_.Class -cne 'MEASURED' } | ForEach-Object { "$($_.Id) $($_.Class) ($($_.Notes))" })
        return (& $fin 'INTEGRITY FAULT' 3 ('image or build fault, not a compatibility result: ' + (($r3 | ForEach-Object { "$($_.Id): $($_.Notes)" }) -join '; ') +
            $(if ($other.Count) { '; other integrity step unmeasured: ' + ($other -join '; ') } else { '' })))
    }
    # rule 4: integrity unmeasured
    $r4 = @($integ | Where-Object { $_.Class -ceq 'TOOL FAULT' -or $_.Class -ceq 'UNPARSEABLE' })
    if ($r4.Count) { return (& $fin 'INCONCLUSIVE' 4 ('integrity unmeasured: ' + (($r4 | ForEach-Object { "$($_.Id) $($_.Class) ($($_.Notes))" }) -join '; '))) }
    # rule 5
    $r5 = @($valve | Where-Object { $_.Class -ceq 'TOOL FAULT' })
    if ($r5.Count) { return (& $fin 'INCONCLUSIVE' 5 ('our side failed during the Valve steps: ' + (($r5 | ForEach-Object { "$($_.Id) ($($_.Notes))" }) -join '; '))) }
    # rule 6
    if ($failing.Count) { return (& $fin 'COMPATIBILITY FAIL' 6 "lowest failing step $($failing[0].I) $($failing[0].Id): $($failing[0].Notes)") }
    # rule 7
    $shown = @($integ | Where-Object { $_.Class -ceq 'MEASURED' -and -not $_.Mismatch }).Count -eq 2
    $allOk = @($valve | Where-Object { $_.Class -ceq 'OK' }).Count -eq 5
    if ($shown -and $allOk) { return (& $fin 'PASS' 7 'integrity shown by hash and absent; every Valve step OK') }
    # rule 8
    return (& $fin 'INCONCLUSIVE' 8 'catch-all (not reachable if §3-§4 are implemented as written)')
}

# Wrapper: errors stop (no statement-level continue), any error is INCONCLUSIVE,
# and every text field that can carry device bytes is escaped.
function Get-FsStage2aOutcome {
    param([Parameter(Mandatory)][string]$Stage1Class, [string]$Kernel, $Fsb1, [string]$Nonce, [string]$Challenge,
          [bool]$Collected = $true, $Pins = $null, [string]$ListRule = '')
    $ErrorActionPreference = 'Stop'
    # rule-version refusals (OUTCOMES rev 5): checked before any step is read; INCONCLUSIVE with rule 0
    # ("refused before §6"), never a verdict and never rule 8's catch-all
    $lrWhy = Get-FsS2ListRuleRefusal $ListRule $Nonce
    if ($null -ne $lrWhy) {
        return [pscustomobject]@{ Outcome = 'INCONCLUSIVE'; Rule = 0; Reason = (ConvertTo-FsPrintable $lrWhy); StepClasses = @(); Failing = @()
                                  ListRule = (ConvertTo-FsPrintable "requested: '$ListRule' (refused, not applied)") }
    }
    try { $o = Get-FsStage2aOutcomeCore @PSBoundParameters }
    catch {
        return [pscustomobject]@{ Outcome = 'INCONCLUSIVE'; Rule = 8; Reason = 'classifier error: ' + (ConvertTo-FsPrintable $_.Exception.Message); StepClasses = @(); Failing = @()
                                  ListRule = (ConvertTo-FsPrintable "requested: '$ListRule' (not applied)") }
    }
    $o.Reason = ConvertTo-FsPrintable $o.Reason
    foreach ($c in @($o.StepClasses)) { $c.Notes = ConvertTo-FsPrintable $c.Notes }
    $o.Failing = @(@($o.Failing) | ForEach-Object { ConvertTo-FsPrintable $_ })
    $o
}

if ($MyInvocation.InvocationName -eq '.') { return }
# Exit: 10 PASS (stage 3a: PASS, machine side), 11 COMPATIBILITY FAIL, 12 INTEGRITY FAULT, 13 stage 1 not PASS,
#       14 INCONCLUSIVE, 15 NO-DISPLAY (3a, 3b), 16 DISPLAY FAIL (3a, 3b), 17 PRECONDITION UNMET (3b), 18 RUN 1 ONLY (3b),
#       64 usage, 70 internal error (no verdict code is 0, 1 or 2: a crash can never read as a verdict)
$ErrorActionPreference = 'Stop'
try {
    if (-not $CollectDir -or (-not $Stage1Class -and -not $ObserveDir) -or ($Stage1Class -and $ObserveDir)) {
        Write-Output 'usage: fs-classify.ps1 [-Stage 2a|3a|3b] -CollectDir <fs-collect output dir> (-Stage1Class <PASS|DEVICE_REJECTED|...> | -ObserveDir <fs-observe output dir>) [-ListRule v1|v2A]'; exit 64 }
    if ($Readings -and $Stage -cne '3b') { Write-Output 'usage: -Readings is for stage 3b only'; exit 64 }
    if ($ListRule -and ($Stage -ceq '3a' -or $Stage -ceq '3b' -or @($script:S2ListRules.Keys) -cnotcontains $ListRule)) {
        Write-Output (ConvertTo-FsPrintable "usage: -ListRule is v1 or v2A, stage 2a only (got '$ListRule' for stage $Stage)"); exit 64 }
    try {
        $j = Get-Content -Raw -ErrorAction Stop (Join-Path $CollectDir 'collect.json') | ConvertFrom-Json
        [byte[]]$raw = [IO.File]::ReadAllBytes((Join-Path $CollectDir 'capture.raw'))
    } catch { Write-Output (ConvertTo-FsPrintable "OUTCOME: INCONCLUSIVE (cannot read the collection: $($_.Exception.Message))"); exit 14 }
    if ((Get-FsSha256Hex $raw) -cne $j.Capture.Sha256) { Write-Output 'OUTCOME: INCONCLUSIVE (capture.raw does not match the hash recorded by the collector)'; exit 14 }
    # FS-R-009 §3: a run registered under list rule v1 is never classified under another rule (usage, no OUTCOME)
    if ($ListRule) { $lrWhy = Get-FsS2ListRuleRefusal $ListRule ([string]$j.Nonce); if ($null -ne $lrWhy) { Write-Output (ConvertTo-FsPrintable "usage: $lrWhy"); exit 64 } }
    if ($ObserveDir) {
        try { $ob = Get-Content -Raw -ErrorAction Stop (Join-Path $ObserveDir 'observe.json') | ConvertFrom-Json }
        catch { Write-Output (ConvertTo-FsPrintable "OUTCOME: INCONCLUSIVE (cannot read observe.json: $($_.Exception.Message))"); exit 14 }
        $s1 = Get-FsStage1Class -Observe $ob -Collect $j
        Write-Output (ConvertTo-FsPrintable "STAGE-1 CLASS: $($s1.Class) (derived: $($s1.Why))")
        $Stage1Class = $s1.Class
    }
    $jStage = if ($j.PSObject.Properties['Stage'] -and $j.Stage) { [string]$j.Stage } else { '2a' }
    if ($jStage -cne $Stage) { Write-Output "OUTCOME: INCONCLUSIVE (the collection is stage $jStage; classifier asked for stage $Stage)"; exit 14 }
    $fsb = $null
    if ($j.ValveSent -and $j.Challenge -cmatch '^[0-9a-f]{32}\z' -and $j.Nonce -cmatch '^[0-9a-f]{16}\z') {
        if ($Stage -ceq '3a') { $fsb = Test-Fsb1Record -Bytes $raw -Exp 'stage3a' -Nonce $j.Nonce -Challenge $j.Challenge -Steps $script:S3Steps }
        elseif ($Stage -ceq '3b') { $fsb = Test-Fsb1Record -Bytes $raw -Exp 'stage3b' -Nonce $j.Nonce -Challenge $j.Challenge -Steps $script:S3bSteps }
        else { $fsb = Test-Fsb1Record -Bytes $raw -Exp 'stage2a' -Nonce $j.Nonce -Challenge $j.Challenge -Steps $script:S2Steps }
    }
    $kern = if ($j.Verified) { [string]$j.Kernel } else { '' }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Stage -ceq '3b') {
        $rl = $null
        $rref = if ($j.PSObject.Properties['RunnerRefusal'] -and $j.RunnerRefusal) { [string]$j.RunnerRefusal } else { '' }
        if ($Readings) { try { $rl = [IO.File]::ReadAllLines($Readings) } catch { $rl = @('unreadable readings file') } }
        $o = Get-FsStage3bOutcome -Stage1Class $Stage1Class -Fsb1 $fsb -Nonce $j.Nonce -Challenge $j.Challenge -Collected ([bool]$j.RecordComplete) -Readings $rl -RunnerRefusal $rref
        if ($rref) { $lines.Add("RUNNER REFUSAL: $rref (the runner printed this instead of a record)") }
        $lines.Add("OUTCOME: $($o.Outcome)   (OUTCOMES §9 rule $($o.Rule)) $($o.Reason)")
        foreach ($c in $o.StepClasses) { $lines.Add(("  step {0} {1,-8} {2,-11} {3}" -f $c.I, $c.Id, $c.Class, $c.Notes)) }
        if ($o.Brightness) { $lines.Add("  brightness: $($o.Brightness)") }
        if ($null -ne $o.PauseMs) { $lines.Add("  pause (run 1 close -> run 2 commit, FSP1 monotonic): $($o.PauseMs) ms") }
        $lines.Add("OPTICAL: $($o.Optical)   (OUTCOMES §9.5) $($o.OpticalReason)")
        foreach ($lb in @($o.Labels)) { $lines.Add("LABEL: $lb") }
        $lines.Add("REGISTERED: $($o.Registered)")
        $lines.Add('A machine-side PASS is not the stage result: the stage passes only with all 8 characters read correctly in EACH eye in one committed run (OUTCOMES §9.5).')
        $lines.Add('Separate gates, not part of this outcome: misc rule (fs-miscrule.ps1), partition/slot/devinfo checks (<withheld document>), recovery, temperature.')
        foreach ($l in $lines) { Write-Output (ConvertTo-FsPrintable $l) }
        $code = switch ($o.Outcome) { 'PASS (machine side)' { 10 } 'INTEGRITY FAULT' { 12 } 'INCONCLUSIVE' { 14 } 'NO-DISPLAY' { 15 } 'DISPLAY FAIL' { 16 } 'PRECONDITION UNMET: CRTC ACTIVE' { 17 } 'RUN 1 ONLY' { 18 } default { 13 } }
        exit $code
    }
    if ($Stage -ceq '3a') {
        $o = Get-FsStage3aOutcome -Stage1Class $Stage1Class -Fsb1 $fsb -Nonce $j.Nonce -Challenge $j.Challenge -Collected ([bool]$j.RecordComplete)
        $lines.Add("OUTCOME: $($o.Outcome)   (OUTCOMES §8 rule $($o.Rule)) $($o.Reason)")
        foreach ($c in $o.StepClasses) { $lines.Add(("  step {0} {1,-7} {2,-11} {3}" -f $c.I, $c.Id, $c.Class, $c.Notes)) }
        if ($o.Fsp1) { $lines.Add("  FSP1 stream: $($o.Fsp1)") }
        $lines.Add('A stage-3a PASS is the machine side only: the result is the PM reading the 8 characters through the lenses (OUTCOMES §8).')
        $lines.Add('Separate gates, not part of this outcome: misc rule (fs-miscrule.ps1), partition/slot/devinfo checks (<withheld document>), recovery.')
        foreach ($l in $lines) { Write-Output (ConvertTo-FsPrintable $l) }
        $code = switch ($o.Outcome) { 'PASS (machine side)' { 10 } 'INTEGRITY FAULT' { 12 } 'INCONCLUSIVE' { 14 } 'NO-DISPLAY' { 15 } 'DISPLAY FAIL' { 16 } default { 13 } }
        exit $code
    }
    $o = Get-FsStage2aOutcome -Stage1Class $Stage1Class -Kernel $kern -Fsb1 $fsb -Nonce $j.Nonce -Challenge $j.Challenge -Collected ([bool]$j.RecordComplete) -ListRule $ListRule
    $lines.Add("OUTCOME: $($o.Outcome)   (OUTCOMES §6 rule $($o.Rule)) $($o.Reason)")
    foreach ($c in $o.StepClasses) { $lines.Add(("  step {0} {1,-7} {2,-11} {3}" -f $c.I, $c.Id, $c.Class, $c.Notes)) }
    if (@($o.Failing).Count) { $lines.Add("  failing (lowest first): $(@($o.Failing) -join ' | ')") }
    $lines.Add("Step-4 list rule applied: $($o.ListRule)")
    $lines.Add('Separate gates, not part of this outcome: misc rule (fs-miscrule.ps1), partition/slot/devinfo checks (<withheld document>), recovery.')
    foreach ($l in $lines) { Write-Output (ConvertTo-FsPrintable $l) }
    $code = switch ($o.Outcome) { 'PASS' { 10 } 'COMPATIBILITY FAIL' { 11 } 'INTEGRITY FAULT' { 12 } 'INCONCLUSIVE' { 14 } default { 13 } }
    exit $code
} catch { Write-Output (ConvertTo-FsPrintable "CLASSIFIER ERROR: $($_.Exception.Message)"); exit 70 }
