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
        run(entry: iso_swiftc_main, arguments: ["swift-frontend"] + CompilerArguments.parse(file: file.path)).output
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

        // Macro expansion, still spawn-free: the in-process plugin server is
        // dlopened by the frontend, and it loads the bundled macro plugin
        // dylibs (libSwiftMacros, ObservationMacros, ...) in-process too.
        // Each *Macros.framework wraps a prebuilt plugin, loaded by explicit
        // path; its binary keeps the lib<Name>.dylib name the frontend
        // derives the plugin module name from.
        var paths = CompilerArguments.Paths(wasiSDK: data.wasiSDK, swiftStatic: data.swiftStatic)
        if let host = data.host {
            paths.pluginServer = host + "/SPluginSrv.framework/SPluginSrv"
            paths.plugins = ((try? FileManager.default.contentsOfDirectory(atPath: host)) ?? [])
                .filter { $0.hasSuffix("Macros.dylib.framework") }.sorted()
                .map { host + "/" + $0 + "/" + String($0.dropLast(".framework".count)) }
        }
        let frontend = ["swift-frontend"] + CompilerArguments.frontend(
            files: snapshots, object: object.path,
            moduleCache: work.appendingPathComponent("module-cache").path, paths: paths, sdk: sdk)
        let compileResult = run(entry: iso_swiftc_main, arguments: frontend)
        guard compileResult.status == 0 else {
            throw CompileError(diagnostics: ToolchainCompiler.prettify(compileResult.output))
        }

        let link = ["wasm-ld"] + CompilerArguments.link(object: object.path, output: wasm.path, paths: paths, sdk: sdk)
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
