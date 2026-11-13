import json, sys, glob, collections, re
p = json.load(open(glob.glob(sys.argv[1] + '/*.cpuprofile')[0]))
nodes = {n['id']: n for n in p['nodes']}
self_t = collections.Counter()
dt = dict(zip(p['samples'], p['timeDeltas']))
for sid, d in zip(p['samples'], p['timeDeltas']):
    self_t[sid] += d
def module(name, url):
    if not url.startswith('wasm://'): return 'JS/host'
    if name.startswith('$s7SwiftUI') or name.startswith('$s7SwiftUI'): return 'SwiftUI core'
    m = re.match(r'\$s(\d+)([A-Za-z_]+)', name)
    if name.startswith('$ss') or name.startswith('$sS') or name.startswith('swift_') or name.startswith('_swift'): return 'Swift stdlib/runtime'
    if m:
        mod = m.group(2)[:int(m.group(1))]
        return {'SwiftUI': 'SwiftUI core', 'FoundationEssentials': 'Foundation', 'Foundation': 'Foundation', 'SwiftProtobuf': 'SwiftProtobuf', 'IsomerSwiftUI': 'SwiftUI core', 'Storybook': 'feature (Storybook)', 'ExampleApplication': 'feature (Storybook)'}.get(mod, mod)
    if name in ('malloc', 'free', 'dlmalloc', 'dlfree', 'memcpy', 'memmove', 'memset', 'aligned_alloc', 'realloc') or name.startswith('__') : return 'libc (malloc/mem*)'
    return 'other wasm: ' + name[:30]
by = collections.Counter(); fns = collections.Counter()
for nid, t in self_t.items():
    cf = nodes[nid]['callFrame']; name = cf['functionName']; url = cf['url']
    if name in ('(idle)', '(program)', '(garbage collector)', '(root)'): continue
    mod = module(name, url)
    by[mod] += t; fns[(mod, name)] += t
tot = sum(by.values())
for m, t in by.most_common(14): print(f"{100*t/tot:5.1f}%  {m}")
print('--- top functions')
for (m, n), t in fns.most_common(18): print(f"{100*t/tot:5.1f}%  {m:22s} {n[:90]}")

print('--- wasm time attributed to the nearest SwiftUI-core or feature frame above it')
parent = {}
for n in p['nodes']:
    for c in n.get('children', []): parent[c] = n['id']
owner = collections.Counter()
for nid, t in self_t.items():
    cf = nodes[nid]['callFrame']
    if not cf['url'].startswith('wasm://'): continue
    cur = nid; who = None
    while cur is not None:
        c = nodes[cur]['callFrame']
        if c['url'].startswith('wasm://'):
            m = module(c['functionName'], c['url'])
            if m in ('SwiftUI core', 'feature (Storybook)'): who = m; break
        cur = parent.get(cur)
    owner[who or 'neither (entry/runtime glue)'] += t
tw = sum(owner.values())
for k, t in owner.most_common(): print(f"{100*t/tw:5.1f}%  {k}")

print('--- wasm time by whether a feature frame is anywhere on the stack')
split = collections.Counter()
for nid, t in self_t.items():
    if not nodes[nid]['callFrame']['url'].startswith('wasm://'): continue
    cur = nid; inside = False
    while cur is not None:
        c = nodes[cur]['callFrame']
        if c['url'].startswith('wasm://') and module(c['functionName'], c['url']) == 'feature (Storybook)': inside = True; break
        cur = parent.get(cur)
    split['inside feature code (body, closures, inits)' if inside else 'core machinery (resolve, state, diff, encode)'] += t
tw = sum(split.values())
for k, t in split.most_common(): print(f"{100*t/tw:5.1f}%  {k}")

print('--- inclusive wasm time of SwiftUI-core functions (no feature frame below them on the path), top 30')
incl = collections.Counter()
for nid, t in self_t.items():
    if not nodes[nid]['callFrame']['url'].startswith('wasm://'): continue
    seen = set(); cur = nid
    while cur is not None:
        c = nodes[cur]['callFrame']; nm = c['functionName']
        if c['url'].startswith('wasm://') and module(nm, c['url']) == 'SwiftUI core' and nm not in seen:
            seen.add(nm); incl[nm] += t
        cur = parent.get(cur)
tw = sum(t for nid, t in self_t.items() if nodes[nid]['callFrame']['url'].startswith('wasm://'))
import subprocess
names = [n for n, _ in incl.most_common(40)]
try:
    dem = subprocess.run(['xcrun', 'swift-demangle', '--simplified', '--compact'], input='\n'.join(names), capture_output=True, text=True).stdout.split('\n')
except Exception: dem = names
for (n, t), d in zip(incl.most_common(40), dem): print(f"{100*t/tw:5.1f}%  {d[:150]}")
