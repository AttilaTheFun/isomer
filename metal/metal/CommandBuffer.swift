// Command queues, command buffers and their encoders: each command buffer
// records its passes as encoder commands and, on commit, sends them to the
// backend in one stream, after the device commands waiting and the bytes
// of the buffers it uses that the CPU can write.
//
// Waiting: `waitUntilCompleted()` cannot block in a browser (the GPU's work
// finishes on the page's event loop, which a blocked call would hold), so
// there it returns at once; completed handlers are how to learn of the
// end, as everywhere.

internal import IsomerMetal

/// The stage a binding is for, as the stream carries it.
enum BindingStage: Int32 {
    case vertex = 0
    case fragment = 1
    case compute = 2
}

/// The id a stream's encoder commands use for the bytes of
/// `set…Bytes` (the backend's own buffer, written before the work).
let metalArenaID: Int32 = -2

final class IsomerCommandQueue: MTLCommandQueue, @unchecked Sendable {
    let isomerDevice: IsomerDevice
    var label: String?

    init(device: IsomerDevice) {
        isomerDevice = device
    }

    var device: any MTLDevice { isomerDevice }

    func makeCommandBuffer() -> (any MTLCommandBuffer)? {
        IsomerCommandBuffer(queue: self)
    }

    func makeCommandBufferWithUnretainedReferences() -> (any MTLCommandBuffer)? {
        IsomerCommandBuffer(queue: self)
    }
}

final class IsomerCommandBuffer: MTLCommandBuffer {
    let queue: IsomerCommandQueue
    var label: String?
    private(set) var status: MTLCommandBufferStatus = .notEnqueued
    private(set) var error: (any Error)?
    private(set) var gpuStartTime: CFTimeInterval = 0
    private(set) var gpuEndTime: CFTimeInterval = 0

    var commands = MetalCommandWriter()
    /// `set…Bytes` data, at 256-byte-aligned offsets.
    var arena: [UInt8] = []
    /// What the work uses, kept alive until it completes.
    var buffers: [ObjectIdentifier: IsomerBuffer] = [:]
    var retained: [AnyObject] = []
    /// Buffers the CPU can see that the GPU writes.
    var writtenBuffers: [ObjectIdentifier: IsomerBuffer] = [:]
    /// Textures to read back (synchronize).
    var textureReads: [(texture: IsomerTexture, slice: Int, level: Int)] = []
    private var scheduledHandlers: [MTLCommandBufferHandler] = []
    private var completedHandlers: [MTLCommandBufferHandler] = []
    var encoding = false

    init(queue: IsomerCommandQueue) {
        self.queue = queue
    }

    var isomerDevice: IsomerDevice { queue.isomerDevice }
    var device: any MTLDevice { isomerDevice }
    var commandQueue: any MTLCommandQueue { queue }
    var retainedReferences: Bool { true }
    var kernelStartTime: CFTimeInterval { gpuStartTime }
    var kernelEndTime: CFTimeInterval { gpuEndTime }

    func use(_ buffer: IsomerBuffer) {
        buffers[ObjectIdentifier(buffer)] = buffer
    }

    func written(_ buffer: IsomerBuffer) {
        guard buffer.storageMode != .private else { return }
        writtenBuffers[ObjectIdentifier(buffer)] = buffer
    }

    func retain(_ object: AnyObject) {
        retained.append(object)
    }

    /// Copies `set…Bytes` data into the arena; its offset there.
    func arenaAppend(_ bytes: UnsafeRawPointer, length: Int) -> Int {
        let offset = (arena.count + 255) & ~255
        arena.append(contentsOf: repeatElement(0, count: offset - arena.count))
        arena.append(contentsOf: UnsafeRawBufferPointer(start: bytes, count: length))
        while arena.count % 4 != 0 { arena.append(0) }
        return offset
    }

    func enqueue() {
        if status == .notEnqueued { status = .enqueued }
    }

