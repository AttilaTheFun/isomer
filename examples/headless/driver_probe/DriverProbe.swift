// Views shaped as an app's are, for the driver's tests (DriverProbeTests.swift):
// what an app's UI tests find by identifier and label, each in the shape that
// lost it before (an identifier outside `.padding`, `.background` or an app's
// own modifier; a selection list's row; a combined card; a toggle; a bottom
// bar's icon button; a disabled toolbar item; a page pushed in a sheet; a
// long press). PROBE_SCREEN picks the screen: the controls (the default), the
// list, or the sheet's.

import Foundation
import SwiftUI

@main
struct DriverProbe: App {
    var body: some Scene {
        WindowGroup {
            switch ProcessInfo.processInfo.environment["PROBE_SCREEN"] ?? "" {
            case "list": ListScreen()
            case "sheet": SheetScreen()
            default: ControlsScreen()
            }
        }
    }
}

/// An app's own button style, as a modifier around the button.
struct PillButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.blue.opacity(0.15)))
    }
}

extension View {
    func pillButton() -> some View { modifier(PillButton()) }
}

struct ControlsScreen: View {
    @State private var last = "nothing yet"
    @State private var notifications = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Last: \(last)")
                // Identifiers and labels outside the views that wrap a button.
                Button("Allow") { last = "allowed" }
                    .padding(8)
                    .background(Color.green.opacity(0.2))
                    .accessibilityIdentifier("allow")
                Button("Deny") { last = "denied" }
                    .pillButton()
                    .accessibilityIdentifier("deny")
                Button { last = "closed" } label: { Image(systemName: "xmark") }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Close")
                // A card read as one element, found by its identifier.
                VStack(alignment: .leading) {
                    Text("Mac Studio")
                    Text("2 sessions")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("server-card")
                Toggle("Notifications", isOn: $notifications)
                    .accessibilityIdentifier("notifications")
                Text(notifications ? "Notifying" : "Quiet")
                Text("Hold to pin")
                    .padding(8)
                    .onLongPressGesture { last = "pinned" }
            }
            .padding()
            .navigationTitle("Probe")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { last = "saved" }
                        .disabled(true)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("New session", systemImage: "square.and.pencil") { last = "new session" }
                }
            }
        }
    }
}

struct ListScreen: View {
    @State private var selection: String?
    private let servers = ["alpha", "beta", "gamma"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Selected: \(selection ?? "none")")
                List(selection: $selection) {
                    ForEach(servers, id: \.self) { name in
                        HStack {
                            Text(name.capitalized)
                            Spacer()
                            Text("idle")
                        }
                        .accessibilityIdentifier("server-\(name)")
                        .tag(name)
                    }
                }
            }
            .navigationTitle("Servers")
        }
    }
}

struct SheetScreen: View {
    @State private var settings = false

    var body: some View {
        NavigationStack {
            VStack {
                Text("Home page")
                Button("Settings…") { settings = true }
            }
            .navigationTitle("Home")
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                VStack {
                    Text("General settings")
                    NavigationLink("Advanced") {
                        Text("Advanced settings")
                            .navigationTitle("Advanced")
                    }
                }
                .navigationTitle("Settings")
            }
        }
    }
}
