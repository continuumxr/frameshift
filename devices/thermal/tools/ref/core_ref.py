#!/usr/bin/env python3
"""Independent Python reference model (test oracle) of the fs-thermald
decision core.

Written only from devices/thermal/CORE-SPEC.md (rev 1 ... rev 7). Rule ids C-n in the
comments map each piece of code to the spec. Where the spec left a choice
open, the most conservative reading (never less safe: earlier/higher tier,
longer fault) is implemented and marked "AMBIG" in a comment.

CLI:
    python3 -I core_ref.py --config CONFIG.json --ticks TICKS.jsonl [--gate]

Standard library only; integer arithmetic only.
"""

import argparse
import copy
import json
import sys

ERR = "ERR"
ABSENT = "ABSENT"

# §0 severity slots
NONE, LIGHT, MODERATE, SEVERE, CRITICAL, EMERGENCY, SHUTDOWN = range(7)
SET_SLOTS = (LIGHT, MODERATE, SEVERE, CRITICAL, EMERGENCY, SHUTDOWN)
# §0 slot -> tier; K-28: CRITICAL/EMERGENCY (unreachable for an accepted
# set) fail closed to tier 4
SLOT_TIER = {NONE: 0, LIGHT: 1, MODERATE: 2, SEVERE: 3, CRITICAL: 4,
             EMERGENCY: 4, SHUTDOWN: 4}
INT32_MIN, INT32_MAX = -2 ** 31, 2 ** 31 - 1
CLASS_ORDER = ("SOC", "SKIN", "BATT", "USB", "BOARD", "PMIC", "AUX")
# K-9/K-53: the counted classes, in self-test order (PMIC: K-53, rev 7)
COUNTED = ("SOC", "SKIN", "BATT", "USB", "BOARD", "PMIC")
# K-50: kinds the core measures; "iio" is exactly "zone" for the core
MEASURED_KINDS = ("zone", "iio", "psy")
# C-18 P12 deltas. K-55: none for PMIC (a PMIC sensor never starts a fast T5)
T5_DELTA = {"SOC": 5000, "BATT": 2000, "SKIN": 3000}
SENSOR_FAULT_HEALTH = ("read", "low", "frozen", "stuck")
ANOMALY_HEALTH = ("hot", "rise")
SHUTDOWN_COMM = "systemd-shutdow"


class ConfigError(Exception):
    pass


def is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def hy_of(s, k):
    """Unset hysteresis counts as 0 (C-10)."""
    h = s["hy"][k]
    return h if is_int(h) else 0


# ---------------------------------------------------------------------------
# §1 configuration
# ---------------------------------------------------------------------------

def load_config(obj):
    flags_in = obj.get("flags") or {}
    flags = {k: bool(flags_in.get(k, 0)) for k in
             ("trial_override", "headless_fan", "batt_absent", "p15", "j145")}
    batt_absent = flags["batt_absent"]

    sensors = []
    for s in obj.get("sensors", []):
        cls = s["class"]
        # C-12: batt_absent skips the BATT class and its sensors entirely
        if batt_absent and cls == "BATT":
            continue
        th = list(s.get("th") or [None] * 7)
        hy = list(s.get("hy") or [None] * 7)
        if len(th) != 7 or len(hy) != 7:
            raise ConfigError("sensor %s: th/hy must have 7 entries" % s["name"])
        kind = s.get("kind", "zone")
        if kind not in ("zone", "iio", "psy", "aux"):          # K-50: iio
            raise ConfigError("sensor %s: bad kind %r" % (s["name"], kind))
        sensors.append({
            "name": s["name"], "cls": cls, "group": s.get("group"),
            "kind": kind, "slow": bool(s.get("slow", 0)),
            "indep": bool(s.get("indep", 0)), "th": th, "hy": hy,
            "vin": list(s.get("vin") or []),
            "weak": bool(s.get("weak", 0)),                # K-29
        })

    groups = [g for g in obj.get("groups", [])
              if not (batt_absent and g["class"] == "BATT")]

    measured = [s for s in sensors if s["kind"] in MEASURED_KINDS]
    by_name = {s["name"]: s for s in sensors}
    members = {}
    for s in measured:
        members.setdefault(s["cls"], []).append(s)
    nosib = {}
    for s in measured:
        others = [o for o in members[s["cls"]] if o is not s and o["indep"]]
        # C-8: not indep, or no other indep sensor in its class
        nosib[s["name"]] = (not s["indep"]) or not others
    has_levels = {s["name"]: any(s["th"][k] is not None for k in SET_SLOTS)
                  for s in measured}
    # C-3 needs the inputs' health first: sensors without vin, then with vin
    order = [s for s in sensors if not s["vin"]] + [s for s in sensors if s["vin"]]

    classes = []
    for c in CLASS_ORDER:
        if any(g["class"] == c for g in groups) or (c == "BATT" and not batt_absent):
            classes.append(c)
    for g in groups:
        if g["class"] not in classes:
            classes.append(g["class"])

    fan = obj.get("fan")
    caps = obj.get("caps") or {}          # K-14(h): caps null -> cpu=- gpu=-
    gpu = caps.get("gpu")
    if not gpu:
        gpu = None
    cpu = caps.get("cpu")
    if not cpu:
        cpu = None
    if cpu is not None and len(cpu) != 6:
        raise ConfigError("caps.cpu must have 6 entries")
    if gpu is not None and len(gpu) != 6:
        raise ConfigError("caps.gpu must have 6 entries")
    if fan is not None and len(fan["floor_tier"]) != 6:
        raise ConfigError("fan.floor_tier must have 6 entries")

    limits = obj.get("limits")
    # C-29 "an active set exists". AMBIG: limits must name an active set
    # (meta-runtime or builtin) AND some zone/psy sensor has a set slot.
    active_set = (limits in ("meta-runtime", "builtin")
                  and any(has_levels.values()))

    return {
        "mode": obj.get("mode", "valve"),
        "psy_period_ms": obj.get("psy_period_ms") or 0,
        "adsp": bool(obj.get("adsp", False)),
        "sensors": sensors, "measured": measured, "by_name": by_name,
        "members": members, "nosib": nosib, "has_levels": has_levels,
        "order": order, "groups": groups, "classes": classes,
        "fan": fan, "cpu": cpu, "gpu": gpu, "p5": obj.get("p5"),
        "flags": flags, "active_set": active_set,
        "c12": not batt_absent,
    }


