// A page that serves an Isomer app's session (docs/modes.md: web-view mode):
// the app's Swift runs here, as wasm, by the page's own engine (its JIT),
// and a head elsewhere draws it, exactly as a remote head draws an app built
// headless on a server (headless/libraries/swift_ui/RemoteSession.swift is
// this file's peer). The head is usually the native app that owns the page:
// Apple's tree renderer in a WKWebView's app (apple/libraries/webview_head).
//
//   const host = createSessionHost({ send: (bytes) => channel.post(bytes) });
//   channel.onMessage = (bytes) => host.receive(bytes);
//
// Only the session crosses: each ClientMessage in (start, resize, events,
// keys, appearance, scale, scene phase, URLs, back) is the guest's own
// export called, as boot.js calls them for a page's own input; out go
// ServerMessages: each frame as a tree.proto Patch (the guest's renderer is
// the head's, bound by name: "swiftui", "compose" or "dom"), the pictures
// the guest makes, its platform commands, the URLs it opens and its own
// appearance. Everything else stays in the page, synchronous with the
// guest: text is measured by the page's canvas, files are the page's
// (IndexedDB), networking its fetch. The page draws nothing.
//
// The guest starts with the session's `start`: its size, scale, appearance
// and launch environment (the ISO_ variables a native host's process has).
// One session a page: a head that reconnects loads the page again, a new
// guest. The messages are session_messages.js's.

import { Dependencies, load } from "../app_bridge.js";
import { appFilesKey, openAppFiles } from "./file_system.js";
import { loadBundledFonts } from "./fonts.js";
import { browserNetworkHosts } from "./network.js";
import { createRasterHost } from "./raster.js";
import { readClientMessage, serverMessage } from "./session_messages.js";

const SCENE_PHASES = ["active", "inactive", "background"];

