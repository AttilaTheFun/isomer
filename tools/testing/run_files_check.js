// run_files_check.js <site directory> — the web's app files end to end
// (wasm/libraries/swift_ui/runtime/file_system.js), through the files probe
// (examples/web/files_probe_web_application). Serves the probe's site on a
// loopback port of its own, loads it in headless Chrome with a fresh
// profile, and checks across reloads that what the app wrote under its home
// is there again and /tmp is not, that a write made just before a reload
// survives it, that IndexedDB holds a record per file (and none for what
// was removed), that another app on the origin has a home of its own, that
// without IndexedDB the app runs on in memory with one warning, and that
// what a page couldn't write to IndexedDB reaches the next load through the
// localStorage journal. Prints what the probe reported; exits 1 on a
// failure. The server and Chrome are stopped either way.
const { spawn } = require("child_process");
const fs = require("fs");
const http = require("http");
const path = require("path");

const [siteArgument] = process.argv.slice(2);
if (!siteArgument) {
  console.error("usage: run_files_check.js <site directory>");
  process.exit(2);
}
const site = path.resolve(siteArgument);
// CDP_CHROME names another Chrome (Linux's, a Chromium) than the Mac's.
const chrome = process.env.CDP_CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PROBE = "dev.isomer.examples.files-probe";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const MIME = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };
const server = http.createServer((request, response) => {
  const urlPath = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  const file = path.join(site, urlPath === "/" ? "index.html" : urlPath);
  if (!file.startsWith(site)) { response.writeHead(403); response.end(); return; }
  fs.readFile(file, (error, data) => {
    if (error) { response.writeHead(404); response.end(); return; }
    response.writeHead(200, { "Content-Type": MIME[path.extname(file)] || "application/octet-stream", "Cache-Control": "no-store" });
    response.end(data);
  });
});

const profile = fs.mkdtempSync("/tmp/files-check-profile-");
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
  server.closeAllConnections();
  server.close();
  fs.rmSync(profile, { recursive: true, force: true });
  process.exit(code);
}

