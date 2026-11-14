// The Storybook's app as a side module over its runtime module in mixed mode
// (MixedWasmKitRuntime: native copies of the runtime's hot functions, the
// guest on its own thread) renders what its self-contained reactor renders
// under WasmKit, byte for byte: the first frame, then a tap on every tap
// target of the first frame. Calls into the mixed runtime are queued for its
// thread, and the guest's calls into the host (host values, frames) come to
// the main thread, so after each step the test runs the main thread's loop
// until the guest's thread is idle.

import Foundation
import IsomerMixedRuntime
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import XCTest

@MainActor
final class MixedRenderTests: XCTestCase {
    func artifact(_ relative: String) throws -> [UInt8] {
        let dir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] ?? ""
        let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(workspace)/\(relative)")))
    }

    func text(_ relative: String) throws -> String { String(decoding: try artifact(relative), as: UTF8.self) }

    /// Drives `runtime`: renders, taps each first-frame tap target, renders
    /// after each; `settle` after each step (the mixed runtime's queue).
    func drive(_ runtime: any WasmRuntime, stream: () -> [UInt8], settle: () throws -> Void) throws -> Int {
        _ = try runtime.call("iso_hot_start", [.f64(1024), .f64(768)])
        _ = try runtime.call("iso_hot_render", [])
        try settle()
        let ids = TapTargets.ids(stream())
        for id in ids {
            let idBytes = Array(id.utf8)
            let idPointer = try runtime.call("iso_hot_alloc", [.i32(Int32(idBytes.count))])?.u32Value ?? 0
            runtime.writeBytes(idPointer, idBytes)
            let valuePointer = try runtime.call("iso_hot_alloc", [.i32(1)])?.u32Value ?? 0
            _ = try runtime.call("iso_hot_event", [
                .i32(Int32(bitPattern: idPointer)), .i32(Int32(idBytes.count)), .i32(Int32(bitPattern: valuePointer)), .i32(0),
            ])
            _ = try runtime.call("iso_hot_render", [])
            try settle()
        }
        return ids.count
    }

    func imports(_ append: @escaping ([UInt8]) -> Void) -> WasmHostImports {
        WasmHostImports(onRenderTree: append, onLog: { print("guest log: \($0)") }, epochMillis: { 1.7e12 }, onScheduleRender: {})
    }

    func testMixedRendersAsTheReactor() throws {
        var reactorStream: [UInt8] = []
        let reactor = WasmKitRuntime()
        try reactor.launch(wasm: try artifact("wasm/example_full_feature/example_full.wasm"), hostImports: imports { reactorStream += $0 })
        let reactorTaps = try drive(reactor, stream: { reactorStream }, settle: {})

        var mixedStream: [UInt8] = []
        let native = MixedNativePart(
            shim: try artifact("tests/side_modules/storybook_native_generated/shim.wasm"),
            slots: try text("tests/side_modules/storybook_native_generated/slots.txt"),
            routed: Set(try text("tests/side_modules/storybook_routed.txt").split(separator: "\n").map(String.init)))
        let mixed = MixedWasmKitRuntime(native: native)
        try mixed.launch(wasm: try artifact("tests/side_modules/storybook_runtime.wasm"), hostImports: imports { mixedStream += $0 })
        try mixed.loadSideModule(wasm: try artifact("tests/side_modules/storybook_side.wasm"))
        let mixedTaps = try drive(mixed, stream: { mixedStream }, settle: {
            // The main thread answers the guest (host values) and takes its
            // frames until the guest's thread is idle; then once more for
            // what it sent last.
            let deadline = Date(timeIntervalSinceNow: 60)
            repeat {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            } while !mixed.isIdle && Date() < deadline
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        })

        XCTAssertGreaterThan(reactorTaps, 50)
        XCTAssertEqual(mixedTaps, reactorTaps)
        XCTAssertEqual(mixedStream.count, reactorStream.count)
        XCTAssertTrue(mixedStream == reactorStream, "the render streams differ")
    }
}
