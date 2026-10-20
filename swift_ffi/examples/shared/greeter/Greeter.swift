import IsomerFFI

// A free function crossing the boundary by value: the String is copied on the
// way in and on the way out, so Kotlin sees kotlin.String and TypeScript sees
// string — never a foreign handle.
@ExportedFunction
public func greeting(for name: String) -> String {
    "Hello from Swift, \(name)!"
}

// Scalars cross directly over the flat C ABI.
@ExportedFunction
public func add(_ a: Int, _ b: Int) -> Int {
    a + b
}

@ExportedFunction
public func isEven(_ n: Int) -> Bool {
    n % 2 == 0
}

// An exported interface: instances cross as owned handles with an idiomatic
// wrapper on the consumer side (a Kotlin AutoCloseable class, a TypeScript
// class with Symbol.dispose). Swift owns the object; the consumer owns a +1
// reference released via close()/using or the collector backstop.
@ExportedInterface
public protocol Counter {
    func increment() -> Int
    func label() -> String
}

final class BumpCounter: Counter {
    private var count = 0
    private let name: String

    init(name: String) { self.name = name }

    func increment() -> Int {
        count += 1
        return count
    }

    func label() -> String {
        "\(name) is at \(count)"
    }
}

// A factory whose return type is an exported interface: the consumer receives
// an owned wrapper around the boxed Swift instance.
@ExportedFunction
public func makeCounter(named name: String) -> any Counter {
    BumpCounter(name: name)
}

// An interface *parameter* going consumer -> Swift. The caller may pass a
// Swift-owned wrapper back (the handle crosses borrowed) or its own Kotlin /
// TypeScript implementation of Counter (Swift receives a foreign proxy and
// calls back out).
@ExportedFunction
public func describe(counter: any Counter) -> String {
    "counter says: \(counter.label())"
}

// An interface implemented on the *consumer* side: Kotlin / TypeScript code
// implements this protocol and passes it into Swift, which calls back out
// through a generated foreign proxy. Methods take parameters (copied at the
// boundary like everywhere else) and may return values — including an
// interface parameter going Swift -> consumer (`sessionEnded(tally:)` hands
// the consumer an owned Counter).
@ExportedInterface
public protocol GreetingObserver {
    func greetingDelivered(greeting: String, index: Int)
    func shouldContinue(after count: Int) -> Bool
    func sessionEnded(tally: any Counter)
}

// Drives a consumer-implemented observer: delivers greetings one at a time
// until the observer declines or the limit is reached, hands the observer the
// running tally, and returns how many were delivered.
@ExportedFunction
public func deliverGreetings(to observer: any GreetingObserver, name: String, limit: Int) -> Int {
    let tally = BumpCounter(name: "tally")
    var delivered = 0
    while delivered < limit {
        delivered = tally.increment()
        observer.greetingDelivered(greeting: "Hello, \(name) #\(delivered)!", index: delivered)
        if !observer.shouldContinue(after: delivered) { break }
    }
    observer.sessionEnded(tally: tally)
    return delivered
}

// A failure crossing the bridge: consumers see the description as the error
// message (Kotlin `Result.failure(SwiftError)`, TypeScript `{ ok: false }`).
public struct GreeterError: Error, CustomStringConvertible {
    public let description: String
}

// A throwing function bridges as a Result on the consumer side.
@ExportedFunction
public func requireEven(_ n: Int) throws -> Int {
    guard n.isMultiple(of: 2) else { throw GreeterError(description: "\(n) is odd") }
    return n / 2
}

// Returning Result<T, E> bridges identically to throwing.
@ExportedFunction
public func parseNumber(text: String) -> Result<Int, GreeterError> {
    guard let value = Int(text) else {
        return .failure(GreeterError(description: "not a number: \(text)"))
    }
    return .success(value)
}

// A flat value struct, copied field-wise at the boundary: Kotlin sees a data
// class, TypeScript a plain object.
@ExportedStruct
public struct TextMetrics {
    public let width: Double
    public let height: Double
    public let label: String
}

@ExportedFunction
public func measure(text: String, fontSize: Double) -> TextMetrics {
    TextMetrics(
        width: Double(text.count) * fontSize * 0.6,
        height: fontSize * 1.3,
        label: text.uppercased())
}

