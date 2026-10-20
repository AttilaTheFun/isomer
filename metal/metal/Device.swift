// Isomer's Metal device and its resources. What they do is recorded as
// commands (IsomerMetal's MetalCommands) for the backend the platform
// connected (`currentMetalBackend`): resources are made and written by
// device commands, sent with the next command buffer committed.
//
// Memory the CPU sees: a buffer that is not `.storageModePrivate` keeps
// its bytes in this process too (what `contents()` returns). Its bytes go
// to the GPU when it is made with bytes, and then, once `contents()` has
// been asked for, with every command buffer that uses it. What the GPU
// writes to such a buffer (a kernel's or fragment function's writable
// buffer, a blit's destination) comes back when the command buffer
// completes, before its completed handlers run. A texture's GPU contents
// come back after a blit encoder's `synchronize(resource:)`, macOS's rule
// for managed textures.

internal import IsomerMetal

/// The device on the platform's backend, or nil before the platform's GPU
/// is ready (on the web, until the page connects its WebGPU executor).
public func MTLCreateSystemDefaultDevice() -> (any MTLDevice)? {
    guard let backend = currentMetalBackend else { return nil }
    if let device = IsomerDevice.shared, device.backend === backend { return device }
    let device = IsomerDevice(backend: backend)
    IsomerDevice.shared = device
    return device
}

/// Apple's shape: a code, and what went wrong in `userInfo` under
/// "NSLocalizedDescription" (Foundation's `NSLocalizedDescriptionKey`).
public struct MTLLibraryError: Error, Hashable, @unchecked Sendable {
    public enum Code: UInt, Sendable {
        case unsupported = 1
        case `internal` = 2
        case compileFailure = 3
        case compileWarning = 4
        case functionNotFound = 5
        case fileNotFound = 6

        public static func ~= (match: MTLLibraryError.Code, error: any Error) -> Bool {
            (error as? MTLLibraryError)?.code == match
        }
    }

    public let code: Code
    public let userInfo: [String: Any]

    public init(_ code: Code, userInfo: [String: Any] = [:]) {
        self.code = code
        self.userInfo = userInfo
    }

    init(_ code: Code, _ message: String) {
        self.init(code, userInfo: ["NSLocalizedDescription": message])
    }

    public static var errorDomain: String { "MTLLibraryErrorDomain" }
    public var errorCode: Int { Int(code.rawValue) }
    public var errorUserInfo: [String: Any] { userInfo }

    public static var unsupported: Code { .unsupported }
    public static var `internal`: Code { .internal }
    public static var compileFailure: Code { .compileFailure }
    public static var compileWarning: Code { .compileWarning }
    public static var functionNotFound: Code { .functionNotFound }
    public static var fileNotFound: Code { .fileNotFound }

    var message: String { userInfo["NSLocalizedDescription"] as? String ?? "" }

    public static func == (lhs: MTLLibraryError, rhs: MTLLibraryError) -> Bool {
        lhs.code == rhs.code && lhs.message == rhs.message
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(code)
        hasher.combine(message)
    }
}

/// Why a render pipeline could not be made. Apple's Metal reports this as
/// an `NSError` callers see only as `any Error`; Isomer's type is its own,
/// and not public.
struct RenderPipelineError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

final class IsomerDevice: MTLDevice, @unchecked Sendable {
    nonisolated(unsafe) static var shared: IsomerDevice?

    let backend: any MetalBackend
    /// Device commands not yet performed: they go with the next stream.
    var pending = MetalCommandWriter()
    private var nextID: Int32 = 0

    init(backend: any MetalBackend) {
        self.backend = backend
    }

    func makeID() -> Int32 {
        nextID += 1
        return nextID
    }

    func destroy(_ id: Int32) {
        pending.op(.destroy)
        pending.int(id)
    }

    /// The device commands waiting, taken.
    func takePending() -> MetalCommandWriter {
        let taken = pending
        pending = MetalCommandWriter()
        return taken
    }

