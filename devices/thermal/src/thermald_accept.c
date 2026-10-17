// SPDX-License-Identifier: Apache-2.0
// fs-thermald: acceptance of the fs-metacfg record (METACFG-SPEC.md §7,
// A-1 .. A-9; design §4.5.3) and construction of the active configuration
// (CORE-SPEC.md §1). fs-thermald never parses JSON, LP or ext4: it checks
// framing, computes the hashes itself (m5) and validates fixed-size entries.
#include <stdio.h>
#include <string.h>
#include "metacfg_record.h"
#include "sha256.h"
#include "thermald.h"
#include "thermald_accept.h"

static const struct cmap *cm_find(const struct devtab *dt, const char *name)
{
    int i;
    for (i = 0; i < dt->ncm; i++)
        if (!strcmp(dt->cm[i].name, name))
            return &dt->cm[i];
    return NULL;
}

static int is_temp_cls(enum cls c) { return c == CL_SOC || c == CL_SKIN || c == CL_BATT || c == CL_USB || c == CL_BOARD; }

/* A-1 framing. Returns 0 and fills the view, or -1. */
int rec_view(const uint8_t *b, size_t n, struct recview *v)
{
    uint64_t want;
    memset(v, 0, sizeof *v);
    if (n < MC_HDR || memcmp(b, MC_MAGIC, 4) || mc_rd16(b + 4) != MC_VERSION || mc_rd32(b + 24) != MC_ENTRY)
        return -1;
    v->status = mc_rd16(b + 6);
    v->json_len = mc_rd32(b + 8);
    v->vr_len = mc_rd32(b + 12);
    v->dev_len = mc_rd16(b + 16);
    v->incr_len = mc_rd16(b + 18);
    v->n = mc_rd32(b + 20);
    if (v->json_len > MC_MAX_JSON || v->vr_len > MC_MAX_VR || v->dev_len > MC_MAX_PROP ||
        v->incr_len > MC_MAX_PROP || v->n > MC_MAX_ENTRIES)
        return -1;
    want = (uint64_t)MC_HDR + v->json_len + v->vr_len + v->dev_len + v->incr_len + (uint64_t)v->n * MC_ENTRY;
    if (want != n)
        return -1;
    v->json = b + MC_HDR;
    v->vr = v->json + v->json_len;
    v->dev = v->vr + v->vr_len;
    v->incr = v->dev + v->dev_len;
    v->ent = v->incr + v->incr_len;
    return 0;
}

/* bytes still expected after the header, or -1 if the header is not acceptable */
long rec_expect(const uint8_t *hdr)
{
    struct recview v;
    uint64_t rest;
    if (memcmp(hdr, MC_MAGIC, 4) || mc_rd16(hdr + 4) != MC_VERSION || mc_rd32(hdr + 24) != MC_ENTRY)
        return -1;
    v.json_len = mc_rd32(hdr + 8);
    v.vr_len = mc_rd32(hdr + 12);
    v.dev_len = mc_rd16(hdr + 16);
    v.incr_len = mc_rd16(hdr + 18);
    v.n = mc_rd32(hdr + 20);
    if (v.json_len > MC_MAX_JSON || v.vr_len > MC_MAX_VR || v.dev_len > MC_MAX_PROP ||
        v.incr_len > MC_MAX_PROP || v.n > MC_MAX_ENTRIES)
        return -1;
    rest = (uint64_t)v.json_len + v.vr_len + v.dev_len + v.incr_len + (uint64_t)v.n * MC_ENTRY;
    return (long)rest;
}

static int eq_hex(const uint8_t d[32], const char *hex)
{
    char h[65];
    sha256_hex(d, h);
    return !strcmp(h, hex);
}

static int32_t ent_slot(const uint8_t *e, int k) { return (int32_t)mc_rd32(e + 32 + 4 * k); }
static int32_t ent_hy(const uint8_t *e, int k) { return (int32_t)mc_rd32(e + 60 + 4 * k); }

