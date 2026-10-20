// isomer's bundle vocabulary is the swift_ffi-level seam: `WasmBundle`
// and `WasmBundleProvider` (SwiftFFIWasmHost) are the types every host and
// third-party delivery implementation plug into; this file keeps the
// established isomer names as aliases and adds the loaders for the
// common sources (a packaged app resource, an on-disk bundle directory).

import Foundation
import SwiftFFIWasmHost

/// A deliverable unit for a wasm feature — the isomer name for the
/// swift_ffi-level `WasmBundle` (reactor bytes + small co-versioned assets).
public typealias WasmServiceBundle = WasmBundle

/// Where a feature's bundle comes from — the isomer name for the
/// swift_ffi-level `WasmBundleProvider` (sync initial bundle + async update
/// stream). Implementations: `AppBundleProvider` (packaged + dev hot-reload
/// shadow, apple/libraries/wasm_view) or a production dynamic-delivery
/// provider over a download cache.
public typealias BundleProvider = WasmBundleProvider

extension WasmBundle {
    /// Loads a bundle from a single packaged reactor resource (no assets).
    ///
    /// Prefers a native `.aot` (what release builds package via `--config=release`
    /// / `reactor_artifact`) and falls back to the interpreted `.wasm`. The bytes
    /// are dispatched by their magic header downstream (WAMR auto-detects `\0aot`
    /// vs `\0asm`), so the field is still called `wasm` either way.
    public static func packaged(
        resource: String, ext: String = "wasm", in bundle: Bundle = .main
    ) -> WasmBundle? {
        for candidate in ["aot", ext] {
            if let url = bundle.url(forResource: resource, withExtension: candidate),
               let data = try? Data(contentsOf: url) {
                return WasmBundle(label: resource, wasm: [UInt8](data))
            }
        }
        return nil
    }

    /// Loads a bundle directory: `<dir>/feature.wasm` plus every file under
    /// `<dir>/assets/` (recursively) keyed by its path relative to `assets/`.
    public static func directory(_ dir: URL, label: String? = nil) -> WasmBundle? {
        let wasmURL = dir.appendingPathComponent("feature.wasm")
        guard let wasm = try? Data(contentsOf: wasmURL) else { return nil }
        var assets: [String: Data] = [:]
        let assetsDir = dir.appendingPathComponent("assets")
        let fm = FileManager.default
        if let walker = fm.enumerator(at: assetsDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in walker
            where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if let data = try? Data(contentsOf: file) {
                    let key = file.path.replacingOccurrences(of: assetsDir.path + "/", with: "")
                    assets[key] = data
                }
            }
        }
        return WasmBundle(label: label ?? dir.lastPathComponent, wasm: [UInt8](wasm), assets: assets)
    }
}