    func commit() {
        guard status == .notEnqueued || status == .enqueued else { return }
        status = .committed
        let device = isomerDevice
        var stream = device.takePending()
        if !arena.isEmpty {
            stream.op(.writeArena)
            stream.data(arena)
        }
        for buffer in buffers.values where buffer.exposed && buffer.pendingGPUWrites == 0 {
            buffer.writeContents(to: &stream)
        }
        stream.append(commands)
        let written = Array(writtenBuffers.values)
        for buffer in written {
            buffer.pendingGPUWrites += 1
            stream.op(.readBuffer)
            stream.int(buffer.id)
        }
        let reads = textureReads
        for read in reads {
            stream.op(.readTexture)
            stream.int(read.texture.id)
            stream.int(read.slice)
            stream.int(read.level)
        }
        status = .scheduled
        for handler in scheduledHandlers { handler(self) }
        scheduledHandlers = []
        device.backend.perform(stream.bytes) { [self] readback in
            for item in readback.items {
                if let buffer = written.first(where: { $0.id == item.id }) {
                    buffer.receive(item.bytes)
                } else if let read = reads.first(where: { $0.texture.id == item.id && $0.slice == Int(item.slice) && $0.level == Int(item.level) }) {
                    read.texture.readback[read.slice << 8 | read.level] = item.bytes
                }
            }
            for buffer in written { buffer.pendingGPUWrites -= 1 }
            self.status = .completed
            for handler in self.completedHandlers { handler(self) }
            self.completedHandlers = []
            self.buffers = [:]
            self.retained = []
        }
    }

    func addScheduledHandler(_ block: @escaping MTLCommandBufferHandler) {
        if status.rawValue >= MTLCommandBufferStatus.scheduled.rawValue {
            block(self)
        } else {
            scheduledHandlers.append(block)
        }
    }

    func addCompletedHandler(_ block: @escaping MTLCommandBufferHandler) {
        if status == .completed {
            block(self)
        } else {
            completedHandlers.append(block)
        }
    }

    func waitUntilScheduled() {}
    func waitUntilCompleted() {}

    func present(_ drawable: any MTLDrawable) {
        guard let drawable = drawable as? _IsomerSurfaceDrawable else { return }
        commands.op(.present)
        commands.int(drawable.surface)
        commands.int(drawable.isomerTexture.id)
        retain(drawable)
    }

    func present(_ drawable: any MTLDrawable, atTime presentationTime: CFTimeInterval) {
        present(drawable)
    }

    func present(_ drawable: any MTLDrawable, afterMinimumDuration duration: CFTimeInterval) {
        present(drawable)
    }

    func makeRenderCommandEncoder(descriptor renderPassDescriptor: MTLRenderPassDescriptor) -> (any MTLRenderCommandEncoder)? {
        guard !encoding else { return nil }
        return IsomerRenderCommandEncoder(commandBuffer: self, descriptor: renderPassDescriptor)
    }

    func makeComputeCommandEncoder() -> (any MTLComputeCommandEncoder)? {
        makeComputeCommandEncoder(dispatchType: .serial)
    }

    func makeComputeCommandEncoder(dispatchType: MTLDispatchType) -> (any MTLComputeCommandEncoder)? {
        guard !encoding else { return nil }
        return IsomerComputeCommandEncoder(commandBuffer: self, dispatchType: dispatchType)
    }

    func makeBlitCommandEncoder() -> (any MTLBlitCommandEncoder)? {
        guard !encoding else { return nil }
        return IsomerBlitCommandEncoder(commandBuffer: self)
    }

    func pushDebugGroup(_ string: String) {}
    func popDebugGroup() {}
}

// MARK: Encoders

class IsomerCommandEncoder {
    let commandBuffer: IsomerCommandBuffer
    var label: String?

    init(commandBuffer: IsomerCommandBuffer) {
        self.commandBuffer = commandBuffer
        commandBuffer.encoding = true
    }

    var device: any MTLDevice { commandBuffer.isomerDevice }

    func endEncoding() {
        commandBuffer.commands.op(.endEncoding)
        commandBuffer.encoding = false
    }

    func insertDebugSignpost(_ string: String) {}
    func pushDebugGroup(_ string: String) {}
    func popDebugGroup() {}

    /// Buffers bound, by stage and index (for what a draw or dispatch
    /// writes, and for set…BufferOffset).
    var boundBuffers: [Int32: [Int: (buffer: IsomerBuffer?, offset: Int)]] = [:]

