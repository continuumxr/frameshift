# FrameShift thermal rule r3: the ONE battery/temperature admission rule of a single reading, the stop threshold and the
# follow-up completion rule (Windows PowerShell 5.1; a library: dot-source it). No device, no network, no file access, no
# write. Used by fs-checklist-k1g.ps1 and fs-observe-k1g.ps1, fs-checklist-n1.ps1 and fs-observe-n1.ps1 (phase B's typed
# reading, the machine-captured BA10, phase F's follow-ups). The T0 tools stay on fs-admission-r2.ps1 (THERMAL-R3.md s.5).
# devices/quest3/THERMAL-R3.md is the proposal (PROPOSED to the Chair, not ruled).
#
# History. FS-R-012 s.5 / FS-R-013 s.3 / J-145: below 35.0 deg C (350) with status 3/4/5, status 2 only below 30.0 deg C;
# the level above 50 %. Admission r2 (fs-admission-r2.ps1, FS-R-019 s.4): status 2 also below 35.0 deg C above 70 %.
# Thermal r3 (PM direction 2026-11-08, relays/FS-A-021-NOTES.md items 1 and 4):
#   admission  T in 100..399 AND L > 50 AND S in {2,3,4,5}        (status 1 never; below 40.0 deg C, any charging state)
#   stop       any reading T >= 430 (43.0 deg C): shut down and cool at once (was >= 400, 40.0 deg C)
#   follow-ups reading 1 at least 270 s after the end of AA; if it is the ONLY reading, it was taken no later than 420 s
#              after the end of AA (PM decision 2026-11-09, about +7 min), it is NOT higher than AA10 and it is below
#              400 (the admission ceiling), the follow-ups are finished. Otherwise the series rule applies as
#              before: reading 2 at least 570 s after the end of AA, each reading at least 240 s after the one before, and
#              the last below 400 and not above the one before ("continue while rising or concerning"; concerning = not
#              below the admission ceiling). Every reading below 430.
# This file holds the limits, the T < 400 / status rule and the follow-up decision; the callers keep their own named
# checks of the 100 floor and the level > 50 (phase B: range-100-399, battery-above-50; BA10: the same messages), the
# freshness, the unit, the raw-file binding of each follow-up, 'off@' and 'none@'.
$script:FsAdmR3TempMin = 100             # three digits, 100..399: below 100 (10.0 deg C) is a typing error / not plausible
$script:FsAdmR3TempLimit = 400           # 40.0 deg C: every admitted reading is below it (the admission ceiling)
$script:FsAdmR3LevelAbove = 50           # FS-R-012 s.5: the battery level is above 50 % for every status (checked by the callers)
$script:FsAdmR3StopAt = 430              # 43.0 deg C: any reading at or above it is the stop (shut down and cool at once)
$script:FsAdmR3FuFirstSec = 270          # reading 1: about +5 min after the end of AA (30 s tolerance)
$script:FsAdmR3FuOneMaxSec = 420         # the one-reading path: reading 1 no later than 420 s (about +7 min) after the end of AA (PM 2026-11-09)
$script:FsAdmR3FuSecondSec = 570         # reading 2 (when one is needed or taken): about +10 min after the end of AA
$script:FsAdmR3FuGapSec = 240            # each further reading at least 240 s after the one before

# $T, $S, $L: the digits as TEXT (nothing is rounded or converted before the check). $L is accepted for the r2 call shape
# and not used: the level > 50 is the callers' named check. Returns $null when the rule holds, else the reason (text).
function Test-FsAdmissionR3BatteryRule([string]$T, [string]$S, [string]$L) {
    if ($T -cnotmatch '^[0-9]{1,4}\z') { return "temperature '$T' is not digits" }
    if ([int]$T -ge $script:FsAdmR3TempLimit) { return "temperature $T is not below $($script:FsAdmR3TempLimit) (40.0 deg C, thermal r3)" }
    if ($S -cmatch '^[2345]\z') { return $null }
    "battery status $S is not 2, 3, 4 or 5 (charging, discharging, not charging, full): the battery state is unknown or not accepted (thermal r3)"
}

