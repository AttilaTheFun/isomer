package dev.isomer.runtime

// Other apps on the device, for the Isomer module's `AppPackages`: which are
// installed and at what version, opening one, and installing one from an APK
// through PackageInstaller (the system asks the person first). Reached
// through the host's `hostValue` and `hostRequest` ("package." keys).
//
// What the app's manifest must say: `<queries>` naming the packages it reads
// (isomer_android_app's `queries_packages`, or `queries_intents` for any
// launcher's), or Android 11 and later hide them; and
// android.permission.REQUEST_INSTALL_PACKAGES (`permissions`) to install.

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

internal object AppPackages {
    /** The activity the system's screens start from (IsomerRuntime.attach). */
    var activity: WeakReference<Activity>? = null
    private val sessions = AtomicInteger(1)
    private val app: Context? get() = activity?.get()?.applicationContext ?: HostServices.appContext

    /** "package.installed:<id>": "<versionName>\t<versionCode>", empty when
     *  it isn't installed (or the manifest's queries don't show it);
     *  "package.mayInstall": "1" when the app may install apps. */
    fun value(key: String): String {
        val app = app ?: return ""
        return when {
            key.startsWith("package.installed:") -> try {
                val info = app.packageManager.getPackageInfo(key.removePrefix("package.installed:"), 0)
                val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                (info.versionName ?: "").replace('\t', ' ') + "\t" + code
            } catch (_: PackageManager.NameNotFoundException) {
                ""
            }
            key == "package.mayInstall" -> if (mayInstall(app)) "1" else "0"
            else -> ""
        }
    }

    /** "package.open" ("<id>\n<url>"): "1" when it opened; "package.askToInstall":
     *  the system's setting for it shown; "package.install" ("<path>\n<id>"):
     *  "" when installed, else why not, in words to show. */
    suspend fun request(key: String, value: String): String {
        val app = app ?: return "There's no app to install from."
        return when (key) {
            "package.open" -> {
                val (identifier, url) = value.split("\n", limit = 2).let { it[0] to it.getOrElse(1) { "" } }
                val launch = app.packageManager.getLaunchIntentForPackage(identifier)
                    ?: url.takeIf { it.isNotEmpty() }?.let { Intent(Intent.ACTION_VIEW, Uri.parse(it)).setPackage(identifier) }
                if (launch != null && start(app, launch)) "1" else "0"
            }
            "package.askToInstall" -> {
                if (Build.VERSION.SDK_INT >= 26) {
                    start(app, Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + app.packageName)))
                } else {
                    start(app, Intent(Settings.ACTION_SECURITY_SETTINGS))
                }
                ""
            }
            "package.install" -> {
                val (path, identifier) = value.split("\n", limit = 2).let { it[0] to it.getOrElse(1) { "" } }
                install(app, File(path), identifier)
            }
            else -> ""
        }
    }

    private fun mayInstall(app: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 26) {
            app.packageManager.canRequestPackageInstalls()
        } else {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(app.contentResolver, Settings.Secure.INSTALL_NON_MARKET_APPS, 0) == 1
        }

    /** The APK at [file] installed in a PackageInstaller session: written on
     *  a thread of its own, then committed; the system's confirmation is
     *  shown, and the outcome comes back as a broadcast to this process
     *  alone. "" when installed, else why not. */
    private suspend fun install(app: Context, file: File, identifier: String): String = suspendCoroutine { done ->
        thread(name = "isomer-install") {
            val installer = app.packageManager.packageInstaller
            var session = -1
            var registered: BroadcastReceiver? = null
            try {
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                if (identifier.isNotEmpty()) params.setAppPackageName(identifier)
                params.setSize(file.length())
                session = installer.createSession(params)
                installer.openSession(session).use { open ->
                    file.inputStream().use { input ->
                        open.openWrite("base.apk", 0, file.length()).use { output ->
                            input.copyTo(output, 1 shl 16)
                            open.fsync(output)
                        }
                    }
                    val action = app.packageName + ".ISOMER_INSTALL." + sessions.getAndIncrement()
                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) {
                            when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                                    @Suppress("DEPRECATION")
                                    intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)?.let { start(app, it) }
                                }
                                PackageInstaller.STATUS_SUCCESS -> {
                                    app.unregisterReceiver(this)
                                    done.resume("")
                                }
                                else -> {
                                    app.unregisterReceiver(this)
                                    done.resume(failure(status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE), identifier))
                                }
                            }
                        }
                    }
                    registered = receiver
                    val filter = IntentFilter(action)
                    if (Build.VERSION.SDK_INT >= 33) {
                        app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        app.registerReceiver(receiver, filter)
                    }
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val pending = PendingIntent.getBroadcast(app, session, Intent(action).setPackage(app.packageName), flags)
                    open.commit(pending.intentSender)
                }
            } catch (error: Exception) {
                registered?.let { try { app.unregisterReceiver(it) } catch (_: Exception) {} }
                if (session >= 0) try { installer.abandonSession(session) } catch (_: Exception) {}
                done.resume("Android didn't take the package: " + (error.message ?: error.javaClass.simpleName))
            }
        }
    }

    /** A failed install's status in words to show, with the system's own after. */
    private fun failure(status: Int, said: String?, identifier: String): String {
        val words = when (status) {
            PackageInstaller.STATUS_FAILURE_ABORTED -> "The install was cancelled."
            PackageInstaller.STATUS_FAILURE_BLOCKED -> "Android blocked the install."
            PackageInstaller.STATUS_FAILURE_CONFLICT ->
                "${identifier.ifEmpty { "The app" }} is installed signed by another key (or a newer build is), so Android won't replace it: uninstall it first."
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "This build isn't for this device."
            PackageInstaller.STATUS_FAILURE_INVALID -> "Android says the file isn't a valid app."
            PackageInstaller.STATUS_FAILURE_STORAGE -> "There isn't room on this device for it."
            else -> "Android didn't install it."
        }
        return if (said.isNullOrBlank()) words else "$words ($said)"
    }

    /** Starts a system screen or an app, on the main thread: from the
     *  activity while it's here, else as a new task. Whether it started. */
    private fun start(app: Context, intent: Intent): Boolean {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Handler(Looper.getMainLooper()).post { start(app, intent) }
            return true
        }
        val from = activity?.get()?.takeIf { !it.isFinishing && !it.isDestroyed }
        return try {
            if (from != null) from.startActivity(intent) else app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }
}
