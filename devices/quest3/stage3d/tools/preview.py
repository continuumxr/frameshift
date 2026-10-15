#!/usr/bin/env python3
"""fs-pattern v0.7 (stage 3d) previews: a stdlib-only Python port of the C drawing code
(src/fs-pattern.c draw_pattern/draw_eye/draw_group/draw_glyph/rect/blit_eye/fill_buf, draw_solid), validated
BYTE FOR BYTE against the C renderer's PPM, then written as PNG previews. Offline only. Derived from
stage3c/tools/preview.py (v0.6, unchanged).

usage: preview.py NONCE OUTDIR PREFIX [--roll DEG] [--eyes swap|direct] [--against C_RENDER.ppm]
       preview.py --solid OUTDIR PREFIX [--against C_SOLID.ppm]      the run-3 red field
       preview.py --fref OUTDIR PREFIX                               the F reference sheet
       preview.py --whole180 NONCE [--against C_RENDER_ROLL0_SWAP.ppm]  roll 0 + eyes swap == the whole-frame 180

  --roll/--eyes  the picture options of the C render (default 21 / swap, the stage-3d run-2 values).
  --against      the PPM written by `fs-pattern render NONCE 4128 2208 FILE [roll=.. eyes=..]` with the exact
                 aarch64 binary under qemu. The port's 4128x2208 pixels must equal it exactly; otherwise
                 nothing is written and the exit code is 1.
Writes:
  pattern: <PREFIX>-scanout-4128x2208.png   the exact buffer as scanned out (each half: one eye, rotated 180
                                            degrees and pre-rotated by the roll)
           <PREFIX>-panels-1032x552.png     each PANEL in viewer orientation (the 180 degrees undone), placed
                                            LEFT EYE | RIGHT EYE: the pre-rotation is visible (left eye turned
                                            counter-clockwise, right eye clockwise)
           <PREFIX>-asseen-1032x552.png     the EXPECTED VIEW if the panels are canted as reported (J-125: left
                                            panel content appears turned clockwise by the roll, right panel
                                            counter-clockwise): the panels image with that cant applied
                                            (floating-point, nearest neighbour): upright and level. [C]: the
                                            angle and direction are the PM's report and screen_rotation 201
           <PREFIX>-mixermap-1032x552.png   the scanout at 1/4 with the four layer mixers marked (LM0..LM3
                                            boundaries at buffer x 1032/2064/3096, the bar count each mixer must
                                            carry) - annotation colours are NOT on the panel
           <PREFIX>-digits-left.png         the left eye's characters at 1:1, design orientation
  solid:   <PREFIX>-viewer-1032x552.png     the red field (every pixel R=255 G=0 B=0)
  fref:    <PREFIX>.png                     the F marker as the PM may see it, with the key to press:
                                            U upright (a tilt is fine), I half-turn (180 deg), M mirrored
                                            left-right, V flipped top-bottom (keys are typed in lower case)
Prints the SHA-256 of the pixel bytes and of every PNG.
"""
import hashlib
import math
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
C_BG, C_CROSS, C_TEXT = 0x80, 0xFF, 0xFF      # fs-pattern.c v0.7 (levels as v0.5)
ROT180 = True
W, H = 4128, 2208
# fs-pattern.c SIN_Q16 / COS_Q16 (round(65536 sin d), round(65536 cos d), d = 0..25)
SIN_Q16 = [0, 1144, 2287, 3430, 4572, 5712, 6850, 7987, 9121, 10252, 11380, 12505, 13626,
           14742, 15855, 16962, 18064, 19161, 20252, 21336, 22415, 23486, 24550, 25607, 26656, 27697]
COS_Q16 = [65536, 65526, 65496, 65446, 65376, 65287, 65177, 65048, 64898, 64729, 64540, 64332, 64104,
           63856, 63589, 63303, 62997, 62672, 62328, 61966, 61584, 61183, 60764, 60326, 59870, 59396]


def cdiv(a, b):
    """C99 integer division (truncation toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


class Eye:
    """one eye canvas (viewer coordinates), as fs-pattern.c's c->eye"""
    def __init__(self, ew, h):
        self.ew, self.h = ew, h
        self.px = bytearray([C_BG]) * (ew * h)

    def rect(self, x0, y0, x1, y1, v):
        x0 = max(x0, 0); y0 = max(y0, 0)
        x1 = min(x1, self.ew); y1 = min(y1, self.h)
        if x0 >= x1 or y0 >= y1:
            return
        row = bytes([v]) * (x1 - x0)
        for y in range(y0, y1):
            o = y * self.ew
            self.px[o + x0:o + x1] = row


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


