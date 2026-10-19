// SPDX-License-Identifier: GPL-2.0-only
/*
 * fsbg-probe: the K1g proof program for fs-blkguard (FrameShift).
 *
 * Attempts every guarded write path and expects a refusal that the guard
 * itself counted.  Safety design (docs/research/fs-blkguard-design.md, section 7):
 *
 *   1. Pre-check: /proc/fs_blkguard present, mode/seal/module latch as
 *      expected, the guard's own verdict table covers every boot-storage
 *      node.  Any failure: ABORT, no armed guard test case attempted.
 *   2. Mechanism phase on harmless decoys only: RAM disks, a loop device on
 *      a tmpfs file carrying a GPT with protected names, dm and loop stacks
 *      on those.  Real data-carrying writes, full capabilities.  Every decoy
 *      is re-verified as RAM-backed before each write attempt.
 *   3. Protected phase (device mode), only if phase 2 passed completely:
 *      every case is built so that the kernel's own checks refuse it even
 *      with no guard (read-only fds, dropped CAP_SYS_ADMIN/CAP_SYS_RAWIO,
 *      zero-length CDBs with no data buffer, nonexistent partition numbers);
 *      the guard hook sits in front of those checks, so its counter proves
 *      it acted.  The last case per node is open(O_RDWR), closed at once
 *      without any write.  The first unexpected success stops everything.
 *   4. Read-back hashing (O_DIRECT, SHA-256) before and after, same boot.
 *
 * "vm" mode (QEMU virt / UML only; refused on Qualcomm hardware) treats every
 * disk that is not a RAM/loop/dm decoy as a decoy too and sends real data
 * through every path, including SCSI pass-through.
 *
 * Exit: 0 PASS, 1 FAIL, 2 ABORT.  As PID 1 it mounts proc/sys/dev, runs,
 * prints the result and powers off.
 *
 * Copyright (C) 2026 FrameShift contributors
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <linux/aio_abi.h>
#include <linux/bsg.h>
#include <linux/dm-ioctl.h>
#include <linux/falloc.h>
#include <linux/fs.h>
#include <linux/loop.h>
#include <linux/capability.h>
#include <linux/reboot.h>
#include <scsi/sg.h>
#include <sys/ioctl.h>
#include <poll.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <sys/swap.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <linux/blkpg.h>
#include <linux/pr.h>
#include <time.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#include <sys/auxv.h>
#ifndef HWCAP_SHA2
#define HWCAP_SHA2 (1 << 6)
#endif
#endif

#define PROC_GUARD	"/proc/fs_blkguard"
#define WORKDIR		"/run/fsbg"
#define DECOY_IMG	WORKDIR "/decoy.img"
#define DECOY_SECTORS	32768ULL		/* 16 MiB */
#define DECOY_LOOP	6
#define STACK_LOOP	7
#define DM_MINOR_RW	200
#define DM_MINOR_RO	201
#define DM_MINOR_NEW	202
#define BS		4096
/* The O_DIRECT alignment of the hashing reads (offset, length and buffer address): the Quest 3's UFS logical block
 * size, as a fixed constant (no BLKSSZGET: the hashing open keeps BLKGETSIZE64 as its only ioctl). K1g r3, J-207:
 * rounding to 512 bytes gave EINVAL on the unit's 4096-byte logical blocks. */
#define DIO_ALIGN	4096

#ifndef SCSI_IOCTL_SEND_COMMAND
#define SCSI_IOCTL_SEND_COMMAND 1
#endif
#ifndef BLKSECDISCARD
#define BLKSECDISCARD _IO(0x12, 125)
#endif
#ifndef BLKZEROOUT
#define BLKZEROOUT _IO(0x12, 127)
#endif

enum { P_OPEN, P_WRITE, P_FALLOC, P_DISCARD, P_ZEROOUT, P_ROSET, P_BLKPG,
       P_RRPART, P_BIO, P_SCSI, P_SG, P_BSG, P_SCSI_IOCTL, P_PR, P_NR };
static const char *const pname[P_NR] = { "open", "write", "fallocate",
	"discard", "zeroout", "roset", "blkpg", "rrpart", "bio", "scsi", "sg",
	"bsg", "scsi-ioctl", "pr" };

#ifndef SCSI_IOCTL_START_UNIT
#define SCSI_IOCTL_START_UNIT 5
#define SCSI_IOCTL_STOP_UNIT 6
#endif
#define UFS_IOCTL_QUERY 0x5388	/* ufs-qcom host ioctl (scsi/ufs/ioctl.h) */

static int vm_mode, stop_all, n_pass, n_fail, n_case, test_kernel, force_q, device_sim;
static int late_abort;	/* a decoy check refused after arming: the result is ABORT, never PASS */
/* Time budget (K1g README s.5). On the unit fs-supervise stops the probe at 25 s (init.sh -t 25).
 *   - The before-hash pass (from the probe's start, decoy set-up included) must end within PRE_BUDGET (8 s);
 *     otherwise the probe stops BEFORE ARMING with "ABORT: time:" (no armed guard test case attempted; the host: INCONCLUSIVE).
 *   - The after-pass reads the same rows (about the same time again) after the cases (allowance 3 s), and must
 *     end by AFTER_END (20 s from the start), 5 s before fs-supervise's TERM, so a row's KILL still fits.
 *   - Each row is bounded like `timeout -k 5 <n>`: n = the time left until its pass's end, at most 10 s.
 * In QEMU/UML (emulated hashing) the rows are bounded at 60 s and the before-pass budget is 120 s
 * (fsbg.prebudget=<s> overrides it there, for the negative test). */
#define AFTER_END 20.0
static double t_start, pre_budget = 8.0;
static int row_timeouts;	/* rows that hit their bound in the current pass */
static int platform_is_vm(void);

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* The bound of the next row: the time left in its pass (at least 1 s, at most 10 s) on the unit; 60 s in VMs. */
static int row_limit(int after)
{
	double left = (after ? AFTER_END : pre_budget) - (now_s() - t_start);

	if (platform_is_vm())
		return 60;
	if (left < 1)
		return 1;
	return left < 10 ? (int)left : 10;
}
static char nonce[64] = "none";
static char arm_req[256];
static int arm_mode_strict = 1;

/* ------------------------------------------------------------------ util */

static int compact;		/* --compact: stdout carries summaries and failures only */
static FILE *fullf;		/* WORKDIR/full.log: every line, always */

static void say(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fflush(stdout);
	if (fullf) {
		va_start(ap, fmt);
		vfprintf(fullf, fmt, ap);
		va_end(ap);
		fflush(fullf);
	}
}

/* Per-series tallies for the compact output. */
struct tally { char id[8]; int pass, fail; };
static struct tally tallies[64];
static int n_tallies;

static void tally(const char *id, int pass)
{
	int i;

	for (i = 0; i < n_tallies; i++)
		if (!strcmp(tallies[i].id, id))
			break;
	if (i == n_tallies) {
		if (n_tallies == 64)
			return;
		snprintf(tallies[n_tallies++].id, sizeof(tallies[0].id), "%s", id);
	}
	if (pass)
		tallies[i].pass++;
	else
		tallies[i].fail++;
}

/* A result line: always in the full log; on stdout unless compact and passing (show forces it). */
static int shown_fail, suppressed_fail;

static void sayq(int show, int pass, const char *id, const char *fmt, ...)
{
	va_list ap;

	tally(id, pass);
	if (compact && !pass && !show && shown_fail >= 24) {
		suppressed_fail++;		/* the full log keeps it */
	} else if (!compact || show || !pass) {
		if (!pass && !show)
			shown_fail++;
		va_start(ap, fmt);
		vprintf(fmt, ap);
		va_end(ap);
		fflush(stdout);
	}
	if (fullf) {
		va_start(ap, fmt);
		vfprintf(fullf, fmt, ap);
		va_end(ap);
		fflush(fullf);
	}
}

static int read_text(const char *path, char *buf, size_t n)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	ssize_t r, tot = 0;

	if (fd < 0)
		return -1;
	while (tot < (ssize_t)n - 1 && (r = read(fd, buf + tot, n - 1 - tot)) > 0)
		tot += r;
	close(fd);
	buf[tot] = '\0';
	return (int)tot;
}

static int write_text(const char *path, const char *s)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	ssize_t r;

	if (fd < 0)
		return -errno;
	r = write(fd, s, strlen(s));
	r = r < 0 ? -errno : 0;
	close(fd);
	return (int)r;
}

/* SHA-256 (FIPS 180-4), compact. */
struct sha { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; };
static const uint32_t K[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha_blk(struct sha *s, const uint8_t *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2;
	int i;

	for (i = 0; i < 16; i++)
		w[i] = (uint32_t)p[4*i] << 24 | p[4*i+1] << 16 | p[4*i+2] << 8 | p[4*i+3];
	for (; i < 64; i++)
		w[i] = (ROR(w[i-2], 17) ^ ROR(w[i-2], 19) ^ (w[i-2] >> 10)) + w[i-7] +
		       (ROR(w[i-15], 7) ^ ROR(w[i-15], 18) ^ (w[i-15] >> 3)) + w[i-16];
	a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3];
	e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
	for (i = 0; i < 64; i++) {
		t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
		t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
	s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}
#if defined(__aarch64__)
/* The same block function with the ARMv8 SHA-256 instructions (ACLE intrinsics): about ten times
 * the portable code's rate. Used only when the CPU reports HWCAP_SHA2 AND the known-answer self-test
 * below agrees with the portable code (sha_select). */
__attribute__((target("arch=armv8-a+crypto")))
static void sha_blk_ce(struct sha *s, const uint8_t *p)
{
	uint32x4_t abcd = vld1q_u32(&s->h[0]), efgh = vld1q_u32(&s->h[4]);
	uint32x4_t a0 = abcd, e0 = efgh, m[4], t, x;
	int i;

	for (i = 0; i < 4; i++)
		m[i] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(p + 16 * i)));
	for (i = 0; i < 16; i++) {
		if (i >= 4)	/* W[4i..4i+3] from W[t-16], W[t-12], W[t-8], W[t-4] */
			m[i & 3] = vsha256su1q_u32(vsha256su0q_u32(m[i & 3], m[(i + 1) & 3]),
						   m[(i + 2) & 3], m[(i + 3) & 3]);
		t = vaddq_u32(m[i & 3], vld1q_u32(&K[4 * i]));
		x = abcd;
		abcd = vsha256hq_u32(abcd, efgh, t);
		efgh = vsha256h2q_u32(efgh, x, t);
	}
	vst1q_u32(&s->h[0], vaddq_u32(a0, abcd));
	vst1q_u32(&s->h[4], vaddq_u32(e0, efgh));
}
#endif
static void (*sha_blk_fn)(struct sha *, const uint8_t *) = sha_blk;
static const char *sha_impl = "portable";

static void sha_init(struct sha *s)
{
	static const uint32_t iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372,
		0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
	memcpy(s->h, iv, sizeof(iv));
	s->len = 0;
	s->n = 0;
}
static void sha_upd(struct sha *s, const void *d, size_t n)
{
	const uint8_t *p = d;

	s->len += n;
	while (n) {
		size_t k = 64 - s->n < n ? 64 - s->n : n;

		memcpy(s->buf + s->n, p, k);
		s->n += k; p += k; n -= k;
		if (s->n == 64) {
			sha_blk_fn(s, s->buf);
			s->n = 0;
		}
	}
}
static void sha_hex(struct sha *s, char out[65])
{
	uint64_t bits = s->len * 8;
	uint8_t pad = 0x80, z = 0, lb[8];
	int i;

	sha_upd(s, &pad, 1);
	while (s->n != 56)
		sha_upd(s, &z, 1);
	for (i = 0; i < 8; i++)
		lb[i] = bits >> (56 - 8 * i);
	sha_upd(s, lb, 8);
	for (i = 0; i < 8; i++)
		sprintf(out + 8 * i, "%08x", s->h[i]);
	out[64] = 0;
}

/* Picks the block function: the ARMv8 instructions only if HWCAP_SHA2 is set and both known-answer
 * tests agree ("abc", FIPS 180-4; and 4096 pseudo-random bytes against the portable code). */
static void sha_select(void)
{
#if defined(__aarch64__)
	static uint8_t buf[4096];
	struct sha a, b;
	char ha[65], hb[65];
	uint32_t x = 0x2545f491;
	size_t i;

	if (!(getauxval(AT_HWCAP) & HWCAP_SHA2)) {
		sha_impl = "portable (no HWCAP_SHA2)";
		return;
	}
	for (i = 0; i < sizeof(buf); i++) {
		x ^= x << 13; x ^= x >> 17; x ^= x << 5;
		buf[i] = (uint8_t)x;
	}
	sha_blk_fn = sha_blk_ce;		/* the ARMv8 code: "abc" and the buffer */
	sha_init(&a);
	sha_upd(&a, "abc", 3);
	sha_hex(&a, ha);
	sha_init(&b);
	sha_upd(&b, buf, sizeof(buf));
	sha_hex(&b, hb);
	sha_blk_fn = sha_blk;			/* the portable code: the buffer */
	{
		struct sha c;
		char hc[65];

		sha_init(&c);
		sha_upd(&c, buf, sizeof(buf));
		sha_hex(&c, hc);
		if (strcmp(ha, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") ||
		    strcmp(hb, hc)) {
			sha_impl = "portable (ARMv8 self-test failed)";
			return;
		}
	}
	sha_blk_fn = sha_blk_ce;
	sha_impl = "armv8-ce";
#endif
}

static uint32_t crc32_le(const void *d, size_t n)
{
	const uint8_t *p = d;
	uint32_t c = 0xffffffff;
	int k;

	while (n--) {
		c ^= *p++;
		for (k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xedb88320 & -(c & 1));
	}
	return ~c;
}

/*
 * One hashing row (aligned with the readback proposal (private) §5.1, fail-closed):
 *   range > 0 : plain SHA-256 of bytes [0, range) (the AVB-covered image of R1-R5);
 *   range == 0: the whole node if its size <= cap, else its first and last MiB.
 * Read-only open (O_RDONLY | O_DIRECT, one open, no fallback), no other ioctl than BLKGETSIZE64. Each read is
 * rounded up to whole DIO_ALIGN (4096-byte) blocks inside the node and only the row's bytes are hashed; a rounded
 * read past the end of the node, or one that returns less than its aligned length, fails closed (K1g r3).
 * Reports the size, the bytes hashed and the bytes the row requires; the caller accepts
 * the row only if they are equal and the hash is not the empty-input hash.
 */
struct hres { int err; uint64_t size, got, want; char hex[65]; };

/* The size of an open node: BLKGETSIZE64 for a block device (no I/O), st_size for a regular file (unit tests). */
static uint64_t node_size(int fd)
{
	struct stat st;
	uint64_t sz = 0;

	if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode))
		return (uint64_t)st.st_size;
	if (ioctl(fd, BLKGETSIZE64, &sz))
		return 0;
	return sz;
}

