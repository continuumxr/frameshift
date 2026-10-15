# FrameShift stage-2a / stage-3a / stage-3b serial collector (Windows PowerShell 5.1, no modules).
# Design: COLLECTOR.md. Replaces the scratch serial-collect.ps1 (FS-A-005 §8
# D1, FS-R-005 §5 D1, FS-A-006 §5.5 item 1). Revision 2: adversarial review of
# da0ad56 (BLOCKER 1 send gate, SHOULD-FIX 4 escaping, nits: capture errors,
# write logging, bounded close, host deadline derived from the device's).
#
# Revision 10 (FS-R-010, trial (iii-b)): -Stage 3b. The runner verb is fs-display again (the
# image is a different one: nonce, exp=stage3b, 5 steps hash,probe1,pattern1,probe2,pattern2),
# device deadline 200 s (stage3b/init.sh), RunnerWorstSec 75 s (stage3b/tools/check-timing-3b.py
# derives it from the runner's implemented bounds, incl. the maximum paced emission), the
# two-period display cue text, its own beep texts and, after beep 2, the per-eye/per-period
# report prompt (FSR1 lines for fs-classify.ps1 -Stage 3b -Readings). Everything else (send gate,
# clock model, recovery) is the same code path; stage 2a and 3a behaviour and texts are unchanged.
# Revision 9 (Chair ruling FS-R-007 B1: a conservative origin, preparation time counted):
#   - the budget ORIGIN is -BootStartUtc: the host's UTC time taken just BEFORE `fastboot boot`
#     was invoked (fs-observe.ps1 observe.json BootStartUtc), for EVERY handoff class. T0 (PID 1
#     starts) cannot precede it, so every host deadline origin + X <= T0 + X. -HandoffUtc (when
#     `fastboot boot` returned) is recorded as evidence only: a successful return does not prove
#     it preceded T0 (host scheduling and output handling can delay it).
#   - the host give-up (origin + DEADLINE - HostMarginSec) and the ack-window give-up
#     (origin + ACK_WINDOW - HostMarginSec) are ABSOLUTE UTC times. They are converted into the
#     transport's monotonic clock only AFTER the preparation (gadget lookup, transport
#     construction), from a fresh read (transport clock first, then UTC), so time spent preparing
#     is never added back (no remaining time computed before the preparation is carried over).
#     The start refusals (< 60 s to the give-up, < 30 s of the ack window) are re-checked then.
#   - from then on every wait, the send gate before every phase, and the runner guard
#     immediately before the runner use that monotonic clock. A late start: INCONCLUSIVE, no
#     runner; fs-done only from the established shell state (unchanged).
#   collect.json records Timing (origin, handoff evidence, absolute give-ups, conversion point).
# Revision 5 (fix round 7, re-review of 685da7c):
#   - before the runner is sent, the time left to the host give-up must cover the runner's
#     worst case plus a margin (RunnerWorstSec + RunnerMarginSec of the stage spec;
#     stage2a/tools/check-timing.py checks the spec against the sources). Otherwise: stop,
#     INCONCLUSIVE, no runner, gated fs-done (NIT3);
#   - the gated fs-done is exempt from the ACK-WINDOW cap (not from the prompt/tail gate), so a
#     foreign-ack stop near the end of the window still recovers at once (NIT7);
#   - stage 3a: the DISPLAY CUE. Just before fs-display the collector prints
#     "=== LOOK INTO THE LENSES NOW ... ===", records an N line in capture.raw.idx, waits
#     -DisplayCueMs (3 s) read-only, then sends through the normal gate (PM usability).
# Revision 4 (fix round 6, package reviews of cf251bb):
#   - the ACK WINDOW is part of the timing: every phase before the runner (drain, fs-verify,
#     fs-ack, fs-status) is capped at handoff + ACK_WINDOW - HostMarginSec, and live mode
#     refuses to start with less than 30 s of that left (e2e S1);
#   - a FOREIGN ACK (FSS1 acked=<a token we did not send>: another host session acked
#     first; PID 1 records only the first ack) stops at once, INCONCLUSIVE, then the gated
#     fs-done: nothing is gained by holding a device another session is talking to (B1);
#   - a RUNNER REFUSAL (FSVE1/FSDE1 ... END instead of a record) is terminal: INCONCLUSIVE,
#     then the gated fs-done (recover now, not at the deadline) (e2e S2);
#   - stage 3a, single-operator protocol (revision 8, Chair review of FS-A-007 S3): the PM
#     keeps the headset on from the display cue. After the record (fs-pattern's hold has
#     ended) the HOST console beeps (beep 1, high), a read-only pause of -PreDoneMs (10 s)
#     lets the PM confirm the panels are dark, a second, distinct beep (low, longer) marks
#     fs-done. Both beeps are N lines in capture.raw.idx; nothing is sent to the device.
#   The stage-1 class of a run comes from fs-observe.ps1 (handoff, gadget) plus this
#   collector's verified FSV1 (fs-classify.ps1 -ObserveDir); fs-observe never opens the port.
# Revision 3 (coordinated round with common/stage2a/stage3a): -Stage 2a|3a selects the
# runner verb (fs-valve | fs-display), the experiment id, the step list and the device
# deadline (stage2a T0+260 s, stage3a T0+170 s: the images' init.sh DEADLINE); the
# stage-2a list has 8 steps (OUTCOMES rev 4: step 8 `inv`, informational).
#
# LIVE (only with the PM's sign-off; never run by fixtures):
#   fs-collect.ps1 [-Stage 2a|3a|3b] -Port COM7 -Nonce <16 hex> -BootStartUtc <observe.json BootStartUtc, ISO 8601>
#                  [-HandoffUtc <observe.json HandoffUtc: evidence only>] -OutDir <new dir>
# REPLAY (offline; a capture plus its index, through the same code path):
#   fs-collect.ps1 -Replay <capture.raw> [-ReplayIndex <capture.raw.idx>] -OutDir <new dir> [-Nonce ...]
#
# Exit (no verdict code is 0, 1 or 2, so a PowerShell crash can never read as one):
#   10 record collected, FSB1-valid   11 record collected, FSB1 rejected
#   14 INCONCLUSIVE (no complete record)   20 refused to start (nothing sent)   70 internal error
#
# Rules (each one has fixtures in test-host2.ps1 sections R, F):
#  1. The port is a parameter. It is never chosen; in live mode it must be the
#     COM port Windows registered under the FS-<nonce> gadget (Get-FsGadget).
#  2. Bytes from the device are DATA ONLY. Every command is built by
#     New-FsCommand from a fixed verb and a host-generated hex token and
#     checked against ^[a-z0-9 -]+$; no captured byte can reach a write.
#     No quote, no repair keystroke, no blind newline is ever sent.
#  3. Send gate (revision 2). Immediately before EVERY write the collector
#     reads whatever has arrived, then requires:
#       - the first command: either no byte at all has arrived, or the tail of
#         the whole capture is a primary prompt (then that exact prompt, bytes
#         included, becomes the expected prompt);
#       - every later command: zero bytes since the last settled prompt, and
#         the tail of the whole capture byte-identical to the expected prompt;
#       - the host deadline not reached.
#     Otherwise nothing is sent, ever again, and the result is INCONCLUSIVE.
#     A prompt is "settled" after the previous command's completion record
#     (a tag the host never sends, at the start of a line, newline-terminated,
#     after the send offset) and then the prompt with no further bytes for
#     PromptSettleMs.
#  4. Missing completion, partial output, a continuation prompt, an
#     echo-only or silent target, a changed tail: stop. Nothing more is sent
#     (not even fs-done); the PID 1 deadline recovers.
#  5. The host gives up HostMarginSec before the device's own deadline, counted
#     from BootStartUtc (taken before `fastboot boot` was invoked, so no later than
#     T0): host stop <= BootStartUtc + DEADLINE - margin <= T0 + DEADLINE - margin.
#     Assumptions: the host clock does not jump between BootStartUtc and the
#     conversion (UTC), and the transport clock is monotonic (Stopwatch) after it.
#  6. The capture is the raw byte stream, written as read (no text decoding
#     in the capture path), with an index of read chunks and completed host
#     writes and a SHA-256 computed while writing and re-checked from disk.
#  7. FSB1 validation is common/host/fsb1.ps1 (Test-Fsb1Record) over the
#     whole raw capture file.
#  8. Device-derived text is printed only through ConvertTo-FsPrintable
#     (\xNN for anything outside [ -~]).
[CmdletBinding()]
param(
    [string]$Port, [string]$Nonce, [string]$OutDir,
    [string]$Replay, [string]$ReplayIndex,
    [string]$BootStartUtc,              # live, REQUIRED: the budget origin = observe.json BootStartUtc (taken just before `fastboot boot` was invoked; T0 is not earlier)
    [string]$HandoffUtc,                # live, optional: observe.json HandoffUtc (when `fastboot boot` returned). EVIDENCE ONLY, never a budget origin
    [ValidateSet('2a', '3a', '3b')][string]$Stage = '2a',
    [int]$DeviceDeadlineSec = 0,       # 0 = the stage's image deadline (stage2a 260, stage3a 170, stage3b 200: init.sh DEADLINE)
    [int]$HostMarginSec = 15,          # the host stops this long before the earliest device deadline
    [int]$AckWindowSec = 0,            # 0 = the stage's image ACK_WINDOW (150 s: init.sh); pre-runner phases end by BootStartUtc + this - HostMarginSec
    [int]$PreDoneMs = -1,              # -1 = stage default (2a: 0; 3a: 10000, revision 8): read-only pause between beep 1 and beep 2, before fs-done
    [string]$Exp = '',                 # '' = the stage's (fixtures only: another experiment id)
    [string[]]$Steps = @(),            # empty = the stage's step list (fixtures only: another list)
    [string]$Kernel = '5.10.198-01402-g1c5986fe21ee',
    [string]$Pid1 = '/bin/busybox,sh,/init',
    [int]$StepTimeoutMs = 10000,       # fs-verify / fs-ack / fs-status / fs-done completion
    [int]$RecordTimeoutMs = 240000,    # the runner (fs-valve / fs-display); always capped by the host give-up time
    [int]$PromptWaitMs = 3000,         # primary prompt after a completion record
    [int]$PromptSettleMs = 150,        # ...and no further bytes for this long
    [int]$AckSettleMs = 2500,          # PID 1 polls the ack once per second
    [int]$AckStatusTries = -1,         # -1 = stage default (2a: 3; 3a: 2, revision 8: makes room for the 3a pre-done pause)
    [int]$InitialDrainMs = 1000,       # read (never write) before the first command
    [int]$PollMs = 50,
    [switch]$NoDone,
    [long]$TestCaptureFailAfterBytes = -1,   # FIXTURES ONLY: simulate a full disk
    [switch]$TestCaptureFailOnClose          # FIXTURES ONLY: simulate a failing close
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:FsHostDir = $PSScriptRoot
. (Join-Path $PSScriptRoot '..\stage1\fs-proto.ps1')     # Test-FsVerify, Test-FsAck, Get-FsGadget, New-FsHex (read only)
. (Join-Path $PSScriptRoot '..\common\host\fsb1.ps1')    # Test-Fsb1Record (read only)
. (Join-Path $PSScriptRoot 'fs-native.ps1')

$script:Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$script:FsLastCtx = $null

# Per stage: the runner verb, the FSB1 experiment id and step list (common/OUTCOMES.md §2, §8)
# and the image's PID 1 deadline in seconds (stage2a/init.sh, stage3a/init.sh DEADLINE;
# stage2a/tools/check-timing.py checks that these agree with the images).
$script:FsStageSpec = @{
    '2a' = @{ Verb = 'fs-valve';   Exp = 'stage2a'; DeviceDeadlineSec = 260; AckWindowSec = 150; Refusal = 'FSVE1'; PreDoneMs = 0
              RunnerWorstSec = 127; RunnerMarginSec = 5; DisplayCueMs = 0; AckStatusTries = 3; Beep1Ms = 0; Beep2Ms = 0
              Steps = @('hash', 'absent', 'diag', 'list', 'uname', 'b2kat', 'b2chal', 'inv') }
    '3a' = @{ Verb = 'fs-display'; Exp = 'stage3a'; DeviceDeadlineSec = 170; AckWindowSec = 150; Refusal = 'FSDE1'; PreDoneMs = 10000
              RunnerWorstSec = 42; RunnerMarginSec = 5; DisplayCueMs = 3000; AckStatusTries = 2; Beep1Ms = 300; Beep2Ms = 700
              Steps = @('hash', 'pattern') }
    '3b' = @{ Verb = 'fs-display'; Exp = 'stage3b'; DeviceDeadlineSec = 200; AckWindowSec = 150; Refusal = 'FSDE1'; PreDoneMs = 10000
              RunnerWorstSec = 75; RunnerMarginSec = 5; DisplayCueMs = 3000; AckStatusTries = 2; Beep1Ms = 300; Beep2Ms = 700
              Steps = @('hash', 'probe1', 'pattern1', 'probe2', 'pattern2') }
}
# Stage-3b texts (revision 10). The stage-2a/3a texts stay in the code below, unchanged.
$script:FsCue3b = '=== LOOK INTO THE LENSES NOW: a FIRST lit period (run 1, about 3 seconds) should start about 3.5 to 6.5 seconds from now, then a DARK gap of at least 2 seconds, then a SECOND lit period (run 2, about 10 seconds). Keep looking until the SECOND (LOW) BEEP. Note for EACH EYE and EACH PERIOD: dark, lit, garbled, or the 8 characters ==='
$script:FsBeep1Text3b = 'BEEP 1: both runs have ended and the record is in. KEEP LOOKING INTO THE LENSES: the panels should now be DARK. fs-done follows the second (low) beep in {0} s.'
$script:FsBeep2Text3b = 'BEEP 2: end of the pause; fs-done follows now if the shell state is unchanged (send gate). Note whether the panels were dark during the pause.'
$script:FsReport3b = @(
    'REPORT (the PM, now, from memory; one line per period and eye; the Arbiter records them verbatim as readings.txt):',
    '  FSR1 run=1 eye=left obs=<DARK|LIT|GARBLED|READ> [chars=<the 8 characters, ? for any unreadable one>]',
    '  FSR1 run=1 eye=right obs=...',
    '  FSR1 run=2 eye=left obs=...',
    '  FSR1 run=2 eye=right obs=...',
    '  DARK = no light seen (no light seen is not zero emitted light or zero exposure); LIT = light but no pattern; GARBLED = a pattern that cannot be read (lines, noise, misplaced); READ = the characters as read.',
    '  Also note: the square at the top-left, the line under the characters, and 1 or 2 bars below the cross, per eye.',
    '  Then: fs-classify.ps1 -Stage 3b -CollectDir <dir> -ObserveDir <dir> -Readings <readings.txt>')

# ------------------------------------------------------------ commands -----
# The ONLY way a byte reaches the target. Verb from a fixed table, argument a
# host-generated token of a fixed form; the final text is re-checked.
$script:FsCmdSpec = [ordered]@{
    'fs-verify' = '^[0-9a-f]{32}\z'
    'fs-ack'    = '^[0-9a-f]{16}\z'
    'fs-status' = $null
    'fs-valve'  = '^[0-9a-f]{32}\z'
    'fs-display' = '^[0-9a-f]{32}\z'
    'fs-done'   = $null
}
function New-FsCommand {
    param([Parameter(Mandatory)][string]$Verb, [string]$Arg = '')
    if (-not $script:FsCmdSpec.Contains($Verb)) { throw "refused: verb '$(ConvertTo-FsPrintable $Verb)' is not in the command table" }
    $re = $script:FsCmdSpec[$Verb]
    if ($null -eq $re) {
        if ($Arg -ne '') { throw "refused: $Verb takes no argument" }
        $text = $Verb
    } else {
        if ($Arg -cnotmatch $re) { throw "refused: argument for $Verb does not match $re" }
        $text = "$Verb $Arg"
    }
    if ($text -cnotmatch '^[a-z0-9 -]{1,64}\z') { throw 'refused: command text outside [a-z0-9 -]' }
    return $text
}

# ------------------------------------------------------------- capture -----
# Raw bytes to <OutDir>\capture.raw exactly as read; index to capture.raw.idx:
#   FSIDX1 nonce=<n16> mode=<live|replay> port=<COMn|->
#   R <offset> <length> <ms>       bytes [offset, offset+length) read at ms
#   W <offset> <ms> <command>      command written (completed) when <offset> bytes had been read
function New-FsCapture {
    param([Parameter(Mandatory)][string]$Dir, [string]$Nonce, [string]$Mode, [string]$PortName,
          [long]$FailAfterBytes = -1, [bool]$FailOnClose = $false)
    if (Test-Path -LiteralPath $Dir) { throw "refused: output directory already exists: $Dir" }
    $null = New-Item -ItemType Directory -Path $Dir
    $rawPath = Join-Path $Dir 'capture.raw'
    $fs = [System.IO.File]::Open($rawPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $ixs = [System.IO.File]::Open("$rawPath.idx", [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $ix = New-Object System.IO.StreamWriter($ixs, (New-Object System.Text.UTF8Encoding($false)))
    $ix.NewLine = "`n"
    $ix.WriteLine("FSIDX1 nonce=$Nonce mode=$Mode port=$PortName"); $ix.Flush()
    $c = [pscustomobject]@{
        Dir = $Dir; RawPath = $rawPath; IdxPath = "$rawPath.idx"; Fs = $fs; Ix = $ix
        Sha = [System.Security.Cryptography.SHA256]::Create(); Mem = (New-Object System.IO.MemoryStream)
        Length = [long]0; Closed = $false; Sha256 = $null; FailAfter = $FailAfterBytes; FailOnClose = $FailOnClose
    }
    $c | Add-Member ScriptMethod Append {
        param([byte[]]$b, [long]$ms)
        if ($b.Length -eq 0) { return }
        if ($this.FailAfter -ge 0 -and $this.Length + $b.Length -gt $this.FailAfter) {
            throw (New-Object System.IO.IOException('capture write failed: There is not enough space on the disk (simulated by -TestCaptureFailAfterBytes)'))
        }
        try {
            $this.Fs.Write($b, 0, $b.Length); $this.Fs.Flush()
            $this.Ix.WriteLine("R $($this.Length) $($b.Length) $ms"); $this.Ix.Flush()
        } catch { throw (New-Object System.IO.IOException("capture write failed: $($_.Exception.Message)")) }
        $null = $this.Sha.TransformBlock($b, 0, $b.Length, $null, 0)
        $this.Mem.Write($b, 0, $b.Length)
        $this.Length += $b.Length
    }
    $c | Add-Member ScriptMethod NoteWrite { param([string]$text, [long]$ms) $this.Ix.WriteLine("W $($this.Length) $ms $text"); $this.Ix.Flush() }
    # N lines (revision 5): host-side events that are not writes (the stage-3a display cue); replay ignores them
    $c | Add-Member ScriptMethod NoteEvent { param([string]$text, [long]$ms) $this.Ix.WriteLine("N $($this.Length) $ms $text"); $this.Ix.Flush() }
    $c | Add-Member ScriptMethod Bytes { param([long]$from) $all = $this.Mem.GetBuffer(); $n = [int]($this.Length - $from)
        $r = New-Object byte[] $n; [Array]::Copy($all, [int]$from, $r, 0, $n); ,$r }
    # Close never loses the hash; it reports (throws) after releasing everything it can.
    $c | Add-Member ScriptMethod Close {
        if ($this.Closed) { return }
        $this.Closed = $true
        $null = $this.Sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $this.Sha256 = [FsHostNative]::Hex($this.Sha.Hash)
        $errs = New-Object System.Collections.Generic.List[string]
        foreach ($d in @($this.Sha, $this.Fs, $this.Ix)) { try { $d.Dispose() } catch { $errs.Add($_.Exception.Message) } }
        if ($this.FailOnClose) { $errs.Add('close failed (simulated by -TestCaptureFailOnClose)') }
        if ($errs.Count) { throw (New-Object System.IO.IOException('capture close failed: ' + ($errs -join '; '))) }
    }
    $c
}

# ----------------------------------------------------------- transports -----
# Interface: ReadBytes(untilMs) -> byte[] (possibly empty; never blocks),
# WriteBytes(byte[]), NowMs(), Idle(untilMs), Dispose().
function New-FsRawSerialTransport {
    param([Parameter(Mandatory)][string]$PortName, [int]$PollMs = 50)
    $sp = New-Object System.IO.Ports.SerialPort $PortName, 115200, 'None', 8, 'One'
    $sp.Handshake = [System.IO.Ports.Handshake]::None
    $sp.DtrEnable = $true; $sp.RtsEnable = $true      # CDC-ACM: DTR tells the gadget a host opened the port
    $sp.ReadTimeout = 200; $sp.WriteTimeout = 2000
    $sp.DiscardNull = $false                          # keep NUL bytes
    $sp.ParityReplace = [byte]0                       # never substitute bytes
    $sp.ReadBufferSize = 4MB
    $t = [pscustomobject]@{ Port = $sp; Clock = [System.Diagnostics.Stopwatch]::StartNew(); PollMs = $PollMs; Kind = 'live' }
    $t | Add-Member ScriptMethod Open { $this.Port.Open() }
    $t | Add-Member ScriptMethod NowMs { [long]$this.Clock.ElapsedMilliseconds }
    $t | Add-Member ScriptMethod ReadBytes {
        param([long]$untilMs)
        $n = $this.Port.BytesToRead
        if ($n -le 0) { return ,([byte[]]@()) }
        $buf = New-Object byte[] $n
        $got = $this.Port.Read($buf, 0, $n)               # byte API: no Encoding involved
        if ($got -lt $n) { $x = New-Object byte[] $got; [Array]::Copy($buf, $x, $got); $buf = $x }
        return ,$buf
    }
    $t | Add-Member ScriptMethod WriteBytes {
        param([byte[]]$b)
        $this.Port.Write($b, 0, $b.Length)                # bounded by WriteTimeout
        if (-not [FsHostNative]::FlushWithTimeout($this.Port.BaseStream, 2000)) { throw 'serial flush did not complete within 2 s' }
    }
    $t | Add-Member ScriptMethod Idle { param([long]$untilMs)
        $d = [Math]::Min([long]$this.PollMs, $untilMs - $this.NowMs()); if ($d -gt 0) { Start-Sleep -Milliseconds $d } }
    $t | Add-Member ScriptMethod Beep { param([int]$f, [int]$ms)      # the HOST's speaker / console only
        try { [Console]::Beep($f, $ms) } catch { [Console]::Out.Write([char]7); Start-Sleep -Milliseconds $ms } }
    $t | Add-Member ScriptMethod Dispose { if (-not [FsHostNative]::CloseWithTimeout($this.Port, 3000)) { throw 'serial close did not complete within 3 s (abandoned)' } }
    $t
}

# A host-console beep (never sent to the device). The transport decides how: live = [Console]::Beep,
# falling back to BEL on the HOST console; replay = recorded, virtual time advances by the duration.
function Invoke-FsBeep { param($Transport, [int]$Freq, [int]$Ms)
    if ($Ms -le 0) { return }
    if ($Transport.PSObject.Methods.Name -contains 'Beep') { $Transport.Beep($Freq, $Ms) }
}

# Parses and validates a capture index (data, not instructions).
function Read-FsCaptureIndex {
    param([Parameter(Mandatory)][string]$Path, [long]$RawLength)
    $lines = [IO.File]::ReadAllLines($Path)
    if ($lines.Count -lt 1 -or $lines[0] -cnotmatch '^FSIDX1 nonce=([0-9a-f]{16}) mode=(live|replay|synthetic) port=(COM[0-9]{1,3}|-)\z') { throw 'index: bad header' }
    $ix = [pscustomobject]@{ Nonce = $Matches[1]; Mode = $Matches[2]; R = (New-Object System.Collections.Generic.List[object]); W = (New-Object System.Collections.Generic.List[object]) }
    $expectOff = [long]0; $lastMs = [long]-1
    for ($k = 1; $k -lt $lines.Count; $k++) {
        $l = $lines[$k]
        if ($l -eq '') { continue }
        if ($l -cmatch '^R (0|[1-9][0-9]{0,8}) ([1-9][0-9]{0,8}) (0|[1-9][0-9]{0,11})\z') {
            $o = [long]$Matches[1]; $n = [long]$Matches[2]; $ms = [long]$Matches[3]
            if ($o -ne $expectOff) { throw "index line $($k + 1): read chunks are not contiguous" }
            if ($ms -lt $lastMs) { throw "index line $($k + 1): time goes backwards" }
            $ix.R.Add([pscustomobject]@{ Offset = $o; Length = $n; Ms = $ms }); $expectOff = $o + $n; $lastMs = $ms
        } elseif ($l -cmatch '^W (0|[1-9][0-9]{0,8}) (0|[1-9][0-9]{0,11}) ([ -~]{1,200})\z') {
            $o = [long]$Matches[1]; $ms = [long]$Matches[2]
            if ($o -ne $expectOff) { throw "index line $($k + 1): write offset is not the bytes read so far" }
            if ($ms -lt $lastMs) { throw "index line $($k + 1): time goes backwards" }
            $ix.W.Add([pscustomobject]@{ Offset = $o; Ms = $ms; Text = $Matches[3] }); $lastMs = $ms
        } elseif ($l -cmatch '^N (0|[1-9][0-9]{0,8}) (0|[1-9][0-9]{0,11}) ([ -~]{1,200})\z') {
            if ([long]$Matches[1] -ne $expectOff) { throw "index line $($k + 1): note offset is not the bytes read so far" }   # a host event: recorded, not replayed
        } else { throw "index line $($k + 1): not an R, W or N line" }
    }
    if ($expectOff -ne $RawLength) { throw "index covers $expectOff bytes; capture has $RawLength" }
    $ix
}

# Replay: delivers the recorded bytes, chunk by chunk, never beyond the next
# recorded host write until the collector itself makes that write. Time is
# virtual (recorded chunk times; idling advances it).
function New-FsReplayTransport {
    param([Parameter(Mandatory)][byte[]]$Raw, [Parameter(Mandatory)]$Index, [int]$PollMs = 50)
    $t = [pscustomobject]@{ Raw = $Raw; Ix = $Index; Ci = 0; Wi = 0; Now = [long]0; PollMs = $PollMs; Kind = 'replay'
                            Beeps = (New-Object System.Collections.Generic.List[string])
                            Divergence = (New-Object System.Collections.Generic.List[string]); Diverged = $false }
    $t | Add-Member ScriptMethod Open { }
    $t | Add-Member ScriptMethod NowMs { $this.Now }
    $t | Add-Member ScriptMethod NextReady {    # the next deliverable chunk, or $null
        if ($this.Diverged -or $this.Ci -ge $this.Ix.R.Count) { return $null }
        $c = $this.Ix.R[$this.Ci]
        if ($this.Wi -lt $this.Ix.W.Count -and $c.Offset -ge $this.Ix.W[$this.Wi].Offset) { return $null }   # gated by a host write not yet made
        return $c
    }
    $t | Add-Member ScriptMethod ReadBytes {
        param([long]$untilMs)
        $c = $this.NextReady()
        if ($null -eq $c -or $c.Ms -gt $untilMs) { return ,([byte[]]@()) }
        if ($c.Ms -gt $this.Now) { $this.Now = $c.Ms }
        $this.Ci++
        $b = New-Object byte[] $c.Length; [Array]::Copy($this.Raw, [int]$c.Offset, $b, 0, [int]$c.Length)
        return ,$b
    }
    $t | Add-Member ScriptMethod WriteBytes {
        param([byte[]]$b)
        $text = $script:Latin1.GetString($b).TrimEnd([char]10)
        if ($this.Diverged) { $this.Divergence.Add("after divergence: $text"); return }
        if ($this.Wi -lt $this.Ix.W.Count) {
            $gate = $this.Ix.W[$this.Wi].Offset; $delivered = if ($this.Ci -lt $this.Ix.R.Count) { $this.Ix.R[$this.Ci].Offset } else { $this.Raw.Length }
            if ($delivered -lt $gate) { $this.Divergence.Add("collector wrote '$text' before reading all bytes recorded ahead of that write ($delivered of $gate)"); $this.Diverged = $true; return }
        }
        if ($this.Wi -lt $this.Ix.W.Count -and $this.Ix.W[$this.Wi].Text -ceq $text) {
            if ($this.Ix.W[$this.Wi].Ms -gt $this.Now) { $this.Now = $this.Ix.W[$this.Wi].Ms }
            $this.Wi++; return
        }
        $want = if ($this.Wi -lt $this.Ix.W.Count) { $this.Ix.W[$this.Wi].Text } else { '(none: the recorded session made no further write)' }
        $this.Divergence.Add("collector wrote '$text'; recorded write was '$want'"); $this.Diverged = $true
    }
    $t | Add-Member ScriptMethod Idle {
        param([long]$untilMs)
        $c = $this.NextReady()
        if ($null -ne $c -and $c.Ms -le $untilMs) { if ($c.Ms -gt $this.Now) { $this.Now = $c.Ms } else { $this.Now += 1 } }
        else { $this.Now = [Math]::Max($this.Now, $untilMs) }
    }
    $t | Add-Member ScriptMethod Beep { param([int]$f, [int]$ms) $this.Beeps.Add("$f/$ms@$($this.Now)"); $this.Now += $ms }   # silent in replay
    $t | Add-Member ScriptMethod Dispose { }
    $t
}

# ------------------------------------------------------- live timing (B1) ----
# FS-R-007 B1. Absolute host deadlines from the conservative origin (BootStartUtc).
function Get-FsHostDeadlines {
    param([Parameter(Mandatory)][DateTime]$OriginUtc, [Parameter(Mandatory)][int]$DeviceDeadlineSec,
          [Parameter(Mandatory)][int]$AckWindowSec, [Parameter(Mandatory)][int]$HostMarginSec)
    $o = $OriginUtc.ToUniversalTime()
    [pscustomobject]@{ OriginUtc = $o; GiveUpUtc = $o.AddSeconds($DeviceDeadlineSec - $HostMarginSec)
                       AckGiveUpUtc = $o.AddSeconds($AckWindowSec - $HostMarginSec); DeviceDeadlineUtc = $o.AddSeconds($DeviceDeadlineSec) }
}
# Converts the absolute deadlines into the transport's monotonic clock. The caller reads the
# transport clock FIRST and the UTC clock SECOND, both AFTER the preparation: the time between the
# two reads can only shorten the budget, and the preparation is never added back.
function ConvertTo-FsTransportDeadlines {
    param([Parameter(Mandatory)]$Deadlines, [Parameter(Mandatory)][long]$NowMs, [Parameter(Mandatory)][DateTime]$NowUtc)
    $rem = [long][Math]::Floor(($Deadlines.GiveUpUtc - $NowUtc).TotalMilliseconds)
    $ack = [long][Math]::Floor(($Deadlines.AckGiveUpUtc - $NowUtc).TotalMilliseconds)
    [pscustomobject]@{ AtUtc = $NowUtc; AtMs = $NowMs; RemainMs = $rem; AckRemainMs = $ack; GiveUpMs = $NowMs + $rem; AckGiveUpMs = $NowMs + $ack }
}
# The start refusals, on remaining times computed from a fresh read. $null = may start.
function Get-FsLiveStartRefusal {
    param([Parameter(Mandatory)][long]$RemainMs, [Parameter(Mandatory)][long]$AckRemainMs, [int]$AckWindowSec)
    if ($RemainMs -lt 60000) { return "only $([Math]::Max(0, [long][Math]::Floor($RemainMs / 1000))) s left before the host give-up (BootStartUtc + DEADLINE - margin); let the device deadline recover" }
    if ($AckRemainMs -lt 30000) { return "only $([Math]::Max(0, [long][Math]::Floor($AckRemainMs / 1000))) s of the ack window left (BootStartUtc + $AckWindowSec s - margin; PID 1 reboots without an ack by SHELL_READY + $AckWindowSec s); let the device recover" }
    return $null
}

# ------------------------------------------------------------- analysis -----
# Lines of a byte region, decoded Latin-1 (1:1, analysis only; the capture
# itself is never decoded). Each: T (trailing CRs removed), Term, End (offset
# in the region just past the line's '\n').
function Get-FsRegionLines {
    param([byte[]]$Bytes)
    $text = $script:Latin1.GetString($Bytes)
    $res = New-Object System.Collections.Generic.List[object]
    $pos = 0
    while ($pos -lt $text.Length) {
        $nl = $text.IndexOf([char]10, $pos)
        if ($nl -lt 0) { $res.Add([pscustomobject]@{ T = $text.Substring($pos).TrimEnd([char]13); Term = $false; End = $text.Length }); break }
        $res.Add([pscustomobject]@{ T = $text.Substring($pos, $nl - $pos).TrimEnd([char]13); Term = $true; End = $nl + 1 })
        $pos = $nl + 1
    }
    ,$res
}
$script:FsEsc = [regex]'\x1b\[[0-9;?]*[ -/]*[@-~]'
function Get-FsVisible { param([string]$S) ($script:FsEsc.Replace($S, '')).Replace([string][char]13, '') }
function Get-FsRawTail { param([byte[]]$Bytes)    # the raw text after the last LF (Latin-1)
    $text = $script:Latin1.GetString($Bytes); $text.Substring($text.LastIndexOf([char]10) + 1) }
# Shell state from the bytes after the last newline of a region.
function Get-FsTailState {
    param([byte[]]$Bytes)
    $tail = Get-FsVisible (Get-FsRawTail $Bytes)
    if ($tail -ceq '> ') { return 'continuation' }                       # ash PS2
    if ($tail.Length -le 64 -and $tail -cmatch '^[ -~]*[#$] \z') { return 'prompt' }   # ash PS1 ('~ # ', '/ # ')
    if ($tail -eq '') { return 'empty' }
    return 'other'
}

# Completion detectors: given the region lines (after the send offset),
# return @{ Index; Line } for the completion line, or $null. Only
# newline-terminated lines that START with the tag count.
# A completion is either a key=value record (ConvertFrom-FsRecord, stage 1)
# or one of the exact literal replies of the stage-1/common helpers
# ("FSA1 queued END" from fs-ack, "FSD1 queued END" from fs-done).
$script:FsLiteralRecords = @('FSA1 queued END', 'FSD1 queued END')
function Find-FsRecordLine {
    param($Lines, [string]$Tag)
    for ($k = 0; $k -lt $Lines.Count; $k++) {
        $l = $Lines[$k]
        if ($l.Term -and $l.T.StartsWith("$Tag ", [StringComparison]::Ordinal) -and
            (($script:FsLiteralRecords -ccontains $l.T) -or $null -ne (ConvertFrom-FsRecord -Line $l.T -Tag $Tag))) {
            return @{ Index = $k; Line = $l.T; End = $l.End }
        }
    }
    return $null
}
function Find-FsFsb1End {
    param($Lines)
    $b = -1
    for ($k = 0; $k -lt $Lines.Count; $k++) {
        $t = $Lines[$k].T
        if ($b -lt 0) { if ($t.StartsWith('FSB1 BEGIN', [StringComparison]::Ordinal)) { $b = $k }; continue }
        if ($Lines[$k].Term -and $t.StartsWith('FSB1 END', [StringComparison]::Ordinal)) { return @{ Index = $k; Line = $t; End = $Lines[$k].End } }
    }
    return $null
}

# Why a phase did not complete (FS-R-005 §5: missing data must be INCONCLUSIVE).
function Get-FsIncompleteState {
    param([byte[]]$Region, [string]$Cmd, [string]$Tag)
    if ($Region.Length -eq 0) { return 'silent' }
    if ((Get-FsTailState $Region) -ceq 'continuation') { return 'continuation' }
    $lines = Get-FsRegionLines $Region
    foreach ($l in $lines) { if ((Get-FsVisible $l.T).StartsWith($Tag, [StringComparison]::Ordinal)) { return 'partial' } }
    $other = @($lines | Where-Object {
        $v = (Get-FsVisible $_.T).Trim()
        $v -ne '' -and $v -cne $Cmd -and -not ($v -cmatch '^[ -~]*[#$]\z')
    })
    if ($other.Count -eq 0) {
        $echo = @($lines | Where-Object { (Get-FsVisible $_.T).Trim() -ceq $Cmd })
        if ($echo.Count -gt 0) { return 'echo-only' }
        return 'prompt-only'
    }
    return 'no-completion'
}
function Get-FsEchoState {
    param([byte[]]$Region, [string]$Cmd, $Completion, [string]$Tag = '')
    $lines = Get-FsRegionLines $Region
    $k = 0
    while ($k -lt $lines.Count -and (Get-FsVisible $lines[$k].T) -eq '') { $k++ }     # leading empty lines are not an echo
    if ($k -ge $lines.Count) { return 'absent' }
    if ($null -ne $Completion -and $Completion.Index -eq $k) { return 'absent' }
    $first = (Get-FsVisible $lines[$k].T)
    if ($Tag -and $first.StartsWith($Tag, [StringComparison]::Ordinal)) { return 'absent' }   # output starts with the record itself
    if ($first -ceq $Cmd) { return 'exact' }
    if ($first.EndsWith($Cmd, [StringComparison]::Ordinal)) { return 'exact-after-redraw' }
    return 'other'
}

# ---------------------------------------------------------------- engine ----
function Read-FsInto {   # one read; appends to the capture; returns bytes read
    param($Ctx, [long]$UntilMs)
    [byte[]]$b = $Ctx.T.ReadBytes($UntilMs)
    if ($b.Length -gt 0) { $Ctx.C.Append($b, $Ctx.T.NowMs()); $Ctx.LastByteMs = $Ctx.T.NowMs() }
    return $b.Length
}

# Rule 3, the send gate. Returns $null when a command may be sent, else why not.
function Get-FsSendGate {
    param($Ctx)
    for ($k = 0; $k -lt 1024; $k++) { if ((Read-FsInto $Ctx $Ctx.T.NowMs()) -eq 0) { break } }   # whatever has already arrived
    if ($Ctx.T.NowMs() -ge $Ctx.Cfg.GiveUpMs) { return 'host deadline reached (the host gives up before the device deadline)' }
    if ($null -ne $Ctx.PhaseCapMs -and $Ctx.T.NowMs() -ge $Ctx.PhaseCapMs) { return 'ack window reached (the host stops before PID 1''s no-host-ack reboot)' }
    if ($Ctx.Sent.Count -eq 0 -and $null -eq $Ctx.SettledLen) {
        if ($Ctx.C.Length -eq 0) { return $null }            # nothing at all has arrived: the first command is the probe
        return 'before the first command the tail is not a settled primary prompt'
    }
    if ($null -eq $Ctx.SettledLen) { return 'no settled prompt since the last command' }
    if ($Ctx.C.Length -ne $Ctx.SettledLen) { return "$($Ctx.C.Length - $Ctx.SettledLen) byte(s) arrived after the settled prompt" }
    $tail = Get-FsRawTail ($Ctx.C.Bytes(0))
    if ($tail -cne $Ctx.ExpectedPrompt) { return "the tail of the capture is not the expected prompt (tail '$(ConvertTo-FsPrintable $tail)')" }
    return $null
}
# Records a settled primary prompt (end of the capture). The first one fixes the expected prompt.
function Set-FsSettled {
    param($Ctx)
    $tail = Get-FsRawTail ($Ctx.C.Bytes(0))
    if ($null -eq $Ctx.ExpectedPrompt) { $Ctx.ExpectedPrompt = $tail }
    elseif ($tail -cne $Ctx.ExpectedPrompt) { $Ctx.SettledLen = $null; return $false }
    $Ctx.SettledLen = $Ctx.C.Length
    return $true
}

# Sends one command (only through the gate) and waits for its completion
# record, then for a settled primary prompt. Never sends anything else.
function Invoke-FsPhase {
    param($Ctx, [string]$Verb, [string]$Arg = '', [int]$TimeoutMs, [scriptblock]$Detect, [string]$Tag, [switch]$NoPrompt)
    $cmd = New-FsCommand -Verb $Verb -Arg $Arg
    $ph = [ordered]@{ Verb = $Verb; Command = $cmd; SendOffset = $null; SendMs = $null; DeadlineMs = $null; HostDeadline = $false
                      State = $null; Gate = $null; Completion = $null; CompletedMs = $null; Prompt = $null; Echo = $null }
    $why = Get-FsSendGate $Ctx
    if ($null -ne $why) { $ph.State = 'not-sent'; $ph.Gate = $why; return [pscustomobject]$ph }
    $Ctx.SettledLen = $null                                    # consumed by this send
    $start = $Ctx.C.Length
    $t0 = $Ctx.T.NowMs()
    try { $Ctx.T.WriteBytes([System.Text.Encoding]::ASCII.GetBytes($cmd + "`n")) }
    catch { throw "write of '$cmd' failed (it may have been partly sent): $($_.Exception.Message)" }
    $Ctx.C.NoteWrite($cmd, $t0)                                # logged only after the write succeeded
    $Ctx.Sent.Add($cmd)
    $cap = $Ctx.Cfg.GiveUpMs
    if ($null -ne $Ctx.PhaseCapMs -and $Ctx.PhaseCapMs -lt $cap) { $cap = $Ctx.PhaseCapMs }
    $deadline = [Math]::Min($t0 + $TimeoutMs, $cap)
    $ph.SendOffset = $start; $ph.SendMs = $t0; $ph.DeadlineMs = $deadline; $ph.HostDeadline = ($deadline -eq $cap)
    $done = $null; $lastData = $t0
    while ($Ctx.T.NowMs() -lt $deadline) {
        if ((Read-FsInto $Ctx $deadline) -gt 0) {
            $lastData = $Ctx.T.NowMs()
            $done = & $Detect (Get-FsRegionLines ($Ctx.C.Bytes($start)))
            if ($null -ne $done) { break }
            continue
        }
        # a continuation prompt after the echo, then quiet: stop waiting early (nothing is sent either way)
        if ($Ctx.C.Length -gt $start -and (Get-FsTailState ($Ctx.C.Bytes($start))) -ceq 'continuation' -and
            $Ctx.T.NowMs() -ge $lastData + $Ctx.Cfg.PromptWaitMs) { break }
        $until = [Math]::Min($deadline, $lastData + $Ctx.Cfg.PromptWaitMs)
        if ($until -le $Ctx.T.NowMs()) { $until = $deadline }
        $Ctx.T.Idle($until)
    }
    $region = $Ctx.C.Bytes($start)
    if ($null -eq $done) {
        $ph.State = Get-FsIncompleteState -Region $region -Cmd $cmd -Tag $Tag
        $ph.Echo = Get-FsEchoState -Region $region -Cmd $cmd -Completion $null -Tag $Tag
        return [pscustomobject]$ph
    }
    $ph.State = 'complete'; $ph.Completion = $done.Line; $ph.CompletedMs = $Ctx.T.NowMs()
    $ph.Echo = Get-FsEchoState -Region $region -Cmd $cmd -Completion $done -Tag $Tag
    if ($NoPrompt) { $ph.Prompt = 'not-awaited'; return [pscustomobject]$ph }
    # The prompt must be the tail AND the line must have gone quiet for PromptSettleMs (ash writes
    # "~ # " and then ESC[6n; a prompt seen mid-write is not yet a settled state).
    $afterOff = $start + $done.End
    $pdl = [Math]::Min($ph.CompletedMs + $Ctx.Cfg.PromptWaitMs, $cap)
    $quiet = $Ctx.T.NowMs()
    while ($true) {
        $st = Get-FsTailState ($Ctx.C.Bytes($afterOff))
        $isP = ($st -ceq 'prompt' -or $st -ceq 'continuation')
        if ($isP -and $Ctx.T.NowMs() -ge $quiet + $Ctx.Cfg.PromptSettleMs) { break }
        if ($Ctx.T.NowMs() -ge $pdl) { break }
        $until = $pdl
        if ($isP) { $until = [Math]::Min($pdl, $quiet + $Ctx.Cfg.PromptSettleMs) }
        if ((Read-FsInto $Ctx $until) -gt 0) { $quiet = $Ctx.T.NowMs() } else { $Ctx.T.Idle($until) }
    }
    $ph.Prompt = switch ($st) { 'prompt' { 'prompt' } 'continuation' { 'continuation' } default { 'missing' } }
    if ($ph.Prompt -ceq 'prompt' -and -not (Set-FsSettled $Ctx)) { $ph.Prompt = 'unexpected-prompt' }
    return [pscustomobject]$ph
}

function Get-FsPhaseStop { param($p)    # the stop reason for an incomplete or refused phase
    if ($p.State -ceq 'not-sent') { return "$($p.Verb) NOT SENT: $($p.Gate)" }
    $r = "$($p.Verb): $($p.State)"
    if ($p.HostDeadline) { $r += ' (host gave up at its deadline: the device deadline, or before the runner the ack window)' }
    return $r
}

function Invoke-FsCollect {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)]$Capture, [Parameter(Mandatory)][hashtable]$Tokens,
          [Parameter(Mandatory)][hashtable]$Cfg)
    $ctx = [pscustomobject]@{ T = $Transport; C = $Capture; Cfg = $Cfg; Sent = (New-Object System.Collections.Generic.List[string])
                              SettledLen = $null; ExpectedPrompt = $null; LastByteMs = [long]-1; PhaseCapMs = $Cfg.AckGiveUpMs }
    $script:FsLastCtx = $ctx
    $res = [ordered]@{
        Schema = 'frameshift.fs-collect.v3'; Stage = $Cfg.Stage; RunVerb = $Cfg.RunVerb; DeviceDeadlineSec = $Cfg.DeviceDeadlineSec
        Nonce = $Cfg.Nonce; Exp = $Cfg.Exp; Steps = $Cfg.Steps
        Status = 'INCONCLUSIVE'; StopReason = $null; Phases = @(); GiveUpMs = $Cfg.GiveUpMs
        Verified = $false; VerifyReason = $null; VerifyRecord = $null; Kernel = $null
        AckToken = $Tokens.A; Acked = $false; AckReason = $null
        Challenge = $Tokens.C; ValveSent = $false; RecordComplete = $false; RecordDeadlineMs = $null; RecordCompletedMs = $null
        AckGiveUpMs = $Cfg.AckGiveUpMs; Timing = $Cfg.Timing; ForeignAck = $null; RunnerRefusal = $null
        DoneSent = $false; DoneReply = $null; Sent = $null; TransportError = $null; CaptureError = $null; Known = $false
    }
    $phases = New-Object System.Collections.Generic.List[object]
    # Known = the last phase ended with its completion record AND a settled, expected prompt.
    $st = @{ Known = $false }
    try {
        $null = & {   # each 'return' below ends the exchange; nothing further is sent except the gated fs-done
            $Transport.Open()
            # 0. read what is pending, until it is quiet; never write before the first command
            $pre = $Transport.NowMs() + $Cfg.InitialDrainMs
            $hard = [Math]::Min([Math]::Min($pre + $Cfg.PromptWaitMs, $Cfg.GiveUpMs), $Cfg.AckGiveUpMs)
            while ($Transport.NowMs() -lt $hard) {
                if ($Transport.NowMs() -ge $pre -and ($ctx.LastByteMs -lt 0 -or $Transport.NowMs() -ge $ctx.LastByteMs + $Cfg.PromptSettleMs)) { break }
                $u = if ($Transport.NowMs() -lt $pre) { $pre } else { [Math]::Min($hard, $ctx.LastByteMs + $Cfg.PromptSettleMs) }
                if ((Read-FsInto $ctx $u) -eq 0) { $Transport.Idle($u) }
            }
            if ($Capture.Length -gt 0) {
                $s0 = Get-FsTailState ($Capture.Bytes(0))
                if ($s0 -ceq 'continuation') { $res.StopReason = 'pre-continuation: the shell shows a continuation prompt before anything was sent'; return }
                if ($s0 -cne 'prompt') { $res.StopReason = "pre-unknown-state: before anything was sent the tail is '$(ConvertTo-FsPrintable (Get-FsRawTail ($Capture.Bytes(0))))', not a primary prompt"; return }
                $null = Set-FsSettled $ctx
            }
            # 1. fs-verify: fresh challenge; completion = the first complete FSV1 record
            $p = Invoke-FsPhase $ctx 'fs-verify' $Tokens.V $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSV1' } -Tag 'FSV1'
            $phases.Add($p)
            if ($p.State -cne 'complete') { $res.StopReason = Get-FsPhaseStop $p; return }
            $v = Test-FsVerify -Text $p.Completion -Nonce $Cfg.Nonce -Challenge $Tokens.V -Kernel $Cfg.Kernel -Pid1 $Cfg.Pid1
            $res.VerifyReason = $v.Reason
            if (-not $v.Ok) { $res.StopReason = "fs-verify: record does not verify ($($v.Reason))"; return }
            $res.Verified = $true; $res.VerifyRecord = $p.Completion; $res.Kernel = $v.Record['kernel']
            if ($p.Prompt -cne 'prompt') { $res.StopReason = "fs-verify: completed, then prompt $($p.Prompt)"; return }
            $st.Known = $true
            # 2. fs-ack: completion = FSA1
            $st.Known = $false
            $p = Invoke-FsPhase $ctx 'fs-ack' $Tokens.A $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSA1' } -Tag 'FSA1'
            $phases.Add($p)
            if ($p.State -cne 'complete') { $res.StopReason = Get-FsPhaseStop $p; return }
            if ($p.Prompt -cne 'prompt') { $res.StopReason = "fs-ack: completed, then prompt $($p.Prompt)"; return }
            $st.Known = $true
            if ($p.Completion -cne 'FSA1 queued END') { $res.StopReason = "fs-ack: refused ($(ConvertTo-FsPrintable $p.Completion))"; return }
            # 3. fs-status until PID 1 has recorded the token (bounded; each one only through the send gate)
            for ($try = 1; $try -le $Cfg.AckStatusTries; $try++) {
                $settle = [Math]::Min([Math]::Min($Transport.NowMs() + $Cfg.AckSettleMs, $Cfg.GiveUpMs), $Cfg.AckGiveUpMs)
                while ($Transport.NowMs() -lt $settle) { if ((Read-FsInto $ctx $settle) -eq 0) { $Transport.Idle($settle) } }
                $st.Known = $false
                $p = Invoke-FsPhase $ctx 'fs-status' '' $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSS1' } -Tag 'FSS1'
                $phases.Add($p)
                if ($p.State -cne 'complete') { $res.StopReason = Get-FsPhaseStop $p; return }
                if ($p.Prompt -cne 'prompt') { $res.StopReason = "fs-status: completed, then prompt $($p.Prompt)"; return }
                $st.Known = $true
                $a = Test-FsAck -Text $p.Completion -Nonce $Cfg.Nonce -AckToken $Tokens.A
                $res.AckReason = $a.Reason
                if ($a.Ok) { $res.Acked = $true; break }
                # A foreign ack: PID 1 records only the FIRST valid ack, so another host session
                # (e.g. a stage-1 observer) is attached. Retrying cannot help; stop now (Known stays
                # true: the gated fs-done below recovers at once).
                $fr = @((Get-FsRecords -Text $p.Completion -Tag 'FSS1') | Where-Object { $_['nonce'] -ceq $Cfg.Nonce })   # (Get-FsRecords returns ONE array: unroll it)
                if ($fr.Count -and $fr[0]['acked'] -cmatch '^[0-9a-f]{1,64}\z' -and $fr[0]['acked'] -cne $Tokens.A) {
                    $res.ForeignAck = $fr[0]['acked']
                    $res.StopReason = "foreign ack: PID 1 recorded acked=$($fr[0]['acked']), not this collector's token (another host session is attached); no experiment request is sent"
                    return
                }
            }
            if (-not $res.Acked) { $res.StopReason = "ack not recorded by PID 1 after $($Cfg.AckStatusTries) fs-status ($($res.AckReason))"; return }
            $ctx.PhaseCapMs = $null                     # the ack window no longer applies once PID 1 recorded our ack
            # 3b. stage 3a: the display cue for the PM (read-only pause; the gate applies after it)
            if ($Cfg.DisplayCueMs -gt 0) {
                if ($Cfg.Stage -ceq '3b') { Write-Host $script:FsCue3b }
                else { Write-Host '=== LOOK INTO THE LENSES NOW: the test pattern appears in 3 seconds and lasts up to 10 seconds ===' }
                $Capture.NoteEvent('display-cue', $Transport.NowMs())
                $u = [Math]::Min($Transport.NowMs() + $Cfg.DisplayCueMs, $Cfg.GiveUpMs)
                while ($Transport.NowMs() -lt $u) { if ((Read-FsInto $ctx $u) -eq 0) { $Transport.Idle($u) } }
            }
            # 3c. the runner's worst case must fit before the host give-up (revision 5, NIT3), checked on the
            #     monotonic transport clock immediately before the runner. Live, GiveUpMs is BootStartUtc +
            #     DEADLINE - margin converted after the preparation (revision 9, FS-R-007 B1).
            $need = [long](($Cfg.RunnerWorstSec + $Cfg.RunnerMarginSec) * 1000) + $Cfg.PreDoneMs + $Cfg.Beep1Ms + $Cfg.Beep2Ms   # + the 3a post-record pause (revision 8)
            $left = $Cfg.GiveUpMs - $Transport.NowMs()
            if ($left -lt $need) {
                $res.StopReason = "runner budget: $([long][Math]::Floor($left / 1000)) s left before the host give-up, the runner needs $([long][Math]::Ceiling($need / 1000)) s (worst case $($Cfg.RunnerWorstSec) s + margin $($Cfg.RunnerMarginSec) s + post-record $([long][Math]::Ceiling(($Cfg.PreDoneMs + $Cfg.Beep1Ms + $Cfg.Beep2Ms) / 1000)) s); the runner is not sent; recover now"
                $st.Known = $true                       # the last phase (fs-status) ended settled: fs-done may follow through the gate
                return
            }
            # 4. the runner (fs-valve for stage 2a, fs-display for stage 3a): sent ONCE; completion =
            #    FSB1 BEGIN ... FSB1 END. The prompt wait keeps reading until the shell is back, so a
            #    duplicate or stray record is captured too.
            $st.Known = $false
            $refTag = $Cfg.RefusalTag
            $p = Invoke-FsPhase $ctx $Cfg.RunVerb $Tokens.C $Cfg.RecordTimeoutMs {
                param($L)
                $e = Find-FsFsb1End $L
                $f = Find-FsRecordLine $L $Ctx.Cfg.RefusalTag      # a runner refusal (FSVE1/FSDE1 ... END) is terminal too (dynamic scope: Invoke-FsPhase's $Ctx)
                if ($null -eq $e) { return $f }
                if ($null -eq $f) { return $e }
                if ($f.Index -lt $e.Index) { return $f } else { return $e }
            } -Tag 'FSB1'
            $phases.Add($p)
            if ($p.State -ceq 'not-sent') { $res.StopReason = Get-FsPhaseStop $p; return }
            $res.ValveSent = $true
            $res.RecordDeadlineMs = $p.DeadlineMs
            if ($p.State -ceq 'complete' -and $p.Completion.StartsWith("$refTag ", [StringComparison]::Ordinal)) {
                $res.RunnerRefusal = ConvertTo-FsPrintable $p.Completion
                $res.StopReason = "$($Cfg.RunVerb): the runner refused ($($res.RunnerRefusal)): no record; recover now"
                if ($p.Prompt -ceq 'prompt') { $st.Known = $true }
                return
            }
            if ($p.State -cne 'complete') { $res.StopReason = (Get-FsPhaseStop $p) + ' (no complete record by the collection deadline)'; return }
            $res.RecordComplete = $true; $res.RecordCompletedMs = $p.CompletedMs; $res.Status = 'COLLECTED'
            if ($p.Prompt -cne 'prompt') { $res.StopReason = "$($Cfg.RunVerb): record complete, then prompt $($p.Prompt): fs-done not sent"; return }
            $st.Known = $true
        }
    } catch {
        $res.TransportError = ConvertTo-FsPrintable $_.Exception.Message
        if (-not $res.StopReason) { $res.StopReason = "transport or collector error: $($res.TransportError)" }
        $st.Known = $false
    }
    try {
        # 5. early recovery only from a known state, after a verified challenge, and through the send gate
        if ($st.Known -and $res.Verified -and -not $Cfg.NoDone) {
            if ($res.RecordComplete -and $Cfg.PreDoneMs -gt 0) {
                # Stage 3a, single-operator protocol (revision 8): the PM keeps the headset on from the
                # display cue. Beep 1 (high, short) = fs-pattern's hold has ended; keep looking and confirm
                # the panels are DARK. A read-only pause of PreDoneMs. Beep 2 (low, long) = fs-done now.
                # Both are host-console sounds only (nothing is written to the device); each is an
                # N line in capture.raw.idx. Bytes arriving during the pause make the send gate refuse
                # fs-done (no re-settle): the device deadline recovers.
                $Capture.NoteEvent('beep-1 pattern-hold-ended keep-looking', $Transport.NowMs())
                Invoke-FsBeep $Transport 1760 $Cfg.Beep1Ms
                if ($Cfg.Stage -ceq '3b') { Write-Host ($script:FsBeep1Text3b -f [long]($Cfg.PreDoneMs / 1000)) }
                else { Write-Host "BEEP 1: KEEP LOOKING INTO THE LENSES. The panels should now be DARK. fs-done follows the second (low) beep in $([long]($Cfg.PreDoneMs / 1000)) s." }
                $u = [Math]::Min($Transport.NowMs() + $Cfg.PreDoneMs, $Cfg.GiveUpMs)
                while ($Transport.NowMs() -lt $u) { if ((Read-FsInto $ctx $u) -eq 0) { $Transport.Idle($u) } }
                $Capture.NoteEvent('beep-2 fs-done-next', $Transport.NowMs())
                Invoke-FsBeep $Transport 440 $Cfg.Beep2Ms
                if ($Cfg.Stage -ceq '3b') { Write-Host $script:FsBeep2Text3b; foreach ($rl in $script:FsReport3b) { Write-Host $rl } }
                else { Write-Host 'BEEP 2: end of the pause; fs-done follows now if the shell state is unchanged (send gate). Note whether the panels were dark during the pause.' }
            }
            $ctx.PhaseCapMs = $null       # recovery only shortens the hold: never blocked by the ack window (NIT7)
            try {
                $p = Invoke-FsPhase $ctx 'fs-done' '' $Cfg.StepTimeoutMs { param($L) Find-FsRecordLine $L 'FSD1' } -Tag 'FSD1' -NoPrompt
                $phases.Add($p)
                if ($p.State -ceq 'not-sent') { $res.DoneReply = Get-FsPhaseStop $p }
                else { $res.DoneSent = $true; $res.DoneReply = if ($p.State -ceq 'complete') { ConvertTo-FsPrintable $p.Completion } else { $p.State } }
            } catch { $res.DoneReply = 'error: ' + (ConvertTo-FsPrintable $_.Exception.Message) }
        }
    } finally {
        $res.Phases = $phases.ToArray()
        $res.Sent = $ctx.Sent.ToArray()
        $res.Known = $st.Known
        try { $Transport.Dispose() } catch { if (-not $res.TransportError) { $res.TransportError = ConvertTo-FsPrintable $_.Exception.Message } }
        try { $Capture.Close() } catch { $res.CaptureError = $_.Exception.Message }
    }
    [pscustomobject]$res
}
# Full run: capture, then FSB1 validation of the raw file read back from disk.
function Invoke-FsCollectRun {
    param([Parameter(Mandatory)]$Transport, [Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][hashtable]$Tokens,
          [Parameter(Mandatory)][hashtable]$Cfg, [string]$Mode, [string]$PortName = '-', [long]$TestCaptureFailAfterBytes = -1,
          [bool]$TestCaptureFailOnClose = $false)
    $cap = New-FsCapture -Dir $OutDir -Nonce $Cfg.Nonce -Mode $Mode -PortName $PortName -FailAfterBytes $TestCaptureFailAfterBytes -FailOnClose $TestCaptureFailOnClose
    $r = Invoke-FsCollect -Transport $Transport -Capture $cap -Tokens $Tokens -Cfg $Cfg
    if ($null -eq $r) { throw 'collector returned nothing' }
    [byte[]]$raw = [IO.File]::ReadAllBytes($cap.RawPath)
    $disk = Get-FsSha256Hex $raw
    $o = [ordered]@{}
    foreach ($pp in $r.PSObject.Properties) { $o[$pp.Name] = $pp.Value }
    $o.Capture = [ordered]@{ Path = $cap.RawPath; Index = $cap.IdxPath; Bytes = $raw.Length; Sha256 = $cap.Sha256; Sha256FromDisk = $disk
                             Consistent = ($disk -ceq $cap.Sha256 -and $raw.Length -eq $cap.Length -and -not $r.CaptureError) }
    $o.Fsb1 = $null
    if ($r.ValveSent) {
        $d = Test-Fsb1Record -Bytes $raw -Exp $Cfg.Exp -Nonce $Cfg.Nonce -Challenge $Tokens.C -Steps $Cfg.Steps
        $o.Fsb1 = [ordered]@{ Ok = $d.Ok; Reason = $d.Reason; Detail = $d.Detail; StepCount = $(if ($d.Ok) { $d.Steps.Count } else { 0 }) }
        $o.Fsb1Decoded = $d
    } else { $o.Fsb1Decoded = $null }
    if (-not $o.Capture.Consistent) {
        $o.Status = 'INCONCLUSIVE'
        $why = if ($r.CaptureError) { $r.CaptureError } else { 'capture file does not match the bytes read' }
        $o.StopReason = $(if ($o.StopReason) { "$($o.StopReason); $why" } else { $why })
    }
    elseif ($r.Status -ceq 'COLLECTED') { $o.Status = $(if ($o.Fsb1.Ok) { 'COLLECTED-VALID' } else { 'COLLECTED-REJECTED' }) }
    if ($Transport.Kind -ceq 'replay') {
        $o.Replay = [ordered]@{ Beeps = $Transport.Beeps.ToArray(); Divergence = $Transport.Divergence.ToArray(); UnperformedWrites = @($Transport.Ix.W | Select-Object -Skip $Transport.Wi | ForEach-Object Text)
                                ConsumedBytes = $raw.Length; SourceBytes = $Transport.Raw.Length }
    }
    [pscustomobject]$o
}

function Save-FsCollectJson {
    param($Result, [string]$Path)
    $copy = [ordered]@{}
    foreach ($pp in $Result.PSObject.Properties) { if ($pp.Name -cne 'Fsb1Decoded') { $copy[$pp.Name] = $pp.Value } }
    $json = [pscustomobject]$copy | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FsReplayTokens {   # tokens come from the recorded writes, validated by the command table
    param($Index)
    $tk = @{ V = $null; A = $null; C = $null }
    foreach ($w in $Index.W) {
        if ($w.Text -cmatch '^fs-verify ([0-9a-f]{32})\z' -and -not $tk.V) { $tk.V = $Matches[1] }
        elseif ($w.Text -cmatch '^fs-ack ([0-9a-f]{16})\z' -and -not $tk.A) { $tk.A = $Matches[1] }
        elseif ($w.Text -cmatch '^fs-(valve|display) ([0-9a-f]{32})\z' -and -not $tk.C) { $tk.C = $Matches[2] }
    }
    if (-not $tk.V) { $tk.V = New-FsHex 16 }; if (-not $tk.A) { $tk.A = New-FsHex 8 }; if (-not $tk.C) { $tk.C = New-FsHex 16 }
    $tk
}

function New-FsCollectCfg {   # defaults equal the CLI parameter defaults; Exp/Steps/deadline default to the stage's
    param([string]$Nonce, [ValidateSet('2a', '3a', '3b')][string]$Stage = '2a', [string]$Exp = '', [string[]]$Steps = @(), [int]$DeviceDeadlineSec = 0,
          [int]$AckWindowSec = 0, [long]$AckGiveUpMs = -1, [int]$PreDoneMs = -1, [int]$DisplayCueMs = -1,
          [string]$Kernel = '5.10.198-01402-g1c5986fe21ee', [string]$Pid1 = '/bin/busybox,sh,/init', [int]$StepTimeoutMs = 10000,
          [int]$RecordTimeoutMs = 240000, [int]$PromptWaitMs = 3000, [int]$AckSettleMs = 2500, [int]$AckStatusTries = -1,
          [int]$InitialDrainMs = 1000, [bool]$NoDone = $false, [int]$PromptSettleMs = 150,
          [long]$GiveUpMs = -1,    # transport-clock time at which the host gives up (replay: from collector start); -1 = (deadline - 15 s)
          $Timing = $null)         # live: the B1 timing evidence (origin, handoff evidence, absolute give-ups, conversion point)
    $sp = $script:FsStageSpec[$Stage]
    if (-not $Exp) { $Exp = $sp.Exp }
    if (@($Steps).Count -eq 0) { $Steps = $sp.Steps }
    if ($DeviceDeadlineSec -le 0) { $DeviceDeadlineSec = $sp.DeviceDeadlineSec }
    if ($GiveUpMs -lt 0) { $GiveUpMs = [long](($DeviceDeadlineSec - 15) * 1000) }
    if ($AckWindowSec -le 0) { $AckWindowSec = $sp.AckWindowSec }
    if ($AckGiveUpMs -lt 0) { $AckGiveUpMs = [long](($AckWindowSec - 15) * 1000) }
    if ($PreDoneMs -lt 0) { $PreDoneMs = $sp.PreDoneMs }
    if ($DisplayCueMs -lt 0) { $DisplayCueMs = $sp.DisplayCueMs }
    if ($AckStatusTries -lt 1) { $AckStatusTries = $sp.AckStatusTries }
    @{ Nonce = $Nonce; Stage = $Stage; RunVerb = $sp.Verb; RefusalTag = $sp.Refusal; DeviceDeadlineSec = $DeviceDeadlineSec
       AckWindowSec = $AckWindowSec; AckGiveUpMs = $AckGiveUpMs; PreDoneMs = $PreDoneMs; DisplayCueMs = $DisplayCueMs
       RunnerWorstSec = $sp.RunnerWorstSec; RunnerMarginSec = $sp.RunnerMarginSec; Beep1Ms = $sp.Beep1Ms; Beep2Ms = $sp.Beep2Ms
       Exp = $Exp; Steps = $Steps; Kernel = $Kernel; Pid1 = $Pid1; StepTimeoutMs = $StepTimeoutMs
       RecordTimeoutMs = $RecordTimeoutMs; PromptWaitMs = $PromptWaitMs; AckSettleMs = $AckSettleMs
       AckStatusTries = [Math]::Max(1, $AckStatusTries); InitialDrainMs = $InitialDrainMs; NoDone = $NoDone; PromptSettleMs = $PromptSettleMs
       GiveUpMs = $GiveUpMs; Timing = $Timing }
}

# Replay entry point used by the CLI and by test-host2.ps1.
function Invoke-FsReplay {
    param([Parameter(Mandatory)][string]$RawPath, [string]$IndexPath, [Parameter(Mandatory)][string]$OutDir, [string]$Nonce = '',
          [hashtable]$Overrides = @{}, [int]$PollMs = 50, [long]$TestCaptureFailAfterBytes = -1, [bool]$TestCaptureFailOnClose = $false)
    if (-not $IndexPath) { $IndexPath = "$RawPath.idx" }
    [byte[]]$raw = [IO.File]::ReadAllBytes($RawPath)
    $ix = Read-FsCaptureIndex -Path $IndexPath -RawLength $raw.Length
    if ($Nonce -and $Nonce -cne $ix.Nonce) { throw "refused: -Nonce $Nonce differs from the index nonce $($ix.Nonce)" }
    $stg = if ($Overrides.ContainsKey('Stage')) { [string]$Overrides['Stage'] } else { '2a' }
    $cfg = New-FsCollectCfg -Nonce $ix.Nonce -Stage $stg
    foreach ($k in $Overrides.Keys) {
        if ($k -ceq 'Stage' -or $k -ceq 'RunVerb' -or $k -ceq 'RefusalTag') { continue }          # fixed by the stage
        if (-not $cfg.ContainsKey($k)) { throw "unknown setting $k" }; $cfg[$k] = $Overrides[$k]
    }
    $t = New-FsReplayTransport -Raw $raw -Index $ix -PollMs $PollMs
    $r = Invoke-FsCollectRun -Transport $t -OutDir $OutDir -Tokens (Get-FsReplayTokens $ix) -Cfg $cfg -Mode 'replay' `
        -TestCaptureFailAfterBytes $TestCaptureFailAfterBytes -TestCaptureFailOnClose $TestCaptureFailOnClose
    $r | Add-Member NoteProperty ReplaySource ([ordered]@{ Raw = $RawPath; Sha256 = (Get-FsSha256Hex $raw); Index = $IndexPath })
    # the re-capture must equal the source bytes it consumed, byte for byte
    [byte[]]$re = [IO.File]::ReadAllBytes($r.Capture.Path)
    $prefixOk = $re.Length -le $raw.Length
    if ($prefixOk -and $re.Length -gt 0) { $src = New-Object byte[] $re.Length; [Array]::Copy($raw, $src, $re.Length); $prefixOk = ([FsHostNative]::DiffIndices($src, $re).Length -eq 0) }
    $r.Replay.RecaptureIsSourcePrefix = $prefixOk
    $r
}

# Operator summary. Every line goes through ConvertTo-FsPrintable.
function Write-FsSummary { param($r)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("STATUS: $($r.Status)")
    if ($r.StopReason) { $out.Add("STOP:   $($r.StopReason)") }
    $out.Add("SENT:   $(@($r.Sent) -join ' | ')")
    $out.Add("CAPTURE: $($r.Capture.Path) bytes=$($r.Capture.Bytes) sha256=$($r.Capture.Sha256) consistent=$($r.Capture.Consistent)")
    if ($r.CaptureError) { $out.Add("CAPTURE ERROR: $($r.CaptureError)") }
    if ($r.Fsb1) { $out.Add("FSB1:   $(if ($r.Fsb1.Ok) { 'VALID' } else { "REJECT $($r.Fsb1.Reason) $($r.Fsb1.Detail)" })") }
    if (-not $r.DoneSent) { $out.Add("RECOVERY: fs-done NOT sent (state unknown, unverified or gated): the PID 1 deadline reboots at T0+$($r.DeviceDeadlineSec) s (backstop +1 s)") }
    else { $out.Add("RECOVERY: fs-done sent; reply: $($r.DoneReply)") }
    foreach ($l in $out) { Write-Output (ConvertTo-FsPrintable $l) }
}

# ------------------------------------------------------------------ CLI -----
if ($MyInvocation.InvocationName -eq '.') { return }
$exit = 70; $r = $null; $started = $false
try {
    if (-not $OutDir) { throw 'refused: -OutDir is required (a new directory)' }
    if ($Replay) {
        if ($Port) { throw 'refused: -Port and -Replay are exclusive' }
        $dd = if ($DeviceDeadlineSec -gt 0) { $DeviceDeadlineSec } else { $script:FsStageSpec[$Stage].DeviceDeadlineSec }
        $ov = @{ Stage = $Stage; DeviceDeadlineSec = $dd; Kernel = $Kernel; Pid1 = $Pid1; StepTimeoutMs = $StepTimeoutMs; RecordTimeoutMs = $RecordTimeoutMs
                 PromptWaitMs = $PromptWaitMs; AckSettleMs = $AckSettleMs
                 InitialDrainMs = $InitialDrainMs; NoDone = [bool]$NoDone; PromptSettleMs = $PromptSettleMs
                 GiveUpMs = [long](($dd - $HostMarginSec) * 1000) }
        $aw = if ($AckWindowSec -gt 0) { $AckWindowSec } else { $script:FsStageSpec[$Stage].AckWindowSec }
        $ov.AckWindowSec = $aw; $ov.AckGiveUpMs = [long](($aw - $HostMarginSec) * 1000)
        if ($PreDoneMs -ge 0) { $ov.PreDoneMs = $PreDoneMs }
        if ($Exp) { $ov.Exp = $Exp }
        if (@($Steps).Count) { $ov.Steps = $Steps }
        $started = $true
        $r = Invoke-FsReplay -RawPath $Replay -IndexPath $ReplayIndex -OutDir $OutDir -Nonce $Nonce -Overrides $ov -PollMs $PollMs `
            -TestCaptureFailAfterBytes $TestCaptureFailAfterBytes -TestCaptureFailOnClose ([bool]$TestCaptureFailOnClose)
        if (@($r.Replay.Divergence).Count) { Write-Output (ConvertTo-FsPrintable "REPLAY DIVERGENCE: $(@($r.Replay.Divergence) -join '; ')") }
    } else {
        if ($Port -cnotmatch '^COM[0-9]{1,3}\z') { throw 'refused: -Port must be given explicitly as COMn (never chosen automatically)' }
        if ($Nonce -cnotmatch '^[0-9a-f]{16}\z') { throw 'refused: -Nonce must be the image nonce (16 lowercase hex)' }
        # FS-R-007 B1: the budget origin is BootStartUtc (before `fastboot boot` was invoked), for every handoff class.
        if (-not $BootStartUtc) { throw 'refused: -BootStartUtc (observe.json BootStartUtc, taken just before fastboot boot was invoked) is required: it is the budget origin; -HandoffUtc is evidence only (FS-R-007 B1)' }
        $parseU = { param([string]$v) [DateTime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        $origin = & $parseU $BootStartUtc
        $hoEv = $null
        if ($HandoffUtc) { $hoEv = & $parseU $HandoffUtc; if ($hoEv -lt $origin) { throw 'refused: -HandoffUtc precedes -BootStartUtc (inconsistent observer times)' } }
        $cliUtc = [DateTime]::UtcNow
        # N1: no tolerance. A future origin means a clock step or bad input, and would inflate the budget.
        if ($origin -gt $cliUtc) { throw "refused: -BootStartUtc $($origin.ToString('o')) is later than now $($cliUtc.ToString('o')) (clock step or bad input; a future origin would inflate the budget)" }
        if ($DeviceDeadlineSec -le 0) { $DeviceDeadlineSec = $script:FsStageSpec[$Stage].DeviceDeadlineSec }
        if ($AckWindowSec -le 0) { $AckWindowSec = $script:FsStageSpec[$Stage].AckWindowSec }
        $dl = Get-FsHostDeadlines -OriginUtc $origin -DeviceDeadlineSec $DeviceDeadlineSec -AckWindowSec $AckWindowSec -HostMarginSec $HostMarginSec
        # fail fast before preparing anything (the binding check is the one after the preparation)
        $pre = ConvertTo-FsTransportDeadlines -Deadlines $dl -NowMs 0 -NowUtc ([DateTime]::UtcNow)
        $why = Get-FsLiveStartRefusal -RemainMs $pre.RemainMs -AckRemainMs $pre.AckRemainMs -AckWindowSec $AckWindowSec
        if ($why) { throw "refused: $why" }
        # preparation: the gadget lookup and the transport (the port is opened later, inside the collection)
        $g = Get-FsGadget -Nonce $Nonce
        if (-not $g.SerialOk) { throw "refused: no USB gadget with serial FS-$Nonce is present" }
        if ($g.ComPort -cne $Port) { throw "refused: $Port is not the port registered under FS-$Nonce (that is '$($g.ComPort)')" }
        $tokens = @{ V = (New-FsHex 16); A = (New-FsHex 8); C = (New-FsHex 16) }
        $t = New-FsRawSerialTransport -PortName $Port -PollMs $PollMs
        # after the preparation: a FRESH read, transport clock first, then UTC; nothing computed earlier is carried over
        $nowMs = [long]$t.NowMs(); $nowU = [DateTime]::UtcNow
        $cv = ConvertTo-FsTransportDeadlines -Deadlines $dl -NowMs $nowMs -NowUtc $nowU
        $why = Get-FsLiveStartRefusal -RemainMs $cv.RemainMs -AckRemainMs $cv.AckRemainMs -AckWindowSec $AckWindowSec
        if ($why) { throw "refused (after $([long]($nowU - $cliUtc).TotalSeconds) s of preparation): $why" }
        $timing = [ordered]@{ BudgetOrigin = 'BootStartUtc'; BootStartUtc = $origin.ToString('o'); HandoffUtcEvidence = $(if ($hoEv) { $hoEv.ToString('o') } else { $null })
                              GiveUpUtc = $dl.GiveUpUtc.ToString('o'); AckGiveUpUtc = $dl.AckGiveUpUtc.ToString('o'); DeviceDeadlineNoEarlierThanUtc = $dl.DeviceDeadlineUtc.ToString('o')
                              CollectorStartUtc = $cliUtc.ToString('o'); ConvertedAtUtc = $nowU.ToString('o'); ConvertedAtMs = $nowMs
                              PreparationMs = [long]($nowU - $cliUtc).TotalMilliseconds; RemainMsAtConversion = $cv.RemainMs; AckRemainMsAtConversion = $cv.AckRemainMs }
        $cfg = New-FsCollectCfg -Nonce $Nonce -Stage $Stage -Exp $Exp -Steps $Steps -DeviceDeadlineSec $DeviceDeadlineSec -Kernel $Kernel -Pid1 $Pid1 -StepTimeoutMs $StepTimeoutMs `
            -RecordTimeoutMs $RecordTimeoutMs -PromptWaitMs $PromptWaitMs -AckSettleMs $AckSettleMs -AckStatusTries $AckStatusTries `
            -InitialDrainMs $InitialDrainMs -NoDone ([bool]$NoDone) -PromptSettleMs $PromptSettleMs -GiveUpMs $cv.GiveUpMs `
            -AckWindowSec $AckWindowSec -AckGiveUpMs $cv.AckGiveUpMs -PreDoneMs $PreDoneMs -Timing $timing
        Write-Output "HOST GIVE-UP: $($dl.GiveUpUtc.ToString('o')) = BootStartUtc $($origin.ToString('o')) + $DeviceDeadlineSec s - $HostMarginSec s (device deadline no earlier than $($dl.DeviceDeadlineUtc.ToString('o'))); $([long][Math]::Floor($cv.RemainMs / 1000)) s left after $([long]($nowU - $cliUtc).TotalSeconds) s of preparation"
        $started = $true
        $r = Invoke-FsCollectRun -Transport $t -OutDir $OutDir -Tokens $tokens -Cfg $cfg -Mode 'live' -PortName $Port
    }
    try { Save-FsCollectJson -Result $r -Path (Join-Path $OutDir 'collect.json') }
    catch { Write-Output (ConvertTo-FsPrintable "COLLECT.JSON NOT WRITTEN: $($_.Exception.Message)") }
    Write-FsSummary $r
    $exit = switch ($r.Status) { 'COLLECTED-VALID' { 10 } 'COLLECTED-REJECTED' { 11 } default { 14 } }
} catch {
    Write-Output (ConvertTo-FsPrintable "REFUSED/ERROR: $($_.Exception.Message)")
    $ctx = $script:FsLastCtx
    if (-not $started -or $null -eq $ctx) { Write-Output 'RECOVERY: nothing was sent to the device by this run'; $exit = 20 }
    else {
        Write-Output (ConvertTo-FsPrintable "SENT:   $(@($ctx.Sent) -join ' | ')")
        Write-Output 'RECOVERY: fs-done NOT sent (collector error): the PID 1 deadline reboots the device (T0+DEADLINE of its image)'
        $exit = 70
    }
}
exit $exit
