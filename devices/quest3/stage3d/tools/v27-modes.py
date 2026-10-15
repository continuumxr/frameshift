#!/usr/bin/env python3
"""The DSI connector's mode list on Quest 3 Horizon OS v2.7, computed from the device tree the way the v2.7 display
driver computes it (fs-pattern v0.7.1, J-141). Offline; stdlib only; an implementation independent of the C mock in
src/fs-pattern.c (ps_gen_v27 / v27_list), which must print the same list (`fs-pattern-unittest v27modes`).

usage: v27-modes.py PROVENANCE_DT_TXT [STAGE3C_PHASE_R2_RAW]

Model (kernel 5243367.3600.520, techpack/display/msm/dsi; README §3a):
  dsi_panel_parse_dfps_range: no qcom,mdss-dsi-refresh-rate-step-sizes -> every rate from max down to min; with step
    sizes (v66: 5, 24) -> max, every rate in between divisible by a step, min;
  dsi_display_get_modes: every timing node (2: qcom,mdss-dms-vid-type) x every rate; h values x 2 (two DSI controllers);
  dsi_display_get_dfps_timing (dfps_immediate_porch_mode_vfp, from the node's 90 Hz):
    vfp' = vfp +/- mult_frac(vtotal, |90 - r|, r); negative -> refused, vfp kept (the return code is ignored);
  dsi_convert_to_drm_mode: clock = (u32)(htotal * vtotal * r) / 1000 (wraps above 2^32), vrefresh =
    DIV_ROUND_CLOSEST(clock * 1000, htotal * vtotal), name "%dx%dx%dvid", PREFERRED at the panel framerate (90);
  dsi_conn_mode_valid: vrefresh != r -> the mode is not found (full-timing match) -> pruned;
  drm_mode_sort: stable; preferred first, then larger area, higher vrefresh, higher clock.
The DT values: provenance/dt.txt (v2.7: max refresh 0xf0, no step sizes, timing@0 porches; v66: max 0x78, steps 5 24);
min refresh 0x48, framerate 0x5a, timing@1 (1552x1664, VFP 0xb8c, HFP 0x26, HBP 0x36, HPW 0x14, VBP 0x1e, VPW 2) are the
same in v66 and v2.7 (so not in dt.txt's difference list): the merged v2.7 DT (dtb 0 + dtbo 11, panel
meta,eureka_panel_sharp; WSL ~/work/s3d-analysis/dt/v27-merged.dts).
With STAGE3C_PHASE_R2_RAW (relays/FS-A-012-raw/stage3c-b7cf9a0bfb559dcb/observe/collect/phase-r2.raw: Unit 1's v66 run)
the same model with the v66 values must give exactly the 24 mode records logged there (validation of the model).
Prints the list ("idx w h vrefresh clock hss hse htotal vss vse vtotal flags type name"), then "n=<count> digest=<crc32>"
and CHECK lines; exit 1 on any failed check.
"""
import base64
import re
import sys
import zlib

fails = 0


def check(name, ok, detail=""):
    global fails
    print(("CHECK %s %s %s" % (name, "PASS" if ok else "FAIL", detail)).rstrip())
    fails += 0 if ok else 1


def rates(rmin, rmax, steps):
    if not steps:
        return list(range(rmax, rmin - 1, -1))
    mid = [r for r in range(rmax - 1, rmin, -1) if any(r % s == 0 for s in steps)]
    return [rmax] + mid + [rmin]


