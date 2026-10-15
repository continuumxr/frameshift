#!/usr/bin/env python3
"""Check fs-pattern v0.7 (stage 3d) against the mock DRM model of the unit-test build. Offline; stdlib only.
Derived from stage3c/tools/check_propsim.py (v0.6, unchanged). v0.7 additions: the "reset" mode (step A the
disable reset_off with only zero values; step B the dark re-enable on an all-black buffer through the v0.5
modeset attempts; then close; exit codes 0 / 50; already_inactive), the start-record picture options
(roll, eyes) and the black pixel class of the mock.

usage: check_propsim.py propsim full|off|repeat|quad|solid STREAM.txt
       check_propsim.py sim SCENARIO STREAM.txt MOCKLOG.txt

Independent of the C code: the objects, names, values, capabilities blobs and the expected
plan are re-derived HERE from the rules stated in src/fs-pattern.c ("v0.6 mock DRM device");
the FSP1 records are decoded (packed lists, %XX values and blob data) and compared.

propsim: the start-of-run logging only (log_properties), per run kind.
sim:     the WHOLE show path (run_show) against the mock: the stream on stdout, the mock's log
         of every DRM_IOCTL_MODE_ATOMIC on stderr. Checks (DESIGN §12.3): plane selection from
         the caps (type from max_upscale, exactly one candidate per slot, missing/ambiguous),
         the attempt order split_probe -> quad_vig -> quad_dma, the split probe never committed,
         zpos only in quad attempts, only on the four planes, values 0,0,1,1 by slot, the set of
         properties ever SET = the v0.5 set + zpos (never sspp_layout, multirect_mode,
         topology_control, dsc_mode, core_/llcc_/dram_ votes, rotation), the commit equal to the
         last accepted TEST_ONLY request, the commit-time stage slots (E15 model; {0,0,0,0} as the
         negative control), post_state/post_plane with the right-half CRTC_X conversion (E17),
         the drawn buffer's pixel classes, and the stream bounds (57344 / 28672 B; FSP_OPT_MAX
         38912 / FSP_OPT_MAX_SOLID 10240).
Prints one "CHECK <name> PASS|FAIL detail" line per check; exit 1 on any FAIL.
"""
import re
import sys
import zlib

FSP_OPT_MAX, FSP_OPT_MAX_SOLID = 38912, 10240
CAP = {"show": 57344, "show-off-quad": 57344, "show-off-solid": 28672, "show-off": 57344, "reset": 57344}
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
TOPO = ["sde_none", "sde_singlepipe", "sde_singlepipe_dsc", "sde_singlepipe_vdc", "sde_dualpipe", "sde_dualpipe_dsc",
        "sde_dualpipemerge", "sde_dualpipemerge_dsc", "sde_dualpipemerge_vdc", "sde_dualpipe_dscmerge", "sde_ppsplit",
        "sde_quadpipemerge", "sde_quadpipe_3dmerge_dsc", "sde_quadpipe_dscmerge", "sde_quadpipe_dsc4hsmerge"]
MODE_PROPS = (b"mode_name=4128x2208x90vid\ntopology=sde_quadpipe_dsc4hsmerge\ncompression=dsc\nwb_topology=0\n"
              b"max_dsc_width=2064\npanel_mode=video\nbit_clk_rate=999999999\nhdr_luminance=-\nodd/even: 50% <>&\x01\xfe\n")
CONN_CAPS = (b"max_blendstages=10\nqseed_type=qseed3lite\nsmart_dma_rev=smart_dma_v2p5\nhas_src_split=1\nsdma_count=6\n"
             b"max_mixer_width=2560\n")
PF_VIG = (b"pixel_formats=AR24 AB24 RA24 AB24/5/1 BA24 XR24 RX24 BX24 XB24 XB24/5/1 RG24 BG24 RG16 BG16/5/1 BG16 AR15 "
          b"AB15 RA15 BA15 XR15 XB15 RX15 BX15 AR12 AB12 RA12 BA12 XR12 XB12 RX12 BX12 NV12 NV12/5/1 NV21 NV16 NV61 VYUY "
          b"UYVY YUYV YVYU YU12 YV12 BA30 BX30 RA30 RX30 AB30 AB30/5/1 XB30 XB30/5/1 AR30 XR30 NV12/5/7 NV12/5/2 "
          b"NV12/5/3 AR4H AR4H/5/10 AB4H AB4H/5/10 AB4H/5/1\n")
PF_DMA = (b"pixel_formats=AR24 AB24 RA24 AB24/5/1 BA24 XR24 RX24 BX24 XB24 XB24/5/1 RG24 BG24 RG16 BG16/5/1 BG16 AR15 "
          b"AB15 RA15 BA15 XR15 XB15 RX15 BX15 AR12 AB12 RA12 BA12 XR12 XB12 RX12 BX12 BA30 BX30 RA30 RX30 AB30 "
          b"AB30/5/1 XB30 XB30/5/1 AR30 XR30\n")
# the v0.5 property-id expressions passed to a_prop, plus zpos (DESIGN §6.2): the only properties ever set
ALLOWED_SET = {"FB_ID", "CRTC_ID", "SRC_X", "SRC_Y", "SRC_W", "SRC_H", "CRTC_X", "CRTC_Y", "CRTC_W", "CRTC_H",
               "MODE_ID", "ACTIVE", "zpos"}
NEVER_SET = {"sspp_layout", "multirect_mode", "topology_control", "dsc_mode", "core_clk", "core_ab", "core_ib",
             "llcc_ab", "llcc_ib", "dram_ab", "dram_ib", "rotation"}
