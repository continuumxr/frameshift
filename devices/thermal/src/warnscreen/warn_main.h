/* SPDX-License-Identifier: Apache-2.0
 * fs-warnscreen main (EXEC-SPEC.md §8, PLAN R46): a consumer of the FSN1
 * notice record. Appended to the patched fs-pattern.c (warn.patch); the
 * stage-3d main() is renamed fsp_main() and is called unchanged, in a child,
 * for the reviewed "reset" and "show-off-quad" sequence of stage 3d, so every
 * DRM step, bound and log record is fs-pattern v0.7.1's. Only the picture
 * differs (warn_frame.h). A STATIC frame: one commit per display, held for
 * at most FSP_HOLD_MAX_S (10 s), then the fd is closed (lastclose disables
 * the pipe). At most WARN_MAX_SHOWS displays per run: the previous boot's
 * "last shutdown" (once, at start), the first warn, the first shutdown.
 *
 *   fs-warnscreen watch NONCE8 NOTICE_PATH [DEV]   (idle priority; never waited on)
 *   fs-warnscreen render-notice NOTICE LAST W H OUT.ppm   (offline frame fixture)
 *
 * The supervisor never waits for this process: it only pwrite()s the record.
 */
#undef main
#include <sched.h>
#include <stdio.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include "fst_record.h"

#define WARN_MAX_SHOWS 3
#define WARN_POLL_MS 250

struct wreason { const char *code, *text; };
static const struct wreason wreasons[] = {
	{"battery-overheating", "BATTERY OVERHEATING"}, {"skin-temperature-high", "HEADSET TOO HOT"},
	{"soc-temperature-high", "PROCESSOR TOO HOT"},  {"usb-connector-hot", "USB CONNECTOR HOT"},
	{"pmic-hot", "POWER CHIP HOT"},                 {"fan-failure", "FAN FAILURE"},
	{"battery-sensor-lost", "BATTERY SENSOR LOST"}, {"sensor-fault", "SENSOR FAULT"},
	{"sensor-anomaly", "SENSOR ANOMALY"},           {"battery-empty", "BATTERY EMPTY"},
	{"cap-write-failed", "SPEED LIMIT FAILED"},     {"self-test-failed", "SELF TEST FAILED"},
	{"battery-low", "BATTERY LOW"},                 {"charging-too-warm", "CHARGING TOO WARM"},
	{"shutdown-requested", "SHUTDOWN REQUESTED"},
};

static const char *wreason_text(const char *code)
{
	for (size_t i = 0; i < sizeof wreasons / sizeof wreasons[0]; i++)
		if (!strcmp(wreasons[i].code, code))
			return wreasons[i].text;
	return "THERMAL FAULT"; /* unknown code: wording maps in the consumer (PLAN 2.1 a) */
}

/* the lines for a notice "<sev>:<reason>[:<s>]" or, with notice "-", for LAST "<reason>:<m°C>" */
static int warn_set(const char *notice, const char *last)
{
	char sev[16] = "", rs[40] = "", tmp[64];
	char *a, *b;
	long secs = -1;
	memset(g_warn, 0, sizeof g_warn);
	if (notice && strcmp(notice, "-")) {
		snprintf(tmp, sizeof tmp, "%s", notice);
		a = strchr(tmp, ':');
		if (!a)
			return -1;
		*a++ = 0;
		b = strchr(a, ':');
		if (b) {
			*b++ = 0;
			secs = strtol(b, NULL, 10);
		}
		snprintf(sev, sizeof sev, "%s", tmp);
		snprintf(rs, sizeof rs, "%s", a);
		if (!strcmp(sev, "shutdown")) {
			snprintf(g_warn[0], sizeof g_warn[0], "SHUTTING DOWN");
			snprintf(g_warn[1], sizeof g_warn[1], "%s", wreason_text(rs));
			if (secs > 0 && secs < 100000)
				snprintf(g_warn[2], sizeof g_warn[2], "IN %ld S", secs);
			snprintf(g_warn[3], sizeof g_warn[3], "REMOVE HEADSET");
		} else if (!strcmp(sev, "warn")) {
			snprintf(g_warn[0], sizeof g_warn[0], "THERMAL WARNING");
			snprintf(g_warn[1], sizeof g_warn[1], "%s", wreason_text(rs));
			if (secs > 0 && secs < 100000)
				snprintf(g_warn[2], sizeof g_warn[2], "OFF IN %ld S", secs);
		} else
			return -1;
		return 0;
	}
	if (last && strcmp(last, "-")) {
		snprintf(tmp, sizeof tmp, "%s", last);
		a = strchr(tmp, ':');
		if (a)
			*a++ = 0;
		snprintf(g_warn[0], sizeof g_warn[0], "LAST SHUTDOWN");
		snprintf(g_warn[1], sizeof g_warn[1], "%s", wreason_text(tmp));
		if (a && a[0] >= '0' && a[0] <= '9') {
			long mc = strtol(a, NULL, 10);
			snprintf(g_warn[2], sizeof g_warn[2], "AT %ld C", mc / 1000);
		}
		return 0;
	}
	return -1;
}

