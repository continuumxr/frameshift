/*
 * fs-supervise — run ONE child under bounded, fully reported supervision.
 *
 * FrameShift shared PID-1 infrastructure (devices/quest3/common), answering
 * FS-R-006 §5 A (controlled child environment, absolute paths) and §5 C
 * (verified kill escalation; an exit status such as 143 is never the only
 * evidence that the timer fired). Revision 2: adversarial review fixes
 * B2, S1-S4 and nits (see README "Review fixes").
 *
 *   fs-supervise -t SECS [-g SECS] [-c BYTES] [-i INFILE] -o OUTFILE -r ERRFILE
 *                [-e KEY=VAL]... -- /ABS/PROG [ARG]...
 *
 * Guarantees (each has a fixture in tools/fixtures-supervise*.sh):
 *   - PROG must be an absolute path; execve() directly (no PATH search);
 *     PROG is also argv[0]. Each option at most once (-e repeatable).
 *   - The child environment is EMPTY unless -e KEY=VAL is given. Loader-,
 *     libc-, malloc- and locale-affecting names are refused (glibc list from
 *     T1-PINS §3, plus bionic/musl names), as are duplicates.
 *   - The child: new session (setsid: no controlling tty, own process group),
 *     stdin /dev/null or -i INFILE (a regular file, never a tty), stdout and
 *     stderr pipes, every other fd closed (close_range, loop fallback),
 *     cwd "/", umask 077, RLIMIT_CORE 0, all signal dispositions default and
 *     the mask empty, PR_SET_PDEATHSIG SIGKILL.
 *   - fs-supervise itself starts by resetting SIGCHLD and SIGALRM to default
 *     and unblocking them (an inherited SIG_IGN would break reaping or the
 *     self-backstop).
 *   - stdout/stderr are captured into OUTFILE/ERRFILE (fresh: O_EXCL|
 *     O_NOFOLLOW, 0600), at most CAP bytes each; the rest is drained and
 *     counted. Reading is done in bounded bursts (64 KiB or 10 ms per stream)
 *     with the clock checked between bursts, so fast writers cannot starve
 *     the deadline.
 *   - Deadline: CLOCK_MONOTONIC at fork + SECS -> SIGTERM to the child's
 *     process group; GRACE s after the TERM was actually sent -> SIGKILL to
 *     the group; 3 s after the KILL was actually sent -> give up (unreaped).
 *   - Child subreaper: after the child is reaped, every descendant still
 *     alive is hunted: the child's process group, then via /proc every
 *     process reparented to us and every process in the session of the child
 *     or of a found descendant (catches setsid escapees); the process group
 *     of every process found is then killed as a whole on every round, which
 *     a fork-hopper cannot outrun.
 *     Whether any descendant is still alive afterwards is known exactly
 *     without /proc (waitpid(-1, WNOHANG) == 0 means a live child of ours,
 *     and every live descendant has a live ancestor that is our child) and
 *     is reported as why=strays-alive (or why=no-proc if /proc was not
 *     available to kill it).
 *   - Compiled-in limits: SECS <= 60, GRACE <= 10, CAP <= 1 MiB; an alarm()
 *     backstop (90 s) ends fs-supervise itself if its own loop ever hangs.
 *   - NOT bounded by fs-supervise: a child running as the same uid (root on
 *     the device) can SIGSTOP fs-supervise itself. A stopped process does
 *     not act on its alarm until continued, so then only the PID 1 deadline
 *     (pid1-hold.sh) bounds the run.
 *
 * Report: exactly one line on stdout, one write():
 *   FSUP1 end=E code=C sig=S errno=N ms=M term_ms=T kill_ms=K
 *         out_total=A out_kept=B err_total=X err_kept=Y strays=Z pipes=P why=W END
 *   end   exited | signaled | timer-term | timer-kill | exec-failed |
 *         unreaped | refused | internal
 *   why   none | strays-alive | no-proc | capture-write-failed | (refusal and
 *         internal reasons). Priority when several apply:
 *         strays-alive/no-proc > capture-write-failed.
 *   strays  descendants (other than the child) reaped by fs-supervise
 *
 * Exit status: exited 0, signaled 2, timer-term 3, timer-kill 4,
 * exec-failed 5, unreaped 6, descendants left alive 7 (overrides 0-5),
 * refused 64, internal 70. The report line is the evidence.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* ---- compiled-in limits (reviewable constants) ---------------------------- */
