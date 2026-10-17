// SPDX-License-Identifier: Apache-2.0
// fs-thermald: device tables, active configuration and the pure decision
// core (CORE-SPEC.md). No I/O in this header's implementations except
// src/fs-thermald.c.
#ifndef FS_THERMALD_H
#define FS_THERMALD_H
#include <stdint.h>

#define UNSET ((int32_t)0x80000000)
#define MAXS 64     /* sensors in a device table */
#define MAXG 16     /* groups */
#define MAXR 32     /* fan rules */
#define MAXVIN 6
#define MAXK 8      /* known-firmware rows */
#define MAXTOK 96   /* output tokens per list */

enum cls { CL_SOC, CL_SKIN, CL_BATT, CL_USB, CL_BOARD, CL_PMIC, CL_AUX, CL_BCL, CL_N }; /* CL_PMIC: rev 7, K-50 */
enum kind { K_ZONE, K_PSY, K_AUX, K_JSON, K_IIO }; /* K_JSON: class-map only (not read); K_IIO: a zone read from IIO (K-50) */

/* ---------------- static device tables (src/thermald_tables.c) ---------------- */
struct cmap {
    const char *name;
    enum cls cls;
    const char *group;   /* NULL for AUX / JSON-only */
    enum kind kind;
    int slow, indep;
    const char *thr_ref; /* psy: whose thresholds apply */
    const char *vin[MAXVIN];
    int json;            /* expected in Meta's JSON (coverage, A-7) */
    int nmasks;
    uint8_t masks[3];    /* allowed set-slot masks, bit k = slot k */
    int32_t mult_num, mult_den;
    int32_t th[7], hy[7]; /* built-in fallback (§4.1 / F12) */
};

struct gdef { const char *name; enum cls cls; int min; };

struct fdef {           /* fan rule: zone, base sensor, per-trip level */
    const char *zone, *base;
    int ntrips;
    int lvl[4];
    int32_t t[4], h[4]; /* expected DT values (fixtures); runtime reads sysfs */
};

struct krow {           /* known-firmware row (hashes only) */
    const char *label, *incr, *json_sha, *digest, *vr_sha;
    uint32_t json_size;
};

struct devtab {
    const char *name;            /* eureka / hollywood */
    int adsp;
    int psy_period_ms;
    const struct cmap *cm; int ncm;
    const struct gdef *gd; int ngd;
    int has_fan;                 /* fan rules known */
    int fan_levels[8]; int nlevels; int fan_top, floor_p1, floor_tier[6];
    int rpm_per_sec, silent_rpm, max_pwm;
    const struct fdef *fr; int nfr;
    int has_caps;
    int32_t cpu[6];              /* kHz; -1 = cpuinfo_min_freq */
    int has_gpu; int gpu[6];
    const char *p5; int32_t p5_t;
    const struct krow *kr; int nkr;
    int max_rpm;                 /* DT max-rpm (F4, K-24) */
    const char *weak[4];         /* sensors that never contradict alone (K-29) */
    int npol; int pol[4];        /* cpufreq policies (K-30) */
};

const struct devtab *dev_lookup(const char *name);
const char *cls_name(enum cls c);

/* ---------------- active configuration (dump-config, CORE-SPEC §1) ---------------- */
struct sens {
    char name[32];
    enum cls cls;
    int group;              /* -1 none */
    enum kind kind;
    int slow, indep, weak;
    int32_t th[7], hy[7];
    int nvin; int vin[MAXVIN];
};
struct grp { char name[16]; enum cls cls; int min; };
struct frule { char zone[32]; int base; int ntrips; int32_t t[4], h[4]; int lvl[4]; };

struct conf {
    const struct devtab *dt;
    int stage;                       /* mode */
    char limits[16]; char reason[48];
    int psy_period_ms, adsp;
    int ns; struct sens s[MAXS];
    int ng; struct grp g[MAXG];
    int has_fan; int levels[8], nlevels, top, floor_p1, floor_tier[6], rpm_per_sec, silent_rpm, max_pwm;
    int nr; struct frule r[MAXR];
    int has_caps; int32_t cpu[6]; int has_gpu; int gpu[6];  /* cpu: -1 min, -2 none */
    int npol; int pol[4];
    int max_rpm, zone_fault;
    int p5; int32_t p5_t;
    int trial_override, headless_fan, batt_absent, p15, j145;
    int vr_export;
};

