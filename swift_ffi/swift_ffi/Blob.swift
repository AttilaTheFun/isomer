// The Swift half of the erased wire encoding ("blob") shared by every bridge
// — see swift_abi.h for the format. Little-endian, self-contained, and
// SELF-DESCRIBING: structs and interface handles carry their type NAME on the
// wire, so no generation-time ordinal tables exist anywhere. Generic
// arguments, container values (Result/Array/Dictionary), struct copies,
// interface method arguments, closure arguments, and Lazy payloads all cross
// the boundary in this encoding.

import SwiftABI

public enum SwiftFFIBlob {
    // Tags mirror bridge_tag in swift_abi.h.
    public enum Tag {
        public static let void: Int32 = 0
        public static let int: Int32 = 1
        public static let int32: Int32 = 2
        public static let double: Int32 = 3
        public static let bool: Int32 = 4
        public static let string: Int32 = 5
        public static let bytes: Int32 = 6
        public static let structure: Int32 = 7
        public static let list: Int32 = 8
        public static let handle: Int32 = 9
        public static let error: Int32 = 10
        public static let foreign: Int32 = 11
    }

    // MARK: - Encoding

    /// Encodes a value into its self-contained wire form.
    public static func encode(_ value: BridgeValue) -> [UInt8] {
        var out: [UInt8] = []
        append(value, to: &out)
        return out
    }

    /// The leading tag of a blob (nil when too short to carry a header).
    public static func tag(of bytes: [UInt8]) -> Int32? {
        guard bytes.count >= 4 else { return nil }
        return Int32(bytes[0]) | Int32(bytes[1]) << 8 | Int32(bytes[2]) << 16 | Int32(bytes[3]) << 24
    }

    /// Encodes an error message as an ERROR blob.
    public static func encodeError(_ message: String) -> [UInt8] {
        var out: [UInt8] = []
        appendI32(Tag.error, &out)
        appendI32(0, &out)
        let bytes = Array(message.utf8)
        appendI64(Int64(bytes.count), &out)
        out.append(contentsOf: bytes)
        return out
    }

    private static func append(_ value: BridgeValue, to out: inout [UInt8]) {
        switch value {
        case .void:
            appendI32(Tag.void, &out)
            appendI32(0, &out)
        case .int(let v):
            appendI32(Tag.int, &out)
            appendI32(0, &out)
            appendI64(Int64(v), &out)
        case .int32(let v):
            appendI32(Tag.int32, &out)
            appendI32(0, &out)
            appendI64(Int64(v), &out)
        case .double(let v):
            appendI32(Tag.double, &out)
            appendI32(0, &out)
            appendI64(Int64(bitPattern: v.bitPattern), &out)
        case .bool(let v):
            appendI32(Tag.bool, &out)
            appendI32(0, &out)
            appendI64(v ? 1 : 0, &out)
        case .string(let v):
            let bytes = Array(v.utf8)
            appendI32(Tag.string, &out)
            appendI32(0, &out)
            appendI64(Int64(bytes.count), &out)
            out.append(contentsOf: bytes)
        case .bytes(let bytes):
            appendI32(Tag.bytes, &out)
            appendI32(0, &out)
            appendI64(Int64(bytes.count), &out)
            out.append(contentsOf: bytes)
        case .structure(let name, let fields):
            let nameBytes = Array(name.utf8)
            appendI32(Tag.structure, &out)
            appendI32(Int32(nameBytes.count), &out)
            out.append(contentsOf: nameBytes)
            appendI64(Int64(fields.count), &out)
            for field in fields {
                append(field, to: &out)
            }
        case .list(let items):
            appendI32(Tag.list, &out)
            appendI32(0, &out)
            appendI64(Int64(items.count), &out)
            for item in items {
                append(item, to: &out)
            }
        case .handle(let bits, let interface):
            let nameBytes = Array(interface.utf8)
            appendI32(Tag.handle, &out)
            appendI32(Int32(nameBytes.count), &out)
            out.append(contentsOf: nameBytes)
            appendI64(Int64(bitPattern: bits), &out)
        case .foreign(let bits, let interface):
            let nameBytes = Array(interface.utf8)
            appendI32(Tag.foreign, &out)
            appendI32(Int32(nameBytes.count), &out)
            out.append(contentsOf: nameBytes)
            appendI64(Int64(bitPattern: bits), &out)
        }
    }

