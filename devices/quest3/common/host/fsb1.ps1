# FrameShift FSB1 record decoder / validator (Windows PowerShell 5.1).
# Spec: devices/quest3/common/FSB1-SPEC.md. Dot-source beside
# devices/quest3/stage1/fs-proto.ps1. Pure functions; no I/O except what the
# caller passes in. Twin of tools/fsb1.py: both must give the same verdict and
# the same first rejection reason for every input (host/test-fsb1.ps1).
#
#   $r = Test-Fsb1Record -Bytes $b -Exp stage2a -Nonce $n -Challenge $c -Steps @('hash','diag',...)
#   $r.Ok (bool), $r.Reason ('valid' or a rejection code), $r.Detail, $r.Steps
#   Each step: hashtable with the STEP fields plus 'out' and 'err' (byte[]).
Set-StrictMode -Version 2.0

$script:Fsb1MaxBytes = 8MB
$script:Fsb1N  = '(0|[1-9][0-9]{0,14})'
$script:Fsb1SN = '(-1|0|[1-9][0-9]{0,14})'
$script:Fsb1ReBegin = [regex]('^FSB1 BEGIN v=' + $script:Fsb1N + ' exp=([a-z0-9_]{1,16}) nonce=([0-9a-f]{16}) chal=([0-9a-f]{32}) steps=' + $script:Fsb1N + '\z')
$script:Fsb1ReEnd   = [regex]('^FSB1 END v=' + $script:Fsb1N + ' nonce=([0-9a-f]{16}) chal=([0-9a-f]{32}) lines=' + $script:Fsb1N + ' rec_sha256=([0-9a-f]{64})\z')
$script:Fsb1ReStep  = [regex]('^FSB1 STEP i=' + $script:Fsb1N + ' id=([a-z0-9_]{1,16})' +
    ' end=(exited|signaled|timer-term|timer-kill|exec-failed|unreaped|refused|internal|nosup)' +
    ' code=' + $script:Fsb1SN + ' sig=' + $script:Fsb1N + ' errno=' + $script:Fsb1N + ' ms=' + $script:Fsb1SN +
    ' term_ms=' + $script:Fsb1SN + ' kill_ms=' + $script:Fsb1SN + ' out_total=' + $script:Fsb1N + ' out_kept=' + $script:Fsb1N +
    ' err_total=' + $script:Fsb1N + ' err_kept=' + $script:Fsb1N + ' strays=' + $script:Fsb1N +
    ' pipes=(eof|open|none) why=([a-z-]{1,32})' +
    ' out_len=' + $script:Fsb1N + ' out_sha256=([0-9a-f]{64}) err_len=' + $script:Fsb1N + ' err_sha256=([0-9a-f]{64})\z')
$script:Fsb1ReData  = [regex]('^FSB1 DATA i=' + $script:Fsb1N + ' s=([oe]) n=' + $script:Fsb1N + ' ([A-Za-z0-9+/=]{1,64})\z')
$script:Fsb1ReBadChar = [regex]'[^\x20-\x7e]'
$script:Fsb1StepKeys = @('i','id','end','code','sig','errno','ms','term_ms','kill_ms','out_total','out_kept',
                         'err_total','err_kept','strays','pipes','why','out_len','out_sha256','err_len','err_sha256')
$script:Fsb1IntKeys  = @('i','code','sig','errno','ms','term_ms','kill_ms','out_total','out_kept',
                         'err_total','err_kept','strays','out_len','err_len')

function Get-Fsb1Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

function Stop-Fsb1 { param([string]$Reason, [string]$Detail = '') throw "FSB1REJECT|$Reason|$Detail" }

function Test-Fsb1Consistent {
    param([hashtable]$St)
    foreach ($n in 'out', 'err') { if ($St["$($n)_kept"] -gt $St["$($n)_total"]) { return $false } }
    switch ($St['end']) {
        'exited'     { return ($St['code'] -ge 0 -and $St['code'] -le 255 -and $St['sig'] -eq 0 -and $St['term_ms'] -eq -1 -and $St['kill_ms'] -eq -1) }
        'signaled'   { return ($St['code'] -eq -1 -and $St['sig'] -gt 0 -and $St['term_ms'] -eq -1 -and $St['kill_ms'] -eq -1) }
        'timer-term' { return ($St['term_ms'] -ge 0 -and $St['kill_ms'] -eq -1) }
        'timer-kill' { return ($St['term_ms'] -ge 0 -and $St['kill_ms'] -ge 0) }
    }
    return $true
}