(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}/`;
  // Port 0: Chrome picks its own and says which in the profile. A window
  // tall enough for every line of the probe's report: its list draws only
  // the rows on screen, and the checks read the page's text.
  browser = spawn(chrome, ["--headless=new", "--use-mock-keychain", "--password-store=basic", "--no-first-run",
    "--window-size=800,4000", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"], { stdio: "ignore" });
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
  const warnings = [];
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
    if (message.method === "Runtime.consoleAPICalled" && message.params.type === "warning") {
      warnings.push(message.params.args.map((a) => a.value ?? a.description).join(" "));
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

  // The probe's lines once a new page shows `launch <n>` (its text: the
  // React renderer draws each Text as DOM text). A page read once is marked,
  // so the one before a navigation isn't taken for the next.
  const launch = async (n, what) => {
    let lines = [];
    for (let i = 0; i < 600; i++) {
      await sleep(100);
      const text = await evaluate("window.__filesCheckRead ? '' : document.body ? document.body.innerText : ''");
      lines = String(text || "").split("\n").map((line) => line.trim())
        .filter((line) => /^(ok |FAIL |launch |late write kept)/.test(line));
      if (lines.some((line) => /^launch \d+$/.test(line))) {
        await evaluate("window.__filesCheckRead = true");
        break;
      }
    }
    console.log(`${what}:`);
    for (const line of lines) console.log(`  ${line}`);
    expect(lines.includes(`launch ${n}`), `${what}: launch ${n}`);
    expect(lines.length > 1 && !lines.some((line) => line.startsWith("FAIL")), `${what}: every check passes`);
    return lines;
  };

  await send("Page.navigate", { url: base });
  await launch(1, "first load");

  // A write the moment before the page goes (the probe's button), then the
  // reload: the page leaving writes it.
  const tapped = await evaluate(`(() => {
    const button = [...document.querySelectorAll("[data-tap]")].find((el) => el.textContent.trim() === "Write late");
    if (!button) return false;
    button.click();
    location.reload();
    return true;
  })()`);
  expect(tapped, "tapped Write late and reloaded");
  const second = await launch(2, "after a reload");
  expect(second.includes("late write kept: late 1"), "the write before the reload was kept");

  await send("Page.reload");
  await launch(3, "after another reload");

  // One record per file and directory under HOME (a file's bytes are block
  // records beside it, [key, path, number]); none for what was removed or
  // moved away, nothing of /tmp.
  const keys = await evaluate(`new Promise((resolve, reject) => {
    const request = indexedDB.open("isomer-files");
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const keys = request.result.transaction("files").objectStore("files")
        .getAllKeys(IDBKeyRange.bound([${JSON.stringify(PROBE)}], [${JSON.stringify(PROBE)}, []]));
      keys.onsuccess = () => resolve(keys.result.filter((key) => key.length === 2).map((key) => key[1]));
    };
  })`);
  console.log(`records: ${(keys || []).join(", ")}`);
  for (const expected of ["Documents/launches.txt", "Documents/late.txt", "Documents/log.txt", "Documents/notes",
    "Documents/notes/a.txt", "Documents/notes/b.txt", "Library/Application Support/probe.sqlite", "Library/Application Support/support.txt", "Library/Caches/cache.txt"]) {
    expect((keys || []).includes(expected), `a record for ${expected}`);
  }
  for (const gone of ["Documents/notes/c.txt", "Documents/notes/moving.txt", "Documents/tree"]) {
    expect(!(keys || []).some((key) => key === gone || key.startsWith(`${gone}/`)), `no record for ${gone}`);
  }

  // Another app on the origin starts with a home of its own.
  await send("Page.navigate", { url: `${base}?bundle=dev.isomer.examples.other` });
  await launch(1, "another app");

  // Without IndexedDB: the files live in memory, with one warning.
  const { identifier } = (await send("Page.addScriptToEvaluateOnNewDocument", {
    source: "Object.defineProperty(window, 'indexedDB', { value: undefined, configurable: true })",
  })).result;
  warnings.length = 0;
  await send("Page.navigate", { url: base });
  await launch(1, "without IndexedDB");
  const storageWarnings = warnings.filter((warning) => warning.includes("[files]"));
  expect(storageWarnings.length === 1, `one warning without IndexedDB (${storageWarnings.length}: ${storageWarnings.join(" | ")})`);
  await send("Page.removeScriptToEvaluateOnNewDocument", { identifier });

  // And the run in memory left the kept files as they were.
  await send("Page.navigate", { url: base });
  await launch(4, "with IndexedDB again");

  // A page whose writes to IndexedDB all fail leaves its changes in the
  // localStorage journal, and the next load writes them on.
  const refused = (await send("Page.addScriptToEvaluateOnNewDocument", {
    source: `{
      const transaction = IDBDatabase.prototype.transaction;
      IDBDatabase.prototype.transaction = function (stores, mode, options) {
        if (mode === "readwrite") throw new DOMException("refused by the check", "QuotaExceededError");
        return transaction.call(this, stores, mode, options);
      };
    }`,
  })).result.identifier;
  warnings.length = 0;
  await send("Page.navigate", { url: base });
  await launch(5, "IndexedDB refusing writes");
  await sleep(1000); // the write behind fails
  expect(warnings.some((warning) => warning.includes("could not write")), "the failed write warned");
  await send("Page.removeScriptToEvaluateOnNewDocument", { identifier: refused });
  // Launch 6 only if the journal carried launch 5's count.
  await send("Page.navigate", { url: `${base}?after-refusal` });
  await launch(6, "after the refused writes");
  await sleep(1000); // the journal written on
  expect(await evaluate(`localStorage.getItem("isomer-files:${PROBE}") === null`), "the journal is gone once written on");
  await send("Page.reload");
  await launch(7, "from IndexedDB alone");

  socket.close();
  console.log(failures ? `${failures} failed` : "all passed");
  await finish(failures ? 1 : 0);
})().catch(async (error) => {
  console.error(error);
  await finish(1);
});
