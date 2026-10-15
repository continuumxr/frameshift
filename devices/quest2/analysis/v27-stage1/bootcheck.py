import struct, sys, hashlib, gzip, io
# read-only layout check of a boot header v2 image
p = sys.argv[1]
b = open(p, 'rb').read()
assert b[:8] == b'ANDROID!'
ks, kaddr, rs, raddr, ss, saddr, tags, page, ver = struct.unpack('<9I', b[8:44])
print('kernel_size', ks, 'ramdisk_size', rs, 'second', ss, 'page', page, 'hdr_ver', ver)
off = 1632  # v1: recovery_dtbo_size(4) offset(8) header_size(4) ; v2: dtb_size(4) dtb_addr(8)
rds, rdo, hs = struct.unpack('<IQI', b[off:off + 16])
dtbs, dtba = struct.unpack('<IQ', b[off + 16:off + 28])
print('rec_dtbo', rds, rdo, 'hdr_size', hs, 'dtb_size', dtbs, hex(dtba))
pg = lambda n: (n + page - 1) // page
ko = page
ro = ko + pg(ks) * page
so = ro + pg(rs) * page
do = so + pg(ss) * page + pg(rds) * page
end = do + pg(dtbs) * page
print('kernel@', ko, 'magic', b[ko:ko + 4].hex(), 'arm64 magic@0x38', b[ko + 0x38:ko + 0x3c])
print('ramdisk@', ro, 'magic', b[ro:ro + 4].hex())
print('dtb@', do, 'magic', b[do:do + 4].hex(), 'end of payload', end, 'file', len(b))
# count FDT blobs in the dtb section
n = 0; i = do
while i < do + dtbs:
    assert b[i:i + 4] == bytes.fromhex('d00dfeed'), (i, b[i:i + 4])
    tot = struct.unpack('>I', b[i + 4:i + 8])[0]; n += 1; i += tot
print('fdt blobs', n, 'section consumed exactly', i == do + dtbs)
tail = b[-64:]
print('AVB footer magic at end:', tail[:4])
rest = b[end:]
first = len(rest) - len(rest.lstrip(b'\0'))
print('first non-zero byte after payload at', end + first, '(AVB vbmeta/footer area)')
print('sha256 kernel', hashlib.sha256(b[ko:ko + ks]).hexdigest())
print('sha256 dtb', hashlib.sha256(b[do:do + dtbs]).hexdigest())
rd = gzip.decompress(b[ro:ro + rs])
print('ramdisk gunzip', len(rd), 'cpio magic', rd[:6])
# list cpio newc names
names = []; i = 0
while i < len(rd):
    if rd[i:i + 6] != b'070701': break
    h = rd[i:i + 110]; nsz = int(h[94:102], 16); fsz = int(h[54:62], 16); mode = int(h[14:22], 16)
    name = rd[i + 110:i + 110 + nsz - 1].decode()
    if name == 'TRAILER!!!': break
    names.append((oct(mode), fsz, name))
    i = (i + 110 + nsz + 3) & ~3; i = (i + fsz + 3) & ~3
print('cpio entries', len(names))
for m, s, nme in names:
    print(' ', m, s, nme)
