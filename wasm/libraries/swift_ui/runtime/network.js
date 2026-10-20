// Foundation's networking on the web: the browser's `fetch` and `WebSocket`
// as the hosts IsomerNetworkHost declares (shared/isomer_network_host/
// NetworkHost.swift), which the guest installs as the transports `URLSession`
// sends its work through. boot.js (and so mountIsomer and `<Isomer>`) and
// hot_host.js inject them under `isomerHTTP` and `isomerWebSocket`, wrapped
// with the page's generated `Dependencies` builders; a page's own entry under
// either key replaces them. A page that must route requests through its own
// endpoint (an API that sends no CORS headers, reached through the page's
// server) gives boot() a `fetch` (fetch's signature) and a `WebSocket` (the
// constructor's) to use instead of the browser's.
//
// A failure to get any answer rejects with a message that starts with the
// reason Foundation turns into the app's `URLError` ("timedOut: …",
// "cannotConnectToHost: …"); an answer with an error status is an answer.
// What a page cannot do that an app's URLSession can:
//   - tell the failures apart: `fetch` says only that it failed, alike for a
//     name with no address, a refused connection, a bad certificate and a
//     server that did not allow this page's origin (CORS), so all of them
//     are cannotConnectToHost;
//   - send the header fields browsers keep for themselves (Host, Cookie,
//     Content-Length, Origin, Sec-*, …: FORBIDDEN_HEADERS), or read the ones
//     a cross-origin answer does not expose (Set-Cookie always);
//   - give a WebSocket header fields, or close one with a code other than
//     1000 or 3000 to 4999 (1000 goes instead);
//   - stop an exchange the app cancelled: the interface has no cancel, so
//     the answer arrives and Foundation drops it.

// Header fields a page's `fetch` may not set (the Fetch standard's
// forbidden request-header names, lowercased), besides any starting with
// "proxy-" or "sec-". They are left out; browsers ignore them, but other
// fetches (Node's, under Electron's main process) throw.
const FORBIDDEN_HEADERS = new Set([
  "accept-charset", "accept-encoding", "access-control-request-headers",
  "access-control-request-method", "connection", "content-length", "cookie",
  "cookie2", "date", "dnt", "expect", "host", "keep-alive", "origin",
  "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade",
  "via",
]);

// Methods `fetch` refuses outright.
const FORBIDDEN_METHODS = new Set(["CONNECT", "TRACE", "TRACK"]);

// WebSocketHostEvent's kinds.
const TEXT = 0, DATA = 1, CLOSED = 2;
const EMPTY = new Uint8Array(0);

/** The page's networking as the injected dependencies the guest's runtime
 *  installs (`installInjectedNetworkHosts`), built with `Dependencies`, the
 *  generated builders of the page's bindings (app_bridge.js). Empty when
 *  the bindings have none (a module without IsomerNetworkHost). */
export function browserNetworkHosts(Dependencies, { fetch, WebSocket } = {}) {
  if (!Dependencies || !Dependencies.hTTPHost || !Dependencies.webSocketHost) return {};
  return {
    isomerHTTP: Dependencies.hTTPHost(() => createHTTPHost({ fetch })),
    isomerWebSocket: Dependencies.webSocketHost(() => createWebSocketHost({ WebSocket })),
  };
}

/** `HTTPHost` over `fetch`: the page's own when it gave one, the browser's
 *  otherwise. */
