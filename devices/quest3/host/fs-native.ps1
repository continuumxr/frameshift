# FrameShift host helpers that need 64-bit wrap-around arithmetic or speed
# (Windows PowerShell 5.1). Compiled once per session with Add-Type from the
# C# source below (the .NET Framework compiler that ships with Windows; no
# external module, no download).
#
#   [FsHostNative]::Blake2b512([byte[]])  -> byte[64]   (RFC 7693, unkeyed, 64-byte digest)
#   [FsHostNative]::DiffIndices([byte[]], [byte[]]) -> int[] (equal-length inputs)
#   [FsHostNative]::Hex([byte[]]) -> lowercase hex string
#   [FsHostNative]::FlushWithTimeout(Stream, ms) / CloseWithTimeout(SerialPort, ms) -> bool
#       (live port only: a CDC-ACM port whose device vanished can block Flush/Close
#       indefinitely; the call runs on a background thread and is abandoned after ms)
#   [FsHostNative]::SelfTestTimeout() -> bool (fixture: a 5 s sleep is abandoned at 100 ms)
#   ConvertTo-FsPrintable <string>: every character outside [ -~] as \xNN (\uNNNN above 0xFF),
#       for any device-derived text that reaches the console (review SHOULD-FIX 4)
#
# BLAKE2b is needed by the outcome classifier (OUTCOMES.md §5 b2chal: the host
# computes BLAKE2b-512("<nonce>:<challenge>") independently). .NET Framework
# has no BLAKE2. Checked in test-host2.ps1 section N against the RFC 7693
# Appendix A vector ("abc"), the empty-input KAT that OUTCOMES §5 pins, and
# Python hashlib on several inputs (block-boundary lengths included).
Set-StrictMode -Version 2.0

