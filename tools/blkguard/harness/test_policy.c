// SPDX-License-Identifier: GPL-2.0-only
/*
 * Userspace harness for the fs-blkguard decision logic.  Compiles the
 * kernel's block/fs-blkguard-policy.h unchanged (extracted from the patch by
 * run.sh) and checks it exhaustively where the domain is small.
 *
 * Copyright (C) 2026 FrameShift contributors
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
#include "fs-blkguard-policy.h"

static int fails, checks;

#define CHECK(cond, ...)                                                \
	do {                                                            \
		checks++;                                               \
		if (!(cond)) {                                          \
			fails++;                                        \
			printf("FAIL %s:%d: ", __FILE__, __LINE__);     \
			printf(__VA_ARGS__);                            \
			printf("\n");                                   \
		}                                                       \
	} while (0)

static int marker_calls;
static bool marker_yes(void *ctx) { marker_calls++; (void)ctx; return true; }
static bool marker_no(void *ctx) { marker_calls++; (void)ctx; return false; }

static struct fsbg_policy pol(const char *req)
{
	struct fsbg_policy p;

	if (fsbg_parse(req, strlen(req), &p)) {
		printf("FAIL: cannot parse '%s'\n", req);
		exit(2);
	}
	return p;
}

/* Quest 3 Unit 2 v2.7 GPT, as measured (devices/quest3/evidence/unit2-v27-baseline-20261012). */
struct qpart { const char *disk, *name; };
static const struct qpart quest3[] = {
	{"sda","ssd"},{"sda","persist"},{"sda","vision"},{"sda","misc"},{"sda","keystore"},
	{"sda","frp"},{"sda","super"},{"sda","vbmeta_system_a"},{"sda","vbmeta_system_b"},
	{"sda","metadata"},{"sda","userdata"},
	{"sdb","xbl_a"},{"sdb","xbl_config_a"},{"sdb","multiimgoem_a"},{"sdb","apdp"},
	{"sdc","xbl_b"},{"sdc","xbl_config_b"},{"sdc","multiimgqti_b"},{"sdc","multiimgoem_b"},
	{"sdd","ALIGN_TO_128K_1"},{"sdd","cdt"},{"sdd","ddr"},
	{"sde","uefi_a"},{"sde","aop_a"},{"sde","aop_config_a"},{"sde","tz_a"},{"sde","hyp_a"},
	{"sde","adsp_a"},{"sde","abl_a"},{"sde","keymaster_a"},{"sde","boot_a"},{"sde","devcfg_a"},
	{"sde","qupfw_a"},{"sde","vbmeta_a"},{"sde","dtbo_a"},{"sde","uefisecapp_a"},
	{"sde","imagefv_a"},{"sde","ovrtz_a"},{"sde","shrm_a"},{"sde","cpucp_a"},
	{"sde","featenabler_a"},{"sde","vendor_boot_a"},{"sde","recovery_a"},{"sde","uefi_b"},
	{"sde","aop_b"},{"sde","aop_config_b"},{"sde","tz_b"},{"sde","hyp_b"},{"sde","adsp_b"},
	{"sde","abl_b"},{"sde","keymaster_b"},{"sde","boot_b"},{"sde","devcfg_b"},{"sde","qupfw_b"},
	{"sde","vbmeta_b"},{"sde","dtbo_b"},{"sde","uefisecapp_b"},{"sde","imagefv_b"},
	{"sde","ovrtz_b"},{"sde","shrm_b"},{"sde","cpucp_b"},{"sde","featenabler_b"},
	{"sde","vendor_boot_b"},{"sde","recovery_b"},{"sde","devinfo"},{"sde","dip"},
	{"sde","splash"},{"sde","limits"},{"sde","limits-cdsp"},{"sde","xbl_ramdump"},
	{"sde","pstore"},{"sde","storsec"},{"sde","uefivarstore"},{"sde","secdata"},
	{"sde","vm-data"},{"sde","mdcompress"},{"sde","connsec"},{"sde","tzsc"},{"sde","spunvm"},
	{"sde","rtice"},{"sde","xbl_sc_test_mode"},{"sde","xbl_sc_logs"},
	{"sdf","ALIGN_TO_128K_2"},{"sdf","modemst1"},{"sdf","modemst2"},{"sdf","fsg"},{"sdf","fsc"},
};
#define NQ (sizeof(quest3) / sizeof(quest3[0]))

