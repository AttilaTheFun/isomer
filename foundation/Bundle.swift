// Bundle, as Isomer's Foundation has it: a directory of resources, found on
// the file system. Apple's Bundle is an Objective-C class (and
// swift-foundation keeps only a package-internal stub of it); this one is
// Swift, with the part of Apple's API that reads resources and the main
// bundle's identity. There is no Info.plist reading: the info dictionary is
// what the host says of the app (its identifier, name and version, the
// `ISOMER_BUNDLE_*` environment), and no class-to-image
// lookup (`Bundle(for:)` is the main bundle) — docs/parity/Foundation.md.
//
// The main bundle is the directory in `ISOMER_BUNDLE_PATH` when the host sets
// it, else the executable's directory, else "/".

import FoundationEssentials

open class Bundle: Hashable, CustomStringConvertible, @unchecked Sendable {
    /// The bundle's directory.
    public let bundleURL: URL

    public init?(path: String) {
        guard FileManager.default.itemType(atPath: path) == .typeDirectory else {
            return nil
        }
        bundleURL = URL(fileURLWithPath: path, isDirectory: true)
    }

    public convenience init?(url: URL) {
        self.init(path: url.path)
    }

    /// The bundle a class was loaded from: in Isomer always the main bundle.
    public convenience init(for aClass: AnyClass) {
        self.init(directory: Bundle.main.bundleURL)
    }

    public convenience init?(identifier: String) {
        guard identifier == Bundle.main.bundleIdentifier else { return nil }
        self.init(directory: Bundle.main.bundleURL)
    }

    init(directory: URL) {
        bundleURL = directory
    }

    nonisolated(unsafe) private static var mainBundle: Bundle?

    /// The application's bundle.
    open class var main: Bundle {
        if let bundle = mainBundle { return bundle }
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        if let path = environment["ISOMER_BUNDLE_PATH"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else if let executable = CommandLine.arguments.first, executable.contains("/") {
            directory = URL(fileURLWithPath: executable).deletingLastPathComponent()
        } else {
            directory = URL(fileURLWithPath: "/", isDirectory: true)
        }
        let bundle = Bundle(directory: directory)
        mainBundle = bundle
        return bundle
    }

    open class var allBundles: [Bundle] { [main] }

    open class var allFrameworks: [Bundle] { [] }

    open var bundlePath: String { bundleURL.path }

    open var resourceURL: URL? { bundleURL }

    open var resourcePath: String? { resourceURL?.path }

    open var executableURL: URL? {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
    }

    open var executablePath: String? { executableURL?.path }

    /// The host's identifier for the app (`ISOMER_BUNDLE_IDENTIFIER`), if set.
    open var bundleIdentifier: String? {
        ProcessInfo.processInfo.environment["ISOMER_BUNDLE_IDENTIFIER"]
    }

    /// The app as its host says it is, under Info.plist's keys: its
    /// identifier, name and version (`ISOMER_BUNDLE_IDENTIFIER`,
    /// `ISOMER_BUNDLE_NAME`, `ISOMER_BUNDLE_SHORT_VERSION`,
    /// `ISOMER_BUNDLE_VERSION`; Android's package, label, versionName and
    /// versionCode).
    open var infoDictionary: [String: Any]? {
        let environment = ProcessInfo.processInfo.environment
        var info: [String: Any] = [:]
        for (key, variable) in [("CFBundleIdentifier", "ISOMER_BUNDLE_IDENTIFIER"), ("CFBundleName", "ISOMER_BUNDLE_NAME"),
                                ("CFBundleDisplayName", "ISOMER_BUNDLE_NAME"),
                                ("CFBundleShortVersionString", "ISOMER_BUNDLE_SHORT_VERSION"),
                                ("CFBundleVersion", "ISOMER_BUNDLE_VERSION")] {
            if let value = environment[variable], !value.isEmpty { info[key] = value }
        }
        return info
    }

    open var localizedInfoDictionary: [String: Any]? { [:] }

    open func object(forInfoDictionaryKey key: String) -> Any? {
        infoDictionary?[key]
    }

    /// The bundle's `<localization>.lproj` folders, `Base` aside.
    open var localizations: [String] {
        guard let resources = resourceURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else { return [] }
        return names.filter { $0.hasSuffix(".lproj") && $0 != "Base.lproj" }.map { String($0.dropLast(6)) }.sorted()
    }

    open var preferredLocalizations: [String] {
        Bundle.preferredLocalizations(from: localizations)
    }

