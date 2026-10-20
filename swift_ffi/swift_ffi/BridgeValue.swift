// The pure-Swift erased value vocabulary for bridge v2 (docs/bridge_v2.md).
//
// `BridgeValue` is the Swift-side twin of the C `bridge_value` in
// //swift_ffi/runtime/swift_abi — but deliberately free of C types, so the
// `SwiftFFI` module (which every annotated library imports) stays pure Swift.
// The generated glue and the shared runtime translate between the two at the
// boundary. Generics bridge by erasing to this vocabulary: a generic exported
// function's `T` must conform to `Bridgeable`, and the C ABI only ever sees
// the erased representation.

/// The erased representation of a bridgeable value.
public enum BridgeValue: Equatable {
    /// The absence of a value (a `Void` return or payload).
    case void
    /// A Swift `Int` (crosses as a 64-bit integer).
    case int(Int)
    /// A Swift `Int32` (widened to 64 bits on the wire).
    case int32(Int32)
    /// A Swift `Double` (crosses as its raw bit pattern).
    case double(Double)
    /// A Swift `Bool` (crosses as 0/1).
    case bool(Bool)
    /// A Swift `String` (crosses as its UTF-8 bytes, copied).
    case string(String)
    /// A Swift `[UInt8]` byte buffer (copied; distinct from `.list` — this is
    /// raw bytes, not an element sequence).
    case bytes([UInt8])
    /// An `@ExportedStruct` instance: its name plus one erased value per
    /// stored field, in declaration order.
    indirect case structure(name: String, fields: [BridgeValue])
    /// An ordered sequence of erased values — the general composite every
    /// generic container conformance encodes through: `Result` is
    /// `[isError, payload]`, `Array` its elements, `Dictionary` alternating
    /// key/value pairs (see Result/Array/Dictionary+Bridgeable.swift, and
    /// write your own the same way).
    indirect case list([BridgeValue])
    /// An `@ExportedInterface` instance inside an erased position. Direction
    /// fixes ownership: Swift → consumer crosses +1 (the consumer wrapper
    /// takes ownership); consumer → Swift (an interface-typed method
    /// argument) crosses borrowed for the call.
    case handle(bits: UInt64, interface: String)
    /// A CONSUMER-implemented interface instance inside an erased position:
    /// on wasm the bits are a foreign-registry id, natively a
    /// `bridge_closure *`. Swift wraps it in the interface's dispatcher-backed
    /// foreign proxy.
    case foreign(bits: UInt64, interface: String)
}

/// The error thrown when an erased value does not match the type it is being
/// decoded into (a bridge-contract violation, not a user error).
public struct BridgeDecodingError: Error, CustomStringConvertible {
    /// What was expected and what actually arrived.
    public let description: String

    /// Creates a decoding error with the given description.
    public init(_ description: String) { self.description = description }
}

/// The error type of the bridge's UNTYPED error channel.
///
/// The wire carries a plain message wherever no error type is declared: a
/// thrown Swift error reaching a consumer, a consumer closure's failure
/// reaching Swift, and the failure of a `Result` whose `Failure` is
/// `any Error`. This type materializes that message as a throwable Swift
/// error. `Result`s with a `Bridgeable` failure type bypass it entirely —
/// their errors round-trip typed (see Result+Bridgeable.swift).
public struct BridgeError: Error, CustomStringConvertible {
    /// The bridged error's message.
    public let description: String

    /// Wraps a message arriving from the untyped error channel.
    public init(_ description: String) { self.description = description }
}

/// A value type that can cross the bridge in erased positions — generic
/// arguments, `Result` payloads, closure arguments, `Lazy` payloads.
///
/// Conformances ship for the bridgeable scalars (`Int`, `Int32`, `Double`,
/// `Bool`, `String`, `[UInt8]`) and — via `.list` — the generic containers
/// `Result`, `Array`, and `Dictionary`; `@ExportedStruct` / `@ExportedEnum`
/// generate the conformance for annotated types. Generic parameters of
/// exported functions must be constrained to this protocol. Conform your own
/// generic types the same way the container files do.
public protocol Bridgeable {
    /// Reconstructs the value from its erased representation, throwing
    /// `BridgeDecodingError` when the shape does not match.
    init(bridgeValue: BridgeValue) throws

    /// The value's erased representation.
    var bridgeValue: BridgeValue { get }
}

