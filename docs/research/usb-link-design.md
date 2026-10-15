# USB device-mode ("gadget") stack under SteamOS on the Quest (PD-8)

**Status:** research only, 2026-10-14. **Revision 1** applies the adversarial review
(GO-with-fixes); the change list is at the end. No device was touched.

Valve files were read in `~/sfroot-full` (Valve build `20260922.6152327`) for names, unit logic,
package metadata and `strings` identifiers only. **No third-party binary was disassembled**
(J-90, J-120). Nothing of Valve's is copied here beyond identifiers and short descriptions.

Tags: **[M]** measured on hardware · **[M-static]** read from a named artifact · **[D]** derived ·
**[C]** plausible, unconfirmed · **[O]** open.

**This revises PD-8.** `stage3-4-plan.md` §6 recommended "ours for now". This note keeps ours
for the first runs, then moves to Valve's stack once the hardware tests in §8 pass.

---

## 0. Answer in brief

- **(a) Development images: staged.**
  - **Stage A (now; the first R-1 runs).**
    - Our ACM console runs in our initramfs, then as **our own `fs` gadget** under Valve's
      userspace.
    - Valve's gadget is held off by **one** cmdline mask: `systemd.mask=usb-gadget.target`.
      No Valve file changes.
  - **Stage B (after tests U1–U6 pass).**
    - Hybrid: Valve's stack owns the UDC after `switch_root`, with the mandatory Quest drop-ins
      (§2).
    - Developer Mode is turned on **by Valve's own helper**.
    - A dev fallback unit binds our `fs` ACM if Valve's gadget fails or does not bind within
      N seconds.
- **(b) Shipped product: Valve's stack plus the Quest drop-ins.**
  - The drop-ins: identity with a per-unit serial; the adbd-post fix; the MAC seed.
  - The eMarker role handler is added only if U4 shows it is needed.
  - No FrameShift debug function in user images. Developer Mode governs USB as on the Frame.
- **Not literally 100 % pure.** The Quest's 5.10 kernel makes Valve's adbd-post fail at every
  boot when Developer Mode is off (§2.1), so one fix is **mandatory**. Identity and the MAC seed
  are needed as well. None of these edits a Valve file.

## 1. What the Frame's stack is [M-static]

| piece | package (licence) | what it does |
|---|---|---|
| `usb-gadget-init.service`, `usb-gadget.service`, `usb-gadget-tools/*.sh` | `usb-gadget-tools` (MIT) | builds configfs gadget `g1` from `USB_GADGET_*` env; binds the first UDC; binds nothing if no function is linked |
| `usb-gadget-init.service.d/usb-gadget.conf` | `steamos-customizations-deckard` (LGPLv2+) | identity: `28de:2460`, "Valve", "Steam Frame", serial `%H` (`/etc/hostname` = `frame`) |
| `adbd{,-pre,-post}.service`, `dev-usb\x2dffs-adb.mount`, `adbd` | `android-platform-tools` (Apache-2.0) | FunctionFS `ffs.adb`; adbd as `steamos`, `ADB_ALLOW_ROOT=true` |
| `usb-gadget.service.d/usb-gadget-adbd-restart.conf` | same | `PartOf=adbd.service`: any adbd restart (e.g. `adb root`) **rebinds the whole gadget**, so NCM drops too |
| `adbd.service.d/adbd.conf` | `steamos-customizations-deckard` | adbd runs only with u-boot DT flags **or** the Developer Mode sentinel file. **Only `adbd.service` carries this condition** |
| `usb-ncm-gadget@`, `usb-ncm-dnsmasq@`, `usr/share/deckard/usb-ncm-*.sh` | same | NCM `usbN`; device `10.86.20N.233/29`, PC `.234`; firewalld zone `nm-shared`; Developer Mode condition |
| `typec-plug-event.rules` + `.sh` | same | on partner add: wait 1 s, read `data_role`. If `[device]`: `systemctl enable usb-ncm-gadget@usbN` and start `usb-gadget.target`. Otherwise: stop `usb-gadget.service`. **Escape hatch:** `/tmp/usb_gadget_block` or `/tmp/adbd_block` skips everything |
| `steamos-devkit-mode` | `deckard-hw-support` (Proprietary) | **Developer Mode**. `--enable` enables sshd, xrdp, `steamos-devkit-service` and the two CEF port-forwards; writes a coredump conf and the adbd sentinel. It exits early if `/etc/steamos-devkit-enabled` already exists. **Steam calls it at every startup** to assert `DevModeEnabled` from `config.vdf`. polkit: `allow_any=yes` |
| `softapmanager` (in `multi-user.target`, runs as root) | `softapmanager` (Proprietary) | identifiers include an `enablencm` command, `g1/functions/ncm.usb0`, `g1/UDC` and `systemctl restart adbd` [M-static, `strings`]: **a second writer of `g1`** outside the units |
| `initcpio/hooks/initrd_shell` + `00-adbd-restart.rules` + `adb_env` | `deckard-hw-support` | initramfs **rescue adb, as root**. Runs only on an initramfs failure (or `gotoinitrd`), after a typec plug; **auto-reboots after about 20 s** unless someone attaches. Not gated by Developer Mode |

