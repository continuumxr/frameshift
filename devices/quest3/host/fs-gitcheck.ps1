# FrameShift E1: clean-checkout check for a pinned third-party git checkout
# (Windows PowerShell 5.1). Twin of fs-gitcheck.sh (the builder runs bash in
# WSL; that copy is what a builder sources).
#
# FS-A-005 §8 E1 / FS-R-005 §5 E1 (accepted): `-c core.worktree="$AOSP"` does
# NOT override a core.worktree set in the checkout's own .git/config. The
# correction, applied here:
#   - every git call is `git --git-dir=<repo>/.git --work-tree=<repo> ...`;
#   - GIT_DIR and GIT_WORK_TREE are removed from the child's environment;
#   - a core.worktree regression negative (test-host2.ps1 G6, fixtures/gitcheck).
#
# Revision 2 (adversarial review of da0ad56, SHOULD-FIX 2). The check no longer
# trusts git's own view of "clean":
#   - GIT_NO_REPLACE_OBJECTS=1, and any refs/replace/* ref is refused
#     (`git replace <pin> <evil>` made HEAD==pin and status clean);
#   - .git/info/grafts and .git/objects/info/alternates are refused;
#   - the configuration git reads is only the repository's own:
#     GIT_CONFIG_NOSYSTEM=1, GIT_CONFIG_GLOBAL=NUL; GIT_CONFIG_SYSTEM,
#     GIT_ATTR_SOURCE, HOME, XDG_CONFIG_HOME, GIT_REPLACE_REF_BASE removed;
#   - EVERY blob of the pinned tree (`ls-tree -r <pin>`) is compared with
#     `git hash-object --no-filters` of the work-tree file. Clean filters,
#     .gitattributes / info/attributes, autocrlf and core.fileMode cannot
#     hide a difference;
#   - a filesystem walk (independent of git's index and ignore rules)
#     refuses any file that is not in the pinned tree, and any link or
#     junction;
#   - mode bits: NOT checkable from Windows (NTFS has no exec bit). This is
#     reported in Evidence.mode_bits; fs-gitcheck.sh enforces them on file
#     systems that store them;
#   - non-blob entries (submodules) and symlink entries are refused.
# Kept: HEAD = the pinned commit, core.worktree in the repository config
# refused, status --porcelain --ignored --untracked-files=all empty,
# ls-files -v only "H ", rev-parse top level / git dir, .git a real directory.
#
#   . fs-gitcheck.ps1; $r = Test-FsGitCheckout -Repo C:\path\repo -ExpectCommit <40 hex>
#   $r.Ok, $r.Failures (every failed check, not only the first), $r.Evidence
#   CLI: fs-gitcheck.ps1 -Repo <dir> -ExpectCommit <sha>  -> exit 0 clean, 1 refused, 64 usage, 70 internal error
param([string]$Repo, [string]$ExpectCommit, [string]$GitExe = 'git')
Set-StrictMode -Version 2.0

$script:FsGitScrubVars = @('GIT_DIR', 'GIT_WORK_TREE',                       # E1 (required)
    'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
    'GIT_COMMON_DIR', 'GIT_NAMESPACE', 'GIT_CEILING_DIRECTORIES', 'GIT_DISCOVERY_ACROSS_FILESYSTEM',
    'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT', 'GIT_CONFIG', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM',
    'GIT_ATTR_SOURCE', 'GIT_REPLACE_REF_BASE', 'GIT_NO_REPLACE_OBJECTS', 'HOME', 'XDG_CONFIG_HOME', 'GIT_EXTERNAL_DIFF')
$script:FsGitSetVars = [ordered]@{ GIT_NO_REPLACE_OBJECTS = '1'; GIT_CONFIG_NOSYSTEM = '1'; GIT_CONFIG_GLOBAL = 'NUL'; GIT_OPTIONAL_LOCKS = '0' }

