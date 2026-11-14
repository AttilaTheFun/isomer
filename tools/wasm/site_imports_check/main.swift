// Checks that a web site's directory holds every module its pages import
// (defs.bzl's site_imports_test runs it).
//
// A page whose module graph has a missing file does not run at all: the browser
// drops the whole graph and the page stays blank, with the error only in the
// console. (The Playground's "Run on the web" page shipped blank twice that way,
// when the renderer gained an import its site's file list did not name.)
//
//   site_imports_check <site directory> <entry> [<entry> ...] [--optional <path> ...]
//
// Walks from each entry (an .html page or a .js module, relative to the site)
// through the relative imports: `import … from "./x.js"`, `export … from`,
// `import "./x.js"`, `import("./x.js")`, `new URL("./x.js", import.meta.url)`
// and an html page's `<script src>`. Anything not found fails the test, unless
// it is imported dynamically and named by --optional (a module a page loads
// only in a configuration this site is not). It was site_imports_test.py
// until 0.54: the same expressions, Python's `re` read by ICU's.
import Foundation

func pattern(_ text: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // The expressions are this file's own: a bad one is a bug here.
    try! NSRegularExpression(pattern: text, options: options)
}

let staticImport = pattern(
    #"(?:^|[;\s}])(?:import|export)\s*(?:[^'"()]*?\sfrom\s*)?['"](\.{1,2}/[^'"]+)['"]"#, [.anchorsMatchLines])
let dynamicImport = pattern(#"(?:import\s*\(\s*|new\s+URL\s*\(\s*)['"](\.{1,2}/[^'"]+)['"]"#)
let scriptSource = pattern(#"<script\b[^>]*\bsrc\s*=\s*['"]([^'"]+)['"]"#, [.caseInsensitive])
let inlineModule = pattern(
    #"<script\b[^>]*type\s*=\s*['"]module['"][^>]*>(.*?)</script>"#, [.caseInsensitive, .dotMatchesLineSeparators])
let comments = pattern(#"/\*.*?\*/|(?<![:'"\\])//[^\n]*"#, [.dotMatchesLineSeparators])
let scheme = pattern(#"^[a-z]+:|^//"#)

/// The first group of each match (Python's `findall` of a one-group pattern).
func findAll(_ expression: NSRegularExpression, _ text: String) -> [String] {
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).map { match in
        Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
    }
}

/// (specifier, dynamic) pairs a file refers to.
func references(_ path: String, _ contents: String) -> [(String, Bool)] {
    var text = contents
    var found: [(String, Bool)] = []
    if path.hasSuffix(".html") || path.hasSuffix(".htm") {
        for source in findAll(scriptSource, text) {
            let range = NSRange(source.startIndex..., in: source)
            if scheme.firstMatch(in: source, options: [.anchored], range: range) == nil {
                found.append((source, false))
            }
        }
        text = findAll(inlineModule, text).joined(separator: "\n")
    } else if !(path.hasSuffix(".js") || path.hasSuffix(".mjs")) {
        return found
    }
    text = comments.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    found += findAll(staticImport, text).map { ($0, false) }
    found += findAll(dynamicImport, text).map { ($0, true) }
    return found
}

/// Python's os.path.normpath of a relative or absolute POSIX path.
func normalized(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
    var parts: [Substring] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        if part == ".." {
            if let last = parts.last, last != ".." {
                parts.removeLast()
            } else if !absolute {
                parts.append(part)
            }
            continue
        }
        parts.append(part)
    }
    let joined = parts.joined(separator: "/")
    if absolute {
        // POSIX keeps exactly two leading slashes, as Python does.
        let leading = path.hasPrefix("//") && !path.hasPrefix("///") ? "//" : "/"
        return leading + joined
    }
    return joined.isEmpty ? "." : joined
}

/// Python's os.path.join of two parts (an absolute second part replaces the first).
func joined(_ base: String, _ part: String) -> String {
    if part.hasPrefix("/") || base.isEmpty { return part }
    return base.hasSuffix("/") ? base + part : base + "/" + part
}

/// Python's os.path.dirname: up to the last slash, without trailing slashes
/// unless it is all slashes.
func directory(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    let head = String(path[...slash])
    if head.allSatisfy({ $0 == "/" }) { return head }
    return String(head.reversed().drop(while: { $0 == "/" }).reversed())
}

func isFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
}

var arguments = Array(CommandLine.arguments)
var optional = Set<String>()
if let at = arguments.firstIndex(of: "--optional") {
    optional = Set(arguments[(at + 1)...])
    arguments = Array(arguments[..<at])
}
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: site_imports_check <site directory> <entry>... [--optional <path>...]\n".utf8))
    exit(2)
}
let site = arguments[1]
var queue = Array(arguments.dropFirst(2))
var seen = Set<String>()
struct Missing: Hashable {
    let target: String
    let importer: String
    let dynamic: Bool
}
var missing = Set<Missing>()
while let relative = queue.popLast() {
    if seen.contains(relative) { continue }
    seen.insert(relative)
    let path = joined(site, relative)
    guard isFile(path), let data = FileManager.default.contents(atPath: path) else {
        missing.insert(Missing(target: relative, importer: "an entry of the test", dynamic: false))
        continue
    }
    // Undecodable bytes read as U+FFFD, as Python's errors="replace".
    let text = String(decoding: data, as: UTF8.self)
    for (specifier, dynamic) in references(relative, text) {
        let bare = String(specifier.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let target = normalized(joined(directory(relative), bare))
        if target.hasPrefix("..") { continue }  // outside the site: another origin path, not ours to check
        if isFile(joined(site, target)) {
            queue.append(target)
        } else if !(dynamic && optional.contains(target)) {
            missing.insert(Missing(target: target, importer: relative, dynamic: dynamic))
        }
    }
}
if !missing.isEmpty {
    print("The site is missing files its pages import (the page would be blank):")
    // In Python's tuple order: target, importer, then static before dynamic.
    let ordered = missing.sorted {
        if $0.target != $1.target { return $0.target.utf8.lexicographicallyPrecedes($1.target.utf8) }
        if $0.importer != $1.importer { return $0.importer.utf8.lexicographicallyPrecedes($1.importer.utf8) }
        return !$0.dynamic && $1.dynamic
    }
    for item in ordered {
        print("  \(item.target), imported\(item.dynamic ? " dynamically" : "") by \(item.importer)")
    }
    print("Add them to the site's file list.")
    exit(1)
}
print("\(seen.count) files checked, every import is in the site")