/*
 * FS-R-014 s.3.1, the content-read allowlist. Enumeration and guard coverage (sysfs metadata, the guard's own
 * verdict table) are separate from permission to open a node and read its content. On the unit, content may be
 * read ONLY from the partitions of the accepted readback rows: R1-R5 (boot_a, vendor_boot_a, dtbo_a, vbmeta_a,
 * vbmeta_system_a, over their AVB-covered ranges) and the scoped misc/devinfo checks (R6 sizes, R7d misc whole,
 * R8 devinfo whole; the readback proposal (private)). Never persist, never a whole LUN, never another
 * partition. The partition is identified by the kernel's own name for the node (sysfs PARTNAME of the device
 * whose number the node carries), not by the node's file name, so discovery order and unexpected names cannot
 * widen it. The probe's RAM/loop/dm decoys and (vm mode only) the VM's host-file disks are not real storage.
 */
static const char *const content_allow[] = { "boot_a", "vendor_boot_a", "dtbo_a", "vbmeta_a", "vbmeta_system_a",
					     "misc", "devinfo" };
static int (*partname_hook)(const char *path, char *out, size_t n);	/* unit tests only (never set in the probe) */
static int partname_of(const char *path, char *out, size_t n);

static int path_is_decoy(const char *path)
{
	const char *bn = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;

	return !strncmp(path, "/run/", 5) || !strncmp(bn, "ram", 3) || !strncmp(bn, "loop", 4) ||
	       !strncmp(bn, "dm-", 3) || !strncmp(bn, "zram", 4);
}

static int content_read_allowed(const char *path)
{
	char pn[64];
	size_t i;

	if (vm_mode && !partname_hook)
		return 1;			/* QEMU/UML vm mode: every disk is a host-file decoy */
	if (path_is_decoy(path))
		return 1;
	if (partname_of(path, pn, sizeof(pn)))
		return 0;			/* not identifiable: refused */
	for (i = 0; i < sizeof(content_allow) / sizeof(content_allow[0]); i++)
		if (!strcmp(pn, content_allow[i]))
			return 1;
	return 0;
}

static void hash_node_do(const char *path, uint64_t cap, uint64_t range, struct hres *r)
{
	/* one EIO retry only for our RAM/tmpfs decoys (a refused mmap writeback leaves a stale error);
	 * never for real storage (readback PROPOSAL s.5.1: no retry) */
	const char *bn = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
	int retry_ok = vm_mode || !strncmp(bn, "ram", 3) || !strncmp(bn, "loop", 4) || !strncmp(path, "/run/", 5);
	uint64_t off, end;
	void *buf;
	struct sha s;
	int pass, fd;

	memset(r, 0, sizeof(*r));
	/* FS-R-014 s.3.1: the content-read allowlist is checked BEFORE the open (also in hash_row, the caller) */
	if (!content_read_allowed(path)) {
		r->err = EACCES;
		return;
	}
	/* FS-R-014 s.3.3: exactly one open, O_RDONLY | O_DIRECT; no second open without O_DIRECT (every node the
	 * probe hashes is a block device: the unit's allowlisted partitions, its RAM/loop decoys, VM disks) */
	fd = open(path, O_RDONLY | O_DIRECT | O_CLOEXEC);
	if (fd < 0) {
		r->err = errno;
		return;
	}
	r->size = node_size(fd);
	if (range)
		r->want = range;
	else
		r->want = r->size <= cap ? r->size : (2ULL << 20);
	if (!r->size || r->want > r->size || posix_memalign(&buf, DIO_ALIGN, 1 << 20)) {
		r->err = !r->size ? ENODATA : r->want > r->size ? EOVERFLOW : ENOMEM;	/* EOVERFLOW: the range is beyond the node */
		close(fd);
		return;
	}
	sha_init(&s);
	for (pass = 0; pass < 2; pass++) {
		if (range || r->size <= cap) {
			off = 0; end = range ? range : r->size;
			if (pass)
				break;
		} else if (!pass) {
			off = 0; end = 1 << 20;
		} else {
			off = r->size - (1 << 20); end = r->size;
		}
		while (off < end) {
			size_t want = end - off > (1 << 20) ? (1 << 20) : end - off;
			/* K1g r3: O_DIRECT needs whole LOGICAL BLOCKS (offset, length and buffer address): read up to
			 * the next DIO_ALIGN (4096) bytes and hash only want. The Quest 3's UFS LUNs have 4096-byte
			 * logical blocks; 4096 is a multiple of 512, so the same rounding serves 512-byte devices. Every
			 * offset here is 0, a multiple of 1 MiB or (head/tail rows) size - 1 MiB; buf is DIO_ALIGN-
			 * aligned and 1 MiB long, so rd never exceeds it. A rounded read that would pass the end of the
			 * node fails closed (ERANGE; no unaligned or shortened read instead). On a 4096-byte-block device
			 * a node's size is a multiple of 4096, so this cannot happen there; on a 512-byte device it fails
			 * a whole-node row whose size is not a multiple of 4096 (every decoy and VM disk the probe reads
			 * is a whole number of MiB). */
			size_t rd = (want + (DIO_ALIGN - 1)) & ~(size_t)(DIO_ALIGN - 1);
			ssize_t n;

			if (off + rd > r->size) {	/* the rounded read would pass the end of the node */
				r->err = ERANGE;
				free(buf);
				close(fd);
				return;
			}
			n = pread(fd, buf, rd, off);
			if (n < 0 && errno == EIO && retry_ok)	/* decoys only: a stale writeback error */
				n = pread(fd, buf, rd, off);
			if (n != (ssize_t)rd) {	/* short or failed read (of the whole aligned length): fail closed */
				r->err = n < 0 ? errno : EIO;
				free(buf);
				close(fd);
				return;
			}
			sha_upd(&s, buf, want);
			r->got += want;
			off += want;
		}
	}
	sha_hex(&s, r->hex);
	free(buf);
	close(fd);
}

/* The row in a child, bounded like `timeout -k 5 <limit>`: TERM at the limit, KILL 5 s later. */
static int hash_node(const char *path, uint64_t cap, uint64_t range, int limit, struct hres *r)
{
	int pfd[2], st, i;
	pid_t pid;

	memset(r, 0, sizeof(*r));
	if (pipe(pfd))
		return -EIO;
	pid = fork();
	if (pid == 0) {
		struct hres c;

		close(pfd[0]);
		hash_node_do(path, cap, range, &c);
		if (write(pfd[1], &c, sizeof(c)) != sizeof(c))
			_exit(3);
		_exit(0);
	}
	close(pfd[1]);
	if (pid < 0) {
		close(pfd[0]);
		return -EIO;
	}
	{
		struct pollfd p = { .fd = pfd[0], .events = POLLIN };

		if (poll(&p, 1, limit * 1000) != 1 ||
		    read(pfd[0], r, sizeof(*r)) != sizeof(*r)) {
			kill(pid, SIGTERM);
			for (i = 0; i < 50 && waitpid(pid, &st, WNOHANG) == 0; i++)
				usleep(100000);
			if (i == 50) {
				kill(pid, SIGKILL);
				waitpid(pid, &st, 0);
			}
			close(pfd[0]);
			memset(r, 0, sizeof(*r));
			r->err = ETIMEDOUT;
			return -ETIMEDOUT;
		}
	}
	close(pfd[0]);
	waitpid(pid, &st, 0);
	return r->err ? -r->err : 0;
}

/* ------------------------------------------------------------ the guard */

struct gstate {
	char mode[16];
	int sealed, modlock, have;
	char hazards[256];
	long cnt[P_NR], total;
	char *targets;			/* the "targets:" section */
};

static char guard_buf[1 << 18];

static int guard_read(struct gstate *g)
{
	char *p, *q;
	int i;

	memset(g, 0, sizeof(*g));
	if (read_text(PROC_GUARD, guard_buf, sizeof(guard_buf)) <= 0)
		return -1;
	if (strncmp(guard_buf, "fs_blkguard 1\n", 14))
		return -1;
	g->have = 1;
	if ((p = strstr(guard_buf, "\nmode: ")))
		sscanf(p + 7, "%15s", g->mode);
	if ((p = strstr(guard_buf, "\nsealed: ")))
		g->sealed = atoi(p + 9);
	if ((p = strstr(guard_buf, "\nmodules_disabled: ")))
		g->modlock = atoi(p + 19);
	if ((p = strstr(guard_buf, "\nhazards:"))) {
		q = strchr(p + 1, '\n');
		snprintf(g->hazards, sizeof(g->hazards), "%.*s",
			 (int)(q ? q - p - 10 : 0), p + 10);
	}
	if (!(p = strstr(guard_buf, "\ndenied:")))
		return -1;
	for (i = 0; i < P_NR; i++) {
		char key[24];

		snprintf(key, sizeof(key), " %s=", pname[i]);
		q = strstr(p, key);
		if (!q)
			return -1;
		g->cnt[i] = atol(q + strlen(key));
	}
	if ((q = strstr(p, " total=")))
		g->total = atol(q + 7);
	g->targets = strstr(guard_buf, "\ntargets:\n");
	return 0;
}

/* The guard's own verdict for a node, e.g. "deny-protected"; "" if absent. */
static void guard_verdict(const char *dev, char *out, size_t n)
{
	struct gstate g;
	char key[64], *p;

	out[0] = '\0';
	if (guard_read(&g) || !g.targets)
		return;
	snprintf(key, sizeof(key), "\n  %s ", dev);
	p = strstr(g.targets, key);
	if (!p)
		return;
	p += strlen(key);
	p = strchr(p, ' ');		/* skip the GPT name column */
	if (!p)
		return;
	sscanf(p + 1, "%31s", out);
	(void)n;
}

/* --------------------------------------------------------------- cases */

#define E(x) (1u << (x))		/* errno set bit (errno < 32) */
#define EXP_REFUSE  (E(EPERM) | E(EACCES))
#define EXP_EIO     (E(EIO))

typedef int (*case_fn)(void *arg);

struct case_spec {
	const char *id, *target;
	int path;		/* counter that must move */
	unsigned int errs;	/* acceptable errno set */
	int min_d, max_d;	/* bounds on that counter's delta */
	int drop;		/* capability bits to drop in a child */
	int protected;		/* real boot storage: unexpected success stops */
};

#define DROP_ADMIN	1
#define DROP_RAWIO	2

static int drop_caps(int which)
{
	struct __user_cap_header_struct h = { _LINUX_CAPABILITY_VERSION_3, 0 };
	struct __user_cap_data_struct d[2];

	if (syscall(SYS_capget, &h, d))
		return -1;
	if (which & DROP_ADMIN) {
		d[0].effective &= ~(1u << CAP_SYS_ADMIN);
		d[0].permitted &= ~(1u << CAP_SYS_ADMIN);
	}
	if (which & DROP_RAWIO) {
		d[0].effective &= ~(1u << CAP_SYS_RAWIO);
		d[0].permitted &= ~(1u << CAP_SYS_RAWIO);
	}
	return (int)syscall(SYS_capset, &h, d);
}

/* Runs fn (in a child if capabilities are dropped); returns 0 or -errno. */
static int run_fn(case_fn fn, void *arg, int drop)
{
	int pfd[2], rc = -EIO;
	pid_t pid;

	if (!drop)
		return fn(arg);
	if (pipe(pfd))
		return -EIO;
	pid = fork();
	if (pid == 0) {
		close(pfd[0]);
		rc = drop_caps(drop) ? -ECHILD : fn(arg);
		if (write(pfd[1], &rc, sizeof(rc)) != sizeof(rc))
			_exit(3);
		_exit(0);
	}
	close(pfd[1]);
	if (pid < 0 || read(pfd[0], &rc, sizeof(rc)) != sizeof(rc))
		rc = -EIO;
	close(pfd[0]);
	if (pid > 0)
		waitpid(pid, NULL, 0);
	return rc;
}

static int run_case(const struct case_spec *c, case_fn fn, void *arg)
{
	struct gstate a, b;
	long d, other;
	int rc, ok;

	if (stop_all)
		return -1;
	n_case++;
	if (guard_read(&a)) {
		say("CASE %s %s: cannot read the guard -> FAIL\n", c->id, c->target);
		n_fail++;
		stop_all = 1;
		return -1;
	}
	rc = run_fn(fn, arg, c->drop);
	guard_read(&b);
	d = b.cnt[c->path] - a.cnt[c->path];
	other = (b.total - a.total) - d;
	ok = rc < 0 && -rc < 32 && (c->errs & E(-rc)) &&
	     d >= c->min_d && d <= c->max_d && other == 0;
	sayq(0, ok, c->id, "CASE %-5s %-22s %-9s rc=%-4d %-8s d=%ld other=%ld -> %s\n",
	     c->id, c->target, pname[c->path], rc, rc < 0 ? strerrorname_np(-rc) : "OK",
	     d, other, ok ? "PASS" : "FAIL");
	if (ok) {
		n_pass++;
		return 0;
	}
	n_fail++;
	if (rc >= 0 && (c->protected || !vm_mode)) {
		say("STOP: an operation that must be refused succeeded on %s\n", c->target);
		stop_all = 1;
	}
	return -1;
}

/* Positive control: must succeed and must not move any counter. */
static int run_allow(const char *id, const char *target, case_fn fn, void *arg)
{
	struct gstate a, b;
	int rc;

	if (stop_all)
		return -1;
	n_case++;
	guard_read(&a);
	rc = fn(arg);
	guard_read(&b);
	sayq(0, rc == 0 && b.total == a.total, id, "ALLOW %-5s %-22s rc=%-4d d_total=%ld -> %s\n",
	     id, target, rc, b.total - a.total, rc == 0 && b.total == a.total ? "PASS" : "FAIL");
	if (rc == 0 && b.total == a.total) {
		n_pass++;
		return 0;
	}
	n_fail++;
	return -1;
}

/* ------------------------------------------------------- case functions */

struct op {
	const char *dev;
	int fd;			/* pre-opened fd, or -1 */
	int flags;		/* open flags */
	unsigned long req;
	long arg;
	const uint8_t *cdb;
	int cdb_len;
	int data_len;		/* bytes sent to the device (SCSI) */
	int dir;		/* SG_DXFER_* */
	void *argp;		/* ioctl argument for fn_ptr_ioctl */
};

static uint8_t *pattern;	/* BS bytes of 0xA5 */

static int with_fd(struct op *o, int (*f)(struct op *, int))
{
	int fd = o->fd, rc;

	if (fd < 0) {
		fd = open(o->dev, o->flags | O_CLOEXEC);
		if (fd < 0)
			return -errno;
	}
	rc = f(o, fd);
	if (o->fd < 0)
		close(fd);
	return rc;
}

static int fn_open(void *arg)
{
	struct op *o = arg;
	int fd = open(o->dev, o->flags | O_CLOEXEC);

	if (fd < 0)
		return -errno;
	close(fd);		/* closed at once, never written */
	return 0;
}