export function createHTTPHost({ fetch: pageFetch } = {}) {
  const send = pageFetch || ((url, init) => globalThis.fetch(url, init));
  return {
    async send(method, url, headers, body, timeout) {
      const name = String(method || "GET").toUpperCase();
      if (FORBIDDEN_METHODS.has(name)) throw new Error(`unknown: a page cannot send ${name} requests`);
      // URLSession's timeout is how long the exchange may wait on the
      // server, to connect or for more of its response: the clock starts
      // again with every part of the body that arrives.
      const controller = new AbortController();
      let timedOut = false;
      let timer = 0;
      const wait = () => {
        clearTimeout(timer);
        if (timeout > 0 && Number.isFinite(timeout)) {
          timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeout * 1000);
        }
      };
      const init = {
        method: name,
        headers: requestHeaders(headers),
        redirect: "follow",
        signal: controller.signal,
      };
      if (body && body.length && name !== "GET" && name !== "HEAD") init.body = body;
      wait();
      let response;
      try {
        response = await send(url, init);
      } catch (error) {
        clearTimeout(timer);
        throw failure(error, timedOut, timeout, "cannotConnectToHost");
      }
      let bytes;
      try {
        bytes = await readBody(response, wait);
      } catch (error) {
        // The answer began and broke off.
        throw failure(error, timedOut, timeout, "networkConnectionLost");
      } finally {
        clearTimeout(timer);
      }
      return {
        status: response.status,
        // Lowercased names, a repeated field's values joined: what the
        // browser exposes of them.
        headers: JSON.stringify([...response.headers]),
        body: bytes,
        url: response.redirected ? response.url : "",
      };
    },
  };
}

/** The request's header fields as `fetch` takes them: the forbidden ones
 *  left out, and any the browser rejects as malformed (with a warning). */
function requestHeaders(json) {
  const headers = new Headers();
  let fields = [];
  try { fields = JSON.parse(json || "[]"); } catch (_) { /* none */ }
  for (const field of fields) {
    if (!Array.isArray(field) || field.length !== 2) continue;
    const [name, value] = field;
    const lower = String(name).toLowerCase();
    if (FORBIDDEN_HEADERS.has(lower) || lower.startsWith("proxy-") || lower.startsWith("sec-")) continue;
    try {
      headers.append(name, value);
    } catch (error) {
      console.warn(`[network] header field ${name} left out:`, error.message);
    }
  }
  return headers;
}

/** The whole body, read a part at a time so `progress` (the timeout's
 *  clock) hears of each. */
async function readBody(response, progress) {
  if (!response.body) return new Uint8Array(await response.arrayBuffer());
  const reader = response.body.getReader();
  const parts = [];
  let length = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    progress();
    parts.push(value);
    length += value.length;
  }
  if (parts.length === 1) return parts[0];
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  return bytes;
}

/** What a failed exchange reports: the reason first, then the browser's
 *  words. `otherwise` is the reason for a failure the browser doesn't
 *  explain. */
function failure(error, timedOut, timeout, otherwise) {
  const message = error && error.message ? error.message : String(error);
  if (timedOut) return new Error(`timedOut: no answer in ${timeout} s`);
  if (error && error.name === "AbortError") return new Error(`cancelled: ${message}`);
  if (typeof navigator !== "undefined" && navigator.onLine === false) {
    return new Error(`notConnectedToInternet: the browser is offline (${message})`);
  }
  if (otherwise === "cannotConnectToHost") {
    // "Failed to fetch" (Chrome), "Load failed" (Safari), "NetworkError
    // when attempting to fetch resource" (Firefox): no more is told.
    return new Error(`cannotConnectToHost: ${message} (no answer, or one this page's origin may not read)`);
  }
  return new Error(`${otherwise}: ${message}`);
}

/** `WebSocketHost` over the browser's `WebSocket`. Each connection keeps
 *  what arrives in a queue until `next` takes it; once closed, `next`
 *  answers with the close every time, so a closed connection's record (its
 *  close and any messages not yet taken) stays for the guest to ask. */