    func bindBuffer(_ stage: BindingStage, _ buffer: (any MTLBuffer)?, offset: Int, index: Int) {
        let buffer = buffer as? IsomerBuffer
        boundBuffers[stage.rawValue, default: [:]][index] = (buffer, offset)
        if let buffer { commandBuffer.use(buffer) }
        commandBuffer.commands.op(.setBuffer)
        commandBuffer.commands.int(stage.rawValue)
        commandBuffer.commands.int(index)
        commandBuffer.commands.int(buffer?.id ?? -1)
        commandBuffer.commands.int(offset)
    }

    func bindBufferOffset(_ stage: BindingStage, offset: Int, index: Int) {
        let buffer = boundBuffers[stage.rawValue]?[index]?.buffer
        bindBuffer(stage, buffer, offset: offset, index: index)
    }

    func bindBytes(_ stage: BindingStage, _ bytes: UnsafeRawPointer, length: Int, index: Int) {
        let offset = commandBuffer.arenaAppend(bytes, length: length)
        boundBuffers[stage.rawValue, default: [:]][index] = (nil, offset)
        commandBuffer.commands.op(.setBuffer)
        commandBuffer.commands.int(stage.rawValue)
        commandBuffer.commands.int(index)
        commandBuffer.commands.int(metalArenaID)
        commandBuffer.commands.int(offset)
    }

    func bindTexture(_ stage: BindingStage, _ texture: (any MTLTexture)?, index: Int) {
        let texture = texture as? IsomerTexture
        if let texture { commandBuffer.retain(texture) }
        commandBuffer.commands.op(.setTexture)
        commandBuffer.commands.int(stage.rawValue)
        commandBuffer.commands.int(index)
        commandBuffer.commands.int(texture?.id ?? -1)
    }

    func bindSampler(_ stage: BindingStage, _ sampler: (any MTLSamplerState)?, index: Int) {
        let sampler = sampler as? IsomerSamplerState
        if let sampler { commandBuffer.retain(sampler) }
        commandBuffer.commands.op(.setSampler)
        commandBuffer.commands.int(stage.rawValue)
        commandBuffer.commands.int(index)
        commandBuffer.commands.int(sampler?.id ?? -1)
    }

    /// The buffers a function writes, as bound now.
    func noteWrites(_ stage: BindingStage, _ function: IsomerFunction?) {
        guard let function else { return }
        for index in function.writableBufferIndices {
            if let buffer = boundBuffers[stage.rawValue]?[index]?.buffer {
                commandBuffer.written(buffer)
            }
        }
    }
}

final class IsomerRenderCommandEncoder: IsomerCommandEncoder, MTLRenderCommandEncoder {
    private var pipeline: IsomerRenderPipelineState?

