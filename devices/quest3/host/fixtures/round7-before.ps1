# FrameShift host — before/after probe for fix round 7 (re-review of 685da7c). Run against this
# tree and against a copy of 685da7c; every probe must FAIL there and PASS here. No device.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File fixtures\round7-before.ps1 [-HostDir <host dir under test>]
param([string]$HostDir = '')
$ErrorActionPreference = 'Stop'
$FIX = $PSScriptRoot
$CODE = if ($HostDir) { [IO.Path]::GetFullPath($HostDir) } else { Split-Path -Parent $PSScriptRoot }
$Q3live = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))          # the sources the fake MANIFEST binds to
. (Join-Path $CODE 'fs-collect.ps1')
. (Join-Path $CODE 'fs-observe.ps1')
. (Join-Path $FIX 'synth.ps1')
$pass = 0; $fail = 0
function P([string]$name, [scriptblock]$probe) {
    $ok = $false; $why = ''
    try { $ok = [bool](& $probe) } catch { $why = $_.Exception.Message }
    if ($ok) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name $why" }
}
function Tmp { Join-Path ([IO.Path]::GetTempPath()) ('r7-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
# a stage-2a build folder OUTSIDE the repository's build\stage2a (a copy)
$nonce = 'c0de0b5e0000aa01'
$bd = Join-Path (Tmp) "copy\20261009T090000Z-$nonce"; $null = New-Item -ItemType Directory -Force -Path $bd
$img = Join-Path $bd 'boot-stage2a.img'; [IO.File]::WriteAllBytes($img, [byte[]](1..64 | ForEach-Object { [byte]$_ }))
$h = { param($f) (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Q3live $f)).Hash.ToLower() }
[IO.File]::WriteAllText((Join-Path $bd 'MANIFEST.txt'), ("FrameShift Quest 3 stage-2a image (probe)`nnonce:            $nonce   (x)`n" +
    "OUTPUT IMAGE:     boot-stage2a.img  size=64  sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $img).Hash.ToLower())`n" +
    "stock boot        49bba46377b52de5f111c90ef38b7a81f2e889eaebfcdff52225c4b5947b2d50  x`nstock vendor_boot 1e3b3762724478a7f592a11a7872cb8f7c55f0f882d7bb283ecbeffd691dbbcf  x`n" +
    "init.sh source    $(& $h 'stage2a\init.sh')  x`nfs-valve.sh       $(& $h 'stage2a\fs-valve.sh')  x`nfs-inv.sh         $(& $h 'stage2a\fs-inv.sh')  x`n"))
Write-Output "== round-7 probes, code under test: $CODE"
P 'SF1  a build folder copied outside <repo>\build\stage2a is refused even at -Preflight (exit 2)' {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $CODE 'fs-observe.ps1') -Stage 2a -Image $img -Preflight
    $LASTEXITCODE -eq 2 }
P 'NIT4 the observer exposes a conservative handoff basis (HandoffBasisUtc)' {
    ([IO.File]::ReadAllText((Join-Path $CODE 'fs-observe.ps1')) -match 'HandoffBasisUtc') }
P 'NIT3 runner budget: with 100 s to give-up the runner (127 + 5 s) is not sent; gated fs-done' {
    $r = Invoke-FsReplay -RawPath (Join-Path $FIX 'replay\runner-budget.raw') -OutDir (Tmp) -Overrides @{ GiveUpMs = [long]100000 }
    (-not $r.ValveSent) -and $r.DoneSent -and $r.StopReason -match 'runner budget' }
P 'NIT7 foreign ack at the end of the ack window: fs-done still sent' {
    $r0 = Invoke-FsReplay -RawPath (Join-Path $FIX 'replay\already-acked.raw') -OutDir (Tmp)
    $sp = @($r0.Phases | Where-Object { $_.Verb -ceq 'fs-status' })[0]
    $r = Invoke-FsReplay -RawPath (Join-Path $FIX 'replay\already-acked.raw') -OutDir (Tmp) -Overrides @{ AckGiveUpMs = [long]($sp.SendMs + 100) }
    $r.DoneSent }
P 'NEW  stage 3a display cue: an N display-cue line precedes the fs-display write by >= 3 s' {
    $r = Invoke-FsReplay -RawPath (Join-Path $FIX 'replay\3a-committed.raw') -OutDir (Tmp) -Overrides @{ Stage = '3a' }
    $ix = [IO.File]::ReadAllLines($r.Capture.Index)
    $c = @($ix | Where-Object { $_ -cmatch '^N \d+ \d+ display-cue\z' }); $w = @($ix | Where-Object { $_ -cmatch '^W \d+ \d+ fs-display ' })
    $c.Count -eq 1 -and $w.Count -eq 1 -and ([long]$w[0].Split(' ')[2] - [long]$c[0].Split(' ')[2]) -ge 3000 }
Write-Output "TOTAL: $pass passed, $fail failed"