export function createWebSocketHost({ WebSocket: PageWebSocket } = {}) {
  const Socket = PageWebSocket || globalThis.WebSocket;
  const connections = new Map();
  let lastID = 0;

  // A message or the close, to the call waiting for one or the queue.
  const deliver = (connection, event) => {
    const waiter = connection.waiting.shift();
    if (waiter) waiter(event);
    else connection.events.push(event);
  };

  // The connection is closed: the close goes after what is queued, to
  // every call waiting (none waits while anything is queued), and to every
  // later `next`. The browser's socket is let go.
  const finish = (connection, code, reason) => {
    if (connection.closed) return;
    connection.closed = { kind: CLOSED, text: reason, data: EMPTY, code };
    for (const waiter of connection.waiting.splice(0)) waiter(connection.closed);
    const { socket } = connection;
    socket.onopen = socket.onmessage = socket.onerror = socket.onclose = null;
    connection.socket = null;
  };

  // The connection to send on, while it is open.
  const live = (id) => {
    const connection = connections.get(id);
    if (!connection || connection.closed || connection.socket.readyState !== WebSocket.OPEN) {
      throw new Error("networkConnectionLost: the WebSocket is closed");
    }
    return connection;
  };

  return {
    open(url, protocols, headers, timeout) {
      // `headers` cannot be sent: a page's WebSocket takes a URL and
      // subprotocols, nothing more. They are left out, as
      // WebSocketTransportRequest says.
      void headers;
      let offered = [];
      try { offered = JSON.parse(protocols || "[]"); } catch (_) { /* none */ }
      return new Promise((resolve, reject) => {
        let socket;
        try {
          socket = new Socket(url, offered);
        } catch (error) {
          // A URL or a subprotocol the browser won't take.
          reject(new Error(`cannotConnectToHost: ${error.message}`));
          return;
        }
        socket.binaryType = "arraybuffer";
        const id = ++lastID;
        const connection = { socket, protocol: "", events: [], waiting: [], closed: null };
        let settled = false;
        const refuse = (message) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          socket.onopen = socket.onmessage = socket.onerror = socket.onclose = null;
          if (socket.readyState === WebSocket.CONNECTING || socket.readyState === WebSocket.OPEN) socket.close();
          reject(new Error(navigator.onLine === false
            ? `notConnectedToInternet: the browser is offline (${message})` : message));
        };
        const timer = timeout > 0 && Number.isFinite(timeout)
          ? setTimeout(() => refuse(`timedOut: the WebSocket did not open in ${timeout} s`), timeout * 1000)
          : 0;
        socket.onopen = () => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          connection.protocol = socket.protocol || "";
          connections.set(id, connection);
          // From here the connection's own events.
          socket.onerror = null;
          socket.onclose = (event) => finish(connection, event.code, event.reason);
          resolve(id);
        };
        socket.onmessage = (event) => {
          deliver(connection, typeof event.data === "string"
            ? { kind: TEXT, text: event.data, data: EMPTY, code: 0 }
            : { kind: DATA, text: "", data: new Uint8Array(event.data), code: 0 });
        };
        // Before it opened: the browser says only that it failed (a refused
        // connection, a failed handshake, a name with no address alike).
        socket.onerror = () => refuse(`cannotConnectToHost: the WebSocket to ${url} could not be opened`);
        socket.onclose = (event) => refuse(`cannotConnectToHost: the WebSocket to ${url} closed before it opened (${event.code})`);
      });
    },

    subprotocol(id) {
      const connection = connections.get(id);
      return connection ? connection.protocol : "";
    },

    sendText(id, text) {
      live(id).socket.send(text);
    },

    sendData(id, data) {
      live(id).socket.send(data);
    },

    next(id) {
      const connection = connections.get(id);
      if (!connection) return Promise.reject(new Error(`networkConnectionLost: no WebSocket ${id}`));
      if (connection.events.length) return connection.events.shift();
      if (connection.closed) return connection.closed;
      return new Promise((resolve) => connection.waiting.push(resolve));
    },

    disconnect(id, code, reason) {
      const connection = connections.get(id);
      if (!connection || connection.closed) return;
      // A page's WebSocket closes with 1000 or 3000 to 4999 only, and a
      // reason of at most 123 bytes.
      const sent = code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000;
      try {
        connection.socket.close(sent, utf8Prefix(reason, 123));
      } catch (error) {
        console.warn("[network] WebSocket close:", error.message);
        connection.socket.close();
      }
      // The close the app asked for is the connection's from now: a `next`
      // waiting answers with it at once, not when the server's reply comes.
      finish(connection, code, reason);
    },
  };
}

/** The longest start of `text` that is at most `limit` bytes of UTF-8. */
function utf8Prefix(text, limit) {
  const encoder = new TextEncoder();
  if (encoder.encode(text).length <= limit) return text;
  let end = 0, bytes = 0;
  for (const character of text) {
    const size = encoder.encode(character).length;
    if (bytes + size > limit) break;
    bytes += size;
    end += character.length;
  }
  return text.slice(0, end);
}
