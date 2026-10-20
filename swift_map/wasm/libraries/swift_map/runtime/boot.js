// Boots a SwiftMap web application through the swift_ffi bindings: `load()`
// instantiates the wasm reactor, Isomer's Metal executor (WebGPU) is
// connected to it, and a plain object implements the Swift `MapWebHost`
// protocol (fetch/decode + rAF scheduling + callout text — no drawing;
// rendering happens in Swift through SwiftGPU).

import { load } from "../map_bridge.js";
import { createIsomerMetalHost } from "./isomer_metal_webgpu.js";

export async function boot({
  canvas,
  wasmURL = "./map.wasm",
  latitude = 37.7749,
  longitude = -122.4194,
  zoom = 12,
  bearing = 0,
  tilt = 0,
  // Overlays: [{ id, latitude, longitude, color: [r,g,b,a], radius }] and
  // [{ id, coordinates: [[lat,lon],…], fillColor: [r,g,b,a],
  //    strokeColor: [r,g,b,a], strokeWidth }].
  annotations = [],
  polygons = [],
  // [{ id, coordinates: [[lat,lon],…], color: [r,g,b,a], width }]
  polylines = [],
} = {}) {
  const metalHost = await createIsomerMetalHost(canvas);

  let bridge = null;
  let renderQueued = false;
  let selectedAnnotation = null; // id of the open callout

  function scheduleRender() {
    if (renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(() => {
      renderQueued = false;
      bridge.smRender();
    });
  }

  const host = {
    presentFrame(infoJSON) {
      // Drawing already happened in Swift (SwiftGPU/WebGPU); this is the
      // slim per-frame info for the callout overlay + smoke tests.
      const info = JSON.parse(infoJSON);
      window.__smLastFrame = info; // for headless smoke tests
      positionCallout(info);
    },
    annotationTapped(id, title, _x, _y) {
      // Toggle the callout; it repositions from each frame's anchors.
      selectedAnnotation = selectedAnnotation === id ? null : id;
      window.__smSelectedAnnotation = selectedAnnotation;
      callout.textContent = title;
      bridge.smRender();
    },
    requestTile(key, url) {
      fetch(url)
        .then((response) => {
          if (!response.ok) throw new Error(`http ${response.status}`);
          return response.blob();
        })
        .then((blob) => createImageBitmap(blob))
        .then((bitmap) => {
          // Decode to tightly packed RGBA bytes; the texture uploads on
          // the Swift side of the bridge (through swift_gpu).
          const surface = new OffscreenCanvas(bitmap.width, bitmap.height);
          const ctx = surface.getContext("2d");
          ctx.drawImage(bitmap, 0, 0);
          const data = ctx.getImageData(0, 0, bitmap.width, bitmap.height).data;
          bridge.smTileLoaded(key, bitmap.width, bitmap.height, new Uint8Array(data.buffer));
        })
        .catch((error) => {
          console.warn(`[SwiftMap] tile ${key} failed:`, error);
          bridge.smTileFailed(key);
        });
    },
    scheduleRender,
    log(message) {
      console.log("[SwiftMap]", message);
    },
  };

  bridge = await load(await WebAssembly.compileStreaming(fetch(wasmURL)));
  window.__smBridge = bridge; // for headless smoke tests
  metalHost.connect(bridge); // Isomer's Metal executor (WebGPU)

  const scale = window.devicePixelRatio || 1;
  function resizeBacking() {
    canvas.width = Math.max(1, Math.round(canvas.clientWidth * scale));
    canvas.height = Math.max(1, Math.round(canvas.clientHeight * scale));
  }
  resizeBacking();

  bridge.smStart(
    host,
    canvas.clientWidth, canvas.clientHeight,
    latitude, longitude, zoom, bearing, tilt,
  );
  if (annotations.length) {
    bridge.smSetAnnotations(
      annotations
        .map((a) => [a.id, a.latitude, a.longitude,
          ...(a.color ?? [1, 0.23, 0.19, 1]), a.radius ?? 8, a.title ?? ""].join("|"))
        .join(";"),
    );
  }
  if (polylines.length) {
    bridge.smSetPolylines(
      polylines
        .map((p) => [
          p.id,
          (p.color ?? [0, 0.48, 1, 1]).join(","),
          p.width ?? 4,
          p.coordinates.map((c) => c.join(",")).join(";"),
        ].join("|"))
        .join("\n"),
    );
  }
  if (polygons.length) {
    bridge.smSetPolygons(
      polygons
        .map((p) => [
          p.id,
          (p.fillColor ?? [0.2, 0.78, 0.35, 0.35]).join(","),
          p.strokeColor ? [...p.strokeColor, p.strokeWidth ?? 2].join(",") : "",
          p.coordinates.map((c) => c.join(",")).join(";"),
        ].join("|"))
        .join("\n"),
    );
  }
  scheduleRender();

  // The selected annotation's callout: native text positioned above the
  // marker from the frame's projected anchors.
  const callout = document.createElement("div");
  callout.style.cssText = [
    "position:absolute", "display:none", "z-index:3", "pointer-events:none",
    "font:12px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
    "font-weight:500", "color:#000", "background:rgba(255,255,255,0.95)",
    "border:0.5px solid rgba(0,0,0,0.2)", "border-radius:6px", "padding:3px 8px",
    "transform:translate(-50%,-100%)", "white-space:nowrap",
  ].join(";");
  (canvas.parentElement || document.body).appendChild(callout);

  function positionCallout(info) {
    const anchor = selectedAnnotation
      ? (info.anns || []).find((a) => a.i === selectedAnnotation)
      : null;
    if (!anchor || !anchor.t) {
      callout.style.display = "none";
      return;
    }
    callout.textContent = anchor.t;
    callout.style.left = `${anchor.x}px`;
    callout.style.top = `${anchor.y - 12}px`;
    callout.style.display = "block";
  }

  // Required attribution for OpenStreetMap data (ODbL).
  const attribution = document.createElement("a");
  attribution.href = "https://www.openstreetmap.org/copyright";
  attribution.textContent = "© OpenStreetMap contributors";
  attribution.style.cssText = [
    "position:absolute", "right:4px", "bottom:4px", "z-index:2",
    "font:9px -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
    "color:rgba(0,0,0,0.6)", "background:rgba(255,255,255,0.7)",
    "padding:1px 4px", "text-decoration:none",
  ].join(";");
  (canvas.parentElement || document.body).appendChild(attribution);

  // Input: drag pans, wheel (and trackpad pinch) zooms about the cursor,
  // double-click zooms in a level.
  const localPoint = (event) => {
    const rect = canvas.getBoundingClientRect();
    return [event.clientX - rect.left, event.clientY - rect.top];
  };
  let downPoint = null;
  canvas.addEventListener("pointerdown", (event) => {
    canvas.setPointerCapture(event.pointerId);
    downPoint = localPoint(event);
    bridge.smPointer(0, ...downPoint);
  });
  canvas.addEventListener("pointermove", (event) => {
    if (event.buttons) bridge.smPointer(1, ...localPoint(event));
  });
  canvas.addEventListener("pointerup", (event) => {
    const point = localPoint(event);
    bridge.smPointer(2, ...point);
    // A press that never dragged is a tap: annotation hit-test.
    if (downPoint &&
        Math.abs(point[0] - downPoint[0]) + Math.abs(point[1] - downPoint[1]) < 4) {
      bridge.smTap(...point);
    }
    downPoint = null;
  });
  canvas.addEventListener("wheel", (event) => {
    event.preventDefault();
    const speed = event.ctrlKey ? 0.01 : 0.003; // pinch reports ctrlKey
    bridge.smZoom(-event.deltaY * speed, ...localPoint(event));
  }, { passive: false });
  canvas.addEventListener("dblclick", (event) => {
    bridge.smZoom(1, ...localPoint(event));
  });
  window.addEventListener("resize", () => {
    resizeBacking();
    bridge.smResize(canvas.clientWidth, canvas.clientHeight);
  });

  return { bridge };
}
