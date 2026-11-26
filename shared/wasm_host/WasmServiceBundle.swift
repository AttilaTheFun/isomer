// isomer's bundle vocabulary is the swift_ffi-level seam: `WasmBundle`
// and `WasmBundleProvider` (SwiftFFIWasmHost) are the types every host and
// third-party delivery implementation plug into; this file keeps the
// established isomer names as aliases and adds the loaders for the
// common sources (a packaged app resource, an on-disk bundle directory).

import Foundation
import SwiftFFIWasmHost

/// A deliverable unit for a wasm feature — the isomer name for the
/// swift_ffi-level `WasmBundle` (a reactor or a side module, in memory or in
/// a file, + small co-versioned assets).
public typealias WasmServiceBundle = WasmBundle

/// Where a feature's bundle comes from — the isomer name for the
/// swift_ffi-level `WasmBundleProvider` (sync initial bundle + async update
/// stream). Implementations: `AppBundleProvider` (packaged + dev hot-reload
/// shadow, apple/libraries/wasm_view) or a production dynamic-delivery
/// provider over a download cache.
public typealias BundleProvider = WasmBundleProvider

extension WasmBundle {
    /// Loads a bundle from a single packaged reactor resource (no assets).
    public static func packaged(
        resource: String, ext: String = "wasm", in bundle: Bundle = .main
    ) -> WasmBundle? {
        guard let url = bundle.url(forResource: resource, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        return WasmBundle(label: resource, wasm: [UInt8](data))
    }

    /// A bundle whose module is a packaged resource's file, read by the
    /// engine when it launches (not now, and not kept): a reactor, or a side
    /// module over the host's runtime module (`kind`).
    public static func packagedFile(
        resource: String, ext: String = "wasm", in bundle: Bundle = .main, kind: Kind = .reactor
    ) -> WasmBundle? {
        guard let module = WasmModuleSource.packaged(resource: resource, ext: ext, in: bundle) else { return nil }
        return WasmBundle(label: resource, module: module, kind: kind)
    }

    /// Loads a bundle directory: `<dir>/feature.wasm` plus every file under
    /// `<dir>/assets/` (recursively) keyed by its path relative to `assets/`.
    public static func directory(_ dir: URL, label: String? = nil) -> WasmBundle? {
        let wasmURL = dir.appendingPathComponent("feature.wasm")
        guard let wasm = try? Data(contentsOf: wasmURL) else { return nil }
        var assets: [String: Data] = [:]
        let assetsDir = dir.appendingPathComponent("assets")
        let fm = FileManager.default
        // FileManager's path API, which every Foundation a host links has
        // (no directory enumerator in Isomer's, the Swift SDK's on Android).
        for path in (try? fm.subpathsOfDirectory(atPath: assetsDir.path)) ?? [] {
            let file = assetsDir.appendingPathComponent(path)
            guard (try? fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular,
                  let data = try? Data(contentsOf: file) else { continue }
            assets[path] = data
        }
        return WasmBundle(label: label ?? dir.lastPathComponent, wasm: [UInt8](wasm), assets: assets)
    }
}

extension WasmModuleSource {
    /// A packaged resource's file (`Bundle.main`'s, by default), for the
    /// engine to read when it launches the module: a runtime module
    /// (`WasmRuntimeModule`'s source) or a bundle's. Nil if there is none.
    public static func packaged(
        resource: String, ext: String = "wasm", in bundle: Bundle = .main
    ) -> WasmModuleSource? {
        guard let url = bundle.url(forResource: resource, withExtension: ext) else { return nil }
        return .file(path: url.path)
    }
}
