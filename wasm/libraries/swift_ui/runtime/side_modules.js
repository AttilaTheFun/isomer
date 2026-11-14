// Side modules for a JavaScript engine (a browser, a web view, Node): a
// feature linked as a WebAssembly side module (wasm-ld `--experimental-pic
// -shared`, a `dylink.0` section) loaded into a runtime module's memory and
// table. The twin of IsomerWasmDylink (shared/wasm_host/dylink), which
// native engines use; tests/wasm_dylink holds both to the same modules.
//
//   const linker = new SideModuleLinker(runtimeInstance);
//   const { instance } = linker.load(featureBytes);
//
// The conventions (the WebAssembly tool conventions' DynamicLinking.md):
// the side module's memory comes from the runtime's allocator
// (`aligned_alloc`, else `malloc`), zeroed; its table slots go at the
// table's end, aligned; `env.memory`, `env.__indirect_function_table`,
// `env.__stack_pointer` are the runtime's; other `env` imports are symbols
// the runtime or an earlier side module exports (the runtime's first);
// `GOT.mem.x` holds a data symbol's address, `GOT.func.x` a function's
// table slot (one per function). After instantiating, the loader runs
// `__wasm_apply_data_relocs`, then `__wasm_call_ctors`.

/** Why a side module couldn't be loaded: `kind` as IsomerWasmDylink's WasmLinkError. */
export class SideModuleError extends Error {
  constructor(kind, detail) {
    super(`${kind}: ${Array.isArray(detail) ? detail.join(", ") : detail}`);
    this.kind = kind;
    this.detail = detail;
  }
}

/** Reads a `dylink.0` section's contents (after its name). */
export function parseDylink(bytes) {
  let position = 0;
  const end = bytes.length;
  const byte = (limit) => {
    if (position >= limit) throw new SideModuleError("malformedDylink", "truncated");
    return bytes[position++];
  };
  const u32 = (limit) => {
    let result = 0, shift = 0;
    for (;;) {
      const b = byte(limit);
      result += (b & 0x7f) * 2 ** shift;
      if (result > 0xffffffff) throw new SideModuleError("malformedDylink", "LEB128 out of range");
      if (!(b & 0x80)) return result;
      shift += 7;
      if (shift >= 35) throw new SideModuleError("malformedDylink", "LEB128 too long");
    }
  };
  const info = { memorySize: 0, memoryAlignment: 0, tableSize: 0, tableAlignment: 0, neededLibraries: [] };
  while (position < end) {
    const kind = byte(end);
    const size = u32(end);
    if (size > end - position) throw new SideModuleError("malformedDylink", "subsection past the end");
    const subEnd = position + size;
    if (kind === 1) {
      info.memorySize = u32(subEnd);
      info.memoryAlignment = u32(subEnd);
      info.tableSize = u32(subEnd);
      info.tableAlignment = u32(subEnd);
    } else if (kind === 2) {
      for (let n = u32(subEnd); n > 0; n--) {
        const length = u32(subEnd);
        if (length > subEnd - position) throw new SideModuleError("malformedDylink", "truncated");
        info.neededLibraries.push(new TextDecoder().decode(bytes.subarray(position, position + length)));
        position += length;
      }
    }
    position = subEnd;
  }
  if (info.memoryAlignment >= 32) throw new SideModuleError("outOfRange", `memory alignment 2^${info.memoryAlignment}`);
  if (info.tableAlignment >= 32) throw new SideModuleError("outOfRange", `table alignment 2^${info.tableAlignment}`);
  return info;
}

/** A compiled module's `dylink.0`. */
export function dylinkInfo(module) {
  const [section] = WebAssembly.Module.customSections(module, "dylink.0");
  if (!section) throw new SideModuleError("notASideModule", "no dylink.0 section (link with wasm-ld --experimental-pic -shared)");
  return parseDylink(new Uint8Array(section));
}

/** Loads side modules into a main (runtime) module's instance. */
export class SideModuleLinker {
  /** `main`: an instance (or anything with `exports`), its `_initialize` run. */
  constructor(main) {
    const exports = main.exports;
    for (const [name, hint] of [["memory", ""], ["__indirect_function_table", " (link it with --export-table)"], ["__stack_pointer", " (link it with --export=__stack_pointer)"]]) {
      if (!exports[name]) throw new SideModuleError("missingMainExport", name + hint);
    }
    if (!exports.aligned_alloc && !exports.malloc) throw new SideModuleError("missingMainExport", "aligned_alloc or malloc");
    this.main = exports;
    this.memory = exports.memory;
    this.table = exports.__indirect_function_table;
    /** Each loaded side module: `{ instance, info, memoryBase, tableBase }`. */
    this.loaded = [];
    this.functionSlots = new Map();
  }

