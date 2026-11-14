import Foundation

// `generate`: the whole of a mixed build's native part, from the runtime
// module and a native set to the files the host compiles:
//
//   1. slim the runtime to the entry points:      split_input.wasm
//   2. Binaryen's wasm-split on the set:           hot_full.wasm, cold.wasm (+ .symbols)
//   3. slim the native part:                       hot.wasm
//   4. map the slots the split added:              slots.txt
//   5. WABT's wasm2c, in eight files:              hot_0.c … hot_7.c, hot.h, hot-impl.h
//   6. the bridge:                                 mixed_glue.c, mixed_glue.h, shim.wat
//   7. WABT's wat2wasm:                            shim.wasm
//
// The outputs go to --out; everything else to a directory inside it, removed
// however the run ends. Nothing is fetched; the same inputs and tools make
// the same bytes.

enum Generate {
    struct Options {
        var wasmSplit = ""
        var wasm2c = ""
        var wat2wasm = ""
        var runtime = ""
        var set = ""
        var entries = ""
        var out = ""
        /// When set, --wasm2c and --wat2wasm are WASI modules (WABT's WASI
        /// build) run by this command (//tools/wasm/wasi_run), the output
        /// directory their working directory: the same on every build
        /// machine, where WABT's native builds aren't (its macOS wasm2c
        /// links Homebrew's OpenSSL).
        var wasiRun = ""
    }

    /// What wasm2c writes besides hot_<n>.c, and the rest of the outputs.
    static let outputs = (0..<8).map { "hot_\($0).c" }
        + ["hot.h", "hot-impl.h", "mixed_glue.c", "mixed_glue.h", "shim.wasm", "slots.txt"]

