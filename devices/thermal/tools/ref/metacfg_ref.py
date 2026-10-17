#!/usr/bin/env python3
"""Reference reader (test oracle) for fs-metacfg, METACFG-SPEC.md rev 1.

Written from the spec text only, independently of src/fs-metacfg.c and of
tools/fix/mkfix.py. Standard library only. The JSON parser is our own (the
json module is not used anywhere in this file) so that M-22..M-25 are exact.

Scope: M-1, M-2 (locate super, uevent wait) and M-5 (seccomp) are not
modelled. M-3's result comes in as --slot-suffix; M-4's size is the image
file size. Everything from M-6 to M-27 is implemented, including the read
budget (M-5, last bullet), counted in bytes exactly as the reads below are
issued:

  geometry 4096, metadata metadata_max_size, superblock 1024, each 32-byte
  group descriptor, each 256-byte inode, each 4096-byte directory, extent
  tree or data block.

Usage:
  python3 -I metacfg_ref.py --image SUPER_IMG --device eureka|hollywood
      --slot-suffix _a|_b [--super-size N] --out RECORD_FILE

Importable: read_super(path, device, slot_suffix, super_size=None) -> bytes

Choices made where the spec is silent are marked "AMBIGUITY" below; each
picks the more rejecting reading.
"""

import argparse
import hashlib
import os
import re
import struct
import sys
import traceback

# ---------------------------------------------------------------- constants

# Section 6 status codes (stable; never renumbered).
STATUS = {
    'ok': 0, 'arg': 1, 'no-super': 2, 'super-ambiguous': 3, 'super-type': 4,
    'super-size': 5, 'slot': 6, 'seccomp': 7, 'io': 8, 'read-budget': 9,
    'lp-geometry': 10, 'lp-header': 11, 'lp-checksum': 12, 'lp-tables': 13,
    'lp-blockdev': 14, 'lp-name': 15, 'vab-merge': 16, 'no-vendor': 17,
    'vendor-dup': 18, 'vendor-disabled': 19, 'extent-type': 20,
    'fs-type': 21, 'ext4-blocksize': 22, 'ext4-features': 23,
    'ext4-inode-size': 24, 'ext4-geometry': 25, 'ext4-size': 26,
    'ext4-inode': 27, 'ext4-range': 28, 'ext4-inode-flags': 29,
    'ext4-isize': 30, 'ext4-extent-magic': 31, 'ext4-extent-count': 32,
    'ext4-extent-depth': 33, 'ext4-uninit': 34, 'ext4-hole': 35,
    'ext4-notdir': 36, 'ext4-dirent': 37, 'ext4-dir-cap': 38,
    'file-missing': 39, 'file-type': 40, 'file-size': 41, 'buildprop': 42,
    'json-syntax': 43, 'json-depth': 44, 'json-dupkey': 45,
    'json-unknown-key': 46, 'json-number': 47, 'json-vr': 48,
    'json-monitor': 49, 'json-name': 50, 'json-dupname': 51,
    'json-count': 52, 'json-slots': 53, 'json-type': 54,
    'extent-source': 55, 'extent-range': 56, 'vab-device': 57, 'lp-flags': 58,
    'vab-cow-group': 59, 'overlay': 60, 'vab-updated': 61, 'lp-attr': 62,
    'vab-policy': 63,
}
STATUS_NAME = {v: k for k, v in STATUS.items()}

# Section 1: expected super size per device (F35).
DEFAULT_SUPER_SIZE = {'eureka': 0x200000000, 'hollywood': 0x180000000}
SLOT_INDEX = {'_a': 0, '_b': 1}                     # M-3

READ_BUDGET = 1048576                               # M-5 last bullet
LP_SECTOR = 512
LP_GEOMETRY_OFFSET = 4096                           # M-6
LP_GEOMETRY_MAGIC = 0x616C4467
LP_METADATA_OFFSET = 12288                          # M-7
LP_HEADER_MAGIC = 0x414C5030
LP_ATTR_UPDATED = 0x4                               # M-12
LP_ATTR_DISABLED = 0x8

