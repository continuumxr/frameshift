# FS-A-006 research — Valve userspace vs the Quest 3 stock kernel

Agent report, 2026-10-08. Offline and read-only. Scratch files are in WSL
`~/work/fs006`: `q.config`, `v.config` and `closure.sh`.

The systemd README for the exact version ships in the rootfs, at
`usr/share/doc/systemd/README`.

## Versions [M-static: `usr/lib/holo/pacmandb/local/*`]

- systemd **257.7-2.2**, built `-SELINUX -APPARMOR +SECCOMP +BPF_FRAMEWORK +BTF`.
- glibc 2.39-2, coreutils 9.5-1, bash 5.3.3-3.
- zram-generator 1.2.1, bubblewrap 0.9.0.
- Valve's kernel package: `linux-618-deckard-6.18.0+gfbdbca41fd45`.
- Kernel 5.10.198 is above systemd 257's recommended baseline of 5.4 and
  meets every version-gated README feature [D].

## Kernel options Valve userspace needs that the Quest kernel lacks

Quest and Valve states are [M-static], from the two configs.

| option | needed by | hard/soft | Quest | Valve |
|---|---|---|---|---|
| DEVTMPFS (+_MOUNT) | systemd PID 1 `/dev`, udev (README "required") | **Hard** | n | y |
| FHANDLE | systemd: libudev and mount handling (README "required") | **Hard** per README; runtime severity [O] | n | y |
| BTRFS_FS | Valve root fs as shipped | **Hard** for the stock layout | n | y |
| USER_NS | `PrivateUsers=`. `bwrap` is 0755, not setuid, so flatpak and pressure-vessel need unprivileged userns [D] | **Hard** for the Steam runtime; soft for PID 1 | n | y |
| PID_NS | bwrap `--unshare-pid`, nspawn [C] | Hard for sandboxes [C] | n | y |
| SYSVIPC, POSIX_MQUEUE, IPC_NS | `dev-mqueue.mount`, `PrivateIPC=`, SysV shm users [C] | Soft for boot; likely hard for the desktop [C] | n | y |
| AUTOFS_FS | fstab automounts for `/efi` and `/esp`; binfmt automount | Soft (nofail) | n | y |
| TMPFS_XATTR, TMPFS_POSIX_ACL | README "strongly recommended" | Soft | n | y |
| CGROUP_PIDS | `TasksMax=` | Soft | n | y |
| CGROUP_DEVICE | cgroup v1 only; v2 uses CGROUP_BPF, which is present [C] | Soft | n | y |
| BPF_LSM | `RestrictFileSystems=` | Soft | n | y |
| VT | logind, getty, Xorg/kwin [C] | Soft | n | y |
| NTSYNC | `modules-load.d` (Wine/Proton) | Soft | absent (6.14+) | y |
| CRYPTO_USER | `modules-load.d` | Soft | n | y |
| ZRAM, CRYPTO_LZO | `zram-generator.conf` | Soft; the Quest has a vendor `.ko` | m | y |
| HUGETLBFS, FANOTIFY, SCHED_AUTOGROUP, SECURITY_YAMA, CHECKPOINT_RESTORE, PROC_CHILDREN, SQUASHFS, EROFS | misc, sysext, flatpak [C] | Soft | n | y |
| FW_LOADER_USER_HELPER | README wants it n | Soft (inverse) | y | n |
| STATIC_USERMODEHELPER, PATH="" | `core_pattern` pipe, `request_module`, probably blocked [C] | Soft | y | n |
| ARM64_VA_BITS | large VA reservations (CEF/V8, Mesa, Proton, FEX) [C] | Soft [O] | 39 | 48 |

**Present on the Quest kernel and OK [M-static]:**
- CGROUPS, MEMCG, PSI, CGROUP_BPF, BPF_JIT, DEBUG_INFO_BTF;
- INOTIFY_USER, SIGNALFD, TIMERFD, EPOLL;
- SECCOMP_FILTER, KCMP;
- NET_NS, UTS_NS, TIME_NS;
- OVERLAY_FS, EXT4 + POSIX_ACL, VFAT, FUSE;
- IO_URING, BINFMT_MISC, USERFAULTFD, MEMFD;
- DM_VERITY, DM_CRYPT, TUN, VETH, BRIDGE.

**SELinux:** built in and the default LSM on the Quest. Valve's systemd is
`-SELINUX`, so no policy is loaded [C].

## Loader facts [M-static unless tagged]

