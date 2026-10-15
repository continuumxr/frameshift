/*
 * fs-pattern — put ONE static test image on the Quest 3 panels through
 * /dev/dri/card0 (msm_drm), hold it for a bounded time, then close and exit.
 *
 * FrameShift stage 3b, v0.5 (trial (iii-b), FS-R-010 §4). Derived from the
 * stage-3a v0.4 source (devices/quest3/stage3a/src/fs-pattern.c, unchanged and
 * still pinned for the spent trial (iii) image). Offline-built; running it on a
 * device needs the Chair's pre-trial review and the PM's live sign-off.
 * See ../README.md for the full contract.
 *
 * Changes from v0.4 (each with a fixture or unit test; README "Changes"):
 *   - the BRIGHT pattern: mid-grey field 0x80; frame, cross, corner square,
 *     the 8 characters, their underline and the link bars at 0xFF. Geometry
 *     unchanged.
 *   - mode "show-off": identical to "show", but the run REQUIRES the CRTC to be
 *     inactive at start (GETCRTC ok, ACTIVE property found, ACTIVE = 0);
 *     otherwise it records step=precondition and exits 31 with NO commit
 *     (FS-R-010 §4: the off->on run; "precondition unmet: CRTC active").
 *   - read-only GET-ioctl logging at start (OBJ_GETPROPERTIES, GETPROPERTY,
 *     GETPROPBLOB only): the connector's topology_name (+ topology_control,
 *     dsc_mode values), its mode_properties blob, each plane's max_linewidth
 *     (from its capabilities blob), and (show) the full property name/value
 *     lists of the connector, the CRTC and every plane, plus the primary
 *     plane's capabilities blob. These records are optional: they stop at a
 *     compiled byte budget (FSP_OPT_MAX), never a silent cut.
 *   - NEVER set topology_control or dsc_mode: the atomic request builder takes
 *     only the property ids looked up for FB_ID, CRTC_ID, SRC_X/Y/W/H and CRTC_X/Y/W/H (planes),
 *     MODE_ID/ACTIVE (CRTC) and CRTC_ID (connector), exactly as in v0.4. The
 *     plane layout and the TEST_ONLY attempt order are UNCHANGED from v0.4.
 *
 * Mode "show" / "show-off":
 *   stdout must be a regular file, a pipe/FIFO (made O_NONBLOCK) or /dev/null
 *   -> open card0 -> require char device major 226 and driver "msm_drm"
 *   -> ATOMIC client cap (refused: exit 21; there is no legacy path)
 *   -> resources, connectors, the CRTC's current mode (GETCRTC), mode list
 *   -> (show-off) the CRTC must be inactive, else exit 31, no commit
 *   -> mode = the CRTC's current mode, else exactly 4128x2208 @ 90 Hz
 *      non-interlaced from the list, else exit 30
 *   -> read-only property logging
 *   -> one XRGB8888 dumb buffer, drawn once -> ADDFB2 -> mode blob
 *   -> TEST_ONLY attempts in order: plane swap without ALLOW_MODESET (single
 *      plane, then split), then with ALLOW_MODESET (single, then split)
 *   -> the first accepted request is committed for real, exactly once
 *   -> hold until commit start + HOLD_S (<= 10 s) or a stop signal
 *   -> close(fd) IMMEDIATELY, then the remaining records -> exit.
 *
 * Bounds on image time: the hold deadline; alarm(HOLD_S + 5) armed just
 * before the real commit (SIGALRM default action: terminate, which closes
 * the fd in the kernel); stdout can never block (see above). Plus PID 1's
 * supervision with KILL escalation (README).
 *
 * Never: sysfs/debugfs, backlight/brightness/BLU, DCS, legacy SETCRTC,
 * re-commits, animation, page flips, any property SET other than the v0.4
 * ones, or any path other than the device (and the output file in "render").
 *
 * Offline modes (no DRM ioctls): render NONCE W H OUT.ppm; holdtest NONCE
 * HOLD MOCK. Built with -DFSP_UNIT_TEST, main() is replaced by unit tests.
 *
 * Output (local log format; PID 1 wraps it in FSB1 for transport):
 *   FSP1 nonce=<8 hex> seq=<n> step=<id> rc=<n> [k=v ...] len=<n> crc=<8 hex> END\n
 * len/crc32 cover the bytes before " len=". The stream ends with step=eos.
 *
 * Headers: kernel uapi drm.h/drm_mode.h from the v2.7 Meta source. No libdrm.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#include "drm.h"
#include "drm_mode.h"

/* ---- compiled-in limits (not overridable at run time) ------------------- */
#define FSP_VERSION        "0.5"
#define FSP_HOLD_MAX_S     10    /* hard ceiling on the hold (PM decision: <= 10 s; no fan is driven) */
#define FSP_SETUP_BUDGET_S 30    /* backstop for everything before the real commit */
#define FSP_CLOSE_MARGIN_S 5     /* after the deadline: close (preclose + lastclose waits) and exit */
#define FSP_PATH_MAX       200   /* longest accepted path argument */
#define FSP_OPT_MAX        20480 /* bytes of OPTIONAL (property/blob logging) records per run */
#define FSP_BLOB_MAX       4096  /* longest blob read for logging; longer: length only */
#define FSP_BLOB_CHUNK     240   /* raw blob bytes per record (<= 720 encoded) */
#if FSP_HOLD_MAX_S > 10 || FSP_HOLD_MAX_S < 1
#error "FSP_HOLD_MAX_S must be 1..10"
#endif
#if FSP_SETUP_BUDGET_S > 30 || FSP_CLOSE_MARGIN_S > 10
#error "backstop margins too large"
#endif

#define FSP_ROTATE_180     1     /* panel orientation 180 (eureka-panel-sharp.dtsi:34) [D] */
#define DRM_MAJOR          226
#define FMT_XRGB8888       0x34325258u   /* fourcc 'X','R','2','4' */
#define PLANE_TYPE_OVERLAY 0     /* enum drm_plane_type, include/drm/drm_plane.h (v2.7) */
#define PLANE_TYPE_PRIMARY 1
#define PLANE_TYPE_CURSOR  2

/* ---- exit codes (README "Exit codes") ------------------------------------ */
enum {
	EX_OK          = 0,  /* image committed and held to the deadline */
	EX_INTERNAL    = 1,  /* internal error (hold wait failed; render I/O) */
	EX_USAGE       = 2,  /* bad arguments */
	EX_STDOUT      = 3,  /* stdout is not a regular file, pipe/FIFO or /dev/null: nothing written */
	EX_NODEV       = 10, /* device path absent (ENOENT/ENODEV/ENXIO) */
	EX_OPENFAIL    = 11, /* open failed otherwise, or not a DRM char device */
	EX_WRONGDRV    = 12, /* DRM_IOCTL_VERSION failed or driver is not msm_drm */
	EX_NOCONN      = 20, /* no connected connector */
	EX_NOPIPE      = 21, /* ATOMIC cap refused, or no usable encoder/CRTC/plane/properties */
	EX_NOMODE      = 30, /* neither the current CRTC mode nor 4128x2208@90 available */
	EX_PRECOND     = 31, /* show-off: the CRTC is not provably inactive at start: no commit */
	EX_BUFFER      = 40, /* dumb buffer / mmap / ADDFB2 / mode blob failed */
	EX_TESTREJECT  = 50, /* every TEST_ONLY attempt rejected: no real commit made */
	EX_COMMITFAIL  = 60, /* the real commit failed */
	EX_INTERRUPTED = 70, /* SIGTERM/SIGINT/SIGHUP before the deadline */
};

/* ---- output: framed single-line records ------------------------------------
 * Every record is written with exactly one write(). stdout is a regular file
 * (tmpfs: never blocks), /dev/null, or a pipe/FIFO set O_NONBLOCK: a record
 * (< PIPE_BUF bytes, so all-or-nothing) that cannot be written is dropped and
 * counted, never waited for. */
#define LINE_MAX_B 1024
#define TAIL_RESERVE 40          /* " len=NNNN crc=XXXXXXXX END\n" */
static char g_nonce[9] = "none";
static unsigned g_seq, g_dropped, g_overflows;
static char g_line[LINE_MAX_B];
static size_t g_len;
static int g_over;
static const char *g_step;
static unsigned g_rec_seq;
static int64_t g_rec_rc;
static uint32_t crc_tab[256];

static void crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1;
		crc_tab[i] = c;
	}
}

static uint32_t crc32_buf(const char *p, size_t n)  /* IEEE 802.3, as zlib.crc32 */
{
	uint32_t c = 0xffffffffu;
	for (size_t i = 0; i < n; i++)
		c = crc_tab[(c ^ (uint8_t)p[i]) & 0xff] ^ (c >> 8);
	return c ^ 0xffffffffu;
}

static void o_putc(char ch)
{
	if (g_len < sizeof(g_line) - TAIL_RESERVE) g_line[g_len++] = ch;
	else g_over = 1;
}
static void o_raw(const char *s) { while (*s) o_putc(*s++); }

static void o_u64(uint64_t v)
{
	char t[24];
	int i = 0;
	do { t[i++] = (char)('0' + v % 10); v /= 10; } while (v);
	while (i) o_putc(t[--i]);
}

static void o_i64(int64_t v)
{
	if (v < 0) { o_putc('-'); o_u64((uint64_t)(-(v + 1)) + 1); }
	else o_u64((uint64_t)v);
}

static void o_hex(uint64_t v)
{
	static const char hx[] = "0123456789abcdef";
	char t[20];
	int i = 0;
	do { t[i++] = hx[v & 15]; v >>= 4; } while (v);
	o_raw("0x");
	while (i) o_putc(t[--i]);
}

/* Outside strings are percent-encoded: bytes outside [A-Za-z0-9_./-] become
 * %XX. An unterminated or over-long input sets the overflow flag (the whole
 * record is then replaced by a step=overflow record): never a silent cut. */
static void o_str(const char *s, size_t max)
{
	static const char hx[] = "0123456789ABCDEF";
	size_t i;
	/* empty string -> the token "-"; a literal "-" -> "%2D": values are never
	 * empty and "-" stays unambiguous */
	if (max == 0 || s[0] == 0) { o_putc('-'); return; }
	if (s[0] == '-' && (max == 1 || s[1] == 0)) { o_raw("%2D"); return; }
	for (i = 0; i < max && s[i]; i++) {
		unsigned char c = (unsigned char)s[i];
		int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			 (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '/' || c == '-';
		if (ok) o_putc((char)c);
		else { o_putc('%'); o_putc(hx[c >> 4]); o_putc(hx[c & 15]); }
	}
	if (i == max && max && s[max - 1])
		g_over = 1;               /* not terminated within max: would be a cut */
}

static void rec_head(const char *step, int64_t rc, unsigned seq)
{
	g_len = 0; g_over = 0;
	o_raw("FSP1 nonce="); o_raw(g_nonce);
	o_raw(" seq="); o_u64(seq);
	o_raw(" step="); o_raw(step);
	o_raw(" rc="); o_i64(rc);
}
static void rec_begin(const char *step, int64_t rc)
{
	g_step = step; g_rec_seq = g_seq++; g_rec_rc = rc;
	rec_head(step, rc, g_rec_seq);
}
static void kv_u(const char *k, uint64_t v) { o_putc(' '); o_raw(k); o_putc('='); o_u64(v); }
static void kv_i(const char *k, int64_t v)  { o_putc(' '); o_raw(k); o_putc('='); o_i64(v); }
static void kv_x(const char *k, uint64_t v) { o_putc(' '); o_raw(k); o_putc('='); o_hex(v); }
static void kv_s(const char *k, const char *v) { o_putc(' '); o_raw(k); o_putc('='); o_raw(v); }
static void kv_str(const char *k, const char *v, size_t m) { o_putc(' '); o_raw(k); o_putc('='); o_str(v, m); }

/* Finish the record in g_line (framing appended) and return its length. */
static size_t rec_frame(void)
{
	if (g_over) {             /* replace, same seq, so the stream stays gap-free */
		g_overflows++;
		rec_head("overflow", -E2BIG, g_rec_seq);
		kv_s("orig_step", g_step);
		kv_i("orig_rc", g_rec_rc);
	}
	size_t body = g_len;
	uint32_t crc = crc32_buf(g_line, body);
	static const char hx[] = "0123456789abcdef";
	char t[24];
	int i = 0;
	size_t v = body;
	memcpy(g_line + g_len, " len=", 5); g_len += 5;
	do { t[i++] = (char)('0' + v % 10); v /= 10; } while (v);
	while (i) g_line[g_len++] = t[--i];
	memcpy(g_line + g_len, " crc=", 5); g_len += 5;
	for (int s = 28; s >= 0; s -= 4) g_line[g_len++] = hx[(crc >> s) & 15];
	memcpy(g_line + g_len, " END\n", 5); g_len += 5;
	return g_len;
}

static void rec_write(size_t n)
{
	ssize_t w;
	do { w = write(1, g_line, n); } while (w < 0 && errno == EINTR);
	if (w != (ssize_t)n)
		g_dropped++;          /* EAGAIN on a full pipe, EPIPE, ...: counted, never waited for */
}

static void rec_end(void)
{
	rec_write(rec_frame());
}

/* ---- optional records (v0.5: property and blob logging) ---------------------
 * An optional record is built with a TENTATIVE seq (g_seq is not advanced) and
 * emitted only while the optional bytes stay within FSP_OPT_MAX. The first one
 * that does not fit is discarded and replaced, with the same seq, by ONE
 * step=opt_budget record; every later optional record is discarded too. The
 * stream therefore stays gap-free, and nothing is cut silently: eos reports
 * opt_bytes and opt_skipped. */
static unsigned g_opt_bytes, g_opt_skipped;
static int g_opt_closed;

static void rec_begin_opt(const char *step)
{
	g_step = step; g_rec_seq = g_seq; g_rec_rc = 0;
	rec_head(step, 0, g_rec_seq);
}

static void rec_end_opt(void)
{
	const char *step = g_step;
	unsigned ov = g_overflows;
	size_t n = rec_frame();
	if (!g_opt_closed && g_opt_bytes + n <= FSP_OPT_MAX) {
		g_seq++;
		g_opt_bytes += (unsigned)n;
		rec_write(n);
		return;
	}
	g_overflows = ov;          /* a discarded record is not an emitted overflow */
	g_opt_skipped++;
	if (g_opt_closed)
		return;
	g_opt_closed = 1;
	rec_begin("opt_budget", -ENOSPC);
	kv_u("max", FSP_OPT_MAX);
	kv_u("used", g_opt_bytes);
	kv_s("first_skipped", step);
	rec_end();
}

/* Packed-list tokens: like o_str, but '.' and '/' are percent-encoded too, so
 * '.' separates the elements of a packed list unambiguously. */
static void o_tok(const char *s, size_t max)
{
	static const char hx[] = "0123456789ABCDEF";
	size_t i;
	if (max == 0 || s[0] == 0) { o_putc('-'); return; }
	if (s[0] == '-' && (max == 1 || s[1] == 0)) { o_raw("%2D"); return; }
	for (i = 0; i < max && s[i]; i++) {
		unsigned char c = (unsigned char)s[i];
		int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			 (c >= '0' && c <= '9') || c == '_' || c == '-';
		if (ok) o_putc((char)c);
		else { o_putc('%'); o_putc(hx[c >> 4]); o_putc(hx[c & 15]); }
	}
	if (i == max && max && s[max - 1])
		g_over = 1;
}

/* Raw bytes (a blob may hold NUL): everything outside [A-Za-z0-9_] is %XX.
 * Zero bytes -> the token "-". */
static void o_bytes(const uint8_t *p, size_t n)
{
	static const char hx[] = "0123456789ABCDEF";
	if (n == 0) { o_putc('-'); return; }
	for (size_t i = 0; i < n; i++) {
		unsigned char c = p[i];
		int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
		if (ok) o_putc((char)c);
		else { o_putc('%'); o_putc(hx[c >> 4]); o_putc(hx[c & 15]); }
	}
}

static const char *g_out_kind = "?";
/* 0 = acceptable stdout (made non-blocking if a pipe/FIFO), -1 = refuse. */
static int stdout_setup(void)
{
	struct stat st;
	if (fstat(1, &st) != 0)
		return -1;
	if (S_ISREG(st.st_mode)) { g_out_kind = "file"; return 0; }
	if (S_ISCHR(st.st_mode) && major(st.st_rdev) == 1 && minor(st.st_rdev) == 3) {
		g_out_kind = "null"; return 0;
	}
	if (S_ISFIFO(st.st_mode)) {
		int fl = fcntl(1, F_GETFL);
		if (fl < 0 || fcntl(1, F_SETFL, fl | O_NONBLOCK) != 0)
			return -1;
		g_out_kind = "pipe"; return 0;
	}
	return -1;                /* tty, serial, socket, ...: refused (README contract) */
}

/* ---- time ----------------------------------------------------------------- */
static int64_t mono_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}
static int64_t g_t0;

