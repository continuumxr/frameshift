#!/usr/bin/env python3
"""Unit tests of the reference core (core_ref.py), from small hand-written
configs and tick sequences. Each rule group has a positive case and a
negative control (one step short of the trigger)."""

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core_ref as C  # noqa: E402

N = None

BASE_CFG = {
    "device": "test", "mode": "valve", "limits": "builtin", "reason": "-",
    "tick_ms": 1000, "psy_period_ms": 1000, "adsp": True,
    "groups": [
        {"name": "soc", "class": "SOC", "min": 1},
        {"name": "skin", "class": "SKIN", "min": 1},
        {"name": "batt", "class": "BATT", "min": 1},
    ],
    "sensors": [
        {"name": "cpu0", "class": "SOC", "group": "soc", "kind": "zone",
         "slow": 0, "indep": 1,
         "th": [N, 89000, 92000, 95000, N, N, 115000],
         "hy": [N, 2000, 2000, 2000, N, N, 2000], "vin": []},
        {"name": "cpu1", "class": "SOC", "group": "soc", "kind": "zone",
         "slow": 0, "indep": 1,
         "th": [N, 89000, 92000, 95000, N, N, 115000],
         "hy": [N, 2000, 2000, 2000, N, N, 2000], "vin": []},
        {"name": "skin", "class": "SKIN", "group": "skin", "kind": "zone",
         "slow": 1, "indep": 0,
         "th": [N, 48000, 50000, 52000, N, N, 60000],
         "hy": [N, 1000, 1000, 1000, N, N, 1000], "vin": []},
        {"name": "batt", "class": "BATT", "group": "batt", "kind": "psy",
         "slow": 1, "indep": 0,
         "th": [N, 58000, 61000, 63000, N, N, 65000],
         "hy": [N, 2000, 2000, 2000, N, N, 2000], "vin": []},
    ],
    "fan": {"levels": [0, 3700, 4500, 5000, 5500], "top": 5500,
            "floor_p1": 3700,
            "floor_tier": [3700, 4500, 5000, 5500, 5500, 5500],
            "rpm_per_sec": 100, "silent_rpm": 4000, "max_pwm": 255,
            "max_rpm": 6000, "zone_fault": False,
            "rules": [{"zone": "cpuss-label", "base": "cpu0",
                       "trips": [{"t": 60000, "h": 5000, "lvl": 1},
                                 {"t": 70000, "h": 5000, "lvl": 2}]}]},
    "caps": {"cpu": [2054400, 1651200, 1382400, 1094400, "min", "min"],
             "gpu": [2, 4, 6, 8, 8, 8]},
    "p5": None,
    "flags": {"trial_override": 0, "headless_fan": 0, "batt_absent": 0,
              "p15": 0, "j145": 0},
}


def mkcfg(**over):
    c = copy.deepcopy(BASE_CFG)
    for k, v in over.items():
        if k == "flags":
            c["flags"].update(v)
        else:
            c[k] = v
    return c


class Runner:
    """Feeds ticks to decide(). The fan's rpm follows the previous tick's
    target (alternating +0/+10 so F5 never sees a repeated value) unless a
    fan reading is given. 'hold' overrides persist across steps."""

    def __init__(self, cfg_obj, t0=1000):
        self.cfg = C.load_config(cfg_obj)
        self.st = C.initial_state(self.cfg)
        self.t = t0 - 1000
        self.last = None
        self.hold = {}
        self.outs = []

    def demand_level(self):
        """cdev cur_state as the kernel would show it: the demand level of
        the previous tick (K-31 then sees no mismatch by default)."""
        fcfg = self.cfg["fan"]
        if not fcfg:
            return 0
        dl = 0
        for ri, r in enumerate(fcfg["rules"]):
            for j, tp in enumerate(r["trips"]):
                if self.st["fan"]["trips"][ri][j]:
                    dl = max(dl, tp["lvl"])
        return dl

    def base(self, t):
        k = t // 1000
        tgt = 3700
        if self.last is not None and self.last["fan"] != "-":
            tgt = int(self.last["fan"])
        return {
            "t": t,
            "s": {"cpu0": 40000, "cpu1": 40000, "skin": 30000},
            "psy": {"temp": 250, "volt": 4000000 + (k % 2) * 1000,
                    "curr": -300000, "cap": 80, "status": "Discharging"},
            "usb_online": 0, "adsp": "running",
            "fan": {"rpm": tgt + (k % 2) * 10, "pwm": 120,
                    "cur": self.demand_level(), "max": 4},
        }

    @staticmethod
    def merge(tick, ov):
        for key, v in ov.items():
            if key in ("s", "psy") and isinstance(v, dict):
                tick[key] = dict(tick[key], **v)
            elif key == "fan" and isinstance(v, dict) and isinstance(tick.get("fan"), dict):
                tick["fan"] = dict(tick["fan"], **v)
            else:
                tick[key] = v

    def set(self, **ov):
        for key, v in ov.items():
            if key in ("s", "psy", "fan") and isinstance(v, dict):
                self.hold[key] = dict(self.hold.get(key, {}), **v)
            else:
                self.hold[key] = v

    def step(self, dt=1000, **ov):
        t = self.t + dt
        tick = self.base(t)
        self.merge(tick, copy.deepcopy(self.hold))
        self.merge(tick, ov)
        rd = C.norm_tick(tick)
        out, self.st = C.decide(self.cfg, self.st, rd, t)
        self.t = t
        self.last = out
        self.outs.append(out)
        return out

    def until(self, t_end, **ov):
        out = None
        while self.t < t_end:
            out = self.step(**ov)
        return out

    def at(self, t):
        for o in self.outs:
            if o["t"] == t:
                return o
        raise KeyError(t)


def items(out, field):
    v = out[field]
    return set() if v == "-" else set(v.split(","))


def t4(out):
    return {e for e in items(out, "e") if e.startswith("t4:")}


class Base(unittest.TestCase):
    def assertIn_(self, x, out, field):
        self.assertIn(x, items(out, field), C.format_line(out))

    def assertNotIn_(self, x, out, field):
        self.assertNotIn(x, items(out, field), C.format_line(out))


# ---------------------------------------------------------------------------
class TestQuiet(Base):
    def test_quiet_run(self):
        r = Runner(mkcfg())
        o = r.step()
        self.assertEqual(C.format_line(o),
                         "t=1000 tier=0 ready=1 fan=3700 cpu=2054400 gpu=2 "
                         "f=- e=ready a=pet n=-")
        o = r.until(200000)
        self.assertEqual(C.format_line(o),
                         "t=200000 tier=0 ready=1 fan=3700 cpu=2054400 gpu=2 "
                         "f=- e=- a=pet n=-")
        for o in r.outs:
            self.assertEqual(o["f"], "-", C.format_line(o))
            self.assertEqual(o["tier"], 0)


# --------------------------------------------------------------- C-1 ... C-6
class TestHealth(Base):
    def test_c1_read_err_and_absent(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": "ERR"})
        self.assertIn_("s:cpu0:read", o, "f")
        o = Runner(mkcfg()).step(s={"cpu0": "ABSENT"})
        self.assertIn_("s:cpu0:read", o, "f")
        # a sensor missing from "s" is ABSENT
        r3 = Runner(mkcfg())
        r3.step()
        tick = r3.base(2000)
        del tick["s"]["cpu0"]
        out, r3.st = C.decide(r3.cfg, r3.st, C.norm_tick(tick), 2000)
        self.assertEqual(out["f"], "s:cpu0:read")
        # negative control: a numeric reading is not a read fault
        o = Runner(mkcfg()).step(s={"cpu0": 0})
        self.assertEqual(o["f"], "-")

    def test_c2_low(self):
        r = Runner(mkcfg())
        o = r.step(s={"cpu0": -20001})
        self.assertIn_("s:cpu0:low", o, "f")
        o = Runner(mkcfg()).step(s={"cpu0": -20000})
        self.assertEqual(o["f"], "-")

    def _frozen_cfg(self):
        c = mkcfg()
        c["groups"].append({"name": "board", "class": "BOARD", "min": 1})
        c["sensors"].append({"name": "in0", "class": "AUX", "group": None,
                             "kind": "aux", "slow": 0, "indep": 0,
                             "th": [N] * 7, "hy": [N] * 7, "vin": []})
        c["sensors"].append({"name": "virt", "class": "BOARD", "group": "board",
                             "kind": "zone", "slow": 0, "indep": 0,
                             "th": [N] * 7, "hy": [N] * 7, "vin": ["in0"]})
        return c

    def _run_frozen(self, moved):
        r = Runner(self._frozen_cfg())
        r.set(s={"virt": 35000, "in0": 30000})
        r.step()                                  # t=1000: frozen_since=1000
        r.set(s={"in0": 30000 + moved})
        return r

    def test_c3_frozen(self):
        r = self._run_frozen(1001)
        o = r.until(120000)                       # now - since = 119000
        self.assertNotIn_("s:virt:frozen", o, "f")
        o = r.step()                              # t=121000: 120000
        self.assertIn_("s:virt:frozen", o, "f")
        self.assertIn_("c:BOARD", o, "f")

    def test_c3_frozen_negative_move_1000(self):
        r = self._run_frozen(1000)
        o = r.until(200000)
        self.assertEqual(o["f"], "-")

    def test_c3_reset_on_change(self):
        r = self._run_frozen(1001)
        r.until(60000)
        r.step(s={"virt": 35001})                 # changes -> since = 61000
        r.set(s={"virt": 35001, "in0": 30000})
        r.step()
        r.set(s={"in0": 31001})
        o = r.until(180000)                       # 180000 - 61000 < 120000
        self.assertNotIn_("s:virt:frozen", o, "f")
        o = r.step()                              # 181000 - 61000 = 120000
        self.assertIn_("s:virt:frozen", o, "f")

    def test_k4_frozen_folds_this_tick_input_first(self):
        r = Runner(self._frozen_cfg())
        r.set(s={"virt": 35000, "in0": 30000})
        o = r.until(120000)
        self.assertEqual(o["f"], "-")
        o = r.step(s={"in0": 31001})               # 121000: moved this tick
        self.assertIn_("s:virt:frozen", o, "f")
        r = Runner(self._frozen_cfg())
        r.set(s={"virt": 35000, "in0": 30000})
        r.until(119000)
        o = r.step(s={"in0": 31001})               # 120000: only 119000
        self.assertNotIn_("s:virt:frozen", o, "f")

    def test_k3_anomalous_input_not_usable(self):
        c = self._frozen_cfg()
        c["sensors"][-1]["vin"] = ["cpu1"]
        r = Runner(c)
        r.set(s={"virt": 35000, "cpu1": 40000})
        r.until(120000)
        o = r.step(s={"cpu1": 130000})             # hot: not a usable input
        self.assertNotIn_("s:virt:frozen", o, "f")
        r = Runner(c)
        r.set(s={"virt": 35000, "cpu1": 40000})
        r.until(120000)
        o = r.step(s={"cpu1": 41001})
        self.assertIn_("s:virt:frozen", o, "f")

    def test_c4_hot(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": 125001})
        self.assertIn_("p:cpu0", o, "f")
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": 125000})
        self.assertNotIn_("p:cpu0", o, "f")

    def test_c5_rise(self):
        # skin is slow: +10001 in 1000 ms is a rise; +10000 is not
        r = Runner(mkcfg())
        r.step(s={"skin": 30000})
        o = r.step(s={"skin": 40001})
        self.assertIn_("s:skin:rise", o, "f")     # C-8: no sibling, below SEVERE
        r = Runner(mkcfg())
        r.step(s={"skin": 30000})
        o = r.step(s={"skin": 40000})
        self.assertEqual(o["f"], "-")
        # a non-slow sensor never has a rise anomaly
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": 90000})
        self.assertEqual(o["f"], "-")

    def test_c5_rise_uses_last_numeric_reading(self):
        r = Runner(mkcfg())
        r.step(s={"skin": 30000})
        r.step(s={"skin": "ERR"})
        o = r.step(s={"skin": 50000})             # 20000 over 2000 ms = 10/s
        self.assertNotIn_("s:skin:rise", o, "f")
        r = Runner(mkcfg())
        r.step(s={"skin": 30000})
        r.step(s={"skin": "ERR"})
        o = r.step(s={"skin": 50001})
        self.assertIn_("s:skin:read", o, "f")     # first code kept
        self.assertEqual(r.st["sens"]["skin"]["flt"]["code"], "read")

    def test_aux_never_faults(self):
        c = TestHealth._frozen_cfg(self)
        r = Runner(c)
        o = r.step(s={"virt": 35000, "in0": "ERR"})
        self.assertEqual(o["f"], "-")
        o = r.step(s={"virt": 35000, "in0": -30000})
        self.assertEqual(o["f"], "-")


# ------------------------------------------------------------- C-7 / C-8
class TestAnomaly(Base):
    def test_c7_confirmed_latches_at_n2(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"cpu0": 130000, "cpu1": 96000})   # cpu1 >= SEVERE blocks
        o0 = r.step()                              # detection, n=0
        self.assertIn_("p:cpu0", o0, "f")
        self.assertEqual(o0["tier"], 3)
        o1 = r.step()                              # n=1: negative control
        self.assertEqual(t4(o1), set())
        self.assertIn_("p:cpu0", o1, "f")
        o2 = r.step()                              # n=2: resolves
        self.assertEqual(t4(o2), {"t4:anomaly:cpu0"})
        self.assertNotIn_("p:cpu0", o2, "f")
        self.assertEqual(o2["tier"], 4)

    def test_c7_contradicted_becomes_fault(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"cpu0": 130000})                  # cpu1 40000 < SEVERE
        r.step()
        o1 = r.step()
        self.assertNotIn_("s:cpu0:contra", o1, "f")
        o2 = r.step()
        self.assertIn_("s:cpu0:contra", o2, "f")
        self.assertNotIn_("p:cpu0", o2, "f")
        self.assertEqual(t4(o2), set())
        self.assertEqual(o2["tier"], 3)

    def test_c7_contradiction_remembered(self):
        # contradicted only on the detection tick: still a fault at n=2
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": 130000})
        r.step(s={"cpu0": 130000, "cpu1": "ERR"})
        o = r.step(s={"cpu0": 130000, "cpu1": "ERR"})
        self.assertIn_("s:cpu0:contra", o, "f")
        self.assertNotIn_("t4:anomaly:cpu0", o, "e")

    def test_c7_unhealthy_sibling_does_not_contradict(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"cpu0": 130000, "cpu1": "ERR"})
        r.step()
        r.step()
        o = r.step()
        self.assertIn_("t4:anomaly:cpu0", o, "e")

    def test_c8_no_sibling_rise_below_severe_faults_at_once(self):
        r = Runner(mkcfg())
        r.step(s={"skin": 30000})
        o = r.step(s={"skin": 51999})               # below SEVERE 52000
        self.assertIn_("s:skin:rise", o, "f")
        self.assertNotIn_("p:skin", o, "f")

    def test_c8_no_sibling_rise_at_severe_latches(self):
        r = Runner(mkcfg())
        r.step(s={"skin": 41999})
        o0 = r.step(s={"skin": 52000})              # rise, at SEVERE -> pending
        self.assertIn_("p:skin", o0, "f")
        self.assertNotIn_("s:skin:rise", o0, "f")
        o1 = r.step(s={"skin": 52000})
        self.assertEqual(t4(o1), set())
        o2 = r.step(s={"skin": 52000})
        self.assertIn_("t4:anomaly:skin", o2, "e")

    def test_c8_no_sibling_hot_never_contradicted(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"skin": 130000})
        o0 = r.step()
        self.assertIn_("p:skin", o0, "f")
        o1 = r.step()
        self.assertEqual(t4(o1), set())
        o2 = r.step()
        self.assertIn_("t4:anomaly:skin", o2, "e")

    def test_c7_sole_indep_sensor_is_no_sibling(self):
        c = mkcfg()
        c["sensors"][1]["indep"] = 0                # cpu1 not indep
        r = Runner(c)
        r.step()
        r.set(s={"cpu0": 130000})
        r.step(); r.step()
        o = r.step()
        self.assertIn_("t4:anomaly:cpu0", o, "e")

    def test_k1_pending_and_fault_independent(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": 130000, "cpu1": 96000})   # pending
        o = r.step(s={"cpu0": "ERR", "cpu1": 96000})
        self.assertIn_("p:cpu0", o, "f")
        self.assertIn_("s:cpu0:read", o, "f")
        o = r.step(s={"cpu0": "ERR", "cpu1": 96000})  # n=2: not contradicted
        self.assertIn_("t4:anomaly:cpu0", o, "e")
        # contra on an already faulted sensor keeps reason and since
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": 130000})                  # 2000 pending (contra)
        r.step(s={"cpu0": "ERR"})                   # 3000 fault read
        o = r.step(s={"cpu0": 130000})              # 4000 resolves contra
        self.assertEqual(r.st["sens"]["cpu0"]["flt"],
                         {"code": "read", "since": 3000, "ok": None})
        self.assertIn_("s:cpu0:read", o, "f")
        self.assertNotIn_("p:cpu0", o, "f")

    def test_c7_faulted_sensor_does_not_become_pending(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})
        o = r.step(s={"cpu0": 130000})
        self.assertNotIn_("p:cpu0", o, "f")
        self.assertIn_("s:cpu0:read", o, "f")


