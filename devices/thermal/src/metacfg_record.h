// SPDX-License-Identifier: Apache-2.0
// The fs-metacfg record (METACFG-SPEC.md §6, M-27): shared by the reader
// (src/fs-metacfg.c) and the supervisor's acceptance (src/thermald_accept.c).
#ifndef FS_METACFG_RECORD_H
#define FS_METACFG_RECORD_H
#include <stdint.h>

#define MC_MAGIC "FSMC"
#define MC_VERSION 1
#define MC_HDR 64
#define MC_ENTRY 96
#define MC_MAX_JSON 65536
#define MC_MAX_VR 4096
#define MC_MAX_PROP 92
#define MC_MAX_ENTRIES 128
#define MC_UNSET ((int32_t)0x80000000)
#define MC_NAME 32
#define MC_MAX_RECORD (MC_HDR + MC_MAX_JSON + MC_MAX_VR + 2 * MC_MAX_PROP + MC_MAX_ENTRIES * MC_ENTRY)

/* record flags (header @40) */
#define MC_FLAG_SECCOMP_OFF 0x1
#define MC_FLAG_UPDATED 0x2 /* rev 2: never set, an UPDATED vendor is refused (vab-updated) */

/* status codes: METACFG-SPEC §6, stable, never renumbered */
#define MC_STATUS_LIST(X) \
    X(1, "arg") X(2, "no-super") X(3, "super-ambiguous") X(4, "super-type") X(5, "super-size") \
    X(6, "slot") X(7, "seccomp") X(8, "io") X(9, "read-budget") X(10, "lp-geometry") \
    X(11, "lp-header") X(12, "lp-checksum") X(13, "lp-tables") X(14, "lp-blockdev") \
    X(15, "lp-name") X(16, "vab-merge") X(17, "no-vendor") X(18, "vendor-dup") \
    X(19, "vendor-disabled") X(20, "extent-type") X(21, "fs-type") X(22, "ext4-blocksize") \
    X(23, "ext4-features") X(24, "ext4-inode-size") X(25, "ext4-geometry") X(26, "ext4-size") \
    X(27, "ext4-inode") X(28, "ext4-range") X(29, "ext4-inode-flags") X(30, "ext4-isize") \
    X(31, "ext4-extent-magic") X(32, "ext4-extent-count") X(33, "ext4-extent-depth") \
    X(34, "ext4-uninit") X(35, "ext4-hole") X(36, "ext4-notdir") X(37, "ext4-dirent") \
    X(38, "ext4-dir-cap") X(39, "file-missing") X(40, "file-type") X(41, "file-size") \
    X(42, "buildprop") X(43, "json-syntax") X(44, "json-depth") X(45, "json-dupkey") \
    X(46, "json-unknown-key") X(47, "json-number") X(48, "json-vr") X(49, "json-monitor") \
    X(50, "json-name") X(51, "json-dupname") X(52, "json-count") X(53, "json-slots") \
    X(54, "json-type") X(55, "extent-source") X(56, "extent-range") X(57, "vab-device")     X(58, "lp-flags") X(59, "vab-cow-group") X(60, "overlay") X(61, "vab-updated") X(62, "lp-attr") \
    X(63, "vab-policy")

enum mc_status {
    MC_OK = 0,
#define X(n, s) MC_S_##n = n,
    MC_STATUS_LIST(X)
#undef X
};

static inline const char *mc_status_name(unsigned code)
{
    switch (code) {
    case 0:
        return "ok";
#define X(n, s) \
    case n:     \
        return s;
        MC_STATUS_LIST(X)
#undef X
    default:
        return "unknown";
    }
}

static inline uint16_t mc_rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t mc_rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline uint64_t mc_rd64(const uint8_t *p) { return (uint64_t)mc_rd32(p) | (uint64_t)mc_rd32(p + 4) << 32; }
static inline void mc_wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void mc_wr32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

#endif