#define MAX_TIMEOUT_S     60
#define MAX_GRACE_S       10
#define DEFAULT_GRACE_S    2
#define MAX_CAP          (1024 * 1024)
#define DEFAULT_CAP      (64 * 1024)
#define REAP_WAIT_MS     3000      /* after SIGKILL was sent, before "unreaped" */
#define STRAY_WAIT_MS    3000      /* hunting strays after the child is reaped  */
#define DRAIN_MS         1000      /* waiting for pipe EOF after cleanup        */
#define POLL_SLICE_MS     20
#define BURST_BYTES      (64 * 1024)  /* per stream per wakeup */
#define BURST_MS          10
#define MAX_ENV           16
#define MAX_ARGS          32
#define MAX_PATH_LEN     255
#define MAX_VAL_LEN      256
#define MAX_SIDS          64
#define BACKSTOP_S (MAX_TIMEOUT_S + MAX_GRACE_S + 20)   /* alarm() on ourselves */

enum { X_EXITED = 0, X_SIGNALED = 2, X_TERM = 3, X_KILL = 4, X_EXECFAIL = 5,
       X_UNREAPED = 6, X_STRAYS = 7, X_REFUSED = 64, X_INTERNAL = 70 };

/* ---- the report ------------------------------------------------------------ */
static struct {
	const char *end;
	int code, sig, err;
	long long ms, term_ms, kill_ms;
	unsigned long long out_total, out_kept, err_total, err_kept;
	int strays;
	const char *pipes;
	const char *why;
} R = { "internal", -1, 0, 0, -1, -1, -1, 0, 0, 0, 0, 0, "none", "none" };

static int report(int status)
{
	char line[512];
	int n = snprintf(line, sizeof line,
		"FSUP1 end=%s code=%d sig=%d errno=%d ms=%lld term_ms=%lld kill_ms=%lld "
		"out_total=%llu out_kept=%llu err_total=%llu err_kept=%llu strays=%d "
		"pipes=%s why=%s END\n",
		R.end, R.code, R.sig, R.err, R.ms, R.term_ms, R.kill_ms,
		R.out_total, R.out_kept, R.err_total, R.err_kept, R.strays, R.pipes, R.why);
	if (n <= 0 || n >= (int)sizeof line)
		status = X_INTERNAL;
	else if (write(1, line, (size_t)n) != n)
		status = X_INTERNAL;
	alarm(0);                         /* only after the report is out */
	return status;
}

static int refuse(const char *why)
{
	R.end = "refused";
	R.why = why;
	return report(X_REFUSED);
}

static int internal(const char *why)
{
	R.end = "internal";
	R.why = why;
	return report(X_INTERNAL);
}

/* ---- helpers --------------------------------------------------------------- */
static long long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* strict decimal: 1..7 digits, no sign, no leading zero unless "0" */
static int parse_uint(const char *s, long *out)
{
	size_t n = strlen(s);
	if (n == 0 || n > 7)
		return -1;
	if (n > 1 && s[0] == '0')
		return -1;
	long v = 0;
	for (size_t i = 0; i < n; i++) {
		if (s[i] < '0' || s[i] > '9')
			return -1;
		v = v * 10 + (s[i] - '0');
	}
	*out = v;
	return 0;
}

