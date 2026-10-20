// The Android host bridge, expressed as a swift_ffi surface.
//
// Kotlin implements `AndroidHost` (an object expression in NativeBridge.kt)
// and passes it into `nativeStart`; Swift calls back out through the
// generated JNI foreign proxy, and the GL thread drives the runtime through
// the exported functions. This replaces the ~500 lines of hand-written JNI
// (cached jmethodIDs, packed-jlong returns, version-script exports) that
// previously carried the same surface.

import ImageIO
package import IsomerFFI
internal import IsomerNetworkHost
import Synchronization
@_spi(ExperimentalCustomExecutors) import _Concurrency
@_spi(ExperimentalScheduling) import _Concurrency

#if canImport(SwiftGPU)
import SwiftGPU
#endif

@ExportedStruct
package struct TextMetrics {
    public let width: Double
    public let height: Double
}

@ExportedStruct
package struct ImageInfoValue {
    /// 0 loading, 1 ready, 2 failed.
    public let state: Int32
    public let width: Double
    public let height: Double
}

/// The Kotlin side of the host bridge. Under the SwiftGPURenderer drawing —
/// chrome included — stays in Swift (`nativeRender` returns an empty draw
/// list); measurement, app-authored representables (`syncHostViews`), and
/// services call up. Under the JetpackComposeRenderer the serialized tree
/// arrives through `renderTree`.
@ExportedInterface
package protocol AndroidHost {
    func measureText(text: String, fontSize: Double, weight: Int32, wrapWidth: Double) -> TextMetrics
    func imageInfo(source: String, isRemote: Bool) -> ImageInfoValue
    func openURL(url: String)
    func platformCommand(key: String, value: String)
    func beginTextInput(text: String, x: Double, y: Double, width: Double, height: Double, fontSize: Double)
    func endTextInput()
    func syncHostViews(viewsJSON: String)
    /// Rasterize content for the SwiftGPU renderer (spec JSON in, [w u32]
    /// [h u32][premultiplied RGBA8...] out; empty when unavailable).
    func rasterize(spec: String) -> [UInt8]
    /// JetpackComposeRenderer path: render the serialized view tree (the
    /// tree.fbs FlatBuffer) as composables. Unused under the SwiftGPURenderer.
    func renderTree(tree: [UInt8])
    /// An encoded picture's bytes for `source` (`IsomerImages`), decoded off
    /// the main thread; empty bytes forget it.
    func registerImage(source: String, bytes: [UInt8])
    /// ImageIO's thumbnail: decode `bytes` for `source` NOW, on the calling
    /// thread (any thread), no larger than `maxPixelSize` (0: whole),
    /// upright when `transform`; returns the decoded size (state 1) or
    /// failure (state 2).
    func decodeImage(source: String, bytes: [UInt8], maxPixelSize: Int32, transform: Bool) -> ImageInfoValue
    /// Device pixels per point.
    func displayScale() -> Double
    /// Main-actor work was queued (a `Task { @MainActor in }` body, an
    /// awaited service answer resuming): call `nativeRunMainJobs` on the
    /// thread that owns the runtime, then render.
    func scheduleMainJobs()
    /// A timed job (`Task.sleep`) is waiting: call `nativeRunMainJobs` on
    /// the runtime's thread after `milliseconds`, when it will be due.
    func scheduleMainJobsAfter(milliseconds: Int32)
}

/// The active host, installed by `nativeStart`. The generated foreign proxy
/// holds a JNI global ref to the Kotlin object for as long as Swift keeps
/// this reference.
nonisolated(unsafe) var androidHost: (any AndroidHost)?

/// Display name of the renderer `nativeStart` bound (for the System screen).
package nonisolated(unsafe) var _boundRendererName = "None"

/// Bridge calls shared with the IsomerBridge module.
package enum _AndroidBridgeCalls {
    public static func openURL(_ url: String) {
        androidHost?.openURL(url: url)
    }
}

// MARK: - Exports (Kotlin -> Swift)

// The app's synthesized @main entry point, run once to install the App into
// the Runtime.
@_extern(c, "main")
func _application_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

#if canImport(SwiftGPU)
/// The SwiftGPU surface for Android: swift_gpu's GLES device, driven on
/// the GL thread (frames render inside nativeRender).
final class GLESRendererSurface: SwiftGPURendererSurface {
    let gpuDevice = GLESGPUDevice()
    var displayScale: Double = 1
    var widthPx = 0
    var heightPx = 0
    var device: GPUDevice { gpuDevice }

