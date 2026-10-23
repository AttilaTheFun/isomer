// The engine-seam conformance suite: every registered `WasmRuntime` engine
// must run the real tap-counter reactor identically — launch, first frame
// containing the counter UI, a tap event producing an updated tree. This is
// what "pluggable" means operationally; a new engine passes this suite or it
// isn't an engine. Timing is printed (startup / tap medians) for a rough
// cross-engine comparison; treat it as a smell test, not a benchmark (see
// docs/benchmarks.md for methodology-grade numbers).

import ApplePlatformServices
import PlatformServicesHost
import IsomerNetworkWasmHost
import Foundation
import IsomerJSCRuntime
import IsomerWasmKitRuntime
import IsomerWasmEdgeRuntime
import IsomerWasmRuntime
import XCTest

final class WasmEngineTests: XCTestCase {
    // MARK: - Engines under test

    @MainActor
    private static let engines: [(name: String, make: @MainActor () -> any WasmRuntime)] = [
        ("WasmKit", { WasmKitRuntime() }),
        ("JSC", { JSCRuntime() }),
        ("WasmEdge", { WasmEdgeRuntime() }),
    ]

    // MARK: - The conformance run

    func testEveryEngineRunsTheReactor() throws {
        try MainActor.assumeIsolated {
            let wasm = try Self.reactorBytes()
            for engine in Self.engines {
                do {
                    try Self.exercise(engine.make(), name: engine.name, wasm: wasm)
                } catch {
                    XCTFail("\(engine.name): \(error)")
                }
            }
        }
    }

    /// Dark mode reaches the guest: `iso_hot_set_color_scheme` re-resolves
    /// the adaptive semantic palette, so the same UI renders a DIFFERENT tree
    /// (background/label colors flip) — the signal WasmView forwards from
    /// `@Environment(\.colorScheme)` and the web page from
    /// `prefers-color-scheme`.
    func testColorSchemeReachesTheGuest() throws {
        try MainActor.assumeIsolated {
            // The FULL app (colorful gallery) — the tap counter's tree
            // carries no explicit colors, so its dark tree is identical.
            let wasm = try Self.artifactBytes("wasm/example_full_feature/example_full.wasm")
            var stream: [UInt8] = []
            let imports = WasmHostImports(
                onRenderTree: { stream.append(contentsOf: $0) },
                onLog: { _ in },
                epochMillis: { Date().timeIntervalSince1970 * 1000 },
                onScheduleRender: {}
            )
            let runtime = WasmKitRuntime()
            try runtime.launch(wasm: wasm, hostImports: imports)
            _ = try runtime.call("iso_hot_start", [.f64(390), .f64(680)])
            _ = try runtime.call("iso_hot_render", [])
            let light = stream

            stream.removeAll()
            _ = try runtime.call("iso_hot_set_color_scheme", [.i32(1)])
            _ = try runtime.call("iso_hot_render", [])
            let dark = stream
            XCTAssertFalse(dark.isEmpty, "dark render emitted no tree")
            XCTAssertNotEqual(light, dark, "dark mode did not change the rendered tree")

            // And back: light again must differ from dark.
            stream.removeAll()
            _ = try runtime.call("iso_hot_set_color_scheme", [.i32(0)])
            _ = try runtime.call("iso_hot_render", [])
            XCTAssertNotEqual(stream, dark, "switching back to light changed nothing")
        }
    }

    /// The Apple wasm tier's DI path end-to-end, on the fully generic seams:
    /// the host installs the app's dependency table (the generated
    /// `Dependencies` builders over shared/platform_services, and an HTTP host
    /// over shared/isomer_network_host's), the guest's runtime installs the
    /// HTTP host as Foundation's transport at start, the app's `URLSession`
    /// sends through it, and the host's `async` implementation answers through
    /// the runtime's `resumeAsync` → the guest's fixed `swift_ffi_async_resume`
    /// — no app-specific export anywhere.
    /// On WasmKit, whose swift_ffi transport is the Swift host runtime's
    /// (SwiftFFIHostRuntime).
    func testWasmKitNetworkingDependencyInjection() async throws {
        try await Self.exerciseNetworkingDI(
            WasmKitRuntime(), name: "WasmKit",
            wasm: Self.artifactBytes("wasm/example_full_feature/example_full.wasm"))
    }

