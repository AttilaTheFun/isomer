// ImageIO, the part of it an app uses to decode a picture off the main
// thread at the size it is drawn: `CGImageSourceCreateWithData`, its
// properties (pixel size, orientation), and `CGImageSourceCreateThumbnailAtIndex`.
// Apple's is used on Apple; this one stands in for it everywhere else, under
// the same names, so an app calls one API on every platform.
//
// A `CGImage` here is a handle to a bitmap the host decoded (Android: a
// Bitmap in its image cache, decoded on the calling thread; the web: the
// encoded bytes as a Blob, decoded by the browser). SwiftUI draws it by its
// `source`; the bitmap is freed when the last reference to the handle goes.

import Foundation
import Synchronization

// MARK: - Core Foundation names

/// The Core Foundation types ImageIO's signatures use, as the Swift types
/// they bridge to on Apple, so `data as CFData` and `options as CFDictionary`
/// read the same here.
public typealias CFData = Data
public typealias CFString = String
public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = Any

// MARK: - CGImage

/// A decoded picture, `width` × `height` pixels, upright.
public final class CGImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// What the host draws it by (an `isomer-image://` URL).
    public let _source: String
    /// The encoded bytes, while no host has taken them (a host that can't
    /// decode off the main thread takes them at the first draw).
    public let _pendingBytes: [UInt8]?

    init(width: Int, height: Int, source: String, pendingBytes: [UInt8]?) {
        self.width = width
        self.height = height
        self._source = source
        self._pendingBytes = pendingBytes
    }

    deinit {
        _ImageIOHost.release?(_source)
    }
}

/// How ImageIO reaches the host (installed by the portable SwiftUI at start).
public enum _ImageIOHost {
    /// Decode `bytes` for `source`, no larger than `maxPixelSize` on its
    /// longest side (0: whole), turned upright when `transform`; returns the
    /// decoded size, or nil when this host decodes at the first draw.
    /// Called on whatever thread asked for the thumbnail.
    nonisolated(unsafe) public static var decode: (@Sendable (_ source: String, _ bytes: [UInt8], _ maxPixelSize: Int, _ transform: Bool) -> (width: Int, height: Int)?)?
    /// Forget what was decoded for `source`.
    nonisolated(unsafe) public static var release: (@Sendable (_ source: String) -> Void)?

    private static let counter = Atomic<Int>(0)

    static func nextSource() -> String {
        "isomer-image://cg-\(counter.add(1, ordering: .relaxed).newValue)"
    }
}

// MARK: - Image sources

/// Encoded picture bytes and what their header says.
public final class CGImageSource: @unchecked Sendable {
    let bytes: [UInt8]
    let header: _ImageHeader?

    init(bytes: [UInt8]) {
        self.bytes = bytes
        self.header = _ImageHeader(bytes)
    }
}

public let kCGImagePropertyPixelWidth: CFString = "PixelWidth"
public let kCGImagePropertyPixelHeight: CFString = "PixelHeight"
public let kCGImagePropertyOrientation: CFString = "Orientation"
public let kCGImageSourceCreateThumbnailFromImageAlways: CFString = "kCGImageSourceCreateThumbnailFromImageAlways"
public let kCGImageSourceCreateThumbnailFromImageIfAbsent: CFString = "kCGImageSourceCreateThumbnailFromImageIfAbsent"
public let kCGImageSourceThumbnailMaxPixelSize: CFString = "kCGImageSourceThumbnailMaxPixelSize"
public let kCGImageSourceCreateThumbnailWithTransform: CFString = "kCGImageSourceCreateThumbnailWithTransform"
public let kCGImageSourceShouldCacheImmediately: CFString = "kCGImageSourceShouldCacheImmediately"
public let kCGImageSourceShouldCache: CFString = "kCGImageSourceShouldCache"

/// A source over encoded bytes (PNG, JPEG, GIF, WebP); nil when they are
/// no picture this can read the size of.
public func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource? {
    let source = CGImageSource(bytes: [UInt8](data))
    return source.header == nil ? nil : source
}

/// The number of pictures in the source (one: animation frames are not read).
public func CGImageSourceGetCount(_ source: CGImageSource) -> Int { 1 }

/// The picture's pixel size and orientation (EXIF, 1–8), as stored.
public func CGImageSourceCopyPropertiesAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CFDictionary? {
    guard index == 0, let header = source.header else { return nil }
    return [
        kCGImagePropertyPixelWidth: header.width,
        kCGImagePropertyPixelHeight: header.height,
        kCGImagePropertyOrientation: header.orientation,
    ]
}

/// The picture decoded, no larger than `kCGImageSourceThumbnailMaxPixelSize`
/// on its longest side, turned upright with
/// `kCGImageSourceCreateThumbnailWithTransform`. Decoded now, on this thread,
/// where the host can (call it off the main thread).
public func CGImageSourceCreateThumbnailAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard index == 0, let header = source.header else { return nil }
    let options = options ?? [:]
    let transform = (options[kCGImageSourceCreateThumbnailWithTransform] as? Bool) ?? false
    let maxPixelSize = _intValue(options[kCGImageSourceThumbnailMaxPixelSize]) ?? 0
    return _makeImage(source.bytes, header: header, maxPixelSize: maxPixelSize, transform: transform)
}

