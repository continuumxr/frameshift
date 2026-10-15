#!/bin/bash
# FrameShift Quest 2 channel — device-side fixtures (run inside WSL; offline):
#   wsl.exe -e bash <repo>/devices/quest2/channel/tools/fixtures-device.sh
# Sections:
#   D  fs-rpcd responder cases (tools/device_cases.py), twice: the shipped aarch64 binary under
#      qemu-aarch64, and the native ASan/UBSan build
#   G  target/fs-ncm.sh gadget logic under the reviewed busybox (qemu-aarch64) against a fake
#      configfs/sysfs/procfs tree (mkdir is wrapped to emulate configfs attribute files)
#   L  fs_ncm_net + fs_rpc_start in an unprivileged user+net namespace on a veth pair:
#      real IPv6 link-local fe80::<nonce>/64, scoped bind, client in a second namespace
#   I  integration: the simulated PID 1 (common/target/pid1-hold.sh, read only) with fs-rpcd as
#      its child; ack/done over TCP, deadline independence under slow-loris and responder death
# Touches no device. Writes fixtures/device/*.txt.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # with -I the variable is ignored (-I implies -E), so every call also passes -B

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)"
HERE=$ROOT/devices/quest2/channel
Q3C=$ROOT/devices/quest3/common
BB_SRC=$ROOT/build/third_party/busybox/busybox
HOLD=$Q3C/target/pid1-hold.sh
FX=$HERE/fixtures/device
# refuse BEFORE touching any committed result file when a gitignored build input is missing
for _in in "$BB_SRC" "$HERE/build/fs-rpcd" "$HERE/build/fs-rpcd.asan"; do
    [ -f "$_in" ] || { echo "REFUSED: build input missing: $_in (gitignored; see README \"What is not in git\"); nothing was written"; exit 1; }
done
W=$(mktemp -d /tmp/fsq2dev.XXXXXX)
trap 'pkill -9 -f "$W/" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$FX"
SUM=$FX/RESULTS.txt; : > "$SUM"
NONCE=0123456789abcdef

[ "$(sha256sum "$BB_SRC" | cut -c1-64)" = c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02 ] \
    || { echo "REFUSED: busybox is not the reviewed binary"; exit 1; }
[ -f "$HERE/build/fs-rpcd" ] && [ -f "$HERE/build/fs-rpcd.asan" ] || { echo "REFUSED: run tools/build.sh first"; exit 1; }
mkdir -p "$W/bin"
cp "$BB_SRC" "$W/bin/busybox"; chmod 0755 "$W/bin/busybox"
for a in sh cut cat echo sleep head rm mv printf mkfifo sync ls tr grep ln mount ip; do ln -s busybox "$W/bin/$a"; done
cp "$HERE/build/fs-rpcd" "$W/bin/fs-rpcd"; chmod 0755 "$W/bin/fs-rpcd"
cp "$Q3C/build/fs-supervise" "$W/fs-supervise"; chmod 0755 "$W/fs-supervise"
BB=$W/bin/busybox
{
echo "fs-rpcd      sha256=$(sha256sum "$HERE/build/fs-rpcd" | cut -c1-64) (aarch64, under qemu-aarch64)"
echo "fs-rpcd.c    sha256=$(sha256sum "$HERE/src/fs-rpcd.c" | cut -c1-64)"
echo "fs-ncm.sh    sha256=$(sha256sum "$HERE/target/fs-ncm.sh" | cut -c1-64)"
echo "pid1-hold.sh sha256=$(sha256sum "$HOLD" | cut -c1-64) (read only)"
echo "busybox      sha256=$(sha256sum "$BB" | cut -c1-64) (reviewed stage-1 busybox, under qemu-aarch64)"
echo "kernel       $(uname -r) (WSL; netns section)"
} | tee -a "$SUM"
res() { local l; if [ "$2" = 0 ]; then l="$1 PASS $3"; else l="$1 FAIL $3"; fi; echo "$l" | tee -a "$SUM"; }

