// URLSession and URLSessionConfiguration, as Apple's Foundation has them,
// without delegates (docs/parity/Foundation.md). A session makes tasks;
// a task loads its request when resumed and hands what it got to its
// completion handler, or to the `async` call that made it. Where a request
// goes:
//
// - file: URLs are read from the file system, data: URLs decoded, as
//   Apple's URLSession does, with no transport;
// - http and https go through the HTTP transport the host installed
//   (IsomerFoundation's IsomerNetwork.http), ws and wss through its
//   WebSocket transport (URLSessionWebSocketTask.swift). With none
//   installed a task fails with URLError.notConnectedToInternet: to the
//   app the program is offline, which it handles as it would on a device
//   (an unsupported-URL error would read as its own mistake);
// - any other scheme fails with URLError.unsupportedURL.
//
// Completion handlers run on a task of their own (Apple's run on the
// session's delegate queue, an OperationQueue, which Isomer does not have),
// never inside the call that made the task.

import FoundationEssentials
import Synchronization
internal import IsomerFoundation

open class URLSessionConfiguration: @unchecked Sendable {
    /// What a session uses when made with none: a new configuration each
    /// time, the defaults below.
    open class var `default`: URLSessionConfiguration { URLSessionConfiguration() }

    /// A configuration that keeps nothing on disk. Isomer's sessions keep
    /// no caches, cookies or credentials of their own, so it is the default
    /// one.
    open class var ephemeral: URLSessionConfiguration { URLSessionConfiguration() }

    init() {}

    /// A background session's identifier; Isomer has no background
    /// sessions, so there is none.
    open var identifier: String? { nil }

    open var requestCachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy

    /// How long a request may wait on the server, to connect or for more of
    /// its response, when the request does not say (its `timeoutInterval`
    /// left at the default 60).
    open var timeoutIntervalForRequest: TimeInterval = 60

    /// How long a WebSocket's or a request's whole exchange may take; kept,
    /// and the hosts' stacks apply their own.
    open var timeoutIntervalForResource: TimeInterval = 604_800

    /// Header fields every request of the session sends, after its own and
    /// unless it set them itself.
    open var httpAdditionalHeaders: [AnyHashable: Any]?

    // What steers Apple's network stack, kept and not acted on: the
    // platform's stack decides how its connections are made.
    open var networkServiceType: URLRequest.NetworkServiceType = .default
    open var allowsCellularAccess = true
    open var allowsExpensiveNetworkAccess = true
    open var allowsConstrainedNetworkAccess = true
    open var allowsUltraConstrainedNetworkAccess = true
    open var waitsForConnectivity = false
    open var isDiscretionary = false
    open var sharedContainerIdentifier: String?
    open var sessionSendsLaunchEvents = false
    open var httpShouldSetCookies = true
    open var httpMaximumConnectionsPerHost = 6
    open var requiresDNSSECValidation = false
    open var usesClassicLoadingMode = true
    open var enablesEarlyData = false
    open var multipathServiceType: MultipathServiceType = .none

    /// How a connection may use more than one network at a time
    /// (Multipath TCP); kept, not acted on.
    public enum MultipathServiceType: Int, Sendable {
        case none = 0
        case handover = 1
        case interactive = 2
        case aggregate = 3
    }

