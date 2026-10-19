# SPDX-License-Identifier: Apache-2.0
# FrameShift H-1/H-2 module loader library (busybox ash). Sourced by a PID 1 init of a later image (K1i,
# TS T1+, R-1); never by K1a (K1a's pinned init.sh keeps its own loader). Our own code, written from the facts
# in devices/quest3/h1/README.md (design: docs/research/device-health-design.md rev 2.1, H-1 and H-2;
# acceptance: relays/FS-R-013.md §10).
#
# Contract (README §2):
#   1. H-2 first: force_sysfs_fallback=0, ignore_sysfs_fallback=1, /sys/class/firmware/timeout=1, each
#      written then READ BACK; any mismatch or missing file -> no module is loaded, return 2.
#   2. The module index (modules.dep / modules.softdep files) must match its pins, and the phase list must be
#      well formed and closed in load order (every modules.dep dependency and every softdep pre: target that
#      exists in FSML_MD comes earlier); otherwise no module is loaded, return 2.
#   3. Phase S (thermal-service closure): plain insmod, in list order, each with its own deadline; never
#      skipped for a budget; then a bounded readiness window for every S module (none when an S module
#      already FAILED: S cannot become ready, so the run goes straight on to E and the refusal); then, if
#      FSML_RPROC_START names a remoteproc (the TS T3b / R-1 ADSP), its explicit start and a bounded wait
#      for "running". Phase S has a ceiling FSML_S_MAX: reaching it is an S-readiness FAILURE (the run
#      stops, the remaining S modules are NOT-ATTEMPTED, E and F are not loaded, the handoff is refused);
#      it never lets the run continue without an S module, and it does not cancel a blocked init.
#      Phase E (essential): plain insmod, each with a deadline, inside the E budget; the rest SKIPPED on
#      exhaustion; then a readiness wait for the required (E) entries inside the same budget.
#      Phase F (the rest): insmod with async_probe=1, each with a deadline, inside the F budget; the rest
#      SKIPPED on exhaustion. S readiness is re-checked (no wait) just before F; F is SKIPPED as a whole
#      when S is not ready then (FSML_F_ON_S_FAIL=skip, default), and such a skip always REFUSES the handoff.
#      E and F also stop at the total budget (counted from the start; S is exempt and bounded by
#      N_S x FSML_DL_S + FSML_READY_S).
#   4. A deadline only ends OUR wait: a module init that is still running in the kernel (an uninterruptible
#      init or a pending probe) is not cancelled by it (FS-R-013 §10). Its insmod child is never killed and
#      never waited for again; a late result is recorded at the end. The wait for one module also ends when
#      its initstate turns "live": its init is done, and a plain insmod may then still be blocked in the
#      global async_synchronize_full() (kernel/module.c:3784 sets LIVE before the wait at :3799-3800);
#      that is recorded as insmod=blocked. insmod returning 0 is not readiness: every module is classified
#      from /sys/module/<m>/initstate plus its readiness predicate.
#   5. Outcomes: READY, READY-BLOCKED (ready while its insmod is still blocked), PENDING (live, predicate not
#      met), FAILED, TIMED-OUT (not live at the end), SKIPPED, NOT-ATTEMPTED (S ceiling). HANDOFF OK (return
#      0) only if every S module and every required E module is READY or an acceptable READY-BLOCKED (its
#      readiness check covers its function; recorded as a FINDING), the ADSP start (if any) reached
#      "running", the S ceiling was not reached and F was not skipped for S; else REFUSED
#      (return 1). The caller must not start the workload (thermal service run, trial runner, switch_root)
#      unless fsml_run returned 0. The caller assigns every FSML_* knob explicitly (PID 1 inherits
#      name=value words of the kernel command line as environment); fsml_run runs with set +eu and the
#      default IFS and restores the caller's on return; under set -e call it as "fsml_run || rc=$?".
# Records: one line per event in FSML_LOG ("FSML1 t=<s.cc> <EVENT> key=value ..."): the D2 load record.
# Reads sysfs/procfs; writes only the three H-2 settings, the optional module latch (FSML_LATCH=1) and files
# under FSML_RUN and FSML_LOG (appended, never truncated). Opens no device node.

: "${FSML_LIST:=/lib/fs/modules.phases}"
: "${FSML_LIST_SHA:=}"         # the list's pinned sha256 (required)
: "${FSML_MD:=/lib/modules}"
: "${FSML_INDEX:=}"            # "path=sha256 path=sha256 ...": the modules.dep / modules.softdep files, pinned
: "${FSML_LOG:=/run/fs-init/modules.log}"
: "${FSML_RUN:=/run/fs-init/ml}"
: "${FSML_ROOT:=}"             # test prefix for /sys and /proc (honoured only with FSML_TEST=1)
: "${FSML_UPTIME:=/proc/uptime}"
: "${FSML_INSMOD:=insmod}"
: "${FSML_DL_S:=10}"           # seconds: per-insmod deadline, phase S
: "${FSML_DL_E:=10}"
: "${FSML_DL_F:=10}"
: "${FSML_READY_S:=15}"        # seconds: S readiness window after the last S insmod
: "${FSML_BUDGET_E:=30}"       # seconds: phase E total (insmods + readiness wait)
: "${FSML_BUDGET_F:=60}"       # seconds: phase F total
: "${FSML_BUDGET_TOTAL:=150}"  # seconds from the start: E and F never start or wait beyond it
: "${FSML_POLL:=0.1}"          # seconds between polls
: "${FSML_F_ON_S_FAIL:=skip}"  # skip | load
: "${FSML_LATCH:=0}"           # 1: kernel.modules_disabled=1 after phase F, read back
: "${FSML_S_MAX:=90}"          # seconds: ceiling on phase S (reaching it = S-readiness failure, refused)
: "${FSML_RPROC_START:=}"      # remoteproc name to start at the end of S (TS T3b / R-1: 3000000.remoteproc-adsp)
: "${FSML_RPROC_WAIT:=15}"     # seconds: bounded wait for that remoteproc to reach "running"
: "${FSML_TEST:=0}"            # 1 only in the offline harness (honours FSML_ROOT, FSML_UPTIME, FSML_INSMOD)

