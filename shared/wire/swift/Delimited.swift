// Messages in a stream of bytes (a pipe, a file): each length-delimited, a
// varint length and then the message, as protobuf's writeDelimitedTo writes
// them. The headless host's standard input and output carry them.

import Foundation
import SwiftProtobuf
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum WireDelimited {
    /// `message`, with its length before it.
    public static func frame(_ message: some SwiftProtobuf.Message) throws -> Data {
        let body: Data = try message.serializedBytes()
        var framed = Data()
        var length = UInt64(body.count)
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length != 0 { byte |= 0x80 }
            framed.append(byte)
        } while length != 0
        framed.append(body)
        return framed
    }

    /// The next message's bytes from `descriptor`, waiting for them; nil at
    /// the stream's end (or a length past what a message may be).
    public static func read(from descriptor: Int32) -> [UInt8]? {
        var length: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard let byte = readExactly(1, from: descriptor)?.first, shift < 64 else { return nil }
            length |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        guard length <= UInt64(Int32.max) else { return nil }
        return length == 0 ? [] : readExactly(Int(length), from: descriptor)
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                Darwin.read(descriptor, buffer.baseAddress! + filled, count - filled)
                #else
                Glibc.read(descriptor, buffer.baseAddress! + filled, count - filled)
                #endif
            }
            if got < 0 && errno == EINTR { continue }
            if got <= 0 { return nil }
            filled += got
        }
        return bytes
    }
}
