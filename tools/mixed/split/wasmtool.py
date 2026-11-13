"""Small wasm binary helpers for the mixed-mode build."""
def uleb_at(b, p):
    r = s = 0
    while True:
        x = b[p[0]]; p[0] += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return r
def sleb_at(b, p):
    r = s = 0
    while True:
        x = b[p[0]]; p[0] += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80:
            if x & 0x40: r -= 1 << s
            return r
def enc_uleb(n):
    out = bytearray()
    while True:
        x = n & 0x7f; n >>= 7
        out.append(x | (0x80 if n else 0))
        if not n: return bytes(out)
def sections(b):
    p = [8]; out = []
    while p[0] < len(b):
        sid = b[p[0]]; p[0] += 1; size = uleb_at(b, p); out.append((sid, p[0], p[0] + size)); p[0] += size
    return out
def import_function_count(b):
    n = 0
    for sid, s, e in sections(b):
        if sid != 2: continue
        p = [s]
        for _ in range(uleb_at(b, p)):
            for _ in range(2): l = uleb_at(b, p); p[0] += l
            kind = b[p[0]]; p[0] += 1
            if kind == 0: uleb_at(b, p); n += 1
            elif kind == 1: p[0] += 1; f = uleb_at(b, p); uleb_at(b, p); (uleb_at(b, p) if f & 1 else None)
            elif kind == 2: f = uleb_at(b, p); uleb_at(b, p); (uleb_at(b, p) if f & 1 else None)
            elif kind == 3: p[0] += 2
            elif kind == 4: p[0] += 1; uleb_at(b, p)
    return n
def function_names(b):
    """name section: function index -> name"""
    names = {}
    for sid, s, e in sections(b):
        if sid != 0: continue
        p = [s]; l = uleb_at(b, p)
        if b[p[0]:p[0]+l] != b'name': continue
        p[0] += l
        while p[0] < e:
            sub = b[p[0]]; p[0] += 1; ssz = uleb_at(b, p); end = p[0] + ssz
            if sub == 1:
                for _ in range(uleb_at(b, p)):
                    i = uleb_at(b, p); ln = uleb_at(b, p); names[i] = b[p[0]:p[0]+ln].decode(errors='replace'); p[0] += ln
            p[0] = end
    return names
def active_elems(b):
    """[(offset, [function indices])] for active funcref segments with i32.const offsets"""
    out = []
    for sid, s, e in sections(b):
        if sid != 9: continue
        p = [s]
        for _ in range(uleb_at(b, p)):
            flags = uleb_at(b, p)
            if flags in (0, 2):
                if flags == 2: uleb_at(b, p)
                op = b[p[0]]; p[0] += 1
                assert op == 0x41, 'elem offset not i32.const'
                off = sleb_at(b, p); assert b[p[0]] == 0x0b; p[0] += 1
                if flags == 2: assert b[p[0]] == 0; p[0] += 1
                out.append((off, [uleb_at(b, p) for _ in range(uleb_at(b, p))]))
            elif flags in (4, 6):
                if flags == 6: uleb_at(b, p)
                op = b[p[0]]; p[0] += 1
                assert op == 0x41, 'elem offset not i32.const'
                off = sleb_at(b, p); assert b[p[0]] == 0x0b; p[0] += 1
                if flags == 6: p[0] += 1  # reftype
                funcs = []
                for _ in range(uleb_at(b, p)):
                    op = b[p[0]]; p[0] += 1
                    if op == 0xd2: funcs.append(uleb_at(b, p))
                    elif op == 0xd0: p[0] += 1; funcs.append(None)
                    else: raise SystemExit(f'elem expression {op:#x}')
                    assert b[p[0]] == 0x0b; p[0] += 1
                out.append((off, funcs))
            else:
                raise SystemExit(f'elem flags {flags} not handled')
    return out
def table_min(b):
    for sid, s, e in sections(b):
        if sid == 4:
            p = [s]; uleb_at(b, p); p[0] += 1; flags = uleb_at(b, p); return uleb_at(b, p)
