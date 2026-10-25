// What every Playground that carries its compiler shares: the SDK a project
// compiles against (CompilerSDK), the compiler's errors, and the build with
// a toolchain the app carries as files (BundledToolchain: swift-frontend and
// wasm-ld run as processes, on the Mac, Linux and Windows). The iPhone links
// the same compiler into the app instead (apple/compiler/EmbeddedCompiler);
// all of them pass CompilerArguments'.

import Foundation

extension URL {
    /// The path as the platform's tools take it: on Windows `C:\...`, where
    /// `path` is `/C:/...` (which a tool reads as a directory of the
    /// current drive's root).
    var fileSystemPath: String {
        withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? path
    }
}

/// A failed build: the compiler's or the linker's diagnostics.
struct CompileError: Error {
    var diagnostics: String
}

/// The Playground SDK (the playground_sdk bundle: the slim SwiftUI module,
/// the hot bridge and their wasm32 archives, and a manifest).
struct CompilerSDK {
    var root: URL
    var moduleDirectory: URL
    var archives: [URL]
    /// The hosts' entries (isomer 0.31's SDKs list them): exported, the
    /// rest dead-stripped; nil exports everything.
    var exports: [String]?
    /// Clang modules the SDK's Swift modules import (module map + headers).
    var clangModuleMaps: [URL] = []
    var clangIncludeDirectories: [URL] = []

    /// Frontend arguments that make the clang modules resolvable.
    var clangModuleArguments: [String] {
        clangModuleMaps.flatMap { ["-Xcc", "-fmodule-map-file=" + $0.fileSystemPath] }
            + clangIncludeDirectories.flatMap { ["-Xcc", "-I", "-Xcc", $0.fileSystemPath] }
    }

    /// The SDK whose manifest.json is in `root`.
    static func load(root: URL) throws -> CompilerSDK {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CompileError(diagnostics: "the Playground SDK is missing (no manifest.json in \(root.path))")
        }
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let archiveList = manifest["archives"] as? [String]
        else { throw CompileError(diagnostics: "the Playground SDK's manifest is unreadable") }
        let clang = (manifest["clang_modules"] as? [[String: Any]]) ?? []
        return CompilerSDK(
            root: root,
            moduleDirectory: root.appendingPathComponent("modules"),
            archives: archiveList.map { root.appendingPathComponent($0) },
            exports: manifest["exports"] as? [String],
            clangModuleMaps: clang.compactMap { ($0["modulemap"] as? String).map(root.appendingPathComponent) },
            clangIncludeDirectories: clang.compactMap { ($0["include"] as? String).map(root.appendingPathComponent) })
    }
}

enum CompilerDiagnostics {
    /// Strips absolute temp paths down to file names, so diagnostics read
    /// like an editor's, not a build log's.
    static func prettify(_ raw: String) -> String {
        let pattern = "/[^\\s:]+/([A-Za-z0-9_ .-]+\\.swift)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "$1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A compiler the app carries as files (the playground_toolchain directory,
/// shared/compiler/toolchain.bzl): swift-frontend and wasm-ld, the macro
/// plugin server and plugins beside them, the wasm SDK's sysroot and static
/// stdlib under data/.
struct BundledToolchain {
    var frontend: String
    var linker: String
    var paths: CompilerArguments.Paths

    /// How a tool runs: its path, arguments and extra environment in; its
    /// exit status and what it wrote out.
    typealias Run = (_ tool: String, _ arguments: [String], _ environment: [String: String]) -> (status: Int32, output: String)

    /// The toolchain in `root`, if it is there. On the Mac and Linux it is
    /// the toolchain's own layout (toolchain.bzl assembles it); on Windows,
    /// whose swift.org toolchain keeps everything in usr\bin (the frontend
    /// finds its DLLs beside it), the frontend, wasm-ld, the plugin server,
    /// the macro plugins and their DLLs are all in usr/bin.
    static func at(_ root: URL) -> BundledToolchain? {
        let bin = root.appendingPathComponent("usr/bin")
        #if os(Windows)
        let frontend = bin.appendingPathComponent("swift-frontend.exe")
        let linker = bin.appendingPathComponent("wasm-ld.exe")
        let server = bin.appendingPathComponent("SwiftInProcPluginServer.dll")
        let plugins = ["ObservationMacros.dll", "SwiftMacros.dll"].map { bin.appendingPathComponent($0) }
        #else
        #if canImport(Darwin)
        let library = ".dylib"
        #else
        let library = ".so"
        #endif
        let frontend = bin.appendingPathComponent("swift-frontend")
        let linker = bin.appendingPathComponent("wasm-ld")
        let host = root.appendingPathComponent("usr/lib/swift/host")
        let server = host.appendingPathComponent("libSwiftInProcPluginServer" + library)
        let pluginDirectory = host.appendingPathComponent("plugins")
        let plugins = ((try? FileManager.default.contentsOfDirectory(atPath: pluginDirectory.path)) ?? [])
            .filter { $0.hasSuffix(library) }.sorted()
            .map { pluginDirectory.appendingPathComponent($0) }
        #endif
        guard FileManager.default.fileExists(atPath: frontend.path) else { return nil }
        return BundledToolchain(
            frontend: frontend.fileSystemPath,
            linker: linker.fileSystemPath,
            paths: CompilerArguments.Paths(
                wasiSDK: root.appendingPathComponent("data/WASI.sdk").fileSystemPath,
                swiftStatic: root.appendingPathComponent("data/swift_static").fileSystemPath,
                pluginServer: FileManager.default.fileExists(atPath: server.path) ? server.fileSystemPath : nil,
                plugins: plugins.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.fileSystemPath)))
    }

    /// Parse-only diagnostics of one file (the editor's syntax check).
    func parseCheck(file: URL, run: Run) -> String {
        run(frontend, CompilerArguments.parse(file: file.fileSystemPath), [:]).output
    }

    /// Compiles `files` (whole-module) and links the reactor; its bytes.
    func compile(files: [URL], sdk: CompilerSDK, run: Run) throws -> Data {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("playground-build-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let object = work.appendingPathComponent("UserApp.o")
        let wasm = work.appendingPathComponent("UserApp.wasm")
        // Snapshot the sources: the editor auto-saves while a build runs, and
        // the frontend refuses an input whose mtime moves mid-build.
        var snapshots: [String] = []
        for file in files {
            let copy = work.appendingPathComponent(file.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else {
                throw CompileError(diagnostics: "could not stage \(file.lastPathComponent)")
            }
            snapshots.append(copy.fileSystemPath)
        }
        let environment = ["HOME": work.fileSystemPath]
        let compile = run(frontend, CompilerArguments.frontend(
            files: snapshots, object: object.fileSystemPath,
            moduleCache: work.appendingPathComponent("module-cache").fileSystemPath,
            paths: paths, sdk: sdk), environment)
        guard compile.status == 0 else {
            throw CompileError(diagnostics: CompilerDiagnostics.prettify(compile.output))
        }
        let link = run(linker, CompilerArguments.link(
            object: object.fileSystemPath, output: wasm.fileSystemPath, paths: paths, sdk: sdk), environment)
        guard link.status == 0 else {
            throw CompileError(diagnostics: CompilerDiagnostics.prettify(link.output))
        }
        guard let bytes = try? Data(contentsOf: wasm), !bytes.isEmpty else {
            throw CompileError(diagnostics: "the link produced no reactor")
        }
        return bytes
    }
}
