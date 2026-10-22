// Embeds one wasm feature bundle in a native SwiftUI hierarchy. It owns a
// `WasmViewModel`, starts a `WasmBundleProvider` to load (and hot-reload) the
// bundle, sizes the feature to the space it is given, and renders the emitted
// tree with real SwiftUI (`IsomerTreeView`). Drop it into any SwiftUI view
// or wrap it in a `UIHostingController`.
//
//     WasmView(provider: BundledWasmProvider(resource: "profile"))
//
// Native services the feature consumes are injected as `dependencies` (the
// app's generated `Dependencies` builders); Foundation's networking goes in
// beneath them by default, so the feature's URLSession is Apple's
// (//shared/isomer_network_host/urlsession). Presentation escaping the frame is deferred (a
// feature's sheets render within its own bounds).

import SwiftFFIWasmHost
import SwiftUI
#if ISO_GPU_TREE_VIEW
import class IsomerGPUTreeView.GPUTreeView
#endif

/// How a WasmView draws the feature's tree: real SwiftUI (`IsomerTreeView`,
/// the platform's component-system renderer) or the self-drawing SwiftGPU
/// renderer over Metal (`GPUTreeView`, iOS; falls back to SwiftUI elsewhere).
public enum WasmViewRenderer: Sendable {
    case swiftUI
    case gpu
}
// Re-exported so a host that imports IsomerWasmView can register bridged
// native views (BridgedViewRegistry) without a separate dependency.
@_exported import IsomerTree

public struct WasmView: View {
    @StateObject private var runtime: WasmViewModel
    @Environment(\.colorScheme) private var hostColorScheme
    @Environment(\.scenePhase) private var hostScenePhase
    #if os(iOS)
    // The system's size classes, which the guest takes for its own: an
    // iPhone held sideways is compact wide at 874 points, past the guest's
    // own 700-point rule.
    @Environment(\.horizontalSizeClass) private var hostHorizontalSizeClass
    @Environment(\.verticalSizeClass) private var hostVerticalSizeClass
    #endif
    private let provider: BundleProvider
    private let ffiModulePrefix: String?
    private let dependencies: [String: SwiftFFIDependency]
    private let onStatus: ((String) -> Void)?
    private let renderer: WasmViewRenderer

    public init(
        provider: BundleProvider,
        ffiModulePrefix: String? = nil,
        dependencies: [String: SwiftFFIDependency] = [:],
        renderer: WasmViewRenderer = .swiftUI,
        onStatus: ((String) -> Void)? = nil
    ) {
        self.init(
            model: WasmViewModel(), provider: provider, ffiModulePrefix: ffiModulePrefix,
            dependencies: dependencies, renderer: renderer, onStatus: onStatus)
    }

