import Combine

// Isomer's Combine, run under a WASI engine (//tools/wasm/wasi_run): the
// subscribers and subjects, demand, each operator's main behaviour, the
// scheduled operators on a scheduler of virtual time, @Published and
// ObservableObject, Future, and `values` with async/await. Each line prints
// "ok" or what differed; the last line is "ok" alone.

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ actual: String, _ expected: String) {
    if actual == expected {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name): got \(actual.debugDescription), want \(expected.debugDescription)")
    }
}

func check<T>(_ name: String, _ actual: [T], _ expected: [T]) where T: Equatable {
    check(name, "\(actual)", "\(expected)")
}

struct Oops: Error, Equatable {}

/// Every value and the completion a publisher sends, once it has finished
/// synchronously.
func record<P: Publisher>(_ publisher: P) -> [String] {
    var events: [String] = []
    let token = publisher.sink(receiveCompletion: { completion in
        switch completion {
        case .finished: events.append("finished")
        case .failure(let error): events.append("failure \(error)")
        }
    }, receiveValue: { events.append("\($0)") })
    _ = token
    return events
}

/// A subscriber that asks for `initial` values, and for `more` after each.
final class Demanding<Input, Failure: Error>: Subscriber {
    var values: [Input] = []
    var completion: Subscribers.Completion<Failure>?
    var subscription: (any Subscription)?
    let initial: Subscribers.Demand
    let more: Subscribers.Demand

    init(initial: Subscribers.Demand, more: Subscribers.Demand = .none) {
        self.initial = initial
        self.more = more
    }

    func receive(subscription: any Subscription) {
        self.subscription = subscription
        if initial > 0 { subscription.request(initial) }
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        values.append(input)
        return more
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        self.completion = completion
    }
}

/// A scheduler of virtual time: work runs when the test advances the
/// clock past it, in time order.
final class TestScheduler: Scheduler {
    struct Time: Strideable {
        typealias Stride = ImmediateScheduler.SchedulerTimeType.Stride
        var ticks: Int
        func distance(to other: Time) -> Stride { Stride(other.ticks - ticks) }
        func advanced(by n: Stride) -> Time { Time(ticks: ticks + n.magnitude) }
    }

    typealias SchedulerTimeType = Time
    typealias SchedulerOptions = Never

    private(set) var now = Time(ticks: 0)
    var minimumTolerance: Time.Stride { 0 }
    private var queue: [(time: Time, order: Int, action: () -> Void)] = []
    private var order = 0

    func schedule(options: Never?, _ action: @escaping () -> Void) {
        enqueue(now, action)
    }

    func schedule(after date: Time, tolerance: Time.Stride, options: Never?, _ action: @escaping () -> Void) {
        enqueue(date, action)
    }

    func schedule(after date: Time, interval: Time.Stride, tolerance: Time.Stride, options: Never?,
                  _ action: @escaping () -> Void) -> any Cancellable {
        enqueue(date, action)
        return AnyCancellable {}
    }

    private func enqueue(_ time: Time, _ action: @escaping () -> Void) {
        order += 1
        queue.append((time, order, action))
    }

    func advance(by ticks: Int) {
        let target = now.ticks + ticks
        while let next = queue.filter({ $0.time.ticks <= target })
            .min(by: { ($0.time.ticks, $0.order) < ($1.time.ticks, $1.order) }) {
            queue.removeAll { $0.order == next.order }
            now = Time(ticks: Swift.max(now.ticks, next.time.ticks))
            next.action()
        }
        now = Time(ticks: target)
    }
}

/// A model as SwiftUI before Observation has them.
class Model: ObservableObject {
    @Published var count = 0
    @Published var name = "a"
    var plain = 1
}

final class SubModel: Model {
    @Published var extra = false
}

final class NoPublished: ObservableObject {}

final class Holder {
    var value = 0
}

/// A decoder of comma-separated integers, for decode(type:decoder:).
struct CSVDecoder: TopLevelDecoder {
    struct Unsupported: Error {}
    func decode<T>(_ type: T.Type, from input: String) throws -> T where T: Decodable {
        guard type == [Int].self else { throw Unsupported() }
        return input.split(separator: ",").compactMap { Int($0) } as! T
    }
}

