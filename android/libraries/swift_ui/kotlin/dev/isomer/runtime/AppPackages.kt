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
import kotlin.concurrent.thread
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

internal object AppPackages {
    /** The activity the system's screens start from (IsomerRuntime.attach). */
    var activity: WeakReference<Activity>? = null
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
     *  shown, and the outcome comes back as a broadcast to this process.
     *  "" when installed, else why not. */
    private suspend fun install(app: Context, file: File, identifier: String): String = suspendCoroutine { done ->
        thread(name = "isomer-install") { Install(app, file, identifier) { done.resume(it) }.run() }
    }

    /** One install, finished exactly once: by the system's final status, by
     *  the person leaving its confirmation without an answer, or by a long
     *  timeout; each way the receiver and the watches go. */
    private class Install(
        private val app: Context,
        private val file: File,
        private val identifier: String,
        private val finished: (String) -> Unit,
    ) {
        private val installer = app.packageManager.packageInstaller
        private val main = Handler(Looper.getMainLooper())
        private val done = java.util.concurrent.atomic.AtomicBoolean(false)
        private var session = -1
        private var receiver: BroadcastReceiver? = null
        private var lifecycle: android.app.Application.ActivityLifecycleCallbacks? = null
        @Volatile private var confirming = false
        // Only this install's own PendingIntent carries the token, so a
        // broadcast another app sends (a guessed action, a faked status or
        // confirmation to start) is ignored: below Android 13 a receiver
        // registered at run time is exported.
        private val token = java.util.UUID.randomUUID().toString()
        private val action = app.packageName + ".ISOMER_INSTALL." + java.util.UUID.randomUUID()

        fun run() {
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
                    listen()
                    main.postDelayed({ finish("Android didn't say whether it installed the package.", abandon = true) }, TIMEOUT_MS)
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val intent = Intent(action).setPackage(app.packageName).putExtra(TOKEN, token)
                    open.commit(PendingIntent.getBroadcast(app, session, intent, flags).intentSender)
                }
            } catch (error: Exception) {
                finish("Android didn't take the package: " + (error.message ?: error.javaClass.simpleName), abandon = true)
            }
        }

        private fun listen() {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.getStringExtra(TOKEN) != token) return
                    when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                        PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                            @Suppress("DEPRECATION")
                            val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                            confirming = true
                            AppPackages.start(app, confirm)
                        }
                        PackageInstaller.STATUS_SUCCESS -> finish("", abandon = false)
                        else -> finish(AppPackages.failure(status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE), identifier), abandon = false)
                    }
                }
            }
            this.receiver = receiver
            val filter = IntentFilter(action)
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                app.registerReceiver(receiver, filter)
            }
            // Some Android versions send nothing when the person leaves the
            // confirmation without an answer. Back in the app, a session that
            // still exists but has no progress was left: cancelled. (One the
            // system already ended waits for its broadcast, which an install
            // that went through can send after the app is back.)
            val application = app.applicationContext as? android.app.Application ?: return
            val callbacks = object : android.app.Application.ActivityLifecycleCallbacks {
                override fun onActivityResumed(a: Activity) {
                    if (!confirming || done.get()) return
                    main.postDelayed({
                        val info = try { installer.getSessionInfo(session) } catch (_: Exception) { null }
                        if (info != null && !info.isActive) finish("The install was cancelled.", abandon = true)
                    }, LEFT_CHECK_MS)
                }
                override fun onActivityCreated(a: Activity, state: android.os.Bundle?) {}
                override fun onActivityStarted(a: Activity) {}
                override fun onActivityPaused(a: Activity) {}
                override fun onActivityStopped(a: Activity) {}
                override fun onActivitySaveInstanceState(a: Activity, state: android.os.Bundle) {}
                override fun onActivityDestroyed(a: Activity) {}
            }
            lifecycle = callbacks
            application.registerActivityLifecycleCallbacks(callbacks)
        }

        private fun finish(result: String, abandon: Boolean) {
            if (!done.compareAndSet(false, true)) return
            main.removeCallbacksAndMessages(null)
            receiver?.let { try { app.unregisterReceiver(it) } catch (_: Exception) {} }
            lifecycle?.let { (app.applicationContext as? android.app.Application)?.unregisterActivityLifecycleCallbacks(it) }
            if (abandon && session >= 0) try { installer.abandonSession(session) } catch (_: Exception) {}
            finished(result)
        }

        private companion object {
            const val TOKEN = "dev.isomer.runtime.INSTALL_TOKEN"
            /** How long a session may go without a final status. */
            const val TIMEOUT_MS = 15 * 60 * 1000L
            /** How long after the app is back a left confirmation is checked. */
            const val LEFT_CHECK_MS = 3000L
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