static bool disk_has_marker(const char *disk)
{
	size_t i;

	for (i = 0; i < NQ; i++)
		if (!strcmp(quest3[i].disk, disk) && fsbg_name_protected(quest3[i].name))
			return true;
	return false;
}
static const char *cur_disk;
static bool marker_quest(void *ctx) { (void)ctx; return disk_has_marker(cur_disk); }

static void test_names(void)
{
	static const char *yes[] = { "xbl", "xbl_a", "xbl_b", "xbl_config_a", "tz_b",
		"vbmeta_system_a", "limits-cdsp", "boot_a", "boot", "persist", "modemst1",
		"fsg", "super", "misc", "frp", "devinfo", "init_boot_a", "recovery_b" };
	static const char *no[] = { "", "userdata", "xbl_c", "XBL_A", "xbl_ab", "bootx",
		"_a", "a_a", "boo", "fsbg_decoy_rw", "fsbg_decoy_ro", "persist2", "tz_",
		"system_a", "vendor_a", "ALIGN_TO_128K_1" };
	size_t i;

	for (i = 0; i < sizeof(yes) / sizeof(*yes); i++)
		CHECK(fsbg_name_protected(yes[i]), "'%s' should be protected", yes[i]);
	for (i = 0; i < sizeof(no) / sizeof(*no); i++)
		CHECK(!fsbg_name_protected(no[i]), "'%s' should not be protected", no[i]);
	CHECK(!fsbg_name_protected(NULL), "NULL name");
	CHECK(!fsbg_name_protected("userdata"), "userdata must never be protected (C6)");
}

static void test_quest3_table(void)
{
	struct fsbg_policy prot = pol("protect"), strict = pol("strict allow=disk:ram0");
	struct fsbg_policy prod = pol("protect allow=part:userdata");
	const char *disks[] = { "sda", "sdb", "sdc", "sdd", "sde", "sdf" };
	size_t i;
	int r;

	/* every boot-storage disk is a marker disk */
	for (i = 0; i < 6; i++)
		CHECK(disk_has_marker(disks[i]), "%s should carry a protected name", disks[i]);
	for (i = 0; i < 6; i++) {
		cur_disk = disks[i];
		CHECK(fsbg_reason_denies(fsbg_verdict(&prot, disks[i], NULL, marker_quest, 0)),
		      "protect: whole %s", disks[i]);
		CHECK(fsbg_reason_denies(fsbg_verdict(&strict, disks[i], NULL, marker_quest, 0)),
		      "strict: whole %s", disks[i]);
		CHECK(fsbg_reason_denies(fsbg_verdict(&prod, disks[i], NULL, marker_quest, 0)),
		      "product: whole %s", disks[i]);
	}
	/* every partition denied in protect and strict; only userdata open in product */
	for (i = 0; i < NQ; i++) {
		cur_disk = quest3[i].disk;
		r = fsbg_verdict(&prot, quest3[i].disk, quest3[i].name, marker_quest, 0);
		CHECK(fsbg_reason_denies(r), "protect: %s %s r=%d", quest3[i].disk, quest3[i].name, r);
		r = fsbg_verdict(&strict, quest3[i].disk, quest3[i].name, marker_quest, 0);
		CHECK(fsbg_reason_denies(r), "strict: %s %s r=%d", quest3[i].disk, quest3[i].name, r);
		r = fsbg_verdict(&prod, quest3[i].disk, quest3[i].name, marker_quest, 0);
		if (!strcmp(quest3[i].name, "userdata"))
			CHECK(r == FSBG_R_ALLOW_LISTED, "product: userdata should be allowed r=%d", r);
		else
			CHECK(fsbg_reason_denies(r), "product: %s %s r=%d", quest3[i].disk,
			      quest3[i].name, r);
	}
	/* an unnamed or new partition on boot storage stays denied */
	cur_disk = "sde";
	r = fsbg_verdict(&prot, "sde", "", marker_quest, 0);
	CHECK(r == FSBG_R_DENY_MARKER_DISK, "protect: unnamed partition on sde r=%d", r);
	r = fsbg_verdict(&prod, "sde", "newfirmware_a", marker_quest, 0);
	CHECK(r == FSBG_R_DENY_MARKER_DISK, "product: unknown name on sde r=%d", r);
	r = fsbg_verdict(&prod, "sde", "", marker_quest, 0);
	CHECK(r == FSBG_R_DENY_MARKER_DISK, "product: unnamed on sde r=%d", r);
}

