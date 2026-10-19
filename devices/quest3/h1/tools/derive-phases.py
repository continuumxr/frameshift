#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""FrameShift H-1: derive the S/E/F phase lists for Quest 3 v2.7 (offline, stdlib only).

usage: derive-phases.py --dts V27.DTS --index DIR [--index DIR ...] --base95 LIST
                        [--write-lists OUTDIR] [--report FILE] [--check LISTDIR]

Inputs (read-only, local; none of them is committed):
  --dts     the compiled v2.7 runtime device tree, decompiled (dtc -I dtb -O dts);
  --index   a modules directory holding modules.dep / modules.softdep / modules.alias (the pinned v2.7
            vendor_boot ramdisk first, then vendor_dlkm, then odm_dlkm; a module named in several is taken
            from the first; dep lines are matched by basename);
  --base95  devices/quest3/stage3d/modules.load.v66 (K1a's 95; unchanged).

What it does, per profile (k1i, ts-t1, ts-t2, ts-t3b; PROFILES below):
  1. the profile's module set = the 95 + the profile's additions;
  2. S = the closure of the S roots, E = the closure of the E roots minus S, F = the rest of the set. A closure
     follows (a) modules.dep (symbol dependencies), (b) softdep pre: targets that exist in an index, and
     (c) DT probe suppliers: every phandle in a supplier property (clocks, *-supply, pinctrl-N,
     interrupt-parent, interrupts-extended, pwms, interconnects, mboxes, qcom,qmp, qcom,smem-states,
     iommus, io-channels, power-domains, hwlocks, phys, nvmem-cells, memory-region, *-gpios, dmas) of the
     root's DT node(s), recursively, plus the parent bus node, each node mapped to the module that drives it
     (modules.alias of:...C<compatible>, else COMPAT_MAP below, else "built in or no driver");
  3. checks (exit 1 on any): every module a closure needs is in the profile's set; nothing in NEVER is in a
     set; the k1i set is exactly the 95 minus DROP_LATER; every list is in an order where each modules.dep / softdep pre:
     dependency and each DT supplier comes earlier (S before E before F; ties keep the 95's order, then the
     additions' order);
  4. writes <profile>.phases (the loader's input) and a report with the reason for every module;
  5. --check LISTDIR: the committed lists must equal the derived ones byte for byte.
Facts only: the tool reads the DT and the module indexes as data; nothing is loaded, executed or copied.
"""
import argparse
import os
import re
import sys

# ---------------------------------------------------------------------------------------------------------
# Rules (our own; each cites the fact it rests on; README §4 is the human table).
# ---------------------------------------------------------------------------------------------------------
# S roots: what fs-thermald reads or writes (devices/thermal/PLAN.md §1.1, devices/quest3/ts/SENSORS.md),
# with the readiness predicate the loader checks (README §2.3).
S_ROOTS_ALL = [
    ("pwm-tach-fan.ko", "hwmon:pwmfan",
     "fan actuator and tach: hwmon pwmfan rpm/pwm/rpm_per_sec/silent_rpm, cdev pwm-tach-fan0 (PLAN §1.1, TCD §3.3)",
     ["pwm-tach-fan@0"]),
    ("qcom-cpufreq-hw.ko", "cpufreq:policy0,cpufreq:policy2",
     "CPU cap actuator: cpufreq policy0/policy2 scaling_max_freq, governor (PLAN §1.1, TCD §4.1)",
     ["qcom,cpufreq-hw"]),
    ("qcom-dload-mode.ko", "bound:1,param:qcom_dload_mode/download_mode",
     "softdog precondition (EXEC-SPEC E-2): the probe disables dump mode/SDI (qcom-dload-mode.c:306-340), so the device must be bound; the supervisor itself checks that download_mode reads 0",
     ["dload_mode"]),
]
S_ROOTS_T1 = [
    ("qcom_tsens.ko", "bound:2",
     "SoC thermal zones (cpu-*, cpuss-*, gpuss-*, nspss-*, ddr): two tsens controllers (SENSORS SOC; v27.dts thermal-sensor@c263000, @c265000)",
     ["thermal-sensor@c263000", "thermal-sensor@c265000"]),
    ("qcom-spmi-adc5-gen3.ko", "iiochan:pmk8550_die_temp",
     "PMIC ADC: soc-usr, pcb/pogo/usb-conn zones and the seven PMIC die channels (P7, J-171) (SENSORS PMIC)",
     ["vadc@9000"]),
    ("ufs_qcom.ko", "bound:1",
     "fs-metacfg reads Meta's thermal config from super (T1 on; design §2.7: ufs_qcom in phase S whenever the image reads super)",
     ["ufshc@1d84000"]),
]
S_ROOTS_T3B = [
    ("qcom_q6v5_pas.ko", "rproc:3000000.remoteproc-adsp",
     "ADSP: battery and charger path via pmic_glink (TCD §6.4; EXEC-SPEC v2.7 ADSP name). auto_boot is false for this SoC (qcom_q6v5_pas.c:967-979): the list proves probe and registration; the loader's explicit start (FSML_RPROC_START, required for T3b/R-1) must reach running within FSML_RPROC_WAIT, else S is not ready and the handoff is refused",
     ["=remoteproc-adsp@03000000", "=remoteproc-adsp@03000000/glink-edge", "=qcom,smem"]),
    ("qti_battery_charger_main.ko", "psy:battery",
     "battery psy: temp/voltage/current/capacity/status, usb online (PLAN §1.1, SENSORS BATT); registered at probe whether or not the ADSP runs (qti_battery_charger.c:3336), so it proves the driver, not live battery data",
     ["qcom,battery_charger", "qcom,pmic_glink"]),
    ("qrtr-smd.ko", "live",
     "IPC router transport to the ADSP (TS README §3 T3b); its rpmsg device appears only once the ADSP runs, so live is all the loader can prove (LIVE_ONLY_ROOTS)",
     []),
    ("bq27xxx_battery_i2c.ko", "psy:bq27z561-0",
     "battery gauge: zone bq27z561-0 is an input of all three virtual sensors (v27.dts battery/display/surface_virtual_sensor thermal-zones)",
     ["fuel-gauge@0x55"]),
    ("virtual_sensor.ko", "bound:3",
     "BATT and SKIN classes: batt-virt-usr, surf-virt-usr (SENSORS). The DT zones exist from boot (thermal_of.c:1171-1220), so readiness is the three bound oculus,virtual-sensor devices; each probe defers until the power-supply zones bq27z561-0 and battery exist (virtual_sensor.c:1035-1048, 915-985, 1198-1202)",
     ["battery_virtual_sensor", "surface_virtual_sensor", "display_virtual_sensor"]),
]
# E roots: essential closures (design H-1 item 2: display, USB gadget, LED; GPU at T2). "E" = required for the
# workload handoff in these profiles (FS-R-013 §10), "e" = essential but best-effort (a missing part is a
# device-health fault, rows 7-9/22, not a refusal).
E_ROOTS_ALL = [
    ("dwc3-msm.ko", "E", "udc:a600000.dwc3",
     "USB-C data: the development host link (the ACM gadget binds a600000.dwc3; row 16: E in development images)",
     ["ssusb@a600000"]),
    ("msm_drm.ko", "e", "path:/sys/class/drm/card0",
     "display (row 7) and the static KMS warning frame consumer (PLAN §1.1 notice consumers)",
     ["qcom,mdss_mdp@ae00000", "qcom,mdss_mdp@15600000"]),
    ("leds-qti-tri-led.ko", "e", "led:red,led:green,led:blue",
     "status LED: the thermal LED notice consumer and the stage LEDs (row 22; fs-noticed)",
     ["qcom,leds@ef00"]),
]
E_ROOTS_T2 = [
    ("msm_kgsl.ko", "e", "path:/sys/class/kgsl/kgsl-3d0/max_pwrlevel",
     "GPU cap actuator (PLAN §1.1: absent -> GPU caps skipped and logged; no GPU workload in TS, so best-effort)",
     ["qcom,kgsl-3d0@3d00000", "qcom,gmu@3d69000"]),
]
# Display-path modules of the 95 that the DT walk from the MDSS nodes does not reach (panel power and
# backlight are referenced from the panel and BLU nodes): kept with the display closure in phase E.
E_DISPLAY_EXTRA = ["tps65132-regulator.ko", "mp3314.ko", "blu_fw_driver.ko", "qti-fixed-regulator.ko",
                   "dispcc0-anorak.ko", "dispcc1-anorak.ko", "msm_ext_display.ko", "i2c-msm-geni.ko",
                   "spi-msm-geni.ko", "gpi.ko"]

PROFILES = {
    # K1i lineage: the 95 minus DROP_LATER (no tsens/ADC/ADSP); the fan, CPU caps and dload mode are still S.
    "k1i": dict(add=[], s=S_ROOTS_ALL, e=E_ROOTS_ALL),
    # TS T1: + tsens/ADC (TS README §3) and the super read (fs-metacfg).
    "ts-t1": dict(add=["qcom_tsens.ko", "qcom-vadc-common.ko", "qcom-spmi-adc5-gen3.ko"],
                  s=S_ROOTS_ALL + S_ROOTS_T1, e=E_ROOTS_ALL),
    # TS T2: + KGSL (C4a); gpucc-anorak is KGSL's and the GMU's clock provider (finding H1-F3).
    "ts-t2": dict(add=["qcom_tsens.ko", "qcom-vadc-common.ko", "qcom-spmi-adc5-gen3.ko",
                       "mdt_loader.ko", "log_gpu_error.ko", "nvmem_qfprom.ko", "gpucc-anorak.ko", "msm_kgsl.ko"],
                  s=S_ROOTS_ALL + S_ROOTS_T1, e=E_ROOTS_ALL + E_ROOTS_T2),
    # TS T3b (and the R-1 base): + the ADSP battery chain, the gauge and the virtual sensors; smp2p is the
    # ADSP's smem-state/interrupt provider (finding H1-F1); the bq27 gauge feeds every virtual sensor (H1-F2).
    "ts-t3b": dict(add=["qcom_tsens.ko", "qcom-vadc-common.ko", "qcom-spmi-adc5-gen3.ko",
                        "mdt_loader.ko", "log_gpu_error.ko", "nvmem_qfprom.ko", "gpucc-anorak.ko", "msm_kgsl.ko",
                        "qcom_pil_info.ko", "qcom_ramdump.ko", "qcom_sysmon.ko", "qcom_q6v5.ko", "smp2p.ko",
                        "qcom_q6v5_pas.ko", "qti_battery_charger_main.ko", "qrtr-smd.ko",
                        "bq27xxx_battery.ko", "bq27xxx_battery_i2c.ko", "virtual_sensor.ko"],
                   s=S_ROOTS_ALL + S_ROOTS_T1 + S_ROOTS_T3B, e=E_ROOTS_ALL + E_ROOTS_T2),
}
# Never in any list (PROJECT_SETUP §6A item 3, TS README §3: keeps the PMIC stage-2 shutdown as left by the
# hardware/bootloader; design H-Q5: the IPD sensor modules come at V0, not in these profiles).
NEVER = {"qcom-spmi-temp-alarm.ko", "ak09973.ko", "as5510.ko", "nautilus.ko"}
# In K1a's 95 but dropped from every later list (Arbiter decision 2026-10-16, finding H1-F4): the depth
# projector driver; no stage before tracking needs it; it returns only in a reviewed tracking package with
# the IR-emitter safety ownership of device-health design §2.1. K1a and stage 3d keep their list unchanged.
DROP_LATER = {"nautilus.ko"}
# Compatibles without a modules.alias entry (the module has no MODULE_DEVICE_TABLE): source file -> module.
COMPAT_MAP = {
    "qcom,pwm-lpg": "pwm-qti-lpg.ko",                 # drivers/pwm/pwm-qti-lpg.c
    "qcom,rpmh-vrm-regulator": "rpmh-regulator.ko",   # drivers/regulator/rpmh-regulator.c
    "qcom,rpmh-arc-regulator": "rpmh-regulator.ko",   # drivers/regulator/rpmh-regulator.c
    "qcom,cpufreq-hw-epss": "qcom-cpufreq-hw.ko",     # drivers/cpufreq/qcom-cpufreq-hw.c
    "qcom,tri-led": "leds-qti-tri-led.ko",            # drivers/leds/leds-qti-tri-led.c
    "qcom,gdsc": "gdsc-regulator.ko",                 # drivers/clk/qcom/gdsc-regulator.c
    "qcom,qmp-mbox": "msm_qmp.ko",                    # drivers/mailbox/msm_qmp.c (CONFIG_MSM_QMP=m)
    "qcom,gen7-gmu": "msm_kgsl.ko",                   # drivers/gpu/msm/adreno_gen7_gmu.c
}
# Suppliers found by name, not by phandle: virtual_sensor looks its input zones, its fault-estimator zones and
# (battery sensor only) its fallback zone up by name (virtual_sensor.c:1035-1048, 915-985, 1198-1202). Of these
# only the power-supply zones are probe suppliers: bq27z561-0 (the gauge psy, bq27xxx_battery_i2c.c:208) and
# battery (the charger psy); pcb1/pcb3/pogo/soc-usr and usb-conn are DT zones registered at boot
# (thermal_of.c:1171-1220) whose data comes from the PMIC ADC: listed as data, not as a probe dependency.
# icc-rpmh reads socinfo's part info at probe (icc-rpmh.c:322-327); socinfo is created by the built-in SMEM,
# which defers until its hwlock exists (smem.c:1064-1081, v27.dts qcom,smem hwlocks) -> qcom_hwspinlock.
MANUAL_SOFT = {
    "virtual_sensor.ko": ["bq27xxx_battery_i2c.ko", "qcom-spmi-adc5-gen3.ko", "qti_battery_charger_main.ko"],
    "icc-rpmh.ko": ["qcom_hwspinlock.ko"],
}
MANUAL_SOFT_WHY = {
    "virtual_sensor.ko": "zones bq27z561-0 and battery; ADC zones as data",
    "icc-rpmh.ko": "socinfo part info via SMEM, which needs its hwlock",
}
# S roots whose readiness can only be "live" (their device appears later); every other S "live" entry must be
# in the closure of a root with a device predicate (checked).
LIVE_ONLY_ROOTS = {"qrtr-smd.ko"}
CELLS = {"resets": "#reset-cells", "clocks": "#clock-cells", "interrupts-extended": "#interrupt-cells", "pwms": "#pwm-cells",
         "interconnects": "#interconnect-cells", "mboxes": "#mbox-cells",
         "qcom,smem-states": "#qcom,smem-state-cells", "iommus": "#iommu-cells",
         "io-channels": "#io-channel-cells", "power-domains": "#power-domain-cells",
         "hwlocks": "#hwlock-cells", "phys": "#phy-cells", "dmas": "#dma-cells"}
PLAIN = re.compile(r"^(.*-supply|pinctrl-\d+|interrupt-parent|memory-region|qcom,qmp|nvmem|nvmem-cells|"
                   r"usb-phy|qcom,wrapper-core|wakeup-parent|extcon|qcom,bcm-voters)$")
GPIO = re.compile(r"^(.*-gpios?|gpios)$")


class DT:
    def __init__(self, path):
        self.nodes, self.order, stack = {}, [], []
        for line in open(path, encoding="utf-8", errors="replace"):
            s = line.strip()
            m = re.match(r"^([^\s=]+)\s*\{$", s)
            if m:
                name = m.group(1)
                path_ = "/" if name == "/" else (stack[-1].rstrip("/") + "/" + name if stack else "/" + name)
                stack.append(path_)
                self.nodes.setdefault(path_, {})
                self.order.append(path_)
                continue
            if s == "};":
                stack.pop()
                continue
            m = re.match(r"^([^\s=]+)\s*=\s*(.*);$", s)
            if m and stack:
                self.nodes[stack[-1]][m.group(1)] = m.group(2)
            elif re.match(r"^[^\s=]+;$", s) and stack:
                self.nodes[stack[-1]][s[:-1]] = True
        self.ph = {}
        for p, pr in self.nodes.items():
            if isinstance(pr.get("phandle"), str):
                self.ph[int(re.findall(r"0x[0-9a-f]+|\d+", pr["phandle"])[0], 0)] = p

    def find(self, name):  # "node-name", or "parent/node-name" to disambiguate
        hits = [p for p in self.order if p.rsplit("/", 1)[-1] == name or ("/" in name and p.endswith("/" + name))]
        if len(hits) != 1:
            raise SystemExit(f"DT node '{name}': {len(hits)} matches (need exactly 1)")
        return hits[0]

    def compat(self, p):
        c = self.nodes[p].get("compatible")
        return re.findall(r'"([^"]*)"', c) if isinstance(c, str) else []

    def status_ok(self, p):
        st = self.nodes[p].get("status")
        return not isinstance(st, str) or st.strip('"') in ("ok", "okay")

    def ncells(self, prov, key):
        v = self.nodes[prov].get(key)
        if not isinstance(v, str):
            return 2 if key == "#gpio-cells" else 0
        return int(re.findall(r"0x[0-9a-f]+|\d+", v)[0], 0)

    def refs(self, p):
        out = []
        for k, v in self.nodes[p].items():
            if not isinstance(v, str) or "<" not in v:
                continue
            nums = [int(x, 0) for x in re.findall(r"0x[0-9a-f]+|\b\d+\b", v)]
            if PLAIN.match(k):
                out += [(k, self.ph[n]) for n in nums if n in self.ph]
            elif k in CELLS or GPIO.match(k):
                key = CELLS.get(k, "#gpio-cells")
                i = 0
                while i < len(nums) and nums[i] in self.ph:
                    out.append((k, self.ph[nums[i]]))
                    i += 1 + self.ncells(self.ph[nums[i]], key)
        pr = self.nodes[p]
        if "interrupts" in pr and "interrupt-parent" not in pr and "interrupts-extended" not in pr:
            q = p.rsplit("/", 1)[0]   # the interrupt parent is inherited from the nearest ancestor naming one
            while q and q != "/":
                v = self.nodes.get(q, {}).get("interrupt-parent")
                if isinstance(v, str):
                    out += [("interrupt-parent(inherited)", self.ph[int(x, 0)])
                            for x in re.findall(r"0x[0-9a-f]+|\b\d+\b", v) if int(x, 0) in self.ph]
                    break
                q = q.rsplit("/", 1)[0]
        return out

    def subtree(self, p):  # the node and its enabled descendants (components and children of the root's driver)
        out = []
        for q in self.order:
            if q == p or q.startswith(p.rstrip("/") + "/"):
                anc, ok = q, True
                while anc != p and ok:
                    ok = self.status_ok(anc)
                    anc = anc.rsplit("/", 1)[0]
                if ok and self.status_ok(p):
                    out.append(q)
        return out

    def owner(self, p):
        q = p
        while q and q != "/":
            if self.compat(q):
                return q
            q = q.rsplit("/", 1)[0] or "/"
        return None


class Index:
    def __init__(self, dirs):
        self.dep, self.soft, self.alias, self.where = {}, {}, [], {}
        for d in dirs:
            for line in open(os.path.join(d, "modules.dep")):
                if ":" not in line:
                    continue
                a, b = line.split(":", 1)
                k = os.path.basename(a.strip())
                if k not in self.dep:
                    self.dep[k] = [os.path.basename(x) for x in b.split()]
                    self.where[k] = d
            for line in open(os.path.join(d, "modules.softdep")):
                w = line.split()
                if len(w) < 2 or w[0] != "softdep":
                    continue
                mode, pre = None, []
                for t in w[2:]:
                    if t in ("pre:", "post:"):
                        mode = t
                    elif mode == "pre:":
                        pre.append(t)
                self.soft.setdefault(w[1].replace("-", "_"), pre)
            for line in open(os.path.join(d, "modules.alias")):
                w = line.split()
                if len(w) == 3 and w[0] == "alias" and w[1].startswith("of:N*T*C"):
                    c = w[1][len("of:N*T*C"):]
                    if c.endswith("C*"):
                        c = c[:-2]
                    self.alias.append((c, w[2]))

    def file_of(self, name):  # a module name or file name -> the indexed .ko basename, or None
        n = name[:-3] if name.endswith(".ko") else name
        for c in (n, n.replace("_", "-"), n.replace("-", "_")):
            if c + ".ko" in self.dep:
                return c + ".ko"
        key = n.replace("-", "_")   # file names that mix '_' and '-' (nvmem_qcom-spmi-sdam.ko)
        for f in self.dep:
            if f[:-3].replace("-", "_") == key:
                return f
        return None

    def module_for_compat(self, c):
        for a, mod in self.alias:
            if a == c:
                return self.file_of(mod)
        return COMPAT_MAP.get(c)


def closure(roots, idx, dt, why, phase, out_missing):
    """roots: [(module, [dt node names], reason)]. Returns the members (in discovery order), the hard edges
    (modules.dep, softdep pre: a load-order requirement) and the soft edges (DT probe suppliers: a missing or
    later supplier only defers the probe, so these order the list where they do not contradict a hard edge)."""
    edges, soft = {}, {}  # module -> set(modules that should come earlier)
    seen = []

    def need(m, by, reason):
        f = idx.file_of(m)
        if f is None:
            out_missing.append(f"{phase}: '{m}' needed by {by} ({reason}) is in no index")
            return None
        if f not in why:
            why[f] = (phase, reason)
        if f not in seen:
            seen.append(f)
            edges.setdefault(f, set())
            for d in idx.dep.get(f, []):
                g = need(d, f, f"modules.dep of {f}")
                if g:
                    edges[f].add(g)
            for s in idx.soft.get(f[:-3].replace("-", "_"), []):
                if idx.file_of(s):
                    g = need(s, f, f"softdep pre of {f}")
                    if g:
                        edges[f].add(g)
            for d in MANUAL_SOFT.get(f, []):   # by-name (not phandle) suppliers, any module
                g = need(d, f, f"by-name lookup in {f} ({MANUAL_SOFT_WHY[f]})")
                if g:
                    soft.setdefault(f, set()).add(g)
        return f

    def walk_dt(node, mod, visited, own=False):
        p = node if own else dt.owner(node)
        if p is None or p in visited:
            return
        visited.add(p)
        for prop, tgt in dt.refs(p):
            q = dt.owner(tgt)
            if q is None:
                continue
            for c in dt.compat(q):
                sm = idx.module_for_compat(c)
                if sm and sm != mod:
                    g = need(sm, mod, f"DT {prop} of {p.rsplit('/', 1)[-1]} -> {q.rsplit('/', 1)[-1]} ({c})")
                    if g:
                        soft.setdefault(mod, set()).add(g)
                        walk_dt(q, g, visited)
                    break
            else:
                walk_dt(q, mod, visited)  # built-in provider: its own suppliers still count
        par = p.rsplit("/", 1)[0]
        if par and par != "/" and dt.compat(par):
            for c in dt.compat(par):
                sm = idx.module_for_compat(c)
                if sm and sm != mod:
                    g = need(sm, mod, f"DT parent bus of {p.rsplit('/', 1)[-1]} ({c})")
                    if g:
                        soft.setdefault(mod, set()).add(g)
                        walk_dt(par, g, visited)
                    break
            else:
                walk_dt(par, mod, visited)

    for m, nodes, reason in roots:
        f = need(m, "root", reason)
        if f is None:
            continue
        why[f] = (phase, "ROOT: " + reason)
        visited = set()
        for n in nodes:  # "=node": that node only; "node": the node and its enabled subtree
            for q in ([dt.find(n[1:])] if n.startswith("=") else dt.subtree(dt.find(n))):
                walk_dt(q, f, visited, own=True)
    return seen, edges, soft


def order(members, hard, soft, rank):
    """Depth-first: hard predecessors first (a cycle is an error), then soft ones unless that would close a
    cycle (a DT supplier whose own module symbol-depends on the consumer is then left later: it defers)."""
    out, done, temp = [], set(), []

    def visit(m, is_soft=False):
        if m in done:
            return
        if m in temp:
            if is_soft:
                return
            raise SystemExit("dependency cycle: " + " -> ".join(temp[temp.index(m):] + [m]))
        temp.append(m)
        for d in sorted(hard.get(m, ()), key=rank):
            if d in members:
                visit(d)
        for d in sorted(soft.get(m, ()), key=rank):
            if d in members and d not in temp:
                visit(d, True)
        temp.pop()
        done.add(m)
        out.append(m)

    for m in sorted(members, key=rank):
        visit(m)
    return out


def derive(name, prof, idx, dt, base95):
    errors, missing = [], []
    add = [idx.file_of(a) or a for a in prof["add"]]
    members = [m for m in base95 if m not in DROP_LATER] + [a for a in add if a not in base95]
    mset = set(members)
    rank = {m: i for i, m in enumerate(members)}
    rk = lambda m: rank.get(m, 10 ** 6)  # noqa: E731
    why, ready = {}, {}
    s_seen, s_edges, s_soft = closure([(m, n, r) for m, _, r, n in prof["s"]], idx, dt, why, "S", missing)
    for m, p, _, _ in prof["s"]:
        ready[idx.file_of(m)] = ("S", p)
    e_roots = [(m, n, r) for m, _, _, r, n in prof["e"]]
    e_seen, e_edges, e_soft = closure(e_roots, idx, dt, why, "E", missing)
    for m, req, p, _, _ in prof["e"]:
        ready[idx.file_of(m)] = (req, p)
    for x in E_DISPLAY_EXTRA:
        f = idx.file_of(x)
        if f in mset and f not in s_seen and f not in e_seen:
            e_seen.append(f)
            why.setdefault(f, ("E", "display path of the 95 (panel power, backlight, display clocks; stage 3c/3d)"))
            for d in idx.dep.get(f, []):
                e_edges.setdefault(f, set()).add(d)
    S = [m for m in s_seen]
    # every S entry whose readiness is only "live" must be reachable from a root with a device predicate
    reach = set()
    for m, pred, _, _ in prof["s"]:
        f = idx.file_of(m)
        if pred == "live" or f is None:
            continue
        stack = [f]
        while stack:
            x = stack.pop()
            if x in reach:
                continue
            reach.add(x)
            stack += list(s_edges.get(x, ())) + list(s_soft.get(x, ()))
    roots_s = {idx.file_of(m): pred for m, pred, _, _ in prof["s"]}
    for m in S:
        if roots_s.get(m, "live") == "live" and m not in reach and m not in LIVE_ONLY_ROOTS:
            errors.append(f"{name}: S module {m} has readiness 'live' and no root with a device predicate covers it")
    E = [m for m in e_seen if m not in S]
    for m in S + E:
        if m not in mset:
            errors.append(f"{name}: {m} is needed ({why[m][0]}: {why[m][1]}) but not in the profile's set")
    for m in members:
        if m in NEVER:
            errors.append(f"{name}: {m} is in NEVER")
    F = [m for m in members if m not in S and m not in E]
    for m in F:
        why.setdefault(m, ("F", "in the set; not needed by any S or E root (loaded with async_probe=1)"))
    edges, softe = {}, {}
    for d in (s_edges, e_edges):
        for k, v in d.items():
            edges.setdefault(k, set()).update(v)
    for d in (s_soft, e_soft):
        for k, v in d.items():
            softe.setdefault(k, set()).update(v)
    for m in members:  # every module's own modules.dep / softdep pre also orders it
        for d in idx.dep.get(m, []):
            edges.setdefault(m, set()).add(d)
        for s in idx.soft.get(m[:-3].replace("-", "_"), []):
            g = idx.file_of(s)
            if g:
                edges.setdefault(m, set()).add(g)
    S_o = order(set(S) & mset, edges, softe, rk)
    E_o = order(set(E) & mset, {k: {d for d in v if d not in S} for k, v in edges.items()},
                {k: {d for d in v if d not in S} for k, v in softe.items()}, rk)
    F_o = order(set(F), {k: {d for d in v if d in F} for k, v in edges.items()},
                {k: {d for d in v if d in F} for k, v in softe.items()}, rk)
    final = S_o + E_o + F_o
    pos = {m: i for i, m in enumerate(final)}
    notes = []
    for m in final:  # verify: every symbol dep / softdep pre (present in the set) is earlier
        for d in edges.get(m, ()):
            if d in pos and pos[d] > pos[m]:
                errors.append(f"{name}: {m} at {pos[m]} needs {d} at {pos[d]} (later)")
            if d not in pos and d in idx.dep and (m in S or m in E):
                errors.append(f"{name}: {m} needs {d}, which is not in the set")
        for d in softe.get(m, ()):
            if d in pos and pos[d] > pos[m]:
                notes.append(f"{name}: DT supplier {d} of {m} loads after it (that device's probe defers until then)")
    # DT suppliers found from the S roots must be in S; those found from the E roots in S or E (instance-level
    # edges are aggregated per module, so an E-walk edge on an S module is only a NOTE above).
    for k, v in s_soft.items():
        for d in v:
            if d not in S:
                errors.append(f"{name}: DT supplier {d} (S walk, of {k}) is not in S")
    for k, v in e_soft.items():
        for d in v:
            if d not in S and d not in E:
                errors.append(f"{name}: DT supplier {d} (E walk, of {k}) is not in S or E")
    if name == "k1i" and sorted(final) != sorted(m for m in base95 if m not in DROP_LATER):
        errors.append("k1i: the list is not exactly the 95 minus DROP_LATER")
    lines = []
    for m in final:
        ph = "S" if m in S else ("E" if m in E else "F")
        tag, pred = ready.get(m, (None, None))
        if ph == "S":
            pred = pred or "live"
            tag = "S"
        elif ph == "E":
            tag = tag if tag in ("E", "e") else "e"
            pred = pred or "auto"
        else:
            tag, pred = "F", "auto"
        lines.append((tag, m, pred))
    return lines, why, errors, missing, notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dts", required=True)
    ap.add_argument("--index", action="append", required=True)
    ap.add_argument("--base95", required=True)
    ap.add_argument("--write-lists")
    ap.add_argument("--report")
    ap.add_argument("--check")
    a = ap.parse_args()
    dt = DT(a.dts)
    idx = Index(a.index)
    base95 = [x.strip() for x in open(a.base95) if x.strip()]
    if len(base95) != 95 or len(set(base95)) != 95:
        raise SystemExit("base list is not 95 distinct entries")
    rep, bad = [], 0
    for name, prof in PROFILES.items():
        lines, why, errors, missing, notes = derive(name, prof, idx, dt, base95)
        body = "".join(f"{t} {m} {p}\n" for t, m, p in lines)
        head = (f"# FrameShift H-1 phase list, profile {name} (Quest 3 v2.7). Generated by "
                f"devices/quest3/h1/tools/derive-phases.py; do not edit.\n"
                f"# columns: phase (S = safety, required; E = essential, required; e = essential, best-effort;"
                f" F = async_probe) module readiness\n")
        text = head + body
        cnt = {k: sum(1 for t, _, _ in lines if t == k) for k in "SEeF"}
        rep.append(f"== profile {name}: {len(lines)} modules  S={cnt['S']} E={cnt['E']} e={cnt['e']} F={cnt['F']}")
        for t, m, p in lines:
            ph, r = why.get(m, ("?", "?"))
            rep.append(f"{t} {m:34s} {p:40s} {r}")
        for n in notes:
            rep.append("NOTE " + n)
        for e in missing + errors:
            rep.append("ERROR " + e)
            bad += 1
        if a.write_lists:
            with open(os.path.join(a.write_lists, f"{name}.phases"), "w", newline="\n", encoding="ascii") as fh:
                fh.write(text)
        if a.check:
            p = os.path.join(a.check, f"{name}.phases")
            got = open(p, newline="", encoding="ascii").read() if os.path.exists(p) else None
            if got != text:
                rep.append(f"ERROR {name}: committed {p} differs from the derived list")
                bad += 1
            else:
                rep.append(f"CHECK {name}: committed list equals the derived list")
    rep.append(f"RESULT {'PASS' if bad == 0 else 'FAIL'}: {bad} error(s)")
    out = "\n".join(rep) + "\n"
    if a.report:
        with open(a.report, "w", newline="\n", encoding="utf-8") as fh:
            fh.write(out)
    sys.stdout.buffer.write(out.encode("utf-8"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
