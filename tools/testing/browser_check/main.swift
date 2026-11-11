// browser_check: a web site's pages loaded in headless Chrome, each waited for
// and pictured, for tests that run where the site was built (a Linux
// container in CI, a Mac by hand). It serves the site on a loopback port of
// its own, starts Chrome with a profile of its own and drives it over the
// DevTools protocol on a pipe (--remote-debugging-pipe: no port, nothing
// listening but the site), and stops both however it ends.
//
//   browser_check --site <dir> [--chrome <path>] [--width 1280] [--height 800]
//                 [--until "<js>"] [--timeout 60] [--settle 2]
//                 [--flag=<chrome flag>]… [--allow-errors] [--hold]
//                 --page "<path and query>=<out.png>" [--page …]
//
// Each page is loaded in turn and waited for until `--until` (a JavaScript
// expression) is true, then `--settle` seconds more, then pictured (PNG). A
// page that never gets there, or that throws, fails the run (exit 1), as
// does an error on the console unless `--allow-errors`. The console and the
// exceptions are printed either way. CHROME in the environment names Chrome
// when `--chrome` doesn't. `--hold` keeps the last page open after its
// picture, its console still printed, until the process is told to stop
// (SIGTERM or SIGINT): a headful app a test drives, launched this way. While
// it holds, `--requests <dir>` takes a picture for each `<n>.request` file
// that appears there (the file holds the picture's path; the request is
// removed once the picture is written): a test's `picture`.
//
// For comparing two renderings of a site (the web's DOM renderer against
// React's, story by story): `--dom` also writes each page's DOM beside its
// picture (<out>.dom.txt: elements with their attributes and inline style
// declarations sorted, and their text, one a line, indented by depth), and
// `--reference <dir>` compares each picture with the one of the same name
// there, in Chrome's own canvas, printing how many pixels differ
// ("browser_check: <name>: N pixels differ"; a different size counts every
// pixel) and writing <out>.diff.txt with the count. Neither fails the run.
import BrowserDriving
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct Options {
    var site = ""
    var chrome = ProcessInfo.processInfo.environment["CHROME"] ?? ""
    var width = 1280
    var height = 800
    var until = "document.readyState === 'complete'"
    var timeout = 60.0
    var settle = 2.0
    var flags: [String] = []
    var allowErrors = false
    var hold = false
    var requests = ""
    var dom = false
    var reference = ""
    var pages: [(path: String, out: String)] = []

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var rest = arguments[...]
        func value(_ name: String) -> String {
            guard let next = rest.popFirst() else { fail("\(name) needs a value") }
            return next
        }
        while let argument = rest.popFirst() {
            if argument.hasPrefix("--flag=") {
                options.flags.append(String(argument.dropFirst("--flag=".count)))
                continue
            }
            switch argument {
            case "--site": options.site = value(argument)
            case "--chrome": options.chrome = value(argument)
            case "--width": options.width = Int(value(argument)) ?? options.width
            case "--height": options.height = Int(value(argument)) ?? options.height
            case "--until": options.until = value(argument)
            case "--timeout": options.timeout = Double(value(argument)) ?? options.timeout
            case "--settle": options.settle = Double(value(argument)) ?? options.settle
            case "--allow-errors": options.allowErrors = true
            case "--hold": options.hold = true
            case "--requests": options.requests = value(argument)
            case "--dom": options.dom = true
            case "--reference": options.reference = value(argument)
            case "--page":
                let page = value(argument)
                guard let equals = page.lastIndex(of: "=") else { fail("--page wants <path>=<out.png>: \(page)") }
                options.pages.append((String(page[..<equals]), String(page[page.index(after: equals)...])))
            default: fail("unknown argument \(argument)")
            }
        }
        if options.site.isEmpty || options.pages.isEmpty { fail("usage: browser_check --site <dir> --page <path>=<out.png>…") }
        if options.chrome.isEmpty { fail("no Chrome: --chrome <path> or CHROME") }
        return options
    }
}

// MARK: The run

BrowserDriving.tool = "browser_check"

// A write to a Chrome that went away fails rather than ends the run.
signal(SIGPIPE, SIG_IGN)

/// --hold's end: set by SIGTERM or SIGINT.
enum Held {
    nonisolated(unsafe) static var stopping: sig_atomic_t = 0
}
signal(SIGTERM) { _ in Held.stopping = 1 }
signal(SIGINT) { _ in Held.stopping = 1 }
let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let server = SiteServer(root: URL(fileURLWithPath: options.site))
server.start()
let profile = FileManager.default.temporaryDirectory.appendingPathComponent("browser-check-\(getpid())").path
try? FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true)
let chrome = Chrome(path: options.chrome, profile: profile, width: options.width, height: options.height, flags: options.flags)
var failures: [String] = []