    init(commandBuffer: IsomerCommandBuffer, descriptor: MTLRenderPassDescriptor) {
        super.init(commandBuffer: commandBuffer)
        var writer = MetalCommandWriter()
        writer.op(.beginRenderPass)
        let colorCount = (descriptor.colorAttachments.items.keys.max() ?? -1) + 1
        writer.int(colorCount)
        var targetWidth = descriptor.renderTargetWidth
        var targetHeight = descriptor.renderTargetHeight
        for index in 0..<colorCount {
            let color = descriptor.colorAttachments.items[index]
            let texture = color?.texture as? IsomerTexture
            let resolve = color?.resolveTexture as? IsomerTexture
            if let texture {
                commandBuffer.retain(texture)
                if targetWidth == 0 {
                    targetWidth = max(texture.width >> (color?.level ?? 0), 1)
                    targetHeight = max(texture.height >> (color?.level ?? 0), 1)
                }
            }
            if let resolve { commandBuffer.retain(resolve) }
            writer.int(texture?.id ?? -1)
            writer.int(color?.level ?? 0)
            writer.int(color?.slice ?? 0)
            writer.int(color?.depthPlane ?? 0)
            writer.uint(color?.loadAction.rawValue ?? 0)
            writer.uint(color?.storeAction.rawValue ?? 0)
            let clear = color?.clearColor ?? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            writer.float(clear.red)
            writer.float(clear.green)
            writer.float(clear.blue)
            writer.float(clear.alpha)
            writer.int(resolve?.id ?? -1)
            writer.int(color?.resolveLevel ?? 0)
            writer.int(color?.resolveSlice ?? 0)
        }
        let depth = descriptor.depthAttachment
        let depthTexture = depth?.texture as? IsomerTexture
        if let depthTexture {
            commandBuffer.retain(depthTexture)
            if targetWidth == 0 {
                targetWidth = depthTexture.width
                targetHeight = depthTexture.height
            }
        }
        writer.int(depthTexture?.id ?? -1)
        writer.int(depth?.level ?? 0)
        writer.int(depth?.slice ?? 0)
        writer.uint(depth?.loadAction.rawValue ?? 0)
        writer.uint(depth?.storeAction.rawValue ?? 0)
        writer.float(depth?.clearDepth ?? 1)
        let stencil = descriptor.stencilAttachment
        let stencilTexture = stencil?.texture as? IsomerTexture
        if let stencilTexture { commandBuffer.retain(stencilTexture) }
        writer.int(stencilTexture?.id ?? -1)
        writer.int(stencil?.level ?? 0)
        writer.int(stencil?.slice ?? 0)
        writer.uint(stencil?.loadAction.rawValue ?? 0)
        writer.uint(stencil?.storeAction.rawValue ?? 0)
        writer.word(stencil?.clearStencil ?? 0)
        writer.int(targetWidth)
        writer.int(targetHeight)
        commandBuffer.commands.append(writer)
    }

    func setRenderPipelineState(_ pipelineState: any MTLRenderPipelineState) {
        guard let pipelineState = pipelineState as? IsomerRenderPipelineState else { return }
        pipeline = pipelineState
        commandBuffer.retain(pipelineState)
        commandBuffer.commands.op(.setRenderPipeline)
        commandBuffer.commands.int(pipelineState.id)
    }

