import struct, sys, hashlib, os
# read-only: parse AVB vbmeta images, list descriptors, compute the
# avbtool-style vbmeta digest (sha256 over main blob, then each chained
# partition's blob in descriptor order) and check the boot hash descriptor.
d = sys.argv[1]
def blob(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'AVB0', path
    auth, aux = struct.unpack('>QQ', b[12:28])
    return b[:256 + auth + aux], b
def descs(b):
    auth, aux = struct.unpack('>QQ', b[12:28])
    (alg,) = struct.unpack('>I', b[28:32])
    do, ds = struct.unpack('>QQ', b[96:112])
    ri, = struct.unpack('>Q', b[112:120]); fl, ril = struct.unpack('>II', b[120:128])
    rel = b[128:176].rstrip(b'\0').decode()
    a = 256 + auth + do; e = a + ds; out = []
    while a < e:
        tag, n = struct.unpack('>QQ', b[a:a + 16]); p = b[a + 16:a + 16 + n]; a += 16 + n
        out.append((tag, p))
    return alg, ri, fl, ril, rel, out
main, _ = blob(os.path.join(d, 'vbmeta.img'))
h = hashlib.sha256(main)
for name in ('vbmeta.img', 'vbmeta_system.img', 'vbmeta_vendor.img'):
    bl, _ = blob(os.path.join(d, name))
    alg, ri, fl, ril, rel, ds = descs(bl)
    print(f'== {name}: blob {len(bl)} B, algorithm {alg}, rollback_index {ri}, flags {fl}, rb_loc {ril}, release "{rel}"')
    for tag, p in ds:
        if tag == 0:
            kl, vl = struct.unpack('>QQ', p[:16]); k = p[16:16 + kl].decode(); v = p[17 + kl:17 + kl + vl].decode(errors='replace')
            print(f'  property {k} = {v}')
        elif tag == 2:
            isz, = struct.unpack('>Q', p[:8]); alg2 = p[8:40].rstrip(b'\0').decode()
            nl, sl, dl, f = struct.unpack('>IIII', p[40:56]); o = 56 + 60
            nm = p[o:o + nl].decode(); salt = p[o + nl:o + nl + sl]; dg = p[o + nl + sl:o + nl + sl + dl]
            print(f'  hash {nm} size {isz} {alg2} digest {dg.hex()}')
            img = os.path.join(d, nm + '.img')
            if os.path.exists(img):
                data = open(img, 'rb').read()[:isz]
                ok = hashlib.new(alg2, salt + data).digest() == dg
                print(f'    check {nm}.img first {isz} B: {"MATCH" if ok else "MISMATCH"}')
        elif tag == 1:
            # hashtree: name follows a 164-byte fixed part (AvbHashtreeDescriptor)
            nl, = struct.unpack('>I', p[88:92])
            print(f'  hashtree {p[164:164 + nl].decode(errors="replace")}')
        elif tag == 4:
            rl, nl, pl, f = struct.unpack('>IIII', p[:16]); nm = p[16 + 60:16 + 60 + nl].decode()
            print(f'  chain {nm} rb_loc {rl}')
            if name == 'vbmeta.img':
                cb, _ = blob(os.path.join(d, nm + '.img')); h.update(cb)
        else:
            print(f'  tag {tag} ({len(p)} B)')
print('vbmeta digest (sha256, main + chained):', h.hexdigest())
