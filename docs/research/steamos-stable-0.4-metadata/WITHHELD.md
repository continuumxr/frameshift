# Withheld from the public copy

Three files of this folder are Valve server output saved verbatim during the 2026-10-12
metadata fetch (see `FETCH-LOG.txt`). They are not republished; fetch them yourself from the
URLs in `FETCH-LOG.txt` and compare the SHA-256 values.

| file | bytes | SHA-256 | what it is |
|---|---:|---|---|
| `vr-listing.html` | 24,730 | `a57859c9983892ee2de853756d1bffb9192e9aa058c51b3a9a89aa92d001ff29` | the server's directory listing of `vr/` |
| `dir-20261007.6125817.html` | 2,272 | `8388d611ff255cc47aa47354a1a0d961d13b25bb4b8ae97bccc9ae4bdb4bc4a1` | the directory listing of build `20261007.6125817` |
| `deckard-stable-20261007.6125817-0.4.5.manifest.json` | 361 | `22625b883ae5b91cc9c6a42d0659217cc7f66a6653a7b6ad9546b1babc1f6260` | the build's unsigned release manifest |

Summary of the manifest, in our words: it names the product SteamOS, variant `vr`, branch
`stable`, architecture `aarch64`, version 0.4.5, build id `20261007.6125817`, and the SteamVR
version 2.18.2. As `SIGNATURE-CHECK.txt` notes, these fields are unsigned; the signed RAUC
manifest inside the bundle is what the verification relies on.
