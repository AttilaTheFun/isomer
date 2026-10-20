// Bundle, as Isomer's Foundation has it: a directory of resources, found on
// the file system. Apple's Bundle is an Objective-C class (and
// swift-foundation keeps only a package-internal stub of it); this one is
// Swift, with the part of Apple's API that reads resources and the main
// bundle's identity. There is no Info.plist reading: the info dictionary is
// what the host says of the app (its identifier, name and version, the
// `ISOMER_BUNDLE_*` environment), no localization tables
// (`localizedString` returns the value or the key) and no class-to-image
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

    open var localizations: [String] { [] }

    open var preferredLocalizations: [String] { ["en"] }

    open var developmentLocalization: String? { "en" }

    open class func preferredLocalizations(from localizationsArray: [String]) -> [String] {
        localizationsArray.first.map { [$0] } ?? ["en"]
    }

    open class func preferredLocalizations(
        from localizationsArray: [String], forPreferences preferencesArray: [String]?
    ) -> [String] {
        preferredLocalizations(from: localizationsArray)
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

    /// The value, or the key when there is no value: Isomer's Foundation
    /// reads no strings tables.
    open func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
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
