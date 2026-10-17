#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""fs-thermald scenarios: every tier transition and every refusal, each with
a negative control (the same scenario one step short must NOT trigger).

Each scenario drives the C binary through harness.Sim, asserts its own
expected results (rule ids from CORE-SPEC.md), and is then replayed through
the independent Python reference (differential). Results go to
fixtures/core/RESULTS.txt.

usage: scenarios.py --bin FS_THERMALD [--only SUBSTR] [--out FILE] [--no-diff]
"""
import argparse
import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import Fail, Sim, expect  # noqa: E402
from fanmodel import Fan  # noqa: E402

SC = []


def sc(fn):
    SC.append(fn)
    return fn


def t4s(sim):
    return [o for o in sim.outs if any(e.startswith('t4:') for e in o['E'])]


def at(sim, t):
    for o in sim.outs:
        if int(o['t']) == t:
            return o
    raise Fail(f'no tick at {t}')


def ramp(sim, name, target, step=5000):
    """raise a slow sensor without a C-5 rise anomaly (<= step per tick)"""
    while sim.val[name] != target:
        v = sim.val[name]
        sim.val[name] = min(target, v + step) if target > v else max(target, v - step)
        sim.step()


# ------------------------------------------------------------------ basics
@sc
def idle_normal(B):
    s = B()
    s.run(40)
    o = s.outs
    expect('ready' in o[0]['E'], 'ready on first tick (C-29)')
    expect(all(x['tier'] == 0 for x in o), 'tier 0 throughout')
    expect(all(x['fan'] == '3700' for x in o), 'P1 floor 3700 (C-21)')
    expect(all(x['cpu'] == '1920000' and x['gpu'] == '3' for x in o), 'NORMAL caps = L4 (P11 rejected, C-27)')
    expect(all('pet' in x['A'] for x in o), 'pet every complete cycle (C-37)')
    expect(not any(x['F'] for x in o), 'no faults')
    return s


@sc
def soc_levels_pm1(B):
    s = B()
    s.run(2)
    seq = [(88999, 0), (89000, 1), (91999, 1), (92000, 2), (94999, 2), (95000, 3), (114999, 3)]
    for v, tier in seq:
        s.val['cpu-1-0-0'] = v
        o = s.step()
        expect(o['tier'] == tier, f'{v} m°C -> tier {tier} (C-10 at ±1 m°C), got {o["tier"]}')
    expect(not t4s(s), 'no T4 below 115000 (negative control)')
    s.val['cpu-1-0-0'] = 115000
    o = s.step()
    expect(o['tier'] == 4 and 't4:shutdown:cpu-1-0-0' in o['E'], 'SHUTDOWN 115000 -> T4 (C-16)')
    expect('signal-pid1' in o['A'] and o['fan'] == '5500' and o['cpu'] == 'min' and o['gpu'] == '9',
           'T4: signal PID 1, fan top, minimum caps (design §5.3)')
    expect(o['n'] == 'shutdown:soc-temperature-high:55', f'notice: SoC hot, shutting down in 55 s (K-19, K-21): {o["n"]}')
    expect(s.outs[-2]['n'] == 'warn:soc-temperature-high' and s.outs[2]['n'] == '-',
           'notice: WARN shows the reason; NORMAL/NOTICE/THROTTLE show none (K-18, K-20)')
    return s


@sc
def hysteresis_dwell(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 89000
    expect(s.step()['tier'] == 1, 'LIGHT')
    s.val['cpu-1-0-0'] = 87000  # = 89000 - 2000: not below the release point
    s.run(40)
    expect(s.outs[-1]['tier'] == 1, 'at the release point the level holds (negative control)')
    s.val['cpu-1-0-0'] = 86999
    for i in range(30):
        o = s.step()
        expect(o['tier'] == 1, f'held during the 30 s dwell (tick {i})')
    o = s.step()
    expect(o['tier'] == 0, 'dropped after 30 s below the release point (C-10)')
    return s


@sc
def t3_shown_30s(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 95000
    o = s.step()
    t0 = int(o['t'])
    expect(o['tier'] == 3, 'SEVERE')
    s.val['cpu-1-0-0'] = 40000
    s.run(29)
    expect(s.outs[-1]['tier'] == 3, 'WARN still shown at +29 s (C-17)')
    s.run(4)
    expect(s.outs[-1]['tier'] == 0, 'back to NORMAL after the dwell')
    return s


@sc
def battery_levels(B):
    s = B()
    s.run(2)
    ramp(s, 'batt-virt-usr', 55000)
    for v, tier in [(57999, 0), (58000, 1), (60999, 1), (61000, 2), (62999, 2), (63000, 3), (64999, 3)]:
        s.val['batt-virt-usr'] = v
        o = s.step()
        expect(o['tier'] == tier, f'battery {v} -> {tier}, got {o["tier"]}')
    s.val['batt-virt-usr'] = 65000
    o = s.step()
    expect('t4:shutdown:batt-virt-usr' in o['E'], 'battery SHUTDOWN 65 °C -> T4')
    expect(o['n'] == 'shutdown:battery-overheating:55', 'notice: battery overheating, 55 s')
    return s


@sc
def psy_battery_shutdown(B):
    s = B()
    s.run(3)
    s.psy['temp'] = 649
    s.run(10)
    expect(not t4s(s), '64.9 °C at the psy: no T4 (negative control)')
    s.psy['temp'] = 650
    s.run(6)
    expect(any('t4:shutdown:psy-battery' in o['E'] for o in s.outs), 'psy battery 65.0 °C -> T4 (5 s samples, C-30)')
    return s


@sc
def skin_levels(B):
    s = B()
    s.run(2)
    ramp(s, 'surf-virt-usr', 59000, 4000)
    expect(not t4s(s), 'skin 59 °C: no T4')
    expect(s.outs[-1]['tier'] == 3, 'skin above SEVERE 52 -> WARN')
    s.val['surf-virt-usr'] = 59999
    s.step()
    expect(not t4s(s), 'skin 59.999: no T4 (negative control)')
    s.val['surf-virt-usr'] = 60000
    o = s.step()
    expect('t4:shutdown:surf-virt-usr' in o['E'], 'skin SHUTDOWN 60 °C -> T4')
    expect(o['n'] == 'shutdown:skin-temperature-high:55', 'notice: skin temperature high, 55 s')
    return s


# ------------------------------------------------------------- T5 and timeline
@sc
def t5_fast_p12(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 115000
    o = s.step()
    t4 = int(o['t'])
    s.val['cpu-1-0-0'] = 119999
    s.run(2)
    expect(all(x['tier'] == 4 for x in s.outs[-2:]), 'SHUTDOWN + 4.999: still T4 (negative control)')
    s.val['cpu-1-0-0'] = 120000
    o = s.step()
    tf = int(o['t'])
    expect(o['tier'] == 5 and 't5:p12:cpu-1-0-0' in o['E'] and 'a1' in o['A'], 'SHUTDOWN + 5 °C -> T5 now, A1 (P12, C-18)')
    expect(o['n'] == 'shutdown:soc-temperature-high:10', f'notice countdown follows the fast A2 (10 s): {o["n"]}')
    s.run(9)
    expect(not any('a2' in x['A'] for x in s.outs), 'A2 not before tf + 10 s')
    o = s.step()
    expect(int(o['t']) == tf + 10000 and 'final-pet' in o['A'] and 'a2' in o['A'] and 'pet' not in o['A'],
           'final pet then A2 at tf + 10 s (C-36)')
    expect(o['n'] == 'shutdown:soc-temperature-high:0', 'notice reaches 0 at A2')
    s.run(5)
    expect(all(not x['A'] for x in s.outs[-5:]), 'no pet and no reboot() after A2 (C-37, C-38)')
    return s


@sc
def t5_fast_a1_done(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 120000
    o = s.step()
    expect('t4:shutdown:cpu-1-0-0' in o['E'] and 't5:p12:cpu-1-0-0' in o['E'], 'latch and fast T5 on the same tick')
    s.run(2)
    s.flags_files.add('a1_done')
    o = s.step()
    expect('a2' in o['A'] and 'final-pet' in o['A'], 'A2 as soon as A1 reports done (C-36)')
    return s


@sc
def budget_t5_and_a2(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 115000
    t4 = int(s.step()['t'])
    s.val['cpu-1-0-0'] = 100000
    s.run(44)
    expect(not any('a1' in x['A'] for x in s.outs), 'no A1 before T4 + 45 s')
    o = s.step()
    expect(int(o['t']) == t4 + 45000 and 'a1' in o['A'] and 't5:budget' in o['E'] and o['tier'] == 5,
           'T5 by budget at + 45 s: A1 (P12, C-35)')
    s.run(9)
    o = s.step()
    expect(int(o['t']) == t4 + 55000 and 'final-pet' in o['A'] and 'a2' in o['A'], 'final pet + A2 at + 55 s')
    expect(at(s, t4 + 45000)['n'] == 'shutdown:soc-temperature-high:10' and o['n'].endswith(':0'),
           'notice counts down 55 -> 10 -> 0 and never moves A1/A2 (J-171 f)')
    s.flags_files.add('a2_exited')
    s.run(3)
    expect(not any('sysrq-c' in x['A'] for x in s.outs), 'no sysrq c without P15 (negative control)')
    return s


@sc
def p15_sysrq_after_a2(B):
    s = B(flags=['--p15'])
    s.run(2)
    s.val['cpu-1-0-0'] = 115000
    s.step()
    s.flags_files.add('a2_exited')  # before A2: must not act
    s.run(10)
    expect(not any('sysrq-c' in x['A'] for x in s.outs), 'sysrq c never before A2 (K-12)')
    s.run(50)
    expect(sum('sysrq-c' in x['A'] for x in s.outs) == 1, 'P15: one sysrq c after A2 exited')
    return s


@sc
def external_shutdown_byte(B):
    s = B()
    s.run(10)
    s.flags_files.add('shutdown_byte')
    t0 = int(s.step()['t'])
    s.run(55)
    o45, o55 = at(s, t0 + 45000), at(s, t0 + 55000)
    expect('a1' in o45['A'] and 'final-pet' in o55['A'] and 'a2' in o55['A'],
           'detected shutdown: A1 + 45 s, final pet + A2 + 55 s (design §5.1, C-35)')
    expect(all(x['tier'] == 0 for x in s.outs), 'tier unchanged by an external shutdown')
    expect(not any('pet' in x['A'] for x in s.outs if int(x['t']) >= t0 + 55000), 'no pet after the final pet')
    expect(not any('signal-pid1' in x['A'] for x in s.outs), 'no signal to PID 1 for its own shutdown')
    expect(at(s, t0)['n'] == 'shutdown:shutdown-requested:55', 'notice: shutdown requested, 55 s')
    return s


@sc
def external_shutdown_comm(B):
    s = B()
    s.run(5)
    s.pid1 = 'systemd-shutdow'
    t0 = int(s.step()['t'])
    s.run(56)
    expect('a2' in at(s, t0 + 55000)['A'], 'PID 1 comm systemd-shutdow detected (design §5.1)')
    return s


@sc
def stage_mode_trip(B):
    s = B(flags=['--stage'])
    s.run(3)
    s.flags_files.add('shutdown_byte')
    s.run(3)
    expect(not any(x['A'] - {'pet'} for x in s.outs), 'stage mode ignores the shutdown byte (K-11)')
    s.val['cpu-1-0-0'] = 115000
    o = s.step()
    t4 = int(o['t'])
    expect('term-step' in o['A'] and 'signal-pid1' not in o['A'], 'stage: SIGTERM to the step (design §5.3)')
    expect(o['n'] == 'shutdown:soc-temperature-high:2', 'stage notice: 2 s')
    s.step()
    o = s.step()
    expect(int(o['t']) == t4 + 2000 and {'kill-step', 'final-pet', 'trip'} <= o['A'],
           'stage: + 2 s SIGKILL, final pet, TRIP; PID 1 is the only reboot caller')
    expect(o['n'] == 'shutdown:soc-temperature-high:0', 'stage notice 0 at TRIP')
    s.run(50)
    expect(not any({'a1', 'a2'} & x['A'] for x in s.outs), 'stage: no A1/A2 ever')
    return s


# ------------------------------------------------------------- departures
@sc
def p5_usb_conn(B):
    s = B()
    s.run(2)
    s.val['usb-conn'] = 69999
    s.run(3)
    expect(not t4s(s), 'usb-conn 69.999: no T4 (negative control)')
    s.val['usb-conn'] = 70000
    o = s.step()
    expect('t4:p5' in o['E'], 'usb-conn 70 °C -> T4 (P5)')
    expect(o['n'] == 'shutdown:usb-connector-hot:55', 'notice: USB connector hot')
    return s


@sc
def p6_p13_low_battery(B):
    s = B()
    s.run(2)
    s.psy['cap'] = 11
    s.run(6)
    expect(all(x['tier'] == 0 for x in s.outs), '11 %: nothing')
    s.psy['cap'] = 10
    s.run(6)
    expect(any('lowbatt' in x['E'] for x in s.outs) and s.outs[-1]['tier'] == 3, '10 % discharging: WARN (P13)')
    expect(s.outs[-1]['n'] == 'warn:battery-low', 'notice: battery low (no countdown)')
    expect(not t4s(s), 'P13 never shuts down')
    s.psy['cap'] = 4
    s.run(6)
    expect(not t4s(s), '4 %: no T4 (negative control)')
    s.psy['cap'] = 3
    s.run(6)
    expect(any('t4:p6' in x['E'] for x in s.outs), '3 % discharging -> T4 (P6)')
    expect(s.first(lambda x: 't4:p6' in x['E'])['n'] == 'shutdown:battery-empty:55', 'notice: battery empty')
    return s


@sc
def p6_charging_no_t4(B):
    s = B()
    s.psy['cap'] = 3
    s.psy['status'] = 'Charging'
    s.run(12)
    expect(not t4s(s), '3 % while charging: no P6 (negative control)')
    return s


@sc
def p14_unplug(B):
    s = B()
    s.run(2)
    s.usb = 1
    s.val['cpu-1-0-0'] = 115000
    o = s.step()
    expect('unplug' in o['E'], 'T4 with a charger attached -> unplug notice (P14)')
    return s


@sc
def p14_no_unplug_on_battery(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 115000
    o = s.step()
    expect('unplug' not in o['E'], 'no unplug notice without a charger (negative control)')
    return s


@sc
def j145_notice(B):
    s = B()
    s.psy['status'] = 'Charging'
    s.psy['temp'] = 299
    s.run(12)
    expect(not any('j145' in x['E'] for x in s.outs), '29.9 °C while charging: no J-145 notice')
    expect(all(x['tier'] == 0 for x in s.outs), '29.9 °C while charging: NORMAL')
    s.psy['temp'] = 300
    s.run(70)
    n = sum('j145' in x['E'] for x in s.outs)
    expect(n == 1, f'30.0 °C while charging: one J-145 event (got {n})')
    expect(s.outs[-1]['tier'] == 3 and s.outs[-1]['n'] == 'warn:charging-too-warm' and not t4s(s),
           'J-145 is a WARN only, never a shutdown by itself (PM J-171, K-17)')
    s.psy['status'] = 'Discharging'
    s.run(40)
    expect(s.outs[-1]['tier'] == 0, 'WARN ends when charging stops (after the 30 s WARN hold)')
    return s


# ------------------------------------------------------------- sensor faults
@sc
def sensor_read_error_t4(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 'ERR'
    o = s.step()
    t0 = int(o['t'])
    expect('s:cpu-1-0-0:read' in o['F'] and o['tier'] == 3, 'read error -> sensor fault, WARN (C-1, P9)')
    s.run(119)
    expect(not t4s(s), 'no T4 before 120 s')
    o = s.step()
    expect(int(o['t']) == t0 + 120000 and 't4:sensor:cpu-1-0-0' in o['E'], 'T4 at 120 s (C-9)')
    expect(at(s, t0)['n'] == 'warn:sensor-fault:120' and at(s, t0 + 119000)['n'] == 'warn:sensor-fault:1',
           'notice: sensor fault, shutting down in 120 .. 1 s unless it recovers (K-21)')
    expect(o['n'] == 'shutdown:sensor-fault:55', 'then: shutting down in 55 s')
    return s


@sc
def sensor_read_error_recovers(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 'ERR'
    s.run(60)
    s.val['cpu-1-0-0'] = 40000
    s.run(29)
    expect('s:cpu-1-0-0:read' in s.outs[-1]['F'], 'fault held during the 30 s recovery window')
    s.run(2)
    expect('s:cpu-1-0-0:read' not in s.outs[-1]['F'], 'fault cleared after 30 s healthy (C-9)')
    s.run(60)
    expect(not t4s(s), 'recovered fault never latches T4 (negative control)')
    return s


@sc
def sensor_low(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = -20000
    o = s.step()
    expect(not o['F'], '-20.000 °C: healthy (negative control)')
    s.val['cpu-1-0-0'] = -20001
    o = s.step()
    expect('s:cpu-1-0-0:low' in o['F'], '-20.001 °C -> fault low (C-2)')
    return s


@sc
def class_fault_two_classes(B):
    s = B()
    s.run(2)
    for i in range(4):
        for j in range(2):
            s.val[f'cpu-1-{i}-{j}'] = 'ERR'
    o = s.step()
    expect('c:SOC' in o['F'] and not t4s(s), 'cluster 1 lost -> SoC class fault, WARN only (C-11)')
    s.val['surf-virt-usr'] = 'ERR'
    o = s.step()
    expect('t4:classes' in o['E'], 'two faulted classes -> T4 at once (C-11)')
    return s


@sc
def class_fault_120s(B):
    s = B()
    s.run(2)
    s.adsp = 'offline'
    o = s.step()
    t0 = int(o['t'])
    expect('b:adsp' in o['F'] and 'c:BATT' in o['F'] and o['tier'] == 3, 'ADSP not running -> battery class fault (C-12)')
    s.run(120)
    expect('t4:class:BATT' in at(s, t0 + 120000)['E'], 'battery class fault -> T4 at 120 s')
    expect(at(s, t0)['n'] == 'warn:battery-sensor-lost:120' and
           at(s, t0 + 120000)['n'] == 'shutdown:battery-sensor-lost:55', 'notice: battery sensor lost')
    return s


@sc
def psy_error(B):
    s = B()
    s.run(5)
    s.psy['temp'] = 'ERR'
    s.run(6)
    o = s.outs[-1]
    expect('b:psy' in o['F'] and 's:psy-battery:read' in o['F'] and 'c:BATT' in o['F'], 'psy read error -> fault')
    return s


@sc
def psy_stale(B):
    s = B()
    s.psy['volt'] = 4000000
    s.run(71)
    first = s.first(lambda o: 'b:stale' in o['F'])
    expect(first is not None and int(first['t']) == 70000, f'stale battery after > 60 s of identical samples (C-12, K-8): {first and first["t"]}')
    return s


@sc
def psy_not_stale(B):
    s = B()
    s.run(130)
    expect(not any('b:stale' in x['F'] for x in s.outs), 'moving voltage: never stale (negative control)')
    return s


# ------------------------------------------------------------- anomalies
@sc
def hot_anomaly_confirmed(B):
    s = B()
    s.run(2)
    for n in s.sensors:
        if n.startswith(('cpu', 'gpuss', 'nspss')) or n == 'soc-usr':
            s.val[n] = 96000
    s.val['gpuss-0'] = 126000
    o0 = s.step()
    expect('p:gpuss-0' in o0['F'] and not t4s(s), 'hot anomaly pending, not yet T4 (C-7)')
    expect(o0['n'] == 'warn:soc-temperature-high', 'notice: SoC hot outranks the anomaly (K-20)')
    s.step()
    o = s.step()
    expect('t4:anomaly:gpuss-0' in o['E'], 'uncontradicted hot anomaly -> T4 after 2 cycles (§3.3)')
    expect(o['n'] == 'shutdown:soc-temperature-high:55', 'notice: a confirmed anomaly is treated as heat')
    return s


@sc
def hot_anomaly_contradicted(B):
    s = B()
    s.run(2)
    s.val['gpuss-0'] = 126000
    s.run(3)
    expect(not t4s(s) and 's:gpuss-0:contra' in s.outs[-1]['F'], 'contradicted by cool siblings -> sensor fault, no T4')
    expect(s.outs[-3]['n'] == 'warn:sensor-anomaly' and s.outs[-1]['n'] == 'warn:sensor-fault:120',
           'notice: anomaly while pending, then sensor fault with its 120 s countdown')
    s.run(120)
    expect(any('t4:sensor:gpuss-0' in x['E'] for x in s.outs), 'persisting contradicted anomaly -> T4 after 120 s (P9)')
    return s


@sc
def no_sibling_hot(B):
    s = B()
    s.run(2)
    ramp(s, 'surf-virt-usr', 50000, 4000)
    s.val['surf-virt-usr'] = 126000  # also a rise; > 125 °C is checked first
    s.run(3)
    expect(any('t4:anomaly:surf-virt-usr' in x['E'] for x in s.outs), 'no-sibling hot anomaly -> T4 (C-8)')
    return s


@sc
def no_sibling_rise_below_severe(B):
    s = B()
    s.run(2)
    s.val['surf-virt-usr'] = 50000  # +10 °C in 1 s: not faster than 10 °C/s
    o = s.step()
    expect(not o['F'], 'exactly 10 °C/s: no anomaly (negative control)')
    s.val['surf-virt-usr'] = 40000
    s.run(2)
    s.val['surf-virt-usr'] = 51000  # +11 °C/s, below SEVERE 52
    o = s.step()
    expect('s:surf-virt-usr:rise' in o['F'] and not t4s(s), 'no-sibling rise below SEVERE -> P9 fault, not T4 (rev 3)')
    return s


@sc
def no_sibling_rise_at_severe(B):
    s = B()
    s.run(2)
    s.val['surf-virt-usr'] = 42000
    s.step()
    s.val['surf-virt-usr'] = 52500  # +10.5 °C/s, at/above SEVERE 52
    s.run(3)
    expect(any('t4:anomaly:surf-virt-usr' in x['E'] for x in s.outs), 'no-sibling rise at SEVERE -> T4 (§3.3)')
    return s


@sc
def frozen_virtual(B):
    s = B()
    s.val['surf-virt-usr'] = 40000
    for i in range(125):
        s.val['pcb1-usr'] = 35000 + min(i * 20, 1001)
        s.step()
    first = s.first(lambda o: 's:surf-virt-usr:frozen' in o['F'])
    expect(first is not None and int(first['t']) == 120000, f'frozen virtual sensor at 120 s (C-3): {first and first["t"]}')
    return s


@sc
def frozen_virtual_negative(B):
    s = B()
    for i in range(140):
        s.val['pcb1-usr'] = 35000 + min(i * 20, 1000)
        s.step()
    expect(not any('frozen' in f for x in s.outs for f in x['F']), 'inputs moved only 1 °C: not frozen (negative control)')
    return s


# ------------------------------------------------------------- fan (P8, F1-F6)
@sc
def fan_f2_and_p8(B):
    s = B()
    s.rpm_override = 0
    s.run(36)
    expect(not any(x['F'] for x in s.outs), 'no fan fault inside allowance + 20 s')
    o = s.step()
    expect(int(o['t']) == 36000 and 'fan:F2' in o['F'] and o['tier'] == 3 and o['fan'] == '5500',
           'F2 (commanded, 0 rpm > 20 s after the 15 s allowance) -> WARN, fan top (P8)')
    expect(o['n'] == 'warn:fan-failure:120', f'notice: fan failure, 120 s: {o["n"]}')
    s.run(120)
    expect(any('t4:fan' in x['E'] for x in s.outs), 'fan fault held through the new allowance -> T4 after 120 s (K-15)')
    expect(s.first(lambda x: 't4:fan' in x['E'])['n'] == 'shutdown:fan-failure:55', 'notice: fan failure, 55 s')
    return s


@sc
def fan_f1(B):
    s = B()
    s.run(3)
    s.fanv['cur'] = 5
    o = s.step()
    expect('fan:F1' in o['F'], 'cur_state > max_state -> F1 at once')
    return s


@sc
def fan_cur_eq_max_ok(B):
    s = B()
    s.fanv['cur'] = 4
    s.run(10)
    expect(not any(x['F'] for x in s.outs), 'cur_state = max_state is legitimate (negative control, never "= 5")')
    return s


@sc
def fan_f3(B):
    s = B()
    s.rpm_override = 3000
    s.run(61)
    expect(not any(x['F'] for x in s.outs), 'no F3 at 60 s')
    o = s.step()
    expect(int(o['t']) == 61000 and 'fan:F3' in o['F'], 'F3: 700 rpm off for > 45 s after the allowance')
    return s


@sc
def fan_f3_negative(B):
    s = B()
    s.rpm_override = 3200
    s.run(80)
    expect(not any(x['F'] for x in s.outs), '500 rpm off (= max(500, 15 %)): no F3 (negative control)')
    return s


@sc
def fan_f4_max_rpm(B):
    s = B()
    s.fanv['pwm'] = 255  # full PWM, rpm following the 3700 target: far below 85 % of DT max-rpm 8500
    s.run(61)
    expect(not any(x['F'] for x in s.outs), 'no F4 within allowance + 45 s')
    o = s.step()
    expect(int(o['t']) == 61000 and 'fan:F4' in o['F'], 'F4: full PWM, rpm < 85 % of max-rpm for > 45 s (Q4, J-172)')
    return s


@sc
def fan_pwm_254_ok(B):
    s = B()
    s.fanv['pwm'] = 254
    s.run(70)
    expect(not any(x['F'] for x in s.outs), 'pwm below max: no F4 (negative control)')
    return s


@sc
def fan_f5_frozen(B):
    s = B()
    s.rpm_exact = True
    s.rpm_override = 3700
    s.run(46)
    expect(not any(x['F'] for x in s.outs), 'no F5 at 45 s')
    o = s.step()
    expect(int(o['t']) == 46000 and 'fan:F5' in o['F'], 'frozen rpm > 30 s -> F5')
    return s


@sc
def fan_absent(B):
    s = B(fan_absent=True)
    o = s.step()
    expect(o['ready'] == 0 and not any(e.startswith(('ready', 'notready')) for e in o['E']) and o['fan'] == '5500',
           'fan absent on the first tick: the fan item is retried, not READY yet, fan top (K-48)')
    s.run(2)
    o = s.outs[-1]
    expect('notready:fan' in o['E'] and o['ready'] == 0 and 'selftest' in o['F'],
           'absent on three ticks -> notready:fan (§4.3, K-48)')
    s.run(2)
    expect('fan:F6' in s.outs[-1]['F'] and 'fan:F6' not in s.outs[-2]['F'],
           'absent on 5 of the last 20 ticks -> F6 (K-44)')
    s.run(56)
    expect('t4:selftest' in at(s, 60000)['E'], 'failed self-test -> T4 at 60 s')
    return s


@sc
def fan_absent_headless(B):
    s = B(fan_absent=True, flags=['--headless-fan'])
    s.run(5)
    expect(all(x['fan'] == '-' and x['ready'] == 1 and not x['F'] for x in s.outs),
           'declared headless idle stage: fan absent is not a fault (§4.3)')
    return s


@sc
def fan_write_error(B):
    s = B()
    s.run(5)
    s.fan_ro = True
    s.run(5)  # the first write failure is seen on the next tick
    expect(not any(x.startswith('fan:') for o in s.outs for x in o['F']), '4 write failures: not yet a fault (K-44)')
    o = s.step()
    expect('fan:F6' in o['F'] and o['fan'] == '5500', 'fan rpm write failing on 5 of 20 ticks -> F6, fan top')
    return s


@sc
def fan_trip2(B):
    s = B()
    s.run(2)
    s.fanv['cur'] = 5
    s.val['cpu-1-0-0'] = 74999
    s.run(3)
    expect(not t4s(s), 'fan fault below the 2nd fan trip: no T4 (negative control)')
    s.val['cpu-1-0-0'] = 75000
    o = s.step()
    expect('t4:fan-trip2' in o['E'], "fan fault at Meta's 2nd fan trip -> T4 (P8)")
    expect(o['n'] == 'shutdown:fan-failure:55', 'notice: fan failure')
    return s


@sc
def fan_demand_follows_meta(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 75000
    o = s.step()
    expect(o['fan'] == '4500', "Meta's 2nd fan trip 75 °C -> level 2 = 4500 (C-20)")
    s.val['cpu-1-0-0'] = 65001
    o = s.step()
    expect(o['fan'] == '4500', 'held above 75 - 10 (hysteresis)')
    s.val['cpu-1-0-0'] = 64999
    o = s.step()
    expect(o['fan'] == '3700', 'released below 65 °C; level 1 (3700) still active; P1 floor')
    return s


# ------------------------------------------------------------- self-test, caps, ownership
@sc
def selftest_missing_zone(B):
    s = B(missing=['gpuss-3'])
    o = s.step()
    expect('notready:sensor:gpuss-3' in o['E'] and o['fan'] == '5500' and o['cpu'] == '1094400',
           'missing zone -> no READY, fan top, SEVERE caps (thermal-control-design §6.4)')
    s.run(60)
    expect('t4:selftest' in at(s, 60000)['E'], 'self-test failure -> T4 at 60 s (C-16)')
    expect(o['n'] == 'warn:sensor-fault:120' and at(s, 60000)['n'] == 'shutdown:self-test-failed:55',
           'notice: the missing sensor outranks the self-test while warning; the 60 s latch names the self-test')
    return s


@sc
def selftest_trial_override(B):
    s = B(missing=['gpuss-3'], flags=['--trial-override'])
    s.run(70)
    expect(not any('t4:selftest' in x['E'] for x in s.outs), 'trial override: no self-test T4 (negative control)')
    return s


@sc
def caps_write_fail(B):
    s = B()
    s.run(5)
    s.caps_ro = True
    s.run(2)
    expect('t4:cap' in s.outs[-1]['E'], 'cap and cpuinfo_min fallback both fail -> T4 (C-28)')
    expect(s.outs[-1]['n'] == 'shutdown:cap-write-failed:55', 'notice: cap write failed')
    return s


@sc
def caps_fail_at_start(B):
    s = B(caps_ro=True)
    o = s.step()
    expect('notready:caps' in o['E'], 'caps not written at start-up -> no READY (C-29)')
    return s


@sc
def owner_conflict(B):
    s = B()
    s.run(3)
    with open(s.polpath[0], 'w') as f:
        f.write('2054400\n')
    s.step()
    s.close()
    expect('owner-conflict policy0' in s.stderr, 'another writer detected (§2 ownership)')
    expect(open(s.polpath[0]).read().strip() == '1920000', 're-asserted our cap')
    return s


@sc
def hung_read_stops_petting(B):
    s = B()
    s.run(3)
    s.val['cpu-1-0-0'] = 'HANG'
    o = s.step(timeout=3)
    expect(o is None, 'a read that never returns: the cycle never completes, no pet (§5.1; softdog fires)')
    s.ticks.pop()  # the tick that never completed has no output line
    s.proc.kill()
    return s


# ------------------------------------------------------------- devices and flags
@sc
def quest2_headless_idle(B):
    s = B(device='hollywood', fan_absent=True, flags=['--headless-fan'], gpu=False)
    s.run(10)
    o = s.outs[-1]
    expect(o['ready'] == 1 and o['cpu'] == '-' and o['gpu'] == '-' and o['fan'] == '-',
           'Quest 2 headless: READY, no caps/fan (values [O])')
    return s


@sc
def quest2_no_fan_rules(B):
    s = B(device='hollywood', gpu=False)
    o = s.step()
    expect('notready:fan' in o['E'], 'Quest 2 fan rules unknown -> no READY unless headless')
    return s


@sc
def quest2_battery_59(B):
    s = B(device='hollywood', fan_absent=True, flags=['--headless-fan'], gpu=False)
    s.run(2)
    ramp(s, 'batt-virt', 58000)
    expect(s.outs[-1]['tier'] == 3, 'Quest 2 battery SEVERE 58 (T1 straight to T3: no MODERATE)')
    s.val['batt-virt'] = 59000
    o = s.step()
    expect('t4:shutdown:batt-virt' in o['E'], 'Quest 2 battery SHUTDOWN 59 °C')
    return s


@sc
def batt_absent_trial(B):
    s = B(flags=['--trial-override', '--batt-absent'])
    s.adsp = 'offline'
    s.run(5)
    expect(all(x['ready'] == 1 and not x['F'] for x in s.outs), 'battery absent by design (trial only): no battery faults')
    s.psy['cap'] = 3
    s.run(6)
    expect(any('t4:p6' in x['E'] for x in s.outs), 'P6 still acts')
    return s


# ------------------------------------------------------------- gate
def gate_case(B, name, setup, want, device='hollywood', flags=(), marker=False):
    kw = dict(device=device, gpu=False) if device == 'hollywood' else {}
    if device == 'hollywood':
        kw.update(fan_absent=True)
        flags = list(flags) + ['--headless-fan']
    s = B(flags=list(flags), **kw)
    setup(s)
    if marker:
        s.flags_files.add('pstore_marker')
    s.step()
    g = s.gate()
    s.gate_line = g
    expect(g == want, f'{name}: gate {g!r}, want {want!r}')
    return s


@sc
def gate_cool_pass(B):
    return gate_case(B, 'cool', lambda s: None, 'gate=pass reasons=-')


@sc
def gate_hot_battery_refuse(B):
    return gate_case(B, 'battery 55.0', lambda s: s.val.__setitem__('batt-virt', 55000),
                     'gate=refuse reasons=hot:batt-virt')


@sc
def gate_hot_battery_pass(B):
    return gate_case(B, 'battery 54.999', lambda s: s.val.__setitem__('batt-virt', 54999), 'gate=pass reasons=-')


@sc
def gate_marker_refuse(B):
    return gate_case(B, 'marker + 53.0', lambda s: s.val.__setitem__('batt-virt', 53000),
                     'gate=refuse reasons=hot:batt-virt', marker=True)


@sc
def gate_marker_pass(B):
    return gate_case(B, 'marker + 52.999', lambda s: s.val.__setitem__('batt-virt', 52999), 'gate=pass reasons=-',
                     marker=True)


@sc
def gate_p6(B):
    return gate_case(B, '3 %', lambda s: s.psy.__setitem__('cap', 3), 'gate=refuse reasons=p6 warn=lowbatt')


@sc
def gate_lowbatt_warn(B):
    return gate_case(B, '9 %', lambda s: s.psy.__setitem__('cap', 9), 'gate=pass reasons=- warn=lowbatt')


@sc
def gate_j145(B):
    def st(s):
        s.psy['status'] = 'Charging'
        s.psy['temp'] = 300
    return gate_case(B, 'J-145', st, 'gate=refuse reasons=j145', flags=['--j145'])


@sc
def gate_j145_pass(B):
    def st(s):
        s.psy['status'] = 'Charging'
        s.psy['temp'] = 299
    return gate_case(B, 'J-145 29.9', st, 'gate=pass reasons=-', flags=['--j145'])


@sc
def gate_selftest_eureka(B):
    return _gate_selftest(B)


def _gate_selftest(B):
    s = B(missing=['soc-usr'])
    s.step()
    g = s.gate()
    s.gate_line = g
    expect(g.startswith('gate=refuse') and 'selftest' in g and 'fault' in g, f'missing zone -> gate refuses: {g}')
    return s


# ------------------------------------------------------------- review fixes (CORE-SPEC §16)
def p8(s):
    """P8 reached: T4 by the 120 s fan rule or at Meta's 2nd fan trip"""
    return any(('t4:fan' in o['E']) or ('t4:fan-trip2' in o['E']) for o in s.outs)