V_NONE, V_VIG2DUP, V_VIG2UP3, V_VIG2UPNONE, V_DMADUP, V_VIG1OTHER, V_CAPSMISSING = range(7)
SCEN = {   # name: (kind, active, accept set, noconv, variant, mp_len, cc_len)
    "show-run1": ("show", 1, {"split+modeset"}, 0, V_NONE, 0, 0),
    "off-v05": ("show-off", 0, {"split+modeset"}, 0, V_NONE, 0, 0),
    "quad-vig": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 0, 0),
    "quad-dma": ("show-off-quad", 0, {"split+modeset", "quad_dma"}, 0, V_NONE, 0, 0),
    "quad-reject": ("show-off-quad", 0, {"split+modeset"}, 0, V_NONE, 0, 0),
    "quad-active": ("show-off-quad", 1, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 0, 0),
    "quad-vig2dup": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_VIG2DUP, 0, 0),
    "quad-vig2up3": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_VIG2UP3, 0, 0),
    "quad-vig2upnone": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_VIG2UPNONE, 0, 0),
    "quad-dmadup": ("show-off-quad", 0, {"split+modeset", "quad_dma"}, 0, V_DMADUP, 0, 0),
    "quad-vig1other": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_VIG1OTHER, 0, 0),
    "quad-capsmissing": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_CAPSMISSING, 0, 0),
    "quad-noconv": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 1, V_NONE, 0, 0),
    "quad-max": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 8192, 8192),
    "show-max": ("show", 1, {"split+modeset"}, 0, V_NONE, 8192, 8192),
    "solid": ("show-off-solid", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 0, 0),
    "solid-max": ("show-off-solid", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 8192, 8192),
    "blob-8193": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 8193, 8192),
    "reset": ("reset", 1, {"reset_off", "split+modeset"}, 0, V_NONE, 0, 0),
    "reset-inactive": ("reset", 0, {"reset_off", "split+modeset"}, 0, V_NONE, 0, 0),
    "reset-off-reject": ("reset", 1, {"split+modeset"}, 0, V_NONE, 0, 0),
    "reset-on-reject": ("reset", 1, {"reset_off"}, 0, V_NONE, 0, 0),
    "reset-max": ("reset", 1, {"reset_off", "split+modeset"}, 0, V_NONE, 8192, 8192),
    "quad-vig-roll0-direct": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 0, 0),
    # v0.7.1 (J-141): Unit 2's v2.7 connector set with the 305 modes of tools/v27-modes.py; mode_properties ~70000 B
    "reset-v27": ("reset", 1, {"reset_off", "split+modeset"}, 0, V_NONE, 70000, 0),
    "quad-v27": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 70000, 0),
    "solid-v27": ("show-off-solid", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 70000, 0),
    "reset-v27-late": ("reset", 1, {"reset_off", "split+modeset"}, 0, V_NONE, 70000, 0),
    "quad-v27-late": ("show-off-quad", 0, {"split+modeset", "quad_vig", "quad_dma"}, 0, V_NONE, 70000, 0),
    "reset-toomany": ("reset", 1, {"reset_off", "split+modeset"}, 0, V_NONE, 0, 0),
}
FSP_ESS_MODES, FSP_LOG_MODES, MAXMODES = 24, 48, 512
# Unit 2's r1 record (v2.7, nonce 7a22c3d2ff0fef44, J-141), records 4-9 without the framing: what fs-pattern v0.7 logged
# before refusing; the v0.7-limit control build (MAXMODES 128 with the v2.7 mock) must log exactly these
UNIT2_R1 = [
    "step=resources rc=0 crtcs=3 connectors=3 encoders=3 fbs=0 max_w=20480 max_h=8640",
    "step=connector rc=0 id=33 type=15 type_id=1 status=1 modes=37 encoders=1 encoder=0 mm_w=0 mm_h=0",
    "step=connector rc=0 id=55 type=16 type_id=1 status=1 modes=305 encoders=1 encoder=54 mm_w=0 mm_h=0",
    "step=connector rc=0 id=65 type=10 type_id=1 status=2 modes=0 encoders=1 encoder=0 mm_w=0 mm_h=0",
    "step=chosen_connector rc=-7 id=55",
    "step=exit rc=0 code=30 reason=too_many_modes shown=0 closed_at_exit=1",
]


def v27_model(late):
    """the v2.7 list of tools/v27-modes.py (an implementation independent of the C mock); late: the mock's reordering"""
    import importlib.util
    import os
    sp = importlib.util.spec_from_file_location("v27modes", os.path.join(os.path.dirname(os.path.abspath(__file__)), "v27-modes.py"))
    m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m)
    L = m.mode_list(72, 240, [], [(2064, 38, 20, 54, 2208, 2918, 2, 30), (1552, 38, 20, 54, 1664, 2956, 2, 30)])
    if not late:
        return L
    e = L[0]
    out = []
    for x in L[1:]:
        if len(out) == 30:
            out.append(dict(e, flags=0x10, type=0))
        if len(out) == 100:
            out.append(dict(e, h=2209, type=0, name="4128x2209x90vid"))
        if len(out) == 250:
            out += [e, e]
        out.append(x)
    return out


def is_exp(m):
    return m["w"] == 4128 and m["h"] == 2208 and m["vrefresh"] == 90 and not m["flags"] & 0x10


def v27_checks(name, recs, by, steps, ex):
    """v0.7.1: the v2.7 connector set and its mode list (J-141)"""
    late = name.endswith("-late")
    L = v27_model(late)
    n = len(L)
    conn = [(r[2]["id"], r[2]["type"], r[2]["status"], r[2]["modes"]) for r in by["connector"]]
    check("v27: connectors as on Unit 2: 33/55/65, types 15/16/10, status 1/1/2, modes 37/%d/0" % n,
          conn == [("33", "15", "1", "37"), ("55", "16", "1", str(n)), ("65", "10", "2", "0")], str(conn))
    cc = by["chosen_connector"][0]
    check("v27: chosen connector 55 (DSI) with all %d modes read (MAXMODES %d)" % (n, MAXMODES),
          cc[1] == 0 and cc[2]["id"] == "55" and cc[2]["type"] == "16" and cc[2]["modes"] == str(n) and n <= MAXMODES, str(cc[2]))
    keys = [("w", "w"), ("h", "h"), ("vrefresh", "vrefresh"), ("clock_khz", "clock"), ("hss", "hss"), ("hse", "hse"),
            ("htotal", "htotal"), ("vss", "vss"), ("vse", "vse"), ("vtotal", "vtotal"), ("name", "name")]
    mr = [r[2] for r in by.get("mode", [])]
    want_idx = [i for i in range(n) if i < FSP_LOG_MODES or is_exp(L[i])]
    check("v27: mode records for indexes 0..%d plus every expected mode beyond (%s)" % (FSP_LOG_MODES - 1, want_idx[FSP_LOG_MODES:]),
          [int(m["idx"]) for m in mr] == want_idx, str([m["idx"] for m in mr][-5:]))
    ok = all([m[a] for a, _ in keys] == [str(L[int(m["idx"])][b]) for _, b in keys] and int(m["flags"], 16) == L[int(m["idx"])]["flags"]
             and int(m["type"], 16) == L[int(m["idx"])]["type"] and m["expected"] == ("1" if is_exp(L[int(m["idx"])]) else "0") for m in mr)
    check("v27: every logged mode record equals the model's mode (timing, flags, type, name, expected flag)", ok)
    eos = recs[-1][2]
    check("v27: the modes not logged are counted in opt_skipped (no optional record dropped otherwise: no opt_budget)",
          eos["opt_skipped"] == str(n - len(want_idx)) and "opt_budget" not in steps,
          "opt_skipped=%s, %d not logged" % (eos["opt_skipped"], n - len(want_idx)))
    check("v27: the property logging survives (prop_list/prop_vals present unless show-off-solid)",
          ("prop_list" in steps) == (by["start"][0][2]["mode"] != "show-off-solid"))
    cm = by["chosen_mode"][0][2]
    e = L[want_idx[FSP_LOG_MODES] if late else 0]
    if by["start"][0][2]["mode"] == "reset":
        wi, why = "-1", "crtc_current_expected"
    else:
        wi, why = ("250" if late else "0"), "expected_4128x2208_90"
    check("v27: the chosen mode is the 4128x2208 @ 90 timing (idx %s, %s), not a near-duplicate" % (wi, why),
          cm["idx"] == wi and cm["why"] == why and [cm[a] for a, _ in keys] == [str(e[b]) for _, b in keys]
          and cm["vtotal"] == "5158" and cm["clock_khz"] == "2020285" and cm["flags"] == "0x0", str(cm))
    check("v27: exit 0", ex["code"] == "0", str(ex))