/* ---- signals: TERM/INT/HUP are blocked and collected synchronously -------- */
static sigset_t g_stopset;

static void signals_init(void)
{
	struct sigaction sa;
	sigset_t un;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = SIG_DFL;     /* undo any inherited SIG_IGN, else they'd be discarded */
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	sigaction(SIGALRM, &sa, NULL); /* backstop must terminate */
	sa.sa_handler = SIG_IGN;     /* output failure must not decide when we exit */
	sigaction(SIGPIPE, &sa, NULL);
	sigaction(SIGXFSZ, &sa, NULL); /* file-size limit: write() returns EFBIG, counted as dropped */

	sigemptyset(&g_stopset);
	sigaddset(&g_stopset, SIGTERM);
	sigaddset(&g_stopset, SIGINT);
	sigaddset(&g_stopset, SIGHUP);
	sigprocmask(SIG_BLOCK, &g_stopset, NULL);
	sigemptyset(&un);
	sigaddset(&un, SIGALRM);     /* an inherited blocked SIGALRM would defeat the backstop */
	sigprocmask(SIG_UNBLOCK, &un, NULL);
}

static int pending_stop(void)
{
	sigset_t p;
	struct timespec zero = { 0, 0 };
	if (sigpending(&p) != 0)
		return 0;
	if (!sigismember(&p, SIGTERM) && !sigismember(&p, SIGINT) && !sigismember(&p, SIGHUP))
		return 0;
	int s = sigtimedwait(&g_stopset, NULL, &zero);
	return s > 0 ? s : 0;
}

/* ---- the image -------------------------------------------------------------
 * Drawn in "viewer" coordinates of one eye and mapped into that eye's buffer
 * half; with FSP_ROTATE_180 each half is rotated 180 degrees. Geometry
 * unchanged from v0.1; v0.5 levels (FS-R-010 §4, the bright pattern): a
 * mid-grey field and every mark in white. */
#define C_BG     0x80
#define C_FRAME  0xFF
#define C_CROSS  0xFF
#define C_TEXT   0xFF

static const uint8_t glyph[16][7] = {
	{0x0e,0x11,0x13,0x15,0x19,0x11,0x0e}, /* 0 */
	{0x04,0x0c,0x04,0x04,0x04,0x04,0x0e}, /* 1 */
	{0x0e,0x11,0x01,0x02,0x04,0x08,0x1f}, /* 2 */
	{0x1f,0x02,0x04,0x02,0x01,0x11,0x0e}, /* 3 */
	{0x02,0x06,0x0a,0x12,0x1f,0x02,0x02}, /* 4 */
	{0x1f,0x10,0x1e,0x01,0x01,0x11,0x0e}, /* 5 */
	{0x06,0x08,0x10,0x1e,0x11,0x11,0x0e}, /* 6 */
	{0x1f,0x01,0x02,0x04,0x08,0x08,0x08}, /* 7 */
	{0x0e,0x11,0x11,0x0e,0x11,0x11,0x0e}, /* 8 */
	{0x0e,0x11,0x11,0x0f,0x01,0x02,0x0c}, /* 9 */
	{0x0e,0x11,0x11,0x1f,0x11,0x11,0x11}, /* A */
	{0x1e,0x11,0x11,0x1e,0x11,0x11,0x1e}, /* B */
	{0x0e,0x11,0x10,0x10,0x10,0x11,0x0e}, /* C */
	{0x1e,0x11,0x11,0x11,0x11,0x11,0x1e}, /* D */
	{0x1f,0x10,0x10,0x1e,0x10,0x10,0x1f}, /* E */
	{0x1f,0x10,0x10,0x1e,0x10,0x10,0x10}, /* F */
};

struct canvas {
	uint8_t *base;
	uint32_t pitch, w, h;
	uint32_t ex0, ew;
};

static void fill_buf(struct canvas *c, uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1, uint8_t v)
{
	uint32_t px = 0xff000000u | ((uint32_t)v << 16) | ((uint32_t)v << 8) | v;
	if (x1 > c->w) x1 = c->w;
	if (y1 > c->h) y1 = c->h;
	for (uint32_t y = y0; y < y1; y++) {
		uint32_t *row = (uint32_t *)(c->base + (size_t)y * c->pitch);
		for (uint32_t x = x0; x < x1; x++)
			row[x] = px;
	}
}

static void rect(struct canvas *c, int64_t x0, int64_t y0, int64_t x1, int64_t y1, uint8_t v)
{
	if (x0 < 0) x0 = 0;
	if (y0 < 0) y0 = 0;
	if (x1 > (int64_t)c->ew) x1 = c->ew;
	if (y1 > (int64_t)c->h) y1 = c->h;
	if (x0 >= x1 || y0 >= y1)
		return;
#if FSP_ROTATE_180
	int64_t bx0 = (int64_t)c->ew - x1, bx1 = (int64_t)c->ew - x0;
	int64_t by0 = (int64_t)c->h - y1, by1 = (int64_t)c->h - y0;
#else
	int64_t bx0 = x0, bx1 = x1, by0 = y0, by1 = y1;
#endif
	fill_buf(c, c->ex0 + (uint32_t)bx0, (uint32_t)by0, c->ex0 + (uint32_t)bx1, (uint32_t)by1, v);
}

static int hexval(char ch)
{
	if (ch >= '0' && ch <= '9') return ch - '0';
	if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
	return -1;
}

static void draw_eye(struct canvas *c, const char *nonce, int link)
{
	int64_t ew = c->ew, h = c->h;
	int64_t cx = ew / 2, cy = h / 2;
	int64_t u = ew / 47 / 2;
	if (u < 2) u = 2;
	int64_t bi = ew / 86, bt = ew / 258;
	if (bi < 4) bi = 4;
	if (bt < 2) bt = 2;
	int64_t arm = h / 12, ct = bt;

	rect(c, bi, bi, ew - bi, bi + bt, C_FRAME);
	rect(c, bi, h - bi - bt, ew - bi, h - bi, C_FRAME);
	rect(c, bi, bi, bi + bt, h - bi, C_FRAME);
	rect(c, ew - bi - bt, bi, ew - bi, h - bi, C_FRAME);
	rect(c, bi + bt + u * 2, bi + bt + u * 2, bi + bt + u * 8, bi + bt + u * 8, C_FRAME);
	rect(c, cx - arm, cy - ct / 2, cx + arm, cy - ct / 2 + ct, C_CROSS);
	rect(c, cx - ct / 2, cy - arm, cx - ct / 2 + ct, cy + arm, C_CROSS);

	int64_t adv = 6 * u, tw = 8 * adv - u, gh = 7 * u;
	int64_t tx = cx - tw / 2, ty = cy - arm - 3 * u - gh - 2 * u;
	for (int i = 0; i < 8; i++) {
		int g = hexval(nonce[i]);
		if (g < 0) continue;
		for (int r = 0; r < 7; r++)
			for (int col = 0; col < 5; col++)
				if (glyph[g][r] & (0x10 >> col))
					rect(c, tx + i * adv + col * u, ty + r * u,
					     tx + i * adv + (col + 1) * u, ty + (r + 1) * u, C_TEXT);
	}
	rect(c, tx, ty + gh + u, tx + tw, ty + gh + u + u / 2 + 1, C_TEXT);

	int64_t bw = 2 * u, bh = 8 * u, gap = 2 * u, by = cy + arm + 3 * u;
	int64_t total = link * bw + (link - 1) * gap, bx = cx - total / 2;
	for (int i = 0; i < link; i++)
		rect(c, bx + i * (bw + gap), by, bx + i * (bw + gap) + bw, by + bh, C_CROSS);
}

static void draw_pattern(uint8_t *base, uint32_t pitch, uint32_t w, uint32_t h, const char *nonce)
{
	struct canvas c = { base, pitch, w, h, 0, 0 };
	fill_buf(&c, 0, 0, w, h, C_BG);
	c.ex0 = 0;     c.ew = w / 2;      draw_eye(&c, nonce, 1);
	c.ex0 = w / 2; c.ew = w - w / 2;  draw_eye(&c, nonce, 2);
}

/* ---- argument parsing -------------------------------------------------------- */
static int valid_nonce(const char *s)
{
	if (strlen(s) != 8) return 0;
	for (int i = 0; i < 8; i++)
		if (hexval(s[i]) < 0) return 0;
	return 1;
}

static int parse_uint(const char *s, uint32_t *out)
{
	size_t n = strlen(s);
	uint32_t v = 0;
	if (n < 1 || n > 6) return 0;
	for (size_t i = 0; i < n; i++) {
		if (s[i] < '0' || s[i] > '9') return 0;
		v = v * 10 + (uint32_t)(s[i] - '0');
	}
	if (v < 1) return 0;
	*out = v;
	return 1;
}

static int valid_path(const char *s)
{
	size_t n = strlen(s);
	return n >= 1 && n <= FSP_PATH_MAX;
}

/* ---- exit ----------------------------------------------------------------------- */
static int g_fd = -1;
static int g_shown;

static void finish(int code, const char *reason) __attribute__((noreturn));
static void finish(int code, const char *reason)
{
	int closed_here = 0;
	if (g_fd >= 0) {
		close(g_fd);          /* driver: preclose null commit + lastclose (README) */
		g_fd = -1;
		closed_here = 1;
	}
	rec_begin("exit", 0);
	kv_u("code", (uint64_t)code);
	kv_s("reason", reason);
	kv_u("shown", (uint64_t)g_shown);
	kv_u("closed_at_exit", (uint64_t)closed_here);
	kv_u("elapsed_ms", (uint64_t)((mono_ns() - g_t0) / 1000000));
	rec_end();
	rec_begin("eos", 0);      /* explicit end of stream; a stream without it is INCOMPLETE */
	kv_u("records", (uint64_t)g_seq);
	kv_u("dropped", (uint64_t)g_dropped);
	kv_u("overflows", (uint64_t)g_overflows);
	kv_s("out", g_out_kind);
	kv_u("opt_bytes", (uint64_t)g_opt_bytes);
	kv_u("opt_skipped", (uint64_t)g_opt_skipped);
	rec_end();
	_exit(code);
}

static void check_stop(const char *where)
{
	int s = pending_stop();
	if (s) {
		rec_begin("signal", 0);
		kv_u("sig", (uint64_t)s);
		kv_s("at", where);
		rec_end();
		finish(EX_INTERRUPTED, "interrupted");
	}
}

/* ---- the hold (shared by show and holdtest) -------------------------------------
 * start: CLOCK_MONOTONIC ns the hold is measured from (commit start in show);
 * deadline = start + hold_s, absolute, computed once. When the wait ends for
 * any reason the fd is closed FIRST, before any further record is written. */
