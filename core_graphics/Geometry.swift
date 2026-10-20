// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
// Isomer: CoreGraphics' geometry: CGPoint, CGSize, CGVector, CGRect,
// CGRectEdge, CGAffineTransform and CGAffineTransformComponents, with the
// API Apple's CoreGraphics gives them in Swift. CGPoint, CGSize and CGRect
// follow swift-corelibs-foundation's Sources/Foundation/NSGeometry.swift
// (swift-6.3.2-RELEASE) without its NSCoder and NSValue parts; the rest is
// Isomer's. On Apple platforms these types are Apple's (CoreFoundation
// declares them and CoreGraphics re-exports them); here CoreGraphics owns
// them and Foundation re-exports them.

#if ISOMER_CORELIBS_FOUNDATION
// Linux and Windows: CGFloat, CGPoint, CGSize and CGRect are
// swift-corelibs-foundation's; this module adds the rest.
import Foundation
#endif

// MARK: - CGPoint

#if !ISOMER_CORELIBS_FOUNDATION
@frozen
public struct CGPoint: Sendable {
    public var x: CGFloat
    public var y: CGFloat

    @_transparent
    public init() {
        self.init(x: CGFloat(), y: CGFloat())
    }

    @_transparent
    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}
#endif

extension CGPoint {
#if !ISOMER_CORELIBS_FOUNDATION
    @_transparent
    public static var zero: CGPoint { CGPoint(x: CGFloat(0), y: CGFloat(0)) }

    @_transparent
    public init(x: Int, y: Int) {
        self.init(x: CGFloat(x), y: CGFloat(y))
    }

    @_transparent
    public init(x: Double, y: Double) {
        self.init(x: CGFloat(x), y: CGFloat(y))
    }

#endif
    /// Whether two points are equal (CGPointEqualToPoint).
    @_transparent
    public func equalTo(_ point2: CGPoint) -> Bool { self == point2 }

    /// The point transformed by `t` (CGPointApplyAffineTransform).
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
    }
}

#if !ISOMER_CORELIBS_FOUNDATION
extension CGPoint: Equatable {
    @_transparent
    public static func == (lhs: CGPoint, rhs: CGPoint) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y
    }
}

extension CGPoint: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}
#endif

// Apple's types have these; swift-corelibs-foundation's (Linux, Windows) do
// not, and adding them to its types would be a retroactive conformance.
#if !ISOMER_CORELIBS_FOUNDATION
extension CGPoint: CustomDebugStringConvertible {
    public var debugDescription: String { "(\(x), \(y))" }
}

extension CGPoint: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: ["x": x, "y": y], displayStyle: .struct)
    }
}
#endif

#if !ISOMER_CORELIBS_FOUNDATION
extension CGPoint: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(CGFloat.self)
        let y = try container.decode(CGFloat.self)
        self.init(x: x, y: y)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}
#endif

// MARK: - CGSize

#if !ISOMER_CORELIBS_FOUNDATION
@frozen
public struct CGSize: Sendable {
    public var width: CGFloat
    public var height: CGFloat

    @_transparent
    public init() {
        self.init(width: CGFloat(), height: CGFloat())
    }

    @_transparent
    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }
}
#endif

extension CGSize {
#if !ISOMER_CORELIBS_FOUNDATION
    @_transparent
    public static var zero: CGSize { CGSize(width: CGFloat(0), height: CGFloat(0)) }

    @_transparent
    public init(width: Int, height: Int) {
        self.init(width: CGFloat(width), height: CGFloat(height))
    }

    @_transparent
    public init(width: Double, height: Double) {
        self.init(width: CGFloat(width), height: CGFloat(height))
    }

#endif
    /// Whether two sizes are equal (CGSizeEqualToSize).
    @_transparent
    public func equalTo(_ size2: CGSize) -> Bool { self == size2 }

    /// The size transformed by `t`: the translation does not apply
    /// (CGSizeApplyAffineTransform).
    public func applying(_ t: CGAffineTransform) -> CGSize {
        CGSize(width: t.a * width + t.c * height, height: t.b * width + t.d * height)
    }
}

