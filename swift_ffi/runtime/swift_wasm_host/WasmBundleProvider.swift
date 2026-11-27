// The bundle-delivery seam: where a host obtains the wasm feature bundles it
// runs. swift_ffi defines the protocol only — packaged resources, download
// caches, and dev hot-reload streams are host implementations plugged in by
// the app (see isomer's AppBundleProvider for a batteries-included
// example).

import Foundation
// The C library, for reading part of a file (an Android asset stored in its
// APK: `WasmModuleSource.file(path:offset:length:)`) without reading the rest.
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Where a wasm module's bytes come from: memory, or a file the host's
/// engine reads itself when it launches the module. A file keeps a large
/// module (a runtime module is tens of megabytes) out of whatever hands the
/// bundle over: on Android, a module read into a Kotlin `ByteArray` and
/// copied through JNI ran an Android 6 emulator out of the JVM's memory,
/// where the engine reading it from a path holds it once, natively.
public enum WasmModuleSource: Sendable, Hashable {
    /// The module's bytes.
    case bytes([UInt8])
    /// `length` bytes of the file at `path`, from `offset` (nil: to the
    /// file's end). A region is how an Android asset stored uncompressed is
    /// read in place, in its APK (the asset's file descriptor's range).
    case file(path: String, offset: Int = 0, length: Int? = nil)

    /// Why a module's file couldn't be read.
    public struct ReadError: Error, CustomStringConvertible {
        public let path: String
        public let reason: String
        public var description: String { "can't read the module at \(path): \(reason)" }
    }

    /// The module's bytes: the bytes themselves, or the file's, read now
    /// (each call reads it again: a host keeps them only while it needs them).
    public func read() throws -> [UInt8] {
        switch self {
        case .bytes(let bytes):
            return bytes
        case .file(let path, let offset, let length):
            return try Self.read(path: path, offset: offset, length: length)
        }
    }

    private static func read(path: String, offset: Int, length: Int?) throws -> [UInt8] {
        guard offset >= 0, (length ?? 0) >= 0 else {
            throw ReadError(path: path, reason: "a negative offset or length")
        }
        // A whole file: Foundation's read, sized by the file.
        if offset == 0, length == nil {
            do {
                return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                throw ReadError(path: path, reason: "\(error)")
            }
        }
        // Part of one: the C library's stream, from the offset. (The CRT
        // deprecates fopen for fopen_s, a warning these targets fail on.)
        #if os(Windows)
        var opened: UnsafeMutablePointer<FILE>?
        guard fopen_s(&opened, path, "rb") == 0, let file = opened else {
            throw ReadError(path: path, reason: "it can't be opened")
        }
        #else
        guard let file = fopen(path, "rb") else {
            throw ReadError(path: path, reason: "it can't be opened")
        }
        #endif
        defer { fclose(file) }
        #if os(Windows)
        let seeked = _fseeki64(file, Int64(offset), SEEK_SET)
        #else
        let seeked = fseeko(file, off_t(offset), SEEK_SET)
        #endif
        guard seeked == 0 else { throw ReadError(path: path, reason: "it has no offset \(offset)") }
        // A region of known length (an asset in its APK): read straight into
        // one buffer of that size, the module held once.
        if let length {
            var got = 0
            let bytes = [UInt8](unsafeUninitializedCapacity: length) { buffer, count in
                // (Unwrapped: a buffer of a non-zero length has an address,
                // and fread's isn't optional.)
                while got < length {
                    let read = fread(buffer.baseAddress! + got, 1, length - got, file)
                    if read == 0 { break }
                    got += read
                }
                count = got
            }
            guard got == length else {
                throw ReadError(path: path, reason: "it ends \(length - got) bytes before the region does")
            }
            return bytes
        }
        // To the file's end, from the offset: in chunks.
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            // (Unwrapped: Glibc's, Bionic's and the CRT's fread take a pointer
            // that isn't optional; a chunk of 1 MiB always has one.)
            let got = chunk.withUnsafeMutableBytes { fread($0.baseAddress!, 1, $0.count, file) }
            if got == 0 { break }
            bytes.append(contentsOf: chunk[0..<got])
        }
        return bytes
    }
}

/// A deliverable unit for a wasm feature: its module plus a handful of
/// small, co-versioned assets (localized strings, tiny images) the feature
/// needs to render its first frame. Large assets do NOT belong here —
/// download them explicitly through a service, or ship them in the main app
/// bundle; a bundle stays small so it can be delivered/updated cheaply.
///
/// The module is a reactor (self-contained: the standard library, Foundation
/// and the UI framework linked in), or a side module over a runtime module
/// the host holds (the feature's own code alone, a few hundred kilobytes):
/// `kind` says which. Its bytes are in memory or in a file the engine reads
/// at launch (`module`).
public struct WasmBundle: Sendable {
    /// What a bundle's module is.
    public enum Kind: Sendable, Hashable {
        /// A self-contained reactor: the engine launches it alone.
        case reactor
        /// A side module linked against the runtime module named `runtime`
        /// (the name the host gave the runtime module it holds): the engine
        /// launches that runtime module and loads this over it. A side module
        /// binds to the exact runtime build it was linked against, so a host
        /// refuses one naming another.
        case sideModule(runtime: String)
    }

    /// A short name for status lines / cache keys.
    public let label: String
    /// Where the module's bytes come from.
    public let module: WasmModuleSource
    /// A reactor, or a side module over a runtime module.
    public let kind: Kind
    /// Small co-shipped assets, keyed by a relative path (e.g.
    /// "strings/en.json", "img/badge.png").
    public let assets: [String: Data]

    /// The module's bytes (`.wasm`, or a runtime-loadable AOT artifact — the
    /// engine dispatches on the magic header): a file-backed module's are
    /// read on each use (empty if it can't be read; `module.read()` says
    /// why).
    public var wasm: [UInt8] { (try? module.read()) ?? [] }

    /// A reactor, its bytes in memory.
    public init(label: String, wasm: [UInt8], assets: [String: Data] = [:]) {
        self.init(label: label, module: .bytes(wasm), assets: assets)
    }

    /// A reactor or a side module (`kind`), its bytes in memory or in a file.
    public init(label: String, module: WasmModuleSource, kind: Kind = .reactor, assets: [String: Data] = [:]) {
        self.label = label
        self.module = module
        self.kind = kind
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
