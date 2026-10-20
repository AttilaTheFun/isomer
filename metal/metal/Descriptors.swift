// Metal's descriptors: the classes an app fills in to make textures,
// samplers, pipelines, depth-stencil states and render passes. Apple's
// are NSObject subclasses that copy (NSCopying); these are Swift classes,
// copied where a device or a pass takes them (`copy()` is here for the
// apps that call it).

public final class MTLTextureDescriptor {
    public var textureType: MTLTextureType = .type2D
    public var pixelFormat: MTLPixelFormat = .rgba8Unorm
    public var width = 1
    public var height = 1
    public var depth = 1
    public var mipmapLevelCount = 1
    public var sampleCount = 1
    public var arrayLength = 1
    public var resourceOptions: MTLResourceOptions = []
    public var cpuCacheMode: MTLCPUCacheMode = .defaultCache
    public var storageMode: MTLStorageMode = .shared
    public var hazardTrackingMode: MTLHazardTrackingMode = .default
    public var usage: MTLTextureUsage = .shaderRead
    public var allowGPUOptimizedContents = true

    public init() {}

    public class func texture2DDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int, mipmapped: Bool) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        if mipmapped { descriptor.mipmapLevelCount = mipLevels(width, height) }
        return descriptor
    }

    public class func textureCubeDescriptor(pixelFormat: MTLPixelFormat, size: Int, mipmapped: Bool) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .typeCube
        descriptor.pixelFormat = pixelFormat
        descriptor.width = size
        descriptor.height = size
        if mipmapped { descriptor.mipmapLevelCount = mipLevels(size, size) }
        return descriptor
    }

    public class func textureBufferDescriptor(with pixelFormat: MTLPixelFormat, width: Int, resourceOptions: MTLResourceOptions, usage: MTLTextureUsage) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .typeTextureBuffer
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.resourceOptions = resourceOptions
        descriptor.usage = usage
        return descriptor
    }

    /// A copy, as Apple's (NSCopying's) gives it: `as! MTLTextureDescriptor`.
    public func copy() -> Any { duplicate() }

    func duplicate() -> MTLTextureDescriptor {
        let copy = MTLTextureDescriptor()
        copy.textureType = textureType
        copy.pixelFormat = pixelFormat
        copy.width = width
        copy.height = height
        copy.depth = depth
        copy.mipmapLevelCount = mipmapLevelCount
        copy.sampleCount = sampleCount
        copy.arrayLength = arrayLength
        copy.resourceOptions = resourceOptions
        copy.cpuCacheMode = cpuCacheMode
        copy.storageMode = storageMode
        copy.hazardTrackingMode = hazardTrackingMode
        copy.usage = usage
        copy.allowGPUOptimizedContents = allowGPUOptimizedContents
        return copy
    }

    private static func mipLevels(_ width: Int, _ height: Int) -> Int {
        var size = max(width, height)
        var levels = 1
        while size > 1 {
            size /= 2
            levels += 1
        }
        return levels
    }
}

public final class MTLSamplerDescriptor {
    public var minFilter: MTLSamplerMinMagFilter = .nearest
    public var magFilter: MTLSamplerMinMagFilter = .nearest
    public var mipFilter: MTLSamplerMipFilter = .notMipmapped
    public var maxAnisotropy = 1
    public var sAddressMode: MTLSamplerAddressMode = .clampToEdge
    public var tAddressMode: MTLSamplerAddressMode = .clampToEdge
    public var rAddressMode: MTLSamplerAddressMode = .clampToEdge
    public var borderColor: MTLSamplerBorderColor = .transparentBlack
    public var normalizedCoordinates = true
    public var lodMinClamp: Float = 0
    public var lodMaxClamp: Float = .greatestFiniteMagnitude
    public var lodAverage = false
    public var compareFunction: MTLCompareFunction = .never
    public var supportArgumentBuffers = false
    public var label: String?

    public init() {}
}

