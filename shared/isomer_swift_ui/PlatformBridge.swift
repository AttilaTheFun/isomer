// What the Isomer module's `Bridge` asks of the platform (shared/isomer/
// Bridge.swift): its host installs its own when it starts, so the Isomer
// module is the same source on every platform.

package protocol PlatformBridge {
    var platformName: String { get }
    var rendererName: String { get }
    func log(_ message: String)
    func epochMilliseconds() -> Int64
    func openURL(_ url: String)
}

package enum PlatformBridges {
    /// The running host's, from its start; nil before it (and where nothing
    /// hosts the app), when `Bridge` answers for itself.
    package nonisolated(unsafe) static var current: (any PlatformBridge)?
}