fsml_now() {                   # FSML_T = centiseconds since boot (builtins only)
    read -r _fu _fx < "$FSML_UPTIME"
    _fs=${_fu%.*}; _ff=${_fu#*.}; _ff=${_ff%"${_ff#??}"}; _ff=${_ff#0}
    FSML_T=$((_fs * 100 + ${_ff:-0}))
}

fsml_rec() {                   # fsml_rec EVENT key=value ...
    fsml_now
    _d=$((FSML_T - FSML_T0))
    printf 'FSML1 t=%d.%02d %s\n' $((_d / 100)) $((_d % 100)) "$*" >> "$FSML_LOG"
}

fsml_name() {                  # module name of a .ko file name (KBUILD_MODNAME: '-' -> '_')
    _n=${1%.ko}
    FSML_N=${_n//-/_}
}

fsml_get() { eval "FSML_V=\${FSML_${2}_$1:-}"; }      # fsml_get NAME FIELD -> FSML_V
fsml_set() { eval "FSML_${2}_$1=\$3"; }               # fsml_set NAME FIELD VALUE

fsml_initstate() {             # FSML_IS = coming | live | going | absent
    FSML_IS=absent
    [ -r "$FSML_SYS/module/$1/initstate" ] && read -r FSML_IS < "$FSML_SYS/module/$1/initstate"
    [ -n "$FSML_IS" ] || FSML_IS=absent
}

fsml_bound() {                 # FSML_B = devices bound to the drivers module $1 registered; FSML_ND = drivers
    FSML_B=0; FSML_ND=0
    for _dd in "$FSML_SYS/module/$1/drivers"/*; do
        [ -e "$_dd" ] || continue
        FSML_ND=$((FSML_ND + 1))
        for _de in "$_dd"/*; do
            [ -L "$_de" ] || continue
            [ "${_de##*/}" = module ] && continue
            FSML_B=$((FSML_B + 1))
        done
    done
}

fsml_atom() {                  # fsml_atom NAME ATOM -> 0 if the readiness atom holds (reads only)
    case $2 in
    live)       return 0 ;;
    auto)       fsml_bound "$1"
                [ "$FSML_ND" = 0 ] && return 0
                # every driver the module registered must have a bound device
                for _dd in "$FSML_SYS/module/$1/drivers"/*; do
                    [ -e "$_dd" ] || continue
                    _ok=1
                    for _de in "$_dd"/*; do
                        [ -L "$_de" ] && [ "${_de##*/}" != module ] && { _ok=0; break; }
                    done
                    [ $_ok = 0 ] || return 1
                done
                return 0 ;;
    bound:*)    fsml_bound "$1"; [ "$FSML_B" -ge "${2#bound:}" ] ;;
    hwmon:*)    for _h in "$FSML_SYS/class/hwmon"/*; do
                    [ -r "$_h/name" ] || continue
                    read -r _v < "$_h/name"; [ "$_v" = "${2#hwmon:}" ] && return 0
                done; return 1 ;;
    tz:*)       for _h in "$FSML_SYS/class/thermal"/thermal_zone*; do
                    [ -r "$_h/type" ] || continue
                    read -r _v < "$_h/type"; [ "$_v" = "${2#tz:}" ] && return 0
                done; return 1 ;;
    iiochan:*)  for _h in "$FSML_SYS/bus/iio/devices"/*; do
                    [ -e "$_h/in_temp_${2#iiochan:}_input" ] && return 0
                done; return 1 ;;
    rproc:*)    _w=${2#rproc:}    # rproc:NAME (registered, any state) or rproc:NAME=STATE
                for _h in "$FSML_SYS/class/remoteproc"/*; do
                    [ -r "$_h/name" ] && [ -r "$_h/state" ] || continue
                    read -r _v < "$_h/name"; read -r _s < "$_h/state"
                    case $_w in *=*) [ "$_v=$_s" = "$_w" ] && return 0 ;; *) [ "$_v" = "$_w" ] && return 0 ;; esac
                done; return 1 ;;
    cpufreq:*)  [ -d "$FSML_SYS/devices/system/cpu/cpufreq/${2#cpufreq:}" ] ;;
    param:*)    _w=${2#param:}; [ -e "$FSML_SYS/module/${_w%%/*}/parameters/${_w#*/}" ] ;;
    psy:*)      [ -e "$FSML_SYS/class/power_supply/${2#psy:}" ] ;;
    udc:*)      [ -e "$FSML_SYS/class/udc/${2#udc:}" ] ;;
    led:*)      [ -e "$FSML_SYS/class/leds/${2#led:}" ] ;;
    path:*)     [ -e "$FSML_ROOT${2#path:}" ] ;;
    *)          return 1 ;;
    esac
}

