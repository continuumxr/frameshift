#!/usr/bin/env python3
"""Check an fs-pattern v0.7 render (PPM): the stage-3d per-eye picture or, with --solid, the run-3 red field.
Offline only; stdlib only. Derived from stage3c/tools/check_render.py (v0.6, unchanged).

usage: check_render.py IMAGE.ppm NONCE OUTDIR PREFIX [--roll DEG] [--eyes swap|direct]
       check_render.py IMAGE.ppm NONCE OUTDIR PREFIX --solid

Independent of the C code: the layout is re-derived from the stage-3d README ("fs-pattern v0.7"): per EYE
a design in that eye's viewer coordinates (u = ew/47/2, bt = ew/258, arm = h/12, M_X = 480 and M_Y = 456
scaled with the size; the v0.6 layout [groups at cx -/+ (ew - 2 M_X)/4, F top at cy + arm + 3u] only for
roll 0 with eyes direct; otherwise the v0.7 layout [groups at cx -/+ (ew - 2 M_X)/3, F top at cy + 3u]);
the left eye carries "1 | 2", the right eye "3 | 4"; the left eye's design is rotated counter-clockwise by
ROLL, the right eye's clockwise (as the viewer sees it, y down); the left eye is buffer half 1 with
--eyes swap (the default), half 0 with --eyes direct; each half holds its eye rotated 180 degrees.
The C code maps buffer -> design with a Q16 integer table (inverse, nearest neighbour); this checker maps
design -> buffer with floating-point trigonometry (forward) and samples feature CENTRES, so the two
implementations are independent.

Checks (pattern): R=G=B; exactly the levels 0x80 and 0xFF; white_ppm <= 37618 and mean_x1000 <= 132777
(the v0.5/v0.6 envelope); per eye: the 8 characters read back, the underline, the centre line (white along
M_X..ew-M_X, grey beyond its ends and beside it), the vertical arm, no edge frame, every white pixel inside
the recovery margins in the eye's design frame (2 px tolerance for the nearest-neighbour rotation), the
measured roll of the centre line (least squares over its white pixels, viewer frame) within 0.35 degrees of
the expected angle and direction, and per quadrant group an upright F and its k bars; per layer mixer
(buffer columns 1032 m .. 1032 m + 1031) the group it must carry (swap: LM0 4, LM1 3, LM2 2, LM3 1;
direct: LM0 2, LM1 1, LM2 4, LM3 3), its forward-mapped bounding box at least 2 px inside the mixer.
Checks (--solid): every pixel (255, 0, 0).
Writes <PREFIX>-scanout.png (1/4 scale, the buffer), <PREFIX>-viewer.png (1/4 scale: each eye's panel in
viewer orientation, the 180 degrees undone, LEFT EYE | RIGHT EYE, the pre-rotation still visible) and, for
the pattern, <PREFIX>-digits.png (1:1, the left eye's characters, design orientation).
Prints one "CHECK <name> PASS|FAIL detail" line per check; exit 1 on any FAIL.
"""
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
F = GLYPH[15]
BG, WHITE = 0x80, 0xFF
WHITE_PPM_MAX, MEAN_X1000_MAX = 37618, 132777          # v0.5 fixture maxima (stage-3c DESIGN §6.3)
LM_BARS = {"swap": {0: 4, 1: 3, 2: 2, 3: 1}, "direct": {0: 2, 1: 1, 2: 4, 3: 3}}

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


def solid(px, W, H, outdir, prefix):
    check("size", len(px) == W * H * 3, f"{W}x{H}")
    check("every_pixel_red_255_0_0", px == b"\xff\x00\x00" * (W * H), "XRGB 0x00FF0000 as R,G,B")
    previews(px, W, H, outdir, prefix, "direct")


def previews(px, W, H, outdir, prefix, eyes):
    stride, s = W * 3, 4
    pw, ph = W // s, H // s
    scan = [b"".join(px[y * s * stride + x * s * 3: y * s * stride + x * s * 3 + 3] for x in range(pw)) for y in range(ph)]
    write_png(f"{outdir}/{prefix}-scanout.png", pw, ph, scan)
    half = pw // 2
    viewer = []
    for r in reversed(scan):
        pix = [r[i:i + 3] for i in range(0, len(r), 3)]
        h0, h1 = b"".join(reversed(pix[:half])), b"".join(reversed(pix[half:]))
        viewer.append(h1 + h0 if eyes == "swap" else h0 + h1)       # LEFT EYE | RIGHT EYE
    write_png(f"{outdir}/{prefix}-viewer.png", pw, ph, viewer)
    print(f"PREVIEW {outdir}/{prefix}-scanout.png {pw}x{ph}")
    print(f"PREVIEW {outdir}/{prefix}-viewer.png {pw}x{ph} (left eye | right eye, viewer orientation, pre-rotation visible)")


