// URLSessionTask and its data, upload and download kinds, as Apple's
// Foundation has them, without delegates or progress. A task is made
// suspended; `resume()` starts its load on a task of its own, and what it
// got goes to its completion handler once. `cancel()` ends it at once with
// URLError.cancelled (the transport is asked to stop, and what it returns
// after is dropped). `suspend()` keeps a task that has not started from
// starting; one already loading carries on, as an exchange through a
// host's transport cannot be paused.

import FoundationEssentials
import Synchronization

open class URLSessionTask: Hashable, @unchecked Sendable {
    public enum State: Int, Sendable {
        case running = 0
        case suspended = 1
        case canceling = 2
        case completed = 3
    }

    public static let defaultPriority: Float = 0.5
    public static let lowPriority: Float = 0
    public static let highPriority: Float = 1

    /// What a task's load ended with.
    enum _Outcome: Sendable {
        case loaded(Data, URLResponse)
        case failed(any Error, URLResponse?)
        /// A WebSocket task's connection closed.
        case ended
    }

    struct _Status: Sendable {
        var state: State = .suspended
        var started = false
        var finished = false
        var work: Task<Void, Never>?
        var currentRequest: URLRequest?
        var response: URLResponse?
        var error: (any Error)?
        var priority = URLSessionTask.defaultPriority
        var taskDescription: String?
        var earliestBeginDate: Date?
        var prefersIncrementalDelivery = true
        var countOfBytesSent: Int64 = 0
        var countOfBytesExpectedToSend: Int64 = 0
        var countOfBytesReceived: Int64 = 0
        var countOfBytesExpectedToReceive: Int64 = 0
        var countOfBytesClientExpectsToSend: Int64 = -1
        var countOfBytesClientExpectsToReceive: Int64 = -1
    }

    let session: URLSession
    private let identifier: Int
    private let request: URLRequest?
    let status = Mutex(_Status())

    init(session: URLSession, identifier: Int, request: URLRequest?) {
        self.session = session
        self.identifier = identifier
        self.request = request
        status.withLock { $0.currentRequest = request }
    }

    /// The task's number in its session, from 1.
    open var taskIdentifier: Int { identifier }

    /// The request the task was made with.
    open var originalRequest: URLRequest? { request }

    /// The request as it is being sent.
    open var currentRequest: URLRequest? { status.withLock { $0.currentRequest } }

    /// The response, once there is one.
    open var response: URLResponse? { status.withLock { $0.response } }

    /// Why the task failed, once it has; nil while it runs and when it
    /// succeeded.
    open var error: (any Error)? { status.withLock { $0.error } }

    open var state: State { status.withLock { $0.state } }

    /// Kept, not acted on: the platform's stack orders its own work.
    open var priority: Float {
        get { status.withLock { $0.priority } }
        set { status.withLock { $0.priority = newValue } }
    }

    open var taskDescription: String? {
        get { status.withLock { $0.taskDescription } }
        set { status.withLock { $0.taskDescription = newValue } }
    }

    /// When a background session's task may begin; as on Apple platforms,
    /// a task of any other session begins when resumed.
    open var earliestBeginDate: Date? {
        get { status.withLock { $0.earliestBeginDate } }
        set { status.withLock { $0.earliestBeginDate = newValue } }
    }

    /// Kept, not acted on: a transport hands over a body whole.
    open var prefersIncrementalDelivery: Bool {
        get { status.withLock { $0.prefersIncrementalDelivery } }
        set { status.withLock { $0.prefersIncrementalDelivery = newValue } }
    }

    open var countOfBytesSent: Int64 { status.withLock { $0.countOfBytesSent } }
    open var countOfBytesExpectedToSend: Int64 { status.withLock { $0.countOfBytesExpectedToSend } }
    open var countOfBytesReceived: Int64 { status.withLock { $0.countOfBytesReceived } }
    open var countOfBytesExpectedToReceive: Int64 { status.withLock { $0.countOfBytesExpectedToReceive } }

    /// Kept, not acted on (the system's scheduling of background work).
    open var countOfBytesClientExpectsToSend: Int64 {
        get { status.withLock { $0.countOfBytesClientExpectsToSend } }
        set { status.withLock { $0.countOfBytesClientExpectsToSend = newValue } }
    }

    /// Kept, not acted on (the system's scheduling of background work).
    open var countOfBytesClientExpectsToReceive: Int64 {
        get { status.withLock { $0.countOfBytesClientExpectsToReceive } }
        set { status.withLock { $0.countOfBytesClientExpectsToReceive = newValue } }
    }

    /// Starts the task, or lets a suspended one go on.
    open func resume() {
        let start = status.withLock { status -> Bool in
            guard status.state == .suspended else { return false }
            status.state = .running
            guard !status.started else { return false }
            status.started = true
            return true
        }
        guard start else { return }
        let work = Task { await self._run() }
        status.withLock { status in
            if !status.finished { status.work = work }
        }
    }

