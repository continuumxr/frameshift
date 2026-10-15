# ERRATA-002 — supersessions from the Chair Continuity Directive

*Edited for publication: names and links removed or paraphrased.*

**Issued:** 2026-10-07, after `FrameShift_Chair_Continuity_Directive.md`
was added to `docs/`.

That document is the chair's handoff artifact and it changes the programme in
ways that contradict documents already written. Per convention, dated records
are **superseded, not edited** — so the earlier text stays visible and this
notice says what no longer holds. `PROJECT_SETUP.md` has been revised to match;
`CHAIR_DIRECTIVE.md` and the programme plan (withheld) carry pointers here
rather than rewrites.

---

## 1. SUPERSEDED — device order and target list

**As written**, `PROJECT_SETUP.md` §1.2 and `CHAIR_DIRECTIVE.md` §1 put the
**XR Elite first**, with Quest 2 and Quest Pro second and Quest 3 third.

**Now:** **Quest 3 first, Quest 2 second, Quest 1 third.** The XR Elite is a
later workstream and must not redirect the Quest bring-up.

**Quest Pro is dropped** — the PM does not hold one. **Quest 1 is added.**

*Editor's note (2026-10-11): superseded by the PM's order of 2026-10-09
(J-35/J-37), adopted by the Chair in FS-R-006 §1: Quest 3 → Quest 2 → Quest Pro
→ Quest 3S → Quest 1 → XR Elite, with Quest Pro and Quest 3S offline/build only.
The current order is in `README.md` → Targets and order.*

The programme goal is restated by the directive as: boot a SteamOS-based ARM
system on an unlocked **Quest 3** as a proof of concept, with the first gate a
minimal observable ARM Linux boot reaching a shell or similarly decisive
marker.

## 2. Why the reordering is also the right call on the evidence

Recorded because adopting a directive and agreeing with it are different
things, and the chair is entitled to know which this is. Four reasons, in
descending order of weight:

1. **A device with temporary boot can test a kernel without a persistent
   write.** This is the decisive one. *[paraphrased for publication]* On a
   Quest, **[C]** a kernel and initramfs can be tried
   non-persistently, so a failed attempt costs a reboot. **[O]** Unverified on
   the specific unit; it is the first thing to establish in §2.2 of
   `PROJECT_SETUP.md`.
2. **Stage 1 is a debugging stage, and debugging wants cheap iteration.** The
   console problem is unsolved on every target. Solving it where a failed
   attempt is free is strictly better than solving it where a failed attempt
   costs a container build and a recovery.
3. **[M] Steam Frame is SM8650, so Quest 3 is the nearest neighbour.**
   SM8550-class against SM8650. Whatever transfers from Valve's own kernel and
   device tree transfers best there, and the community ports
   (`MaSieS4Fun/SteamOS-ARM-SM8550`, and others) are in that family. The
   XR Elite, at SM8250, gets the least carry of any target on the list — the
   opposite of what the original order assumed.
4. **The XR Elite's recovery story is good but it is [I], not [D].** Per
   `ERRATA-001.md`, two successful recoveries are not a proof covering an
   arbitrary bad image. Spending the project's first and least-informed kernel
   attempts against that claim is poor sequencing. Spending them on a device
   that can roll back by power-cycling is better.

**Against the reordering, stated honestly:** the XR Elite is the device we
had studied longest *[paraphrased for publication]*. Quest 3 is a device we have measured nothing about.
Moving first to a target with zero established facts costs the programme the
baseline it already owns, and §2.2 of `PROJECT_SETUP.md` has to rebuild it.
That cost is real and it is accepted.

## 3. NOT ADOPTED — claim-tag vocabulary (reversed by FS-R-001)

The continuity directive introduced **[C]** (inferred) and narrowed **[D]** to
"derived from code or disassembly". This section originally adopted that.

**Ruling FS-R-001 (2026-10-07) reversed it:** retain the agreed
**[M]/[D]/[C]/[O]** vocabulary of `CHAIR_DIRECTIVE.md` §3, and *identify static
observations explicitly rather than redefining [M] or introducing [I]*.

In force from 2026-10-07:

- **[M]** measured on hardware, with the output shown.
- **[M-static]** read directly from a named artifact — an image, a dump, a
  file — with its provenance. Not an observation of running hardware.
- **[D]** derived from something measured, with the derivation stated.
- **[C]** inferred, plausible, unconfirmed.
- **[O]** open.

`FS-A-001`, sent before the ruling, used **[C]** and a redefined **[M]**. As a
sent record it is not edited; FS-R-001 is the correction.

## 4. CLARIFIED — relay format

The directive says every relay intended for the Arbiter goes in **one copyable
fenced code block**, with no separate `.md` file per response.

Read carefully, that governs **the chair's responses to us**, not our relays to
the chair. `CHAIR_DIRECTIVE.md` §7 — relays are durable files in `relays/`,
numbered `FS-A-NNN` — therefore stands.

Practice adopted (PM, 2026-10-07): **the relay is written to
the private review records and the PM sends that file.** The Arbiter does not also
reproduce it in chat as a code block — copyable code blocks are the chair's
format for rulings, not ours. Rulings are recorded under the relay's number.

Two further points from the directive, now binding:

- **Relay numbers are mirrored exactly.** No parallel sequence, and a revised
  relay gets one consolidated response under its existing number.
- **Relays are written only when something must go before the chair** — a
  discovery, a question, a spot check, or a blocker. Not for routine
  back-and-forth. Numbers are never skipped; unsent material is rolled into the
  open relay. (PM instruction, 2026-10-07.)

## 5. REINFORCED — do not assume the Steam Frame image transfers

The directive is pointed about this and it is aimed at exactly the inference
`FS-A-001` §6 is built on:

> The ARM SteamOS ecosystem and Valve's Steam Frame image are research inputs,
> not proof of drop-in compatibility.

Specifically: do not assume *[paraphrased for publication]* that U-Boot can
simply replace an Android `boot` image, or that an existing SM8550/SM8650 port
supplies a suitable Quest 3 kernel or DT. Examine U-Boot/UEFI placement and
**what actually starts it** on each target.

`FS-A-001` §3.1 already records that we cannot tell what starts U-Boot on Steam
Frame. §6.3's chained-U-Boot proposal for the XR Elite inherits that gap and is
now doubly a proposal rather than a plan.

## 6. Unchanged

- The prohibited-write list for the XR Elite: `abl`, `xbl`, `xbl_config`, `tz`,
  `rpm`, `hyp`, and — added by the directive — `persist`. *[removed for
  publication]* Preserved unless the PM explicitly revises them.
- The failure-pattern list in `CHAIR_DIRECTIVE.md` §5 and §5.1.
- Every device-touching command is presented before it is run, and the device
  gate is the PM's.

---

## Document status

| document | status |
|---|---|
| `FrameShift_Chair_Continuity_Directive.md` | **authoritative** on device order and scope; tags per FS-R-001 |
| `PROJECT_SETUP.md` | **revised 2026-10-07** to match |
| `ERRATA-001.md` | stands |
| `CHAIR_DIRECTIVE.md` | superseded on §1 device order only; §3 tags restored by FS-R-001 |
| programme plan (withheld) | **deferred** — shelved workstream, not the current line of work |
| *[removed for publication]* | |
