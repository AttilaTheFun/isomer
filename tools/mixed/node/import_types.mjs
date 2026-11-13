// Result type of each function import ("module.name" -> 'i32'|'i64'|'f32'|'f64'|null).
export function importResults(bytes) {
  const b = new Uint8Array(bytes); let i = 8; const types = []; const out = {};
  const uleb = () => { let r = 0, s = 0, x; do { x = b[i++]; r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); return r; };
  const str = () => { const n = uleb(); const v = new TextDecoder().decode(b.subarray(i, i + n)); i += n; return v; };
  const T = { 0x7f: 'i32', 0x7e: 'i64', 0x7d: 'f32', 0x7c: 'f64' };
  while (i < b.length) {
    const id = b[i++]; const size = uleb(); const end = i + size;
    if (id === 1) { for (let n = uleb(), k = 0; k < n; k++) { i++; const np = uleb(); i += np; const nr = uleb(); types.push(nr ? T[b[i]] : null); i += nr; } }
    if (id === 2) { for (let n = uleb(), k = 0; k < n; k++) { const m = str(), nm = str(); const kind = b[i++];
      if (kind === 0) out[m + '.' + nm] = types[uleb()]; else if (kind === 1) { i++; const f = uleb(); uleb(); if (f & 1) uleb(); } else if (kind === 2) { const f = uleb(); uleb(); if (f & 1) uleb(); } else if (kind === 3) { i += 2; } else uleb(); } }
    i = end;
  }
  return out;
}
