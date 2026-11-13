"""Adds the runtime functions native code calls into the interpreter at least
<min> times (from MixedCheck2's COUNT output) to the native set.
Usage: grow_set.py <runtime.wasm, with names> <crossings> <slots.txt> <set in> <set out> <min>"""
import collections, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wasmtool import *
runtime_p, cross_p, slots_p, set_in, set_out, minimum = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
orig = open(runtime_p, 'rb').read()
names = function_names(orig)
first = {}
for i, n in sorted(names.items()): first.setdefault(n, i)
def binaryen_name(i): return names[i] if first[names[i]] == i else f'{names[i]}_{i}'
slot_fn = {off + k: f for off, fs in active_elems(orig) for k, f in enumerate(fs) if f is not None}
for l in open(slots_p):
    if l.strip(): s, f = map(int, l.split()); slot_fn[s] = f
current = set(open(set_in).read().split('\n')) - {''}
added = []; feature = 0
for line in open(cross_p):
    parts = line.split()
    if len(parts) != 3 or parts[1] != 'slot': continue
    c, s = int(parts[0]), int(parts[2])
    if c < minimum: continue
    f = slot_fn.get(s)
    if f is None: feature += c; continue
    n = binaryen_name(f)
    if n not in current: current.add(n); added.append((c, n))
open(set_out, 'w').write('\n'.join(sorted(current)) + '\n')
print(f'added {len(added)} functions ({sum(c for c, _ in added)} crossings); {feature} crossings into feature code; set now {len(current)}')
