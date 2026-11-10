// iso: drive Isomer apps from a terminal, an agent or a script, wherever
// they run (docs/drive_plan.md). Apps are kept by name with their URL and
// token; one is selected, and commands go to it:
//
//   iso application add <name> <url> [--token <token> | --token-file <path>]
//   iso application remove <name>
//   iso application select <name>
//   iso application list
//   iso application stop <name>          an exec: app started in the background
//
//   iso ls [<role>…] | info              (ls text, ls button: one role)
//   iso inspect <element>                everything the app knows of one
//   iso tap <element>                    an element: its name (button-3,
//                                        text-2), identifier or label
//   iso type <element> <text>
//   iso set <element> <value>
//   iso select <element> <option>
//   iso swipe [<element>] <up|down|left|right>
//   iso back | dismiss
//   iso wait <text> [--timeout <seconds>]
//   iso drive                            commands as JSON lines on standard input
//
//   iso hub [--grpc <port>] [--ws <port>] [--host <address>] [--token <token>]
//                                        a hub of your own, where headful apps
//                                        dial out to (ISO_DRIVER=grpc://host:port),
//                                        each then an app: grpc://host:port/<name>
//   iso apps                             the apps attached to the hub on this machine
//   iso hub stop                         ends the hub iso started
//
// Options for the commands: --url <url> (an app by its URL), --app <name> (an
// application kept by name, not the selected one), --json (each answer as
// protobuf's JSON). URLs: grpc://, grpcs://, ws://, unix:<socket>, exec:<an
// app built headless> (started on the first command, kept running on a Unix
// socket until `stop`).
//
// With no application named or selected, the commands go to the apps
// attached to the hub on this machine (ws://127.0.0.1:7710), started in the
// background if none is running. Apps built with --config=cli
// (--@isomer//drive:headful) dial it when launched without ISO_DRIVER, each
// under its platform's name: `--app ios,android` names some, `--all` (or no
// --app, with several attached) every one, each driven at once and its
// answers printed under its name. A command waits for the apps it names to
// attach, so the apps and the CLI start in either order.
//
// The applications are kept in $XDG_CONFIG_HOME/isomer (~/.config/isomer),
// readable only by their user.

import Foundation
import IsomerGRPCTransport
import IsomerRemote
import IsomerServing
import IsomerWebSocketTransport
import IsomerWire
import SwiftProtobuf
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - The registry

struct Application: Codable {
    var url: String
    var token: String?
    var tokenFile: String?

    var resolvedToken: String? {
        if let token { return token }
        guard let tokenFile, let text = try? String(contentsOfFile: tokenFile, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

struct Registry: Codable {
    var selected: String?
    var applications: [String: Application] = [:]

    static var directory: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("isomer")
    }

    static var file: URL { directory.appendingPathComponent("applications.json") }

    static func load() -> Registry {
        guard let data = try? Data(contentsOf: file) else { return Registry() }
        return (try? JSONDecoder().decode(Registry.self, from: data)) ?? Registry()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file, options: .atomic)
        chmod(Self.file.path, 0o600)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("iso: \(message)\n".utf8))
    exit(1)
}

// MARK: - exec: apps, kept running on a Unix socket

/// Where an exec: app started in the background listens, and its process.
func runFiles(_ name: String) -> (socket: String, pid: URL, log: URL) {
    let directory = Registry.directory.appendingPathComponent("run")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return (directory.appendingPathComponent("\(name).sock").path,
            directory.appendingPathComponent("\(name).pid"),
            directory.appendingPathComponent("\(name).log"))
}

func running(_ pidFile: URL) -> Int32? {
    guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0 else { return nil }
    return pid
}

/// The URL commands reach an app by: an exec: app's socket, the app started
/// first if it isn't running.
func reachableURL(_ name: String, _ application: Application) throws -> String {
    guard application.url.hasPrefix("exec:") else { return application.url }
    let files = runFiles(name)
    if running(files.pid) != nil, FileManager.default.fileExists(atPath: files.socket) { return "unix:" + files.socket }
    var parts = String(application.url.dropFirst("exec:".count)).split(separator: " ").map(String.init)
    let path = parts.removeFirst()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = parts
    var environment = ProcessInfo.processInfo.environment
    environment["ISO_DRIVE_LISTEN"] = "unix:" + files.socket
    environment["ISO_HEADLESS_PROTOCOL"] = "serve"
    process.environment = environment
    FileManager.default.createFile(atPath: files.log.path, contents: nil)
    let log = try FileHandle(forWritingTo: files.log)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    try process.run()
    try String(process.processIdentifier).write(to: files.pid, atomically: true, encoding: .utf8)
    // Until it listens.
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: files.socket) { return "unix:" + files.socket }
        if !process.isRunning { fail("\(name) ended starting (\(files.log.path))") }
        usleep(50_000)
    }
    fail("\(name) didn't start listening (\(files.log.path))")
}

