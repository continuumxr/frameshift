#!/usr/bin/env python3
"""Fixture writer for fs-metacfg (METACFG-SPEC.md rev 1).

Builds synthetic Android `super` images: an LP metadata writer (geometry,
backup geometry, primary and backup metadata slots with SHA-256 checksums,
partitions, linear extents, groups, one block device) around an ext4 vendor
image made by `mke2fs -d` from a fixture tree. Written from the spec and the
public AOSP liblp / ext4 on-disk formats, independently of both readers
(src/fs-metacfg.c and tools/ref/metacfg_ref.py); it imports neither.

All fixture content is INVENTED (sensor names, values, build.prop values,
the VR list). Nothing here comes from vendor firmware.

Usage (WSL / Linux; needs mke2fs, debugfs, dumpe2fs; e2fsck if present):
  python3 -I mkfix.py --out DIR

Writes into DIR:
  <case>.img                   one sparse super image per case
  CASES.tsv                    case, image, device, slot_suffix, super_size,
                               expected_status, note
  CASES-AMBIGUOUS.tsv          same columns; cases whose status depends on a
                               reading of the spec that the text leaves open
  expected/<case>.rec          the exact expected record (section 6)

Each fault case changes one thing relative to a valid image; where the case
is not about checksums the LP checksums are recomputed after the change.
"""

import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from decimal import Decimal

KiB = 1024
MiB = 1024 * KiB
SECT = 512
BLK = 4096

# Section 6 status codes (needed for the expected records).
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
UNSET = -2 ** 31

# ============================================================ JSON emitter


class Num(str):
    """A JSON number token, emitted verbatim (strings are emitted quoted)."""


class Obj:
    """An ordered JSON object; allows repeated keys for fault cases."""

    def __init__(self, *pairs):
        self.pairs = list(pairs)

    def get(self, k, default=None):
        for kk, v in self.pairs:
            if kk == k:
                return v
        return default

    def set(self, k, v):
        for i, (kk, _) in enumerate(self.pairs):
            if kk == k:
                self.pairs[i] = (k, v)
                return
        self.pairs.append((k, v))

    def drop(self, k):
        self.pairs = [p for p in self.pairs if p[0] != k]


def jtext(v, ind=0, nl='\n', unit='  '):
    if isinstance(v, Obj):
        if not v.pairs:
            return '{}'
        inner = (',' + nl).join(
            unit * (ind + 1) + '"%s": %s' % (k, jtext(x, ind + 1, nl, unit))
            for k, x in v.pairs)
        return '{' + nl + inner + nl + unit * ind + '}'
    if isinstance(v, list):
        if all(not isinstance(x, (Obj, list)) for x in v):
            return '[' + ', '.join(jtext(x, ind, nl, unit) for x in v) + ']'
        if not v:
            return '[]'
        inner = (',' + nl).join(unit * (ind + 1) + jtext(x, ind + 1, nl, unit)
                                for x in v)
        return '[' + nl + inner + nl + unit * ind + ']'
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if v is None:
        return 'null'
    if isinstance(v, Num):
        return str(v)
    if isinstance(v, str):
        return '"' + v + '"'
    raise TypeError(v)


def S(name, typ, hot, hyst=None, mult=Num('0.001'), monitor='auto',
      vr='NAN'):
    """A sensor object in Meta's schema (key order as in the HAL config)."""
    o = Obj(('Name', name), ('Type', typ), ('HotThreshold', list(hot)))
    if hyst is not None:
        o.pairs.append(('HotHysteresis', list(hyst)))
    o.pairs.append(('VrThreshold', vr))
    o.pairs.append(('Multiplier', mult))
    if monitor == 'auto':
        monitor = True if any(x != 'NAN' for x in hot) else None
    if monitor is not None:
        o.pairs.append(('Monitor', monitor))
    return o


N = 'NAN'


class Model:
    def __init__(self, sensors, cdevs=None, extra_top=()):
        self.sensors = sensors
        self.cdevs = cdevs
        self.extra_top = list(extra_top)

    def obj(self):
        o = Obj()
        if self.sensors is not None:
            o.pairs.append(('Sensors', self.sensors))
        if self.cdevs is not None:
            o.pairs.append(('CoolingDevices', self.cdevs))
        o.pairs.extend(self.extra_top)
        return o

    def render(self, crlf=False, tabs=False):
        t = jtext(self.obj(), 0, '\r\n' if crlf else '\n',
                  '\t' if tabs else '  ')
        return (t + ('\r\n' if crlf else '\n')).encode('ascii')

    def copy(self):
        return Model([Obj(*s.pairs) for s in self.sensors],
                     None if self.cdevs is None else
                     [Obj(*c.pairs) for c in self.cdevs], self.extra_top)


def base_model(device):
    """Invented sensors; enough of them that the JSON spans two blocks."""
    p, d = ('fx', 0) if device == 'eureka' else ('hw', -2)
    ncpu = 8 if device == 'eureka' else 6
    ss = []
    for i in range(ncpu):
        ss.append(S('%s-cpu%d' % (p, i), 'CPU',
                    [N, N, N, Num('%d.5' % (86 + i + d)), N, N,
                     Num('%d' % (104 + i + d))],
                    hyst=[Num('0'), Num('0'), Num('0'), Num('3.5'), Num('0'),
                          Num('0'), Num('2')]))
    ss.append(S('%s_gpu0' % p, 'GPU',
                [N, Num('%d' % (72 + d)), Num('77.5'), Num('83'), N, N,
                 Num('108')],
                hyst=['0', '2', '2', '2', '0', '0', '1.5']))
    ss.append(S('%s_skin_front' % p, 'SKIN',
                [N, '39.5', '41', '43', N, N, '%d' % (52 + d)]))
    ss.append(S('%s.batt0' % p, 'BATTERY',
                [N, N, N, Num('46'), N, N, Num('57.5')],
                hyst=['0', '0', '0', '1', '0', '0', '0']))
    ss.append(S('%s_usb_conn' % p, 'USB_PORT',
                [N, N, N, Num('61'), N, N, Num('91.25')]))
    ss.append(S('%s_vbat_bcl' % p, 'BCL_VOLTAGE',
                [N, Num('3150'), Num('3050'), N, N, N, N], mult=Num('1')))
    for i in range(6):
        ss.append(S('%s_aux%d' % (p, i), 'UNKNOWN', [N] * 7, monitor=None,
                    mult='0.001'))
    for i in range(3):
        ss.append(S('%s_pa%d' % (p, i), 'POWER_AMPLIFIER', [N] * 7,
                    monitor=True))
    cd = [Obj(('Name', '%s-cdev-cpu0' % p), ('Type', 'CPU')),
          Obj(('Name', '%s_cdev_gpu' % p), ('Type', 'GPU')),
          Obj(('Name', '%s.cdev.batt' % p), ('Type', 'BATTERY'))]
    return Model(ss, cd)


def mixed_model():
    """ok-mixed-values: numbers, numeric strings and NAN mixed; edge values."""
    ss = [
        S('mx_a', 'CPU', [Num('-0'), N, '35', '40.1', N, N,
                          Num('2147483.647')], mult=Num('0.1')),
        S('mx_b', 'GPU', ['-2147483.647', Num('0'), N, N, N, N, '0.001'],
          hyst=[N, '0.5', Num('1'), N, Num('-0.25'), '0', N], mult=Num('1')),
        S('mx_c', 'SKIN', [N] * 7, mult='1.0', monitor=True),
        S('mx_d', 'BATTERY', [N, N, N, Num('45.000'), N, N, '50.12'],
          mult='1.50'),
        S('mx_a.b', 'UNKNOWN', [N] * 7, mult=Num('0.000001'), monitor=None),
        S('Zeta-upper', 'UNKNOWN', [N] * 7, mult='10', monitor=None),
        S('abcdefghijklmnopqrstuvwxyz01234', 'UNKNOWN', [Num('1')] + [N] * 6,
          mult=Num('100.000100')),
        S('0', 'UNKNOWN', [N] * 7, mult=Num('999999999'), monitor=None),
    ]
    return Model(ss, None)          # no CoolingDevices key at all


def exp_milli(x):
    if not isinstance(x, Num) and x == 'NAN':
        return UNSET
    v = Decimal(str(x)) * 1000
    assert v == v.to_integral_value(), x
    return int(v)


def exp_mult(x):
    s = str(x)
    ip, _, fr = s.partition('.')
    fr = fr.rstrip('0')                 # = "divide by 10 while both divisible"
    return int(ip + fr), 10 ** len(fr)


def exp_entries(model):
    ents = []
    for s in model.sensors:
        hot = [exp_milli(x) for x in s.get('HotThreshold')]
        hy = s.get('HotHysteresis')
        hy = [exp_milli(x) for x in hy] if hy is not None else [UNSET] * 7
        num, den = exp_mult(s.get('Multiplier'))
        ents.append(struct.pack('<32s7i7iii',
                                s.get('Name').encode('ascii'), *hot, *hy,
                                num, den))
    ents.sort(key=lambda e: e[:32])
    return b''.join(ents)

# ======================================================== build.prop, trees


INCR = {'eureka': '58132907400017', 'hollywood': '40981173300052'}
VR_DEFAULT = (b'{"FixtureNote": "invented VR runtime mitigation list, '
              b'not vendor content", "Entries": []}\n')


def build_prop(dev, incr, extra_after=b''):
    return (b'# fixture build.prop for fs-metacfg tests (invented values)\n'
            b'ro.vendor.build.date=Thu Jan  1 00:00:00 UTC 2026\n'
            b'ro.vendor.build.date.utc=1767225600\n'
            b'\n'
            b'ro.product.vendor.brand=fixture\n'
            b'ro.product.vendor.device=' + dev + b'\r\n'
            b'ro.product.vendor.model=Fixture Unit (invented)\n'
            b'ro.vendor.build.version.incremental=' + incr + b'\n'
            + extra_after +
            b'#ro.product.vendor.device=commented-out\n'
            b'ro.vendor.build.tags=release-keys')     # no final newline