def toomany_checks(recs, by, steps, ex, atoms):
    cc = by["chosen_connector"][0]
    check("toomany: 513 modes > MAXMODES 512 -> chosen_connector rc=-7, exit 30 too_many_modes, nothing set or committed",
          [(r[2]["id"], r[2]["modes"]) for r in by["connector"]] == [("33", "37"), ("55", "513"), ("65", "0")] and cc[1] == -7
          and ex["code"] == "30" and ex["reason"] == "too_many_modes" and ex["shown"] == "0" and not atoms
          and "mode" not in steps and "buffer" not in steps, str(ex))


def v07control(path):
    """the v0.7-limit control (MAXMODES 128) on the v2.7 mock: exactly Unit 2's r1 refusal"""
    recs, size = parse(path)
    got = [re.sub(r" elapsed_ms=\d+", "", r[4].split(" ", 3)[3]) for r in recs[4:10]]
    check("control: MAXMODES 128 (v0.7's limit) on the v2.7 connector set reproduces Unit 2's r1 records 4-9 (J-141)",
          got == UNIT2_R1 and [r[0] for r in recs[:4]] == ["start", "open", "version", "caps"] and recs[-1][0] == "eos"
          and len(recs) == 11, str(got))
W, H = 4128, 2208

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("CHECK %s %s %s" % (name, "PASS" if ok else "FAIL", detail)).rstrip())
    fails += 0 if ok else 1


def pct(s):
    out, i = bytearray(), 0
    while i < len(s):
        if s[i] == "%":
            out.append(int(s[i + 1:i + 3], 16)); i += 3
        else:
            out.append(ord(s[i])); i += 1
    return bytes(out)


def dec(v):
    """an FSP1 value as text: '-' is the empty token, %XX decoded"""
    return "" if v == "-" else pct(v).decode("latin-1")


def caps(k, variant=V_NONE):
    vig = k < 4 or k >= 16
    pidx = k if k < 4 else (k - 4 if k < 10 else (k - 10 if k < 16 else k - 16))
    smart = PLANES[k - 16] if k >= 16 else (PLANES[k - 6] if k >= 10 else None)
    up = b"20" if vig else b"1"
    if variant == V_VIG2DUP and k == 16:
        smart, pidx = None, 2
    if variant == V_VIG2UP3 and k == 2:
        up = b"3"
    if variant == V_VIG2UPNONE and k == 2:
        up = None
    if variant == V_DMADUP and k == 14:
        smart = 115
    b = (PF_VIG if vig else PF_DMA) + (b"scaler_step_ver=12290\n" if vig else b"") + b"max_linewidth=5120\n"
    if up is not None:
        b += b"max_upscale=" + up + b"\n"
    b += b"max_downscale=" + (b"4" if vig else b"1") + b"\nmax_horizontal_deci=0\nmax_vertical_deci=0\n" \
         b"max_per_pipe_bw=4500000000\nmax_per_pipe_bw_high=5200000000\n"
    if smart is not None:
        b += b"primary_smart_plane_id=%d\n" % smart
    b += b"pipe_idx=%d\n" % pidx
    b += b"cac_mode=2\ncac_parent_rec=4\ntrue_inline_rot_rev=513\ninverse_pma=1\n" if vig else b"inverse_pma=1\n"
    return b


def genblob(n):
    return bytes(1 + i % 47 for i in range(n))


def kvint(b, key):
    for line in b.split(b"\n"):
        if line.startswith(key + b"="):
            v = line[len(key) + 1:]
            return int(v) if v.isdigit() and 1 <= len(v) <= 9 else None
    return None


def val(kind, obj, name, i, k, active, variant):
    if kind == "conn":
        sp = {"CRTC_ID": 155, "mode_properties": 201, "capabilities": 202, "topology_name": 0, "dsc_mode": 0, "topology_control": 0}
        if name in sp:
            return sp[name]
    if kind == "crtc":
        if name == "ACTIVE":
            return active
        if name == "MODE_ID":
            return 209 if active else 0
    if kind == "plane":
        if name == "type":
            return 1 if k < 3 else 0
        if name in ("FB_ID", "zpos"):
            return 0
        if name == "CRTC_ID":
            if variant == V_VIG1OTHER and k == 1:
                return 156
            return 155 if (k < 4 and active) else 0
        if i == 10:
            return obj << 20
        if name == "capabilities":
            return 399 if (variant == V_CAPSMISSING and k == 1) else 300 + k
    return obj * 1000 + i


def letter(name):
    if name in ("topology_name", "panel_mode"):
        return "e"
    if name in ("dsc_mode", "DPMS", "blend_op", "type"):
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