def initial_state(cfg):
    sens = {}
    for s in cfg["sensors"]:
        sens[s["name"]] = {
            "cur": None,              # {"h","v","u"} of the last evaluation
            "pv": None, "pt": None,   # C-5 last numeric reading
            "fz_v": None, "fz_since": None, "fz_in": {},  # C-3 trackers
            "k27": None,              # K-33 {"fv","fsince","ref0"}
            "pend": None,             # C-7 {"n","contra"}
            "flt": None,              # C-9 {"code","since","ok"}
            "L": 0, "down": None,     # C-10
        }
    fan = cfg["fan"]
    return {
        "tick": 0, "first_t": None, "last_sample": None,
        "last_t": None,                       # previous tick time (K-43)
        "sens": sens,
        "cls": {c: None for c in cfg["classes"]},   # C-11 {"since","ok"}
        "batt": {"adsp": False, "psy": False, "stale_since": None,
                 "stale": False, "prev": None},
        "lowbatt": False, "psy_status": None, "j145": False,
        "ext": False, "t4_reasons": [], "warn_last": None,
        "fan": {"prev_target": None, "allow_until": None,
                "t_before": 0, "spin_until": None,   # K-24
                "t_change": None,                    # K-36
                "r0": 0,                             # K-37/K-46
                "x": 0,                              # K-43
                "f6_hist": [],                       # K-41/K-44: last 20 ticks
                "need": 0,                           # K-47
                "rpm3": [],                          # K-46: last 3 ticks' rpm
                "st_retry": 0,                       # K-48
                "f9_hist": [], "f9_prev": None, "f9_pt": None,   # K-38
                "cdev_since": None, "cdev_done": False,   # K-31
                "tm": {"F2": None, "F3": None, "F4": None, "F5": None},
                "prev_rpm": None, "flt": None,
                "trips": [[False] * len(r["trips"]) for r in fan["rules"]]
                if fan else []},
        "ready": 0, "selftest_failed": False,
        "latched": False, "t5": False, "tf": None,
        "tier": 0, "t3_since": None,
        "tl0": None, "done": set(), "a2_tick": None,
    }


# ---------------------------------------------------------------------------
# §2 / §12 inputs
# ---------------------------------------------------------------------------

def i32(v):
    """K-26: a reading outside int32 (after scaling) is ERR."""
    if is_int(v) and not INT32_MIN <= v <= INT32_MAX:
        return ERR
    return v


def norm_tick(obj):
    psy = obj.get("psy")
    if not isinstance(psy, dict):
        psy = {}
    psy = {k: i32(psy.get(k, ERR)) for k in ("temp", "volt", "curr", "cap", "status")}
    if is_int(psy["temp"]) and i32(psy["temp"] * 100) == ERR:
        # K-26: psy temp x 100 outside int32 -> ERR. AMBIG: the psy field
        # itself becomes ERR (also for C-12 psy, J-145), not only the sensor.
        psy["temp"] = ERR
    fan = obj.get("fan", ABSENT)
    if isinstance(fan, dict):
        fan = {k: i32(v) for k, v in fan.items()}
    return {
        "t": obj["t"],
        "s": {k: i32(v) for k, v in (obj.get("s") or {}).items()},
        "psy": psy,
        "usb_online": i32(obj.get("usb_online", 0)),
        "adsp": obj.get("adsp", "running"),
        "fan": fan,
        "fan_wr_err": bool(obj.get("fan_wr_err", False)),
        "cap_fail": bool(obj.get("cap_fail", False)),
        "caps_ok_at_start": bool(obj.get("caps_ok_at_start", True)),
        "shutdown_byte": bool(obj.get("shutdown_byte", False)),
        "pid1_comm": obj.get("pid1_comm", "init"),
        "a1_done": bool(obj.get("a1_done", False)),
        "a2_exited": bool(obj.get("a2_exited", False)),
        "pstore_marker": bool(obj.get("pstore_marker", False)),
    }


def raw_reading(s, rd):
    if s["kind"] == "psy":
        t = rd["psy"]["temp"]
        return t * 100 if is_int(t) else ERR   # §12: deci-°C -> m°C
    # zone, aux and (K-50) iio: the tick file's "s" object
    v = rd["s"].get(s["name"], ABSENT)
    return v if is_int(v) else (v if v in (ERR, ABSENT) else ERR)


# ---------------------------------------------------------------------------
# §3 sensor health
# ---------------------------------------------------------------------------

def health_c12(raw):
    """K-3 first pass: C-1, C-2."""
    if not is_int(raw):
        return "read"                                       # C-1
    if raw < -20000:
        return "low"                                        # C-2
    return None


def health_c45(s, ss, raw, now):
    """C-4, C-5 (not for AUX). (pv, pt) are those of earlier ticks (K-5)."""
    if s["kind"] == "aux":
        return None            # AUX: only C-1, C-2 (they never fault)
    if raw > 125000:
        return "hot"                                        # C-4
    if (s["slow"] and ss["pv"] is not None
            and (raw - ss["pv"]) * 1000 > 10000 * (now - ss["pt"])):
        return "rise"                                       # C-5
    return None


def frozen_step(ss, raw, inputs, now):
    """K-4: update the C-3 tracker (numeric readings only), then check."""
    if not is_int(raw):
        return False
    if ss["fz_since"] is not None and raw == ss["fz_v"]:
        for inp, u in inputs.items():
            mm = ss["fz_in"].get(inp)
            ss["fz_in"][inp] = [u, u] if mm is None else [min(mm[0], u), max(mm[1], u)]
    else:
        ss["fz_v"], ss["fz_since"] = raw, now
        ss["fz_in"] = {inp: [u, u] for inp, u in inputs.items()}
    return (now - ss["fz_since"] >= 120000
            and any(mx - mn > 1000 for mn, mx in ss["fz_in"].values()))


def contradicted(cfg, s, st):
    """C-7: another indep sensor of the class, healthy this tick, below its
    own SEVERE; and no healthy indep sibling at or above its SEVERE.
    K-29: a weak sensor never contradicts; no contradiction on a tick where
    any other indep sibling has C-1/C-2/C-3 health or an active fault."""
    below = above = False
    for o in cfg["members"][s["cls"]]:
        if o is s or not o["indep"]:
            continue
        oss = st["sens"][o["name"]]
        c = oss["cur"]
        if (c is not None and c["h"] in SENSOR_FAULT_HEALTH) or oss["flt"] is not None:
            return False                                     # K-29
        if c is None or c["h"] != "ok":
            continue
        sev = o["th"][SEVERE]
        if sev is None:
            continue          # a sensor with no SEVERE never contradicts
        if c["v"] < sev:
            if not o["weak"]:                                # K-29
                below = True
        else:
            above = True      # a weak sibling still blocks (AMBIG)
    return below and not above


