# FrameShift Quest 2 channel — simulated stage-1 PID 1 for the fixtures (busybox ash,
# under qemu-aarch64; never on a device). It is the Quest 2 PID 1 shape with the
# USB/net part replaced by a responder on a fixture address:
#   . pid1-hold.sh (devices/quest3/common/target, READ ONLY, unchanged semantics)
#   fs_hold_init DL AW ; fs_start_backstop ; fs-rpcd as a child ; fs_hold_loop
# Only the reboot SYSCALL is faked (FS_REBOOT_FINAL / FS_REBOOT_BIN record and
# return/sleep, as in common/tools/fixtures-deadline.sh).
# Environment: HOLD FS_RUN FS_REC DL AW RPCD ADDR PORT NONCE [RUNNER RUNNER_S]
read -r _h _ < /proc/uptime; echo "${_h%%.*}" > "$FS_REC.start"
. "$HOLD"
log()   { echo "FS t=$(cut -d. -f1 /proc/uptime)s $*" >> "$FS_RUN/fs.log"; }
stage() { echo "$1" >> "$FS_RUN/fs.stages"; log "STAGE=$1 $2"; }
led()   { :; }
fs_hold_init "$DL" "$AW"
echo "$T0" > "$FS_REC.t0"; echo "$$" > "$FS_REC.pid"
fs_start_backstop
stage INIT_STARTED
if [ -n "${RUNNER:-}" ]; then
    "$RPCD" -n "$NONCE" -a "$ADDR" -p "$PORT" -r "$FS_RUN" -c "$RUNNER" -T "$RUNNER_S" </dev/null >"$FS_REC.rpcd-err" 2>&1 &
else
    "$RPCD" -n "$NONCE" -a "$ADDR" -p "$PORT" -r "$FS_RUN" </dev/null >"$FS_REC.rpcd-err" 2>&1 &
fi
echo "$!" > "$FS_REC.rpcpid"
stage SHELL_READY
echo ready > "$FS_RUN/READY"
fs_hold_loop
