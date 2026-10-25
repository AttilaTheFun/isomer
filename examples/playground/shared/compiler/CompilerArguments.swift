// The arguments of a project's build, the same wherever the compiler runs:
// the iPhone's swift-frontend and lld linked into the app (EmbeddedCompiler)
// and the Mac's run as processes from its Resources (ToolchainCompiler's
// bundled toolchain). Two steps, as Bazel builds a hot reactor:
//
//   1. swift-frontend -frontend -c: every file of the project, whole-module,
//      into one wasm32 object against the bundled SDK's modules;
//   2. wasm-ld: that object, the SDK's archives (whole-archive: the bridge's
//      exports and the app's @main are reached only from the host), the WASI
//      reactor start file and the static stdlib, into the reactor.
//
// Neither list starts with the tool's own name (argv[0]); its caller adds it.

import Foundation

enum CompilerArguments {
    /// Where the wasm SDK's sysroot and static resources are, and the macro
    /// plugins (the in-process plugin server and the plugin libraries).
    struct Paths {
        var wasiSDK: String
        var swiftStatic: String
        var pluginServer: String?
        var plugins: [String] = []
    }

    /// swift-frontend's: compile `files` into `object`.
    static func frontend(
        files: [String], object: String, moduleCache: String,
        paths: Paths, sdk: CompilerSDK
    ) -> [String] {
        var arguments = ["-frontend", "-c"] + files + [
            "-target", "wasm32-unknown-wasip1",
            "-disable-objc-interop",
            "-sdk", paths.wasiSDK,
            "-I", sdk.moduleDirectory.fileSystemPath,
        ] + sdk.clangModuleArguments + [
            "-no-color-diagnostics",
            "-Xcc", "-fno-color-diagnostics",
            "-static",
            "-swift-version", "5",
            "-Onone",
            "-empty-abi-descriptor",
            "-resource-dir", paths.swiftStatic,
            "-use-static-resource-dir",
            "-Xcc", "--target=wasm32-unknown-wasip1",
            // A per-build module cache: pcm files embed their absolute cache
            // path, and an app container's tmp moves with every reinstall.
            "-module-cache-path", moduleCache,
            "-module-name", "UserApp",
            "-parse-as-library",
            "-o", object,
        ]
        if let server = paths.pluginServer {
            arguments += ["-in-process-plugin-server-path", server]
            arguments += paths.plugins.flatMap { ["-load-plugin-library", $0] }
        }
        return arguments
    }

    /// swift-frontend's parse-only check of one file (the editor's squiggles).
    static func parse(file: String) -> [String] {
        [
            "-frontend", "-parse", file,
            "-target", "wasm32-unknown-wasip1", "-disable-objc-interop",
            "-no-color-diagnostics", "-module-name", "UserApp", "-parse-as-library",
        ]
    }

    /// wasm-ld's: link `object` with the SDK into the reactor `output`.
    static func link(object: String, output: String, paths: Paths, sdk: CompilerSDK) -> [String] {
        var arguments = [
            "-m", "wasm32",
            "-L" + paths.swiftStatic + "/wasi",
            "-L" + paths.wasiSDK + "/lib/wasm32-wasip1",
            paths.wasiSDK + "/lib/wasm32-wasip1/crt1-reactor.o",
            "--entry", "_initialize",
            object,
            "--whole-archive",
        ]
        arguments += sdk.archives.map(\.fileSystemPath)
        arguments += ["--no-whole-archive"]
        // The hosts' entries exported, the rest dead-stripped (an SDK that
        // lists none exports everything).
        if let exports = sdk.exports {
            arguments += ["--gc-sections"] + exports.map { "--export-if-defined=" + $0 }
        } else {
            arguments += ["--export-all", "--no-gc-sections"]
        }
        arguments += [
            "-z", "stack-size=16777216",
            paths.swiftStatic + "/wasi/wasm32/swiftrt.o",
            "-lswiftCore", "-lswiftSwiftOnoneSupport", "-lswiftWASILibc",
            "-lswift_Concurrency", "-lswift_RegexParser", "-lswift_StringProcessing",
            "-lswiftObservation", "-lswiftSynchronization",
            "-lc++", "-lc++abi", "-ldl", "-lm",
            "-lwasi-emulated-mman", "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks", "-lwasi-emulated-getpid",
            "--global-base=4096", "--table-base=4096",
            "-lc",
            paths.swiftStatic + "/clang/lib/wasip1/libclang_rt.builtins-wasm32.a",
            "-o", output,
        ]
        return arguments
    }
}
