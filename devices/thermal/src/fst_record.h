/* SPDX-License-Identifier: Apache-2.0
 * FST1 records (EXEC-SPEC.md §4): the one-line pstore (pmsg) record of the
 * thermal service, written at the T4 latch and the later shutdown steps and
 * read by the next boot's gate (design §6.2, O19 marker; PLAN R48), and the
 * FSN1 notice record that the user-visible consumers poll (PLAN §2.1).
 * Pure functions: no I/O here.
 */
#ifndef FST_RECORD_H
#define FST_RECORD_H
#include <stddef.h>
#include <stdint.h>

#define FST_MAX 240   /* one pmsg write, well below the ramoops pmsg zone */
#define FSN_LEN 256   /* fixed-size notice record, '\n'-terminated */

uint32_t fst_crc32(const void *p, size_t n);

struct fst {
    char ev[16];      /* start t4 t5 a2 a2-returned gate */
    long long t;      /* ms, CLOCK_BOOTTIME of the writing boot */
    char reason[32];  /* notice reason (CORE-SPEC K-19) or - */
    char sensor[32];  /* cause sensor or - */
    char value[16];   /* its reading in m°C or - */
    char hot[48];     /* hottest counted sensor name:m°C or - */
    char why[64];     /* the t4/t5 event list, comma-joined, truncated, or - */
    int cd;           /* countdown seconds at the write, -1 none */
};

/* encode into buf (cap >= FST_MAX+1); returns length incl. '\n', or -1 */
int fst_encode(const struct fst *r, char *buf, size_t cap);
/* parse one line (without or with '\n'); 0 ok, -1 invalid (format or crc) */
int fst_parse(const char *line, size_t n, struct fst *r);
/* scan a pstore pmsg dump: the last valid record and whether any valid
 * record is a shutdown marker (ev t4, t5, a2, a2-returned or gate).
 * returns the number of valid records. */
int fst_scan(const char *buf, size_t n, struct fst *last, int *marker);

/* FSN1 notice record: exactly FSN_LEN bytes */
int fsn_encode(char out[FSN_LEN], unsigned long long seq, long long t, int ready, int tier, const char *notice,
               const char *last);
struct fsn {
    unsigned long long seq;
    long long t;
    int ready, tier;
    char n[64], last[64];
};
/* parse one FSN1 record (exactly FSN_LEN bytes); 0 ok, -1 invalid (format, crc, non-canonical) */
int fsn_parse(const char *rec, size_t n, struct fsn *o);
#endif
