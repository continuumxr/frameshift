# FrameShift N1 classifier (Windows PowerShell 5.1, no modules). Reads ONE collector output directory of
# fs-collect-n1.ps1 (collect.json + capture.raw + xfer.json) and classifies the N1 run (devices/quest3/n1/README.md s.6
# "What counts as N1 PASS"; FS-R-013 s.5, s.9). Offline; reads files only; no device, no network. Adapted from
# fs-classify-k1a.ps1 (not edited): the same binding, INCONCLUSIVE / INTEGRITY FAULT rules and K1a kernel facts, plus
#   - FS-R-013 s.2: a valid, positive MemTotal is REQUIRED (missing or malformed: N1 FAIL; reported; not a reason for
#     another attempt);
#   - ACM continuity: the record came over the ACM console (it exists) and the gadget is bound with acm.gs0 FIRST and
#     ncm.fs second; any NCM failure (NCM_SKIPPED, NCM_DROPPED, NCM_NET_FAILED, NCM_FALLBACK) is an N1 FAIL that keeps
#     the fact "ACM continuity held";
#   - the NCM link: dev_addr/host_addr from the nonce, the interface carries dev_addr, its IPv6 sysctls, EXACTLY one
#     IPv6 address on it (fe80::<nonce>/64, scope link, permanent);
#   - the kernel log BEFORE and AFTER the transfer (FS-R-014 s.5): the modules step's read (step 3, pre-transfer,
#     K1a's section) and the log step's kmsg_post read (step 6, post-transfer) are BOTH required and evaluated; the
#     post read must extend the pre read (same first line, no fewer lines: continuous coverage); a missing or
#     malformed post result is an N1 FAIL; an unreadable post read, a coverage not proven (wrapped, cleared) or a post
#     result cut by the log step's cap is an N1 REVIEW, never a silent PASS; WARNING/BUG lines in either read are a
#     REVIEW, and those first seen after step 3 are named as such;
#   - no unintended listener: before (net step) and after (log step) the transfer no TCP LISTEN row and no UDP,
#     UDP-Lite, raw or packet socket (a REVIEW: listed for the Chair); fs-xfer closed its listener at the accept;
#   - the transfer: fs-xfer result=ok; the device received 8388608 bytes with the SHA-256 the PC sent, and sent 8388608
#     bytes whose SHA-256 the PC received, which is the expected deterministic stream (recomputed here); the trailer
#     agrees; the drain saw the PC's EOF;
#   - the PC side (xfer.json; bound: the live client, the adapter that descends from FS-<nonce>, its ifIndex): the driver (inbox UsbNcm, usbncm.inf, expected;
#     another driver is a REVIEW: any driver install is a PM decision), its MAC, the adapter timeline (bounded
#     enumeration).
#   fs-classify-n1.ps1 -CollectDir <dir> [-ObserveDir <dir>] [-AllowReplay]
#   . fs-classify-n1.ps1 ; $o = Get-FsN1Outcome -Fsb1 <Test-Fsb1Record result> -Xfer <xfer.json object> -Nonce <n> -Challenge <c>
# Outcome, first match wins:
#   INCONCLUSIVE     no complete, FSB1-VALID record
#   INTEGRITY FAULT  a step that did not exit 0 (timer, signal, no supervisor report, fs-xfer usage/internal), or stderr
#   (then: no readable xfer.json of this nonce and challenge, or one not made by the live PC client for this attempt's
#   adapter, turns any later outcome into INCONCLUSIVE)
#   N1 FAIL          the record is valid but a K1a fact, MemTotal, the NCM link or the transfer is wrong
#   N1 REVIEW        every N1 fact holds, but: kernel WARNING/BUG lines (before or after the transfer), a wrapped log,
#                    an unreadable post-transfer read or its coverage not proven, a truncated step, an unexpected
#                    socket before or after, an IPv4 local address, a drain anomaly, or a PC driver other than UsbNcm
#   N1 PASS          every N1 fact holds and nothing above is to review
# Binding (as K1a): a recorded outcome needs a LIVE collect.json and xfer.json (no replay, no fixture) and the attempt's
# observe.json (-ObserveDir: the same nonce, stage n1, one of the two units); otherwise INCONCLUSIVE. -AllowReplay
# (offline fixtures only) lifts that and labels every output FIXTURE. With -ObserveDir and the attempt's checklist
# phase F, the classifier writes <ObserveDir>\classify-n1.json ONCE (schema frameshift.fs-classify-n1.v1).
# Exit: 40 N1 PASS, 41 N1 REVIEW, 42 N1 FAIL, 43 INTEGRITY FAULT, 44 INCONCLUSIVE, 64 usage, 70 internal error.
[CmdletBinding()]
param(
    [string]$CollectDir = '', [string]$ObserveDir = '',
    [switch]$AllowReplay
)
Set-StrictMode -Version 2.0
$script:FsN1ClsInvocation = $MyInvocation.InvocationName
$script:FsN1ClsDir = $PSScriptRoot
. (Join-Path $PSScriptRoot 'fs-n1-units.ps1')      # the units, the K1a pins, Test-Fsb1Record, Get-FsN1MemTotal (read only)
. (Join-Path $PSScriptRoot 'fs-xfer-n1.ps1')       # Get-FsN1Ids, Get-FsN1D2hExpectedSha (read only here: no session is made)
$script:FsN1Latin1 = [System.Text.Encoding]::GetEncoding(28591)

