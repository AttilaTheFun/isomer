// The imperative SwiftMap entry point on Apple platforms: a plain
// NSView/UIView hosting a SwiftGPU render surface — used like an MKMapView
// (create it, set `camera`, add to the hierarchy). Event-driven: it draws
// only when the engine invalidates (gesture, tile arrival, camera set).
// No graphics API appears here: rendering goes through SwiftGPU's
// MetalGPUDevice and the shared MapSceneRenderer.

// canImport: the XCFramework distribution compiles SwiftGPU's sources into
// this module (apple_xcframework forbids transitive swift_library deps).
#if canImport(SwiftGPU)
import SwiftGPU
#endif

#if canImport(AppKit)
import AppKit
public typealias MapViewSuperclass = NSView
#else
import UIKit
public typealias MapViewSuperclass = UIView
#endif

public final class MapView: MapViewSuperclass {
    public let engine: MapEngine
    private let device: MetalGPUDevice
    private let scene: MapSceneRenderer
    private let surface: GPUSurfaceView
    private let fetcher: TileFetcher
    private let hostAdapter = HostAdapter()
    private let attributionLabel: PlatformLabel
    private let calloutLabel: PlatformLabel

    public var camera: MapCamera {
        get { engine.camera }
        set { engine.camera = newValue }
    }

    /// Billboarded point markers (screen-sized, upright under bearing/tilt).
    public var annotations: [MapAnnotation] {
        get { engine.annotations }
        set { engine.annotations = newValue }
    }

    /// Map-plane polygons (filled + optionally stroked).
    public var polygons: [MapPolygon] {
        get { engine.polygons }
        set { engine.polygons = newValue }
    }

    /// Map-plane open paths (round joints/caps).
    public var polylines: [MapPolyline] {
        get { engine.polylines }
        set { engine.polylines = newValue }
    }

    /// Called when a tap/click lands on an annotation marker. The built-in
    /// callout (the annotation's `title`) toggles independently.
    public var onAnnotationTap: ((MapAnnotation) -> Void)?
    private var selectedAnnotationID: String?

    fileprivate func handleTap(atX x: Double, y: Double) {
        if let annotation = engine.annotation(atScreenX: x, y: y) {
            selectedAnnotationID = selectedAnnotationID == annotation.id ? nil : annotation.id
            onAnnotationTap?(annotation)
        } else {
            selectedAnnotationID = nil
        }
        scheduleRedraw()
    }

    /// Observe camera changes (gestures and programmatic). Delivered
    /// asynchronously on the main queue, coalesced per runloop turn, so a
    /// SwiftUI binding can be updated from it without re-entering a view
    /// update.
    public var onCameraChange: ((MapCamera) -> Void)?
    private var lastNotifiedCamera: MapCamera?
    private var cameraNotificationScheduled = false

