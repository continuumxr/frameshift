#!/usr/bin/env python3
"""Check fs-pattern v0.5's read-only property logging against the mock DRM model
("fs-pattern-unittest propsim full|off"). Offline only; stdlib only.

usage: check_propsim.py full|off STREAM.txt

Independent of the C code: the expected objects, names and values are re-derived
here from the rules stated in src/fs-pattern.c ("v0.5 mock DRM property model");
the records are decoded (packed lists, %XX blob data) and compared. Also checks
the stream framing with the stage-3a validator rules, the record order, that the
optional bytes stay within FSP_OPT_MAX, and that no record is an overflow.
Prints one "CHECK <name> PASS|FAIL detail" line per check; exit 1 on any FAIL.
"""
import re
import sys
import zlib

FSP_OPT_MAX = 20480
REC = re.compile(r"^FSP1 nonce=([0-9a-f]{8}|none) seq=(0|[1-9][0-9]*) step=([a-z_]+) "
                 r"rc=(-?[0-9]+)((?: [a-z_0-9]+=[A-Za-z0-9_./%-]+)*) len=(0|[1-9][0-9]*) crc=([0-9a-f]{8}) END$")
KV = re.compile(r" ([a-z_0-9]+)=([A-Za-z0-9_./%-]+)")

CONN = ["EDID", "DPMS", "link-status", "non-desktop", "TILE", "CRTC_ID", "capabilities", "mode_properties",
        "dimming_bl_lut", "hdr_properties", "RETIRE_FENCE", "autorefresh", "qsync_mode", "dsc_mode",
        "frame_trigger_mode", "panel_mode", "bl_scale", "sv_bl_scale", "supported_colorspaces",
        "topology_name", "topology_control", "LP"]
CRTC = ["ACTIVE", "MODE_ID", "OUT_FENCE_PTR", "VRR_ENABLED", "GAMMA_LUT", "GAMMA_LUT_SIZE", "DEGAMMA_LUT", "CTM",
        "input_fence_timeout", "output_fence", "output_fence_offset", "core_clk", "core_ab", "core_ib", "llcc_ab",
        "llcc_ib", "dram_ab", "dram_ib", "rot_prefill_bw", "rot_clk", "idle_time", "capabilities", "dest_scaler",
        "ds_lut_ed", "ds_lut_cir", "ds_lut_sep", "security_level", "cache_state", "frame_trigger_mode", "dnsc_blur"]
PLANE = ["type", "FB_ID", "IN_FENCE_FD", "CRTC_ID", "CRTC_X", "CRTC_Y", "CRTC_W", "CRTC_H", "SRC_X", "SRC_Y",
         "SRC_W", "SRC_H", "IN_FORMATS", "rotation", "zpos", "alpha", "input_fence", "multirect_mode", "blend_op",
         "src_config", "sspp_layout", "syscache_type", "bg_alpha", "color_fill", "prefill_size", "prefill_time",
         "capabilities", "fb_translation_mode", "h_decimate", "v_decimate", "scaler_v2", "csc_v1", "inverse_pma",
         "SDE_VIG_3D_LUT_GEN5", "SDE_VIG_GAMUT", "SDE_VIG_IGC", "SDE_DGM_1D", "SDE_DGM_GC", "SDE_VIG_1D_LUT_IGC",
         "SDE_VIG_3D_LUT", "ubwc_stats_roi", "cac_type", "excl_rect_v1", "scaler_v2_lut_ed", "scaler_v2_lut_cir",
         "scaler_v2_lut_sep", "COLOR_ENCODING", "COLOR_RANGE", "pixel_blend_mode", "src.ext/x"]
PLANES = [71, 97, 100, 103, 106, 109, 112, 115, 118, 121, 124, 128, 131, 134, 137, 140, 143, 146, 149, 152]
MODE_PROPS = (b"mode_name=4128x2208x90vid\ntopology=sde_quadpipe_dsc4hsmerge\ncompression=dsc\nwb_topology=0\n"
              b"max_dsc_width=2064\npanel_mode=video\nbit_clk_rate=999999999\nhdr_luminance=-\nodd/even: 50% <>&\x01\xfe\n")
