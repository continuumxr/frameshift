# FrameShift admission rule r2: the ONE battery/temperature rule of a single admission reading (Windows PowerShell 5.1; a
# library: dot-source it). No device, no network, no file access, no write. Used by fs-checklist-k1g.ps1 and
# fs-observe-k1g.ps1, fs-checklist-n1.ps1 and fs-observe-n1.ps1 (phase B's typed reading and the machine-captured BA10).
#
# History. FS-R-012 s.5 / FS-R-013 s.3 / J-145: the reading is below 35.0 deg C (350) with the battery status 3, 4 or 5; a
# reading while charging (status 2) is accepted only below 30.0 deg C (300); the battery level is above 50 %.
# Admission r2 (PM direction 2026-10-23, proposed to the Chair, not ruled): "allow a run if the headset is over 70% charge and
# under 35 celsius": status 2 is ALSO accepted below 35.0 deg C when the battery level is above 70 %. Everything else is
# unchanged: status 3/4/5 below 35.0; status 2 at a level of 70 % or less still only below 30.0; status 1 never; the level above
# 50 % for every status; the freshness, unit, BA10, follow-up and 40.0 deg C rules live in the callers and are untouched.
# Rule (tenths of a deg C T, status S, level L %):   T in 100..349 AND L > 50 AND ( S in 3,4,5  OR  S = 2 AND ( T < 300  OR  L > 70 ) )
# This function holds the T < 350 limit and the status/level interplay; the callers keep their own named checks of the 100 floor and the level > 50
# (phase B: range-100-349, battery-above-50; BA10: the same messages), which are unchanged.
#
# All three arguments are the digits as TEXT (nothing is rounded or converted before the check; exactly the forms the
# checklist and the BA10 reader already validate). $L may be $null or '' (the level is unknown): then no status 2 reading is
# accepted above 30.0 deg C. Returns $null when the battery rule holds, else the reason (text).
$script:FsAdmTempMin = 100               # three digits, 100..349: below 100 (10.0 deg C) is a typing error / not plausible
$script:FsAdmTempLimit = 350             # 35.0 deg C: every admitted reading is below it
$script:FsAdmChargingLimit = 300         # 30.0 deg C: status 2 (charging) at any level above FsAdmLevelAbove
$script:FsAdmLevelAbove = 50             # FS-R-012 s.5: the battery level is above 50 % for every status
$script:FsAdmChargingHighLevel = 70      # r2: status 2 below FsAdmTempLimit when the level is above 70 %
function Test-FsAdmissionBatteryRule([string]$T, [string]$S, [string]$L) {
    if ($T -cnotmatch '^[0-9]{1,4}\z') { return "temperature '$T' is not digits" }
    if ([int]$T -ge $script:FsAdmTempLimit) { return "temperature $T is not below $($script:FsAdmTempLimit) (35.0 deg C)" }
    if ($S -cmatch '^[345]\z') { return $null }
    if ($S -ceq '2') {
        if ([int]$T -lt $script:FsAdmChargingLimit) { return $null }
        $lv = if ($L -cmatch '^(100|[1-9]?[0-9])\z') { [int]$L } else { -1 }
        if ($lv -gt $script:FsAdmChargingHighLevel) { return $null }
        return ("battery status 2 (charging) with temperature ${T} and level $(if ($lv -ge 0) { "$lv %" } else { 'unknown' }): charging is accepted below $($script:FsAdmChargingLimit) (30.0 deg C), " +
                "or below $($script:FsAdmTempLimit) (35.0 deg C) only when the battery level is above $($script:FsAdmChargingHighLevel) % (admission r2)")
    }
    "battery status $S is not 3, 4 or 5 (discharging, not charging, full), nor 2 (charging) below $($script:FsAdmChargingLimit), nor 2 below $($script:FsAdmTempLimit) with the level above $($script:FsAdmChargingHighLevel) %: the battery state is unknown or not accepted"
}
