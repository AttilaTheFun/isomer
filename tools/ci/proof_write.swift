// The proof in Reviews' format 2 (the private AttilaTheFun/reviews'
// docs/PROOF_FORMAT.md): every picture an item under an id stable from
// release to release, proof.json beside them, nothing compared (Reviews
// compares a release's proof with the one before it). Made from the review
// folders tools/proof/proof.py writes (review-<platform>-<app>/, each with
// its manifest.json and pictures), and from pictures tests took
// (HeadlessApp.picture: screens/<id>.png).
//
//   swiftc -O -o proof_write tools/ci/proof_write.swift
//   proof_write <out> --app <App> --version <version> --repository <owner/name>
//               --commit <sha> [--run <id>] <folder>…
//
// Each folder is searched for review-*/manifest.json and for screens/. The
// ids:
//   review-ios-storybook         ios/phone/<story>
//   review-ios-storybook-isomer  ios/phone-isomer/<story> (the iPhone
//                                Storybook compiled against Isomer's
//                                frameworks), and tests/parity-ios: its
//                                stories that differ from Apple's
//   review-macos-storybook       macos/window/<story>
//   review-android-storybook     android/phone/<story>
//   review-web-storybook         web/desktop/<story>
//   review-linux-storybook       linux/window/<story>
//   review-windows-storybook     windows/window/<story>
// <out> gets proof.json, screens/<id>.png and logs/.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("proof_write: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    fail("usage: proof_write <out> --app <App> --version <v> --repository <r> --commit <sha> [--run <id>] <folder>…")
}
let out = URL(fileURLWithPath: arguments.removeFirst())
var options: [String: String] = [:]
var folders: [URL] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument.hasPrefix("--") {
        guard !arguments.isEmpty else { fail("\(argument) takes a value") }
        options[String(argument.dropFirst(2))] = arguments.removeFirst()
    } else {
        folders.append(URL(fileURLWithPath: argument))
    }
}
for key in ["app", "version", "repository", "commit"] where options[key] == nil { fail("--\(key) is required") }

let files = FileManager.default

/// A PNG's width and height, from its IHDR (bytes 16 to 23).
func pngSize(_ url: URL) -> (Int, Int)? {
    guard let data = try? Data(contentsOf: url), data.count > 24, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
    func number(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
    return (number(16), number(20))
}

/// A file's SHA-256, by the system's own tool (sha256sum on Linux, shasum
/// on a Mac).
func sha256(_ url: URL) -> String {
    let process = Process()
    let pipe = Pipe()
    if files.isExecutableFile(atPath: "/usr/bin/sha256sum") {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.arguments = [url.path]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
    }
    process.standardOutput = pipe
    do { try process.run() } catch { fail("no SHA-256 for \(url.path): \(error)") }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard let digest = output.split(separator: " ").first, digest.count == 64 else { fail("no SHA-256 for \(url.path)") }
    return String(digest)
}

/// Where a review folder's pictures go: its platform and device.
let devices: [String: String] = [
    "ios-storybook": "ios/phone",
    "ios-storybook-isomer": "ios/phone-isomer",
    "macos-storybook": "macos/window",
    "android-storybook": "android/phone",
    "web-storybook": "web/desktop",
    "linux-storybook": "linux/window",
    "windows-storybook": "windows/window",
]

func valid(_ id: String) -> Bool {
    !id.isEmpty && id.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber || "-./".contains($0) }
}

var screens: [String: [String: Any]] = [:]
var tests: [[String: Any]] = []

/// One picture, an item.
func add(id: String, title: String?, picture: URL) {
    guard valid(id) else { fail("\(id) is no proof id (lowercase letters, digits, - . /)") }
    guard screens[id] == nil else { fail("\(id) twice") }
    let file = "screens/\(id).png"
    let target = out.appendingPathComponent(file)
    try? files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? files.removeItem(at: target)
    do { try files.copyItem(at: picture, to: target) } catch { fail("\(picture.path): \(error)") }
    guard let (width, height) = pngSize(target) else { fail("\(picture.path) is no PNG") }
    var item: [String: Any] = ["id": id, "kind": "screen", "file": file, "sha256": sha256(target),
                               "width": width, "height": height]
    if let title { item["title"] = title }
    screens[id] = item
}

