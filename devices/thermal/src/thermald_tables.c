// SPDX-License-Identifier: Apache-2.0
// fs-thermald device tables: class maps, built-in fallback thresholds,
// fan rules, caps and the known-firmware table (hashes only).
//
// Sources (each value is checked by tools/test_tables.py):
//  - fallback thresholds: emergency-shutdown-design.md §4.1 (Quest 3:
//    thermal-control-design.md §2.2; Quest 2: F12), equal to the values
//    parsed from the reviewed files (tables/derived/*.tsv, local check);
//  - fan levels and rules: thermal-control-design.md §1.3, §3.3 (Meta's
//    DT eureka-thermal.dtsi; trips are re-read from sysfs at start-up);
//  - caps: thermal-control-design.md §6.3 with P11 rejected (NORMAL = L4);
//  - P1/P4 floors, P5: thermal-control-design.md §0.1 (PM 2026-10-09);
//  - known rows: F31, F40 and the record digests in tables/known-firmware.tsv.
#include <string.h>
#include "thermald.h"

#define U UNSET
#define SOC_TH {U, 89000, 92000, 95000, U, U, 115000}
#define SOC_HY {0, 2000, 2000, 2000, 0, 0, 5000}
#define NO_TH {U, U, U, U, U, U, U}
#define M_LMSX 0x4E /* LIGHT MODERATE SEVERE SHUTDOWN */

#define Q3SOC(n, g) {n, CL_SOC, g, K_ZONE, 0, 1, NULL, {NULL}, 1, 1, {M_LMSX}, 1, 1000, SOC_TH, SOC_HY}
#define Q3BCL(n) {n, CL_BCL, NULL, K_JSON, 0, 0, NULL, {NULL}, 1, 1, {0x02}, 1, 1, NO_TH, NO_TH}
#define AUXZ(n) {n, CL_AUX, NULL, K_AUX, 0, 0, NULL, {NULL}, 0, 0, {0}, 1, 1000, NO_TH, NO_TH}
#define PMIC_TH {U, U, U, 95000, U, U, 115000} /* P7 */
#define PMIC_HY {0, 0, 0, 5000, 0, 0, 5000}
#define PMICD(n) {n, CL_PMIC, "pmic", K_IIO, 0, 0, NULL, {NULL}, 0, 1, {0x48}, 1, 1000, PMIC_TH, PMIC_HY}

