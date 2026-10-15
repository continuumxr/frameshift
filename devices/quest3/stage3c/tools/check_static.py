#!/usr/bin/env python3
"""Static checks of fs-pattern v0.6 against v0.5 (DESIGN.md §6.2, §12.3 "static"). Offline; stdlib only.

usage: check_static.py STAGE3C/src/fs-pattern.c STAGE3B/src/fs-pattern.c

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
    v6, v5 = device(sys.argv[1]), device(sys.argv[2])
    for name in ("hold", "a_obj", "a_prop", "a_plane", "a_plane_off", "a_commit", "plan_attempts", "pick_mode",
                 "is_expected_mode", "mode_eq", "mode_in_list", "crtc_provably_inactive", "kv_text_int", "xioctl_n",
                 "obj_props", "find_prop", "plane_props", "finish", "check_stop", "rec_frame", "rec_write", "stdout_setup",
                 "signals_init", "pending_stop", "rect", "fill_buf", "read_blob", "log_blob", "obj_pinfo", "enum_name"):
        a, b = func(v6, name), func(v5, name)
        check("identical_to_v05_%s" % name, a is not None and a == b, "" if a == b else "differs or missing")
    sa = block(v6, r"^struct areq \{", r"^\};")
    check("identical_to_v05_struct_areq", sa is not None and sa == block(v5, r"^struct areq \{", r"^\};"))
    i6 = sorted(set(re.findall(r"DRM_IOCTL_[A-Z_0-9]+", v6)))
    i5 = sorted(set(re.findall(r"DRM_IOCTL_[A-Z_0-9]+", v5)))
    check("no_new_ioctl (DRM_IOCTL set = v0.5's)", i6 == i5, "new: %s" % sorted(set(i6) - set(i5)))
    p6 = sorted({norm(split_args(a)[1]) for _, a in calls(v6, "a_prop")})
    p5 = sorted({norm(split_args(a)[1]) for _, a in calls(v5, "a_prop")})
    check("a_prop_property_ids = v0.5 set + p->p_zpos", set(p6) == set(p5) | {"p->p_zpos"} and "p->p_zpos" not in p5,
          "v0.6 %s; v0.5 %s" % (p6, p5))
    zs = [pos for pos, a in calls(v6, "a_prop") if "p_zpos" in a]
    check("p_zpos_set_only_inside_a_plane_z", len(zs) == 1 and all(inside(v6, z, "a_plane_z") for z in zs), "%d site(s)" % len(zs))
    zc = calls(v6, "a_plane_z")
    check("a_plane_z_called_only_with_FSP_QUAD_Z[k]", len(zc) >= 1 and all(split_args(a)[-1] == "FSP_QUAD_Z[k]" for _, a in zc),
          str([split_args(a)[-1] for _, a in zc]))
    mz = re.search(r"static const uint64_t FSP_QUAD_Z\[4\] = \{ ([^}]*) \};", v6)
    check("FSP_QUAD_Z = {0, 0, 1, 1}", mz is not None and [x.strip() for x in mz.group(1).split(",")] == ["0", "0", "1", "1"],
          mz.group(0) if mz else "missing")
    f6 = sorted({split_args(a)[3] for _, a in calls(v6, "find_prop")})
    f5 = sorted({split_args(a)[3] for _, a in calls(v5, "find_prop")})
    check("find_prop_names = v0.5's (the only ids besides p_zpos that reach a request)", f6 == f5, str(f6))
    bad = []
    for nm in ("sspp_layout", "multirect_mode", "topology_control", "dsc_mode", "core_clk", "core_ab", "core_ib",
               "llcc_ab", "llcc_ib", "dram_ab", "dram_ib", "rotation"):
        for m in re.finditer('"%s"' % nm, v6):
            if not (inside(v6, m.start(), "log_conn_topology") or inside(v6, m.start(), "log_post_state")):
                bad.append("%s@%d" % (nm, v6[:m.start()].count("\n") + 1))
    check("never_set_names_only_in_the_read_only_loggers (log_conn_topology, log_post_state)", not bad, " ".join(bad))
    zl = [v6[:m.start()].count("\n") + 1 for m in re.finditer(r'"zpos"', v6)]
    check('"zpos"_name_only_read (log_plane_caps, log_post_plane)', all(inside(v6, m.start(), "log_plane_caps") or inside(v6, m.start(), "log_post_plane")
                                                                     for m in re.finditer(r'"zpos"', v6)), "lines %s" % zl)
    # the show/show-off request content: build_v05 = v0.5's inline loop body
    body5 = block(v5, r"^\t\tmemset\(&a, 0, sizeof\(a\)\);$", r"^\t\tuint32_t flags")
    b6 = func(v6, "build_v05")
    l5 = [norm(x) for x in body5.splitlines()[1:-1] if x.strip() and "int off = 0;" not in x]
    l6 = [norm(x) for x in b6.splitlines() if x.strip()]
    l6 = l6[l6.index("memset(a, 0, sizeof(*a));") + 1:l6.index("return off;")]
    l5 = [x.replace("plan[t].", "at->").replace("planes[pri], fb.fb_id", "planes[pri], fb_id").replace("fb.fb_id", "fb_id")
          .replace("blob.blob_id", "mode_blob").replace(", W", ", W").replace("&planes", "&planes") for x in l5]
    l6 = [x.replace("x->", "") for x in l6]
    l5n = [re.sub(r"\bW\b", "W", re.sub(r"\bH\b", "H", x)) for x in l5]
    check("build_v05_equals_the_v05_inline_request (normalised)", l5n == l6,
          "%d lines" % len(l6) if l5n == l6 else "\n v0.5 %s\n v0.6 %s" % (l5n, l6))
    code = re.sub(r"/\*.*?\*/", "", v6, flags=re.S)
    lits = re.findall(r'"([^"\n]*)"', code)
    paths = [x for x in lits if x.startswith("/sys") or x.startswith("/proc") or "debug" in x]
    check("no_sysfs_procfs_debugfs_path_in_the_device_build", not paths, str(paths))
    e6 = re.findall(r"^\t(EX_[A-Z]+)\s*= (\d+),", v6, re.M)
    e5 = re.findall(r"^\t(EX_[A-Z]+)\s*= (\d+),", v5, re.M)
    check("exit_code_table_equals_v05 (no new exit code)", e6 == e5 and len(e6) == 15, str(e6))
    want = {"FSP_HOLD_MAX_S": "10", "FSP_OPT_MAX": "38912", "FSP_OPT_MAX_SOLID": "10240", "FSP_BLOB_MAX": "8192",
            "FSP_CLOSE_MARGIN_S": "5", "FSP_SETUP_BUDGET_S": "30"}
    got = {k: (re.search(r"^#define %s\s+(\d+)" % k, v6, re.M) or [None, None])[1] for k in want}
    check("limits: hold 10, opt 38912/10240, blob 8192, close margin 5, setup 30", got == want, str(got))
    check("FSP_VERSION 0.6", re.search(r'^#define FSP_VERSION\s+"0\.6"', v6, re.M) is not None)
    # ---- build review: the 2 x 2064 policy and the split probe ----
    rs = func(v6, "run_show") or ""
    qa = rs.find("/* show-off-quad / show-off-solid (DESIGN")
    qb = rs.find('check_stop("before_commit")')
    nq = rs[:qa] if qa >= 0 else ""
    qbr = rs[qa:qb] if 0 <= qa < qb else ""
    check("policy: run 1 (show, the non-quad branch) commits the reviewed v0.5 split as the wake step (DESIGN §6.1, Q16): "
          "its committed tag is plan[ok].split ? \"split\" : \"single\"",
          'tag = plan[ok].split ? "split" : "single";' in nq and "if (!quad) {" in nq)

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
    check("policy: in the quad modes the split probe's a_commit carries DRM_MODE_ATOMIC_TEST_ONLY (TEST_ONLY only, never committed)",
          len(spc) == 1 and "DRM_MODE_ATOMIC_TEST_ONLY" in split_args(spc[0])[2] and not re.search(r"\bok\s*=[^=]", sp), str(spc))
    ql = brace_block(qbr, "for (int t = 0; t < 2 && ok < 0; t++) {") or ""
    oks = [m.start() for m in re.finditer(r"\bok\s*=[^=]", qbr)]
    lo = qbr.find(ql) if ql else -1
    check("policy: in the quad branch `ok` is assigned only inside the quad attempt loop (quad_vig, quad_dma)",
          bool(ql) and len(oks) >= 1 and all(lo <= o < lo + len(ql) for o in oks), "%d assignment(s)" % len(oks))
    tags = re.findall(r"\btag\s*=\s*([^;]+);", qbr)
    qt = re.search(r'static const char \*const qtag\[2\] = \{ "quad_vig", "quad_dma" \};', qbr)
    check("policy: the quad branch commits only a quad tag (tag = qtag[ok], qtag = {quad_vig, quad_dma}); 2 x 2064 there is TEST_ONLY only",
          tags == ["qtag[ok]"] and qt is not None, str(tags))
    # ---- build review: the essential-record cap ----
    ess = {k: (re.search(r"^#define %s\s+(\d+)" % k, v6, re.M) or [None, None])[1] for k in ("FSP_ESS_CONNECTORS", "FSP_ESS_MODES", "FSP_ESS_PLANES")}
    check("essential cap: FSP_ESS_CONNECTORS 3, FSP_ESS_MODES 24, FSP_ESS_PLANES 20 (= the maximum fixtures)",
          ess == {"FSP_ESS_CONNECTORS": "3", "FSP_ESS_MODES": "24", "FSP_ESS_PLANES": "20"}, str(ess))
    check("essential cap: the connector, mode and plane records use rec_begin_ess/rec_end_ess or rec_mode(..., i >= FSP_ESS_MODES); "
          "plane_caps is essential only for i < FSP_ESS_PLANES",
          'rec_begin_ess("connector", r, i, FSP_ESS_CONNECTORS);' in rs and 'rec_end_ess(i, FSP_ESS_CONNECTORS);' in rs
          and 'rec_mode("mode", (int)i, &modes[i], i >= FSP_ESS_MODES);' in rs and 'rec_end_ess(i, FSP_ESS_MODES);' in rs
          and 'rec_begin_ess("plane", r, i, FSP_ESS_PLANES);' in rs and 'rec_end_ess(i, FSP_ESS_PLANES);' in rs
          and "log_plane_caps(fd, pids[i], quad && i < FSP_ESS_PLANES, &caps);" in v6
          and not re.search(r'rec_begin\("(connector|mode|plane)",', v6))
    sys.exit(1 if fails else 0)


main()
