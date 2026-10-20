// Metal's protocols: the device and what it makes. Apple's are Objective-C
// protocols (NSObjectProtocol); these are Swift's, with the same members.
// Where Apple's give a parameter a default value (`options: = []`), the
// requirement takes it and an extension adds the call without it.

public typealias MTLCommandBufferHandler = @Sendable (any MTLCommandBuffer) -> Void
public typealias MTLDrawablePresentedHandler = @Sendable (any MTLDrawable) -> Void
public typealias MTLNewLibraryCompletionHandler = ((any MTLLibrary)?, (any Error)?) -> Void
public typealias MTLNewRenderPipelineStateCompletionHandler = ((any MTLRenderPipelineState)?, (any Error)?) -> Void
public typealias MTLNewComputePipelineStateCompletionHandler = ((any MTLComputePipelineState)?, (any Error)?) -> Void

public protocol MTLDevice: AnyObject, Sendable {
    var name: String { get }
    var registryID: UInt64 { get }
    var maxThreadsPerThreadgroup: MTLSize { get }
    var maxBufferLength: Int { get }
    var maxThreadgroupMemoryLength: Int { get }
    var currentAllocatedSize: Int { get }
    var readWriteTextureSupport: MTLReadWriteTextureTier { get }
    var argumentBuffersSupport: MTLArgumentBuffersTier { get }
    var areRasterOrderGroupsSupported: Bool { get }
    var areProgrammableSamplePositionsSupported: Bool { get }
    var hasUnifiedMemory: Bool { get }
    var recommendedMaxWorkingSetSize: UInt64 { get }

    func makeCommandQueue() -> (any MTLCommandQueue)?
    func makeCommandQueue(maxCommandBufferCount: Int) -> (any MTLCommandQueue)?
    func makeBuffer(length: Int, options: MTLResourceOptions) -> (any MTLBuffer)?
    func makeBuffer(bytes pointer: UnsafeRawPointer, length: Int, options: MTLResourceOptions) -> (any MTLBuffer)?
    /// A buffer over the caller's memory (its `contents()`), handed to
    /// `deallocator` when the buffer goes.
    func makeBuffer(bytesNoCopy pointer: UnsafeMutableRawPointer, length: Int, options: MTLResourceOptions, deallocator: (@Sendable (UnsafeMutableRawPointer, Int) -> Void)?) -> (any MTLBuffer)?
    func makeTexture(descriptor: MTLTextureDescriptor) -> (any MTLTexture)?
    func makeSamplerState(descriptor: MTLSamplerDescriptor) -> (any MTLSamplerState)?
    func makeDepthStencilState(descriptor: MTLDepthStencilDescriptor) -> (any MTLDepthStencilState)?
    func makeDefaultLibrary() -> (any MTLLibrary)?
    func makeLibrary(source: String, options: MTLCompileOptions?) throws -> any MTLLibrary
    func makeLibrary(source: String, options: MTLCompileOptions?, completionHandler: @escaping MTLNewLibraryCompletionHandler)
    func makeRenderPipelineState(descriptor: MTLRenderPipelineDescriptor) throws -> any MTLRenderPipelineState
    func makeRenderPipelineState(descriptor: MTLRenderPipelineDescriptor, completionHandler: @escaping MTLNewRenderPipelineStateCompletionHandler)
    func makeComputePipelineState(function computeFunction: any MTLFunction) throws -> any MTLComputePipelineState
    func makeComputePipelineState(function computeFunction: any MTLFunction, completionHandler: @escaping MTLNewComputePipelineStateCompletionHandler)
    func supportsFamily(_ gpuFamily: MTLGPUFamily) -> Bool
    func supportsTextureSampleCount(_ sampleCount: Int) -> Bool
    func minimumLinearTextureAlignment(for format: MTLPixelFormat) -> Int
    func heapBufferSizeAndAlign(length: Int, options: MTLResourceOptions) -> MTLSizeAndAlign
    func heapTextureSizeAndAlign(descriptor desc: MTLTextureDescriptor) -> MTLSizeAndAlign
}

