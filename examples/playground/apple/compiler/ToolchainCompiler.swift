// The Playground's compile pipeline: user .swift files -> a `iso_hot` wasm
// feature reactor, built AGAINST THE BUNDLED SDK (playground_sdk — the slim
// `SwiftUI` module + HotBridge and their transitive wasm32 archives, plus a
// manifest). Two commands, mirroring exactly what bazel does for
// //wasm/hot_demo_feature:
//
//   1. swiftc  -target wasm32-unknown-wasip1 ... -emit-object (whole-module)
//   2. clang   --target=wasm32-unknown-wasip1 ... user.o + SDK archives
//              + swiftrt + static stdlib -> reactor .wasm
//
// The BACKEND is a seam: the iPhone links swift-frontend + lld into the app
// (EmbeddedCompiler); the Mac carries them in its Resources
// (playground_toolchain/, shared/compiler/toolchain.bzl) and runs them as
// processes (shared/compiler's BundledToolchain, as Linux and Windows do),
// with the same arguments (CompilerArguments);
// on the simulator without the embedded compiler, the host toolchain is
// posix_spawned, its paths injected by the `:run` launcher via
// SIMCTL_CHILD_ISO_PLAYGROUND_*.

import Foundation

/// One parser/compiler diagnostic (`file:line:col: error: message`).
struct SyntaxDiagnostic: Equatable {
    var line: Int
    var column: Int
    var severity: String
    var message: String
}

enum ToolchainCompiler {
    /// Every compiler invocation goes through here: the embedded frontend
    /// is in-process global state (and its diagnostics capture dup2s the
    /// process's fds 1+2), so builds and syntax checks must not overlap.
    static let queue = DispatchQueue(label: "playground.compiler", qos: .userInitiated)