PF = (b"pixel_formats=AB24,AR24,RA24,BA24,XB24,XR24,RX24,BX24,BG24,RG24,BG16,RG16,AB15,AR15,BA15,RA15,XB15,XR15,"
      b"BX15,RX15,AB12,AR12,BA12,RA12,XB12,XR12,BX12,RX12,AB30,AR30,BA30,RA30,XB30,XR30,BX30,RX30,NV12,NV21,NV16,"
      b"NV61,YV12,YUYV,YVYU,UYVY,VYUY,P010,TP10,Q410\n")


def caps(k):
    return PF + b"max_linewidth=" + (b"4096" if k % 2 else b"2560") + (
        b"\nmax_upscale=20\nmax_downscale=4\nmax_horizontal_deci=0\nmax_vertical_deci=0\nmax_per_pipe_bw=4500000\npipe_idx=")\
        + bytes([0x30 + k % 10]) + b"\n"


def val(kind, obj, name, i, k=None):
    if kind == "conn":
        special = {"CRTC_ID": 155, "mode_properties": 201, "topology_name": 14, "dsc_mode": 2, "topology_control": 0}
        if name in special:
            return special[name]
    if kind == "plane":
        if i == 10:
            return obj << 20
        if name == "capabilities":
            return 300 + k
    return obj * 1000 + i


def letter(name):
    if name in ("topology_name", "panel_mode"):
        return "e"
    if name in ("dsc_mode", "DPMS", "blend_op"):
        return "E"
    if name in ("topology_control", "rotation"):
        return "M"
    if name in ("capabilities", "mode_properties", "EDID"):
        return "b"
    if name in ("CRTC_ID", "FB_ID"):
        return "O"
    if name in ("CRTC_X", "CRTC_Y"):
        return "S"
    return "R"


def pct(s):
    out, i = bytearray(), 0
    while i < len(s):
        if s[i] == "%":
            out.append(int(s[i + 1:i + 3], 16)); i += 3
        else:
            out.append(ord(s[i])); i += 1
    return bytes(out)


fails = 0


def check(name, ok, detail=""):
    global fails
    print(("CHECK %s %s %s" % (name, "PASS" if ok else "FAIL", detail)).rstrip())
    fails += 0 if ok else 1


