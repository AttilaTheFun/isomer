// Boots a Isomer wasm application through the swift_ffi bindings:
// `load()` instantiates the reactor (WASI shim included), a plain object
// implements the Swift `WebHost` protocol, and the exported functions drive
// the runtime. Strings and structs copy at the boundary, so there is no
// pointer/length or staging-buffer plumbing here.

import { appFilesKey, openAppFiles } from "./file_system.js";
import { Dependencies, load } from "../app_bridge.js";
import { browserNetworkHosts } from "./network.js";
import { createRasterHost, registerImageBytes } from "./raster.js";
import { createReactTreeRenderer } from "./react_renderer.js";
import { applyPatch } from "./flat_tree.js";

// `rendererName` picks the renderer (docs/renderer_layers.md): "webGPU"
// (default) binds the self-drawing SwiftGPURenderer; "react" binds the
// ReactRenderer, which mounts the serialized view tree as React components
// and owns layout itself.
// The page's clipboard, written during the tap that asked for it.
function copyText(text) {
  const fallback = () => {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.cssText = "position:fixed;top:0;left:0;opacity:0;pointer-events:none;font-size:16px";
    document.body.appendChild(area);
    area.select();
    try { document.execCommand("copy"); } catch (err) { console.warn("[clipboard] copy failed", err); }
    area.remove();
  };
  if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).catch(fallback);
  else fallback();
}

