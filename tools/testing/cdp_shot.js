// cdp_shot.js <url> <out.png> [waitSeconds] [width] [height] [clicks "x,y;x,y"] [typeText] [postWaitS]
// env CDP_PRE_EVAL="<js>": awaited before the screenshot (drive the page into a state; its value is printed).
// env CDP_INIT_SCRIPT="<js>": runs before the page loads. CDP_LOG_FILTER=<regex>: console lines to print.
// Drives headless Chrome over CDP (Node's global WebSocket): loads the page,
// waits for the wasm app to render, optionally clicks / types, screenshots,
// and prints console messages + page errors.
const { spawn } = require("child_process");
const fs = require("fs");
const [url, out, waitS = "8", width = "1200", height = "800", clicks = "", typeText = "", postWaitS = "1"] = process.argv.slice(2);
// CDP_CHROME names another Chrome (Linux's, a Chromium) than the Mac's.
const chrome = process.env.CDP_CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = fs.mkdtempSync("/tmp/cdp-profile-");
const port = 9333 + Math.floor(Math.random() * 500);
// CDP_CHROME_FLAGS="--enable-unsafe-webgpu --use-angle=metal": extra flags
// (and no --disable-gpu) for pages that need WebGPU.
const gpuFlags = process.env.CDP_CHROME_FLAGS ? process.env.CDP_CHROME_FLAGS.split(/\s+/).filter(Boolean) : ["--disable-gpu"];
const proc = spawn(chrome, ["--headless=new", ...gpuFlags, "--use-mock-keychain", "--password-store=basic", "--hide-scrollbars", `--remote-debugging-port=${port}`,
  `--window-size=${width},${height}`, `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  let targets = null;
  for (let i = 0; i < 50 && !targets; i++) {
    await sleep(200);
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch (_) {}
  }
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0; const pending = new Map(); const logs = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    if (m.method === "Runtime.consoleAPICalled") logs.push(`[${m.params.type}] ` + m.params.args.map((a) => a.value ?? a.description ?? "").join(" "));
    if (m.method === "Runtime.exceptionThrown") logs.push("[exception] " + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
  };
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  await send("Runtime.enable"); await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width: +width, height: +height, deviceScaleFactor: 1, mobile: +width < 500 });
  // CDP_INIT_SCRIPT="<js>": runs before the page's own scripts (seed
  // localStorage, e.g. a renderer preference the page reads at boot).
  if (process.env.CDP_INIT_SCRIPT) await send("Page.addScriptToEvaluateOnNewDocument", { source: process.env.CDP_INIT_SCRIPT });
  await send("Page.navigate", { url });
  await sleep(+waitS * 1000);
  for (const c of clicks.split(";").filter(Boolean)) {
    const [x, y] = c.split(",").map(Number);
    for (const type of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 });
    await sleep(800);
  }
  if (typeText) { await send("Input.insertText", { text: typeText }); await sleep(500); }
  // CDP_PRE_EVAL: an expression (awaited) to run before the screenshot —
  // drive the page into the state to capture (open a sheet, start a run).
  if (process.env.CDP_PRE_EVAL) {
    const r = await send("Runtime.evaluate", { expression: process.env.CDP_PRE_EVAL, awaitPromise: true, returnByValue: true });
    if (r.result && r.result.exceptionDetails) logs.push("[pre-eval] " + JSON.stringify(r.result.exceptionDetails).slice(0, 300));
    else if (r.result && r.result.result && r.result.result.value !== undefined) logs.push("[pre-eval] " + JSON.stringify(r.result.result.value).slice(0, 600));
  }
  await sleep(+postWaitS * 1000);
  const shot = await send("Page.captureScreenshot", { format: "png" });
  fs.writeFileSync(out, Buffer.from(shot.result.data, "base64"));
  console.log("saved", out);
  // CDP_LOG_FILTER=<regex>: print every matching console line instead of the last 40.
  const shown = process.env.CDP_LOG_FILTER ? logs.filter((l) => new RegExp(process.env.CDP_LOG_FILTER).test(l)) : logs.slice(-40);
  for (const l of shown) console.log(l.slice(0, 300));
  ws.close(); proc.kill(); try { fs.rmSync(profile, { recursive: true, force: true }); } catch (_) {}
  process.exit(0);
})().catch((e) => { console.error(e); proc.kill(); process.exit(1); });
