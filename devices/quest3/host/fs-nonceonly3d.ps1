<#
FrameShift - stage-3d nonce-only rebuild check (Windows PowerShell 5.1). NO DEVICE COMMAND, NO NETWORK; reads files only.

Each stage-3d run needs its own single-use nonce (PM, J-133; J-141: Unit 1 next, then Unit 2). A new nonce means a rebuild
(stage3d/build-image.sh: a fresh `openssl rand -hex 8`, substituted into /init). This tool proves that a rebuilt
candidate differs from the REVIEWED candidate only by the nonce, by opening both images (review MAJOR-2: the first
version compared the record files only and trusted the builder's MANIFEST for the image):
  - the reference image is a reviewed candidate: its SHA-256 must equal -ReferenceSha (default the CURRENT candidate
    fcca5ee7...4fb5, fs-pattern v0.7.1, J-141), and -ReferenceSha must be an entry of the reviewed-candidate table below,
    so a self-consistent but unreviewed directory cannot serve;
  - both directories are <stamp>-<nonce> with a MANIFEST.txt carrying that nonce; the nonces differ; each image's
    SHA-256 and size equal its MANIFEST's OUTPUT IMAGE line;
  - THE IMAGES (Android boot image header v3/v4, page 4096): the same file size; the header page byte-identical except
    the ramdisk-size field (bytes 12-15: the lz4 size follows the nonce); the kernel bytes and everything after the
    ramdisk byte-identical; the ramdisk's page padding zero in both;
  - THE RAMDISKS: each is unpacked here (LZ4 legacy frames, then cpio newc); the compressed bytes and the cpio equal
    their MANIFEST lines (ramdisk.lz4, ramdisk.cpio); the cpio sizes are equal; the entries are the same, in the same
    order, with identical cpio headers (mode, owner, inode, mtime, size, ...), and every file's bytes are identical,
    except /init, whose bytes may differ ONLY where the reference's 16-hex nonce stands in the reference and the
    candidate's in the candidate (same size; at least one occurrence); every "## ramdisk files" line of each MANIFEST
    equals the file in its own image (hash and size);
  - MANIFEST.txt is line-for-line identical except built:, nonce:, the OUTPUT IMAGE hash (its size must match),
    the ramdisk.cpio hash (its size must match), ramdisk.lz4 and the /init file line, which must keep its size and its
    source text (only the hash differs);
  - ramdisk.sha256 identical except the `init` line (same size); ramdisk.list, applets.txt, avb-check.txt,
    module-list-check.txt and gitcheck.txt byte-identical; ramdisk-scan.txt identical except its first two lines,
    which every build writes anew (delta review MAJOR-1): line 1 "# initramfs BLAKE2 scan of boot-stage3d.img  <UTC>"
    and line 2 "boot image:   /tmp/tmp.<x>/boot-stage3d.img sha256=<the image's own SHA-256>" (each directory's
    line 2 must name its own image); header-diff.txt identical except the output's `ramdisk size` line.
  - the builder (delta review MAJOR-1, found by a REAL rebuild from master): each MANIFEST's build-image.sh hash and its
    module-list-check tool hash must be one of the builder pairs reviewed FOR THIS REFERENCE (the table below: each
    reviewed candidate has its own pairs; a pair of another candidate is refused); those two lines may differ only that
    way, and module-list-check.txt only by check 5's line
    "CHECK no_forbidden_module_in_or_reachable_from_the_list (38 forbidden) PASS []" (present exactly when the tool is
    402525cd). The image and ramdisk comparison above is unaffected: the image bytes stay nonce-only.
A different image size (the lz4 size crossing a 4096-byte page) is refused: rebuild with another nonce.
The reviewed candidates (J-141): the CURRENT one is 20261014T014738Z-13ed21be49c7b4ba (fcca5ee7...4fb5, fs-pattern
v0.7.1 bfafad97...9a9a, fs-probe.sh with the v2.7 dmesg filter; builder b90c0fbb / 402525cd). WITHDRAWN: the first v0.7.1
candidate 20261014T012519Z-2b2596964c0812b1 (96cc15aa...3fad; builder 8870bbce / 402525cd), superseded before any boot.
The first candidate 20261013T065151Z-7a22c3d2ff0fef44
(3d730337...c224, fs-pattern v0.7 7c9fa98c...0674; builders 605da89e / 35261647 and b67c4023 / 402525cd) is WITHDRAWN:
its nonce was spent on Unit 2 (J-141) and its fs-pattern refuses v2.7's 305 modes (MAXMODES 128). It stays in the table
for history (this CLI with -ReferenceSha 3d730337... still compares, but never reports a usable rebuild: exit 1).
fs-observe3d.ps1 runs the same check (it dot-sources this file) for any candidate other than the current one and
refuses the image unless it passes, also at -Preflight (review MAJOR-2); it never accepts a withdrawn candidate.
Usage:
  fs-nonceonly3d.ps1 -Reference build\stage3d\20261014T014738Z-13ed21be49c7b4ba -Candidate build\stage3d\<stamp>-<new nonce>
Exit: 0 a nonce-only rebuild of the current candidate (prints NONCE-ONLY REBUILD: OK ...); 1 not one, or a rebuild of a
withdrawn candidate (prints every difference); 64 usage; 70 error.
#>
param([string]$Reference = '', [string]$Candidate = '', [string]$ReferenceSha = 'fcca5ee791ee6e9dcf696eba16c676de1c26ab60ce82211c49a457e9cca24fb5')
Set-StrictMode -Version 2.0
$script:FsNoInvocation = $MyInvocation.InvocationName
# The reviewed stage-3d candidates: image sha256 -> its directory under build\stage3d, the builder pairs reviewed for it
# (build-image.sh sha256 -> the module-list-check.py sha256 it ran) and, for a withdrawn one, why. Each reference is
# compared only with ITS OWN builder pairs (a pair of another candidate is "not a reviewed builder version").
$script:FsNoCandidates = [ordered]@{
    # CURRENT (J-141): fs-pattern v0.7.1 bfafad97...9a9a (MAXMODES fix) and fs-probe.sh f0fda865 (the v2.7 mode-validation
    # dmesg lines counted, not kept); build-image.sh b90c0fbb (the v0.7.1 pin, the MANIFEST's both-units sentence, the
    # fs-probe source label), module-list-check.py 402525cd (unchanged, check 5)
    'fcca5ee791ee6e9dcf696eba16c676de1c26ab60ce82211c49a457e9cca24fb5' = @{
        Dir = '20261014T014738Z-13ed21be49c7b4ba'; Withdrawn = ''
        Builders = @{ 'b90c0fbb7e874f798f2dd56fc2f9c25c73b94f82f1b4472c5087abefd7286c34' = '402525cd94220832b4201212684e22a910833e1dd0c6b7dc2cbd438ba14bf4c8' } }
    # WITHDRAWN (J-141), history only: the first v0.7.1 candidate, superseded before any boot by the fs-probe.sh dmesg filter
    '96cc15aabc647e9da4b1d5b0f95214bd42445aa66c4eb1a8c79210f273113fad' = @{
        Dir = '20261014T012519Z-2b2596964c0812b1'
        Withdrawn = 'superseded before any boot (never booted; nonce 2b2596964c0812b1 never used) by fcca5ee7 (fs-probe.sh: the v2.7 mode-validation dmesg lines counted, not kept; J-141)'
        Builders = @{ '8870bbceef462410fb5af5d15130d8495f5c0faf5bc454edab25e0a425fe012c' = '402525cd94220832b4201212684e22a910833e1dd0c6b7dc2cbd438ba14bf4c8' } }
    # WITHDRAWN (J-141), history only: the first candidate (J-133/J-135); git 3453f94: the builder that built it; git 7634871:
    # master after review C (a comment in build-image.sh and check 5 in module-list-check.py, image unchanged)
    '3d730337c6fa9e0b5aa6dbbe9da382770ad7b104de0399887b7bfd1c30fcc224' = @{
        Dir = '20261013T065151Z-7a22c3d2ff0fef44'
        Withdrawn = 'nonce 7a22c3d2ff0fef44 spent on Unit 2 (J-141); its fs-pattern v0.7 (7c9fa98c...0674) refuses v2.7''s 305 modes (MAXMODES 128)'
        Builders = @{ '605da89e5486aadd01d93c9925ea7f852dc14a27ed94c494bf1f0fb1bf7561f7' = '35261647eb53711dded95e391f2c7e2742031dababbd5215f55b6b7e0468e8ca'
                      'b67c40233b0be590d6fd153021e75847df9853b6402875c0cf37126f00093d2d' = '402525cd94220832b4201212684e22a910833e1dd0c6b7dc2cbd438ba14bf4c8' } }
}
$script:FsNoReviewedSha = 'fcca5ee791ee6e9dcf696eba16c676de1c26ab60ce82211c49a457e9cca24fb5'   # the CURRENT reviewed candidate (the observer's)
$script:FsNoReviewedDir = $script:FsNoCandidates[$script:FsNoReviewedSha].Dir                    # its directory under build\stage3d
# '' for the current candidate or an unknown sha; the reason for a withdrawn one
function Get-FsNoWithdrawn([string]$Sha) { if ($Sha -and $script:FsNoCandidates.Contains($Sha)) { [string]$script:FsNoCandidates[$Sha].Withdrawn } else { '' } }
$script:FsNoCheck5Tool = '402525cd94220832b4201212684e22a910833e1dd0c6b7dc2cbd438ba14bf4c8'
$script:FsNoCheck5Line = 'CHECK no_forbidden_module_in_or_reachable_from_the_list (38 forbidden) PASS []'
# The LZ4 legacy-frame decoder (the format of `lz4 -l`, the kernel's ramdisk format): magic 0x184C2102, then blocks of
# <uint32 compressed size><LZ4 block>, each decoding to at most 8 MiB. Every read and copy is bounds-checked.
if (-not ('FsNoLz4' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
public static class FsNoLz4 {
    public const uint LegacyMagic = 0x184C2102;
    public static byte[] DecodeLegacy(byte[] s, int off, int len) {
        if (off < 0 || len < 4 || off + len > s.Length) throw new Exception("lz4: bad range");
        int end = off + len, p = off;
        if (BitConverter.ToUInt32(s, p) != LegacyMagic) throw new Exception("lz4: not a legacy frame (magic)");
        p += 4;
        MemoryStream o = new MemoryStream();
        byte[] buf = new byte[8 << 20];
        int blocks = 0;
        while (p < end) {
            if (end - p < 4) throw new Exception("lz4: truncated block size");
            uint bs = BitConverter.ToUInt32(s, p); p += 4;
            if (bs == LegacyMagic) continue;
            if (bs == 0 || bs > (uint)(end - p)) throw new Exception("lz4: block size " + bs + " out of range");
            int n = DecodeBlock(s, p, (int)bs, buf);
            o.Write(buf, 0, n); p += (int)bs; blocks++;
        }
        if (blocks == 0) throw new Exception("lz4: no block");
        return o.ToArray();
    }
    static int DecodeBlock(byte[] s, int sp, int slen, byte[] d) {
        int send = sp + slen, dp = 0;
        while (true) {
            if (sp >= send) throw new Exception("lz4: truncated sequence");
            int token = s[sp++];
            int lit = token >> 4;
            if (lit == 15) { int b; do { if (sp >= send) throw new Exception("lz4: truncated length"); b = s[sp++]; lit += b; } while (b == 255); }
            if (lit > send - sp || lit > d.Length - dp) throw new Exception("lz4: literal run out of range");
            Buffer.BlockCopy(s, sp, d, dp, lit); sp += lit; dp += lit;
            if (sp == send) break;
            if (send - sp < 2) throw new Exception("lz4: truncated offset");
            int moff = s[sp] | (s[sp + 1] << 8); sp += 2;
            if (moff == 0 || moff > dp) throw new Exception("lz4: match offset out of range");
            int ml = token & 15;
            if (ml == 15) { int b; do { if (sp >= send) throw new Exception("lz4: truncated match length"); b = s[sp++]; ml += b; } while (b == 255); }
            ml += 4;
            if (ml > d.Length - dp) throw new Exception("lz4: match out of range");
            int m = dp - moff;
            for (int i = 0; i < ml; i++) d[dp++] = d[m++];
        }
        return dp;
    }
}
'@
}

function Get-FsNoSha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }
function Get-FsNoBytesSha([byte[]]$B, [int]$Off = 0, [int]$Len = -1) {
    if ($Len -lt 0) { $Len = $B.Length - $Off }
    $h = [Security.Cryptography.SHA256]::Create(); try { -join ($h.ComputeHash($B, $Off, $Len) | ForEach-Object { $_.ToString('x2') }) } finally { $h.Dispose() }
}
function Read-FsNoLines([string]$Path) { @([IO.File]::ReadAllText($Path) -split "`r?`n") }
function Test-FsNoEqual([byte[]]$A, [int]$Ao, [byte[]]$B, [int]$Bo, [int]$Len) { (Get-FsNoBytesSha $A $Ao $Len) -ceq (Get-FsNoBytesSha $B $Bo $Len) }
function Test-FsNoZero([byte[]]$A, [int]$Off, [int]$Len) { for ($i = 0; $i -lt $Len; $i++) { if ($A[$Off + $i] -ne 0) { return $false } }; $true }
# cpio newc: the entries (name, the 13 header fields as text, the data range) up to TRAILER!!!, then only zero bytes.
function Read-FsNoCpio([byte[]]$C) {
    $e = New-Object System.Collections.Generic.List[object]; $p = 0; $asc = [Text.Encoding]::ASCII
    while ($true) {
        if ($p + 110 -gt $C.Length) { throw "cpio: truncated header at $p" }
        $h = $asc.GetString($C, $p, 110)
        if ($h -cnotmatch '^070701[0-9A-Fa-f]{104}\z') { throw "cpio: not a newc header at $p" }
        $f = @(); for ($i = 0; $i -lt 13; $i++) { $f += $h.Substring(6 + 8 * $i, 8) }
        $ns = [Convert]::ToInt32($f[11], 16); $fs = [Convert]::ToInt32($f[6], 16)
        if ($ns -lt 1 -or $p + 110 + $ns -gt $C.Length) { throw "cpio: bad name size at $p" }
        $name = $asc.GetString($C, $p + 110, $ns - 1)
        if ($C[$p + 110 + $ns - 1] -ne 0) { throw "cpio: name not NUL-terminated at $p" }
        $dOff = $p + 110 + $ns; $dOff += (4 - ($dOff % 4)) % 4
        if ($fs -lt 0 -or $dOff + $fs -gt $C.Length) { throw "cpio: data of '$name' out of range" }
        $p = $dOff + $fs; $p += (4 - ($p % 4)) % 4
        if ($name -ceq 'TRAILER!!!') { break }
        $e.Add([pscustomobject]@{ Name = $name; Header = ($f -join ' '); Size = $fs; Off = $dOff })
    }
    if ($p -lt $C.Length -and -not (Test-FsNoZero $C $p ($C.Length - $p))) { throw 'cpio: non-zero bytes after the trailer' }
    ,$e.ToArray()
}
# An Android boot image, header v3/v4 (page 4096): its regions, the ramdisk unpacked. Returns @{ Ok; Why; ... }.
function Read-FsNoBootImage([string]$Path) {
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w } }
    [byte[]]$b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 4096 -or [Text.Encoding]::ASCII.GetString($b, 0, 8) -cne 'ANDROID!') { return (& $no 'not an Android boot image (magic)') }
    $u = { param([int]$o) [long][BitConverter]::ToUInt32($b, $o) }
    $hv = & $u 40
    if ($hv -ne 3 -and $hv -ne 4) { return (& $no "boot image header version $hv (3 or 4 expected)") }
    $pg = 4096; $pad = { param([long]$n) [long]([Math]::Ceiling($n / [double]$pg) * $pg) }
    $ks = & $u 8; $rs = & $u 12; $hs = & $u 20; $ss = if ($hv -eq 4) { & $u 1580 } else { [long]0 }
    $kOff = [long]$pg; $rOff = $kOff + (& $pad $ks); $sOff = $rOff + (& $pad $rs); $end = $sOff + (& $pad $ss)
    if ($end -ne $b.Length) { return (& $no "the regions (header 4096, kernel $ks, ramdisk $rs, signature $ss, page 4096) end at $end, the file has $($b.Length) bytes") }
    try { [byte[]]$cpio = [FsNoLz4]::DecodeLegacy($b, [int]$rOff, [int]$rs) } catch { return (& $no "ramdisk: $($_.Exception.Message)") }
    try { $ent = Read-FsNoCpio $cpio } catch { return (& $no "ramdisk: $($_.Exception.Message)") }
    [pscustomobject]@{ Ok = $true; Why = 'ok'; Bytes = $b; Version = $hv; HeaderSize = $hs; KernelSize = $ks; RamdiskSize = $rs; SigSize = $ss; KernelOff = $kOff; RamdiskOff = $rOff; SigOff = $sOff
                       Lz4Sha = (Get-FsNoBytesSha $b ([int]$rOff) ([int]$rs)); Cpio = $cpio; CpioSha = (Get-FsNoBytesSha $cpio); Entries = $ent }
}
# Returns @{ Ok; Diffs; RefNonce; CandNonce; CandImageSha }
function Test-FsNonceOnly {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$Cand, [string]$RefSha = $script:FsNoReviewedSha)
    $d = New-Object System.Collections.Generic.List[string]
    $res = { [pscustomobject]@{ Ok = ($d.Count -eq 0); Diffs = $d.ToArray(); RefNonce = $rn; CandNonce = $cn; CandImageSha = $cs; RefWithdrawn = (Get-FsNoWithdrawn $RefSha) } }
    $rn = $null; $cn = $null; $cs = $null
    foreach ($x in @(@('reference', $Ref), @('candidate', $Cand))) {
        if (-not (Test-Path -LiteralPath (Join-Path $x[1] 'MANIFEST.txt') -PathType Leaf)) { $d.Add("$($x[0]): no MANIFEST.txt in $($x[1])") }
        if (-not (Test-Path -LiteralPath (Join-Path $x[1] 'boot-stage3d.img') -PathType Leaf)) { $d.Add("$($x[0]): no boot-stage3d.img in $($x[1])") }
    }
    if ($d.Count) { return (& $res) }
    $mr = Read-FsNoLines (Join-Path $Ref 'MANIFEST.txt'); $mc = Read-FsNoLines (Join-Path $Cand 'MANIFEST.txt')
    $nonceOf = { param($m) $l = @($m | Where-Object { $_ -cmatch '^nonce:\s+([0-9a-f]{16})\s' }); if ($l.Count -eq 1 -and $l[0] -cmatch '^nonce:\s+([0-9a-f]{16})\s') { $Matches[1] } else { $null } }
    $rn = & $nonceOf $mr; $cn = & $nonceOf $mc
    if (-not $rn -or -not $cn) { $d.Add('a MANIFEST has no single nonce line'); return (& $res) }
    if ($rn -ceq $cn) { $d.Add("the nonces are the same ($rn): not a new single-use nonce") }
    $mline = { param($m, [string]$re) $l = @($m | Where-Object { $_ -cmatch $re }); if ($l.Count -eq 1) { [regex]::Match($l[0], $re) } else { $null } }
    $img = @{}
    foreach ($x in @(@('reference', $Ref, $rn, $mr), @('candidate', $Cand, $cn, $mc))) {
        if ((Split-Path -Leaf $x[1]) -cnotmatch ('^\d{8}T\d{6}Z-' + $x[2] + '\z')) { $d.Add("$($x[0]) directory '$(Split-Path -Leaf $x[1])' does not carry its nonce $($x[2])") }
        $ip = Join-Path $x[1] 'boot-stage3d.img'
        $sha = Get-FsNoSha $ip; $sz = (Get-Item -LiteralPath $ip).Length
        if ($x[0] -ceq 'candidate') { $cs = $sha }
        if ($x[0] -ceq 'reference' -and $sha -cne $RefSha) { $d.Add("the reference image $sha is not the reviewed candidate $RefSha") }
        $oi = & $mline $x[3] '^OUTPUT IMAGE:\s+boot-stage3d\.img\s+size=(\d+)\s+sha256=([0-9a-f]{64})\s*$'
        if ($null -eq $oi -or $oi.Groups[2].Value -cne $sha -or [long]$oi.Groups[1].Value -ne $sz) { $d.Add("$($x[0]) image (sha256 $sha, $sz bytes) is not its MANIFEST's OUTPUT IMAGE") }
        $bi = Read-FsNoBootImage $ip
        if (-not $bi.Ok) { $d.Add("$($x[0]) image: $($bi.Why)"); continue }
        $img[$x[0]] = $bi
        $lz = & $mline $x[3] '^ramdisk\.lz4\s+([0-9a-f]{64})\s+size=(\d+)\s*$'; $cp = & $mline $x[3] '^ramdisk\.cpio\s+([0-9a-f]{64})\s+size=(\d+)\s*$'
        if ($null -eq $lz -or $lz.Groups[1].Value -cne $bi.Lz4Sha -or [long]$lz.Groups[2].Value -ne $bi.RamdiskSize) { $d.Add("$($x[0]): the ramdisk in the image (lz4 sha256 $($bi.Lz4Sha), $($bi.RamdiskSize) bytes) is not its MANIFEST's ramdisk.lz4") }
        if ($null -eq $cp -or $cp.Groups[1].Value -cne $bi.CpioSha -or [long]$cp.Groups[2].Value -ne $bi.Cpio.Length) { $d.Add("$($x[0]): the unpacked ramdisk (cpio sha256 $($bi.CpioSha), $($bi.Cpio.Length) bytes) is not its MANIFEST's ramdisk.cpio") }
        # every "## ramdisk files" line of the MANIFEST equals the file in this image
        $byName = @{}; foreach ($en in $bi.Entries) { $byName['/' + $en.Name] = $en }
        foreach ($l in @($x[3] | Where-Object { $_ -cmatch '^[0-9a-f]{64}  \d+  /\S+  ' })) {
            $fm = [regex]::Match($l, '^([0-9a-f]{64})  (\d+)  (/\S+)  ')
            $en = $byName[$fm.Groups[3].Value]
            if ($null -eq $en) { $d.Add("$($x[0]): MANIFEST names $($fm.Groups[3].Value), which is not in the image's ramdisk"); continue }
            if ([long]$fm.Groups[2].Value -ne $en.Size -or (Get-FsNoBytesSha $bi.Cpio $en.Off $en.Size) -cne $fm.Groups[1].Value) { $d.Add("$($x[0]): $($fm.Groups[3].Value) in the image is not its MANIFEST line") }
        }
    }
    # the two images, byte for byte
    if ($img.ContainsKey('reference') -and $img.ContainsKey('candidate')) {
        $a = $img['reference']; $c = $img['candidate']
        if ($a.Bytes.Length -ne $c.Bytes.Length) { $d.Add("the image sizes differ ($($a.Bytes.Length) / $($c.Bytes.Length) bytes): rebuild with another nonce") }
        else {
            [byte[]]$ha = New-Object byte[] 4096; [byte[]]$hc = New-Object byte[] 4096
            [Array]::Copy($a.Bytes, $ha, 4096); [Array]::Copy($c.Bytes, $hc, 4096)
            for ($i = 12; $i -lt 16; $i++) { $ha[$i] = 0; $hc[$i] = 0 }
            if ((Get-FsNoBytesSha $ha) -cne (Get-FsNoBytesSha $hc)) { $d.Add('the boot image headers differ beyond the ramdisk size (bytes 12-15)') }
            if ($a.KernelSize -ne $c.KernelSize -or -not (Test-FsNoEqual $a.Bytes ([int]$a.KernelOff) $c.Bytes ([int]$c.KernelOff) ([int]($a.RamdiskOff - $a.KernelOff)))) { $d.Add('the kernel bytes differ') }
            if ($a.SigOff -ne $c.SigOff -or -not (Test-FsNoEqual $a.Bytes ([int]$a.SigOff) $c.Bytes ([int]$c.SigOff) ([int]($a.Bytes.Length - $a.SigOff)))) { $d.Add('the bytes after the ramdisk differ') }
        }
        foreach ($y in @(@('reference', $a), @('candidate', $c))) {
            $pe = [int]($y[1].RamdiskOff + $y[1].RamdiskSize)
            if (-not (Test-FsNoZero $y[1].Bytes $pe ([int]($y[1].SigOff - $pe)))) { $d.Add("$($y[0]): non-zero bytes in the ramdisk's page padding") }
        }
        if ($a.Cpio.Length -ne $c.Cpio.Length) { $d.Add("the cpio sizes differ ($($a.Cpio.Length) / $($c.Cpio.Length) bytes)") }
        $ea = @($a.Entries); $ec = @($c.Entries)
        if ((@($ea | ForEach-Object Name) -join '|') -cne (@($ec | ForEach-Object Name) -join '|')) { $d.Add("the ramdisk file lists differ ($($ea.Count) / $($ec.Count) entries)") }
        else {
            for ($i = 0; $i -lt $ea.Count; $i++) {
                $x = $ea[$i]; $y = $ec[$i]
                if ($x.Header -cne $y.Header) { $d.Add("ramdisk /$($x.Name): cpio header differs ('$($x.Header)' / '$($y.Header)')"); continue }
                if ($x.Name -ceq 'init') {
                    $l1 = [Text.Encoding]::GetEncoding(28591)
                    $ta = $l1.GetString($a.Cpio, [int]$x.Off, [int]$x.Size); $tc = $l1.GetString($c.Cpio, [int]$y.Off, [int]$y.Size)
                    $occ = ([regex]::Matches($ta, [regex]::Escape($rn))).Count
                    if ($occ -lt 1) { $d.Add("ramdisk /init of the reference does not hold its nonce $rn"); continue }
                    # the candidate's nonce where the reference's stands: the result must be the candidate's /init exactly
                    if ($ta.Replace($rn, $cn) -cne $tc -or ([regex]::Matches($tc, [regex]::Escape($cn))).Count -ne $occ) { $d.Add("ramdisk /init differs beyond the nonce ($rn -> $cn at $occ place(s))") }
                    continue
                }
                if ($x.Size -gt 0 -and -not (Test-FsNoEqual $a.Cpio ([int]$x.Off) $c.Cpio ([int]$y.Off) ([int]$x.Size))) { $d.Add("ramdisk /$($x.Name) differs") }
            }
        }
    }
    # a builder test-override line is never part of a usable candidate (final review nit; only K4's stripped copy passes)
    foreach ($x in @(@('reference', $mr), @('candidate', $mc))) {
        if (@($x[1] | Where-Object { $_ -cmatch '^TEST OVERRIDES' }).Count -gt 0) { $d.Add("$($x[0]): MANIFEST has a TEST OVERRIDES line (a test build, not a candidate)") }
    }
    # the builder of each directory: a (build-image.sh, module-list-check tool) pair reviewed FOR THIS REFERENCE (delta review
    # MAJOR-1; J-141: each reviewed candidate has its own pairs, a pair of another candidate is refused)
    $pairs = @{}
    if ($RefSha -cmatch '^[0-9a-f]{64}\z' -and $script:FsNoCandidates.Contains($RefSha)) { $pairs = $script:FsNoCandidates[$RefSha].Builders }
    else { $d.Add("the reference sha $RefSha is not a reviewed candidate (no entry in the reviewed-candidate table): no reviewed builder pairs") }
    $bld = @{}
    foreach ($x in @(@('reference', $mr), @('candidate', $mc))) {
        $bm = & $mline $x[1] '^build-image\.sh\s+([0-9a-f]{64})\s+\(recorded\)\s*$'; $tm = & $mline $x[1] '^loaded modules\s.*module-list-check\.txt, tool ([0-9a-f]{64})\)\s*$'
        $bs = if ($null -ne $bm) { $bm.Groups[1].Value } else { '' }; $ts = if ($null -ne $tm) { $tm.Groups[1].Value } else { '' }
        if (-not $pairs.ContainsKey($bs) -or $pairs[$bs] -cne $ts) { $d.Add("$($x[0]): built by build-image.sh '$bs' with module-list-check tool '$ts': not a reviewed builder version for the reference $RefSha") }
        $bld[$x[0]] = $ts
    }
    # MANIFEST: line for line, the nonce-dependent lines excepted (the image and cpio sizes must match)
    if ($mr.Count -ne $mc.Count) { $d.Add("MANIFEST line counts differ ($($mr.Count) / $($mc.Count))") }
    else {
        for ($i = 0; $i -lt $mr.Count; $i++) {
            $a0 = $mr[$i]; $b0 = $mc[$i]
            if ($a0 -ceq $b0) { continue }
            if ($a0 -cmatch '^(built|nonce):' -and $b0 -cmatch '^(built|nonce):' -and $a0.Split(':')[0] -ceq $b0.Split(':')[0]) { continue }
            if ($a0 -cmatch '^ramdisk\.lz4\s' -and $b0 -cmatch '^ramdisk\.lz4\s') { continue }
            # the builder lines (checked against the reviewed pairs above)
            if ($a0 -cmatch '^build-image\.sh\s+[0-9a-f]{64}\s+\(recorded\)\s*$' -and $b0 -cmatch '^build-image\.sh\s+[0-9a-f]{64}\s+\(recorded\)\s*$') { continue }
            $tl = '^(loaded modules\s.*module-list-check\.txt, tool )[0-9a-f]{64}(\)\s*)$'
            $ta0 = [regex]::Match($a0, $tl); $tb0 = [regex]::Match($b0, $tl)
            if ($ta0.Success -and $tb0.Success -and $ta0.Groups[1].Value -ceq $tb0.Groups[1].Value -and $ta0.Groups[2].Value -ceq $tb0.Groups[2].Value) { continue }
            $sz2 = '^(OUTPUT IMAGE:\s+boot-stage3d\.img\s+size=\d+\s+sha256=|ramdisk\.cpio\s+)[0-9a-f]{64}(.*)$'
            $xa = [regex]::Match($a0, $sz2); $xb = [regex]::Match($b0, $sz2)
            if ($xa.Success -and $xb.Success -and $xa.Groups[1].Value -ceq $xb.Groups[1].Value -and $xa.Groups[2].Value -ceq $xb.Groups[2].Value) { continue }
            $ia = [regex]::Match($a0, '^[0-9a-f]{64}(\s+\d+\s+/init\s.*)$'); $ib = [regex]::Match($b0, '^[0-9a-f]{64}(\s+\d+\s+/init\s.*)$')
            if ($ia.Success -and $ib.Success -and $ia.Groups[1].Value -ceq $ib.Groups[1].Value) { continue }
            $d.Add("MANIFEST line $($i + 1) differs: '$a0' / '$b0'")
        }
    }
    # the side files
    # ramdisk-scan.txt (delta review MAJOR-1): lines 1-2 are per build (the scan time, the builder's temp path and the
    # image's own hash); line 2 must name this directory's own image; every other line identical
    $scanL1 = '^# initramfs BLAKE2 scan of boot-stage3d\.img  [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    $scanL2 = '^boot image:   /tmp/tmp\.[A-Za-z0-9]{1,32}/boot-stage3d\.img sha256=([0-9a-f]{64})$'
    $sa = Join-Path $Ref 'ramdisk-scan.txt'; $sb = Join-Path $Cand 'ramdisk-scan.txt'
    if (-not (Test-Path -LiteralPath $sa) -or -not (Test-Path -LiteralPath $sb)) { $d.Add('ramdisk-scan.txt missing in one of the two') }
    else {
        $la = Read-FsNoLines $sa; $lb = Read-FsNoLines $sb
        foreach ($y in @(@('reference', $la, $Ref), @('candidate', $lb, $Cand))) {
            $ls = $y[1]
            if ($ls.Count -lt 3 -or $ls[0] -cnotmatch $scanL1) { $d.Add("$($y[0]) ramdisk-scan.txt line 1 is not '# initramfs BLAKE2 scan of boot-stage3d.img  <UTC>'"); continue }
            $m2 = [regex]::Match($ls[1], $scanL2)
            if (-not $m2.Success) { $d.Add("$($y[0]) ramdisk-scan.txt line 2 is not 'boot image:   /tmp/tmp.<x>/boot-stage3d.img sha256=<64 hex>'"); continue }
            $own = Get-FsNoSha (Join-Path $y[2] 'boot-stage3d.img')
            if ($m2.Groups[1].Value -cne $own) { $d.Add("$($y[0]) ramdisk-scan.txt line 2 names image $($m2.Groups[1].Value), not this directory's image $own") }
        }
        if ($la.Count -ne $lb.Count) { $d.Add('ramdisk-scan.txt line counts differ') }
        else { for ($i = 2; $i -lt $la.Count; $i++) { if ($la[$i] -cne $lb[$i]) { $d.Add("ramdisk-scan.txt line $($i + 1) differs: '$($la[$i])' / '$($lb[$i])'") } } }
    }
    # module-list-check.txt: identical, except check 5's PASS line, present exactly when that side's tool has check 5
    $ma0 = Join-Path $Ref 'module-list-check.txt'; $mb0 = Join-Path $Cand 'module-list-check.txt'
    if (-not (Test-Path -LiteralPath $ma0) -or -not (Test-Path -LiteralPath $mb0)) { $d.Add('module-list-check.txt missing in one of the two') }
    else {
        $lA = Read-FsNoLines $ma0; $lB = Read-FsNoLines $mb0
        foreach ($y in @(@('reference', $lA), @('candidate', $lB))) {
            $has = @($y[1] | Where-Object { $_ -ceq $script:FsNoCheck5Line }).Count
            $want = if ($bld[$y[0]] -ceq $script:FsNoCheck5Tool) { 1 } else { 0 }
            if ($has -ne $want) { $d.Add("$($y[0]) module-list-check.txt has $has check-5 PASS line(s); its tool $($bld[$y[0]]) means $want") }
        }
        if ((@($lA | Where-Object { $_ -cne $script:FsNoCheck5Line }) -join "`n") -cne (@($lB | Where-Object { $_ -cne $script:FsNoCheck5Line }) -join "`n")) { $d.Add('module-list-check.txt differs (beyond check 5)') }
    }
    foreach ($f in 'ramdisk.list', 'applets.txt', 'avb-check.txt', 'gitcheck.txt') {
        $pa = Join-Path $Ref $f; $pb = Join-Path $Cand $f
        if (-not (Test-Path -LiteralPath $pa) -or -not (Test-Path -LiteralPath $pb)) { $d.Add("$f missing in one of the two"); continue }
        if ((Get-FsNoSha $pa) -cne (Get-FsNoSha $pb)) { $d.Add("$f differs") }
    }
    foreach ($pair in @(@('ramdisk.sha256', '^[0-9a-f]{64}(\s+\d+\s+init)$'), @('header-diff.txt', '^> ramdisk size: \d+$'))) {
        $pa = Join-Path $Ref $pair[0]; $pb = Join-Path $Cand $pair[0]
        if (-not (Test-Path -LiteralPath $pa) -or -not (Test-Path -LiteralPath $pb)) { $d.Add("$($pair[0]) missing in one of the two"); continue }
        $la = Read-FsNoLines $pa; $lb = Read-FsNoLines $pb
        if ($la.Count -ne $lb.Count) { $d.Add("$($pair[0]) line counts differ"); continue }
        for ($i = 0; $i -lt $la.Count; $i++) {
            if ($la[$i] -ceq $lb[$i]) { continue }
            $ma = [regex]::Match($la[$i], $pair[1]); $mb = [regex]::Match($lb[$i], $pair[1])
            if ($ma.Success -and $mb.Success -and ($pair[0] -ceq 'header-diff.txt' -or $ma.Groups[1].Value -ceq $mb.Groups[1].Value)) { continue }
            $d.Add("$($pair[0]) line $($i + 1) differs: '$($la[$i])' / '$($lb[$i])'")
        }
    }
    & $res
}

