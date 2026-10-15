# FrameShift stage 3c: the interactive part of the host session (Windows PowerShell 5.1, no modules).
# Design: devices/quest3/stage3c/DESIGN.md revision 3, sections 8.2 (prompts), 8.3 (gap deadline and
# countdown), 8.4 (sounds and banners, the preflight sound check) and 8.5 (readings record).
#
# Dot-sourced by fs-collect3c.ps1 (after the pinned fs-collect.ps1) and by test-host3c.ps1. Run on
# its own only for the preflight sound check (nothing touches the device, no port is opened):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File devices\quest3\host\fs-session3c.ps1 -SoundCheck [-SoundCheckDir <dir>]
#   Exit 0 = SOUND CHECK PASSED, 1 = FAILED (then nothing is booted), 64 usage, 70 internal error.
#   Run it in powershell.exe (a console host): [Console]::KeyAvailable / ReadKey are needed (not ISE).
#
# M4 (DESIGN 8.1): this file's parameter names collide with none of fs-collect.ps1's, and it never
# reads or assigns $Stage or any other name of fs-collect.ps1's param() block (test-host3c case 21).
#
# Pieces (all injectable, so test-host3c.ps1 drives them with a ScriptedKeySource, a recording sound
# sink and a recording console):
#   Sounds      New-Fs3cSounds: five 16-bit 44.1 kHz mono PCM WAVs generated in memory (no files, no
#               download), each with its SHA-256. New-Fs3cSoundSink: live = System.Media.SoundPlayer
#               (Load() once, then Play(), asynchronous, never PlaySync); if Play throws, the fallback
#               SystemSounds.Exclamation plus a console bell, and the failure is logged.
#   Console     New-Fs3cUi: 5-line full-width banners (Write-Host -BackgroundColor) and plain lines.
#   Keys        New-Fs3cConsoleKeySource ([Console]::KeyAvailable/ReadKey; Ctrl+C is read as `x`, build review
#               MAJOR-2) or New-Fs3cScriptedKeySource (entries 'anchor:delayMs:key'; see that function).
#   Console     Enter-/Exit-Fs3cConsoleMode: for an interactive session, Ctrl+C as input and QuickEdit off
#               (restored afterwards; build review MAJOR-2, MINOR-9).
#   Prompts     Invoke-Fs3cGap: the prompts of one gap (left, right, dark check, then after run 2 the
#               layout items), each with the 30 s timeout cut to the gap deadline, the key buffer
#               drained before every prompt (discarded keys logged), the previous answer's key ignored
#               for 600 ms at a prompt's start (key repeat; build review MINOR-2), every answer echoed in
#               words, FSR2 lines for readings3c.txt, appended to the file at once (and a session.json
#               checkpoint) so a closed window keeps every answer given (build review MAJOR-2).
#               Q7 fallback (PM rehearsal 2026-10-12, DESIGN 15 Q7): on the run-3 path (-BarsQ7 says DESIGN 5.8
#               rules 1-4 hold after the dark check) the bar counts are not asked (FSR2 NOT_ASKED, event
#               bars-not-asked ... (Q7 fallback)). PM rehearsal feedback: `n` (light visible) is a key of the
#               DARK CHECK only (the eye, character and layout prompts take x to abort); short per-eye lines; a
#               self-explanatory bar-count prompt.
#   Preflight   Invoke-Fs3cSoundCheck: each sound named (y per sound heard), three unnamed sounds
#               identified (s/e/a/f/l), the one-handed key-reach test; soundcheck.json.
# No machine fact is ever printed by this file: it never sees a record.
param(
    [switch]$SoundCheck,
    [string]$SoundCheckDir = '',
    [int]$SoundCheckSeed = -1
)
Set-StrictMode -Version 2.0
$script:Fs3cSessionInvocation = $MyInvocation.InvocationName

