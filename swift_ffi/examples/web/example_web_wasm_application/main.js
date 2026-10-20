// Electron shell around the wasm example: serves the page, the bundled JS,
// and the reactor over loopback HTTP (wasm + ES modules don't load over
// file://) and opens it in a BrowserWindow.

import { app, BrowserWindow } from "electron";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

// GREETER_SITE_DIR is set by `bazel run` to the runfiles directory holding
// index.html, bundle.js, and greeter_web.wasm.
const siteDir = process.env.GREETER_SITE_DIR;
if (!siteDir) {
  console.error("GREETER_SITE_DIR is not set; launch via bazel run");
  app.exit(1);
}

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".wasm": "application/wasm",
};

const server = http.createServer((request, response) => {
  const urlPath = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  const relative = urlPath === "/" ? "index.html" : urlPath.replace(/^\//, "");
  const file = path.normalize(path.join(siteDir, relative));
  if (!file.startsWith(path.normalize(siteDir))) {
    response.writeHead(403);
    response.end();
    return;
  }
  fs.readFile(file, (error, data) => {
    if (error) {
      response.writeHead(404);
      response.end();
      return;
    }
    response.writeHead(200, {
      "Content-Type": MIME[path.extname(file)] || "application/octet-stream",
    });
    response.end(data);
  });
});

server.listen(0, "127.0.0.1", () => {
  const port = server.address().port;
  app.whenReady().then(() => {
    const window = new BrowserWindow({
      width: 480,
      height: 720,
      title: "Greeter",
    });
    window.loadURL(`http://127.0.0.1:${port}/`);
  });
});

app.on("window-all-closed", () => {
  app.quit();
});