// Apple's requirements default their `options` to `[]`, which a Swift
// protocol requirement cannot: these are the calls that leave it out.
extension MTLDevice {
    public func makeBuffer(length: Int) -> (any MTLBuffer)? {
        makeBuffer(length: length, options: [])
    }

    public func makeBuffer(bytes pointer: UnsafeRawPointer, length: Int) -> (any MTLBuffer)? {
        makeBuffer(bytes: pointer, length: length, options: [])
    }

    public func makeBuffer(
        bytesNoCopy pointer: UnsafeMutableRawPointer, length: Int,
        deallocator: (@Sendable (UnsafeMutableRawPointer, Int) -> Void)?
    ) -> (any MTLBuffer)? {
        makeBuffer(bytesNoCopy: pointer, length: length, options: [], deallocator: deallocator)
    }

    public func heapBufferSizeAndAlign(length: Int) -> MTLSizeAndAlign {
        heapBufferSizeAndAlign(length: length, options: [])
    }
}

public protocol MTLResource: MTLAllocation {
    var label: String? { get set }
    var device: any MTLDevice { get }
    var cpuCacheMode: MTLCPUCacheMode { get }
    var storageMode: MTLStorageMode { get }
    var hazardTrackingMode: MTLHazardTrackingMode { get }
    var resourceOptions: MTLResourceOptions { get }
    var allocatedSize: Int { get }
    func setPurgeableState(_ state: MTLPurgeableState) -> MTLPurgeableState
}

public protocol MTLBuffer: MTLResource {
    var length: Int { get }
    func contents() -> UnsafeMutableRawPointer
    /// The CPU changed this range (a managed buffer's rule; on the web
    /// every buffer the CPU can see follows it, cheaply: see
    /// docs/parity/Metal.md).
    func didModifyRange(_ range: Range<Int>)
    func addDebugMarker(_ marker: String, range: Range<Int>)
    func removeAllDebugMarkers()
}

public protocol MTLTexture: MTLResource {
    var textureType: MTLTextureType { get }
    var pixelFormat: MTLPixelFormat { get }
    var width: Int { get }
    var height: Int { get }
    var depth: Int { get }
    var mipmapLevelCount: Int { get }
    var sampleCount: Int { get }
    var arrayLength: Int { get }
    var usage: MTLTextureUsage { get }
    var isFramebufferOnly: Bool { get }
    var allowGPUOptimizedContents: Bool { get }
    var parent: (any MTLTexture)? { get }
    var parentRelativeLevel: Int { get }
    var parentRelativeSlice: Int { get }
    var buffer: (any MTLBuffer)? { get }
    var bufferOffset: Int { get }
    var bufferBytesPerRow: Int { get }

    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, bytesPerImage: Int, from region: MTLRegion, mipmapLevel level: Int, slice: Int)
    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion, mipmapLevel level: Int)
    func replace(region: MTLRegion, mipmapLevel level: Int, slice: Int, withBytes pixelBytes: UnsafeRawPointer, bytesPerRow: Int, bytesPerImage: Int)
    func replace(region: MTLRegion, mipmapLevel level: Int, withBytes pixelBytes: UnsafeRawPointer, bytesPerRow: Int)
    func makeTextureView(pixelFormat: MTLPixelFormat) -> (any MTLTexture)?
    func makeTextureView(pixelFormat: MTLPixelFormat, textureType: MTLTextureType, levels levelRange: Range<Int>, slices sliceRange: Range<Int>) -> (any MTLTexture)?
}

public protocol MTLSamplerState: AnyObject, Sendable {
    var label: String? { get }
    var device: any MTLDevice { get }
}

public protocol MTLDepthStencilState: AnyObject, Sendable {
    var label: String? { get }
    var device: any MTLDevice { get }
}