    func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        bindBytes(.vertex, bytes, length: length, index: index)
    }

    func setVertexBuffer(_ buffer: (any MTLBuffer)?, offset: Int, index: Int) {
        bindBuffer(.vertex, buffer, offset: offset, index: index)
    }

    func setVertexBufferOffset(_ offset: Int, index: Int) {
        bindBufferOffset(.vertex, offset: offset, index: index)
    }

    func setVertexBuffers(_ buffers: [(any MTLBuffer)?], offsets: [Int], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindBuffer(.vertex, buffers[i], offset: offsets[i], index: index) }
    }

    func setVertexTexture(_ texture: (any MTLTexture)?, index: Int) {
        bindTexture(.vertex, texture, index: index)
    }

    func setVertexTextures(_ textures: [(any MTLTexture)?], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindTexture(.vertex, textures[i], index: index) }
    }

    func setVertexSamplerState(_ sampler: (any MTLSamplerState)?, index: Int) {
        bindSampler(.vertex, sampler, index: index)
    }

    func setVertexSamplerStates(_ samplers: [(any MTLSamplerState)?], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindSampler(.vertex, samplers[i], index: index) }
    }

    func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        bindBytes(.fragment, bytes, length: length, index: index)
    }

    func setFragmentBuffer(_ buffer: (any MTLBuffer)?, offset: Int, index: Int) {
        bindBuffer(.fragment, buffer, offset: offset, index: index)
    }

    func setFragmentBufferOffset(_ offset: Int, index: Int) {
        bindBufferOffset(.fragment, offset: offset, index: index)
    }

    func setFragmentBuffers(_ buffers: [(any MTLBuffer)?], offsets: [Int], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindBuffer(.fragment, buffers[i], offset: offsets[i], index: index) }
    }

    func setFragmentTexture(_ texture: (any MTLTexture)?, index: Int) {
        bindTexture(.fragment, texture, index: index)
    }

    func setFragmentTextures(_ textures: [(any MTLTexture)?], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindTexture(.fragment, textures[i], index: index) }
    }

    func setFragmentSamplerState(_ sampler: (any MTLSamplerState)?, index: Int) {
        bindSampler(.fragment, sampler, index: index)
    }

    func setFragmentSamplerStates(_ samplers: [(any MTLSamplerState)?], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindSampler(.fragment, samplers[i], index: index) }
    }

    func setViewport(_ viewport: MTLViewport) {
        commandBuffer.commands.op(.setViewport)
        commandBuffer.commands.float(viewport.originX)
        commandBuffer.commands.float(viewport.originY)
        commandBuffer.commands.float(viewport.width)
        commandBuffer.commands.float(viewport.height)
        commandBuffer.commands.float(viewport.znear)
        commandBuffer.commands.float(viewport.zfar)
    }

    func setScissorRect(_ rect: MTLScissorRect) {
        commandBuffer.commands.op(.setScissor)
        commandBuffer.commands.int(rect.x)
        commandBuffer.commands.int(rect.y)
        commandBuffer.commands.int(rect.width)
        commandBuffer.commands.int(rect.height)
    }

    func setFrontFacing(_ frontFacingWinding: MTLWinding) {
        commandBuffer.commands.op(.setFrontFacing)
        commandBuffer.commands.uint(frontFacingWinding.rawValue)
    }

    func setCullMode(_ cullMode: MTLCullMode) {
        commandBuffer.commands.op(.setCullMode)
        commandBuffer.commands.uint(cullMode.rawValue)
    }

    /// WebGPU clips depth always (its depth-clip-control feature is
    /// optional): `.clamp` is not done.
    func setDepthClipMode(_ depthClipMode: MTLDepthClipMode) {}

    func setDepthBias(_ depthBias: Float, slopeScale: Float, clamp: Float) {
        commandBuffer.commands.op(.setDepthBias)
        commandBuffer.commands.float(depthBias)
        commandBuffer.commands.float(slopeScale)
        commandBuffer.commands.float(clamp)
    }

    func setTriangleFillMode(_ fillMode: MTLTriangleFillMode) {
        commandBuffer.commands.op(.setTriangleFillMode)
        commandBuffer.commands.uint(fillMode.rawValue)
    }

    func setBlendColor(red: Float, green: Float, blue: Float, alpha: Float) {
        commandBuffer.commands.op(.setBlendColor)
        commandBuffer.commands.float(red)
        commandBuffer.commands.float(green)
        commandBuffer.commands.float(blue)
        commandBuffer.commands.float(alpha)
    }

    func setDepthStencilState(_ depthStencilState: (any MTLDepthStencilState)?) {
        let state = depthStencilState as? IsomerDepthStencilState
            ?? IsomerDepthStencilState(device: commandBuffer.isomerDevice, descriptor: MTLDepthStencilDescriptor())
        state.write(to: &commandBuffer.commands)
    }

    func setStencilReferenceValue(_ referenceValue: UInt32) {
        setStencilReferenceValues(front: referenceValue, back: referenceValue)
    }

    func setStencilReferenceValues(front frontReferenceValue: UInt32, back backReferenceValue: UInt32) {
        commandBuffer.commands.op(.setStencilReference)
        commandBuffer.commands.word(frontReferenceValue)
        commandBuffer.commands.word(backReferenceValue)
    }

    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int) {
        drawPrimitives(type: primitiveType, vertexStart: vertexStart, vertexCount: vertexCount, instanceCount: 1, baseInstance: 0)
    }

    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int) {
        drawPrimitives(type: primitiveType, vertexStart: vertexStart, vertexCount: vertexCount, instanceCount: instanceCount, baseInstance: 0)
    }

    func drawPrimitives(type primitiveType: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int, baseInstance: Int) {
        noteWrites(.fragment, pipeline?.fragmentFunction)
        commandBuffer.commands.op(.draw)
        commandBuffer.commands.uint(primitiveType.rawValue)
        commandBuffer.commands.int(vertexStart)
        commandBuffer.commands.int(vertexCount)
        commandBuffer.commands.int(instanceCount)
        commandBuffer.commands.int(baseInstance)
    }

    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: any MTLBuffer, indexBufferOffset: Int) {
        drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer,
                              indexBufferOffset: indexBufferOffset, instanceCount: 1, baseVertex: 0, baseInstance: 0)
    }

    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: any MTLBuffer, indexBufferOffset: Int, instanceCount: Int) {
        drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer,
                              indexBufferOffset: indexBufferOffset, instanceCount: instanceCount, baseVertex: 0, baseInstance: 0)
    }

    func drawIndexedPrimitives(type primitiveType: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: any MTLBuffer, indexBufferOffset: Int, instanceCount: Int, baseVertex: Int, baseInstance: Int) {
        guard let indexBuffer = indexBuffer as? IsomerBuffer else { return }
        commandBuffer.use(indexBuffer)
        noteWrites(.fragment, pipeline?.fragmentFunction)
        commandBuffer.commands.op(.drawIndexed)
        commandBuffer.commands.uint(primitiveType.rawValue)
        commandBuffer.commands.int(indexCount)
        commandBuffer.commands.uint(indexType.rawValue)
        commandBuffer.commands.int(indexBuffer.id)
        commandBuffer.commands.int(indexBufferOffset)
        commandBuffer.commands.int(instanceCount)
        commandBuffer.commands.int(baseVertex)
        commandBuffer.commands.int(baseInstance)
    }
}

