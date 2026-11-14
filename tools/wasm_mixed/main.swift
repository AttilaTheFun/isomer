import Foundation

// wasm_mixed: the generator of mixed mode's native part (docs/side_modules.md):
// a runtime module interpreted by WasmKit, with native copies (wasm2c) of a
// set of its hot functions compiled into the host. Each step is a
// subcommand, and `generate` runs them all with Binaryen and WABT.

let usage = """
    usage: wasm_mixed <command> ...

      slim <in.wasm> <out.wasm> <keep>
          the module with only the exports <keep> names and its data
          segments emptied (<keep>: names separated by commas; @<file> for a
          file of names)
      map-slots <runtime.wasm> <cold.wasm> <cold.symbols> <hot_full.wasm> <hot_full.symbols> <out slots.txt>
          the table slots wasm-split added, as the runtime's function indices
      bridge <hot.wasm> <hot.h> <out dir>
          mixed_glue.c, mixed_glue.h and shim.wat for wasm2c's hot.h
      generate --wasm-split <path> --wasm2c <path> --wat2wasm <path>
               --runtime <runtime.wasm> --set <set.txt> --entries <keep> --out <dir>
               [--wasi-run <wasi_run>]
          all of it: hot_0.c … hot_7.c, hot.h, hot-impl.h, mixed_glue.c,
          mixed_glue.h, shim.wasm and slots.txt in <dir>. The runtime must
          have its name section; <keep> is the entry points and the routed
          functions.

    """

func fail(_ message: String) -> Never {
    fflush(nil)  // what was printed before the error, first
    FileHandle.standardError.write(Data("wasm_mixed: \(message)\n".utf8))
    exit(1)
}

func positional(_ args: ArraySlice<String>, _ count: Int, _ command: String) -> [String] {
    guard args.count == count else {
        fail("\(command) takes \(count) arguments, not \(args.count)\n\n\(usage)")
    }
    return Array(args)
}

func generateOptions(_ args: ArraySlice<String>) -> Generate.Options {
    var options = Generate.Options()
    let fields: [String: WritableKeyPath<Generate.Options, String>] = [
        "--wasm-split": \.wasmSplit, "--wasm2c": \.wasm2c, "--wat2wasm": \.wat2wasm,
        "--runtime": \.runtime, "--set": \.set, "--entries": \.entries, "--out": \.out,
        "--wasi-run": \.wasiRun,
    ]
    var seen: Set<String> = []
    var rest = args[...]
    while let arg = rest.popFirst() {
        var flag = arg
        var value: String?
        if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
            flag = String(arg[..<eq])
            value = String(arg[arg.index(after: eq)...])
        }
        guard let field = fields[flag] else { fail("generate: unknown argument \(arg)\n\n\(usage)") }
        if value == nil { value = rest.popFirst() }
        guard let value else { fail("generate: \(flag) needs a value") }
        options[keyPath: field] = value
        seen.insert(flag)
    }
    let missing = fields.keys.filter { !seen.contains($0) && $0 != "--wasi-run" }.sorted()
    if !missing.isEmpty { fail("generate: missing \(missing.joined(separator: ", "))\n\n\(usage)") }
    return options
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    print(usage, terminator: "")
    exit(2)
}
let rest = arguments.dropFirst()
do {
    switch command {
    case "slim":
        let a = positional(rest, 3, command)
        try Slim.run(input: a[0], output: a[1], keep: a[2])
    case "map-slots":
        let a = positional(rest, 6, command)
        try MapSlots.run(runtime: a[0], cold: a[1], coldSymbols: a[2], hot: a[3], hotSymbols: a[4], output: a[5])
    case "bridge":
        let a = positional(rest, 3, command)
        try Bridge.run(hotWasm: a[0], hotHeader: a[1], outDir: a[2])
    case "generate":
        try Generate.run(generateOptions(rest))
    case "-h", "--help", "help":
        print(usage, terminator: "")
    default:
        fail("unknown command \(command)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
