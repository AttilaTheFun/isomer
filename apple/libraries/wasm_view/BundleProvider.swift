// Where a wasm feature's bundle comes from. A provider yields:
//   • an INITIAL bundle synchronously (so the first frame renders immediately),
//     from the app package or the newest previously-cached dynamic-delivery
//     bundle, and
//   • an async STREAM of newer bundles that arrive while running — a dev
//     hot-reload shadow, or a production dynamic-delivery update. The runtime
//     swaps to each as it arrives.
//
// `AppBundleProvider` is the batteries-included default: it serves the packaged
// bundle and, when `ISO_HOT_RELOAD_SERVER` (or `ISO_WASM_PATH`) is set, shadows
// it with a live hot-reload stream — the one case where a bundle is swapped
// mid-run (never done in production; it can flicker/break, that's the point of
// dev-only hot reload). Dynamic delivery slots into the same shape: override
// `initialBundle()` to return the newest cached download, and feed
// `bundleUpdates()` from a background fetch.

import Foundation
import IsomerWasmHost  // WasmServiceBundle
import IsomerWamrRuntime  // WamrRuntime.embeddedImage
#if canImport(FoundationNetworking)
// URLSession lives in a separate module in swift-corelibs-foundation
// (Android / Linux); on Apple it is part of Foundation.
import FoundationNetworking
#endif
// libc, for `stat` in the watched-file source (Foundation re-exports it on
// Apple but not off-platform).
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

// `BundleProvider` itself is the swift_ffi-level `WasmBundleProvider` seam
// (see //shared/wasm_host/WasmServiceBundle.swift for the aliases); this file
// provides the batteries-included implementation + the dev-only hot-reload
// sources.

/// The default provider: the app-packaged wasm, plus a dev hot-reload shadow
/// gated on environment variables. Point production dynamic delivery at the
/// same protocol.
public final class AppBundleProvider: BundleProvider {
    private let resource: String
    private let bundle: Bundle
    private let serverEnv: String
    private let pathEnv: String

    /// - resource: the packaged `<resource>.wasm`.
    /// - serverEnv/pathEnv: env vars that, when set, enable the hot-reload
    ///   shadow (an HTTP server build, or a watched on-disk artifact).
    public init(
        resource: String,
        bundle: Bundle = .main,
        serverEnv: String = "ISO_HOT_RELOAD_SERVER",
        pathEnv: String = "ISO_WASM_PATH"
    ) {
        self.resource = resource
        self.bundle = bundle
        self.serverEnv = serverEnv
        self.pathEnv = pathEnv
    }

    public func initialBundle() -> WasmServiceBundle? {
        if let packaged = WasmServiceBundle.packaged(resource: resource, in: bundle) { return packaged }
        // An app that carries its reactor compiled ahead of time, run in
        // place (`WamrRuntime.embeddedImage`), need not ship the module as
        // well: the image is all WAMR loads (Visor's 83 MB .wasm was read
        // into memory at each launch and never run).
        if WamrRuntime.embeddedImage != nil { return WasmServiceBundle(label: resource, wasm: []) }
        return nil
    }

    public func bundleUpdates() -> AsyncStream<WasmServiceBundle> {
        let env = ProcessInfo.processInfo.environment
        if let server = env[serverEnv], let url = URL(string: server) {
            return HotReloadServerSource(base: url).stream()
        }
        if let path = env[pathEnv], FileManager.default.fileExists(atPath: path) {
            return WatchedFileSource(path: path).stream()
        }
        return AsyncStream { $0.finish() }
    }
}

// MARK: - Hot-reload update sources (dev only)

/// Polls a hot-reload server (see the example's HotReloadServer): `GET /version`
/// (a build counter) and `GET /wasm` (the reactor bytes). Yields a bundle on
/// each version bump. The running timer strong-retains the source; the
/// stream's termination cancels it, breaking the cycle.
private final class HotReloadServerSource {
    private let base: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "wasm-view.hot-reload.server")
    private var timer: DispatchSourceTimer?
    private var version = Int.min
    private var inFlight = false
    private var continuation: AsyncStream<WasmServiceBundle>.Continuation?

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)
    }

    func stream() -> AsyncStream<WasmServiceBundle> {
        AsyncStream { continuation in
            self.continuation = continuation
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 0.5)
            t.setEventHandler { self.poll() }  // strong self keeps the source alive
            self.timer = t
            continuation.onTermination = { [weak self] _ in self?.stop() }
            t.resume()
        }
    }

    private func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.continuation = nil
        }
    }

    private func poll() {
        guard !inFlight else { return }
        inFlight = true
        session.dataTask(with: base.appendingPathComponent("version")) { [weak self] data, _, _ in
            guard let self else { return }
            defer { self.queue.async { self.inFlight = false } }
            guard let data, let text = String(data: data, encoding: .utf8),
                  let v = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return }
            if v != self.version {
                self.version = v
                self.fetchWasm(version: v)
            }
        }.resume()
    }

    private func fetchWasm(version: Int) {
        session.dataTask(with: base.appendingPathComponent("wasm")) { [weak self] data, _, _ in
            guard let self, let data, !data.isEmpty else { return }
            self.continuation?.yield(
                WasmServiceBundle(label: "server build \(version)", wasm: [UInt8](data)))
        }.resume()
    }
}

/// Watches an on-disk `.wasm` (a shared `bazel-bin` artifact) and yields a
/// bundle whenever its mtime bumps. For the iOS Simulator, which can't spawn a
/// compiler but shares the Mac filesystem.
private final class WatchedFileSource {
    private let path: String
    private let queue = DispatchQueue(label: "wasm-view.hot-reload.watch")
    private var timer: DispatchSourceTimer?
    private var lastStamp: TimeInterval = 0
    private var continuation: AsyncStream<WasmServiceBundle>.Continuation?

    init(path: String) { self.path = path }

    func stream() -> AsyncStream<WasmServiceBundle> {
        AsyncStream { continuation in
            self.continuation = continuation
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 0.5)
            t.setEventHandler { self.tick() }
            self.timer = t
            continuation.onTermination = { [weak self] _ in self?.stop() }
            t.resume()
        }
    }

    private func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.continuation = nil
        }
    }

    private func tick() {
        let stamp = mtime()
        guard stamp > lastStamp else { return }
        lastStamp = stamp
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else { return }
        continuation?.yield(WasmServiceBundle(label: "watched build", wasm: [UInt8](data)))
    }

    private func mtime() -> TimeInterval {
        // POSIX stat FOLLOWS symlinks (unlike lstat); the polled artifact is a
        // bazel-bin symlink chain, so only the resolved target's mtime bumps.
        var st = stat()
        guard stat(path, &st) == 0 else { return 0 }
        // The nanosecond field is spelled differently per libc.
        #if canImport(Darwin)
        let sec = st.st_mtimespec.tv_sec, nsec = st.st_mtimespec.tv_nsec
        #else
        let sec = st.st_mtim.tv_sec, nsec = st.st_mtim.tv_nsec
        #endif
        return TimeInterval(sec) + TimeInterval(nsec) / 1e9
    }
}