def parse(path):
    data = open(path, encoding="latin-1").read()
    lines = data.split("\n")
    check("ends_with_newline", lines[-1] == "")
    recs, framing = [], True
    for i, l in enumerate(lines[:-1]):
        m = REC.match(l)
        if not m:
            framing = False; break
        body = l[:l.rindex(" len=")]
        if int(m.group(6)) != len(body) or int(m.group(7), 16) != zlib.crc32(body.encode("latin-1")) & 0xffffffff or int(m.group(2)) != i:
            framing = False; break
        recs.append((m.group(3), int(m.group(4)), dict(KV.findall(m.group(5))), len(l) + 1, body))
    check("framing_len_crc_seq_gapfree", framing, "%d records, %d bytes" % (len(recs), len(data)))
    if recs:
        check("eos_last_after_exit", recs[-1][0] == "eos" and recs[-2][0] == "exit" and recs[-1][2].get("records") == str(len(recs))
              and recs[-1][2].get("dropped") == "0" and recs[-1][2].get("overflows") == "0", str(recs[-1][2]))
    return recs, len(data)


OPT = {"blob", "plane_caps", "prop_list", "prop_vals"}


def opt_bytes_ok(recs, budget, essential_caps):
    eos = recs[-1][2]
    measured = sum(r[3] for r in recs if (r[0] in OPT and not (r[0] == "plane_caps" and essential_caps))
                   or (r[0] == "mode" and int(r[2]["idx"]) >= FSP_ESS_MODES))   # v0.7.1: optional mode records
    ob = int(eos.get("opt_bytes", "-1"))
    check("opt_bytes_reported_equals_measured_and_within_budget", ob == measured and ob <= budget,
          "opt_bytes=%d measured=%d budget=%d" % (ob, measured, budget))
    return ob


def blob_parts(recs, what):
    return sorted([r[2] for r in recs if r[0] == "blob" and r[2].get("what") == what], key=lambda k: int(k.get("part", "0")))


def check_blob(recs, what, want, label, allow_cut=False):
    parts = blob_parts(recs, what)
    if len(want) > 8192:
        check(label + "_over_8192_length_only", len(parts) == 1 and parts[0].get("read_rc") == "-27" and parts[0].get("bytes") == str(len(want)),
              str(parts[:1]))
        return
    data = b"".join(pct(k["data"]) if k.get("data", "-") != "-" else b"" for k in parts)
    if allow_cut and parts and len(data) < len(want):
        np = (len(want) + 239) // 240
        check(label + "_cut_by_the_opt_budget_prefix_intact", want.startswith(data) and all(k["parts"] == str(np) for k in parts),
              "%d of %d bytes before the budget" % (len(data), len(want)))
        return
    check(label + "_roundtrip", data == want and all(k["bytes"] == str(len(want)) for k in parts), "%d bytes in %d parts" % (len(data), len(parts)))


def check_plane_caps(recs, variant, essential):
    pc = [r for r in recs if r[0] == "plane_caps"]
    check("plane_caps_every_plane_in_order", [int(r[2]["plane"]) for r in pc] == PLANES, "%d records" % len(pc))
    ok = True
    for k, r in enumerate(pc):
        kv = r[2]
        b = caps(k, variant)
        missing = variant == V_CAPSMISSING and k == 1
        if missing:
            ok &= kv["read_rc"] == "-2" and kv["caps_bytes"] == "0" and kv["pipe_idx"] == "none" and kv["max_upscale"] == "none"
            continue
        sm = kvint(b, b"primary_smart_plane_id")
        mu = kvint(b, b"max_upscale")
        ok &= kv["read_rc"] == "0" and kv["caps_bytes"] == str(len(b)) and kv["max_linewidth"] == "5120"
        ok &= kv["pipe_idx"] == str(kvint(b, b"pipe_idx")) and kv["max_upscale"] == ("none" if mu is None else str(mu))
        ok &= kv["smart"] == ("none" if sm is None else str(sm)) and kv["zpos"] == "0"
        ok &= kv["nv12"] == ("1" if (k < 4 or k >= 16) else "0")
        ok &= (r[1] == 0)
    check("plane_caps_values_rederived_from_the_mock_blobs (pipe_idx, max_upscale, primary_smart_plane_id, zpos, nv12)", ok)
    if essential:
        check("plane_caps_essential_in_quad_modes (never cut by the opt budget)", len(pc) == 20)


def propsim(mode, path):
    recs, size = parse(path)
    steps = [r[0] for r in recs]
    kind = {"full": "show", "repeat": "show", "off": "show-off", "quad": "show-off-quad", "solid": "show-off-solid"}[mode]
    budget = FSP_OPT_MAX_SOLID if kind == "show-off-solid" else FSP_OPT_MAX
    quad = kind in ("show-off-quad", "show-off-solid")
    if mode == "repeat":
        b = [r for r in recs if r[0] == "opt_budget"]
        eos = recs[-1][2]
        check("repeat_third_pass_hits_the_budget_once", len(b) == 1 and b[0][1] == -28 and b[0][2]["max"] == str(FSP_OPT_MAX)
              and int(eos["opt_skipped"]) > 0 and int(eos["opt_bytes"]) <= FSP_OPT_MAX, str(b[0][2] if b else None))
        return
    check("no_overflow_or_budget_record", "overflow" not in steps and "opt_budget" not in steps)
    opt_bytes_ok(recs, budget, quad)
    topo = [r for r in recs if r[0] == "conn_topology"]
    t = topo[0][2] if topo else {}
    check("conn_topology_once_essential_sde_none_before_any_commit", len(topo) == 1 and t.get("topology_name") == "sde_none" and t.get("topology_val") == "0" and
          t.get("control_val") == "0" and t.get("dsc_mode_val") == "0" and t.get("mode_props_blob") == "201" and
          t.get("topology_prop") == str(1000 + CONN.index("topology_name")), str(t))
    check_blob(recs, "mode_properties", MODE_PROPS, "mode_properties_blob")
    if kind == "show-off":
        check("off_logs_topology_and_mode_properties_only", set(steps) == {"start", "conn_topology", "blob", "exit", "eos"}, str(sorted(set(steps))))
        return
    check_plane_caps(recs, V_NONE, quad)
    if kind == "show-off-solid":
        check("solid_logs_topology_mode_properties_and_plane_caps_only", set(steps) == {"start", "conn_topology", "blob", "plane_caps", "exit", "eos"},
              str(sorted(set(steps))))
        return
    check_blob(recs, "primary_capabilities", caps(0), "primary_capabilities_blob")
    check_blob(recs, "conn_capabilities", CONN_CAPS, "conn_capabilities_blob")
    lists, vals = {}, {}
    for s, rc, kv, n, body in recs:
        if s == "prop_list":
            names = [dec(x) for x in kv["names"].split(".")]
            lists.setdefault((kv["kind"], int(kv["ref"])), []).append((int(kv["first"]), names, kv["types"], int(kv["n"])))
        if s == "prop_vals":
            vals.setdefault((kv["kind"], int(kv["obj"])), []).append((int(kv["first"]), [int(x) for x in kv["vals"].split(".")], int(kv["n"]), int(kv["count"]), kv["same_names"]))
    ok = set(lists) == {("conn", 55), ("crtc", 155), ("plane", 71), ("plane", 106)}
    for (kd, ref), parts in lists.items():
        names, types = [], ""
        for first, nm, ty, n in sorted(parts):
            ok &= first == len(names) and len(nm) == n == len(ty)
            names += nm; types += ty
        want = {"conn": CONN, "crtc": CRTC, "plane": PLANE}[kd] if ref != 106 else PLANE[:49]
        ok &= names == want and types == "".join(letter(x) for x in want)
    check("prop_lists_names_and_types_roundtrip", ok, str(sorted(lists)))
    ok = len(vals) == 22
    objs = [("conn", 55, CONN, None), ("crtc", 155, CRTC, None)] + [("plane", p, PLANE[:49] if p == 106 else PLANE, k) for k, p in enumerate(PLANES)]
    for kd, obj, names, k in objs:
        got = []
        for first, vv, n, cnt, same in sorted(vals.get((kd, obj), [])):
            ok &= first == len(got) and len(vv) == n and cnt == len(names) and same == ("0" if obj == 106 else "1")
            got += vv
        ok &= got == [val(kd, obj, nm, i, k, 0, V_NONE) for i, nm in enumerate(names)]
    check("prop_vals_every_object_roundtrip", ok, "%d objects" % len(vals))
    order = [s for s in steps if s not in ("start", "exit", "eos")]
    want = ["conn_topology", "blob"] + ["plane_caps"] * 20 + ["blob"]
    check("record_order_essential_and_selection_inputs_first", order[:len(want)] == want)


