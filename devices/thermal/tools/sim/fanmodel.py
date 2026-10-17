#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A simulated Quest 3 fan for the scenarios and the sweep (CORE-SPEC §19).

The driver's setpoint follows the target written by fs-thermald: it ramps
at `rps` rpm/s, or jumps when `rps` is 0 (v66) or when both the setpoint and
the target are at or below `silent` (the v2.7 driver's jump). The rotor
follows the setpoint with a first-order lag `tau` (s), its acceleration
limited to `acc` rpm/s. The tach reads the rotor speed with a uniform
relative noise of +-`noise` and fails (`ERR`) with probability `fail` per
read. Faults: `dead` (rotor stopped, tach reads 0), `stuck` (rotor held at
that speed, tach reads it with the same noise), `frozen` (the tach repeats
that value exactly). Deterministic for a given seed.
"""
import random


class Fan:
    def __init__(self, rps, silent, tau=0.5, acc=3000, noise=0.0, fail=0.0, seed=0,
                 dead=False, stuck=None, frozen=None, sub=20):
        self.rps, self.silent, self.tau, self.acc = rps, silent, tau, acc
        self.noise, self.fail = noise, fail
        self.dead, self.stuck, self.frozen = dead, stuck, frozen
        self.rnd = random.Random(seed)
        self.sp = 0.0      # driver setpoint
        self.v = 0.0       # rotor speed
        self.sub = sub

    def advance(self, target, dt=1.0):
        """the interval since the previous read, with `target` in force"""
        h = dt / self.sub
        for _ in range(self.sub):
            if self.rps <= 0 or (self.sp <= self.silent and target <= self.silent):
                self.sp = float(target)
            elif self.sp < target:
                self.sp = min(float(target), self.sp + self.rps * h)
            else:
                self.sp = max(float(target), self.sp - self.rps * h)
            dv = (self.sp - self.v) * h / self.tau if self.tau > 0 else self.sp - self.v
            lim = self.acc * h
            self.v += max(-lim, min(lim, dv))
        if self.dead:
            self.v = 0.0
        elif self.stuck is not None:
            self.v = float(self.stuck)

    def read(self):
        """one tach read: an int or 'ERR' (the random draws are made in a fixed order)"""
        u = self.rnd.uniform(-self.noise, self.noise)
        e = self.rnd.random() < self.fail
        if e:
            return 'ERR'
        if self.frozen is not None:
            return int(self.frozen)
        if self.v <= 0:
            return 0
        return int(self.v * (1 + u))
