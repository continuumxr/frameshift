# FrameShift - stage-3d carry-over library (Windows PowerShell 5.1): the session/collector TOOL SET of J-143 and the
# "made" record that every sound check and rehearsal carries (review of 14107af, MAJOR-1). Dot-sourced by
# fs-collect3d.ps1 (which writes the records) and fs-checklist3d.ps1 (which checks them). No param block (it binds
# nothing in its callers' scope), no device command, no network. The file is ASCII.
#
# The tool set: fs-session3c.ps1 (the sound check, the prompts) and fs-collect3d.ps1 (the rehearsals) with every file
# they dot-source (this file among them; test-host3d H13 derives the closure from the sources and compares), and the two
# rehearsal replays. Its SHA-256 is the SHA-256 of the lines "<sha256 or 'missing'>  <path>" in this order, LF, UTF-8.
Set-StrictMode -Version 2.0
$script:FsCarry3dToolSetFiles = @(
    'devices\quest3\host\fs-session3c.ps1', 'devices\quest3\host\fs-native.ps1',
    'devices\quest3\host\fs-collect3d.ps1', 'devices\quest3\host\fs-collect3c.ps1', 'devices\quest3\host\fs-collect.ps1',
    'devices\quest3\host\fs-session3d.ps1', 'devices\quest3\host\fs-classify3d.ps1', 'devices\quest3\host\fs-classify3c.ps1',
    'devices\quest3\host\fs-classify.ps1', 'devices\quest3\host\fs-classify3b.ps1', 'devices\quest3\host\fs-carry3d.ps1',
    'devices\quest3\stage1\fs-proto.ps1', 'devices\quest3\common\host\fsb1.ps1',
    'devices\quest3\host\fixtures\stage3d\replay\garbled-r3\capture.raw', 'devices\quest3\host\fixtures\stage3d\replay\garbled-r3\capture.raw.idx',
    'devices\quest3\host\fixtures\stage3d\replay\nominal-read\capture.raw', 'devices\quest3\host\fixtures\stage3d\replay\nominal-read\capture.raw.idx')
# the repository of this file (fixtures pass another root)
$script:FsCarry3dRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$script:FsCarry3dSoundSchema = 'frameshift.fs-soundcheck3d.v1'
function Get-FsCarry3dSha([string]$Path) { try { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLower() } catch { $null } }
function Get-FsCarry3dToolSet([string]$Root = $script:FsCarry3dRoot) {
    $rows = @(foreach ($f in $script:FsCarry3dToolSetFiles) { $h = Get-FsCarry3dSha (Join-Path $Root $f); [ordered]@{ File = $f; Sha256 = $(if ($h) { $h } else { 'missing' }) } })
    $txt = [string[]]@($rows | ForEach-Object { "$($_.Sha256)  $($_.File)" })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $s = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($txt -join "`n"))) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    [pscustomobject]@{ Sha256 = $s; Files = $rows }
}
# The last line of a rehearsal summary.txt: when it was made (UTC), with which tool set, and which replay was rehearsed
# (its SHA-256 and path; delta review of 6f2973f, MINOR-1). The replays a rehearsal must use, by kind:
$script:FsCarry3dReplays = @{ 'rehearsal' = 'devices\quest3\host\fixtures\stage3d\replay\garbled-r3\capture.raw'; 'rehearsal-read' = 'devices\quest3\host\fixtures\stage3d\replay\nominal-read\capture.raw' }
function Get-FsCarry3dRecordLine([DateTime]$MadeUtc, [string]$ToolSetSha256, [string]$ReplaySha256, [string]$ReplayPath) {
    "REHEARSAL MADE: $($MadeUtc.ToUniversalTime().ToString('o')) with tool set $ToolSetSha256 replay $(if ($ReplaySha256) { $ReplaySha256 } else { 'none' }) $(if ($ReplayPath) { $ReplayPath } else { '-' })"
}
# Reads the made record of a rehearsal summary (exactly one line) or a stage-3d soundcheck.json. Returns @{ Ok; Why; MadeUtc; ToolSetSha256 }.
function Read-FsCarry3dMade([string]$Kind, [string]$Path) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w; MadeUtc = $null; ToolSetSha256 = $null; ReplaySha256 = $null; ReplayPath = $null } }
    $rs = $null; $rpth = $null
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (& $no "missing: $Path") }
    $re = '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z\z'
    $parse = { param([string]$u) if ($u -cnotmatch $re) { return $null }; try { [DateTime]::ParseExact($u, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal') } catch { $null } }
    if ($Kind -ceq 'soundcheck') {
        try { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return (& $no "unreadable: $Path") }
        $sch = if ($j.PSObject.Properties['Schema']) { [string]$j.Schema } else { '' }
        if ($sch -cne $script:FsCarry3dSoundSchema) { return (& $no "$Path is not a stage-3d sound check ($script:FsCarry3dSoundSchema, written by fs-collect3d.ps1 -S3dSoundCheck; schema '$sch' records no time or tool set)") }
        $m = if ($j.PSObject.Properties['MadeUtc']) { & $parse ([string]$j.MadeUtc) } else { $null }
        $t = if ($j.PSObject.Properties['ToolSetSha256']) { [string]$j.ToolSetSha256 } else { '' }
    } else {
        $ls = @([IO.File]::ReadAllLines($Path) | Where-Object { $_ -cmatch '^REHEARSAL MADE: ' })
        if ($ls.Count -ne 1) { return (& $no "$Path has $($ls.Count) 'REHEARSAL MADE:' lines (exactly 1 expected: a rehearsal by the stage-3d collector of J-143 records when and with which tools it was made)") }
        $mm = [regex]::Match($ls[0], '^REHEARSAL MADE: (\S+) with tool set ([0-9a-f]{64}) replay ([0-9a-f]{64}) (\S.*)\z')
        $m = if ($mm.Success) { & $parse $mm.Groups[1].Value } else { $null }
        $t = if ($mm.Success) { $mm.Groups[2].Value } else { '' }
        if (-not $mm.Success) { return (& $no "$Path has no valid 'REHEARSAL MADE: <utc> with tool set <sha256> replay <sha256> <path>' line") }
        $rs = $mm.Groups[3].Value; $rpth = $mm.Groups[4].Value
    }
    if ($null -eq $m -or $t -cnotmatch '^[0-9a-f]{64}\z') { return (& $no "$Path has no valid made time or tool-set SHA-256") }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; MadeUtc = $m; ToolSetSha256 = $t; ReplaySha256 = $rs; ReplayPath = $rpth }
}