    /// Keeps a task that has not started from starting until resumed. A
    /// task already loading goes on loading.
    open func suspend() {
        status.withLock { status in
            if status.state == .running { status.state = .suspended }
        }
    }

    /// Ends the task with URLError.cancelled, at once, whatever it was
    /// doing.
    open func cancel() {
        let cancelling = status.withLock { status -> (Bool, Task<Void, Never>?) in
            guard !status.finished, status.state == .running || status.state == .suspended else { return (false, nil) }
            status.state = .canceling
            return (true, status.work)
        }
        guard cancelling.0 else { return }
        cancelling.1?.cancel()
        let url = request?.url
        Task { self._finish(.failed(URLError(.cancelled, url: url), nil)) }
    }

    // MARK: Hashable (as an NSObject is: by identity)

    public static func == (lhs: URLSessionTask, rhs: URLSessionTask) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    // MARK: Running

    /// The task's work once resumed: a data, upload or download task loads
    /// its request (a WebSocket task overrides this).
    func _run() async {
        guard let request else {
            _finish(.failed(URLError(.unsupportedURL, url: nil), nil))
            return
        }
        do {
            let (data, response) = try await session._load(request, upload: _upload, task: self)
            _finish(.loaded(data, response))
        } catch {
            _finish(.failed(error, nil))
        }
    }

    /// An upload task's body; nil for the others.
    var _upload: _UploadBody? { nil }

    /// Records how the task ended and hands it to the completion handler,
    /// the first time it is called; later calls (a load that ended after
    /// the task was cancelled) are dropped.
    func _finish(_ outcome: _Outcome) {
        let first = status.withLock { status -> Bool in
            guard !status.finished else { return false }
            status.finished = true
            status.state = .completed
            status.work = nil
            switch outcome {
            case .loaded(_, let response):
                status.response = response
            case .failed(let error, let response):
                status.error = error
                if let response { status.response = response }
            case .ended:
                break
            }
            return true
        }
        guard first else { return }
        session._taskCompleted(self)
        _deliver(outcome)
    }

    /// Hands how the task ended to its completion handler, if it has one.
    func _deliver(_ outcome: _Outcome) {}

    func _sending(_ count: Int) {
        status.withLock { status in
            status.countOfBytesExpectedToSend = Int64(count)
            status.countOfBytesSent = Int64(count)
        }
    }

    func _received(_ count: Int) {
        status.withLock { status in
            status.countOfBytesExpectedToReceive = Int64(count)
            status.countOfBytesReceived = Int64(count)
        }
    }
}

open class URLSessionDataTask: URLSessionTask, @unchecked Sendable {
    private let upload: _UploadBody?
    private let completionHandler: (@Sendable (Data?, URLResponse?, (any Error)?) -> Void)?

    init(
        session: URLSession, identifier: Int, request: URLRequest, upload: _UploadBody?,
        completionHandler: (@Sendable (Data?, URLResponse?, (any Error)?) -> Void)?
    ) {
        self.upload = upload
        self.completionHandler = completionHandler
        super.init(session: session, identifier: identifier, request: request)
    }

    override var _upload: _UploadBody? { upload }

    override func _deliver(_ outcome: _Outcome) {
        guard let completionHandler else { return }
        switch outcome {
        case .loaded(let data, let response): completionHandler(data, response, nil)
        case .failed(let error, let response): completionHandler(nil, response, error)
        case .ended: break
        }
    }
}

open class URLSessionUploadTask: URLSessionDataTask, @unchecked Sendable {}

open class URLSessionDownloadTask: URLSessionTask, @unchecked Sendable {
    /// Whether the file is the receiver's (the async `download` forms) or
    /// removed once the completion handler returns (Apple's handler form).
    private let keepsFile: Bool
    private let completionHandler: (@Sendable (URL?, URLResponse?, (any Error)?) -> Void)?

    init(
        session: URLSession, identifier: Int, request: URLRequest, keepsFile: Bool,
        completionHandler: (@Sendable (URL?, URLResponse?, (any Error)?) -> Void)?
    ) {
        self.keepsFile = keepsFile
        self.completionHandler = completionHandler
        super.init(session: session, identifier: identifier, request: request)
    }

    /// The body written to a new file in the temporary directory, named as
    /// Apple's are ("CFNetworkDownload_….tmp").
    override func _deliver(_ outcome: _Outcome) {
        switch outcome {
        case .ended:
            break
        case .failed(let error, let response):
            completionHandler?(nil, response, error)
        case .loaded(let data, let response):
            let name = "CFNetworkDownload_" + UUID().uuidString.prefix(8) + ".tmp"
            let location = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try data.write(to: location)
            } catch {
                let failure = URLError(.cannotCreateFile, url: originalRequest?.url, underlying: error)
                completionHandler?(nil, response, failure)
                return
            }
            completionHandler?(location, response, nil)
            if !keepsFile { try? FileManager.default.removeItem(at: location) }
        }
    }
}