@main
struct CombineCheck {
    static func main() async {
        checkCore()
        checkSubjects()
        checkSources()
        checkOperators()
        checkCombining()
        checkSwitching()
        checkConnectable()
        checkScheduled()
        checkPublished()
        await checkAsync()
        print(failures == 0 ? "ok" : "FAIL \(failures) checks")
    }

    static func checkCore() {
        // Demand's arithmetic, as Apple's (saturating, unlimited absorbing).
        check("demand add", "\(Subscribers.Demand.max(2) + .max(3))", "max(5)")
        check("demand unlimited", "\(Subscribers.Demand.unlimited + 1)", "unlimited")
        check("demand subtract", "\(Subscribers.Demand.max(1) - .max(3))", "max(0)")
        check("demand compare", "\(Subscribers.Demand.max(3) > 2) \(Subscribers.Demand.unlimited > .max(100)) \(Subscribers.Demand.none == 0)",
              "true true true")
        check("demand max", "\(Subscribers.Demand.max(4).max ?? -1) \(Subscribers.Demand.unlimited.max == nil)", "4 true")

        // sink, then cancel: nothing after.
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let token = subject.sink { received.append($0) }
        subject.send(1)
        subject.send(2)
        token.cancel()
        subject.send(3)
        check("sink cancel", received, [1, 2])

        // An AnyCancellable released cancels.
        received = []
        do {
            let scoped = subject.sink { received.append($0) }
            subject.send(4)
            _ = scoped
        }
        subject.send(5)
        check("cancel on release", received, [4])

        // store(in:).
        var bag = Set<AnyCancellable>()
        var array: [AnyCancellable] = []
        subject.sink { received.append($0) }.store(in: &bag)
        subject.sink { received.append($0 * 10) }.store(in: &array)
        received = []
        subject.send(6)
        check("store", received.sorted(), [6, 60])
        bag.removeAll()
        array.removeAll()
        subject.send(7)
        check("store released", received.sorted(), [6, 60])

        // Backpressure: a subscriber asking for two gets two, then one more
        // when it asks again.
        let demanding = Demanding<Int, Never>(initial: .max(2))
        [1, 2, 3, 4].publisher.subscribe(demanding)
        check("demand limits", demanding.values, [1, 2])
        demanding.subscription?.request(.max(1))
        check("demand more", demanding.values, [1, 2, 3])
        check("demand not finished", "\(demanding.completion == nil)", "true")
        demanding.subscription?.request(.max(1))
        check("demand finished", "\(demanding.values) \(demanding.completion.map { "\($0)" } ?? "none")", "[1, 2, 3, 4] finished")

        // Demand returned from receive adds.
        let adding = Demanding<Int, Never>(initial: .max(1), more: .max(1))
        (1...5).publisher.subscribe(adding)
        check("demand returned", adding.values, [1, 2, 3, 4, 5])

        // A value dropped by an operator asks upstream for another.
        let filtered = Demanding<Int, Never>(initial: .max(2))
        (1...10).publisher.filter { $0 % 3 == 0 }.subscribe(filtered)
        check("filter demand", filtered.values, [3, 6])

        // assign(to:on:).
        let holder = Holder()
        let assigned = [3, 4].publisher.assign(to: \.value, on: holder)
        check("assign on", "\(holder.value)", "4")
        _ = assigned

        // AnySubscriber and AnyPublisher.
        var anyValues: [Int] = []
        let anySubscriber = AnySubscriber<Int, Never>(receiveSubscription: { $0.request(.unlimited) },
                                                      receiveValue: { anyValues.append($0); return .none })
        Just(9).eraseToAnyPublisher().subscribe(anySubscriber)
        check("AnySubscriber", anyValues, [9])
        check("equatable", "\(Just(1) == Just(1)) \(Subscribers.Completion<Oops>.failure(Oops()) == .finished) \([1].publisher.first() == [1].publisher.first())",
              "true false true")
        check("CombineIdentifier", "\(CombineIdentifier() != CombineIdentifier())", "true")
    }

