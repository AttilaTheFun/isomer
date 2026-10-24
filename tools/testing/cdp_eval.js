// cdp_eval.js <url> <waitSeconds> <expression> — loads the page in headless
// Chrome and prints the awaited result of an expression (the page's dev
// hooks, e.g. window.__playgroundHost.uiTree()).
const { spawn } = require("child_process");
const fs = require("fs");
const [url, waitS = "10", expression = "1"] = process.argv.slice(2);
// CDP_CHROME names another Chrome (Linux's, a Chromium) than the Mac's.
const chrome = process.env.CDP_CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = fs.mkdtempSync("/tmp/cdp-profile-");
const port = 9333 + Math.floor(Math.random() * 500);
const proc = spawn(chrome, ["--headless=new", "--disable-gpu", "--use-mock-keychain", "--password-store=basic", `--remote-debugging-port=${port}`, "--window-size=1200,800", `--user-data-dir=${profile}`, "--no-first-run", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  let targets = null;
  for (let i = 0; i < 50 && !targets; i++) { await sleep(200); try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch (_) {} }
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0; const pending = new Map();
  ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  await send("Page.enable"); await send("Runtime.enable");
  await send("Page.navigate", { url });
  await sleep(+waitS * 1000);
  const result = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true, timeout: 120000 });
  console.log(result.result.exceptionDetails ? "EXCEPTION " + JSON.stringify(result.result.exceptionDetails.exception?.description || result.result.exceptionDetails.text) : String(result.result.result.value));
  ws.close(); proc.kill(); try { fs.rmSync(profile, { recursive: true, force: true }); } catch (_) {}
  process.exit(0);
})().catch((e) => { console.error(e); proc.kill(); process.exit(1); });
