// swiftffi — the hand-written Kotlin half of the bridge runtime, shared by
// every generated binding (add @isomer_android//swift_ffi:kotlin to the
// deps of the kt library that compiles them). The JNI glue throws
// swiftffi/SwiftError by its fixed class path.
package swiftffi

/** A Swift error surfaced across the bridge (message only). */
class SwiftError(message: String) : Exception(message)
