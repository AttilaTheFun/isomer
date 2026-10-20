package dev.isomer.runtime

// The app's directories for Foundation's FileManager, laid out as an iOS
// app's container, as the web lays out its own (AGENTS.md, "App files on the
// web"). swift-foundation on Android takes them from the environment: the
// home from CFFIXED_USER_HOME (before getpwuid's, which is no app's) and
// HOME, Application Support and Caches from XDG_DATA_HOME and
// XDG_CACHE_HOME, Documents as ~/Documents, the temporary directory from
// TMPDIR (else /data/local/tmp, which an app cannot write). So the runtime
// sets them, in Kotlin, before any Swift runs: the paths are the Context's,
// and the process's environment is best changed early, on the main thread,
// before other threads read it.
//
//   HOME = CFFIXED_USER_HOME = the app's files directory (filesDir)
//     Documents/                        URL.documentsDirectory
//     Library/Application Support/      XDG_DATA_HOME, .applicationSupportDirectory
//     Library/Caches -> <cacheDir>/Caches (a symbolic link)
//   XDG_CACHE_HOME = <cacheDir>/Caches  .cachesDirectory
//   TMPDIR = <cacheDir>                 FileManager.temporaryDirectory
//   ISOMER_BUNDLE_IDENTIFIER = the package name (Bundle.main.bundleIdentifier)
//   ISOMER_BUNDLE_NAME, _SHORT_VERSION, _VERSION = its label, versionName and
//     versionCode (Bundle.main.infoDictionary's CFBundle keys)
//
// What an app keeps (Documents, Application Support) is in the files
// directory: it lasts until the app is uninstalled or its data cleared, and
// Android's backup takes it, as iOS's does. Caches live in Android's cache
// directory, which is what iOS's Library/Caches is: not backed up, emptied by
// the system when storage runs low and by the "Clear cache" button in the
// app's settings. (Under the files directory they would be backed up, count
// against the backup's quota, and never be cleared.) The link keeps the
// container's layout for code that builds paths from the home; backups skip
// links. Temporary files go where Android already sends Java's
// (java.io.tmpdir is the cache directory), one place for the process, as on
// iOS.

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File

object AppDirectories {
    /** The home last prepared: a second surface or delivery leaves it be. */
    private var prepared: String? = null

    /** Makes the directories and sets the environment; once per home. */
    @Synchronized
    fun prepare(context: Context) {
        val app = context.applicationContext ?: context
        val home = app.filesDir
        if (prepared == home.path) return
        val support = File(home, "Library/Application Support")
        val caches = File(app.cacheDir, "Caches")
        for (directory in listOf(File(home, "Documents"), support, caches)) directory.mkdirs()
        link(File(home, "Library/Caches"), caches)
        try {
            Os.setenv("HOME", home.path, true)
            Os.setenv("CFFIXED_USER_HOME", home.path, true)
            Os.setenv("XDG_DATA_HOME", support.path, true)
            Os.setenv("XDG_CACHE_HOME", caches.path, true)
            Os.setenv("TMPDIR", app.cacheDir.path, true)
            Os.setenv("ISOMER_BUNDLE_IDENTIFIER", app.packageName, true)
            // Its name and version, for Bundle.main.infoDictionary.
            Os.setenv("ISOMER_BUNDLE_NAME", app.applicationInfo.loadLabel(app.packageManager).toString(), true)
            try {
                val info = app.packageManager.getPackageInfo(app.packageName, 0)
                val code = if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                Os.setenv("ISOMER_BUNDLE_SHORT_VERSION", info.versionName ?: "", true)
                Os.setenv("ISOMER_BUNDLE_VERSION", code.toString(), true)
            } catch (_: android.content.pm.PackageManager.NameNotFoundException) {
            }
        } catch (error: ErrnoException) {
            android.util.Log.w("Isomer", "the app's directories are not in the environment", error)
            return
        }
        prepared = home.path
    }

    /** `link` pointing at `target`, unless the app put a directory of its own there. */
    private fun link(link: File, target: File) {
        val existing = try { Os.lstat(link.path) } catch (_: ErrnoException) { null }
        if (existing != null) {
            if (!OsConstants.S_ISLNK(existing.st_mode)) return
            if (try { Os.readlink(link.path) } catch (_: ErrnoException) { null } == target.path) return
            link.delete()
        }
        try {
            Os.symlink(target.path, link.path)
        } catch (error: ErrnoException) {
            android.util.Log.w("Isomer", "no link from ${link.path} to the caches", error)
        }
    }
}