Also: stock systemd's `99-systemd.rules` pulls `usb-gadget.target` whenever a UDC appears.
Only `usb-gadget-init`, `usb-gadget` and `adbd` are `DefaultDependencies=no`. `adbd-pre`,
`adbd-post`, the ffs mount and the NCM units keep the default dependencies, so they wait for
`basic.target`.

**What users and developers get:**
- **Developer Mode off:** nothing on USB.
- **Developer Mode on:**
  - `adb shell` (Valve's documented path, also used to reach Lepton through
    `adb forward tcp:5555`), with `adb root` allowed;
  - NCM to the PC, plus ssh and RDP;
  - devkit pairing; CEF debugging.
- **Not provided:**
  - no MTP and no mass storage;
  - no wired PC VR. SteamVR and the Steam bootstrap have no NCM or `usb_gadget` reference
    [M-static, grep]; the Frame streams over Wi-Fi 6E [C, Wikipedia];
  - no DisplayPort alt-mode on the Quest (Quest 3 kernel: `TYPEC_DP_ALTMODE` unset)
    [M-static].
- Valve shipped wired Steam Link over USB NCM for Quest on **Android** as a public beta in
  September 2026 [C, vr.org]. That is a reason to keep Valve's NCM unmodified.

## 2. How the options behave on Quest 3 hardware

**Quest facts:**
- **One UDC:** `a600000.dwc3`, `dr_mode=otg` [M, Android].
- **The kernel builds the needed functions:** `CONFIGFS_F_FS`, `NCM` and `ACM` are `=y` in v2.7
  [M-static]. `EEPROM_AT24` is unset in both the v66 and v2.7 configs [M-static].
- **The typec class exists:** `/sys/class/typec/port0{,-partner}` [M, Android]. Under our
  images: **[O]**.
- **Our role logs are not evidence of the default.** Our `stage3d/init.sh` §3 **forces**
  `mode=peripheral` and the role `device` before logging `ROLE`. The "peripheral/device"
  lines are our own doing [M-static].
