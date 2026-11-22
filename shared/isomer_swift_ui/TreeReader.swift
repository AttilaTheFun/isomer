// The render tree as a reader sees it (Apple's tree view, the GPU renderer's
// decoder, the headless host, the tests): the wire format's messages
// (shared/wire/tree.proto's, generated as it builds) with an optional where
// a field may be absent, under the names the tree's readers have always used
// (IsoFlat_*, from when the wire format was FlatBuffers).

import SwiftProtobuf
// tree.proto's messages: generated into this module by swift-protobuf's
// plugin in a SwiftPM build; a module of their own under Bazel
// (//shared/wire:tree_messages), re-exported, so `import IsomerSwiftUI` gives
// them either way.
#if canImport(IsomerTreeMessages)
@_exported import IsomerTreeMessages
#endif

/// A tree (or a patch) that doesn't parse as the wire format's message.
public struct IsoFlatDecodingError: Error {}

public enum IsoFlat_Kind: UInt8, Sendable {
    case box = 0, text, shape, stack, spacer, divider, scroll, image, textfield, slider, gradient, hostview,
        progress, presentation

    init(_ wire: Wire_Kind) { self = IsoFlat_Kind(rawValue: UInt8(clamping: wire.rawValue)) ?? .box }
    public var wire: Wire_Kind { Wire_Kind(rawValue: Int(rawValue)) ?? .box }
}

public enum IsoFlat_Axis: UInt8, Sendable {
    case horizontal = 0, vertical, depth

    init(_ wire: Wire_Axis) { self = IsoFlat_Axis(rawValue: UInt8(clamping: wire.rawValue)) ?? .horizontal }
    public var wire: Wire_Axis { Wire_Axis(rawValue: Int(rawValue)) ?? .horizontal }
}

/// Leading/top, center, trailing/bottom (per the node's axis).
public enum IsoFlat_Align: UInt8, Sendable {
    case start = 0, center, end

    init(_ wire: Wire_Align) { self = IsoFlat_Align(rawValue: UInt8(clamping: wire.rawValue)) ?? .start }
    public var wire: Wire_Align { Wire_Align(rawValue: Int(rawValue)) ?? .start }
}

public enum IsoFlat_Shape: UInt8, Sendable {
    case rect = 0, circle, capsule

    init(_ wire: Wire_Shape) { self = IsoFlat_Shape(rawValue: UInt8(clamping: wire.rawValue)) ?? .rect }
    public var wire: Wire_Shape { Wire_Shape(rawValue: Int(rawValue)) ?? .rect }
}

public enum IsoFlat_PresentationStyle: UInt8, Sendable {
    case sheet = 0, popover, alert

    init(_ wire: Wire_PresentationStyle) {
        self = IsoFlat_PresentationStyle(rawValue: UInt8(clamping: wire.rawValue)) ?? .sheet
    }
    public var wire: Wire_PresentationStyle { Wire_PresentationStyle(rawValue: Int(rawValue)) ?? .sheet }
}

public struct IsoFlat_ColorRGBA: Equatable, Sendable {
    public var r: Float32
    public var g: Float32
    public var b: Float32
    public var a: Float32

    public init(r: Float32, g: Float32, b: Float32, a: Float32) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ wire: Wire_Color) { self.init(r: wire.r, g: wire.g, b: wire.b, a: wire.a) }

    public var wire: Wire_Color {
        var color = Wire_Color()
        color.r = r
        color.g = g
        color.b = b
        color.a = a
        return color
    }
}

public struct IsoFlat_ShadowSpec: Equatable, Sendable {
    public var color: IsoFlat_ColorRGBA
    public var radius: Float32
    public var x: Float32
    public var y: Float32

    public init(color: IsoFlat_ColorRGBA, radius: Float32, x: Float32, y: Float32) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }

    init(_ wire: Wire_Shadow) { self.init(color: IsoFlat_ColorRGBA(wire.color), radius: wire.radius, x: wire.x, y: wire.y) }

    public var wire: Wire_Shadow {
        var shadow = Wire_Shadow()
        shadow.color = color.wire
        shadow.radius = radius
        shadow.x = x
        shadow.y = y
        return shadow
    }
}