@ExportedFunction
public func area(of metrics: TextMetrics) -> Double {
    metrics.width * metrics.height
}

// A consumer-implemented interface whose method *returns* a struct: the
// object literal / Kotlin object hands a field-wise copy back to Swift.
@ExportedInterface
public protocol MetricsProvider {
    func metrics(scale: Double) -> TextMetrics
}

@ExportedFunction
public func describeMetrics(from provider: any MetricsProvider) -> String {
    let m = provider.metrics(scale: 2.0)
    return "\(m.label): \(m.width)x\(m.height)"
}

// Raw bytes cross by copy, like strings: Kotlin sees ByteArray, TypeScript
// sees Uint8Array.
@ExportedFunction
public func checksum(of data: [UInt8]) -> Int {
    data.reduce(0) { ($0 &+ Int($1)) % 251 }
}

@ExportedFunction
public func doubled(bytes: [UInt8]) -> [UInt8] {
    bytes.flatMap { [$0, $0] }
}

// Async functions bridge to Kotlin suspend functions and TypeScript
// Promises; async + throwing composes as a suspend/Promise of Result.
@ExportedFunction
public func fetchMotd() async -> String {
    "Greetings arrive asynchronously."
}

@ExportedFunction
public func fetchNumber(above minimum: Int) async throws -> Int {
    guard minimum < 100 else { throw GreeterError(description: "\(minimum) is too large") }
    return minimum + 1
}

// A timed wait inside the guest (Task.sleep): the job crosses to the host
// through `task_enqueue_after` and comes back once the delay is up.
@ExportedFunction
public func sleepThenAnswer(milliseconds: Int) async -> String {
    try? await Task.sleep(for: .milliseconds(milliseconds))
    return "Slept \(milliseconds) ms."
}

// MARK: - Bridge v2 (docs/bridge_v2.md)

// A generic function over any bridgeable T (scalars, String, [UInt8],
// @ExportedStructs, Result values). No generics exist in the C ABI: values
// erase to the shared wire encoding and re-type in each consumer language
// (Kotlin reified generics, C++ templates, TypeScript type tokens).
@ExportedFunction
public func choose<T: Bridgeable>(_ value: T, or fallback: T, second: Bool) -> T {
    second ? fallback : value
}

// A callback closure crossing consumer -> Swift: Kotlin lambda,
// C++ std::function, TypeScript arrow function.
@ExportedFunction
public func transform(_ value: Int, using transformation: (Int) -> Int) -> Int {
    transformation(value)
}

// A closure with a mixed signature (and a String result built from it).
@ExportedFunction
public func renderList(count: Int, describe: (Int) -> String) -> String {
    (1...max(count, 1)).map { describe($0) }.joined(separator: ", ")
}

// A deferred value: the consumer receives a Lazy handle and the Swift-side
// computation (including this side effect) runs only on first unwrap.
public nonisolated(unsafe) var expensiveGreetingComputations = 0

@ExportedFunction
public func expensiveGreeting(for name: String) -> Lazy<String> {
    Lazy {
        expensiveGreetingComputations += 1
        return "Expensively greeting \(name) (computation #\(expensiveGreetingComputations))"
    }
}

// Result<T, Error> as a first-class *value* (not just the throwing return
// convention): here as a parameter.
@ExportedFunction
public func describeOutcome(_ outcome: Result<Int, any Error>) -> String {
    switch outcome {
    case .success(let value): return "ok(\(value))"
    case .failure(let error): return "err(\(error))"
    }
}

// A raw-value enum crossing by raw value — and usable as a dependency key in
// the wasm DI story.
@ExportedEnum
public enum GreetingTone: String {
    case formal
    case cheerful
}

@ExportedFunction
public func tonedGreeting(name: String, tone: GreetingTone) -> String {
    switch tone {
    case .formal: return "Good day, \(name)."
    case .cheerful: return "Hey hey, \(name)!"
    }
}

// The wasm dependency-injection story (docs/wasm_di.md): the host injects
// services keyed by an exported enum; the guest looks them up lazily.
@ExportedEnum
public enum GreeterDependencyKey: String {
    case counter
}

@ExportedFunction
public func dependentCount() -> Int {
    guard let counter = dependencies[GreeterDependencyKey.counter] as? Lazy<any Counter> else {
        return -1
    }
    return counter.value.increment()
}