public protocol MTLFunction: AnyObject, Sendable {
    var label: String? { get set }
    var device: any MTLDevice { get }
    var functionType: MTLFunctionType { get }
    var name: String { get }
}

public protocol MTLLibrary: AnyObject, Sendable {
    var label: String? { get set }
    var device: any MTLDevice { get }
    var functionNames: [String] { get }
    var type: MTLLibraryType { get }
    var installName: String? { get }
    func makeFunction(name functionName: String) -> (any MTLFunction)?
}

public protocol MTLRenderPipelineState: AnyObject, Sendable {
    var label: String? { get }
    var device: any MTLDevice { get }
    var maxTotalThreadsPerThreadgroup: Int { get }
}

public protocol MTLComputePipelineState: AnyObject, Sendable {
    var label: String? { get }
    var device: any MTLDevice { get }
    var maxTotalThreadsPerThreadgroup: Int { get }
    var threadExecutionWidth: Int { get }
    var staticThreadgroupMemoryLength: Int { get }
}

public protocol MTLCommandQueue: AnyObject, Sendable {
    var label: String? { get set }
    var device: any MTLDevice { get }
    func makeCommandBuffer() -> (any MTLCommandBuffer)?
    func makeCommandBufferWithUnretainedReferences() -> (any MTLCommandBuffer)?
}

public protocol MTLDrawable: AnyObject {
    var presentedTime: CFTimeInterval { get }
    var drawableID: Int { get }
    func present()
    func present(at presentationTime: CFTimeInterval)
    func present(afterMinimumDuration duration: CFTimeInterval)
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler)
}

public protocol MTLCommandBuffer: AnyObject {
    var device: any MTLDevice { get }
    var commandQueue: any MTLCommandQueue { get }
    var retainedReferences: Bool { get }
    var label: String? { get set }
    var kernelStartTime: CFTimeInterval { get }
    var kernelEndTime: CFTimeInterval { get }
    var gpuStartTime: CFTimeInterval { get }
    var gpuEndTime: CFTimeInterval { get }
    var status: MTLCommandBufferStatus { get }
    var error: (any Error)? { get }

    func enqueue()
    func commit()
    func addScheduledHandler(_ block: @escaping MTLCommandBufferHandler)
    func addCompletedHandler(_ block: @escaping MTLCommandBufferHandler)
    func waitUntilScheduled()
    func waitUntilCompleted()
    func present(_ drawable: any MTLDrawable)
    func present(_ drawable: any MTLDrawable, atTime presentationTime: CFTimeInterval)
    func present(_ drawable: any MTLDrawable, afterMinimumDuration duration: CFTimeInterval)
    func makeRenderCommandEncoder(descriptor renderPassDescriptor: MTLRenderPassDescriptor) -> (any MTLRenderCommandEncoder)?
    func makeComputeCommandEncoder() -> (any MTLComputeCommandEncoder)?
    func makeComputeCommandEncoder(dispatchType: MTLDispatchType) -> (any MTLComputeCommandEncoder)?
    func makeBlitCommandEncoder() -> (any MTLBlitCommandEncoder)?
    func pushDebugGroup(_ string: String)
    func popDebugGroup()
}

public protocol MTLCommandEncoder: AnyObject {
    var device: any MTLDevice { get }
    var label: String? { get set }
    func endEncoding()
    func insertDebugSignpost(_ string: String)
    func pushDebugGroup(_ string: String)
    func popDebugGroup()
}