public struct IsoFlat_KV: Sendable {
    public var key: String!
    public var value: String!

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    init(_ wire: Wire_KV) {
        key = wire.key
        value = wire.value
    }
}

public struct IsoFlat_Node: Sendable {
    public var kind: IsoFlat_Kind
    public var v: String?
    public var num: Double?
    public var id: String?
    public var size: Double?
    public var weight: Int32?
    public var color: IsoFlat_ColorRGBA?
    public var lines: Int32?
    public var shape: IsoFlat_Shape?
    public var fill: IsoFlat_ColorRGBA?
    public var stroke: IsoFlat_ColorRGBA?
    public var strokeWidth: Double?
    public var axis: IsoFlat_Axis?
    public var spacing: Double?
    public var min: Double?
    public var src: String?
    public var remote: Bool?
    public var resizable: Bool?
    public var fit: Bool?
    public var placeholder: String?
    public var edit: String?
    public var view: String?
    public var options: [String?]
    public var params: [IsoFlat_KV]
    public var growW: Bool
    public var growH: Bool
    public var alignH: IsoFlat_Align?
    public var alignV: IsoFlat_Align?
    public var shadow: IsoFlat_ShadowSpec?
    public var padding: [Double]
    public var width: Double?
    public var height: Double?
    public var expandW: Bool
    public var expandH: Bool
    public var radius: Double?
    public var opacity: Double?
    public var bg: IsoFlat_ColorRGBA?
    public var gradient: String?
    public var tap: String?
    public var feedback: Int32?
    public var style: IsoFlat_PresentationStyle?
    public var title: String?
    public var message: String?
    public var dismiss: String?
    public var ch: [IsoFlat_Node]
    public var offsetX: Double?
    public var offsetY: Double?
    public var scale: Double?
    public var drag: String?
    public var key: String?

    /// A whole tree, as `FlatTreeEncoder.encode(root:)` writes it, read
    /// straight from its bytes (_WireReader).
    public init(treeBytes: [UInt8]) throws {
        self = try _WireReader.read(treeBytes) { try IsoFlat_Node(reading: &$0) }
    }

    /// A node with nothing set, for the reader to fill.
    init() {
        kind = .box
        options = []
        params = []
        growW = false
        growH = false
        padding = []
        expandW = false
        expandH = false
        ch = []
    }

    public init(_ wire: Wire_Node) {
        kind = IsoFlat_Kind(wire.kind)
        v = wire.hasV ? wire.v : nil
        num = wire.hasNum ? wire.num : nil
        id = wire.hasID ? wire.id : nil
        size = wire.hasSize ? wire.size : nil
        weight = wire.hasWeight ? wire.weight : nil
        color = wire.hasColor ? IsoFlat_ColorRGBA(wire.color) : nil
        lines = wire.hasLines ? wire.lines : nil
        shape = wire.hasShape ? IsoFlat_Shape(wire.shape) : nil
        fill = wire.hasFill ? IsoFlat_ColorRGBA(wire.fill) : nil
        stroke = wire.hasStroke ? IsoFlat_ColorRGBA(wire.stroke) : nil
        strokeWidth = wire.hasStrokeWidth ? wire.strokeWidth : nil
        axis = wire.hasAxis ? IsoFlat_Axis(wire.axis) : nil
        spacing = wire.hasSpacing ? wire.spacing : nil
        min = wire.hasMin ? wire.min : nil
        src = wire.hasSrc ? wire.src : nil
        remote = wire.hasRemote ? wire.remote : nil
        resizable = wire.hasResizable ? wire.resizable : nil
        fit = wire.hasFit ? wire.fit : nil
        placeholder = wire.hasPlaceholder ? wire.placeholder : nil
        edit = wire.hasEdit ? wire.edit : nil
        view = wire.hasView ? wire.view : nil
        options = wire.options.map { $0 }
        params = wire.params.map(IsoFlat_KV.init)
        growW = wire.growW
        growH = wire.growH
        alignH = wire.hasAlignH ? IsoFlat_Align(wire.alignH) : nil
        alignV = wire.hasAlignV ? IsoFlat_Align(wire.alignV) : nil
        shadow = wire.hasShadow ? IsoFlat_ShadowSpec(wire.shadow) : nil
        padding = wire.padding
        width = wire.hasWidth ? wire.width : nil
        height = wire.hasHeight ? wire.height : nil
        expandW = wire.expandW
        expandH = wire.expandH
        radius = wire.hasRadius ? wire.radius : nil
        opacity = wire.hasOpacity ? wire.opacity : nil
        bg = wire.hasBg ? IsoFlat_ColorRGBA(wire.bg) : nil
        gradient = wire.hasGradient ? wire.gradient : nil
        tap = wire.hasTap ? wire.tap : nil
        feedback = wire.hasFeedback ? wire.feedback : nil
        style = wire.hasStyle ? IsoFlat_PresentationStyle(wire.style) : nil
        title = wire.hasTitle ? wire.title : nil
        message = wire.hasMessage ? wire.message : nil
        dismiss = wire.hasDismiss ? wire.dismiss : nil
        ch = wire.ch.map(IsoFlat_Node.init)
        offsetX = wire.hasOffsetX ? wire.offsetX : nil
        offsetY = wire.hasOffsetY ? wire.offsetY : nil
        scale = wire.hasScale ? wire.scale : nil
        drag = wire.hasDrag ? wire.drag : nil
        key = wire.hasKey ? wire.key : nil
    }
}