    static func checkSubjects() {
        let current = CurrentValueSubject<Int, Oops>(1)
        var values: [String] = []
        let token = current.sink(receiveCompletion: { values.append("\($0)") }, receiveValue: { values.append("\($0)") })
        current.send(2)
        current.value = 3
        check("current value", "\(current.value)", "3")
        current.send(completion: .failure(Oops()))
        current.send(4)
        check("current subject", values, ["1", "2", "3", "failure(CombineCheck.Oops())"])
        _ = token

        // A late subscriber of a completed subject gets the completion.
        check("late completion", record(current), ["failure Oops()"])

        // A current-value subject gives each subscriber the latest when it asks.
        let latest = CurrentValueSubject<String, Never>("a")
        let waiting = Demanding<String, Never>(initial: .none)
        latest.subscribe(waiting)
        latest.send("b")
        latest.send("c")
        waiting.subscription?.request(.max(1))
        check("current latest on request", waiting.values, ["c"])

        // A passthrough subject drops values for subscribers with no demand.
        let passthrough = PassthroughSubject<Int, Never>()
        let lazy = Demanding<Int, Never>(initial: .none)
        passthrough.subscribe(lazy)
        passthrough.send(1)
        lazy.subscription?.request(.max(1))
        passthrough.send(2)
        passthrough.send(3)
        check("passthrough demand", lazy.values, [2])

        // Feeding a subject from a publisher.
        let fed = PassthroughSubject<Int, Never>()
        var fedValues: [Int] = []
        let fedToken = fed.sink { fedValues.append($0) }
        let feed = [1, 2].publisher.subscribe(fed)
        check("subscribe subject", fedValues, [1, 2])
        _ = (fedToken, feed)

        // Subject with Output == Void.
        let void = PassthroughSubject<Void, Never>()
        var pings = 0
        let voidToken = void.sink { pings += 1 }
        void.send()
        check("send()", "\(pings)", "1")
        _ = voidToken
    }

    static func checkSources() {
        check("Just", record(Just(1)), ["1", "finished"])
        check("Empty", record(Empty<Int, Never>()), ["finished"])
        check("Fail", record(Fail<Int, Oops>(error: Oops())), ["failure Oops()"])
        check("Optional", record(Optional(5).publisher) + record(Optional<Int>.none.publisher), ["5", "finished", "finished"])
        check("Result", record(Result<Int, Oops>.success(2).publisher) + record(Result<Int, Oops>.failure(Oops()).publisher),
              ["2", "finished", "failure Oops()"])
        check("Sequence", record([1, 2, 3].publisher), ["1", "2", "3", "finished"])
        check("Record", record(Record<Int, Oops>(output: [1, 2], completion: .failure(Oops()))),
              ["1", "2", "failure Oops()"])
        check("Record builder", record(Record<Int, Never> { $0.receive(7); $0.receive(completion: .finished) }),
              ["7", "finished"])

        var made = 0
        let deferred = Deferred { () -> Just<Int> in
            made += 1
            return Just(made)
        }
        check("Deferred", record(deferred) + record(deferred), ["1", "finished", "2", "finished"])

        // Future: runs once, at once; every subscriber gets its result.
        var runs = 0
        var promise: Future<Int, Never>.Promise?
        let future = Future<Int, Never> { fulfil in
            runs += 1
            promise = fulfil
        }
        var early: [Int] = []
        let earlyToken = future.sink { early.append($0) }
        promise?(.success(8))
        check("Future", "\(runs) \(early) \(record(future))", "1 [8] [\"8\", \"finished\"]")
        _ = earlyToken

        // Just's own operators answer with Apple's types.
        let mapped: Just<String> = Just(2).map { "\($0)" }
        let filtered: Optional<Int>.Publisher = Just(2).filter { $0 > 5 }
        let tried: Result<Int, any Error>.Publisher = Just(2).tryMap { _ in throw Oops() }
        check("Just operators", "\(mapped.output) \(record(filtered)) \(record(tried).count)", "2 [\"finished\"] 1")
    }

