// The command stream a `Metal` device hands its backend: a sequence of
// commands, each a 32-bit opcode and its operands, every value a
// little-endian 32-bit word (integers, or floats as their bits). Bytes and
// strings are a word with their count and then the bytes, padded to four.
// Enumerations travel as Metal's raw values.
//
// Two kinds of command share the stream. Device commands (1-19) make,
// write and destroy resources and take effect in order as the stream is
// read. Encoder commands (20 and up) are a command buffer's work: the
// backend records them, from the first `begin…` to the end of the stream,
// and submits them as one unit of GPU work.
//
// The JavaScript executor (metal/runtime/isomer_metal_webgpu.js) reads the
// same format; keep the two in step.

public enum MetalOpcode: UInt32, Sendable {
    // Device
    /// id, length, storage mode
    case createBuffer = 1
    /// id, offset, bytes
    case writeBuffer = 2
    /// id, texture type, pixel format, width, height, depth, array length,
    /// mipmap levels, sample count, usage
    case createTexture = 3
    /// id, level, slice, x, y, z, width, height, depth, bytes per row,
    /// bytes per image, bytes
    case writeTexture = 4
    /// id, min, mag, mip filter, s, t, r address, compare (-1: none),
    /// max anisotropy, lod min clamp (float), lod max clamp (float),
    /// normalized coordinates
    case createSampler = 5
    /// id, WGSL (string), reflection JSON (string)
    case createShader = 6
    /// id, descriptor JSON (string): see RenderPipelineJSON in Metal
    case createRenderPipeline = 7
    /// id, shader id, threadgroup width, height, depth (0: from dispatch)
    case createComputePipeline = 8
    /// id
    case destroy = 9
    /// id, source id, pixel format, texture type, first level, level
    /// count, first slice, slice count
    case createTextureView = 10
    /// bytes: the stream's `set…Bytes` data, which encoder commands use
    /// as buffer id -2 at the offsets they give
    case writeArena = 11

    // Render pass
    /// color count; per color: texture, level, slice, depth plane, load,
    /// store, red, green, blue, alpha (floats), resolve texture, resolve
    /// level, resolve slice; then depth: texture (-1: none), level, slice,
    /// load, store, clear depth (float); stencil: texture, level, slice,
    /// load, store, clear stencil; then render target width, height
    case beginRenderPass = 20
    case endEncoding = 21
    /// pipeline id
    case setRenderPipeline = 22
    /// stage (0 vertex, 1 fragment, 2 compute), index, buffer id, offset
    case setBuffer = 23
    /// stage, index, texture id
    case setTexture = 24
    /// stage, index, sampler id
    case setSampler = 25
    /// x, y, width, height, znear, zfar (floats)
    case setViewport = 26
    /// x, y, width, height
    case setScissor = 27
    /// cull mode
    case setCullMode = 28
    /// winding
    case setFrontFacing = 29
    /// depth compare, depth write; front and back: compare, stencil
    /// failure, depth failure, pass, read mask, write mask
    case setDepthStencil = 30
    /// red, green, blue, alpha (floats)
    case setBlendColor = 31
    /// front, back
    case setStencilReference = 32
    /// primitive, vertex start, vertex count, instance count, base instance
    case draw = 33
    /// primitive, index count, index type, index buffer, index offset,
    /// instance count, base vertex, base instance
    case drawIndexed = 34
    /// depth bias, slope scale, clamp (floats)
    case setDepthBias = 35
    /// mode (0 fill, 1 lines)
    case setTriangleFillMode = 36

    // Compute pass
    case beginComputePass = 40
    /// pipeline id
    case setComputePipeline = 41
    /// threadgroups x, y, z; threads per threadgroup x, y, z; threads in
    /// the grid x, y, z
    case dispatch = 42

    // Blit pass
    case beginBlitPass = 50
    /// source, source offset, destination, destination offset, size
    case copyBufferToBuffer = 51
    /// buffer, offset, bytes per row, bytes per image, width, height,
    /// depth, texture, slice, level, x, y, z
    case copyBufferToTexture = 52
    /// texture, slice, level, x, y, z, width, height, depth, buffer,
    /// offset, bytes per row, bytes per image
    case copyTextureToBuffer = 53
    /// source, slice, level, x, y, z, width, height, depth, destination,
    /// slice, level, x, y, z
    case copyTextureToTexture = 54
    /// buffer, offset, length, value
    case fillBuffer = 55
    /// texture
    case generateMipmaps = 56

    // After the work
    /// buffer id: read it back once the work is done
    case readBuffer = 60
    /// texture id, slice, level
    case readTexture = 61

    // Surfaces
    /// surface, texture id, pixel format: the id names the surface's next
    /// texture (configured for that format)
    case acquireDrawable = 70
    /// surface, texture id
    case present = 71
}

/// Writes a command stream.
public struct MetalCommandWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var isEmpty: Bool { bytes.isEmpty }

    public mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ other: MetalCommandWriter) {
        bytes.append(contentsOf: other.bytes)
    }

    public mutating func op(_ opcode: MetalOpcode) {
        word(opcode.rawValue)
    }

    public mutating func word(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    public mutating func int(_ value: Int) {
        word(UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
    }

    public mutating func int(_ value: Int32) {
        word(UInt32(bitPattern: value))
    }

    public mutating func uint(_ value: UInt) {
        word(UInt32(truncatingIfNeeded: value))
    }

    public mutating func float(_ value: Float) {
        word(value.bitPattern)
    }

    public mutating func float(_ value: Double) {
        word(Float(value).bitPattern)
    }

    public mutating func bool(_ value: Bool) {
        word(value ? 1 : 0)
    }

    public mutating func data(_ data: UnsafeRawBufferPointer) {
        int(data.count)
        bytes.append(contentsOf: data)
        pad()
    }

    public mutating func data(_ data: [UInt8]) {
        int(data.count)
        bytes.append(contentsOf: data)
        pad()
    }

    public mutating func string(_ string: String) {
        data(Array(string.utf8))
    }

    private mutating func pad() {
        while bytes.count % 4 != 0 { bytes.append(0) }
    }
}

/// A small JSON writer for the descriptors the stream carries as JSON.
public struct MetalJSON: Sendable {
    public private(set) var text = ""
    private var needsComma = [false]

    public init() {}

    private mutating func separator() {
        if needsComma[needsComma.count - 1] { text += "," }
        needsComma[needsComma.count - 1] = true
    }

    private mutating func key(_ name: String?) {
        separator()
        if let name { text += jsonString(name) + ":" }
    }

    public mutating func beginObject(_ name: String? = nil) {
        key(name)
        text += "{"
        needsComma.append(false)
    }

    public mutating func endObject() {
        needsComma.removeLast()
        text += "}"
    }

    public mutating func beginArray(_ name: String? = nil) {
        key(name)
        text += "["
        needsComma.append(false)
    }

    public mutating func endArray() {
        needsComma.removeLast()
        text += "]"
    }

    public mutating func value(_ name: String? = nil, _ value: Int) {
        key(name)
        text += String(value)
    }

    public mutating func value(_ name: String? = nil, _ value: UInt) {
        key(name)
        text += String(value)
    }

    public mutating func value(_ name: String? = nil, _ value: Bool) {
        key(name)
        text += value ? "true" : "false"
    }

    public mutating func value(_ name: String? = nil, _ value: String) {
        key(name)
        text += jsonString(value)
    }

    public mutating func null(_ name: String? = nil) {
        key(name)
        text += "null"
    }
}
