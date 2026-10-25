// Links a natively compiled object with the browser driver's wasm-ld step:
//   node test_link.mjs <toolchain-dir> <UserApp.o> [out.wasm]
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";
import { linkWithToolchain } from "../../web/playground_web_application/toolchain_driver.js";

const [dir, object, out = "/tmp/UserApp.linked.wasm"] = process.argv.slice(2);
const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
const files = new Map();
for (const entry of manifest.files) files.set(entry.path, new Uint8Array(readFileSync(join(dir, entry.path))));
for (const name of Array.isArray(manifest.linker) ? manifest.linker : [manifest.linker]) {
  const path = join(dir, name);
  files.set(name, new Uint8Array(existsSync(path + ".gz") ? gunzipSync(readFileSync(path + ".gz")) : readFileSync(path)));
}
const started = performance.now();
const result = await linkWithToolchain({ manifest, files }, new Uint8Array(readFileSync(object)));
const elapsed = ((performance.now() - started) / 1000).toFixed(1);
if (!result.ok) { console.log(`FAIL (${elapsed}s)\n` + result.diagnostics); process.exit(1); }
writeFileSync(out, result.wasm);
const exports = WebAssembly.Module.exports(await WebAssembly.compile(result.wasm)).map((e) => e.name);
console.log(`${exports.includes("iso_hot_start") ? "PASS" : "FAIL"} (${elapsed}s): ${result.wasm.length} bytes → ${out}; iso_hot_start=${exports.includes("iso_hot_start")}`);