# ---- the mock's atomic log ------------------------------------------------------------------
ATOM = re.compile(r"^MOCK atomic (test|commit)(\+modeset)? rc=(-?\d+) layout=(\S+) same_as_last_accepted_test=([01]) set=(.*)$")


def parse_mock(path):
    atoms, pixels = [], None
    for l in open(path, encoding="latin-1"):
        l = l.rstrip("\n")
        m = ATOM.match(l)
        if m:
            sets = []
            for tok in m.group(6).split():
                o, rest = tok.split(":", 1)
                nm, v = rest.rsplit("=", 1)
                sets.append((int(o), nm, int(v)))
            atoms.append(dict(test=m.group(1) == "test", ms=bool(m.group(2)), rc=int(m.group(3)), layout=m.group(4),
                              same=m.group(5) == "1", sets=sets))
        mp = re.match(r"^MOCK pixels n=(\d+) bg=(\d+) white=(\d+) red=(\d+) other=(\d+) black=(\d+)$", l)
        if mp:
            pixels = tuple(int(x) for x in mp.groups())
    return atoms, pixels


def stage_slots(zpos_by_slot, base_layer=False):
    """E15 model of the commit-time blend setup (sde_crtc.c:2053, :2134-2139; PIPES_PER_STAGE 2,
    sde_hw_ctl.h:74): per CRTC, stage = zpos + SDE_STAGE_0 (1) without a base layer, and
    stage_idx = zpos_cnt[stage]++ into stage[S][2]; an index >= 2 aliases into the next stage."""
    cnt, slots, alias = {}, {}, 0
    for z in zpos_by_slot:
        st = z + (0 if base_layer else 1)
        i = cnt.get(st, 0)
        cnt[st] = i + 1
        if i >= 2:
            alias += 1
        slots.setdefault(st, []).append(i)
    return cnt, alias


def atomic_check_ok(planes_xz):
    """E11 model of the atomic check: at most 2 planes per (stage, half); a pair sharing a stage in a
    half contiguous in x with equal y/h; no plane crosses x = 2064 (sspp_layout none)."""
    halves = {}
    for x, w, z in planes_xz:
        if x < 2064 < x + w:
            return False
        halves.setdefault((z, x >= 2064), []).append((x, w))
    for key, ps in halves.items():
        if len(ps) > 2:
            return False
        if len(ps) == 2:
            ps.sort()
            if ps[0][0] + ps[0][1] != ps[1][0]:
                return False
    return True


def expected_selection(variant):
    vig = [71, 97, 100, 103]
    dma = [115, 134, 112, 131]
    why_v = why_d = None
    if variant == V_VIG2DUP:
        vig, why_v = None, "ambiguous"
    if variant in (V_VIG2UP3, V_VIG2UPNONE, V_VIG1OTHER, V_CAPSMISSING):
        vig, why_v = None, "missing"
    if variant == V_DMADUP:
        dma, why_d = None, "ambiguous"
    return vig, why_v, dma, why_d


def post_plane_class(pp):
    """the classifier rule of DESIGN §6.5/§11.1 (E17): match = SRC_X 0/1032/2064/3096 and CRTC_X
    0/1032/0/1032 (converted); finding-unconverted = CRTC_X 0/1032/2064/3096; else mismatch."""
    sx = [int(p["src_x"]) for p in pp]
    cx = [int(p["crtc_x"]) for p in pp]
    rest = all(p["src_w"] == "1032" and p["crtc_w"] == "1032" and p["src_y"] == "0" and p["crtc_y"] == "0" and p["src_h"] == "2208"
               and p["crtc_h"] == "2208" and p["src_frac"] == "0" for p in pp) and [p["zpos"] for p in pp] == ["0", "0", "1", "1"]
    if len(pp) != 4 or sx != [0, 1032, 2064, 3096] or not rest:
        return "mismatch"
    if cx == [0, 1032, 0, 1032]:
        return "match"
    if cx == [0, 1032, 2064, 3096]:
        return "finding-unconverted"
    return "mismatch"


