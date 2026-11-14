#!/usr/bin/env python3
"""sheet.py SALIDA.png NOMBRE...: hoja de contacto de shots/NOMBRE-{0,1}.png (fila superior buffer 0, inferior buffer 1), a 1/4."""
import zlib, struct, os, sys
d = os.path.expanduser('~/sapphire-angel/research/metal/medicion/shots/')
def rd(p):
    b = open(p, 'rb').read(); i = 8; idat = b''
    while i < len(b):
        n, t = struct.unpack('>I4s', b[i:i+8])
        if t == b'IHDR': w, h = struct.unpack('>II', b[i+8:i+16])
        if t == b'IDAT': idat += b[i+8:i+8+n]
        i += 12 + n
    raw = zlib.decompress(idat); st = w * 3 + 1
    return [bytes(raw[y*st+1+x*3+c] for x in range(0, w, 4) for c in range(3)) for y in range(0, h, 4)]
rows = []
for buf in (0, 1):
    imgs = [rd(d + '%s-%d.png' % (n, buf)) for n in sys.argv[2:]]
    for y in range(len(imgs[0])): rows.append(b'\0' + b''.join(im[y] + b'\xff\x00\x00' * 2 for im in imgs))
w = (len(rows[0]) - 1) // 3; h = len(rows)
def ch(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b))
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(b''.join(rows), 6)) + ch(b'IEND', b''))
