// Visual transforms: `.rotationEffect` and `.scaleEffect`. The runtime emits a
// 2D affine matrix (about the node's center) through the host's
// pushTransform/popTransform, which both renderers apply per drawn primitive in
// their vertex shaders. Real SwiftUI is used on Apple.

extension View {
    nonisolated public func rotationEffect(_ angle: Angle, anchor: UnitPoint = .center) -> some View {
        _AnimatableBoxModifier(child: self, descend: "rotation") { box, env, path, now in
            let target = angle.radians
            box.rotation = Double(Runtime.shared.animator.value(
                key: path + "#rotation", target: target, animation: env.animation, now: now))
        }
    }

    nonisolated public func scaleEffect(_ scale: CGFloat, anchor: UnitPoint = .center) -> some View {
        _AnimatableBoxModifier(child: self, descend: "scale") { box, env, path, now in
            box.scaleEffect = Runtime.shared.animator.value(
                key: path + "#scale", target: scale, animation: env.animation, now: now)
        }
    }
}

/// A 2D affine transform `(a, b, c, d, e, f)`: maps `(x, y)` to
/// `(a*x + c*y + e, b*x + d*y + f)`.
struct AffineTransform {
    var a, b, c, d, e, f: Double

    static let identity = AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    /// A rotation + uniform scale about a pivot point.
    static func rotationScale(angle: Double, scale: Double, cx: Double, cy: Double) -> AffineTransform {
        let cosA = cosApprox(angle) * scale
        let sinA = sinApprox(angle) * scale
        // [cos -sin; sin cos] about (cx, cy).
        let a = cosA, b = sinA, c = -sinA, d = cosA
        let e = cx - (a * cx + c * cy)
        let f = cy - (b * cx + d * cy)
        return AffineTransform(a: a, b: b, c: c, d: d, e: e, f: f)
    }

    var isIdentity: Bool {
        a == 1 && b == 0 && c == 0 && d == 1 && e == 0 && f == 0
    }
}

// Minimal sin/cos (the core links no math library): range-reduce then a 7th-
// order Taylor series, accurate to ~1e-6 over the reduced range.
func sinApprox(_ x: Double) -> Double {
    let twoPi = 6.283185307179586
    var t = x.truncatingRemainder(dividingBy: twoPi)
    if t > 3.141592653589793 { t -= twoPi }
    if t < -3.141592653589793 { t += twoPi }
    let x2 = t * t
    return t * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42 * (1 - x2 / 72))))
}

func cosApprox(_ x: Double) -> Double {
    sinApprox(x + 1.5707963267948966)
}
