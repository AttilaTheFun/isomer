// Isomer's CoreGraphics: CGColor and CGColorSpace, as far as they go without
// CoreFoundation (no CFString color space names, no CFDictionary options, no
// ICC data) and without color management (a color keeps the components it
// was made with; `converted(to:)` is not provided). docs/parity/CoreGraphics.md
// lists what is left out and why.

#if ISOMER_CORELIBS_FOUNDATION
// Linux and Windows: CGFloat, CGPoint, CGSize and CGRect are
// swift-corelibs-foundation's; this module adds the rest.
import Foundation
#endif

/// A color space's family.
@frozen
public enum CGColorSpaceModel: Int32, Sendable {
    case unknown = -1
    case monochrome = 0
    case rgb = 1
    case cmyk = 2
    case lab = 3
    case deviceN = 4
    case indexed = 5
    case pattern = 6
    case XYZ = 7
}

/// How out-of-gamut colors are mapped when a color is converted.
@frozen
public enum CGColorRenderingIntent: Int32, Sendable {
    case defaultIntent = 0
    case absoluteColorimetric = 1
    case relativeColorimetric = 2
    case perceptual = 3
    case saturation = 4
}

/// A color space: the device and generic spaces, sRGB and Display P3.
public final class CGColorSpace: Hashable, @unchecked Sendable {
    /// Which space, for equality and for hosts that draw the color.
    enum Identity: Hashable, Sendable {
        case deviceRGB
        case deviceGray
        case deviceCMYK
        case genericGrayGamma2_2
        case genericCMYK
        case sRGB
        case displayP3
    }

    let identity: Identity

    init(_ identity: Identity) {
        self.identity = identity
    }

    public var model: CGColorSpaceModel {
        switch identity {
        case .deviceRGB, .sRGB, .displayP3: return .rgb
        case .deviceGray, .genericGrayGamma2_2: return .monochrome
        case .deviceCMYK, .genericCMYK: return .cmyk
        }
    }

    /// The color components a color in this space has, alpha not counted.
    public var numberOfComponents: Int {
        switch model {
        case .monochrome: return 1
        case .cmyk: return 4
        default: return 3
        }
    }

    public var baseColorSpace: CGColorSpace? { nil }

    public var isWideGamutRGB: Bool { identity == .displayP3 }

    public func isHDR() -> Bool { false }

    public var supportsOutput: Bool { true }

    public static func == (lhs: CGColorSpace, rhs: CGColorSpace) -> Bool {
        lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    static let sharedDeviceRGB = CGColorSpace(.deviceRGB)
    static let sharedDeviceGray = CGColorSpace(.deviceGray)
    static let sharedDeviceCMYK = CGColorSpace(.deviceCMYK)
    static let sharedGenericGray = CGColorSpace(.genericGrayGamma2_2)
    static let sharedGenericCMYK = CGColorSpace(.genericCMYK)
    static let sharedSRGB = CGColorSpace(.sRGB)
}

public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { .sharedDeviceRGB }

public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { .sharedDeviceGray }

public func CGColorSpaceCreateDeviceCMYK() -> CGColorSpace { .sharedDeviceCMYK }

/// A color: components in a color space, alpha last.
public final class CGColor: Hashable, @unchecked Sendable {
    private let space: CGColorSpace
    private let storage: [CGFloat]

    init(space: CGColorSpace, components: [CGFloat]) {
        self.space = space
        self.storage = components
    }

    /// A color from `space.numberOfComponents` components and alpha, or nil
    /// when the space is a pattern space.
    public init?(colorSpace space: CGColorSpace, components: UnsafePointer<CGFloat>) {
        guard space.model != .pattern, space.model != .unknown else { return nil }
        self.space = space
        self.storage = Array(UnsafeBufferPointer(start: components, count: space.numberOfComponents + 1))
    }

    public convenience init(gray: CGFloat, alpha: CGFloat) {
        self.init(space: .sharedDeviceGray, components: [gray, alpha])
    }

    public convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(space: .sharedDeviceRGB, components: [red, green, blue, alpha])
    }

    public convenience init(
        genericCMYKCyan cyan: CGFloat, magenta: CGFloat, yellow: CGFloat, black: CGFloat, alpha: CGFloat
    ) {
        self.init(space: .sharedGenericCMYK, components: [cyan, magenta, yellow, black, alpha])
    }

    public convenience init(genericGrayGamma2_2Gray gray: CGFloat, alpha: CGFloat) {
        self.init(space: .sharedGenericGray, components: [gray, alpha])
    }

    public convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(space: .sharedSRGB, components: [red, green, blue, alpha])
    }

    /// The components, alpha last.
    public var components: [CGFloat]? { storage }

    /// How many components, alpha included.
    public var numberOfComponents: Int { storage.count }

    public var alpha: CGFloat { storage.last ?? 1 }

    public var colorSpace: CGColorSpace? { space }

    /// Standard dynamic range: content headroom 1.
    public var contentHeadroom: Float { 1 }

    public func copy() -> CGColor? {
        CGColor(space: space, components: storage)
    }

    public func copy(alpha: CGFloat) -> CGColor? {
        var components = storage
        if components.isEmpty { return nil }
        components[components.count - 1] = alpha
        return CGColor(space: space, components: components)
    }

    public static func == (lhs: CGColor, rhs: CGColor) -> Bool {
        lhs.space == rhs.space && lhs.storage == rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(space)
        hasher.combine(storage)
    }
}

extension CGColor {
    /// The color's red, green, blue and alpha in sRGB, for a host that draws
    /// it: device RGB is taken as sRGB, gray is spread over the three
    /// channels, CMYK is converted naively. Isomer's, not Apple's.
    var sRGBAComponents: (red: Double, green: Double, blue: Double, alpha: Double) {
        let c = storage.map(\.native)
        switch space.model {
        case .monochrome where c.count >= 2:
            return (c[0], c[0], c[0], c[1])
        case .cmyk where c.count >= 5:
            let k = 1 - c[3]
            return ((1 - c[0]) * k, (1 - c[1]) * k, (1 - c[2]) * k, c[4])
        default:
            guard c.count >= 4 else { return (0, 0, 0, 1) }
            return (c[0], c[1], c[2], c[3])
        }
    }
}