if (-not ('FsHostNative' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
public static class FsHostNative {
    static readonly ulong[] IV = {
        0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL, 0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL,
        0x510e527fade682d1UL, 0x9b05688c2b3e6c1fUL, 0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL };
    static readonly int[][] SIGMA = {
        new int[] { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
        new int[] {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 },
        new int[] {11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 },
        new int[] { 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 },
        new int[] { 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 },
        new int[] { 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 },
        new int[] {12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11 },
        new int[] {13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10 },
        new int[] { 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5 },
        new int[] {10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0 } };

    static ulong Rotr(ulong x, int n) { return (x >> n) | (x << (64 - n)); }
    static ulong Le64(byte[] b, int o) {
        ulong r = 0;
        for (int k = 7; k >= 0; k--) r = (r << 8) | b[o + k];
        return r;
    }
    static void G(ulong[] v, int a, int b, int c, int d, ulong x, ulong y) {
        unchecked {
            v[a] = v[a] + v[b] + x; v[d] = Rotr(v[d] ^ v[a], 32);
            v[c] = v[c] + v[d];     v[b] = Rotr(v[b] ^ v[c], 24);
            v[a] = v[a] + v[b] + y; v[d] = Rotr(v[d] ^ v[a], 16);
            v[c] = v[c] + v[d];     v[b] = Rotr(v[b] ^ v[c], 63);
        }
    }
    static void Compress(ulong[] h, byte[] block, ulong t, bool last) {
        ulong[] m = new ulong[16];
        for (int i = 0; i < 16; i++) m[i] = Le64(block, i * 8);
        ulong[] v = new ulong[16];
        for (int i = 0; i < 8; i++) { v[i] = h[i]; v[i + 8] = IV[i]; }
        v[12] ^= t;                 // low 64 bits of the byte counter (inputs here are < 2^64 bytes)
        if (last) v[14] = ~v[14];
        for (int r = 0; r < 12; r++) {
            int[] s = SIGMA[r % 10];
            G(v, 0, 4,  8, 12, m[s[ 0]], m[s[ 1]]);
            G(v, 1, 5,  9, 13, m[s[ 2]], m[s[ 3]]);
            G(v, 2, 6, 10, 14, m[s[ 4]], m[s[ 5]]);
            G(v, 3, 7, 11, 15, m[s[ 6]], m[s[ 7]]);
            G(v, 0, 5, 10, 15, m[s[ 8]], m[s[ 9]]);
            G(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
            G(v, 2, 7,  8, 13, m[s[12]], m[s[13]]);
            G(v, 3, 4,  9, 14, m[s[14]], m[s[15]]);
        }
        for (int i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
    }
    public static byte[] Blake2b512(byte[] data) {
        if (data == null) data = new byte[0];
        ulong[] h = (ulong[])IV.Clone();
        h[0] ^= 0x01010000UL ^ 64UL;            // depth 1, fanout 1, key length 0, digest length 64
        byte[] block = new byte[128];
        int off = 0; ulong t = 0;
        while (data.Length - off > 128) {
            Array.Copy(data, off, block, 0, 128);
            t += 128; Compress(h, block, t, false); off += 128;
        }
        int rem = data.Length - off;
        Array.Clear(block, 0, 128);
        Array.Copy(data, off, block, 0, rem);
        t += (ulong)rem; Compress(h, block, t, true);
        byte[] outb = new byte[64];
        for (int i = 0; i < 8; i++) for (int k = 0; k < 8; k++) outb[i * 8 + k] = (byte)(h[i] >> (8 * k));
        return outb;
    }
    public static int[] DiffIndices(byte[] a, byte[] b) {
        if (a.Length != b.Length) throw new ArgumentException("lengths differ");
        System.Collections.Generic.List<int> d = new System.Collections.Generic.List<int>();
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) d.Add(i);
        return d.ToArray();
    }
    static bool RunWithTimeout(Action a, int ms) {
        Exception err = null;
        System.Threading.Thread t = new System.Threading.Thread(() => { try { a(); } catch (Exception e) { err = e; } });
        t.IsBackground = true;
        t.Start();
        if (!t.Join(ms)) return false;
        if (err != null) throw new InvalidOperationException(err.Message, err);
        return true;
    }
    public static bool FlushWithTimeout(System.IO.Stream s, int ms) { return RunWithTimeout(() => s.Flush(), ms); }
    public static bool CloseWithTimeout(System.IO.Ports.SerialPort p, int ms) {
        return RunWithTimeout(() => { try { if (p.IsOpen) p.Close(); } finally { p.Dispose(); } }, ms);
    }
    public static bool SelfTestTimeout() {
        bool slowAbandoned = !RunWithTimeout(() => System.Threading.Thread.Sleep(5000), 100);
        bool fastCompletes = RunWithTimeout(() => { }, 2000);
        return slowAbandoned && fastCompletes;
    }
    public static string Printable(string s) {
        if (s == null) return null;
        System.Text.StringBuilder sb = new System.Text.StringBuilder(s.Length);
        foreach (char c in s) {
            if (c >= 0x20 && c <= 0x7e) sb.Append(c);
            else if (c <= 0xff) sb.Append("\\x").Append(((int)c).ToString("x2"));
            else sb.Append("\\u").Append(((int)c).ToString("x4"));
        }
        return sb.ToString();
    }
    public static string Hex(byte[] b) {
        System.Text.StringBuilder sb = new System.Text.StringBuilder(b.Length * 2);
        foreach (byte x in b) sb.Append(x.ToString("x2"));
        return sb.ToString();
    }
}
'@
}

function ConvertTo-FsPrintable { param([AllowNull()][AllowEmptyString()][string]$S) [FsHostNative]::Printable($S) }
function Get-FsBlake2bHex { param([byte[]]$Bytes) [FsHostNative]::Hex([FsHostNative]::Blake2b512($Bytes)) }
function Get-FsSha256Hex {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [FsHostNative]::Hex($sha.ComputeHash($Bytes)) } finally { $sha.Dispose() }
}
