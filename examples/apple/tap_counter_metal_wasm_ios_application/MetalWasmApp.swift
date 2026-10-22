// The wasm+METAL iOS cell of the counter benchmark (docs/benchmarks.md#ios),
// mostly a curiosity: the SAME shared TapCounter.swift as a wasm reactor,
// drawn by the self-drawing `SwiftGPURenderer` through swift_gpu's METAL
// backend — the iOS analogue of the desktop wasm hosts. The wiring mirrors
// LinuxWasmHost: the reactor runs on WasmKit under the shared feature
// runtime (WasmFeatureRuntime over WasmKitRuntime) and emits tree.fbs, the
// host decodes it and SwiftGPURenderer lays out + draws every pixel into an
// MTKView pass.
//
// UIKit only — this module compiles the SwiftUI *reimplementation* core
// (Runtime/Renderer/SwiftGPURenderer), whose type names (View/Text/Color…)
// would clash with the real SwiftUI if both were imported.

import Foundation
import IsomerWasmHost
import IsomerWasmKitRuntime
import SwiftGPU
import UIKit
public import IsomerSwiftUI

// The reimplementation core (compiled into this module) shims CGSize/CGRect/
// URL for non-Apple platforms; UIKit needs the real ones — qualify.
private typealias FURL = Foundation.URL
private typealias CFSize = CoreFoundation.CGSize
private typealias CFRect = CoreFoundation.CGRect

// MARK: - App shell

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = MetalWasmViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

// MARK: - The cell (reactor + renderer + surface)

@MainActor
final class MetalWasmCell {
    static var shared: MetalWasmCell?

    var core: WasmFeatureRuntime?
    let decoder: FlatTreeDecoder
    var latestTree: RenderNode?
    /// Frames handed up by `onTree`, pending decode on the draw callback.
    /// An ordered QUEUE, deliberately not a latest-wins slot: with diff-aware
    /// updates each buffer is a delta against the retained tree (a tap emits
    /// press + un-press patches in one pump); dropping one desyncs the
    /// retained tree and every later splice corrupts it.
    var pendingBytes: [[UInt8]] = []

    init() {
        decoder = FlatTreeDecoder(send: { id, value in
            MetalWasmCell.shared?.sendEvent(id: id, value: value)
        })
    }

    func sendEvent(id: String, value: String) {
        core?.send(id: id, value: value)
    }
}

// MARK: - Metal surface adapter

/// Bridges the callback-style `GPUSurfaceView` (a pass per `draw`) to the
/// `SwiftGPURendererSurface` pull model: the view controller stashes the
/// frame's pass here before running the render, and `beginFrame` hands it out.
final class MetalRendererSurface: SwiftGPURendererSurface {
    let gpuDevice: MetalGPUDevice
    var displayScale: Double = Double(UIScreen.main.scale)
    var currentPass: GPURenderPass?

    init(device: MetalGPUDevice) {
        gpuDevice = device
    }

    var device: GPUDevice { gpuDevice }

    func beginFrame(clear: GPUColor, width: Double, height: Double) -> GPURenderPass? {
        currentPass
    }

    func endFrame() {}
}

// MARK: - Host services (measurement + rasterization on UIKit/CoreGraphics)

final class MetalServicesHost: HostBridge {
    static let lineHeight: CGFloat = 1.3