static void test_order(void)
{
	struct fsbg_policy p = pol("strict allow=disk:ram0,disk:sde,part:fsbg_decoy_rw");
	struct fsbg_policy forged = p;
	int r;

	/* protected names win over a (forged) allowlist entry */
	forged.allow[forged.n_allow].kind = FSBG_ALLOW_PART;
	strcpy(forged.allow[forged.n_allow++].name, "xbl_a");
	marker_calls = 0;
	r = fsbg_verdict(&forged, "sdb", "xbl_a", marker_yes, 0);
	CHECK(r == FSBG_R_DENY_PROTECTED, "forged allow of xbl_a r=%d", r);
	CHECK(marker_calls == 0, "marker should not be consulted for a protected name");
	/* the whole-disk node of boot storage wins over disk: allowlisting */
	r = fsbg_verdict(&p, "sde", NULL, marker_yes, 0);
	CHECK(r == FSBG_R_DENY_MARKER_WHOLE, "allowlisted whole marker disk r=%d", r);
	/* allowlist hits */
	r = fsbg_verdict(&p, "ram0", NULL, marker_no, 0);
	CHECK(r == FSBG_R_ALLOW_LISTED, "ram0 r=%d", r);
	marker_calls = 0;
	r = fsbg_verdict(&p, "loop6", "fsbg_decoy_rw", marker_yes, 0);
	CHECK(r == FSBG_R_ALLOW_LISTED, "part allowlist on a marker disk r=%d", r);
	CHECK(marker_calls == 0, "marker consulted for a listed partition");
	/* disk: entries cover the whole-disk node only, not its partitions */
	r = fsbg_verdict(&p, "ram0", "", marker_no, 0);
	CHECK(r == FSBG_R_DENY_STRICT, "partition of an allowlisted disk r=%d", r);
	/* strict denies everything else */
	r = fsbg_verdict(&p, "ram1", NULL, marker_no, 0);
	CHECK(r == FSBG_R_DENY_STRICT, "ram1 strict r=%d", r);
	r = fsbg_verdict(&p, "dm-0", NULL, marker_no, 0);
	CHECK(r == FSBG_R_DENY_STRICT, "dm-0 strict r=%d", r);
	r = fsbg_verdict(&p, "zram0", NULL, marker_no, 0);
	CHECK(r == FSBG_R_DENY_STRICT, "zram0 strict r=%d", r);
	r = fsbg_verdict(&p, "loop6", "fsbg_decoy_ro", marker_yes, 0);
	CHECK(r == FSBG_R_DENY_STRICT, "unlisted partition strict r=%d", r);
}

static void test_modes(void)
{
	struct fsbg_policy off = { .mode = FSBG_OFF };
	struct fsbg_policy prot = pol("protect");
	int r;

	marker_calls = 0;
	CHECK(fsbg_verdict(&off, "sdb", "xbl_a", marker_yes, 0) == FSBG_R_ALLOW_OFF, "off allows");
	CHECK(fsbg_verdict(&off, "sdb", NULL, marker_yes, 0) == FSBG_R_ALLOW_OFF, "off allows whole");
	CHECK(marker_calls == 0, "off consults nothing");
	r = fsbg_verdict(&prot, "sdx", NULL, marker_no, 0);
	CHECK(r == FSBG_R_ALLOW_UNGUARDED, "protect: other disk whole r=%d", r);
	r = fsbg_verdict(&prot, "sdx", "data", marker_no, 0);
	CHECK(r == FSBG_R_ALLOW_UNGUARDED, "protect: other disk partition r=%d", r);
	r = fsbg_verdict(&prot, "ram1", NULL, marker_no, 0);
	CHECK(r == FSBG_R_ALLOW_UNGUARDED, "protect: ram1 r=%d", r);
	r = fsbg_verdict(&prot, "sdx", "boot", marker_yes, 0);
	CHECK(r == FSBG_R_DENY_PROTECTED, "protect: protected name anywhere r=%d", r);
}

