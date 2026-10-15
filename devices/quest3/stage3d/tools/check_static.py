#!/usr/bin/env python3
"""Static checks of fs-pattern v0.7 (stage 3d) against v0.6 (stage 3c, itself checked against v0.5 there). Offline; stdlib only.

usage: check_static.py STAGE3D/src/fs-pattern.c STAGE3C/src/fs-pattern.c

v0.7: the v0.6 request builder, hold, loggers and quad branch are textually v0.6s; the reset (build_reset, run_reset) sets
only ids v0.6 already sets (step A: the value 0); the picture: the sine table, the eye mapping and the blit (main() lists
every check). The v0.6 notes follow.

Only the DEVICE build is inspected (the text before "#else /* FSP_UNIT_TEST"; the unit-test mock
names many properties as data). Checks:
  - hold() and the request builder (struct areq, a_obj, a_prop, a_plane, a_plane_off, a_commit) are
    textually identical to v0.5; so are the mode policy and the v0.5 pure helpers;
  - no new ioctl: the set of DRM_IOCTL_* names equals v0.5's;
  - the property ids passed to a_prop = v0.5's set + p->p_zpos; p->p_zpos only inside a_plane_z;
    a_plane_z called only with FSP_QUAD_Z[k]; FSP_QUAD_Z = { 0, 0, 1, 1 };
  - the names looked up with find_prop (the only ids that reach a request besides p_zpos) = v0.5's;
  - the never-set names (sspp_layout, multirect_mode, topology_control, dsc_mode, core_/llcc_/dram_
    votes, rotation) occur only inside the read-only loggers (log_conn_topology, log_post_state);
  - the v0.5 request content of show/show-off (build_v05) equals v0.5's inline loop body;
  - no sysfs, procfs or debugfs path in the device build; the exit-code table equals v0.5's;
  - FSP_HOLD_MAX_S 10; FSP_OPT_MAX 38912, FSP_OPT_MAX_SOLID 10240, FSP_BLOB_MAX 8192;
  - build review: the 2 x 2064 POLICY (wording; DESIGN §6.1, Q16): run 1 (`show`, the non-quad branch of
    run_show) commits the reviewed v0.5 split as the wake step (its tag can be "split"); in the quad modes
    (runs 2/3) the split request is a TEST_ONLY probe: the split-probe a_commit carries TEST_ONLY, `ok` is
    assigned only inside the quad attempt loop, and the committed tag comes only from qtag {quad_vig, quad_dma};
  - build review: the essential-record cap (FSP_ESS_CONNECTORS 3, FSP_ESS_MODES 24, FSP_ESS_PLANES 20; the
    connector/mode/plane/plane_caps records go through the essential-or-optional helpers).
Prints one "CHECK <name> PASS|FAIL detail" line per check; exit 1 on any FAIL.
"""
import math
import re
import sys

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("CHECK %s %s %s" % (name, "PASS" if ok else "FAIL", detail)).rstrip())
    fails += 0 if ok else 1


def device(path):
    t = open(path, encoding="utf-8").read()
    return t.split("#else /* FSP_UNIT_TEST")[0]


def func(text, name):
    """the full text of the top-level function NAME (from its signature line to its closing brace)"""
    m = re.search(r"^(static [^\n;{]*?\b" + re.escape(name) + r"\([^;{]*?\)\s*)\{", text, re.M | re.S)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[m.start():j + 1]
    return None


def block(text, start_re, end_re):
    m = re.search(start_re, text, re.M)
    if not m:
        return None
    e = re.search(end_re, text[m.end():], re.M)
    return text[m.start():m.end() + e.end()] if e else None