# ------------------------------------------------------------------ sounds ----
if (-not ('Fs3cWav' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
public static class Fs3cWav {
    const int Rate = 44100;
    // segments: {f0, f1, ms, gapMs} per tone; f0 -> f1 is a linear glide; amplitude 0.45 with 5 ms fades
    public static byte[] Make(double[] seg) {
        int total = 0;
        for (int i = 0; i + 3 < seg.Length + 0 && i < seg.Length; i += 4) total += (int)(Rate * (seg[i + 2] + seg[i + 3]) / 1000.0);
        short[] pcm = new short[total];
        int pos = 0;
        for (int i = 0; i < seg.Length; i += 4) {
            double f0 = seg[i], f1 = seg[i + 1];
            int n = (int)(Rate * seg[i + 2] / 1000.0), g = (int)(Rate * seg[i + 3] / 1000.0);
            int fade = (int)(Rate * 0.005);
            double ph = 0.0;
            for (int k = 0; k < n; k++) {
                double f = f0 + (f1 - f0) * k / (double)n;
                ph += 2.0 * Math.PI * f / Rate;
                double a = 0.45;
                if (k < fade) a *= k / (double)fade;
                if (n - k < fade) a *= (n - k) / (double)fade;
                pcm[pos + k] = (short)Math.Round(a * 32767.0 * Math.Sin(ph));
            }
            pos += n + g;
        }
        MemoryStream ms = new MemoryStream();
        BinaryWriter w = new BinaryWriter(ms);
        int dataLen = pcm.Length * 2;
        w.Write(new char[] { 'R', 'I', 'F', 'F' }); w.Write(36 + dataLen);
        w.Write(new char[] { 'W', 'A', 'V', 'E' });
        w.Write(new char[] { 'f', 'm', 't', ' ' }); w.Write(16); w.Write((short)1); w.Write((short)1);
        w.Write(Rate); w.Write(Rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write(new char[] { 'd', 'a', 't', 'a' }); w.Write(dataLen);
        foreach (short s in pcm) w.Write(s);
        w.Flush();
        return ms.ToArray();
    }
}
'@
}

# The console input mode of an interactive session (build review MINOR-9): QuickEdit off (a click into the
# window would otherwise freeze the console output and the key reads until a key is pressed).
if (-not ('Fs3cConsole' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Fs3cConsole {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint m);
    // QuickEdit (0x40) off, extended flags (0x80) on; returns the previous input mode, or -1 if it cannot be changed
    public static long DisableQuickEdit() {
        IntPtr h = GetStdHandle(-10); uint m;
        if (!GetConsoleMode(h, out m)) return -1;
        if (!SetConsoleMode(h, (m & ~0x40u) | 0x80u)) return -1;
        return m;
    }
    public static bool RestoreInputMode(long m) { if (m < 0) return false; return SetConsoleMode(GetStdHandle(-10), (uint)m); }
}
'@
}
# Interactive sessions (live, rehearsal): Ctrl+C is read as a key and taken as `x` (the safe finish, fs-done),
# never as a script stop (build review MAJOR-2); QuickEdit off (MINOR-9). Exit-Fs3cConsoleMode restores both.
function Enter-Fs3cConsoleMode {
    $st = [pscustomobject]@{ TreatCtrlC = $null; QuickEditPrev = [long]-1; Notes = (New-Object System.Collections.Generic.List[string]) }
    try { $st.TreatCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true; $st.Notes.Add('Ctrl+C is read as a key and taken as x') }
    catch { $st.TreatCtrlC = $null; $st.Notes.Add("Ctrl+C mode not set: $($_.Exception.Message)") }
    try { $st.QuickEditPrev = [Fs3cConsole]::DisableQuickEdit()
          if ($st.QuickEditPrev -ge 0) { $st.Notes.Add('QuickEdit off for the session') } else { $st.Notes.Add('QuickEdit not changed (no console input mode): do not click into the window') } }
    catch { $st.QuickEditPrev = [long]-1; $st.Notes.Add("QuickEdit not changed: $($_.Exception.Message)") }
    $st
}
function Exit-Fs3cConsoleMode { param($St)
    if ($null -eq $St) { return }
    # Input mode first (it was saved after Ctrl+C was set to read-as-key), then the Ctrl+C setting (R-D NIT).
    try { if ($St.QuickEditPrev -ge 0) { $null = [Fs3cConsole]::RestoreInputMode($St.QuickEditPrev) } } catch {}
    try { if ($null -ne $St.TreatCtrlC) { [Console]::TreatControlCAsInput = [bool]$St.TreatCtrlC } } catch {}
}

# DESIGN 8.4 table. Each segment: f0, f1 (Hz), duration ms, silence after (ms).
$script:Fs3cSoundShapes = [ordered]@{
    START  = @{ Shape = '660 -> 880 Hz rising, 2 x 0.2 s'; Seg = [double[]]@(660, 660, 200, 0, 880, 880, 200, 0) }
    END    = @{ Shape = '880 -> 440 Hz falling, 0.6 s';   Seg = [double[]]@(880, 440, 600, 0) }
    ANSWER = @{ Shape = '3 x 0.1 s pips at 1000 Hz';      Seg = [double[]]@(1000, 1000, 100, 100, 1000, 1000, 100, 100, 1000, 1000, 100, 0) }
    FINISH = @{ Shape = '330 Hz, 1.0 s';                   Seg = [double[]]@(330, 330, 1000, 0) }
    ALARM  = @{ Shape = '1200/600 Hz x 3';                 Seg = [double[]]@(1200, 1200, 150, 0, 600, 600, 150, 0, 1200, 1200, 150, 0, 600, 600, 150, 0, 1200, 1200, 150, 0, 600, 600, 150, 0) }
}
function Get-Fs3cSha256Hex { param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}
function New-Fs3cSounds {
    $o = [ordered]@{}
    foreach ($k in $script:Fs3cSoundShapes.Keys) {
        [byte[]]$b = [Fs3cWav]::Make($script:Fs3cSoundShapes[$k].Seg)
        $o[$k] = [pscustomobject]@{ Name = $k; Shape = $script:Fs3cSoundShapes[$k].Shape; Bytes = $b; Sha256 = (Get-Fs3cSha256Hex $b); Length = $b.Length }
    }
    $o
}
function Get-Fs3cSoundHashes { param($Sounds)
    $h = [ordered]@{}; foreach ($k in $Sounds.Keys) { $h[$k] = [ordered]@{ Sha256 = $Sounds[$k].Sha256; Bytes = $Sounds[$k].Length; Shape = $Sounds[$k].Shape } }; $h
}

# A sound sink. Kind 'live': one System.Media.SoundPlayer per sound, Load() once at start-up, Play()
# (asynchronous; never PlaySync). Kind 'record': nothing is played (replay, fixtures). -Player /
# -Fallback replace the play and fallback actions (fixtures: a failing player). Every call is recorded
# in Played ("NAME@ms"); a failed Play is recorded in Failures and the fallback runs.
function New-Fs3cSoundSink {
    param([string]$Kind = 'record', [Parameter(Mandatory)]$Sounds, [scriptblock]$Player = $null, [scriptblock]$Fallback = $null)
    $s = [pscustomobject]@{ Kind = $Kind; Sounds = $Sounds; Players = @{}; Played = (New-Object System.Collections.Generic.List[string])
                            Failures = (New-Object System.Collections.Generic.List[string]); PlayerFn = $Player; FallbackFn = $Fallback; LoadErrors = @{} }
    if ($Kind -ceq 'live' -and $null -eq $Player) {
        foreach ($k in $Sounds.Keys) {
            try {
                $p = New-Object System.Media.SoundPlayer
                $p.Stream = New-Object System.IO.MemoryStream (, [byte[]]$Sounds[$k].Bytes)
                $p.Load()
                $s.Players[$k] = $p
            } catch { $s.LoadErrors[$k] = $_.Exception.Message }
        }
        $s.PlayerFn = { param($sink, [string]$name)
            if (-not $sink.Players.ContainsKey($name)) { throw "no loaded player for $name ($($sink.LoadErrors[$name]))" }
            $sink.Players[$name].Play() }
    }
    if ($null -eq $s.PlayerFn) { $s.PlayerFn = { param($sink, [string]$name) } }
    if ($null -eq $s.FallbackFn) {
        if ($Kind -ceq 'live') { $s.FallbackFn = { param($sink, [string]$name) [System.Media.SystemSounds]::Exclamation.Play(); [Console]::Out.Write([char]7) } }
        else { $s.FallbackFn = { param($sink, [string]$name) } }
    }
    $s | Add-Member ScriptMethod Play {
        param([string]$name, [long]$ms)
        $this.Played.Add("$name@$ms")
        try { & $this.PlayerFn $this $name }
        catch {
            $this.Failures.Add("$name@$($ms): $($_.Exception.Message)")
            try { & $this.FallbackFn $this $name } catch { $this.Failures.Add("$name@$($ms): fallback failed: $($_.Exception.Message)") }
        }
    }
    $s
}

# ----------------------------------------------------------------- console ----
# Banners: 5 full-width lines. look = black on yellow (LOOK/STARTING), ended/answer = black on green,
# info = black on cyan, abort = white on red (ABORT/SAFE FINISH/FINISH/ALARM). Kind 'record' keeps a
# transcript only (fixtures); 'console' writes with Write-Host and keeps the transcript too.
$script:Fs3cBannerColors = @{ look = @('Yellow', 'Black'); ended = @('Green', 'Black'); answer = @('Green', 'Black'); info = @('Cyan', 'Black'); abort = @('Red', 'White') }
function New-Fs3cUi {
    param([string]$Kind = 'record', [int]$Width = 0)
    $u = [pscustomobject]@{ Kind = $Kind; Transcript = (New-Object System.Collections.Generic.List[string]); Width = $Width }
    if ($u.Width -le 0) { $u.Width = 78; if ($Kind -ceq 'console') { try { $w = [Console]::WindowWidth; if ($w -ge 40) { $u.Width = $w - 1 } } catch {} } }
    $u | Add-Member ScriptMethod Line {
        param([string]$text)
        $t = [FsHostNative]::Printable($text)
        $this.Transcript.Add($t)
        if ($this.Kind -ceq 'console') { Write-Host $t }
    }
    $u | Add-Member ScriptMethod Banner {
        param([string]$kind, [string]$text, [string]$sub = '')
        $t = [FsHostNative]::Printable($text); $s2 = [FsHostNative]::Printable($sub)
        $this.Transcript.Add("[BANNER $kind] $t$(if ($s2) { ' | ' + $s2 })")
        if ($this.Kind -cne 'console') { return }
        $c = $script:Fs3cBannerColors[$kind]; if ($null -eq $c) { $c = @('Cyan', 'Black') }
        $w = $this.Width
        $pad = { param([string]$x) if ($x.Length -ge $w) { $x.Substring(0, $w) } else { $l = [int][Math]::Floor(($w - $x.Length) / 2); (' ' * $l) + $x + (' ' * ($w - $x.Length - $l)) } }
        foreach ($ln in @('', $t, $s2, '', '')) { Write-Host (& $pad $ln) -BackgroundColor $c[0] -ForegroundColor $c[1] }
    }
    $u
}

# -------------------------------------------------------------------- keys ----
# Interface: Arm(anchor, nowMs); Read(nowMs) -> one key or $null (never blocks); Drain(nowMs) -> the keys
# already pressed (discarded by the caller and logged); NextDueMs(nowMs) -> when a key may next arrive.
# Keys: lower-case letters, digits, '?', 'Enter', 'Esc', 'Backspace'. Ctrl+C (read as input in an interactive
# session, Enter-Fs3cConsoleMode) is the key 'x' (build review MAJOR-2).
function Test-Fs3cCtrlC { param([System.ConsoleKeyInfo]$K) ($K.Key -eq [ConsoleKey]::C -and ($K.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -or [int]$K.KeyChar -eq 3 }
function ConvertTo-Fs3cKeyName { param([System.ConsoleKeyInfo]$K)
    if (Test-Fs3cCtrlC $K) { return 'x' }
    if ($K.Key -eq [ConsoleKey]::Enter) { return 'Enter' }
    if ($K.Key -eq [ConsoleKey]::Escape) { return 'Esc' }
    if ($K.Key -eq [ConsoleKey]::Backspace) { return 'Backspace' }
    $ch = $K.KeyChar
    if ([int]$ch -lt 32 -or [int]$ch -gt 126) { return "key-$([int]$K.Key)" }
    return ([string]$ch).ToLowerInvariant()
}
# -Reader (fixtures only): a scriptblock param($now) returning a [ConsoleKeyInfo] or $null, in place of the console.
function New-Fs3cConsoleKeySource {
    param([scriptblock]$Reader = $null)
    $k = [pscustomobject]@{ Kind = 'console'; Unavailable = $null; ReaderFn = $Reader; CtrlC = (New-Object System.Collections.Generic.List[long]) }
    $k | Add-Member ScriptMethod Arm { param([string]$anchor, [long]$now) }
    $k | Add-Member ScriptMethod Read {
        param([long]$now)
        try {
            $ki = $null
            if ($null -ne $this.ReaderFn) { $ki = & $this.ReaderFn $now }
            elseif ([Console]::KeyAvailable) { $ki = [Console]::ReadKey($true) }
            if ($null -ne $ki) {
                if (Test-Fs3cCtrlC $ki) { $this.CtrlC.Add($now) }
                return (ConvertTo-Fs3cKeyName $ki)
            }
        }
        catch { $this.Unavailable = $_.Exception.Message }
        return $null
    }
    $k | Add-Member ScriptMethod Drain {
        param([long]$now)
        $l = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt 256; $i++) { $x = $this.Read($now); if ($null -eq $x) { break }; $l.Add($x) }
        ,$l.ToArray()
    }
    $k | Add-Member ScriptMethod NextDueMs { param([long]$now) $now + 50 }
    $k
}
# Scripted keys (fixtures and the -S3cKeyScript replay option). Entries 'anchor:delayMs:key', in order:
#   anchor 'p' = relative to the start of the prompt that will consume it (the session arms 'p' at every
#     prompt item, after the drain), or, inside one prompt (characters, bars), to the previous key;
#   anchor 'g' / 'i' / 'j' / 'k' = pressed during phase p0 / r1 / r2 / r3 (armed when that fs-phase
#     command is sent; such a key reaches the session during the phase, where `x` is an abort noted at
#     once and anything else is discarded and logged);
#   anchor 'c' = pressed during the 3 s LOOK cue after p0.
# Only the head entry is ever scheduled; it is scheduled when the session arms its anchor (or, with the
# same anchor still armed, when the previous key was consumed). Drain() discards the scheduled keys that
# are due and every non-'p' head entry (it was pressed before this prompt appeared).
function New-Fs3cScriptedKeySource {
    param([string[]]$Script = @())
    $q = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Script)) {
        if (-not $e -or $e.StartsWith('#')) { continue }
        if ($e -cnotmatch '^([a-z]):([0-9]{1,7}):(Enter|Esc|Backspace|[a-z0-9?])\z') { throw "scripted key entry '$e' is not anchor:delayMs:key" }
        $q.Add([pscustomobject]@{ Anchor = $Matches[1]; Delay = [long][Math]::Max(1, [long]$Matches[2]); Key = $Matches[3]; Due = $null })
    }
    $k = [pscustomobject]@{ Kind = 'scripted'; Q = $q; Cur = ''; Consumed = (New-Object System.Collections.Generic.List[string]) }
    $k | Add-Member ScriptMethod Arm {
        param([string]$anchor, [long]$now)
        $this.Cur = $anchor
        if ($this.Q.Count -eq 0) { return }
        $h = $this.Q[0]
        if ($h.Anchor -ceq $anchor) { $h.Due = $now + $h.Delay } else { $h.Due = $null }
    }
    $k | Add-Member ScriptMethod Read {
        param([long]$now)
        if ($this.Q.Count -eq 0) { return $null }
        $h = $this.Q[0]
        if ($null -eq $h.Due -or $h.Due -gt $now) { return $null }
        $this.Q.RemoveAt(0); $this.Consumed.Add("$($h.Key)@$now")
        if ($this.Q.Count -gt 0 -and $this.Q[0].Anchor -ceq $this.Cur) { $this.Q[0].Due = $now + $this.Q[0].Delay }
        return $h.Key
    }
    $k | Add-Member ScriptMethod Drain {
        param([long]$now)
        $l = New-Object System.Collections.Generic.List[string]
        while ($this.Q.Count -gt 0) {
            $h = $this.Q[0]
            if (($null -ne $h.Due -and $h.Due -le $now) -or $h.Anchor -cne 'p') { $this.Q.RemoveAt(0); $l.Add($h.Key); continue }
            break
        }
        ,$l.ToArray()
    }
    $k | Add-Member ScriptMethod NextDueMs {
        param([long]$now)
        if ($this.Q.Count -eq 0 -or $null -eq $this.Q[0].Due) { return [long]::MaxValue }
        return [long]$this.Q[0].Due
    }
    $k
}

# ------------------------------------------------------------ the X object ----
# One per session: the clock and the port (through the collector context, so the port is read every
# poll in every state), the console, the keys, the sounds, the readings and the event log.
#   -Ctx: the fs-collect context (T transport, C capture, Cfg, SettledLen); $null = no port (sound check)
#   -OutDirX: the session directory: every FSR2 line is appended to readings3c.txt at once, and session.json gets
#     a checkpoint (schema frameshift.fs-collect3c.partial.v1) after every reading, so a closed window or a crash
#     keeps every answer given (build review MAJOR-2); the collector replaces both at the end.
function New-Fs3cInteract {
    param($Ctx = $null, [Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Keys, [Parameter(Mandatory)]$Sound,
          [DateTime]$UtcBase = [DateTime]::MinValue, [long]$UtcBaseMs = 0, [int]$PollMsX = 50, [string]$OutDirX = '')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($UtcBase -eq [DateTime]::MinValue) { $UtcBase = [DateTime]::UtcNow; $UtcBaseMs = 0 }
    $x = [pscustomobject]@{ Ctx = $Ctx; Ui = $Ui; Keys = $Keys; Sound = $Sound; Sw = $sw; PollMsX = $PollMsX
                            UtcBase = $UtcBase.ToUniversalTime(); UtcBaseMs = $UtcBaseMs
                            Readings = (New-Object System.Collections.Generic.List[string]); ReadingObjs = (New-Object System.Collections.Generic.List[object])
                            Events = (New-Object System.Collections.Generic.List[string]); Stray = $false; StrayMs = $null
                            ReadingsPath = $(if ($OutDirX) { Join-Path $OutDirX 'readings3c.txt' } else { '' })
                            SessionPath = $(if ($OutDirX) { Join-Path $OutDirX 'session.json' } else { '' })
                            KeyFailLogged = $false; CtrlCLogged = 0 }
    $x | Add-Member ScriptMethod Now { if ($null -ne $this.Ctx) { [long]$this.Ctx.T.NowMs() } else { [long]$this.Sw.ElapsedMilliseconds } }
    $x | Add-Member ScriptMethod Utc { param([long]$ms) $this.UtcBase.AddMilliseconds($ms - $this.UtcBaseMs).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture) }
    $x | Add-Member ScriptMethod Event { param([string]$text)
        $t = "$($this.Now()) $text"; $this.Events.Add($t)
        if ($null -ne $this.Ctx -and $text -cmatch '^[ -~]{1,190}\z') { try { $this.Ctx.C.NoteEvent($text, $this.Now()) } catch {} } }
    # build review MAJOR-2: the answer is on disk at once (readings3c.txt) and session.json holds a checkpoint
    $x | Add-Member ScriptMethod Checkpoint { param([string]$line)
        $enc = New-Object System.Text.UTF8Encoding($false)
        if ($this.ReadingsPath) { try { [IO.File]::AppendAllText($this.ReadingsPath, "$line`n", $enc) } catch { $this.Events.Add("$($this.Now()) readings-append-failed $($_.Exception.Message)") } }
        if ($this.SessionPath) {
            try {
                $cp = [ordered]@{ Schema = 'frameshift.fs-collect3c.partial.v1'; Note = 'checkpoint written after every reading; the collector replaces it with the final session.json when it finishes'
                                  Nonce = $(if ($null -ne $this.Ctx) { $this.Ctx.Cfg.Nonce } else { $null }); UpdatedUtc = $this.Utc($this.Now())
                                  Sent = $(if ($null -ne $this.Ctx) { @($this.Ctx.Sent.ToArray()) } else { @() }); Readings = @($this.Readings.ToArray()); Events = @($this.Events.ToArray()) }
                [IO.File]::WriteAllText($this.SessionPath, (($cp | ConvertTo-Json -Depth 4) + "`n"), $enc)
            } catch { $this.Events.Add("$($this.Now()) checkpoint-failed $($_.Exception.Message)") }
        }
    }
    # read whatever the port has; bytes after the settled prompt mark the session state as changed (stray)
    $x | Add-Member ScriptMethod Poll {
        # build review NIT f: a key-source failure is logged (once) and shown; Ctrl+C reads are logged
        if (-not $this.KeyFailLogged -and $this.Keys.PSObject.Properties['Unavailable'] -and $this.Keys.Unavailable) {
            $this.KeyFailLogged = $true
            $this.Events.Add("$($this.Now()) key-source-failure $($this.Keys.Unavailable)")
            $this.Ui.Line("KEYBOARD NOT READABLE ($($this.Keys.Unavailable)): every prompt will time out, which ends the session safely")
        }
        if ($this.Keys.PSObject.Properties['CtrlC'] -and $this.Keys.CtrlC.Count -gt $this.CtrlCLogged) {
            for ($i = $this.CtrlCLogged; $i -lt $this.Keys.CtrlC.Count; $i++) { $this.Events.Add("$($this.Keys.CtrlC[$i]) ctrl-c read as x") }
            $this.CtrlCLogged = $this.Keys.CtrlC.Count
        }
        if ($null -eq $this.Ctx) { return }
        for ($i = 0; $i -lt 256; $i++) { if ((Read-FsInto $this.Ctx $this.Ctx.T.NowMs()) -eq 0) { break } }
        if (-not $this.Stray -and $null -ne $this.Ctx.SettledLen -and $this.Ctx.C.Length -ne $this.Ctx.SettledLen) {
            $this.Stray = $true; $this.StrayMs = $this.Now()
            $this.Events.Add("$($this.Now()) stray-bytes $($this.Ctx.C.Length - $this.Ctx.SettledLen) after the settled prompt")
        }
    }
    $x | Add-Member ScriptMethod Idle { param([long]$until)
        $now = $this.Now()
        $u = [Math]::Min($until, $now + $this.PollMsX)
        $kd = $this.Keys.NextDueMs($now); if ($kd -gt $now -and $kd -lt $u) { $u = $kd }
        if ($u -le $now) { $u = $now + 1 }
        if ($null -ne $this.Ctx) { $this.Ctx.T.Idle($u) }
        else { $d = $u - $now; if ($d -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min($d, 50)) } }
    }
    $x
}

