// Headless smoke test for the composed wasm pipeline: instantiate the demo
// reactor under WAMR (WASI + the swift_ffi dependency transport plus
// the `iso_hot` render callbacks are all wired by the shared C host), inject a
// native ConfigurationService, run `iso_hot_start`/`render`, and assert the reactor pushed
// a tree containing the demo greeting AND the native-flag-gated promo banner.
// Proves the whole path (WASI, swift_ffi DI, iso_hot render, FlatBuffers) works
// without a GUI. Usage: hot_smoke <path-to.wasm> [expected-substring]

import ApplePlatformServices
import Foundation
import IsomerWamrRuntime
import IsomerWasmRuntime

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: hot_smoke <wasm> [substring]\n".utf8))
    exit(2)
}
let wasmPath = args[1]
let needle = args.count >= 3 ? args[2] : "Hot reload works."


func run() -> Never {
    do {
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: wasmPath)))
        let tree: [UInt8] = try MainActor.assumeIsolated {
            var captured: [UInt8] = []
            let runtime = WamrRuntime()
            let imports = WasmHostImports(
                onRenderTree: { captured = $0 },
                onLog: { _ in },
                epochMillis: { Date().timeIntervalSince1970 * 1000 },
                onScheduleRender: {}
            )
            // Inject the app's dependency table (before launch — the DI
            // imports bind at instantiation): the dependency table rides the
            // standard dictionary like every other dependency.
            runtime.installDependencies(
                prefix: platformServicesFFIPrefix,
                applePlatformDependencies(namespace: "smoke"))
            try runtime.launch(wasm: bytes, hostImports: imports)
            _ = try runtime.call("iso_hot_start", [.f64(900), .f64(680)])
            _ = try runtime.call("iso_hot_render", [])
            return captured
        }

        guard !tree.isEmpty else {
            FileHandle.standardError.write(Data("FAIL: no render tree emitted\n".utf8))
            exit(1)
        }
        let haystack = Data(tree)
        // The injected flag returned true, so the demo's promo banner must be
        // present — proof the native dependency crossed into the feature (over
        // swift_ffi) and back.
        let promo = "Promo from native host"
        let hasPromo = haystack.range(of: Data(promo.utf8)) != nil
        guard haystack.range(of: Data(needle.utf8)) != nil else {
            FileHandle.standardError.write(
                Data("FAIL: tree (\(tree.count) bytes) missing \"\(needle)\"\n".utf8))
            exit(1)
        }
        guard hasPromo else {
            FileHandle.standardError.write(
                Data("FAIL: injected ConfigurationService flag did not reach the feature (no promo banner)\n".utf8))
            exit(1)
        }
        print("OK: tree is \(tree.count) bytes, contains \"\(needle)\", and the injected swift_ffi ConfigurationService flag rendered the promo banner")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("run failed: \(error)\n".utf8))
        exit(1)
    }
}

run()