def sim(name, path, mock):
    kind, active, accept, noconv, variant, mp_len, cc_len = SCEN[name]
    recs, size = parse(path)
    atoms, pixels = parse_mock(mock)
    steps = [r[0] for r in recs]
    by = {}
    for r in recs:
        by.setdefault(r[0], []).append(r)
    start = by["start"][0][2]
    check("start_mode_ver", start.get("mode") == kind and start.get("ver") == "0.7.1", str(start.get("mode")))
    if name == "reset-toomany":
        toomany_checks(recs, by, steps, by["exit"][0][2], atoms)
        return
    if "-v27" in name:
        v27_checks(name, recs, by, steps, by["exit"][0][2])
    if kind in ("show", "show-off", "show-off-quad", "show-off-solid"):
        wr, we = ("0", "direct") if name == "quad-vig-roll0-direct" else ("21", "swap")
        check("start_picture_options_roll_%s_eyes_%s" % (wr, we), start.get("roll") == wr and start.get("eyes") == we, str(start))
    quad = kind in ("show-off-quad", "show-off-solid")
    budget = FSP_OPT_MAX_SOLID if kind == "show-off-solid" else FSP_OPT_MAX
    ex = by["exit"][0][2]
    check("stream_within_the_step_cap", size <= CAP[kind], "%d <= %d bytes" % (size, CAP[kind]))
    if "opt_budget" in steps:
        b = by["opt_budget"][0]
        check("opt_budget_record_once_at_the_kind_budget", len(by["opt_budget"]) == 1 and b[2]["max"] == str(budget), str(b[2]))
    opt = opt_bytes_ok(recs, budget, quad)
    essential = size - opt
    print("INFO essential_bytes=%d opt_bytes=%d total=%d cap=%d (essential + budget = %d)" % (essential, opt, size, CAP[kind], essential + budget))
    if name.endswith("-max"):
        check("max_stream_hits_the_opt_budget", "opt_budget" in steps)
        check("max_bound: essential + the full budget <= the cap", essential + budget <= CAP[kind],
              "%d + %d = %d <= %d" % (essential, budget, essential + budget, CAP[kind]))
    # never set: anything outside the allowed set; zpos only in quad attempts
    set_names = {nm for a in atoms for (_, nm, _) in a["sets"]}
    check("set_properties_subset_of_v05_set_plus_zpos", set_names <= ALLOWED_SET and not (set_names & NEVER_SET), str(sorted(set_names)))
    for a in atoms:
        zs = [(o, v) for (o, nm, v) in a["sets"] if nm == "zpos"]
        if a["layout"] in ("quad_vig", "quad_dma"):
            on = [o for (o, nm, v) in a["sets"] if nm == "FB_ID" and v]
            if not ([o for o, _ in zs] == on and [v for _, v in zs] == [0, 0, 1, 1]):
                check("zpos_exactly_four_planes_0011_by_slot", False, str(zs))
                break
        elif zs:
            check("zpos_only_in_quad_attempts", False, "%s sets zpos" % a["layout"])
            break
    else:
        check("zpos_only_in_quad_attempts_on_the_four_planes_values_0011_by_slot", True)
    commits = [a for a in atoms if not a["test"]]
    if kind == "reset":
        check("reset: at most two real commits (A reset_off, B the re-enable), each equal to the last accepted test",
              len(commits) <= 2 and all(a["same"] and a["rc"] == 0 for a in commits), str([(a["layout"], a["same"]) for a in commits]))
        reset_checks(name, active, accept, by, steps, atoms, commits, ex, pixels)
        if mp_len:
            check_blob(recs, "mode_properties", genblob(mp_len), "mode_properties_blob_%d" % mp_len, allow_cut=True)
        elif active:
            check_blob(recs, "mode_properties", MODE_PROPS, "mode_properties_blob")
        return
    check("at_most_one_real_commit_and_it_equals_the_last_accepted_test", len(commits) <= 1 and all(a["same"] and a["rc"] == 0 for a in commits),
          str([(a["layout"], a["same"]) for a in commits]))
    tc = [(r[2]["attempt"], r[2]["modeset"], r[2]["layout"], r[1]) for r in by.get("test_commit", [])]
    if kind == "show":
        # v0.5 behaviour (trial (iii-b) run 1, relays/FS-A-012-raw pattern1): byte-identical plan, same attempts
        plan = by["plan"][0][4]
        check("show_plan_record_byte_identical_to_v05", plan.endswith(" step=plan rc=0 attempts=4 use_current=1 modeset_allowed=1 helper=1"), plan)
        want = [("0", "0", "single", 4, 16, 3, -22), ("1", "0", "split", 4, 24, 2, -22), ("2", "1", "single", 6, 19, 3, -7), ("3", "1", "split", 6, 27, 2, 0)]
        got = [(r[2]["attempt"], r[2]["modeset"], r[2]["layout"], int(r[2]["objs"]), int(r[2]["props"]), int(r[2]["planes_off"]), r[1]) for r in by["test_commit"]]
        check("show_test_commits_as_trial_iiib_run1 (attempt, modeset, layout, objs, props, planes_off, rc)", got == want, str(got))
        c = by["commit"][0][2]
        check("show_commit_split_modeset_attempt3", c["layout"] == "split" and c["attempt"] == "3" and c["modeset"] == "1" and ex["code"] == "0")
        pp = [r[2] for r in by.get("post_plane", [])]
        check("show_post_plane_pri_and_helper (helper CRTC_X 2064 converted to 0, E17)", [p["plane"] for p in pp] == ["71", "97"] and
              [p["crtc_x"] for p in pp] == ["0", "0"] and [p["src_x"] for p in pp] == ["0", "2064"] and [p["zpos"] for p in pp] == ["0", "0"], str(pp))
        check("show_no_zpos_set", "zpos" not in set_names)
    elif kind == "show-off":
        check("off_v05_attempts_single_then_split_modeset", [t[:3] for t in tc] == [("0", "1", "single"), ("1", "1", "split")] and ex["code"] == "0", str(tc))
    else:
        if active:
            check("quad_active_crtc_exit31_no_test_only_no_commit", ex["code"] == "31" and by["precondition"][0][1] == -16 and not atoms
                  and "plan" not in steps, str(ex))
            return
        check("precondition_inactive_proven", by["precondition"][0][1] == 0 and by["precondition"][0][2]["active"] == "0")
        plan = by["plan"][0][2]
        vig, why_v, dma, why_d = expected_selection(variant)
        # the lists are in the FSP1 value charset (no %XX): elements joined by '.', a pipe is <type>-<idx>
        want_v = ".".join(map(str, vig)) if vig else "unavailable-" + why_v
        want_d = ".".join(map(str, dma)) if dma else "unavailable-" + why_d
        check("plan_quad_vig_%s" % want_v, plan["quad_vig"] == want_v, plan["quad_vig"])
        check("plan_quad_dma_%s" % want_d, plan["quad_dma"] == want_d, plan["quad_dma"])
        check("plan_values_need_no_percent_encoding (a digit-splitting reader gets the right numbers)", "%" not in by["plan"][0][4])
        check("plan_pipe_types_from_max_upscale", plan["pipe_vig"] == ("vig-0.vig-1.vig-2.vig-3" if vig else "-") and
              plan["pipe_dma"] == ("dma-3.dma-3.dma-2.dma-2" if dma else "-") and plan["max_upscale_vig"] == ("20.20.20.20" if vig else "-")
              and plan["max_upscale_dma"] == ("1.1.1.1" if dma else "-"), "%s / %s" % (plan["pipe_vig"], plan["pipe_dma"]))
        check("plan_zpos_before_and_zpos_set", plan["zpos_before_vig"] == ("0.0.0.0" if vig else "-") and
              plan["zpos_before_dma"] == ("0.0.0.0" if dma else "-") and plan["zpos_set"] == "0.0.1.1")
        check("plan_splash_set", plan["splash_set"] == ("match" if vig else "differs"), plan["splash_set"])
        check("plan_attempts_and_split_probe", plan["attempts"] == str(1 + bool(vig) + bool(dma)) and plan["split_probe"] == "1")
        # the order and the probe; an unavailable attempt issues no TEST_ONLY
        want_tc = [("0", "1", "split_probe")]
        if vig:
            want_tc.append(("1", "1", "quad_vig"))
        acc_v = vig is not None and "quad_vig" in accept
        if dma and not acc_v:
            want_tc.append(("2", "1", "quad_dma"))
        check("attempt_order_split_probe_quad_vig_quad_dma (unavailable: no TEST_ONLY)", [t[:3] for t in tc] == want_tc, str(tc))
        tests = [a for a in atoms if a["test"]]
        check("mock_saw_the_same_test_only_layouts", [a["layout"] for a in tests] == ["split+modeset"] + [t[2] for t in want_tc[1:]],
              str([a["layout"] for a in tests]))
        check("split_probe_never_committed", all(a["layout"] in ("quad_vig", "quad_dma") for a in commits))
        com = None
        if acc_v:
            com = "quad_vig"
        elif dma and "quad_dma" in accept:
            com = "quad_dma"
        if com is None:
            check("no_quad_accepted_exit50_nothing_committed", ex["code"] == "50" and ex["reason"] == "no_quad_accepted" and not commits
                  and "commit" not in steps and ex["shown"] == "0", str(ex))
            return
        c = by["commit"][0][2]
        check("committed_%s" % com, c["layout"] == com and c["modeset"] == "1" and c["attempt"] == ("1" if com == "quad_vig" else "2")
              and len(commits) == 1 and commits[0]["layout"] == com and ex["code"] == "0" and ex["shown"] == "1", str(c))
        # the committed request: geometry, zpos, stage slots (E15), atomic check (E11)
        req = commits[0]["sets"]
        geo = []
        for o in [o for (o, nm, v) in req if nm == "FB_ID" and v]:
            d = {nm: v for (oo, nm, v) in req if oo == o}
            geo.append((o, d["SRC_X"] >> 16, d["CRTC_X"], d["SRC_W"] >> 16, d["CRTC_W"], d["SRC_H"] >> 16, d["CRTC_H"], d["SRC_Y"], d["CRTC_Y"], d["zpos"]))
        want_ids = [71, 97, 100, 103] if com == "quad_vig" else [115, 134, 112, 131]
        check("commit_geometry_4x1032_global_x_no_scaling", [g[0] for g in geo] == want_ids and
              all(g[1] == g[2] == 1032 * k and g[3] == g[4] == 1032 and g[5] == g[6] == 2208 and g[7] == g[8] == 0 for k, g in enumerate(geo)), str(geo))
        z = [g[9] for g in geo]
        cnt, alias = stage_slots(z)
        cnt0, alias0 = stage_slots([0, 0, 0, 0])
        check("E15_stage_slots: {0,0,1,1} fills stage 1 and stage 2 with 2 pipes each", cnt == {1: 2, 2: 2} and alias == 0, str(cnt))
        check("E15_negative_control: {0,0,0,0} overflows stage 1 (2 pipes alias into the next stage)", cnt0 == {1: 4} and alias0 == 2, str(cnt0))
        check("E11_atomic_check_model_passes_both (why the {0,0,0,0} bug survives TEST_ONLY)",
              atomic_check_ok([(g[2], g[4], g[9]) for g in geo]) and atomic_check_ok([(g[2], g[4], 0) for g in geo]))
        ps = by["post_state"][0][2]
        check("post_state_after_the_commit (active, mode, topology, votes as GET)", ps["active"] == "1" and ps["mode_id"] == "208" and
              ps["topology_name"] == "sde_quadpipe_dsc4hsmerge" and ps["topology_val"] == "14" and ps["core_clk"] == str(155 * 1000 + CRTC.index("core_clk"))
              and ps["getcrtc_rc"] == "0" and ps["mode_valid"] == "1" and ps["fb"] == "207", str(ps))
        pp = [r[2] for r in by.get("post_plane", [])]
        cls = post_plane_class(pp)
        check("post_plane_slots_planes", [p["slot"] for p in pp] == ["0", "1", "2", "3"] and [int(p["plane"]) for p in pp] == want_ids
              and all(p["crtc_id"] == "155" and p["fb_id"] == "207" for p in pp))
        if noconv:
            check("post_plane_unconverted_crtc_x_is_the_reported_finding (E17)", cls == "finding-unconverted", cls)
        else:
            check("post_plane_matches_the_plan_after_the_right_half_conversion (SRC_X 0/1032/2064/3096, CRTC_X 0/1032/0/1032, zpos 0/0/1/1)",
                  cls == "match", "%s %s" % (cls, [(p["src_x"], p["crtc_x"], p["zpos"]) for p in pp]))
        order = [s for s in steps if s in ("commit", "post_state", "post_plane", "hold_start")]
        check("post_records_between_commit_and_hold_start", order == ["commit", "post_state"] + ["post_plane"] * 4 + ["hold_start"], str(order))
    # mode_properties / connector caps blobs
    if mp_len:
        check_blob(recs, "mode_properties", genblob(mp_len), "mode_properties_blob_%d" % mp_len, allow_cut=True)
    elif kind != "show-off":
        check_blob(recs, "mode_properties", MODE_PROPS, "mode_properties_blob")
    if kind in ("show-off-quad", "show") and cc_len == 0 and "conn_capabilities" in {r[2].get("what") for r in recs if r[0] == "blob"}:
        check_blob(recs, "conn_capabilities", CONN_CAPS, "conn_capabilities_blob")
    if kind != "show-off":
        check_plane_caps(recs, variant, quad)
    # the drawn buffer
    if pixels:
        n, bg, white, red, other, black = pixels
        if kind == "show-off-solid":
            check("solid_buffer_every_pixel_00FF0000", red == n == W * H and bg == white == other == 0, str(pixels))
        else:
            ppm = white * 1000000 // n
            check("pattern_buffer_two_levels_white_ppm_within_37618", bg + white == n == W * H and red == other == black == 0 and ppm <= 37618,
                  "white_ppm=%d" % ppm)
    elif ex["code"] in ("0", "50"):
        check("buffer_drawn", False, "no MOCK pixels line")