def lifecycle(rec, raised_code, healthy, now, t4_key, trig, can_clear=True,
              clear_ms=30000):
    """Shared C-9 / C-11 / C-25 fault lifecycle. rec is None or
    {"code","since","ok"}. clear_ms: 30000 (sensor, class), 60000 (fan,
    K-16). Returns the new rec."""
    if raised_code is not None:
        if rec is None:
            rec = {"code": raised_code, "since": now, "ok": None}
        # a new fault while active keeps since (and the first code)
        rec["ok"] = None
    elif rec is not None:
        if healthy:
            if rec["ok"] is None:
                rec["ok"] = now
        else:
            rec["ok"] = None
    # K-14(a): a tick that raises a fault never starts its recovery (above).
    # C-9 order (PM ruling): the clear first, then the 120 s timer, so a
    # fault that clears on a tick does not latch T4 on that tick.
    if (rec is not None and can_clear and rec["ok"] is not None
            and now - rec["ok"] >= clear_ms):
        rec = None
    if rec is not None and now - rec["since"] >= 120000:
        trig.add(t4_key)
    return rec


# ---------------------------------------------------------------------------
# The core: one tick
# ---------------------------------------------------------------------------

def decide(cfg, state, rd, now):
    """Pure core: returns (output_fields, new_state). state is not mutated."""
    st = copy.deepcopy(state)
    first = st["tick"] == 0
    if first:
        st["first_t"] = now
    flags = cfg["flags"]
    trig = set()          # T4 triggers firing this tick (C-19)
    events = set()
    actions = set()
    psy = rd["psy"]

    # -- step 1: C-30 psy sampling ------------------------------------------
    sample = first or now - st["last_sample"] >= cfg["psy_period_ms"]
    if sample:
        st["last_sample"] = now

    def processed(s):
        # §12: C-1...C-10 run for the psy sensor on sample ticks only
        return s["kind"] != "psy" or sample

    # -- step 2: health (C-1 ... C-6) in the passes of K-3, then (pv, pt) ----
    raws, p1, p45 = {}, {}, {}
    for s in cfg["sensors"]:
        if not processed(s):
            continue          # psy: every state carried from the last sample
        n = s["name"]
        raws[n] = raw_reading(s, rd)
        p1[n] = health_c12(raws[n])                          # pass 1: C-1, C-2
        p45[n] = (health_c45(s, st["sens"][n], raws[n], now)
                  if p1[n] is None else None)

    def input_usable(inp):
        """K-3: usable = C-1/C-2 did not fire and (non-AUX) C-4/C-5 neither."""
        if inp in p1:
            return raws[inp] if p1[inp] is None and p45[inp] is None else None
        c = st["sens"][inp]["cur"] if inp in st["sens"] else None
        return c["u"] if c is not None else None   # carried psy / unknown

    frozen = {}
    for s in cfg["sensors"]:                                 # pass 2: C-3
        if not processed(s) or not s["vin"]:
            continue
        n = s["name"]
        ins = {}
        for inp in s["vin"]:
            u = input_usable(inp)
            if u is not None:
                ins[inp] = u
        frozen[n] = frozen_step(st["sens"][n], raws[n], ins, now)
    stuck = {}
    for s in cfg["measured"]:                                # pass 2: K-33
        # K-33/K-40: only SOC-class zone sensors (no vin), not weak (K-50:
        # never an iio/PMIC sensor)
        if (not processed(s) or s["vin"] or s["kind"] != "zone"
                or s["cls"] != "SOC" or s["weak"]):
            continue
        n = s["name"]
        ss = st["sens"][n]
        raw = raws[n]
        if not is_int(raw):
            continue                       # tracker changes on numeric only
        refs = [input_usable(o["name"]) for o in cfg["members"].get("SOC", [])
                if o is not s]
        refs = [v for v in refs if v is not None]
        ref = max(refs) if refs else None
        k = ss["k27"]
        if k is not None and raw == k["fv"]:
            if k["stuck"] or (now - k["fsince"] >= 300000 and ref is not None
                              and k["ref0"] is not None
                              and abs(ref - k["ref0"]) > 3000):
                # K-40: once stuck, stays stuck while the value is unchanged
                k["stuck"] = True
                stuck[n] = True
        else:
            ss["k27"] = {"fv": raw, "fsince": now, "ref0": ref, "stuck": False}
    for s in cfg["sensors"]:                                 # pass 3: C-4..C-6
        if not processed(s):
            continue
        n = s["name"]
        ss = st["sens"][n]
        if p1[n] is not None:
            h = p1[n]
        elif frozen.get(n) and s["kind"] != "aux":
            h = "frozen"
        elif stuck.get(n):
            h = "stuck"                                      # K-33
        elif p45[n] is not None:
            h = p45[n]
        else:
            h = "ok"                                         # C-6
        v = raws[n] if is_int(raws[n]) else None
        ss["cur"] = {"h": h, "v": v, "u": v if h == "ok" else None}
        if v is not None:                                    # C-5 / K-5
            ss["pv"], ss["pt"] = v, now

    measured_now = [s for s in cfg["measured"] if processed(s)]

    # -- step 3: anomalies (C-7, C-8) --------------------------------------
    raised = {}
    for s in measured_now:
        ss = st["sens"][s["name"]]
        c = ss["cur"]
        if c["h"] not in ANOMALY_HEALTH:
            continue
        sev = s["th"][SEVERE]
        if (cfg["nosib"][s["name"]] and c["h"] == "rise"
                and (sev is None or c["v"] < sev)):
            # C-8: no independent sibling, rise below SEVERE -> fault at once.
            # K-14(b): applied even if the sensor is already pending/faulted.
            raised[s["name"]] = "rise"
        elif ss["pend"] is None and ss["flt"] is None:
            ss["pend"] = {"n": 0, "contra": False}          # C-7 detection
    for s in measured_now:
        ss = st["sens"][s["name"]]
        p = ss["pend"]
        if p is None:
            continue
        if not cfg["nosib"][s["name"]] and contradicted(cfg, s, st):
            p["contra"] = True                               # remembered
        if p["n"] == 2:                                      # C-7 resolution
            if p["contra"]:
                raised.setdefault(s["name"], "contra")
            else:
                trig.add("anomaly:" + s["name"])
            ss["pend"] = None
        else:
            p["n"] += 1

    # -- step 4: sensor fault lifecycle (C-9) -------------------------------
    for s in measured_now:
        ss = st["sens"][s["name"]]
        h = ss["cur"]["h"]
        code = h if h in SENSOR_FAULT_HEALTH else raised.get(s["name"])
        # K-14(a): a tick on which a fault is raised never starts the 30 s
        # recovery, even if that tick's reading is healthy (contra/rise).
        ss["flt"] = lifecycle(ss["flt"], code, h == "ok", now,
                              "sensor:" + s["name"], trig)

    # -- step 5: sensor levels (C-10) ---------------------------------------
    for s in measured_now:
        if not cfg["has_levels"][s["name"]]:
            continue
        ss = st["sens"][s["name"]]
        v = ss["cur"]["u"]
        if v is None:
            ss["down"] = None
            continue
        th = s["th"]
        up = max([k for k in SET_SLOTS if th[k] is not None and v >= th[k]],
                 default=0)
        L = ss["L"]
        if up > L:
            ss["L"], ss["down"] = up, None
        elif L > 0 and v < th[L] - hy_of(s, L):
            if ss["down"] is None:
                ss["down"] = now
            if now - ss["down"] >= 30000:
                L = max([k for k in SET_SLOTS
                         if k < L and th[k] is not None and v >= th[k] - hy_of(s, k)],
                        default=0)
                ss["L"] = L
                ss["down"] = now if (L > 0 and v < th[L] - hy_of(s, L)) else None
        else:
            ss["down"] = None

    # -- step 6: battery class (C-12), groups and classes (C-11) -------------
    b = st["batt"]
    if cfg["c12"]:
        if cfg["adsp"]:
            b["adsp"] = rd["adsp"] != "running"
        if sample:
            b["psy"] = any(psy[k] == ERR or (k != "status" and not is_int(psy[k]))
                           for k in ("temp", "volt", "curr", "cap", "status"))
            trip = (psy["temp"], psy["volt"], psy["curr"])
            if all(is_int(x) for x in trip):                     # K-8
                if b["prev"] is not None and list(trip) == b["prev"]:
                    if b["stale_since"] is None:
                        b["stale_since"] = now
                    b["stale"] = now - b["stale_since"] > 60000
                else:
                    b["stale_since"] = None
                    b["stale"] = False
                b["prev"] = list(trip)
            # K-8: a sample with an ERR field leaves the stale state unchanged
    stale = b["stale"]
    bcodes = []
    if cfg["c12"]:
        if cfg["adsp"] and b["adsp"]:
            bcodes.append("adsp")
        if b["psy"]:
            bcodes.append("psy")
        if stale:
            bcodes.append("stale")

    raw_cls = {c: False for c in cfg["classes"]}
    alt_cls = {c: False for c in cfg["classes"]}   # K-33: stuck as healthy
    for g in cfg["groups"]:
        n = n_alt = 0
        for s in cfg["measured"]:
            if s["group"] != g["name"]:
                continue
            ss = st["sens"][s["name"]]
            # C-11 counted healthy: usable and no active fault
            if ss["cur"] is not None and ss["cur"]["u"] is not None and ss["flt"] is None:
                n += 1
                n_alt += 1
            elif (ss["flt"] is not None and ss["flt"]["code"] == "stuck"
                  and ss["cur"] is not None and ss["cur"]["h"] in ("ok", "stuck")):
                # K-33. AMBIG: only while this tick's reading is ok/stuck
                n_alt += 1
        if n < g["min"]:
            raw_cls[g["class"]] = True
        if n_alt < g["min"]:
            alt_cls[g["class"]] = True
    if cfg["c12"] and bcodes:
        raw_cls["BATT"] = True
        alt_cls["BATT"] = True
    for c in cfg["classes"]:
        rc = "class" if raw_cls[c] else None
        rec = lifecycle(st["cls"][c], rc, not raw_cls[c], now,
                        "class:" + c, trig)
        if rec is not None:
            # K-33: "ns" = this episode had a cause other than stuck sensors
            rec["ns"] = rec.get("ns", False) or alt_cls[c]
        st["cls"][c] = rec
    # K-7: "two or more classes faulted" counts active classes; K-33: a
    # class faulted only through stuck sensors does not count there.
    if sum(1 for c in cfg["classes"]
           if st["cls"][c] is not None and st["cls"][c]["ns"]) >= 2:
        trig.add("classes")

    # -- step 7: fan checks (C-23 ... C-25), then demand (C-20) --------------
    fcfg = cfg["fan"]
    f = st["fan"]
    fin = rd["fan"]
    # §5 / C-26. K-14(c): with headless_fan = 1 the fan is still controlled
    # and checked while it is present; only an absent fan is exempt.
    fan_active = fcfg is not None and (not flags["headless_fan"] or fin != ABSENT)
    fan_codes = []
    e6 = False
    if fan_active:
        codes = []
        fields_ok = isinstance(fin, dict) and all(
            is_int(fin.get(k)) for k in ("rpm", "pwm", "cur", "max"))
        # C-23 read/write/absence condition of this tick
        e6 = not isinstance(fin, dict) or not fields_ok or rd["fan_wr_err"]
        # K-44: F6 is a rate: the tick condition on >= 5 of the last 20
        # ticks with a fan in the config (this one included)
        if sum(f["f6_hist"][-19:]) + e6 >= 5:
            codes.append("F6")
        if fcfg.get("zone_fault"):
            codes.append("F8")                                  # K-25
        if isinstance(fin, dict) and is_int(fin.get("cur")) and is_int(fin.get("max")) \
                and fin["cur"] > fin["max"]:
            codes.append("F1")                                  # C-23
        rpm = fin.get("rpm") if isinstance(fin, dict) else None
        rpm = rpm if is_int(rpm) else None
        pwm = fin.get("pwm") if isinstance(fin, dict) else None
        pwm = pwm if is_int(pwm) else None
        T = f["prev_target"]
        inside = f["allow_until"] is not None and now < f["allow_until"]
        grace = f["spin_until"] is not None and now < f["spin_until"]
        rps = fcfg.get("rpm_per_sec") or 0
        silent = fcfg.get("silent_rpm")
        mr = fcfg.get("max_rpm")

        def tol(x):
            return max(500, x * 15 // 100)

        # K-43: update the ramp expectation x before the F3 check
        if T is not None:
            if not inside:
                f["x"] = T
            elif not grace:
                if (now - f["t_change"] > 1000 and st["last_t"] is not None):
                    f["x"] = min(T, f["x"] + rps * (now - st["last_t"]) // 1000)
                if T < f["x"]:
                    f["x"] = T
        # C-24: never on the first tick (no target written). Per check:
        # False = the condition is false (its timer resets), True = it holds,
        # "hold" = the timer neither starts nor resets but fires once a
        # running timer has passed its limit (K-36/K-47 F3, K-45 a tick
        # without the readings the check needs).
        conds = {"F2": False, "F3": False, "F4": False, "F5": False}
        if T is None:
            f["need"] = 0
        else:
            if grace:
                f["need"] = 0                                    # K-24(a)
            elif rpm is None:
                conds["F2"] = conds["F3"] = conds["F5"] = "hold"   # K-45
            else:
                # K-24(a): F2 and F5 run inside or outside the allowance
                conds["F2"] = T > 0 and rpm == 0
                # K-45: against the last numeric rpm of an earlier tick
                conds["F5"] = (f["prev_rpm"] is not None and rpm == f["prev_rpm"]
                               and T > 0)
                if not inside:
                    low = rpm < T - tol(T)
                    c3 = low or rpm > T + tol(T)
                    lvl = T - tol(T)
                else:
                    # K-43: against the continuous expectation x
                    x = f["x"]
                    low = c3 = rpm < x - tol(x)
                    lvl = x - tol(x)
                if c3:
                    conds["F3"] = True
                    if low:
                        f["need"] = max(f["need"], lvl)          # K-47
                elif not inside or rpm >= f["need"]:
                    f["need"] = 0                                # K-47 release
                else:
                    conds["F3"] = "hold"                         # K-47
            if not inside:
                # K-24(c): F4 against fan.max_rpm, outside the allowance only.
                # AMBIG: without max_rpm in the config, the target is used.
                if rpm is None or pwm is None:
                    conds["F4"] = "hold"                         # K-45
                else:
                    mr = fcfg.get("max_rpm")
                    ref_rpm = mr if is_int(mr) else T
                    conds["F4"] = pwm == fcfg["max_pwm"] and rpm * 100 < 85 * ref_rpm
        lims = {"F2": 20000, "F3": 45000, "F4": 45000, "F5": 30000}
        for k in ("F2", "F3", "F4", "F5"):
            if conds[k] == "hold":
                if f["tm"][k] is not None and now - f["tm"][k] > lims[k]:
                    codes.append(k)
                continue
            if conds[k]:
                if f["tm"][k] is None:
                    f["tm"][k] = now
                if now - f["tm"][k] > lims[k]:
                    codes.append(k)
            else:
                f["tm"][k] = None
        if f["tm"]["F3"] is None:
            f["need"] = 0
        if rpm is not None:
            f["prev_rpm"] = rpm                                  # K-45 F5
        f["rpm3"] = (f["rpm3"] + [rpm])[-3:]                     # K-46
        # K-35/K-38: tach plausibility (numeric fan input only)
        if fields_ok:
            impl = rpm < 0 or (is_int(mr) and mr > 0 and rpm > mr * 12 // 10)
            pr = f["f9_prev"]
            # AMBIG: the rate test keeps K-35's "rpm_per_sec > 0" precondition
            if (not impl and rps > 0 and pr is not None
                    and abs(rpm - pr) > (2 * rps * (now - f["f9_pt"]) // 1000
                                         + max(500, pr * 25 // 100))   # K-49
                    and not (is_int(silent) and rpm <= silent and pr <= silent)):
                impl = True
            f["f9_hist"] = (f["f9_hist"] + [impl])[-5:]
            f["f9_prev"], f["f9_pt"] = rpm, now
        else:
            # K-38: a fan ERR/ABSENT tick clears the history and leaves no
            # previous reading
            f["f9_hist"] = []
            f["f9_prev"] = f["f9_pt"] = None
        if sum(f["f9_hist"]) >= 3:
            codes.append("F9")                                   # K-38
        fan_codes = codes
        # K-10: the fan fault condition = C-23 fires or a fired F2...F5 (or
        # F9, K-35) still holds. K-15: a tick inside the allowance (now < allow_until, the
        # value in force at step 7) never clears and resets the clear timer.
        # K-16: the fan's clear window is 60000 ms.
        f["flt"] = lifecycle(f["flt"], codes[0] if codes else None,
                             not codes and not inside, now, "fan", trig,
                             clear_ms=60000)
    elif f["flt"] is not None:
        # headless and absent: no checks; the 120 s timer still runs
        if now - f["flt"]["since"] >= 120000:
            trig.add("fan")
    if fcfg is not None:
        # K-41/K-44: history of the C-23 tick condition over the last 20
        # ticks with a fan in the config (a headless absent tick counts as
        # no failure, K-42)
        f["f6_hist"] = (f["f6_hist"] + [bool(e6)])[-20:]
        if not fan_active:
            f["f9_hist"] = []
            f["f9_prev"] = f["f9_pt"] = None
    if fcfg is not None:                                        # C-20
        for ri, r in enumerate(fcfg["rules"]):
            # C-20: the rule's "base" names the sensor whose usable value
            # drives every trip of the rule ("zone" is only a label)
            bs = cfg["by_name"].get(r.get("base"))
            u = None
            if bs is not None and st["sens"][bs["name"]]["cur"] is not None:
                u = st["sens"][bs["name"]]["cur"]["u"]
            if u is None:
                continue
            for j, tp in enumerate(r["trips"]):
                if u >= tp["t"]:
                    f["trips"][ri][j] = True
                elif u < tp["t"] - tp["h"]:
                    f["trips"][ri][j] = False
        dl = 0
        for ri, r in enumerate(fcfg["rules"]):
            for j, tp in enumerate(r["trips"]):
                if f["trips"][ri][j]:
                    dl = max(dl, tp["lvl"])
        levels = fcfg["levels"]
        demand_rpm = levels[min(dl, len(levels) - 1)]
        demand_level = dl
    else:
        demand_rpm = 0
        demand_level = 0

    # -- step 8: P5, P6, P13 (C-13, C-14) ------------------------------------
    p5 = cfg["p5"]
    if p5 and p5.get("sensor") in st["sens"] and p5["sensor"] in cfg["by_name"]:
        c = st["sens"][p5["sensor"]]["cur"]
        if c is not None and c["u"] is not None and c["u"] >= p5["t"]:
            trig.add("p5")                                       # C-13
    lowbatt_start = False
    j145_start = False
    if sample:
        cap, status = psy["cap"], psy["status"]
        st["psy_status"] = status
        if is_int(cap) and status == "Discharging" and cap <= 3:
            trig.add("p6")                                       # C-14 P6
        if is_int(cap) and status != ERR:
            new_lb = cap <= 10 and status == "Discharging"       # C-14 P13
            if new_lb and not st["lowbatt"]:
                lowbatt_start = True
            st["lowbatt"] = new_lb
        # AMBIG: a sample with cap or status ERR holds lowbatt unchanged
        # K-17: J-145 is a WARN condition held until a sample shows
        # otherwise; an ERR sample keeps it. AMBIG: "ERR sample" = any psy
        # field ERR (the reading that keeps the WARN longest).
        temp = psy["temp"]
        if status == "Charging" and is_int(temp) and temp >= 300:
            new_j = True
        elif any(psy[k] == ERR for k in ("temp", "volt", "curr", "cap", "status")):
            new_j = st["j145"]
        else:
            new_j = False
        if new_j and not st["j145"]:
            j145_start = True
        st["j145"] = new_j

    # -- step 9: self-test (C-29) ------------------------------------------
    def fan_item():
        # K-14(c): passes for a headless image whose fan is absent, or a
        # config with fan and a clean C-23 (present and readable); K-48: a
        # read/write failure alone is retried on the next two ticks
        if flags["headless_fan"] and fin == ABSENT:
            return "pass"
        if fcfg is None or fan_codes:
            return "fail"
        return "retry" if e6 else "pass"

    def finish(failed):
        if failed is None and not cfg["active_set"]:
            failed = "set"
        if failed is None:
            st["ready"] = 1
            events.add("ready")
        else:
            st["selftest_failed"] = True
            events.add("notready:" + failed)

    if not first and st["fan"]["st_retry"]:
        it = fan_item()
        st["fan"]["st_retry"] -= 1
        if it == "pass":
            st["fan"]["st_retry"] = 0
            finish(None)
        elif it == "fail" or st["fan"]["st_retry"] == 0:
            st["fan"]["st_retry"] = 0
            finish("fan")
    if first:
        # K-9/K-53 item order: sensor:<name> (zone, iio and psy sensors of
        # the counted classes, config order), class:<CLASS> (SOC, SKIN, BATT,
        # USB, BOARD, PMIC), caps, fan (+ "set" for a missing active set,
        # checked last)
        counted = COUNTED
        failed = None
        for s in cfg["measured"]:
            if s["cls"] not in counted:
                continue
            if st["sens"][s["name"]]["cur"]["h"] != "ok":
                failed = "sensor:" + s["name"]
                break
        if failed is None:
            for c in counted:
                if c in st["cls"] and st["cls"][c] is not None:
                    failed = "class:" + c
                    break
        if failed is None and not rd["caps_ok_at_start"]:
            failed = "caps"
        it = "pass" if failed is not None else fan_item()
        if it == "fail":
            failed = "fan"
        if it == "retry":
            st["fan"]["st_retry"] = 2                            # K-48
        else:
            finish(failed)

    # -- step 10: T4 triggers (C-16) -> latch (C-19) ------------------------
    for s in cfg["measured"]:
        # AMBIG (K-28): a CRITICAL/EMERGENCY level (tier 4) also latches
        # T4 as shutdown:<name>, since tier 4 is latching
        if st["sens"][s["name"]]["L"] >= CRITICAL:
            trig.add("shutdown:" + s["name"])
    if f["flt"] is not None and any(any(tr[1:]) for tr in f["trips"]):
        # K-34/K-41: a current non-F6 condition, or F6 on >= 6 of the last
        # 10 ticks
        if any(c != "F6" for c in fan_codes) or sum(f["f6_hist"][-10:]) >= 6:
            trig.add("fan-trip2")                                # P8
    if rd["cap_fail"]:
        trig.add("cap")
    if (st["selftest_failed"] and not flags["trial_override"]
            and now - st["first_t"] >= 60000):
        trig.add("selftest")
    latched_now = False
    if not st["latched"] and trig:
        st["latched"] = True
        latched_now = True
        st["t4_reasons"] = sorted(trig)                         # K-19
        for r in sorted(trig):
            events.add("t4:" + r)

    # -- step 11: T5 (C-18; budget of C-35) ---------------------------------
    if st["latched"] and not st["t5"]:
        fast = []
        for s in cfg["measured"]:
            d = T5_DELTA.get(s["cls"])
            shut = s["th"][SHUTDOWN]
            c = st["sens"][s["name"]]["cur"]
            if d is None or shut is None or c is None or c["u"] is None:
                continue
            if c["u"] >= shut + d:
                fast.append(s["name"])
        if fast:
            st["t5"] = True
            st["tf"] = now
            # K-14(d): one t5:p12:<name> event per sensor past its delta
            for n in fast:
                events.add("t5:p12:" + n)
        elif (cfg["mode"] == "valve" and st["tl0"] is not None
              and now >= st["tl0"] + 45000):
            # K-14(e): the budget T5 is decided here (before the tier) so the
            # tier shows 5 on the tick T5 starts; it also starts on the first
            # tick >= tl0 + 45000 on which T4 is latched.
            st["t5"] = True
            events.add("t5:budget")

    # -- step 12: tier (C-15, C-17) ---------------------------------------
    want = 0
    for s in cfg["measured"]:
        want = max(want, SLOT_TIER[st["sens"][s["name"]]["L"]])
    contrib = (any(st["sens"][s["name"]]["flt"] is not None for s in cfg["measured"])
               or any(st["sens"][s["name"]]["pend"] is not None for s in cfg["measured"])
               or any(v is not None for v in st["cls"].values())
               or f["flt"] is not None or st["lowbatt"] or st["selftest_failed"]
               or st["j145"])                                    # K-17
    if contrib:
        want = max(want, 3)
    prev_tier = st["tier"]
    if st["latched"]:
        tier = 5 if st["t5"] else 4
    else:
        tier = want
        if prev_tier == 3 and tier < 3 and now - st["t3_since"] < 30000:
            tier = 3
    if tier == 3 and prev_tier < 3:
        st["t3_since"] = now
    st["tier"] = tier

    # -- step 13: fan target and allowance (C-21, C-22) ---------------------
    target = None
    if fan_active:
        target = max(demand_rpm, fcfg["floor_p1"], fcfg["floor_tier"][tier])
        target = min(target, fcfg["top"])
        if tier >= 4 or not st["ready"] or f["flt"] is not None:
            target = fcfg["top"]
        old = f["prev_target"] if f["prev_target"] is not None else 0
        if target != old:
            rps = fcfg.get("rpm_per_sec") or 0
            silent = fcfg.get("silent_rpm")
            both_silent = is_int(silent) and old <= silent and target <= silent
            ramp = abs(target - old) * 1000 // rps if rps > 0 and not both_silent else 0
            ramp = min(60000, ramp)                              # K-24(d)
            f["allow_until"] = now + 15000 + ramp
            f["t_before"] = old                                  # K-36
            f["t_change"] = now                                  # K-36
            # K-46: r0 = the median of the numeric rpm readings of the last
            # three ticks (two: the lower; one: that one), else the last
            # numeric rpm of an earlier tick, else 0
            nums = sorted(v for v in f["rpm3"] if v is not None)
            if nums:
                f["r0"] = nums[(len(nums) - 1) // 2]
            else:
                f["r0"] = f["prev_rpm"] if f["prev_rpm"] is not None else 0
            # K-43: the expectation on a target change
            if rps == 0 or both_silent:
                f["x"] = target                                  # a jump
            elif target < f["x"]:
                f["x"] = target
            else:
                f["x"] = max(f["x"], min(f["r0"], target))
            if old == 0 and target > 0:
                f["spin_until"] = now + 15000                    # K-24(a)
        f["prev_target"] = target
    else:
        f["prev_target"] = None
        f["t_before"] = 0

    # -- step 14: caps (C-27) ---------------------------------------------
    ct = tier if st["ready"] else max(tier, 3)
    cpu = cfg["cpu"][ct] if cfg["cpu"] is not None else None
    gpu = cfg["gpu"][ct] if cfg["gpu"] is not None else None

    # -- step 15: timeline and petting (C-34 ... C-40) ----------------------
    # K-11: stage mode ignores shutdown_byte and pid1_comm
    ext_now = cfg["mode"] == "valve" and (
        rd["shutdown_byte"] or rd["pid1_comm"] == SHUTDOWN_COMM)
    if ext_now:
        st["ext"] = True                                         # K-18
    if st["tl0"] is None and (latched_now or ext_now):
        st["tl0"] = now                                          # C-34
    tl0 = st["tl0"]
    done = st["done"]

    def fire(a):                                                 # C-40
        if a not in done:
            done.add(a)
            actions.add(a)

    if cfg["mode"] == "valve":
        if latched_now:
            # C-35 / K-12: sent on the T4 latch tick, also when an external
            # shutdown anchored tl0 earlier.
            fire("signal-pid1")
        if tl0 is not None and now >= tl0 + 45000:
            fire("a1")                                           # C-35
        if st["tf"] is not None:
            fire("a1")                                           # C-36
        due = tl0 is not None and now >= tl0 + 55000             # C-35
        if st["tf"] is not None and (rd["a1_done"] or now >= st["tf"] + 10000):
            due = True                                           # C-36
        if due and "a2" not in done:
            fire("final-pet")
            fire("a2")
            st["a2_tick"] = now
        # C-38 / K-12: sysrq-c requires that a2 was emitted earlier.
        if (flags["p15"] and rd["a2_exited"] and st["a2_tick"] is not None
                and st["a2_tick"] < now):
            fire("sysrq-c")
    else:                                                        # C-39
        if latched_now:
            fire("term-step")
        if tl0 is not None and now >= tl0 + 2000:
            fire("kill-step")
            fire("final-pet")
            fire("trip")
    if "final-pet" not in done:
        actions.add("pet")                                       # C-37

    # -- step 16: events and output ----------------------------------------
    if latched_now and (rd["usb_online"] == 1
                        or st["psy_status"] in ("Charging", "Full")):
        events.add("unplug")                                     # C-31
    if j145_start:
        events.add("j145")                 # C-32/K-17 on start; K-14(g)
    # K-31: cdev cross-check (log only)
    if (fcfg is not None and isinstance(fin, dict)
            and all(is_int(fin.get(k)) for k in ("rpm", "pwm", "cur", "max"))
            and fin["cur"] != demand_level):
        if f["cdev_since"] is None:
            f["cdev_since"] = now
            f["cdev_done"] = False
        if not f["cdev_done"] and now - f["cdev_since"] > 10000:
            events.add("cdev-mismatch")
            f["cdev_done"] = True
    else:
        # AMBIG: a tick without numeric fan input also ends the episode
        f["cdev_since"] = None
        f["cdev_done"] = False
    if lowbatt_start:
        events.add("lowbatt")                                    # C-33

    faults = []
    for s in cfg["measured"]:
        ss = st["sens"][s["name"]]
        if ss["flt"] is not None:
            faults.append("s:%s:%s" % (s["name"], ss["flt"]["code"]))
        if ss["pend"] is not None:
            faults.append("p:" + s["name"])
    for c in cfg["classes"]:
        if st["cls"][c] is not None:
            faults.append("c:" + c)
    for bc in bcodes:
        faults.append("b:" + bc)
    if f["flt"] is not None:
        faults.append("fan:" + f["flt"]["code"])
    if st["selftest_failed"]:
        faults.append("selftest")

    st["tick"] += 1
    st["last_t"] = now
    out = {
        "t": now, "tier": tier, "ready": st["ready"],
        "fan": "-" if target is None else str(target),
        "cpu": "-" if cpu is None else str(cpu), "gpu": "-" if gpu is None else str(gpu),
        "f": ",".join(sorted(faults)) or "-",
        "e": ",".join(sorted(events)) or "-",
        "a": ",".join(sorted(actions)) or "-",
    }
    # K-22: the notice is computed after step 16 from the state only
    out["n"] = notice(cfg, st, now)
    return out, st


def format_line(o):
    return ("t=%d tier=%d ready=%d fan=%s cpu=%s gpu=%s f=%s e=%s a=%s n=%s"
            % (o["t"], o["tier"], o["ready"], o["fan"], o["cpu"], o["gpu"],
               o["f"], o["e"], o["a"], o.get("n", "-")))


# ---------------------------------------------------------------------------
# §15 user-visible notice (K-18 ... K-22)
# ---------------------------------------------------------------------------

# §15 priority; K-54 (rev 7): pmic-hot right after soc-temperature-high
PRIORITY = ("battery-overheating", "skin-temperature-high",
            "soc-temperature-high", "pmic-hot", "usb-connector-hot",
            "fan-failure", "battery-sensor-lost", "sensor-fault",
            "sensor-anomaly", "battery-empty", "cap-write-failed",
            "self-test-failed", "battery-low", "charging-too-warm",
            "shutdown-requested")
HOT_REASON = {"BATT": "battery-overheating", "SKIN": "skin-temperature-high",
              "SOC": "soc-temperature-high", "USB": "usb-connector-hot",
              "PMIC": "pmic-hot"}                            # K-54


def hot_reason(cls):
    # AMBIG: K-19/K-20 name no reason for a hot BOARD (or other) sensor;
    # such a sensor maps to soc-temperature-high (a device-hot reason,
    # K-23). K-54: no longer for PMIC, which maps to pmic-hot.
    return HOT_REASON.get(cls, "soc-temperature-high")


def ceil_s(ms):
    """K-21: seconds, rounded up, never below 0."""
    return max(0, -(-ms // 1000))


def t4_reason(cfg, r):
    """K-19 mapping of one C-19 latch reason."""
    kind, _, name = r.partition(":")
    if kind in ("shutdown", "anomaly"):
        return hot_reason(cfg["by_name"][name]["cls"])
    if kind == "sensor":
        return ("battery-sensor-lost" if cfg["by_name"][name]["cls"] == "BATT"
                else "sensor-fault")
    if kind == "class":
        return "battery-sensor-lost" if name == "BATT" else "sensor-fault"
    return {"classes": "sensor-fault", "p5": "usb-connector-hot",
            "p6": "battery-empty", "fan": "fan-failure",
            "fan-trip2": "fan-failure", "cap": "cap-write-failed",
            "selftest": "self-test-failed"}[kind]


def best(reasons):
    """Highest in the §15 priority list."""
    return min(reasons, key=PRIORITY.index)


def notice(cfg, st, now):
    """K-18 ... K-21. Reads the state after step 16; only warn_last (a
    notice-only field) is written (K-22)."""
    # K-18 shutdown: T4 latched, or (valve) a detected external shutdown
    if st["latched"] or st["ext"]:
        if st["latched"]:
            # K-19 / K-21: the latch-tick reason, kept; it replaces
            # shutdown-requested when T4 latches after an external shutdown
            reason = best({t4_reason(cfg, r) for r in st["t4_reasons"]})
        else:
            reason = "shutdown-requested"
        tl0 = st["tl0"]
        if cfg["mode"] == "valve":
            due = tl0 + 55000
            if st["tf"] is not None:
                due = min(due, st["tf"] + 10000)
            done_tok = "a2"
        else:
            due = tl0 + 2000
            done_tok = "trip"
        secs = 0 if done_tok in st["done"] else ceil_s(due - now)
        return "shutdown:%s:%d" % (reason, secs)
    if st["tier"] < 3:
        return "-"
    # K-20 warn: the conditions holding this tick, each with the earliest
    # running T4 deadline (K-21) or None
    cands = {}

    def add(reason, deadline=None):
        old = cands.get(reason)
        if old is None:
            cands[reason] = deadline
        elif deadline is not None:
            cands[reason] = min(old, deadline)

    for s in cfg["measured"]:
        if st["sens"][s["name"]]["L"] >= SEVERE:
            # AMBIG: K-20 lists BATT/SKIN/SOC; a USB sensor at SEVERE maps to
            # usb-connector-hot, BOARD/other to soc-temperature-high
            add(hot_reason(s["cls"]))
    if st["fan"]["flt"] is not None:
        add("fan-failure", st["fan"]["flt"]["since"] + 120000)
    for s in cfg["measured"]:
        ss = st["sens"][s["name"]]
        if ss["flt"] is not None:
            add("battery-sensor-lost" if s["cls"] == "BATT" else "sensor-fault",
                ss["flt"]["since"] + 120000)
    for c, rec in st["cls"].items():
        if rec is not None:
            add("battery-sensor-lost" if c == "BATT" else "sensor-fault",
                rec["since"] + 120000)
    if any(st["sens"][s["name"]]["pend"] is not None for s in cfg["measured"]):
        add("sensor-anomaly")
    if st["selftest_failed"]:
        add("self-test-failed",
            None if cfg["flags"]["trial_override"] else st["first_t"] + 60000)
    if st["lowbatt"]:
        add("battery-low")
    if st["j145"]:
        add("charging-too-warm")
    if cands:
        reason = best(cands)
        st["warn_last"] = reason
        dl = cands[reason]
        if dl is None:
            return "warn:" + reason
        return "warn:%s:%d" % (reason, ceil_s(dl - now))
    # AMBIG: tier 3 held by C-17 after its condition ended: the last warn
    # reason, without a countdown (no timer to T4 is running)
    return "warn:" + (st["warn_last"] or "sensor-fault")


# ---------------------------------------------------------------------------
# §9 gate (C-41 ... C-44)
# ---------------------------------------------------------------------------

def gate(cfg, rd):
    now = rd["t"]
    _, st = decide(cfg, initial_state(cfg), rd, now)
    reasons = set()
    if st["selftest_failed"]:
        reasons.add("selftest")                                  # C-41
    for s in cfg["measured"]:
        if s["cls"] == "AUX":
            continue
        ss = st["sens"][s["name"]]
        if ss["flt"] is not None or ss["pend"] is not None:
            reasons.add("fault")                                 # C-41, K-13
    for s in cfg["measured"]:
        u = st["sens"][s["name"]]["cur"]["u"]
        if u is None:
            continue
        sev = s["th"][SEVERE]
        if sev is not None and u >= sev - hy_of(s, SEVERE):
            reasons.add("hot:" + s["name"])                      # C-42
        if rd["pstore_marker"]:
            setv = [s["th"][k] for k in SET_SLOTS if s["th"][k] is not None]
            # lowest set slot; min() equals it for an ascending set
            if setv and u >= min(setv):
                reasons.add("hot:" + s["name"])
    p5 = cfg["p5"]
    if p5 and p5.get("sensor") in cfg["by_name"]:
        c = st["sens"][p5["sensor"]]["cur"]
        if c is not None and c["u"] is not None and c["u"] >= p5["t"]:
            reasons.add("hot:" + p5["sensor"])
    psy = rd["psy"]
    warn = False
    if is_int(psy["cap"]) and psy["status"] == "Discharging":
        if psy["cap"] <= 3:
            reasons.add("p6")                                    # C-43
        if psy["cap"] <= 10:
            warn = True       # K-14(f): also warns when refused for p6
    if (cfg["flags"]["j145"] and psy["status"] == "Charging"
            and is_int(psy["temp"]) and psy["temp"] >= 300):
        reasons.add("j145")                                      # C-44
    line = "gate=%s reasons=%s" % ("refuse" if reasons else "pass",
                                   ",".join(sorted(reasons)) or "-")
    if warn:
        line += " warn=lowbatt"
    return line


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def read_ticks(path):
    ticks = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                ticks.append(json.loads(line))
    return ticks


def run(cfg, tick_objs):
    st = initial_state(cfg)
    lines = []
    for obj in tick_objs:
        rd = norm_tick(obj)
        out, st = decide(cfg, st, rd, rd["t"])
        lines.append(format_line(out))
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description="fs-thermald core reference model")
    ap.add_argument("--config", required=True)
    ap.add_argument("--ticks", required=True)
    ap.add_argument("--gate", action="store_true")
    a = ap.parse_args(argv)
    with open(a.config, "r", encoding="utf-8") as fh:
        cfg = load_config(json.load(fh))
    ticks = read_ticks(a.ticks)
    if a.gate:
        if not ticks:
            sys.stderr.write("no ticks\n")
            return 2
        sys.stdout.write(gate(cfg, norm_tick(ticks[0])) + "\n")
        return 0
    for line in run(cfg, ticks):
        sys.stdout.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
