import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ToolFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Runs a program with standard input closed (adb on Android 6.0 copies an
/// open one to the device until it closes), its output passed through or
/// captured. By posix_spawn and waitpid: Foundation's Process on Linux was
/// seen to leave an exited Bazel client unreaped and wait on it forever.
@discardableResult
func run(_ arguments: [String], in directory: String? = nil, capture: Bool = false,
         environment: [String: String] = [:], timeout: TimeInterval? = nil) throws -> (status: Int32, output: String) {
    // What `bazel run` sets for this program is not the fixture's: Bazelisk
    // puts the Bazel it ran (isomer's 9) first on PATH, where `bazel` would
    // find it in place of the fixture's .bazelversion (8), and the runfiles
    // and BUILD_ variables point into isomer's tree.
    var inherited = ProcessInfo.processInfo.environment.filter { name, _ in
        !(name.hasPrefix("BAZEL") || name.hasPrefix("BUILD_") || name.hasPrefix("RUNFILES") || name == "JAVA_RUNFILES")
    }
    if let path = inherited["PATH"] {
        inherited["PATH"] = path.split(separator: ":").filter { !$0.contains("/bazelisk/downloads/") }.joined(separator: ":")
    }
    let env = inherited.merging(environment) { $1 }.map { "\($0.key)=\($0.value)" }
    let captured = capture
        ? FileManager.default.temporaryDirectory.appendingPathComponent("sdk-smoke-\(UUID().uuidString)").path : nil

    print("+ \(arguments.joined(separator: " "))\(directory.map { "   (in \($0))" } ?? "")")
    // What this printed before, ahead of the program's own output (a log's
    // standard output is buffered).
    fflush(stdout)

    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    if let captured { posix_spawn_file_actions_addopen(&actions, 1, captured, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
    // In `directory` by the shell (posix_spawn's chdir action is a GNU and
    // Darwin extension Swift may not import), then the program by PATH.
    let command = directory.map { ["/bin/sh", "-c", "cd \"$0\" && exec \"$@\"", $0] } ?? ["/usr/bin/env"]
    let argv = (command + arguments).map { strdup($0) } + [nil]
    let envp = env.map { strdup($0) } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid = pid_t()
    let spawned = posix_spawn(&pid, command[0], &actions, nil, argv, envp)
    guard spawned == 0 else { throw ToolFailure("\(arguments.first ?? "") couldn't start: \(String(cString: strerror(spawned)))") }
    var status: Int32 = 0
    // With a deadline, a program that outlives it is killed: a hang fails
    // fast (`timedOut`) rather than at the job's limit.
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    while true {
        let reaped = waitpid(pid, &status, deadline == nil ? 0 : WNOHANG)
        if reaped == pid { break }
        if reaped == -1 {
            guard errno == EINTR else { throw ToolFailure("waitpid: \(String(cString: strerror(errno)))") }
            continue
        }
        if let deadline, Date() >= deadline {
            kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            print("(\(arguments.joined(separator: " ")) took longer than \(Int(timeout ?? 0)) s: killed)")
            fflush(stdout)
            return (timedOut, "")
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    // WIFEXITED / WEXITSTATUS, which Swift doesn't import as functions.
    let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    var output = ""
    if let captured {
        output = String(decoding: try Data(contentsOf: URL(fileURLWithPath: captured)), as: UTF8.self)
        try? FileManager.default.removeItem(atPath: captured)
    }
    return (exitCode, output)
}

/// The status `run` returns for a program it killed at its deadline (as
/// timeout(1) does).
let timedOut: Int32 = 124

@discardableResult
func runChecked(_ arguments: [String], in directory: String? = nil, capture: Bool = false,
                timeout: TimeInterval? = nil) throws -> String {
    let result = try run(arguments, in: directory, capture: capture, timeout: timeout)
    guard result.status == 0 else {
        throw ToolFailure("\(arguments.joined(separator: " ")) \(result.status == timedOut ? "timed out" : "failed with exit code \(result.status)")")
    }
    return result.output
}

/// A URL's body (an SDK's .sha256 beside it), http(s) or file.
func fetch(_ url: String) throws -> String {
    guard let parsed = URL(string: url) else { throw ToolFailure("not a URL: \(url)") }
    if parsed.isFileURL { return try String(contentsOf: parsed, encoding: .utf8) }
    return try runChecked(["curl", "-fsSL", "--retry", "3", url], capture: true)
}

/// A path made absolute against the directory `bazel run` was started in.
func absolute(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    let base = ProcessInfo.processInfo.environment["BUILD_WORKING_DIRECTORY"] ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: base).appendingPathComponent(path).standardizedFileURL.path
}

/// `run`, by a name a command's own `run()` doesn't hide.
func runStatus(_ arguments: [String], in directory: String? = nil, capture: Bool = false,
               timeout: TimeInterval? = nil) throws -> (status: Int32, output: String) {
    try run(arguments, in: directory, capture: capture, timeout: timeout)
}
