// How the generated bindings load their Swift libraries. By default
// `System.loadLibrary`, from the APK's native library directory; a host
// whose libraries live elsewhere (an on-demand Play feature split, which
// the base ClassLoader's lookup doesn't see) installs its own `loader`, or
// loads them itself and calls `markLoaded`, before any binding is touched:
//
//   swiftffi.NativeLibraries.loader = { name -> SplitInstallHelper.loadLibrary(context, name) }
//
// Each library is loaded once, whichever way.
package swiftffi

object NativeLibraries {
  private val loaded = mutableSetOf<String>()

  /** Loads a library by its name ("greeter" for libgreeter.so). */
  @JvmStatic
  @Volatile
  var loader: (String) -> Unit = { name -> System.loadLibrary(name) }

  /** Loads `name` with `loader`, unless it was loaded already. */
  @JvmStatic
  fun load(name: String) {
    synchronized(loaded) {
      if (name in loaded) return
      loader(name)
      loaded += name
    }
  }

  /** Records that the host loaded `name` itself (from a split, say), so
   *  the bindings don't load it again. */
  @JvmStatic
  fun markLoaded(name: String) {
    synchronized(loaded) { loaded += name }
  }
}
