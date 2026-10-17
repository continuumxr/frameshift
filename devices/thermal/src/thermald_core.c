// SPDX-License-Identifier: Apache-2.0
// fs-thermald pure decision core: CORE-SPEC.md (rule ids C-n, K-n).
// No I/O, no allocation, integer arithmetic only. The Python reference
// tools/ref/core_ref.py implements the same spec independently.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "thermald.h"

#define NONE (-1)
enum { H_OK = 0, H_READ, H_LOW, H_FROZEN, H_HOT, H_RISE, H_CONTRA_UNUSED, H_STUCK };
static const char *const freason_name[] = {"", "read", "low", "frozen", "hot", "rise", "contra", "stuck"};
#define FR_CONTRA 6
#define FR_RISE 5

static void addtok(char (*list)[48], int *n, const char *s)
{
    int i;
    for (i = 0; i < *n; i++)
        if (!strcmp(list[i], s))
            return;
    if (*n < MAXTOK)
        snprintf(list[(*n)++], 48, "%s", s);
}
static void adde(struct tick_out *o, const char *s)
{
    int i;
    for (i = 0; i < o->ne; i++)
        if (!strcmp(o->e[i], s))
            return;
    if (o->ne < MAXTOK)
        snprintf(o->e[o->ne++], 64, "%s", s);
}
static void adda(struct tick_out *o, const char *s)
{
    if (o->na < 16)
        snprintf(o->a[o->na++], 16, "%s", s);
}

static int counted_cls(enum cls c)
{
    return c == CL_SOC || c == CL_SKIN || c == CL_BATT || c == CL_USB || c == CL_BOARD || c == CL_PMIC; /* K-53 */
}

void core_init(struct core *k, const struct conf *c)
{
    int i;
    memset(k, 0, sizeof *k);
    k->c = c;
    k->first = 1;
    for (i = 0; i < c->ns; i++) {
        k->s[i].fault_since = NONE;
        k->s[i].ok_since = NONE;
        k->s[i].down_since = NONE;
    }
    for (i = 0; i < CL_N; i++) {
        k->cl[i].since = NONE;
        k->cl[i].ok_since = NONE;
    }
    k->stale_start = NONE;
    k->last_j145 = NONE;
    k->f2 = k->f3 = k->f4 = k->f5 = NONE;
    k->fsince = k->fok_since = NONE;
    k->cdev_start = NONE;
    k->f6_since = NONE;
    k->last_status = ST_UNKNOWN;
}

static int sev(const struct sens *s) { return s->th[3]; }

/* C-10 */
static void level_update(const struct sens *S, struct sstate *st, int64_t now)
{
    int k, up = 0;
    int any = 0;
    for (k = 1; k <= 6; k++)
        if (S->th[k] != UNSET)
            any = 1;
    if (!any)
        return;
    if (!st->usable) {
        st->down_since = NONE;
        return;
    }
    for (k = 1; k <= 6; k++)
        if (S->th[k] != UNSET && st->v >= S->th[k])
            up = k;
    if (up > st->L) {
        st->L = up;
        st->down_since = NONE;
        return;
    }
    if (st->L > 0) {
        int32_t hy = S->hy[st->L] == UNSET ? 0 : S->hy[st->L];
        if (st->v < S->th[st->L] - hy) {
            if (st->down_since == NONE)
                st->down_since = now;
            if (now - st->down_since >= 30000) {
                int nl = 0;
                for (k = 1; k < st->L; k++) {
                    int32_t h2 = S->hy[k] == UNSET ? 0 : S->hy[k];
                    if (S->th[k] != UNSET && st->v >= S->th[k] - h2)
                        nl = k;
                }
                st->L = nl;
                if (nl > 0) {
                    int32_t h3 = S->hy[nl] == UNSET ? 0 : S->hy[nl];
                    st->down_since = st->v < S->th[nl] - h3 ? now : NONE;
                } else
                    st->down_since = NONE;
            }
        } else
            st->down_since = NONE;
    }
}

static int has_indep_sibling(const struct conf *c, int i)
{
    int j;
    if (!c->s[i].indep)
        return 0;
    for (j = 0; j < c->ns; j++)
        if (j != i && c->s[j].indep && c->s[j].cls == c->s[i].cls && c->s[j].kind != K_AUX)
            return 1;
    return 0;
}

/* C-7 contradiction (K-6) */
static int contradicted(const struct core *k, int i)
{
    const struct conf *c = k->c;
    int j, below = 0;
    for (j = 0; j < c->ns; j++) {
        const struct sens *S = &c->s[j];
        if (j == i || !S->indep || S->cls != c->s[i].cls || S->kind == K_AUX)
            continue;
        /* K-29: a common-mode sibling fault vetoes the contradiction */
        if (k->s[j].h == H_READ || k->s[j].h == H_LOW || k->s[j].h == H_FROZEN || k->s[j].h == H_STUCK ||
            k->s[j].fault)
            return 0;
        if (k->s[j].h != H_OK || sev(S) == UNSET)
            continue;
        if (k->s[j].v >= sev(S))
            return 0;
        if (!S->weak) /* K-29: soc-usr reads low; never the contradiction */
            below = 1;
    }
    return below;
}

static void latch4(struct core *k, struct tick_out *o, const char *reason, int64_t now)
{
    char b[64];
    if (k->t4 && k->t4_at != now)
        return; /* already latched earlier: reasons only on the latch tick (C-19) */
    if (!k->t4) {
        k->t4 = 1;
        k->t4_at = now;
    }
    snprintf(b, sizeof b, "t4:%s", reason);
    adde(o, b);
}

/* ---------------- user-visible notice (CORE-SPEC §15, K-18 .. K-22) ---------------- */
enum {
    N_BATT_HOT, N_SKIN_HOT, N_SOC_HOT, N_PMIC_HOT, N_USB_HOT, N_FAN, N_BATT_LOST, N_SENSOR, N_ANOMALY, N_BATT_EMPTY,
    N_CAP, N_SELFTEST, N_BATT_LOW, N_CHARGING, N_REQUESTED, N_NONE
};
static const char *const nname[] = {"battery-overheating", "skin-temperature-high", "soc-temperature-high",
                                    "pmic-hot", "usb-connector-hot", "fan-failure", "battery-sensor-lost", "sensor-fault",
                                    "sensor-anomaly", "battery-empty", "cap-write-failed", "self-test-failed",
                                    "battery-low", "charging-too-warm", "shutdown-requested"};