EXT4_BLOCK = 4096
EXT4_MAGIC = 0xEF53
EXT4_COMPAT = 0x28                                  # M-13 (F34)
EXT4_INCOMPAT = 0x42
EXT4_RO_COMPAT = 0x407B
EXT4_EXTENTS_FL = 0x80000                           # M-16
EXT4_INLINE_DATA_FL = 0x10000000
EXT4_EXT_MAGIC = 0xF30A                             # M-17
S_IFMT, S_IFDIR, S_IFREG = 0xF000, 0x4000, 0x8000   # M-18 / M-19
DIR_BLOCK_CAP = 16                                  # M-18

JSON_NAME = b'thermal_info_config.json'             # M-19
VR_NAME = b'vr_runtime_power_mitigation.json'
JSON_CAP, VR_CAP, PROP_CAP = 65536, 4096, 65536

INT32_MAX = 2 ** 31 - 1
INT32_MIN = -2 ** 31
UNSET = INT32_MIN                                   # section 6
ENTRY_SIZE = 96
HEADER_FMT = '<4sHHIIHHIIIIII20s'                   # 64 bytes, section 6
ENTRY_FMT = '<32s7i7iii'                            # 96 bytes, section 6
assert struct.calcsize(HEADER_FMT) == 64 and struct.calcsize(ENTRY_FMT) == 96


class Fail(Exception):
    """'Fail x': stop and emit a header-only record with status x."""

    def __init__(self, name):
        assert name in STATUS, name
        super().__init__(name)
        self.name = name


def u16(b, o):
    return struct.unpack_from('<H', b, o)[0]


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def u64(b, o):
    return struct.unpack_from('<Q', b, o)[0]


# ------------------------------------------------------------- super access

class Super:
    """The `super` device: every pread counts against the budget (M-5)."""

    def __init__(self, f, size):
        self.f = f
        self.size = size
        self.used = 0

    def pread(self, off, n):
        if self.used + n > READ_BUDGET:
            raise Fail('read-budget')
        self.used += n
        if off < 0 or off + n > self.size:
            raise Fail('io')                        # a short read
        self.f.seek(off)
        data = self.f.read(n)
        if len(data) != n:
            raise Fail('io')
        return data


class Vendor:
    """The vendor partition, mapped onto super by the M-12 extents."""

    def __init__(self, sup, extents):
        self.sup = sup
        self.map = []                               # (logical, length, physical)
        pos = 0
        for phys, length in extents:
            self.map.append((pos, length, phys))
            pos += length
        self.length = pos

    def read(self, off, n, oob):
        """Read n bytes at partition offset off; outside the partition: oob."""
        if off < 0 or off + n > self.length:
            raise Fail(oob)                         # M-20
        out = bytearray()
        for lpos, length, phys in self.map:
            if n == 0:
                break
            if off >= lpos + length or off + n <= lpos:
                continue
            start = off - lpos
            take = min(length - start, n)
            out += self.sup.pread(phys + start, take)
            off += take
            n -= take
        return bytes(out)


# ---------------------------------------------------------------- LP (M-6..12)

