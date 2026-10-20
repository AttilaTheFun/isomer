// URLError, as Apple's Foundation has it: a code from NSURLErrorDomain and
// the user info that goes with it (the failing URL above all). Off Apple
// platforms it is a plain Swift error, like swift-foundation's CocoaError
// and POSIXError: no NSError behind it. And `localizedDescription` on every
// error, which apps show; in English (there are no strings tables).

import FoundationEssentials

public struct URLError: Error, Hashable, Sendable {
    /// The error's code, one of the static members below.
    public struct Code: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// An error matches a code when it is a URLError with that code:
        /// `catch URLError.Code.timedOut`.
        public static func ~= (match: Self, error: any Error) -> Bool {
            (error as? URLError)?.code == match
        }
    }

    /// Why the network was unavailable to a request that allowed less of
    /// it (`allowsCellularAccess`, `allowsExpensiveNetworkAccess`…).
    public enum NetworkUnavailableReason: Int, Sendable {
        case cellular = 0
        case expensive = 1
        case constrained = 2
        case ultraConstrained = 3
    }

    /// Why the system cancelled a background session's task.
    public enum BackgroundTaskCancelledReason: Int, Sendable {
        case userForceQuitApplication = 0
        case backgroundUpdatesDisabled = 1
        case insufficientSystemResources = 2
    }

    public let code: Code

    // Apple's is an NSDictionary, which holds anything.
    public nonisolated(unsafe) let userInfo: [String: Any]

    public init(_ code: Self.Code, userInfo: [String: Any] = [:]) {
        self.code = code
        self.userInfo = userInfo
    }

    public static var errorDomain: String { "NSURLErrorDomain" }

    public var errorCode: Int { code.rawValue }

    public var errorUserInfo: [String: Any] { userInfo }

    /// The URL that failed (`NSURLErrorFailingURLErrorKey`).
    public var failingURL: URL? {
        userInfo[_URLErrorKey.failingURL] as? URL
            ?? (userInfo[_URLErrorKey.failingURLString] as? String).flatMap { URL(string: $0) }
    }

    public var networkUnavailableReason: NetworkUnavailableReason? {
        (userInfo[_URLErrorKey.networkUnavailableReason] as? Int).flatMap(NetworkUnavailableReason.init(rawValue:))
    }

    public var backgroundTaskCancelledReason: BackgroundTaskCancelledReason? {
        (userInfo[_URLErrorKey.backgroundTaskCancelledReason] as? Int)
            .flatMap(BackgroundTaskCancelledReason.init(rawValue:))
    }

    /// What a cancelled download leaves to resume it from; Isomer's
    /// downloads do not resume, so there is none.
    public var downloadTaskResumeData: Data? {
        userInfo[_URLErrorKey.downloadTaskResumeData] as? Data
    }

    /// What a cancelled upload leaves to resume it from; Isomer's uploads do
    /// not resume, so there is none.
    public var uploadTaskResumeData: Data? {
        userInfo[_URLErrorKey.uploadTaskResumeData] as? Data
    }

    // Equal as NSErrors are: the same code about the same URL.
    public static func == (lhs: URLError, rhs: URLError) -> Bool {
        lhs.code == rhs.code && lhs.failingURL == rhs.failingURL
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(code)
    }
}

/// The keys of a URLError's user info, as Apple's Foundation names them.
enum _URLErrorKey {
    static let failingURL = "NSErrorFailingURLKey"
    static let failingURLString = "NSErrorFailingURLStringKey"
    static let localizedDescription = "NSLocalizedDescription"
    static let debugDescription = "NSDebugDescription"
    static let underlyingError = "NSUnderlyingError"
    static let networkUnavailableReason = "NSURLErrorNetworkUnavailableReasonKey"
    static let backgroundTaskCancelledReason = "NSURLErrorBackgroundTaskCancelledReasonKey"
    static let downloadTaskResumeData = "NSURLSessionDownloadTaskResumeData"
    static let uploadTaskResumeData = "NSURLSessionUploadTaskResumeData"
}

