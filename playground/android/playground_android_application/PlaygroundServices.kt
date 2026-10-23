// The Playground's host on Android, installed through the generated
// bindings before the runtime starts: the platform services the app's Swift
// uses (keychain, timer, image picker; its network and files are Foundation's),
// the PlaygroundHostService (compile, run, chat, the key), and the two
// app-authored host views the shared screens draw — the code editor and the
// run surface.
//
// Compiling: swift-frontend and wasm-ld built for Android (stage_toolchain.sh),
// run as processes from the APK's native library directory against the SDK
// unpacked from the app's assets on first use.
// Running: the build (a `iso_hot` reactor, as on the web and iOS) in
// RunActivity, a window and process of its own; the run cover here only
// waits for it to close.

package dev.isomer.runtime

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.isomer.platform.PlatformServicesWasm
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream
import kotlin.concurrent.thread
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine
import org.json.JSONObject

object PlaygroundAndroidServices {
    /** [activity]: the installer runs before the runtime attaches, so the
     *  context comes from the activity, not HostServices. */
    fun install(activity: android.app.Activity) {
        val context = activity.applicationContext
        val preferences = context.getSharedPreferences("playground", Context.MODE_PRIVATE)
        SwiftUIBridge.installPlatformDependencies(
            keychain = PreferencesKeychainService("playground"),
            analytics = object : AnalyticsService {
                override fun track(event: String) { android.util.Log.i("Playground", "[analytics] $event") }
            },
            configuration = object : ConfigurationService {
                override fun flag(key: String): Boolean = false
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
        SwiftUIBridge.installPlaygroundHost(host = AndroidPlaygroundHost(context, preferences))
        PlaygroundRun.listen(context)
        AppHostViews.factories["codeeditor"] = { node, modifier, edit -> CodeEditorView(node, modifier, edit) }
        AppHostViews.factories["surface"] = { _, modifier, edit -> RunSurfaceView(modifier, edit) }
    }
}


/** The compiler (native executables in the APK's library directory) and the
 *  SDK, unpacked from assets/toolchain.zip on first use (or after a newer zip
 *  ships: the manifest's version names the unpacking). */
private class Toolchain(private val context: Context) {
    val root = File(context.filesDir, "toolchain")
    private val libraries = File(context.applicationInfo.nativeLibraryDir)
    val frontend get() = File(libraries, "libswift-frontend.so")
    val linker get() = File(libraries, "libwasm-ld.so")
    val libraryPath: String get() = libraries.absolutePath
    /** Macros, as the iOS Playground's compiler runs them: the in-process
     *  plugin server and the prebuilt plugins (ObservationMacros for
     *  @Observable, SwiftMacros for @TaskLocal and the like), loaded by the
     *  frontend with dlopen. Empty when the toolchain was staged without them. */
    val macroArguments: List<String> get() {
        val server = File(libraries, "libSwiftInProcPluginServer.so")
        if (!server.exists()) return emptyList()
        return listOf("-in-process-plugin-server-path", server.absolutePath) +
            listOf("libObservationMacros.so", "libSwiftMacros.so").map { File(libraries, it) }.filter { it.exists() }
                .flatMap { listOf("-load-plugin-library", it.absolutePath) }
    }
    private val marker get() = File(root, ".unpacked")

    val packaged: Boolean get() = frontend.exists() && linker.exists() &&
        try { context.assets.open("toolchain.zip").close(); true } catch (_: Exception) { false }

    /** null when ready, else why not. */
    @Synchronized fun ensure(): String? {
        if (!packaged) return "the toolchain is not in this build (run stage_toolchain.sh, then build again)"
        val packagedVersion = try {
            ZipInputStream(context.assets.open("toolchain.zip")).use { zip ->
                generateSequence { zip.nextEntry }.firstOrNull { it.name == "manifest.json" }
                    ?.let { JSONObject(zip.readBytes().toString(Charsets.UTF_8)).optString("version") }
            } ?: "unversioned"
        } catch (e: Exception) { return "cannot read the toolchain: $e" }
        if (marker.exists() && marker.readText() == packagedVersion) return null
        root.deleteRecursively()
        root.mkdirs()
        try {
            ZipInputStream(context.assets.open("toolchain.zip")).use { zip ->
                var entry = zip.nextEntry
                while (entry != null) {
                    val target = File(root, entry.name)
                    if (!target.canonicalPath.startsWith(root.canonicalPath)) throw IllegalStateException("bad path ${entry.name}")
                    if (entry.isDirectory) target.mkdirs() else {
                        target.parentFile?.mkdirs()
                        target.outputStream().use { zip.copyTo(it) }
                    }
                    entry = zip.nextEntry
                }
            }
        } catch (e: Exception) { return "cannot unpack the toolchain: $e" }
        marker.writeText(packagedVersion)
        return null
    }

    /** The SDK's layout, from its manifest (the browser bundle's). */
    val manifest: JSONObject get() = JSONObject(File(root, "manifest.json").readText())
}

/** Whether the build's window (RunActivity, its own process) is up. */
object PlaygroundRun {
    var running by mutableStateOf(false)

    fun listen(context: Context) {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: android.content.Intent?) { running = false }
        }
        val filter = android.content.IntentFilter(RunActivity.ACTION_STOPPED)
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag") context.registerReceiver(receiver, filter)
        }
    }
}