# Waits for one allowed key. Other keys are ignored (logged); the port is read every poll; $OnTick runs
# every poll (countdown). -RepeatKey/-RepeatUntilMs (build review MINOR-2): that key is ignored (logged)
# until that time: the previous answer's key at the start of a new prompt (key auto-repeat, a double press).
# Returns @{ Key; Ms; TimedOut }.
$script:Fs3cRepeatMs = 600   # > the Windows default key-repeat delay (500 ms; R-D MINOR)
function Wait-Fs3cKey {
    param([Parameter(Mandatory)]$X, [Parameter(Mandatory)][string[]]$Allowed, [Parameter(Mandatory)][long]$DeadlineMs, [scriptblock]$OnTick = $null, [string]$Label = '',
          [string]$RepeatKey = '', [long]$RepeatUntilMs = -1)
    while ($true) {
        $X.Poll()
        if ($null -ne $OnTick) { & $OnTick }
        $now = $X.Now()
        $k = $X.Keys.Read($now)
        while ($null -ne $k) {
            if ($RepeatKey -and $k -ceq $RepeatKey -and $now -lt $RepeatUntilMs) { $X.Event("key-repeat-ignored $Label key=$k (the previous answer's key within $($script:Fs3cRepeatMs) ms)") }
            elseif ($Allowed -ccontains $k) { return [pscustomobject]@{ Key = $k; Ms = $now; TimedOut = $false } }
            else { $X.Event("key-ignored $Label key=$k") }
            $k = $X.Keys.Read($now)
        }
        if ($now -ge $DeadlineMs) { return [pscustomobject]@{ Key = $null; Ms = $now; TimedOut = $true } }
        $X.Idle($DeadlineMs)
    }
}

