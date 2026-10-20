// The hand-written marshaling vocabulary the macro-expanded C ABI calls at
// the boundary: byte boxes, (pointer, length) decoding, packed foreign
// slots, and — on Android — the JNI byte-array/string conversions.
//
// This lives in the same `SwiftFFI` module as the macros because macro
// expansions compile inside the CONSUMER's module and can only reference
// modules that module already imports — which is exactly `SwiftFFI`.

/// Owns the bytes of a string or byte-array value crossing the boundary;
/// consumers copy the bytes out and release the box.
public final class SwiftFFIStringBox {
    public let bytes: [UInt8]

    public init(_ string: String) { self.bytes = Array(string.utf8) }

    public init(bytes: [UInt8]) { self.bytes = bytes }
}

/// The marshaling helpers the expanded thunks call at the boundary: decoding
/// incoming (pointer, length) buffers, unpacking packed foreign slots, and —
/// on Android — the JNI byte-array/string conversions.
public enum SwiftFFIBridge {
    /// Decodes a UTF-8 (pointer, length) parameter into a Swift string.
    public static func string(_ pointer: UnsafeRawPointer?, _ length: Int32) -> String {
        guard let pointer, length > 0 else { return "" }
        let buffer = UnsafeRawBufferPointer(start: pointer, count: Int(length))
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Copies a (pointer, length) parameter into a Swift byte array.
    public static func bytes(_ pointer: UnsafeRawPointer?, _ length: Int32) -> [UInt8] {
        guard let pointer, length > 0 else { return [] }
        return Array(UnsafeRawBufferPointer(start: pointer, count: Int(length)))
    }

    /// Unpacks a (len << 32) | ptr buffer slot, taking ownership of the bytes
    /// (the reader frees them).
    public static func unpackForeignBytes(_ packed: UInt64) -> [UInt8] {
        let length = Int(packed >> 32)
        guard length > 0, let pointer = UnsafeMutableRawPointer(bitPattern: UInt(packed & 0xffff_ffff)) else {
            return []
        }
        let result = Array(UnsafeRawBufferPointer(start: pointer, count: length))
        pointer.deallocate()
        return result
    }

    public static func unpackForeignString(_ packed: UInt64) -> String {
        String(decoding: unpackForeignBytes(packed), as: UTF8.self)
    }
}

#if canImport(Android)
import Android

// JNI-side helpers for the Android (kotlin) bridge.

extension SwiftFFIBridge {
    public static func bytes(_ env: UnsafeMutablePointer<JNIEnv?>, _ array: jbyteArray?) -> [UInt8] {
        guard let array else { return [] }
        let jni = env.pointee!.pointee
        let length = Int(jni.GetArrayLength(env, array))
        guard length > 0 else { return [] }
        var buffer = [Int8](repeating: 0, count: length)
        buffer.withUnsafeMutableBufferPointer { pointer in
            jni.GetByteArrayRegion(env, array, 0, jsize(length), pointer.baseAddress)
        }
        return buffer.withUnsafeBytes { Array($0) }
    }

    public static func string(_ env: UnsafeMutablePointer<JNIEnv?>, _ array: jbyteArray?) -> String {
        String(decoding: bytes(env, array), as: UTF8.self)
    }

    public static func javaByteArray(_ env: UnsafeMutablePointer<JNIEnv?>, _ bytes: [UInt8]) -> jbyteArray? {
        let jni = env.pointee!.pointee
        guard let array = jni.NewByteArray(env, jsize(bytes.count)) else { return nil }
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { raw in
                jni.SetByteArrayRegion(
                    env, array, 0, jsize(bytes.count),
                    raw.baseAddress!.assumingMemoryBound(to: jbyte.self))
            }
        }
        return array
    }

    public static func javaByteArray(_ env: UnsafeMutablePointer<JNIEnv?>, _ string: String) -> jbyteArray? {
        javaByteArray(env, Array(string.utf8))
    }

    /// Copies a jbyteArray out and releases the local ref.
    public static func takeByteArray(_ env: UnsafeMutablePointer<JNIEnv?>, _ object: jobject?) -> [UInt8] {
        guard let object else { return [] }
        let result = bytes(env, object)
        env.pointee!.pointee.DeleteLocalRef(env, object)
        return result
    }

    public static func handlePointer(_ handle: jlong) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: Int(handle))!
    }

    /// Throws a `swiftffi.SwiftError` into the calling Java frame; the pending
    /// exception surfaces when the native call returns.
    public static func throwError(_ env: UnsafeMutablePointer<JNIEnv?>, _ message: String) {
        let jni = env.pointee!.pointee
        guard let cls = jni.FindClass(env, "swiftffi/SwiftError") else { return }
        _ = message.withCString { jni.ThrowNew(env, cls, $0) }
    }

    /// A real java.lang.String (UTF-16) for calls *into* Kotlin interface
    /// implementations; the jbyteArray convention is only used for the
    /// consumer-driven direction.
    public static func javaString(_ env: UnsafeMutablePointer<JNIEnv?>, _ string: String) -> jobject? {
        let jni = env.pointee!.pointee
        let units = Array(string.utf16)
        return units.withUnsafeBufferPointer { buffer in
            jni.NewString(env, buffer.baseAddress, jsize(units.count))
        }
    }

    public static func swiftString(_ env: UnsafeMutablePointer<JNIEnv?>, _ object: jobject?) -> String {
        guard let object else { return "" }
        let jni = env.pointee!.pointee
        let length = Int(jni.GetStringLength(env, object))
        guard length > 0, let chars = jni.GetStringChars(env, object, nil) else { return "" }
        let result = String(decoding: UnsafeBufferPointer(start: chars, count: length), as: UTF16.self)
        jni.ReleaseStringChars(env, object, chars)
        jni.DeleteLocalRef(env, object)
        return result
    }
}
#endif