extension URLError {
    /// An error about `url`, with the user info Apple's has for it.
    init(_ code: Code, url: URL?, debugDescription: String = "", underlying: (any Error)? = nil) {
        var userInfo: [String: Any] = [:]
        if let url {
            userInfo[_URLErrorKey.failingURL] = url
            userInfo[_URLErrorKey.failingURLString] = url.absoluteString
        }
        if !debugDescription.isEmpty { userInfo[_URLErrorKey.debugDescription] = debugDescription }
        if let underlying { userInfo[_URLErrorKey.underlyingError] = underlying }
        self.init(code, userInfo: userInfo)
    }

    /// The description Apple's Foundation gives the code, in English; nil
    /// for the codes it describes only by number.
    var _description: String? {
        switch code {
        case .unknown: "unknown error"
        case .cancelled: "cancelled"
        case .badURL: "bad URL"
        case .timedOut: "The request timed out."
        case .unsupportedURL: "unsupported URL"
        case .cannotFindHost: "A server with the specified hostname could not be found."
        case .cannotConnectToHost: "Could not connect to the server."
        case .networkConnectionLost: "The network connection was lost."
        case .dnsLookupFailed: "DNS lookup error"
        case .httpTooManyRedirects: "too many HTTP redirects"
        case .resourceUnavailable: "resource unavailable"
        case .notConnectedToInternet: "The Internet connection appears to be offline."
        case .redirectToNonExistentLocation: "redirected to nowhere"
        case .badServerResponse: "bad server response"
        case .userAuthenticationRequired: "user authentication required"
        case .zeroByteResource: "zero byte resource"
        case .cannotDecodeRawData: "cannot decode raw data"
        case .cannotDecodeContentData: "cannot decode content data"
        case .cannotParseResponse: "cannot parse response"
        case .appTransportSecurityRequiresSecureConnection:
            "The resource could not be loaded because the App Transport Security policy requires the use of a secure connection."
        case .fileDoesNotExist: "The requested URL was not found on this server."
        case .fileIsDirectory: "file is directory"
        case .noPermissionsToReadFile: "You do not have permission to access the requested resource."
        case .dataLengthExceedsMaximum: "resource exceeds maximum size"
        case .secureConnectionFailed: "An SSL error has occurred and a secure connection to the server cannot be made."
        case .serverCertificateHasBadDate: "The certificate for this server has expired."
        case .serverCertificateUntrusted: "The certificate for this server is invalid."
        case .serverCertificateHasUnknownRoot:
            "The certificate for this server was signed by an unknown certifying authority."
        case .serverCertificateNotYetValid: "The certificate for this server is not yet valid."
        case .clientCertificateRejected: "The server did not accept the certificate."
        case .clientCertificateRequired: "The server requires a client certificate."
        case .cannotLoadFromNetwork: "can’t load from network"
        case .internationalRoamingOff: "International roaming is currently off."
        case .callIsActive: "A data connection cannot be established since a call is currently active."
        case .dataNotAllowed: "A data connection is not currently allowed."
        default: nil
        }
    }
}