def draw_eye(c, nonce, bars_left, bars_right, legacy):
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
    q = cdiv(ew - 2 * mx, 4) if legacy else cdiv(ew - 2 * mx, 3)
    fy = cy + arm + 3 * u if legacy else cy + 3 * u
    by = fy + 7 * u + 2 * u
    draw_group(c, cx - q, fy, by, u, bars_left)
    draw_group(c, cx + q, fy, by, u, bars_right)
    return dict(tx=tx, ty=ty, tw=tw, gh=gh, u=u)


def eye_sin(left, roll):
    s = SIN_Q16[abs(roll)]
    if roll < 0:
        s = -s
    return s if left else -s


def blit_eye(buf, w, ex0, eye, s, cs):
    """fs-pattern.c blit_eye: buffer pixel -> viewer (180) -> inverse pre-rotation, floor division"""
    ew, h = eye.ew, eye.h
    e = eye.px
    for by in range(h):
        y = h - 1 - by if ROT180 else by
        Y = 2 * y + 1 - h
        o = by * w + ex0
        if s == 0 and cs == 65536:          # the identity: the v0.6 mapping (same result, faster)
            src = e[y * ew:(y + 1) * ew]
            buf[o:o + ew] = src[::-1] if ROT180 else src
            continue
        ys, yc = Y * s, Y * cs
        for bx in range(ew):
            x = ew - 1 - bx if ROT180 else bx
            X = 2 * x + 1 - ew
            sx = (X * cs - ys + ew * 65536) // 131072
            sy = (X * s + yc + h * 65536) // 131072
            buf[o + bx] = e[sy * ew + sx] if (0 <= sx < ew and 0 <= sy < h) else C_BG


def draw_pattern(w, h, nonce, roll=21, swap=True):
    """returns (grey bytes w*h, geometry of the left eye, the two eye canvases)"""
    buf = bytearray([C_BG]) * (w * h)
    legacy = roll == 0 and not swap
    geo, eyes = None, {}
    for left in (1, 0):
        half = (1 if left else 0) ^ (0 if swap else 1)
        ex0 = w // 2 if half else 0
        ew = w - w // 2 if half else w // 2
        eye = Eye(ew, h)
        g = draw_eye(eye, nonce, 1 if left else 3, 2 if left else 4, legacy)
        if left:
            geo = g
        eyes["left" if left else "right"] = (eye, half)
        blit_eye(buf, w, ex0, eye, eye_sin(left, roll), COS_Q16[abs(roll)])
    return buf, geo, eyes


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


def rotate_small(img, w, h, deg):
    """nearest-neighbour rotation of a small grey image about its centre; + = counter-clockwise as seen"""
    th = math.radians(deg)
    co, si = math.cos(th), math.sin(th)
    out = bytearray([C_BG]) * (w * h)
    cx, cy = w / 2.0, h / 2.0
    for y in range(h):
        for x in range(w):
            dx, dy = x + 0.5 - cx, y + 0.5 - cy
            sx, sy = cx + dx * co - dy * si, cy + dx * si + dy * co     # inverse of the CCW rotation
            ix, iy = int(math.floor(sx)), int(math.floor(sy))
            if 0 <= ix < w and 0 <= iy < h:
                out[y * w + x] = img[iy * w + ix]
    return out


