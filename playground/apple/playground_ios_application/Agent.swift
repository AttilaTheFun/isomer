// The agent: a tool loop over the chat model with the playground's tools —
// list/read/write/delete files, build (the in-process compiler, errors fed
// back), run (loads the build in the preview). Everything happens on the
// device; the compile feedback is what makes the loop converge.

import Foundation
import SwiftUI

@MainActor
final class AgentSession: ObservableObject {
    let projectID: String
    let projects: ProjectStore
    let auth: AuthStore

    @Published var messages: [ChatMessage]
    @Published var streamingText = ""
    @Published var busy = false
    @Published var activity: String?
    @Published var error: String?
    /// The latest successful build (the preview pane shows it).
    @Published var buildProduct: Data?
    @Published var buildCount = 0
    @Published var lastDiagnostics: String?
    /// True while `buildProduct` matches the current source (cleared on writes).
    @Published var buildIsCurrent = false
    /// Bumped when the agent rewrites the file, so the editor reloads.
    @Published var fileVersion = 0

    private var task: Task<Void, Never>?

    init(projectID: String, projects: ProjectStore, auth: AuthStore) {
        self.projectID = projectID
        self.projects = projects
        self.auth = auth
        self.messages = projects.loadMessages(projectID)
    }

    var client: ChatModel? {
        guard let key = auth.key, let provider = auth.provider else { return nil }
        if ProcessInfo.processInfo.environment["ISO_PLAYGROUND_AGENT_MOCK"] == "1" { return MockChatModel() }
        switch provider {
        case .openRouter: return OpenRouterClient(key: key)
        case .anthropic: return AnthropicClient(key: key)
        }
    }