fsml_ready() {                 # fsml_ready NAME -> 0 if initstate is live and every atom of its predicate holds
    fsml_initstate "$1"
    [ "$FSML_IS" = live ] || return 1
    fsml_get "$1" PRED
    _p=$FSML_V
    while [ -n "$_p" ]; do
        _a=${_p%%,*}
        fsml_atom "$1" "$_a" || return 1
        [ "$_a" = "$_p" ] && break
        _p=${_p#*,}
    done
    return 0
}

# ---------------------------------------------------------------------------------------------------------
# H-2: the two fallback settings and the 1 s timeout, written and read back BEFORE any module load.
# ---------------------------------------------------------------------------------------------------------
fsml_setcheck() {              # fsml_setcheck FILE VALUE LABEL -> 0 if the read-back equals VALUE
    _got=missing
    if [ -e "$1" ]; then
        echo "$2" > "$1" 2>/dev/null
        _got=unreadable
        [ -r "$1" ] && read -r _got < "$1"
    fi
    FSML_FW="$FSML_FW $3=$_got"
    [ "$_got" = "$2" ]
}

fsml_fwcfg() {
    FSML_FW=""
    _fc="$FSML_PROC/sys/kernel/firmware_config"
    _r=0
    fsml_setcheck "$_fc/force_sysfs_fallback" 0 force_sysfs_fallback || _r=1
    fsml_setcheck "$_fc/ignore_sysfs_fallback" 1 ignore_sysfs_fallback || _r=1
    fsml_setcheck "$FSML_SYS/class/firmware/timeout" 1 timeout || _r=1
    if [ $_r = 0 ]; then
        fsml_rec "FWCFG ok$FSML_FW (sysfs fallback off; direct file loads and driver stalls are not covered)"
    else
        fsml_rec "FWCFG REFUSED want=force_sysfs_fallback=0,ignore_sysfs_fallback=1,timeout=1 got:$FSML_FW"
    fi
    return $_r
}

# ---------------------------------------------------------------------------------------------------------
# Index pins and the list (both before any module load).
# ---------------------------------------------------------------------------------------------------------
fsml_index() {
    [ -n "${FSML_INDEX// /}" ] || { fsml_rec "INDEX REFUSED reason=no-pins"; return 1; }
    FSML_DEPF=""; FSML_SOFTF=""
    for _e in $FSML_INDEX; do
        _f=${_e%%=*}; _w=${_e#*=}
        _h=$(sha256sum "$_f" 2>/dev/null); _h=${_h%% *}
        if [ "$_h" != "$_w" ]; then
            fsml_rec "INDEX REFUSED file=$_f sha256=${_h:-missing} pinned=$_w"
            return 1
        fi
        case $_f in
        *modules.dep) FSML_DEPF="$FSML_DEPF $_f" ;;
        *modules.softdep) FSML_SOFTF="$FSML_SOFTF $_f" ;;
        *) fsml_rec "INDEX REFUSED file=$_f reason=not-an-index-file"; return 1 ;;
        esac
        fsml_rec "INDEX ok file=$_f sha256=$_h"
    done
    [ -n "$FSML_DEPF" ] || { fsml_rec "INDEX REFUSED reason=no-modules.dep"; return 1; }
    return 0
}