/// The whole picture, decoded (stored orientation).
public func CGImageSourceCreateImageAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard index == 0, let header = source.header else { return nil }
    return _makeImage(source.bytes, header: header, maxPixelSize: 0, transform: false)
}

func _makeImage(_ bytes: [UInt8], header: _ImageHeader, maxPixelSize: Int, transform: Bool) -> CGImage? {
    let source = _ImageIOHost.nextSource()
    if let decode = _ImageIOHost.decode, let size = decode(source, bytes, maxPixelSize, transform) {
        return CGImage(width: size.width, height: size.height, source: source, pendingBytes: nil)
    }
    // Decoded by the host at the first draw: its size is the one asked for.
    let turned = transform && header.orientation >= 5
    var width = turned ? header.height : header.width
    var height = turned ? header.width : header.height
    let longest = max(width, height)
    if maxPixelSize > 0, longest > maxPixelSize {
        width = max(1, width * maxPixelSize / longest)
        height = max(1, height * maxPixelSize / longest)
    }
    return CGImage(width: width, height: height, source: source, pendingBytes: bytes)
}

func _intValue(_ value: Any?) -> Int? {
    switch value {
    case let v as Int: return v
    case let v as Double: return Int(v.rounded(.up))
    case let v as Float: return Int(v.rounded(.up))
    case let v as UInt32: return Int(v)
    case let v as Int64: return Int(v)
    default: return nil
    }
}

// MARK: - Headers

/// A picture's pixel size and EXIF orientation, read from its header.
struct _ImageHeader {
    let width: Int
    let height: Int
    let orientation: Int

    init?(_ b: [UInt8]) {
        func be16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
        func be32(_ i: Int) -> Int { i + 3 < b.count ? be16(i) << 16 | be16(i + 2) : 0 }
        func le16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func le24(_ i: Int) -> Int { i + 2 < b.count ? le16(i) | Int(b[i + 2]) << 16 : 0 }
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            // PNG: IHDR is the first chunk.
            width = be32(16); height = be32(20); orientation = 1
        } else if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 {
            // JPEG: the first start-of-frame marker, and EXIF's orientation.
            var i = 2
            var size: (Int, Int)?
            var turn = 1
            while i + 4 <= b.count, size == nil {
                guard b[i] == 0xFF else { i += 1; continue }
                let marker = b[i + 1]
                if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { i += 2; continue }
                let length = be16(i + 2)
                if marker == 0xE1, let exif = _ImageHeader.exifOrientation(b, start: i + 4, end: i + 2 + length) { turn = exif }
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    size = (be16(i + 7), be16(i + 5))
                }
                i += 2 + length
            }
            guard let size else { return nil }
            width = size.0; height = size.1; orientation = turn
        } else if b.count >= 10, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 {
            // GIF: the logical screen.
            width = le16(6); height = le16(8); orientation = 1
        } else if b.count >= 30, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
                  b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            // WebP: lossy, lossless or extended.
            switch (b[12], b[13], b[14], b[15]) {
            case (0x56, 0x50, 0x38, 0x20): // "VP8 "
                width = le16(26) & 0x3FFF; height = le16(28) & 0x3FFF
            case (0x56, 0x50, 0x38, 0x4C): // "VP8L"
                let bits = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
                width = (bits & 0x3FFF) + 1; height = ((bits >> 14) & 0x3FFF) + 1
            case (0x56, 0x50, 0x38, 0x58): // "VP8X"
                width = le24(24) + 1; height = le24(27) + 1
            default:
                return nil
            }
            orientation = 1
        } else {
            return nil
        }
        guard width > 0, height > 0 else { return nil }
    }

    /// The orientation tag (0x0112) of an APP1 "Exif" segment.
    static func exifOrientation(_ b: [UInt8], start: Int, end: Int) -> Int? {
        guard end <= b.count, start + 14 <= end,
              b[start] == 0x45, b[start + 1] == 0x78, b[start + 2] == 0x69, b[start + 3] == 0x66 else { return nil }
        let tiff = start + 6
        let little = b[tiff] == 0x49
        func u16(_ i: Int) -> Int {
            guard i + 1 < end else { return 0 }
            return little ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1])
        }
        func u32(_ i: Int) -> Int { little ? u16(i) | u16(i + 2) << 16 : u16(i) << 16 | u16(i + 2) }
        let ifd = tiff + u32(tiff + 4)
        let count = u16(ifd)
        for entry in 0..<count {
            let at = ifd + 2 + entry * 12
            guard at + 12 <= end else { break }
            if u16(at) == 0x0112 {
                let value = u16(at + 8)
                return (1...8).contains(value) ? value : nil
            }
        }
        return nil
    }
}
