// The uniform callback channel into Kotlin: closures, foreign interface
// dispatchers, and async completions all cross the boundary as one of these.
// The JNI adapter wraps it in a `bridge_closure` vtable; Swift invokes it
// with a blob-encoded argument sequence (foreign interface calls lead with an
// Int32 method ordinal) and receives a blob-encoded result. Exceptions become
// ERROR blobs on the Swift side.
package swiftffi

fun interface SwiftClosure {
  fun invoke(args: ByteArray): ByteArray
}
