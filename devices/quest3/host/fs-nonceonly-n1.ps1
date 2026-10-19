<#
FrameShift N1 - nonce-only rebuild check (Windows PowerShell 5.1). NO DEVICE COMMAND, NO NETWORK; reads files only.

The PowerShell twin of devices/quest3/n1/tools/nonce-only-n1.py, for the N1 observer (fs-observe-n1.ps1 dot-sources
it). An adapted COPY of fs-nonceonly-k1a.ps1 (not edited): the same rules (the generic readers of fs-nonceonly3d.ps1,
dot-sourced; the kernel bytes identical and equal to the pinned K1a Image, which N1 carries unchanged; only the nonce
inside /init differs; the MANIFESTs line for line), with the image name boot-n1.img, the N1 candidate table, and the
prefixes FsNoN1 / N1No*.
Usage:
  fs-nonceonly-n1.ps1 -N1NoReference <repo>\build\n1\<reviewed dir> -N1NoCandidate <repo>\build\n1\<stamp>-<new nonce>
Exit: 0 NONCE-ONLY REBUILD: OK; 1 not one (every difference printed); 64 usage; 70 error.
#>
param([string]$N1NoReference = '', [string]$N1NoCandidate = '', [string]$N1NoReferenceSha = '')
Set-StrictMode -Version 2.0
$script:FsNoN1Invocation = $MyInvocation.InvocationName
. (Join-Path $PSScriptRoot 'fs-nonceonly3d.ps1')     # Read-FsNoBootImage, Read-FsNoCpio, FsNoLz4, Get-FsNoSha (its stage-3d table is not used here)

$script:FsNoN1Kernel = '087f0e72999922909e9583b95ae956f0186d6c1a337b71308b845456689e1840'   # the K1a Image, unchanged in N1 (k1a/kernel/record/run1; kgate PASS)
# The N1 candidates: image sha256 -> directory under build\n1, and why a candidate is withdrawn ('' = current).
$script:FsNoN1Candidates = [ordered]@{
    # CURRENT: N1 r2, the FS-R-014 s.5 post-transfer kernel-log delta (built at the r2 sources; never booted)
    '82eefa8a7d263bbe0a36370070149418820a155e35fc906ff6377ecc1f480436' = @{ Dir = '20261018T005854Z-b1ba58d65e7ffa1a'; Withdrawn = '' }
    '5550b45a29c32ebf1bd6d2a930f563c7c232728d5ca81b1d6e2d10c0ca8ccebd' = @{ Dir = '20261016T210552Z-890262ef72c9e4cd'; Withdrawn = 'superseded before any boot (FS-R-014 s.5: execution withheld; the kernel log was not read after the transfer; N1 r2 adds the post-transfer check)' }
    'b1474948ee0ed5818a25f46617bec8f8edac3457d61ee972975fccc3c57dd8a0' = @{ Dir = '20261016T165507Z-fabc8c4edca631d8'; Withdrawn = 'superseded before any boot (internal review fixes: guard, fs-xfer without loopback mode); kept for reference' }
}
$script:FsNoN1ReviewedSha = '82eefa8a7d263bbe0a36370070149418820a155e35fc906ff6377ecc1f480436'
$script:FsNoN1ReviewedDir = $script:FsNoN1Candidates[$script:FsNoN1ReviewedSha].Dir
function Get-FsNoN1Withdrawn([string]$Sha) { if ($Sha -and $script:FsNoN1Candidates.Contains($Sha)) { [string]$script:FsNoN1Candidates[$Sha].Withdrawn } else { '' } }