def pattern_main(nonce, outdir, prefix, against, roll, swap):
    assert len(nonce) == 8 and all(ch in "0123456789abcdef" for ch in nonce)
    assert -25 <= roll <= 25
    px, geo, eyes = draw_pattern(W, H, nonce, roll, swap)
    print("PORT %s roll=%d eyes=%s %dx%d grey-pixels sha256=%s" % (nonce, roll, "swap" if swap else "direct", W, H,
                                                                   hashlib.sha256(bytes(px)).hexdigest()))
    if against:
        w2, h2, rgb = read_ppm(against)
        ok = (w2, h2) == (W, H) and rgb[0::3] == bytes(px) and rgb[1::3] == bytes(px) and rgb[2::3] == bytes(px)
        print("VALIDATE port == C render (%s): %s" % (against, "IDENTICAL" if ok else "DIFFERENT"))
        if not ok:
            sys.exit(1)
    lit = sum(1 for v in px if v > C_BG)
    print("STATS white_ppm=%d max=0x%02x mean_x1000=%d levels=%s" % (lit * 1000000 // (W * H), max(px), sum(px) * 1000 // (W * H),
          ",".join("0x%02x" % v for v in sorted(set(px)))))
    rows = [px[y * W:(y + 1) * W] for y in range(H)]
    out = {}
    out["scanout"] = png("%s/%s-scanout-4128x2208.png" % (outdir, prefix), W, H, rows)
    s = 4
    small = [rows[y][0::s] for y in range(0, H, s)]
    half = W // 2 // s
    sh = H // s
    # panels: each half's 180 undone, placed LEFT EYE | RIGHT EYE
    pan = []
    for r in reversed(small):
        h0, h1 = bytes(reversed(r[:half])), bytes(reversed(r[half:]))
        pan.append(h1 + h0 if swap else h0 + h1)
    out["panels"] = png("%s/%s-panels-1032x552.png" % (outdir, prefix), W // s, sh, pan)
    # as seen: the reported cant applied to each panel image (left eye turned clockwise by roll, right eye counter-clockwise)
    left = bytearray(b"".join(r[:half] for r in pan))
    right = bytearray(b"".join(r[half:] for r in pan))
    lv = rotate_small(left, half, sh, -roll)
    rv = rotate_small(right, half, sh, roll)
    seen = [bytes(lv[y * half:(y + 1) * half]) + bytes(rv[y * half:(y + 1) * half]) for y in range(sh)]
    out["asseen"] = png("%s/%s-asseen-1032x552.png" % (outdir, prefix), W // s, sh, seen)
    # mixer map: the scanout at 1/4 in RGB, boundaries in cyan, LMn and the bar count in yellow
    mm = [bytearray(b"".join(bytes((v, v, v)) for v in r)) for r in small]
    for bx in (1032 // s, 2064 // s, 3096 // s):
        for y in range(len(mm)):
            mm[y][bx * 3:bx * 3 + 3] = b"\x00\xc0\xff"
            mm[y][(bx - 1) * 3:(bx - 1) * 3 + 3] = b"\x00\xc0\xff"
    lmb = ((0, 4), (1, 3), (2, 2), (3, 1)) if swap else ((0, 2), (1, 1), (2, 4), (3, 3))
    for m, k in lmb:
        x0 = m * 1032 // s + 12
        stamp(mm, x0, 10, LETTERS["L"], 3, (255, 220, 0))
        stamp(mm, x0 + 18, 10, LETTERS["M"], 3, (255, 220, 0))
        stamp(mm, x0 + 36, 10, GLYPH[m], 3, (255, 220, 0))
        stamp(mm, x0 + 66, 10, GLYPH[k], 3, (255, 120, 0))
    out["mixermap"] = png("%s/%s-mixermap-1032x552.png" % (outdir, prefix), W // s, sh, mm, rgb=True)
    eye = eyes["left"][0]
    u = geo["u"]
    x0, y0, x1, y1 = geo["tx"] - 2 * u, geo["ty"] - 2 * u, geo["tx"] + geo["tw"] + 2 * u, geo["ty"] + geo["gh"] + 3 * u
    crop = [bytes(eye.px[y * eye.ew + x] for x in range(x0, x1)) for y in range(y0, y1)]
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


def whole180_main(nonce, against):
    """roll 0, eyes swap: the per-half 180 degrees of the swapped halves IS one 180-degree rotation of the whole
    4128-wide frame [left-eye design | right-eye design] (the 180-degree mount of the whole panel assembly).
    Built here the second way and compared with draw_pattern(roll 0, swap) and, if given, the C render."""
    px, _, _ = draw_pattern(W, H, nonce, 0, True)
    ewl, ewr = W - W // 2, W // 2                       # the left eye gets half 1 (width W - W/2), the right eye half 0
    le, re_ = Eye(ewl, H), Eye(ewr, H)
    draw_eye(le, nonce, 1, 2, False)
    draw_eye(re_, nonce, 3, 4, False)
    design = bytearray(W * H)                            # the viewer frame: left eye | right eye
    for y in range(H):
        design[y * W:y * W + ewl] = le.px[y * ewl:(y + 1) * ewl]
        design[y * W + ewl:(y + 1) * W] = re_.px[y * ewr:(y + 1) * ewr]
    whole = bytes(reversed(design))                      # (x, y) -> (W-1-x, H-1-y) over the whole frame
    ok = whole == bytes(px)
    print("WHOLE180 roll=0 eyes=swap: draw_pattern == whole-frame 180 of [left eye | right eye]: %s" % ("IDENTICAL" if ok else "DIFFERENT"))
    if against:
        w2, h2, rgb = read_ppm(against)
        okc = (w2, h2) == (W, H) and rgb[0::3] == whole
        print("WHOLE180 C render (%s) == whole-frame 180: %s" % (against, "IDENTICAL" if okc else "DIFFERENT"))
        ok = ok and okc
    sys.exit(0 if ok else 1)


def main():
    a = sys.argv[1:]
    if a[0] == "--whole180":
        whole180_main(a[1], a[a.index("--against") + 1] if "--against" in a else None)
    against = a[a.index("--against") + 1] if "--against" in a else None
    roll = int(a[a.index("--roll") + 1]) if "--roll" in a else 21
    swap = (a[a.index("--eyes") + 1] if "--eyes" in a else "swap") == "swap"
    if a[0] == "--solid":
        solid_main(a[1], a[2], against)
    elif a[0] == "--fref":
        fref_main(a[1], a[2])
    else:
        pattern_main(a[0], a[1], a[2], against, roll, swap)


main()