static void test_cdb(void)
{
	static const u8 allowed[] = { 0x00, 0x03, 0x12, 0x1a, 0x25, 0x5a, 0xa0 };
	int op, sa, n_ok = 0;
	size_t k;

	for (op = 0; op < 256; op++)
		for (sa = 0; sa < 32; sa++) {
			u8 cdb[16] = { (u8)op, (u8)sa };
			bool want = false;

			for (k = 0; k < sizeof(allowed); k++)
				if (op == allowed[k])
					want = true;
			if (op == 0x9e && sa == 0x10)
				want = true;
			n_ok += fsbg_cdb_allowed(cdb, 16);
			CHECK(fsbg_cdb_allowed(cdb, 16) == want, "cdb %02x/%02x want %d", op, sa, want);
		}
	CHECK(n_ok == 7 * 32 + 1, "allowed (op, sa) pairs %d", n_ok);
	/* CDB length: nothing shorter than 6 bytes passes (sg SG_NEXT_CMD_LEN) */
	{
		u8 inq[16] = { 0x12 }, rc16[16] = { 0x9e, 0x10 };
		unsigned int L;

		for (L = 0; L < 6; L++) {
			CHECK(!fsbg_cdb_allowed(inq, L), "INQUIRY with %u-byte CDB", L);
			CHECK(!fsbg_cdb_allowed(rc16, L), "READ CAPACITY(16) with %u-byte CDB", L);
		}
		CHECK(fsbg_cdb_allowed(inq, 6), "INQUIRY with 6-byte CDB");
		CHECK(fsbg_cdb_allowed(rc16, 16), "READ CAPACITY(16) with 16-byte CDB");
	}
	/* named dangerous opcodes */
	{
		static const u8 bad[] = { 0x0a, 0x2a, 0xaa, 0x8a, 0x2e, 0x8e, 0x41, 0x93, 0x42,
			0x04, 0x3b, 0x15, 0x55, 0xb5, 0x85, 0xa1, 0x1b, 0x35, 0x91, 0x08, 0x28,
			0x88, 0xa8, 0x3c, 0xc0, 0xff };
		for (k = 0; k < sizeof(bad); k++) {
			u8 cdb[16] = { bad[k] };

			CHECK(!fsbg_cdb_allowed(cdb, 16), "opcode %02x must be refused", bad[k]);
		}
	}
}

static void test_parse(void)
{
	static const char *good[] = { "protect", "strict", "strict\n", "protect\n",
		"strict allow=disk:ram0", "strict allow=disk:ram0,part:userdata\n",
		"protect allow=part:userdata",
		"strict allow=disk:a,disk:b,disk:c,disk:d,disk:e,disk:f,disk:g,disk:h",
		"strict allow=disk:dm-200,part:fsbg_decoy_rw,disk:loop7",
		"strict allow=disk:0123456789012345678901234567890" };
	static const char *bad[] = { "", "\n", "off", "Strict", "strict ", "strictx",
		"strict\n\n", "strict allow=", "strict allow=disk:", "strict allow=disk:ram0,",
		"strict allow=foo:x", "strict allow=part:xbl_a", "strict allow=part:persist",
		"strict allow=part:boot_b", "strict allow=disk:ram 0", "strict allow=disk:ram/0",
		"strict allow=disk:a,disk:b,disk:c,disk:d,disk:e,disk:f,disk:g,disk:h,disk:i",
		"strict allow=disk:01234567890123456789012345678901",
		"strict  allow=disk:ram0", "strict allow=disk:ram0,,disk:ram1",
		"protect allow=part:" };
	struct fsbg_policy p;
	char longpart[96];
	size_t i;

	for (i = 0; i < sizeof(good) / sizeof(*good); i++)
		CHECK(!fsbg_parse(good[i], strlen(good[i]), &p), "should parse: '%s'", good[i]);
	for (i = 0; i < sizeof(bad) / sizeof(*bad); i++)
		CHECK(fsbg_parse(bad[i], strlen(bad[i]), &p), "should reject: '%s'", bad[i]);
	CHECK(fsbg_parse("strict\0allow=disk:x", 19, &p), "embedded NUL");
	memset(longpart, 'p', sizeof(longpart));
	memcpy(longpart, "strict allow=part:", 18);
	CHECK(!fsbg_parse(longpart, 18 + 63, &p), "63-char partition name");
	CHECK(fsbg_parse(longpart, 18 + 64, &p), "64-char partition name");
	fsbg_parse("strict allow=disk:ram0,part:userdata", 36, &p);
	CHECK(p.mode == FSBG_STRICT && p.n_allow == 2 && p.allow[0].kind == FSBG_ALLOW_DISK &&
	      !strcmp(p.allow[0].name, "ram0") && p.allow[1].kind == FSBG_ALLOW_PART &&
	      !strcmp(p.allow[1].name, "userdata"), "parsed contents");
}