# Runs git with an explicit argument vector, a scrubbed environment and
# optional stdin text. The caller's own environment is not modified.
function Invoke-FsGit {
    param([string]$GitExe, [string[]]$ArgList, [int]$TimeoutMs = 60000, [string]$StdIn = $null)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $GitExe
    $psi.Arguments = (($ArgList | ForEach-Object {
        if ($_ -eq '') { '""' } elseif ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = ($null -ne $StdIn)
    foreach ($v in $script:FsGitScrubVars) { if ($psi.EnvironmentVariables.ContainsKey($v)) { $psi.EnvironmentVariables.Remove($v) } }
    foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ($k -match '^GIT_CONFIG_(KEY|VALUE)_\d+$') { $psi.EnvironmentVariables.Remove($k) } }
    foreach ($k in $script:FsGitSetVars.Keys) { $psi.EnvironmentVariables[$k] = $script:FsGitSetVars[$k] }
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi
    try { $null = $p.Start() } catch { return [pscustomobject]@{ Code = -1; Out = ''; Err = $_.Exception.Message } }
    try {
        $to = $p.StandardOutput.ReadToEndAsync(); $te = $p.StandardError.ReadToEndAsync()
        if ($null -ne $StdIn) { $sb = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StdIn); $p.StandardInput.BaseStream.Write($sb, 0, $sb.Length); $p.StandardInput.Close() }   # bytes: no BOM
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {}; return [pscustomobject]@{ Code = -2; Out = ''; Err = 'timeout' } }
        $p.WaitForExit()
        return [pscustomobject]@{ Code = $p.ExitCode; Out = $to.Result; Err = $te.Result }
    } finally { $p.Dispose() }
}

function ConvertTo-FsGitPath { param([string]$P)   # comparable form of a path git prints
    $x = $P.Trim() -replace '\\', '/'
    $x = $x.TrimEnd('/')
    return $x.ToLowerInvariant()
}