    func beginFrame(clear: GPUColor, width: Double, height: Double) -> GPURenderPass? {
        gpuDevice.beginFrame(widthPx: widthPx, heightPx: heightPx, clear: clear)
    }

    func endFrame() {
        gpuDevice.endFrame()
    }
}

nonisolated(unsafe) var gpuSurface: GLESRendererSurface?
#endif

// The surface's device-pixel size + density arrive before nativeStart
// creates the renderer surface, so they live in globals.
nonisolated(unsafe) var surfaceWidthPx = 0
nonisolated(unsafe) var surfaceHeightPx = 0
nonisolated(unsafe) var surfaceDensity = 1.0

/// The GL surface's device-pixel size + density, for the SwiftGPU renderer.
@ExportedFunction
package func nativeSurfaceChanged(widthPx: Int32, heightPx: Int32, density: Double) {
    surfaceWidthPx = Int(widthPx)
    surfaceHeightPx = Int(heightPx)
    surfaceDensity = density
    #if canImport(SwiftGPU)
    if let surface = gpuSurface {
        surface.widthPx = surfaceWidthPx
        surface.heightPx = surfaceHeightPx
        surface.displayScale = surfaceDensity
        surface.gpuDevice.contextLost() // fresh EGL context
    }
    #endif
}

// MARK: - Swift concurrency

// Swift concurrency's platform executors on Android are Dispatch's queues,
// and nothing drains the main one in an Android process (the main thread
// runs a Looper). Install an executor FACTORY (Swift 6.3) that routes every
// job — the MainActor's, the global executor's, resumed continuations' —
// into a queue the host drains on its runtime thread (`nativeRunMainJobs`),
// so `Task { @MainActor in }`, `MainActor.run`, `.task {}` bodies and the
// continuations of awaited platform services actually run. Single-threaded
// like the wasm executor in swift_ffi: async work that must block (network,
// disk) lives behind the injected services, which run on host threads.
final class AndroidHostExecutor: MainExecutor, TaskExecutor, @unchecked Sendable {
    static let shared = AndroidHostExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        mainJobs.withLock { $0.append(unowned) }
        androidHost?.scheduleMainJobs()
    }

    var isMainExecutor: Bool { true }
    func run() throws {}
    func runUntil(_ condition: () -> Bool) throws {}
    func stop() {}
    func checkIsolated() {}
    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
}

