// The Isomer site's front page — a post about the framework, written in
// Isomer's SwiftUI and compiled to wasm, with the example apps embedded
// INLINE as subviews (the same Counter / 2048 / Pokédex sources every example
// app ships) inside framed cards you can use and scroll past. The pencil in
// each card's corner (and in the page's corner) opens the Playground on that
// source; the page's host handles the commands (`template:<name>`, `edit`,
// `playground`).

import SwiftUI
import Isomer

@main
struct SplashApp: App {
    var body: some Scene { WindowGroup { SplashPage() } }
}

struct SplashPage: View {
    @State private var command = ""
    @State private var commandCount = 0
    /// The Pokédex's caught record (kept in the app's Application Support).
    @State private var pokedex = PokedexStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                section("What it is") {
                    Para("Isomer is a reimplementation of SwiftUI. Apps are written against Apple's SwiftUI API — `import SwiftUI`, `@State`, `NavigationStack`, `List`, gestures, animations — and the same source compiles for every platform: on iOS and macOS it is Apple's SwiftUI, and everywhere else (the web, Android, Linux, Windows) it is this reimplementation, which turns the view tree into a compact render tree and hands it to a renderer.")
                    Para("The whole page you are reading is one of those apps, running as WebAssembly in your browser. So are the examples below — they are the example apps' own screens, embedded here as ordinary subviews. Try them; then press the pencil to open the source in the Playground.")
                    DemoCard(title: "Counter", template: "Counter", note: "State and a button — the smallest app.", send: send) {
                        NavigationStack { CounterScreen() }
                    }
                }
                section("How it works: one tree, pluggable renderers") {
                    Para("Every frame, the app's SwiftUI body builds a render tree: stacks, text, images, shapes, scroll views, inputs, navigation chrome. It is diffed and serialized as patches on a small FlatBuffers wire format, and a renderer applies it. Renderers are pluggable and come in two kinds.")
                    Para("Component-system renderers build the platform's own components from the tree — React DOM on the web (this page), Jetpack Compose or classic Views on Android, SwiftUI or UIKit views on Apple when a feature runs as a bundle inside a native app. They get the platform's native feel for free: real text fields, real scrolling, real navigation bars.")
                    Para("The self-drawing renderer, SwiftGPU, draws everything itself — layout, text, chrome — identically on every backend, for hosts without a component system or for pixel-identical output across platforms.")
                    DemoCard(title: "2048", template: "2048", note: "Drag gestures, GeometryReader layout, withAnimation — swipe the board.", send: send) {
                        NavigationStack { Game2048Screen() }
                    }
                }
                section("Compiled, or WebAssembly") {
                    Para("The same Swift ships two ways. Compiled, it links straight into the app for the platform's native performance. As WebAssembly, it becomes a self-contained feature bundle a host runs in a wasm engine — WasmKit, JavaScriptCore, or the browser — which is what makes hot reload possible: a native iOS or Android app can swap a feature's bundle live, and a phone can pull new versions of an app as they are published.")
                    Para("In the browser it goes one step further: the Playground compiles Swift itself, in the page, with swift-frontend and wasm-ld compiled to WebAssembly. Edit this page there and Run, and the site recompiles without leaving the browser.")
                }
                section("Pluggable GPUs") {
                    Para("The SwiftGPU renderer draws through a GPU abstraction with pluggable backends — Metal on Apple, OpenGL ES on Android, WebGPU in the browser — and a host can bring its own device. The same abstraction powers SwiftMap, an OpenStreetMap renderer that drops into Isomer apps as a map view on every platform.")
                }
                section("Apple's frameworks, everywhere") {
                    Para("Apps reach the network and their files the way they do on Apple platforms: URLSession, FileManager and UserDefaults from Foundation, with models made @Observable. Off Apple those are Isomer's own Foundation and Observation, in Swift — URLSession over the browser's fetch here and Android's HTTP client there, an app's files in the browser's storage or on disk — so the same source runs everywhere.")
                    Para("The Pokédex below loads its list and artwork with URLSession and remembers which Pokémon you have caught in a file in its Application Support — in your browser's storage here, on disk in the native apps.")
                    DemoCard(title: "Pokédex", template: "Pokédex", note: "URLSession and a file kept in Application Support.", send: send) {
                        NavigationStack { PokedexScreen() }.environment(pokedex)
                    }
                }
                section("Try it") {
                    Para("The Playground is a Swift compiler and an agent in a static web page: describe an app, and it writes the SwiftUI, compiles it in your browser, fixes its own errors, and runs it. Or open this page's source and change it.")
                    HStack(spacing: 12) {
                        Button { send("playground") } label: { Label("Open the Playground", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                        Button { send("edit") } label: { Label("Edit this page", systemImage: "pencil") }
                            .buttonStyle(.bordered)
                    }
                }
                footer
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 24)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            // The page's own pencil: this file, in the Playground.
            Button { send("edit") } label: { Image(systemName: "pencil") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Edit this page")
                .accessibilityIdentifier("edit-page")
                .padding(14)
        }
        .platformCommand("splash", command, on: .wasm)
    }

    private func send(_ value: String) {
        // A distinct value each time, so repeated commands are delivered.
        // (A counter, not the epoch in ms: Int is 32-bit on wasm.)
        commandCount += 1
        command = value + "#" + String(commandCount)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Isomer").font(.system(size: 44, weight: .bold))
            Text("SwiftUI, everywhere.").font(.system(size: 26, weight: .semibold)).foregroundColor(.secondary)
            Text("This website is written in SwiftUI. You can edit it and re-compile the code without leaving the page.")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(.top, 4)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 26, weight: .bold))
            content()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Isomer · SwiftUI reimplementation · wasm, Android, Linux, Windows, Apple")
                .font(.footnote).foregroundColor(.secondary)
        }
    }
}

/// A paragraph of the post.
struct Para: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 17)).lineSpacing(5)
    }
}

/// An example app embedded inline: the screen inside a phone-sized, rounded,
/// bordered card with a shadow, usable in place, with a pencil that opens
/// its source in the Playground.
struct DemoCard<Content: View>: View {
    let title: String
    let template: String
    let note: String
    let send: (String) -> Void
    let content: Content

    init(title: String, template: String, note: String, send: @escaping (String) -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.template = template
        self.note = note
        self.send = send
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 560)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.gray.opacity(0.35), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 12)
                .frame(maxWidth: 400)
            // The pencil sits beside the note, not over the example: the
            // example's own bar has the top-trailing corner (2048's new-game
            // button lives there), and a page control laid over an app's
            // control is two things in one place.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(note).font(.footnote).foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button { send("template:" + template) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Edit \(title) in the Playground")
                    .accessibilityIdentifier("edit-" + template)
            }
            .frame(maxWidth: 400)
        }
        .padding(.vertical, 6)
    }
}
