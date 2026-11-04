// URLResourceValues and URL.setResourceValues(_:), for what an app sets on
// its files: a new name, and the backup and hidden flags. A name renames the
// item in its directory and moves the URL with it, as Apple's does. The
// flags are accepted and not acted on: Android backs up an app's files by
// its manifest's rules, not per file, and the web (IndexedDB) and WASI
// keep no such flag. Reading values back (`resourceValues(forKeys:)`) needs
// URLResourceKey, which swift-foundation declares off Apple's platforms with
// no members: not here yet.

import FoundationEssentials

public struct URLResourceValues {
    public init() {}

    /// The item's name in its directory: setting it renames the item.
    public var name: String?

    /// Accepted, not acted on (see above).
    public var isHidden: Bool?

    /// Accepted, not acted on (see above).
    public var isExcludedFromBackup: Bool?
}

extension URL {
    /// Applies `values` to the file this URL names: a `name` renames it
    /// (and this URL becomes the new one); the flags are accepted.
    public mutating func setResourceValues(_ values: URLResourceValues) throws {
        // "NSURL": NSURLErrorKey, internal to swift-foundation.
        guard isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme, userInfo: ["NSURL": self]) }
        guard let name = values.name, name != lastPathComponent else { return }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: ["NSURL": self])
        }
        let renamed = deletingLastPathComponent().appendingPathComponent(name, isDirectory: hasDirectoryPath)
        try FileManager.default.moveItem(at: self, to: renamed)
        self = renamed
    }
}