function Complete-Fsb1Step {
    param([hashtable]$St)
    foreach ($sx in 'o', 'e') {
        $name = if ($sx -eq 'o') { 'out' } else { 'err' }
        $chunks = $St['chunks'][$sx]
        for ($k = 0; $k -lt $chunks.Count - 1; $k++) {
            if ($chunks[$k].Length -ne 64) { Stop-Fsb1 'bad-data' "step $($St['i']) $($name): short line before the last" }
        }
        $joined = -join $chunks
        [byte[]]$dec = @()
        if ($joined.Length -gt 0) {
            if ($chunks[$chunks.Count - 1].Length % 4) { Stop-Fsb1 'bad-data' "step $($St['i']) $($name): last line length" }
            try { $dec = [Convert]::FromBase64String($joined) } catch { Stop-Fsb1 'bad-data' "step $($St['i']) $($name): base64" }
            if ([Convert]::ToBase64String($dec) -cne $joined) { Stop-Fsb1 'bad-data' "step $($St['i']) $($name): non-canonical base64" }
        }
        if ($dec.Length -ne $St["$($name)_len"]) { Stop-Fsb1 'length-mismatch' "step $($St['i']) $($name): decoded $($dec.Length)" }
        if ($St['end'] -cne 'nosup' -and $St["$($name)_len"] -ne $St["$($name)_kept"]) { Stop-Fsb1 'length-mismatch' "step $($St['i']) $($name): len vs kept" }
        if ((Get-Fsb1Sha256Hex $dec) -cne $St["$($name)_sha256"]) { Stop-Fsb1 'payload-hash' "step $($St['i']) $name" }
        $St[$name] = $dec
    }
    $St.Remove('chunks'); $St.Remove('phase')
}