def oscillate(s, n, period=8, lo=81000, hi=85000, name='cpu-1-0-0'):
    """SoC demand swinging between fan levels 3 and 4 every `period` s (review MAJOR-1)"""
    for i in range(n):
        s.val[name] = hi if (i // period) % 2 else lo
        s.step()


@sc
def review_osc_frozen_tach_reaches_p8(B):
    s = B()
    s.run(5)
    s.rpm_exact = True
    s.rpm_override = 3707
    oscillate(s, 320)
    f = s.first(lambda o: any(x.startswith('fan:') for x in o['F']))
    expect(f is not None and 'fan:F5' in f['F'], 'frozen tach under oscillating demand -> F5 (K-24 a)')
    expect(p8(s), 'and P8 T4 (the review case: no fault for 320 s before)')
    return s


@sc
def review_osc_stall_reaches_p8(B):
    s = B()
    s.run(5)
    s.rpm_override = 0
    oscillate(s, 200)
    expect(any('fan:F2' in o['F'] for o in s.outs) and p8(s),
           'stalled fan under oscillating demand -> F2 -> P8 T4')
    return s


@sc
def review_osc_stuck_low_reaches_p8(B):
    s = B()
    s.run(5)
    s.rpm_override = 3000  # jittered, below every target 5000/5500
    oscillate(s, 260)
    expect(any('fan:F3' in o['F'] for o in s.outs) and p8(s),
           'fan stuck low under oscillating demand -> F3 (low side inside the allowance) -> P8 T4')
    return s


@sc
def review_osc_healthy_no_fault(B):
    s = B()
    s.run(5)
    oscillate(s, 200)
    expect(not any(x.startswith('fan:') for o in s.outs for x in o['F']),
           'a healthy fan following oscillating demand: no fan fault (negative control)')
    return s


@sc
def review_rpm_per_sec_1(B):
    s = B(rps='1')
    expect(s.config['fan']['rpm_per_sec'] == 100, 'hwmon rpm_per_sec 1 rejected, table 100 kept (K-24 d)')
    s.run(3)
    s.rpm_override = 0
    s.val['cpu-1-0-0'] = 85000  # target 5500: allowance capped
    s.run(200)
    expect(p8(s), 'stall with rpm_per_sec=1 still reaches P8 (no 800 s allowance)')
    return s


@sc
def review_fan_zone_missing(B):
    s = B(missing_fanzones=['gpuss-5-fan'], flags=['--trial-override'])
    expect(s.config['fan']['zone_fault'] is True and len(s.config['fan']['rules']) == 28, 'zone fault flagged, rules kept')
    o = s.step()
    expect('notready:fan' in o['E'] and 'fan:F8' in o['F'] and o['fan'] == '5500',
           'missing fan zone -> F8, no READY, fan driven at top (K-25)')
    s.run(5)
    s.rpm_override = 0
    s.run(120)
    expect(any('t4:fan' in x['E'] for x in s.outs), 'fan control and P8 continue (even with the trial override)')
    return s


@sc
def review_fan_trip_mismatch(B):
    s = B(trip_override={('soc-fan', 0): 61000})
    o = s.step()
    expect(s.config['fan']['zone_fault'] is True and 'fan:F8' in o['F'], 'sysfs trip differs from the table -> F8 (TCD §3.3)')
    return s


@sc
def review_psy_overflow(B):
    s = B()
    s.run(3)
    s.psy['temp'] = 42949700
    s.run(6)
    expect('s:psy-battery:read' in s.outs[-1]['F'], 'psy temp 42949700 x 100 outside int32 -> ERR, not a wrap (K-26)')
    return s


@sc
def review_frozen_tsens(B):
    s = B()
    others = [n for n in s.sensors if n.startswith('cpu-0-')]
    for i in range(305):
        for n in others:
            s.val[n] = 40000 + min(i * 20, 4000)
        s.step()
    s.run(125)
    f = s.first(lambda o: 's:cpu-1-0-0:stuck' in o['F'])
    expect(f is not None and int(f['t']) == 300000, f'tsens identical 300 s while SoC rose 4 °C -> stuck (K-33): {f and f["t"]}')
    expect(any('t4:sensor:cpu-1-0-0' in o['E'] for o in s.outs) and not any('t4:classes' in o['E'] for o in s.outs),
           'a stuck tsens escalates like a sensor fault (T4 at + 120 s), never through the two-class rule')
    expect(not any('s:soc-usr:stuck' in o['F'] for o in s.outs), 'soc-usr (ADC) is never judged stuck (K-40)')
    return s


@sc
def review_frozen_tsens_negative(B):
    s = B()
    others = [n for n in s.sensors if n.startswith('cpu-0-')]
    for i in range(320):
        for n in others:
            s.val[n] = 40000 + min(i * 20, 3000)
        s.step()
    expect(not any('stuck' in x for o in s.outs for x in o['F']), 'SoC rose only 3 °C: not stuck (negative control)')
    return s


@sc
def review_weak_soc_usr(B):
    s = B()
    s.run(2)
    for n in s.sensors:
        if n.startswith(('cpu', 'gpuss', 'nspss')) or n == 'ddr':
            s.val[n] = 126000
    s.val['soc-usr'] = 40000  # the only cool sibling reads low by design
    s.run(3)
    expect(any('t4:anomaly:gpuss-0' in o['E'] for o in s.outs), 'soc-usr alone never contradicts tsens (K-29)')
    return s


@sc
def review_common_mode_veto(B):
    s = B()
    s.run(2)
    s.val['gpuss-0'] = 126000
    s.val['cpu-0-0-0'] = 'ERR'  # a tsens fault on the shared controller
    s.run(3)
    expect(any('t4:anomaly:gpuss-0' in o['E'] for o in s.outs), 'a sibling tsens fault vetoes the contradiction (K-29)')
    return s


@sc
def review_cap_clamped_ok(B):
    s = B()
    open(s.root + '/sim/clamp-policy0', 'w').write('1500000')
    s.run(5)
    s.close()
    expect(not any('t4:cap' in o['E'] for o in s.outs) and 'owner-conflict' not in s.stderr,
           'an effective cap below ours (another limit) is accepted, not a failure or a conflict (K-30)')
    return s


@sc
def review_cdev_mismatch(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 75000  # demand level 2, cdev stays 0
    s.run(12)
    n = sum('cdev-mismatch' in o['E'] for o in s.outs)
    expect(n == 1 and all(o['tier'] == 0 for o in s.outs), f'cdev cross-check: one log event, no tier (K-31): {n}')
    return s


@sc
def review_cdev_match_negative(B):
    s = B()
    s.run(2)
    s.val['cpu-1-0-0'] = 75000
    s.fanv['cur'] = 2
    s.run(15)
    expect(not any('cdev-mismatch' in o['E'] for o in s.outs), 'cdev follows our demand: no event')
    return s


@sc
def review_quest2_min_caps(B):
    s = B(device='hollywood', fan_absent=True, flags=['--headless-fan'], gpu=False)
    s.run(3)
    expect(s.outs[-1]['cpu'] == '-', 'Quest 2 T0: no cap written (J-172)')
    ramp(s, 'batt-virt', 58000)
    o = s.outs[-1]
    expect(o['tier'] == 3 and o['cpu'] == 'min', 'Quest 2 T3: CPU min')
    expect(open(s.root + '/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq').read().strip() == '307200',
           'policies from the table: policy7 written (K-30)')
    return s


@sc
def review_sysfs_formats(B):
    s = B()
    s.run(2)
    s.raw['cpu-1-0-0'] = '  41000 \n'
    o = s.step()
    expect(not o['F'], 'leading spaces and a trailing space: numeric (S-1)')
    s.raw['cpu-1-0-0'] = '+42000\n'
    o = s.step()
    expect(not o['F'], 'a sign: numeric')
    s.raw['cpu-1-0-0'] = '4e4\n'
    o = s.step()
    expect('s:cpu-1-0-0:read' in o['F'], '4e4: ERR')
    s.raw['cpu-1-0-0'] = ''
    o = s.step()
    expect('s:cpu-1-0-0:read' in o['F'], 'empty: ERR')
    return s


# ------------------------------------------------------------- delta review (CORE-SPEC §17)
@sc
def review2_flat_slow_zones_no_shutdown(B):
    s = B()
    s.psy['temp'] = 312            # battery flat at 31.2 °C (0.1 °C steps)
    s.psy['volt'] = None           # voltage keeps moving (not stale)
    del s.psy['volt']
    s.val['usb-conn'] = 30000      # USB connector flat
    soc = [n for n in s.sensors if n.startswith(('cpu', 'gpuss', 'nspss')) or n in ('soc-usr', 'ddr')]
    for i in range(460):
        step = min(i // 10, 35) * 100   # the SoC steps 3.5 °C in 0.1 °C steps, then holds
        for n in soc:
            s.val[n] = 40000 + step
        s.val['surf-virt-usr'] = 40000 + step * 288 // 10000  # Meta's skin formula: 0.0288 x soc
        s.step()
    expect(not any(o['F'] for o in s.outs) and not t4s(s) and all(o['tier'] == 0 for o in s.outs),
           'flat battery and USB for 460 s while the SoC steps 3.5 °C: no fault, no shutdown (K-33)')
    return s


@sc
def review2_one_tsens_flat_steady_load(B):
    s = B()
    s.val['cpu-1-0-0'] = 45000  # one core flat, the others step 3.5 °C together
    others = [n for n in s.sensors if n.startswith(('cpu-0', 'gpuss')) ]
    for i in range(330):
        for n in others:
            s.val[n] = 40000 + min(i // 10, 35) * 100
        s.step()
    f = s.first(lambda o: 's:cpu-1-0-0:stuck' in o['F'])
    expect(f is not None and not any('t4:classes' in o['E'] for o in s.outs),
           'a flat tsens under moving SoC is stuck (WARN), never a two-class instant shutdown')
    return s


@sc
def review2_f6_transient_no_trip2(B):
    s = B()
    s.run(3)
    s.val['cpu-1-0-0'] = 76000   # 2nd fan trip active
    s.run(20)
    for i in range(20):  # 4 failed reads in 20 ticks
        s.rpm_override = 'ERR' if i % 5 == 0 else None
        s.step()
    expect(not any(x.startswith('fan:') for o in s.outs for x in o['F']) and not t4s(s),
           'isolated fan read errors (4 of 20) are not a fault (K-44)')
    s.run(20)
    s.rpm_override = 'ERR'
    s.run(5)
    o = s.outs[-1]
    expect('fan:F6' in o['F'] and o['fan'] == '5500' and not t4s(s),
           'a burst of 5 failed reads -> F6 (WARN, fan top), no trip-2 shutdown (5 < 6 of 10, K-41)')
    s.rpm_override = None
    s.run(30)
    expect(not t4s(s), 'a transient F6 at the 2nd fan trip never shuts down (K-34)')
    return s


@sc
def review2_f6_persistent_trip2(B):
    s = B()
    s.run(3)
    s.val['cpu-1-0-0'] = 76000
    s.run(20)
    s.rpm_override = 'ERR'
    t0 = int(s.step()['t'])
    s.run(6)
    o = s.first(lambda x: 't4:fan-trip2' in x['E'])
    expect(o is not None and int(o['t']) == t0 + 5000, f'F6 held 5 s at the 2nd fan trip -> T4 (K-34): {o and o["t"]}')
    return s


@sc
def review2_tach_noise_f9(B):
    import random
    rnd = random.Random(7)
    s = B()
    s.run(3)
    for _ in range(60):
        s.rpm_exact = True
        s.rpm_override = rnd.randint(0, 9000)
        s.step()
    expect(any('fan:F9' in o['F'] for o in s.outs), 'random 0-9000 rpm tach -> plausibility fault F9 (K-35)')
    return s


@sc
def review2_tach_ramp_plausible(B):
    s = B()
    s.run(3)
    s.val['cpu-1-0-0'] = 85000  # target 5500: the harness fan follows within one tick (jitter 7)
    s.run(40)
    expect(not any('fan:F9' in o['F'] for o in s.outs), 'a fan ramping normally is plausible (negative control)')
    return s


@sc
def review2_stuck_lower_of_alternating(B):
    s = B()
    s.run(3)
    s.rpm_override = 3700
    for i in range(100):
        s.val['cpu-1-0-0'] = 85000 if (i // 20) % 2 else 61000  # 3700 <-> 5500 every 20 s
        s.step()
    f = s.first(lambda o: 'fan:F3' in o['F'])
    expect(f is not None and int(f['t']) < 90000, f'fan stuck at the lower target -> F3 before 90 s (K-36): {f and f["t"]}')
    return s


# ------------------------------------------------------------- final delta review (CORE-SPEC §18)
def spike_wobble(s, n):
    s.run(20)
    for v in (74000, 81000, 86000):
        s.val['cpu-1-0-0'] = v
        s.step()
    for i in range(n):
        s.val['cpu-1-0-0'] = 81000 if (i // 6) % 2 else 86000
        s.step()


@sc
def rev5_spike_wobble_healthy_100(B):
    s = B()
    spike_wobble(s, 200)
    expect(not any(x.startswith('fan:') for o in s.outs for x in o['F']) and not t4s(s),
           'healthy fan ramping at 100 rpm/s, 74->81->86 then 81<->86 every 6 s: no fault, no shutdown (K-37)')
    return s


@sc
def rev5_spike_wobble_healthy_50(B):
    s = B(rps='50')
    expect(s.config['fan']['rpm_per_sec'] == 50, 'rpm_per_sec 50 accepted')
    spike_wobble(s, 200)
    expect(not any(x.startswith('fan:') for o in s.outs for x in o['F']) and not t4s(s),
           'the same at 50 rpm/s: no fault, no shutdown')
    return s


@sc
def rev5_spike_wobble_stuck_caught(B):
    s = B()
    s.run(20)
    s.rpm_override = 3700  # stuck at the lowest of the targets (jittered)
    for v in (74000, 81000, 86000):
        s.val['cpu-1-0-0'] = v
        s.step()
    for i in range(150):
        s.val['cpu-1-0-0'] = 81000 if (i // 6) % 2 else 86000
        s.step()
    expect(any('fan:F3' in o['F'] for o in s.outs), 'a fan stuck below the targets under the same wobble: F3 (K-37)')
    return s


def noisy(s, pct, n, seed=3):
    import random
    rnd = random.Random(seed)
    s.run(20)
    s.val['cpu-1-0-0'] = 86000
    for _ in range(n):
        s.rpm_noise = rnd.uniform(-pct, pct)
        s.step()


@sc
def rev5_tach_noise_3pct(B):
    s = B()
    noisy(s, 0.03, 150)
    expect(not any('fan:F9' in o['F'] for o in s.outs) and not t4s(s), '+-3 % tach noise at 86 °C: no F9, no shutdown (K-38)')
    return s


@sc
def rev5_tach_noise_5pct(B):
    s = B()
    noisy(s, 0.05, 150)
    expect(not any('fan:F9' in o['F'] for o in s.outs) and not t4s(s), '+-5 % tach noise at 86 °C: no F9, no shutdown (K-38)')
    return s


@sc
def rev5_dead_fan_flaky_reads(B):
    s = B()
    s.run(20)
    s.val['cpu-1-0-0'] = 86000
    s.run(3)
    t0 = None
    for i in range(20):
        s.rpm_override = None if i % 5 == 4 else 'ERR'
        o = s.step()
        t0 = t0 or int(o['t'])
    f = s.first(lambda o: 't4:fan-trip2' in o['E'])
    expect(f is not None and int(f['t']) <= t0 + 10000, f'reads failing 4 s of 5 at 86 °C -> fan-trip2 within 10 s (K-41): {f and f["t"]}')
    return s


@sc
def rev5_stuck_latched(B):
    s = B()
    others = [n for n in s.sensors if n.startswith('cpu-0-')]
    for i in range(305):
        for n in others:
            s.val[n] = 40000 + min(i * 20, 4000)
        s.step()
    for n in others:
        s.val[n] = 40000  # the reference returns
    s.run(40)
    expect('s:cpu-1-0-0:stuck' in s.outs[-1]['F'], 'stuck stays latched while the value is unchanged (K-40)')
    s.val['cpu-1-0-0'] = 40100
    s.run(32)
    expect('s:cpu-1-0-0:stuck' not in s.outs[-1]['F'], 'and clears 30 s after the value changes')
    return s


def stuck_cpu1(s):
    """every cpu-1 tsens identical for 305 s while cpu-0 rises 4 °C: the cpu1 group (min 1) has no
    healthy sensor, so the SoC class is active through stuck sensors only (K-33)"""
    others = [n for n in s.sensors if n.startswith('cpu-0-')]
    for i in range(305):
        for n in others:
            s.val[n] = 40000 + min(i * 20, 4000)
        s.step()
    o = s.outs[-1]
    expect('c:SOC' in o['F'] and all(f's:{n}:stuck' in o['F'] for n in s.sensors if n.startswith('cpu-1-')),
           'all cpu-1 tsens stuck -> SoC class active through stuck sensors only')


@sc
def rev5_stuck_class_plus_skin(B):
    s = B()
    stuck_cpu1(s)
    s.val['surf-virt-usr'] = 'ERR'
    s.run(5)
    expect('c:SKIN' in s.outs[-1]['F'] and 'c:SOC' in s.outs[-1]['F'],
           'SKIN class active next to the stuck-only SoC class')
    expect(not any('t4:classes' in o['E'] for o in s.outs),
           'a SoC class faulted only by stuck sensors plus a skin fault: no two-class instant shutdown (K-39)')
    # positive control: a non-stuck SoC cause in the same episode (gpu group below its minimum)
    c = B()
    stuck_cpu1(c)
    for n in [x for x in c.sensors if x.startswith('gpuss-')][:7]:
        c.val[n] = 'ERR'
    c.step()
    c.val['surf-virt-usr'] = 'ERR'
    o = c.step()
    same(c)
    expect('t4:classes' in o['E'], 'the same with a non-stuck SoC cause: two classes -> T4 (C-11, K-39 control)')
    return s


@sc
def rev5_fast_alternation_stuck_3700(B):
    """the declared K-43 limit, pinned: demand alternating 3700 <-> 5500 every 6 s (faster than the
    100 rpm/s ramp) with the fan stuck at the lower target is not an F3; the tier floors are the
    backstop: once the SoC reaches LIGHT (89 °C, floor 4500) the alternation ends and the stuck fan
    is caught (F3, then trip 2) about 53 s later"""
    s = B()
    s.run(3)
    s.rpm_override = 3700
    for i in range(150):
        s.val['cpu-1-0-0'] = 85000 if (i // 6) % 2 else 61000  # 3700 <-> 5500 every 6 s
        s.step()
    expect({o['fan'] for o in s.outs[-150:]} == {'3700', '5500'}, 'the target alternates 3700/5500')
    expect(not any(x.startswith('fan:') for o in s.outs for x in o['F']) and not t4s(s),
           'declared limit: a fan stuck at the lower of fast-alternating targets is not an F3 (K-43)')
    s.val['cpu-1-0-0'] = 89000  # sustained full load: LIGHT, floor 4500, demand 5500
    t0 = int(s.step()['t'])
    s.run(70)
    f = s.first(lambda o: 'fan:F3' in o['F'])
    t = s.first(lambda o: 't4:fan-trip2' in o['E'])
    expect(f is not None and t is not None and int(t['t']) - t0 <= 60000,
           f'at LIGHT the stuck fan is caught: F3 and fan-trip2 within 60 s ({t and int(t["t"]) - t0} ms)')
    return s


@sc
def rev5_wobble_stuck_4500(B):
    s = B()
    s.run(20)
    s.rpm_override = 4500
    for v in (74000, 81000, 86000):
        s.val['cpu-1-0-0'] = v
        s.step()
    for i in range(150):
        s.val['cpu-1-0-0'] = 81000 if (i // 6) % 2 else 86000
        s.step()
    expect(any('fan:F3' in o['F'] for o in s.outs), 'stuck at 4500 under 5000/5500 wobble: F3 (K-43)')
    return s


# ------------------------------------------------------------- round-4 review (CORE-SPEC §19)
def same(s):
    """the differential for every simulation of a multi-run scenario (the runner checks the last)"""
    d = s.differential()
    expect(not d, 'C != Python: ' + (d[0][:400] if d else ''))


def alternate(s, n, half, lo=61000, hi=86000, name='cpu-1-0-0'):
    """SoC square wave: demand 3700 (61 °C) / 5500 (86 °C, 2nd fan trip active), `half` s each"""
    for i in range(n):
        s.val[name] = hi if (i // half) % 2 else lo
        s.step()


def fan_faults(s):
    return sorted({x for o in s.outs for x in o['F'] if x.startswith('fan:')})


def healthy(B, n=300, half=5, rps=100, **fan_kw):
    s = B(fan='v27', rps=str(rps)) if rps else B(fan='v66')
    cfg = s.config['fan']
    s.fan_model = Fan(cfg['rpm_per_sec'], cfg['silent_rpm'] or 0, **fan_kw)
    alternate(s, n, half)
    same(s)
    expect(not t4s(s), f'healthy fan ({fan_kw}, rps {rps}, half-period {half} s): no shutdown, got '
           f'{[e for o in t4s(s) for e in o["E"] if e.startswith("t4:")]} faults {fan_faults(s)}')
    return s


@sc
def rev6_blocker_noise10_ramp100(B):
    """the round-4 BLOCKER: 100 rpm/s, +-10 % tach noise, demand 3700/5500 every 5 s"""
    for seed in (1, 3, 7, 9):
        s = healthy(B, tau=0.5, acc=3000, noise=0.10, seed=seed)
        expect(not fan_faults(s), f'seed {seed}: no fan fault at all (K-46, K-47): {fan_faults(s)}')
    return s


@sc
def rev6_blocker_slow_spinup(B):
    """slow spin-up (about 2 s for 1800 rpm) with little noise: 500 and 2000 rpm/s, and v66 (no ramp)"""
    for rps in (500, 2000, 0):
        for half in (3, 6):
            s = healthy(B, n=200, half=half, rps=rps, tau=0.7, acc=900, noise=0.02, seed=half + rps)
            expect(not fan_faults(s), f'rps {rps} half {half}: no fan fault: {fan_faults(s)}')
    return s


@sc
def rev6_read_failures_2pct(B):
    """the round-4 MAJOR: a healthy fan with 2 % failed reads (and writes) never gets a fan fault"""
    s = B()
    s.fan_model = Fan(100, 4000, tau=0.5, acc=3000, noise=0.01, fail=0.02, seed=11)
    s.val['cpu-1-0-0'] = 86000
    s.run(400)
    n = sum(1 for t in s.ticks if isinstance(t['fan'], dict) and t['fan']['rpm'] == 'ERR')
    expect(n >= 4, f'the run has failed reads ({n})')
    expect(not fan_faults(s) and not t4s(s), f'2 % failed reads: no fan fault, no shutdown (K-44): {fan_faults(s)}')
    return s


@sc
def rev6_first_read_fails(B):
    """a failed fan read on the first tick only: READY one tick later, no self-test failure (K-48)"""
    s = B()
    s.rpm_override = 'ERR'
    o = s.step()
    expect(o['ready'] == 0 and 'selftest' not in o['F'], 'first tick: fan item retried')
    s.rpm_override = None
    o = s.step()
    expect('ready' in o['E'] and o['ready'] == 1, 'second tick reads: READY (K-48)')
    s.run(70)
    expect(not t4s(s) and not fan_faults(s), 'no self-test shutdown, no fan fault')
    return s


@sc
def rev6_dead_fan_flaky_reads(B):
    """MINOR (b): a dead fan whose reads fail now and then still gets F2 and trip 2 at once"""
    s = B()
    s.val['cpu-1-0-0'] = 86000
    s.rpm_override = 0
    for i in range(60):
        s.rpm_override = 'ERR' if i % 7 == 3 else 0
        s.step()
    t = s.first(lambda o: 't4:fan-trip2' in o['E'])
    expect(t is not None and int(t['t']) <= 36000,
           f'dead from the start, a read failing every 7 s: F2 > 20 s after the 15 s grace -> trip 2 at 36 s '
           f'(K-45 holds, no reset): {t and t["t"]}')
    expect(any('fan:F2' in o['F'] for o in s.outs), 'reported as F2')
    return s


@sc
def rev6_f5_after_pwm_error(B):
    """MINOR (a): rpm reads but pwm fails on one tick; F5 compares with that rpm (K-45), C = Python"""
    s = B()
    s.run(20)
    s.rpm_exact = True
    s.rpm_override = 3707
    s.run(3)
    s.fanv['pwm'] = 'ERR'
    s.step()
    s.fanv['pwm'] = 120
    s.run(40)
    f = s.first(lambda o: 'fan:F5' in o['F'])
    expect(f is not None, 'a frozen tach across a pwm read failure -> F5')
    return s


@sc
def rev6_unreadable_fan_trip2(B):
    """persistent read failure still escalates: F6 on the 5th failed tick, trip 2 on the 6th (K-41, K-44)"""
    s = B()
    s.run(3)
    s.val['cpu-1-0-0'] = 86000
    s.run(20)
    s.rpm_override = 'ERR'
    t0 = int(s.step()['t'])
    s.run(6)
    f = s.first(lambda o: 'fan:F6' in o['F'])
    t = s.first(lambda o: 't4:fan-trip2' in o['E'])
    expect(f is not None and int(f['t']) == t0 + 4000, f'F6 on the 5th failed tick: {f and f["t"]}')
    expect(t is not None and int(t['t']) == t0 + 5000, f'trip 2 on the 6th: {t and t["t"]}')
    return s


@sc
def rev6_unreadable_fan_p8(B):
    """an unreadable fan below the 2nd fan trip: F6, then P8 120 s later"""
    s = B()
    s.run(20)
    s.rpm_override = 'ERR'
    t0 = int(s.step()['t'])
    s.run(130)
    t = s.first(lambda o: 't4:fan' in o['E'])
    expect(t is not None and int(t['t']) == t0 + 4000 + 120000, f'F6 at +4 s, t4:fan at +124 s: {t and t["t"]}')
    return s


@sc
def rev6_noisy_stuck_limit_8s(B):
    """round-5 MINOR, the declared limit with tach noise (K-43, K-47): a fan stuck at 4000 rpm with
    +-5 % noise under demand alternating 3700 <-> 5500 every 8 s is not caught by the fan check (a
    noisy high reading can end an early F3 episode, so the limit reaches about 8-10 s half-periods
    instead of 7 s); the tier floors are the backstop: at LIGHT (89 °C, floor 4500) the alternation
    ends and the fan is caught (F3, then trip 2) within 60 s"""
    s = B()
    s.fan_model = Fan(100, 4000, noise=0.05, seed=1, stuck=4000)
    alternate(s, 150, 8)
    expect(not fan_faults(s) and not t4s(s),
           f'declared limit: stuck at 4000 with 5 % noise, 8 s alternation: not a fan fault ({fan_faults(s)})')
    s.val['cpu-1-0-0'] = 89000
    t0 = int(s.step()['t'])
    s.run(70)
    t = s.first(lambda o: 't4:fan-trip2' in o['E'])
    expect(any('fan:F3' in o['F'] for o in s.outs) and t is not None and int(t['t']) - t0 <= 60000,
           f'at LIGHT the stuck fan is caught: F3 and fan-trip2 within 60 s ({t and int(t["t"]) - t0} ms)')
    return s


# ------------------------------------------------------------- runner
@sc
def p2_adsp_name_v27(B):
    """part 2 (E-32): the v2.7 ADSP rproc is named 3000000.remoteproc-adsp (FS-A-006 raw);
    part 1 looked for "adsp" only and would have raised b:adsp -> T4 at 120 s on a device"""
    s = B()
    s.run(5)
    expect(all('b:adsp' not in o['F'] for o in s.outs) and s.outs[0]['ready'] == 1, 'v2.7 name found')
    s.adsp = 'offline'
    s.run(2)
    expect('b:adsp' in s.outs[-1]['F'], 'and its state is read (offline -> b:adsp)')
    return s


@sc
def p2_adsp_name_legacy(B):
    s = B(adsp_name='adsp')
    s.run(3)
    expect(all('b:adsp' not in o['F'] for o in s.outs), 'a plain "adsp" name still matches')
    return s


@sc
def p2_adsp_name_other_rproc(B):
    s = B(adsp_name='2000000.remoteproc-cdsp')
    s.run(3)
    expect('b:adsp' in s.outs[0]['F'], 'another remote processor is never taken for the ADSP (negative control)')
    return s


@sc
def p2_adsp_name_no_dot(B):
    s = B(adsp_name='xremoteproc-adsp')
    s.run(3)
    expect('b:adsp' in s.outs[0]['F'], 'the suffix must follow a "." (negative control)')
    return s


@sc
def p2_pmic_levels(B):
    """CORE-SPEC §20 (P7): a PMIC die at 95 C is SEVERE (warn:pmic-hot), at 115 C SHUTDOWN"""
    s = B()
    s.run(3)
    s.val['pm8550b_die_temp'] = 94999
    o = s.run(3)
    expect(o['tier'] == 0 and o['n'] == '-', '94.999 C: nothing (negative control)')
    s.val['pm8550b_die_temp'] = 95000
    o = s.step()
    expect(o['tier'] == 3 and o['n'] == 'warn:pmic-hot', f'95.000 C: WARN pmic-hot (K-51/K-54): {o["n"]}')
    s.val['pm8550b_die_temp'] = 115000
    o = s.step()
    expect(o['tier'] == 4 and 't4:shutdown:pm8550b_die_temp' in o['E'] and o['n'] == 'shutdown:pmic-hot:55',
           f'115.000 C: T4, shutdown:pmic-hot:55: {o["E"]} {o["n"]}')
    s.val['pm8550b_die_temp'] = 121000
    s.run(3)
    expect(not any(e.startswith('t5:p12') for x in s.outs for e in x['E']), 'no P12 fast T5 from a PMIC die (K-55)')
    return s


@sc
def p2_pmic_priority(B):
    s = B()
    s.run(2)
    s.val['pmk8550_die_temp'] = 96000
    s.val['cpu-1-0-0'] = 95500
    o = s.step()
    expect(o['n'] == 'warn:soc-temperature-high', f'SoC SEVERE outranks PMIC SEVERE: {o["n"]}')
    s.val['cpu-1-0-0'] = 50000
    s.run(40)  # past the SoC hysteresis and the 30 s dwell (C-10)
    o = s.step()
    expect(o['n'] == 'warn:pmic-hot', f'pmic-hot once only the PMIC is SEVERE: {o["n"]}')
    return s


@sc
def p2_pmic_missing_notready(B):
    s = B(missing=['pm8550vs_d_die_temp'])
    o = s.step()
    expect(o['ready'] == 0 and 'notready:sensor:pm8550vs_d_die_temp' in o['E'],
           f'a missing PMIC die channel: never READY (R50, K-53): {o["E"]}')
    return s


@sc
def p2_pmic_soc_first(B):
    s = B(missing=['pm8550b_die_temp', 'cpu-0-0-0'])
    o = s.step()
    expect('notready:sensor:cpu-0-0-0' in o['E'], f'self-test order: SOC before PMIC (K-53): {o["E"]}')
    return s


@sc
def p2_pmic_read_error_class(B):
    s = B()
    s.run(3)
    s.val['pmxr2230_die_temp'] = 'ERR'
    o = s.step()
    expect('s:pmxr2230_die_temp:read' in o['F'] and 'c:PMIC' in o['F'] and o['tier'] == 3
           and o['n'].startswith('warn:sensor-fault:'), f'a PMIC read error: sensor + class fault, WARN: {o["F"]} {o["n"]}')
    s.run(121)
    expect(any('t4:' in e for x in s.outs for e in x['E']), 'and T4 after 120 s')
    return s


@sc
def p2_pmic_gate(B):
    s = B()
    s.val['pm8550ve_die_temp'] = 90000  # SEVERE 95 - hyst 5 = 90: refused
    s.step()
    g = s.gate()
    s.gate_line = g
    expect('gate=refuse' in g and 'hot:pm8550ve_die_temp' in g, f'gate refuses a PMIC die at SEVERE - hyst (C-42): {g}')
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True)
    ap.add_argument('--only')
    ap.add_argument('--out')
    ap.add_argument('--no-diff', action='store_true')
    a = ap.parse_args()
    res, npass, ndiff = [], 0, 0
    for fn in SC:
        if a.only and a.only not in fn.__name__:
            continue
        sims = []

        def B(**kw):
            s = Sim(a.bin, **kw)
            sims.append(s)
            return s
        status, detail, dstat = 'PASS', '', 'skip'
        try:
            s = fn(B)
            for x in sims:
                if x.proc.poll() is None:
                    x.close()
            if not a.no_diff and s is not None:
                if hasattr(s, 'gate_line'):
                    d = s.differential(gate=True)
                    # the gate differential compares the single gate line
                    d = [] if not d or (len(d) == 1 and d[0].startswith('line count')) else d
                    import subprocess as sp
                    import json as js
                    cfg = os.path.join(s.dir, 'config.json')
                    tk = os.path.join(s.dir, 'ticks.jsonl')
                    r = sp.run([sys.executable, '-I', os.path.join(os.path.dirname(__file__), '..', 'ref', 'core_ref.py'),
                                '--config', cfg, '--ticks', tk, '--gate'], capture_output=True, text=True)
                    py = r.stdout.strip()
                    d = [] if py == s.gate_line else [f'gate C: {s.gate_line}\n  gate PY: {py} {r.stderr[-300:]}']
                else:
                    d = s.differential()
                dstat = 'SAME' if not d else 'DIFF'
                if d:
                    ndiff += 1
                    detail = '\n'.join(d[:3])
        except Fail as e:
            status, detail = 'FAIL', str(e)
        except Exception:
            status, detail = 'ERROR', traceback.format_exc()[-600:]
        finally:
            for x in sims:
                if x.proc.poll() is None:
                    x.proc.kill()
        if status == 'PASS':
            npass += 1
        line = f'{status:5s} {dstat:4s} {fn.__name__}'
        print(line + (('\n    ' + detail.replace('\n', '\n    ')) if detail else ''), flush=True)
        res.append(line)
    tot = len(res)
    summ = f'scenarios: {npass}/{tot} pass; differential vs core_ref.py: {tot - ndiff}/{tot} identical' + \
        (' (not run)' if a.no_diff else '')
    print(summ)
    if a.out:
        with open(a.out, 'w', newline='\n') as f:
            f.write('# fs-thermald scenarios (tools/sim/scenarios.py): status, differential, name\n')
            f.write('\n'.join(res) + '\n' + summ + '\n')
    sys.exit(0 if npass == tot and ndiff == 0 else 1)


if __name__ == '__main__':
    main()