- **Role switching is mostly in the kernel, with one exception.** `ucsi.c`'s connector-change
  handler sets the data role and calls `usb_role_switch_set_role`, **except** for an eMarked
  USB3 Gen2+ cable. In that case it emits an `eMarker` uevent and skips the role set
  (`ucsi.c` about l.822). The role is then left to Android userspace [M-static, v2.7 source;
  Android's handler C].
  - Under SteamOS nothing handles that uevent. With such a cable the gadget may never enumerate,
    even though `data_role` reads `[device]` [C].
  - Test U4. If needed, add a FrameShift udev rule on that uevent that sets the role (Quest-side).
- **Brief correction:** the Quest 3 stage images bind **ACM only**. Our NCM exists only as the
  Quest 2 draft (`devices/quest2/channel/target/fs-ncm.sh`) [M-static].

### 2.1 Valve's stack as is: what breaks [D from M-static]
1. **Developer Mode off fails at every boot and every plug (mandatory fix).**
   - `adbd-pre`, the ffs mount and `adbd-post` still run, because systemd conditions do not
     gate dependents.
   - `adbd-post` polls `ffs.adb/ready`. Meta's 5.10 `f_fs.c` has no such attribute (it was
     added upstream in 2024), so the unquoted test errors and the wait ends at once.
   - `ffs.adb` is then linked with no adbd, and `usb-gadget.service` binds. On 5.10 the bind
     returns `-ENODEV` because the descriptors are not ready (`f_fs.c:3107`), and
     `usb-gadget.service` fails.
   - On the Frame's 6.18 kernel the same wait spins forever instead, which is harmless there.
   - **Fix:** a drop-in on `adbd-post.service`:
     - `ExecStartPre=` reset, then a bounded wait for `/dev/usb-ffs/adb/ep1` (FunctionFS creates
       the endpoint files only once descriptors are written);
     - `TimeoutStartSec=`;
     - plus adbd's own `ConditionPathExists=` set.
2. **Descriptor race [O].**
   - It is not established whether Valve's adbd signals readiness to systemd before or after it
     writes its FunctionFS descriptors.
   - The `ep1` wait above covers both cases. Test U2 checks it on hardware.
3. **Identity and serial.**
   - Every Quest would enumerate as Valve's "Steam Frame" with serial `frame` (`%H`). Units 1 and
     2 would collide in `adb -s`.
   - **Fix:** `fs-usb-identity.service` (before `usb-gadget-init`) writes
     `/run/frameshift/usb-identity.env` from a stable per-unit hardware ID: the bootloader's
     `androidboot.serialno` if it is passed [O], otherwise an SoC serial.
   - A drop-in `zz-frameshift-identity.conf` adds `EnvironmentFile=` for it. In systemd,
     `EnvironmentFile=` overrides `Environment=` [C, systemd.exec(5)].
4. **NCM MAC seed.**
   - With `AT24` unset, `eeprom_console` finds no EEPROM. The seed is empty, so every Quest gets
     the same MACs. The writer risk is minor.
   - **Fix:** a drop-in `BindReadOnlyPaths=` on `usb-ncm-gadget@` maps a FrameShift shim over
     that path. The shim prints a value derived from the same per-unit hardware ID, **not** the
     machine-id (`/etc` is tmpfs in R0/R1).
