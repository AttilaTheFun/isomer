// Metal's enumerations and option sets, with Apple's raw values (a stream's
// commands carry them as they are). Cases the backends cannot do are not
// here (docs/parity/Metal.md lists them): the compressed pixel formats,
// the YUV and extended-range ones, tessellation's step functions.

public enum MTLPixelFormat: UInt, Sendable {
    case invalid = 0
    case a8Unorm = 1
    case r8Unorm = 10
    case r8Unorm_srgb = 11
    case r8Snorm = 12
    case r8Uint = 13
    case r8Sint = 14
    case r16Unorm = 20
    case r16Snorm = 22
    case r16Uint = 23
    case r16Sint = 24
    case r16Float = 25
    case rg8Unorm = 30
    case rg8Unorm_srgb = 31
    case rg8Snorm = 32
    case rg8Uint = 33
    case rg8Sint = 34
    case b5g6r5Unorm = 40
    case a1bgr5Unorm = 41
    case abgr4Unorm = 42
    case bgr5A1Unorm = 43
    case r32Uint = 53
    case r32Sint = 54
    case r32Float = 55
    case rg16Unorm = 60
    case rg16Snorm = 62
    case rg16Uint = 63
    case rg16Sint = 64
    case rg16Float = 65
    case rgba8Unorm = 70
    case rgba8Unorm_srgb = 71
    case rgba8Snorm = 72
    case rgba8Uint = 73
    case rgba8Sint = 74
    case bgra8Unorm = 80
    case bgra8Unorm_srgb = 81
    case rgb10a2Unorm = 90
    case rgb10a2Uint = 91
    case rg11b10Float = 92
    case rgb9e5Float = 93
    case bgr10a2Unorm = 94
    case rg32Uint = 103
    case rg32Sint = 104
    case rg32Float = 105
    case rgba16Unorm = 110
    case rgba16Snorm = 112
    case rgba16Uint = 113
    case rgba16Sint = 114
    case rgba16Float = 115
    case rgba32Uint = 123
    case rgba32Sint = 124
    case rgba32Float = 125
    case depth16Unorm = 250
    case depth32Float = 252
    case stencil8 = 253
    case depth24Unorm_stencil8 = 255
    case depth32Float_stencil8 = 260
    case x32_stencil8 = 261
    case x24_stencil8 = 262
}

extension MTLPixelFormat {
    /// Bytes per pixel, for uploads and readbacks (0 for depth and stencil
    /// formats, which have no CPU layout here).
    var bytesPerPixel: Int {
        switch self {
        case .a8Unorm, .r8Unorm, .r8Unorm_srgb, .r8Snorm, .r8Uint, .r8Sint, .stencil8: return 1
        case .r16Unorm, .r16Snorm, .r16Uint, .r16Sint, .r16Float, .rg8Unorm, .rg8Unorm_srgb, .rg8Snorm,
             .rg8Uint, .rg8Sint, .b5g6r5Unorm, .a1bgr5Unorm, .abgr4Unorm, .bgr5A1Unorm, .depth16Unorm:
            return 2
        case .r32Uint, .r32Sint, .r32Float, .rg16Unorm, .rg16Snorm, .rg16Uint, .rg16Sint, .rg16Float,
             .rgba8Unorm, .rgba8Unorm_srgb, .rgba8Snorm, .rgba8Uint, .rgba8Sint, .bgra8Unorm, .bgra8Unorm_srgb,
             .rgb10a2Unorm, .rgb10a2Uint, .rg11b10Float, .rgb9e5Float, .bgr10a2Unorm, .depth32Float:
            return 4
        case .rg32Uint, .rg32Sint, .rg32Float, .rgba16Unorm, .rgba16Snorm, .rgba16Uint, .rgba16Sint, .rgba16Float:
            return 8
        case .rgba32Uint, .rgba32Sint, .rgba32Float: return 16
        default: return 0
        }
    }

    var isDepthOrStencil: Bool {
        rawValue >= 250
    }
}

public enum MTLPrimitiveType: UInt, Sendable {
    case point = 0
    case line = 1
    case lineStrip = 2
    case triangle = 3
    case triangleStrip = 4
}

public enum MTLPrimitiveTopologyClass: UInt, Sendable {
    case unspecified = 0
    case point = 1
    case line = 2
    case triangle = 3
}

public enum MTLIndexType: UInt, Sendable {
    case uint16 = 0
    case uint32 = 1
}

public enum MTLLoadAction: UInt, Sendable {
    case dontCare = 0
    case load = 1
    case clear = 2
}

public enum MTLStoreAction: UInt, Sendable {
    case dontCare = 0
    case store = 1
    case multisampleResolve = 2
    case storeAndMultisampleResolve = 3
    case unknown = 4
    case customSampleDepthStore = 5
}

public struct MTLStoreActionOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let customSamplePositions = MTLStoreActionOptions(rawValue: 1)
}