    /// The caller-owned-model variant: hand in the `WasmViewModel` you keep a
    /// reference to. A host whose injected services answer ASYNCHRONOUSLY
    /// needs this — the service performs its work and completes back into the
    /// feature via `model.complete(...)` (or raw `engineRuntime` calls), so it
    /// must reach the model the view drives.
    public init(
        model: WasmViewModel,
        provider: BundleProvider,
        ffiModulePrefix: String? = nil,
        dependencies: [String: SwiftFFIDependency] = [:],
        renderer: WasmViewRenderer = .swiftUI,
        onStatus: ((String) -> Void)? = nil
    ) {
        _runtime = StateObject(wrappedValue: model)
        self.provider = provider
        self.ffiModulePrefix = ffiModulePrefix
        self.dependencies = dependencies
        self.renderer = renderer
        self.onStatus = onStatus
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                #if ISO_GPU_TREE_VIEW
                if renderer == .gpu {
                    GPUTreeHost(model: runtime)
                } else if let tree = runtime.tree {
                    IsomerTreeView(root: tree) { id, value in
                        runtime.send(id: id, value: value)
                    }
                    .id(runtime.generation)
                } else {
                    ProgressView()
                }
                #else
                if let tree = runtime.tree {
                    IsomerTreeView(root: tree) { id, value in
                        runtime.send(id: id, value: value)
                    }
                    .id(runtime.generation)
                } else {
                    ProgressView()
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The feature starts once its size is known: started at the
            // runtime's default width, a phone drew the wide layout (a
            // split view's sidebar column) for a few frames before the
            // resize rebuilt it at its own size.
            .onChange(of: geo.size) { size in
                runtime.resize(width: size.width, height: size.height)
                if size.width > 0 { startProviderOnce() }
            }
            .onAppear {
                guard geo.size.width > 0 else { return }
                runtime.resize(width: geo.size.width, height: geo.size.height)
                // Known before the feature's first build.
                reportSizeClasses()
                startProviderOnce()
            }
        }
        // The host app's appearance flows into the feature (initially and on
        // every system/app toggle), so the wasm side's adaptive semantic
        // palette matches the native chrome around it.
        .onChange(of: hostColorScheme) { scheme in
            runtime.setColorScheme(dark: scheme == .dark)
        }
        .onAppear { runtime.setColorScheme(dark: hostColorScheme == .dark) }
        // And the app's scene phase: the guest's `.onChange(of: scenePhase)`
        // runs as under SwiftUI (an app letting its connections go in the
        // background, checking them on return).
        .onChange(of: hostScenePhase) { phase in
            runtime.setScenePhase(phase == .background ? 2 : phase == .inactive ? 1 : 0)
        }
        #if os(iOS)
        .onChange(of: hostHorizontalSizeClass) { _ in reportSizeClasses() }
        .onChange(of: hostVerticalSizeClass) { _ in reportSizeClasses() }
        #endif
        // Newer bundles (dev hot-reload shadow, dynamic-delivery update) swap
        // in as they arrive. The subscription lives with the view: `.task`
        // cancels it when the view goes away, so a provider whose stream
        // never finishes cannot keep the model — and its engine instance —
        // alive after the view is released. Re-subscribes on reappear.
        .task {
            let runtime = runtime
            let onStatus = onStatus
            for await bundle in provider.bundleUpdates() {
                if Task.isCancelled { return }
                runtime.load(bundle: bundle)
                onStatus?(runtime.status)
            }
        }
    }

    /// The system's size classes to the guest (each 0 = none, 1 = compact,
    /// 2 = regular); on the Mac, none: the guest works them out from its
    /// size, as a Mac window's are.
    private func reportSizeClasses() {
        #if os(iOS)
        func code(_ sizeClass: UserInterfaceSizeClass?) -> Int32 {
            switch sizeClass {
            case .compact: 1
            case .regular: 2
            default: 0
            }
        }
        runtime.setSizeClasses(horizontal: code(hostHorizontalSizeClass), vertical: code(hostVerticalSizeClass))
        #endif
    }

    @State private var started = false
    private func startProviderOnce() {
        guard !started else { return }
        started = true
        runtime.ffiModulePrefix = ffiModulePrefix  // injected before the first load
        runtime.dependencies = dependencies
        runtime.drawnNavigation = renderer == .gpu

        // The initial bundle loads synchronously so the first frame renders
        // immediately (no ProgressView flash for a packaged feature).
        if let initial = provider.initialBundle() {
            runtime.load(bundle: initial)
            onStatus?(runtime.status)
        }
    }
}

#if ISO_GPU_TREE_VIEW
/// The GPU renderer inside SwiftUI: the model's raw patches feed the
/// `GPUTreeView`, whose events go back through the model.
struct GPUTreeHost: UIViewRepresentable {
    let model: WasmViewModel
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> GPUTreeView {
        let view = GPUTreeView(frame: .zero)
        view.onEvent = { [weak model] id, value in model?.send(id: id, value: value) }
        model.onPatch = { [weak view] bytes in view?.apply(patch: bytes) }
        model.onPatchReset = { [weak view] in view?.reset() }
        view.setColorScheme(dark: colorScheme == .dark)
        return view
    }

    func updateUIView(_ uiView: GPUTreeView, context: Context) {
        uiView.setColorScheme(dark: colorScheme == .dark)
    }

    static func dismantleUIView(_ uiView: GPUTreeView, coordinator: ()) {
        uiView.onEvent = nil
    }
}
#endif
