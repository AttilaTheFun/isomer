"""Maps every table slot of the split parts to the original module's function
index; writes the slots the split added. Usage: map_slots.py <original> <cold> <cold.symbols> <hot> <hot.symbols> <out>"""
import collections, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wasmtool import *
orig_p, cold_p, cold_s, hot_p, hot_s, out_p = sys.argv[1:7]
orig = open(orig_p, 'rb').read()
names = function_names(orig)
count = collections.Counter(names.values())
unique = {n: i for i, n in names.items() if count[n] == 1}
first = {}
for i, n in sorted(names.items()): first.setdefault(n, i)
def original(name):
    m = re.match(r'(.*)_(\d+)$', name)
    if m and names.get(int(m.group(2))) == m.group(1): return int(m.group(2))
    # Binaryen keeps the first function's plain name, suffixes the others.
    return unique.get(name, first.get(name))
orig_slots = {off + k: f for off, fs in active_elems(orig) for k, f in enumerate(fs) if f is not None}
out = []; kept = moved = missing = 0
for part, sym_p in ((cold_p, cold_s), (hot_p, hot_s)):
    sym = {int(l.split(':', 1)[0]): l.split(':', 1)[1] for l in open(sym_p).read().splitlines() if ':' in l}
    for off, fs in active_elems(open(part, 'rb').read()):
        for k, f in enumerate(fs):
            if f is None: continue
            slot = off + k; oi = original(sym.get(f, ''))
            if oi is None: missing += 1; continue
            if slot in orig_slots:
                kept += 1; moved += orig_slots[slot] != oi
            else:
                out.append(f'{slot} {oi}')
print(f'original table {table_min(orig)}; {kept} slots kept ({moved} with another function), {len(out)} added, {missing} unmapped')
open(out_p, 'w').write('\n'.join(out) + '\n')