func finish() -> Never {
    chrome.stop()
    try? FileManager.default.removeItem(atPath: profile)
    if failures.isEmpty {
        try? FileManager.default.removeItem(atPath: chrome.logPath)
        print("browser_check: \(options.pages.count) page(s) loaded and pictured")
        exit(0)
    }
    for failure in failures { log("FAILED: \(failure)") }
    if let output = try? String(contentsOfFile: chrome.logPath, encoding: .utf8) {
        log("Chrome's last output:\n" + output.split(separator: "\n").suffix(30).joined(separator: "\n"))
    }
    try? FileManager.default.removeItem(atPath: chrome.logPath)
    exit(1)
}

guard let target = chrome.send("Target.createTarget", ["url": "about:blank"], timeout: 60)?["targetId"] as? String,
      let session = chrome.send("Target.attachToTarget", ["targetId": target, "flatten": true])?["sessionId"] as? String
else {
    failures.append("Chrome never answered (\(options.chrome))")
    finish()
}
chrome.send("Page.enable", session: session)
chrome.send("Runtime.enable", session: session)
chrome.send("Emulation.setDeviceMetricsOverride",
            ["width": options.width, "height": options.height, "deviceScaleFactor": 1, "mobile": false], session: session)
chrome.send("Emulation.setEmulatedMedia", ["features": [["name": "prefers-color-scheme", "value": "light"]]], session: session)

/// The page's console and exceptions since the last call, printed; the
/// errors among them returned.
func drainConsole(_ name: String) -> [String] {
    var errors: [String] = []
    for event in chrome.takeEvents() {
        guard let method = event["method"] as? String, let params = event["params"] as? [String: Any] else { continue }
        if method == "Runtime.consoleAPICalled" {
            let type = params["type"] as? String ?? "log"
            let text = (params["args"] as? [[String: Any]] ?? []).map { "\($0["value"] ?? $0["description"] ?? "")" }.joined(separator: " ")
            print("[\(name)] [\(type)] \(text)")
            if type == "error" { errors.append("console error: \(text)") }
        } else if method == "Runtime.exceptionThrown" {
            let details = params["exceptionDetails"] as? [String: Any] ?? [:]
            let exception = (details["exception"] as? [String: Any])?["description"] ?? details["text"] ?? "?"
            print("[\(name)] [exception] \(exception)")
            errors.append("exception: \(exception)")
        }
    }
    return errors
}