def calls(text, name):
    """the argument lists of every call of NAME (not its definition)"""
    out = []
    for m in re.finditer(r"(?<![\w>])" + re.escape(name) + r"\(", text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        if text[line_start:m.start()].lstrip().startswith("static"):
            continue
        depth, j = 1, m.end()
        while depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        out.append((m.start(), text[m.end():j - 1]))
    return out


def split_args(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "," and depth == 0:
            out.append(cur.strip()); cur = ""
            continue
        depth += ch in "([{"
        depth -= ch in ")]}"
        cur += ch
    out.append(cur.strip())
    return out


def inside(text, pos, fname):
    f = func(text, fname)
    if not f:
        return False
    s = text.find(f)
    return s <= pos < s + len(f)


def norm(s):
    return re.sub(r"\s+", " ", s.replace("x->", "").replace("&a", "a").replace("(a,", "(a,")).strip()


def main():
    v7, v6 = device(sys.argv[1]), device(sys.argv[2])
    full7 = open(sys.argv[1], encoding="utf-8").read()
    # ---- unchanged from v0.6 (and through it from v0.5): the request builder, hold, the helpers ----
    for name in ("hold", "a_obj", "a_prop", "a_plane", "a_plane_off", "a_commit", "plan_attempts", "pick_mode",
                 "is_expected_mode", "mode_eq", "mode_in_list", "crtc_provably_inactive", "kv_text_int", "xioctl_n",
                 "obj_props", "find_prop", "plane_props", "finish", "check_stop", "rec_frame", "rec_write", "stdout_setup",
                 "signals_init", "pending_stop", "fill_buf", "read_blob", "log_blob", "obj_pinfo", "enum_name",
                 "build_v05", "build_quad", "a_plane_z", "quad_select", "quad_pick1", "pipe_type", "log_post_state",
                 "log_post_plane", "log_plane_caps", "log_properties", "draw_glyph", "draw_group", "draw_solid"):
        a, b = func(v7, name), func(v6, name)
        check("identical_to_v06_%s" % name, a is not None and a == b, "" if a == b else "differs or missing")
    sa = block(v7, r"^struct areq \{", r"^\};")
    check("identical_to_v06_struct_areq", sa is not None and sa == block(v6, r"^struct areq \{", r"^\};"))
    i7 = sorted(set(re.findall(r"DRM_IOCTL_[A-Z_0-9]+", v7)))
    i6 = sorted(set(re.findall(r"DRM_IOCTL_[A-Z_0-9]+", v6)))
    check("no_new_ioctl (DRM_IOCTL set = v0.6's)", i7 == i6, "new: %s" % sorted(set(i7) - set(i6)))
    p7 = sorted({norm(split_args(a)[1]) for _, a in calls(v7, "a_prop")})
    p6 = sorted({norm(split_args(a)[1]) for _, a in calls(v6, "a_prop")})
    check("a_prop_property_ids = v0.6's set (no new property id is ever set)", p7 == p6, "v0.7 %s; v0.6 %s" % (p7, p6))
    zs = [pos for pos, a in calls(v7, "a_prop") if "p_zpos" in a]
    check("p_zpos_set_only_inside_a_plane_z", len(zs) == 1 and all(inside(v7, z, "a_plane_z") for z in zs), "%d site(s)" % len(zs))
    zc = calls(v7, "a_plane_z")
    check("a_plane_z_called_only_with_FSP_QUAD_Z[k]", len(zc) >= 1 and all(split_args(a)[-1] == "FSP_QUAD_Z[k]" for _, a in zc),
          str([split_args(a)[-1] for _, a in zc]))
    mz = re.search(r"static const uint64_t FSP_QUAD_Z\[4\] = \{ ([^}]*) \};", v7)
    check("FSP_QUAD_Z = {0, 0, 1, 1}", mz is not None and [x.strip() for x in mz.group(1).split(",")] == ["0", "0", "1", "1"],
          mz.group(0) if mz else "missing")
    f7 = sorted({split_args(a)[3] for _, a in calls(v7, "find_prop")})
    f6 = sorted({split_args(a)[3] for _, a in calls(v6, "find_prop")})
    check("find_prop_names = v0.6's", f7 == f6, str(f7))
    bad = []
    for nm in ("sspp_layout", "multirect_mode", "topology_control", "dsc_mode", "core_clk", "core_ab", "core_ib",
               "llcc_ab", "llcc_ib", "dram_ab", "dram_ib", "rotation", "backlight_changes_blocked"):
        for m in re.finditer('"%s"' % nm, v7):
            if not (inside(v7, m.start(), "log_conn_topology") or inside(v7, m.start(), "log_post_state")):
                bad.append("%s@%d" % (nm, v7[:m.start()].count("\n") + 1))
    check("never_set_names_only_in_the_read_only_loggers (log_conn_topology, log_post_state)", not bad, " ".join(bad))
    code = re.sub(r"/\*.*?\*/", "", v7, flags=re.S)
    lits = re.findall(r'"([^"\n]*)"', code)
    paths = [x for x in lits if x.startswith("/sys") or x.startswith("/proc") or "debug" in x]
    check("no_sysfs_procfs_debugfs_path_in_the_device_build", not paths, str(paths))
    e7 = re.findall(r"^\t(EX_[A-Z]+)\s*= (\d+),", v7, re.M)
    e6 = re.findall(r"^\t(EX_[A-Z]+)\s*= (\d+),", v6, re.M)
    check("exit_code_table_equals_v06 (no new exit code)", e7 == e6 and len(e7) == 15, str(e7))
    want = {"FSP_HOLD_MAX_S": "10", "FSP_OPT_MAX": "38912", "FSP_OPT_MAX_SOLID": "10240", "FSP_BLOB_MAX": "8192",
            "FSP_CLOSE_MARGIN_S": "5", "FSP_SETUP_BUDGET_S": "30", "FSP_ROLL_DEFAULT": "21", "FSP_ROLL_MAX": "25",
            "FSP_EYES_SWAP": "1", "FSP_RESET_POST_PLANES": "4"}
    got = {k: (re.search(r"^#define %s\s+(\d+)" % k, v7, re.M) or [None, None])[1] for k in want}
    check("limits: hold 10, opt 38912/10240, blob 8192, close 5, setup 30; roll default 21, max 25; eyes swap; reset post_plane 4",
          got == want, str(got))
    check("FSP_VERSION 0.7.1", re.search(r'^#define FSP_VERSION\s+"0\.7\.1"', v7, re.M) is not None)
    # v0.7.1 (J-141): the mode limit holds v2.7's list (305; 338 before pruning; 480 = 2 nodes x 240 rates); the logged
    # mode records are capped (essential 24, optional up to 48 or an expected mode), the rest counted in opt_skipped
    mm = re.search(r"^#define MAXMODES\s+(\d+)", v7, re.M)
    check("v0.7.1: MAXMODES >= 480 (v2.7: 305 listed, 338 built)", mm is not None and int(mm.group(1)) >= 480, mm.group(0) if mm else "missing")
    lm = re.search(r"^#define FSP_LOG_MODES\s+(\d+)", v7, re.M)
    check("v0.7.1: FSP_LOG_MODES 48", lm is not None and lm.group(1) == "48")
    rsx = func(v7, "run_show") or ""
    check("v0.7.1: the mode loop skips (and counts in opt_skipped) only modes at index >= FSP_LOG_MODES that are not expected",
          "if (i >= FSP_LOG_MODES && !is_expected_mode(&modes[i])) {   /* v0.7.1: not logged, counted */\n\t\t\tg_opt_skipped++;\n\t\t\tcontinue;" in rsx)
    check("v0.7.1: the too_many_modes refusal is kept (count_modes > MAXMODES -> exit 30)",
          "if (chosen.count_modes > MAXMODES || chosen.count_encoders > MAXOBJ) {" in rsx and 'finish(EX_NOMODE, "too_many_modes");' in rsx)
    # ---- the quad branch (runs 2/3) keeps the stage-3c policy ----
    rs = func(v7, "run_show") or ""
    rs6 = func(v6, "run_show") or ""
    qa = rs.find("/* show-off-quad / show-off-solid (DESIGN")
    qb = rs.find('check_stop("before_commit")')
    qbr = rs[qa:qb] if 0 <= qa < qb else ""
    qa6 = rs6.find("/* show-off-quad / show-off-solid (DESIGN")
    qb6 = rs6.find('check_stop("before_commit")')
    check("the quad branch of run_show (plane selection, split probe, quad attempts) is textually v0.6's",
          bool(qbr) and qbr == rs6[qa6:qb6])

    def brace_block(text, opener):
        i = text.find(opener)
        if i < 0:
            return None
        j = text.find("{", i)
        d = 0
        for k in range(j, len(text)):
            d += text[k] == "{"
            d -= text[k] == "}"
            if d == 0:
                return text[i:k + 1]
        return None
    sp = brace_block(qbr, "if (have_split) {") or ""
    spc = [a for _, a in calls(sp, "a_commit")]
    check("policy: in the quad modes the split probe's a_commit carries DRM_MODE_ATOMIC_TEST_ONLY (never committed)",
          len(spc) == 1 and "DRM_MODE_ATOMIC_TEST_ONLY" in split_args(spc[0])[2] and not re.search(r"\bok\s*=[^=]", sp), str(spc))
    tags = re.findall(r"\btag\s*=\s*([^;]+);", qbr)
    check("policy: the quad branch commits only a quad tag (tag = qtag[ok])", tags == ["qtag[ok]"], str(tags))
    ess = {k: (re.search(r"^#define %s\s+(\d+)" % k, v7, re.M) or [None, None])[1] for k in ("FSP_ESS_CONNECTORS", "FSP_ESS_MODES", "FSP_ESS_PLANES")}
    check("essential cap: FSP_ESS_CONNECTORS 3, FSP_ESS_MODES 24, FSP_ESS_PLANES 20",
          ess == {"FSP_ESS_CONNECTORS": "3", "FSP_ESS_MODES": "24", "FSP_ESS_PLANES": "20"}, str(ess))
    # ---- v0.7 reset (run 1 of stage 3d) ----
    br = func(v7, "build_reset") or ""
    bp = [split_args(a) for _, a in calls(br, "a_prop")]
    check("reset A (build_reset): a_prop only k_crtc, c_mode, c_active, each with the value 0",
          sorted(a[1] for a in bp) == ["c_active", "c_mode", "k_crtc"] and all(a[2] == "0" for a in bp), str(bp))
    check("reset A: the planes bound to the CRTC switched off with a_plane_off only; no a_plane / a_plane_z",
          "a_plane_off(a, &planes[i]);" in br and "planes[i].crtc_id == crtc_id" in br
          and not calls(br, "a_plane") and not calls(br, "a_plane_z"))
    rr = func(v7, "run_reset") or ""
    cm = [split_args(a) for _, a in calls(rr, "a_commit")]
    flags = [a[2] for a in cm]
    check("reset: four a_commit sites in order TEST_ONLY|ALLOW_MODESET (A), ALLOW_MODESET (A), TEST_ONLY|ALLOW_MODESET (B), "
          "ALLOW_MODESET (B); real commits tried once",
          flags == ["DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET", "DRM_MODE_ATOMIC_ALLOW_MODESET",
                    "DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET", "DRM_MODE_ATOMIC_ALLOW_MODESET"]
          and [a[3] for a in cm] == ["100", "1", "100", "1"], str(flags))
    i_test_a = rr.find('kv_s("layout", "reset_off");')
    i_refuse_a = rr.find('if (r) finish(EX_TESTREJECT, "reset_off_rejected");')
    i_commit_a = rr.find("r = a_commit(g_fd, &a, DRM_MODE_ATOMIC_ALLOW_MODESET, 1);")
    i_plan = rr.find("int na = plan_attempts(0, mode_expected, sec >= 0, plan);")
    i_na = rr.find('if (na == 0) finish(EX_TESTREJECT, "no_reenable_attempt");')
    check("reset: B is planned (a modeset attempt exists) BEFORE A is sent; A is committed only after its TEST_ONLY was accepted",
          0 <= i_plan < i_na < i_test_a < i_refuse_a < i_commit_a)
    check("reset: B = the v0.5 modeset attempts only (plan_attempts with use_current 0) built by build_v05",
          "plan_attempts(0, mode_expected" in rr and "build_v05(&a, &plan[t], x, pri, sec)" in rr)
    check("reset: no picture, no hold: run_reset calls neither draw_pattern, draw_solid, hold nor a_plane_z",
          not any(calls(rr, n) for n in ("draw_pattern", "draw_solid", "hold", "a_plane_z")))
    check("reset: the fd is closed before the reset_close record and before finish",
          0 <= rr.find("int cr = close(g_fd);") < rr.find('rec_begin("reset_close", 0);'))
    db = re.sub(r"\s+", " ", func(v7, "draw_black") or "")
    check("reset: the buffer of a reset is drawn by draw_black only; draw_black writes zero bytes only",
          "else if (kind == K_RESET) draw_black((uint8_t *)map, cd.pitch, W, H);" in rs
          and "memset(base + (size_t)y * pitch, 0, (size_t)w * 4);" in db)
    i_buf = rs.find('if (r) finish(EX_BUFFER, "buffer_failed");')
    i_rr = rs.find("run_reset(&x, pri, sec, is_expected_mode(&mode));")
    i_nq = rs.find("if (!quad) {")
    check("reset: dispatched after the buffer record and before any show/quad attempt", 0 <= i_buf < i_rr < i_nq)
    check("reset: off_mode (the inactive-CRTC precondition) is for show-off* only, not for reset",
          "int off_mode = kind == K_OFF || kind == K_QUAD || kind == K_SOLID," in rs)
    # ---- v0.7 picture ----
    ms = re.search(r"SIN_Q16\[FSP_ROLL_MAX \+ 1\] = \{([^}]*)\}", v7, re.S)
    mc = re.search(r"COS_Q16\[FSP_ROLL_MAX \+ 1\] = \{([^}]*)\}", v7, re.S)
    sv = [int(x) for x in ms.group(1).replace("\n", " ").split(",")] if ms else []
    cv = [int(x) for x in mc.group(1).replace("\n", " ").split(",")] if mc else []
    check("SIN_Q16 / COS_Q16 = round(65536 sin d) / round(65536 cos d), d = 0..25 (recomputed here)",
          sv == [round(65536 * math.sin(math.radians(d))) for d in range(26)]
          and cv == [round(65536 * math.cos(math.radians(d))) for d in range(26)])
    es = re.sub(r"\s+", " ", func(v7, "eye_sin") or "")
    check("eye_sin: the left eye gets +sin(roll) (counter-clockwise), the right eye -sin(roll)", "return left_eye ? s : -s;" in es)
    eh = re.sub(r"\s+", " ", func(v7, "eye_half") or "")
    check("eye_half: swap -> the left eye is half 1; direct -> half 0", "return (left_eye ? 1 : 0) ^ (swap ? 0 : 1);" in eh)
    dp = re.sub(r"\s+", " ", func(v7, "draw_pattern") or "")
    check("draw_pattern: the left eye 1|2, the right eye 3|4; legacy layout only for roll 0 with eyes direct",
          "int legacy = g_roll == 0 && !g_eyes_swap;" in dp and "draw_eye(&c, nonce, left ? 1 : 3, left ? 2 : 4, legacy);" in dp)
    bl = re.sub(r"\s+", " ", func(v7, "blit_eye") or "")
    check("blit_eye writes grey levels from the eye canvas or C_BG only (no other value)",
          "uint8_t v = (sx >= 0 && sx < ew && sy >= 0 && sy < h) ? c->eye[(size_t)sy * (size_t)ew + (size_t)sx] : C_BG;" in bl
          and "row[bx] = 0xff000000u | ((uint32_t)v << 16) | ((uint32_t)v << 8) | v;" in bl)
    po = re.sub(r"\s+", " ", func(v7, "parse_opt") or "")
    check("parse_opt: roll bounded by FSP_ROLL_MAX, eyes swap|direct only, each once", "if (val > FSP_ROLL_MAX)" in po
          and '"eyes=swap"' in po and '"eyes=direct"' in po and "!g_opt_roll_seen" in po and "!g_opt_eyes_seen" in po)
    check("show-off-solid takes no picture option (main: o == 1 && kind != K_SOLID)", "if (o == 1 && kind != K_SOLID) continue;" in full7)
    sys.exit(1 if fails else 0)


main()
