#!/usr/bin/env python3
"""Check an fs-pattern v0.6 render (PPM): the stage-3c picture or, with --solid, the run-3 red field.
Offline only; stdlib only. Derived from stage3b/tools/check_render.py (v0.5).

usage: check_render.py IMAGE.ppm NONCE OUTDIR PREFIX
       check_render.py IMAGE.ppm NONCE OUTDIR PREFIX --solid

Independent of the C code: the layout is re-derived from DESIGN.md §6.3 (u = ew/47/2, bt = ew/258,
arm = h/12, M_X = 480 and M_Y = 456 scaled with the size, groups centred at M_X + q and
ew - M_X - q with q = (ew - 2 M_X)/4, F top at cy + arm + 3u, bars 2u x 8u at F top + 9u).
Checks (pattern): R=G=B, exactly the levels 0x80 and 0xFF, white_ppm <= 37618 and
mean_x1000 <= 132777 (v0.5's fixtures; DESIGN §6.3 envelope), the 8 characters read back in BOTH
buffer halves, the underline, the vertical arm, the centre line spanning M_X..ew-M_X in each half,
no edge frame and no corner square, every white pixel inside the recovery margins, and the
quadrant map: per layer mixer (buffer columns 1032 m .. 1032 m + 1031) an upright F and k bars
(LM0 2, LM1 1, LM2 4, LM3 3), each group wholly inside its mixer's columns (exact white-pixel
count per mixer in the group rows). Checks (--solid): every pixel (255, 0, 0).
Writes <PREFIX>-scanout.png, <PREFIX>-viewer.png (1/4 scale) and, for the pattern,
<PREFIX>-digits.png (1:1, left half, viewer orientation).
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
F = GLYPH[15]
BG, WHITE = 0x80, 0xFF
WHITE_PPM_MAX, MEAN_X1000_MAX = 37618, 132777          # v0.5 fixture maxima (DESIGN §6.3)
BARS = {0: 2, 1: 1, 2: 4, 3: 3}                        # mixer -> bar count (DESIGN §6.3 table)

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
        while d[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not d[end:end + 1].isspace():
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


def tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def previews(px, W, H, outdir, prefix):
    stride, s = W * 3, 4
    pw, ph = W // s, H // s
    scan = [b"".join(px[y * s * stride + x * s * 3: y * s * stride + x * s * 3 + 3] for x in range(pw)) for y in range(ph)]
    write_png(f"{outdir}/{prefix}-scanout.png", pw, ph, scan)
    half = pw // 2
    viewer = []
    for r in reversed(scan):
        pix = [r[i:i + 3] for i in range(0, len(r), 3)]
        viewer.append(b"".join(reversed(pix[:half])) + b"".join(reversed(pix[half:])))
    write_png(f"{outdir}/{prefix}-viewer.png", pw, ph, viewer)
    print(f"PREVIEW {outdir}/{prefix}-scanout.png {pw}x{ph}")
    print(f"PREVIEW {outdir}/{prefix}-viewer.png {pw}x{ph}")


def solid(px, W, H, outdir, prefix):
    check("size", len(px) == W * H * 3, f"{W}x{H}")
    check("every_pixel_red_255_0_0", px == b"\xff\x00\x00" * (W * H), "XRGB 0x00FF0000 as R,G,B")
    previews(px, W, H, outdir, prefix)


def pattern(px, W, H, nonce, outdir, prefix):
    check("size", len(px) == W * H * 3, f"{W}x{H}")
    stride = W * 3
    R = px[0::3]
    check("grey", px[1::3] == R and px[2::3] == R, "R=G=B everywhere")
    n_white, n_bg = R.count(WHITE), R.count(BG)
    check("two_levels_only", n_white + n_bg == W * H and n_white > 0, "0x80 field, 0xFF marks")
    white_ppm = n_white * 1000000 // (W * H)
    mean_x1000 = (n_white * WHITE + n_bg * BG) * 1000 // (W * H)
    check("white_ppm_within_v05_envelope", white_ppm <= WHITE_PPM_MAX, f"white_ppm={white_ppm} <= {WHITE_PPM_MAX} ({white_ppm / 10000:.2f} %)")
    check("mean_within_v05_envelope", mean_x1000 <= MEAN_X1000_MAX, f"mean_x1000={mean_x1000} <= {MEAN_X1000_MAX}")
    print(f"STATS white_ppm={white_ppm} mean_x1000={mean_x1000}")

    def buf(x, y):
        return px[y * stride + x * 3]
    crop = None
    for e, (ex0, ew) in enumerate(((0, W // 2), (W // 2, W - W // 2))):
        side = "left" if e == 0 else "right"

        def view(x, y):          # viewer -> buffer: 180 degrees inside the half
            return buf(ex0 + ew - 1 - x, H - 1 - y)
        u = max(tdiv(tdiv(ew, 47), 2), 2)
        bt = max(tdiv(ew, 258), 2)
        arm = tdiv(H, 12)
        cx, cy = tdiv(ew, 2), tdiv(H, 2)
        mx, my = tdiv(ew * 480, 2064), tdiv(H * 456, 2208)
        adv, gh = 6 * u, 7 * u
        tw = 8 * adv - u
        tx, ty = cx - tdiv(tw, 2), cy - arm - 3 * u - gh - 2 * u
        got = ""
        for i in range(8):
            bits = []
            for r in range(7):
                row = 0
                for c in range(5):
                    if view(tx + i * adv + c * u + tdiv(u, 2), ty + r * u + tdiv(u, 2)) == WHITE:
                        row |= 0x10 >> c
                bits.append(row)
            got += "0123456789abcdef"[GLYPH.index(bits)] if bits in GLYPH else "?"
        check(f"nonce_{side}", got == nonce, f"decoded={got} expected={nonce}")
        uy = ty + gh + u + tdiv(u, 4)
        check(f"underline_{side}", view(cx, uy) == WHITE and view(tx - 2, uy) == BG)
        ct = bt
        yl0 = cy - tdiv(ct, 2)
        line = [view(x, yl0) for x in range(ew)]
        span = [x for x in range(ew) if line[x] == WHITE]
        check(f"centre_line_{side}_spans_M_X_to_ew-M_X", span == list(range(mx, ew - mx)) and
              all(view(x, yl0 + ct - 1) == WHITE for x in (mx, ew - mx - 1)) and view(mx, yl0 + ct) == BG and view(mx, yl0 - 1) == BG,
              f"x {span[0] if span else '-'}..{span[-1] if span else '-'} (want {mx}..{ew - mx - 1}), {ct} rows")
        check(f"vertical_arm_{side}_on_the_seam", view(cx, cy - arm + 1) == WHITE and view(cx, cy + arm - 1) == WHITE and view(cx, cy - arm - 2) == BG
              and view(cx - tdiv(ct, 2) - 1, cy - arm + 1) == BG and view(cx - tdiv(ct, 2) + ct, cy - arm + 1) == BG)
        bi = max(tdiv(ew, 86), 4)
        check(f"no_frame_no_corner_square_{side}", all(view(x, y) == BG for x, y in
              [(bi, tdiv(H, 2)), (ew - bi - 1, tdiv(H, 2)), (tdiv(ew, 2), bi), (tdiv(ew, 2), H - bi - 1), (bi + bt + 5 * u, bi + bt + 5 * u)]))
        # every white pixel inside the recovery margins (viewer box [mx, ew-mx) x [my, H-my))
        out = 0
        for y in range(H):
            row = px[(H - 1 - y) * stride + ex0 * 3:(H - 1 - y) * stride + (ex0 + ew) * 3:3]
            for xb in (i for i, v in enumerate(row) if v == WHITE):
                x = ew - 1 - xb
                if not (mx <= x < ew - mx and my <= y < H - my):
                    out += 1
        check(f"marks_inside_recovery_margins_{side}", out == 0, f"{out} white pixels outside [{mx},{ew - mx})x[{my},{H - my})")
        # quadrant groups: F decode (upright, chiral) and the bars
        q = tdiv(ew - 2 * mx, 4)
        fy = cy + arm + 3 * u
        by = fy + 9 * u
        for gx, part in ((cx - q, "viewer_left"), (cx + q, "viewer_right")):
            fx = gx - tdiv(5 * u, 2)
            bits = []
            for r in range(7):
                row = 0
                for c in range(5):
                    if view(fx + c * u + tdiv(u, 2), fy + r * u + tdiv(u, 2)) == WHITE:
                        row |= 0x10 >> c
                bits.append(row)
            mirrored = [int(f"{b:05b}"[::-1], 2) for b in F]
            check(f"F_upright_{side}_{part}", bits == F and F != mirrored and F != F[::-1], "rows=" + ",".join(f"{b:02x}" for b in bits))
        if e == 0:
            crop = (tx - 2 * u, ty - 2 * u, tx + tw + 2 * u, ty + gh + 3 * u, ew)
        # per mixer (buffer columns): bar runs and the exact white count of the group rows
        yb = by + 4 * u
        rows_g = range(H - (by + 8 * u), H - fy)        # buffer rows of viewer rows [fy, by + 8u)
        for mloc in (0, 1):
            m = e * 2 + mloc
            x0 = ex0 + mloc * tdiv(ew, 2)
            x1 = ex0 + (mloc + 1) * tdiv(ew, 2) if mloc == 0 else ex0 + ew
            k = BARS[m]
            r = [buf(x, H - 1 - yb) == WHITE for x in range(x0, x1)]
            runs = sum(1 for i, v in enumerate(r) if v and (i == 0 or not r[i - 1]))
            touch = r[0] or r[-1]
            want = 14 * u * u + k * (2 * u) * (8 * u)
            cnt = sum(1 for yy in rows_g for x in range(x0, x1) if buf(x, yy) == WHITE)
            check(f"LM{m}_buffer_cols_{x0}-{x1 - 1}_F_and_{k}_bars_wholly_inside", runs == k and not touch and cnt == want,
                  f"bars={runs} white={cnt} (want {want})")
    stride_ok = crop is not None
    previews(px, W, H, outdir, prefix)
    if stride_ok:
        x0, y0, x1, y1, ew = crop
        rows = []
        for y in range(y0, y1):
            by_ = H - 1 - y
            ln = px[by_ * stride: by_ * stride + ew * 3]
            pix = [ln[i:i + 3] for i in range((ew - x1) * 3, (ew - x0) * 3, 3)]
            rows.append(b"".join(reversed(pix)))
        write_png(f"{outdir}/{prefix}-digits.png", x1 - x0, y1 - y0, rows)
        print(f"PREVIEW {outdir}/{prefix}-digits.png {x1 - x0}x{y1 - y0}")


def main():
    ppm, nonce, outdir, prefix = sys.argv[1:5]
    W, H, px = read_ppm(ppm)
    if "--solid" in sys.argv[5:]:
        solid(px, W, H, outdir, prefix)
    else:
        pattern(px, W, H, nonce, outdir, prefix)
    sys.exit(1 if fails else 0)


main()
