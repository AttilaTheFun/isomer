"""Lists the memory offsets of R_WASM_MEMORY_ADDR_LOCREL_I32 slots in a wasm-ld
-shared output, from its -Map file and the input objects (archives' members).
Usage: locrel_from_map.py <map> <archive-or-object>... > offsets.json"""
import json, re, subprocess, sys, tempfile, os

def uleb(b, p):
    r = s = 0
    while True:
        x = b[p[0]]; p[0] += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return r
def sleb(b, p):
    r = s = 0
    while True:
        x = b[p[0]]; p[0] += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80:
            if x & 0x40: r -= 1 << s
            return r
ADDEND = {3, 4, 5, 8, 9, 11, 14, 15, 16, 17, 21, 23, 24, 25}

def parse_object(b):
    p = [8]; sections = []; data_start = None; data_index = None; reloc_data = None; seg_names = []
    idx = 0
    while p[0] < len(b):
        sid = b[p[0]]; p[0] += 1; size = uleb(b, p); start = p[0]
        if sid == 11: data_start, data_index = start, idx
        if sid == 0:
            n = uleb(b, p); name = b[p[0]:p[0]+n].decode(); p[0] += n
            if name == 'linking':
                q = [p[0]]; uleb(b, q)
                while q[0] < start + size:
                    t = b[q[0]]; q[0] += 1; sz = uleb(b, q); e = q[0] + sz
                    if t == 5:
                        for _ in range(uleb(b, q)):
                            ln = uleb(b, q); seg_names.append(b[q[0]:q[0]+ln].decode()); q[0] += ln; uleb(b, q); uleb(b, q)
                    q[0] = e
            elif name.startswith('reloc.'):
                q = [p[0]]; target = uleb(b, q)
                reloc_data = reloc_data if target != data_index else (q[0], start + size)
        p[0] = start + size; idx += 1
    if data_start is None: return []
    segs = []; q = [data_start]
    for k in range(uleb(b, q)):
        flags = uleb(b, q)
        if flags == 2: uleb(b, q)
        if flags != 1:
            while b[q[0]] != 0x0b:
                op = b[q[0]]; q[0] += 1
                if op == 0x41: sleb(b, q)
                elif op == 0x23: uleb(b, q)
            q[0] += 1
        sz = uleb(b, q); segs.append((q[0] - data_start, sz, seg_names[k])); q[0] += sz
    out = []
    if reloc_data:
        q = [reloc_data[0]]
        for _ in range(uleb(b, q)):
            t = b[q[0]]; q[0] += 1; off = uleb(b, q); uleb(b, q)
            if t in ADDEND: sleb(b, q)
            if t != 23: continue
            for k, (so, sz, nm) in enumerate(segs):
                if so <= off < so + sz: out.append((k, nm, off - so)); break
    rank = {}
    names = [nm for _, _, nm in segs]
    out = [(k, nm, within, names[:k].count(nm)) for k, nm, within in out]
    return out

mapfile, inputs = sys.argv[1], sys.argv[2:]
# Map lines: "<VA> <LMA> <size>  <file>(<member>):(<segment>)" under DATA.
placed = {}
in_data = False
for line in open(mapfile):
    if re.search(r'\bDATA$', line.strip()): in_data = True; continue
    if in_data and re.match(r'\s+-\s', line) : in_data = False
    m = re.match(r'\s*([0-9a-f]+)\s+[0-9a-f]+\s+[0-9a-f]+\s+(.*):\((.*)\)\s*$', line)
    if in_data and m:
        placed.setdefault((m.group(2), m.group(3)), []).append(int(m.group(1), 16))
result = []
tmp = tempfile.mkdtemp()
for path in inputs:
    members = []
    if path.endswith('.a'):
        d = os.path.join(tmp, str(len(os.listdir(tmp)))); os.makedirs(d)
        subprocess.run([os.environ['LLVM_AR'], 'x', path], cwd=d, check=True)
        names = subprocess.run([os.environ['LLVM_AR'], 't', path], capture_output=True, text=True).stdout.split()
        members = [(f'{path}({n})', os.path.join(d, n)) for n in names]
    else:
        members = [(path, path)]
    for label, file in members:
        for k, nm, within, rank in parse_object(open(file, 'rb').read()):
            vas = placed.get((label, nm))
            result.append(vas[rank] + within if vas and rank < len(vas) else None)
            if result[-1] is None and os.environ.get("DEBUG"): print("UNPLACED", label.split("/")[-1], nm, rank, len(vas or []), file=sys.stderr)
missing = sum(r is None for r in result)
print(json.dumps(sorted(r for r in result if r is not None)))
print(f'{len(result)} LOCREL slots, {missing} unplaced', file=sys.stderr)
