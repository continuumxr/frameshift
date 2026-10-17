// SPDX-License-Identifier: Apache-2.0
#ifndef FS_THERMALD_ACCEPT_H
#define FS_THERMALD_ACCEPT_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include "thermald.h"

struct recview {
    unsigned status;
    uint32_t json_len, vr_len, dev_len, incr_len, n;
    const uint8_t *json, *vr, *dev, *incr, *ent;
};

struct accept_info {
    const struct krow *row;
    char json_sha[65], digest[65];
    int vr_export, fault_record;
};

int rec_view(const uint8_t *b, size_t n, struct recview *v);
long rec_expect(const uint8_t *hdr);
const char *rec_accept(const struct devtab *dt, const struct recview *v, struct accept_info *ai);
int conf_build(struct conf *c, const struct devtab *dt, const struct recview *v, int accepted);
void conf_drop_batt(struct conf *c);
void conf_dump(FILE *f, const struct conf *c);

#endif