def pattern(px, W, H, nonce, outdir, prefix, roll, eyes):
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
    print(f"STATS white_ppm={white_ppm} mean_x1000={mean_x1000} roll={roll} eyes={eyes}")
    legacy = roll == 0 and eyes == "direct"

    def buf(x, y):
        return px[y * stride + x * 3]
    crop = None
    group_boxes = []          # (eye, part, k, bx0, bx1)
    for eye in ("left", "right"):
        half = (1 if eye == "left" else 0) if eyes == "swap" else (0 if eye == "left" else 1)
        ex0, ew = (W // 2, W - W // 2) if half else (0, W // 2)
        th = math.radians(roll) * (1 if eye == "left" else -1)    # + = counter-clockwise as seen (y down)
        co, si = math.cos(th), math.sin(th)
        u = max(tdiv(tdiv(ew, 47), 2), 2)
        bt = max(tdiv(ew, 258), 2)
        arm = tdiv(H, 12)
        cx, cy = tdiv(ew, 2), tdiv(H, 2)
        mx, my = tdiv(ew * 480, 2064), tdiv(H * 456, 2208)
        ccx, ccy = ew / 2.0, H / 2.0                                # the rotation centre (the eye centre)

        def fwd(x, y):            # design point (continuous) -> viewer point of the panel (continuous)
            dx, dy = x - ccx, y - ccy
            return ccx + dx * co + dy * si, ccy - dx * si + dy * co

        def to_buf(x, y):         # design point -> buffer pixel (x, y) (180 degrees inside the half)
            vx, vy = fwd(x, y)
            ix, iy = int(math.floor(vx)), int(math.floor(vy))
            return ex0 + ew - 1 - ix, H - 1 - iy

        def view(x, y):           # sample the design pixel CENTRE (x + 0.5, y + 0.5)
            bx, by = to_buf(x + 0.5, y + 0.5)
            if not (ex0 <= bx < ex0 + ew and 0 <= by < H):
                return BG
            return buf(bx, by)

        def inv(bx, by):          # buffer pixel centre -> design point
            vx, vy = ex0 + ew - 1 - bx + 0.5, H - 1 - by + 0.5
            dx, dy = vx - ccx, vy - ccy
            return ccx + dx * co - dy * si, ccy + dx * si + dy * co
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
        check(f"nonce_{eye}_eye (buffer half {half})", got == nonce, f"decoded={got} expected={nonce}")
        ul0, ul1 = ty + gh + u, ty + gh + u + tdiv(u, 2) + 1
        uy = (ul0 + ul1 - 1) // 2
        check(f"underline_{eye}", view(cx, uy) == WHITE and view(tx + tw // 4, uy) == WHITE and view(tx - 3 * u, uy) == BG)
        ct = bt
        yl0 = cy - tdiv(ct, 2)
        yc = yl0 + ct // 2
        span_ok = all(view(x, yc) == WHITE for x in range(mx + 2, ew - mx - 2, 7))
        ends_ok = view(mx - 3 * bt, yc) == BG and view(ew - mx + 3 * bt, yc) == BG
        side_ok = all(view(x, yc + s) == BG for x in (mx + 40, cx - 60, cx + 60, ew - mx - 40) for s in (-(ct + 3), ct + 3))
        check(f"centre_line_{eye}_spans_M_X_to_ew-M_X", span_ok and ends_ok and side_ok, f"span {span_ok} ends {ends_ok} sides {side_ok}")
        check(f"vertical_arm_{eye}_on_the_seam", all(view(cx, y) == WHITE for y in range(cy - arm + 2, cy + arm - 2, 9))
              and view(cx, cy - arm - 3 * bt) == BG and view(cx, cy + arm + 3 * bt) == BG
              and view(cx - ct - 3, cy - arm // 2) == BG and view(cx + ct + 3, cy - arm // 2) == BG)
        bi = max(tdiv(ew, 86), 4)
        check(f"no_frame_no_corner_square_{eye}", all(view(x, y) == BG for x, y in
              [(bi, tdiv(H, 2)), (ew - bi - 1, tdiv(H, 2)), (tdiv(ew, 2), bi), (tdiv(ew, 2), H - bi - 1), (bi + bt + 5 * u, bi + bt + 5 * u)]))
        # every white pixel of the half, in the design frame, inside the recovery margins (+-2 px)
        out = 0
        line_pts = []
        for by in range(H):
            row = px[by * stride + ex0 * 3:by * stride + (ex0 + ew) * 3:3]
            for xb in (i for i, v in enumerate(row) if v == WHITE):
                x, y = inv(ex0 + xb, by)
                if not (mx - 2 <= x < ew - mx + 2 and my - 2 <= y < H - my + 2):
                    out += 1
                if abs(y - (yl0 + ct / 2.0)) <= ct / 2.0 + 1 and mx + 2 * bt <= x <= ew - mx - 2 * bt and abs(x - cx) > 3 * bt:
                    line_pts.append((ew - 1 - xb + 0.5, H - 1 - by + 0.5))      # viewer frame
        check(f"marks_inside_recovery_margins_{eye} (design frame, 2 px tolerance)", out == 0,
              f"{out} white pixels outside [{mx},{ew - mx})x[{my},{H - my})")
        # the measured roll: least squares y = a + b x of the centre line's white pixels (viewer frame)
        n = len(line_pts)
        sx = sum(p[0] for p in line_pts); sy = sum(p[1] for p in line_pts)
        sxx = sum(p[0] * p[0] for p in line_pts); sxy = sum(p[0] * p[1] for p in line_pts)
        b = (n * sxy - sx * sy) / (n * sxx - sx * sx) if n > 2 and n * sxx != sx * sx else float("nan")
        meas = math.degrees(math.atan(-b))                         # + = rising to the right = counter-clockwise
        want = roll if eye == "left" else -roll
        check(f"roll_{eye}_measured_on_the_centre_line (expected {want:+d} deg, + = counter-clockwise as seen)",
              n > 1000 and abs(meas - want) <= 0.35, f"measured {meas:+.3f} deg over {n} px")
        # quadrant groups: F decode (upright, chiral) and the bars
        if legacy:
            q, fy = tdiv(ew - 2 * mx, 4), cy + arm + 3 * u
        else:
            q, fy = tdiv(ew - 2 * mx, 3), cy + 3 * u
        by_ = fy + 9 * u
        bars = (1, 2) if eye == "left" else (3, 4)
        for gx, part, k in ((cx - q, "viewer_left", bars[0]), (cx + q, "viewer_right", bars[1])):
            fx = gx - tdiv(5 * u, 2)
            bits = []
            for r in range(7):
                row = 0
                for c in range(5):
                    if view(fx + c * u + tdiv(u, 2), fy + r * u + tdiv(u, 2)) == WHITE:
                        row |= 0x10 >> c
                bits.append(row)
            mirrored = [int(f"{b_:05b}"[::-1], 2) for b_ in F]
            check(f"F_upright_{eye}_{part}", bits == F and F != mirrored and F != F[::-1], "rows=" + ",".join(f"{b_:02x}" for b_ in bits))
            bw, gap = 2 * u, 2 * u
            total = k * bw + (k - 1) * gap
            bx0 = gx - tdiv(total, 2)
            yb = by_ + 4 * u
            samp = [view(x, yb) == WHITE for x in range(bx0 - 2 * u, bx0 + total + 2 * u)]
            runs = sum(1 for i, v in enumerate(samp) if v and (i == 0 or not samp[i - 1]))
            check(f"bars_{eye}_{part}_{k}", runs == k and not samp[0] and not samp[-1], f"runs={runs}")
            # the group's design box, forward-mapped to buffer columns
            gx0, gx1 = min(fx, bx0), max(fx + 5 * u, bx0 + total)
            cols = [to_buf(x, y)[0] for x in (gx0, gx1) for y in (fy, by_ + 8 * u)]
            group_boxes.append((eye, part, k, min(cols), max(cols)))
        if eye == "left":
            crop = (tx - 2 * u, ty - 2 * u, tx + tw + 2 * u, ty + gh + 3 * u, view)
    # per layer mixer: the expected group, wholly inside the mixer's columns
    for m in range(4):
        x0, x1 = 1032 * m * W // 4128, 1032 * (m + 1) * W // 4128 - 1
        want = LM_BARS[eyes][m]
        g = [b_ for b_ in group_boxes if x0 <= (b_[3] + b_[4]) // 2 <= x1]
        ok = len(g) == 1 and g[0][2] == want and g[0][3] >= x0 + 2 and g[0][4] <= x1 - 2
        check(f"LM{m}_buffer_cols_{x0}-{x1}_carries_the_{want}-bar_group_wholly_inside", ok,
              " ".join(f"{e}/{p}/k{k} cols {a}-{b_}" for e, p, k, a, b_ in g) or "no group")
    previews(px, W, H, outdir, prefix, eyes)
    if crop:
        x0, y0, x1, y1, view = crop
        rows = [bytes(b"".join(bytes((view(x, y),) * 3) for x in range(x0, x1))) for y in range(y0, y1)]
        write_png(f"{outdir}/{prefix}-digits.png", x1 - x0, y1 - y0, rows)
        print(f"PREVIEW {outdir}/{prefix}-digits.png {x1 - x0}x{y1 - y0} (left eye, design orientation)")


def main():
    ppm, nonce, outdir, prefix = sys.argv[1:5]
    rest = sys.argv[5:]
    roll = int(rest[rest.index("--roll") + 1]) if "--roll" in rest else 21
    eyes = rest[rest.index("--eyes") + 1] if "--eyes" in rest else "swap"
    assert -25 <= roll <= 25 and eyes in ("swap", "direct")
    W, H, px = read_ppm(ppm)
    if "--solid" in rest:
        solid(px, W, H, outdir, prefix)
    else:
        pattern(px, W, H, nonce, outdir, prefix, roll, eyes)
    sys.exit(1 if fails else 0)


main()