static int cls_hot(int c) /* K-23: any other class maps to SoC; K-54: PMIC -> pmic-hot */
{
    return c == CL_BATT ? N_BATT_HOT : c == CL_SKIN ? N_SKIN_HOT : c == CL_USB ? N_USB_HOT : c == CL_PMIC ? N_PMIC_HOT : N_SOC_HOT;
}

static int sens_cls(const struct conf *c, const char *name)
{
    int i;
    for (i = 0; i < c->ns; i++)
        if (!strcmp(c->s[i].name, name))
            return c->s[i].cls;
    return -1;
}

/* K-19: one T4 latch reason -> notice reason */
static int map_t4(const struct conf *c, const char *r)
{
    if (!strncmp(r, "shutdown:", 9) || !strncmp(r, "anomaly:", 8)) {
        int cl = sens_cls(c, strchr(r, ':') + 1);
        return cl < 0 ? N_NONE : cls_hot(cl);
    }
    if (!strncmp(r, "sensor:", 7))
        return sens_cls(c, r + 7) == CL_BATT ? N_BATT_LOST : N_SENSOR;
    if (!strcmp(r, "class:BATT"))
        return N_BATT_LOST;
    if (!strncmp(r, "class:", 6) || !strcmp(r, "classes"))
        return N_SENSOR;
    if (!strcmp(r, "p5"))
        return N_USB_HOT;
    if (!strcmp(r, "p6"))
        return N_BATT_EMPTY;
    if (!strcmp(r, "fan") || !strcmp(r, "fan-trip2"))
        return N_FAN;
    if (!strcmp(r, "cap"))
        return N_CAP;
    if (!strcmp(r, "selftest"))
        return N_SELFTEST;
    return N_NONE;
}

static int64_t secs_up(int64_t ms) { return ms <= 0 ? 0 : (ms + 999) / 1000; }

/* computed from the state after step 16; it never changes an action (K-22) */
static void notice(struct core *k, struct tick_out *o, int64_t now, int fan_on)
{
    const struct conf *c = k->c;
    int i, best = N_NONE;
    int64_t until = NONE;
    if (k->t4 && k->t4_at == now) { /* K-19 */
        for (i = 0; i < o->ne; i++)
            if (!strncmp(o->e[i], "t4:", 3)) {
                int m = map_t4(c, o->e[i] + 3);
                if (m < best)
                    best = m;
            }
        k->nsev = 2;
        k->nreason = best;
    } else if (k->nsev < 2 && !c->stage && k->have_tl0) {
        k->nsev = 2; /* K-18: detected external shutdown */
        k->nreason = N_REQUESTED;
    }
    if (k->nsev == 2) {
        int64_t a2 = c->stage ? k->tl0 + 2000 : k->tl0 + 55000;
        int64_t left;
        if (!c->stage && k->t5 && k->tf != NONE && k->tf + 10000 < a2)
            a2 = k->tf + 10000;
        left = (c->stage ? k->sent_kill : k->sent_a2) ? 0 : secs_up(a2 - now);
        snprintf(o->notice, sizeof o->notice, "shutdown:%s:%lld", k->nreason < N_NONE ? nname[k->nreason] : "unknown",
                 (long long)left);
        return;
    }
    if (k->tier < 3) {
        snprintf(o->notice, sizeof o->notice, "-");
        return;
    }
    /* K-20 */
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        if (S->kind == K_JSON || S->kind == K_AUX)
            continue;
        if (k->s[i].L >= 3) {
            int m = cls_hot(S->cls);
            if (m < best)
                best = m;
        }
    }
    if (fan_on && k->ffault && best > N_FAN)
        best = N_FAN;
    {
        int blost = k->cl[CL_BATT].active, sfault = 0;
        for (i = 0; i < c->ns; i++)
            if (k->s[i].fault && c->s[i].kind != K_JSON && c->s[i].kind != K_AUX) {
                if (c->s[i].cls == CL_BATT)
                    blost = 1;
                else
                    sfault = 1;
            }
        for (i = 0; i < CL_N; i++)
            if (i != CL_BATT && k->cl[i].active)
                sfault = 1;
        if (blost && best > N_BATT_LOST)
            best = N_BATT_LOST;
        if (sfault && best > N_SENSOR)
            best = N_SENSOR;
    }
    for (i = 0; i < c->ns; i++)
        if (k->s[i].pending && best > N_ANOMALY)
            best = N_ANOMALY;
    if (k->selftest_fail && best > N_SELFTEST)
        best = N_SELFTEST;
    if (k->lowbatt && best > N_BATT_LOW)
        best = N_BATT_LOW;
    if (k->j145c && best > N_CHARGING)
        best = N_CHARGING;
    if (best == N_NONE) { /* the WARN hold of C-17: repeat the last reason, no seconds (K-23) */
        snprintf(o->notice, sizeof o->notice, "warn:%s", nname[k->nsev == 1 ? k->nreason : N_SENSOR]);
        return;
    }
    k->nsev = 1;
    k->nreason = best;
    /* K-21: the running timer of the chosen reason */
    if (best == N_FAN)
        until = k->fsince + 120000;
    else if (best == N_BATT_LOST || best == N_SENSOR) {
        int want_batt = best == N_BATT_LOST;
        for (i = 0; i < c->ns; i++)
            if (k->s[i].fault && c->s[i].kind != K_JSON && c->s[i].kind != K_AUX &&
                (c->s[i].cls == CL_BATT) == want_batt && (until == NONE || k->s[i].fault_since + 120000 < until))
                until = k->s[i].fault_since + 120000;
        for (i = 0; i < CL_N; i++)
            if (k->cl[i].active && (i == CL_BATT) == want_batt && (until == NONE || k->cl[i].since + 120000 < until))
                until = k->cl[i].since + 120000;
    } else if (best == N_SELFTEST && !c->trial_override)
        until = k->t0 + 60000;
    if (until == NONE)
        snprintf(o->notice, sizeof o->notice, "warn:%s", nname[best]);
    else
        snprintf(o->notice, sizeof o->notice, "warn:%s:%lld", nname[best], (long long)secs_up(until - now));
}

static int is_sample(const struct core *k, int64_t now)
{
    return k->first || now - k->last_sample >= k->c->psy_period_ms;
}