def main():
    mode, path = sys.argv[1], sys.argv[2]
    lines = open(path, encoding="latin-1").read().split("\n")
    check("ends_with_newline", lines[-1] == "")
    recs = []
    framing = True
    for i, l in enumerate(lines[:-1]):
        m = REC.match(l)
        if not m:
            framing = False; break
        body = l[:l.rindex(" len=")]
        if int(m.group(6)) != len(body) or int(m.group(7), 16) != zlib.crc32(body.encode("latin-1")) & 0xffffffff or int(m.group(2)) != i:
            framing = False; break
        recs.append((m.group(3), int(m.group(4)), dict(KV.findall(m.group(5)))))
    check("framing_len_crc_seq", framing, "%d records" % len(recs))
    steps = [r[0] for r in recs]
    check("no_overflow_or_budget_record", "overflow" not in steps and "opt_budget" not in steps)
    eos = recs[-1][2] if recs and recs[-1][0] == "eos" else {}
    check("eos_counts", eos.get("records") == str(len(recs)) and eos.get("dropped") == "0" and eos.get("opt_skipped") == "0", str(eos))
    ob = int(eos.get("opt_bytes", "-1"))
    opt_steps = {"blob", "plane_caps", "prop_list", "prop_vals"}
    measured = sum(len(lines[i]) + 1 for i, r in enumerate(recs) if r[0] in opt_steps)
    check("opt_bytes_reported_equals_measured_and_within_max", ob == measured and ob <= FSP_OPT_MAX, "opt_bytes=%d measured=%d max=%d" % (ob, measured, FSP_OPT_MAX))
    topo = [r for r in recs if r[0] == "conn_topology"]
    check("conn_topology_once_essential", len(topo) == 1 and topo[0][1] == 0)
    t = topo[0][2] if topo else {}
    check("topology_values", t.get("topology_name") == "sde_quadpipe_dsc4hsmerge" and t.get("topology_val") == "14" and
          t.get("control_val") == "0" and t.get("dsc_mode_val") == "2" and t.get("mode_props_blob") == "201" and
          t.get("topology_prop") == str(1000 + CONN.index("topology_name")) and t.get("control_prop") == str(1000 + CONN.index("topology_control")), str(t))
    blobs = {}
    for s, rc, kv in recs:
        if s == "blob":
            blobs.setdefault(kv["what"], []).append(kv)
    mp = blobs.get("mode_properties", [])
    data = b"".join(pct(k["data"]) if k["data"] != "-" else b"" for k in sorted(mp, key=lambda k: int(k["part"])))
    check("mode_properties_blob_roundtrip", data == MODE_PROPS and all(k["bytes"] == str(len(MODE_PROPS)) for k in mp), "%d bytes" % len(data))
    if mode == "off":
        check("off_mode_logs_topology_and_mode_properties_only", set(steps) == {"start", "conn_topology", "blob", "exit", "eos"} and list(blobs) == ["mode_properties"], str(sorted(set(steps))))
    else:
        pc = [r[2] for r in recs if r[0] == "plane_caps"]
        check("plane_caps_every_plane_in_order", [int(k["plane"]) for k in pc] == PLANES)
        check("plane_caps_max_linewidth", all(k["max_linewidth"] == ("4096" if j % 2 else "2560") and k["caps_bytes"] == str(len(caps(j))) and
                                              k["caps_blob"] == str(300 + j) for j, k in enumerate(pc)))
        pcaps = blobs.get("primary_capabilities", [])
        data = b"".join(pct(k["data"]) for k in sorted(pcaps, key=lambda k: int(k["part"])))
        check("primary_capabilities_blob_roundtrip", data == caps(0) and all(k["obj"] == "71" for k in pcaps), "%d bytes in %d parts" % (len(data), len(pcaps)))
        lists = {}
        vals = {}
        for s, rc, kv in recs:
            if s == "prop_list":
                key = (kv["kind"], int(kv["ref"]))
                names = [pct(x).decode("latin-1") if x != "-" else "" for x in kv["names"].split(".")]
                lists.setdefault(key, []).append((int(kv["first"]), names, kv["types"], int(kv["n"]), int(kv["count"])))
            if s == "prop_vals":
                key = (kv["kind"], int(kv["obj"]))
                vals.setdefault(key, []).append((int(kv["first"]), [int(x) for x in kv["vals"].split(".")], int(kv["n"]), int(kv["count"]), kv["same_names"]))

        def join(parts):
            parts.sort()
            out, ok = [], True
            for first, items, *rest in parts:
                ok &= first == len(out) and rest[-1 if len(rest) == 3 else 1] is not None
                out += items
            return out, ok

        exp_objs = [("conn", 55, CONN), ("crtc", 155, CRTC)] + [("plane", p, PLANE[:49] if p == 106 else PLANE) for p in PLANES]
        refs = {"conn": 55, "crtc": 155, "plane": 71}
        ok_lists = True
        for kind, ref in [("conn", 55), ("crtc", 155), ("plane", 71), ("plane", 106)]:
            parts = lists.get((kind, ref), [])
            names = []
            types = ""
            for first, nm, ty, n, cnt in sorted(parts):
                ok_lists &= first == len(names) and len(nm) == n == len(ty)
                names += nm; types += ty
            want = dict(conn=CONN, crtc=CRTC, plane=PLANE)[kind] if ref != 106 else PLANE[:49]
            ok_lists &= names == want and types == "".join(letter(x) for x in want)
        check("prop_lists_names_and_types_roundtrip_incl_dot_slash", ok_lists and set(lists) == {("conn", 55), ("crtc", 155), ("plane", 71), ("plane", 106)}, str(sorted(lists)))
        ok_vals = True
        for kind, obj, names in exp_objs:
            parts = sorted(vals.get((kind, obj), []))
            got = []
            for first, vv, n, cnt, same in parts:
                ok_vals &= first == len(got) and len(vv) == n and cnt == len(names)
                ok_vals &= same == ("0" if obj == 106 else "1")
                got += vv
            k = PLANES.index(obj) if kind == "plane" else None
            ok_vals &= got == [val(kind, obj, nm, i, k) for i, nm in enumerate(names)]
        check("prop_vals_every_object_roundtrip", ok_vals and len(vals) == 22, "%d objects" % len(vals))
        order = [s for s in steps if s not in ("start", "exit", "eos")]
        want_order = ["conn_topology", "blob"] + ["plane_caps"] * 20 + ["blob"]
        check("record_order_priority", order[:len(want_order)] == want_order and set(order[len(want_order):]) <= {"blob", "prop_list", "prop_vals"})
    sys.exit(1 if fails else 0)


main()
