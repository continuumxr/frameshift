#!/usr/bin/env python3
"""fs-pattern v0.6 (stage 3c) previews: a stdlib-only Python port of the C drawing code
(src/fs-pattern.c draw_pattern/draw_eye/draw_group/draw_glyph/rect/fill_buf, draw_solid), validated
BYTE FOR BYTE against the C renderer's PPM, then written as PNG previews. Offline only.

usage: preview.py NONCE OUTDIR PREFIX [--against C_RENDER.ppm]       the v0.6 pattern
       preview.py --solid OUTDIR PREFIX [--against C_SOLID.ppm]      the run-3 red field
       preview.py --fref OUTDIR PREFIX                               the F reference sheet

  --against   the PPM written by `fs-pattern render NONCE 4128 2208 FILE` (or render-solid) with the
              exact aarch64 binary under qemu. The port's 4128x2208 pixels must equal it exactly;
              otherwise nothing is written and the exit code is 1.
Writes:
  pattern: <PREFIX>-viewer-1032x552.png     what each eye should see (rotation undone), 1/4 scale, true levels
           <PREFIX>-scanout-4128x2208.png   the exact buffer as scanned out (each half rotated 180)
           <PREFIX>-mixermap-1032x552.png   the scanout at 1/4 with the four layer mixers marked
                                            (LM0..LM3 boundaries at buffer x 1032/2064/3096, the bar count
                                            each mixer must carry) - annotation colours are NOT on the panel
           <PREFIX>-digits-left.png         the left-half characters at 1:1, viewer orientation
  solid:   <PREFIX>-viewer-1032x552.png     the red field (every pixel R=255 G=0 B=0)
  fref:    <PREFIX>.png                     the F marker as the PM may see it, with the key to press:
                                            U upright (a tilt is fine), I half-turn (180 deg), M mirrored
                                            left-right, V flipped top-bottom (keys are typed in lower case)
Prints the SHA-256 of the pixel bytes and of every PNG.
"""
import hashlib
import struct
import sys
import zlib

GLYPH = [
    [0x0e,0x11,0x13,0x15,0x19,0x11,0x0e], [0x04,0x0c,0x04,0x04,0x04,0x04,0x0e],
    [0x0e,0x11,0x01,0x02,0x04,0x08,0x1f], [0x1f,0x02,0x04,0x02,0x01,0x11,0x0e],
    [0x02,0x06,0x0a,0x12,0x1f,0x02,0x02], [0x1f,0x10,0x1e,0x01,0x01,0x11,0x0e],
    [0x06,0x08,0x10,0x1e,0x11,0x11,0x0e], [0x1f,0x01,0x02,0x04,0x08,0x08,0x08],
    [0x0e,0x11,0x11,0x0e,0x11,0x11,0x0e], [0x0e,0x11,0x11,0x0f,0x01,0x02,0x0c],
    [0x0e,0x11,0x11,0x1f,0x11,0x11,0x11], [0x1e,0x11,0x11,0x1e,0x11,0x11,0x1e],
    [0x0e,0x11,0x10,0x10,0x10,0x11,0x0e], [0x1e,0x11,0x11,0x11,0x11,0x11,0x1e],
    [0x1f,0x10,0x10,0x1e,0x10,0x10,0x1f], [0x1f,0x10,0x10,0x1e,0x10,0x10,0x10],
]
LETTERS = {"L": [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f], "M": [0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11],
           "U": [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e], "I": [0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e],
           "V": [0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04]}
C_BG, C_CROSS, C_TEXT = 0x80, 0xFF, 0xFF      # fs-pattern.c v0.6 (levels as v0.5)
ROT180 = True
W, H = 4128, 2208


