// Where Isomer's `UserDefaults` keeps its suites: a store the host installs
// (the browser's localStorage, a file in the app's files directory on
// Android). Each suite is one text value under its own key,
// "UserDefaults.<suite name>", written whole on every change. Without a
// store, values last as long as the program.

import Synchronization

/// The store `UserDefaults` reads its suites from and writes them to.
public enum IsomerUserDefaults {
    /// Installed by the host; read by `UserDefaults` the first time it
    /// needs each suite and on every write.
    public static var store: UserDefaultsStore? {
        get { installed.withLock { $0 } }
        set { installed.withLock { $0 = newValue } }
    }
}

private let installed = Mutex<UserDefaultsStore?>(nil)

/// A store of text values by key: what `UserDefaults` needs of the
/// platform's.
public struct UserDefaultsStore: Sendable {
    /// The value under `key`; nil when there is none.
    public var read: @Sendable (_ key: String) -> String?

    /// Keeps `value` under `key`, replacing what was there.
    public var write: @Sendable (_ key: String, _ value: String) -> Void

    public init(
        read: @escaping @Sendable (_ key: String) -> String?,
        write: @escaping @Sendable (_ key: String, _ value: String) -> Void
    ) {
        self.read = read
        self.write = write
    }
}
