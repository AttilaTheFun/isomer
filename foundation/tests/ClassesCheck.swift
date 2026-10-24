import Foundation

// Foundation's classes Isomer writes itself: JSONSerialization,
// ISO8601DateFormatter, FileWrapper, and UserDefaults' argument domain.

extension FoundationCheck {
    static func checkClasses() throws {
        // JSONSerialization: what it reads, as Apple's gives it.
        let text = #"{"a":[1,2.5,true,null,"xé"],"b":{"c":"d/e"},"n":-3}"#
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let list = object?["a"] as? [Any] ?? []
        check("json read count", "\(list.count)", "5")
        check("json read int", "\(list.first as? Int ?? 0)", "1")
        check("json read double", "\(list.count > 1 ? list[1] as? Double ?? 0 : 0)", "2.5")
        check("json read bool", "\(list.count > 2 ? list[2] as? Bool ?? false : false)", "true")
        check("json read null", "\(list.count > 3 && list[3] is NSNull)", "true")
        check("json read string", list.count > 4 ? list[4] as? String ?? "" : "", "xé")
        check("json read nested", (object?["b"] as? [String: Any])?["c"] as? String ?? "", "d/e")
        check("json read negative", "\(object?["n"] as? Int ?? 0)", "-3")
        check("json read int as double", "\(object?["n"] as? Double ?? 0)", "-3.0")
        // Casts from NSNumber are exact, as Apple's bridging is.
        let half: Any = NSNumber(value: 2.5), one: Any = NSNumber(value: 1)
        check("nsnumber inexact int", "\(half as? Int as Any)", "nil")
        check("nsnumber bool from 1", "\(one as? Bool ?? false)", "true")
        check("nsnumber int8 out of range", "\((NSNumber(value: 300) as Any) as? Int8 as Any)", "nil")
        check("int to nsnumber", "\(((7 as Any) as? NSNumber)?.intValue ?? 0)", "7")
        let bad = (try? JSONSerialization.jsonObject(with: Data("{\"a\":".utf8))) == nil
        check("json read malformed throws", "\(bad)", "true")
        let pair = try JSONSerialization.jsonObject(with: Data(#"["\ud83d\ude00"]"#.utf8)) as? [Any]
        check("json read surrogate pair", pair?.first as? String ?? "", "😀")
        let unpaired = (try? JSONSerialization.jsonObject(with: Data(#"["\ud83d\u0041"]"#.utf8))) == nil
        check("json read unpaired surrogate throws", "\(unpaired)", "true")

        // What it writes: slashes escaped, keys sorted when asked.
        let written = try JSONSerialization.data(withJSONObject: ["b": ["c": "d/e"], "a": [1, 2.5, true, NSNull()]] as [String: Any],
                                                 options: [.sortedKeys])
        check("json write", String(decoding: written, as: UTF8.self), #"{"a":[1,2.5,true,null],"b":{"c":"d\/e"}}"#)
        let pretty = try JSONSerialization.data(withJSONObject: ["k": [1]], options: [.prettyPrinted, .withoutEscapingSlashes])
        check("json write pretty", String(decoding: pretty, as: UTF8.self), "{\n  \"k\" : [\n    1\n  ]\n}")
        let nickname: String? = nil
        let withNil = try JSONSerialization.data(withJSONObject: ["name": nickname as Any])
        check("json write nil", String(decoding: withNil, as: UTF8.self), #"{"name":null}"#)
        check("json valid object", "\(JSONSerialization.isValidJSONObject(["a": 1]))", "true")
        check("json invalid object", "\(JSONSerialization.isValidJSONObject(Date()))", "false")

        // ISO8601DateFormatter: internet date-time by default, both ways.
        let formatter = ISO8601DateFormatter()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        check("iso8601 string", formatter.string(from: date), "2023-11-14T22:13:20Z")
        check("iso8601 date", "\(formatter.date(from: "2023-11-14T22:13:20Z")?.timeIntervalSince1970 ?? 0)", "1700000000.0")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        check("iso8601 fractional", formatter.string(from: date.addingTimeInterval(0.25)), "2023-11-14T22:13:20.250Z")
        formatter.formatOptions = [.withFullDate]
        check("iso8601 full date", formatter.string(from: date), "2023-11-14")

        // FileWrapper: a directory of files, written and read back.
        let folder = FileWrapper(directoryWithFileWrappers: [:])
        folder.addRegularFile(withContents: Data("one".utf8), preferredFilename: "a.txt")
        let second = folder.addRegularFile(withContents: Data("two".utf8), preferredFilename: "a.txt")
        check("filewrapper unique name", second, "2 a.txt")
        let place = URL(fileURLWithPath: "/tmp/filewrapper-check")
        try? FileManager.default.removeItem(at: place)
        try folder.write(to: place, options: [], originalContentsURL: nil)
        let read = try FileWrapper(url: place)
        check("filewrapper read directory", "\(read.isDirectory) \(read.fileWrappers?.keys.sorted() ?? [])", #"true ["2 a.txt", "a.txt"]"#)
        check("filewrapper read file", String(decoding: read.fileWrappers?["a.txt"]?.regularFileContents ?? Data(), as: UTF8.self), "one")

        // UserDefaults' argument domain: `-key value` ahead of what is stored.
        UserDefaults.standard.set("stored", forKey: "check.argument")
        check("defaults argument", UserDefaults.standard.string(forKey: "check.argument") ?? "", "given")
        check("defaults argument bool", "\(UserDefaults.standard.bool(forKey: "check.flag"))", "true")
    }
}