static int f_range_ioctl(struct op *o, int fd)
{
	uint64_t range[2] = { 0, (uint64_t)o->arg };

	return ioctl(fd, o->req, range) ? -errno : 0;
}
static int fn_range_ioctl(void *arg) { return with_fd(arg, f_range_ioctl); }

static int f_int_ioctl(struct op *o, int fd)
{
	int v = (int)o->arg;

	return ioctl(fd, o->req, &v) ? -errno : 0;
}
static int fn_int_ioctl(void *arg) { return with_fd(arg, f_int_ioctl); }

static int f_ptr_ioctl(struct op *o, int fd)
{
	return ioctl(fd, o->req, o->argp) ? -errno : 0;
}
static int fn_ptr_ioctl(void *arg) { return with_fd(arg, f_ptr_ioctl); }

static int f_noarg_ioctl(struct op *o, int fd)
{
	return ioctl(fd, o->req, 0) ? -errno : 0;
}
static int fn_noarg_ioctl(void *arg) { return with_fd(arg, f_noarg_ioctl); }

static int f_blkpg(struct op *o, int fd)
{
	struct blkpg_partition p = { 0 };
	struct blkpg_ioctl_arg a = { 0 };

	a.op = (int)o->arg;
	a.datalen = sizeof(p);
	a.data = &p;
	p.pno = (a.op == BLKPG_RESIZE_PARTITION) ? 1 : 250;
	p.start = 1 << 20;	/* overlaps the first decoy partition */
	p.length = 1 << 20;
	return ioctl(fd, BLKPG, &a) ? -errno : 0;
}
static int fn_blkpg(void *arg) { return with_fd(arg, f_blkpg); }

static int f_write(struct op *o, int fd)
{
	ssize_t r = pwrite(fd, pattern, BS, 0);

	return r < 0 ? -errno : (r == BS ? 0 : -EIO);
}
static int fn_write(void *arg) { return with_fd(arg, f_write); }

static int f_writev(struct op *o, int fd)
{
	struct iovec v[2] = { { pattern, BS / 2 }, { pattern, BS / 2 } };
	ssize_t r = pwritev(fd, v, 2, BS);

	return r < 0 ? -errno : 0;
}
static int fn_writev(void *arg) { return with_fd(arg, f_writev); }

static int f_falloc(struct op *o, int fd)
{
	return fallocate(fd, (int)o->arg, 0, BS) ? -errno : 0;
}
static int fn_falloc(void *arg) { return with_fd(arg, f_falloc); }