static const uint8_t *ent_find(const struct recview *v, const char *name)
{
    uint32_t i;
    for (i = 0; i < v->n; i++) {
        const uint8_t *e = v->ent + (size_t)i * MC_ENTRY;
        if (!strncmp((const char *)e, name, MC_NAME) && memchr(e, 0, MC_NAME))
            return e;
    }
    return NULL;
}

/* A-2 .. A-8. Returns NULL (accepted) or a reason code. */
const char *rec_accept(const struct devtab *dt, const struct recview *v, struct accept_info *ai)
{
    static char reason[64];
    uint8_t hj[32], hd[32], hv[32];
    const struct krow *row = NULL;
    int i, k;
    uint32_t e;

    memset(ai, 0, sizeof *ai);
    if (v->status) {
        snprintf(reason, sizeof reason, "reader:%s", mc_status_name(v->status));
        return reason;
    }
    if (v->json_len == 0 || v->n == 0)
        return "reader-bad-record";
    /* A-3 */
    if (v->dev_len != strlen(dt->name) || memcmp(v->dev, dt->name, v->dev_len))
        return "device-mismatch";
    /* A-4: hashes computed here (m5) */
    sha256(v->json, v->json_len, hj);
    sha256(v->ent, (size_t)v->n * MC_ENTRY, hd);
    sha256(v->vr, v->vr_len, hv);
    sha256_hex(hj, ai->json_sha);
    sha256_hex(hd, ai->digest);
    for (i = 0; i < dt->nkr; i++)
        if (eq_hex(hj, dt->kr[i].json_sha))
            row = &dt->kr[i];
    if (!row)
        return "unknown-hash"; /* P18 */
    ai->row = row;
    if (!eq_hex(hd, row->digest)) {
        ai->fault_record = 1;
        return "digest-mismatch";
    }
    if (v->incr_len != strlen(row->incr) || memcmp(v->incr, row->incr, v->incr_len))
        return "incremental-mismatch";
    ai->vr_export = eq_hex(hv, row->vr_sha);
    /* A-5 multiplier */
    for (i = 0; i < dt->ncm; i++) {
        const uint8_t *en = ent_find(v, dt->cm[i].name);
        if (en && ((int32_t)mc_rd32(en + 88) != dt->cm[i].mult_num || (int32_t)mc_rd32(en + 92) != dt->cm[i].mult_den))
            return "multiplier";
    }
    /* A-6 bounds (step 5) */
    for (i = 0; i < dt->ncm; i++) {
        const struct cmap *m = &dt->cm[i];
        const uint8_t *en = ent_find(v, m->name);
        int32_t prev = UNSET, cap;
        if (!en || !is_temp_cls(m->cls))
            continue;
        if (ent_slot(en, 0) != UNSET || ent_slot(en, 4) != UNSET || ent_slot(en, 5) != UNSET)
            return "bounds-unset-slot";
        cap = m->cls == CL_SOC ? 115000 : m->cls == CL_BATT ? 65000 : m->cls == CL_SKIN ? 60000 : 125000;
        for (k = 1; k <= 6; k++) {
            int32_t s = ent_slot(en, k), h = ent_hy(en, k);
            if (s == UNSET)
                continue;
            if (s < 35000 || s > 125000)
                return "bounds-range";
            if (prev != UNSET && s <= prev)
                return "bounds-order";
            prev = s;
            if (h == UNSET)
                h = 0;
            if (h < 0)
                return "bounds-hyst";
            if ((int64_t)s - h < 20000)
                return "bounds-release";
            if (k == 6 && s > cap)
                return "bounds-shutdown";
        }
    }
    /* A-7 coverage (step 6) */
    for (i = 0; i < dt->ncm; i++) {
        const struct cmap *m = &dt->cm[i];
        const uint8_t *en;
        int mask = 0, ok = 0;
        if (!m->json)
            continue;
        en = ent_find(v, m->name);
        if (!en)
            return "coverage-missing";
        for (k = 0; k <= 6; k++)
            if (ent_slot(en, k) != UNSET)
                mask |= 1 << k;
        for (k = 0; k < m->nmasks; k++)
            if (m->masks[k] == mask)
                ok = 1;
        if (!ok)
            return "coverage-mask";
    }
    for (e = 0; e < v->n; e++) {
        const uint8_t *en = v->ent + (size_t)e * MC_ENTRY;
        char nm[MC_NAME + 1];
        int any = 0;
        for (k = 0; k <= 6; k++)
            if (ent_slot(en, k) != UNSET)
                any = 1;
        if (!any)
            continue;
        memcpy(nm, en, MC_NAME);
        nm[MC_NAME] = 0;
        if (!cm_find(dt, nm))
            return "coverage-unmapped";
    }
    return NULL;
}

