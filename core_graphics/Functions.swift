// Isomer's CoreGraphics: the C-style names of the geometry API, which Swift
// code still reaches for (`CGRectGetMinX`, `CGRectMake`, `CGPointZero`,
// `CGAffineTransformMakeRotation`…), and CGFloat's limits.

#if ISOMER_CORELIBS_FOUNDATION
// Linux and Windows: CGFloat, CGPoint, CGSize and CGRect are
// swift-corelibs-foundation's; this module adds the rest.
import Foundation
#endif

public let CGFLOAT_IS_DOUBLE: Int32 = 1
public let CGFLOAT_DEFINED: Int32 = 1
public var CGFLOAT_EPSILON: CGFloat { CGFloat.ulpOfOne }

public let CGPointZero = CGPoint.zero
public let CGSizeZero = CGSize.zero
public let CGRectZero = CGRect.zero
public let CGRectNull = CGRect.null
public let CGRectInfinite = CGRect.infinite
public let CGAffineTransformIdentity = CGAffineTransform.identity

public func CGPointMake(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
public func CGSizeMake(_ width: CGFloat, _ height: CGFloat) -> CGSize { CGSize(width: width, height: height) }
public func CGVectorMake(_ dx: CGFloat, _ dy: CGFloat) -> CGVector { CGVector(dx: dx, dy: dy) }
public func CGRectMake(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

public func CGRectGetMinX(_ rect: CGRect) -> CGFloat { rect.minX }
public func CGRectGetMidX(_ rect: CGRect) -> CGFloat { rect.midX }
public func CGRectGetMaxX(_ rect: CGRect) -> CGFloat { rect.maxX }
public func CGRectGetMinY(_ rect: CGRect) -> CGFloat { rect.minY }
public func CGRectGetMidY(_ rect: CGRect) -> CGFloat { rect.midY }
public func CGRectGetMaxY(_ rect: CGRect) -> CGFloat { rect.maxY }
public func CGRectGetWidth(_ rect: CGRect) -> CGFloat { rect.width }
public func CGRectGetHeight(_ rect: CGRect) -> CGFloat { rect.height }

public func CGPointEqualToPoint(_ point1: CGPoint, _ point2: CGPoint) -> Bool { point1 == point2 }
public func CGSizeEqualToSize(_ size1: CGSize, _ size2: CGSize) -> Bool { size1 == size2 }
public func CGRectEqualToRect(_ rect1: CGRect, _ rect2: CGRect) -> Bool { rect1 == rect2 }

public func CGRectStandardize(_ rect: CGRect) -> CGRect { rect.standardized }
public func CGRectIsEmpty(_ rect: CGRect) -> Bool { rect.isEmpty }
public func CGRectIsNull(_ rect: CGRect) -> Bool { rect.isNull }
public func CGRectIsInfinite(_ rect: CGRect) -> Bool { rect.isInfinite }
public func CGRectInset(_ rect: CGRect, _ dx: CGFloat, _ dy: CGFloat) -> CGRect { rect.insetBy(dx: dx, dy: dy) }
public func CGRectIntegral(_ rect: CGRect) -> CGRect { rect.integral }
public func CGRectUnion(_ r1: CGRect, _ r2: CGRect) -> CGRect { r1.union(r2) }
public func CGRectIntersection(_ r1: CGRect, _ r2: CGRect) -> CGRect { r1.intersection(r2) }
public func CGRectOffset(_ rect: CGRect, _ dx: CGFloat, _ dy: CGFloat) -> CGRect { rect.offsetBy(dx: dx, dy: dy) }
public func CGRectContainsPoint(_ rect: CGRect, _ point: CGPoint) -> Bool { rect.contains(point) }
public func CGRectContainsRect(_ rect1: CGRect, _ rect2: CGRect) -> Bool { rect1.contains(rect2) }
public func CGRectIntersectsRect(_ rect1: CGRect, _ rect2: CGRect) -> Bool { rect1.intersects(rect2) }

public func CGPointApplyAffineTransform(_ point: CGPoint, _ t: CGAffineTransform) -> CGPoint { point.applying(t) }
public func CGSizeApplyAffineTransform(_ size: CGSize, _ t: CGAffineTransform) -> CGSize { size.applying(t) }
public func CGRectApplyAffineTransform(_ rect: CGRect, _ t: CGAffineTransform) -> CGRect { rect.applying(t) }

public func CGAffineTransformMake(
    _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ tx: CGFloat, _ ty: CGFloat
) -> CGAffineTransform {
    CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
}
public func CGAffineTransformMakeTranslation(_ tx: CGFloat, _ ty: CGFloat) -> CGAffineTransform {
    CGAffineTransform(translationX: tx, y: ty)
}
public func CGAffineTransformMakeScale(_ sx: CGFloat, _ sy: CGFloat) -> CGAffineTransform {
    CGAffineTransform(scaleX: sx, y: sy)
}
public func CGAffineTransformMakeRotation(_ angle: CGFloat) -> CGAffineTransform {
    CGAffineTransform(rotationAngle: angle)
}
public func CGAffineTransformIsIdentity(_ t: CGAffineTransform) -> Bool { t.isIdentity }
public func CGAffineTransformTranslate(_ t: CGAffineTransform, _ tx: CGFloat, _ ty: CGFloat) -> CGAffineTransform {
    t.translatedBy(x: tx, y: ty)
}
public func CGAffineTransformScale(_ t: CGAffineTransform, _ sx: CGFloat, _ sy: CGFloat) -> CGAffineTransform {
    t.scaledBy(x: sx, y: sy)
}
public func CGAffineTransformRotate(_ t: CGAffineTransform, _ angle: CGFloat) -> CGAffineTransform {
    t.rotated(by: angle)
}
public func CGAffineTransformInvert(_ t: CGAffineTransform) -> CGAffineTransform { t.inverted() }
public func CGAffineTransformConcat(_ t1: CGAffineTransform, _ t2: CGAffineTransform) -> CGAffineTransform {
    t1.concatenating(t2)
}
