/*
 * FrameShift stage 3a — before/after harness for the v0.4 review fixes.
 * Offline only. Compiles a given fs-pattern.c (v0.3 or v0.4) into the same
 * requirement checks, so one test fails on v0.3 and passes on v0.4:
 *
 *   clang ... -DFSP_UNIT_TEST -DHV=3 '-DFSP_SRC="build/prev/fs-pattern-0.3.c"' tools/policy_harness.c
 *   clang ... -DFSP_UNIT_TEST -DHV=4 '-DFSP_SRC="src/fs-pattern.c"'           tools/policy_harness.c
 *
 * Requirements checked (second review, should-fix 1 and 2):
 *   H1 a no-modeset (plane swap) attempt only on the current mode of an ACTIVE
 *      CRTC whose mode is in the connector list and progressive
 *   H2 an ALLOW_MODESET attempt only with exactly 4128x2208@90 progressive
 *   H3 a current mode is only ever chosen if in the list and progressive
 *   H4 empty strings never produce an empty value ("k= ")
 *   plus positive cases that must still produce attempts (both versions).
 */
#define main fsp_embedded_main
#include FSP_SRC
#undef main
#include <stdio.h>

static int fails;
static void chk(const char *name, int ok, const char *detail)
{
	printf("H %s %s %s\n", name, ok ? "PASS" : "FAIL", detail);
	if (!ok) fails++;
}
static struct drm_mode_modeinfo mkm(int w, int h, int r, int fl)
{
	struct drm_mode_modeinfo m;
	memset(&m, 0, sizeof(m));
	m.hdisplay = (uint16_t)w; m.vdisplay = (uint16_t)h; m.vrefresh = (uint32_t)r; m.flags = (uint32_t)fl;
	m.clock = (uint32_t)(r * 1000);
	return m;
}

struct sc {
	const char *name;
	int cur_valid, active, cur_in_list, list_has_expected;
	struct drm_mode_modeinfo cur;
	int must_have_attempts;
};

int main(void)
{
	crc_init();
	struct drm_mode_modeinfo E = mkm(4128, 2208, 90, 0);
	struct sc S[] = {
		{ "splash_typical",          1, 1, 1, 1, mkm(4128, 2208, 90, 0), 1 },
		{ "no_current_expected",     0, 0, 0, 1, mkm(0, 0, 0, 0), 1 },
		{ "current_inactive",        1, 0, 1, 1, mkm(4128, 2208, 90, 0), 1 },
		{ "current_not_in_list",     1, 1, 0, 1, mkm(4128, 2208, 60, 0), 1 },
		{ "current_interlaced",      1, 1, 1, 1, mkm(4128, 2208, 90, DRM_MODE_FLAG_INTERLACE), 1 },
		{ "current_72hz_in_list",    1, 1, 1, 1, mkm(4128, 2208, 72, 0), 1 },
		{ "current_72hz_no_expected",1, 1, 1, 0, mkm(4128, 2208, 72, 0), 1 },
	};
	for (unsigned k = 0; k < sizeof(S) / sizeof(S[0]); k++) {
		struct sc *s = &S[k];
		struct drm_mode_modeinfo L[3];
		uint32_t n = 0;
		if (s->list_has_expected) L[n++] = E;
		if (s->cur_valid && s->cur_in_list && !(s->list_has_expected && mode_eq(&s->cur, &E))) L[n++] = s->cur;
		const struct drm_mode_modeinfo *cur = s->cur_valid ? &s->cur : NULL;
		struct attempt A[4];
		int na;
#if HV == 3
		struct mode_pick p = pick_mode(L, n, cur);
		struct drm_mode_modeinfo mode = p.use_current ? s->cur : (p.idx >= 0 ? L[p.idx] : mkm(0, 0, 0, 0));
		int any = p.use_current || p.idx >= 0;
		na = any ? plan_attempts(s->cur_valid, 1, A) : 0;
#else
		struct mode_pick p = pick_mode(L, n, cur, s->active);
		struct drm_mode_modeinfo mode = p.use_current ? s->cur : (p.idx >= 0 ? L[p.idx] : mkm(0, 0, 0, 0));
		int any = p.use_current || p.idx >= 0;
		na = any ? plan_attempts(p.use_current, is_expected_mode(&mode), 1, A) : 0;
#endif
		int h1 = 1, h2 = 1, h3 = 1;
		for (int i = 0; i < na; i++) {
			if (!A[i].modeset && !(p.use_current && s->active && s->cur_in_list &&
					       !(s->cur.flags & DRM_MODE_FLAG_INTERLACE)))
				h1 = 0;
			if (A[i].modeset && !is_expected_mode(&mode))
				h2 = 0;
		}
		if (p.use_current && (!s->cur_in_list || (s->cur.flags & DRM_MODE_FLAG_INTERLACE)))
			h3 = 0;
		char d[96];
		snprintf(d, sizeof(d), "use_current=%d idx=%d attempts=%d mode=%ux%u@%u", p.use_current, p.idx, na,
			 mode.hdisplay, mode.vdisplay, mode.vrefresh);
		char nm[96];
		snprintf(nm, sizeof(nm), "H1_noms_only_active_current.%s", s->name); chk(nm, h1, d);
		snprintf(nm, sizeof(nm), "H2_modeset_only_expected.%s", s->name);    chk(nm, h2, d);
		snprintf(nm, sizeof(nm), "H3_current_in_list_progressive.%s", s->name); chk(nm, h3, d);
		if (s->must_have_attempts) {
			snprintf(nm, sizeof(nm), "H5_still_attempts.%s", s->name); chk(nm, na > 0, d);
		}
	}
	/* H4: empty strings */
	memcpy(g_nonce, "0badc0de", 9);
	char zeros[DRM_DISPLAY_MODE_LEN + 1];
	memset(zeros, 0, sizeof(zeros));
	rec_begin("e", 0); kv_str("name", zeros, sizeof(zeros)); rec_frame();
	chk("H4_no_empty_value", strstr(g_line, "= ") == NULL, "zeroed mode name");
	printf("H_TOTAL failures=%d\n", fails);
	return fails ? 1 : 0;
}