    var name: String { backend.name }
    var registryID: UInt64 { 1 }
    // WebGPU's default limits.
    var maxThreadsPerThreadgroup: MTLSize { MTLSize(width: 256, height: 256, depth: 64) }
    var maxBufferLength: Int { 256 << 20 }
    var maxThreadgroupMemoryLength: Int { 16 << 10 }
    var currentAllocatedSize: Int { 0 }
    var readWriteTextureSupport: MTLReadWriteTextureTier { .tier1 }
    var argumentBuffersSupport: MTLArgumentBuffersTier { .tier1 }
    var areRasterOrderGroupsSupported: Bool { false }
    var areProgrammableSamplePositionsSupported: Bool { false }
    var hasUnifiedMemory: Bool { false }
    var recommendedMaxWorkingSetSize: UInt64 { 1 << 30 }

    func makeCommandQueue() -> (any MTLCommandQueue)? {
        IsomerCommandQueue(device: self)
    }

    func makeCommandQueue(maxCommandBufferCount: Int) -> (any MTLCommandQueue)? {
        IsomerCommandQueue(device: self)
    }

    func makeBuffer(length: Int, options: MTLResourceOptions) -> (any MTLBuffer)? {
        guard length > 0, length <= maxBufferLength else { return nil }
        return IsomerBuffer(device: self, length: length, options: options, bytes: nil)
    }

    func makeBuffer(bytes pointer: UnsafeRawPointer, length: Int, options: MTLResourceOptions) -> (any MTLBuffer)? {
        guard length > 0, length <= maxBufferLength else { return nil }
        return IsomerBuffer(device: self, length: length, options: options, bytes: pointer)
    }

    func makeBuffer(bytesNoCopy pointer: UnsafeMutableRawPointer, length: Int, options: MTLResourceOptions, deallocator: (@Sendable (UnsafeMutableRawPointer, Int) -> Void)?) -> (any MTLBuffer)? {
        guard length > 0, length <= maxBufferLength else { return nil }
        return IsomerBuffer(device: self, length: length, options: options, memory: pointer, deallocator: deallocator)
    }

    func makeTexture(descriptor: MTLTextureDescriptor) -> (any MTLTexture)? {
        guard descriptor.pixelFormat != .invalid, descriptor.width > 0, descriptor.height > 0 else { return nil }
        return IsomerTexture(device: self, descriptor: descriptor)
    }

    func makeSamplerState(descriptor: MTLSamplerDescriptor) -> (any MTLSamplerState)? {
        IsomerSamplerState(device: self, descriptor: descriptor)
    }

    func makeDepthStencilState(descriptor: MTLDepthStencilDescriptor) -> (any MTLDepthStencilState)? {
        IsomerDepthStencilState(device: self, descriptor: descriptor)
    }

    /// No compiled library comes with an app off Apple platforms: a library
    /// is made from source (`makeLibrary(source:options:)`).
    func makeDefaultLibrary() -> (any MTLLibrary)? {
        nil
    }

    func makeLibrary(source: String, options: MTLCompileOptions?) throws -> any MTLLibrary {
        var text = source
        if let macros = options?.preprocessorMacros, !macros.isEmpty {
            var defines = ""
            for (name, value) in macros.sorted(by: { $0.key < $1.key }) {
                defines += "#define \(name) \(value)\n"
            }
            text = defines + source
        }
        do {
            let translator = try MSLTranslator(source: text)
            var entryPoints: [String: TranslatedEntryPoint] = [:]
            for (name, _) in translator.entryPoints {
                entryPoints[name] = try translator.translate(entryPoint: name)
            }
            return IsomerLibrary(device: self, entryPoints: entryPoints)
        } catch let error as MSLTranslationError {
            throw MTLLibraryError(.compileFailure, "program_source:\(error)")
        }
    }