5. **Subnet.**
   - `IF_NET` comes from the interface name, so two Quests on one PC both use
     `10.86.200.232/29`.
   - The Frame has the same limit. Accept it (one headset's NCM per PC); `adb -s` is unaffected.
     Changing it would mean replacing Valve's script.
6. **Windows [O].** No MS OS descriptors are set, so adb and NCM binding on the PM's PC needs
   test U5.

### 2.2 Options
- **1. Ours throughout.**
  - Needs **one** mask, `usb-gadget.target` (cmdline or `/etc`). The typec script's
    `systemctl start` then fails harmlessly.
  - Developer Mode, Valve's adb docs and Lepton debugging do not apply.
- **2. Valve's.** As shipped, plus the §2.1 fixes.
- **3. Hybrid.** Option 2, plus our initramfs console and a dev fallback:
  - `fs-usb-fallback.service` binds our `fs` ACM gadget if `usb-gadget.service` failed
    (`OnFailure=`), or if `g1/UDC` is still empty N seconds after the UDC appears.
  - An ACM function **inside** `g1` is not an independent console. adbd closing unbinds the
    whole gadget (`ffs_closed` → `unregister_gadget_item`, `f_fs.c:3839-3871`), and
    `usb-gadget-adbd-restart.conf` restarts it with adbd.
- **Handover rule:** before `switch_root`, write an empty `fs/UDC` and `rmdir` the gadget. A
  Valve bind fails while our gadget holds the UDC; Valve's stop only touches `g1`.

## 3. Developer Mode in development images
- **Do not preset sentinel files.** With `/etc/steamos-devkit-enabled` present, a later
  `--enable` exits early, and sshd, xrdp, the devkit service, the port-forwards and the
  coredump conf would be missing.
- **Instead:** a dev-only first-boot unit runs **Valve's own** `steamos-devkit-mode --enable`.
- Once Steam runs, set `DevModeEnabled` in its config. Otherwise Steam's startup assertion calls
  `--disable` [C, from the helper's own comment].
- For R-1, `fs-console.target` must **want** `sshd.service`, because `multi-user.target` is not
  reached. adbd's units reach `basic.target` on their own.

## 4. Security
- **Valve's, inherited as stock [M-static]:**
  - nothing on USB unless Developer Mode is on;
  - when it is on: root-capable adb (whether auth is enforced is **[O]**), `nm-shared` ports
    1024–65535 open, and any local caller can toggle the mode (`allow_any=yes`);
  - rescue adb as root, not gated.
- Report concerns to Valve; do not patch.
- **Ours:**
  - the ACM shell is an unauthenticated root shell: dev images only, never a user build;
  - the fallback unit lives in the dev-only layer;
  - the product initramfs has no always-on gadget.

## 5. Update survival: a per-build check
- **Mechanism.**
  - Only FrameShift-named drop-ins (`zz-frameshift-*.conf`, which sort after Valve's
    `usb-gadget.conf`), new `fs-*` units, a `BindReadOnlyPaths=` shim, and cmdline switches.
  - Never a same-named file over a Valve file.
  - Delivered in our `quest` overlay layer (`stage3-4-plan.md` §4.3), or via `systemd-sysext`,
    which SteamOS ships [M-static].
- **Per-build check, before any Valve build is accepted.** systemd silently ignores drop-ins
  for renamed units, so hash and diff these against the reviewed set, and re-review on any
  change:
  - `adbd.service`, `adbd-pre.service`, `adbd-post.service`, `dev-usb\x2dffs-adb.mount`,
    `adbd.service.d/adbd.conf`;
  - `usb-gadget.service`, `usb-gadget-init.service`,
    `usb-gadget-init.service.d/usb-gadget.conf`,
    `usb-gadget.service.d/usb-gadget-adbd-restart.conf`, `usr/lib/usb-gadget-tools/*.sh`;
  - `usb-ncm-gadget@.service`, `usb-ncm-dnsmasq@.service`,
    `usr/share/deckard/{typec-plug-event,usb-ncm-gadget,usb-ncm-dnsmasq}.sh`;
  - `typec-plug-event.rules`, `99-systemd.rules`;
  - `steamos-devkit-mode`, `org.valve.steamos.policy`, `softapmanager` (binary hash);
  - `etc/systemd/system/usb-gadget.target.wants/`;
  - the `USB_GADGET_*` variable names.

## 6. Maintenance burden [D]

| | code we own | per Valve build |
|---|---|---|
| 1 ours | gadget, network, auth, host tools; 1 mask | check the mask target |
| 2 Valve's | 3–4 drop-ins, identity unit, shim (~60 lines) | §5 file check |
| 3 hybrid | 2 plus initramfs ACM (exists) plus fallback unit (dev) | §5 file check |

**Costs of the PM's lean, stated plainly:**
- Valve's stack **does not work as is** on the Quest kernel (§2.1, item 1).
- Developers lose an independent console unless the fallback exists. Valve's rescue adb only
  covers initramfs failures, and reboots after about 20 s.
- Host scripts move from FSV1 to adb or ssh.
- Windows binding is [O].
- With Developer Mode on, the attack surface is Valve's.

## 7. USB identity
- `28de:2460` belongs to Valve. Using it misrepresents the device.
- `1d6b:0104` (today's ID) is generic: fine for development.
- **pid.codes** (VID `0x1209`) requires a public repo with an open-source licence. FrameShift
  has no `LICENSE` and no public remote yet [M-static], and software-only projects must justify
  the request.
- **Asking Valve for a `0x28de` PID** fits the held letter.

## 8. Decisions for the PM, and hardware tests

- **PD-8a: development images.**
  - Options: (1) ours only; (2) Valve's only; (3) **staged**: ours now (Stage A, one cmdline
    mask), then hybrid with the fallback once U1–U6 pass.
  - **Recommend (3).**
- **PD-8b: shipped product.**
  - Options: (1) Valve's files untouched; (2) Valve's plus the Quest drop-ins (identity and
    per-unit serial, adbd-post fix, MAC seed; eMarker rule if U4 needs it); (3) add FrameShift
    debug or MTP functions.
  - **Recommend (2).**
- **PD-8c: USB identity and serial.**
  - Options: (1) Valve's `28de:2460` (no); (2) `1d6b:0104` everywhere; (3) ask Valve for a
    `0x28de` PID; (4) pid.codes, after a licence and a public repo exist.
  - **Recommend:** `1d6b:0104` in development; ask Valve (3) first for the product, with (4) as
    the fallback.
  - In every case, a **per-unit serial from a hardware ID**.
- **PD-8d: MTP.** Not in v1 (recommended); revisit later as a separately reviewed departure.

**Hardware tests** (each in its own package; read-only first; no forced role):
- **U1:** typec `port0-partner` and `data_role` appear under our image.
- **U2:** Valve's adbd over 5.10 FunctionFS with the `ep1` wait; the descriptor race.
- **U3:** Developer Mode off: no failure, nothing enumerates.
- **U4:** replug **without** forcing the role, with a plain cable and with an eMarked USB3 Gen2+
  cable.
- **U5:** adb and NCM on the PM's Windows PC.
- **U6:** the fallback binds `fs` ACM after a forced `usb-gadget.service` failure.

## Sources
- **Valve rootfs `~/sfroot-full`:**
  - the units and drop-ins named in §1 and §5;
  - `usr/lib/udev/rules.d/{typec-plug-event,99-systemd}.rules`;
  - `usr/share/deckard/*.sh`, `usr/lib/usb-gadget-tools/`;
  - `usr/bin/steamos-polkit-helpers/steamos-devkit-mode`;
  - `usr/share/polkit-1/actions/org.valve.steamos.policy`;
  - `usr/lib/initcpio/{hooks,install}/initrd_shell`, `adb_env`;
  - `etc/hostname`;
  - `usr/bin/softapmanager` (`strings` only);
  - the pacman db `usr/lib/holo/pacmandb/local/`.
- **Kernels:**
  - Frame: FS-A-002 (private review record);
  - Quest 3: FS-A-004 (private review record);
  - v2.7: WSL `~/work/kgate27/out/.config`, and `src/drivers/usb/gadget/function/f_fs.c`
    (l.3099-3107, 3839-3871) and `src/drivers/usb/typec/ucsi/ucsi.c` (l.800-840), both under
    `~/work/kgate27`.
- **Quest:** FS-A-004 (private review record);
  `devices/quest3/stage3d/init.sh` §3–§4.
- **Repo:** `devices/quest2/channel/target/fs-ncm.sh`; `docs/research/stage3-4-plan.md` §4.4, §6.
- **Web:**
  - Steamworks, *Steam Frame debugging* and *adb_lepton*;
  - Wikipedia, *Steam Frame*;
  - vr.org (2026-09-03);
  - kernel ABI `configfs-usb-gadget-ffs`, f_fs `ready` commit 43a029724d1c;
  - pid.codes requirements.

## Change list (revision 1)
- **Major:**
  - The Developer-Mode-off failure is now a mandatory adbd-post drop-in.
  - The descriptor race is [O] with test U2.
  - Developer Mode is now enabled through Valve's helper and `DevModeEnabled`;
    `fs-console.target` wants sshd.
  - PD-8a is staged, with a fallback and the cmdline mask; an ACM inside `g1` is shown not to be
    independent.
  - The role evidence is corrected (our init forces the role; the eMarker path; test U4).
  - Per-unit serial; pid.codes prerequisites; the Valve-PID option.
- **Minor:**
  - Inventory adds `usb-gadget-adbd-restart.conf`, the block hatch, `softapmanager` and the
    root rescue adb.
  - AT24 unset; seed from a hardware ID.
  - Option 1 needs one mask.
  - §5 is now a per-build check with a file list.
  - Subnet collision noted.
  - Plan §4.4 reconciled.
