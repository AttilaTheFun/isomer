// The services half of the web SwiftGPURenderer: text
// measurement and CPU rasterization (text runs, gradients, shadows,
// images) via 2D canvas. NO GPU code here — Swift draws the returned RGBA
// through swift_gpu; this only produces pixels and metrics.

const FONT_STACK =
  '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif';
const LINE_HEIGHT = 1.3;

function fontString(size, weight) {
  return `${weight} ${size}px ${FONT_STACK}`;
}

/// Splits text into lines: explicit newlines plus greedy word wrap.
function layoutLines(ctx2d, text, size, weight, wrapWidth) {
  ctx2d.font = fontString(size, weight);
  const lines = [];
  for (const paragraph of text.split("\n")) {
    if (wrapWidth == null || ctx2d.measureText(paragraph).width <= wrapWidth) {
      lines.push(paragraph);
      continue;
    }
    let current = "";
    for (const word of paragraph.split(" ")) {
      const candidate = current.length > 0 ? current + " " + word : word;
      if (ctx2d.measureText(candidate).width <= wrapWidth || current.length === 0) {
        current = candidate;
      } else {
        lines.push(current);
        current = word;
      }
    }
    lines.push(current);
  }
  let maxWidth = 0;
  for (const line of lines) {
    maxWidth = Math.max(maxWidth, ctx2d.measureText(line).width);
  }
  return { lines, width: maxWidth, height: lines.length * size * LINE_HEIGHT };
}

function cssColor(r, g, b, a) {
  return `rgba(${(r * 255) | 0},${(g * 255) | 0},${(b * 255) | 0},${a})`;
}

// Pictures handed over by `IsomerImages.register`: their `isomer-image://`
// source -> a Blob's object URL, which every image path draws by (the browser
// decodes it off the main thread).
const registeredImages = new Map();

export function registerImageBytes(source, bytes) {
  const old = registeredImages.get(source);
  if (old) URL.revokeObjectURL(old);
  registeredImages.delete(source);
  // The Blob copies the bytes (they are a view of the wasm memory).
  if (bytes && bytes.length) registeredImages.set(source, URL.createObjectURL(new Blob([bytes])));
}

export function resolveImageSource(src) {
  return registeredImages.get(src) || src;
}