    private func scheduleCameraNotification() {
        guard onCameraChange != nil, !cameraNotificationScheduled else { return }
        cameraNotificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cameraNotificationScheduled = false
            let camera = self.engine.camera
            if camera != self.lastNotifiedCamera {
                self.lastNotifiedCamera = camera
                self.onCameraChange?(camera)
            }
        }
    }

    public init(
        frame frameRect: CGRect = .zero,
        configuration: MapConfiguration = .openStreetMap,
        fetcher: TileFetcher = FoundationTileFetcher()
    ) {
        guard let gpuDevice = MetalGPUDevice() else {
            fatalError("SwiftMap requires a GPU device")
        }
        engine = MapEngine(configuration: configuration)
        device = gpuDevice
        scene = MapSceneRenderer(device: gpuDevice)
        surface = gpuDevice.makeSurfaceView()
        self.fetcher = fetcher
        attributionLabel = Self.makeAttributionLabel(text: configuration.attribution)
        calloutLabel = Self.makeCalloutLabel()
        super.init(frame: frameRect)

        surface.clear = MapSceneRenderer.clearColor
        surface.frame = bounds
        #if canImport(AppKit)
        surface.autoresizingMask = [.width, .height]
        #else
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Touches belong to the MapView (gestures + annotation taps).
        surface.isUserInteractionEnabled = false
        #endif
        // Event-driven drawing: no frame loop; the engine invalidates.
        surface.onDraw = { [weak self] pass, width, height in
            self?.renderFrame(into: pass, width: width, height: height)
        }
        addSubview(surface)

        hostAdapter.view = self
        engine.host = hostAdapter

        addSubview(attributionLabel)
        addSubview(calloutLabel)
        installGestures()
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Drawing

    private func renderFrame(into pass: GPURenderPass, width: Double, height: Double) {
        engine.resize(width: width, height: height)
        let frame = engine.buildFrame()
        scene.draw(frame: frame, into: pass)
        updateCallout(frame: frame)
    }

    // The selected annotation's callout: a native-text bubble above the
    // marker, repositioned every frame from the projected anchor.
    private func updateCallout(frame: MapFrame) {
        guard let id = selectedAnnotationID,
              let anchor = frame.annotationAnchors.first(where: { $0.id == id }),
              !anchor.title.isEmpty else {
            calloutLabel.isHidden = true
            return
        }
        setLabelText(calloutLabel, anchor.title)
        var size = labelFitSize(calloutLabel)
        size.width += 16
        size.height += 8
        let radius = engine.annotations.first(where: { $0.id == id })?.radius ?? 8
        calloutLabel.frame = CGRect(
            x: anchor.x - size.width / 2,
            y: anchor.y - radius - 6 - size.height,
            width: size.width,
            height: size.height
        )
        calloutLabel.isHidden = false
    }

    fileprivate func scheduleRedraw() {
        surface.setNeedsRender()
        scheduleCameraNotification()
    }

    fileprivate func fetchTile(key: TileKey, url: String) {
        fetcher.fetch(url: url) { [weak self] bytes in
            // Decode off-main (whatever thread the fetcher used), then hop
            // to the main queue for the scene/engine.
            let decoded = bytes.flatMap { TileDecoder.decodeRGBA($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let decoded {
                    self.scene.setTexture(
                        rgba: decoded.rgba,
                        width: decoded.width,
                        height: decoded.height,
                        forKey: key.id
                    )
                    self.engine.tileLoaded(key: key)
                } else {
                    self.engine.tileFailed(key: key)
                }
            }
        }
    }

    fileprivate func evictTile(key: TileKey) {
        scene.removeTexture(forKey: key.id)
    }

    // MARK: - Attribution (required for OpenStreetMap data — ODbL)

    #if canImport(AppKit)
    private typealias PlatformLabel = NSTextField
    #else
    private typealias PlatformLabel = UILabel
    #endif

    private static func makeAttributionLabel(text: String) -> PlatformLabel {
        #if canImport(AppKit)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9)
        label.textColor = .secondaryLabelColor
        label.backgroundColor = NSColor.white.withAlphaComponent(0.7)
        label.drawsBackground = !text.isEmpty
        label.sizeToFit()
        #else
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 9)
        label.textColor = .secondaryLabel
        label.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        label.sizeToFit()
        #endif
        return label
    }

    private func layoutAttribution() {
        let size = attributionLabel.frame.size
        attributionLabel.frame = CGRect(
            x: bounds.width - size.width - 4,
            y: bounds.height - size.height - 4,
            width: size.width,
            height: size.height
        )
    }

    private static func makeCalloutLabel() -> PlatformLabel {
        #if canImport(AppKit)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.textColor = .black
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        label.layer?.cornerRadius = 6
        label.layer?.borderWidth = 0.5
        label.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
        #else
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        label.textColor = .black
        label.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        label.layer.cornerRadius = 6
        label.layer.borderWidth = 0.5
        label.layer.borderColor = UIColor.black.withAlphaComponent(0.2).cgColor
        label.clipsToBounds = true
        #endif
        label.isHidden = true
        return label
    }

    private func setLabelText(_ label: PlatformLabel, _ text: String) {
        #if canImport(AppKit)
        label.stringValue = text
        #else
        label.text = text
        #endif
    }

    private func labelFitSize(_ label: PlatformLabel) -> CGSize {
        #if canImport(AppKit)
        return label.fittingSize
        #else
        return label.sizeThatFits(CGSize(width: 320, height: 100))
        #endif
    }

    // MARK: - Gestures

    #if canImport(AppKit)

    // Top-left origin so view coordinates match the engine's screen space.
    public override var isFlipped: Bool { true }

    // Mouse events belong to the MapView, not the render surface.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === surface ? self : view
    }

    public override func layout() {
        super.layout()
        layoutAttribution()
    }

    private func installGestures() {
        let magnification = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:)))
        addGestureRecognizer(magnification)
        let rotation = NSRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        addGestureRecognizer(rotation)
    }

    @objc private func handleRotation(_ recognizer: NSRotationGestureRecognizer) {
        // Two-finger twist; AppKit reports counterclockwise-positive radians.
        let degrees = Double(recognizer.rotation) * 180 / .pi
        recognizer.rotation = 0
        engine.rotate(by: degrees)
    }

    private var mouseDownPoint: CGPoint?
    private var mouseMoved = false

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            engine.zoom(by: 1, anchorX: Double(point.x), anchorY: Double(point.y))
            return
        }
        mouseDownPoint = point
        mouseMoved = false
        engine.pointer(phase: 0, x: Double(point.x), y: Double(point.y))
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = mouseDownPoint, abs(point.x - start.x) + abs(point.y - start.y) > 3 {
            mouseMoved = true
        }
        engine.pointer(phase: 1, x: Double(point.x), y: Double(point.y))
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        engine.pointer(phase: 2, x: Double(point.x), y: Double(point.y))
        // A click that never dragged is a tap: annotation hit-test.
        if event.clickCount == 1 && !mouseMoved {
            handleTap(atX: Double(point.x), y: Double(point.y))
        }
        mouseDownPoint = nil
    }

    public override func scrollWheel(with event: NSEvent) {
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        engine.pan(
            deltaX: Double(event.scrollingDeltaX) * factor,
            deltaY: Double(event.scrollingDeltaY) * factor
        )
    }

    @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
        let point = recognizer.location(in: self)
        let delta = log2(1 + Double(recognizer.magnification))
        recognizer.magnification = 0
        engine.zoom(by: delta, anchorX: Double(point.x), anchorY: Double(point.y))
    }

    #else

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutAttribution()
    }

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotation.delegate = self
        addGestureRecognizer(rotation)
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        handleTap(atX: Double(point.x), y: Double(point.y))
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        // Two-finger twist; UIKit reports clockwise-positive radians.
        let degrees = -Double(recognizer.rotation) * 180 / .pi
        recognizer.rotation = 0
        engine.rotate(by: degrees)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        engine.pan(deltaX: Double(translation.x), deltaY: Double(translation.y))
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let point = recognizer.location(in: self)
        let delta = log2(Double(recognizer.scale))
        recognizer.scale = 1
        engine.zoom(by: delta, anchorX: Double(point.x), anchorY: Double(point.y))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        engine.zoom(by: 1, anchorX: Double(point.x), anchorY: Double(point.y))
    }

    #endif
}

#if canImport(UIKit)
extension MapView: UIGestureRecognizerDelegate {
    // Pan + pinch together, like every map app.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif

/// The engine's platform half, kept out of the (main-actor) view class so
/// the conformance stays nonisolated; every call happens on the main thread.
private final class HostAdapter: MapEngineHost {
    weak var view: MapView?

    func requestTile(key: TileKey, url: String) {
        view?.fetchTile(key: key, url: url)
    }

    func evictTile(key: TileKey) {
        view?.evictTile(key: key)
    }

    func setNeedsRender() {
        view?.scheduleRedraw()
    }
}
