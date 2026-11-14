"""Runtime functions the feature calls whose time per call (V8 profile,
inclusive, called directly from feature code) is at least <min us>: worth
crossing into native code for. Usage: pick_routed.py <profile dir> <import_calls> <min us> <out>"""
import json, glob, collections, re, subprocess, sys
prof_dir, calls_p, minimum, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
calls = {l.split(' ', 1)[1]: int(l.split(' ', 1)[0]) for l in open(calls_p).read().splitlines() if ' ' in l}
prof = json.load(open(glob.glob(prof_dir + '/*.cpuprofile')[0]))
nodes = {n['id']: n for n in prof['nodes']}
parent = {c: n['id'] for n in prof['nodes'] for c in n.get('children', [])}
def is_feature(name):
    m = re.match(r'\$s(\d+)([A-Za-z_]+)', name)
    return bool(m) and m.group(2)[:int(m.group(1))] in ('Storybook', 'ExampleApplication')
self_t = collections.Counter()
for sid, d in zip(prof['samples'], prof['timeDeltas']): self_t[sid] += d
callee = collections.Counter()
for nid, t in self_t.items():
    chain = []; cur = nid
    while cur is not None:
        cf = nodes[cur]['callFrame']
        if cf['url'].startswith('wasm://'): chain.append(cf['functionName'])
        cur = parent.get(cur)
    k = next((i for i, n in enumerate(chain) if is_feature(n)), None)
    if k: callee[chain[k - 1]] += t
rows = []
for name, us in callee.items():
    n = calls.get(name)
    if n: rows.append((us / n, us, n, name))
rows.sort(reverse=True)
picked = [r for r in rows if r[0] >= minimum]
dem = subprocess.run(['xcrun', 'swift-demangle', '--simplified', '--compact'], input='\n'.join(r[3] for r in picked), capture_output=True, text=True).stdout.split('\n')
for (per, us, n, name), d in zip(picked, dem): print(f'{per:7.2f} us/call {us/1e3:6.1f} ms {n:7d} calls  {d[:90]}')
tot = sum(r[1] for r in rows); got = sum(r[1] for r in picked)
print(f'picked {len(picked)} of {len(rows)} profiled callees: {100*got/tot:.0f}% of the feature\'s callee time, {sum(r[2] for r in picked)} calls')
open(out, 'w').write('\n'.join(r[3] for r in picked) + '\n')