for folder in folders {
    guard let walker = files.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
    for case let url as URL in walker {
        // A review folder: its manifest's items.
        if url.lastPathComponent == "manifest.json", url.deletingLastPathComponent().lastPathComponent.hasPrefix("review-") {
            let cellFolder = url.deletingLastPathComponent()
            let cell = String(cellFolder.lastPathComponent.dropFirst("review-".count))
            guard let device = devices[cell] else {
                FileHandle.standardError.write(Data("proof_write: \(cell): no device for it, left out\n".utf8))
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = manifest["items"] as? [[String: Any]] else { fail("\(url.path) is no manifest") }
            var parity: [(String, Int)] = []
            var compared = 0
            for entry in items {
                // The item's name is the story's title ("Text styles"); its
                // capture is named by the story's id (text.styles.png), which
                // is the proof's id.
                guard let name = entry["name"] as? String, let capture = entry["capture"] as? String else { continue }
                let picture = cellFolder.appendingPathComponent(capture)
                guard files.fileExists(atPath: picture.path) else { continue }
                let story = URL(fileURLWithPath: capture).deletingPathExtension().lastPathComponent
                add(id: "\(device)/\(story.lowercased())", title: name, picture: picture)
                if entry["parity"] != nil {
                    compared += 1
                    if let changed = entry["changed_px"] as? Int, changed > 0 { parity.append((story, changed)) }
                }
            }
            // The iPhone Storybook on Isomer's frameworks held to Apple's:
            // a tests item, its failures the stories that differ.
            if cell == "ios-storybook-isomer", compared > 0 {
                let log = "logs/parity-ios.txt"
                let lines = parity.map { "\($0.0): \($0.1) pixels differ" }
                try? files.createDirectory(at: out.appendingPathComponent("logs"), withIntermediateDirectories: true)
                try? (lines.isEmpty ? "every story matches Apple's SwiftUI\n" : lines.joined(separator: "\n") + "\n")
                    .write(to: out.appendingPathComponent(log), atomically: true, encoding: .utf8)
                tests.append(["id": "tests/parity-ios", "kind": "tests",
                              "title": "The iPhone Storybook on Isomer against Apple's SwiftUI",
                              "result": parity.isEmpty ? "passed" : "failed", "tests": compared,
                              "failures": parity.count, "log": log])
            }
        }
        // Pictures tests took: screens/<id>.png.
        if url.pathExtension == "png", url.path.contains("/screens/"),
           !url.path.contains("/review-") {
            let relative = url.path.components(separatedBy: "/screens/").last!
            add(id: String(relative.dropLast(".png".count)), title: nil, picture: url)
        }
    }
}

// In the order Reviews shows them: the platforms, then the tests.
let order = ["ios/phone/", "ios/phone-landscape/", "ios/phone-isomer/", "macos/", "android/", "web/", "linux/", "windows/"]
func rank(_ id: String) -> Int { order.firstIndex { id.hasPrefix($0) } ?? order.count }
let items = screens.values.sorted {
    let (a, b) = ($0["id"] as! String, $1["id"] as! String)
    return rank(a) != rank(b) ? rank(a) < rank(b) : a < b
} + tests

var proof: [String: Any] = [
    "format": 2,
    "app": options["app"]!,
    "version": options["version"]!,
    "repository": options["repository"]!,
    "commit": options["commit"]!,
    "made": ISO8601DateFormatter().string(from: Date()),
    "items": items,
]
if let run = options["run"].flatMap(Int.init) { proof["run"] = run }
try? files.createDirectory(at: out, withIntermediateDirectories: true)
let json = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: out.appendingPathComponent("proof.json"))
print("proof_write: \(screens.count) screens, \(tests.count) tests items, in \(out.path)/proof.json")