public final class MTLStencilDescriptor: Equatable {
    public var stencilCompareFunction: MTLCompareFunction = .always
    public var stencilFailureOperation: MTLStencilOperation = .keep
    public var depthFailureOperation: MTLStencilOperation = .keep
    public var depthStencilPassOperation: MTLStencilOperation = .keep
    public var readMask: UInt32 = 0xffff_ffff
    public var writeMask: UInt32 = 0xffff_ffff

    public init() {}

    /// A copy, as Apple's (NSCopying's) gives it: `as! MTLStencilDescriptor`.
    public func copy() -> Any { duplicate() }

    func duplicate() -> MTLStencilDescriptor {
        let copy = MTLStencilDescriptor()
        copy.stencilCompareFunction = stencilCompareFunction
        copy.stencilFailureOperation = stencilFailureOperation
        copy.depthFailureOperation = depthFailureOperation
        copy.depthStencilPassOperation = depthStencilPassOperation
        copy.readMask = readMask
        copy.writeMask = writeMask
        return copy
    }

    public static func == (a: MTLStencilDescriptor, b: MTLStencilDescriptor) -> Bool {
        a.stencilCompareFunction == b.stencilCompareFunction && a.stencilFailureOperation == b.stencilFailureOperation
            && a.depthFailureOperation == b.depthFailureOperation && a.depthStencilPassOperation == b.depthStencilPassOperation
            && a.readMask == b.readMask && a.writeMask == b.writeMask
    }
}

public final class MTLDepthStencilDescriptor {
    public var depthCompareFunction: MTLCompareFunction = .always
    public var isDepthWriteEnabled = false
    public var frontFaceStencil: MTLStencilDescriptor! = MTLStencilDescriptor()
    public var backFaceStencil: MTLStencilDescriptor! = MTLStencilDescriptor()
    public var label: String?

    public init() {}
}

/// What the compiler is told: accepted, and not changing the translation
/// (Apple's preprocessor macros are NSObject-valued; Isomer's are not public).
public final class MTLCompileOptions {
    /// Apple's is `[String: NSObject]?`, which Isomer has no NSObject for:
    /// not public (the translator still applies them).
    var preprocessorMacros: [String: Any]?
    public var fastMathEnabled = true
    public var mathMode: MTLMathMode = .fast
    public var mathFloatingPointFunctions: MTLMathFloatingPointFunctions = .fast
    public var languageVersion: MTLLanguageVersion = .version3_2
    public var libraryType: MTLLibraryType = .executable
    public var installName: String?
    public var optimizationLevel: MTLLibraryOptimizationLevel = .default
    public var compileSymbolVisibility: MTLCompileSymbolVisibility = .default
    public var preserveInvariance = false
    public var allowReferencingUndefinedSymbols = false
    public var maxTotalThreadsPerThreadgroup = 0
    public var requiredThreadsPerThreadgroup = MTLSize()
    public var enableLogging = false
    public var floatingPointConversionRoundingMode: MTLFloatingPointConversionRoundingMode = .toNearestEven

    public init() {}
}

/// A view's format, type, levels and slices (`MTLTexture.newTextureView`).
public final class MTLTextureViewDescriptor {
    public var pixelFormat: MTLPixelFormat = .invalid
    public var textureType: MTLTextureType = .type2D
    public var levelRange: Range<Int> = 0..<1
    public var sliceRange: Range<Int> = 0..<1

    public init() {}
}

// MARK: Vertex descriptors

public final class MTLVertexAttributeDescriptor {
    public var format: MTLVertexFormat = .invalid
    public var offset = 0
    public var bufferIndex = 0

    public init() {}
}

public final class MTLVertexBufferLayoutDescriptor {
    public var stride = 0
    public var stepFunction: MTLVertexStepFunction = .perVertex
    public var stepRate = 1

    public init() {}
}

public final class MTLVertexAttributeDescriptorArray {
    var items: [Int: MTLVertexAttributeDescriptor] = [:]

    public subscript(index: Int) -> MTLVertexAttributeDescriptor! {
        get {
            if let item = items[index] { return item }
            let item = MTLVertexAttributeDescriptor()
            items[index] = item
            return item
        }
        set { items[index] = newValue }
    }
}