fsml_parse() {                 # syntax, then order/closure (one awk pass); sets FSML_S, FSML_E, FSML_F
    FSML_S=""; FSML_E=""; FSML_F=""; FSML_ALL=""; FSML_NS=0; FSML_NE=0; FSML_NF=0
    [ -r "$FSML_LIST" ] || { fsml_rec "LIST REFUSED file=$FSML_LIST reason=unreadable"; return 1; }
    _h=$(sha256sum "$FSML_LIST" 2>/dev/null); _h=${_h%% *}
    if [ -z "$FSML_LIST_SHA" ] || [ "$_h" != "$FSML_LIST_SHA" ]; then
        fsml_rec "LIST REFUSED file=$FSML_LIST reason=pin sha256=${_h:-missing} pinned=${FSML_LIST_SHA:-none}"
        return 1
    fi
    _ln=0; _last=S
    while read -r _ph _f _pred _x || [ -n "$_ph" ]; do
        _ln=$((_ln + 1))
        case $_ph in ''|'#'*) continue ;; esac
        _bad=""
        [ -z "$_x" ] && [ -n "$_pred" ] || _bad=fields
        case $_ph in S|E|e|F) ;; *) _bad=${_bad:-phase} ;; esac
        case $_f in *[!A-Za-z0-9_.-]*|.*|'') _bad=${_bad:-name} ;; *.ko) ;; *) _bad=${_bad:-name} ;; esac
        # phases must be grouped S, then E/e, then F (the file order is the load order)
        case "$_last$_ph" in SS|SE|Se|SF|EE|Ee|EF|eE|ee|eF|FF) ;; *) _bad=${_bad:-phase-order} ;; esac
        _p=$_pred
        case $_p in ,*|*,|*,,*) _bad=${_bad:-predicate} ;; esac
        while [ -z "$_bad" ] && [ -n "$_p" ]; do
            _a=${_p%%,*}
            [ "$_ph" = S ] && [ "$_a" = auto ] && _bad=s-needs-explicit-predicate
            case $_a in
            live|auto) ;;
            bound:[1-9]|bound:[1-9][0-9]) ;;
            hwmon:?*|tz:?*|iiochan:?*|cpufreq:policy[0-9]|psy:?*|udc:?*|led:?*) ;;
            rproc:?*=?*|rproc:?*) ;;
            param:?*/?*) ;;
            path:/sys/?*) ;;
            *) _bad=${_bad:-predicate} ;;
            esac
            case $_a in *[!A-Za-z0-9_.:=/,@+-]*|*..*) _bad=${_bad:-predicate} ;; esac
            [ "$_a" = "$_p" ] && break
            _p=${_p#*,}
        done
        fsml_name "$_f"
        case $FSML_N in *[!A-Za-z0-9_]*) _bad=${_bad:-name} ;; esac
        [ -n "$_bad" ] || fsml_get "$FSML_N" PH
        [ -z "$_bad" ] && [ -n "$FSML_V" ] && _bad=duplicate
        if [ -n "$_bad" ]; then
            fsml_rec "LIST REFUSED file=$FSML_LIST line=$_ln reason=$_bad"
            return 1
        fi
        _last=$_ph
        fsml_set "$FSML_N" PH "$_ph"
        fsml_set "$FSML_N" PRED "$_pred"
        fsml_set "$FSML_N" FILE "$_f"
        fsml_set "$FSML_N" EV none
        FSML_ALL="$FSML_ALL $FSML_N"
        case $_ph in
        S) FSML_S="$FSML_S $FSML_N"; FSML_NS=$((FSML_NS + 1)) ;;
        E|e) FSML_E="$FSML_E $FSML_N"; FSML_NE=$((FSML_NE + 1)) ;;
        F) FSML_F="$FSML_F $FSML_N"; FSML_NF=$((FSML_NF + 1)) ;;
        esac
    done < "$FSML_LIST"
    [ "$FSML_NS" -gt 0 ] || { fsml_rec "LIST REFUSED file=$FSML_LIST reason=no-S-module"; return 1; }
    _n2=$(awk '$1 !~ /^#/ && NF { n++ } END { print n + 0 }' "$FSML_LIST")
    if [ "$_n2" != $((FSML_NS + FSML_NE + FSML_NF)) ]; then
        fsml_rec "LIST REFUSED file=$FSML_LIST reason=entry-count shell=$((FSML_NS + FSML_NE + FSML_NF)) awk=$_n2"
        return 1
    fi
    # Closure and order against the pinned index: every dependency is listed EARLIER; every softdep pre:
    # target present as a file in FSML_MD is listed earlier; every listed module is in the index.
    _v=$(
        { echo "#LIST"; awk '$1 !~ /^#/ && NF { print $2 }' "$FSML_LIST"
          echo "#FILES"; for _k in "$FSML_MD"/*.ko; do [ -e "$_k" ] && echo "${_k##*/}"; done
          echo "#DEP"; for _k in $FSML_DEPF; do cat "$_k"; done
          echo "#SOFT"; for _k in $FSML_SOFTF; do cat "$_k"; done
        } | awk '
        function base(s) { sub(/.*\//, "", s); return s }
        function mn(s) { s = base(s); sub(/\.ko$/, "", s); gsub(/-/, "_", s); return s }
        /^#LIST$/ { sec = 1; next } /^#FILES$/ { sec = 2; next } /^#DEP$/ { sec = 3; next } /^#SOFT$/ { sec = 4; next }
        sec == 1 { n++; ord[n] = $1; pos[mn($1)] = n; next }
        sec == 2 { have[mn($1)] = 1; next }
        sec == 3 { if (index($0, ":") == 0) next
                   k = $0; sub(/:.*/, "", k); k = mn(k); if (k in dep) next
                   r = $0; sub(/^[^:]*:/, "", r); dep[k] = r; next }
        sec == 4 { if ($1 != "softdep") next
                   m = 0; for (i = 3; i <= NF; i++) { if ($i == "pre:") { m = 1; continue } if ($i == "post:") { m = 2; continue }
                   if (m == 1) pre[mn($2)] = pre[mn($2)] " " $i } }
        END {
          bad = 0
          for (i = 1; i <= n; i++) {
            k = mn(ord[i])
            if (!(k in dep)) { print "not-indexed:" ord[i]; bad = 1; continue }
            c = split(dep[k], d, " ")
            for (j = 1; j <= c; j++) { x = mn(d[j]); if (!(x in pos)) { print "dep-not-listed:" ord[i] "->" base(d[j]); bad = 1 }
                                       else if (pos[x] > i) { print "dep-later:" ord[i] "->" base(d[j]); bad = 1 } }
            c = split(pre[k], d, " ")
            for (j = 1; j <= c; j++) { x = d[j]; gsub(/-/, "_", x); if (!(x in have)) continue
                                       if (!(x in pos)) { print "softdep-not-listed:" ord[i] "->" d[j]; bad = 1 }
                                       else if (pos[x] > i) { print "softdep-later:" ord[i] "->" d[j]; bad = 1 } }
          }
          if (!bad) print "ok"
        }' 2>&1
    )
    if [ "$_v" != ok ]; then
        fsml_rec "LIST REFUSED file=$FSML_LIST reason=order-or-closure detail=$(printf '%s' "$_v" | tr '\n ' ',,')"
        return 1
    fi
    fsml_rec "LIST ok file=$FSML_LIST sha256=$FSML_LIST_SHA S=$FSML_NS E=$FSML_NE F=$FSML_NF"
    return 0
}