class AndroidPlaygroundHost(private val context: Context, private val preferences: android.content.SharedPreferences) : PlaygroundHostService {
    private val toolchain = Toolchain(context)
    private val web = WebRunServer(context)
    private val work = File(context.filesDir, "work")
    @Volatile private var status: String = if (toolchain.packaged) "Swift toolchain on the phone (swift-frontend for Android)" else "No compiler: " + (toolchain.ensure() ?: "")
    @Volatile private var lastBuild: File? = null

    override suspend fun compile(source: String): String = suspendCoroutine { cont ->
        thread(name = "playground-compile") {
            try { cont.resume(compileNow(source)) } catch (e: Throwable) { cont.resumeWithException(e) }
        }
    }

    private fun compileNow(source: String): String {
        toolchain.ensure()?.let { status = "No compiler: $it"; return it }
        val manifest = toolchain.manifest.getJSONObject("sdk")
        val T = { path: String -> File(toolchain.root, path).absolutePath }
        work.mkdirs()
        File(work, "App.swift").writeText(source)
        val obj = File(work, "UserApp.o"); obj.delete()
        val wasm = File(work, "UserApp.wasm"); wasm.delete()
        File(work, "module-cache").mkdirs()
        val env = mapOf("HOME" to work.absolutePath, "TMPDIR" to work.absolutePath)
        // 1. swift-frontend -frontend -c … (the flags the web driver uses).
        val frontendArgs = mutableListOf(
            "swift-frontend", "-frontend", "-c", "-primary-file", File(work, "App.swift").absolutePath,
            "-target", "wasm32-unknown-wasip1", "-Xcc", "--target=wasm32-unknown-wasip1",
            "-disable-objc-interop", "-use-static-resource-dir", "-sdk", T(manifest.getString("sysroot")),
            "-resource-dir", T(manifest.getString("resourceDir")), "-I", T(manifest.getString("modules")),
            "-module-cache-path", File(work, "module-cache").absolutePath,
            "-swift-version", "5", "-Onone", "-parse-as-library", "-module-name", "UserApp", "-o", obj.absolutePath,
        )
        frontendArgs += toolchain.macroArguments
        val clangModules = manifest.optJSONArray("clangModules")
        for (i in 0 until (clangModules?.length() ?: 0)) {
            val entry = clangModules!!.getJSONObject(i)
            entry.optString("modulemap").takeIf { it.isNotEmpty() }?.let { frontendArgs += listOf("-Xcc", "-fmodule-map-file=" + T(it)) }
            entry.optString("include").takeIf { it.isNotEmpty() }?.let { frontendArgs += listOf("-Xcc", "-I", "-Xcc", T(it)) }
        }
        val frontendStarted = android.os.SystemClock.uptimeMillis()
        val compiled = run(toolchain.frontend, frontendArgs, env)
        android.util.Log.i("Playground", "[build] swift-frontend: ${android.os.SystemClock.uptimeMillis() - frontendStarted}ms")
        if (!compiled.ok || !obj.exists()) {
            return compiled.output.replace(work.absolutePath + "/", "").ifBlank { "swift-frontend exited with ${compiled.exitCode}" }
        }
        // 2. wasm-ld: the reactor link.
        // lld picks its flavor from argv[0]; the executable is named
        // libwasm-ld.so, so the flavor is said outright.
        val linkArgs = mutableListOf(
            "wasm-ld", "-flavor", "wasm", "-m", "wasm32", "-L" + T(manifest.getString("resourceDir")) + "/wasi",
            "-L" + T(manifest.getString("sysroot")) + "/lib/wasm32-wasip1",
            T(manifest.getString("sysroot")) + "/lib/wasm32-wasip1/crt1-reactor.o", "--entry", "_initialize",
            obj.absolutePath, "--whole-archive",
        )
        val archives = manifest.getJSONArray("archives")
        for (i in 0 until archives.length()) linkArgs += T(archives.getString(i))
        linkArgs += "--no-whole-archive"
        // The hosts' entries exported and the rest dead-stripped, as isomer
        // ships its reactors (Foundation would otherwise be all there);
        // an SDK without the list exports everything.
        val exports = manifest.optJSONArray("exports")
        if (exports != null) {
            linkArgs += "--gc-sections"
            for (i in 0 until exports.length()) linkArgs += "--export-if-defined=" + exports.getString(i)
        } else {
            linkArgs += listOf("--export-all", "--no-gc-sections")
        }
        linkArgs += listOf(
            "-z", "stack-size=16777216",
            T(manifest.getString("resourceDir")) + "/wasi/wasm32/swiftrt.o",
            "-lswiftCore", "-lswiftSwiftOnoneSupport", "-lswiftWASILibc", "-lswift_Concurrency", "-lswift_RegexParser", "-lswift_StringProcessing",
            "-lswiftObservation", "-lswiftSynchronization",
            "-lc++", "-lc++abi", "-ldl", "-lm", "-lwasi-emulated-mman", "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks", "-lwasi-emulated-getpid",
            "--global-base=4096", "--table-base=4096", "-lc", T(manifest.getString("resourceDir")) + "/clang/lib/wasip1/libclang_rt.builtins-wasm32.a",
            "-o", wasm.absolutePath,
        )
        val linkStarted = android.os.SystemClock.uptimeMillis()
        val linked = run(toolchain.linker, linkArgs, mapOf("HOME" to work.absolutePath))
        android.util.Log.i("Playground", "[build] wasm-ld: ${android.os.SystemClock.uptimeMillis() - linkStarted}ms")
        if (!linked.ok || !wasm.exists()) {
            return linked.output.replace(work.absolutePath + "/", "").ifBlank { "wasm-ld exited with ${linked.exitCode}" }
        }
        // (The run's own window runs the module as it is, under Isomer's
        // wasm engine on Android, WasmKit's interpreter: nothing more to make
        // here.)
        lastBuild = wasm
        return ""
    }