static int f_mmap(struct op *o, int fd)
{
	void *m = mmap(NULL, BS, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	int rc;

	if (m == MAP_FAILED)
		return -errno;
	memset(m, 0x5a, BS);
	rc = msync(m, BS, MS_SYNC) ? -errno : 0;
	munmap(m, BS);
	return rc;
}
static int fn_mmap(void *arg) { return with_fd(arg, f_mmap); }

static int f_aio(struct op *o, int fd)
{
	aio_context_t ctx = 0;
	struct iocb cb = { 0 }, *cbs[1] = { &cb };
	struct io_event ev;
	int rc;

	if (syscall(SYS_io_setup, 1, &ctx))
		return -errno;
	cb.aio_fildes = fd;
	cb.aio_lio_opcode = IOCB_CMD_PWRITE;
	cb.aio_buf = (uintptr_t)pattern;
	cb.aio_nbytes = BS;
	rc = (int)syscall(SYS_io_submit, ctx, 1, cbs);
	if (rc == 1) {
		rc = (int)syscall(SYS_io_getevents, ctx, 1, 1, &ev, NULL);
		rc = rc == 1 ? (ev.res < 0 ? (int)ev.res : 0) : -EIO;
	} else {
		rc = -errno;
	}
	syscall(SYS_io_destroy, ctx);
	return rc;
}
static int fn_aio(void *arg) { return with_fd(arg, f_aio); }

static int f_sendfile(struct op *o, int fd)
{
	int in = open(WORKDIR "/pattern", O_RDONLY | O_CLOEXEC);
	ssize_t r;

	if (in < 0)
		return -errno;
	r = sendfile(fd, in, NULL, BS);
	close(in);
	return r < 0 ? -errno : 0;
}
static int fn_sendfile(void *arg) { return with_fd(arg, f_sendfile); }


static int fn_swapon(void *arg)
{
	struct op *o = arg;

	if (swapon(o->dev, 0) == 0) {
		swapoff(o->dev);
		return 0;
	}
	return -errno;
}

/* SG_IO v3 on sd or sg. */
static int f_sgio(struct op *o, int fd)
{
	sg_io_hdr_t h = { 0 };
	uint8_t sense[32];

	h.interface_id = 'S';
	h.cmd_len = o->cdb_len;
	h.cmdp = (unsigned char *)o->cdb;
	h.dxfer_direction = o->dir;
	h.dxfer_len = o->data_len;
	h.dxferp = o->data_len ? pattern : NULL;
	h.sbp = sense;
	h.mx_sb_len = sizeof(sense);
	h.timeout = 5000;
	if (ioctl(fd, SG_IO, &h))
		return -errno;
	return (h.status || h.host_status || h.driver_status) ? -EREMOTEIO : 0;
}
static int fn_sgio(void *arg) { return with_fd(arg, f_sgio); }

/* SG_IO v4 on a bsg node (SCSI command or a transport request). */
static int f_bsg(struct op *o, int fd)
{
	struct sg_io_v4 h = { 0 };
	uint8_t sense[32], resp[256];

	h.guard = 'Q';
	h.protocol = BSG_PROTOCOL_SCSI;
	h.subprotocol = o->req ? BSG_SUB_PROTOCOL_SCSI_TRANSPORT : BSG_SUB_PROTOCOL_SCSI_CMD;
	h.request_len = o->cdb_len;
	h.request = (uintptr_t)o->cdb;
	if (o->dir == SG_DXFER_TO_DEV && o->data_len) {
		h.dout_xfer_len = o->data_len;
		h.dout_xferp = (uintptr_t)pattern;
	} else if (o->dir == SG_DXFER_FROM_DEV) {
		h.din_xfer_len = o->data_len;
		h.din_xferp = (uintptr_t)resp;
	}
	h.response = (uintptr_t)sense;
	h.max_response_len = sizeof(sense);
	h.timeout = 5000;
	if (ioctl(fd, SG_IO, &h))
		return -errno;
	return (h.device_status || h.transport_status || h.driver_status) ? -EREMOTEIO : 0;
}
static int fn_bsg(void *arg) { return with_fd(arg, f_bsg); }

/* Whether the SCSI host behind sd has a driver ioctl (scsi_debug, ufshcd do; virtio-scsi
 * does not): read from the host's proc_name, a fixed list. */
static int host_has_ioctl(const char *sd)
{
	char p[160], real[4096], b[64], *h;
	const char *n = strrchr(sd, '/') ? strrchr(sd, '/') + 1 : sd;
	int host;

	/* the device's sysfs path contains ".../hostN/targetH:C:T/H:C:T:L" */
	snprintf(p, sizeof(p), "/sys/block/%s/device", n);
	if (!realpath(p, real))
		return 0;
	for (h = strstr(real, "/host"); h; h = strstr(h + 1, "/host"))
		if (sscanf(h, "/host%d/", &host) == 1)
			break;
	if (!h)
		return 0;
	snprintf(p, sizeof(p), "/sys/class/scsi_host/host%d/proc_name", host);
	if (read_text(p, b, sizeof(b)) <= 0)
		return 0;
	if (!strncmp(b, "ufshcd", 6))	/* ufs-qcom installs UFS_IOCTL_QUERY; QEMU's PCI UFS host has none */
		return !platform_is_vm();
	return !strncmp(b, "scsi_debug", 10);
}

/* SCSI_IOCTL_SEND_COMMAND on sd. */
static int f_sendcmd(struct op *o, int fd)
{
	unsigned char buf[8 + 16 + BS];
	unsigned int inlen = o->data_len, outlen = 0;

	memcpy(buf, &inlen, 4);
	memcpy(buf + 4, &outlen, 4);
	memcpy(buf + 8, o->cdb, o->cdb_len);
	memcpy(buf + 8 + o->cdb_len, pattern, inlen);
	return ioctl(fd, SCSI_IOCTL_SEND_COMMAND, buf) ? -errno : 0;
}
static int fn_sendcmd(void *arg) { return with_fd(arg, f_sendcmd); }

/* Legacy sg write(2) interface (struct sg_header + CDB + data). */
static int f_sgwrite(struct op *o, int fd)
{
	unsigned char buf[sizeof(struct sg_header) + 16 + BS];
	struct sg_header *h = (struct sg_header *)buf;
	size_t n = sizeof(*h) + o->cdb_len + o->data_len;
	ssize_t r;

	memset(h, 0, sizeof(*h));
	h->reply_len = sizeof(*h);
	h->pack_len = n;
	memcpy(buf + sizeof(*h), o->cdb, o->cdb_len);
	memcpy(buf + sizeof(*h) + o->cdb_len, pattern, o->data_len);
	r = write(fd, buf, n);
	if (r < 0)
		return -errno;
	r = read(fd, buf, sizeof(*h));		/* reap the reply */
	return 0;
}
static int fn_sgwrite(void *arg) { return with_fd(arg, f_sgwrite); }

/* ------------------------------------------------------- device-mapper */

static int dm_major(void)
{
	char b[4096], *p;
	int maj;

	if (read_text("/proc/devices", b, sizeof(b)) <= 0)
		return -1;
	p = strstr(b, " device-mapper\n");
	if (!p)
		return -1;
	while (p > b && p[-1] != '\n')
		p--;
	return sscanf(p, "%d", &maj) == 1 ? maj : -1;
}

static void ensure_nodes(void);
static int uevent_get(const char *sysdir, const char *key, char *out, size_t n);

static int dm_call(unsigned long cmd, const char *name, int minor, uint32_t flags,
		   const char *target_dev, uint64_t sectors)
{
	char buf[16384];
	struct dm_ioctl *io = (struct dm_ioctl *)buf;
	int fd, rc, maj = dm_major();

	if (maj < 0)
		return -ENODEV;
	memset(buf, 0, sizeof(buf));
	io->version[0] = DM_VERSION_MAJOR;
	io->version[1] = 0;
	io->version[2] = 0;
	io->data_size = sizeof(buf);
	io->data_start = sizeof(*io);
	io->flags = flags;
	snprintf(io->name, sizeof(io->name), "%s", name);
	if (cmd == DM_DEV_CREATE) {
		io->flags |= DM_PERSISTENT_DEV_FLAG;
		io->dev = makedev(maj, minor);
	}
	if (cmd == DM_TABLE_LOAD) {
		struct dm_target_spec *t = (struct dm_target_spec *)(buf + sizeof(*io));
		char *params = (char *)(t + 1);

		io->target_count = 1;
		t->sector_start = 0;
		t->length = sectors;
		snprintf(t->target_type, sizeof(t->target_type), "linear");
		snprintf(params, 256, "%s 0", target_dev);
		t->next = 0;
	}
	fd = open("/dev/mapper/control", O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -errno;
	rc = ioctl(fd, cmd, io) ? -errno : 0;
	close(fd);
	return rc;
}

/* Creates /dev/dm-<minor> = linear over target_dev; ro adds DM_READONLY_FLAG. */
static int dm_make(const char *name, int minor, const char *target_dev,
		   uint64_t sectors, int ro)
{
	int rc = dm_call(DM_DEV_CREATE, name, minor, 0, NULL, 0);

	if (rc)
		return rc;
	rc = dm_call(DM_TABLE_LOAD, name, 0, ro ? DM_READONLY_FLAG : 0,
		     target_dev, sectors);
	if (rc) {
		dm_call(DM_DEV_REMOVE, name, 0, 0, NULL, 0);
		return rc;
	}
	rc = dm_call(DM_DEV_SUSPEND, name, 0, 0, NULL, 0);	/* resume */
	ensure_nodes();
	return rc;
}

struct dmop { const char *name, *target; int minor; uint64_t sectors; };
static int fn_dm_load_rw(void *arg)
{
	struct dmop *d = arg;
	int rc = dm_make(d->name, d->minor, d->target, d->sectors, 0);

	if (rc == 0)
		dm_call(DM_DEV_REMOVE, d->name, 0, 0, NULL, 0);
	return rc;
}

/* ----------------------------------------------------------- the decoys */

static void put16le(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static void put32le(uint8_t *p, uint32_t v) { put16le(p, v); put16le(p + 2, v >> 16); }
static void put64le(uint8_t *p, uint64_t v) { put32le(p, v); put32le(p + 4, v >> 32); }

struct gpt_part { const char *name; uint64_t first, last; };
static const struct gpt_part decoy_parts[] = {
	{ "xbl_a",         2048,  4095 },	/* 1: protected name */
	{ "persist",       4096,  6143 },	/* 2: protected name, swap header */
	{ "boot_a",        6144,  8191 },	/* 3: protected name */
	{ "modemst1",      8192, 10239 },	/* 4: protected name */
	{ "fsbg_decoy_rw",10240, 12287 },	/* 5: allowlisted by name */
	{ "fsbg_decoy_ro",12288, 14335 },	/* 6: unprotected, not listed */
};
#define N_DECOY_PARTS 6

/* The SCSI decoy (vm mode) carries no allowlisted name: every node must be refused. */
static const struct gpt_part scsi_parts[] = {
	{ "xbl_a",         2048,  4095 },
	{ "persist",       4096,  6143 },
	{ "boot_a",        6144,  8191 },
	{ "modemst1",      8192, 10239 },
	{ "tz_a",         10240, 12287 },
	{ "fsbg_decoy_ro",12288, 14335 },
};

/* Writes a valid GPT (primary + backup) into buf of 'sectors' 512-byte sectors. */
static void make_gpt(uint8_t *img, uint64_t sectors, const struct gpt_part *parts, int n)
{
	static const uint8_t linux_type[16] = { 0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84,
		0x72, 0x47, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4 };
	uint8_t ent[128 * 128], hdr[92];
	uint32_t ecrc;
	int i, k, b;

	memset(ent, 0, sizeof(ent));
	for (i = 0; i < n; i++) {
		uint8_t *e = ent + 128 * i;

		memcpy(e, linux_type, 16);
		for (k = 0; k < 16; k++)
			e[16 + k] = 0x40 + i * 16 + k;	/* unique GUID */
		put64le(e + 32, parts[i].first);
		put64le(e + 40, parts[i].last);
		for (k = 0; parts[i].name[k] && k < 36; k++)
			put16le(e + 56 + 2 * k, (uint8_t)parts[i].name[k]);
	}
	ecrc = crc32_le(ent, sizeof(ent));
	/* protective MBR */
	img[446 + 4] = 0xee;
	put32le(img + 446 + 8, 1);
	put32le(img + 446 + 12, sectors - 1 > 0xffffffffULL ? 0xffffffff : (uint32_t)(sectors - 1));
	img[510] = 0x55; img[511] = 0xaa;
	for (b = 0; b < 2; b++) {
		uint64_t my = b ? sectors - 1 : 1, alt = b ? 1 : sectors - 1;
		uint64_t elba = b ? sectors - 33 : 2;

		memset(hdr, 0, sizeof(hdr));
		memcpy(hdr, "EFI PART", 8);
		put32le(hdr + 8, 0x00010000);
		put32le(hdr + 12, 92);
		put64le(hdr + 24, my);
		put64le(hdr + 32, alt);
		put64le(hdr + 40, 34);
		put64le(hdr + 48, sectors - 34);
		for (k = 0; k < 16; k++)
			hdr[56 + k] = 0xf0 + k;
		put64le(hdr + 72, elba);
		put32le(hdr + 80, 128);
		put32le(hdr + 84, 128);
		put32le(hdr + 88, ecrc);
		put32le(hdr + 16, crc32_le(hdr, 92));
		memcpy(img + 512 * my, hdr, 92);
		memcpy(img + 512 * elba, ent, sizeof(ent));
	}
}

static void make_swap_header(uint8_t *p, uint64_t bytes)
{
	/* struct swap_header_v1_2 within the first page; magic at page end */
	put32le(p + 1024, 1);				/* version */
	put32le(p + 1028, (uint32_t)(bytes / BS - 1));	/* last_page */
	memcpy(p + BS - 10, "SWAPSPACE2", 10);
}

/*
 * K1a/K1g's PID 1 keeps /dev a tmpfs populated by `mdev -s` (no devtmpfs, no hotplug helper),
 * so nodes for devices created later (loop partitions, dm, sg, bsg) do not appear by
 * themselves. Create any missing node from its sysfs "dev" file (a tmpfs write, as mdev does).
 */
static void mknod_from(const char *sysdir, const char *devpath, int blk)
{
	char p[300], b[32], dir[300], *sl;
	unsigned int ma, mi;

	snprintf(p, sizeof(p), "%s/dev", sysdir);
	if (read_text(p, b, sizeof(b)) <= 0 || sscanf(b, "%u:%u", &ma, &mi) != 2)
		return;
	snprintf(dir, sizeof(dir), "%s", devpath);
	if ((sl = strrchr(dir, '/')) && sl != dir) {
		*sl = '\0';
		mkdir(dir, 0755);
	}
	mknod(devpath, (blk ? S_IFBLK : S_IFCHR) | 0600, makedev(ma, mi));	/* EEXIST is fine */
}

static void ensure_nodes(void)
{
	static const struct { const char *cls, *prefix; int blk; } c[] = {
		{ "/sys/class/block", "/dev/", 1 },
		{ "/sys/class/scsi_generic", "/dev/", 0 },
		{ "/sys/class/bsg", "/dev/bsg/", 0 },
	};
	char sd[300], dp[300];
	size_t k;

	for (k = 0; k < sizeof(c) / sizeof(c[0]); k++) {
		DIR *d = opendir(c[k].cls);
		struct dirent *e;

		if (!d)
			continue;
		while ((e = readdir(d)))
			if (e->d_name[0] != '.') {
				char pn[64] = "";

				snprintf(sd, sizeof(sd), "%s/%s", c[k].cls, e->d_name);
				snprintf(dp, sizeof(dp), "%s%s", c[k].prefix, e->d_name);
				/* FS-R-014 s.3.1: the probe makes no node for the real persist partition (device
				 * mode); its own RAM/loop decoys (one decoy partition is named persist) are kept */
				if (c[k].blk && !vm_mode && !path_is_decoy(dp) &&
				    !uevent_get(sd, "PARTNAME", pn, sizeof(pn)) &&
				    !strcmp(pn, "persist"))
					continue;
				mknod_from(sd, dp, c[k].blk);
			}
		closedir(d);
	}
	mknod_from("/sys/class/misc/device-mapper", "/dev/mapper/control", 0);
}

static int wait_node(const char *path)
{
	int i;

	for (i = 0; i < 200; i++) {
		ensure_nodes();
		if (access(path, F_OK) == 0)
			return 0;
		usleep(10000);
	}
	return -1;
}

/* Attaches path to /dev/loop<n> with partition scanning; returns the partition count. */
static int attach_loop(int n, const char *path)
{
	struct loop_info64 li = { 0 };
	char dev[32], part[40];
	int fd, lfd, i, rc;

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -1;
	snprintf(dev, sizeof(dev), "/dev/loop%d", n);
	lfd = open(dev, O_RDWR | O_CLOEXEC);
	if (lfd < 0) {
		close(fd);
		return -1;
	}
	rc = ioctl(lfd, LOOP_SET_FD, fd);
	if (rc == 0) {
		li.lo_flags = LO_FLAGS_PARTSCAN;
		rc = ioctl(lfd, LOOP_SET_STATUS64, &li);
	}
	close(lfd);
	close(fd);
	if (rc)
		return -1;
	snprintf(part, sizeof(part), "/dev/loop%dp1", n);
	wait_node(part);
	for (i = 1; i < 64; i++) {
		snprintf(part, sizeof(part), "/dev/loop%dp%d", n, i);
		if (access(part, F_OK))
			break;
	}
	return i - 1;
}

static int setup_decoy_loop(void)
{
	uint8_t *img = calloc(DECOY_SECTORS, 512);
	struct loop_info64 li = { 0 };
	char dev[32], part[40];
	int fd, lfd, i, rc = -1;

	if (!img)
		return -1;
	make_gpt(img, DECOY_SECTORS, decoy_parts, N_DECOY_PARTS);
	for (i = 0; i < N_DECOY_PARTS; i++)		/* a recognisable fill */
		memset(img + decoy_parts[i].first * 512 + BS, 0x11 * (i + 1),
		       (decoy_parts[i].last - decoy_parts[i].first + 1) * 512 - BS);
	make_swap_header(img + decoy_parts[1].first * 512,
			 (decoy_parts[1].last - decoy_parts[1].first + 1) * 512);
	fd = open(DECOY_IMG, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0 || write(fd, img, DECOY_SECTORS * 512) != (ssize_t)(DECOY_SECTORS * 512))
		goto out;
	snprintf(dev, sizeof(dev), "/dev/loop%d", DECOY_LOOP);
	lfd = open(dev, O_RDWR | O_CLOEXEC);
	if (lfd < 0)
		goto out;
	if (ioctl(lfd, LOOP_SET_FD, fd) == 0) {
		li.lo_flags = LO_FLAGS_PARTSCAN;
		snprintf((char *)li.lo_file_name, sizeof(li.lo_file_name), "%s", DECOY_IMG);
		rc = ioctl(lfd, LOOP_SET_STATUS64, &li);
	}
	close(lfd);
	for (i = 1; rc == 0 && i <= N_DECOY_PARTS; i++) {
		snprintf(part, sizeof(part), "/dev/loop%dp%d", DECOY_LOOP, i);
		rc = wait_node(part);
	}
out:
	if (fd >= 0)
		close(fd);
	free(img);
	return rc;
}

static int write_image(const char *path, int with_gpt)
{
	uint8_t *img = calloc(DECOY_SECTORS, 512);
	int fd, rc = -1;

	if (!img)
		return -1;
	if (with_gpt)
		make_gpt(img, DECOY_SECTORS, decoy_parts, N_DECOY_PARTS);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd >= 0 && write(fd, img, DECOY_SECTORS * 512) == (ssize_t)(DECOY_SECTORS * 512))
		rc = 0;
	if (fd >= 0)
		close(fd);
	free(img);
	return rc;
}

/* S5 (protect mode): boot storage stays boot storage after its partitions vanish. */
static int fn_sticky_reattach(void *arg)
{
	int lf, bf, fd, i;

	(void)arg;
	lf = open("/dev/loop4", O_RDONLY | O_CLOEXEC);	/* loop ioctls need no write mode */
	if (lf < 0 || ioctl(lf, LOOP_CLR_FD, 0)) {
		if (lf >= 0)
			close(lf);
		return -ECANCELED;
	}
	close(lf);
	for (i = 0; i < 200 && access("/dev/loop4p1", F_OK) == 0; i++)
		usleep(10000);
	bf = open(WORKDIR "/blank.img", O_RDWR | O_CLOEXEC);
	lf = open("/dev/loop4", O_RDONLY | O_CLOEXEC);
	if (bf < 0 || lf < 0 || ioctl(lf, LOOP_SET_FD, bf)) {
		if (bf >= 0)
			close(bf);
		if (lf >= 0)
			close(lf);
		return -ECANCELED;	/* setup failed: not the expected refusal */
	}
	close(bf);
	close(lf);
	/* loop4 now has no partitions at all; a write open must still be refused */
	fd = open("/dev/loop4", O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -errno;
	close(fd);
	return 0;
}

/* A decoy write target must be RAM-backed: brd ramN, our loop on tmpfs, our dm. */
/* The node /dev/<name> must be the device the kernel calls <name> (st_rdev = its sysfs dev). */
static int node_is(const char *dev, const char *name)
{
	char p[160], b[32];
	unsigned int ma, mi;
	struct stat st;

	snprintf(p, sizeof(p), "/sys/class/block/%s/dev", name);
	if (read_text(p, b, sizeof(b)) <= 0 || sscanf(b, "%u:%u", &ma, &mi) != 2)
		return 0;
	return stat(dev, &st) == 0 && S_ISBLK(st.st_mode) && st.st_rdev == makedev(ma, mi);
}

static int ram_backed(const char *dev)
{
	char b[256], p[128], name[64];
	const char *n = strrchr(dev, '/') ? strrchr(dev, '/') + 1 : dev;
	int k;

	snprintf(name, sizeof(name), "%s", n);
	if (!node_is(dev, name))
		return 0;			/* the node is not the device of that name */
	if (sscanf(n, "ram%d", &k) == 1)
		return 1;
	if (sscanf(n, "dm-%d", &k) == 1)
		return k == DM_MINOR_RW || k == DM_MINOR_RO || k == DM_MINOR_NEW;
	if (sscanf(n, "loop%d", &k) == 1) {
		const char *want = k == DECOY_LOOP ? DECOY_IMG : k == STACK_LOOP ? "/dev/ram1" :
				   k == 4 ? WORKDIR "/" : NULL;
		char disk[16];

		if (!want)
			return 0;
		snprintf(disk, sizeof(disk), "loop%d", k);	/* partitions: the disk's backing file */
		snprintf(p, sizeof(p), "/sys/block/%s/loop/backing_file", disk);
		return read_text(p, b, sizeof(b)) > 0 && !strncmp(b, want, strlen(want));
	}
	return 0;
}

/* ------------------------------------------------------------ the phases */

#define EMPTY_SHA256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
static struct sha hd_before, hd_after;	/* digests of every accepted row, before and after */

struct hashrec {
	char dev[64]; char h[65]; uint64_t cap, range, got; int limit;
	const char *expect;	/* known SHA-256 (readback R1-R5), or NULL */
};
static struct hashrec hashes[512];
static int n_hashes;

/*
 * Fail-closed acceptance (PROPOSAL.md §5.1): the row passes only if the read completed
 * within its bound, hashed exactly the bytes the row requires, is not the empty-input
 * hash, and (R1-R5) equals the expected value.  Returns 0 or -1 (STOP).
 */
static int hash_row(const char *tag, struct hashrec *h, int after)
{
	struct hres r;
	int rc;
	const char *why = NULL;

	memset(&r, 0, sizeof(r));
	if (!content_read_allowed(h->dev)) {	/* FS-R-014 s.3.1: refused before any open */
		rc = -EACCES;
		why = "not on the content-read allowlist: never opened";
	} else
		rc = hash_node(h->dev, h->cap, h->range, h->limit, &r);
	if (rc == -ETIMEDOUT)
		row_timeouts++;
	if (why)
		;
	else if (rc)
		why = rc == -ETIMEDOUT ? "timeout" :
		      rc == -ERANGE ? "the read rounded to 4096 bytes would pass the end of the node" : strerror(-rc);
	else if (r.got != r.want || !r.got)
		why = "short read";
	else if (!strcmp(r.hex, EMPTY_SHA256))
		why = "empty-input hash";
	else if (h->expect && strcmp(r.hex, h->expect))
		why = "content differs from the expected v2.7 image";
	else if (after && strcmp(r.hex, h->h))
		why = "CHANGED";
	sayq(h->expect != NULL, !why, after ? "H'" : "H",
	     "ROW %-3s %-22s bytes=%llu/%llu sha256=%.16s%s -> %s\n", tag, h->dev,
	     (unsigned long long)r.got, (unsigned long long)r.want, r.hex,
	     h->expect ? " (expected value)" : "", why ? why : "PASS");
	if (why)
		return -1;
	{
		char line[160];

		snprintf(line, sizeof(line), "%s %llu %s\n", h->dev, (unsigned long long)r.got, r.hex);
		sha_upd(after ? &hd_after : &hd_before, line, strlen(line));
	}
	if (!after) {
		memcpy(h->h, r.hex, sizeof(h->h));
		h->got = r.got;
	}
	return 0;
}

static int hash_fail;		/* failed (or not read) before-pass rows: the first one stops all further reads */
static int rows_not_read;	/* of those, the rows not read because an earlier row had failed */

/* Adds and runs a "before" row; a failure is returned so the caller can stop. */
static int hash_add_x(const char *dev, uint64_t cap, uint64_t range, const char *expect)
{
	struct hashrec *h;

	if (n_hashes >= 512)
		return -1;
	h = &hashes[n_hashes];
	memset(h, 0, sizeof(*h));
	snprintf(h->dev, sizeof(h->dev), "%s", dev);
	h->cap = cap;
	h->range = range;
	h->expect = expect;
	h->limit = row_limit(0);		/* the time left in the before-pass, at most 10 s (VM: 60 s) */
	/* FS-R-014 s.3.2: after the first failed row (a read error, short read, mismatch, refused open or time
	 * bound) no further row is read: nothing more is opened, the partial result is kept */
	if (row_timeouts || hash_fail) {
		sayq(0, 0, "H", "ROW H   %-22s -> not read (%s)\n", h->dev,
		     row_timeouts ? "an earlier row hit its time bound" : "stopped after an earlier failure");
		rows_not_read++;
		return -1;
	}
	if (hash_row("H", h, 0))
		return -1;
	n_hashes++;
	return 0;
}

static void hash_add(const char *dev, uint64_t cap)
{
	if (hash_add_x(dev, cap, 0, NULL))
		hash_fail++;
}

/* The after-pass. Returns the rows that failed for a reason other than time; rows that hit their time
 * bound (and the rows left unread after one) are counted in *timed, not as a changed range. */
static int hash_verify(int *timed)
{
	int i, bad = 0, skipped = 0, out_of_time = 0;

	row_timeouts = 0;
	for (i = 0; i < n_hashes; i++) {
		/* FS-R-014 s.3.2: after the first failed after-row (CHANGED, a read error, a short read or a time
		 * bound) no further row is read; the failure is classified as it is (CHANGED/read error: FAIL) */
		if (row_timeouts || out_of_time || bad) {
			skipped++;
			continue;
		}
		/* on the unit no after-row starts with less than 1 s left before AFTER_END, so a row's bound
		 * (at most the time left) plus its 5 s KILL always ends before fs-supervise's TERM at 25 s */
		if (!platform_is_vm() && AFTER_END - (now_s() - t_start) < 1.0) {
			out_of_time = 1;
			skipped++;
			continue;
		}
		hashes[i].limit = row_limit(1);	/* the time left until AFTER_END, at most 10 s (VM: 60 s) */
		if (hash_row("H'", &hashes[i], 1) && !row_timeouts)
			bad++;
	}
	*timed = bad ? 0 : row_timeouts + skipped;
	if (skipped)
		say("SKIP  H'    %d row(s) not read: %s\n", skipped,
		    bad ? "stopped after an earlier failure" :
		    row_timeouts ? "a row hit its time bound" : "less than 1 s left before the after-pass end");
	say("HASH verify: %d nodes, %d failed or changed\n", n_hashes, bad);
	return bad;
}

static void spec(struct case_spec *c, const char *id, const char *t, int path,
		 unsigned int errs, int mind, int maxd, int drop, int prot)
{
	c->id = id; c->target = t; c->path = path; c->errs = errs;
	c->min_d = mind; c->max_d = maxd; c->drop = drop; c->protected = prot;
}

/* N-series: refusals on a decoy node with full capabilities. */
static void decoy_node_cases(const char *dev, int whole, int swap)
{
	struct case_spec c;
	struct op o = { .dev = dev, .fd = -1 };

	if (!vm_mode && !ram_backed(dev)) {
		say("ABORT: %s is not RAM-backed; refusing to use it as a decoy\n", dev);
		late_abort = stop_all = 1;
		return;
	}
	o.flags = O_RDWR;
	spec(&c, "N1", dev, P_OPEN, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_open, &o);
	o.flags = O_WRONLY;
	spec(&c, "N2", dev, P_OPEN, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_open, &o);
	o.flags = O_RDONLY; o.req = BLKDISCARD; o.arg = BS;
	spec(&c, "N3", dev, P_DISCARD, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_range_ioctl, &o);
	o.req = BLKSECDISCARD;
	spec(&c, "N4", dev, P_DISCARD, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_range_ioctl, &o);
	o.req = BLKZEROOUT;
	spec(&c, "N5", dev, P_ZEROOUT, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_range_ioctl, &o);
	o.req = BLKROSET; o.arg = 0;
	spec(&c, "N6", dev, P_ROSET, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_int_ioctl, &o);
	if (whole) {
		o.arg = BLKPG_DEL_PARTITION;
		spec(&c, "N7", dev, P_BLKPG, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_blkpg, &o);
		o.arg = BLKPG_ADD_PARTITION;
		spec(&c, "N8", dev, P_BLKPG, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_blkpg, &o);
		o.arg = BLKPG_RESIZE_PARTITION;
		spec(&c, "N9", dev, P_BLKPG, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_blkpg, &o);
		o.req = BLKRRPART;
		spec(&c, "N10", dev, P_RRPART, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_noarg_ioctl, &o);
	}
	if (swap) {
		spec(&c, "N11", dev, P_OPEN, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_swapon, &o);
	}
}

/* P-series: writes through descriptors opened before arming. */
static void prearmed_cases(const char *dev, int fd, int fd_direct)
{
	struct case_spec c;
	struct op o = { .dev = dev, .fd = fd };

	spec(&c, "P1", dev, P_WRITE, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_write, &o);
	spec(&c, "P2", dev, P_WRITE, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_writev, &o);
	o.fd = fd_direct;
	spec(&c, "P3", dev, P_WRITE, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_write, &o);
	spec(&c, "P4", dev, P_WRITE, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_aio, &o);
	o.fd = fd;
	spec(&c, "P5", dev, P_WRITE, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sendfile, &o);
	/* copy_file_range(2) refuses non-regular files itself (EINVAL): not a path */
	o.arg = FALLOC_FL_ZERO_RANGE;
	spec(&c, "P7", dev, P_FALLOC, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_falloc, &o);
	o.arg = FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE;
	spec(&c, "P8", dev, P_FALLOC, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_falloc, &o);
	o.req = BLKDISCARD; o.arg = BS;
	spec(&c, "P9", dev, P_DISCARD, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_range_ioctl, &o);
	o.req = BLKZEROOUT;
	spec(&c, "P10", dev, P_ZEROOUT, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_range_ioctl, &o);
	/* mmap writeback: refused at the bio layer (EIO), possibly several bios */
	spec(&c, "P11", dev, P_BIO, EXP_EIO, 1, 64, 0, 0); run_case(&c, fn_mmap, &o);
}

static const uint8_t cdb_write10_1[10] = { 0x2a, 0, 0, 0, 0x08, 0, 0, 0, 1, 0 };	/* LBA 2048, 1 blk */
static const uint8_t cdb_write10_0[10] = { 0x2a, 0, 0, 0, 0x08, 0, 0, 0, 0, 0 };	/* 0 blocks */
static const uint8_t cdb_write6_1[6]   = { 0x0a, 0, 0x08, 0, 1, 0 };
static const uint8_t cdb_sync10[10]    = { 0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
static const uint8_t cdb_unmap[10]     = { 0x42, 0, 0, 0, 0, 0, 0, 0, 24, 0 };
static const uint8_t cdb_wsame16[16]   = { 0x93, 0x08, 0,0,0,0,0,0,0x08,0, 0,0,0,8, 0,0 };
static const uint8_t cdb_secout[12]    = { 0xb5, 0xec, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
static const uint8_t cdb_wbuf[10]      = { 0x3b, 0x05, 0, 0, 0, 0, 0, 0x10, 0, 0 };
static const uint8_t cdb_modesel6[6]   = { 0x15, 0x10, 0, 0, 0, 0 };
static const uint8_t cdb_format[6]     = { 0x04, 0, 0, 0, 0, 0 };
static const uint8_t cdb_inquiry[6]    = { 0x12, 0, 0, 0, 96, 0 };
static const uint8_t cdb_rcap16[16]    = { 0x9e, 0x10, 0,0,0,0,0,0,0,0, 0,0,0,32, 0,0 };

/* C-series (vm mode): real data-carrying pass-through writes to a SCSI decoy. */
static void scsi_decoy_cases(const char *sd, const char *sg, const char *bsg)
{
	struct case_spec c;
	/* O_RDONLY: an O_RDWR open of the decoy is itself refused (open), and root with
	 * CAP_SYS_RAWIO may send any command on a read-only fd without the guard. */
	struct op o = { .dev = sd, .fd = -1, .flags = O_RDONLY };

	o.cdb = cdb_write10_1; o.cdb_len = 10; o.data_len = 512; o.dir = SG_DXFER_TO_DEV;
	spec(&c, "C1", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &o);
	spec(&c, "C2", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sendcmd, &o);
	o.cdb = cdb_unmap; o.data_len = 24;
	spec(&c, "C3", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &o);
	o.cdb = cdb_wsame16; o.cdb_len = 16; o.data_len = 512;
	spec(&c, "C4", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &o);
	o.cdb = cdb_secout; o.cdb_len = 12; o.data_len = 0; o.dir = SG_DXFER_NONE;
	spec(&c, "C5", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &o);
	o.cdb = cdb_wbuf; o.cdb_len = 10;
	spec(&c, "C6", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &o);
	o.cdb = cdb_modesel6; o.cdb_len = 6;
	spec(&c, "C7", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &o);
	o.cdb = cdb_format;
	spec(&c, "C8", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &o);
	o.cdb = cdb_sync10; o.cdb_len = 10;
	spec(&c, "C9", sd, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &o);
	{
		static int reset_dev = SG_SCSI_RESET_DEVICE;
		static struct pr_registration reg = { .old_key = 0, .new_key = 0x46534247 };
		static uint8_t q[16] = { 0x03, 0, 0, 0, 0x00, 0, 0x04, 0 };	/* opcode 3, idn 0, buf_size 4 */	/* read attr bBootLunEn */

		o.req = SCSI_IOCTL_STOP_UNIT; o.argp = NULL;
		spec(&c, "C13", sd, P_SCSI_IOCTL, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_ptr_ioctl, &o);
		o.req = SCSI_IOCTL_START_UNIT;
		spec(&c, "C14", sd, P_SCSI_IOCTL, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_ptr_ioctl, &o);
		o.req = SG_SCSI_RESET; o.argp = &reset_dev;
		spec(&c, "C15", sd, P_SCSI_IOCTL, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_ptr_ioctl, &o);
		o.req = UFS_IOCTL_QUERY; o.argp = q;	/* reaches the host driver's ioctl */
		if (host_has_ioctl(sd)) {
			spec(&c, "C16", sd, P_SCSI_IOCTL, EXP_REFUSE, 1, 1, 0, 0);
			run_case(&c, fn_ptr_ioctl, &o);
		} else {
			say("SKIP  C16   %-22s the SCSI host has no driver ioctl\n", sd);
		}
		o.req = IOC_PR_REGISTER; o.argp = &reg;
		spec(&c, "C17", sd, P_PR, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_ptr_ioctl, &o);
	}
	if (sg) {
		struct op s = { .dev = sg, .fd = -1, .flags = O_RDWR, .cdb = cdb_write10_1,
				.cdb_len = 10, .data_len = 512, .dir = SG_DXFER_TO_DEV };

		spec(&c, "C10", sg, P_SG, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgio, &s);
		s.cdb = cdb_write6_1; s.cdb_len = 6;
		spec(&c, "C11", sg, P_SG, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_sgwrite, &s);
		{
			static int reset_dev = SG_SCSI_RESET_DEVICE;

			s.req = SG_SCSI_RESET; s.argp = &reset_dev;
			spec(&c, "C18", sg, P_SCSI_IOCTL, EXP_REFUSE, 1, 1, 0, 0);
			run_case(&c, fn_ptr_ioctl, &s);
		}
	}
	if (bsg) {
		struct op b = { .dev = bsg, .fd = -1, .flags = O_RDWR, .cdb = cdb_write10_1,
				.cdb_len = 10, .data_len = 512, .dir = SG_DXFER_TO_DEV };

		spec(&c, "C12", bsg, P_SCSI, EXP_REFUSE, 1, 1, 0, 0); run_case(&c, fn_bsg, &b);
	}
}

/* Q-series: real boot storage, write-incapable variants only. */
static void protected_node_cases(const char *dev, int whole, int is_sd)
{
	struct case_spec c;
	struct op o = { .dev = dev, .fd = -1, .flags = O_RDONLY };

	o.req = BLKDISCARD; o.arg = 0;		/* EBADF without the guard */
	spec(&c, "Q1", dev, P_DISCARD, EXP_REFUSE, 1, 1, 0, 1); run_case(&c, fn_range_ioctl, &o);
	o.req = BLKZEROOUT;
	spec(&c, "Q2", dev, P_ZEROOUT, EXP_REFUSE, 1, 1, 0, 1); run_case(&c, fn_range_ioctl, &o);
	o.req = BLKROSET; o.arg = 0;		/* EACCES without the guard */
	spec(&c, "Q3", dev, P_ROSET, EXP_REFUSE, 1, 1, DROP_ADMIN, 1); run_case(&c, fn_int_ioctl, &o);
	if (whole) {
		o.arg = BLKPG_DEL_PARTITION;	/* pno 250 does not exist */
		spec(&c, "Q4", dev, P_BLKPG, EXP_REFUSE, 1, 1, DROP_ADMIN, 1); run_case(&c, fn_blkpg, &o);
		o.req = BLKRRPART;
		spec(&c, "Q5", dev, P_RRPART, EXP_REFUSE, 1, 1, DROP_ADMIN, 1); run_case(&c, fn_noarg_ioctl, &o);
	}
	if (whole && is_sd) {
		/* Q12: the ufs-qcom host ioctl, as a READ query (bBootLunEn): reads even unguarded */
		static uint8_t q[16] = { 0x03, 0, 0, 0, 0x00, 0, 0x04, 0 };	/* opcode 3, idn 0, buf_size 4 */
		/* Q13: PR register with CAP_SYS_ADMIN dropped: refused by the kernel unguarded */
		static struct pr_registration reg = { .old_key = 0, .new_key = 0x46534247 };
		/* Q14: SG_SCSI_RESET_NOTHING (a no-op) with admin+rawio dropped: EACCES unguarded */
		static int reset_nothing = SG_SCSI_RESET_NOTHING;
		struct op io = { .dev = dev, .fd = -1, .flags = O_RDONLY };

		io.req = UFS_IOCTL_QUERY; io.argp = q;
		/* on the Quest (no fsbg.testkernel) Q12 always runs: the UFS host has the ioctl */
		if ((!test_kernel && !device_sim) || host_has_ioctl(dev)) {
			spec(&c, "Q12", dev, P_SCSI_IOCTL, EXP_REFUSE, 1, 1, 0, 1);
			run_case(&c, fn_ptr_ioctl, &io);
		} else {
			say("SKIP  Q12   %-22s the SCSI host has no driver ioctl\n", dev);
		}
		io.req = IOC_PR_REGISTER; io.argp = &reg;
		spec(&c, "Q13", dev, P_PR, EXP_REFUSE, 1, 1, DROP_ADMIN, 1); run_case(&c, fn_ptr_ioctl, &io);
		io.req = SG_SCSI_RESET; io.argp = &reset_nothing;
		spec(&c, "Q14", dev, P_SCSI_IOCTL, EXP_REFUSE, 1, 1, DROP_ADMIN | DROP_RAWIO, 1);
		run_case(&c, fn_ptr_ioctl, &io);
	}
	if (whole && is_sd) {			/* kernel filter refuses WRITE on RDONLY without RAWIO */
		o.cdb = cdb_write10_0; o.cdb_len = 10; o.data_len = 0; o.dir = SG_DXFER_NONE;
		spec(&c, "Q6", dev, P_SCSI, E(EPERM), 1, 1, DROP_RAWIO, 1); run_case(&c, fn_sgio, &o);
		o.cdb = cdb_sync10;
		spec(&c, "Q7", dev, P_SCSI, E(EPERM), 1, 1, DROP_RAWIO, 1); run_case(&c, fn_sgio, &o);
	}
}

/* UFS query: READ DESCRIPTOR (device descriptor), a 36-byte struct ufs_bsg_request; read-only even if sent */
static const uint8_t upiu_query[36] = {
	0x16, 0, 0, 0,				/* msgcode: UPIU_TRANSACTION_QUERY_REQ (little-endian u32) */
	0x16, 0, 0, 0,				/* header dword 0: transaction type QUERY_REQ */
	0, 0x01, 0, 0,				/* header dword 1: query function 0x01 (standard READ) */
	0, 0, 0, 0,				/* header dword 2 */
	0x01, 0x00, 0x00, 0x00,			/* query: opcode READ_DESC, idn DEVICE, index, selector */
	0, 0, 0x00, 0x40,			/* reserved_osf (be16), length 0x40 (be16) */
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };	/* value, reserved */

static void protected_passthru_cases(const char *node, int kind)
{
	struct case_spec c;
	struct op o = { .dev = node, .fd = -1, .flags = O_RDONLY, .cdb = cdb_write10_0,
			.cdb_len = 10, .data_len = 0, .dir = SG_DXFER_NONE };

	if (kind == 0) {		/* /dev/sgN */
		spec(&c, "Q8", node, P_SG, E(EPERM), 1, 1, DROP_RAWIO, 1); run_case(&c, fn_sgio, &o);
	} else if (kind == 1) {		/* /dev/bsg/H:C:T:L */
		spec(&c, "Q9", node, P_SCSI, E(EPERM), 1, 1, DROP_RAWIO, 1); run_case(&c, fn_bsg, &o);
	} else {			/* transport bsg (ufs-bsg) */
		o.req = 1; o.cdb = upiu_query; o.cdb_len = sizeof(upiu_query);
		spec(&c, "Q10", node, P_BSG, E(EPERM), 1, 1, DROP_RAWIO, 1); run_case(&c, fn_bsg, &o);
	}
}

static void protected_open_case(const char *dev)
{
	struct case_spec c;
	struct op o = { .dev = dev, .fd = -1, .flags = O_RDWR };

	spec(&c, "Q11", dev, P_OPEN, EXP_REFUSE, 1, 1, 0, 1); run_case(&c, fn_open, &o);
}

static int fn_rw_ok(void *arg)
{
	struct op *o = arg;
	void *b, *r;
	int fd, rc = 0;

	if (posix_memalign(&b, BS, BS) || posix_memalign(&r, BS, BS))
		return -ENOMEM;
	memset(b, 0xc3, BS);
	fd = open(o->dev, O_RDWR | O_DIRECT | O_CLOEXEC);
	if (fd < 0)
		rc = -errno;
	else if (pwrite(fd, b, BS, BS) != BS || pread(fd, r, BS, BS) != BS)
		rc = -errno ? -errno : -EIO;
	else if (memcmp(b, r, BS))
		rc = -EBADMSG;
	if (fd >= 0)
		close(fd);
	free(b);
	free(r);
	return rc;
}

static int fn_inquiry_ok(void *arg)
{
	struct op *o = arg;

	o->cdb = cdb_inquiry; o->cdb_len = 6; o->data_len = 96; o->dir = SG_DXFER_FROM_DEV;
	return with_fd(o, f_sgio);
}

static int fn_rcap16_ok(void *arg)
{
	struct op *o = arg;

	o->cdb = cdb_rcap16; o->cdb_len = 16; o->data_len = 32; o->dir = SG_DXFER_FROM_DEV;
	return with_fd(o, f_sgio);
}

static int fn_write_direct(void *arg)
{
	struct op *o = arg;
	void *b;
	int fd, rc;

	if (posix_memalign(&b, BS, BS))
		return -ENOMEM;
	memset(b, 0x3c, BS);
	fd = open(o->dev, O_RDWR | O_DIRECT | O_CLOEXEC);
	if (fd < 0) {
		free(b);
		return -errno;
	}
	rc = pwrite(fd, b, BS, 0) == BS ? 0 : -errno;
	close(fd);
	free(b);
	return rc;
}

static int fn_roset_then_write(void *arg)
{
	struct op *o = arg;
	int fd = open(o->dev, O_RDONLY | O_CLOEXEC), v = 0;

	if (fd < 0)
		return -errno;
	if (ioctl(fd, BLKROSET, &v)) {
		close(fd);
		return -ECANCELED;	/* setup failed: not the expected EIO */
	}
	close(fd);
	return fn_write_direct(arg);
}

/* ------------------------------------------------------- discovery */

struct node { char dev[48]; char partname[64]; int whole; int is_sd; };
static struct node nodes[256];
static int n_nodes;

static int uevent_get(const char *sysdir, const char *key, char *out, size_t n)
{
	char path[256], b[1024], *p;

	snprintf(path, sizeof(path), "%s/uevent", sysdir);
	if (read_text(path, b, sizeof(b)) <= 0)
		return -1;
	snprintf(path, sizeof(path), "%s=", key);
	for (p = b; p && *p; p = strchr(p, '\n') ? strchr(p, '\n') + 1 : NULL)
		if (!strncmp(p, path, strlen(path))) {
			char *e = strchr(p, '\n');

			snprintf(out, n, "%.*s", (int)((e ? e : p + strlen(p)) - p - strlen(path)),
				 p + strlen(path));
			return 0;
		}
	return -1;
}

/* True if the whole-disk node /dev/X has at least one partition (/sys/block/X/X*). */
static int disk_has_parts(const char *dev)
{
	const char *n = strrchr(dev, '/') ? strrchr(dev, '/') + 1 : dev;
	char p[128];
	DIR *d;
	struct dirent *e;
	int r = 0;

	snprintf(p, sizeof(p), "/sys/block/%s", n);
	d = opendir(p);
	if (!d)
		return 0;
	while ((e = readdir(d)))
		if (!strncmp(e->d_name, n, strlen(n)) && strlen(e->d_name) > strlen(n))
			r = 1;
	closedir(d);
	return r;
}

/* Real storage nodes: everything in /sys/class/block except ram/loop/dm/zram. */
/* The kernel's partition name of the device the node at path refers to (st_rdev = the sysfs device of the
 * node's own name); 0 on success. */
static int node_is(const char *dev, const char *name);
static int partname_of(const char *path, char *out, size_t n)
{
	const char *bn = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
	char sys[300];

	if (partname_hook)
		return partname_hook(path, out, n);
	out[0] = '\0';
	if (!node_is(path, bn))
		return -1;
	snprintf(sys, sizeof(sys), "/sys/class/block/%s", bn);
	if (uevent_get(sys, "PARTNAME", out, n) || !out[0])
		return -1;
	return 0;
}

/* FS-R-014 s.3.1: a real node the probe never opens for anything (rows, test cases): persist. Fails closed: a
 * partition is re-identified at the moment of use by the kernel's name of the device its node refers to (not the
 * name cached at discovery); a partition that cannot be identified is not opened either. A whole LUN is never the
 * persist partition (it is a Q target like the others; no content is read from it). */
static int node_open_allowed(const struct node *nd)
{
	char pn[64];

	if (vm_mode && !partname_hook)
		return 1;
	if (nd->whole)
		return 1;
	if (!strcmp(nd->partname, "persist") || partname_of(nd->dev, pn, sizeof(pn)))
		return 0;
	return strcmp(pn, "persist") != 0;
}

static void discover(void)
{
	DIR *d = opendir("/sys/class/block");
	struct dirent *e;

	n_nodes = 0;
	if (!d)
		return;
	while ((e = readdir(d)) && n_nodes < 256) {
		char sys[300], type[32] = "";
		struct node *nd = &nodes[n_nodes];

		if (e->d_name[0] == '.' || !strncmp(e->d_name, "ram", 3) ||
		    !strncmp(e->d_name, "loop", 4) || !strncmp(e->d_name, "dm-", 3) ||
		    !strncmp(e->d_name, "zram", 4))
			continue;
		snprintf(sys, sizeof(sys), "/sys/class/block/%s", e->d_name);
		uevent_get(sys, "DEVTYPE", type, sizeof(type));
		nd->whole = !strcmp(type, "disk");
		nd->partname[0] = '\0';
		uevent_get(sys, "PARTNAME", nd->partname, sizeof(nd->partname));
		snprintf(nd->dev, sizeof(nd->dev), "/dev/%s", e->d_name);
		nd->is_sd = !strncmp(e->d_name, "sd", 2);
		n_nodes++;
	}
	closedir(d);
}

static void find_class_nodes(const char *cls, const char *prefix, char out[][48], int *n, int max)
{
	DIR *d = opendir(cls);
	struct dirent *e;

	*n = 0;
	if (!d)
		return;
	while ((e = readdir(d)) && *n < max)
		if (e->d_name[0] != '.' && (!prefix || !strncmp(e->d_name, prefix, strlen(prefix))))
			snprintf(out[(*n)++], 48, "%s%s", strstr(cls, "bsg") ? "/dev/bsg/" : "/dev/",
				 e->d_name);
	closedir(d);
}

/* ---------------------------------------------------------------- main */

static void pid1_setup(void)
{
	mkdir("/proc", 0755); mkdir("/sys", 0755); mkdir("/dev", 0755); mkdir("/run", 0755);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	{
		char cl[4096];

		/* fsbg.tmpfsdev (VM test of the K1g PID 1 layout): /dev is a tmpfs, no devtmpfs */
		if (read_text("/proc/cmdline", cl, sizeof(cl)) > 0 && strstr(cl, "fsbg.tmpfsdev"))
			mount("tmpfs", "/dev", "tmpfs", 0, "mode=0755,size=4m");
		else
			mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	}
	{
		char cl[4096];

		/* fsbg.tmpfsdev: also /run at init.sh's size (32 MiB), so a too-large decoy shows in the VM */
		if (read_text("/proc/cmdline", cl, sizeof(cl)) > 0 && strstr(cl, "fsbg.tmpfsdev"))
			mount("tmpfs", "/run", "tmpfs", 0, "mode=0755,size=32m");
		else
			mount("tmpfs", "/run", "tmpfs", 0, "size=64m");
	}
}

/*
 * Platform identity (FS-A-014 review: every VM-only flag is refused on real hardware, by a POSITIVE check).
 * The decisions are pure functions of the identity texts so that they can be unit-tested
 * (tools/blkguard/probe/test/test-identity.c); platform_is_vm()/platform_is_quest() read the live texts.
 *   compat : the device tree's root "compatible" (a NUL-separated list; n bytes)
 *   model  : the device tree's root "model" (may be empty)
 *   cmdline: /proc/cmdline
 *   cpuinfo: /proc/cpuinfo
 */
static int has_ci(const char *h, const char *needle)	/* case-insensitive substring */
{
	size_t k = strlen(needle);

	for (; h && *h; h++)
		if (!strncasecmp(h, needle, k))
			return 1;
	return 0;
}

/* A Quest 3 (or any Qualcomm/Meta/Oculus platform): positively identified by the device tree's compatible or
 * model, or by the stock DTB boot arguments seen on the Quest's command line ([M] on v2.7: qcom_dload_mode,
 * msm_drm.dsi_display0=meta). Any one of them is enough. */
static int ident_is_quest(const char *compat, int n, const char *model, const char *cmdline)
{
	static const char *const dt[] = { "qcom", "oculus", "meta", "anorak", "eureka" };
	static const char *const cl[] = { "qcom_dload_mode", "msm_drm.dsi_display0=meta", "androidboot.hardware=eureka",
					   "msm_rtb.", "service_locator.enable" };
	size_t i;

	for (i = 0; i < sizeof(dt) / sizeof(dt[0]); i++)
		if ((n > 0 && memmem(compat, n, dt[i], strlen(dt[i]))) || has_ci(model, dt[i]))
			return 1;
	if (has_ci(model, "quest") || has_ci(model, "qualcomm"))
		return 1;
	for (i = 0; i < sizeof(cl) / sizeof(cl[0]); i++)
		if (cmdline && strstr(cmdline, cl[i]))
			return 1;
	return 0;
}

/* A test VM: positively identified as QEMU "virt" (compatible linux,dummy-virt) or User-Mode Linux, and NOT a
 * Quest by any of the texts above. */
static int ident_is_vm(const char *compat, int n, const char *model, const char *cmdline, const char *cpuinfo)
{
	if (ident_is_quest(compat, n, model, cmdline))
		return 0;
	if (n > 0)
		return memmem(compat, n, "linux,dummy-virt", 16) != NULL;
	return cpuinfo && strstr(cpuinfo, "User Mode Linux") != NULL;
}

struct ident { char compat[4096], model[256], cmdline[4096], cpuinfo[4096]; int n; };

static void ident_read(struct ident *id)
{
	memset(id, 0, sizeof(*id));
	id->n = read_text("/proc/device-tree/compatible", id->compat, sizeof(id->compat));
	if (id->n <= 0)
		id->n = read_text("/sys/firmware/devicetree/base/compatible", id->compat, sizeof(id->compat));
	if (read_text("/proc/device-tree/model", id->model, sizeof(id->model)) <= 0)
		read_text("/sys/firmware/devicetree/base/model", id->model, sizeof(id->model));
	read_text("/proc/cmdline", id->cmdline, sizeof(id->cmdline));
	read_text("/proc/cpuinfo", id->cpuinfo, sizeof(id->cpuinfo));
}

static int platform_is_quest(void)	/* read once; the identity does not change while the probe runs */
{
	static struct ident id;
	static int cached = -1;

	if (cached < 0) {
		ident_read(&id);
		cached = ident_is_quest(id.compat, id.n, id.model, id.cmdline);
	}
	return cached;
}

static int platform_is_vm(void)
{
	static struct ident id;
	static int cached = -1;

	if (cached < 0) {
		ident_read(&id);
		cached = ident_is_vm(id.compat, id.n, id.model, id.cmdline, id.cpuinfo);
	}
	return cached;
}

/* The flag gate: returns NULL when the requested modes are allowed here, else the reason. The device run uses
 * none of them (init.sh: --compact --nonce only, and the probe is not PID 1 there, so no kernel-command-line flag
 * is even read); any of them on a Quest, or on anything not positively a test VM, is refused. */
static const char *vm_flag_gate(int any_vm_flag, int is_vm, int is_quest)
{
	if (!any_vm_flag)
		return NULL;
	if (is_quest)
		return "this platform identifies as a Quest/Qualcomm device (device tree or boot arguments)";
	if (!is_vm)
		return "this platform is not positively a QEMU virt or UML test machine";
	return NULL;
}

static int finish(int code)
{
	if (compact && suppressed_fail)
		say("... %d more failing lines suppressed (see /run/fsbg/full.log)\n", suppressed_fail);
	if (compact) {
		char hb[65], ha[65];
		struct sha b = hd_before, a = hd_after;
		int i;

		for (i = 0; i < n_tallies; i++)
			say("SERIES %-5s pass=%d fail=%d\n", tallies[i].id, tallies[i].pass, tallies[i].fail);
		sha_hex(&b, hb);
		sha_hex(&a, ha);
		say("HASHDIGEST before=%.32s after=%.32s\n", hb, ha);
	}
	const char *r = code == 0 ? "PASS" : code == 1 ? "FAIL" : "ABORT";

	say("FSBG-PROBE RESULT: %s nonce=%s cases=%d pass=%d fail=%d mode=%s%s%s\n", r, nonce,
	    n_case, n_pass, n_fail, vm_mode ? "vm" : "device",
	    test_kernel ? " testkernel" : (device_sim ? " devicesim" : ""), force_q ? " forceq" : "");
	if (getpid() == 1) {
		sync();
		reboot(RB_POWER_OFF);
	}
	return code;
}

/*
 * The device content rows (FS-R-014 s.3.1, the readback proposal (private)): R1-R5 over their AVB ranges
 * against the expected v2.7 values, R6 the sizes of misc and devinfo, R7d misc whole and R8 devinfo whole (their
 * before/after pair must be equal). Each name must be carried by exactly one node. Nothing else is opened. The
 * first failure stops every later row (s.3.2).
 */
static struct rootrow { const char *name; uint64_t range; const char *sha; } rootread_rows[] = {
	{ "boot_a", 61607936, "7fe59729491b40b689cfe18eb1e4376cfbbb4027a686cdf67fc47ff193437c0a" },
	{ "vendor_boot_a", 5058560, "7e0cfe93e0e9867a3eaf0545204be580699f1b2da769f9afb6fd423ed1a5cfe5" },
	{ "dtbo_a", 12564, "a02fdeede1c1466f6bd97a7deadb0f034a80e011e8fd06706fa94dbfa54f29e8" },
	{ "vbmeta_a", 5632, "1674552357aa0ca1fa15206bf4522254da2ff2e96241c1e862048485ac9dddef" },
	{ "vbmeta_system_a", 3136, "a462b6dab7e67a729ab2906d64b58073a93032b2c71c7e81eea523ecaf0bb973" },
};
static const struct { const char *name; uint64_t size; } scoped_rows[] = { { "misc", 1048576 }, { "devinfo", 4096 } };

static int find_one(const char *name)	/* the index of the one node carrying name, else -1 (and a line) */
{
	int i, found = 0, at = -1;

	for (i = 0; i < n_nodes; i++)
		if (!strcmp(nodes[i].partname, name)) {
			found++;
			at = i;
		}
	if (found != 1) {
		say("ROW R   %-22s %d nodes carry this name (exactly 1 required)\n", name, found);
		return -1;
	}
	return at;
}

static void content_rows_device(void)
{
	size_t k;
	int i;

	for (k = 0; k < sizeof(rootread_rows) / sizeof(rootread_rows[0]); k++) {
		if (hash_fail || row_timeouts) {
			hash_add_x(rootread_rows[k].name, 0, 0, NULL);	/* prints "not read", opens nothing */
			hash_fail++;
			continue;
		}
		if ((i = find_one(rootread_rows[k].name)) < 0) {
			hash_fail++;
			continue;
		}
		if (hash_add_x(nodes[i].dev, 0, rootread_rows[k].range, rootread_rows[k].sha))
			hash_fail++;
	}
	/* R6: the sizes (BLKGETSIZE64 on an O_RDONLY open of the allowlisted node; no I/O) */
	for (k = 0; k < 2; k++) {
		uint64_t sz = 0;
		int f;

		if (hash_fail || row_timeouts) {
			say("ROW R6  %-22s -> not read (%s)\n", scoped_rows[k].name,
			    row_timeouts ? "an earlier row hit its time bound" : "stopped after an earlier failure");
			rows_not_read++;
			hash_fail++;
			continue;
		}
		if ((i = find_one(scoped_rows[k].name)) < 0) {
			hash_fail++;
			continue;
		}
		if (!content_read_allowed(nodes[i].dev)) {
			say("ROW R6  %-22s %s -> not on the content-read allowlist: never opened\n", nodes[i].dev,
			    scoped_rows[k].name);
			hash_fail++;
			continue;
		}
		f = open(nodes[i].dev, O_RDONLY | O_CLOEXEC);
		if (f >= 0)
			sz = node_size(f);
		if (f < 0 || sz != scoped_rows[k].size)
			hash_fail++;
		say("ROW R6  %-22s %s size=%llu expect=%llu\n", nodes[i].dev, scoped_rows[k].name,
		    (unsigned long long)sz, (unsigned long long)scoped_rows[k].size);
		if (f >= 0)
			close(f);
	}
	/* R7d (misc whole) and R8 (devinfo whole), only after R6 passed: equal before and after */
	for (k = 0; k < 2; k++) {
		if (hash_fail || row_timeouts) {
			hash_add_x(scoped_rows[k].name, 0, 0, NULL);
			hash_fail++;
			continue;
		}
		if ((i = find_one(scoped_rows[k].name)) < 0) {
			hash_fail++;
			continue;
		}
		if (hash_add_x(nodes[i].dev, 0, scoped_rows[k].size, NULL))
			hash_fail++;
	}
}

int main(int argc, char **argv)
{
	struct gstate g;
	int i, expect_boot_off = 0, fd_ram1 = -1, fd_ram1_d = -1, fd_xbl = -1, fd_xbl_d = -1;
	char sgn[16][48], bsgn[32][48], verdict[48], pn[40];
	int n_sg = 0, n_bsg = 0, host_parts = -1, fd_host = -1, fd_host_d = -1;

	if (getpid() == 1)
		pid1_setup();
	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--vm"))
			vm_mode = 1;
		else if (!strcmp(argv[i], "--boot-off"))
			expect_boot_off = 1;
		else if (!strcmp(argv[i], "--protect"))
			arm_mode_strict = 0;
		else if (!strcmp(argv[i], "--compact"))
			compact = 1;
		else if (!strncmp(argv[i], "--nonce=", 8))
			snprintf(nonce, sizeof(nonce), "%s", argv[i] + 8);
	}
	t_start = now_s();
	sha_select();
	if (getpid() == 1) {		/* kernel command line options for the VM runs */
		char cl[4096];

		if (read_text("/proc/cmdline", cl, sizeof(cl)) > 0) {
			char *p;

			vm_mode |= strstr(cl, "fsbg.vm") != NULL;
			expect_boot_off |= strstr(cl, "fs_blkguard=off") != NULL;
			if (strstr(cl, "fsbg.protect"))
				arm_mode_strict = 0;
			test_kernel |= strstr(cl, "fsbg.testkernel") != NULL;
			/* fsbg.devicesim (VM only): the device code paths, hazards waived */
			device_sim |= strstr(cl, "fsbg.devicesim") != NULL;
			force_q |= strstr(cl, "fsbg.forceq") != NULL;
			compact |= strstr(cl, "fsbg.compact") != NULL;
			/* fsbg.child (VM test of the K1g layout): run as a child of PID 1, as under init */
			if (strstr(cl, "fsbg.child")) {
				pid_t c = fork();

				if (c > 0) {
					int st;

					waitpid(c, &st, 0);
					sync();
					reboot(RB_POWER_OFF);
				}
			}
			if ((p = strstr(cl, "fsbg.nonce=")))
				sscanf(p + 11, "%63s", nonce);
			/* fsbg.prebudget=<s> (VM only, refused elsewhere): the negative test of the time stop */
			if ((p = strstr(cl, "fsbg.prebudget=")))
				pre_budget = -atof(p + 15);	/* marked negative until checked below */
		}
	}
	say("fsbg-probe: nonce=%s mode=%s arm=%s boot=%s\n", nonce, vm_mode ? "vm" : "device",
	    arm_mode_strict ? "strict" : "protect", expect_boot_off ? "off" : "protect");
	{
		/* every non-default mode is VM-only: --vm, --boot-off, --protect, fsbg.vm, fsbg.testkernel,
		 * fsbg.devicesim, fsbg.forceq, fsbg.prebudget, fs_blkguard=off, fsbg.protect */
		int any = vm_mode || test_kernel || device_sim || force_q || pre_budget <= 0 ||
			  expect_boot_off || !arm_mode_strict;
		const char *why = vm_flag_gate(any, platform_is_vm(), platform_is_quest());

		if (why) {
			say("ABORT: VM-only mode(s)%s%s%s%s%s%s%s refused: %s; no armed guard test case attempted\n",
			    vm_mode ? " vm" : "", test_kernel ? " testkernel" : "", device_sim ? " devicesim" : "",
			    force_q ? " forceq" : "", pre_budget <= 0 ? " prebudget" : "",
			    expect_boot_off ? " boot-off" : "", !arm_mode_strict ? " protect" : "", why);
			return finish(2);
		}
	}
	if (vm_mode && !platform_is_vm()) {
		say("ABORT: --vm refused: this is not a QEMU virt or UML machine\n");
		return finish(2);
	}
	/* fsbg.forceq (mutation tests only): run the protected phase even after mechanism
	 * failures, to show that its cases cannot write without the guard.  VM only. */
	if (device_sim && !platform_is_vm()) {
		say("ABORT: fsbg.devicesim refused: this is not a QEMU virt or UML machine\n");
		return finish(2);
	}
	if (force_q && !platform_is_vm()) {
		say("ABORT: fsbg.forceq refused: this is not a QEMU virt or UML machine\n");
		return finish(2);
	}
	if (pre_budget <= 0 && !platform_is_vm()) {
		say("ABORT: fsbg.prebudget refused: this is not a QEMU virt or UML machine\n");
		return finish(2);
	}
	if (pre_budget <= 0)
		pre_budget = -pre_budget;
	else if (platform_is_vm())
		pre_budget = 120.0;		/* emulated hashing */
	mkdir(WORKDIR, 0700);
	fullf = fopen(WORKDIR "/full.log", "w");
	sha_init(&hd_before);
	sha_init(&hd_after);
	if (posix_memalign((void **)&pattern, BS, BS))
		return finish(2);
	memset(pattern, 0xa5, BS);

	/* ---- 1. pre-check: present, boot mode as expected, not yet sealed */
	if (guard_read(&g)) {
		say("ABORT: %s missing or unreadable: the guard is not in this kernel\n", PROC_GUARD);
		return finish(2);
	}
	say("PRE guard: mode=%s sealed=%d modules_disabled=%d hazards=%s\n", g.mode, g.sealed,
	    g.modlock, g.hazards);
	if (strcmp(g.mode, expect_boot_off ? "off" : "protect") || g.sealed) {
		say("ABORT: unexpected boot state (want %s, unsealed)\n",
		    expect_boot_off ? "off" : "protect");
		return finish(2);
	}
	if (!vm_mode && strcmp(g.hazards, "none") && strcmp(g.hazards, "modules")) {
		if (!test_kernel && !device_sim) {
			say("ABORT: build hazards present on the device kernel: %s\n", g.hazards);
			return finish(2);
		}
		say("WARN: hazards '%s' accepted (fsbg.testkernel: test kernels only)\n", g.hazards);
	}

	/* device mode: the Quest's boot storage must be visible (ufs_qcom loaded), otherwise
	 * the protected phase would have nothing to test and could pass vacuously */
	discover();
	if (!vm_mode && !test_kernel) {
		static const char *const need[] = { "xbl_a", "xbl_b", "tz_a", "tz_b", "abl_a",
			"boot_a", "vbmeta_a", "persist", "misc", "frp", "devinfo", "modemst1",
			"modemst2", "fsg", "cdt", "ddr" };
		size_t k;

		for (k = 0; k < sizeof(need) / sizeof(need[0]); k++) {
			int found = 0;

			for (i = 0; i < n_nodes; i++)
				found |= !strcmp(nodes[i].partname, need[k]);
			if (!found) {
				say("ABORT: boot-storage partition '%s' not visible (is ufs_qcom loaded?)\n",
				    need[k]);
				return finish(2);
			}
		}
		say("PRE boot storage visible: %d block nodes\n", n_nodes);
	}

	/* ---- 2a. decoy preparation (RAM and tmpfs only); device nodes first (after the pre-checks:
	 * nothing, not even a /dev node, is created when the guard is absent or the state is wrong) */
	ensure_nodes();
	{	/* the sendfile source (tmpfs), also only after the pre-checks */
		int pf = open(WORKDIR "/pattern", O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);

		if (pf < 0 || write(pf, pattern, BS) != BS)
			return finish(2);
		close(pf);
	}
	if (setup_decoy_loop()) {
		say("ABORT: cannot build the loop decoy\n");
		return finish(2);
	}
	fd_ram1 = open("/dev/ram1", O_RDWR | O_CLOEXEC);
	fd_ram1_d = open("/dev/ram1", O_RDWR | O_DIRECT | O_CLOEXEC);
	if (fd_ram1 < 0 || fd_ram1_d < 0 || pwrite(fd_ram1_d, pattern, BS, 8 * BS) != BS) {
		say("ABORT: /dev/ram1 unusable (%s)\n", strerror(errno));
		return finish(2);
	}
	if (expect_boot_off) {		/* pre-armed descriptors on a protected-name decoy */
		fd_xbl = open("/dev/loop6p1", O_RDWR | O_CLOEXEC);
		fd_xbl_d = open("/dev/loop6p1", O_RDWR | O_DIRECT | O_CLOEXEC);
	}
	if (!arm_mode_strict) {
		if (write_image(WORKDIR "/decoy2.img", 1) || write_image(WORKDIR "/blank.img", 0) ||
		    attach_loop(4, WORKDIR "/decoy2.img") != N_DECOY_PARTS) {
			say("ABORT: cannot build the loop4 decoy\n");
			return finish(2);
		}
	}
	if (dm_make("fsbg-rw", DM_MINOR_RW, "/dev/ram1", 8192, 0)) {
		say("ABORT: cannot create dm-%d over /dev/ram1\n", DM_MINOR_RW);
		return finish(2);
	}
	{
		int lf = open("/dev/loop7", O_RDWR | O_CLOEXEC);

		if (lf < 0 || ioctl(lf, LOOP_SET_FD, fd_ram1)) {
			say("ABORT: cannot attach loop7 to /dev/ram1\n");
			return finish(2);
		}
		close(lf);
	}
	/* vm mode: a host-file decoy disk (UML: loop5 over a hostfs file; hashed on the host) */
	if (vm_mode && access("/fsbg-hostdecoy.img", F_OK) == 0) {
		host_parts = attach_loop(5, "/fsbg-hostdecoy.img");
		say("host decoy: /dev/loop5 with %d partitions\n", host_parts);
		if (host_parts > 0 && expect_boot_off) {
			fd_host = open("/dev/loop5p1", O_RDWR | O_CLOEXEC);
			fd_host_d = open("/dev/loop5p1", O_RDWR | O_DIRECT | O_CLOEXEC);
		}
	}
	if (vm_mode) {			/* SCSI decoys: write a GPT before arming, rescan */
		discover();
		for (i = 0; i < n_nodes; i++)
			if (nodes[i].whole && nodes[i].is_sd && !disk_has_parts(nodes[i].dev)) {
				uint8_t *img = calloc(DECOY_SECTORS, 512);
				int f = open(nodes[i].dev, O_RDWR | O_CLOEXEC);

				if (img && f >= 0) {
					uint64_t sz = 0;

					ioctl(f, BLKGETSIZE64, &sz);
					if (sz >= DECOY_SECTORS * 512) {
						make_gpt(img, DECOY_SECTORS, scsi_parts, 6);
						if (sz == DECOY_SECTORS * 512 &&
						    pwrite(f, img, DECOY_SECTORS * 512, 0) > 0)
							ioctl(f, BLKRRPART, 0);
					}
				}
				if (f >= 0)
					close(f);
				free(img);
			}
	}

	/* hashes before (decoys; real storage in device mode) */
	hash_add("/dev/ram1", 1ULL << 40);
	hash_add("/dev/loop6", 0);		/* GPT areas: head and tail 1 MiB */
	hash_add("/dev/loop6p1", 1ULL << 40);
	hash_add("/dev/loop6p2", 1ULL << 40);
	hash_add("/dev/loop6p3", 1ULL << 40);
	hash_add("/dev/loop6p4", 1ULL << 40);
	hash_add("/dev/loop6p6", 1ULL << 40);	/* p5 is the allowlisted control */
	discover();
	if (vm_mode)			/* QEMU/UML vm mode: every VM disk is a host-file decoy, hashed whole */
		for (i = 0; i < n_nodes; i++)
			hash_add(nodes[i].dev, 1ULL << 40);
	else {
		/* FS-R-014 s.3.1: enumeration is metadata only; content is read from the allowlist alone */
		char ex[160] = "";

		for (i = 0; i < n_nodes; i++)
			if (!node_open_allowed(&nodes[i]) && strlen(ex) + strlen(nodes[i].dev) + 2 < sizeof(ex)) {
				strcat(ex, " ");
				strcat(ex, nodes[i].dev);
			}
		say("PRE scope: content reads only R1-R5, R6, R7d (misc), R8 (devinfo); never opened:%s\n",
		    ex[0] ? ex : " none");
	}
	if (host_parts > 0) {
		hash_add("/dev/loop5", 1ULL << 40);
		for (i = 1; i <= host_parts; i++) {
			snprintf(pn, sizeof(pn), "/dev/loop5p%d", i);
			hash_add(pn, 1ULL << 40);
		}
	}
	/* device: the content-read allowlist only (FS-R-014 s.3.1): R1-R5, R6, R7d, R8 */
	if (!vm_mode && !test_kernel)
		content_rows_device();
	{
		double e1 = now_s() - t_start;
		uint64_t mib = 0;
		char f0[32] = "?", fl[32] = "?", gov[32] = "?";
		int last;

		for (i = 0; i < n_hashes; i++)
			mib += hashes[i].got;
		/* the clocks while hashing (read-only sysfs; recorded, not judged) */
		read_text("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", f0, sizeof(f0));
		read_text("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", gov, sizeof(gov));
		last = (int)sysconf(_SC_NPROCESSORS_CONF) - 1;
		{
			char pth[96];

			snprintf(pth, sizeof(pth), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", last);
			read_text(pth, fl, sizeof(fl));
		}
		f0[strcspn(f0, "\n")] = 0; fl[strcspn(fl, "\n")] = 0; gov[strcspn(gov, "\n")] = 0;
		say("PRE pace: sha256=%s before-pass=%.2f s budget=%.0f s hashed=%llu MiB cpu0=%s kHz cpu%d=%s kHz governor=%s\n",
		    sha_impl, e1, pre_budget, (unsigned long long)(mib >> 20), f0, last, fl, gov);
		if (row_timeouts) {
			say("ABORT: time: %d row(s) hit their time bound before arming; no armed guard test case attempted\n",
			    row_timeouts);
			return finish(2);
		}
		if (hash_fail) {
			say("ABORT: %d hashing row(s) failed closed before arming (%d later row(s) not read); no armed guard "
			    "test case attempted\n", hash_fail - rows_not_read, rows_not_read);
			return finish(2);
		}
		if (e1 > pre_budget) {
			say("ABORT: time: the before-hash pass took %.2f s (budget %.0f s): the proof would not fit "
			    "its time; no armed guard test case attempted\n", e1, pre_budget);
			return finish(2);
		}
	}

	/* ---- arm: module latch, then the sealing request */
	if (write_text("/proc/sys/kernel/modules_disabled", "1") &&
	    access("/proc/sys/kernel/modules_disabled", F_OK) == 0) {
		say("ABORT: cannot latch kernel.modules_disabled\n");
		return finish(2);
	}
	snprintf(arm_req, sizeof(arm_req),
		 arm_mode_strict ? "strict allow=disk:ram0,disk:dm-%d,disk:dm-%d,disk:loop%d,part:fsbg_decoy_rw"
				 : "protect allow=part:fsbg_decoy_rw", DM_MINOR_RW, DM_MINOR_RO, STACK_LOOP);
	if (write_text(PROC_GUARD, arm_req)) {
		say("ABORT: arming request refused: %s\n", arm_req);
		return finish(2);
	}
	if (guard_read(&g) || strcmp(g.mode, arm_mode_strict ? "strict" : "protect") ||
	    g.sealed != 1 || g.modlock != 1) {
		say("ABORT: guard not armed as requested (mode=%s sealed=%d)\n", g.mode, g.sealed);
		return finish(2);
	}
	say("ARMED: %s\n", arm_req);
	/* the seal holds: every further request is refused */
	if (!write_text(PROC_GUARD, "strict") || !write_text(PROC_GUARD, "protect")) {
		say("FAIL: a second arming request was accepted\n");
		n_fail++;
		stop_all = 1;
	} else {
		say("SEAL: re-arming refused (EPERM) -> PASS\n");
		n_pass++;
	}
	n_case++;

	/* identification: every real storage node must have a deny verdict */
	discover();
	for (i = 0; i < n_nodes && !stop_all; i++) {
		guard_verdict(nodes[i].dev + 5, verdict, sizeof(verdict));
		if (strncmp(verdict, "deny-", 5)) {
			if (!vm_mode || arm_mode_strict) {
				say("ABORT: guard verdict for %s (%s) is '%s'\n", nodes[i].dev,
				    nodes[i].partname, verdict);
				return finish(2);
			}
		}
	}

	/* ---- 2b. mechanism phase on decoys */
	{
		struct op o = { .fd = -1 };
		struct case_spec c;
		struct dmop d3 = { "fsbg-new", "/dev/loop6p2", DM_MINOR_NEW, 2048 };

		if (arm_mode_strict)
			decoy_node_cases("/dev/ram1", 1, 0);
		decoy_node_cases("/dev/loop6", 1, 0);
		decoy_node_cases("/dev/loop6p1", 0, 0);
		decoy_node_cases("/dev/loop6p2", 0, 1);
		decoy_node_cases("/dev/loop6p3", 0, 0);
		decoy_node_cases("/dev/loop6p4", 0, 0);
		decoy_node_cases("/dev/loop6p6", 0, 0);
		if (arm_mode_strict)
			prearmed_cases("/dev/ram1", fd_ram1, fd_ram1_d);
		if (fd_xbl >= 0 && fd_xbl_d >= 0)
			prearmed_cases("/dev/loop6p1", fd_xbl, fd_xbl_d);
		if (host_parts > 0) {
			decoy_node_cases("/dev/loop5", 1, 0);
			for (i = 1; i <= host_parts; i++) {
				snprintf(pn, sizeof(pn), "/dev/loop5p%d", i);
				decoy_node_cases(strdup(pn), 0, 0);
			}
			if (fd_host >= 0 && fd_host_d >= 0)
				prearmed_cases("/dev/loop5p1", fd_host, fd_host_d);
		}
		if (arm_mode_strict) {
			/* S1: dm-200 (pre-arm, rw over ram1) is allowlisted; the leaf refuses */
			o.dev = "/dev/dm-200";
			spec(&c, "S1", o.dev, P_BIO, EXP_EIO, 1, 64, 0, 0);
			run_case(&c, fn_write_direct, &o);
			/* S2: dm-201, read-only table over xbl_a, ro flag cleared, written */
			if (dm_make("fsbg-ro", DM_MINOR_RO, "/dev/loop6p1", 2048, 1) == 0) {
				o.dev = "/dev/dm-201";
				spec(&c, "S2", o.dev, P_BIO, EXP_EIO, 1, 64, 0, 0);
				run_case(&c, fn_roset_then_write, &o);
			} else {
				say("CASE S2: cannot create the read-only dm -> FAIL\n");
				n_fail++; n_case++;
			}
			/* S4: loop7 (pre-arm over an O_RDWR fd of ram1): the loop worker's write */
			o.dev = "/dev/loop7";
			spec(&c, "S4", o.dev, P_WRITE, EXP_EIO, 1, 4, 0, 0);
			run_case(&c, fn_write_direct, &o);
		}
		if (!arm_mode_strict) {
			/* S5: detach loop4 (GPT names) and re-open it for writing with no
			 * partitions left: still boot storage (sticky mark) */
			spec(&c, "S5", "/dev/loop4", P_OPEN, EXP_REFUSE, 1, 1, 0, 0);
			run_case(&c, fn_sticky_reattach, NULL);
		}
		/* S3: a new read-write dm table over persist: refused at open */
		spec(&c, "S3", "dm-202->loop6p2", P_OPEN, EXP_REFUSE, 1, 1, 0, 0);
		run_case(&c, fn_dm_load_rw, &d3);

		/* positive controls */
		/* positive controls write data: each target is re-verified RAM-backed first */
		o.dev = "/dev/loop6p5";
		if (vm_mode || ram_backed(o.dev))
			run_allow("A1", o.dev, fn_rw_ok, &o);
		else {
			say("ABORT: %s is not RAM-backed; refusing to write it\n", o.dev);
			late_abort = stop_all = 1;
		}
		o.dev = arm_mode_strict ? "/dev/ram0" : "/dev/ram2";	/* ram2: unguarded in protect mode; not hashed */
		if (vm_mode || ram_backed(o.dev))
			run_allow("A2", o.dev, fn_rw_ok, &o);
		else {
			say("ABORT: %s is not RAM-backed; refusing to write it\n", o.dev);
			late_abort = stop_all = 1;
		}
	}

	/* ---- SCSI paths */
	find_class_nodes("/sys/class/scsi_generic", NULL, sgn, &n_sg, 16);
	find_class_nodes("/sys/class/bsg", NULL, bsgn, &n_bsg, 32);
	discover();
	if (vm_mode) {
		for (i = 0; i < n_nodes && !stop_all; i++)
			if (nodes[i].whole && nodes[i].is_sd) {
				struct op q = { .dev = nodes[i].dev, .fd = -1, .flags = O_RDONLY };
				const char *sg1 = n_sg ? sgn[0] : NULL;
				const char *bs1 = NULL;
				int k;

				for (k = 0; k < n_bsg; k++)
					if (isdigit((unsigned char)bsgn[k][9]))
						bs1 = bsgn[k];
				scsi_decoy_cases(nodes[i].dev, sg1, bs1);
				run_allow("A3", nodes[i].dev, fn_inquiry_ok, &q);
				run_allow("A4", nodes[i].dev, fn_rcap16_ok, &q);
				break;
			}
		/* C19 (VM only, QEMU UFS): a UFS query through ufs-bsg with full capabilities (the stock
		 * kernel would execute this read): the guard must refuse it (bsg +1) */
		for (i = 0; i < n_bsg && !stop_all; i++)
			if (!strncmp(bsgn[i] + 9, "ufs-bsg", 7)) {
				struct case_spec c;
				struct op u = { .dev = bsgn[i], .fd = -1, .flags = O_RDWR, .req = 1,
						.cdb = upiu_query, .cdb_len = sizeof(upiu_query) };

				spec(&c, "C19", bsgn[i], P_BSG, E(EPERM), 1, 1, 0, 0);
				run_case(&c, fn_bsg, &u);
			}
		/* every other real disk in the VM is a decoy as well: full write attempts */
		for (i = 0; i < n_nodes && !stop_all; i++)
			if (arm_mode_strict || disk_has_parts(nodes[i].dev) || !nodes[i].whole ||
			    nodes[i].partname[0])
				decoy_node_cases(nodes[i].dev, nodes[i].whole, 0);
			else	/* protect mode: a disk with no partitions is not boot storage */
				say("SKIP  N*    %-22s no partitions: unguarded in protect mode\n",
				    nodes[i].dev);
	}

	if (n_fail && !force_q) {
		say("Mechanism phase failed: the protected phase is skipped\n");
		stop_all = 1;
	} else if (n_fail) {
		say("Mechanism phase failed: protected phase forced (fsbg.forceq, VM only)\n");
		stop_all = 0;
	}
	if (late_abort)
		stop_all = 1;		/* never forced past a refused decoy check */

	/* ---- 3. protected phase (device mode only) */
	if (!vm_mode && !stop_all) {
		for (i = 0; i < n_nodes && !stop_all; i++) {
			if (!node_open_allowed(&nodes[i])) {	/* FS-R-014 s.3.1 */
				say("SKIP  Q*    %-22s %s: never opened (FS-R-014 s.3.1)\n", nodes[i].dev,
				    !strcmp(nodes[i].partname, "persist") ? "persist" : "not identifiable");
				continue;
			}
			protected_node_cases(nodes[i].dev, nodes[i].whole, nodes[i].is_sd);
		}
		for (i = 0; i < n_sg && !stop_all; i++)
			protected_passthru_cases(sgn[i], 0);
		for (i = 0; i < n_bsg && !stop_all; i++)
			protected_passthru_cases(bsgn[i], strncmp(bsgn[i] + 9, "ufs-bsg", 7) ? 1 : 2);
		/* Q11 (a write-mode open, closed unwritten) is NOT run on a Quest (PM decision
		 * 2026-10-15); it runs only on test kernels in QEMU/UML. */
		for (i = 0; i < n_nodes && !stop_all && test_kernel; i++)
			if (node_open_allowed(&nodes[i]))
				protected_open_case(nodes[i].dev);
		for (i = 0; i < n_nodes && !stop_all; i++) {
			struct op q = { .dev = nodes[i].dev, .fd = -1, .flags = O_RDONLY };

			if (nodes[i].is_sd && nodes[i].whole && node_open_allowed(&nodes[i]))	/* every whole sd disk */
				run_allow("A3", nodes[i].dev, fn_inquiry_ok, &q);
		}
	}

	/* ---- 4. read-back hashes, same boot */
	{
		int timed = 0;

		if (hash_verify(&timed))
			n_fail++;
		if (timed) {
			say("ABORT: time: %d after-hash row(s) not verified within their bound; the invariance check "
			    "is incomplete (not a changed range)\n", timed);
			late_abort = 1;
		}
	}
	guard_read(&g);
	say("POST guard counters: total=%ld\n", g.total);
	return finish(n_fail ? 1 : late_abort ? 2 : 0);
}
