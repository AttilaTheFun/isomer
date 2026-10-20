// The bundle-delivery seam: where a host obtains the wasm feature bundles it
// runs. swift_ffi defines the protocol only — packaged resources, download
// caches, and dev hot-reload streams are host implementations plugged in by
// the app (see isomer's AppBundleProvider for a batteries-included
// example).

import Foundation

/// A deliverable unit for a wasm feature: the reactor bytes plus a handful of
/// small, co-versioned assets (localized strings, tiny images) the feature
/// needs to render its first frame. Large assets do NOT belong here —
/// download them explicitly through a service, or ship them in the main app
/// bundle; a bundle stays small so it can be delivered/updated cheaply.
public struct WasmBundle: Sendable {
    /// A short name for status lines / cache keys.
    public let label: String
    /// The reactor bytes (`.wasm`, or a runtime-loadable AOT artifact — the
    /// engine dispatches on the magic header).
    public let wasm: [UInt8]
    /// Small co-shipped assets, keyed by a relative path (e.g.
    /// "strings/en.json", "img/badge.png").
    public let assets: [String: Data]

    public init(label: String, wasm: [UInt8], assets: [String: Data] = [:]) {
        self.label = label
        self.wasm = wasm
        self.assets = assets
    }
}

/// Where a wasm feature's bundle comes from. A provider yields:
///   - an INITIAL bundle synchronously (so the first frame renders
///     immediately), from the app package or the newest previously-cached
///     dynamic-delivery bundle, and
///   - an async STREAM of newer bundles that arrive while running — a dev
///     hot-reload shadow, or a production dynamic-delivery update. The host
///     swaps to each as it arrives.
public protocol WasmBundleProvider {
    /// The bundle available synchronously at launch. Nil if none is packaged.
    func initialBundle() -> WasmBundle?
    /// Newer bundles arriving while running. A static provider returns an
    /// empty, immediately-finished stream.
    func bundleUpdates() -> AsyncStream<WasmBundle>
}

extension WasmBundleProvider {
    public func bundleUpdates() -> AsyncStream<WasmBundle> {
        AsyncStream { $0.finish() }
    }
}