/* absolute, short, no empty/"."/".." components, printable, no trailing '/' */
static int abs_path_ok(const char *p)
{
	size_t n = strlen(p);
	if (n < 2 || n > MAX_PATH_LEN || p[0] != '/' || p[n - 1] == '/')
		return 0;
	for (size_t i = 0; i < n; i++)
		if ((unsigned char)p[i] <= 0x20 || (unsigned char)p[i] >= 0x7f)
			return 0;
	const char *c = p;
	while (*c) {                      /* c points at a '/' */
		const char *s = c + 1, *e = strchr(s, '/');
		size_t len = e ? (size_t)(e - s) : strlen(s);
		if (len == 0 || (len == 1 && s[0] == '.') || (len == 2 && s[0] == '.' && s[1] == '.'))
			return 0;
		if (!e)
			break;
		c = e;
	}
	return 1;
}

/* Names that change the loader, libc, malloc, locale or coreutils behaviour:
 * glibc (T1-PINS §3, evidence/ldso-envvars.txt), plus bionic and musl names
 * for completeness. */
static const char *const refused_prefix[] = { "LD_", "MALLOC_", "LC_", "GLIBC_", NULL };
static const char *const refused_exact[] = {
	"GCONV_PATH", "GETCONF_DIR", "GMON_OUTPUT_PREFIX", "HOSTALIASES",
	"LOCALDOMAIN", "LOCPATH", "NIS_PATH", "NLSPATH", "RESOLV_HOST_CONF",
	"RES_OPTIONS", "TMPDIR", "TZ", "TZDIR", "LANG", "LANGUAGE",
	"POSIXLY_CORRECT", "_POSIX2_VERSION",
	"SCUDO_OPTIONS", "LIBC_DEBUG_MALLOC_OPTIONS", "LIBC_DEBUG_MALLOC_ENABLE",
	"LIBC_HOOKS_ENABLE", "MUSL_LOCPATH", NULL };

/* returns NULL if acceptable, else a reason token */
static const char *env_check(const char *kv, char *const *seen, int nseen)
{
	const char *eq = strchr(kv, '=');
	if (!eq || eq == kv)
		return "env-syntax";
	size_t klen = (size_t)(eq - kv);
	if (klen > 64)
		return "env-syntax";
	for (size_t i = 0; i < klen; i++) {
		char c = kv[i];
		int ok = (c == '_') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
			 (i > 0 && c >= '0' && c <= '9');
		if (!ok)
			return "env-syntax";
	}
	const char *val = eq + 1;
	size_t vlen = strlen(val);
	if (vlen > MAX_VAL_LEN)
		return "env-syntax";
	for (size_t i = 0; i < vlen; i++)
		if ((unsigned char)val[i] < 0x20 || (unsigned char)val[i] >= 0x7f)
			return "env-syntax";
	for (int i = 0; refused_prefix[i]; i++)
		if (strncmp(kv, refused_prefix[i], strlen(refused_prefix[i])) == 0)
			return "env-refused";
	for (int i = 0; refused_exact[i]; i++)
		if (strlen(refused_exact[i]) == klen && strncmp(kv, refused_exact[i], klen) == 0)
			return "env-refused";
	for (int i = 0; i < nseen; i++)
		if (strncmp(seen[i], kv, klen + 1) == 0)
			return "env-duplicate";
	return NULL;
}

static int open_out(const char *path)
{
	return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY, 0600);
}

/* one captured stream */
struct stream {
	int rfd;                     /* pipe read end, -1 when EOF */
	int wfd;                     /* capture file */
	long cap;
	unsigned long long total, kept;
	int write_failed;
};

/* one bounded burst: at most BURST_BYTES and BURST_MS, then back to the clock */
static void pump(struct stream *s)
{
	char buf[4096];
	size_t got = 0;
	long long t_end = now_ms() + BURST_MS;
	while (got < BURST_BYTES) {
		ssize_t n = read(s->rfd, buf, sizeof buf);
		if (n > 0) {
			got += (size_t)n;
			s->total += (unsigned long long)n;
			if (!s->write_failed && s->kept < (unsigned long long)s->cap) {
				size_t room = (size_t)((unsigned long long)s->cap - s->kept);
				size_t want = (size_t)n < room ? (size_t)n : room, done = 0;
				while (done < want) {
					ssize_t w = write(s->wfd, buf + done, want - done);
					if (w < 0 && errno == EINTR)
						continue;
					if (w <= 0) { s->write_failed = 1; break; }
					done += (size_t)w;
				}
				s->kept += done;
			}
			if (now_ms() >= t_end)
				return;
			continue;
		}
		if (n == 0) {                /* EOF */
			close(s->rfd);
			s->rfd = -1;
			return;
		}
		if (errno == EINTR)
			continue;
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return;
		close(s->rfd);               /* unexpected read error: stop reading */
		s->rfd = -1;
		return;
	}
}

