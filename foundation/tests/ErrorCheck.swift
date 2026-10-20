import Foundation

// NSError (foundation/NSError.swift): `as NSError` for Swift errors, the
// domains, codes, user info and descriptions Apple's Foundation gives them,
// and NSErrors made by hand.

private enum Described: Error, LocalizedError {
    case it
    var errorDescription: String? { "It went wrong." }
}

private enum Coded: Int, CustomNSError {
    case first = 1, second
    static var errorDomain: String { "test.coded" }
    var errorUserInfo: [String: Any] { ["k": "v"] }
}

extension FoundationCheck {
    static func checkErrors() {
        let url = URLError(.cannotConnectToHost) as NSError
        check("nserror url", "\(url.domain) \(url.code)", "NSURLErrorDomain -1004")
        check("nserror url description", url.localizedDescription, URLError(.cannotConnectToHost).localizedDescription)
        let thrown: any Error = URLError(.timedOut)
        check("nserror from existential", "\((thrown as NSError).code)", "-1001")
        check("error description", thrown.localizedDescription, URLError(.timedOut).localizedDescription)
        check("nserror back to URLError", "\(_convertNSErrorToError(thrown as NSError) as? URLError == URLError(.timedOut))", "true")

        let made = NSError(domain: "test.domain", code: 7, userInfo: [NSLocalizedDescriptionKey: "Seven."])
        check("nserror description", made.localizedDescription, "Seven.")
        check("nserror as error description", (made as any Error).localizedDescription, "Seven.")
        check("nserror stays itself", "\(((made as any Error) as NSError) === made)", "true")
        check("nserror plain", NSError(domain: "D", code: 3).localizedDescription, "The operation couldn’t be completed. (D error 3.)")
        check("nserror localized error", (Described.it as NSError).localizedDescription, "It went wrong.")
        let coded = Coded.second as NSError
        check("nserror custom", "\(coded.domain) \(coded.code) \(coded.userInfo["k"] as? String ?? "")", "test.coded 2 v")
        let cocoa = CocoaError(.fileNoSuchFile) as NSError
        check("nserror cocoa", "\(cocoa.domain) \(cocoa.code)", "NSCocoaErrorDomain 4")
        let outer = NSError(domain: "outer", code: 1, userInfo: [NSUnderlyingErrorKey: made])
        check("nserror underlying", "\(outer.underlyingErrors.count) \((outer.underlyingErrors.first as? NSError)?.code ?? 0)", "1 7")
        // What PathProbe reads: an NSError's user info by a key it may lack.
        check("nserror missing key", "\((thrown as NSError).userInfo["_NSURLErrorNWPathKey"] == nil)", "true")
    }
}