# --------------------------------------------------------------- readings ----
# FSR2 p=<r1|r2|r3> item=<...> key=<k|-> obs=<OBS> [chars=<8>] [bars=<2>] prompt_ms=<ms> answer_ms=<ms|-1>
#      prompt_utc=<ISO> answer_utc=<ISO|-> discarded=<n>        (DESIGN 8.5)
function Add-Fs3cReading {
    param([Parameter(Mandatory)]$X, [string]$Ph, [string]$Item, [string]$Key = '-', [string]$Obs, [string]$Chars = '', [string]$Bars = '',
          [long]$PromptMs, [long]$AnswerMs = -1, [int]$Discarded = 0)
    if (-not $Key) { $Key = '-' }
    $au = if ($AnswerMs -ge 0) { $X.Utc($AnswerMs) } else { '-' }
    $l = "FSR2 p=$Ph item=$Item key=$Key obs=$Obs" + $(if ($Chars) { " chars=$Chars" } else { '' }) + $(if ($Bars) { " bars=$Bars" } else { '' }) +
         " prompt_ms=$PromptMs answer_ms=$AnswerMs prompt_utc=$($X.Utc($PromptMs)) answer_utc=$au discarded=$Discarded"
    $X.Readings.Add($l)
    $o = [pscustomobject]@{ Ph = $Ph; Item = $Item; Key = $Key; Obs = $Obs; Chars = $Chars; Bars = $Bars; PromptMs = $PromptMs; AnswerMs = $AnswerMs; Discarded = $Discarded }
    $X.ReadingObjs.Add($o)
    $X.Event("reading p=$Ph item=$Item key=$Key obs=$Obs")
    $X.Checkpoint($l)
    $o
}
$script:Fs3cReadKeys12 = [ordered]@{ a = @('LIT', 'LIT, NO PATTERN'); b = @('DARK', 'DARK'); c = @('GARBLED', 'GARBLED'); d = @('READ', 'READ') }
$script:Fs3cReadKeys3 = [ordered]@{ r = @('UNIFORM_RED', 'UNIFORM RED FIELD'); p = @('PARTIAL_RED', 'PARTLY RED'); u = @('UNIFORM_OTHER', 'UNIFORM FIELD OF ANOTHER COLOUR')
                                    s = @('SAME_AS_R2', 'STRIPES/GARBLE THE SAME AS RUN 2'); g = @('DIFFERENT', 'GARBLE DIFFERENT FROM RUN 2'); b = @('DARK', 'DARK') }