    // MARK: - Decoding

    /// Decodes one blob.
    public static func decode(_ bytes: [UInt8]) throws -> BridgeValue {
        var cursor = 0
        return try read(bytes, &cursor)
    }

    /// Decodes a borrowed (pointer, length) parameter.
    public static func decode(_ pointer: UnsafeRawPointer?, _ length: Int32) throws -> BridgeValue {
        try decode(SwiftFFIBridge.bytes(pointer, length))
    }

    /// Decodes a *sequence* of blobs (closure / interface-method argument lists).
    public static func decodeSequence(_ bytes: [UInt8]) throws -> [BridgeValue] {
        var cursor = 0
        var values: [BridgeValue] = []
        while cursor < bytes.count {
            values.append(try read(bytes, &cursor))
        }
        return values
    }

    private static func read(_ bytes: [UInt8], _ cursor: inout Int) throws -> BridgeValue {
        let tag = try readI32(bytes, &cursor)
        let aux = try readI32(bytes, &cursor)
        switch tag {
        case Tag.void:
            return .void
        case Tag.int:
            return .int(Int(try readI64(bytes, &cursor)))
        case Tag.int32:
            return .int32(Int32(truncatingIfNeeded: try readI64(bytes, &cursor)))
        case Tag.double:
            return .double(Double(bitPattern: UInt64(bitPattern: try readI64(bytes, &cursor))))
        case Tag.bool:
            return .bool(try readI64(bytes, &cursor) != 0)
        case Tag.string, Tag.error:
            let count = Int(try readI64(bytes, &cursor))
            let value = String(decoding: try readBytes(bytes, &cursor, count), as: UTF8.self)
            return .string(value)
        case Tag.bytes:
            let count = Int(try readI64(bytes, &cursor))
            return .bytes(try readBytes(bytes, &cursor, count))
        case Tag.structure:
            let name = String(decoding: try readBytes(bytes, &cursor, Int(aux)), as: UTF8.self)
            let count = Int(try readI64(bytes, &cursor))
            var fields: [BridgeValue] = []
            fields.reserveCapacity(count)
            for _ in 0..<count {
                fields.append(try read(bytes, &cursor))
            }
            return .structure(name: name, fields: fields)
        case Tag.list:
            let count = Int(try readI64(bytes, &cursor))
            var items: [BridgeValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                items.append(try read(bytes, &cursor))
            }
            return .list(items)
        case Tag.handle:
            let name = String(decoding: try readBytes(bytes, &cursor, Int(aux)), as: UTF8.self)
            let bits = UInt64(bitPattern: try readI64(bytes, &cursor))
            return .handle(bits: bits, interface: name)
        case Tag.foreign:
            let name = String(decoding: try readBytes(bytes, &cursor, Int(aux)), as: UTF8.self)
            let bits = UInt64(bitPattern: try readI64(bytes, &cursor))
            return .foreign(bits: bits, interface: name)
        default:
            throw BridgeDecodingError("unknown blob tag \(tag)")
        }
    }

    // MARK: - Generic binding

