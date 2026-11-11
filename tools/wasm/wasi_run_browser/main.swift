// wasi_run_browser: a WASI command module run in headless Chrome, by the
// browser's own engine, with //tools/wasm/wasi_run's command line, so a test
// that runs its check under one runs it under the other:
//
//   wasi_run_browser [--map-dir=/tmp::<dir>] [--env=NAME=VALUE]…
//                    [--stack-size=<bytes>] [--chrome=<path>] <module.wasm> [args…]
//
// The module runs in a page's worker (worker.js) over the web's own WASI
// file system (runtime/file_system.js): HOME laid out as an iOS container,
// /tmp in memory. A --map-dir of /tmp is that /tmp (nothing of the host's
// directory is read or written); any other directory is refused, as is
// --dir. --stack-size is WasmKit's interpreter's and means nothing here. The
// guest's stdout and stderr are this process's, as they are written; its exit
// code is this process's, 1 when it traps. Chrome is --chrome, else CHROME in
// the environment, else the one this binary was built with (Chrome for
// Testing on Linux; the Mac's own Chrome there).
import BazelRunfiles
import BrowserDriving
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

BrowserDriving.tool = "wasi_run_browser"
signal(SIGPIPE, SIG_IGN)

var environment: [String: String] = [:]
var chromePath = ProcessInfo.processInfo.environment["CHROME"] ?? ""
var arguments = Array(CommandLine.arguments.dropFirst())[...]
while let argument = arguments.first, argument.hasPrefix("--") {
    arguments.removeFirst()
    if argument.hasPrefix("--map-dir=") {
        let mapping = argument.dropFirst("--map-dir=".count)
        guard let separator = mapping.range(of: "::"), mapping[..<separator.lowerBound] == "/tmp" else {
            fail("only /tmp can be mapped (\(argument)): the guest's /tmp is the page's, in memory")
        }
    } else if argument.hasPrefix("--env=") {
        let pair = argument.dropFirst("--env=".count)
        guard let equals = pair.firstIndex(of: "=") else { fail("--env wants NAME=VALUE: \(argument)") }
        environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
    } else if argument.hasPrefix("--stack-size=") {
        continue
    } else if argument.hasPrefix("--chrome=") {
        chromePath = String(argument.dropFirst("--chrome=".count))
    } else if argument == "--" {
        break
    } else {
        fail("unknown option \(argument) (--dir isn't supported in the browser)")
    }
}
guard let modulePath = arguments.popFirst() else {
    fail("usage: wasi_run_browser [--map-dir=/tmp::<dir>] [--env=NAME=VALUE]… [--chrome=<path>] <module.wasm> [args…]")
}

// The page, the worker and the file system, and Chrome, from this binary's
// runfiles.
let runfiles: Runfiles
do { runfiles = try Runfiles.create() } catch { fail("no runfiles: \(error)") }
func runfile(_ path: String) -> URL {
    do { return try runfiles.rlocation(path) } catch { fail("no \(path) in the runfiles: \(error)") }
}
if chromePath.isEmpty {
    let named = runfile("isomer/tools/wasm/wasi_run_browser/chrome_path.txt")
    let path = (try? String(contentsOf: named, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    chromePath = path.hasPrefix("/") ? path : runfile(path).path
}

// The site: the page, the worker, the file system, the module and run.json.
let site = FileManager.default.temporaryDirectory.appendingPathComponent("wasi-run-browser-\(getpid())")
try? FileManager.default.removeItem(at: site)
do {
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    for (name, path) in [("index.html", "isomer/tools/wasm/wasi_run_browser/index.html"),
                         ("worker.js", "isomer/tools/wasm/wasi_run_browser/worker.js"),
                         ("file_system.js", "isomer/wasm/libraries/swift_ui/runtime/file_system.js")] {
        try FileManager.default.copyItem(at: runfile(path), to: site.appendingPathComponent(name))
    }
    let module = URL(fileURLWithPath: modulePath)
    try FileManager.default.copyItem(at: module.resolvingSymlinksInPath(), to: site.appendingPathComponent(module.lastPathComponent))
    let run: [String: Any] = ["module": module.lastPathComponent, "args": Array(arguments), "env": environment]
    try JSONSerialization.data(withJSONObject: run).write(to: site.appendingPathComponent("run.json"))
} catch {
    fail("couldn't lay out the page: \(error)")
}

let server = SiteServer(root: site)
server.start()
let profile = FileManager.default.temporaryDirectory.appendingPathComponent("wasi-run-browser-profile-\(getpid())").path
try? FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true)
let chrome = Chrome(path: chromePath, profile: profile, width: 800, height: 600, flags: [])

func finish(_ code: Int32) -> Never {
    chrome.stop()
    // Chrome itself failed: its last lines say why.
    if code == 3, let output = try? String(contentsOfFile: chrome.logPath, encoding: .utf8) {
        log("Chrome's last output:\n" + output.split(separator: "\n").suffix(30).joined(separator: "\n"))
    }
    try? FileManager.default.removeItem(atPath: profile)
    try? FileManager.default.removeItem(atPath: chrome.logPath)
    try? FileManager.default.removeItem(at: site)
    exit(code)
}

guard let target = chrome.send("Target.createTarget", ["url": "about:blank"], timeout: 60)?["targetId"] as? String,
      let session = chrome.send("Target.attachToTarget", ["targetId": target, "flatten": true])?["sessionId"] as? String
else {
    log("Chrome never answered (\(chromePath))")
    finish(3)
}
chrome.send("Runtime.enable", session: session)
chrome.send("Page.navigate", ["url": "http://127.0.0.1:\(server.port)/index.html"], session: session)

// What the guest wrote, as it writes it, until it ends.
let take = "JSON.stringify({ output: (window.__wasiOutput || []).splice(0), exit: window.__wasiExit })"
while true {
    usleep(100_000)
    // An exception in the page (the worker's own are its output).
    for event in chrome.takeEvents() where event["method"] as? String == "Runtime.exceptionThrown" {
        let details = (event["params"] as? [String: Any])?["exceptionDetails"] as? [String: Any] ?? [:]
        log("the page threw: \((details["exception"] as? [String: Any])?["description"] ?? details["text"] ?? "?")")
        finish(1)
    }
    let answer = chrome.send("Runtime.evaluate", ["expression": take, "returnByValue": true], session: session, timeout: 60)
    guard let answer else {
        log("Chrome went away")
        finish(3)
    }
    guard let text = (answer["result"] as? [String: Any])?["value"] as? String,
          let state = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { continue }
    for case let chunk as [Any] in state["output"] as? [Any] ?? [] {
        guard chunk.count == 2, let fd = chunk[0] as? Int, let text = chunk[1] as? String else { continue }
        writeAll(fd == 2 ? 2 : 1, Data(text.utf8))
    }
    if let code = state["exit"] as? Int {
        finish(Int32(truncatingIfNeeded: code))
    }
}