# The stop: $true when a reading (text digits or an int) is at or above 430.
function Test-FsThermalR3Stop($T) { ([string]$T -cmatch '^[0-9]{1,4}\z') -and [int]$T -ge $script:FsAdmR3StopAt }

# The follow-up completion rule. $Temps: the readings' temperatures (ints, in order; only readings that have one);
# $Utcs: their UTC times ([DateTime], same order); $AaEndUtc: the end of AA ([DateTime] or $null); $Aa10: AA10's temperature
# (int or $null). Returns the list of reasons the series is NOT finished (empty = finished). The caller adds its own
# reasons for 'off@', 'none@' readings and a missing AA end time, and does not call this with a 'none' reading in the series.
# Call it as @(Get-FsFollowUpR3Problems ...).
function Get-FsFollowUpR3Problems([int[]]$Temps, [DateTime[]]$Utcs, $AaEndUtc, $Aa10) {
    $w = @()
    $n = @($Temps).Count
    if ($n -lt 1) { return @("no follow-up reading: one about 5 min ($($script:FsAdmR3FuFirstSec) s) after the end of AA is required") }
    if ($null -ne $AaEndUtc -and ($Utcs[0] - $AaEndUtc).TotalSeconds -lt $script:FsAdmR3FuFirstSec) { $w += "the first reading is less than about 5 min ($($script:FsAdmR3FuFirstSec) s) after the end of AA" }
    if ($n -eq 1) {
        # the shorter rule: one reading finishes the follow-ups when it was taken no later than 420 s after the end of AA (PM
        # decision 2026-11-09: "Cap at ~7 min"), it is not higher than AA10 and it is below the admission ceiling
        if ($null -ne $AaEndUtc -and ($Utcs[0] - $AaEndUtc).TotalSeconds -gt $script:FsAdmR3FuOneMaxSec) { $w += "reading 1 is more than about 7 min ($($script:FsAdmR3FuOneMaxSec) s) after the end of AA, too late to finish the follow-ups alone: continue (a second reading at least 240 s later, about +10 min or later)" }
        if ($null -eq $Aa10) { $w += 'no AA10 temperature to compare reading 1 with: continue (a second reading at least 240 s later, about +10 min)' }
        elseif ($Temps[0] -gt [int]$Aa10) { $w += "reading 1 ($($Temps[0])) is higher than AA10 ($Aa10): continue (a second reading at least 240 s later, about +10 min, then every 5 min while rising or concerning)" }
        if ($Temps[0] -ge $script:FsAdmR3TempLimit) { $w += "reading 1 ($($Temps[0])) is not below $($script:FsAdmR3TempLimit) (40.0 deg C, the admission ceiling): continue every 5 min" }
    } else {
        if ($null -ne $AaEndUtc -and ($Utcs[1] - $AaEndUtc).TotalSeconds -lt $script:FsAdmR3FuSecondSec) { $w += "the second reading is less than about 10 min ($($script:FsAdmR3FuSecondSec) s) after the end of AA" }
        for ($i = 1; $i -lt $n; $i++) { if (($Utcs[$i] - $Utcs[$i - 1]).TotalSeconds -lt $script:FsAdmR3FuGapSec) { $w += "reading $($i + 1) is less than $($script:FsAdmR3FuGapSec) s after reading $i" } }
        if ($Temps[$n - 1] -ge $script:FsAdmR3TempLimit -or $Temps[$n - 1] -gt $Temps[$n - 2]) { $w += "the last reading is rising or concerning ($($script:FsAdmR3TempLimit) or more, or above the one before): continue every 5 min" }
    }
    if (@($Temps | Where-Object { $_ -ge $script:FsAdmR3StopAt }).Count) { $w += "a reading at $($script:FsAdmR3StopAt) (43.0 deg C) or more" }
    $w   # callers wrap the call in @( ): an empty list emits nothing
}