/* ---------------- active configuration (CORE-SPEC §1) ---------------- */
static int sens_index(const struct conf *c, const char *name)
{
    int i;
    for (i = 0; i < c->ns; i++)
        if (!strcmp(c->s[i].name, name))
            return i;
    return -1;
}

/* th/hy of class-map entry m from the record (accepted) or built-in */
static void thr_of(const struct devtab *dt, const struct recview *v, int accepted, const char *name, int32_t th[7],
                   int32_t hy[7])
{
    const struct cmap *m = cm_find(dt, name);
    const uint8_t *en = accepted ? ent_find(v, name) : NULL;
    int k;
    for (k = 0; k < 7; k++) {
        th[k] = en ? ent_slot(en, k) : m ? m->th[k] : UNSET;
        hy[k] = en ? ent_hy(en, k) : m ? m->hy[k] : UNSET;
    }
}

int conf_build(struct conf *c, const struct devtab *dt, const struct recview *v, int accepted)
{
    int i, j;
    memset(c, 0, sizeof *c);
    c->dt = dt;
    c->psy_period_ms = dt->psy_period_ms;
    c->adsp = dt->adsp;
    c->p5 = -1;
    for (i = 0; i < dt->ngd; i++) {
        snprintf(c->g[c->ng].name, sizeof c->g[0].name, "%s", dt->gd[i].name);
        c->g[c->ng].cls = dt->gd[i].cls;
        c->g[c->ng].min = dt->gd[i].min;
        c->ng++;
    }
    for (i = 0; i < dt->ncm; i++) {
        const struct cmap *m = &dt->cm[i];
        struct sens *s;
        if (m->kind == K_JSON)
            continue; /* class map only, never read */
        if (c->ns == MAXS)
            return -1;
        s = &c->s[c->ns++];
        snprintf(s->name, sizeof s->name, "%s", m->name);
        s->cls = m->cls;
        s->kind = m->kind;
        s->slow = m->slow;
        s->indep = m->indep;
        s->group = -1;
        if (m->group)
            for (j = 0; j < c->ng; j++)
                if (!strcmp(c->g[j].name, m->group))
                    s->group = j;
        thr_of(dt, v, accepted, m->thr_ref ? m->thr_ref : m->name, s->th, s->hy);
        for (j = 0; j < 4; j++)
            if (dt->weak[j] && !strcmp(dt->weak[j], m->name))
                s->weak = 1;
    }
    for (i = 0; i < c->ns; i++) {
        const struct cmap *m = cm_find(dt, c->s[i].name);
        for (j = 0; j < MAXVIN && m->vin[j]; j++) {
            int x = sens_index(c, m->vin[j]);
            if (x < 0)
                return -1;
            c->s[i].vin[c->s[i].nvin++] = x;
        }
    }
    c->has_fan = dt->has_fan;
    memcpy(c->levels, dt->fan_levels, sizeof c->levels);
    c->nlevels = dt->nlevels;
    c->top = dt->fan_top;
    c->floor_p1 = dt->floor_p1;
    memcpy(c->floor_tier, dt->floor_tier, sizeof c->floor_tier);
    c->rpm_per_sec = dt->rpm_per_sec;
    c->silent_rpm = dt->silent_rpm;
    c->max_pwm = dt->max_pwm;
    for (i = 0; i < dt->nfr; i++) {
        struct frule *r = &c->r[c->nr++];
        snprintf(r->zone, sizeof r->zone, "%s", dt->fr[i].zone);
        r->base = sens_index(c, dt->fr[i].base);
        if (r->base < 0)
            return -1;
        r->ntrips = dt->fr[i].ntrips;
        for (j = 0; j < r->ntrips; j++) {
            r->t[j] = dt->fr[i].t[j];
            r->h[j] = dt->fr[i].h[j];
            r->lvl[j] = dt->fr[i].lvl[j];
        }
    }
    c->has_caps = dt->has_caps;
    memcpy(c->cpu, dt->cpu, sizeof c->cpu);
    c->npol = dt->npol;
    memcpy(c->pol, dt->pol, sizeof c->pol);
    c->max_rpm = dt->max_rpm;
    c->has_gpu = dt->has_gpu;
    memcpy(c->gpu, dt->gpu, sizeof c->gpu);
    if (dt->p5) {
        c->p5 = sens_index(c, dt->p5);
        c->p5_t = dt->p5_t;
    }
    snprintf(c->limits, sizeof c->limits, "%s", accepted ? "meta-runtime" : "builtin");
    return 0;
}