static int hold(int64_t start, uint32_t hold_s, unsigned alarm_s)
{
	int64_t deadline = start + (int64_t)hold_s * 1000000000LL;

	rec_begin("hold_start", 0);
	kv_u("hold_s", hold_s);
	kv_u("start_ms", (uint64_t)(start / 1000000));
	kv_u("deadline_ms", (uint64_t)(deadline / 1000000));
	kv_u("alarm_s", alarm_s);
	rec_end();

	int sig = 0, err = 0;
	for (;;) {
		int64_t now = mono_ns();
		if (now >= deadline)
			break;
		int64_t rem = deadline - now;
		struct timespec ts = { (time_t)(rem / 1000000000LL), (long)(rem % 1000000000LL) };
		int s = sigtimedwait(&g_stopset, NULL, &ts);
		if (s > 0) { sig = s; break; }
		if (errno == EAGAIN || errno == EINTR)
			continue;
		err = errno;          /* unexpected: end early (the safe direction) */
		break;
	}
	int64_t c0 = mono_ns();
	int crc = close(g_fd);    /* image ends here, before any output */
	g_fd = -1;
	int64_t c1 = mono_ns();

	rec_begin("hold_end", err ? -err : 0);
	kv_s("reason", sig ? "signal" : (err ? "error" : "deadline"));
	kv_u("sig", (uint64_t)sig);
	kv_u("held_ms", (uint64_t)((c0 - start) / 1000000));
	kv_i("late_ms", (c0 - deadline) / 1000000);
	kv_u("fd_closed", 1);
	kv_i("close_rc", crc);
	kv_u("close_ms", (uint64_t)((c1 - c0) / 1000000));
	rec_end();
	if (sig) return EX_INTERRUPTED;
	if (err) return EX_INTERNAL;
	return EX_OK;
}

/* ---- DRM helpers --------------------------------------------------------------- */
#ifdef FSP_UNIT_TEST
/* unit-test build only: the read-only property logging runs against a mock DRM
 * object model ("propsim" mode below); the device build calls the real ioctl */
static int mock_ioctl(int fd, unsigned long req, void *arg);
#define ioctl(fd, req, arg) mock_ioctl((fd), (req), (arg))
#endif
static int xioctl_n(int fd, unsigned long req, void *arg, int tries)
{
	for (int i = 0; i < tries; i++) {
		if (ioctl(fd, req, arg) == 0)
			return 0;
		if (errno != EINTR && errno != EAGAIN)
			return -errno;
	}
	return -errno;
}
#define xioctl(fd, req, arg) xioctl_n((fd), (req), (arg), 100)

#define MAXOBJ   64
#define MAXMODES 128
#define MAXPROPS 128
#define MAXFMTS  512

static uint32_t res_crtcs[MAXOBJ], res_conns[MAXOBJ], res_encs[MAXOBJ], res_fbs[MAXOBJ];
static struct drm_mode_card_res res;
static struct drm_mode_modeinfo modes[MAXMODES];
static uint32_t conn_encs[MAXOBJ];
static uint32_t prop_ids[MAXPROPS];
static uint64_t prop_vals[MAXPROPS];
static uint32_t plane_ids[MAXOBJ];
static uint32_t fmts[MAXFMTS];

static int obj_props(int fd, uint32_t id, uint32_t type)
{
	struct drm_mode_obj_get_properties op;
	memset(&op, 0, sizeof(op));
	op.obj_id = id; op.obj_type = type;
	int r = xioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &op);
	if (r) return r;
	if (op.count_props > MAXPROPS) return -E2BIG;
	op.props_ptr = (uint64_t)(uintptr_t)prop_ids;
	op.prop_values_ptr = (uint64_t)(uintptr_t)prop_vals;
	r = xioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &op);
	if (r) return r;
	return op.count_props > MAXPROPS ? -E2BIG : (int)op.count_props;
}

static uint32_t find_prop(int fd, uint32_t id, uint32_t type, const char *name, uint64_t *val)
{
	int n = obj_props(fd, id, type);
	for (int i = 0; i < n; i++) {
		struct drm_mode_get_property gp;
		memset(&gp, 0, sizeof(gp));
		gp.prop_id = prop_ids[i];
		if (xioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &gp))
			continue;
		gp.name[DRM_PROP_NAME_LEN - 1] = 0;
		if (strcmp(gp.name, name) == 0) {
			if (val) *val = prop_vals[i];
			return gp.prop_id;
		}
	}
	return 0;
}

struct plane_info {
	uint32_t id, type, crtc_id, fb_id, possible, xrgb;
	uint32_t p_fb, p_crtc, p_sx, p_sy, p_sw, p_sh, p_cx, p_cy, p_cw, p_ch;
};
static struct plane_info planes[MAXOBJ];
static int nplanes;

static int plane_props(int fd, struct plane_info *p)
{
	uint32_t t = DRM_MODE_OBJECT_PLANE;
	p->p_fb = find_prop(fd, p->id, t, "FB_ID", NULL);
	p->p_crtc = find_prop(fd, p->id, t, "CRTC_ID", NULL);
	p->p_sx = find_prop(fd, p->id, t, "SRC_X", NULL);
	p->p_sy = find_prop(fd, p->id, t, "SRC_Y", NULL);
	p->p_sw = find_prop(fd, p->id, t, "SRC_W", NULL);
	p->p_sh = find_prop(fd, p->id, t, "SRC_H", NULL);
	p->p_cx = find_prop(fd, p->id, t, "CRTC_X", NULL);
	p->p_cy = find_prop(fd, p->id, t, "CRTC_Y", NULL);
	p->p_cw = find_prop(fd, p->id, t, "CRTC_W", NULL);
	p->p_ch = find_prop(fd, p->id, t, "CRTC_H", NULL);
	return p->p_fb && p->p_crtc && p->p_sx && p->p_sy && p->p_sw && p->p_sh &&
	       p->p_cx && p->p_cy && p->p_cw && p->p_ch;
}

/* atomic request builder. Exceeding a limit sets .over; a_commit then refuses
 * to send the request (no silent truncation). */
#define MAXAOBJ  64
#define MAXAPROP 320
struct areq {
	uint32_t objs[MAXAOBJ], counts[MAXAOBJ];
	uint32_t props[MAXAPROP];
	uint64_t vals[MAXAPROP];
	uint32_t nobj, nprop;
	int over;
};

static void a_obj(struct areq *a, uint32_t id)
{
	if (a->nobj >= MAXAOBJ) { a->over = 1; return; }
	a->objs[a->nobj] = id; a->counts[a->nobj] = 0; a->nobj++;
}
static void a_prop(struct areq *a, uint32_t prop, uint64_t val)
{
	if (a->nprop >= MAXAPROP || !a->nobj || a->over) { a->over = 1; return; }
	a->props[a->nprop] = prop; a->vals[a->nprop] = val; a->nprop++;
	a->counts[a->nobj - 1]++;
}
static void a_plane(struct areq *a, const struct plane_info *p, uint32_t fb, uint32_t crtc,
		    uint32_t sx, uint32_t sw, uint32_t h)
{
	a_obj(a, p->id);
	a_prop(a, p->p_fb, fb);
	a_prop(a, p->p_crtc, crtc);
	a_prop(a, p->p_sx, (uint64_t)sx << 16);
	a_prop(a, p->p_sy, 0);
	a_prop(a, p->p_sw, (uint64_t)sw << 16);
	a_prop(a, p->p_sh, (uint64_t)h << 16);
	a_prop(a, p->p_cx, sx);
	a_prop(a, p->p_cy, 0);
	a_prop(a, p->p_cw, sw);
	a_prop(a, p->p_ch, h);
}
static void a_plane_off(struct areq *a, const struct plane_info *p)
{
	a_obj(a, p->id);
	a_prop(a, p->p_fb, 0);
	a_prop(a, p->p_crtc, 0);
}
/* tries: 100 for TEST_ONLY (harmless to retry on EINTR/EAGAIN), 1 for the real commit */
static int a_commit(int fd, struct areq *a, uint32_t flags, int tries)
{
	struct drm_mode_atomic at;
	if (a->over)
		return -E2BIG;
	memset(&at, 0, sizeof(at));
	at.flags = flags;
	at.count_objs = a->nobj;
	at.objs_ptr = (uint64_t)(uintptr_t)a->objs;
	at.count_props_ptr = (uint64_t)(uintptr_t)a->counts;
	at.props_ptr = (uint64_t)(uintptr_t)a->props;
	at.prop_values_ptr = (uint64_t)(uintptr_t)a->vals;
	return xioctl_n(fd, DRM_IOCTL_MODE_ATOMIC, &at, tries);
}

/* ---- mode policy (pure; unit-tested) -------------------------------------------
 * The CRTC's current mode is used (plane swap on the timing the splash is
 * already scanning out) only if the CRTC is ACTIVE, the mode is in the
 * connector's list and it is progressive. Otherwise: exactly 4128x2208 @ 90 Hz
 * progressive from the list (modeset path). Otherwise nothing. */
struct mode_pick { int idx; int use_current; const char *why; };

static int is_expected_mode(const struct drm_mode_modeinfo *m)
{
	return m->hdisplay == 4128 && m->vdisplay == 2208 && m->vrefresh == 90 &&
	       !(m->flags & DRM_MODE_FLAG_INTERLACE);
}

static int mode_eq(const struct drm_mode_modeinfo *a, const struct drm_mode_modeinfo *b)
{
	return a->clock == b->clock && a->hdisplay == b->hdisplay && a->hsync_start == b->hsync_start &&
	       a->hsync_end == b->hsync_end && a->htotal == b->htotal && a->vdisplay == b->vdisplay &&
	       a->vsync_start == b->vsync_start && a->vsync_end == b->vsync_end &&
	       a->vtotal == b->vtotal && a->flags == b->flags;
}

static int mode_in_list(const struct drm_mode_modeinfo *list, uint32_t n, const struct drm_mode_modeinfo *m)
{
	for (uint32_t i = 0; i < n; i++)
		if (mode_eq(&list[i], m)) return 1;
	return 0;
}

/* cur: the CRTC's mode, NULL if GETCRTC gave none; active: CRTC ACTIVE property */
static struct mode_pick pick_mode(const struct drm_mode_modeinfo *list, uint32_t n,
				  const struct drm_mode_modeinfo *cur, int active)
{
	struct mode_pick p = { -1, 0, "none" };
	if (cur && active && mode_in_list(list, n, cur) && !(cur->flags & DRM_MODE_FLAG_INTERLACE) &&
	    cur->hdisplay >= 64 && cur->vdisplay >= 64 && cur->hdisplay <= 8192 && cur->vdisplay <= 8192) {
		p.use_current = 1; p.why = "crtc_current";
		return p;
	}
	for (uint32_t i = 0; i < n; i++)
		if (is_expected_mode(&list[i])) { p.idx = (int)i; p.why = "expected_4128x2208_90"; return p; }
	return p;
}

/* TEST_ONLY attempt order (pure; unit-tested). No-modeset plane swaps only on
 * the current mode of an ACTIVE CRTC (use_current implies that); ALLOW_MODESET
 * attempts only when the mode is exactly the expected one. Single plane before
 * split; split only with a helper plane. May return 0 (nothing allowed). */
struct attempt { int modeset, split; };

static int plan_attempts(int use_current, int mode_expected, int have_helper, struct attempt *out)
{
	int n = 0;
	if (use_current) {
		out[n].modeset = 0; out[n].split = 0; n++;
		if (have_helper) { out[n].modeset = 0; out[n].split = 1; n++; }
	}
	if (mode_expected) {
		out[n].modeset = 1; out[n].split = 0; n++;
		if (have_helper) { out[n].modeset = 1; out[n].split = 1; n++; }
	}
	return n;
}

static void rec_mode(const char *step, int idx, const struct drm_mode_modeinfo *m)
{
	rec_begin(step, 0);
	kv_i("idx", idx);
	kv_u("w", m->hdisplay); kv_u("h", m->vdisplay); kv_u("vrefresh", m->vrefresh);
	kv_u("clock_khz", m->clock);
	kv_u("hss", m->hsync_start); kv_u("hse", m->hsync_end); kv_u("htotal", m->htotal);
	kv_u("vss", m->vsync_start); kv_u("vse", m->vsync_end); kv_u("vtotal", m->vtotal);
	kv_x("flags", m->flags); kv_x("type", m->type);
	char nm[DRM_DISPLAY_MODE_LEN + 1];
	memcpy(nm, m->name, DRM_DISPLAY_MODE_LEN); nm[DRM_DISPLAY_MODE_LEN] = 0;
	kv_str("name", nm, sizeof(nm));
}

/* ---- v0.5 pure helpers (unit-tested) ----------------------------------------- */
/* show-off precondition: 1 only if the CRTC is PROVABLY inactive: GETCRTC
 * succeeded, the ACTIVE property was found, and its value is 0. Anything
 * else (ACTIVE=1, no ACTIVE property, GETCRTC failed) is "not proven". */
static int crtc_provably_inactive(int getcrtc_rc, uint32_t active_prop, uint64_t active_val)
{
	return getcrtc_rc == 0 && active_prop != 0 && active_val == 0;
}

/* SDE info blobs are "key=value\n" lines (sde_kms_info_add_keyint). Returns
 * the decimal value of KEY at the start of a line, or -1 if absent/not a
 * plain decimal of 1 to 9 digits. */
static int64_t kv_text_int(const uint8_t *p, size_t n, const char *key)
{
	size_t kl = strlen(key), i = 0;
	while (i < n) {
		size_t e = i;
		while (e < n && p[e] != '\n') e++;
		if (e - i > kl && memcmp(p + i, key, kl) == 0 && p[i + kl] == '=') {
			size_t j = i + kl + 1;
			int64_t v = 0;
			int d = 0;
			while (j < e && p[j] >= '0' && p[j] <= '9' && d < 10) { v = v * 10 + (p[j] - '0'); j++; d++; }
			return (d >= 1 && d <= 9 && j == e) ? v : -1;
		}
		i = e + 1;
	}
	return -1;
}

