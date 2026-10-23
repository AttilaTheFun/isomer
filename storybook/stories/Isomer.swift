// The Isomer module: what Isomer adds to SwiftUI, on every platform
// (`import Isomer`): the platform, web views, maps, video, the clipboard,
// colors by appearance, swipes, and a platform's own views.

import Foundation
import Isomer
import SwiftUI

extension StoryCatalog {
    static let isomer = StoryArea(id: "isomer", title: "Isomer", symbol: "cube", stories: [
        Story(
            "isomer.platform", "Platform", apis: ["Bridge.platformName", "Bridge.rendererName", "Bridge.log(_:)", "#if os(…)"],
            summary: "Which platform and renderer the app is running on, and a line written to the platform's log."
        ) { PlatformStory() },
        Story(
            "isomer.webview", "WebView", apis: ["WebView(url:)"],
            height: 360,
            summary: "A web page in the app: WKWebView on Apple's platforms, WebView on Android, an iframe on the web, WebView2 on Windows."
        ) { WebViewStory() },
        Story(
            "isomer.map", "Map", apis: ["Map(camera:annotations:polygons:polylines:onAnnotationTap:)", "MapCamera", "MapAnnotation"],
            height: 380,
            summary: "OpenStreetMap's tiles, drawn by Isomer's map renderer, with markers that show their titles when tapped."
        ) { MapStory() },
        Story(
            "isomer.video", "VideoPlayer", apis: ["VideoPlayer(url:)"],
            height: 240,
            summary: "A video with the platform's own playback controls."
        ) { VideoStory() },
        Story(
            "isomer.clipboard", "Clipboard", apis: ["Clipboard.string"],
            summary: "Text copied to and pasted from the system's clipboard."
        ) { ClipboardStory() },
        Story(
            "isomer.dynamic", "Colors by appearance", apis: ["Color.dynamic(light:dark:)"],
            summary: "A color of your own with a light and a dark version, following the system's appearance."
        ) { DynamicColorStory() },
        Story(
            "isomer.swipe", "Swipe gesture", apis: [".swipeGesture(onChanged:onEnded:)"],
            summary: "A horizontal swipe that leaves vertical drags to the scroll view around it: a row swiped aside."
        ) { SwipeStory() },
    ])
}

// story: isomer.platform
struct PlatformStory: View {
    @State private var logged = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if canImport(Darwin)
            let compiledFor = "Apple"
            #elseif os(Android)
            let compiledFor = "Android"
            #elseif os(WASI)
            let compiledFor = "WebAssembly"
            #elseif os(Windows)
            let compiledFor = "Windows"
            #elseif os(Linux)
            let compiledFor = "Linux"
            #else
            let compiledFor = "another platform"
            #endif
            Text("Compiled for \(compiledFor)").font(.headline)
            Text("Platform: \(Bridge.platformName)")
            Text("Renderer: \(Bridge.rendererName)")
            Button("Write to the log (\(logged))") {
                logged += 1
                Bridge.log("Hello from the Storybook, \(logged)")
            }
            .buttonStyle(.bordered)
        }
    }
}
// end story

// story: isomer.webview
struct WebViewStory: View {
    var body: some View {
        WebView(url: URL(string: "https://en.wikipedia.org/wiki/Swift_(programming_language)"))
    }
}
// end story

// story: isomer.map
struct MapStory: View {
    @State private var camera = MapCamera(latitude: 37.8, longitude: -122.43, zoom: 11.5)
    @State private var tapped = "nothing yet"

    private let landmarks = [
        MapAnnotation(id: "ferry", latitude: 37.7955, longitude: -122.3937, title: "Ferry Building"),
        MapAnnotation(id: "bridge", latitude: 37.8199, longitude: -122.4783, color: MapColor(red: 0, green: 0.48, blue: 1), title: "Golden Gate Bridge"),
        MapAnnotation(id: "alcatraz", latitude: 37.8270, longitude: -122.4230, color: MapColor(red: 0.2, green: 0.78, blue: 0.35), title: "Alcatraz Island"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(camera: $camera, annotations: landmarks) { annotation in
                tapped = annotation.title
            }
            .cornerRadius(12)
            Text("Tapped: \(tapped)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: isomer.video
struct VideoStory: View {
    var body: some View {
        VideoPlayer(url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4"))
    }
}
// end story

// story: isomer.clipboard
struct ClipboardStory: View {
    @State private var text = "Copied from the Storybook"
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Text to copy", text: $text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Copy") { Clipboard.string = text }
                Button("Paste") { pasted = Clipboard.string ?? "(empty)" }
            }
            .buttonStyle(.bordered)
            Text("Pasted: \(pasted)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: isomer.dynamic
struct DynamicColorStory: View {
    private let ink = Color.dynamic(light: Color(red: 0.1, green: 0.2, blue: 0.5), dark: Color(red: 0.6, green: 0.8, blue: 1))
    private let paper = Color.dynamic(light: Color(red: 1, green: 0.97, blue: 0.9), dark: Color(red: 0.15, green: 0.15, blue: 0.2))

    var body: some View {
        Text("Ink on paper, in either appearance")
            .font(.headline)
            .foregroundColor(ink)
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(paper)
            .cornerRadius(12)
    }
}
// end story

// story: isomer.swipe
struct SwipeStory: View {
    @State private var offset: CGFloat = 0
    @State private var archived = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 12).fill(Color.orange)
                Label("Archive", systemImage: "archivebox").foregroundColor(.white).padding(.trailing, 16)
                HStack {
                    Text(archived ? "Archived" : "Swipe me left")
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                .offset(x: offset)
                .swipeGesture(
                    onChanged: { offset = min(0, $0) },
                    onEnded: { width in
                        withAnimation {
                            if width < -100 { archived.toggle() }
                            offset = 0
                        }
                    }
                )
            }
            .frame(height: 60)
            #if os(Windows) || os(Linux)
            NativeSliderRow()
            #endif
        }
    }
}
// end story

#if os(Windows) || os(Linux)
/// The platform's own trackbar, through PlatformViewRepresentable (Windows
/// and Linux only).
struct NativeSliderRow: View {
    @State private var value = 40

    var body: some View {
        VStack(alignment: .leading) {
            Text("Native trackbar: \(value)")
            NativeSlider(value: $value).frame(height: 34)
        }
    }
}
#endif