# ---------------------------------------------------------------------------------------------------------
# One insmod in a child with a deadline. The child writes its exit status to a file; the parent polls.
# ---------------------------------------------------------------------------------------------------------
fsml_load() {                  # fsml_load NAME PHASE WAIT_CS [PARAMS]
    fsml_get "$1" FILE; _file=$FSML_V
    _rcf="$FSML_RUN/$1.rc"
    if [ ! -f "$FSML_MD/$_file" ]; then
        fsml_set "$1" EV FAILED; fsml_set "$1" RC missing
        fsml_rec "MODULE $1 phase=$2 result=FAILED reason=file-missing file=$_file"
        return
    fi
    rm -f "${_rcf:?}" "${_rcf:?}.tmp"
    fsml_initstate "$1"; _pre=$FSML_IS   # already live before our insmod (loaded earlier): wait for the rc
    fsml_now; _st=$FSML_T
    ( "$FSML_INSMOD" "$FSML_MD/$_file" ${4:-} > /dev/null 2> "$FSML_RUN/$1.err"
      echo $? > "$_rcf.tmp" && mv "$_rcf.tmp" "$_rcf" ) < /dev/null &
    _ch=$!
    fsml_set "$1" CH "$_ch"
    _lv=""
    while :; do                # until insmod returned, or the init finished (live) + 1 s grace, or the deadline
        [ -f "$_rcf" ] && break
        fsml_now
        [ $((FSML_T - _st)) -ge "$3" ] && break
        if [ -z "$_lv" ] && [ "$_pre" != live ]; then
            fsml_initstate "$1"; [ "$FSML_IS" = live ] && _lv=$FSML_T
        fi
        [ -n "$_lv" ] && [ $((FSML_T - _lv)) -ge 100 ] && break
        sleep "$FSML_POLL"
    done
    fsml_now; _el=$((FSML_T - _st))
    fsml_initstate "$1"
    if [ -f "$_rcf" ]; then
        read -r _rc < "$_rcf"
        fsml_set "$1" RC "$_rc"
        if [ "$_rc" = 0 ]; then
            fsml_set "$1" EV LOADED
            fsml_rec "MODULE $1 phase=$2 result=LOADED rc=0 ms=$((_el * 10)) initstate=$FSML_IS${4:+ params=$4}"
        else
            _m=""; [ -r "$FSML_RUN/$1.err" ] && read -r _m < "$FSML_RUN/$1.err"
            _m=$(printf '%s' "$_m" | tr -c 'A-Za-z0-9_.:/=-' '_' | cut -c1-120)
            if [ "$FSML_IS" = live ]; then   # e.g. EEXIST: loaded earlier this boot; judged by its readiness
                fsml_set "$1" EV LOADED
                fsml_rec "MODULE $1 phase=$2 result=LOADED rc=$_rc note=already-live ms=$((_el * 10)) initstate=live msg=$_m"
            else
                fsml_set "$1" EV FAILED
                fsml_rec "MODULE $1 phase=$2 result=FAILED rc=$_rc ms=$((_el * 10)) initstate=$FSML_IS msg=$_m"
            fi
        fi
    elif [ "$FSML_IS" = live ]; then
        fsml_set "$1" EV LOADED
        fsml_rec "MODULE $1 phase=$2 result=LIVE insmod=blocked child=$_ch ms=$((_el * 10))${4:+ params=$4} (init done; the insmod is still waiting, e.g. in async_synchronize_full() for pending async probes; not killed)"
    else
        fsml_set "$1" EV TIMEOUT
        fsml_rec "MODULE_TIMEOUT $1 phase=$2 waited_ms=$((_el * 10)) initstate=$FSML_IS child=$_ch cancel=none (the init may still run in the kernel; the deadline only ends our wait; the child is not killed or waited for again)"
    fi
}

fsml_skip() {                  # fsml_skip REASON NAME...
    _why=$1; shift
    for _m in "$@"; do
        fsml_get "$_m" EV
        [ "$FSML_V" = none ] || continue
        fsml_set "$_m" EV SKIPPED
        fsml_rec "MODULE_SKIPPED $_m reason=$_why"
    done
}

fsml_wait_ready() {            # fsml_wait_ready UNTIL_CS NAME... -> 0 when all are ready, 1 at UNTIL
    _until=$1; shift
    while :; do
        _all=0
        for _wm in "$@"; do fsml_ready "$_wm" || { _all=1; break; }; done
        [ $_all = 0 ] && return 0
        fsml_now
        [ "$FSML_T" -ge "$_until" ] && return 1
        sleep "$FSML_POLL"
    done
}

fsml_waitable() {              # FSML_WAITABLE = those of the given modules that may still become ready
    FSML_WAITABLE=""; FSML_DEAD=0   # (LOADED or TIMEOUT); FSML_DEAD = how many cannot (FAILED, SKIPPED, none)
    for _wm in "$@"; do
        fsml_get "$_wm" EV
        case $FSML_V in
        LOADED|TIMEOUT) FSML_WAITABLE="$FSML_WAITABLE $_wm" ;;
        *) FSML_DEAD=$((FSML_DEAD + 1)) ;;
        esac
    done
}

fsml_min() { FSML_M=$1; for _x in "$@"; do [ "$_x" -lt "$FSML_M" ] && FSML_M=$_x; done; return 0; }

