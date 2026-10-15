# FrameShift misc before/after rule (MISC-RULE.md v1), Windows PowerShell 5.1.
# A port of devices/quest3/common/tools/misc_rule.py. It must print the same
# finding lines, the same "VERDICT <class>" and return the same exit status as
# the Python reference for every input (test-host2.ps1 section M runs both
# on every case and compares the full output).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File fs-miscrule.ps1 BEFORE.img AFTER.img
#   exit 10 UNCHANGED, 11 EXPECTED, 12 RECORDED, 13 STOP, 14 INCONCLUSIVE, 64 usage
#   (as misc_rule.py after the second review, S2: no verdict code is 0, 1 or 2, so a crash or a
#   PowerShell/parameter failure can never be read as a verdict)
#
# Or dot-source and call Get-FsMiscVerdict -Before <byte[]> -After <byte[]>.
#
# Regions (Quest 3 Unit 1, 1 MiB misc; FS-A-005 control data):
#   C  0x0000-0x001f  bootloader_message.command (32 bytes)
#   V  0x1010-0x101b  vendor field the stock control changed (3 x u32 LE)
#   O  every other byte
# No param block: arguments are taken positionally from $args exactly as misc_rule.py takes sys.argv
# (review nit: two arguments or usage 64; an empty or unreadable path is INCONCLUSIVE 14).
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'fs-native.ps1')

$script:MiscSize = 1048576
$script:MiscCLo = 0x0000; $script:MiscCHi = 0x0020      # [lo, hi)
$script:MiscVLo = 0x1010; $script:MiscVHi = 0x101C
$script:MiscE0 = New-Object byte[] 32
$script:MiscE1 = New-Object byte[] 32
[byte[]]$_e1 = [Text.Encoding]::ASCII.GetBytes('bootonce-bootloader')
[Array]::Copy($_e1, $script:MiscE1, $_e1.Length)
$script:MiscRank = @{ UNCHANGED = 0; EXPECTED = 1; RECORDED = 2; STOP = 3; INCONCLUSIVE = 4 }

function Test-FsBytesEqual { param([byte[]]$A, [byte[]]$B)
    if ($A.Length -ne $B.Length) { return $false }
    return ([FsHostNative]::DiffIndices($A, $B).Length -eq 0)
}
function Get-FsSlice { param([byte[]]$B, [int]$Lo, [int]$Hi)
    $r = New-Object byte[] ($Hi - $Lo); [Array]::Copy($B, $Lo, $r, 0, $Hi - $Lo); ,$r
}
function Get-FsMiscCName { param([byte[]]$B)
    if (Test-FsBytesEqual $B $script:MiscE0) { return 'E0(empty)' }
    if (Test-FsBytesEqual $B $script:MiscE1) { return 'E1(bootonce-bootloader)' }
    return 'other:' + [FsHostNative]::Hex($B)
}

