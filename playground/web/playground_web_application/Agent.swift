// The web Playground's agent: the same tool loop as the iOS app, over
// OpenRouter chat completions (non-streaming; the host proxies the request
// with the stored key). Tools act on the selected project through the
// store and the host service (compile / run / logs).

import Foundation
import Observation
import SwiftUI
import Isomer

struct ToolCall: Equatable {
    var id: String
    var name: String
    var arguments: JSONValue
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, tool }
    var id: String = UUID().uuidString
    var role: Role
    var text: String = ""
    var toolCalls: [ToolCall] = []
    var toolCallID: String?
    var toolName: String?

    var json: JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "role": .string(role.rawValue), "text": .string(text)]
        if !toolCalls.isEmpty {
            object["toolCalls"] = .array(toolCalls.map { .object(["id": .string($0.id), "name": .string($0.name), "arguments": $0.arguments]) })
        }
        if let toolCallID { object["toolCallID"] = .string(toolCallID) }
        if let toolName { object["toolName"] = .string(toolName) }
        return .object(object)
    }

    init(role: Role, text: String = "", toolCalls: [ToolCall] = [], toolCallID: String? = nil, toolName: String? = nil) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
    }

    init?(json: JSONValue) {
        guard let roleName = json["role"].string, let role = Role(rawValue: roleName) else { return nil }
        self.init(role: role, text: json["text"].string ?? "")
        id = json["id"].string ?? id
        toolCalls = (json["toolCalls"].array ?? []).compactMap { call in
            guard let id = call["id"].string, let name = call["name"].string else { return nil }
            return ToolCall(id: id, name: name, arguments: call["arguments"])
        }
        toolCallID = json["toolCallID"].string
        toolName = json["toolName"].string
    }
}

@Observable
final class WebAgentSession {
    let projectID: String
    let store: WebProjectStore
    var messages: [ChatMessage]
    var busy = false
    var activity: String?
    var error: String?
    var lastDiagnostics: String?
    var buildOK = false
    /// Bumped when the agent rewrites the file, so the editor reloads.
    var fileVersion = 0
    var model: String { WebSettings.model }
    @ObservationIgnored private var task: Task<Void, Never>?

    init(projectID: String, store: WebProjectStore) {
        self.projectID = projectID
        self.store = store
        messages = store.loadChat(projectID)
    }

    func send(_ text: String) {
        let prompt = text.trimmed
        guard !prompt.isEmpty, !busy else { return }
        messages.append(ChatMessage(role: .user, text: prompt))
        persist()
        task = Task { await runLoop() }
    }

    func cancel() {
        task?.cancel()
        busy = false
        activity = nil
    }

    private func persist() { store.saveChat(messages, in: projectID) }

    private func runLoop() async {
        guard let host = PlaygroundHost.service else { error = "No host service"; return }
        guard host.hasKey() else { error = "Add your OpenRouter key first (gear icon)."; return }
        busy = true
        error = nil
        defer { busy = false; activity = nil }
        var iterations = 0
        while iterations < 16, !Task.isCancelled {
            iterations += 1
            activity = "Thinking…"
            let body = Self.requestBody(model: model, messages: messages)
            let reply: JSONValue
            do {
                let text = try await host.chat(body: body.encoded())
                guard let parsed = parseJSON(text) else { throw AgentError.badResponse(text) }
                if let message = parsed["error"]["message"].string { throw AgentError.badResponse(message) }
                reply = parsed
            } catch {
                self.error = "\(error)"
                messages.append(ChatMessage(role: .assistant, text: "(request failed: \(error))"))
                persist()
                return
            }
            let message = reply["choices"][0]["message"]
            let text = message["content"].string ?? ""
            let calls: [ToolCall] = (message["tool_calls"].array ?? []).compactMap { call in
                guard let id = call["id"].string, let name = call["function"]["name"].string else { return nil }
                let arguments = parseJSON(call["function"]["arguments"].string ?? "{}") ?? .object([:])
                return ToolCall(id: id, name: name, arguments: arguments)
            }
            messages.append(ChatMessage(role: .assistant, text: text, toolCalls: calls))
            persist()
            if calls.isEmpty { return }
            for call in calls {
                if Task.isCancelled { return }
                activity = Self.activityLabel(call)
                let result = await execute(call)
                messages.append(ChatMessage(role: .tool, text: result, toolCallID: call.id, toolName: call.name))
                persist()
            }
        }
    }

    enum AgentError: Error, CustomStringConvertible {
        case badResponse(String)
        var description: String {
            switch self { case .badResponse(let text): return String(text.prefix(300)) }
        }
    }

