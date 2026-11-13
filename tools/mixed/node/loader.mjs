// Minimal wasm dynamic loader: one main module (a reactor exporting everything),
// then side modules (dylink.0) placed in its memory and table.
import fs from 'node:fs';
import { WASI } from 'node:wasi';
import { locrelOffsets } from './locrel_fix.mjs';
import { importResults } from './import_types.mjs';

function readLEB(bytes, pos) { let r = 0, s = 0, b; do { b = bytes[pos.i++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80); return r >>> 0; }
function dylinkInfo(mod) {
  const [sec] = WebAssembly.Module.customSections(mod, 'dylink.0');
  const bytes = new Uint8Array(sec); const pos = { i: 0 }; const info = {};
  while (pos.i < bytes.length) {
    const kind = bytes[pos.i++]; const size = readLEB(bytes, pos); const end = pos.i + size;
    if (kind === 1) { info.memSize = readLEB(bytes, pos); info.memAlign = readLEB(bytes, pos); info.tableSize = readLEB(bytes, pos); info.tableAlign = readLEB(bytes, pos); }
    pos.i = end;
  }
  return info;
}

export function loadMain(path) { return loadMainWith(path, {}); }
export function loadMainWith(path, extra) {
  const wasi = new WASI({ version: 'preview1', args: ['app'], env: {}, returnOnExit: true });
  const bytes = fs.readFileSync(path); const mod = new WebAssembly.Module(bytes); const results = importResults(bytes);
  const imports = { wasi_snapshot_preview1: wasi.wasiImport, ...extra };
  for (const imp of WebAssembly.Module.imports(mod)) if (!imports[imp.module]?.[imp.name]) {
    if (imp.kind !== 'function') throw new Error('main import ' + imp.module + '.' + imp.name);
    (imports[imp.module] ??= {})[imp.name] = (...a) => { if (process.env.STUB_LOG) console.log('[stub]', imp.module, imp.name, a); const r = results[imp.module + '.' + imp.name]; return r === 'i64' ? 0n : r ? 0 : undefined; };
  }
  const inst = new WebAssembly.Instance(mod, imports);
  wasi.initialize(inst);
  return inst;
}

export function loadSide(main, path) {
  const mod = new WebAssembly.Module(fs.readFileSync(path));
  const info = dylinkInfo(mod);
  const E = main.exports, table = E.__indirect_function_table;
  const align = 1 << info.memAlign;
  const memoryBase = info.memSize ? (E.aligned_alloc ? E.aligned_alloc(align, info.memSize) : E.malloc(info.memSize + align)) : 0;
  new Uint8Array(E.memory.buffer, memoryBase, info.memSize).fill(0);
  const tableBase = table.grow(info.tableSize);
  const funcSlot = new Map();
  const slotFor = (f) => { if (!funcSlot.has(f)) { const i = table.grow(1); table.set(i, f); funcSlot.set(f, i); } return funcSlot.get(f); };
  const i32 = (v, mutable = false) => new WebAssembly.Global({ value: 'i32', mutable }, v);
  const env = { memory: E.memory, __indirect_function_table: table, __memory_base: i32(memoryBase), __table_base: i32(tableBase), __stack_pointer: E.__stack_pointer };
  const gotMem = {}, gotFunc = {}, missing = [];
  for (const imp of WebAssembly.Module.imports(mod)) {
    if (imp.module === 'env' && imp.name in env) continue;
    const ex = E[imp.name];
    if (imp.module === 'env' && imp.kind === 'function') { if (typeof ex === 'function') env[imp.name] = ex; else missing.push(imp.name); }
    else if (imp.module === 'GOT.mem') { if (ex instanceof WebAssembly.Global) gotMem[imp.name] = i32(ex.value, true); else missing.push('GOT.mem ' + imp.name); }
    else if (imp.module === 'GOT.func') { if (typeof ex === 'function') gotFunc[imp.name] = i32(slotFor(ex), true); else missing.push('GOT.func ' + imp.name); }
    else if (imp.module === 'env' && imp.kind === 'global' && ex instanceof WebAssembly.Global) env[imp.name] = ex;
    else missing.push(`${imp.module}.${imp.name} (${imp.kind})`);
  }
  if (missing.length) throw new Error('unresolved: ' + missing.slice(0, 20).join(', ') + ` (${missing.length})`);
  const inst = new WebAssembly.Instance(mod, { env, 'GOT.mem': gotMem, 'GOT.func': gotFunc, wasi_snapshot_preview1: {} });
  inst.exports.__wasm_apply_data_relocs?.();
  // The unpatched wasm-ld's LOCREL slots (lld_wasm_pic_locrel.patch fixes the
  // linker): from a sidecar (split/locrel_from_map.py) or the module's own
  // reloc.DATA (--emit-relocs). A module from the patched wasm-ld has neither
  // and needs nothing.
  if (!process.env.NO_FIX) {
    const offsets = fs.existsSync(path + '.locrel.json') ? JSON.parse(fs.readFileSync(path + '.locrel.json')) : locrelOffsets(fs.readFileSync(path));
    const dv = new DataView(E.memory.buffer);
    for (const o of offsets) dv.setInt32(memoryBase + o, dv.getInt32(memoryBase + o, true) - memoryBase, true);
  }
  if (!process.env.NO_CTORS) inst.exports.__wasm_call_ctors?.();
  return { inst, memoryBase, tableBase, info };
}