static const struct cmap eureka_cm[] = {
    Q3SOC("cpu-0-0-0", "cpu0"), Q3SOC("cpu-0-0-1", "cpu0"), Q3SOC("cpu-0-1-0", "cpu0"), Q3SOC("cpu-0-1-1", "cpu0"),
    Q3SOC("cpu-1-0-0", "cpu1"), Q3SOC("cpu-1-0-1", "cpu1"), Q3SOC("cpu-1-1-0", "cpu1"), Q3SOC("cpu-1-1-1", "cpu1"),
    Q3SOC("cpu-1-2-0", "cpu1"), Q3SOC("cpu-1-2-1", "cpu1"), Q3SOC("cpu-1-3-0", "cpu1"), Q3SOC("cpu-1-3-1", "cpu1"),
    Q3SOC("cpuss-0", "cpuss"), Q3SOC("cpuss-1", "cpuss"),
    Q3SOC("gpuss-0", "gpu"), Q3SOC("gpuss-1", "gpu"), Q3SOC("gpuss-2", "gpu"), Q3SOC("gpuss-3", "gpu"),
    Q3SOC("gpuss-4", "gpu"), Q3SOC("gpuss-5", "gpu"), Q3SOC("gpuss-6", "gpu"), Q3SOC("gpuss-7", "gpu"),
    Q3SOC("nspss-0", "nsp"), Q3SOC("nspss-1", "nsp"), Q3SOC("nspss-2", "nsp"),
    /* soc-usr is typed SKIN by Meta but is our SoC class (F33, m6) */
    Q3SOC("soc-usr", "socth"),
    /* ddr (tsens0 sensor 15): monitored for faults only, no Meta threshold (review MINOR) */
    {"ddr", CL_SOC, "ddr", K_ZONE, 0, 1, NULL, {NULL}, 0, 1, {0}, 1, 1000, NO_TH, NO_TH},
    {"surf-virt-usr", CL_SKIN, "skin", K_ZONE, 1, 0, NULL, {"pcb1-usr", "pcb3-usr", "pogo-usr", "soc-usr"}, 1, 1,
     {M_LMSX}, 1, 1000, {U, 48000, 50000, 52000, U, U, 60000}, {0, 1000, 1000, 1000, 0, 0, 5000}},
    {"batt-virt-usr", CL_BATT, "bvirt", K_ZONE, 1, 0, NULL, {"pcb3-usr", "pogo-usr"}, 1, 1,
     {M_LMSX}, 1, 1000, {U, 58000, 61000, 63000, U, U, 65000}, {0, 2000, 2000, 1000, 0, 0, 1000}},
    {"psy-battery", CL_BATT, "bpsy", K_PSY, 1, 0, "batt-virt-usr", {NULL}, 0, 0, {0}, 1, 1000, NO_TH, NO_TH},
    /* usb-conn: v66 sets nothing, v2.7 LIGHT 70 (hyst 45); P5 >= 70 -> T4 stays ours */
    {"usb-conn", CL_USB, "usb", K_ZONE, 0, 0, NULL, {NULL}, 1, 2, {0x00, 0x02}, 1, 1000, NO_TH, NO_TH},
    Q3BCL("pm8550b-bcl-lvl0"), Q3BCL("pm8550b-bcl-lvl1"), Q3BCL("pm8550b-bcl-lvl2"),
    Q3BCL("pm8550b-ibat-lvl0"), Q3BCL("pm8550b-ibat-lvl1"),
    Q3BCL("pmxr2230-bcl-lvl0"), Q3BCL("pmxr2230-bcl-lvl1"), Q3BCL("pmxr2230-bcl-lvl2"),
    AUXZ("pcb1-usr"), AUXZ("pcb3-usr"), AUXZ("pogo-usr"),
    /* P7 (PM J-171 Q3, CORE-SPEC K-50..K-52): the PMIC die temperatures, our thresholds (never Meta's),
     * read from the vadc@9000 IIO channels by their DT labels (v27.dts:20777-20886), every die required */
    PMICD("pmk8550_die_temp"), PMICD("pmxr2230_die_temp"), PMICD("pm8550vs_c_die_temp"),
    PMICD("pm8550vs_d_die_temp"), PMICD("pm8550ve_die_temp"), PMICD("pm8550b_die_temp"),
    PMICD("pm8550b_lite_die_temp"),
};

static const struct gdef eureka_gd[] = {
    {"cpu0", CL_SOC, 1}, {"cpu1", CL_SOC, 1}, {"cpuss", CL_SOC, 0}, {"gpu", CL_SOC, 2},
    {"nsp", CL_SOC, 0}, {"socth", CL_SOC, 1}, {"skin", CL_SKIN, 1}, {"bvirt", CL_BATT, 1},
    {"bpsy", CL_BATT, 1}, {"usb", CL_USB, 1}, {"ddr", CL_SOC, 0}, {"pmic", CL_PMIC, 7},
};

#define TSF(z, b) {z, b, 4, {1, 2, 3, 4}, {60000, 75000, 80000, 85000}, {15000, 10000, 3000, 3000}}
static const struct fdef eureka_fr[] = {
    TSF("cpu-0-0-0-fan", "cpu-0-0-0"), TSF("cpu-0-0-1-fan", "cpu-0-0-1"), TSF("cpu-0-1-0-fan", "cpu-0-1-0"),
    TSF("cpu-0-1-1-fan", "cpu-0-1-1"), TSF("cpu-1-0-0-fan", "cpu-1-0-0"), TSF("cpu-1-0-1-fan", "cpu-1-0-1"),
    TSF("cpu-1-1-0-fan", "cpu-1-1-0"), TSF("cpu-1-1-1-fan", "cpu-1-1-1"), TSF("cpu-1-2-0-fan", "cpu-1-2-0"),
    TSF("cpu-1-2-1-fan", "cpu-1-2-1"), TSF("cpu-1-3-0-fan", "cpu-1-3-0"), TSF("cpu-1-3-1-fan", "cpu-1-3-1"),
    TSF("cpuss-0-fan", "cpuss-0"), TSF("cpuss-1-fan", "cpuss-1"),
    TSF("gpuss-0-fan", "gpuss-0"), TSF("gpuss-1-fan", "gpuss-1"), TSF("gpuss-2-fan", "gpuss-2"),
    TSF("gpuss-3-fan", "gpuss-3"), TSF("gpuss-4-fan", "gpuss-4"), TSF("gpuss-5-fan", "gpuss-5"),
    TSF("gpuss-6-fan", "gpuss-6"), TSF("gpuss-7-fan", "gpuss-7"),
    TSF("nspss-0-fan", "nspss-0"), TSF("nspss-1-fan", "nspss-1"), TSF("nspss-2-fan", "nspss-2"),
    {"soc-fan", "soc-usr", 4, {1, 2, 3, 4}, {60000, 75000, 80000, 85000}, {3000, 3000, 3000, 3000}},
    {"batt-virt-fan", "batt-virt-usr", 3, {2, 3, 4}, {45000, 49000, 53000}, {2000, 2000, 2000}},
    {"surf-virt-fan", "surf-virt-usr", 3, {2, 3, 4}, {42000, 44000, 46000}, {2000, 2000, 2000}},
};