static void test_parse_fuzz(void)
{
	static const char *tok[] = { "strict", "protect", " allow=", "disk:", "part:", ",",
		"ram0", "userdata", "xbl_a", "persist", "dm-200", "a", "_b", "-", ".", "\n",
		"/", " ", "=", ":", "0123456789abcdef0123456789abcdef", "x" };
	struct fsbg_policy p;
	char buf[256];
	unsigned int seed = 12345;
	int it, i, accepted = 0;

	for (it = 0; it < 2000000; it++) {
		int n = 0, k = 1 + (int)((seed = seed * 1103515245 + 12345) >> 16) % 12;

		/* half the inputs start with a valid head, to reach the entry parser */
		if (it & 1)
			n = snprintf(buf, sizeof(buf), "%s", (it & 2) ? "strict allow=" : "protect allow=");
		for (i = 0; i < k && n < 200; i++)
			n += snprintf(buf + n, sizeof(buf) - n, "%s",
				      tok[((seed = seed * 1103515245 + 12345) >> 16) % (sizeof(tok) / sizeof(*tok))]);
		if (fsbg_parse(buf, n, &p) == 0) {
			accepted++;
			CHECK(p.mode == FSBG_PROTECT || p.mode == FSBG_STRICT, "fuzz mode");
			CHECK(p.n_allow >= 0 && p.n_allow <= FSBG_MAX_ALLOW, "fuzz n_allow");
			for (i = 0; i < p.n_allow; i++) {
				size_t L = strnlen(p.allow[i].name, FSBG_NAME_MAX);

				CHECK(L > 0 && L < FSBG_NAME_MAX, "fuzz name length");
				CHECK(p.allow[i].kind == FSBG_ALLOW_DISK || p.allow[i].kind == FSBG_ALLOW_PART,
				      "fuzz kind");
				CHECK(!(p.allow[i].kind == FSBG_ALLOW_PART &&
					fsbg_name_protected(p.allow[i].name)), "fuzz protected allow");
			}
		}
	}
	CHECK(accepted > 1000, "fuzz reached the accept path only %d times", accepted);
	printf("fuzz: 2000000 token inputs, %d accepted, all well-formed\n", accepted);
}

static void test_transition(void)
{
	CHECK(fsbg_transition_ok(FSBG_PROTECT, false, FSBG_STRICT), "protect -> strict");
	CHECK(fsbg_transition_ok(FSBG_PROTECT, false, FSBG_PROTECT), "protect -> protect (seal)");
	CHECK(fsbg_transition_ok(FSBG_OFF, false, FSBG_PROTECT), "off -> protect");
	CHECK(fsbg_transition_ok(FSBG_OFF, false, FSBG_STRICT), "off -> strict");
	CHECK(!fsbg_transition_ok(FSBG_STRICT, false, FSBG_PROTECT), "strict -> protect");
	CHECK(!fsbg_transition_ok(FSBG_PROTECT, false, FSBG_OFF), "protect -> off");
	CHECK(!fsbg_transition_ok(FSBG_OFF, false, FSBG_OFF), "off -> off");
	CHECK(!fsbg_transition_ok(FSBG_PROTECT, true, FSBG_STRICT), "sealed");
	CHECK(!fsbg_transition_ok(FSBG_STRICT, true, FSBG_STRICT), "sealed strict");
	CHECK(!fsbg_transition_ok(FSBG_OFF, true, FSBG_STRICT), "sealed off");
}

int main(void)
{
	test_names();
	test_quest3_table();
	test_order();
	test_modes();
	test_cdb();
	test_parse();
	test_parse_fuzz();
	test_transition();
	printf("fs-blkguard policy harness: %d checks, %d failures\n", checks, fails);
	return fails ? 1 : 0;
}
