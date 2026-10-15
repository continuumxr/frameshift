# Generates the synthetic Replay captures in fixtures\replay\ (deterministic:
# fixed tokens, fixed timing; rerunning reproduces MANIFEST.sha256).
#   powershell -NoProfile -ExecutionPolicy Bypass -File gen-replay.ps1
# Each case is <name>.raw (device -> host bytes) + <name>.raw.idx (read chunks
# and host writes, the same format fs-collect.ps1 records live) and one row
# in CASES.tsv with the expected collector result.
# The device side is modelled on the stage-1 transcripts (FS-A-005-raw):
# ash echoes the line, prints records, then the prompt "~ # ESC[6n"; its
# continuation prompt is "> ESC[6n".
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'synth.ps1')
$OUT = Join-Path $PSScriptRoot 'replay'
$null = New-Item -ItemType Directory -Force -Path $OUT
Get-ChildItem -Path $OUT -File | Where-Object { $_.Name -ne '.gitattributes' } | Remove-Item

$N = 'a1b2c3d4e5f60718'; $V = '0f1e2d3c4b5a69788796a5b4c3d2e1f0'; $A = '5a5a0123456789ab'; $C = 'c3c3a1b2c3d4e5f60718293a4b5c6d7e'
$KERNEL = $script:SynKernel; $P1 = $script:SynPid1
$E = [string][char]27
$P = "~ # $E[6n"; $PS2 = "> $E[6n"
$STAGES = 'INIT_STARTED,MODULES_READY,ACM_SETUP_ATTEMPTED,UDC_BOUND,SHELL_READY'
function Resp([string]$n, [string]$c) { Get-FsSha256Hex (SB "$($n):$c") }
$FSV1 = "FSV1 nonce=$N resp=$(Resp $N $V) kernel=$KERNEL pid1=$P1 stages=$STAGES END"
$cases = New-Object System.Collections.Generic.List[string]
$cases.Add("# name`tstatus`tstop-substring`tsent`tfsb1`tclassify`toverrides`tdescription")

function New-S { param([string]$Mangle = 'lf', [string]$Nonce = $N, [switch]$NoEcho)
    $s = New-Synth -Nonce $Nonce -Mangle $Mangle
    $s | Add-Member NoteProperty Echo (-not $NoEcho)
    $s
}
function Dev { param($S, [string]$Text, [int]$Chunk = 0, [int]$Dt = 5) Add-Dev $S (SB $Text) -Chunk $Chunk -Dt $Dt }
function First { param($S) if ($S.Ms -lt 1000) { $S.Ms = 1000 } }
function Cmd { param($S, [string]$Cmd, [int]$Dt = 20, [int]$Chunk = 0)
    First $S; Add-Host $S $Cmd -Dt $Dt
    if ($S.Echo) { Dev $S "$Cmd`n" -Chunk $Chunk }
}
function Verify { param($S, [string]$Rec = $FSV1, [int]$Chunk = 0) Cmd $S "fs-verify $V" -Chunk $Chunk; Dev $S "$Rec`n" -Chunk $Chunk; Dev $S $P -Chunk $Chunk }
function Ack    { param($S, [int]$Chunk = 0) Cmd $S "fs-ack $A" -Chunk $Chunk; Dev $S "FSA1 queued END`n" -Chunk $Chunk; Dev $S $P -Chunk $Chunk }
function Status { param($S, [string]$Acked = $A, [int]$Chunk = 0)
    Cmd $S 'fs-status' -Dt 2600 -Chunk $Chunk
    $st = if ($Acked -ne 'none') { "$STAGES,HOST_ACK" } else { $STAGES }
    Dev $S "FSS1 nonce=$($S.Nonce) stages=$st acked=$Acked END`n" -Chunk $Chunk; Dev $S $P -Chunk $Chunk
}
function Valve  { param($S, [byte[]]$Rec, [string]$Chal = $C, [int]$Chunk = 256, [string]$After = $P, [switch]$RawRec, [int]$Dt = 5, [string]$Verb = 'fs-valve')
    Cmd $S "$Verb $Chal"
    if ($RawRec) { Add-Dev $S $Rec -Chunk $Chunk -Dt $Dt -Raw } else { Add-Dev $S $Rec -Chunk $Chunk -Dt $Dt }
    if ($After) { Dev $S $After }
}
function Done   { param($S) Cmd $S 'fs-done'; Dev $S "FSD1 queued END`n" }
function GoodRec { param([string]$n = $N, [string]$c = $C) SB (New-SynthFsb1 -Exp 'stage2a' -Nonce $n -Chal $c -Steps (Get-Stage2aGoodSteps -Nonce $n -Chal $c)) }
function Emit { param($S, [string]$Name, [string]$Status, [string]$Stop, [string]$Sent, [string]$Fsb1, [string]$Class, [string]$Ov, [string]$Desc)
    Save-Synth $S (Join-Path $OUT "$Name.raw")
    $cases.Add("$Name`t$Status`t$Stop`t$Sent`t$Fsb1`t$Class`t$Ov`t$Desc")
}
$ALL = 'fs-verify,fs-ack,fs-status,fs-valve,fs-done'
$TO4 = 'fs-verify,fs-ack,fs-status,fs-valve'