    /// `ISOMER_BUNDLE_DEVELOPMENT_REGION` (Info.plist's
    /// CFBundleDevelopmentRegion), else English.
    open var developmentLocalization: String? {
        let region = ProcessInfo.processInfo.environment["ISOMER_BUNDLE_DEVELOPMENT_REGION"] ?? ""
        return region.isEmpty ? "en" : region
    }

    open class func preferredLocalizations(from localizationsArray: [String]) -> [String] {
        preferredLocalizations(from: localizationsArray, forPreferences: nil)
    }

    /// Of `localizationsArray`, the best match for the first preferred
    /// language that has one (`ISOMER_PREFERRED_LANGUAGES`, which a host sets
    /// from the device's, else `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` or `LANG`),
    /// matched by the whole tag, then without its region, then by language:
    /// "fr-CA" takes fr-CA.lproj, else fr.lproj. Else the development
    /// localization, else the first.
    open class func preferredLocalizations(
        from localizationsArray: [String], forPreferences preferencesArray: [String]?
    ) -> [String] {
        func normal(_ tag: String) -> String { tag.replacingOccurrences(of: "_", with: "-").lowercased() }
        let available = localizationsArray.map { ($0, normal($0)) }
        for preference in preferencesArray ?? preferredLanguages {
            var parts = normal(preference).split(separator: "-").map(String.init)
            while !parts.isEmpty {
                let tag = parts.joined(separator: "-")
                if let match = available.first(where: { $0.1 == tag }) { return [match.0] }
                parts.removeLast()
            }
        }
        let development = normal(Bundle.main.developmentLocalization ?? "en")
        if let match = available.first(where: { $0.1 == development }) { return [match.0] }
        return localizationsArray.first.map { [$0] } ?? []
    }

    /// The languages the app prefers, most preferred first, as BCP 47 tags.
    static var preferredLanguages: [String] {
        let environment = ProcessInfo.processInfo.environment
        if let list = environment["ISOMER_PREFERRED_LANGUAGES"], !list.isEmpty {
            return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let list = environment["LANGUAGE"], !list.isEmpty {
            return list.split(separator: ":").map(String.init)
        }
        for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            // "fr_CA.UTF-8@euro" is fr-CA; C and POSIX name no language.
            guard let value = environment[name], !value.isEmpty, value != "C", value != "POSIX" else { continue }
            let tag = value.split(separator: ".").first.map(String.init) ?? value
            return [String(tag.split(separator: "@").first ?? Substring(tag)).replacingOccurrences(of: "_", with: "-")]
        }
        return []
    }

    // MARK: Strings tables

    private var tables: [String: [String: String]] = [:]
    private let tablesLock = NSLock()

    /// A `.strings` table in a localization's folder (nil: the bundle's
    /// root), read once: Xcode's text format, UTF-8 or UTF-16, or a property
    /// list (XML or binary) of strings.
    func table(_ name: String, localization: String?) -> [String: String] {
        let path = (localization.map { "\($0).lproj/" } ?? "") + name + ".strings"
        tablesLock.lock()
        defer { tablesLock.unlock() }
        if let table = tables[path] { return table }
        var table: [String: String] = [:]
        if let resources = resourceURL, let data = FileManager.default.contents(atPath: resources.appendingPathComponent(path).path) {
            table = StringsTable.parse(data) ?? [:]
        }
        tables[path] = table
        return table
    }

    // MARK: Resources

    open func url(forResource name: String?, withExtension ext: String?) -> URL? {
        url(forResource: name, withExtension: ext, subdirectory: nil)
    }

    open func url(forResource name: String?, withExtension ext: String?, subdirectory subpath: String?) -> URL? {
        guard let resources = resourceURL else { return nil }
        let directory = subpath.map { resources.appendingPathComponent($0, isDirectory: true) } ?? resources
        if let name {
            var file = name
            if let ext, !ext.isEmpty { file += "." + ext }
            let candidate = directory.appendingPathComponent(file)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        return urls(forResourcesWithExtension: ext, subdirectory: subpath)?.first
    }

    open func url(
        forResource name: String?, withExtension ext: String?, subdirectory subpath: String?,
        localization localizationName: String?
    ) -> URL? {
        url(forResource: name, withExtension: ext, subdirectory: subpath)
    }

    open func urls(forResourcesWithExtension ext: String?, subdirectory subpath: String?) -> [URL]? {
        guard let resources = resourceURL else { return nil }
        let directory = subpath.map { resources.appendingPathComponent($0, isDirectory: true) } ?? resources
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        return names.sorted()
            .filter { ext == nil || ext == "" || $0.hasSuffix("." + ext!) }
            .map { directory.appendingPathComponent($0) }
    }

    open func path(forResource name: String?, ofType ext: String?) -> String? {
        url(forResource: name, withExtension: ext)?.path
    }

    open func path(forResource name: String?, ofType ext: String?, inDirectory subpath: String?) -> String? {
        url(forResource: name, withExtension: ext, subdirectory: subpath)?.path
    }

    open func paths(forResourcesOfType ext: String?, inDirectory subpath: String?) -> [String] {
        urls(forResourcesWithExtension: ext, subdirectory: subpath)?.map(\.path) ?? []
    }

    /// The key's string in `<table>.strings` (Localizable when nil), looked
    /// up as Apple's Bundle does: in the preferred localization's folder,
    /// then the development localization's, then Base.lproj's, then the
    /// bundle's root. Not found: `value`, or the key when that is empty.
    open func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        let name = (tableName ?? "").isEmpty ? "Localizable" : tableName!
        var folders: [String?] = preferredLocalizations
        if let development = developmentLocalization, localizations.contains(development) { folders.append(development) }
        folders += ["Base", nil]
        for folder in folders {
            if let string = table(name, localization: folder)[key] { return string }
        }
        if let value, !value.isEmpty { return value }
        return key
    }

