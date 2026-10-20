// The path functions corelibs and Apple's Foundation have beside
// FileManager (swift-foundation has only FileManager's).

import FoundationEssentials

/// The temporary directory's path, ending in "/".
public func NSTemporaryDirectory() -> String {
    var path = FileManager.default.temporaryDirectory.path
    if !path.hasSuffix("/") { path += "/" }
    return path
}

/// The current user's home directory.
public func NSHomeDirectory() -> String {
    FileManager.default.homeDirectoryForCurrentUser.path
}

// URL's directories, which swift-foundation declares for Apple's framework
// only: each is the first of FileManager's search paths for it, as Apple's
// are. Off Apple those come from the environment (HOME, XDG_DATA_HOME,
// XDG_CACHE_HOME); the hosts give an app an iOS container's layout
// (wasm/libraries/swift_ui/runtime/file_system.js). The directories with
// no search path off Apple (applications, the library) are left out.
extension URL {
    private static func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask) -> URL {
        FileManager.default.urls(for: directory, in: domain).first!
    }

    /// The app's documents directory.
    public static var documentsDirectory: URL { url(for: .documentDirectory, in: .userDomainMask) }

    /// The app's support files (Library/Application Support).
    public static var applicationSupportDirectory: URL { url(for: .applicationSupportDirectory, in: .userDomainMask) }

    /// The app's discardable cache files (Library/Caches).
    public static var cachesDirectory: URL { url(for: .cachesDirectory, in: .userDomainMask) }

    public static var userDirectory: URL { url(for: .userDirectory, in: .localDomainMask) }

    public static var desktopDirectory: URL { url(for: .desktopDirectory, in: .userDomainMask) }

    public static var downloadsDirectory: URL { url(for: .downloadsDirectory, in: .userDomainMask) }

    public static var moviesDirectory: URL { url(for: .moviesDirectory, in: .userDomainMask) }

    public static var musicDirectory: URL { url(for: .musicDirectory, in: .userDomainMask) }

    public static var picturesDirectory: URL { url(for: .picturesDirectory, in: .userDomainMask) }

    public static var sharedPublicDirectory: URL { url(for: .sharedPublicDirectory, in: .userDomainMask) }

    public static var trashDirectory: URL { url(for: .trashDirectory, in: .userDomainMask) }
}
