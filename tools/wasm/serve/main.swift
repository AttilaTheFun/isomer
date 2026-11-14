// Serves a built static site from Bazel's runfiles on localhost and opens it
// in the default browser (pass --no-open not to, e.g. for CI): the
// `bazel run` of a web app (defs.bzl's web_server).
//
//     serve <site rootpath> [<port> [<query>]] [--no-open]
//
// `query` is added to the opened URL ("renderer=dom" picks the DOM
// renderer's binding; docs/renderer_layers.md). It was serve.py until 0.54:
// Swift, so a consumer's web app needs no Python to `bazel run`.
import BrowserDriving
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

BrowserDriving.tool = "serve"
// A browser that drops a connection mid-answer must not end the server.
signal(SIGPIPE, SIG_IGN)

let flags = CommandLine.arguments.dropFirst()
let openBrowser = !flags.contains("--no-open")
let arguments = flags.filter { $0 != "--no-open" }
guard let siteRootpath = arguments.first else { fail("usage: serve <site rootpath> [<port> [<query>]] [--no-open]") }
let portArgument = arguments.dropFirst().first ?? "8080"
guard let port = UInt16(portArgument) else { fail("not a port: \(portArgument)") }
let query = arguments.dropFirst(2).first.map { $0.isEmpty ? "" : "?\($0)" } ?? ""

// The site path is a main-repository rootpath, but this server may be
// isomer's, a dependency of the module run: `bazel run` starts in
// <runfiles>/_main, so the rootpath usually works as it is; otherwise look
// under the runfiles' _main (and at their root, for repository-qualified
// paths).
let environment = ProcessInfo.processInfo.environment
let runfiles = environment["RUNFILES_DIR"] ?? (CommandLine.arguments[0] + ".runfiles")
let candidates = [siteRootpath, runfiles + "/_main/" + siteRootpath, runfiles + "/" + siteRootpath]
let directory = candidates.first { candidate in
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue
}
guard let directory else {
    fail("site directory not found; tried:\n  " + candidates.joined(separator: "\n  "))
}

let server = SiteServer(root: URL(fileURLWithPath: directory).resolvingSymlinksInPath(), port: port)
server.start()
let url = "http://127.0.0.1:\(server.port)/\(query)"
print("Serving \(siteRootpath)")
print("  -> \(url)  (Ctrl-C to stop)")
fflush(stdout)

if openBrowser {
    // The system's own opener, as Python's webbrowser used.
    #if os(macOS)
    let opener = ["/usr/bin/open", url]
    #else
    let opener = ["/usr/bin/env", "xdg-open", url]
    #endif
    Thread.sleep(forTimeInterval: 0.3)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: opener[0])
    process.arguments = Array(opener.dropFirst())
    do {
        try process.run()
    } catch {
        log("couldn't open a browser (\(error)): open \(url) yourself")
    }
}
while true { sleep(3600) }
