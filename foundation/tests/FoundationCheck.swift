import Foundation
import IsomerFoundation
import Synchronization

// Isomer's Foundation, run under a WASI engine: what Essentials gives (JSON,
// Date, URL, UUID, Data), the CoreGraphics geometry it re-exports, the
// string API the fork adds (CharacterSet, searching, replacing, trimming,
// percent encoding, String(format:)), what corelibs adds, UserDefaults, and
// URLSession over transports installed as a host would (NetworkCheck.swift).
// Each line prints "ok" or what differed.

struct Probe: Codable { var name: String; var size: CGSize }

func check(_ name: String, _ actual: String, _ expected: String) {
    print(actual == expected ? "ok   \(name)" : "FAIL \(name): got \(actual.debugDescription), want \(expected.debugDescription)")
}

/// What a store keeps, as a host's would: text by key.
final class Stored: Sendable {
    private let values = Mutex<[String: String]>([:])
    func read(_ key: String) -> String? { values.withLock { $0[key] } }
    func write(_ key: String, _ value: String) { values.withLock { $0[key] = value } }
}

@main
struct FoundationCheck {
    static func main() async throws {
        try checkFoundation()
        checkErrors()
        await checkNetwork()
    }

    static func checkFoundation() throws {
        let probe = Probe(name: "isomer", size: CGSize(width: 3, height: 4))
        let back = try JSONDecoder().decode(Probe.self, from: try JSONEncoder().encode(probe))
        check("json", "\(back.name) \(back.size.width)", "isomer 3.0")
        check("url", URL(string: "https://example.com/a?b=c")!.host() ?? "", "example.com")
        check("uuid", String(UUID().uuidString.count), "36")

        check("trim", "  hello \n".trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        check("replace", "a-b-c".replacingOccurrences(of: "-", with: "+"), "a+b+c")
        check("replace case", "Hello hello".replacingOccurrences(of: "HELLO", with: "x", options: .caseInsensitive), "x x")
        check("replace regex", "a1b22c".replacingOccurrences(of: "[0-9]+", with: "<$0>", options: .regularExpression), "a<1>b<22>c")
        check("range", "\("swift foundation".range(of: "found") != nil)", "true")
        check("components set", "a,b;c".components(separatedBy: CharacterSet(charactersIn: ",;")).joined(separator: "|"), "a|b|c")
        check("components string", "a::b".components(separatedBy: "::").joined(separator: "|"), "a|b")
        check("compare", "\("abc".caseInsensitiveCompare("ABC") == .orderedSame)", "true")
        check("numeric", "\("file2".localizedStandardCompare("file10") == .orderedAscending)", "true")
        check("percent", "a b&c".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "", "a%20b&c")
        check("unpercent", "a%20b".removingPercentEncoding ?? "", "a b")
        check("padding", "ab".padding(toLength: 5, withPad: "-", startingAt: 0), "ab---")
        check("letters", "\(CharacterSet.letters.contains("é") && !CharacterSet.letters.contains("1"))", "true")
        check("format", String(format: "%d items, %.2f%%, %@, %5s|%-3d|", 3, 99.5, "ok", "ab", 7), "3 items, 99.50%, ok,    ab|7  |")
        check("format hex", String(format: "%04x %X", 255, 255), "00ff FF")
        check("format positions", String(format: "%2$@ %1$@", "a", "b"), "b a")
        check("weekday", Calendar.current.shortWeekdaySymbols.first ?? "", "Sun")
        let width: Double = back.size.width
        check("cgfloat", "\(width + 1)", "4.0")

        // What Foundation has beyond swift-foundation's (corelibs' API).
        let text = "café: ab12, cd345"
        let regex = try NSRegularExpression(pattern: "([a-z]+)(\\d+)", options: [])
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        check("regex matches", found.map { NSStringFromRange($0.range) }.joined(separator: " "), "{6, 4} {12, 5}")
        check("regex group", found.last.flatMap { Range($0.range(at: 2), in: text) }.map { String(text[$0]) } ?? "", "345")
        check("regex groups", "\(regex.numberOfCaptureGroups)", "2")
        check("regex replace", regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: "$2$1"), "café: 12ab, 345cd")
        let caseless = try NSRegularExpression(pattern: "CAFÉ", options: .caseInsensitive)
        check("regex case", "\(caseless.firstMatch(in: text, range: NSRange(location: 0, length: 10)) != nil)", "true")
        check("regex named", (try NSRegularExpression(pattern: "(?<word>[a-z]+)\\d").firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count))?.range(withName: "word")).map(NSStringFromRange) ?? "", "{6, 2}")
        check("nsrange", "\(NSMaxRange(NSMakeRange(3, 4))) \(NSIntersectionRange(NSMakeRange(0, 5), NSMakeRange(3, 5)))", "7 {3, 2}")
        let lock = NSLock()
        check("lock", lock.withLock { "locked" }, "locked")
        check("temporary directory", "\(NSTemporaryDirectory().hasSuffix("/"))", "true")
        let path = NSTemporaryDirectory() + "isomer-file-handle"
        _ = FileManager.default.createFile(atPath: path, contents: Data("hello".utf8))
        if let handle = FileHandle(forUpdatingAtPath: path) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" world".utf8))
            try handle.seek(toOffset: 0)
            check("file handle", String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self), "hello world")
            try handle.close()
        } else {
            check("file handle", "no handle", "hello world")
        }
        // Intermediate directories where no preopen reaches (a host that maps
        // no home): an error, not a recursion past "/", its own parent.
        let unreachable = (try? FileManager.default.createDirectory(
            atPath: "/nowhere/isomer/a", withIntermediateDirectories: true)) == nil
        check("directories outside the preopens", "\(unreachable)", "true")
        let nested = NSTemporaryDirectory() + "isomer-nested/a/b"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let type = (try? FileManager.default.attributesOfItem(atPath: nested))?[.type] as? FileAttributeType
        check("intermediate directories", "\(type == .typeDirectory)", "true")

        // UserDefaults, through a store installed as the SwiftUI runtime
        // installs its host's: a suite read back by another instance finds
        // what was written, and the store holds it.
        let stored = Stored()
        IsomerUserDefaults.store = UserDefaultsStore(read: { stored.read($0) }, write: { stored.write($0, $1) })
        let defaults = UserDefaults(suiteName: "check")!
        defaults.set(3, forKey: "count")
        defaults.set(true, forKey: "on")
        defaults.set("café", forKey: "name")
        defaults.set(["a", "b"], forKey: "list")
        defaults.set(["x": 1.5], forKey: "map")
        defaults.set(Data([1, 2, 3]), forKey: "bytes")
        defaults.register(defaults: ["fallback": "yes"])
        let again = UserDefaults(suiteName: "check")!
        check("defaults", "\(again.integer(forKey: "count")) \(again.bool(forKey: "on")) \(again.string(forKey: "name") ?? "") \((again.stringArray(forKey: "list") ?? []).joined(separator: ",")) \(again.dictionary(forKey: "map")?["x"] as? Double ?? 0) \(again.data(forKey: "bytes")?.count ?? 0)", "3 true café a,b 1.5 3")
        check("defaults registered", defaults.string(forKey: "fallback") ?? "", "yes")
        defaults.removeObject(forKey: "count")
        check("defaults removed", "\(UserDefaults(suiteName: "check")!.object(forKey: "count") == nil)", "true")
        check("defaults store", "\(stored.read("UserDefaults.check")?.contains("s4:name") ?? false)", "true")
    }
}
