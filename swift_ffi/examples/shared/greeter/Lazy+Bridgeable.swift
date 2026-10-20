// HOW TO BRIDGE YOUR OWN GENERIC TYPE — the consumer-side pattern.
//
// swift_ffi ships `Bridgeable` conformances for the scalars and — via the
// general `.list` composite — for `Result`, `Array`, and `Dictionary`
// (see swift_ffi/swift_ffi/Result+Bridgeable.swift, the canonical example).
// Any generic type of yours can join them the same way: encode its contents
// into `BridgeValue` (use `.list` for composites) and decode by shape.
//
// Here the example app makes swift_ffi's `Lazy<T>` usable in ERASED positions
// (generic arguments, closure arguments, Result payloads). Note the trade:
// a `Lazy` RETURN type stays deferred (the bridge's built-in handle path
// computes on first unwrap, consumer-side); a `Lazy` crossing through this
// conformance computes at the boundary — erased values are self-contained
// bytes, so there is nothing left to defer. The single-element `.list` keeps
// the shape explicit.

import IsomerFFI

// `@retroactive` because BOTH Lazy and Bridgeable come from SwiftFFI — the
// usual consumer case (conforming YOUR generic type) doesn't need it.
extension Lazy: @retroactive Bridgeable where T: Bridgeable {
    public convenience init(bridgeValue: BridgeValue) throws {
        guard case .list(let items) = bridgeValue, items.count == 1 else {
            throw BridgeDecodingError("expected Lazy, got \(bridgeValue)")
        }
        self.init(value: try T(bridgeValue: items[0]))
    }

    public var bridgeValue: BridgeValue {
        .list([value.bridgeValue])
    }
}
