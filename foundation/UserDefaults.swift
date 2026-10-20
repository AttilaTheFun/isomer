// UserDefaults: a key-value store of property-list values (strings,
// numbers, booleans, data, dates, URLs, and arrays and dictionaries of
// them), as Apple's Foundation has it. Each suite is one dictionary, kept in
// memory and written whole on each change: to a file in the app's
// Library/Preferences, as Apple's (the app's home persists on every
// platform: IndexedDB under the web's, the app's files on Android), or to a
// store a host installs in IsomerFoundation's `IsomerUserDefaults` instead.
// Where neither can be written, values last as long as the program.
// `@AppStorage` reads and writes the standard suite.

import FoundationEssentials
internal import IsomerFoundation

open class UserDefaults: @unchecked Sendable {
    private let suite: String
    private var values: [String: Any]?
    private var registered: [String: Any] = [:]
    private let lock = NSLock()

    nonisolated(unsafe) private static var shared: UserDefaults?

    open class var standard: UserDefaults {
        if let shared { return shared }
        let defaults = UserDefaults(suite: "standard")
        shared = defaults
        return defaults
    }

    public convenience init() {
        self.init(suite: "standard")
    }

    public init?(suiteName suitename: String?) {
        suite = suitename ?? "standard"
    }

    private init(suite: String) {
        self.suite = suite
    }

    open class func resetStandardUserDefaults() {}

    // MARK: Reading

    open func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return loaded()[defaultName] ?? registered[defaultName]
    }

    open func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let value as String: return value
        case let value as Int: return String(value)
        case let value as Double: return String(value)
        case let value as Bool: return value ? "1" : "0"
        default: return nil
        }
    }

    open func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    open func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    open func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    open func stringArray(forKey defaultName: String) -> [String]? {
        (object(forKey: defaultName) as? [Any])?.compactMap { $0 as? String }
    }

    open func integer(forKey defaultName: String) -> Int {
        switch object(forKey: defaultName) {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as Bool: return value ? 1 : 0
        case let value as String: return Int(value) ?? Double(value).map { Int($0) } ?? 0
        default: return 0
        }
    }

    open func float(forKey defaultName: String) -> Float { Float(double(forKey: defaultName)) }

    open func double(forKey defaultName: String) -> Double {
        switch object(forKey: defaultName) {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as Bool: return value ? 1 : 0
        case let value as String: return Double(value) ?? 0
        default: return 0
        }
    }

    open func bool(forKey defaultName: String) -> Bool {
        switch object(forKey: defaultName) {
        case let value as Bool: return value
        case let value as Int: return value != 0
        case let value as Double: return value != 0
        case let value as String: return ["1", "true", "yes", "YES", "TRUE"].contains(value)
        default: return false
        }
    }

    open func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let value as URL: return value
        case let value as String: return URL(string: value)
        default: return nil
        }
    }

    open func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return registered.merging(loaded()) { $1 }
    }

    // MARK: Writing

    open func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        var current = loaded()
        if let value, let plist = Self.propertyList(value) {
            current[defaultName] = plist
        } else {
            current[defaultName] = nil
        }
        values = current
        lock.unlock()
        save(current)
    }

    open func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    open func set(_ value: Float, forKey defaultName: String) { set(Double(value) as Any?, forKey: defaultName) }
    open func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    open func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    open func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }

    open func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }

    open func register(defaults registrationDictionary: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in registrationDictionary {
            if let plist = Self.propertyList(value) { registered[key] = plist }
        }
    }

    /// Writes are immediate; there is nothing left to write.
    @discardableResult
    open func synchronize() -> Bool { true }

    // MARK: Storage

    private var storeKey: String { "UserDefaults." + suite }

    /// The suite's file: `Library/Preferences/<name>.defaults` in the app's
    /// home, the standard suite under the app's bundle identifier (Apple's
    /// are property lists; these are this file's text form).
    private var fileURL: URL {
        let name = suite == "standard" ? (Bundle.main.bundleIdentifier ?? "standard") : suite
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(name + ".defaults", isDirectory: false)
    }

    /// The suite's values, read the first time (the lock is held).
    private func loaded() -> [String: Any] {
        if let values { return values }
        var read: [String: Any] = [:]
        let text = IsomerUserDefaults.store.map { $0.read(storeKey) }
            ?? (try? Data(contentsOf: fileURL)).map { String(decoding: $0, as: UTF8.self) }
        if let text {
            var reader = _PlistReader(text)
            read = (reader.value() as? [String: Any]) ?? [:]
        }
        values = read
        return read
    }

    private func save(_ current: [String: Any]) {
        var text = ""
        _PlistWriter.write(current, into: &text)
        if let store = IsomerUserDefaults.store {
            store.write(storeKey, text)
        } else {
            let file = fileURL
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Not `.atomic`: WASI has no temporary files to write through.
            try? Data(text.utf8).write(to: file)
        }
    }

    /// A value as a property list (its arrays' and dictionaries' contents
    /// too); nil when it is not one.
    private static func propertyList(_ value: Any) -> Any? {
        switch value {
        case is String, is Int, is Double, is Bool, is Data, is Date, is URL: return value
        case let value as Float: return Double(value)
        case let value as Int64: return Int(value)
        case let value as Int32: return Int(value)
        case let value as Substring: return String(value)
        case let value as [Any]:
            let items = value.compactMap(propertyList)
            return items.count == value.count ? items : nil
        case let value as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in value {
                guard let plist = propertyList(item) else { return nil }
                out[key] = plist
            }
            return out
        default: return nil
        }
    }
}