# --- positives -------------------------------------------------------------------
foreach ($m in 'lf', 'crlf', 'crcrlf') {
    $s = New-S -Mangle $m; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (GoodRec); Done $s
    Emit $s "good-$m" 'COLLECTED-VALID' '-' $ALL 'valid' 'PASS' '-' "full exchange; device newlines $m (tty ONLCR modelled)"
}
$s = New-S -NoEcho; Verify $s; Ack $s; Status $s; Valve $s (GoodRec); Done $s
Emit $s 'no-echo-record-joins-prompt' 'COLLECTED-REJECTED' '-' $ALL 'no-begin' 'INCONCLUSIVE' '-' 'FINDING: without an echo, FSB1 BEGIN follows the prompt on the same line; the whole-capture decode rejects it (no-begin)'
$s = New-S -NoEcho; Verify $s; Ack $s; Status $s; Valve $s ([byte[]]((SB "`n") + (GoodRec))); Done $s
Emit $s 'no-echo-leading-newline' 'COLLECTED-VALID' '-' $ALL 'valid' 'PASS' '-' 'target does not echo; the runner prints a newline before BEGIN (proposed encoder change)'
$s = New-S; Verify $s -Chunk 1; Ack $s -Chunk 1; Status $s -Chunk 1; Valve $s (GoodRec) -Chunk 13 -Dt 1; Done $s
Emit $s 'good-split-reads' 'COLLECTED-VALID' '-' $ALL 'valid' 'PASS' '-' '1-byte reads for every exchange, 13-byte reads for the record'
$s = New-S; $b = New-Object byte[] 256; for ($k = 0; $k -lt 256; $k++) { $b[$k] = [byte]$k }
Add-Dev $s $b -Raw; Dev $s "`n$P"; Verify $s; Ack $s; Status $s; Valve $s (GoodRec); Done $s
Emit $s 'binary-noise-pre' 'COLLECTED-VALID' '-' $ALL 'valid' 'PASS' '-' 'all 256 byte values before the first command; re-capture must be byte-exact'

# --- interleaved noise -------------------------------------------------------------
$noise = "[   12.345678] usb 1-1: noise line`n"
$s = New-S; Dev $s "$noise$P"
Cmd $s "fs-verify $V"; Dev $s $noise; Dev $s "$FSV1`n"; Dev $s $noise; Dev $s $P
Cmd $s "fs-ack $A"; Dev $s "FSA1 queued END`n"; Dev $s ("junk " + [char]7 + [char]0 + [char]255 + "$E[2J`n"); Dev $s $P
Cmd $s 'fs-status' -Dt 2600; Dev $s $noise; Dev $s "FSS1 nonce=$N stages=$STAGES,HOST_ACK acked=$A END`n"; Dev $s $P
Cmd $s "fs-valve $C"; Dev $s $noise; Add-Dev $s (GoodRec) -Chunk 256; Dev $s $noise; Dev $s $P; Done $s
Emit $s 'noise-outside-records' 'COLLECTED-VALID' '-' $ALL 'valid' 'PASS' '-' 'noise and binary junk lines between records (never inside one)'
$rec = (New-SynthFsb1 -Exp 'stage2a' -Nonce $N -Chal $C -Steps (Get-Stage2aGoodSteps -Nonce $N -Chal $C)) -split "`n"
$withNoise = (($rec[0..4] + @('[   99.000001] noise inside the record') + $rec[5..($rec.Count - 1)]) -join "`n")
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (SB $withNoise); Done $s
Emit $s 'noise-inside-record' 'COLLECTED-REJECTED' '-' $ALL 'line-count' 'INCONCLUSIVE' '-' 'a foreign line between two record lines'
$k = 0; for ($j = 0; $j -lt $rec.Count; $j++) { if ($rec[$j].StartsWith('FSB1 DATA')) { $k = $j; break } }
$mid = $rec.Clone(); $mid[$k] = $mid[$k].Substring(0, 30) + 'zz' + $mid[$k].Substring(30)
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (SB ($mid -join "`n")); Done $s
Emit $s 'noise-mid-line' 'COLLECTED-REJECTED' '-' $ALL 'rec-hash' 'INCONCLUSIVE' '-' 'two bytes injected inside a DATA line'