    /// The threaded tap counter (wasm32-unknown-wasip1-threads: shared
    /// memory, wasi.thread-spawn) on WasmKit's WASI Threads.
    func testWasmKitRunsTheThreadedReactor() throws {
        guard WasmKitRuntime.canRunThreads else { throw XCTSkip("WasmKit can make no shared memory here") }
        try MainActor.assumeIsolated {
            try Self.exercise(
                WasmKitRuntime(), name: "WasmKit-threads",
                wasm: Self.artifactBytes("wasm/tap_counter_feature/tap_counter_threads_release.wasm"))
        }
    }

    /// The DI path on the threaded full app: the dependencies' calls and
    /// the main actor on the host's thread, the app's other tasks on the
    /// guest's own pool of threads.
    func testWasmKitThreadedNetworkingDependencyInjection() async throws {
        guard WasmKitRuntime.canRunThreads else { throw XCTSkip("WasmKit can make no shared memory here") }
        try await Self.exerciseNetworkingDI(
            WasmKitRuntime(), name: "WasmKit-threads",
            wasm: Self.artifactBytes("wasm/example_full_feature/example_full_threads.wasm"))
    }

    /// An HTTP host whose `send` records the URL and answers a canned
    /// Pokédex list — an `async throws` host implementation, like WasmView's
    /// URLSession one.
    private final class RecordingHTTP: IsomerNetworkWasmHost.HTTPHost {
        var requests: [String] = []
        func send(method: String, url: String, headers: String, body: [UInt8], timeout: Double) async throws
            -> HTTPHostResponse
        {
            requests.append(url)
            return HTTPHostResponse(
                status: 200, headers: #"[["Content-Type","application/json"]]"#,
                body: Array(#"{"results":[{"name":"bulbasaur","url":"https://pokeapi.co/api/v2/pokemon/1/"}]}"#.utf8),
                url: "")
        }
    }