/// The store's text form of a property list: a tag, then the value
/// (`s<utf8 length>:<text>`, `i<int>;`, `f<double>;`, `b0;`/`b1;`,
/// `d<base64>;`, `t<seconds since 2001>;`, `u<length>:<url>`,
/// `a<count>;` and its items, `m<count>;` and its key-value pairs).
enum _PlistWriter {
    static func write(_ value: Any, into out: inout String) {
        switch value {
        case let value as String: out += "s\(value.utf8.count):" + value
        case let value as Bool: out += value ? "b1;" : "b0;"
        case let value as Int: out += "i\(value);"
        case let value as Double: out += "f\(value);"
        case let value as Data: out += "d" + value.base64EncodedString() + ";"
        case let value as Date: out += "t\(value.timeIntervalSinceReferenceDate);"
        case let value as URL:
            let text = value.absoluteString
            out += "u\(text.utf8.count):" + text
        case let value as [Any]:
            out += "a\(value.count);"
            for item in value { write(item, into: &out) }
        case let value as [String: Any]:
            out += "m\(value.count);"
            for (key, item) in value.sorted(by: { $0.key < $1.key }) {
                write(key, into: &out)
                write(item, into: &out)
            }
        default: out += "s0:"
        }
    }
}

struct _PlistReader {
    private let bytes: [UInt8]
    private var at = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    private mutating func until(_ end: UInt8) -> String? {
        guard let stop = bytes[at...].firstIndex(of: end) else { return nil }
        let text = String(decoding: bytes[at..<stop], as: UTF8.self)
        at = stop + 1
        return text
    }

    private mutating func counted() -> String? {
        guard let length = until(UInt8(ascii: ":")).flatMap({ Int($0) }), at + length <= bytes.count else { return nil }
        let text = String(decoding: bytes[at..<at + length], as: UTF8.self)
        at += length
        return text
    }

    mutating func value() -> Any? {
        guard at < bytes.count else { return nil }
        let tag = bytes[at]
        at += 1
        switch tag {
        case UInt8(ascii: "s"): return counted()
        case UInt8(ascii: "u"): return counted().flatMap { URL(string: $0) }
        case UInt8(ascii: "b"): return until(UInt8(ascii: ";")).map { $0 == "1" }
        case UInt8(ascii: "i"): return until(UInt8(ascii: ";")).flatMap { Int($0) }
        case UInt8(ascii: "f"): return until(UInt8(ascii: ";")).flatMap { Double($0) }
        case UInt8(ascii: "d"): return until(UInt8(ascii: ";")).flatMap { Data(base64Encoded: $0) }
        case UInt8(ascii: "t"): return until(UInt8(ascii: ";")).flatMap { Double($0) }.map { Date(timeIntervalSinceReferenceDate: $0) }
        case UInt8(ascii: "a"):
            guard let count = until(UInt8(ascii: ";")).flatMap({ Int($0) }) else { return nil }
            var items: [Any] = []
            for _ in 0..<count {
                guard let item = value() else { return nil }
                items.append(item)
            }
            return items
        case UInt8(ascii: "m"):
            guard let count = until(UInt8(ascii: ";")).flatMap({ Int($0) }) else { return nil }
            var items: [String: Any] = [:]
            for _ in 0..<count {
                guard let key = value() as? String, let item = value() else { return nil }
                items[key] = item
            }
            return items
        default: return nil
        }
    }
}