/// Timed jobs (`Task.sleep`, timeouts) wait here with the time they are due;
/// the host is asked to drain again then (`scheduleMainJobsAfter`), and the
/// drain runs those that are due. Without this the stdlib has no executor to
/// hand a delayed job to, and traps.
extension AndroidHostExecutor: SchedulingExecutor {
    func enqueue<C: Clock>(_ job: consuming ExecutorJob, after delay: C.Duration,
                           tolerance: C.Duration?, clock: C) {
        let unowned = UnownedJob(job)
        var milliseconds: Int64 = 0
        if let duration = delay as? Duration {
            let (seconds, attoseconds) = duration.components
            milliseconds = seconds &* 1000 &+ (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        }
        let wait = max(0, milliseconds)
        let due = ContinuousClock.now.advanced(by: .milliseconds(wait))
        timedJobs.withLock { $0.append((unowned, due)) }
        armTimedWake()
    }
}

/// When the looper is set to run main jobs next for the timed ones (nil:
/// no wake pending).
private let armedWake = Mutex<ContinuousClock.Instant?>(nil)

/// Keeps one looper wake set for the soonest timed job. The looper's delayed
/// callbacks can land a hair before a job's deadline (millisecond rounding);
/// every run re-arms for what is still waiting, so a job is never left
/// without a wake.
private func armTimedWake() {
    let now = ContinuousClock.now
    guard let soonest = timedJobs.withLock({ $0.map(\.due).min() }) else { return }
    let arm = armedWake.withLock { armed -> Bool in
        if let armed, armed > now, armed <= soonest { return false }
        armed = soonest
        return true
    }
    guard arm else { return }
    let (seconds, attoseconds) = (soonest - now).components
    let milliseconds = max(0, seconds &* 1000 &+ (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
    androidHost?.scheduleMainJobsAfter(milliseconds: Int32(clamping: milliseconds + 1))
}

struct AndroidExecutorFactory: ExecutorFactory {
    static var mainExecutor: any MainExecutor { AndroidHostExecutor.shared }
    static var defaultExecutor: any TaskExecutor { AndroidHostExecutor.shared }
}

private let mainJobs = Mutex<[UnownedJob]>([])
private let timedJobs = Mutex<[(job: UnownedJob, due: ContinuousClock.Instant)]>([])
private nonisolated(unsafe) var executorInstalled = false

private func installMainExecutorHook() {
    guard !executorInstalled else { return }
    executorInstalled = true
    _createExecutors(factory: AndroidExecutorFactory.self)
}

/// Runs the queued main-actor jobs (on the runtime thread). Returns whether
/// any ran, so the caller knows to render.
@ExportedFunction
package func nativeRunMainJobs() -> Bool {
    var ran = false
    while true {
        // Timed jobs whose delay is up join the queue, soonest first.
        let now = ContinuousClock.now
        let due = timedJobs.withLock { timed -> [UnownedJob] in
            let ready = timed.filter { $0.due <= now }.sorted { $0.due < $1.due }.map(\.job)
            timed.removeAll { $0.due <= now }
            return ready
        }
        if !due.isEmpty { mainJobs.withLock { $0.append(contentsOf: due) } }
        let batch = mainJobs.withLock { jobs -> [UnownedJob] in
            defer { jobs.removeAll() }
            return jobs
        }
        if batch.isEmpty {
            armTimedWake()
            return ran
        }
        ran = true
        for job in batch {
            job.runSynchronously(on: AndroidHostExecutor.shared.asUnownedSerialExecutor())
        }
    }
}

// MARK: - Dispatch's main queue

// `DispatchQueue.main` is the Swift SDK's own Dispatch here (Apple's
// open-source libdispatch; Isomer adds none of its own). Nothing in an
// Android process drains its main queue, so the host watches the queue's
// wake handle (an eventfd) on the main looper and drains it when it fires,
// as CoreFoundation's run loop does on Linux.
#if hasFeature(Extern)
@_extern(c, "_dispatch_get_main_queue_handle_4CF")
private func _dispatchMainQueueHandle() -> Int32
@_extern(c, "_dispatch_main_queue_callback_4CF")
private func _dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)
#endif

/// The main queue's wake handle, readable while work is queued (-1: none).
@ExportedFunction
package func nativeMainQueueHandle() -> Int32 {
    #if hasFeature(Extern)
    return _dispatchMainQueueHandle()
    #else
    return -1
    #endif
}

/// Runs the work queued on the main queue (on the main thread, which the
/// queue belongs to).
@ExportedFunction
package func nativeDrainMainQueue() {
    #if hasFeature(Extern)
    _dispatchMainQueueCallback(nil)
    #endif
}

@ExportedFunction
package func nativeStart(host: any AndroidHost, renderer: String, width: Double, height: Double) {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    MainActor.assumeIsolated {
        androidHost = host
        // Foundation's networking: what the Kotlin runtime injected (or
        // handed to installIsomerNetworkHosts already).
        installInjectedNetworkHosts()
        installMainExecutorHook()
        Runtime.shared.displayScale = host.displayScale()
        // ImageIO decodes on whatever thread asks (the host's JNI attaches it).
        _ImageIOHost.decode = { source, bytes, maxPixelSize, transform in
            guard let info = androidHost?.decodeImage(
                source: source, bytes: bytes, maxPixelSize: Int32(maxPixelSize), transform: transform),
                info.state == 1 else { return nil }
            return (Int(info.width), Int(info.height))
        }
        _ImageIOHost.release = { source in androidHost?.registerImage(source: source, bytes: []) }
        if Runtime.shared.host == nil {
            _ = _application_main(0, nil)
        }
        androidLog("nativeStart \(renderer) \(width)x\(height)")
        if renderer == "jetpackCompose" {
            _boundRendererName = "Jetpack Compose"
            Renderer.bind(JetpackComposeRenderer { androidHost?.renderTree(tree: $0) })
            Runtime.shared.start(host: AndroidHostBridge(), width: width, height: height)
            return
        }
        #if canImport(SwiftGPU)
        // The self-drawing renderer: SwiftGPU draws on the GL thread; Kotlin
        // keeps the services half (measurement, raster, IME, host views).
        let surface = gpuSurface ?? GLESRendererSurface()
        surface.widthPx = surfaceWidthPx
        surface.heightPx = surfaceHeightPx
        surface.displayScale = surfaceDensity
        gpuSurface = surface
        let gpuRenderer = SwiftGPURenderer(services: AndroidHostBridge(), surface: surface)
        _boundRendererName = "SwiftGPU"
        Renderer.bind(gpuRenderer)
        #if canImport(SwiftMap)
        Renderer.hostRendersMaps = true  // `Map` draws real SwiftMap tiles
        #endif
        Runtime.shared.start(host: gpuRenderer, width: width, height: height)
        #else
        #error("HostDrawnRenderer has been removed; SwiftGPU is now the only self-drawing renderer. Link swift_gpu (OpenGL ES) for Android — see docs/renderer_layers.md")
        #endif
    }
}

/// Renders a frame. The self-drawing renderer (SwiftGPU) draws HERE on the GL
/// thread through swift_gpu; the component-system renderer (Jetpack Compose)
/// ships its tree via `renderTree`. Either way there is no draw list to hand
/// back — the old host-drawn op-buffer path was removed with HostDrawnRenderer.
@ExportedFunction
package func nativeRender() -> [UInt8] {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    return MainActor.assumeIsolated {
        AndroidHostState.shared.renderScheduled = false
        Runtime.shared.renderFrame()
        return []
    }
}

/// Whether the runtime wants another frame after the last render (a running
/// fling, animation, sheet transition, or spinner).
@ExportedFunction
package func nativeWantsRender() -> Bool {
    AndroidHostState.shared.renderScheduled
}

@ExportedFunction
package func nativePointer(kind: Int32, x: Double, y: Double) -> Bool {
    Runtime.shared.pointerEvent(kind: Int(kind), x: x, y: y)
    return AndroidHostState.shared.renderScheduled
}

@ExportedFunction
package func nativeWheel(x: Double, y: Double, deltaX: Double, deltaY: Double) -> Bool {
    Runtime.shared.wheelEvent(x: x, y: y, deltaX: deltaX, deltaY: deltaY)
    return AndroidHostState.shared.renderScheduled
}

@ExportedFunction
package func nativeResize(width: Double, height: Double) {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    MainActor.assumeIsolated {
        androidLog("nativeResize \(width)x\(height)")
        Runtime.shared.resize(width: width, height: height)
    }
}

@ExportedFunction
package func nativeTextChanged(text: String) -> Bool {
    Runtime.shared.textChanged(text)
    return AndroidHostState.shared.renderScheduled
}

@ExportedFunction
package func nativeTextSubmitted() -> Bool {
    Runtime.shared.textSubmitted()
    return AndroidHostState.shared.renderScheduled
}

@ExportedFunction
package func nativeHostEvent(id: String, value: String) -> Bool {
    Runtime.shared.hostViewEvent(id: id, value: value)
    return AndroidHostState.shared.renderScheduled
}

/// A field's key (`.onKeyPress`): true when the app took it, so the
/// renderer keeps it from the field.
@ExportedFunction
package func nativeKeyEvent(id: String, value: String) -> Bool {
    Runtime.shared.keyPressEvent(id: id, value: value)
}

/// System back button/gesture: pop navigation or dismiss a sheet. Returns
/// true if the runtime handled it.
@ExportedFunction
package func nativeBack() -> Bool {
    Runtime.shared.handleBackButton()
}

/// Activity lifecycle mapped to `@Environment(\.scenePhase)`:
/// "active" (resumed) / "inactive" (paused) / "background" (stopped).
@ExportedFunction
package func nativeSetColorScheme(dark: Bool) {
    Runtime.shared.setSystemColorScheme(dark: dark)
}

@ExportedFunction
package func nativeSetScenePhase(phase: String) {
    switch phase {
    case "background": Runtime.shared.setScenePhase(.background)
    case "inactive": Runtime.shared.setScenePhase(.inactive)
    default: Runtime.shared.setScenePhase(.active)
    }
}

/// A URL delivered to the running app (a VIEW intent's data); dispatched to
/// `.onOpenURL` handlers.
@ExportedFunction
package func nativeOpenURL(url: String) {
    Runtime.shared.openURL(external: url)
}

/// Edge overscroll distance (logical points) for the native scroller `path`.
@ExportedFunction
package func nativeOverscroll(path: String, amount: Double) {
    Runtime.shared.nativeOverscroll(path: path, amount: amount)
}