    private func font(size: Double, weight: Int) -> UIFont {
        let uiWeight: UIFont.Weight
        switch weight {
        case ..<350: uiWeight = .light
        case ..<450: uiWeight = .regular
        case ..<550: uiWeight = .medium
        case ..<650: uiWeight = .semibold
        default: uiWeight = .bold
        }
        return .systemFont(ofSize: size, weight: uiWeight)
    }

    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(size: fontSize, weight: weight)]
        let bounds = CFSize(
            width: wrapWidth ?? Double.greatestFiniteMagnitude,
            height: Double.greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(
            with: bounds, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        let lines = max(1.0, ((rect.height) / (fontSize * 1.2)).rounded())
        return CGSize(width: Double(ceil(rect.width)), height: lines * fontSize * Self.lineHeight)
    }

    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus { .loading }

    /// Rasterize SwiftGPURenderer specs ([w u32][h u32][premultiplied RGBA8…]).
    func rasterize(_ spec: String) -> [UInt8] {
        guard let data = spec.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = json["kind"] as? String
        else { return [] }
        let scale = CGFloat(UIScreen.main.scale)

        func pack(_ image: UIImage) -> [UInt8] {
            guard let cg = image.cgImage else { return [] }
            let width = cg.width
            let height = cg.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CFRect(x: 0, y: 0, width: Double(width), height: Double(height)))
            var out = [UInt8]()
            out.reserveCapacity(8 + pixels.count)
            for value in [UInt32(width), UInt32(height)] {
                out.append(UInt8(value & 0xFF))
                out.append(UInt8((value >> 8) & 0xFF))
                out.append(UInt8((value >> 16) & 0xFF))
                out.append(UInt8((value >> 24) & 0xFF))
            }
            out.append(contentsOf: pixels)
            return out
        }

        func color(_ r: Any?, _ g: Any?, _ b: Any?, _ a: Any?) -> UIColor {
            UIColor(
                red: CGFloat((r as? Double) ?? 0), green: CGFloat((g as? Double) ?? 0),
                blue: CGFloat((b as? Double) ?? 0), alpha: CGFloat((a as? Double) ?? 1))
        }

        switch kind {
        case "text":
            let text = json["text"] as? String ?? ""
            let size = json["size"] as? Double ?? 17
            let weight = json["weight"] as? Int ?? 400
            let wrap = json["wrap"] as? Double ?? 0
            let textColor = color(json["r"], json["g"], json["b"], json["a"])
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: size, weight: weight), .foregroundColor: textColor,
            ]
            let bounds = CFSize(
                width: wrap > 0 ? wrap + 1 : Double.greatestFiniteMagnitude,
                height: Double.greatestFiniteMagnitude)
            let rect = (text as NSString).boundingRect(
                with: bounds, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            let sizePts = CFSize(width: ceil(rect.width) + 1, height: ceil(rect.height))
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let renderer = UIGraphicsImageRenderer(size: sizePts, format: format)
            let image = renderer.image { _ in
                (text as NSString).draw(
                    with: CFRect(origin: .zero, size: sizePts),
                    options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            }
            return pack(image)
        case "gradient", "shadow":
            let w = json["w"] as? Double ?? 1
            let h = json["h"] as? Double ?? 1
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let sizePts = CFSize(width: max(w, 1), height: max(h, 1))
            let renderer = UIGraphicsImageRenderer(size: sizePts, format: format)
            let fill = color(json["r"], json["g"], json["b"], json["a"])
            let image = renderer.image { ctx in
                fill.setFill()
                ctx.fill(CFRect(origin: .zero, size: sizePts))
            }
            return pack(image)
        default:
            return []
        }
    }

    func syncHostViews(_ viewsJSON: String) {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {}
    func endTextInput() {}

    func scheduleRender() {
        MainActor.assumeIsolated { MetalWasmViewController.shared?.scheduleRender() }
    }

    func now() -> Double { Foundation.Date().timeIntervalSince1970 }

    func log(_ message: String) { NSLog("%@", message) }
}

// MARK: - View controller (surface + input + render loop + bench)

@MainActor
final class MetalWasmViewController: UIViewController {
    static var shared: MetalWasmViewController?

    private var surfaceView: GPUSurfaceView?
    private var surface: MetalRendererSurface?
    private var renderer: SwiftGPURenderer?
    private var started = false