public protocol MTLRenderCommandEncoder: MTLCommandEncoder {
    func setRenderPipelineState(_ pipelineState: any MTLRenderPipelineState)
    func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setVertexBuffer(_ buffer: (any MTLBuffer)?, offset: Int, index: Int)
    func setVertexBufferOffset(_ offset: Int, index: Int)
    func setVertexBuffers(_ buffers: [(any MTLBuffer)?], offsets: [Int], range: Range<Int>)
    func setVertexTexture(_ texture: (any MTLTexture)?, index: Int)
    func setVertexTextures(_ textures: [(any MTLTexture)?], range: Range<Int>)
    func setVertexSamplerState(_ sampler: (any MTLSamplerState)?, index: Int)
    func setVertexSamplerStates(_ samplers: [(any MTLSamplerState)?], range: Range<Int>)
    func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setFragmentBuffer(_ buffer: (any MTLBuffer)?, offset: Int, index: Int)
    func setFragmentBufferOffset(_ offset: Int, index: Int)
    func setFragmentBuffers(_ buffers: [(any MTLBuffer)?], offsets: [Int], range: Range<Int>)
    func setFragmentTexture(_ texture: (any MTLTexture)?, index: Int)
    func setFragmentTextures(_ textures: [(any MTLTexture)?], range: Range<Int>)
    func setFragmentSamplerState(_ sampler: (any MTLSamplerState)?, index: Int)
    func setFragmentSamplerStates(_ samplers: [(any MTLSamplerState)?], range: Range<Int>)
    func setViewport(_ viewport: MTLViewport)
    func setScissorRect(_ rect: MTLScissorRect)
    func setFrontFacing(_ frontFacingWinding: MTLWinding)
    func setCullMode(_ cullMode: MTLCullMode)
    func setDepthClipMode(_ depthClipMode: MTLDepthClipMode)
    func setDepthBias(_ depthBias: Float, slopeScale: Float, clamp: Float)
    func setTriangleFillMode(_ fillMode: MTLTriangleFillMode)
    func setBlendColor(red: Float, green: Float, blue: Float, alpha: Float)
    func setDepthStencilState(_ depthStencilState: (any MTLDepthStencilState)?)
    func setStencilReferenceValue(_ referenceValue: UInt32)
    func setStencilReferenceValues(front frontReferenceValue: UInt32, back backReferenceValue: UInt32)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int)
    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int, baseInstance: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: any MTLBuffer, indexBufferOffset: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: any MTLBuffer, indexBufferOffset: Int, instanceCount: Int)
    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: any MTLBuffer, indexBufferOffset: Int, instanceCount: Int, baseVertex: Int, baseInstance: Int)
}

public protocol MTLComputeCommandEncoder: MTLCommandEncoder {
    var dispatchType: MTLDispatchType { get }
    func setComputePipelineState(_ state: any MTLComputePipelineState)
    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setBuffer(_ buffer: (any MTLBuffer)?, offset: Int, index: Int)
    func setBufferOffset(_ offset: Int, index: Int)
    func setBuffers(_ buffers: [(any MTLBuffer)?], offsets: [Int], range: Range<Int>)
    func setTexture(_ texture: (any MTLTexture)?, index: Int)
    func setTextures(_ textures: [(any MTLTexture)?], range: Range<Int>)
    func setSamplerState(_ sampler: (any MTLSamplerState)?, index: Int)
    func setSamplerStates(_ samplers: [(any MTLSamplerState)?], range: Range<Int>)
    func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize)
    func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize)
}

public protocol MTLBlitCommandEncoder: MTLCommandEncoder {
    func copy(from sourceBuffer: any MTLBuffer, sourceOffset: Int, to destinationBuffer: any MTLBuffer, destinationOffset: Int, size: Int)
    func copy(from sourceBuffer: any MTLBuffer, sourceOffset: Int, sourceBytesPerRow: Int, sourceBytesPerImage: Int, sourceSize: MTLSize, to destinationTexture: any MTLTexture, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MTLOrigin)
    func copy(from sourceTexture: any MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize, to destinationBuffer: any MTLBuffer, destinationOffset: Int, destinationBytesPerRow: Int, destinationBytesPerImage: Int)
    func copy(from sourceTexture: any MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize, to destinationTexture: any MTLTexture, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MTLOrigin)
    func copy(from sourceTexture: any MTLTexture, to destinationTexture: any MTLTexture)
    func fill(buffer: any MTLBuffer, range: Range<Int>, value: UInt8)
    func generateMipmaps(for texture: any MTLTexture)
    /// A managed resource's GPU contents, made visible to the CPU once the
    /// command buffer completes (macOS's rule; on the web, every
    /// texture's).
    func synchronize(resource: any MTLResource)
    func synchronize(texture: any MTLTexture, slice: Int, level: Int)
    func optimizeContentsForGPUAccess(texture: any MTLTexture)
    func optimizeContentsForCPUAccess(texture: any MTLTexture)
}