    /// Fast parse-only check of a single buffer (`swift-frontend -parse`):
    /// syntax errors with positions, for the editor's squiggles. Runs on
    /// `queue`; returns [] when no backend is available.
    static func syntaxCheck(source: String, fileName: String) -> [SyntaxDiagnostic] {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("playground-check-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent(fileName.isEmpty ? "Untitled.swift" : fileName)
        guard (try? source.write(to: file, atomically: true, encoding: .utf8)) != nil else { return [] }
        var raw = ""
        if let bundled = bundledToolchain {
            return parseDiagnostics(queue.sync { bundled.parseCheck(file: file, run: spawn) })
        }
        #if ISO_PLAYGROUND_EMBEDDED
            if EmbeddedCompiler.isAvailable {
                raw = queue.sync { EmbeddedCompiler.parseCheck(file: file) }
                return parseDiagnostics(raw)
            }
        #endif
        guard Spawn.isAvailable, let toolchain = Toolchain.fromEnvironment() else { return [] }
        let result = queue.sync {
            Spawn.run(toolchain.swiftc, [
                "-frontend", "-parse", file.path,
                "-target", "wasm32-unknown-wasip1", "-no-color-diagnostics",
                "-module-name", "UserApp", "-parse-as-library",
            ], environment: ["HOME": work.path])
        }
        raw = result.stderr + result.stdout
        return parseDiagnostics(raw)
    }

    /// `path:line:col: severity: message` lines → diagnostics.
    static func parseDiagnostics(_ raw: String) -> [SyntaxDiagnostic] {
        var out: [SyntaxDiagnostic] = []
        for line in raw.split(separator: "\n") {
            // Find ": error: " / ": warning: " / ": note: ".
            guard let sevRange = line.range(of: #": (error|warning|note): "#, options: .regularExpression) else { continue }
            let head = line[line.startIndex..<sevRange.lowerBound]
            let parts = head.split(separator: ":")
            guard parts.count >= 3, let l = Int(parts[parts.count - 2]), let c = Int(parts[parts.count - 1]) else { continue }
            let severity = String(line[sevRange]).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            out.append(SyntaxDiagnostic(
                line: l, column: c, severity: severity,
                message: String(line[sevRange.upperBound...])))
        }
        return out
    }

    struct Toolchain {
        var swiftc: String
        var clang: String
        var wasiSDK: String
        var swiftStatic: String

        static func fromEnvironment() -> Toolchain? {
            let env = ProcessInfo.processInfo.environment
            guard let bin = env["ISO_PLAYGROUND_TOOLCHAIN_BIN"],
                let wasiSDK = env["ISO_PLAYGROUND_WASI_SDK"],
                let swiftStatic = env["ISO_PLAYGROUND_SWIFT_STATIC"]
            else { return nil }
            return Toolchain(
                swiftc: bin + "/swiftc",
                clang: bin + "/clang",
                wasiSDK: wasiSDK,
                swiftStatic: swiftStatic)
        }
    }

    /// The Mac's compiler: swift-frontend and wasm-ld in the app's Resources
    /// (playground_toolchain/), run as processes.
    static var bundledToolchain: BundledToolchain? {
        Bundle.main.resourceURL.flatMap { BundledToolchain.at($0.appendingPathComponent("playground_toolchain")) }
    }

    /// A tool run as a process (Spawn: iOS hides Process), its stdout and
    /// stderr together.
    static func spawn(_ tool: String, _ arguments: [String], _ environment: [String: String]) -> (status: Int32, output: String) {
        let result = Spawn.run(tool, arguments, environment: environment)
        return (result.status, result.stderr + result.stdout)
    }

    /// Whether ANY compile backend can work here right now.
    static var availability: String? {
        if bundledToolchain != nil { return nil }
        #if ISO_PLAYGROUND_EMBEDDED
            if EmbeddedCompiler.isAvailable { return nil }
        #endif
        #if os(macOS)
        return "This Mac's Playground was built without its compiler (playground_toolchain is missing from its Resources)."
        #else
        guard Spawn.isAvailable else {
            return "On-device compilation is not wired up yet — run in the "
                + "simulator via `bazel run //playground/apple/playground_ios_application:run`."
        }
        guard Toolchain.fromEnvironment() != nil else {
            return "Toolchain paths missing — launch via "
                + "`bazel run //playground/apple/playground_ios_application:run` so "
                + "ISO_PLAYGROUND_* env vars are injected."
        }
        return nil
        #endif
    }

    /// The bundled SDK (playground_sdk resource directory + its manifest).
    typealias SDK = CompilerSDK

    // The stdlib the reactor links (the union bazel's autolink extraction
    // produces for a hot_demo-shaped reactor, plus the fixed wasi/c++ set).
    private static let linkLibraries = [
        "-lswiftCore", "-lswiftSwiftOnoneSupport", "-lswiftWASILibc",
        "-lswift_Concurrency", "-lswift_RegexParser", "-lswift_StringProcessing",
        "-lswiftObservation", "-lswiftSynchronization",
        "-lc++", "-lc++abi", "-ldl", "-lm",
        "-lwasi-emulated-mman", "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks", "-lwasi-emulated-getpid",
    ]

    /// Compiles `files` (whole-module) and links the reactor; returns the
    /// wasm bytes. Runs the toolchain synchronously — call from a background
    /// task. Throws CompileError with diagnostics on failure.
    static func compile(files: [URL]) throws -> Data {
        try queue.sync { try compileSerialized(files: files) }
    }

    private static func compileSerialized(files: [URL]) throws -> Data {
        if let bundled = bundledToolchain {
            return try bundled.compile(files: files, sdk: try SDK.bundled(), run: spawn)
        }
        #if ISO_PLAYGROUND_EMBEDDED
            if EmbeddedCompiler.isAvailable {
                return try EmbeddedCompiler.compile(files: files, sdk: try SDK.bundled())
            }
        #endif
        guard let toolchain = Toolchain.fromEnvironment() else {
            throw CompileError(diagnostics: availability ?? "no compile backend")
        }
        let sdk = try SDK.bundled()

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("playground-build-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let object = work.appendingPathComponent("UserApp.o")
        let wasm = work.appendingPathComponent("UserApp.wasm")

        // Snapshot the sources into the work directory: the editor keeps
        // auto-saving while a build runs, and swiftc refuses inputs whose
        // mtime moves mid-build ("input file was modified during the build").
        var snapshots: [URL] = []
        for file in files {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else {
                throw CompileError(diagnostics: "could not stage \(file.lastPathComponent)")
            }
            snapshots.append(copy)
        }

        // 1. Whole-module compile of every playground file into one object.
        var compileArgs = [
            "-target", "wasm32-unknown-wasip1",
            "-Xcc", "--target=wasm32-unknown-wasip1",
            "-sdk", toolchain.wasiSDK,
            "-resource-dir", toolchain.swiftStatic,
            "-static-stdlib", "-static",
            "-parse-as-library",
            "-module-name", "UserApp",
            "-swift-version", "5",
            "-Onone",
            "-whole-module-optimization",
            "-I", sdk.moduleDirectory.path,
        ] + sdk.clangModuleArguments + [
            // A per-build module cache: pcm files embed their absolute cache
            // path, and the app container's tmp moves on every reinstall —
            // a persistent cache goes stale-with-errors, a per-build one
            // just costs ~a second re-precompiling the WASI headers.
            "-module-cache-path", work.appendingPathComponent("module-cache").path,
            "-emit-object", "-o", object.path,
        ]
        compileArgs += snapshots.map { $0.path }
        // The frontend's implicit clang-module cache lands in Darwin's
        // per-user cache dir, which the simulator physically SHARES across
        // app reinstalls while its nominal path changes — pcm files embed
        // the old path and every later compile fails ("was compiled with
        // module cache path …"). No flag or env reliably redirects the
        // frontend's implicit builds, so clear the poisoned cache up front;
        // it repopulates with the current path (~a second).
        let sharedCache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(".cache/clang/ModuleCache")
        try? FileManager.default.removeItem(at: sharedCache)
        let buildEnv = ["HOME": work.path]
        let compileResult = Spawn.run(toolchain.swiftc, compileArgs, environment: buildEnv)
        guard compileResult.status == 0 else {
            throw CompileError(diagnostics: prettify(compileResult.stderr + compileResult.stdout))
        }

        // 2. Link the reactor: user object + SDK archives (whole-archive: the
        // bridge's @_cdecl exports and the app's @main are reached only from
        // the host) + swiftrt + the static stdlib, the hosts' entries
        // exported and the rest dead-stripped (16 MiB stack, reactor model).
        var linkArgs = [
            "--target=wasm32-unknown-wasip1",
            "--sysroot=" + toolchain.wasiSDK,
            "-resource-dir", toolchain.swiftStatic + "/clang",
            object.path,
        ]
        for archive in sdk.archives {
            linkArgs += ["-Wl,--whole-archive", archive.path, "-Wl,--no-whole-archive"]
        }
        if let exports = sdk.exports {
            linkArgs += ["-Xlinker", "--gc-sections"] + exports.flatMap { ["-Xlinker", "--export-if-defined=" + $0] }
        } else {
            linkArgs += ["-Xlinker", "--export-all", "-Xlinker", "--no-gc-sections"]
        }
        linkArgs += [
            "-Xlinker", "-z", "-Xlinker", "stack-size=16777216",
            "-mexec-model=reactor",
            toolchain.swiftStatic + "/wasi/wasm32/swiftrt.o",
            "-L", toolchain.swiftStatic + "/wasi",
        ]
        linkArgs += linkLibraries
        linkArgs += [
            "-Wl,--global-base=4096",
            "-Wl,--table-base=4096",
            "-o", wasm.path,
        ]
        let linkResult = Spawn.run(toolchain.clang, linkArgs, environment: buildEnv)
        guard linkResult.status == 0 else {
            throw CompileError(diagnostics: prettify(linkResult.stderr + linkResult.stdout))
        }

        guard let bytes = try? Data(contentsOf: wasm), !bytes.isEmpty else {
            throw CompileError(diagnostics: "link produced no output")
        }
        return bytes
    }

    /// Strips absolute temp paths down to filenames, so diagnostics read
    /// like an editor's, not a build log's.
    static func prettify(_ raw: String) -> String {
        CompilerDiagnostics.prettify(raw)
    }
}

extension CompilerSDK {
    /// The SDK in the app's bundle. rules_apple flattens tree-artifact
    /// resources into the bundle's resource root (modules/, lib/,
    /// manifest.json land beside Info.plist); a named playground_sdk folder
    /// is accepted too.
    static func bundled() throws -> CompilerSDK {
        guard let root = Bundle.main.url(forResource: "playground_sdk", withExtension: nil) ?? Bundle.main.resourceURL else {
            throw CompileError(diagnostics: "playground_sdk resource missing from the app bundle")
        }
        return try load(root: root)
    }
}