    static func checkOperators() {
        check("map", record([1, 2].publisher.map { $0 * 10 }), ["10", "20", "finished"])
        check("map key path", record([Holder()].publisher.map(\.value)), ["0", "finished"])
        check("tryMap", record([1, 2, 3].publisher.tryMap { value -> Int in
            if value == 2 { throw Oops() }
            return value
        }), ["1", "failure Oops()"])
        check("compactMap", record(["1", "x", "3"].publisher.compactMap { Int($0) }), ["1", "3", "finished"])
        check("filter", record((1...6).publisher.filter { $0.isMultiple(of: 2) }), ["2", "4", "6", "finished"])
        check("removeDuplicates", record([1, 1, 2, 2, 1].publisher.removeDuplicates()), ["1", "2", "1", "finished"])
        check("removeDuplicates by", record([1, 3, 4, 6].publisher.removeDuplicates { $0 % 2 == $1 % 2 }),
              ["1", "4", "finished"])
        check("first", record((1...3).publisher.first()), ["1", "finished"])
        check("first where", record((1...5).publisher.first { $0 > 3 }), ["4", "finished"])
        check("first empty", record(Empty<Int, Never>().first()), ["finished"])
        check("dropFirst", record((1...4).publisher.dropFirst(2)), ["3", "4", "finished"])
        check("drop while", record([1, 2, 5, 1].publisher.drop { $0 < 3 }), ["5", "1", "finished"])
        check("prefix", record((1...10).publisher.prefix(2)), ["1", "2", "finished"])
        check("prefix while", record([1, 2, 5, 1].publisher.prefix { $0 < 3 }), ["1", "2", "finished"])
        check("output at", record((1...10).publisher.output(at: 3)), ["4", "finished"])
        check("output in", record((1...10).publisher.output(in: 2...3)), ["3", "4", "finished"])
        check("scan", record((1...4).publisher.scan(0, +)), ["1", "3", "6", "10", "finished"])
        check("reduce", record((1...4).publisher.reduce(0, +)), ["10", "finished"])
        check("collect", record((1...3).publisher.collect()), ["[1, 2, 3]", "finished"])
        check("collect count", record((1...5).publisher.collect(2)), ["[1, 2]", "[3, 4]", "[5]", "finished"])
        check("count", record((1...7).publisher.count()), ["7", "finished"])
        check("last", record((1...3).publisher.last()), ["3", "finished"])
        check("last where", record((1...6).publisher.last { $0 < 3 }), ["2", "finished"])
        check("min max", record([3, 1, 2].publisher.min()) + record([3, 1, 4].publisher.max()),
              ["1", "finished", "4", "finished"])
        check("contains", record((1...3).publisher.contains(2)) + record((1...3).publisher.contains(9)),
              ["true", "finished", "false", "finished"])
        check("allSatisfy", record([2, 4].publisher.allSatisfy { $0.isMultiple(of: 2) }), ["true", "finished"])
        check("ignoreOutput", record((1...3).publisher.ignoreOutput()), ["finished"])
        check("replaceNil", record([1, nil, 3].publisher.eraseToAnyPublisher().replaceNil(with: 0)), ["1", "0", "3", "finished"])
        // A sequence's own overload keeps the optional type, as Apple's does.
        check("replaceNil sequence", record([1, nil].publisher.replaceNil(with: 0)), ["Optional(1)", "Optional(0)", "finished"])
        check("sequence count", "\([1, 2, 3].publisher.count().output)", "3")
        check("replaceError", record(Fail<Int, Oops>(error: Oops()).replaceError(with: 5)), ["5", "finished"])
        check("replaceEmpty", record(Empty<Int, Never>().replaceEmpty(with: 6)), ["6", "finished"])
        check("mapError", record(Fail<Int, Oops>(error: Oops()).mapError { _ in CSVDecoder.Unsupported() }),
              ["failure Unsupported()"])
        check("setFailureType", record(Just(1).setFailureType(to: Oops.self).eraseToAnyPublisher()), ["1", "finished"])
        check("append prepend", record([2].publisher.prepend(1).append(3, 4)), ["1", "2", "3", "4", "finished"])
        check("decode", record(Just("1,2,3").decode(type: [Int].self, decoder: CSVDecoder())), ["[1, 2, 3]", "finished"])

        var events: [String] = []
        let handled = (1...2).publisher.handleEvents(
            receiveSubscription: { _ in events.append("subscription") },
            receiveOutput: { events.append("output \($0)") },
            receiveCompletion: { _ in events.append("completion") },
            receiveRequest: { events.append("request \($0)") })
        _ = record(handled)
        check("handleEvents", events, ["subscription", "request unlimited", "output 1", "output 2", "completion"])

        var cancelled = false
        let subject = PassthroughSubject<Int, Never>()
        let token = subject.handleEvents(receiveCancel: { cancelled = true }).sink { _ in }
        token.cancel()
        check("handleEvents cancel", "\(cancelled)", "true")

        // print, into a stream of the test's own.
        final class Lines: TextOutputStream {
            var text = ""
            func write(_ string: String) { text += string }
        }
        let lines = Lines()
        _ = record(Just(1).print("p", to: lines))
        check("print", lines.text.contains("p: receive value: (1)") && lines.text.contains("p: receive finished") ? "yes" : lines.text,
              "yes")
    }

