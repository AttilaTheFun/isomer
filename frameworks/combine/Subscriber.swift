// The protocols a publisher and its subscriber meet through, and the
// values they pass: a subscription, the demand a subscriber asks for, and
// how a stream completes.

public protocol Subscription: Cancellable, CustomCombineIdentifierConvertible {
    func request(_ demand: Subscribers.Demand)
}

public enum Subscriptions {}

extension Subscriptions {
    /// A subscription that does nothing: what a publisher hands a
    /// subscriber it completes at once.
    public static var empty: any Subscription {
        EmptySubscription.shared
    }
}

struct EmptySubscription: Subscription {
    static let shared = EmptySubscription()
    let combineIdentifier = CombineIdentifier()
    func request(_ demand: Subscribers.Demand) {}
    func cancel() {}
}

public protocol Subscriber<Input, Failure>: CustomCombineIdentifierConvertible {
    associatedtype Input
    associatedtype Failure: Error
    func receive(subscription: any Subscription)
    func receive(_ input: Self.Input) -> Subscribers.Demand
    func receive(completion: Subscribers.Completion<Self.Failure>)
}

extension Subscriber where Self.Input == () {
    public func receive() -> Subscribers.Demand {
        receive(())
    }
}

public enum Subscribers {}

extension Subscribers {
    @frozen public enum Completion<Failure> where Failure: Error {
        case finished
        case failure(Failure)
    }
}

extension Subscribers.Completion: Equatable where Failure: Equatable {
    public static func == (a: Subscribers.Completion<Failure>, b: Subscribers.Completion<Failure>) -> Bool {
        switch (a, b) {
        case (.finished, .finished): return true
        case (.failure(let x), .failure(let y)): return x == y
        default: return false
        }
    }
}

extension Subscribers.Completion: Hashable where Failure: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .finished:
            hasher.combine(0)
        case .failure(let error):
            hasher.combine(1)
            hasher.combine(error)
        }
    }
}

// Coded as Apple's: `success`, and the failure's `error`.
private enum CompletionCodingKeys: String, CodingKey {
    case success
    case error
}

extension Subscribers.Completion: Encodable where Failure: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CompletionCodingKeys.self)
        switch self {
        case .finished:
            try container.encode(true, forKey: .success)
        case .failure(let error):
            try container.encode(false, forKey: .success)
            try container.encode(error, forKey: .error)
        }
    }
}

extension Subscribers.Completion: Decodable where Failure: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CompletionCodingKeys.self)
        if try container.decode(Bool.self, forKey: .success) {
            self = .finished
        } else {
            self = .failure(try container.decode(Failure.self, forKey: .error))
        }
    }
}
extension Subscribers.Completion: Sendable {}

extension Subscribers.Completion {
    /// The same completion with its error turned into another.
    func mapError<E: Error>(_ transform: (Failure) -> E) -> Subscribers.Completion<E> {
        switch self {
        case .finished: return .finished
        case .failure(let error): return .failure(transform(error))
        }
    }

    /// As any Error (the try- operators' completions).
    var eraseError: Subscribers.Completion<any Error> {
        mapError { $0 as any Error }
    }
}

extension Subscribers {
    /// How many more values a subscriber will take: a count, or unlimited.
    /// Stored as one number, `UInt(Int.max) + 1` meaning unlimited, as
    /// Apple's frozen layout has it.
    @frozen public struct Demand: Equatable, Comparable, Hashable, Codable, CustomStringConvertible {
        @usableFromInline
        internal let rawValue: UInt

        @inline(__always) @inlinable
        internal init(rawValue: UInt) {
            self.rawValue = Swift.min(UInt(Int.max) + 1, rawValue)
        }

        public static let unlimited = Demand(rawValue: UInt(Int.max) + 1)
        public static let none = Demand(rawValue: 0)

        @inline(__always) @inlinable
        public static func max(_ value: Int) -> Subscribers.Demand {
            precondition(value >= 0, "A demand can't be negative")
            return Demand(rawValue: UInt(value))
        }

        public var description: String {
            self == .unlimited ? "unlimited" : "max(\(rawValue))"
        }

        /// The count, or nil when unlimited.
        @inline(__always) @inlinable
        public var max: Int? {
            self == .unlimited ? nil : Int(rawValue)
        }

        @inlinable
        public static func + (lhs: Subscribers.Demand, rhs: Subscribers.Demand) -> Subscribers.Demand {
            guard let l = lhs.max, let r = rhs.max else { return .unlimited }
            let (sum, overflow) = l.addingReportingOverflow(r)
            return overflow ? .unlimited : .max(sum)
        }

        @inlinable
        public static func += (lhs: inout Subscribers.Demand, rhs: Subscribers.Demand) {
            lhs = lhs + rhs
        }

        @inlinable
        public static func + (lhs: Subscribers.Demand, rhs: Int) -> Subscribers.Demand {
            guard let l = lhs.max else { return .unlimited }
            let (sum, overflow) = l.addingReportingOverflow(rhs)
            return overflow ? .unlimited : .max(Swift.max(0, sum))
        }

