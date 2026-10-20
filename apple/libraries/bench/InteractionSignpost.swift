// The interaction-benchmark instrumentation: an os_signpost interval that
// brackets exactly the work the app owns for one tap — from the UIEvent
// reaching the tap handler to the update being handed off to Core Animation
// — so an XCUITest `measure` block reads it with XCTOSSignpostMetric:
//
//   XCTOSSignpostMetric(subsystem: "dev.isomer.bench",
//                       category: "Interaction", name: "tap")
//
// Injection latency (test host → app) and render-server present time are
// OUTSIDE the interval by construction, exactly as the methodology requires.
//
//  begin: IsomerTreeBenchHook.onTapReceived — the onTapGesture edge,
//         BEFORE the reactor event is sent.
//  end:   a runloop observer at order 2,500,000 (after Core Animation's commit
//         observer at 2,000,000, in the same before-waiting pass), fired on
//         the first turn whose commit carried a fresh body evaluation
//         (IsomerTreeBenchHook.bodyTick) — i.e. the tap's update is laid
//         out, encoded, and handed to the render server.
//
// Dormant unless `-bench-signpost` / ISO_BENCH_SIGNPOST=1. Installed by the
// `:boot` constructor with zero app-source changes, like the startup harness.

#if os(iOS)
import Foundation
import UIKit
import os.signpost
#if canImport(IsomerTree)
import IsomerTree
#endif

@MainActor
public final class InteractionSignpost {
    public static let shared = InteractionSignpost()

    private let log = OSLog(subsystem: "dev.isomer.bench", category: "Interaction")
    private var observer: CFRunLoopObserver?
    private var openID: OSSignpostID?
    private var bodyTickedSinceTap = false

    public static func installIfRequested() {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("-bench-signpost")
            || info.environment["ISO_BENCH_SIGNPOST"] == "1" else { return }
        shared.install()
    }

    private var installed = false

    /// The UIEvent → handler edge, callable from ANY cell's action.
    public static func tapReceived() {
        shared.beginTap()
    }

    /// The cell applied its update this runloop turn (BenchHarness routes its
    /// universal noteBodyTick signal here).
    public static func noteUpdate() {
        guard shared.installed else { return }
        shared.bodyTickedSinceTap = true
    }

    private func install() {
        installed = true
        BenchHarness.onUpdateSignal = { InteractionSignpost.noteUpdate() }
        #if canImport(IsomerTree)
        IsomerTreeBenchHook.onTapReceived = { [weak self] in
            self?.beginTap()
        }
        #endif

        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_500_000
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.afterCommit() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        NSLog("[bench] interaction signpost armed")
    }

    /// The UIEvent → handler edge: open a fresh interval. If one is somehow
    /// still open (a tap produced no commit), close it first so intervals
    /// never nest.
    private func beginTap() {
        guard installed else { return }
        if openID != nil {
            os_signpost(.end, log: log, name: "tap", signpostID: openID!)
        }
        let id = OSSignpostID(log: log)
        openID = id
        bodyTickedSinceTap = false
        os_signpost(.begin, log: log, name: "tap", signpostID: id)
    }

    private func afterCommit() {
        guard let id = openID, bodyTickedSinceTap else { return }
        os_signpost(.end, log: log, name: "tap", signpostID: id)
        openID = nil
        bodyTickedSinceTap = false
    }
}
#endif

/// C-visible entry: the `:boot` constructor installs BOTH the startup harness
/// and (when requested) the interaction signpost.
@_cdecl("iso_bench_install_signpost")
public func iso_bench_install_signpost() {
    #if os(iOS)
    MainActor.assumeIsolated {
        InteractionSignpost.installIfRequested()
    }
    #endif
}