$script:Fs3cOrientKeys = [ordered]@{ u = @('UPRIGHT', 'F UPRIGHT'); i = @('HALF_TURN', 'F TURNED BY A HALF-TURN'); m = @('MIRRORED', 'F MIRRORED LEFT-RIGHT'); v = @('VFLIP', 'F FLIPPED TOP-BOTTOM'); '0' = @('UNKNOWN', "F: CAN'T TELL") }
$script:Fs3cTiltKeys = [ordered]@{ l = @('LEFT_LOW', 'LINE: LEFT END LOWER'); r = @('RIGHT_LOW', 'LINE: RIGHT END LOWER'); '0' = @('LEVEL', "LINE: LEVEL OR CAN'T TELL") }
$script:Fs3cHexKeys = @('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f', '?')

# The prompts of one gap (DESIGN 8.2, 8.3). Returns @{ Safe = $null|'abort'|'timeout'|'light'|'stray';
# SafeWhy; Items = hashtable item -> reading object; Discarded; NextLost }.
#   -Mode 'full' (per-eye, dark check, layout items when -Layout), 'readings' (per-eye and dark check:
#     a rejected record or an FSXE1 ran=1 refusal), 'darkonly' (after `x` during the lit phase).
#   -LastEndMs  the end of the last phase (the gap cap is LastEndMs + GapCapSec).
#   -NextName / -NextGuardMs  the next run and its guard (countdown: GiveUp - G - now); $null on run 3.
#   -BarsQ7  (run 2, layout only) a scriptblock given the reading items after the dark check; $true = this is the
#     run-3 path (DESIGN 5.8 rules 1-4 hold): the Q7 fallback, no bar-count prompt (recorded NOT_ASKED, listed in
#     BarsQ7 of the result). The rule alone decides (not the countdown), so the prompt set never depends on timing.
function Invoke-Fs3cGap {
    param([Parameter(Mandatory)]$X, [Parameter(Mandatory)][string]$Ph, [string]$Mode = 'full', [bool]$Layout = $false,
          [Parameter(Mandatory)][long]$LastEndMs, [Parameter(Mandatory)][long]$GiveUpMsX, [int]$DoneReserveSec = 3, [int]$GapCapSec = 110,
          [int]$PromptTimeoutSec = 30, [int]$LayoutMinSec = 10, [string]$NextName = '', [long]$NextGuardMs = 0, [scriptblock]$BarsQ7 = $null)
    $runN = $Ph.Substring(1, 1)
    $cutoff = [Math]::Min($GiveUpMsX - [long]$DoneReserveSec * 1000, $LastEndMs + [long]$GapCapSec * 1000)
    $res = [ordered]@{ Safe = $null; SafeWhy = ''; Items = @{}; NextLost = $false; CutoffMs = $cutoff; FirstPromptMs = $null; LastAnswerMs = $null; BarsQ7 = @() }
    $st = @{ Lost = $false; First = $true; LastKey = ''; LastMs = [long]-100000 }
    $ru = { [long]$st.LastMs + $script:Fs3cRepeatMs }                     # MINOR-2: the repeat window of the last answer
    $acc = { param($w) if ($null -ne $w -and -not $w.TimedOut) { $st.LastKey = [string]$w.Key; $st.LastMs = [long]$w.Ms } }
    $tick = {
        if ($NextName -and -not $st.Lost -and ($GiveUpMsX - $NextGuardMs - $X.Now()) -le 0) {
            $st.Lost = $true; $res.NextLost = $true
            $X.Ui.Line("RUN $($NextName.Substring(1,1)) NO LONGER POSSIBLE: finish the readings; the session then ends with fs-done.")
            $X.Event("next-lost $NextName")
        }
    }
    $countdown = {
        $now = $X.Now()
        if ($NextName) {
            $n = [long][Math]::Floor(($GiveUpMsX - $NextGuardMs - $now) / 1000)
            if ($n -gt 0) { $X.Ui.Line("$n s left to keep RUN $($NextName.Substring(1,1)) possible") }
            elseif (-not $st.Lost) { & $tick }
        } else {
            $X.Ui.Line("$([long][Math]::Max(0, [Math]::Floor(($cutoff - $now) / 1000))) s left before the safe-finish cut-off")
        }
    }
    # a prompt's start: drain (discarded keys logged), arm the key source, the ANSWER sound on the first prompt of the gap
    $begin = {
        param([string]$item)
        $now = $X.Now()
        $X.Poll()
        $dr = @($X.Keys.Drain($now))
        if ($dr.Count) { $X.Event("keys-discarded before $Ph/$item n=$($dr.Count) keys=$($dr -join ',')") }
        if ($st.First) {
            $st.First = $false; $res.FirstPromptMs = $now
            if ($Mode -ceq 'darkonly') { $X.Ui.Banner('answer', "RUN $runN ENDED - ONE SAFETY QUESTION", 'after your x (or n): are both panels dark now?') }
            else { $X.Ui.Banner('answer', "RUN $runN ENDED - ANSWER NOW", 'what you saw, eye by eye; the panels are off') }
            $X.Sound.Play('ANSWER', $now)
        }
        $X.Keys.Arm('p', $now)
        [pscustomobject]@{ Ms = $now; Discarded = $dr.Count }
    }
    $deadlineFor = { param([long]$from) [Math]::Min($from + [long]$PromptTimeoutSec * 1000, $cutoff) }
    # mark every remaining item NOT_ASKED (after a timeout/abort/light/stray), the layout items included
    $rest = {
        param([string[]]$items)
        foreach ($it in $items) { if (-not $res.Items.ContainsKey($it)) { $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Obs 'NOT_ASKED' -PromptMs $X.Now() } }
    }
    $safe = { param([string]$kind, [string]$why) $res.Safe = $kind; $res.SafeWhy = $why }
    $Eyes = @('left', 'right')
    $echoEye = { param([string]$eye) $eye.ToUpperInvariant() + ' EYE' }

    if ($Mode -ceq 'darkonly') {
        foreach ($e in $Eyes) { $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Obs 'ABORT' -PromptMs $X.Now() }
    } else {
        # ---- per-eye readings
        foreach ($e in $Eyes) {
            if ($null -ne $res.Safe -or $X.Stray) { break }
            $b = & $begin $e
            $dl = & $deadlineFor $b.Ms
            $answered = $false
            while (-not $answered) {
                & $countdown
                # PM rehearsal feedback: short lines; `n` is a key of the dark check only (x aborts everywhere)
                if ($Ph -ceq 'r3') {
                    $X.Ui.Line("RUN 3 - $(& $echoEye $e):  r = all red   p = partly red   u = one other colour   s = same as run 2   g = different garble   b = dark   x = abort")
                    $allowed = @('r', 'p', 'u', 's', 'g', 'b', 'x')
                } else {
                    $X.Ui.Line("RUN $runN - $(& $echoEye $e):  a = light, no pattern   b = dark   c = garbled   d = I can read the characters   x = abort")
                    $allowed = @('a', 'b', 'c', 'd', 'x')
                }
                $w = Wait-Fs3cKey -X $X -Allowed $allowed -DeadlineMs $dl -OnTick $tick -Label "$Ph/$e" -RepeatKey $st.LastKey -RepeatUntilMs (& $ru)
                & $acc $w
                if ($w.TimedOut) {
                    $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Obs 'TIMEOUT' -PromptMs $b.Ms -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e): TIMEOUT"); & $safe 'timeout' "$e reading timed out"; break
                }
                if ($w.Key -ceq 'x') { $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key 'x' -Obs 'ABORT' -PromptMs $b.Ms -AnswerMs $w.Ms -Discarded $b.Discarded
                                        $X.Ui.Line("$(& $echoEye $e): ABORT"); & $safe 'abort' "x at the $e reading"; break }
                if ($Ph -ceq 'r3') {
                    $m = $script:Fs3cReadKeys3[$w.Key]
                    $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key $w.Key -Obs $m[0] -PromptMs $b.Ms -AnswerMs $w.Ms -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e): $($m[1])"); $answered = $true; continue
                }
                if ($w.Key -cne 'd') {
                    $m = $script:Fs3cReadKeys12[$w.Key]
                    $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key $w.Key -Obs $m[0] -PromptMs $b.Ms -AnswerMs $w.Ms -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e): $($m[1])"); $answered = $true; continue
                }
                # d: the 8 characters (own 30 s timeout; Esc returns to this eye's reading prompt, whose timeout keeps running)
                $cs = $X.Now(); $cdl = & $deadlineFor $cs
                $buf = ''
                $X.Ui.Line("$(& $echoEye $e): type the 8 characters (0-9 A-F, ? for an unreadable one), Backspace to correct, Enter to finish, Esc to go back, x = abort")
                $back = $false; $cend = $null; $firstCh = $true
                while ($true) {
                    # the first character only: a repeated `d` is not taken as the character D (MINOR-2)
                    $ck = Wait-Fs3cKey -X $X -Allowed ($script:Fs3cHexKeys + @('Enter', 'Backspace', 'Esc', 'x')) -DeadlineMs $cdl -OnTick $tick -Label "$Ph/chars_$e" `
                        -RepeatKey $(if ($firstCh) { $st.LastKey } else { '' }) -RepeatUntilMs (& $ru)
                    $firstCh = $false; & $acc $ck
                    if ($ck.TimedOut) { $cend = @('-', 'TIMEOUT', $ck.Ms); break }
                    switch -CaseSensitive ($ck.Key) {
                        'Esc'       { $back = $true }
                        'x'         { $cend = @('x', 'ABORT', $ck.Ms) }
                        'Backspace' { if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1) }; $X.Ui.Line("  characters: $buf") }
                        'Enter'     { if ($buf -cmatch '^[0-9A-F?]{8}\z') { $cend = @('ok', 'READ', $ck.Ms) } else { $X.Ui.Line("  $($buf.Length) of 8 characters: keep typing (Enter needs all 8)"); $X.Event("chars-early-enter $Ph/$e len=$($buf.Length)") } }
                        default     { if ($buf.Length -lt 8) { $buf += $ck.Key.ToUpperInvariant(); $X.Ui.Line("  characters: $buf") } else { $X.Event("chars-ninth-ignored $Ph/$e key=$($ck.Key)") } }
                    }
                    if ($back -or $null -ne $cend) { break }
                }
                if ($back) {
                    $X.Ui.Line("$(& $echoEye $e): characters discarded; back to the a/b/c/d choice"); $X.Event("chars-esc $Ph/$e")
                    if ($X.Now() -ge $dl) {
                        $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Obs 'TIMEOUT' -PromptMs $b.Ms -Discarded $b.Discarded
                        $X.Ui.Line("$(& $echoEye $e): TIMEOUT"); & $safe 'timeout' "$e reading timed out (after Esc)"; break
                    }
                    continue
                }
                if ($cend[0] -ceq 'ok') {
                    $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key 'd' -Obs 'READ' -Chars $buf -PromptMs $b.Ms -AnswerMs $cend[2] -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e): READ $buf"); $answered = $true; continue
                }
                # build review MINOR-3: `d` and then no characters (a timeout or x during the entry): the eye's record
                # is READ with no characters ("READ, characters not recorded"), never a garble
                $res.Items[$e] = Add-Fs3cReading -X $X -Ph $Ph -Item $e -Key 'd' -Obs 'READ' -PromptMs $b.Ms -AnswerMs $cs -Discarded $b.Discarded
                $X.Ui.Line("$(& $echoEye $e): READ, characters not recorded")
                $ci = "chars_$e"
                $res.Items[$ci] = Add-Fs3cReading -X $X -Ph $Ph -Item $ci -Key $cend[0] -Obs $cend[1] -PromptMs $cs -AnswerMs $(if ($cend[0] -ceq '-') { -1 } else { $cend[2] })
                switch ($cend[1]) {
                    'TIMEOUT'   { $X.Ui.Line("$(& $echoEye $e) CHARACTERS: TIMEOUT"); & $safe 'timeout' "$e characters timed out" }
                    'ABORT'     { $X.Ui.Line("$(& $echoEye $e) CHARACTERS: ABORT"); & $safe 'abort' "x during the $e characters" }
                }
                break
            }
        }
    }
    # ---- dark check (after the per-eye readings; also the one question after `x` during a lit phase)
    if ($null -eq $res.Safe -and -not $X.Stray) {
        $wasFirst = $st.First
        $b = & $begin 'dark'
        $dl = & $deadlineFor $b.Ms
        # build review NIT d: the dark check has its own banner (after x it is the one safety question's banner above)
        if (-not $wasFirst) { $X.Ui.Banner('info', 'DARK CHECK - ARE BOTH PANELS DARK NOW?', 'y = dark | n = light visible | x = abort') }
        & $countdown
        $X.Ui.Line('DARK CHECK: are both panels DARK now?  y = dark | n = light visible | x = abort')
        $w = Wait-Fs3cKey -X $X -Allowed @('y', 'n', 'x') -DeadlineMs $dl -OnTick $tick -Label "$Ph/dark" -RepeatKey $st.LastKey -RepeatUntilMs (& $ru)
        & $acc $w
        if ($w.TimedOut) { $res.Items['dark'] = Add-Fs3cReading -X $X -Ph $Ph -Item 'dark' -Obs 'TIMEOUT' -PromptMs $b.Ms -Discarded $b.Discarded; $X.Ui.Line('DARK CHECK: TIMEOUT'); & $safe 'timeout' 'dark check timed out' }
        else {
            $map = @{ y = @('DARK_NOW', 'DARK'); n = @('LIGHT_NOW', 'LIGHT VISIBLE'); x = @('ABORT', 'ABORT') }
            $res.Items['dark'] = Add-Fs3cReading -X $X -Ph $Ph -Item 'dark' -Key $w.Key -Obs $map[$w.Key][0] -PromptMs $b.Ms -AnswerMs $w.Ms -Discarded $b.Discarded
            $X.Ui.Line("DARK CHECK: $($map[$w.Key][1])")
            if ($w.Key -ceq 'n') { & $safe 'light' 'dark check: light visible' }
            elseif ($w.Key -ceq 'x') { & $safe 'abort' 'x at the dark check' }
        }
    }
    # ---- layout items (run 2 only, per eye whose reading was c or d, left first; best effort)
    if ($Layout -and $Mode -ceq 'full' -and $null -eq $res.Safe -and -not $X.Stray) {
        # Q7 fallback (DESIGN 15 Q7, PM rehearsal 2026-10-12): on the run-3 path (DESIGN 5.8 rules 1-4 hold after the dark
        # check; the remaining time is not consulted) the bar counts are not asked; nothing is shown on the console (the rule
        # is control flow only)
        $q7 = ($null -ne $BarsQ7 -and [bool](& $BarsQ7 $res.Items))
        foreach ($e in $Eyes) {
            $rd = $res.Items[$e]
            if ($null -eq $rd -or ($rd.Key -cne 'c' -and $rd.Key -cne 'd')) { continue }
            $items = @("bars_$e"); if ($rd.Key -ceq 'd') { $items += "orient_$e"; $items += "tilt_$e" }
            foreach ($it in $items) {
                if ($null -ne $res.Safe -or $X.Stray) { break }
                if ($q7 -and $it -like 'bars_*') {
                    $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Obs 'NOT_ASKED' -PromptMs $X.Now()
                    $res.BarsQ7 += $it
                    $X.Event("bars-not-asked $Ph/$it (Q7 fallback: run-3 path)"); continue
                }
                if (($cutoff - $X.Now()) -lt [long]$LayoutMinSec * 1000) {
                    $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Obs 'NOT_ASKED' -PromptMs $X.Now()
                    $X.Event("layout-not-asked $Ph/$it (< $LayoutMinSec s to the cut-off)"); continue
                }
                $b = & $begin $it
                $dl = & $deadlineFor $b.Ms
                & $countdown
                if ($it -like 'bars_*') {
                    # PM rehearsal feedback: the question explains itself (no expected order is shown)
                    $X.Ui.Line("$(& $echoEye $e) BARS: next to each of the two F letters (below it when upright) there is a row of 1 to 4 bars (see the preview).")
                    $X.Ui.Line("  Press how many bars you see at the LEFT F, then at the RIGHT F (two keys, 0 = none visible).   Backspace = correct   x = abort")
                    $buf = ''; $fin = $null; $firstB = $true
                    while ($null -eq $fin) {
                        $k = Wait-Fs3cKey -X $X -Allowed @('0', '1', '2', '3', '4', 'Backspace', 'x') -DeadlineMs $dl -OnTick $tick -Label "$Ph/$it" `
                            -RepeatKey $(if ($firstB) { $st.LastKey } else { '' }) -RepeatUntilMs (& $ru)
                        $firstB = $false; & $acc $k
                        if ($k.TimedOut) { $fin = @('-', 'TIMEOUT', -1); break }
                        if ($k.Key -ceq 'x') { $fin = @('x', 'ABORT', $k.Ms); break }
                        if ($k.Key -ceq 'Backspace') { if ($buf.Length) { $buf = $buf.Substring(0, $buf.Length - 1) }; $X.Ui.Line("  bars: $buf"); continue }
                        $buf += $k.Key; $X.Ui.Line("  bars: $buf")
                        if ($buf -cmatch '^[0-4]{2}\z') { $fin = @('-', 'BARS', $k.Ms) }
                    }
                    if ($fin[1] -ceq 'BARS') {
                        $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Obs 'BARS' -Bars $buf -PromptMs $b.Ms -AnswerMs $fin[2] -Discarded $b.Discarded
                        $X.Ui.Line("$(& $echoEye $e) BARS: $($buf.Substring(0,1)) $($buf.Substring(1,1))")
                    } else {
                        $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Key $fin[0] -Obs $fin[1] -PromptMs $b.Ms -AnswerMs $fin[2] -Discarded $b.Discarded
                        $X.Ui.Line("$(& $echoEye $e) BARS: $($fin[1] -replace '_', ' ')")
                    }
                } else {
                    if ($it -like 'orient_*') { $map = $script:Fs3cOrientKeys
                        $X.Ui.Line("$(& $echoEye $e) F MARKERS: u = upright (a tilt is fine) | i = turned by a half-turn (long arm at the bottom, arms pointing left) | m = mirrored (long arm at the top, arms pointing left) | v = flipped top-bottom (long arm at the bottom, arms pointing right) | 0 = can't tell | x = abort") }
                    else { $map = $script:Fs3cTiltKeys
                        $X.Ui.Line("$(& $echoEye $e) CENTRE LINE: l = left end lower | r = right end lower | 0 = level or can't tell | x = abort") }
                    $k = Wait-Fs3cKey -X $X -Allowed (@($map.Keys) + @('x')) -DeadlineMs $dl -OnTick $tick -Label "$Ph/$it" -RepeatKey $st.LastKey -RepeatUntilMs (& $ru)
                    & $acc $k
                    if ($k.TimedOut) { $fin = @('-', 'TIMEOUT', -1, 'TIMEOUT') }
                    elseif ($k.Key -ceq 'x') { $fin = @('x', 'ABORT', $k.Ms, 'ABORT') }
                    else { $fin = @($k.Key, $map[$k.Key][0], $k.Ms, $map[$k.Key][1]) }
                    $res.Items[$it] = Add-Fs3cReading -X $X -Ph $Ph -Item $it -Key $fin[0] -Obs $fin[1] -PromptMs $b.Ms -AnswerMs $fin[2] -Discarded $b.Discarded
                    $X.Ui.Line("$(& $echoEye $e) $($it.Split('_')[0].ToUpperInvariant()): $($fin[3])")
                }
                switch ($res.Items[$it].Obs) {
                    'TIMEOUT'   { & $safe 'timeout' "$it timed out" }
                    'ABORT'     { & $safe 'abort' "x at $it" }
                }
            }
        }
    }
    if ($null -ne $res.Safe -or $X.Stray) {
        # NOT_ASKED for every core item still open, and for the layout items that would have been asked
        $rem = New-Object System.Collections.Generic.List[string]
        foreach ($it in 'left', 'right', 'dark') { $rem.Add($it) }
        if ($Layout -and $Mode -ceq 'full') {
            foreach ($e in $Eyes) {
                $rd = $res.Items[$e]
                if ($null -eq $rd -or ($rd.Key -cne 'c' -and $rd.Key -cne 'd')) { continue }
                $rem.Add("bars_$e"); if ($rd.Key -ceq 'd') { $rem.Add("orient_$e"); $rem.Add("tilt_$e") }
            }
        }
        & $rest $rem.ToArray()
        if ($X.Stray -and $null -eq $res.Safe) { & $safe 'stray' 'bytes arrived from the device after the settled prompt (the shell state changed)' }
    }
    $last = @($res.Items.Values | Where-Object { $_.AnswerMs -ge 0 } | ForEach-Object { $_.AnswerMs } | Sort-Object -Descending)
    if ($last.Count) { $res.LastAnswerMs = $last[0] }
    $X.Ui.Line("READINGS COMPLETE FOR RUN $runN")
    $X.Event("readings-complete $Ph safe=$($res.Safe)")
    [pscustomobject]$res
}