export function createSessionHost({
  // The guest: its reactor's URL, or its bytes (a BundleProvider's).
  wasmURL = "./app.wasm",
  bundle = undefined,
  // Each ServerMessage's bytes, in order, to the head.
  send,
  // The session ended on the page's side (the guest failed to load or
  // trapped): its error.
  onEnd = () => {},
  // As boot()'s: the page's own swift_ffi dependencies, its networking's
  // `fetch` and `WebSocket`, WASI overrides, and the app's identity on this
  // origin (its files are kept under it; Bundle.main's values).
  dependencies = {},
  fetch: pageFetch = undefined,
  WebSocket: PageWebSocket = undefined,
  wasi = undefined,
  bundleIdentifier = undefined,
  bundleName = undefined,
  bundleVersion = undefined,
  bundleBuild = undefined,
  // `Font.custom`'s fonts (isomer_web_app's fonts/), for measuring text.
  fonts = "./fonts/",
  // Keep the reactor's response in the page's Cache Storage and compile it
  // from there (compileModule below): where the engine keeps the compiled
  // code beside a cached response (Chrome's V8, Android's WebView), the next
  // launch skips most of the compile.
  cacheReactor = true,
} = {}) {
  const post = (bytes) => {
    try {
      send(bytes);
    } catch (error) {
      console.warn("[session] the head's channel refused a message:", error);
    }
  };
  // The guest's files and fonts, opened while the session starts.
  const filesOpening = openAppFiles(appFilesKey(bundleIdentifier, bundle ? undefined : wasmURL));
  const fontsLoading = fonts ? loadBundledFonts(fonts) : null;
  // Text measured as the page draws it (a canvas of its own); images are
  // the head's to load, so the guest finds every one ready, as under the DOM
  // renderer.
  const raster = typeof OffscreenCanvas === "undefined" ? null : createRasterHost({ scale: 1 });

  let bridge = null;
  let started = false;
  let ended = false;
  // What the head said before the guest was up: applied once it is, in order.
  const early = [];

  // The guest's frames: one when it asks, an animation frame's time later,
  // or at once after the head's input (`renderIfNeeded`), as RemoteSession
  // answers. A timer stands in where the page gets no animation frames (a
  // web view WebKit counts as hidden).
  let frame = 0;
  let timer = 0;
  function render() {
    cancelAnimationFrame(frame);
    clearTimeout(timer);
    frame = timer = 0;
    if (ended) return;
    try {
      bridge.isoRender();
    } catch (error) {
      end(error);
    }
  }
  function scheduleRender() {
    if (frame || timer) return;
    frame = requestAnimationFrame(render);
    timer = setTimeout(render, 100);
  }
  function renderIfNeeded() {
    if (frame || timer) render();
  }

  function end(error) {
    if (ended) return;
    ended = true;
    console.error("[session] ended:", error);
    onEnd(error);
  }

  // How long the guest took to come up (logged once its first frame is out).
  const timing = { begun: 0, compiled: 0, loaded: 0, source: "" };
  let firstFrame = true;

  // The Swift `WebHost` protocol (wasm/libraries/swift_ui/WebBridge.swift),
  // its drawing half the head's: the tree goes out as the session's patches.
  const host = {
    measureText(text, fontSize, weight, wrapWidth) {
      if (!raster) return { width: text.length * fontSize * 0.6, height: fontSize * 1.3 };
      return raster.measureText(text, fontSize, weight, wrapWidth < 0 ? null : wrapWidth);
    },
    imageInfo() { return { state: 1, width: 0, height: 0 }; },
    syncHostViews() {},
    rasterize() { return new Uint8Array(0); },
    beginTextInput(text, x, y, width, height, fontSize) {
      post(serverMessage.textInput({ text, x, y, width, height, fontSize }));
    },
    endTextInput() { post(serverMessage.endTextInput()); },
    scheduleRender,
    setColorScheme(dark) { post(serverMessage.dark(dark)); },
    now() { return performance.now() / 1000; },
    log(message) {
      console.log("[swiftui]", message);
      post(serverMessage.log(message));
    },
    openURL(url) { post(serverMessage.openURL(url)); },
    platformCommand(key, value) { post(serverMessage.command(key, value)); },
    epochMillis() { return Date.now(); },
    registerImage(source, bytes) { post(serverMessage.image(source, bytes)); },
    renderTree(tree) {
      post(serverMessage.patch(tree));
      if (firstFrame) {
        firstFrame = false;
        const ms = (to, from) => Math.round(to - from);
        // To the head, which logs it (logcat, the app's standard output).
        post(serverMessage.log(`[session] the app's first frame ${ms(performance.now(), timing.begun)} ms after its start ` +
          `(the reactor compiled in ${ms(timing.compiled, timing.begun)} ms from ${timing.source}, ` +
          `its files and instance ${ms(timing.loaded, timing.compiled)} ms, ` +
          `its first frame ${ms(performance.now(), timing.loaded)} ms; the page ${ms(timing.begun, 0)} ms old at the start)`));
      }
    },
  };

  async function begin(start) {
    timing.begun = performance.now();
    let module;
    if (bundle) {
      module = await WebAssembly.compile(bundle.wasm ?? bundle);
      timing.source = "bytes";
    } else {
      const compiled = await compileModule(wasmURL, cacheReactor);
      module = compiled.module;
      timing.source = compiled.source;
    }
    timing.compiled = performance.now();
    const files = await filesOpening;
    await fontsLoading;
    // The head's launch environment (its ISO_ variables only, as a server
    // passes on) and the app's identity.
    const launch = Object.fromEntries(Object.entries(start.environment).filter(([key]) => key.startsWith("ISO_")));
    const bundleInfo = { ISOMER_BUNDLE_IDENTIFIER: bundleIdentifier, ISOMER_BUNDLE_NAME: bundleName,
                         ISOMER_BUNDLE_SHORT_VERSION: bundleVersion, ISOMER_BUNDLE_VERSION: bundleBuild };
    const environment = { ...launch, ...Object.fromEntries(Object.entries(bundleInfo).filter(([, value]) => value)) };
    const wasiWithFiles = (getMemory, builtins) => ({
      ...files.wasi(getMemory, builtins, { environment }),
      ...(typeof wasi === "function" ? wasi(getMemory, builtins) : (wasi || {})),
    });
    bridge = await load(module, {
      dependencies: { ...browserNetworkHosts(Dependencies, { fetch: pageFetch, WebSocket: PageWebSocket }), ...dependencies },
      wasi: wasiWithFiles,
    });
    timing.loaded = performance.now();
    // As RemoteSession.begin: the head's scale and appearance, then the
    // guest started at the head's size under the head's renderer. Its first
    // frame is the whole tree.
    if (start.displayScale > 0) bridge.isoSetDisplayScale(start.displayScale);
    bridge.isoSetColorScheme(start.dark);
    bridge.isoStart(host, start.renderer || "dom", start.width || 1, start.height || 1);
    for (const message of early.splice(0)) apply(message);
    scheduleRender();
  }

  // One of the head's messages, as RemoteSession.receive maps it onto the
  // runtime: here, through the guest's exports.
  function apply(message) {
    if (message.resize) bridge.isoResize(message.resize.width, message.resize.height);
    else if (message.event) bridge.isoHostEvent(message.event.id, message.event.value);
    // The answer (whether a handler took the key) comes too late for the
    // head to keep the key from its field: it lets every key through.
    else if (message.key) bridge.isoKeyEvent(message.key.id, message.key.value);
    else if (message.pointer) bridge.isoPointerEvent(message.pointer.phase, message.pointer.x, message.pointer.y);
    else if (message.wheel) bridge.isoWheelEvent(message.wheel.x, message.wheel.y, message.wheel.deltaX, message.wheel.deltaY);
    else if (message.text) {
      if (message.text.change === 1) bridge.isoTextSubmitted();
      else if (message.text.change === 2) bridge.isoTextEnded();
      else bridge.isoTextChanged(message.text.text);
    } else if (message.dark !== undefined) bridge.isoSetColorScheme(message.dark);
    else if (message.displayScale !== undefined) bridge.isoSetDisplayScale(message.displayScale);
    else if (message.scenePhase !== undefined) bridge.isoSetScenePhase(SCENE_PHASES[message.scenePhase] ?? "active");
    else if (message.openURL !== undefined) bridge.isoOpenURL(message.openURL);
    else if (message.back) bridge.isoBack();
    // What the message changed renders in the frame the guest asked for;
    // a frame now answers the person sooner.
    renderIfNeeded();
  }

  return {
    // One ClientMessage's bytes from the head.
    receive(bytes) {
      if (ended) return;
      const message = readClientMessage(bytes);
      if (message.start) {
        // A session's first message, once: the guest runs once a page.
        if (started) return;
        started = true;
        begin(message.start).catch(end);
        return;
      }
      if (!bridge) {
        early.push(message);
        return;
      }
      try {
        apply(message);
      } catch (error) {
        end(error);
      }
    },
    // The guest's exports, once it is up (tests).
    get bridge() { return bridge; },
  };
}

