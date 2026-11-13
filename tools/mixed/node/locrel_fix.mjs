// Workaround for wasm-ld (Swift 6.4.2) adding __memory_base to Swift's relative
// pointers (R_WASM_MEMORY_ADDR_LOCREL_I32) in PIC data: given a side module
// linked with --emit-relocs, list the memory offsets of its LOCREL slots.
function uleb(b, p) { let r = 0, s = 0, x; do { x = b[p.i++]; r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); return r; }
function sleb(b, p) { let r = 0, s = 0, x; do { x = b[p.i++]; r |= (x & 0x7f) << s; s += 7; } while (x & 0x80); if (s < 32 && (x & 0x40)) r |= -1 << s; return r; }
const ADDEND = new Set([3, 4, 5, 8, 9, 11, 14, 15, 16, 17, 21, 23, 24, 25]);
export function locrelOffsets(bytes) {
  const b = new Uint8Array(bytes); const p = { i: 8 }; let dataStart = -1, relocData = null;
  while (p.i < b.length) {
    const id = b[p.i++]; const size = uleb(b, p); const start = p.i;
    if (id === 11) dataStart = start;
    if (id === 0) { const n = uleb(b, p); const name = new TextDecoder().decode(b.subarray(p.i, p.i + n)); p.i += n; if (name === 'reloc.DATA') relocData = { start: p.i, end: start + size }; }
    p.i = start + size;
  }
  // Segment layout: payload offset of each segment's bytes -> memory offset.
  const segs = []; { const q = { i: dataStart }; const n = uleb(b, q);
    for (let k = 0; k < n; k++) { const flags = uleb(b, q); let mem = 0;
      if (flags === 2) uleb(b, q);
      if (flags !== 1) { while (b[q.i] !== 0x0b) { const op = b[q.i++]; if (op === 0x41) mem = sleb(b, q); else if (op === 0x23) uleb(b, q); } q.i++; }
      const sz = uleb(b, q); segs.push({ off: q.i - dataStart, mem, sz }); q.i += sz; } }
  const out = []; const q = { i: relocData.start }; uleb(b, q); const count = uleb(b, q);
  for (let k = 0; k < count; k++) { const type = b[q.i++]; const off = uleb(b, q); uleb(b, q); if (ADDEND.has(type)) sleb(b, q);
    if (type !== 23) continue;
    const s = segs.find(s => off >= s.off && off < s.off + s.sz); out.push(s.mem + off - s.off); }
  return out;
}
