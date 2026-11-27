// The threaded reactor on WasmKit alone, on every native host WasmKit runs
// on (the Mac and Linux; wasm_engine_tests, beside JSC and WasmEdge, is the
// Mac's alone): WasmKit makes a shared memory here (`canRunThreads`), and the
// tap counter built for wasm32-unknown-wasip1-threads (Isomer's threads SDK:
// Swift 6.4.2 with swiftlang/swift#92018, libc++ with WebAssembly exceptions)
// launches, draws its first frame and answers a tap as the single-threaded
// build does, byte for byte.

import Foundation
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import XCTest

final class WasmKitThreadsTests: XCTestCase {
    /// A 64-bit Mac or Linux has the guard pages and signal handling a
    /// shared memory needs: a threaded reactor must be able to run here.
    func testWasmKitCanRunThreadsHere() {
        XCTAssertTrue(WasmKitRuntime.canRunThreads, "WasmKit made no shared memory on this host")
    }

    /// The threaded tap counter: shared memory imported, `wasi.thread-spawn`,
    /// the guest's main actor on this thread.
    func testThreadedTapCounter() throws {
        guard WasmKitRuntime.canRunThreads else { throw XCTSkip("WasmKit can make no shared memory here") }
        try MainActor.assumeIsolated {
            let threaded = try Self.exercise(
                name: "WasmKit-threads",
                wasm: Self.artifactBytes("wasm/tap_counter_feature/tap_counter_threads_release.wasm"))
            let single = try Self.exercise(
                name: "WasmKit",
                wasm: Self.artifactBytes("wasm/tap_counter_feature/tap_counter_release.wasm"))
            // The tree doesn't depend on the threads the guest has.
            XCTAssertEqual(threaded.first, single.first, "the threaded build's first frame differs")
            XCTAssertEqual(threaded.next, single.next, "the threaded build's frame after the tap differs")
        }
    }

    // MARK: - Support (as WasmEngineTests' own)

    /// Runtimes kept for the life of the process: a threaded instance's
    /// guest threads are WasmKit's process-scoped WASI Threads'.
    @MainActor private static var kept: [WasmKitRuntime] = []

    @MainActor
    private static func exercise(name: String, wasm: [UInt8]) throws -> (first: [UInt8], next: [UInt8]) {
        var stream: [UInt8] = []
        let imports = WasmHostImports(
            onRenderTree: { stream.append(contentsOf: $0) },
            onLog: { print("[\(name) log] \($0)") },
            epochMillis: { 1_700_000_000_000 },
            onScheduleRender: {}
        )
        let runtime = WasmKitRuntime()
        kept.append(runtime)
        try runtime.launch(wasm: wasm, hostImports: imports)
        _ = try runtime.call("iso_hot_start", [.f64(390), .f64(680)])
        _ = try runtime.call("iso_hot_render", [])
        XCTAssertTrue(contains(stream, "Tap me"), "\(name): first frame lacks the counter button")
        let first = stream
        guard let tapID = firstID(in: stream, suffix: ".tap") else {
            XCTFail("\(name): no tap id in the first frame")
            return (first, [])
        }
        stream.removeAll()
        send(runtime, id: tapID, value: "")
        _ = try runtime.call("iso_hot_render", [])
        XCTAssertTrue(contains(stream, "Tapped 1 time"), "\(name): tap did not produce the incremented label")
        return (first, stream)
    }

    /// A host event by node id: the alloc/write/event/free sequence
    /// `WasmFeatureRuntime.send` performs.
    @MainActor
    private static func send(_ runtime: WasmKitRuntime, id: String, value: String) {
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

    private static func artifactBytes(_ relative: String) throws -> [UInt8] {
        let dir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] ?? ""
        let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(workspace)/\(relative)")))
    }

    /// The first "<path>.tap" id in a serialized tree.
    private static func firstID(in bytes: [UInt8], suffix: String) -> String? {
        let suffix = Array(suffix.utf8)
        var i = 0
        while i + suffix.count <= bytes.count {
            if Array(bytes[i..<(i + suffix.count)]) == suffix {
                var start = i
                while start > 0 {
                    let c = bytes[start - 1]
                    if (c >= 0x30 && c <= 0x39) || c == 0x2E || (c >= 0x61 && c <= 0x7A) { start -= 1 } else { break }
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
        return haystack.withUnsafeBytes { Data($0).range(of: Data(n)) != nil }
    }
}