    func send(_ text: String, images: [Data] = []) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !images.isEmpty, !busy else { return }
        var message = ChatMessage(role: .user, text: prompt)
        let saved = images.compactMap { projects.saveImage($0, in: projectID) }
        if !saved.isEmpty { message.images = saved }
        messages.append(message)
        persist()
        task = Task { await runLoop() }
    }

    func cancel() {
        task?.cancel()
        busy = false
        activity = nil
    }

    /// Records something the app did on the user's behalf (an asset import)
    /// as a tool-style transcript row the model also sees.
    func note(_ text: String, tool: String) {
        messages.append(ChatMessage(role: .tool, text: text, toolName: tool))
        persist()
    }

    private func persist() { projects.saveMessages(messages, in: projectID) }

    private func runLoop() async {
        guard let client else { error = "Not signed in"; return }
        busy = true
        error = nil
        defer { busy = false; activity = nil; streamingText = "" }
        var iterations = 0
        while iterations < 16, !Task.isCancelled {
            iterations += 1
            streamingText = ""
            activity = "Thinking…"
            var text = ""
            var calls: [ToolCall] = []
            do {
                let tools = auth.harness == .agent ? Self.tools : []
                let options = ChatOptions(
                    reasoningEffort: auth.reasoningEffort,
                    resolveImage: { [projects, projectID] path in projects.imageData(path, in: projectID) })
                for try await event in client.stream(system: Self.systemPrompt, messages: messages, tools: tools, model: auth.modelID, options: options) {
                    switch event {
                    case .text(let delta):
                        text += delta
                        streamingText = text
                    case .toolCall(let call):
                        calls.append(call)
                    case .finished:
                        break
                    }
                }
            } catch {
                self.error = error.localizedDescription
                messages.append(ChatMessage(role: .assistant, text: text.isEmpty ? "(request failed: \(error.localizedDescription))" : text))
                persist()
                return
            }
            messages.append(ChatMessage(role: .assistant, text: text, toolCalls: calls))
            streamingText = ""
            persist()
            if calls.isEmpty { return }
            for call in calls {
                if Task.isCancelled { return }
                activity = Self.activityLabel(call)
                let result = await execute(call)
                var reply = ChatMessage(role: .tool, text: result.text, toolCallID: call.id, toolName: call.name)
                if let image = result.image, let path = projects.saveImage(image, in: projectID) {
                    reply.images = [path]
                }
                messages.append(reply)
                persist()
            }
        }
    }

    static func activityLabel(_ call: ToolCall) -> String {
        let args = call.argumentsObject
        switch call.name {
        case "write_file": return "Writing \(args["name"] as? String ?? "file")…"
        case "read_file": return "Reading \(args["name"] as? String ?? "file")…"
        case "delete_file": return "Deleting \(args["name"] as? String ?? "file")…"
        case "build": return "Building…"
        case "run": return "Running…"
        case "screenshot": return "Taking a screenshot…"
        case "logs": return "Reading the logs…"
        case "close_run": return "Closing the app…"
        case "web_search": return "Searching the web…"
        case "crash_report": return "Reading the crash report…"
        case "ui_tree": return "Reading the view tree…"
        case "tap": return "Tapping \(args["target"] as? String ?? "")…"
        case "type_text": return "Typing into \(args["target"] as? String ?? "")…"
        case "submit": return "Pressing Return…"
        case "swipe": return "Swiping \(args["target"] as? String ?? "")…"
        case "fetch_url": return "Reading \((args["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a page")…"
        default: return call.name
        }
    }

    // MARK: Tools

    static let tools: [ToolSpec] = [
        ToolSpec(name: "list_files", description: "List the Swift source files in the project.", parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]),
        ToolSpec(name: "read_file", description: "Read a source file.", parameters: ["type": "object", "properties": ["name": ["type": "string", "description": "File name, e.g. ContentView.swift"]], "required": ["name"]]),
        ToolSpec(name: "write_file", description: "Replace the project's single source file (App.swift) with the given FULL contents.", parameters: ["type": "object", "properties": ["name": ["type": "string", "description": "Always App.swift"], "contents": ["type": "string"]], "required": ["name", "contents"]]),
        ToolSpec(name: "delete_file", description: "Delete a source file.", parameters: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]),
        ToolSpec(name: "build", description: "Compile every file in the project. Returns 'ok' or the compiler diagnostics to fix.", parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]),
        ToolSpec(name: "run", description: "Launch the latest successful build offscreen at the device's screen size (it stays up until close_run; the user does not see it — they keep the chat and can play their own copy). Call after build returns ok.", parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]),
        ToolSpec(name: "screenshot", description: "Capture your running build and attach it as an image so you can check your work against the request or a mock. Launches the latest build first if it is not running; waits for it to load.", parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]),
        ToolSpec(name: "logs", description: "The running app's recent log output: load status, print() output and runtime errors.", parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]),
        ToolSpec(name: "close_run", description: "Close the running app and return to the chat.", parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]),
        ToolSpec(name: "ui_tree", description: "The running build's view tree, one node per line: path, kind, text, accessibility label/identifier, and which nodes take [tap], [edit], [submit] or [drag]. Read it before tap/type/swipe, and after an action to see what changed (cheaper than a screenshot).", parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]),
        ToolSpec(name: "tap", description: "Tap a node of the running build: a Button, list row, NavigationLink, Toggle… Target is a tree path from ui_tree (e.g. \"0.2.1\") or a label (accessibility label/identifier, visible text, or placeholder).", parameters: ["type": "object", "properties": ["target": ["type": "string"]], "required": ["target"]]),
        ToolSpec(name: "type_text", description: "Replace a text field's contents in the running build (target: path or its placeholder/label). Follow with submit to press Return.", parameters: ["type": "object", "properties": ["target": ["type": "string"], "text": ["type": "string"]], "required": ["target", "text"]]),
        ToolSpec(name: "submit", description: "Press Return in a text field of the running build (fires its onSubmit).", parameters: ["type": "object", "properties": ["target": ["type": "string"]], "required": ["target"]]),
        ToolSpec(name: "swipe", description: "A finite swipe on a view with a DragGesture in the running build: the drag's onChanged runs over the motion and onEnded lands at (dx, dy) points (e.g. dx -120 for a left swipe). Native ScrollViews cannot be swiped here.", parameters: ["type": "object", "properties": ["target": ["type": "string"], "dx": ["type": "number"], "dy": ["type": "number"]], "required": ["target", "dx", "dy"]]),
        ToolSpec(name: "crash_report", description: "The most recent crash of the Playground while a build of this project was running (yours, or the user's when they played it): which run, the run's last log lines, and the OS crash diagnostic when available. Call it when the user says the app crashed, or when a transcript note reports one.", parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]),
        ToolSpec(name: "web_search", description: "Search the web (like a search engine): returns a short answer plus the pages found with URLs. Use it for facts you need and don't know — a public API or endpoint, a data source, a current value. Costs about a cent per call; don't search for SwiftUI basics.", parameters: ["type": "object", "properties": ["query": ["type": "string", "description": "What to search for, as you would type it into a search engine"]], "required": ["query"]]),
        ToolSpec(name: "fetch_url", description: "Read a public web page or API response as text (HTML is reduced to its visible text; JSON comes back verbatim, truncated when long). Use it to see an API's real response shape before writing code against it, or to read a page web_search found.", parameters: ["type": "object", "properties": ["url": ["type": "string", "description": "Absolute http(s) URL"]], "required": ["url"]]),
    ]

    /// A tool's outcome: text for the transcript, plus an optional image
    /// (the `screenshot` tool) that rides along to the model.
    struct ToolResult {
        var text: String
        var image: Data? = nil
    }

    private func execute(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case "screenshot":
            guard let wasm = buildProduct else { return ToolResult(text: "error: no successful build yet — call build first") }
            if !HeadlessRun.shared.isRunning {
                RunMonitor.shared.beginRun()
                HeadlessRun.shared.start(wasm: wasm, projectID: projectID, projects: projects)
            }
            guard await RunMonitor.shared.waitUntilLoaded() else {
                return ToolResult(text: "error: the app did not finish loading.\n" + RunMonitor.shared.recentLog(limit: 30))
            }
            #if os(iOS)
            guard let image = HeadlessRun.shared.screenshot() else { return ToolResult(text: "error: could not capture the run") }
            return ToolResult(text: "Screenshot of your running build attached (rendered at the device's screen size).", image: image)
            #else
            return ToolResult(text: "error: screenshots are only available on iOS")
            #endif
        case "logs":
            return ToolResult(text: RunMonitor.shared.recentLog())
        case "close_run":
            switch await HeadlessRun.shared.stop(timeout: 1) {
            case .graceful: return ToolResult(text: "closed")
            case .unsupported: return ToolResult(text: "closed (the build has no shutdown export; torn down immediately)")
            case .forced(let pending): return ToolResult(text: "closed (forced after 1s: \(pending) task(s) never finished — an await on something that never completes?)")
            }
        case "ui_tree", "tap", "type_text", "submit", "swipe":
            return ToolResult(text: await drive(call))
        case "crash_report":
            return ToolResult(text: CrashRecorder.shared.latestReport(for: projectID))
        case "web_search":
            guard let query = call.argumentsObject["query"] as? String else { return ToolResult(text: "error: missing query") }
            guard let key = auth.key, let provider = auth.provider else { return ToolResult(text: "error: web search needs a signed-in provider") }
            return ToolResult(text: await WebTools.search(query: query, provider: provider, key: key))
        case "fetch_url":
            guard let url = call.argumentsObject["url"] as? String else { return ToolResult(text: "error: missing url") }
            return ToolResult(text: await WebTools.fetch(urlString: url))
        default:
            return ToolResult(text: await executeFileOrBuild(call))
        }
    }

    /// The driving tools act on the agent's offscreen run (started if needed).
    private func drive(_ call: ToolCall) async -> String {
        let args = call.argumentsObject
        if !HeadlessRun.shared.isRunning {
            guard let wasm = buildProduct else { return "error: no successful build yet — call build first" }
            RunMonitor.shared.beginRun()
            HeadlessRun.shared.start(wasm: wasm, projectID: projectID, projects: projects)
            guard await RunMonitor.shared.waitUntilLoaded() else {
                return "error: the app did not finish loading.\n" + RunMonitor.shared.recentLog(limit: 30)
            }
        }
        let target = args["target"] as? String ?? ""
        let result: String
        switch call.name {
        case "ui_tree": return HeadlessRun.shared.treeDump()
        case "tap": result = HeadlessRun.shared.tap(target)
        case "type_text": result = HeadlessRun.shared.type(target, text: args["text"] as? String ?? "")
        case "submit": result = HeadlessRun.shared.submit(target)
        case "swipe":
            let dx = (args["dx"] as? NSNumber)?.doubleValue ?? 0
            let dy = (args["dy"] as? NSNumber)?.doubleValue ?? 0
            result = await HeadlessRun.shared.swipe(target, dx: dx, dy: dy)
        default: result = "error: unknown tool"
        }
        // Let the guest render the consequence before the agent looks.
        try? await Task.sleep(nanoseconds: 350_000_000)
        return result
    }

    private func executeFileOrBuild(_ call: ToolCall) async -> String {
        let args = call.argumentsObject
        switch call.name {
        case "list_files":
            let names = projects.fileNames(in: projectID)
            var out = names.isEmpty ? "(no files)" : names.joined(separator: "\n")
            let assets = projects.importedAssets(in: projectID)
            if !assets.isEmpty {
                out += "\n\nImported assets (in the app's Documents: Data(contentsOf: URL.documentsDirectory.appendingPathComponent(path))):\n"
                out += assets.map { "\($0.path) (\($0.size / 1024) KB)" }.joined(separator: "\n")
            }
            return out
        case "read_file":
            guard let name = args["name"] as? String else { return "error: missing name" }
            return projects.read(name, in: projectID) ?? "error: no such file \(name)"
        case "write_file":
            guard let name = args["name"] as? String, let contents = args["contents"] as? String else { return "error: missing name/contents" }
            var safe = (name as NSString).lastPathComponent
            guard safe.hasSuffix(".swift") else { return "error: only .swift files" }
            // Single-file projects: everything lands in App.swift.
            if safe != projectMainFile { safe = projectMainFile }
            projects.write(safe, contents: contents, in: projectID)
            buildIsCurrent = false
            fileVersion += 1
            return "wrote \(safe) (\(contents.utf8.count) bytes)"
        case "delete_file":
            guard let name = args["name"] as? String else { return "error: missing name" }
            projects.deleteFile((name as NSString).lastPathComponent, in: projectID)
            return "deleted \(name)"
        case "build":
            // Same path as the user's play button: a snapshot of the sources
            // compiled off the main thread, the product recorded on the session.
            switch await ProjectBuilder.build(session: self, projects: projects) {
            case .success(let wasm):
                return "ok (\(wasm.count) bytes)"
            case .failure(let failure):
                return failure.diagnostics.hasPrefix("error:") ? failure.diagnostics : "build failed:\n" + String(failure.diagnostics.prefix(6000))
            }
        case "run":
            guard let wasm = buildProduct else { return "error: no successful build yet — call build first" }
            // Offscreen: the user keeps the chat (and can play their own copy).
            RunMonitor.shared.beginRun()
            HeadlessRun.shared.start(wasm: wasm, projectID: projectID, projects: projects)
            let loaded = await RunMonitor.shared.waitUntilLoaded()
            MemoryFootprint.log("run loaded")
            return loaded ? "running (offscreen — screenshot to see it)" : "launched, but it did not report loading:\n" + RunMonitor.shared.recentLog(limit: 30)
        default:
            return "error: unknown tool \(call.name)"
        }
    }

    static let systemPrompt = """
    You are the coding agent inside Isomer Playground, an iOS app that compiles Swift to WebAssembly on the device and renders it with a SwiftUI reimplementation (Isomer). You write the app the user describes, build it, fix any compiler errors, and run it.

    Environment: the code compiles with Swift 6.3 to wasm32 and runs inside the Playground's preview (the real SwiftUI renderer on device; the react renderer in Safari). Foundation is Isomer's (Apple's API, a subset): URL, Date, UUID, Data, JSONEncoder/JSONDecoder with Codable, URLSession (`try await URLSession.shared.data(from: url)`), FileManager in the app's own directories (`URL.documentsDirectory`, `URL.applicationSupportDirectory`; each project has its own), UserDefaults and @AppStorage. Models are `@Observable` classes (`import Observation`) held in @State and passed with `.environment(model)` / read with `@Environment(Model.self)`.

    Injected services (module `PlatformServices`; add `import PlatformServices` to use them). Each is optional (nil when the host doesn't provide it):
    - `PlatformDependencies.keychain?` — `get(key:) async throws -> [UInt8]` (throws when absent), `set(value: [UInt8], for: String) async throws`. Secrets only.
    - `PlatformDependencies.analytics?.track(event:)`, `PlatformDependencies.configuration?.flag(key:) -> Bool`.
    - Imported assets: the user can import photos and files into the app's Documents under `imported/` (list_files shows them). Read one with `Data(contentsOf: URL.documentsDirectory.appendingPathComponent("imported/<name>"))`.
    - `PlatformDependencies.imagePicker?.pickImage(maxDimension: Int) async throws -> String` — presents the platform photo/file picker and returns a URL of the chosen image ("" when cancelled); show it with `AsyncImage(url: URL(string: url))`. The only way to get a user's image (no PhotosPicker/UIImagePickerController).
    - JSON (`import Isomer`): `parseJSON(text) -> JSONValue?` with subscripts `json["key"]`, `.array`, `.object`, `.string`, `.int`, `.double`, `.bool`; build with `JSONValue.object([...])`/`.array`/`.string`/`.number`/`.bool` and `.encoded()`. (Codable with JSONDecoder works too.)

    Rules for the code you write:
    - ONE FILE: the whole app lives in App.swift (this is a prototyping tool). It starts with `import SwiftUI` (plus `import Foundation` and `import Observation` when used, `import PlatformServices` when using the services, and `import Isomer` for the JSON helpers, `Platform.current` or `WebView`). Do NOT import Combine, UIKit or any other framework.
    - Exactly one `@main struct … : App` with `var body: some Scene { WindowGroup { RootView() } }`, followed by the views.
    - Use the mainstream SwiftUI subset: VStack/HStack/ZStack/Spacer/Divider, Text, Image(systemName:), Button (styles: bordered/borderedProminent/plain), Toggle, Slider, Stepper, TextField, Picker (.segmented/.menu), List (with Section, selection, ForEach), ScrollView, Form, LabeledContent, NavigationStack/NavigationLink/.navigationTitle/.toolbar/ToolbarItem, NavigationSplitView, TabView(.tabItem), sheet/alert/popover, GeometryReader, Shapes (Rectangle/RoundedRectangle/Circle/Capsule) with fill/stroke, Color, gradients, .padding/.frame/.background/.foregroundColor/.font/.cornerRadius/.overlay/.opacity/.shadow, @State/@Binding/@Bindable/@AppStorage/@Environment(\\.dismiss)/@Environment(Model.self), withAnimation, Task/async-await, Timer via .task loops.
    - Also available: `.onSubmit {}` on text fields (Enter submits; Shift+Enter is a newline in `TextField(axis: .vertical)`), `.overlay(alignment:) {}` / `.background(alignment:) {}`, `.tint(_:)`, `.position(x:y:)`, `.offset`, `.scaleEffect`, `.rotationEffect`, `.opacity`, `withAnimation` with `.repeatForever(autoreverses:)` / `.repeatCount` / `.delay`, `.task {}` / `.task(id:)`, `Task.sleep(for:)` for delays, `DragGesture`, `.accessibilityLabel/Hint/Value/Identifier/Hidden`, `.ignoresSafeArea()`, `.toolbarTitleDisplayMode`, `.preferredColorScheme`, `@FocusState` + `.focused($state)` / `.focused($field, equals:)`, `.textInputAutocapitalization`, `.autocorrectionDisabled()`, `.truncationMode`, `ScrollViewReader` + `proxy.scrollTo(id, anchor:)` with `.id(_:)`. The app's root is laid out inside the safe area like a real app (only your own `.ignoresSafeArea()` views extend under the status bar), and a text field at the bottom rises above the keyboard automatically; the default TextField has no border (add your own bubble). `Image(systemName:)` draws the real SF Symbol on iOS and a matching glyph on other renderers.
    - Avoid: UIKit, Combine (no ObservableObject, @Published, @StateObject, @ObservedObject), Dispatch (use Task and async/await), string formatting with %; keep numbers as simple text.
    - Keep files small and complete: always write the FULL file contents.

    Workflow: read_file App.swift when editing existing work, write_file App.swift with the full contents, call build. If build returns diagnostics, fix them and build again (up to a few rounds). When build returns ok, call run, then reply with one or two sentences about what you built. Keep chat replies short; the code lives in the files.

    Research: web_search works like a search engine (a short answer plus the pages found) and fetch_url reads one page or API response as text. Use them when the app needs a public data source or an API you are not sure about: search for the endpoint, fetch_url its actual response to see the JSON shape (and confirm it allows unauthenticated requests), then write the parsing against what you saw. Both are for facts, not for SwiftUI questions; search costs a little per call, fetch is free. The app itself reaches the network only through PlatformDependencies.networking.

    Checking your work: the user may attach images (mocks, screenshots, photos) — implement what they show. After run, call screenshot to see the app as rendered at the device's screen size and compare it with the request or the mock; call logs when something looks wrong at runtime (print() output and load errors show up there). Fix, build, run and screenshot again until it matches, then close_run and reply. Drive the app to test flows: ui_tree lists every node with its text/labels and what it accepts ([tap], [edit], [submit], [drag]); tap/type_text/submit/swipe act on a node by path or label, then screenshot or ui_tree again to check the result (give buttons and fields .accessibilityLabel/.accessibilityIdentifier so they are easy to target). Swipes drive DragGestures you wrote; native scrolling is not scriptable. If the Playground itself crashes while a build runs, a note appears in the transcript and crash_report has the details (which run, its last log lines, the OS diagnostic when available); the user may also just say "it crashed" — call crash_report then. Your run is offscreen: the user does not see it, and may be playing an earlier build of their own meanwhile — nothing you do interrupts them.
    """
}