    /// A copy: what a session keeps (Apple's `@NSCopying`).
    func _copy() -> URLSessionConfiguration {
        let copy = URLSessionConfiguration()
        copy.requestCachePolicy = requestCachePolicy
        copy.timeoutIntervalForRequest = timeoutIntervalForRequest
        copy.timeoutIntervalForResource = timeoutIntervalForResource
        copy.httpAdditionalHeaders = httpAdditionalHeaders
        copy.networkServiceType = networkServiceType
        copy.allowsCellularAccess = allowsCellularAccess
        copy.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        copy.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        copy.allowsUltraConstrainedNetworkAccess = allowsUltraConstrainedNetworkAccess
        copy.waitsForConnectivity = waitsForConnectivity
        copy.isDiscretionary = isDiscretionary
        copy.sharedContainerIdentifier = sharedContainerIdentifier
        copy.sessionSendsLaunchEvents = sessionSendsLaunchEvents
        copy.httpShouldSetCookies = httpShouldSetCookies
        copy.httpMaximumConnectionsPerHost = httpMaximumConnectionsPerHost
        copy.requiresDNSSECValidation = requiresDNSSECValidation
        copy.usesClassicLoadingMode = usesClassicLoadingMode
        copy.enablesEarlyData = enablesEarlyData
        copy.multipathServiceType = multipathServiceType
        return copy
    }

    /// The additional header fields as text, in a stable order.
    var _additionalHeaderFields: [(name: String, value: String)] {
        (httpAdditionalHeaders ?? [:])
            .map { (name: ($0.key as? String) ?? "\($0.key)", value: ($0.value as? String) ?? "\($0.value)") }
            .sorted { $0.name < $1.name }
    }
}

open class URLSession: @unchecked Sendable {
    private struct State {
        var tasks: [Int: URLSessionTask] = [:]
        var nextIdentifier = 1
        var invalidated = false
        var sessionDescription: String?
    }

    let sessionConfiguration: URLSessionConfiguration
    private let isShared: Bool
    private let state = Mutex(State())

    private static let sharedSession = URLSession(configuration: .default, shared: true)

    /// The session for requests that need no configuration of their own.
    /// It cannot be invalidated.
    open class var shared: URLSession { sharedSession }

    public init(configuration: URLSessionConfiguration) {
        sessionConfiguration = configuration._copy()
        isShared = false
    }

    private init(configuration: URLSessionConfiguration, shared: Bool) {
        sessionConfiguration = configuration
        isShared = shared
    }

    /// A copy of the session's configuration: changing it changes nothing.
    open var configuration: URLSessionConfiguration { sessionConfiguration._copy() }

    open var sessionDescription: String? {
        get { state.withLock { $0.sessionDescription } }
        set { state.withLock { $0.sessionDescription = newValue } }
    }

    // MARK: Invalidating

    /// Lets the session's tasks finish and takes no more.
    open func finishTasksAndInvalidate() {
        guard !isShared else { return }
        state.withLock { $0.invalidated = true }
    }

    /// Cancels the session's tasks and takes no more.
    open func invalidateAndCancel() {
        guard !isShared else { return }
        let tasks = state.withLock { state in
            state.invalidated = true
            return Array(state.tasks.values)
        }
        for task in tasks { task.cancel() }
    }

    /// Isomer's sessions keep no caches, cookies or credentials to empty.
    open func reset(completionHandler: @escaping @Sendable () -> Void) {
        Task { completionHandler() }
    }

    public func reset() async {}

    /// Isomer's sessions keep nothing to write out.
    open func flush(completionHandler: @escaping @Sendable () -> Void) {
        Task { completionHandler() }
    }

    public func flush() async {}

    // MARK: The session's tasks

    open func getTasksWithCompletionHandler(
        _ completionHandler:
            @escaping @Sendable ([URLSessionDataTask], [URLSessionUploadTask], [URLSessionDownloadTask]) -> Void
    ) {
        let (data, uploads, downloads) = Self.sorted(liveTasks())
        Task { completionHandler(data, uploads, downloads) }
    }

    open func getAllTasks(completionHandler: @escaping @Sendable ([URLSessionTask]) -> Void) {
        let all = liveTasks()
        Task { completionHandler(all) }
    }

    public var tasks: ([URLSessionDataTask], [URLSessionUploadTask], [URLSessionDownloadTask]) {
        get async { Self.sorted(liveTasks()) }
    }

    public var allTasks: [URLSessionTask] {
        get async { liveTasks() }
    }

