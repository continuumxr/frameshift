#!/usr/bin/env python3
"""FrameShift stage 3d: compare two flattened device trees node by node (raw property bytes; offline, stdlib only).
usage: dt-props-compare.py A.dtb B.dtb NODE_PATH...
Prints, per node, every property whose bytes differ (phandle values differ between builds when the numbering
shifts: such properties are reported too and must be read as references). Used for the v66 -> v2.7 display
re-check (stage3d/IMAGE.md "Display assumptions")."""
import struct, sys

def parse(p):
    d = open(p, "rb").read()
    magic, tot, off_s, off_str, off_mem, ver, lcv, bcpu, sz_str, sz_s = struct.unpack(">10I", d[:40])
    assert magic == 0xd00dfeed
    strs = d[off_str:off_str + sz_str]
    i = off_s; stack = []; nodes = {}
    while True:
        tok, = struct.unpack(">I", d[i:i + 4]); i += 4
        if tok == 1:
            e = d.index(b"\0", i); name = d[i:e].decode(); i = (e + 4) & ~3
            stack.append(name); path = "/" + "/".join(stack[1:]); nodes[path] = {}
        elif tok == 2:
            stack.pop()
        elif tok == 3:
            ln, no = struct.unpack(">II", d[i:i + 8]); i += 8
            pn = strs[no:strs.index(b"\0", no)].decode()
            nodes["/" + "/".join(stack[1:])][pn] = d[i:i + ln]; i = (i + ln + 3) & ~3
        elif tok == 4: continue
        elif tok == 9: break
    ph = {}
    for path, pr in nodes.items():
        for k in ("phandle", "linux,phandle"):
            if k in pr: ph[struct.unpack(">I", pr[k])[0]] = path
    return nodes, ph

def show(v, ph, name):
    if v and all(32 <= c < 127 or c == 0 for c in v) and v[-1] == 0 and v[0] != 0:
        return repr(v.decode(errors="replace").rstrip("\0").replace("\0", "|"))
    if len(v) % 4 == 0 and v:
        cells = struct.unpack(">%dI" % (len(v) // 4), v)
        ref = name.endswith("-supply") or name in ("qcom,dsi-ctrl", "qcom,dsi-phy", "qcom,dsi-panel", "clocks",
              "interrupt-parent", "pinctrl-0", "pinctrl-1", "pinctrl-2", "qcom,platform-te-gpio", "iommus",
              "interconnects", "power-domains", "phys", "usb-phy", "qcom,mdss-dsi-bl-pmic-pwm", "pwms",
              "qcom,dsi-default-panel", "qcom,sde-rsc", "qcom,dsi-display-active", "qcom,panel-supply-entries",
              "qcom,display-type", "qcom,dsi-panel-blu", "gpios") or name.endswith("-gpio") or name.endswith("-gpios") or name.startswith("meta,")
        return "<" + " ".join(("&" + ph[c]) if (ref and c in ph) else hex(c) for c in cells) + ">"
    return v.hex()

(a, pa), (b, pb) = parse(sys.argv[1]), parse(sys.argv[2])
for p in sys.argv[3:]:
    na, nb = a.get(p), b.get(p)
    print("## %s (A %s, B %s)" % (p, "present" if na is not None else "ABSENT", "present" if nb is not None else "ABSENT"))
    if na is None or nb is None: continue
    for k in sorted(set(na) | set(nb)):
        if k in ("phandle", "linux,phandle"): continue
        if na.get(k) != nb.get(k):
            def s(v):
                if v is None: return "(absent)"
                if v and v[-1] == 0 and all(32 <= c < 127 or c == 0 for c in v): return repr(v.rstrip(b"\0").decode())
                return v.hex() if len(v) <= 64 else v[:64].hex() + "...(%d B)" % len(v)
            print("  %-48s A %s\n  %-48s B %s" % (k, s(na.get(k)), "", s(nb.get(k))))
