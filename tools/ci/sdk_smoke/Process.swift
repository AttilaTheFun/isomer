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
/// captured.
@discardableResult
func run(_ arguments: [String], in directory: String? = nil, capture: Bool = false,
         environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
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
    process.environment = inherited.merging(environment) { $1 }
    var captured: URL?
    if capture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-smoke-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        process.standardOutput = handle
        captured = url
    }
    print("+ \(arguments.joined(separator: " "))\(directory.map { "   (in \($0))" } ?? "")")
    // What this printed before, ahead of the program's own output (a log's
    // standard output is buffered).
    fflush(stdout)
    try process.run()
    process.waitUntilExit()
    var output = ""
    if let captured {
        output = String(decoding: try Data(contentsOf: captured), as: UTF8.self)
        try? FileManager.default.removeItem(at: captured)
    }
    return (process.terminationStatus, output)
}

@discardableResult
func runChecked(_ arguments: [String], in directory: String? = nil, capture: Bool = false) throws -> String {
    let result = try run(arguments, in: directory, capture: capture)
    guard result.status == 0 else {
        throw ToolFailure("\(arguments.joined(separator: " ")) failed with exit code \(result.status)")
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
