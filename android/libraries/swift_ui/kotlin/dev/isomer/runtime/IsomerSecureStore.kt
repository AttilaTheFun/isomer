package dev.isomer.runtime

// The Isomer module's SecureStore on Android: the swift_ffi interface
// IsomerNetworkHost declares (`SecureStoreHost`, generated into
// SwiftUIBridge), handed to Swift through `installIsomerSecureStore` before
// the runtime starts (IsomerRuntime.prepare). Each value is sealed with
// AES-GCM by a key that never leaves the Android Keystore, and kept, sealed,
// in the app's private preferences: readable by the app alone, gone with it,
// and of no use copied off the device. An app that injects its own under
// `SecureStoreHostKey`'s key has that instead.

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class AndroidSecureStoreHost(context: Context) : SecureStoreHost {
    private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    /** The Keystore's key, made the first time it's needed. */
    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun slot(service: String, key: String) = service + "\u001F" + key

    @Synchronized
    override fun read(service: String, key: String): SecureStoreHostValue {
        val stored = preferences.getString(slot(service, key), null)
            ?: return SecureStoreHostValue(found = false, value = ByteArray(0), error = "")
        return try {
            val sealed = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_LENGTH))
            SecureStoreHostValue(found = true, value = cipher.doFinal(sealed, IV_LENGTH, sealed.size - IV_LENGTH), error = "")
        } catch (failure: Exception) {
            SecureStoreHostValue(found = false, value = ByteArray(0), error = failure.toString())
        }
    }

    @Synchronized
    override fun write(service: String, key: String, value: ByteArray): String = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value)
        if (preferences.edit().putString(slot(service, key), Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()) "" else "not written"
    } catch (failure: Exception) {
        failure.toString()
    }

    @Synchronized
    override fun remove(service: String, key: String): String =
        if (preferences.edit().remove(slot(service, key)).commit()) "" else "not removed"

    companion object {
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "dev.isomer.secure-store"
        private const val PREFERENCES = "dev.isomer.secure-store"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_LENGTH = 12
        private var installed = false

        /** Installs the store as SecureStore's; once. */
        @Synchronized
        fun install(context: Context) {
            if (installed) return
            installed = true
            SwiftUIBridge.installIsomerSecureStore(host = AndroidSecureStoreHost(context))
        }
    }
}
