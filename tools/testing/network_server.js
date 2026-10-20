// network_server.js — the far end of Foundation's networking checks: an HTTP
// and WebSocket server on a loopback port of its own, Node's standard library
// only (the WebSocket side is RFC 6455's handshake and framing, written out
// here). tests/web_network's network_test drives the web's hosts
// (wasm/libraries/swift_ui/runtime/network.js) against it in the hermetic
// Node; tools/testing/run_network_check.js serves the network probe's site
// from it too, so the page and the server share an origin.
//
//   GET|POST|… /echo        200, the request as JSON: method, url, headers
//                           (lowercased), body (UTF-8); "X-Echo: yes"
//   /status/<code>          that status, body "status <code>"
//   /redirect               302 to /echo?redirected=1
//   /slow?ms=<n>            answers after n ms
//   /drip?parts=<n>&gap=<ms> n parts of the body, gap ms apart (a slow but
//                           steady answer: an idle timeout must not fire)
//   /gzip                   "compressed hello", gzip-encoded
//   /ws/echo (WebSocket)    echoes text and binary messages; the text
//                           "close:<code>:<reason>" makes the server close;
//                           takes the first subprotocol offered
//   /ws/last-close          the code and reason of the last close a client
//                           sent, as JSON
//   anything else           a file of `site`, when given (index.html for /)
//
// Every answer allows any origin (CORS), so a page served elsewhere can
// reach it too.
const crypto = require("crypto");
const fs = require("fs");
const http = require("http");
const path = require("path");
const zlib = require("zlib");

const MIME = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".css": "text/css" };
const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** Starts the server; resolves to { url, port, close() }. */
async function startNetworkServer({ site = null } = {}) {
  let lastClose = null;
  const sockets = new Set();

  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "*",
      "Access-Control-Allow-Methods": "*",
      "Access-Control-Expose-Headers": "*",
    };
    if (request.method === "OPTIONS") {
      response.writeHead(204, cors);
      response.end();
      return;
    }
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const body = Buffer.concat(chunks);
      const send = (status, headers, data) => {
        response.writeHead(status, { ...cors, "Cache-Control": "no-store", ...headers });
        response.end(data);
      };
      if (url.pathname === "/echo") {
        send(200, { "Content-Type": "application/json", "X-Echo": "yes" }, JSON.stringify({
          method: request.method,
          url: request.url,
          headers: request.headers,
          body: body.toString("utf8"),
        }));
      } else if (url.pathname.startsWith("/status/")) {
        const status = Number(url.pathname.slice("/status/".length)) || 500;
        send(status, { "Content-Type": "text/plain" }, `status ${status}`);
      } else if (url.pathname === "/redirect") {
        send(302, { Location: "/echo?redirected=1" }, "");
      } else if (url.pathname === "/slow") {
        const timer = setTimeout(() => send(200, { "Content-Type": "text/plain" }, "slow answer"), Number(url.searchParams.get("ms")) || 1000);
        response.on("close", () => clearTimeout(timer));
      } else if (url.pathname === "/drip") {
        const parts = Number(url.searchParams.get("parts")) || 3;
        const gap = Number(url.searchParams.get("gap")) || 200;
        response.writeHead(200, { ...cors, "Content-Type": "text/plain", "Cache-Control": "no-store" });
        let sent = 0;
        const drip = () => {
          if (response.destroyed) return;
          response.write(`part ${sent};`);
          sent += 1;
          if (sent === parts) response.end();
          else setTimeout(drip, gap);
        };
        setTimeout(drip, gap);
      } else if (url.pathname === "/gzip") {
        send(200, { "Content-Type": "text/plain", "Content-Encoding": "gzip" }, zlib.gzipSync("compressed hello"));
      } else if (url.pathname === "/ws/last-close") {
        send(200, { "Content-Type": "application/json" }, JSON.stringify(lastClose));
      } else if (site) {
        const file = path.join(site, url.pathname === "/" ? "index.html" : decodeURIComponent(url.pathname));
        if (!file.startsWith(site)) { send(403, {}, ""); return; }
        fs.readFile(file, (error, data) => {
          if (error) send(404, { "Content-Type": "text/plain" }, "no such file");
          else send(200, { "Content-Type": MIME[path.extname(file)] || "application/octet-stream" }, data);
        });
      } else {
        send(404, { "Content-Type": "text/plain" }, "no such file");
      }
    });
  });

  server.on("upgrade", (request, socket) => {
    const url = new URL(request.url, "http://localhost");
    const key = request.headers["sec-websocket-key"];
    if (url.pathname !== "/ws/echo" || !key) {
      socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      return;
    }
    const accept = crypto.createHash("sha1").update(key + WEBSOCKET_GUID).digest("base64");
    const offered = String(request.headers["sec-websocket-protocol"] || "").split(",").map((p) => p.trim()).filter(Boolean);
    socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
      ...(offered.length ? [`Sec-WebSocket-Protocol: ${offered[0]}`] : []),
      "", "",
    ].join("\r\n"));
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    serveWebSocket(socket, (code, reason) => { lastClose = { code, reason }; });
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  return {
    port,
    url: `http://127.0.0.1:${port}`,
    close() {
      for (const socket of sockets) socket.destroy();
      server.closeAllConnections();
      return new Promise((resolve) => server.close(resolve));
    },
  };
}