    static func run(_ o: Options) throws {
        let fm = FileManager.default
        let wasmSplit = try executable(o.wasmSplit, "--wasm-split")
        // Native tools, or WASI modules run by --wasi-run.
        func resolve(_ path: String, _ flag: String) throws -> String {
            if o.wasiRun.isEmpty { return try executable(path, flag) }
            let p = absolute(path)
            guard fm.isReadableFile(atPath: p) else { throw ToolError("\(flag): can't read \(p)") }
            return p
        }
        let wasm2c = try resolve(o.wasm2c, "--wasm2c")
        let wat2wasm = try resolve(o.wat2wasm, "--wat2wasm")
        let runtime = absolute(o.runtime)
        let set = absolute(o.set)
        let out = absolute(o.out)
        for (path, flag) in [(runtime, "--runtime"), (set, "--set")] where !fm.isReadableFile(atPath: path) {
            throw ToolError("\(flag): can't read \(path)")
        }
        // The keep list's @files are read now, relative to the working directory.
        let keep = try Slim.keepSet(o.entries)

        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let work = out + "/.wasm_mixed.work"
        if fm.fileExists(atPath: work) { try fm.removeItem(atPath: work) }
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: work) }

        // 1. The split's input: wasm-split keeps every exported function in
        // the first part, so only the entry points (and the routed functions)
        // stay exported.
        let runtimeBytes = try FileIO.read(runtime)
        let splitInput = try Slim.slim(runtimeBytes, keeping: keep)
        try FileIO.write(work + "/split_input.wasm", splitInput)
        print("split input: \(Slim.megabytes(runtimeBytes.count)) MB -> \(Slim.megabytes(splitInput.count)) MB")

        // 2. The split: the set (and what is exported) in hot_full.wasm.
        let splitLog = try tool(
            wasmSplit,
            ["--split", "--no-placeholders", "--symbolmap", "--keep-funcs=@" + set,
             "-o1", "hot_full.wasm", "-o2", "cold.wasm", "split_input.wasm"],
            in: work, log: work + "/wasm-split.log")
        let lines = PythonText.splitLines(splitLog)
        let absent = lines.filter { $0.contains("does not exist") }.count
        for line in lines where !line.contains("does not exist") { print("wasm-split: \(line)") }
        if absent > 0 { print("wasm-split: \(absent) functions of the set are not in the module") }

        // 3. The native part without data or exports the host doesn't call.
        let hotFull = try FileIO.read(work + "/hot_full.wasm")
        let hot = try Slim.slim(hotFull, keeping: keep)
        try FileIO.write(work + "/hot.wasm", hot)
        print("native part: \(Slim.megabytes(hotFull.count)) MB -> \(Slim.megabytes(hot.count)) MB")

        // 4. The slots the split added, as the runtime's functions.
        try MapSlots.run(
            runtime: runtime,
            cold: work + "/cold.wasm", coldSymbols: work + "/cold.wasm.symbols",
            hot: work + "/hot_full.wasm", hotSymbols: work + "/hot_full.wasm.symbols",
            output: out + "/slots.txt")

        // 5. C. The module's C names (w2c_hot_…) come from the input's file
        // name, the header's guard and includes from the output's: hot.wasm,
        // hot.c, written in --out.
        let c: String
        if o.wasiRun.isEmpty {
            c = try tool(wasm2c, ["--num-outputs=8", work + "/hot.wasm", "-o", "hot.c"], in: out, log: work + "/wasm2c.log")
        } else {
            c = try tool(try executable(o.wasiRun, "--wasi-run"),
                         ["--map-dir=.::" + out, wasm2c, "--num-outputs=8", ".wasm_mixed.work/hot.wasm", "-o", "hot.c"],
                         in: out, log: work + "/wasm2c.log")
        }
        if !c.isEmpty { print(c, terminator: "") }

        // 6. The bridge.
        let bridge = try Bridge.generate(hotWasm: work + "/hot.wasm", hotHeader: out + "/hot.h")
        try FileIO.write(out + "/mixed_glue.c", bridge.glueC)
        try FileIO.write(out + "/mixed_glue.h", bridge.glueH)
        try FileIO.write(work + "/shim.wat", bridge.shimWAT)
        print(bridge.summary)

        // 7. The shim WasmKit instantiates.
        let w: String
        if o.wasiRun.isEmpty {
            w = try tool(wat2wasm, [work + "/shim.wat", "-o", out + "/shim.wasm"], in: work, log: work + "/wat2wasm.log")
        } else {
            w = try tool(try executable(o.wasiRun, "--wasi-run"),
                         ["--map-dir=.::" + out, wat2wasm, ".wasm_mixed.work/shim.wat", "-o", "shim.wasm"],
                         in: out, log: work + "/wat2wasm.log")
        }
        if !w.isEmpty { print(w, terminator: "") }

        for name in outputs where !fm.fileExists(atPath: out + "/" + name) {
            throw ToolError("\(name) was not made (wasm2c's --num-outputs or WABT's version?)")
        }
    }

    static func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    }

    /// A tool by path, or by name on PATH.
    static func executable(_ path: String, _ flag: String) throws -> String {
        if path.isEmpty { throw ToolError("\(flag) is required") }
        let fm = FileManager.default
        if path.contains("/") {
            let p = absolute(path)
            guard fm.isExecutableFile(atPath: p) else { throw ToolError("\(flag): \(p) is not an executable") }
            return p
        }
        let search = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in search.split(separator: ":") where fm.isExecutableFile(atPath: "\(dir)/\(path)") {
            return absolute("\(dir)/\(path)")
        }
        throw ToolError("\(flag): \(path) is not on PATH")
    }

    /// Runs a tool in a directory, its output (both streams) kept in a log
    /// file; its output, or an error with the end of it.
    static func tool(_ executable: String, _ arguments: [String], in directory: String, log: String) throws -> String {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard FileManager.default.createFile(atPath: log, contents: nil) else {
            throw ToolError("can't write \(log)")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            throw ToolError("can't run \(executable): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        try handle.close()
        let output = String(decoding: try FileIO.read(log), as: UTF8.self)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let how = process.terminationReason == .exit
                ? "exited with \(process.terminationStatus)" : "was killed by signal \(process.terminationStatus)"
            let tail = PythonText.splitLines(output).suffix(20).joined(separator: "\n")
            throw ToolError("\(name) \(how): \(([executable] + arguments).joined(separator: " "))\n\(tail)")
        }
        return output
    }
}
