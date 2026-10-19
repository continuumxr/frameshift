<#
FrameShift K1g - nonce-only rebuild check (Windows PowerShell 5.1). NO DEVICE COMMAND, NO NETWORK; reads files only.

An adapted COPY of fs-nonceonly-k1a.ps1 (pinned, not edited), for the K1g observer (fs-observe-k1g.ps1 dot-sources it);
the PowerShell twin of devices/quest3/k1g/tools/nonce-only-k1g.py. Each K1g run needs its own single-use nonce: a new
nonce means a rebuild (k1g/build-image-k1g.sh). This proves that a rebuilt candidate differs from the REVIEWED K1g
candidate only by the nonce, by opening both images. The generic readers (Read-FsNoBootImage: boot header v3/v4, page
4096, the LZ4 legacy ramdisk, cpio newc with only zero bytes after the trailer) are fs-nonceonly3d.ps1's, dot-sourced
and never edited. The K1g rules (K1a's, with boot-k1g.img and the K1g kernel):
  - both directories are <stamp>-<nonce> with a MANIFEST.txt carrying that nonce, no TEST OVERRIDES; the nonces differ;
    each image's SHA-256 and size equal its MANIFEST's OUTPUT IMAGE line (boot-k1g.img); the reference's SHA-256 is the
    reviewed K1g candidate's (-K1gNoReferenceSha, which must be in the table below and not withdrawn);
  - THE IMAGES: the same size; the header page byte-identical except the ramdisk-size field (bytes 12-15); THE KERNEL
    BYTES IDENTICAL and equal to the pinned K1g Image ($script:FsNoK1gKernel; each MANIFEST's "K1g kernel" line names
    it); the signature region identical; the page padding zero;
  - THE RAMDISKS: the same cpio size; the same entries in the same order with identical cpio headers; every file
    identical (the pinned probe binary /bin/fsbg-probe included) except /init, whose bytes may differ ONLY where the
    reference's nonce stands (same size, >= 1 occurrence);
  - each MANIFEST describes its own image (ramdisk.lz4, ramdisk.cpio and every ramdisk-file line);
  - MANIFEST.txt line-for-line identical except built:, nonce:, OUTPUT IMAGE (same size), ramdisk.cpio (same size),
    ramdisk.lz4, checkout HEAD, and the /init file line (same size and source text).
THE IMAGE PINS ARE FILLED IN BY THE COORDINATOR after the K1g kernel build and the reviewed candidate build: until then
the kernel pin is empty and the candidate table has no entry, and every check refuses (no K1g image can be used).
Usage:
  fs-nonceonly-k1g.ps1 -K1gNoReference <repo>\build\k1g\<reviewed dir> -K1gNoCandidate <repo>\build\k1g\<stamp>-<new nonce>
Exit: 0 NONCE-ONLY REBUILD: OK; 1 not one (every difference printed); 64 usage; 70 error.
#>
param([string]$K1gNoReference = '', [string]$K1gNoCandidate = '', [string]$K1gNoReferenceSha = '')
Set-StrictMode -Version 2.0
$script:FsNoK1gInvocation = $MyInvocation.InvocationName
. (Join-Path $PSScriptRoot 'fs-nonceonly3d.ps1')     # Read-FsNoBootImage, Read-FsNoCpio, FsNoLz4, Get-FsNoSha (its stage-3d table is not used here)

# IMAGE PIN (coordinator): the K1g Image's SHA-256 (k1g/kernel/record/run1; kgate check-k1g.json PASS). Empty = not filled in.
$script:FsNoK1gKernel = '65740722b532b4235e2d35b517bf70d7753e63f42b7b7ee5c869117d999042d3'
# The K1g candidates: image sha256 -> directory under build\k1g, and why a candidate is withdrawn ('' = current).
# IMAGE PIN (coordinator): the reviewed K1g candidate's row, e.g.
#   '<64 hex image sha256>' = @{ Dir = '<UTC>-<nonce>'; Withdrawn = '' }
$script:FsNoK1gCandidates = [ordered]@{
    # CURRENT (r3, J-207: O_DIRECT reads rounded to whole 4096-byte blocks; source 7226f45b, binary c1de030c); built at
    # 014c64d; the kernel bytes are the r2 candidate's (fixtures/image-delta/RESULTS.txt)
    '1ee9f1059d91b1f100e6bde31910980c65befa42c5dd5b8de12e38d187ff2ce4' = @{ Dir = '20261019T031348Z-1c8ade5c6ec2b063'; Withdrawn = '' }
    'd24d155966ac45e9005e85d2a6c00cef585c4967bd67890e9d75dc7b1f4742a4' = @{ Dir = '20261018T004649Z-a6718ea6bc4fe516'; Withdrawn = 'r2 (FS-R-015 s.4): its Unit 2 attempt 0cbd71dd67acc301 was K1G REVIEW (J-207: the probe failed closed before arming, O_DIRECT EINVAL on 4096-byte blocks); superseded by r3; kept as the image-delta reference' }
    'c3c92a0944a5f568eee9ab8a6aab49a1add1ea83b794b3b53640439c94fcfaa3' = @{ Dir = '20261016T160640Z-313eb9b374689d49'; Withdrawn = 'halted by FS-R-014 s.3 (read scope, stop on the first error, open fallback); never booted; kept as the image-delta reference' }
    'f451853cbf19364bbe9dd8faf749597f14d89b6f1f750a6201085914b454905b' = @{ Dir = '20261016T105549Z-3e2e864a0e876dea'; Withdrawn = 'superseded before any boot (FS-A-014 draft MAJOR: fsbg.testkernel not refused on real hardware); deleted' }
    'dd551bf995489a551d8c57468a5c40e2de9701b67570b8c65737670ca61b90e3' = @{ Dir = '20261016T101315Z-9ec2de7d62ad9c0a'; Withdrawn = 'superseded before any boot (narrow review: no after-row in the last second before AFTER_END); deleted' }
    'ce8d39ed9b0e3f1e514534f8092da9d1ff759532d380cf0daad0a82bb526f3f7' = @{ Dir = '20261016T074117Z-150ec234522ec08d'; Withdrawn = 'superseded before any boot (the probe time budget, INCONCLUSIVE time stops, Q10 offline); deleted' }
    'fcb5ba9984b08f58c2d050b1e4318c7a8d9f0e713250cd9dce1a862296a0f42f' = @{ Dir = '20261016T064745Z-79df23b22f80f61d'; Withdrawn = 'superseded before any boot (delta review N1/N2: a refused decoy check ended as PASS; positive controls not re-verified); deleted' }
    '237de855e74486019d3c5283084e3384aa9d003342ae2170fe2ae3580224d3b2' = @{ Dir = '20261016T062740Z-90441fe739665ce0'; Withdrawn = 'superseded before any boot (builder clean-check narrowed to the image sources); deleted' }
    '5e9a69a449336b531d72dfff9c1d4dacaa3a52802be96ad579d7978d62b5b724' = @{ Dir = '20261016T050728Z-f2587972a1520ad3'; Withdrawn = 'superseded before any boot (review BLOCKER: /run 4 MiB; probe before the review fixes); deleted' }
}
$script:FsNoK1gReviewedSha = '1ee9f1059d91b1f100e6bde31910980c65befa42c5dd5b8de12e38d187ff2ce4'
$script:FsNoK1gReviewedDir = if ($script:FsNoK1gReviewedSha -and $script:FsNoK1gCandidates.Contains($script:FsNoK1gReviewedSha)) { [string]$script:FsNoK1gCandidates[$script:FsNoK1gReviewedSha].Dir } else { '' }
function Get-FsNoK1gWithdrawn([string]$Sha) { if ($Sha -and $script:FsNoK1gCandidates.Contains($Sha)) { [string]$script:FsNoK1gCandidates[$Sha].Withdrawn } else { '' } }

# Returns @{ Ok; Diffs; RefNonce; CandNonce; CandImageSha; RefWithdrawn }
function Test-FsNonceOnlyK1g {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$Cand, [string]$RefSha = $script:FsNoK1gReviewedSha)
    $d = New-Object System.Collections.Generic.List[string]
    $rn = $null; $cn = $null; $cs = $null
    $res = { [pscustomobject]@{ Ok = ($d.Count -eq 0); Diffs = $d.ToArray(); RefNonce = $rn; CandNonce = $cn; CandImageSha = $cs; RefWithdrawn = (Get-FsNoK1gWithdrawn $RefSha) } }
    if ($script:FsNoK1gKernel -cnotmatch '^[0-9a-f]{64}\z') { $d.Add('the K1g kernel pin is not filled in (fs-nonceonly-k1g.ps1, coordinator): no K1g image can be checked yet'); return (& $res) }
    if (-not $script:FsNoK1gCandidates.Contains($RefSha)) { $d.Add("the reference $RefSha is not a K1g candidate of the table"); return (& $res) }
    foreach ($x in @(@('reference', $Ref), @('candidate', $Cand))) {
        foreach ($f in 'MANIFEST.txt', 'boot-k1g.img') { if (-not (Test-Path -LiteralPath (Join-Path $x[1] $f) -PathType Leaf)) { $d.Add("$($x[0]): no $f in $($x[1])") } }
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
        $ip = Join-Path $x[1] 'boot-k1g.img'
        $oi = & $one $x[3] '^OUTPUT IMAGE:\s+boot-k1g\.img\s+size=(\d+)\s+sha256=([0-9a-f]{64})\s*$'
        $h = Get-FsNoSha $ip; $sz = (Get-Item -LiteralPath $ip).Length
        if ($null -eq $oi -or [long]$oi.Groups[1].Value -ne $sz -or $oi.Groups[2].Value -cne $h) { $d.Add("$($x[0]): the image's size/SHA-256 differ from its MANIFEST OUTPUT IMAGE line") }
        $kl = & $one $x[3] '^K1g kernel\s+([0-9a-f]{64})\s'
        if ($null -eq $kl -or $kl.Groups[1].Value -cne $script:FsNoK1gKernel) { $d.Add("$($x[0]): its MANIFEST 'K1g kernel' line is not the pinned K1g Image $($script:FsNoK1gKernel)") }
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
    elseif ((Get-FsNoBytesSha $a.Bytes ([int]$a.KernelOff) ([int]$a.KernelSize)) -cne $script:FsNoK1gKernel) { $d.Add("the kernel inside the images is not the pinned K1g Image $($script:FsNoK1gKernel)") }
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

if ($script:FsNoK1gInvocation -eq '.') { return }
$exit = 70
try {
    if (-not $K1gNoReference -or -not $K1gNoCandidate) { Write-Output 'usage: fs-nonceonly-k1g.ps1 -K1gNoReference <reviewed candidate dir> -K1gNoCandidate <rebuilt dir> [-K1gNoReferenceSha <64 hex>]   (reads files only)'; exit 64 }
    $rs = if ($K1gNoReferenceSha) { $K1gNoReferenceSha } else { $script:FsNoK1gReviewedSha }
    if ($rs -cnotmatch '^[0-9a-f]{64}\z') { Write-Output 'usage: -K1gNoReferenceSha is 64 lowercase hex'; exit 64 }
    $r = Test-FsNonceOnlyK1g -Ref ([IO.Path]::GetFullPath($K1gNoReference)) -Cand ([IO.Path]::GetFullPath($K1gNoCandidate)) -RefSha $rs
    if ($r.Ok -and $r.RefWithdrawn) { Write-Output "NONCE-ONLY REBUILD OF A WITHDRAWN CANDIDATE ($($r.RefWithdrawn)): never a run image"; $exit = 1 }
    elseif ($r.Ok) { Write-Output "NONCE-ONLY REBUILD: OK: $K1gNoCandidate differs from $K1gNoReference only by the nonce ($($r.RefNonce) -> $($r.CandNonce)); image sha256 $($r.CandImageSha)"; $exit = 0 }
    else { foreach ($l in $r.Diffs) { Write-Output "DIFF: $l" }; Write-Output "NOT A NONCE-ONLY REBUILD ($($r.Diffs.Count) difference(s)): do not use it without a review"; $exit = 1 }
} catch { Write-Output "NONCE-ONLY CHECK ERROR: $($_.Exception.Message)"; $exit = 70 }
exit $exit
