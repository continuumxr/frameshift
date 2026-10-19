/* fs-blkguard: the probe's SHA-256 code, timed (offline evidence for the K1g time budget, README s.5).
 * Builds fsbg-probe.c with its main renamed and times sha_upd() over a 64 MiB buffer, for the portable block
 * function and (aarch64 with HWCAP_SHA2) the ARMv8 one.  Prints MiB/s and, with the clock in MHz as argv[1],
 * cycles per byte.  Reads and writes nothing else.
 *   cc -O2 -o sha-bench sha-bench.c && ./sha-bench <MHz> */
#define main fsbg_probe_main
#include "../fsbg-probe.c"
#undef main

static double bench(void (*blk)(struct sha *, const uint8_t *), const uint8_t *buf, size_t n, char hex[65])
{
	struct sha s;
	double t0, t;

	sha_blk_fn = blk;
	sha_init(&s);
	t0 = now_s();
	sha_upd(&s, buf, n);
	sha_hex(&s, hex);
	t = now_s() - t0;
	return n / t / 1048576.0;
}

int main(int argc, char **argv)
{
	size_t n = 64u << 20, i;
	uint8_t *buf = malloc(n);
	double mhz = argc > 1 ? atof(argv[1]) : 0, r;
	char h1[65], h2[65];

	if (!buf)
		return 1;
	for (i = 0; i < n; i++)
		buf[i] = (uint8_t)(i * 2654435761u >> 24);
	r = bench(sha_blk, buf, n, h1);
	printf("portable  %.1f MiB/s%s", r, mhz > 0 ? "" : "\n");
	if (mhz > 0)
		printf("  %.1f cycles/byte at %.0f MHz\n", mhz * 1e6 / (r * 1048576.0), mhz);
#if defined(__aarch64__)
	sha_select();
	if (!strcmp(sha_impl, "armv8-ce")) {
		r = bench(sha_blk_ce, buf, n, h2);
		printf("armv8-ce  %.1f MiB/s (same digest: %s)\n", r, strcmp(h1, h2) ? "NO" : "yes");
	} else
		printf("armv8-ce  not used: %s\n", sha_impl);
#endif
	printf("digest    %s\n", h1);
	return 0;
}