# ------------------------------------------------------------ sound check ----
# DESIGN 8.4 preflight, before BA; nothing touches the device. 1. each sound with its name, y per sound
# heard; 2. three sounds in random order without names, identified with s/e/a/f/l; 3. the key-reach test
# (each key in turn, one-handed). All must pass. A wrong key in step 3 is recorded as a miss and the same
# key is asked again; the step fails on a timeout. Returns the soundcheck.json object.
# build review MINOR-6: every key a session can ask for, incl. Enter, Backspace and the hex characters of the entry
$script:Fs3cReachKeys = @('a', 'b', 'c', 'd', 'x', 'y', 'n', 'r', 'p', 'u', 's', 'g', 'i', 'm', 'v', 'l', '0', '1', '2', '3', '4', 'Esc',
                          'e', 'f', '5', '6', '7', '8', '9', '?', 'Enter', 'Backspace')
$script:Fs3cIdKeys = [ordered]@{ s = 'START'; e = 'END'; a = 'ANSWER'; f = 'FINISH'; l = 'ALARM' }
function Invoke-Fs3cSoundCheck {
    param([Parameter(Mandatory)]$X, [Parameter(Mandatory)]$Sounds, [int]$Seed = -1, [int]$TimeoutSec = 30)
    $rng = if ($Seed -ge 0) { New-Object System.Random $Seed } else { New-Object System.Random ([BitConverter]::ToInt32([Guid]::NewGuid().ToByteArray(), 0)) }
    $r = [ordered]@{ Schema = 'frameshift.fs-soundcheck3c.v1'; StartUtc = $X.Utc($X.Now()); Named = @(); Blind = @(); Reach = @(); ReachMisses = @(); Pass = $false; Why = ''
                     Sounds = (Get-Fs3cSoundHashes $Sounds); PlayFailures = @() }
    $ok = $true
    $X.Ui.Banner('info', 'SOUND CHECK (nothing touches the device)', 'step 1 of 3: each sound is played with its name; press y if you heard it')
    foreach ($n in $Sounds.Keys) {
        $X.Keys.Drain($X.Now()) | Out-Null
        $X.Ui.Line("Playing $n ($($Sounds[$n].Shape)). Heard it? y = yes, n = no")
        $X.Sound.Play($n, $X.Now()); $X.Keys.Arm('p', $X.Now())
        $w = Wait-Fs3cKey -X $X -Allowed @('y', 'n', 'x', 'Esc') -DeadlineMs ($X.Now() + $TimeoutSec * 1000) -Label "named/$n"
        $heard = (-not $w.TimedOut -and $w.Key -ceq 'y')
        $X.Ui.Line("$($n): $(if ($heard) { 'HEARD' } elseif ($w.TimedOut) { 'TIMEOUT' } else { 'NOT HEARD' })")
        $r.Named += [ordered]@{ Sound = $n; Key = $(if ($w.TimedOut) { '-' } else { $w.Key }); Heard = $heard }
        if (-not $heard) { $ok = $false }
    }
    $X.Ui.Banner('info', 'SOUND CHECK step 2 of 3', 'three sounds without names: s = START, e = END, a = ANSWER, f = FINISH, l = ALARM')
    $names = @($Sounds.Keys)
    for ($i = 1; $i -le 3; $i++) {
        $pick = $names[$rng.Next(0, $names.Count)]
        $X.Keys.Drain($X.Now()) | Out-Null
        $X.Ui.Line("Sound $i of 3: which one?  s / e / a / f / l")
        $X.Sound.Play($pick, $X.Now()); $X.Keys.Arm('p', $X.Now())
        $w = Wait-Fs3cKey -X $X -Allowed @($script:Fs3cIdKeys.Keys) -DeadlineMs ($X.Now() + $TimeoutSec * 1000) -Label "blind/$i"
        $named = if ($w.TimedOut) { 'TIMEOUT' } else { $script:Fs3cIdKeys[$w.Key] }
        $X.Ui.Line("Sound $($i): you named $named")
        $r.Blind += [ordered]@{ N = $i; Played = $pick; Named = $named; Ok = ($named -ceq $pick) }
        if ($named -cne $pick) { $ok = $false }
    }
    $X.Ui.Banner('info', 'SOUND CHECK step 3 of 3: key reach, ONE-HANDED', 'press each key as it is asked for')
    foreach ($k in $script:Fs3cReachKeys) {
        $X.Keys.Drain($X.Now()) | Out-Null
        $X.Keys.Arm('p', $X.Now())
        $dl = $X.Now() + $TimeoutSec * 1000
        $X.Ui.Line("press: $k")
        $got = $false
        while (-not $got) {
            $w = Wait-Fs3cKey -X $X -Allowed (@($script:Fs3cReachKeys) + @('h', 'j', 'k', 'o', 'q', 't', 'w', 'z')) -DeadlineMs $dl -Label "reach/$k"
            if ($w.TimedOut) { break }
            if ($w.Key -ceq $k) { $got = $true } else { $r.ReachMisses += "$k<-$($w.Key)"; $X.Ui.Line("  that was $($w.Key); press: $k") }
        }
        $r.Reach += [ordered]@{ Key = $k; Ok = $got }
        if (-not $got) { $ok = $false; $X.Ui.Line("  $($k): TIMEOUT"); break }      # the check has failed: stop here
    }
    $r.PlayFailures = @($X.Sound.Failures)
    $r.Pass = $ok
    $r.Why = if ($ok) { 'all sounds heard and named; every key reached' } else { 'a sound was not heard or misnamed, or a key was not reached in time' }
    $r.EndUtc = $X.Utc($X.Now())
    $X.Ui.Banner($(if ($ok) { 'ended' } else { 'abort' }), $(if ($ok) { 'SOUND CHECK PASSED' } else { 'SOUND CHECK FAILED: nothing is booted' }), $r.Why)
    [pscustomobject]$r
}

