"""Slims the native part: keeps only the given exports and empties its data
segments (the interpreted runtime initializes memory).
Usage: slim_native.py <in.wasm> <out.wasm> <export,export,...>"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wasmtool import *
src, dst = sys.argv[1], sys.argv[2]
keep = set()
for item in sys.argv[3].split(','):
    keep |= set(open(item[1:]).read().split()) if item.startswith('@') else {item}
b = open(src, 'rb').read()
out = bytearray(b[:8])
for sid, s, e in sections(b):
    body = b[s:e]
    if sid == 7:  # exports
        p = [s]; kept = []
        for _ in range(uleb_at(b, p)):
            start = p[0]; l = uleb_at(b, p); name = b[p[0]:p[0]+l].decode(); p[0] += l; p[0] += 1; uleb_at(b, p)
            if name in keep: kept.append(b[start:p[0]])
        body = enc_uleb(len(kept)) + b''.join(kept)
    elif sid == 11:  # data: same segments, no bytes
        p = [s]; n = uleb_at(b, p); segs = []
        for _ in range(n):
            start = p[0]; flags = uleb_at(b, p)
            if flags == 2: uleb_at(b, p)
            if flags != 1:
                while b[p[0]] != 0x0b:
                    op = b[p[0]]; p[0] += 1
                    if op == 0x41: sleb_at(b, p)
                    elif op == 0x23: uleb_at(b, p)
                p[0] += 1
            head = b[start:p[0]]; size = uleb_at(b, p); p[0] += size
            segs.append(head + enc_uleb(0))
        body = enc_uleb(n) + b''.join(segs)
    elif sid == 0:
        p = [s]; l = uleb_at(b, p); name = b[p[0]:p[0]+l]
        if name not in (b'name', b'target_features'): continue  # drop other custom sections
    out += bytes([sid]) + enc_uleb(len(body)) + body
open(dst, 'wb').write(out)
print(f'{len(b)/1e6:.1f} MB -> {len(out)/1e6:.1f} MB')