#if !ISOMER_CORELIBS_FOUNDATION
extension CGSize: Equatable {
    @_transparent
    public static func == (lhs: CGSize, rhs: CGSize) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }
}

extension CGSize: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
    }
}
#endif

// Apple's types have these; swift-corelibs-foundation's (Linux, Windows) do
// not, and adding them to its types would be a retroactive conformance.
#if !ISOMER_CORELIBS_FOUNDATION
extension CGSize: CustomDebugStringConvertible {
    public var debugDescription: String { "(\(width), \(height))" }
}

extension CGSize: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: ["width": width, "height": height], displayStyle: .struct)
    }
}
#endif

#if !ISOMER_CORELIBS_FOUNDATION
extension CGSize: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let width = try container.decode(CGFloat.self)
        let height = try container.decode(CGFloat.self)
        self.init(width: width, height: height)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(width)
        try container.encode(height)
    }
}
#endif

// MARK: - CGVector

@frozen
public struct CGVector: Sendable {
    public var dx: CGFloat
    public var dy: CGFloat

    @_transparent
    public init() {
        self.init(dx: CGFloat(), dy: CGFloat())
    }

    @_transparent
    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }
}

extension CGVector {
    @_transparent
    public static var zero: CGVector { CGVector(dx: CGFloat(0), dy: CGFloat(0)) }

    @_transparent
    public init(dx: Int, dy: Int) {
        self.init(dx: CGFloat(dx), dy: CGFloat(dy))
    }

    @_transparent
    public init(dx: Double, dy: Double) {
        self.init(dx: CGFloat(dx), dy: CGFloat(dy))
    }
}

extension CGVector: Equatable {
    @_transparent
    public static func == (lhs: CGVector, rhs: CGVector) -> Bool {
        lhs.dx == rhs.dx && lhs.dy == rhs.dy
    }
}

extension CGVector: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(dx)
        hasher.combine(dy)
    }
}

extension CGVector: CustomDebugStringConvertible {
    public var debugDescription: String { "(\(dx), \(dy))" }
}

extension CGVector: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let dx = try container.decode(CGFloat.self)
        let dy = try container.decode(CGFloat.self)
        self.init(dx: dx, dy: dy)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(dx)
        try container.encode(dy)
    }
}

// MARK: - CGRect

#if !ISOMER_CORELIBS_FOUNDATION
@frozen
public struct CGRect: Sendable {
    public var origin: CGPoint
    public var size: CGSize

    @_transparent
    public init() {
        self.init(origin: CGPoint(), size: CGSize())
    }

    @_transparent
    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }
}

/// An edge of a rectangle (CGRect.divided(atDistance:from:)).
@frozen
public enum CGRectEdge: UInt32, Sendable {
    case minXEdge = 0
    case minYEdge = 1
    case maxXEdge = 2
    case maxYEdge = 3
}
#endif

extension CGRect {
#if !ISOMER_CORELIBS_FOUNDATION
    @_transparent
    public static var zero: CGRect { CGRect(origin: CGPoint(), size: CGSize()) }