/// The page's DOM as text, one line an element or text: the tag, its
/// attributes sorted (the inline style apart, its declarations sorted), then
/// its children indented. Scripts and the injected stylesheets' text are
/// left out; what differs between two renderers of one tree shows as a line.
let domDump = #"""
(() => {
  const out = [];
  const walk = (node, depth) => {
    const pad = "  ".repeat(depth);
    if (node.nodeType === 3) {
      const text = node.textContent.replace(/\s+/g, " ").trim();
      if (text) out.push(pad + JSON.stringify(text));
      return;
    }
    if (node.nodeType !== 1) return;
    const tag = node.tagName.toLowerCase();
    if (tag === "script" || tag === "style") { out.push(pad + "<" + tag + ">"); return; }
    const attributes = [...node.attributes].filter(a => a.name !== "style")
      .map(a => a.name + "=" + JSON.stringify(a.value)).sort();
    const style = node.getAttribute("style");
    if (style) {
      const declarations = [];
      for (let i = 0; i < node.style.length; i++) {
        const name = node.style[i];
        declarations.push(name + ": " + node.style.getPropertyValue(name));
      }
      attributes.push("style={" + declarations.sort().join("; ") + "}");
    }
    out.push(pad + "<" + tag + (attributes.length ? " " + attributes.join(" ") : "") + ">");
    for (const child of node.childNodes) walk(child, depth + 1);
  };
  walk(document.body, 0);
  return out.join("\n") + "\n";
})()
"""#

/// How many pixels of two PNGs differ, counted in the page's canvas (no PNG
/// decoder here off Apple's platforms); every pixel of the larger when their
/// sizes differ.
func differingPixels(_ a: Data, _ b: Data, session: String) -> Int? {
    let expression = """
    (async () => {
      const load = (b64) => new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = reject;
        image.src = "data:image/png;base64," + b64;
      });
      const [a, b] = await Promise.all([load("\(a.base64EncodedString())"), load("\(b.base64EncodedString())")]);
      if (a.width !== b.width || a.height !== b.height) return Math.max(a.width * a.height, b.width * b.height);
      const pixels = (image) => {
        const canvas = document.createElement("canvas");
        canvas.width = image.width;
        canvas.height = image.height;
        const context = canvas.getContext("2d");
        context.drawImage(image, 0, 0);
        return context.getImageData(0, 0, image.width, image.height).data;
      };
      const pa = pixels(a), pb = pixels(b);
      let changed = 0;
      for (let i = 0; i < pa.length; i += 4) {
        if (pa[i] !== pb[i] || pa[i + 1] !== pb[i + 1] || pa[i + 2] !== pb[i + 2] || pa[i + 3] !== pb[i + 3]) changed++;
      }
      return changed;
    })()
    """
    let result = chrome.send("Runtime.evaluate", ["expression": expression, "awaitPromise": true, "returnByValue": true],
                             session: session, timeout: 60)
    return ((result?["result"] as? [String: Any])?["value"] as? NSNumber)?.intValue
}

for page in options.pages {
    let url = "http://127.0.0.1:\(server.port)/" + page.path.drop(while: { $0 == "/" })
    let name = URL(fileURLWithPath: page.out).deletingPathExtension().lastPathComponent
    log("\(name): \(url)")
    _ = chrome.send("Page.navigate", ["url": url], session: session)
    let deadline = Date().addingTimeInterval(options.timeout)
    var ready = false
    while Date() < deadline {
        let result = chrome.send("Runtime.evaluate", ["expression": "Boolean(\(options.until))", "returnByValue": true], session: session)
        if ((result?["result"] as? [String: Any])?["value"] as? Bool) == true {
            ready = true
            break
        }
        usleep(250_000)
    }
    if !ready { failures.append("\(name): not ready in \(Int(options.timeout)) s (\(options.until))") }
    usleep(useconds_t(options.settle * 1_000_000))
    if let data = (chrome.send("Page.captureScreenshot", ["format": "png"], session: session)?["data"] as? String)
        .flatMap({ Data(base64Encoded: $0) }) {
        let out = URL(fileURLWithPath: page.out)
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: out) } catch { failures.append("\(name): \(error)") }
        if !options.reference.isEmpty {
            let reference = URL(fileURLWithPath: options.reference).appendingPathComponent(out.lastPathComponent)
            if let other = try? Data(contentsOf: reference) {
                let changed = differingPixels(data, other, session: session)
                print("browser_check: \(name): \(changed.map(String.init) ?? "?") pixels differ")
                try? Data("\(changed.map(String.init) ?? "?")\n".utf8).write(to: out.appendingPathExtension("diff.txt"))
            } else {
                print("browser_check: \(name): no reference \(reference.path)")
            }
        }
    } else {
        failures.append("\(name): no picture")
    }
    if options.dom {
        let result = chrome.send("Runtime.evaluate", ["expression": domDump, "returnByValue": true], session: session)
        if let text = (result?["result"] as? [String: Any])?["value"] as? String {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: page.out).appendingPathExtension("dom.txt"))
        } else {
            print("browser_check: \(name): no DOM")
        }
    }
    let errors = drainConsole(name)
    let counted = errors.filter { options.allowErrors ? $0.hasPrefix("exception") : true }
    failures += counted.map { "\(name): \($0)" }
}
if options.hold, let last = options.pages.last {
    let name = URL(fileURLWithPath: last.out).deletingPathExtension().lastPathComponent
    log("\(name): held open until stopped")
    while Held.stopping == 0 {
        usleep(200_000)
        // A test's pictures, as asked.
        if !options.requests.isEmpty,
           let names = try? FileManager.default.contentsOfDirectory(atPath: options.requests) {
            for request in names.sorted() where request.hasSuffix(".request") {
                let path = options.requests + "/" + request
                guard let target = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                if let data = (chrome.send("Page.captureScreenshot", ["format": "png"], session: session)?["data"] as? String)
                    .flatMap({ Data(base64Encoded: $0) }) {
                    try? data.write(to: URL(fileURLWithPath: target.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        let errors = drainConsole(name)
        failures += errors.filter { options.allowErrors ? $0.hasPrefix("exception") : true }.map { "\(name): \($0)" }
    }
}
finish()
