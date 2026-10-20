// `Image(_ cgImage:…)` over the portable ImageIO (//shared/image_io): a
// picture decoded off the main thread, drawn here by its handle. On an Apple
// platform (an app compiled against Isomer's frameworks there, the cores
// hosted on a Mac) Apple's CGImage, encoded once as PNG and handed to the
// host as a portable one is.

#if canImport(ImageIO) && !canImport(Darwin)
import ImageIO

extension CGImage: _PendingImageBytes {}

extension Image {
    /// A decoded picture, `scale` device pixels per point.
    public init(_ cgImage: CGImage, scale: CGFloat, orientation: Orientation = .up, label: Text) {
        self.init(remote: cgImage._source)
        handle = cgImage
    }

    /// A decoded picture that says nothing to assistive technology.
    public init(decorative cgImage: CGImage, scale: CGFloat, orientation: Orientation = .up) {
        self.init(remote: cgImage._source)
        handle = cgImage
    }
}
#endif

#if canImport(Darwin) && canImport(ImageIO)
import Foundation
import ImageIO

/// An Apple CGImage as the host draws it: by a source of its own, its PNG
/// handed over at the first draw. The same image keeps its source while it
/// is among the last few hundred drawn (held here, so its address names no
/// other image meanwhile).
final class _AppleImageBytes: _PendingImageBytes, @unchecked Sendable {
    let image: CGImage
    let _source: String
    private(set) lazy var _pendingBytes: [UInt8]? = Self.png(image)

    private init(image: CGImage, source: String) {
        self.image = image
        _source = source
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [ObjectIdentifier: _AppleImageBytes] = [:]
    nonisolated(unsafe) private static var order: [ObjectIdentifier] = []
    nonisolated(unsafe) private static var counter = 0

    static func of(_ image: CGImage) -> _AppleImageBytes {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(image)
        if let held = known[id] { return held }
        counter += 1
        let made = _AppleImageBytes(image: image, source: "isomer-image://apple-cg-\(counter)")
        known[id] = made
        order.append(id)
        if order.count > 256 { known[order.removeFirst()] = nil }
        return made
    }

    private static func png(_ image: CGImage) -> [UInt8]? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return [UInt8](data as Data)
    }
}

extension Image {
    /// A decoded picture, `scale` device pixels per point.
    public init(_ cgImage: CGImage, scale: CGFloat, orientation: Image.Orientation = .up, label: Text) {
        let bytes = _AppleImageBytes.of(cgImage)
        self.init(remote: bytes._source)
        handle = bytes
    }

    /// A decoded picture that says nothing to assistive technology.
    public init(decorative cgImage: CGImage, scale: CGFloat, orientation: Image.Orientation = .up) {
        let bytes = _AppleImageBytes.of(cgImage)
        self.init(remote: bytes._source)
        handle = bytes
    }
}
#endif