# ------------------------------------------------------------------- C-9
class TestFaultLifecycle(Base):
    def test_c9_latch_at_120s(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"cpu0": "ERR"})
        r.step()                                     # fault_since = 2000
        o = r.until(121000)                          # 119000
        self.assertEqual(t4(o), set())
        self.assertEqual(o["tier"], 3)
        o = r.step()                                 # 122000: 120000
        self.assertEqual(t4(o), {"t4:sensor:cpu0"})

    def test_c9_clear_after_30s_healthy(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})                    # 2000
        r.until(10000, s={"cpu0": "ERR"})
        r.step()                                     # 11000 first healthy
        o = r.until(40000)                           # 29000 healthy
        self.assertIn_("s:cpu0:read", o, "f")
        o = r.step()                                 # 41000: 30000
        self.assertEqual(o["f"], "-")

    def test_c9_clear_before_t4_same_tick(self):
        # healthy from 92000 -> clears at 122000 = since + 120000: no T4
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})                    # since 2000
        r.until(91000, s={"cpu0": "ERR"})
        o = r.until(122000)
        self.assertEqual(o["f"], "-")
        self.assertFalse(r.st["latched"])
        # negative: healthy from 93000 -> still active at 122000 -> T4
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})
        r.until(92000, s={"cpu0": "ERR"})
        o = r.until(122000)
        self.assertIn_("t4:sensor:cpu0", o, "e")

    def test_c11_class_clear_before_t4_same_tick(self):
        c = mkcfg(adsp=True)
        r = Runner(c)
        r.step()
        r.step(adsp="offline")                       # BATT since 2000
        r.until(91000, adsp="offline")
        o = r.until(122000)
        self.assertFalse(r.st["latched"], C.format_line(o))
        r = Runner(c)
        r.step()
        r.step(adsp="offline")
        r.until(92000, adsp="offline")
        o = r.until(122000)
        self.assertIn_("t4:class:BATT", o, "e")

    def test_c9_unhealthy_tick_restarts_recovery(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})                    # 2000
        r.until(20000)                               # healthy from 3000
        r.step(s={"cpu0": "ERR"})                    # 21000 resets
        o = r.until(51000)                           # healthy since 22000: 29000
        self.assertIn_("s:cpu0:read", o, "f")
        o = r.step()
        self.assertNotIn_("s:cpu0:read", o, "f")

    def test_c9_recovery_window_still_latches(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})                    # since 2000
        r.until(100000, s={"cpu0": "ERR"})
        o = r.until(121000)                          # healthy since 101000
        self.assertEqual(t4(o), set())
        self.assertIn_("s:cpu0:read", o, "f")
        o = r.step()                                 # 122000: 120000 >= 120000
        self.assertIn_("t4:sensor:cpu0", o, "e")

    def test_c9_new_fault_keeps_since(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})                    # 2000
        r.until(60000, s={"cpu0": "ERR"})
        r.set(s={"cpu0": -30000})                    # new fault while active
        r.until(121000)
        self.assertEqual(r.st["sens"]["cpu0"]["flt"]["since"], 2000)
        self.assertEqual(r.st["sens"]["cpu0"]["flt"]["code"], "read")  # K-2
        self.assertFalse(r.st["latched"])
        o = r.step()                                 # 122000: 120000
        self.assertIn_("t4:sensor:cpu0", o, "e")
        self.assertIn_("s:cpu0:read", o, "f")


# ------------------------------------------------------------------ C-10
class TestLevels(Base):
    def test_c10_up_at_each_threshold(self):
        cases = [(89000, 1), (92000, 2), (95000, 3)]
        for th, tier in cases:
            o = Runner(mkcfg()).step(s={"cpu0": th})
            self.assertEqual(o["tier"], tier, th)
            o = Runner(mkcfg()).step(s={"cpu0": th - 1})
            self.assertEqual(o["tier"], tier - 1, th - 1)
        o = Runner(mkcfg()).step(s={"cpu0": 115000})
        self.assertEqual(t4(o), {"t4:shutdown:cpu0"})
        self.assertEqual(o["tier"], 4)
        o = Runner(mkcfg()).step(s={"cpu0": 114999})
        self.assertEqual(t4(o), set())
        self.assertEqual(o["tier"], 3)

    def _down(self, level_value, release, ticks_below):
        r = Runner(mkcfg())
        r.step(s={"cpu0": level_value})
        r.set(s={"cpu0": release})
        outs = [r.step() for _ in range(ticks_below)]
        return outs

    def test_c10_down_dwell_30s(self):
        for th, tier in ((89000, 1), (92000, 2), (95000, 3)):
            outs = self._down(th, th - 2000 - 1, 31)   # below release
            # down_since = 2000; 31000 -> 29000 elapsed; 32000 -> 30000
            self.assertEqual(outs[29]["tier"], tier, th)   # t=31000
            self.assertEqual(outs[30]["tier"], tier - 1, th)   # t3 hold over
        # SEVERE: tier 3 also held by C-17, so check the level itself
        r = Runner(mkcfg())
        r.step(s={"cpu0": 95000})
        r.set(s={"cpu0": 92999})
        r.until(31000)
        self.assertEqual(r.st["sens"]["cpu0"]["L"], 3)
        r.step()
        self.assertEqual(r.st["sens"]["cpu0"]["L"], 2)

    def test_c10_no_drop_at_release(self):
        for th, tier in ((89000, 1), (92000, 2)):
            outs = self._down(th, th - 2000, 60)
            self.assertEqual(outs[-1]["tier"], tier, th)

    def test_c10_multi_step_drop_and_restart(self):
        r = Runner(mkcfg())
        r.step(s={"cpu0": 95000})                 # L = 3
        r.set(s={"cpu0": 89500})                  # below 93000 and 90000
        r.until(31000)
        self.assertEqual(r.st["sens"]["cpu0"]["L"], 3)
        r.step()                                  # 32000: -> L = 1 (89500>=87000)
        self.assertEqual(r.st["sens"]["cpu0"]["L"], 1)
        self.assertIsNone(r.st["sens"]["cpu0"]["down"])
        r.set(s={"cpu0": 86999})
        r.step()                                  # 33000 down_since
        r.until(62000)
        self.assertEqual(r.st["sens"]["cpu0"]["L"], 1)
        r.step()                                  # 63000
        self.assertEqual(r.st["sens"]["cpu0"]["L"], 0)

    def test_c10_unusable_resets_dwell(self):
        r = Runner(mkcfg())
        r.step(s={"cpu0": 89000})
        r.set(s={"cpu0": 86000})
        r.until(20000)
        r.step(s={"cpu0": 130000})                # anomalous: down_since reset
        r.until(50000)
        self.assertEqual(r.st["sens"]["cpu0"]["L"], 1)


