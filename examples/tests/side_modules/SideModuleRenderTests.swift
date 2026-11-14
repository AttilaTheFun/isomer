// The Storybook's app as a side module over a runtime module renders, under
// WasmKit, exactly what its self-contained reactor renders: the first frame,
// then a tap on every tap target of the first frame (each story's page), the
// render streams compared byte for byte. The time the guest reads is fixed
// and its Swift jobs aren't run (nothing drains the main queue while the
// test holds it), so both runs are deterministic.

import Foundation
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import XCTest

@MainActor
final class SideModuleRenderTests: XCTestCase {
    func artifact(_ relative: String) throws -> [UInt8] {
        let dir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] ?? ""
        let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(workspace)/\(relative)")))
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
        _ = try runtime.call("iso_hot_render", [])
        let ids = TapTargets.ids(stream)
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
        return (stream, ids.count)
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
}
