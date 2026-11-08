// isomer: drive Isomer apps from a terminal, an agent or a script, wherever
// they run (docs/drive_plan.md). Apps are kept by name with their URL and
// token; one is selected, and commands go to it:
//
//   isomer application add <name> <url> [--token <token> | --token-file <path>]
//   isomer application remove <name>
//   isomer application select <name>
//   isomer application list
//   isomer application stop <name>          an exec: app started in the background
//
//   isomer ls | info
//   isomer tap <element>
//   isomer type <element> <text>
//   isomer set <element> <value>
//   isomer select <element> <option>
//   isomer swipe [<element>] <up|down|left|right>
//   isomer back | dismiss
//   isomer wait <text> [--timeout <seconds>]
//   isomer drive                            commands as JSON lines on standard input
//
//   isomer hub [--grpc <port>] [--ws <port>] [--host <address>] [--token <token>]
//                                           where headful apps dial out to
//                                           (ISO_DRIVER=grpc://host:port), each
//                                           then an app: grpc://host:port/<name>
//
// Options for the commands: --app <name> (not the selected one), --url <url>
// (no name at all), --json (each answer as protobuf's JSON). URLs: grpc://,
// grpcs://, ws://, unix:<socket>, exec:<an app built headless> (started on
// the first command, kept running on a Unix socket until `stop`).
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
    FileHandle.standardError.write(Data("isomer: \(message)\n".utf8))
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
            case "--json": json = true
            case "--timeout": timeout = Double(arguments.isEmpty ? "" : arguments.removeFirst()) ?? 0
            default: rest.append(argument)
            }
        }
    }
}

func endpoint(_ options: Options) throws -> (IsomerRemote.Endpoint, String?) {
    if let url = options.url { return (try IsomerRemote.endpoint(url), ProcessInfo.processInfo.environment["ISO_DRIVE_TOKEN"]) }
    let registry = Registry.load()
    guard let name = options.app ?? registry.selected else {
        fail("no application selected: isomer application add <name> <url>, then select <name>")
    }
    guard let application = registry.applications[name] else { fail("no application \(name)") }
    return (try IsomerRemote.endpoint(try reachableURL(name, application)), application.resolvedToken)
}

/// The command the arguments name, as headless.proto's.
func command(_ verb: String, _ rest: [String], _ options: Options) -> Wire_Command {
    var command = Wire_Command()
    command.cmd = verb
    func argument(_ index: Int, _ usage: String) -> String {
        guard index < rest.count else { fail("usage: isomer \(usage)") }
        return rest[index]
    }
    switch verb {
    case "ls", "info", "back", "dismiss", "quit": break
    case "tap": command.target = argument(0, "tap <element>")
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
    default: fail("unknown command \(verb) (isomer help)")
    }
    return command
}

/// An answer as a person reads it.
func describe(_ answer: Wire_Answer) -> String {
    var lines: [String] = []
    if answer.hasError { lines.append("error: \(answer.error)") }
    if answer.hasInfo {
        let info = answer.info
        lines.append("\(info.name) \(info.version) (\(info.bundleIdentifier))")
        lines.append("\(info.platform), \(info.renderer), \(Int(info.width))×\(Int(info.height))")
    }
    let screen = answer.screen
    for presentation in screen.presented {
        lines.append("[\(presentation.style)] \(presentation.title)\(presentation.message.isEmpty ? "" : ": \(presentation.message)")")
    }
    for element in screen.elements {
        var line = "\(element.role) \"\(element.label)\""
        if element.hasID { line += " #\(element.id)" }
        if element.hasValue { line += " = \(element.value)" }
        if !element.options.isEmpty { line += " [\(element.options.joined(separator: ", "))]" }
        lines.append(line)
    }
    if !screen.texts.isEmpty {
        lines.append("texts: " + screen.texts.joined(separator: " | "))
    }
    return lines.joined(separator: "\n")
}

func json(_ answer: Wire_Answer) -> String {
    (try? answer.jsonString()) ?? "{}"
}

/// Sends `commands`, printing each answer; false if one failed.
func run(_ commands: [Wire_Command], _ options: Options) async throws -> Bool {
    let (endpoint, token) = try endpoint(options)
    let call = try await endpoint.connection.drive(context: endpoint.context(token: token))
    var answers = call.inbound.makeAsyncIterator()
    var ok = true
    for command in commands {
        try await call.write(command)
        guard let answer = try await answers.next() else { fail("the app ended the call") }
        print(options.json ? json(answer) : describe(answer))
        if !answer.ok { ok = false }
    }
    await call.finish()
    return ok
}

/// Commands as JSON lines on standard input, each answer a line of JSON.
func driveInteractively(_ options: Options) async throws {
    let (endpoint, token) = try endpoint(options)
    let call = try await endpoint.connection.drive(context: endpoint.context(token: token))
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
        default: fail("usage: isomer hub [--grpc <port>] [--ws <port>] [--host <address>] [--token <token>]")
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
                    print("isomer hub: grpc://\(host):\(port) (apps dial out with ISO_DRIVER=grpc://\(host):\(port))")
                    fflush(stdout)
                }
            }
        }
        if let wsPort {
            guard #available(macOS 14, *) else { fail("the WebSocket hub needs macOS 14") }
            group.addTask {
                try await IsomerWebSocketServer(server, host: host, port: wsPort).run { port in
                    print("isomer hub: ws://\(host):\(port)")
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
    print("isomer application add|remove|select|list|stop …, then isomer ls|info|tap|type|set|select|swipe|back|dismiss|wait|drive, or isomer hub")
    exit(2)
}

do {
    switch verb {
    case "application", "applications", "app":
        var registry = Registry.load()
        let rest = Array(arguments.dropFirst())
        switch rest.first ?? "list" {
        case "add":
            guard rest.count >= 3 else { fail("usage: isomer application add <name> <url> [--token <token> | --token-file <path>]") }
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
            guard rest.count >= 2 else { fail("usage: isomer application stop <name>") }
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
            fail("usage: isomer application add|remove|select|list|stop")
        }
    case "hub":
        try await hub(Array(arguments.dropFirst()))
    case "drive":
        try await driveInteractively(parsed)
    case "help", "--help", "-h":
        print("See drive/cli/main.swift's header, or docs/drive.md.")
    default:
        exit(try await run([command(verb, Array(arguments.dropFirst()), parsed)], parsed) ? 0 : 1)
    }
} catch {
    fail("\(error)")
}
