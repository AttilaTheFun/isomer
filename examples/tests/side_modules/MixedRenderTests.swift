// The Storybook's app as a side module over its runtime module in mixed mode
// (MixedWasmKitRuntime: native copies of the runtime's hot functions, the
// guest on its own thread) renders what its self-contained reactor renders
// under WasmKit, byte for byte: the first frame, then a tap on every tap
// target of the first frame. Calls into the mixed runtime are queued for its
// thread, and the guest's calls into the host (host values, frames) come to
// the main thread, so after each step the test runs the main thread's loop
// until the guest's thread is idle.
//
// And a runtime released lets the next one launch with the native part: a
// feature's reload (a side module can't be unloaded) is a new runtime over a
// fresh instance of the native part, rendering the same, and
// WasmFeatureRuntime's reload releases the old runtime before it makes the
// new one, so the new one runs natively too.

import Foundation
import IsomerMixedRuntime
import IsomerWasmHost
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import SwiftFFIWasmHost
import XCTest

/// The Storybook as a host loads a feature in mixed mode: its runtime module
/// launched, then its app over it as a side module.
@MainActor
final class StorybookFeature: WasmRuntime {
    let mixed: MixedWasmKitRuntime
    let side: [UInt8]

    init(_ mixed: MixedWasmKitRuntime, side: [UInt8]) {
        self.mixed = mixed
        self.side = side
    }

