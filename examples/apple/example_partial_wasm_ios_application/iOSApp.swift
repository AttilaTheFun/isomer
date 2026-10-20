// The hot-reload example host for the iOS Simulator: embeds the same demo
// feature bundle with `WasmView` (from //apple/libraries/wasm_view) and renders
// the emitted tree with real SwiftUI, exactly like the macOS host — but the iOS
// sandbox can't spawn a compiler, so it doesn't build. It renders a bundled
// wasm out of the box, connects to a hot-reload server if ISO_HOT_RELOAD_SERVER
// is set, or polls ISO_WASM_PATH on the shared Mac filesystem.
//
//   bazel run //examples/apple/example_partial_wasm_ios_application
//     → renders the bundled demo in the simulator
//   …with ISO_HOT_RELOAD_SERVER set (see run_ios.sh) → hot-reloads live
//
// Because the demo shares one HotDemo.swift / hot_demo.wasm with the macOS
// host, the running server drives BOTH.

import ApplePlatformServices
import SwiftUI
import IsomerWasmView

@main
struct WasmViewIOSApp: App {
    @StateObject private var model = IOSModel()

    var body: some Scene {
        WindowGroup {
            IOSContentView(model: model)
        }
    }
}

@MainActor
final class IOSModel: ObservableObject {
    @Published var banner = "Starting…"
    let provider: BundleProvider

    init() {
        registerBridgedViews()
        // Packaged bundle renders immediately; ISO_HOT_RELOAD_SERVER /
        // ISO_WASM_PATH shadow it with a live hot-reload stream (see run_ios.sh).
        provider = AppBundleProvider(resource: "hot_demo")
    }
}


/// Register the app's native SwiftUI views that features may bridge in by id.
@MainActor func registerBridgedViews() {
    BridgedViewRegistry.shared.register("native_badge") { params, _, _ in
        AnyView(
            Label(params["title"] ?? "Native", systemImage: params["icon"] ?? "star.fill")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.14))
                .foregroundStyle(Color.blue)
                .clipShape(Capsule())
        )
    }
}

struct IOSContentView: View {
    @ObservedObject var model: IOSModel

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            WasmView(
                provider: model.provider,
                ffiModulePrefix: platformServicesFFIPrefix,
                dependencies: applePlatformDependencies(namespace: "example_partial_wasm_ios")
            ) { status in
                model.banner = status
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.banner.contains("fail") ? Color.red : Color.green)
                .frame(width: 8, height: 8)
            Text(model.banner)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}
