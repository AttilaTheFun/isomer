// Scheduler: where and when the timing operators (receive(on:),
// debounce, throttle, delay, timeout, ...) run their work. Combine itself
// has ImmediateScheduler only; the run loop's, the main queue's and an
// operation queue's are Foundation's and Dispatch's.

public protocol SchedulerTimeIntervalConvertible {
    static func seconds(_ s: Int) -> Self
    static func seconds(_ s: Double) -> Self
    static func milliseconds(_ ms: Int) -> Self
    static func microseconds(_ us: Int) -> Self
    static func nanoseconds(_ ns: Int) -> Self
}

public protocol Scheduler<SchedulerTimeType> {
    associatedtype SchedulerTimeType: Strideable where Self.SchedulerTimeType.Stride: SchedulerTimeIntervalConvertible
    associatedtype SchedulerOptions

    var now: Self.SchedulerTimeType { get }
    var minimumTolerance: Self.SchedulerTimeType.Stride { get }

    func schedule(options: Self.SchedulerOptions?, _ action: @escaping () -> Void)
    func schedule(after date: Self.SchedulerTimeType, tolerance: Self.SchedulerTimeType.Stride,
                  options: Self.SchedulerOptions?, _ action: @escaping () -> Void)
    func schedule(after date: Self.SchedulerTimeType, interval: Self.SchedulerTimeType.Stride,
                  tolerance: Self.SchedulerTimeType.Stride, options: Self.SchedulerOptions?,
                  _ action: @escaping () -> Void) -> any Cancellable
}

extension Scheduler {
    public func schedule(after date: Self.SchedulerTimeType, _ action: @escaping () -> Void) {
        schedule(after: date, tolerance: minimumTolerance, action)
    }

    public func schedule(_ action: @escaping () -> Void) {
        schedule(options: nil, action)
    }

    public func schedule(after date: Self.SchedulerTimeType, tolerance: Self.SchedulerTimeType.Stride,
                         _ action: @escaping () -> Void) {
        schedule(after: date, tolerance: tolerance, options: nil, action)
    }

    public func schedule(after date: Self.SchedulerTimeType, interval: Self.SchedulerTimeType.Stride,
                         tolerance: Self.SchedulerTimeType.Stride, _ action: @escaping () -> Void) -> any Cancellable {
        schedule(after: date, interval: interval, tolerance: tolerance, options: nil, action)
    }

    public func schedule(after date: Self.SchedulerTimeType, interval: Self.SchedulerTimeType.Stride,
                         _ action: @escaping () -> Void) -> any Cancellable {
        schedule(after: date, interval: interval, tolerance: minimumTolerance, action)
    }
}

/// Runs work at once, on the thread asking. Its clock never moves: work
/// "after" a time runs now, and repeating work runs once.
public struct ImmediateScheduler: Scheduler {
    public struct SchedulerTimeType: Strideable {
        fileprivate init() {}

        public func distance(to other: ImmediateScheduler.SchedulerTimeType) -> ImmediateScheduler.SchedulerTimeType.Stride {
            SchedulerTimeType.Stride(0)
        }

        public func advanced(by n: ImmediateScheduler.SchedulerTimeType.Stride) -> ImmediateScheduler.SchedulerTimeType {
            self
        }

        /// A whole number of the clock's units, read as seconds' parts by the
        /// interval functions (nanoseconds, as Dispatch counts).
        public struct Stride: ExpressibleByFloatLiteral, Comparable, SignedNumeric, Codable, SchedulerTimeIntervalConvertible {
            public typealias FloatLiteralType = Double
            public typealias IntegerLiteralType = Int
            public typealias Magnitude = Int

            public var magnitude: Int

            public init(_ value: Int) {
                magnitude = value
            }

            public init(integerLiteral value: Int) {
                self.init(value)
            }

            public init(floatLiteral value: Double) {
                self.init(Int(value))
            }

            public init?<T>(exactly source: T) where T: BinaryInteger {
                guard let value = Int(exactly: source) else { return nil }
                self.init(value)
            }