function Test-Fsb1Record {
    param([byte[]]$Bytes, [Parameter(Mandatory)][string]$Exp, [Parameter(Mandatory)][string]$Nonce,
          [Parameter(Mandatory)][string]$Challenge, [Parameter(Mandatory)][string[]]$Steps)
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    try {
        if ($Bytes.Length -gt $script:Fsb1MaxBytes) { Stop-Fsb1 'too-large' "$($Bytes.Length) bytes" }
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)
        $pieces = $text.Split([char]10)
        $lines = New-Object System.Collections.Generic.List[object]
        for ($k = 0; $k -lt $pieces.Length - 1; $k++) { $lines.Add([pscustomobject]@{ T = $pieces[$k].TrimEnd([char]13); Term = $true }) }
        if ($pieces[$pieces.Length - 1] -ne '') { $lines.Add([pscustomobject]@{ T = $pieces[$pieces.Length - 1].TrimEnd([char]13); Term = $false }) }
        $ord = [System.StringComparison]::Ordinal

        $begins = @(for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k].T.StartsWith('FSB1 BEGIN', $ord)) { $k } })
        if ($begins.Count -eq 0) { Stop-Fsb1 'no-begin' }
        if ($begins.Count -gt 1) { Stop-Fsb1 'multiple-begin' "$($begins.Count) BEGIN lines" }
        $b = $begins[0]; $e = -1
        for ($k = $b + 1; $k -lt $lines.Count; $k++) {
            if ($lines[$k].T.StartsWith('FSB1 END', $ord) -and $lines[$k].Term) { $e = $k; break }
        }
        if ($e -lt 0) { Stop-Fsb1 'no-end' }
        for ($k = 0; $k -lt $lines.Count; $k++) {
            if (($k -lt $b -or $k -gt $e) -and $lines[$k].T.Contains('FSB1')) { Stop-Fsb1 'stray-fsb1-line' "line $($k + 1)" }
        }
        $rec = @(for ($k = $b; $k -le $e; $k++) { $lines[$k].T })
        for ($k = 0; $k -lt $rec.Count; $k++) {
            if ($script:Fsb1ReBadChar.IsMatch($rec[$k])) { Stop-Fsb1 'bad-char' "record line $($k + 1)" }
        }

        $m = $script:Fsb1ReEnd.Match($rec[$rec.Count - 1])
        if (-not $m.Success) { Stop-Fsb1 'bad-end' }
        if ($m.Groups[1].Value -cne '1') { Stop-Fsb1 'version' "END v=$($m.Groups[1].Value)" }
        $enonce = $m.Groups[2].Value; $echal = $m.Groups[3].Value
        if ([long]$m.Groups[4].Value -ne $rec.Count - 1) { Stop-Fsb1 'line-count' "END lines=$($m.Groups[4].Value)" }
        $sb = New-Object System.Text.StringBuilder
        for ($k = 0; $k -lt $rec.Count - 1; $k++) { $null = $sb.Append($rec[$k]).Append("`n") }
        if ((Get-Fsb1Sha256Hex ([System.Text.Encoding]::ASCII.GetBytes($sb.ToString()))) -cne $m.Groups[5].Value) { Stop-Fsb1 'rec-hash' }

        $m = $script:Fsb1ReBegin.Match($rec[0])
        if (-not $m.Success) { Stop-Fsb1 'bad-begin' }
        if ($m.Groups[1].Value -cne '1') { Stop-Fsb1 'version' "BEGIN v=$($m.Groups[1].Value)" }
        if ($m.Groups[2].Value -cne $Exp) { Stop-Fsb1 'exp-mismatch' $m.Groups[2].Value }
        if ($m.Groups[3].Value -cne $Nonce -or $enonce -cne $Nonce) { Stop-Fsb1 'nonce-mismatch' }
        if ($m.Groups[4].Value -cne $Challenge -or $echal -cne $Challenge) { Stop-Fsb1 'chal-mismatch' }
        if ([long]$m.Groups[5].Value -ne $Steps.Count) { Stop-Fsb1 'step-count' "BEGIN steps=$($m.Groups[5].Value)" }

        $out = New-Object System.Collections.Generic.List[hashtable]
        $seen = @{}; $cur = $null
        for ($k = 1; $k -lt $rec.Count - 1; $k++) {
            $t = $rec[$k]
            if ($t.StartsWith('FSB1 STEP ', $ord)) {
                $m = $script:Fsb1ReStep.Match($t)
                if (-not $m.Success) { Stop-Fsb1 'bad-step' }
                if ($null -ne $cur) { Complete-Fsb1Step $cur }
                $st = @{}
                for ($g = 0; $g -lt $script:Fsb1StepKeys.Count; $g++) {
                    $key = $script:Fsb1StepKeys[$g]; $v = $m.Groups[$g + 1].Value
                    if ($script:Fsb1IntKeys -contains $key) { $st[$key] = [long]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) } else { $st[$key] = $v }
                }
                if ($seen.ContainsKey($st['id'])) { Stop-Fsb1 'duplicate-step' $st['id'] }
                if ($st['i'] -ne $out.Count + 1) { Stop-Fsb1 'step-order' "i=$($st['i'])" }
                if ($st['i'] -gt $Steps.Count) { Stop-Fsb1 'step-count' 'more steps than expected' }
                if ($st['id'] -cne $Steps[$st['i'] - 1]) { Stop-Fsb1 'step-id' "i=$($st['i']) id=$($st['id'])" }
                if (-not (Test-Fsb1Consistent $st)) { Stop-Fsb1 'step-inconsistent' "step $($st['i'])" }
                $seen[$st['id']] = $true
                $st['chunks'] = @{ o = (New-Object System.Collections.Generic.List[string]); e = (New-Object System.Collections.Generic.List[string]) }
                $st['phase'] = 'o'
                $cur = $st; $out.Add($st)
            } elseif ($t.StartsWith('FSB1 DATA ', $ord)) {
                $m = $script:Fsb1ReData.Match($t)
                if (-not $m.Success) { Stop-Fsb1 'bad-data' }
                if ($null -eq $cur) { Stop-Fsb1 'bad-line' 'DATA before any STEP' }
                $di = [long]$m.Groups[1].Value; $ds = $m.Groups[2].Value; $dn = [long]$m.Groups[3].Value
                if ($di -ne $cur['i']) { Stop-Fsb1 'data-order' "DATA i=$di inside step $($cur['i'])" }
                if ($ds -ceq 'o' -and $cur['phase'] -ceq 'e') { Stop-Fsb1 'data-order' 'stdout DATA after stderr DATA' }
                if ($ds -ceq 'e') { $cur['phase'] = 'e' }
                if ($dn -ne $cur['chunks'][$ds].Count) { Stop-Fsb1 'data-order' "step $($cur['i']) s=$ds n=$dn" }
                $cur['chunks'][$ds].Add($m.Groups[4].Value)
            } else {
                Stop-Fsb1 'bad-line'
            }
        }
        if ($null -ne $cur) { Complete-Fsb1Step $cur }
        if ($out.Count -ne $Steps.Count) { Stop-Fsb1 'step-count' "$($out.Count) steps" }
        return [pscustomobject]@{ Ok = $true; Reason = 'valid'; Detail = ''; Steps = $out.ToArray() }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -clike 'FSB1REJECT|*') {
            $p = $msg.Split('|', 3)
            return [pscustomobject]@{ Ok = $false; Reason = $p[1]; Detail = $p[2]; Steps = $null }
        }
        return [pscustomobject]@{ Ok = $false; Reason = 'decoder-fault'; Detail = $msg; Steps = $null }
    }
}
