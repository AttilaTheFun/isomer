// A split view shaped as an app's dashboard is: a list whose selection
// picks the detail, the detail a Group of the selection's screen (a
// ScrollViewReader whose navigationTitle is the selection's name), a
// placeholder until one is picked. The headless tests (SplitTitleTests.swift)
// read the detail's title from the screen.

import Foundation
import Observation
import SwiftUI

@main
struct SplitTitleProbe: App {
    var body: some Scene {
        WindowGroup {
            ProbeRoot()
        }
    }
}

@Observable
final class ProbeStore {
    var selection: String?
    let servers = ["Mac Studio", "MacBook Pro"]
}

struct ProbeRoot: View {
    @State private var store = ProbeStore()
    @State private var settings = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.servers, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(name).font(.headline)
                        }
                        Text("Nothing leased").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(name)
                }
                Section {
                    Text("CI").tag("ci")
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem {
                    Button { settings = true } label: { Label("Settings", systemImage: "gear") }
                }
            }
        } detail: {
            switch ProcessInfo.processInfo.environment["PROBE_DETAIL"] ?? "" {
            case "plain":
                // The selection's title on a text, nothing around it.
                Text("What's running").navigationTitle(store.selection ?? "None")
            case "screen":
                // The screen alone, no Group or placeholder.
                ServerScreen(name: store.selection ?? "None")
            case "if":
                if let name = store.selection {
                    ServerScreen(name: name)
                } else {
                    Text("Pick a server")
                }
            default:
                Group {
                    if store.selection == "ci" {
                        Text("Runs").navigationTitle("CI")
                    } else if let name = store.selection {
                        ServerScreen(name: name)
                    } else {
                        ContentUnavailableView("Pick a server", systemImage: "gauge.with.dots.needle.50percent")
                    }
                }
                .navigationSplitViewColumnWidth(min: 560, ideal: 640)
            }
        }
        .sheet(isPresented: $settings) { Text("Settings") }
    }
}

struct ServerScreen: View {
    let name: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What's running")
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .task { proxy.scrollTo("end") }
        }
        .navigationTitle(name)
        .refreshable {}
    }
}
