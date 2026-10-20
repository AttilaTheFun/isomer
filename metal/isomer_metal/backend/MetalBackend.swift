// What Isomer's `Metal` runs on. A `Metal` device records everything it is
// asked to do (resources made, written and destroyed; command buffers'
// passes, draws, dispatches and copies) as a stream of commands in the
// format of MetalCommands.swift, and hands each stream to a backend, which
// performs it on the GPU API it has. In a browser that is WebGPU
// (IsomerMetalWeb, over swift_ffi to its JavaScript executor); a native
// Metal backend for wasm inside an Apple app, and WebGPU through
// wgpu-native or Dawn for Android, Windows and Linux, are the plan.
//
// The stream carries Metal's own values (pixel formats, blend factors,
// load actions by their raw values), so a backend translates from Metal and
// the device needs to know nothing of it.

public protocol MetalBackend: AnyObject {
    /// The GPU's name, for `MTLDevice.name`.
    var name: String { get }

    /// Performs a stream of commands, in order after the streams before
    /// it. `completion` is called once the GPU has finished the stream's
    /// work, with what the stream asked to read back (MetalReadback); a
    /// stream that only makes resources passes nil.
    func perform(_ commands: [UInt8], completion: ((MetalReadback) -> Void)?)

    /// The size in pixels of a surface's next drawable (the canvas it
    /// draws to), or nil when the surface is gone.
    func drawableSize(surface: Int32) -> (width: Int, height: Int)?
}

/// The backend `MTLCreateSystemDefaultDevice()` uses: set by the platform
/// when its GPU is ready (the web's `metalConnect`), nil before.
nonisolated(unsafe) public var currentMetalBackend: (any MetalBackend)?

/// What a stream read back: buffers' and textures' bytes after its work.
public struct MetalReadback: Sendable {
    public struct Item: Sendable {
        public var id: Int32
        /// For a texture: the slice and mipmap level read; 0 for a buffer.
        public var slice: Int32
        public var level: Int32
        public var bytes: [UInt8]
    }

    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    /// The readback's wire format (the executor's): per item, kind (1
    /// buffer, 2 texture), id, slice, level, byte count, the bytes padded
    /// to four; all little-endian 32-bit.
    public init(decoding bytes: [UInt8]) {
        var items: [Item] = []
        var offset = 0
        func word() -> Int32 {
            guard offset + 4 <= bytes.count else { offset = bytes.count; return 0 }
            let value = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return Int32(bitPattern: value)
        }
        while offset + 20 <= bytes.count {
            _ = word()
            let id = word(), slice = word(), level = word(), count = Int(word())
            let end = min(offset + count, bytes.count)
            items.append(Item(id: id, slice: slice, level: level, bytes: Array(bytes[offset..<end])))
            offset += (count + 3) & ~3
        }
        self.items = items
    }
}