class Tree:
    def __init__(self, files, model=None, json=None, vr=None, dev=None,
                 incr=None, ninodes=64, nblocks=256):
        self.files = files
        self.model = model
        self.json, self.vr, self.dev, self.incr = json, vr, dev, incr
        self.ninodes, self.nblocks = ninodes, nblocks

    def key(self):
        h = hashlib.sha256(repr((self.ninodes, self.nblocks)).encode())
        for k in sorted(self.files):
            h.update(k.encode() + b'\0' + repr(self.files[k]).encode() + b'\0')
        return h.hexdigest()


def mk_tree(device='eureka', model=None, json=None, prop=None, vr=None,
            extra=None, drop=(), dev=None, incr=None, **kw):
    model = model if model is not None else base_model(device)
    dev = (dev or device).encode()
    incr = (incr or INCR[device]).encode()
    jb = json if json is not None else model.render()
    pb = prop if prop is not None else build_prop(dev, incr)
    vb = vr if vr is not None else VR_DEFAULT
    files = {
        '/build.prop': pb,
        '/etc/thermal_info_config.json': jb,
        '/etc/vr_runtime_power_mitigation.json': vb,
        # decoys: exact-name matching and directory scoping
        '/etc/thermal_info_config.json.bak': b'{"decoy": true}\n',
        '/etc/vr_runtime_power_mitigation': b'decoy\n',
        '/etc/fixture.conf': b'# invented\n',
        '/odm/etc/thermal_info_config.json': b'{"decoy": "odm"}\n',
        '/lib/firmware/fixture.bin': bytes(range(256)) * 3,
    }
    files.update(extra or {})
    for d in drop:
        del files[d]
    return Tree(files, model, jb, vb, dev, incr, **kw)

# ===================================================================== ext4


def tool(name):
    for d in os.environ.get('PATH', '').split(os.pathsep) + ['/sbin',
                                                             '/usr/sbin']:
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


MKE2FS_CONF = """[defaults]
\tbase_features = sparse_super
\tdefault_features = sparse_super
\tblocksize = 4096
\tinode_size = 256
\tinode_ratio = 16384
\treserved_ratio = 0
[fs_types]
\text4 = {
\t\tfeatures = sparse_super
\t}
\tsmall = {
\t\tinode_size = 256
\t}
\tfloppy = {
\t\tinode_size = 256
\t}
"""
# F34 feature set minus shared_blocks (not settable by mke2fs; patched in).
MKE2FS_FEATURES = ('none,ext_attr,dir_index,filetype,extent,sparse_super,'
                   'large_file,huge_file,uninit_bg,dir_nlink,extra_isize')
WANT_FEATURES = set(MKE2FS_FEATURES.split(',')[1:]) | {'shared_blocks'}
FIXED_TIME = 1767225600