/* poll the open streams (and the exec-error pipe) for at most ms */
static void wait_io(struct stream *o, struct stream *e, int *xfd, int *xerr, int ms)
{
	struct pollfd p[3];
	int n = 0, io = -1, ie = -1, ix = -1;
	if (o->rfd >= 0) { p[n].fd = o->rfd; p[n].events = POLLIN; io = n++; }
	if (e->rfd >= 0) { p[n].fd = e->rfd; p[n].events = POLLIN; ie = n++; }
	if (*xfd >= 0)   { p[n].fd = *xfd;   p[n].events = POLLIN; ix = n++; }
	if (ms < 0)
		ms = 0;
	if (n == 0) {
		struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
		nanosleep(&ts, NULL);
		return;
	}
	int r = poll(p, (nfds_t)n, ms);
	if (r <= 0)
		return;
	if (io >= 0 && p[io].revents) pump(o);
	if (ie >= 0 && p[ie].revents) pump(e);
	if (ix >= 0 && p[ix].revents) {
		int v = 0;
		ssize_t k = read(*xfd, &v, sizeof v);
		if (k == (ssize_t)sizeof v)
			*xerr = v ? v : EIO;
		if (k <= 0 || k == (ssize_t)sizeof v) {   /* EOF = exec succeeded */
			close(*xfd);
			*xfd = -1;
		}
	}
}

/* signal a process group, falling back to the pid if the group does not
 * exist yet (the child calls setsid() right after fork) */
static void kill_group(pid_t pid, int sig)
{
	if (kill(-pid, sig) != 0)
		kill(pid, sig);
}

/* Sessions whose members are hunted after the child is reaped. */
static long sids[MAX_SIDS];
static int nsids;
static void add_sid(long sid)
{
	for (int i = 0; i < nsids; i++)
		if (sids[i] == sid)
			return;
	if (nsids < MAX_SIDS)
		sids[nsids++] = sid;
}

/* Process groups seen among the strays: re-killed as whole groups every
 * round (kill(-pgrp) is atomic in the kernel, so a fork-hopper inside the
 * group cannot outrun it the way it can outrun a /proc scan). */
static long pgids[MAX_SIDS];
static int npgids;
static void add_pgid(long pg, long own_pgrp)
{
	if (pg <= 1 || pg == own_pgrp)
		return;
	for (int i = 0; i < npgids; i++)
		if (pgids[i] == pg)
			return;
	if (npgids < MAX_SIDS)
		pgids[npgids++] = pg;
}

/* SIGKILL every known stray group, then (via /proc) every process
 * reparented to us and every process in a hunted session, remembering their
 * groups. Returns -1 if /proc cannot be read, else how many were found. */