    /// The tasks made and not yet completed, oldest first.
    private func liveTasks() -> [URLSessionTask] {
        state.withLock { $0.tasks.sorted { $0.key < $1.key }.map(\.value) }
    }

    private static func sorted(
        _ tasks: [URLSessionTask]
    ) -> ([URLSessionDataTask], [URLSessionUploadTask], [URLSessionDownloadTask]) {
        let uploads = tasks.compactMap { $0 as? URLSessionUploadTask }
        let data = tasks.compactMap { $0 as? URLSessionDataTask }.filter { !($0 is URLSessionUploadTask) }
        let downloads = tasks.compactMap { $0 as? URLSessionDownloadTask }
        return (data, uploads, downloads)
    }

    /// The next task's identifier, the task kept until it completes.
    func _register<Kind: URLSessionTask>(_ make: (Int) -> Kind) -> Kind {
        state.withLock { state in
            if state.invalidated {
                // As Apple's Foundation does (it raises an exception).
                fatalError("Task created in a session that has been invalidated")
            }
            let identifier = state.nextIdentifier
            state.nextIdentifier += 1
            let task = make(identifier)
            state.tasks[identifier] = task
            return task
        }
    }

    func _taskCompleted(_ task: URLSessionTask) {
        state.withLock { _ = $0.tasks.removeValue(forKey: task.taskIdentifier) }
    }

    // MARK: Data tasks

    open func dataTask(with request: URLRequest) -> URLSessionDataTask {
        makeDataTask(request, upload: nil, completionHandler: nil)
    }

    open func dataTask(with url: URL) -> URLSessionDataTask {
        makeDataTask(URLRequest(url: url), upload: nil, completionHandler: nil)
    }