    static func checkCombining() {
        let a = PassthroughSubject<Int, Never>()
        let b = PassthroughSubject<Int, Never>()
        var merged: [Int] = []
        var mergedDone = false
        let mergeToken = a.merge(with: b).sink(receiveCompletion: { _ in mergedDone = true }, receiveValue: { merged.append($0) })
        a.send(1)
        b.send(2)
        a.send(3)
        a.send(completion: .finished)
        check("merge not done", "\(mergedDone)", "false")
        b.send(4)
        b.send(completion: .finished)
        check("merge", "\(merged) \(mergedDone)", "[1, 2, 3, 4] true")
        _ = mergeToken

        check("merge sequences", record([1, 2].publisher.merge(with: [3].publisher)), ["1", "2", "3", "finished"])
        check("merge 5", record(Just(1).merge(with: Just(2), Just(3), Just(4), Just(5))), ["1", "2", "3", "4", "5", "finished"])

        // A buffer keeps what downstream hasn't asked for, dropping the oldest when full.
        let buffered = Demanding<Int, Never>(initial: .none)
        let bufferSource = PassthroughSubject<Int, Never>()
        bufferSource.buffer(size: 2, prefetch: .byRequest, whenFull: .dropOldest).subscribe(buffered)
        buffered.subscription?.request(.max(1))
        bufferSource.send(1)
        bufferSource.send(2)
        bufferSource.send(3)
        bufferSource.send(4)
        buffered.subscription?.request(.max(5))
        check("buffer", buffered.values, [1, 3, 4])

        check("MergeMany", record(Publishers.MergeMany([Just(1), Just(2), Just(3)])), ["1", "2", "3", "finished"])

        // Merge with limited demand: two at a time.
        let limited = Demanding<Int, Never>(initial: .max(2))
        [1, 2, 3].publisher.merge(with: [4, 5].publisher).subscribe(limited)
        check("merge demand", "\(limited.values.count)", "2")
        limited.subscription?.request(.unlimited)
        check("merge demand rest", "\(limited.values.sorted()) \(limited.completion != nil)", "[1, 2, 3, 4, 5] true")

        let x = PassthroughSubject<Int, Never>()
        let y = PassthroughSubject<String, Never>()
        var combined: [String] = []
        let combineToken = x.combineLatest(y).sink { combined.append("\($0)\($1)") }
        x.send(1)
        y.send("a")
        x.send(2)
        y.send("b")
        check("combineLatest", combined, ["1a", "2a", "2b"])
        _ = combineToken

        let z = PassthroughSubject<Bool, Never>()
        var combined3: [String] = []
        let combine3Token = x.combineLatest(y, z) { "\($0)\($1)\($2)" }.sink { combined3.append($0) }
        x.send(3)
        y.send("c")
        z.send(true)
        x.send(4)
        check("combineLatest3", combined3, ["3ctrue", "4ctrue"])
        _ = combine3Token

        var zipped: [String] = []
        let zipToken = x.zip(y).sink { zipped.append("\($0)\($1)") }
        x.send(1)
        x.send(2)
        y.send("a")
        y.send("b")
        y.send("c")
        check("zip", zipped, ["1a", "2b"])
        _ = zipToken

        // zip with an endless sequence stays bounded by demand.
        let endless = Demanding<String, Never>(initial: .max(2))
        (0...).publisher.zip(["a", "b"].publisher).map { "\($0)\($1)" }.subscribe(endless)
        check("zip endless", "\(endless.values) \(endless.completion != nil)", "[\"0a\", \"1b\"] true")

        check("flatMap", record([1, 2].publisher.flatMap { [$0, $0 * 10].publisher }), ["1", "10", "2", "20", "finished"])
        var created = 0
        let outer = PassthroughSubject<Int, Never>()
        let inners = (0..<3).map { _ in PassthroughSubject<Int, Never>() }
        var flat: [Int] = []
        let flatToken = outer.flatMap(maxPublishers: .max(1)) { index -> PassthroughSubject<Int, Never> in
            created += 1
            return inners[index]
        }.sink { flat.append($0) }
        outer.send(0)
        // No room for a second: the subject drops it, as it drops any value
        // not asked for.
        outer.send(2)
        check("flatMap max publishers", "\(created)", "1")
        inners[0].send(5)
        inners[0].send(completion: .finished)
        outer.send(1)
        inners[1].send(6)
        check("flatMap next publisher", "\(created) \(flat)", "2 [5, 6]")
        _ = flatToken
    }