/* One-letter property type for the packed type list; lower case = immutable. */
static char prop_type_letter(uint32_t flags)
{
	char c = '?';
	if (flags & DRM_MODE_PROP_ENUM) c = 'E';
	else if (flags & DRM_MODE_PROP_BITMASK) c = 'M';
	else if (flags & DRM_MODE_PROP_BLOB) c = 'B';
	else if (flags & DRM_MODE_PROP_RANGE) c = 'R';
	else if ((flags & DRM_MODE_PROP_EXTENDED_TYPE) == DRM_MODE_PROP_OBJECT) c = 'O';
	else if ((flags & DRM_MODE_PROP_EXTENDED_TYPE) == DRM_MODE_PROP_SIGNED_RANGE) c = 'S';
	if ((flags & DRM_MODE_PROP_IMMUTABLE) && c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
	return c;
}

/* ---- v0.5 read-only property logging (GET ioctls only) -------------------------
 * Only DRM_IOCTL_MODE_OBJ_GETPROPERTIES, DRM_IOCTL_MODE_GETPROPERTY and
 * DRM_IOCTL_MODE_GETPROPBLOB are issued here. Nothing is set. */
#define PACK_LIMIT 820           /* stop adding list elements to a record past this length */
struct pinfo { uint32_t id, flags; uint64_t val; char name[DRM_PROP_NAME_LEN + 1]; };
static struct pinfo g_pi[MAXPROPS], g_ref[MAXPROPS];
static int g_nref;

/* All properties of an object (ids, values, names, flags). Returns the count or -errno. */
static int obj_pinfo(int fd, uint32_t id, uint32_t type, struct pinfo *out)
{
	int n = obj_props(fd, id, type);
	if (n < 0) return n;
	for (int i = 0; i < n; i++) {
		struct drm_mode_get_property gp;
		memset(&gp, 0, sizeof(gp));
		gp.prop_id = prop_ids[i];
		memset(&out[i], 0, sizeof(out[i]));
		out[i].id = prop_ids[i]; out[i].val = prop_vals[i];
		if (xioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &gp) == 0) {
			memcpy(out[i].name, gp.name, DRM_PROP_NAME_LEN);
			out[i].name[DRM_PROP_NAME_LEN] = 0;
			out[i].flags = gp.flags;
		}
	}
	return n;
}

static int pinfo_find(const struct pinfo *pi, int n, const char *name)
{
	for (int i = 0; i < n; i++)
		if (strcmp(pi[i].name, name) == 0) return i;
	return -1;
}

/* The name of enum value VAL of property PID ("none" if not an enum or not found). */
static void enum_name(int fd, uint32_t pid, uint64_t val, char *out, size_t outsz)
{
	static struct drm_mode_property_enum en[64];
	struct drm_mode_get_property gp;
	memcpy(out, "none", 5);
	memset(&gp, 0, sizeof(gp));
	gp.prop_id = pid;
	if (xioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &gp) || !(gp.flags & DRM_MODE_PROP_ENUM) ||
	    gp.count_enum_blobs == 0 || gp.count_enum_blobs > 64)
		return;
	uint32_t ne = gp.count_enum_blobs;
	memset(&gp, 0, sizeof(gp));
	gp.prop_id = pid;
	gp.count_enum_blobs = ne;
	gp.enum_blob_ptr = (uint64_t)(uintptr_t)en;
	if (xioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &gp) || gp.count_enum_blobs > ne)
		return;
	for (uint32_t i = 0; i < gp.count_enum_blobs; i++)
		if (en[i].value == val) {
			size_t k = 0;
			while (k + 1 < outsz && k < DRM_PROP_NAME_LEN && en[i].name[k]) { out[k] = en[i].name[k]; k++; }
			out[k] = 0;
			return;
		}
}

/* Reads blob BLOB_ID into g_blob (at most FSP_BLOB_MAX). Returns its length, or
 * -errno (-EFBIG if longer than FSP_BLOB_MAX; *len_out still gets the length). */
static uint8_t g_blob[FSP_BLOB_MAX];
static int read_blob(int fd, uint32_t blob_id, uint32_t *len_out)
{
	struct drm_mode_get_blob gb;
	*len_out = 0;
	memset(&gb, 0, sizeof(gb));
	gb.blob_id = blob_id;
	int r = xioctl(fd, DRM_IOCTL_MODE_GETPROPBLOB, &gb);
	if (r) return r;
	*len_out = gb.length;
	if (gb.length > FSP_BLOB_MAX) return -EFBIG;
	uint32_t want = gb.length;
	gb.data = (uint64_t)(uintptr_t)g_blob;
	r = xioctl(fd, DRM_IOCTL_MODE_GETPROPBLOB, &gb);
	if (r) return r;
	if (gb.length != want) return -EAGAIN;
	return (int)want;
}

/* step=blob records (optional): the blob's bytes, %XX-encoded, FSP_BLOB_CHUNK per record. */
static void log_blob(int fd, const char *what, uint32_t obj, uint32_t blob_id)
{
	uint32_t len = 0;
	int r = blob_id ? read_blob(fd, blob_id, &len) : -ENOENT;
	if (r < 0) {
		rec_begin_opt("blob");
		kv_s("what", what); kv_u("obj", obj); kv_u("blob", blob_id); kv_i("read_rc", r);
		kv_u("bytes", len);
		rec_end_opt();
		return;
	}
	uint32_t parts = len ? (len + FSP_BLOB_CHUNK - 1) / FSP_BLOB_CHUNK : 1;
	for (uint32_t k = 0; k < parts; k++) {
		uint32_t off = k * FSP_BLOB_CHUNK;
		uint32_t m = len ? (len - off < FSP_BLOB_CHUNK ? len - off : FSP_BLOB_CHUNK) : 0;
		rec_begin_opt("blob");
		kv_s("what", what); kv_u("obj", obj); kv_u("blob", blob_id); kv_u("bytes", len);
		kv_u("part", k); kv_u("parts", parts);
		o_raw(" data="); o_bytes(g_blob + off, m);
		rec_end_opt();
	}
}

/* step=prop_list (optional): the property names (packed, '.'-separated) and one
 * type letter per property, of object REF of KIND. */
static void log_prop_list(const char *kind, uint32_t ref, const struct pinfo *pi, int n)
{
	int i = 0, part = 0;
	do {
		int first = i, k = 0;
		rec_begin_opt("prop_list");
		kv_s("kind", kind); kv_u("ref", ref); kv_u("count", (uint64_t)n);
		kv_u("part", (uint64_t)part); kv_u("first", (uint64_t)first);
		o_raw(" names=");
		if (n == 0) o_putc('-');
		while (i < n && (k == 0 || g_len + 3 * strlen(pi[i].name) + 4 < PACK_LIMIT)) {
			if (k) o_putc('.');
			o_tok(pi[i].name, sizeof(pi[i].name));
			i++; k++;
		}
		o_raw(" types=");
		if (k == 0) o_putc('-');
		for (int j = first; j < first + k; j++) o_putc(prop_type_letter(pi[j].flags));
		kv_u("n", (uint64_t)k);
		rec_end_opt();
		part++;
	} while (i < n);
}

/* step=prop_vals (optional): the values of object OBJ, packed in the order of its
 * own property list; same_names=1 when that list equals the reference list
 * logged for KIND (else its own prop_list precedes it). */
static void log_prop_vals(const char *kind, uint32_t obj, const struct pinfo *pi, int n, int same)
{
	int i = 0, part = 0;
	do {
		int first = i, k = 0;
		rec_begin_opt("prop_vals");
		kv_s("kind", kind); kv_u("obj", obj); kv_u("count", (uint64_t)n); kv_u("same_names", (uint64_t)same);
		kv_u("part", (uint64_t)part); kv_u("first", (uint64_t)first);
		o_raw(" vals=");
		if (n == 0) o_putc('-');
		while (i < n && (k == 0 || g_len + 24 < PACK_LIMIT)) {
			if (k) o_putc('.');
			o_u64(pi[i].val);
			i++; k++;
		}
		kv_u("n", (uint64_t)k);
		rec_end_opt();
		part++;
	} while (i < n);
}

static int same_names(const struct pinfo *a, int na, const struct pinfo *b, int nb)
{
	if (na != nb) return 0;
	for (int i = 0; i < na; i++)
		if (strcmp(a[i].name, b[i].name) != 0) return 0;
	return 1;
}

/* One object: the reference list for its kind the first time, then its values. */
static void log_object(int fd, const char *kind, uint32_t id, uint32_t type, int *have_ref)
{
	int n = obj_pinfo(fd, id, type, g_pi);
	if (n < 0) {
		rec_begin_opt("prop_vals");
		kv_s("kind", kind); kv_u("obj", id); kv_i("read_rc", n);
		rec_end_opt();
		return;
	}
	int same = 0;
	if (!*have_ref) {
		memcpy(g_ref, g_pi, sizeof(g_pi[0]) * (size_t)n); g_nref = n; *have_ref = 1;
		log_prop_list(kind, id, g_pi, n);
		same = 1;
	} else if (same_names(g_pi, n, g_ref, g_nref)) {
		same = 1;
	} else {
		log_prop_list(kind, id, g_pi, n);
	}
	log_prop_vals(kind, id, g_pi, n, same);
}

/* The connector's topology: ALWAYS logged (an essential record; read-only). */
static void log_conn_topology(int fd, uint32_t cid, uint32_t *mode_props_blob)
{
	static struct pinfo cp[MAXPROPS];
	char tname[DRM_PROP_NAME_LEN + 1];
	int n = obj_pinfo(fd, cid, DRM_MODE_OBJECT_CONNECTOR, cp);
	int it = n > 0 ? pinfo_find(cp, n, "topology_name") : -1;
	int ic = n > 0 ? pinfo_find(cp, n, "topology_control") : -1;
	int id = n > 0 ? pinfo_find(cp, n, "dsc_mode") : -1;
	int im = n > 0 ? pinfo_find(cp, n, "mode_properties") : -1;
	memcpy(tname, "none", 5);
	if (it >= 0) enum_name(fd, cp[it].id, cp[it].val, tname, sizeof(tname));
	*mode_props_blob = im >= 0 ? (uint32_t)cp[im].val : 0;
	rec_begin("conn_topology", n < 0 ? n : 0);
	kv_u("conn", cid); kv_i("props", n);
	kv_u("topology_prop", it >= 0 ? cp[it].id : 0);
	if (it >= 0) kv_u("topology_val", cp[it].val); else kv_s("topology_val", "none");
	kv_str("topology_name", tname, sizeof(tname));
	kv_u("control_prop", ic >= 0 ? cp[ic].id : 0);
	if (ic >= 0) kv_u("control_val", cp[ic].val); else kv_s("control_val", "none");
	kv_u("dsc_mode_prop", id >= 0 ? cp[id].id : 0);
	if (id >= 0) kv_u("dsc_mode_val", cp[id].val); else kv_s("dsc_mode_val", "none");
	kv_u("mode_props_blob", *mode_props_blob);
	rec_end();
}

/* step=plane_caps (optional): max_linewidth from each plane's capabilities blob. */
static void log_plane_caps(int fd, uint32_t pid, uint32_t *caps_blob_out)
{
	static struct pinfo pp[MAXPROPS];
	int n = obj_pinfo(fd, pid, DRM_MODE_OBJECT_PLANE, pp);
	int ic = n > 0 ? pinfo_find(pp, n, "capabilities") : -1;
	uint32_t blob = ic >= 0 ? (uint32_t)pp[ic].val : 0, len = 0;
	int r = blob ? read_blob(fd, blob, &len) : -ENOENT;
	int64_t mlw = r >= 0 ? kv_text_int(g_blob, (size_t)r, "max_linewidth") : -1;
	*caps_blob_out = blob;
	rec_begin_opt("plane_caps");
	kv_u("plane", pid); kv_u("caps_blob", blob); kv_i("read_rc", r < 0 ? r : 0); kv_u("caps_bytes", len);
	if (mlw >= 0) kv_u("max_linewidth", (uint64_t)mlw); else kv_s("max_linewidth", "none");
	rec_end_opt();
}

/* The whole start-of-run logging. full = 1 for "show" (run 1); 0 for "show-off"
 * (run 2: the topology and mode_properties only). Read-only. */
static void log_properties(int fd, int full, uint32_t cid, uint32_t crtc_id, uint32_t primary_plane_id,
			   const uint32_t *pids, uint32_t npids)
{
	uint32_t mpb = 0, caps_pri = 0, caps = 0;
	log_conn_topology(fd, cid, &mpb);
	log_blob(fd, "mode_properties", cid, mpb);
	if (!full)
		return;
	for (uint32_t i = 0; i < npids; i++) {
		log_plane_caps(fd, pids[i], &caps);
		if (pids[i] == primary_plane_id) caps_pri = caps;
	}
	log_blob(fd, "primary_capabilities", primary_plane_id, caps_pri);
	int ref = 0;
	log_object(fd, "conn", cid, DRM_MODE_OBJECT_CONNECTOR, &ref);
	ref = 0;
	log_object(fd, "crtc", crtc_id, DRM_MODE_OBJECT_CRTC, &ref);
	ref = 0;
	for (uint32_t i = 0; i < npids; i++)
		log_object(fd, "plane", pids[i], DRM_MODE_OBJECT_PLANE, &ref);
}