    @_transparent
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    @_transparent
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    @_transparent
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.init(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    /// The null rectangle: the result of intersecting rectangles that do not
    /// meet (its origin is at infinity).
    public static var null: CGRect {
        CGRect(x: CGFloat.infinity, y: CGFloat.infinity, width: CGFloat(0), height: CGFloat(0))
    }

    /// The infinite rectangle.
    public static var infinite: CGRect {
        CGRect(
            x: -CGFloat.greatestFiniteMagnitude / 2,
            y: -CGFloat.greatestFiniteMagnitude / 2,
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
    }

    public var width: CGFloat { abs(size.width) }
    public var height: CGFloat { abs(size.height) }

    public var minX: CGFloat { origin.x + min(size.width, 0) }
    public var midX: CGFloat { (minX + maxX) * 0.5 }
    public var maxX: CGFloat { origin.x + max(size.width, 0) }

    public var minY: CGFloat { origin.y + min(size.height, 0) }
    public var midY: CGFloat { (minY + maxY) * 0.5 }
    public var maxY: CGFloat { origin.y + max(size.height, 0) }

    public var isEmpty: Bool { isNull || size.width == 0 || size.height == 0 }
    public var isInfinite: Bool { self == .infinite }
    public var isNull: Bool { origin.x == .infinity || origin.y == .infinity }

#endif
    /// Whether two rectangles are equal once standardized (CGRectEqualToRect).
    public func equalTo(_ rect2: CGRect) -> Bool { self == rect2 }

#if !ISOMER_CORELIBS_FOUNDATION
    public func contains(_ point: CGPoint) -> Bool {
        if isNull || isEmpty { return false }
        return (minX..<maxX).contains(point.x) && (minY..<maxY).contains(point.y)
    }

    public func contains(_ rect2: CGRect) -> Bool {
        union(rect2) == self
    }

    public var standardized: CGRect {
        if isNull { return .null }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    public var integral: CGRect {
        if isNull { return self }
        let standardized = self.standardized
        let x = standardized.origin.x.rounded(.down)
        let y = standardized.origin.y.rounded(.down)
        let width = (standardized.origin.x + standardized.size.width).rounded(.up) - x
        let height = (standardized.origin.y + standardized.size.height).rounded(.up) - y
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public func insetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        if isNull { return self }
        var rect = standardized
        rect.origin.x += dx
        rect.origin.y += dy
        rect.size.width -= 2 * dx
        rect.size.height -= 2 * dy
        if rect.size.width < 0 || rect.size.height < 0 {
            return .null
        }
        return rect
    }

    public func union(_ r2: CGRect) -> CGRect {
        if isNull {
            return r2
        } else if r2.isNull {
            return self
        }
        let rect1 = standardized
        let rect2 = r2.standardized
        let minX = min(rect1.minX, rect2.minX)
        let minY = min(rect1.minY, rect2.minY)
        let maxX = max(rect1.maxX, rect2.maxX)
        let maxY = max(rect1.maxY, rect2.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func intersection(_ r2: CGRect) -> CGRect {
        if isNull || r2.isNull { return .null }
        let rect1 = standardized
        let rect2 = r2.standardized
        let rect1SpanH = rect1.minX...rect1.maxX
        let rect1SpanV = rect1.minY...rect1.maxY
        let rect2SpanH = rect2.minX...rect2.maxX
        let rect2SpanV = rect2.minY...rect2.maxY
        if !rect1SpanH.overlaps(rect2SpanH) || !rect1SpanV.overlaps(rect2SpanV) {
            return .null
        }
        let overlapH = rect1SpanH.clamped(to: rect2SpanH)
        let overlapV = rect1SpanV.clamped(to: rect2SpanV)
        let width: CGFloat
        if overlapH == rect1SpanH {
            width = rect1.width
        } else if overlapH == rect2SpanH {
            width = rect2.width
        } else {
            width = overlapH.upperBound - overlapH.lowerBound
        }
        let height: CGFloat
        if overlapV == rect1SpanV {
            height = rect1.height
        } else if overlapV == rect2SpanV {
            height = rect2.height
        } else {
            height = overlapV.upperBound - overlapV.lowerBound
        }
        return CGRect(x: overlapH.lowerBound, y: overlapV.lowerBound, width: width, height: height)
    }

    public func intersects(_ rect2: CGRect) -> Bool {
        !intersection(rect2).isNull
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        if isNull { return self }
        var rect = standardized
        rect.origin.x += dx
        rect.origin.y += dy
        return rect
    }

    public func divided(atDistance: CGFloat, from fromEdge: CGRectEdge) -> (slice: CGRect, remainder: CGRect) {
        if isNull { return (.null, .null) }
        let splitLocation: CGFloat
        switch fromEdge {
        case .minXEdge: splitLocation = min(max(atDistance, 0), width)
        case .maxXEdge: splitLocation = min(max(width - atDistance, 0), width)
        case .minYEdge: splitLocation = min(max(atDistance, 0), height)
        case .maxYEdge: splitLocation = min(max(height - atDistance, 0), height)
        }
        let rect = standardized
        var rect1 = rect
        var rect2 = rect
        switch fromEdge {
        case .minXEdge, .maxXEdge:
            rect1.size.width = splitLocation
            rect2.origin.x = rect1.maxX
            rect2.size.width = rect.width - splitLocation
        case .minYEdge, .maxYEdge:
            rect1.size.height = splitLocation
            rect2.origin.y = rect1.maxY
            rect2.size.height = rect.height - splitLocation
        }
        switch fromEdge {
        case .minXEdge, .minYEdge: return (rect1, rect2)
        case .maxXEdge, .maxYEdge: return (rect2, rect1)
        }
    }

#endif
    /// The smallest rectangle holding this one transformed by `t`
    /// (CGRectApplyAffineTransform).
    public func applying(_ t: CGAffineTransform) -> CGRect {
        if isNull { return self }
        let corners = [
            CGPoint(x: minX, y: minY).applying(t),
            CGPoint(x: maxX, y: minY).applying(t),
            CGPoint(x: minX, y: maxY).applying(t),
            CGPoint(x: maxX, y: maxY).applying(t),
        ]
        var lowX = corners[0].x, highX = corners[0].x
        var lowY = corners[0].y, highY = corners[0].y
        for corner in corners.dropFirst() {
            lowX = min(lowX, corner.x)
            highX = max(highX, corner.x)
            lowY = min(lowY, corner.y)
            highY = max(highY, corner.y)
        }
        return CGRect(x: lowX, y: lowY, width: highX - lowX, height: highY - lowY)
    }
}

#if !ISOMER_CORELIBS_FOUNDATION
extension CGRect: Equatable {
    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        if lhs.isNull && rhs.isNull { return true }
        let r1 = lhs.standardized
        let r2 = rhs.standardized
        return r1.origin == r2.origin && r1.size == r2.size
    }
}

extension CGRect: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin)
        hasher.combine(size)
    }
}
#endif

// Apple's types have these; swift-corelibs-foundation's (Linux, Windows) do
// not, and adding them to its types would be a retroactive conformance.
#if !ISOMER_CORELIBS_FOUNDATION
extension CGRect: CustomDebugStringConvertible {
    public var debugDescription: String {
        "(\(origin.x), \(origin.y), \(size.width), \(size.height))"
    }
}

extension CGRect: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin, "size": size], displayStyle: .struct)
    }
}
#endif