    open func dataTask(
        with request: URLRequest, completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDataTask {
        makeDataTask(request, upload: nil, completionHandler: completionHandler)
    }

    open func dataTask(
        with url: URL, completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDataTask {
        makeDataTask(URLRequest(url: url), upload: nil, completionHandler: completionHandler)
    }

    // MARK: Upload tasks

    open func uploadTask(with request: URLRequest, from bodyData: Data) -> URLSessionUploadTask {
        makeUploadTask(request, upload: .data(bodyData), completionHandler: nil)
    }

    open func uploadTask(
        with request: URLRequest, from bodyData: Data?,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionUploadTask {
        makeUploadTask(request, upload: bodyData.map { .data($0) }, completionHandler: completionHandler)
    }

    open func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
        makeUploadTask(request, upload: .file(fileURL), completionHandler: nil)
    }

    open func uploadTask(
        with request: URLRequest, fromFile fileURL: URL,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionUploadTask {
        makeUploadTask(request, upload: .file(fileURL), completionHandler: completionHandler)
    }

    // MARK: Download tasks

    open func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        makeDownloadTask(request, keepsFile: false, completionHandler: nil)
    }

    open func downloadTask(with url: URL) -> URLSessionDownloadTask {
        makeDownloadTask(URLRequest(url: url), keepsFile: false, completionHandler: nil)
    }

    /// The handler gets the file the body was written to, in the temporary
    /// directory; it is removed when the handler returns, so move it first.
    open func downloadTask(
        with request: URLRequest, completionHandler: @escaping @Sendable (URL?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDownloadTask {
        makeDownloadTask(request, keepsFile: false, completionHandler: completionHandler)
    }

    open func downloadTask(
        with url: URL, completionHandler: @escaping @Sendable (URL?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDownloadTask {
        makeDownloadTask(URLRequest(url: url), keepsFile: false, completionHandler: completionHandler)
    }

    // MARK: WebSocket tasks

    open func webSocketTask(with url: URL) -> URLSessionWebSocketTask {
        makeWebSocketTask(URLRequest(url: url), protocols: [])
    }

    /// Offers `protocols` as the connection's subprotocols.
    open func webSocketTask(with url: URL, protocols: [String]) -> URLSessionWebSocketTask {
        makeWebSocketTask(URLRequest(url: url), protocols: protocols)
    }

    /// Offers the subprotocols the request's `Sec-WebSocket-Protocol` field
    /// lists.
    open func webSocketTask(with request: URLRequest) -> URLSessionWebSocketTask {
        let offered = request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        return makeWebSocketTask(request, protocols: offered)
    }

    // MARK: Making tasks

    private func makeDataTask(
        _ request: URLRequest, upload: _UploadBody?,
        completionHandler: (@Sendable (Data?, URLResponse?, (any Error)?) -> Void)?
    ) -> URLSessionDataTask {
        let request = withSessionDefaults(request)
        return _register { identifier in
            URLSessionDataTask(
                session: self, identifier: identifier, request: request, upload: upload,
                completionHandler: completionHandler)
        }
    }

    private func makeUploadTask(
        _ request: URLRequest, upload: _UploadBody?,
        completionHandler: (@Sendable (Data?, URLResponse?, (any Error)?) -> Void)?
    ) -> URLSessionUploadTask {
        let request = withSessionDefaults(request)
        return _register { identifier in
            URLSessionUploadTask(
                session: self, identifier: identifier, request: request, upload: upload,
                completionHandler: completionHandler)
        }
    }

    func makeDownloadTask(
        _ request: URLRequest, keepsFile: Bool,
        completionHandler: (@Sendable (URL?, URLResponse?, (any Error)?) -> Void)?
    ) -> URLSessionDownloadTask {
        let request = withSessionDefaults(request)
        return _register { identifier in
            URLSessionDownloadTask(
                session: self, identifier: identifier, request: request, keepsFile: keepsFile,
                completionHandler: completionHandler)
        }
    }

    private func makeWebSocketTask(_ request: URLRequest, protocols: [String]) -> URLSessionWebSocketTask {
        let request = withSessionDefaults(request)
        return _register { identifier in
            URLSessionWebSocketTask(session: self, identifier: identifier, request: request, protocols: protocols)
        }
    }

    /// The request as the session sends it: its timeout the configuration's
    /// when it kept the default, and a request made from a URL alone with
    /// the configuration's cache policy.
    private func withSessionDefaults(_ request: URLRequest) -> URLRequest {
        var request = request
        if request.timeoutInterval == 60 {
            request.timeoutInterval = sessionConfiguration.timeoutIntervalForRequest
        }
        if request.cachePolicy == .useProtocolCachePolicy {
            request.cachePolicy = sessionConfiguration.requestCachePolicy
        }
        return request
    }

    // MARK: Loading

    /// Loads `request` (with `upload` as its body when there is one):
    /// what the task's response is, its body read whole. Throws a URLError.
    func _load(_ request: URLRequest, upload: _UploadBody?, task: URLSessionTask) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.unsupportedURL, url: nil) }
        switch url.scheme?.lowercased() {
        case "file":
            return try Self.loadFile(url)
        case "data":
            return try Self.decodeDataURL(url)
        case "http", "https":
            return try await loadHTTP(request, url: url, upload: upload, task: task)
        default:
            throw URLError(.unsupportedURL, url: url)
        }
    }

    private func loadHTTP(
        _ request: URLRequest, url: URL, upload: _UploadBody?, task: URLSessionTask
    ) async throws -> (Data, URLResponse) {
        let body = try Self.body(of: request, upload: upload, url: url)
        var fields = request._headerFields
        for field in sessionConfiguration._additionalHeaderFields
        where request.value(forHTTPHeaderField: field.name) == nil {
            fields.append(field)
        }
        // As Apple's Foundation does: a body sent without a type is a form's.
        if !body.isEmpty && request.value(forHTTPHeaderField: "Content-Type") == nil
            && !fields.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })
        {
            fields.append((name: "Content-Type", value: "application/x-www-form-urlencoded"))
        }
        task._sending(body.count)
        guard let transport = IsomerNetwork.http else {
            throw URLError(
                .notConnectedToInternet, url: url,
                debugDescription: "No HTTP transport is installed (IsomerFoundation's IsomerNetwork.http).")
        }
        let exchange = HTTPTransportRequest(
            method: request.httpMethod ?? "GET", url: url, headerFields: fields, body: body,
            timeoutInterval: request.timeoutInterval)
        let answer: HTTPTransportResponse
        do {
            answer = try await transport.send(exchange)
        } catch {
            throw Self.urlError(error, url: url)
        }
        // Repeated fields are one, their values joined, as Apple's are.
        var headerFields: [String: String] = [:]
        var names: [String: String] = [:]
        for field in answer.headerFields {
            let key = field.name.lowercased()
            if let name = names[key] {
                headerFields[name] = headerFields[name]! + ", " + field.value
            } else {
                names[key] = field.name
                headerFields[field.name] = field.value
            }
        }
        guard
            let response = HTTPURLResponse(
                url: answer.url ?? url, statusCode: answer.statusCode, httpVersion: "HTTP/1.1",
                headerFields: headerFields)
        else {
            throw URLError(.badServerResponse, url: url, debugDescription: "Status \(answer.statusCode)")
        }
        task._received(answer.body.count)
        return (answer.body, response)
    }

    /// The body a request sends: the upload's, else the request's own.
    private static func body(of request: URLRequest, upload: _UploadBody?, url: URL) throws -> Data {
        switch upload {
        case .data(let data):
            return data
        case .file(let file):
            do {
                return try Data(contentsOf: file)
            } catch {
                throw URLError(.cannotOpenFile, url: url, underlying: error)
            }
        case nil:
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
                if count < 0 { throw URLError(.requestBodyStreamExhausted, url: url) }
                if count == 0 { return data }
                data.append(contentsOf: buffer[0..<count])
            }
        }
    }