#ifndef FSP_UNIT_TEST
/* ---- mode "show" / "show-off" ----------------------------------------------------- */
static int run_show(const char *dev, uint32_t hold_s, int off_mode)
{
	int r;
	check_stop("before_open");

	/* 1. stat the path first: only a DRM char device (major 226) is ever opened */
	struct stat st0, st;
	if (stat(dev, &st0) != 0) {
		int e = errno;
		int nodev = (e == ENOENT || e == ENODEV || e == ENXIO || e == ENOTDIR);
		rec_begin("open", -e); kv_u("errno", (uint64_t)e); kv_str("dev", dev, FSP_PATH_MAX + 1);
		kv_s("at", "stat"); rec_end();
		finish(nodev ? EX_NODEV : EX_OPENFAIL, nodev ? "no_device" : "stat_failed");
	}
	if (!S_ISCHR(st0.st_mode) || major(st0.st_rdev) != DRM_MAJOR) {
		rec_begin("open", -ENOTTY); kv_s("error", "not_drm_chardev"); kv_str("dev", dev, FSP_PATH_MAX + 1);
		kv_x("mode", (uint64_t)st0.st_mode); kv_s("at", "stat"); rec_end();
		finish(EX_OPENFAIL, "not_drm_device");      /* never opened */
	}
	g_fd = open(dev, O_RDWR | O_NOCTTY | O_CLOEXEC);
	if (g_fd < 0) {
		int e = errno;
		int nodev = (e == ENOENT || e == ENODEV || e == ENXIO);
		rec_begin("open", -e); kv_u("errno", (uint64_t)e); kv_str("dev", dev, FSP_PATH_MAX + 1);
		kv_s("at", "open"); rec_end();
		finish(nodev ? EX_NODEV : EX_OPENFAIL, nodev ? "no_device" : "open_failed");
	}
	/* the opened file must be the node we checked (no swap between stat and open) */
	if (fstat(g_fd, &st) != 0 || !S_ISCHR(st.st_mode) || st.st_rdev != st0.st_rdev) {
		rec_begin("open", -ENOTTY); kv_s("error", "node_changed"); kv_str("dev", dev, FSP_PATH_MAX + 1);
		kv_s("at", "fstat"); rec_end();
		finish(EX_OPENFAIL, "node_changed");        /* finish() closes it first */
	}
	rec_begin("open", 0); kv_str("dev", dev, FSP_PATH_MAX + 1);
	kv_u("major", major(st.st_rdev)); kv_u("minor", minor(st.st_rdev)); rec_end();

	/* 2. driver must be msm_drm */
	char dname[64], ddate[64], ddesc[128];
	struct drm_version ver;
	memset(&ver, 0, sizeof(ver)); memset(dname, 0, sizeof(dname));
	ver.name = dname; ver.name_len = sizeof(dname) - 1;
	ver.date = ddate; ver.date_len = sizeof(ddate) - 1;
	ver.desc = ddesc; ver.desc_len = sizeof(ddesc) - 1;
	r = xioctl(g_fd, DRM_IOCTL_VERSION, &ver);
	dname[sizeof(dname) - 1] = 0;
	rec_begin("version", r);
	if (!r) {
		kv_str("drv", dname, sizeof(dname));
		kv_i("major", ver.version_major); kv_i("minor", ver.version_minor);
		kv_i("patch", ver.version_patchlevel);
	}
	rec_end();
	if (r || strcmp(dname, "msm_drm") != 0)
		finish(EX_WRONGDRV, "wrong_driver");

	/* 3. client caps: ATOMIC is required (it implies universal planes) */
	struct drm_set_client_cap cap = { DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1 };
	int r_univ = xioctl(g_fd, DRM_IOCTL_SET_CLIENT_CAP, &cap);
	cap.capability = DRM_CLIENT_CAP_ATOMIC; cap.value = 1;
	int r_atom = xioctl(g_fd, DRM_IOCTL_SET_CLIENT_CAP, &cap);
	rec_begin("caps", r_atom);
	kv_i("universal_rc", r_univ); kv_i("atomic_rc", r_atom);
	rec_end();
	if (r_atom)
		finish(EX_NOPIPE, "no_atomic");

	/* 4. resources */
	memset(&res, 0, sizeof(res));
	r = xioctl(g_fd, DRM_IOCTL_MODE_GETRESOURCES, &res);
	if (!r && (res.count_crtcs > MAXOBJ || res.count_connectors > MAXOBJ ||
		   res.count_encoders > MAXOBJ || res.count_fbs > MAXOBJ))
		r = -E2BIG;
	if (!r) {
		struct drm_mode_card_res first = res;
		res.crtc_id_ptr = (uint64_t)(uintptr_t)res_crtcs;
		res.connector_id_ptr = (uint64_t)(uintptr_t)res_conns;
		res.encoder_id_ptr = (uint64_t)(uintptr_t)res_encs;
		res.fb_id_ptr = (uint64_t)(uintptr_t)res_fbs;
		r = xioctl(g_fd, DRM_IOCTL_MODE_GETRESOURCES, &res);
		if (!r && (res.count_crtcs > first.count_crtcs || res.count_connectors > first.count_connectors ||
			   res.count_encoders > first.count_encoders || res.count_fbs > first.count_fbs))
			r = -EAGAIN;
	}
	rec_begin("resources", r);
	kv_u("crtcs", res.count_crtcs); kv_u("connectors", res.count_connectors);
	kv_u("encoders", res.count_encoders); kv_u("fbs", res.count_fbs);
	kv_u("max_w", res.max_width); kv_u("max_h", res.max_height);
	rec_end();
	if (r) finish(EX_NOCONN, "no_resources");
	check_stop("after_resources");

	/* 5. connectors */
	struct drm_mode_get_connector gc, chosen;
	int have = 0, nconnected = 0;
	memset(&chosen, 0, sizeof(chosen));
	for (uint32_t i = 0; i < res.count_connectors && i < MAXOBJ; i++) {
		memset(&gc, 0, sizeof(gc));
		gc.connector_id = res_conns[i];
		r = xioctl(g_fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc);
		rec_begin("connector", r);
		kv_u("id", res_conns[i]);
		if (!r) {
			kv_u("type", gc.connector_type); kv_u("type_id", gc.connector_type_id);
			kv_u("status", gc.connection); kv_u("modes", gc.count_modes);
			kv_u("encoders", gc.count_encoders); kv_u("encoder", gc.encoder_id);
			kv_u("mm_w", gc.mm_width); kv_u("mm_h", gc.mm_height);
		}
		rec_end();
		if (r || gc.connection != 1)
			continue;
		nconnected++;
		if (!have || (chosen.connector_type != DRM_MODE_CONNECTOR_DSI &&
			      gc.connector_type == DRM_MODE_CONNECTOR_DSI)) {
			chosen = gc; have = 1;
		}
	}
	if (!have) {
		rec_begin("chosen_connector", -ENOENT); kv_u("connected", 0); rec_end();
		finish(EX_NOCONN, "no_connector");
	}
	uint32_t cid = chosen.connector_id;
	if (chosen.count_modes > MAXMODES || chosen.count_encoders > MAXOBJ) {
		rec_begin("chosen_connector", -E2BIG); kv_u("id", cid); rec_end();
		finish(EX_NOMODE, "too_many_modes");
	}
	memset(&gc, 0, sizeof(gc));
	gc.connector_id = cid;
	gc.count_modes = chosen.count_modes;
	gc.modes_ptr = (uint64_t)(uintptr_t)modes;
	gc.count_encoders = chosen.count_encoders;
	gc.encoders_ptr = (uint64_t)(uintptr_t)conn_encs;
	r = xioctl(g_fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc);
	if (!r && (gc.count_modes > chosen.count_modes || gc.count_encoders > chosen.count_encoders))
		r = -EAGAIN;
	rec_begin("chosen_connector", r);
	kv_u("id", cid); kv_u("type", gc.connector_type); kv_u("connected", (uint64_t)nconnected);
	kv_u("modes", gc.count_modes); kv_u("encoder", gc.encoder_id);
	rec_end();
	if (r) finish(EX_NOCONN, "connector_read_failed");
	uint32_t nm = gc.count_modes;
	for (uint32_t i = 0; i < nm; i++) {
		rec_mode("mode", (int)i, &modes[i]);
		kv_u("preferred", (modes[i].type & DRM_MODE_TYPE_PREFERRED) ? 1 : 0);
		kv_u("expected", (uint64_t)is_expected_mode(&modes[i]));
		rec_end();
	}

	/* 6. encoder -> CRTC */
	uint32_t crtc_id = 0, enc_id = gc.encoder_id;
	struct drm_mode_get_encoder ge;
	if (enc_id) {
		memset(&ge, 0, sizeof(ge)); ge.encoder_id = enc_id;
		if (!xioctl(g_fd, DRM_IOCTL_MODE_GETENCODER, &ge))
			crtc_id = ge.crtc_id;
	}
	for (uint32_t e = 0; !crtc_id && e < gc.count_encoders; e++) {
		memset(&ge, 0, sizeof(ge)); ge.encoder_id = conn_encs[e];
		if (xioctl(g_fd, DRM_IOCTL_MODE_GETENCODER, &ge)) continue;
		for (uint32_t k = 0; k < res.count_crtcs && k < 32; k++)
			if (ge.possible_crtcs & (1u << k)) { crtc_id = res_crtcs[k]; enc_id = ge.encoder_id; break; }
	}
	int crtc_idx = -1;
	for (uint32_t k = 0; k < res.count_crtcs; k++)
		if (res_crtcs[k] == crtc_id) crtc_idx = (int)k;
	rec_begin("pipeline", crtc_idx >= 0 ? 0 : -ENOENT);
	kv_u("encoder", enc_id); kv_u("crtc", crtc_id); kv_i("crtc_idx", crtc_idx);
	rec_end();
	if (crtc_idx < 0 || crtc_idx > 31) finish(EX_NOPIPE, "no_crtc");

	/* 7. the CRTC's current mode (logged either way), then the mode policy */
	struct drm_mode_crtc gcr;
	memset(&gcr, 0, sizeof(gcr));
	gcr.crtc_id = crtc_id;
	r = xioctl(g_fd, DRM_IOCTL_MODE_GETCRTC, &gcr);
	int cur_valid = (!r && gcr.mode_valid);
	uint64_t active_val = 0;
	uint32_t active_prop = find_prop(g_fd, crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE", &active_val);
	int cur_active = (active_prop && active_val == 1);
	rec_mode("crtc_state", -1, &gcr.mode);
	kv_i("getcrtc_rc", r); kv_u("mode_valid", r ? 0 : gcr.mode_valid); kv_u("fb", gcr.fb_id);
	kv_u("active_prop", active_prop); kv_u("active", active_val);
	kv_u("in_list", (uint64_t)(cur_valid && mode_in_list(modes, nm, &gcr.mode)));
	kv_u("interlaced", (uint64_t)((gcr.mode.flags & DRM_MODE_FLAG_INTERLACE) ? 1 : 0));
	kv_u("expected", (uint64_t)(cur_valid && is_expected_mode(&gcr.mode)));
	rec_end();
	/* show-off (run 2 of trial (iii-b)): the off->on run needs a PROVABLY inactive
	 * CRTC. Otherwise: no commit at all (FS-R-010 §4 "precondition unmet"). */
	if (off_mode && !crtc_provably_inactive(r, active_prop, active_val)) {
		rec_begin("precondition", -EBUSY);
		kv_s("required", "crtc_inactive");
		kv_i("getcrtc_rc", r); kv_u("active_prop", active_prop); kv_u("active", active_val);
		rec_end();
		finish(EX_PRECOND, "crtc_active");
	}
	if (off_mode) {
		rec_begin("precondition", 0);
		kv_s("required", "crtc_inactive");
		kv_i("getcrtc_rc", r); kv_u("active_prop", active_prop); kv_u("active", active_val);
		rec_end();
	}
	struct mode_pick mp = pick_mode(modes, nm, cur_valid ? &gcr.mode : NULL, cur_active);
	struct drm_mode_modeinfo mode;
	if (mp.use_current) mode = gcr.mode;
	else if (mp.idx >= 0) mode = modes[mp.idx];
	else {
		rec_begin("chosen_mode", -ENOENT); kv_s("why", mp.why); rec_end();
		finish(EX_NOMODE, "no_acceptable_mode");
	}
	uint32_t W = mode.hdisplay, H = mode.vdisplay;
	rec_mode("chosen_mode", mp.idx, &mode);
	kv_s("why", mp.why);
	kv_u("expected", (uint64_t)is_expected_mode(&mode));
	rec_end();

	/* 8. planes */
	int pri = -1, sec = -1;
	struct drm_mode_get_plane_res pr;
	memset(&pr, 0, sizeof(pr));
	r = xioctl(g_fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr);
	if (!r && pr.count_planes > MAXOBJ) r = -E2BIG;
	if (!r) {
		uint32_t n0 = pr.count_planes;
		pr.plane_id_ptr = (uint64_t)(uintptr_t)plane_ids;
		r = xioctl(g_fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr);
		if (!r && pr.count_planes > n0) r = -EAGAIN;
	}
	rec_begin("planes", r); kv_u("count", pr.count_planes); rec_end();
	if (r) finish(EX_NOPIPE, "no_planes");
	nplanes = 0;
	for (uint32_t i = 0; i < pr.count_planes && i < MAXOBJ; i++) {
		struct drm_mode_get_plane gp;
		struct plane_info *p = &planes[nplanes];
		memset(&gp, 0, sizeof(gp)); memset(p, 0, sizeof(*p));
		gp.plane_id = plane_ids[i];
		r = xioctl(g_fd, DRM_IOCTL_MODE_GETPLANE, &gp);
		if (!r && gp.count_format_types > MAXFMTS) r = -E2BIG;
		if (!r) {
			uint32_t f0 = gp.count_format_types;
			gp.format_type_ptr = (uint64_t)(uintptr_t)fmts;
			r = xioctl(g_fd, DRM_IOCTL_MODE_GETPLANE, &gp);
			if (!r && gp.count_format_types > f0) r = -EAGAIN;
		}
		uint64_t type = 0;
		int props_ok = 0;
		if (!r) {
			p->id = gp.plane_id; p->crtc_id = gp.crtc_id; p->fb_id = gp.fb_id;
			p->possible = gp.possible_crtcs;
			for (uint32_t f = 0; f < gp.count_format_types && f < MAXFMTS; f++)
				if (fmts[f] == FMT_XRGB8888) p->xrgb = 1;
			find_prop(g_fd, p->id, DRM_MODE_OBJECT_PLANE, "type", &type);
			p->type = (uint32_t)type;
			props_ok = plane_props(g_fd, p);
		}
		rec_begin("plane", r);
		kv_u("id", plane_ids[i]);
		if (!r) {
			kv_u("type", p->type); kv_x("possible", p->possible);
			kv_u("crtc", p->crtc_id); kv_u("fb", p->fb_id);
			kv_u("xrgb8888", p->xrgb); kv_u("props", (uint64_t)props_ok);
		}
		rec_end();
		if (r || !props_ok) continue;
		nplanes++;
	}
	for (int pass = 0; pass < 2 && pri < 0; pass++)
		for (int i = 0; i < nplanes; i++) {
			struct plane_info *p = &planes[i];
			if (p->type != PLANE_TYPE_PRIMARY || !p->xrgb || !(p->possible & (1u << crtc_idx)))
				continue;
			if (p->crtc_id && p->crtc_id != crtc_id) continue;
			if (pass == 0 && p->crtc_id != crtc_id) continue;
			pri = i; break;
		}
	for (int i = 0; i < nplanes; i++) {
		struct plane_info *p = &planes[i];
		if (i == pri || p->type == PLANE_TYPE_CURSOR || !p->xrgb ||
		    !(p->possible & (1u << crtc_idx)) || (p->crtc_id && p->crtc_id != crtc_id))
			continue;
		sec = i; break;
	}
	uint32_t c_mode = find_prop(g_fd, crtc_id, DRM_MODE_OBJECT_CRTC, "MODE_ID", NULL);
	uint32_t c_active = find_prop(g_fd, crtc_id, DRM_MODE_OBJECT_CRTC, "ACTIVE", NULL);
	uint32_t k_crtc = find_prop(g_fd, cid, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", NULL);
	rec_begin("atomic_props", (pri >= 0 && c_mode && c_active && k_crtc) ? 0 : -ENOENT);
	kv_u("primary", pri >= 0 ? planes[pri].id : 0);
	kv_u("helper", sec >= 0 ? planes[sec].id : 0);
	kv_u("crtc_mode_id", c_mode); kv_u("crtc_active", c_active); kv_u("conn_crtc_id", k_crtc);
	rec_end();
	if (pri < 0 || !c_mode || !c_active || !k_crtc)
		finish(EX_NOPIPE, "no_atomic_pipeline");
	/* v0.5: read-only property logging at start (GET ioctls only) */
	log_properties(g_fd, !off_mode, cid, crtc_id, planes[pri].id, plane_ids,
		       pr.count_planes < MAXOBJ ? pr.count_planes : MAXOBJ);
	check_stop("before_buffer");

	/* 9. dumb buffer, draw once, ADDFB2, mode blob */
	struct drm_mode_create_dumb cd;
	memset(&cd, 0, sizeof(cd));
	cd.width = W; cd.height = H; cd.bpp = 32;
	r = xioctl(g_fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd);
	if (!r && (cd.pitch < W * 4 || cd.size < (uint64_t)cd.pitch * H)) r = -EINVAL;
	struct drm_mode_map_dumb md;
	memset(&md, 0, sizeof(md));
	if (!r) { md.handle = cd.handle; r = xioctl(g_fd, DRM_IOCTL_MODE_MAP_DUMB, &md); }
	void *map = MAP_FAILED;
	if (!r) {
		map = mmap(NULL, (size_t)cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, (off_t)md.offset);
		if (map == MAP_FAILED) r = -errno;
	}
	if (!r) {
		draw_pattern((uint8_t *)map, cd.pitch, W, H, g_nonce);
		munmap(map, (size_t)cd.size);
	}
	struct drm_mode_fb_cmd2 fb;
	memset(&fb, 0, sizeof(fb));
	if (!r) {
		fb.width = W; fb.height = H; fb.pixel_format = FMT_XRGB8888;
		fb.handles[0] = cd.handle; fb.pitches[0] = cd.pitch; fb.offsets[0] = 0;
		r = xioctl(g_fd, DRM_IOCTL_MODE_ADDFB2, &fb);
	}
	struct drm_mode_create_blob blob;
	memset(&blob, 0, sizeof(blob));
	if (!r) {
		blob.data = (uint64_t)(uintptr_t)&mode; blob.length = sizeof(mode);
		r = xioctl(g_fd, DRM_IOCTL_MODE_CREATEPROPBLOB, &blob);
	}
	rec_begin("buffer", r);
	kv_u("w", W); kv_u("h", H); kv_u("handle", cd.handle); kv_u("pitch", cd.pitch);
	kv_u("size", cd.size); kv_u("fb", fb.fb_id); kv_u("mode_blob", blob.blob_id);
	kv_x("format", FMT_XRGB8888);
	rec_end();
	if (r) finish(EX_BUFFER, "buffer_failed");

	/* 10. TEST_ONLY attempts, then exactly one real commit */
	struct attempt plan[4];
	int na = plan_attempts(mp.use_current, is_expected_mode(&mode), sec >= 0, plan);
	rec_begin("plan", na ? 0 : -ENOENT);
	kv_u("attempts", (uint64_t)na);
	kv_u("use_current", (uint64_t)mp.use_current);
	kv_u("modeset_allowed", (uint64_t)is_expected_mode(&mode));
	kv_u("helper", (uint64_t)(sec >= 0));
	rec_end();
	if (na == 0)
		finish(EX_TESTREJECT, "no_allowed_attempt");
	struct areq a;
	int ok = -1;
	for (int t = 0; t < na && ok < 0; t++) {
		check_stop("before_test");
		memset(&a, 0, sizeof(a));
		if (plan[t].modeset) {
			a_obj(&a, cid); a_prop(&a, k_crtc, crtc_id);
			a_obj(&a, crtc_id); a_prop(&a, c_mode, blob.blob_id); a_prop(&a, c_active, 1);
		}
		if (!plan[t].split) {
			a_plane(&a, &planes[pri], fb.fb_id, crtc_id, 0, W, H);
		} else {
			a_plane(&a, &planes[pri], fb.fb_id, crtc_id, 0, W / 2, H);
			a_plane(&a, &planes[sec], fb.fb_id, crtc_id, W / 2, W - W / 2, H);
		}
		int off = 0;
		for (int i = 0; i < nplanes; i++)
			if (i != pri && !(plan[t].split && i == sec) && planes[i].crtc_id == crtc_id) {
				a_plane_off(&a, &planes[i]); off++;
			}
		uint32_t flags = DRM_MODE_ATOMIC_TEST_ONLY | (plan[t].modeset ? DRM_MODE_ATOMIC_ALLOW_MODESET : 0);
		r = a_commit(g_fd, &a, flags, 100);
		rec_begin("test_commit", r);
		kv_u("attempt", (uint64_t)t);
		kv_u("modeset", (uint64_t)plan[t].modeset);
		kv_s("layout", plan[t].split ? "split" : "single");
		kv_u("objs", a.nobj); kv_u("props", a.nprop); kv_u("planes_off", (uint64_t)off);
		kv_u("overflow", (uint64_t)a.over);
		kv_s("result", r ? "rejected" : "accepted");
		rec_end();
		if (a.over) finish(EX_NOPIPE, "request_overflow");
		if (!r) ok = t;
	}
	if (ok < 0)
		finish(EX_TESTREJECT, "test_rejected");
	check_stop("before_commit");

	/* The image-time bound starts here: alarm and deadline both count from
	 * the start of the real commit. One ioctl attempt, no retry. */
	unsigned alarm_s = hold_s + FSP_CLOSE_MARGIN_S;
	int64_t commit_t0 = mono_ns();
	alarm(alarm_s);
	r = a_commit(g_fd, &a, plan[ok].modeset ? DRM_MODE_ATOMIC_ALLOW_MODESET : 0, 1);
	if (!r) g_shown = 1;
	rec_begin("commit", r);
	kv_u("attempt", (uint64_t)ok);
	kv_u("modeset", (uint64_t)plan[ok].modeset);
	kv_s("layout", plan[ok].split ? "split" : "single");
	kv_u("commit_ms", (uint64_t)((mono_ns() - commit_t0) / 1000000));
	rec_end();
	if (r) finish(EX_COMMITFAIL, "commit_failed");

	/* 11. hold; hold() closes the fd as soon as the wait ends */
	int hr = hold(commit_t0, hold_s, alarm_s);
	finish(hr, hr == EX_OK ? "held_to_deadline" : (hr == EX_INTERRUPTED ? "interrupted" : "hold_error"));
}

/* ---- mode "holdtest": identical hold code, mock path, no ioctls --------------- */
static int run_holdtest(const char *mock, uint32_t hold_s)
{
	check_stop("before_open");
	/* stat first: a DRM node is refused without ever being opened */
	struct stat st0, st;
	if (stat(mock, &st0) != 0) {
		int e = errno;
		int nodev = (e == ENOENT || e == ENODEV || e == ENXIO || e == ENOTDIR);
		rec_begin("open", -e); kv_u("errno", (uint64_t)e); kv_str("dev", mock, FSP_PATH_MAX + 1);
		kv_s("at", "stat"); rec_end();
		finish(nodev ? EX_NODEV : EX_OPENFAIL, nodev ? "no_device" : "stat_failed");
	}
	if (S_ISCHR(st0.st_mode) && major(st0.st_rdev) == DRM_MAJOR) {
		rec_begin("open", -EPERM); kv_s("error", "mock_is_drm_device"); kv_s("at", "stat"); rec_end();
		finish(EX_USAGE, "mock_refused");
	}
	g_fd = open(mock, O_RDONLY | O_NOCTTY | O_CLOEXEC);
	if (g_fd < 0) {
		int e = errno;
		int nodev = (e == ENOENT || e == ENODEV || e == ENXIO);
		rec_begin("open", -e); kv_u("errno", (uint64_t)e); kv_str("dev", mock, FSP_PATH_MAX + 1);
		kv_s("at", "open"); rec_end();
		finish(nodev ? EX_NODEV : EX_OPENFAIL, nodev ? "no_device" : "open_failed");
	}
	if (fstat(g_fd, &st) != 0 || st.st_dev != st0.st_dev || st.st_ino != st0.st_ino ||
	    (S_ISCHR(st.st_mode) && major(st.st_rdev) == DRM_MAJOR)) {
		rec_begin("open", -EPERM); kv_s("error", "mock_changed"); kv_s("at", "fstat"); rec_end();
		finish(EX_USAGE, "mock_refused");          /* finish() closes it first */
	}
	rec_begin("open", 0); kv_str("dev", mock, FSP_PATH_MAX + 1); kv_s("mock", "1"); rec_end();
	unsigned alarm_s = hold_s + FSP_CLOSE_MARGIN_S;   /* same arming as show, at the same point */
	int64_t t = mono_ns();
	alarm(alarm_s);
	int hr = hold(t, hold_s, alarm_s);
	finish(hr, hr == EX_OK ? "held_to_deadline" : (hr == EX_INTERRUPTED ? "interrupted" : "hold_error"));
}

/* ---- mode "render": identical draw code into memory, written as PPM ----------- */
static int run_render(uint32_t W, uint32_t H, const char *out)
{
	if (W < 64 || H < 64 || W > 8192 || H > 8192) {
		rec_begin("render", -EINVAL); kv_u("w", W); kv_u("h", H); rec_end();
		finish(EX_USAGE, "bad_size");
	}
	uint32_t pitch = W * 4;
	uint8_t *buf = malloc((size_t)pitch * H);
	uint8_t *row = malloc((size_t)W * 3);
	if (!buf || !row) finish(EX_INTERNAL, "oom");
	draw_pattern(buf, pitch, W, H, g_nonce);
	int fd = open(out, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0) {
		int e = errno;
		rec_begin("render", -e); kv_str("out", out, FSP_PATH_MAX + 1); rec_end();
		finish(EX_INTERNAL, "render_open_failed");
	}
	char hdr[48];
	size_t hl = 0;
	char t[12];
	int n;
	hdr[hl++] = 'P'; hdr[hl++] = '6'; hdr[hl++] = '\n';
	n = 0; { uint32_t v = W; do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v); }
	while (n) hdr[hl++] = t[--n];
	hdr[hl++] = ' ';
	n = 0; { uint32_t v = H; do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v); }
	while (n) hdr[hl++] = t[--n];
	memcpy(hdr + hl, "\n255\n", 5); hl += 5;
	int ok = write(fd, hdr, hl) == (ssize_t)hl;
	uint64_t lit = 0, maxv = 0, sum = 0;
	for (uint32_t y = 0; ok && y < H; y++) {
		const uint32_t *p = (const uint32_t *)(buf + (size_t)y * pitch);
		for (uint32_t x = 0; x < W; x++) {
			uint8_t r = (uint8_t)(p[x] >> 16), g = (uint8_t)(p[x] >> 8), b = (uint8_t)p[x];
			row[x * 3] = r; row[x * 3 + 1] = g; row[x * 3 + 2] = b;
			if (r > C_BG) lit++;
			if (r > maxv) maxv = r;
			sum += r;
		}
		size_t want = (size_t)W * 3, off = 0;
		while (off < want) {
			ssize_t k = write(fd, row + off, want - off);
			if (k <= 0) { ok = 0; break; }
			off += (size_t)k;
		}
	}
	close(fd);
	rec_begin("render", ok ? 0 : -EIO);
	kv_u("w", W); kv_u("h", H); kv_str("out", out, FSP_PATH_MAX + 1);
	kv_u("lit_ppm", lit * 1000000 / ((uint64_t)W * H));
	kv_x("max", maxv);
	kv_u("mean_x1000", sum * 1000 / ((uint64_t)W * H));
	kv_u("rot", FSP_ROTATE_180 ? 180 : 0);
	rec_end();
	finish(ok ? EX_OK : EX_INTERNAL, ok ? "rendered" : "render_write_failed");
}