// The codes, on Code and on URLError both, as Apple's Foundation has them.
extension URLError.Code {
    public static var unknown: URLError.Code { URLError.Code(rawValue: -1) }
    public static var cancelled: URLError.Code { URLError.Code(rawValue: -999) }
    public static var badURL: URLError.Code { URLError.Code(rawValue: -1000) }
    public static var timedOut: URLError.Code { URLError.Code(rawValue: -1001) }
    public static var unsupportedURL: URLError.Code { URLError.Code(rawValue: -1002) }
    public static var cannotFindHost: URLError.Code { URLError.Code(rawValue: -1003) }
    public static var cannotConnectToHost: URLError.Code { URLError.Code(rawValue: -1004) }
    public static var networkConnectionLost: URLError.Code { URLError.Code(rawValue: -1005) }
    public static var dnsLookupFailed: URLError.Code { URLError.Code(rawValue: -1006) }
    public static var httpTooManyRedirects: URLError.Code { URLError.Code(rawValue: -1007) }
    public static var resourceUnavailable: URLError.Code { URLError.Code(rawValue: -1008) }
    public static var notConnectedToInternet: URLError.Code { URLError.Code(rawValue: -1009) }
    public static var redirectToNonExistentLocation: URLError.Code { URLError.Code(rawValue: -1010) }
    public static var badServerResponse: URLError.Code { URLError.Code(rawValue: -1011) }
    public static var userCancelledAuthentication: URLError.Code { URLError.Code(rawValue: -1012) }
    public static var userAuthenticationRequired: URLError.Code { URLError.Code(rawValue: -1013) }
    public static var zeroByteResource: URLError.Code { URLError.Code(rawValue: -1014) }
    public static var cannotDecodeRawData: URLError.Code { URLError.Code(rawValue: -1015) }
    public static var cannotDecodeContentData: URLError.Code { URLError.Code(rawValue: -1016) }
    public static var cannotParseResponse: URLError.Code { URLError.Code(rawValue: -1017) }
    public static var internationalRoamingOff: URLError.Code { URLError.Code(rawValue: -1018) }
    public static var callIsActive: URLError.Code { URLError.Code(rawValue: -1019) }
    public static var dataNotAllowed: URLError.Code { URLError.Code(rawValue: -1020) }
    public static var requestBodyStreamExhausted: URLError.Code { URLError.Code(rawValue: -1021) }
    public static var appTransportSecurityRequiresSecureConnection: URLError.Code { URLError.Code(rawValue: -1022) }
    public static var fileDoesNotExist: URLError.Code { URLError.Code(rawValue: -1100) }
    public static var fileIsDirectory: URLError.Code { URLError.Code(rawValue: -1101) }
    public static var noPermissionsToReadFile: URLError.Code { URLError.Code(rawValue: -1102) }
    public static var dataLengthExceedsMaximum: URLError.Code { URLError.Code(rawValue: -1103) }
    public static var secureConnectionFailed: URLError.Code { URLError.Code(rawValue: -1200) }
    public static var serverCertificateHasBadDate: URLError.Code { URLError.Code(rawValue: -1201) }
    public static var serverCertificateUntrusted: URLError.Code { URLError.Code(rawValue: -1202) }
    public static var serverCertificateHasUnknownRoot: URLError.Code { URLError.Code(rawValue: -1203) }
    public static var serverCertificateNotYetValid: URLError.Code { URLError.Code(rawValue: -1204) }
    public static var clientCertificateRejected: URLError.Code { URLError.Code(rawValue: -1205) }
    public static var clientCertificateRequired: URLError.Code { URLError.Code(rawValue: -1206) }
    public static var cannotLoadFromNetwork: URLError.Code { URLError.Code(rawValue: -2000) }
    public static var cannotCreateFile: URLError.Code { URLError.Code(rawValue: -3000) }
    public static var cannotOpenFile: URLError.Code { URLError.Code(rawValue: -3001) }
    public static var cannotCloseFile: URLError.Code { URLError.Code(rawValue: -3002) }
    public static var cannotWriteToFile: URLError.Code { URLError.Code(rawValue: -3003) }
    public static var cannotRemoveFile: URLError.Code { URLError.Code(rawValue: -3004) }
    public static var cannotMoveFile: URLError.Code { URLError.Code(rawValue: -3005) }
    public static var downloadDecodingFailedMidStream: URLError.Code { URLError.Code(rawValue: -3006) }
    public static var downloadDecodingFailedToComplete: URLError.Code { URLError.Code(rawValue: -3007) }
    public static var backgroundSessionRequiresSharedContainer: URLError.Code { URLError.Code(rawValue: -995) }
    public static var backgroundSessionInUseByAnotherProcess: URLError.Code { URLError.Code(rawValue: -996) }
    public static var backgroundSessionWasDisconnected: URLError.Code { URLError.Code(rawValue: -997) }
}