    func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        try mixed.launch(wasm: wasm, hostImports: hostImports)
        try mixed.loadSideModule(wasm: side)
    }

    func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {
        mixed.installDependencies(prefix: prefix, dependencies)
    }

    func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? { try mixed.call(name, args) }
    func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] { mixed.readBytes(ptr, len) }
    func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) { mixed.writeBytes(ptr, bytes) }
    func pumpGuestJobs() { mixed.pumpGuestJobs() }
    func renderPending() { mixed.renderPending() }
    func release() { mixed.release() }
}

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

    func nativePart() throws -> MixedNativePart {
        MixedNativePart(
            shim: try artifact("tests/side_modules/storybook_native_generated/shim.wasm"),
            slots: try text("tests/side_modules/storybook_native_generated/slots.txt"),
            routed: Set(try text("tests/side_modules/storybook_routed.txt").split(separator: "\n").map(String.init)))
    }

    /// The main thread answers the guest (host values) and takes its frames
    /// until the guest's thread is idle; then once more for what it sent
    /// last.
    func settle(_ mixed: MixedWasmKitRuntime) {
        let deadline = Date(timeIntervalSinceNow: 60)
        repeat {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        } while !mixed.isIdle && Date() < deadline
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }

    /// Native code runs unless ISO_MIXED_NATIVE=0 (or WasmKit couldn't
    /// reserve guard pages, which a Mac and Linux always can).
    var expectsNative: Bool { ProcessInfo.processInfo.environment["ISO_MIXED_NATIVE"] != "0" }

    /// A mixed runtime launched over the Storybook's runtime module with its
    /// app as a side module, driven: its taps and its render stream.
    func launchAndDrive(_ mixed: MixedWasmKitRuntime) throws -> (taps: Int, stream: [UInt8]) {
        var stream: [UInt8] = []
        try mixed.launch(wasm: try artifact("tests/side_modules/storybook_runtime.wasm"), hostImports: imports { stream += $0 })
        try mixed.loadSideModule(wasm: try artifact("tests/side_modules/storybook_side.wasm"))
        let taps = try drive(mixed, stream: { stream }, settle: { settle(mixed) })
        return (taps, stream)
    }

    func testMixedRendersAsTheReactor() throws {
        var reactorStream: [UInt8] = []
        let reactor = WasmKitRuntime()
        try reactor.launch(wasm: try artifact("wasm/example_full_feature/example_full.wasm"), hostImports: imports { reactorStream += $0 })
        let reactorTaps = try drive(reactor, stream: { reactorStream }, settle: {})

        let mixed = MixedWasmKitRuntime(native: try nativePart())
        defer { mixed.release() }
        let (mixedTaps, mixedStream) = try launchAndDrive(mixed)

        XCTAssertEqual(mixed.isNative, expectsNative)
        XCTAssertGreaterThan(reactorTaps, 50)
        XCTAssertEqual(mixedTaps, reactorTaps)
        XCTAssertEqual(mixedStream.count, reactorStream.count)
        XCTAssertTrue(mixedStream == reactorStream, "the render streams differ")
    }

    /// The native part is one a process: a second runtime can't launch while
    /// the first holds it, and can once the first is released (by
    /// `release()`, or by its deinit), over a fresh instance of the native
    /// part, rendering what the first rendered.
    func testReleasedRuntimeHandsTheNativePartOver() throws {
        let native = try nativePart()
        let first = MixedWasmKitRuntime(native: native)
        let (firstTaps, firstStream) = try launchAndDrive(first)
        XCTAssertEqual(first.isNative, expectsNative)
        XCTAssertGreaterThan(firstTaps, 50)
        XCTAssertFalse(MixedWasmKitRuntime.isAvailable)

        // Held: another launch is refused, as before.
        let refused = MixedWasmKitRuntime(native: native)
        XCTAssertThrowsError(try refused.launch(wasm: try artifact("tests/side_modules/storybook_runtime.wasm"), hostImports: imports { _ in })) {
            guard case MixedRuntimeError.alreadyRunning = $0 else { return XCTFail("\($0)") }
        }
        refused.release()
        XCTAssertFalse(MixedWasmKitRuntime.isAvailable)

        // Released: calls fail cleanly; the next launch waits for its
        // guest's hand-over (something queued last, to finish first).
        _ = try first.call("iso_hot_render", [])
        first.release()
        XCTAssertTrue(MixedWasmKitRuntime.isAvailable)
        XCTAssertThrowsError(try first.call("iso_hot_render", [])) {
            guard case MixedRuntimeError.released = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try first.call("iso_hot_alloc", [.i32(4)]))
        XCTAssertEqual(first.readBytes(0, 4), [])
        first.writeBytes(0, [1])
        first.renderPending()
        first.release()

        // The second over a fresh instance renders the same; let go of
        // without `release()`, its deinit hands over.
        do {
            let second = MixedWasmKitRuntime(native: native)
            let (secondTaps, secondStream) = try launchAndDrive(second)
            XCTAssertEqual(second.isNative, expectsNative)
            XCTAssertEqual(secondTaps, firstTaps)
            XCTAssertEqual(secondStream.count, firstStream.count)
            XCTAssertTrue(secondStream == firstStream, "the second runtime's render stream differs from the first's")
        }

        // So a third launches: its first frame is the first runtime's.
        let third = MixedWasmKitRuntime(native: native)
        defer { third.release() }
        var thirdStream: [UInt8] = []
        try third.launch(wasm: try artifact("tests/side_modules/storybook_runtime.wasm"), hostImports: imports { thirdStream += $0 })
        try third.loadSideModule(wasm: try artifact("tests/side_modules/storybook_side.wasm"))
        _ = try third.call("iso_hot_start", [.f64(1024), .f64(768)])
        _ = try third.call("iso_hot_render", [])
        settle(third)
        XCTAssertEqual(third.isNative, expectsNative)
        XCTAssertFalse(thirdStream.isEmpty)
        XCTAssertTrue(firstStream.starts(with: thirdStream), "the third runtime's first frame differs from the first's")
    }

    /// WasmFeatureRuntime's reload with a mixed runtime: the old runtime is
    /// released before the new one is made, so the new one gets the native
    /// part (rather than failing, and a host falling back to the
    /// interpreter), and the reloaded feature renders its first frame again.
    func testReloadHandsTheNativePartOver() throws {
        let native = try nativePart()
        let side = try artifact("tests/side_modules/storybook_side.wasm")
        let bundle = WasmServiceBundle(label: "storybook", wasm: try artifact("tests/side_modules/storybook_runtime.wasm"))
        var made: [MixedWasmKitRuntime] = []
        let feature = WasmFeatureRuntime(runtime: { _ in
            // What a host's factory would ask before choosing mixed mode.
            XCTAssertTrue(MixedWasmKitRuntime.isAvailable)
            let mixed = MixedWasmKitRuntime(native: native)
            made.append(mixed)
            return StorybookFeature(mixed, side: side)
        })
        var trees: [[UInt8]] = []
        feature.onTree = { trees.append($0) }
        feature.resize(width: 1024, height: 768)
        defer { feature.forceShutdown() }

        /// Loads the bundle and runs the main thread until its first frame.
        func load() -> [UInt8] {
            trees = []
            feature.load(bundle: bundle)
            let deadline = Date(timeIntervalSinceNow: 60)
            while (trees.isEmpty || !(made.last?.isIdle ?? true)) && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
            return trees.first ?? []
        }

        let first = load()
        XCTAssertEqual(feature.status, "Loaded storybook")
        XCTAssertFalse(first.isEmpty)
        let reloaded = load()
        XCTAssertEqual(feature.status, "Loaded storybook")
        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(made.allSatisfy { $0.isNative == expectsNative })
        XCTAssertThrowsError(try made[0].call("iso_hot_render", []))
        XCTAssertTrue(reloaded == first, "the reloaded feature's first frame differs")
    }
}
