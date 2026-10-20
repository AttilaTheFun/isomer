// validate_wgsl.js <file> — compiles each WGSL module in <file> with a
// browser's WebGPU (headless Chrome) and prints its errors. The file is
// what `translator_check --print` writes: modules separated by lines
// starting `// ===== <name>`. No server: the modules are compiled from an
// empty file:// page (a secure context, as WebGPU requires) over the
// DevTools protocol.
const { spawn } = require("child_process");
const fs = require("fs");
const text = fs.readFileSync(process.argv[2], "utf8");
const modules = [];
for (const chunk of text.split(/^\/\/ ===== /m).slice(1)) {
  const newline = chunk.indexOf("\n");
  const name = chunk.slice(0, newline).trim();
  const code = chunk.slice(newline + 1).split(/^\/\/ reflection: /m)[0];
  modules.push({ name, code });
}
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = fs.mkdtempSync("/tmp/wgsl-profile-");
const blank = `${profile}/blank.html`;
fs.writeFileSync(blank, "<!doctype html><title>wgsl</title>");
const port = 9333 + Math.floor(Math.random() * 500);
const proc = spawn(chrome, ["--headless=new", "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-mock-keychain",
  "--password-store=basic", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run", `file://${blank}`],
  { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const finish = (code) => { proc.kill(); try { fs.rmSync(profile, { recursive: true, force: true }); } catch (_) {} process.exit(code); };
(async () => {
  let targets = null;
  for (let i = 0; i < 50 && !targets; i++) { await sleep(200); try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch (_) {} }
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0; const pending = new Map();
  ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  const expression = `(async () => {
    if (!navigator.gpu) return JSON.stringify({ error: "no navigator.gpu" });
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) return JSON.stringify({ error: "no adapter" });
    const device = await adapter.requestDevice();
    const results = [];
    for (const m of ${JSON.stringify(modules)}) {
      const module = device.createShaderModule({ code: m.code });
      const info = await module.getCompilationInfo();
      results.push({ name: m.name, messages: info.messages.filter((x) => x.type !== "info").map((x) => x.type + " " + x.lineNum + ":" + x.linePos + " " + x.message) });
    }
    return JSON.stringify({ results });
  })()`;
  const result = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true, timeout: 60000 });
  const value = JSON.parse(result.result.result.value);
  if (value.error) { console.log("FAIL " + value.error); finish(1); return; }
  let failed = 0;
  for (const r of value.results) {
    if (r.messages.length) { failed++; console.log("FAIL " + r.name); for (const m of r.messages) console.log("  " + m); }
    else console.log("ok " + r.name);
  }
  ws.close();
  finish(failed ? 1 : 0);
})().catch((e) => { console.error(e); finish(1); });
