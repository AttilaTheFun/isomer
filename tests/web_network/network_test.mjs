// Foundation's networking on the web (wasm/libraries/swift_ui/runtime/
// network.js) in Node, with no browser: the HTTP and WebSocket hosts the
// guest's URLSession runs over, called as the generated dispatchers call
// them, against tools/testing/network_server.js on a loopback port. Node's
// fetch and WebSocket are the browser's APIs (Node's fetch also sends the
// header fields a browser keeps for itself, so the hosts' filtering shows
// here). URLSession over them in a real page: run_network_check.js.

import net from "node:net";
import { browserNetworkHosts, createHTTPHost, createWebSocketHost } from "./network.js";
import { startNetworkServer } from "./network_server.js";

const server = await startNetworkServer();
const base = server.url;
const wsBase = base.replace("http:", "ws:");
const decoder = new TextDecoder();
const encoder = new TextEncoder();

let failures = 0;
function check(name, found, expected) {
  const ok = JSON.stringify(found) === JSON.stringify(expected);
  if (!ok) failures += 1;
  console.log(ok ? `ok ${name}` : `FAIL ${name}: ${JSON.stringify(found)}, expected ${JSON.stringify(expected)}`);
}
// The reason a failed call names ("timedOut", …), or "answered". Called as
// the generated dispatcher calls an async method: a throw is a rejection.
async function reason(call) {
  try {
    await Promise.resolve().then(call);
    return "answered";
  } catch (error) {
    return String(error.message).split(":")[0];
  }
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// --- HTTP --------------------------------------------------------------------

const httpHost = createHTTPHost();
const fields = (pairs) => JSON.stringify(pairs);
const echo = (answer) => JSON.parse(decoder.decode(answer.body));
const header = (answer, name) => (JSON.parse(answer.headers).find(([n]) => n === name) || [])[1];

{
  const answer = await httpHost.send("GET", `${base}/echo`,
    fields([["X-Probe", "probe value"], ["Cookie", "kept=no"], ["Host", "elsewhere"], ["Sec-Fetch-Mode", "no"]]),
    new Uint8Array(0), 5);
  const request = echo(answer);
  check("GET answers", answer.status, 200);
  check("GET sends the app's field", request.headers["x-probe"], "probe value");
  check("GET leaves out Cookie", request.headers.cookie, undefined);
  check("GET leaves out Host's value", request.headers.host, base.slice("http://".length));
  check("GET answer's field", header(answer, "x-echo"), "yes");
  check("GET answer's content type", header(answer, "content-type"), "application/json");
  check("GET from the request's own URL", answer.url, "");
}
{
  const answer = await httpHost.send("POST", `${base}/echo`, fields([["Content-Type", "text/plain"]]),
    encoder.encode("hello body"), 5);
  const request = echo(answer);
  check("POST method", request.method, "POST");
  check("POST body", request.body, "hello body");
  check("POST content type", request.headers["content-type"], "text/plain");
}
{
  const answer = await httpHost.send("GET", `${base}/echo`, "[]", encoder.encode("dropped"), 5);
  check("GET sends no body", echo(answer).body, "");
}
{
  const answer = await httpHost.send("HEAD", `${base}/echo`, "[]", new Uint8Array(0), 5);
  check("HEAD answers without a body", [answer.status, answer.body.length], [200, 0]);
}
{
  const answer = await httpHost.send("GET", `${base}/status/404`, "[]", new Uint8Array(0), 5);
  check("404 is an answer", [answer.status, decoder.decode(answer.body)], [404, "status 404"]);
}
{
  const answer = await httpHost.send("GET", `${base}/redirect`, "[]", new Uint8Array(0), 5);
  check("redirect followed", [answer.status, echo(answer).url], [200, "/echo?redirected=1"]);
  check("redirect's URL", answer.url, `${base}/echo?redirected=1`);
}
{
  const answer = await httpHost.send("GET", `${base}/gzip`, "[]", new Uint8Array(0), 5);
  check("gzip undone", decoder.decode(answer.body), "compressed hello");
}
check("a slow server times out",
  await reason(() => httpHost.send("GET", `${base}/slow?ms=3000`, "[]", new Uint8Array(0), 0.3)), "timedOut");
{
  // 4 parts 200 ms apart, 0.5 s allowed: the clock restarts with each part.
  const answer = await httpHost.send("GET", `${base}/drip?parts=4&gap=200`, "[]", new Uint8Array(0), 0.5);
  check("a steady answer outlasts its timeout", decoder.decode(answer.body), "part 0;part 1;part 2;part 3;");
}
check("a refused connection",
  await reason(() => httpHost.send("GET", "http://127.0.0.1:1/", "[]", new Uint8Array(0), 5)), "cannotConnectToHost");
check("a method fetch refuses",
  await reason(() => httpHost.send("CONNECT", `${base}/echo`, "[]", new Uint8Array(0), 5)), "unknown");

// --- WebSocket ---------------------------------------------------------------

const sockets = createWebSocketHost();
{
  const id = await sockets.open(`${wsBase}/ws/echo`, JSON.stringify(["probe.v1", "other"]),
    fields([["X-Left-Out", "yes"]]), 5);
  check("subprotocol chosen", sockets.subprotocol(id), "probe.v1");
  await sockets.sendText(id, "hello");
  check("text echoed", await sockets.next(id), { kind: 0, text: "hello", data: new Uint8Array(0), code: 0 });
  await sockets.sendData(id, new Uint8Array([1, 2, 3]));
  const data = await sockets.next(id);
  check("data echoed", [data.kind, [...data.data]], [1, [1, 2, 3]]);
  // Queued until asked for, in order.
  for (const text of ["one", "two", "three"]) await sockets.sendText(id, text);
  await sleep(200);
  const queued = [];
  for (let i = 0; i < 3; i++) queued.push((await sockets.next(id)).text);
  check("messages queued in order", queued, ["one", "two", "three"]);
  await sockets.sendText(id, "close:1001:bye");
  const closed = await sockets.next(id);
  check("the server's close", [closed.kind, closed.code, closed.text], [2, 1001, "bye"]);
  check("the close again", (await sockets.next(id)).code, 1001);
  check("sending after the close", await reason(() => sockets.sendText(id, "late")), "networkConnectionLost");
}
{
  const id = await sockets.open(`${wsBase}/ws/echo`, "[]", "[]", 5);
  check("no subprotocol", sockets.subprotocol(id), "");
  const waiting = sockets.next(id);
  sockets.disconnect(id, 1000, "done");
  const closed = await waiting;
  check("a waiting next answers with the app's close", [closed.kind, closed.code, closed.text], [2, 1000, "done"]);
  await sleep(300);
  check("the server heard the close", JSON.parse(decoder.decode(
    (await httpHost.send("GET", `${base}/ws/last-close`, "[]", new Uint8Array(0), 5)).body)), { code: 1000, reason: "done" });
}
{
  // 1001 is not a code a page may send: 1000 goes, the app keeps its own.
  const id = await sockets.open(`${wsBase}/ws/echo`, "[]", "[]", 5);
  sockets.disconnect(id, 1001, "x".repeat(10));
  check("the app's code stays the connection's", (await sockets.next(id)).code, 1001);
  await sleep(300);
  check("1000 sent for 1001", JSON.parse(decoder.decode(
    (await httpHost.send("GET", `${base}/ws/last-close`, "[]", new Uint8Array(0), 5)).body)).code, 1000);
}
{
  // A reason over 123 bytes is cut at a character's end.
  const id = await sockets.open(`${wsBase}/ws/echo`, "[]", "[]", 5);
  sockets.disconnect(id, 1000, "é".repeat(100));
  await sleep(300);
  check("a long reason cut to 123 bytes", JSON.parse(decoder.decode(
    (await httpHost.send("GET", `${base}/ws/last-close`, "[]", new Uint8Array(0), 5)).body)).reason, "é".repeat(61));
}
check("a refused WebSocket",
  await reason(() => sockets.open("ws://127.0.0.1:1/ws/echo", "[]", "[]", 5)), "cannotConnectToHost");
{
  // A server that takes the connection and never answers the handshake.
  const silent = net.createServer(() => {});
  await new Promise((resolve) => silent.listen(0, "127.0.0.1", resolve));
  check("a WebSocket that never opens times out",
    await reason(() => sockets.open(`ws://127.0.0.1:${silent.address().port}/`, "[]", "[]", 0.3)), "timedOut");
  silent.close();
}
check("an unknown connection", await reason(() => sockets.next(999)), "networkConnectionLost");

// --- Injection ---------------------------------------------------------------

{
  const builders = {
    hTTPHost: (provide) => ({ key: "http", provide }),
    webSocketHost: (provide) => ({ key: "ws", provide }),
  };
  const injected = browserNetworkHosts(builders);
  check("injected under Isomer's keys", Object.keys(injected), ["isomerHTTP", "isomerWebSocket"]);
  check("injected hosts", [typeof injected.isomerHTTP.provide().send, typeof injected.isomerWebSocket.provide().open],
    ["function", "function"]);
  check("no builders, nothing injected", browserNetworkHosts({}), {});
}

// --- A page's own fetch and WebSocket (boot({ fetch, WebSocket })) -----------

{
  // A page routing through its own endpoint: here, the server's /echo for
  // whatever URL the app asked for.
  const asked = [];
  const proxied = createHTTPHost({
    fetch: (url, init) => {
      asked.push(url);
      return globalThis.fetch(`${base}/echo`, init);
    },
  });
  const answer = await proxied.send("GET", "https://api.example.invalid/v1/models", fields([]), new Uint8Array(0), 5);
  check("a page's fetch is asked", asked, ["https://api.example.invalid/v1/models"]);
  check("a page's fetch answers", answer.status, 200);
  const made = [];
  class PageSocket {
    constructor(url, protocols) {
      made.push(url);
      throw new Error("refused by the page");
    }
  }
  const pageSockets = createWebSocketHost({ WebSocket: PageSocket });
  check("a page's WebSocket is made", [await reason(() => pageSockets.open("wss://elsewhere.invalid/socket", "[]", "[]", 2)), made],
    ["cannotConnectToHost", ["wss://elsewhere.invalid/socket"]]);
}

await server.close();
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);