            public static func < (lhs: ImmediateScheduler.SchedulerTimeType.Stride,
                                  rhs: ImmediateScheduler.SchedulerTimeType.Stride) -> Bool {
                lhs.magnitude < rhs.magnitude
            }

            public static func * (lhs: ImmediateScheduler.SchedulerTimeType.Stride,
                                  rhs: ImmediateScheduler.SchedulerTimeType.Stride) -> ImmediateScheduler.SchedulerTimeType.Stride {
                Stride(lhs.magnitude * rhs.magnitude)
            }

            public static func + (lhs: ImmediateScheduler.SchedulerTimeType.Stride,
                                  rhs: ImmediateScheduler.SchedulerTimeType.Stride) -> ImmediateScheduler.SchedulerTimeType.Stride {
                Stride(lhs.magnitude + rhs.magnitude)
            }

            public static func - (lhs: ImmediateScheduler.SchedulerTimeType.Stride,
                                  rhs: ImmediateScheduler.SchedulerTimeType.Stride) -> ImmediateScheduler.SchedulerTimeType.Stride {
                Stride(lhs.magnitude - rhs.magnitude)
            }

            public static func -= (lhs: inout ImmediateScheduler.SchedulerTimeType.Stride,
                                   rhs: ImmediateScheduler.SchedulerTimeType.Stride) {
                lhs = lhs - rhs
            }

            public static func *= (lhs: inout ImmediateScheduler.SchedulerTimeType.Stride,
                                   rhs: ImmediateScheduler.SchedulerTimeType.Stride) {
                lhs = lhs * rhs
            }

            public static func += (lhs: inout ImmediateScheduler.SchedulerTimeType.Stride,
                                   rhs: ImmediateScheduler.SchedulerTimeType.Stride) {
                lhs = lhs + rhs
            }

            public static func seconds(_ s: Int) -> ImmediateScheduler.SchedulerTimeType.Stride {
                Stride(s * 1_000_000_000)
            }

            public static func seconds(_ s: Double) -> ImmediateScheduler.SchedulerTimeType.Stride {
                Stride(Int(s * 1_000_000_000))
            }

            public static func milliseconds(_ ms: Int) -> ImmediateScheduler.SchedulerTimeType.Stride {
                Stride(ms * 1_000_000)
            }

            public static func microseconds(_ us: Int) -> ImmediateScheduler.SchedulerTimeType.Stride {
                Stride(us * 1_000)
            }

            public static func nanoseconds(_ ns: Int) -> ImmediateScheduler.SchedulerTimeType.Stride {
                Stride(ns)
            }

            public static func == (a: ImmediateScheduler.SchedulerTimeType.Stride,
                                   b: ImmediateScheduler.SchedulerTimeType.Stride) -> Bool {
                a.magnitude == b.magnitude
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(magnitude)
            }

            public init(from decoder: any Decoder) throws {
                self.init(try decoder.singleValueContainer().decode(Int.self))
            }
        }
    }

    public typealias SchedulerOptions = Never

    public static let shared = ImmediateScheduler()

    public func schedule(options: ImmediateScheduler.SchedulerOptions?, _ action: @escaping () -> Void) {
        action()
    }

    public var now: ImmediateScheduler.SchedulerTimeType {
        SchedulerTimeType()
    }

    public var minimumTolerance: ImmediateScheduler.SchedulerTimeType.Stride {
        SchedulerTimeType.Stride(0)
    }

    public func schedule(after date: ImmediateScheduler.SchedulerTimeType, tolerance: ImmediateScheduler.SchedulerTimeType.Stride,
                         options: ImmediateScheduler.SchedulerOptions?, _ action: @escaping () -> Void) {
        action()
    }

    @discardableResult
    public func schedule(after date: ImmediateScheduler.SchedulerTimeType, interval: ImmediateScheduler.SchedulerTimeType.Stride,
                         tolerance: ImmediateScheduler.SchedulerTimeType.Stride, options: ImmediateScheduler.SchedulerOptions?,
                         _ action: @escaping () -> Void) -> any Cancellable {
        action()
        return AnyCancellable {}
    }
}