// MARK: What the protocols above give in terms of their requirements

/// Anything that takes GPU memory.
public protocol MTLAllocation: AnyObject {
    var allocatedSize: Int { get }
}

/// The GPU's architecture, by name.
public final class MTLArchitecture: @unchecked Sendable {
    public let name: String

    init(name: String) {
        self.name = name
    }
}

/// Every device: the one the platform has.
public func MTLCopyAllDevices() -> [any MTLDevice] {
    MTLCreateSystemDefaultDevice().map { [$0] } ?? []
}

extension MTLDevice {
    public var architecture: MTLArchitecture { MTLArchitecture(name: name) }
    public var supports32BitFloatFiltering: Bool { false }
    public var supports32BitMSAA: Bool { false }
    public var supportsQueryTextureLOD: Bool { true }
    public var supportsPullModelInterpolation: Bool { false }
    public var supportsShaderBarycentricCoordinates: Bool { false }
    public var supportsDynamicLibraries: Bool { false }
    public var supportsRenderDynamicLibraries: Bool { false }
    public var supportsRaytracing: Bool { false }
    public var supportsFunctionPointers: Bool { false }
    public var supportsPrimitiveMotionBlur: Bool { false }

    public func minimumTextureBufferAlignment(for format: MTLPixelFormat) -> Int {
        256
    }
}

extension MTLComputePipelineState {
    /// No size is required: the dispatch gives it.
    public var requiredThreadsPerThreadgroup: MTLSize { MTLSize() }
}

extension MTLCommandBuffer {
    /// Returns once the work is scheduled.
    public func scheduled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            addScheduledHandler { _ in continuation.resume() }
        }
    }

    /// Returns once the work is done (the way to wait in a browser).
    public func completed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            addCompletedHandler { _ in continuation.resume() }
        }
    }
}

extension MTLTexture {
    public func newTextureView(with descriptor: MTLTextureViewDescriptor) -> (any MTLTexture)? {
        makeTextureView(
            pixelFormat: descriptor.pixelFormat == .invalid ? pixelFormat : descriptor.pixelFormat,
            textureType: descriptor.textureType, levels: descriptor.levelRange, slices: descriptor.sliceRange)
    }
}

// The level-of-detail clamps are not applied: a WebGPU sampler's clamps are
// its own (MTLSamplerDescriptor's lodMinClamp and lodMaxClamp).
extension MTLRenderCommandEncoder {
    public func setVertexSamplerState(_ sampler: (any MTLSamplerState)?, lodMinClamp: Float, lodMaxClamp: Float, index: Int) {
        setVertexSamplerState(sampler, index: index)
    }

    public func setVertexSamplerStates(_ samplers: [(any MTLSamplerState)?], lodMinClamps: [Float], lodMaxClamps: [Float], range: Range<Int>) {
        setVertexSamplerStates(samplers, range: range)
    }

    public func setFragmentSamplerState(_ sampler: (any MTLSamplerState)?, lodMinClamp: Float, lodMaxClamp: Float, index: Int) {
        setFragmentSamplerState(sampler, index: index)
    }

