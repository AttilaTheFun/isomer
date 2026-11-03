// Cookie and credential storage, as a session's configuration names them
// (`httpCookieStorage`, `urlCredentialStorage`): the types and their shared
// instances, so code that sets or passes them compiles, holding nothing.
// Isomer's sessions send requests through the host's stack (fetch,
// HttpURLConnection, URLSession), which keeps its own cookies and
// credentials; Isomer's keep none of their own (docs/parity/Foundation.md).

open class HTTPCookieStorage: NSObject, @unchecked Sendable {
    open class var shared: HTTPCookieStorage { sharedStorage }

    private static let sharedStorage = HTTPCookieStorage()
}

open class URLCredentialStorage: NSObject, @unchecked Sendable {
    open class var shared: URLCredentialStorage { sharedStorage }

    private static let sharedStorage = URLCredentialStorage()
}