static void usage(void) __attribute__((noreturn));
static void usage(void)
{
	rec_begin("usage", -EINVAL);
	kv_s("help", "see_README");
	rec_end();
	finish(EX_USAGE, "usage");
}

int main(int argc, char **argv)
{
	g_t0 = mono_ns();
	crc_init();
	if (stdout_setup() != 0)
		_exit(EX_STDOUT);     /* nothing is written to an unacceptable stdout */
	signals_init();
	alarm(FSP_SETUP_BUDGET_S);   /* backstop for everything before the real commit */

	if (argc < 3 || !valid_nonce(argv[2]))
		usage();
	memcpy(g_nonce, argv[2], 8); g_nonce[8] = 0;

	const char *mode = argv[1];
	if (strcmp(mode, "render") == 0) {
		uint32_t W, H;
		if (argc != 6 || !parse_uint(argv[3], &W) || !parse_uint(argv[4], &H) || !valid_path(argv[5]))
			usage();
		rec_begin("start", 0); kv_s("mode", "render"); kv_s("ver", FSP_VERSION); kv_s("out", g_out_kind);
		rec_end();
		return run_render(W, H, argv[5]);
	}

	int is_off = strcmp(mode, "show-off") == 0;
	int is_show = strcmp(mode, "show") == 0 || is_off, is_ht = strcmp(mode, "holdtest") == 0;
	uint32_t req;
	if (!(is_show && (argc == 4 || argc == 5)) && !(is_ht && argc == 5))
		usage();
	if (!parse_uint(argv[3], &req))
		usage();
	uint32_t hold_s = req > FSP_HOLD_MAX_S ? FSP_HOLD_MAX_S : req;
	const char *dev = is_show ? (argc == 5 ? argv[4] : "/dev/dri/card0") : argv[4];
	if (!valid_path(dev))
		usage();

	rec_begin("start", 0);
	kv_s("mode", is_off ? "show-off" : (is_show ? "show" : "holdtest"));
	kv_s("ver", FSP_VERSION);
	kv_u("hold_req", req); kv_u("hold", hold_s); kv_u("hold_max", FSP_HOLD_MAX_S);
	kv_u("clamped", req > FSP_HOLD_MAX_S ? 1 : 0);
	kv_u("setup_alarm_s", FSP_SETUP_BUDGET_S);
	kv_u("close_margin_s", FSP_CLOSE_MARGIN_S);
	kv_str("dev", dev, FSP_PATH_MAX + 1);
	kv_s("out", g_out_kind);
	kv_u("rot", FSP_ROTATE_180 ? 180 : 0);
	kv_u("t0_ms", (uint64_t)(g_t0 / 1000000));
	rec_end();

	if (is_show)
		return run_show(dev, hold_s, is_off);
	return run_holdtest(dev, hold_s);
}

