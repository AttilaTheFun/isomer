// A generic browser host for `iso_hot` feature bundles — the web peer of the
// native WasmView. Where boot.js drives an app reactor through its GENERATED
// swift_ffi bindings (app_bridge.js), this host speaks the fixed `iso_hot`
// render ABI directly, so it can run ANY feature bundle — including one
// compiled outside bazel (the Playground app's on-the-fly user builds) —
// with no generated code. The reactor pushes tree.fbs Patches; the React
// renderer mounts them as real DOM.
//
// ABI (mirrors HotBridge.swift):
//   imports (this host provides, module "iso_hot"):
//     render_tree(ptr, len)  log(ptr, len)  epoch_millis()  schedule_render()
//     platform_command(key, value)  host_value(key, out, capacity) -> length
//   exports (this host calls):
//     _initialize, iso_hot_start(w, h), iso_hot_render(), iso_hot_resize(w, h),
//     iso_hot_set_color_scheme(dark), iso_hot_alloc/free, iso_hot_event(...)
//
// The six fixed `swift_ffi` transport imports are bound as inert stubs
// (dependency lookups answer "absent"); a v3 reactor that never touches
// `dependencies[...]` runs exactly as it does under a host without DI.

import { BlobWriter, Runtime, Tags, Types, decoder as ffiDecoder, encodeErrorBlob, foreignObjects, pendingCalls, registerForeign, wasiShim } from "./swift_ffi_runtime.js";
import { createReactTreeRenderer } from "./runtime/react_renderer.js";
import { applyPatch } from "./runtime/flat_tree.js";
import { appFilesKey, openAppFiles } from "./runtime/file_system.js";
import { playHaptic } from "./runtime/haptics.js";
import { browserNetworkHosts } from "./runtime/network.js";

const decoder = new TextDecoder();
const encoder = new TextEncoder();

/** Foundation's networking (runtime/network.js) for a bundle on the full
 *  SwiftUI, whose HotBridge installs what is injected under `isomerHTTP` and
 *  `isomerWebSocket` (a bundle on the slim one never asks). The hosts are
 *  wrapped with the generated builders of the bindings beside this file
 *  (app_bridge.js, where isomer_web_app and the Playground's sites put
 *  them): IsomerNetworkHost's are the same in every reactor's bindings.
 *  None without them. */
async function pageNetworkHosts(options) {
  try {
    const { Dependencies } = await import("./app_bridge.js");
    return browserNetworkHosts(Dependencies, options);
  } catch (_) {
    return {};
  }
}

/** Instantiates `wasm` (bytes or a compiled Module) and mounts the feature
 *  into `container`. Returns { resize(w, h), setColorScheme(dark), stop() }.
 *  The feature's files (file_system.js) are kept under `bundleIdentifier`,
 *  else under the page's path; a bundle run again on the page finds them as
 *  the last one left them. `environment` adds variables to the guest's
 *  (ISO_OPEN_APP and the other launch hooks). */