def cdiv(a, b):
    """C99 integer division (truncation toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = bytearray([C_BG]) * (w * h)        # one grey byte per pixel
        self.ex0 = 0
        self.ew = 0

    def fill(self, x0, y0, x1, y1, v):
        x1 = min(x1, self.w); y1 = min(y1, self.h)
        if x0 >= x1:
            return
        row = bytes([v]) * (x1 - x0)
        for y in range(y0, y1):
            o = y * self.w
            self.px[o + x0:o + x1] = row

    def rect(self, x0, y0, x1, y1, v):
        x0 = max(x0, 0); y0 = max(y0, 0)
        x1 = min(x1, self.ew); y1 = min(y1, self.h)
        if x0 >= x1 or y0 >= y1:
            return
        if ROT180:
            bx0, bx1, by0, by1 = self.ew - x1, self.ew - x0, self.h - y1, self.h - y0
        else:
            bx0, bx1, by0, by1 = x0, x1, y0, y1
        self.fill(self.ex0 + bx0, by0, self.ex0 + bx1, by1, v)


def draw_glyph(c, g, x, y, u):
    for r in range(7):
        for col in range(5):
            if GLYPH[g][r] & (0x10 >> col):
                c.rect(x + col * u, y + r * u, x + (col + 1) * u, y + (r + 1) * u, C_TEXT)


def draw_group(c, gx, fy, by, u, k):
    draw_glyph(c, 15, gx - cdiv(5 * u, 2), fy, u)
    bw, bh, gap = 2 * u, 8 * u, 2 * u
    total = k * bw + (k - 1) * gap
    bx = gx - cdiv(total, 2)
    for i in range(k):
        c.rect(bx + i * (bw + gap), by, bx + i * (bw + gap) + bw, by + bh, C_CROSS)


def draw_eye(c, nonce, bars_left, bars_right):
    ew, h = c.ew, c.h
    cx, cy = cdiv(ew, 2), cdiv(h, 2)
    u = max(cdiv(cdiv(ew, 47), 2), 2)
    bt = max(cdiv(ew, 258), 2)
    arm, ct = cdiv(h, 12), bt
    mx = cdiv(ew * 480, 2064)
    c.rect(mx, cy - cdiv(ct, 2), ew - mx, cy - cdiv(ct, 2) + ct, C_CROSS)
    c.rect(cx - cdiv(ct, 2), cy - arm, cx - cdiv(ct, 2) + ct, cy + arm, C_CROSS)
    adv, tw, gh = 6 * u, 8 * 6 * u - u, 7 * u
    tx, ty = cx - cdiv(tw, 2), cy - arm - 3 * u - gh - 2 * u
    for i in range(8):
        g = "0123456789abcdef".find(nonce[i])
        if g >= 0:
            draw_glyph(c, g, tx + i * adv, ty, u)
    c.rect(tx, ty + gh + u, tx + tw, ty + gh + u + cdiv(u, 2) + 1, C_TEXT)
    q = cdiv(ew - 2 * mx, 4)
    fy = cy + arm + 3 * u
    by = fy + 7 * u + 2 * u
    draw_group(c, cx - q, fy, by, u, bars_left)
    draw_group(c, cx + q, fy, by, u, bars_right)
    return dict(tx=tx, ty=ty, tw=tw, gh=gh, u=u)


def draw_pattern(w, h, nonce):
    c = Canvas(w, h)
    c.ex0, c.ew = 0, w // 2
    geo = draw_eye(c, nonce, 1, 2)
    c.ex0, c.ew = w // 2, w - w // 2
    draw_eye(c, nonce, 3, 4)
    return c, geo


def read_ppm(path):
    d = open(path, "rb").read()
    parts, pos = [], 0
    while len(parts) < 4:
        while d[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not d[end:end + 1].isspace():
            end += 1
        parts.append(d[pos:end]); pos = end
    pos += 1
    assert parts[0] == b"P6" and parts[3] == b"255"
    return int(parts[1]), int(parts[2]), d[pos:]


def png(path, w, h, rows, rgb=False):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2 if rgb else 0, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
    return hashlib.sha256(data).hexdigest()


def stamp(rows, x, y, bits_rows, cell, rgb):
    """draw a 5x7 bitmap into RGB rows (bytearrays) at (x, y), cell px per bit"""
    for r, b in enumerate(bits_rows):
        for col in range(5):
            if b & (0x10 >> col):
                for yy in range(y + r * cell, y + (r + 1) * cell):
                    for xx in range(x + col * cell, x + (col + 1) * cell):
                        if 0 <= yy < len(rows) and 0 <= xx * 3 < len(rows[yy]):
                            rows[yy][xx * 3:xx * 3 + 3] = bytes(rgb)


def pattern_main(nonce, outdir, prefix, against):
    assert len(nonce) == 8 and all(ch in "0123456789abcdef" for ch in nonce)
    c, geo = draw_pattern(W, H, nonce)
    print("PORT %s %dx%d grey-pixels sha256=%s" % (nonce, W, H, hashlib.sha256(bytes(c.px)).hexdigest()))
    if against:
        w2, h2, rgb = read_ppm(against)
        ok = (w2, h2) == (W, H) and rgb[0::3] == bytes(c.px) and rgb[1::3] == bytes(c.px) and rgb[2::3] == bytes(c.px)
        print("VALIDATE port == C render (%s): %s" % (against, "IDENTICAL" if ok else "DIFFERENT"))
        if not ok:
            sys.exit(1)
    lit = sum(1 for v in c.px if v > C_BG)
    print("STATS white_ppm=%d max=0x%02x mean_x1000=%d levels=%s" % (lit * 1000000 // (W * H), max(c.px), sum(c.px) * 1000 // (W * H),
          ",".join("0x%02x" % v for v in sorted(set(c.px)))))
    rows = [c.px[y * W:(y + 1) * W] for y in range(H)]
    out = {}
    out["scanout"] = png("%s/%s-scanout-4128x2208.png" % (outdir, prefix), W, H, rows)
    s = 4
    small = [rows[y][0::s] for y in range(0, H, s)]
    half = W // 2 // s
    viewer = [bytes(reversed(r[:half])) + bytes(reversed(r[half:])) for r in reversed(small)]
    out["viewer"] = png("%s/%s-viewer-1032x552.png" % (outdir, prefix), W // s, H // s, viewer)
    # mixer map: the scanout at 1/4 in RGB, boundaries in cyan, LMn and the bar count in yellow
    mm = [bytearray(b"".join(bytes((v, v, v)) for v in r)) for r in small]
    for bx in (1032 // s, 2064 // s, 3096 // s):
        for y in range(len(mm)):
            mm[y][bx * 3:bx * 3 + 3] = b"\x00\xc0\xff"
            mm[y][(bx - 1) * 3:(bx - 1) * 3 + 3] = b"\x00\xc0\xff"
    for m, k in ((0, 2), (1, 1), (2, 4), (3, 3)):
        x0 = m * 1032 // s + 12
        stamp(mm, x0, 10, LETTERS["L"], 3, (255, 220, 0))
        stamp(mm, x0 + 18, 10, LETTERS["M"], 3, (255, 220, 0))
        stamp(mm, x0 + 36, 10, GLYPH[m], 3, (255, 220, 0))
        stamp(mm, x0 + 66, 10, GLYPH[k], 3, (255, 120, 0))
    out["mixermap"] = png("%s/%s-mixermap-1032x552.png" % (outdir, prefix), W // s, H // s, mm, rgb=True)
    ew, u = W // 2, geo["u"]
    x0, y0, x1, y1 = geo["tx"] - 2 * u, geo["ty"] - 2 * u, geo["tx"] + geo["tw"] + 2 * u, geo["ty"] + geo["gh"] + 3 * u
    crop = [bytes(rows[H - 1 - y][ew - 1 - x] for x in range(x0, x1)) for y in range(y0, y1)]
    out["digits"] = png("%s/%s-digits-left.png" % (outdir, prefix), x1 - x0, y1 - y0, crop)
    for k, v in out.items():
        print("PNG %s sha256=%s" % (k, v))


def solid_main(outdir, prefix, against):
    px = b"\xff\x00\x00" * (W * H)
    print("PORT solid %dx%d rgb sha256=%s" % (W, H, hashlib.sha256(px).hexdigest()))
    if against:
        w2, h2, rgb = read_ppm(against)
        ok = (w2, h2) == (W, H) and rgb == px
        print("VALIDATE port == C render-solid (%s): %s" % (against, "IDENTICAL" if ok else "DIFFERENT"))
        if not ok:
            sys.exit(1)
    rows = [b"\xff\x00\x00" * (W // 4) for _ in range(H // 4)]
    print("PNG viewer sha256=%s" % png("%s/%s-viewer-1032x552.png" % (outdir, prefix), W // 4, H // 4, rows, rgb=True))


def fref_main(outdir, prefix):
    """four panels (grey field, white F at the panel's cell u = 21 / 2 for a readable size), the key below"""
    F = GLYPH[15]
    var = [("U", F), ("I", [int(f"{b:05b}"[::-1], 2) for b in F[::-1]]),
           ("M", [int(f"{b:05b}"[::-1], 2) for b in F]), ("V", F[::-1])]
    cell, pw, ph = 12, 120, 170
    rows = [bytearray(b"\x80\x80\x80" * (pw * 4)) for _ in range(ph)]
    for i, (key, bits) in enumerate(var):
        x0 = i * pw + (pw - 5 * cell) // 2
        stamp(rows, x0, 12, bits, cell, (255, 255, 255))
        stamp(rows, i * pw + (pw - 5 * 4) // 2, 12 + 7 * cell + 14, LETTERS[key], 4, (255, 220, 0))
        for y in range(ph):
            rows[y][(i * pw) * 3:(i * pw) * 3 + 3] = b"\x00\x00\x00"
    print("FREF keys u (upright), i (half-turn), m (mirrored left-right), v (flipped top-bottom)")
    print("PNG fref sha256=%s" % png("%s/%s.png" % (outdir, prefix), pw * 4, ph, rows, rgb=True))


def main():
    a = sys.argv[1:]
    against = a[a.index("--against") + 1] if "--against" in a else None
    if a[0] == "--solid":
        solid_main(a[1], a[2], against)
    elif a[0] == "--fref":
        fref_main(a[1], a[2])
    else:
        pattern_main(a[0], a[1], a[2], against)


main()
