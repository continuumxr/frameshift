# kgate validation records

Outputs of `kgate.py` and `run_validation.sh` for the four v2.7 targets
(summaries, check reports, logs, profiles, requested options and allowlists).

- The kernel configuration requests and allowlists in `requests/` are derived
  from the public GPL-2.0 oculus-linux-kernel source
  (`github.com/facebookincubator/oculus-linux-kernel`).
- **Withheld from the public copy:** the per-device `required_crcs.txt`
  (symbol/CRC pairs read from the stock vendor modules) and `inventory.tsv`
  (the stock module inventory with hashes). They are extracted from Meta
  firmware. `kgate.py reference --out <dir>` regenerates both from your own
  firmware; `reference.summary.json` keeps the counts and pins.
