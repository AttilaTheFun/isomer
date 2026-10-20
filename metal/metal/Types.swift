// Metal's value types: sizes, origins, regions, clear colors, viewports and
// scissor rectangles, with their make functions. C structs in Apple's Metal:
// neither Equatable nor Hashable.

/// CoreFoundation's time interval, which Metal's command buffers and
/// drawables report times in (seconds).
public typealias CFTimeInterval = Double

public struct MTLSize: Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int

    public init() {
        width = 0
        height = 0
        depth = 0
    }

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }
}

public struct MTLOrigin: Sendable {
    public var x: Int
    public var y: Int
    public var z: Int

    public init() {
        x = 0
        y = 0
        z = 0
    }

    public init(x: Int, y: Int, z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct MTLRegion: Sendable {
    public var origin: MTLOrigin
    public var size: MTLSize

    public init() {
        origin = MTLOrigin()
        size = MTLSize()
    }

    public init(origin: MTLOrigin, size: MTLSize) {
        self.origin = origin
        self.size = size
    }
}

public struct MTLClearColor: Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init() {
        red = 0
        green = 0
        blue = 0
        alpha = 0
    }

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct MTLViewport: Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double
    public var znear: Double
    public var zfar: Double

    public init() {
        originX = 0
        originY = 0
        width = 0
        height = 0
        znear = 0
        zfar = 0
    }

    public init(originX: Double, originY: Double, width: Double, height: Double, znear: Double, zfar: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.znear = znear
        self.zfar = zfar
    }
}

public struct MTLScissorRect: Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init() {
        x = 0
        y = 0
        width = 0
        height = 0
    }

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct MTLSizeAndAlign: Sendable {
    public var size: Int
    public var align: Int

    public init() {
        size = 0
        align = 0
    }

    public init(size: Int, align: Int) {
        self.size = size
        self.align = align
    }
}

public func MTLOriginMake(_ x: Int, _ y: Int, _ z: Int) -> MTLOrigin {
    MTLOrigin(x: x, y: y, z: z)
}

public func MTLSizeMake(_ width: Int, _ height: Int, _ depth: Int) -> MTLSize {
    MTLSize(width: width, height: height, depth: depth)
}

public func MTLRegionMake1D(_ x: Int, _ width: Int) -> MTLRegion {
    MTLRegion(origin: MTLOrigin(x: x, y: 0, z: 0), size: MTLSize(width: width, height: 1, depth: 1))
}

public func MTLRegionMake2D(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> MTLRegion {
    MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0), size: MTLSize(width: width, height: height, depth: 1))
}

public func MTLRegionMake3D(_ x: Int, _ y: Int, _ z: Int, _ width: Int, _ height: Int, _ depth: Int) -> MTLRegion {
    MTLRegion(origin: MTLOrigin(x: x, y: y, z: z), size: MTLSize(width: width, height: height, depth: depth))
}

public func MTLClearColorMake(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> MTLClearColor {
    MTLClearColor(red: red, green: green, blue: blue, alpha: alpha)
}
