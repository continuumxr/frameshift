/* SPDX-License-Identifier: Apache-2.0
 * fs-thermald executor (part 2; EXEC-SPEC.md): turns the decision core's
 * actions into device actions. The core stays pure (CORE-SPEC K-22): the
 * executor reads its output and the tick's inputs and never changes a
 * decision.
 *
 * Three kinds of build use this file:
 *   - device (FS_DEVICE, no FS_TEST): the real softdog ioctls, kill(1, 38),
 *     the actuators' sync()/fs_poweroff_final(), /proc/sysrq-trigger,
 *     /dev/pmsg0, /dev/kmsg; RT hardening;
 *   - device log-only (FS_DEVICE + FS_LOGONLY): no device write at all;
 *     no softdog, no actuator, no signal; actions are logged only;
 *   - test (FS_TEST, --exec-sim): the same code under a fake root, with the
 *     few kernel-facing calls replaced by logged stand-ins (EXEC-SPEC §6).
 */
#ifndef THERMALD_EXEC_H
#define THERMALD_EXEC_H
#include <stdint.h>
#include <sys/types.h>
#include "thermald.h"

#define FS_PID1_SIGNAL 38 /* literal: glibc SIGRTMIN+4 = systemd's poweroff.target request (E-11) */

enum { EX_TEST = 1, EX_DEVICE = 2 };

struct exec_cfg {
    int kind;                 /* EX_TEST or EX_DEVICE */
    const char *root;         /* EX_TEST: fake root prefix; device: "" */
    int stage;                /* C-39 stage timeline (S1 guard) */
    int logonly;              /* no device write of any kind */
    int softdog;              /* --softdog: open the softdog if download_mode reads 0 (Chair class) */
    int require_softdog;      /* --require-softdog: no published READY without it */
    int wd_margin, wd_final;  /* P17: running margin and M_final, seconds */
    int p15;
    int pid1;                 /* 1 on a device; the fake PID 1 in tests */
    const char *step_pgid_file;
    int gate;                 /* one-shot gate: no actuator, no FIFO; softdog only on a refusal */
};

struct exec {
    struct exec_cfg c;
    int wd;                   /* -1 closed */
    int wd_state;             /* 0 not requested, 1 open, -1 refused, -2 error */
    char wd_why[64];
    int wd_final_done, wd_pets;
    int pmsg, kmsg, comm, sysrq, ctl, notice, hb, xlog;
    int a1_cmd, a1_stat, a2_cmd;
    pid_t a1_pid, a2_pid;
    int a1_done, a2_sent, a2_exited, a2_dead_early, a1_dead_early, sb;
    unsigned long long seq;
    int tripped, ok;
    char why[96];             /* first reason the executor withholds READY */
    char last[64];            /* last shutdown of the previous boot (pstore), for display */
    int rec_t4, rec_t5, rec_a2, rec_a2r;
};

int exec_start(struct exec *x, const struct exec_cfg *cfg, const char *last);
void exec_inputs(struct exec *x, struct tick_in *in);
void exec_timeline(struct exec *x, const struct conf *c, const struct tick_in *in, const struct tick_out *o, int64_t t);
void exec_publish(struct exec *x, const struct tick_out *o, int64_t t);
void exec_pet(struct exec *x, const struct tick_out *o, int64_t t);
int exec_ready(const struct exec *x, const struct tick_out *o);
/* gate refusal (design §6.2): FST1 gate record and, if allowed, the softdog
 * armed with M_final, left open for PID 1's exec of fs-poweroff-final */
void exec_gate_refuse(struct exec *x, const struct conf *c, const struct tick_in *in, const char *reasons, int64_t t);
void exec_log(struct exec *x, int64_t t, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
#endif