    @MainActor
    private static func exerciseNetworkingDI(
        _ runtime: any WasmRuntime, name: String, wasm: [UInt8]
    ) async throws {
        setenv("ISO_OPEN_APP", "pokedex", 1)
        defer { unsetenv("ISO_OPEN_APP") }

        var stream: [UInt8] = []
        let imports = WasmHostImports(
            onRenderTree: { stream.append(contentsOf: $0) },
            onLog: { print("[\(name) log] \($0)") },
            epochMillis: { Date().timeIntervalSince1970 * 1000 },
            onScheduleRender: {}
        )

        let service = RecordingHTTP()
        var deps = applePlatformDependencies(namespace: "wasm_engine_tests")
        deps[IsomerNetworkWasmHost.NetworkHostKey.isomerHTTP.rawValue] = IsomerNetworkWasmHost.Dependencies.hTTPHost { service }
        runtime.installDependencies(prefix: platformServicesFFIPrefix, deps)
        try runtime.launch(wasm: wasm, hostImports: imports)

        _ = try runtime.call("iso_hot_start", [.f64(390), .f64(680)])
        _ = try runtime.call("iso_hot_render", [])
        // The Pokedex onAppear starts a Task that awaits URLSession: let the
        // guest's queued jobs run (a real host drains them on the main queue),
        // then let the host-side async answer land and the resumed task run.
        // (With guest threads the request is made on one of them: give it
        // time, not just turns of the main actor.)
        for _ in 0..<400 where service.requests.isEmpty {
            runtime.pumpGuestJobs()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(service.requests.isEmpty, "\(name): Pokedex onAppear should request through the injected HTTP host")
        guard !service.requests.isEmpty else { return }
        XCTAssertTrue(service.requests[0].contains("pokeapi.co"), "\(name): unexpected URL \(service.requests[0])")

        // The patch stream is cumulative: a host that renders as part of its
        // job pump may have emitted the list already.
        for _ in 0..<40 where !Self.contains(stream, "ulbasaur") {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            runtime.pumpGuestJobs()
            _ = try runtime.call("iso_hot_render", [])
        }
        XCTAssertTrue(Self.contains(stream, "ulbasaur"), "\(name): the awaited fetch should render the Pokedex list")
    }

    @MainActor
    private static func exercise(
        _ runtime: any WasmRuntime, name: String, wasm: [UInt8]
    ) throws {
        var stream: [UInt8] = []
        let imports = WasmHostImports(
            onRenderTree: { stream.append(contentsOf: $0) },
            onLog: { _ in },
            epochMillis: { Date().timeIntervalSince1970 * 1000 },
            onScheduleRender: {}
        )

        let launchStart = Date()
        try runtime.launch(wasm: wasm, hostImports: imports)
        _ = try runtime.call("iso_hot_start", [.f64(390), .f64(680)])
        _ = try runtime.call("iso_hot_render", [])
        let startupMs = Date().timeIntervalSince(launchStart) * 1000

        XCTAssertTrue(
            Self.contains(stream, "Tap me"),
            "\(name): first frame lacks the counter button")

        // A tap: send the button's tap event by node id (the exact path a
        // host takes — IsomerTreeView sends the tree node's `tap` id).
        guard let tapID = Self.firstTapID(in: stream) else {
            XCTFail("\(name): no tap id in the first frame"); return
        }
        stream.removeAll()
        let tapStart = Date()
        Self.send(runtime, id: tapID, value: "")
        _ = try runtime.call("iso_hot_render", [])
        let tapMs = Date().timeIntervalSince(tapStart) * 1000

        if !Self.contains(stream, "Tapped 1 time") {
            let ascii = String(bytes: stream.filter { $0 >= 0x20 && $0 < 0x7f }, encoding: .utf8) ?? ""
            print("[wasm-engine] \(name): tapID=\(tapID) post-tap stream (\(stream.count)B): \(ascii.prefix(300))")
        }
        XCTAssertTrue(
            Self.contains(stream, "Tapped 1 time"),
            "\(name): tap did not produce the incremented label")

        print("[wasm-engine] \(name): startup=\(Int(startupMs))ms tap=\(String(format: "%.2f", tapMs))ms")
    }

    // MARK: - Benchmark (opt-in)

    /// What a drag costs under each engine: launch, the first frame, then
    /// `changed` events each followed by a render — a finger moving across a
    /// view with a DragGesture. Runs only when `ISO_BENCH_WASM` names a
    /// reactor (a Playground build of the 2048 sample, say): `bazel test
    /// //tests/wasm_engines:wasm_engine_tests
    /// --test_env=ISO_BENCH_WASM=/tmp/Game2048.wasm --test_output=all
    /// --test_filter=WasmEngineTests/testBenchmarkDrag`.
    func testBenchmarkDrag() throws {
        guard let path = ProcessInfo.processInfo.environment["ISO_BENCH_WASM"], !path.isEmpty else { return }
        let wasm = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        try MainActor.assumeIsolated {
            for (name, make) in Self.engines {
                let runtime = make()
                var stream: [UInt8] = []
                var wantsRender = false
                let imports = WasmHostImports(
                    onRenderTree: { stream.append(contentsOf: $0) }, onLog: { _ in },
                    epochMillis: { Date().timeIntervalSince1970 * 1000 }, onScheduleRender: { wantsRender = true })
                let t0 = Date()
                do { try runtime.launch(wasm: wasm, hostImports: imports) } catch { print("[wasm-bench] \(name): launch failed: \(error)"); continue }
                let launchMs = Date().timeIntervalSince(t0) * 1000
                let t1 = Date()
                _ = try runtime.call("iso_hot_start", [.f64(390), .f64(680)])
                _ = try runtime.call("iso_hot_render", [])
                let firstMs = Date().timeIntervalSince(t1) * 1000
                guard let dragID = Self.firstID(in: stream, suffix: ".drag") else { print("[wasm-bench] \(name): no drag id"); continue }
                var samples: [Double] = []
                for step in 1...60 {
                    stream.removeAll(keepingCapacity: true)
                    let t = Date()
                    Self.send(runtime, id: dragID, value: "changed:\(step * 2),0")
                    _ = try runtime.call("iso_hot_render", [])
                    samples.append(Date().timeIntervalSince(t) * 1000)
                }
                // The release: the move, and the frames of its animation.
                let t2 = Date()
                Self.send(runtime, id: dragID, value: "ended:120,0")
                var frames = 0
                repeat { wantsRender = false; _ = try runtime.call("iso_hot_render", []); frames += 1 } while wantsRender && frames < 40
                let endMs = Date().timeIntervalSince(t2) * 1000
                samples.sort()
                print(String(format: "[wasm-bench] %@: launch=%.0fms first-frame=%.0fms drag median=%.2fms p90=%.2fms max=%.2fms release=%.1fms/%d frames",
                             name, launchMs, firstMs, samples[samples.count / 2], samples[samples.count * 9 / 10], samples.last!, endMs, frames))
            }
        }
    }

    /// Delivers a host event by node id — the same alloc/write/event/free
    /// sequence `WasmFeatureRuntime.send` performs.
    @MainActor
    private static func send(_ runtime: any WasmRuntime, id: String, value: String) {
        let idBytes = Array(id.utf8)
        let valueBytes = Array(value.utf8)
        guard case .i32(let idPtr)? = try? runtime.call("iso_hot_alloc", [.i32(Int32(idBytes.count))]),
            case .i32(let valuePtr)? = try? runtime.call("iso_hot_alloc", [.i32(Int32(valueBytes.count))])
        else { return }
        runtime.writeBytes(UInt32(idPtr), idBytes)
        runtime.writeBytes(UInt32(valuePtr), valueBytes)
        _ = try? runtime.call(
            "iso_hot_event",
            [.i32(idPtr), .i32(Int32(idBytes.count)), .i32(valuePtr), .i32(Int32(valueBytes.count))])
        _ = try? runtime.call("iso_hot_free", [.i32(idPtr)])
        _ = try? runtime.call("iso_hot_free", [.i32(valuePtr)])
    }

    // MARK: - Support

    private static func reactorBytes() throws -> [UInt8] {
        try artifactBytes("wasm/tap_counter_feature/tap_counter_release.wasm")
    }

    private static func artifactBytes(_ relative: String) throws -> [UInt8] {
        let dir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] ?? ""
        let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(workspace)/\(relative)"))
        return [UInt8](data)
    }

