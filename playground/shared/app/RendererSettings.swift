// The renderer choice, shared by both Playgrounds' Settings: the platform's
// component-system renderer (SwiftUI on iOS, React on the web) or the
// self-drawing SwiftGPU renderer over the platform's GPU (Metal, WebGPU).
// Kept in UserDefaults (under the key the iOS Playground used before 0.31),
// or by the host where it picks the renderer before the app starts: the web
// page reads it from the browser's storage before boot, so it installs
// `hostStore`. Applied on the next launch (iOS: the next run) / page refresh.

import Foundation
import SwiftUI

public enum RendererPreference {
    public static let key = "playground.preferences.renderer"
    /// The host's own store, when it keeps the choice (the web and Android
    /// Playgrounds, through their host service).
    public nonisolated(unsafe) static var hostStore: (get: () -> String, set: (String) -> Void)?
    /// "native" (default) or "gpu".
    public static var current: String {
        let value = hostStore?.get() ?? UserDefaults.standard.string(forKey: key) ?? ""
        return value == "gpu" ? "gpu" : "native"
    }
    public static var isGPU: Bool { current == "gpu" }
    public static func set(_ value: String) {
        if let hostStore {
            hostStore.set(value)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}

/// A Settings section: a segmented picker between the two renderers.
public struct RendererSettingsSection: View {
    let nativeName: String
    let gpuName: String
    let footer: String
    @State private var selection = RendererPreference.current

    public init(nativeName: String, gpuName: String, footer: String) {
        self.nativeName = nativeName
        self.gpuName = gpuName
        self.footer = footer
    }

    public var body: some View {
        Section {
            Picker("Renderer", selection: $selection) {
                Text(nativeName).tag("native")
                Text(gpuName).tag("gpu")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("renderer")
            .onChange(of: selection) { value in RendererPreference.set(value) }
        } header: {
            Text("Renderer")
        } footer: {
            Text(footer)
        }
    }
}
