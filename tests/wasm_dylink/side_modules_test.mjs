// The web's side-module linker (wasm/libraries/swift_ui/runtime/
// side_modules.js) in Node, on the same modules WasmDylinkTests.swift loads
// with WasmKit (fixtures/WasmFixtures.swift): the same placement, bindings,
// relocations, constructors and refusals.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SideModuleError, SideModuleLinker, parseDylink } from "./side_modules.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = (name) => readFileSync(join(here, name));

let failures = 0;
function check(name, found, expected) {
  const ok = JSON.stringify(found) === JSON.stringify(expected);
  if (!ok) failures += 1;
  console.log(ok ? `ok ${name}` : `FAIL ${name}: ${JSON.stringify(found)}, expected ${JSON.stringify(expected)}`);
}
function refuses(name, work, kind) {
  try {
    work();
    check(name, "loaded", kind);
  } catch (error) {
    // An engine's own error (instantiation) by its type: messages differ by engine.
    check(name, error instanceof SideModuleError ? error.kind : error.constructor.name, kind);
  }
}

const MAIN_DATA = 1024, HEAP = 4096;
function fresh() {
  const main = new WebAssembly.Instance(new WebAssembly.Module(fixture("main.wasm")), {});
  const linker = new SideModuleLinker(main);
  const word = (address) => new DataView(main.exports.memory.buffer).getUint32(address, true);
  const bytes = (address, count) => [...new Uint8Array(main.exports.memory.buffer, address, count)];
  const slot = (index, argument) => main.exports.__indirect_function_table.get(index)(argument);
  return { main, linker, word, bytes, slot };
}

// dylink.0 itself.
check("reads dylink.0", parseDylink(new Uint8Array([1, 4, 64, 4, 2, 2])), { memorySize: 64, memoryAlignment: 4, tableSize: 2, tableAlignment: 2, neededLibraries: [] });
refuses("truncated subsection", () => parseDylink(new Uint8Array([1, 5, 0x40])), "malformedDylink");
refuses("overlong LEB", () => parseDylink(new Uint8Array([1, 6, 0x80, 0x80, 0x80, 0x80, 0x80, 1])), "malformedDylink");

// A side module placed, relocated and constructed.
{
  const { linker, word, bytes, slot, main } = fresh();
  const a = linker.load(fixture("side_a.wasm"));
  check("memory aligned to 16", a.memoryBase % 16, 0);
  check("memory from the heap", a.memoryBase >= HEAP, true);
  check("table base aligned", a.tableBase, 4);
  check("its slots", [slot(4, 5), slot(5, 0)], [106, 101]);
  check("its data", bytes(a.memoryBase + 32, 4), [..."SIDE"].map((c) => c.charCodeAt(0)));
  check("relocation: its own address", word(a.memoryBase + 8), a.memoryBase + 16);
  check("relocation: GOT.mem", word(a.memoryBase + 12), MAIN_DATA);
  check("relocation: GOT.func", word(a.memoryBase + 20), 6);
  check("GOT.func slot calls the main module", slot(6, 1), 101);
  check("constructor ran", word(a.memoryBase), 42);
  check("table count", main.exports.__indirect_function_table.length, 7);

  // A second binds the first's symbols.
  const b = linker.load(fixture("side_b.wasm"));
  check("second: side_f(1) through the first", word(b.memoryBase), 102);
  check("second: GOT.mem of the first's data", word(b.memoryBase + 4), a.memoryBase);
  check("second: GOT.func slot", word(b.memoryBase + 8), 7);
  check("second: that slot", slot(7, 2), 103);
  check("loaded", linker.loaded.length, 2);
}

// Its memory zeroed, whatever was there.
{
  const { main, linker, bytes } = fresh();
  new Uint8Array(main.exports.memory.buffer, HEAP, 64).fill(0xab);
  const a = linker.load(fixture("side_a.wasm"));
  check("zeroed", bytes(a.memoryBase + 36, 28), new Array(28).fill(0));
}

// Refusals, with nothing half-loaded left.
{
  const { linker, main } = fresh();
  refuses("not a side module", () => linker.load(fixture("main.wasm")), "notASideModule");
  refuses("wrong import kind", () => linker.load(fixture("wrong_kind.wasm")), "wrongImportKind");
  try {
    linker.load(fixture("unresolved.wasm"));
    check("unresolved", "loaded", "unresolved");
  } catch (error) {
    check("unresolved, every one", error.detail, ["nowhere", "GOT.mem.no_data", "GOT.func.no_function", "elsewhere.thing"]);
  }
  refuses("truncated dylink.0", () => linker.load(fixture("truncated_dylink.wasm")), "malformedDylink");
  refuses("alignment out of range", () => linker.load(fixture("huge_alignment.wasm")), "outOfRange");
  refuses("truncated module", () => linker.load(fixture("side_a.wasm").subarray(0, 30)), "malformedModule");
  const before = main.exports.__indirect_function_table.length;
  refuses("elements past its slots", () => linker.load(fixture("overlong_elements.wasm")), "RuntimeError");
  check("nothing past its slot", main.exports.__indirect_function_table.length, before + 1);
  check("none loaded", linker.loaded.length, 0);
}

process.exit(failures ? 1 : 0);