    // MARK: Equality

    public static func == (lhs: Bundle, rhs: Bundle) -> Bool {
        lhs.bundleURL == rhs.bundleURL
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleURL)
    }

    open var description: String { "Bundle <\(bundlePath)>" }
}

/// `key` localized from `bundle`'s strings tables (`localizedString(forKey:value:table:)`).
public func NSLocalizedString(_ key: String, tableName: String? = nil, bundle: Bundle = Bundle.main, value: String = "",
                              comment: String) -> String {
    bundle.localizedString(forKey: key, value: value, table: tableName)
}

/// Reads a `.strings` file: Xcode's text format (`"key" = "value";`, an
/// unquoted key or value of letters, digits and `_.-:/$`, `/* */` and `//`
/// comments, `\n \t \r \" \\ \Uxxxx` escapes) in UTF-8 or UTF-16 (by
/// its byte order mark), or a property list of strings (XML or binary, as
/// Xcode compiles them).
enum StringsTable {
    static func parse(_ data: Data) -> [String: String]? {
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("bplist".utf8)) || bytes.starts(with: Array("<?xml".utf8)) {
            return try? PropertyListDecoder().decode([String: String].self, from: data)
        }
        let text: String?
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: Data(bytes.starts(with: [0xef, 0xbb, 0xbf]) ? bytes.dropFirst(3) : bytes[...]), encoding: .utf8)
        }
        guard let text else { return nil }
        var scalars = Array(text.unicodeScalars)[...]
        var table: [String: String] = [:]
        func skipSpace() {
            while let first = scalars.first {
                if first.properties.isWhitespace {
                    scalars = scalars.dropFirst()
                } else if first == "/", scalars.dropFirst().first == "*" {
                    scalars = scalars.dropFirst(2)
                    while !scalars.isEmpty, !(scalars.first == "*" && scalars.dropFirst().first == "/") { scalars = scalars.dropFirst() }
                    scalars = scalars.dropFirst(2)
                } else if first == "/", scalars.dropFirst().first == "/" {
                    while let next = scalars.first, next != "\n" { scalars = scalars.dropFirst() }
                } else {
                    return
                }
            }
        }
        func token() -> String? {
            skipSpace()
            guard let first = scalars.first else { return nil }
            var out = String.UnicodeScalarView()
            if first == "\"" {
                scalars = scalars.dropFirst()
                while let next = scalars.popFirst() {
                    if next == "\"" { return String(out) }
                    guard next == "\\", let escaped = scalars.popFirst() else { out.append(next); continue }
                    switch escaped {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "U", "u":
                        let hex = String(String.UnicodeScalarView(scalars.prefix(4)))
                        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                        out.append(scalar)
                        scalars = scalars.dropFirst(4)
                    default: out.append(escaped)
                    }
                }
                return nil   // unterminated
            }
            while let next = scalars.first, next.properties.isAlphabetic || next.properties.numericType != nil
                || "_.-:/$".unicodeScalars.contains(next) {
                out.append(next)
                scalars = scalars.dropFirst()
            }
            return out.isEmpty ? nil : String(out)
        }
        while true {
            skipSpace()
            if scalars.isEmpty { return table }
            guard let key = token() else { return nil }
            skipSpace()
            if scalars.first == ";" {
                scalars = scalars.dropFirst()
                table[key] = key
                continue
            }
            guard scalars.popFirst() == "=", let value = token() else { return nil }
            skipSpace()
            guard scalars.popFirst() == ";" else { return nil }
            table[key] = value
        }
    }
}
