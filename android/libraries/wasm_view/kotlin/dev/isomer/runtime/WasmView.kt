package dev.isomer.runtime

// The Android peer of Apple's `WasmView` and the web's `<Isomer>`: a
// Jetpack Compose @Composable that embeds one *wasm feature bundle* in an
// existing Compose hierarchy. Where `Isomer()` (//android/libraries/
// swift_ui) runs the app's UI compiled directly to Android (compiled Swift),
// `WasmView` runs a downloadable/hot-reloadable wasm reactor in-process under
// the **WAMR** interpreter (`WamrRuntime`) — a C engine, so the app carries
// NO compiled Swift. It renders the tree the reactor emits with the SAME
// Swift-free Compose interpreter (IsoNode) the native path uses.
//
// The reactor's render tree is the tree.fbs the native path also emits, so the
// only wasm-specific glue is (1) launching the reactor with a bundle's bytes
// and (2) routing node events back to the reactor via `WamrRuntime.event`
// (IsoEventRouter). Feature-flag / analytics DI is answered natively through
// the `WamrHost` callbacks (the swift_ffi dependency transport).

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive

/**
 * Embed a wasm feature. [provider] supplies the initial bundle (a packaged
 * asset) and any newer bundles (a dev hot-reload shadow / dynamic delivery);
 * [ffiPrefix] + [dependencies] are the APP's swift_ffi dependency table
 * (opaque to this view — keys, ordinals, and blob dispatchers belong to the
 * app), injected into the feature's `dependencies` dictionary. With them
 * goes Foundation's networking (WasmNetworkHosts: URLSession's HTTP and
 * WebSockets on Android's), unless the app injects its own under those keys.
 */
