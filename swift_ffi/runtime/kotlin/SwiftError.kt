// swiftffi — the hand-written Kotlin half of the bridge runtime, shared by
// every generated binding (add @isomer//swift_ffi/runtime/kotlin to the
// deps of the kt library that compiles them). The JNI glue throws
// swiftffi/SwiftError by its fixed class path.
package swiftffi

/** A Swift error surfaced across the bridge (message only). */
class SwiftError(message: String) : Exception(message)