    public func setFragmentSamplerStates(_ samplers: [(any MTLSamplerState)?], lodMinClamps: [Float], lodMaxClamps: [Float], range: Range<Int>) {
        setFragmentSamplerStates(samplers, range: range)
    }

    /// WebGPU has one viewport and one scissor rectangle: the first.
    public func setViewports(_ viewports: [MTLViewport]) {
        if let first = viewports.first { setViewport(first) }
    }

    public func setScissorRects(_ scissorRects: [MTLScissorRect]) {
        if let first = scissorRects.first { setScissorRect(first) }
    }

    /// A pass whose store action was `.unknown` stores (WebGPU decides at
    /// the start of the pass).
    public func setColorStoreAction(_ storeAction: MTLStoreAction, index colorAttachmentIndex: Int) {}
    public func setDepthStoreAction(_ storeAction: MTLStoreAction) {}
    public func setStencilStoreAction(_ storeAction: MTLStoreAction) {}
}

extension MTLComputeCommandEncoder {
    public func setSamplerState(_ sampler: (any MTLSamplerState)?, lodMinClamp: Float, lodMaxClamp: Float, index: Int) {
        setSamplerState(sampler, index: index)
    }

    public func setSamplerStates(_ samplers: [(any MTLSamplerState)?], lodMinClamps: [Float], lodMaxClamps: [Float], range: Range<Int>) {
        setSamplerStates(samplers, range: range)
    }
}

extension MTLBlitCommandEncoder {
    /// The options (depth or stencil of a combined format, PVRTC rows) are
    /// for formats WebGPU copies whole or does not have.
    public func copy(from sourceBuffer: any MTLBuffer, sourceOffset: Int, sourceBytesPerRow: Int, sourceBytesPerImage: Int, sourceSize: MTLSize, to destinationTexture: any MTLTexture, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MTLOrigin, options: MTLBlitOption) {
        copy(from: sourceBuffer, sourceOffset: sourceOffset, sourceBytesPerRow: sourceBytesPerRow, sourceBytesPerImage: sourceBytesPerImage,
             sourceSize: sourceSize, to: destinationTexture, destinationSlice: destinationSlice, destinationLevel: destinationLevel,
             destinationOrigin: destinationOrigin)
    }

    public func copy(from sourceTexture: any MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize, to destinationBuffer: any MTLBuffer, destinationOffset: Int, destinationBytesPerRow: Int, destinationBytesPerImage: Int, options: MTLBlitOption) {
        copy(from: sourceTexture, sourceSlice: sourceSlice, sourceLevel: sourceLevel, sourceOrigin: sourceOrigin, sourceSize: sourceSize,
             to: destinationBuffer, destinationOffset: destinationOffset, destinationBytesPerRow: destinationBytesPerRow,
             destinationBytesPerImage: destinationBytesPerImage)
    }

    public func copy(from sourceTexture: any MTLTexture, sourceSlice: Int, sourceLevel: Int, to destinationTexture: any MTLTexture, destinationSlice: Int, destinationLevel: Int, sliceCount: Int, levelCount: Int) {
        for slice in 0..<sliceCount {
            for level in 0..<levelCount {
                let size = MTLSize(width: max(sourceTexture.width >> (sourceLevel + level), 1),
                                   height: max(sourceTexture.height >> (sourceLevel + level), 1),
                                   depth: max(sourceTexture.depth >> (sourceLevel + level), 1))
                copy(from: sourceTexture, sourceSlice: sourceSlice + slice, sourceLevel: sourceLevel + level, sourceOrigin: MTLOrigin(),
                     sourceSize: size, to: destinationTexture, destinationSlice: destinationSlice + slice,
                     destinationLevel: destinationLevel + level, destinationOrigin: MTLOrigin())
            }
        }
    }

    public func optimizeContentsForGPUAccess(texture: any MTLTexture, slice: Int, level: Int) {}
    public func optimizeContentsForCPUAccess(texture: any MTLTexture, slice: Int, level: Int) {}
}
