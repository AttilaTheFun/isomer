// Views shaped as an app's are, for the driver's tests (DriverProbeTests.swift):
// what an app's UI tests find by identifier and label, each in the shape that
// lost it before (an identifier outside `.padding`, `.background` or an app's
// own modifier; a selection list's row; a combined card; a toggle; a bottom
// bar's icon button; a disabled toolbar item; a page pushed in a sheet; a
// long press; controls in a Form's rows, a text field and a multi-line one,
// the navigation title's own button; sheets closed by `dismiss` alone, and
// one presented over another; the scene's phase, and what an app does on
// coming back to the foreground, from the home screen or from a page it
// opened in another app (Safari), its process shown; an alert with a text field, a confirmation
// dialog, a row's context menu and a long press). PROBE_SCREEN picks the
// screen: the controls (the default), the list, the sheet's, the form, the
// sheets, the scene, the dialogs or the sign-in prompt. The same
// source is the iPhone's probe on Apple's SwiftUI
// (//apple/driver_probe_ios_application), which its tests drive through
// Apple's driver, upright and turned to landscape by the app itself, and the
// Mac's (//apple/driver_probe_macos_application).

import Foundation
import SwiftUI

@main
struct DriverProbe: App {
    var body: some Scene {
        WindowGroup {
            switch ProcessInfo.processInfo.environment["PROBE_SCREEN"] ?? "" {
            case "list": ListScreen()
            case "sheet": SheetScreen()
            case "form": FormScreen()
            case "sheets": SheetsScreen()
            case "scene": SceneScreen()
            case "dialogs": DialogsScreen()
            case "signin": SignInScreen()
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
                ToolbarItem(placement: .probeBottomBar) {
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

/// A form's rows as an app's settings are: controls with identifiers in
/// them, a text field, a multi-line field, and the navigation title's own
/// button.
struct FormScreen: View {
    @State private var last = "nothing yet"
    @State private var sync = false
    @State private var host = ""
    @State private var message = ""
    @AppStorage("probe.launches") private var launches = 0
    /// A launch argument (`-probe.argument <value>`, UserDefaults' argument
    /// domain), shown.
    private let argument = UserDefaults.standard.string(forKey: "probe.argument") ?? "none"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Last: \(last)")
                    Text("Argument: \(argument)")
                    Text("Launches: \(launches)")
                }
                Section("Computers") {
                    Button("Add Computer") { last = "add computer" }
                        .accessibilityIdentifier("add-computer")
                    HStack {
                        Text("Mac Studio")
                        Spacer()
                        Button("Connect") { last = "connect" }
                            .accessibilityIdentifier("connect")
                    }
                    Toggle("Sync", isOn: $sync)
                        .accessibilityIdentifier("sync")
                    NavigationLink("Runner") {
                        Text("Runner settings")
                            .navigationTitle("Runner")
                    }
                    .accessibilityIdentifier("runner")
                }
                Section("Connection") {
                    TextField("Host name", text: $host)
                        .accessibilityIdentifier("host")
                    TextField("Message", text: $message, axis: .vertical)
                    Text("Host: \(host.isEmpty ? "none" : host), message: \(message.isEmpty ? "none" : message)")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button("Session title") { last = "title" }
                        .accessibilityIdentifier("session-title")
                }
            }
        }
        .onAppear { launches += 1 }
    }
}

/// Sheets an app presents: one with only Done, one with nothing to close it
/// but a swipe (closed by the driver's `dismiss`), and one presented from
/// inside another.
struct SheetsScreen: View {
    @State private var done = false
    @State private var question = false
    @State private var outer = false
    @State private var inner = false
    @State private var last = "nothing yet"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Last: \(last)")
                Button("Tool calls") { done = true }
                Button("Question") { question = true }
                Button("Settings…") { outer = true }
            }
            .navigationTitle("Sheets")
        }
        .sheet(isPresented: $done) {
            NavigationStack {
                Text("Every tool call")
                    .navigationTitle("Tool calls")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { done = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $question, onDismiss: { last = "question closed" }) {
            VStack {
                Text("Which model?")
                Text("Pick one, or swipe down")
            }
        }
        .sheet(isPresented: $outer) {
            VStack(spacing: 12) {
                Text("Outer sheet")
                Button("Add Computer") { inner = true }
                    .accessibilityIdentifier("add-computer")
            }
            .sheet(isPresented: $inner) {
                Text("Inner sheet")
            }
        }
    }
}

