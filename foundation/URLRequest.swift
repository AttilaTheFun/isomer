// URLRequest, as Apple's Foundation has it: what to load and how. A value
// type here as there; Apple's keeps an NSURLRequest inside, this one its
// fields. Header field names match without regard to case, and the fields
// keep the order they were set in, which is the order the transport sends
// them (docs/parity/Foundation.md: what of a request a transport honours).

import FoundationEssentials

public struct URLRequest: Hashable, Sendable {
    // Apple's are NSURLRequest's (`URLRequest.CachePolicy` is a typealias
    // of `NSURLRequest.CachePolicy`); Isomer has no NSURLRequest.

    /// Where a response may come from: the network, or a cache. Isomer's
    /// Foundation keeps no cache, so every policy loads from the network
    /// (and the two that never load fail as an empty cache would).
    public enum CachePolicy: UInt, Sendable {
        case useProtocolCachePolicy = 0
        case reloadIgnoringLocalCacheData = 1
        case reloadIgnoringLocalAndRemoteCacheData = 4
        case returnCacheDataElseLoad = 2
        case returnCacheDataDontLoad = 3
        case reloadRevalidatingCacheData = 5

        public static var reloadIgnoringCacheData: URLRequest.CachePolicy { .reloadIgnoringLocalCacheData }
    }

    /// The kind of traffic a request is, for the system's network
    /// scheduling; kept, not acted on.
    public enum NetworkServiceType: UInt, Sendable {
        case `default` = 0
        case video = 2
        case background = 3
        case voice = 4
        case responsiveData = 6
        case avStreaming = 8
        case responsiveAV = 9
        case callSignaling = 11
    }

    /// Who asked for a request: the developer or the person using the app.
    public enum Attribution: UInt, Sendable {
        case developer = 0
        case user = 1
    }

    public var url: URL?
    public var cachePolicy: CachePolicy
    public var timeoutInterval: TimeInterval
    public var mainDocumentURL: URL?
    public var networkServiceType: NetworkServiceType = .default
    public var allowsCellularAccess = true
    public var allowsExpensiveNetworkAccess = true
    public var allowsConstrainedNetworkAccess = true
    public var allowsUltraConstrainedNetworkAccess = true
    public var assumesHTTP3Capable = false
    public var requiresDNSSECValidation = false
    public var allowsPersistentDNS = false
    public var attribution: Attribution = .developer
    public var cookiePartitionIdentifier: String?
    public var httpShouldHandleCookies = true

    private var method: String?
    private var fields: [(name: String, value: String)] = []
    private var body: Body?

    /// A request has a body of bytes or a stream, not both.
    private enum Body {
        case data(Data)
        case stream(InputStream)
    }

    public init(
        url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy, timeoutInterval: TimeInterval = 60.0
    ) {
        self.url = url
        self.cachePolicy = cachePolicy
        self.timeoutInterval = timeoutInterval
    }

    /// The method; "GET" until another is set (setting nil sets "GET"
    /// again).
    public var httpMethod: String? {
        get { method ?? "GET" }
        set { method = newValue }
    }

    /// The header fields by name; nil when there are none. Setting replaces
    /// them all.
    public var allHTTPHeaderFields: [String: String]? {
        get {
            if fields.isEmpty { return nil }
            var all: [String: String] = [:]
            for field in fields { all[field.name] = field.value }
            return all
        }
        set {
            fields = (newValue ?? [:]).sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
        }
    }