# ------------------------------------------------------------ C-11 / C-12
class TestClasses(Base):
    def test_c11_group_short_class_latch(self):
        c = mkcfg()
        c["groups"][0]["min"] = 2
        r = Runner(c)
        r.step()
        r.set(s={"cpu0": "ERR"})
        o = r.step()                                 # 2000
        self.assertIn_("c:SOC", o, "f")
        o = r.until(121000)
        self.assertEqual(t4(o), set())
        o = r.step()
        self.assertEqual(t4(o), {"t4:class:SOC", "t4:sensor:cpu0"})

    def test_c11_min1_not_short(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": "ERR"})
        self.assertNotIn_("c:SOC", o, "f")

    def test_c11_recovering_sensor_not_counted(self):
        c = mkcfg()
        c["groups"][0]["min"] = 2
        r = Runner(c)
        r.step()
        r.step(s={"cpu0": "ERR"})
        o = r.step()                                 # healthy, fault active
        self.assertIn_("c:SOC", o, "f")

    def test_c11_two_classes_at_once(self):
        c = mkcfg()
        c["groups"][0]["min"] = 2
        r = Runner(c)
        r.step()
        o = r.step(s={"cpu0": "ERR", "skin": "ERR"})
        self.assertIn_("t4:classes", o, "e")
        r = Runner(c)
        r.step()
        o = r.step(s={"cpu0": "ERR"})                # one class only
        self.assertEqual(t4(o), set())

    def test_c11_class_clear_after_30s(self):
        c = mkcfg()
        c["groups"][0]["min"] = 2
        r = Runner(c)
        r.step()
        r.step(s={"cpu0": "ERR"})                    # 2000
        # sensor fault clears at 33000 (healthy since 3000); class raw
        # healthy from 33000 -> class clears at 63000
        o = r.until(62000)
        self.assertIn_("c:SOC", o, "f")
        o = r.step()
        self.assertEqual(o["f"], "-")

    def test_c12_adsp(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(adsp="offline")
        self.assertIn_("b:adsp", o, "f")
        self.assertIn_("c:BATT", o, "f")
        o = Runner(mkcfg(adsp=False)).step(adsp="offline")
        self.assertEqual(o["f"], "-")
        o = Runner(mkcfg()).step(adsp="ERR")
        self.assertIn_("b:adsp", o, "f")

    def test_c12_psy_err(self):
        r = Runner(mkcfg(psy_period_ms=5000))
        r.step()                                     # sample 1000
        o = r.step(psy={"volt": "ERR"})              # 2000: not a sample
        self.assertEqual(o["f"], "-")
        r.until(5000)
        o = r.step(psy={"volt": "ERR"})              # 6000: sample
        self.assertIn_("b:psy", o, "f")
        o = r.step()                                 # 7000: held
        self.assertIn_("b:psy", o, "f")
        o = r.until(10000)
        self.assertIn_("b:psy", o, "f")
        o = r.step()                                 # 11000: clean sample
        self.assertNotIn_("b:psy", o, "f")

    def test_c12_stale(self):
        r = Runner(mkcfg())
        r.set(psy={"volt": 4000000})
        r.step()                                     # 1000 first sample
        r.step()                                     # 2000 equal -> since 2000
        o = r.until(62000)                           # 60000: not > 60000
        self.assertNotIn_("b:stale", o, "f")
        o = r.step()                                 # 63000
        self.assertIn_("b:stale", o, "f")
        self.assertIn_("c:BATT", o, "f")
        o = r.step(psy={"curr": -300001})            # change clears stale
        self.assertNotIn_("b:stale", o, "f")

    def test_c12_stale_negative_any_field_moves(self):
        r = Runner(mkcfg())
        r.set(psy={"volt": 4000000})
        r.step()
        for i in range(100):
            o = r.step(psy={"temp": 250 + (i % 2)})
            self.assertNotIn_("b:stale", o, "f")

    def test_k14h_min0_group_never_short(self):
        c = mkcfg()
        c["groups"].append({"name": "x", "class": "USB", "min": 0})
        o = Runner(c).step()
        self.assertEqual(o["e"], "ready")
        self.assertEqual(o["f"], "-")

    def test_c12_batt_absent(self):
        c = mkcfg(flags={"batt_absent": 1})
        r = Runner(c)
        o = r.step(psy={"temp": "ERR", "volt": "ERR"}, adsp="offline")
        self.assertEqual(o["f"], "-")
        self.assertEqual(o["e"], "ready")


# ------------------------------------------------------- C-13 / C-14 / C-17
class TestP5P6P13(Base):
    def test_c13_p5(self):
        c = mkcfg(p5={"sensor": "cpu1", "t": 100000})
        o = Runner(c).step(s={"cpu1": 100000})
        self.assertIn_("t4:p5", o, "e")
        o = Runner(c).step(s={"cpu1": 99999})
        self.assertEqual(t4(o), set())

    def test_c14_p6(self):
        o = Runner(mkcfg()).step(psy={"cap": 3})
        self.assertEqual(t4(o), {"t4:p6"})
        o = Runner(mkcfg()).step(psy={"cap": 4})
        self.assertEqual(t4(o), set())
        o = Runner(mkcfg()).step(psy={"cap": 3, "status": "Charging"})
        self.assertEqual(t4(o), set())

    def test_c14_p13_lowbatt(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(psy={"cap": 10})
        self.assertIn_("lowbatt", o, "e")
        self.assertEqual(o["tier"], 3)
        o = r.step(psy={"cap": 10})
        self.assertNotIn_("lowbatt", o, "e")         # event only at start
        self.assertEqual(o["tier"], 3)
        r = Runner(mkcfg())
        r.step()
        o = r.step(psy={"cap": 11})
        self.assertNotIn_("lowbatt", o, "e")
        self.assertEqual(o["tier"], 0)

    def test_c14_lowbatt_held_between_samples(self):
        r = Runner(mkcfg(psy_period_ms=5000))
        r.step(psy={"cap": 9})                       # sample at 1000
        o = r.step(psy={"cap": 80})                  # 2000 not a sample
        self.assertEqual(o["tier"], 3)
        r.until(5000)
        o = r.step(psy={"cap": 80})                  # 6000 sample: off
        self.assertEqual(o["tier"], 3)               # C-17 hold (t3 at 1000)
        self.assertFalse(r.st["lowbatt"])

    def test_c17_tier3_hold(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(psy={"cap": 10})                  # 2000: tier 3
        self.assertEqual(o["tier"], 3)
        o = r.until(31000)                           # 29000 shown
        self.assertEqual(o["tier"], 3)
        o = r.step()                                 # 32000: 30000
        self.assertEqual(o["tier"], 0)

    def test_c17_hold_not_for_lower_tiers(self):
        r = Runner(mkcfg())
        r.step(s={"cpu0": 92000})                    # tier 2
        o = r.step(s={"cpu0": 40000})                # dwell starts
        self.assertEqual(o["tier"], 2)
        o = r.until(32000, s={"cpu0": 40000})
        self.assertEqual(o["tier"], 0)


# ------------------------------------------------------------------ C-18
class TestT5(Base):
    def test_c18_soc(self):
        r = Runner(mkcfg())
        r.step(s={"cpu0": 115000})                   # T4
        o = r.step(s={"cpu0": 119999})
        self.assertEqual(o["tier"], 4)
        self.assertNotIn_("t5:p12:cpu0", o, "e")
        o = r.step(s={"cpu0": 120000})
        self.assertEqual(o["tier"], 5)
        self.assertIn_("t5:p12:cpu0", o, "e")
        o = r.step(s={"cpu0": 130000})
        self.assertEqual(o["e"], "-")                # once

    def test_c18_on_latch_tick(self):
        o = Runner(mkcfg()).step(s={"cpu0": 120000})
        self.assertEqual(o["tier"], 5)
        self.assertIn_("t4:shutdown:cpu0", o, "e")
        self.assertIn_("t5:p12:cpu0", o, "e")

    def test_c18_skin(self):
        r = Runner(mkcfg())
        r.step(s={"cpu0": 115000})                   # T4
        for v in (38000, 46000, 54000, 62000):
            r.step(s={"cpu0": 115000, "skin": v})
        o = r.step(s={"cpu0": 115000, "skin": 62999})
        self.assertNotIn_("t5:p12:skin", o, "e")
        o = r.step(s={"cpu0": 115000, "skin": 63000})
        self.assertIn_("t5:p12:skin", o, "e")

    def test_c18_not_without_t4(self):
        o = Runner(mkcfg()).step(s={"skin": 30000})
        r = Runner(mkcfg())
        r.step(s={"cpu1": 114000})
        o = r.step(s={"cpu1": 114999})
        self.assertNotIn_("t5:p12:cpu1", o, "e")


# -------------------------------------------------------- C-20 ... C-26
class TestFan(Base):
    def test_c20_demand_and_hysteresis(self):
        r = Runner(mkcfg())
        o = r.step(s={"cpu0": 59999})
        self.assertEqual(o["fan"], "3700")
        o = r.step(s={"cpu0": 60000})                # trip 0 -> lvl1 3700
        self.assertTrue(r.st["fan"]["trips"][0][0])
        o = r.step(s={"cpu0": 70000})                # trip 1 -> lvl2 4500
        self.assertEqual(o["fan"], "4500")
        o = r.step(s={"cpu0": 65000})                # 65000 = 70000-5000: held
        self.assertEqual(o["fan"], "4500")
        o = r.step(s={"cpu0": 64999})
        self.assertEqual(o["fan"], "3700")
        self.assertTrue(r.st["fan"]["trips"][0][0])
        o = r.step(s={"cpu0": "ERR"})                # unusable: unchanged
        self.assertTrue(r.st["fan"]["trips"][0][0])

    def test_c21_target_floors_and_top(self):
        r = Runner(mkcfg())
        o = r.step(s={"cpu0": 89000})                # tier 1: floor 4500
        self.assertEqual(o["fan"], "4500")
        o = Runner(mkcfg()).step(s={"cpu0": 115000})  # T4: top
        self.assertEqual(o["fan"], "5500")
        o = Runner(mkcfg()).step(caps_ok_at_start=False)  # not READY: top
        self.assertEqual(o["fan"], "5500")

    def test_c22_allowance(self):
        r = Runner(mkcfg())
        r.step()                                     # 0 -> 3700, both silent
        self.assertEqual(r.st["fan"]["allow_until"], 1000 + 15000)
        r.step(s={"cpu0": 89000})                    # 3700 -> 4500 ramp 8000
        self.assertEqual(r.st["fan"]["allow_until"], 2000 + 15000 + 8000)
        r.step(s={"cpu0": 89000})                    # unchanged: kept
        self.assertEqual(r.st["fan"]["allow_until"], 25000)
        c = mkcfg()
        c["fan"]["floor_tier"][1] = 3900
        r = Runner(c)
        r.step()
        r.step(s={"cpu1": 89000})                    # 3700 -> 3900 both silent
        self.assertEqual(r.st["fan"]["allow_until"], 2000 + 15000)

    def test_c23_f6_absent_err_wrerr(self):
        # K-44: the C-23 tick condition is a fault (F6) only on >= 5 of the
        # last 20 ticks
        for ov in ({"fan": "ABSENT"}, {"fan": {"rpm": "ERR"}},
                   {"fan": {"cur": "ERR"}}, {"fan_wr_err": True}):
            r = Runner(mkcfg())
            r.step()
            for _ in range(4):
                o = r.step(**ov)
                self.assertNotIn_("fan:F6", o, "f")
                self.assertEqual(o["tier"], 0)
            o = r.step(**ov)                         # the 5th
            self.assertIn_("fan:F6", o, "f")
            self.assertEqual(o["fan"], "5500")
            self.assertEqual(o["tier"], 3)
        # 4 failures in every 20 ticks: never a fault
        r = Runner(mkcfg())
        r.step()
        for i in range(100):
            o = r.step(**({"fan": {"rpm": "ERR"}} if i % 5 == 0 else {}))
            self.assertNotIn_("fan:F6", o, "f")
        r = Runner(mkcfg())
        r.step()
        o = r.step()
        self.assertEqual(o["f"], "-")

    def test_c23_f1(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(fan={"cur": 5})
        self.assertIn_("fan:F1", o, "f")
        r = Runner(mkcfg())
        r.step()
        o = r.step(fan={"cur": 4})
        self.assertEqual(o["f"], "-")

    def test_c24_f2(self):
        r = Runner(mkcfg())
        r.set(fan={"rpm": 0})
        r.step()                                     # 1000, allow 16000
        o = r.until(35000)                           # cond from 16000: 19000
        self.assertEqual(o["f"], "-")
        o = r.until(36000)                           # 20000: not > 20000
        self.assertEqual(o["f"], "-")
        o = r.step()                                 # 37000: 21000
        self.assertIn_("fan:F2", o, "f")

    def _alt(self, a, b):
        return lambda r: {"rpm": a if (r.t // 1000) % 2 else b}

    def test_c24_f3(self):
        # rpm 4255/4254 is within max(500, 555) of 3700: never F3
        r = Runner(mkcfg())
        for _ in range(80):
            k = ((r.t + 1000) // 1000) % 2
            o = r.step(fan={"rpm": 3700 + 555 - k})
        self.assertEqual(o["f"], "-")
        # F3 with off = 556 - k: k=1 gives 555; use a fixed +556 / +557
        r = Runner(mkcfg())
        for _ in range(70):
            k = ((r.t + 1000) // 1000) % 2
            o = r.step(fan={"rpm": 3700 + 556 + k})
            if r.t == 61000:
                self.assertEqual(o["f"], "-")
            if r.t == 62000:
                self.assertIn_("fan:F3", o, "f")

    def test_c24_f4(self):
        # see TestK24FanNotStarved.test_k24c_* (F4 against fan.max_rpm)
        c = mkcfg()
        c["fan"]["floor_p1"] = 5000
        c["fan"]["floor_tier"][0] = 5000
        c["fan"]["silent_rpm"] = 6000
        r = Runner(c)
        for _ in range(62):
            k = ((r.t + 1000) // 1000) % 2
            o = r.step(fan={"rpm": 5099 - k, "pwm": 255})
        self.assertIn_("fan:F4", o, "f")

    def test_c24_f5(self):
        r = Runner(mkcfg())
        r.set(fan={"rpm": 3700})
        o = r.until(46000)                           # cond from 16000
        self.assertEqual(o["f"], "-")
        o = r.step()                                 # 47000: 31000
        self.assertIn_("fan:F5", o, "f")
        r = Runner(mkcfg())                          # alternating: never
        o = r.until(200000)
        self.assertEqual(o["f"], "-")

    def test_c25_fan_lifecycle_120s_and_clear(self):
        r = Runner(mkcfg())
        r.step()
        r.set(fan="ABSENT")
        r.until(6000)                                # F6 since 6000 (K-44)
        o = r.until(125000)
        self.assertEqual(t4(o), set())
        o = r.step()
        self.assertEqual(t4(o), {"t4:fan"})
        # clear (K-15, K-16): 5 bad ticks 2000..6000 -> target top at 6000,
        # allowance until 6000 + 15000 + 18000 = 39000; ticks inside it
        # never count, so the 60 s clear runs from 39000: 59 s at 98000
        # (still active), 60 s at 99000 (cleared)
        r = Runner(mkcfg())
        r.step()
        for _ in range(5):
            r.step(fan="ABSENT")
        self.assertEqual(r.st["fan"]["allow_until"], 39000)
        o = r.until(98000)
        self.assertIn_("fan:F6", o, "f")
        o = r.step()                                 # 99000
        self.assertNotIn_("fan:F6", o, "f")
        self.assertFalse(r.st["latched"])

    def test_k16_sensor_and_class_keep_30s(self):
        # the 60 s window is for the fan only: a sensor fault still clears
        # after 30 s (healthy from 3000 -> cleared at 33000)
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})
        o = r.until(32000)
        self.assertIn_("s:cpu0:read", o, "f")
        o = r.step()
        self.assertEqual(o["f"], "-")

    def test_k15_allowance_tick_resets_clear_timer(self):
        # F6 from 5 absent ticks (2000..6000, K-44) -> target top at 6000,
        # allowance until 6000 + 15000 + 18000 = 39000; the F6 rate holds
        # to 21000; the clear timer starts at 39000. Then force a new
        # allowance by writing it and check the timer reset
        r = Runner(mkcfg())
        r.step()
        for _ in range(5):
            r.step(fan="ABSENT")
        self.assertEqual(r.st["fan"]["allow_until"], 39000)
        r.until(50000)
        self.assertEqual(r.st["fan"]["flt"]["ok"], 39000)
        r.st["fan"]["allow_until"] = 60000           # inside again
        r.step()                                     # 51000
        self.assertIsNone(r.st["fan"]["flt"]["ok"])
        o = r.until(119000)                          # ok from 60000: 59 s
        self.assertIn_("fan:F6", o, "f")
        o = r.step()                                 # 120000: 60 s
        self.assertNotIn_("fan:F6", o, "f")

    def test_k15_c23_runs_inside_allowance(self):
        r = Runner(mkcfg())
        r.step()                                     # allowance to 16000
        o = r.step(fan={"cur": 5})                   # 2000: inside
        self.assertIn_("fan:F1", o, "f")

    def test_k16_frozen_tach_reaches_p8_t4(self):
        # F5 at 47000 (since); allowance for top to 80000; restarted F5
        # re-fires at 111000, before the 60 s clear could end (140000), so
        # the fault stays active and P8 latches at 47000 + 120000
        r = Runner(mkcfg())
        r.set(fan={"rpm": 3700})
        o = r.until(47000)
        self.assertIn_("fan:F5", o, "f")
        o = r.until(166000)
        self.assertIn_("fan:F5", o, "f")
        self.assertEqual(r.st["fan"]["flt"]["since"], 47000)
        self.assertFalse(r.st["latched"])
        o = r.step()                                 # 167000
        self.assertEqual(t4(o), {"t4:fan"})

    def test_k16_stuck_fan_reaches_p8_t4(self):
        # rpm ~3000 vs target 3700: F3 at 62000; allowance to 95000; F3
        # re-fires at 141000, before the clear (155000); T4 at 182000
        r = Runner(mkcfg())
        o = None
        while r.t < 181000:
            k = ((r.t + 1000) // 1000) % 2
            o = r.step(fan={"rpm": 3000 + k})
            if r.t == 62000:
                self.assertIn_("fan:F3", o, "f")
        self.assertIn_("fan:F3", o, "f")
        self.assertFalse(r.st["latched"])
        k = ((r.t + 1000) // 1000) % 2
        o = r.step(fan={"rpm": 3000 + k})            # 182000
        self.assertEqual(t4(o), {"t4:fan"})

    def test_k10_timers_reset_on_err(self):
        # K-45 (replaces K-10's reset): each check needs only its own
        # readings; a tick without them holds its timer
        r = Runner(mkcfg())
        r.set(fan={"rpm": 3700})
        r.until(40000)                               # F5 timer from 16000
        self.assertEqual(r.st["fan"]["tm"]["F5"], 16000)
        r.step(fan={"pwm": "ERR"})                   # 41000: rpm read: runs on
        self.assertEqual(r.st["fan"]["tm"]["F5"], 16000)
        r.step(fan={"rpm": "ERR"})                   # 42000: held
        self.assertEqual(r.st["fan"]["tm"]["F5"], 16000)
        o = r.until(46000)
        self.assertNotIn_("fan:F5", o, "f")
        o = r.step()                                 # 47000: > 30 s
        self.assertIn_("fan:F5", o, "f")
        o = r.step(fan={"rpm": "ERR"})               # 48000: fires while held
        self.assertIn_("fan:F5", o, "f")

    def test_c25_first_code_reported(self):
        r = Runner(mkcfg())
        r.step()
        r.step(fan={"cur": 5})
        o = r.step(fan="ABSENT")
        self.assertIn_("fan:F1", o, "f")

    def test_c20_base_sensor_drives_trips(self):
        c = mkcfg()
        c["fan"]["rules"] = [{"zone": "cpu1", "base": "cpu0",
                              "trips": [{"t": 60000, "h": 5000, "lvl": 2}]}]
        r = Runner(c)
        o = r.step(s={"cpu1": 80000})                # label sensor: no effect
        self.assertEqual(o["fan"], "3700")
        o = r.step(s={"cpu0": 60000})
        self.assertEqual(o["fan"], "4500")
        o = r.step(s={"cpu0": "ERR"})                # no usable base: held
        self.assertTrue(r.st["fan"]["trips"][0][0])
        o = r.step(s={"cpu0": 55000})                # = t - h: held
        self.assertTrue(r.st["fan"]["trips"][0][0])
        o = r.step(s={"cpu0": 54999})
        self.assertFalse(r.st["fan"]["trips"][0][0])

    def test_c16_fan_trip2(self):
        # K-34: a non-F6 condition (F1) latches at once; F6 needs 5 s
        r = Runner(mkcfg())
        r.step(s={"cpu0": 70000})
        o = r.step(s={"cpu0": 70000}, fan={"cur": 9})
        self.assertIn_("t4:fan-trip2", o, "e")
        r = Runner(mkcfg())
        r.step(s={"cpu0": 69999})
        o = r.step(s={"cpu0": 69999}, fan={"cur": 9})
        self.assertEqual(t4(o), set())

    def test_c26_headless(self):
        c = mkcfg(flags={"headless_fan": 1})
        o = Runner(c).step(fan="ABSENT")
        self.assertEqual(o["fan"], "-")
        self.assertEqual(o["f"], "-")
        self.assertEqual(o["e"], "ready")
        o = Runner(mkcfg(fan=None)).step()
        self.assertEqual(o["fan"], "-")
        self.assertEqual(o["e"], "notready:fan")
        # K-14(c): headless with a present fan: targeted and checked
        o = Runner(c).step()
        self.assertEqual((o["fan"], o["e"]), ("3700", "ready"))
        o = Runner(c).step(fan={"cur": 5})
        self.assertEqual(o["e"], "notready:fan")
        self.assertIn_("fan:F1", o, "f")
        o = Runner(mkcfg(fan=None, flags={"headless_fan": 1})).step()
        self.assertEqual(o["e"], "notready:fan")     # present, no fan config
        o = Runner(mkcfg(fan=None, flags={"headless_fan": 1})).step(fan="ABSENT")
        self.assertEqual((o["fan"], o["e"]), ("-", "ready"))


# ------------------------------------------------------------------ C-27
class TestCaps(Base):
    def test_c27(self):
        o = Runner(mkcfg()).step()
        self.assertEqual((o["cpu"], o["gpu"]), ("2054400", "2"))
        o = Runner(mkcfg()).step(s={"cpu0": 92000})
        self.assertEqual((o["cpu"], o["gpu"]), ("1382400", "6"))
        o = Runner(mkcfg()).step(s={"cpu0": 115000})
        self.assertEqual((o["cpu"], o["gpu"]), ("min", "8"))
        c = mkcfg()
        c["caps"] = {"cpu": c["caps"]["cpu"]}
        o = Runner(c).step()
        self.assertEqual(o["gpu"], "-")
        o = Runner(mkcfg(caps=None)).step()          # K-14(h)
        self.assertEqual((o["cpu"], o["gpu"]), ("-", "-"))

    def test_c27_not_ready_tier3_values(self):
        c = mkcfg(flags={"trial_override": 1})
        c["caps"]["cpu"][1] = 9
        r = Runner(c)
        o = r.step(caps_ok_at_start=False, s={"cpu0": 89000})
        self.assertEqual((o["cpu"], o["gpu"]), ("1094400", "8"))


# ------------------------------------------------------------------ C-29
class TestSelfTest(Base):
    def test_pass(self):
        o = Runner(mkcfg()).step()
        self.assertEqual(o["e"], "ready")
        self.assertEqual(o["ready"], 1)

    def test_items(self):
        cases = [
            ({"caps_ok_at_start": False}, mkcfg(), "notready:caps"),
            ({"s": {"cpu1": "ERR"}}, mkcfg(), "notready:sensor:cpu1"),
            ({"s": {"cpu0": 130000}}, mkcfg(), "notready:sensor:cpu0"),
            ({"adsp": "offline"}, mkcfg(), "notready:class:BATT"),
            ({"fan": {"cur": 9}}, mkcfg(), "notready:fan"),
            ({}, mkcfg(limits="none"), "notready:set"),
        ]
        for ov, cfg, ev in cases:
            o = Runner(cfg).step(**ov)
            self.assertEqual(o["e"], ev, ov)
            self.assertEqual(o["ready"], 0)
            self.assertIn_("selftest", o, "f")
            self.assertEqual(o["tier"], 3)


    def test_k48_fan_item_retried(self):
        # a read/write failure alone on the first tick is retried on the
        # next two ticks: READY on the first clean one, else notready:fan
        r = Runner(mkcfg())
        o = r.step(fan="ABSENT")
        self.assertEqual((o["e"], o["ready"], o["fan"]), ("-", 0, "5500"))
        o = r.step(fan="ABSENT")
        self.assertEqual((o["e"], o["ready"]), ("-", 0))
        o = r.step(fan="ABSENT")
        self.assertEqual((o["e"], o["ready"], o["tier"]), ("notready:fan", 0, 3))
        self.assertIn_("selftest", o, "f")
        r = Runner(mkcfg())
        r.step(fan={"rpm": "ERR"})
        o = r.step()
        self.assertEqual((o["e"], o["ready"]), ("ready", 1))
        r = Runner(mkcfg())
        r.step(fan_wr_err=True)
        o = r.step(fan={"cur": 9})                   # F1 on the retry tick
        self.assertEqual(o["e"], "notready:fan")

    def test_selftest_latch_60s(self):
        r = Runner(mkcfg())
        r.set(caps_ok_at_start=False)
        r.step()                                     # 1000
        o = r.until(60000)                           # 59000
        self.assertEqual(t4(o), set())
        o = r.step()                                 # 61000: 60000
        self.assertEqual(t4(o), {"t4:selftest"})
        r = Runner(mkcfg(flags={"trial_override": 1}))
        r.step(caps_ok_at_start=False)
        o = r.until(200000)
        self.assertEqual(o["tier"], 3)
        self.assertFalse(r.st["latched"])

    def test_caps_ok_only_first_tick(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(caps_ok_at_start=False)
        self.assertEqual(o["f"], "-")


# ------------------------------------------------------------------ C-30
class TestPsySampling(Base):
    def test_c30(self):
        r = Runner(mkcfg(psy_period_ms=5000))
        r.step()                                     # 1000 sample
        o = r.step(psy={"temp": 1300})               # 2000: ignored
        self.assertEqual(o["f"], "-")
        r.until(5000)
        o = r.step(psy={"temp": "ERR"})              # 6000 sample
        self.assertIn_("s:batt:read", o, "f")
        self.assertEqual(r.st["last_sample"], 6000)

    def test_c30_psy_state_carried(self):
        r = Runner(mkcfg(psy_period_ms=5000))
        r.step()
        r.step(psy={"temp": "ERR"}, dt=5000)         # 6000 sample: fault
        for _ in range(4):
            o = r.step(psy={"temp": "ERR"})          # carried, not resampled
            self.assertIn_("s:batt:read", o, "f")
        # 120 s latch only on a sample tick: since 6000 -> 126000 is a sample
        r.until(125000, psy={"temp": "ERR"})
        self.assertFalse(r.st["latched"])
        o = r.step(psy={"temp": "ERR"})              # 126000 sample
        self.assertIn_("t4:sensor:batt", o, "e")


# ------------------------------------------------------------- C-31...C-33
class TestNotices(Base):
    def test_c31_unplug(self):
        o = Runner(mkcfg()).step(s={"cpu0": 115000}, usb_online=1)
        self.assertIn_("unplug", o, "e")
        o = Runner(mkcfg()).step(s={"cpu0": 115000},
                                 psy={"status": "Full"})
        self.assertIn_("unplug", o, "e")
        o = Runner(mkcfg()).step(s={"cpu0": 115000})
        self.assertNotIn_("unplug", o, "e")
        r = Runner(mkcfg())
        r.step(usb_online=1)
        o = r.step(usb_online=1)
        self.assertNotIn_("unplug", o, "e")          # only on the latch tick

    def test_c32_j145(self):
        # K-17: event on start only (no 60 s repeat while it holds)
        r = Runner(mkcfg())
        r.set(psy={"status": "Charging", "temp": 300})
        o = r.step()                                 # 1000
        self.assertIn_("j145", o, "e")
        o = r.until(61000)
        self.assertTrue(all("j145" not in items(x, "e") for x in r.outs[1:]))
        o = Runner(mkcfg()).step(psy={"status": "Charging", "temp": 299})
        self.assertNotIn_("j145", o, "e")

    def test_c33_lowbatt_event_on_start(self):
        r = Runner(mkcfg())
        o = r.step(psy={"cap": 10})
        self.assertIn_("lowbatt", o, "e")
        r.step(psy={"cap": 50})
        o = r.step(psy={"cap": 5})
        self.assertIn_("lowbatt", o, "e")


# ---------------------------------------------------------- C-34 ... C-40
class TestTimelineValve(Base):
    def test_valve_budget(self):
        c = mkcfg(flags={"p15": 1})
        r = Runner(c)
        r.step()
        r.set(s={"cpu0": 115000})
        o = r.step()                                 # 2000 latch
        self.assertEqual(items(o, "a"), {"pet", "signal-pid1"})
        o = r.until(46000)
        self.assertEqual(o["a"], "pet")
        self.assertEqual(o["tier"], 4)
        o = r.step()                                 # 47000 = tl0 + 45000
        self.assertEqual(items(o, "a"), {"a1", "pet"})
        self.assertIn_("t5:budget", o, "e")
        self.assertEqual(o["tier"], 5)
        o = r.until(56000)
        self.assertEqual(o["a"], "pet")
        o = r.step(a2_exited=True)                   # 57000 = tl0 + 55000
        self.assertEqual(items(o, "a"), {"final-pet", "a2"})
        o = r.step()
        self.assertEqual(o["a"], "-")                # no pet after final-pet
        o = r.step(a2_exited=True)
        self.assertEqual(o["a"], "sysrq-c")
        o = r.step(a2_exited=True)
        self.assertEqual(o["a"], "-")

    def test_valve_no_sysrq_without_p15(self):
        r = Runner(mkcfg())
        r.step(s={"cpu0": 115000})
        r.until(56000, s={"cpu0": 115000})
        o = r.step(a2_exited=True)
        self.assertEqual(o["a"], "-")

    def test_valve_external_shutdown(self):
        for ov in ({"shutdown_byte": True}, {"pid1_comm": "systemd-shutdow"}):
            r = Runner(mkcfg())
            r.step()
            o = r.step(**ov)                         # 2000 tl0
            self.assertEqual(o["a"], "pet")
            o = r.until(46000)
            self.assertEqual(o["a"], "pet")
            o = r.step()                             # 47000
            self.assertEqual(items(o, "a"), {"a1", "pet"})
            self.assertNotIn_("t5:budget", o, "e")
            self.assertEqual(o["tier"], 0)
            r.until(56000)
            o = r.step()
            self.assertEqual(items(o, "a"), {"final-pet", "a2"})
        o = Runner(mkcfg()).step(pid1_comm="systemd")
        self.assertEqual(o["a"], "pet")

    def test_valve_t5_fast_timeout(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": 115000})                   # 2000 latch
        o = r.step(s={"cpu0": 120000})               # 3000 tf
        self.assertEqual(items(o, "a"), {"a1", "pet"})
        o = r.until(12000, s={"cpu0": 120000})       # tf + 9000
        self.assertEqual(o["a"], "pet")
        o = r.step(s={"cpu0": 120000})               # tf + 10000
        self.assertEqual(items(o, "a"), {"final-pet", "a2"})

    def test_valve_t5_fast_a1_done(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": 115000})
        r.step(s={"cpu0": 120000})                   # 3000 tf
        o = r.step(s={"cpu0": 120000})
        self.assertEqual(o["a"], "pet")
        o = r.step(s={"cpu0": 120000}, a1_done=True)
        self.assertEqual(items(o, "a"), {"final-pet", "a2"})

    def test_valve_t5_fast_capped_by_tl0_55(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"cpu0": 115000})
        r.step()                                     # 2000 latch
        r.until(46000)
        o = r.step(s={"cpu0": 120000})               # 47000: fast (before budget)
        self.assertIn_("t5:p12:cpu0", o, "e")
        self.assertNotIn_("t5:budget", o, "e")
        o = r.until(56000)
        self.assertEqual(o["a"], "pet")
        o = r.step()                                 # 57000 = tl0 + 55000
        self.assertEqual(items(o, "a"), {"final-pet", "a2"})


class TestTimelineStage(Base):
    def test_stage(self):
        r = Runner(mkcfg(mode="stage"))
        r.step()
        r.set(s={"cpu0": 115000})
        o = r.step()                                 # 2000
        self.assertEqual(items(o, "a"), {"pet", "term-step"})
        o = r.step()                                 # 3000
        self.assertEqual(o["a"], "pet")
        o = r.step()                                 # 4000 = tl0 + 2000
        self.assertEqual(items(o, "a"), {"final-pet", "kill-step", "trip"})
        o = r.until(100000)
        self.assertEqual(o["a"], "-")
        self.assertTrue(all("signal-pid1" not in x["a"] and "a1" not in x["a"]
                            for x in r.outs))
        self.assertTrue(all("t5:budget" not in x["e"] for x in r.outs))

    def test_stage_ignores_external_shutdown(self):
        r = Runner(mkcfg(mode="stage"))
        r.step()
        r.step(shutdown_byte=True, pid1_comm="systemd-shutdow")
        o = r.until(100000)
        self.assertEqual(o["a"], "pet")
        self.assertIsNone(r.st["tl0"])

    def test_stage_t5_fast_no_actions(self):
        r = Runner(mkcfg(mode="stage"))
        r.step()
        r.step(s={"cpu0": 115000})                   # 2000 latch
        o = r.step(s={"cpu0": 120000})               # 3000
        self.assertEqual(o["tier"], 5)
        self.assertIn_("t5:p12:cpu0", o, "e")
        self.assertEqual(o["a"], "pet")


# ---------------------------------------------------------- C-41 ... C-44
class TestGate(Base):
    def g(self, cfg=None, **ov):
        r = Runner(cfg or mkcfg())
        tick = r.base(1000)
        Runner.merge(tick, ov)
        return C.gate(r.cfg, C.norm_tick(tick))

    def test_pass(self):
        self.assertEqual(self.g(), "gate=pass reasons=-")

    def test_c41(self):
        self.assertEqual(self.g(caps_ok_at_start=False),
                         "gate=refuse reasons=selftest")
        self.assertEqual(self.g(s={"cpu0": "ERR"}),
                         "gate=refuse reasons=fault,selftest")

    def test_k13_pending_is_fault(self):
        self.assertEqual(self.g(s={"cpu0": 130000}),
                         "gate=refuse reasons=fault,selftest")
        self.assertEqual(self.g(s={"cpu0": 125000}),
                         "gate=refuse reasons=hot:cpu0")
        self.assertEqual(self.g(psy={"temp": 640}),
                         "gate=refuse reasons=hot:batt")

    def test_c42_severe_release(self):
        self.assertEqual(self.g(s={"cpu0": 93000}),
                         "gate=refuse reasons=hot:cpu0")
        self.assertEqual(self.g(s={"cpu0": 92999}), "gate=pass reasons=-")

    def test_c42_p5(self):
        c = mkcfg(p5={"sensor": "cpu1", "t": 80000})
        self.assertEqual(self.g(c, s={"cpu1": 80000}),
                         "gate=refuse reasons=hot:cpu1")
        self.assertEqual(self.g(c, s={"cpu1": 79999}), "gate=pass reasons=-")

    def test_c42_pstore(self):
        self.assertEqual(self.g(s={"cpu0": 89000}, pstore_marker=True),
                         "gate=refuse reasons=hot:cpu0")
        self.assertEqual(self.g(s={"cpu0": 88999}, pstore_marker=True),
                         "gate=pass reasons=-")
        self.assertEqual(self.g(s={"cpu0": 89000}), "gate=pass reasons=-")

    def test_c43(self):
        self.assertEqual(self.g(psy={"cap": 3}),
                         "gate=refuse reasons=p6 warn=lowbatt")
        self.assertEqual(self.g(psy={"cap": 4}),
                         "gate=pass reasons=- warn=lowbatt")
        self.assertEqual(self.g(psy={"cap": 10}),
                         "gate=pass reasons=- warn=lowbatt")
        self.assertEqual(self.g(psy={"cap": 11}), "gate=pass reasons=-")
        self.assertEqual(self.g(psy={"cap": 3, "status": "Charging"}),
                         "gate=pass reasons=-")

    def test_c44(self):
        c = mkcfg(flags={"j145": 1})
        ch = {"status": "Charging", "temp": 300}
        self.assertEqual(self.g(c, psy=ch), "gate=refuse reasons=j145")
        self.assertEqual(self.g(c, psy=dict(ch, temp=299)),
                         "gate=pass reasons=-")
        self.assertEqual(self.g(psy=ch), "gate=pass reasons=-")


# ------------------------------------------------------------------ K-17
class TestJ145Warn(Base):
    CH = {"status": "Charging", "temp": 300}

    def test_k17_start_event_and_warn(self):
        r = Runner(mkcfg())
        r.step()
        r.set(psy=self.CH)
        o = r.step()                                 # 2000 start
        self.assertIn_("j145", o, "e")
        self.assertEqual(o["tier"], 3)
        self.assertEqual(o["n"], "warn:charging-too-warm")
        o = r.until(200000)
        self.assertTrue(all("j145" not in items(x, "e") for x in r.outs[2:]))
        self.assertEqual(o["tier"], 3)
        self.assertFalse(r.st["latched"])            # never T4 by itself

    def test_k17_negative_299(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(psy={"status": "Charging", "temp": 299})
        self.assertNotIn_("j145", o, "e")
        self.assertEqual((o["tier"], o["n"]), (0, "-"))

    def test_k17_hold_err_and_clear(self):
        r = Runner(mkcfg())
        r.step(psy=self.CH)                          # 1000 start (t3 1000)
        r.step(psy={"status": "ERR", "temp": 250})   # ERR sample keeps
        self.assertTrue(r.st["j145"])
        r.step(psy={"status": "Charging", "volt": "ERR", "temp": 250})
        self.assertTrue(r.st["j145"])                # any-field ERR keeps
        r.step(psy={"status": "Charging", "temp": 299})   # 4000: otherwise
        self.assertFalse(r.st["j145"])
        # the ERR samples also raised b:psy -> BATT class (outranks it)
        o = r.until(30000)
        self.assertEqual(o["n"], "warn:battery-sensor-lost:92")

    def test_k17_clear_then_hold_then_restart(self):
        r = Runner(mkcfg())
        r.step(psy=self.CH)                          # 1000 start (t3 1000)
        r.step(psy=self.CH)
        o = r.step(psy={"status": "Charging", "temp": 299})   # 3000 clears
        self.assertFalse(r.st["j145"])
        o = r.until(30000)                           # C-17 hold to 31000
        self.assertEqual(o["tier"], 3)
        self.assertEqual(o["n"], "warn:charging-too-warm")  # last reason
        o = r.step()                                 # 31000
        self.assertEqual((o["tier"], o["n"]), (0, "-"))
        o = r.step(psy=self.CH)                      # starts again
        self.assertIn_("j145", o, "e")

    def test_k17_clear_by_status(self):
        r = Runner(mkcfg())
        r.step(psy=self.CH)
        r.step(psy={"status": "Full", "temp": 350})
        self.assertFalse(r.st["j145"])


# ------------------------------------------------------- K-18 ... K-22
def n_of(o):
    return o["n"]


class TestNoticeWhen(Base):
    def test_k18_none_below_tier3(self):
        r = Runner(mkcfg())
        o = r.step(s={"cpu0": 92000})                # tier 2
        self.assertEqual(o["n"], "-")
        o = r.step(s={"cpu0": 95000})                # tier 3
        self.assertEqual(o["n"], "warn:soc-temperature-high")

    def test_k18_shutdown_never_goes_back(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": 115000})
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:55")
        o = r.until(200000)
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:0")
        self.assertTrue(all(x["n"].startswith("shutdown:") for x in r.outs[1:]))

    def test_k18_external_shutdown_valve_only(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(shutdown_byte=True)               # 2000 tl0
        self.assertEqual(o["n"], "shutdown:shutdown-requested:55")
        self.assertEqual(o["tier"], 0)
        o = r.step()
        self.assertEqual(o["n"], "shutdown:shutdown-requested:54")
        r = Runner(mkcfg(mode="stage"))
        r.step()
        o = r.step(shutdown_byte=True, pid1_comm="systemd-shutdow")
        self.assertEqual(o["n"], "-")

    def test_k21_t4_after_external_replaces_reason_keeps_tl0(self):
        r = Runner(mkcfg())
        r.step()
        r.step(pid1_comm="systemd-shutdow")          # 2000 tl0
        r.until(11000)
        o = r.step(s={"cpu0": 115000})               # 12000 latch
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:45")
        self.assertNotIn_("signal-pid1", o, "e")
        self.assertIn_("signal-pid1", o, "a")        # K-12, unchanged


class TestNoticeShutdownReason(Base):
    def latch(self, cfg=None, **ov):
        r = Runner(cfg or mkcfg())
        r.step()
        return r.step(**ov)

    def test_k19_mapping(self):
        c2 = mkcfg()
        c2["groups"][0]["min"] = 2
        cases = [
            ({"s": {"cpu0": 115000}}, None, "soc-temperature-high"),
            ({"psy": {"cap": 3}}, None, "battery-empty"),
            ({"cap_fail": True}, None, "cap-write-failed"),
            ({"s": {"cpu0": "ERR", "skin": "ERR"}}, c2, "sensor-fault"),
            ({"s": {"cpu0": 70000}, "fan": {"cur": 9}}, None, "fan-failure"),
        ]
        for ov, cfg, reason in cases:
            r = Runner(cfg or mkcfg())
            r.step(s={"cpu0": 70000}) if "fan" in ov else r.step()
            o = r.step(**ov)
            self.assertEqual(o["n"], "shutdown:%s:55" % reason, ov)

    def test_k19_priority_on_latch_tick(self):
        o = self.latch(s={"cpu0": 115000}, psy={"cap": 3}, cap_fail=True)
        self.assertEqual(t4(o), {"t4:cap", "t4:p6", "t4:shutdown:cpu0"})
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:55")
        o = self.latch(psy={"cap": 3}, cap_fail=True)
        self.assertEqual(o["n"], "shutdown:battery-empty:55")

    def test_k19_sensor_batt_and_selftest(self):
        r = Runner(mkcfg(psy_period_ms=1000))
        r.step()
        r.set(psy={"temp": "ERR"})
        o = r.until(122000)                          # sensor:batt, class:BATT
        self.assertIn_("t4:sensor:batt", o, "e")
        self.assertEqual(o["n"], "shutdown:battery-sensor-lost:55")
        r = Runner(mkcfg())
        r.set(caps_ok_at_start=False)
        o = r.until(61000)
        self.assertEqual(t4(o), {"t4:selftest"})
        self.assertEqual(o["n"], "shutdown:self-test-failed:55")

    def test_k19_reason_kept(self):
        r = Runner(mkcfg())
        r.step()
        r.step(psy={"cap": 3})                       # battery-empty
        o = r.step(s={"cpu0": 115000})               # hotter later: kept
        self.assertEqual(o["n"], "shutdown:battery-empty:54")


class TestNoticeWarnReason(Base):
    def test_k20_priority(self):
        o = Runner(mkcfg()).step(s={"cpu0": 95000, "skin": 30000})
        self.assertEqual(o["n"], "warn:soc-temperature-high")
        r = Runner(mkcfg())
        for v in (38000, 46000, 52000):
            o = r.step(s={"cpu0": 95000, "skin": v})
        self.assertEqual(o["n"], "warn:skin-temperature-high")
        o = Runner(mkcfg()).step(psy={"cap": 10, "status": "Discharging"})
        self.assertEqual(o["n"], "warn:battery-low")
        r = Runner(mkcfg())
        r.step()
        for _ in range(5):
            o = r.step(psy={"cap": 10}, fan="ABSENT")
        self.assertEqual(o["n"], "warn:fan-failure:120")
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": 130000})               # pending
        self.assertEqual(o["n"], "warn:sensor-anomaly")
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": 130000, "cpu1": "ERR"})
        self.assertEqual(o["n"], "warn:sensor-fault:120")   # beats anomaly

    def test_k20_battery_sensor_lost(self):
        r = Runner(mkcfg())
        r.step()
        o = r.step(adsp="offline")                   # BATT class active
        self.assertEqual(o["n"], "warn:battery-sensor-lost:120")
        r = Runner(mkcfg())
        r.step()
        o = r.step(adsp="offline", s={"cpu0": "ERR"})
        self.assertEqual(o["n"], "warn:battery-sensor-lost:120")

    def test_k20_hold_keeps_last_reason(self):
        r = Runner(mkcfg())
        r.step()
        r.step(psy={"cap": 10})                      # 2000 tier 3
        o = r.step(psy={"cap": 80})                  # held by C-17
        self.assertEqual((o["tier"], o["n"]), (3, "warn:battery-low"))
        o = r.until(32000)
        self.assertEqual((o["tier"], o["n"]), (0, "-"))


class TestNoticeCountdown(Base):
    def test_k21_valve_t4_latch(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"cpu0": 115000})
        o = r.step()                                 # 2000
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:55")
        o = r.step(dt=500)                           # 2500: 54.5 s -> 55
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:55")
        o = r.step(dt=500)                           # 3000
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:54")
        o = r.until(56000)
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:1")
        self.assertEqual(o["a"], "pet")
        o = r.step()                                 # 57000 a2
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:0")
        self.assertIn_("a2", o, "a")

    def test_k21_t5_fast(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": 115000})                   # 2000 tl0
        r.set(s={"cpu0": 120000})
        o = r.step()                                 # 3000 tf
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:10")
        o = r.until(12000)                           # tf + 9000
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:1")
        o = r.step()                                 # tf + 10000: a2
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:0")
        self.assertIn_("a2", o, "a")

    def test_k21_t5_fast_capped_by_tl0(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"cpu0": 115000})
        r.step()                                     # 2000
        r.until(50000)
        o = r.step(s={"cpu0": 120000})               # 51000: tf
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:6")

    def test_k21_early_a2_is_zero(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": 115000})
        r.set(s={"cpu0": 120000})
        r.step()                                     # 3000 tf
        o = r.step(a1_done=True)                     # 4000: early a2
        self.assertIn_("a2", o, "a")
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:0")
        o = r.step()
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:0")

    def test_k21_stage(self):
        r = Runner(mkcfg(mode="stage"))
        r.step()
        r.set(s={"cpu0": 115000})
        o = r.step()                                 # 2000
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:2")
        o = r.step()
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:1")
        o = r.step()                                 # 4000 trip
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:0")
        self.assertIn_("trip", o, "a")
        o = r.step(s={"cpu0": 120000})               # T5 fast: no change
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:0")
        self.assertEqual(o["tier"], 5)

    def test_k21_sensor_fault_timer(self):
        r = Runner(mkcfg())
        r.step()
        r.set(s={"cpu0": "ERR"})
        o = r.step()                                 # 2000
        self.assertEqual(o["n"], "warn:sensor-fault:120")
        o = r.step()
        self.assertEqual(o["n"], "warn:sensor-fault:119")
        o = r.until(121000)
        self.assertEqual(o["n"], "warn:sensor-fault:1")
        o = r.step()                                 # 122000 T4
        self.assertEqual(o["n"], "shutdown:sensor-fault:55")

    def test_k21_earliest_deadline(self):
        r = Runner(mkcfg())
        r.step()
        r.step(s={"cpu0": "ERR"})                    # since 2000
        r.until(9000, s={"cpu0": "ERR"})
        o = r.step(s={"cpu0": "ERR", "skin": "ERR"})  # 10000: SKIN class too
        self.assertEqual(o["n"], "warn:sensor-fault:112")

    def test_k21_fan_timer(self):
        r = Runner(mkcfg())
        r.step()
        r.set(fan="ABSENT")
        o = r.until(5000)
        self.assertEqual(o["n"], "-")                # 4 failed ticks (K-44)
        o = r.step()                                 # 6000: F6
        self.assertEqual(o["n"], "warn:fan-failure:120")
        o = r.until(125000)
        self.assertEqual(o["n"], "warn:fan-failure:1")
        o = r.step()
        self.assertEqual(o["n"], "shutdown:fan-failure:55")

    def test_k21_selftest_timer(self):
        r = Runner(mkcfg())
        r.set(caps_ok_at_start=False)
        o = r.step()                                 # 1000 = t0
        self.assertEqual(o["n"], "warn:self-test-failed:60")
        o = r.until(60000)
        self.assertEqual(o["n"], "warn:self-test-failed:1")
        r = Runner(mkcfg(flags={"trial_override": 1}))
        o = r.step(caps_ok_at_start=False)
        self.assertEqual(o["n"], "warn:self-test-failed")

    def test_k21_no_timer_reasons(self):
        o = Runner(mkcfg()).step(s={"cpu0": 95000})
        self.assertEqual(o["n"], "warn:soc-temperature-high")
        r = Runner(mkcfg())
        r.step()
        o = r.step(s={"cpu0": 130000})
        self.assertEqual(o["n"], "warn:sensor-anomaly")


class TestNoticeNeutral(Base):
    """K-22: replacing the notice by '-' changes nothing else."""

    def scenario(self, r):
        r.step()
        r.step(fan="ABSENT")
        r.until(20000)
        r.step(psy={"cap": 10})
        r.until(30000, s={"cpu0": "ERR"})
        r.step(shutdown_byte=True)
        r.until(40000)
        r.set(s={"cpu0": 115000})
        r.until(45000)
        r.set(s={"cpu0": 121000})
        r.until(90000, a2_exited=True)
        return r.outs

    def test_k22(self):
        for mode in ("valve", "stage"):
            a = self.scenario(Runner(mkcfg(mode=mode, flags={"p15": 1})))
            real = C.notice
            try:
                C.notice = lambda cfg, st, now: "-"
                b = self.scenario(Runner(mkcfg(mode=mode, flags={"p15": 1})))
            finally:
                C.notice = real
            strip = lambda o: {k: v for k, v in o.items() if k != "n"}
            self.assertEqual([strip(x) for x in a], [strip(x) for x in b], mode)
            self.assertTrue(any(x["n"] != "-" for x in a))


# ------------------------------------------------------- rev 3: K-24 ... K-31
def osc(r, period=5000):
    """cpu0 alternating 40000 / 70000 every `period` ms: with osc_cfg() the
    demand (and the target 3700 / 4500) changes before each ramp allowance
    (23 s) ends. osc_cfg has a single trip, so fan-trip2 never applies."""
    return 70000 if ((r.t + 1000) // period) % 2 else 40000


def osc_cfg():
    c = mkcfg()
    c["fan"]["rules"] = [{"zone": "cpuss-label", "base": "cpu0",
                          "trips": [{"t": 60000, "h": 5000, "lvl": 2}]}]
    return c


class TestK24FanNotStarved(Base):
    def _zero_floor_cfg(self):
        c = mkcfg()
        c["fan"]["floor_p1"] = 0
        c["fan"]["floor_tier"][0] = 0
        return c

    def test_k24a_spin_grace_on_0_to_positive(self):
        r = Runner(self._zero_floor_cfg())
        r.set(fan={"rpm": 0})
        o = r.until(9000)
        self.assertEqual(o["fan"], "0")
        r.set(s={"cpu0": 60000})
        r.step()                                     # 10000: 0 -> 3700
        self.assertEqual(r.st["fan"]["spin_until"], 25000)
        o = r.until(45000)                           # F2 from 25000: 20000
        self.assertNotIn_("fan:F2", o, "f")
        o = r.step()                                 # 46000
        self.assertIn_("fan:F2", o, "f")

    def test_k24a_f2_runs_inside_ramp_allowance(self):
        # tier 3 at 2000: 3700 -> 5500, allowance to 35000; F2 runs anyway
        r = Runner(mkcfg())
        r.step()                                     # grace to 16000
        r.set(psy={"cap": 10}, fan={"rpm": 0})
        r.step()
        self.assertEqual(r.st["fan"]["allow_until"], 35000)
        o = r.until(36000)                           # cond from 16000: 20000
        self.assertNotIn_("fan:F2", o, "f")
        o = r.step()                                 # 37000, inside allowance
        self.assertIn_("fan:F2", o, "f")

    def test_k24a_oscillating_demand_stall_reaches_t4(self):
        r = Runner(osc_cfg())
        o = None
        while r.t < 37000:
            o = r.step(s={"cpu0": osc(r)}, fan={"rpm": 0})
        self.assertIn_("fan:F2", o, "f")             # 16000 + 21000
        while r.t < 156000:
            o = r.step(s={"cpu0": osc(r)}, fan={"rpm": 0})
        self.assertFalse(r.st["latched"])
        o = r.step(s={"cpu0": osc(r)}, fan={"rpm": 0})   # 157000
        self.assertIn_("t4:fan", o, "e")

    def test_k24a_oscillating_demand_frozen_tach_reaches_t4(self):
        r = Runner(osc_cfg())
        o = None
        while r.t < 46000:
            o = r.step(s={"cpu0": osc(r)}, fan={"rpm": 3700})
        self.assertNotIn_("fan:F5", o, "f")
        o = r.step(s={"cpu0": osc(r)}, fan={"rpm": 3700})  # 47000
        self.assertIn_("fan:F5", o, "f")
        while r.t < 166000:
            o = r.step(s={"cpu0": osc(r)}, fan={"rpm": 3700})
        self.assertFalse(r.st["latched"])
        o = r.step(s={"cpu0": osc(r)}, fan={"rpm": 3700})  # 167000
        self.assertIn_("t4:fan", o, "e")

    def test_k24a_oscillating_healthy_fan_never_faults(self):
        r = Runner(osc_cfg())
        for _ in range(300):
            o = r.step(s={"cpu0": osc(r)})
            self.assertEqual(o["f"], "-", C.format_line(o))

    def test_k24b_f3_timer_runs_across_boundary(self):
        # outside: |3000 - 3700| > 555 from 16000; at 30000 a target change
        # (allowance to 53000) keeps the low-side condition: one timer
        r = Runner(osc_cfg())
        o = None
        while r.t < 62000:
            k = ((r.t + 1000) // 1000) % 2
            cpu0 = 70000 if r.t + 1000 >= 30000 else 40000
            o = r.step(s={"cpu0": cpu0}, fan={"rpm": 3000 + k})
            if r.t == 30000:
                self.assertEqual(r.st["fan"]["allow_until"], 53000)
                self.assertEqual(r.st["fan"]["tm"]["F3"], 16000)
        self.assertIn_("fan:F3", o, "f")             # 62000, inside

    def test_k24b_high_side_not_checked_inside_allowance(self):
        # rpm far above the target inside the allowance: no F3 there
        r = Runner(osc_cfg())
        for _ in range(80):
            k = ((r.t + 1000) // 1000) % 2
            o = r.step(s={"cpu0": osc(r)}, fan={"rpm": 5400 + k})
        self.assertEqual(o["f"], "-")

    def _f4_cfg(self):
        c = mkcfg()
        c["fan"]["floor_p1"] = 5000
        c["fan"]["floor_tier"][0] = 5000
        c["fan"]["silent_rpm"] = 6000                # no ramp: allow 16000
        return c

    def test_k24c_f4_against_max_rpm(self):
        # max_rpm 6000: 85 % = 5100
        r = Runner(self._f4_cfg())
        for _ in range(62):
            k = ((r.t + 1000) // 1000) % 2
            o = r.step(fan={"rpm": 5000 + k, "pwm": 255})
            if r.t == 61000:
                self.assertEqual(o["f"], "-")
        self.assertIn_("fan:F4", o, "f")             # 62000
        for ov in ({"pwm": 254, "rpm": 5000}, {"pwm": 255, "rpm": 5100}):
            r = Runner(self._f4_cfg())
            for _ in range(80):
                k = ((r.t + 1000) // 1000) % 2
                o = r.step(fan={"rpm": ov["rpm"] + k, "pwm": ov["pwm"]})
            self.assertEqual(o["f"], "-", ov)

    def test_k24c_f4_not_inside_allowance(self):
        c = self._f4_cfg()
        c["fan"]["floor_tier"][1] = 5500             # tier 1 -> 5500
        c["fan"]["silent_rpm"] = 4000                # ramp 5000 -> 5500
        c["fan"]["rpm_per_sec"] = 10                 # 50000 ms ramp
        r = Runner(c)
        for _ in range(100):
            k = ((r.t + 1000) // 1000) % 2
            cpu1 = 89000 if ((r.t + 1000) // 40000) % 2 else 40000
            o = r.step(s={"cpu1": cpu1}, fan={"pwm": 255, "rpm": 5000 + k})
            self.assertNotIn_("fan:F4", o, "f")

    def test_k24d_ramp_cap(self):
        c = mkcfg()
        c["fan"]["rpm_per_sec"] = 50                 # 3700/50 s = 74 s
        r = Runner(c)
        r.step()                                     # 0 -> 3700: silent
        self.assertEqual(r.st["fan"]["allow_until"], 16000)
        c["fan"]["silent_rpm"] = 0
        r = Runner(c)
        r.step()
        self.assertEqual(r.st["fan"]["allow_until"], 1000 + 15000 + 60000)
        c["fan"]["rpm_per_sec"] = 100                # 37 s: not capped
        r = Runner(c)
        r.step()
        self.assertEqual(r.st["fan"]["allow_until"], 1000 + 15000 + 37000)


class TestK25ZoneFault(Base):
    def test_k25_f8_every_tick_selftest_and_p8(self):
        c = mkcfg()
        c["fan"]["zone_fault"] = True
        c["flags"]["trial_override"] = 1             # no selftest T4
        r = Runner(c)
        o = r.step()                                 # 1000
        self.assertEqual(o["e"], "notready:fan")
        self.assertIn_("fan:F8", o, "f")
        self.assertNotEqual(o["fan"], "-")           # fan control continues
        o = r.until(120000)
        self.assertFalse(r.st["latched"])
        o = r.step()                                 # 121000 = since + 120 s
        self.assertIn_("t4:fan", o, "e")
        o = Runner(mkcfg()).step()
        self.assertEqual(o["e"], "ready")

    def test_k25_order(self):
        # F8 raises on the first tick; F6 needs 5 of 20 ticks (K-44)
        c = mkcfg()
        c["fan"]["zone_fault"] = True
        r = Runner(c)
        o = r.step(fan="ABSENT")
        self.assertIn_("fan:F8", o, "f")
        o = Runner(c).step(fan={"cur": 9})
        self.assertIn_("fan:F8", o, "f")

    def test_k25_fan_trip2(self):
        c = mkcfg()
        c["fan"]["zone_fault"] = True
        o = Runner(c).step(s={"cpu0": 70000})
        self.assertIn_("t4:fan-trip2", o, "e")


class TestK26Int32(Base):
    def test_k26(self):
        r = Runner(mkcfg())
        o = r.step(psy={"temp": 42949700})           # x100 outside int32
        self.assertIn_("s:batt:read", o, "f")
        self.assertIn_("b:psy", o, "f")
        o = Runner(mkcfg()).step(psy={"temp": 21474836})   # x100 = in range
        self.assertNotIn_("s:batt:read", o, "f")
        o = Runner(mkcfg()).step(s={"cpu0": 2 ** 31})
        self.assertIn_("s:cpu0:read", o, "f")
        o = Runner(mkcfg()).step(s={"cpu0": 2 ** 31 - 1})
        self.assertIn_("p:cpu0", o, "f")             # numeric: hot
        o = Runner(mkcfg()).step(s={"cpu0": -2 ** 31 - 1})
        self.assertIn_("s:cpu0:read", o, "f")
        r = Runner(mkcfg())
        for _ in range(5):
            o = r.step(fan={"rpm": 2 ** 31})
        self.assertIn_("fan:F6", o, "f")


class TestK33StuckTsens(Base):
    def _run(self, move, cfg=None):
        r = Runner(cfg or mkcfg())
        r.set(s={"skin": 30000, "cpu0": 40000, "cpu1": 40000})
        r.step()                                     # 1000: cpu1 fv, ref0
        r.set(s={"cpu0": 40000 + move})
        return r

    def test_k33_review_flat_batt_usb_skin_never_fault(self):
        # battery 31.2 C and usb-conn 30 C flat for > 420 s while the SoC
        # moves by 3.6 C: no fault, no shutdown (only SOC zones are judged)
        c = mkcfg()
        c["groups"].append({"name": "usb", "class": "USB", "min": 1})
        c["sensors"].append({"name": "usb", "class": "USB", "group": "usb",
                             "kind": "zone", "slow": 1, "indep": 0,
                             "th": [N, N, N, N, N, N, 70000],
                             "hy": [N] * 7, "vin": []})
        r = Runner(c)
        r.set(s={"usb": 30000, "skin": 30000}, psy={"temp": 312})
        r.step()
        k = 0
        while r.t < 430000:
            k += 1
            # both SOC sensors move (never stuck themselves)
            v = 43600 + (k % 2)
            o = r.step(s={"cpu0": v, "cpu1": v + 1})
            self.assertEqual(o["f"], "-", C.format_line(o))
        self.assertFalse(r.st["latched"])
        self.assertEqual(o["tier"], 0)

    def test_k33_stuck_tsens_escalates(self):
        r = self._run(3001)
        o = r.until(300000)                          # 299000
        self.assertEqual(o["f"], "-")
        o = r.step()                                 # 301000
        self.assertEqual(o["f"], "s:cpu1:stuck")
        self.assertEqual(o["n"], "warn:sensor-fault:120")
        o = r.until(420000)
        self.assertFalse(r.st["latched"])
        o = r.step()                                 # 421000
        self.assertIn_("t4:sensor:cpu1", o, "e")

    def test_k33_negative_ref_moved_3000(self):
        r = self._run(3000)
        o = r.until(500000)
        self.assertEqual(o["f"], "-")

    def test_k33_change_resets(self):
        r = self._run(3001)
        r.until(200000)
        r.step(s={"cpu1": 40001})                    # 201000: fv, fsince, ref0
        r.set(s={"cpu1": 40001})
        o = r.until(600000)                          # ref0 = 43001 = ref
        self.assertEqual(o["f"], "-")

    def test_k33_stuck_not_counted_for_two_classes(self):
        c = mkcfg()
        c["groups"][0]["min"] = 2
        r = self._run(3001, c)
        r.until(301000)                              # cpu1 stuck: c:SOC
        self.assertIn_("c:SOC", r.last, "f")
        o = r.step(s={"skin": "ERR"})                # 302000: SKIN too
        self.assertIn_("c:SKIN", o, "f")
        self.assertNotIn_("t4:classes", o, "e")
        self.assertFalse(r.st["latched"])
        # the class's own 120 s rule still applies (with sensor:cpu1)
        o = r.until(420000, s={"skin": "ERR"})
        self.assertFalse(r.st["latched"])
        o = r.step(s={"skin": "ERR"})                # 421000
        self.assertIn_("t4:class:SOC", o, "e")
        # negative control: SOC faulted by a read error counts
        r = Runner(c)
        r.step()
        o = r.step(s={"cpu1": "ERR", "skin": "ERR"})
        self.assertIn_("t4:classes", o, "e")

    def test_k33_stuck_then_err_counts_again(self):
        c = mkcfg()
        c["groups"][0]["min"] = 2
        r = self._run(3001, c)
        r.until(301000)
        o = r.step(s={"cpu1": "ERR", "skin": "ERR"})
        self.assertIn_("t4:classes", o, "e")

    def test_k40_weak_soc_never_stuck(self):
        c = mkcfg()
        c["sensors"][1]["weak"] = 1                  # cpu1 = soc-usr
        r = self._run(3001, c)
        o = r.until(500000)
        self.assertEqual(o["f"], "-")

    def test_k40_stuck_latched_while_unchanged(self):
        r = self._run(3001)
        o = r.until(301000)
        self.assertEqual(o["f"], "s:cpu1:stuck")
        r.set(s={"cpu0": 40000})                     # reference back
        o = r.step()
        self.assertEqual(r.st["sens"]["cpu1"]["cur"]["h"], "stuck")
        r.until(340000)
        self.assertEqual(r.st["sens"]["cpu1"]["cur"]["h"], "stuck")
        r.step(s={"cpu1": 40001})                    # value changes
        self.assertEqual(r.st["sens"]["cpu1"]["cur"]["h"], "ok")


class TestK28FailClosed(Base):
    def test_k28_critical_slot_tier4(self):
        c = mkcfg()
        c["sensors"][0]["th"][4] = 100000
        o = Runner(c).step(s={"cpu0": 100000})
        self.assertEqual(o["tier"], 4)
        self.assertIn_("t4:shutdown:cpu0", o, "e")
        o = Runner(c).step(s={"cpu0": 99999})
        self.assertEqual(o["tier"], 3)
        self.assertEqual(t4(o), set())


class TestK29Contradiction(Base):
    def _cfg3(self):
        c = mkcfg()
        cpu2 = copy.deepcopy(c["sensors"][1])
        cpu2["name"] = "cpu2"
        c["sensors"].insert(2, cpu2)
        return c

    def _resolve(self, cfg, extra):
        r = Runner(cfg)
        if "cpu2" in r.cfg["by_name"]:
            r.set(s={"cpu2": 40000})
        r.step(s=dict({"cpu0": 40000}, **extra.get(1000, {})))
        o = None
        for t in (2000, 3000, 4000):
            o = r.step(s=dict({"cpu0": 130000}, **extra.get(t, {})))
        return o

    def test_k29_weak_never_contradicts(self):
        c = mkcfg()
        c["sensors"][1]["weak"] = 1
        o = self._resolve(c, {})
        self.assertIn_("t4:anomaly:cpu0", o, "e")
        o = self._resolve(mkcfg(), {})               # not weak: contra
        self.assertIn_("s:cpu0:contra", o, "f")

    def test_k29_weak_still_blocks(self):
        c = self._cfg3()
        c["sensors"][2]["weak"] = 1                  # cpu2 weak, >= SEVERE
        hot = {"cpu2": 96000}
        o = self._resolve(c, {2000: hot, 3000: hot, 4000: hot})
        self.assertIn_("t4:anomaly:cpu0", o, "e")

    def test_k29_sibling_fault_blocks_contradiction(self):
        c = self._cfg3()
        err = {"cpu2": "ERR"}
        o = self._resolve(c, {2000: err, 3000: err, 4000: err})
        self.assertIn_("t4:anomaly:cpu0", o, "e")    # cpu1 cool, cpu2 ERR
        o = self._resolve(c, {2000: {"cpu2": -30000}, 3000: err, 4000: err})
        self.assertIn_("t4:anomaly:cpu0", o, "e")
        # active fault in recovery (healthy reading) still blocks
        o = self._resolve(c, {1000: err})
        self.assertIn_("t4:anomaly:cpu0", o, "e")
        # negative control: no sibling problem -> contradicted
        o = self._resolve(c, {})
        self.assertIn_("s:cpu0:contra", o, "f")


class TestK30CapsNull(Base):
    def test_k30(self):
        c = mkcfg()
        c["caps"]["cpu"] = [None, None, None, "min", "min", "min"]
        o = Runner(c).step()
        self.assertEqual((o["cpu"], o["gpu"]), ("-", "2"))
        o = Runner(c).step(s={"cpu0": 95000})
        self.assertEqual(o["cpu"], "min")


class TestK31Cdev(Base):
    def test_k31(self):
        r = Runner(mkcfg())
        r.step()
        r.set(fan={"cur": 2})                        # demand level 0
        r.step()                                     # 2000 since
        o = r.until(12000)                           # 10000: not > 10000
        self.assertTrue(all("cdev-mismatch" not in x["e"] for x in r.outs))
        o = r.step()                                 # 13000
        self.assertIn_("cdev-mismatch", o, "e")
        self.assertEqual((o["tier"], o["f"]), (0, "-"))   # log only
        o = r.until(60000)
        self.assertEqual(sum("cdev-mismatch" in x["e"] for x in r.outs), 1)
        r.step(fan={"cur": 0})                       # episode ends
        o = r.until(72000)
        self.assertNotIn_("cdev-mismatch", o, "e")
        o = r.step()                                 # 73000: 61000 + 12000
        self.assertIn_("cdev-mismatch", o, "e")

    def test_k31_negative_matching(self):
        r = Runner(mkcfg())
        o = r.until(100000)
        self.assertTrue(all("cdev-mismatch" not in x["e"] for x in r.outs))


class TestK34FanTrip2Debounce(Base):
    def test_k34_review_transient_f6_no_t4(self):
        r = Runner(mkcfg())
        r.set(s={"cpu0": 76000})
        r.step()
        o = r.step(fan="ABSENT")                     # 2000: one failed tick
        self.assertNotIn_("fan:F6", o, "f")          # K-44: not a fault
        for _ in range(4):
            o = r.step(fan="ABSENT")                 # 3000..6000
        self.assertIn_("fan:F6", o, "f")             # 5 of 20: F6
        self.assertEqual(t4(o), set())               # 5 of 10 < 6 (K-41)
        o = r.until(100000)
        self.assertFalse(r.st["latched"], C.format_line(o))

    def test_k34_persistent_f6_5s(self):
        r = Runner(mkcfg())
        r.set(s={"cpu0": 76000})
        r.step()
        r.set(fan="ABSENT")
        r.step()                                     # 2000 f6_since
        o = r.until(6000)                            # 4000 ms
        self.assertEqual(t4(o), set())
        self.assertFalse(r.st["latched"])
        o = r.step()                                 # 7000: 5000 ms
        self.assertEqual(t4(o), {"t4:fan-trip2"})

    def test_k41_review_failing_reads_4_of_5(self):
        # reads fail 4 s of every 5 at 86 C: t4:fan-trip2 within ~10 s
        r = Runner(mkcfg())
        r.set(s={"cpu0": 86000})
        r.step()                                     # 1000
        first = None
        for i in range(30):
            fan = {"rpm": "ERR"} if i % 5 != 4 else None
            o = r.step(fan=fan) if fan else r.step()
            if first is None and "t4:fan-trip2" in items(o, "e"):
                first = r.t
        self.assertEqual(first, 8000)                # 6th F6 of the window
        self.assertLessEqual(first - 2000, 10000)

    def test_k41_success_does_not_reset(self):
        r = Runner(mkcfg())
        r.set(s={"cpu0": 76000})
        r.step()
        for _ in range(4):
            r.step(fan="ABSENT")                     # 2000..5000
        r.step()                                     # 6000 success
        o = r.step(fan="ABSENT")                     # 7000: 5 of 10
        self.assertFalse(r.st["latched"])
        o = r.step(fan="ABSENT")                     # 8000: 6 of 10
        self.assertIn_("t4:fan-trip2", o, "e")

    def test_k41_negative_5_of_10(self):
        r = Runner(mkcfg())
        r.set(s={"cpu0": 76000})
        r.step()
        for i in range(60):
            if i % 2 == 0:
                r.step(fan="ABSENT")
            else:
                # a moving tach: the present ticks would otherwise repeat one
                # value, which F5 (K-45: against the last numeric reading)
                # rightly reports as frozen
                r.step(fan={"rpm": int(r.outs[-1]["fan"]) + (i // 2 % 2) * 10})
        self.assertIn("fan:F6", r.outs[-1]["f"])     # 10 of 20 (K-44)
        self.assertFalse(r.st["latched"])            # 5 of 10 < 6 (K-41)
        self.assertTrue(sum(r.st["fan"]["f6_hist"][-10:]) <= 5)

    def test_k34_non_f6_condition_immediate(self):
        r = Runner(mkcfg())
        r.step(s={"cpu0": 76000})
        o = r.step(s={"cpu0": 76000}, fan={"cur": 9})    # F1 now
        self.assertIn_("t4:fan-trip2", o, "e")
        r = Runner(mkcfg())
        r.step(s={"cpu0": 69999})
        o = r.step(s={"cpu0": 69999}, fan={"cur": 9})    # no trip 2
        self.assertEqual(t4(o), set())


class TestK38TachPlausibility(Base):
    def test_k38_review_random_noise_reaches_f9(self):
        import random
        rnd = random.Random(7)
        r = Runner(mkcfg())
        first = None
        for _ in range(30):
            o = r.step(fan={"rpm": rnd.randint(0, 9000)})
            if first is None and "fan:F9" in items(o, "f"):
                first = r.t
        self.assertIsNotNone(first)
        self.assertLessEqual(first, 6000)

    def test_k38_review_tach_noise_3_and_5_percent_no_shutdown(self):
        import random
        for pct in (3, 5):
            rnd = random.Random(pct)
            r = Runner(mkcfg())
            r.set(s={"cpu0": 86000})                 # trip 2 active
            for _ in range(400):
                tgt = int(r.last["fan"]) if r.last else 3700
                d = tgt * pct // 100
                o = r.step(fan={"rpm": tgt + rnd.randint(-d, d)})
                self.assertNotIn("fan:", o["f"], (pct, C.format_line(o)))
            self.assertFalse(r.st["latched"])

    def test_k38_range_3_of_5(self):
        r = Runner(mkcfg())
        r.step()                                     # 3700
        outs = [r.step(fan={"rpm": 7201}) for _ in range(3)]
        self.assertNotIn_("fan:F9", outs[1], "f")
        self.assertIn_("fan:F9", outs[2], "f")       # 3rd implausible
        r = Runner(mkcfg())
        outs = [r.step(fan={"rpm": -1}) for _ in range(3)]
        self.assertNotIn_("fan:F9", outs[1], "f")
        self.assertIn_("fan:F9", outs[2], "f")
        r = Runner(mkcfg())                          # 7200 = 6000 x 12 / 10
        r.step()
        r.step(fan={"rpm": 4500})
        for v in (5300, 6100, 6900, 7200, 7200, 7200):
            r.step(fan={"rpm": v})
        self.assertEqual(sum(r.st["fan"]["f9_hist"]), 0)

    def test_k38_rate_noise_floor(self):
        # 1000 ms tick, 100 rpm/s: bound = 200 + max(500, prev x 25 / 100)
        def run(seq):
            r = Runner(mkcfg())
            r.step()
            for v in seq:
                r.step(fan={"rpm": v})
            return r.st["fan"]["f9_hist"]
        # K-49: prev 4300: bound 200 + max(500, 4300 x 25 / 100) = 1275
        self.assertEqual(run([4300, 5575])[-1], False)
        self.assertEqual(run([4300, 5576])[-1], True)
        # both <= silent (4000): exempt
        self.assertEqual(run([1000, 4000])[-1], False)

    def test_k38_three_of_five_holds_and_ends(self):
        r = Runner(mkcfg())
        r.step()
        # implausible, plausible, implausible, plausible, implausible
        seq = [7300, 7100, 7300, 7100, 7300]
        outs = [r.step(fan={"rpm": v}) for v in seq]
        self.assertNotIn_("fan:F9", outs[3], "f")
        self.assertIn_("fan:F9", outs[4], "f")
        self.assertEqual(r.st["fan"]["f9_hist"], [True, False, True, False, True])
        o = r.step(fan={"rpm": 7100})                # 2 of last 5
        self.assertEqual(sum(r.st["fan"]["f9_hist"]), 2)
        # the condition ended (no current code); the fault itself stays
        # active until its 60 s clear (C-25/K-16; here inside the allowance
        # for the top target, so the clear timer cannot run yet, K-15)
        self.assertIn_("fan:F9", o, "f")
        self.assertIsNone(r.st["fan"]["flt"]["ok"])

    def test_k38_err_clears_history_and_previous(self):
        r = Runner(mkcfg())
        r.step()
        r.step(fan={"rpm": -1})
        r.step(fan={"rpm": -1})
        self.assertEqual(sum(r.st["fan"]["f9_hist"]), 2)
        r.step(fan={"rpm": "ERR"})
        self.assertEqual(r.st["fan"]["f9_hist"], [])
        self.assertIsNone(r.st["fan"]["f9_prev"])
        r.step(fan={"rpm": 9000 - 1801})             # no previous: no rate test
        self.assertEqual(r.st["fan"]["f9_hist"], [False])
        r.step(fan="ABSENT")
        self.assertEqual(r.st["fan"]["f9_hist"], [])

    def test_k38_order_last(self):
        r = Runner(mkcfg())
        outs = [r.step(fan={"rpm": -1, "cur": 9}) for _ in range(3)]
        self.assertIn_("fan:F1", outs[2], "f")


def osc20_cfg():
    c = mkcfg()
    c["fan"]["rules"] = [{"zone": "cpuss-label", "base": "cpu0",
                          "trips": [{"t": 60000, "h": 5000, "lvl": 4}]}]
    return c


class TestK36F3Allowance(Base):
    def _alt(self, r, rpm_fn):
        cpu0 = 70000 if ((r.t + 1000) // 20000) % 2 else 40000
        return r.step(s={"cpu0": cpu0}, fan={"rpm": rpm_fn(r)})

    def test_k36_review_stuck_at_lower_alternating_target(self):
        # 3700 / 5500 every 20 s, always inside the allowance; fan stuck at
        # ~3700. Rising from 20000: e passes 4353 at 28000 -> timer 28000;
        # falling phases hold it; fires at 74000 (< 90 s)
        r = Runner(osc20_cfg())
        stuck = lambda r: 3700 + 10 * (((r.t + 1000) // 1000) % 2)
        first = None
        while r.t < 90000:
            o = self._alt(r, stuck)
            self.assertTrue(r.t < 20000 or r.st["fan"]["allow_until"] > r.t)
            if r.t == 27000:
                self.assertIsNone(r.st["fan"]["tm"]["F3"])
            if r.t == 28000:
                self.assertEqual(r.st["fan"]["tm"]["F3"], 28000)
            if r.t == 50000:                         # falling: held
                self.assertEqual(r.st["fan"]["tm"]["F3"], 28000)
            if first is None and "fan:F3" in items(o, "f"):
                first = r.t
        self.assertEqual(first, 74000)

    def test_k36_review_following_fan_never_faults(self):
        r = Runner(osc20_cfg())
        for _ in range(200):
            o = self._alt(r, lambda r: int(r.last["fan"]) if r.last else 3700)
            self.assertEqual(o["f"], "-", C.format_line(o))

    def test_k36_rising_bound_lag_1000(self):
        # one change 3700 -> 5500 at 20000; rpm stuck 3700/3710: e =
        # 3700 + 100 x (now - 21000) / 1000; condition from 28000
        r = Runner(osc20_cfg())
        stuck = lambda r: 3700 + 10 * (((r.t + 1000) // 1000) % 2)
        while r.t < 28000:
            cpu0 = 70000 if r.t + 1000 >= 20000 else 40000
            r.step(s={"cpu0": cpu0}, fan={"rpm": stuck(r)})
            if r.t == 27000:
                self.assertIsNone(r.st["fan"]["tm"]["F3"])
        self.assertEqual(r.st["fan"]["t_change"], 20000)
        self.assertEqual(r.st["fan"]["tm"]["F3"], 28000)

    def test_k36_falling_low_side(self):
        # 5500 -> 3700 (falling): condition rpm < 3700 - 555 = 3145
        for rpm, started in ((3144, True), (3145, False)):
            r = Runner(osc20_cfg())
            r.until(19000)
            r.until(39000, s={"cpu0": 70000})        # 5500 since 20000
            r.step(s={"cpu0": 40000}, fan={"rpm": 5500})   # 40000: change
            for _ in range(3):
                r.step(s={"cpu0": 40000}, fan={"rpm": rpm})
            self.assertEqual(r.st["fan"]["tm"]["F3"] is not None, started, rpm)

    def test_k36_outside_in_tolerance_resets_held_timer(self):
        # K-47: a fan stuck at 3000 outside the allowance (target 3700):
        # F3 from 16000, need = 3145. Target 4500 at 30000 (checked against
        # 3700 on that tick: 4400 is too fast, the timer runs on); at 31000
        # inside the allowance 4401 >= need releases the timer
        r = Runner(osc_cfg())
        r.until(29000, fan={"rpm": 3000})
        self.assertEqual(r.st["fan"]["tm"]["F3"], 16000)
        self.assertEqual(r.st["fan"]["need"], 3145)
        r.step(s={"cpu0": 70000}, fan={"rpm": 4400})       # 30000: change
        self.assertEqual(r.st["fan"]["tm"]["F3"], 16000)
        r.step(s={"cpu0": 70000}, fan={"rpm": 4401})       # 31000
        self.assertIsNone(r.st["fan"]["tm"]["F3"])
        self.assertEqual(r.st["fan"]["need"], 0)
        # outside the allowance a reading within tolerance resets as before
        r = Runner(osc_cfg())
        r.until(29000, fan={"rpm": 3000})
        r.step(fan={"rpm": 3200})                          # |3200-3700| <= 555
        self.assertIsNone(r.st["fan"]["tm"]["F3"])

    def test_k36_outside_in_tolerance_resets(self):
        # timer runs from 16000 (outside: |3000 - 3700| > 555); one tick
        # within tolerance outside the allowance resets it
        r = Runner(mkcfg())
        r.until(20000, fan={"rpm": 3000})
        self.assertEqual(r.st["fan"]["tm"]["F3"], 16000)
        r.step(fan={"rpm": 3255})                    # |445| <= 555
        self.assertIsNone(r.st["fan"]["tm"]["F3"])

    def test_k36_hold_inside_then_fire_on_held_tick(self):
        # K-47: target 4500 from the start (20 rpm/s: allowance to 76000);
        # from 77000 the fan reads 3500 < 4500 - 675: F3 runs, need = 3825.
        # At 80000 the target falls to 3700 (allowance 80000 + 15000 +
        # 40000 = 135000): 3500 is above x - tol(x) = 3145 but below need ->
        # held; it fires on a held tick at 123000 (> 45 s from 77000)
        c = osc_cfg()
        c["fan"]["rpm_per_sec"] = 20
        r = Runner(c)
        r.until(76000, s={"cpu0": 70000})
        self.assertEqual(r.st["fan"]["allow_until"], 76000)

        def rpm(r):
            return {"rpm": 3500 + (r.t // 1000) % 2}
        r.until(79000, s={"cpu0": 70000}, fan=rpm(r))
        r.step(s={"cpu0": 70000}, fan=rpm(r))        # 80000: still 4500
        self.assertEqual(r.st["fan"]["tm"]["F3"], 77000)
        self.assertEqual(r.st["fan"]["need"], 3825)
        while r.t < 123000:
            o = r.step(s={"cpu0": 40000}, fan=rpm(r))
            if r.t == 122000:
                self.assertEqual(r.st["fan"]["tm"]["F3"], 77000)
                self.assertNotIn_("fan:F3", o, "f")
        self.assertTrue(r.st["fan"]["allow_until"] > r.t)
        self.assertIn_("fan:F3", o, "f")

def spike_cfg(rps):
    c = mkcfg()
    c["fan"]["rpm_per_sec"] = rps
    c["fan"]["rules"] = [{"zone": "cpuss-label", "base": "cpu0",
                          "trips": [{"t": 72000, "h": 2000, "lvl": 2},
                                    {"t": 80000, "h": 2000, "lvl": 3},
                                    {"t": 85000, "h": 2000, "lvl": 4}]}]
    return c


def spike_cpu0(t):
    """74 C for 30 s, 81 C for 6 s, 86 C for 6 s, then 81 <-> 86 every 6 s."""
    if t < 31000:
        return 74000
    k = (t - 31000) // 6000
    return 81000 if k % 2 == 0 else 86000


class TestK37RampFromMeasured(Base):
    def _healthy(self, rps, ticks=300):
        """A physical fan: each tick it moves toward the last written target
        by at most rps x 1 s, with a 7 rpm tach jitter."""
        r = Runner(spike_cfg(rps))
        rpm = 3700
        for i in range(ticks):
            tgt = int(r.last["fan"]) if r.last else 3700
            step = max(-rps, min(rps, tgt - rpm))
            rpm += step
            o = r.step(s={"cpu0": spike_cpu0(r.t + 1000)},
                       fan={"rpm": rpm + 7 * (i % 2)})
            self.assertEqual(o["f"], "-", (rps, C.format_line(o)))
        self.assertFalse(r.st["latched"])
        return r

    def test_k37_review_healthy_fan_100(self):
        self._healthy(100)

    def test_k37_review_healthy_fan_50(self):
        self._healthy(50)

    def test_k37_base_uses_rpm_on_change_tick(self):
        # K-46: r0 = the median of the numeric readings of the last three
        # ticks. Target 3700 -> 5500 (osc20) at 20000
        r = Runner(osc20_cfg())
        r.until(17000)
        r.step(fan={"rpm": 3250})                        # 18000
        r.step(fan={"rpm": 3300})                        # 19000
        r.step(s={"cpu0": 70000}, fan={"rpm": 3200})     # 20000: change
        self.assertEqual(r.st["fan"]["t_change"], 20000)
        self.assertEqual(r.st["fan"]["r0"], 3250)
        # one high reading on the change tick is not the base (round 4)
        r = Runner(osc20_cfg())
        r.until(19000)                                   # 3700, 3710
        r.step(s={"cpu0": 70000}, fan={"rpm": 5000})     # 20000
        self.assertEqual(r.st["fan"]["r0"], 3710)
        # an ERR reading on the change tick: two readings -> the lower
        r = Runner(osc20_cfg())
        r.until(17000)
        r.step(fan={"rpm": 3250})                        # 18000
        r.step(fan={"rpm": 3300})                        # 19000
        r.step(s={"cpu0": 70000}, fan={"rpm": "ERR"})    # 20000
        self.assertEqual(r.st["fan"]["r0"], 3250)
        # no numeric reading in the last three ticks: the last numeric one
        r = Runner(osc20_cfg())
        r.until(16000)
        r.step(fan={"rpm": 3300})                        # 17000
        r.step(fan={"rpm": "ERR"})                       # 18000
        r.step(fan={"rpm": "ERR"})                       # 19000
        r.step(s={"cpu0": 70000}, fan={"rpm": "ERR"})    # 20000
        self.assertEqual(r.st["fan"]["r0"], 3300)

    def test_k37_review_stuck_at_lower_target_still_f3(self):
        # 3700 / 5500 every 20 s, fan stuck at ~3700: r0 = T_prev, so F3
        # still fires at 74000 (< 90 s)
        r = Runner(osc20_cfg())
        first = None
        while r.t < 90000:
            cpu0 = 70000 if ((r.t + 1000) // 20000) % 2 else 40000
            o = r.step(s={"cpu0": cpu0},
                       fan={"rpm": 3700 + 10 * (((r.t + 1000) // 1000) % 2)})
            if first is None and "fan:F3" in items(o, "f"):
                first = r.t
        self.assertEqual(first, 74000)

    def _falling_setup(self, r0):
        # steady 3700 until 20000, then the falling-change state of K-37:
        # T = 3700 in force, T_prev = 5500, r0 = rpm on the change tick
        r = Runner(mkcfg())
        r.until(20000)
        f = r.st["fan"]
        # K-43: x consistent with that history (a fan ramping from r0)
        f.update(t_before=5500, r0=r0, t_change=20000, allow_until=100000,
                 x=min(r0, 3700))
        for k in f["tm"]:
            f["tm"][k] = None
        return r

    def test_k37_falling_fan_ramping_up_from_below(self):
        # base = min(5500, 3000) = 3000; e = 3000 + 100 x (now - 21000)/1000;
        # a fan ramping at 100 rpm/s is never judged (old rule: 3000 < 3145)
        r = self._falling_setup(3000)
        for k in range(1, 15):
            r.step(fan={"rpm": min(3700, 3000 + 100 * k) + (k % 2)})
            self.assertIsNone(r.st["fan"]["tm"]["F3"], r.t)

    def test_k37_falling_fan_stuck_below(self):
        # negative control: stuck at 3000 -> e - tol(e) > 3000 from 27000
        r = self._falling_setup(3000)
        for k in range(1, 8):
            r.step(fan={"rpm": 3000 + (k % 2)})
            if r.t == 26000:
                self.assertIsNone(r.st["fan"]["tm"]["F3"])
        self.assertEqual(r.st["fan"]["tm"]["F3"], 27000)

    def test_k37_falling_fan_above_target(self):
        # r0 = 4000 >= T: e = T at once -> rpm < 3700 - 555 = 3145
        for rpm, started in ((3144, True), (3145, False)):
            r = self._falling_setup(4000)
            r.step(fan={"rpm": rpm})
            r.step(fan={"rpm": rpm + 1})
            r.step(fan={"rpm": rpm})
            started_now = r.st["fan"]["tm"]["F3"] is not None
            self.assertEqual(started_now, started, rpm)

    def test_k37_slow_start_fan_still_bounded(self):
        # the change tick reads 1000 rpm and the fan stays there: the bound
        # e = 1000 + 100 x (now - 21000) / 1000 overtakes it -> F3 timer
        r = Runner(osc20_cfg())
        r.until(19000)
        r.step(s={"cpu0": 70000}, fan={"rpm": 1000})     # 20000
        while r.t < 30000:
            r.step(s={"cpu0": 70000}, fan={"rpm": 1000 + (r.t // 1000) % 2})
        # e at 28000 = 1000 + 700 = 1700 -> 1700 - 500 = 1200 > 1001
        self.assertIsNotNone(r.st["fan"]["tm"]["F3"])


class TestK43RampExpectation(Base):
    @staticmethod
    def _first_fault(cfg, cpu0_fn, rpm_fn, n=300):
        r = Runner(cfg)
        first = None
        for i in range(n):
            # cpu1 moves slightly so K-33 never sees it as stuck
            o = r.step(s={"cpu0": cpu0_fn(r.t + 1000), "cpu1": 41000 + (i % 2)},
                       fan={"rpm": rpm_fn(i)})
            if first is None and o["f"] != "-":
                first = (r.t, o)
        return r, first

    def test_k43_x_on_changes(self):
        r = Runner(mkcfg())
        r.step()                                     # 0 -> 3700, both silent
        self.assertEqual(r.st["fan"]["x"], 3700)     # a jump
        c = osc20_cfg()
        r = Runner(c)
        r.until(17000)
        self.assertEqual(r.st["fan"]["x"], 3700)     # outside: x = T
        r.step(fan={"rpm": 4200})                        # 18000
        r.step(fan={"rpm": 4200})                        # 19000
        r.step(s={"cpu0": 70000}, fan={"rpm": 4200})     # 20000: -> 5500
        self.assertEqual(r.st["fan"]["x"], 4200)     # fan ahead is credited
        r.step(s={"cpu0": 70000}, fan={"rpm": 4200})     # 21000: lag
        self.assertEqual(r.st["fan"]["x"], 4200)
        r.step(s={"cpu0": 70000}, fan={"rpm": 4300})     # 22000: +100
        self.assertEqual(r.st["fan"]["x"], 4300)
        r.step(s={"cpu0": 40000}, fan={"rpm": 4400})     # 23000: -> 3700
        self.assertEqual(r.st["fan"]["x"], 3700)     # Tn < x
        r = Runner(c)
        r.until(19000)
        r.step(s={"cpu0": 70000}, fan={"rpm": 3000})     # slow fan
        self.assertEqual(r.st["fan"]["x"], 3700)     # never lowered by it
        r = Runner(c)
        r.until(19000)
        r.step(s={"cpu0": 70000}, fan={"rpm": 4200})     # one high reading
        self.assertEqual(r.st["fan"]["x"], 3710)     # K-46: the median only

    def test_k43_spike_wobble_stuck_3700_f3(self):
        r, first = self._first_fault(spike_cfg(100), spike_cpu0,
                                     lambda i: 3700 + 10 * (i % 2))
        self.assertEqual(first[0], 68000)
        self.assertIn_("fan:F3", first[1], "f")
        self.assertIn_("t4:fan-trip2", first[1], "e")    # 86 C: trip 2

    def test_k43_spike_wobble_stuck_4500_f3(self):
        r, first = self._first_fault(spike_cfg(100), spike_cpu0,
                                     lambda i: 4500 + 10 * (i % 2))
        self.assertEqual(first[0], 87000)
        self.assertIn_("fan:F3", first[1], "f")

    def test_k43_spike_wobble_stuck_5000_within_tolerance(self):
        # negative control: 5000 vs 5000/5500 is within max(500, 15 %)
        r, first = self._first_fault(spike_cfg(100), spike_cpu0,
                                     lambda i: 5000 + 10 * (i % 2))
        self.assertIsNone(first)

    def test_k43_20s_alternation_stuck_3700_f3(self):
        alt = lambda t: 70000 if (t // 20000) % 2 else 40000
        r, first = self._first_fault(osc20_cfg(), alt,
                                     lambda i: 3700 + 10 * (i % 2), n=120)
        self.assertEqual(first[0], 74000)

    @unittest.expectedFailure
    def test_k43_gap_6s_alternation_3700_5500_stuck_3700(self):
        # Requested property, NOT delivered by K-43 as written: on each fall
        # to 3700, x = 3700; on each rise, x = max(3700, min(r0 = 3700,
        # 5500)) = 3700, and x grows 100 rpm/s only from t_change + 2000, so
        # within a 6 s phase it reaches about 4100 (F3 needs x >= 4365 for a
        # fan at 3710). Reported to the spec owner.
        alt = lambda t: 70000 if (t // 6000) % 2 else 40000
        r, first = self._first_fault(osc20_cfg(), alt,
                                     lambda i: 3700 + 10 * (i % 2), n=290)
        self.assertIsNotNone(first)


# ------------------------------------------------- §20 K-50 ... K-55 (PMIC)
PMIC_TH = [N, N, N, 95000, N, N, 115000]           # K-51
PMIC_HY = [N, N, N, 5000, N, N, 5000]


def pmic_cfg(pmic_min=2, **over):
    """BASE_CFG plus a PMIC class (K-50/K-52): two iio dies, group pmic."""
    c = mkcfg(**over)
    c["groups"].append({"name": "pmic", "class": "PMIC", "min": pmic_min})
    for n in ("pmA", "pmB"):
        c["sensors"].append({"name": n, "class": "PMIC", "group": "pmic",
                             "kind": "iio", "slow": 0, "indep": 0,
                             "th": list(PMIC_TH), "hy": list(PMIC_HY),
                             "vin": []})
    return c


def pmic_runner(cfg=None):
    r = Runner(cfg or pmic_cfg())
    r.set(s={"pmA": 40000, "pmB": 41000})            # read from "s" (K-50)
    return r


class TestK50PmicClass(Base):
    def test_k50_iio_kind_accepted_unknown_rejected(self):
        cfg = C.load_config(pmic_cfg())
        self.assertIn("pmA", [s["name"] for s in cfg["measured"]])
        self.assertIn("PMIC", cfg["classes"])
        c = pmic_cfg()
        c["sensors"][-1]["kind"] = "hwmon"
        with self.assertRaises(C.ConfigError):
            C.load_config(c)

    def test_k50_quiet_ready(self):
        r = pmic_runner()
        o = r.step()
        self.assertEqual((o["e"], o["ready"], o["tier"], o["n"]),
                         ("ready", 1, 0, "-"))
        o = r.until(200000)
        self.assertEqual((o["f"], o["tier"]), ("-", 0))

    def test_k50_iio_read_fault_like_zone(self):
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": "ERR"})
        self.assertIn_("s:pmA:read", o, "f")
        self.assertIn_("c:PMIC", o, "f")             # group min 2 (K-52)
        r = Runner(pmic_cfg())
        r.set(s={"pmB": 41000})                      # pmA not in "s": ABSENT
        o = r.step()
        self.assertIn_("s:pmA:read", o, "f")

    def test_k50_hot_anomaly_latches_pmic_hot(self):
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": 125001})                # C-4, no sibling: C-8
        self.assertIn_("p:pmA", o, "f")
        self.assertIn_("c:PMIC", o, "f")             # every die required
        self.assertEqual(o["n"], "warn:sensor-fault:120")
        r.step(s={"pmA": 125001})
        o = r.step(s={"pmA": 125001})                # n = 2
        self.assertIn_("t4:anomaly:pmA", o, "e")
        self.assertEqual(o["n"], "shutdown:pmic-hot:55")

    def test_k50_iio_never_stuck(self):
        # K-33/K-40: SOC zone sensors only; a flat PMIC die while the SoC
        # moves by > 3 C for > 300 s is not a fault
        r = pmic_runner()
        r.step()
        k = 0
        while r.t < 420000:
            k += 1
            v = 40000 + (k % 40) * 100
            o = r.step(s={"cpu0": v, "cpu1": v + 50})
            self.assertEqual(o["f"], "-", C.format_line(o))


class TestK51PmicLevels(Base):
    def test_k51_severe_95(self):
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": 94999})                 # negative control
        self.assertEqual((o["tier"], o["n"]), (0, "-"))
        o = r.step(s={"pmA": 95000})
        self.assertEqual((o["tier"], o["n"]), (3, "warn:pmic-hot"))
        self.assertEqual(t4(o), set())

    def test_k51_shutdown_115(self):
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmB": 114999})                # negative control
        self.assertEqual((o["tier"], t4(o)), (3, set()))
        o = r.step(s={"pmB": 115000})
        self.assertEqual(o["tier"], 4)
        self.assertEqual(t4(o), {"t4:shutdown:pmB"})
        self.assertEqual(o["n"], "shutdown:pmic-hot:55")

    def test_k51_gate_hot_at_severe_minus_hy(self):
        # K-55: C-42 applies to PMIC sensors (SEVERE 95000 - hy 5000)
        r = pmic_runner()
        tick = r.base(1000)
        Runner.merge(tick, {"s": {"pmA": 89999, "pmB": 41000}})
        self.assertEqual(C.gate(r.cfg, C.norm_tick(tick)), "gate=pass reasons=-")
        tick["s"]["pmA"] = 90000
        self.assertEqual(C.gate(r.cfg, C.norm_tick(tick)),
                         "gate=refuse reasons=hot:pmA")


class TestK53PmicSelfTest(Base):
    def first(self, cfg=None, **ov):
        return pmic_runner(cfg).step(**ov)

    def test_k53_pmic_sensor_required(self):
        o = self.first(s={"pmB": "ERR"})
        self.assertEqual((o["e"], o["ready"]), ("notready:sensor:pmB", 0))
        r = Runner(pmic_cfg())                       # PMIC dies not in "s"
        o = r.step()
        self.assertEqual(o["e"], "notready:sensor:pmA")

    def test_k53_order_soc_before_pmic(self):
        o = self.first(s={"pmA": "ERR", "cpu1": "ERR"})
        self.assertEqual(o["e"], "notready:sensor:cpu1")
        o = self.first(s={"pmA": "ERR", "skin": "ERR"})  # two classes
        self.assertEqual(items(o, "e"), {"notready:sensor:skin", "t4:classes"})

    def test_k53_config_order_of_sensor_items(self):
        # sensor items follow the config order, not the class order
        c = pmic_cfg()
        c["sensors"].insert(0, c["sensors"].pop())   # pmB first
        o = self.first(c, s={"pmB": "ERR", "cpu0": "ERR"})
        self.assertEqual(o["e"], "notready:sensor:pmB")

    def test_k53_class_items(self):
        o = self.first(pmic_cfg(pmic_min=3))         # 2 dies, min 3
        self.assertEqual(o["e"], "notready:class:PMIC")
        c = pmic_cfg(pmic_min=3)
        c["groups"][0]["min"] = 3                    # SOC short too
        o = self.first(c)                            # two classes: T4 too
        self.assertEqual(items(o, "e"), {"notready:class:SOC", "t4:classes"})
        o = self.first(pmic_cfg(pmic_min=3), adsp="offline")
        self.assertEqual(items(o, "e"), {"notready:class:BATT", "t4:classes"})
        # every class item precedes caps
        o = self.first(pmic_cfg(pmic_min=3), caps_ok_at_start=False)
        self.assertEqual(o["e"], "notready:class:PMIC")


class TestK54PmicNotice(Base):
    def test_k54_warn_priority(self):
        r = pmic_runner()
        o = r.step(s={"cpu0": 95000, "pmA": 95000})
        self.assertEqual(o["n"], "warn:soc-temperature-high")
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": 95000}, fan={"cur": 9})     # F1 fan fault
        self.assertIn_("fan:F1", o, "f")
        self.assertEqual(o["n"], "warn:pmic-hot")
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": 95000, "cpu1": "ERR"})      # beats sensor-fault
        self.assertEqual(o["n"], "warn:pmic-hot")
        r = pmic_runner()
        r.step()
        for v in (38000, 46000, 52000):
            o = r.step(s={"pmA": 95000, "skin": v})
        self.assertEqual(o["n"], "warn:skin-temperature-high")

    def test_k54_shutdown_priority(self):
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": 115000, "cpu0": 115000})
        self.assertEqual(o["n"], "shutdown:soc-temperature-high:55")
        r = pmic_runner(pmic_cfg(p5={"sensor": "cpu1", "t": 100000}))
        r.step()
        o = r.step(s={"pmA": 115000, "cpu1": 100000})
        self.assertEqual(t4(o), {"t4:p5", "t4:shutdown:pmA"})
        self.assertEqual(o["n"], "shutdown:pmic-hot:55")   # before usb
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": 115000}, cap_fail=True)
        self.assertEqual(o["n"], "shutdown:pmic-hot:55")

    def test_k54_sensor_and_class_map_to_sensor_fault(self):
        cfg = C.load_config(pmic_cfg())
        self.assertEqual(C.t4_reason(cfg, "sensor:pmA"), "sensor-fault")
        self.assertEqual(C.t4_reason(cfg, "class:PMIC"), "sensor-fault")
        self.assertEqual(C.t4_reason(cfg, "shutdown:pmA"), "pmic-hot")
        self.assertEqual(C.t4_reason(cfg, "anomaly:pmB"), "pmic-hot")
        # a sensor fault: warn sensor-fault with its countdown
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": "ERR"})
        self.assertEqual(o["n"], "warn:sensor-fault:120")

    def test_k54_class_pmic_fault_alone(self):
        # group min 3 over 2 dies: class:PMIC only (trial_override keeps the
        # failed self-test from latching T4 first)
        r = pmic_runner(pmic_cfg(pmic_min=3, flags={"trial_override": 1}))
        o = r.step()
        self.assertEqual(o["e"], "notready:class:PMIC")
        self.assertEqual(o["n"], "warn:sensor-fault:120")
        o = r.until(120000)
        self.assertEqual((o["tier"], t4(o)), (3, set()))
        o = r.step()                                 # 121000
        self.assertEqual(t4(o), {"t4:class:PMIC"})
        self.assertEqual(o["n"], "shutdown:sensor-fault:55")


class TestK55PmicNoFastT5(Base):
    def test_k55_no_p12_for_pmic(self):
        r = pmic_runner()
        r.step()
        o = r.step(s={"pmA": 115000})                # T4
        self.assertEqual(o["tier"], 4)
        for v in (120000, 125000):
            o = r.step(s={"pmA": v})
            self.assertEqual(o["tier"], 4)
            self.assertEqual(o["e"], "-", C.format_line(o))
        o = r.step(s={"pmA": 125000, "cpu0": 120000})    # positive control
        self.assertEqual(o["tier"], 5)
        self.assertEqual(o["e"], "t5:p12:cpu0")

    def test_k55_no_p12_on_latch_tick(self):
        o = pmic_runner().step(s={"pmA": 125000})
        self.assertIn_("t4:shutdown:pmA", o, "e")
        self.assertEqual(o["tier"], 4)
        self.assertNotIn_("t5:p12:pmA", o, "e")


# ------------------------------------------------------------------- CLI
class TestCli(Base):
    def test_cli_lines_and_gate(self):
        here = os.path.dirname(os.path.abspath(__file__))
        script = os.path.join(here, "core_ref.py")
        r = Runner(mkcfg())
        ticks = [r.base(1000 * i) for i in range(1, 4)]
        ticks[1]["s"]["cpu0"] = "ERR"
        with tempfile.TemporaryDirectory() as d:
            cp = os.path.join(d, "c.json")
            tp = os.path.join(d, "t.jsonl")
            with open(cp, "w") as fh:
                json.dump(BASE_CFG, fh)
            with open(tp, "w") as fh:
                for t in ticks:
                    fh.write(json.dumps(t) + "\n")
            out = subprocess.run([sys.executable, "-I", script, "--config", cp,
                                  "--ticks", tp], capture_output=True,
                                 text=True, check=True).stdout
            lines = out.splitlines()
            self.assertEqual(len(lines), 3)
            self.assertEqual(lines[0], "t=1000 tier=0 ready=1 fan=3700 "
                             "cpu=2054400 gpu=2 f=- e=ready a=pet n=-")
            self.assertIn("f=s:cpu0:read", lines[1])
            ticks[0]["pstore_marker"] = True
            ticks[0]["s"]["cpu0"] = 89000
            with open(tp, "w") as fh:
                for t in ticks:
                    fh.write(json.dumps(t) + "\n")
            out = subprocess.run([sys.executable, "-I", script, "--config", cp,
                                  "--ticks", tp, "--gate"], capture_output=True,
                                 text=True, check=True).stdout
            self.assertEqual(out, "gate=refuse reasons=hot:cpu0\n")

    def test_config_accepts_critical_slot(self):
        c = mkcfg()
        c["sensors"][0]["th"][4] = 100000           # K-28: fail closed
        C.load_config(c)

    def test_decide_is_pure(self):
        cfg = C.load_config(mkcfg())
        st = C.initial_state(cfg)
        snap = copy.deepcopy(st)
        r = Runner(mkcfg())
        C.decide(cfg, st, C.norm_tick(r.base(1000)), 1000)
        self.assertEqual(st, snap)


if __name__ == "__main__":
    unittest.main(verbosity=2)
