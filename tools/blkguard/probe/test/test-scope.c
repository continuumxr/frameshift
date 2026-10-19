/* fs-blkguard probe: fixtures for FS-R-014 s.3 (read scope, stop on the first failure, no open fallback).
 *
 * Builds fsbg-probe.c with its main renamed and runs its real content pass (content_rows_device, hash_add_x,
 * hash_row, hash_node, hash_node_do, hash_verify) over synthetic "real storage" nodes: every open() the probe makes
 * is intercepted (-Wl,--wrap=open) and appended to a log, and a fake node is served from a small regular file in a
 * temporary directory (O_DIRECT stripped). The partition names come from the test's table through the probe's
 * partname hook, so discovery order and names are under the test's control. Nothing outside the temporary
 * directory is opened for writing; no device is touched.
 *
 *   gcc -O1 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -Wl,--wrap=open -o test-scope test-scope.c && ./test-scope
 *
 * K1g r3 (J-207): every pread() on a fake node opened with O_DIRECT is checked as the Linux 5.10 block layer
 * checks it (blkdev_direct_IO: offset, length and buffer address each a multiple of the logical block size, else
 * EINVAL; -Wl,--wrap=pread,--wrap=pread64), with the fake's own logical block size (4096 like the Quest 3's UFS
 * LUNs, or 512), and logged. Sections 10-12 are the 4K regression: the r2 code (512-byte rounding) fails them with
 * "Invalid argument" at R3 dtbo_a, as on Unit 2; build with -DFSBG_PROBE_SRC='"<path>"' to run against another
 * fsbg-probe.c (run-scope.sh does both).
 *
 *   gcc -O1 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -Wl,--wrap=open,--wrap=pread,--wrap=pread64 \
 *       -o test-scope test-scope.c && ./test-scope
 *
 * Run it alone: the rows run under the probe's real time bounds, so a heavily loaded host can make R1 hit its
 * before-pass bound (an unrelated FAIL).
 *
 * Exit 0: every case as expected. The output is plain text (no sound).
 */
#ifndef FSBG_PROBE_SRC
#define FSBG_PROBE_SRC "../fsbg-probe.c"
#endif
#define main fsbg_probe_main
#include FSBG_PROBE_SRC
#undef main

int __real_open(const char *path, int flags, ...);
ssize_t __real_pread(int fd, void *buf, size_t n, off_t off);
ssize_t __real_pread64(int fd, void *buf, size_t n, off_t off);

static char tdir[256], logpath[300], readlog[300];
static struct fake { char path[64]; char part[64]; char file[320]; unsigned lbs; } fk[64];
static int nfk, fails, cases;
static unsigned fake_lbs = 4096;	/* the logical block size of every fake node (the Quest 3's UFS LUNs: 4096) */
static unsigned dio_lbs[1024];		/* fd -> the logical block size of the fake opened O_DIRECT on it (0: none) */
static int dio_fk[1024];		/* fd -> the fake's index */
static const char *short_path;		/* section 12: reads on this node come back 236 bytes short */

static void note_fd(int fd, unsigned lbs, int k)
{
	if (fd >= 0 && fd < 1024) {
		dio_lbs[fd] = lbs;
		dio_fk[fd] = k;
	}
}

int __wrap_open(const char *path, int flags, ...)
{
	mode_t mode = 0;
	int i;

	if (flags & O_CREAT) {
		va_list ap;

		va_start(ap, flags);
		mode = (mode_t)va_arg(ap, int);
		va_end(ap);
	}
	if (!strncmp(path, "/dev/fake/", 10)) {
		int lf = __real_open(logpath, O_WRONLY | O_APPEND | O_CREAT, 0644);

		if (lf >= 0) {
			dprintf(lf, "%s\n", path);
			close(lf);
		}
		for (i = 0; i < nfk; i++)
			if (!strcmp(fk[i].path, path)) {
				int fd = __real_open(fk[i].file, flags & ~O_DIRECT, mode);

				note_fd(fd, (flags & O_DIRECT) ? fk[i].lbs : 0, i);
				return fd;
			}
		errno = ENOENT;
		return -1;
	}
	{
		int fd = __real_open(path, flags, mode);

		note_fd(fd, 0, -1);
		return fd;
	}
}

