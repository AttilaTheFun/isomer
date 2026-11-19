// The Maven artifacts' cache (tools/ci/ci_bazel.sh maven): the artifacts a
// job's builds downloaded, copied out of Bazel's repository cache into a
// folder of the same layout (content_addressable/sha256/<hex>/), which
// .github/actions/bazel_cache_save keeps in GitHub's cache by the Maven
// lock files, and ci_bazel.sh setup copies back into the repository cache.
//
//   swiftc -O -o maven_cache tools/ci/maven_cache.swift
//   maven_cache <repository cache> <out> <folder>…
//
// An artifact is one a rules_jvm_external lock file pins: every SHA-256 in
// a lock file (`*install.json` with `"artifacts"` in it) found in a
// <folder> (the checkout; an output base's external/, the lock files of the
// modules the builds fetched, rules_jvm_external's own tools' among them),
// at most two folders down from it (`external/<module>/<lock file>`). One
// that the repository cache doesn't hold (not fetched) is left out.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("maven_cache: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 3 else { fail("usage: maven_cache <repository cache> <out> <folder>…") }
let repository = URL(fileURLWithPath: arguments[arguments.startIndex])
let out = URL(fileURLWithPath: arguments[arguments.startIndex + 1])
let folders = arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let files = FileManager.default

/// The lock files in a folder, at most `depth` folders down, symbolic links
/// followed (an output base's external/<module> may be one, into Bazel's
/// repository contents cache); Bazel's own trees (bazel-*) and .git skipped.
func lockFiles(in folder: URL, depth: Int) -> [URL] {
    guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return [] }
    var found: [URL] = []
    for name in names.sorted() where !name.hasPrefix("bazel-") && name != ".git" {
        let path = folder.appendingPathComponent(name)
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: path.path, isDirectory: &isFolder) else { continue }
        if isFolder.boolValue {
            if depth > 0 { found += lockFiles(in: path, depth: depth - 1) }
        } else if name.hasSuffix("install.json") {
            found.append(path)
        }
    }
    return found
}

/// Every quoted 64-digit hexadecimal string in a lock file: its artifacts'
/// SHA-256s (its other values are names, versions, URLs and short hashes).
func checksums(in lockFile: URL) -> Set<String> {
    guard let text = try? String(contentsOf: lockFile, encoding: .utf8), text.contains("\"artifacts\"") else { return [] }
    var found: Set<String> = []
    for part in text.split(separator: "\"") where part.count == 64 {
        if part.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { found.insert(String(part)) }
    }
    return found
}

var wanted: Set<String> = []
var lockCount = 0
for folder in folders {
    for lockFile in lockFiles(in: folder, depth: 2) {
        let found = checksums(in: lockFile)
        if !found.isEmpty {
            lockCount += 1
            wanted.formUnion(found)
        }
    }
}

// The entry whole: its file and its id-<hash> markers, the canonical ids
// it was downloaded under (rules_jvm_external's http_file names one, and
// Bazel takes an entry only under an id it has).
var copied = 0
var bytes: Int64 = 0
for checksum in wanted.sorted() {
    let relative = "content_addressable/sha256/\(checksum)"
    let source = repository.appendingPathComponent(relative)
    guard files.fileExists(atPath: source.appendingPathComponent("file").path) else { continue }
    let destination = out.appendingPathComponent(relative)
    do {
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: destination)
        try files.copyItem(at: source, to: destination)
    } catch {
        fail("\(source.path): \(error)")
    }
    copied += 1
    bytes += ((try? files.attributesOfItem(atPath: destination.appendingPathComponent("file").path))?[.size] as? NSNumber)?.int64Value ?? 0
}
print("maven_cache: \(copied) of the \(wanted.count) artifacts \(lockCount) lock files pin, \(bytes / 1_048_576) MB, in \(out.path)")