/// The scene's phase as the app sees it, each change it was told of, and
/// what an app does on coming back from the background (a sign-in prompt
/// opened on `.onChange(of: scenePhase)` once the phase is `.active` again,
/// as an app that asks again on `.active` does: a scene left inactive on
/// its way back never shows it); a page opened in another app
/// (Safari, on the iPhone, in front of the app), the app's process (the
/// same when it comes back) and a button to use when it has.
struct SceneScreen: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var changes: [String] = []
    @State private var welcome = false
    @State private var away = false
    @State private var opened = 0
    @State private var notes = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Phase: \(name(phase))")
                Text("Changes: \(changes.isEmpty ? "none" : changes.joined(separator: " "))")
                if welcome {
                    Text("Welcome back")
                    Button("Sign in") { welcome = false }
                        .accessibilityIdentifier("sign-in")
                }
                Text("Process: \(String(ProcessInfo.processInfo.processIdentifier))")
                Text("Opened: \(opened), notes: \(notes)")
                Button("Open Page") {
                    opened += 1
                    openURL(URL(string: "https://example.com/")!)
                }
                Button("Note") { notes += 1 }
            }
            .padding()
            .navigationTitle("Scene")
        }
        .onChange(of: phase) { old, new in
            changes.append(name(new))
            if new == .background { away = true }
            if new == .active, away {
                away = false
                welcome = true
            }
        }
    }

    private func name(_ phase: ScenePhase) -> String { "\(phase)" }
}

/// What an app asks with: an alert with a text field and two buttons, a
/// confirmation dialog, a list row's context menu (a session's, opened by a
/// long press) and a long-press gesture.
struct DialogsScreen: View {
    @State private var last = "nothing yet"
    @State private var renaming = false
    @State private var name = ""
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            List {
                Text("Last: \(last)")
                Button("Rename…") { renaming = true }
                Button("Delete…") { deleting = true }
                Button("Session alpha") { last = "opened alpha" }
                    .accessibilityIdentifier("session-alpha")
                    .contextMenu {
                        Button("Project Settings") { last = "project settings" }
                        Button("Archive", role: .destructive) { last = "archived" }
                    }
                Text("Hold to star")
                    .onLongPressGesture { last = "starred" }
            }
            .navigationTitle("Dialogs")
        }
        .alert("Rename Session", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { last = "rename cancelled" }
            Button("Rename") { last = "renamed \(name)" }
        } message: {
            Text("Give the session a name.")
        }
        .confirmationDialog("Delete the session?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { last = "deleted" }
            Button("Keep", role: .cancel) { last = "kept" }
        }
    }
}

/// An alert an app asks with as a page arrives (a sign-in prompt that the
/// session's first reading brings), over a page shown at launch, its
/// composer focused.
struct SignInScreen: View {
    var body: some View {
        NavigationStack {
            SignInPage()
        }
    }
}

struct SignInPage: View {
    @State private var asking = false
    @State private var last = "nothing yet"
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("Last: \(last)")
            TextField("Message", text: $draft)
                .focused($composing)
        }
        .padding()
        .navigationTitle("Session")
        .onAppear {
            composing = true
            asking = true
        }
        .alert("Sign In to Claude", isPresented: $asking) {
            Button("Open Sign-In Page") { last = "opened the page" }
            Button("Later", role: .cancel) { last = "later" }
        } message: {
            Text("Sign in on the page that opens.")
        }
    }
}
