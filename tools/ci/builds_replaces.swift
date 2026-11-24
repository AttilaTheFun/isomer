// Adds to builds.json what each build's app replaces: the bundle ids it was
// released under before (tools/ci/replaces.json, a map from a bundle id to
// those). Shireworks' Applications reads it from a release's builds.json
// (`replaces`), and offers the new app in the old one's place; nothing
// there is hard-coded. Run by attach_release.sh, before builds.json is
// attached, on every draft and release.
//
//   swift tools/ci/builds_replaces.swift <builds.json> <replaces.json>
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: builds_replaces.swift <builds.json> <replaces.json>\n".utf8))
    exit(2)
}
let buildsURL = URL(fileURLWithPath: arguments[1])
let replacesURL = URL(fileURLWithPath: arguments[2])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("builds_replaces: \(message)\n".utf8))
    exit(1)
}

guard let replaces = (try? JSONSerialization.jsonObject(with: Data(contentsOf: replacesURL))) as? [String: [String]] else {
    fail("\(arguments[2]) is not a map from a bundle id to the bundle ids it replaces")
}
guard var builds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: buildsURL))) as? [[String: Any]] else {
    fail("\(arguments[1]) is not an array of builds")
}
var marked = 0
for index in builds.indices {
    guard let bundleID = builds[index]["bundleID"] as? String, let old = replaces[bundleID], !old.isEmpty else { continue }
    builds[index]["replaces"] = old
    marked += 1
}
do {
    let data = try JSONSerialization.data(withJSONObject: builds, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: buildsURL)
} catch {
    fail("couldn't write \(arguments[1]): \(error)")
}
print("builds_replaces: \(marked) of \(builds.count) builds say what they replace")
