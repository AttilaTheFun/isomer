// Stream, InputStream and OutputStream, as Isomer's Foundation has them:
// Swift classes for streams over memory and files, read and written
// synchronously. Apple's are Objective-C classes scheduled on run loops;
// these have no run loop, no delegate events and no sockets
// (docs/parity/Foundation.md). SwiftProtobuf's delimited messages, for one,
// read and write through them.

import FoundationEssentials

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(ucrt)
import ucrt
#endif

open class Stream: @unchecked Sendable {
    public enum Status: UInt, Sendable {
        case notOpen = 0
        case opening = 1
        case open = 2
        case reading = 3
        case writing = 4
        case atEnd = 5
        case closed = 6
        case error = 7
    }

    public struct Event: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let openCompleted = Event(rawValue: 1 << 0)
        public static let hasBytesAvailable = Event(rawValue: 1 << 1)
        public static let hasSpaceAvailable = Event(rawValue: 1 << 2)
        public static let errorOccurred = Event(rawValue: 1 << 3)
        public static let endEncountered = Event(rawValue: 1 << 4)
    }

    public struct PropertyKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let dataWrittenToMemoryStreamKey = PropertyKey("NSStreamDataWrittenToMemoryStreamKey")
        public static let fileCurrentOffsetKey = PropertyKey("NSStreamFileCurrentOffsetKey")
    }

    public internal(set) var streamStatus: Status = .notOpen
    public internal(set) var streamError: (any Error)?

    init() {}

    open func open() {
        if streamStatus == .notOpen { streamStatus = .open }
    }

    open func close() {
        streamStatus = .closed
    }

    open func property(forKey key: PropertyKey) -> Any? { nil }

    open func setProperty(_ property: Any?, forKey key: PropertyKey) -> Bool { false }
}

open class InputStream: Stream, @unchecked Sendable {
    private var bytes: [UInt8] = []
    private var offset = 0
    private var pendingFile: String?

    public init(data: Data) {
        bytes = Array(data)
        super.init()
    }

    public init?(url: URL) {
        guard url.isFileURL else { return nil }
        pendingFile = url.path
        super.init()
    }

    public convenience init?(fileAtPath path: String) {
        self.init(url: URL(fileURLWithPath: path))
    }

    open override func open() {
        guard streamStatus == .notOpen else { return }
        if let path = pendingFile {
            do {
                bytes = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                streamError = error
                streamStatus = .error
                return
            }
        }
        streamStatus = bytes.isEmpty ? .atEnd : .open
    }

    /// Copies up to `len` bytes into `buffer`: how many, 0 at the end, -1 on
    /// an error.
    open func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if streamStatus == .error { return -1 }
        guard streamStatus == .open || streamStatus == .atEnd else { return -1 }
        let count = min(len, bytes.count - offset)
        if count <= 0 {
            streamStatus = .atEnd
            return 0
        }
        bytes.withUnsafeBufferPointer { source in
            buffer.update(from: source.baseAddress! + offset, count: count)
        }
        offset += count
        if offset == bytes.count { streamStatus = .atEnd }
        return count
    }

    open func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>
    ) -> Bool { false }

    open var hasBytesAvailable: Bool { streamStatus == .open && offset < bytes.count }

    open override func property(forKey key: PropertyKey) -> Any? {
        key == .fileCurrentOffsetKey ? offset : nil
    }
}

open class OutputStream: Stream, @unchecked Sendable {
    private enum Target {
        case memory
        case buffer(UnsafeMutablePointer<UInt8>, capacity: Int)
        case file(path: String, append: Bool)
    }

    private let target: Target
    private var written: [UInt8] = []

    public required init(toMemory: ()) {
        target = .memory
        super.init()
    }

    public init(toBuffer buffer: UnsafeMutablePointer<UInt8>, capacity: Int) {
        target = .buffer(buffer, capacity: capacity)
        super.init()
    }

    public init?(url: URL, append shouldAppend: Bool) {
        guard url.isFileURL else { return nil }
        target = .file(path: url.path, append: shouldAppend)
        super.init()
    }

    public convenience init?(toFileAtPath path: String, append shouldAppend: Bool) {
        self.init(url: URL(fileURLWithPath: path), append: shouldAppend)
    }

    open class func toMemory() -> Self {
        self.init(toMemory: ())
    }

    /// Writes up to `len` bytes from `buffer`: how many, -1 on an error.
    open func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        guard streamStatus == .open || streamStatus == .writing else { return -1 }
        var count = len
        if case .buffer(_, let capacity) = target {
            count = min(len, capacity - written.count)
            if count <= 0 {
                streamStatus = .atEnd
                return 0
            }
        }
        written.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))
        if case .buffer(let destination, _) = target {
            (destination + written.count - count).update(from: buffer, count: count)
        }
        if case .file = target, !flush() { return -1 }
        return count
    }

    open var hasSpaceAvailable: Bool {
        if case .buffer(_, let capacity) = target { return written.count < capacity }
        return streamStatus == .open
    }

    open override func property(forKey key: PropertyKey) -> Any? {
        switch key {
        case .dataWrittenToMemoryStreamKey:
            if case .memory = target { return Data(written) }
            return nil
        case .fileCurrentOffsetKey:
            return written.count
        default:
            return nil
        }
    }

    /// A file stream writes what it has through to the file.
    private func flush() -> Bool {
        guard case .file(let path, let append) = target else { return true }
        do {
            var data = Data()
            if append, let existing = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                data = existing
            }
            data.append(contentsOf: written)
            try data.write(to: URL(fileURLWithPath: path))
            if append {
                written.removeAll()
            }
            return true
        } catch {
            streamError = error
            streamStatus = .error
            return false
        }
    }
}