def mult_frac(x, n, d):
    return (x // d) * n + ((x % d) * n) // d


def mode_list(rmin, rmax, steps, timings, node_fps=90, panel_fps=90):
    out = []
    for (ha, hfp, hpw, hbp, va, vfp, vpw, vbp) in timings:
        vt0 = va + vfp + vpw + vbp
        for r in rates(rmin, rmax, steps):
            add = mult_frac(vt0, abs(node_fps - r), r)
            v = vfp + add if node_fps > r else vfp - add
            if v < 0:
                v = vfp
            hd, hss = 2 * ha, 2 * ha + 2 * hfp
            hse = hss + 2 * hpw
            ht = hse + 2 * hbp
            vss = va + v
            vse = vss + vpw
            vt = vse + vbp
            prod = (ht * vt * r) & 0xFFFFFFFF
            if prod >= 1 << 31:
                prod -= 1 << 32
            clock = int(prod / 1000)                      # C division truncates toward zero
            clock &= 0xFFFFFFFF
            vref = (clock * 1000 + (ht * vt) // 2) // (ht * vt)
            if vref != r:
                continue                                    # pruned (mode_valid)
            out.append(dict(w=hd, h=va, vrefresh=vref, clock=clock, hss=hss, hse=hse, htotal=ht, vss=vss, vse=vse,
                            vtotal=vt, flags=0, type=8 if r == panel_fps else 0, name="%dx%dx%dvid" % (hd, va, vref)))
    # drm_mode_sort: stable (list_sort), drm_mode_compare
    return sorted(out, key=lambda m: (-((m["type"] & 8) != 0), -(m["w"] * m["h"]), -m["vrefresh"], -m["clock"]))


def line(i, m):
    return "%d %d %d %d %d %d %d %d %d %d %d 0x%x 0x%x %s" % (i, m["w"], m["h"], m["vrefresh"], m["clock"], m["hss"], m["hse"],
                                                           m["htotal"], m["vss"], m["vse"], m["vtotal"], m["flags"], m["type"], m["name"])


def dt_values(path):
    t = open(path, encoding="utf-8").read()
    def diff(prop):
        m = re.search(r"^  %s\s+A (\S+)\s*\n\s+B (\S*)" % re.escape(prop), t, re.M)
        return (m.group(1), m.group(2)) if m else (None, None)
    def merged(prop):
        m = re.search(r"^%s = <(0x[0-9a-f]+)>;" % re.escape(prop), t, re.M)
        return int(m.group(1), 16) if m else None
    return diff, merged


def v66_records(raw):
    d = {}
    for ln in open(raw, "rb").read().decode("latin1").splitlines():
        m = re.match(r"FSB1 DATA i=(\d+) s=(\w) n=(\d+) (\S*)", ln)
        if m:
            d.setdefault((m.group(1), m.group(2)), []).append((int(m.group(3)), m.group(4)))
    recs = []
    for k in sorted(d):
        txt = base64.b64decode("".join(x for _, x in sorted(d[k]))).decode("latin1")
        for r in txt.splitlines():
            if " step=mode " in r:
                kv = dict(re.findall(r" (\w+)=(\S+)", r.split(" len=")[0]))
                recs.append(kv)
    return recs


def main():
    diff, merged = dt_values(sys.argv[1])
    maxr = diff("qcom,mdss-dsi-max-refresh-rate")
    steps = diff("qcom,mdss-dsi-refresh-rate-step-sizes")
    check("dt: max refresh v66 0x78 (120), v2.7 0xf0 (240)", maxr == ("00000078", "000000f0"), str(maxr))
    check("dt: step sizes v66 5 24, v2.7 absent", steps == ("0000000500000018", "(absent)"), str(steps))
    t0 = (merged("qcom,mdss-dsi-panel-width"), merged("qcom,mdss-dsi-h-front-porch"), merged("qcom,mdss-dsi-h-pulse-width"),
          merged("qcom,mdss-dsi-h-back-porch"), merged("qcom,mdss-dsi-panel-height"), merged("qcom,mdss-dsi-v-front-porch"),
          merged("qcom,mdss-dsi-v-pulse-width"), merged("qcom,mdss-dsi-v-back-porch"))
    check("dt: v2.7 timing@0 = 2064 38 20 54 / 2208 2918 2 30, framerate 90", t0 == (2064, 38, 20, 54, 2208, 2918, 2, 30)
          and merged("qcom,mdss-dsi-panel-framerate") == 90, str(t0))
    T1 = (1552, 38, 20, 54, 1664, 2956, 2, 30)            # timing@1, unchanged v66 -> v2.7 (merged DT)
    L = mode_list(72, 240, [], [t0, T1])
    text = "".join(line(i, m) + "\n" for i, m in enumerate(L))
    sys.stdout.write(text)
    print("n=%d digest=%08x" % (len(L), zlib.crc32(text.encode("ascii")) & 0xFFFFFFFF))
    exp = [i for i, m in enumerate(L) if m["w"] == 4128 and m["h"] == 2208 and m["vrefresh"] == 90 and not m["flags"] & 0x10]
    check("v2.7: 305 modes (Unit 2's record, J-141: connector 55 modes=305)", len(L) == 305, str(len(L)))
    check("v2.7: 338 built before the pruning (2 x 169); pruned = timing@0 at 208..240 (33)",
          2 * len(rates(72, 240, [])) == 338 and sum(m["w"] == 4128 for m in L) == 136 and sum(m["w"] == 3104 for m in L) == 169)
    check("v2.7: exactly one 4128x2208 @ 90 mode, index 0, PREFERRED, the v66 timing (clock 2020285, vtotal 5158)",
          exp == [0] and L[0]["clock"] == 2020285 and L[0]["vtotal"] == 5158 and L[0]["htotal"] == 4352 and L[0]["type"] == 8,
          str(exp))
    if len(sys.argv) > 2:
        v66 = mode_list(72, 120, [5, 24], [t0, T1])
        rec = v66_records(sys.argv[2])
        keys = ["w", "h", "vrefresh", "clock", "hss", "hse", "htotal", "vss", "vse", "vtotal", "name"]
        got = [[r.get("clock_khz" if k == "clock" else k) for k in keys] + [int(r.get("type", "0x0"), 16)] for r in rec]
        want = [[str(m[k]) for k in keys] + [m["type"]] for m in v66]
        check("model validated on v66: the same model with v66's DT (max 120, steps 5 24) gives exactly the %d mode "
              "records of Unit 1's stage-3c run (phase-r2)" % len(want), got == want and len(want) == 24,
              "logged %d, model %d" % (len(got), len(want)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
