// CombineIdentifier: what tells subscriptions and subscribers apart (a
// subscriber struct has no identity of its own; AnySubscriber keeps the one
// of the subscriber it wraps).

public struct CombineIdentifier: Hashable, CustomStringConvertible {
    // An object's identity, or a number counted from one: the two never
    // compare equal (`isObject` keeps them apart).
    private let value: UInt64
    private let isObject: Bool

    public init() {
        value = CombineIdentifier.next()
        isObject = false
    }

    public init(_ obj: AnyObject) {
        value = UInt64(UInt(bitPattern: ObjectIdentifier(obj)))
        isObject = true
    }

    public var description: String {
        "0x" + String(value, radix: 16)
    }

    public static func == (a: CombineIdentifier, b: CombineIdentifier) -> Bool {
        a.value == b.value && a.isObject == b.isObject
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
        hasher.combine(isObject)
    }

    private static let counterLock = Lock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    private static func next() -> UInt64 {
        counterLock.withLock {
            counter += 1
            return counter
        }
    }
}

public protocol CustomCombineIdentifierConvertible {
    var combineIdentifier: CombineIdentifier { get }
}

extension CustomCombineIdentifierConvertible where Self: AnyObject {
    public var combineIdentifier: CombineIdentifier {
        CombineIdentifier(self)
    }
}