if ($script:FsNoInvocation -eq '.') { return }
$exit = 70
try {
    if (-not $Reference -or -not $Candidate) { Write-Output 'usage: fs-nonceonly3d.ps1 -Reference <reviewed candidate dir> -Candidate <rebuilt dir>   (reads files only)'; exit 64 }
    if ($ReferenceSha -cnotmatch '^[0-9a-f]{64}\z') { Write-Output 'usage: -ReferenceSha is 64 lowercase hex'; exit 64 }
    $r = Test-FsNonceOnly -Ref ([IO.Path]::GetFullPath($Reference)) -Cand ([IO.Path]::GetFullPath($Candidate)) -RefSha $ReferenceSha
    if ($r.Ok -and $r.RefWithdrawn) { Write-Output "NONCE-ONLY REBUILD OF A WITHDRAWN CANDIDATE: $Candidate differs from $Reference only by the nonce ($($r.RefNonce) -> $($r.CandNonce)), but the reference $ReferenceSha is withdrawn ($($r.RefWithdrawn)): history only, never a run image"; $exit = 1 }
    elseif ($r.Ok) { Write-Output "NONCE-ONLY REBUILD: OK: $Candidate differs from $Reference only by the nonce ($($r.RefNonce) -> $($r.CandNonce)); image sha256 $($r.CandImageSha)"; $exit = 0 }
    else { foreach ($l in $r.Diffs) { Write-Output "DIFF: $l" }; Write-Output "NOT A NONCE-ONLY REBUILD ($($r.Diffs.Count) difference(s)): do not use it without a review"; $exit = 1 }
} catch { Write-Output "NONCE-ONLY CHECK ERROR: $($_.Exception.Message)"; $exit = 70 }
exit $exit