// The reactor compiled as it downloads, where the scheme serves it as wasm
// (application/wasm); whole otherwise (a scheme handler that names no type).
//
// With `cache`, the response comes from the page's Cache Storage
// ("isomer-reactor", keyed by the reactor's URL, its `?v=` stamp the site's
// version; the first launch puts it there, and drops a version before it):
// Chrome's V8 keeps the code it compiled for a module streamed from a cached
// response (128 kB or more) beside it, and takes it from there the next time
// instead of compiling again. Where Cache Storage isn't (a page that isn't
// a secure context) or fails, the network's response as before.
async function compileModule(url, cache) {
  const { response, source } = cache ? await cachedResponse(url) : { response: fetch(url), source: "the network" };
  try {
    return { module: await WebAssembly.compileStreaming(response), source };
  } catch (error) {
    if (!(error instanceof TypeError)) throw error;
    return { module: await WebAssembly.compile(await (await fetch(url)).arrayBuffer()), source: "the network, whole" };
  }
}

const REACTOR_CACHE = "isomer-reactor";

async function cachedResponse(url) {
  if (typeof caches === "undefined" || !globalThis.isSecureContext) return { response: fetch(url), source: "the network" };
  try {
    const key = new URL(url, location.href).href;
    const cache = await caches.open(REACTOR_CACHE);
    const hit = await cache.match(key);
    if (hit) return { response: hit, source: "Cache Storage" };
    const fetched = await fetch(key);
    if (!fetched.ok) return { response: fetched, source: "the network" };
    await cache.put(key, fetched);
    for (const request of await cache.keys()) {
      if (request.url !== key) await cache.delete(request);
    }
    const stored = await cache.match(key);
    return stored ? { response: stored, source: "the network, into Cache Storage" } : { response: fetch(key), source: "the network" };
  } catch (error) {
    console.warn("[session] the reactor's cache:", error);
    return { response: fetch(url), source: "the network" };
  }
}