        @inlinable
        public static func += (lhs: inout Subscribers.Demand, rhs: Int) {
            lhs = lhs + rhs
        }

        public static func * (lhs: Subscribers.Demand, rhs: Int) -> Subscribers.Demand {
            guard let l = lhs.max else { return .unlimited }
            let (product, overflow) = l.multipliedReportingOverflow(by: rhs)
            return overflow ? .unlimited : .max(Swift.max(0, product))
        }

        @inlinable
        public static func *= (lhs: inout Subscribers.Demand, rhs: Int) {
            lhs = lhs * rhs
        }

        /// Never below none; unlimited less anything is still unlimited,
        /// and a count less unlimited is none.
        @inlinable
        public static func - (lhs: Subscribers.Demand, rhs: Subscribers.Demand) -> Subscribers.Demand {
            guard let l = lhs.max else { return .unlimited }
            guard let r = rhs.max else { return .none }
            let (difference, overflow) = l.subtractingReportingOverflow(r)
            return overflow || difference < 0 ? .none : .max(difference)
        }

        @inlinable
        public static func -= (lhs: inout Subscribers.Demand, rhs: Subscribers.Demand) {
            lhs = lhs - rhs
        }

        @inlinable
        public static func - (lhs: Subscribers.Demand, rhs: Int) -> Subscribers.Demand {
            guard let l = lhs.max else { return .unlimited }
            let (difference, overflow) = l.subtractingReportingOverflow(rhs)
            return overflow || difference < 0 ? .none : .max(difference)
        }

        @inlinable
        public static func -= (lhs: inout Subscribers.Demand, rhs: Int) {
            lhs = lhs - rhs
        }

        // Against a count: unlimited is above every Int.
        @inlinable public static func > (lhs: Subscribers.Demand, rhs: Int) -> Bool {
            guard let l = lhs.max else { return true }
            return l > rhs
        }

        @inlinable public static func >= (lhs: Subscribers.Demand, rhs: Int) -> Bool {
            guard let l = lhs.max else { return true }
            return l >= rhs
        }

        @inlinable public static func > (lhs: Int, rhs: Subscribers.Demand) -> Bool {
            guard let r = rhs.max else { return false }
            return lhs > r
        }

        @inlinable public static func >= (lhs: Int, rhs: Subscribers.Demand) -> Bool {
            guard let r = rhs.max else { return false }
            return lhs >= r
        }

        @inlinable public static func < (lhs: Subscribers.Demand, rhs: Int) -> Bool {
            guard let l = lhs.max else { return false }
            return l < rhs
        }

        @inlinable public static func < (lhs: Int, rhs: Subscribers.Demand) -> Bool {
            guard let r = rhs.max else { return true }
            return lhs < r
        }

        @inlinable public static func <= (lhs: Subscribers.Demand, rhs: Int) -> Bool {
            guard let l = lhs.max else { return false }
            return l <= rhs
        }

        @inlinable public static func <= (lhs: Int, rhs: Subscribers.Demand) -> Bool {
            guard let r = rhs.max else { return true }
            return lhs <= r
        }

        @inlinable public static func < (lhs: Subscribers.Demand, rhs: Subscribers.Demand) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        @inlinable public static func <= (lhs: Subscribers.Demand, rhs: Subscribers.Demand) -> Bool {
            lhs.rawValue <= rhs.rawValue
        }

        @inlinable public static func >= (lhs: Subscribers.Demand, rhs: Subscribers.Demand) -> Bool {
            lhs.rawValue >= rhs.rawValue
        }

        @inlinable public static func > (lhs: Subscribers.Demand, rhs: Subscribers.Demand) -> Bool {
            lhs.rawValue > rhs.rawValue
        }

        @inlinable public static func == (lhs: Subscribers.Demand, rhs: Int) -> Bool {
            guard let l = lhs.max else { return false }
            return l == rhs
        }

        @inlinable public static func != (lhs: Subscribers.Demand, rhs: Int) -> Bool {
            !(lhs == rhs)
        }

        @inlinable public static func == (lhs: Int, rhs: Subscribers.Demand) -> Bool {
            rhs == lhs
        }

        @inlinable public static func != (lhs: Int, rhs: Subscribers.Demand) -> Bool {
            !(rhs == lhs)
        }

        // One unsigned number, unlimited as its largest value.
        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(UInt.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public static func == (a: Subscribers.Demand, b: Subscribers.Demand) -> Bool {
            a.rawValue == b.rawValue
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(rawValue)
        }
    }
}

extension Subscribers.Demand: Sendable {}
extension Subscribers.Demand: BitwiseCopyable {}

extension Subscribers.Demand {
    /// One less, for a value delivered (unlimited stays unlimited).
    mutating func consumeOne() {
        if self != .unlimited, rawValue > 0 { self = Subscribers.Demand(rawValue: rawValue - 1) }
    }
}