#if !ISOMER_CORELIBS_FOUNDATION
extension CGRect: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let origin = try container.decode(CGPoint.self)
        let size = try container.decode(CGSize.self)
        self.init(origin: origin, size: size)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(origin)
        try container.encode(size)
    }
}
#endif

// MARK: - CGAffineTransform

/// An affine transform: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
@frozen
public struct CGAffineTransform: Sendable {
    public var a: CGFloat
    public var b: CGFloat
    public var c: CGFloat
    public var d: CGFloat
    public var tx: CGFloat
    public var ty: CGFloat

    @_transparent
    public init() {
        self.init(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)
    }

    @_transparent
    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }
}

extension CGAffineTransform {
    @_transparent
    public init(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ tx: CGFloat, _ ty: CGFloat) {
        self.init(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    public static var identity: CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    }

    public init(translationX tx: CGFloat, y ty: CGFloat) {
        self.init(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
    }

    public init(scaleX sx: CGFloat, y sy: CGFloat) {
        self.init(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    public init(rotationAngle angle: CGFloat) {
        let cosine = cos(angle)
        let sine = sin(angle)
        self.init(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
    }

    /// The transform these components make: scale, then shear, then rotate,
    /// then translate (CGAffineTransformMakeWithComponents).
    public init(_ components: CGAffineTransformComponents) {
        let scale = CGAffineTransform(scaleX: components.scale.width, y: components.scale.height)
        let shear = CGAffineTransform(a: 1, b: 0, c: components.horizontalShear, d: 1, tx: 0, ty: 0)
        let rotation = CGAffineTransform(rotationAngle: components.rotation)
        let translation = CGAffineTransform(
            translationX: components.translation.dx, y: components.translation.dy)
        self = scale.concatenating(shear).concatenating(rotation).concatenating(translation)
    }

    public var isIdentity: Bool { self == .identity }

    /// `t1.concatenating(t2)`: t1, then t2 (CGAffineTransformConcat).
    public func concatenating(_ t2: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(
            a: a * t2.a + b * t2.c,
            b: a * t2.b + b * t2.d,
            c: c * t2.a + d * t2.c,
            d: c * t2.b + d * t2.d,
            tx: tx * t2.a + ty * t2.c + t2.tx,
            ty: tx * t2.b + ty * t2.d + t2.ty)
    }

    /// A translation, then this transform (CGAffineTransformTranslate).
    public func translatedBy(x tx: CGFloat, y ty: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: tx, y: ty).concatenating(self)
    }

    /// A scale, then this transform (CGAffineTransformScale).
    public func scaledBy(x sx: CGFloat, y sy: CGFloat) -> CGAffineTransform {
        CGAffineTransform(scaleX: sx, y: sy).concatenating(self)
    }

    /// A rotation, then this transform (CGAffineTransformRotate).
    public func rotated(by angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: angle).concatenating(self)
    }

    /// The inverse, or this transform unchanged when it has none
    /// (CGAffineTransformInvert).
    public func inverted() -> CGAffineTransform {
        let determinant = a * d - b * c
        if determinant == 0 { return self }
        let inverseA = d / determinant
        let inverseB = -b / determinant
        let inverseC = -c / determinant
        let inverseD = a / determinant
        return CGAffineTransform(
            a: inverseA,
            b: inverseB,
            c: inverseC,
            d: inverseD,
            tx: -(tx * inverseA + ty * inverseC),
            ty: -(tx * inverseB + ty * inverseD))
    }

    /// The scale, shear, rotation and translation this transform makes
    /// (CGAffineTransformDecompose).
    public func decomposed() -> CGAffineTransformComponents {
        let scaleX = (a * a + b * b).squareRoot()
        let rotation = atan2(b, a)
        let determinant = a * d - b * c
        let scaleY = scaleX == 0 ? 0 : determinant / scaleX
        let shear = scaleX == 0 || scaleY == 0 ? 0 : (a * c + b * d) / (scaleX * scaleY)
        return CGAffineTransformComponents(
            scale: CGSize(width: scaleX, height: scaleY),
            horizontalShear: shear,
            rotation: rotation,
            translation: CGVector(dx: tx, dy: ty))
    }
}

extension CGAffineTransform: Equatable {
    @_transparent
    public static func == (lhs: CGAffineTransform, rhs: CGAffineTransform) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d
            && lhs.tx == rhs.tx && lhs.ty == rhs.ty
    }
}

extension CGAffineTransform: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(a)
        hasher.combine(b)
        hasher.combine(c)
        hasher.combine(d)
        hasher.combine(tx)
        hasher.combine(ty)
    }
}

