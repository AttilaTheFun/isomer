// NSError, as Apple's Foundation has it: an error's domain, code and user
// info, and `error as NSError` for any Swift error (the compiler calls
// `_convertErrorToNSError` for it, as it does with corelibs Foundation).
// Off Apple platforms the errors themselves stay Swift values (URLError,
// CocoaError, POSIXError, an app's own); an NSError is made from one when
// asked for, keeps it, and `as?` back from the NSError finds it again.

import FoundationEssentials

// MARK: - Keys and domains

/// The user info's description of the error, for a person.
public let NSLocalizedDescriptionKey = "NSLocalizedDescription"
/// Why the error happened, for a person.
public let NSLocalizedFailureReasonErrorKey = "NSLocalizedFailureReason"
/// What a person might do about it.
public let NSLocalizedRecoverySuggestionErrorKey = "NSLocalizedRecoverySuggestion"
/// The help anchor for the error.
public let NSHelpAnchorErrorKey = "NSHelpAnchor"
/// The error that led to this one.
public let NSUnderlyingErrorKey = "NSUnderlyingError"
/// The errors that led to this one, as an array.
public let NSMultipleUnderlyingErrorsKey = "NSMultipleUnderlyingErrorsKey"
/// A description for a developer, not a person.
public let NSDebugDescriptionErrorKey = "NSDebugDescription"
/// The errors Foundation's own APIs throw.
public let NSCocoaErrorDomain = "NSCocoaErrorDomain"
/// The errors of POSIX calls (`errno`).
public let NSPOSIXErrorDomain = "NSPOSIXErrorDomain"
/// The errors of URL loading.
public let NSURLErrorDomain = "NSURLErrorDomain"

// MARK: - CustomNSError

/// An error that says its own domain, code and user info, as an NSError
/// made from it has them.
public protocol CustomNSError: Error {
    /// The domain of the error.
    static var errorDomain: String { get }
    /// The error code within the domain.
    var errorCode: Int { get }
    /// The user info dictionary.
    var errorUserInfo: [String: Any] { get }
}

extension CustomNSError {
    /// The type's fully qualified name.
    public static var errorDomain: String { String(reflecting: self) }

    /// The code Swift gives the error (an enum's case number).
    public var errorCode: Int { _code }

    /// None.
    public var errorUserInfo: [String: Any] { [:] }
}

extension CustomNSError where Self: RawRepresentable, Self.RawValue: FixedWidthInteger {
    /// The raw value.
    public var errorCode: Int { numericCast(rawValue) }
}

extension URLError: CustomNSError {}

// MARK: - NSError

/// An error's domain, code and user info.
open class NSError: Error, @unchecked Sendable {
    private let errorDomain: String
    private let errorCode: Int
    private let errorUserInfo: [String: Any]
    /// The Swift error this one was made from (`error as NSError`), which
    /// `as?` finds again.
    fileprivate var swiftError: (any Error)?

    public init(domain: String, code: Int, userInfo dict: [String: Any]? = nil) {
        errorDomain = domain
        errorCode = code
        errorUserInfo = dict ?? [:]
    }

    /// The error's domain.
    open var domain: String { errorDomain }

    /// The error's code within its domain.
    open var code: Int { errorCode }

    /// The error's user info.
    open var userInfo: [String: Any] { errorUserInfo }

    /// The error described for a person: the user info's description, else
    /// that of the Swift error it was made from, else "The operation
    /// couldn’t be completed." with the domain and code.
    open var localizedDescription: String {
        if let description = userInfo[NSLocalizedDescriptionKey] as? String { return description }
        if let swiftError { return swiftError.localizedDescription }
        return "The operation couldn’t be completed. (\(domain) error \(code).)"
    }

    /// Why the error happened, if the user info says.
    open var localizedFailureReason: String? {
        userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? (swiftError as? any LocalizedError)?.failureReason
    }

    /// What a person might do about it, if the user info says.
    open var localizedRecoverySuggestion: String? {
        userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String ?? (swiftError as? any LocalizedError)?.recoverySuggestion
    }

    /// The help anchor, if the user info has one.
    open var helpAnchor: String? {
        userInfo[NSHelpAnchorErrorKey] as? String ?? (swiftError as? any LocalizedError)?.helpAnchor
    }

    /// The errors that led to this one: the user info's underlying error,
    /// then its multiple underlying errors.
    open var underlyingErrors: [any Error] {
        var errors: [any Error] = []
        if let underlying = userInfo[NSUnderlyingErrorKey] as? any Error { errors.append(underlying) }
        if let more = userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] { errors.append(contentsOf: more) }
        return errors
    }

    public var _domain: String { domain }

    public var _code: Int { code }
}

// MARK: - Bridging

/// The error itself when it is an NSError, else nil. Not `as? NSError`:
/// that bridges, making an NSError of any error (through the function
/// below), so it always succeeds.
func _existingNSError(_ error: any Error) -> NSError? {
    guard type(of: error) is NSError.Type else { return nil }
    return unsafeDowncast(error as AnyObject, to: NSError.self)
}

/// The NSError for a Swift error (`error as NSError`): the error itself if
/// it is one; else its domain, code and user info (a CustomNSError's own,
/// CocoaError's and POSIXError's, a LocalizedError's words), kept with the
/// error for `as?` back.
public func _convertErrorToNSError(_ error: any Error) -> NSError {
    if let error = _existingNSError(error) { return error }
    let made: NSError
    if let error = error as? any CustomNSError {
        made = NSError(domain: type(of: error).errorDomain, code: error.errorCode, userInfo: error.errorUserInfo)
    } else if let error = error as? CocoaError {
        made = NSError(domain: CocoaError.errorDomain, code: error.code.rawValue, userInfo: error.userInfo)
    } else if let error = error as? POSIXError {
        made = NSError(domain: POSIXError.errorDomain, code: Int(error.code.rawValue))
    } else {
        var userInfo: [String: Any] = [:]
        if let error = error as? any LocalizedError {
            userInfo[NSLocalizedDescriptionKey] = error.errorDescription
            userInfo[NSLocalizedFailureReasonErrorKey] = error.failureReason
            userInfo[NSLocalizedRecoverySuggestionErrorKey] = error.recoverySuggestion
            userInfo[NSHelpAnchorErrorKey] = error.helpAnchor
        }
        made = NSError(domain: error._domain, code: error._code, userInfo: userInfo)
    }
    made.swiftError = error
    return made
}

/// The Swift error an NSError stands for: the one it was made from, else
/// the NSError itself.
public func _convertNSErrorToError(_ error: NSError?) -> any Error {
    if let error {
        return error.swiftError ?? error
    }
    return NSError(domain: "Foundation._GenericObjCError", code: 0)
}
