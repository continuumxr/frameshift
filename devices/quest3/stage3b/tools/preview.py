#!/usr/bin/env python3
"""fs-pattern v0.5 (stage 3b) preview: a stdlib-only Python port of the C drawing
code (src/fs-pattern.c draw_pattern/draw_eye/rect/fill_buf), validated BYTE FOR BYTE
against the C renderer's PPM, then written as PNG previews. Offline only.

usage: preview.py NONCE OUTDIR PREFIX [--against C_RENDER.ppm]

  --against   the PPM written by `fs-pattern render NONCE 4128 2208 FILE` (the exact
              aarch64 binary under qemu). The port's 4128x2208 pixel bytes must equal
              it exactly; otherwise nothing is written and the exit code is 1.
Writes (8-bit grey PNG, own zlib encoder):
  <PREFIX>-scanout-4128x2208.png   the exact buffer as scanned out (each half rotated 180)
  <PREFIX>-viewer-1032x552.png     what each eye should see (rotation undone), 1/4 scale
  <PREFIX>-digits-left.png         the left-half characters at 1:1, viewer orientation
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
C_BG, C_FRAME, C_CROSS, C_TEXT = 0x80, 0xFF, 0xFF, 0xFF      # fs-pattern.c v0.5
ROT180 = True


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


def draw_eye(c, nonce, link):
    ew, h = c.ew, c.h
    cx, cy = cdiv(ew, 2), cdiv(h, 2)
    u = cdiv(cdiv(ew, 47), 2)
    u = max(u, 2)
    bi, bt = cdiv(ew, 86), cdiv(ew, 258)
    bi = max(bi, 4); bt = max(bt, 2)
    arm, ct = cdiv(h, 12), bt
    c.rect(bi, bi, ew - bi, bi + bt, C_FRAME)
    c.rect(bi, h - bi - bt, ew - bi, h - bi, C_FRAME)
    c.rect(bi, bi, bi + bt, h - bi, C_FRAME)
    c.rect(ew - bi - bt, bi, ew - bi, h - bi, C_FRAME)
    c.rect(bi + bt + u * 2, bi + bt + u * 2, bi + bt + u * 8, bi + bt + u * 8, C_FRAME)
    c.rect(cx - arm, cy - cdiv(ct, 2), cx + arm, cy - cdiv(ct, 2) + ct, C_CROSS)
    c.rect(cx - cdiv(ct, 2), cy - arm, cx - cdiv(ct, 2) + ct, cy + arm, C_CROSS)
    adv, tw, gh = 6 * u, 8 * 6 * u - u, 7 * u
    tx, ty = cx - cdiv(tw, 2), cy - arm - 3 * u - gh - 2 * u
    for i in range(8):
        g = "0123456789abcdef".find(nonce[i])
        if g < 0:
            continue
        for r in range(7):
            for col in range(5):
                if GLYPH[g][r] & (0x10 >> col):
                    c.rect(tx + i * adv + col * u, ty + r * u, tx + i * adv + (col + 1) * u, ty + (r + 1) * u, C_TEXT)
    c.rect(tx, ty + gh + u, tx + tw, ty + gh + u + cdiv(u, 2) + 1, C_TEXT)
    bw, bh, gap, by = 2 * u, 8 * u, 2 * u, cy + arm + 3 * u
    total = link * bw + (link - 1) * gap
    bx = cx - cdiv(total, 2)
    for i in range(link):
        c.rect(bx + i * (bw + gap), by, bx + i * (bw + gap) + bw, by + bh, C_CROSS)
    return dict(tx=tx, ty=ty, tw=tw, gh=gh, u=u)


def draw_pattern(w, h, nonce):
    c = Canvas(w, h)
    c.ex0, c.ew = 0, w // 2
    geo = draw_eye(c, nonce, 1)
    c.ex0, c.ew = w // 2, w - w // 2
    draw_eye(c, nonce, 2)
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


def png_grey(path, w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
    return hashlib.sha256(data).hexdigest()


def main():
    nonce, outdir, prefix = sys.argv[1:4]
    against = sys.argv[sys.argv.index("--against") + 1] if "--against" in sys.argv else None
    assert len(nonce) == 8 and all(ch in "0123456789abcdef" for ch in nonce)
    W, H = 4128, 2208
    c, geo = draw_pattern(W, H, nonce)
    pix_sha = hashlib.sha256(bytes(c.px)).hexdigest()
    print("PORT %s %dx%d grey-pixels sha256=%s" % (nonce, W, H, pix_sha))
    if against:
        w2, h2, rgb = read_ppm(against)
        ok = (w2, h2) == (W, H) and rgb[0::3] == bytes(c.px) and rgb[1::3] == bytes(c.px) and rgb[2::3] == bytes(c.px)
        print("VALIDATE port == C render (%s): %s" % (against, "IDENTICAL" if ok else "DIFFERENT"))
        if not ok:
            sys.exit(1)
    lit = sum(1 for v in c.px if v > C_BG)
    print("STATS lit_ppm=%d max=0x%02x mean_x1000=%d levels=%s" % (lit * 1000000 // (W * H), max(c.px), sum(c.px) * 1000 // (W * H),
          ",".join("0x%02x" % v for v in sorted(set(c.px)))))
    rows = [c.px[y * W:(y + 1) * W] for y in range(H)]
    out = {}
    out["scanout"] = png_grey("%s/%s-scanout-4128x2208.png" % (outdir, prefix), W, H, rows)
    s = 4
    small = [rows[y][0::s] for y in range(0, H, s)]
    half = W // 2 // s
    viewer = []
    for r in reversed(small):          # rotate each half 180 deg back: the eye's view
        viewer.append(bytes(reversed(r[:half])) + bytes(reversed(r[half:])))
    out["viewer"] = png_grey("%s/%s-viewer-1032x552.png" % (outdir, prefix), W // s, H // s, viewer)
    ew, u = W // 2, geo["u"]
    x0, y0, x1, y1 = geo["tx"] - 2 * u, geo["ty"] - 2 * u, geo["tx"] + geo["tw"] + 2 * u, geo["ty"] + geo["gh"] + 3 * u
    crop = []
    for y in range(y0, y1):            # viewer (y, x) = buffer (H-1-y, ew-1-x) in the left half
        line = rows[H - 1 - y]
        crop.append(bytes(line[ew - 1 - x] for x in range(x0, x1)))
    out["digits"] = png_grey("%s/%s-digits-left.png" % (outdir, prefix), x1 - x0, y1 - y0, crop)
    for k, v in out.items():
        print("PNG %s sha256=%s" % (k, v))


main()
