// The example app's host-side platform services for the COMPILED Android
// cell (shared/platform_services): a private SharedPreferences-backed
// keychain, logcat analytics, static flags, a timer, the image picker —
// installed into the app's swift_ffi dependency dictionary through the
// generated `installPlatformDependencies` export before the runtime starts.
// Networking and files are Foundation's own (the runtime's IsomerHTTP and
// AppDirectories).

package dev.isomer.runtime

import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

object ExampleAppServices {
    fun install() {
        SwiftUIBridge.installPlatformDependencies(
            keychain = PreferencesKeychainService("example_application"),
            analytics = object : AnalyticsService {
                override fun track(event: String) { android.util.Log.i("Isomer", "[analytics] $event") }
            },
            configuration = object : ConfigurationService {
                override fun flag(key: String): Boolean = key == "promo_banner"
            },
        )
        SwiftUIBridge.installPlatformTimer(timer = LooperTimerService())
        SwiftUIBridge.installPlatformOAuth(oauth = UnsupportedOAuthService())
        SwiftUIBridge.installPlatformImagePicker(
            imagePicker = object : ImagePickerService {
                override suspend fun pickImage(maxDimension: Long): String = suspendCoroutine { cont ->
                    ImagePickerHost.pick(maxDimension.toInt()) { cont.resume(it) }
                }
            },
        )
    }
}

/** One-shot delays on the main looper. */
class LooperTimerService : TimerService {
    override suspend fun delay(milliseconds: Int): Unit = suspendCoroutine { cont ->
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ cont.resume(Unit) }, milliseconds.coerceAtLeast(0).toLong())
    }
}

/** OAuth redirect capture needs an app-declared intent filter; not carried here yet. */
class UnsupportedOAuthService : OAuthService {
    override suspend fun redirectURI(): String = throw UnsupportedOperationException("OAuth redirect capture is not carried on Android yet")
    override suspend fun authorize(url: String): String = throw UnsupportedOperationException("OAuth redirect capture is not carried on Android yet")
}


/** Secrets in a private SharedPreferences file (base64), per namespace. */
class PreferencesKeychainService(private val namespace: String) : KeychainService {
    private val prefs get() = HostServices.appContext?.getSharedPreferences("iso-keychain-$namespace", android.content.Context.MODE_PRIVATE)

    override suspend fun get(key: String): ByteArray {
        val stored = prefs?.getString(key, null) ?: throw NoSuchElementException("no keychain value for $key")
        return android.util.Base64.decode(stored, android.util.Base64.NO_WRAP)
    }

    override suspend fun set(value: ByteArray, key: String) {
        prefs?.edit()?.putString(key, android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP))?.apply()
            ?: throw IllegalStateException("no app context")
    }

    override suspend fun delete(key: String) {
        prefs?.edit()?.remove(key)?.apply() ?: throw IllegalStateException("no app context")
    }
}
