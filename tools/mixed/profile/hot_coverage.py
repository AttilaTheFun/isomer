import json, sys, glob, collections
# Function body sizes and names from the unstripped runtime module.
b = open(sys.argv[2], 'rb').read()
def uleb(p):
    r = s = 0
    while True:
        x = b[p[0]]; p[0] += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return r
p = [8]; imports = 0; sizes = []; names = {}
while p[0] < len(b):
    sid = b[p[0]]; p[0] += 1; size = uleb(p); start = p[0]
    if sid == 2:
        for _ in range(uleb(p)):
            for _ in range(2): n = uleb(p); p[0] += n
            kind = b[p[0]]; p[0] += 1
            if kind == 0: uleb(p); imports += 1
            elif kind == 1: p[0] += 1; f = uleb(p); uleb(p); (uleb(p) if f & 1 else None)
            elif kind == 2: f = uleb(p); uleb(p); (uleb(p) if f & 1 else None)
            elif kind == 3: p[0] += 2
    if sid == 10:
        for _ in range(uleb(p)): n = uleb(p); sizes.append(n); p[0] += n
    if sid == 0:
        n = uleb(p); nm = b[p[0]:p[0]+n]; p[0] += n
        if nm == b'name':
            while p[0] < start + size:
                sub = b[p[0]]; p[0] += 1; ssz = uleb(p); e = p[0] + ssz
                if sub == 1:
                    for _ in range(uleb(p)):
                        i = uleb(p); ln = uleb(p); names[b[p[0]:p[0]+ln].decode(errors='replace')] = i; p[0] += ln
                p[0] = e
    p[0] = start + size
total_code = sum(sizes)
prof = json.load(open(glob.glob(sys.argv[1] + '/*.cpuprofile')[0]))
nodes = {n['id']: n for n in prof['nodes']}
t = collections.Counter()
for sid, d in zip(prof['samples'], prof['timeDeltas']):
    cf = nodes[sid]['callFrame']
    if cf['url'].startswith('wasm://') and cf['functionName'] in names: t[cf['functionName']] += d
tot = sum(t.values()); acc = 0; code = 0; marks = [0.5, 0.8, 0.9, 0.95, 0.99, 1.0]
print(f"runtime: {len(sizes)} functions, {total_code/1e6:.1f} MB of code; profiled runtime functions: {len(t)}")
for k, (n, v) in enumerate(t.most_common(), 1):
    acc += v; code += sizes[names[n] - imports]
    while marks and acc / tot >= marks[0] - 1e-9:
        print(f"{100*marks[0]:5.0f}% of runtime time: {k:6d} functions, {code/1e3:8.0f} KB of wasm code ({100*code/total_code:4.1f}% of the module)")
        marks.pop(0)