extension URLError {
    public static var unknown: URLError.Code { .unknown }
    public static var cancelled: URLError.Code { .cancelled }
    public static var badURL: URLError.Code { .badURL }
    public static var timedOut: URLError.Code { .timedOut }
    public static var unsupportedURL: URLError.Code { .unsupportedURL }
    public static var cannotFindHost: URLError.Code { .cannotFindHost }
    public static var cannotConnectToHost: URLError.Code { .cannotConnectToHost }
    public static var networkConnectionLost: URLError.Code { .networkConnectionLost }
    public static var dnsLookupFailed: URLError.Code { .dnsLookupFailed }
    public static var httpTooManyRedirects: URLError.Code { .httpTooManyRedirects }
    public static var resourceUnavailable: URLError.Code { .resourceUnavailable }
    public static var notConnectedToInternet: URLError.Code { .notConnectedToInternet }
    public static var redirectToNonExistentLocation: URLError.Code { .redirectToNonExistentLocation }
    public static var badServerResponse: URLError.Code { .badServerResponse }
    public static var userCancelledAuthentication: URLError.Code { .userCancelledAuthentication }
    public static var userAuthenticationRequired: URLError.Code { .userAuthenticationRequired }
    public static var zeroByteResource: URLError.Code { .zeroByteResource }
    public static var cannotDecodeRawData: URLError.Code { .cannotDecodeRawData }
    public static var cannotDecodeContentData: URLError.Code { .cannotDecodeContentData }
    public static var cannotParseResponse: URLError.Code { .cannotParseResponse }
    public static var internationalRoamingOff: URLError.Code { .internationalRoamingOff }
    public static var callIsActive: URLError.Code { .callIsActive }
    public static var dataNotAllowed: URLError.Code { .dataNotAllowed }
    public static var requestBodyStreamExhausted: URLError.Code { .requestBodyStreamExhausted }
    public static var appTransportSecurityRequiresSecureConnection: URLError.Code {
        .appTransportSecurityRequiresSecureConnection
    }
    public static var fileDoesNotExist: URLError.Code { .fileDoesNotExist }
    public static var fileIsDirectory: URLError.Code { .fileIsDirectory }
    public static var noPermissionsToReadFile: URLError.Code { .noPermissionsToReadFile }
    public static var dataLengthExceedsMaximum: URLError.Code { .dataLengthExceedsMaximum }
    public static var secureConnectionFailed: URLError.Code { .secureConnectionFailed }
    public static var serverCertificateHasBadDate: URLError.Code { .serverCertificateHasBadDate }
    public static var serverCertificateUntrusted: URLError.Code { .serverCertificateUntrusted }
    public static var serverCertificateHasUnknownRoot: URLError.Code { .serverCertificateHasUnknownRoot }
    public static var serverCertificateNotYetValid: URLError.Code { .serverCertificateNotYetValid }
    public static var clientCertificateRejected: URLError.Code { .clientCertificateRejected }
    public static var clientCertificateRequired: URLError.Code { .clientCertificateRequired }
    public static var cannotLoadFromNetwork: URLError.Code { .cannotLoadFromNetwork }
    public static var cannotCreateFile: URLError.Code { .cannotCreateFile }
    public static var cannotOpenFile: URLError.Code { .cannotOpenFile }
    public static var cannotCloseFile: URLError.Code { .cannotCloseFile }
    public static var cannotWriteToFile: URLError.Code { .cannotWriteToFile }
    public static var cannotRemoveFile: URLError.Code { .cannotRemoveFile }
    public static var cannotMoveFile: URLError.Code { .cannotMoveFile }
    public static var downloadDecodingFailedMidStream: URLError.Code { .downloadDecodingFailedMidStream }
    public static var downloadDecodingFailedToComplete: URLError.Code { .downloadDecodingFailedToComplete }
    public static var backgroundSessionRequiresSharedContainer: URLError.Code {
        .backgroundSessionRequiresSharedContainer
    }
    public static var backgroundSessionInUseByAnotherProcess: URLError.Code { .backgroundSessionInUseByAnotherProcess }
    public static var backgroundSessionWasDisconnected: URLError.Code { .backgroundSessionWasDisconnected }
}

// MARK: - localizedDescription

extension Error {
    /// The error described for a person, as Apple's Foundation describes
    /// it: a `LocalizedError`'s `errorDescription`, the description of a
    /// URLError's code, else "The operation couldn’t be completed." with
    /// the error's domain and code.
    public var localizedDescription: String {
        if let error = _existingNSError(self) {
            return error.localizedDescription
        }
        if let error = self as? any LocalizedError, let description = error.errorDescription {
            return description
        }
        if let error = self as? URLError {
            if let description = error.userInfo[_URLErrorKey.localizedDescription] as? String {
                return description
            }
            if let description = error._description {
                return description
            }
            return "The operation couldn’t be completed. (\(URLError.errorDomain) error \(error.code.rawValue).)"
        }
        if let error = self as? CocoaError {
            return "The operation couldn’t be completed. (\(CocoaError.errorDomain) error \(error.code.rawValue).)"
        }
        if let error = self as? POSIXError {
            return "The operation couldn’t be completed. (\(POSIXError.errorDomain) error \(error.code.rawValue).)"
        }
        return "The operation couldn’t be completed. (\(_domain) error \(_code).)"
    }
}
