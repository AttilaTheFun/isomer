// The WATCHED SwiftUI file. This is the whole demo UI - it compiles ONLY into
// the `hot_demo.wasm` reactor, never into a host binary. With the hot-reload
// server running (`:hot_reload_server`) and an app connected (`:run` on macOS
// or iOS), edit this file and save: the server rebuilds just this wasm (a few
// seconds) and every connected app re-renders. The host process is never
// rebuilt or relaunched.
//
// Try it: change `accent`, the greeting text, or add a row to `items`, save,
// and watch the app update.

import Isomer
import PlatformServices
import SwiftUI

@main
struct HotDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    // Edit any of these and save  -  the window reflects it after the rebuild.
    private let accent = Color(red: 0.35, green: 0.34, blue: 0.84)
    private let greeting = "Hot reload works."
    private let items = ["Edit HotDemo.swift", "Save the file", "Watch it reload"]

    @State private var count = 0
    @State private var enabled = true

    var body: some View {
        VStack(spacing: 20) {
            // A native-injected dependency (ConfigurationService.flag, over the swift_ffi
            // transport): the wasm feature stays declarative, the native host
            // owns the policy.
            if PlatformDependencies.configuration?.flag(key: "promo_banner") == true {
                Text("Promo from native host")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.15, green: 0.6, blue: 0.4))
                    .cornerRadius(8)
            }

            Text(greeting)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(accent)

            // A native SwiftUI view the app registered under "native_badge",
            // bridged into this wasm feature by id (SF Symbols can't be drawn
            // by the wasm core — the host renders the real native view).
            BridgedView("native_badge", parameters: [
                "title": "Bridged native view", "icon": "swift",
            ])
            .frame(height: 34)

            Text("Tapped \(count) time\(count == 1 ? "" : "s")")
                .font(.system(size: 16))
                .foregroundColor(.gray)

            Button {
                count += 1
                PlatformDependencies.analytics?.track(event: "tap_me")  // analytics event → native host
            } label: {
                Text("Tap me")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(accent)
                    .cornerRadius(10)
            }

            Toggle("Feature enabled", isOn: $enabled)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(accent)
                            .frame(width: 10, height: 10)
                        Text(item)
                            .font(.system(size: 15))
                    }
                }
            }
            .padding(20)
            .background(Color.gray.opacity(0.12))
            .cornerRadius(14)
        }
        .padding(40)
    }
}
