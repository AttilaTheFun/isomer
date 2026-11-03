// NSObject and NSObjectProtocol, without the Objective-C runtime: what Swift
// code asks of them (a model class that subclasses NSObject, a type checked
// against NSObjectProtocol), as swift-corelibs-foundation has them. Equal by
// identity unless a subclass says otherwise, its hash from its identity,
// described by its type and address. No selectors, key-value coding or
// messaging: Isomer's Foundation has no runtime to send them through.
// Isomer's own classes (Bundle, URLSessionTask, …) are plain Swift classes
// and don't subclass it.

/// What every NSObject answers.
public protocol NSObjectProtocol: AnyObject {
    func isEqual(_ object: Any?) -> Bool
    var hash: Int { get }
    var description: String { get }
}

open class NSObject: NSObjectProtocol, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public init() {}

    /// The same object; a subclass compares what it holds.
    open func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NSObject else { return false }
        return other === self
    }

    /// Its identity's, unless a subclass that overrides `isEqual(_:)`
    /// overrides this too (objects that are equal hash alike).
    open var hash: Int { ObjectIdentifier(self).hashValue }

    open var description: String {
        "<\(type(of: self)): 0x\(String(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()), radix: 16))>"
    }

    open var debugDescription: String { description }

    public static func == (lhs: NSObject, rhs: NSObject) -> Bool { lhs.isEqual(rhs) }

    public func hash(into hasher: inout Hasher) { hasher.combine(hash) }
}