/* one fs-pattern run in a child (it always ends in exit); returns its status */
static int warn_child(const char *mode, const char *nonce, const char *dev)
{
	pid_t p = fork();
	int st = 0;
	if (p < 0)
		return -1;
	if (p == 0) {
		char *av[8];
		int n = 0;
		av[n++] = (char *)"fs-warnscreen";
		av[n++] = (char *)mode;
		av[n++] = (char *)nonce;
		if (strcmp(mode, "reset")) {
			av[n++] = (char *)"10";
			av[n++] = (char *)dev;
			av[n++] = (char *)"roll=21";
			av[n++] = (char *)"eyes=swap";
		} else
			av[n++] = (char *)dev;
		av[n] = NULL;
		_exit(fsp_main(n, av));
	}
	while (waitpid(p, &st, 0) < 0)
		;
	return st;
}

static int warn_read(const char *path, struct fsn *f)
{
	char b[FSN_LEN];
	struct stat st;
	int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
	ssize_t n;
	if (fd < 0)
		return -1;
	if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
		close(fd);
		return -1;
	}
	n = pread(fd, b, sizeof b, 0);
	close(fd);
	if (n != FSN_LEN)
		return -1;
	return fsn_parse(b, FSN_LEN, f);
}

static int warn_watch(const char *nonce, const char *path, const char *dev)
{
	struct sched_param sp = {0};
	struct fsn f;
	int shows = 0, did_last = 0, did_warn = 0, did_down = 0, reset_done = 0;
	setpriority(PRIO_PROCESS, 0, 19);
	sched_setscheduler(0, SCHED_IDLE, &sp); /* best effort: below every other task */
	while (shows < WARN_MAX_SHOWS && !did_down) { /* nothing follows a shutdown display */
		const char *want = NULL;
		struct timespec ts = {0, WARN_POLL_MS * 1000000L};
		if (warn_read(path, &f) == 0) {
			if (!strncmp(f.n, "shutdown:", 9) && !did_down) {
				did_down = did_warn = did_last = 1;
				want = "show";
				warn_set(f.n, NULL);
			} else if (!strncmp(f.n, "warn:", 5) && !did_warn && !did_down) {
				did_warn = did_last = 1;
				want = "show";
				warn_set(f.n, NULL);
			} else if (!did_last && strcmp(f.last, "-")) {
				did_last = 1;
				want = "show";
				warn_set("-", f.last);
			}
		}
		if (want) {
			if (!reset_done) { /* stage 3d's r1: end the bootloader's continuous splash once */
				warn_child("reset", nonce, dev);
				reset_done = 1;
			}
			warn_child("show-off-quad", nonce, dev);
			shows++;
			continue;
		}
		nanosleep(&ts, NULL);
	}
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 7 && !strcmp(argv[1], "render-notice")) {
		char *av[7];
		if (warn_set(argv[2], argv[3]))
			return 2;
		av[0] = (char *)"fs-warnscreen";
		av[1] = (char *)"render";
		av[2] = (char *)"00000000";
		av[3] = argv[4];
		av[4] = argv[5];
		av[5] = argv[6];
		av[6] = NULL;
		return fsp_main(6, av);
	}
	if ((argc == 4 || argc == 5) && !strcmp(argv[1], "watch") && valid_nonce(argv[2]) && valid_path(argv[3]) &&
	    (argc == 4 || valid_path(argv[4])))
		return warn_watch(argv[2], argv[3], argc == 5 ? argv[4] : "/dev/dri/card0");
	fprintf(stderr, "usage: fs-warnscreen watch NONCE8 NOTICE [DEV] | render-notice NOTICE LAST W H OUT.ppm\n");
	return 2;
}