extension CGAffineTransform: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let a = try container.decode(CGFloat.self)
        let b = try container.decode(CGFloat.self)
        let c = try container.decode(CGFloat.self)
        let d = try container.decode(CGFloat.self)
        let tx = try container.decode(CGFloat.self)
        let ty = try container.decode(CGFloat.self)
        self.init(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(a)
        try container.encode(b)
        try container.encode(c)
        try container.encode(d)
        try container.encode(tx)
        try container.encode(ty)
    }
}

/// An affine transform's parts (CGAffineTransform.decomposed()).
@frozen
public struct CGAffineTransformComponents: Sendable {
    public var scale: CGSize
    public var horizontalShear: CGFloat
    public var rotation: CGFloat
    public var translation: CGVector

    @_transparent
    public init() {
        self.init(scale: CGSize(), horizontalShear: 0, rotation: 0, translation: CGVector())
    }

    public init(
        scale: CGSize = .init(width: 1, height: 1),
        horizontalShear: CGFloat = 0,
        rotation: CGFloat = 0,
        translation: CGVector = .zero
    ) {
        self.scale = scale
        self.horizontalShear = horizontalShear
        self.rotation = rotation
        self.translation = translation
    }
}

/// Whether two transforms are equal (CGAffineTransformEqualToTransform).
public func CGAffineTransformEqualToTransform(_ t1: CGAffineTransform, _ t2: CGAffineTransform) -> Bool {
    t1 == t2
}