    /// The value of the field named `field` (in any case); nil when there
    /// is none.
    public func value(forHTTPHeaderField field: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(field) == .orderedSame }?.value
    }

    /// Sets the field named `field` (in any case) to `value`, or removes it
    /// when `value` is nil.
    public mutating func setValue(_ value: String?, forHTTPHeaderField field: String) {
        if let index = fields.firstIndex(where: { $0.name.caseInsensitiveCompare(field) == .orderedSame }) {
            if let value {
                fields[index].value = value
            } else {
                fields.remove(at: index)
            }
        } else if let value {
            fields.append((name: field, value: value))
        }
    }

    /// Adds `value` to the field named `field`, after a comma when it has
    /// one already.
    public mutating func addValue(_ value: String, forHTTPHeaderField field: String) {
        if let index = fields.firstIndex(where: { $0.name.caseInsensitiveCompare(field) == .orderedSame }) {
            fields[index].value += "," + value
        } else {
            fields.append((name: field, value: value))
        }
    }

    /// The body sent with the request. Setting it clears `httpBodyStream`.
    public var httpBody: Data? {
        get {
            if case .data(let data) = body { return data }
            return nil
        }
        set { body = newValue.map { .data($0) } }
    }

    /// A stream the body is read from, read whole when the request is
    /// sent. Setting it clears `httpBody`.
    public var httpBodyStream: InputStream? {
        get {
            if case .stream(let stream) = body { return stream }
            return nil
        }
        set { body = newValue.map { .stream($0) } }
    }

    /// The header fields in the order they were set: what is sent.
    var _headerFields: [(name: String, value: String)] { fields }

    public static func == (lhs: URLRequest, rhs: URLRequest) -> Bool {
        let sameBody: Bool
        switch (lhs.body, rhs.body) {
        case (nil, nil): sameBody = true
        case (.data(let a)?, .data(let b)?): sameBody = a == b
        case (.stream(let a)?, .stream(let b)?): sameBody = a === b
        default: sameBody = false
        }
        return sameBody && lhs.url == rhs.url && lhs.cachePolicy == rhs.cachePolicy
            && lhs.timeoutInterval == rhs.timeoutInterval && lhs.mainDocumentURL == rhs.mainDocumentURL
            && lhs.httpMethod == rhs.httpMethod && lhs.allHTTPHeaderFields == rhs.allHTTPHeaderFields
            && lhs.networkServiceType == rhs.networkServiceType && lhs.allowsCellularAccess == rhs.allowsCellularAccess
            && lhs.allowsExpensiveNetworkAccess == rhs.allowsExpensiveNetworkAccess
            && lhs.allowsConstrainedNetworkAccess == rhs.allowsConstrainedNetworkAccess
            && lhs.allowsUltraConstrainedNetworkAccess == rhs.allowsUltraConstrainedNetworkAccess
            && lhs.assumesHTTP3Capable == rhs.assumesHTTP3Capable
            && lhs.requiresDNSSECValidation == rhs.requiresDNSSECValidation
            && lhs.allowsPersistentDNS == rhs.allowsPersistentDNS && lhs.attribution == rhs.attribution
            && lhs.cookiePartitionIdentifier == rhs.cookiePartitionIdentifier
            && lhs.httpShouldHandleCookies == rhs.httpShouldHandleCookies
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(httpMethod)
        hasher.combine(httpBody)
    }
}

extension URLRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        url?.description ?? "url: nil"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        var children: [(label: String?, value: Any)] = []
        children.append((label: "url", value: url as Any))
        children.append((label: "cachePolicy", value: cachePolicy.rawValue))
        children.append((label: "timeoutInterval", value: timeoutInterval))
        if let mainDocumentURL { children.append((label: "mainDocumentURL", value: mainDocumentURL)) }
        children.append((label: "networkServiceType", value: networkServiceType))
        children.append((label: "allowsCellularAccess", value: allowsCellularAccess))
        children.append((label: "httpMethod", value: httpMethod as Any))
        if let allHTTPHeaderFields { children.append((label: "allHTTPHeaderFields", value: allHTTPHeaderFields)) }
        if let httpBody { children.append((label: "httpBody", value: httpBody)) }
        if let httpBodyStream { children.append((label: "httpBodyStream", value: httpBodyStream)) }
        children.append((label: "httpShouldHandleCookies", value: httpShouldHandleCookies))
        return Mirror(self, children: children, displayStyle: .struct)
    }
}