    // Bench mode (-bench): the self-drawn analogue of //apple/libraries/bench,
    // same methodology — startup = process init -> the end of the first
    // MANUALLY DRIVEN draw whose tree contains the content (encode + command
    // buffer commit done: handed to the GPU); tap = trigger receipt -> the end
    // of the manually driven draw that drew the updated label. Manual
    // `draw(bounds)` calls remove all display-link pacing from the metric.
    private let bench = ProcessInfo.processInfo.arguments.contains("-bench")
        || ProcessInfo.processInfo.environment["ISO_BENCH"] == "1"
    private var benchStartupMs: Double = -1
    private var benchTaps: [Double] = []
    private var benchLastLabel = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.shared = self
        view.backgroundColor = .white
        // Benchmark runs are unattended: a locked screen starves the Metal
        // layer of drawables and stalls the whole cell.
        UIApplication.shared.isIdleTimerDisabled = true

        guard let device = MetalGPUDevice() else { return }
        let surface = MetalRendererSurface(device: device)
        let renderer = SwiftGPURenderer(services: MetalServicesHost(), surface: surface)
        Renderer.bind(renderer)
        self.surface = surface
        self.renderer = renderer

        let surfaceView = device.makeSurfaceView()
        surfaceView.clear = GPUColor(red: 0.98, green: 0.98, blue: 0.98)
        surfaceView.frame = view.bounds
        surfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surfaceView.onDraw = { [weak self] pass, width, height in
            self?.drawFrame(pass: pass, width: width, height: height)
        }
        view.addSubview(surfaceView)
        self.surfaceView = surfaceView
        if bench {
            // Explicit-draw mode: ONLY the harness's manual draw() calls
            // render. A concurrent setNeedsDisplay-paced draw would present
            // the same drawable twice (CAMetalLayerDrawable is single-use).
            surfaceView.isPaused = true
            surfaceView.enableSetNeedsDisplay = false
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !started else {
            MetalWasmCell.shared?.core?.resize(width: Double(view.bounds.width), height: Double(view.bounds.height))
            return
        }
        started = true
        startReactor(width: Double(view.bounds.width), height: Double(view.bounds.height))
        if bench { benchStart() }
    }

    private func startReactor(width: Double, height: Double) {
        let cell = MetalWasmCell()
        MetalWasmCell.shared = cell

        // The runtime is only the layout/draw walker here (no native @main app
        // is installed); the tree comes from the reactor.
        Runtime.shared.start(host: renderer!, width: width, height: height)

        guard let url: FURL = Bundle.main.url(forResource: "tap_counter_release", withExtension: "wasm"),
            let bytes = try? [UInt8](Data(contentsOf: url))
        else {
            NSLog("[wasm] no packaged reactor")
            return
        }

        // WasmKit under the shared feature runtime, which pumps the reactor's
        // renders on the main queue. The reactor ships tree.fbs Patches — the
        // only wire format; the first render after start is a single
        // full-tree op at "n". Each buffer is queued in order (`pendingBytes`)
        // and applied on the next draw.
        let core = WasmFeatureRuntime(
            runtime: { _ in WasmKitRuntime() },
            log: { line in NSLog("%@", line) })
        core.onTree = { [weak self, weak cell] bytes in
            cell?.pendingBytes.append(bytes)
            self?.scheduleRender()
        }
        cell.core = core
        core.resize(width: width, height: height)
        core.load(bundle: WasmServiceBundle(label: "tap_counter_release", wasm: bytes))
        scheduleRender()
    }

    func scheduleRender() {
        surfaceView?.setNeedsRender()
    }

    private func drawFrame(pass: GPURenderPass, width: Double, height: Double) {
        guard let cell = MetalWasmCell.shared, let surface, let renderer else { return }
        if !cell.pendingBytes.isEmpty {
            let queued = cell.pendingBytes
            cell.pendingBytes = []
            for bytes in queued {
                cell.latestTree = cell.decoder.applyPatch(bytes: bytes, to: cell.latestTree)
            }
        }
        guard let tree = cell.latestTree else { return }
        surface.currentPass = pass
        renderer.beginFrame(width: width, height: height)
        renderer.render(tree: tree)
        renderer.endFrame()
        surface.currentPass = nil
    }

