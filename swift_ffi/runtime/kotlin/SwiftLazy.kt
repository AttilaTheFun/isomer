// A deferred Swift value: the Swift-side computation runs on first `value`
// access (then caches, releasing the handle). `close()` releases an
// un-unwrapped handle early; a finalizer backstop covers leaks.
package swiftffi

class SwiftLazy<T>(
  private var handle: Long,
  private val get: (Long) -> ByteArray,
  private val release: (Long) -> Unit,
  private val decode: (ByteArray) -> T,
) : AutoCloseable {
  private var cached: T? = null
  private var hasValue = false

  /** The value, computed in Swift on first access. */
  @Suppress("UNCHECKED_CAST")
  val value: T
    get() {
      if (!hasValue) {
        check(handle != 0L) { "Lazy used after close()" }
        val bytes = get(handle)
        cached = decode(bytes)
        hasValue = true
        close()
      }
      return cached as T
    }

  /** Releases the underlying Swift handle. Idempotent. */
  override fun close() {
    if (handle != 0L) {
      release(handle)
      handle = 0L
    }
  }

  @Suppress("removal", "deprecation")
  protected fun finalize() {
    close()
  }
}