public enum MTLBlendFactor: UInt, Sendable {
    case zero = 0
    case one = 1
    case sourceColor = 2
    case oneMinusSourceColor = 3
    case sourceAlpha = 4
    case oneMinusSourceAlpha = 5
    case destinationColor = 6
    case oneMinusDestinationColor = 7
    case destinationAlpha = 8
    case oneMinusDestinationAlpha = 9
    case sourceAlphaSaturated = 10
    case blendColor = 11
    case oneMinusBlendColor = 12
    case blendAlpha = 13
    case oneMinusBlendAlpha = 14
    case source1Color = 15
    case oneMinusSource1Color = 16
    case source1Alpha = 17
    case oneMinusSource1Alpha = 18
}

public enum MTLBlendOperation: UInt, Sendable {
    case add = 0
    case subtract = 1
    case reverseSubtract = 2
    case min = 3
    case max = 4
}

public struct MTLColorWriteMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let red = MTLColorWriteMask(rawValue: 0x1 << 3)
    public static let green = MTLColorWriteMask(rawValue: 0x1 << 2)
    public static let blue = MTLColorWriteMask(rawValue: 0x1 << 1)
    public static let alpha = MTLColorWriteMask(rawValue: 0x1 << 0)
    public static let all = MTLColorWriteMask(rawValue: 0xf)
}

public enum MTLCompareFunction: UInt, Sendable {
    case never = 0
    case less = 1
    case equal = 2
    case lessEqual = 3
    case greater = 4
    case notEqual = 5
    case greaterEqual = 6
    case always = 7
}

public enum MTLStencilOperation: UInt, Sendable {
    case keep = 0
    case zero = 1
    case replace = 2
    case incrementClamp = 3
    case decrementClamp = 4
    case invert = 5
    case incrementWrap = 6
    case decrementWrap = 7
}

public enum MTLSamplerMinMagFilter: UInt, Sendable {
    case nearest = 0
    case linear = 1
}

public enum MTLSamplerMipFilter: UInt, Sendable {
    case notMipmapped = 0
    case nearest = 1
    case linear = 2
}

public enum MTLSamplerAddressMode: UInt, Sendable {
    case clampToEdge = 0
    case mirrorClampToEdge = 1
    case `repeat` = 2
    case mirrorRepeat = 3
    case clampToZero = 4
    case clampToBorderColor = 5
}

public enum MTLSamplerBorderColor: UInt, Sendable {
    case transparentBlack = 0
    case opaqueBlack = 1
    case opaqueWhite = 2
}

public enum MTLTextureType: UInt, Sendable {
    case type1D = 0
    case type1DArray = 1
    case type2D = 2
    case type2DArray = 3
    case type2DMultisample = 4
    case typeCube = 5
    case typeCubeArray = 6
    case type3D = 7
    case type2DMultisampleArray = 8
    case typeTextureBuffer = 9
}

public struct MTLTextureUsage: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let unknown = MTLTextureUsage([])
    public static let shaderRead = MTLTextureUsage(rawValue: 0x0001)
    public static let shaderWrite = MTLTextureUsage(rawValue: 0x0002)
    public static let renderTarget = MTLTextureUsage(rawValue: 0x0004)
    public static let pixelFormatView = MTLTextureUsage(rawValue: 0x0010)
    public static let shaderAtomic = MTLTextureUsage(rawValue: 0x0020)
}

public enum MTLStorageMode: UInt, Sendable {
    case shared = 0
    case managed = 1
    case `private` = 2
    case memoryless = 3
}

public enum MTLCPUCacheMode: UInt, Sendable {
    case defaultCache = 0
    case writeCombined = 1
}

public enum MTLHazardTrackingMode: UInt, Sendable {
    case `default` = 0
    case untracked = 1
    case tracked = 2
}

public struct MTLResourceOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let cpuCacheModeWriteCombined = MTLResourceOptions(rawValue: 1)
    public static let storageModeShared = MTLResourceOptions([])
    public static let storageModeManaged = MTLResourceOptions(rawValue: 1 << 4)
    public static let storageModePrivate = MTLResourceOptions(rawValue: 2 << 4)
    public static let storageModeMemoryless = MTLResourceOptions(rawValue: 3 << 4)
    public static let hazardTrackingModeUntracked = MTLResourceOptions(rawValue: 1 << 8)
    public static let hazardTrackingModeTracked = MTLResourceOptions(rawValue: 2 << 8)

    var storageMode: MTLStorageMode {
        MTLStorageMode(rawValue: (rawValue >> 4) & 0xf) ?? .shared
    }
}

public enum MTLPurgeableState: UInt, Sendable {
    case keepCurrent = 1
    case nonVolatile = 2
    case volatile = 3
    case empty = 4
}

public enum MTLCullMode: UInt, Sendable {
    case none = 0
    case front = 1
    case back = 2
}

public enum MTLWinding: UInt, Sendable {
    case clockwise = 0
    case counterClockwise = 1
}

public enum MTLTriangleFillMode: UInt, Sendable {
    case fill = 0
    case lines = 1
}

public enum MTLDepthClipMode: UInt, Sendable {
    case clip = 0
    case clamp = 1
}

public enum MTLVisibilityResultMode: UInt, Sendable {
    case disabled = 0
    case boolean = 1
    case counting = 2
}