@Composable
fun WasmView(
    provider: WasmBundleProvider,
    modifier: Modifier = Modifier,
    ffiPrefix: String? = null,
    dependencies: List<WasmDependency> = emptyList(),
    // Init-threading A/B (benchmark): move the reactor instantiate + first
    // render off the main thread (see the threading note below — create-off-
    // main / drive-on-main is safe; Compose snapshot state accepts writes
    // from any thread). Default stays the simple all-on-main model.
    offMainInit: Boolean = false,
    // The engine seam (Apple's WasmRuntimeRegistry, as a parameter): default
    // WAMR; an app may pass a factory of its own.
    engineFactory: (ByteArray, WamrHost, String?, List<WasmDependency>) -> WasmEngine =
        { w, h, prefix, deps -> WamrRuntime(w, h, prefix, deps) },
) {
    val context = LocalContext.current
    val density = LocalDensity.current.density
    val darkTheme = androidx.compose.foundation.isSystemInDarkTheme()
    var size by remember { mutableStateOf(0 to 0) }

    // The pure-Kotlin host services (image cache, scale) the interpreter reads.
    HostServices.appContext = context.applicationContext
    HostServices.density = density
    // The app's directories in the environment, as the compiled delivery
    // has them (the reactor's /tmp is a folder of TMPDIR's).
    remember { AppDirectories.prepare(context) }

    // Interpreting wasm in-process is synchronous — no async main-thread hop like
    // the web's JS — so all Compose<->wasm interaction (render, event, resize)
    // runs on the MAIN thread: the tree callback writes Compose state and events
    // call straight into the reactor, no marshaling. The one heavy, one-time cost
    // is instantiating the reactor (WAMR load + `_initialize` + first render).
    // On a 2018 Pixel 3a that's ~0.8s, fast enough to run inline on the main
    // thread, which keeps the model dead simple (one thread, no handoff). A
    // consumer that wants to hide even that latency can wrap the WamrRuntime
    // construction in withContext(Dispatchers.Default): the runtime is only ever
    // driven on the main thread afterward, and WAMR re-binds its exec_env to the
    // calling thread on every call, so the create-off-main / drive-on-main
    // handoff is safe (there is never concurrent access either way).
    val holder = remember { object { var runtime: WasmEngine? = null } }
    val mainHandler = remember { android.os.Handler(android.os.Looper.getMainLooper()) }
    // Foundation's networking (WasmNetworkHosts) joins the app's table for a
    // reactor with the swift_ffi transport (an `ffiPrefix`); an app's own
    // entry under one of its keys stands instead.
    val injected = remember {
        if (ffiPrefix == null) dependencies
        else dependencies + WasmNetworkHosts.dependencies(mainHandler).filter { host ->
            dependencies.none { it.key == host.key }
        }
    }
    // Runs the guest's queued jobs, then comes back when its next timed job
    // (`Task.sleep`) is due; one pending wake at a time.
    val jobsWake = remember { Any() }
    fun drainJobs() {
        val runtime = holder.runtime as? WamrRuntime ?: return
        runtime.runJobs()
        mainHandler.removeCallbacksAndMessages(jobsWake)
        val wait = runtime.nextJobDelayMs()
        if (wait >= 0) mainHandler.postAtTime({ drainJobs() }, jobsWake, android.os.SystemClock.uptimeMillis() + wait)
    }
    val host = remember {
        object : WamrHost {
            override fun renderTree(tree: ByteArray) {
                // The reactor ships diff `Patch`es — the only wire format;
                // apply to the retained UNode tree so only changed views
                // recompose (the first patch is a full root op).
                val t0 = if (WasmPerf.on) System.nanoTime() else 0L
                ComposeTreeState.applyPatch(tree)
                if (WasmPerf.on) WasmPerf.patch(System.nanoTime() - t0, tree.size)
            }
            // The guest's "render again soon" (an animation's next frame, a
            // change made outside an event): ONE render at the next display
            // frame, however many times it asks before then. Posted as plain
            // messages these ran back to back — an animating reactor asks
            // again from inside each render — three or four renders to a
            // displayed frame on a slow phone, each holding the main thread
            // the frame itself was waiting for.
            override fun scheduleRender() {
                if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) renderNextFrame()
                else mainHandler.post { renderNextFrame() }
            }
            private var framePosted = false
            private fun renderNextFrame() {
                if (framePosted) return
                framePosted = true
                android.view.Choreographer.getInstance().postFrameCallback {
                    framePosted = false
                    val t0 = if (WasmPerf.on) System.nanoTime() else 0L
                    holder.runtime?.render()
                    if (WasmPerf.on) WasmPerf.call("render", System.nanoTime() - t0)
                }
            }
            override fun log(message: String) {
                android.util.Log.i("Isomer", "[wasm] $message")
            }
            override fun dispatchDependency(index: Int, args: ByteArray): ByteArray =
                injected.getOrNull(index)?.dispatch?.invoke(holder.runtime, args) ?: ByteArray(0)
            override fun scheduleJobs() {
                mainHandler.post { drainJobs() }
            }
        }
    }

    // System appearance: forward dark-mode toggles into the running reactor
    // (the initial value rides the launch below).
    androidx.compose.runtime.LaunchedEffect(darkTheme) {
        holder.runtime?.setColorScheme(darkTheme)
    }

    // Node events go straight to THIS reactor on the main thread while alive.
    DisposableEffect(Unit) {
        val previous = IsoEventRouter.sink
        IsoEventRouter.sink = { id, value ->
            val t0 = if (WasmPerf.on) System.nanoTime() else 0L
            holder.runtime?.event(id, value)
            if (WasmPerf.on) WasmPerf.call("event", System.nanoTime() - t0)
        }
        onDispose {
            IsoEventRouter.sink = previous
            holder.runtime?.destroy()
            holder.runtime = null
        }
    }

    // A live resize: re-lay-out the running reactor. (One still starting is
    // given the size it finds when it is up.)
    LaunchedEffect(size) {
        val (w, h) = size
        if (w != 0 && h != 0) holder.runtime?.resize(w / density.toDouble(), h / density.toDouble())
    }

    // Launch once a size is known; relaunch as newer bundles arrive. ONE job
    // for the view's life owns launching: a reactor is replaced and destroyed
    // on the main thread only, between launches, so nothing on the main
    // thread (an event, a render) ever reaches an instance another thread is
    // tearing down — which a relaunch on every size change did, once
    // start-up could run off the main thread.
    val currentDark by androidx.compose.runtime.rememberUpdatedState(darkTheme)
    LaunchedEffect(Unit) {
        androidx.compose.runtime.snapshotFlow { size }.first { it.first != 0 && it.second != 0 }

        // Instantiate + first render. The [wasm-init] logs bracket the whole
        // create+start so it's visible in adb.
        fun create(wasm: ByteArray, widthPt: Double, heightPt: Double): WasmEngine? {
            val t0 = android.os.SystemClock.uptimeMillis()
            android.util.Log.i(
                "Isomer", "[wasm-init] start — ${wasm.size} bytes (offMain=$offMainInit)")
            val created = try {
                engineFactory(wasm, host, ffiPrefix, injected).also {
                    it.start(widthPt, heightPt)
                    it.setColorScheme(currentDark)
                }
            } catch (e: Throwable) {
                android.util.Log.e("Isomer", "wasm reactor failed to start", e)
                null
            }
            val ms = android.os.SystemClock.uptimeMillis() - t0
            android.util.Log.i("Isomer", "[wasm-init] done in ${ms}ms")
            return created
        }

        // On the main thread by default (see the note above); on
        // Dispatchers.Default when [offMainInit]. Off the main thread the
        // reactor is created and started there and handed over here; it is
        // only driven from main afterward.
        suspend fun launch(wasm: ByteArray) {
            holder.runtime?.destroy()
            holder.runtime = null
            // Fresh reactor => fresh diff state; drop the retained tree so the
            // first patch (a root op carrying the whole tree) rebuilds it.
            ComposeTreeState.clear()
            val started = size
            val widthPt = started.first / density.toDouble()
            val heightPt = started.second / density.toDouble()
            // Not cancellable: a reactor made while the view was leaving is
            // destroyed below rather than leaked.
            val elsewhere = kotlinx.coroutines.NonCancellable
            val created = if (offMainInit) {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default + elsewhere) {
                    create(wasm, widthPt, heightPt)
                }
            } else {
                create(wasm, widthPt, heightPt)
            }
            if (!kotlinx.coroutines.currentCoroutineContext().isActive) {
                created?.destroy()
                throw kotlinx.coroutines.CancellationException("the view left while its reactor started")
            }
            holder.runtime = created
            if (created == null) return
            // What happened while it started elsewhere: the view resized, and
            // the guest asked for frames this thread had no reactor to give.
            val now = size
            if (now != started && now.first != 0 && now.second != 0) {
                created.resize(now.first / density.toDouble(), now.second / density.toDouble())
            } else {
                created.render()
            }
            // Jobs the guest queued while starting (an `.onAppear` Task, a
            // `.task {}` body) were scheduled before `holder.runtime` existed;
            // the C host only signals the empty->non-empty transition, so drain
            // them now or they never run.
            mainHandler.post { drainJobs() }
        }
        provider.initialBundle()?.let { bundle -> launch(bundle.wasm) }
        provider.bundleUpdates().collect { bundle -> launch(bundle.wasm) }
    }

    Box(modifier.fillMaxSize().onSizeChanged { size = it.width to it.height }) {
        val root = ComposeTreeState.tree.value
        // The system's appearance, as the guest is told it (setColorScheme
        // above): dark text on light, or light on dark — never one of each.
        // Grounds as iOS's: white or black, grouped greys for sidebars.
        val scheme = if (darkTheme) darkColorScheme(background = androidx.compose.ui.graphics.Color.Black, surface = androidx.compose.ui.graphics.Color.Black,
                surfaceVariant = androidx.compose.ui.graphics.Color(0xFF1C1C1E))
            else lightColorScheme(background = androidx.compose.ui.graphics.Color.White, surface = androidx.compose.ui.graphics.Color.White,
                surfaceVariant = androidx.compose.ui.graphics.Color(0xFFF2F2F7))
        MaterialTheme(colorScheme = scheme) {
            Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                if (root != null) IsoRoot(root)
            }
        }
    }
}


