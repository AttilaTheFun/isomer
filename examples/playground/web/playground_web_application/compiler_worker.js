// The compile worker: turns App.swift into a runnable iso_hot reactor.
//
// Backends, tried in order:
//   1. In-browser toolchain — `toolchain/manifest.json` beside the site lists
//      swift-frontend.wasm, wasm-ld.wasm, the resource dir and the SDK
//      archives (built by tools/browser_toolchain). The frontend runs under a
//      WASI shim over an in-memory filesystem hydrated from the bundle, then
//      the linker links the object against the SDK.
//   2. Dev compile server — POST /compile (tools/playground/dev_compile_server.py
//      runs the host toolchain); for developing the page before the wasm
//      toolchain is available, never for the published site.
//
// Messages: { id, source } in; { id, ok, wasm?, diagnostics? } out.
let toolchain = null;   // { manifest, files: Map<path, Uint8Array> } once loaded
let toolchainState = "unknown";

async function loadToolchain() {
  if (toolchain || toolchainState === "absent") return;
  try {
    // The manifest is revalidated every load (a cheap ETag check); the big
    // files it names are fetched under its version (the content's hash),
    // so a cached copy is only ever the one this manifest describes. A
    // stale manifest from the HTTP cache paired an old SDK with a newer page.
    const response = await fetch("./toolchain/manifest.json", { cache: "no-cache" });
    if (!response.ok) { toolchainState = "absent"; return; }
    const manifest = await response.json();
    const version = String(manifest.version || 1);
    const versioned = (name) => "./toolchain/" + name + "?v=" + encodeURIComponent(version);
    const files = new Map();
    if (manifest.bundle) {
      // One blob, sliced by the manifest's offsets (thousands of small
      // module files would be thousands of fetches otherwise).
      // Prefer the gzipped blob (a static host serves it as-is); fall back
      // to the raw one when only that is published.
      let response = await fetch(versioned(manifest.bundle + ".gz"), { cache: "force-cache" });
      let blob;
      if (response.ok) {
        const bytes = new Uint8Array(await response.arrayBuffer());
        blob = bytes[0] === 0x1f && bytes[1] === 0x8b
          ? new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"))).arrayBuffer())
          : bytes;
      } else {
        response = await fetch(versioned(manifest.bundle), { cache: "force-cache" });
        blob = new Uint8Array(await response.arrayBuffer());
      }
      for (const entry of manifest.files || []) files.set(entry.path, blob.subarray(entry.offset, entry.offset + entry.size));
    } else {
      for (const entry of manifest.files || []) {
        const bytes = new Uint8Array(await (await fetch(versioned(entry.path), { cache: "force-cache" })).arrayBuffer());
        files.set(entry.path, bytes);
      }
    }
    // The compiler and linker binaries: outside the blob (too big), each a
    // file or a list of parts, gzipped on the host. They are compiled
    // STREAMING straight from the (inflated) response — the browser's code
    // cache then keys on the URL and skips the ~100 MB compile on later
    // loads — and kept as WebAssembly.Module objects, not bytes.
    const cacheName = "iso-toolchain-v" + version;
    if (self.caches) {
      // Earlier toolchains' compilers (~150 MB each) go.
      for (const name of await caches.keys()) {
        if (name.startsWith("iso-toolchain-") && name !== cacheName) await caches.delete(name);
      }
    }
    const cache = await (self.caches ? caches.open(cacheName) : null);
    const fetchCached = async (url) => {
      if (cache) { const hit = await cache.match(url); if (hit) return hit; }
      const response = await fetch(url);
      if (response.ok && cache) { try { await cache.put(url, response.clone()); } catch (_) {} }
      return response;
    };
    // A host may serve `.gz` with Content-Encoding (already inflated by the
    // browser) or as plain bytes: sniff the gzip magic instead of assuming.
    const inflated = async (response) => {
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
        return new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"))).body;
      }
      return new Blob([bytes]).stream();
    };
    const partStream = async (name) => {
      const gz = await fetchCached(versioned(name + ".gz"));
      if (gz.ok) return inflated(gz);
      const raw = await fetchCached(versioned(name));
      if (!raw.ok) throw new Error("toolchain: missing " + name);
      return raw.body;
    };
    const compileEntry = async (entry) => {
      const names = Array.isArray(entry) ? entry : [entry];
      // Parts concatenate into one stream.
      const streams = await Promise.all(names.map(partStream));
      const joined = new ReadableStream({
        async start(controller) {
          for (const stream of streams) {
            const reader = stream.getReader();
            for (;;) { const { done, value } = await reader.read(); if (done) break; controller.enqueue(value); }
          }
          controller.close();
        },
      });
      return WebAssembly.compileStreaming(new Response(joined, { headers: { "Content-Type": "application/wasm" } }));
    };
    const [frontendModule, linkerModule] = await Promise.all([compileEntry(manifest.frontend), compileEntry(manifest.linker)]);
    toolchain = { manifest, files, modules: { frontend: frontendModule, linker: linkerModule } };
    toolchainState = "wasm";
  } catch (error) {
    toolchainState = "absent";
  }
}

async function compileInBrowser(source) {
  // Wired when tools/browser_toolchain produces the bundle: instantiate
  // swift-frontend.wasm with a WASI shim + virtual FS (resource dir, SDK
  // modules, work/main.swift), run `-frontend -c …`, then wasm-ld.wasm.
  const { compileWithToolchain } = await import("./toolchain_driver.js");
  return compileWithToolchain(toolchain, source);
}

async function compileWithDevServer(source) {
  const response = await fetch("/compile", { method: "POST", headers: { "Content-Type": "text/plain" }, body: source });
  if (response.status === 200) return { ok: true, wasm: new Uint8Array(await response.arrayBuffer()) };
  if (response.status === 422) return { ok: false, diagnostics: await response.text() };
  throw new Error("compile server: HTTP " + response.status);
}

self.onmessage = async (event) => {
  const { id, source, probe } = event.data;
  await loadToolchain();
  if (probe) {
    let status = toolchainState === "wasm" ? "wasm" : "none: no toolchain bundle";
    if (toolchainState !== "wasm") {
      try {
        const ping = await fetch("/compile", { method: "OPTIONS" });
        if (ping.ok) status = "dev";
      } catch (_) {}
    }
    self.postMessage({ id, status });
    return;
  }
  try {
    const result = toolchainState === "wasm" ? await compileInBrowser(source) : await compileWithDevServer(source);
    if (result.ok) self.postMessage({ id, ok: true, wasm: result.wasm }, [result.wasm.buffer]);
    else self.postMessage({ id, ok: false, diagnostics: result.diagnostics });
  } catch (error) {
    self.postMessage({ id, ok: false, diagnostics: "compile failed: " + (error && error.message || error) });
  }
};