- **ABI tag:** Linux 4.4.0 in `libc.so.6` and the executables.
- **Page size:** PT_LOAD `p_align` is 64K, which is fine on the Quest's 4K
  pages (`ARM64_4K_PAGES=y`, VA_BITS 39, 3-level page tables) [D].
- **ARM extensions:** no BTI/PAC GNU property notes.
- **Instruction set:**
  - `makepkg.conf` sets no `-march`.
  - libc has a few LSE/SVE instructions, presumably in hwcap/ifunc-gated
    paths [C].
  - No `glibc-hwcaps/` directory.
- **rseq:** `CONFIG_RSEQ=n` on both kernels, so glibc's rseq registration
  fails non-fatally [C].
- **ld.so:** ET_DYN with no DT_NEEDED, so it can be exec'd directly. It
  supports `--list-diagnostics`, `--inhibit-cache`, `--library-path` and
  `--list`.

## Track B — smallest genuine-Valve test

| set | files | bytes |
|---|---|---|
| T0 `ld-linux-aarch64.so.1 --list-diagnostics` | 1 | 204,048 |
| **T1** `b2sum` + `uname` + `libc.so.6` + `ld.so` | 4 | 2,062,760 |
| T2 `sha256sum` (+ `libcrypto.so.3`, which exercises OpenSSL's hwcap dispatch) | 4 | 7,510,536 |
| bash (+ readline, ncursesw) | 5 | 4,112,384 |
| `systemd --version` | ~17 | ~18 MB (defer) |

**Reference SHA-256** [M-static, from `~/sfroot-full/usr`]:

| file | SHA-256 |
|---|---|
| `bin/b2sum` | `90154680070cfcb2a3027b8fa26a8091d24333329294a2f4be7a12c7f11f6402` |
| `bin/uname` | `4295f034edf7d62f721cfe994230ba139646c7872dc2a6899aa681f76fca31f1` |
| `lib/libc.so.6` | `be7ee393429d493c4d3b996ed25cbb02fabb2896a77efe6d57e5993ead5bbb3b` |
| `lib/ld-linux-aarch64.so.1` | `2ddc56a02f476765a21e31d69144e68bee933950fe613747d54b87a2369a037e` |
| `bin/sha256sum` | `0261208042845591548fc212562f3f2f087630ef46e2be639ce72fd5a7116303` |
| `lib/libcrypto.so.3` | `0668c1fe3de7e7823d86597befa1a5299b29c1ac83d707d1d91f9f931f3c3ae2` |

**Invocation from our busybox initramfs.** No chroot and no systemd. Files go
in `/valve/{bin,lib}`, with `/proc` mounted [D]:

```
L=/valve/lib/ld-linux-aarch64.so.1; R="$L --inhibit-cache --library-path /valve/lib"
busybox sha256sum /valve/bin/b2sum /valve/bin/uname /valve/lib/*
$L --list-diagnostics
$R --list /valve/bin/b2sum
$R /valve/bin/uname -a
$R /valve/bin/b2sum --version
printf '' | $R /valve/bin/b2sum
N=$(cat /proc/sys/kernel/random/boot_id); printf '%s' "$N" | $R /valve/bin/b2sum
```

**PASS requires all of the following [D]:**
- The busybox hashes match the table above.
- The empty-input known-answer test prints
  `786a02f7…1afe9be2ce` (BLAKE2b-512 of "", host-verified).
- The digest of the per-boot `boot_id` equals the host's computation.

The Arbiter's note: in the real design, the nonce should come from the
**host challenge** over the existing protocol, not from `boot_id`. Otherwise
the device both chooses and answers it.

## Open

1. Does systemd 257 PID 1 or udevd abort without `name_to_handle_at`
   (FHANDLE), or does it fall back? [O]
2. Without DEVTMPFS, can the stock-kernel path reach systemd at all? A tmpfs
   `/dev` loses hotplug nodes [C]. DEVTMPFS, FHANDLE, USER_NS, PID_NS and
   SYSVIPC are built-in only, so no module can supply them [D].
3. How userspace reacts when 6.x-only syscalls are missing on 5.10
   (fallbacks expected) [C].
4. Does 39-bit VA break Steam/CEF or Mesa? [O]
5. Confirm that the empty static usermode-helper path blocks
   `core_pattern` pipes [C].
6. RAUC slots are `type=raw` on `/dev/disk/by-partsets/{A,B}/rootfs`
   (`etc/rauc/system.conf`) [M-static]. Is the btrfs root required? [O]