  allocate(size, alignment) {
    // malloc's own alignment (16 in wasi-libc) is enough for what wasm-ld
    // asks of a side module's data, up to 16.
    return (this.main.aligned_alloc ? this.main.aligned_alloc(alignment, size) : this.main.malloc(size)) >>> 0;
  }

  /** A function the main module or a side module exports, the main module's first. */
  function(name) {
    if (typeof this.main[name] === "function") return this.main[name];
    for (const { instance } of this.loaded) {
      if (typeof instance.exports[name] === "function") return instance.exports[name];
    }
    return null;
  }

  global(name) {
    if (this.main[name] instanceof WebAssembly.Global) return this.main[name];
    for (const { instance } of this.loaded) {
      if (instance.exports[name] instanceof WebAssembly.Global) return instance.exports[name];
    }
    return null;
  }

  functionSlot(name) {
    if (this.functionSlots.has(name)) return this.functionSlots.get(name);
    const f = this.function(name);
    if (!f) return null;
    const slot = this.table.grow(1);
    this.table.set(slot, f);
    this.functionSlots.set(name, slot);
    return slot;
  }

  /** Places `bytes` (a side module, or a compiled WebAssembly.Module), instantiates it, relocates its data and runs its constructors. */
  load(bytes) {
    let module = bytes;
    if (!(bytes instanceof WebAssembly.Module)) {
      try {
        module = new WebAssembly.Module(bytes);
      } catch (error) {
        throw new SideModuleError("malformedModule", error.message);
      }
    }
    const info = dylinkInfo(module);

    let memoryBase = 0;
    if (info.memorySize > 0) {
      memoryBase = this.allocate(info.memorySize, 2 ** info.memoryAlignment);
      if (memoryBase === 0) throw new SideModuleError("allocationFailed", `${info.memorySize} bytes`);
      if (memoryBase + info.memorySize > this.memory.buffer.byteLength) {
        throw new SideModuleError("allocationOutOfBounds", `${info.memorySize} bytes at ${memoryBase}`);
      }
      new Uint8Array(this.memory.buffer, memoryBase, info.memorySize).fill(0);
    }

    const alignment = 2 ** info.tableAlignment;
    const count = this.table.length;
    const padding = (alignment - (count % alignment)) % alignment;
    if (count + padding + info.tableSize > 0xffffffff) throw new SideModuleError("outOfRange", `${info.tableSize} table slots after ${count}`);
    const tableBase = this.table.grow(padding + info.tableSize) + padding;

    const constant = (value) => new WebAssembly.Global({ value: "i32", mutable: false }, value);
    const got = (value) => new WebAssembly.Global({ value: "i32", mutable: true }, value);
    const env = {}, gotMem = {}, gotFunc = {}, unresolved = [];
    const expect = (ok, item) => {
      if (!ok) throw new SideModuleError("wrongImportKind", `${item.module}.${item.name}`);
    };
    for (const item of WebAssembly.Module.imports(module)) {
      const key = `${item.module}.${item.name}`;
      if (key === "env.memory") { expect(item.kind === "memory", item); env.memory = this.memory; }
      else if (key === "env.__indirect_function_table") { expect(item.kind === "table", item); env.__indirect_function_table = this.table; }
      else if (key === "env.__stack_pointer") { expect(item.kind === "global", item); env.__stack_pointer = this.main.__stack_pointer; }
      else if (key === "env.__memory_base") { expect(item.kind === "global", item); env.__memory_base = constant(memoryBase); }
      else if (key === "env.__table_base") { expect(item.kind === "global", item); env.__table_base = constant(tableBase); }
      else if (item.module === "GOT.mem") {
        expect(item.kind === "global", item);
        const global = this.global(item.name);
        if (global) gotMem[item.name] = got(global.value >>> 0); else unresolved.push(`GOT.mem.${item.name}`);
      } else if (item.module === "GOT.func") {
        expect(item.kind === "global", item);
        const slot = this.functionSlot(item.name);
        if (slot !== null) gotFunc[item.name] = got(slot); else unresolved.push(`GOT.func.${item.name}`);
      } else if (item.module === "env" && item.kind === "function") {
        const f = this.function(item.name);
        if (f) env[item.name] = f; else unresolved.push(item.name);
      } else if (item.module === "env" && item.kind === "global") {
        const global = this.global(item.name);
        if (global) env[item.name] = global; else unresolved.push(item.name);
      } else {
        unresolved.push(item.module === "env" ? item.name : key);
      }
    }
    if (unresolved.length) throw new SideModuleError("unresolved", unresolved);

    const instance = new WebAssembly.Instance(module, { env, "GOT.mem": gotMem, "GOT.func": gotFunc });
    const loaded = { instance, info, memoryBase, tableBase };
    this.loaded.push(loaded);
    instance.exports.__wasm_apply_data_relocs?.();
    instance.exports.__wasm_call_ctors?.();
    return loaded;
  }
}
