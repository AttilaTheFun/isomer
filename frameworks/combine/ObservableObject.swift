// ObservableObject and @Published, as SwiftUI before Observation takes
// them: a class whose @Published properties send its objectWillChange just
// before each change.
//
// Where the object's publisher lives: in its @Published properties. Each
// Published keeps a reference to a box (PublishedStorage) holding its value,
// its own subscribers, and a slot for the enclosing object's
// ObservableObjectPublisher. The default objectWillChange reads the object's
// stored properties with Mirror (its superclasses' too), takes the publisher
// from the first Published's slot, or makes one and puts it in every
// Published's slot. A set through the property (Published's
// `_enclosingInstance` subscript) or through `assign(to: &$property)` then
// sends that publisher before the value changes. Nothing outlives the
// object: the publisher is kept only in its properties.
//
// An object with no @Published property has nowhere to keep one, so it
// gets a new publisher at each read, which nothing sends (Apple's behaves
// the same; such an object declares its own objectWillChange to send).

public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher: Publisher = ObservableObjectPublisher
    where Self.ObjectWillChangePublisher.Failure == Never

    var objectWillChange: Self.ObjectWillChangePublisher { get }
}

final public class ObservableObjectPublisher: Publisher {
    public typealias Output = Void
    public typealias Failure = Never

    private let core = SubjectCore<Void, Never>()

    public init() {}

    final public func receive<S>(subscriber: S) where S: Subscriber, S.Failure == Never, S.Input == () {
        core.attach(subscriber)
    }

    final public func send() {
        core.broadcast(())
    }
}

extension ObservableObject where Self.ObjectWillChangePublisher == ObservableObjectPublisher {
    public var objectWillChange: ObservableObjectPublisher {
        var slots: [PublishedSlot] = []
        var mirror: Mirror? = Mirror(reflecting: self)
        while let current = mirror {
            for child in current.children {
                if let slot = PublishedSlot.of(child.value) {
                    // Found already: the publisher made at an earlier read.
                    if let publisher = slot.objectWillChange { return publisher }
                    slots.append(slot)
                }
            }
            mirror = current.superclassMirror
        }
        let publisher = ObservableObjectPublisher()
        // Installed in every one (if two reads race, the first to install
        // wins and both return it).
        var chosen: ObservableObjectPublisher?
        for slot in slots {
            let installed = slot.install(publisher)
            if chosen == nil { chosen = installed }
        }
        return chosen ?? publisher
    }
}

/// What every Published's storage has, whatever its Value: the slot for
/// the enclosing object's publisher.
class PublishedSlot {
    private let slotLock = Lock()
    private var publisher: ObservableObjectPublisher?

    var objectWillChange: ObservableObjectPublisher? {
        slotLock.withLock { publisher }
    }

    /// Puts `candidate` in the slot unless one is there; returns the one there.
    func install(_ candidate: ObservableObjectPublisher) -> ObservableObjectPublisher {
        slotLock.withLock {
            if let publisher { return publisher }
            publisher = candidate
            return candidate
        }
    }

    /// The slot of a Published, read from an object's Mirror child (a
    /// Published<Value> whose one stored property is its storage).
    static func of(_ value: Any) -> PublishedSlot? {
        let type = "\(Swift.type(of: value))"
        guard type.hasPrefix("Published<") else { return nil }
        return Mirror(reflecting: value).children.first?.value as? PublishedSlot
    }
}

/// A Published's value and subscribers. A set sends the object's
/// publisher, then the value to the property's own subscribers (who see the
/// new value while the property still has the old one, as Apple's do), and
/// then stores it.
final class PublishedStorage<Value>: PublishedSlot {
    let subject: SubjectCore<Value, Never>
    /// `assign(to: &$property)`'s subscription, for as long as the property.
    var assignment: AnyCancellable?

    init(_ value: Value) {
        subject = SubjectCore(current: value)
    }

    var value: Value {
        subject.current!
    }

    func set(_ newValue: Value) {
        objectWillChange?.send()
        subject.broadcast(newValue)
        subject.setCurrent(newValue)
    }
}

@propertyWrapper public struct Published<Value> {
    // The only stored property (PublishedSlot.of reads it so).
    let storage: PublishedStorage<Value>

    @_alwaysEmitIntoClient
    public init(wrappedValue: Value) {
        self.init(initialValue: wrappedValue)
    }

    public init(initialValue: Value) {
        storage = PublishedStorage(initialValue)
    }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError("@Published is only available on properties of classes") }
        set { fatalError("@Published is only available on properties of classes") }
    }

    /// The property, read and set through the object holding it.
    public static subscript<EnclosingSelf>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Published<Value>>
    ) -> Value where EnclosingSelf: AnyObject {
        get { object[keyPath: storageKeyPath].storage.value }
        set { object[keyPath: storageKeyPath].storage.set(newValue) }
    }

    /// The property's values: the current one when asked, then each new
    /// one as it is set.
    public struct Publisher: Combine.Publisher {
        public typealias Output = Value
        public typealias Failure = Never

        let storage: PublishedStorage<Value>

        public func receive<S>(subscriber: S) where Value == S.Input, S: Subscriber, S.Failure == Never {
            storage.subject.attach(subscriber)
        }
    }

    public var projectedValue: Published<Value>.Publisher {
        mutating get { Publisher(storage: storage) }
        _modify {
            var publisher = Publisher(storage: storage)
            yield &publisher
        }
    }
}

extension Publisher where Self.Failure == Never {
    /// Republishes into a @Published property (`assign(to: &$value)`): each
    /// value is set as a set through the property is, the object's
    /// publisher sent first. The subscription lasts as long as the
    /// property (replacing any earlier one); no token to keep.
    public func assign(to published: inout Published<Self.Output>.Publisher) {
        let storage = published.storage
        storage.assignment = nil
        storage.assignment = sink { [weak storage] value in storage?.set(value) }
    }
}