// MARK: - Scalar conformances

extension Int: Bridgeable {
    public init(bridgeValue: BridgeValue) throws {
        guard case .int(let value) = bridgeValue else {
            throw BridgeDecodingError("expected Int, got \(bridgeValue)")
        }
        self = value
    }
    public var bridgeValue: BridgeValue { .int(self) }
}

extension Int32: Bridgeable {
    public init(bridgeValue: BridgeValue) throws {
        guard case .int32(let value) = bridgeValue else {
            throw BridgeDecodingError("expected Int32, got \(bridgeValue)")
        }
        self = value
    }
    public var bridgeValue: BridgeValue { .int32(self) }
}

extension Double: Bridgeable {
    public init(bridgeValue: BridgeValue) throws {
        guard case .double(let value) = bridgeValue else {
            throw BridgeDecodingError("expected Double, got \(bridgeValue)")
        }
        self = value
    }
    public var bridgeValue: BridgeValue { .double(self) }
}

extension Bool: Bridgeable {
    public init(bridgeValue: BridgeValue) throws {
        guard case .bool(let value) = bridgeValue else {
            throw BridgeDecodingError("expected Bool, got \(bridgeValue)")
        }
        self = value
    }
    public var bridgeValue: BridgeValue { .bool(self) }
}

extension String: Bridgeable {
    public init(bridgeValue: BridgeValue) throws {
        guard case .string(let value) = bridgeValue else {
            throw BridgeDecodingError("expected String, got \(bridgeValue)")
        }
        self = value
    }
    public var bridgeValue: BridgeValue { .string(self) }
}

extension UInt8: Bridgeable {
    public init(bridgeValue: BridgeValue) throws {
        guard case .int(let value) = bridgeValue, let byte = UInt8(exactly: value) else {
            throw BridgeDecodingError("expected UInt8, got \(bridgeValue)")
        }
        self = byte
    }
    public var bridgeValue: BridgeValue { .int(Int(self)) }
}

// MARK: - The opaque list carrier

/// The type a `.list` binds to when a GENERIC parameter is inferred from an
/// erased argument: the bridge cannot know which container the caller meant
/// (`[Int]`, `Result<Int, Error>`, a consumer type — they all encode as
/// `.list`), and it does not need to — `Bridgeable` is the only constraint,
/// so the value flows through generic code opaquely and re-encodes
/// byte-identically. Typed positions (a declared `Result` parameter, a
/// closure's `[Int]` argument) decode into their real container instead.
public struct BridgeList: Bridgeable, Equatable {
    /// The still-erased elements, in wire order. Decode them into concrete
    /// values with the element type's `init(bridgeValue:)` if needed.
    public let items: [BridgeValue]

    /// Wraps an erased element sequence (the expanded ABI's binding path;
    /// rarely constructed by hand).
    public init(items: [BridgeValue]) {
        self.items = items
    }

    public init(bridgeValue: BridgeValue) throws {
        guard case .list(let items) = bridgeValue else {
            throw BridgeDecodingError("expected list, got \(bridgeValue)")
        }
        self.items = items
    }

    public var bridgeValue: BridgeValue { .list(items) }
}

/// The type a `.structure` binds to when a GENERIC parameter is inferred from
/// an erased argument: the bridge identifies structs on the wire by NAME, and
/// generic code only needs `Bridgeable` — so the value flows through
/// opaquely and re-encodes byte-identically, exactly like `BridgeList` does
/// for containers. Typed positions (a declared `@ExportedStruct` parameter)
/// decode into the real struct instead.
public struct BridgeStruct: Bridgeable, Equatable {
    /// The struct's wire name (its Swift type name).
    public let name: String
    /// The still-erased fields, in declaration order.
    public let fields: [BridgeValue]

    /// Wraps an erased struct value (the expanded ABI's binding path; rarely
    /// constructed by hand).
    public init(name: String, fields: [BridgeValue]) {
        self.name = name
        self.fields = fields
    }

    public init(bridgeValue: BridgeValue) throws {
        guard case .structure(let name, let fields) = bridgeValue else {
            throw BridgeDecodingError("expected structure, got \(bridgeValue)")
        }
        self.name = name
        self.fields = fields
    }

    public var bridgeValue: BridgeValue { .structure(name: name, fields: fields) }
}