static const struct krow eureka_kr[] = {
    {"eureka-v66", "50105190000000511", "e49b49fe2920cd8300a45598a8cc608ad31360a0eb3010092960cc5d4d294a89",
     "4e03bdb5cedf27dd3d7ac4b03653a940f9b80b5ad733457f548eeb3a4c0606ca",
     "674af9d5d27acf7b545d65273b4bad42f70cced44de5a5fe016ccb4304e7996a", 27284},
    {"eureka-v27", "52433670036000520", "c9301ff553f65255f7e204da9988345a0ecf1a5305099889db43ce1ab5473cd4",
     "bc0ee55048051fdd36a034a8beb51a1d540e42de961844d5fa5930585890f9bc",
     "d3a2ffa41e057cfa0bae0c657915a9350b76abb9da7f475631f59b504c3aa887", 27505},
};

/* ------------------------------- Quest 2 (hollywood) ------------------------------- */
#define Q2A_TH {U, U, U, 95000, U, U, 115000}
#define Q2A_HY {0, 0, 0, 5000, 0, 0, 5000}
#define Q2B_TH {U, 90000, U, 95000, U, U, 115000}
#define Q2B_HY {0, 5000, 0, 5000, 0, 0, 5000}
#define Q2A(n, g) {n, CL_SOC, g, K_ZONE, 0, 1, NULL, {NULL}, 1, 1, {0x48}, 1, 1000, Q2A_TH, Q2A_HY}
#define Q2B(n) {n, CL_SOC, "cpu1", K_ZONE, 0, 1, NULL, {NULL}, 1, 1, {0x4A}, 1, 1000, Q2B_TH, Q2B_HY}
#define Q2BRD(n, j) {n, CL_BOARD, "board", K_ZONE, 1, 1, NULL, {NULL}, j, 1, {0}, 1, 1000, NO_TH, NO_TH}

static const struct cmap hollywood_cm[] = {
    Q2A("cpu-0-0-usr", "cpu0"), Q2A("cpu-0-1-usr", "cpu0"), Q2A("cpu-0-2-usr", "cpu0"), Q2A("cpu-0-3-usr", "cpu0"),
    Q2B("cpu-1-0-usr"), Q2B("cpu-1-1-usr"), Q2B("cpu-1-2-usr"), Q2B("cpu-1-3-usr"),
    Q2B("cpu-1-4-usr"), Q2B("cpu-1-5-usr"), Q2B("cpu-1-6-usr"), Q2B("cpu-1-7-usr"),
    Q2A("cpuss-0-usr", "cpuss"), Q2A("cpuss-1-usr", "cpuss"),
    Q2A("gpuss-0-usr", "gpu"), Q2A("gpuss-1-usr", "gpu"),
    {"vrapi-pmem", CL_SOC, "pmem", K_ZONE, 0, 1, NULL, {NULL}, 1, 1, {0x08}, 1, 1000,
     {U, U, U, 95000, U, U, U}, {0, 0, 0, 5000, 0, 0, 5000}},
    {"vrapi-front-panel", CL_SKIN, "skin", K_ZONE, 1, 0, NULL, {NULL}, 1, 1, {M_LMSX}, 1, 1000,
     {U, 47000, 51000, 52000, U, U, 60000}, {0, 1000, 1000, 5000, 0, 0, 5000}},
    {"batt-virt", CL_BATT, "bvirt", K_ZONE, 1, 0, NULL, {NULL}, 1, 1, {0x4A}, 1, 1000,
     {U, 53000, U, 58000, U, U, 59000}, {0, 1000, 0, 3000, 0, 0, 1000}},
    {"psy-battery", CL_BATT, "bpsy", K_PSY, 1, 0, "batt-virt", {NULL}, 0, 0, {0}, 1, 1000, NO_TH, NO_TH},
    /* batt-usr: Meta's multiplier 0.1 (F33); JSON-only, no set slot */
    {"batt-usr", CL_BATT, NULL, K_JSON, 0, 0, NULL, {NULL}, 1, 1, {0x00}, 1, 10, NO_TH, NO_TH},
    Q2BRD("pcb1-usr", 0), Q2BRD("pcb2-usr", 0), Q2BRD("pcb3-usr", 0), Q2BRD("xo-therm-adc", 0),
};

