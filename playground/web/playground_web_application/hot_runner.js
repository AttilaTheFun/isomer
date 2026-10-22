// Runs a user build in the page: a full-screen overlay hosting the reactor
// through hot_host.js (the same generic browser host the iOS Playground's
// web run uses), with a Stop bar. Logs (load status + guest print()) are kept
// for the agent's `logs` tool.
import { runHotBundle } from "./hot_host.js";

export function createRunner({ dependencies }) {
  let overlay = null;
  let handle = null;
  let lines = [];
  const log = (line) => { lines.push(line); if (lines.length > 400) lines.shift(); };
  // The build's DOM lives in `container`; it is parked in the app's run
  // surface (the Playground's full-screen cover) when one is mounted, and
  // in the fallback overlay (its own Stop bar) otherwise — the headless
  // dev hook runs without the app's cover.
  const container = document.createElement("div");
  container.className = "run-host";
  let surface = null;
  let surfaceSend = null;
  let fallbackTimer = null;

  function mount(el, send) {
    if (el) {
      surface = el;
      surfaceSend = send;
      if (fallbackTimer) { clearTimeout(fallbackTimer); fallbackTimer = null; }
      if (overlay) overlay.style.display = "none";
      el.appendChild(container);
      if (handle) handle._resize();
      return;
    }
    surface = null;
    surfaceSend = null;
    // React re-renders unmount/remount the surface element (a null ref,
    // then the new element); only a cover that stays gone falls back to
    // the overlay with the run still up.
    if (handle && !fallbackTimer) {
      fallbackTimer = setTimeout(() => { fallbackTimer = null; if (handle && !surface) showFallback(); }, 300);
    }
  }

  function showFallback() {
    const root = ensureOverlay();
    root.appendChild(container);
    root.style.display = "flex";
    if (handle) handle._resize();
  }

  function ensureOverlay() {
    if (overlay) return overlay;
    overlay = document.createElement("div");
    overlay.id = "playground-run";
    overlay.innerHTML =
      '<div class="run-bar"><span class="run-title">Running your build</span>' +
      '<button class="run-stop" aria-label="Stop">Stop</button></div>';
    overlay.querySelector(".run-stop").onclick = () => stop();
    document.body.appendChild(overlay);
    return overlay;
  }

  // `bundleIdentifier` names the build's home: its files (FileManager's,
  // kept in IndexedDB) and UserDefaults, one per project; `environment`
  // is the guest's added variables.
  async function run(wasm, bundleIdentifier, environment = {}) {
    stop();
    lines = [];
    container.innerHTML = "";
    if (surface) surface.appendChild(container);
    else fallbackTimer = setTimeout(() => { fallbackTimer = null; if (handle && !surface) showFallback(); }, 800);
    try {
      handle = await runHotBundle({
        wasm,
        container,
        dependencies,
        bundleIdentifier,
        environment,
        onLog: (line) => log(line),
        onStatus: (status) => log("[status] " + status),
      });
      log("[status] Loaded run");
      const resize = () => handle && handle.resize(container.clientWidth, container.clientHeight);
      resize();
      window.addEventListener("resize", resize);
      handle._resize = resize;
      return "running";
    } catch (error) {
      log("[status] Load failed: " + error);
      throw error;
    }
  }

  function stop() {
    if (fallbackTimer) { clearTimeout(fallbackTimer); fallbackTimer = null; }
    const wasRunning = !!handle;
    if (handle) {
      try { window.removeEventListener("resize", handle._resize); handle.stop(); } catch (_) {}
      handle = null;
    }
    container.innerHTML = "";
    if (overlay) overlay.style.display = "none";
    if (wasRunning && surfaceSend) surfaceSend("stopped");
  }

  // --- Driving the run (the agent's ui_tree / tap / type_text / submit / swipe) ---
  // Mirrors the iOS Playground's HeadlessRun: a node by tree path ("0.2.1")
  // or by label (accessibility label/identifier, text, placeholder); the
  // nearest handler on, inside or above it.
  const param = (n, key) => (n.params || {})[key];
  function uiTree(maxLines = 400) {
    const root = handle && handle.tree();
    if (!root) return "(no tree yet — is the app running?)";
    const lines = [];
    (function walk(n, path, depth) {
      let line = "  ".repeat(depth) + path + " " + (n.k || "box") + (n.view ? "/" + n.view : "");
      if (typeof n.v === "string" && n.v) line += ' "' + n.v.slice(0, 60).replace(/\n/g, " ") + '"';
      if (param(n, "a11yLabel")) line += ' label="' + param(n, "a11yLabel") + '"';
      if (param(n, "a11yId")) line += ' id="' + param(n, "a11yId") + '"';
      if (n.placeholder) line += ' placeholder="' + n.placeholder + '"';
      const caps = [];
      if (n.tap) caps.push("tap"); if (n.edit) caps.push("edit"); if (param(n, "submit")) caps.push("submit"); if (n.drag) caps.push("drag");
      if (caps.length) line += " [" + caps.join(" ") + "]";
      lines.push(line);
      (n.ch || []).forEach((c, i) => walk(c, path + "." + i, depth + 1));
    })(root, "0", 0);
    return lines.length > maxLines ? lines.slice(0, maxLines).join("\n") + `\n… (${lines.length - maxLines} more nodes)` : lines.join("\n");
  }
  function find(target) {
    const root = handle && handle.tree();
    if (!root) return null;
    const wanted = target.trim();
    if (/^[0-9.]+$/.test(wanted)) {
      let n = root;
      for (const part of wanted.split(".").slice(1)) { n = (n.ch || [])[Number(part)]; if (!n) return null; }
      return { node: n, path: wanted };
    }
    let exact = null, prefix = null;
    (function walk(n, path) {
      for (const c of [param(n, "a11yLabel"), param(n, "a11yId"), typeof n.v === "string" ? n.v : null, n.placeholder]) {
        if (!c) continue;
        if (!exact && c.toLowerCase() === wanted.toLowerCase()) exact = { node: n, path };
        if (!prefix && c.toLowerCase().startsWith(wanted.toLowerCase())) prefix = { node: n, path };
      }
      (n.ch || []).forEach((c, i) => walk(c, path + "." + i));
    })(root, "0");
    return exact || prefix;
  }
  function nearest(found, key) {
    const own = key(found.node); if (own) return own;
    const below = (n) => { for (const c of n.ch || []) { const id = key(c) || below(c); if (id) return id; } return null; };
    const inside = below(found.node); if (inside) return inside;
    const root = handle.tree(); const chain = [root]; let n = root;
    for (const part of found.path.split(".").slice(1)) { n = (n.ch || [])[Number(part)]; if (!n) break; chain.push(n); }
    for (const a of chain.reverse().slice(1)) { const id = key(a); if (id) return id; }
    return null;
  }
  async function drive(kind, target, arg) {
    if (!handle) return "error: nothing is running";
    const found = find(target || "");
    if (!found) return `error: no node matching ${target} (call ui_tree)`;
    if (kind === "tap") { const id = nearest(found, (n) => n.tap); if (!id) return `error: nothing tappable at ${target}`; handle.send(id, ""); return "tapped " + found.path; }
    if (kind === "type") { const id = nearest(found, (n) => n.edit); if (!id) return `error: no text field at ${target}`; handle.send(id, arg || ""); return "typed into " + found.path; }
    if (kind === "submit") { const id = nearest(found, (n) => param(n, "submit")); if (!id) return `error: nothing to submit at ${target}`; handle.send(id, ""); return "submitted " + found.path; }
    if (kind === "swipe") {
      const id = nearest(found, (n) => n.drag);
      if (!id) return `error: no DragGesture at ${target} (native scrolling cannot be swiped)`;
      const [dx, dy] = arg;
      for (let step = 1; step <= 8; step++) { const t = step / 8; handle.send(id, `changed:${dx * t},${dy * t}`); await new Promise((r) => setTimeout(r, 16)); }
      handle.send(id, `ended:${dx},${dy}`);
      return `swiped ${found.path} by (${Math.round(dx)}, ${Math.round(dy)})`;
    }
    return "error: unknown action";
  }

  return { run, stop, mount, uiTree, drive, logs: () => (lines.length ? lines.join("\n") : "(no log output yet)") };
}
