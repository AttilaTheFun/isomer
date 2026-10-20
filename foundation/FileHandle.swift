// FileHandle over a file descriptor (Apple's Foundation and corelibs have
// it; swift-foundation does not): reading, writing, seeking and closing.
// The run-loop-driven background reads and the readability handlers are
// not here (docs/parity/Foundation.md).

import FoundationEssentials
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#endif

open class FileHandle: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let closeOnDealloc: Bool
    private var closed = false

    public init(fileDescriptor fd: Int32, closeOnDealloc closeopt: Bool) {
        fileDescriptor = fd
        closeOnDealloc = closeopt
    }

    public convenience init(fileDescriptor fd: Int32) {
        self.init(fileDescriptor: fd, closeOnDealloc: false)
    }

    deinit {
        if closeOnDealloc && !closed {
            _ = Self.systemClose(fileDescriptor)
        }
    }

    public static let standardInput = FileHandle(fileDescriptor: 0)
    public static let standardOutput = FileHandle(fileDescriptor: 1)
    public static let standardError = FileHandle(fileDescriptor: 2)

    public static var nullDevice: FileHandle {
        FileHandle(forUpdatingAtPath: "/dev/null") ?? FileHandle(fileDescriptor: -1)
    }

    private convenience init?(path: String, flags: Int32) {
        let fd = systemOpen(path, flags)
        guard fd >= 0 else { return nil }
        self.init(fileDescriptor: fd, closeOnDealloc: true)
    }

    private convenience init(url: URL, flags: Int32) throws {
        let fd = systemOpen(url.path, flags)
        guard fd >= 0 else { throw Self.lastError() }
        self.init(fileDescriptor: fd, closeOnDealloc: true)
    }

    public convenience init?(forReadingAtPath path: String) {
        self.init(path: path, flags: O_RDONLY)
    }

    public convenience init?(forWritingAtPath path: String) {
        self.init(path: path, flags: O_WRONLY)
    }

    public convenience init?(forUpdatingAtPath path: String) {
        self.init(path: path, flags: O_RDWR)
    }

    public convenience init(forReadingFrom url: URL) throws {
        try self.init(url: url, flags: O_RDONLY)
    }

    public convenience init(forWritingTo url: URL) throws {
        try self.init(url: url, flags: O_WRONLY)
    }

    public convenience init(forUpdating url: URL) throws {
        try self.init(url: url, flags: O_RDWR)
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func systemClose(_ fd: Int32) -> Int32 {
        Glibc_close(fd)
    }

    // MARK: Reading

    /// Up to `count` bytes; nil at the end of the file.
    public func read(upToCount count: Int) throws -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(max(count, 0), 64 << 10))
        while data.count < count {
            let wanted = min(buffer.count, count - data.count)
            let got = buffer.withUnsafeMutableBytes { Glibc_read(fileDescriptor, $0.baseAddress, wanted) }
            if got < 0 {
                if errno == EINTR { continue }
                throw Self.lastError()
            }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<got])
        }
        return data.isEmpty && count > 0 ? nil : data
    }

    /// Everything to the end of the file; nil when there was nothing.
    public func readToEnd() throws -> Data? {
        var data = Data()
        while let chunk = try read(upToCount: 64 << 10) {
            data.append(chunk)
        }
        return data.isEmpty ? nil : data
    }

    public var availableData: Data {
        (try? read(upToCount: 64 << 10)) ?? Data()
    }

    public func readDataToEndOfFile() -> Data {
        (try? readToEnd()) ?? Data()
    }

    public func readData(ofLength length: Int) -> Data {
        (try? read(upToCount: length)) ?? Data()
    }

    // MARK: Writing

    public func write<T: DataProtocol>(contentsOf data: T) throws {
        for region in data.regions {
            try region.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Glibc_write(fileDescriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.lastError()
                    }
                    offset += written
                }
            }
        }
    }

    public func write(_ data: Data) {
        try? write(contentsOf: data)
    }

    // MARK: Position

    public func offset() throws -> UInt64 {
        let position = lseek(fileDescriptor, 0, SEEK_CUR)
        guard position >= 0 else { throw Self.lastError() }
        return UInt64(position)
    }

    @discardableResult
    public func seekToEnd() throws -> UInt64 {
        let position = lseek(fileDescriptor, 0, SEEK_END)
        guard position >= 0 else { throw Self.lastError() }
        return UInt64(position)
    }

    public func seek(toOffset offset: UInt64) throws {
        guard lseek(fileDescriptor, off_t(offset), SEEK_SET) >= 0 else { throw Self.lastError() }
    }

    public var offsetInFile: UInt64 { (try? offset()) ?? 0 }

    @discardableResult
    public func seekToEndOfFile() -> UInt64 {
        (try? seekToEnd()) ?? 0
    }

    public func seek(toFileOffset offset: UInt64) {
        try? seek(toOffset: offset)
    }

    public func truncate(atOffset offset: UInt64) throws {
        guard ftruncate(fileDescriptor, off_t(offset)) == 0 else { throw Self.lastError() }
        try seek(toOffset: offset)
    }

    public func truncateFile(atOffset offset: UInt64) {
        try? truncate(atOffset: offset)
    }

    public func synchronize() throws {
        guard fsync(fileDescriptor) == 0 else { throw Self.lastError() }
    }

    public func synchronizeFile() {
        try? synchronize()
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        guard Self.systemClose(fileDescriptor) == 0 else { throw Self.lastError() }
    }

    public func closeFile() {
        try? close()
    }
}

// The C calls under names of their own: inside FileHandle, `read` and
// `write` are its methods.
private func Glibc_read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}

private func Glibc_write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}

private func Glibc_close(_ fd: Int32) -> Int32 {
    close(fd)
}

private func systemOpen(_ path: String, _ flags: Int32) -> Int32 {
    open(path, flags, 0o644)
}
