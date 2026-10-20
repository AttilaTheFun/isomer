// Electron shell around the wasm application: serves the built static site
// from its own scheme, isomer://app/ (wasm + ES modules don't load over
// file://), and opens it in a BrowserWindow. The renderer is Chromium, so
// the same WebGPU runtime used in the browser runs unchanged. The scheme is
// standard and secure, so the page is a secure context (WebGPU) with the
// same origin at every launch: what the app keeps in IndexedDB (its files,
// wasm/libraries/swift_ui/runtime/file_system.js) and localStorage is there
// the next time, in Electron's user data directory. A loopback server's
// origin changed with its port, and that data with it.

const { app, BrowserWindow, protocol } = require("electron");
const fs = require("fs");
const path = require("path");

// ISO_SITE_DIR is set by `bazel run`; the packaged build (e.g. the Windows
// zip) ships the site inside the app directory instead.
const siteDir = process.env.ISO_SITE_DIR || path.join(__dirname, "site");
if (!fs.existsSync(path.join(siteDir, "index.html"))) {
  console.error(`No built site found at: ${siteDir}`);
  app.exit(1);
}

app.commandLine.appendSwitch("enable-unsafe-webgpu");

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".wasm": "application/wasm",
  ".css": "text/css",
};

// Registered before the app is ready, as Electron requires.
protocol.registerSchemesAsPrivileged([{
  scheme: "isomer",
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true },
}]);

// Headless visual verification: with ISO_SCREENSHOT set, the window stays
// hidden (nothing on screen, no focus taken), the app waits for the wasm app
// to render (ISO_SCREENSHOT_DELAY ms, default 7000), captures the page to
// that PNG path, and quits. Lets an agent verify the web build visually
// through Electron's Chromium without a window.
const screenshotPath = process.env.ISO_SCREENSHOT;

app.whenReady().then(() => {
  protocol.handle("isomer", async (request) => {
    const urlPath = decodeURIComponent(new URL(request.url).pathname);
    const relative = urlPath === "/" ? "index.html" : urlPath.replace(/^\//, "");
    const file = path.normalize(path.join(siteDir, relative));
    if (!file.startsWith(path.normalize(siteDir))) return new Response(null, { status: 403 });
    try {
      const data = await fs.promises.readFile(file);
      return new Response(data, {
        headers: { "Content-Type": MIME[path.extname(file)] || "application/octet-stream" },
      });
    } catch (_) {
      return new Response(null, { status: 404 });
    }
  });

  if (screenshotPath && app.dock) app.dock.hide();
  const window = new BrowserWindow({
    width: 960,
    height: 720,
    title: "Isomer",
    show: !screenshotPath,
    // A hidden window still paints and runs its frames at full rate.
    webPreferences: { backgroundThrottling: !screenshotPath },
  });
  // ISO_RENDERER selects the layered renderer binding (e.g. "react");
  // defaults to the SwiftGPU (WebGPU) path.
  const renderer = process.env.ISO_RENDERER ? `?renderer=${process.env.ISO_RENDERER}` : "";
  window.loadURL(`isomer://app/${renderer}`);

  if (screenshotPath) {
    window.webContents.once("did-finish-load", () => {
      setTimeout(async () => {
        try {
          const image = await window.webContents.capturePage(undefined, { stayHidden: true });
          fs.writeFileSync(screenshotPath, image.toPNG());
          console.log(`screenshot written: ${screenshotPath}`);
        } catch (error) {
          console.error("screenshot failed:", error);
        }
        app.quit();
      }, Number(process.env.ISO_SCREENSHOT_DELAY || 7000));
    });
  }
});

app.on("window-all-closed", () => {
  app.quit();
});