// MARK: - Commands

struct Options {
    var app: String?
    var url: String?
    var all = false
    var json = false
    var timeout: Double = 0
    var rest: [String] = []

    init(_ arguments: ArraySlice<String>) {
        var arguments = Array(arguments)
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--app": app = arguments.isEmpty ? nil : arguments.removeFirst()
            case "--url": url = arguments.isEmpty ? nil : arguments.removeFirst()
            case "--all": all = true
            case "--json": json = true
            case "--timeout": timeout = Double(arguments.isEmpty ? "" : arguments.removeFirst()) ?? 0
            default: rest.append(argument)
            }
        }
    }
}

/// Where the commands go: a URL, an application of the registry, or apps
/// attached to the hub on this machine.
enum Destination {
    case endpoint(IsomerRemote.Endpoint, token: String?)
    /// Apps attached to the local hub: these names, or (nil) every one.
    case hub([String]?)
}

/// The local hub, where apps built with --config=cli (--@isomer//drive:headful)
/// dial when launched without ISO_DRIVER (IsomerDriving).
let hubURL = "ws://127.0.0.1:\(IsomerDriving.hubPort)"

func destination(_ options: Options) throws -> Destination {
    if let url = options.url { return .endpoint(try IsomerRemote.endpoint(url), token: ProcessInfo.processInfo.environment["ISO_DRIVE_TOKEN"]) }
    let registry = Registry.load()
    if !options.all, let name = options.app ?? registry.selected, let application = registry.applications[name] {
        return .endpoint(try IsomerRemote.endpoint(try reachableURL(name, application)), token: application.resolvedToken)
    }
    if options.all { return .hub(nil) }
    // `--app ios,android`: apps attached to the hub by those names.
    return .hub(options.app.map { $0.split(separator: ",").map(String.init) })
}

/// The apps attached to the local hub, or nil when no hub answers there.
func attachedApps() async -> [Wire_Attachment]? {
    do {
        let endpoint = try IsomerRemote.endpoint(hubURL)
        let call = try await endpoint.connection.drive(context: endpoint.context(token: nil))
        var command = Wire_Command()
        command.cmd = "apps"
        try await call.write(command)
        var answers = call.inbound.makeAsyncIterator()
        let answer = try await answers.next()
        await call.finish()
        return answer?.apps ?? []
    } catch {
        return nil
    }
}