/// One change to the reader's tree (shared/wire/tree.proto's PatchOp).
public struct IsoFlat_PatchOp: Sendable {
    public var path: String?
    public var node: IsoFlat_Node?
    public var attrsOnly: Bool
    public var order: [Int32]
    /// Whether the op is a reorder (`order` present, even if empty).
    public var hasOrder: Bool
    public var inserts: [IsoFlat_Node]

    init() {
        path = ""
        attrsOnly = false
        order = []
        hasOrder = false
        inserts = []
    }

    init(_ wire: Wire_PatchOp) {
        path = wire.path
        node = wire.hasNode ? IsoFlat_Node(wire.node) : nil
        attrsOnly = wire.attrsOnly
        order = wire.order
        hasOrder = wire.reorder
        inserts = wire.inserts.map(IsoFlat_Node.init)
    }
}

public struct IsoFlat_Patch: Sendable {
    public var ops: [IsoFlat_PatchOp]

    /// A frame, as `FlatTreeEncoder.encodePatch(root:)` writes it.
    public init(patchBytes: [UInt8]) throws {
        ops = try _WireReader.read(patchBytes) { reader in
            var ops: [IsoFlat_PatchOp] = []
            while let (field, type) = try reader.tag() {
                if field == 1, type == 2 {
                    var op = try reader.message()
                    ops.append(try IsoFlat_PatchOp(reading: &op))
                } else {
                    try reader.skip(type)
                }
            }
            return ops
        }
    }
}

// MARK: - Reading the wire format

// tree.proto's messages read straight from their bytes into the IsoFlat
// types: no SwiftProtobuf message made per node (each with storage of its
// own) and then copied field by field into the IsoFlat node. A field the
// reader doesn't know is skipped, as protobuf's readers skip one; a repeated
// number reads packed or not; bytes that end inside a field, a length past
// the end, or a group (which tree.proto has none of) are an
// `IsoFlatDecodingError`, as SwiftProtobuf's parse failing was.
//
// Over the array's own storage, every read checked against the bytes left.
// Not through Span: on Apple's systems before 26 it is in a back-deployment
// library (libswiftCompatibilitySpan) that an app at Isomer's floor (iOS 16)
// would have to embed.

struct _WireReader {
    private let base: UnsafePointer<UInt8>
    private var position: Int
    private let end: Int

    private init(base: UnsafePointer<UInt8>, position: Int, end: Int) {
        self.base = base
        self.position = position
        self.end = end
    }

    /// What `read` makes of all of `bytes`.
    static func read<T>(_ bytes: [UInt8], _ read: (inout _WireReader) throws -> T) throws -> T {
        try bytes.withUnsafeBufferPointer { buffer in
            // (No bytes have no address: a reader of nothing reads none.)
            guard let base = buffer.baseAddress else {
                var empty = _WireReader(base: UnsafePointer(bitPattern: 1)!, position: 0, end: 0)
                return try read(&empty)
            }
            var reader = _WireReader(base: base, position: 0, end: buffer.count)
            return try read(&reader)
        }
    }