function Get-FsN1Section([string]$Text, [string]$Title) {
    $out = New-Object System.Collections.Generic.List[string]; $on = $false
    foreach ($l in ($Text -split "`n")) {
        $l = $l.TrimEnd("`r")
        if ($l.StartsWith('== ')) { if ($on) { break }; $on = ($l -ceq "== $Title"); continue }
        if ($on) { $out.Add($l) }
    }
    $out.ToArray()       # unrolled: callers wrap the result in @()
}
function Get-FsN1Attrs([string]$Text, [string]$Title) {     # grep -H lines "/path/name:value" -> @{ name = value }
    $d = [ordered]@{}
    foreach ($l in (Get-FsN1Section $Text $Title)) { if ($l -cmatch '^(/[^:]+):(.*)$') { $d[($Matches[1] -split '/')[-1]] = $Matches[2] } }
    $d
}
function Get-FsN1Sockets([string]$Text, [string]$Which) {   # @{ table = @(rows) } of "== sockets <which>"; header rows dropped
    $t = [ordered]@{}; foreach ($n in 'tcp', 'tcp6', 'udp', 'udp6', 'udplite', 'udplite6', 'raw', 'raw6', 'packet') { $t[$n] = New-Object System.Collections.Generic.List[string] }
    $seen = @()
    foreach ($l in (Get-FsN1Section $Text "sockets $Which")) {
        if ($l -cnotmatch '^/proc/net/(\w+):(.*)$') { continue }
        $n = $Matches[1]; $b = $Matches[2]
        if (-not $t.Contains($n)) { continue }
        if ($seen -cnotcontains $n) { $seen += $n }
        if ($b -cmatch '^\s*(sl|sk)\s') { continue }
        $t[$n].Add($b)
    }
    [pscustomobject]@{ Rows = $t; Seen = $seen }
}
function ConvertTo-FsN1P([string]$s) { ConvertTo-FsN1Printable $s }
# The log step's post-transfer kernel-log result (fs-n1-info.sh kmsg_post; FS-R-014 s.5), parsed as a STRICT
# sequence (review r2 M2): the read line is line 0 of the log step; read=fail is followed only by the end marker;
# read=ok has rc=0 and then, each exactly once and in this order: lines, first, last, modver, taint, warnings (then
# exactly min(l, 30) "| " lines), ncm (then exactly min(n, 10) "| " lines), the end marker; the next line is
# "== fs.log"; no second "== kmsg-post" line anywhere in the step; every count at most 15 digits; w, b <= l <= lines
# and n <= lines. Returns { Present; Read; Rc; Bytes; Lines; First; Last; Modver; Taint; WarningCount; BugCount;
# MatchLines; ListedCount; Listed; NcmLines; NcmListed; End; Complete; Missing; Coverage }.
function Get-FsN1KmsgPost([string]$Text) {
    $k = [ordered]@{ Present = $false; Read = $null; Rc = $null; Bytes = $null; Lines = $null; First = $null; Last = $null; Modver = $null; Taint = $null
                     WarningCount = $null; BugCount = $null; MatchLines = $null; ListedCount = $null; Listed = @(); NcmLines = $null; NcmListed = $null; End = $false
                     Complete = $false; Missing = ''; Coverage = $null }
    $L = @($Text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
    $hits = @(for ($j = 0; $j -lt $L.Count; $j++) { if ($L[$j].StartsWith('== kmsg-post')) { $j } })
    if ($hits.Count -eq 0) { return [pscustomobject]$k }
    $k.Present = $true
    $miss = New-Object System.Collections.Generic.List[string]
    $N = '(0|[1-9][0-9]{0,14})'
    $at = { param([int]$x) if ($x -lt $L.Count) { [string]$L[$x] } else { '' } }
    $i = 1
    $m0 = [regex]::Match($L[0], "^== kmsg-post read=(ok|fail) rc=$N bytes=$N$")
    if (-not $L[0].StartsWith('== kmsg-post read=')) { $miss.Add('the read line is not line 0 of the log step') }
    elseif (-not $m0.Success) { $miss.Add('the read line is malformed') }
    elseif ($m0.Groups[1].Value -ceq 'fail') {
        $k.Read = 'fail'; $k.Rc = [long]$m0.Groups[2].Value; $k.Bytes = [long]$m0.Groups[3].Value
        if ((& $at $i) -ceq '== kmsg-post-end') { $k.End = $true; $i++ } else { $miss.Add('a failed read not followed by the end marker') }
    } elseif ($m0.Groups[2].Value -cne '0') { $miss.Add('read=ok with a nonzero rc') }
    else {
        $k.Read = 'ok'; $k.Rc = 0; $k.Bytes = [long]$m0.Groups[3].Value
        $seq = @(@('Lines', "^== kmsg-post-lines $N$"), @('First', '^== kmsg-post-first (.*)$'), @('Last', '^== kmsg-post-last (.*)$'),
                 @('Modver', "^== kmsg-post-modver $N$"), @('Taint', "^== kmsg-post-taint $N$"))
        $ok = $true
        foreach ($q in $seq) {
            $m = [regex]::Match((& $at $i), $q[1])
            if (-not $m.Success) { $miss.Add("no $($q[0].ToLower()) line at line $i of the log step"); $ok = $false; break }
            $k[$q[0]] = $(if ($q[0] -ceq 'First' -or $q[0] -ceq 'Last') { $m.Groups[1].Value } else { [long]$m.Groups[1].Value }); $i++
        }
        if ($ok) {
            $m = [regex]::Match((& $at $i), "^== kmsg-post-warnings $N warning-lines, $N bug-lines, $N lines, $N listed$")
            if (-not $m.Success) { $miss.Add("no warnings line at line $i of the log step"); $ok = $false }
            else {
                $k.WarningCount = [long]$m.Groups[1].Value; $k.BugCount = [long]$m.Groups[2].Value; $k.MatchLines = [long]$m.Groups[3].Value; $k.ListedCount = [long]$m.Groups[4].Value; $i++
                $wl = New-Object System.Collections.Generic.List[string]
                while ((& $at $i).StartsWith('| ')) { $wl.Add((ConvertTo-FsN1P (& $at $i).Substring(2))); $i++ }
                $k.Listed = $wl.ToArray()
                $wantL = [Math]::Min($k.MatchLines, 30)
                if ($k.ListedCount -ne $wantL -or $wl.Count -ne $wantL) { $miss.Add("$($wl.Count) warning lines listed, $($k.ListedCount) announced, min($($k.MatchLines), 30) expected"); $ok = $false }
            }
        }
        if ($ok) {
            $m = [regex]::Match((& $at $i), "^== kmsg-post-ncm $N lines, $N listed$")
            if (-not $m.Success) { $miss.Add("no ncm line at line $i of the log step"); $ok = $false }
            else {
                $k.NcmLines = [long]$m.Groups[1].Value; $k.NcmListed = [long]$m.Groups[2].Value; $i++; $nl = 0
                while ((& $at $i).StartsWith('| ')) { $nl++; $i++ }
                $wantN = [Math]::Min($k.NcmLines, 10)
                if ($k.NcmListed -ne $wantN -or $nl -ne $wantN) { $miss.Add("$nl ncm lines listed, $($k.NcmListed) announced, min($($k.NcmLines), 10) expected"); $ok = $false }
            }
        }
        if ($ok) { if ((& $at $i) -ceq '== kmsg-post-end') { $k.End = $true; $i++ } else { $miss.Add('no end marker after the ncm lines'); $ok = $false } }
        if ($ok) {
            if ($k.Lines -lt 1) { $miss.Add('no line read') }
            if ($k.WarningCount -gt $k.MatchLines -or $k.BugCount -gt $k.MatchLines -or $k.MatchLines -gt $k.Lines -or $k.NcmLines -gt $k.Lines -or $k.Modver -gt $k.Lines -or $k.Taint -gt $k.Lines) { $miss.Add('the counts are inconsistent (w, b <= l <= lines; n, modver, taint <= lines)') }
        }
    }
    if ($k.End -and (& $at $i) -cne '== fs.log') { $miss.Add("the line after the end marker is not '== fs.log'") }
    $extra = @($hits | Where-Object { $_ -ge $i })
    if ($extra.Count) { $miss.Add("a further '== kmsg-post' line at line $($extra[0]) of the log step") }
    if (-not $k.End -and @($miss | Where-Object { $_ -like '*end marker*' }).Count -eq 0) { $miss.Add('no end marker') }
    $k.Missing = ($miss -join '; ')
    $k.Complete = ($k.Read -ceq 'ok' -and $miss.Count -eq 0)
    if ($k.Read -ceq 'fail' -and $miss.Count) { $k.Read = 'malformed' }
    [pscustomobject]$k
}

function Get-FsN1Outcome {
    param([Parameter(Mandatory)][AllowNull()]$Fsb1, $Xfer = $null, [bool]$Collected = $true, [string]$Nonce = '', [string]$Challenge = '',
          [string]$Banner = $script:FsK1aPinBanner, [string]$ConfigSha = $script:FsK1aPinConfigSha, [int]$Modules = $script:FsK1aPinModules)
    $facts = New-Object System.Collections.Generic.List[string]
    $fails = New-Object System.Collections.Generic.List[string]
    $rev = New-Object System.Collections.Generic.List[string]
    $warn = New-Object System.Collections.Generic.List[string]
    $o = [ordered]@{ Outcome = 'INCONCLUSIVE'; Reason = ''; Facts = $facts; Failing = $fails; Review = $rev; Warnings = $warn; WarningCount = $null; BugCount = $null
                     MemTotal = $null; KmsgFirst = $null; KmsgLines = $null; KmsgTaintCount = $null; KmsgMatchLines = $null; KmsgPost = $null; PostWarnings = @(); Steps = @(); Truncated = @(); Wrapped = $null; TaintLines = @(); AcmContinuity = $null; Ncm = $null
                     Xfer = $null; Host = $null; SocketsBefore = $null; SocketsAfter = $null }
    if (-not $Collected -or $null -eq $Fsb1 -or -not $Fsb1.Ok) {
        $o.Reason = $(if ($null -ne $Fsb1 -and -not $Fsb1.Ok) { "no valid record (FSB1 $($Fsb1.Reason) $($Fsb1.Detail))" } else { 'no complete record' })
        return [pscustomobject]$o
    }
    $out = @{}; $bad = @()
    foreach ($st in $Fsb1.Steps) {
        $id = [string]$st['id']
        $out[$id] = $script:FsN1Latin1.GetString([byte[]]$st['out'])
        $o.Steps += [pscustomobject]@{ I = $st['i']; Id = $id; End = $st['end']; Code = $st['code']; OutLen = $st['out_len']; ErrLen = $st['err_len'] }
        if ($st.ContainsKey('out_total') -and $st.ContainsKey('out_kept') -and [long]$st['out_total'] -gt [long]$st['out_kept']) { $o.Truncated += "$id ($($st['out_total']) bytes, $($st['out_kept']) kept)" }
        if ($st['end'] -cne 'exited' -or [long]$st['code'] -ne 0) { $bad += "step $($st['i']) $id end=$($st['end']) code=$($st['code'])" }
        elseif ([long]$st['err_len'] -ne 0) { $bad += "step $($st['i']) $id wrote $($st['err_len']) bytes to stderr" }
    }
    $mo = [string]$out['modules']; $nt = [string]$out['net']; $xf = [string]$out['xfer']; $lg = [string]$out['log']
    # reported whatever the outcome: the kernel log findings (FS-R-012 s.3), MemTotal, the kmsg first line
    if ($mo -cmatch '(?m)^== kmsg-lines (\d{1,15}) first=(.*)$') { $o.KmsgLines = [long]$Matches[1]; $o.KmsgFirst = $Matches[2].TrimEnd("`r"); $facts.Add("kmsg (step 3, before the transfer): $($Matches[1]) lines, first '$(ConvertTo-FsN1P $o.KmsgFirst)'") }
    if ($mo -cmatch '(?m)^== warnings (\d{1,15}) warning-lines, (\d{1,15}) bug-lines, (\d{1,15}) lines$') {
        $o.WarningCount = [long]$Matches[1]; $o.BugCount = [long]$Matches[2]; $o.KmsgMatchLines = [long]$Matches[3]
        $after = $mo.Substring($mo.IndexOf($Matches[0]) + $Matches[0].Length).Split("`n")
        foreach ($l in $after) { if ($l.StartsWith('== ')) { break }; if ($l.Trim() -ne '') { $warn.Add((ConvertTo-FsN1P $l.TrimEnd("`r"))) } }
    }
    $o.Wrapped = -not ([string]$o.KmsgFirst -cmatch '^(<[0-9]+>)?\[\s*0\.0+')
    if ($mo -cmatch '(?m)^== taint-lines (\d{1,15})\r?$') { $o.KmsgTaintCount = [long]$Matches[1]; $after = $mo.Substring($mo.IndexOf($Matches[0]) + $Matches[0].Length).Split("`n"); foreach ($l in $after) { if ($l.StartsWith('== ')) { break }; if ($l.Trim() -ne '') { $o.TaintLines += (ConvertTo-FsN1P $l.TrimEnd("`r")) } } }
    $mt = Get-FsN1MemTotal ([string]$out['mem'])
    $o.MemTotal = $(if ($mt.Ok) { "$($mt.Kb) kB" } else { $null })
    $o.KmsgPost = Get-FsN1KmsgPost $lg
    $o.PostWarnings = @($o.KmsgPost.Listed)
    if ($bad.Count) { $o.Outcome = 'INTEGRITY FAULT'; $o.Reason = ($bad -join '; '); return [pscustomobject]$o }

    # ---- the K1a facts (same kernel) and MemTotal ----
    $kn = [string]$out['kernel']
    $pv = if ($kn -cmatch "(?m)^== proc-version\n(.*)$") { $Matches[1] } else { '' }
    if ($pv -ceq $Banner) { $facts.Add('kernel: /proc/version is the pinned K1a banner (the K1a kernel booted)') } else { $fails.Add("kernel: /proc/version '$(ConvertTo-FsN1P $pv)' is not the pinned banner") }
    if ($kn -cmatch '(?m)^== config_sha256 ([0-9a-f]{64})$' -and $Matches[1] -ceq $ConfigSha) { $facts.Add("config: sha256(zcat /proc/config.gz) = $ConfigSha (the gated k1a.config)") }
    else { $fails.Add('config: the running config is not the gated k1a.config (or not reported)') }
    foreach ($opt in 'CONFIG_USB_CONFIGFS_NCM=y', 'CONFIG_USB_F_NCM=y', 'CONFIG_IPV6=y') { if (-not ($kn -cmatch ('(?m)^' + [regex]::Escape($opt) + '$'))) { $fails.Add("config: $opt not reported") } }
    $ready = $mo -cmatch "(?m)STAGE=MODULES_READY ok=$Modules fail=0 "
    $loaded = $mo -cmatch "(?m)^== loaded $Modules$"
    $mf = @([regex]::Matches($mo, '(?m)MODULE_FAIL (\S+)') | ForEach-Object { $_.Groups[1].Value })
    if ($ready -and $loaded -and $mf.Count -eq 0) { $facts.Add("modules: MODULES_READY ok=$Modules fail=0; $Modules in /proc/modules; no MODULE_FAIL") }
    else { $fails.Add("modules: ready=$ready loaded=$loaded MODULE_FAIL=$($mf -join ',')") }
    if ($mo -cmatch '(?m)^== modver-matches 0\r?$') { $facts.Add('kmsg: no symbol-version or vermagic refusal') } else { $fails.Add('kmsg: symbol-version or vermagic lines in the kernel log (or not reported)') }
    if ($null -eq $o.WarningCount) { $fails.Add('kmsg: the warning counts are missing') }
    if ($null -eq $o.KmsgLines) { $fails.Add('kmsg: the step 3 line count and first line are missing') }
    if ($null -eq $o.KmsgTaintCount) { $fails.Add('kmsg: the step 3 taint count is missing') }
    # the post-transfer kernel-log check (FS-R-014 s.5): required; evaluated against the pre-transfer read. kmsg_post
    # prints first and at most about 8.1 KB of the 24576-byte cap, and fs-supervise keeps the head of a step's output,
    # so a cap can never remove or cut it: a missing or incomplete result is an N1 FAIL (review r2 m3)
    $kp = $o.KmsgPost
    if (-not $kp.Present) {
        $fails.Add('kmsg-post: the post-transfer kernel-log result is missing (required: FS-R-014 s.5)')
    } elseif ($kp.Read -ceq 'fail') {
        $rev.Add("kmsg-post: the kernel log could not be read after the transfer (dmesg rc=$($kp.Rc), $($kp.Bytes) bytes): the transfer period has no kernel-log coverage")
    } elseif (-not $kp.Complete) {
        $fails.Add("kmsg-post: the post-transfer result is malformed or incomplete ($($kp.Missing)); kmsg_post prints first, so the log step's cap cannot explain it")
    } else {
        $facts.Add("kmsg-post (step 6, after the transfer): $($kp.Lines) lines, first '$(ConvertTo-FsN1P ([string]$kp.First))', last '$(ConvertTo-FsN1P ([string]$kp.Last))'; $($kp.WarningCount) WARNING, $($kp.BugCount) BUG/oops-class, $($kp.MatchLines) matching lines ($($kp.ListedCount) listed); $($kp.Modver) refusal, $($kp.Taint) taint lines")
        if ($kp.Modver -gt 0) { $fails.Add("kmsg-post: $($kp.Modver) symbol-version or vermagic lines in the post-transfer kernel log") }
        $postWrapped = -not ([string]$kp.First -cmatch '^(<[0-9]+>)?\[\s*0\.0+')
        $cont = ($null -ne $o.KmsgLines -and -not $o.Wrapped -and -not $postWrapped -and [string]$kp.First -ceq [string]$o.KmsgFirst -and $kp.Lines -ge $o.KmsgLines)
        $kp.Coverage = $(if ($cont) { 'continuous' } else { 'not proven' })
        if ($cont) { $facts.Add("kmsg coverage: the post-transfer read extends the pre-transfer read (same first line; $($o.KmsgLines) -> $($kp.Lines) lines, +$($kp.Lines - $o.KmsgLines) since step 3)") }
        else { $rev.Add("kmsg-post: the kernel log's coverage across the transfer is not proven (step 3: $($o.KmsgLines) lines, first '$(ConvertTo-FsN1P ([string]$o.KmsgFirst))'; step 6: $($kp.Lines) lines, first '$(ConvertTo-FsN1P ([string]$kp.First))'): the buffer wrapped or was cleared, lines logged during the transfer may be missing") }
        if ($kp.WarningCount -gt 0 -or $kp.BugCount -gt 0 -or $kp.MatchLines -gt 0) {
            $nw = ''
            if ($cont -and $null -ne $o.WarningCount -and $null -ne $o.KmsgMatchLines) {
                $dw = $kp.WarningCount - $o.WarningCount; $db = $kp.BugCount - $o.BugCount; $dl = $kp.MatchLines - $o.KmsgMatchLines
                $newL = @($kp.Listed | Where-Object { $warn -cnotcontains $_ })
                $nw = $(if ($dw -gt 0 -or $db -gt 0 -or $dl -gt 0) { "; $dl matching lines ($dw WARNING, $db BUG/oops-class) first appeared AFTER step 3 (during or after the transfer)$(if ($newL.Count) { ", e.g. '$($newL[-1])'" })" } else { '; none new since step 3' })
            } elseif (-not $cont) { $nw = '; which of them are new since step 3 cannot be told (coverage not proven)' }
            $ls = $(if ($kp.ListedCount -lt $kp.MatchLines) { " (the last $($kp.ListedCount) of $($kp.MatchLines) lines listed; the counts are complete)" } else { '' })
            $rev.Add("the post-transfer kernel log (step 6) has $($kp.WarningCount) WARNING, $($kp.BugCount) BUG/oops-class and $($kp.MatchLines) matching lines in all$nw$ls (FS-R-012 s.3, FS-R-014 s.5)")
        }
        if ($null -ne $o.KmsgTaintCount -and $kp.Taint -gt $o.KmsgTaintCount) { $rev.Add("kmsg-post: $($kp.Taint - $o.KmsgTaintCount) new 'taints kernel' line(s) after step 3") }
    }
    if ($mt.Ok) { $facts.Add("mem: $($mt.Why) (FS-R-013 s.2: valid and positive)") } else { $fails.Add("mem: no valid, positive MemTotal ($($mt.Why); FS-R-013 s.2: blocks progression, reported, not a reason for another attempt)") }

    # ---- ACM continuity and the NCM link ----
    $ids = Get-FsN1Ids $Nonce
    $ud = Get-FsN1Attrs $nt 'udc'; $gd = Get-FsN1Attrs $nt 'gadget'; $nf = Get-FsN1Attrs $nt 'ncm-function'
    $cf = if ($nt -cmatch '(?m)^== config-functions (.*)$') { $Matches[1].TrimEnd("`r") } else { '' }
    $fsLog = (@(Get-FsN1Section $lg 'fs.log') -join "`n")      # the scan reads fs.log only (the log step also holds kernel text)
    $ncmLog = @([regex]::Matches($fsLog, '(?m)NCM_(SKIPPED|DROPPED|NET_FAILED|FALLBACK)[^\r\n]*') | ForEach-Object { ConvertTo-FsN1P $_.Value })
    $o.AcmContinuity = "the record came over the ACM console; gadget '$cf' bound to $($ud['UDC']) ($($ud['state']))"
    $facts.Add("ACM continuity: $($o.AcmContinuity)")
    if ([string]$ud['UDC'] -cne 'a600000.dwc3' -or [string]$ud['state'] -cne 'configured') { $fails.Add("usb: the UDC is '$($ud['UDC'])' state '$($ud['state'])' (a600000.dwc3 configured expected)") }
    if ([string]$gd['product'] -cne 'FrameShift N1' -or [string]$gd['serialnumber'] -cne $ids.Serial) { $fails.Add("usb: product '$(ConvertTo-FsN1P $gd['product'])' serial '$(ConvertTo-FsN1P $gd['serialnumber'])' (FrameShift N1, $($ids.Serial) expected)") }
    $ncmOk = $true
    if ($cf -cne 'acm.gs0 ncm.fs ') { $fails.Add("ncm: the configuration links '$(ConvertTo-FsN1P $cf.Trim())', not acm.gs0 then ncm.fs (NCM not bound; ACM continuity held)"); $ncmOk = $false }
    if ($ncmLog.Count) { $fails.Add("ncm: $($ncmLog -join '; ') (ACM continuity held)"); $ncmOk = $false }
    $fsn = @(Get-FsN1Section $nt 'fs.ncm' | ForEach-Object { ($_ -split ':', 2)[-1] })
    $nifName = ''; foreach ($x in $fsn) { if ($x -cmatch '^if=([a-z0-9]{1,15})$') { $nifName = $Matches[1] } }
    if (@($fsn) -cnotcontains 'state=up') { $fails.Add("ncm: /run/fs.ncm says '$(ConvertTo-FsN1P (@($fsn) -join ' '))', not state=up"); $ncmOk = $false }
    if ([string]$nf['dev_addr'] -cne $ids.DevMac -or ([string]$nf['host_addr']).ToUpperInvariant().Replace(':', '-') -cne $ids.HostMac) { $fails.Add("ncm: dev_addr '$(ConvertTo-FsN1P $nf['dev_addr'])' host_addr '$(ConvertTo-FsN1P $nf['host_addr'])' are not the nonce's ($($ids.DevMac), $($ids.HostMac))"); $ncmOk = $false }
    if ($nifName) {
        $ia = Get-FsN1Attrs $nt "if $nifName"; $ic = Get-FsN1Attrs $nt "ipv6conf $nifName"
        if ([string]$ia['address'] -cne $ids.DevMac) { $fails.Add("ncm: $nifName carries '$(ConvertTo-FsN1P $ia['address'])', not dev_addr $($ids.DevMac)"); $ncmOk = $false }
        $want = [ordered]@{ disable_ipv6 = '0'; addr_gen_mode = '1'; accept_dad = '0'; dad_transmits = '0'; accept_ra = '0'; autoconf = '0'; router_solicitations = '0'; forwarding = '0' }
        $bc = @($want.Keys | Where-Object { [string]$ic[$_] -cne $want[$_] })
        if ($bc.Count) { $fails.Add("ncm: $nifName IPv6 settings differ: $(@($bc | ForEach-Object { "$_=$($ic[$_])" }) -join ' ')"); $ncmOk = $false }
        $v6 = @(Get-FsN1Section $nt 'if_inet6' | Where-Object { $_ -cmatch (' ' + [regex]::Escape($nifName) + '$') })
        $wantV6 = "fe80000000000000$Nonce"
        if ($v6.Count -ne 1 -or ($v6[0] -split '\s+')[0] -cne $wantV6 -or ($v6[0] -split '\s+')[2] -cne '40' -or ($v6[0] -split '\s+')[3] -cne '20' -or ($v6[0] -split '\s+')[4] -cne '80') {
            $fails.Add("ncm: $nifName does not hold exactly one IPv6 address fe80::<nonce>/64 scope link permanent ($(@($v6) -join ' | '))"); $ncmOk = $false }
        else { $facts.Add("ncm: $nifName ($($ia['address']), $($ia['operstate'])) holds exactly one IPv6 address, $($ids.LinkLocal)/64, scope link, permanent; IPv6 settings as set") }
        $o.Ncm = [ordered]@{ If = $nifName; Mac = $ia['address']; Operstate = $ia['operstate']; Carrier = $ia['carrier']; IfIndex = $ia['ifindex']; Mtu = $ia['mtu'] }
    } elseif ($ncmOk) { $fails.Add('ncm: no interface name in /run/fs.ncm'); $ncmOk = $false }
    if ($ncmOk) { $facts.Add("ncm: linked after acm.gs0 and bound; MACs from the nonce ($($ids.DevMac) / $($ids.HostMac)); no NCM_SKIPPED/DROPPED/NET_FAILED/FALLBACK") }
    # IPv4: every "/32 host LOCAL" entry of fib_trie names a local address (the "|-- a.b.c.d" line before it); loopback
    # 127/8 is not on the NCM link and is only reported
    $local4 = @(); $lo4 = @(); $lastA = ''
    foreach ($l in @(Get-FsN1Section $nt 'fib_trie')) {
        if ($l -cmatch '\|-- ([0-9]{1,3}(\.[0-9]{1,3}){3})\s*$') { $lastA = $Matches[1] }
        elseif ($l -cmatch '/32 host LOCAL') { if ($lastA -like '127.*') { $lo4 += $lastA } else { $local4 += $lastA } }
    }
    if ($local4.Count) { $rev.Add("an IPv4 local address exists on the device ($(@($local4 | Select-Object -Unique) -join ', ')): N1 is IPv6 link-local only") }
    else { $facts.Add("ipv4: no local IPv4 address other than loopback (fib_trie$(if ($lo4.Count) { "; loopback $(@($lo4 | Select-Object -Unique) -join ', ')" }))") }

    # ---- no unintended listener ----
    $sb = Get-FsN1Sockets $nt 'before'; $sa = Get-FsN1Sockets $lg 'after'
    $need = @('tcp', 'tcp6', 'udp', 'udp6', 'raw', 'raw6', 'packet')
    foreach ($w in @(@('before', $sb), @('after', $sa))) {
        $miss = @($need | Where-Object { $w[1].Seen -cnotcontains $_ })
        if ($miss.Count) { $fails.Add("sockets $($w[0]): tables not read: $($miss -join ',')") }
        $lis = @(foreach ($tn in 'tcp', 'tcp6') { foreach ($r in $w[1].Rows[$tn]) { $f = ($r.Trim() -split '\s+')
            if ($f.Count -gt 3 -and ($f[3] -ceq '0A' -or $w[0] -ceq 'before' -or $f[1] -cnotmatch ':B861$')) { "$tn $($f[1]) st=$($f[3])" } } })
        $oth = @(foreach ($tn in 'udp', 'udp6', 'udplite', 'udplite6', 'raw', 'raw6', 'packet') { if ($w[1].Rows[$tn].Count) { "$tn x$($w[1].Rows[$tn].Count)" } })
        if ($lis.Count -or $oth.Count) { $rev.Add("sockets $($w[0]) the transfer: $(@($lis) + @($oth) -join ', ') (no listener expected; after the transfer only the closing session on port 47201)") }
        else { $facts.Add("sockets $($w[0]) the transfer: no TCP LISTEN row, no UDP, UDP-Lite, raw or packet socket$(if ($w[0] -ceq 'after') { " ($($w[1].Rows['tcp6'].Count + $w[1].Rows['tcp'].Count) closing TCP rows)" })") }
    }
    $o.SocketsBefore = [ordered]@{}; foreach ($k in $sb.Rows.Keys) { $o.SocketsBefore[$k] = $sb.Rows[$k].Count }
    $o.SocketsAfter = [ordered]@{}; foreach ($k in $sa.Rows.Keys) { $o.SocketsAfter[$k] = $sa.Rows[$k].Count }

    # ---- the transfer: the device's record, the PC's xfer.json, the expected stream ----
    $xr = if ($xf -cmatch '(?m)^FSX1 result=(\S+)') { $Matches[1] } else { '' }
    $rx = [regex]::Match($xf, '(?m)^FSX1 rx bytes=(\d+) sha256=([0-9a-f]{64}) ms=(\d+)$')
    $tx = [regex]::Match($xf, '(?m)^FSX1 tx bytes=(\d+) sha256=([0-9a-f]{64}) ms=(\d+) trailer=1$')
    $ac = [regex]::Match($xf, '(?m)^FSX1 accept peer=(\S+) scope=(\d+) t_ms=(\d+) rejects=(\d+)$')
    $dr = [regex]::Match($xf, '(?m)^FSX1 drain bytes=(\d+) eof=([01])$')
    $exp = Get-FsN1D2hExpectedSha $Nonce $Challenge
    $o.Xfer = [ordered]@{ DeviceResult = $xr; RxMs = $(if ($rx.Success) { [long]$rx.Groups[3].Value }); TxMs = $(if ($tx.Success) { [long]$tx.Groups[3].Value }); ExpectedD2hSha256 = $exp }
    $pvx = { param($ob, [string]$n) if ($null -ne $ob -and $ob -is [psobject] -and $ob.PSObject.Properties[$n]) { $ob.$n } else { $null } }
    $hostRes = [string](& $pvx $Xfer 'Result')
    if ($xr -cne 'ok') { $fails.Add("transfer: fs-xfer result=$(ConvertTo-FsN1P $xr) (the PC: $(ConvertTo-FsN1P $hostRes))") }
    else {
        $h2d = & $pvx $Xfer 'H2d'; $d2h = & $pvx $Xfer 'D2h'
        $hs = [string](& $pvx $h2d 'Sha256'); $ds = [string](& $pvx $d2h 'Sha256')
        $okx = ($rx.Success -and $tx.Success -and [long]$rx.Groups[1].Value -eq 8388608 -and [long]$tx.Groups[1].Value -eq 8388608 -and $hostRes -ceq 'ok' -and
                $rx.Groups[2].Value -ceq $hs -and $tx.Groups[2].Value -ceq $ds -and $ds -ceq $exp -and [string](& $pvx $d2h 'ExpectedSha256') -ceq $exp)
        $tf = & $pvx $Xfer 'TrailerFields'
        $okt = ($null -ne $tf -and [string](& $pvx $tf 'rx_sha256') -ceq $rx.Groups[2].Value -and [string](& $pvx $tf 'tx_sha256') -ceq $tx.Groups[2].Value)
        if ($okx -and $okt) { $facts.Add("transfer: 8388608 bytes PC->device (SHA-256 $($hs.Substring(0, 16))... on both sides, device $($rx.Groups[3].Value) ms) and 8388608 bytes device->PC (the expected stream, $($ds.Substring(0, 16))... on both sides, device $($tx.Groups[3].Value) ms); the trailer agrees") }
        else { $fails.Add("transfer: the hashes or sizes do not agree (device rx $($rx.Groups[2].Value) / PC sent $hs; device tx $($tx.Groups[2].Value) / PC received $ds / expected $exp; trailer ok $okt; PC result $hostRes)") }
        $ifx = if ($null -ne $o.Ncm) { [string]$o.Ncm.IfIndex } else { '' }
        if (-not $ac.Success -or $ac.Groups[1].Value -cnotmatch '^fe80:' -or $ac.Groups[2].Value -cne $ifx) { $fails.Add("transfer: the accepted peer '$(ConvertTo-FsN1P $ac.Value)' is not link-local on the NCM interface (ifindex $ifx)") }
        elseif ([int]$ac.Groups[4].Value -ne 0) { $rev.Add("transfer: fs-xfer rejected $($ac.Groups[4].Value) foreign peer(s) before the session") }
        if ($xf -cnotmatch '(?m)^FSX1 closed-listener ') { $fails.Add('transfer: fs-xfer did not report closing its listener at the accept') }
        if (-not $dr.Success -or $dr.Groups[1].Value -cne '0' -or $dr.Groups[2].Value -cne '1') { $rev.Add("transfer: the drain was '$(ConvertTo-FsN1P $dr.Value)' (bytes=0 eof=1 expected: the PC closes after the trailer)") }
    }
    # ---- the PC side: the adapter, its driver, the timeline (bounded enumeration) ----
    if ($null -ne $Xfer) {
        $ad = & $pvx $Xfer 'Adapter'; $a2 = & $pvx $ad 'Adapter'; $dv = & $pvx $ad 'Driver'
        $tl = @(& $pvx $Xfer 'AdapterTimeline')
        $o.Host = [ordered]@{ Result = $hostRes; Adapter = $a2; Driver = $dv; MacMatches = (& $pvx $ad 'MacMatches'); HostLinkLocal = @(& $pvx $ad 'HostLinkLocal'); Timeline = $tl
                              ConnectAttempts = (& $pvx $Xfer 'ConnectAttempts'); ConnectRefused = (& $pvx $Xfer 'ConnectRefused'); ConnectedAfterMs = (& $pvx $Xfer 'ConnectedAfterMs')
                              H2dMs = (& $pvx (& $pvx $Xfer 'H2d') 'Ms'); D2hMs = (& $pvx (& $pvx $Xfer 'D2h') 'Ms') }
        if ($null -ne $dv) {
            $svc = [string](& $pvx $dv 'Service'); $inf = [string](& $pvx $dv 'InfPath')
            if ((& $pvx $ad 'MacMatches') -ne $true) { $rev.Add("PC: the adapter's MAC '$(ConvertTo-FsN1P ([string](& $pvx $a2 'Mac')))' is not the gadget's host_addr") }
            if ($svc -ceq 'UsbNcm' -and $inf -ceq 'usbncm.inf') { $facts.Add("PC: the adapter '$(ConvertTo-FsN1P ([string](& $pvx $a2 'Description')))' (ifIndex $(& $pvx $a2 'IfIndex')) uses the inbox driver UsbNcm (usbncm.inf $(& $pvx $dv 'DriverVersion')); MAC $(& $pvx $a2 'Mac') (host_addr match: $(& $pvx $ad 'MacMatches'))") }
            else { $rev.Add("PC: the adapter's driver is '$(ConvertTo-FsN1P $svc)' ($(ConvertTo-FsN1P $inf)), not the inbox UsbNcm (usbncm.inf): any driver install is a PM decision") }
        } elseif ($hostRes -cne 'ok') { $facts.Add("PC: no adapter of this attempt was ready ($(ConvertTo-FsN1P ([string](& $pvx $ad 'Refusal'))))") }
        # the interface order seen by the PC: the NCM function is the collection starting at interface 2 (MI_02), i.e. ACM
        # (interfaces 0-1, the COM port) comes first as linked; another MI is a REVIEW
        $pnp = [string](& $pvx $a2 'PnpId')
        if ($pnp -cmatch '&MI_02\\') { $facts.Add('PC: the NCM adapter is the USB interface collection MI_02 (ACM is MI_00: the console first)') }
        elseif ($pnp) { $rev.Add("PC: the NCM adapter's PnP id '$(ConvertTo-FsN1P $pnp)' is not interface collection MI_02 (ACM first expected)") }
        if ($tl.Count) { $facts.Add("PC: adapter timeline $(@($tl | ForEach-Object { "+$(& $pvx $_ 'Ms') ms $(& $pvx $_ 'State')" }) -join ' | ')") }
    }

    if ($fails.Count) { $o.Outcome = 'N1 FAIL'; $o.Reason = ($fails -join '; '); return [pscustomobject]$o }
    if ($warn.Count -gt 0 -or $o.WarningCount -gt 0 -or $o.BugCount -gt 0) { $rev.Add("the pre-transfer kernel log (step 3) has $($o.WarningCount) WARNING and $($o.BugCount) BUG/oops-class lines ($($warn.Count) lines listed; FS-R-012 s.3)") }
    if ($o.Wrapped) { $rev.Add("the kernel log had wrapped by step 3 (first line '$(ConvertTo-FsN1P ([string]$o.KmsgFirst))'): earlier lines were not seen") }
    if (@($o.Truncated).Count) { $rev.Add("step output truncated at its cap: $(@($o.Truncated) -join '; ')") }
    if ($rev.Count) { $o.Outcome = 'N1 REVIEW'; $o.Reason = "every N1 fact holds; review before any further run: $($rev -join '; ')" }
    else { $o.Outcome = 'N1 PASS'; $o.Reason = 'every N1 fact holds: the K1a kernel facts and MemTotal, ACM first and NCM second, the link-local-only interface, no listener before or after, the 8 MiB transfer each way with matching SHA-256 on both sides, the kernel log clean before (step 3) and after (step 6) the transfer with continuous coverage; nothing to review' }
    [pscustomobject]$o
}

function Invoke-FsN1ClassifyDir {
    param([Parameter(Mandatory)][string]$CollectDir, [string]$ObserveDir = '', [bool]$AllowReplay = $false)
    $cj = Join-Path $CollectDir 'collect.json'
    if (-not (Test-Path -LiteralPath $cj -PathType Leaf)) { throw "no collect.json in $CollectDir" }
    $c = [IO.File]::ReadAllText($cj) | ConvertFrom-Json
    if ($c.Stage -cne 'n1' -or $c.Exp -cne 'n1') { throw "collect.json is not an N1 session (stage '$($c.Stage)', exp '$($c.Exp)')" }
    $raw = Join-Path $CollectDir 'capture.raw'
    [byte[]]$b = [IO.File]::ReadAllBytes($raw)
    $sha = Get-Fsb1Sha256Hex $b
    $consistent = ($sha -ceq [string]$c.Capture.Sha256) -and [bool]$c.Capture.Consistent
    $fsb1 = $null
    if ($c.ValveSent -and $c.Challenge -cmatch '^[0-9a-f]{32}\z') { $fsb1 = Test-Fsb1Record -Bytes $b -Exp 'n1' -Nonce ([string]$c.Nonce) -Challenge ([string]$c.Challenge) -Steps $script:FsN1Steps }
    $xj = Join-Path $CollectDir 'xfer.json'
    $x = $null; $xsha = ''; $xwhy = ''
    if (Test-Path -LiteralPath $xj -PathType Leaf) {
        try { $x = [IO.File]::ReadAllText($xj) | ConvertFrom-Json; $xsha = Get-FsK1aFileSha $xj } catch { $xwhy = 'xfer.json unreadable' }
        if ($null -ne $x -and ([string]$x.Schema -cne $script:FsN1XferSchema -or [string]$x.Nonce -cne [string]$c.Nonce -or [string]$x.Challenge -cne [string]$c.Challenge)) { $xwhy = 'xfer.json is not this nonce and challenge (or another schema)'; $x = $null }
    } else { $xwhy = 'no xfer.json (the PC side of the transfer)' }
    $collected = ($consistent -and [string]$c.Status -like 'COLLECTED*')
    $o = Get-FsN1Outcome -Fsb1 $fsb1 -Xfer $x -Collected $collected -Nonce ([string]$c.Nonce) -Challenge ([string]$c.Challenge)
    if ($xwhy -and $o.Outcome -cne 'INCONCLUSIVE' -and $o.Outcome -cne 'INTEGRITY FAULT') { $o.Reason = "$xwhy; the record said: $($o.Outcome) ($($o.Reason))"; $o.Outcome = 'INCONCLUSIVE' }
    $isReplay = ($c.PSObject.Properties['Replay'] -and $null -ne $c.Replay) -or ($c.PSObject.Properties['FixtureOverrides'] -and $null -ne $c.FixtureOverrides) -or ($null -ne $x -and [bool]$x.Fixture)
    $bind = @(); $serial = ''; $obSha = ''
    if ($isReplay -and -not $AllowReplay) { $bind += 'collect.json or xfer.json is a replay or a fixture (not a live collection)' }
    # review m2: a live xfer.json is the pinned PowerShell client's, mode ok, to fe80::<nonce> on the ifIndex of the adapter
    # that descends from this attempt's USB device FS-<nonce>
    if (-not $AllowReplay -and $null -ne $x) {
        $xa = if ($x.PSObject.Properties['Adapter']) { $x.Adapter } else { $null }
        $xaa = if ($null -ne $xa -and $xa.PSObject.Properties['Adapter']) { $xa.Adapter } else { $null }
        $par = if ($null -ne $xa -and $xa.PSObject.Properties['Parent']) { [string]$xa.Parent } else { '' }
        $idsB = Get-FsN1Ids ([string]$c.Nonce)
        if ([string]$x.Client -cne 'devices/quest3/host/fs-xfer-n1.ps1' -or [string]$x.Mode -cne 'ok' -or [string]$x.Address -cne $idsB.LinkLocal) { $bind += 'xfer.json was not made by the live PC client (fs-xfer-n1.ps1, mode ok, fe80::<nonce>)' }
        elseif ([string]$x.Result -ceq 'ok' -and ($null -eq $xaa -or $par -ine "USB\VID_1D6B&PID_0104\$($idsB.Serial)" -or [string]$x.ScopeId -cne [string]$xaa.IfIndex)) { $bind += "xfer.json's session was not on the adapter of this attempt's USB device $($idsB.Serial)" }
    }
    if (-not $AllowReplay) {
        $oj = if ($ObserveDir) { Join-Path $ObserveDir 'observe.json' } else { '' }
        if (-not $oj -or -not (Test-Path -LiteralPath $oj -PathType Leaf)) { $bind += 'no observe.json of the attempt (-ObserveDir)' }
        else {
            $ob = [IO.File]::ReadAllText($oj) | ConvertFrom-Json
            if ([string]$ob.Nonce -cne [string]$c.Nonce) { $bind += "observe.json nonce $($ob.Nonce) is not the collected $($c.Nonce)" }
            if ([string]$ob.Stage -cne 'n1') { $bind += "observe.json stage '$($ob.Stage)' is not n1" }
            if (-not (Test-FsN1Unit ([string]$ob.Serial))) { $bind += "observe.json unit '$($ob.Serial)' is not one of the two units" }
            else { $serial = [string]$ob.Serial; $obSha = Get-FsK1aFileSha $oj }
        }
    }
    if ($bind.Count) { $o.Reason = "not tied to a live, observed N1 attempt ($($bind -join '; ')); the record said: $($o.Outcome) ($($o.Reason))"; $o.Outcome = 'INCONCLUSIVE' }
    $o | Add-Member NoteProperty Fixture ([bool]($isReplay -and $AllowReplay))
    $o | Add-Member NoteProperty CaptureSha256 $sha
    $o | Add-Member NoteProperty CaptureConsistent $consistent
    $o | Add-Member NoteProperty Nonce ([string]$c.Nonce)
    $o | Add-Member NoteProperty CollectStatus ([string]$c.Status)
    $o | Add-Member NoteProperty Bound ([bool](-not $AllowReplay -and $bind.Count -eq 0))
    $o | Add-Member NoteProperty Serial $serial
    $o | Add-Member NoteProperty ObserveJsonSha256 $obSha
    $o | Add-Member NoteProperty CollectJsonSha256 (Get-FsK1aFileSha $cj)
    $o | Add-Member NoteProperty XferJsonSha256 $xsha
    $o | Add-Member NoteProperty DoneSent ([bool]$c.DoneSent)
    $o
}

# The outcome record, written once (as K1a's), only for a result bound to a live, observed attempt with phase F.
function Write-FsN1ClassifyRecord([Parameter(Mandatory)]$O, [Parameter(Mandatory)][string]$ObserveDir, [DateTime]$NowUtc = [DateTime]::UtcNow, $After = $null, [string]$ChecklistSha256 = '') {
    if (-not $O.Bound -or $O.Fixture -or -not (Test-FsN1Unit ([string]$O.Serial)) -or $null -eq $After) { return $null }
    $p = Join-Path $ObserveDir 'classify-n1.json'
    if (Test-Path -LiteralPath $p) { throw "classify-n1.json already exists ($p): an outcome record is written once and never replaced" }
    $rec = [ordered]@{ Schema = $script:FsN1ClassifySchema; Utc = $NowUtc.ToUniversalTime().ToString('o'); Nonce = [string]$O.Nonce; Serial = [string]$O.Serial
                       Unit = (Get-FsN1UnitName ([string]$O.Serial)); Outcome = [string]$O.Outcome; Reason = [string]$O.Reason; Fixture = [bool]$O.Fixture
                       MemTotal = $O.MemTotal; CaptureSha256 = [string]$O.CaptureSha256; CollectJsonSha256 = [string]$O.CollectJsonSha256; XferJsonSha256 = [string]$O.XferJsonSha256
                       ObserveJsonSha256 = [string]$O.ObserveJsonSha256; ClassifierSha256 = (Get-FsK1aFileSha (Join-Path $script:FsN1ClsDir 'fs-classify-n1.ps1'))
                       BannerSha256 = (Get-FsK1aTextSha $script:FsK1aPinBanner); ConfigSha = $script:FsK1aPinConfigSha; Modules = [string]$script:FsK1aPinModules
                       KmsgPost = $(if ($O.PSObject.Properties['KmsgPost'] -and $null -ne $O.KmsgPost) { [ordered]@{ Read = $O.KmsgPost.Read; Rc = $O.KmsgPost.Rc; Lines = $O.KmsgPost.Lines; First = $O.KmsgPost.First; Coverage = $O.KmsgPost.Coverage
                                                                       WarningCount = $O.KmsgPost.WarningCount; BugCount = $O.KmsgPost.BugCount; MatchLines = $O.KmsgPost.MatchLines; Listed = @($O.KmsgPost.Listed); Missing = $O.KmsgPost.Missing } } else { $null })
                       After = $After; ChecklistSha256 = $ChecklistSha256 }
    [byte[]]$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((($rec | ConvertTo-Json -Depth 8) + "`n"))
    $fs = [IO.File]::Open($p, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    $p
}

# The attempt's after-session facts: exactly one PASS phase F entry of THIS nonce in the attempt's checklist-n1.json,
# written by the pinned the N1 sign-off tooling (private) (as fs-classify-k1a.ps1's Get-FsK1aAfterFacts).
function Get-FsN1AfterFacts([string]$ObserveDir, [string]$Nonce, [string]$Serial) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; After = $null; Sha256 = $null } }
    $pv = { param($o, [string]$n) if ($null -ne $o -and $o -is [psobject] -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    try { $ob = [IO.File]::ReadAllText((Join-Path $ObserveDir 'observe.json')) | ConvertFrom-Json } catch { return (& $no 'observe.json unreadable') }
    $cf = [string](& $pv $ob 'ChecklistFile')
    if (-not $cf -or -not (Test-Path -LiteralPath $cf -PathType Leaf)) { return (& $no "the attempt's checklist '$cf' is missing") }
    try { $j = [IO.File]::ReadAllText($cf) | ConvertFrom-Json } catch { return (& $no "the checklist $cf is unreadable") }
    $fs = @(@(& $pv $j 'Entries') | Where-Object { [string](& $pv $_ 'Phase') -ceq 'F' -and [string](& $pv $_ 'Result') -ceq 'PASS' -and [string](& $pv $_ 'Nonce') -ceq $Nonce })
    if ($fs.Count -eq 0) { return (& $no "phase F (after the session) has not passed for nonce $Nonce in ${cf}: run the N1 sign-off tooling (private) -Phase F once the follow-ups are finished, then classify again") }
    if ($fs.Count -ne 1) { return (& $no "${cf} holds $($fs.Count) PASS phase F entries for nonce $Nonce (exactly one is allowed)") }
    $f = $fs[0]
    if ([string](& $pv $f 'Serial') -cne $Serial) { return (& $no "the phase F entry of $cf is for unit '$(& $pv $f 'Serial')', not $Serial") }
    if ([string](& $pv $f 'ToolSha256') -cne (Get-FsK1aFileSha (Join-Path $script:FsN1ClsDir 'the N1 sign-off tooling (private)'))) { return (& $no "the phase F entry of $cf was not written by the pinned the N1 sign-off tooling (private)") }
    $a = & $pv $f 'After'
    if ($null -eq $a) { return (& $no "the phase F entry of $cf holds no after-session facts") }
    [pscustomobject]@{ Ok = $true; Why = "phase F of $cf"; After = $a; Sha256 = (Get-FsK1aFileSha $cf) }
}

if ($script:FsN1ClsInvocation -eq '.') { return }
$exit = 70
try {
    if (-not $CollectDir) { Write-Output 'usage: fs-classify-n1.ps1 -CollectDir <dir> [-ObserveDir <dir>]'; exit 64 }
    if ($ObserveDir) {
        $rx0 = Join-Path $ObserveDir 'classify-n1.json'
        if (Test-Path -LiteralPath $rx0) {
            $ox = try { [string]([IO.File]::ReadAllText($rx0) | ConvertFrom-Json).Outcome } catch { 'unreadable' }
            Write-Output "NOT RECORDED: the outcome record $rx0 already exists (recorded outcome: $ox) and is kept; this run classifies and records nothing"; exit 64 }
    }
    $o = Invoke-FsN1ClassifyDir -CollectDir $CollectDir -ObserveDir $ObserveDir -AllowReplay ([bool]$AllowReplay)
    if ($o.Fixture) { Write-Output 'FIXTURE: an offline replay (-AllowReplay): not a run result' }
    Write-Output "OUTCOME: $($o.Outcome)"
    Write-Output (ConvertTo-FsN1P "REASON:  $($o.Reason)")
    Write-Output "NONCE:   $($o.Nonce)  capture sha256=$($o.CaptureSha256) consistent=$($o.CaptureConsistent)  collector=$($o.CollectStatus) fs-done-sent=$($o.DoneSent)  xfer.json sha256=$($o.XferJsonSha256)"
    foreach ($f in $o.Facts) { Write-Output (ConvertTo-FsN1P "FACT:    $f") }
    foreach ($f in $o.Failing) { Write-Output (ConvertTo-FsN1P "FAILING: $f") }
    foreach ($f in $o.Review) { Write-Output (ConvertTo-FsN1P "REVIEW:  $f") }
    Write-Output "MEMTOTAL: $(if ($o.MemTotal) { $o.MemTotal } else { 'NOT VALID (FS-R-013 s.2: blocks progression)' })"
    Write-Output "KERNEL WARNINGS (FS-R-012 s.3): $(if ($null -ne $o.WarningCount) { "$($o.WarningCount) WARNING, $($o.BugCount) BUG/oops-class, $($o.Warnings.Count) lines" } else { 'not reported' })"
    foreach ($w in $o.Warnings) { Write-Output "  $w" }
    $kq = $o.KmsgPost
    Write-Output "KERNEL LOG AFTER THE TRANSFER (step 6, FS-R-014 s.5): $(if ($null -eq $kq -or -not $kq.Present) { 'NOT REPORTED' } elseif ($kq.Read -cne 'ok') { "read=$($kq.Read) rc=$($kq.Rc) $($kq.Missing)" } else { "$($kq.Lines) lines, coverage $($kq.Coverage); $($kq.WarningCount) WARNING, $($kq.BugCount) BUG/oops-class, $($kq.MatchLines) matching lines ($($kq.ListedCount) listed)$(if ($kq.Missing) { "; $($kq.Missing)" })" })"
    if ($null -ne $kq) { foreach ($w in @($kq.Listed)) { Write-Output (ConvertTo-FsN1P "  $w") } }
    if ($null -ne $o.Xfer) { Write-Output "TRANSFER: device result $($o.Xfer.DeviceResult), rx $($o.Xfer.RxMs) ms, tx $($o.Xfer.TxMs) ms; PC $(if ($null -ne $o.Host) { "$($o.Host.Result), up $($o.Host.H2dMs) ms, down $($o.Host.D2hMs) ms, connects $($o.Host.ConnectAttempts) (refused $($o.Host.ConnectRefused))" } else { 'no xfer.json' })" }
    Write-Output 'MACHINE SIDE ONLY: the return to fastboot is checked at AF (<withheld capture tool> -Phase AF)'
    $aft = $null
    if ($ObserveDir -and $o.Bound) { $aft = Get-FsN1AfterFacts $ObserveDir $o.Nonce $o.Serial; if (-not $aft.Ok) { Write-Output "NOT RECORDED: $($aft.Why)" } }
    if ($ObserveDir -and $o.Bound -and $aft.Ok) { $rp = Write-FsN1ClassifyRecord -O $o -ObserveDir $ObserveDir -After $aft.After -ChecklistSha256 $aft.Sha256; if ($rp) { Write-Output "RECORDED: $rp (unit $(Get-FsN1UnitName $o.Serial) $($o.Serial); report this result to the PM before any further N1 attempt)" } }
    $exit = switch ($o.Outcome) { 'N1 PASS' { 40 } 'N1 REVIEW' { 41 } 'N1 FAIL' { 42 } 'INTEGRITY FAULT' { 43 } default { 44 } }
} catch {
    Write-Output (ConvertTo-FsN1P "ERROR: $($_.Exception.Message)")
    $exit = 70
}
exit $exit