    static func checkSwitching() {
        let outer = PassthroughSubject<PassthroughSubject<Int, Never>, Never>()
        let first = PassthroughSubject<Int, Never>()
        let second = PassthroughSubject<Int, Never>()
        var values: [Int] = []
        var done = false
        let token = outer.switchToLatest().sink(receiveCompletion: { _ in done = true }, receiveValue: { values.append($0) })
        outer.send(first)
        first.send(1)
        outer.send(second)
        first.send(2)
        second.send(3)
        outer.send(completion: .finished)
        check("switchToLatest open", "\(done)", "false")
        second.send(completion: .finished)
        check("switchToLatest", "\(values) \(done)", "[1, 3] true")
        _ = token

        check("catch", record(Fail<Int, Oops>(error: Oops()).catch { _ in Just(7) }), ["7", "finished"])
        check("tryCatch", record(Fail<Int, Oops>(error: Oops()).tryCatch { _ -> Just<Int> in throw CSVDecoder.Unsupported() }),
              ["failure Unsupported()"])
        var attempts = 0
        let flaky = Deferred { () -> AnyPublisher<Int, Oops> in
            attempts += 1
            return attempts < 3 ? Fail(error: Oops()).eraseToAnyPublisher() : Just(attempts).setFailureType(to: Oops.self).eraseToAnyPublisher()
        }
        check("retry", record(flaky.retry(5)), ["3", "finished"])
        attempts = 0
        check("retry gives up", record(flaky.retry(1)), ["failure Oops()"])

        let source = PassthroughSubject<Int, Never>()
        let stop = PassthroughSubject<Void, Never>()
        var prefixed: [Int] = []
        var prefixDone = false
        let prefixToken = source.prefix(untilOutputFrom: stop)
            .sink(receiveCompletion: { _ in prefixDone = true }, receiveValue: { prefixed.append($0) })
        source.send(1)
        stop.send()
        source.send(2)
        check("prefix untilOutputFrom", "\(prefixed) \(prefixDone)", "[1] true")
        _ = prefixToken

        let start = PassthroughSubject<Void, Never>()
        var dropped: [Int] = []
        let dropToken = source.drop(untilOutputFrom: start).sink { dropped.append($0) }
        source.send(1)
        start.send()
        source.send(2)
        check("drop untilOutputFrom", dropped, [2])
        _ = dropToken
    }