    // MARK: Touch → runtime (hit-tests the drawn tree's tap regions)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, kind: 0)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, kind: 2)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, kind: 1)
    }

    private func forward(_ touches: Set<UITouch>, kind: Int) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: view)
        Runtime.shared.pointerEvent(kind: kind, x: Double(point.x), y: Double(point.y))
        scheduleRender()
    }

    // MARK: Bench (manual-draw anchors; see the `bench` comment above)

    private func benchStart() {
        // A fresh run must never be confused with a previous launch's file.
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("bench.json"))
        }
        // The reactor started synchronously above and its first (full-tree)
        // patch is already pending: one manual draw = the first content frame,
        // encoded and committed when draw() returns.
        surfaceView?.draw()
        if let tree = MetalWasmCell.shared?.latestTree,
           findText(tree, prefix: "Tap me") != nil {
            benchStartupMs = Self.msSinceProcessStart()
            benchLastLabel = findText(tree, prefix: "Tapped") ?? ""
            NSLog("[bench] content draw committed sinceStart=%.0fms", benchStartupMs)
            benchScheduleTap(after: 1.0)
        } else {
            // Content not up yet (shouldn't happen — start is synchronous);
            // retry on the next turn.
            DispatchQueue.main.async { [weak self] in self?.benchStart() }
        }
    }

    private func benchScheduleTap(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.benchTap()
        }
    }

    private func benchTap() {
        guard benchTaps.count < 15,
              let tree = MetalWasmCell.shared?.latestTree,
              let frame = findFrame(tree, text: "Tap me")
        else { return }
        let t0 = CACurrentMediaTime()
        // The full tap path, synchronously: pointer event -> reactor ->
        // patch (on_tree appends inline) -> manual draw (decode + layout +
        // encode + command buffer commit).
        Runtime.shared.pointerEvent(kind: 0, x: frame.midX, y: frame.midY)
        Runtime.shared.pointerEvent(kind: 1, x: frame.midX, y: frame.midY)
        surfaceView?.draw()
        let label = MetalWasmCell.shared?.latestTree.flatMap { findText($0, prefix: "Tapped") } ?? ""
        if label != benchLastLabel {
            let ms = (CACurrentMediaTime() - t0) * 1000
            benchTaps.append(ms)
            benchLastLabel = label
            NSLog("[bench] tap #%d %.2fms (to draw-commit)", benchTaps.count, ms)
        } else {
            NSLog("[bench] tap missed (no label change after draw)")
        }
        if benchTaps.count >= 15 {
            benchFinish()
        } else {
            benchScheduleTap(after: 0.25 + Double.random(in: 0...0.05))
        }
    }

    private func benchFinish() {
        let sorted = benchTaps.sorted()
        let payload: [String: Any] = [
            "run": ProcessInfo.processInfo.environment["ISO_BENCH_RUN"] ?? "",
            "startupMs": benchStartupMs,
            "taps": benchTaps.map { (($0 * 100).rounded()) / 100 },
            "tapMedianMs": sorted.isEmpty ? -1 : ((sorted[sorted.count / 2] * 100).rounded()) / 100,
            "tapMeanMs": benchTaps.isEmpty ? -1 :
                (((benchTaps.reduce(0, +) / Double(benchTaps.count)) * 100).rounded()) / 100,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: dir.appendingPathComponent("bench.json"))
            NSLog("[bench] done: %@", String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func findText(_ node: RenderNode, prefix: String) -> String? {
        if case .text(let string) = node.kind, string.hasPrefix(prefix) { return string }
        for child in node.children {
            if let found = findText(child, prefix: prefix) { return found }
        }
        return nil
    }

    private func findFrame(_ node: RenderNode, text: String) -> CGRect? {
        if case .text(let string) = node.kind, string == text { return node.frame }
        for child in node.children {
            if let found = findFrame(child, text: text) { return found }
        }
        return nil
    }

    private static func msSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let startSec = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        // Foundation's Date, NOT the core module's calendar shim.
        return (Foundation.Date().timeIntervalSince1970 - startSec) * 1000
    }
}