    private class Outcome(val exitCode: Int, val output: String) { val ok get() = exitCode == 0 }

    /** Runs a toolchain executable with its libraries beside it; argv[0] is
     *  the program's name (what the frontend reads its own path from). */
    private fun run(executable: File, argv: List<String>, env: Map<String, String>): Outcome {
        val process = ProcessBuilder(listOf(executable.absolutePath) + argv.drop(1))
            .directory(work)
            .redirectErrorStream(true)
            .apply { environment().putAll(env); environment()["LD_LIBRARY_PATH"] = toolchain.libraryPath }
            .start()
        val output = process.inputStream.bufferedReader().readText()
        return Outcome(process.waitFor(), output)
    }

    // A run's home is not the project's yet: Android's WasmView gives a
    // guest none (its files are not kept).
    override suspend fun run(project: String): String {
        val wasm = lastBuild ?: throw IllegalStateException("nothing built yet")
        start(wasm, "")
        return "running"
    }

    /** The run's window (RunActivity, a process of its own) over [wasm]. */
    private fun start(wasm: File, environment: String) {
        Handler(Looper.getMainLooper()).post {
            PlaygroundRun.running = true
            context.startActivity(
                android.content.Intent(context, RunActivity::class.java)
                    .putExtra(RunActivity.EXTRA_WASM, wasm.absolutePath)
                    .putExtra(RunActivity.EXTRA_ENVIRONMENT, environment)
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    // The app compiles (with the toolchain staged), runs a reactor from a
    // URL, and carries the Gallery's (assets/gallery.wasm).
    override fun capabilities(): String = "projects,reactors,gallery-wasm"

    override suspend fun runReactor(url: String, project: String, environment: String): String = suspendCoroutine { cont ->
        thread(name = "playground-reactor") {
            try {
                val reactors = File(context.cacheDir, "reactors").apply { mkdirs() }
                val file = File(reactors, project.replace(Regex("[^A-Za-z0-9._-]"), "_") + ".wasm")
                if (url.startsWith("bundle:")) {
                    context.assets.open(url.removePrefix("bundle:")).use { input -> file.outputStream().use { input.copyTo(it) } }
                } else {
                    val connection = URL(url).openConnection() as HttpURLConnection
                    connection.connectTimeout = 20_000
                    connection.readTimeout = 120_000
                    connection.useCaches = false
                    if (connection.responseCode >= 300) throw IllegalStateException("$url: HTTP ${connection.responseCode}")
                    connection.inputStream.use { input -> file.outputStream().use { input.copyTo(it) } }
                }
                start(file, environment)
                cont.resume("running")
            } catch (e: Exception) {
                cont.resumeWithException(e)
            }
        }
    }

    override suspend fun signIn(): String = throw UnsupportedOperationException("paste a key in Settings")
    override fun rendererNames(): String = "Compose,OpenGL"
    override fun rendererFooter(): String = "Compose builds the app from Material components; OpenGL is the self-drawing SwiftGPU renderer. Applies the next time the app starts. A run is drawn with Compose."
    override fun appVersion(): String =
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""

    override fun stop() {
        Handler(Looper.getMainLooper()).post {
            PlaygroundRun.running = false
            // The run's process goes with its window.
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            for (process in manager.runningAppProcesses ?: emptyList()) {
                if (process.processName == context.packageName + ":run") android.os.Process.killProcess(process.pid)
            }
        }
    }

    override fun logs(): String = ""

    override fun canRunOnWeb(): Boolean = web.packaged

    override suspend fun runOnWeb(): String {
        val wasm = lastBuild ?: throw IllegalStateException("nothing built yet")
        val url = web.publish(wasm, File(context.filesDir, "sandbox/playground_run"))
        Handler(Looper.getMainLooper()).post { web.open(url) }
        return "opened $url"
    }

    override suspend fun chat(body: String): String = suspendCoroutine { cont ->
        val key = preferences.getString("openrouter-key", null)
        if (key.isNullOrEmpty()) { cont.resumeWithException(IllegalStateException("no OpenRouter key")); return@suspendCoroutine }
        thread(name = "playground-chat") {
            try {
                val connection = URL("https://openrouter.ai/api/v1/chat/completions").openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Authorization", "Bearer $key")
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setRequestProperty("HTTP-Referer", "https://github.com/AttilaTheFun/isomer")
                connection.setRequestProperty("X-Title", "Isomer Playground (Android)")
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                val stream = if (connection.responseCode < 400) connection.inputStream else connection.errorStream
                cont.resume(stream?.bufferedReader()?.readText() ?: "")
            } catch (e: Exception) {
                cont.resumeWithException(e)
            }
        }
    }

    override fun hasKey(): Boolean = !preferences.getString("openrouter-key", null).isNullOrEmpty()
    override fun setKey(key: String) {
        preferences.edit().apply { if (key.isEmpty()) remove("openrouter-key") else putString("openrouter-key", key) }.apply()
    }
    override fun toolchainStatus(): String = status
    override fun requestedTemplate(): String = ""

    /** The projects as the app kept them before 0.31 (its file service's
     *  sandbox: playground/<id>/App.swift, chat.json, projects.json), path ->
     *  base64, for the app's store to move once. Left in place. */
    override fun legacyFiles(): String {
        val sandbox = File(context.filesDir, "sandbox/playground")
        val files = JSONObject()
        File(sandbox, "playground").walkTopDown().filter { it.isFile }.forEach { file ->
            files.put(file.relativeTo(sandbox).invariantSeparatorsPath,
                android.util.Base64.encodeToString(file.readBytes(), android.util.Base64.NO_WRAP))
        }
        return files.toString()
    }

    // The app's renderer, which the generated MainActivity reads at launch
    // (SharedPreferences "isomer", "renderer").
    private val isomerPreferences = context.getSharedPreferences("isomer", Context.MODE_PRIVATE)
    override fun renderer(): String = if (isomerPreferences.getString("renderer", null) == "openGL") "gpu" else "native"
    override fun setRenderer(value: String) {
        isomerPreferences.edit().putString("renderer", if (value == "gpu") "openGL" else "jetpackCompose").apply()
    }

    // Driving the running build (the agent's ui_tree / tap / …) is not wired
    // on Android yet: the agent is told so.
    override fun uiTree(): String = "ui_tree is not available on Android yet"
    override suspend fun tap(target: String): String = "tap is not available on Android yet"
    override suspend fun typeText(target: String, text: String): String = "type_text is not available on Android yet"
    override suspend fun submit(target: String): String = "submit is not available on Android yet"
    override suspend fun swipe(target: String, dx: Double, dy: Double): String = "swipe is not available on Android yet"
}

/** The editor sheet's code editor: a monospaced text field over the file. */
@Composable
private fun CodeEditorView(node: JSONObject, modifier: Modifier, edit: String) {
    // The sheet loads the file after the editor first appears, so the value
    // arrives in a later tree: follow it whenever it differs from the last
    // one seen (what is typed here is reported and comes back the same).
    val incoming = node.optString("v")
    var seen by remember(edit) { mutableStateOf(incoming) }
    var text by remember(edit) { mutableStateOf(incoming) }
    if (incoming != seen) { seen = incoming; text = incoming }
    BasicTextField(
        value = text,
        onValueChange = { text = it; AppHostViews.report(edit, it) },
        textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface),
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp),
    )
}

/** The run cover's surface: the build is in its own window (RunActivity);
 *  this reports "stopped" once that window has closed, so the cover follows. */
@Composable
private fun RunSurfaceView(modifier: Modifier, edit: String) {
    val running = PlaygroundRun.running
    androidx.compose.runtime.LaunchedEffect(running) {
        if (!running) AppHostViews.report(edit, "stopped")
    }
    Text(if (running) "Running in its own window…" else "Stopped", modifier = modifier.padding(24.dp))
}
