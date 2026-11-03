// OperationQueue, as far as code hands it blocks: the main queue (what
// NotificationCenter's `addObserver(forName:object:queue:using:)` is most
// often given) and queues of an app's own. A block runs as a Swift task: the
// main queue's on the main actor, in the order added; another queue's off
// it. No Operation objects, dependencies, priorities or suspension: Swift
// concurrency is how Isomer's apps schedule work (docs/parity/Foundation.md).

open class OperationQueue: NSObject, @unchecked Sendable {
    private let isMain: Bool

    /// The queue whose operations run on the main actor.
    open class var main: OperationQueue { mainQueue }

    public override init() {
        isMain = false
    }

    private init(main: Bool) {
        isMain = main
    }

    open var name: String?

    /// `block` run soon, after the blocks added before it on the main queue.
    open func addOperation(_ block: @escaping @Sendable () -> Void) {
        if isMain {
            Task { @MainActor in block() }
        } else {
            Task.detached { block() }
        }
    }

    private static let mainQueue = OperationQueue(main: true)
}