    /// What the app sees of a transport's failure.
    static func urlError(_ error: any Error, url: URL?) -> URLError {
        if let error = error as? URLError { return error }
        if error is CancellationError { return URLError(.cancelled, url: url) }
        guard let failure = error as? NetworkTransportError else {
            return URLError(.unknown, url: url, debugDescription: "\(error)", underlying: error)
        }
        let code: URLError.Code =
            switch failure.reason {
            case .timedOut: .timedOut
            case .cannotFindHost: .cannotFindHost
            case .cannotConnectToHost: .cannotConnectToHost
            case .networkConnectionLost: .networkConnectionLost
            case .notConnectedToInternet: .notConnectedToInternet
            case .secureConnectionFailed: .secureConnectionFailed
            case .cancelled: .cancelled
            case .badServerResponse: .badServerResponse
            case .unknown: .unknown
            }
        return URLError(code, url: url, debugDescription: failure.message)
    }

    /// A file: URL's contents, its type told by its extension.
    private static func loadFile(_ url: URL) throws -> (Data, URLResponse) {
        guard let type = FileManager.default.itemType(atPath: url.path) else {
            throw URLError(.fileDoesNotExist, url: url)
        }
        if type == .typeDirectory { throw URLError(.fileIsDirectory, url: url) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw URLError(.noPermissionsToReadFile, url: url, underlying: error)
        }
        let response = URLResponse(
            url: url, mimeType: mimeType(forPathExtension: url.pathExtension), expectedContentLength: data.count,
            textEncodingName: nil)
        return (data, response)
    }

