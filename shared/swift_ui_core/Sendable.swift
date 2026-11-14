// What Apple's SwiftUI promises `Sendable` and Isomer's types didn't say
// (docs/parity/missing/SwiftUI.md, "Sendable on Apple, not in Isomer"): an
// app that keeps one in a `Sendable` type, or sends one across actors,
// builds in Swift 6 mode with Isomer's as with Apple's.
//
// Unchecked: a conformance declared away from its type can't be checked.
// They are values made of values: Image's `handle` is an image a host
// made, never changed after; AnyShapeStyle's `base` is a style's value.

extension AngularGradient: @unchecked Sendable {}
extension AnyShapeStyle: @unchecked Sendable {}
extension BackgroundStyle: @unchecked Sendable {}
extension Capsule: @unchecked Sendable {}
extension Circle: @unchecked Sendable {}
extension DefaultGlassEffectShape: @unchecked Sendable {}
extension DragGesture.Value: @unchecked Sendable {}
extension Ellipse: @unchecked Sendable {}
extension EllipticalGradient: @unchecked Sendable {}
extension EmptyView: @unchecked Sendable {}
extension GlassEffectContainer: @unchecked Sendable where Content: Sendable {}
extension HierarchicalShapeStyle: @unchecked Sendable {}
extension Image: @unchecked Sendable {}
extension LinearGradient: @unchecked Sendable {}
extension MagnifyGesture.Value: @unchecked Sendable {}
extension MatchedGeometryProperties: @unchecked Sendable {}
extension ModifiedContent: @unchecked Sendable where Content: Sendable, Modifier: Sendable {}
extension RadialGradient: @unchecked Sendable {}
extension Rectangle: @unchecked Sendable {}
extension RotatedShape: @unchecked Sendable where Content: Sendable {}
extension RoundedRectangle: @unchecked Sendable {}
extension SimultaneousGesture.Value: @unchecked Sendable where First.Value: Sendable, Second.Value: Sendable {}
extension Spacer: @unchecked Sendable {}
extension Text: @unchecked Sendable {}
extension TintShapeStyle: @unchecked Sendable {}