public final class MTLVertexBufferLayoutDescriptorArray {
    var items: [Int: MTLVertexBufferLayoutDescriptor] = [:]

    public subscript(index: Int) -> MTLVertexBufferLayoutDescriptor! {
        get {
            if let item = items[index] { return item }
            let item = MTLVertexBufferLayoutDescriptor()
            items[index] = item
            return item
        }
        set { items[index] = newValue }
    }
}

public final class MTLVertexDescriptor {
    public let attributes = MTLVertexAttributeDescriptorArray()
    public let layouts = MTLVertexBufferLayoutDescriptorArray()

    public init() {}

    public func reset() {
        attributes.items.removeAll()
        layouts.items.removeAll()
    }
}

// MARK: Pipelines

public final class MTLRenderPipelineColorAttachmentDescriptor {
    public var pixelFormat: MTLPixelFormat = .invalid
    public var isBlendingEnabled = false
    public var sourceRGBBlendFactor: MTLBlendFactor = .one
    public var destinationRGBBlendFactor: MTLBlendFactor = .zero
    public var rgbBlendOperation: MTLBlendOperation = .add
    public var sourceAlphaBlendFactor: MTLBlendFactor = .one
    public var destinationAlphaBlendFactor: MTLBlendFactor = .zero
    public var alphaBlendOperation: MTLBlendOperation = .add
    public var writeMask: MTLColorWriteMask = .all

    public init() {}
}

public final class MTLRenderPipelineColorAttachmentDescriptorArray {
    var items: [Int: MTLRenderPipelineColorAttachmentDescriptor] = [:]

    public subscript(attachmentIndex: Int) -> MTLRenderPipelineColorAttachmentDescriptor! {
        get {
            if let item = items[attachmentIndex] { return item }
            let item = MTLRenderPipelineColorAttachmentDescriptor()
            items[attachmentIndex] = item
            return item
        }
        set { items[attachmentIndex] = newValue }
    }
}

public final class MTLRenderPipelineDescriptor {
    public var label: String?
    public var vertexFunction: (any MTLFunction)?
    public var fragmentFunction: (any MTLFunction)?
    public var vertexDescriptor: MTLVertexDescriptor?
    public let colorAttachments = MTLRenderPipelineColorAttachmentDescriptorArray()
    public var depthAttachmentPixelFormat: MTLPixelFormat = .invalid
    public var stencilAttachmentPixelFormat: MTLPixelFormat = .invalid
    public var rasterSampleCount = 1
    public var isAlphaToCoverageEnabled = false
    public var isAlphaToOneEnabled = false
    public var isRasterizationEnabled = true
    public var inputPrimitiveTopology: MTLPrimitiveTopologyClass = .unspecified
    public var supportIndirectCommandBuffers = false

    public var sampleCount: Int {
        get { rasterSampleCount }
        set { rasterSampleCount = newValue }
    }

    public init() {}

    public func reset() {
        label = nil
        vertexFunction = nil
        fragmentFunction = nil
        vertexDescriptor = nil
        colorAttachments.items.removeAll()
        depthAttachmentPixelFormat = .invalid
        stencilAttachmentPixelFormat = .invalid
        rasterSampleCount = 1
        isAlphaToCoverageEnabled = false
        isAlphaToOneEnabled = false
        isRasterizationEnabled = true
        inputPrimitiveTopology = .unspecified
    }
}

public final class MTLComputePipelineDescriptor {
    public var label: String?
    public var computeFunction: (any MTLFunction)?
    public var threadGroupSizeIsMultipleOfThreadExecutionWidth = false
    public var maxTotalThreadsPerThreadgroup = 0
    public var requiredThreadsPerThreadgroup = MTLSize()

    public init() {}

    public func reset() {
        label = nil
        computeFunction = nil
        threadGroupSizeIsMultipleOfThreadExecutionWidth = false
        maxTotalThreadsPerThreadgroup = 0
    }
}

// MARK: Render passes

