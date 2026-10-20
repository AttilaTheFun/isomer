// Where a wasm feature's bundle comes from on the web — the JS mirror of the
// Apple `BundleProvider` (apple/libraries/wasm_view/BundleProvider.swift). A
// provider yields:
//   • an INITIAL bundle (a Promise for the first bytes) — the app-packaged wasm,
//     or the newest previously-cached dynamic-delivery bundle, and
//   • an async STREAM of newer bundles that arrive while running — a dev
//     hot-reload shadow, or a production dynamic-delivery update. The React
//     component (`<Isomer>`) re-instantiates the surface on each.
//
// A bundle is `{ wasm: ArrayBuffer | Uint8Array, label: string, assets?: {} }`.
// `assets` holds small co-versioned files (localized strings, tiny images);
// large assets go through services or the main app bundle.

/** A static, app-packaged bundle (fetched once, no updates). */
export function packagedBundleProvider(wasmURL, { label } = {}) {
  return {
    async initialBundle() {
      const response = await fetch(wasmURL);
      if (!response.ok) throw new Error(`bundle fetch ${response.status}: ${wasmURL}`);
      return { wasm: await response.arrayBuffer(), label: label || wasmURL };
    },
    bundleUpdates() {
      return emptyStream();
    },
  };
}

// The batteries-included default: the packaged bundle plus a dev hot-reload
// shadow gated on `hotReloadURL` (pass it from a dev-only env/query param).
// Point production dynamic delivery at the same shape: override `initialBundle`
// to return the newest cached download and feed `bundleUpdates` from a
// background fetch.
export function appBundleProvider(wasmURL, { hotReloadURL, label } = {}) {
  const base = packagedBundleProvider(wasmURL, { label });
  if (!hotReloadURL) return base;
  return {
    initialBundle: () => base.initialBundle(),
    bundleUpdates: () => hotReloadStream(hotReloadURL),
  };
}

/** Reads a hot-reload server (the same protocol the Apple AppBundleProvider
 *  uses): `GET /version` (a build counter) + `GET /wasm` (reactor bytes). */
async function* hotReloadStream(baseURL) {
  const base = baseURL.replace(/\/$/, "");
  let version = -Infinity;
  for (;;) {
    await delay(500);
    try {
      const text = await (await fetch(`${base}/version`, { cache: "no-store" })).text();
      const v = parseInt(text.trim(), 10);
      if (Number.isNaN(v) || v === version) continue;
      version = v;
      const wasm = await (await fetch(`${base}/wasm`, { cache: "no-store" })).arrayBuffer();
      yield { wasm, label: `server build ${v}` };
    } catch {
      // Server not up yet / transient — keep polling.
    }
  }
}

// eslint-disable-next-line require-yield
async function* emptyStream() {}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