    static func checkConnectable() {
        var subscriptions = 0
        let upstream = [1, 2].publisher.handleEvents(receiveSubscription: { _ in subscriptions += 1 })

        let multicast = upstream.multicast { PassthroughSubject<Int, Never>() }
        var one: [Int] = []
        var two: [Int] = []
        let t1 = multicast.sink { one.append($0) }
        let t2 = multicast.sink { two.append($0) }
        check("multicast waits", "\(one)", "[]")
        let connection = multicast.connect()
        check("multicast", "\(one) \(two) \(subscriptions)", "[1, 2] [1, 2] 1")
        _ = (t1, t2, connection)

        let subject = PassthroughSubject<Int, Never>()
        var shareSubscriptions = 0
        let shared = subject.handleEvents(receiveSubscription: { _ in shareSubscriptions += 1 }).share()
        var s1: [Int] = []
        var s2: [Int] = []
        let st1 = shared.sink { s1.append($0) }
        let st2 = shared.sink { s2.append($0) }
        subject.send(1)
        check("share", "\(s1) \(s2) \(shareSubscriptions)", "[1] [1] 1")
        st1.cancel()
        st2.cancel()
        let st3 = shared.sink { s1.append($0) }
        check("share reconnects", "\(shareSubscriptions)", "2")
        _ = st3

        let connectable = Just(4).makeConnectable()
        var late: [Int] = []
        let lateToken = connectable.sink { late.append($0) }
        check("makeConnectable waits", "\(late)", "[]")
        let lateConnection = connectable.connect()
        check("makeConnectable", "\(late)", "[4]")
        _ = (lateToken, lateConnection)

        check("autoconnect", record(Just(5).makeConnectable().autoconnect()), ["5", "finished"])
    }

    static func checkScheduled() {
        check("receive on immediate", record((1...2).publisher.receive(on: ImmediateScheduler.shared)), ["1", "2", "finished"])
        check("subscribe on immediate", record(Just(1).subscribe(on: ImmediateScheduler.shared)), ["1", "finished"])

        let scheduler = TestScheduler()
        let input = PassthroughSubject<Int, Never>()

        var debounced: [Int] = []
        let debounceToken = input.debounce(for: 10, scheduler: scheduler).sink { debounced.append($0) }
        input.send(1)
        scheduler.advance(by: 5)
        input.send(2)
        scheduler.advance(by: 9)
        check("debounce waits", debounced, [])
        scheduler.advance(by: 1)
        check("debounce", debounced, [2])
        debounceToken.cancel()

        var throttled: [Int] = []
        let throttleToken = input.throttle(for: 10, scheduler: scheduler, latest: true).sink { throttled.append($0) }
        input.send(1)
        scheduler.advance(by: 0)
        input.send(2)
        input.send(3)
        scheduler.advance(by: 10)
        check("throttle latest", throttled, [1, 3])
        throttleToken.cancel()

        var firsts: [Int] = []
        let firstToken = input.throttle(for: 10, scheduler: scheduler, latest: false).sink { firsts.append($0) }
        input.send(1)
        scheduler.advance(by: 0)
        input.send(2)
        input.send(3)
        scheduler.advance(by: 10)
        check("throttle first", firsts, [1, 2])
        firstToken.cancel()

        var delayed: [String] = []
        let delayToken = input.delay(for: 5, scheduler: scheduler)
            .sink(receiveCompletion: { _ in delayed.append("done") }, receiveValue: { delayed.append("\($0)") })
        input.send(7)
        scheduler.advance(by: 4)
        check("delay waits", delayed, [])
        scheduler.advance(by: 1)
        check("delay", delayed, ["7"])
        delayToken.cancel()

        let silent = PassthroughSubject<Int, Oops>()
        var timedOut: [String] = []
        let timeoutToken = silent.timeout(5, scheduler: scheduler, customError: { Oops() })
            .sink(receiveCompletion: { timedOut.append("\($0)") }, receiveValue: { timedOut.append("\($0)") })
        scheduler.advance(by: 3)
        silent.send(1)
        scheduler.advance(by: 4)
        check("timeout restarts", timedOut, ["1"])
        scheduler.advance(by: 1)
        check("timeout", timedOut, ["1", "failure(CombineCheck.Oops())"])
        _ = timeoutToken

        var batches: [[Int]] = []
        let collectToken = input.collect(.byTimeOrCount(scheduler, 10, 3)).sink { batches.append($0) }
        input.send(1)
        input.send(2)
        scheduler.advance(by: 10)
        input.send(3)
        input.send(4)
        input.send(5)
        check("collect by time or count", batches, [[1, 2], [3, 4, 5]])
        collectToken.cancel()

        var intervals: [Int] = []
        let measureToken = input.measureInterval(using: scheduler).sink { intervals.append($0.magnitude) }
        scheduler.advance(by: 3)
        input.send(0)
        scheduler.advance(by: 4)
        input.send(0)
        check("measureInterval", intervals, [3, 4])
        _ = measureToken
    }

