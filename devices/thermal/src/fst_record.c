// SPDX-License-Identifier: Apache-2.0
// FST1 / FSN1 record encoding and parsing (EXEC-SPEC.md §4). Pure functions.
#include "fst_record.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint32_t fst_crc32(const void *p, size_t n)
{
    const unsigned char *b = p;
    uint32_t c = 0xffffffffu;
    size_t i;
    int k;
    for (i = 0; i < n; i++) {
        c ^= b[i];
        for (k = 0; k < 8; k++)
            c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1u)));
    }
    return ~c;
}

/* a field value: printable, no space, no '=', non-empty, < cap */
static int okval(const char *s, size_t cap)
{
    size_t i, n = strlen(s);
    if (!n || n >= cap)
        return 0;
    for (i = 0; i < n; i++)
        if (s[i] <= ' ' || s[i] > '~' || s[i] == '=')
            return 0;
    return 1;
}

int fst_encode(const struct fst *r, char *buf, size_t cap)
{
    char body[FST_MAX + 1], cd[16];
    int n, m;
    if (!okval(r->ev, sizeof r->ev) || !okval(r->reason, sizeof r->reason) || !okval(r->sensor, sizeof r->sensor) ||
        !okval(r->value, sizeof r->value) || !okval(r->hot, sizeof r->hot) || !okval(r->why, sizeof r->why) ||
        r->t < 0)
        return -1;
    if (r->cd < 0)
        snprintf(cd, sizeof cd, "-");
    else
        snprintf(cd, sizeof cd, "%d", r->cd);
    n = snprintf(body, sizeof body, "FST1 ev=%s t=%lld reason=%s sensor=%s value=%s hot=%s why=%s cd=%s", r->ev, r->t,
                 r->reason, r->sensor, r->value, r->hot, r->why, cd);
    if (n < 0 || (size_t)n >= sizeof body || n + 15 > FST_MAX)
        return -1;
    m = snprintf(buf, cap, "%s crc=%08x\n", body, fst_crc32(body, (size_t)n));
    if (m < 0 || (size_t)m >= cap)
        return -1;
    return m;
}

static int getf(const char *body, const char *key, char *out, size_t cap)
{
    /* body is "FST1 k=v k=v ..."; exact key match at a token start */
    size_t kl = strlen(key);
    const char *p = body;
    while ((p = strchr(p, ' '))) {
        p++;
        if (!strncmp(p, key, kl) && p[kl] == '=') {
            const char *v = p + kl + 1, *e = strchr(v, ' ');
            size_t l = e ? (size_t)(e - v) : strlen(v);
            if (!l || l >= cap)
                return -1;
            memcpy(out, v, l);
            out[l] = 0;
            return 0;
        }
    }
    return -1;
}

int fst_parse(const char *line, size_t n, struct fst *r)
{
    char tmp[FST_MAX + 2], num[24], cd[16], crc[16], chk[16];
    const char *c;
    size_t bl, i;
    char *e;
    if (n && line[n - 1] == '\n')
        n--;
    if (n < 20 || n > FST_MAX || memcmp(line, "FST1 ev=", 8))
        return -1;
    memcpy(tmp, line, n);
    tmp[n] = 0;
    for (i = 0; i < n; i++)
        if (tmp[i] < ' ' || tmp[i] > '~')
            return -1;
    c = strstr(tmp, " crc=");
    if (!c || strlen(c) != 13)
        return -1;
    bl = (size_t)(c - tmp);
    snprintf(crc, sizeof crc, "%s", c + 5);
    snprintf(chk, sizeof chk, "%08x", fst_crc32(tmp, bl));
    if (strcmp(crc, chk))
        return -1;
    tmp[bl] = 0;
    memset(r, 0, sizeof *r);
    if (getf(tmp, "ev", r->ev, sizeof r->ev) || getf(tmp, "t", num, sizeof num) ||
        getf(tmp, "reason", r->reason, sizeof r->reason) || getf(tmp, "sensor", r->sensor, sizeof r->sensor) ||
        getf(tmp, "value", r->value, sizeof r->value) || getf(tmp, "hot", r->hot, sizeof r->hot) ||
        getf(tmp, "why", r->why, sizeof r->why) || getf(tmp, "cd", cd, sizeof cd))
        return -1;
    if (num[0] < '0' || num[0] > '9' || (num[0] == '0' && num[1]))
        return -1;
    r->t = strtoll(num, &e, 10);
    if (*e || strlen(num) > 15)
        return -1;
    if (!strcmp(cd, "-"))
        r->cd = -1;
    else {
        long v;
        if (cd[0] < '0' || cd[0] > '9' || (cd[0] == '0' && cd[1]) || strlen(cd) > 6)
            return -1;
        v = strtol(cd, &e, 10);
        if (*e)
            return -1;
        r->cd = (int)v;
    }
    /* re-encoding must give the same bytes: one canonical form only */
    {
        char re[FST_MAX + 2];
        int m = fst_encode(r, re, sizeof re);
        if (m < 0 || (size_t)m != n + 1 || memcmp(re, line, n))
            return -1;
    }
    return 0;
}

static int is_marker(const char *ev)
{
    return !strcmp(ev, "t4") || !strcmp(ev, "t5") || !strcmp(ev, "a2") || !strcmp(ev, "a2-returned") ||
           !strcmp(ev, "gate");
}

int fst_scan(const char *buf, size_t n, struct fst *last, int *marker)
{
    size_t i = 0;
    int cnt = 0;
    *marker = 0;
    while (i < n) {
        size_t j = i;
        struct fst r;
        while (j < n && buf[j] != '\n' && buf[j] != 0)
            j++;
        if (j > i && !fst_parse(buf + i, j - i, &r)) {
            cnt++;
            *last = r;
            if (is_marker(r.ev))
                *marker = 1;
        }
        i = j + 1;
    }
    return cnt;
}

int fsn_encode(char out[FSN_LEN], unsigned long long seq, long long t, int ready, int tier, const char *notice,
               const char *last)
{
    char body[FSN_LEN];
    int n, m;
    n = snprintf(body, sizeof body, "FSN1 seq=%llu t=%lld ready=%d tier=%d n=%s last=%s", seq, t, ready, tier,
                 notice && notice[0] ? notice : "-", last && last[0] ? last : "-");
    if (n < 0 || n + 15 > FSN_LEN - 1)
        return -1;
    m = snprintf(out, FSN_LEN, "%s crc=%08x", body, fst_crc32(body, (size_t)n));
    memset(out + m, ' ', (size_t)(FSN_LEN - 1 - m));
    out[FSN_LEN - 1] = '\n';
    return 0;
}

int fsn_parse(const char *rec, size_t n, struct fsn *o)
{
    char tmp[FSN_LEN + 1], re[FSN_LEN];
    if (n != FSN_LEN || rec[FSN_LEN - 1] != '\n')
        return -1;
    memcpy(tmp, rec, FSN_LEN);
    tmp[FSN_LEN] = 0;
    memset(o, 0, sizeof *o);
    if (sscanf(tmp, "FSN1 seq=%llu t=%lld ready=%d tier=%d n=%63s last=%63s", &o->seq, &o->t, &o->ready, &o->tier,
               o->n, o->last) != 6)
        return -1;
    /* canonical form only: re-encoding must give the same 256 bytes (crc included) */
    if (fsn_encode(re, o->seq, o->t, o->ready, o->tier, o->n, o->last) || memcmp(re, rec, FSN_LEN))
        return -1;
    return 0;
}