/// The local hub, started in the background (`iso hub stop` ends it) when
/// none answers; true when it was started now.
func ensureHub() async -> Bool {
    if await attachedApps() != nil { return false }
    let files = runFiles("hub")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    process.arguments = ["hub", "--ws", String(IsomerDriving.hubPort), "--detach"]
    FileManager.default.createFile(atPath: files.log.path, contents: nil)
    guard let log = try? FileHandle(forWritingTo: files.log) else { fail("can't write \(files.log.path)") }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    do { try process.run() } catch { fail("can't start a hub: \(error)") }
    try? String(process.processIdentifier).write(to: files.pid, atomically: true, encoding: .utf8)
    for _ in 0..<100 {
        if await attachedApps() != nil {
            FileHandle.standardError.write(Data("iso: started a hub at \(hubURL), where apps built with --config=cli attach (iso hub stop ends it)\n".utf8))
            return true
        }
        if !process.isRunning { fail("the hub ended starting (\(files.log.path))") }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    fail("the hub didn't start listening (\(files.log.path))")
}

/// The names of the apps the commands go to, once they have attached: those
/// named, waited for; or every app attached (a moment's wait first when the
/// hub has just started, for the apps dialling it to attach).
func hubTargets(_ names: [String]?) async -> [String] {
    let started = await ensureHub()
    let deadline = Date().addingTimeInterval(20)
    var said = false
    if started, names == nil { try? await Task.sleep(nanoseconds: 2_500_000_000) }
    while true {
        let attached = (await attachedApps() ?? []).map(\.name)
        if let names {
            if names.allSatisfy(attached.contains) { return names }
        } else if !attached.isEmpty {
            return attached
        }
        if Date() > deadline {
            let missing = names.map { $0.filter { !attached.contains($0) } } ?? []
            fail("""
                \(names == nil ? "no app has attached" : "not attached: \(missing.joined(separator: ", "))") to the hub at \(hubURL)\
                \(attached.isEmpty ? "" : " (attached: \(attached.joined(separator: ", ")))"). Run apps built with --config=cli, \
                for example `bazel run //apple/storybook_ios_application --config=cli` in isomer's examples, or name one \
                elsewhere: iso application add <name> <url>
                """)
        }
        if !said {
            FileHandle.standardError.write(Data("iso: waiting for \(names?.joined(separator: ", ") ?? "an app") to attach to \(hubURL)…\n".utf8))
            said = true
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
}

/// The command the arguments name, as headless.proto's.
func command(_ verb: String, _ rest: [String], _ options: Options) -> Wire_Command {
    var command = Wire_Command()
    command.cmd = verb
    func argument(_ index: Int, _ usage: String) -> String {
        guard index < rest.count else { fail("usage: iso \(usage)") }
        return rest[index]
    }
    switch verb {
    case "ls":
        // `ls <role>…`: only those roles (the filter is the CLI's own: the
        // app answers with the whole screen).
        if !rest.isEmpty {
            shownRoles = Set(rest.map { role in
                let lower = role.lowercased()
                return lower.hasSuffix("s") && lower.count > 1 ? String(lower.dropLast()) : lower
            })
        }
    case "info", "back", "dismiss", "quit": break
    case "tap": command.target = argument(0, "tap <element>")
    case "inspect": command.target = argument(0, "inspect <element>")
    case "type":
        command.target = argument(0, "type <element> <text>")
        command.text = argument(1, "type <element> <text>")
    case "set":
        command.target = argument(0, "set <element> <value>")
        command.value = argument(1, "set <element> <value>")
    case "select":
        command.target = argument(0, "select <element> <option>")
        command.value = argument(1, "select <element> <option>")
    case "swipe":
        if rest.count >= 2 {
            command.target = rest[0]
            command.direction = rest[1]
        } else {
            command.direction = argument(0, "swipe [<element>] <up|down|left|right>")
        }
    case "wait":
        command.text = argument(0, "wait <text> [--timeout <seconds>]")
        command.timeout = options.timeout
    default: fail("unknown command \(verb) (iso help)")
    }
    return command
}

/// The roles `ls <role>` shows (button, text, textField, toggle, picker,
/// slider, sheet, alert…; a plural as its singular), every one when nil.
nonisolated(unsafe) var shownRoles: Set<String>?

/// A label or a text as Swift writes a string: in double quotes, its quotes
/// and backslashes escaped; one of several lines as a multiline literal
/// ("""), its lines as they are, only backslashes and a triple quote
/// escaped.
func quoted(_ text: String) -> String {
    let backslashed = text.replacingOccurrences(of: "\\", with: "\\\\")
    if text.contains("\n") {
        let body = backslashed.replacingOccurrences(of: "\"\"\"", with: "\\\"\"\"")
        return "\"\"\"\n" + body + "\n\"\"\""
    }
    return "\"" + backslashed.replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// An answer as a person reads it: a line an element, in the screen's order
/// (what is presented, the controls, then the texts).
func describe(_ answer: Wire_Answer) -> String {
    var lines: [String] = []
    if answer.hasError { lines.append("error: \(answer.error)") }
    // `info`: what the app is, not its screen (`ls` for that).
    if answer.hasInfo {
        let info = answer.info
        var first = info.name
        if !info.version.isEmpty { first += " \(info.version)" }
        if !info.bundleIdentifier.isEmpty { first += " (\(info.bundleIdentifier))" }
        lines.append(first)
        lines.append("\(info.platform), \(info.renderer), \(Int(info.width))×\(Int(info.height))")
        return lines.joined(separator: "\n")
    }
    func shown(_ role: String) -> Bool {
        shownRoles.map { $0.contains(role.lowercased()) } ?? true
    }
    let screen = answer.screen
    for presentation in screen.presented where shown(presentation.style) {
        var line = "\(presentation.style) \(quoted(presentation.title))"
        if !presentation.message.isEmpty { line += ": \(quoted(presentation.message))" }
        lines.append(line)
    }
    for element in screen.elements where shown(element.role) {
        var line = "\(element.name.isEmpty ? element.role : element.name) \(quoted(element.label))"
        if element.hasID { line += " #\(element.id)" }
        if element.hasValue { line += " = \(quoted(element.value))" }
        if !element.options.isEmpty { line += " [\(element.options.map(quoted).joined(separator: ", "))]" }
        lines.append(line)
    }
    if shown("text") {
        for (index, text) in screen.texts.enumerated() { lines.append("text-\(index + 1) \(quoted(text))") }
    }
    return lines.joined(separator: "\n")
}

/// `inspect`'s answer: a field a line.
func describe(_ inspection: Wire_Inspection) -> String {
    var lines = ["\(inspection.name) \(quoted(inspection.label))", "role: \(inspection.role)", "kind: \(inspection.kind)"]
    if inspection.hasID { lines.append("id: \(inspection.id)") }
    if inspection.hasValue { lines.append("value: \(quoted(inspection.value))") }
    if !inspection.options.isEmpty { lines.append("options: " + inspection.options.map(quoted).joined(separator: ", ")) }
    if inspection.hasContainer { lines.append("in: \(inspection.container)") }
    if !inspection.actions.isEmpty { lines.append("actions: " + inspection.actions.joined(separator: ", ")) }
    if inspection.hasFontSize || inspection.hasFontWeight {
        var font = "font:"
        if inspection.hasFontSize { font += " \(inspection.fontSize)pt" }
        if inspection.hasFontWeight { font += " weight \(inspection.fontWeight)" }
        lines.append(font)
    }
    if inspection.hasColor { lines.append("color: \(inspection.color)") }
    if inspection.hasLines { lines.append("lines: \(inspection.lines)") }
    if !inspection.texts.isEmpty, inspection.texts != [inspection.label],
       inspection.texts.joined(separator: "\n") != inspection.label {
        lines.append("texts: " + inspection.texts.map(quoted).joined(separator: ", "))
    }
    for key in inspection.params.keys.sorted() {
        lines.append("\(key): \(quoted(inspection.params[key]!))")
    }
    return lines.joined(separator: "\n")
}

func json(_ answer: Wire_Answer) -> String {
    (try? answer.jsonString()) ?? "{}"
}

/// An answer as the CLI prints it.
func render(_ answer: Wire_Answer, for command: Wire_Command, _ options: Options) -> String {
    if options.json { return json(answer) }
    if command.cmd == "inspect", answer.hasInspection { return describe(answer.inspection) }
    return describe(answer)
}

/// Sends `commands` over one call, answers in order; the answers so far and
/// the error that ended them early, if one did.
func send(_ commands: [Wire_Command], over endpoint: IsomerRemote.Endpoint, context: IsomerCallContext) async -> ([Wire_Answer], String?) {
    var answers: [Wire_Answer] = []
    do {
        let call = try await endpoint.connection.drive(context: context)
        var inbound = call.inbound.makeAsyncIterator()
        for command in commands {
            try await call.write(command)
            guard let answer = try await inbound.next() else { return (answers, "the app ended the call") }
            answers.append(answer)
        }
        await call.finish()
        return (answers, nil)
    } catch {
        return (answers, "\(error)")
    }
}

/// Sends `commands`, printing each answer; false if one failed. To several
/// apps on the hub at once, each app's answers under its name, in the order
/// the apps were named.
func run(_ commands: [Wire_Command], _ options: Options) async throws -> Bool {
    switch try destination(options) {
    case .endpoint(let endpoint, let token):
        let (answers, error) = await send(commands, over: endpoint, context: endpoint.context(token: token))
        for (command, answer) in zip(commands, answers) { print(render(answer, for: command, options)) }
        if let error { fail(error) }
        return answers.allSatisfy(\.ok)
    case .hub(let names):
        let targets = await hubTargets(names)
        let endpoint = try IsomerRemote.endpoint(hubURL)
        let results = await withTaskGroup(of: (String, [Wire_Answer], String?).self) { group in
            for target in targets {
                group.addTask {
                    let (answers, error) = await send(commands, over: endpoint, context: endpoint.context(token: nil, metadata: ["iso-target": target]))
                    return (target, answers, error)
                }
            }
            var results: [String: ([Wire_Answer], String?)] = [:]
            for await (target, answers, error) in group { results[target] = (answers, error) }
            return results
        }
        var ok = true
        for target in targets {
            let (answers, error) = results[target]!
            if targets.count > 1 { print("── \(target) ──") }
            for (command, answer) in zip(commands, answers) { print(render(answer, for: command, options)) }
            if let error { print("error: \(error)") }
            if error != nil || !answers.allSatisfy(\.ok) { ok = false }
        }
        return ok
    }
}

/// Commands as JSON lines on standard input, each answer a line of JSON.
func driveInteractively(_ options: Options) async throws {
    let endpoint: IsomerRemote.Endpoint
    let context: IsomerCallContext
    switch try destination(options) {
    case .endpoint(let given, let token):
        (endpoint, context) = (given, given.context(token: token))
    case .hub(let names):
        // One app: JSON lines are one conversation.
        let targets = await hubTargets(names)
        guard targets.count == 1 else { fail("iso drive drives one app: name it with --app (attached: \(targets.joined(separator: ", ")))") }
        endpoint = try IsomerRemote.endpoint(hubURL)
        context = endpoint.context(token: nil, metadata: ["iso-target": targets[0]])
    }
    let call = try await endpoint.connection.drive(context: context)
    var answers = call.inbound.makeAsyncIterator()
    var decoding = JSONDecodingOptions()
    decoding.ignoreUnknownFields = true
    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard let command = try? Wire_Command(jsonString: line, options: decoding) else {
            print(#"{"ok":false,"error":"not a command"}"#)
            continue
        }
        try await call.write(command)
        guard let answer = try await answers.next() else { break }
        print(json(answer))
        fflush(stdout)
        if command.cmd == "quit" { break }
    }
    await call.finish()
}

// MARK: - The hub headful apps dial out to

func hub(_ arguments: [String]) async throws {
    if arguments.first == "stop" {
        let files = runFiles("hub")
        if let pid = running(files.pid) {
            kill(pid, SIGTERM)
            print("stopped the hub at \(hubURL)")
        } else {
            print("no hub of iso's running")
        }
        try? FileManager.default.removeItem(at: files.pid)
        return
    }
    var grpcPort: Int?
    var wsPort: Int?
    var host = "127.0.0.1"
    var tokens: Set<String> = []
    var rest = arguments[...]
    while let argument = rest.popFirst() {
        switch argument {
        case "--grpc": grpcPort = Int(rest.popFirst() ?? "")
        case "--ws": wsPort = Int(rest.popFirst() ?? "")
        case "--host": host = rest.popFirst() ?? host
        case "--token": if let token = rest.popFirst() { tokens.insert(token) }
        // Started by `iso` itself: a session of its own, so the terminal's
        // signals to the command that started it don't reach it.
        case "--detach": _ = setsid()
        default: fail("usage: iso hub [--grpc <port>] [--ws <port>] [--host <address>] [--token <token>] | iso hub stop")
        }
    }
    if host != "127.0.0.1" && host != "localhost" && tokens.isEmpty {
        fail("a hub on \(host) needs a --token: apps and drivers on the network present it")
    }
    // Apps that dialled out (Driver.Attach), driven by name (IsomerHub).
    let server = IsomerHub(authorization: IsomerAuthorization(tokens: tokens)) { event in
        print(event)
        fflush(stdout)
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        if grpcPort != nil || wsPort == nil {
            guard #available(macOS 15.0, *) else { fail("the gRPC hub needs macOS 15: use --ws") }
            group.addTask {
                try await IsomerGRPCServer(server, host: host, port: grpcPort ?? 7700).run { port in
                    print("iso hub: grpc://\(host):\(port) (apps dial out with ISO_DRIVER=grpc://\(host):\(port))")
                    fflush(stdout)
                }
            }
        }
        if let wsPort {
            guard #available(macOS 14, *) else { fail("the WebSocket hub needs macOS 14") }
            group.addTask {
                try await IsomerWebSocketServer(server, host: host, port: wsPort).run { port in
                    print("iso hub: ws://\(host):\(port)")
                    fflush(stdout)
                }
            }
        }
        try await group.next()
    }
}

// MARK: - Main

// Options anywhere on the line; the first other word is the command.
let parsed = Options(CommandLine.arguments.dropFirst())
let arguments = parsed.rest[...]
guard let verb = arguments.first else {
    print("iso ls|info|tap|type|set|select|swipe|back|dismiss|wait|drive [--app <name>[,<name>…] | --all], iso apps, iso hub [stop], iso application add|remove|select|list|stop …")
    exit(2)
}

do {
    switch verb {
    case "application", "applications", "app":
        var registry = Registry.load()
        let rest = Array(arguments.dropFirst())
        switch rest.first ?? "list" {
        case "add":
            guard rest.count >= 3 else { fail("usage: iso application add <name> <url> [--token <token> | --token-file <path>]") }
            var application = Application(url: rest[2])
            if let index = rest.firstIndex(of: "--token"), index + 1 < rest.count { application.token = rest[index + 1] }
            if let index = rest.firstIndex(of: "--token-file"), index + 1 < rest.count { application.tokenFile = rest[index + 1] }
            _ = try IsomerRemote.endpoint(application.url.hasPrefix("exec:") ? "unix:/" : application.url)
            registry.applications[rest[1]] = application
            if registry.selected == nil { registry.selected = rest[1] }
            try registry.save()
            print("added \(rest[1])\(registry.selected == rest[1] ? " (selected)" : "")")
        case "remove":
            guard rest.count >= 2, registry.applications.removeValue(forKey: rest[1]) != nil else { fail("no application \(rest.dropFirst().first ?? "")") }
            if registry.selected == rest[1] { registry.selected = nil }
            try registry.save()
        case "select":
            guard rest.count >= 2, registry.applications[rest[1]] != nil else { fail("no application \(rest.dropFirst().first ?? "")") }
            registry.selected = rest[1]
            try registry.save()
        case "stop":
            guard rest.count >= 2 else { fail("usage: iso application stop <name>") }
            let files = runFiles(rest[1])
            if let pid = running(files.pid) { kill(pid, SIGTERM) }
            try? FileManager.default.removeItem(at: files.pid)
            try? FileManager.default.removeItem(atPath: files.socket)
        case "list":
            for name in registry.applications.keys.sorted() {
                let application = registry.applications[name]!
                print("\(name == registry.selected ? "*" : " ") \(name)  \(application.url)\(application.token != nil || application.tokenFile != nil ? "  (token)" : "")")
            }
        default:
            fail("usage: iso application add|remove|select|list|stop")
        }
    case "hub":
        try await hub(Array(arguments.dropFirst()))
    case "apps":
        _ = await ensureHub()
        for app in await attachedApps() ?? [] {
            print("\(app.name)  \(app.info.name) (\(app.info.platform), \(app.info.renderer))")
        }
    case "drive":
        try await driveInteractively(parsed)
    case "help", "--help", "-h":
        print("See xplat/iso/main.swift's header, or docs/drive.md.")
    default:
        exit(try await run([command(verb, Array(arguments.dropFirst()), parsed)], parsed) ? 0 : 1)
    }
} catch {
    fail("\(error)")
}