# ------------------------------------------------------------------ D
echo "== D: responder cases" | tee -a "$SUM"
for v in ${D_VARIANTS-qemu asan native}; do
    extra=""
    case $v in
        qemu)   cmd="qemu-aarch64 $W/bin/fs-rpcd"; pb=47400 ;;
        asan)   cmd="$HERE/build/fs-rpcd.asan"; pb=47600; extra="--native" ;;
        native) cmd="$HERE/build/fs-rpcd.native"; pb=47700; extra="--native --shim $HERE/build/shim-nowait.so" ;;
    esac
    # shellcheck disable=SC2086
    ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    python3 -I -B "$HERE/tools/device_cases.py" --rpcd "$cmd" --work "$W/d-$v" --bb "$BB" --out "$FX/D-$v.txt" --port-base $pb $extra \
        --fsb1-enc "$Q3C/target/fsb1-enc.sh" --fsup "$W/fs-supervise" --fsb1-py "$Q3C/tools/fsb1.py" > "$W/d-$v.log" 2>&1
    rc=$?
    res "D-$v" $rc "$(tail -1 "$FX/D-$v.txt" 2>/dev/null) (fixtures/device/D-$v.txt)"
done

# ------------------------------------------------------------------ G
echo "== G: gadget logic (fake configfs)" | tee -a "$SUM"
# configfs creates a function's attribute files on mkdir. The reviewed busybox ash runs applets
# directly (standalone shell), so a PATH wrapper would be bypassed: the harness-only sim defines a
# shell FUNCTION mkdir (functions take precedence over applets) that emulates the ifname attribute.
mkdir -p "$W/gbin"; for a in sh cut cat echo sleep ls tr grep ln mount mkdir; do ln -s "$BB" "$W/gbin/$a"; done
cat > "$W/gsim.sh" <<'EOF'
mkdir() {   # harness only: configfs attribute emulation (see above)
    "$BB" mkdir "$@" || return $?
    for _d in "$@"; do case "$_d" in */functions/ncm.fs)
        echo "${FAKE_IFNAME:-usb0}" > "$_d/ifname"
        [ -n "${FAKE_RO_DEVADDR:-}" ] && "$BB" mkdir "$_d/dev_addr" ;; esac; done
    return 0
}
ln() {      # harness only: FAKE_LN_FILE makes the "link" a regular file (link readback must catch it)
    if [ -n "${FAKE_LN_FILE:-}" ]; then : > "${3%/}/${2##*/}"; return 0; fi
    "$BB" ln "$@"
}
log()  { echo "LOG $*" >> "$OUTF"; }
fail() { echo "FAIL $1 $2" >> "$OUTF"; exit 3; }
. "$NCM"
fs_ncm_ids
echo "IDS $FS_DEV_MAC $FS_HOST_MAC $FS_LL $FS_LL_RAW $FS_SERIAL" >> "$OUTF"
fs_ncm_udc
fs_ncm_gadget
fs_ncm_role
echo "DONE if=$FS_IF udc=$FS_UDC" >> "$OUTF"
EOF
gtree() {  # gtree DIR UDCNAMES... : a fresh fake tree
    local d=$1; shift
    rm -rf "$d"; mkdir -p "$d/config/usb_gadget" "$d/sys/class/net/usb0" "$d/proc/sys/net/ipv6/conf/default" "$d/sys/devices/platform/soc/a600000.ssusb"
    echo "none $d/config configfs rw 0 0" > "$d/proc/mounts"
    for f in addr_gen_mode accept_dad accept_ra autoconf; do echo 9 > "$d/proc/sys/net/ipv6/conf/default/$f"; done
    echo "02:01:23:45:67:89" > "$d/sys/class/net/usb0/address"
    echo host > "$d/sys/devices/platform/soc/a600000.ssusb/mode"
    for u in "$@"; do mkdir -p "$d/sys/class/udc/$u"; echo "not attached" > "$d/sys/class/udc/$u/state"; done
}
grun() {  # grun NAME TREE [ENV...] -> $W/NAME.out
    local name=$1 d=$2; shift 2
    : > "$W/$name.out"
    ( cd /; env -i PATH="$W/gbin" BB="$BB" NCM="$HERE/target/fs-ncm.sh" OUTF="$W/$name.out" NONCE=$NONCE \
        FS_CONFIG="$d/config" FS_SYS="$d/sys" FS_PROC="$d/proc" FS_UDC_WAIT=1 FS_ROLE_WAIT=1 "$@" \
        /usr/bin/qemu-aarch64 "$BB" sh "$W/gsim.sh" > "$W/$name.stdout" 2>&1 )
    echo $? > "$W/$name.rc"
    { echo "# G $name"; sed 's/^/#   /' "$W/$name.out"; } >> "$FX/G.txt"
}
: > "$FX/G.txt"
T=$W/gt
gtree "$T" a600000.dwc3; grun g1 "$T"
G=$T/config/usb_gadget/fs
ok=0
grep -qx "IDS 02:01:23:45:67:89 06:01:23:45:67:89 fe80::0123:4567:89ab:cdef fe800000000000000123456789abcdef FS-0123456789abcdef" "$W/g1.out" || ok=1
[ "$(cat $G/strings/0x409/serialnumber)" = FS-$NONCE ] || ok=1
[ "$(cat $G/functions/ncm.fs/dev_addr)" = 02:01:23:45:67:89 ] && [ "$(cat $G/functions/ncm.fs/host_addr)" = 06:01:23:45:67:89 ] || ok=1
[ -L "$G/configs/c.1/ncm.fs" ] && [ "$(cat $G/UDC)" = a600000.dwc3 ] || ok=1
[ "$(cat $G/idVendor)/$(cat $G/idProduct)/$(cat $G/bDeviceClass)/$(cat $G/bDeviceSubClass)/$(cat $G/bDeviceProtocol)" = 0x1d6b/0x0104/0xef/0x02/0x01 ] || ok=1
[ "$(cat $T/proc/sys/net/ipv6/conf/default/addr_gen_mode)$(cat $T/proc/sys/net/ipv6/conf/default/accept_dad)$(cat $T/proc/sys/net/ipv6/conf/default/accept_ra)$(cat $T/proc/sys/net/ipv6/conf/default/autoconf)" = 1000 ] || ok=1
grep -qx "DONE if=usb0 udc=a600000.dwc3" "$W/g1.out" || ok=1
[ "$(cat "$W/g1.rc")" = 0 ] || ok=1
res G1-gadget-ok $ok "serial, MACs, IAD class, link, bind, default sysctls, ifname usb0"
[ "$(cat $T/sys/devices/platform/soc/a600000.ssusb/mode)" = peripheral ] && grep -q "ROLE fallback write-rc=0 mode=peripheral" "$W/g1.out"; res G2-role-fallback-when-unattached $? ""
gtree "$T" a600000.dwc3; echo configured > "$T/sys/class/udc/a600000.dwc3/state"; grun g3 "$T"
[ "$(cat $T/sys/devices/platform/soc/a600000.ssusb/mode)" = host ] && ! grep -q "ROLE fallback" "$W/g3.out" && grep -q "^DONE" "$W/g3.out"; res G3-no-role-write-when-attached $? ""
gtree "$T" a600000.dwc3; grun g4 "$T" FS_UDC_EXPECT=a600000.dwc3
grep -q "^DONE" "$W/g4.out"; res G4-udc-expect-match $? ""
gneg() {  # gneg NAME WANTREGEX SETUPFN [ENV...]
    local name=$1 want=$2 setup=$3; shift 3
    gtree "$T" a600000.dwc3; $setup; grun "$name" "$T" "$@"
    local ok=0
    grep -Eq "^FAIL $want" "$W/$name.out" || ok=1
    grep -q "^DONE" "$W/$name.out" && ok=1
    [ "$(cat "$W/$name.rc")" = 3 ] || ok=1
    res "$name" $ok "$(grep '^FAIL' "$W/$name.out" | head -1)"
}
none() { :; }
noudc() { rm -rf "$T/sys/class/udc"/*; }
twoudc() { mkdir -p "$T/sys/class/udc/b000000.dwc3"; }
badudc() { rm -rf "$T/sys/class/udc"/*; mkdir -p "$T/sys/class/udc/x;reboot"; }
exists() { mkdir -p "$T/config/usb_gadget/fs"; }
wrongmac() { echo "02:00:00:00:00:01" > "$T/sys/class/net/usb0/address"; }
noconfigfs() { rm -rf "$T/config/usb_gadget"; }
gneg G5-udc-expect-mismatch "udc UDC 'a600000.dwc3' is not" none FS_UDC_EXPECT=a800000.dwc3
gneg G6-no-udc "udc no UDC" noudc
gneg G7-two-udcs "udc expected one UDC" twoudc
gneg G8-unsafe-udc-name "udc unsafe UDC name" badudc
gneg G9-gadget-exists "ncm gadget already exists" exists
gneg G10-netdev-mac-mismatch "net usb0 does not carry" wrongmac
gneg G11-bad-ifname "net bad ifname" none FAKE_IFNAME='usb0;x'
gneg G12-bad-nonce "ncm bad nonce" none NONCE=0123456789ABCDEF
gneg G13-short-nonce "ncm bad nonce length" none NONCE=0123
gneg G14-no-configfs "ncm no configfs" noconfigfs
gneg G15-write-fails "ncm write /usb_gadget/fs/functions/ncm.fs/dev_addr=" none FAKE_RO_DEVADDR=1
gneg G16-link-readback "ncm readback link" none FAKE_LN_FILE=1
gneg G17-bad-numeric-setting "ncm bad numeric setting 'abc'" none FS_RPC_WAIT=abc
# fs_rpc_start (review m7): RPC_READY only after the responder's own "listening" line, pid alive
cat > "$W/rsim.sh" <<'EOF'
log()  { echo "LOG $*" >> "$OUTF"; }
# like the real fail(): record, then WAIT (ERR_DELAY, scaled to 4 s) before "rebooting" - the
# responder must already be dead during this wait (rev 3, N1)
fail() { echo "FAIL $1 $2" >> "$OUTF"; echo "ERROR_$1" >> "$FS_RUN/fs.stages"; sleep 4; exit 3; }
. "$NCM"
fs_ncm_ids
FS_IF=usb0
fs_rpc_start
echo "DONE pid=$FS_RPC_PID" >> "$OUTF"
EOF
fake_rpcd() {  # fake_rpcd NAME BODY : a stand-in responder (busybox sh); records its pid first
    printf '#!%s sh\necho $$ > "$FS_RUN/fake.pid"\n%s\n' "$BB" "$2" > "$W/$1"; chmod 0755 "$W/$1"
}
fake_rpcd rp-exit 'exit 3'
fake_rpcd rp-silent "exec $BB sleep 30"
fake_rpcd rp-wrongport "echo 'FSRPC listening port=47999 fam=inet6 if=usb0' >> \"\$FS_RUN/fs.rpc.log\"; exec $BB sleep 30"
fake_rpcd rp-ok "echo 'FSRPC listening port=47101 fam=inet6 if=usb0' >> \"\$FS_RUN/fs.rpc.log\"; exec $BB sleep 30"
# starts listening only after the 2 s wait has expired: without the N1 kill it would come up
# during fail()'s ERR_DELAY and could then answer the host
fake_rpcd rp-late "$BB sleep 3; echo 'FSRPC listening port=47101 fam=inet6 if=usb0' >> \"\$FS_RUN/fs.rpc.log\"; echo late-served >> \"\$FS_RUN/late.marker\"; exec $BB sleep 30"
rrun() {  # rrun NAME BIN WANT [ENV...]
    local name=$1 bin=$2 want=$3; shift 3
    rm -rf "$W/$name.run"; mkdir -p "$W/$name.run"; : > "$W/$name.out"
    [ "${STALE:-0}" = 1 ] && echo "FSRPC listening port=47101 fam=inet6 if=usb0" > "$W/$name.run/fs.rpc.log"
    ( cd /; env -i PATH="$W/gbin" BB="$BB" NCM="$HERE/target/fs-ncm.sh" OUTF="$W/$name.out" NONCE=$NONCE \
        FS_RUN="$W/$name.run" FS_RPC_BIN="$W/$bin" FS_RPC_WAIT=2 "$@" \
        /usr/bin/timeout 30 /usr/bin/qemu-aarch64 "$BB" sh "$W/rsim.sh" > "$W/$name.stdout" 2>&1 )
    local rc=$?
    sleep 1                                   # rp-late would have come up by now if it survived
    local fp alive=no
    fp=$(cat "$W/$name.run/fake.pid" 2>/dev/null)
    if [ -n "$fp" ] && kill -0 "$fp" 2>/dev/null; then alive=yes; fi
    { echo "# G $name (responder alive after the run: $alive)"; sed 's/^/#   /' "$W/$name.out"; } >> "$FX/G.txt"
    pkill -9 -f "$W/$bin" 2>/dev/null
    if [ "$want" = DONE ]; then
        grep -q "^DONE" "$W/$name.out" && grep -q "listening$" "$W/$name.out" && [ $alive = yes ]
        res "$name" $? "$(grep '^LOG RPC' "$W/$name.out")"
    elif [ "$want" = "stale fs.rpc.log" ]; then
        grep -q "^FAIL rpc $want" "$W/$name.out" && [ $rc = 3 ] && [ -z "$fp" ]
        res "$name" $? "$(grep '^FAIL' "$W/$name.out") (responder never started)"
    else
        # the responder is dead, it was stopped BEFORE the FAIL line, and it never came up late
        grep -q "^FAIL rpc $want" "$W/$name.out" && [ $rc = 3 ] && [ $alive = no ] && [ ! -e "$W/$name.run/late.marker" ] \
            && awk '/^LOG RPC stopped/ {s=NR} /^FAIL rpc/ {f=NR} END {exit !(s && f && s < f)}' "$W/$name.out"
        res "$name" $? "$(grep -E '^(LOG RPC stopped|FAIL)' "$W/$name.out" | tr '\n' ' ') alive=$alive"
    fi
}
rrun G18-rpc-exits-before-listening rp-exit "responder exited before listening"
rrun G19-rpc-never-listens-killed rp-silent "responder not listening after 2s"
rrun G20-rpc-other-port-killed rp-wrongport "responder not listening after 2s"
rrun G21-rpc-listening-ok rp-ok DONE
STALE=1 rrun G22-stale-rpc-log rp-ok "stale fs.rpc.log"
rrun G23-late-listener-killed-before-err-delay rp-late "responder not listening after 2s"

# ------------------------------------------------------------------ L
echo "== L: link-local bring-up in a user+net namespace (veth)" | tee -a "$SUM"
cat > "$W/lsim.sh" <<'EOF'
log()  { echo "LOG $*" >> "$OUTF"; }
fail() { echo "FAIL $1 $2" >> "$OUTF"; exit 3; }
. "$NCM"
fs_ncm_ids
FS_IF=$LIF
fs_ncm_net
fs_rpc_start
echo "DONE ll=$FS_LL if=$FS_IF pid=$FS_RPC_PID" >> "$OUTF"
EOF
cat > "$W/lns.sh" <<EOF
#!/bin/bash
# runs as root of a fresh user+net namespace (unshare -rn)
set -u
W=$W; BB=$BB; HERE=$HERE; NONCE=$NONCE
ip link add veth0 type veth peer name veth1 || exit 90
ip link set lo up
unshare -n sleep 120 &          # namespace B (the "host" side)
NB=\$!; sleep 0.3
ip link set veth1 netns \$NB || exit 91
nsenter -t \$NB -n sh -c 'echo 1 > /proc/sys/net/ipv6/conf/veth1/addr_gen_mode; echo 0 > /proc/sys/net/ipv6/conf/veth1/accept_dad; ip link set lo up; ip link set veth1 up; ip -6 addr add fe80::1/64 dev veth1' || exit 92
mkdir -p \$W/lrun
: > \$W/l1.out
( cd /; env -i PATH=\$W/bin NCM=\$HERE/target/fs-ncm.sh OUTF=\$W/l1.out NONCE=\$NONCE LIF=veth0 FS_RUN=\$W/lrun \
    FS_RPC_BIN=$W/bin/fs-rpcd /usr/bin/qemu-aarch64 \$BB sh \$W/lsim.sh > \$W/l1.stdout 2>&1 )
echo "RC \$?" >> \$W/l1.out
cat /proc/net/if_inet6 > \$W/l1.inet6
sleep 1
nsenter -t \$NB -n python3 -I -B \$HERE/tools/rpc.py "fe80::0123:4567:89ab:cdef%veth1" 47101 --verify \$NONCE > \$W/l2.out 2>&1; echo "RC \$?" >> \$W/l2.out
nsenter -t \$NB -n python3 -I -B \$HERE/tools/rpc.py "fe80::0123:4567:89ab:cdef%veth1" 47101 "fs-ack \$NONCE 00112233aabbccdd" > \$W/l3.out 2>&1
nsenter -t \$NB -n python3 -I -B \$HERE/tools/rpc.py "fe80::0123:4567:89ab:cdef%veth1" 47101 "fs-done \$NONCE" > \$W/l4.out 2>&1
# not reachable on any other address: ::1 and 127.0.0.1 inside namespace A
python3 -I -B \$HERE/tools/rpc.py ::1 47101 "fs-status \$NONCE" > \$W/l5.out 2>&1; echo "RC \$?" >> \$W/l5.out
python3 -I -B \$HERE/tools/rpc.py 127.0.0.1 47101 "fs-status \$NONCE" > \$W/l6.out 2>&1; echo "RC \$?" >> \$W/l6.out
cp \$W/lrun/fs.rpc.log \$W/l.rpclog 2>/dev/null
# negative: an interface that already has a kernel-generated address (link was up with addr_gen_mode 0)
ip link add veth2 type veth peer name veth3; ip link set veth3 up; ip link set veth2 up; sleep 0.5
: > \$W/l7.out
( cd /; env -i PATH=\$W/bin NCM=\$HERE/target/fs-ncm.sh OUTF=\$W/l7.out NONCE=fedcba9876543210 LIF=veth2 FS_RUN=\$W/lrun \
    FS_RPC_BIN=\$W/bin/fs-rpcd FS_RPC_PORT=47102 /usr/bin/qemu-aarch64 \$BB sh \$W/lsim.sh > \$W/l7.stdout 2>&1 )
echo "RC \$?" >> \$W/l7.out
pkill -9 -f "\$W/bin/fs-rpcd" 2>/dev/null
kill \$NB 2>/dev/null
exit 0
EOF
chmod 0755 "$W/lns.sh"
timeout 120 unshare -rn "$W/lns.sh" > "$W/lns.log" 2>&1
lrc=$?
{ echo "# L (unshare -rn rc=$lrc)"; for f in l1.out l1.inet6 l2.out l3.out l4.out l5.out l6.out l.rpclog l7.out; do echo "## $f"; sed 's/^/#   /' "$W/$f" 2>/dev/null; done; } > "$FX/L.txt"
ok=0; grep -q "^DONE ll=fe80::0123:4567:89ab:cdef if=veth0" "$W/l1.out" && grep -q "^RC 0" "$W/l1.out" || ok=1
grep -Eq "^fe800000000000000123456789abcdef [0-9a-f]{2} 40 20 80 +veth0$" "$W/l1.inet6" || ok=1
[ "$(grep -c ' veth0$' "$W/l1.inet6")" = 1 ] || ok=1
res L1-linklocal-permanent-single $ok "$(grep ' veth0$' "$W/l1.inet6" | tr -s ' ')"
grep -q "^OK " "$W/l2.out"; res L2-verify-over-scoped-linklocal $? "$(head -c 120 "$W/l2.out")"
grep -q "FSA1 queued END" "$W/l3.out" && [ "$(cat "$W/lrun/host_ack" 2>/dev/null)" = 00112233aabbccdd ]; res L3-ack-over-linklocal $? ""
grep -q "FSD1 queued END" "$W/l4.out" && [ -f "$W/lrun/fs.collected" ]; res L4-done-over-linklocal $? ""
grep -q "ConnectionRefused\|RC 1" "$W/l5.out" && grep -q "ConnectionRefused\|RC 1" "$W/l6.out"; res L5-not-on-loopback $? "bound to fe80::<nonce>%veth0 only"
grep -q "^FAIL net address state" "$W/l7.out" && grep -q "^RC 3" "$W/l7.out"; res L6-refuses-extra-kernel-address $? "$(grep '^FAIL' "$W/l7.out")"

# ------------------------------------------------------------------ I
echo "== I: simulated PID 1 (pid1-hold.sh) + fs-rpcd" | tee -a "$SUM"
cat > "$W/bin/fake-reboot" <<EOF
#!$W/bin/sh
read -r u _ < /proc/uptime
echo "\${u%%.*} \${1:-none} pid=\$\$ via=fork" >> "\$FS_REC"
exit 1
EOF
cat > "$W/bin/fake-final" <<EOF
#!$W/bin/sh
read -r u _ < /proc/uptime
echo "\${u%%.*} \${1:-none} pid=\$\$ via=final" >> "\$FS_REC"
while :; do sleep 3600; done
EOF
chmod 0755 "$W/bin/fake-reboot" "$W/bin/fake-final"
up() { cut -d. -f1 /proc/uptime; }
isim() {  # isim NAME PORT DL AW : starts the sim; sets SP R REC
    local name=$1; PORT=$2
    R=$W/i-$name/run; REC=$W/i-$name/rec; mkdir -p "$R"
    ( cd /; exec setsid env -i PATH="$W/bin" HOLD="$HOLD" FS_RUN="$R" FS_REC="$REC" FS_UPTIME=/proc/uptime \
        FS_REBOOT_BIN="$W/bin/fake-reboot" FS_REBOOT_FINAL="$W/bin/fake-final" FS_REBOOT_FALLBACK="$W/bin/fake-reboot fallback" \
        DL=$3 AW=$4 RPCD="$W/bin/fs-rpcd" ADDR=127.0.0.1 PORT=$PORT NONCE=$NONCE \
        /usr/bin/qemu-aarch64 "$BB" sh "$HERE/tools/sim-pid1.sh" > "$W/i-$name/stdout" 2>&1 ) &
    SP=$!
    local t=$(( $(up) + 15 ))
    while [ ! -f "$R/READY" ] && [ "$(up)" -lt "$t" ]; do sleep 0.2; done
    t=$(( $(up) + 10 ))
    while ! grep -q listening "$R/fs.rpc.log" 2>/dev/null && [ "$(up)" -lt "$t" ]; do sleep 0.2; done
}
istop() { pkill -9 -f "$R/" 2>/dev/null; pkill -9 -f "fs-rpcd -n $NONCE -a 127.0.0.1 -p $PORT " 2>/dev/null; kill -9 $SP 2>/dev/null; { wait $SP; } 2>/dev/null; }
iwait() { local t=$(( $(up) + $1 )); while [ ! -s "$REC" ] && [ "$(up)" -lt "$t" ]; do sleep 0.2; done; }
first() { head -1 "$REC" 2>/dev/null | cut -d' ' -f2; }
rel() { echo $(( $(head -1 "$REC" | cut -d' ' -f1) - $(cat "$REC.t0") )); }
idump() { { echo "# I $1: reboot records (first counts), t0=$(cat "$REC.t0" 2>/dev/null)"; sed 's/^/#   /' "$REC" 2>/dev/null; echo "# rpc log:"; sed 's/^/#   /' "$R/fs.rpc.log" 2>/dev/null; echo "# pid1 log:"; sed 's/^/#   /' "$R/fs.log" 2>/dev/null; } >> "$FX/I.txt"; }
: > "$FX/I.txt"
RPC="python3 -I -B $HERE/tools/rpc.py 127.0.0.1"

# I1: verify, ack, PID 1 records it, status shows it, done -> PID 1 reboots now ("collected")
isim i1 47801 40 30
v=$($RPC $PORT --verify $NONCE); a=$($RPC $PORT "fs-ack $NONCE a1a2a3a4a5a6a7a8"); sleep 2.5
s=$($RPC $PORT "fs-status $NONCE"); d0=$(up); dn=$($RPC $PORT "fs-done $NONCE"); iwait 10; d1=$(up)
idump I1
ok=0; case "$v" in OK*) ;; *) ok=1 ;; esac
case "$a" in *"FSA1 queued END"*) ;; *) ok=1 ;; esac
case "$s" in *"stages=INIT_STARTED,SHELL_READY,HOST_ACK acked=a1a2a3a4a5a6a7a8 END"*) ;; *) ok=1 ;; esac
case "$dn" in *"FSD1 queued END"*) ;; *) ok=1 ;; esac
[ "$(first)" = collected ] && [ $((d1 - d0)) -le 3 ] || ok=1
res I1-ack-recorded-done-reboots $ok "first=$(first) after=$((d1 - d0))s status=$s"
istop

# I2: no ack -> PID 1 reboots at the ack window (no-host-ack)
isim i2 47802 20 6
iwait 30; idump I2
[ "$(first)" = no-host-ack ] && [ "$(rel)" -ge 6 ] && [ "$(rel)" -le 9 ]; res I2-no-ack-window $? "first=$(first) at T0+$(rel)s"
istop

# I3: ack, then a slow-loris storm on the responder: PID 1 still reboots at its deadline
isim i3 47803 14 10
$RPC $PORT "fs-ack $NONCE b1b2b3b4b5b6b7b8" > /dev/null
( while :; do $RPC $PORT --hold 5 >/dev/null 2>&1 & sleep 0.3; done ) & LP=$!
iwait 30; kill $LP 2>/dev/null; pkill -f -- "--hold 5" 2>/dev/null; idump I3
[ "$(first)" = deadline ] && [ "$(rel)" -ge 14 ] && [ "$(rel)" -le 16 ]; res I3-deadline-under-slowloris $? "first=$(first) at T0+$(rel)s"
istop

# I4: ack, then the responder is killed: PID 1 is unaffected and reboots at its deadline
isim i4 47804 12 10
$RPC $PORT "fs-ack $NONCE c1c2c3c4c5c6c7c8" > /dev/null
kill -9 "$(cat "$REC.rpcpid")" 2>/dev/null
iwait 30; idump I4
[ "$(first)" = deadline ] && [ "$(rel)" -ge 12 ] && [ "$(rel)" -le 14 ]; res I4-deadline-after-responder-death $? "first=$(first) at T0+$(rel)s"
istop

# I5: an ack with the wrong nonce is refused and never reaches PID 1 -> no-host-ack
isim i5 47805 20 6
o=$($RPC $PORT "fs-ack fedcba9876543210 d1d2d3d4d5d6d7d8")
iwait 30; idump I5
[ "$(first)" = no-host-ack ] && case "$o" in *"error=nonce END"*) true ;; *) false ;; esac; res I5-wrong-nonce-ack-ignored $? "first=$(first) resp=$o"
istop

n=$(awk '$2 == "PASS"' "$SUM" | wc -l); f=$(awk '$2 == "FAIL"' "$SUM" | wc -l)   # field 2 only: details may contain "FAIL"
echo "TOTAL sections: $n PASS, $f FAIL" | tee -a "$SUM"
[ "$f" = 0 ]