class FsBuilder:
    def __init__(self, work):
        self.work = work
        self.cache = {}
        self.mke2fs, self.debugfs = tool('mke2fs'), tool('debugfs')
        self.dumpe2fs, self.e2fsck = tool('dumpe2fs'), tool('e2fsck')
        if not (self.mke2fs and self.debugfs and self.dumpe2fs):
            sys.exit('mkfix: mke2fs, debugfs and dumpe2fs are required')
        self.conf = os.path.join(work, 'mke2fs.conf')
        with open(self.conf, 'w') as f:
            f.write(MKE2FS_CONF)
        self.env = dict(os.environ, MKE2FS_CONFIG=self.conf,
                        E2FSPROGS_FAKE_TIME=str(FIXED_TIME))
        self.n = 0

    def run(self, argv):
        r = subprocess.run(argv, env=self.env, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            raise RuntimeError('%s failed: %s' % (argv[0], r.stderr))
        return r.stdout

    def build(self, tree):
        """-> (bytearray vendor image, info dict). Cached per tree."""
        k = tree.key()
        if k in self.cache:
            img, info = self.cache[k]
            return bytearray(img), info
        self.n += 1
        root = os.path.join(self.work, 'tree%d' % self.n)
        os.mkdir(root)
        dirs = set()
        for path, val in sorted(tree.files.items()):
            full = root + path
            os.makedirs(os.path.dirname(full), exist_ok=True)
            dirs.add(os.path.dirname(full))
            if isinstance(val, bytes):
                with open(full, 'wb') as f:
                    f.write(val)
                os.utime(full, (FIXED_TIME, FIXED_TIME))
            elif val[0] == 'symlink':
                os.symlink(val[1], full)
            elif val[0] == 'dir':
                os.makedirs(full, exist_ok=True)
                dirs.add(full)
        for d in dirs | {root}:
            os.utime(d, (FIXED_TIME, FIXED_TIME))
        img = os.path.join(self.work, 'fs%d.img' % self.n)
        self.run([self.mke2fs, '-F', '-q', '-t', 'ext4', '-b', '4096',
                  '-I', '256', '-N', str(tree.ninodes), '-m', '0',
                  '-U', '6b1c2d3e-4f50-4a61-8b72-9c8d0e1f2a3b',
                  '-E', 'root_owner=0:0,hash_seed='
                  '0b1c2d3e-4f50-4a61-8b72-9c8d0e1f2a3b',
                  '-O', MKE2FS_FEATURES, '-d', root, img, str(tree.nblocks)])
        with open(img, 'rb') as f:
            data = bytearray(f.read())
        normalize_times(data)
        with open(img, 'wb') as f:
            f.write(data)
        if self.e2fsck:
            self.run([self.e2fsck, '-fn', img])         # sanity: clean fs
        info = self.info(img, tree)
        # Patch the feature words to exactly F34 (adds shared_blocks).
        c, i, r = struct.unpack_from('<III', data, 1024 + 0x5C)
        assert (c, i, r) == (0x28, 0x42, 0x407B & ~0x4000), (c, i, r)
        struct.pack_into('<I', data, 1024 + 0x64, r | 0x4000)
        with open(img, 'wb') as f:
            f.write(data)
        out = self.run([self.dumpe2fs, '-h', img])
        m = re.search(r'^Filesystem features:\s*(.*)$', out, re.M)
        assert m and set(m.group(1).split()) == WANT_FEATURES, out
        assert re.search(r'^Inode size:\s*256$', out, re.M)
        assert re.search(r'^Block size:\s*4096$', out, re.M)
        assert re.search(r'^First block:\s*0$', out, re.M)
        assert len(data) == tree.nblocks * BLK
        os.unlink(img)
        shutil.rmtree(root)
        self.cache[k] = (bytes(data), info)
        return bytearray(data), info

    def dbg(self, img, cmd):
        return self.run([self.debugfs, '-R', cmd, img])

    def info(self, img, tree):
        """Locations via debugfs (independent of any reader code)."""
        ino = {}
        for p in ['/', '/etc', '/etc/thermal_info_config.json',
                  '/etc/vr_runtime_power_mitigation.json', '/build.prop']:
            out = self.dbg(img, 'imap "%s"' % p)
            m = re.search(r'located at block (\d+), offset 0x([0-9a-fA-F]+)',
                          out)
            ino[p] = int(m.group(1)) * BLK + int(m.group(2), 16) if m else None
        num = {}
        for p in ['/etc/thermal_info_config.json', '/build.prop']:
            m = re.search(r'Inode: (\d+)', self.dbg(img, 'stat "%s"' % p))
            num[p] = int(m.group(1)) if m else None
        etc_blocks = [int(x) for x in self.dbg(img, 'blocks /etc').split()]
        free = [int(x) for x in re.search(
            r'Free blocks found: ([\d ]+)',
            self.dbg(img, 'ffb 8')).group(1).split()]
        return {'ino': ino, 'num': num, 'etc_blocks': etc_blocks,
                'free': free}

def normalize_times(fs):
    """Reproducible images: mke2fs -d copies the host's atime/ctime, which
    cannot be pinned; set every in-use inode's times to FIXED_TIME. (No
    metadata_csum, so nothing else needs recomputing.)"""
    inodes, blocks = struct.unpack_from('<II', fs, 1024)
    bpg, ipg = struct.unpack_from('<I', fs, 1024 + 0x20)[0], \
        struct.unpack_from('<I', fs, 1024 + 0x28)[0]
    isz = struct.unpack_from('<H', fs, 1024 + 0x58)[0]
    for g in range(-(-blocks // bpg)):
        table = struct.unpack_from('<I', fs, BLK + 32 * g + 8)[0]
        for i in range(ipg):
            o = table * BLK + i * isz
            if struct.unpack_from('<H', fs, o)[0] == 0:     # i_mode: unused
                continue
            struct.pack_into('<III', fs, o + 0x08, FIXED_TIME, FIXED_TIME,
                             FIXED_TIME)                    # a/c/mtime
            # ctime/mtime/atime_extra, crtime, crtime_extra (i_extra_isize 32)
            if struct.unpack_from('<H', fs, o + 0x80)[0] >= 24:
                struct.pack_into('<IIIII', fs, o + 0x84, 0, 0, 0, FIXED_TIME, 0)

# --- ext4 patch helpers (vendor image bytearray) ---


def sb_get(fs, off, fmt):
    return struct.unpack_from(fmt, fs, 1024 + off)[0]


def sb_set(fs, off, fmt, val):
    struct.pack_into(fmt, fs, 1024 + off, val)


def blocks_count(fs):
    return sb_get(fs, 0x4, '<I')


def jino(info):
    return info['ino']['/etc/thermal_info_config.json']


def root_leaf(fs, io):
    """The (depth-0) extent root of the inode at byte offset io."""
    magic, ent, emax, depth = struct.unpack_from('<HHHH', fs, io + 0x28)
    assert magic == 0xF30A and depth == 0, (magic, depth)
    return [struct.unpack_from('<IHHI', fs, io + 0x28 + 12 + 12 * i)
            for i in range(ent)]


def leaf_bytes(entries):
    return b''.join(struct.pack('<IHHI', lb, ln, start >> 32,
                                start & 0xFFFFFFFF)
                    for lb, ln, start in entries)


def index_bytes(children):
    return b''.join(struct.pack('<IIHH', lb, blk & 0xFFFFFFFF, blk >> 32, 0)
                    for lb, blk in children)


def set_root(fs, io, depth, body, n, emax=4):
    struct.pack_into('<HHHHI', fs, io + 0x28, 0xF30A, n, emax, depth, 0)
    fs[io + 0x28 + 12: io + 0x28 + 60] = body.ljust(48, b'\0')


def put_node(fs, blk, depth, body, n, emax=340):
    node = struct.pack('<HHHHI', 0xF30A, n, emax, depth, 0) + body
    fs[blk * BLK:(blk + 1) * BLK] = node.ljust(BLK, b'\0')


def json_two_block_extent(fs, info):
    leaf = root_leaf(fs, jino(info))
    assert len(leaf) == 1 and leaf[0][0] == 0 and leaf[0][1] == 2, leaf
    return (leaf[0][2] << 32) | leaf[0][3]


def find_dirent(fs, blk, name):
    pos = 0
    base = blk * BLK
    while pos < BLK:
        ino, rec, nl = struct.unpack_from('<IHB', fs, base + pos)
        if ino and bytes(fs[base + pos + 8: base + pos + 8 + nl]) == name:
            return base + pos
        pos += rec
    raise KeyError(name)

# ======================================================================= LP


LP_GEO_MAGIC = 0x616C4467
LP_HDR_MAGIC = 0x414C5030
ATTR_READONLY, ATTR_SLOT_SUFFIXED, ATTR_UPDATED, ATTR_DISABLED = 0x1, 0x2, 0x4, 0x8


class LP:
    """A liblp-format super image (metadata_format.h, major 10)."""

    def __init__(self, super_size, mms=8192, slots=2, minor=2, flags=0):
        self.super_size = super_size
        self.mms, self.slots, self.lbs = mms, slots, 4096
        self.major, self.minor, self.flags = 10, minor, flags
        self.parts = []
        self.groups = [[b'default', 0, 0]]
        self.bdevs = [dict(first=2048, align=MiB, align_off=0,
                           size=super_size, name=b'super', flags=0)]
        self.geo_ovr, self.hdr_ovr, self.desc_ovr = {}, {}, {}
        self.bad_geo_csum = self.bad_hdr_csum = self.bad_tbl_csum = False
        self.garbage_slots = set()      # primary slots filled with junk
        self.garbage_backups = False    # backup geometry + metadata junk
        self.layout_slots = None
        self.contents = []              # (byte offset, bytes)
        self.next = 1 * MiB             # data area starts at 1 MiB

    def group(self, name, max_size=0):
        self.groups.append([name, 0, max_size])
        return len(self.groups) - 1

    def _alloc(self, n):
        off = self.next
        self.next = -(-(off + n) // (64 * KiB)) * (64 * KiB)
        assert self.next <= self.super_size, 'super too small'
        return off

    def part(self, name, data=None, attrs=ATTR_READONLY, group=0, split=None):
        p = dict(name=name, attrs=attrs, group=group, extents=[])
        if data is not None:
            assert len(data) % SECT == 0
            if split is None:
                off = self._alloc(len(data))
                p['extents'].append([len(data) // SECT, 0, off // SECT, 0])
                self.contents.append((off, bytes(data)))
            else:
                # two non-adjacent linear extents, the second one placed
                # physically *before* the first
                assert split % SECT == 0 and 0 < split < len(data)
                off2 = self._alloc(len(data) - split)
                self._alloc(64 * KiB)                      # gap
                off1 = self._alloc(split)
                p['extents'].append([split // SECT, 0, off1 // SECT, 0])
                p['extents'].append([(len(data) - split) // SECT, 0,
                                     off2 // SECT, 0])
                self.contents.append((off1, bytes(data[:split])))
                self.contents.append((off2, bytes(data[split:])))
        self.parts.append(p)
        return p

    def find(self, name):
        return [p for p in self.parts if p['name'] == name][0]

    # --- serialisation ---

    def geometry(self, valid_only=False):
        f = dict(magic=LP_GEO_MAGIC, struct_size=52, mms=self.mms,
                 slots=self.slots, lbs=self.lbs)
        if not valid_only:
            f.update(self.geo_ovr)
        g = bytearray(struct.pack('<II32sIII', f['magic'], f['struct_size'],
                                  b'\0' * 32, f['mms'], f['slots'], f['lbs']))
        g[8:40] = hashlib.sha256(bytes(g)).digest()
        if self.bad_geo_csum and not valid_only:
            g[8] ^= 0xFF
        return bytes(g).ljust(4096, b'\0')

    def metadata(self):
        hs_real = 256 if self.minor >= 2 else 128
        parts, exts = [], []
        for p in self.parts:
            first, num = len(exts), len(p['extents'])
            first = p.get('first_ovr', first)
            num = p.get('num_ovr', num)
            exts.extend(p['extents'])
            parts.append(struct.pack('<36sIIII', p['name'], p['attrs'], first,
                                     num, p['group']))
        tparts = b''.join(parts)
        texts = b''.join(struct.pack('<QIQI', *e) for e in exts)
        tgroups = b''.join(struct.pack('<36sIQ', *g) for g in self.groups)
        tbdevs = b''.join(struct.pack('<QIIQ36sI', b['first'], b['align'],
                                      b['align_off'], b['size'], b['name'],
                                      b['flags']) for b in self.bdevs)
        descs, off = {}, 0
        for name, t, n, es in (('partitions', tparts, len(parts), 52),
                               ('extents', texts, len(exts), 24),
                               ('groups', tgroups, len(self.groups), 48),
                               ('block_devices', tbdevs, len(self.bdevs), 64)):
            d = dict(offset=off, num=n, es=es)
            d.update(self.desc_ovr.get(name, {}))
            descs[name] = d
            off += len(t)
        tables = tparts + texts + tgroups + tbdevs
        h = dict(magic=LP_HDR_MAGIC, major=self.major, minor=self.minor,
                 header_size=hs_real, tables_size=len(tables))
        h.update(self.hdr_ovr)
        buf = bytearray(self.mms)
        assert hs_real + len(tables) <= self.mms, 'metadata too large'
        struct.pack_into('<IHHI', buf, 0, h['magic'], h['major'], h['minor'],
                         h['header_size'])
        struct.pack_into('<I', buf, 44, h['tables_size'])
        for i, name in enumerate(('partitions', 'extents', 'groups',
                                  'block_devices')):
            d = descs[name]
            struct.pack_into('<III', buf, 80 + 12 * i, d['offset'], d['num'],
                             d['es'])
        if hs_real == 256:
            struct.pack_into('<I', buf, 128, self.flags)
        buf[hs_real:hs_real + len(tables)] = tables
        hsz = min(h['header_size'], self.mms)
        tsz = min(h['tables_size'], self.mms - hsz)
        buf[48:80] = hashlib.sha256(bytes(buf[hsz:hsz + tsz])).digest()
        if self.bad_tbl_csum:
            buf[48] ^= 0xFF
        z = bytearray(buf[:hsz])
        z[12:44] = b'\0' * 32
        buf[12:44] = hashlib.sha256(bytes(z)).digest()
        if self.bad_hdr_csum:
            buf[12] ^= 0xFF
        return bytes(buf)

    def write(self, path):
        geo = self.geometry()
        meta = self.metadata()
        nslots = self.layout_slots or (self.slots if 1 <= self.slots <= 3
                                       else 2)
        junk = (b'\xa5\x5a' * (self.mms // 2))
        with open(path, 'wb') as f:
            f.truncate(self.super_size)
            write_sparse(f, 4096, geo)
            write_sparse(f, 8192, junk[:4096] if self.garbage_backups
                         else self.geometry(valid_only=True))
            for s in range(nslots):
                write_sparse(f, 12288 + s * self.mms,
                             junk if s in self.garbage_slots else meta)
                write_sparse(f, 12288 + (nslots + s) * self.mms,
                             junk if self.garbage_backups else meta)
            for off, data in self.contents:
                write_sparse(f, off, data)


def write_sparse(f, off, data):
    """Write only non-zero 4 KiB chunks so images stay sparse."""
    for i in range(0, len(data), 4096):
        chunk = data[i:i + 4096]
        if chunk.count(0) != len(chunk):
            f.seek(off + i)
            f.write(chunk)


def filler(tag, n):
    unit = ('[%s fixture filler]' % tag).encode()
    return (unit * (n // len(unit) + 1))[:n]

# =============================================================== the cases


def record(status, slot=0, json=b'', vr=b'', dev=b'', incr=b'', ents=b'',
           lp_flags=0, attrs=0, flags=0):
    """Section 6 framing (64-byte header, then payload)."""
    n = len(ents) // 96
    return struct.pack('<4sHHIIHHIIIIII20s', b'FSMC', 1, STATUS[status],
                       len(json), len(vr), len(dev), len(incr), n, 96,
                       lp_flags, attrs, slot, flags, b'\0' * 20) + \
        json + vr + dev + incr + ents


class Gen:
    def __init__(self, out, work):
        self.out = out
        self.fsb = FsBuilder(work)
        self.rows = []
        self.amb_rows = []
        os.makedirs(os.path.join(out, 'expected'), exist_ok=True)
        self.base = {d: mk_tree(d) for d in ('eureka', 'hollywood')}

    # --- generic case ---
    def case(self, name, expect, note, device='eureka', slot='_a',
             size=8 * MiB, tree=None, fs=None, lp=None, lp_kw=None,
             split=None, vendor_attrs=ATTR_READONLY, other='fs',
             ambiguous=False, reader_device=None, reader_slot=None,
             reader_size=None, image=None):
        """Build one super image.

        fs(fsimg, info): patch the vendor ext4 image in place.
        lp(lpobj):      patch the LP model before serialisation.
        other:          content of the inactive vendor slot: 'fs' (the other
                        device's image), 'zero' (zero-filled) or None.
        """
        if image is None:
            tree = tree or self.base[device]
            fsimg, info = self.fsb.build(tree)
            if fs:
                fs(fsimg, info)
            L = LP(size, **(lp_kw or {}))
            ga = L.group(b'fxt_dynamic_a', size // 2)
            gb = L.group(b'fxt_dynamic_b', size // 2)
            L.part(b'system_a', filler('system_a', 64 * KiB), group=ga)
            L.part(b'system_b', None, group=gb)
            odev = 'hollywood' if device == 'eureka' else 'eureka'
            if other == 'fs':
                oimg = bytes(self.fsb.build(self.base[odev])[0])
            elif other == 'zero':
                oimg = bytes(len(fsimg))
            else:
                oimg = None
            act, ina = (b'vendor_a', b'vendor_b') if slot == '_a' else \
                       (b'vendor_b', b'vendor_a')
            for pname in (b'vendor_a', b'vendor_b'):
                if pname == act:
                    L.part(act, fsimg, attrs=vendor_attrs,
                           group=ga if slot == '_a' else gb, split=split)
                else:
                    L.part(ina, oimg, group=gb if slot == '_a' else ga)
            L.part(b'product_a', filler('product_a', 64 * KiB), group=ga)
            L.part(b'product_b', None, group=gb)
            if lp:
                lp(L)
            image = name + '.img'
            L.write(os.path.join(self.out, image))
        else:
            L = None
        rdev = reader_device or device
        rslot = reader_slot or slot
        rsize = reader_size if reader_size is not None else size
        slot_idx = {'_a': 0, '_b': 1}.get(rslot, 0)
        if expect == 'ok':
            vattrs = L.find(b'vendor' + rslot.encode())['attrs']
            rec = record('ok', slot_idx, tree.json, tree.vr, tree.dev,
                         tree.incr, exp_entries(tree.model),
                         lp_flags=L.flags if L.minor == 2 else 0,
                         attrs=vattrs,
                         flags=0x2 if vattrs & ATTR_UPDATED else 0)
        else:
            known = slot_idx if expect not in ('arg', 'slot') else 0
            rec = record(expect, known)
        with open(os.path.join(self.out, 'expected', name + '.rec'), 'wb') as f:
            f.write(rec)
        row = (name, image, rdev, rslot, str(rsize), expect, note)
        (self.amb_rows if ambiguous else self.rows).append(row)

    def tcase(self, name, expect, note, device='eureka', ambiguous=False,
              **tree_kw):
        """A case that differs from the base only in the fixture tree."""
        self.case(name, expect, note, device=device, ambiguous=ambiguous,
                  tree=mk_tree(device, **tree_kw))

    def jcase(self, name, expect, note, mutate=None, text=None,
              ambiguous=False, device='eureka'):
        """A JSON content case: mutate(model) and/or text(bytes)->bytes."""
        m = base_model(device).copy()
        if mutate:
            mutate(m)
        jb = m.render()
        if text:
            jb = text(jb)
        self.tcase(name, expect, note, device=device, ambiguous=ambiguous,
                   model=m, json=jb)

    def write_tsv(self):
        hdr = ('case', 'image', 'device', 'slot_suffix', 'super_size',
               'expected_status', 'note')
        for fname, rows in (('CASES.tsv', self.rows),
                            ('CASES-AMBIGUOUS.tsv', self.amb_rows)):
            with open(os.path.join(self.out, fname), 'w') as f:
                f.write('\t'.join(hdr) + '\n')
                for r in rows:
                    assert not any('\t' in c or '\n' in c for c in r)
                    f.write('\t'.join(r) + '\n')

    # ------------------------------------------------------------- cases
    def all_cases(self):
        self.ok_cases()
        self.param_cases()
        self.lp_cases()
        self.ext4_cases()
        self.content_cases()

    def ok_cases(self):
        c = self.case

        def junk_backups(L):
            L.garbage_backups = True

        c('ok-eureka-a', 'ok', 'baseline Quest 3, slot _a; backup geometry '
          'and backup metadata are junk (never read, M-6)', lp=junk_backups)
        c('ok-eureka-b', 'ok', 'slot _b: vendor_b holds the fs, vendor_a is '
          'zero-filled, primary slot-0 metadata is junk (M-7 reads slot 1)',
          slot='_b', other='zero',
          lp=lambda L: L.garbage_slots.add(0))
        c('ok-hollywood', 'ok', 'Quest 2, 16 MiB super, header minor 1, '
          'metadata_max_size 65536, 3 metadata slots', device='hollywood',
          size=16 * MiB, lp_kw=dict(minor=1, mms=65536, slots=3))
        c('ok-minor0', 'ok', 'LP header minor 0, header_size 128 (M-7)',
          lp_kw=dict(minor=0))
        c('ok-slot-suffixed-attr', 'ok', 'vendor attributes '
          'READONLY|SLOT_SUFFIXED (the known-safe bits, M-12 rev 2)',
          vendor_attrs=ATTR_READONLY | ATTR_SLOT_SUFFIXED)
        c('ok-multi-extent', 'ok', 'vendor in 2 non-adjacent linear extents '
          '(second placed first); split inside the inode table, not '
          '4 KiB aligned (M-12 map)', split=4 * BLK + 5 * SECT)
        c('ok-slot-count-1', 'ok', 'metadata_slot_count 1, slot _a',
          lp_kw=dict(slots=1))
        c('ok-mms-max', 'ok', 'metadata_max_size 65536 (upper bound, M-6)',
          lp_kw=dict(mms=65536))

        def depth1(fsimg, info):
            io = jino(info)
            start = json_two_block_extent(fsimg, info)
            leaf = info['free'][0]
            put_node(fsimg, leaf, 0, leaf_bytes([(0, 1, start),
                                                 (1, 1, start + 1)]), 2)
            set_root(fsimg, io, 1, index_bytes([(0, leaf)]), 1)
        c('ok-extent-depth1', 'ok', 'json inode root rewritten to a depth-1 '
          'index -> leaf block in free space holding 2 one-block extents '
          '(M-17)', fs=depth1)

        def depth2(fsimg, info):
            io = jino(info)
            start = json_two_block_extent(fsimg, info)
            i1, l1, l2 = info['free'][0:3]
            put_node(fsimg, l1, 0, leaf_bytes([(0, 1, start)]), 1)
            put_node(fsimg, l2, 0, leaf_bytes([(1, 1, start + 1)]), 1)
            put_node(fsimg, i1, 1, index_bytes([(0, l1), (1, l2)]), 2)
            set_root(fsimg, io, 2, index_bytes([(0, i1)]), 1)
        c('ok-extent-depth2', 'ok', 'json extent tree depth 2: root -> index '
          'block -> 2 leaf blocks (M-17)', fs=depth2)

        m = mixed_model()
        self.case('ok-mixed-values', 'ok', 'numbers, numeric strings, NAN '
                  'mixed; -0, +/-2147483.647; multipliers 0.1, 1, "1.0", '
                  '"1.50", 0.000001, "10", 100.000100, 999999999; 31-char '
                  'name; byte-order sort; no CoolingDevices; CRLF + tab '
                  'whitespace (M-22..M-25)',
                  tree=mk_tree('eureka', model=m,
                               json=m.render(crlf=True, tabs=True)))
        m = Model([S('s%03d' % i, 'UNKNOWN', [N] * 7, monitor=None)
                   for i in range(128)][::-1])
        self.tcase('ok-128-sensors', 'ok', '128 sensors (the maximum, M-25), '
                   'written in reverse name order', model=m)
        self.tcase('ok-buildprop-92', 'ok', 'incremental value of 92 bytes '
                   '(the maximum, M-21)', incr='9' * 46 + 'a.b_c-' + '1' * 40)
        self.tcase('ok-empty-vr', 'ok', 'vr list of 0 bytes (shipped raw)',
                   vr=b'')
        self.tcase('ok-vr-4096', 'ok', 'vr list of exactly 4096 bytes',
                   vr=filler('vr', 4096))

    def param_cases(self):
        c = self.case
        img = 'ok-eureka-a.img'
        c('arg-device', 'arg', 'device name not eureka/hollywood (section 1)',
          image=img, reader_device='seacliff')
        c('slot-bad-suffix', 'slot', 'slot suffix _c (M-3)', image=img,
          reader_slot='_c')
        c('super-size-mismatch', 'super-size', 'expected size 8 MiB + 512, '
          'image 8 MiB (M-4)', image=img, reader_size=8 * MiB + 512)
        c('super-size-eureka-default', 'super-size', 'expected size = the '
          'eureka default 0x200000000, image 8 MiB (M-4)', image=img,
          reader_size=0x200000000)
        # Tiny image: the geometry read (4096..8192) is short -> io.
        L = LP(6144)
        with open(os.path.join(self.out, 'io-short-read.img'), 'wb') as f:
            f.write((bytes(4096) + L.geometry())[:6144])
        c('io-short-read', 'io', '6144-byte super: the 4096-byte geometry '
          'read is short (M-5)', image='io-short-read.img', size=6144)
        # Metadata slot range outside the device -> lp-geometry.
        L = LP(14336, mms=4096, slots=1)
        with open(os.path.join(self.out, 'lp-meta-past-end.img'), 'wb') as f:
            f.write((bytes(4096) + L.geometry() + L.geometry()
                     + bytes(14336))[:14336])
        c('lp-meta-past-end', 'lp-geometry', 'super 14336 bytes: metadata '
          'slot 12288..16384 not inside the device (M-7)',
          image='lp-meta-past-end.img', size=14336)

    def lp_cases(self):
        c = self.case

        def geo(**kw):
            return lambda L: L.geo_ovr.update(kw)

        def hdr(**kw):
            return lambda L: L.hdr_ovr.update(kw)

        def desc(table, **kw):
            return lambda L: L.desc_ovr.setdefault(table, {}).update(kw)

        def vendor(fn):
            return lambda L: fn(L.find(b'vendor_a'))

        def vext(**kw):
            def f(L):
                e = L.find(b'vendor_a')['extents'][0]
                for k, v in kw.items():
                    e[['ns', 'tt', 'td', 'ts'].index(k)] = v
            return f

        def setattr_(k, v):
            return lambda L: setattr(L, k, v)

        c('lp-geo-magic', 'lp-geometry', 'geometry magic 0 (M-6)',
          lp=geo(magic=0))
        c('lp-geo-checksum', 'lp-geometry', 'geometry checksum wrong, backup '
          'geometry valid: backup never read (M-6)',
          lp=setattr_('bad_geo_csum', True))
        c('lp-geo-struct-size', 'lp-geometry', 'struct_size 56 (M-6)',
          lp=geo(struct_size=56))
        c('lp-slot-count-4', 'lp-geometry', 'metadata_slot_count 4 (M-6)',
          lp=geo(slots=4))
        c('lp-slot-count-0', 'lp-geometry', 'metadata_slot_count 0 (M-6)',
          lp=geo(slots=0))
        c('lp-slot-ge-count', 'lp-geometry', 'slot _b with '
          'metadata_slot_count 1 (M-6)', slot='_b', lp_kw=dict(slots=1))
        c('lp-mms-not-512', 'lp-geometry', 'metadata_max_size 8000 (M-6)',
          lp=geo(mms=8000))
        c('lp-mms-zero', 'lp-geometry', 'metadata_max_size 0 (M-6)',
          lp=geo(mms=0))
        c('lp-mms-too-big', 'lp-geometry', 'metadata_max_size 66048 (M-6)',
          lp=geo(mms=65536 + 512))
        c('lp-lbs-zero', 'lp-geometry', 'logical_block_size 0 (M-6)',
          lp=geo(lbs=0))
        c('lp-lbs-not-512', 'lp-geometry', 'logical_block_size 4000 (M-6)',
          lp=geo(lbs=4000))
        c('lp-hdr-magic', 'lp-header', 'header magic wrong (M-7)',
          lp=hdr(magic=0x414C5031))
        c('lp-major-11', 'lp-header', 'major_version 11 (M-7)',
          lp=hdr(major=11))
        c('lp-minor-3', 'lp-header', 'minor_version 3 (M-7)',
          lp=hdr(minor=3))
        c('lp-hdrsize-200', 'lp-header', 'minor 2 with header_size 200 '
          '(M-7)', lp=hdr(header_size=200))
        c('lp-hdrsize-256-minor1', 'lp-header', 'minor 1 with header_size '
          '256 (M-7)', lp_kw=dict(minor=1), lp=hdr(header_size=256))
        c('lp-hdr-checksum', 'lp-checksum', 'header checksum wrong (M-7)',
          lp=setattr_('bad_hdr_csum', True))
        c('lp-tables-checksum', 'lp-checksum', 'tables checksum wrong (M-7)',
          lp=setattr_('bad_tbl_csum', True))
        c('lp-part-entsize-40', 'lp-tables', 'partitions entry_size 40 '
          '(M-8)', lp=desc('partitions', es=40))
        c('lp-bdev-entsize-60', 'lp-tables', 'block devices entry_size 60 '
          '(M-8)', lp=desc('block_devices', es=60))
        c('lp-table-beyond', 'lp-tables', 'block devices table offset + 4: '
          'offset + size past tables_size (M-8)',
          lp=lambda L: L.desc_ovr.setdefault('block_devices', {}).update(
              offset=52 * len(L.parts) + 48 * len(L.groups) + 4
              + 24 * sum(len(p['extents']) for p in L.parts)))
        c('lp-entries-overflow', 'lp-tables', 'extents num_entries '
          '0xAAAAAAAB x 24 wraps to 8 in u32 (M-8)',
          lp=desc('extents', num=0xAAAAAAAB))
        c('lp-two-bdevs', 'lp-blockdev', 'two block devices (M-9)',
          lp=lambda L: L.bdevs.append(dict(L.bdevs[0], name=b'super2')))
        c('lp-bdev-size', 'lp-blockdev', 'block device size = device size '
          '- 4096 (M-9)',
          lp=lambda L: L.bdevs[0].update(size=L.super_size - 4096))
        c('lp-name-unterminated', 'lp-name', 'a 36-byte partition name '
          'without NUL (M-10)',
          lp=lambda L: L.parts.insert(1, dict(name=b'odm_a_' + b'x' * 30,
                                              attrs=1, group=0, extents=[])))
        c('vab-merge', 'vab-merge', 'a system_a-cow partition (M-11)',
          lp=lambda L: L.parts.append(dict(name=b'system_a-cow', attrs=0,
                                           group=0, extents=[])))
        # M-11 rev 2 (FS-R-012 §8): the active view must be positively
        # established; every other signal falls back
        c('vab-device-flag', 'vab-device', 'minor 2, header flags = '
          'VIRTUAL_AB_DEVICE (M-11 a)', lp_kw=dict(minor=2, flags=1))
        c('vab-device-and-cow', 'vab-device', 'VIRTUAL_AB_DEVICE and a '
          'vendor_a-cow partition: the flag is checked first (M-11 order)',
          lp_kw=dict(minor=2, flags=1),
          lp=lambda L: L.parts.append(dict(name=b'vendor_a-cow', attrs=0,
                                           group=0, extents=[])))
        c('lp-flags-unknown', 'lp-flags', 'minor 2, header flags = 0x2 '
          '(an unknown flag, M-11 b)', lp_kw=dict(minor=2, flags=2))
        c('lp-flags-high', 'lp-flags', 'minor 2, header flags = 0x80000000 '
          '(M-11 b)', lp_kw=dict(minor=2, flags=0x80000000))
        c('vab-cow-group', 'vab-cow-group', "a partition group named 'cow' "
          'with no partition in it (M-11 d)',
          lp=lambda L: L.group(b'cow'))
        c('ok-group-cowx', 'ok', "a group named 'cowx' is not the COW group "
          '(exact-name match, M-11 d)', lp=lambda L: L.group(b'cowx'))
        c('overlay-scratch', 'overlay', "a partition named 'scratch' (adb "
          'remount storage, M-11 e)',
          lp=lambda L: L.parts.append(dict(name=b'scratch', attrs=0,
                                           group=0, extents=[])))
        c('vab-updated-attr', 'vab-updated', 'vendor attributes '
          'READONLY|UPDATED (M-12 rev 2)',
          vendor_attrs=ATTR_READONLY | ATTR_UPDATED)
        c('vab-updated-other-slot', 'ok', 'UPDATED on vendor_b while the '
          'slot is _a: only the active partition counts (M-12)',
          lp=lambda L: L.find(b'vendor_b').update(attrs=ATTR_READONLY | ATTR_UPDATED))
        c('lp-attr-unknown', 'lp-attr', 'vendor attributes READONLY|0x10 '
          '(an unknown bit, M-12 rev 2)', vendor_attrs=ATTR_READONLY | 0x10)
        c('no-vendor', 'no-vendor', 'no vendor_a partition (M-12)',
          lp=lambda L: L.parts.remove(L.find(b'vendor_a')))
        c('no-vendor-prefix', 'no-vendor', 'vendor_a renamed vendor_a_x, '
          'slot _a (exact-name match, M-12)',
          lp=lambda L: L.find(b'vendor_a').update(name=b'vendor_a_x'))
        c('vendor-dup', 'vendor-dup', 'two vendor_a partitions (M-12)',
          lp=lambda L: L.parts.append(dict(L.find(b'vendor_a'))))
        c('vendor-disabled', 'vendor-disabled', 'vendor_a attributes '
          'READONLY|DISABLED (M-12)',
          vendor_attrs=ATTR_READONLY | ATTR_DISABLED)
        c('vendor-no-extents', 'lp-tables', 'vendor_a num_extents 0 (M-12)',
          lp=vendor(lambda p: p.update(num_ovr=0)))
        c('vendor-extents-past', 'lp-tables', 'vendor_a first_extent_index + '
          'num_extents > extent count (M-12)',
          lp=vendor(lambda p: p.update(num_ovr=200)))
        c('extent-type', 'extent-type', 'vendor extent target_type 1 (ZERO) '
          '(M-12)', lp=vext(tt=1))
        c('extent-source', 'extent-source', 'vendor extent target_source 1 '
          '(M-12)', lp=vext(ts=1))
        c('extent-overflow-sum', 'extent-range', 'target_data 2^64-16: '
          'target_data + num_sectors overflows u64 (M-12)',
          lp=vext(td=2 ** 64 - 16))
        c('extent-overflow-mul', 'extent-range', 'target_data 2^55: '
          '(target_data + num_sectors) x 512 overflows u64 (M-12)',
          lp=vext(td=2 ** 55))
        c('extent-beyond', 'extent-range', 'vendor extent ends 4 KiB past the '
          'device end (M-12)',
          lp=lambda L: L.find(b'vendor_a')['extents'][0].__setitem__(
              2, (L.super_size // SECT) + 8
              - L.find(b'vendor_a')['extents'][0][0]))
        c('extent-ends-at-device', 'ok', 'vendor extent ends exactly at the '
          'device end (M-12 boundary)', lp=self._move_vendor_to_end)
        # ambiguous: num_sectors 0 has no named status
        c('extent-zero-sectors', 'extent-range', 'AMBIGUOUS M-12: a second '
          'vendor extent with num_sectors 0; status not named in the spec '
          '(reference: extent-range)', ambiguous=True,
          lp=lambda L: L.find(b'vendor_a')['extents'].append([0, 0, 2048, 0]))
        c('lp-tables-size-big', 'lp-header', 'AMBIGUOUS M-7: tables_size > '
          'metadata_max_size - header_size; spec lists "size" under '
          'lp-header (reference: lp-header)', ambiguous=True,
          lp=hdr(tables_size=8192))

    def _move_vendor_to_end(self, L):
        v = L.find(b'vendor_a')
        ns, _, td, _ = v['extents'][0]
        data = [d for o, d in L.contents if o == td * SECT][0]
        new_td = L.super_size // SECT - ns
        v['extents'][0][2] = new_td
        L.contents.append((new_td * SECT, data))

    def ext4_cases(self):
        c = self.case

        def sbf(off, fmt, val=None, orv=None, add=None):
            def f(fs, info):
                cur = sb_get(fs, off, fmt)
                sb_set(fs, off, fmt, val if val is not None else
                       cur | orv if orv is not None else cur + add)
            return f

        def jfield(off, fmt, val=None, orv=None, andv=None):
            def f(fs, info):
                io = jino(info) + off
                cur = struct.unpack_from(fmt, fs, io)[0]
                v = val if val is not None else (
                    cur | orv if orv is not None else cur & andv)
                struct.pack_into(fmt, fs, io, v)
            return f

        def erofs(fs, info):
            struct.pack_into('<I', fs, 1024, 0xE0F5E1E2)    # EROFS magic
            sb_set(fs, 0x38, '<H', 0)
        c('fs-type-erofs', 'fs-type', 'EROFS magic at 1024, ext4 magic '
          'zeroed (M-13)', fs=erofs)
        c('ext4-blocksize', 'ext4-blocksize', 's_log_block_size 3 (M-13)',
          fs=sbf(0x18, '<I', 3))
        c('ext4-64bit', 'ext4-features', 'incompat 64bit set (M-13)',
          fs=sbf(0x60, '<I', orv=0x80))
        c('ext4-metadata-csum', 'ext4-features', 'ro_compat metadata_csum '
          'set (M-13)', fs=sbf(0x64, '<I', orv=0x400))
        c('ext4-has-journal', 'ext4-features', 'compat has_journal set '
          '(M-13)', fs=sbf(0x5C, '<I', orv=0x4))
        c('ext4-no-shared-blocks', 'ext4-features', 'ro_compat without '
          'shared_blocks (0x007B, M-13)', fs=sbf(0x64, '<I', 0x7B))
        c('ext4-inode-size-128', 'ext4-inode-size', 's_inode_size 128 '
          '(M-13)', fs=sbf(0x58, '<H', 128))
        c('ext4-inodes-count', 'ext4-geometry', 's_inodes_count + 1 '
          '(!= groups x inodes_per_group, M-14)', fs=sbf(0x0, '<I', add=1))
        c('ext4-first-data-block', 'ext4-geometry', 's_first_data_block 1 '
          '(M-14)', fs=sbf(0x14, '<I', 1))
        c('ext4-bpg-zero', 'ext4-geometry', 's_blocks_per_group 0 (M-14)',
          fs=sbf(0x20, '<I', 0))
        c('ext4-ipg-zero', 'ext4-geometry', 's_inodes_per_group 0 (M-14)',
          fs=sbf(0x28, '<I', 0))
        c('ext4-blocks-beyond', 'ext4-size', 's_blocks_count one block past '
          'the vendor partition (M-14)', fs=sbf(0x4, '<I', add=1))

        def itable(fs, info):
            struct.pack_into('<I', fs, BLK + 8, blocks_count(fs))
        c('ext4-itable-range', 'ext4-range', 'group 0 bg_inode_table_lo = '
          'blocks_count (M-15)', fs=itable)

        def bad_ino(fs, info):
            off = find_dirent(fs, info['etc_blocks'][0],
                              b'thermal_info_config.json')
            struct.pack_into('<I', fs, off, sb_get(fs, 0x0, '<I') + 1)
        c('ext4-inode-number', 'ext4-inode', 'json dirent inode = '
          'inodes_count + 1 (M-15)', fs=bad_ino)

        c('json-inline-flag', 'ext4-inode-flags', 'json inode INLINE_DATA '
          'flag set (M-16)', fs=jfield(0x20, '<I', orv=0x10000000))
        c('json-no-extents-flag', 'ext4-inode-flags', 'json inode without '
          'EXTENTS flag (M-16)', fs=jfield(0x20, '<I', andv=~0x80000 &
                                            0xFFFFFFFF))
        c('json-isize-high', 'ext4-isize', 'json i_size_high 1 (M-16)',
          fs=jfield(0x6C, '<I', 1))
        c('json-size-70000', 'ext4-isize', 'json i_size_lo 70000 (M-16 '
          'inode check precedes M-19)', fs=jfield(0x4, '<I', 70000))

        def root_hdr(field, val):
            def f(fs, info):
                struct.pack_into('<H', fs, jino(info) + 0x28 + field, val)
            return f
        c('ext-bad-magic', 'ext4-extent-magic', 'json extent header magic '
          '0xF30B (M-17)', fs=root_hdr(0, 0xF30B))
        c('ext-entries-gt-max', 'ext4-extent-count', 'json root eh_entries 5 '
          '> eh_max 4 (M-17)', fs=root_hdr(2, 5))
        c('ext-max-5-inode', 'ext4-extent-count', 'json root eh_max 5 '
          '(M-17)', fs=root_hdr(4, 5))
        c('ext-depth-3', 'ext4-extent-depth', 'json root eh_depth 3 (M-17)',
          fs=root_hdr(6, 3))

        def leaf0(fn):
            def f(fs, info):
                io = jino(info)
                start = json_two_block_extent(fs, info)
                body, n = fn(start, blocks_count(fs))
                set_root(fs, io, 0, leaf_bytes(body), n)
            return f
        c('ext-uninit', 'ext4-uninit', 'json extent ee_len 32769 '
          '(uninitialised, M-17)',
          fs=leaf0(lambda s, b: ([(0, 32769, s)], 1)))
        c('ext-len-zero', 'ext4-uninit', 'json extent ee_len 0 (M-17)',
          fs=leaf0(lambda s, b: ([(0, 0, s)], 1)))
        c('ext-hole', 'ext4-hole', 'json 2 extents, the second starts at '
          'logical 2 instead of 1 (M-17)',
          fs=leaf0(lambda s, b: ([(0, 1, s), (2, 1, s + 1)], 2)))
        c('ext-short-cover', 'ext4-hole', 'json extents cover 1 of 2 '
          'blocks (M-17)', fs=leaf0(lambda s, b: ([(0, 1, s)], 1)))
        c('ext-start-not-0', 'ext4-hole', 'json first extent at logical 1 '
          '(M-17)', fs=leaf0(lambda s, b: ([(1, 2, s)], 1)))
        c('ext-beyond-blocks', 'ext4-range', 'json extent start + len = '
          'blocks_count + 1 (M-17)',
          fs=leaf0(lambda s, b: ([(0, 2, b - 1)], 1)))
        c('ext-start-hi', 'ext4-range', 'json extent ee_start_hi 1 (M-17)',
          fs=leaf0(lambda s, b: ([(0, 2, s | (1 << 32))], 1)))

        def tree1(child_depth=0, child_max=340, child_blk=None):
            def f(fs, info):
                io = jino(info)
                start = json_two_block_extent(fs, info)
                leaf = info['free'][0]
                put_node(fs, leaf, child_depth, leaf_bytes([(0, 2, start)]),
                         0 if child_depth else 1, emax=child_max)
                set_root(fs, io, 1, index_bytes(
                    [(0, leaf if child_blk is None else child_blk(fs))]), 1)
            return f
        c('ext-child-range', 'ext4-range', 'json depth-1 index points at '
          'block blocks_count (M-17)', fs=tree1(child_blk=blocks_count))
        c('ext-child-depth', 'ext4-extent-depth', 'json depth-1 root, child '
          'node claims depth 1 (M-17)', fs=tree1(child_depth=1))
        c('ext-child-max-341', 'ext4-extent-count', 'json leaf block eh_max '
          '341 (M-17)', fs=tree1(child_max=341))

        def budget(fs, info):
            io = jino(info)
            idx, leaf = info['free'][0:2]
            put_node(fs, leaf, 0, b'', 0)                   # empty leaf
            put_node(fs, idx, 1, index_bytes([(i, leaf) for i in range(340)]),
                     340)
            set_root(fs, io, 2, index_bytes([(i, idx) for i in range(4)]), 4)
        c('read-budget', 'read-budget', 'json extent tree depth 2: 4 x 340 '
          'index entries all valid, pointing at an empty leaf; 1360 block '
          'reads > 1 MiB (M-5 budget)', fs=budget)

        # Budget boundary. Accounting (task statement for M-5): geometry
        # 4096, metadata_max_size, superblock 1024, 32 per group descriptor,
        # 256 per inode, 4096 per directory / extent-tree / data block. The
        # baseline flow loads 5 inodes (/, etc, json, vr, build.prop), scans
        # 2 directory blocks and reads ceil(size/4096) data blocks per file.
        # 5 x 288 = 1440 = 416 mod 512, so the budget cannot be hit exactly;
        # the edges are budget - 96 (ok) and budget + 416 (read-budget).
        bt = self.base['eureka']
        data_blocks = sum(-(-len(x) // BLK) for x in (bt.json, bt.vr,
                                                       bt.files['/build.prop']))

        def fixed(mms):
            return 4096 + mms + 1024 + 5 * (32 + 256) + 2 * BLK + \
                data_blocks * BLK

        def budget_tree(k):
            """k extra extent-tree block reads: 1 index + (k-1) leaves."""
            def f(fs, info):
                io = jino(info)
                start = json_two_block_extent(fs, info)
                idx, empty, real = info['free'][0:3]
                put_node(fs, empty, 0, b'', 0)
                put_node(fs, real, 0, leaf_bytes([(0, 2, start)]), 1)
                kids = [(0, empty)] * (k - 2) + [(0, real)]
                put_node(fs, idx, 1, index_bytes(kids), len(kids))
                set_root(fs, io, 2, index_bytes([(0, idx)]), 1)
            return f
        budget = 1048576
        for name, mms, expect in (('budget-edge-ok', 9728, 'ok'),
                                  ('budget-edge-over', 10240, 'read-budget')):
            k = (budget - fixed(mms)) // BLK + (expect != 'ok')
            total = fixed(mms) + k * BLK
            assert (total <= budget) == (expect == 'ok') and k - 1 <= 340
            c(name, expect, 'AMBIGUOUS M-5 read granularity: metadata_max_size '
              '%d, json extent tree depth 2 with %d block reads; %d bytes read '
              'in total (budget %+d) under the per-read accounting of the '
              'task' % (mms, k, total, total - budget), lp_kw=dict(mms=mms),
              fs=budget_tree(k), ambiguous=True)

        def dot(field, fmt, val):
            def f(fs, info):
                struct.pack_into(fmt, fs, info['etc_blocks'][0] * BLK + field,
                                 val)
            return f
        c('dirent-reclen-8', 'ext4-dirent', '/etc "." rec_len 8 (M-18)',
          fs=dot(4, '<H', 8))
        c('dirent-reclen-not4', 'ext4-dirent', '/etc "." rec_len 14 (M-18)',
          fs=dot(4, '<H', 14))
        c('dirent-reclen-past', 'ext4-dirent', '/etc "." rec_len 4100, past '
          'the block (M-18)', fs=dot(4, '<H', 4100))
        c('dirent-namelen', 'ext4-dirent', '/etc "." name_len 5 '
          '(5 + 8 > rec_len 12, M-18)', fs=dot(6, '<B', 5))

        def root_mode(fs, info):
            struct.pack_into('<H', fs, info['ino']['/'], 0x81A4)
        c('root-not-dir', 'ext4-notdir', 'inode 2 mode regular (M-18)',
          fs=root_mode)
        self.tcase('etc-not-dir', 'ext4-notdir', '/etc is a regular file '
                   '(M-18)', drop=['/etc/thermal_info_config.json',
                                   '/etc/vr_runtime_power_mitigation.json',
                                   '/etc/thermal_info_config.json.bak',
                                   '/etc/vr_runtime_power_mitigation',
                                   '/etc/fixture.conf'],
                   extra={'/etc': b'not a directory\n'})
        # A single directory of more than 16 blocks is > 65536 bytes and
        # fails M-16 (ext4-isize) first, so the M-18 cap is reached through
        # the sum: / (1 block) + /etc (exactly 16 blocks = 65536 bytes).
        def etc_tree(n):
            many = {'/etc/f%03d-%s' % (i, 'x' * 190): b'' for i in range(n)}
            return mk_tree('eureka', extra=many, ninodes=512)

        def etc_blocks(n):
            return len(self.fsb.build(etc_tree(n))[1]['etc_blocks'])
        lo, hi = 1, 400                 # smallest n giving >= 16 blocks
        assert etc_blocks(hi) > 16
        while lo < hi:
            mid = (lo + hi) // 2
            if etc_blocks(mid) >= 16:
                hi = mid
            else:
                lo = mid + 1
        assert etc_blocks(lo) == 16 and etc_blocks(lo - 1) == 15
        self.case('dir-cap', 'ext4-dir-cap', '/ is 1 block, /etc is exactly '
                  '16 blocks (%d files of 195-char names): 17 directory '
                  'blocks in total (M-18)' % lo, tree=etc_tree(lo))
        self.case('etc-17-blocks', 'ext4-isize', '/etc of 17+ blocks: i_size '
                  '> 65536 fails M-16 before the M-18 cap',
                  tree=etc_tree(400))
        t15 = etc_tree(lo - 1)
        self.case('dir-16-blocks-total', 'ok', 'AMBIGUOUS M-18: / 1 block + '
                  '/etc 15 blocks = 16 blocks scanned once each (ok); a '
                  'reader that scans a directory once per looked-up name '
                  'exceeds the cap', tree=t15, ambiguous=True)

        def dir_size(fs, info):
            struct.pack_into('<I', fs, info['ino']['/etc'] + 4, 4000)
        c('dir-size-not-4096', 'ext4-dirent', 'AMBIGUOUS M-18: /etc i_size '
          '4000, not a multiple of 4096; no status named (reference: '
          'ext4-notdir)', fs=dir_size, ambiguous=True)

        self.tcase('json-missing', 'file-missing', 'no '
                   '/etc/thermal_info_config.json (M-19)',
                   drop=['/etc/thermal_info_config.json'])
        self.tcase('vr-missing', 'file-missing', 'no '
                   '/etc/vr_runtime_power_mitigation.json (M-19)',
                   drop=['/etc/vr_runtime_power_mitigation.json'])
        self.tcase('buildprop-missing', 'file-missing', 'no /build.prop '
                   '(M-19)', drop=['/build.prop'])
        self.tcase('etc-missing', 'file-missing', 'no /etc at all (M-19)',
                   drop=[k for k in mk_tree().files if k.startswith('/etc/')])
        self.tcase('json-symlink', 'file-type', 'json is a slow symlink '
                   '(EXTENTS flag set, target 100 bytes, M-19)',
                   extra={'/etc/thermal_info_config.json':
                          ('symlink', '/vendor/etc/' + 'l' * 88)})
        self.tcase('json-is-dir', 'file-type', 'json is a directory (M-19)',
                   extra={'/etc/thermal_info_config.json': ('dir',)})
        self.tcase('json-fast-symlink', 'ext4-inode-flags', 'AMBIGUOUS '
                   'M-16/M-19 order: json is a fast symlink (no EXTENTS '
                   'flag); reference applies M-16 first (else file-type)',
                   ambiguous=True,
                   extra={'/etc/thermal_info_config.json':
                          ('symlink', 'x.json')})
        self.tcase('vr-size-5000', 'file-size', 'vr list 5000 bytes > 4096 '
                   '(M-19)', vr=filler('vr', 5000))

    def content_cases(self):
        t, j = self.tcase, self.jcase
        dev, inc = b'eureka', INCR['eureka'].encode()
        # --- M-21 build.prop
        t('bp-no-device', 'buildprop', 'build.prop without '
          'ro.product.vendor.device (M-21)',
          prop=build_prop(dev, inc).replace(b'ro.product.vendor.device=',
                                            b'ro.product.vendor.devic='))
        t('bp-dup-incr', 'buildprop', 'incremental twice, same value (M-21)',
          prop=build_prop(dev, inc, b'ro.vendor.build.version.incremental='
                          + inc + b'\n'))
        t('bp-dup-device-diff', 'buildprop', 'device key twice, different '
          'values (M-21)', prop=build_prop(dev, inc,
                                           b'ro.product.vendor.device=x\n'))
        t('bp-value-space', 'buildprop', 'incremental "5813 2907" (M-21)',
          prop=build_prop(dev, b'5813 2907'))
        t('bp-value-empty', 'buildprop', 'empty device value (M-21)',
          prop=build_prop(b'', inc))
        t('bp-value-93', 'buildprop', 'incremental 93 bytes (M-21)',
          prop=build_prop(dev, b'7' * 93))
        t('bp-key-space', 'buildprop', '"ro.product.vendor.device = eureka" '
          '(no trimming: the key does not match, M-21)',
          prop=build_prop(dev, inc).replace(b'ro.product.vendor.device=',
                                            b'ro.product.vendor.device = '))
        # --- M-21a (rev 3, PM 2026-10-15): Virtual A/B devices -> built-in
        t('vab-prop-enabled', 'vab-policy', 'ro.virtual_ab.enabled=true '
          '(M-21a)', prop=build_prop(dev, inc, b'ro.virtual_ab.enabled=true\n'))
        t('vab-prop-retrofit', 'vab-policy', 'ro.virtual_ab.retrofit=true '
          'alone (M-21a)', prop=build_prop(dev, inc,
                                            b'ro.virtual_ab.retrofit=true\n'))
        t('vab-prop-compression', 'vab-policy', 'ro.virtual_ab.compression'
          '.enabled=true alone (M-21a)', prop=build_prop(
              dev, inc, b'ro.virtual_ab.compression.enabled=true\n'))
        t('vab-prop-empty', 'vab-policy', 'ro.virtual_ab.enabled= (empty, '
          'unreadable value: refused, M-21a)',
          prop=build_prop(dev, inc, b'ro.virtual_ab.enabled=\n'))
        t('vab-prop-garbage', 'vab-policy', 'ro.virtual_ab.enabled=1 (not '
          '"false": refused, M-21a)',
          prop=build_prop(dev, inc, b'ro.virtual_ab.enabled=1\n'))
        t('vab-prop-spaced', 'vab-policy', '" ro.virtual_ab.enabled = true<TAB>" '
          '(spaces and tabs ignored, M-21a)',
          prop=build_prop(dev, inc, b' ro.virtual_ab.enabled = true\t\n'))
        t('vab-prop-false-then-true', 'vab-policy', 'enabled=false, then '
          'enabled=true (any non-false line refuses, M-21a)',
          prop=build_prop(dev, inc, b'ro.virtual_ab.enabled=false\n'
                          b'ro.virtual_ab.enabled=true\n'))
        t('vab-prop-crlf', 'vab-policy', 'ro.virtual_ab.enabled=true with '
          'CRLF (M-21a)', prop=build_prop(dev, inc,
                                           b'ro.virtual_ab.enabled=true\r\n'))
        t('ok-vab-prop-false', 'ok', 'ro.virtual_ab.enabled=false and '
          'retrofit=false: not a Virtual A/B device (M-21a)',
          prop=build_prop(dev, inc, b'ro.virtual_ab.enabled=false\n'
                          b'ro.virtual_ab.retrofit= false \n'))
        t('ok-vab-prop-commented', 'ok', '#ro.virtual_ab.enabled=true is a '
          'comment (M-21a)', prop=build_prop(dev, inc,
                                              b'#ro.virtual_ab.enabled=true\n'))
        t('ok-vab-prop-other-prefix', 'ok', 'ro.virtual_abx=true and '
          'persist.ro.virtual_ab.enabled=true do not match (M-21a)',
          prop=build_prop(dev, inc, b'ro.virtual_abx=true\n'
                          b'persist.ro.virtual_ab.enabled=true\n'))
        for nm, ch in (('ff', b'\x0c'), ('vt', b'\x0b'), ('cr', b'\r')):
            t('vab-prop-lead-' + nm, 'vab-policy', 'a leading ' + nm.upper()
              + ' byte before ro.virtual_ab.enabled=true (isspace, as '
              'Android trims, M-21a)',
              prop=build_prop(dev, inc, ch + b'ro.virtual_ab.enabled=true\n'))
        t('ok-vab-prop-isspace-false', 'ok', 'FF/VT/CR around key and the '
          'value false: trimmed, not Virtual A/B (M-21a)',
          prop=build_prop(dev, inc, b'\x0c\x0bro.virtual_ab.enabled\r=\x0b'
                          b'false\x0c\n'))
        t('vab-prop-and-no-device', 'buildprop', 'enabled=true and no device '
          'key: the M-21 failure comes first (M-21a order)',
          prop=build_prop(dev, inc, b'ro.virtual_ab.enabled=true\n').replace(
              b'ro.product.vendor.device=', b'ro.product.vendor.devic='))
        t('bp-line-without-eq', 'ok', 'AMBIGUOUS M-21: a line '
          '"import /vendor/etc/x.prop" (no "="); reference rejects it',
          prop=build_prop(dev, inc, b'import /vendor/etc/x.prop\n'),
          ambiguous=True)
        # --- M-22 syntax / depth
        j('json-bom', 'json-syntax', 'UTF-8 BOM (M-22)',
          text=lambda b: b'\xef\xbb\xbf' + b)
        j('json-escape', 'json-syntax', 'a \\n escape in a Type string (M-22)',
          text=lambda b: b.replace(b'"CPU"', b'"C\\nPU"', 1))
        j('json-escape-quote', 'json-syntax', 'a \\" escape (M-22)',
          text=lambda b: b.replace(b'"GPU"', b'"G\\"PU"', 1))
        j('json-nonascii', 'json-syntax', 'UTF-8 e-acute in a Type string '
          '(M-22)', text=lambda b: b.replace(b'"SKIN"', b'"SKIN\xc3\xa9"', 1))
        j('json-tab-in-string', 'json-syntax', 'raw TAB inside a string '
          '(M-22)', text=lambda b: b.replace(b'"SKIN"', b'"SK\tIN"', 1))
        j('json-trailing', 'json-syntax', 'garbage after the top value '
          '(M-22)', text=lambda b: b + b'x')
        j('json-two-values', 'json-syntax', 'a second top value (M-22)',
          text=lambda b: b + b'{}')
        j('json-leading-zero-num', 'json-syntax', 'bare number 05 (RFC 8259 '
          'syntax, M-22)', text=lambda b: b.replace(b'77.5', b'05', 1))
        j('json-truncated', 'json-syntax', 'document cut in half (M-22)',
          text=lambda b: b[:len(b) // 2])
        j('json-empty', 'json-syntax', 'empty file (M-22)',
          text=lambda b: b'')
        j('json-single-quote', 'json-syntax', "single-quoted string (M-22)",
          text=lambda b: b.replace(b'"CPU"', b"'CPU'", 1))
        j('json-trailing-comma', 'json-syntax', 'trailing comma in an array '
          '(M-22)', text=lambda b: b.replace(b', "NAN"]', b', "NAN",]', 1))
        j('json-ff-whitespace', 'json-syntax', 'form feed as whitespace '
          '(M-22)', text=lambda b: b.replace(b'\n', b'\n\x0c', 1))

        def depth5(m):
            m.sensors[0].set('HotThreshold', [N] * 6 + [[]])
        j('json-depth5', 'json-depth', 'an empty array as a HotThreshold '
          'element: depth 5 (M-22)', mutate=depth5)
        # --- M-23 keys
        j('json-dupkey-sensor', 'json-dupkey', 'Name twice in a sensor '
          '(M-23)', mutate=lambda m: m.sensors[2].pairs.insert(
              1, ('Name', 'fx_dupkey')))
        j('json-dupkey-top', 'json-dupkey', 'CoolingDevices twice (M-23)',
          mutate=lambda m: m.extra_top.append(('CoolingDevices', [])))
        j('json-unknown-sensor-key', 'json-unknown-key', 'sensor key '
          'BindedCdevInfo (M-23)', mutate=lambda m: m.sensors[1].pairs.append(
              ('BindedCdevInfo', [])))
        j('json-unknown-top-key', 'json-unknown-key', 'top key PowerRails '
          '(M-23)', mutate=lambda m: m.extra_top.append(('PowerRails', [])))
        j('json-cdev-extra-key', 'json-unknown-key', 'cooling device with '
          'MaxState (M-23)', mutate=lambda m: m.cdevs[1].pairs.append(
              ('MaxState', Num('3'))))
        j('json-sensors-missing', 'json-type', 'no Sensors key (M-23)',
          mutate=lambda m: setattr(m, 'sensors', None))
        j('json-sensors-object', 'json-type', 'Sensors is an object (M-23)',
          text=lambda b: b'{"Sensors": {}}')
        j('json-top-array', 'json-type', 'top value is an array (M-23)',
          text=lambda b: b'["Sensors"]')
        j('json-cdev-not-array', 'json-type', 'CoolingDevices is a string '
          '(M-23)', mutate=lambda m: setattr(m, 'cdevs', 'none'))
        j('json-name-missing', 'json-type', 'sensor without Name (M-23)',
          mutate=lambda m: m.sensors[3].drop('Name'))
        j('json-vr-missing', 'json-type', 'sensor without VrThreshold '
          '(M-23)', mutate=lambda m: m.sensors[3].drop('VrThreshold'))
        j('json-mult-missing', 'json-type', 'sensor without Multiplier '
          '(M-23)', mutate=lambda m: m.sensors[3].drop('Multiplier'))
        j('json-type-number', 'json-type', 'Type 5 (M-23)',
          mutate=lambda m: m.sensors[3].set('Type', Num('5')))
        j('json-name-number', 'json-type', 'Name 5 (M-23)',
          mutate=lambda m: m.sensors[3].set('Name', Num('5')))
        j('json-ht-not-array', 'json-type', 'HotThreshold is a string '
          '(M-23)', mutate=lambda m: m.sensors[3].set('HotThreshold', 'NAN'))
        j('json-hyst-not-array', 'json-type', 'HotHysteresis is a number '
          '(M-23)', mutate=lambda m: m.sensors[0].set('HotHysteresis',
                                                     Num('0')))
        j('json-sensor-not-object', 'json-type', 'a Sensors element is an '
          'array (M-23)', mutate=lambda m: m.sensors.append([]))
        j('json-cdev-type-missing', 'json-type', 'cooling device without '
          'Type (M-23)', mutate=lambda m: m.cdevs[0].drop('Type'))
        # --- M-24 values
        j('json-slots-6', 'json-slots', 'HotThreshold with 6 elements (M-24)',
          mutate=lambda m: m.sensors[0].set('HotThreshold', [N] * 6))
        j('json-slots-8', 'json-slots', 'HotThreshold with 8 elements (M-24)',
          mutate=lambda m: m.sensors[0].set('HotThreshold', [N] * 8))
        j('json-hyst-slots-6', 'json-slots', 'HotHysteresis with 6 elements '
          '(M-24)', mutate=lambda m: m.sensors[0].set('HotHysteresis',
                                                     ['0'] * 6))

        def slot3(v):
            return lambda m: m.sensors[0].get('HotThreshold').__setitem__(3, v)
        j('json-exponent', 'json-number', 'slot value 1e2 (M-24)',
          mutate=slot3(Num('1e2')))
        j('json-4-decimals', 'json-number', 'slot value 45.1234 (M-24)',
          mutate=slot3(Num('45.1234')))
        j('json-leading-zero-str', 'json-number', 'slot value "05" (M-24)',
          mutate=slot3('05'))
        j('json-str-space', 'json-number', 'slot value " 45" (M-24)',
          mutate=slot3(' 45'))
        j('json-str-plus', 'json-number', 'slot value "+45" (M-24)',
          mutate=slot3('+45'))
        j('json-str-nan-lower', 'json-number', 'slot value "nan" (M-24)',
          mutate=slot3('nan'))
        j('json-10-digits', 'json-number', 'slot value 1000000000 (M-24)',
          mutate=slot3(Num('1000000000')))
        j('json-int32-over', 'json-number', 'slot value 2147483.648 '
          '(> INT32_MAX milli, M-24)', mutate=slot3('2147483.648'))
        j('json-int32-min', 'json-number', 'slot value -2147483.648 '
          '(= INT32_MIN milli, M-24)', mutate=slot3(Num('-2147483.648')))
        j('json-slot-null', 'json-number', 'slot value null (M-24)',
          mutate=slot3(None))
        j('json-slot-true', 'json-number', 'slot value true (M-24)',
          mutate=slot3(True))
        j('json-hyst-bad', 'json-number', 'hysteresis value "1.0001" (M-24)',
          mutate=lambda m: m.sensors[0].get('HotHysteresis').__setitem__(
              1, '1.0001'))

        def mult(v):
            return lambda m: m.sensors[0].set('Multiplier', v)
        j('json-mult-zero', 'json-number', 'Multiplier 0 (M-24)',
          mutate=mult(Num('0')))
        j('json-mult-zero-dec', 'json-number', 'Multiplier "0.000000" '
          '(M-24)', mutate=mult('0.000000'))
        j('json-mult-negative', 'json-number', 'Multiplier -0.001 (M-24)',
          mutate=mult(Num('-0.001')))
        j('json-mult-7-decimals', 'json-number', 'Multiplier 0.0000001 '
          '(M-24)', mutate=mult(Num('0.0000001')))
        j('json-mult-nan', 'json-number', 'Multiplier "NAN" (M-24)',
          mutate=mult('NAN'))
        j('json-mult-bool', 'json-number', 'Multiplier true (M-24)',
          mutate=mult(True))
        j('json-vr-1', 'json-vr', 'VrThreshold "1" (M-24)',
          mutate=lambda m: m.sensors[0].set('VrThreshold', '1'))
        j('json-vr-number', 'json-vr', 'VrThreshold 1 (M-24)',
          mutate=lambda m: m.sensors[0].set('VrThreshold', Num('1')))
        j('json-monitor-false', 'json-monitor', 'Monitor false (M-24)',
          mutate=lambda m: m.sensors[0].set('Monitor', False))
        j('json-monitor-string', 'json-monitor', 'Monitor "true" (M-24)',
          mutate=lambda m: m.sensors[0].set('Monitor', 'true'))
        j('json-set-no-monitor', 'json-monitor', 'a set slot without Monitor '
          '(M-24)', mutate=lambda m: m.sensors[0].drop('Monitor'))
        # --- M-25 names and counts
        j('json-name-space', 'json-name', 'Name "fx cpu" (M-25)',
          mutate=lambda m: m.sensors[0].set('Name', 'fx cpu'))
        j('json-name-32', 'json-name', 'Name of 32 bytes (M-25)',
          mutate=lambda m: m.sensors[0].set('Name', 'n' * 32))
        j('json-name-empty', 'json-name', 'Name "" (M-25)',
          mutate=lambda m: m.sensors[0].set('Name', ''))
        j('json-dupname', 'json-dupname', 'two sensors named fx-cpu0 (M-25)',
          mutate=lambda m: m.sensors[1].set('Name', 'fx-cpu0'))
        j('json-count-129', 'json-count', '129 sensors (M-25)',
          mutate=lambda m: setattr(m, 'sensors', [
              S('s%03d' % i, 'UNKNOWN', [N] * 7, monitor=None)
              for i in range(129)]))
        j('json-count-0', 'json-count', 'Sensors [] (M-25)',
          mutate=lambda m: setattr(m, 'sensors', []))
        j('json-cdev-name-space', 'ok', 'AMBIGUOUS M-25: cooling '
          'device Name "cdev 0"; reference applies the Name rule to cooling '
          'devices too', mutate=lambda m: m.cdevs[0].set('Name', 'cdev 0'),
          ambiguous=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description='fs-metacfg fixture writer')
    ap.add_argument('--out', required=True)
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    work = tempfile.mkdtemp(prefix='mkfix-')
    try:
        g = Gen(a.out, work)
        g.all_cases()
        g.write_tsv()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print('mkfix: %d cases + %d ambiguous cases in %s'
          % (len(g.rows), len(g.amb_rows), a.out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
