#!/usr/bin/env python3
"""Check an fs-pattern render (PPM) and write PNG previews. Offline only.

usage: check_render.py IMAGE.ppm NONCE OUTDIR PREFIX

Independent of the C code: re-derives the layout from the same published
rules (README "The image"), reads the digits back out of the pixels in BOTH
buffer halves, and checks brightness limits, link bars and the orientation
square. Writes:
  <PREFIX>-scanout.png   whole buffer as scanned out (downscaled 1/4)
  <PREFIX>-viewer.png    each half rotated 180 deg back = what the eye should see
                         if the DT orientation (180) is right (downscaled 1/4)
  <PREFIX>-digits.png    1:1 crop of the left-half digits, viewer orientation
Prints one "CHECK <name> PASS|FAIL detail" line per check; exit 1 on any FAIL.
"""
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
C_BG, C_FRAME, C_CROSS, C_TEXT = 0x10, 0x60, 0x70, 0x90

fails = 0
def check(name, ok, detail=""):
    global fails
    print(f"CHECK {name} {'PASS' if ok else 'FAIL'} {detail}".rstrip())
    if not ok:
        fails += 1

def read_ppm(path):
    d = open(path, "rb").read()
    parts, pos = [], 0
    while len(parts) < 4:
        while d[pos:pos+1].isspace():
            pos += 1
        end = pos
        while not d[end:end+1].isspace():
            end += 1
        parts.append(d[pos:end]); pos = end
    pos += 1
    assert parts[0] == b"P6" and parts[3] == b"255", "not a P6/255 PPM"
    return int(parts[1]), int(parts[2]), d[pos:]

def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))

def main():
    ppm, nonce, outdir, prefix = sys.argv[1:5]
    W, H, px = read_ppm(ppm)
    check("size", len(px) == W * H * 3, f"{W}x{H}")
    stride = W * 3
    R = px[0::3]                        # red channel; image is grey
    check("grey", px[1::3] == R and px[2::3] == R, "R=G=B everywhere")
    hist = [0] * 256
    for v in set(R):
        hist[v] = R.count(v)
    levels = sorted(v for v in range(256) if hist[v])
    check("levels", set(levels) <= {C_BG, C_FRAME, C_CROSS, C_TEXT},
          "levels=" + ",".join(f"0x{v:02x}" for v in levels))
    check("no_white", max(levels) <= 0x90, f"max=0x{max(levels):02x}")
    lit = sum(hist[v] for v in levels if v != C_BG) / (W * H)
    mean = sum(v * hist[v] for v in levels) / (W * H)
    check("mostly_dark", lit < 0.05 and mean < 0x18, f"lit={lit*100:.2f}% mean={mean:.2f}")

    def buf(x, y):
        return px[y * stride + x * 3]

    # layout (README "The image"), per eye in viewer coordinates
    eyes = [(0, W // 2, 1), (W // 2, W - W // 2, 2)]
    for ex0, ew, link in eyes:
        def view(x, y):                 # viewer -> buffer with 180 rotation inside the half
            return buf(ex0 + ew - 1 - x, H - 1 - y)
        u = max(ew // 47 // 2, 2)
        bi, bt = max(ew // 86, 4), max(ew // 258, 2)
        arm = H // 12
        cx, cy = ew // 2, H // 2
        adv, gh = 6 * u, 7 * u
        tw = 8 * adv - u
        tx, ty = cx - tw // 2, cy - arm - 3 * u - gh - 2 * u
        got = ""
        for i in range(8):
            bits = []
            for r in range(7):
                row = 0
                for c in range(5):
                    if view(tx + i * adv + c * u + u // 2, ty + r * u + u // 2) == C_TEXT:
                        row |= 0x10 >> c
                bits.append(row)
            got += "0123456789abcdef"[GLYPH.index(bits)] if bits in GLYPH else "?"
        side = "left" if ex0 == 0 else "right"
        check(f"nonce_{side}", got == nonce, f"decoded={got} expected={nonce}")
        uy = ty + gh + u + u // 4
        check(f"underline_{side}", view(cx, uy) == C_TEXT and view(tx - 2, uy) == C_BG)
        check(f"cross_{side}", view(cx, cy) == C_CROSS and view(cx + arm - 1, cy) == C_CROSS
              and view(cx, cy - arm + 1) == C_CROSS and view(cx + arm + 2, cy) == C_BG)
        check(f"border_{side}", all(view(x, y) == C_FRAME for x, y in
              [(bi, H // 2), (ew - bi - 1, H // 2), (ew // 2, bi), (ew // 2, H - bi - 1)]))
        sq = bi + bt + 5 * u
        check(f"orient_square_{side}", view(sq, sq) == C_FRAME and view(ew - 1 - sq, sq) == C_BG
              and view(sq, H - 1 - sq) == C_BG, "viewer top-left only")
        yb = cy + arm + 3 * u + 4 * u
        runs, prev = 0, False
        for x in range(bi + bt + 1, ew - bi - bt - 1):
            on = view(x, yb) == C_CROSS
            runs += on and not prev
            prev = on
        check(f"link_bars_{side}", runs == link, f"bars={runs} expected={link}")
        if ex0 == 0:
            crop = (tx - 2 * u, ty - 2 * u, tx + tw + 2 * u, ty + gh + 3 * u)

    # previews
    s = 4                               # nearest-neighbour 1/4 (thinnest line is 8 px)
    pw, ph = W // s, H // s
    scan = [b"".join(px[y * s * stride + x * s * 3: y * s * stride + x * s * 3 + 3] for x in range(pw))
            for y in range(ph)]
    write_png(f"{outdir}/{prefix}-scanout.png", pw, ph, scan)
    half = pw // 2
    viewer = []
    for r in reversed(scan):
        pix = [r[i:i + 3] for i in range(0, len(r), 3)]
        viewer.append(b"".join(reversed(pix[:half])) + b"".join(reversed(pix[half:])))
    write_png(f"{outdir}/{prefix}-viewer.png", pw, ph, viewer)
    x0, y0, x1, y1 = crop
    ew = W // 2
    rows = []
    for y in range(y0, y1):
        by = H - 1 - y
        line = px[by * stride: by * stride + ew * 3]
        pix = [line[i:i + 3] for i in range((ew - x1) * 3, (ew - x0) * 3, 3)]
        rows.append(b"".join(reversed(pix)))
    write_png(f"{outdir}/{prefix}-digits.png", x1 - x0, y1 - y0, rows)
    print(f"PREVIEW {outdir}/{prefix}-scanout.png {pw}x{ph}")
    print(f"PREVIEW {outdir}/{prefix}-viewer.png {pw}x{ph}")
    print(f"PREVIEW {outdir}/{prefix}-digits.png {x1 - x0}x{y1 - y0}")
    sys.exit(1 if fails else 0)

main()