# --- truncation, silence, echo, continuation (FS-R-005 §5 D1) ----------------------
$g = GoodRec; $cut = New-Object byte[] ([int]($g.Length * 0.6)); [Array]::Copy($g, $cut, $cut.Length)
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s $cut -After ''
Emit $s 'truncated-record' 'INCONCLUSIVE' 'fs-valve: partial' $TO4 'no-end' 'INCONCLUSIVE' '-' 'record stops at 60% (device silent afterwards); fs-done is not sent'
$s = New-S; Dev $s $P; Cmd $s "fs-verify $V"; Dev $s $FSV1.Substring(0, 45)
Emit $s 'truncated-verify' 'INCONCLUSIVE' 'fs-verify: partial' 'fs-verify' '-' '-' '-' 'FSV1 line cut mid-line, never terminated'
$s = New-S; Dev $s $P; Cmd $s "fs-verify $V"
Emit $s 'echo-only' 'INCONCLUSIVE' 'fs-verify: echo-only' 'fs-verify' '-' '-' '-' 'the command is echoed; no record follows'
$s = New-S; Dev $s $P; First $s; Add-Host $s "fs-verify $V"
Emit $s 'silent' 'INCONCLUSIVE' 'fs-verify: silent' 'fs-verify' '-' '-' '-' 'nothing at all after the command'
$s = New-S; Dev $s $P; Cmd $s "fs-verify $V"; Dev $s $PS2
Add-Host $s "fs-ack $A" -Dt 30000; Add-Host $s 'fs-status'; Add-Host $s "fs-valve $C"
Emit $s 'continuation-after-verify' 'INCONCLUSIVE' 'fs-verify: continuation' 'fs-verify' '-' '-' '-' 'D1 pass-1 state: echo then PS2; the index also holds the 3 writes a blind collector would have made'
$s = New-S; Dev $s ("cat /proc/cmdline; echo __FS''_END_1__`n" + $PS2); First $s; Add-Host $s "fs-verify $V"
Emit $s 'pre-continuation' 'INCONCLUSIVE' 'pre-continuation' 'none' '-' '-' '-' 'D1 pass-2 state: the shell is already in a continuation before anything is sent; nothing is sent'
$s = New-S; Dev $s $P; Cmd $s "fs-verify $V"; Dev $s $FSV1; Dev $s $P
Emit $s 'verify-unterminated-then-prompt' 'INCONCLUSIVE' 'fs-verify: partial' 'fs-verify' '-' '-' '-' 'a complete-looking FSV1 without its newline, then a prompt on the same line'
$s = New-S; Dev $s $P; Verify $s; Cmd $s "fs-ack $A"
Emit $s 'ack-echo-only' 'INCONCLUSIVE' 'fs-ack: echo-only' 'fs-verify,fs-ack' '-' '-' '-' 'fs-ack echoed, no FSA1'
$s = New-S; Dev $s $P; Verify $s; Ack $s; Cmd $s 'fs-status' -Dt 2600; Dev $s "FSS1 nonce=$N stages=$STAGES,HOST"
Emit $s 'status-partial' 'INCONCLUSIVE' 'fs-status: partial' 'fs-verify,fs-ack,fs-status' '-' '-' '-' 'FSS1 cut mid-line'
$s = New-S; Dev $s $P; Cmd $s "fs-verify $V"; Dev $s "$FSV1`n"
Emit $s 'verify-no-prompt' 'INCONCLUSIVE' 'prompt missing' 'fs-verify' '-' '-' '-' 'FSV1 complete but no prompt follows: state unknown, nothing more sent (no fs-done)'