    /// The next field's number and wire type; nil at the end.
    mutating func tag() throws -> (Int, Int)? {
        guard position < end else { return nil }
        let key = try varint()
        guard key >> 3 > 0, key >> 3 <= UInt64(Int32.max) else { throw IsoFlatDecodingError() }
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < end, shift < 64 else { throw IsoFlatDecodingError() }
            let byte = base[position]
            position += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
    }

    mutating func fixed32() throws -> UInt32 {
        guard end - position >= 4 else { throw IsoFlatDecodingError() }
        let bits = UnsafeRawPointer(base + position).loadUnaligned(as: UInt32.self)
        position += 4
        return UInt32(littleEndian: bits)
    }

    mutating func fixed64() throws -> UInt64 {
        guard end - position >= 8 else { throw IsoFlatDecodingError() }
        let bits = UnsafeRawPointer(base + position).loadUnaligned(as: UInt64.self)
        position += 8
        return UInt64(littleEndian: bits)
    }

    mutating func double() throws -> Double { Double(bitPattern: try fixed64()) }
    mutating func float() throws -> Float32 { Float32(bitPattern: try fixed32()) }
    mutating func int32() throws -> Int32 { Int32(truncatingIfNeeded: try varint()) }
    mutating func bool() throws -> Bool { try varint() != 0 }

    /// A length-delimited field's length, checked against the bytes left.
    private mutating func length() throws -> Int {
        let length = try varint()
        guard length <= UInt64(end - position) else { throw IsoFlatDecodingError() }
        return Int(length)
    }

    mutating func string() throws -> String {
        let length = try length()
        let string = String(decoding: UnsafeBufferPointer(start: base + position, count: length), as: UTF8.self)
        position += length
        return string
    }

    /// A nested message: a reader of its bytes alone, this one moved past them.
    mutating func message() throws -> _WireReader {
        let length = try length()
        let inner = _WireReader(base: base, position: position, end: position + length)
        position += length
        return inner
    }

    /// A field not read: passed over by its wire type.
    mutating func skip(_ type: Int) throws {
        switch type {
        case 0: _ = try varint()
        case 1: _ = try fixed64()
        case 2: position += try length()
        case 5: _ = try fixed32()
        default: throw IsoFlatDecodingError()
        }
    }

    /// A repeated double, packed (wire type 2) or one value (1).
    mutating func doubles(_ type: Int, into values: inout [Double]) throws {
        guard type == 2 else { return values.append(try double()) }
        var packed = try message()
        while packed.position < packed.end { values.append(try packed.double()) }
    }

    /// A repeated int32, packed (wire type 2) or one value (0).
    mutating func int32s(_ type: Int, into values: inout [Int32]) throws {
        guard type == 2 else { return values.append(try int32()) }
        var packed = try message()
        while packed.position < packed.end { values.append(try packed.int32()) }
    }
}

extension IsoFlat_ColorRGBA {
    init(reading reader: inout _WireReader) throws {
        self.init(r: 0, g: 0, b: 0, a: 0)
        while let (field, type) = try reader.tag() {
            switch (field, type) {
            case (1, 5): r = try reader.float()
            case (2, 5): g = try reader.float()
            case (3, 5): b = try reader.float()
            case (4, 5): a = try reader.float()
            default: try reader.skip(type)
            }
        }
    }

    fileprivate static func reading(_ reader: inout _WireReader) throws -> IsoFlat_ColorRGBA {
        var message = try reader.message()
        return try IsoFlat_ColorRGBA(reading: &message)
    }
}

