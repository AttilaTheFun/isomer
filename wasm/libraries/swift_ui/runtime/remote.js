// The web's thin client for a remote session (shared/wire/session.proto):
// the app's SwiftUI runs on a server, built headless; the page holds only
// the React renderer, the tree reader and a WebSocket. No wasm, no Swift:
// what the person does goes to the server as a ClientMessage, each frame
// comes back as a tree.proto Patch.
//
//   import { connectIsomer } from "./runtime/remote.js";
//   connectIsomer({ url: "ws://localhost:8090/session", container: document.body });
//
// The page's ISO_ query parameters are the app's launch environment
// (`?ISO_STORYBOOK_STORY=controls.toggle`), as boot.js's are. The messages
// are session_messages.js's.

import { createReactTreeRenderer } from "./react_renderer.js";
import { applyPatch } from "./flat_tree.js";
import { registerImageBytes } from "./raster.js";
import { clientMessage, readServerMessage } from "./session_messages.js";

export { clientMessage, readServerMessage };

// The page's ISO_ query parameters.
export function launchEnvironment(search = location.search) {
  return Object.fromEntries([...new URLSearchParams(search)].filter(([key]) => key.startsWith("ISO_")));
}

// Connects to `url` (a gateway's /session) and draws the app into
// `container` until the session ends. Returns `{ socket, tree() }`.
export function connectIsomer({
  url,
  container = document.body,
  environment = launchEnvironment(),
  WebSocket: Socket = WebSocket,
  onCommand = null,
  onClose = null,
}) {
  const surface = document.createElement("div");
  surface.style.cssText = "position:fixed;inset:0;display:flex;flex-direction:column;overflow:hidden";
  container.appendChild(surface);
  const socket = new Socket(url);
  socket.binaryType = "arraybuffer";
  const send = (bytes) => { if (socket.readyState === 1) socket.send(bytes); };
  const reactTree = createReactTreeRenderer({
    container: surface,
    sendEvent: (id, value) => send(clientMessage.event(id, value)),
    // The app's answer comes too late to keep a key from its field.
    sendKey: (id, value) => { send(clientMessage.key(id, value)); return false; },
  });
  let retained = null;
  let frame = 0;
  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

  socket.addEventListener("open", () => {
    send(clientMessage.start({
      width: window.innerWidth,
      height: window.innerHeight,
      displayScale: window.devicePixelRatio || 1,
      dark: darkQuery.matches,
      environment,
    }));
    send(clientMessage.openURL(window.location.href));
  });
  socket.addEventListener("message", (event) => {
    const message = readServerMessage(event.data);
    if (message.patch) {
      retained = applyPatch(retained, message.patch);
      window.__isoLastTree = JSON.stringify(retained); // for headless smoke tests
      // A frame an animation frame: patches that arrive together draw once.
      if (!frame) frame = requestAnimationFrame(() => { frame = 0; reactTree.render(retained, false); });
    } else if (message.command) {
      const { key, value } = message.command;
      if (key === "windowTitle") document.title = value;
      else if (key === "copy") navigator.clipboard?.writeText(value).catch(() => {});
      onCommand?.(key, value);
      if (typeof window.isoPlatformCommand === "function") window.isoPlatformCommand(key, value);
    } else if (message.image) {
      registerImageBytes(message.image.source, message.image.bytes);
    } else if (message.openURL) {
      window.open(message.openURL, "_blank");
    } else if (message.dark !== undefined) {
      document.documentElement.style.colorScheme = message.dark ? "dark" : "light";
      document.body.style.background = message.dark ? "rgb(18, 18, 20)" : "#ffffff";
    } else if (message.log) {
      console.log("[swiftui]", message.log);
    }
  });
  socket.addEventListener("close", () => onClose?.());

  window.addEventListener("resize", () => send(clientMessage.resize(window.innerWidth, window.innerHeight)));
  darkQuery.addEventListener("change", (event) => send(clientMessage.dark(event.matches)));
  document.addEventListener("visibilitychange", () => send(clientMessage.scenePhase(document.hidden ? 2 : 0)));
  // Event injection for headless smoke tests, as boot.js's.
  window.__isoSendEvent = (id, value) => send(clientMessage.event(id, value));
  return { socket, tree: () => retained };
}
