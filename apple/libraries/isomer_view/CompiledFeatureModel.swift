// The compiled engine behind `IsomerView`: the exact in-process analogue
// of a `iso_hot` wasm reactor's glue (examples/wasm/*/HotReloadBridge.swift),
// with the wasm boundary deleted.
//
//   reactor                          | compiled engine (this file)
//   ---------------------------------+--------------------------------------
//   iso_hot_start → bind + start     | start(root:) → bind + installRootView + start
//   SwiftUIRenderer → render_tree()  | SwiftUIRenderer → FlatPatchTree.apply
//   iso_hot_event(id, value)         | send(id:value:) → hostViewEvent
//   iso_hot_render (host pump)       | before-waiting runloop observer → renderFrame
//
// The frame pump mirrors the compiled benchmark cells: state changes mark the
// frame dirty (`scheduleRender`), and a before-waiting runloop observer flushes
// `renderFrame` at the END of the turn that mutated state, so the resulting
// `@Published` tree lands in the same CA commit as any surrounding SwiftUI.
//
// This file deliberately does NOT import SwiftUI: `IsomerCore` reexports
// the reimplementation's own View/StateObject/ObservableObject names, which
// collide with the real ones — the SwiftUI-facing half lives in
// IsomerView.swift, which conversely never imports the core. The two meet
// through `IsomerCoreView` and this model's published `tree`.

import Foundation
public import IsomerSwiftUI
// Scoped: only the observable-object machinery, not SwiftUI's view names
// (this file also sees the core module's).
import protocol SwiftUI.ObservableObject
import struct SwiftUI.Published
import IsomerTree
import IsomerCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The core's view protocol, re-exported so SwiftUI-side code can reference
/// feature roots (`any IsomerCoreView`) without importing the core module.
public typealias IsomerCoreView = IsomerCore.View

@MainActor
final class CompiledFeatureModel: ObservableObject {
    /// The retained render tree, advanced by each tree.fbs Patch the core's
    /// `SwiftUIRenderer` emits (applied in arrival order, never coalesced).
    @Published private(set) var tree: PatchedNode?

    private var started = false
    private var renderScheduled = false
    private var inRender = false
    private var flushObserver: CFRunLoopObserver?

    nonisolated init() {}

    func start(root: @escaping @MainActor () -> any IsomerCoreView, width: Double, height: Double) {
        guard !started else { return }
        started = true
        IsomerCore.Runtime.shared.installRootView(root)  // .embedded integration
        IsomerCore.Renderer.bind(IsomerCore.SwiftUIRenderer { [weak self] bytes in
            guard let self else { return }
            self.tree = FlatPatchTree.apply(patch: bytes, to: self.tree)
        })
        IsomerCore.Runtime.shared.start(
            host: EmbeddedCoreHost(model: self), width: width, height: height)
        scheduleRender()
    }

    /// The `IsomerTreeView` event channel — same contract as the wasm
    /// runtime's `send` (a reactor's `iso_hot_event`).
    func send(id: String, value: String) {
        // The runtime asks for the render the event needs.
        IsomerCore.Runtime.shared.hostViewEvent(id: id, value: value)
    }

    func resize(width: Double, height: Double) {
        guard started else { return }
        IsomerCore.Runtime.shared.resize(width: width, height: height)
    }

    /// The host app's appearance, forwarded into the in-process core so the
    /// compiled feature's adaptive palette matches (the wasm tier's peer of
    /// `iso_hot_set_color_scheme`).
    func setColorScheme(dark: Bool) {
        IsomerCore.Runtime.shared.setSystemColorScheme(dark: dark)
        IsomerCore.Runtime.shared.setNeedsRender()
    }

    /// The system's size classes (each 0 = none, 1 = compact, 2 = regular),
    /// into the in-process core (the wasm tier's `iso_hot_set_size_classes`).
    func setSizeClasses(horizontal: Int32, vertical: Int32) {
        func sizeClass(_ value: Int32) -> IsomerCore.UserInterfaceSizeClass? {
            value == 1 ? .compact : value == 2 ? .regular : nil
        }
        IsomerCore.Runtime.shared.setHostSizeClasses(horizontal: sizeClass(horizontal), vertical: sizeClass(vertical))
    }

    func scheduleRender() {
        renderScheduled = true
        if flushObserver == nil {
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
            ) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.flushIfNeeded() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            flushObserver = observer
        }
        // A schedule arriving off the main runloop's active turn (a URLSession
        // completion hopping queues) still needs a wake-up.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func flushIfNeeded() {
        guard renderScheduled, !inRender else { return }
        renderScheduled = false
        inRender = true
        IsomerCore.Runtime.shared.renderFrame()
        inRender = false
    }

    deinit {
        if let flushObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), flushObserver, .commonModes)
        }
    }
}

// MARK: - Host services

/// The `HostBridge` the embedded compiled core runs against. Under a
/// component-system renderer the core only builds and serializes trees — the
/// draw half inherits the core's no-op defaults; what remains is text
/// measurement (platform fonts), networking, and the render pump.
private final class EmbeddedCoreHost: IsomerSwiftUI.HostBridge {
    private weak var model: CompiledFeatureModel?

    init(model: CompiledFeatureModel) {
        self.model = model
    }

    // HostBridge geometry uses the CORE's CGSize/CGRect (the reimplementation
    // defines its own so non-Apple platforms don't need CoreGraphics);
    // CoreFoundation types are qualified where UIKit needs the real ones.
    func measureText(
        _ text: String, fontSize: Double, weight: Int, wrapWidth: Double?
    ) -> IsomerCore.CGSize {
        let bounds = CoreFoundation.CGSize(
            width: wrapWidth ?? Double.greatestFiniteMagnitude,
            height: Double.greatestFiniteMagnitude)
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: fontSize, weight: Self.uiWeight(weight))
        #elseif canImport(AppKit)
        let font = NSFont.systemFont(ofSize: fontSize, weight: Self.nsWeight(weight))
        #endif
        let rect = (text as NSString).boundingRect(
            with: bounds, options: [.usesLineFragmentOrigin],
            attributes: [.font: font], context: nil)
        let lines = max(1.0, ((rect.height) / (fontSize * 1.2)).rounded())
        return IsomerCore.CGSize(
            width: ceil(rect.width), height: lines * fontSize * 1.3)
    }

    func imageInfo(_ source: String, isRemote: Bool) -> IsomerSwiftUI.ImageStatus { .loading }


    func syncHostViews(_ viewsJSON: String) {}
    func beginTextInput(_ text: String, in rect: IsomerCore.CGRect, fontSize: Double) {}
    func endTextInput() {}
    func rasterize(_ spec: String) -> [UInt8] { [] }

    func scheduleRender() {
        MainActor.assumeIsolated { model?.scheduleRender() }
    }

    func now() -> Double { Foundation.Date().timeIntervalSince1970 }

    func log(_ message: String) { NSLog("[isomer-view] %@", message) }

    #if canImport(UIKit)
    private static func uiWeight(_ weight: Int) -> UIFont.Weight {
        switch weight {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }
    #elseif canImport(AppKit)
    private static func nsWeight(_ weight: Int) -> NSFont.Weight {
        switch weight {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }
    #endif
}
