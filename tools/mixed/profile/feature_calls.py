"""Within samples that have a feature frame on the stack: the feature's own
time vs the runtime functions it calls, by inclusive time (V8 profile)."""
import json, glob, collections, re, subprocess, sys
prof = json.load(open(glob.glob(sys.argv[1] + '/*.cpuprofile')[0]))
nodes = {n['id']: n for n in prof['nodes']}
parent = {c: n['id'] for n in prof['nodes'] for c in n.get('children', [])}
def is_feature(name):
    m = re.match(r'\$s(\d+)([A-Za-z_]+)', name)
    return bool(m) and m.group(2)[:int(m.group(1))] in ('Storybook', 'ExampleApplication')
self_t = collections.Counter()
for sid, d in zip(prof['samples'], prof['timeDeltas']): self_t[sid] += d
inside = feature_self = 0
callee = collections.Counter()
for nid, t in self_t.items():
    if not nodes[nid]['callFrame']['url'].startswith('wasm://'): continue
    chain = []; cur = nid
    while cur is not None:
        cf = nodes[cur]['callFrame']
        if cf['url'].startswith('wasm://'): chain.append(cf['functionName'])
        cur = parent.get(cur)
    # chain[0] is the leaf; find the innermost feature frame.
    k = next((i for i, n in enumerate(chain) if is_feature(n)), None)
    if k is None: continue
    inside += t
    if k == 0: feature_self += t
    else: callee[chain[k - 1]] += t   # the runtime function the feature called
print(f'feature on stack: {inside/1e3:.0f} ms; feature code itself {100*feature_self/inside:.0f}%, runtime functions it calls {100*(inside-feature_self)/inside:.0f}%')
names = [n for n, _ in callee.most_common(25)]
dem = subprocess.run(['xcrun', 'swift-demangle', '--simplified', '--compact'], input='\n'.join(names), capture_output=True, text=True).stdout.split('\n')
for (n, t), d in zip(callee.most_common(25), dem): print(f'{100*t/inside:5.1f}%  {d[:120]}')