final class IsomerComputeCommandEncoder: IsomerCommandEncoder, MTLComputeCommandEncoder {
    let dispatchType: MTLDispatchType
    private var pipeline: IsomerComputePipelineState?

    init(commandBuffer: IsomerCommandBuffer, dispatchType: MTLDispatchType) {
        self.dispatchType = dispatchType
        super.init(commandBuffer: commandBuffer)
        commandBuffer.commands.op(.beginComputePass)
    }

    func setComputePipelineState(_ state: any MTLComputePipelineState) {
        guard let state = state as? IsomerComputePipelineState else { return }
        pipeline = state
        commandBuffer.retain(state)
        commandBuffer.commands.op(.setComputePipeline)
        commandBuffer.commands.int(state.id)
    }

    func setBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        bindBytes(.compute, bytes, length: length, index: index)
    }

    func setBuffer(_ buffer: (any MTLBuffer)?, offset: Int, index: Int) {
        bindBuffer(.compute, buffer, offset: offset, index: index)
    }

    func setBufferOffset(_ offset: Int, index: Int) {
        bindBufferOffset(.compute, offset: offset, index: index)
    }

    func setBuffers(_ buffers: [(any MTLBuffer)?], offsets: [Int], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindBuffer(.compute, buffers[i], offset: offsets[i], index: index) }
    }

    func setTexture(_ texture: (any MTLTexture)?, index: Int) {
        bindTexture(.compute, texture, index: index)
    }

    func setTextures(_ textures: [(any MTLTexture)?], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindTexture(.compute, textures[i], index: index) }
    }

    func setSamplerState(_ sampler: (any MTLSamplerState)?, index: Int) {
        bindSampler(.compute, sampler, index: index)
    }

    func setSamplerStates(_ samplers: [(any MTLSamplerState)?], range: Range<Int>) {
        for (i, index) in range.enumerated() { bindSampler(.compute, samplers[i], index: index) }
    }

    func dispatchThreadgroups(_ threadgroupsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        dispatch(groups: threadgroupsPerGrid, threads: threadsPerThreadgroup, grid: MTLSize(
            width: threadgroupsPerGrid.width * threadsPerThreadgroup.width,
            height: threadgroupsPerGrid.height * threadsPerThreadgroup.height,
            depth: threadgroupsPerGrid.depth * threadsPerThreadgroup.depth))
    }

    func dispatchThreads(_ threadsPerGrid: MTLSize, threadsPerThreadgroup: MTLSize) {
        func groups(_ total: Int, _ size: Int) -> Int { (total + max(size, 1) - 1) / max(size, 1) }
        dispatch(groups: MTLSize(
            width: groups(threadsPerGrid.width, threadsPerThreadgroup.width),
            height: groups(threadsPerGrid.height, threadsPerThreadgroup.height),
            depth: groups(threadsPerGrid.depth, threadsPerThreadgroup.depth)),
                 threads: threadsPerThreadgroup, grid: threadsPerGrid)
    }

    private func dispatch(groups: MTLSize, threads: MTLSize, grid: MTLSize) {
        noteWrites(.compute, pipeline?.function)
        commandBuffer.commands.op(.dispatch)
        for value in [groups.width, groups.height, groups.depth, threads.width, threads.height, threads.depth,
                      grid.width, grid.height, grid.depth] {
            commandBuffer.commands.int(value)
        }
    }
}

