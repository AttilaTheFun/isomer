// run_metal_check.js <bundle.js> <reactor.wasm> — runs Isomer's Metal check
// (metal/tests/web) in headless Chrome with WebGPU and prints what it
// reported; exits 1 on a FAIL line or no "done". No server: the reactor's
// bytes and the bundle go to an empty file:// page (a secure context, as
// WebGPU requires) over the DevTools protocol.
const { spawn } = require("child_process");
const fs = require("fs");
const [bundlePath, wasmPath, waitSeconds = "30"] = process.argv.slice(2);
const bundle = fs.readFileSync(bundlePath, "utf8");
const wasm = fs.readFileSync(wasmPath).toString("base64");
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = fs.mkdtempSync("/tmp/metal-check-profile-");
const blank = `${profile}/blank.html`;
fs.writeFileSync(blank, "<!doctype html><title>metal check</title><body></body>");
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
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    if (m.method === "Runtime.consoleAPICalled") console.log("  console:", m.params.args.map((a) => a.value ?? a.description).join(" "));
    if (m.method === "Runtime.exceptionThrown") console.log("  exception:", m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
  };
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  await send("Runtime.enable");
  await send("Runtime.evaluate", { expression: `window.__metalCheckWasm = Uint8Array.from(atob(${JSON.stringify(wasm)}), (c) => c.charCodeAt(0)); 0` });
  const loaded = await send("Runtime.evaluate", { expression: bundle });
  if (loaded.result.exceptionDetails) console.log("  load exception:", JSON.stringify(loaded.result.exceptionDetails).slice(0, 500));
  let state = null;
  for (let i = 0; i < +waitSeconds * 10; i++) {
    await sleep(100);
    const r = await send("Runtime.evaluate", { expression: "JSON.stringify(window.__metalCheck)", returnByValue: true });
    state = JSON.parse(r.result.result.value || "null");
    if (state?.done) break;
  }
  for (const line of state?.lines ?? []) console.log(line);
  const failed = !state?.done || state.lines.some((l) => l.startsWith("FAIL"));
  if (!state?.done) console.log("FAIL the check did not finish");
  ws.close();
  finish(failed ? 1 : 0);
})().catch((e) => { console.error(e); finish(1); });