void core_tick(struct core *k, const struct tick_in *in, struct tick_out *o)
{
    const struct conf *c = k->c;
    int64_t now = in->t;
    int i, j, sample;
    int raw_h[MAXS];
    int numeric[MAXS];
    int32_t val[MAXS];
    char b[96];
    int fan_on = c->has_fan && !(c->headless_fan && in->fan_absent); /* C-26: headless excuses absence only */
    int raised[MAXS];
    int fan_cond = 0, fcode_now = 0, e6 = 0;

    memset(o, 0, sizeof *o);
    if (k->first)
        k->t0 = now;

    /* 1. psy sample (C-30) */
    sample = is_sample(k, now);
    if (sample)
        k->last_sample = now;
    if (in->psy_temp.st == RD_NUM && ((int64_t)in->psy_temp.v * 100 > INT32_MAX ||
                                      (int64_t)in->psy_temp.v * 100 <= INT32_MIN)) {
        static struct tick_in cp; /* K-26: out of int32 after scaling = an ERR field everywhere */
        cp = *in;
        cp.psy_temp.st = RD_ERR;
        in = &cp;
    }

    /* 2. health: pass A (C-1, C-2) */
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        struct rd r;
        if (S->kind == K_JSON)
            continue;
        if (S->kind == K_PSY) {
            if (!sample)
                continue;
            r = in->psy_temp;
            if (r.st == RD_NUM) { /* K-26: exact, out of int32 -> ERR */
                int64_t x = (int64_t)r.v * 100;
                if (x > INT32_MAX || x <= INT32_MIN)
                    r.st = RD_ERR;
                else
                    r.v = (int32_t)x;
            }
        } else
            r = in->s[i];
        numeric[i] = r.st == RD_NUM;
        val[i] = r.v;
        if (r.st != RD_NUM)
            raw_h[i] = H_READ;
        else if (r.v < -20000)
            raw_h[i] = H_LOW;
        else
            raw_h[i] = H_OK;
    }
    /* pass B (C-3, K-3, K-4) and pass C (C-4 .. C-6) */
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        struct sstate *st = &k->s[i];
        int h;
        if (S->kind == K_JSON || (S->kind == K_PSY && !sample))
            continue;
        h = raw_h[i];
        if (h == H_OK && S->nvin && S->kind != K_AUX) {
            int32_t v = val[i];
            int frozen = 0;
            if (st->have_fz && v == st->fz) {
                for (j = 0; j < S->nvin; j++) {
                    int x = S->vin[j];
                    int us = raw_h[x] == H_OK;
                    if (us && c->s[x].kind != K_AUX) {
                        /* non-AUX input: C-4/C-5 must not fire either */
                        if (val[x] > 125000)
                            us = 0;
                        else if (c->s[x].slow && k->s[x].have_prev &&
                                 ((int64_t)val[x] - k->s[x].pv) * 1000 > (int64_t)10000 * (now - k->s[x].pt))
                            us = 0;
                    }
                    if (!us)
                        continue;
                    if (!st->vhave[j]) {
                        st->vhave[j] = 1;
                        st->vmin[j] = st->vmax[j] = val[x];
                    } else {
                        if (val[x] < st->vmin[j])
                            st->vmin[j] = val[x];
                        if (val[x] > st->vmax[j])
                            st->vmax[j] = val[x];
                    }
                }
                if (now - st->fz_since >= 120000)
                    for (j = 0; j < S->nvin; j++)
                        if (st->vhave[j] && st->vmax[j] - st->vmin[j] > 1000)
                            frozen = 1;
            } else {
                st->have_fz = 1;
                st->fz = v;
                st->fz_since = now;
                for (j = 0; j < S->nvin; j++) {
                    int x = S->vin[j];
                    int us = raw_h[x] == H_OK;
                    if (us && c->s[x].kind != K_AUX) {
                        if (val[x] > 125000)
                            us = 0;
                        else if (c->s[x].slow && k->s[x].have_prev &&
                                 ((int64_t)val[x] - k->s[x].pv) * 1000 > (int64_t)10000 * (now - k->s[x].pt))
                            us = 0;
                    }
                    st->vhave[j] = us;
                    if (us)
                        st->vmin[j] = st->vmax[j] = val[x];
                }
            }
            if (frozen)
                h = H_FROZEN;
        }
        if (numeric[i] && !S->nvin && S->kind == K_ZONE && S->cls == CL_SOC && !S->weak) { /* K-33/K-40: tsens */
            int refh = 0;
            int64_t ref = 0;
            for (j = 0; j < c->ns; j++)
                if (j != i && c->s[j].cls == CL_SOC && c->s[j].kind == K_ZONE && raw_h[j] == H_OK &&
                    val[j] <= 125000 && (!refh || val[j] > ref)) {
                    ref = val[j];
                    refh = 1;
                }
            if (st->k27 && val[i] == st->k27v) {
                if (h == H_OK && (st->k27stuck || (now - st->k27since >= 300000 && refh && st->k27refh &&
                                                    (ref - st->k27ref > 3000 || st->k27ref - ref > 3000)))) {
                    h = H_STUCK;
                    st->k27stuck = 1; /* K-40: latched until the value changes */
                }
            } else {
                st->k27stuck = 0;
                st->k27 = 1;
                st->k27v = val[i];
                st->k27since = now;
                st->k27refh = refh;
                st->k27ref = ref;
            }
        }
        if (h == H_OK && S->kind != K_AUX) {
            int32_t v = val[i];
            if (v > 125000)
                h = H_HOT;
            else if (S->slow && st->have_prev && ((int64_t)v - st->pv) * 1000 > (int64_t)10000 * (now - st->pt))
                h = H_RISE;
        }
        st->h = h;
    }
    /* trackers (K-5) and usable values */
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        struct sstate *st = &k->s[i];
        if (S->kind == K_JSON || (S->kind == K_PSY && !sample))
            continue;
        if (numeric[i]) {
            st->have_prev = 1;
            st->pv = val[i];
            st->pt = now;
        }
        st->usable = st->h == H_OK;
        st->v = val[i];
    }

    /* 3. anomalies (C-7, C-8) */
    memset(raised, 0, sizeof raised);
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        struct sstate *st = &k->s[i];
        if (S->kind == K_JSON || S->kind == K_AUX || (S->kind == K_PSY && !sample))
            continue;
        if (!has_indep_sibling(c, i) && st->h == H_RISE && (sev(S) == UNSET || st->v < sev(S))) {
            if (!st->fault) { /* C-8: immediate fault rise (also while pending) */
                st->fault = 1;
                st->freason = FR_RISE;
                st->fault_since = now;
                raised[i] = 1;
            }
            st->ok_since = NONE;
        } else if (!st->pending && !st->fault && (st->h == H_HOT || st->h == H_RISE)) {
            {
                st->pending = 1;
                st->n = 0;
                st->contra = 0;
                st->akind = st->h;
            }
        }
        if (st->pending) {
            if (has_indep_sibling(c, i) && contradicted(k, i))
                st->contra = 1;
            if (st->n == 2) {
                st->pending = 0;
                if (st->contra) {
                    if (!st->fault) {
                        st->fault = 1;
                        st->freason = FR_CONTRA;
                        st->fault_since = now;
                        raised[i] = 1;
                    }
                    st->ok_since = NONE;
                } else {
                    snprintf(b, sizeof b, "anomaly:%s", S->name);
                    latch4(k, o, b, now);
                }
            } else
                st->n++;
        }
    }

    /* 4. sensor faults (C-9, K-1, K-2) */
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        struct sstate *st = &k->s[i];
        if (S->kind == K_JSON || S->kind == K_AUX || (S->kind == K_PSY && !sample))
            continue;
        if (st->h == H_READ || st->h == H_LOW || st->h == H_FROZEN || st->h == H_STUCK) {
            if (!st->fault) {
                st->fault = 1;
                st->freason = st->h;
                st->fault_since = now;
            }
            st->ok_since = NONE;
        } else if (st->fault && !raised[i]) {
            if (st->h == H_OK) {
                if (st->ok_since == NONE)
                    st->ok_since = now;
                if (now - st->ok_since >= 30000) {
                    st->fault = 0;
                    st->ok_since = NONE;
                }
            } else
                st->ok_since = NONE;
        }
        if (st->fault && now - st->fault_since >= 120000) {
            snprintf(b, sizeof b, "sensor:%s", S->name);
            latch4(k, o, b, now);
        }
    }

    /* 5. levels (C-10) */
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        if (S->kind == K_JSON || S->kind == K_AUX || (S->kind == K_PSY && !sample))
            continue;
        level_update(S, &k->s[i], now);
    }

    /* 6. battery class (C-12, K-8) and classes (C-11, K-7) */
    {
        int cond[CL_N] = {0}, cond_ns[CL_N] = {0}; /* cond_ns: with stuck sensors as healthy (K-33) */
        int skip_batt = c->batt_absent;
        if (!skip_batt) {
            if (c->adsp)
                k->b_adsp = in->adsp != 1;
            if (sample) {
                int anyerr = in->psy_temp.st != RD_NUM || in->psy_volt.st != RD_NUM || in->psy_curr.st != RD_NUM ||
                             in->psy_cap.st != RD_NUM || in->psy_status == ST_ERR;
                k->b_psy = anyerr;
                if (in->psy_temp.st == RD_NUM && in->psy_volt.st == RD_NUM && in->psy_curr.st == RD_NUM) {
                    int32_t t3[3] = {in->psy_temp.v, in->psy_volt.v, in->psy_curr.v};
                    if (k->have_triple && !memcmp(t3, k->trip3, sizeof t3)) {
                        if (k->stale_start == NONE)
                            k->stale_start = now;
                        k->b_stale = now - k->stale_start > 60000;
                    } else {
                        k->stale_start = NONE;
                        k->b_stale = 0;
                    }
                    k->have_triple = 1;
                    memcpy(k->trip3, t3, sizeof t3);
                }
            }
            if (k->b_adsp || k->b_psy || k->b_stale)
                cond[CL_BATT] = cond_ns[CL_BATT] = 1;
        }
        for (j = 0; j < c->ng; j++) {
            int cnt = 0, cnt_ns = 0;
            if (skip_batt && c->g[j].cls == CL_BATT)
                continue;
            for (i = 0; i < c->ns; i++)
                if (c->s[i].group == j) {
                    if (k->s[i].usable && !k->s[i].fault)
                        cnt++;
                    if ((k->s[i].usable || k->s[i].h == H_STUCK) &&
                        (!k->s[i].fault || k->s[i].freason == H_STUCK))
                        cnt_ns++;
                }
            if (cnt < c->g[j].min)
                cond[c->g[j].cls] = 1;
            if (cnt_ns < c->g[j].min)
                cond_ns[c->g[j].cls] = 1;
        }
        {
            int nact = 0;
            for (j = 0; j < CL_N; j++) {
                struct cstate *cs = &k->cl[j];
                if (cond[j]) {
                    if (!cs->active) {
                        cs->active = 1;
                        cs->since = now;
                        cs->nonstuck = 0;
                    }
                    cs->ok_since = NONE;
                } else if (cs->active) {
                    if (cs->ok_since == NONE)
                        cs->ok_since = now;
                    if (now - cs->ok_since >= 30000) {
                        cs->active = 0;
                        cs->ok_since = NONE;
                        cs->nonstuck = 0;
                    }
                }
                if (cs->active && cond_ns[j])
                    cs->nonstuck = 1; /* K-39: a non-stuck cause seen in this episode */
                if (cs->active) {
                    if (cs->nonstuck) /* K-33/K-39: stuck-only episodes skip the two-class rule */
                        nact++;
                    if (now - cs->since >= 120000) {
                        snprintf(b, sizeof b, "class:%s", cls_name((enum cls)j));
                        latch4(k, o, b, now);
                    }
                }
            }
            if (nact >= 2)
                latch4(k, o, "classes", now);
        }
    }

    /* 7. fan checks vs the previous target (C-23 .. C-25, K-44 .. K-47), then demand (C-20) */
    if (fan_on) {
        int rpm_ok = !in->fan_absent && in->rpm.st == RD_NUM, pwm_ok = !in->fan_absent && in->pwm.st == RD_NUM;
        int anyerr = in->fan_absent || in->rpm.st != RD_NUM || in->pwm.st != RD_NUM || in->cur.st != RD_NUM ||
                     in->max.st != RD_NUM;
        int nonf6 = 0;
        e6 = anyerr || in->fan_wr_err; /* the C-23 read/write/absence condition of this tick */
        /* K-44: F6 is a rate, the condition on >= 5 of the last 20 ticks (this one included) */
        if (__builtin_popcount(((k->f6_hist << 1) | (unsigned)e6) & 0xFFFFFu) >= 5)
            fcode_now = 6;
        if (c->zone_fault) {
            fcode_now = fcode_now ? fcode_now : 8; /* K-25 */
            nonf6 = 1;
        }
        if (!in->fan_absent && in->cur.st == RD_NUM && in->max.st == RD_NUM && in->cur.v > in->max.v) {
            fcode_now = fcode_now ? fcode_now : 1;
            nonf6 = 1;
        }
        if (anyerr) {
            k->imp_hist = 0; /* K-38: an ERR/ABSENT tick clears the history */
            k->imp_cnt = 0;
        } else { /* K-35/K-38 tach plausibility */
            int64_t r = in->rpm.v;
            int imp = r < 0 || (c->max_rpm > 0 && r * 10 > (int64_t)c->max_rpm * 12);
            if (!imp && c->rpm_per_sec > 0 && k->have_prev_rpm && !(r <= c->silent_rpm && k->prev_rpm <= c->silent_rpm)) {
                int64_t d = r - k->prev_rpm, pr = k->prev_rpm;
                int64_t floor = pr * 25 / 100 > 500 ? pr * 25 / 100 : 500; /* K-49 */
                if ((d < 0 ? -d : d) > (int64_t)2 * c->rpm_per_sec * (now - k->prev_rpm_t) / 1000 + floor)
                    imp = 1;
            }
            k->imp_hist = ((k->imp_hist << 1) | (unsigned)imp) & 0x1Fu;
        }
        if (!k->first) { /* K-43: the expectation follows time and targets on every tick */
            int pt0 = k->prev_target;
            if (now >= k->allow_until)
                k->xexp = pt0;
            else {
                if (now >= k->spin_until && now - k->t_change > 1000) {
                    k->xexp += (int64_t)c->rpm_per_sec * (now - k->t_last) / 1000;
                    if (k->xexp > pt0)
                        k->xexp = pt0;
                }
                if (pt0 < k->xexp)
                    k->xexp = pt0;
            }
        }
        if (k->first) {
            k->f2 = k->f3 = k->f4 = k->f5 = NONE;
            k->need = 0;
        } else {
            /* per check: 0 false (the timer resets), 1 holds, 2 held (K-36, K-45, K-47: neither
             * starts nor resets the timer, fires once a running timer has passed its limit) */
            int pt = k->prev_target;
            int in_allow = now < k->allow_until, in_spin = now < k->spin_until;
            int s2 = 0, s3 = 0, s4 = 0, s5 = 0;
            if (in_spin)
                k->need = 0; /* K-24 (a) */
            else if (!rpm_ok)
                s2 = s3 = s5 = 2; /* K-45 */
            else {
                int64_t rpm = in->rpm.v, lvl;
                int low, c3;
                /* K-24 (a): F2 and F5 through the allowance, outside the spin-up grace */
                s2 = pt > 0 && rpm == 0;
                s5 = k->have_last_rpm && rpm == k->last_rpm && pt > 0; /* K-45: the last numeric rpm */
                if (!in_allow) {
                    int64_t tol = (int64_t)pt * 15 / 100 > 500 ? (int64_t)pt * 15 / 100 : 500;
                    low = rpm < pt - tol;
                    c3 = low || rpm > pt + tol;
                    lvl = pt - tol;
                } else { /* K-43 */
                    int64_t e = k->xexp, te = e * 15 / 100 > 500 ? e * 15 / 100 : 500;
                    low = c3 = rpm < e - te;
                    lvl = e - te;
                }
                if (c3) {
                    s3 = 1;
                    if (low && lvl > k->need) /* K-47 */
                        k->need = lvl;
                } else if (!in_allow || rpm >= k->need)
                    k->need = 0; /* K-47: the fan showed the speed it lacked */
                else
                    s3 = 2;
            }
            /* K-24 (c): F4 against DT max-rpm at full PWM, outside the allowance only */
            if (!in_allow) {
                if (!rpm_ok || !pwm_ok)
                    s4 = 2;
                else
                    s4 = in->pwm.v == c->max_pwm &&
                         (int64_t)in->rpm.v * 100 < (int64_t)85 * (c->max_rpm > 0 ? c->max_rpm : pt); /* K-32 */
            }
            {
                int64_t *tm[4] = {&k->f2, &k->f3, &k->f4, &k->f5};
                const int st4[4] = {s2, s3, s4, s5}, code[4] = {2, 3, 4, 5};
                const int64_t lim[4] = {20000, 45000, 45000, 30000};
                for (j = 0; j < 4; j++) {
                    if (st4[j] == 1 && *tm[j] == NONE)
                        *tm[j] = now;
                    else if (st4[j] == 0)
                        *tm[j] = NONE;
                    if (*tm[j] != NONE && now - *tm[j] > lim[j]) {
                        fcode_now = fcode_now ? fcode_now : code[j];
                        nonf6 = 1;
                    }
                }
            }
            if (k->f3 == NONE)
                k->need = 0;
        }
        if (__builtin_popcount(k->imp_hist) >= 3) { /* K-38: 3 of the last 5 */
            fcode_now = fcode_now ? fcode_now : 9;
            nonf6 = 1;
        }
        k->fan_nonf6 = nonf6;
        if (!anyerr) { /* K-38: F9's previous reading is the previous tick's only */
            k->have_prev_rpm = 1;
            k->prev_rpm = in->rpm.v;
            k->prev_rpm_t = now;
        } else
            k->have_prev_rpm = 0;
        if (rpm_ok) { /* K-45 */
            k->have_last_rpm = 1;
            k->last_rpm = in->rpm.v;
        }
        k->rpm3[2] = k->rpm3[1]; /* K-46 */
        k->rpm3ok[2] = k->rpm3ok[1];
        k->rpm3[1] = k->rpm3[0];
        k->rpm3ok[1] = k->rpm3ok[0];
        k->rpm3[0] = rpm_ok ? in->rpm.v : 0;
        k->rpm3ok[0] = rpm_ok;
        fan_cond = fcode_now != 0;
        if (fan_cond) {
            if (!k->ffault) {
                k->ffault = 1;
                k->fcode = fcode_now;
                k->fsince = now;
            }
            k->fok_since = NONE;
        } else if (k->ffault && now < k->allow_until) {
            k->fok_since = NONE; /* K-15: never clears inside the allowance */
        } else if (k->ffault) {
            if (k->fok_since == NONE)
                k->fok_since = now;
            if (now - k->fok_since >= 60000) { /* K-16 */
                k->ffault = 0;
                k->fok_since = NONE;
            }
        }
    } else if (c->has_fan) { /* headless and absent: no checks, no F9 history (K-38, K-42) */
        k->imp_hist = 0;
        k->have_prev_rpm = 0;
    }
    if (c->has_fan) /* K-41/K-44: a headless absent tick counts as no failure */
        k->f6_hist = ((k->f6_hist << 1) | (unsigned)e6) & 0xFFFFFu;
    /* demand (C-20) */
    {
        int r, dl = 0;
        for (r = 0; r < c->nr; r++) {
            const struct frule *R = &c->r[r];
            const struct sstate *bs = &k->s[R->base];
            int rl = 0;
            for (j = 0; j < R->ntrips; j++) {
                if (bs->usable) {
                    if (bs->v >= R->t[j])
                        k->fan_active[r][j] = 1;
                    else if (bs->v < R->t[j] - R->h[j])
                        k->fan_active[r][j] = 0;
                }
                if (k->fan_active[r][j] && R->lvl[j] > rl)
                    rl = R->lvl[j];
            }
            if (rl > dl)
                dl = rl;
        }
        k->target = c->has_fan && dl < c->nlevels ? c->levels[dl] : 0;
        k->dlevel = dl;
        if (c->has_fan && !in->fan_absent && in->rpm.st == RD_NUM && in->pwm.st == RD_NUM &&
            in->cur.st == RD_NUM && in->max.st == RD_NUM && in->cur.v != dl) { /* K-31, log only */
            if (k->cdev_start == NONE)
                k->cdev_start = now;
            if (now - k->cdev_start > 10000 && !k->cdev_fired) {
                k->cdev_fired = 1;
                adde(o, "cdev-mismatch");
            }
        } else {
            k->cdev_start = NONE;
            k->cdev_fired = 0;
        }
    }

    /* 8. P5, P6, P13 (C-13, C-14) */
    if (c->p5 >= 0 && k->s[c->p5].usable && k->s[c->p5].v >= c->p5_t)
        latch4(k, o, "p5", now);
    if (sample) {
        if (in->psy_status != ST_ERR)
            k->last_status = in->psy_status;
        if (in->psy_cap.st == RD_NUM && in->psy_status != ST_ERR) {
            int dis = in->psy_status == ST_DISCHARGING;
            int lb = dis && in->psy_cap.v <= 10;
            if (dis && in->psy_cap.v <= 3)
                latch4(k, o, "p6", now);
            if (lb && !k->lowbatt)
                adde(o, "lowbatt");
            k->lowbatt = lb;
        }
        /* C-32 J-145, a WARN since J-171 (K-17) */
        if (in->psy_status != ST_ERR && in->psy_temp.st == RD_NUM && in->psy_volt.st == RD_NUM &&
            in->psy_curr.st == RD_NUM && in->psy_cap.st == RD_NUM) { /* any ERR field keeps it (K-17, K-23) */
            int jc = in->psy_status == ST_CHARGING && in->psy_temp.v >= 300;
            if (jc && !k->j145c)
                adde(o, "j145");
            k->j145c = jc;
        }
    }

    /* 9. self-test (C-29, K-9, K-48) */
    if (k->first || k->st_retry) {
        char item[64] = "";
        int defer = 0;
        for (i = 0; k->first && i < c->ns && !item[0]; i++) {
            const struct sens *S = &c->s[i];
            if ((S->kind != K_ZONE && S->kind != K_IIO && S->kind != K_PSY) || !counted_cls(S->cls))
                continue;
            if (c->batt_absent && S->cls == CL_BATT)
                continue;
            if (k->s[i].h != H_OK)
                snprintf(item, sizeof item, "sensor:%s", S->name);
        }
        {
            static const enum cls order[6] = {CL_SOC, CL_SKIN, CL_BATT, CL_USB, CL_BOARD, CL_PMIC}; /* K-53 */
            for (j = 0; k->first && j < 6 && !item[0]; j++)
                if (k->cl[order[j]].active)
                    snprintf(item, sizeof item, "class:%s", cls_name(order[j]));
        }
        if (k->first && !item[0] && !in->caps_ok_at_start)
            snprintf(item, sizeof item, "caps");
        if (!item[0] && !(c->headless_fan && in->fan_absent)) {
            if (!c->has_fan || fan_cond)
                snprintf(item, sizeof item, "fan");
            else if (e6) { /* K-48: a read/write failure alone is retried on the next two ticks */
                if (k->first) {
                    k->st_retry = 2;
                    defer = 1;
                } else if (--k->st_retry > 0)
                    defer = 1;
                else
                    snprintf(item, sizeof item, "fan");
            }
        }
        if (!defer) {
            k->st_retry = 0;
            if (item[0]) {
                k->selftest_fail = 1;
                snprintf(b, sizeof b, "notready:%s", item);
                adde(o, b);
            } else {
                k->ready = 1;
                adde(o, "ready");
            }
        }
    }

    /* 10. other T4 latches (C-16) */
    for (i = 0; i < c->ns; i++)
        if (c->s[i].kind != K_JSON && c->s[i].kind != K_AUX && k->s[i].L >= 4) { /* K-28: fail closed */
            snprintf(b, sizeof b, "shutdown:%s", c->s[i].name);
            latch4(k, o, b, now);
        }
    if (fan_on && k->ffault) {
        int r;
        if (now - k->fsince >= 120000)
            latch4(k, o, "fan", now);
        /* K-34: trip-2 escalation only on a current non-F6 condition or an F6 streak >= 5 s */
        if (!k->fan_nonf6 && __builtin_popcount(k->f6_hist & 0x3FFu) < 6) /* K-41: 6 of the last 10 */
            r = c->nr;
        else
            r = 0;
        for (; r < c->nr; r++)
            for (j = 1; j < c->r[r].ntrips; j++)
                if (k->fan_active[r][j]) {
                    latch4(k, o, "fan-trip2", now);
                    r = c->nr;
                    break;
                }
    }
    if (in->cap_fail)
        latch4(k, o, "cap", now);
    if (k->selftest_fail && !c->trial_override && now - k->t0 >= 60000)
        latch4(k, o, "selftest", now);

    /* 11. T5 fast escalation (C-18); the budget T5 also starts here (C-35) */
    if (k->t4 && !k->t5) {
        int fired = 0;
        for (i = 0; i < c->ns; i++) {
            const struct sens *S = &c->s[i];
            int32_t d = S->cls == CL_SOC ? 5000 : S->cls == CL_BATT ? 2000 : S->cls == CL_SKIN ? 3000 : -1;
            if (d < 0 || S->th[6] == UNSET || S->kind == K_JSON || S->kind == K_AUX || !k->s[i].usable)
                continue;
            if (k->s[i].v >= S->th[6] + d) {
                fired = 1;
                snprintf(b, sizeof b, "t5:p12:%s", S->name);
                adde(o, b);
            }
        }
        if (fired) {
            k->t5 = 1;
            k->tf = now;
        } else if (!c->stage && k->have_tl0 && now >= k->tl0 + 45000) {
            k->t5 = 1;
            k->tf = NONE;
            adde(o, "t5:budget");
        }
    }

    /* 12. tier (C-15, C-17) */
    {
        int want = 0, any3 = 0;
        for (i = 0; i < c->ns; i++) {
            const struct sens *S = &c->s[i];
            struct sstate *st = &k->s[i];
            int tl;
            if (S->kind == K_JSON || S->kind == K_AUX)
                continue;
            tl = st->L == 1 ? 1 : st->L == 2 ? 2 : st->L == 3 ? 3 : st->L >= 4 ? 4 : 0; /* K-28 */
            if (tl > want)
                want = tl;
            if (st->fault || st->pending)
                any3 = 1;
        }
        for (j = 0; j < CL_N; j++)
            if (k->cl[j].active)
                any3 = 1;
        if ((fan_on && k->ffault) || k->lowbatt || k->selftest_fail || k->j145c)
            any3 = 1;
        if (any3 && want < 3)
            want = 3;
        if (k->t4)
            k->tier = k->t5 ? 5 : 4;
        else {
            if (k->tier == 3 && want < 3 && now - k->t3_since < 30000)
                want = 3;
            if (want == 3 && k->tier < 3)
                k->t3_since = now;
            k->tier = want > 3 ? 3 : want;
        }
    }

    /* 13. fan target and allowance (C-21, C-22) */
    if (fan_on) {
        int t = k->target, tierf = c->floor_tier[k->tier];
        if (c->floor_p1 > t)
            t = c->floor_p1;
        if (tierf > t)
            t = tierf;
        if (t > c->top)
            t = c->top;
        if (k->tier >= 4 || !k->ready || k->ffault)
            t = c->top;
        if (k->first || t != k->prev_target) {
            int old = k->first ? 0 : k->prev_target;
            int64_t ramp = 0, dd = (int64_t)t - old;
            if (dd < 0)
                dd = -dd;
            if (c->rpm_per_sec > 0 && !(old <= c->silent_rpm && t <= c->silent_rpm))
                ramp = dd * 1000 / c->rpm_per_sec;
            if (ramp > 60000)
                ramp = 60000; /* K-24 (d) */
            k->allow_until = now + 15000 + ramp;
            if (old == 0 && t > 0)
                k->spin_until = now + 15000; /* K-24 (a) */
            k->t_prev = old;
            k->t_change = now;
            /* K-46: the median of the numeric rpm readings of the last three ticks (two: the
             * lower; one: that one), else the last numeric rpm of an earlier tick, else 0 */
            {
                int32_t v[3];
                int n = 0, a, b;
                for (a = 0; a < 3; a++)
                    if (k->rpm3ok[a])
                        v[n++] = k->rpm3[a];
                for (a = 1; a < n; a++) /* insertion sort, n <= 3 */
                    for (b = a; b > 0 && v[b - 1] > v[b]; b--) {
                        int32_t x = v[b];
                        v[b] = v[b - 1];
                        v[b - 1] = x;
                    }
                k->r0 = n ? v[(n - 1) / 2] : k->have_last_rpm ? k->last_rpm : 0;
            }
            /* K-43 */
            if (c->rpm_per_sec <= 0 || (old <= c->silent_rpm && t <= c->silent_rpm))
                k->xexp = t;
            else if (t < k->xexp)
                k->xexp = t;
            else {
                int64_t m = k->r0 < t ? k->r0 : t;
                if (m > k->xexp)
                    k->xexp = m;
            }
        }
        k->prev_target = t;
        o->fan = t;
    } else
        o->fan = -1;

    /* 14. caps (C-27) */
    {
        int idx = k->ready ? k->tier : (k->tier > 3 ? k->tier : 3);
        if (c->has_caps) {
            o->cpu = c->cpu[idx];          /* -2: no cap at this tier (K-30) */
            o->cpu_min = c->cpu[idx] == -1;
        } else
            o->cpu = -2;
        o->gpu = c->has_gpu ? c->gpu[idx] : -1;
    }

    /* 15. timeline and petting (C-34 .. C-40, K-11, K-12) */
    if (!k->have_tl0) {
        int ext = !c->stage && (in->shutdown_byte || in->pid1_shutdown);
        if (k->t4 || ext) {
            k->have_tl0 = 1;
            k->tl0 = now;
        }
    }
    if (c->stage) {
        if (k->t4 && k->t4_at == now && !k->sent_term) {
            k->sent_term = 1;
            adda(o, "term-step");
        }
        if (k->have_tl0 && now >= k->tl0 + 2000 && !k->sent_kill) {
            k->sent_kill = 1;
            k->sent_final = 1;
            adda(o, "kill-step");
            adda(o, "final-pet");
            adda(o, "trip");
        } else if (!k->sent_final)
            adda(o, "pet");
    } else {
        int do_final = 0;
        if (k->t4 && k->t4_at == now && !k->sent_sig) {
            k->sent_sig = 1;
            adda(o, "signal-pid1");
        }
        if (k->have_tl0 && now >= k->tl0 + 45000) {
            if (!k->sent_a1) {
                k->sent_a1 = 1;
                adda(o, "a1");
            }
        }
        if (k->t5 && k->tf != NONE && !k->sent_a1) {
            k->sent_a1 = 1;
            adda(o, "a1");
        }
        if (k->have_tl0 && now >= k->tl0 + 55000)
            do_final = 1;
        if (k->t5 && k->tf != NONE && (in->a1_done || now >= k->tf + 10000))
            do_final = 1;
        if (k->sent_a2 && in->a2_exited && c->p15 && !k->sent_sysrq) {
            k->sent_sysrq = 1; /* K-12: only after an A2 of an earlier tick */
            adda(o, "sysrq-c");
        }
        if (do_final && !k->sent_final) {
            k->sent_final = 1;
            k->sent_a2 = 1;
            adda(o, "final-pet");
            adda(o, "a2");
        } else if (!k->sent_final)
            adda(o, "pet");
    }

    /* 16. events (C-31) and the fault list */
    if (k->t4 && k->t4_at == now) {
        if (in->usb_online.st == RD_NUM && in->usb_online.v == 1)
            adde(o, "unplug");
        else if (k->last_status == ST_CHARGING || k->last_status == ST_FULL)
            adde(o, "unplug");
    }
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        if (S->kind == K_JSON || S->kind == K_AUX)
            continue;
        if (k->s[i].fault) {
            snprintf(b, sizeof b, "s:%s:%s", S->name, freason_name[k->s[i].freason]);
            addtok(o->f, &o->nf, b);
        }
        if (k->s[i].pending) {
            snprintf(b, sizeof b, "p:%s", S->name);
            addtok(o->f, &o->nf, b);
        }
    }
    for (j = 0; j < CL_N; j++)
        if (k->cl[j].active) {
            snprintf(b, sizeof b, "c:%s", cls_name((enum cls)j));
            addtok(o->f, &o->nf, b);
        }
    if (!c->batt_absent) {
        if (k->b_adsp)
            addtok(o->f, &o->nf, "b:adsp");
        if (k->b_psy)
            addtok(o->f, &o->nf, "b:psy");
        if (k->b_stale)
            addtok(o->f, &o->nf, "b:stale");
    }
    if (fan_on && k->ffault) {
        snprintf(b, sizeof b, "fan:F%d", k->fcode);
        addtok(o->f, &o->nf, b);
    }
    if (k->selftest_fail)
        addtok(o->f, &o->nf, "selftest");

    o->tier = k->tier;
    o->ready = k->ready;
    notice(k, o, now, fan_on);
    k->t_last = now; /* K-43 */
    k->first = 0;
}

