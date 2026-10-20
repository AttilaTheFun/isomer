// The hot-reload example host: a macOS SwiftUI app that embeds the demo feature
// bundle with `WasmView` (from //apple/libraries/wasm_view) and renders the
// tree it emits with real SwiftUI. It mirrors the iOS host exactly — a client
// of the hot-reload server:
//
//   bazel run //examples/apple/example_partial_wasm_macos_application:hot_reload_server  # shell 1
//   bazel run //examples/apple/example_partial_wasm_macos_application:run                # shell 2
//
// then edit examples/wasm/hot_demo_feature/HotDemo.swift and the window re-renders. The server
// compiles the wasm; this app only fetches and renders it. Without a server it
// renders the bundled wasm (static). The host picks a `WasmBundleProvider` and
// hands it to `WasmView`; all the WasmKit machinery lives in the library.

import ApplePlatformServices
import SwiftUI
import IsomerWasmView

@main
struct WasmViewHostApp: App {
    @StateObject private var model = HostModel()

    var body: some Scene {
        WindowGroup("Isomer — Hot Reload") {
            ContentView(model: model)
        }
        .defaultSize(width: 960, height: 760)
    }
}

@MainActor
final class HostModel: ObservableObject {
    @Published var banner = "Starting…"
    let provider: BundleProvider

    init() {
        registerBridgedViews()
        // The packaged bundle renders immediately; if ISO_HOT_RELOAD_SERVER (a
        // hot-reload server that compiles + serves) or ISO_WASM_PATH (a watched
        // artifact) is set, AppBundleProvider shadows it with a live stream.
        provider = AppBundleProvider(resource: "hot_demo")
    }
}


/// Register the app's native SwiftUI views that features may bridge in by id.
/// Ships with the app (never dynamically delivered). Here: a native badge whose
/// SF Symbol the wasm core cannot draw itself.
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

struct ContentView: View {
    @ObservedObject var model: HostModel

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            WasmView(
                provider: model.provider,
                ffiModulePrefix: platformServicesFFIPrefix,
                dependencies: applePlatformDependencies(namespace: "example_partial_wasm_macos")
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
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Text("edit examples/wasm/hot_demo_feature/HotDemo.swift → auto-reload")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial)
    }
}