static int hunt(pid_t self, long own_sid, long own_pgrp)
{
	for (int i = 0; i < npgids; i++)
		kill((pid_t)-pgids[i], SIGKILL);
	DIR *d = opendir("/proc");
	if (!d)
		return -1;
	int n = 0, found_proc = 0;
	struct dirent *de;
	while ((de = readdir(d)) != NULL) {
		long pid;
		if (parse_uint(de->d_name, &pid) != 0 || pid <= 1 || pid == self)
			continue;
		found_proc = 1;
		char path[64], buf[512];
		snprintf(path, sizeof path, "/proc/%ld/stat", pid);
		int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
		if (fd < 0)
			continue;
		ssize_t k = read(fd, buf, sizeof buf - 1);
		close(fd);
		if (k <= 0)
			continue;
		buf[k] = 0;
		char *rp = strrchr(buf, ')');          /* comm may contain spaces */
		if (!rp)
			continue;
		char st;
		long ppid, pgrp, sid;
		if (sscanf(rp + 1, " %c %ld %ld %ld", &st, &ppid, &pgrp, &sid) != 4)
			continue;
		if (st == 'Z')
			continue;
		int in_sid = 0;
		for (int i = 0; i < nsids; i++)
			if (sids[i] == sid && sid != own_sid)
				in_sid = 1;
		if (ppid == (long)self || in_sid) {
			if (sid != own_sid)
				add_sid(sid);            /* its session-mates go too */
			add_pgid(pgrp, own_pgrp);
			if (pgrp > 1 && pgrp != own_pgrp)
				kill((pid_t)-pgrp, SIGKILL);
			kill((pid_t)pid, SIGKILL);
			n++;
		}
	}
	closedir(d);
	return found_proc ? n : -1;              /* an empty /proc is no /proc */
}

static void classify(int st)
{
	if (WIFEXITED(st)) { R.code = WEXITSTATUS(st); R.sig = 0; }
	else if (WIFSIGNALED(st)) { R.code = -1; R.sig = WTERMSIG(st); }
}

static void close_from(int lo)
{
#ifdef SYS_close_range
	if (syscall(SYS_close_range, (unsigned)lo, ~0U, 0) == 0)
		return;
#endif
	long max = sysconf(_SC_OPEN_MAX);
	if (max < 0 || max > 65536)
		max = 65536;
	for (long fd = lo; fd < max; fd++)
		close((int)fd);
}