# --- echo vs completion -------------------------------------------------------------
$s = New-S; Dev $s $P; Cmd $s "fs-verify $V"; Dev $s "xx $FSV1`n"; Dev $s $P
Emit $s 'record-not-at-line-start' 'INCONCLUSIVE' 'fs-verify: no-completion' 'fs-verify' '-' '-' '-' 'a correct FSV1 that does not start its line is not a completion'
$s = New-S; Dev $s $P; Verify $s -Rec "FSV1 nonce=$N resp=$V kernel=$KERNEL pid1=$P1 stages=$STAGES END"
Emit $s 'verify-echoed-challenge' 'INCONCLUSIVE' 'does not verify (bad response)' 'fs-verify' '-' '-' '-' 'FSV1 whose resp is the challenge itself: complete but not verified; no fs-done'
$s = New-S; Dev $s $P; Verify $s -Rec "FSV1 nonce=ffffffffffffffff resp=$(Resp 'ffffffffffffffff' $V) kernel=$KERNEL pid1=$P1 stages=$STAGES END"
Emit $s 'verify-wrong-nonce' 'INCONCLUSIVE' 'does not verify (nonce mismatch)' 'fs-verify' '-' '-' '-' 'another image answers'
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s -Acked 'none'; Status $s -Acked 'none'; Status $s -Acked 'none'; Done $s
Emit $s 'ack-not-recorded' 'INCONCLUSIVE' 'ack not recorded' 'fs-verify,fs-ack,fs-status,fs-status,fs-status,fs-done' '-' '-' '-' 'PID 1 never records the token: bounded retries, then stop (known state: fs-done)'

# --- spliced attempts -------------------------------------------------------------
$s = New-S; Dev $s ("fs-valve 99999999999999999999999999999999`n" + $script:SynL1.GetString((GoodRec -n '0123456789abcdef' -c '99999999999999999999999999999999')) + $P)
Verify $s; Ack $s; Status $s; Valve $s (GoodRec); Done $s
Emit $s 'spliced-old-record-before-send' 'COLLECTED-REJECTED' '-' $ALL 'multiple-begin' 'INCONCLUSIVE' '-' 'a previous attempt''s record arrives before anything is sent; the real record follows'
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (GoodRec -n '0123456789abcdef' -c 'deadbeefdeadbeefdeadbeefdeadbeef'); Done $s
Emit $s 'spliced-other-attempt-response' 'COLLECTED-REJECTED' '-' $ALL 'nonce-mismatch' 'INCONCLUSIVE' '-' 'the response record belongs to another attempt (nonce and challenge)'
$two = [byte[]]((GoodRec) + (GoodRec -n '0123456789abcdef' -c 'deadbeefdeadbeefdeadbeefdeadbeef'))
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s $two; Done $s
Emit $s 'spliced-two-records' 'COLLECTED-REJECTED' '-' $ALL 'multiple-begin' 'INCONCLUSIVE' '-' 'two attempts'' records back to back before the prompt'

# --- deadline and prompt state after the record -------------------------------------
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Cmd $s "fs-valve $C"; $s.Ms += 30000; Add-Dev $s (GoodRec) -Chunk 256; Dev $s $P
Emit $s 'late-record' 'INCONCLUSIVE' 'fs-valve: echo-only' $TO4 'no-begin' 'INCONCLUSIVE' 'RecordTimeoutMs=20000' 'the record starts 30 s after fs-valve; the collection deadline is 20 s'
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (GoodRec) -After ''
Emit $s 'no-prompt-after-record' 'COLLECTED-VALID' 'prompt missing: fs-done not sent' $TO4 'valid' 'PASS' '-' 'valid record but the shell never returns: no fs-done (deadline recovers)'
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (GoodRec) -After $PS2
Emit $s 'continuation-after-record' 'COLLECTED-VALID' 'prompt continuation' $TO4 'valid' 'PASS' '-' 'valid record followed by PS2: no fs-done'

# --- real encoder output (common/fixtures/fsb1, made by fsb1-enc.sh under qemu) -------
$FX = Join-Path $PSScriptRoot '..\..\common\fixtures\fsb1'
$RN = '5e1f0c3a9b7d2468'; $RC = 'c0ffee00112233445566778899aabbcc'
$FSV1r = "FSV1 nonce=$RN resp=$(Resp $RN $V) kernel=$KERNEL pid1=$P1 stages=$STAGES END"
foreach ($f in 'valid', 'valid-pty') {
    $s = New-S -Nonce $RN; Dev $s $P; Verify $s -Rec $FSV1r; Ack $s; Status $s
    Valve $s ([IO.File]::ReadAllBytes((Join-Path $FX "$f.txt"))) -Chal $RC -RawRec; Done $s
    Emit $s "real-encoder-$f" 'COLLECTED-VALID' '-' $ALL 'valid' '-' 'Exp=fixture;Steps=text|bytes|empty|both|slow|kat|chal' "common/fixtures/fsb1/$f.txt as the response (real encoder, busybox under qemu)"
}