function Test-FsGitCheckout {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$ExpectCommit, [string]$GitExe = 'git')
    $ErrorActionPreference = 'Stop'
    $fail = New-Object System.Collections.Generic.List[string]
    $ev = [ordered]@{}
    $done = { [pscustomobject]@{ Ok = ($fail.Count -eq 0); Failures = $fail.ToArray(); Evidence = $ev } }
    try {
        if ($ExpectCommit -cnotmatch '^[0-9a-f]{40}\z') { $fail.Add('pinned commit is not 40 lowercase hex'); return (& $done) }
        if (-not [IO.Path]::IsPathRooted($Repo)) { $fail.Add("repository path is not absolute: $Repo"); return (& $done) }
        $Repo = [IO.Path]::GetFullPath($Repo).TrimEnd('\', '/')
        $gd = Join-Path $Repo '.git'
        $item = Get-Item -LiteralPath $gd -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { $fail.Add('no .git in the repository'); return (& $done) }
        if (-not $item.PSIsContainer) { $fail.Add('.git is a file (gitfile redirect), not a directory') }
        elseif ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $fail.Add('.git is a link or junction, not a real directory') }
        if ($fail.Count) { return (& $done) }
        foreach ($f in @('info\grafts', 'objects\info\alternates')) {
            if (Test-Path -LiteralPath (Join-Path $gd $f)) { $fail.Add(".git\$f exists (object substitution)") }
        }

        $base = @("--git-dir=$gd", "--work-tree=$Repo", '-c', 'core.fsmonitor=false', '-c', 'status.showUntrackedFiles=all')

        $c = Invoke-FsGit $GitExe @('config', '--file', (Join-Path $gd 'config'), '--includes', '--get-all', 'core.worktree')
        $ev.config_core_worktree = $c.Out.Trim()
        if ($c.Code -eq 0 -and $c.Out.Trim()) { $fail.Add("core.worktree is set in the repository config: $($c.Out.Trim())") }
        elseif ($c.Code -ne 0 -and $c.Code -ne 1) { $fail.Add("git config read failed (rc $($c.Code)): $($c.Err.Trim())") }

        $rr = Invoke-FsGit $GitExe ($base + @('for-each-ref', '--format=%(refname)', 'refs/replace/'))
        if ($rr.Code -ne 0) { $fail.Add("for-each-ref refs/replace failed (rc $($rr.Code))") }
        elseif ($rr.Out.Trim()) { $fail.Add('replace refs present (refs/replace): ' + (($rr.Out.Trim() -split "`n" | Select-Object -First 3) -join '; ')) }

        $t = Invoke-FsGit $GitExe ($base + @('rev-parse', '--show-toplevel'))
        $ev.toplevel = $t.Out.Trim()
        if ($t.Code -ne 0) { $fail.Add("rev-parse --show-toplevel failed (rc $($t.Code)): $($t.Err.Trim())") }
        elseif ((ConvertTo-FsGitPath $t.Out) -cne (ConvertTo-FsGitPath $Repo)) { $fail.Add("work tree is $($t.Out.Trim()), not $Repo") }

        $g = Invoke-FsGit $GitExe ($base + @('rev-parse', '--absolute-git-dir'))
        $ev.gitdir = $g.Out.Trim()
        if ($g.Code -ne 0) { $fail.Add("rev-parse --absolute-git-dir failed (rc $($g.Code))") }
        elseif ((ConvertTo-FsGitPath $g.Out) -cne (ConvertTo-FsGitPath $gd)) { $fail.Add("git dir is $($g.Out.Trim()), not $gd") }

        $h = Invoke-FsGit $GitExe ($base + @('rev-parse', '--verify', 'HEAD^{commit}'))
        $ev.head = $h.Out.Trim()
        if ($h.Code -ne 0) { $fail.Add("rev-parse HEAD failed (rc $($h.Code))") }
        elseif ($h.Out.Trim() -cne $ExpectCommit) { $fail.Add("HEAD is $($h.Out.Trim()), not the pinned $ExpectCommit") }

        $s = Invoke-FsGit $GitExe ($base + @('status', '--porcelain', '--ignored', '--untracked-files=all'))
        $ev.status = $s.Out
        if ($s.Code -ne 0) { $fail.Add("status failed (rc $($s.Code)): $($s.Err.Trim())") }
        elseif ($s.Out.Trim()) { $fail.Add('working tree is modified (ignored and untracked files included): ' + (($s.Out.Trim() -split "`n" | Select-Object -First 5) -join '; ')) }

        $l = Invoke-FsGit $GitExe ($base + @('ls-files', '-v'))
        if ($l.Code -ne 0) { $fail.Add("ls-files failed (rc $($l.Code))") }
        else {
            $odd = @($l.Out -split "`n" | Where-Object { $_ -and $_ -cnotmatch '^H ' })
            if ($odd.Count) { $fail.Add('assume-unchanged/skip-worktree entries: ' + (($odd | Select-Object -First 5) -join '; ')) }
        }

        # --- every blob of the pinned tree against the bytes on disk (no filters) ---
        $lt = Invoke-FsGit $GitExe ($base + @('ls-tree', '-r', '-z', '--full-tree', "$ExpectCommit^{tree}"))
        if ($lt.Code -ne 0) { $fail.Add("ls-tree of the pinned commit failed (rc $($lt.Code)): $($lt.Err.Trim())") }
        else {
            $want = [ordered]@{}; $modes = @{}
            foreach ($ent in ($lt.Out -split [char]0)) {
                if ($ent -eq '') { continue }
                if ($ent -cnotmatch '^([0-7]{6}) (blob|tree|commit) ([0-9a-f]{40})\t(.+)\z') { $fail.Add("unparseable ls-tree entry: $ent"); continue }
                $mode = $Matches[1]; $type = $Matches[2]; $sha = $Matches[3]; $path = $Matches[4]
                if ($type -cne 'blob') { $fail.Add("non-blob entry in the pinned tree ($type): $path"); continue }
                if ($mode -ceq '120000') { $fail.Add("symlink entry in the pinned tree (not supported by this check): $path"); continue }
                if ($mode -cne '100644' -and $mode -cne '100755') { $fail.Add("unexpected mode ${mode}: $path"); continue }
                if ($path -match '[\x00-\x1f\x7f]') { $fail.Add("control character in a tracked path: $path"); continue }
                $want[$path] = $sha; $modes[$path] = $mode
            }
            $ev.tree_blobs = $want.Count
            $paths = @($want.Keys)
            $missing = New-Object System.Collections.Generic.List[string]
            $present = New-Object System.Collections.Generic.List[string]
            foreach ($p in $paths) {
                $full = Join-Path $Repo ($p -replace '/', '\')
                $it = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
                if ($null -eq $it) { $missing.Add($p); continue }
                if ($it.PSIsContainer -or ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $fail.Add("tracked path is not a regular file: $p"); continue }
                $present.Add($p)
            }
            if ($missing.Count) { $fail.Add('tracked files missing: ' + (($missing | Select-Object -First 5) -join '; ')) }
            if ($present.Count) {
                # paths as arguments in batches (redirected stdin from .NET carries a BOM)
                $got = New-Object System.Collections.Generic.List[string]; $hoFail = $null; $k0 = 0
                while ($k0 -lt $present.Count -and -not $hoFail) {
                    $batch = New-Object System.Collections.Generic.List[string]; $len = 0
                    while ($k0 -lt $present.Count -and ($batch.Count -eq 0 -or $len -lt 12000)) {
                        $fp = Join-Path $Repo ($present[$k0] -replace '/', '\'); $batch.Add($fp); $len += $fp.Length + 3; $k0++
                    }
                    $ho = Invoke-FsGit $GitExe ($base + @('hash-object', '--no-filters', '--') + $batch.ToArray())
                    $part = @($ho.Out -split "`n" | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
                    if ($ho.Code -ne 0 -or $part.Count -ne $batch.Count) { $hoFail = "rc $($ho.Code): $($ho.Err.Trim())" } else { $got.AddRange([string[]]$part) }
                }
                if ($hoFail) { $fail.Add("hash-object --no-filters failed ($hoFail)") }
                else {
                    $diff = @(for ($k = 0; $k -lt $present.Count; $k++) { if ($got[$k] -cne $want[$present[$k]]) { $present[$k] } })
                    $ev.tree_compared = $present.Count
                    if ($diff.Count) { $fail.Add('file content differs from the pinned tree (no filters): ' + (($diff | Select-Object -First 5) -join '; ')) }
                }
            }
            $ev.mode_bits = 'not checkable from Windows (NTFS stores no exec bit); fs-gitcheck.sh enforces them where the file system stores them'
            # --- filesystem walk: anything on disk that is not in the pinned tree ---
            $extra = New-Object System.Collections.Generic.List[string]
            $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Repo)
            while ($stack.Count) {
                $d = $stack.Pop()
                foreach ($e in (Get-ChildItem -LiteralPath $d -Force)) {
                    $rel = $e.FullName.Substring($Repo.Length + 1) -replace '\\', '/'
                    if ($rel -ceq '.git') { continue }
                    if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $fail.Add("link or junction in the checkout: $rel"); continue }
                    if ($e.PSIsContainer) { $stack.Push($e.FullName); continue }
                    if (-not $want.Contains($rel)) { $extra.Add($rel) }
                }
            }
            if ($extra.Count) { $fail.Add('files not in the pinned tree (filesystem walk): ' + (($extra | Select-Object -First 5) -join '; ')) }
        }
    } catch {
        $fail.Add("internal error in the check: $($_.Exception.Message)")
    }
    return (& $done)
}

if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
try {
    if (-not $Repo -or -not $ExpectCommit) { Write-Output 'usage: fs-gitcheck.ps1 -Repo <dir> -ExpectCommit <40-hex> [-GitExe git]'; exit 64 }
    $r = Test-FsGitCheckout -Repo $Repo -ExpectCommit $ExpectCommit -GitExe $GitExe
    if ($r.Ok) { Write-Output "CLEAN $Repo at $ExpectCommit"; exit 0 }
    foreach ($f in $r.Failures) { Write-Output "REFUSED: $f" }
    exit 1
} catch { Write-Output "ERROR: $($_.Exception.Message)"; exit 70 }