public enum MTLVertexFormat: UInt, Sendable {
    case invalid = 0
    case uchar2 = 1
    case uchar3 = 2
    case uchar4 = 3
    case char2 = 4
    case char3 = 5
    case char4 = 6
    case uchar2Normalized = 7
    case uchar3Normalized = 8
    case uchar4Normalized = 9
    case char2Normalized = 10
    case char3Normalized = 11
    case char4Normalized = 12
    case ushort2 = 13
    case ushort3 = 14
    case ushort4 = 15
    case short2 = 16
    case short3 = 17
    case short4 = 18
    case ushort2Normalized = 19
    case ushort3Normalized = 20
    case ushort4Normalized = 21
    case short2Normalized = 22
    case short3Normalized = 23
    case short4Normalized = 24
    case half2 = 25
    case half3 = 26
    case half4 = 27
    case float = 28
    case float2 = 29
    case float3 = 30
    case float4 = 31
    case int = 32
    case int2 = 33
    case int3 = 34
    case int4 = 35
    case uint = 36
    case uint2 = 37
    case uint3 = 38
    case uint4 = 39
    case int1010102Normalized = 40
    case uint1010102Normalized = 41
    case uchar4Normalized_bgra = 42
    case uchar = 45
    case char = 46
    case ucharNormalized = 47
    case charNormalized = 48
    case ushort = 49
    case short = 50
    case ushortNormalized = 51
    case shortNormalized = 52
    case half = 53
}

public enum MTLVertexStepFunction: UInt, Sendable {
    case constant = 0
    case perVertex = 1
    case perInstance = 2
}

public enum MTLCommandBufferStatus: UInt, Sendable {
    case notEnqueued = 0
    case enqueued = 1
    case committed = 2
    case scheduled = 3
    case completed = 4
    case error = 5
}

public enum MTLDispatchType: UInt, Sendable {
    case serial = 0
    case concurrent = 1
}

public enum MTLFunctionType: UInt, Sendable {
    case vertex = 1
    case fragment = 2
    case kernel = 3
}

public enum MTLLanguageVersion: UInt, Sendable {
    case version1_1 = 65537
    case version1_2 = 65538
    case version2_0 = 131072
    case version2_1 = 131073
    case version2_2 = 131074
    case version2_3 = 131075
    case version2_4 = 131076
    case version3_0 = 196608
    case version3_1 = 196609
    case version3_2 = 196610
    case version4_0 = 262144
}

public enum MTLLibraryType: Int, Sendable {
    case executable = 0
    case dynamic = 1
}

public enum MTLGPUFamily: Int, Sendable {
    case apple1 = 1001
    case apple2 = 1002
    case apple3 = 1003
    case apple4 = 1004
    case apple5 = 1005
    case apple6 = 1006
    case apple7 = 1007
    case apple8 = 1008
    case apple9 = 1009
    case apple10 = 1010
    case apple11 = 1011
    case mac2 = 2002
    case common1 = 3001
    case common2 = 3002
    case common3 = 3003
    case metal3 = 5001
    case metal4 = 5002
}

public enum MTLReadWriteTextureTier: UInt, Sendable {
    case tierNone = 0
    case tier1 = 1
    case tier2 = 2
}

public enum MTLArgumentBuffersTier: UInt, Sendable {
    case tier1 = 0
    case tier2 = 1
}

public struct MTLPipelineOption: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
}

public enum MTLMultisampleDepthResolveFilter: UInt, Sendable {
    case sample0 = 0
    case min = 1
    case max = 2
}

public struct MTLBlitOption: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let depthFromDepthStencil = MTLBlitOption(rawValue: 1 << 0)
    public static let stencilFromDepthStencil = MTLBlitOption(rawValue: 1 << 1)
    public static let rowLinearPVRTC = MTLBlitOption(rawValue: 1 << 2)
}

public enum MTLMultisampleStencilResolveFilter: UInt, Sendable {
    case sample0 = 0
    case depthResolvedSample = 1
}

public enum MTLMathMode: Int, Sendable {
    case safe = 0
    case relaxed = 1
    case fast = 2
}

public enum MTLMathFloatingPointFunctions: Int, Sendable {
    case fast = 0
    case precise = 1
}

public enum MTLCompileSymbolVisibility: Int, Sendable {
    case `default` = 0
    case hidden = 1
}

public enum MTLLibraryOptimizationLevel: Int, Sendable {
    case `default` = 0
    case size = 1
}

public enum MTLFloatingPointConversionRoundingMode: Int, Sendable {
    case toNearestEven = 0
    case towardZero = 1
}

// Apple's types: the shifts are C ints, the masks unsigned.
public let MTLResourceCPUCacheModeShift: Int32 = 0
public let MTLResourceCPUCacheModeMask: UInt = 0xf << UInt(MTLResourceCPUCacheModeShift)
public let MTLResourceStorageModeShift: Int32 = 4
public let MTLResourceStorageModeMask: UInt = 0xf << UInt(MTLResourceStorageModeShift)
public let MTLResourceHazardTrackingModeShift: Int32 = 8
public let MTLResourceHazardTrackingModeMask: UInt = 0x3 << UInt(MTLResourceHazardTrackingModeShift)
