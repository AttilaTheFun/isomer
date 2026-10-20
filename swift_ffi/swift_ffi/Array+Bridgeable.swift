// Array<Element> as a bridgeable value, following the generic-container
// pattern established in Result+Bridgeable.swift: the elements encode into
// `.list` in order. Usable wherever erased values flow — generic arguments,
// closure arguments, `Result` payloads, `Lazy` payloads — whenever `Element`
// is itself bridgeable.

extension Array: Bridgeable where Element: Bridgeable {
    public init(bridgeValue: BridgeValue) throws {
        // `[UInt8]` keeps its dedicated `.bytes` wire form (a byte buffer,
        // not an element list).
        if case .bytes(let raw) = bridgeValue, let bytes = raw as? [Element] {
            self = bytes
            return
        }
        guard case .list(let items) = bridgeValue else {
            throw BridgeDecodingError("expected Array, got \(bridgeValue)")
        }
        self = try items.map { try Element(bridgeValue: $0) }
    }

    public var bridgeValue: BridgeValue {
        if let bytes = self as? [UInt8] { return .bytes(bytes) }
        return .list(map(\.bridgeValue))
    }
}
