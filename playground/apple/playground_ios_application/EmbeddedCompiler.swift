// The EMBEDDED compile backend: the Swift compiler and wasm-ld linked INTO
// this app as static libraries (build_embedded_toolchain.sh stages them from
// the ~/Developer/ios-toolchain cross-build; `--define iso_playground_embedded=1`
// links them). Compilation is two IN-PROCESS calls — `iso_swiftc_main`
// (swift::mainEntry, invoked as `swift-frontend -frontend`, which spawns
// nothing) and `iso_wasm_ld_main` (lld with argv[0] "wasm-ld") — against the
// bundled WASI sysroot + static stdlib. No subprocess anywhere: this is the
// backend a REAL DEVICE runs, and the simulator runs it identically.

#if ISO_PLAYGROUND_EMBEDDED

import Foundation

@_silgen_name("iso_swiftc_main")
private func iso_swiftc_main(
    _ argc: Int32, _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Int32

@_silgen_name("iso_wasm_ld_main")
private func iso_wasm_ld_main(
    _ argc: Int32, _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Int32

enum EmbeddedCompiler {
    /// The bundled toolchain data (structured resources).
    private struct DataPaths {
        var wasiSDK: String
        var swiftStatic: String
        /// The app's Frameworks/ dir when it embeds the in-process plugin
        /// server + macro plugin frameworks (nil when the staging predates
        /// macro support).
        var host: String?

        static func bundled() -> DataPaths? {
            guard let root = Bundle.main.resourceURL?
                .appendingPathComponent("embedded_toolchain")
            else { return nil }
            #if targetEnvironment(simulator)
                let platform = "iphonesimulator"
            #else
                let platform = "iphoneos"
            #endif
            _ = platform
            let frameworks = Bundle.main.privateFrameworksURL
            let server = frameworks?.appendingPathComponent(
                "SPluginSrv.framework/SPluginSrv")
            let paths = DataPaths(
                wasiSDK: root.appendingPathComponent("data/WASI.sdk").path,
                swiftStatic: root.appendingPathComponent("data/swift_static").path,
                host: server.map { FileManager.default.fileExists(atPath: $0.path) } == true
                    ? frameworks?.path : nil)
            guard FileManager.default.fileExists(atPath: paths.wasiSDK) else { return nil }
            return paths
        }
    }

    static var isAvailable: Bool { DataPaths.bundled() != nil }

    /// Parse-only pass over one file (the editor's syntax check): the
    /// frontend's `-parse` action, no SDK or modules needed. Returns the
    /// raw diagnostics text.
    static func parseCheck(file: URL) -> String {
        let result = run(entry: iso_swiftc_main, arguments: [
            "swift-frontend", "-frontend", "-parse", file.path,
            "-target", "wasm32-unknown-wasip1", "-disable-objc-interop",
            "-no-color-diagnostics", "-module-name", "UserApp", "-parse-as-library",
        ])
        return result.output
    }

    /// Compiles `files` into a `iso_hot` reactor entirely in-process.
    static func compile(files: [URL], sdk: ToolchainCompiler.SDK) throws -> Data {
        guard let data = DataPaths.bundled() else {
            throw CompileError(diagnostics: "embedded toolchain data missing from the bundle")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("playground-embedded-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let object = work.appendingPathComponent("UserApp.o")
        let wasm = work.appendingPathComponent("UserApp.wasm")

        // Snapshot sources (the editor auto-saves during builds).
        var snapshots: [String] = []
        for file in files {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.copyItem(at: file, to: copy)
            snapshots.append(copy.path)
        }

        // The exact single-frontend invocation the driver would spawn (mined
        // via swiftc -###), minus macro-plugin paths — no host dylibs here.
        var frontend = ["swift-frontend", "-frontend", "-c"]
        frontend += snapshots
        frontend += [
            "-target", "wasm32-unknown-wasip1",
            "-disable-objc-interop",
            "-sdk", data.wasiSDK,
            "-I", sdk.moduleDirectory.path,
        ] + sdk.clangModuleArguments + [
            "-no-color-diagnostics",
            "-Xcc", "-fno-color-diagnostics",
            "-static",
            "-swift-version", "5",
            "-Onone",
            "-empty-abi-descriptor",
            "-resource-dir", data.swiftStatic,
            "-use-static-resource-dir",
            "-Xcc", "--target=wasm32-unknown-wasip1",
            "-module-cache-path", work.appendingPathComponent("module-cache").path,
            "-module-name", "UserApp",
            "-parse-as-library",
            "-o", object.path,
        ]
        // Macro expansion, still spawn-free: the in-process plugin server is
        // dlopened by the frontend, and it loads the bundled macro plugin
        // dylibs (libSwiftMacros, ObservationMacros, ...) in-process too.
        if let host = data.host {
            frontend += [
                "-in-process-plugin-server-path",
                host + "/SPluginSrv.framework/SPluginSrv",
            ]
            // Each *Macros.framework wraps a prebuilt plugin, loaded by explicit
            // path; its binary keeps the lib<Name>.dylib name the frontend
            // derives the plugin module name from.
            let plugins = ((try? FileManager.default.contentsOfDirectory(atPath: host)) ?? [])
                .filter { $0.hasSuffix("Macros.dylib.framework") }.sorted()
            for plugin in plugins {
                let name = String(plugin.dropLast(".framework".count))
                frontend += ["-load-plugin-library", host + "/" + plugin + "/" + name]
            }
        }
        let compileResult = run(entry: iso_swiftc_main, arguments: frontend)
        guard compileResult.status == 0 else {
            throw CompileError(diagnostics: ToolchainCompiler.prettify(compileResult.output))
        }

        // The exact raw wasm-ld line the clang driver would produce
        // (mined via clang -###): reactor model, whole-archive SDK, static
        // stdlib + wasi emulation libs + compiler-rt builtins.
        var link = [
            "wasm-ld", "-m", "wasm32",
            "-L" + data.swiftStatic + "/wasi",
            "-L" + data.wasiSDK + "/lib/wasm32-wasip1",
            data.wasiSDK + "/lib/wasm32-wasip1/crt1-reactor.o",
            "--entry", "_initialize",
            object.path,
            "--whole-archive",
        ]
        link += sdk.archives.map { $0.path }
        link += ["--no-whole-archive"]
        // The hosts' entries exported and the rest dead-stripped, as isomer
        // ships its reactors; an SDK without the list exports everything.
        if let exports = sdk.exports {
            link += ["--gc-sections"] + exports.map { "--export-if-defined=" + $0 }
        } else {
            link += ["--export-all", "--no-gc-sections"]
        }
        link += [
            "-z", "stack-size=16777216",
            data.swiftStatic + "/wasi/wasm32/swiftrt.o",
            "-lswiftCore", "-lswiftSwiftOnoneSupport", "-lswiftWASILibc",
            "-lswift_Concurrency", "-lswift_RegexParser", "-lswift_StringProcessing",
            "-lswiftObservation", "-lswiftSynchronization",
            "-lc++", "-lc++abi", "-ldl", "-lm",
            "-lwasi-emulated-mman", "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks", "-lwasi-emulated-getpid",
            "--global-base=4096", "--table-base=4096",
            "-lc",
            data.swiftStatic + "/clang/lib/wasip1/libclang_rt.builtins-wasm32.a",
            "-o", wasm.path,
        ]
        let linkResult = run(entry: iso_wasm_ld_main, arguments: link)
        guard linkResult.status == 0 else {
            throw CompileError(diagnostics: ToolchainCompiler.prettify(linkResult.output))
        }

        guard let bytes = try? Data(contentsOf: wasm), !bytes.isEmpty else {
            throw CompileError(diagnostics: "embedded link produced no output")
        }
        return bytes
    }

    // MARK: - In-process tool invocation

    private struct ToolResult {
        var status: Int32
        var output: String
    }

    /// Runs a linked-in tool entry with `arguments`, capturing everything it
    /// writes to stdout/stderr (dup2 over fds 1+2 around the call, with a
    /// concurrent drain so a full pipe buffer can't deadlock the tool).
    private static func run(
        entry: (Int32, UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Int32,
        arguments: [String]
    ) -> ToolResult {
        var captured = Data()
        let capturedLock = NSLock()
        var pipeFDs: [Int32] = [0, 0]
        pipe(&pipeFDs)
        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]

        let drain = Thread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(readFD, &buffer, buffer.count)
                if n <= 0 { break }
                capturedLock.withLock { captured.append(contentsOf: buffer[0..<n]) }
            }
            close(readFD)
        }
        drain.start()

        let savedOut = dup(1)
        let savedErr = dup(2)
        dup2(writeFD, 1)
        dup2(writeFD, 2)
        close(writeFD)

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        let status = argv.withUnsafeBufferPointer { buffer in
            entry(Int32(arguments.count), buffer.baseAddress!)
        }
        argv.forEach { free($0) }

        // Restore the process fds; closing our dup'd write end EOFs the drain.
        dup2(savedOut, 1)
        dup2(savedErr, 2)
        close(savedOut)
        close(savedErr)
        // Give the drain a moment to finish reading the tail.
        for _ in 0..<200 where drain.isExecuting { usleep(5000) }

        let output = capturedLock.withLock {
            String(decoding: captured, as: UTF8.self)
        }
        return ToolResult(status: status, output: output)
    }
}

#endif
