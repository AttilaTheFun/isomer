import CoreGraphics

// SE-0307: CGFloat and Double convert implicitly, which the compiler allows
// for a CGFloat declared in a module named CoreGraphics.
public func conversionCheck(_ value: Double) -> Double {
    let rect = CGRect(x: 0, y: 0, width: value, height: 2)
    let width: Double = rect.width
    let half: CGFloat = width / 2
    return half + 1.0
}
