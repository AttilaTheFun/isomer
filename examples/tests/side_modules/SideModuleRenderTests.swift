// The Storybook's app as a side module over a runtime module renders, under
// WasmKit, exactly what its self-contained reactor renders: the first frame,
// then a tap on every tap target of the first frame (each story's page), the
// render streams compared byte for byte. The time the guest reads is fixed
// and its Swift jobs aren't run (nothing drains the main queue while the
// test holds it), so both runs are deterministic.
//
// And the same feature as a host loads it: a side-module bundle over the
// runtime module given to WasmFeatureRuntime, both read from their files by
// the engine (`WasmModuleSource.file`), renders the same stream.

import Foundation
import IsomerWasmHost
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import SwiftFFIWasmHost
import XCTest

@MainActor
final class SideModuleRenderTests: XCTestCase {
    func path(_ relative: String) -> String {
        let dir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] ?? ""
        let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
        return "\(dir)/\(workspace)/\(relative)"
    }

    func artifact(_ relative: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(fileURLWithPath: path(relative))))
    }

    /// Launches `main` (and loads `side` over it), then renders, taps every
    /// first-frame tap target in turn, rendering after each; the stream.
    func drive(main: [UInt8], side: [UInt8]?) throws -> (stream: [UInt8], taps: Int) {
        var stream: [UInt8] = []
        let runtime = WasmKitRuntime()
        try runtime.launch(wasm: main, hostImports: WasmHostImports(
            onRenderTree: { stream.append(contentsOf: $0) },
            onLog: { _ in },
            epochMillis: { 1.7e12 },
            onScheduleRender: {}))
        if let side { try runtime.loadSideModule(wasm: side) }
        _ = try runtime.call("iso_hot_start", [.f64(1024), .f64(768)])
        let taps = try tapThrough(runtime, stream: { stream })
        return (stream, taps)
    }

    /// Renders a started feature, then taps every first-frame tap target in
    /// turn, rendering after each; the taps.
    func tapThrough(_ runtime: any WasmRuntime, stream: () -> [UInt8]) throws -> Int {
        _ = try runtime.call("iso_hot_render", [])
        let ids = TapTargets.ids(stream())
        XCTAssertFalse(ids.isEmpty, "no tap targets in the first frame")
        for id in ids {
            let idBytes = Array(id.utf8)
            let idPointer = try runtime.call("iso_hot_alloc", [.i32(Int32(idBytes.count))])?.u32Value ?? 0
            runtime.writeBytes(idPointer, idBytes)
            let valuePointer = try runtime.call("iso_hot_alloc", [.i32(1)])?.u32Value ?? 0
            _ = try runtime.call("iso_hot_event", [
                .i32(Int32(bitPattern: idPointer)), .i32(Int32(idBytes.count)), .i32(Int32(bitPattern: valuePointer)), .i32(0),
            ])
            _ = try runtime.call("iso_hot_render", [])
        }
        return ids.count
    }

    func testSideModuleRendersAsTheReactor() throws {
        let reactor = try drive(main: try artifact("wasm/example_full_feature/example_full.wasm"), side: nil)
        let linked = try drive(
            main: try artifact("tests/side_modules/storybook_runtime.wasm"),
            side: try artifact("tests/side_modules/storybook_side.wasm"))
        XCTAssertGreaterThan(reactor.taps, 50)
        XCTAssertEqual(linked.taps, reactor.taps)
        XCTAssertEqual(linked.stream.count, reactor.stream.count)
        XCTAssertTrue(linked.stream == reactor.stream, "the render streams differ")
    }

    /// The feature as a host loads it: WasmFeatureRuntime given the runtime
    /// module once (interpreted, read from its file by the engine) and the
    /// side module as a bundle (from its file too) renders what the reactor
    /// renders, tap for tap.
    func testFeatureOverRuntimeModuleRendersAsTheReactor() throws {
        let reactor = try drive(main: try artifact("wasm/example_full_feature/example_full.wasm"), side: nil)

        var stream: [UInt8] = []
        let feature = WasmFeatureRuntime(runtime: { _ in
            XCTFail("a side-module bundle made a reactor's engine")
            return WasmKitRuntime()
        })
        defer { feature.forceShutdown() }
        feature.epochMillis = { 1.7e12 }
        feature.onTree = { stream += $0 }
        // Started at the size the reactor was; frames come from the test's
        // calls (the frame the load schedules is never pumped: nothing runs
        // the main queue).
        feature.resize(width: 1024, height: 768)
        feature.runtimeModule = .interpreted(
            name: "storybook_runtime", source: .file(path: path("tests/side_modules/storybook_runtime.wasm")))
        feature.load(bundle: WasmServiceBundle(
            label: "storybook", module: .file(path: path("tests/side_modules/storybook_side.wasm")),
            kind: .sideModule(runtime: "storybook_runtime")))
        XCTAssertEqual(feature.status, "Loaded storybook")
        let runtime = try XCTUnwrap(feature.engineRuntime)
        XCTAssertTrue(runtime is WasmKitRuntime)
        let taps = try tapThrough(runtime, stream: { stream })

        XCTAssertGreaterThan(reactor.taps, 50)
        XCTAssertEqual(taps, reactor.taps)
        XCTAssertEqual(stream.count, reactor.stream.count)
        XCTAssertTrue(stream == reactor.stream, "the render streams differ")
    }

    /// A side module naming another runtime build, or loaded with none
    /// given, is refused (a side module binds to its runtime's exact build).
    func testSideModuleOfAnotherRuntimeIsRefused() throws {
        let feature = WasmFeatureRuntime(runtime: { _ in WasmKitRuntime() })
        let bundle = WasmServiceBundle(
            label: "storybook", module: .file(path: path("tests/side_modules/storybook_side.wasm")),
            kind: .sideModule(runtime: "storybook_runtime"))
        feature.load(bundle: bundle)
        XCTAssertTrue(feature.status.hasPrefix("Load failed"), feature.status)
        XCTAssertNil(feature.engineRuntime)
        feature.runtimeModule = .interpreted(
            name: "another_runtime", source: .file(path: path("tests/side_modules/storybook_runtime.wasm")))
        feature.load(bundle: bundle)
        XCTAssertTrue(feature.status.contains("not of the host's (another_runtime)"), feature.status)
        XCTAssertNil(feature.engineRuntime)
    }

    /// A module read from its file is the bytes; so is a region of one (an
    /// Android asset in its APK), and a region past the file's end is an
    /// error, not a short module.
    func testModuleFromAFileIsItsBytes() throws {
        let file = path("tests/side_modules/storybook_side.wasm")
        let bytes = try artifact("tests/side_modules/storybook_side.wasm")
        XCTAssertGreaterThan(bytes.count, 4096)
        XCTAssertTrue(try WasmModuleSource.file(path: file).read() == bytes)
        XCTAssertTrue(try WasmModuleSource.bytes(bytes).read() == bytes)
        XCTAssertEqual(
            try WasmModuleSource.file(path: file, offset: 1000, length: 3000).read(), Array(bytes[1000..<4000]))
        XCTAssertEqual(try WasmModuleSource.file(path: file, offset: 1000).read(), Array(bytes[1000...]))
        XCTAssertThrowsError(try WasmModuleSource.file(path: file, offset: bytes.count - 10, length: 20).read())
        XCTAssertThrowsError(try WasmModuleSource.file(path: file + ".missing").read())
        // The bundle's bytes, as hosts that read `wasm` see them.
        XCTAssertTrue(WasmServiceBundle(label: "side", module: .file(path: file)).wasm == bytes)
    }
}
