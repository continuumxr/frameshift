/*
 * fs-pattern — put ONE static test image on the Quest 3 panels through
 * /dev/dri/card0 (msm_drm), hold it for a bounded time, then close and exit.
 *
 * FrameShift stage 3d, v0.7.1 (devices/quest3/stage3d/README.md "fs-pattern v0.7", "v0.7.1";
 * the stage-3c design devices/quest3/stage3c/DESIGN.md rev 3 §6 plus the stage-3d deltas).
 * Derived from the stage-3c v0.6 source (devices/quest3/stage3c/src/fs-pattern.c,
 * unchanged and still pinned for the stage-3c image). Offline-built; running it on
 * a device needs the full review of the stage-3d package and the PM's live sign-off.
 *
 * Changes from v0.7 in v0.7.1 (J-141: Unit 2's r1 exited 30 too_many_modes before any
 * commit: v2.7's DSI connector lists 305 modes, MAXMODES was 128; README §3a):
 *   - MAXMODES 128 -> 512: v2.7's panel node has min/max refresh 72/240 and no step
 *     sizes, so the driver builds 169 dfps rates x 2 timing nodes = 338 modes (305 after
 *     the kernel prunes the 33 modes of timing@0 whose clock overflows); 512 also holds
 *     2 timing nodes x the full 1..240 range (480). Static array, not on the stack.
 *   - the mode records: essential below FSP_ESS_MODES (24) as before; optional records
 *     only below FSP_LOG_MODES (48) or for an expected (4128x2208 @ 90) mode; every other
 *     mode is not logged and counted in opt_skipped, so 281 optional mode records do
 *     not use up the optional budget before the property logging (the stream bounds
 *     and the essential bytes are unchanged). The mode policy is unchanged.
 *   - the unit-test build's mock DRM model can serve the v2.7 connector set exactly as
 *     logged on Unit 2 (connectors 33/55/65, types 15/16/10, 37/305/0 modes), the 305
 *     modes computed as the v2.7 driver computes them (tools/v27-modes.py).
 *
 * Changes from v0.6 (PM decisions for stage 3d; each with a unit test, a mock-model
 * scenario, a render check or a static check; ../README.md):
 *   - mode "reset" (run 1 of stage 3d; replaces the lit run 1 of stage 3c), NO picture:
 *     one dumb buffer + framebuffer filled with BLACK (every pixel 0x00000000) and the
 *     mode blob are made first; then, on the CRTC the bootloader handed over,
 *     step A (reset_off): an atomic DISABLE: connector CRTC_ID = 0, CRTC MODE_ID = 0 and
 *       ACTIVE = 0, every plane bound to that CRTC FB_ID = 0 / CRTC_ID = 0 (a_plane_off,
 *       v0.5's helper); only the value 0; TEST_ONLY, then one real commit, post_state;
 *     step B (reset_on): the v0.5 modeset attempts (single, then split) on the black
 *       framebuffer, TEST_ONLY, the first accepted one committed once: a dark re-enable
 *       that ends the continuous splash (the DSI splash flag is cleared only on an enable);
 *     then close at once (lastclose disables everything through the full off path).
 *     So TWO real commits (ALLOW_MODESET, one try each), only property ids v0.6 already
 *     sets. B is planned before A is sent. A CRTC that is already provably inactive:
 *     nothing is committed (exit 0, already_inactive). Exit codes are v0.6's (31 = CRTC
 *     state not readable; 30 no mode; 40 buffer; 50 rejected; 60 commit failed).
 *   - PICTURE v0.7, per EYE (J-125: the eyes are swapped and each panel is canted
 *     inward): each eye's content is drawn in that eye's viewer coordinates into a
 *     private eye canvas and blitted into the buffer half that reaches that eye
 *     ("eyes=swap", the default: the LEFT eye is buffer half 1, x 2064..4127 [PM
 *     report, J-125]; "eyes=direct": half 0, as v0.6), with the in-buffer 180 degrees
 *     of v0.6 and a pre-rotation by "roll=<deg>" (default 21 [C: the PM's report and
 *     ro.boot.bootloader_screen_rotation=201 = 180 + 21]; -25..25; the LEFT eye
 *     counter-clockwise, the RIGHT eye clockwise, as the viewer sees it; 0 = none).
 *     Integer-only (a Q16 sine table, floor division), nearest-neighbour, so the levels
 *     stay exactly 0x80 / 0xFF. Bars per EYE: left eye "1 | 2", right eye "3 | 4".
 *     roll=0 with eyes=direct reproduces the v0.6 picture byte for byte (the v0.6
 *     layout); every other setting uses the v0.7 layout (the quadrant groups at
 *     q = (ew - 2 M_X) / 3 and 3u below the centre line, so that every group stays
 *     inside its own layer mixer for |roll| <= 25).
 *   - "show-off-quad", "render": optional arguments roll=<deg> eyes=<swap|direct>;
 *     the start record carries roll= and eyes=.
 *
 * Changes from v0.5 in v0.6 (each with a unit test, a mock-model scenario or a static
 * fixture; ../README.md "fs-pattern v0.6"):
 *   - the v0.6 PICTURE (DESIGN §6.3): same levels (field 0x80, marks 0xFF); the
 *     edge frame and corner square are removed; the 8 characters and their
 *     underline are unchanged; the cross keeps its vertical arm (the mixer seam)
 *     and its horizontal arm becomes a centre line from M_X to ew - M_X (the roll);
 *     the link bars become one QUADRANT GROUP per layer mixer: an "F" (chiral)
 *     above k bars, k = 1/2 (eye of buffer half 0, viewer left/right) and 3/4
 *     (half 1). Each group lies wholly inside its mixer's 1032 buffer columns.
 *   - mode "show-off-quad" (run 2): the inactive-CRTC precondition of show-off
 *     (exit 31 otherwise), then TEST_ONLY attempts in a fixed order: the v0.5
 *     2 x 2064 split request as a PROBE (TEST_ONLY only, never committed in the
 *     quad modes; policy below), then "quad_vig"
 *     (VIG0-3), then "quad_dma" (the stock DMA half-pairs): 4 planes x 1032 px,
 *     SRC_X = CRTC_X = 0/1032/2064/3096, zpos = {0, 0, 1, 1} by slot. Planes are
 *     selected from their capabilities blobs (type from max_upscale: 20 VIG,
 *     1 DMA; index from pipe_idx; rect from primary_smart_plane_id), EXACTLY one
 *     candidate per slot or the attempt is unavailable (missing/ambiguous) and
 *     issues no TEST_ONLY. The first accepted quad attempt is committed once.
 *     No quad accepted: exit 50, nothing committed, whatever the probe returned.
 *   - mode "show-off-solid" (run 3): as show-off-quad, buffer = XRGB 0x00FF0000
 *     in every pixel (a plain red field); NONCE only labels the stream.
 *   - read-only logging (GET ioctls only, no new ioctl): post_state (connector
 *     topology/dsc/control values; CRTC ACTIVE, MODE_ID and the clock/bandwidth
 *     votes; GETCRTC) and post_plane (per committed plane: CRTC_ID, FB_ID,
 *     CRTC_X/Y/W/H, SRC_X/Y/W/H, zpos) right after the real commit, before the
 *     hold starts; plane_caps per plane (pipe_idx, max_upscale,
 *     primary_smart_plane_id, max_linewidth, zpos, NV12 corroboration): essential
 *     in the quad modes; the connector capabilities blob; full property lists in
 *     show and show-off-quad; FSP_BLOB_MAX 8192; FSP_OPT_MAX 38912 and a separate
 *     FSP_OPT_MAX_SOLID 10240.
 *   - the ONLY new property SET is zpos, only inside a_plane_z, only with the
 *     compile-time table FSP_QUAD_Z = {0, 0, 1, 1} (PM decision J-109 #1). The
 *     request builder, a_plane, a_plane_off, a_prop and hold() are unchanged.
 *     Never set: sspp_layout, multirect_mode, topology_control, dsc_mode,
 *     core_*, llcc_*, dram_* votes, rotation.
 *   - "show" (run 1) keeps the v0.5 commit path: the same mode policy, TEST_ONLY
 *     order, layouts and plan record; only the picture and the read-only logging
 *     differ. "show-off" is kept as v0.5 (fixtures only).
 *   - POLICY (build review, wording; DESIGN §6.1, Q16, PM "run 1 unchanged"): run 1
 *     (`show`) deliberately COMMITS the reviewed v0.5 2 x 2064 split as the wake
 *     step. The rule "2 x 2064 only as TEST_ONLY" applies to the quad modes (runs 2
 *     and 3: show-off-quad, show-off-solid), where the split request is a probe and
 *     only a quad layout can be committed (tools/check_static.py checks both).
 *   - essential-record cap (build review): connector, mode, plane and plane_caps
 *     records are essential only up to FSP_ESS_CONNECTORS / FSP_ESS_MODES /
 *     FSP_ESS_PLANES (the counts of the mock-model maximum fixtures); every further
 *     one is an OPTIONAL record inside the opt budget, so the essential bytes stay
 *     within the measured stream bounds whatever the device reports.
 *
 * Mode "show" / "show-off" / "show-off-quad" / "show-off-solid":
 *   stdout must be a regular file, a pipe/FIFO (made O_NONBLOCK) or /dev/null
 *   -> open card0 -> require char device major 226 and driver "msm_drm"
 *   -> ATOMIC client cap (refused: exit 21; there is no legacy path)
 *   -> resources, connectors, the CRTC's current mode (GETCRTC), mode list
 *   -> (show-off*) the CRTC must be inactive, else exit 31, no commit
 *   -> mode = the CRTC's current mode, else exactly 4128x2208 @ 90 Hz
 *      non-interlaced from the list, else exit 30
 *   -> read-only property logging (plane capabilities: the quad selection inputs)
 *   -> one XRGB8888 dumb buffer, drawn once -> ADDFB2 -> mode blob
 *   -> TEST_ONLY attempts (show/show-off: v0.5 order; quad modes: split probe,
 *      quad_vig, quad_dma) -> the first accepted (quad, in the quad modes)
 *      request is committed for real, exactly once
 *   -> post_state/post_plane (GETs), then hold until commit start + HOLD_S
 *      (<= 10 s) or a stop signal
 *   -> close(fd) IMMEDIATELY, then the remaining records -> exit.
 *
 * Bounds on image time: the hold deadline; alarm(HOLD_S + 5) armed just
 * before the real commit (SIGALRM default action: terminate, which closes
 * the fd in the kernel); stdout can never block (see above). Plus PID 1's
 * supervision with KILL escalation (README).
 *
 * Never: sysfs/debugfs, backlight/brightness/BLU, DCS, legacy SETCRTC,
 * re-commits, animation, page flips, any property SET other than the v0.5
 * ones plus zpos as above, or any path other than the device (and the output
 * file in "render"/"render-solid").
 *
 * Offline modes (no DRM ioctls): render NONCE W H OUT.ppm; render-solid NONCE
 * W H OUT.ppm; holdtest NONCE HOLD MOCK. Built with -DFSP_UNIT_TEST, main() is
 * replaced by unit tests and a mock DRM model ("propsim", "sim").
 *
 * Output (local log format; PID 1 wraps it in FSB1 for transport):
 *   FSP1 nonce=<8 hex> seq=<n> step=<id> rc=<n> [k=v ...] len=<n> crc=<8 hex> END\n
 * len/crc32 cover the bytes before " len=". String bytes outside [A-Za-z0-9_./-]
 * are %XX-encoded; the v0.6 plan lists need none: quad_vig=71.97.100.103,
 * pipe_vig=vig-0.vig-1.vig-2.vig-3, zpos_set=0.0.1.1, quad_dma=unavailable-missing
 * (DESIGN's "71,97,100,103", "vig:0", "unavailable:missing"). The stream ends with step=eos.
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
#define FSP_VERSION        "0.7.1"
#define FSP_HOLD_MAX_S     10    /* hard ceiling on the hold (PM decision: <= 10 s; no fan is driven) */
#define FSP_SETUP_BUDGET_S 30    /* backstop for everything before the real commit */
#define FSP_CLOSE_MARGIN_S 5     /* after the deadline: close (preclose + lastclose waits) and exit */
#define FSP_PATH_MAX       200   /* longest accepted path argument */
#define FSP_OPT_MAX        38912 /* bytes of OPTIONAL records per run: show, show-off, show-off-quad (DESIGN §6.5) */
#define FSP_OPT_MAX_SOLID  10240 /* the same for show-off-solid (its stdout cap is 28672) */
#define FSP_BLOB_MAX       8192  /* longest blob read for logging; longer: length only */
#define FSP_BLOB_CHUNK     240   /* raw blob bytes per record (<= 720 encoded) */
#define FSP_ESS_CONNECTORS 3     /* per-object records ESSENTIAL up to these counts (the mock-model maximum */
#define FSP_ESS_MODES      24    /* fixtures stage3c/fixtures/sim/ *-max); each further connector / mode / plane / */
#define FSP_ESS_PLANES     20    /* plane_caps record is OPTIONAL (opt budget): the essential bytes are capped */
#if FSP_HOLD_MAX_S > 10 || FSP_HOLD_MAX_S < 1
#error "FSP_HOLD_MAX_S must be 1..10"
#endif
#if FSP_SETUP_BUDGET_S > 30 || FSP_CLOSE_MARGIN_S > 10
#error "backstop margins too large"
#endif
#if FSP_OPT_MAX > 38912 || FSP_OPT_MAX_SOLID > 10240 || FSP_BLOB_MAX > 8192
#error "logging budgets above the reviewed stream bounds (DESIGN §6.5)"
#endif
#if FSP_ESS_CONNECTORS > 3 || FSP_ESS_MODES > 24 || FSP_ESS_PLANES > 20
#error "essential-record counts above the measured stream bounds (build review; check-timing-3c.py)"
#endif
#define FSP_LOG_MODES      48    /* v0.7.1: mode records logged (optional beyond FSP_ESS_MODES); expected modes always */
#if FSP_LOG_MODES < FSP_ESS_MODES || FSP_LOG_MODES > 64
#error "FSP_LOG_MODES must be FSP_ESS_MODES..64"
#endif

#define FSP_ROTATE_180     1     /* panel orientation 180 (eureka-panel-sharp.dtsi:34) [D] */
#define FSP_EYE_W          2064  /* the eye size the margins below are given for (DESIGN §6.3) */
#define FSP_EYE_H          2208
#define FSP_MARGIN_X       480   /* recovery margins: the visible lens area [C]; scaled with the size */
#define FSP_MARGIN_Y       456
#define FSP_SOLID_XRGB     0x00FF0000u   /* run 3: B=00 G=00 R=FF X=00 in every pixel (DESIGN §6.4) */
#define FSP_ROLL_DEFAULT   21    /* v0.7: per-eye pre-rotation, degrees [C: J-125 report; screen_rotation 201] */
#define FSP_ROLL_MAX       25    /* |roll| bound: every quadrant group stays inside its mixer (README) */
#define FSP_EYES_SWAP      1     /* v0.7 default: the LEFT eye is buffer half 1 [PM report, J-125] */
#if FSP_ROLL_MAX > 25 || FSP_ROLL_DEFAULT > FSP_ROLL_MAX || FSP_ROLL_DEFAULT < -FSP_ROLL_MAX
#error "roll bounds"
#endif
#define DRM_MAJOR          226
#define FMT_XRGB8888       0x34325258u   /* fourcc 'X','R','2','4' */
#define PLANE_TYPE_OVERLAY 0     /* enum drm_plane_type, include/drm/drm_plane.h (v2.7) */
#define PLANE_TYPE_PRIMARY 1
#define PLANE_TYPE_CURSOR  2

/* ---- exit codes (README "Exit codes"; v0.5's table, no new code) ---------- */
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
	EX_PRECOND     = 31, /* show-off*: the CRTC is not provably inactive at start: no commit */
	EX_BUFFER      = 40, /* dumb buffer / mmap / ADDFB2 / mode blob failed */
	EX_TESTREJECT  = 50, /* every (quad) TEST_ONLY attempt rejected or unavailable: no real commit made */
	EX_COMMITFAIL  = 60, /* the real commit failed */
	EX_INTERRUPTED = 70, /* SIGTERM/SIGINT/SIGHUP before the deadline */
};

/* run kinds (argv[1]); every show-off* kind requires a provably inactive CRTC;
 * v0.7: K_RESET disables the handed-over CRTC and shows nothing */
enum { K_SHOW = 0, K_OFF = 1, K_QUAD = 2, K_SOLID = 3, K_RESET = 4 };

#ifdef FSP_UNIT_TEST
/* unit-test build only: the whole show path runs against a mock DRM device
 * ("/mock/card0", see the end of this file). These wrappers pass every other
 * path and fd through to the real calls; the device build has none of them. */
static int mock_stat(const char *p, struct stat *st);
static int mock_fstat(int fd, struct stat *st);
static int mock_open(const char *p, int fl, ...);
static void *mock_mmap(void *a, size_t n, int prot, int fl, int fd, off_t off);
#define stat(p, s) mock_stat((p), (s))
#define fstat(fd, s) mock_fstat((fd), (s))
#define open(...) mock_open(__VA_ARGS__)
#define mmap(a, n, p, f, fd, o) mock_mmap((a), (n), (p), (f), (fd), (o))
static int mock_munmap(void *a, size_t n);
#define munmap(a, n) mock_munmap((a), (n))
#endif

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
 * emitted only while the optional bytes stay within g_opt_max (FSP_OPT_MAX, or
 * FSP_OPT_MAX_SOLID in show-off-solid). The first one
 * that does not fit is discarded and replaced, with the same seq, by ONE
 * step=opt_budget record; every later optional record is discarded too. The
 * stream therefore stays gap-free, and nothing is cut silently: eos reports
 * opt_bytes and opt_skipped. */
static unsigned g_opt_bytes, g_opt_skipped;
static unsigned g_opt_max = FSP_OPT_MAX;   /* v0.6: FSP_OPT_MAX_SOLID in show-off-solid */
static int g_opt_closed;

static void rec_begin_opt_rc(const char *step, int64_t rc)
{
	g_step = step; g_rec_seq = g_seq; g_rec_rc = rc;
	rec_head(step, rc, g_rec_seq);
}
static void rec_begin_opt(const char *step) { rec_begin_opt_rc(step, 0); }