# Returns @{ Ok; Diffs; RefNonce; CandNonce; CandImageSha; RefWithdrawn }
function Test-FsNonceOnlyN1 {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$Cand, [string]$RefSha = $script:FsNoN1ReviewedSha)
    $d = New-Object System.Collections.Generic.List[string]
    $rn = $null; $cn = $null; $cs = $null
    $res = { [pscustomobject]@{ Ok = ($d.Count -eq 0); Diffs = $d.ToArray(); RefNonce = $rn; CandNonce = $cn; CandImageSha = $cs; RefWithdrawn = (Get-FsNoN1Withdrawn $RefSha) } }
    if (-not $script:FsNoN1Candidates.Contains($RefSha)) { $d.Add("the reference $RefSha is not an N1 candidate of the table"); return (& $res) }
    foreach ($x in @(@('reference', $Ref), @('candidate', $Cand))) {
        foreach ($f in 'MANIFEST.txt', 'boot-n1.img') { if (-not (Test-Path -LiteralPath (Join-Path $x[1] $f) -PathType Leaf)) { $d.Add("$($x[0]): no $f in $($x[1])") } }
    }
    if ($d.Count) { return (& $res) }
    $mr = Read-FsNoLines (Join-Path $Ref 'MANIFEST.txt'); $mc = Read-FsNoLines (Join-Path $Cand 'MANIFEST.txt')
    $one = { param($m, [string]$re) $l = @($m | Where-Object { $_ -cmatch $re }); if ($l.Count -eq 1) { [regex]::Match($l[0], $re) } else { $null } }
    $nr = & $one $mr '^nonce:\s+([0-9a-f]{16})\s'; $nc = & $one $mc '^nonce:\s+([0-9a-f]{16})\s'
    if ($null -eq $nr -or $null -eq $nc) { $d.Add('a MANIFEST has no single nonce line'); return (& $res) }
    $rn = $nr.Groups[1].Value; $cn = $nc.Groups[1].Value
    if ($rn -ceq $cn) { $d.Add("the nonces are the same ($rn): a nonce is single-use") }
    $img = @{}
    foreach ($x in @(@('reference', $Ref, $rn, $mr), @('candidate', $Cand, $cn, $mc))) {
        if ((Split-Path -Leaf $x[1]) -cnotmatch ('^\d{8}T\d{6}Z-' + $x[2] + '\z')) { $d.Add("$($x[0]): directory '$(Split-Path -Leaf $x[1])' does not carry its MANIFEST nonce") }
        if (@($x[3] | Where-Object { $_ -cmatch '^TEST OVERRIDES' }).Count) { $d.Add("$($x[0]): MANIFEST records TEST OVERRIDES (a fixture build)") }
        $ip = Join-Path $x[1] 'boot-n1.img'
        $oi = & $one $x[3] '^OUTPUT IMAGE:\s+boot-n1\.img\s+size=(\d+)\s+sha256=([0-9a-f]{64})\s*$'
        $h = Get-FsNoSha $ip; $sz = (Get-Item -LiteralPath $ip).Length
        if ($null -eq $oi -or [long]$oi.Groups[1].Value -ne $sz -or $oi.Groups[2].Value -cne $h) { $d.Add("$($x[0]): the image's size/SHA-256 differ from its MANIFEST OUTPUT IMAGE line") }
        $kl = & $one $x[3] '^K1a kernel\s+([0-9a-f]{64})\s'
        if ($null -eq $kl -or $kl.Groups[1].Value -cne $script:FsNoN1Kernel) { $d.Add("$($x[0]): its MANIFEST 'K1a kernel' line is not the pinned K1a Image $($script:FsNoN1Kernel)") }
        $img[$x[0]] = Read-FsNoBootImage $ip
        if (-not $img[$x[0]].Ok) { $d.Add("$($x[0]): $($img[$x[0]].Why)") }
        else {
            # review MINOR-7 (as fs-nonceonly3d.ps1): the MANIFEST describes the bytes of THIS image
            $bi = $img[$x[0]]
            $lz = & $one $x[3] '^ramdisk\.lz4\s+([0-9a-f]{64})\s+size=(\d+)\s*$'; $cp = & $one $x[3] '^ramdisk\.cpio\s+([0-9a-f]{64})\s+size=(\d+)\s*$'
            if ($null -eq $lz -or $lz.Groups[1].Value -cne $bi.Lz4Sha -or [long]$lz.Groups[2].Value -ne $bi.RamdiskSize) { $d.Add("$($x[0]): the ramdisk in the image is not its MANIFEST's ramdisk.lz4") }
            if ($null -eq $cp -or $cp.Groups[1].Value -cne $bi.CpioSha -or [long]$cp.Groups[2].Value -ne $bi.Cpio.Length) { $d.Add("$($x[0]): the unpacked ramdisk is not its MANIFEST's ramdisk.cpio") }
            $byName = @{}; foreach ($en in $bi.Entries) { $byName['/' + $en.Name] = $en }
            $fl = @($x[3] | Where-Object { $_ -cmatch '^[0-9a-f]{64}  \d+  /\S+  ' })
            if ($fl.Count -lt 1) { $d.Add("$($x[0]): its MANIFEST lists no ramdisk files") }
            foreach ($l in $fl) {
                $fm = [regex]::Match($l, '^([0-9a-f]{64})  (\d+)  (/\S+)  ')
                $en = $byName[$fm.Groups[3].Value]
                if ($null -eq $en) { $d.Add("$($x[0]): MANIFEST names $($fm.Groups[3].Value), which is not in the image's ramdisk"); continue }
                if ([long]$fm.Groups[2].Value -ne $en.Size -or (Get-FsNoBytesSha $bi.Cpio $en.Off $en.Size) -cne $fm.Groups[1].Value) { $d.Add("$($x[0]): $($fm.Groups[3].Value) in the image is not its MANIFEST line") }
            }
        }
        if ($x[0] -ceq 'candidate') { $cs = $h }
        elseif ($h -cne $RefSha) { $d.Add("reference: its image $h is not the reviewed candidate $RefSha") }
    }
    if ($d.Count) { return (& $res) }
    $a = $img['reference']; $b = $img['candidate']
    if ($a.Bytes.Length -ne $b.Bytes.Length) { $d.Add("image sizes differ ($($a.Bytes.Length) / $($b.Bytes.Length)): rebuild with another nonce"); return (& $res) }
    $ha = [byte[]]$a.Bytes[0..4095]; $hb = [byte[]]$b.Bytes[0..4095]
    for ($i = 12; $i -lt 16; $i++) { $ha[$i] = 0; $hb[$i] = 0 }
    if ((Get-FsNoBytesSha $ha) -cne (Get-FsNoBytesSha $hb)) { $d.Add('the header pages differ beyond the ramdisk-size field') }
    if ($a.KernelSize -ne $b.KernelSize -or -not (Test-FsNoEqual $a.Bytes ([int]$a.KernelOff) $b.Bytes ([int]$b.KernelOff) ([int]$a.KernelSize))) { $d.Add('KERNEL BYTES DIFFER') }
    elseif ((Get-FsNoBytesSha $a.Bytes ([int]$a.KernelOff) ([int]$a.KernelSize)) -cne $script:FsNoN1Kernel) { $d.Add("the kernel inside the images is not the pinned K1a Image $($script:FsNoN1Kernel)") }
    foreach ($y in @(@('reference', $a), @('candidate', $b))) {
        $o = $y[1]
        if (-not (Test-FsNoZero $o.Bytes ([int]($o.KernelOff + $o.KernelSize)) ([int]($o.RamdiskOff - $o.KernelOff - $o.KernelSize)))) { $d.Add("$($y[0]): nonzero kernel padding") }
        if (-not (Test-FsNoZero $o.Bytes ([int]($o.RamdiskOff + $o.RamdiskSize)) ([int]($o.SigOff - $o.RamdiskOff - $o.RamdiskSize)))) { $d.Add("$($y[0]): nonzero ramdisk padding") }
    }
    if ($a.SigSize -ne $b.SigSize -or ($a.SigSize -gt 0 -and -not (Test-FsNoEqual $a.Bytes ([int]$a.SigOff) $b.Bytes ([int]$b.SigOff) ([int]$a.SigSize)))) { $d.Add('the signature regions differ') }
    if ($a.Cpio.Length -ne $b.Cpio.Length) { $d.Add('cpio sizes differ') }
    $ea = @($a.Entries); $eb = @($b.Entries)
    if ($ea.Count -ne $eb.Count) { $d.Add('cpio entry counts differ'); return (& $res) }
    $rnb = [Text.Encoding]::ASCII.GetBytes($rn); $cnb = [Text.Encoding]::ASCII.GetBytes($cn)
    for ($i = 0; $i -lt $ea.Count; $i++) {
        $x = $ea[$i]; $y = $eb[$i]
        if ($x.Name -cne $y.Name -or $x.Header -cne $y.Header) { $d.Add("cpio entry $i ($($x.Name) / $($y.Name)): name or header differs"); continue }
        $same = Test-FsNoEqual $a.Cpio ([int]$x.Off) $b.Cpio ([int]$y.Off) ([int]$x.Size)
        if ($x.Name -cne 'init') { if (-not $same) { $d.Add("file /$($x.Name) differs") }; continue }
        if ($same) { $d.Add('/init is identical: the nonce did not change in it'); continue }
        # /init: replace every occurrence of the reference nonce by the candidate's; the result must be the candidate's /init
        $ia = [byte[]]$a.Cpio[([int]$x.Off)..([int]$x.Off + [int]$x.Size - 1)]; $ib = [byte[]]$b.Cpio[([int]$y.Off)..([int]$y.Off + [int]$y.Size - 1)]
        $hits = 0
        for ($p = 0; $p -le $ia.Length - 16; $p++) {
            $m = $true; for ($q = 0; $q -lt 16; $q++) { if ($ia[$p + $q] -ne $rnb[$q]) { $m = $false; break } }
            if ($m) { for ($q = 0; $q -lt 16; $q++) { $ia[$p + $q] = $cnb[$q] }; $hits++; $p += 15 }
        }
        if ($hits -lt 1 -or (Get-FsNoBytesSha $ia) -cne (Get-FsNoBytesSha $ib)) { $d.Add('/init differs beyond the nonce') }
    }
    # MANIFEST: line for line
    $keys = '^(built:|nonce:|OUTPUT IMAGE:|ramdisk\.cpio|ramdisk\.lz4|checkout HEAD)'
    if ($mr.Count -ne $mc.Count) { $d.Add('the MANIFESTs differ in length'); return (& $res) }
    for ($i = 0; $i -lt $mr.Count; $i++) {
        $p1 = $mr[$i]; $p2 = $mc[$i]
        if ($p1 -ceq $p2) { continue }
        if ($p1 -cmatch $keys -and $p2 -cmatch $keys -and ($p1 -split '\s+')[0] -ceq ($p2 -split '\s+')[0]) {
            if ($p1 -cmatch '^OUTPUT IMAGE:' -and ([regex]::Match($p1, 'size=\d+').Value -cne [regex]::Match($p2, 'size=\d+').Value)) { $d.Add('MANIFEST image sizes differ') }
            if ($p1 -cmatch '^ramdisk\.cpio' -and ([regex]::Match($p1, 'size=\d+').Value -cne [regex]::Match($p2, 'size=\d+').Value)) { $d.Add('MANIFEST cpio sizes differ') }
            continue
        }
        $f1 = $p1 -split '\s+'; $f2 = $p2 -split '\s+'
        if ($f1.Count -ge 4 -and $f1[2] -ceq '/init' -and $f2[2] -ceq '/init' -and $f1[1] -ceq $f2[1] -and (($f1[3..($f1.Count - 1)]) -join ' ') -ceq (($f2[3..($f2.Count - 1)]) -join ' ')) { continue }
        $d.Add("MANIFEST line $($i + 1) differs: '$p1' / '$p2'")
    }
    & $res
}

