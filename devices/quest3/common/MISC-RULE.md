# misc before/after rule (v1)

**Answers:**
- **FS-R-006 §6:** accept only specifically expected boot-command contents
  and transitions, not arbitrary changes anywhere in the 32-byte field.
  Record changes in the control-observed vendor range as presumed
  reboot-related; their location alone does not prove harmlessness.
- **FS-R-005 §3:** retain complete before/after misc contents and specify
  how differences are classified.

**This replaces the `misc` bullet of FS-A-006 §5.5 item 3.** That bullet
accepted any change confined to `0x0000–0x001f`.

**Reference implementation:** `tools/misc_rule.py`. **Fixtures:**
`tools/test_misc_rule.py` → `fixtures/misc/RESULTS.txt`, 26/26 (18 classification, 8 CLI).

**CLI exit codes (second review S2):** UNCHANGED 10, EXPECTED 11,
RECORDED 12, STOP 13, INCONCLUSIVE 14, usage 64.
- No verdict uses 0, 1 or 2, so a Python traceback (exit 1) or an
  interpreter/argparse failure (exit 2) can never be read as a verdict.
- A missing, unreadable or non-file capture, or any other exception, is
  reported as `VERDICT INCONCLUSIVE` with exit 14.
- Before this, at `05a2dd2`, a missing capture raised a traceback with
  exit 1, which that revision's table read as EXPECTED.

## 1. Observed data (Quest 3 Unit 1; FS-A-005 (private review record))

| image | sha256 | `0x0000` command | `0x1010` vendor words (LE) |
|---|---|---|---|
| `firmware/quest3/unit1_nonslotted/misc.img` (earlier dump) | `668bac5b…c683` | 32 × `00` | `0x066e 0xfffffa63 0x6b` |
| `misc-after.img` (after the stage-1 trial) | `33db1f61…10a0` | `bootonce-bootloader` + 13 × `00` | `0x06d0 0xfffffa09 0x73` |
| `misc-ctrl0.img` (before the PM's stock control) | `33db1f61…10a0` (= after) | same | same |
| `misc-ctrl1.img` (after the control) | `5b8baebe…82fd` | same | `0x05bf 0xfffffb21 0x77` |

- **The control** (`misc-control-commands.txt`): `adb reboot bootloader`,
  then `fastboot reboot`, with no image of ours. It changed exactly 5 bytes,
  all at `0x1010–0x1018`. The command string was already set and stayed set
  (FS-R-005 §2 verified the same).
- **The earlier dump vs after:** the command went from empty to
  `bootonce-bootloader`, plus vendor-field changes. Not a valid
  before/after pair (FS-R-005 §3), but real images.
- **Other non-zero content, unchanged in every image:**
  - `0x101c` = `02`;
  - `0x1400` and `0x1440` = `deadbeef`;
  - `0x8000` = virtual-A/B message (version 2, magic `0x56740ab0`, merge
    status 0).

## 2. Regions

| region | bytes | meaning |
|---|---|---|
| **C** | `0x0000–0x001f` | AOSP `bootloader_message.command` (32 bytes) |
| **V** | `0x1010–0x101b` | the vendor field the stock control changed. **The control changed only 5 bytes** (`0x1010–0x1011`, `0x1014–0x1015`, `0x1018`). V is **widened to the three whole 32-bit little-endian words** those bytes lie in (12 bytes), because a word-sized field that changed in its low bytes can plausibly change in its high bytes on another cycle. Writer and meaning unknown [O]; not established to be a counter (FS-A-005 note) |
| **O** | everything else (1,048,576 − 44 bytes) | including `bootloader_message.status/recovery/stage`, `slot_suffix` at `0x800`, `0x101c`, `0x1400`, `0x1440` and the VAB message at `0x8000` |

## 3. Expected values of C

- `E0` = 32 bytes of `00`.
- `E1` = the 19 ASCII bytes `bootonce-bootloader` followed by exactly 13
  bytes of `00`.
  - This is what Android writes for `reboot bootloader` [C, strong: AOSP
    `libbootloader_message`; matches the trial sequence, which starts with
    `adb reboot bootloader`].
  - ABL did not clear it in the control [M].

**Accepted (before → after):**
- `E0 → E0` (unchanged);
- `E1 → E1` (unchanged);
- `E0 → E1` (Android's `reboot bootloader`).

**Everything else is not specifically expected:**
- `E1 → E0`: never observed;
- any other string;
- `E1` with a non-NUL byte in its tail;
- a before-value that is neither `E0` nor `E1`, even if unchanged.

## 4. Classification (precedence: INCONCLUSIVE > STOP > RECORDED > EXPECTED > UNCHANGED)

| class | condition | consequence |
|---|---|---|
| **INCONCLUSIVE** | Either capture is missing or not exactly 1,048,576 bytes. Captures must be the full partition (`/dev/block/by-name/misc`, 1,048,576 bytes), taken in Android immediately before `adb reboot bootloader` and after the return | Persistent-state accounting is impossible. **No further trial** until a complete pair exists |
| **STOP** | Any byte in O differs, **or** C's transition is not in §3 | Stops further trials until explained (FS-A-006 §5.5, FS-R-005 §3) |
| **RECORDED** | V differs (and nothing above applies) | Recorded verbatim: the three words before and after, as unsigned and signed. Labelled **"presumed reboot-related"**: the stock control changed the same field. **The location alone does not establish harmlessness** (FS-R-006 §6). It does not stop trials by itself. It is reported in the relay with the control comparison |
| **EXPECTED** | Only C changed, and `E0 → E1` | Recorded as Android's `reboot bootloader` |
| **UNCHANGED** | The images are byte-identical | |

**Not covered by this rule:**
- Other partitions (boot images, vbmeta) and the slot state, covered by the
  before/after state checks (method private). Any change to these stops
  further trials (FS-A-006 §5.5 item 3, unchanged).
- RPMB and UFS device attributes, which partition captures do not see.

## 5. Fixtures (`fixtures/misc/RESULTS.txt`)

| case | before → after | expected | result |
|---|---|---|---|
| `real-control-ctrl0-ctrl1` | the real stock control | RECORDED (V only; words listed) | PASS |
| `real-trial-after-eq-ctrl0` | trial-after vs control-before | UNCHANGED (byte-identical) | PASS |
| `real-dump-march-to-ctrl0` | real images, synthetic pairing | RECORDED (`E0→E1` plus V) | PASS |
| `c-E0-to-E1-only` | only the command written | EXPECTED | PASS |
| `c-E0-unchanged`, `identical` | | UNCHANGED | PASS |
| `c-E1-to-E0` | command cleared | STOP | PASS |
| `c-recovery` | `boot-recovery` | STOP | PASS |
| `c-junk-after-nul` | `E1` with `0x1f` = `01` | STOP | PASS |
| `c-before-unexpected` | `boot-recovery` in both | STOP | PASS |
| `o-status-field` | `0x20` | STOP | PASS |
| `o-just-below-v`, `o-just-above-v` | `0x100f`, `0x101c` | STOP (boundaries) | PASS |
| `o-vab-message` | `0x8008` | STOP | PASS |
| `o-slot-suffix` | `0x800` = `_b` | STOP | PASS |
| `v-and-other` | V plus `0x1400` | STOP | PASS |
| `truncated-after` | 1 byte short | INCONCLUSIVE | PASS |
| `empty-before` | no before capture (the FS-A-005 situation) | INCONCLUSIVE | PASS |

The synthetic cases are made in memory from the real images. No new image
is written to the repo.