/* ---------------- core (src/thermald_core.c) ---------------- */
enum { RD_NUM = 0, RD_ERR = 1, RD_ABSENT = 2 };
struct rd { int st; int32_t v; };

enum { ST_CHARGING, ST_DISCHARGING, ST_NOTCHARGING, ST_FULL, ST_UNKNOWN, ST_ERR };

struct tick_in {
    int64_t t;
    struct rd s[MAXS];               /* zone/aux sensors (psy index ignored) */
    struct rd psy_temp, psy_volt, psy_curr, psy_cap; int psy_status;
    struct rd usb_online;
    int adsp;                        /* 1 running, 0 other, -1 ERR/ABSENT */
    int fan_absent; struct rd rpm, pwm, cur, max;
    int fan_wr_err, cap_fail, caps_ok_at_start, shutdown_byte, pid1_shutdown, a1_done, a2_exited;
    int pstore_marker;
};

struct sstate {
    int h;                 /* health this tick: 0 ok, 1 read, 2 low, 3 frozen, 4 hot, 5 rise */
    int usable; int32_t v; /* usable value this tick (carried for psy) */
    int have_prev; int32_t pv; int64_t pt;
    int have_fz; int32_t fz; int64_t fz_since; int32_t vmin[MAXVIN], vmax[MAXVIN]; int vhave[MAXVIN];
    int pending, n, contra, akind;
    int fault, freason; int64_t fault_since, ok_since;   /* ok_since -1 = none */
    int L; int64_t down_since;                          /* -1 none */
    int k27; int32_t k27v; int64_t k27since; int k27refh; int64_t k27ref;  /* K-27 */
    int k27stuck;                                                          /* K-40 latch */
};

struct cstate { int active; int64_t since, ok_since; int nonstuck; };  /* K-39 */

struct core {
    const struct conf *c;
    int first; int64_t t0;
    struct sstate s[MAXS];
    struct cstate cl[CL_N];
    int b_adsp, b_psy, b_stale; int64_t stale_start; int have_triple; int32_t trip3[3];
    int last_status; int64_t last_sample; int lowbatt;
    int64_t last_j145;
    /* fan */
    int fan_active[MAXR][4];
    int prev_target; int64_t allow_until; int have_prev_rpm; int32_t prev_rpm;
    int64_t f2, f3, f4, f5;          /* timer starts, -1 none */
    int ffault, fcode; int64_t fsince, fok_since;
    /* tier */
    int ready, selftest_fail; int tier; int64_t t3_since;
    int t4; int64_t t4_at; int t5; int64_t tf;
    int64_t tl0; int have_tl0;
    int sent_sig, sent_a1, sent_final, sent_a2, sent_sysrq, sent_term, sent_kill;
    int target;
    int j145c;                       /* K-17 */
    int64_t spin_until; int t_prev;  /* K-24 */
    int64_t t_change;                /* K-36 */
    int64_t f6_since; int fan_nonf6; /* K-34 */
    int imp_n; int64_t prev_rpm_t;   /* K-35 */
    unsigned imp_hist; int imp_cnt;  /* K-38: last 5 numeric-fan ticks */
    unsigned f6_hist;                /* K-41/K-44: C-23 tick condition, last 20 ticks (bit 0 newest) */
    int have_last_rpm; int32_t last_rpm; int32_t r0;  /* K-45 F5 previous reading; K-37/K-46 r0 */
    int32_t rpm3[3]; int rpm3ok[3];  /* K-46: rpm of the last three ticks (0 newest) */
    int64_t need;                    /* K-47: speed that ends a low F3 episode */
    int st_retry;                    /* K-48: self-test fan retries left */
    int64_t xexp, t_last;            /* K-43 continuous ramp expectation */
    int64_t cdev_start; int cdev_fired; int dlevel; /* K-31 */
    int nsev, nreason;               /* K-18: 0 none, 1 warn, 2 shutdown */
};

struct tick_out {
    int tier, ready, fan, cpu_min; int32_t cpu; int gpu;
    int nf; char f[MAXTOK][48];
    int ne; char e[MAXTOK][64];
    int na; char a[16][16];
    char notice[64];                 /* K-18 .. K-21 */
};

void core_init(struct core *k, const struct conf *c);
void core_tick(struct core *k, const struct tick_in *in, struct tick_out *o);
int core_gate(struct core *k, const struct tick_in *in, char *out, int cap);
void out_line(const struct tick_out *o, int64_t t, char *buf, int cap);

#endif
