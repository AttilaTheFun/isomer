// The "partial x compiled" cell of the Apple matrix: a plain native SwiftUI app
// — its own @main, its own chrome — that embeds ONE shared Isomer feature
// (//examples/shared/embedded_example's OrderStatusCard) directly as a SwiftUI view. This
// is the Apple analogue of the Android partial_compiled host (a Kotlin/Compose
// app that drops in the same feature via the `Isomer()` composable). On
// Apple "compiled" is pure native SwiftUI, so the feature is just a `View` the
// host embeds — no runtime, no bridge. The wasm-delivered twin is
// example_partial_wasm_macos_application.

import SwiftUI
import EmbeddedExample

@main
struct PartialCompiledHostApp: App {
    var body: some Scene {
        WindowGroup("Isomer — Partial (compiled)") {
            HostScreen()
        }
        .defaultSize(width: 720, height: 560)
    }
}

/// Native host chrome that owns the screen; the shared feature is one section.
struct HostScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
                Text("Acme (native host)").font(.headline)
                Spacer()
                Text("SwiftUI").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Embedded Isomer feature")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.top, 16)

                    // The shared feature, compiled natively and dropped in.
                    OrderStatusCard()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}