extension IsoFlat_Node {
    init(reading reader: inout _WireReader) throws {
        self.init()
        while let (field, type) = try reader.tag() {
            switch (field, type) {
            case (1, 0): kind = IsoFlat_Kind(rawValue: UInt8(clamping: try reader.int32())) ?? .box
            case (2, 2): v = try reader.string()
            case (3, 1): num = try reader.double()
            case (4, 2): id = try reader.string()
            case (5, 1): size = try reader.double()
            case (6, 0): weight = try reader.int32()
            case (7, 2): color = try .reading(&reader)
            case (8, 0): lines = try reader.int32()
            case (9, 0): shape = IsoFlat_Shape(rawValue: UInt8(clamping: try reader.int32())) ?? .rect
            case (10, 2): fill = try .reading(&reader)
            case (11, 2): stroke = try .reading(&reader)
            case (12, 1): strokeWidth = try reader.double()
            case (13, 0): axis = IsoFlat_Axis(rawValue: UInt8(clamping: try reader.int32())) ?? .horizontal
            case (14, 1): spacing = try reader.double()
            case (15, 1): min = try reader.double()
            case (16, 2): src = try reader.string()
            case (17, 0): remote = try reader.bool()
            case (18, 0): resizable = try reader.bool()
            case (19, 0): fit = try reader.bool()
            case (20, 2): placeholder = try reader.string()
            case (21, 2): edit = try reader.string()
            case (22, 2): view = try reader.string()
            case (23, 2): options.append(try reader.string())
            case (24, 2):
                var inner = try reader.message()
                var kv = IsoFlat_KV(key: "", value: "")
                while let (field, type) = try inner.tag() {
                    switch (field, type) {
                    case (1, 2): kv.key = try inner.string()
                    case (2, 2): kv.value = try inner.string()
                    default: try inner.skip(type)
                    }
                }
                params.append(kv)
            case (25, 0): growW = try reader.bool()
            case (26, 0): growH = try reader.bool()
            case (27, 0): alignH = IsoFlat_Align(rawValue: UInt8(clamping: try reader.int32())) ?? .start
            case (28, 0): alignV = IsoFlat_Align(rawValue: UInt8(clamping: try reader.int32())) ?? .start
            case (29, 2):
                var inner = try reader.message()
                var spec = IsoFlat_ShadowSpec(color: IsoFlat_ColorRGBA(r: 0, g: 0, b: 0, a: 0), radius: 0, x: 0, y: 0)
                while let (field, type) = try inner.tag() {
                    switch (field, type) {
                    case (1, 2): spec.color = try .reading(&inner)
                    case (2, 5): spec.radius = try inner.float()
                    case (3, 5): spec.x = try inner.float()
                    case (4, 5): spec.y = try inner.float()
                    default: try inner.skip(type)
                    }
                }
                shadow = spec
            case (30, 1), (30, 2): try reader.doubles(type, into: &padding)
            case (31, 1): width = try reader.double()
            case (32, 1): height = try reader.double()
            case (33, 0): expandW = try reader.bool()
            case (34, 0): expandH = try reader.bool()
            case (35, 1): radius = try reader.double()
            case (36, 1): opacity = try reader.double()
            case (37, 2): bg = try .reading(&reader)
            case (38, 2): gradient = try reader.string()
            case (39, 2): tap = try reader.string()
            case (40, 0): feedback = try reader.int32()
            case (41, 0): style = IsoFlat_PresentationStyle(rawValue: UInt8(clamping: try reader.int32())) ?? .sheet
            case (42, 2): title = try reader.string()
            case (43, 2): message = try reader.string()
            case (44, 2): dismiss = try reader.string()
            case (45, 2):
                var inner = try reader.message()
                ch.append(try IsoFlat_Node(reading: &inner))
            case (46, 1): offsetX = try reader.double()
            case (47, 1): offsetY = try reader.double()
            case (48, 1): scale = try reader.double()
            case (49, 2): drag = try reader.string()
            case (50, 2): key = try reader.string()
            default: try reader.skip(type)
            }
        }
    }
}

extension IsoFlat_PatchOp {
    init(reading reader: inout _WireReader) throws {
        self.init()
        while let (field, type) = try reader.tag() {
            switch (field, type) {
            case (1, 2): path = try reader.string()
            case (2, 2):
                var message = try reader.message()
                node = try IsoFlat_Node(reading: &message)
            case (3, 0): attrsOnly = try reader.bool()
            case (4, 0), (4, 2): try reader.int32s(type, into: &order)
            case (5, 2):
                var message = try reader.message()
                inserts.append(try IsoFlat_Node(reading: &message))
            case (6, 0): hasOrder = try reader.bool()
            default: try reader.skip(type)
            }
        }
    }
}