export async function runHotBundle({ wasm, container, dependencies = {}, bundleIdentifier = undefined, environment = {}, fetch = undefined, WebSocket = undefined, onLog = null, onStatus = null }) {
  const files = await openAppFiles(appFilesKey(bundleIdentifier));
  // The page's own entries replace the network hosts, as under boot.js.
  dependencies = { ...(await pageNetworkHosts({ fetch, WebSocket })), ...dependencies };
  let memory = null;
  let exports = null;
  let retainedTree = null;

  const guestString = (ptr, len) =>
    len <= 0 ? "" : decoder.decode(new Uint8Array(memory.buffer, ptr, len));

  function sendEvent(id, value) {
    if (!exports) return;
    const idBytes = encoder.encode(id);
    const valueBytes = encoder.encode(value);
    const idPtr = exports.iso_hot_alloc(idBytes.length);
    new Uint8Array(memory.buffer, idPtr, idBytes.length).set(idBytes);
    const valuePtr = exports.iso_hot_alloc(valueBytes.length);
    new Uint8Array(memory.buffer, valuePtr, valueBytes.length).set(valueBytes);
    exports.iso_hot_event(idPtr, idBytes.length, valuePtr, valueBytes.length);
    exports.iso_hot_free(idPtr);
    exports.iso_hot_free(valuePtr);
    scheduleRender();
  }

  // Dispatch-channel helpers: argument buffers arrive borrowed as (ptr, len);
  // results go back packed as (len << 32) | ptr in swift_ffi_alloc memory
  // (ownership transfers to the guest).
  let ffiRuntime = null;
  const foreignBytes = (ptr, len) =>
    len === 0 ? new Uint8Array(0) : new Uint8Array(memory.buffer, ptr, len).slice();
  const foreignString = (ptr, len) =>
    len === 0 ? "" : ffiDecoder.decode(new Uint8Array(memory.buffer, ptr, len));
  const packForeignBytes = (bytes) => {
    if (bytes.length === 0) return 0n;
    const ptr = exports.swift_ffi_alloc(bytes.length);
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    return (BigInt(bytes.length) << 32n) | BigInt(ptr >>> 0);
  };

  const renderer = createReactTreeRenderer({ container, sendEvent });
  window.__isoSendEvent = sendEvent; // headless smoke-test hook

  let renderQueued = false;
  function scheduleRender() {
    if (renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(() => {
      renderQueued = false;
      if (exports) exports.iso_hot_render();
    });
  }

  const imports = {
    iso_hot: {
      render_tree(ptr, len) {
        const bytes = new Uint8Array(memory.buffer, ptr, len).slice();
        retainedTree = applyPatch(retainedTree, bytes);
        window.__isoLastTree = JSON.stringify(retainedTree); // smoke-test hook
        renderer.render(retainedTree);
      },
      log(ptr, len) {
        const line = guestString(ptr, len);
        console.log("[iso-hot]", line);
        if (onLog) onLog(line);
      },
      epoch_millis() {
        return Date.now();
      },
      schedule_render() {
        scheduleRender();
      },
      // The platform channel: "copy" to the clipboard, "openURL" in a new
      // tab, "share" through navigator.share. A page reads no clipboard
      // synchronously, so it holds no values (-1).
      platform_command(kp, kl, vp, vl) {
        const key = guestString(kp, kl), value = guestString(vp, vl);
        if (key === "copy") navigator.clipboard?.writeText(value).catch(() => {});
        else if (key === "openURL") window.open(value, "_blank");
        else if (key === "share" && navigator.share) navigator.share({ text: value }).catch(() => {});
        else if (key === "haptic") playHaptic(value);
      },
      host_value() {
        return -1;
      },
    },
    // The fixed v3 swift_ffi transport (the same bindings the generated
    // app_bridge `load` installs): `dependencies` is a {key: dependency}
    // table built with a module's generated `Dependencies.*` builders —
    // the guest's `dependencies[...]` lookups resolve to them, and their
    // async answers come back through resumeAsync/async_complete. With no
    // table, lookups return "absent" and the guest runs without DI.
    swift_ffi: {
      closure_invoke(id, argsPtr, argsLen) {
        const dispatcher = foreignObjects.get(id);
        let result;
        try {
          if (!dispatcher) throw new Error(`no foreign object ${id}`);
          result = dispatcher(foreignBytes(argsPtr, argsLen));
        } catch (error) {
          result = encodeErrorBlob(error instanceof Error ? error.message : String(error));
        }
        return packForeignBytes(result);
      },
      foreign_release(id) { foreignObjects.delete(id); },
      dependency_get(keyPtr, keyLen) {
        const dep = dependencies[foreignString(keyPtr, keyLen)];
        if (!dep) return 0n;
        const w = new BlobWriter();
        w.header(Tags.list, 0);
        w.i64(3n);
        Types.bool.encode(w, dep.lazy);
        Types.string.encode(w, dep.key);
        Types.int32.encode(w, registerForeign((args) => dep.dispatcher(args, () => ffiRuntime)));
        return packForeignBytes(w.data());
      },
      task_enqueue(job) {
        queueMicrotask(() => {
          if (exports && exports.swift_ffi_task_run) exports.swift_ffi_task_run(job);
        });
      },
      // A timed job (Task.sleep): run it once the delay is up.
      task_enqueue_after(job, delayMs) {
        setTimeout(() => {
          if (exports && exports.swift_ffi_task_run) exports.swift_ffi_task_run(job);
        }, Math.max(0, delayMs));
      },
      async_complete(callId, blobPtr, blobLen) {
        const pending = pendingCalls.get(callId);
        pendingCalls.delete(callId);
        if (pending) pending.resolve(pending.decode(foreignBytes(blobPtr, blobLen)));
      },
    },
    wasi_snapshot_preview1: wasiShim(() => {
      if (!memory) throw new Error("wasm memory accessed before instantiation");
      return memory;
    }, (getMemory, builtins) => files.wasi(getMemory, builtins, {
      environment: { ...environment, ...(bundleIdentifier ? { ISOMER_BUNDLE_IDENTIFIER: bundleIdentifier } : {}) },
    })),
  };

  const module =
    wasm instanceof WebAssembly.Module ? wasm : await WebAssembly.compile(wasm);
  const instance = await WebAssembly.instantiate(module, imports);
  memory = instance.exports.memory;
  instance.exports._initialize();
  exports = instance.exports;
  ffiRuntime = new Runtime(instance.exports);
  // Register every interface's dependency-proxy factory the reactor
  // exports (docs/wasm_di.md) — generic, so any module's interfaces work.
  for (const name of Object.keys(instance.exports)) {
    if (/^swift_ffi_.*_register_/.test(name)) instance.exports[name]();
  }

  // System appearance BEFORE the first frame (no light flash for dark users),
  // live on later toggles. Mirrors boot.js's page treatment.
  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  function applyColorScheme(dark) {
    document.documentElement.style.colorScheme = dark ? "dark" : "light";
    document.body.style.background = dark ? "rgb(18, 18, 20)" : "#ffffff";
    exports.iso_hot_set_color_scheme(dark ? 1 : 0);
  }
  applyColorScheme(darkQuery.matches);
  darkQuery.addEventListener("change", (event) => {
    applyColorScheme(event.matches);
    scheduleRender();
  });

  exports.iso_hot_start(
    container.clientWidth || window.innerWidth,
    container.clientHeight || window.innerHeight);
  exports.iso_hot_render();

  const onResize = () => {
    exports.iso_hot_resize(
      container.clientWidth || window.innerWidth,
      container.clientHeight || window.innerHeight);
    scheduleRender();
  };
  window.addEventListener("resize", onResize);

  return {
    resize: (w, h) => exports.iso_hot_resize(w, h),
    /** The retained plain-object tree (kinds, text, params, tap/edit/drag
     *  ids) — what a driver reads; `send` fires an event on a node id the
     *  way the renderer does (tap: "", edit: text, drag: "changed:x,y"). */
    tree: () => retainedTree,
    send: (id, value) => sendEvent(id, value),
    setColorScheme: (dark) => {
      applyColorScheme(!!dark);
      scheduleRender();
    },
    stop() {
      window.removeEventListener("resize", onResize);
      exports = null;
      files.flush();
    },
  };
}