#else /* FSP_UNIT_TEST: pure-logic unit tests, run under qemu-aarch64 */
#include <stdio.h>
static int ut_fail;
static void ut(const char *name, int ok)
{
	printf("UT %s %s\n", name, ok ? "PASS" : "FAIL");
	if (!ok) ut_fail++;
}
static struct drm_mode_modeinfo mk(int w, int h, int r, int flags, int type)
{
	struct drm_mode_modeinfo m;
	memset(&m, 0, sizeof(m));
	m.hdisplay = (uint16_t)w; m.vdisplay = (uint16_t)h; m.vrefresh = (uint32_t)r;
	m.flags = (uint32_t)flags; m.type = (uint32_t)type;
	m.clock = (uint32_t)(r * 1000);   /* real modes of different refresh differ in timing */
	return m;
}
/* "stream" mode: emit a framed sample stream with the edge-case values
 * (zeroed mode name, empty driver name, literal "-") for check_stream.py. */
static void sample_stream(void)
{
	struct drm_mode_modeinfo z;
	memset(&z, 0, sizeof(z));
	memcpy(g_nonce, "0badc0de", 9);
	g_out_kind = "file";
	rec_mode("crtc_state", -1, &z);   /* name all zero bytes, as GETCRTC returns with no mode */
	kv_u("mode_valid", 0);
	rec_end();
	rec_begin("version", 0); kv_str("drv", "", 64); rec_end();
	rec_begin("sample", 0); kv_str("dash", "-", 8); kv_str("pct", "a b=c", 8); rec_end();
	finish(0, "sample");
}

/* ---- v0.5 mock DRM property model ("propsim"): exercises log_properties offline ----
 * Values follow fixed rules that tools/check_propsim.py re-derives independently:
 *   object o, property index i: value = o*1000 + i, except
 *     planes: i == 10 (SRC_W) -> o << 20 (a large value); "capabilities" -> blob 300 + plane index;
 *     connector: "CRTC_ID" 155, "mode_properties" blob 201, "topology_name" 14, "dsc_mode" 2,
 *                "topology_control" 0.
 *   plane 106 lacks its last property (exercises same_names=0).
 * Blobs: 201 = PS_MODE_PROPS; 300+k = the capabilities text with max_linewidth
 * 2560 (k even) or 4096 (k odd). */
#define PS_CONN 55
#define PS_CRTC 155
static const uint32_t ps_planes[20] = { 71, 97, 100, 103, 106, 109, 112, 115, 118, 121,
					124, 128, 131, 134, 137, 140, 143, 146, 149, 152 };
static const char *const ps_conn_names[] = { "EDID", "DPMS", "link-status", "non-desktop", "TILE", "CRTC_ID",
	"capabilities", "mode_properties", "dimming_bl_lut", "hdr_properties", "RETIRE_FENCE", "autorefresh",
	"qsync_mode", "dsc_mode", "frame_trigger_mode", "panel_mode", "bl_scale", "sv_bl_scale",
	"supported_colorspaces", "topology_name", "topology_control", "LP" };
static const char *const ps_crtc_names[] = { "ACTIVE", "MODE_ID", "OUT_FENCE_PTR", "VRR_ENABLED", "GAMMA_LUT",
	"GAMMA_LUT_SIZE", "DEGAMMA_LUT", "CTM", "input_fence_timeout", "output_fence", "output_fence_offset",
	"core_clk", "core_ab", "core_ib", "llcc_ab", "llcc_ib", "dram_ab", "dram_ib", "rot_prefill_bw",
	"rot_clk", "idle_time", "capabilities", "dest_scaler", "ds_lut_ed", "ds_lut_cir", "ds_lut_sep",
	"security_level", "cache_state", "frame_trigger_mode", "dnsc_blur" };
static const char *const ps_plane_names[] = { "type", "FB_ID", "IN_FENCE_FD", "CRTC_ID", "CRTC_X", "CRTC_Y",
	"CRTC_W", "CRTC_H", "SRC_X", "SRC_Y", "SRC_W", "SRC_H", "IN_FORMATS", "rotation", "zpos", "alpha",
	"input_fence", "multirect_mode", "blend_op", "src_config", "sspp_layout", "syscache_type", "bg_alpha",
	"color_fill", "prefill_size", "prefill_time", "capabilities", "fb_translation_mode", "h_decimate",
	"v_decimate", "scaler_v2", "csc_v1", "inverse_pma", "SDE_VIG_3D_LUT_GEN5", "SDE_VIG_GAMUT",
	"SDE_VIG_IGC", "SDE_DGM_1D", "SDE_DGM_GC", "SDE_VIG_1D_LUT_IGC", "SDE_VIG_3D_LUT", "ubwc_stats_roi",
	"cac_type", "excl_rect_v1", "scaler_v2_lut_ed", "scaler_v2_lut_cir", "scaler_v2_lut_sep",
	"COLOR_ENCODING", "COLOR_RANGE", "pixel_blend_mode", "src.ext/x" };
static const char *const ps_topo[] = { "sde_none", "sde_singlepipe", "sde_singlepipe_dsc", "sde_singlepipe_vdc",
	"sde_dualpipe", "sde_dualpipe_dsc", "sde_dualpipemerge", "sde_dualpipemerge_dsc", "sde_dualpipemerge_vdc",
	"sde_dualpipe_dscmerge", "sde_ppsplit", "sde_quadpipemerge", "sde_quadpipe_3dmerge_dsc",
	"sde_quadpipe_dscmerge", "sde_quadpipe_dsc4hsmerge" };
static const char PS_MODE_PROPS[] = "mode_name=4128x2208x90vid\ntopology=sde_quadpipe_dsc4hsmerge\n"
	"compression=dsc\nwb_topology=0\nmax_dsc_width=2064\npanel_mode=video\nbit_clk_rate=999999999\n"
	"hdr_luminance=-\nodd/even: 50% <>&\x01\xfe\n";
#define PS_PLANE_PROPS 50
/* property ids: object base + index (connector 1000+, crtc 2000+, plane k 3000 + 100*k) */
static int ps_obj(uint32_t id, uint32_t type, const char *const **names, int *n, int *k)
{
	*k = -1;
	if (type == DRM_MODE_OBJECT_CONNECTOR && id == PS_CONN) {
		*names = ps_conn_names; *n = (int)(sizeof(ps_conn_names) / sizeof(*ps_conn_names)); return 1000;
	}
	if (type == DRM_MODE_OBJECT_CRTC && id == PS_CRTC) {
		*names = ps_crtc_names; *n = (int)(sizeof(ps_crtc_names) / sizeof(*ps_crtc_names)); return 2000;
	}
	if (type == DRM_MODE_OBJECT_PLANE)
		for (int j = 0; j < 20; j++)
			if (ps_planes[j] == id) {
				*names = ps_plane_names; *n = PS_PLANE_PROPS - (id == 106); *k = j; return 3000 + 100 * j;
			}
	return -1;
}
static uint64_t ps_val(uint32_t obj, int base, const char *name, int i, int k)
{
	if (base == 1000) {
		if (!strcmp(name, "CRTC_ID")) return PS_CRTC;
		if (!strcmp(name, "mode_properties")) return 201;
		if (!strcmp(name, "topology_name")) return 14;
		if (!strcmp(name, "dsc_mode")) return 2;
		if (!strcmp(name, "topology_control")) return 0;
	}
	if (base >= 3000) {
		if (i == 10) return (uint64_t)obj << 20;
		if (!strcmp(name, "capabilities")) return 300 + (uint64_t)k;
	}
	return (uint64_t)obj * 1000 + (uint64_t)i;
}
static uint32_t ps_flags(const char *name)
{
	if (!strcmp(name, "topology_name") || !strcmp(name, "panel_mode")) return DRM_MODE_PROP_ENUM | DRM_MODE_PROP_IMMUTABLE;
	if (!strcmp(name, "dsc_mode") || !strcmp(name, "DPMS") || !strcmp(name, "blend_op")) return DRM_MODE_PROP_ENUM;
	if (!strcmp(name, "topology_control") || !strcmp(name, "rotation")) return DRM_MODE_PROP_BITMASK;
	if (!strcmp(name, "capabilities") || !strcmp(name, "mode_properties") || !strcmp(name, "EDID")) return DRM_MODE_PROP_BLOB | DRM_MODE_PROP_IMMUTABLE;
	if (!strcmp(name, "CRTC_ID") || !strcmp(name, "FB_ID")) return DRM_MODE_PROP_OBJECT;
	if (!strcmp(name, "CRTC_X") || !strcmp(name, "CRTC_Y")) return DRM_MODE_PROP_SIGNED_RANGE;
	return DRM_MODE_PROP_RANGE;
}
static int ps_blob(uint32_t id, char *out, size_t cap)
{
	if (id == 201) { memcpy(out, PS_MODE_PROPS, sizeof(PS_MODE_PROPS) - 1); return (int)sizeof(PS_MODE_PROPS) - 1; }
	if (id >= 300 && id < 320) {
		int k = (int)id - 300, n = 0;
		const char *pf = "pixel_formats=AB24,AR24,RA24,BA24,XB24,XR24,RX24,BX24,BG24,RG24,BG16,RG16,"
				 "AB15,AR15,BA15,RA15,XB15,XR15,BX15,RX15,AB12,AR12,BA12,RA12,XB12,XR12,BX12,RX12,"
				 "AB30,AR30,BA30,RA30,XB30,XR30,BX30,RX30,NV12,NV21,NV16,NV61,YV12,YUYV,YVYU,UYVY,VYUY,P010,TP10,Q410\n";
		for (const char *q = pf; *q && (size_t)n < cap; q++) out[n++] = *q;
		char tail[160];
		int t = 0;
		const char *a = "max_linewidth=", *b = k % 2 ? "4096" : "2560";
		const char *c = "\nmax_upscale=20\nmax_downscale=4\nmax_horizontal_deci=0\nmax_vertical_deci=0\nmax_per_pipe_bw=4500000\npipe_idx=";
		for (const char *q = a; *q; q++) tail[t++] = *q;
		for (const char *q = b; *q; q++) tail[t++] = *q;
		for (const char *q = c; *q; q++) tail[t++] = *q;
		tail[t++] = (char)('0' + k % 10); tail[t++] = '\n';
		for (int j = 0; j < t && (size_t)n < cap; j++) out[n++] = tail[j];
		return n;
	}
	return -1;
}
static int mock_ioctl(int fd, unsigned long req, void *arg)
{
	(void)fd;
	if (req == DRM_IOCTL_MODE_OBJ_GETPROPERTIES) {
		struct drm_mode_obj_get_properties *op = arg;
		const char *const *names; int n, k;
		int base = ps_obj(op->obj_id, op->obj_type, &names, &n, &k);
		if (base < 0) { errno = ENOENT; return -1; }
		if (op->count_props >= (uint32_t)n && op->props_ptr) {
			uint32_t *ids = (uint32_t *)(uintptr_t)op->props_ptr;
			uint64_t *vals = (uint64_t *)(uintptr_t)op->prop_values_ptr;
			for (int i = 0; i < n; i++) { ids[i] = (uint32_t)(base + i); vals[i] = ps_val(op->obj_id, base, names[i], i, k); }
		}
		op->count_props = (uint32_t)n;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETPROPERTY) {
		struct drm_mode_get_property *gp = arg;
		uint32_t pid = gp->prop_id;
		const char *nm = NULL;
		if (pid >= 1000 && pid < 1000 + sizeof(ps_conn_names) / sizeof(*ps_conn_names)) nm = ps_conn_names[pid - 1000];
		else if (pid >= 2000 && pid < 2000 + sizeof(ps_crtc_names) / sizeof(*ps_crtc_names)) nm = ps_crtc_names[pid - 2000];
		else if (pid >= 3000 && pid < 3000 + 100 * 20 && (pid - 3000) % 100 < PS_PLANE_PROPS) nm = ps_plane_names[(pid - 3000) % 100];
		if (!nm) { errno = ENOENT; return -1; }
		memset(gp->name, 0, sizeof(gp->name));
		strncpy(gp->name, nm, sizeof(gp->name) - 1);
		gp->flags = ps_flags(nm);
		uint32_t ne = 0;
		if (!strcmp(nm, "topology_name")) ne = 15;
		else if (!strcmp(nm, "dsc_mode")) ne = 3;
		if (ne && gp->count_enum_blobs >= ne && gp->enum_blob_ptr) {
			struct drm_mode_property_enum *en = (struct drm_mode_property_enum *)(uintptr_t)gp->enum_blob_ptr;
			for (uint32_t i = 0; i < ne; i++) {
				memset(&en[i], 0, sizeof(en[i]));
				en[i].value = i;
				strncpy(en[i].name, ne == 15 ? ps_topo[i] : (i == 0 ? "none" : (i == 1 ? "single" : "dual")), sizeof(en[i].name) - 1);
			}
		}
		gp->count_enum_blobs = ne;
		gp->count_values = 0;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETPROPBLOB) {
		struct drm_mode_get_blob *gb = arg;
		static char tmp[FSP_BLOB_MAX];
		int n = ps_blob(gb->blob_id, tmp, sizeof(tmp));
		if (n < 0) { errno = ENOENT; return -1; }
		if (gb->data && gb->length >= (uint32_t)n) memcpy((void *)(uintptr_t)gb->data, tmp, (size_t)n);
		gb->length = (uint32_t)n;
		return 0;
	}
	errno = ENOTTY;
	return -1;
}
/* "propsim [full|off]": the v0.5 start-of-run logging against the mock, framed as a real stream */
static void propsim(int full)
{
	memcpy(g_nonce, "0badc0de", 9);
	g_out_kind = "file";
	rec_begin("start", 0); kv_s("mode", full == 2 ? "propsim-twice" : (full ? "propsim-full" : "propsim-off")); kv_s("ver", FSP_VERSION); rec_end();
	log_properties(3, full, PS_CONN, PS_CRTC, 71, ps_planes, 20);
	if (full == 2)          /* "twice": the second pass must hit the optional budget */
		log_properties(3, 1, PS_CONN, PS_CRTC, 71, ps_planes, 20);
	finish(0, "propsim");
}