extension Notification.Name {
    static let playgroundRun = Notification.Name("playground.run")
}

extension ToolCall {
    var argumentsObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
    }
}

/// Headless stand-in (ISO_PLAYGROUND_AGENT_MOCK=1): writes a small app, builds,
/// fixes a deliberate error, runs — exercises the whole loop without a key.
struct MockChatModel: ChatModel {
    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec], model: String, options: ChatOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let lastTool = messages.last(where: { $0.role == .tool })
            let toolMessages = messages.filter { $0.role == .tool }
            let step = toolMessages.count
            func call(_ name: String, _ args: [String: Any]) -> ToolCall {
                ToolCall(id: "mock_\(step)", name: name, arguments: String(data: (try? JSONSerialization.data(withJSONObject: args)) ?? Data(), encoding: .utf8) ?? "{}")
            }
            switch step {
            case 0:
                continuation.yield(.toolCall(call("crash_report", [:])))
            case 1:
                continuation.yield(.toolCall(call("fetch_url", ["url": "https://example.com/"])))
            case 2:
                continuation.yield(.text("Writing the app."))
                // ISO_PLAYGROUND_MOCK_SOURCE=<path>: build THAT file instead of the
                // counter (a way to drive any app through the tools headlessly).
                if let path = ProcessInfo.processInfo.environment["ISO_PLAYGROUND_MOCK_SOURCE"],
                   let source = try? String(contentsOfFile: path, encoding: .utf8) {
                    continuation.yield(.toolCall(call("write_file", ["name": "App.swift", "contents": source])))
                    break
                }
                continuation.yield(.toolCall(call("write_file", ["name": "App.swift", "contents": "import SwiftUI\n\n@main\nstruct MockApp: App {\n    var body: some Scene { WindowGroup { RootView() } }\n}\n\nstruct RootView: View {\n    @State private var count = 0\n    var body: some View {\n        VStack(spacing: 12) {\n            Text(\"Mock agent build\")\n            Text(\"Count: \\(count)\")\n            Button(\"Add\") { count += \"1\" }\n        }\n        .padding()\n    }\n}\n"])))
            case 3:
                continuation.yield(.toolCall(call("build", [:])))
            case 4:
                let failed = lastTool?.text.hasPrefix("build failed") == true
                if failed, ProcessInfo.processInfo.environment["ISO_PLAYGROUND_MOCK_SOURCE"] == nil {
                    continuation.yield(.text("Fixing the type error."))
                    continuation.yield(.toolCall(call("write_file", ["name": "App.swift", "contents": "import SwiftUI\nimport PlatformServices\n\n@main\nstruct MockApp: App {\n    var body: some Scene { WindowGroup { RootView() } }\n}\n\nstruct RootView: View {\n    @State private var count = 0\n    @State private var saved = \"(none)\"\n    @State private var status = \"(pending)\"\n    var body: some View {\n        VStack(spacing: 12) {\n            Text(\"Mock agent build\")\n            Text(\"Count: \\(count)\")\n            Text(\"Saved: \\(saved)\")\n            Text(\"HTTP: \\(status)\")\n            Button(\"Add\") { count += 1 }\n        }\n        .padding()\n        .task {\n            if let files = PlatformDependencies.file {\n                _ = files.write(path: \"notes/hello.txt\", contents: Array(\"hello from wasm\".utf8))\n                if let bytes = try? files.read(path: \"notes/hello.txt\") { saved = String(decoding: bytes, as: UTF8.self) }\n            }\n            do {\n                guard let net = PlatformDependencies.networking else { status = \"no network service\"; return }\n                let bytes = try await net.request(url: \"https://example.com/\", method: \"GET\")\n                status = \"ok \\(bytes.count) bytes\"\n            } catch {\n                status = \"error \\(error)\"\n            }\n        }\n    }\n}\n"])))
                } else {
                    continuation.yield(.toolCall(call("run", [:])))
                }
            case 5:
                continuation.yield(.toolCall(call("build", [:])))
            case 6:
                continuation.yield(.toolCall(call("run", [:])))
            case 7:
                continuation.yield(.toolCall(call("screenshot", [:])))
            case 8:
                continuation.yield(.toolCall(call("ui_tree", [:])))
            case 9:
                continuation.yield(.toolCall(call("tap", ["target": ProcessInfo.processInfo.environment["ISO_PLAYGROUND_MOCK_TAP"] ?? "Add"])))
            case 10:
                continuation.yield(.toolCall(call("ui_tree", [:])))
            case 11:
                continuation.yield(.toolCall(call("logs", [:])))
            case 12:
                // ISO_PLAYGROUND_MOCK_KEEP_RUN=1 leaves the offscreen run up (the
                // coexisting-runs probe measures two live runtimes).
                if ProcessInfo.processInfo.environment["ISO_PLAYGROUND_MOCK_KEEP_RUN"] == "1" {
                    continuation.yield(.text("Leaving the app running."))
                } else {
                    continuation.yield(.toolCall(call("close_run", [:])))
                }
            default:
                continuation.yield(.text("Built a counter app with an Add button."))
            }
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}