fsml_rproc_start() {           # fsml_rproc_start NAME UNTIL_CS -> 0 when its state reads "running"
    _rd=""
    for _h in "$FSML_SYS/class/remoteproc"/*; do
        [ -r "$_h/name" ] || continue
        read -r _v < "$_h/name"; [ "$_v" = "$1" ] && { _rd=$_h; break; }
    done
    _fp=""; [ -r "$FSML_SYS/module/firmware_class/parameters/path" ] && read -r _fp < "$FSML_SYS/module/firmware_class/parameters/path"
    if [ -z "$_rd" ]; then FSML_RPS=absent; fsml_rec "RPROC_START $1 result=FAILED reason=not-registered"; return 1; fi
    _st0=unreadable; [ -r "$_rd/state" ] && read -r _st0 < "$_rd/state"
    fsml_rec "RPROC_START $1 state=$_st0 firmware_class.path=${_fp:-unset} action=write-start"
    if [ "$_st0" != running ]; then echo start > "$_rd/state" 2>/dev/null; fi
    while :; do
        FSML_RPS=unreadable; [ -r "$_rd/state" ] && read -r FSML_RPS < "$_rd/state"
        [ "$FSML_RPS" = running ] && { fsml_rec "RPROC_START $1 result=running"; return 0; }
        fsml_now
        [ "$FSML_T" -ge "$2" ] && break
        sleep "$FSML_POLL"
    done
    fsml_rec "RPROC_START $1 result=FAILED state=$FSML_RPS (S-readiness failure; a pending boot is not cancelled by this deadline)"
    return 1
}

fsml_sready() {                # 0 if every S module is ready now (no wait)
    for _sm in $FSML_S; do fsml_ready "$_sm" || return 1; done
    return 0
}

# ---------------------------------------------------------------------------------------------------------
# The run.
# ---------------------------------------------------------------------------------------------------------
fsml_run() {                   # the caller's shell options and IFS are saved, neutralised and restored
    _fsml_o=$-; _fsml_is=${IFS+1}; _fsml_ifs=${IFS-}
    set +eu; unset IFS
    fsml_run_body; _fsml_rc=$?
    if [ -n "$_fsml_is" ]; then IFS=$_fsml_ifs; else unset IFS; fi
    case $_fsml_o in *e*) set -e ;; esac
    case $_fsml_o in *u*) set -u ;; esac
    return $_fsml_rc
}

fsml_run_body() {
    FSML_VERDICT=REFUSED
    for _m in $FSML_ALL; do    # a second run in the same shell starts from clean per-module state
        for _k in PH PRED FILE EV RC CH; do unset "FSML_${_k}_$_m"; done
    done
    FSML_ALL=""
    if [ "$FSML_TEST" != 1 ]; then   # the test-only knobs are fixed on a device
        FSML_ROOT=""; FSML_UPTIME=/proc/uptime; FSML_INSMOD=insmod
    fi
    FSML_SYS="$FSML_ROOT/sys"; FSML_PROC="$FSML_ROOT/proc"
    FSML_T0=0
    if ! mkdir -p "${FSML_LOG%/*}" 2>/dev/null || ! : >> "$FSML_LOG" 2>/dev/null; then
        echo "FSML1 HANDOFF verdict=REFUSED reason=log-unwritable log=$FSML_LOG (no module loaded)" >&2
        return 2
    fi
    fsml_now; FSML_T0=$FSML_T
    fsml_rec "START list=$FSML_LIST md=$FSML_MD run=$FSML_RUN s_max=$FSML_S_MAX rproc_start=${FSML_RPROC_START:-none} rproc_wait=$FSML_RPROC_WAIT dl_s=$FSML_DL_S dl_e=$FSML_DL_E dl_f=$FSML_DL_F ready_s=$FSML_READY_S budget_e=$FSML_BUDGET_E budget_f=$FSML_BUDGET_F budget_total=$FSML_BUDGET_TOTAL poll=$FSML_POLL f_on_s_fail=$FSML_F_ON_S_FAIL latch=$FSML_LATCH test=$FSML_TEST root=${FSML_ROOT:-/} insmod=$FSML_INSMOD uptime=$FSML_UPTIME"
    case $FSML_RUN in /?*) ;; *) fsml_rec "HANDOFF verdict=REFUSED reason=bad-run-dir run=$FSML_RUN (no module loaded)"; return 2 ;; esac
    if ! mkdir -p "$FSML_RUN" 2>/dev/null || ! : > "$FSML_RUN/.probe" 2>/dev/null; then
        fsml_rec "HANDOFF verdict=REFUSED reason=run-dir-unwritable run=$FSML_RUN (no module loaded)"; return 2
    fi
    rm -f "${FSML_RUN:?}/.probe" "${FSML_RUN:?}"/*.rc "${FSML_RUN:?}"/*.rc.tmp "${FSML_RUN:?}"/*.err   # no stale result
    for _x in "$FSML_DL_S" "$FSML_DL_E" "$FSML_DL_F" "$FSML_READY_S" "$FSML_BUDGET_E" "$FSML_BUDGET_F" "$FSML_BUDGET_TOTAL" "$FSML_S_MAX" "$FSML_RPROC_WAIT"; do
        case $_x in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) ;;   # 1..9999 s; no leading zero (octal)
        *) fsml_rec "HANDOFF verdict=REFUSED reason=bad-budget value=$_x (no module loaded)"; return 2 ;; esac
    done
    case $FSML_POLL in 0.0[1-9]|0.[1-9]|0.[1-9][0-9]|[1-5]) ;;
    *) fsml_rec "HANDOFF verdict=REFUSED reason=bad-poll value=$FSML_POLL (no module loaded)"; return 2 ;; esac
    case $FSML_RPROC_START in *[!A-Za-z0-9_.-]*) fsml_rec "HANDOFF verdict=REFUSED reason=bad-rproc value=$FSML_RPROC_START (no module loaded)"; return 2 ;; esac
    case $FSML_F_ON_S_FAIL$FSML_LATCH in skip0|skip1|load0|load1) ;;
    *) fsml_rec "HANDOFF verdict=REFUSED reason=bad-option f_on_s_fail=$FSML_F_ON_S_FAIL latch=$FSML_LATCH (no module loaded)"; return 2 ;; esac
    if ! fsml_fwcfg; then
        fsml_rec "HANDOFF verdict=REFUSED reason=firmware-config (no module loaded)"; return 2
    fi
    if ! fsml_index || ! fsml_parse; then
        fsml_rec "HANDOFF verdict=REFUSED reason=index-or-list (no module loaded)"; return 2
    fi
    fsml_rec "BOUND s_max_s=$FSML_S_MAX e_max_s=$FSML_BUDGET_E f_max_s=$FSML_BUDGET_F total_s=$FSML_BUDGET_TOTAL (S ends by its ceiling: reaching it refuses; E and F end by min(phase budget, total))"
    _fskip=""; _rpbad=""; _ceil=0

    # --- phase S: every module attempted, plainly, each with its own deadline; never skipped ---
    fsml_rec "PHASE S start n=$FSML_NS"
    fsml_now; _sceil=$((FSML_T + FSML_S_MAX * 100))
    for _m in $FSML_S; do
        fsml_now
        if [ "$FSML_T" -ge "$_sceil" ]; then _ceil=1; break; fi
        fsml_min $((FSML_DL_S * 100)) $((_sceil - FSML_T))
        fsml_load "$_m" S "$FSML_M"
    done
    fsml_now
    # an S module that FAILED (or was never loaded) cannot become ready: S is not ready; refuse without waiting
    fsml_waitable $FSML_S
    FSML_SREADY=0
    if [ $_ceil = 0 ] && [ "$FSML_DEAD" = 0 ]; then
        fsml_min $((FSML_T + FSML_READY_S * 100)) "$_sceil"
        fsml_wait_ready "$FSML_M" $FSML_WAITABLE && FSML_SREADY=1
    fi
    if [ $_ceil = 0 ] && [ "$FSML_SREADY" = 1 ] && [ -n "$FSML_RPROC_START" ]; then
        fsml_now
        fsml_min $((FSML_T + FSML_RPROC_WAIT * 100)) "$_sceil"
        if ! fsml_rproc_start "$FSML_RPROC_START" "$FSML_M"; then
            FSML_SREADY=0; _rpbad="S:rproc-$FSML_RPROC_START:$FSML_RPS"
        fi
    fi
    fsml_now
    if [ $_ceil = 1 ] || { [ "$FSML_SREADY" = 0 ] && [ "$FSML_T" -ge "$_sceil" ]; }; then
        _ceil=1
        for _m in $FSML_S; do
            fsml_get "$_m" EV; [ "$FSML_V" = none ] || continue
            fsml_set "$_m" EV NOTATT; fsml_rec "MODULE_NOT_ATTEMPTED $_m reason=s-ceiling"
        done
        fsml_rec "S_CEILING reached s_max_s=$FSML_S_MAX: S-readiness failure, handoff refused; E and F are not loaded; a blocked init is not cancelled by this ceiling (FS-R-013 §10)"
    fi
    _nr=0; for _m in $FSML_S; do fsml_ready "$_m" && _nr=$((_nr + 1)); done
    fsml_rec "PHASE S end ready=$_nr/$FSML_NS"
    if [ $_ceil = 1 ]; then
        fsml_skip s-ceiling $FSML_E $FSML_F
    else

    # --- phase E: plain, deadline each, inside min(E budget, total) ---
    fsml_now
    fsml_min $((FSML_T + FSML_BUDGET_E * 100)) $((FSML_T0 + FSML_BUDGET_TOTAL * 100)); _end=$FSML_M
    fsml_rec "PHASE E start n=$FSML_NE"
    _req=""
    for _m in $FSML_E; do fsml_get "$_m" PH; [ "$FSML_V" = E ] && _req="$_req $_m"; done
    for _m in $FSML_E; do
        fsml_now
        if [ "$FSML_T" -ge "$_end" ]; then
            [ "$_end" -lt $((FSML_T0 + FSML_BUDGET_TOTAL * 100)) ] && _w=budget-e || _w=budget-total
            fsml_skip "$_w" $FSML_E; break
        fi
        fsml_min $((FSML_DL_E * 100)) $((_end - FSML_T))
        fsml_load "$_m" E "$FSML_M"
    done
    fsml_waitable $_req     # wait only while every required E entry can still become ready
    [ -n "$FSML_WAITABLE" ] && [ "$FSML_DEAD" = 0 ] && fsml_wait_ready "$_end" $FSML_WAITABLE
    fsml_rec "PHASE E end"

    # --- phase F: async_probe=1, deadline each, inside min(F budget, total); not while S is not ready ---
    if [ "$FSML_SREADY" = 0 ] && [ -z "$_rpbad" ] && fsml_sready; then
        FSML_SREADY=1; fsml_rec "S ready=yes (re-checked before F, after the S window)"
    fi
    if [ "$FSML_SREADY" = 0 ] && [ "$FSML_F_ON_S_FAIL" != load ]; then
        fsml_skip s-not-ready $FSML_F
        [ "$FSML_NF" -gt 0 ] && _fskip=" f_skipped=s-not-ready"
    else
        fsml_now
        fsml_min $((FSML_T + FSML_BUDGET_F * 100)) $((FSML_T0 + FSML_BUDGET_TOTAL * 100)); _end=$FSML_M
        fsml_rec "PHASE F start n=$FSML_NF"
        for _m in $FSML_F; do
            fsml_now
            if [ "$FSML_T" -ge "$_end" ]; then
                [ "$_end" -lt $((FSML_T0 + FSML_BUDGET_TOTAL * 100)) ] && _w=budget-f || _w=budget-total
                fsml_skip "$_w" $FSML_F; break
            fi
            fsml_min $((FSML_DL_F * 100)) $((_end - FSML_T))
            fsml_load "$_m" F "$FSML_M" async_probe=1
        done
    fi
    fsml_rec "PHASE F end"
    fi

    # --- final classification: one bounded settle (<= 1 s) for insmod results still in flight, then no waiting ---
    fsml_now; _sl=$FSML_T
    while :; do
        _pend=0
        for _m in $FSML_ALL; do
            fsml_get "$_m" EV
            case $FSML_V in LOADED|TIMEOUT) [ -f "$FSML_RUN/$_m.rc" ] || { fsml_initstate "$_m"; [ "$FSML_IS" = live ] && _pend=1; } ;; esac
            [ $_pend = 1 ] && break
        done
        fsml_now
        [ $_pend = 0 ] || [ $((FSML_T - _sl)) -ge 100 ] && break
        sleep "$FSML_POLL"
    done
    _bad=""; _blk=""; _rb=""; _cnt_r=0; _cnt_rb=0; _cnt_p=0; _cnt_f=0; _cnt_t=0; _cnt_s=0; _cnt_n=0
    for _m in $FSML_ALL; do
        fsml_get "$_m" EV; _ev=$FSML_V
        fsml_get "$_m" PH; _ph=$FSML_V
        _note=""; _lrc=""
        case $_ev in LOADED|TIMEOUT)
            if [ -f "$FSML_RUN/$_m.rc" ]; then
                read -r _lrc < "$FSML_RUN/$_m.rc"
                [ "$_ev" = TIMEOUT ] && _note=" late=1 late_rc=$_lrc"
            else
                _note=" insmod=blocked"; _blk="$_blk $_m"
            fi ;;
        esac
        case $_ev in
        SKIPPED) _o=SKIPPED; _cnt_s=$((_cnt_s + 1)) ;;
        NOTATT)  _o=NOT-ATTEMPTED; _cnt_n=$((_cnt_n + 1)) ;;
        FAILED)  _o=FAILED; _cnt_f=$((_cnt_f + 1)) ;;
        *)       fsml_initstate "$_m"
                 if fsml_ready "$_m"; then
                     case $_note in *insmod=blocked*) _o=READY-BLOCKED; _cnt_rb=$((_cnt_rb + 1)) ;; *) _o=READY; _cnt_r=$((_cnt_r + 1)) ;; esac
                 elif [ "$FSML_IS" = live ]; then _o=PENDING; _cnt_p=$((_cnt_p + 1))
                 elif [ -n "$_lrc" ] && [ "$_lrc" != 0 ]; then _o=FAILED; _cnt_f=$((_cnt_f + 1))
                 elif [ "$_ev" = TIMEOUT ]; then _o=TIMED-OUT; _cnt_t=$((_cnt_t + 1))
                 else _o=FAILED; _cnt_f=$((_cnt_f + 1)); fi ;;
        esac
        fsml_get "$_m" PRED
        fsml_initstate "$_m"
        fsml_rec "OUTCOME $_m phase=$_ph outcome=$_o initstate=$FSML_IS ready=$FSML_V$_note"
        if [ "$_o" = READY-BLOCKED ]; then
            # acceptable only if a device-readiness check covers its function: its own predicate has a
            # device atom, or it is a "live" infrastructure entry whose device side the S/E roots' checks
            # prove (derive-phases.py live-coverage check; those roots must themselves be READY here)
            _cov=no
            case ",$FSML_V," in
            ,live,) _cov=root-checks ;;
            *) _q=",$FSML_V,"; _q=${_q//,live,/,}; _q=${_q//,auto,/,}; [ "$_q" != "," ] && [ -n "${_q//,/}" ] && _cov=own-check ;;
            esac
            fsml_rec "FINDING ready-blocked module=$_m phase=$_ph ready=$FSML_V covered=$_cov (device ready while its insmod is still blocked, e.g. behind another module's pending async probe)"
            _rb="$_rb $_m"
            case $_ph in S|E) [ "$_cov" = no ] && _bad="$_bad $_ph:$_m:READY-BLOCKED-uncovered" ;; esac
        else
            case $_ph in S|E) [ "$_o" = READY ] || _bad="$_bad $_ph:$_m:$_o" ;; esac
        fi
    done
    [ -n "$_rpbad" ] && _bad="$_bad $_rpbad"
    [ $_ceil = 1 ] && _bad="$_bad S:ceiling:REACHED"
    [ -n "$_fskip" ] && _bad="$_bad F:all:SKIPPED-s-not-ready"
    if [ "$FSML_LATCH" = 1 ]; then
        _lf="$FSML_PROC/sys/kernel/modules_disabled"
        echo 1 > "$_lf" 2>/dev/null; _g=unreadable; [ -r "$_lf" ] && read -r _g < "$_lf"
        if [ "$_g" = 1 ]; then fsml_rec "LATCH modules_disabled=1"
        else fsml_rec "LATCH FAILED modules_disabled=$_g"; _bad="$_bad latch"; fi
    fi
    _blk=${_blk# }
    _rb=${_rb# }
    fsml_rec "SUMMARY ready=$_cnt_r ready_blocked=$_cnt_rb pending=$_cnt_p failed=$_cnt_f timed_out=$_cnt_t skipped=$_cnt_s not_attempted=$_cnt_n insmod_blocked=${_blk:-none}"
    if [ -z "$_bad" ]; then
        FSML_VERDICT=OK
        fsml_rec "HANDOFF verdict=OK${_rb:+ ready_blocked=${_rb// /,}}${_blk:+ insmod_blocked=${_blk// /,}}"
        return 0
    fi
    _bad=${_bad# }
    fsml_rec "HANDOFF verdict=REFUSED not_ready=${_bad// /,}$_fskip"
    return 1
}
