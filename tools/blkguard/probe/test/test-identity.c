/* fs-blkguard probe: unit test of the platform identity and the VM-only flag gate (FS-A-014 review: every VM-only
 * flag, fsbg.testkernel included, is refused on real hardware by a positive check). Builds fsbg-probe.c with its
 * main renamed and drives the pure decision functions with identity texts; reads and writes nothing.
 *   cc -O2 -o test-identity test-identity.c && ./test-identity     (exit 0: every case as expected) */
#define main fsbg_probe_main
#include "../fsbg-probe.c"
#undef main

static int fails, cases;

static void t(const char *name, const char *compat, int n, const char *model, const char *cmdline,
	      const char *cpuinfo, int want_quest, int want_vm, int want_refused)
{
	int q = ident_is_quest(compat, n, model, cmdline);
	int v = ident_is_vm(compat, n, model, cmdline, cpuinfo);
	const char *why = vm_flag_gate(1, v, q);
	int ok = q == want_quest && v == want_vm && (why != NULL) == want_refused;

	/* the gate never refuses the default device mode (no VM-only flag) */
	ok = ok && vm_flag_gate(0, v, q) == NULL;
	cases++;
	if (!ok)
		fails++;
	printf("%s  %-58s quest=%d vm=%d flags:%s\n", ok ? "PASS" : "FAIL", name, q, v, why ? "refused" : "allowed");
}

#define S(x) x, (int)sizeof(x) - 1		/* a NUL-separated compatible list and its length */

int main(void)
{
	static const char cmd_quest[] = "loglevel=6 kernel.panic_on_rcu_stall=1 loop.max_part=7 pcie_ports=compat "
		"service_locator.enable=1 msm_rtb.filter=0x237 cpufreq.default_governor=performance "
		"msm_drm.dsi_display0=meta,eureka_panel_sharp: rootwait ro init=/init qcom_dload_mode.download_mode=1 "
		"fsbg.testkernel";
	static const char cmd_qemu[] = "console=ttyAMA0 loglevel=3 rdinit=/init panic=-1 fsbg.testkernel";

	/* a Quest: by its device tree (any one marker), by its model, or by the stock DTB boot arguments */
	t("Quest DT compatible meta,eureka + qcom SoC", S("meta,eureka\0qcom,anorak"), "", cmd_qemu, "", 1, 0, 1);
	t("DT compatible qcom only", S("qcom,sxr2230p"), "", cmd_qemu, "", 1, 0, 1);
	t("DT compatible oculus only", S("oculus,eureka"), "", cmd_qemu, "", 1, 0, 1);
	t("DT model 'Meta Quest 3' (compatible unreadable)", "", 0, "Meta Quest 3", cmd_qemu, "", 1, 0, 1);
	t("DT model 'Qualcomm Technologies, Inc. ...'", "", 0, "Qualcomm Technologies, Inc. Anorak", cmd_qemu, "", 1, 0, 1);
	t("no DT, the Quest's stock boot arguments", "", 0, "", cmd_quest, "", 1, 0, 1);
	t("no DT, qcom_dload_mode alone", "", 0, "", "rdinit=/init qcom_dload_mode.download_mode=1 fsbg.vm", "", 1, 0, 1);
	/* a Quest marker anywhere wins over a VM marker */
	t("dummy-virt compatible but a Quest boot argument", S("linux,dummy-virt"), "", "msm_drm.dsi_display0=meta fsbg.vm", "", 1, 0, 1);
	t("dummy-virt next to qcom in the compatible list", S("linux,dummy-virt\0qcom,foo"), "", cmd_qemu, "", 1, 0, 1);
	t("UML cpuinfo but a Quest DT", S("meta,eureka"), "", cmd_qemu, "User Mode Linux", 1, 0, 1);
	/* not positively a VM: refused too */
	t("no DT, no identity at all", "", 0, "", "fsbg.testkernel", "processor : 0", 0, 0, 1);
	t("another DT (not dummy-virt)", S("raspberrypi,4-model-b\0brcm,bcm2711"), "", cmd_qemu, "", 0, 0, 1);
	t("a DT that says nothing", S(""), "", cmd_qemu, "", 0, 0, 1);
	/* the test VMs: allowed */
	t("QEMU virt (linux,dummy-virt)", S("linux,dummy-virt"), "linux,dummy-virt", cmd_qemu, "", 0, 1, 0);
	t("User-Mode Linux (no DT)", "", 0, "", "fsbg.vm", "vendor_id : User Mode Linux", 0, 1, 0);
	printf("TOTAL: %d cases, %d failed\n", cases, fails);
	return fails != 0;
}
