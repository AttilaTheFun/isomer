// run_network_check.js <site directory> — Foundation's networking on the web
// end to end: URLSession in a page, over the page's fetch and WebSocket
// (wasm/libraries/swift_ui/runtime/network.js), through the network probe
// (examples/web/network_probe_web_application). Serves the probe's site from
// network_server.js, whose HTTP and WebSocket endpoints the probe checks
// against at the page's own origin, loads it in headless Chrome with a fresh
// profile, waits for the probe's "done" line, and prints what it reported;
// then once more with the browser offline (Network.emulateNetworkConditions),
// where a request fails as on a device without a network. Exits 1 on a
// failure. The server and Chrome are stopped either way.
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const { startNetworkServer } = require("./network_server.js");

const [siteArgument] = process.argv.slice(2);
if (!siteArgument) {
  console.error("usage: run_network_check.js <site directory>");
  process.exit(2);
}
const site = path.resolve(siteArgument);
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const profile = fs.mkdtempSync("/tmp/network-check-profile-");
let server = null;
let browser = null;
let failures = 0;
const expect = (condition, message) => {
  console.log(`${condition ? "ok" : "FAIL"} ${message}`);
  if (!condition) failures += 1;
};

async function finish(code) {
  if (browser) {
    const exited = new Promise((resolve) => browser.once("exit", resolve));
    browser.kill();
    await Promise.race([exited, sleep(5000)]);
  }
  if (server) await server.close();
  fs.rmSync(profile, { recursive: true, force: true });
  process.exit(code);
}

(async () => {
  server = await startNetworkServer({ site });
  const base = `${server.url}/`;
  // Port 0: Chrome picks its own and says which in the profile.
  browser = spawn(chrome, ["--headless=new", "--use-mock-keychain", "--password-store=basic", "--no-first-run",
    "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"], { stdio: "ignore" });
  let port = null;
  for (let i = 0; i < 100 && !port; i++) {
    await sleep(100);
    try { port = fs.readFileSync(`${profile}/DevToolsActivePort`, "utf8").split("\n")[0]; } catch (_) {}
  }
  let targets = null;
  for (let i = 0; i < 50 && !targets; i++) {
    try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch (_) { await sleep(100); }
  }
  const page = targets.find((target) => target.type === "page");
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve) => (socket.onopen = resolve));
  let id = 0;
  const pending = new Map();
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
    if (message.method === "Runtime.exceptionThrown") {
      console.log("  exception:", message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
    }
  };
  const send = (method, params = {}) => new Promise((resolve) => {
    const n = ++id;
    pending.set(n, resolve);
    socket.send(JSON.stringify({ id: n, method, params }));
  });
  const evaluate = async (expression) => {
    const answer = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    return answer.result.result?.value;
  };
  await send("Page.enable");
  await send("Runtime.enable");
  await send("Network.enable");

  // The probe's lines (its Texts, drawn as DOM text by the React renderer)
  // once it says "done", or what there is after a minute.
  const run = async (what) => {
    let lines = [];
    for (let i = 0; i < 600; i++) {
      await sleep(100);
      const text = await evaluate("document.body ? document.body.innerText : ''");
      lines = String(text || "").split("\n").map((line) => line.trim())
        .filter((line) => /^(ok |FAIL |done: )/.test(line));
      if (lines.some((line) => line.startsWith("done: "))) break;
    }
    console.log(`${what}:`);
    for (const line of lines) console.log(`  ${line}`);
    return lines;
  };

  await send("Page.navigate", { url: base });
  const online = await run("online");
  expect(online.some((line) => line.startsWith("done: ")), "the probe finished");
  expect(online.length > 10 && !online.some((line) => line.startsWith("FAIL")), "every check passes");

  // Offline: the page's requests fail as a device's without a network do.
  // (The module is loaded first: offline, it could not be.)
  await evaluate(`import("./runtime/network.js").then((module) => { window.__networkCheck = module; })`);
  await send("Network.emulateNetworkConditions", { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  const offline = await evaluate(`(async () => {
    try {
      await window.__networkCheck.createHTTPHost().send("GET", location.origin + "/echo", "[]", new Uint8Array(0), 5);
      return "answered";
    } catch (error) {
      return error.message;
    }
  })()`);
  console.log(`offline: ${offline}`);
  expect(String(offline).startsWith("notConnectedToInternet:"), "offline is notConnectedToInternet");

  socket.close();
  console.log(failures ? `${failures} failed` : "all passed");
  await finish(failures ? 1 : 0);
})().catch(async (error) => {
  console.error(error);
  await finish(1);
});