def read_lp(sup, slot, suffix):
    # M-6 geometry (the backup at 8192 is never read).
    g = sup.pread(LP_GEOMETRY_OFFSET, 4096)
    if u32(g, 0) != LP_GEOMETRY_MAGIC or u32(g, 4) != 52:
        raise Fail('lp-geometry')
    zeroed = g[0:8] + b'\0' * 32 + g[40:52]
    if hashlib.sha256(zeroed).digest() != g[8:40]:
        raise Fail('lp-geometry')
    mms, slot_count, lbs = u32(g, 40), u32(g, 44), u32(g, 48)
    if mms == 0 or mms % 512 or mms > 65536:
        raise Fail('lp-geometry')
    if not 1 <= slot_count <= 3 or slot >= slot_count:
        raise Fail('lp-geometry')
    if lbs == 0 or lbs % 512:
        raise Fail('lp-geometry')

    # M-7 header of the slot's primary metadata.
    moff = LP_METADATA_OFFSET + slot * mms
    if moff + mms > sup.size:
        raise Fail('lp-geometry')
    m = sup.pread(moff, mms)
    if u32(m, 0) != LP_HEADER_MAGIC:
        raise Fail('lp-header')
    major, minor, hsize = u16(m, 4), u16(m, 6), u32(m, 8)
    if major != 10 or minor > 2:
        raise Fail('lp-header')
    if hsize != (256 if minor == 2 else 128):
        raise Fail('lp-header')
    # Check order (AMBIGUITY M-7): magic, major, minor, header_size,
    # header_checksum, tables_size, tables_checksum (the order of the text).
    hz = m[0:12] + b'\0' * 32 + m[44:hsize]
    if hashlib.sha256(hz).digest() != m[12:44]:
        raise Fail('lp-checksum')
    tsize = u32(m, 44)
    if tsize > mms - hsize:
        raise Fail('lp-header')     # AMBIGUITY M-7: tables_size is a "size"
    tables = m[hsize:hsize + tsize]
    if hashlib.sha256(tables).digest() != m[48:80]:
        raise Fail('lp-checksum')
    hdr_flags = u32(m, 128) if minor == 2 else 0

    # M-8 tables: partitions, extents, groups, block devices.
    descs = []
    for at, min_es in ((80, 52), (92, 24), (104, 48), (116, 64)):
        off, num, es = struct.unpack_from('<III', m, at)
        if es < min_es:
            raise Fail('lp-tables')
        total = num * es                    # exact; u32 overflow is a failure
        if total > 0xFFFFFFFF or off + total > tsize:
            raise Fail('lp-tables')
        descs.append([tables[off + i * es: off + (i + 1) * es]
                      for i in range(num)])
    parts, exts, groups, bdevs = descs

    # M-9 block devices.
    if len(bdevs) != 1 or u64(bdevs[0], 16) != sup.size:
        raise Fail('lp-blockdev')
    # M-10 names.
    for p in parts:
        if b'\0' not in p[0:36]:
            raise Fail('lp-name')
    names = [p[0:36].split(b'\0', 1)[0] for p in parts]
    # M-11 (rev 2): a deny-list of the signals visible in super (FS-R-012
    # §8), plus the M-21a Virtual A/B policy; any signal falls back.
    if hdr_flags & 0x1:
        raise Fail('vab-device')            # LP_HEADER_FLAG_VIRTUAL_AB_DEVICE
    if hdr_flags:
        raise Fail('lp-flags')
    for n in names:
        if n.endswith(b'-cow'):
            raise Fail('vab-merge')
    for g in groups:
        if g[0:4] == b'cow\x00':            # the group name is exactly "cow"
            raise Fail('vab-cow-group')
    if b'scratch' in names:
        raise Fail('overlay')
    # M-12 vendor partition.
    want = b'vendor' + suffix.encode('ascii')
    hits = [p for p, n in zip(parts, names) if n == want]
    if not hits:
        raise Fail('no-vendor')
    if len(hits) > 1:
        raise Fail('vendor-dup')
    vp = hits[0]
    attrs = u32(vp, 36)
    if attrs & LP_ATTR_DISABLED:
        raise Fail('vendor-disabled')
    if attrs & LP_ATTR_UPDATED:
        raise Fail('vab-updated')           # M-12 rev 2
    if attrs & ~0x3:
        raise Fail('lp-attr')               # only READONLY, SLOT_SUFFIXED
    first, num = u32(vp, 40), u32(vp, 44)
    if num < 1 or first + num > len(exts):
        raise Fail('lp-tables')
    extents = []
    for e in exts[first:first + num]:
        nsec, ttype, tdata, tsrc = (u64(e, 0), u32(e, 8), u64(e, 12),
                                    u32(e, 20))
        if nsec == 0:
            # AMBIGUITY M-12: "num_sectors > 0" names no status; extent-range.
            raise Fail('extent-range')
        if ttype != 0:
            raise Fail('extent-type')
        if tsrc != 0:
            raise Fail('extent-source')
        end = (tdata + nsec) * LP_SECTOR
        if end > 0xFFFFFFFFFFFFFFFF or end > sup.size:
            raise Fail('extent-range')
        extents.append((tdata * LP_SECTOR, nsec * LP_SECTOR))
    return extents, hdr_flags, attrs


# ------------------------------------------------------------ ext4 (M-13..20)

