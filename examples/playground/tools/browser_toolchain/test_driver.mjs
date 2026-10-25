// Runs the web Playground's compile driver under Node against a staged
// toolchain directory (tools/browser_toolchain/stage_bundle.sh output with
// swift-frontend.wasm + wasm-ld.wasm present): compiles a Swift source to a
// iso_hot reactor and validates it. The same code path the browser worker
// runs, minus the fetches.
//
//   node test_driver.mjs <toolchain-dir> <App.swift> [out.wasm]
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import { compileWithToolchain } from "../../web/playground_web_application/toolchain_driver.js";

const [dir, source, out = "/tmp/UserApp.wasm"] = process.argv.slice(2);
const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
const files = new Map();
for (const entry of manifest.files) files.set(entry.path, new Uint8Array(readFileSync(join(dir, entry.path))));
for (const entry of [manifest.frontend, manifest.linker]) {
  for (const name of Array.isArray(entry) ? entry : [entry]) {
    // Staged as gzipped files (what the site serves); raw ones also accepted.
    const path = join(dir, name);
    if (existsSync(path + ".gz")) files.set(name, new Uint8Array(gunzipSync(readFileSync(path + ".gz"))));
    else if (existsSync(path)) files.set(name, new Uint8Array(readFileSync(path)));
    else { console.error("missing", path); process.exit(2); }
  }
}
const started = performance.now();
const result = await compileWithToolchain({ manifest, files }, readFileSync(source, "utf8"));
const elapsed = ((performance.now() - started) / 1000).toFixed(1);
if (!result.ok) { console.log(`FAIL (${elapsed}s)\n` + result.diagnostics); process.exit(1); }
writeFileSync(out, result.wasm);
const valid = WebAssembly.validate(result.wasm);
const module = valid ? await WebAssembly.compile(result.wasm) : null;
const exports = module ? WebAssembly.Module.exports(module).map((e) => e.name) : [];
const hasStart = exports.includes("iso_hot_start") && exports.includes("_initialize");
console.log(`${hasStart ? "PASS" : "FAIL"} (${elapsed}s): ${result.wasm.length} bytes → ${out}; valid=${valid}; iso_hot_start=${exports.includes("iso_hot_start")}`);
process.exit(hasStart ? 0 : 1);