/* O_DIRECT on a fake node: the 5.10 blkdev_direct_IO rule ((pos | iov alignment) & (lbs - 1) -> EINVAL), and a log
 * line "<node> <offset> <length>" per read */
static ssize_t dio_check(int fd, void *buf, size_t n, off_t off, int is64)
{
	if (fd >= 0 && fd < 1024 && dio_lbs[fd]) {
		unsigned a = dio_lbs[fd] - 1;
		int lf = __real_open(readlog, O_WRONLY | O_APPEND | O_CREAT, 0644);

		if (lf >= 0) {
			dprintf(lf, "%s %lld %zu\n", fk[dio_fk[fd]].path, (long long)off, n);
			close(lf);
		}
		if (((uint64_t)off & a) || (n & a) || ((uintptr_t)buf & a)) {
			errno = EINVAL;
			return -1;
		}
	}
	{
		ssize_t got = is64 ? __real_pread64(fd, buf, n, off) : __real_pread(fd, buf, n, off);

		if (short_path && fd >= 0 && fd < 1024 && dio_fk[fd] >= 0 && !strcmp(fk[dio_fk[fd]].path, short_path) &&
		    got > 236)
			got -= 236;	/* section 12: the device returns fewer bytes than asked (still >= the row's) */
		return got;
	}
}
ssize_t __wrap_pread(int fd, void *buf, size_t n, off_t off) { return dio_check(fd, buf, n, off, 0); }
ssize_t __wrap_pread64(int fd, void *buf, size_t n, off_t off) { return dio_check(fd, buf, n, off, 1); }

static int fake_partname(const char *path, char *out, size_t n)
{
	int i;

	for (i = 0; i < nfk; i++)
		if (!strcmp(fk[i].path, path)) {
			snprintf(out, n, "%s", fk[i].part);
			return fk[i].part[0] ? 0 : -1;
		}
	return -1;
}