public class MTLRenderPassAttachmentDescriptor {
    public var texture: (any MTLTexture)?
    public var level = 0
    public var slice = 0
    public var depthPlane = 0
    public var resolveTexture: (any MTLTexture)?
    public var resolveLevel = 0
    public var resolveSlice = 0
    public var resolveDepthPlane = 0
    public var loadAction: MTLLoadAction = .dontCare
    public var storeAction: MTLStoreAction = .dontCare
    public var storeActionOptions: MTLStoreActionOptions = []

    public init() {}

    func copyAttachment(to other: MTLRenderPassAttachmentDescriptor) {
        other.texture = texture
        other.level = level
        other.slice = slice
        other.depthPlane = depthPlane
        other.resolveTexture = resolveTexture
        other.resolveLevel = resolveLevel
        other.resolveSlice = resolveSlice
        other.resolveDepthPlane = resolveDepthPlane
        other.loadAction = loadAction
        other.storeAction = storeAction
        other.storeActionOptions = storeActionOptions
    }
}

public final class MTLRenderPassColorAttachmentDescriptor: MTLRenderPassAttachmentDescriptor {
    public var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// A copy, as Apple's (NSCopying's) gives it: `as! MTLRenderPassColorAttachmentDescriptor`.
    public func copy() -> Any { duplicate() }

    func duplicate() -> MTLRenderPassColorAttachmentDescriptor {
        let copy = MTLRenderPassColorAttachmentDescriptor()
        copyAttachment(to: copy)
        copy.clearColor = clearColor
        return copy
    }
}

public final class MTLRenderPassDepthAttachmentDescriptor: MTLRenderPassAttachmentDescriptor {
    public var clearDepth: Double = 1
    public var depthResolveFilter: MTLMultisampleDepthResolveFilter = .sample0

    /// A copy, as Apple's (NSCopying's) gives it: `as! MTLRenderPassDepthAttachmentDescriptor`.
    public func copy() -> Any { duplicate() }

    func duplicate() -> MTLRenderPassDepthAttachmentDescriptor {
        let copy = MTLRenderPassDepthAttachmentDescriptor()
        copyAttachment(to: copy)
        copy.clearDepth = clearDepth
        copy.depthResolveFilter = depthResolveFilter
        return copy
    }
}

public final class MTLRenderPassStencilAttachmentDescriptor: MTLRenderPassAttachmentDescriptor {
    public var clearStencil: UInt32 = 0
    public var stencilResolveFilter: MTLMultisampleStencilResolveFilter = .sample0

    /// A copy, as Apple's (NSCopying's) gives it: `as! MTLRenderPassStencilAttachmentDescriptor`.
    public func copy() -> Any { duplicate() }

    func duplicate() -> MTLRenderPassStencilAttachmentDescriptor {
        let copy = MTLRenderPassStencilAttachmentDescriptor()
        copyAttachment(to: copy)
        copy.clearStencil = clearStencil
        copy.stencilResolveFilter = stencilResolveFilter
        return copy
    }
}

public final class MTLRenderPassColorAttachmentDescriptorArray {
    var items: [Int: MTLRenderPassColorAttachmentDescriptor] = [:]

    public subscript(attachmentIndex: Int) -> MTLRenderPassColorAttachmentDescriptor! {
        get {
            if let item = items[attachmentIndex] { return item }
            let item = MTLRenderPassColorAttachmentDescriptor()
            items[attachmentIndex] = item
            return item
        }
        set { items[attachmentIndex] = newValue }
    }
}

public final class MTLRenderPassDescriptor {
    public let colorAttachments = MTLRenderPassColorAttachmentDescriptorArray()
    public var depthAttachment: MTLRenderPassDepthAttachmentDescriptor! = MTLRenderPassDepthAttachmentDescriptor()
    public var stencilAttachment: MTLRenderPassStencilAttachmentDescriptor! = MTLRenderPassStencilAttachmentDescriptor()
    public var visibilityResultBuffer: (any MTLBuffer)?
    public var renderTargetArrayLength = 0
    public var renderTargetWidth = 0
    public var renderTargetHeight = 0
    public var defaultRasterSampleCount = 0

    public init() {}
}