    /// Binds an erased value to a concrete `Bridgeable` so an
    /// implicitly-opened existential can infer a generic parameter. Composite
    /// values bind OPAQUELY (`BridgeList` / `BridgeStruct` carriers): generic
    /// code only sees the `Bridgeable` constraint, and the carriers re-encode
    /// byte-identically.
    public static func bindAny(_ value: BridgeValue) throws -> any Bridgeable {
        switch value {
        case .int(let v): return v
        case .int32(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .string(let v): return v
        case .bytes(let v): return v
        case .structure(let name, let fields): return BridgeStruct(name: name, fields: fields)
        case .list(let items): return BridgeList(items: items)
        default:
            throw BridgeDecodingError("cannot bind a generic parameter to \(value)")
        }
    }

    /// If the blob is an ERROR blob, its message.
    public static func errorMessage(of bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        let tag = bytes.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) }
        guard tag == Tag.error else { return nil }
        if case .string(let message) = try? decode(bytes) { return message }
        return "bridged call failed"
    }

    // MARK: - Primitives

    private static func appendI32(_ value: Int32, _ out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    private static func appendI64(_ value: Int64, _ out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    private static func readI32(_ bytes: [UInt8], _ cursor: inout Int) throws -> Int32 {
        let slice = try readBytes(bytes, &cursor, 4)
        return slice.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) }
    }

    private static func readI64(_ bytes: [UInt8], _ cursor: inout Int) throws -> Int64 {
        let slice = try readBytes(bytes, &cursor, 8)
        return slice.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
    }

    private static func readBytes(
        _ bytes: [UInt8], _ cursor: inout Int, _ count: Int
    ) throws -> [UInt8] {
        guard count >= 0, cursor + count <= bytes.count else {
            throw BridgeDecodingError("blob truncated")
        }
        defer { cursor += count }
        return Array(bytes[cursor..<cursor + count])
    }
}

// MARK: - Dispatch

/// The uniform callback channel: closures, consumer-implemented interfaces,
/// and injected dependencies all cross as a dispatcher the expanded ABI
/// invokes with blob-encoded arguments (interface method calls lead with an
/// `.int32` method ordinal).
public protocol SwiftFFIDispatcher: AnyObject {
    func invoke(_ args: [UInt8]) throws -> [UInt8]
}

// MARK: - Boxes

/// Boxes a deferred value crossing out as a `Lazy` handle: computing (and
/// encoding) happens only when the consumer first asks.
public final class SwiftFFILazyBox {
    private let compute: () -> [UInt8]

    public init(_ compute: @escaping () -> [UInt8]) {
        self.compute = compute
    }

    public func bytes() -> [UInt8] { compute() }
}

/// Owns a copied native `bridge_closure` vtable: retains the consumer context
/// on capture, releases exactly once when ARC drops the box, and invokes with
/// blob-encoded arguments. Macro expansions construct it through the
/// raw-pointer initializer (they cannot import the `SwiftABI` clang module;
/// the C type stays behind this boundary).
public final class SwiftFFIClosureBox: SwiftFFIDispatcher, @unchecked Sendable {
    private let closure: bridge_closure

    public init(copying pointer: UnsafePointer<bridge_closure>) {
        self.closure = pointer.pointee
        closure.retain?(closure.ctx)
    }

    /// The macro-expansion entry point: `pointer` is a `const bridge_closure *`
    /// that crossed the C ABI as an untyped pointer.
    public convenience init(copyingRaw pointer: UnsafeRawPointer) {
        self.init(copying: pointer.assumingMemoryBound(to: bridge_closure.self))
    }

    deinit {
        closure.release?(closure.ctx)
    }

    /// Invokes the consumer closure with a concatenated argument-blob
    /// sequence; returns the result blob, or throws `BridgeError` with the
    /// consumer's error message.
    public func invoke(_ args: [UInt8]) throws -> [UInt8] {
        var result = bridge_buf(ptr: nil, len: 0)
        var error = bridge_buf(ptr: nil, len: 0)
        args.withUnsafeBytes { raw in
            closure.invoke?(closure.ctx, raw.baseAddress, Int64(raw.count), &result, &error)
        }
        if let errorPtr = error.ptr {
            defer { bridge_free(errorPtr) }
            let bytes = Array(UnsafeRawBufferPointer(start: errorPtr, count: Int(error.len)))
            if case .string(let message) = try? SwiftFFIBlob.decode(bytes) {
                throw BridgeError(message)
            }
            throw BridgeError("closure failed")
        }
        guard let resultPtr = result.ptr else { return [] }
        defer { bridge_free(resultPtr) }
        let bytes = Array(UnsafeRawBufferPointer(start: resultPtr, count: Int(result.len)))
        // A dispatcher may also answer with an ERROR blob in the result slot.
        if let message = SwiftFFIBlob.errorMessage(of: bytes) {
            throw BridgeError(message)
        }
        return bytes
    }
}
