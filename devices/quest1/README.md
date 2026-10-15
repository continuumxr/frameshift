# Meta Quest 1

*Edited for publication: names and links removed or paraphrased.*

**Queued — fifth target** (order Quest 3 → Quest 2 → Quest Pro → Quest 3S →
Quest 1 → XR Elite, FS-R-006 §1; it was "third" under the 2026-10-07 order).
No Quest 1 work is active. MSM8998 / Snapdragon 835 **[D]**, from the PM's
existing Quest 1 material (read-only, not in this repository).

**Firmware: v50 is the final build (end of life; PM, 2026-10-10).** The
Quest 1 build target is therefore v50, not v2.7; Meta's stock v50 ABL is
used.

**Prior art:** `nicolas-riera/Quest1-SteamOS` already boots SteamOS Holo.
- Meta's 4.4 kernel, rebuilt with systemd backports and LSE-atomics
  emulation (the CPUs are ARMv8.0).
- Adreno 540 through libhybris.
- An fbdev display path.

The expected approach is to adopt and adapt that work, with our shared
userspace layer (JOURNAL J-26).

**Performance envelope** [M-static, Meta firmware tables]:
- **CPU:** 1.90/2.30 GHz. Some chip bins go to 2.59 GHz, but Meta never
  shipped it, so it is excluded.
- **GPU:** 710 MHz.

**Refresh rate:** shipped at 72 Hz. The panels are reported capable of
90 Hz: Carmack at Oculus Connect 6 (2019) said 72 Hz was kept for
performance and 90 Hz was not FCC-certified [C, press report:
engadget.com/2019/09/26/john-carmack-oculus-connect-cto-keynote/]. The PM
reports a community mod that enabled 90 Hz: **`Juspertinry/q1-modules`,
`q1_90hz`** (MIT, v4.2, Quest 1 v50 only) [M-static, read 2026-10-09]. It
includes `tools/dtpatch.py`, which retimes the DSI panel in the boot
image's appended DTBs by changing **only the refresh rate and the
horizontal front porch** (DSC config and the DDIC init sequence untouched,
size-preserving edits), and a boot-time panel-clock resync. For
FrameShift the DT part is the relevant method: we own the DT, so
90 Hz is a DT timing change, verified on hardware later. PM
requirement: 90 Hz default, so 90 Hz is a Quest 1 target, verified from its
DT/panel driver (checklist E4), with the certification note kept.

**Safety:**
- The stock kernel defaults to the **`performance`** governor.
- The fan reportedly stops on POWERDOWN blank [C, Quest1-SteamOS fork report; `docs/research/FS-A-006-quest-projects.md`].
- **Never stop the modem once started.**
- The cells are about 7 years old.

See `docs/research/perf-envelope-quest1-2.md` and
`docs/DEVICE_PORT_CHECKLIST.md`.

Per-device boot, kernel, DT, driver and recovery material for this target lives
here. Common userspace and build infrastructure stays outside `devices/`
(`docs/PROJECT_SETUP.md` §1.2).