    /// Finds the first tap-handler id in a serialized tree: an ASCII run of
    /// digits/dots ending in ".tap" (ids are "<node-path>.tap").
    private static func firstTapID(in bytes: [UInt8]) -> String? { firstID(in: bytes, suffix: ".tap") }

    private static func firstID(in bytes: [UInt8], suffix: String) -> String? {
        let suffix = Array(suffix.utf8)
        var i = 0
        while i + suffix.count <= bytes.count {
            if Array(bytes[i..<(i + suffix.count)]) == suffix {
                var start = i
                while start > 0 {
                    let c = bytes[start - 1]
                    // Ids are "<path>.tap" with paths like "n.0.0.1" — walk
                    // back over [a-z0-9.].
                    if (c >= 0x30 && c <= 0x39) || c == 0x2E || (c >= 0x61 && c <= 0x7A) {
                        start -= 1
                    } else { break }
                }
                if start < i {
                    var id = String(decoding: bytes[start..<(i + suffix.count)], as: UTF8.self)
                    while id.hasPrefix(".") { id.removeFirst() }
                    return id
                }
            }
            i += 1
        }
        return nil
    }

    private static func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard !n.isEmpty, haystack.count >= n.count else { return false }
        return haystack.withUnsafeBytes { raw in
            Data(raw).range(of: Data(n)) != nil
        }
    }
}