int main(int argc, char **argv)
{
	crc_init();
	if (argc > 1 && strcmp(argv[1], "stream") == 0)
		sample_stream();
	if (argc > 2 && strcmp(argv[1], "propsim") == 0)
		propsim(strcmp(argv[2], "twice") == 0 ? 2 : strcmp(argv[2], "full") == 0);
	struct drm_mode_modeinfo L[4];
	struct mode_pick p;

	/* mode policy */
	struct drm_mode_modeinfo e90 = mk(4128, 2208, 90, 0, DRM_MODE_TYPE_PREFERRED);
	struct drm_mode_modeinfo r72 = mk(4128, 2208, 72, 0, 0);
	struct drm_mode_modeinfo cur;
	L[0] = e90; L[1] = r72;
	p = pick_mode(L, 2, &r72, 1);
	ut("mode_current_active_in_list_used", p.use_current == 1 && strcmp(p.why, "crtc_current") == 0);
	p = pick_mode(L, 2, &r72, 0);
	ut("mode_current_inactive_not_used", !p.use_current && p.idx == 0);          /* v0.3 used it */
	cur = mk(4128, 2208, 60, 0, 0);
	p = pick_mode(L, 2, &cur, 1);
	ut("mode_current_not_in_list_not_used", !p.use_current && p.idx == 0);       /* v0.3 used it */
	cur = mk(4128, 2208, 90, DRM_MODE_FLAG_INTERLACE, 0);
	L[2] = cur;
	p = pick_mode(L, 3, &cur, 1);
	ut("mode_current_interlaced_not_used", !p.use_current && p.idx == 0);        /* v0.3 used it */
	p = pick_mode(L, 2, NULL, 0);
	ut("mode_expected_4128x2208_90", !p.use_current && p.idx == 0);
	L[0] = mk(4128, 2208, 72, 0, DRM_MODE_TYPE_PREFERRED); L[1] = mk(4128, 2208, 120, 0, 0);
	p = pick_mode(L, 2, NULL, 0);
	ut("mode_preferred_without_90_rejected", p.idx < 0 && !p.use_current);    /* v0.1 accepted */
	L[0] = mk(1920, 1080, 90, 0, DRM_MODE_TYPE_PREFERRED);
	p = pick_mode(L, 1, NULL, 0);
	ut("mode_other_resolution_90_rejected", p.idx < 0 && !p.use_current);     /* v0.1 accepted */
	L[0] = mk(4128, 2208, 90, DRM_MODE_FLAG_INTERLACE, 0);
	p = pick_mode(L, 1, NULL, 0);
	ut("mode_interlaced_rejected", p.idx < 0);
	p = pick_mode(L, 0, NULL, 0);
	ut("mode_empty_list_rejected", p.idx < 0 && !p.use_current);
	cur = mk(9000, 2208, 90, 0, 0);
	L[0] = cur;
	p = pick_mode(L, 1, &cur, 1);
	ut("mode_current_out_of_range_rejected", p.idx < 0 && !p.use_current);

	/* attempt order and modeset gating */
	struct attempt A[4];
	int n = plan_attempts(1, 1, 1, A);
	ut("plan_current_expected_helper", n == 4 && !A[0].modeset && !A[0].split && !A[1].modeset && A[1].split &&
	   A[2].modeset && !A[2].split && A[3].modeset && A[3].split);
	n = plan_attempts(1, 1, 0, A);
	ut("plan_current_expected_nohelper", n == 2 && !A[0].modeset && A[1].modeset && !A[0].split && !A[1].split);
	n = plan_attempts(0, 1, 1, A);
	ut("plan_nocurrent_helper", n == 2 && A[0].modeset && A[1].modeset && !A[0].split && A[1].split);
	n = plan_attempts(1, 0, 1, A);
	ut("plan_current_not_expected_no_modeset", n == 2 && !A[0].modeset && !A[1].modeset); /* v0.3 added modesets */
	n = plan_attempts(0, 0, 1, A);
	ut("plan_nothing_allowed", n == 0);

	/* empty / dash values are explicit tokens */
	memcpy(g_nonce, "0badc0de", 9);
	rec_begin("e", 0); kv_str("name", "", 8); rec_frame();
	ut("empty_string_is_dash", strstr(g_line, " name=- len=") != NULL);               /* v0.3: "name= " */
	char zeros[DRM_DISPLAY_MODE_LEN + 1];
	memset(zeros, 0, sizeof(zeros));
	rec_begin("e", 0); kv_str("name", zeros, sizeof(zeros)); rec_frame();
	ut("zeroed_mode_name_is_dash", strstr(g_line, " name=- len=") != NULL);
	rec_begin("e", 0); kv_str("name", "-", 8); rec_frame();
	ut("literal_dash_encoded", strstr(g_line, " name=%2D len=") != NULL);

	/* request builder refuses overflow */
	static struct areq a;
	memset(&a, 0, sizeof(a));
	for (int i = 0; i < MAXAOBJ; i++) a_obj(&a, (uint32_t)i + 1);
	ut("areq_64_objs_ok", !a.over && a.nobj == MAXAOBJ);
	a_obj(&a, 999);
	ut("areq_65th_obj_flags_overflow", a.over == 1 && a.nobj == MAXAOBJ);
	ut("areq_overflow_not_sent", a_commit(-1, &a, 0, 1) == -E2BIG);
	memset(&a, 0, sizeof(a));
	a_prop(&a, 1, 1);
	ut("areq_prop_without_obj_overflow", a.over == 1);

	/* framing */
	g_seq = 0; g_overflows = 0;
	ut("crc32_check_value", crc32_buf("123456789", 9) == 0xcbf43926u);
	memcpy(g_nonce, "0badc0de", 9);
	rec_begin("t", 0); kv_s("k", "v");
	size_t len = rec_frame();
	const char *want = "FSP1 nonce=0badc0de seq=0 step=t rc=0 k=v";
	char exp[128];
	snprintf(exp, sizeof(exp), "%s len=%zu crc=%08x END\n", want, strlen(want), crc32_buf(want, strlen(want)));
	ut("frame_len_crc", len == strlen(exp) && memcmp(g_line, exp, len) == 0);
	char big[600];
	memset(big, 'a', sizeof(big) - 1); big[sizeof(big) - 1] = 0;
	rec_begin("long", 0); kv_str("p", big, sizeof(big)); kv_str("q", big, sizeof(big));
	rec_frame();
	ut("frame_overflow_replaced_same_seq", strstr(g_line, "seq=1 step=overflow rc=-7 orig_step=long") != NULL &&
	   g_overflows == 1);
	char unterminated[4] = { 'a', 'b', 'c', 'd' };
	rec_begin("cut", 0); kv_str("p", unterminated, sizeof(unterminated));
	rec_frame();
	ut("str_cut_is_overflow_not_silent", strstr(g_line, "step=overflow") != NULL);
	char path[FSP_PATH_MAX + 2];
	memset(path, 'x', sizeof(path) - 1); path[sizeof(path) - 1] = 0;
	ut("path_201_rejected", !valid_path(path));
	path[FSP_PATH_MAX] = 0;
	ut("path_200_accepted", valid_path(path));

	/* v0.5: show-off precondition (FS-R-010 §4) */
	ut("precond_inactive_proven", crtc_provably_inactive(0, 22, 0) == 1);
	ut("precond_active_refused", crtc_provably_inactive(0, 22, 1) == 0);
	ut("precond_no_active_prop_refused", crtc_provably_inactive(0, 0, 0) == 0);
	ut("precond_getcrtc_failed_refused", crtc_provably_inactive(-22, 22, 0) == 0);

	/* v0.5: SDE info-blob parse (max_linewidth) */
	{
		const char *b1 = "pixel_formats=AB24,XB24\nmax_linewidth=2560\nmax_upscale=20\n";
		const char *b2 = "max_linewidth_x=1\nmax_linewidth=4096";      /* last line unterminated */
		const char *b3 = "foo_max_linewidth=1\nmax_linewidth=12a\n";
		const char *b4 = "max_linewidth=1234567890\n";
		ut("kvint_found", kv_text_int((const uint8_t *)b1, strlen(b1), "max_linewidth") == 2560);
		ut("kvint_prefix_not_confused_unterminated_ok", kv_text_int((const uint8_t *)b2, strlen(b2), "max_linewidth") == 4096);
		ut("kvint_not_at_line_start_or_bad_digits", kv_text_int((const uint8_t *)b3, strlen(b3), "max_linewidth") == -1);
		ut("kvint_ten_digits_refused", kv_text_int((const uint8_t *)b4, strlen(b4), "max_linewidth") == -1);
		ut("kvint_absent", kv_text_int((const uint8_t *)b1, strlen(b1), "scale_max") == -1);
		ut("kvint_empty_blob", kv_text_int((const uint8_t *)"", 0, "max_linewidth") == -1);
	}

	/* v0.5: packed-list and blob encodings */
	memcpy(g_nonce, "0badc0de", 9);
	rec_begin("e", 0); o_raw(" names="); o_tok("SRC.X", 8); o_putc('.'); o_tok("a/b", 8); o_putc('.'); o_tok("", 8); o_putc('.'); o_tok("-", 8); rec_frame();
	ut("o_tok_dot_slash_empty_dash", strstr(g_line, " names=SRC%2EX.a%2Fb.-.%2D len=") != NULL);
	{
		const uint8_t raw[] = { 'k', '=', '1', '\n', 0, 0xff, '-', '.' };
		rec_begin("e", 0); o_raw(" data="); o_bytes(raw, sizeof(raw)); rec_frame();
		ut("o_bytes_all_nonword_encoded", strstr(g_line, " data=k%3D1%0A%00%FF%2D%2E len=") != NULL);
		rec_begin("e", 0); o_raw(" data="); o_bytes(raw, 0); rec_frame();
		ut("o_bytes_empty_is_dash", strstr(g_line, " data=- len=") != NULL);
	}
	ut("type_letters", prop_type_letter(DRM_MODE_PROP_ENUM) == 'E' && prop_type_letter(DRM_MODE_PROP_BLOB | DRM_MODE_PROP_IMMUTABLE) == 'b' &&
	   prop_type_letter(DRM_MODE_PROP_RANGE) == 'R' && prop_type_letter(DRM_MODE_PROP_OBJECT) == 'O' &&
	   prop_type_letter(DRM_MODE_PROP_SIGNED_RANGE) == 'S' && prop_type_letter(DRM_MODE_PROP_BITMASK) == 'M');

	/* v0.5: optional-record budget: fits -> emitted with the next seq; the first that does
	 * not fit -> ONE opt_budget record with that same seq; later ones skipped, no seq used */
	{
		fflush(stdout);
		int saved = dup(1), dn = open("/dev/null", O_WRONLY);
		dup2(dn, 1);
		g_seq = 10; g_opt_bytes = 0; g_opt_skipped = 0; g_opt_closed = 0;
		rec_begin_opt("blob"); kv_s("k", "v"); rec_end_opt();
		int ok1 = g_seq == 11 && g_opt_bytes > 0 && !g_opt_closed;
		g_opt_bytes = FSP_OPT_MAX - 10;
		rec_begin_opt("blob"); kv_s("k", "v"); rec_end_opt();
		int ok2 = g_seq == 12 && g_opt_closed == 1 && g_opt_skipped == 1;   /* seq 11 = opt_budget */
		rec_begin_opt("blob"); kv_s("k", "v"); rec_end_opt();
		int ok3 = g_seq == 12 && g_opt_skipped == 2;
		fflush(stdout); dup2(saved, 1); close(saved); close(dn);
		ut("opt_fits_emitted_seq_advances", ok1);
		ut("opt_first_overflow_becomes_opt_budget_same_seq", ok2);
		ut("opt_later_skipped_no_seq_used", ok3);
	}

	printf("UT_TOTAL failures=%d\n", ut_fail);
	return ut_fail ? 1 : 0;
}
#endif