    static func activityLabel(_ call: ToolCall) -> String {
        switch call.name {
        case "write_file": return "Writing App.swift…"
        case "read_file": return "Reading App.swift…"
        case "build": return "Building…"
        case "run": return "Running…"
        case "logs": return "Reading the logs…"
        case "close_run": return "Closing the app…"
        case "ui_tree": return "Reading the view tree…"
        case "tap": return "Tapping \(call.arguments["target"].string ?? "")…"
        case "type_text": return "Typing…"
        case "submit": return "Pressing Return…"
        case "swipe": return "Swiping…"
        default: return call.name
        }
    }

    // MARK: Tools

    static let toolSpecs: JSONValue = .array([
        tool("list_files", "List the project's source files.", [:]),
        tool("read_file", "Read a source file.", ["name": .object(["type": .string("string")])]),
        tool("write_file", "Replace App.swift with the given FULL contents.", ["name": .object(["type": .string("string")]), "contents": .object(["type": .string("string")])]),
        tool("build", "Compile the project. Returns 'ok' or the compiler diagnostics to fix.", [:]),
        tool("run", "Show the latest successful build full screen in the page (the user closes it with its Stop button, or call close_run).", [:]),
        tool("logs", "The running build's log: load status, print() output, runtime errors.", [:]),
        tool("close_run", "Close the running build.", [:]),
        tool("ui_tree", "The running build's view tree, one node per line: path, kind, text, accessibility label/identifier, and what it accepts ([tap], [edit], [submit], [drag]). Read it before tap/type_text/swipe and after an action to see what changed.", [:]),
        tool("tap", "Tap a node of the running build (a Button, row, link, toggle…) by tree path (e.g. \"0.2.1\") or label (accessibility label/identifier, visible text, placeholder).", ["target": .object(["type": .string("string")])]),
        tool("type_text", "Replace a text field's contents in the running build (target: path or placeholder/label).", ["target": .object(["type": .string("string")]), "text": .object(["type": .string("string")])]),
        tool("submit", "Press Return in a text field of the running build (fires onSubmit).", ["target": .object(["type": .string("string")])]),
        tool("swipe", "A finite swipe on a view with a DragGesture: onChanged runs over the motion and onEnded lands at (dx, dy) points. Native scrolling cannot be swiped.", ["target": .object(["type": .string("string")]), "dx": .object(["type": .string("number")]), "dy": .object(["type": .string("number")])]),
    ])

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("function"), "function": .object([
            "name": .string(name), "description": .string(description),
            "parameters": .object(["type": .string("object"), "properties": .object(properties), "required": .array(properties.keys.sorted().map { .string($0) })]),
        ])])
    }

    static func requestBody(model: String, messages: [ChatMessage]) -> JSONValue {
        var wire: [JSONValue] = [.object(["role": .string("system"), "content": .string(systemPrompt)])]
        for message in messages {
            switch message.role {
            case .user:
                wire.append(.object(["role": .string("user"), "content": .string(message.text)]))
            case .assistant:
                var entry: [String: JSONValue] = ["role": .string("assistant"), "content": .string(message.text)]
                if !message.toolCalls.isEmpty {
                    entry["tool_calls"] = .array(message.toolCalls.map {
                        .object(["id": .string($0.id), "type": .string("function"), "function": .object(["name": .string($0.name), "arguments": .string($0.arguments.encoded())])])
                    })
                }
                wire.append(.object(entry))
            case .tool:
                wire.append(.object(["role": .string("tool"), "tool_call_id": .string(message.toolCallID ?? ""), "content": .string(message.text)]))
            }
        }
        return .object(["model": .string(model), "messages": .array(wire), "tools": toolSpecs])
    }

    private func execute(_ call: ToolCall) async -> String {
        let host = PlaygroundHost.service
        switch call.name {
        case "list_files":
            return "App.swift"
        case "read_file":
            return store.source(projectID)
        case "write_file":
            guard let contents = call.arguments["contents"].string else { return "error: missing contents" }
            store.write(projectID, source: contents)
            buildOK = false
            fileVersion += 1
            return "wrote App.swift (\(contents.utf8.count) bytes)"
        case "build":
            return await build()
        case "run":
            guard buildOK else { return "error: no successful build yet — call build first" }
            do { return try await host?.run(project: projectID) ?? "error: no host" } catch { return "error: \(error)" }
        case "logs":
            return host?.logs() ?? "(no host)"
        case "close_run":
            host?.stop()
            return "closed"
        case "ui_tree":
            return host?.uiTree() ?? "(no host)"
        case "tap":
            do { return try await host?.tap(target: call.arguments["target"].string ?? "") ?? "error: no host" } catch { return "error: \(error)" }
        case "type_text":
            do { return try await host?.typeText(target: call.arguments["target"].string ?? "", text: call.arguments["text"].string ?? "") ?? "error: no host" } catch { return "error: \(error)" }
        case "submit":
            do { return try await host?.submit(target: call.arguments["target"].string ?? "") ?? "error: no host" } catch { return "error: \(error)" }
        case "swipe":
            do { return try await host?.swipe(target: call.arguments["target"].string ?? "", dx: call.arguments["dx"].double ?? 0, dy: call.arguments["dy"].double ?? 0) ?? "error: no host" } catch { return "error: \(error)" }
        default:
            return "error: unknown tool \(call.name)"
        }
    }

    /// Compiles the project's source through the host; "ok" on success.
    func build() async -> String {
        guard let host = PlaygroundHost.service else { return "error: no host" }
        do {
            let diagnostics = try await host.compile(source: store.source(projectID))
            if diagnostics.isEmpty {
                buildOK = true
                lastDiagnostics = nil
                return "ok"
            }
            buildOK = false
            lastDiagnostics = diagnostics
            return "build failed:\n" + String(diagnostics.prefix(6000))
        } catch {
            buildOK = false
            lastDiagnostics = "\(error)"
            return "build failed:\n\(error)"
        }
    }

    static let systemPrompt = """
    You are the coding agent inside Isomer Playground on the web: a page that compiles Swift to WebAssembly in the browser and renders it with a SwiftUI reimplementation (Isomer). You write the app the user describes, build it, fix any compiler errors, and run it.

    Environment: the code compiles with Swift 6.3 to wasm32 and runs inside the page. Foundation is Isomer's (Apple's API, a subset): URL, Date, UUID, Data, JSONEncoder/JSONDecoder with Codable, URLSession (`try await URLSession.shared.data(from: url)`; over the browser's fetch, so a server must allow the page's origin), FileManager in the app's own directories (`URL.documentsDirectory`, `URL.applicationSupportDirectory`; kept in the browser), UserDefaults and @AppStorage. This compiler has no macros: no @Observable — keep state in @State (value types, structs and arrays of them) and pass it down with @Binding.

    Injected services (module `PlatformServices`; add `import PlatformServices`). Each is optional (nil when absent):
    - `PlatformDependencies.imagePicker?.pickImage(maxDimension: Int) async throws -> String` — the browser's file picker; returns a URL for `AsyncImage(url: URL(string: url))` ("" when cancelled).
    - JSON (`import Isomer`): `parseJSON(text) -> JSONValue?` with subscripts `json["key"]`, `[index]`, `.array`, `.object`, `.string`, `.int`, `.double`, `.bool`; build with `JSONValue.object([...])`/`.array`/`.string`/`.number`/`.bool` and `.encoded()`. (Codable with JSONDecoder works too.)

    Rules for the code you write:
    - ONE FILE: the whole app lives in App.swift. It starts with `import SwiftUI` (plus `import Foundation`, `import PlatformServices` / `import Isomer` when used). Do NOT import Combine, UIKit or any other framework.
    - Exactly one `@main struct … : App` with `var body: some Scene { WindowGroup { RootView() } }`, followed by the views.
    - Use the mainstream SwiftUI subset: VStack/HStack/ZStack/Spacer/Divider, Text, Image(systemName:), Button, Toggle, Slider, Stepper, TextField, Picker, List (Section, selection, ForEach), ScrollView, Form, LabeledContent, NavigationStack/NavigationLink/.navigationTitle/.toolbar, NavigationSplitView, TabView, sheet/alert, GeometryReader, Shapes with fill/stroke, Color, gradients, .padding/.frame/.background/.foregroundColor/.font/.cornerRadius/.overlay/.opacity/.shadow, @State/@Binding/@AppStorage/@Environment(\\.dismiss), withAnimation (incl. .repeatForever), Task/async-await, .task {}, DragGesture, .onSubmit, .accessibilityLabel/Identifier, @FocusState + .focused, ScrollViewReader + scrollTo with .id.
    - No UIKit, Combine or Dispatch (use Task and async/await; `try await Task.sleep(for: .seconds(1))` for a delay). Keep numbers as simple text.
    - Always write the FULL file contents.

    Workflow: read_file when editing existing work, write_file with the full contents, call build. If build returns diagnostics, fix them and build again (a few rounds). When build returns ok, call run, then reply with one or two sentences about what you built. Keep replies short; the code lives in the file. Call logs when something looks wrong at runtime.

    Checking your work: after run, ui_tree lists every node with its text/labels and what it accepts ([tap], [edit], [submit], [drag]); tap/type_text/submit/swipe act on a node by path or label, then ui_tree again to check the result (give buttons and fields .accessibilityLabel/.accessibilityIdentifier so they are easy to target). The user sees the running build in the page while you drive it.
    """
}
