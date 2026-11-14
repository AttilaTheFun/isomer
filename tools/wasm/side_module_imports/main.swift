// side_module_imports: the runtime-module symbols side modules import, as
// clang link flags (`-Wl,--export-if-defined=<name>`, one a line), for a
// runtime module that exports just what its features use
// (tools/wasm/side_modules.bzl's `wasm_runtime_module(exports_for = …)`).
// A runtime with every public symbol exported has more than the 100,000
// exports the WebAssembly JS API lets a browser or web view load.
//
//   side_module_imports <out.rsp> <side module.wasm>...
//
// Each `env` function or global a side module imports, and the symbol of
// each `GOT.mem` and `GOT.func` entry; not the memory, table, stack pointer
// and bases the loader binds. `--export-if-defined`: a symbol one side module
// takes from another (not the runtime's) is skipped by the link.

import Foundation
import IsomerWasmDylink

let arguments = CommandLine.arguments.dropFirst()
guard let output = arguments.first, arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: side_module_imports <out.rsp> <side module.wasm>...\n".utf8))
    exit(2)
}
let bound: Set<String> = ["memory", "__indirect_function_table", "__stack_pointer", "__memory_base", "__table_base"]
var names = Set<String>()
do {
    for path in arguments.dropFirst() {
        let description = try WasmSideModuleDescription(bytes: Array(try Data(contentsOf: URL(fileURLWithPath: path))))
        for item in description.imports {
            switch item.module {
            case "env" where !bound.contains(item.name): names.insert(item.name)
            case "GOT.mem", "GOT.func": names.insert(item.name)
            default: break
            }
        }
    }
    let flags = names.sorted().map { "-Wl,--export-if-defined=\($0)" }
    try (flags.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("side_module_imports: \(error)\n".utf8))
    exit(1)
}