export function createRasterHost({ scale = 1, invalidate = () => {} } = {}) {
  const measureCtx = new OffscreenCanvas(1, 1).getContext("2d");
  const images = new Map(); // src -> {state, width, height, bitmap}

  function imageEntry(src, isRemote) {
    let entry = images.get(src);
    if (!entry) {
      entry = { state: 0, width: 0, height: 0, bitmap: null };
      images.set(src, entry);
      loadImage(src, isRemote, entry);
    }
    return entry;
  }

  async function loadImage(src, isRemote, entry) {
    const candidates = isRemote
      ? [resolveImageSource(src)]
      : [`assets/${src}`, `assets/${src}.png`, `assets/${src}.jpg`];
    for (const candidate of candidates) {
      try {
        const response = await fetch(candidate, { mode: isRemote ? "cors" : "same-origin" });
        if (!response.ok) continue;
        const bitmap = await createImageBitmap(await response.blob());
        entry.state = 1;
        entry.width = bitmap.width;
        entry.height = bitmap.height;
        entry.bitmap = bitmap;
        invalidate();
        return;
      } catch {
        // try the next candidate
      }
    }
    entry.state = 2;
    invalidate();
  }

  /// Render `draw` into an offscreen canvas at the display scale and pack
  /// the result as [w u32 LE][h u32 LE][RGBA8...].
  function packCanvas(cssWidth, cssHeight, draw) {
    const width = Math.max(1, Math.round(cssWidth * scale));
    const height = Math.max(1, Math.round(cssHeight * scale));
    const surface = new OffscreenCanvas(width, height);
    const ctx = surface.getContext("2d");
    ctx.scale(scale, scale);
    draw(ctx, cssWidth, cssHeight);
    const data = ctx.getImageData(0, 0, width, height).data;
    const out = new Uint8Array(8 + data.length);
    new DataView(out.buffer).setUint32(0, width, true);
    new DataView(out.buffer).setUint32(4, height, true);
    // Premultiply (getImageData is straight alpha; the textured pipeline
    // blends premultiplied).
    for (let i = 0; i < data.length; i += 4) {
      const a = data[i + 3] / 255;
      out[8 + i] = data[i] * a;
      out[8 + i + 1] = data[i + 1] * a;
      out[8 + i + 2] = data[i + 2] * a;
      out[8 + i + 3] = data[i + 3];
    }
    return out;
  }

  function applyGradient(ctx, spec, w, h) {
    // The runtime's schema (shared/swift_ui_core/Paint.swift):
    // {kind: "linear"|"radial"|"angular", stops: [{c: [r,g,b,a], l}],
    //  p0/p1 (linear) or c + er (radial/angular), unit coordinates}.
    let gradient;
    if (spec.kind === "radial") {
      const cx = spec.c[0] * w;
      const cy = spec.c[1] * h;
      // sr/er are radii in points (canvas space is points here).
      gradient = ctx.createRadialGradient(cx, cy, Math.max(spec.sr ?? 0, 0), cx, cy, Math.max(spec.er ?? 1, 0.01));
    } else if (spec.kind === "angular") {
      gradient = ctx.createConicGradient(spec.a0 ?? 0, spec.c[0] * w, spec.c[1] * h);
    } else {
      gradient = ctx.createLinearGradient(
        spec.p0[0] * w, spec.p0[1] * h, spec.p1[0] * w, spec.p1[1] * h);
    }
    for (const stop of spec.stops ?? []) {
      const [r, g, b, a] = stop.c;
      gradient.addColorStop(Math.min(1, Math.max(0, stop.l ?? 0)), cssColor(r, g, b, a));
    }
    ctx.fillStyle = gradient;
  }

  return {
    measureText(text, fontSize, weight, wrapWidth) {
      const layout = layoutLines(measureCtx, text, fontSize, weight, wrapWidth);
      return { width: layout.width, height: layout.height };
    },

    imageInfo(source, isRemote) {
      const entry = imageEntry(source, isRemote);
      return { state: entry.state, width: entry.width, height: entry.height };
    },

    /// The SwiftGPURenderer's raster callback; spec kinds mirror
    /// shared/swift_ui_core/SwiftGPURenderer.swift.
    rasterize(specJSON) {
      const spec = JSON.parse(specJSON);
      if (spec.kind === "text") {
        const wrap = spec.wrap > 0 ? spec.wrap : null;
        const layout = layoutLines(measureCtx, spec.text, spec.size, spec.weight, wrap);
        const width = Math.max(layout.width, 1);
        const height = Math.max(layout.height, 1);
        return packCanvas(width, height, (ctx) => {
          ctx.font = fontString(spec.size, spec.weight);
          ctx.textBaseline = "middle";
          ctx.fillStyle = cssColor(spec.r, spec.g, spec.b, spec.a);
          layout.lines.forEach((line, index) => {
            ctx.fillText(line, 0, (index + 0.5) * spec.size * LINE_HEIGHT);
          });
        });
      }
      if (spec.kind === "gradient") {
        const radius = Math.min(spec.radius ?? 0, spec.w / 2, spec.h / 2);
        return packCanvas(spec.w, spec.h, (ctx, w, h) => {
          ctx.beginPath();
          ctx.roundRect(0, 0, w, h, radius);
          ctx.clip();
          applyGradient(ctx, spec.gradient, w, h);
          ctx.fillRect(0, 0, w, h);
        });
      }
      if (spec.kind === "shadow") {
        const radius = Math.min(spec.corner ?? 0, spec.w / 2, spec.h / 2);
        const pad = spec.blur * 2;
        return packCanvas(spec.w + pad * 2, spec.h + pad * 2, (ctx) => {
          ctx.filter = `blur(${spec.blur}px)`;
          ctx.fillStyle = cssColor(spec.r, spec.g, spec.b, spec.a);
          ctx.beginPath();
          ctx.roundRect(pad, pad, spec.w, spec.h, radius);
          ctx.fill();
        });
      }
      if (spec.kind === "image") {
        const entry = imageEntry(spec.source, spec.remote);
        if (entry.state !== 1 || !entry.bitmap) return new Uint8Array(0);
        return packCanvas(entry.width, entry.height, (ctx) => {
          ctx.drawImage(entry.bitmap, 0, 0, entry.width, entry.height);
        });
      }
      return new Uint8Array(0);
    },
  };
}