def reset_checks(name, active, accept, by, steps, atoms, commits, ex, pixels):
    """v0.7 reset: A = reset_off (only zero values: connector CRTC_ID, CRTC MODE_ID and ACTIVE, the bound planes'
    FB_ID and CRTC_ID), B = the v0.5 modeset attempts on the black buffer, then close."""
    pre = by["reset_precondition"][0]
    if not active:
        check("reset_inactive: precondition state already_inactive, exit 0 already_inactive, no TEST_ONLY, no commit, no buffer",
              pre[2]["state"] == "already_inactive" and ex["code"] == "0" and ex["reason"] == "already_inactive" and not atoms
              and "buffer" not in steps and ex["shown"] == "0", str(ex))
        return
    check("reset: precondition active", pre[1] == 0 and pre[2]["state"] == "active")
    check("reset: the re-enable mode is the handed-over expected mode", by["chosen_mode"][0][2]["why"] == "crtc_current_expected"
          and by["chosen_mode"][0][2]["name"] == "4128x2208x90vid")
    check("reset: the buffer is black (buffer black=1; every pixel 0x00000000)", by["buffer"][0][2].get("black") == "1"
          and pixels is not None and pixels[5] == pixels[0] == W * H, str(pixels))
    plan = by["reset_plan"][0][2]
    check("reset_plan: 6 objects, 11 properties, 4 planes off, 2 re-enable attempts", plan["objs"] == "6" and plan["props"] == "11"
          and plan["planes_off"] == "4" and plan["reenable_attempts"] == "2" and plan["helper"] == "1", str(plan))
    a0 = atoms[0]
    want_a = sorted([(55, "CRTC_ID", 0), (155, "MODE_ID", 0), (155, "ACTIVE", 0)] +
                    [(pl, nm, 0) for pl in (71, 97, 100, 103) for nm in ("FB_ID", "CRTC_ID")])
    check("reset A: the first request (TEST_ONLY, ALLOW_MODESET) sets exactly the connector CRTC_ID, MODE_ID, ACTIVE and the 4 bound "
          "planes' FB_ID/CRTC_ID, every value 0", a0["test"] and a0["ms"] and a0["layout"] == "reset_off" and sorted(a0["sets"]) == want_a,
          str(a0["sets"]))
    check("reset: never sets zpos", all(nm != "zpos" for a in atoms for (_, nm, _) in a["sets"]))
    tc = [(r[2]["attempt"], r[2]["layout"], r[1]) for r in by.get("test_commit", [])]
    if "reset_off" not in accept:
        check("reset_off rejected: exit 50 reset_off_rejected, nothing committed", ex["code"] == "50" and ex["reason"] == "reset_off_rejected"
              and not commits and tc == [("0", "reset_off", -22)], str(tc))
        return
    check("reset A committed once (= its test), post_state inactive without a mode, the 4 planes without CRTC and FB",
          commits[0]["layout"] == "reset_off" and by["commit"][0][2]["layout"] == "reset_off"
          and by["post_state"][0][2]["active"] == "0" and by["post_state"][0][2]["mode_id"] == "0"
          and [p[2]["plane"] for p in by["post_plane"][:4]] == ["71", "97", "100", "103"]
          and all(p[2]["crtc_id"] == "0" and p[2]["fb_id"] == "0" for p in by["post_plane"][:4]))
    check("reset B: the v0.5 modeset attempts on the black buffer: single (rejected -7 as on v66) then split",
          tc[1:] == [("1", "reset_on_single", -7), ("2", "reset_on_split", 0 if "split+modeset" in accept else -22)], str(tc))
    tests_b = [a for a in atoms if a["test"]][1:]
    check("reset B: every re-enable request sets the connector CRTC_ID 155, a mode blob and ACTIVE 1 (ALLOW_MODESET)",
          len(tests_b) == 2 and all(a["ms"] and (55, "CRTC_ID", 155) in a["sets"] and (155, "ACTIVE", 1) in a["sets"]
                                    and any(o == 155 and nm == "MODE_ID" and v != 0 for (o, nm, v) in a["sets"]) for a in tests_b))
    if "split+modeset" not in accept:
        check("reset_on rejected: exit 50 reset_on_rejected after the one disable commit", ex["code"] == "50" and ex["reason"] == "reset_on_rejected"
              and len(commits) == 1, str(ex))
        return
    order = [s for s in steps if s in ("commit", "post_state", "post_plane", "reset_close", "exit")]
    check("reset B committed (split, = its test), post_state active, then reset_close before exit",
          len(commits) == 2 and commits[1]["layout"] == "split+modeset" and by["commit"][1][2]["layout"] == "reset_on_split"
          and by["post_state"][1][2]["active"] == "1"
          and order == ["commit", "post_state"] + ["post_plane"] * 4 + ["commit", "post_state", "post_plane", "post_plane", "reset_close", "exit"],
          str(order))
    check("reset: close_rc 0; exit 0 reset_done, shown 0 (only black was ever scanned out)", by["reset_close"][0][2]["close_rc"] == "0"
          and ex["code"] == "0" and ex["reason"] == "reset_done" and ex["shown"] == "0", str(ex))


def main():
    if sys.argv[1] == "propsim":
        propsim(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "sim":
        sim(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == "v07control":
        v07control(sys.argv[2])
    else:
        raise SystemExit(__doc__)
    sys.exit(1 if fails else 0)


main()