    func makeLibrary(source: String, options: MTLCompileOptions?, completionHandler: @escaping MTLNewLibraryCompletionHandler) {
        do {
            completionHandler(try makeLibrary(source: source, options: options), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func makeRenderPipelineState(descriptor: MTLRenderPipelineDescriptor) throws -> any MTLRenderPipelineState {
        try IsomerRenderPipelineState(device: self, descriptor: descriptor)
    }

    func makeRenderPipelineState(descriptor: MTLRenderPipelineDescriptor, completionHandler: @escaping MTLNewRenderPipelineStateCompletionHandler) {
        do {
            completionHandler(try makeRenderPipelineState(descriptor: descriptor), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func makeComputePipelineState(function computeFunction: any MTLFunction) throws -> any MTLComputePipelineState {
        try IsomerComputePipelineState(device: self, function: computeFunction, label: nil)
    }

    func makeComputePipelineState(function computeFunction: any MTLFunction, completionHandler: @escaping MTLNewComputePipelineStateCompletionHandler) {
        do {
            completionHandler(try makeComputePipelineState(function: computeFunction), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func supportsFamily(_ gpuFamily: MTLGPUFamily) -> Bool {
        switch gpuFamily {
        case .common1, .common2: return true
        default: return false
        }
    }

    func supportsTextureSampleCount(_ sampleCount: Int) -> Bool {
        sampleCount == 1 || sampleCount == 4
    }

    func minimumLinearTextureAlignment(for format: MTLPixelFormat) -> Int {
        256
    }

    func heapBufferSizeAndAlign(length: Int, options: MTLResourceOptions) -> MTLSizeAndAlign {
        MTLSizeAndAlign(size: (length + 255) & ~255, align: 256)
    }

    func heapTextureSizeAndAlign(descriptor desc: MTLTextureDescriptor) -> MTLSizeAndAlign {
        let size = desc.width * desc.height * desc.depth * max(desc.arrayLength, 1) * max(desc.pixelFormat.bytesPerPixel, 4)
        return MTLSizeAndAlign(size: (size + 255) & ~255, align: 256)
    }
}

// MARK: Buffers

final class IsomerBuffer: MTLBuffer {
    let isomerDevice: IsomerDevice
    let id: Int32
    let length: Int
    let resourceOptions: MTLResourceOptions
    var label: String?
    /// The bytes the CPU sees (nil for a private buffer).
    private(set) var storage: UnsafeMutableRawPointer?
    /// `contents()` was asked for: the CPU may write at any time, so the
    /// bytes go with every command buffer that uses the buffer.
    var exposed = false
    /// Command buffers in flight that write it: until they complete, the
    /// GPU's bytes are newer than the CPU's.
    var pendingGPUWrites = 0
    /// The caller's memory (`makeBuffer(bytesNoCopy:…)`), handed back on
    /// release; nil when the buffer allocated its own.
    private var deallocator: ((UnsafeMutableRawPointer, Int) -> Void)?
    private var ownsStorage = true

    /// A buffer over the caller's memory: what the CPU writes there goes
    /// to the GPU as with `contents()`.
    convenience init(device: IsomerDevice, length: Int, options: MTLResourceOptions, memory: UnsafeMutableRawPointer,
                     deallocator: ((UnsafeMutableRawPointer, Int) -> Void)?) {
        self.init(device: device, length: length, options: options.subtracting(.storageModePrivate), bytes: nil)
        storage?.deallocate()
        storage = memory
        ownsStorage = false
        exposed = true
        self.deallocator = deallocator
    }

    init(device: IsomerDevice, length: Int, options: MTLResourceOptions, bytes: UnsafeRawPointer?) {
        isomerDevice = device
        id = device.makeID()
        self.length = length
        resourceOptions = options
        let padded = (length + 3) & ~3
        device.pending.op(.createBuffer)
        device.pending.int(id)
        device.pending.int(padded)
        device.pending.uint(options.storageMode.rawValue)
        if options.storageMode != .private {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: padded, alignment: 16)
            memory.initializeMemory(as: UInt8.self, repeating: 0, count: padded)
            storage = memory
        }
        if let bytes {
            storage?.copyMemory(from: bytes, byteCount: length)
            device.pending.op(.writeBuffer)
            device.pending.int(id)
            device.pending.int(0)
            if let storage {
                device.pending.data(UnsafeRawBufferPointer(start: storage, count: padded))
            } else {
                var copy = [UInt8](repeating: 0, count: padded)
                copy.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: length)) }
                device.pending.data(copy)
            }
        }
    }

    deinit {
        isomerDevice.destroy(id)
        if ownsStorage {
            storage?.deallocate()
        } else if let storage {
            deallocator?(storage, length)
        }
    }

    var device: any MTLDevice { isomerDevice }
    var cpuCacheMode: MTLCPUCacheMode { resourceOptions.contains(.cpuCacheModeWriteCombined) ? .writeCombined : .defaultCache }
    var storageMode: MTLStorageMode { resourceOptions.storageMode }
    var hazardTrackingMode: MTLHazardTrackingMode { .tracked }
    var allocatedSize: Int { (length + 3) & ~3 }

    func setPurgeableState(_ state: MTLPurgeableState) -> MTLPurgeableState {
        .nonVolatile
    }

    func contents() -> UnsafeMutableRawPointer {
        guard let storage else {
            fatalError("contents() of a buffer with private storage")
        }
        exposed = true
        return storage
    }

    func didModifyRange(_ range: Range<Int>) {
        exposed = true
    }

    func addDebugMarker(_ marker: String, range: Range<Int>) {}
    func removeAllDebugMarkers() {}

    /// The bytes as they stand, for a command buffer to send.
    func writeContents(to writer: inout MetalCommandWriter) {
        guard let storage else { return }
        writer.op(.writeBuffer)
        writer.int(id)
        writer.int(0)
        writer.data(UnsafeRawBufferPointer(start: storage, count: (length + 3) & ~3))
    }

    func receive(_ bytes: [UInt8]) {
        guard let storage else { return }
        let count = min(bytes.count, length)
        bytes.withUnsafeBytes { storage.copyMemory(from: $0.baseAddress!, byteCount: count) }
    }
}

// MARK: Textures

final class IsomerTexture: MTLTexture {
    let isomerDevice: IsomerDevice
    let id: Int32
    let textureType: MTLTextureType
    let pixelFormat: MTLPixelFormat
    let width: Int
    let height: Int
    let depth: Int
    let mipmapLevelCount: Int
    let sampleCount: Int
    let arrayLength: Int
    let usage: MTLTextureUsage
    let resourceOptions: MTLResourceOptions
    let storageMode: MTLStorageMode
    let allowGPUOptimizedContents: Bool
    var label: String?
    let parent: (any MTLTexture)?
    let parentRelativeLevel: Int
    let parentRelativeSlice: Int
    /// A surface's drawable texture: the backend owns it.
    let isDrawable: Bool
    /// What came back from the GPU, by (slice, level): getBytes reads it.
    var readback: [Int: [UInt8]] = [:]

    init(device: IsomerDevice, descriptor: MTLTextureDescriptor) {
        isomerDevice = device
        id = device.makeID()
        textureType = descriptor.textureType
        pixelFormat = descriptor.pixelFormat
        width = descriptor.width
        height = descriptor.height
        depth = descriptor.depth
        mipmapLevelCount = descriptor.mipmapLevelCount
        sampleCount = descriptor.sampleCount
        arrayLength = descriptor.arrayLength
        usage = descriptor.usage
        resourceOptions = descriptor.resourceOptions
        storageMode = descriptor.storageMode
        allowGPUOptimizedContents = descriptor.allowGPUOptimizedContents
        parent = nil
        parentRelativeLevel = 0
        parentRelativeSlice = 0
        isDrawable = false
        device.pending.op(.createTexture)
        device.pending.int(id)
        device.pending.uint(textureType.rawValue)
        device.pending.uint(pixelFormat.rawValue)
        device.pending.int(width)
        device.pending.int(height)
        device.pending.int(depth)
        device.pending.int(textureType == .typeCube || textureType == .typeCubeArray ? arrayLength * 6 : arrayLength)
        device.pending.int(mipmapLevelCount)
        device.pending.int(sampleCount)
        device.pending.uint(usage.rawValue)
    }

    /// A view of another texture.
    init(view source: IsomerTexture, pixelFormat: MTLPixelFormat, textureType: MTLTextureType, levels: Range<Int>, slices: Range<Int>) {
        isomerDevice = source.isomerDevice
        id = source.isomerDevice.makeID()
        self.textureType = textureType
        self.pixelFormat = pixelFormat
        width = max(source.width >> levels.lowerBound, 1)
        height = max(source.height >> levels.lowerBound, 1)
        depth = source.depth
        mipmapLevelCount = levels.count
        sampleCount = source.sampleCount
        arrayLength = slices.count
        usage = source.usage
        resourceOptions = source.resourceOptions
        storageMode = source.storageMode
        allowGPUOptimizedContents = source.allowGPUOptimizedContents
        parent = source
        parentRelativeLevel = levels.lowerBound
        parentRelativeSlice = slices.lowerBound
        isDrawable = false
        let pending = { (writer: inout MetalCommandWriter) in
            writer.op(.createTextureView)
            writer.int(self.id)
            writer.int(source.id)
            writer.uint(pixelFormat.rawValue)
            writer.uint(textureType.rawValue)
            writer.int(levels.lowerBound)
            writer.int(levels.count)
            writer.int(slices.lowerBound)
            writer.int(slices.count)
        }
        pending(&isomerDevice.pending)
    }

    /// A surface's next texture.
    init(drawableOn device: IsomerDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        isomerDevice = device
        id = device.makeID()
        textureType = .type2D
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
        depth = 1
        mipmapLevelCount = 1
        sampleCount = 1
        arrayLength = 1
        usage = .renderTarget
        resourceOptions = .storageModePrivate
        storageMode = .private
        allowGPUOptimizedContents = true
        parent = nil
        parentRelativeLevel = 0
        parentRelativeSlice = 0
        isDrawable = true
    }

    deinit {
        isomerDevice.destroy(id)
    }

    var device: any MTLDevice { isomerDevice }
    var cpuCacheMode: MTLCPUCacheMode { .defaultCache }
    var hazardTrackingMode: MTLHazardTrackingMode { .tracked }
    var isFramebufferOnly: Bool { isDrawable }
    var buffer: (any MTLBuffer)? { nil }
    var bufferOffset: Int { 0 }
    var bufferBytesPerRow: Int { 0 }
    var allocatedSize: Int { width * height * depth * max(arrayLength, 1) * max(pixelFormat.bytesPerPixel, 1) }

    func setPurgeableState(_ state: MTLPurgeableState) -> MTLPurgeableState {
        .nonVolatile
    }

    func replace(region: MTLRegion, mipmapLevel level: Int, slice: Int, withBytes pixelBytes: UnsafeRawPointer, bytesPerRow: Int, bytesPerImage: Int) {
        let rowBytes = region.size.width * pixelFormat.bytesPerPixel
        let rows = max(region.size.height, 1)
        let images = max(region.size.depth, 1)
        let imageBytes = bytesPerImage > 0 ? bytesPerImage : bytesPerRow * rows
        let count = imageBytes * (images - 1) + bytesPerRow * (rows - 1) + rowBytes
        let pending = { (writer: inout MetalCommandWriter) in
            writer.op(.writeTexture)
            writer.int(self.id)
            writer.int(level)
            writer.int(slice)
            writer.int(region.origin.x)
            writer.int(region.origin.y)
            writer.int(region.origin.z)
            writer.int(region.size.width)
            writer.int(rows)
            writer.int(images)
            writer.int(bytesPerRow)
            writer.int(imageBytes)
            writer.data(UnsafeRawBufferPointer(start: pixelBytes, count: count))
        }
        pending(&isomerDevice.pending)
    }

    func replace(region: MTLRegion, mipmapLevel level: Int, withBytes pixelBytes: UnsafeRawPointer, bytesPerRow: Int) {
        replace(region: region, mipmapLevel: level, slice: 0, withBytes: pixelBytes, bytesPerRow: bytesPerRow, bytesPerImage: 0)
    }

    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, bytesPerImage: Int, from region: MTLRegion, mipmapLevel level: Int, slice: Int) {
        guard let bytes = readback[slice << 8 | level] else { return }
        let bpp = pixelFormat.bytesPerPixel
        let levelWidth = max(width >> level, 1)
        let levelHeight = max(height >> level, 1)
        let sourceRow = levelWidth * bpp
        let rowBytes = region.size.width * bpp
        for z in 0..<max(region.size.depth, 1) {
            for y in 0..<max(region.size.height, 1) {
                let sourceOffset = ((region.origin.z + z) * levelHeight + region.origin.y + y) * sourceRow + region.origin.x * bpp
                let destinationOffset = z * bytesPerImage + y * bytesPerRow
                guard sourceOffset + rowBytes <= bytes.count else { return }
                bytes.withUnsafeBytes { source in
                    (pixelBytes + destinationOffset).copyMemory(from: source.baseAddress! + sourceOffset, byteCount: rowBytes)
                }
            }
        }
    }

    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion, mipmapLevel level: Int) {
        getBytes(pixelBytes, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerRow * max(region.size.height, 1), from: region, mipmapLevel: level, slice: 0)
    }

    func makeTextureView(pixelFormat: MTLPixelFormat) -> (any MTLTexture)? {
        IsomerTexture(view: self, pixelFormat: pixelFormat, textureType: textureType, levels: 0..<mipmapLevelCount, slices: 0..<arrayLength)
    }

    func makeTextureView(pixelFormat: MTLPixelFormat, textureType: MTLTextureType, levels levelRange: Range<Int>, slices sliceRange: Range<Int>) -> (any MTLTexture)? {
        IsomerTexture(view: self, pixelFormat: pixelFormat, textureType: textureType, levels: levelRange, slices: sliceRange)
    }
}

// MARK: States

final class IsomerSamplerState: MTLSamplerState, @unchecked Sendable {
    let isomerDevice: IsomerDevice
    let id: Int32
    let label: String?

    init(device: IsomerDevice, descriptor: MTLSamplerDescriptor) {
        isomerDevice = device
        id = device.makeID()
        label = descriptor.label
        device.pending.op(.createSampler)
        device.pending.int(id)
        device.pending.uint(descriptor.minFilter.rawValue)
        device.pending.uint(descriptor.magFilter.rawValue)
        device.pending.uint(descriptor.mipFilter.rawValue)
        device.pending.uint(descriptor.sAddressMode.rawValue)
        device.pending.uint(descriptor.tAddressMode.rawValue)
        device.pending.uint(descriptor.rAddressMode.rawValue)
        device.pending.int(descriptor.compareFunction == .never ? -1 : Int(descriptor.compareFunction.rawValue))
        device.pending.int(descriptor.maxAnisotropy)
        device.pending.float(descriptor.lodMinClamp)
        device.pending.float(min(descriptor.lodMaxClamp, 32))
        device.pending.bool(descriptor.normalizedCoordinates)
    }

    deinit {
        isomerDevice.destroy(id)
    }

    var device: any MTLDevice { isomerDevice }
}

final class IsomerDepthStencilState: MTLDepthStencilState, @unchecked Sendable {
    let isomerDevice: IsomerDevice
    let label: String?
    let depthCompare: MTLCompareFunction
    let depthWrite: Bool
    let front: MTLStencilDescriptor
    let back: MTLStencilDescriptor

    init(device: IsomerDevice, descriptor: MTLDepthStencilDescriptor) {
        isomerDevice = device
        label = descriptor.label
        depthCompare = descriptor.depthCompareFunction
        depthWrite = descriptor.isDepthWriteEnabled
        front = (descriptor.frontFaceStencil ?? MTLStencilDescriptor()).duplicate()
        back = (descriptor.backFaceStencil ?? MTLStencilDescriptor()).duplicate()
    }

    var device: any MTLDevice { isomerDevice }

    func write(to writer: inout MetalCommandWriter) {
        writer.op(.setDepthStencil)
        writer.uint(depthCompare.rawValue)
        writer.bool(depthWrite)
        for face in [front, back] {
            writer.uint(face.stencilCompareFunction.rawValue)
            writer.uint(face.stencilFailureOperation.rawValue)
            writer.uint(face.depthFailureOperation.rawValue)
            writer.uint(face.depthStencilPassOperation.rawValue)
            writer.word(face.readMask)
            writer.word(face.writeMask)
        }
    }
}

// MARK: Libraries and functions

final class IsomerLibrary: MTLLibrary, @unchecked Sendable {
    let isomerDevice: IsomerDevice
    let entryPoints: [String: TranslatedEntryPoint]
    var label: String?

    init(device: IsomerDevice, entryPoints: [String: TranslatedEntryPoint]) {
        isomerDevice = device
        self.entryPoints = entryPoints
    }

    var device: any MTLDevice { isomerDevice }
    var functionNames: [String] { entryPoints.keys.sorted() }
    var type: MTLLibraryType { .executable }
    var installName: String? { nil }

    func makeFunction(name functionName: String) -> (any MTLFunction)? {
        guard let entryPoint = entryPoints[functionName] else { return nil }
        return IsomerFunction(device: isomerDevice, entryPoint: entryPoint)
    }
}

final class IsomerFunction: MTLFunction, @unchecked Sendable {
    let isomerDevice: IsomerDevice
    let entryPoint: TranslatedEntryPoint
    var label: String?
    /// The backend's shader module, made when a pipeline first uses it.
    private var shaderID: Int32?

    init(device: IsomerDevice, entryPoint: TranslatedEntryPoint) {
        isomerDevice = device
        self.entryPoint = entryPoint
    }

    deinit {
        if let shaderID { isomerDevice.destroy(shaderID) }
    }

    var device: any MTLDevice { isomerDevice }
    var name: String { entryPoint.name }

    var functionType: MTLFunctionType {
        switch entryPoint.stage {
        case .vertex: return .vertex
        case .fragment: return .fragment
        case .kernel: return .kernel
        }
    }

    func shader() -> Int32 {
        if let shaderID { return shaderID }
        let id = isomerDevice.makeID()
        isomerDevice.pending.op(.createShader)
        isomerDevice.pending.int(id)
        isomerDevice.pending.string(entryPoint.wgsl)
        isomerDevice.pending.string(entryPoint.reflectionJSON)
        shaderID = id
        return id
    }

    /// The Metal buffer indices the function writes.
    var writableBufferIndices: [Int] {
        entryPoint.bindings.compactMap { binding in
            if case .storageReadWrite = binding.kind { return binding.metalIndex }
            return nil
        }
    }
}

// MARK: Pipelines

final class IsomerRenderPipelineState: MTLRenderPipelineState, @unchecked Sendable {
    let isomerDevice: IsomerDevice
    let id: Int32
    let label: String?
    let vertexFunction: IsomerFunction
    let fragmentFunction: IsomerFunction?

    init(device: IsomerDevice, descriptor: MTLRenderPipelineDescriptor) throws {
        guard let vertex = descriptor.vertexFunction as? IsomerFunction, vertex.functionType == .vertex else {
            throw RenderPipelineError("a render pipeline needs a vertex function")
        }
        let fragment = descriptor.fragmentFunction as? IsomerFunction
        if descriptor.fragmentFunction != nil, fragment?.functionType != .fragment {
            throw RenderPipelineError("the fragment function is not a fragment function")
        }
        isomerDevice = device
        id = device.makeID()
        label = descriptor.label
        vertexFunction = vertex
        fragmentFunction = fragment

        var json = MetalJSON()
        json.beginObject()
        json.value("vertex", Int(vertex.shader()))
        if let fragment {
            json.value("fragment", Int(fragment.shader()))
        } else {
            json.null("fragment")
        }
        json.beginArray("colors")
        let colorCount = (descriptor.colorAttachments.items.keys.max() ?? -1) + 1
        for index in 0..<colorCount {
            let color = descriptor.colorAttachments.items[index]
            json.beginObject()
            json.value("format", color?.pixelFormat.rawValue ?? 0)
            json.value("blend", color?.isBlendingEnabled ?? false)
            json.value("srcRGB", color?.sourceRGBBlendFactor.rawValue ?? 1)
            json.value("dstRGB", color?.destinationRGBBlendFactor.rawValue ?? 0)
            json.value("opRGB", color?.rgbBlendOperation.rawValue ?? 0)
            json.value("srcAlpha", color?.sourceAlphaBlendFactor.rawValue ?? 1)
            json.value("dstAlpha", color?.destinationAlphaBlendFactor.rawValue ?? 0)
            json.value("opAlpha", color?.alphaBlendOperation.rawValue ?? 0)
            json.value("writeMask", color?.writeMask.rawValue ?? 15)
            json.endObject()
        }
        json.endArray()
        json.value("depthFormat", descriptor.depthAttachmentPixelFormat.rawValue)
        json.value("stencilFormat", descriptor.stencilAttachmentPixelFormat.rawValue)
        json.value("sampleCount", descriptor.rasterSampleCount)
        json.value("alphaToCoverage", descriptor.isAlphaToCoverageEnabled)

        // Vertex fetch: the descriptor's layouts and attributes, checked
        // against the function's [[attribute(n)]] inputs.
        json.beginArray("vertexBuffers")
        let inputs = vertex.entryPoint.vertexInputs
        if !inputs.isEmpty {
            guard let vertexDescriptor = descriptor.vertexDescriptor else {
                throw RenderPipelineError("'\(vertex.name)' takes [[stage_in]] but the pipeline has no vertex descriptor")
            }
            var byBuffer: [Int: [(location: Int, attribute: MTLVertexAttributeDescriptor)]] = [:]
            for input in inputs {
                guard let attribute = vertexDescriptor.attributes.items[input.location], attribute.format != .invalid else {
                    throw RenderPipelineError("the vertex descriptor has no attribute \(input.location) for '\(vertex.name)'")
                }
                byBuffer[attribute.bufferIndex, default: []].append((input.location, attribute))
            }
            for bufferIndex in byBuffer.keys.sorted() {
                let layout = vertexDescriptor.layouts.items[bufferIndex] ?? MTLVertexBufferLayoutDescriptor()
                json.beginObject()
                json.value("index", bufferIndex)
                json.value("stride", layout.stride)
                json.value("step", layout.stepFunction.rawValue)
                json.beginArray("attributes")
                for (location, attribute) in byBuffer[bufferIndex] ?? [] {
                    json.beginObject()
                    json.value("location", location)
                    json.value("format", attribute.format.rawValue)
                    json.value("offset", attribute.offset)
                    json.endObject()
                }
                json.endArray()
                json.endObject()
            }
        }
        json.endArray()
        json.endObject()

        device.pending.op(.createRenderPipeline)
        device.pending.int(id)
        device.pending.string(json.text)
    }

    deinit {
        isomerDevice.destroy(id)
    }

    var device: any MTLDevice { isomerDevice }
    var maxTotalThreadsPerThreadgroup: Int { 0 }
}

final class IsomerComputePipelineState: MTLComputePipelineState, @unchecked Sendable {
    let isomerDevice: IsomerDevice
    let id: Int32
    let label: String?
    let function: IsomerFunction

    init(device: IsomerDevice, function: any MTLFunction, label: String?) throws {
        guard let kernel = function as? IsomerFunction, kernel.functionType == .kernel else {
            throw MTLLibraryError(.functionNotFound, "a compute pipeline needs a kernel function")
        }
        isomerDevice = device
        id = device.makeID()
        self.label = label
        self.function = kernel
        let shader = kernel.shader()
        device.pending.op(.createComputePipeline)
        device.pending.int(id)
        device.pending.int(shader)
    }

    deinit {
        isomerDevice.destroy(id)
    }

    var device: any MTLDevice { isomerDevice }
    var maxTotalThreadsPerThreadgroup: Int { 256 }
    var threadExecutionWidth: Int { 32 }
    var staticThreadgroupMemoryLength: Int { 0 }
}