# --- end-to-end into the classifier -------------------------------------------------
$st = Get-Stage2aGoodSteps -Nonce $N -Chal $C
$pins = Get-SynthPins
$bad = (($pins | ForEach-Object { $h = if ($_.Path -like '*libc*') { 'f' * 64 } else { $_.Sha256 }; "$h  $($_.Path)`n" }) -join '')
$st[0] = New-SynthStep 1 'hash' (SB $bad)
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (SB (New-SynthFsb1 -Exp 'stage2a' -Nonce $N -Chal $C -Steps $st)); Done $s
Emit $s 'e2e-integrity-fault' 'COLLECTED-VALID' '-' $ALL 'valid' 'INTEGRITY FAULT' '-' 'libc digest differs from its pin'
$st = Get-Stage2aGoodSteps -Nonce $N -Chal $C
$st[6] = New-SynthStep 7 'b2chal' (SB ((Get-FsBlake2bHex (SB "$($N):$C`n")) + "  -`n"))
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (SB (New-SynthFsb1 -Exp 'stage2a' -Nonce $N -Chal $C -Steps $st)); Done $s
Emit $s 'e2e-compat-fail' 'COLLECTED-VALID' '-' $ALL 'valid' 'COMPATIBILITY FAIL' '-' 'b2chal digests the challenge with a trailing newline'

# --- stage 3a (fs-display; -Stage 3a; OUTCOMES §8) ------------------------------------
$ALL3 = 'fs-verify,fs-ack,fs-status,fs-display,fs-done'
function Rec3 { param([object[]]$Steps) SB ("`n" + (New-SynthFsb1 -Exp 'stage3a' -Nonce $N -Chal $C -Steps $Steps)) }   # with fsb1_emit's leading empty line
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (Rec3 (Get-Stage3aGoodSteps -Nonce $N -Chal $C)) -Verb 'fs-display'; Done $s
Emit $s '3a-committed' 'COLLECTED-VALID' '-' $ALL3 'valid' 'PASS (machine side)' 'Stage=3a' 'stage 3a: committed and held; machine-side PASS (the PM reading decides)'
$nd = New-SynthFsp1 -Nonce8 $C.Substring(0, 8) -Recs (Get-Stage3aNoDisplayRecs 10 'no_device')
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (Rec3 (Get-Stage3aGoodSteps -Nonce $N -Chal $C -Stream $nd -Code 10)) -Verb 'fs-display'; Done $s
Emit $s '3a-no-device' 'COLLECTED-VALID' '-' $ALL3 'valid' 'NO-DISPLAY' 'Stage=3a' 'stage 3a: fs-pattern exit 10 (no device), as in the offline image harness'
$s = New-S -NoEcho; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (Rec3 (Get-Stage3aGoodSteps -Nonce $N -Chal $C)) -Verb 'fs-display'; Done $s
Emit $s '3a-no-echo' 'COLLECTED-VALID' '-' $ALL3 'valid' 'PASS (machine side)' 'Stage=3a' 'stage 3a without echo: fsb1_emit''s empty line keeps BEGIN at a line start'

# --- fix round 6 (package reviews of cf251bb) ----------------------------------------
# B1: the device already holds another session's ack (a stage-1-style observer acked first).
# PID 1 records only the first ack, so retrying cannot succeed: stop at the first FSS1 that shows
# a foreign token, INCONCLUSIVE, no experiment request, and the gated fs-done (recover now).
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s -Acked '0123456789abcdef'; Done $s
Emit $s 'already-acked' 'INCONCLUSIVE' 'foreign ack' 'fs-verify,fs-ack,fs-status,fs-done' '-' '-' '-' 'PID 1 shows an earlier (foreign) ack: stop at once, no fs-valve, gated fs-done'
# S2: the runner refuses (no FSB1 text): terminal, INCONCLUSIVE, gated fs-done (stage 2a and 3a)
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Cmd $s "fs-valve $C"; Dev $s "FSVE1 error=already-run END`n"; Dev $s $P; Done $s
Emit $s 'runner-refused-2a' 'INCONCLUSIVE' 'the runner refused' $ALL 'no-begin' '-' '-' 'fs-valve prints FSVE1 error=already-run END: no record, fs-done at once'
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Cmd $s "fs-display $C"; Dev $s "FSDE1 error=bad-nonce END`n"; Dev $s $P; Done $s
Emit $s 'runner-refused-3a' 'INCONCLUSIVE' 'the runner refused' $ALL3 'no-begin' '-' 'Stage=3a' 'fs-display prints FSDE1 error=bad-nonce END: no record, fs-done at once'
# S1: the ack window. With 3 s of window left at collector start, fs-status cannot be sent in time:
# the collector stops before PID 1's no-host-ack reboot and sends nothing more (state not known).
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Valve $s (GoodRec); Done $s
Emit $s 'ack-window-reached' 'INCONCLUSIVE' 'ack window reached' 'fs-verify,fs-ack' '-' '-' 'AckGiveUpMs=3000' 'the ack window ends before fs-status: nothing more is sent'

