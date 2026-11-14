# Meta Quest 3S

Developed alongside the Meta Quest 3. Build and research work only so far: no FrameShift image
has run on a Quest 3S, and the project has no Quest 3S unit yet.

- **Platform:** Qualcomm XR2 Gen 2, the same platform family as the Quest 3.
- **Kernel:** the same Meta source tree as the Quest 3, built with its own configuration. The
  kernel gate passes: the extra options SteamOS needs first change none of the symbol versions
  Meta's stock modules expect.
- **Approach:** do the work on the Quest 3, then port it. The display, cooling and battery differ
  from the Quest 3 and get their own checks before any test on a Quest 3S.

---

*Meta, Meta Quest and Meta Horizon are trademarks of Meta Platforms, Inc.; Valve, Steam, SteamOS and
Steam Frame are trademarks of Valve Corporation; Qualcomm, Snapdragon and Adreno are trademarks of
Qualcomm Incorporated; other names are the property of their respective owners. FrameShift is not
affiliated with, endorsed by or sponsored by any of them.*
