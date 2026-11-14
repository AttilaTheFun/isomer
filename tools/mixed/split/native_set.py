"""The native set: every runtime function on a profiled stack, plus direct
callees, to a depth. Prints sizes; writes the set to <out>.
Usage: native_set.py <profile dir> <callgraph.dot> <named runtime.wasm> <depth> <out>"""
import collections, glob, json, os, re, sys
prof_dir, dot, wasm, depth, out = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
sys.argv = [sys.argv[0], prof_dir, wasm]
# Function sizes and names from the runtime (hot_coverage.py's reader).
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'profile', 'hot_coverage.py')).read().split('total_code = sum(sizes)')[0]
exec(src)
runtime = set(names)
prof = json.load(open(glob.glob(prof_dir + '/*.cpuprofile')[0]))
nodes = {n['id']: n for n in prof['nodes']}
parent = {c: n['id'] for n in prof['nodes'] for c in n.get('children', [])}
on_stack = set()
for sid in set(prof['samples']):
    cur = sid
    while cur is not None:
        cf = nodes[cur]['callFrame']
        if cf['url'].startswith('wasm://') and cf['functionName'] in runtime: on_stack.add(cf['functionName'])
        cur = parent.get(cur)
callees = collections.defaultdict(set)
for line in open(dot):
    m = re.match(r'\s*"(.*?)" -> "(.*?)"; // call', line)
    if m: callees[m.group(1)].add(m.group(2))
def size(fs): return sum(sizes[names[f] - imports] for f in fs if f in names)
total = sum(sizes)
s = set(on_stack)
print(f'on profiled stacks: {len(s)} functions, {size(s)/1e3:.0f} KB ({100*size(s)/total:.1f}% of {total/1e6:.1f} MB)')
frontier = set(s)
for d in range(1, depth + 1):
    frontier = {c for f in frontier for c in callees.get(f, ()) if c in runtime} - s
    s |= frontier
    print(f'+ callees, depth {d}: {len(s)} functions, {size(s)/1e3:.0f} KB ({100*size(s)/total:.1f}%)')
open(out, 'w').write('\n'.join(sorted(s)) + '\n')