/* drop the BATT class when the trial declares it absent by design (C-12) */
void conf_drop_batt(struct conf *c)
{
    int i, j, map[MAXS], n = 0;
    struct sens ns[MAXS];
    for (i = 0; i < c->ns; i++) {
        map[i] = -1;
        if (c->s[i].cls == CL_BATT)
            continue;
        map[i] = n;
        ns[n++] = c->s[i];
    }
    for (i = 0; i < n; i++) {
        int k = 0;
        for (j = 0; j < ns[i].nvin; j++)
            if (map[ns[i].vin[j]] >= 0)
                ns[i].vin[k++] = map[ns[i].vin[j]];
        ns[i].nvin = k;
    }
    for (i = 0; i < c->nr; i++)
        c->r[i].base = map[c->r[i].base];
    /* a fan rule whose base was dropped is removed */
    for (i = 0, j = 0; i < c->nr; i++)
        if (c->r[i].base >= 0)
            c->r[j++] = c->r[i];
    c->nr = j;
    if (c->p5 >= 0)
        c->p5 = map[c->p5];
    memcpy(c->s, ns, sizeof ns);
    c->ns = n;
    for (i = 0; i < c->ng; i++)
        if (c->g[i].cls == CL_BATT)
            c->g[i].min = 0;
}

static void jstr(FILE *f, const char *s) { fprintf(f, "\"%s\"", s); }
static void jint(FILE *f, int32_t v)
{
    if (v == UNSET)
        fprintf(f, "null");
    else
        fprintf(f, "%d", v);
}