    static func checkPublished() {
        let model = Model()
        var log: [String] = []
        // objectWillChange comes before the change: the model still has the
        // old value when it fires.
        let willChange = model.objectWillChange.sink { log.append("will \(model.count)") }
        let projected = model.$count.sink { log.append("$count \($0) while \(model.count)") }
        model.count = 1
        model.count = 2
        model.plain = 5
        check("Published", log, ["$count 0 while 0", "will 0", "$count 1 while 0", "will 1", "$count 2 while 1"])
        check("objectWillChange is one publisher", "\(model.objectWillChange === model.objectWillChange)", "true")

        // Every @Published property sends it, the superclass's too.
        let sub = SubModel()
        var subChanges = 0
        let subToken = sub.objectWillChange.sink { subChanges += 1 }
        sub.name = "b"
        sub.extra = true
        sub.count += 1
        check("Published in a subclass", "\(subChanges) \(sub.name) \(sub.extra) \(sub.count)", "3 b true 1")

        // assign(to: &$property): each value set as a set through the
        // property is, objectWillChange first.
        let subject = PassthroughSubject<Int, Never>()
        subject.assign(to: &model.$count)
        log = []
        subject.send(10)
        check("assign to Published", "\(model.count) \(log)", "10 [\"will 2\", \"$count 10 while 2\"]")

        // No @Published: a publisher nothing sends.
        _ = NoPublished().objectWillChange.sink {}
        _ = (willChange, projected, subToken)
    }

    static func checkAsync() async {
        var values: [Int] = []
        for await value in (1...3).publisher.values {
            values.append(value)
        }
        check("values", values, [1, 2, 3])

        var thrown = ""
        do {
            for try await value in [1, 2].publisher.setFailureType(to: Oops.self).append(Fail(error: Oops())).values {
                values.append(value)
            }
        } catch {
            thrown = "\(error)"
        }
        check("values throwing", "\(values) \(thrown)", "[1, 2, 3, 1, 2] Oops()")

        let future = Future<Int, Never> { $0(.success(42)) }
        check("Future.value", "\(await future.value)", "42")
        let failing = Future<Int, Oops> { $0(.failure(Oops())) }
        do {
            _ = try await failing.value
            check("Future.value throws", "no", "Oops()")
        } catch {
            check("Future.value throws", "\(error)", "Oops()")
        }

        // A subject's values arrive as sent, from another task.
        let subject = PassthroughSubject<Int, Never>()
        let reader = Task { () -> [Int] in
            var got: [Int] = []
            for await value in subject.values {
                got.append(value)
                if got.count == 2 { break }
            }
            return got
        }
        // Let the reader subscribe and wait.
        for _ in 0..<10 { await Task.yield() }
        subject.send(1)
        for _ in 0..<10 { await Task.yield() }
        subject.send(2)
        check("values from a subject", await reader.value, [1, 2])
    }
}
