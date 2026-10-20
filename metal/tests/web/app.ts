// The page side of the Metal check: makes the WebGPU executor for a
// canvas, loads the check's reactor (bytes the driver put in
// window.__metalCheckWasm), connects them, runs the check, and leaves what
// it reported in window.__metalCheck for the driver to read.
import { load } from "./metal_check_web.js";
// @ts-ignore: plain JavaScript (esbuild bundles it; nothing typechecks here).
import { createIsomerMetalHost } from "./isomer_metal_webgpu.js";

const w = window as any;
const state: { lines: string[]; done: boolean } = (w.__metalCheck = { lines: [], done: false });

/// The frame drawn to the canvas, read back through a 2D canvas in the
/// task that drew it (a WebGPU canvas's image is the page's until the task
/// ends and it is presented).
function readCanvas() {
  try {
    const copy = document.createElement("canvas");
    copy.width = canvas.width;
    copy.height = canvas.height;
    const context = copy.getContext("2d")!;
    context.drawImage(canvas, 0, 0);
    const [r, g, b, a] = context.getImageData(20, 15, 1, 1).data;
    const ok = r === 255 && Math.abs(g - 128) <= 1 && b === 0 && a === 255;
    state.lines.push(`${ok ? "ok" : "FAIL"} canvas: the drawable's clear color reached the page (${r}, ${g}, ${b}, ${a})`);
  } catch (error) {
    state.lines.push(`FAIL canvas: ${error}`);
  }
}

const canvas = document.createElement("canvas");
canvas.width = 40;
canvas.height = 30;
document.body.appendChild(canvas);

(async () => {
  try {
    const host = await createIsomerMetalHost(canvas);
    const bridge = await load(w.__metalCheckWasm.buffer);
    host.connect(bridge);
    bridge.metalCheckRun({
      report(line: string) {
        state.lines.push(line);
        if (line === "drawn canvas") readCanvas();
        if (line === "done") state.done = true;
      },
    });
  } catch (error) {
    state.lines.push(`FAIL ${error}`);
    state.done = true;
  }
})();