if ($script:Fs3cSessionInvocation -eq '.') { return }
# ------------------------------------------------------------------ CLI -----
$ErrorActionPreference = 'Stop'
$exitCode = 70
try {
    if (-not $SoundCheck) { Write-Output 'usage: fs-session3c.ps1 -SoundCheck [-SoundCheckDir <dir>]   (the preflight sound check; nothing touches the device)'; exit 64 }
    . (Join-Path $PSScriptRoot 'fs-native.ps1')
    $snd = New-Fs3cSounds
    $ui = New-Fs3cUi -Kind console
    $xx = New-Fs3cInteract -Ui $ui -Keys (New-Fs3cConsoleKeySource) -Sound (New-Fs3cSoundSink -Kind live -Sounds $snd)
    $res = Invoke-Fs3cSoundCheck -X $xx -Sounds $snd -Seed $SoundCheckSeed
    $dir = if ($SoundCheckDir) { $SoundCheckDir } else { (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    $p = Join-Path $dir 'soundcheck.json'
    [IO.File]::WriteAllText($p, (($res | ConvertTo-Json -Depth 6) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "soundcheck.json: $p"
    $exitCode = if ($res.Pass) { 0 } else { 1 }
} catch { Write-Output ("SOUND CHECK ERROR: " + $_.Exception.Message); $exitCode = 70 }
exit $exitCode
