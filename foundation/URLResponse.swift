// URLResponse and HTTPURLResponse, as Apple's Foundation has them: what a
// load's response said about itself. Swift classes, not NSObject
// subclasses; immutable, as Apple's are.

import FoundationEssentials

open class URLResponse: @unchecked Sendable {
    private let responseURL: URL?
    private let responseMIMEType: String?
    private let contentLength: Int64
    private let encodingName: String?

    public init(
        url URL: URL, mimeType MIMEType: String?, expectedContentLength length: Int, textEncodingName name: String?
    ) {
        responseURL = URL
        responseMIMEType = MIMEType
        contentLength = Int64(length)
        encodingName = name
    }

    open var url: URL? { responseURL }

    /// The type of the body ("text/html"), lowercased; nil when unknown.
    open var mimeType: String? { responseMIMEType }

    /// The length of the body; -1 when unknown.
    open var expectedContentLength: Int64 { contentLength }

    /// The body's character set ("utf-8"); nil when not given.
    open var textEncodingName: String? { encodingName }

    /// A name to save the body under: the URL's last path component, else
    /// "Unknown".
    open var suggestedFilename: String? {
        let last = responseURL?.lastPathComponent ?? ""
        return last.isEmpty || last == "/" ? "Unknown" : last
    }
}

open class HTTPURLResponse: URLResponse, @unchecked Sendable {
    private let status: Int
    private let fields: [String: String]

    /// A response to a request for `url`; nil when `statusCode` is not one
    /// (outside 100 to 999). The MIME type, text encoding and expected
    /// length are read from the header fields.
    public init?(url: URL, statusCode: Int, httpVersion HTTPVersion: String?, headerFields: [String: String]?) {
        guard (100...999).contains(statusCode) else { return nil }
        let fields = headerFields ?? [:]
        status = statusCode
        self.fields = fields
        func field(_ name: String) -> String? {
            fields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        var mimeType: String?
        var encoding: String?
        if let contentType = field("Content-Type") {
            let parts = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            if let type = parts.first, !type.isEmpty { mimeType = type.lowercased() }
            for parameter in parts.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2, pair[0].lowercased() == "charset" {
                    encoding = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
                }
            }
        }
        let length = field("Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? -1
        super.init(url: url, mimeType: mimeType, expectedContentLength: length, textEncodingName: encoding)
    }

    /// The status code: 200, 404…
    open var statusCode: Int { status }

    /// The header fields by name, as the server sent them.
    open var allHeaderFields: [AnyHashable: Any] {
        var all: [AnyHashable: Any] = [:]
        for (name, value) in fields { all[name] = value }
        return all
    }

    /// The value of the field named `field` (in any case); nil when there
    /// is none.
    open func value(forHTTPHeaderField field: String) -> String? {
        fields.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
    }

    /// The name given in a `Content-Disposition` field, else the URL's last
    /// path component.
    open override var suggestedFilename: String? {
        if let disposition = value(forHTTPHeaderField: "Content-Disposition") {
            for parameter in disposition.split(separator: ";") {
                let pair = parameter.split(separator: "=", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0].lowercased() == "filename" {
                    let name = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !name.isEmpty { return name }
                }
            }
        }
        return super.suggestedFilename
    }

    /// The status code described, as Apple's Foundation describes it (in
    /// English, lowercased): "no error" for 200, "not found" for 404.
    open class func localizedString(forStatusCode statusCode: Int) -> String {
        switch statusCode {
        case 100: "continue"
        case 101: "switching protocols"
        case 200: "no error"
        case 201: "created"
        case 202: "accepted"
        case 203: "non-authoritative information"
        case 204: "no content"
        case 205: "reset content"
        case 206: "partial content"
        case 300: "multiple choices"
        case 301: "moved permanently"
        case 302: "found"
        case 303: "see other"
        case 304: "not modified"
        case 305: "needs proxy"
        case 307: "temporarily redirected"
        case 308: "permanent redirect"
        case 400: "bad request"
        case 401: "unauthorized"
        case 402: "payment required"
        case 403: "forbidden"
        case 404: "not found"
        case 405: "method not allowed"
        case 406: "unacceptable"
        case 407: "proxy authentication required"
        case 408: "request timed out"
        case 409: "conflict"
        case 410: "no longer exists"
        case 411: "length required"
        case 412: "precondition failed"
        case 413: "request too large"
        case 414: "requested URL too long"
        case 415: "unsupported media type"
        case 416: "requested range not satisfiable"
        case 417: "expectation failed"
        case 500: "internal server error"
        case 501: "unimplemented"
        case 502: "bad gateway"
        case 503: "service unavailable"
        case 504: "gateway timed out"
        case 505: "unsupported version"
        case 100..<200: "informational"
        case 200..<300: "success"
        case 300..<400: "redirected"
        case 400..<500: "client error"
        default: "server error"
        }
    }
}
