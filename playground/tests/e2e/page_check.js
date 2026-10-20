// page_check.js <url> <text> [seconds] — loads a page in headless Chrome and
// passes when <text> shows on it with nothing having gone wrong on the way:
// no request that failed or answered 4xx/5xx (a module the site forgot to
// ship leaves the page blank, with the only word of it in the console), no
// uncaught exception, no console error. Prints what it saw; exits 1 on a
// failure. Used by run.py for the Playground's "Run on the web" pages.
const { spawn } = require("child_process");
const fs = require("fs");
const [url, text, seconds = "40"] = process.argv.slice(2);
if (!url || !text) { console.error("usage: page_check.js <url> <text> [seconds]"); process.exit(2); }
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = fs.mkdtempSync("/tmp/page-check-");
const port = 9400 + Math.floor(Math.random() * 400);
const proc = spawn(chrome, ["--headless=new", "--disable-gpu", "--use-mock-keychain", "--password-store=basic",
  `--remote-debugging-port=${port}`, "--window-size=412,900", `--user-data-dir=${profile}`, "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const finish = (code) => { proc.kill(); try { fs.rmSync(profile, { recursive: true, force: true }); } catch (_) {} process.exit(code); };
(async () => {
  let targets = null;
  for (let i = 0; i < 50 && !targets; i++) { await sleep(200); try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch (_) {} }
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0; const pending = new Map(); const problems = []; const requests = new Map();
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); return; }
    const p = m.params || {};
    if (m.method === "Network.requestWillBeSent") requests.set(p.requestId, p.request.url);
    if (m.method === "Network.responseReceived" && p.response.status >= 400) problems.push(`HTTP ${p.response.status} ${p.response.url}`);
    if (m.method === "Network.loadingFailed" && !p.canceled) problems.push(`request failed (${p.errorText}) ${requests.get(p.requestId) || ""}`);
    if (m.method === "Runtime.exceptionThrown") problems.push("uncaught: " + ((p.exceptionDetails.exception && p.exceptionDetails.exception.description) || p.exceptionDetails.text).split("\n").slice(0, 3).join(" | "));
    if (m.method === "Log.entryAdded" && p.entry.level === "error") problems.push(`console: ${p.entry.text} ${p.entry.url || ""}`);
  };
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  await send("Page.enable"); await send("Runtime.enable"); await send("Network.enable"); await send("Log.enable");
  await send("Page.navigate", { url });
  let shown = "";
  for (let waited = 0; waited < +seconds * 1000; waited += 500) {
    await sleep(500);
    const r = await send("Runtime.evaluate", { expression: "document.body ? document.body.innerText : ''", returnByValue: true });
    shown = String((r.result.result || {}).value || "");
    if (shown.includes(text)) break;
  }
  // Requests to other hosts (a sample's own network calls) are the sample's
  // business, not the page's: only the page's origin counts.
  const origin = new URL(url).origin;
  // (And not the favicon a browser asks for unprompted.)
  const own = problems.filter((p) => (!/https?:\/\//.test(p) || p.includes(origin)) && !p.includes("/favicon.ico"));
  const ok = shown.includes(text) && own.length === 0;
  console.log(JSON.stringify({ ok, text: shown.includes(text), shown: shown.slice(0, 160).replace(/\n/g, " | "), problems: own }, null, 1));
  ws.close();
  finish(ok ? 0 : 1);
})().catch((e) => { console.error(e); finish(1); });
