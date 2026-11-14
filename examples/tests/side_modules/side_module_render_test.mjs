// The Storybook's app as a side module over its runtime module renders, in
// V8 (Node), with the web's linker (wasm/libraries/swift_ui/runtime/
// side_modules.js), what its self-contained reactor renders, byte for byte:
// the first frame, then a tap on every first-frame tap target. As
// SideModuleRenderTests.swift does under WasmKit.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { WASI } from "node:wasi";
import { SideModuleLinker } from "./side_modules.js";

const here = dirname(fileURLToPath(import.meta.url));
const bytes = (name) => readFileSync(join(here, name));

// Each function import's result type, so imports nothing defines answer zero.
function resultTypes(module) {
  const b = new Uint8Array(module); let i = 8; const types = []; const out = {};
  const uleb = () => { let r = 0, s = 0, x; do { x = b[i++]; r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); return r; };
  const str = () => { const n = uleb(); const v = new TextDecoder().decode(b.subarray(i, i + n)); i += n; return v; };
  while (i < b.length) {
    const id = b[i++]; const size = uleb(); const end = i + size;
    if (id === 1) for (let n = uleb(); n > 0; n--) { i++; const p = uleb(); i += p; const r = uleb(); types.push(r ? b[i] : 0); i += r; }
    if (id === 2) for (let n = uleb(); n > 0; n--) {
      const key = str() + "." + str(); const kind = b[i++];
      if (kind === 0) out[key] = types[uleb()];
      else if (kind === 1) { i++; const f = uleb(); uleb(); if (f & 1) uleb(); }
      else if (kind === 2) { const f = uleb(); uleb(); if (f & 1) uleb(); }
      else if (kind === 3) i += 2; else uleb();
    }
    if (id > 2) break;
    i = end;
  }
  return out;
}

/** Launches `main` (and loads `side` over it) and drives it; the render stream. */
function drive(mainBytes, sideBytes) {
  const stream = [];
  let instance, linker;
  const memory = () => new Uint8Array(instance.exports.memory.buffer);
  const wasi = new WASI({ version: "preview1", args: ["app"], env: {}, returnOnExit: true });
  const imports = {
    wasi_snapshot_preview1: wasi.wasiImport,
    iso_hot: {
      render_tree: (p, n) => { for (const x of memory().subarray(p, p + n)) stream.push(x); },
      log: () => {}, epoch_millis: () => 1.7e12, schedule_render: () => {}, platform_command: () => {}, host_value: () => -1,
    },
    env: { __main_argc_argv: (a, b) => linker.function("__main_argc_argv")(a, b) },
  };
  const module = new WebAssembly.Module(mainBytes);
  const results = resultTypes(mainBytes);
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.kind === "function" && !imports[imp.module]?.[imp.name]) {
      const type = results[imp.module + "." + imp.name];
      (imports[imp.module] ??= {})[imp.name] = () => (type === 0x7e ? 0n : type ? 0 : undefined);
    }
  }
  instance = new WebAssembly.Instance(module, imports);
  wasi.initialize(instance);
  if (sideBytes) { linker = new SideModuleLinker(instance); linker.load(sideBytes); }
  const E = instance.exports;
  E.iso_hot_start(1024, 768);
  E.iso_hot_render();
  const ids = [];
  const ok = (c) => (c >= 48 && c <= 57) || c === 46 || (c >= 97 && c <= 122);
  for (let i = 0; i + 4 <= stream.length; i++) {
    if (stream[i] === 46 && stream[i + 1] === 116 && stream[i + 2] === 97 && stream[i + 3] === 112) {
      let start = i; while (start > 0 && ok(stream[start - 1])) start--;
      const id = String.fromCharCode(...stream.slice(start, i + 4)).replace(/^\.+/, "");
      if (id && !ids.includes(id)) ids.push(id);
    }
  }
  const encoder = new TextEncoder();
  for (const id of ids) {
    const idBytes = encoder.encode(id);
    const idPointer = E.iso_hot_alloc(idBytes.length);
    memory().set(idBytes, idPointer);
    const valuePointer = E.iso_hot_alloc(1);
    E.iso_hot_event(idPointer, idBytes.length, valuePointer, 0);
    E.iso_hot_render();
  }
  return { stream: Uint8Array.from(stream), taps: ids.length };
}

const reactor = drive(bytes("example_full.wasm"), null);
const linked = drive(bytes("storybook_runtime.wasm"), bytes("storybook_side.wasm"));
let failures = 0;
const check = (name, ok) => { if (!ok) failures++; console.log(`${ok ? "ok" : "FAIL"} ${name}`); };
check(`taps (${reactor.taps})`, reactor.taps > 50 && linked.taps === reactor.taps);
check(`stream length (${reactor.stream.length})`, linked.stream.length === reactor.stream.length);
check("streams byte for byte", Buffer.compare(Buffer.from(linked.stream), Buffer.from(reactor.stream)) === 0);
process.exit(failures ? 1 : 0);