function Get-FsMiscVerdict {
    param([byte[]]$Before, [byte[]]$After)
    if ($null -eq $Before) { $Before = [byte[]]@() }
    if ($null -eq $After)  { $After  = [byte[]]@() }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(('before sha256={0} size={1}' -f (Get-FsSha256Hex $Before), $Before.Length))
    $out.Add(('after  sha256={0} size={1}' -f (Get-FsSha256Hex $After), $After.Length))
    if ($Before.Length -ne $script:MiscSize -or $After.Length -ne $script:MiscSize) {
        $out.Add(('INCONCLUSIVE capture size is not {0} bytes: persistent-state accounting impossible' -f $script:MiscSize))
        return [pscustomobject]@{ Verdict = 'INCONCLUSIVE'; Rank = 4; Lines = $out.ToArray() }
    }
    $verdict = 'UNCHANGED'
    $raise = { param($v) if ($script:MiscRank[$v] -gt $script:MiscRank[$verdict]) { Set-Variable -Name verdict -Value $v -Scope 1 } }

    $diffs = [FsHostNative]::DiffIndices($Before, $After)
    $other = @($diffs | Where-Object { -not (($_ -ge $script:MiscCLo -and $_ -lt $script:MiscCHi) -or ($_ -ge $script:MiscVLo -and $_ -lt $script:MiscVHi)) })
    if ($other.Count -gt 0) {
        # same run construction as misc_rule.py
        $runs = New-Object System.Collections.Generic.List[string]
        $s = $other[0]; $p = $other[0]
        $seq = @($other | Select-Object -Skip 1) + @($null)
        foreach ($i in $seq) {
            if ($null -ne $i -and $i -eq $p + 1) { $p = $i; continue }
            $runs.Add(('0x{0:x5}-0x{1:x5}' -f $s, $p))
            if ($null -ne $i) { $s = $i; $p = $i }
        }
        $shown = @($runs | Select-Object -First 8)
        $out.Add(('STOP {0} byte(s) changed outside C and V: {1}' -f $other.Count, ($shown -join ', ')))
        & $raise 'STOP'
    }

    $cb = Get-FsSlice $Before $script:MiscCLo $script:MiscCHi
    $ca = Get-FsSlice $After  $script:MiscCLo $script:MiscCHi
    $bE0 = Test-FsBytesEqual $cb $script:MiscE0; $bE1 = Test-FsBytesEqual $cb $script:MiscE1
    $aE0 = Test-FsBytesEqual $ca $script:MiscE0; $aE1 = Test-FsBytesEqual $ca $script:MiscE1
    $accepted = ($bE0 -and $aE0) -or ($bE1 -and $aE1) -or ($bE0 -and $aE1)
    if ($accepted) {
        if (-not (Test-FsBytesEqual $cb $ca)) {
            $out.Add(("EXPECTED boot command {0} -> {1} (Android 'reboot bootloader')" -f (Get-FsMiscCName $cb), (Get-FsMiscCName $ca)))
            & $raise 'EXPECTED'
        } else {
            $out.Add(('ok boot command unchanged {0}' -f (Get-FsMiscCName $cb)))
        }
    } else {
        $out.Add(('STOP boot command transition not specifically expected: {0} -> {1}' -f (Get-FsMiscCName $cb), (Get-FsMiscCName $ca)))
        & $raise 'STOP'
    }

    $vb = Get-FsSlice $Before $script:MiscVLo $script:MiscVHi
    $va = Get-FsSlice $After  $script:MiscVLo $script:MiscVHi
    if (-not (Test-FsBytesEqual $vb $va)) {
        $words = @(for ($k = 0; $k -lt 3; $k++) {
            '{0} 0x{1:x8}->0x{2:x8} ({3}->{4})' -f "w$k", [BitConverter]::ToUInt32($vb, 4 * $k), [BitConverter]::ToUInt32($va, 4 * $k),
                [BitConverter]::ToInt32($vb, 4 * $k), [BitConverter]::ToInt32($va, 4 * $k)
        })
        $out.Add(('RECORDED vendor field 0x1010-0x101b changed: {0}; presumed reboot-related ' -f ($words -join ', ') +
                  '(the stock control changed the same field); location alone does not establish harmlessness'))
        & $raise 'RECORDED'
    } else {
        $out.Add('ok vendor field 0x1010-0x101b unchanged')
    }
    $vabSame = Test-FsBytesEqual (Get-FsSlice $Before 0x8000 0x8020) (Get-FsSlice $After 0x8000 0x8020)
    $out.Add(('info VAB message 0x8000: {0}' -f $(if ($vabSame) { 'unchanged' } else { 'CHANGED (already STOP above)' })))
    return [pscustomobject]@{ Verdict = $verdict; Rank = $script:MiscRank[$verdict]; Lines = $out.ToArray() }
}

if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'
if ($args.Count -ne 2) { Write-Output 'usage: fs-miscrule.ps1 BEFORE.img AFTER.img'; exit 64 }
$BeforePath = [string]$args[0]; $AfterPath = [string]$args[1]
# A missing or unreadable capture, or any error while classifying, is INCONCLUSIVE (exit 14), as in
# misc_rule.py. The message text after "INCONCLUSIVE " differs (.NET vs Python exception names); the
# VERDICT line and the exit status are identical.
try {
    [byte[]]$bb = [IO.File]::ReadAllBytes($BeforePath); [byte[]]$ab = [IO.File]::ReadAllBytes($AfterPath)
    $r = Get-FsMiscVerdict -Before $bb -After $ab
} catch {
    Write-Output "INCONCLUSIVE cannot read or classify the captures: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    Write-Output 'VERDICT INCONCLUSIVE'
    exit 14
}
foreach ($l in $r.Lines) { Write-Output $l }
Write-Output ('VERDICT ' + $r.Verdict)
exit (10 + $r.Rank)