    private static func mimeType(forPathExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "txt", "text": "text/plain"
        case "css": "text/css"
        case "csv": "text/csv"
        case "js", "mjs": "text/javascript"
        case "json": "application/json"
        case "xml": "application/xml"
        case "pdf": "application/pdf"
        case "wasm": "application/wasm"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "mp3": "audio/mpeg"
        case "mp4", "m4v": "video/mp4"
        case "m4a": "audio/mp4"
        default: "application/octet-stream"
        }
    }

    /// A data: URL's bytes (RFC 2397): `data:[<type>][;charset=…][;base64],<data>`.
    private static func decodeDataURL(_ url: URL) throws -> (Data, URLResponse) {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ","), text.lowercased().hasPrefix("data:") else {
            throw URLError(.badURL, url: url)
        }
        let header = text[text.index(text.startIndex, offsetBy: 5)..<comma]
        let payload = String(text[text.index(after: comma)...])
        var parameters = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let isBase64 = parameters.last?.lowercased() == "base64"
        if isBase64 { parameters.removeLast() }
        let mimeType = parameters.first.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "text/plain"
        var charset: String? = mimeType == "text/plain" && parameters.first?.isEmpty != false ? "us-ascii" : nil
        for parameter in parameters.dropFirst() where parameter.lowercased().hasPrefix("charset=") {
            charset = String(parameter.dropFirst("charset=".count)).lowercased()
        }
        let data: Data?
        if isBase64 {
            let decoded = payload.removingPercentEncoding ?? payload
            data = Data(base64Encoded: decoded, options: .ignoreUnknownCharacters)
        } else {
            data = (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        }
        guard let data else { throw URLError(.cannotDecodeRawData, url: url) }
        let response = URLResponse(
            url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: charset)
        return (data, response)
    }
}

// MARK: - async

extension URLSession {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await awaitData { makeDataTask(request, upload: nil, completionHandler: $0) }
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        try await awaitData { makeDataTask(URLRequest(url: url), upload: nil, completionHandler: $0) }
    }

    public func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        try await awaitData { makeUploadTask(request, upload: .data(bodyData), completionHandler: $0) }
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await awaitData { makeUploadTask(request, upload: .file(fileURL), completionHandler: $0) }
    }

    /// Downloads the body to a file in the temporary directory, which is
    /// the caller's to move or remove. (Apple's has a `delegate` parameter
    /// too, defaulted to nil; Isomer has no session delegates.)
    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await awaitDownload(request)
    }

    public func download(from url: URL) async throws -> (URL, URLResponse) {
        try await awaitDownload(URLRequest(url: url))
    }

    /// Runs the task `make` returns, handing it the completion handler, and
    /// returns what the handler got; cancelling the calling task cancels it.
    private func awaitData(
        _ make: (@escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) -> URLSessionTask
    ) async throws -> (Data, URLResponse) {
        let result = _Rendezvous<(Data, URLResponse)>()
        let task = make { data, response, error in
            if let response, error == nil {
                result.resolve(.success((data ?? Data(), response)))
            } else {
                result.resolve(.failure(error ?? URLError(.unknown)))
            }
        }
        return try await withTaskCancellationHandler {
            task.resume()
            return try await result.value()
        } onCancel: {
            task.cancel()
        }
    }

    private func awaitDownload(_ request: URLRequest) async throws -> (URL, URLResponse) {
        let result = _Rendezvous<(URL, URLResponse)>()
        let task = makeDownloadTask(request, keepsFile: true) { location, response, error in
            if let location, let response, error == nil {
                result.resolve(.success((location, response)))
            } else {
                result.resolve(.failure(error ?? URLError(.unknown)))
            }
        }
        return try await withTaskCancellationHandler {
            task.resume()
            return try await result.value()
        } onCancel: {
            task.cancel()
        }
    }
}

/// An upload task's body.
enum _UploadBody: Sendable {
    case data(Data)
    case file(URL)
}

/// A result handed from a completion handler to the one call waiting for
/// it, whichever of the two comes first.
final class _Rendezvous<Value: Sendable>: Sendable {
    private let state = Mutex<(result: Result<Value, any Error>?, waiter: CheckedContinuation<Value, any Error>?)>(
        (nil, nil))

    func resolve(_ result: Result<Value, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard let waiter = state.waiter else {
                state.result = result
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<Value, any Error>? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