/* deterministic synthetic content (not Meta data): byte i of node `seed` */
static void write_content(const char *file, uint64_t size, unsigned seed)
{
	int f = __real_open(file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	static uint8_t b[1 << 16];
	uint64_t off = 0;

	while (off < size) {
		size_t k = size - off < sizeof(b) ? (size_t)(size - off) : sizeof(b), i;

		for (i = 0; i < k; i++)
			b[i] = (uint8_t)((off + i) * 2654435761u >> 24) ^ (uint8_t)seed;
		if (write(f, b, k) != (ssize_t)k)
			exit(3);
		off += k;
	}
	close(f);
}

static void sha_of(uint64_t size, unsigned seed, char hex[65])
{
	static uint8_t b[1 << 16];
	struct sha s;
	uint64_t off = 0;

	sha_init(&s);
	while (off < size) {
		size_t k = size - off < sizeof(b) ? (size_t)(size - off) : sizeof(b), i;

		for (i = 0; i < k; i++)
			b[i] = (uint8_t)((off + i) * 2654435761u >> 24) ^ (uint8_t)seed;
		sha_upd(&s, b, k);
		off += k;
	}
	sha_hex(&s, hex);
}

/* the table of a scenario: kernel name, partition name, the row's length (R1-R5: the AVB range; misc/devinfo: the
 * whole node), the node's size (a multiple of 4096, as on the unit's 4096-byte-block LUNs; 0: the length) */
struct spec { const char *name, *part; uint64_t size, node; };

static const struct spec base[] = {
	{ "sde14", "boot_a", 61607936, 0 }, { "sde22", "vendor_boot_a", 5058560, 0 },
	{ "sde16", "dtbo_a", 12564, 1048576 }, { "sde17", "vbmeta_a", 5632, 65536 },
	{ "sde18", "vbmeta_system_a", 3136, 65536 }, { "sda9", "misc", 1048576, 0 }, { "sde9", "devinfo", 4096, 0 },
	/* excluded: persist, other partitions, whole LUNs, look-alike and unexpected names */
	{ "sda2", "persist", 4096 }, { "sda11", "userdata", 4096 }, { "sda10", "metadata", 4096 },
	{ "sde40", "boot_b", 4096 }, { "sde41", "BOOT_A", 4096 }, { "sde42", "boot_a_old", 4096 },
	{ "sde43", "misc ", 4096 }, { "sde44", "vbmeta", 4096 }, { "sda", "", 4096 }, { "sde", "", 4096 },
	{ "mmcblk0p3", "persistbak", 4096 }, { "nvme0n1p1", "modemst1", 4096 }, { "sdf5", "fsc", 4096 },
};
#define NBASE ((int)(sizeof(base) / sizeof(base[0])))
static const char *const allowed_paths[] = { "/dev/fake/sde14", "/dev/fake/sde22", "/dev/fake/sde16",
	"/dev/fake/sde17", "/dev/fake/sde18", "/dev/fake/sda9", "/dev/fake/sde9" };
/* the opens of a complete content pass, in order: R1-R5, R6 misc, R6 devinfo, R7d misc, R8 devinfo */
static const char *const full_seq[] = { "/dev/fake/sde14", "/dev/fake/sde22", "/dev/fake/sde16", "/dev/fake/sde17",
	"/dev/fake/sde18", "/dev/fake/sda9", "/dev/fake/sde9", "/dev/fake/sda9", "/dev/fake/sde9" };
static char rr_sha[5][65];

static void setup(const int *order, int n)
{
	int i;
	char cmd[400];

	snprintf(cmd, sizeof(cmd), "rm -rf %s/n && mkdir -p %s/n", tdir, tdir);
	if (system(cmd))
		exit(3);
	nfk = 0;
	n_nodes = 0;
	for (i = 0; i < n; i++) {
		const struct spec *sp = &base[order[i]];
		struct fake *f = &fk[nfk++];
		struct node *nd = &nodes[n_nodes++];

		snprintf(f->path, sizeof(f->path), "/dev/fake/%s", sp->name);
		snprintf(f->part, sizeof(f->part), "%s", sp->part);
		snprintf(f->file, sizeof(f->file), "%s/n/%s", tdir, sp->name);
		f->lbs = fake_lbs;
		write_content(f->file, sp->node ? sp->node : sp->size, (unsigned)order[i]);
		snprintf(nd->dev, sizeof(nd->dev), "%s", f->path);
		snprintf(nd->partname, sizeof(nd->partname), "%s", sp->part);
		nd->whole = !sp->part[0];
		nd->is_sd = !strncmp(sp->name, "sd", 2);
	}
	for (i = 0; i < 5; i++)
		rootread_rows[i].sha = rr_sha[i];
	n_hashes = 0;
	hash_fail = 0;
	row_timeouts = 0;
	t_start = now_s();
	truncate(logpath, 0);
	truncate(readlog, 0);
}

static int read_log(char lines[64][64])
{
	FILE *f = fopen(logpath, "r");
	int n = 0;

	if (!f)
		return 0;
	while (n < 64 && fgets(lines[n], 64, f)) {
		lines[n][strcspn(lines[n], "\n")] = 0;
		n++;
	}
	fclose(f);
	return n;
}

static void check(int ok, const char *fmt, ...)
{
	va_list ap;

	cases++;
	if (!ok)
		fails++;
	fprintf(stderr, "%s  ", ok ? "PASS" : "FAIL");
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static struct fake *fake_by_part(const char *part)
{
	int i;

	for (i = 0; i < nfk; i++)
		if (!strcmp(fk[i].part, part))
			return &fk[i];
	return NULL;
}

static int log_is_prefix(int want)	/* the log is exactly the first `want` opens of a complete pass */
{
	char l[64][64];
	int n = read_log(l), i;

	if (n != want)
		return 0;
	for (i = 0; i < n; i++)
		if (strcmp(l[i], full_seq[i]))
			return 0;
	return 1;
}

int main(void)
{
	int order[NBASE], i, k, r;
	unsigned rnd = 12345;
	char l[64][64];

	snprintf(tdir, sizeof(tdir), "/tmp/fsbg-scope-%d", (int)getpid());
	mkdir(tdir, 0700);
	snprintf(logpath, sizeof(logpath), "%s/opens.log", tdir);
	snprintf(readlog, sizeof(readlog), "%s/reads.log", tdir);
	partname_hook = fake_partname;
	if (!freopen("/dev/null", "w", stdout))	/* the probe's own lines; the verdicts go to stderr */
		return 3;
	for (i = 0; i < 5; i++)
		sha_of(base[i].size, (unsigned)i, rr_sha[i]);

	/* 1. scope: 25 discovery orders (identity, reversed, 23 shuffles), unexpected and look-alike names */
	for (r = 0; r < 25; r++) {
		int n, bad = 0, seen[7] = { 0 };

		for (i = 0; i < NBASE; i++)
			order[i] = r == 1 ? NBASE - 1 - i : i;
		for (i = NBASE - 1; r >= 2 && i > 0; i--) {
			int j, t;

			rnd = rnd * 1103515245u + 12345u;
			j = (int)((rnd >> 8) % (unsigned)(i + 1));
			t = order[i]; order[i] = order[j]; order[j] = t;
		}
		setup(order, NBASE);
		/* the seeds follow the base index, so every R1-R5 content still matches its expected value */
		content_rows_device();
		n = read_log(l);
		for (i = 0; i < n; i++) {
			int a, ok = 0;

			for (a = 0; a < 7; a++)
				if (!strcmp(l[i], allowed_paths[a])) {
					ok = 1;
					seen[a]++;
				}
			bad += !ok;
		}
		check(hash_fail == 0 && bad == 0 && n == 9 && seen[0] == 1 && seen[4] == 1 && seen[5] == 2 && seen[6] == 2,
		      "scope, discovery order %2d: %d opens, all on the 7 allowlisted partitions (persist, userdata, metadata, "
		      "boot_b, BOOT_A, boot_a_old, 'misc ', vbmeta, whole LUNs, persistbak, modemst1, fsc never opened)", r, n);
	}

	/* 2. the gate itself: a row on an excluded node is refused before any open (no child, no open) */
	{
		static const char *const ex[] = { "persist", "userdata", "metadata", "boot_b", "BOOT_A", "" };
		int all = 1;

		for (i = 0; i < NBASE; i++)
			order[i] = i;
		setup(order, NBASE);
		for (k = 0; k < 6; k++) {
			struct hashrec h;
			struct fake *f = NULL;

			for (i = 0; i < nfk; i++)
				if (!strcmp(fk[i].part, ex[k]))
					f = &fk[i];
			if (!f)
				continue;
			memset(&h, 0, sizeof(h));
			snprintf(h.dev, sizeof(h.dev), "%s", f->path);
			h.limit = 5;
			all &= hash_row("H", &h, 0) != 0;
		}
		check(all && read_log(l) == 0, "gate: rows on persist, userdata, metadata, boot_b, BOOT_A and a whole LUN are "
		      "refused before any open (0 opens)");
		check(!content_read_allowed("/dev/fake/sda2") && !content_read_allowed("/dev/fake/nonexistent"),
		      "gate: persist and an unidentifiable node are not on the content-read allowlist");
		{
			struct node pn = { "/dev/fake/sda2", "persist", 0, 1 }, un = { "/dev/fake/sda11", "userdata", 0, 1 };

			check(!node_open_allowed(&pn) && node_open_allowed(&un),
			      "protected phase: persist is never a target of any case (FS-R-014 s.3.1); other nodes are");
		}
	}

	/* 3. duplicates: a second node carrying boot_a stops the pass before boot_a is read */
	{
		static const struct spec dup = { "sde60", "boot_a", 61607936 };
		int ok;

		for (i = 0; i < NBASE; i++)
			order[i] = i;
		setup(order, NBASE);
		snprintf(nodes[n_nodes].dev, sizeof(nodes[0].dev), "/dev/fake/%s", dup.name);
		snprintf(nodes[n_nodes].partname, sizeof(nodes[0].partname), "%s", dup.part);
		n_nodes++;
		content_rows_device();
		ok = hash_fail > 0 && read_log(l) == 0;
		check(ok, "duplicate boot_a: the pass stops at R1 with nothing opened at all");
	}

	/* 4. before-pass: each failure at each row stops every later open (FS-R-014 s.3.2). R7d/R8 (misc, devinfo
	 *    whole) have no expected value and the same range as R6's size check, so on a node they can fail only by a
	 *    read error or a time bound after R6 passed; their stop behaviour is the same code (hash_add_x) */
	{
		static const char *const kinds[] = { "read error", "range beyond the node", "content differs", "missing node" };
		/* the row targets in pass order: R1-R5, R6 misc, R6 devinfo, R7d misc, R8 devinfo */
		static const char *const parts[] = { "boot_a", "vendor_boot_a", "dtbo_a", "vbmeta_a", "vbmeta_system_a",
						     "misc", "devinfo", "misc", "devinfo" };
		int pos, kd;

		for (pos = 0; pos < 7; pos++)
			for (kd = 0; kd < 4; kd++) {
				struct fake *f;
				char cmd[700];
				int want;

				if (pos >= 5 && pos <= 6 && kd != 1)
					continue;	/* R6 is a size check: its failure is a wrong size */
				for (i = 0; i < NBASE; i++)
					order[i] = i;
				setup(order, NBASE);
				f = fake_by_part(parts[pos]);
				switch (kd) {
				case 0: snprintf(cmd, sizeof(cmd), "rm -f %s && mkdir %s", f->file, f->file); break;
				case 1: snprintf(cmd, sizeof(cmd), "truncate -s 512 %s", f->file); break;
				case 2: snprintf(cmd, sizeof(cmd), "printf x | dd of=%s bs=1 seek=100 conv=notrunc status=none", f->file); break;
				default: snprintf(cmd, sizeof(cmd), "rm -f %s", f->file); break;
				}
				if (system(cmd))
					exit(3);
				content_rows_device();
				want = pos + 1;		/* the failing row's own open is the last one */
				check(hash_fail > 0 && log_is_prefix(want),
				      "before-pass, %-16s at row %d (%s): %d open(s), none after the failing row",
				      kinds[kd], pos + 1, parts[pos], want);
			}
	}

	/* 5. after-pass: a CHANGED row or a read error stops every later after-row */
	{
		/* the after-pass order of the rows the test makes: R1-R5, R7d misc, R8 devinfo */
		static const char *const after_seq[] = { "/dev/fake/sde14", "/dev/fake/sde22", "/dev/fake/sde16",
			"/dev/fake/sde17", "/dev/fake/sde18", "/dev/fake/sda9", "/dev/fake/sde9" };
		int pos, kd;

		for (pos = 0; pos < 7; pos++)
			for (kd = 0; kd < 2; kd++) {
				int timed = 0, bad, n, ok = 1;
				char cmd[700];
				struct fake *f;

				for (i = 0; i < NBASE; i++)
					order[i] = i;
				setup(order, NBASE);
				content_rows_device();
				if (hash_fail || n_hashes != 7) {
					check(0, "after-pass setup: the before-pass did not complete (%d rows)", n_hashes);
					continue;
				}
				truncate(logpath, 0);
				f = NULL;
				for (i = 0; i < nfk; i++)
					if (!strcmp(fk[i].path, after_seq[pos]))
						f = &fk[i];
				if (kd == 0)
					snprintf(cmd, sizeof(cmd), "printf x | dd of=%s bs=1 seek=7 conv=notrunc status=none", f->file);
				else
					snprintf(cmd, sizeof(cmd), "rm -f %s && mkdir %s", f->file, f->file);
				if (system(cmd))
					exit(3);
				t_start = now_s();
				bad = hash_verify(&timed);
				n = read_log(l);
				ok = bad == 1 && timed == 0 && n == pos + 1;
				for (i = 0; ok && i < n; i++)
					ok = !strcmp(l[i], after_seq[i]);
				check(ok, "after-pass, %-10s at row %d: %d open(s), none after the failing row; classified as a "
				      "failure (not time)", kd ? "read error" : "CHANGED", pos + 1, n);
			}
	}

	/* 6. no open fallback (FS-R-014 s.3.3): one open per row, O_DIRECT only (the source has one open call) */
	{
		int ok;

		for (i = 0; i < NBASE; i++)
			order[i] = i;
		setup(order, NBASE);
		{
			struct fake *f = fake_by_part("dtbo_a");
			char cmd[400];

			snprintf(cmd, sizeof(cmd), "rm -f %s", f->file);	/* the open fails (ENOENT) */
			if (system(cmd))
				exit(3);
		}
		content_rows_device();
		ok = log_is_prefix(3);	/* R1, R2, then ONE failed open of R3 and nothing more (no reopen) */
		check(ok && hash_fail > 0, "a failed open is not retried without O_DIRECT: exactly one open of the row, then stop");
	}

	/* 7. after-pass time: with less than 1 s left before AFTER_END no after-row starts (no open at all) */
	{
		int timed = 0, bad, n;

		for (i = 0; i < NBASE; i++)
			order[i] = i;
		setup(order, NBASE);
		content_rows_device();
		truncate(logpath, 0);
		t_start = now_s() - (AFTER_END - 0.5);	/* 0.5 s left */
		bad = hash_verify(&timed);
		n = read_log(l);
		check(n_hashes == 7 && bad == 0 && timed == 7 && n == 0,
		      "after-pass with < 1 s left before AFTER_END: no row read (0 opens), all 7 rows timed (REVIEW, not FAIL)");
	}

	/* 8. a failure before the real rows (a decoy row, or anything that set the stop) means no real open at all */
	{
		for (i = 0; i < NBASE; i++)
			order[i] = i;
		setup(order, NBASE);
		hash_fail = 1;				/* as after a failed decoy row (/dev/ram1 ...) */
		rows_not_read = 0;
		content_rows_device();
		check(read_log(l) == 0 && rows_not_read == 9,
		      "a failure before the real rows: R1-R5, R6, R7d, R8 all 'not read' (9), 0 opens");
	}

	/* 9. node_open_allowed fails closed and re-identifies by the device at the moment of use */
	{
		struct node cached_empty = { "/dev/fake/sda2", "", 0, 1 };	/* discovery cached no name; the device is persist */
		struct node unknown = { "/dev/fake/nothere", "", 0, 1 };	/* a partition that cannot be identified */
		struct node lun = { "/dev/fake/sda", "", 1, 1 };		/* a whole LUN */

		for (i = 0; i < NBASE; i++)
			order[i] = i;
		setup(order, NBASE);
		check(!node_open_allowed(&cached_empty) && !node_open_allowed(&unknown) && node_open_allowed(&lun),
		      "node_open_allowed: persist refused even with an empty cached name; an unidentifiable partition refused; "
		      "a whole LUN allowed (Q target, no content read)");
	}

	/* 10. K1g r3 (J-207), the 4K regression: every fake node has 4096-byte logical blocks (as the Quest 3's UFS LUNs);
	 *     each row alone (no stop between them), then the whole pass: R3 dtbo_a (12,564 bytes), R4 vbmeta_a (5,632)
	 *     and R5 vbmeta_system_a (3,136) are not multiples of 4096; R1, R2, misc and devinfo are. The r2 code rounded
	 *     to 512 bytes (12,800 / 5,632 / 3,584) and failed R3 with EINVAL on Unit 2. Then the same with 512-byte
	 *     blocks (the fixed 4096 rounding serves both) */
	{
		static const struct { const char *part, *path; uint64_t range, rd; } rr[] = {
			{ "boot_a", "/dev/fake/sde14", 61607936, 790528 }, { "vendor_boot_a", "/dev/fake/sde22", 5058560, 864256 },
			{ "dtbo_a", "/dev/fake/sde16", 12564, 16384 }, { "vbmeta_a", "/dev/fake/sde17", 5632, 8192 },
			{ "vbmeta_system_a", "/dev/fake/sde18", 3136, 4096 }, { "misc", "/dev/fake/sda9", 1048576, 1048576 },
			{ "devinfo", "/dev/fake/sde9", 4096, 4096 } };
		int lbsv, ok;

		for (lbsv = 0; lbsv < 2; lbsv++) {
			fake_lbs = lbsv ? 512 : 4096;
			for (i = 0; i < NBASE; i++)
				order[i] = i;
			setup(order, NBASE);
			for (k = 0; k < 7; k++) {
				struct hres hr;
				char want_line[96];
				int rc, n, j, aligned = 1, lastok = 0;
				FILE *f;
				char ln[160];

				truncate(readlog, 0);
				rc = hash_node(rr[k].path, 0, rr[k].range, 10, &hr);
				if (!rc && hr.err)
					rc = -hr.err;
				/* every read on the node: offset and length multiples of 4096 (the fixed rounding, also on a
				 * 512-byte device); the last read (the tail of the range) has the rounded length */
				snprintf(want_line, sizeof(want_line), "%s ", rr[k].path);
				n = 0;
				if ((f = fopen(readlog, "r"))) {
					while (fgets(ln, sizeof(ln), f)) {
						long long o = 0;
						size_t len = 0;

						if (strncmp(ln, want_line, strlen(want_line)))
							continue;
						n++;
						if (sscanf(ln + strlen(want_line), "%lld %zu", &o, &len) != 2 || (o % 4096) || (len % 4096))
							aligned = 0;
						lastok = len == rr[k].rd;
					}
					fclose(f);
				}
				for (j = 0; j < 5 && strcmp(rootread_rows[j].name, rr[k].part); j++)
					;
				ok = !rc && hr.got == rr[k].range && hr.want == rr[k].range && n > 0 && aligned && lastok &&
				     (j == 5 || !strcmp(hr.hex, rootread_rows[j].sha));
				check(ok, "%4u-byte blocks, %-15s range %8llu: %s (%d read(s), last %zu bytes expected, all 4096-aligned: %s)",
				      fake_lbs, rr[k].part, (unsigned long long)rr[k].range,
				      rc ? strerror(-rc) : "hashed exactly the range", n, (size_t)rr[k].rd, aligned ? "yes" : "NO");
			}
			for (i = 0; i < NBASE; i++)
				order[i] = i;
			setup(order, NBASE);
			content_rows_device();
			check(hash_fail == 0 && n_hashes == 7 && log_is_prefix(9),
			      "%4u-byte blocks: the whole content pass (R1-R5, R6, R7d, R8) passes, 9 opens, the 7 rows hashed",
			      fake_lbs);
		}
		fake_lbs = 4096;
	}

	/* 11. a rounded read that would pass the end of the node fails closed: a node exactly as long as its unaligned
	 *     range (R3, R4, R5) is refused before any read is issued on it, and no later row is opened. Such a node
	 *     cannot exist on a 4096-byte-block device (its size would not be a multiple of the block size): this is
	 *     the defensive path, kept closed */
	{
		static const char *const parts[] = { "dtbo_a", "vbmeta_a", "vbmeta_system_a" };
		static const uint64_t len[] = { 12564, 5632, 3136 };
		int pos;

		for (pos = 0; pos < 3; pos++) {
			struct fake *f;
			char cmd[400];
			int nreads = 0;
			FILE *rf;
			char ln[160];

			for (i = 0; i < NBASE; i++)
				order[i] = i;
			setup(order, NBASE);
			f = fake_by_part(parts[pos]);
			snprintf(cmd, sizeof(cmd), "truncate -s %llu %s", (unsigned long long)len[pos], f->file);
			if (system(cmd))
				exit(3);
			content_rows_device();
			if ((rf = fopen(readlog, "r"))) {
				while (fgets(ln, sizeof(ln), rf))
					nreads += !strncmp(ln, f->path, strlen(f->path)) && ln[strlen(f->path)] == ' ';
				fclose(rf);
			}
			{
				struct hres hr;
				int pre = hash_fail > 0 && n_hashes == pos + 2 && log_is_prefix(pos + 3) && nreads == 0;
				int rc = hash_node(f->path, 0, len[pos], 10, &hr);	/* again, alone: its reason */

				if (!rc && hr.err)
					rc = -hr.err;
				check(pre && rc == -ERANGE,
				      "node of exactly %llu bytes (%s): the rounded read would pass its end: refused before any "
				      "read (%d reads; %s), %d open(s), none after it", (unsigned long long)len[pos], parts[pos],
				      nreads, rc == -ERANGE ? "ERANGE, its own reason" : strerror(-rc), pos + 3);
			}
		}
	}

	/* 12. a read that returns at least the row's bytes but less than its aligned length fails closed (the r3 code
	 *     requires the whole aligned length; the r2 code accepted any count >= the row's bytes). 512-byte blocks,
	 *     so that the r2 code's own 12,800-byte read is allowed and the case tells the two apart */
	{
		fake_lbs = 512;
		for (i = 0; i < NBASE; i++)
			order[i] = i;
		setup(order, NBASE);
		short_path = "/dev/fake/sde16";
		content_rows_device();
		short_path = NULL;
		fake_lbs = 4096;
		check(hash_fail > 0 && n_hashes == 2 && log_is_prefix(3),
		      "dtbo_a: a read that returns 236 bytes less than asked (still >= the 12564 needed) fails closed; no later open");
	}

	snprintf(logpath, sizeof(logpath), "rm -rf %s", tdir);
	if (system(logpath))
		return 3;
	fprintf(stderr, "TOTAL: %d cases, %d failed\n", cases, fails);
	return fails != 0;
}