export async function boot({
  canvas, wasmURL, bundle, rendererName = "webGPU", embedded = false,
  // Host-side swift_ffi dependency injection (docs/wasm_di.md): entries built
  // with the generated `Dependencies` builders, keyed by dictionary key. The
  // page owns every app-specific service; boot() passes the table to load()
  // beside Foundation's networking (network.js, under `isomerHTTP` and
  // `isomerWebSocket`, which a page's own entries replace). Async
  // completions call back through the app's own exports on the returned
  // bridge.
  dependencies = {},
  // What Foundation's networking sends through: the browser's `fetch` and
  // `WebSocket` unless the page gives its own (the same signatures), as a
  // page does that routes requests through its server. (Renamed here: a
  // parameter named `fetch` would hide the global the reactor loads with.)
  fetch: pageFetch = undefined,
  WebSocket: PageWebSocket = undefined,
  // WASI shim overrides, merged over the built-ins and the app's file
  // system (extend or replace individual calls — clocks, fds, … — without
  // forking the runtime); a function gets the memory accessor and the
  // built-ins.
  wasi = undefined,
  // The app's identity on this origin, as an Apple app's bundle identifier:
  // its files (file_system.js) are kept under it, and the guest's
  // `Bundle.main.bundleIdentifier` is it. Without one, the files are kept
  // under the reactor's URL.
  bundleIdentifier = undefined,
  // Document scrolling on a phone-width page (react only): the screen's
  // scroll is the page's own, its bars fixed over it (react_renderer.js).
  // Also `?scroll=document` in the page's URL.
  documentScroll = new URLSearchParams(location.search).get("scroll") === "document",
} = {}) {
  const react = rendererName === "react";
  // The app's files, read from IndexedDB while the rest starts: the reactor
  // finds them from its first instruction.
  const filesOpening = openAppFiles(appFilesKey(bundleIdentifier, bundle ? undefined : wasmURL));
  // SwiftGPURenderer: Swift draws through Isomer's Metal, whose executor
  // runs it on WebGPU; this page supplies measurement + rasterization.
  let gpuHost = null;
  let raster = null;
  if (!react) {
    // Imported lazily: the ReactRenderer path never touches WebGPU, and a
    // static import would put the Metal executor on EVERY page's critical
    // module graph (an unresolved ES module import evaluates NOTHING —
    // rendering as a silent blank page when the file isn't served).
    const { createIsomerMetalHost } = await import("./isomer_metal_webgpu.js");
    gpuHost = await createIsomerMetalHost(canvas);
    raster = createRasterHost({
      scale: window.devicePixelRatio || 1,
      invalidate: () => scheduleRender(),
    });
  }

  let bridge = null;
  let reactTree = null;
  // The retained render tree; each renderTree() buffer is a Patch against it.
  let retainedTree = null;
  let treeContainer = null;
  let mapSurface = null;
  let metalViews = null;
  // The page's one Metal executor (surface 1 is the page canvas, which the
  // GPU renderer or a React-path map draws into), made on first use and
  // connected to the app.
  let metalHostStarting = null;
  async function ensureMetalHost() {
    if (gpuHost) return gpuHost;
    metalHostStarting ??= (async () => {
      const { createIsomerMetalHost } = await import("./isomer_metal_webgpu.js");
      gpuHost = await createIsomerMetalHost(canvas);
      gpuHost.connect(bridge);
      bridge.isoSetDisplayScale(window.devicePixelRatio || 1);
      return gpuHost;
    })();
    return metalHostStarting;
  }
  if (react) {
    // React owns the surface: mount a root container where the canvas was.
    treeContainer = document.createElement("div");
    treeContainer.style.cssText =
      "position:absolute;inset:0;overflow:hidden;display:flex;flex-direction:column";
    canvas.style.display = "none";
    (canvas.parentElement || document.body).appendChild(treeContainer);
    // A phone's soft keyboard shrinks the visual viewport, and Safari then
    // scrolls the page to show the focused field, carrying the pinned bars
    // off the top. Size the surface to the visual viewport instead, so the
    // bars stay and only the content between them shrinks (the iOS shape).
    if (window.visualViewport && canvas.parentElement === document.body) {
      const viewport = window.visualViewport;
      // The surface follows the keyboard both ways with the same easing
      // (Safari animates the viewport in, not out), and the home-indicator
      // inset is dropped while the keyboard covers it — nothing but the
      // page's background sits between the composer and the keys.
      treeContainer.style.transition = "height 0.25s ease-out, top 0.25s ease-out";
      // The surface keeps running on under the keyboard: its content lays
      // out above the keys (the keyboard's height is bottom padding), and a
      // bottom `.safeAreaInset` reaches down into that padding, so what
      // scrolls under the composer carries on behind the keyboard, as on
      // an iPhone, instead of the page's plain ground.
      treeContainer.style.boxSizing = "border-box";
      // A Home Screen web app that draws under the status bar is told a
      // viewport short by the status bar's height (iOS 26: innerHeight 812
      // on an 874pt screen, leaving a blank strip at the bottom); the large
      // viewport unit still measures the whole screen.
      const screenProbe = document.createElement("div");
      screenProbe.style.cssText = "position:absolute;top:0;left:0;width:0;height:100lvh;visibility:hidden;pointer-events:none";
      document.body.appendChild(screenProbe);
      const pageHeight = () => navigator.standalone === true
        ? Math.max(window.innerHeight, Math.round(screenProbe.getBoundingClientRect().height))
        : window.innerHeight;
      // The page's height with no keyboard: the keyboard is measured
      // against it, not against innerHeight, which on an iPhone shrinks
      // with the visual viewport when the keyboard comes up (the simulator's
      // doesn't) — measured that way the keyboard came out as nothing, and
      // the composer stayed behind it.
      const editing = () => {
        const active = document.activeElement;
        return !!active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable);
      };
      let restHeight = pageHeight();
      // Document scrolling (documentScroll) holds only while the page is
      // phone-width, as the renderer's own test (isDesktop) has it: a wide
      // page keeps the fixed, clipped surface its desktop layout needs.
      // The mode follows the window across that line.
      let inDocument = null;
      const surface = treeContainer.style.cssText;
      const applyMode = () => {
        const next = documentScroll && window.innerWidth < 700;
        if (next === inDocument) return;
        inDocument = next;
        document.documentElement.classList.toggle("iso-document", next);
        if (next) {
          // The surface runs on as tall as its content (the page scrolls,
          // not the surface); its chrome is fixed or sticky, so the browser
          // itself keeps a focused field above the keyboard.
          treeContainer.style.cssText = "position:absolute;left:0;right:0;top:0;overflow:visible;display:flex;flex-direction:column;min-height:100%";
          treeContainer.dataset.isoDocument = "1";
        } else {
          treeContainer.style.cssText = surface;
          treeContainer.style.transition = "height 0.25s ease-out, top 0.25s ease-out";
          treeContainer.style.boxSizing = "border-box";
          delete treeContainer.dataset.isoDocument;
        }
        fit();
      };
      const fit = () => {
        if (inDocument) {
          // Only the home indicator's inset, dropped while a field is focused.
          treeContainer.style.setProperty("--iso-safe-bottom", editing() ? "0px" : "env(safe-area-inset-bottom, 0px)");
          return;
        }
        if (!editing()) restHeight = pageHeight();
        const keyboard = Math.max(0, Math.round(restHeight - viewport.height - viewport.offsetTop));
        const keyboardUp = editing() && keyboard > 120;
        const lift = keyboardUp ? keyboard : 0;
        const full = keyboardUp ? Math.round(viewport.height) : Math.max(Math.round(viewport.height), pageHeight());
        treeContainer.style.top = `${Math.max(0, viewport.offsetTop)}px`;
        treeContainer.style.height = `${full + lift}px`;
        treeContainer.style.bottom = "auto";
        treeContainer.style.paddingBottom = `${lift}px`;
        treeContainer.style.setProperty("--iso-keyboard", `${lift}px`);
        treeContainer.style.setProperty("--iso-safe-bottom", keyboardUp ? "0px" : "env(safe-area-inset-bottom, 0px)");
        if (window.scrollY) window.scrollTo(0, 0);
      };
      viewport.addEventListener("resize", fit);
      viewport.addEventListener("scroll", fit);
      // A field gaining or losing focus changes what the viewport means.
      document.addEventListener("focusin", () => setTimeout(fit, 0));
      document.addEventListener("focusout", () => setTimeout(fit, 0));
      window.addEventListener("resize", applyMode);
      applyMode();
      // The page runs the whole screen too, so nothing clips the surface
      // at the short viewport's edge.
      if (navigator.standalone === true) {
        document.documentElement.style.height = "100lvh";
        document.body.style.height = "100lvh";
      }
      fit();
    }
    // React-path `Map` host views: the wasm module draws real SwiftMap tiles
    // (when swift_map is linked, `--config=map`) into the page canvas through
    // swift_gpu's WebGPU executor; the canvas is parked INSIDE the map
    // element so later ZStack layers (the map's DOM controls) stack above
    // it. One live map surface at a time — matching the one page canvas.
    mapSurface = {
      el: null,
      node: null,
      starting: false,
      detachTimer: 0,
      attach(el, node) {
        if (el) {
          clearTimeout(this.detachTimer);
          this.node = node;
          if (el !== this.el) {
            this.el = el;
            canvas.style.cssText =
              "position:absolute;inset:0;width:100%;height:100%;display:block";
            el.appendChild(canvas);
          }
          this.draw();
        } else {
          // React re-runs ref callbacks (null, then the element) on every
          // render; only a real unmount — no synchronous re-attach — should
          // reclaim the canvas.
          this.detachTimer = setTimeout(() => {
            this.el = null;
            this.node = null;
            canvas.remove();
            canvas.style.display = "none";
          }, 0);
        }
      },
      async ensure() {
        if (gpuHost || this.starting) return;
        this.starting = true;
        try {
          // Tiles ride the image machinery (imageInfo/rasterize), which the
          // React path otherwise never needs — create it with the surface.
          if (!raster) {
            raster = createRasterHost({
              scale: window.devicePixelRatio || 1,
              invalidate: () => scheduleRender(),
            });
          }
          await ensureMetalHost();
          this.draw();
        } catch (err) {
          // No WebGPU (older browser): leave a legible pane instead of a
          // dead canvas; the map's DOM controls still render above it.
          console.warn("[map] WebGPU unavailable — map tiles disabled:", err);
          if (this.el) {
            canvas.remove();
            canvas.style.display = "none";
            this.el.style.cssText +=
              ";display:grid;place-items:center;background:#e9e5dc;" +
              "color:#8a8377;font:14px -apple-system,sans-serif";
            this.el.textContent = "Map tiles need WebGPU";
          }
        }
      },
      draw() {
        if (!this.el || !this.node || !bridge) return;
        if (!gpuHost) {
          this.ensure();
          return;
        }
        const rect = this.el.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) return;
        const scale = window.devicePixelRatio || 1;
        const w = Math.max(1, Math.round(rect.width * scale));
        const h = Math.max(1, Math.round(rect.height * scale));
        if (canvas.width !== w) canvas.width = w;
        if (canvas.height !== h) canvas.height = h;
        const p = this.node.params || {};
        bridge.isoMapSurfaceRender(
          this.node.edit || "map", this.node.v || "",
          p.annotations || "", p.polygons || "", p.polylines || "",
          rect.width, rect.height);
      },
    };
    // React-path `MetalView`s: each a canvas of its own, a surface of the
    // page's Metal executor, asked for a frame every animation frame while
    // mounted (`isoMetalViewFrame`), as an MTKView draws by default.
    metalViews = {
      views: new Map(),
      attach(el, token, send) {
        const existing = this.views.get(token);
        if (el) {
          if (existing) {
            clearTimeout(existing.detachTimer);
            if (existing.el === el) return;
            existing.el = el;
            existing.surface = 0;
            return;
          }
          const view = { el, token, send, surface: 0, frame: 0, detachTimer: 0 };
          this.views.set(token, view);
          this.start(view);
        } else if (existing) {
          // React re-runs ref callbacks (null, then the element) on every
          // render: only a real unmount lets the view go.
          existing.detachTimer = setTimeout(() => {
            cancelAnimationFrame(existing.frame);
            if (existing.surface) gpuHost?.removeSurface(existing.surface);
            this.views.delete(token);
            existing.send("gone");
          }, 0);
        }
      },
      async start(view) {
        try {
          await ensureMetalHost();
        } catch (err) {
          console.warn("[metal] WebGPU unavailable — MetalView not drawn:", err);
          return;
        }
        const tick = () => {
          if (!this.views.has(view.token)) return;
          const scale = window.devicePixelRatio || 1;
          const rect = view.el.getBoundingClientRect();
          const w = Math.max(1, Math.round(rect.width * scale));
          const h = Math.max(1, Math.round(rect.height * scale));
          if (view.el.width !== w) view.el.width = w;
          if (view.el.height !== h) view.el.height = h;
          if (!view.surface) view.surface = gpuHost.addSurface(view.el);
          bridge.isoMetalViewFrame(view.token, view.surface);
          view.frame = requestAnimationFrame(tick);
        };
        view.frame = requestAnimationFrame(tick);
      },
    };
    reactTree = createReactTreeRenderer({
      container: treeContainer,
      sendEvent: hostEvent,
      sendKey: (id, value) => bridge.isoKeyEvent(id, value),
      mapSurface,
      metalViews,
      documentScroll,
    });
    // Event injection for headless smoke tests (cf. __isoHostViews).
    window.__isoSendEvent = (id, value) => bridge.isoHostEvent(id, value);
  }

  let renderFrame = 0;
  function scheduleRender() {
    if (renderFrame) return;
    renderFrame = requestAnimationFrame(() => {
      renderFrame = 0;
      bridge.isoRender();
    });
  }

  // A reader's tap renders what it changed before its event returns, not a
  // frame later: what that frame presents may be something only the
  // reader's gesture can open (a file picker: Safari opens one from
  // `input.click()` only while the click is being dispatched).
  let renderingInGesture = false;
  const GESTURES = new Set(["click", "pointerup", "touchend", "keydown", "keyup"]);
  function hostEvent(id, value) {
    bridge.isoHostEvent(id, value);
    const event = window.event;
    if (!renderFrame || !event || !event.isTrusted || !GESTURES.has(event.type)) return;
    cancelAnimationFrame(renderFrame);
    renderFrame = 0;
    renderingInGesture = true;
    try { bridge.isoRender(); } finally { renderingInGesture = false; }
  }


  // Native text input: a real DOM <input> positioned over the focused
  // TextField (full IME/selection support for free).
  const textOverlay = document.createElement("input");
  textOverlay.type = "text";
  textOverlay.style.cssText = [
    "position:fixed", "display:none", "box-sizing:border-box",
    "border:2px solid #0a84ff", "border-radius:6px", "padding:0 7px",
    "outline:none", "background:#fff", "color:rgba(0,0,0,0.85)",
    "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
    "z-index:10",
  ].join(";");
  document.body.appendChild(textOverlay);
  window.__isoTextOverlay = textOverlay; // used by headless smoke tests

  let hidingTextOverlay = false;
  function hideTextOverlay() {
    hidingTextOverlay = true;
    textOverlay.style.display = "none";
    textOverlay.blur();
    hidingTextOverlay = false;
  }
  textOverlay.addEventListener("input", () => bridge.isoTextChanged(textOverlay.value));
  textOverlay.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      bridge.isoTextSubmitted();
    }
  });
  textOverlay.addEventListener("blur", () => {
    if (!hidingTextOverlay && textOverlay.style.display !== "none") {
      textOverlay.style.display = "none";
      bridge.isoTextEnded();
    }
  });

  // Native host views: app-authored representables (`html:<type>`, the
  // UIViewRepresentable analogue) positioned over the canvas, reconciled each
  // frame by id. Framework chrome (navbar/tabbar/search/picker/menu/date/
  // media) is drawn at the GPU layer under the SwiftGPURenderer and built
  // from React components under the ReactRenderer — no DOM widgets here.
  const hostViews = new Map(); // id -> { el, kind }
  let darkMode = false;
  function sendHostEvent(id, value) {
    bridge.isoHostEvent(id, value);
  }
  function makeHostView(spec) {
    let el;
    if (spec.kind.startsWith("html:")) {
      el = document.createElement("input");
      el.type = spec.kind.slice(5); // e.g. "html:color" -> <input type=color>
      el.addEventListener("input", () => sendHostEvent(spec.id, el.value));
    } else {
      el = document.createElement("div");
    }
    el.style.cssText = [
      "position:fixed", "box-sizing:border-box", "z-index:9",
      "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
      "font-size:15px",
    ].join(";");
    document.body.appendChild(el);
    return el;
  }
  function updateHostView(entry, spec, bounds) {
    const el = entry.el;
    el.style.left = `${bounds.left + spec.x}px`;
    el.style.top = `${bounds.top + spec.y}px`;
    el.style.width = `${spec.w}px`;
    el.style.height = `${spec.h}px`;
    if (spec.kind.startsWith("html:")) {
      if (document.activeElement !== el && el.value !== spec.value) el.value = spec.value;
    }
  }
  function syncHostViews(json) {
    const specs = JSON.parse(json);
    const seen = new Set();
    const bounds = canvas.getBoundingClientRect();
    for (const spec of specs) {
      seen.add(spec.id);
      let entry = hostViews.get(spec.id);
      if (!entry || entry.kind !== spec.kind) {
        if (entry) entry.el.remove();
        entry = { el: makeHostView(spec), kind: spec.kind };
        hostViews.set(spec.id, entry);
      }
      updateHostView(entry, spec, bounds);
    }
    for (const [id, entry] of hostViews) {
      if (!seen.has(id)) {
        entry.el.remove();
        hostViews.delete(id);
      }
    }
  }
  window.__isoHostViews = hostViews; // for headless smoke tests

  // The Swift `WebHost` protocol, implemented as a plain object. Strings and
  // structs are real values; Swift retains this object through its foreign
  // proxy for the life of the app.
  const host = {
    measureText(text, fontSize, weight, wrapWidth) {
      if (!raster) {
        // ReactRenderer: the component system owns layout; a rough
        // estimate satisfies any stray build-time queries.
        return { width: text.length * fontSize * 0.6, height: fontSize * 1.3 };
      }
      return raster.measureText(text, fontSize, weight, wrapWidth < 0 ? null : wrapWidth);
    },
    imageInfo(source, isRemote) {
      if (!raster) return { state: 1, width: 0, height: 0 };
      // Image pixels are treated as logical points at 1x.
      return raster.imageInfo(source, isRemote);
    },
    // Drawing happens in Swift (SwiftGPURenderer through swift_gpu's WebGPU
    // backend); the host only supplies the services below.
    syncHostViews(viewsJSON) { syncHostViews(viewsJSON); },
    rasterize(spec) {
      return raster ? raster.rasterize(spec) : new Uint8Array(0);
    },
    beginTextInput(text, x, y, w, h, fontSize) {
      const bounds = canvas.getBoundingClientRect();
      textOverlay.value = text;
      textOverlay.style.left = `${bounds.left + x}px`;
      textOverlay.style.top = `${bounds.top + y}px`;
      textOverlay.style.width = `${w}px`;
      textOverlay.style.height = `${h}px`;
      textOverlay.style.fontSize = `${fontSize}px`;
      textOverlay.style.display = "block";
      requestAnimationFrame(() => textOverlay.focus());
    },
    endTextInput() { hideTextOverlay(); },
    scheduleRender() { scheduleRender(); },
    setColorScheme(dark) {
      darkMode = dark;
      // Makes native form controls (<select>/<input>) and scrollbars adapt.
      document.documentElement.style.colorScheme = darkMode ? "dark" : "light";
      // The window background behind the tree: the self-drawing renderers
      // paint Color.windowBackground themselves; under a component-system
      // renderer the PAGE is that surface, so mirror the same values
      // (light #ffffff / dark 0.07,0.07,0.08). Driven from here — not a CSS
      // media query — so an in-app .preferredColorScheme override matches too.
      document.body.style.background = darkMode ? "rgb(18, 18, 20)" : "#ffffff";
      textOverlay.style.background = darkMode ? "#1c1c1e" : "#fff";
      textOverlay.style.color = darkMode ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.85)";
    },
    now() { return performance.now() / 1000; },
    log(message) { console.log("[swiftui]", message); },
    openURL(url) { window.open(url, "_blank"); },
    // Generic platform-configuration channel (window title, platform
    // modifiers). Unknown keys are ignored by design.
    platformCommand(key, value) {
      // `UIPasteboard.general.string = …`: the page's clipboard. Called from
      // the tap's own event dispatch, so the browser counts it as the
      // reader's gesture; the textarea route is for browsers without the
      // async API (or refusing it outside a secure context).
      if (key === "copy") { copyText(value); return; }
      // `ShareLink`: the system's share sheet where the browser has one
      // (a phone's), else the text to the clipboard.
      if (key === "share") {
        if (navigator.share) navigator.share({ text: value }).catch(() => {});
        else copyText(value);
        return;
      }
      // An embedded surface must not reconfigure the host page.
      if (embedded) return;
      if (key === "windowTitle") document.title = value;
      // A page hook for app-specific commands (`platformCommand("splash",
      // "demo:2048", on: .wasm)` → the page runs the demo).
      if (typeof window.isoPlatformCommand === "function") window.isoPlatformCommand(key, value);
    },
    epochMillis() { return Date.now(); },
    registerImage(source, bytes) { registerImageBytes(source, bytes); },
    renderTree(tree) {
      // Each buffer is a tree.fbs `Patch` — the only wire format — applied in
      // arrival order to the retained plain-object tree the React interpreter
      // walks (the first patch after start is a full-tree op at "n").
      retainedTree = applyPatch(retainedTree, tree);
      window.__isoLastTree = JSON.stringify(retainedTree); // for headless smoke tests
      reactTree.render(retainedTree, renderingInGesture);
      // A mounted map redraws with every tree frame (camera moves arrive as
      // new frames; tile completions schedule one through the image drain).
      if (mapSurface && mapSurface.el) mapSurface.draw();
    },
  };

  // A `bundle` (bytes from a BundleProvider) takes precedence over `wasmURL`
  // (a plain packaged URL) — the two entry points into the same reactor.
  const module = bundle
    ? await WebAssembly.compile(bundle.wasm ?? bundle)
    : await WebAssembly.compileStreaming(fetch(wasmURL));
  // The guest's Foundation reads and writes the app's files through WASI
  // (file_system.js); a page's own overrides go on top.
  const files = await filesOpening;
  // The page's ISO_ query parameters are the guest's ISO_ environment, as a
  // native host's process environment is: the launch hooks
  // (`?ISO_OPEN_APP=todo`).
  const launchEnvironment = Object.fromEntries(
    [...new URLSearchParams(location.search)].filter(([key]) => key.startsWith("ISO_")));
  const environment = { ...launchEnvironment, ...(bundleIdentifier ? { ISOMER_BUNDLE_IDENTIFIER: bundleIdentifier } : {}) };
  const wasiWithFiles = (getMemory, builtins) => ({
    ...files.wasi(getMemory, builtins, { environment }),
    ...(typeof wasi === "function" ? wasi(getMemory, builtins) : (wasi || {})),
  });
  // `URLSession` over the page's fetch and WebSocket (network.js): isoStart
  // installs them before the app's @main runs.
  bridge = await load(module, {
    dependencies: { ...browserNetworkHosts(Dependencies, { fetch: pageFetch, WebSocket: PageWebSocket }), ...dependencies },
    wasi: wasiWithFiles,
  });
  if (gpuHost) {
    gpuHost.connect(bridge); // Isomer's Metal executor (WebGPU)
  }
  // Device pixels per point: the GPU renderer's clips, and `\.displayScale`.
  bridge.isoSetDisplayScale(window.devicePixelRatio || 1);

  const scale = window.devicePixelRatio || 1;
  function resizeBacking() {
    if (!gpuHost) return;
    canvas.width = Math.max(1, Math.round(canvas.clientWidth * scale));
    canvas.height = Math.max(1, Math.round(canvas.clientHeight * scale));
  }

  resizeBacking();
  // System appearance: report `prefers-color-scheme` BEFORE the first frame,
  // so a dark-mode user never sees a light flash.
  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  bridge.isoSetColorScheme(darkQuery.matches);
  // Runs the app's @main (installing the App) and starts the runtime with
  // this host object under the chosen renderer binding.
  // Size from the mount surface (an embedded container or the full page).
  bridge.isoStart(
    host, rendererName,
    canvas.clientWidth || window.innerWidth, canvas.clientHeight || window.innerHeight);

  // Scene lifecycle: page visibility maps to `@Environment(\.scenePhase)`.
  document.addEventListener("visibilitychange", () => {
    bridge.isoSetScenePhase(document.hidden ? "background" : "active");
  });
  // System appearance changes: live on every OS/browser toggle (the initial
  // value was reported before isoStart above).
  darkQuery.addEventListener("change", (event) => {
    bridge.isoSetColorScheme(event.matches);
  });
  // `.onOpenURL`: the launch URL, plus any the host page dispatches later via
  // `window.dispatchEvent(new CustomEvent("iso:openurl", { detail: url }))`.
  bridge.isoOpenURL(window.location.href);
  window.addEventListener("iso:openurl", (event) => {
    if (event.detail) bridge.isoOpenURL(String(event.detail));
  });

  if (react) {
    window.addEventListener("resize", () => {
      bridge.isoResize(window.innerWidth, window.innerHeight);
    });
    return { bridge, container: treeContainer };
  }

  const localPoint = (event) => {
    const rect = canvas.getBoundingClientRect();
    return [event.clientX - rect.left, event.clientY - rect.top];
  };
  canvas.addEventListener("pointerdown", (event) => {
    // Synthetic events (tests) carry pointer ids the browser doesn't own.
    try { canvas.setPointerCapture(event.pointerId); } catch (_) {}
    bridge.isoPointerEvent(0, ...localPoint(event));
  });
  canvas.addEventListener("pointermove", (event) => {
    bridge.isoPointerEvent(2, ...localPoint(event));
  });
  canvas.addEventListener("pointerup", (event) => {
    bridge.isoPointerEvent(1, ...localPoint(event));
  });
  canvas.addEventListener("wheel", (event) => {
    event.preventDefault();
    bridge.isoWheelEvent(...localPoint(event), event.deltaX, event.deltaY);
  }, { passive: false });
  window.addEventListener("resize", () => {
    resizeBacking();
    bridge.isoResize(canvas.clientWidth, canvas.clientHeight);
  });

  return { bridge };
}