int main(int argc, char **argv)
{
	long timeout = -1, grace = -1, cap = -1;
	const char *in = NULL, *outp = NULL, *errp = NULL;
	char *envv[MAX_ENV + 1];
	int nenv = 0, i = 1;

	/* S3: our own SIGCHLD/SIGALRM must work whatever we inherited */
	signal(SIGCHLD, SIG_DFL);
	signal(SIGALRM, SIG_DFL);
	{
		sigset_t u;
		sigemptyset(&u);
		sigaddset(&u, SIGCHLD);
		sigaddset(&u, SIGALRM);
		sigprocmask(SIG_UNBLOCK, &u, NULL);
	}
	signal(SIGPIPE, SIG_IGN);

	/* ---- strict argument parsing (no getopt: it reads POSIXLY_CORRECT) ---- */
	for (; i < argc; i++) {
		const char *a = argv[i];
		if (strcmp(a, "--") == 0) { i++; break; }
		if (a[0] != '-' || a[1] == 0 || a[2] != 0)
			return refuse("usage");
		if (i + 1 >= argc)
			return refuse("usage");
		const char *v = argv[++i];
		switch (a[1]) {
		case 't': if (timeout != -1 || parse_uint(v, &timeout)) return refuse("usage"); break;
		case 'g': if (grace != -1 || parse_uint(v, &grace)) return refuse("usage"); break;
		case 'c': if (cap != -1 || parse_uint(v, &cap)) return refuse("usage"); break;
		case 'i': if (in) return refuse("usage"); in = v; break;
		case 'o': if (outp) return refuse("usage"); outp = v; break;
		case 'r': if (errp) return refuse("usage"); errp = v; break;
		case 'e': {
			if (nenv >= MAX_ENV) return refuse("env-too-many");
			const char *why = env_check(v, envv, nenv);
			if (why) return refuse(why);
			envv[nenv++] = (char *)v;
			break;
		}
		default: return refuse("usage");
		}
	}
	envv[nenv] = NULL;
	if (grace == -1) grace = DEFAULT_GRACE_S;
	if (cap == -1) cap = DEFAULT_CAP;
	if (!in) in = "/dev/null";
	if (timeout == -1 || !outp || !errp || i >= argc)
		return refuse("usage");
	if (timeout < 1 || timeout > MAX_TIMEOUT_S) return refuse("timeout-range");
	if (grace < 1 || grace > MAX_GRACE_S)      return refuse("grace-range");
	if (cap > MAX_CAP)                         return refuse("cap-range");
	if (argc - i > MAX_ARGS)                   return refuse("too-many-args");
	if (!abs_path_ok(argv[i]))                 return refuse("prog-not-absolute");
	if (!abs_path_ok(in) || !abs_path_ok(outp) || !abs_path_ok(errp))
		return refuse("path-not-absolute");
	if (strcmp(outp, errp) == 0)               return refuse("same-capture-file");

	/* ---- stdin: /dev/null (char 1:3) or a regular file; never a tty ---- */
	int infd = open(in, O_RDONLY | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
	if (infd < 0)
		return refuse("stdin-open");
	struct stat sb;
	if (fstat(infd, &sb) != 0)
		return refuse("stdin-open");
	int is_null = S_ISCHR(sb.st_mode) && major(sb.st_rdev) == 1 && minor(sb.st_rdev) == 3;
	if (!S_ISREG(sb.st_mode) && !is_null)
		return refuse("stdin-not-file");
	fcntl(infd, F_SETFL, 0);           /* regular file / null: blocking reads are fine */

	int ofd = open_out(outp);
	if (ofd < 0) return refuse("out-open");
	int efd = open_out(errp);
	if (efd < 0) return refuse("err-open");

	int po[2], pe[2], px[2];
	if (pipe2(po, O_CLOEXEC) || pipe2(pe, O_CLOEXEC) || pipe2(px, O_CLOEXEC))
		return internal("pipe");

	if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0)
		return internal("subreaper");

	alarm(BACKSTOP_S);              /* our own backstop: default action kills us */

	pid_t self = getpid();
	long own_sid = (long)getsid(0);
	long own_pgrp = (long)getpgrp();
	char **cargv = &argv[i];
	long long t0 = now_ms();
	pid_t pid = fork();
	if (pid < 0)
		return internal("fork");

	if (pid == 0) {
		/* ---------------- child ---------------- */
		int e;
		setsid();                                  /* S2: no ctty, own group */
		prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0);
		if (getppid() != self)
			_exit(127);
		for (int s = 1; s < NSIG; s++)
			if (s != SIGKILL && s != SIGSTOP)
				signal(s, SIG_DFL);
		sigset_t none;
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		alarm(0);
		struct rlimit rl = { 0, 0 };
		setrlimit(RLIMIT_CORE, &rl);
		umask(077);
		/* fds: 0,1,2 as specified; the exec-error pipe moved to 3; S1: all else closed */
		if (chdir("/") != 0 || dup2(infd, 0) < 0 || dup2(po[1], 1) < 0 || dup2(pe[1], 2) < 0 ||
		    dup2(px[1], 3) < 0 || fcntl(3, F_SETFD, FD_CLOEXEC) != 0) {
			e = errno ? errno : EIO;
			(void)!write(px[1], &e, sizeof e);
			_exit(127);
		}
		close_from(4);
		execve(cargv[0], cargv, envv);
		e = errno ? errno : EIO;
		(void)!write(3, &e, sizeof e);
		_exit(127);
	}

	/* ---------------- parent ---------------- */
	add_sid((long)pid);                    /* the child's own session */
	close(po[1]); close(pe[1]); close(px[1]); close(infd);
	fcntl(po[0], F_SETFL, O_NONBLOCK);
	fcntl(pe[0], F_SETFL, O_NONBLOCK);
	struct stream so = { po[0], ofd, cap, 0, 0, 0 };
	struct stream se = { pe[0], efd, cap, 0, 0, 0 };
	int xfd = px[0], xerr = 0, st = 0, reaped = 0;
	long long deadline = t0 + timeout * 1000;
	long long kill_at = -1, give_up = -1;  /* set from when TERM / KILL were actually sent */

	/* phase A: until the child is reaped (or it cannot be) */
	for (;;) {
		pid_t r = waitpid(pid, &st, WNOHANG);
		long long t = now_ms();
		if (r == pid) { reaped = 1; R.ms = t - t0; break; }
		if (R.term_ms < 0 && t >= deadline) {
			kill_group(pid, SIGTERM);
			t = now_ms();
			R.term_ms = t - t0;
			kill_at = t + grace * 1000;
		} else if (R.term_ms >= 0 && R.kill_ms < 0 && t >= kill_at) {
			kill_group(pid, SIGKILL);
			t = now_ms();
			R.kill_ms = t - t0;
			give_up = t + REAP_WAIT_MS;
		} else if (R.kill_ms >= 0 && t >= give_up) {
			R.ms = t - t0;
			break;
		}
		long long next = R.term_ms < 0 ? deadline : R.kill_ms < 0 ? kill_at : give_up;
		long long slice = next - t;
		if (slice > POLL_SLICE_MS) slice = POLL_SLICE_MS;
		wait_io(&so, &se, &xfd, &xerr, (int)slice);
	}
	/* a pending exec-failure report: once the child is reaped its end of the
	 * pipe is closed, so this is EOF or the errno (bounded anyway) */
	{
		long long xstop = now_ms() + 500;
		while (xfd >= 0 && reaped && now_ms() < xstop)
			wait_io(&so, &se, &xfd, &xerr, POLL_SLICE_MS);
		if (xfd >= 0) { close(xfd); xfd = -1; }
	}

	if (!reaped) {
		R.end = "unreaped";
	} else {
		classify(st);
		if (xerr) { R.end = "exec-failed"; R.err = xerr; }
		else if (R.kill_ms >= 0) R.end = "timer-kill";
		else if (R.term_ms >= 0) R.end = "timer-term";
		else if (WIFSIGNALED(st)) R.end = "signaled";
		else R.end = "exited";
	}

	/* phase B: strays. The group, then (via /proc) reparented processes and
	 * hunted sessions; repeat until nobody is left or time is up. */
	int noproc = 0;
	kill(-pid, SIGKILL);
	long long stop = now_ms() + STRAY_WAIT_MS;
	for (;;) {
		pid_t r;
		while ((r = waitpid(-1, NULL, WNOHANG)) > 0)
			if (r != pid) R.strays++;
		if (r < 0 && errno == ECHILD)
			break;                       /* no descendant is alive */
		if (now_ms() >= stop)
			break;
		kill(-pid, SIGKILL);
		if (hunt(self, own_sid, own_pgrp) < 0)
			noproc = 1;
		wait_io(&so, &se, &xfd, &xerr, 10);
	}
	/* exact, /proc-free check: a live child of ours means a live descendant */
	int alive = 0;
	{
		pid_t r;
		while ((r = waitpid(-1, NULL, WNOHANG)) > 0)   /* reap every zombie first */
			if (r != pid) R.strays++;
		alive = (r == 0);                               /* 0: a live child remains */
	}

	/* phase C: drain the pipes to EOF (bounded) */
	stop = now_ms() + DRAIN_MS;
	while ((so.rfd >= 0 || se.rfd >= 0) && now_ms() < stop)
		wait_io(&so, &se, &xfd, &xerr, POLL_SLICE_MS);
	R.pipes = (so.rfd >= 0 || se.rfd >= 0) ? "open" : "eof";
	if (so.rfd >= 0) close(so.rfd);
	if (se.rfd >= 0) close(se.rfd);

	R.out_total = so.total; R.out_kept = so.kept;
	R.err_total = se.total; R.err_kept = se.kept;
	if (so.write_failed || se.write_failed)
		R.why = "capture-write-failed";
	if (fsync(ofd) != 0 || close(ofd) != 0 || fsync(efd) != 0 || close(efd) != 0)
		R.why = "capture-write-failed";
	if (alive)
		R.why = noproc ? "no-proc" : "strays-alive";

	if (!reaped)                       return report(X_UNREAPED);
	if (alive)                         return report(X_STRAYS);
	if (xerr)                          return report(X_EXECFAIL);
	if (R.kill_ms >= 0)                return report(X_KILL);
	if (R.term_ms >= 0)                return report(X_TERM);
	if (WIFSIGNALED(st))               return report(X_SIGNALED);
	return report(X_EXITED);
}