# --- fix round 7: NIT3, the runner's worst case must fit before the host give-up ---
$s = New-S; Dev $s $P; Verify $s; Ack $s; Status $s; Done $s
Emit $s 'runner-budget' 'INCONCLUSIVE' 'runner budget' 'fs-verify,fs-ack,fs-status,fs-done' '-' '-' 'GiveUpMs=100000' 'host give-up 100 s after start: less than the runner worst case 127 s + 5 s is left; no fs-valve, gated fs-done'

# --- FS-R-007 B1: the Chair's timeline (fastboot boot invoked at 0, T0 2, return 60, collector start 80)
# with a slow shell (every reply ~9 s after its command; PID 1 records the ack on the second fs-status,
# ~43 s after collector start). With the origin BootStartUtc the give-up is 80 s nearer than with Th:
# 2a give-up = 245 - 80 = 165 s, 3a = 155 - 80 = 75 s, ack window = 135 - 80 = 55 s after collector start.
function SlowPre { param($S)
    Dev $S $P
    Cmd $S "fs-verify $V"; Dev $S "$FSV1`n" -Dt 9000; Dev $S $P
    Cmd $S "fs-ack $A"; Dev $S "FSA1 queued END`n" -Dt 9000; Dev $S $P
    Cmd $S 'fs-status' -Dt 2600; Dev $S "FSS1 nonce=$($S.Nonce) stages=$STAGES acked=none END`n" -Dt 9000; Dev $S $P
    Cmd $S 'fs-status' -Dt 2600; Dev $S "FSS1 nonce=$($S.Nonce) stages=$STAGES,HOST_ACK acked=$A END`n" -Dt 9000; Dev $S $P
}
$s = New-S; SlowPre $s; Done $s
Emit $s 'b1-late-2a' 'INCONCLUSIVE' 'runner budget' 'fs-verify,fs-ack,fs-status,fs-status,fs-done' '-' '-' 'GiveUpMs=165000;AckGiveUpMs=55000' 'FS-R-007 B1, stage 2a: origin BootStartUtc, collector start +80 s, slow shell: ~122 s left at the runner < 127 + 5 s: no fs-valve, gated fs-done'
$s = New-S; SlowPre $s; Done $s
Emit $s 'b1-late-3a' 'INCONCLUSIVE' 'runner budget' 'fs-verify,fs-ack,fs-status,fs-status,fs-done' '-' '-' 'Stage=3a;GiveUpMs=75000;AckGiveUpMs=55000' 'FS-R-007 B1, stage 3a (the Chair counterexample): origin BootStartUtc, collector start +80 s, slow shell, 3 s cue: ~29 s left < 42 + 5 + 11 s: no fs-display, gated fs-done'

[IO.File]::WriteAllText((Join-Path $OUT 'CASES.tsv'), (($cases | ForEach-Object { "$_`n" }) -join ''), (New-Object System.Text.UTF8Encoding($false)))
$man = Get-ChildItem -Path $OUT -File | Where-Object { $_.Name -notin @('MANIFEST.sha256', '.gitattributes') } | Sort-Object Name |
    ForEach-Object { "$(Get-FsSha256Hex ([IO.File]::ReadAllBytes($_.FullName)))  $($_.Name)" }
[IO.File]::WriteAllText((Join-Path $OUT 'MANIFEST.sha256'), (($man | ForEach-Object { "$_`n" }) -join ''), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "generated $($cases.Count - 1) cases in $OUT"
