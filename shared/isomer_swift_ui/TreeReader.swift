// The render tree as a reader sees it (Apple's tree view, the GPU renderer's
// decoder, the headless host, the tests): the wire format's messages
// (tree.pb.swift, from shared/wire/tree.proto) with an optional where a field
// may be absent, under the names the tree's readers have always used
// (IsoFlat_*, from when the wire format was FlatBuffers).

import SwiftProtobuf

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

    /// A whole tree, as `FlatTreeEncoder.encode(root:)` writes it.
    public init(treeBytes: [UInt8]) throws {
        guard let wire = try? Wire_Node(serializedBytes: treeBytes) else { throw IsoFlatDecodingError() }
        self.init(wire)
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
        guard let wire = try? Wire_Patch(serializedBytes: patchBytes) else { throw IsoFlatDecodingError() }
        ops = wire.ops.map(IsoFlat_PatchOp.init)
    }
}