class Ext4:
    def __init__(self, vendor):
        self.v = vendor
        self.dir_blocks = 0
        # M-13 superblock. AMBIGUITY M-13/M-20: a partition too short to
        # hold the superblock fails ext4-size.
        sb = vendor.read(1024, 1024, 'ext4-size')
        if u16(sb, 0x38) != EXT4_MAGIC:
            raise Fail('fs-type')
        if u32(sb, 0x18) != 2:
            raise Fail('ext4-blocksize')
        if (u32(sb, 0x5C) != EXT4_COMPAT or u32(sb, 0x60) != EXT4_INCOMPAT
                or u32(sb, 0x64) != EXT4_RO_COMPAT):
            raise Fail('ext4-features')
        if u16(sb, 0x58) != 256:
            raise Fail('ext4-inode-size')
        # M-14 geometry.
        self.inodes = u32(sb, 0x0)
        self.blocks = u32(sb, 0x4)
        first_data, bpg, ipg = u32(sb, 0x14), u32(sb, 0x20), u32(sb, 0x28)
        if first_data != 0 or bpg == 0 or ipg == 0:
            raise Fail('ext4-geometry')
        groups = -(-self.blocks // bpg)
        if self.inodes != groups * ipg:
            raise Fail('ext4-geometry')
        if self.blocks * EXT4_BLOCK > vendor.length:
            raise Fail('ext4-size')
        self.ipg = ipg
        self.fs_bytes = self.blocks * EXT4_BLOCK

    def read_fs(self, off, n):
        """Read inside the filesystem (blocks < blocks_count); M-20."""
        if off + n > self.fs_bytes:
            raise Fail('ext4-range')
        return self.v.read(off, n, 'ext4-range')

    def read_block(self, b):
        if b >= self.blocks:
            raise Fail('ext4-range')
        return self.read_fs(b * EXT4_BLOCK, EXT4_BLOCK)

    def inode(self, n):
        """M-15 locate and read inode n, then the M-16 checks."""
        if not 1 <= n <= self.inodes:
            raise Fail('ext4-inode')
        group = (n - 1) // self.ipg
        # AMBIGUITY M-15/M-20: the descriptor and the inode must lie inside
        # the filesystem (blocks_count), else ext4-range.
        gd = self.read_fs(EXT4_BLOCK + 32 * group, 32)
        table = u32(gd, 8)
        if table >= self.blocks:
            raise Fail('ext4-range')
        ino = self.read_fs(table * EXT4_BLOCK + ((n - 1) % self.ipg) * 256,
                           256)
        # M-16. AMBIGUITY: applied to every inode at load, before the type
        # checks of M-18/M-19.
        flags = u32(ino, 0x20)
        if not flags & EXT4_EXTENTS_FL or flags & EXT4_INLINE_DATA_FL:
            raise Fail('ext4-inode-flags')
        if u32(ino, 0x6C) != 0 or u32(ino, 0x4) > 65536:
            raise Fail('ext4-isize')
        return ino

    def map_blocks(self, ino):
        """M-17: walk the whole extent tree; return physical blocks for
        logical blocks 0 .. ceil(size/4096)-1."""
        size = u32(ino, 0x4)
        need = -(-size // EXT4_BLOCK)
        state = {'next': 0, 'runs': []}
        self._walk(ino[0x28:0x28 + 60], True, None, state)
        if state['next'] < need:
            raise Fail('ext4-hole')                 # short cover
        out = []
        for lblk, length, start in state['runs']:
            for i in range(length):
                if len(out) == need:
                    return out
                out.append(start + i)
        return out

    def _walk(self, node, in_inode, want_depth, state):
        if u16(node, 0) != EXT4_EXT_MAGIC:
            raise Fail('ext4-extent-magic')
        entries, emax, depth = u16(node, 2), u16(node, 4), u16(node, 6)
        if entries > emax or emax > (4 if in_inode else 340):
            raise Fail('ext4-extent-count')
        if in_inode:
            if depth > 2:
                raise Fail('ext4-extent-depth')
        elif depth != want_depth:
            raise Fail('ext4-extent-depth')
        for i in range(entries):
            e = node[12 + 12 * i: 24 + 12 * i]
            if depth > 0:
                child = u32(e, 4) | (u16(e, 8) << 32)
                if child >= self.blocks:
                    raise Fail('ext4-range')
                self._walk(self.read_block(child), False, depth - 1, state)
            else:
                lblk, length = u32(e, 0), u16(e, 4)
                start = (u16(e, 6) << 32) | u32(e, 8)
                if length == 0 or length > 32768:
                    raise Fail('ext4-uninit')
                if start + length > self.blocks:
                    raise Fail('ext4-range')
                # AMBIGUITY M-17: contiguity is required of every leaf entry
                # in tree order, also those past the needed cover.
                if lblk != state['next']:
                    raise Fail('ext4-hole')
                state['runs'].append((lblk, length, start))
                state['next'] += length

    def scan_dir(self, ino, wanted):
        """M-18: type, size, then a full linear scan of every block.
        Returns {name: inode} for the first entry of each wanted name."""
        if u16(ino, 0) & S_IFMT != S_IFDIR:
            raise Fail('ext4-notdir')
        size = u32(ino, 0x4)
        if size % EXT4_BLOCK:
            # M-18 (rev 1a): a size not a multiple of 4096 is ext4-dirent.
            raise Fail('ext4-dirent')
        blocks = self.map_blocks(ino)
        found = {}
        for b in blocks:
            # AMBIGUITY M-18: each directory is scanned once, in full; the
            # cap counts the blocks of / plus /etc.
            if self.dir_blocks >= DIR_BLOCK_CAP:
                raise Fail('ext4-dir-cap')
            self.dir_blocks += 1
            blk = self.read_block(b)
            pos = 0
            while pos < EXT4_BLOCK:
                rest = EXT4_BLOCK - pos
                if rest < 12:
                    raise Fail('ext4-dirent')
                d_ino, rec_len, name_len = (u32(blk, pos), u16(blk, pos + 4),
                                            blk[pos + 6])
                if rec_len < 12 or rec_len % 4 or rec_len > rest:
                    raise Fail('ext4-dirent')
                if name_len + 8 > rec_len:
                    raise Fail('ext4-dirent')
                if d_ino != 0:
                    name = blk[pos + 8: pos + 8 + name_len]
                    if name in wanted and name not in found:
                        found[name] = d_ino
                pos += rec_len
        return found

    def read_file(self, n, cap):
        """M-19 for one file: type, cap, content."""
        ino = self.inode(n)
        if u16(ino, 0) & S_IFMT != S_IFREG:
            raise Fail('file-type')
        size = u32(ino, 0x4)
        if size > cap:
            raise Fail('file-size')
        data = b''.join(self.read_block(b) for b in self.map_blocks(ino))
        return data[:size]


def read_files(vendor):
    fs = Ext4(vendor)
    root = fs.scan_dir(fs.inode(2), {b'build.prop', b'etc'})
    if b'etc' not in root:
        raise Fail('file-missing')
    etc = fs.scan_dir(fs.inode(root[b'etc']), {JSON_NAME, VR_NAME})
    # File order (AMBIGUITY M-19): the order of the M-19 list.
    out = []
    for where, name, cap in ((etc, JSON_NAME, JSON_CAP),
                             (etc, VR_NAME, VR_CAP),
                             (root, b'build.prop', PROP_CAP)):
        if name not in where:
            raise Fail('file-missing')
        out.append(fs.read_file(where[name], cap))
    return out


# ------------------------------------------------------------ build.prop M-21

PROP_VALUE = re.compile(rb'[A-Za-z0-9._-]{1,92}')
PROP_KEYS = (b'ro.product.vendor.device', b'ro.vendor.build.version.incremental')


def parse_buildprop(data):
    seen = {k: [] for k in PROP_KEYS}
    vab = False
    for line in data.split(b'\n'):
        if line.endswith(b'\r'):
            line = line[:-1]
        if not line or line.startswith(b'#'):
            continue
        if b'=' not in line:
            # M-21 (rev 1a): a line without '=' (e.g. `import`) is ignored.
            continue
        key, value = line.split(b'=', 1)
        # M-21a (rev 3, PM 2026-10-15): any "ro.virtual_ab.*" key whose value
        # is not "false"; key and value trimmed of C isspace() on both sides,
        # as Android's property loader (init/property_service.cpp)
        ws = b' \t\n\v\f\r'
        if (key.strip(ws).startswith(b'ro.virtual_ab.')
                and value.strip(ws) != b'false'):
            vab = True
        if key in seen:
            seen[key].append(value)
    vals = []
    for k in PROP_KEYS:
        if len(seen[k]) != 1 or not PROP_VALUE.fullmatch(seen[k][0]):
            raise Fail('buildprop')
        vals.append(seen[k][0])
    if vab:
        raise Fail('vab-policy')
    return vals


# ------------------------------------------------------------------ JSON M-22

JSON_NUMBER_RE = re.compile(
    rb'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')   # RFC 8259
JSON_WS = b' \t\r\n'
MAX_DEPTH = 4


class _Json:
    """Strict RFC 8259 subset (M-22). Values:
    ('obj', [(key, value), ...]), ('arr', [...]), ('str', bytes),
    ('num', token bytes), ('true',), ('false',), ('null',)."""

    def __init__(self, b):
        self.b = b
        self.i = 0

    def ws(self):
        while self.i < len(self.b) and self.b[self.i] in JSON_WS:
            self.i += 1

    def peek(self):
        if self.i >= len(self.b):
            raise Fail('json-syntax')
        return self.b[self.i]

    def value(self, depth):
        self.ws()
        c = self.peek()
        if c == 0x7B:
            return self.container(depth, 0x7D, True)
        if c == 0x5B:
            return self.container(depth, 0x5D, False)
        if c == 0x22:
            return ('str', self.string())
        if c == 0x2D or 0x30 <= c <= 0x39:
            m = JSON_NUMBER_RE.match(self.b, self.i)
            if not m:
                raise Fail('json-syntax')
            self.i = m.end()
            return ('num', m.group(0))
        for lit in (b'true', b'false', b'null'):
            if self.b.startswith(lit, self.i):
                self.i += len(lit)
                return (lit.decode(),)
        raise Fail('json-syntax')

    def string(self):
        j = self.i + 1
        while True:
            if j >= len(self.b):
                raise Fail('json-syntax')
            c = self.b[j]
            if c == 0x22:
                break
            if c == 0x5C or c < 0x20 or c > 0x7E:   # no escapes, ASCII only
                raise Fail('json-syntax')
            j += 1
        s = self.b[self.i + 1:j]
        self.i = j + 1
        return s

    def container(self, depth, close, is_obj):
        if depth > MAX_DEPTH:
            raise Fail('json-depth')
        self.i += 1
        items = []
        self.ws()
        if self.peek() == close:
            self.i += 1
            return ('obj' if is_obj else 'arr', items)
        while True:
            if is_obj:
                self.ws()
                if self.peek() != 0x22:
                    raise Fail('json-syntax')
                key = self.string()
                self.ws()
                if self.peek() != 0x3A:
                    raise Fail('json-syntax')
                self.i += 1
                items.append((key, self.value(depth + 1)))
            else:
                items.append(self.value(depth + 1))
            self.ws()
            c = self.peek()
            self.i += 1
            if c == 0x2C:
                continue
            if c == close:
                return ('obj' if is_obj else 'arr', items)
            raise Fail('json-syntax')


def parse_json_syntax(data):
    """M-22: the whole document (syntax and depth, first error wins)."""
    if data.startswith(b'\xef\xbb\xbf'):
        raise Fail('json-syntax')
    p = _Json(data)
    v = p.value(1)
    p.ws()
    if p.i != len(data):
        raise Fail('json-syntax')
    return v


def check_dupkeys(v):
    """M-23 first sentence, over the whole document (AMBIGUITY: before any
    schema check)."""
    if v[0] == 'obj':
        keys = set()
        for k, x in v[1]:
            if k in keys:
                raise Fail('json-dupkey')
            keys.add(k)
        for _, x in v[1]:
            check_dupkeys(x)
    elif v[0] == 'arr':
        for x in v[1]:
            check_dupkeys(x)


# ------------------------------------------------------- JSON schema M-23..25

SLOT_RE = re.compile(rb'(-?)(0|[1-9][0-9]{0,8})(?:\.([0-9]{1,3}))?')
MULT_RE = re.compile(rb'(-?)(0|[1-9][0-9]{0,8})(?:\.([0-9]{1,6}))?')
NAME_RE = re.compile(rb'[A-Za-z0-9._-]{1,31}')
SENSOR_KEYS = {b'Name', b'Type', b'HotThreshold', b'HotHysteresis',
               b'VrThreshold', b'Multiplier', b'Monitor'}
SENSOR_REQUIRED = (b'Name', b'Type', b'HotThreshold', b'VrThreshold',
                   b'Multiplier')
TOP_KEYS = {b'Sensors', b'CoolingDevices'}
CDEV_KEYS = {b'Name', b'Type'}


def milli(tok):
    """M-24 numeric grammar, 3 decimals, value x 1000 as int32 != INT32_MIN."""
    m = SLOT_RE.fullmatch(tok)
    if not m:
        raise Fail('json-number')
    frac = m.group(3) or b''
    v = int(m.group(2)) * 1000 + int(frac.ljust(3, b'0'))
    if m.group(1):
        v = -v
    if v > INT32_MAX or v <= INT32_MIN:
        raise Fail('json-number')
    return v


def slot_value(v):
    if v[0] == 'num':
        return milli(v[1])
    if v[0] == 'str':
        return UNSET if v[1] == b'NAN' else milli(v[1])
    raise Fail('json-number')


def slot_array(v):
    if len(v[1]) != 7:
        raise Fail('json-slots')
    return [slot_value(x) for x in v[1]]


def multiplier(v):
    """M-24 Multiplier: up to 6 decimals, > 0, num/den reduced by 10s."""
    if v[0] not in ('num', 'str'):
        raise Fail('json-number')
    m = MULT_RE.fullmatch(v[1])
    if not m:
        raise Fail('json-number')
    frac = m.group(3) or b''
    num = int(m.group(2) + frac)
    if m.group(1):
        num = -num
    den = 10 ** len(frac)
    if num <= 0:
        raise Fail('json-number')
    while num % 10 == 0 and den % 10 == 0:
        num //= 10
        den //= 10
    # AMBIGUITY M-24: the reduced numerator must fit the int32 record field.
    if num > INT32_MAX:
        raise Fail('json-number')
    return num, den


def check_schema(doc):
    """M-23..M-25. Returns the list of (name, slots, hyst, num, den)."""
    if doc[0] != 'obj':
        raise Fail('json-type')     # AMBIGUITY M-23: top value not an object
    top = dict(doc[1])
    for k in top:
        if k not in TOP_KEYS:
            raise Fail('json-unknown-key')
    if b'Sensors' not in top or top[b'Sensors'][0] != 'arr':
        raise Fail('json-type')
    if b'CoolingDevices' in top and top[b'CoolingDevices'][0] != 'arr':
        raise Fail('json-type')
    sensors = top[b'Sensors'][1]
    if not 1 <= len(sensors) <= 128:
        raise Fail('json-count')
    out = []
    for s in sensors:
        if s[0] != 'obj':
            raise Fail('json-type')
        f = dict(s[1])
        for k in f:
            if k not in SENSOR_KEYS:
                raise Fail('json-unknown-key')
        for k in SENSOR_REQUIRED:
            if k not in f:
                raise Fail('json-type')
        if f[b'Name'][0] != 'str' or f[b'Type'][0] != 'str':
            raise Fail('json-type')
        if f[b'HotThreshold'][0] != 'arr':
            raise Fail('json-type')
        if b'HotHysteresis' in f and f[b'HotHysteresis'][0] != 'arr':
            raise Fail('json-type')
        name = f[b'Name'][1]
        if not NAME_RE.fullmatch(name):
            raise Fail('json-name')
        slots = slot_array(f[b'HotThreshold'])
        hyst = (slot_array(f[b'HotHysteresis']) if b'HotHysteresis' in f
                else [UNSET] * 7)
        if f[b'VrThreshold'] != ('str', b'NAN'):
            raise Fail('json-vr')
        num, den = multiplier(f[b'Multiplier'])
        if b'Monitor' in f:
            if f[b'Monitor'] != ('true',):
                raise Fail('json-monitor')
        elif any(x != UNSET for x in slots):
            raise Fail('json-monitor')
        out.append((name, slots, hyst, num, den))
    names = [e[0] for e in out]
    if len(set(names)) != len(names):
        raise Fail('json-dupname')
    for c in top.get(b'CoolingDevices', ('arr', []))[1]:
        if c[0] != 'obj':
            raise Fail('json-type')
        f = dict(c[1])
        for k in f:
            if k not in CDEV_KEYS:
                raise Fail('json-unknown-key')
        for k in (b'Name', b'Type'):
            if k not in f or f[k][0] != 'str':
                raise Fail('json-type')
        # M-25 (rev 1a): cooling-device names are type-checked only (unused).
    return out


def parse_thermal_json(data):
    doc = parse_json_syntax(data)       # M-22
    check_dupkeys(doc)                  # M-23
    return check_schema(doc)            # M-23 .. M-25


# ----------------------------------------------------------- record (M-27)

def header(status, slot=0, json_len=0, vr_len=0, dev_len=0, incr_len=0,
           n=0, lp_flags=0, attrs=0, flags=0):
    return struct.pack(HEADER_FMT, b'FSMC', 1, STATUS[status], json_len,
                       vr_len, dev_len, incr_len, n, ENTRY_SIZE, lp_flags,
                       attrs, slot, flags, b'\0' * 20)


def fail_record(status, slot):
    # AMBIGUITY M-27: on failure lp_header_flags, attributes and flags are
    # zero; only the slot is kept "as known".
    return header(status, slot=slot)


def entries_region(sensors):
    ents = []
    for name, slots, hyst, num, den in sensors:
        ents.append(struct.pack(ENTRY_FMT, name.ljust(32, b'\0'), *slots,
                                *hyst, num, den))
    ents.sort(key=lambda e: e[:32])
    return b''.join(ents)


def _read(path, device, slot_suffix, super_size):
    slot = 0
    try:
        if device not in DEFAULT_SUPER_SIZE:
            raise Fail('arg')
        if slot_suffix not in SLOT_INDEX:
            raise Fail('slot')                                  # M-3
        slot = SLOT_INDEX[slot_suffix]
        expect = (DEFAULT_SUPER_SIZE[device] if super_size is None
                  else super_size)
        try:
            f = open(path, 'rb')
        except OSError:
            raise Fail('super-type')                            # M-4
        with f:
            size = os.fstat(f.fileno()).st_size
            if size != expect:
                raise Fail('super-size')                        # M-4
            sup = Super(f, size)
            extents, lp_flags, attrs = read_lp(sup, slot, slot_suffix)
            vendor = Vendor(sup, extents)
            jdata, vdata, pdata = read_files(vendor)            # M-13..M-20
        dev, incr = parse_buildprop(pdata)                      # M-21
        sensors = parse_thermal_json(jdata)                     # M-22..M-25
        ents = entries_region(sensors)
        flags = 0x2 if attrs & LP_ATTR_UPDATED else 0
        rec = (header('ok', slot, len(jdata), len(vdata), len(dev), len(incr),
                      len(sensors), lp_flags, attrs, flags)
               + jdata + vdata + dev + incr + ents)            # M-26: raw vr
        return rec, 'ok', len(sensors), ents, len(jdata), len(vdata), sup.used
    except Fail as e:
        return fail_record(e.name, slot), e.name, 0, None, 0, 0, None


def read_super(path, device, slot_suffix, super_size=None):
    """Return the framed record (section 6) for the image at path."""
    return _read(path, device, slot_suffix, super_size)[0]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--image', required=True)
    ap.add_argument('--device', required=True)
    ap.add_argument('--slot-suffix', required=True)
    ap.add_argument('--super-size', type=lambda s: int(s, 0), default=None)
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    rc = 0
    try:
        rec, status, n, ents, jl, vl, _used = _read(a.image, a.device,
                                                    a.slot_suffix, a.super_size)
    except Exception:               # a bug in this oracle, never an input fault
        traceback.print_exc()
        rec, status, n, ents, jl, vl = fail_record('io', 0), 'io', 0, None, 0, 0
        rc = 2
    with open(a.out, 'wb') as f:
        f.write(rec)
    digest = hashlib.sha256(ents).hexdigest() if status == 'ok' else '-'
    print('status=%s json=%d vr=%d n=%d digest=%s' % (status, jl, vl, n, digest))
    return rc


if __name__ == '__main__':
    sys.exit(main())