if ($script:FsNoN1Invocation -eq '.') { return }
$exit = 70
try {
    if (-not $N1NoReference -or -not $N1NoCandidate) { Write-Output 'usage: fs-nonceonly-n1.ps1 -N1NoReference <reviewed candidate dir> -N1NoCandidate <rebuilt dir> [-N1NoReferenceSha <64 hex>]   (reads files only)'; exit 64 }
    $rs = if ($N1NoReferenceSha) { $N1NoReferenceSha } else { $script:FsNoN1ReviewedSha }
    if ($rs -cnotmatch '^[0-9a-f]{64}\z') { Write-Output 'usage: -N1NoReferenceSha is 64 lowercase hex'; exit 64 }
    $r = Test-FsNonceOnlyN1 -Ref ([IO.Path]::GetFullPath($N1NoReference)) -Cand ([IO.Path]::GetFullPath($N1NoCandidate)) -RefSha $rs
    if ($r.Ok -and $r.RefWithdrawn) { Write-Output "NONCE-ONLY REBUILD OF A WITHDRAWN CANDIDATE ($($r.RefWithdrawn)): never a run image"; $exit = 1 }
    elseif ($r.Ok) { Write-Output "NONCE-ONLY REBUILD: OK: $N1NoCandidate differs from $N1NoReference only by the nonce ($($r.RefNonce) -> $($r.CandNonce)); image sha256 $($r.CandImageSha)"; $exit = 0 }
    else { foreach ($l in $r.Diffs) { Write-Output "DIFF: $l" }; Write-Output "NOT A NONCE-ONLY REBUILD ($($r.Diffs.Count) difference(s)): do not use it without a review"; $exit = 1 }
} catch { Write-Output "NONCE-ONLY CHECK ERROR: $($_.Exception.Message)"; $exit = 70 }
exit $exit