static const struct gdef hollywood_gd[] = {
    {"cpu0", CL_SOC, 1}, {"cpu1", CL_SOC, 1}, {"cpuss", CL_SOC, 0}, {"gpu", CL_SOC, 1},
    {"pmem", CL_SOC, 0}, {"skin", CL_SKIN, 1}, {"bvirt", CL_BATT, 1}, {"bpsy", CL_BATT, 1},
    {"board", CL_BOARD, 1},
};

static const struct krow hollywood_kr[] = {
    {"hollywood-v27", "52242990024200150", "cc3e513784a468d2c322c2aa945a902850aedb354704d3ffb97cd9c697865147",
     "3145d7b03ea1029d2128fba66d5e1af1610ac9ac5d9c95f6fcfa3526cfd0efa7",
     "f525cc6a6cb50f4debded7c726906a4fd915c06d360d7a3063f5da22a45c1e3e", 16015},
};

#define N(a) ((int)(sizeof(a) / sizeof((a)[0])))

static const struct devtab tabs[] = {
    {
        .name = "eureka", .adsp = 1, .psy_period_ms = 5000,
        .cm = eureka_cm, .ncm = N(eureka_cm), .gd = eureka_gd, .ngd = N(eureka_gd),
        .has_fan = 1, .fan_levels = {0, 3700, 4500, 5000, 5500}, .nlevels = 5, .fan_top = 5500,
        .floor_p1 = 3700, .floor_tier = {0, 4500, 5000, 5500, 5500, 5500},
        .rpm_per_sec = 100, .silent_rpm = 4000, .max_pwm = 255,
        .fr = eureka_fr, .nfr = N(eureka_fr),
        .has_caps = 1, .cpu = {1920000, 1651200, 1382400, 1094400, -1, -1},
        .has_gpu = 1, .gpu = {3, 4, 6, 8, 9, 9},
        .p5 = "usb-conn", .p5_t = 70000,
        .kr = eureka_kr, .nkr = N(eureka_kr),
        .max_rpm = 8500, .weak = {"soc-usr"}, .npol = 2, .pol = {0, 2},
    },
    {
        /* Quest 2: fan rules, fan floors and caps are [O] (PLAN.md §8):
         * no fan rules -> no READY unless the image declares a headless
         * idle stage; no caps -> none written. */
        .name = "hollywood", .adsp = 0, .psy_period_ms = 2000,
        .cm = hollywood_cm, .ncm = N(hollywood_cm), .gd = hollywood_gd, .ngd = N(hollywood_gd),
        .has_fan = 0, .fan_levels = {0, 1000, 2000, 3000, 4000, 5000, 6000, 7000}, .nlevels = 8,
        .fan_top = 7000, .floor_p1 = 0, .floor_tier = {0, 0, 0, 7000, 7000, 7000},
        .rpm_per_sec = 0, .silent_rpm = 0, .max_pwm = 255,
        .fr = NULL, .nfr = 0,
        /* J-172: READY only as a headless idle stage; CPU "min" at T3-T5,
         * nothing written at T0-T2; policies 0/4/7 */
        .has_caps = 1, .cpu = {-2, -2, -2, -1, -1, -1}, .has_gpu = 0,
        .p5 = NULL, .p5_t = 0,
        .kr = hollywood_kr, .nkr = N(hollywood_kr),
        .max_rpm = 0, .npol = 3, .pol = {0, 4, 7},
    },
};

const struct devtab *dev_lookup(const char *name)
{
    int i;
    for (i = 0; i < N(tabs); i++)
        if (!strcmp(tabs[i].name, name))
            return &tabs[i];
    return NULL; /* Quest Pro, Quest 3S: no fallback -> never READY (A-9) */
}

const char *cls_name(enum cls c)
{
    static const char *n[CL_N] = {"SOC", "SKIN", "BATT", "USB", "BOARD", "PMIC", "AUX", "BCL"};
    return c < CL_N ? n[c] : "?";
}