void conf_dump(FILE *f, const struct conf *c)
{
    int i, k;
    static const char *kn[] = {"zone", "psy", "aux", "json", "iio"};
    fprintf(f, "{\"device\":");
    jstr(f, c->dt->name);
    fprintf(f, ",\"mode\":\"%s\",\"limits\":\"%s\",\"reason\":\"%s\",\"tick_ms\":1000,\"psy_period_ms\":%d,\"adsp\":%s,\n",
            c->stage ? "stage" : "valve", c->limits, c->reason, c->psy_period_ms, c->adsp ? "true" : "false");
    fprintf(f, " \"groups\":[");
    for (i = 0; i < c->ng; i++)
        fprintf(f, "%s{\"name\":\"%s\",\"class\":\"%s\",\"min\":%d}", i ? "," : "", c->g[i].name, cls_name(c->g[i].cls),
                c->g[i].min);
    fprintf(f, "],\n \"sensors\":[\n");
    for (i = 0; i < c->ns; i++) {
        const struct sens *s = &c->s[i];
        fprintf(f, "  %s{\"name\":\"%s\",\"class\":\"%s\",\"group\":", i ? "," : "", s->name, cls_name(s->cls));
        if (s->group >= 0)
            jstr(f, c->g[s->group].name);
        else
            fprintf(f, "null");
        fprintf(f, ",\"kind\":\"%s\",\"slow\":%d,\"indep\":%d,\"weak\":%d,\"th\":[", kn[s->kind], s->slow,
                s->indep, s->weak);
        for (k = 0; k < 7; k++) {
            if (k)
                fputc(',', f);
            jint(f, s->th[k]);
        }
        fprintf(f, "],\"hy\":[");
        for (k = 0; k < 7; k++) {
            if (k)
                fputc(',', f);
            jint(f, s->hy[k]);
        }
        fprintf(f, "],\"vin\":[");
        for (k = 0; k < s->nvin; k++)
            fprintf(f, "%s\"%s\"", k ? "," : "", c->s[s->vin[k]].name);
        fprintf(f, "]}\n");
    }
    fprintf(f, " ],\n \"fan\":");
    if (!c->has_fan)
        fprintf(f, "null");
    else {
        fprintf(f, "{\"levels\":[");
        for (i = 0; i < c->nlevels; i++)
            fprintf(f, "%s%d", i ? "," : "", c->levels[i]);
        fprintf(f, "],\"top\":%d,\"floor_p1\":%d,\"floor_tier\":[", c->top, c->floor_p1);
        for (i = 0; i < 6; i++)
            fprintf(f, "%s%d", i ? "," : "", c->floor_tier[i]);
        fprintf(f, "],\"rpm_per_sec\":%d,\"silent_rpm\":%d,\"max_pwm\":%d,\"max_rpm\":%d,\"zone_fault\":%s,\"rules\":[\n",
                c->rpm_per_sec, c->silent_rpm, c->max_pwm, c->max_rpm, c->zone_fault ? "true" : "false");
        for (i = 0; i < c->nr; i++) {
            const struct frule *r = &c->r[i];
            fprintf(f, "  %s{\"zone\":\"%s\",\"base\":\"%s\",\"trips\":[", i ? "," : "", r->zone, c->s[r->base].name);
            for (k = 0; k < r->ntrips; k++)
                fprintf(f, "%s{\"t\":%d,\"h\":%d,\"lvl\":%d}", k ? "," : "", r->t[k], r->h[k], r->lvl[k]);
            fprintf(f, "]}\n");
        }
        fprintf(f, " ]}");
    }
    fprintf(f, ",\n \"caps\":");
    if (!c->has_caps)
        fprintf(f, "null");
    else {
        fprintf(f, "{\"cpu\":[");
        for (i = 0; i < 6; i++) {
            if (i)
                fputc(',', f);
            if (c->cpu[i] == -2)
                fprintf(f, "null");
            else if (c->cpu[i] < 0)
                fprintf(f, "\"min\"");
            else
                fprintf(f, "%d", c->cpu[i]);
        }
        fprintf(f, "],\"gpu\":");
        if (!c->has_gpu)
            fprintf(f, "null");
        else {
            fprintf(f, "[");
            for (i = 0; i < 6; i++)
                fprintf(f, "%s%d", i ? "," : "", c->gpu[i]);
            fprintf(f, "]");
        }
        fprintf(f, "}");
    }
    fprintf(f, ",\n \"policies\":[");
    for (i = 0; i < c->npol; i++)
        fprintf(f, "%s%d", i ? "," : "", c->pol[i]);
    fprintf(f, "]");
    fprintf(f, ",\n \"p5\":");
    if (c->p5 < 0)
        fprintf(f, "null");
    else
        fprintf(f, "{\"sensor\":\"%s\",\"t\":%d}", c->s[c->p5].name, c->p5_t);
    fprintf(f, ",\n \"flags\":{\"trial_override\":%d,\"headless_fan\":%d,\"batt_absent\":%d,\"p15\":%d,\"j145\":%d}}\n",
            c->trial_override, c->headless_fan, c->batt_absent, c->p15, c->j145);
}