static void rec_end_opt(void)
{
	const char *step = g_step;
	unsigned ov = g_overflows;
	size_t n = rec_frame();
	if (!g_opt_closed && g_opt_bytes + n <= g_opt_max) {
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
	kv_u("max", g_opt_max);
	kv_u("used", g_opt_bytes);
	kv_s("first_skipped", step);
	rec_end();
}

/* build review (essential-record cap): the record of the I-th object of a kind (connector, mode,
 * plane, plane_caps) is essential while I < ESS and an optional record after that, so the essential
 * bytes do not grow with the counts the device reports. */
static void rec_begin_ess(const char *step, int64_t rc, uint32_t i, uint32_t ess)
{
	if (i < ess) rec_begin(step, rc); else rec_begin_opt_rc(step, rc);
}
static void rec_end_ess(uint32_t i, uint32_t ess)
{
	if (i < ess) rec_end(); else rec_end_opt();
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
 * Drawn in "viewer" coordinates of one eye (v0.7: into an eye canvas) and mapped
 * into that eye's buffer half; with FSP_ROTATE_180 each half is rotated 180 degrees
 * (the v0.1 mapping, now in blit_eye, plus the v0.7 roll). v0.5 levels (FS-R-010 §4): a mid-grey field and every
 * mark in white. v0.6 layout (DESIGN §6.3): no frame or corner square; the
 * characters and underline as v0.5; the vertical arm (the mixer seam); a
 * centre line from M_X to ew - M_X; one quadrant group (F + k bars) per mixer. */
#define C_BG     0x80
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
#define GLYPH_F 15

/* v0.7: rect() draws one eye in VIEWER coordinates into the eye canvas `eye` (ew x h,
 * one grey byte per pixel); blit_eye() then maps it into the buffer half at ex0 (the
 * 180 degrees and the roll). base/pitch/w/h describe the whole XRGB buffer. */
struct canvas {
	uint8_t *base;
	uint32_t pitch, w, h;
	uint32_t ex0, ew;
	uint8_t *eye;
};

/* v0.7 picture parameters (main() sets them from the arguments; compiled defaults) */
static int g_roll = FSP_ROLL_DEFAULT;     /* degrees, -FSP_ROLL_MAX..FSP_ROLL_MAX */
static int g_eyes_swap = FSP_EYES_SWAP;   /* 1: the left eye is buffer half 1 */

/* sin / cos of 0..25 degrees in Q16 (round(65536 * sin d), round(65536 * cos d)); integer
 * only, so the C render and the Python port (tools/preview.py) agree bit for bit */
static const int32_t SIN_Q16[FSP_ROLL_MAX + 1] = {
	0, 1144, 2287, 3430, 4572, 5712, 6850, 7987, 9121, 10252, 11380, 12505, 13626,
	14742, 15855, 16962, 18064, 19161, 20252, 21336, 22415, 23486, 24550, 25607, 26656, 27697 };
static const int32_t COS_Q16[FSP_ROLL_MAX + 1] = {
	65536, 65526, 65496, 65446, 65376, 65287, 65177, 65048, 64898, 64729, 64540, 64332, 64104,
	63856, 63589, 63303, 62997, 62672, 62328, 61966, 61584, 61183, 60764, 60326, 59870, 59396 };

/* floor(a / b) for b > 0 (C division truncates toward zero) */
static int64_t fdiv(int64_t a, int64_t b)
{
	int64_t q = a / b;
	return (a % b != 0 && a < 0) ? q - 1 : q;
}

/* the signed sine for one eye: the LEFT eye is pre-rotated counter-clockwise by roll, the
 * RIGHT eye clockwise (as the viewer sees it; y grows downwards) */
static int32_t eye_sin(int left_eye, int roll)
{
	int a = roll < 0 ? -roll : roll;
	int32_t s = SIN_Q16[a];
	if (roll < 0) s = -s;
	return left_eye ? s : -s;
}

/* the buffer half (0: x 0..w/2-1, 1: x w/2..w-1) that reaches the given eye */
static int eye_half(int left_eye, int swap)
{
	return (left_eye ? 1 : 0) ^ (swap ? 0 : 1);
}

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

/* v0.7: a rectangle in viewer coordinates of the current eye, into the eye canvas
 * (same clamping as v0.6; the 180 degrees moved to blit_eye) */
static void rect(struct canvas *c, int64_t x0, int64_t y0, int64_t x1, int64_t y1, uint8_t v)
{
	if (x0 < 0) x0 = 0;
	if (y0 < 0) y0 = 0;
	if (x1 > (int64_t)c->ew) x1 = c->ew;
	if (y1 > (int64_t)c->h) y1 = c->h;
	if (x0 >= x1 || y0 >= y1)
		return;
	for (int64_t y = y0; y < y1; y++)
		memset(c->eye + (size_t)y * c->ew + (size_t)x0, v, (size_t)(x1 - x0));
}

/* v0.7: the eye canvas into the buffer half at ex0. For each buffer pixel: viewer
 * position (the 180 degrees of v0.6 when FSP_ROTATE_180), then the inverse of the
 * pre-rotation (sine S, cosine CS, Q16) around the eye centre, nearest neighbour, in doubled
 * integer coordinates (pixel k spans [2k - ew, 2k + 2 - ew)); outside the canvas: C_BG.
 * S = 0 is the identity (v0.6's mapping exactly). */
static void blit_eye(struct canvas *c, int32_t s, int32_t cs)
{
	int64_t ew = c->ew, h = c->h;
	for (int64_t by = 0; by < h; by++) {
		uint32_t *row = (uint32_t *)(c->base + (size_t)by * c->pitch) + c->ex0;
#if FSP_ROTATE_180
		int64_t y = h - 1 - by;
#else
		int64_t y = by;
#endif
		int64_t Y = 2 * y + 1 - h;
		for (int64_t bx = 0; bx < ew; bx++) {
#if FSP_ROTATE_180
			int64_t x = ew - 1 - bx;
#else
			int64_t x = bx;
#endif
			int64_t X = 2 * x + 1 - ew;
			int64_t sx = fdiv(X * cs - Y * s + ew * 65536, 131072);
			int64_t sy = fdiv(X * s + Y * cs + h * 65536, 131072);
			uint8_t v = (sx >= 0 && sx < ew && sy >= 0 && sy < h) ? c->eye[(size_t)sy * (size_t)ew + (size_t)sx] : C_BG;
			row[bx] = 0xff000000u | ((uint32_t)v << 16) | ((uint32_t)v << 8) | v;
		}
	}
}

static int hexval(char ch)
{
	if (ch >= '0' && ch <= '9') return ch - '0';
	if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
	return -1;
}

/* One hex-font glyph G with cell U, top-left (X, Y), viewer coordinates. */
static void draw_glyph(struct canvas *c, int g, int64_t x, int64_t y, int64_t u)
{
	for (int r = 0; r < 7; r++)
		for (int col = 0; col < 5; col++)
			if (glyph[g][r] & (0x10 >> col))
				rect(c, x + col * u, y + r * u, x + (col + 1) * u, y + (r + 1) * u, C_TEXT);
}

/* A quadrant group centred at viewer x = GX: an upright "F" (top at FY) above K
 * bars (2u x 8u, gap 2u, top at BY). */
static void draw_group(struct canvas *c, int64_t gx, int64_t fy, int64_t by, int64_t u, int k)
{
	draw_glyph(c, GLYPH_F, gx - 5 * u / 2, fy, u);
	int64_t bw = 2 * u, bh = 8 * u, gap = 2 * u;
	int64_t total = k * bw + (k - 1) * gap, bx = gx - total / 2;
	for (int i = 0; i < k; i++)
		rect(c, bx + i * (bw + gap), by, bx + i * (bw + gap) + bw, by + bh, C_CROSS);
}

/* One eye: BARS_LEFT / BARS_RIGHT bars in the viewer-left / viewer-right part.
 * With the in-buffer 180 degrees the viewer-right part lies in the LEFT 1032
 * columns of the buffer half (DESIGN §6.3 table). */
static void draw_eye(struct canvas *c, const char *nonce, int bars_left, int bars_right, int legacy)
{
	int64_t ew = c->ew, h = c->h;
	int64_t cx = ew / 2, cy = h / 2;
	int64_t u = ew / 47 / 2;
	if (u < 2) u = 2;
	int64_t bt = ew / 258;
	if (bt < 2) bt = 2;
	int64_t arm = h / 12, ct = bt;
	int64_t mx = ew * FSP_MARGIN_X / FSP_EYE_W;

	/* centre line (the former horizontal arm): M_X ... ew - M_X, bt thick */
	rect(c, mx, cy - ct / 2, ew - mx, cy - ct / 2 + ct, C_CROSS);
	/* vertical arm (kept): it straddles the mixer seam at ew / 2 */
	rect(c, cx - ct / 2, cy - arm, cx - ct / 2 + ct, cy + arm, C_CROSS);

	/* the 8 characters and their underline (unchanged since v0.1) */
	int64_t adv = 6 * u, tw = 8 * adv - u, gh = 7 * u;
	int64_t tx = cx - tw / 2, ty = cy - arm - 3 * u - gh - 2 * u;
	for (int i = 0; i < 8; i++) {
		int g = hexval(nonce[i]);
		if (g < 0) continue;
		draw_glyph(c, g, tx + i * adv, ty, u);
	}
	rect(c, tx, ty + gh + u, tx + tw, ty + gh + u + u / 2 + 1, C_TEXT);

	/* the quadrant groups. v0.6 (legacy): centred at cx -/+ q, q = (ew - 2 M_X) / 4, the F top at
	 * cy + arm + 3u. v0.7: q = (ew - 2 M_X) / 3 and the F top 3u below the centre line, so that a
	 * group stays inside its own mixer after the pre-rotation (README "v0.7 layout") */
	int64_t q = legacy ? (ew - 2 * mx) / 4 : (ew - 2 * mx) / 3;
	int64_t fy = legacy ? cy + arm + 3 * u : cy + 3 * u, by = fy + 7 * u + 2 * u;
	draw_group(c, cx - q, fy, by, u, bars_left);
	draw_group(c, cx + q, fy, by, u, bars_right);
}

/* v0.7: each EYE drawn in its own viewer coordinates (the left eye "1 | 2", the right eye
 * "3 | 4"), pre-rotated by g_roll (left counter-clockwise, right clockwise) and blitted into
 * the buffer half that reaches it (eye_half, g_eyes_swap). roll 0 with eyes=direct is the
 * v0.6 picture byte for byte. Returns 0, or -ENOMEM (the eye canvas). */
static int draw_pattern(uint8_t *base, uint32_t pitch, uint32_t w, uint32_t h, const char *nonce)
{
	struct canvas c = { base, pitch, w, h, 0, 0, NULL };
	uint32_t ewmax = w - w / 2;
	int legacy = g_roll == 0 && !g_eyes_swap;
	c.eye = malloc((size_t)ewmax * h);
	if (!c.eye)
		return -ENOMEM;
	fill_buf(&c, 0, 0, w, h, C_BG);
	for (int left = 1; left >= 0; left--) {
		int half = eye_half(left, g_eyes_swap);
		int a = g_roll < 0 ? -g_roll : g_roll;
		c.ex0 = half ? w / 2 : 0;
		c.ew = half ? w - w / 2 : w / 2;
		memset(c.eye, C_BG, (size_t)c.ew * h);
		draw_eye(&c, nonce, left ? 1 : 3, left ? 2 : 4, legacy);
		blit_eye(&c, eye_sin(left, g_roll), COS_Q16[a]);
	}
	free(c.eye);
	return 0;
}

/* run 3: every pixel FSP_SOLID_XRGB; no text, frame or marks (DESIGN §6.4) */
static void draw_solid(uint8_t *base, uint32_t pitch, uint32_t w, uint32_t h)
{
	for (uint32_t y = 0; y < h; y++) {
		uint32_t *row = (uint32_t *)(base + (size_t)y * pitch);
		for (uint32_t x = 0; x < w; x++)
			row[x] = FSP_SOLID_XRGB;
	}
}

/* v0.7 reset (step B): every pixel XRGB 0x00000000; nothing is drawn */
static void draw_black(uint8_t *base, uint32_t pitch, uint32_t w, uint32_t h)
{
	for (uint32_t y = 0; y < h; y++)
		memset(base + (size_t)y * pitch, 0, (size_t)w * 4);
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

/* v0.7 picture options: "roll=<-25..25>" (decimal, optional '-', no leading zeros except "0")
 * and "eyes=swap|direct". Returns 1 (valid option, applied), 0 (not an option: no '='),
 * -1 (an option word, but invalid). Each option at most once. */
static int g_opt_roll_seen, g_opt_eyes_seen;
static int parse_opt(const char *s)
{
	if (!strchr(s, '='))
		return 0;
	if (strncmp(s, "roll=", 5) == 0 && !g_opt_roll_seen) {
		const char *v = s + 5;
		int neg = 0, val = 0;
		if (*v == '-') { neg = 1; v++; }
		size_t n = strlen(v);
		if (n < 1 || n > 2 || (n == 2 && v[0] == '0') || (neg && n == 1 && v[0] == '0'))
			return -1;
		for (size_t i = 0; i < n; i++) {
			if (v[i] < '0' || v[i] > '9') return -1;
			val = val * 10 + (v[i] - '0');
		}
		if (val > FSP_ROLL_MAX)
			return -1;
		g_roll = neg ? -val : val;
		g_opt_roll_seen = 1;
		return 1;
	}
	if (strcmp(s, "eyes=swap") == 0 && !g_opt_eyes_seen) { g_eyes_swap = 1; g_opt_eyes_seen = 1; return 1; }
	if (strcmp(s, "eyes=direct") == 0 && !g_opt_eyes_seen) { g_eyes_swap = 0; g_opt_eyes_seen = 1; return 1; }
	return -1;
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
#define MAXMODES 512    /* v0.7.1 (was 128): v2.7 lists 305 (338 before pruning; README §3a limit table) */
#define MAXPROPS 128
#define MAXFMTS  512
#if MAXMODES < 480
#error "MAXMODES must hold 2 timing nodes x 240 refresh rates (v2.7: 338 built, 305 listed)"
#endif

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
	uint32_t p_zpos;          /* v0.6: from the plane's property list (log_plane_caps); quad attempts only */
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

static void rec_mode(const char *step, int idx, const struct drm_mode_modeinfo *m, int opt)
{
	if (opt) rec_begin_opt(step); else rec_begin(step, 0);
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

/* The connector's topology: ALWAYS logged (an essential record; read-only).
 * v0.6: also returns the connector's capabilities blob id (logged as an
 * optional blob in show and show-off-quad; DESIGN §6.5). The record is v0.5's. */
static void log_conn_topology(int fd, uint32_t cid, uint32_t *mode_props_blob, uint32_t *conn_caps_blob)
{
	static struct pinfo cp[MAXPROPS];
	char tname[DRM_PROP_NAME_LEN + 1];
	int n = obj_pinfo(fd, cid, DRM_MODE_OBJECT_CONNECTOR, cp);
	int it = n > 0 ? pinfo_find(cp, n, "topology_name") : -1;
	int ic = n > 0 ? pinfo_find(cp, n, "topology_control") : -1;
	int id = n > 0 ? pinfo_find(cp, n, "dsc_mode") : -1;
	int im = n > 0 ? pinfo_find(cp, n, "mode_properties") : -1;
	int ik = n > 0 ? pinfo_find(cp, n, "capabilities") : -1;
	memcpy(tname, "none", 5);
	if (it >= 0) enum_name(fd, cp[it].id, cp[it].val, tname, sizeof(tname));
	*mode_props_blob = im >= 0 ? (uint32_t)cp[im].val : 0;
	*conn_caps_blob = ik >= 0 ? (uint32_t)cp[ik].val : 0;
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

/* ---- v0.6 plane capabilities (GET only; the quad selection inputs, DESIGN §6.2) ---- */
struct pcap {
	uint32_t id, bytes, zpos_prop;
	int read_rc, zpos_found, nv12;
	int64_t mlw, pipe_idx, max_upscale, smart;
	uint64_t zpos_val;
};
static struct pcap g_caps[MAXOBJ];
static int g_ncaps;

/* 1 if the "KEY=" line of an SDE info blob lists TOKEN (exactly, or as TOKEN/<modifier>;
 * elements separated by spaces or commas), 0 if the line exists without it, -1 if
 * there is no such line. Corroboration only (DESIGN §6.2: NV12 is never a gate). */
static int kv_text_has(const uint8_t *p, size_t n, const char *key, const char *tok)
{
	size_t kl = strlen(key), tl = strlen(tok), i = 0;
	while (i < n) {
		size_t e = i;
		while (e < n && p[e] != '\n') e++;
		if (e - i > kl && memcmp(p + i, key, kl) == 0 && p[i + kl] == '=') {
			size_t j = i + kl + 1;
			while (j < e) {
				size_t s = j;
				while (j < e && p[j] != ' ' && p[j] != ',') j++;
				if (j - s >= tl && memcmp(p + s, tok, tl) == 0 && (j - s == tl || p[s + tl] == '/'))
					return 1;
				j++;
			}
			return 0;
		}
		i = e + 1;
	}
	return -1;
}

static void kv_n(const char *k, int64_t v) { if (v >= 0) kv_u(k, (uint64_t)v); else kv_s(k, "none"); }

/* step=plane_caps: essential in the quad modes, optional in show. smart = the
 * blob's primary_smart_plane_id (rect-1 planes only), zpos = the property's value. */
static void log_plane_caps(int fd, uint32_t pid, int essential, uint32_t *caps_blob_out)
{
	static struct pinfo pp[MAXPROPS];
	int n = obj_pinfo(fd, pid, DRM_MODE_OBJECT_PLANE, pp);
	int ic = n > 0 ? pinfo_find(pp, n, "capabilities") : -1;
	int iz = n > 0 ? pinfo_find(pp, n, "zpos") : -1;
	uint32_t blob = ic >= 0 ? (uint32_t)pp[ic].val : 0, len = 0;
	int r = blob ? read_blob(fd, blob, &len) : -ENOENT;
	struct pcap k;
	memset(&k, 0, sizeof(k));
	k.id = pid; k.read_rc = r < 0 ? r : 0; k.bytes = len;
	k.mlw = k.pipe_idx = k.max_upscale = k.smart = -1;
	k.nv12 = -1;
	if (r >= 0) {
		k.mlw = kv_text_int(g_blob, (size_t)r, "max_linewidth");
		k.pipe_idx = kv_text_int(g_blob, (size_t)r, "pipe_idx");
		k.max_upscale = kv_text_int(g_blob, (size_t)r, "max_upscale");
		k.smart = kv_text_int(g_blob, (size_t)r, "primary_smart_plane_id");
		k.nv12 = kv_text_has(g_blob, (size_t)r, "pixel_formats", "NV12");
	}
	if (iz >= 0) { k.zpos_found = 1; k.zpos_prop = pp[iz].id; k.zpos_val = pp[iz].val; }
	if (g_ncaps < MAXOBJ) g_caps[g_ncaps++] = k;
	*caps_blob_out = blob;
	if (essential) rec_begin("plane_caps", 0); else rec_begin_opt("plane_caps");
	kv_u("plane", pid); kv_i("read_rc", k.read_rc); kv_u("caps_bytes", len);
	kv_n("max_linewidth", k.mlw); kv_n("pipe_idx", k.pipe_idx); kv_n("max_upscale", k.max_upscale);
	kv_n("smart", k.smart);
	if (k.zpos_found) kv_u("zpos", k.zpos_val); else kv_s("zpos", "none");
	kv_n("nv12", k.nv12);
	if (essential) rec_end(); else rec_end_opt();
}

/* The whole start-of-run logging (read-only). show: everything (plane caps
 * optional); show-off (v0.5): the topology and mode_properties only;
 * show-off-quad: everything, plane caps essential; show-off-solid: topology,
 * mode_properties and plane caps (essential) only. */
static void log_properties(int fd, int kind, uint32_t cid, uint32_t crtc_id, uint32_t primary_plane_id,
			   const uint32_t *pids, uint32_t npids)
{
	uint32_t mpb = 0, ccb = 0, caps_pri = 0, caps = 0;
	g_ncaps = 0;
	log_conn_topology(fd, cid, &mpb, &ccb);
	log_blob(fd, "mode_properties", cid, mpb);
	if (kind == K_OFF)
		return;
	int quad = kind == K_QUAD || kind == K_SOLID;
	for (uint32_t i = 0; i < npids; i++) {
		log_plane_caps(fd, pids[i], quad && i < FSP_ESS_PLANES, &caps);   /* beyond FSP_ESS_PLANES: optional */
		if (pids[i] == primary_plane_id) caps_pri = caps;
	}
	if (kind == K_SOLID)
		return;
	log_blob(fd, "primary_capabilities", primary_plane_id, caps_pri);
	log_blob(fd, "conn_capabilities", cid, ccb);
	int ref = 0;
	log_object(fd, "conn", cid, DRM_MODE_OBJECT_CONNECTOR, &ref);
	ref = 0;
	log_object(fd, "crtc", crtc_id, DRM_MODE_OBJECT_CRTC, &ref);
	ref = 0;
	for (uint32_t i = 0; i < npids; i++)
		log_object(fd, "plane", pids[i], DRM_MODE_OBJECT_PLANE, &ref);
}

/* ---- v0.6 quad plan (pure; unit-tested; DESIGN §6.2) ------------------------------
 * pipe_idx is the index WITHIN a pipe type (VIG n and DMA n both report n, E16); the
 * type comes from max_upscale: 20 -> VIG (MAX_UPSCALE_RATIO), 1 -> DMA
 * (SSPP_UNITY_SCALE); anything else -> unknown (not selectable). */
enum { PT_UNKNOWN = 0, PT_VIG = 1, PT_DMA = 2 };
enum { Q_VIG = 0, Q_DMA = 1 };
static int pipe_type(int64_t max_upscale)
{
	if (max_upscale == 20) return PT_VIG;
	if (max_upscale == 1) return PT_DMA;
	return PT_UNKNOWN;
}

struct qcand {
	uint32_t id;
	int idx, eligible, ptype;
	int64_t pipe_idx, smart, max_upscale;
	uint64_t zpos;
};

/* Exactly one eligible candidate of type PTYPE: the rect 0 of pipe PIDX (rect1_of
 * == 0: no primary_smart_plane_id), or the rect 1 whose primary_smart_plane_id is
 * RECT1_OF. 0 and *out = its index; else -1 and *why = missing | ambiguous. */
static int quad_pick1(const struct qcand *c, int n, int ptype, int64_t pidx, uint32_t rect1_of,
		      int *out, const char **why)
{
	int found = -1, cnt = 0;
	for (int i = 0; i < n; i++) {
		if (!c[i].eligible || c[i].ptype != ptype)
			continue;
		if (rect1_of == 0) {
			if (c[i].pipe_idx != pidx || c[i].smart >= 0) continue;
		} else if (c[i].smart != (int64_t)rect1_of) {
			continue;
		}
		found = i; cnt++;
	}
	if (cnt == 1) { *out = found; return 0; }
	*why = cnt ? "ambiguous" : "missing";
	return -1;
}

/* KIND Q_VIG: slots k = 0..3 = VIG k rect 0. Q_DMA: DMA3 rect 0, its rect 1, DMA2
 * rect 0, its rect 1 (the stock half-pairs, E5). out[k] = candidate index for the
 * plane at x = 1032 k. The first slot that fails decides *why. */
static int quad_select(const struct qcand *c, int n, int kind, int out[4], const char **why)
{
	if (kind == Q_VIG) {
		for (int k = 0; k < 4; k++)
			if (quad_pick1(c, n, PT_VIG, k, 0, &out[k], why))
				return -1;
		return 0;
	}
	static const int64_t dpipe[2] = { 3, 2 };
	for (int h = 0; h < 2; h++) {
		if (quad_pick1(c, n, PT_DMA, dpipe[h], 0, &out[2 * h], why))
			return -1;
		if (quad_pick1(c, n, PT_DMA, -1, c[out[2 * h]].id, &out[2 * h + 1], why))
			return -1;
	}
	return 0;
}

/* zpos by slot: the left pair at blend stage 1, the right pair at stage 2, as
 * stock (E15). The ONLY values zpos is ever set to (PM decision J-109 #1). */
static const uint64_t FSP_QUAD_Z[4] = { 0, 0, 1, 1 };

/* The one new request wrapper: a_plane plus one zpos property. */
static void a_plane_z(struct areq *a, const struct plane_info *p, uint32_t fb, uint32_t crtc,
		      uint32_t sx, uint32_t sw, uint32_t h, uint64_t z)
{
	a_plane(a, p, fb, crtc, sx, sw, h);
	a_prop(a, p->p_zpos, z);
}

/* ---- the atomic requests ------------------------------------------------------- */
struct pipe_ctx { uint32_t cid, k_crtc, crtc_id, c_mode, c_active, mode_blob, fb_id, W, H; };

/* The v0.5 request (show/show-off attempts; the quad modes' split probe), as v0.5
 * built it inline: the modeset part, one plane (W) or the split pair (W/2 each),
 * and the planes bound to our CRTC switched off. Returns the number switched off. */
static int build_v05(struct areq *a, const struct attempt *at, const struct pipe_ctx *x, int pri, int sec)
{
	int off = 0;
	memset(a, 0, sizeof(*a));
	if (at->modeset) {
		a_obj(a, x->cid); a_prop(a, x->k_crtc, x->crtc_id);
		a_obj(a, x->crtc_id); a_prop(a, x->c_mode, x->mode_blob); a_prop(a, x->c_active, 1);
	}
	if (!at->split) {
		a_plane(a, &planes[pri], x->fb_id, x->crtc_id, 0, x->W, x->H);
	} else {
		a_plane(a, &planes[pri], x->fb_id, x->crtc_id, 0, x->W / 2, x->H);
		a_plane(a, &planes[sec], x->fb_id, x->crtc_id, x->W / 2, x->W - x->W / 2, x->H);
	}
	for (int i = 0; i < nplanes; i++)
		if (i != pri && !(at->split && i == sec) && planes[i].crtc_id == x->crtc_id) {
			a_plane_off(a, &planes[i]); off++;
		}
	return off;
}

/* A quad request: modeset part; plane k at SRC_X = CRTC_X = (W/4) k, width W/4,
 * full height, zpos FSP_QUAD_Z[k]; the other planes bound to our CRTC off. */
static int build_quad(struct areq *a, const struct pipe_ctx *x, const int sel[4])
{
	int off = 0;
	uint32_t qw = x->W / 4;
	memset(a, 0, sizeof(*a));
	a_obj(a, x->cid); a_prop(a, x->k_crtc, x->crtc_id);
	a_obj(a, x->crtc_id); a_prop(a, x->c_mode, x->mode_blob); a_prop(a, x->c_active, 1);
	for (int k = 0; k < 4; k++)
		a_plane_z(a, &planes[sel[k]], x->fb_id, x->crtc_id, qw * (uint32_t)k, qw, x->H, FSP_QUAD_Z[k]);
	for (int i = 0; i < nplanes; i++) {
		int in = 0;
		for (int k = 0; k < 4; k++)
			in |= sel[k] == i;
		if (!in && planes[i].crtc_id == x->crtc_id) {
			a_plane_off(a, &planes[i]); off++;
		}
	}
	return off;
}

/* ---- v0.6 post-commit state (GET ioctls only; DESIGN §6.5) -----------------------
 * Software state after the blocking commit, not hardware registers. The kernel's
 * right-half CRTC_X rewrite (E17) is NOT undone here: the raw GET values are logged. */
static void kv_pv(const struct pinfo *pi, int n, const char *name, const char *key)
{
	int i = n > 0 ? pinfo_find(pi, n, name) : -1;
	if (i >= 0) kv_u(key, pi[i].val); else kv_s(key, "none");
}
static void kv_pvs(const struct pinfo *pi, int n, const char *name, const char *key)   /* signed range */
{
	int i = n > 0 ? pinfo_find(pi, n, name) : -1;
	if (i >= 0) kv_i(key, (int64_t)pi[i].val); else kv_s(key, "none");
}

static void log_post_state(int fd, uint32_t cid, uint32_t crtc_id)
{
	static struct pinfo cp[MAXPROPS], rp[MAXPROPS];
	static const char *const cn[] = { "ACTIVE", "MODE_ID", "core_clk", "core_ab", "core_ib",
					  "llcc_ab", "llcc_ib", "dram_ab", "dram_ib" };
	static const char *const ck[] = { "active", "mode_id", "core_clk", "core_ab", "core_ib",
					  "llcc_ab", "llcc_ib", "dram_ab", "dram_ib" };
	char tname[DRM_PROP_NAME_LEN + 1];
	int nc = obj_pinfo(fd, cid, DRM_MODE_OBJECT_CONNECTOR, cp);
	int nr = obj_pinfo(fd, crtc_id, DRM_MODE_OBJECT_CRTC, rp);
	int it = nc > 0 ? pinfo_find(cp, nc, "topology_name") : -1;
	memcpy(tname, "none", 5);
	if (it >= 0) enum_name(fd, cp[it].id, cp[it].val, tname, sizeof(tname));
	struct drm_mode_crtc gcr;
	memset(&gcr, 0, sizeof(gcr));
	gcr.crtc_id = crtc_id;
	int gr = xioctl(fd, DRM_IOCTL_MODE_GETCRTC, &gcr);
	rec_begin("post_state", nc < 0 ? nc : (nr < 0 ? nr : 0));
	kv_u("conn", cid);
	kv_pv(cp, nc, "topology_name", "topology_val");
	kv_str("topology_name", tname, sizeof(tname));
	kv_pv(cp, nc, "dsc_mode", "dsc_mode_val");
	kv_pv(cp, nc, "topology_control", "control_val");
	kv_u("crtc", crtc_id);
	for (unsigned i = 0; i < sizeof(cn) / sizeof(cn[0]); i++)
		kv_pv(rp, nr, cn[i], ck[i]);
	kv_i("getcrtc_rc", gr); kv_u("mode_valid", gr ? 0 : gcr.mode_valid); kv_u("fb", gr ? 0 : gcr.fb_id);
	rec_end();
}

/* SRC_* are 16.16 fixed point: logged as the integer part (raw >> 16); src_frac is
 * the OR of the four fractional parts (0 for every request this tool makes). */
static void log_post_plane(int fd, int slot, uint32_t pid)
{
	static struct pinfo pp[MAXPROPS];
	static const char *const sn[] = { "SRC_X", "SRC_Y", "SRC_W", "SRC_H" };
	static const char *const sk[] = { "src_x", "src_y", "src_w", "src_h" };
	int n = obj_pinfo(fd, pid, DRM_MODE_OBJECT_PLANE, pp);
	uint64_t frac = 0;
	rec_begin("post_plane", n < 0 ? n : 0);
	kv_u("slot", (uint64_t)slot); kv_u("plane", pid);
	kv_pv(pp, n, "CRTC_ID", "crtc_id"); kv_pv(pp, n, "FB_ID", "fb_id");
	kv_pvs(pp, n, "CRTC_X", "crtc_x"); kv_pvs(pp, n, "CRTC_Y", "crtc_y");
	kv_pv(pp, n, "CRTC_W", "crtc_w"); kv_pv(pp, n, "CRTC_H", "crtc_h");
	for (int j = 0; j < 4; j++) {
		int i = n > 0 ? pinfo_find(pp, n, sn[j]) : -1;
		if (i >= 0) { kv_u(sk[j], pp[i].val >> 16); frac |= pp[i].val & 0xffffu; }
		else kv_s(sk[j], "none");
	}
	kv_u("src_frac", frac);
	kv_pv(pp, n, "zpos", "zpos");
	rec_end();
}

/* plan-record lists in the FSP1 value charset, no %XX needed: elements joined by '.', as the packed
 * lists ("71.97.100.103"); a pipe is <type>-<pipe_idx> ("vig-0"); an unavailable attempt reads
 * "unavailable-missing" / "unavailable-ambiguous". WHAT: 0 ids, 1 type-pipe_idx, 2 max_upscale,
 * 3 zpos (the value read before the commit). */
static void kv_qlist(const char *key, int avail, const char *why, const struct qcand *c, const int sel[4], int what)
{
	char b[96];
	size_t n = 0;
	if (!avail) {
		if (what) { kv_s(key, "-"); return; }
		const char *u = "unavailable-";
		while (*u) b[n++] = *u++;
		while (*why && n < sizeof(b) - 1) b[n++] = *why++;
		b[n] = 0;
		kv_str(key, b, sizeof(b));
		return;
	}
	for (int k = 0; k < 4; k++) {
		const struct qcand *q = &c[sel[k]];
		char t[24];
		int tn = 0;
		uint64_t v = what == 0 ? q->id : (what == 1 ? (uint64_t)q->pipe_idx : (what == 2 ? (uint64_t)q->max_upscale : q->zpos));
		if (k) b[n++] = '.';
		if (what == 1) {
			const char *tp = q->ptype == PT_VIG ? "vig-" : (q->ptype == PT_DMA ? "dma-" : "unknown-");
			while (*tp) b[n++] = *tp++;
		}
		do { t[tn++] = (char)('0' + v % 10); v /= 10; } while (v && tn < 20);
		while (tn) b[n++] = t[--tn];
	}
	b[n] = 0;
	kv_str(key, b, sizeof(b));
}

static void kv_zset(void)
{
	char b[16];
	size_t n = 0;
	for (int k = 0; k < 4; k++) {
		if (k) b[n++] = '.';
		b[n++] = (char)('0' + FSP_QUAD_Z[k]);
	}
	b[n] = 0;
	kv_str("zpos_set", b, sizeof(b));
}

static void rec_start(const char *mode, uint32_t req, uint32_t hold_s, const char *dev)
{
	rec_begin("start", 0);
	kv_s("mode", mode);
	kv_s("ver", FSP_VERSION);
	kv_u("hold_req", req); kv_u("hold", hold_s); kv_u("hold_max", FSP_HOLD_MAX_S);
	kv_u("clamped", req > FSP_HOLD_MAX_S ? 1 : 0);
	kv_u("setup_alarm_s", FSP_SETUP_BUDGET_S);
	kv_u("close_margin_s", FSP_CLOSE_MARGIN_S);
	kv_str("dev", dev, FSP_PATH_MAX + 1);
	kv_s("out", g_out_kind);
	kv_u("rot", FSP_ROTATE_180 ? 180 : 0);
	kv_i("roll", g_roll); kv_s("eyes", g_eyes_swap ? "swap" : "direct");
	kv_u("t0_ms", (uint64_t)(g_t0 / 1000000));
	rec_end();
}

/* ---- v0.7 mode "reset": the request (pure builder; unit-tested on the mock model) ----------
 * The disable of the handed-over pipeline (step A of run_reset): the connector detached
 * (CRTC_ID 0), the CRTC without a mode (MODE_ID 0) and inactive (ACTIVE 0), every plane bound
 * to that CRTC switched off (a_plane_off: FB_ID 0 with CRTC_ID 0). ACTIVE 0 alone would keep
 * the mode and the connector; MODE_ID 0 without CRTC_ID 0 is refused by the DRM core
 * (drm_atomic_helper.c:674, README). Only ids v0.6 already sets; only the value 0.
 * Returns the number of planes switched off. */
static int build_reset(struct areq *a, uint32_t cid, uint32_t k_crtc, uint32_t crtc_id, uint32_t c_mode, uint32_t c_active)
{
	int off = 0;
	memset(a, 0, sizeof(*a));
	a_obj(a, cid); a_prop(a, k_crtc, 0);
	a_obj(a, crtc_id); a_prop(a, c_mode, 0); a_prop(a, c_active, 0);
	for (int i = 0; i < nplanes; i++)
		if (planes[i].crtc_id == crtc_id) {
			a_plane_off(a, &planes[i]); off++;
		}
	return off;
}

#define FSP_RESET_POST_PLANES 4   /* post_plane records after the disable: at most the first 4 planes switched off */


/* v0.7 reset, after the read-only logging and the BLACK buffer (every pixel XRGB 0x00000000):
 *  A  "reset_off": build_reset (connector CRTC_ID 0, MODE_ID 0, ACTIVE 0, its planes off): TEST_ONLY,
 *     one commit, post_state. A disable alone does NOT end the continuous splash on the DSI side
 *     (dsi_display.c clears is_cont_splash_enabled only on the enable path; research in README).
 *  B  "reset_on": the v0.5 modeset attempts (single, then split, plan_attempts with use_current 0)
 *     on the black buffer: TEST_ONLY, the first accepted one committed once (ALLOW_MODESET). On the
 *     splash path this enable sends no panel-on (the panel stays asleep, as run 1 of stage 3c) and
 *     clears the splash state (DSI flag; SDE splash resources).
 *  then close at once (no hold): lastclose, with the splash gone, disables everything through the
 *  full off path, so run 2 (a new process) gets the full power-on. Nothing but black is ever
 *  scanned out by this mode. Exit 0 "reset_done"; 50 / 60 as v0.6 (A or B rejected / failed). */
static void run_reset(const struct pipe_ctx *x, int pri, int sec, int mode_expected) __attribute__((noreturn));
static void run_reset(const struct pipe_ctx *x, int pri, int sec, int mode_expected)
{
	struct areq a;
	/* B must be plannable before A is sent: a modeset attempt exists */
	struct attempt plan[4];
	int na = plan_attempts(0, mode_expected, sec >= 0, plan);
	int off = build_reset(&a, x->cid, x->k_crtc, x->crtc_id, x->c_mode, x->c_active);
	rec_begin("reset_plan", na ? 0 : -ENOENT);
	kv_u("conn", x->cid); kv_u("crtc", x->crtc_id);
	kv_u("objs", a.nobj); kv_u("props", a.nprop); kv_u("planes_off", (uint64_t)off);
	kv_u("overflow", (uint64_t)a.over);
	kv_u("reenable_attempts", (uint64_t)na); kv_u("helper", (uint64_t)(sec >= 0));
	rec_end();
	if (a.over) finish(EX_NOPIPE, "request_overflow");
	if (na == 0) finish(EX_TESTREJECT, "no_reenable_attempt");   /* nothing committed */
	/* A: the disable */
	check_stop("before_test");
	int r = a_commit(g_fd, &a, DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET, 100);
	rec_begin("test_commit", r);
	kv_u("attempt", 0); kv_u("modeset", 1); kv_s("layout", "reset_off");
	kv_u("objs", a.nobj); kv_u("props", a.nprop); kv_u("planes_off", (uint64_t)off);
	kv_u("overflow", (uint64_t)a.over);
	kv_s("result", r ? "rejected" : "accepted");
	rec_end();
	if (r) finish(EX_TESTREJECT, "reset_off_rejected");          /* nothing committed */
	check_stop("before_commit");
	int64_t t0 = mono_ns();
	r = a_commit(g_fd, &a, DRM_MODE_ATOMIC_ALLOW_MODESET, 1);    /* one attempt, no retry */
	rec_begin("commit", r);
	kv_u("attempt", 0); kv_u("modeset", 1); kv_s("layout", "reset_off");
	kv_u("commit_ms", (uint64_t)((mono_ns() - t0) / 1000000));
	rec_end();
	if (r) finish(EX_COMMITFAIL, "reset_off_failed");
	log_post_state(g_fd, x->cid, x->crtc_id);
	int k = 0;
	for (int i = 0; i < nplanes && k < FSP_RESET_POST_PLANES; i++)
		if (planes[i].crtc_id == x->crtc_id)
			log_post_plane(g_fd, k++, planes[i].id);
	/* B: the dark re-enable on the black buffer (v0.5 modeset attempts, single then split) */
	int ok = -1;
	for (int t = 0; t < na && ok < 0; t++) {
		check_stop("before_test");
		int po = build_v05(&a, &plan[t], x, pri, sec);
		r = a_commit(g_fd, &a, DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET, 100);
		rec_begin("test_commit", r);
		kv_u("attempt", (uint64_t)(t + 1)); kv_u("modeset", 1);
		kv_s("layout", plan[t].split ? "reset_on_split" : "reset_on_single");
		kv_u("objs", a.nobj); kv_u("props", a.nprop); kv_u("planes_off", (uint64_t)po);
		kv_u("overflow", (uint64_t)a.over);
		kv_s("result", r ? "rejected" : "accepted");
		rec_end();
		if (a.over) finish(EX_NOPIPE, "request_overflow");
		if (!r) ok = t;
	}
	if (ok < 0) finish(EX_TESTREJECT, "reset_on_rejected");     /* left disabled; run 2 is gated off */
	/* `a` holds the accepted request (the loop stops at the first accepted attempt) */
	check_stop("before_commit");
	t0 = mono_ns();
	r = a_commit(g_fd, &a, DRM_MODE_ATOMIC_ALLOW_MODESET, 1);
	rec_begin("commit", r);
	kv_u("attempt", (uint64_t)(ok + 1)); kv_u("modeset", 1);
	kv_s("layout", plan[ok].split ? "reset_on_split" : "reset_on_single");
	kv_u("commit_ms", (uint64_t)((mono_ns() - t0) / 1000000));
	rec_end();
	if (r) finish(EX_COMMITFAIL, "reset_on_failed");
	log_post_state(g_fd, x->cid, x->crtc_id);
	log_post_plane(g_fd, 0, planes[pri].id);
	if (plan[ok].split) log_post_plane(g_fd, 1, planes[sec].id);
	/* close at once: lastclose disables the pipeline through the full off path */
	int64_t tc = mono_ns();
	int cr = close(g_fd);
	g_fd = -1;
	rec_begin("reset_close", 0);
	kv_i("close_rc", cr); kv_u("close_ms", (uint64_t)((mono_ns() - tc) / 1000000));
	rec_end();
	finish(cr == 0 ? EX_OK : EX_INTERNAL, cr == 0 ? "reset_done" : "close_failed");
}

/* v0.7: the start record of "reset" (no hold) */
static void rec_start_reset(const char *dev)
{
	rec_begin("start", 0);
	kv_s("mode", "reset"); kv_s("ver", FSP_VERSION);
	kv_u("setup_alarm_s", FSP_SETUP_BUDGET_S);
	kv_u("close_margin_s", FSP_CLOSE_MARGIN_S);
	kv_str("dev", dev, FSP_PATH_MAX + 1);
	kv_s("out", g_out_kind);
	kv_u("rot", FSP_ROTATE_180 ? 180 : 0);
	kv_u("t0_ms", (uint64_t)(g_t0 / 1000000));
	rec_end();
}

/* ---- mode "show" / "show-off" / "show-off-quad" / "show-off-solid" / "reset" ---------- */
static int run_show(const char *dev, uint32_t hold_s, int kind)
{
	int r;
	int off_mode = kind == K_OFF || kind == K_QUAD || kind == K_SOLID, quad = kind == K_QUAD || kind == K_SOLID;
	g_opt_max = kind == K_SOLID ? FSP_OPT_MAX_SOLID : FSP_OPT_MAX;   /* before the first record that may be optional */
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
		rec_begin_ess("connector", r, i, FSP_ESS_CONNECTORS);
		kv_u("id", res_conns[i]);
		if (!r) {
			kv_u("type", gc.connector_type); kv_u("type_id", gc.connector_type_id);
			kv_u("status", gc.connection); kv_u("modes", gc.count_modes);
			kv_u("encoders", gc.count_encoders); kv_u("encoder", gc.encoder_id);
			kv_u("mm_w", gc.mm_width); kv_u("mm_h", gc.mm_height);
		}
		rec_end_ess(i, FSP_ESS_CONNECTORS);
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
		if (i >= FSP_LOG_MODES && !is_expected_mode(&modes[i])) {   /* v0.7.1: not logged, counted */
			g_opt_skipped++;
			continue;
		}
		rec_mode("mode", (int)i, &modes[i], i >= FSP_ESS_MODES);
		kv_u("preferred", (modes[i].type & DRM_MODE_TYPE_PREFERRED) ? 1 : 0);
		kv_u("expected", (uint64_t)is_expected_mode(&modes[i]));
		rec_end_ess(i, FSP_ESS_MODES);
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
	rec_mode("crtc_state", -1, &gcr.mode, 0);
	kv_i("getcrtc_rc", r); kv_u("mode_valid", r ? 0 : gcr.mode_valid); kv_u("fb", gcr.fb_id);
	kv_u("active_prop", active_prop); kv_u("active", active_val);
	kv_u("in_list", (uint64_t)(cur_valid && mode_in_list(modes, nm, &gcr.mode)));
	kv_u("interlaced", (uint64_t)((gcr.mode.flags & DRM_MODE_FLAG_INTERLACE) ? 1 : 0));
	kv_u("expected", (uint64_t)(cur_valid && is_expected_mode(&gcr.mode)));
	rec_end();
	/* show-off*: the off->on runs need a PROVABLY inactive CRTC. Otherwise: no
	 * commit at all (exit 31, "precondition unmet: CRTC active"). */
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
	/* v0.7 reset: the CRTC state must be readable; an already inactive CRTC needs nothing */
	if (kind == K_RESET) {
		int known = (r == 0 && active_prop != 0);
		rec_begin("reset_precondition", known ? 0 : -EBUSY);
		kv_s("required", "crtc_state_readable");
		kv_i("getcrtc_rc", r); kv_u("active_prop", active_prop); kv_u("active", active_val);
		kv_s("state", !known ? "unknown" : (active_val ? "active" : "already_inactive"));
		rec_end();
		if (!known)
			finish(EX_PRECOND, "crtc_state_unknown");
		if (crtc_provably_inactive(r, active_prop, active_val))
			finish(EX_OK, "already_inactive");       /* nothing committed */
	}
	struct mode_pick mp = { -1, 0, "reset" };
	struct drm_mode_modeinfo mode;
	memset(&mode, 0, sizeof(mode));
	uint32_t W = 0, H = 0;
	if (kind == K_RESET) {
		/* the re-enable mode (step B): the handed-over mode if it is exactly the expected one and in
		 * the list, else the expected mode from the list; none: nothing is committed (exit 30) */
		if (cur_valid && mode_in_list(modes, nm, &gcr.mode) && is_expected_mode(&gcr.mode)) {
			mode = gcr.mode; mp.why = "crtc_current_expected";
		} else {
			for (uint32_t i = 0; i < nm && mp.idx < 0; i++)
				if (is_expected_mode(&modes[i])) { mode = modes[i]; mp.idx = (int)i; mp.why = "expected_4128x2208_90"; }
			if (mp.idx < 0) {
				rec_begin("chosen_mode", -ENOENT); kv_s("why", "no_expected_mode"); rec_end();
				finish(EX_NOMODE, "no_acceptable_mode");
			}
		}
		W = mode.hdisplay; H = mode.vdisplay;
		rec_mode("chosen_mode", mp.idx, &mode, 0);
		kv_s("why", mp.why);
		kv_u("expected", (uint64_t)is_expected_mode(&mode));
		rec_end();
	} else {
		mp = pick_mode(modes, nm, cur_valid ? &gcr.mode : NULL, cur_active);
		if (mp.use_current) mode = gcr.mode;
		else if (mp.idx >= 0) mode = modes[mp.idx];
		else {
			rec_begin("chosen_mode", -ENOENT); kv_s("why", mp.why); rec_end();
			finish(EX_NOMODE, "no_acceptable_mode");
		}
		W = mode.hdisplay; H = mode.vdisplay;
		rec_mode("chosen_mode", mp.idx, &mode, 0);
		kv_s("why", mp.why);
		kv_u("expected", (uint64_t)is_expected_mode(&mode));
		rec_end();
	}

	/* 8. planes (the v0.5 enumeration, primary and helper selection) */
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
		rec_begin_ess("plane", r, i, FSP_ESS_PLANES);
		kv_u("id", plane_ids[i]);
		if (!r) {
			kv_u("type", p->type); kv_x("possible", p->possible);
			kv_u("crtc", p->crtc_id); kv_u("fb", p->fb_id);
			kv_u("xrgb8888", p->xrgb); kv_u("props", (uint64_t)props_ok);
		}
		rec_end_ess(i, FSP_ESS_PLANES);
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
	/* the quad modes need no primary plane (the split probe is then skipped); reset needs it (step B) */
	int pipe_ok = c_mode && c_active && k_crtc && (quad || pri >= 0);
	rec_begin("atomic_props", pipe_ok ? 0 : -ENOENT);
	kv_u("primary", pri >= 0 ? planes[pri].id : 0);
	kv_u("helper", sec >= 0 ? planes[sec].id : 0);
	kv_u("crtc_mode_id", c_mode); kv_u("crtc_active", c_active); kv_u("conn_crtc_id", k_crtc);
	rec_end();
	if (!pipe_ok)
		finish(EX_NOPIPE, "no_atomic_pipeline");
	/* read-only property logging at start (GET ioctls only); the plane caps are
	 * the quad selection inputs */
	g_opt_max = kind == K_SOLID ? FSP_OPT_MAX_SOLID : FSP_OPT_MAX;
	log_properties(g_fd, kind, cid, crtc_id, pri >= 0 ? planes[pri].id : 0, plane_ids,
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
		if (kind == K_SOLID) draw_solid((uint8_t *)map, cd.pitch, W, H);
		else if (kind == K_RESET) draw_black((uint8_t *)map, cd.pitch, W, H);
		else r = draw_pattern((uint8_t *)map, cd.pitch, W, H, g_nonce);
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
	if (kind == K_SOLID) kv_x("solid", FSP_SOLID_XRGB);
	if (kind == K_RESET) kv_u("black", 1);
	rec_end();
	if (r) finish(EX_BUFFER, "buffer_failed");

	/* 10. TEST_ONLY attempts, then exactly one real commit */
	struct pipe_ctx x = { cid, k_crtc, crtc_id, c_mode, c_active, blob.blob_id, fb.fb_id, W, H };
	if (kind == K_RESET)
		run_reset(&x, pri, sec, is_expected_mode(&mode));   /* never returns; only black is ever scanned out */
	struct areq a;
	int ok = -1, modeset = 0, attempt = 0, ncom = 0, com[4] = { -1, -1, -1, -1 };
	const char *tag = "?";
	if (!quad) {
		/* show / show-off: v0.5's plan, order and layouts */
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
		for (int t = 0; t < na && ok < 0; t++) {
			check_stop("before_test");
			int off = build_v05(&a, &plan[t], &x, pri, sec);
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
		attempt = ok; modeset = plan[ok].modeset; tag = plan[ok].split ? "split" : "single";
		com[0] = pri; ncom = 1;
		if (plan[ok].split) { com[1] = sec; ncom = 2; }
	} else {
		/* show-off-quad / show-off-solid (DESIGN §6.2): eligible planes from the caps */
		static struct qcand qc[MAXOBJ];
		int nq = 0;
		for (int i = 0; i < nplanes; i++) {
			struct plane_info *p = &planes[i];
			const struct pcap *k = NULL;
			for (int j = 0; j < g_ncaps; j++)
				if (g_caps[j].id == p->id) k = &g_caps[j];
			memset(&qc[nq], 0, sizeof(qc[nq]));
			qc[nq].id = p->id; qc[nq].idx = i;
			qc[nq].eligible = p->xrgb && (p->possible & (1u << crtc_idx)) && p->type != PLANE_TYPE_CURSOR &&
					  (p->crtc_id == 0 || p->crtc_id == crtc_id) && k && k->zpos_found &&
					  k->read_rc == 0 && k->pipe_idx >= 0 && k->max_upscale >= 0;
			qc[nq].ptype = k ? pipe_type(k->max_upscale) : PT_UNKNOWN;
			qc[nq].pipe_idx = k ? k->pipe_idx : -1;
			qc[nq].smart = k ? k->smart : -1;
			qc[nq].max_upscale = k ? k->max_upscale : -1;
			qc[nq].zpos = k ? k->zpos_val : 0;
			if (qc[nq].eligible) p->p_zpos = k->zpos_prop;
			nq++;
		}
		static const char *const qtag[2] = { "quad_vig", "quad_dma" };
		int sel[2][4], psel[2][4], av[2];
		const char *why[2] = { "missing", "missing" };
		av[0] = quad_select(qc, nq, Q_VIG, sel[0], &why[0]) == 0;
		av[1] = quad_select(qc, nq, Q_DMA, sel[1], &why[1]) == 0;
		for (int t = 0; t < 2; t++)
			for (int k = 0; k < 4; k++)
				psel[t][k] = av[t] ? qc[sel[t][k]].idx : -1;
		int splash = av[0] && qc[sel[0][0]].id == 71 && qc[sel[0][1]].id == 97 &&
			     qc[sel[0][2]].id == 100 && qc[sel[0][3]].id == 103;
		int have_split = pri >= 0 && sec >= 0 && is_expected_mode(&mode);
		rec_begin("plan", (av[0] || av[1]) ? 0 : -ENOENT);
		kv_u("attempts", (uint64_t)(have_split + av[0] + av[1]));
		kv_u("split_probe", (uint64_t)have_split);
		kv_qlist("quad_vig", av[0], why[0], qc, sel[0], 0);
		kv_qlist("quad_dma", av[1], why[1], qc, sel[1], 0);
		kv_qlist("pipe_vig", av[0], why[0], qc, sel[0], 1);
		kv_qlist("pipe_dma", av[1], why[1], qc, sel[1], 1);
		kv_qlist("max_upscale_vig", av[0], why[0], qc, sel[0], 2);
		kv_qlist("max_upscale_dma", av[1], why[1], qc, sel[1], 2);
		kv_qlist("zpos_before_vig", av[0], why[0], qc, sel[0], 3);
		kv_qlist("zpos_before_dma", av[1], why[1], qc, sel[1], 3);
		kv_zset();
		kv_s("splash_set", splash ? "match" : "differs");
		rec_end();
		/* p: the v0.5 split request as a TEST_ONLY probe. NEVER committed. */
		if (have_split) {
			struct attempt sp = { 1, 1 };
			check_stop("before_test");
			int off = build_v05(&a, &sp, &x, pri, sec);
			r = a_commit(g_fd, &a, DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET, 100);
			rec_begin("test_commit", r);
			kv_u("attempt", 0);
			kv_u("modeset", 1);
			kv_s("layout", "split_probe");
			kv_u("objs", a.nobj); kv_u("props", a.nprop); kv_u("planes_off", (uint64_t)off);
			kv_u("overflow", (uint64_t)a.over);
			kv_s("result", r ? "rejected" : "accepted");
			rec_end();
			if (a.over) finish(EX_NOPIPE, "request_overflow");
		}
		/* a0 quad_vig, a1 quad_dma: the first accepted one is committed */
		for (int t = 0; t < 2 && ok < 0; t++) {
			if (!av[t])
				continue;               /* unavailable: no TEST_ONLY */
			check_stop("before_test");
			int off = build_quad(&a, &x, psel[t]);
			r = a_commit(g_fd, &a, DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET, 100);
			rec_begin("test_commit", r);
			kv_u("attempt", (uint64_t)(t + 1));
			kv_u("modeset", 1);
			kv_s("layout", qtag[t]);
			kv_u("objs", a.nobj); kv_u("props", a.nprop); kv_u("planes_off", (uint64_t)off);
			kv_u("overflow", (uint64_t)a.over);
			kv_s("result", r ? "rejected" : "accepted");
			rec_end();
			if (a.over) finish(EX_NOPIPE, "request_overflow");
			if (!r) ok = t;
		}
		if (ok < 0)
			finish(EX_TESTREJECT, "no_quad_accepted");   /* nothing committed, whatever the probe returned */
		attempt = ok + 1; modeset = 1; tag = qtag[ok];
		for (int k = 0; k < 4; k++) com[k] = psel[ok][k];
		ncom = 4;
	}
	check_stop("before_commit");

	/* The image-time bound starts here: alarm and deadline both count from
	 * the start of the real commit. One ioctl attempt, no retry. `a` holds the
	 * accepted request (the loop stops at the first accepted attempt). */
	unsigned alarm_s = hold_s + FSP_CLOSE_MARGIN_S;
	int64_t commit_t0 = mono_ns();
	alarm(alarm_s);
	r = a_commit(g_fd, &a, modeset ? DRM_MODE_ATOMIC_ALLOW_MODESET : 0, 1);
	if (!r) g_shown = 1;
	rec_begin("commit", r);
	kv_u("attempt", (uint64_t)attempt);
	kv_u("modeset", (uint64_t)modeset);
	kv_s("layout", tag);
	kv_u("commit_ms", (uint64_t)((mono_ns() - commit_t0) / 1000000));
	rec_end();
	if (r) finish(EX_COMMITFAIL, "commit_failed");

	/* 11. the post-commit state (GETs only; inside the hold, which counts from commit_t0) */
	log_post_state(g_fd, cid, crtc_id);
	for (int k = 0; k < ncom; k++)
		log_post_plane(g_fd, k, planes[com[k]].id);

	/* 12. hold; hold() closes the fd as soon as the wait ends */
	int hr = hold(commit_t0, hold_s, alarm_s);
	finish(hr, hr == EX_OK ? "held_to_deadline" : (hr == EX_INTERRUPTED ? "interrupted" : "hold_error"));
}

/* ---- mode "render" / "render-solid": identical draw code into memory, written as PPM ---- */
static int run_render(uint32_t W, uint32_t H, const char *out, int solid)
{
	if (W < 64 || H < 64 || W > 8192 || H > 8192) {
		rec_begin("render", -EINVAL); kv_u("w", W); kv_u("h", H); rec_end();
		finish(EX_USAGE, "bad_size");
	}
	uint32_t pitch = W * 4;
	uint8_t *buf = malloc((size_t)pitch * H);
	uint8_t *row = malloc((size_t)W * 3);
	if (!buf || !row) finish(EX_INTERNAL, "oom");
	if (solid) draw_solid(buf, pitch, W, H);
	else if (draw_pattern(buf, pitch, W, H, g_nonce) != 0) finish(EX_INTERNAL, "oom");
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
	uint64_t lit = 0, maxv = 0, sum = 0, words = 0;
	for (uint32_t y = 0; ok && y < H; y++) {
		const uint32_t *p = (const uint32_t *)(buf + (size_t)y * pitch);
		for (uint32_t x = 0; x < W; x++) {
			uint8_t r = (uint8_t)(p[x] >> 16), g = (uint8_t)(p[x] >> 8), b = (uint8_t)p[x];
			row[x * 3] = r; row[x * 3 + 1] = g; row[x * 3 + 2] = b;
			if (r > C_BG) lit++;
			if (r > maxv) maxv = r;
			sum += r;
			if (p[x] == FSP_SOLID_XRGB) words++;
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
	kv_i("roll", g_roll); kv_s("eyes", g_eyes_swap ? "swap" : "direct");
	kv_s("picture", solid ? "solid" : "pattern");
	if (solid) kv_u("solid_words", words);
	rec_end();
	finish(ok ? EX_OK : EX_INTERNAL, ok ? "rendered" : "render_write_failed");
}

#ifndef FSP_UNIT_TEST
/* ---- mode "holdtest": identical hold code, mock path, no ioctls (v0.5) --------- */
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
	int rsolid = strcmp(mode, "render-solid") == 0;
	if (strcmp(mode, "render") == 0 || rsolid) {
		uint32_t W, H;
		if (argc < 6 || argc > (rsolid ? 6 : 8) || !parse_uint(argv[3], &W) || !parse_uint(argv[4], &H) || !valid_path(argv[5]))
			usage();
		for (int i = 6; i < argc; i++)
			if (parse_opt(argv[i]) != 1)
				usage();
		rec_begin("start", 0); kv_s("mode", rsolid ? "render-solid" : "render"); kv_s("ver", FSP_VERSION);
		kv_s("out", g_out_kind);
		if (!rsolid) { kv_i("roll", g_roll); kv_s("eyes", g_eyes_swap ? "swap" : "direct"); }
		rec_end();
		return run_render(W, H, argv[5], rsolid);
	}

	/* v0.7: reset NONCE [DEV] (no hold, no picture, no options) */
	if (strcmp(mode, "reset") == 0) {
		if (argc != 3 && argc != 4)
			usage();
		const char *rdev = argc == 4 ? argv[3] : "/dev/dri/card0";
		if (!valid_path(rdev) || strchr(rdev, '=') != NULL)
			usage();
		rec_start_reset(rdev);
		return run_show(rdev, 0, K_RESET);
	}

	static const char *const kname[4] = { "show", "show-off", "show-off-quad", "show-off-solid" };
	int kind = -1;
	for (int k = 0; k < 4; k++)
		if (strcmp(mode, kname[k]) == 0) kind = k;
	int is_show = kind >= 0, is_ht = strcmp(mode, "holdtest") == 0;
	uint32_t req;
	/* show*: NONCE HOLD_S [DEV] [roll=N] [eyes=swap|direct] (options: not with show-off-solid) */
	if (!(is_show && argc >= 4 && argc <= 7) && !(is_ht && argc == 5))
		usage();
	if (!parse_uint(argv[3], &req))
		usage();
	uint32_t hold_s = req > FSP_HOLD_MAX_S ? FSP_HOLD_MAX_S : req;
	const char *dev = is_show ? "/dev/dri/card0" : argv[4];
	if (is_show) {
		int have_dev = 0;
		for (int i = 4; i < argc; i++) {
			int o = parse_opt(argv[i]);
			if (o == 1 && kind != K_SOLID) continue;
			if (o == 0 && !have_dev && i == 4) { dev = argv[i]; have_dev = 1; continue; }
			usage();
		}
	}
	if (!valid_path(dev))
		usage();

	rec_start(is_show ? kname[kind] : "holdtest", req, hold_s, dev);
	if (is_show)
		return run_show(dev, hold_s, kind);
	return run_holdtest(dev, hold_s);
}

#else /* FSP_UNIT_TEST: pure-logic unit tests and the mock DRM model, run under qemu-aarch64 */
#include <stdarg.h>
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
	rec_mode("crtc_state", -1, &z, 0);   /* name all zero bytes, as GETCRTC returns with no mode */
	kv_u("mode_valid", 0);
	rec_end();
	rec_begin("version", 0); kv_str("drv", "", 64); rec_end();
	rec_begin("sample", 0); kv_str("dash", "-", 8); kv_str("pct", "a b=c", 8); rec_end();
	finish(0, "sample");
}

/* ---- v0.6 mock DRM device ("/mock/card0") ------------------------------------------
 * A model of the v66 object set as trial (iii-b) logged it (relays/FS-A-012-raw):
 * connectors 33 (type 15, connected), 55 (DSI, connected, 24 modes, encoder 54) and 65
 * (disconnected); CRTCs 155/156/157; 20 planes 71..152 (E4). tools/check_propsim.py
 * re-derives every logged value from these rules independently:
 *   property ids: connector 1000 + i, CRTC 2000 + i, plane k (index in ps_planes) 3000 + 100 k + i.
 *   initial values: object o, property index i: o*1000 + i, except
 *     connector: CRTC_ID 155, mode_properties blob 201, capabilities blob 202, topology_name 0
 *                (sde_none, E7), dsc_mode 0, topology_control 0;
 *     CRTC: ACTIVE = active, MODE_ID = active ? 209 : 0;
 *     plane k: type 1 for k < 3 (71/97/100 primary, as logged) else 0; FB_ID 0; CRTC_ID 155 for
 *              VIG0-3 when active (the splash set), else 0 (variant vig1other: plane 97 on 156);
 *              zpos 0; SRC_W (i == 10) o << 20; capabilities blob 300 + k (capsmissing: 97 -> 399).
 *   plane 106 lacks its last property (same_names=0).
 *   capabilities text (ps_caps): VIG rect 0 = k 0..3 (pipe_idx k), DMA rect 0 = k 4..9 (pipe_idx
 *   k-4, max_upscale 1: the DMA blobs at pipe_idx 0..3 of fixture M1), DMA rect 1 = k 10..15
 *   (primary_smart_plane_id = ps_planes[k-6]), VIG rect 1 = k 16..19 (primary ps_planes[k-16]).
 *   A real commit stores the request; with sspp_layout none the kernel converts a plane at
 *   CRTC_X >= 2064 to CRTC_X - 2064 (E17; variant noconv: not converted); a modeset with
 *   ACTIVE 1 sets topology_name 14 (sde_quadpipe_dsc4hsmerge).
 * Every DRM_IOCTL_MODE_ATOMIC is logged on stderr ("MOCK atomic ..."), with every
 * object:property=value it sets; the drawn buffer's pixel classes at munmap ("MOCK pixels"). */
#define PS_CONN 55
#define PS_CRTC 155
#define PS_MOCK_DEV "/mock/card0"
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
static const char PS_CONN_CAPS[] = "max_blendstages=10\nqseed_type=qseed3lite\nsmart_dma_rev=smart_dma_v2p5\n"
	"has_src_split=1\nsdma_count=6\nmax_mixer_width=2560\n";
static const char PS_PF_VIG[] = "pixel_formats=AR24 AB24 RA24 AB24/5/1 BA24 XR24 RX24 BX24 XB24 XB24/5/1 RG24 BG24 "
	"RG16 BG16/5/1 BG16 AR15 AB15 RA15 BA15 XR15 XB15 RX15 BX15 AR12 AB12 RA12 BA12 XR12 XB12 RX12 BX12 "
	"NV12 NV12/5/1 NV21 NV16 NV61 VYUY UYVY YUYV YVYU YU12 YV12 BA30 BX30 RA30 RX30 AB30 AB30/5/1 XB30 "
	"XB30/5/1 AR30 XR30 NV12/5/7 NV12/5/2 NV12/5/3 AR4H AR4H/5/10 AB4H AB4H/5/10 AB4H/5/1\n";
static const char PS_PF_DMA[] = "pixel_formats=AR24 AB24 RA24 AB24/5/1 BA24 XR24 RX24 BX24 XB24 XB24/5/1 RG24 BG24 "
	"RG16 BG16/5/1 BG16 AR15 AB15 RA15 BA15 XR15 XB15 RX15 BX15 AR12 AB12 RA12 BA12 XR12 XB12 RX12 BX12 "
	"BA30 BX30 RA30 RX30 AB30 AB30/5/1 XB30 XB30/5/1 AR30 XR30\n";
#define PS_PLANE_PROPS 50

enum { V_NONE = 0, V_VIG2DUP, V_VIG2UP3, V_VIG2UPNONE, V_DMADUP, V_VIG1OTHER, V_CAPSMISSING };
enum { L_SINGLE_NM = 1, L_SPLIT_NM = 2, L_SINGLE_MS = 4, L_SPLIT_MS = 8, L_QUAD_VIG = 16, L_QUAD_DMA = 32, L_OTHER = 64,
       L_RESET_OFF = 128 };   /* v0.7: no plane with a framebuffer, ACTIVE 0, MODE_ID 0, connector CRTC_ID 0 */
/* v0.7.1: modes = the DSI connector's mode list: M_V66 the 24 modes as logged on v66 (default); M_V27 the 305 modes of
 * v2.7 as its driver builds them (ps_gen_v27); M_V27_LATE the same list reordered: the expected mode at index 250 behind
 * near-duplicates (4128x2208 @ 90 interlaced, 4128x2209 @ 90, 4128x2208 @ 89/91, 3104x1664 @ 90), an exact copy of it at
 * 251; M_TOOMANY 513 modes (more than MAXMODES: the refusal must stay exit 30 too_many_modes) */
enum { M_V66 = 0, M_V27 = 1, M_V27_LATE = 2, M_TOOMANY = 3 };
struct sim_cfg { int active, accept, noconv, variant, mp_len, cc_len, modes; };
static struct sim_cfg g_sc;
static uint64_t ps_store[22][64];
static int ps_inited;
static int g_mock_fd = -1;
static void *g_mock_map;
static size_t g_mock_map_len;
#define PS_MAXM 600              /* the mock's own array (independent of MAXMODES: the v0.7-limit control build) */
static struct drm_mode_modeinfo ps_modes[PS_MAXM];
static uint32_t ps_nmodes = 24, ps_cur;   /* the list length; the index of the CRTC's current (splash) mode */
static int ps_crtc_valid;
static uint32_t ps_crtc_fb;
static struct { uint32_t n; uint32_t objs[64], cnt[64], props[400]; uint64_t vals[400]; int valid; } ps_last;

/* object -> names, count, store index (0 conn, 1 crtc, 2 + k plane k), base id */
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
static int ps_plane_k(uint32_t id)
{
	for (int j = 0; j < 20; j++)
		if (ps_planes[j] == id) return j;
	return -1;
}
/* property id -> (store index, property index, name) */
static const char *ps_prop(uint32_t pid, int *so, int *pi)
{
	if (pid >= 1000 && pid < 1000 + sizeof(ps_conn_names) / sizeof(*ps_conn_names)) { *so = 0; *pi = (int)pid - 1000; return ps_conn_names[*pi]; }
	if (pid >= 2000 && pid < 2000 + sizeof(ps_crtc_names) / sizeof(*ps_crtc_names)) { *so = 1; *pi = (int)pid - 2000; return ps_crtc_names[*pi]; }
	if (pid >= 3000 && pid < 3000 + 100 * 20 && (pid - 3000) % 100 < PS_PLANE_PROPS) {
		*so = 2 + (int)(pid - 3000) / 100; *pi = (int)(pid - 3000) % 100; return ps_plane_names[*pi];
	}
	return NULL;
}
static uint64_t ps_rule(uint32_t obj, int base, const char *name, int i, int k)
{
	if (base == 1000) {
		if (!strcmp(name, "CRTC_ID")) return PS_CRTC;
		if (!strcmp(name, "mode_properties")) return 201;
		if (!strcmp(name, "capabilities")) return 202;
		if (!strcmp(name, "topology_name") || !strcmp(name, "dsc_mode") || !strcmp(name, "topology_control")) return 0;
	}
	if (base == 2000) {
		if (!strcmp(name, "ACTIVE")) return (uint64_t)g_sc.active;
		if (!strcmp(name, "MODE_ID")) return g_sc.active ? 209 : 0;
	}
	if (base >= 3000) {
		if (!strcmp(name, "type")) return k < 3 ? PLANE_TYPE_PRIMARY : PLANE_TYPE_OVERLAY;
		if (!strcmp(name, "FB_ID") || !strcmp(name, "zpos")) return 0;
		if (!strcmp(name, "CRTC_ID")) {
			if (g_sc.variant == V_VIG1OTHER && k == 1) return 156;
			return (k < 4 && g_sc.active) ? PS_CRTC : 0;
		}
		if (i == 10) return (uint64_t)obj << 20;
		if (!strcmp(name, "capabilities")) return (g_sc.variant == V_CAPSMISSING && k == 1) ? 399 : 300 + (uint64_t)k;
	}
	return (uint64_t)obj * 1000 + (uint64_t)i;
}
/* v0.7.1: the v2.7 DSI connector's mode list, computed as the v2.7 driver computes it (kernel 5243367.3600.520,
 * techpack/display/msm/dsi; the v2.7 merged DT, panel meta,eureka_panel_sharp; README §3a). Cross-checked against the
 * independent Python model tools/v27-modes.py (the same digest, fixtures/v27-modes.txt) and against Unit 2's record
 * (305 modes, J-141):
 *   dsi_panel_parse_dfps_range: min 72, max 240, no step sizes -> the rates 240, 239, ..., 72 (169);
 *   dsi_display_get_modes: 2 timing nodes (dms-vid-seamless) x 169 rates; per node the h values x 2 (ctrl_count);
 *   dsi_display_get_dfps_timing, DSI_DFPS_IMMEDIATE_VFP, from the node's 90 Hz: vfp' = vfp + / - mult_frac(vtotal,
 *     |90 - r|, r); a negative vfp' is refused and the mode keeps vfp (the return code is ignored);
 *   dsi_convert_to_drm_mode: clock = (u32)(htotal * vtotal * r) (u16 x u16 x u32: wraps above 2^32) / 1000; the name
 *     uses drm_mode_vrefresh = DIV_ROUND_CLOSEST(clock * 1000, htotal * vtotal); PREFERRED when r = 90 (the panel
 *     framerate, is_default_refresh);
 *   dsi_conn_mode_valid: a mode whose vrefresh is not r is not found (dsi_display_find_mode, full timings) and pruned:
 *     timing@0 at r >= 208 (vfp' < 0, clock wrapped: "could not find mode 4128x2208x17..49vid", Unit 2's dmesg);
 *   drm_mode_sort (stable): preferred first, then larger area, higher vrefresh, higher clock. */
struct v27_timing { uint32_t ha, hfp, hpw, hbp, va, vfp, vpw, vbp; };
static const struct v27_timing V27_T[2] = { { 2064, 38, 20, 54, 2208, 2918, 2, 30 },     /* timing@0 */
					    { 1552, 38, 20, 54, 1664, 2956, 2, 30 } };   /* timing@1 */
static int v27_cmp(const struct drm_mode_modeinfo *a, const struct drm_mode_modeinfo *b)   /* drm_mode_compare */
{
	int d = ((b->type & DRM_MODE_TYPE_PREFERRED) != 0) - ((a->type & DRM_MODE_TYPE_PREFERRED) != 0);
	if (d) return d;
	d = (int)b->hdisplay * (int)b->vdisplay - (int)a->hdisplay * (int)a->vdisplay;
	if (d) return d;
	d = (int)b->vrefresh - (int)a->vrefresh;
	if (d) return d;
	return (int)b->clock - (int)a->clock;
}
static uint32_t v27_list(struct drm_mode_modeinfo *out)
{
	uint32_t n = 0;
	for (int t = 0; t < 2; t++) {
		const struct v27_timing *T = &V27_T[t];
		uint32_t vt0 = T->va + T->vfp + T->vpw + T->vbp;
		for (uint32_t r = 240; r >= 72; r--) {
			uint32_t d = r > 90 ? r - 90 : 90 - r;
			uint32_t add = (vt0 / r) * d + ((vt0 % r) * d) / r;          /* mult_frac */
			int64_t vfp = r < 90 ? (int64_t)T->vfp + add : (int64_t)T->vfp - add;
			if (vfp < 0) vfp = T->vfp;                                     /* refused: unchanged */
			struct drm_mode_modeinfo m;
			memset(&m, 0, sizeof(m));
			m.hdisplay = (uint16_t)(2 * T->ha); m.hsync_start = (uint16_t)(m.hdisplay + 2 * T->hfp);
			m.hsync_end = (uint16_t)(m.hsync_start + 2 * T->hpw); m.htotal = (uint16_t)(m.hsync_end + 2 * T->hbp);
			m.vdisplay = (uint16_t)T->va; m.vsync_start = (uint16_t)(T->va + vfp);
			m.vsync_end = (uint16_t)(m.vsync_start + T->vpw); m.vtotal = (uint16_t)(m.vsync_end + T->vbp);
			uint32_t hv = (uint32_t)m.htotal * (uint32_t)m.vtotal;
			int32_t clk = (int32_t)(hv * r);                                   /* wraps as the kernel's u32 product */
			m.clock = (uint32_t)(clk / 1000);
			m.vrefresh = (uint32_t)(((uint64_t)m.clock * 1000 + hv / 2) / hv);
			m.type = r == 90 ? DRM_MODE_TYPE_PREFERRED : 0;
			snprintf(m.name, sizeof(m.name), "%ux%ux%uvid", m.hdisplay, m.vdisplay, m.vrefresh);
			if (m.vrefresh != r) continue;                                     /* pruned by mode_valid */
			out[n++] = m;
		}
	}
	for (uint32_t i = 1; i < n; i++) {                                         /* stable insertion sort */
		struct drm_mode_modeinfo k = out[i];
		uint32_t j = i;
		while (j > 0 && v27_cmp(&out[j - 1], &k) > 0) { out[j] = out[j - 1]; j--; }
		out[j] = k;
	}
	return n;
}
/* digest of a mode list (CRC-32 over one text line per mode), compared with tools/v27-modes.py */
static uint32_t v27_digest(const struct drm_mode_modeinfo *L, uint32_t n)
{
	static char t[PS_MAXM * 128];
	size_t k = 0;
	for (uint32_t i = 0; i < n; i++) {
		const struct drm_mode_modeinfo *m = &L[i];
		k += (size_t)snprintf(t + k, sizeof(t) - k, "%u %u %u %u %u %u %u %u %u %u %u 0x%x 0x%x %s\n", i, m->hdisplay,
				      m->vdisplay, m->vrefresh, m->clock, m->hsync_start, m->hsync_end, m->htotal,
				      m->vsync_start, m->vsync_end, m->vtotal, m->flags, m->type, m->name);
	}
	return crc32_buf(t, k);
}
static void ps_gen_v27(int which)
{
	static struct drm_mode_modeinfo L[PS_MAXM];
	uint32_t n = v27_list(L);
	if (which == M_V27) {
		memcpy(ps_modes, L, n * sizeof(L[0]));
		ps_nmodes = n; ps_cur = 0;
		return;
	}
	if (which == M_TOOMANY) {
		memcpy(ps_modes, L, n * sizeof(L[0]));
		for (uint32_t i = n; i < 513; i++) {                                   /* distinct fillers */
			ps_modes[i] = L[n - 1];
			ps_modes[i].clock += i;
			ps_modes[i].type = 0;
		}
		ps_nmodes = 513; ps_cur = 0;
		return;
	}
	/* M_V27_LATE: L without its index 0 (the expected mode, e), near-duplicates inserted, e at 250, its copy at 251 */
	struct drm_mode_modeinfo e = L[0], nd;
	uint32_t k = 0;
	for (uint32_t i = 1; i < n; i++) {
		if (k == 30) { nd = e; nd.flags |= DRM_MODE_FLAG_INTERLACE; nd.type = 0; ps_modes[k++] = nd; }
		if (k == 100) { nd = e; nd.vdisplay = 2209; nd.type = 0; snprintf(nd.name, sizeof(nd.name), "4128x2209x90vid"); ps_modes[k++] = nd; }
		if (k == 250) { ps_cur = k; ps_modes[k++] = e; ps_modes[k++] = e; }
		ps_modes[k++] = L[i];
	}
	ps_nmodes = k;
}
static void ps_init(void)
{
	static const uint32_t ids[22] = { PS_CONN, PS_CRTC, 71, 97, 100, 103, 106, 109, 112, 115, 118, 121,
					  124, 128, 131, 134, 137, 140, 143, 146, 149, 152 };
	static const int rates[12] = { 90, 120, 115, 110, 105, 100, 96, 95, 85, 80, 75, 72 };
	for (int o = 0; o < 22; o++) {
		const char *const *names; int n, k;
		int base = ps_obj(ids[o], o == 0 ? DRM_MODE_OBJECT_CONNECTOR : (o == 1 ? DRM_MODE_OBJECT_CRTC : DRM_MODE_OBJECT_PLANE), &names, &n, &k);
		for (int i = 0; i < n; i++) ps_store[o][i] = ps_rule(ids[o], base, names[i], i, k);
	}
	for (int j = 0; j < 24; j++) {     /* 4128x2208 and 3104x1664, 12 rates each (as logged) */
		struct drm_mode_modeinfo *m = &ps_modes[j];
		int big = j < 12 || j == 0, r = rates[j % 12];
		if (j == 1) { big = 0; r = 90; }
		else if (j >= 2 && j < 12) { big = 1; r = rates[j - 1]; }
		else if (j == 12) { big = 1; r = 72; }
		else if (j > 12) { big = 0; r = rates[j - 12]; }
		memset(m, 0, sizeof(*m));
		m->hdisplay = big ? 4128 : 3104; m->vdisplay = big ? 2208 : 1664;
		m->htotal = big ? 4352 : 3328; m->hsync_start = big ? 4204 : 3180; m->hsync_end = big ? 4244 : 3220;
		m->clock = big ? 2020285 : 1393367;
		m->vtotal = (uint16_t)((uint64_t)m->clock * 1000 / ((uint64_t)m->htotal * (uint64_t)r));
		if (big && r == 90) m->vtotal = 5158;
		m->vsync_start = (uint16_t)(m->vtotal - 32); m->vsync_end = (uint16_t)(m->vtotal - 30);
		m->vrefresh = (uint32_t)r;
		m->type = j < 2 ? DRM_MODE_TYPE_PREFERRED : 0;
		snprintf(m->name, sizeof(m->name), "%ux%ux%dvid", m->hdisplay, m->vdisplay, r);
	}
	ps_nmodes = 24; ps_cur = 0;
	if (g_sc.modes != M_V66)
		ps_gen_v27(g_sc.modes);
	ps_crtc_valid = g_sc.active;
	ps_crtc_fb = 0;
	ps_last.valid = 0;
	ps_inited = 1;
}
static int ps_caps(int k, char *out, size_t cap)
{
	int vig = k < 4 || k >= 16;
	int pidx = k < 4 ? k : (k < 10 ? k - 4 : (k < 16 ? k - 10 : k - 16));
	int64_t smart = k >= 16 ? (int64_t)ps_planes[k - 16] : (k >= 10 ? (int64_t)ps_planes[k - 6] : -1);
	const char *up = vig ? "20" : "1";
	if (g_sc.variant == V_VIG2DUP && k == 16) { smart = -1; pidx = 2; }   /* 143: a second VIG rect 0 at pipe_idx 2 */
	if (g_sc.variant == V_VIG2UP3 && k == 2) up = "3";
	if (g_sc.variant == V_VIG2UPNONE && k == 2) up = NULL;
	if (g_sc.variant == V_DMADUP && k == 14) smart = 115;                 /* 137 also claims DMA3 rect 0 */
	int n = snprintf(out, cap, "%s%smax_linewidth=5120\n%s%s%smax_downscale=%s\nmax_horizontal_deci=0\n"
			 "max_vertical_deci=0\nmax_per_pipe_bw=4500000000\nmax_per_pipe_bw_high=5200000000\n",
			 vig ? PS_PF_VIG : PS_PF_DMA, vig ? "scaler_step_ver=12290\n" : "",
			 up ? "max_upscale=" : "", up ? up : "", up ? "\n" : "", vig ? "4" : "1");
	if (smart >= 0)
		n += snprintf(out + n, cap - (size_t)n, "primary_smart_plane_id=%lld\n", (long long)smart);
	n += snprintf(out + n, cap - (size_t)n, "pipe_idx=%d\n%s", pidx,
		      vig ? "cac_mode=2\ncac_parent_rec=4\ntrue_inline_rot_rev=513\ninverse_pma=1\n" : "inverse_pma=1\n");
	return n;
}
/* a blob of LEN non-word bytes (every byte %XX-encoded: the worst case for the stream size) */
static int ps_genblob(int len, char *out, size_t cap)
{
	int n = 0;
	for (int i = 0; i < len && (size_t)n < cap; i++) out[n++] = (char)(1 + i % 47);
	return n;
}
static int ps_blob(uint32_t id, char *out, size_t cap)
{
	if (id == 201) {
		if (g_sc.mp_len) return ps_genblob(g_sc.mp_len, out, cap);
		memcpy(out, PS_MODE_PROPS, sizeof(PS_MODE_PROPS) - 1); return (int)sizeof(PS_MODE_PROPS) - 1;
	}
	if (id == 202) {
		if (g_sc.cc_len) return ps_genblob(g_sc.cc_len, out, cap);
		memcpy(out, PS_CONN_CAPS, sizeof(PS_CONN_CAPS) - 1); return (int)sizeof(PS_CONN_CAPS) - 1;
	}
	if (id >= 300 && id < 320)
		return ps_caps((int)id - 300, out, cap);
	return -1;
}
static uint32_t ps_flags(const char *name)
{
	if (!strcmp(name, "topology_name") || !strcmp(name, "panel_mode")) return DRM_MODE_PROP_ENUM | DRM_MODE_PROP_IMMUTABLE;
	if (!strcmp(name, "dsc_mode") || !strcmp(name, "DPMS") || !strcmp(name, "blend_op") || !strcmp(name, "type")) return DRM_MODE_PROP_ENUM;
	if (!strcmp(name, "topology_control") || !strcmp(name, "rotation")) return DRM_MODE_PROP_BITMASK;
	if (!strcmp(name, "capabilities") || !strcmp(name, "mode_properties") || !strcmp(name, "EDID")) return DRM_MODE_PROP_BLOB | DRM_MODE_PROP_IMMUTABLE;
	if (!strcmp(name, "CRTC_ID") || !strcmp(name, "FB_ID")) return DRM_MODE_PROP_OBJECT;
	if (!strcmp(name, "CRTC_X") || !strcmp(name, "CRTC_Y")) return DRM_MODE_PROP_SIGNED_RANGE;
	return DRM_MODE_PROP_RANGE;
}
static const char *ps_lname(int l)
{
	switch (l) {
	case L_SINGLE_NM: return "single"; case L_SPLIT_NM: return "split"; case L_SINGLE_MS: return "single+modeset";
	case L_SPLIT_MS: return "split+modeset"; case L_QUAD_VIG: return "quad_vig"; case L_QUAD_DMA: return "quad_dma";
	case L_RESET_OFF: return "reset_off";
	default: return "other";
	}
}
static int mock_atomic(struct drm_mode_atomic *at)
{
	uint32_t *objs = (uint32_t *)(uintptr_t)at->objs_ptr, *cnt = (uint32_t *)(uintptr_t)at->count_props_ptr;
	uint32_t *props = (uint32_t *)(uintptr_t)at->props_ptr;
	uint64_t *vals = (uint64_t *)(uintptr_t)at->prop_values_ptr;
	int test = (at->flags & DRM_MODE_ATOMIC_TEST_ONLY) != 0, ms = (at->flags & DRM_MODE_ATOMIC_ALLOW_MODESET) != 0;
	int on[8], non = 0;
	int act = -1, mid = -1, kcr = -1;   /* v0.7: the ACTIVE, MODE_ID and connector CRTC_ID values set (-1: not set) */
	uint32_t p = 0;
	for (uint32_t o = 0; o < at->count_objs; o++) {
		int k = ps_plane_k(objs[o]);
		for (uint32_t j = 0; j < cnt[o]; j++, p++) {
			int so, pi;
			const char *nm = ps_prop(props[p], &so, &pi);
			if (k >= 0 && nm && !strcmp(nm, "FB_ID") && vals[p] && non < 8) on[non++] = k;
			if (nm && so == 1 && !strcmp(nm, "ACTIVE")) act = (int)vals[p];
			if (nm && so == 1 && !strcmp(nm, "MODE_ID")) mid = (int)vals[p];
			if (nm && so == 0 && !strcmp(nm, "CRTC_ID")) kcr = (int)vals[p];
		}
	}
	int lay = L_OTHER;
	if (non == 0 && ms && act == 0 && mid == 0 && kcr == 0) lay = L_RESET_OFF;
	else if (non == 0 && act == 0) lay = L_OTHER;            /* e.g. ACTIVE 0 alone: modelled as other */
	if (non == 1) lay = ms ? L_SINGLE_MS : L_SINGLE_NM;
	else if (non == 2) lay = ms ? L_SPLIT_MS : L_SPLIT_NM;
	else if (non == 4 && ms && on[0] == 0 && on[1] == 1 && on[2] == 2 && on[3] == 3) lay = L_QUAD_VIG;
	else if (non == 4 && ms && on[0] == 7 && on[1] == 13 && on[2] == 6 && on[3] == 12) lay = L_QUAD_DMA;
	int rc = (g_sc.accept & lay) ? 0 : (lay == L_SINGLE_MS ? -E2BIG : -EINVAL);
	int same = 0;
	if (!test) {
		same = ps_last.valid && ps_last.n == at->count_objs && p <= 400 &&
		       !memcmp(ps_last.objs, objs, at->count_objs * 4) && !memcmp(ps_last.cnt, cnt, at->count_objs * 4) &&
		       !memcmp(ps_last.props, props, p * 4) && !memcmp(ps_last.vals, vals, p * 8);
	}
	fprintf(stderr, "MOCK atomic %s%s rc=%d layout=%s same_as_last_accepted_test=%d set=",
		test ? "test" : "commit", ms ? "+modeset" : "", rc, ps_lname(lay), same);
	p = 0;
	for (uint32_t o = 0; o < at->count_objs; o++)
		for (uint32_t j = 0; j < cnt[o]; j++, p++) {
			int so, pi;
			const char *nm = ps_prop(props[p], &so, &pi);
			fprintf(stderr, " %u:%s=%llu", objs[o], nm ? nm : "?", (unsigned long long)vals[p]);
		}
	fprintf(stderr, "\n");
	if (test && rc == 0 && at->count_objs <= 64 && p <= 400) {
		ps_last.n = at->count_objs; memcpy(ps_last.objs, objs, at->count_objs * 4); memcpy(ps_last.cnt, cnt, at->count_objs * 4);
		memcpy(ps_last.props, props, p * 4); memcpy(ps_last.vals, vals, p * 8); ps_last.valid = 1;
	}
	if (!test && rc == 0) {
		p = 0;
		for (uint32_t o = 0; o < at->count_objs; o++)
			for (uint32_t j = 0; j < cnt[o]; j++, p++) {
				int so, pi;
				if (ps_prop(props[p], &so, &pi)) ps_store[so][pi] = vals[p];
			}
		if (ps_store[1][0]) {                                         /* ACTIVE */
			ps_crtc_valid = 1;
			if (ms) ps_store[0][19] = 14;                         /* topology_name */
		} else {                                                      /* v0.7 reset_off: no mode, no fb */
			ps_crtc_valid = 0;
			ps_crtc_fb = 0;
			ps_store[0][19] = 0;
		}
		for (uint32_t o = 0; o < at->count_objs; o++) {
			int k = ps_plane_k(objs[o]);
			if (k < 0 || !ps_store[2 + k][3]) continue;              /* index 3 = CRTC_ID */
			if (!ps_crtc_fb) ps_crtc_fb = (uint32_t)ps_store[2 + k][1];
			/* index 4 = CRTC_X: the right-half rewrite (E17) only on the quadpipe topology (14) */
			if (!g_sc.noconv && ps_store[0][19] == 14 && (int64_t)ps_store[2 + k][4] >= 2064)
				ps_store[2 + k][4] -= 2064;
		}
	}
	if (rc) { errno = -rc; return -1; }
	return 0;
}
static int mock_ioctl(int fd, unsigned long req, void *arg)
{
	(void)fd;
	if (!ps_inited) ps_init();
	if (req == DRM_IOCTL_MODE_OBJ_GETPROPERTIES) {
		struct drm_mode_obj_get_properties *op = arg;
		const char *const *names; int n, k;
		int base = ps_obj(op->obj_id, op->obj_type, &names, &n, &k);
		if (base < 0) { errno = ENOENT; return -1; }
		int so = base == 1000 ? 0 : (base == 2000 ? 1 : 2 + k);
		if (op->count_props >= (uint32_t)n && op->props_ptr) {
			uint32_t *ids = (uint32_t *)(uintptr_t)op->props_ptr;
			uint64_t *vals = (uint64_t *)(uintptr_t)op->prop_values_ptr;
			for (int i = 0; i < n; i++) { ids[i] = (uint32_t)(base + i); vals[i] = ps_store[so][i]; }
		}
		op->count_props = (uint32_t)n;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETPROPERTY) {
		struct drm_mode_get_property *gp = arg;
		int so, pi;
		const char *nm = ps_prop(gp->prop_id, &so, &pi);
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
		static char tmp[FSP_BLOB_MAX + 64];
		if (gb->blob_id == 201 && g_sc.mp_len > (int)sizeof(tmp)) {   /* v0.7.1: a blob longer than any read: length only */
			gb->length = (uint32_t)g_sc.mp_len;
			return 0;
		}
		int n = ps_blob(gb->blob_id, tmp, sizeof(tmp));
		if (n < 0) { errno = ENOENT; return -1; }
		if (gb->data && gb->length >= (uint32_t)n) memcpy((void *)(uintptr_t)gb->data, tmp, (size_t)n);
		gb->length = (uint32_t)n;
		return 0;
	}
	if (req == DRM_IOCTL_VERSION) {
		struct drm_version *v = arg;
		static const char nm[] = "msm_drm";
		if (v->name && v->name_len >= sizeof(nm)) memcpy(v->name, nm, sizeof(nm));
		v->name_len = sizeof(nm) - 1;
		v->version_major = 1; v->version_minor = 4; v->version_patchlevel = 0;
		return 0;
	}
	if (req == DRM_IOCTL_SET_CLIENT_CAP)
		return 0;
	if (req == DRM_IOCTL_MODE_GETRESOURCES) {
		struct drm_mode_card_res *r = arg;
		static const uint32_t c[3] = { 155, 156, 157 }, k[3] = { 33, 55, 65 }, e[3] = { 32, 54, 64 };
		if (r->crtc_id_ptr && r->count_crtcs >= 3) memcpy((void *)(uintptr_t)r->crtc_id_ptr, c, sizeof(c));
		if (r->connector_id_ptr && r->count_connectors >= 3) memcpy((void *)(uintptr_t)r->connector_id_ptr, k, sizeof(k));
		if (r->encoder_id_ptr && r->count_encoders >= 3) memcpy((void *)(uintptr_t)r->encoder_id_ptr, e, sizeof(e));
		r->count_crtcs = 3; r->count_connectors = 3; r->count_encoders = 3; r->count_fbs = 0;
		r->max_width = 20480; r->max_height = 8640;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETCONNECTOR) {
		struct drm_mode_get_connector *g = arg;
		if (g->connector_id == 55) {
			if (g->modes_ptr && g->count_modes >= ps_nmodes) memcpy((void *)(uintptr_t)g->modes_ptr, ps_modes, ps_nmodes * sizeof(ps_modes[0]));
			if (g->encoders_ptr && g->count_encoders >= 1) *(uint32_t *)(uintptr_t)g->encoders_ptr = 54;
			g->connector_type = DRM_MODE_CONNECTOR_DSI; g->connector_type_id = 1; g->connection = 1;
			g->count_modes = ps_nmodes; g->count_encoders = 1; g->encoder_id = 54;
		} else if (g->connector_id == 33 || g->connector_id == 65) {
			int v = g->connector_id == 33;
			g->connector_type = v ? 15 : 10; g->connector_type_id = 1; g->connection = v ? 1 : 2;
			g->count_modes = v ? 37 : 0; g->count_encoders = 1; g->encoder_id = 0;
		} else { errno = ENOENT; return -1; }
		g->mm_width = 0; g->mm_height = 0; g->count_props = 0;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETENCODER) {
		struct drm_mode_get_encoder *e = arg;
		if (e->encoder_id != 54) { errno = ENOENT; return -1; }
		e->crtc_id = g_sc.active ? PS_CRTC : 0; e->possible_crtcs = 0x7; e->encoder_type = 6;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETCRTC) {
		struct drm_mode_crtc *c = arg;
		if (c->crtc_id != PS_CRTC) { errno = ENOENT; return -1; }
		memset(&c->mode, 0, sizeof(c->mode));
		c->mode_valid = (uint32_t)ps_crtc_valid;
		if (ps_crtc_valid) c->mode = ps_modes[ps_cur];
		c->fb_id = ps_crtc_fb;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETPLANERESOURCES) {
		struct drm_mode_get_plane_res *pr = arg;
		if (pr->plane_id_ptr && pr->count_planes >= 20) memcpy((void *)(uintptr_t)pr->plane_id_ptr, ps_planes, sizeof(ps_planes));
		pr->count_planes = 20;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_GETPLANE) {
		struct drm_mode_get_plane *gp = arg;
		int k = ps_plane_k(gp->plane_id);
		if (k < 0) { errno = ENOENT; return -1; }
		uint32_t f[5] = { 0x34325241u /* AR24 */, 0x34324241u /* AB24 */, FMT_XRGB8888, 0x34324258u /* XB24 */, 0x3231564eu /* NV12 */ };
		uint32_t nf = (k < 4 || k >= 16) ? 5 : 4;
		if (gp->format_type_ptr && gp->count_format_types >= nf) memcpy((void *)(uintptr_t)gp->format_type_ptr, f, nf * 4);
		gp->count_format_types = nf;
		gp->crtc_id = (uint32_t)ps_store[2 + k][3]; gp->fb_id = (uint32_t)ps_store[2 + k][1];
		gp->possible_crtcs = 0x7; gp->gamma_size = 0;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_CREATE_DUMB) {
		struct drm_mode_create_dumb *cd = arg;
		cd->pitch = cd->width * 4; cd->size = (uint64_t)cd->pitch * cd->height; cd->handle = 1;
		return 0;
	}
	if (req == DRM_IOCTL_MODE_MAP_DUMB) { ((struct drm_mode_map_dumb *)arg)->offset = 0; return 0; }
	if (req == DRM_IOCTL_MODE_ADDFB2) { ((struct drm_mode_fb_cmd2 *)arg)->fb_id = 207; return 0; }
	if (req == DRM_IOCTL_MODE_CREATEPROPBLOB) { ((struct drm_mode_create_blob *)arg)->blob_id = 208; return 0; }
	if (req == DRM_IOCTL_MODE_ATOMIC)
		return mock_atomic(arg);
	errno = ENOTTY;
	return -1;
}
static int mock_stat(const char *p, struct stat *st)
{
	if (strcmp(p, PS_MOCK_DEV) == 0) {
		memset(st, 0, sizeof(*st));
		st->st_mode = S_IFCHR | 0600; st->st_rdev = makedev(DRM_MAJOR, 0);
		return 0;
	}
	return (stat)(p, st);
}
static int mock_fstat(int fd, struct stat *st)
{
	if (fd >= 0 && fd == g_mock_fd)
		return mock_stat(PS_MOCK_DEV, st);
	return (fstat)(fd, st);
}
static int mock_open(const char *p, int fl, ...)
{
	va_list ap;
	va_start(ap, fl);
	int mode = va_arg(ap, int);
	va_end(ap);
	if (strcmp(p, PS_MOCK_DEV) == 0) {
		g_mock_fd = (open)("/dev/null", O_RDWR | O_CLOEXEC);
		return g_mock_fd;
	}
	return (open)(p, fl, mode);
}
static void *mock_mmap(void *a, size_t n, int prot, int fl, int fd, off_t off)
{
	if (fd >= 0 && fd == g_mock_fd) {
		g_mock_map = (mmap)(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		g_mock_map_len = n;
		return g_mock_map;
	}
	return (mmap)(a, n, prot, fl, fd, off);
}
static int mock_munmap(void *a, size_t n)
{
	if (a && a == g_mock_map) {   /* the pixel classes of the drawn buffer (4 bytes per pixel) */
		uint64_t bg = 0, white = 0, red = 0, other = 0, black = 0;
		const uint32_t *px = a;
		for (size_t i = 0; i < n / 4; i++) {
			if (px[i] == 0xff808080u) bg++;
			else if (px[i] == 0xffffffffu) white++;
			else if (px[i] == FSP_SOLID_XRGB) red++;
			else if (px[i] == 0) black++;                /* v0.7 reset (step B) */
			else other++;
		}
		fprintf(stderr, "MOCK pixels n=%llu bg=%llu white=%llu red=%llu other=%llu black=%llu\n", (unsigned long long)(n / 4),
			(unsigned long long)bg, (unsigned long long)white, (unsigned long long)red, (unsigned long long)other,
			(unsigned long long)black);
		g_mock_map = NULL;
	}
	return (munmap)(a, n);
}

/* "propsim full|off|repeat|quad|solid": the start-of-run logging against the mock, framed */
static void propsim(const char *v)
{
	int kind = !strcmp(v, "off") ? K_OFF : (!strcmp(v, "quad") ? K_QUAD : (!strcmp(v, "solid") ? K_SOLID : K_SHOW));
	memset(&g_sc, 0, sizeof(g_sc));
	ps_init();
	memcpy(g_nonce, "0badc0de", 9);
	g_out_kind = "file";
	g_opt_max = kind == K_SOLID ? FSP_OPT_MAX_SOLID : FSP_OPT_MAX;
	rec_begin("start", 0); kv_s("mode", !strcmp(v, "repeat") ? "propsim-repeat" : (kind == K_OFF ? "propsim-off" :
		(kind == K_QUAD ? "propsim-quad" : (kind == K_SOLID ? "propsim-solid" : "propsim-full")))); kv_s("ver", FSP_VERSION); rec_end();
	log_properties(3, kind, PS_CONN, PS_CRTC, 71, ps_planes, 20);
	if (!strcmp(v, "repeat"))      /* three passes: the third must hit the optional budget */
		for (int i = 0; i < 2; i++)
			log_properties(3, K_SHOW, PS_CONN, PS_CRTC, 71, ps_planes, 20);
	finish(0, "propsim");
}

/* "sim SCENARIO": the WHOLE show path (run_show) against the mock device; the
 * stream on stdout, the mock's atomic log on stderr (tools/check_propsim.py sim). */
static void sim(const char *name)
{
	static const struct { const char *n; int kind, active, accept, noconv, variant, mp, cc, modes; } T[] = {
		{ "show-run1",       K_SHOW,  1, L_SPLIT_MS, 0, V_NONE, 0, 0 },
		{ "off-v05",         K_OFF,   0, L_SPLIT_MS, 0, V_NONE, 0, 0 },
		{ "quad-vig",        K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 0, 0 },
		{ "quad-dma",        K_QUAD,  0, L_SPLIT_MS | L_QUAD_DMA, 0, V_NONE, 0, 0 },
		{ "quad-reject",     K_QUAD,  0, L_SPLIT_MS, 0, V_NONE, 0, 0 },
		{ "quad-active",     K_QUAD,  1, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 0, 0 },
		{ "quad-vig2dup",    K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_VIG2DUP, 0, 0 },
		{ "quad-vig2up3",    K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_VIG2UP3, 0, 0 },
		{ "quad-vig2upnone", K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_VIG2UPNONE, 0, 0 },
		{ "quad-dmadup",     K_QUAD,  0, L_SPLIT_MS | L_QUAD_DMA, 0, V_DMADUP, 0, 0 },
		{ "quad-vig1other",  K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_VIG1OTHER, 0, 0 },
		{ "quad-capsmissing", K_QUAD, 0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_CAPSMISSING, 0, 0 },
		{ "quad-noconv",     K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 1, V_NONE, 0, 0 },
		{ "quad-max",        K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 8192, 8192 },
		{ "show-max",        K_SHOW,  1, L_SPLIT_MS, 0, V_NONE, 8192, 8192 },
		{ "solid",           K_SOLID, 0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 0, 0 },
		{ "solid-max",       K_SOLID, 0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 8192, 8192 },
		{ "blob-8193",       K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 8193, 8192 },
		/* v0.7 reset: the disable (reset_off), then the dark re-enable on the black buffer (single
		 * rejected -E2BIG as on v66, split accepted); inactive: nothing; rejections at A and at B */
		{ "reset",           K_RESET, 1, L_RESET_OFF | L_SPLIT_MS, 0, V_NONE, 0, 0 },
		{ "reset-inactive",  K_RESET, 0, L_RESET_OFF | L_SPLIT_MS, 0, V_NONE, 0, 0 },
		{ "reset-off-reject", K_RESET, 1, L_SPLIT_MS, 0, V_NONE, 0, 0 },
		{ "reset-on-reject", K_RESET, 1, L_RESET_OFF, 0, V_NONE, 0, 0 },
		{ "reset-max",       K_RESET, 1, L_RESET_OFF | L_SPLIT_MS, 0, V_NONE, 8192, 8192 },
		/* v0.7 picture options on the quad path */
		{ "quad-vig-roll0-direct", K_QUAD, 0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 0, 0 },
		/* v0.7.1: Unit 2's v2.7 connector set (33/55/65, types 15/16/10, 37/305/0 modes; J-141), the 305 modes as the
		 * v2.7 driver builds them, the mode_properties blob longer than FSP_BLOB_MAX (~228 B per mode, as on v66);
		 * r1 (reset, the splash CRTC active), r2 (quad, inactive), r3 (solid); the expected mode deep in the list
		 * behind near-duplicates; more modes than MAXMODES (still refused: exit 30) */
		{ "reset-v27",       K_RESET, 1, L_RESET_OFF | L_SPLIT_MS, 0, V_NONE, 70000, 0, M_V27 },
		{ "quad-v27",        K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 70000, 0, M_V27 },
		{ "solid-v27",       K_SOLID, 0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 70000, 0, M_V27 },
		{ "reset-v27-late",  K_RESET, 1, L_RESET_OFF | L_SPLIT_MS, 0, V_NONE, 70000, 0, M_V27_LATE },
		{ "quad-v27-late",   K_QUAD,  0, L_SPLIT_MS | L_QUAD_VIG | L_QUAD_DMA, 0, V_NONE, 70000, 0, M_V27_LATE },
		{ "reset-toomany",   K_RESET, 1, L_RESET_OFF | L_SPLIT_MS, 0, V_NONE, 0, 0, M_TOOMANY },
	};
	static const char *const kname[5] = { "show", "show-off", "show-off-quad", "show-off-solid", "reset" };
	for (unsigned i = 0; i < sizeof(T) / sizeof(T[0]); i++) {
		if (strcmp(T[i].n, name) != 0) continue;
		g_sc.active = T[i].active; g_sc.accept = T[i].accept; g_sc.noconv = T[i].noconv;
		g_sc.variant = T[i].variant; g_sc.mp_len = T[i].mp; g_sc.cc_len = T[i].cc; g_sc.modes = T[i].modes;
		ps_init();
		g_t0 = mono_ns();
		if (stdout_setup() != 0) _exit(EX_STDOUT);
		signals_init();
		alarm(FSP_SETUP_BUDGET_S);
		memcpy(g_nonce, "3c3c0a0b", 9);
		fprintf(stderr, "MOCK scenario %s kind=%s active=%d accept=%d noconv=%d variant=%d mp=%d cc=%d modes=%d n=%u cur=%u\n", name,
			kname[T[i].kind], T[i].active, T[i].accept, T[i].noconv, T[i].variant, T[i].mp, T[i].cc, T[i].modes,
			ps_nmodes, ps_cur);
		if (!strcmp(name, "quad-vig-roll0-direct")) { g_roll = 0; g_eyes_swap = 0; }
		if (T[i].kind == K_RESET) {
			rec_start_reset(PS_MOCK_DEV);
			run_show(PS_MOCK_DEV, 0, K_RESET);
		}
		rec_start(kname[T[i].kind], 1, 1, PS_MOCK_DEV);
		run_show(PS_MOCK_DEV, 1, T[i].kind);
	}
	fprintf(stderr, "unknown scenario %s\n", name);
	_exit(2);
}

/* the qcand model of the mock's planes (for the pure selection tests) */
static int ut_cands(struct qcand *c, int variant)
{
	memset(&g_sc, 0, sizeof(g_sc));
	g_sc.variant = variant;
	char b[1200];
	for (int k = 0; k < 20; k++) {
		int n = ps_caps(k, b, sizeof(b));
		memset(&c[k], 0, sizeof(c[k]));
		c[k].id = ps_planes[k]; c[k].idx = k;
		c[k].pipe_idx = kv_text_int((const uint8_t *)b, (size_t)n, "pipe_idx");
		c[k].max_upscale = kv_text_int((const uint8_t *)b, (size_t)n, "max_upscale");
		c[k].smart = kv_text_int((const uint8_t *)b, (size_t)n, "primary_smart_plane_id");
		c[k].ptype = pipe_type(c[k].max_upscale);
		c[k].eligible = c[k].pipe_idx >= 0 && c[k].max_upscale >= 0 && !(variant == V_VIG1OTHER && k == 1);
	}
	return 20;
}

int main(int argc, char **argv)
{
	crc_init();
	if (argc > 1 && strcmp(argv[1], "stream") == 0)
		sample_stream();
	if (argc > 2 && strcmp(argv[1], "propsim") == 0)
		propsim(argv[2]);
	if (argc > 2 && strcmp(argv[1], "sim") == 0)
		sim(argv[2]);
	if (argc > 1 && strcmp(argv[1], "v27modes") == 0) {   /* v0.7.1: the mock's v2.7 list, for tools/v27-modes.py */
		static struct drm_mode_modeinfo V[PS_MAXM];
		uint32_t nv = v27_list(V);
		for (uint32_t i = 0; i < nv; i++)
			printf("%u %u %u %u %u %u %u %u %u %u %u 0x%x 0x%x %s\n", i, V[i].hdisplay, V[i].vdisplay, V[i].vrefresh,
			       V[i].clock, V[i].hsync_start, V[i].hsync_end, V[i].htotal, V[i].vsync_start, V[i].vsync_end,
			       V[i].vtotal, V[i].flags, V[i].type, V[i].name);
		printf("n=%u digest=%08x\n", nv, v27_digest(V, nv));
		return 0;
	}
	struct drm_mode_modeinfo L[4];
	struct mode_pick p;

	/* mode policy (v0.5) */
	struct drm_mode_modeinfo e90 = mk(4128, 2208, 90, 0, DRM_MODE_TYPE_PREFERRED);
	struct drm_mode_modeinfo r72 = mk(4128, 2208, 72, 0, 0);
	struct drm_mode_modeinfo cur;
	L[0] = e90; L[1] = r72;
	p = pick_mode(L, 2, &r72, 1);
	ut("mode_current_active_in_list_used", p.use_current == 1 && strcmp(p.why, "crtc_current") == 0);
	p = pick_mode(L, 2, &r72, 0);
	ut("mode_current_inactive_not_used", !p.use_current && p.idx == 0);
	cur = mk(4128, 2208, 60, 0, 0);
	p = pick_mode(L, 2, &cur, 1);
	ut("mode_current_not_in_list_not_used", !p.use_current && p.idx == 0);
	cur = mk(4128, 2208, 90, DRM_MODE_FLAG_INTERLACE, 0);
	L[2] = cur;
	p = pick_mode(L, 3, &cur, 1);
	ut("mode_current_interlaced_not_used", !p.use_current && p.idx == 0);
	p = pick_mode(L, 2, NULL, 0);
	ut("mode_expected_4128x2208_90", !p.use_current && p.idx == 0);
	L[0] = mk(4128, 2208, 72, 0, DRM_MODE_TYPE_PREFERRED); L[1] = mk(4128, 2208, 120, 0, 0);
	p = pick_mode(L, 2, NULL, 0);
	ut("mode_preferred_without_90_rejected", p.idx < 0 && !p.use_current);
	L[0] = mk(1920, 1080, 90, 0, DRM_MODE_TYPE_PREFERRED);
	p = pick_mode(L, 1, NULL, 0);
	ut("mode_other_resolution_90_rejected", p.idx < 0 && !p.use_current);
	L[0] = mk(4128, 2208, 90, DRM_MODE_FLAG_INTERLACE, 0);
	p = pick_mode(L, 1, NULL, 0);
	ut("mode_interlaced_rejected", p.idx < 0);
	p = pick_mode(L, 0, NULL, 0);
	ut("mode_empty_list_rejected", p.idx < 0 && !p.use_current);
	cur = mk(9000, 2208, 90, 0, 0);
	L[0] = cur;
	p = pick_mode(L, 1, &cur, 1);
	ut("mode_current_out_of_range_rejected", p.idx < 0 && !p.use_current);

	/* attempt order and modeset gating (v0.5; the quad modes' split probe is attempt 2 of (0,1,1)) */
	struct attempt A[4];
	int n = plan_attempts(1, 1, 1, A);
	ut("plan_current_expected_helper", n == 4 && !A[0].modeset && !A[0].split && !A[1].modeset && A[1].split &&
	   A[2].modeset && !A[2].split && A[3].modeset && A[3].split);
	n = plan_attempts(1, 1, 0, A);
	ut("plan_current_expected_nohelper", n == 2 && !A[0].modeset && A[1].modeset && !A[0].split && !A[1].split);
	n = plan_attempts(0, 1, 1, A);
	ut("plan_nocurrent_helper", n == 2 && A[0].modeset && A[1].modeset && !A[0].split && A[1].split);
	n = plan_attempts(1, 0, 1, A);
	ut("plan_current_not_expected_no_modeset", n == 2 && !A[0].modeset && !A[1].modeset);
	n = plan_attempts(0, 0, 1, A);
	ut("plan_nothing_allowed", n == 0);

	/* empty / dash values are explicit tokens */
	memcpy(g_nonce, "0badc0de", 9);
	rec_begin("e", 0); kv_str("name", "", 8); rec_frame();
	ut("empty_string_is_dash", strstr(g_line, " name=- len=") != NULL);
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

	/* show-off precondition (v0.5) */
	ut("precond_inactive_proven", crtc_provably_inactive(0, 22, 0) == 1);
	ut("precond_active_refused", crtc_provably_inactive(0, 22, 1) == 0);
	ut("precond_no_active_prop_refused", crtc_provably_inactive(0, 0, 0) == 0);
	ut("precond_getcrtc_failed_refused", crtc_provably_inactive(-22, 22, 0) == 0);

	/* SDE info-blob parse (v0.5) */
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

	/* packed-list and blob encodings (v0.5) */
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

	/* optional-record budget at both v0.6 limits: fits -> emitted with the next seq; the first
	 * that does not fit -> ONE opt_budget record with that same seq; later ones skipped */
	{
		static const unsigned lim[2] = { FSP_OPT_MAX, FSP_OPT_MAX_SOLID };
		int okb = 1;
		fflush(stdout);
		int saved = dup(1), dn = open("/dev/null", O_WRONLY);
		dup2(dn, 1);
		for (int j = 0; j < 2; j++) {
			g_opt_max = lim[j];
			g_seq = 10; g_opt_bytes = 0; g_opt_skipped = 0; g_opt_closed = 0;
			rec_begin_opt("blob"); kv_s("k", "v"); rec_end_opt();
			size_t one = g_opt_bytes;                       /* a record's framed length */
			okb &= g_seq == 11 && one > 0 && !g_opt_closed;
			g_opt_bytes = lim[j] - (unsigned)one;           /* exactly fits: emitted, budget reached */
			rec_begin_opt("blob"); kv_s("k", "v"); rec_end_opt();
			okb &= g_seq == 12 && g_opt_bytes == lim[j] && !g_opt_closed;
			rec_begin_opt("blob"); kv_s("k", "v"); rec_end_opt();   /* one byte over: opt_budget, same seq */
			okb &= g_seq == 13 && g_opt_closed == 1 && g_opt_skipped == 1 && strstr(g_line, "step=opt_budget rc=-28 max=") != NULL;
			rec_begin_opt("blob"); kv_s("k", "v"); rec_end_opt();
			okb &= g_seq == 13 && g_opt_skipped == 2;
		}
		fflush(stdout); dup2(saved, 1); close(saved); close(dn);
		ut("opt_budget_boundaries_38912_and_10240", okb);
		g_opt_max = FSP_OPT_MAX;
	}
	/* build review: a per-object record is essential below its ESS count (seq advances, no opt bytes) and
	 * optional from it on (counted in the opt budget; skipped once the budget is closed, the seq gap-free) */
	{
		int oke = 1;
		fflush(stdout);
		int saved = dup(1), dn = open("/dev/null", O_WRONLY);
		dup2(dn, 1);
		g_opt_max = FSP_OPT_MAX; g_seq = 20; g_opt_bytes = 0; g_opt_skipped = 0; g_opt_closed = 0;
		rec_begin_ess("plane", 0, FSP_ESS_PLANES - 1, FSP_ESS_PLANES); kv_u("id", 1); rec_end_ess(FSP_ESS_PLANES - 1, FSP_ESS_PLANES);
		oke &= g_seq == 21 && g_opt_bytes == 0;
		rec_begin_ess("plane", -2, FSP_ESS_PLANES, FSP_ESS_PLANES); kv_u("id", 2); rec_end_ess(FSP_ESS_PLANES, FSP_ESS_PLANES);
		oke &= g_seq == 22 && g_opt_bytes > 0 && strstr(g_line, "step=plane rc=-2 id=2 ") != NULL;
		rec_mode("mode", FSP_ESS_MODES, &modes[0], 1); rec_end_ess(FSP_ESS_MODES, FSP_ESS_MODES);
		oke &= g_seq == 23;
		g_opt_closed = 1;                                   /* budget closed: further optional records are skipped */
		rec_begin_ess("connector", 0, FSP_ESS_CONNECTORS, FSP_ESS_CONNECTORS); rec_end_ess(FSP_ESS_CONNECTORS, FSP_ESS_CONNECTORS);
		oke &= g_seq == 23 && g_opt_skipped == 1;
		rec_begin_ess("connector", 0, 0, FSP_ESS_CONNECTORS); rec_end_ess(0, FSP_ESS_CONNECTORS);   /* essential: always written */
		oke &= g_seq == 24;
		fflush(stdout); dup2(saved, 1); close(saved); close(dn);
		ut("essential_cap_per_object_records_beyond_24_modes_20_planes_3_connectors_are_optional",
		   oke && FSP_ESS_MODES == 24 && FSP_ESS_PLANES == 20 && FSP_ESS_CONNECTORS == 3);
		g_opt_max = FSP_OPT_MAX; g_opt_bytes = 0; g_opt_skipped = 0; g_opt_closed = 0;
	}

	/* v0.6: pipe type from max_upscale; capabilities parse incl. primary_smart_plane_id and NV12 */
	ut("pipe_type_vig20_dma1_else_unknown", pipe_type(20) == PT_VIG && pipe_type(1) == PT_DMA && pipe_type(3) == PT_UNKNOWN &&
	   pipe_type(-1) == PT_UNKNOWN && pipe_type(0) == PT_UNKNOWN);
	{
		char b[1200];
		memset(&g_sc, 0, sizeof(g_sc));
		int m = ps_caps(16, b, sizeof(b));                     /* VIG0 rect 1 */
		ut("caps_rect1_smart_and_pipe", kv_text_int((uint8_t *)b, (size_t)m, "primary_smart_plane_id") == 71 &&
		   kv_text_int((uint8_t *)b, (size_t)m, "pipe_idx") == 0 && kv_text_int((uint8_t *)b, (size_t)m, "max_upscale") == 20);
		ut("caps_nv12_vig_yes", kv_text_has((uint8_t *)b, (size_t)m, "pixel_formats", "NV12") == 1);
		m = ps_caps(7, b, sizeof(b));                          /* DMA3 rect 0 */
		ut("caps_dma_rect0_no_smart_upscale1_pipe3", kv_text_int((uint8_t *)b, (size_t)m, "primary_smart_plane_id") == -1 &&
		   kv_text_int((uint8_t *)b, (size_t)m, "max_upscale") == 1 && kv_text_int((uint8_t *)b, (size_t)m, "pipe_idx") == 3);
		ut("caps_nv12_dma_no", kv_text_has((uint8_t *)b, (size_t)m, "pixel_formats", "NV12") == 0);
		const char *q = "pixel_formats=NV12/5/1,XR24\n";
		const char *q2 = "pixel_formats=NV120 XR24\nx=1\n";
		ut("kvhas_modifier_and_comma", kv_text_has((const uint8_t *)q, strlen(q), "pixel_formats", "NV12") == 1 &&
		   kv_text_has((const uint8_t *)q2, strlen(q2), "pixel_formats", "NV12") == 0 &&
		   kv_text_has((const uint8_t *)q2, strlen(q2), "formats", "NV12") == -1);
	}

	/* v0.6: quad selection on the mock model (E4/E16; DMA rect-0 blobs report pipe_idx 0..5) */
	{
		struct qcand c[20];
		int s[4], nn;
		const char *why = "";
		nn = ut_cands(c, V_NONE);
		ut("select_vig_71_97_100_103_despite_dma_pipe_idx_0_3", quad_select(c, nn, Q_VIG, s, &why) == 0 &&
		   c[s[0]].id == 71 && c[s[1]].id == 97 && c[s[2]].id == 100 && c[s[3]].id == 103);
		ut("select_dma_115_134_112_131", quad_select(c, nn, Q_DMA, s, &why) == 0 &&
		   c[s[0]].id == 115 && c[s[1]].id == 134 && c[s[2]].id == 112 && c[s[3]].id == 131);
		nn = ut_cands(c, V_VIG2DUP);
		ut("select_vig_two_rect0_at_pipe2_ambiguous", quad_select(c, nn, Q_VIG, s, &why) == -1 && !strcmp(why, "ambiguous"));
		ut("select_dma_unaffected_by_vig_dup", quad_select(c, nn, Q_DMA, s, &why) == 0);
		nn = ut_cands(c, V_VIG2UP3);
		ut("select_vig_upscale3_missing", quad_select(c, nn, Q_VIG, s, &why) == -1 && !strcmp(why, "missing"));
		nn = ut_cands(c, V_VIG2UPNONE);
		ut("select_vig_upscale_absent_missing", quad_select(c, nn, Q_VIG, s, &why) == -1 && !strcmp(why, "missing"));
		nn = ut_cands(c, V_DMADUP);
		ut("select_dma_duplicate_rect1_ambiguous", quad_select(c, nn, Q_DMA, s, &why) == -1 && !strcmp(why, "ambiguous"));
		nn = ut_cands(c, V_VIG1OTHER);
		ut("select_vig_plane_on_other_crtc_missing", quad_select(c, nn, Q_VIG, s, &why) == -1 && !strcmp(why, "missing"));
		nn = ut_cands(c, V_NONE);
		for (int k = 0; k < 20; k++) c[k].eligible = k < 3;   /* < 4 eligible planes */
		ut("select_fewer_than_4_eligible_unavailable", quad_select(c, nn, Q_VIG, s, &why) == -1 && quad_select(c, nn, Q_DMA, s, &why) == -1);
	}

	/* v0.6: zpos table, a_plane_z = a_plane + exactly one zpos property (last) */
	{
		struct plane_info pz;
		memset(&pz, 0, sizeof(pz));
		pz.id = 71; pz.p_fb = 1; pz.p_crtc = 2; pz.p_sx = 3; pz.p_sy = 4; pz.p_sw = 5; pz.p_sh = 6;
		pz.p_cx = 7; pz.p_cy = 8; pz.p_cw = 9; pz.p_ch = 10; pz.p_zpos = 11;
		ut("zpos_table_0011", FSP_QUAD_Z[0] == 0 && FSP_QUAD_Z[1] == 0 && FSP_QUAD_Z[2] == 1 && FSP_QUAD_Z[3] == 1);
		memset(&a, 0, sizeof(a));
		a_plane_z(&a, &pz, 207, 155, 2064, 1032, 2208, FSP_QUAD_Z[2]);
		ut("a_plane_z_11_props_zpos_last", a.nobj == 1 && a.nprop == 11 && a.counts[0] == 11 && a.props[10] == 11 && a.vals[10] == 1 &&
		   a.vals[2] == (2064ull << 16) && a.vals[6] == 2064 && a.vals[4] == (1032ull << 16) && a.vals[8] == 1032);
	}

	/* v0.6: the solid word and the pattern's level set (small render) */
	{
		uint32_t px[64 * 64];
		draw_solid((uint8_t *)px, 64 * 4, 64, 64);
		int all = 1;
		for (int i = 0; i < 64 * 64; i++) all &= px[i] == 0x00FF0000u;
		ut("solid_every_word_00FF0000", all);
		static uint32_t big2[256 * 128];
		draw_pattern((uint8_t *)big2, 256 * 4, 256, 128, "3f9c07ab");
		int lv = 1;
		for (int i = 0; i < 256 * 128; i++) lv &= big2[i] == 0xff808080u || big2[i] == 0xffffffffu;
		ut("pattern_two_levels_only", lv);
	}

	/* v0.7: the per-eye mapping, the roll arithmetic, the options, the reset request */
	{
		ut("fdiv_floor", fdiv(7, 2) == 3 && fdiv(-7, 2) == -4 && fdiv(-8, 2) == -4 && fdiv(0, 5) == 0 && fdiv(-1, 131072) == -1);
		ut("eye_half_swap_left_is_half1", eye_half(1, 1) == 1 && eye_half(0, 1) == 0);
		ut("eye_half_direct_left_is_half0", eye_half(1, 0) == 0 && eye_half(0, 0) == 1);
		ut("eye_sin_left_ccw_right_cw", eye_sin(1, 21) == 23486 && eye_sin(0, 21) == -23486 && eye_sin(1, -21) == -23486 &&
		   eye_sin(0, -21) == 23486 && eye_sin(1, 0) == 0 && eye_sin(0, 0) == 0);
		int tab = 1;
		for (int d = 0; d <= FSP_ROLL_MAX; d++) {
			int64_t s = SIN_Q16[d], c = COS_Q16[d], n = s * s + c * c;
			tab &= n > (int64_t)65536 * 65536 - 140000 && n < (int64_t)65536 * 65536 + 140000;   /* |(s, c)| = 1 within rounding */
			if (d) tab &= SIN_Q16[d] > SIN_Q16[d - 1] && COS_Q16[d] < COS_Q16[d - 1];
		}
		ut("sin_cos_q16_table_unit_norm_monotonic", tab && SIN_Q16[21] == 23486 && COS_Q16[21] == 61183);
		/* the identity blit (s = 0) is v0.6's 180-degree mapping: eye pixel (x, y) -> buffer (ew-1-x, h-1-y) */
		{
			static uint32_t b3[16 * 8];
			static uint8_t e3[8 * 8];
			struct canvas c3 = { (uint8_t *)b3, 16 * 4, 16, 8, 8, 8, e3 };
			memset(e3, C_BG, sizeof(e3));
			e3[1 * 8 + 2] = 0xFF;                                  /* viewer (2, 1) */
			blit_eye(&c3, 0, COS_Q16[0]);
			int okb = b3[(8 - 1 - 1) * 16 + 8 + (8 - 1 - 2)] == 0xffffffffu, nw = 0;
			for (int i = 0; i < 16 * 8; i++) nw += b3[i] == 0xffffffffu;
			ut("blit_identity_is_the_v06_180_mapping", okb && nw == 1);
		}
		g_opt_roll_seen = g_opt_eyes_seen = 0; g_roll = 99;
		ut("opt_roll_minus25", parse_opt("roll=-25") == 1 && g_roll == -25);
		ut("opt_roll_twice_refused", parse_opt("roll=3") == -1);
		g_opt_roll_seen = 0;
		ut("opt_roll_bad_values_refused", parse_opt("roll=26") == -1 && parse_opt("roll=05") == -1 && parse_opt("roll=-0") == -1 &&
		   parse_opt("roll=") == -1 && parse_opt("roll=1a") == -1 && parse_opt("roll=100") == -1 && parse_opt("roll=+3") == -1);
		ut("opt_eyes", parse_opt("eyes=direct") == 1 && g_eyes_swap == 0 && parse_opt("eyes=swap") == -1);
		g_opt_eyes_seen = 0;
		ut("opt_eyes_bad_refused", parse_opt("eyes=left") == -1 && parse_opt("eyes=") == -1);
		ut("opt_not_an_option", parse_opt("/dev/dri/card0") == 0 && parse_opt("zoom=2") == -1);
		g_roll = FSP_ROLL_DEFAULT; g_eyes_swap = FSP_EYES_SWAP; g_opt_roll_seen = g_opt_eyes_seen = 0;
		/* build_reset: connector CRTC_ID 0, MODE_ID 0, ACTIVE 0, the planes bound to the CRTC off, nothing else */
		struct areq ra;
		nplanes = 3;
		memset(planes, 0, sizeof(planes[0]) * 3);
		planes[0].id = 71; planes[0].crtc_id = 155; planes[0].p_fb = 501; planes[0].p_crtc = 502;
		planes[1].id = 97; planes[1].crtc_id = 0;   planes[1].p_fb = 511; planes[1].p_crtc = 512;
		planes[2].id = 100; planes[2].crtc_id = 155; planes[2].p_fb = 521; planes[2].p_crtc = 522;
		int roff = build_reset(&ra, 55, 401, 155, 402, 403);
		int rv = roff == 2 && ra.nobj == 4 && ra.nprop == 7 && !ra.over &&
			 ra.objs[0] == 55 && ra.counts[0] == 1 && ra.props[0] == 401 &&
			 ra.objs[1] == 155 && ra.counts[1] == 2 && ra.props[1] == 402 && ra.props[2] == 403 &&
			 ra.objs[2] == 71 && ra.props[3] == 501 && ra.props[4] == 502 && ra.objs[3] == 100 && ra.props[5] == 521 && ra.props[6] == 522;
		for (uint32_t i = 0; i < ra.nprop; i++) rv &= ra.vals[i] == 0;
		ut("build_reset_only_zero_values_conn_crtc_and_bound_planes", rv);
		nplanes = 0;
		/* the black buffer of step B */
		static uint32_t bk[32 * 4];
		memset(bk, 0x55, sizeof(bk));
		draw_black((uint8_t *)bk, 32 * 4, 32, 4);
		int allb = 1;
		for (int i = 0; i < 32 * 4; i++) allb &= bk[i] == 0;
		ut("reset_black_every_word_00000000", allb);
	}

	/* v0.7.1: the v2.7 mode list (J-141) and the mode policy on it */
	{
		static struct drm_mode_modeinfo V[PS_MAXM];
		uint32_t nv = v27_list(V), n4 = 0, n3 = 0, ne = 0, ie = 0, bad = 0;
		for (uint32_t i = 0; i < nv; i++) {
			n4 += V[i].hdisplay == 4128 && V[i].vdisplay == 2208;
			n3 += V[i].hdisplay == 3104 && V[i].vdisplay == 1664;
			if (is_expected_mode(&V[i])) { ne++; ie = i; }
			if (V[i].hdisplay == 4128 && (V[i].vrefresh < 72 || V[i].vrefresh > 207)) bad++;
		}
		ut("v27_list_305_modes_136_at_4128x2208_169_at_3104x1664", nv == 305 && n4 == 136 && n3 == 169 && bad == 0);
		ut("v27_list_more_than_v07_maxmodes_128_and_fits_maxmodes", nv > 128 && nv <= MAXMODES && 2 * 169 <= MAXMODES);
		const struct drm_mode_modeinfo *e = &V[ie];
		ut("v27_exactly_one_expected_mode_index0_with_the_v66_90hz_timing",
		   ne == 1 && ie == 0 && e->clock == 2020285 && e->hsync_start == 4204 && e->hsync_end == 4244 && e->htotal == 4352 &&
		   e->vsync_start == 5126 && e->vsync_end == 5128 && e->vtotal == 5158 && e->flags == 0 &&
		   e->type == DRM_MODE_TYPE_PREFERRED && strcmp(e->name, "4128x2208x90vid") == 0);
		ut("v27_near_duplicates_present_not_expected", nv > 2 && V[1].hdisplay == 3104 && V[1].vrefresh == 90 &&
		   !is_expected_mode(&V[1]) && V[2].hdisplay == 4128 && V[2].vrefresh == 207 && V[nv - 1].vrefresh == 72);
		p = pick_mode(V, nv, NULL, 0);
		ut("v27_pick_inactive_expected_index0", !p.use_current && p.idx == 0 && strcmp(p.why, "expected_4128x2208_90") == 0);
		p = pick_mode(V, nv, &V[0], 1);
		ut("v27_pick_active_splash_mode_current", p.use_current == 1);
		struct drm_mode_modeinfo s91 = V[0];
		s91.vtotal = 5159;                                    /* a splash mode not in the list: not used as current */
		p = pick_mode(V, nv, &s91, 1);
		ut("v27_pick_active_mode_not_in_list_falls_back_to_index0", !p.use_current && p.idx == 0);
		memset(&g_sc, 0, sizeof(g_sc));
		g_sc.modes = M_V27_LATE;
		ps_init();
		p = pick_mode(ps_modes, ps_nmodes, NULL, 0);
		ut("v27_late_pick_index250_the_exact_v27_mode_not_a_near_duplicate",
		   ps_nmodes == 308 && ps_cur == 250 && !p.use_current && p.idx == 250 && mode_eq(&ps_modes[250], &V[0]) &&
		   (ps_modes[30].flags & DRM_MODE_FLAG_INTERLACE) && ps_modes[100].vdisplay == 2209 && !is_expected_mode(&ps_modes[30]) &&
		   !is_expected_mode(&ps_modes[100]));
		g_sc.modes = M_TOOMANY;
		ps_init();
		ut("toomany_513_above_maxmodes", ps_nmodes == 513 && ps_nmodes > MAXMODES);
		memset(&g_sc, 0, sizeof(g_sc));
		ps_init();
		ut("v66_list_unchanged_24", ps_nmodes == 24 && ps_cur == 0 && ps_modes[0].vtotal == 5158 && ps_modes[0].vrefresh == 90);
		ut("log_modes_48_ess_24", FSP_LOG_MODES == 48 && FSP_ESS_MODES == 24);
	}

	printf("UT_TOTAL failures=%d\n", ut_fail);
	return ut_fail ? 1 : 0;
}
#endif