/** Where a wasm-driven frame's main-thread time goes, logged once a second
 *  while `adb shell setprop debug.isomer.wasm.perf 1` is set (read once):
 *  each event and each scheduled render the host makes into the reactor —
 *  the guest's work, the patch it sends back included — and, within those,
 *  applying the patch to the Compose tree. */
internal object WasmPerf {
    val on: Boolean by lazy {
        try {
            (Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                .invoke(null, "debug.isomer.wasm.perf") as? String) == "1"
        } catch (e: Throwable) { false }
    }
    private var events = 0; private var eventNs = 0L
    private var renders = 0; private var renderNs = 0L
    private var patches = 0; private var patchNs = 0L; private var patchBytes = 0L
    private var since = 0L

    fun patch(ns: Long, bytes: Int) { patches++; patchNs += ns; patchBytes += bytes }

    fun call(kind: String, ns: Long) {
        if (kind == "event") { events++; eventNs += ns } else { renders++; renderNs += ns }
        val now = android.os.SystemClock.uptimeMillis()
        if (since == 0L) since = now
        if (now - since < 1000) return
        fun ms(total: Long, n: Int) = if (n == 0) "-" else String.format("%.1f", total / 1e6 / n)
        android.util.Log.i("Isomer", "[wasm-perf] events $events avg ${ms(eventNs, events)}ms; renders $renders avg ${ms(renderNs, renders)}ms; " +
            "of which patches $patches avg ${ms(patchNs, patches)}ms, ${if (patches == 0) 0 else patchBytes / patches}B")
        events = 0; eventNs = 0; renders = 0; renderNs = 0; patches = 0; patchNs = 0; patchBytes = 0; since = now
    }
}