final class IsomerBlitCommandEncoder: IsomerCommandEncoder, MTLBlitCommandEncoder {
    override init(commandBuffer: IsomerCommandBuffer) {
        super.init(commandBuffer: commandBuffer)
        commandBuffer.commands.op(.beginBlitPass)
    }

    func copy(from sourceBuffer: any MTLBuffer, sourceOffset: Int, to destinationBuffer: any MTLBuffer, destinationOffset: Int, size: Int) {
        guard let source = sourceBuffer as? IsomerBuffer, let destination = destinationBuffer as? IsomerBuffer else { return }
        commandBuffer.use(source)
        commandBuffer.use(destination)
        commandBuffer.written(destination)
        let c = commandBuffer
        c.commands.op(.copyBufferToBuffer)
        c.commands.int(source.id)
        c.commands.int(sourceOffset)
        c.commands.int(destination.id)
        c.commands.int(destinationOffset)
        c.commands.int(size)
    }

    func copy(from sourceBuffer: any MTLBuffer, sourceOffset: Int, sourceBytesPerRow: Int, sourceBytesPerImage: Int, sourceSize: MTLSize, to destinationTexture: any MTLTexture, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MTLOrigin) {
        guard let source = sourceBuffer as? IsomerBuffer, let destination = destinationTexture as? IsomerTexture else { return }
        commandBuffer.use(source)
        commandBuffer.retain(destination)
        let c = commandBuffer
        c.commands.op(.copyBufferToTexture)
        for value in [Int(source.id), sourceOffset, sourceBytesPerRow, sourceBytesPerImage, sourceSize.width, sourceSize.height,
                      sourceSize.depth, Int(destination.id), destinationSlice, destinationLevel, destinationOrigin.x,
                      destinationOrigin.y, destinationOrigin.z] {
            c.commands.int(value)
        }
    }

    func copy(from sourceTexture: any MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize, to destinationBuffer: any MTLBuffer, destinationOffset: Int, destinationBytesPerRow: Int, destinationBytesPerImage: Int) {
        guard let source = sourceTexture as? IsomerTexture, let destination = destinationBuffer as? IsomerBuffer else { return }
        commandBuffer.retain(source)
        commandBuffer.use(destination)
        commandBuffer.written(destination)
        let c = commandBuffer
        c.commands.op(.copyTextureToBuffer)
        for value in [Int(source.id), sourceSlice, sourceLevel, sourceOrigin.x, sourceOrigin.y, sourceOrigin.z, sourceSize.width,
                      sourceSize.height, sourceSize.depth, Int(destination.id), destinationOffset, destinationBytesPerRow,
                      destinationBytesPerImage] {
            c.commands.int(value)
        }
    }

    func copy(from sourceTexture: any MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize, to destinationTexture: any MTLTexture, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MTLOrigin) {
        guard let source = sourceTexture as? IsomerTexture, let destination = destinationTexture as? IsomerTexture else { return }
        commandBuffer.retain(source)
        commandBuffer.retain(destination)
        let c = commandBuffer
        c.commands.op(.copyTextureToTexture)
        for value in [Int(source.id), sourceSlice, sourceLevel, sourceOrigin.x, sourceOrigin.y, sourceOrigin.z, sourceSize.width,
                      sourceSize.height, sourceSize.depth, Int(destination.id), destinationSlice, destinationLevel,
                      destinationOrigin.x, destinationOrigin.y, destinationOrigin.z] {
            c.commands.int(value)
        }
    }

