// Result as a bridgeable value — a GENERIC conformance over the erased
// vocabulary, with no case of its own in `BridgeValue`. This is the pattern
// for bridging any generic container: encode its contents into `.list` (the
// general ordered composite) and decode by shape. `Array+Bridgeable.swift`
// and `Dictionary+Bridgeable.swift` follow it, and consumer libraries can
// conform their own generic types the same way.

/// `Result` crosses as `.list([isError, payload])`.
///
/// Any error type works. When `Failure` is itself `Bridgeable` (a bridgeable
/// struct or enum, say), the failure payload crosses with FULL FIDELITY and
/// decodes back into the typed error. Otherwise — including the common
/// `Result<T, any Error>` spelling exported signatures use — the error
/// crosses as its description and resurfaces as `BridgeError`, matching the
/// message-only `throws` channel.
extension Result: Bridgeable where Success: Bridgeable, Failure: Error {
    public init(bridgeValue: BridgeValue) throws {
        guard case .list(let items) = bridgeValue, items.count == 2,
            case .bool(let isError) = items[0]
        else {
            throw BridgeDecodingError("expected Result, got \(bridgeValue)")
        }
        guard isError else {
            self = .success(try Success(bridgeValue: items[1]))
            return
        }
        // A typed failure decodes through its own conformance.
        if let bridgeableFailure = Failure.self as? any Bridgeable.Type {
            let decoded = try bridgeableFailure.init(bridgeValue: items[1])
            guard let failure = decoded as? Failure else {
                throw BridgeDecodingError("expected \(Failure.self), got \(type(of: decoded))")
            }
            self = .failure(failure)
            return
        }
        // The untyped channel: a message, resurfacing as `BridgeError`.
        guard case .string(let message) = items[1] else {
            throw BridgeDecodingError("expected Result error message, got \(items[1])")
        }
        guard let failure = BridgeError(message) as? Failure else {
            throw BridgeDecodingError("cannot represent a bridged error as \(Failure.self)")
        }
        self = .failure(failure)
    }

    public var bridgeValue: BridgeValue {
        switch self {
        case .success(let value):
            return .list([.bool(false), value.bridgeValue])
        case .failure(let error):
            // Typed only when the STATIC Failure type is bridgeable — the
            // decoding side must be able to reconstruct it. `any Error`
            // failures cross as their description.
            if Failure.self is any Bridgeable.Type, let bridgeable = error as? any Bridgeable {
                return .list([.bool(true), bridgeable.bridgeValue])
            }
            return .list([.bool(true), .string(String(describing: error))])
        }
    }
}
