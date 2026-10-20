// The single embedding point for a Isomer feature on Apple platforms.
//
//     IsomerView(root: { OrderStatusCard() },
//                   bundleProvider: MyDeliveryProvider())
//
// The feature ships COMPILED (built natively against `IsomerCore`;
// feature libraries alias it: `-module-alias SwiftUI=IsomerCore`) — and
// that is the whole reason to pass a `bundleProvider`: on Apple platforms
// Isomer earns its keep through the hot reloader and dynamic delivery
// of interpreted wasm, both of which arrive through the provider.
//
// Engine selection is the provider's bundle availability, not a caller choice:
//   • `initialBundle()` returns a bundle (the newest cached dynamic-delivery
//     download, or a packaged reactor) → the wasm engine renders from launch.
//   • Bundles arriving on `bundleUpdates()` (a dev hot-reload stream, a
//     background fetch completing) → the view swaps to the wasm engine live.
//   • No bundle present and none emitted → the compiled root renders, at
//     native performance. This is the shipping steady state.
//
// Both engines emit the SAME tree.fbs Patch stream into the SAME
// `IsomerTreeView` (real SwiftUI), so the surrounding app never notices
// which one is live.
//
// Note: the compiled engine drives the process-wide `IsomerCore.Runtime`
// singleton — one compiled feature per process (matching every compiled host
// today). Wasm features have per-instance runtimes and are not limited. Once
// the wasm engine takes over, the compiled runtime idles unrendered (the
// singleton has no teardown); it resumes if the app relaunches without a
// bundle.
//
// This file never imports IsomerCore (its reexported View/StateObject/…
// names collide with real SwiftUI); the core-facing half lives in
// CompiledFeatureModel.swift, which conversely never imports SwiftUI.

import SwiftFFIWasmHost
import SwiftUI
import IsomerTree
// Re-exported so a host importing IsomerView sees the whole wasm-engine
// surface (BundleProvider/AppBundleProvider/BridgedViewRegistry)
// without extra imports — the same courtesy WasmView extends.
@_exported import IsomerWasmView

public struct IsomerView: View {
    private let root: @MainActor () -> any IsomerCoreView
    private let provider: BundleProvider?
    private let ffiModulePrefix: String?
    private let dependencies: [String: SwiftFFIDependency]
    private let onStatus: ((String) -> Void)?

    @StateObject private var compiled = CompiledFeatureModel()
    @StateObject private var wasm = WasmViewModel()
    @Environment(\.colorScheme) private var hostColorScheme
    #if os(iOS)
    // The system's size classes, which the feature takes for its own (an
    // iPhone held sideways stays compact wide).
    @Environment(\.horizontalSizeClass) private var hostHorizontalSizeClass
    @Environment(\.verticalSizeClass) private var hostVerticalSizeClass
    #endif
    @State private var wasmActive = false
    @State private var started = false

    /// - root: the compiled feature (always present; the fallback and the
    ///   shipping steady state).
    /// - bundleProvider: where interpreted-wasm overrides come from — dynamic
    ///   delivery (cached download + background fetch) or the dev hot
    ///   reloader (env-gated, e.g. `AppBundleProvider`). Nil = compiled only.
    /// - host: native dependencies injected into a running WASM feature
    ///   (the compiled root links its dependencies directly).
    public init(
        root: @escaping @MainActor () -> any IsomerCoreView,
        bundleProvider: BundleProvider? = nil,
        ffiModulePrefix: String? = nil,
        dependencies: [String: SwiftFFIDependency] = [:],
        onStatus: ((String) -> Void)? = nil
    ) {
        self.root = root
        self.provider = bundleProvider
        self.ffiModulePrefix = ffiModulePrefix
        self.dependencies = dependencies
        self.onStatus = onStatus
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if wasmActive, let tree = wasm.tree {
                    IsomerTreeView(root: tree) { id, value in
                        wasm.send(id: id, value: value)
                    }
                    .id(wasm.generation)
                } else if let tree = compiled.tree {
                    IsomerTreeView(root: tree) { id, value in
                        compiled.send(id: id, value: value)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: geo.size) { size in
                compiled.resize(width: size.width, height: size.height)
                wasm.resize(width: size.width, height: size.height)
            }
            // The host app's appearance flows into whichever tier is live
            // (initially and on every toggle) so the feature's adaptive
            // semantic palette matches the native chrome.
            .onChange(of: hostColorScheme) { scheme in
                compiled.setColorScheme(dark: scheme == .dark)
                wasm.setColorScheme(dark: scheme == .dark)
            }
            .onAppear {
                compiled.setColorScheme(dark: hostColorScheme == .dark)
                wasm.setColorScheme(dark: hostColorScheme == .dark)
            }
            #if os(iOS)
            .onChange(of: hostHorizontalSizeClass) { _ in reportSizeClasses() }
            .onChange(of: hostVerticalSizeClass) { _ in reportSizeClasses() }
            #endif
            .onAppear {
                reportSizeClasses()
                start(size: geo.size)
            }
        }
    }

    /// The system's size classes to both tiers (each 0 = none, 1 = compact,
    /// 2 = regular); on the Mac, none: the feature works them out from its
    /// size.
    private func reportSizeClasses() {
        #if os(iOS)
        func code(_ sizeClass: UserInterfaceSizeClass?) -> Int32 {
            switch sizeClass {
            case .compact: 1
            case .regular: 2
            default: 0
            }
        }
        compiled.setSizeClasses(horizontal: code(hostHorizontalSizeClass), vertical: code(hostVerticalSizeClass))
        wasm.setSizeClasses(horizontal: code(hostHorizontalSizeClass), vertical: code(hostVerticalSizeClass))
        #endif
    }

    private func start(size: CGSize) {
        guard !started else { return }
        started = true

        if let provider {
            wasm.ffiModulePrefix = ffiModulePrefix
            wasm.dependencies = dependencies
            wasm.resize(width: size.width, height: size.height)
            // A synchronously available bundle (cached download / packaged
            // reactor) renders from the first frame — no compiled detour.
            if let initial = provider.initialBundle() {
                wasmActive = true
                wasm.load(bundle: initial)
                onStatus?(wasm.status)
            }
            // Later bundles (hot-reload builds, a fetch completing) take over
            // whichever engine is live.
            Task { @MainActor in
                for await bundle in provider.bundleUpdates() {
                    wasmActive = true
                    wasm.load(bundle: bundle)
                    onStatus?(wasm.status)
                }
            }
        }

        if !wasmActive {
            compiled.start(root: root, width: size.width, height: size.height)
            onStatus?("Compiled feature (no wasm bundle)")
        }
    }
}