static int cmpstr(const void *a, const void *b) { return strcmp((const char *)a, (const char *)b); }

static void join(char *dst, int cap, char *base, int n, int stride)
{
    int i, p = 0;
    if (!n) {
        snprintf(dst, (size_t)cap, "-");
        return;
    }
    qsort(base, (size_t)n, (size_t)stride, cmpstr);
    dst[0] = 0;
    for (i = 0; i < n; i++)
        p += snprintf(dst + p, (size_t)(cap - p > 0 ? cap - p : 0), "%s%s", i ? "," : "", base + (size_t)i * stride);
}

void out_line(const struct tick_out *o0, int64_t t, char *buf, int cap)
{
    struct tick_out o = *o0;
    char f[4096], e[4096], a[512], cpu[24], fan[16], gpu[8];
    join(f, sizeof f, &o.f[0][0], o.nf, 48);
    join(e, sizeof e, &o.e[0][0], o.ne, 64);
    join(a, sizeof a, &o.a[0][0], o.na, 16);
    if (o.cpu == -2)
        snprintf(cpu, sizeof cpu, "-");
    else if (o.cpu_min)
        snprintf(cpu, sizeof cpu, "min");
    else
        snprintf(cpu, sizeof cpu, "%d", o.cpu);
    if (o.fan < 0)
        snprintf(fan, sizeof fan, "-");
    else
        snprintf(fan, sizeof fan, "%d", o.fan);
    if (o.gpu < 0)
        snprintf(gpu, sizeof gpu, "-");
    else
        snprintf(gpu, sizeof gpu, "%d", o.gpu);
    snprintf(buf, (size_t)cap, "t=%lld tier=%d ready=%d fan=%s cpu=%s gpu=%s f=%s e=%s a=%s n=%s", (long long)t,
             o.tier, o.ready, fan, cpu, gpu, f, e, a, o.notice[0] ? o.notice : "-");
}