    func copy(from sourceTexture: any MTLTexture, to destinationTexture: any MTLTexture) {
        let levels = min(sourceTexture.mipmapLevelCount, destinationTexture.mipmapLevelCount)
        let slices = min(sourceTexture.arrayLength, destinationTexture.arrayLength)
        for slice in 0..<slices {
            for level in 0..<levels {
                let size = MTLSize(width: max(sourceTexture.width >> level, 1), height: max(sourceTexture.height >> level, 1),
                                   depth: max(sourceTexture.depth >> level, 1))
                copy(from: sourceTexture, sourceSlice: slice, sourceLevel: level, sourceOrigin: MTLOrigin(), sourceSize: size,
                     to: destinationTexture, destinationSlice: slice, destinationLevel: level, destinationOrigin: MTLOrigin())
            }
        }
    }

    func fill(buffer: any MTLBuffer, range: Range<Int>, value: UInt8) {
        guard let buffer = buffer as? IsomerBuffer else { return }
        commandBuffer.use(buffer)
        commandBuffer.written(buffer)
        let c = commandBuffer
        c.commands.op(.fillBuffer)
        c.commands.int(buffer.id)
        c.commands.int(range.lowerBound)
        c.commands.int(range.count)
        c.commands.int(Int(value))
    }

    func generateMipmaps(for texture: any MTLTexture) {
        guard let texture = texture as? IsomerTexture else { return }
        commandBuffer.retain(texture)
        commandBuffer.commands.op(.generateMipmaps)
        commandBuffer.commands.int(texture.id)
    }

    func synchronize(resource: any MTLResource) {
        if let texture = resource as? IsomerTexture {
            for slice in 0..<max(texture.arrayLength, 1) {
                for level in 0..<max(texture.mipmapLevelCount, 1) {
                    synchronize(texture: texture, slice: slice, level: level)
                }
            }
        } else if let buffer = resource as? IsomerBuffer {
            commandBuffer.use(buffer)
            commandBuffer.written(buffer)
        }
    }

    func synchronize(texture: any MTLTexture, slice: Int, level: Int) {
        guard let texture = texture as? IsomerTexture, texture.pixelFormat.bytesPerPixel > 0 else { return }
        commandBuffer.retain(texture)
        commandBuffer.textureReads.append((texture, slice, level))
    }

    func optimizeContentsForGPUAccess(texture: any MTLTexture) {}
    func optimizeContentsForCPUAccess(texture: any MTLTexture) {}
}

// MARK: Surfaces

/// A surface's drawable: the texture to draw a frame into, presented by a
/// command buffer. Isomer's platform layers (IsomerMetalWeb's
/// IsomerMetalLayer) make them.
package final class _IsomerSurfaceDrawable: MTLDrawable {
    public let surface: Int32
    let isomerTexture: IsomerTexture
    private var presentedHandlers: [MTLDrawablePresentedHandler] = []
    public private(set) var presentedTime: CFTimeInterval = 0
    public let drawableID: Int

    init(surface: Int32, texture: IsomerTexture, drawableID: Int) {
        self.surface = surface
        isomerTexture = texture
        self.drawableID = drawableID
    }

    public var texture: any MTLTexture { isomerTexture }

    /// A browser presents a canvas's frame when the page's task ends.
    public func present() {}
    public func present(at presentationTime: CFTimeInterval) {}
    public func present(afterMinimumDuration duration: CFTimeInterval) {}

    public func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {
        presentedHandlers.append(block)
    }
}

nonisolated(unsafe) private var nextDrawableID = 0

/// The surface's next drawable, sized as the backend says the surface is
/// now; nil when the device is not Isomer's or the surface is gone.
package func _isomerNextDrawable(device: any MTLDevice, surface: Int32, pixelFormat: MTLPixelFormat) -> _IsomerSurfaceDrawable? {
    guard let device = device as? IsomerDevice, let size = device.backend.drawableSize(surface: surface),
          size.width > 0, size.height > 0 else { return nil }
    let texture = IsomerTexture(drawableOn: device, width: size.width, height: size.height, pixelFormat: pixelFormat)
    device.pending.op(.acquireDrawable)
    device.pending.int(surface)
    device.pending.int(texture.id)
    device.pending.uint(pixelFormat.rawValue)
    nextDrawableID += 1
    return _IsomerSurfaceDrawable(surface: surface, texture: texture, drawableID: nextDrawableID)
}