/** One WebSocket connection, after the handshake: echoes messages, answers
 *  pings and closes, and closes when asked to by "close:<code>:<reason>".
 *  `onClientClose(code, reason)` hears each close the client starts. */
function serveWebSocket(socket, onClientClose) {
  let buffer = Buffer.alloc(0);
  let fragments = [];
  let fragmentOpcode = 0;
  let closing = false;

  const frame = (opcode, payload) => {
    const length = payload.length;
    const head = length < 126 ? Buffer.from([0x80 | opcode, length])
      : length < 65536 ? Buffer.from([0x80 | opcode, 126, length >> 8, length & 0xff])
      : Buffer.concat([Buffer.from([0x80 | opcode, 127]), (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(length)); return b; })()]);
    if (!socket.destroyed) socket.write(Buffer.concat([head, payload]));
  };
  const closeFrame = (code, reason) => {
    const reasonBytes = Buffer.from(reason || "", "utf8");
    const payload = Buffer.alloc(2 + reasonBytes.length);
    payload.writeUInt16BE(code, 0);
    reasonBytes.copy(payload, 2);
    frame(0x8, payload);
  };

  const message = (opcode, payload) => {
    if (opcode === 0x1) {
      const text = payload.toString("utf8");
      const asked = /^close:(\d+):(.*)$/s.exec(text);
      if (asked) {
        closing = true;
        closeFrame(Number(asked[1]), asked[2]);
        // The client answers with its close; end then, or soon regardless.
        setTimeout(() => socket.end(), 1000);
        return;
      }
      frame(0x1, payload);
    } else {
      frame(0x2, payload);
    }
  };

  socket.on("data", (data) => {
    buffer = Buffer.concat([buffer, data]);
    for (;;) {
      if (buffer.length < 2) return;
      const fin = (buffer[0] & 0x80) !== 0;
      const opcode = buffer[0] & 0x0f;
      const masked = (buffer[1] & 0x80) !== 0;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        length = Number(buffer.readBigUInt64BE(2));
        offset = 10;
      }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (buffer.length < offset + length) return;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (masked) {
        for (let i = 0; i < payload.length; i++) payload[i] ^= buffer[maskOffset + (i % 4)];
      }
      buffer = buffer.subarray(offset + length);

      if (opcode === 0x8) {
        // A close: the client's own (recorded and answered), or its answer
        // to ours.
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
        const reason = payload.length > 2 ? payload.subarray(2).toString("utf8") : "";
        if (!closing) {
          onClientClose(code, reason);
          closeFrame(code === 1005 ? 1000 : code, "");
        }
        socket.end();
        return;
      } else if (opcode === 0x9) {
        frame(0xA, payload);
      } else if (opcode === 0xA) {
        // A pong: nothing to do.
      } else if (opcode === 0x0) {
        fragments.push(payload);
        if (fin) {
          message(fragmentOpcode, Buffer.concat(fragments));
          fragments = [];
        }
      } else if (fin) {
        message(opcode, payload);
      } else {
        fragmentOpcode = opcode;
        fragments = [payload];
      }
    }
  });
}

module.exports = { startNetworkServer };

// `node network_server.js [site]`: serve until interrupted.
if (require.main === module) {
  startNetworkServer({ site: process.argv[2] ? path.resolve(process.argv[2]) : null }).then((server) => {
    console.log(`network server at ${server.url}`);
    const stop = () => server.close().then(() => process.exit(0));
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
  });
}