/* gate (C-41 .. C-44, K-13): evaluate the first tick, then the rules */
int core_gate(struct core *k, const struct tick_in *in, char *out, int cap)
{
    const struct conf *c = k->c;
    struct tick_out o;
    char r[MAXTOK][48], j[4096];
    int nr = 0, i, warn = 0;
    core_tick(k, in, &o);
    if (k->selftest_fail)
        addtok(r, &nr, "selftest");
    for (i = 0; i < c->ns; i++) {
        const struct sens *S = &c->s[i];
        const struct sstate *st = &k->s[i];
        char b[48];
        if (S->kind == K_JSON || S->kind == K_AUX)
            continue;
        if (c->batt_absent && S->cls == CL_BATT)
            continue;
        if (st->fault || st->pending)
            addtok(r, &nr, "fault");
        if (!st->usable)
            continue;
        snprintf(b, sizeof b, "hot:%s", S->name);
        if (S->th[3] != UNSET && st->v >= S->th[3] - (S->hy[3] == UNSET ? 0 : S->hy[3]))
            addtok(r, &nr, b);
        if (i == c->p5 && st->v >= c->p5_t)
            addtok(r, &nr, b);
        if (in->pstore_marker) {
            int kk;
            for (kk = 1; kk <= 6; kk++)
                if (S->th[kk] != UNSET) {
                    if (st->v >= S->th[kk])
                        addtok(r, &nr, b);
                    break;
                }
        }
    }
    if (in->psy_cap.st == RD_NUM && in->psy_status == ST_DISCHARGING) {
        if (in->psy_cap.v <= 3)
            addtok(r, &nr, "p6");
        if (in->psy_cap.v <= 10)
            warn = 1;
    }
    if (c->j145 && in->psy_status == ST_CHARGING && in->psy_temp.st == RD_NUM && in->psy_temp.v >= 300)
        addtok(r, &nr, "j145");
    join(j, sizeof j, &r[0][0], nr, 48);
    snprintf(out, (size_t)cap, "gate=%s reasons=%s%s", nr ? "refuse" : "pass", j, warn ? " warn=lowbatt" : "");
    return nr ? 1 : 0;
}