// Incremental adoption (Level 3): mount a Isomer surface inside an
// existing web page — the web analogue of dropping a `UIHostingController`'s
// view into a UIKit hierarchy. Boots the runtime into the host-provided
// `container` (the Swift side decides the root via its `@main` App or a
// `IsomerHostingController`) under the chosen renderer: "react" builds
// real DOM/React components inside the container; "webGPU" draws into a
// canvas that fills it. Container resizes re-lay-out the embedded view
// independently of the window. Returns { bridge, unmount }.
export async function mountIsomer(container, { wasmURL, bundle, renderer = "webGPU", dependencies = {}, wasi = undefined, bundleIdentifier = undefined, fetch = undefined, WebSocket = undefined } = {}) {
  // The react tree / host-view overlays anchor to the container.
  if (getComputedStyle(container).position === "static") {
    container.style.position = "relative";
  }
  const canvas = document.createElement("canvas");
  canvas.style.cssText = "width:100%;height:100%;display:block;touch-action:none";
  container.appendChild(canvas);

  const result = await boot({
    canvas, wasmURL: bundle ? undefined : (wasmURL || "./app.wasm"),
    bundle, rendererName: renderer, embedded: true, dependencies, wasi, bundleIdentifier, fetch, WebSocket,
  });

  if (renderer !== "react" && typeof ResizeObserver !== "undefined") {
    const scale = window.devicePixelRatio || 1;
    const observer = new ResizeObserver(() => {
      canvas.width = Math.max(1, Math.round(canvas.clientWidth * scale));
      canvas.height = Math.max(1, Math.round(canvas.clientHeight * scale));
      result.bridge.isoResize(canvas.clientWidth, canvas.clientHeight);
    });
    observer.observe(container);
    result.disconnect = () => observer.disconnect();
  }

  result.unmount = () => {
    if (result.disconnect) result.disconnect();
    if (result.container) result.container.remove();
    canvas.remove();
  };
  return { ...result, canvas };
}
